// ============================================================================
// Module: fir_adder_stage.sv
// Description: Single pipelined stage in the binary adder tree.
//              Takes 2*NUM_PAIRS inputs of width IN_WIDTH and produces
//              NUM_PAIRS outputs of width IN_WIDTH + 1 on each clock enable.
// ============================================================================

`timescale 1ns / 1ps

module fir_adder_stage #(
    parameter int IN_WIDTH  = 32,
    parameter int NUM_PAIRS = 8
)(
    input  logic                                          clk,
    input  logic                                          rst_n,
    input  logic                                          pipe_en,
    input  logic                                          soft_reset,

    input  wire signed [IN_WIDTH-1:0]                    din  [2*NUM_PAIRS],
    output logic signed [IN_WIDTH:0]                      dout [NUM_PAIRS]
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_PAIRS; i++) begin
                dout[i] <= '0;
            end
        end else if (soft_reset) begin
            for (int i = 0; i < NUM_PAIRS; i++) begin
                dout[i] <= '0;
            end
        end else if (pipe_en) begin
            for (int i = 0; i < NUM_PAIRS; i++) begin
                dout[i] <= $signed(din[2*i]) + $signed(din[2*i + 1]);
            end
        end
    end

endmodule
