# Linux driver and control tool

The RISC-V Linux side configures the fabric and reports what it decides; it
is never in the motor-disable path. It is a user-space UIO driver, so it
needs no out-of-tree kernel module.

| Part | Path | Role |
| --- | --- | --- |
| `libmotorsentinel` | `sw/lib/motorsentinel.c`, `sw/include/motorsentinel.h` | Portable register-level API: identify, CRC-checked model load, configuration, start/arm/clear, events, telemetry, sample injection, fault decoding |
| UIO backend | `sw/lib/motorsentinel_uio.c` | Finds the UIO device named `motorsentinel`, maps it (the 256-byte slot is not page aligned), waits for interrupts |
| `msrvctl` | `sw/tools/msrvctl.c` | Command-line tool for bring-up, monitoring and replay |
| Device-tree overlay | `sw/linux/motorsentinel-overlay.dtso` | Binds the fabric core to `uio_pdrv_genirq` |
| Model file | `tools/export_model_bin.py` | Writes the 122-word image plus threshold (492 bytes) |

## Build

```sh
make -C sw CROSS_COMPILE=riscv64-linux-gnu-    # for the Icicle Kit
make -C sw                                     # native Linux build
python3 tools/export_model_bin.py              # build/motorsentinel_ae_v1.bin
make -C sw dtbo PLIC_IRQ=<n>                   # overlay; see below
```

`PLIC_IRQ` is the PLIC source number of the `MSS_INT_F2M` line that carries
`irq_o`. It comes from the integrated Libero design's memory map, so the
build refuses to guess it. The overlay's address, `0x4000_0600`, is the
provisional CoreAPB3 slot 6 range and must also be confirmed from that map.

## Use on the Icicle Kit

```sh
modprobe uio_pdrv_genirq of_id=shivamtiwari020505,motorsentinel-rv
msrvctl info                         # IDs, model, sensor and fault state
msrvctl load motorsentinel_ae_v1.bin # CRC-checked commit, default configuration
msrvctl start                        # enable and arm
msrvctl monitor                      # one line per event, fault causes decoded
msrvctl monitor --json               # JSON lines, 1 Hz heartbeat, for a dashboard
msrvctl window                       # features, q, h and y of the last window
msrvctl clear && msrvctl arm         # recover after a trip
msrvctl replay recording.csv         # x,y,z per line through APB injection
```

`clear` is accepted only when the safety policy has seen the configured
number of healthy windows, and it never restarts the motor; `arm` is always a
separate step.

## Interrupt handling

`irq_o` is level-sensitive. `uio_pdrv_genirq` masks the line when it fires,
so the driver acknowledges the causes in the device (write-one-to-clear on
`IRQ_STATUS` and `INTEGRITY_STATUS`) before writing `1` to the UIO file to
unmask, then waits with `poll()`. `msrv_uio_wait_irq` and `msrvctl monitor`
follow that order.

## Verification

| Test | What it proves | Result |
| --- | --- | --- |
| `sw/tests/test_motorsentinel.c` (host, any OS) | CRC-32 against the IEEE check value and the Python/RTL model CRC; model-file parsing; exact register packing; every CONTROL write restates the enable level, so clear and arm never disable the core; model-load success and failure; fault decoding | 23 checks |
| Driver-to-RTL replay (`tb/tb_driver_replay.sv`) | The library records its register traffic for identify, model load, configure, start and 384 injected samples. The bench drives that traffic into `motorsentinel_core_apb`, checks every read the driver depends on, and really polls every driver wait condition. | 397 checks; both window scores bit-exact with Python; motor armed, no fault |
| CI | Native Linux and `riscv64-linux-gnu` builds of the library and `msrvctl` with `-Wall -Wextra -Wpedantic -Werror`; overlay compiled with `dtc` | every push |

The replay already caught one mismatch: the trace recorder assumed
`CORE_CONTROL` resets to 0, but the hardware resets with DATA_READY mode
selected. The driver itself was correct, because it preserves that bit.

## Not yet verified

The UIO backend's `mmap` and interrupt path, and `msrvctl` against a real
`/dev/uioN`, need the board. They are compiled in CI but have not run on the
Icicle Kit.
