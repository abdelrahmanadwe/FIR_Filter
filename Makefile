# ==============================================================================
# High-Performance Pipelined FIR Filter IP - Root Makefile
# ==============================================================================

SHELL      := /bin/bash
PROJECT_DIR:= $(CURDIR)
RTL_DIR    := $(PROJECT_DIR)/rtl
TB_DIR     := $(PROJECT_DIR)/tb
SIM_DIR    := $(PROJECT_DIR)/sim
WORK_DIR   := $(SIM_DIR)/work

VENV_DIR   := $(PROJECT_DIR)/.venv
PYTHON     := $(shell if [ -f $(VENV_DIR)/bin/python3 ]; then echo $(VENV_DIR)/bin/python3; else echo python3; fi)

VSIM       := vsim
VLOG       := vlog
VLIB       := vlib
VMAP       := vmap

RTL_SRCS   := $(RTL_DIR)/fir_adder_stage.sv \
              $(RTL_DIR)/axi_stream_skid_buffer.sv \
              $(RTL_DIR)/fir_core_pipelined.sv \
              $(RTL_DIR)/axi4_lite_regfile.sv \
              $(RTL_DIR)/fir_filter_top.sv

TB_SRCS    := $(TB_DIR)/fir_filter_top_tb.sv

.PHONY: all venv stimulus dsp_chain compile sim sim_gui clean help

all: sim

# ------------------------------------------------------------------------------
# Python Virtual Environment Setup
# ------------------------------------------------------------------------------
venv: $(VENV_DIR)/bin/activate

$(VENV_DIR)/bin/activate: $(PROJECT_DIR)/requirements.txt
	@echo "==> Creating Python virtual environment in $(VENV_DIR)..."
	python3 -m venv $(VENV_DIR)
	$(VENV_DIR)/bin/pip install --upgrade pip
	$(VENV_DIR)/bin/pip install -r $(PROJECT_DIR)/requirements.txt
	@touch $(VENV_DIR)/bin/activate
	@echo "==> Virtual environment created successfully!"

# ------------------------------------------------------------------------------
# Golden Model & DSP Verification
# ------------------------------------------------------------------------------
stimulus:
	@echo "==> Generating parameterized filter coefficients and test stimulus..."
	$(PYTHON) $(TB_DIR)/fir_golden_model.py

dsp_chain:
	@echo "==> Running End-to-End DSP chain (ADC -> FIR -> DAC -> Sinc Interpolation)..."
	$(PYTHON) $(TB_DIR)/end_to_end_dsp_chain.py

# ------------------------------------------------------------------------------
# QuestaSim Compilation & Simulation
# ------------------------------------------------------------------------------
$(WORK_DIR):
	@mkdir -p $(SIM_DIR)
	@cd $(SIM_DIR) && $(VLIB) work && $(VMAP) work work

compile: $(WORK_DIR) stimulus
	@echo "==> Compiling SystemVerilog RTL and Testbench with QuestaSim..."
	@cd $(SIM_DIR) && $(VLOG) -sv -work work +acc $(RTL_SRCS) $(TB_SRCS)

sim: compile
	@echo "==> Executing QuestaSim Batch Simulation..."
	@cd $(SIM_DIR) && $(VSIM) -c -do "run -all; quit -f" work.fir_filter_top_tb

sim_gui: compile
	@echo "==> Launching QuestaSim GUI..."
	@cd $(SIM_DIR) && $(VSIM) -gui -do "add wave -r /*; run -all" work.fir_filter_top_tb

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
clean:
	@echo "==> Cleaning simulation artifacts..."
	rm -rf $(SIM_DIR)/work $(SIM_DIR)/transcript $(SIM_DIR)/*.wlf $(SIM_DIR)/modelsim.ini
	rm -rf $(TB_DIR)/*.txt __pycache__ $(TB_DIR)/__pycache__
	@echo "==> Clean complete."

clean_all: clean
	@echo "==> Removing virtual environment..."
	rm -rf $(VENV_DIR)

help:
	@echo "High-Performance FIR Filter Makefile Targets:"
	@echo "  make (or make sim) : Compile and run self-checking simulation (QuestaSim)"
	@echo "  make sim_gui       : Run simulation with QuestaSim GUI waveforms"
	@echo "  make dsp_chain     : Run End-to-End DSP chain simulation (ADC->FIR->DAC) and generate plots"
	@echo "  make venv          : Create isolated Python virtual environment (.venv) and install dependencies"
	@echo "  make clean         : Remove compilation and simulation artifacts"
	@echo "  make clean_all     : Remove simulation artifacts and virtual environment"
