# Libero SoC build

`fpga/libero/build_motorsentinel.tcl` builds the complete fabric data plane,
`motorsentinel_top`, for the Icicle Kit's PolarFire SoC through synthesis,
place and route and static timing analysis. It measures the design's real
utilization and 50 MHz timing before the overlay into the Icicle reference
design.

## Status

The script and constraints are written, and checked in a dry run with every
Libero command stubbed out. The dry run confirms the Tcl syntax, the step
order, that all 13 sources and the constraints file are found, and that a
missing file stops the build with a clear error. **It has not yet run in
Libero**, so there are no utilization or timing numbers yet; they will be
published from the first real run.

## Requirements

- Libero SoC 2025.2 (the version pinned in
  [the Icicle integration baseline](icicle-integration.md)), with a license
  that covers the MPFS250T.
- Python 3 for the report summary.

## Run

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_libero.ps1
# or, if libero.exe is not found automatically:
powershell -ExecutionPolicy Bypass -File .\scripts\run_libero.ps1 -Libero "C:\Microchip\Libero_SoC_2025.2\Designer\bin\libero.exe"
```

Linux:

```sh
make libero                 # uses `libero` on PATH
make libero LIBERO=/opt/microchip/Libero_SoC_2025.2/Libero/bin/libero
```

The project is recreated in `build/libero/motorsentinel` on every run. The
full Libero log is `build/libero/libero.log`, and `build/libero/summary.md`
collects the resource-usage table and the timing-slack lines copied verbatim
from Libero's reports.

## What the build contains

| Setting | Value |
| --- | --- |
| Device | MPFS250T, FCVG484, STD speed, 1.05 V, extended range (Icicle Kit) |
| Top level | `motorsentinel_top` (ADXL345 reader and integrated core) |
| HDL | SystemVerilog, linked from `rtl/` (not copied) |
| Flow | Synthesize, place and route, verify timing |
| Constraints | `fpga/constraints/motorsentinel_top.sdc` |

The constraints define one 50 MHz clock (`PCLK`, the reference design's FIC3
APB clock). They exclude the asynchronous SCL, SDA and INT1 inputs, which
enter through two-flop synchronizers, and the reset, which is released
synchronously by `CORERESET_PF` in the integrated design. Because this is a
standalone build, the APB bus and sensor pins become device I/Os with
automatic placement. The APB ports get a half-period I/O budget, since in the
integrated design they are an internal connection in the same clock domain.

## Paths to watch in the first timing report

These single-cycle paths are the most likely to set the critical path at
50 MHz:

- the INT8 normalizer: 33x16 multiply, rounding, a variable shift of up to
  47 bits and saturation (`motorsentinel_inference`);
- the feature extractor's per-sample update: three 21-bit squares per Haar
  band and the accumulator adds (`motorsentinel_feature_extractor`);
- the autoencoder's bias, requantization and 16-term L1 score
  (`edgematrix_autoencoder`).

Each one can take an extra pipeline register without changing behavior. The
data plane has thousands of idle cycles between samples, so added latency
does not matter, and the bit-exact regression would confirm the result is
unchanged.

## Next: Icicle reference-design overlay

After the standalone build closes timing, a second script will source the
Icicle reference design (tag `v2026.04`) and then:

1. instantiate `motorsentinel_top` in the top SmartDesign;
2. connect its APB slave to CoreAPB3 slot 6 on FIC3, `PCLK` to `FIC_3_CLK`
   and `PRESETn` to `RESETN_FIC_3_CLK`;
3. route `irq_o` to a free `MSS_INT_F2M` input;
4. add BIBUF pads for SCL and SDA (`D` tied low, `E` from `*_drive_low_o`,
   `Y` to `*_i`) and assign the sensor, INT1 and motor pins in a PDC file.
