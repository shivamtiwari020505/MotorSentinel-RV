GUARD_RTL := rtl/motorsentinel_protocol_guard.sv \
	rtl/motorsentinel_safety_policy.sv \
	rtl/motorsentinel_guard_apb.sv
FEATURE_RTL := rtl/motorsentinel_feature_extractor.sv
ENGINE_RTL := rtl/edgematrix_pe.sv \
	rtl/edgematrix_array.sv \
	rtl/edgematrix_autoencoder.sv \
	rtl/motorsentinel_model_store.sv \
	rtl/motorsentinel_inference.sv
CORE_RTL := $(ENGINE_RTL) \
	rtl/motorsentinel_integrity_monitor.sv \
	$(FEATURE_RTL) \
	$(GUARD_RTL) \
	rtl/motorsentinel_core_apb.sv
READER_RTL := rtl/motorsentinel_adxl345_reader.sv
TOP_RTL := $(CORE_RTL) $(READER_RTL) rtl/motorsentinel_top.sv
SENSOR_MODEL := tb/adxl345_i2c_model.sv
PYTHON ?= python3
IVERILOG := iverilog -g2012 -Wall -Wno-sensitivity-entire-array

.PHONY: test python-test guard-test feature-test inference-test core-test \
	reader-test top-test feature-vectors system-vectors waves feature-waves \
	core-waves train libero clean

test: python-test guard-test feature-test inference-test core-test reader-test top-test

python-test:
	$(PYTHON) -m unittest discover -s tests -v

guard-test: build/tb_motorsentinel_guard.vvp
	vvp build/tb_motorsentinel_guard.vvp

feature-vectors:
	mkdir -p build
	$(PYTHON) tools/generate_feature_vectors.py --output-dir build

system-vectors:
	mkdir -p build
	$(PYTHON) tools/generate_system_vectors.py --output-dir build

feature-test: feature-vectors build/tb_motorsentinel_feature_extractor.vvp
	vvp build/tb_motorsentinel_feature_extractor.vvp

inference-test: system-vectors build/tb_edgematrix_inference.vvp
	vvp build/tb_edgematrix_inference.vvp

core-test: system-vectors build/tb_motorsentinel_core.vvp
	vvp build/tb_motorsentinel_core.vvp

reader-test: build/tb_adxl345_reader.vvp
	vvp build/tb_adxl345_reader.vvp

top-test: system-vectors build/tb_motorsentinel_top.vvp
	vvp build/tb_motorsentinel_top.vvp

# Offline: retrains the committed model (requires NumPy).
train:
	$(PYTHON) tools/train_autoencoder.py

# Requires Libero SoC with a license covering MPFS250T; not part of `test`.
LIBERO ?= libero
libero:
	mkdir -p build/libero
	$(LIBERO) SCRIPT:fpga/libero/build_motorsentinel.tcl LOGFILE:build/libero/libero.log
	$(PYTHON) tools/libero_report.py --build-dir build/libero

waves:
	mkdir -p build
	iverilog -g2012 -Wall -DDUMP_WAVES -s tb_motorsentinel_guard -o build/tb_motorsentinel_guard.vvp $(GUARD_RTL) tb/tb_motorsentinel_guard.sv
	vvp build/tb_motorsentinel_guard.vvp

feature-waves: feature-vectors
	mkdir -p build
	$(IVERILOG) -DDUMP_WAVES -s tb_motorsentinel_feature_extractor -o build/tb_motorsentinel_feature_extractor.vvp $(FEATURE_RTL) tb/tb_motorsentinel_feature_extractor.sv
	vvp build/tb_motorsentinel_feature_extractor.vvp

core-waves: system-vectors
	mkdir -p build
	$(IVERILOG) -DDUMP_WAVES -s tb_motorsentinel_core -o build/tb_motorsentinel_core.vvp $(CORE_RTL) tb/tb_motorsentinel_core.sv
	vvp build/tb_motorsentinel_core.vvp

build/tb_motorsentinel_guard.vvp: $(GUARD_RTL) tb/tb_motorsentinel_guard.sv
	mkdir -p build
	iverilog -g2012 -Wall -s tb_motorsentinel_guard -o $@ $(GUARD_RTL) tb/tb_motorsentinel_guard.sv

build/tb_motorsentinel_feature_extractor.vvp: $(FEATURE_RTL) tb/tb_motorsentinel_feature_extractor.sv
	mkdir -p build
	$(IVERILOG) -s tb_motorsentinel_feature_extractor -o $@ $(FEATURE_RTL) tb/tb_motorsentinel_feature_extractor.sv

build/tb_edgematrix_inference.vvp: $(ENGINE_RTL) tb/tb_edgematrix_inference.sv
	mkdir -p build
	$(IVERILOG) -s tb_edgematrix_inference -o $@ $(ENGINE_RTL) tb/tb_edgematrix_inference.sv

build/tb_motorsentinel_core.vvp: $(CORE_RTL) tb/tb_motorsentinel_core.sv
	mkdir -p build
	$(IVERILOG) -s tb_motorsentinel_core -o $@ $(CORE_RTL) tb/tb_motorsentinel_core.sv

build/tb_adxl345_reader.vvp: $(READER_RTL) $(SENSOR_MODEL) tb/tb_adxl345_reader.sv
	mkdir -p build
	$(IVERILOG) -s tb_adxl345_reader -o $@ $(READER_RTL) $(SENSOR_MODEL) tb/tb_adxl345_reader.sv

build/tb_motorsentinel_top.vvp: $(TOP_RTL) $(SENSOR_MODEL) tb/tb_motorsentinel_top.sv
	mkdir -p build
	$(IVERILOG) -s tb_motorsentinel_top -o $@ $(TOP_RTL) $(SENSOR_MODEL) tb/tb_motorsentinel_top.sv

clean:
	rm -rf build
