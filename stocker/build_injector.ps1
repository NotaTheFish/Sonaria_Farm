param(
    [string]$Toolchain = "auto",
    [switch]$VerboseBuild,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
# В PowerShell 7 stderr native-команд может превращаться в ErrorRecord и падать по ErrorActionPreference=Stop.
# Для компиляторов это нормальный поток диагностики, поэтому отключаем такое поведение локально.
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$prevOutEnc = [Console]::OutputEncoding
$prevInEnc = [Console]::InputEncoding
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    # best-effort; keep default encoding
}

$Toolchain = if ([string]::IsNullOrWhiteSpace($Toolchain)) { "auto" } else { $Toolchain.ToLowerInvariant() }
if ($Toolchain -notin @("auto", "msvc", "mingw")) {
    throw "Unsupported Toolchain '$Toolchain'. Use: auto | msvc | mingw."
}

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$outputDir = Join-Path $root "stocker\build"
$source = Join-Path $root "stocker\injector.cpp"
$output = Join-Path $outputDir "injector.exe"
$buildLog = if ([string]::IsNullOrWhiteSpace($LogPath)) {
    Join-Path $outputDir "injector_build.log"
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$CmdLine
    )
    $tmpOut = [System.IO.Path]::GetTempFileName()
    try {
        # Весь stdout/stderr уходит в файл на стороне cmd.exe, чтобы PowerShell не превращал stderr в ErrorRecord.
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

function Invoke-MsvcBuild {
    # Prefer explicit x64 toolchain via VsDevCmd to avoid x86/x64 mixed env issues.
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
                    "`"$source`"",
                    "/Fe:`"$output`"",
                    "/link",
                    "user32.lib",
                    "kernel32.lib"
                ) -join " "
                $res = Invoke-CmdAndCapture -CmdLine $cmd
                $vsOut = $res.Lines
                if ($vsOut) {
                    $vsOut | ForEach-Object {
                        Write-Host $_
                        Write-BuildLog "$_"
                    }
                }
                Write-BuildLog "[build] msvc_vsdevcmd_exit_code=$($res.ExitCode)"
                if ($res.ExitCode -eq 0) {
                    return $true
                }
                # MSVC cl.exe returns 1 on warnings. If output exists, treat as success.
                if ($res.ExitCode -eq 1 -and (Test-Path $output)) {
                    Write-Warning "MSVC VsDevCmd x64 returned 1 (warnings), but output exists: $output"
                    Write-BuildLog "[build] note: treating exit_code=1 as success because output exists"
                    return $true
                }
                Write-Warning "MSVC VsDevCmd x64 failed with code $($res.ExitCode)"
                Show-LogTail 200
            }
        }
    }

    # Fallback: cl.exe from current PATH (may be x86, but can still work in some setups).
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl) {
        Write-Host "[build] using MSVC (cl.exe in PATH)"
        Write-BuildLog "[build] using MSVC (cl.exe in PATH)"
        $cmd = @(
            "`"$($cl.Path)`"",
            "/std:c++17",
            "/EHsc",
            "/O2",
            "`"$source`"",
            "/Fe:`"$output`"",
            "/link",
            "user32.lib",
            "kernel32.lib"
        ) -join " "
        $res = Invoke-CmdAndCapture -CmdLine $cmd
        $msvcOut = $res.Lines
        if ($msvcOut) {
            $msvcOut | ForEach-Object {
                Write-Host $_
                Write-BuildLog "$_"
            }
        }
        Write-BuildLog "[build] msvc_exit_code=$($res.ExitCode)"
        if ($res.ExitCode -eq 0) {
            return $true
        }
        # MSVC cl.exe returns 1 on warnings. If output exists, treat as success.
        if ($res.ExitCode -eq 1 -and (Test-Path $output)) {
            Write-Warning "MSVC returned 1 (warnings), but output exists: $output"
            Write-BuildLog "[build] note: treating exit_code=1 as success because output exists"
            return $true
        }
        Show-LogTail 160
        throw "MSVC build failed with code $($res.ExitCode). See log: $buildLog"
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
        "-static-libgcc",
        "-static-libstdc++",
        "-s",
        $source,
        "-o", $output,
        "-luser32",
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
    # ignore
}
