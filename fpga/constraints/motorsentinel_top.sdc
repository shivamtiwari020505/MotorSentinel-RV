# Timing constraints for the standalone motorsentinel_top build.
#
# The whole data plane runs in one 50 MHz domain: the Icicle reference
# design's FIC3 APB clock. Reg-to-reg paths inside the fabric are the
# measurement of interest.

create_clock -name {PCLK} -period 20.000 [get_ports {PCLK}]

# SCL, SDA and INT1 are asynchronous and enter through two-flop synchronizers
# in both the reader and the protocol guard.
set_false_path -from [get_ports {scl_i sda_i adxl_int1_i}]

# PRESETn comes from CORERESET_PF in the integrated design, which asserts
# asynchronously and releases synchronously to PCLK.
set_false_path -from [get_ports {PRESETn}]

# In the standalone build the APB bus is driven from pins. In the integrated
# design it is an internal FIC3/CoreAPB3 connection in the same clock domain,
# so board-level I/O timing here is not meaningful; budget half a period.
set_input_delay  -clock {PCLK} 10.000 [get_ports {PSEL PENABLE PWRITE PADDR[*] PWDATA[*]}]
set_output_delay -clock {PCLK} 10.000 [get_ports {PRDATA[*] PREADY PSLVERR}]

# Pin outputs that are slow by nature (I2C at 400 kHz, motor enable, LED, IRQ).
set_false_path -to [get_ports {scl_drive_low_o sda_drive_low_o motor_enable_o fault_led_o irq_o}]
