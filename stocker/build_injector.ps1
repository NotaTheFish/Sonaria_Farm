param(
    [string]$Toolchain = "auto",
    [switch]$VerboseBuild,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"

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

function Invoke-MsvcBuild {
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl) {
        Write-Host "[build] using MSVC (cl.exe in PATH)"
        Write-BuildLog "[build] using MSVC (cl.exe in PATH)"
        $msvcOut = & $cl.Path /std:c++17 /EHsc /O2 $source /Fe:$output /link user32.lib kernel32.lib 2>&1
        if ($msvcOut) {
            $msvcOut | ForEach-Object {
                Write-Host $_
                Write-BuildLog "$_"
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "MSVC build failed with code $LASTEXITCODE. See log: $buildLog"
        }
        return $true
    }

    # Fallback: try to bootstrap MSVC env via VsDevCmd from Visual Studio installation.
    $vswhereDefault = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vswhere = if (Test-Path $vswhereDefault) { $vswhereDefault } else { $null }
    if (-not $vswhere) {
        return $false
    }
    $vsInstallPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vsInstallPath)) {
        return $false
    }

    $vsDevCmd = Join-Path $vsInstallPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        return $false
    }

    Write-Host "[build] using MSVC (VsDevCmd bootstrap)"
    Write-BuildLog "[build] using MSVC (VsDevCmd bootstrap)"
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
    $vsOut = cmd /c $cmd 2>&1
    if ($vsOut) {
        $vsOut | ForEach-Object {
            Write-Host $_
            Write-BuildLog "$_"
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "MSVC build via VsDevCmd failed with code $LASTEXITCODE. See log: $buildLog"
    }
    return $true
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
    if ($LASTEXITCODE -ne 0) {
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
            Write-Warning $_
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
