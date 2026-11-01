/* Linux UIO backend for libmotorsentinel. See motorsentinel_uio.h. */

#define _POSIX_C_SOURCE 200809L

#include "motorsentinel_uio.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define UIO_MAX_DEVICES 64

static int read_sysfs(const char *path, char *buffer, size_t size)
{
    FILE *file = fopen(path, "r");
    size_t length;

    if (!file)
        return -1;
    length = fread(buffer, 1, size - 1, file);
    fclose(file);
    buffer[length] = '\0';
    while (length && (buffer[length - 1] == '\n' || buffer[length - 1] == ' '))
        buffer[--length] = '\0';
    return 0;
}

static int read_sysfs_number(const char *path, unsigned long *value)
{
    char text[64];
    char *end;

    if (read_sysfs(path, text, sizeof(text)) != 0)
        return -1;
    errno = 0;
    *value = strtoul(text, &end, 0);
    return (errno || end == text) ? -1 : 0;
}

static int find_device(char *device, size_t size)
{
    char path[96];
    char name[64];
    int index;

    for (index = 0; index < UIO_MAX_DEVICES; index++) {
        snprintf(path, sizeof(path), "/sys/class/uio/uio%d/name", index);
        if (read_sysfs(path, name, sizeof(name)) != 0)
            continue;
        if (strcmp(name, MSRV_UIO_NAME) == 0) {
            snprintf(device, size, "/dev/uio%d", index);
            return 0;
        }
    }
    errno = ENODEV;
    return -1;
}

int msrv_uio_open(msrv_uio *uio, const char *device)
{
    char path[96];
    const char *base;
    unsigned long size;
    unsigned long offset;
    long page;

    memset(uio, 0, sizeof(*uio));
    uio->fd = -1;
    if (device) {
        snprintf(uio->device, sizeof(uio->device), "%s", device);
    } else if (find_device(uio->device, sizeof(uio->device)) != 0) {
        return MSRV_ERR_IO;
    }

    /* Map 0 attributes: region size and its offset inside the first page
     * (the 256-byte APB slot is not page aligned). */
    base = strrchr(uio->device, '/');
    base = base ? base + 1 : uio->device;
    snprintf(path, sizeof(path), "/sys/class/uio/%s/maps/map0/size", base);
    if (read_sysfs_number(path, &size) != 0)
        return MSRV_ERR_IO;
    snprintf(path, sizeof(path), "/sys/class/uio/%s/maps/map0/offset", base);
    if (read_sysfs_number(path, &offset) != 0)
        offset = 0;

    uio->fd = open(uio->device, O_RDWR | O_CLOEXEC);
    if (uio->fd < 0)
        return MSRV_ERR_IO;

    page = sysconf(_SC_PAGESIZE);
    if (page <= 0)
        page = 4096;
    uio->map_length = (size_t)((offset + size + (unsigned long)page - 1) /
                               (unsigned long)page * (unsigned long)page);
    uio->map = mmap(NULL, uio->map_length, PROT_READ | PROT_WRITE, MAP_SHARED,
                    uio->fd, 0);
    if (uio->map == MAP_FAILED) {
        uio->map = NULL;
        close(uio->fd);
        uio->fd = -1;
        return MSRV_ERR_IO;
    }
    uio->regs = (volatile uint32_t *)((volatile uint8_t *)uio->map + offset);
    return MSRV_OK;
}

void msrv_uio_close(msrv_uio *uio)
{
    if (uio->map)
        munmap(uio->map, uio->map_length);
    if (uio->fd >= 0)
        close(uio->fd);
    uio->map = NULL;
    uio->regs = NULL;
    uio->fd = -1;
}

static uint32_t uio_read(void *ctx, uint32_t offset)
{
    msrv_uio *uio = ctx;
    return uio->regs[offset / 4u];
}

static void uio_write(void *ctx, uint32_t offset, uint32_t value)
{
    msrv_uio *uio = ctx;
    uio->regs[offset / 4u] = value;
}

static int uio_poll(void *ctx, uint32_t offset, uint32_t mask, uint32_t value,
                    uint32_t timeout_us)
{
    const struct timespec pause = { 0, 10000 };  /* 10 us */
    uint32_t waited = 0;

    for (;;) {
        if ((uio_read(ctx, offset) & mask) == value)
            return MSRV_OK;
        if (waited >= timeout_us)
            return MSRV_ERR_TIMEOUT;
        nanosleep(&pause, NULL);
        waited += 10;
    }
}

void msrv_uio_io(msrv_uio *uio, msrv_io *io)
{
    io->read = uio_read;
    io->write = uio_write;
    io->poll = uio_poll;
    io->ctx = uio;
}

int msrv_uio_wait_irq(msrv_uio *uio, int timeout_ms)
{
    uint32_t unmask = 1;
    uint32_t count;
    struct pollfd request;
    int ready;

    /* uio_pdrv_genirq masks the line after each interrupt. */
    if (write(uio->fd, &unmask, sizeof(unmask)) != (ssize_t)sizeof(unmask))
        return MSRV_ERR_IO;

    request.fd = uio->fd;
    request.events = POLLIN;
    request.revents = 0;
    do {
        ready = poll(&request, 1, timeout_ms);
    } while (ready < 0 && errno == EINTR);
    if (ready < 0)
        return MSRV_ERR_IO;
    if (ready == 0)
        return 0;
    if (read(uio->fd, &count, sizeof(count)) != (ssize_t)sizeof(count))
        return MSRV_ERR_IO;
    return 1;
}
