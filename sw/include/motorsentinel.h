#ifndef MOTORSENTINEL_H
#define MOTORSENTINEL_H

/*
 * libmotorsentinel: user-space access to the MotorSentinel-RV fabric core.
 *
 * Every register access goes through msrv_io, so the same code runs on the
 * Icicle Kit through Linux UIO (motorsentinel_uio.h) and in host tests
 * against a fake or recording backend. The library never sleeps; waiting is
 * delegated to msrv_io.poll when a backend provides it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "motorsentinel_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MSRV_KERNEL_ID     UINT32_C(0x4d530100)
#define MSRV_FEATURES      16u
#define MSRV_HIDDEN        8u

enum msrv_error {
    MSRV_OK = 0,
    MSRV_ERR_ARG = -1,      /* invalid argument */
    MSRV_ERR_ID = -2,       /* ID registers do not match this library */
    MSRV_ERR_TIMEOUT = -3,  /* hardware condition not reached in time */
    MSRV_ERR_MODEL = -4,    /* model commit rejected by the hardware */
    MSRV_ERR_IO = -5,       /* operating-system failure (errno is set) */
    MSRV_ERR_FORMAT = -6,   /* malformed model file */
    MSRV_ERR_REJECTED = -7  /* clear request rejected by the safety policy */
};

typedef struct msrv_io {
    uint32_t (*read)(void *ctx, uint32_t offset);
    void (*write)(void *ctx, uint32_t offset, uint32_t value);
    /* Optional: wait until (read(offset) & mask) == value. Returns MSRV_OK or
     * MSRV_ERR_TIMEOUT. When NULL the library spins on read() for at most
     * MSRV_SPIN_LIMIT reads. */
    int (*poll)(void *ctx, uint32_t offset, uint32_t mask, uint32_t value,
                uint32_t timeout_us);
    void *ctx;
} msrv_io;

#define MSRV_SPIN_LIMIT 1000000u

typedef struct msrv_dev {
    msrv_io io;
} msrv_dev;

/* 122-word image from model/edgematrix.py, optionally followed by the
 * anomaly threshold (tools/export_model_bin.py writes both). */
typedef struct msrv_model {
    uint32_t image[MSRV_MODEL_IMAGE_WORDS];
    uint32_t threshold;
    bool has_threshold;
} msrv_model;

typedef struct msrv_config {
    uint32_t sample_timeout_us;  /* 0 disables the missing-sample watchdog */
    uint16_t stretch_limit_us;
    uint16_t stuck_limit_us;
    uint32_t anomaly_threshold;
    uint8_t anomaly_confirm;     /* consecutive windows above threshold */
    uint8_t recovery_windows;    /* healthy windows before a clear is accepted */
    uint8_t nack_limit;
    uint16_t range_limit;
    uint16_t slew_limit;
    uint8_t frozen_limit;
    uint8_t replay_threshold;
    bool use_drdy;               /* ADXL345 DATA_READY trigger (else timer) */
} msrv_config;

typedef struct msrv_status {
    uint32_t status;
    uint32_t fault_vector;
    uint32_t irq_status;
    uint32_t integrity_status;
    uint32_t model_status;
    uint32_t inference_status;
    uint32_t anomaly_score;
    uint32_t window_count;
    uint32_t last_sequence;
    uint32_t latency;
    uint32_t acq_status;
    uint32_t acq_samples;
} msrv_status;

typedef struct msrv_window {
    uint32_t sequence;
    uint32_t score;
    int32_t features[MSRV_FEATURES];
    int8_t q[MSRV_FEATURES];
    int8_t h[MSRV_HIDDEN];
    int8_t y[MSRV_FEATURES];
} msrv_window;

void msrv_attach(msrv_dev *dev, const msrv_io *io);
uint32_t msrv_read(const msrv_dev *dev, uint32_t offset);
void msrv_write(const msrv_dev *dev, uint32_t offset, uint32_t value);
int msrv_wait(const msrv_dev *dev, uint32_t offset, uint32_t mask,
              uint32_t value, uint32_t timeout_us);

/* Checks the safety-kernel and data-plane ID registers. */
int msrv_identify(const msrv_dev *dev);

uint32_t msrv_crc32(const void *data, size_t length);
uint32_t msrv_image_crc(const uint32_t image[MSRV_MODEL_IMAGE_WORDS]);
/* Parses 488 (image) or 492 (image + threshold) little-endian bytes. */
int msrv_model_parse(msrv_model *model, const void *data, size_t length);
/* Begin, stream, CRC and commit. The model is invalid (motor off) until the
 * commit succeeds. *model_status receives MODEL_STATUS when non-NULL. */
int msrv_load_model(const msrv_dev *dev, const msrv_model *model,
                    uint32_t *model_status);

void msrv_default_config(msrv_config *config);
int msrv_configure(const msrv_dev *dev, const msrv_config *config);

/* CONTROL helpers preserve the enable and monitor-only levels. */
int msrv_start(const msrv_dev *dev, bool monitor_only);  /* enable + arm */
int msrv_stop(const msrv_dev *dev);                      /* disarm + disable */
int msrv_arm(const msrv_dev *dev);
int msrv_disarm(const msrv_dev *dev);
/* MSRV_OK when the policy accepted the clear, MSRV_ERR_REJECTED otherwise.
 * A clear never re-arms the motor. */
int msrv_request_clear(const msrv_dev *dev);

/* Reads and acknowledges (write-one-to-clear) the interrupt and integrity
 * causes; either pointer may be NULL. */
void msrv_ack_events(const msrv_dev *dev, uint32_t *irq_causes,
                     uint32_t *integrity_causes);
void msrv_read_status(const msrv_dev *dev, msrv_status *status);
void msrv_read_window(const msrv_dev *dev, msrv_window *window);

/* Sample injection for replay and the CPU-versus-FPGA comparison. */
int msrv_set_inject_mode(const msrv_dev *dev, bool enable);
int msrv_inject_sample(const msrv_dev *dev, int16_t x, int16_t y, int16_t z);

/* Human-readable names for FAULT_VECTOR and INTEGRITY_STATUS bits, joined
 * with ", " ("none" when empty). Returns the length that would be written. */
size_t msrv_describe_faults(uint32_t fault_vector, char *buffer, size_t size);
size_t msrv_describe_integrity(uint32_t integrity, char *buffer, size_t size);
const char *msrv_strerror(int error);

#ifdef __cplusplus
}
#endif

#endif /* MOTORSENTINEL_H */
