param(
    [string]$Toolchain = "auto",
    [switch]$VerboseBuild,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$prevOutEnc = [Console]::OutputEncoding
$prevInEnc = [Console]::InputEncoding
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
}

$Toolchain = if ([string]::IsNullOrWhiteSpace($Toolchain)) { "auto" } else { $Toolchain.ToLowerInvariant() }
if ($Toolchain -notin @("auto", "msvc", "mingw")) {
    throw "Unsupported Toolchain '$Toolchain'. Use: auto | msvc | mingw."
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputDir = Join-Path $root "stocker\build"
$source = Join-Path $root "stocker\sonaria_wrd_executor_api.cpp"
$output = Join-Path $outputDir "sonaria_wrd_executor_api.dll"
$buildLog = if ([string]::IsNullOrWhiteSpace($LogPath)) {
    Join-Path $outputDir "wrd_executor_api_build.log"
} else {
    $LogPath
}

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

Write-Host "[build] root: $root"
Write-Host "[build] source: $source"
Write-Host "[build] output: $output"
Write-Host "[build] toolchain: $Toolchain"
Write-Host "[build] log: $buildLog"

"" | Out-File -FilePath $buildLog -Encoding utf8

function Write-BuildLog {
    param([string]$Line)
    if ($null -eq $Line) { return }
    $Line | Out-File -FilePath $buildLog -Append -Encoding utf8
}

function Show-LogTail {
    param([int]$Lines = 120)
    if (-not (Test-Path $buildLog)) { return }
    Write-Host "[build] --- log tail ($Lines lines): $buildLog"
    try {
        Get-Content -Path $buildLog -Tail $Lines | ForEach-Object { Write-Host $_ }
    } catch {
        Write-Host "[build] (failed to read log tail) $_"
    }
}

function Invoke-CmdAndCapture {
    param([Parameter(Mandatory = $true)][string]$CmdLine)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    try {
        $full = "$CmdLine > `"$tmpOut`" 2>&1"
        cmd /c $full | Out-Null
        $exitCode = $LASTEXITCODE
        $lines = @()
        if (Test-Path $tmpOut) {
            $lines = Get-Content -Path $tmpOut -Encoding utf8 -ErrorAction SilentlyContinue
            if (-not $lines) {
                $lines = Get-Content -Path $tmpOut -ErrorAction SilentlyContinue
            }
        }
        return @{
            ExitCode = $exitCode
            Lines = $lines
        }
    } finally {
        Remove-Item -Path $tmpOut -ErrorAction SilentlyContinue
    }
}

function Stop-LockingOutputProcess {
    if (-not (Test-Path $output)) {
        return
    }
    $outputFull = [System.IO.Path]::GetFullPath($output)
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ([System.IO.Path]::GetFullPath($_.ExecutablePath) -ieq $outputFull) }
    foreach ($p in @($procs)) {
        if (-not $p) { continue }
        Write-Host "[build] stopping process locking output (pid=$($p.ProcessId))"
        Write-BuildLog "[build] stopping pid=$($p.ProcessId) path=$($p.ExecutablePath)"
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        } catch {
            Write-Warning "Failed to stop pid=$($p.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Invoke-MsvcBuildCore {
    param(
        [Parameter(Mandatory = $true)][string]$CmdLine,
        [Parameter(Mandatory = $true)][string]$ExitCodeLabel
    )
    $res = Invoke-CmdAndCapture -CmdLine $CmdLine
    $buildOut = $res.Lines
    if ($buildOut) {
        $buildOut | ForEach-Object {
            Write-Host $_
            Write-BuildLog "$_"
        }
    }
    Write-BuildLog "[build] $ExitCodeLabel=$($res.ExitCode)"
    if ($res.ExitCode -eq 0) {
        return $true
    }
    if ($res.ExitCode -eq 1 -and (Test-Path $output)) {
        Write-Warning "MSVC returned 1 (warnings), but output exists: $output"
        Write-BuildLog "[build] note: treating exit_code=1 as success because output exists"
        return $true
    }

    $hadLockError = $false
    foreach ($line in @($buildOut)) {
        if ($line -match 'LNK1104' -and $line -match [Regex]::Escape($output)) {
            $hadLockError = $true
            break
        }
    }
    if ($hadLockError) {
        Write-Warning "Detected linker lock on $output. Retrying once after process cleanup."
        Write-BuildLog "[build] LNK1104 retry"
        Stop-LockingOutputProcess
        Start-Sleep -Milliseconds 250
        $retry = Invoke-CmdAndCapture -CmdLine $CmdLine
        if ($retry.Lines) {
            $retry.Lines | ForEach-Object {
                Write-Host $_
                Write-BuildLog "$_"
            }
        }
        Write-BuildLog "[build] ${ExitCodeLabel}_retry=$($retry.ExitCode)"
        if ($retry.ExitCode -eq 0) {
            return $true
        }
        if ($retry.ExitCode -eq 1 -and (Test-Path $output)) {
            Write-Warning "MSVC retry returned 1 (warnings), but output exists: $output"
            return $true
        }
    }
    return $false
}

function Invoke-MsvcBuild {
    $vswhereDefault = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vswhere = if (Test-Path $vswhereDefault) { $vswhereDefault } else { $null }
    if ($vswhere) {
        $vsInstallPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vsInstallPath)) {
            $vsDevCmd = Join-Path $vsInstallPath "Common7\Tools\VsDevCmd.bat"
            if (Test-Path $vsDevCmd) {
                Write-Host "[build] using MSVC (VsDevCmd bootstrap x64)"
                Write-BuildLog "[build] using MSVC (VsDevCmd bootstrap x64)"
                $cmd = @(
                    "`"$vsDevCmd`"",
                    "-arch=x64",
                    "&&",
                    "cl",
                    "/std:c++17",
                    "/EHsc",
                    "/O2",
                    "/LD",
                    "`"$source`"",
                    "/Fe:`"$output`"",
                    "/link",
                    "/DLL",
                    "kernel32.lib"
                ) -join " "
                $ok = Invoke-MsvcBuildCore -CmdLine $cmd -ExitCodeLabel "msvc_vsdevcmd_exit_code"
                if ($ok) {
                    return $true
                }
                Write-Warning "MSVC VsDevCmd x64 build attempt failed"
                Show-LogTail 200
            }
        }
    }

    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl) {
        Write-Host "[build] using MSVC (cl.exe in PATH)"
        Write-BuildLog "[build] using MSVC (cl.exe in PATH)"
        $cmd = @(
            "`"$($cl.Path)`"",
            "/std:c++17",
            "/EHsc",
            "/O2",
            "/LD",
            "`"$source`"",
            "/Fe:`"$output`"",
            "/link",
            "/DLL",
            "kernel32.lib"
        ) -join " "
        $ok = Invoke-MsvcBuildCore -CmdLine $cmd -ExitCodeLabel "msvc_exit_code"
        if ($ok) {
            return $true
        }
        Show-LogTail 160
        throw "MSVC build failed. See log: $buildLog"
    }
    return $false
}

function Invoke-MingwBuild {
    $gxx = Get-Command g++.exe -ErrorAction SilentlyContinue
    if (-not $gxx) {
        return $false
    }
    Write-Host "[build] using MinGW (g++.exe)"
    Write-BuildLog "[build] using MinGW (g++.exe)"
    $args = @(
        "-std=c++17",
        "-O2",
        "-shared",
        "-static-libgcc",
        "-static-libstdc++",
        "-s",
        "-o", $output,
        $source,
        "-lkernel32"
    )
    if ($VerboseBuild) {
        Write-Host "[build] g++ args: $($args -join ' ')"
        Write-BuildLog "[build] g++ args: $($args -join ' ')"
    }
    $gxxOut = & $gxx.Path @args 2>&1
    if ($gxxOut) {
        $gxxOut | ForEach-Object {
            Write-Host $_
            Write-BuildLog "$_"
        }
    }
    Write-BuildLog "[build] mingw_exit_code=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Show-LogTail 200
        throw "MinGW build failed with code $LASTEXITCODE. See log: $buildLog"
    }
    return $true
}

$built = $false
switch ($Toolchain) {
    "msvc" {
        $built = Invoke-MsvcBuild
        if (-not $built) {
            throw "Requested toolchain 'msvc', but cl.exe not found."
        }
    }
    "mingw" {
        $built = Invoke-MingwBuild
        if (-not $built) {
            throw "Requested toolchain 'mingw', but g++.exe not found."
        }
    }
    default {
        try {
            $built = Invoke-MsvcBuild
        } catch {
            Write-Warning "MSVC build path failed: $($_.Exception.Message)"
            Show-LogTail 200
            $built = $false
        }
        if (-not $built) {
            Write-Host "[build] MSVC unavailable, trying MinGW fallback..."
            $built = Invoke-MingwBuild
        }
    }
}

if (-not $built) {
    throw "No supported compiler found. Install MSVC Build Tools (cl.exe) or MinGW-w64 (g++.exe)."
}

if (-not (Test-Path $output)) {
    throw "Build finished without output file: $output"
}

Write-Host "[build] ok: $output"
Write-BuildLog "[build] ok: $output"

try {
    [Console]::OutputEncoding = $prevOutEnc
    [Console]::InputEncoding = $prevInEnc
} catch {
}
