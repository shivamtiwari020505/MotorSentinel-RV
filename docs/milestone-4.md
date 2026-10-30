# Milestone 4: ADXL345 I2C acquisition, pins to motor

This milestone replaces the last behavioral input of the data plane with
synthesizable acquisition logic. `motorsentinel_top` now runs from the
accelerometer's open-drain SCL/SDA pins all the way to the motor-enable pin,
with no software in the loop.

## Implemented

### ADXL345 reader (`rtl/motorsentinel_adxl345_reader.sv`)

- Open-drain I2C master: `scl_drive_low_o` and `sda_drive_low_o` only ever
  pull a line low; the board pull-ups release it.
- Fast-mode timing derived from `CLK_HZ`: SCL low >= 1.4 us, high >= 0.7 us,
  START/STOP setup and hold >= 0.7 us, data setup >= 100 ns and a bus-free
  time of 1.4 us before every START. At 50 MHz this gives about 382 kHz.
- Clock stretching: every SCL release waits until the line reads high.
- Bring-up: reads DEVID and requires `0xE5`, then writes
  `POWER_CTL=0x00` (standby), `BW_RATE=0x0D` (800 Hz), `DATA_FORMAT=0x0B`
  (full resolution, +/-16 g, 256 LSB/g; this matches the model's training
  scale), `INT_MAP=0x00`, `INT_ENABLE=0x80` (DATA_READY on INT1) and finally
  `POWER_CTL=0x08` (measure).
- Streaming: one six-byte burst (`DATAX0`..`DATAZ1`) per sample, triggered
  by DATA_READY on INT1, or by an internal 800 Hz timer when INT1 is not
  wired (`CORE_CONTROL` bit 1 selects the mode). A burst takes 222 us, which
  is 18 % of the 1.25 ms sample period.
- Fault handling: a NACK aborts with a STOP, pulses `sample_nack_o` to the
  protocol guard and re-initializes the sensor after 100 us. A wrong device
  ID is reported and re-polled once per sample period.
- Bus ownership: `master_active_o` is asserted only from the reader's own
  START until the end of its STOP and bus-free time. A line held low by
  another device is therefore never mistaken for the reader's traffic, and
  the protocol guard flags it.

### Top level (`rtl/motorsentinel_top.sv`)

The reader feeds the existing `motorsentinel_core_apb` sample port and its
bus-status inputs. The protocol guard observes the same pad inputs as the
reader, so bus attacks are detected independently of the acquisition logic.
Two read-only registers expose acquisition state to Linux: `ACQ_STATUS`
(`0xE8`) and `ACQ_SAMPLES` (`0xEC`), described in the
[register map](register-map.md).

## Verification

### Reader unit test (`tb/tb_adxl345_reader.sv`, 20 checks)

The bench uses an independent behavioral ADXL345 (`tb/adxl345_i2c_model.sv`)
with a register file, auto-increment, coherent multi-byte data reads,
DATA_READY, and a framing checker. It verifies:

| Check | Result |
| --- | --- |
| DEVID check and all six configuration writes | pass |
| 69 samples, including signed extremes, bit-exact | pass |
| I2C Fast-mode timing monitor (tLOW, tHIGH, tSU;STA, tHD;STA, tSU;STO, tBUF, tSU;DAT) | 0 violations; min tLOW 1.44 us, min tHIGH 1.18 us |
| Sensor stretches SCL by 5 us per byte | samples still exact |
| Address NACK | reported, sensor re-initialized, no sample lost |
| Wrong DEVID | flagged, nothing streamed, recovers when the right sensor answers |
| SDA held low by another device | master never claims the bus; resumes after release |
| Timer mode without DATA_READY | 8 ± 1 samples per 10 ms window (800 samples/s) |
| START/STOP never inside a byte | pass |

### Pins-to-motor integration (`tb/tb_motorsentinel_top.sv`, 12 checks)

The behavioral sensor serves the healthy-motor scenario stream on the real
SCL/SDA pins. The bench loads the model over APB, arms the motor and checks
that:

- both window anomaly scores, computed from samples read over I2C, match the
  Python reference bit-exactly;
- real I2C traffic produces no protocol, integrity or anomaly fault, and the
  missing-sample watchdog stays quiet;
- every acquired sample reaches the data plane, with no overrun;
- a NACK storm on the real bus disables the motor with the NACK-limit fault;
- SDA held low by a rogue device disables the motor with a stuck-line or
  rogue-bus fault.

The integration bench runs the fabric at 4 MHz to keep simulation short. The
reader derives every I2C interval from `CLK_HZ`, so the protocol behavior is
the same as at 50 MHz; the 50 MHz timing is checked in the unit test.

## Board connection

| Signal | Connection |
| --- | --- |
| SCL, SDA | Fabric BIBUF pads, `D` tied low, `E` = `*_drive_low_o`, `Y` = `*_i`; pull-ups on the sensor board |
| INT1 | Fabric input to `adxl_int1_i` (optional; use timer mode if not wired) |
| CS, SDO/ALT | CS high selects I2C; SDO/ALT low selects address `0x53` |

## Verification boundary

This is RTL simulation against a behavioral sensor model. Electrical
behavior, pad configuration, rise times with the real pull-ups and a physical
ADXL345 still have to be confirmed on the Icicle Kit.

## Next milestone

1. Libero SoC Tcl overlay: instantiate `motorsentinel_top` on CoreAPB3
   slot 6, assign pins, and report utilization and timing.
2. Linux UIO driver and model loader using `sw/include/motorsentinel_regs.h`.
3. Bring-up on hardware with a real ADXL345 and the demonstration motor.
