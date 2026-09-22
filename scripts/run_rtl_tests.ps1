param(
    [switch]$Waves
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot "build"
$guardImage = Join-Path $buildDir "tb_motorsentinel_guard.vvp"
$featureImage = Join-Path $buildDir "tb_motorsentinel_feature_extractor.vvp"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

Push-Location $repoRoot
try {
    & python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) {
        throw "Python feature-model tests failed with exit code $LASTEXITCODE"
    }

    & python tools/generate_feature_vectors.py --output-dir $buildDir
    if ($LASTEXITCODE -ne 0) {
        throw "Feature-vector generation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$iverilogArgs = @("-g2012", "-Wall")
if ($Waves) {
    $iverilogArgs += "-DDUMP_WAVES"
}
$guardArgs = $iverilogArgs + @("-s", "tb_motorsentinel_guard", "-o", $guardImage)

& iverilog @guardArgs `
    (Join-Path $repoRoot "rtl/motorsentinel_protocol_guard.sv") `
    (Join-Path $repoRoot "rtl/motorsentinel_safety_policy.sv") `
    (Join-Path $repoRoot "rtl/motorsentinel_guard_apb.sv") `
    (Join-Path $repoRoot "tb/tb_motorsentinel_guard.sv")

if ($LASTEXITCODE -ne 0) {
    throw "Icarus Verilog compilation failed with exit code $LASTEXITCODE"
}

Push-Location $repoRoot
try {
    & vvp $guardImage
    if ($LASTEXITCODE -ne 0) {
        throw "Safety-kernel simulation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$featureArgs = $iverilogArgs + @(
    "-Wno-sensitivity-entire-array",
    "-s", "tb_motorsentinel_feature_extractor",
    "-o", $featureImage
)

& iverilog @featureArgs `
    (Join-Path $repoRoot "rtl/motorsentinel_feature_extractor.sv") `
    (Join-Path $repoRoot "tb/tb_motorsentinel_feature_extractor.sv")

if ($LASTEXITCODE -ne 0) {
    throw "Feature-extractor compilation failed with exit code $LASTEXITCODE"
}

Push-Location $repoRoot
try {
    & vvp $featureImage
    if ($LASTEXITCODE -ne 0) {
        throw "Feature-extractor simulation failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
