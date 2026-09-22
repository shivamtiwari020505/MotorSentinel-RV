# Bit-exact feature contract

Milestone 2 fixes the numerical meaning of every accelerator input before model
training begins. The Python model and SystemVerilog implementation use only
integer operations and must agree exactly for every signed 16-bit input.

## Stream and window definition

- Input: signed 16-bit X, Y, and Z accelerometer samples.
- Nominal rate: 800 samples/s.
- Window: 256 accepted samples (320 ms).
- Hop: 128 accepted samples (160 ms), giving 50% overlap.
- A sample is accepted only when `sample_valid_i && sample_ready_o` is true.

Two accumulator contexts alternate starts every 128 samples. Each context owns
a 256x48 sample memory so exact mean-centered zero crossings can be computed in
a short post-pass. Completed vectors enter a two-entry result queue and are
serialized as 16 indexed 32-bit words. Input readiness is removed during the
post-pass or before a result could be lost.

## Feature order

| Index | Feature | Exact integer definition | Output width |
| ---: | --- | --- | ---: |
| 0-2 | Axis mean X/Y/Z | arithmetic `sum >> 8`; negative values round toward negative infinity | signed 16 bit |
| 3-5 | Mean-square X/Y/Z | `sum(sample * sample) >> 8` | unsigned 31 bit |
| 6-8 | Peak-to-peak X/Y/Z | `maximum - minimum` | unsigned 16 bit |
| 9-11 | Exact DC-centered zero crossings X/Y/Z | sign transitions around the exact window mean; centered zeros are ignored | unsigned 8 bit |
| 12 | Haar energy, nominal 25-50 Hz | L8 raw energy divided by `8192` | unsigned 31 bit |
| 13 | Haar energy, nominal 50-100 Hz | L4 raw energy divided by `4096` | unsigned 31 bit |
| 14 | Haar energy, nominal 100-200 Hz | L2 raw energy divided by `2048` | unsigned 31 bit |
| 15 | Haar energy, nominal 200-400 Hz | L1 raw energy divided by `1024` | unsigned 31 bit |

For half-length `L`, each non-overlapping `2L`-sample block and axis produces:

```text
detail = sum(first L samples) - sum(second L samples)
```

The raw energy is the sum of `detail * detail` over all blocks and all three
axes. The published feature divides it by `2 * 256 * (2L)`, using an exact right
shift. L1 represents the highest-frequency scale; L8 represents the lowest.
This Haar filter bank is the concrete implementation of the proposal's four
band-energy features. The frequency labels are approximate nominal bands at
800 samples/s; the Haar responses overlap and are not brick-wall filters.

For exact zero crossings, the post-pass evaluates `c[n] = 256*x[n] - sum(x)`.
This is proportional to `x[n] - exact_window_mean` without division. Values
where `c[n] == 0` are ignored; every sign change between successive nonzero
values increments the count. No crossing is counted across window boundaries.

Mean outputs use signed two's-complement 32-bit encoding. Every other feature is
nonnegative and fits signed 32 bits. The accumulator widths cover the
mathematical worst case, so valid INT16 inputs neither wrap nor saturate.
Per-feature affine normalization and INT8 saturation belong to the later model
loading/inference stage.

The RTL uses signed 24-bit axis sums, unsigned 39-bit square sums, signed
20-bit Haar half-sums, signed 21-bit Haar differences, unsigned 48-bit raw Haar
accumulators, and signed 25-bit centered values. These widths include the full
INT16 worst case.

## Output protocol

`feature_valid_o` holds the current feature stable until `feature_ready_i` is
asserted. `feature_index_o` runs from 0 through 15, `feature_last_o` marks index
15, and `window_sequence_o` identifies the window beginning with sequence zero.
The consumer must use the valid/ready handshake; it may apply arbitrary
backpressure without corrupting queued vectors.
