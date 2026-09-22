# Milestone 2: bit-exact overlapping feature pipeline

This milestone implements the complete 16-feature transform that feeds the
future INT8 autoencoder. The arithmetic is frozen in a pure-Python reference
model and matched bit-for-bit by synthesizable SystemVerilog.

## Implemented

- Three signed 16-bit sample inputs with a valid/ready contract.
- Two accumulation contexts for 256-sample windows starting every 128 accepted
  samples.
- Axis mean, mean-square, peak-to-peak, and exact mean-centered zero crossings.
- Four scaled three-axis Haar-band energies covering approximate dyadic bands
  from 25 Hz through 400 Hz at the 800-sample/s input rate.
- Two private 256x48 sample stores and a 257-cycle post-pass for exact
  zero-crossing calculation.
- A two-window result FIFO and backpressure-safe 16x32 serializer.
- Reset/disable flushing of incomplete windows without clearing RAM contents.
- Pure-standard-library Python oracle, deterministic vector generator, and
  ten analytic unit tests.
- RTL differential regression covering seven overlapping windows, 112 exact
  feature values, signed extrema, all four Haar scales, exact zero-crossing
  edge cases, input-valid gaps, stalls on every output lane, a full result
  queue, post-pass input backpressure, and partial-window flushing.

The detailed lane order, formulas, rounding behavior, and width proofs are in
[the feature contract](feature-contract.md).

## Timing behavior

At 50 MHz, the exact zero-crossing scan occupies 257 clocks, approximately
5.14 microseconds. The ADXL345 I2C design provides 1.25 milliseconds between
samples at 800 samples/s, so the post-pass has substantial scheduling margin.
The source must still obey `sample_ready_o`; a future clock-domain boundary or
pulse-only producer will use a complete 48-bit asynchronous FIFO.

## Verification boundary

The current evidence proves behavioral equivalence in Icarus Verilog. It does
not yet prove PolarFire LSRAM or math-block inference, placed timing, resource
utilization, or board operation. Those measurements will be produced with the
pinned Libero/Icicle flow rather than estimated.

## Next milestone

1. Import the verified signed-INT8 processing elements under their MIT license.
2. Add bias, deterministic requantization, ReLU, and saturation stages.
3. Schedule the `16 -> 8 -> 16` autoencoder as four 8x8 matrix tiles.
4. Calculate the 12-bit L1 reconstruction score and connect it to the existing
   safety policy.
5. Add atomic model staging, CRC validation, and APB feature/model access.
