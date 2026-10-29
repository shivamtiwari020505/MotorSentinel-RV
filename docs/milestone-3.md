# Milestone 3: EdgeMatrix-RV inference, sensor integrity and end-to-end safety

This milestone closes the loop from accelerometer samples to the motor-enable
pin. Every stage is synthesizable SystemVerilog checked bit-for-bit against a
standard-library Python reference, and the complete system is exercised with
nine mechanical-fault and sensor-attack scenarios.

![Implemented data plane](MotorSentinel-RV_System_Block_Diagram.png)

## Implemented

### EdgeMatrix-RV INT8 autoencoder

- `rtl/edgematrix_pe.sv` and `rtl/edgematrix_array.sv`: the signed-INT8
  weight-stationary 8x8 systolic array imported from the author's verified
  [SystolicForge NPU](https://github.com/shivamtiwari020505/systolicforge-npu)
  (MIT).
- `rtl/edgematrix_autoencoder.sv`: schedules the `16 -> 8 -> 16` network as
  four 8x8 weight tiles, then applies bias, round-half-up requantization, ReLU,
  INT8 saturation and a 12-bit L1 reconstruction score. Latency is fixed at
  **74 cycles (1.48 us at 50 MHz)** from the last feature to the score.
- `rtl/motorsentinel_inference.sv`: normalizes each serialized 32-bit feature
  to INT8 as it streams (`(f - offset) * scale >> shift`, saturated), starts
  the engine on the last word and publishes a consistent snapshot of raw
  features, `q`, `h` and `y` for software.

### Trained, quantized model

- `tools/train_autoencoder.py` simulates 96 healthy motors with randomized
  speed (±12 %), imbalance, harmonics, noise and ±3° mounting tilt, calibrates
  per-feature normalization, trains a ReLU autoencoder from a sign-split PCA
  initialization and quantizes it to the hardware contract. Training is seeded
  and reproduces the committed model byte-for-byte.
- **Bounded latent space.** Every hidden unit is rescaled so its healthy peak
  sits at 100 of 127 INT8 counts. ReLU is positive-homogeneous, so the float
  network is unchanged, but INT8 saturation then stops the decoder from
  extrapolating along healthy directions. Before this change, a 3x imbalance
  was reconstructed well enough to score *below* the threshold. After it, the
  weakest anomaly scores 2.8x the threshold.
- The threshold (118) is set only from 480 held-out healthy windows. Across
  100 further unseen healthy runs, the worst healthy score was 51.
- `model/weights/motorsentinel_ae_v1.json` is the committed integer model
  (image CRC-32 `0x32253a25`).

### CRC-protected model store

`rtl/motorsentinel_model_store.sv` accepts the 122-word image over APB,
computes IEEE CRC-32 in hardware one word per cycle and commits only if the
length, CRC, format word and every shift/bias range are correct. A load
invalidates the model first, so the policy trips and the motor stays off until
a verified model is committed.

### Sensor-integrity monitor

`rtl/motorsentinel_integrity_monitor.sv` checks every accepted sample for:

| Check | Catches | Mechanism |
| --- | --- | --- |
| Range | clipping, injected rails | any axis magnitude above a limit |
| Slew | spike injection, glitches | any axis step above a limit |
| Frozen | stuck or held sensor value | run of bit-identical X/Y/Z samples |
| Replay | looped recordings | 16-sample rolling hash + 1024-entry tag RAM |

Replay detection is the key addition. A replayed recording of *healthy* data
is statistically healthy, so the autoencoder cannot see it: in the regression
its highest score is 55, against a threshold of 118. The monitor folds each
sample into a 32-bit word and maintains the cyclic-polynomial hash
`H[n] = XOR_k rotl(s[n-k], k)` using only rotates and XORs. Exact 16-sample,
three-axis repeats essentially never occur in noisy sensor data, but a replay
produces a burst of table hits wherever its loop boundary falls. The 600-sample
loop in the regression is deliberately not a multiple of the 128-sample hop.

### Integrated top level

`rtl/motorsentinel_core_apb.sv` combines the safety kernel, feature
extractor, integrity monitor, model store and inference engine behind one
256-byte APB3 slot. The Milestone 1 kernel is reused without behavioral
changes; it only gained an `enable_o` observation port. The extension adds APB
sample injection, so Linux can replay recorded data through the identical
hardware path for a CPU-versus-FPGA comparison. It also adds latency
instrumentation and inference telemetry. See the
[register map](register-map.md).

## Results (RTL simulation, Icarus Verilog)

`tb/tb_motorsentinel_core.sv` resets the core, loads the model over APB with
a hardware CRC match, arms the motor and streams 2,816 samples per scenario.
The fault or attack starts at sample 1,536. Every window score is compared
bit-exactly with Python, along with the trip sample, latched fault vector,
integrity causes and final motor state.

| Scenario | Max score | Motor disabled at sample | Detection time | Fault vector | Detected by |
| --- | ---: | ---: | ---: | ---: | --- |
| Healthy operation | 69 | never | - | `0x000` | (no false trip) |
| 3x rotor imbalance | 751 | 1,792 | 320 ms | `0x200` | autoencoder |
| Outer-race bearing fault | 509 | 1,792 | 320 ms | `0x200` | autoencoder |
| +120 LSB bias injection | 466 | 1,792 | 320 ms | `0x200` | autoencoder |
| Noise injection | 1,001 | 1,792 | 320 ms | `0x200` | autoencoder |
| Frozen sensor value | 384 | 1,567 | 38.75 ms | `0x240` | frozen + replay, then autoencoder |
| Replay of healthy recording | 55 | 1,664 | 160 ms | `0x040` | **replay hash only** |
| Spike injection | 656 | 1,537 | 1.25 ms | `0x240` | slew limit |
| I2C NACK storm | 51 | 1,536 | immediate | `0x008` | protocol guard |

Detection time is measured in sample time at 800 samples/s, from attack onset
to motor disable. Learned anomalies need two consecutive windows above the
threshold, which takes 320 ms here; `POLICY_CFG` can trade that confirmation
against false-trip immunity. The worst-case hardware compute time from the
window-closing sample to the safety decision is **348 cycles (6.96 us at
50 MHz)**. That covers the 257-cycle exact zero-crossing post-pass, the 16-word
feature transfer and the 74-cycle inference, and none of it depends on Linux.

Additional directed checks:

- the model store rejects a wrong CRC, a corrupted weight word, a truncated
  image and a wrong format word;
- 96 random and extreme feature vectors match `q`, `h`, `y` and the score
  bit-exactly;
- APB-injected samples reproduce the streamed decision exactly;
- a sample dropped during the window post-pass trips the internal-fault path;
- the safety invariants (trip implies motor off; invalid model implies motor
  off) are asserted on every clock edge of every test.

## Verification boundary

These results come from RTL simulation with synthetic vibration data from
`model/motor_sim.py`. They do not yet include PolarFire synthesis, placed
timing, utilization, power, or measurements from a real motor. The model and
threshold will be retrained on recorded Icicle Kit data with the same tools.
The model is currently held in about 3.7 k flip-flops so that a full 8x8 tile
can load in one cycle; moving it to LSRAM is an option if Libero utilization
calls for it.

## Next milestone

1. ADXL345 I2C acquisition sequencer driving the existing sample port and
   protocol-guard status inputs.
2. Libero SoC 2025.2 Tcl overlay: package `motorsentinel_core_apb` on CoreAPB3
   slot 6, connect `irq_o`, then report utilization and timing.
3. Linux UIO driver and model loader using `sw/include/motorsentinel_regs.h`.
4. RP2040 attack emulator for live demonstrations, and PAC1934 energy-per-window
   measurements.
