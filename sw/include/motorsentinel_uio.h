#ifndef MOTORSENTINEL_UIO_H
#define MOTORSENTINEL_UIO_H

/*
 * Linux UIO backend for libmotorsentinel.
 *
 * The device is bound to uio_pdrv_genirq through the device-tree node in
 * sw/linux/motorsentinel-overlay.dtso. Its UIO name is the node name,
 * "motorsentinel".
 */

#include <stddef.h>
#include <stdint.h>

#include "motorsentinel.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MSRV_UIO_NAME "motorsentinel"

typedef struct msrv_uio {
    int fd;
    void *map;
    size_t map_length;
    volatile uint32_t *regs;
    char device[32];
} msrv_uio;

/* device: "/dev/uioN", or NULL to find the UIO named MSRV_UIO_NAME. */
int msrv_uio_open(msrv_uio *uio, const char *device);
void msrv_uio_close(msrv_uio *uio);
/* Fills an msrv_io whose poll() sleeps between reads. */
void msrv_uio_io(msrv_uio *uio, msrv_io *io);
/* Unmasks the interrupt and waits for it. Returns 1 when it fired, 0 on
 * timeout (timeout_ms < 0 waits forever) and MSRV_ERR_IO on failure.
 * Acknowledge the device causes (msrv_ack_events) before waiting again,
 * because the interrupt is level-sensitive. */
int msrv_uio_wait_irq(msrv_uio *uio, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* MOTORSENTINEL_UIO_H */
