// ============================================================================
// Module: fir_core_pipelined.sv
// Description: Fully pipelined FIR Filter Datapath.
//              - Parameterized DATA_WIDTH, COEFF_WIDTH, MAX_TAPS.
//              - Runtime configurable active taps, coefficients, and scale.
//              - Pipelined Multipliers + Binary Adder Tree for Max Fmax.
//              - Rounding (convergent/nearest) and signed saturation logic.
//              - Full pipeline stall and backpressure handling.
// ============================================================================

`timescale 1ns / 1ps

module fir_core_pipelined #(
    parameter int DATA_WIDTH     = 16,
    parameter int COEFF_WIDTH    = 16,
    parameter int MAX_TAPS       = 16
)(
    input  logic                                  clk,
    input  logic                                  rst_n,

    // Runtime Configuration & Control
    input  logic                                  reg_filter_en,
    input  logic                                  reg_soft_reset,
    input  logic                                  reg_bypass,
    input  logic [$clog2(MAX_TAPS+1)-1:0]         reg_active_taps,
    input  logic [4:0]                            reg_scale_shift,
    input  wire signed [COEFF_WIDTH-1:0]         reg_coeffs [MAX_TAPS],

    output logic                                  status_active,
    output logic                                  status_overflow,

    // Streaming Input Interface
    input  logic                                  in_valid,
    output logic                                  in_ready,
    input  logic signed [DATA_WIDTH-1:0]          in_data,
    input  logic                                  in_last,

    // Streaming Output Interface (to Skid Buffer)
    output logic                                  core_out_valid,
    input  logic                                  core_out_ready,
    output logic signed [DATA_WIDTH-1:0]          core_out_data,
    output logic                                  core_out_last
);

    // ------------------------------------------------------------------------
    // Architecture Sizing & Parameters
    // ------------------------------------------------------------------------
    localparam int TREE_LEVELS   = (MAX_TAPS <= 1) ? 1 : $clog2(MAX_TAPS);
    localparam int PADDED_TAPS   = 1 << TREE_LEVELS;
    localparam int MULT_WIDTH    = DATA_WIDTH + COEFF_WIDTH;
    localparam int ACC_WIDTH     = MULT_WIDTH + TREE_LEVELS;
    localparam int TOTAL_LATENCY = 1 + TREE_LEVELS + 1; // Mult(1) + Tree(L) + Sat(1)

    // Pipeline enable controlled by downstream backpressure
    logic pipe_en;
    assign pipe_en  = core_out_ready;
    assign in_ready = pipe_en && reg_filter_en;

    // ------------------------------------------------------------------------
    // Stage 0: Sample Delay Line (Shift Register)
    // ------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] sample_shift_reg [MAX_TAPS];

    // ------------------------------------------------------------------------
    // Stage 1: Pipelined Multipliers
    // ------------------------------------------------------------------------
    logic signed [MULT_WIDTH-1:0] mult_q [PADDED_TAPS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < MAX_TAPS; k++) begin
                sample_shift_reg[k] <= '0;
            end
            for (int k = 0; k < PADDED_TAPS; k++) begin
                mult_q[k] <= '0;
            end
        end else if (reg_soft_reset) begin
            for (int k = 0; k < MAX_TAPS; k++) begin
                sample_shift_reg[k] <= '0;
            end
            for (int k = 0; k < PADDED_TAPS; k++) begin
                mult_q[k] <= '0;
            end
        end else if (pipe_en) begin
            if (in_valid && in_ready) begin
                // Update sample delay line
                sample_shift_reg[0] <= in_data;
                for (int k = 1; k < MAX_TAPS; k++) begin
                    sample_shift_reg[k] <= sample_shift_reg[k-1];
                end

                // Multiply new incoming sample and previous delayed samples
                for (int k = 0; k < PADDED_TAPS; k++) begin
                    if (k < MAX_TAPS && k < reg_active_taps) begin
                        if (k == 0) begin
                            mult_q[0] <= in_data * reg_coeffs[0];
                        end else begin
                            mult_q[k] <= sample_shift_reg[k-1] * reg_coeffs[k];
                        end
                    end else begin
                        mult_q[k] <= '0;
                    end
                end
            end else begin
                // If no incoming valid data, clear multiplier registers for this cycle
                for (int k = 0; k < PADDED_TAPS; k++) begin
                    mult_q[k] <= '0;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Stage 2 to L+1: Pipelined Binary Adder Tree
    // ------------------------------------------------------------------------
    generate
        for (genvar s = 0; s < TREE_LEVELS; s++) begin : gen_adder_tree
            localparam int STAGE_IN_WIDTH  = MULT_WIDTH + s;
            localparam int STAGE_NUM_PAIRS = PADDED_TAPS >> (s + 1);

            logic signed [STAGE_IN_WIDTH-1:0] stage_din  [2 * STAGE_NUM_PAIRS];
            logic signed [STAGE_IN_WIDTH:0]   stage_dout [STAGE_NUM_PAIRS];

            if (s == 0) begin : gen_input_conn
                for (genvar p = 0; p < 2 * STAGE_NUM_PAIRS; p++) begin
                    assign stage_din[p] = mult_q[p];
                end
            end else begin : gen_mid_conn
                for (genvar p = 0; p < 2 * STAGE_NUM_PAIRS; p++) begin
                    assign stage_din[p] = gen_adder_tree[s-1].stage_dout[p];
                end
            end

            fir_adder_stage #(
                .IN_WIDTH(STAGE_IN_WIDTH),
                .NUM_PAIRS(STAGE_NUM_PAIRS)
            ) u_stage (
                .clk(clk),
                .rst_n(rst_n),
                .pipe_en(pipe_en),
                .soft_reset(reg_soft_reset),
                .din(stage_din),
                .dout(stage_dout)
            );
        end
    endgenerate

    // Final sum from root of adder tree
    logic signed [ACC_WIDTH-1:0] final_sum;
    assign final_sum = gen_adder_tree[TREE_LEVELS-1].stage_dout[0];

    // ------------------------------------------------------------------------
    // Control Signal Delay Pipelines (Matching Latency)
    // ------------------------------------------------------------------------
    logic [TOTAL_LATENCY-1:0]             valid_pipe;
    logic [TOTAL_LATENCY-1:0]             last_pipe;
    logic [TOTAL_LATENCY-1:0]             bypass_pipe;
    logic signed [DATA_WIDTH-1:0]         raw_data_pipe [TOTAL_LATENCY];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe  <= '0;
            last_pipe   <= '0;
            bypass_pipe <= '0;
            for (int i = 0; i < TOTAL_LATENCY; i++) begin
                raw_data_pipe[i] <= '0;
            end
        end else if (reg_soft_reset) begin
            valid_pipe  <= '0;
            last_pipe   <= '0;
            bypass_pipe <= '0;
            for (int i = 0; i < TOTAL_LATENCY; i++) begin
                raw_data_pipe[i] <= '0;
            end
        end else if (pipe_en) begin
            valid_pipe  <= {valid_pipe[TOTAL_LATENCY-2:0], (in_valid && in_ready)};
            last_pipe   <= {last_pipe[TOTAL_LATENCY-2:0], in_last};
            bypass_pipe <= {bypass_pipe[TOTAL_LATENCY-2:0], reg_bypass};

            raw_data_pipe[0] <= in_data;
            for (int i = 1; i < TOTAL_LATENCY; i++) begin
                raw_data_pipe[i] <= raw_data_pipe[i-1];
            end
        end
    end

    // ------------------------------------------------------------------------
    // Final Stage: Rounding, Scaling & Saturation (Registered)
    // ------------------------------------------------------------------------
    localparam signed [DATA_WIDTH-1:0] MAX_POS = {1'b0, {(DATA_WIDTH-1){1'b1}}};   // e.g. +32767
    localparam signed [DATA_WIDTH-1:0] MIN_NEG = {1'b1, {(DATA_WIDTH-1){1'b0}}};   // e.g. -32768

    logic signed [DATA_WIDTH-1:0] sat_out_q;
    logic                         overflow_q;

    // Combinational rounding calculation
    logic signed [ACC_WIDTH:0] round_addend;
    logic signed [ACC_WIDTH:0] rounded_sum;
    logic signed [ACC_WIDTH:0] scaled_sum;

    always_comb begin
        if (reg_scale_shift > 0) begin
            round_addend = (1'b1 << (reg_scale_shift - 1));
        end else begin
            round_addend = '0;
        end
        rounded_sum = final_sum + round_addend;
        scaled_sum  = rounded_sum >>> reg_scale_shift;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sat_out_q   <= '0;
            overflow_q  <= 1'b0;
        end else if (reg_soft_reset) begin
            sat_out_q   <= '0;
            overflow_q  <= 1'b0;
        end else if (pipe_en) begin
            if (valid_pipe[TOTAL_LATENCY-2]) begin
                if (bypass_pipe[TOTAL_LATENCY-2]) begin
                    sat_out_q  <= raw_data_pipe[TOTAL_LATENCY-2];
                    overflow_q <= 1'b0;
                end else begin
                    // Saturation Check against DATA_WIDTH limits
                    if (scaled_sum > $signed({{(ACC_WIDTH+1-DATA_WIDTH){1'b0}}, MAX_POS})) begin
                        sat_out_q  <= MAX_POS;
                        overflow_q <= 1'b1;
                    end else if (scaled_sum < $signed({{(ACC_WIDTH+1-DATA_WIDTH){1'b1}}, MIN_NEG})) begin
                        sat_out_q  <= MIN_NEG;
                        overflow_q <= 1'b1;
                    end else begin
                        sat_out_q  <= scaled_sum[DATA_WIDTH-1:0];
                        overflow_q <= 1'b0;
                    end
                end
            end else begin
                sat_out_q  <= '0;
                overflow_q <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------------
    // Outputs to Skid Buffer & Status
    // ------------------------------------------------------------------------
    assign core_out_valid  = valid_pipe[TOTAL_LATENCY-1];
    assign core_out_last   = last_pipe[TOTAL_LATENCY-1];
    assign core_out_data   = sat_out_q;
    assign status_active   = (|valid_pipe);
    assign status_overflow = overflow_q;

endmodule
