RTL := rtl/motorsentinel_protocol_guard.sv \
	rtl/motorsentinel_safety_policy.sv \
	rtl/motorsentinel_guard_apb.sv

.PHONY: test waves clean

test: build/tb_motorsentinel_guard.vvp
	vvp $<

waves:
	mkdir -p build
	iverilog -g2012 -Wall -DDUMP_WAVES -s tb_motorsentinel_guard -o build/tb_motorsentinel_guard.vvp $(RTL) tb/tb_motorsentinel_guard.sv
	vvp build/tb_motorsentinel_guard.vvp

build/tb_motorsentinel_guard.vvp: $(RTL) tb/tb_motorsentinel_guard.sv
	mkdir -p build
	iverilog -g2012 -Wall -s tb_motorsentinel_guard -o $@ $(RTL) tb/tb_motorsentinel_guard.sv

clean:
	rm -rf build
