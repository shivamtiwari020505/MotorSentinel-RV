GUARD_RTL := rtl/motorsentinel_protocol_guard.sv \
	rtl/motorsentinel_safety_policy.sv \
	rtl/motorsentinel_guard_apb.sv
FEATURE_RTL := rtl/motorsentinel_feature_extractor.sv
PYTHON ?= python3

.PHONY: test python-test guard-test feature-test feature-vectors waves feature-waves clean

test: python-test guard-test feature-test

python-test:
	$(PYTHON) -m unittest discover -s tests -v

guard-test: build/tb_motorsentinel_guard.vvp
	vvp build/tb_motorsentinel_guard.vvp

feature-vectors:
	mkdir -p build
	$(PYTHON) tools/generate_feature_vectors.py --output-dir build

feature-test: feature-vectors build/tb_motorsentinel_feature_extractor.vvp
	vvp build/tb_motorsentinel_feature_extractor.vvp

waves:
	mkdir -p build
	iverilog -g2012 -Wall -DDUMP_WAVES -s tb_motorsentinel_guard -o build/tb_motorsentinel_guard.vvp $(GUARD_RTL) tb/tb_motorsentinel_guard.sv
	vvp build/tb_motorsentinel_guard.vvp

feature-waves: feature-vectors
	mkdir -p build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array -DDUMP_WAVES -s tb_motorsentinel_feature_extractor -o build/tb_motorsentinel_feature_extractor.vvp $(FEATURE_RTL) tb/tb_motorsentinel_feature_extractor.sv
	vvp build/tb_motorsentinel_feature_extractor.vvp

build/tb_motorsentinel_guard.vvp: $(GUARD_RTL) tb/tb_motorsentinel_guard.sv
	mkdir -p build
	iverilog -g2012 -Wall -s tb_motorsentinel_guard -o $@ $(GUARD_RTL) tb/tb_motorsentinel_guard.sv

build/tb_motorsentinel_feature_extractor.vvp: $(FEATURE_RTL) tb/tb_motorsentinel_feature_extractor.sv
	mkdir -p build
	iverilog -g2012 -Wall -Wno-sensitivity-entire-array -s tb_motorsentinel_feature_extractor -o $@ $(FEATURE_RTL) tb/tb_motorsentinel_feature_extractor.sv

clean:
	rm -rf build
