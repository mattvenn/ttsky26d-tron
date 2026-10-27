# FPGA build for the TT ICE40UP5K breakout board, following
# ../../shuttle-ttihp26a/multi-seg-monitor.
#
# This mirrors what `tt_fpga.py harden` does, so it runs without the
# tt-support-tools python environment. Deploying to the demoboard still needs
# the real tool (`make flash`).
#
# Needs oss-cad-suite on PATH:  source ~/oss-cad-suite/environment
TT_TOOLS ?= $(HOME)/work/asic-workshop/tinytapeout/tt-support-tools
TT_PY    ?= $(TT_TOOLS)/venv/bin/python
PORT     ?= /dev/ttyACM1

TOP        = tt_um_mattvenn_tron
FREQ       = 40
# 40 MHz has little margin on the UP5K and placement varies by seed: try
# another if nextpnr fails timing.
SEED      ?= 1
CLOCKRATE  = 40000000  # FREQ in Hz, for tt_fpga.py --clockrate
PCF        = $(TT_TOOLS)/fpga/tt_fpga_fabricfoxv2.pcf
WRAPPER    = $(TT_TOOLS)/fpga/tt_fpga_top.v

SOURCES  = src/tt_um_mattvenn_tron.v \
           src/tron.v \
           fpga/rf_top_fpga.v \
           src/input_select.v \
           src/hvsync_generator.v

BUILD    = build

.PHONY: bitstream flash test lint clean

bitstream: $(BUILD)/$(TOP).bin

# Needs tt-support-tools' python environment (not oss-cad-suite); its venv
# also has the mpremote that tt_fpga.py runs.
flash: $(BUILD)/$(TOP).bin
	PATH=$(dir $(TT_PY)):$$PATH $(TT_PY) $(TT_TOOLS)/tt_fpga.py --project-dir . configure \
	    --port $(PORT) --upload \
	    --set-default --clockrate $(CLOCKRATE)

# The wrapper ties uio_in/uio_out/uio_oe to real bidirectional pins and names the
# user module, so it has to be generated per project.
src/_tt_fpga_top.v: $(WRAPPER)
	sed 's/__tt_um_placeholder/$(TOP)/' $< > $@

$(BUILD)/$(TOP).json: src/_tt_fpga_top.v $(SOURCES)
	@mkdir -p $(BUILD)
	yosys -l $(BUILD)/01-synth.log -DSYNTH \
	    -p "read_verilog -sv src/_tt_fpga_top.v $(SOURCES); \
	        synth_ice40 -top tt_fpga_top -json $@"

$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json
	nextpnr-ice40 -l $(BUILD)/02-nextpnr.log --pcf-allow-unconstrained \
	    --seed $(SEED) --freq $(FREQ) --package sg48 --up5k \
	    --pcf $(PCF) --json $< --asc $@

$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	icepack $< $@

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Isrc $(SOURCES) --top-module $(TOP)

test:
	$(MAKE) -C test

clean:
	rm -rf $(BUILD) src/_tt_fpga_top.v
	$(MAKE) -C test clean
