param(
    # Full path to libero.exe; otherwise $env:LIBERO, PATH, then C:\Microchip.
    [string]$Libero = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot "build\libero"
$tclScript = Join-Path $repoRoot "fpga\libero\build_motorsentinel.tcl"
$logFile = Join-Path $buildDir "libero.log"

function Find-Libero {
    if ($Libero) { return $Libero }
    if ($env:LIBERO) { return $env:LIBERO }
    $command = Get-Command libero -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $installed = Get-ChildItem -Path "C:\Microchip" -Filter "libero.exe" -Recurse `
        -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($installed) { return $installed.FullName }
    throw "libero.exe not found. Pass -Libero <path> or set the LIBERO environment variable."
}

$liberoExe = Find-Libero
Write-Host "Using $liberoExe"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

# The Tcl script locates the repository from its own path, so no SCRIPT_ARGS
# are passed; Libero splits them on spaces, which breaks paths like this one.
& $liberoExe "SCRIPT:$tclScript" "LOGFILE:$logFile"
$liberoExit = $LASTEXITCODE

Push-Location $repoRoot
try {
    & python tools/libero_report.py --build-dir $buildDir
}
finally {
    Pop-Location
}

if ($liberoExit -ne 0) {
    throw "Libero build failed with exit code $liberoExit; see $logFile"
}
