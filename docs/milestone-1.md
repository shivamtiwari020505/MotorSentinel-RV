# Milestone 1: deterministic safety-path baseline

This milestone converts the proposal's safety behavior into synthesizable and
self-checking RTL before sensor acquisition and neural inference are attached.

## Implemented

- APB3 control/status interface suitable for an MSS FIC peripheral slot.
- Two-flop synchronization of external I2C lines.
- Microsecond-based SCL/SDA stuck-low and clock-stretch watchdogs.
- Missing-sample, consecutive-NACK, and unowned-START detection.
- Consecutive-window anomaly confirmation.
- Latched protocol, physical, internal, model-validity, and learned faults.
- Hardware recovery gate requiring four healthy windows and an idle bus by
  default.
- Separate arm/disarm commands so clearing a trip cannot restart the motor.
- Active-high fail-safe motor output and an explicit monitor-only diagnostic
  mode.
- Sticky, maskable interrupt causes with write-one-to-clear handling.
- A self-checking simulation covering reset, APB access, invalid-model startup,
  learned anomaly confirmation, premature recovery rejection, NACK storms,
  stuck SDA, clock stretching, monitor-only operation, and IRQ clearing.

## Clocking contract

The APB interface, acquisition events, safety policy, and output currently use
one clock. The default is 50 MHz to match the Icicle reference design's FIC3
clock. I2C pins are synchronized inside the protocol guard. When the accelerator
moves to the 125 MHz fabric compute domain, an explicit command handshake and
event FIFO will be added at the integration boundary; the safety path will stay
entirely in the acquisition domain.

## Next milestone

1. Freeze bit-exact Python definitions for the 256-sample feature windows.
2. Implement overlapping fixed-point accumulators and golden-vector tests.
3. Integrate the signed INT8 8x8 matrix engine and `16 -> 8 -> 16`
   autoencoder scheduler.
4. Add atomic model staging/commit and a model CRC.
5. Package the verified RTL as a Libero component and connect it through FIC3.

No board timing, utilization, power, or detection-performance claim is made by
this milestone; those require Libero synthesis and Icicle Kit measurements.
