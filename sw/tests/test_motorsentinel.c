/*
 * Host tests for libmotorsentinel.
 *
 *   test_motorsentinel <model.bin> <expected_crc_hex>
 *       unit tests against a fake register file
 *   test_motorsentinel --trace <out.txt> <model.bin> <samples.hex> <count>
 *       records the register traffic of a real bring-up (identify, load,
 *       configure, start, inject <count> samples) for replay against the RTL
 *       by tb/tb_driver_replay.sv
 */

#include "motorsentinel.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks;
static int failures;

#define CHECK(condition, message)                                          \
    do {                                                                   \
        checks++;                                                          \
        if (!(condition)) {                                                \
            failures++;                                                    \
            printf("FAIL: %s (%s:%d)\n", message, __FILE__, __LINE__);     \
        } else {                                                           \
            printf("PASS: %s\n", message);                                 \
        }                                                                  \
    } while (0)

/* ------------------------------------------------------------------ */
/* Fake register file                                                  */
/* ------------------------------------------------------------------ */

typedef struct fake {
    uint32_t regs[64];
    uint32_t writes[512][2];
    int write_count;
    bool model_ok;
    bool clear_ok;
} fake;

static uint32_t fake_read(void *ctx, uint32_t offset)
{
    fake *f = ctx;

    switch (offset) {
    case MSRV_REG_ID_VERSION: return MSRV_KERNEL_ID;
    case MSRV_REG_CORE_ID: return MSRV_CORE_ID_VALUE;
    case MSRV_REG_MODEL_STATUS:
        return f->model_ok ? (((uint32_t)MSRV_MODEL_IMAGE_WORDS << 16) | 1u)
                           : ((uint32_t)MSRV_MODEL_ERR_CRC | (122u << 16));
    case MSRV_REG_MODEL_CRC_ACTUAL:
        return f->regs[MSRV_REG_MODEL_CRC / 4];
    case MSRV_REG_STATUS: return MSRV_STATUS_ARMED;
    case MSRV_REG_INFERENCE_STATUS: return MSRV_INFERENCE_DATAPATH_READY | 77u;
    case MSRV_REG_IRQ_STATUS:
        return f->clear_ok ? MSRV_IRQ_CLEAR_ACCEPTED : MSRV_IRQ_CLEAR_REJECTED;
    default: return f->regs[offset / 4];
    }
}

static void fake_write(void *ctx, uint32_t offset, uint32_t value)
{
    fake *f = ctx;

    if (f->write_count < 512) {
        f->writes[f->write_count][0] = offset;
        f->writes[f->write_count][1] = value;
        f->write_count++;
    }
    if (offset == MSRV_REG_CONTROL)
        f->regs[offset / 4] = value & (MSRV_CONTROL_ENABLE | MSRV_CONTROL_MONITOR_ONLY);
    else
        f->regs[offset / 4] = value;
}

static void fake_attach(fake *f, msrv_dev *dev)
{
    msrv_io io = { fake_read, fake_write, NULL, f };

    memset(f, 0, sizeof(*f));
    f->model_ok = true;
    f->clear_ok = true;
    msrv_attach(dev, &io);
}

static int read_file(const char *path, unsigned char *buffer, size_t size, size_t *length)
{
    FILE *file = fopen(path, "rb");

    if (!file)
        return -1;
    *length = fread(buffer, 1, size, file);
    fclose(file);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Unit tests                                                          */
/* ------------------------------------------------------------------ */

static int unit_tests(const char *model_path, uint32_t expected_crc)
{
    unsigned char buffer[600];
    size_t length = 0;
    msrv_model model;
    msrv_config config;
    msrv_dev dev;
    fake f;
    char text[256];
    uint32_t status = 0;
    int i;

    CHECK(msrv_crc32("123456789", 9) == UINT32_C(0xcbf43926),
          "CRC-32 matches the IEEE check value 0xCBF43926");

    CHECK(read_file(model_path, buffer, sizeof(buffer), &length) == 0,
          "exported model file is readable");
    CHECK(msrv_model_parse(&model, buffer, length) == MSRV_OK && model.has_threshold,
          "model file parses with its threshold");
    CHECK(msrv_image_crc(model.image) == expected_crc,
          "C image CRC equals the Python/RTL CRC");
    CHECK(msrv_model_parse(&model, buffer, 100) == MSRV_ERR_FORMAT,
          "truncated model file is rejected");
    buffer[0] ^= 1u;
    CHECK(msrv_model_parse(&model, buffer, length) == MSRV_ERR_FORMAT,
          "wrong format word is rejected");
    buffer[0] ^= 1u;
    msrv_model_parse(&model, buffer, length);

    fake_attach(&f, &dev);
    CHECK(msrv_identify(&dev) == MSRV_OK, "both ID registers are recognized");

    CHECK(msrv_load_model(&dev, &model, &status) == MSRV_OK,
          "model load succeeds when the hardware commits it");
    CHECK(f.write_count == (int)MSRV_MODEL_IMAGE_WORDS + 3 &&
          f.writes[0][0] == MSRV_REG_MODEL_CMD && f.writes[0][1] == MSRV_MODEL_CMD_BEGIN &&
          f.writes[1][1] == MSRV_MODEL_FORMAT_WORD &&
          f.writes[MSRV_MODEL_IMAGE_WORDS + 1][0] == MSRV_REG_MODEL_CRC &&
          f.writes[MSRV_MODEL_IMAGE_WORDS + 1][1] == expected_crc &&
          f.writes[MSRV_MODEL_IMAGE_WORDS + 2][1] == MSRV_MODEL_CMD_COMMIT,
          "load writes begin, 122 words in order, CRC, commit");
    f.model_ok = false;
    CHECK(msrv_load_model(&dev, &model, &status) == MSRV_ERR_MODEL &&
          (status & MSRV_MODEL_ERR_CRC),
          "a rejected commit is reported with MODEL_STATUS");
    f.model_ok = true;

    fake_attach(&f, &dev);
    msrv_default_config(&config);
    config.anomaly_threshold = model.threshold;
    msrv_configure(&dev, &config);
    CHECK(f.regs[MSRV_REG_POLICY_CFG / 4] == UINT32_C(0x00030402) &&
          f.regs[MSRV_REG_BUS_TIMEOUT / 4] == UINT32_C(0x03e80064) &&
          f.regs[MSRV_REG_INTEGRITY_LIMITS / 4] == UINT32_C(0x04000fa0) &&
          f.regs[MSRV_REG_INTEGRITY_CFG / 4] == UINT32_C(0x00001020) &&
          f.regs[MSRV_REG_ANOM_THRESHOLD / 4] == model.threshold &&
          f.regs[MSRV_REG_CORE_CONTROL / 4] == MSRV_CORE_CONTROL_DRDY &&
          f.regs[MSRV_REG_IRQ_ENABLE / 4] == UINT32_C(0xf),
          "configuration registers are packed as the RTL expects");

    fake_attach(&f, &dev);
    msrv_start(&dev, false);
    CHECK(f.writes[0][1] == (MSRV_CONTROL_ENABLE | MSRV_CONTROL_ARM),
          "start enables and arms in one CONTROL write");
    f.write_count = 0;
    CHECK(msrv_request_clear(&dev) == MSRV_OK, "accepted clear is reported");
    CHECK(f.writes[1][0] == MSRV_REG_CONTROL &&
          f.writes[1][1] == (MSRV_CONTROL_ENABLE | MSRV_CONTROL_CLEAR),
          "clear keeps the core enabled (levels are restated)");
    f.clear_ok = false;
    CHECK(msrv_request_clear(&dev) == MSRV_ERR_REJECTED, "rejected clear is reported");
    f.write_count = 0;
    msrv_arm(&dev);
    CHECK(f.writes[0][1] == (MSRV_CONTROL_ENABLE | MSRV_CONTROL_ARM),
          "arm keeps the core enabled");
    msrv_stop(&dev);
    CHECK(f.regs[MSRV_REG_CONTROL / 4] == 0, "stop disarms and disables");

    fake_attach(&f, &dev);
    msrv_set_inject_mode(&dev, true);
    CHECK(msrv_inject_sample(&dev, -32768, 32767, -1) == MSRV_OK &&
          f.regs[MSRV_REG_INJECT_XY / 4] == UINT32_C(0x7fff8000) &&
          f.regs[MSRV_REG_INJECT_Z / 4] == UINT32_C(0x0000ffff) &&
          (f.regs[MSRV_REG_CORE_CONTROL / 4] & MSRV_CORE_CONTROL_INJECT),
          "injected samples are packed X|Y then Z");

    msrv_describe_faults(UINT32_C(0x248), text, sizeof(text));
    CHECK(strcmp(text, "NACK limit, sensor integrity, learned anomaly") == 0,
          "fault vector is decoded to names");
    msrv_describe_faults(0, text, sizeof(text));
    CHECK(strcmp(text, "none") == 0, "empty fault vector reads 'none'");
    msrv_describe_integrity(UINT32_C(0xc), text, sizeof(text));
    CHECK(strcmp(text, "frozen, replay") == 0, "integrity causes are decoded");
    CHECK(msrv_describe_faults(UINT32_C(0x3ff), text, 8) > 8 && strlen(text) == 7,
          "decoding truncates safely and reports the full length");

    for (i = -7, status = 1; i <= 0; i++)
        status = status && strcmp(msrv_strerror(i), "unknown error") != 0;
    CHECK(status, "every error code has a message");

    printf("\n%s: %d of %d C driver checks passed\n",
           failures ? "FAIL" : "PASS", checks - failures, checks);
    return failures ? 1 : 0;
}

/* ------------------------------------------------------------------ */
/* Trace recording for tb/tb_driver_replay.sv                          */
/* ------------------------------------------------------------------ */

typedef struct recorder {
    FILE *out;
    uint32_t control;
    uint32_t core_control;
    uint32_t crc;
} recorder;

/* Reads return the value a healthy device would return and are emitted with
 * that value and a mask, so the replay checks the RTL agrees with the
 * driver's expectation. Unchecked reads use mask 0. */
static uint32_t record_read(void *ctx, uint32_t offset)
{
    recorder *r = ctx;
    uint32_t value = 0;
    uint32_t mask = 0;

    switch (offset) {
    case MSRV_REG_ID_VERSION: value = MSRV_KERNEL_ID; mask = 0xffffffffu; break;
    case MSRV_REG_CORE_ID: value = MSRV_CORE_ID_VALUE; mask = 0xffffffffu; break;
    case MSRV_REG_MODEL_STATUS:
        value = ((uint32_t)MSRV_MODEL_IMAGE_WORDS << 16) | 1u;
        mask = UINT32_C(0x00ff1f03);
        break;
    case MSRV_REG_MODEL_CRC_ACTUAL: value = r->crc; mask = 0xffffffffu; break;
    case MSRV_REG_CONTROL: value = r->control; mask = UINT32_C(0x11); break;
    case MSRV_REG_CORE_CONTROL: value = r->core_control; mask = UINT32_C(0x3); break;
    default: break;
    }
    fprintf(r->out, "R %02x %08x %08x\n", (unsigned)offset, (unsigned)value, (unsigned)mask);
    return value;
}

static void record_write(void *ctx, uint32_t offset, uint32_t value)
{
    recorder *r = ctx;

    if (offset == MSRV_REG_CONTROL)
        r->control = value & (MSRV_CONTROL_ENABLE | MSRV_CONTROL_MONITOR_ONLY);
    if (offset == MSRV_REG_CORE_CONTROL)
        r->core_control = value & 3u;
    if (offset == MSRV_REG_MODEL_CRC)
        r->crc = value;
    fprintf(r->out, "W %02x %08x\n", (unsigned)offset, (unsigned)value);
}

static int record_poll(void *ctx, uint32_t offset, uint32_t mask, uint32_t value,
                       uint32_t timeout_us)
{
    recorder *r = ctx;

    (void)timeout_us;
    fprintf(r->out, "P %02x %08x %08x\n", (unsigned)offset, (unsigned)mask, (unsigned)value);
    return MSRV_OK;
}

static int record_trace(const char *out_path, const char *model_path,
                        const char *samples_path, long count)
{
    unsigned char buffer[600];
    size_t length = 0;
    /* CORE_CONTROL resets with DATA_READY mode selected. */
    recorder r = { NULL, 0, MSRV_CORE_CONTROL_DRDY, 0 };
    msrv_io io = { record_read, record_write, record_poll, &r };
    msrv_model model;
    msrv_config config;
    msrv_dev dev;
    FILE *samples;
    char line[64];
    long injected = 0;

    if (read_file(model_path, buffer, sizeof(buffer), &length) != 0 ||
        msrv_model_parse(&model, buffer, length) != MSRV_OK) {
        fprintf(stderr, "cannot read model %s\n", model_path);
        return 1;
    }
    samples = fopen(samples_path, "r");
    r.out = fopen(out_path, "w");
    if (!samples || !r.out) {
        fprintf(stderr, "cannot open trace input or output\n");
        return 1;
    }

    msrv_attach(&dev, &io);
    msrv_identify(&dev);
    msrv_load_model(&dev, &model, NULL);
    msrv_default_config(&config);
    config.anomaly_threshold = model.threshold;
    msrv_configure(&dev, &config);
    msrv_start(&dev, false);
    msrv_set_inject_mode(&dev, true);
    while (injected < count && fgets(line, sizeof(line), samples)) {
        unsigned long long packed;
        if (sscanf(line, "%llx", &packed) != 1)
            continue;
        msrv_inject_sample(&dev, (int16_t)(uint16_t)(packed >> 32),
                           (int16_t)(uint16_t)(packed >> 16),
                           (int16_t)(uint16_t)packed);
        injected++;
    }
    fclose(samples);
    fclose(r.out);
    printf("recorded driver trace: %ld injected samples -> %s\n", injected, out_path);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 6 && strcmp(argv[1], "--trace") == 0)
        return record_trace(argv[2], argv[3], argv[4], strtol(argv[5], NULL, 10));
    if (argc == 3)
        return unit_tests(argv[1], (uint32_t)strtoul(argv[2], NULL, 16));
    fprintf(stderr, "usage: test_motorsentinel <model.bin> <crc_hex>\n"
                    "       test_motorsentinel --trace <out> <model.bin> <samples.hex> <count>\n");
    return 2;
}
