param(
    [switch]$Waves
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot "build"
$simImage = Join-Path $buildDir "tb_motorsentinel_guard.vvp"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$iverilogArgs = @("-g2012", "-Wall")
if ($Waves) {
    $iverilogArgs += "-DDUMP_WAVES"
}
$iverilogArgs += @("-s", "tb_motorsentinel_guard", "-o", $simImage)

& iverilog @iverilogArgs `
    (Join-Path $repoRoot "rtl/motorsentinel_protocol_guard.sv") `
    (Join-Path $repoRoot "rtl/motorsentinel_safety_policy.sv") `
    (Join-Path $repoRoot "rtl/motorsentinel_guard_apb.sv") `
    (Join-Path $repoRoot "tb/tb_motorsentinel_guard.sv")

if ($LASTEXITCODE -ne 0) {
    throw "Icarus Verilog compilation failed with exit code $LASTEXITCODE"
}

Push-Location $repoRoot
try {
    & vvp $simImage
    if ($LASTEXITCODE -ne 0) {
        throw "RTL simulation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
