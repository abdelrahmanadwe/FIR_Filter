# High-Performance Pipelined FIR Filter IP

A fully parameterized, high-throughput SystemVerilog hardware IP implementing a **Finite Impulse Response (FIR) Filter**. Designed for demanding Digital Signal Processing (DSP) applications, Software-Defined Radio (SDR), audio processing, and high-speed SoC streaming architectures.

---

## 🌟 Key Features

- **Maximum Operating Frequency ($F_{\max}$) & Throughput:**
  - Fully pipelined architecture: 1 multiplication stage + $\lceil\log_2(N)\rceil$ registered binary adder stages + 1 saturation/rounding stage.
  - Zero combinational feedback paths: achieves **1 sample/cycle throughput** (sustained 100% bandwidth).
- **Streaming Interface (AXI4-Stream):**
  - Standard `s_axis_*` (Slave) and `m_axis_*` (Master) interfaces with `tvalid`, `tready`, `tdata`, and `tlast`.
  - Integrated **2-Entry Skid Buffer** on output to cleanly decouple ready/valid timing closures without bubble cycles or dropped samples.
- **Control & Configuration (AXI4-Lite):**
  - Full runtime control plane supporting ARM AMBA AXI4-Lite slave specification.
  - Runtime programmable filter coefficients ($h_0, h_1, \dots, h_{N-1}$): change filter response (Low-pass, High-pass, Band-pass) on-the-fly without FPGA re-synthesis.
  - Runtime dynamic tap scaling: select any active number of taps from $1$ to $\text{MAX\_TAPS}$.
  - Runtime output scale shift, filter enable, delay-line soft reset, and zero-latency hardware bypass.
- **Fixed-Point Arithmetic & Saturation:**
  - Full-precision internal accumulation with round-to-nearest logic ($+ 2^{\text{shift}-1}$).
  - Two's complement signed saturation logic: prevents audio/signal wrap-around distortion and flags sticky `OVERFLOW` in the status register.

---

## 📐 Architecture Overview

```text
                                  +-------------------------------------------------------------+
                                  |                     fir_filter_top                          |
                                  |                                                             |
   s_axis_tdata (Signed 16-bit)   |   +-----------------------+     +-----------------------+   |   m_axis_tdata
  ===============================>|-->|  fir_core_pipelined   |---->| axi_stream_skid_buf   |-->|=================>
   s_axis_tvalid / s_axis_tready  |   |  - Delay Line         |     | - 2-entry ping-pong   |   |   m_axis_tvalid
   s_axis_tlast                   |   |  - Mult Stage         |     | - Decoupled timing    |   |   m_axis_tready
                                  |   |  - Pipelined AdderTree|     +-----------------------+   |   m_axis_tlast
                                  |   |  - Round & Saturate   |                                 |
                                  |   +-----------------------+                                 |
                                  |               ^                                             |
                                  |               | Config / Coeffs                             |
                                  |               v                                             |
   s_axi_aw*, s_axi_w*            |   +-----------------------+                                 |
  ===============================>|-->|  axi4_lite_regfile    |                                 |
   s_axi_ar*, s_axi_r*            |   |  - Control / Status   |                                 |
   (AXI4-Lite 32-bit Control Bus) |   |  - Dynamic Coeff RAM  |                                 |
                                  |   +-----------------------+                                 |
                                  +-------------------------------------------------------------+
```

---

## 🔌 Hardware Parameters

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `DATA_WIDTH` | `16` | Bit width of incoming and outgoing audio/RF signal samples (signed). |
| `COEFF_WIDTH` | `16` | Bit width of filter impulse response coefficients (signed Q15). |
| `MAX_TAPS` | `16` | Maximum number of filter taps hardware can support (e.g. 8, 16, 32, 64). |
| `AXI_ADDR_WIDTH`| `8` | Address bus width for AXI4-Lite control interface. |
| `AXI_DATA_WIDTH`| `32` | Data bus width for AXI4-Lite control interface. |
| `DEF_SCALE` | `15` | Default right-shift scaling factor (15 for Q15 fixed-point unity gain). |

---

## 📋 AXI4-Lite Register Map

All registers are 32-bit word-aligned:

| Offset Address | Register Name | Access | Bit Field Description |
| :--- | :--- | :---: | :--- |
| **`0x00`** | `CTRL_REG` | R/W | • **Bit 0**: `ENABLE` (1 = Filter Active, 0 = Disabled).<br>• **Bit 1**: `SOFT_RESET` (Self-clearing pulse; flushes sample delay line to 0).<br>• **Bit 2**: `BYPASS` (1 = Pass input directly to output, 0 = Filtered output). |
| **`0x04`** | `STATUS_REG` | R/W1C | • **Bit 0**: `ACTIVE` (Read-only; 1 when samples are in flight).<br>• **Bit 1**: `OVERFLOW` (Sticky bit; set on saturation. Write 1 to clear). |
| **`0x08`** | `ACTIVE_TAPS` | R/W | Number of active taps ($1 \le N \le \text{MAX\_TAPS}$). Default: `MAX_TAPS`. |
| **`0x0C`** | `SCALE_REG` | R/W | Right-shift amount for fixed-point output scaling ($0 \le \text{shift} \le 31$). |
| **`0x40`** | `COEFF_0` | R/W | Impulse response tap 0 coefficient ($h[0]$). |
| **`0x44`** | `COEFF_1` | R/W | Impulse response tap 1 coefficient ($h[1]$). |
| **...** | ... | R/W | ... |
| **`0x40 + 4*(N-1)`** | `COEFF_N-1` | R/W | Impulse response tap $N-1$ coefficient ($h[N-1]$). |

---

## 📁 Repository Structure

```text
FIR_Filter/
├── rtl/
│   ├── fir_adder_stage.sv        # Individual pipelined stage in binary adder tree
│   ├── fir_core_pipelined.sv     # Pipelined multipliers, adder tree, rounder & saturator
│   ├── axi_stream_skid_buffer.sv # 2-entry ping-pong skid buffer for clean timing closure
│   ├── axi4_lite_regfile.sv      # AXI4-Lite Slave CSR with dynamic coefficient RAM
│   └── fir_filter_top.sv         # Top-level IP integrating Stream and Lite interfaces
├── tb/
│   ├── fir_golden_model.py       # Python script: designs Low-Pass filter & generates vectors
│   └── fir_filter_top_tb.sv      # Self-checking SystemVerilog testbench (7 comprehensive tests)
├── sim/
│   ├── Makefile                  # Automated compilation & simulation for QuestaSim
│   └── run_sim.sh                # Executable one-click bash simulation runner
└── README.md
```

---

## 🚀 Simulation & Verification

The testbench tests 7 rigorous operational scenarios:
1. **AXI4-Lite Register Sanity Check**: Tests default values and register access.
2. **Dynamic Coefficient Reload**: Writes 16 Q15 Low-Pass coefficients via AXI-Lite and verifies via readback.
3. **100% Throughput Streaming**: Feeds 128 composite samples (carrier + high-frequency noise) and bit-compares output against the Python Golden Model.
4. **Heavy Backpressure Test**: Stalls `m_axis_tready` randomly to verify pipeline freeze and skid buffer operation without loss of samples.
5. **Hardware Bypass Mode**: Verifies samples pass unaltered when bypass bit is asserted.
6. **Soft Reset Test**: Verifies the internal sample delay line clears to zero instantly.
7. **Overflow & Saturation Test**: Triggers saturation intentionally, verifying hard limiting to $+32767$ and sticky flag capture.

### Running Simulation (QuestaSim)

```bash
cd sim
./run_sim.sh
```

Or using `make`:
```bash
cd sim
make sim
```

