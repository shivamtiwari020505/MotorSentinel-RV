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

/* Data-plane extension (motorsentinel_core_apb). */
#define MSRV_REG_CORE_ID          UINT32_C(0x40)
#define MSRV_REG_CORE_CONTROL     UINT32_C(0x44)
#define MSRV_REG_INJECT_XY        UINT32_C(0x48)
#define MSRV_REG_INJECT_Z         UINT32_C(0x4c)
#define MSRV_REG_MODEL_CMD        UINT32_C(0x50)
#define MSRV_REG_MODEL_DATA       UINT32_C(0x54)
#define MSRV_REG_MODEL_CRC        UINT32_C(0x58)
#define MSRV_REG_MODEL_STATUS     UINT32_C(0x5c)
#define MSRV_REG_MODEL_CRC_ACTUAL UINT32_C(0x60)
#define MSRV_REG_INTEGRITY_LIMITS UINT32_C(0x64)
#define MSRV_REG_INTEGRITY_CFG    UINT32_C(0x68)
#define MSRV_REG_INTEGRITY_STATUS UINT32_C(0x6c)
#define MSRV_REG_WINDOW_COUNT     UINT32_C(0x70)
#define MSRV_REG_LAST_SEQUENCE    UINT32_C(0x74)
#define MSRV_REG_LATENCY          UINT32_C(0x78)
#define MSRV_REG_INFERENCE_STATUS UINT32_C(0x7c)
#define MSRV_REG_FEATURE(n)       (UINT32_C(0x80) + 4u * (uint32_t)(n))
#define MSRV_REG_Q(n)             (UINT32_C(0xc0) + 4u * (uint32_t)(n))
#define MSRV_REG_Y(n)             (UINT32_C(0xd0) + 4u * (uint32_t)(n))
#define MSRV_REG_H(n)             (UINT32_C(0xe0) + 4u * (uint32_t)(n))
#define MSRV_REG_ACQ_STATUS       UINT32_C(0xe8)
#define MSRV_REG_ACQ_SAMPLES      UINT32_C(0xec)

#define MSRV_CORE_ID_VALUE        UINT32_C(0x4d530300)
#define MSRV_CORE_CONTROL_INJECT  (UINT32_C(1) << 0)
#define MSRV_CORE_CONTROL_DRDY    (UINT32_C(1) << 1)

#define MSRV_MODEL_CMD_BEGIN      (UINT32_C(1) << 0)
#define MSRV_MODEL_CMD_COMMIT     (UINT32_C(1) << 1)
#define MSRV_MODEL_IMAGE_WORDS    122u
#define MSRV_MODEL_FORMAT_WORD    UINT32_C(0x4d410001)

#define MSRV_MODEL_STATUS_VALID   (UINT32_C(1) << 0)
#define MSRV_MODEL_STATUS_LOADING (UINT32_C(1) << 1)
#define MSRV_MODEL_ERR_CRC        (UINT32_C(1) << 8)
#define MSRV_MODEL_ERR_LENGTH     (UINT32_C(1) << 9)
#define MSRV_MODEL_ERR_FORMAT     (UINT32_C(1) << 10)
#define MSRV_MODEL_ERR_RANGE      (UINT32_C(1) << 11)
#define MSRV_MODEL_ERR_SEQUENCE   (UINT32_C(1) << 12)
#define MSRV_MODEL_STATUS_WORDS(v) (((uint32_t)(v) >> 16) & UINT32_C(0xff))

#define MSRV_INTEGRITY_RANGE      (UINT32_C(1) << 0)
#define MSRV_INTEGRITY_SLEW       (UINT32_C(1) << 1)
#define MSRV_INTEGRITY_FROZEN     (UINT32_C(1) << 2)
#define MSRV_INTEGRITY_REPLAY     (UINT32_C(1) << 3)
#define MSRV_INTEGRITY_OVERRUN    (UINT32_C(1) << 4)

#define MSRV_INTEGRITY_LIMITS(slew, range)     ((((uint32_t)(slew) & UINT32_C(0xffff)) << 16) |      ((uint32_t)(range) & UINT32_C(0xffff)))

#define MSRV_INTEGRITY_CFG(replay_hits, frozen_run)     ((((uint32_t)(replay_hits) & UINT32_C(0xff)) << 8) |      ((uint32_t)(frozen_run) & UINT32_C(0xff)))

#define MSRV_INFERENCE_SCORE(v)      ((uint32_t)(v) & UINT32_C(0xfff))
#define MSRV_INFERENCE_FROZEN        (UINT32_C(1) << 16)
#define MSRV_INFERENCE_BUSY          (UINT32_C(1) << 17)
#define MSRV_INFERENCE_DATAPATH_READY (UINT32_C(1) << 20)

#define MSRV_ACQ_DEVICE_ID(v)     ((uint32_t)(v) & UINT32_C(0xff))
#define MSRV_ACQ_CONFIGURED       (UINT32_C(1) << 8)
#define MSRV_ACQ_ID_ERROR         (UINT32_C(1) << 9)
#define MSRV_ACQ_DRDY_MODE        (UINT32_C(1) << 10)
#define MSRV_ACQ_BUS_OWNED        (UINT32_C(1) << 11)
#define MSRV_ACQ_NACK_COUNT(v)    ((uint32_t)(v) >> 16)

#define MSRV_LATENCY_LAST(v)      ((uint32_t)(v) & UINT32_C(0xffff))
#define MSRV_LATENCY_MAX(v)       ((uint32_t)(v) >> 16)

#endif /* MOTORSENTINEL_REGS_H */
