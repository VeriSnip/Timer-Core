Utils_DIR ?= $(PWD)/../Utils-Tool
OpenLibrary_DIR ?= $(PWD)/../Open-Library
# --clean so switching vs_build's main module cannot leave a stale source in
# build/RTL. A `vs_build <top>_fpga` run puts the wrapper there, and a later
# board build would then hand yosys the same module twice.
VSBUILD_ARGS := --clean "--inc_dir=$(OpenLibrary_DIR)"

PROJECT_NAME ?= timer

# VeriSnip variables used by Utils-Tool
QUIET := 1
#DEBUG := 1

# FPGA/Board variables used by Utils-Tool
FPGA_TOP_MODULES := _fpga
PROJECT_FPGA_TOP := $(PROJECT_NAME)_fpga
PROJECT_FPGA_DIR = $(PROJECT_BUILD_DIR)/$(PROJECT_FPGA_TOP)
SUPPORTED_BOARDS := IceSugar_pro
BOARD ?= IceSugar_pro

# Simulation variables used by Utils-Tool
SUPPORTED_SIMULATORS := IVerilog
SIMULATOR := IVerilog

# make sim-run DEBUG=1
IVERILOG_EXTRA_FLAGS ?=
ifeq ($(DEBUG),1)
    IVERILOG_EXTRA_FLAGS += -DDEBUG
endif

## Comment the following line to test the FPGA wrapper instead of the timer core.
PROJECT_SIM_TOP := $(PROJECT_NAME)_tb
TB_SRCS := $(wildcard hardware/testbench/*_tb.v) $(wildcard hardware/testbench/*_tb.sv)

# Build and run every testbench under hardware/testbench, then lint its DUT.
test:
	@if [ -z "$$IN_NIX_SHELL" ]; then \
		echo "Not inside the nix-shell. Run: nix-shell --run \"make test\""; \
		exit 1; \
	fi
	@set -e; \
	tbs="$(TB_SRCS)"; \
	if [ -z "$$tbs" ]; then echo "No *_tb.[v|sv] files found in hardware/testbench"; exit 1; fi; \
	for tb in $$tbs; do \
		name=$$(basename "$${tb%.*}" _tb); \
		echo "==> Running vs_build and make sim for $$name"; \
		vs_build --clean --quiet $$name --inc_dir=$(OpenLibrary_DIR); \
		$(MAKE) sim-run PROJECT_NAME=$$name; \
		$(MAKE) lint PROJECT_NAME=$$name; \
	done

.PHONY: test

include $(Utils_DIR)/utils.mk
