// ============================================================================
// Module: fir_filter_top.sv
// Description: Top-Level High-Performance Fully-Pipelined FIR Filter IP.
//              - Data Plane: AXI4-Stream Slave (Input) & Master (Output)
//              - Control Plane: AXI4-Lite Slave for Runtime Configuration
//              - Pipelined Multiplier & Binary Adder Tree with Output Skid Buffer
// ============================================================================

`timescale 1ns / 1ps

module fir_filter_top #(
    parameter int DATA_WIDTH     = 16,
    parameter int COEFF_WIDTH    = 16,
    parameter int MAX_TAPS       = 16,
    parameter int AXI_ADDR_WIDTH = 8,
    parameter int AXI_DATA_WIDTH = 32,
    parameter int DEF_SCALE      = 15
)(
    input  logic                                  clk,
    input  logic                                  rst_n,

    // ------------------------------------------------------------------------
    // AXI4-Stream Slave Interface (Input Samples)
    // ------------------------------------------------------------------------
    input  logic signed [DATA_WIDTH-1:0]          s_axis_tdata,
    input  logic                                  s_axis_tvalid,
    output logic                                  s_axis_tready,
    input  logic                                  s_axis_tlast,

    // ------------------------------------------------------------------------
    // AXI4-Stream Master Interface (Filtered Output Samples)
    // ------------------------------------------------------------------------
    output logic signed [DATA_WIDTH-1:0]          m_axis_tdata,
    output logic                                  m_axis_tvalid,
    input  logic                                  m_axis_tready,
    output logic                                  m_axis_tlast,

    // ------------------------------------------------------------------------
    // AXI4-Lite Slave Interface (Control & Dynamic Coefficients)
    // ------------------------------------------------------------------------
    input  logic [AXI_ADDR_WIDTH-1:0]             s_axi_awaddr,
    input  logic [2:0]                            s_axi_awprot,
    input  logic                                  s_axi_awvalid,
    output logic                                  s_axi_awready,

    input  logic [AXI_DATA_WIDTH-1:0]             s_axi_wdata,
    input  logic [(AXI_DATA_WIDTH/8)-1:0]         s_axi_wstrb,
    input  logic                                  s_axi_wvalid,
    output logic                                  s_axi_wready,

    output logic [1:0]                            s_axi_bresp,
    output logic                                  s_axi_bvalid,
    input  logic                                  s_axi_bready,

    input  logic [AXI_ADDR_WIDTH-1:0]             s_axi_araddr,
    input  logic [2:0]                            s_axi_arprot,
    input  logic                                  s_axi_arvalid,
    output logic                                  s_axi_arready,

    output logic [AXI_DATA_WIDTH-1:0]             s_axi_rdata,
    output logic [1:0]                            s_axi_rresp,
    output logic                                  s_axi_rvalid,
    input  logic                                  s_axi_rready,

    // Optional status flags to external logic / interrupts
    output logic                                  status_active_o,
    output logic                                  status_overflow_o
);

    // ------------------------------------------------------------------------
    // Internal Interconnect Wires
    // ------------------------------------------------------------------------
    logic                                  reg_filter_en;
    logic                                  reg_soft_reset;
    logic                                  reg_bypass;
    logic [$clog2(MAX_TAPS+1)-1:0]         reg_active_taps;
    logic [4:0]                            reg_scale_shift;
    logic signed [COEFF_WIDTH-1:0]         reg_coeffs [MAX_TAPS];

    logic                                  status_active;
    logic                                  status_overflow;

    assign status_active_o   = status_active;
    assign status_overflow_o = status_overflow;

    // Core to Skid Buffer Wires
    logic                                  core_valid;
    logic                                  core_ready;
    logic signed [DATA_WIDTH-1:0]          core_data;
    logic                                  core_last;

    // ------------------------------------------------------------------------
    // 1. AXI4-Lite Register File Instance
    // ------------------------------------------------------------------------
    axi4_lite_regfile #(
        .ADDR_WIDTH  (AXI_ADDR_WIDTH),
        .DATA_WIDTH  (AXI_DATA_WIDTH),
        .MAX_TAPS    (MAX_TAPS),
        .COEFF_WIDTH (COEFF_WIDTH),
        .DEF_SCALE   (DEF_SCALE)
    ) u_regfile (
        .aclk            (clk),
        .aresetn         (rst_n),

        .s_axi_awaddr    (s_axi_awaddr),
        .s_axi_awprot    (s_axi_awprot),
        .s_axi_awvalid   (s_axi_awvalid),
        .s_axi_awready   (s_axi_awready),

        .s_axi_wdata     (s_axi_wdata),
        .s_axi_wstrb     (s_axi_wstrb),
        .s_axi_wvalid    (s_axi_wvalid),
        .s_axi_wready    (s_axi_wready),

        .s_axi_bresp     (s_axi_bresp),
        .s_axi_bvalid    (s_axi_bvalid),
        .s_axi_bready    (s_axi_bready),

        .s_axi_araddr    (s_axi_araddr),
        .s_axi_arprot    (s_axi_arprot),
        .s_axi_arvalid   (s_axi_arvalid),
        .s_axi_arready   (s_axi_arready),

        .s_axi_rdata     (s_axi_rdata),
        .s_axi_rresp     (s_axi_rresp),
        .s_axi_rvalid    (s_axi_rvalid),
        .s_axi_rready    (s_axi_rready),

        .reg_filter_en   (reg_filter_en),
        .reg_soft_reset  (reg_soft_reset),
        .reg_bypass      (reg_bypass),
        .reg_active_taps (reg_active_taps),
        .reg_scale_shift (reg_scale_shift),
        .reg_coeffs      (reg_coeffs),

        .status_active   (status_active),
        .status_overflow (status_overflow)
    );

    // ------------------------------------------------------------------------
    // 2. High-Performance Pipelined FIR Core
    // ------------------------------------------------------------------------
    fir_core_pipelined #(
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH),
        .MAX_TAPS    (MAX_TAPS)
    ) u_fir_core (
        .clk             (clk),
        .rst_n           (rst_n),

        .reg_filter_en   (reg_filter_en),
        .reg_soft_reset  (reg_soft_reset),
        .reg_bypass      (reg_bypass),
        .reg_active_taps (reg_active_taps),
        .reg_scale_shift (reg_scale_shift),
        .reg_coeffs      (reg_coeffs),

        .status_active   (status_active),
        .status_overflow (status_overflow),

        .in_valid        (s_axis_tvalid),
        .in_ready        (s_axis_tready),
        .in_data         (s_axis_tdata),
        .in_last         (s_axis_tlast),

        .core_out_valid  (core_valid),
        .core_out_ready  (core_ready),
        .core_out_data   (core_data),
        .core_out_last   (core_last)
    );

    // ------------------------------------------------------------------------
    // 3. AXI4-Stream Output Skid Buffer (Clean register isolation)
    // ------------------------------------------------------------------------
    axi_stream_skid_buffer #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_output_skid_buffer (
        .clk     (clk),
        .rst_n   (rst_n),

        .s_valid (core_valid),
        .s_ready (core_ready),
        .s_data  (core_data),
        .s_last  (core_last),

        .m_valid (m_axis_tvalid),
        .m_ready (m_axis_tready),
        .m_data  (m_axis_tdata),
        .m_last  (m_axis_tlast)
    );

endmodule

