// ============================================================================
// Module: axi4_lite_regfile.sv
// Description: AXI4-Lite Register File for FIR Filter Configuration and Status.
//              Provides runtime control, status reporting, scaling config,
//              and dynamic coefficient reload for up to MAX_TAPS.
// ============================================================================

`timescale 1ns / 1ps

module axi4_lite_regfile #(
    parameter int ADDR_WIDTH     = 8,
    parameter int DATA_WIDTH     = 32,
    parameter int MAX_TAPS       = 16,
    parameter int COEFF_WIDTH    = 16,
    parameter int DEF_SCALE      = 15
)(
    input  logic                                  aclk,
    input  logic                                  aresetn,

    // ------------------------------------------------------------------------
    // AXI4-Lite Slave Interface
    // ------------------------------------------------------------------------
    // Write Address Channel
    input  logic [ADDR_WIDTH-1:0]                 s_axi_awaddr,
    input  logic [2:0]                            s_axi_awprot,
    input  logic                                  s_axi_awvalid,
    output logic                                  s_axi_awready,

    // Write Data Channel
    input  logic [DATA_WIDTH-1:0]                 s_axi_wdata,
    input  logic [(DATA_WIDTH/8)-1:0]             s_axi_wstrb,
    input  logic                                  s_axi_wvalid,
    output logic                                  s_axi_wready,

    // Write Response Channel
    output logic [1:0]                            s_axi_bresp,
    output logic                                  s_axi_bvalid,
    input  logic                                  s_axi_bready,

    // Read Address Channel
    input  logic [ADDR_WIDTH-1:0]                 s_axi_araddr,
    input  logic [2:0]                            s_axi_arprot,
    input  logic                                  s_axi_arvalid,
    output logic                                  s_axi_arready,

    // Read Data Channel
    output logic [DATA_WIDTH-1:0]                 s_axi_rdata,
    output logic [1:0]                            s_axi_rresp,
    output logic                                  s_axi_rvalid,
    input  logic                                  s_axi_rready,

    // ------------------------------------------------------------------------
    // Core FIR Control & Status Signals
    // ------------------------------------------------------------------------
    output logic                                  reg_filter_en,
    output logic                                  reg_soft_reset,
    output logic                                  reg_bypass,
    output logic [$clog2(MAX_TAPS+1)-1:0]         reg_active_taps,
    output logic [4:0]                            reg_scale_shift,
    output logic signed [COEFF_WIDTH-1:0]         reg_coeffs [MAX_TAPS],

    input  logic                                  status_active,
    input  logic                                  status_overflow
);

    // ------------------------------------------------------------------------
    // Register Address Offsets
    // ------------------------------------------------------------------------
    localparam logic [ADDR_WIDTH-1:0] ADDR_CTRL        = 'h00; // Bit 0: EN, Bit 1: SOFT_RST, Bit 2: BYPASS
    localparam logic [ADDR_WIDTH-1:0] ADDR_STATUS      = 'h04; // Bit 0: ACTIVE, Bit 1: OVERFLOW
    localparam logic [ADDR_WIDTH-1:0] ADDR_ACTIVE_TAPS = 'h08; // Dynamic number of active taps
    localparam logic [ADDR_WIDTH-1:0] ADDR_SCALE       = 'h0C; // Right shift amount for rounding/scaling
    localparam logic [ADDR_WIDTH-1:0] ADDR_COEFF_BASE  = 'h40; // Coeff 0 .. MAX_TAPS-1 (word-addressed)

    // Internal Registers
    logic [2:0]                           ctrl_q;
    logic [$clog2(MAX_TAPS+1)-1:0]        active_taps_q;
    logic [4:0]                           scale_shift_q;
    logic signed [COEFF_WIDTH-1:0]        coeffs_q [MAX_TAPS];
    logic                                 overflow_sticky_q;

    // AXI handshake signals
    logic [ADDR_WIDTH-1:0] axi_awaddr;
    logic                  axi_awready;
    logic                  axi_wready;
    logic [1:0]            axi_bresp;
    logic                  axi_bvalid;

    logic [ADDR_WIDTH-1:0] axi_araddr;
    logic                  axi_arready;
    logic [DATA_WIDTH-1:0] axi_rdata;
    logic [1:0]            axi_rresp;
    logic                  axi_rvalid;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = axi_bresp;
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = axi_rresp;
    assign s_axi_rvalid  = axi_rvalid;

    // Outputs to Core
    assign reg_filter_en   = ctrl_q[0];
    assign reg_soft_reset  = ctrl_q[1];
    assign reg_bypass      = ctrl_q[2];
    assign reg_active_taps = active_taps_q;
    assign reg_scale_shift = scale_shift_q;
    assign reg_coeffs      = coeffs_q;

    // ------------------------------------------------------------------------
    // AXI4-Lite Write Channels
    // ------------------------------------------------------------------------
    logic aw_en;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_awready <= 1'b0;
            axi_awaddr  <= '0;
            aw_en       <= 1'b1;
        end else begin
            if (~axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                axi_awready <= 1'b1;
                axi_awaddr  <= s_axi_awaddr;
                aw_en       <= 1'b0;
            end else if (s_axi_bready && axi_bvalid) begin
                aw_en       <= 1'b1;
                axi_awready <= 1'b0;
            end else begin
                axi_awready <= 1'b0;
            end
        end
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_wready <= 1'b0;
        end else begin
            if (~axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en) begin
                axi_wready <= 1'b1;
            end else begin
                axi_wready <= 1'b0;
            end
        end
    end

    // Write Execution
    logic slv_reg_wren;
    assign slv_reg_wren = axi_wready && s_axi_wvalid && axi_awready && s_axi_awvalid;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ctrl_q            <= 3'b001; // Enable = 1 by default
            active_taps_q     <= MAX_TAPS;
            scale_shift_q     <= DEF_SCALE[4:0];
            overflow_sticky_q <= 1'b0;
            for (int i = 0; i < MAX_TAPS; i++) begin
                coeffs_q[i] <= '0;
            end
        end else begin
            // Latch sticky overflow from core
            if (status_overflow) begin
                overflow_sticky_q <= 1'b1;
            end

            // Auto-clear soft reset pulse after one cycle
            if (ctrl_q[1]) begin
                ctrl_q[1] <= 1'b0;
            end

            if (slv_reg_wren) begin
                if (axi_awaddr == ADDR_CTRL) begin
                    ctrl_q <= s_axi_wdata[2:0];
                end else if (axi_awaddr == ADDR_STATUS) begin
                    // Write 1 to clear overflow sticky bit
                    if (s_axi_wdata[1]) begin
                        overflow_sticky_q <= 1'b0;
                    end
                end else if (axi_awaddr == ADDR_ACTIVE_TAPS) begin
                    if (s_axi_wdata <= MAX_TAPS && s_axi_wdata > 0)
                        active_taps_q <= s_axi_wdata[$clog2(MAX_TAPS+1)-1:0];
                end else if (axi_awaddr == ADDR_SCALE) begin
                    scale_shift_q <= s_axi_wdata[4:0];
                end else if (axi_awaddr >= ADDR_COEFF_BASE) begin
                    int tap_idx;
                    tap_idx = (axi_awaddr - ADDR_COEFF_BASE) >> 2;
                    if (tap_idx >= 0 && tap_idx < MAX_TAPS) begin
                        coeffs_q[tap_idx] <= $signed(s_axi_wdata[COEFF_WIDTH-1:0]);
                    end
                end
            end
        end
    end

    // Write Response
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00; // OKAY
        end else begin
            if (axi_awready && s_axi_awvalid && ~axi_bvalid && axi_wready && s_axi_wvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
            end else if (s_axi_bready && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // AXI4-Lite Read Channels
    // ------------------------------------------------------------------------
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_arready <= 1'b0;
            axi_araddr  <= '0;
        end else begin
            if (~axi_arready && s_axi_arvalid) begin
                axi_arready <= 1'b1;
                axi_araddr  <= s_axi_araddr;
            end else begin
                axi_arready <= 1'b0;
            end
        end
    end

    // Read Data Mux
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b00;
            axi_rdata  <= '0;
        end else begin
            if (axi_arready && s_axi_arvalid && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;

                case (axi_araddr)
                    ADDR_CTRL: begin
                        axi_rdata <= {{(DATA_WIDTH-3){1'b0}}, ctrl_q};
                    end
                    ADDR_STATUS: begin
                        axi_rdata <= {{(DATA_WIDTH-2){1'b0}}, overflow_sticky_q, status_active};
                    end
                    ADDR_ACTIVE_TAPS: begin
                        axi_rdata <= {{(DATA_WIDTH-$clog2(MAX_TAPS+1)){1'b0}}, active_taps_q};
                    end
                    ADDR_SCALE: begin
                        axi_rdata <= {{(DATA_WIDTH-5){1'b0}}, scale_shift_q};
                    end
                    default: begin
                        if (axi_araddr >= ADDR_COEFF_BASE) begin
                            int tap_idx;
                            tap_idx = (axi_araddr - ADDR_COEFF_BASE) >> 2;
                            if (tap_idx >= 0 && tap_idx < MAX_TAPS) begin
                                axi_rdata <= {{(DATA_WIDTH-COEFF_WIDTH){coeffs_q[tap_idx][COEFF_WIDTH-1]}}, coeffs_q[tap_idx]};
                            end else begin
                                axi_rdata <= '0;
                            end
                        end else begin
                            axi_rdata <= '0;
                        end
                    end
                endcase
            end else if (axi_rvalid && s_axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

endmodule

