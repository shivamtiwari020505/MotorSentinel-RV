# libmotorsentinel, msrvctl and the portable host tests.
#
#   make -C sw                                     Linux build (library + msrvctl)
#   make -C sw CROSS_COMPILE=riscv64-linux-gnu-    PolarFire SoC (RISC-V Linux)
#   make -C sw test                                portable host tests, any OS
#   make -C sw dtbo PLIC_IRQ=<n>                   device-tree overlay
#
# Outputs go to build/sw/<target> at the repository root.

CROSS_COMPILE ?=
CC := $(CROSS_COMPILE)gcc
AR := $(CROSS_COMPILE)ar
DTC ?= dtc
CPP ?= cpp
TARGET := $(if $(CROSS_COMPILE),$(patsubst %-,%,$(CROSS_COMPILE)),native)
BUILD ?= ../build/sw/$(TARGET)
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic -Werror -Iinclude

.PHONY: all test dtbo clean

all: $(BUILD)/libmotorsentinel.a $(BUILD)/msrvctl

test: $(BUILD)/test_motorsentinel

$(BUILD)/%.o: lib/%.c include/motorsentinel.h include/motorsentinel_regs.h include/motorsentinel_uio.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/libmotorsentinel.a: $(BUILD)/motorsentinel.o $(BUILD)/motorsentinel_uio.o
	$(AR) rcs $@ $^

$(BUILD)/msrvctl: tools/msrvctl.c $(BUILD)/libmotorsentinel.a
	$(CC) $(CFLAGS) -o $@ $< $(BUILD)/libmotorsentinel.a

# Portable: the UIO backend is not needed by the host tests.
$(BUILD)/test_motorsentinel: tests/test_motorsentinel.c lib/motorsentinel.c include/motorsentinel.h include/motorsentinel_regs.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ tests/test_motorsentinel.c lib/motorsentinel.c

# The PLIC source of the fabric interrupt comes from the integrated design's
# memory map and is deliberately required rather than guessed.
dtbo:
	@test -n "$(PLIC_IRQ)" || { echo "set PLIC_IRQ to the PLIC source of the MSS_INT_F2M line used for irq_o"; exit 1; }
	mkdir -p $(BUILD)
	$(CPP) -nostdinc -undef -x assembler-with-cpp -DMSRV_PLIC_IRQ=$(PLIC_IRQ) \
		linux/motorsentinel-overlay.dtso -o $(BUILD)/motorsentinel-overlay.pp.dtso
	$(DTC) -@ -I dts -O dtb -o $(BUILD)/motorsentinel-overlay.dtbo \
		$(BUILD)/motorsentinel-overlay.pp.dtso

clean:
	rm -rf $(BUILD)
