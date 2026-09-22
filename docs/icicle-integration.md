# PolarFire SoC Icicle Kit integration baseline

The board project will be derived from the official Icicle Kit reference design
rather than a blank Libero project. The initial reproducible baseline is:

- Libero SoC 2025.2;
- Icicle reference design tag `v2026.04`;
- production `MPFS250T` target;
- FIC3 at 50 MHz for APB control and status; and
- a later 125 MHz compute domain with explicit clock-domain crossing.

## Proposed connection

Package `motorsentinel_guard_apb` as a user HDL+ component with an APB3 bus
interface. Connect it to unused CoreAPB3 slot 6 in the reference design, giving
a provisional MSS-visible range of `0x4000_0600` through `0x4000_06ff`. The
address is not authoritative until SmartDesign memory-map DRC passes and the
generated map is reflected in Linux software.

Use `FIC_3_CLK` and `RESETN_FIC_3_CLK` for this milestone. The reset must come
from the reference design's `CORERESET_PF` path, which provides asynchronous
assertion and synchronous deassertion. Do not derive functional reset directly
from PLL lock.

Route the level-sensitive `irq_o` to a verified free `MSS_INT_F2M` input. Bit 11
appears unused in the current reference design but must be rechecked after all
SmartDesign components are generated.

The active-high motor permission output requires a physical pull-down or driver
stage that keeps the motor disabled during reset, FPGA configuration, or an
unpowered FPGA. RTL alone cannot guarantee the pre-configuration electrical
state.

The onboard power monitor is a **PAC1934T-I/JQ** on MSS I2C1. That bus should be
preserved for CPU-versus-FPGA power measurements. The older proposal diagram's
`AC1934` label is a documentation typo; it is not a different device.

## Reproducibility rules

1. Express SmartDesign changes as Tcl overlay scripts; do not rely on GUI-only
   state.
2. Run component generation, SmartDesign DRC, synthesis, place-and-route, and
   timing verification from a pinned tool/reference revision.
3. Keep the existing CoreI2C peripheral and PAC1934 access working before adding
   the matrix accelerator.
4. Record utilization, timing, tool versions, and the exact Git commit for every
   hardware result.
5. If bulk DDR access is later added through FIC2, configure an MSS MPU window
   explicitly and cross the 50/125 MHz boundary through reviewed CDC logic.

## Official references

- [Icicle Kit reference design](https://github.com/polarfire-soc/icicle-kit-reference-design)
- [Reference design v2026.04](https://github.com/polarfire-soc/icicle-kit-reference-design/releases/tag/v2026.04)
- [PolarFire SoC MSS technical reference manual](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/ReferenceManuals/PolarFire_SoC_FPGA_MSS_Technical_Reference_Manual_VC.pdf)
- [Icicle Kit user guide](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/UserGuides/microchip_polarfire_soc_fpga_icicle_kit_user_guide_vb.pdf)
