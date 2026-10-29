# APB register map

Milestone 1 exposes a zero-wait-state APB3 slave with an 8-bit local address.
The final system base address will be assigned by Libero SmartDesign and then
exported to the Linux device tree.

| Offset | Name | Access | Definition |
| ---: | --- | --- | --- |
| `0x00` | `ID_VERSION` | RO | `0x4d53_0100` (`MS`, interface v1.0) |
| `0x04` | `CONTROL` | RW/W1P | bit 0 enable, bit 1 clear, bit 2 arm, bit 3 disarm, bit 4 monitor-only |
| `0x08` | `STATUS` | RO | ready, model-valid, window-valid, trip, data-valid, monitor-only, bus-healthy, motor-enable |
| `0x0c` | `IRQ_STATUS` | RW1C | trip, accepted clear, rejected clear, protocol fault |
| `0x10` | `IRQ_ENABLE` | RW | masks corresponding `IRQ_STATUS` bits |
| `0x14` | `SAMPLE_CFG` | RW | missing-sample timeout in microseconds; zero disables it |
| `0x18` | `BUS_TIMEOUT` | RW | `[15:0]` stretch timeout and `[31:16]` stuck-line timeout, in microseconds |
| `0x1c` | `ANOM_THRESHOLD` | RW | unsigned L1 reconstruction-error threshold |
| `0x20` | `POLICY_CFG` | RW | anomaly confirmations, recovery windows, NACK limit |
| `0x34` | `ANOM_SCORE` | RO | latest accelerator score |
| `0x38` | `FAULT_VECTOR` | RO | latched fault causes |

## Bit definitions

`STATUS`:

| Bit | Meaning |
| ---: | --- |
| 0 | Core ready |
| 1 | Model valid |
| 2 | Window-valid input is asserted |
| 3 | Safety trip latched |
| 4 | Current inference data is valid |
| 5 | Monitor-only mode |
| 6 | Synchronized I2C bus is idle and healthy |
| 7 | Active-high motor enable output |
| 8 | Motor output is armed |

`FAULT_VECTOR`:

| Bit | Meaning |
| ---: | --- |
| 0 | SCL stuck low |
| 1 | SDA stuck low |
| 2 | Excessive clock stretching |
| 3 | Consecutive NACK limit |
| 4 | Missing-sample timeout |
| 5 | Unexpected START/unowned bus activity |
| 6 | Physical-limit fault |
| 7 | Internal pipeline/FIFO fault |
| 8 | Core enabled without a valid committed model |
| 9 | Confirmed learned anomaly |

The fault vector and trip latch cannot be erased by a normal register write. A
`CONTROL.clear` request is accepted only when the configured number of healthy
windows has elapsed, the model is valid, and the I2C bus is idle. Clearing a
trip never restarts the motor: software must issue a separate `CONTROL.arm`
pulse after recovery.

## Data-plane extension (`motorsentinel_core_apb`, offsets `0x40`-`0xff`)

The integrated core occupies the same 256-byte APB slot. Offsets `0x00`-`0x3f`
are routed unchanged to the verified safety kernel above; the extension adds
the data plane. FAULT_VECTOR bit 6 is driven by the sensor-integrity monitor,
and bit 7 by a dropped (overrun) sample.

| Offset | Name | Access | Definition |
| ---: | --- | --- | --- |
| `0x40` | `CORE_ID` | RO | `0x4d53_0300` (data plane v3.0) |
| `0x44` | `CORE_CONTROL` | RW | bit 0 sample source: 0 = acquisition port, 1 = APB injection |
| `0x48` | `INJECT_XY` | RW | `[15:0]` X and `[31:16]` Y of the next injected sample |
| `0x4c` | `INJECT_Z` | WO | `[15:0]` Z; the write pushes one injected sample |
| `0x50` | `MODEL_CMD` | W1P | bit 0 begin load (invalidates model), bit 1 commit |
| `0x54` | `MODEL_DATA` | WO | next 32-bit word of the 122-word model image |
| `0x58` | `MODEL_CRC` | RW | expected IEEE CRC-32 of the image |
| `0x5c` | `MODEL_STATUS` | RO | bit 0 valid, bit 1 loading, `[12:8]` errors, `[23:16]` words written |
| `0x60` | `MODEL_CRC_ACTUAL` | RO | CRC-32 computed by hardware over the words written |
| `0x64` | `INTEGRITY_LIMITS` | RW | `[15:0]` range limit, `[31:16]` slew limit (LSB; 0 disables) |
| `0x68` | `INTEGRITY_CFG` | RW | `[7:0]` frozen run length, `[15:8]` replay hits per 128-sample block |
| `0x6c` | `INTEGRITY_STATUS` | RW1C/RO | `[4:0]` sticky causes, `[15:8]` replay hits in last block |
| `0x70` | `WINDOW_COUNT` | RO | completed inferences since reset |
| `0x74` | `LAST_SEQUENCE` | RO | window sequence number of the latest decision |
| `0x78` | `LATENCY` | RO | `[15:0]` last, `[31:16]` worst cycles from window-closing sample to policy decision |
| `0x7c` | `INFERENCE_STATUS` | RO | `[11:0]` last score, 16 frozen active, 17 engine busy, `[19:18]` queued windows, 20 data path ready |
| `0x80`-`0xbc` | `FEATURE[0..15]` | RO | raw 32-bit features of the latest inferred window |
| `0xc0`-`0xcc` | `Q[0..3]` | RO | 16 normalized INT8 inputs, four per word, lane 0 in bits `[7:0]` |
| `0xd0`-`0xdc` | `Y[0..3]` | RO | 16 INT8 reconstructions, packed as `Q` |
| `0xe0`-`0xe4` | `H[0..1]` | RO | 8 INT8 hidden activations, packed as `Q` |

Default integrity limits after reset: range 4000 LSB, slew 1024 LSB, frozen
run 32 samples, replay threshold 16 hits per block.

`MODEL_STATUS` error bits (valid after commit):

| Bit | Meaning |
| ---: | --- |
| 8 | CRC mismatch |
| 9 | Image length is not 122 words |
| 10 | Format word is not `0x4d41_0001` |
| 11 | A normalizer shift, layer shift or bias is out of range |
| 12 | Write without `begin`, write past the image, or commit without `begin` |

`INTEGRITY_STATUS` cause bits:

| Bit | Meaning |
| ---: | --- |
| 0 | Axis magnitude above range limit |
| 1 | Sample-to-sample step above slew limit |
| 2 | Bit-identical X/Y/Z run reached the frozen limit |
| 3 | Replayed 16-sample sequences reached the per-block hit threshold |
| 4 | Sample offered while the data path was not ready (dropped) |

After `CONTROL.enable`, the integrity monitor clears its 1024-entry replay table
for 1024 cycles (20.5 us at 50 MHz). Software that injects samples polls
`INFERENCE_STATUS` bit 20 before the first write.

### Model load sequence

1. Write `MODEL_CMD = 1`. The model becomes invalid; an enabled core trips and
   the motor is disabled.
2. Write the 122 image words from `model/edgematrix.py:model_image()` in order
   to `MODEL_DATA`.
3. Write the expected CRC-32 to `MODEL_CRC`, then `MODEL_CMD = 2`.
4. Check `MODEL_STATUS` bit 0; recover and re-arm through `CONTROL` as usual.
