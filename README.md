# MotorSentinel-RV

[![RTL verification](https://github.com/shivamtiwari020505/MotorSentinel-RV/actions/workflows/rtl.yml/badge.svg)](https://github.com/shivamtiwari020505/MotorSentinel-RV/actions/workflows/rtl.yml)

MotorSentinel-RV is an attack-resilient predictive-maintenance architecture for
industrial motors, targeting **Track 2 - Connected Real-Time Systems** on the
**PolarFire SoC Icicle Kit**.

The design places sensor-bus monitoring, fixed-point feature extraction, INT8
autoencoder inference, and the final safety decision in FPGA fabric. PolarFire
SoC RISC-V software will manage models, telemetry, visualization, and the CPU
comparison path without being part of the time-critical motor-disable path.

## Current implementation

Milestone 1 provides a synthesizable, APB-controlled vertical slice of the
deterministic safety path:

- protected I2C watchdogs for stuck lines, clock stretching, NACK storms,
  missing samples, and unexpected bus activity;
- consecutive-window anomaly confirmation;
- latched fault provenance and fail-safe motor control;
- recovery interlock requiring healthy windows and an idle bus;
- sticky maskable interrupts; and
- a self-checking RTL regression.

See [Milestone 1](docs/milestone-1.md) and the
[APB register map](docs/register-map.md) for the exact behavior. The
[Icicle integration baseline](docs/icicle-integration.md) pins the intended
Libero/reference-design flow.

## Run the RTL regression

Icarus Verilog 11 or newer is sufficient.

On Linux:

```sh
make test
```

On Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_rtl_tests.ps1
```

The test is self-checking. Use `make waves` on Linux or add `-Waves` to the
PowerShell command to write `build/motorsentinel_guard.vcd` for debug. GitHub
Actions runs the same regression on every push and pull request.

## Repository layout

```text
rtl/       synthesizable SystemVerilog
tb/        self-checking testbenches
scripts/   local verification entry points
sw/        RISC-V software interface definitions
docs/      architecture, interfaces, and proposal artifacts
```

## Proposed complete data path

1. Acquire signed X/Y/Z vibration samples at 800 samples/s over protected I2C.
2. Generate 16 fixed-point features from 256-sample, 50%-overlapped windows.
3. Run a quantized `16 -> 8 -> 16` autoencoder on an 8x8 INT8 matrix engine.
4. Combine protocol faults, physical limits, and reconstruction error in the
   FPGA safety policy.
5. Report events to Linux while the FPGA can disable the low-voltage
   demonstration motor independently.

## System architecture

[Download the system block diagram as PDF](docs/MotorSentinel-RV_System_Block_Diagram.pdf)

![MotorSentinel-RV system architecture](docs/MotorSentinel-RV_System_Block_Diagram.png)

This repository is under active development. Board-level timing, utilization,
power, and anomaly-detection results will be reported only after measurement on
the PolarFire SoC Icicle Kit.
