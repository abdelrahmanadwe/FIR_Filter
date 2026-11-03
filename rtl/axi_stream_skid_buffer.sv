// ============================================================================
// Module: axi_stream_skid_buffer.sv
// Description: Fully registered 2-entry skid buffer for AXI4-Stream.
//              Isolates input and output ready/valid paths, breaking combinational
//              feedback loops while sustaining full 100% throughput (1 trans/cycle).
// ============================================================================

`timescale 1ns / 1ps

module axi_stream_skid_buffer #(
    parameter int DATA_WIDTH = 16
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Slave side (Input)
    input  logic                   s_valid,
    output logic                   s_ready,
    input  logic [DATA_WIDTH-1:0]  s_data,
    input  logic                   s_last,

    // Master side (Output)
    output logic                   m_valid,
    input  logic                   m_ready,
    output logic [DATA_WIDTH-1:0]  m_data,
    output logic                   m_last
);

    // Two storage slots (skid buffer)
    logic [DATA_WIDTH-1:0] data_buf_q;
    logic                  last_buf_q;
    logic                  buf_valid_q;

    logic [DATA_WIDTH-1:0] data_out_q;
    logic                  last_out_q;
    logic                  out_valid_q;

    assign s_ready = !buf_valid_q;
    assign m_valid = out_valid_q;
    assign m_data  = data_out_q;
    assign m_last  = last_out_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_buf_q  <= '0;
            last_buf_q  <= 1'b0;
            buf_valid_q <= 1'b0;
            data_out_q  <= '0;
            last_out_q  <= 1'b0;
            out_valid_q <= 1'b0;
        end else begin
            // Output transaction consumed
            if (m_ready && m_valid) begin
                if (buf_valid_q) begin
                    // Drain buffer into output
                    data_out_q  <= data_buf_q;
                    last_out_q  <= last_buf_q;
                    out_valid_q <= 1'b1;
                    buf_valid_q <= 1'b0;
                end else begin
                    out_valid_q <= 1'b0;
                end
            end

            // Input transaction accepted
            if (s_valid && s_ready) begin
                if ((m_ready && m_valid) || !out_valid_q) begin
                    // Bypass directly to output
                    data_out_q  <= s_data;
                    last_out_q  <= s_last;
                    out_valid_q <= 1'b1;
                end else begin
                    // Buffer it
                    data_buf_q  <= s_data;
                    last_buf_q  <= s_last;
                    buf_valid_q <= 1'b1;
                end
            end
        end
    end

endmodule

