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
