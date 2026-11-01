/*
 * msrvctl: command-line control of the MotorSentinel-RV fabric core on Linux.
 *
 *   msrvctl [-d /dev/uioN] info
 *   msrvctl [-d /dev/uioN] load <model.bin>      load, verify and configure
 *   msrvctl [-d /dev/uioN] start [--monitor-only]
 *   msrvctl [-d /dev/uioN] stop | arm | clear
 *   msrvctl [-d /dev/uioN] status [--json]
 *   msrvctl [-d /dev/uioN] window                 last inferred window
 *   msrvctl [-d /dev/uioN] monitor [--json] [--count N]
 *   msrvctl [-d /dev/uioN] replay <samples.csv>   x,y,z per line via APB
 *
 * The motor-disable decision never depends on this program: it only
 * configures the fabric and reports what the hardware already decided.
 */

#define _POSIX_C_SOURCE 200809L

#include "motorsentinel.h"
#include "motorsentinel_uio.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int usage(void)
{
    fprintf(stderr,
            "usage: msrvctl [-d /dev/uioN] <command> [options]\n"
            "commands: info, load <model.bin>, start [--monitor-only], stop, arm,\n"
            "          clear, status [--json], window, monitor [--json] [--count N],\n"
            "          replay <samples.csv>\n");
    return 2;
}

static int fail(const char *what, int error)
{
    if (error == MSRV_ERR_IO)
        fprintf(stderr, "msrvctl: %s: %s\n", what, strerror(errno));
    else
        fprintf(stderr, "msrvctl: %s: %s\n", what, msrv_strerror(error));
    return 1;
}

static bool has_flag(int argc, char **argv, const char *flag)
{
    int i;

    for (i = 0; i < argc; i++)
        if (strcmp(argv[i], flag) == 0)
            return true;
    return false;
}

static double now_seconds(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void print_status(const msrv_dev *dev, bool json)
{
    msrv_status s;
    char faults[256];
    char integrity[128];

    msrv_read_status(dev, &s);
    msrv_describe_faults(s.fault_vector, faults, sizeof(faults));
    msrv_describe_integrity(s.integrity_status, integrity, sizeof(integrity));
    if (json) {
        printf("{\"time\":%.3f,\"motor\":%s,\"armed\":%s,\"trip\":%s,"
               "\"model_valid\":%s,\"score\":%u,\"windows\":%u,"
               "\"latency_cycles\":%u,\"max_latency_cycles\":%u,"
               "\"fault_vector\":%u,\"faults\":\"%s\",\"integrity\":\"%s\","
               "\"sensor_id\":%u,\"sensor_configured\":%s,\"samples\":%u,"
               "\"i2c_nacks\":%u}\n",
               now_seconds(),
               (s.status & MSRV_STATUS_MOTOR_ENABLE) ? "true" : "false",
               (s.status & MSRV_STATUS_ARMED) ? "true" : "false",
               (s.status & MSRV_STATUS_TRIP) ? "true" : "false",
               (s.model_status & MSRV_MODEL_STATUS_VALID) ? "true" : "false",
               MSRV_INFERENCE_SCORE(s.inference_status), s.window_count,
               MSRV_LATENCY_LAST(s.latency), MSRV_LATENCY_MAX(s.latency),
               s.fault_vector, faults, integrity,
               MSRV_ACQ_DEVICE_ID(s.acq_status),
               (s.acq_status & MSRV_ACQ_CONFIGURED) ? "true" : "false",
               s.acq_samples, MSRV_ACQ_NACK_COUNT(s.acq_status));
    } else {
        printf("motor        %s (%s, %s)\n",
               (s.status & MSRV_STATUS_MOTOR_ENABLE) ? "ON" : "OFF",
               (s.status & MSRV_STATUS_ARMED) ? "armed" : "disarmed",
               (s.status & MSRV_STATUS_TRIP) ? "TRIPPED" : "no trip");
        printf("model        %s\n",
               (s.model_status & MSRV_MODEL_STATUS_VALID) ? "valid" : "invalid");
        printf("faults       %s\n", faults);
        printf("integrity    %s\n", integrity);
        printf("score        %u (window %u)\n",
               MSRV_INFERENCE_SCORE(s.inference_status), s.window_count);
        printf("latency      %u cycles last, %u worst\n",
               MSRV_LATENCY_LAST(s.latency), MSRV_LATENCY_MAX(s.latency));
        printf("sensor       DEVID 0x%02x, %s, %u samples, %u NACKs\n",
               MSRV_ACQ_DEVICE_ID(s.acq_status),
               (s.acq_status & MSRV_ACQ_CONFIGURED) ? "configured" : "not configured",
               s.acq_samples, MSRV_ACQ_NACK_COUNT(s.acq_status));
    }
}

static int load_model_file(const msrv_dev *dev, const char *path)
{
    unsigned char buffer[(MSRV_MODEL_IMAGE_WORDS + 2u) * 4u];
    msrv_model model;
    msrv_config config;
    uint32_t model_status = 0;
    size_t length;
    FILE *file;
    int result;

    file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "msrvctl: %s: %s\n", path, strerror(errno));
        return 1;
    }
    length = fread(buffer, 1, sizeof(buffer), file);
    fclose(file);
    result = msrv_model_parse(&model, buffer, length);
    if (result != MSRV_OK)
        return fail(path, result);

    result = msrv_load_model(dev, &model, &model_status);
    if (result != MSRV_OK) {
        fprintf(stderr, "msrvctl: MODEL_STATUS 0x%08x\n", model_status);
        return fail("load", result);
    }
    msrv_default_config(&config);
    if (model.has_threshold)
        config.anomaly_threshold = model.threshold;
    msrv_configure(dev, &config);
    printf("model committed: CRC-32 0x%08x, threshold %u\n",
           msrv_image_crc(model.image), config.anomaly_threshold);
    return 0;
}

static int monitor(msrv_uio *uio, const msrv_dev *dev, bool json, long count)
{
    long events = 0;

    while (count < 0 || events < count) {
        uint32_t irq;
        uint32_t integrity;
        int fired;

        msrv_ack_events(dev, NULL, NULL);
        fired = msrv_uio_wait_irq(uio, 1000);
        if (fired < 0)
            return fail("wait for interrupt", fired);
        msrv_ack_events(dev, &irq, &integrity);
        if (!fired) {
            if (json)
                print_status(dev, true);  /* 1 Hz heartbeat for dashboards */
            continue;
        }
        events++;
        if (json) {
            print_status(dev, true);
        } else {
            char text[128];
            msrv_describe_integrity(integrity, text, sizeof(text));
            printf("[%.3f] event:%s%s%s%s integrity: %s\n", now_seconds(),
                   (irq & MSRV_IRQ_TRIP) ? " TRIP" : "",
                   (irq & MSRV_IRQ_PROTOCOL_FAULT) ? " protocol-fault" : "",
                   (irq & MSRV_IRQ_CLEAR_ACCEPTED) ? " clear-accepted" : "",
                   (irq & MSRV_IRQ_CLEAR_REJECTED) ? " clear-rejected" : "",
                   text);
            print_status(dev, false);
        }
        fflush(stdout);
    }
    return 0;
}

static int replay(const msrv_dev *dev, const char *path)
{
    FILE *file = fopen(path, "r");
    char line[128];
    uint32_t windows;
    long samples = 0;
    int result = 0;

    if (!file) {
        fprintf(stderr, "msrvctl: %s: %s\n", path, strerror(errno));
        return 1;
    }
    windows = msrv_read(dev, MSRV_REG_WINDOW_COUNT);
    msrv_set_inject_mode(dev, true);
    while (fgets(line, sizeof(line), file)) {
        int x, y, z;
        int error;

        if (sscanf(line, "%d , %d , %d", &x, &y, &z) != 3)
            continue;  /* header or comment */
        error = msrv_inject_sample(dev, (int16_t)x, (int16_t)y, (int16_t)z);
        if (error != MSRV_OK) {
            result = fail("inject", error);
            break;
        }
        samples++;
        if (msrv_read(dev, MSRV_REG_WINDOW_COUNT) != windows) {
            windows = msrv_read(dev, MSRV_REG_WINDOW_COUNT);
            printf("window %u score %u\n", windows - 1u,
                   MSRV_INFERENCE_SCORE(msrv_read(dev, MSRV_REG_INFERENCE_STATUS)));
        }
    }
    fclose(file);
    msrv_set_inject_mode(dev, false);
    printf("replayed %ld samples\n", samples);
    return result;
}

int main(int argc, char **argv)
{
    const char *device = NULL;
    const char *command;
    msrv_uio uio;
    msrv_io io;
    msrv_dev dev;
    int result;
    int status = 0;

    if (argc >= 3 && strcmp(argv[1], "-d") == 0) {
        device = argv[2];
        argc -= 2;
        argv += 2;
    }
    if (argc < 2)
        return usage();
    command = argv[1];

    result = msrv_uio_open(&uio, device);
    if (result != MSRV_OK)
        return fail(device ? device : "find UIO device \"" MSRV_UIO_NAME "\"", result);
    msrv_uio_io(&uio, &io);
    msrv_attach(&dev, &io);
    result = msrv_identify(&dev);
    if (result != MSRV_OK) {
        msrv_uio_close(&uio);
        return fail(uio.device, result);
    }

    if (strcmp(command, "info") == 0) {
        printf("device       %s\n", uio.device);
        printf("ID           kernel 0x%08x, data plane 0x%08x\n",
               msrv_read(&dev, MSRV_REG_ID_VERSION), msrv_read(&dev, MSRV_REG_CORE_ID));
        print_status(&dev, false);
    } else if (strcmp(command, "load") == 0 && argc >= 3) {
        status = load_model_file(&dev, argv[2]);
    } else if (strcmp(command, "start") == 0) {
        result = msrv_start(&dev, has_flag(argc, argv, "--monitor-only"));
        status = result == MSRV_OK ? 0 : fail("start (is a valid model loaded?)", result);
    } else if (strcmp(command, "stop") == 0) {
        msrv_stop(&dev);
    } else if (strcmp(command, "arm") == 0) {
        result = msrv_arm(&dev);
        status = result == MSRV_OK ? 0 : fail("arm (clear the trip first)", result);
    } else if (strcmp(command, "clear") == 0) {
        result = msrv_request_clear(&dev);
        if (result == MSRV_OK)
            printf("clear accepted; run 'msrvctl arm' to restart the motor\n");
        else
            status = fail("clear", result);
    } else if (strcmp(command, "status") == 0) {
        print_status(&dev, has_flag(argc, argv, "--json"));
    } else if (strcmp(command, "window") == 0) {
        msrv_window w;
        size_t i;
        msrv_read_window(&dev, &w);
        printf("window %u score %u\n", w.sequence, w.score);
        for (i = 0; i < MSRV_FEATURES; i++)
            printf("  f[%2zu] %11d  q %4d  y %4d\n", i, w.features[i], w.q[i], w.y[i]);
        printf("  h:");
        for (i = 0; i < MSRV_HIDDEN; i++)
            printf(" %d", w.h[i]);
        printf("\n");
    } else if (strcmp(command, "monitor") == 0) {
        long count = -1;
        int i;
        for (i = 2; i + 1 < argc; i++)
            if (strcmp(argv[i], "--count") == 0)
                count = strtol(argv[i + 1], NULL, 10);
        status = monitor(&uio, &dev, has_flag(argc, argv, "--json"), count);
    } else if (strcmp(command, "replay") == 0 && argc >= 3) {
        status = replay(&dev, argv[2]);
    } else {
        status = usage();
    }

    msrv_uio_close(&uio);
    return status;
}
