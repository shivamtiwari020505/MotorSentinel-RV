param(
    [switch]$Waves
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot "build"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Invoke-RtlTest {
    param(
        [string]$Top,
        [string[]]$Sources,
        [string[]]$ExtraArgs = @()
    )
    $image = Join-Path $buildDir "$Top.vvp"
    $compileArgs = @("-g2012", "-Wall") + $ExtraArgs
    if ($Waves) {
        $compileArgs += "-DDUMP_WAVES"
    }
    $compileArgs += @("-s", $Top, "-o", $image)
    $paths = $Sources | ForEach-Object { Join-Path $repoRoot $_ }

    Invoke-Checked "$Top compilation" { & iverilog @compileArgs @paths }
    Push-Location $repoRoot
    try {
        Invoke-Checked "$Top simulation" { & vvp $image }
    }
    finally {
        Pop-Location
    }
}

Push-Location $repoRoot
try {
    Invoke-Checked "Python model tests" { & python -m unittest discover -s tests -v }
    Invoke-Checked "Feature-vector generation" {
        & python tools/generate_feature_vectors.py --output-dir $buildDir
    }
    Invoke-Checked "System-vector generation" {
        & python tools/generate_system_vectors.py --output-dir $buildDir
    }
}
finally {
    Pop-Location
}

$guardRtl = @(
    "rtl/motorsentinel_protocol_guard.sv",
    "rtl/motorsentinel_safety_policy.sv",
    "rtl/motorsentinel_guard_apb.sv"
)
$featureRtl = @("rtl/motorsentinel_feature_extractor.sv")
$engineRtl = @(
    "rtl/edgematrix_pe.sv",
    "rtl/edgematrix_array.sv",
    "rtl/edgematrix_autoencoder.sv",
    "rtl/motorsentinel_model_store.sv",
    "rtl/motorsentinel_inference.sv"
)
$coreRtl = $engineRtl + @("rtl/motorsentinel_integrity_monitor.sv") +
    $featureRtl + $guardRtl + @("rtl/motorsentinel_core_apb.sv")
$quiet = @("-Wno-sensitivity-entire-array")

Invoke-RtlTest "tb_motorsentinel_guard" ($guardRtl + @("tb/tb_motorsentinel_guard.sv"))
Invoke-RtlTest "tb_motorsentinel_feature_extractor" `
    ($featureRtl + @("tb/tb_motorsentinel_feature_extractor.sv")) $quiet
Invoke-RtlTest "tb_edgematrix_inference" `
    ($engineRtl + @("tb/tb_edgematrix_inference.sv")) $quiet
Invoke-RtlTest "tb_motorsentinel_core" `
    ($coreRtl + @("tb/tb_motorsentinel_core.sv")) $quiet

$readerRtl = @("rtl/motorsentinel_adxl345_reader.sv")
$sensorModel = @("tb/adxl345_i2c_model.sv")
Invoke-RtlTest "tb_adxl345_reader" `
    ($readerRtl + $sensorModel + @("tb/tb_adxl345_reader.sv")) $quiet
Invoke-RtlTest "tb_motorsentinel_top" `
    ($coreRtl + $readerRtl + @("rtl/motorsentinel_top.sv") + $sensorModel +
     @("tb/tb_motorsentinel_top.sv")) $quiet
