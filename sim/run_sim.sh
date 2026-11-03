#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SCRIPT_DIR}"

echo "================================================================================"
echo "    Compiling and Simulating Pipelined FIR Filter in QuestaSim                  "
echo "================================================================================"

# Clean up previous simulation files
rm -rf work transcript *.wlf

# Step 1: Generate Golden Model and Stimulus Vectors
echo "[1/3] Generating Stimulus and Golden Reference Vectors..."
python3 "${PROJECT_DIR}/tb/fir_golden_model.py"

# Step 2: Create work library
echo "[2/3] Preparing QuestaSim Work Library..."
vlib work
vmap work work

# Step 3: Compile SystemVerilog RTL and Testbench
echo "[3/3] Compiling RTL and TB..."
vlog -sv -work work +acc \
    "${PROJECT_DIR}/rtl/fir_adder_stage.sv" \
    "${PROJECT_DIR}/rtl/axi_stream_skid_buffer.sv" \
    "${PROJECT_DIR}/rtl/fir_core_pipelined.sv" \
    "${PROJECT_DIR}/rtl/axi4_lite_regfile.sv" \
    "${PROJECT_DIR}/rtl/fir_filter_top.sv" \
    "${PROJECT_DIR}/tb/fir_filter_top_tb.sv"

# Run simulation
echo "--> Launching QuestaSim Simulation..."
vsim -c -do "run -all; quit -f" work.fir_filter_top_tb

