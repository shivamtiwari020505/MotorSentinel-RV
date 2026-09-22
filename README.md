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

Two simulation-verified milestones are now implemented:

- **Milestone 1:** APB-controlled protocol monitoring, deterministic safety
  policy, latched fault provenance, interrupts, recovery interlock, and explicit
  motor arm/disarm control.
- **Milestone 2:** bit-exact 256-sample/128-hop feature extraction with mean,
  mean-square, peak-to-peak, exact mean-centered zero crossings, and four Haar
  band energies.

See [Milestone 1](docs/milestone-1.md) and the
[Milestone 2 feature pipeline](docs/milestone-2.md), plus the
[bit-exact feature contract](docs/feature-contract.md), for the implemented
behavior. The [APB register map](docs/register-map.md) defines the control
plane, while the
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

The test runs Python unit tests, regenerates deterministic golden vectors, and
runs both self-checking RTL simulations. Use `make waves` for the safety-kernel
waveform, `make feature-waves` for the feature pipeline, or add `-Waves` to the
PowerShell command for both. GitHub Actions runs the same regression on every
push and pull request.

## Repository layout

```text
rtl/       synthesizable SystemVerilog
tb/        self-checking testbenches
scripts/   local verification entry points
sw/        RISC-V software interface definitions
model/     bit-exact Python reference models
tools/     deterministic vector and build utilities
tests/     analytic reference-model tests
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
