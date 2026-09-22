#ifndef MOTORSENTINEL_REGS_H
#define MOTORSENTINEL_REGS_H

#include <stdint.h>

/* Local APB offsets. The system base address is assigned by SmartDesign. */
#define MSRV_REG_ID_VERSION       UINT32_C(0x00)
#define MSRV_REG_CONTROL          UINT32_C(0x04)
#define MSRV_REG_STATUS           UINT32_C(0x08)
#define MSRV_REG_IRQ_STATUS       UINT32_C(0x0c)
#define MSRV_REG_IRQ_ENABLE       UINT32_C(0x10)
#define MSRV_REG_SAMPLE_CFG       UINT32_C(0x14)
#define MSRV_REG_BUS_TIMEOUT      UINT32_C(0x18)
#define MSRV_REG_ANOM_THRESHOLD   UINT32_C(0x1c)
#define MSRV_REG_POLICY_CFG       UINT32_C(0x20)
#define MSRV_REG_ANOM_SCORE       UINT32_C(0x34)
#define MSRV_REG_FAULT_VECTOR     UINT32_C(0x38)

#define MSRV_CONTROL_ENABLE       (UINT32_C(1) << 0)
#define MSRV_CONTROL_CLEAR        (UINT32_C(1) << 1)
#define MSRV_CONTROL_ARM          (UINT32_C(1) << 2)
#define MSRV_CONTROL_DISARM       (UINT32_C(1) << 3)
#define MSRV_CONTROL_MONITOR_ONLY (UINT32_C(1) << 4)

#define MSRV_STATUS_READY         (UINT32_C(1) << 0)
#define MSRV_STATUS_MODEL_VALID   (UINT32_C(1) << 1)
#define MSRV_STATUS_WINDOW_VALID  (UINT32_C(1) << 2)
#define MSRV_STATUS_TRIP          (UINT32_C(1) << 3)
#define MSRV_STATUS_DATA_VALID    (UINT32_C(1) << 4)
#define MSRV_STATUS_MONITOR_ONLY  (UINT32_C(1) << 5)
#define MSRV_STATUS_BUS_HEALTHY   (UINT32_C(1) << 6)
#define MSRV_STATUS_MOTOR_ENABLE  (UINT32_C(1) << 7)
#define MSRV_STATUS_ARMED         (UINT32_C(1) << 8)

#define MSRV_IRQ_TRIP             (UINT32_C(1) << 0)
#define MSRV_IRQ_CLEAR_ACCEPTED   (UINT32_C(1) << 1)
#define MSRV_IRQ_CLEAR_REJECTED   (UINT32_C(1) << 2)
#define MSRV_IRQ_PROTOCOL_FAULT   (UINT32_C(1) << 3)

#define MSRV_FAULT_SCL_STUCK      (UINT32_C(1) << 0)
#define MSRV_FAULT_SDA_STUCK      (UINT32_C(1) << 1)
#define MSRV_FAULT_CLOCK_STRETCH  (UINT32_C(1) << 2)
#define MSRV_FAULT_NACK_LIMIT     (UINT32_C(1) << 3)
#define MSRV_FAULT_NO_SAMPLE      (UINT32_C(1) << 4)
#define MSRV_FAULT_UNEXPECTED_BUS (UINT32_C(1) << 5)
#define MSRV_FAULT_PHYSICAL       (UINT32_C(1) << 6)
#define MSRV_FAULT_INTERNAL       (UINT32_C(1) << 7)
#define MSRV_FAULT_MODEL_INVALID  (UINT32_C(1) << 8)
#define MSRV_FAULT_ANOMALY        (UINT32_C(1) << 9)

#define MSRV_BUS_TIMEOUT(stuck_us, stretch_us) \
    ((((uint32_t)(stuck_us) & UINT32_C(0xffff)) << 16) | \
     ((uint32_t)(stretch_us) & UINT32_C(0xffff)))

#define MSRV_POLICY_CFG(nack_limit, recovery_windows, anomaly_confirm) \
    ((((uint32_t)(nack_limit) & UINT32_C(0xff)) << 16) | \
     (((uint32_t)(recovery_windows) & UINT32_C(0xff)) << 8) | \
     ((uint32_t)(anomaly_confirm) & UINT32_C(0xff)))

#endif /* MOTORSENTINEL_REGS_H */
