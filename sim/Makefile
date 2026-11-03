# ==============================================================================
# Makefile for High-Performance Pipelined FIR Filter Simulation in QuestaSim
# ==============================================================================

RTL_DIR  = ../rtl
TB_DIR   = ../tb
WORK_DIR = work

VSIM = vsim
VLOG = vlog
VLIB = vlib
VMAP = vmap
PYTHON = python3

RTL_SRCS = $(RTL_DIR)/fir_adder_stage.sv \
           $(RTL_DIR)/axi_stream_skid_buffer.sv \
           $(RTL_DIR)/fir_core_pipelined.sv \
           $(RTL_DIR)/axi4_lite_regfile.sv \
           $(RTL_DIR)/fir_filter_top.sv

TB_SRCS  = $(TB_DIR)/fir_filter_top_tb.sv

.PHONY: all stimulus compile sim sim_gui clean

all: sim

stimulus:
	$(PYTHON) $(TB_DIR)/fir_golden_model.py

$(WORK_DIR):
	$(VLIB) $(WORK_DIR)
	$(VMAP) work $(WORK_DIR)

compile: $(WORK_DIR) stimulus
	$(VLOG) -sv -work $(WORK_DIR) +acc $(RTL_SRCS) $(TB_SRCS)

sim: compile
	$(VSIM) -c -do "run -all; quit -f" work.fir_filter_top_tb

sim_gui: compile
	$(VSIM) -gui -do "add wave -r /*; run -all" work.fir_filter_top_tb

clean:
	rm -rf $(WORK_DIR) transcript *.wlf modelsim.ini $(TB_DIR)/*.txt

