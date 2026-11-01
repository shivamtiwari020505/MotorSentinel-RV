/* Portable MotorSentinel-RV register-level library. See motorsentinel.h. */

#include "motorsentinel.h"

#include <stdio.h>
#include <string.h>

#define MODEL_TIMEOUT_US   1000u
#define INJECT_TIMEOUT_US  10000u

void msrv_attach(msrv_dev *dev, const msrv_io *io)
{
    dev->io = *io;
}

uint32_t msrv_read(const msrv_dev *dev, uint32_t offset)
{
    return dev->io.read(dev->io.ctx, offset);
}

void msrv_write(const msrv_dev *dev, uint32_t offset, uint32_t value)
{
    dev->io.write(dev->io.ctx, offset, value);
}

int msrv_wait(const msrv_dev *dev, uint32_t offset, uint32_t mask,
              uint32_t value, uint32_t timeout_us)
{
    uint32_t spins;

    if (dev->io.poll)
        return dev->io.poll(dev->io.ctx, offset, mask, value, timeout_us);
    for (spins = 0; spins < MSRV_SPIN_LIMIT; spins++) {
        if ((msrv_read(dev, offset) & mask) == value)
            return MSRV_OK;
    }
    return MSRV_ERR_TIMEOUT;
}

int msrv_identify(const msrv_dev *dev)
{
    if (msrv_read(dev, MSRV_REG_ID_VERSION) != MSRV_KERNEL_ID)
        return MSRV_ERR_ID;
    if (msrv_read(dev, MSRV_REG_CORE_ID) != MSRV_CORE_ID_VALUE)
        return MSRV_ERR_ID;
    return MSRV_OK;
}

/* Reflected IEEE 802.3 CRC-32, bit-serial: the image is 488 bytes. */
uint32_t msrv_crc32(const void *data, size_t length)
{
    const uint8_t *bytes = data;
    uint32_t crc = UINT32_C(0xffffffff);
    size_t i;
    int bit;

    for (i = 0; i < length; i++) {
        crc ^= bytes[i];
        for (bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (UINT32_C(0xedb88320) & (0u - (crc & 1u)));
    }
    return ~crc;
}

uint32_t msrv_image_crc(const uint32_t image[MSRV_MODEL_IMAGE_WORDS])
{
    uint8_t bytes[MSRV_MODEL_IMAGE_WORDS * 4u];
    size_t i;

    for (i = 0; i < MSRV_MODEL_IMAGE_WORDS; i++) {
        bytes[4 * i + 0] = (uint8_t)(image[i] >> 0);
        bytes[4 * i + 1] = (uint8_t)(image[i] >> 8);
        bytes[4 * i + 2] = (uint8_t)(image[i] >> 16);
        bytes[4 * i + 3] = (uint8_t)(image[i] >> 24);
    }
    return msrv_crc32(bytes, sizeof(bytes));
}

static uint32_t load_le32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

int msrv_model_parse(msrv_model *model, const void *data, size_t length)
{
    const uint8_t *bytes = data;
    size_t i;

    if (!model || !data)
        return MSRV_ERR_ARG;
    if (length != MSRV_MODEL_IMAGE_WORDS * 4u &&
        length != (MSRV_MODEL_IMAGE_WORDS + 1u) * 4u)
        return MSRV_ERR_FORMAT;
    for (i = 0; i < MSRV_MODEL_IMAGE_WORDS; i++)
        model->image[i] = load_le32(bytes + 4 * i);
    if (model->image[0] != MSRV_MODEL_FORMAT_WORD)
        return MSRV_ERR_FORMAT;
    model->has_threshold = length > MSRV_MODEL_IMAGE_WORDS * 4u;
    model->threshold = model->has_threshold
        ? load_le32(bytes + 4 * MSRV_MODEL_IMAGE_WORDS) : 0;
    return MSRV_OK;
}

int msrv_load_model(const msrv_dev *dev, const msrv_model *model,
                    uint32_t *model_status)
{
    const uint32_t expected = UINT32_C(0x00ff1f03);
    const uint32_t committed = ((uint32_t)MSRV_MODEL_IMAGE_WORDS << 16) |
                               MSRV_MODEL_STATUS_VALID;
    uint32_t crc;
    uint32_t status;
    size_t i;
    int result;

    if (!dev || !model)
        return MSRV_ERR_ARG;
    crc = msrv_image_crc(model->image);

    msrv_write(dev, MSRV_REG_MODEL_CMD, MSRV_MODEL_CMD_BEGIN);
    for (i = 0; i < MSRV_MODEL_IMAGE_WORDS; i++)
        msrv_write(dev, MSRV_REG_MODEL_DATA, model->image[i]);
    msrv_write(dev, MSRV_REG_MODEL_CRC, crc);
    msrv_write(dev, MSRV_REG_MODEL_CMD, MSRV_MODEL_CMD_COMMIT);

    /* Valid, not loading, no error bits, all words counted. */
    result = msrv_wait(dev, MSRV_REG_MODEL_STATUS, expected, committed,
                       MODEL_TIMEOUT_US);
    status = msrv_read(dev, MSRV_REG_MODEL_STATUS);
    if (model_status)
        *model_status = status;
    if (result != MSRV_OK)
        return MSRV_ERR_MODEL;
    if (msrv_read(dev, MSRV_REG_MODEL_CRC_ACTUAL) != crc)
        return MSRV_ERR_MODEL;
    return MSRV_OK;
}

void msrv_default_config(msrv_config *config)
{
    /* Hardware reset values, so configure() after reset is a no-op. */
    memset(config, 0, sizeof(*config));
    config->sample_timeout_us = 2500;
    config->stretch_limit_us = 100;
    config->stuck_limit_us = 1000;
    config->anomaly_threshold = 1000;
    config->anomaly_confirm = 2;
    config->recovery_windows = 4;
    config->nack_limit = 3;
    config->range_limit = 4000;
    config->slew_limit = 1024;
    config->frozen_limit = 32;
    config->replay_threshold = 16;
    config->use_drdy = true;
}

static uint32_t core_control(const msrv_dev *dev)
{
    return msrv_read(dev, MSRV_REG_CORE_CONTROL) &
           (MSRV_CORE_CONTROL_INJECT | MSRV_CORE_CONTROL_DRDY);
}

int msrv_configure(const msrv_dev *dev, const msrv_config *config)
{
    uint32_t control;

    if (!dev || !config)
        return MSRV_ERR_ARG;
    msrv_write(dev, MSRV_REG_SAMPLE_CFG, config->sample_timeout_us);
    msrv_write(dev, MSRV_REG_BUS_TIMEOUT,
               MSRV_BUS_TIMEOUT(config->stuck_limit_us, config->stretch_limit_us));
    msrv_write(dev, MSRV_REG_ANOM_THRESHOLD, config->anomaly_threshold);
    msrv_write(dev, MSRV_REG_POLICY_CFG,
               MSRV_POLICY_CFG(config->nack_limit, config->recovery_windows,
                               config->anomaly_confirm));
    msrv_write(dev, MSRV_REG_INTEGRITY_LIMITS,
               MSRV_INTEGRITY_LIMITS(config->slew_limit, config->range_limit));
    msrv_write(dev, MSRV_REG_INTEGRITY_CFG,
               MSRV_INTEGRITY_CFG(config->replay_threshold, config->frozen_limit));
    msrv_write(dev, MSRV_REG_IRQ_ENABLE,
               MSRV_IRQ_TRIP | MSRV_IRQ_CLEAR_ACCEPTED |
               MSRV_IRQ_CLEAR_REJECTED | MSRV_IRQ_PROTOCOL_FAULT);
    control = core_control(dev) & MSRV_CORE_CONTROL_INJECT;
    if (config->use_drdy)
        control |= MSRV_CORE_CONTROL_DRDY;
    msrv_write(dev, MSRV_REG_CORE_CONTROL, control);
    return MSRV_OK;
}

/* CONTROL: bit 0 enable and bit 4 monitor-only are levels; bits 1-3 are
 * single-cycle requests. Every write must restate the levels. */
static void control_request(const msrv_dev *dev, uint32_t levels,
                            uint32_t requests)
{
    msrv_write(dev, MSRV_REG_CONTROL, levels | requests);
}

static uint32_t control_levels(const msrv_dev *dev)
{
    return msrv_read(dev, MSRV_REG_CONTROL) &
           (MSRV_CONTROL_ENABLE | MSRV_CONTROL_MONITOR_ONLY);
}

int msrv_start(const msrv_dev *dev, bool monitor_only)
{
    uint32_t levels = MSRV_CONTROL_ENABLE |
                      (monitor_only ? MSRV_CONTROL_MONITOR_ONLY : 0u);

    control_request(dev, levels, MSRV_CONTROL_ARM);
    return msrv_wait(dev, MSRV_REG_STATUS, MSRV_STATUS_ARMED,
                     MSRV_STATUS_ARMED, MODEL_TIMEOUT_US);
}

int msrv_stop(const msrv_dev *dev)
{
    control_request(dev, control_levels(dev), MSRV_CONTROL_DISARM);
    control_request(dev, 0u, 0u);
    return MSRV_OK;
}

int msrv_arm(const msrv_dev *dev)
{
    control_request(dev, control_levels(dev), MSRV_CONTROL_ARM);
    return msrv_wait(dev, MSRV_REG_STATUS, MSRV_STATUS_ARMED,
                     MSRV_STATUS_ARMED, MODEL_TIMEOUT_US);
}

int msrv_disarm(const msrv_dev *dev)
{
    control_request(dev, control_levels(dev), MSRV_CONTROL_DISARM);
    return MSRV_OK;
}

int msrv_request_clear(const msrv_dev *dev)
{
    const uint32_t outcome = MSRV_IRQ_CLEAR_ACCEPTED | MSRV_IRQ_CLEAR_REJECTED;

    msrv_write(dev, MSRV_REG_IRQ_STATUS, outcome);
    control_request(dev, control_levels(dev), MSRV_CONTROL_CLEAR);
    if (msrv_wait(dev, MSRV_REG_IRQ_STATUS, outcome, MSRV_IRQ_CLEAR_ACCEPTED,
                  MODEL_TIMEOUT_US) == MSRV_OK)
        return MSRV_OK;
    return MSRV_ERR_REJECTED;
}

void msrv_ack_events(const msrv_dev *dev, uint32_t *irq_causes,
                     uint32_t *integrity_causes)
{
    uint32_t irq = msrv_read(dev, MSRV_REG_IRQ_STATUS) & UINT32_C(0xf);
    uint32_t integrity = msrv_read(dev, MSRV_REG_INTEGRITY_STATUS) & UINT32_C(0x1f);

    if (irq)
        msrv_write(dev, MSRV_REG_IRQ_STATUS, irq);
    if (integrity)
        msrv_write(dev, MSRV_REG_INTEGRITY_STATUS, integrity);
    if (irq_causes)
        *irq_causes = irq;
    if (integrity_causes)
        *integrity_causes = integrity;
}

void msrv_read_status(const msrv_dev *dev, msrv_status *status)
{
    status->status = msrv_read(dev, MSRV_REG_STATUS);
    status->fault_vector = msrv_read(dev, MSRV_REG_FAULT_VECTOR);
    status->irq_status = msrv_read(dev, MSRV_REG_IRQ_STATUS);
    status->integrity_status = msrv_read(dev, MSRV_REG_INTEGRITY_STATUS);
    status->model_status = msrv_read(dev, MSRV_REG_MODEL_STATUS);
    status->inference_status = msrv_read(dev, MSRV_REG_INFERENCE_STATUS);
    status->anomaly_score = msrv_read(dev, MSRV_REG_ANOM_SCORE);
    status->window_count = msrv_read(dev, MSRV_REG_WINDOW_COUNT);
    status->last_sequence = msrv_read(dev, MSRV_REG_LAST_SEQUENCE);
    status->latency = msrv_read(dev, MSRV_REG_LATENCY);
    status->acq_status = msrv_read(dev, MSRV_REG_ACQ_STATUS);
    status->acq_samples = msrv_read(dev, MSRV_REG_ACQ_SAMPLES);
}

static void unpack_int8(const msrv_dev *dev, uint32_t base, int8_t *out,
                        size_t count)
{
    size_t i;

    for (i = 0; i < count; i++) {
        uint32_t word = msrv_read(dev, base + 4u * (uint32_t)(i / 4u));
        out[i] = (int8_t)(uint8_t)(word >> (8u * (i % 4u)));
    }
}

void msrv_read_window(const msrv_dev *dev, msrv_window *window)
{
    size_t i;

    window->sequence = msrv_read(dev, MSRV_REG_LAST_SEQUENCE);
    window->score = MSRV_INFERENCE_SCORE(msrv_read(dev, MSRV_REG_INFERENCE_STATUS));
    for (i = 0; i < MSRV_FEATURES; i++)
        window->features[i] = (int32_t)msrv_read(dev, MSRV_REG_FEATURE(i));
    unpack_int8(dev, MSRV_REG_Q(0), window->q, MSRV_FEATURES);
    unpack_int8(dev, MSRV_REG_H(0), window->h, MSRV_HIDDEN);
    unpack_int8(dev, MSRV_REG_Y(0), window->y, MSRV_FEATURES);
}

int msrv_set_inject_mode(const msrv_dev *dev, bool enable)
{
    uint32_t control = core_control(dev) & ~MSRV_CORE_CONTROL_INJECT;

    if (enable)
        control |= MSRV_CORE_CONTROL_INJECT;
    msrv_write(dev, MSRV_REG_CORE_CONTROL, control);
    return MSRV_OK;
}

int msrv_inject_sample(const msrv_dev *dev, int16_t x, int16_t y, int16_t z)
{
    int result = msrv_wait(dev, MSRV_REG_INFERENCE_STATUS,
                           MSRV_INFERENCE_DATAPATH_READY,
                           MSRV_INFERENCE_DATAPATH_READY, INJECT_TIMEOUT_US);

    if (result != MSRV_OK)
        return result;
    msrv_write(dev, MSRV_REG_INJECT_XY,
               ((uint32_t)(uint16_t)y << 16) | (uint32_t)(uint16_t)x);
    msrv_write(dev, MSRV_REG_INJECT_Z, (uint32_t)(uint16_t)z);
    return MSRV_OK;
}

static size_t describe(uint32_t bits, const char *const *names, size_t count,
                       char *buffer, size_t size)
{
    size_t length = 0;
    size_t i;
    int written;

    if (size)
        buffer[0] = '\0';
    for (i = 0; i < count; i++) {
        if (!(bits & (UINT32_C(1) << i)))
            continue;
        written = snprintf(size > length ? buffer + length : NULL,
                           size > length ? size - length : 0,
                           "%s%s", length ? ", " : "", names[i]);
        if (written > 0)
            length += (size_t)written;
    }
    if (length == 0) {
        written = snprintf(buffer, size, "none");
        length = written > 0 ? (size_t)written : 0;
    }
    return length;
}

size_t msrv_describe_faults(uint32_t fault_vector, char *buffer, size_t size)
{
    static const char *const names[] = {
        "SCL stuck low", "SDA stuck low", "clock stretch timeout",
        "NACK limit", "missing sample", "unexpected bus activity",
        "sensor integrity", "internal overrun", "model invalid",
        "learned anomaly",
    };
    return describe(fault_vector, names, sizeof(names) / sizeof(names[0]),
                    buffer, size);
}

size_t msrv_describe_integrity(uint32_t integrity, char *buffer, size_t size)
{
    static const char *const names[] = {
        "range", "slew", "frozen", "replay", "overrun",
    };
    return describe(integrity, names, sizeof(names) / sizeof(names[0]),
                    buffer, size);
}

const char *msrv_strerror(int error)
{
    switch (error) {
    case MSRV_OK: return "ok";
    case MSRV_ERR_ARG: return "invalid argument";
    case MSRV_ERR_ID: return "MotorSentinel-RV ID registers not found";
    case MSRV_ERR_TIMEOUT: return "hardware did not respond in time";
    case MSRV_ERR_MODEL: return "model commit rejected";
    case MSRV_ERR_IO: return "operating-system error";
    case MSRV_ERR_FORMAT: return "malformed model file";
    case MSRV_ERR_REJECTED: return "clear rejected by the safety policy";
    default: return "unknown error";
    }
}
