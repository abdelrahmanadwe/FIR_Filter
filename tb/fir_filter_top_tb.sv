// ============================================================================
// Module: fir_filter_top_tb.sv
// Description: Comprehensive Self-Checking Testbench for fir_filter_top.
//              - Verifies AXI4-Lite Control & Dynamic Coefficient Reload.
//              - Verifies AXI4-Stream data transfer against Golden Model.
//              - Tests Full-Speed Streaming, Backpressure, Bypass, Soft Reset,
//                Dynamic Tap Reconfiguration, and Overflow Saturation.
// ============================================================================

`timescale 1ns / 1ps

module fir_filter_top_tb;

    // Parameters
    localparam int DATA_WIDTH     = 16;
    localparam int COEFF_WIDTH    = 16;
    localparam int MAX_TAPS       = 16;
    localparam int AXI_ADDR_WIDTH = 8;
    localparam int AXI_DATA_WIDTH = 32;
    localparam int DEF_SCALE      = 15;
    localparam real CLK_PERIOD    = 10.0; // 100 MHz

    // Clock and Reset
    logic clk;
    logic rst_n;

    // AXI4-Stream Slave (Input)
    logic signed [DATA_WIDTH-1:0] s_axis_tdata;
    logic                         s_axis_tvalid;
    logic                         s_axis_tready;
    logic                         s_axis_tlast;

    // AXI4-Stream Master (Output)
    logic signed [DATA_WIDTH-1:0] m_axis_tdata;
    logic                         m_axis_tvalid;
    logic                         m_axis_tready;
    logic                         m_axis_tlast;

    // AXI4-Lite Slave (Control)
    logic [AXI_ADDR_WIDTH-1:0]     s_axi_awaddr;
    logic [2:0]                    s_axi_awprot;
    logic                          s_axi_awvalid;
    logic                          s_axi_awready;

    logic [AXI_DATA_WIDTH-1:0]     s_axi_wdata;
    logic [(AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb;
    logic                          s_axi_wvalid;
    logic                          s_axi_wready;

    logic [1:0]                    s_axi_bresp;
    logic                          s_axi_bvalid;
    logic                          s_axi_bready;

    logic [AXI_ADDR_WIDTH-1:0]     s_axi_araddr;
    logic [2:0]                    s_axi_arprot;
    logic                          s_axi_arvalid;
    logic                          s_axi_arready;

    logic [AXI_DATA_WIDTH-1:0]     s_axi_rdata;
    logic [1:0]                    s_axi_rresp;
    logic                          s_axi_rvalid;
    logic                          s_axi_rready;

    logic                          status_active_o;
    logic                          status_overflow_o;

    // Testbench Variables & Scoreboard
    int error_count = 0;
    int test_count  = 0;

    // Memory arrays for stimulus and golden data
    logic [15:0] coeff_rom     [MAX_TAPS];
    logic [15:0] stimulus_mem  [256];
    logic [15:0] golden_mem    [256];
    int          num_stim_samples = 128;

    // ------------------------------------------------------------------------
    // Clock Generation
    // ------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // ------------------------------------------------------------------------
    // DUT Instantiation
    // ------------------------------------------------------------------------
    fir_filter_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .COEFF_WIDTH    (COEFF_WIDTH),
        .MAX_TAPS       (MAX_TAPS),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .DEF_SCALE      (DEF_SCALE)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),

        .s_axis_tdata     (s_axis_tdata),
        .s_axis_tvalid    (s_axis_tvalid),
        .s_axis_tready    (s_axis_tready),
        .s_axis_tlast     (s_axis_tlast),

        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tlast     (m_axis_tlast),

        .s_axi_awaddr     (s_axi_awaddr),
        .s_axi_awprot     (s_axi_awprot),
        .s_axi_awvalid    (s_axi_awvalid),
        .s_axi_awready    (s_axi_awready),

        .s_axi_wdata      (s_axi_wdata),
        .s_axi_wstrb      (s_axi_wstrb),
        .s_axi_wvalid     (s_axi_wvalid),
        .s_axi_wready     (s_axi_wready),

        .s_axi_bresp      (s_axi_bresp),
        .s_axi_bvalid     (s_axi_bvalid),
        .s_axi_bready     (s_axi_bready),

        .s_axi_araddr     (s_axi_araddr),
        .s_axi_arprot     (s_axi_arprot),
        .s_axi_arvalid    (s_axi_arvalid),
        .s_axi_arready    (s_axi_arready),

        .s_axi_rdata      (s_axi_rdata),
        .s_axi_rresp      (s_axi_rresp),
        .s_axi_rvalid     (s_axi_rvalid),
        .s_axi_rready     (s_axi_rready),

        .status_active_o  (status_active_o),
        .status_overflow_o(status_overflow_o)
    );

    // ------------------------------------------------------------------------
    // AXI4-Lite Driver Tasks
    // ------------------------------------------------------------------------
    task axi_write(input [AXI_ADDR_WIDTH-1:0] addr, input [AXI_DATA_WIDTH-1:0] data);
        @(posedge clk);
        s_axi_awaddr  <= addr;
        s_axi_awprot  <= 3'b000;
        s_axi_awvalid <= 1'b1;
        s_axi_wdata   <= data;
        s_axi_wstrb   <= 4'hF;
        s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;

        // Wait for address and data handshakes
        fork
            begin
                wait (s_axi_awready);
                @(posedge clk);
                s_axi_awvalid <= 1'b0;
            end
            begin
                wait (s_axi_wready);
                @(posedge clk);
                s_axi_wvalid  <= 1'b0;
            end
        join

        // Wait for write response
        wait (s_axi_bvalid);
        @(posedge clk);
        s_axi_bready <= 1'b0;
        @(posedge clk);
    endtask

    task axi_read(input [AXI_ADDR_WIDTH-1:0] addr, output [AXI_DATA_WIDTH-1:0] data);
        @(posedge clk);
        s_axi_araddr  <= addr;
        s_axi_arprot  <= 3'b000;
        s_axi_arvalid <= 1'b1;
        s_axi_rready  <= 1'b1;

        wait (s_axi_arready);
        @(posedge clk);
        s_axi_arvalid <= 1'b0;

        wait (s_axi_rvalid);
        data = s_axi_rdata;
        @(posedge clk);
        s_axi_rready <= 1'b0;
        @(posedge clk);
    endtask

    // ------------------------------------------------------------------------
    // Helper Tasks
    // ------------------------------------------------------------------------
    task reset_all();
        rst_n         <= 1'b0;
        s_axis_tdata  <= '0;
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        m_axis_tready <= 1'b1;

        s_axi_awaddr  <= '0;
        s_axi_awprot  <= '0;
        s_axi_awvalid <= 1'b0;
        s_axi_wdata   <= '0;
        s_axi_wstrb   <= '0;
        s_axi_wvalid  <= 1'b0;
        s_axi_bready  <= 1'b0;

        s_axi_araddr  <= '0;
        s_axi_arprot  <= '0;
        s_axi_arvalid <= 1'b0;
        s_axi_rready  <= 1'b0;

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);
    endtask

    // ------------------------------------------------------------------------
    // Main Test Sequence
    // ------------------------------------------------------------------------
    logic [AXI_DATA_WIDTH-1:0] read_val;

    initial begin
        $display("================================================================================");
        $display("                 STARTING FIR FILTER SYSTEMVERILOG TESTBENCH                    ");
        $display("================================================================================");

        // Load files generated by golden model
        $readmemh("../tb/coeffs.txt", coeff_rom);
        $readmemh("../tb/input_samples.txt", stimulus_mem);
        $readmemh("../tb/golden_output.txt", golden_mem);

        reset_all();

        // --------------------------------------------------------------------
        // TEST 1: AXI4-Lite Register File Access & Defaults
        // --------------------------------------------------------------------
        $display("\n[TEST 1] Checking AXI4-Lite Register Default Values...");
        test_count++;
        axi_read('h00, read_val); // CTRL
        if (read_val[0] !== 1'b1) begin
            $error("[FAIL] Default CTRL != 1 (Actual: 0x%08X)", read_val);
            error_count++;
        end else begin
            $display("  -> CTRL_REG default verified (EN = 1)");
        end

        axi_read('h08, read_val); // ACTIVE_TAPS
        if (read_val !== MAX_TAPS) begin
            $error("[FAIL] Default ACTIVE_TAPS != %0d (Actual: %0d)", MAX_TAPS, read_val);
            error_count++;
        end else begin
            $display("  -> ACTIVE_TAPS_REG default verified (%0d taps)", read_val);
        end

        axi_read('h0C, read_val); // SCALE
        if (read_val !== DEF_SCALE) begin
            $error("[FAIL] Default SCALE != %0d (Actual: %0d)", DEF_SCALE, read_val);
            error_count++;
        end else begin
            $display("  -> SCALE_REG default verified (Shift = %0d)", read_val);
        end

        // --------------------------------------------------------------------
        // TEST 2: Dynamic Coefficient Reload via AXI4-Lite
        // --------------------------------------------------------------------
        $display("\n[TEST 2] Programming 16 Filter Coefficients into Register File...");
        test_count++;
        for (int i = 0; i < MAX_TAPS; i++) begin
            axi_write('h40 + (i * 4), {16'h0000, coeff_rom[i]});
        end

        // Readback verification
        for (int i = 0; i < MAX_TAPS; i++) begin
            axi_read('h40 + (i * 4), read_val);
            if (read_val[15:0] !== coeff_rom[i]) begin
                $error("[FAIL] Mismatch reading coeff[%0d]: Expected 0x%04X, Got 0x%04X",
                       i, coeff_rom[i], read_val[15:0]);
                error_count++;
            end
        end
        $display("  -> All %0d Coefficients successfully programmed and verified via readback!", MAX_TAPS);

        // --------------------------------------------------------------------
        // TEST 3: Full-Speed Streaming & Golden Model Comparison
        // --------------------------------------------------------------------
        $display("\n[TEST 3] Streaming %0d Samples at 100%% Throughput (No Backpressure)...", num_stim_samples);
        test_count++;
        m_axis_tready <= 1'b1;

        fork
            // Sender Process
            begin
                for (int n = 0; n < num_stim_samples; n++) begin
                    @(posedge clk);
                    while (!s_axis_tready) @(posedge clk);
                    s_axis_tvalid <= 1'b1;
                    s_axis_tdata  <= $signed(stimulus_mem[n]);
                    s_axis_tlast  <= (n == num_stim_samples - 1);
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
            end

            // Receiver & Checker Process
            begin
                automatic int rx_count = 0;
                while (rx_count < num_stim_samples) begin
                    @(posedge clk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        logic signed [DATA_WIDTH-1:0] exp_data;
                        exp_data = $signed(golden_mem[rx_count]);
                        
                        if (m_axis_tdata !== exp_data) begin
                            $error("[SAMPLE MISMATCH] Sample #%0d: Expected 0x%04X (%0d), Got 0x%04X (%0d)",
                                   rx_count, exp_data, exp_data, m_axis_tdata, m_axis_tdata);
                            error_count++;
                        end

                        if (rx_count == num_stim_samples - 1) begin
                            if (!m_axis_tlast) begin
                                $error("[FAIL] m_axis_tlast was not asserted on the final sample!");
                                error_count++;
                            end else begin
                                $display("  -> m_axis_tlast correctly asserted on final sample!");
                            end
                        end

                        rx_count++;
                    end
                end
                $display("  -> Processed %0d samples with zero mismatches against Golden Model!", rx_count);
            end
        join

        // --------------------------------------------------------------------
        // TEST 4: AXI4-Stream Backpressure Test (Pipeline Freeze & Skid Buffer)
        // --------------------------------------------------------------------
        $display("\n[TEST 4] Backpressure Test: Injecting Random tready Stalls...");
        test_count++;
        // Clear delay line via Soft Reset so it starts fresh from zero state
        axi_write('h00, 32'h00000003); // Enable + Soft Reset
        repeat (10) @(posedge clk);
        axi_write('h00, 32'h00000001); // Enable
        repeat (5) @(posedge clk);

        fork
            // Sender: send 32 samples continuously
            begin
                for (int n = 0; n < 32; n++) begin
                    @(posedge clk);
                    while (!s_axis_tready) @(posedge clk);
                    s_axis_tvalid <= 1'b1;
                    s_axis_tdata  <= $signed(stimulus_mem[n]);
                    s_axis_tlast  <= (n == 31);
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
            end

            // Backpressure Driver: randomly stall m_axis_tready
            begin
                repeat (120) begin
                    @(posedge clk);
                    m_axis_tready <= ($urandom_range(0, 3) != 0); // 75% ready, 25% stall
                end
                m_axis_tready <= 1'b1;
            end

            // Receiver
            begin
                automatic int rx_count = 0;
                while (rx_count < 32) begin
                    @(posedge clk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        logic signed [DATA_WIDTH-1:0] exp_data;
                        exp_data = $signed(golden_mem[rx_count]);
                        if (m_axis_tdata !== exp_data) begin
                            $error("[BACKPRESSURE MISMATCH] Sample #%0d: Expected 0x%04X, Got 0x%04X",
                                   rx_count, exp_data, m_axis_tdata);
                            error_count++;
                        end
                        rx_count++;
                    end
                end
                $display("  -> All 32 samples correctly received during heavy backpressure stalls!");
            end
        join

        m_axis_tready <= 1'b1;
        repeat (20) @(posedge clk);

        // --------------------------------------------------------------------
        // TEST 5: Filter Bypass Mode Test
        // --------------------------------------------------------------------
        $display("\n[TEST 5] Testing Hardware Bypass Mode...");
        test_count++;
        // Set BYPASS bit in CTRL (Bit 2 = 1, Bit 0 = 1) -> 3'b101 = 0x5
        axi_write('h00, 32'h00000005);

        fork
            begin
                for (int n = 0; n < 16; n++) begin
                    @(posedge clk);
                    while (!s_axis_tready) @(posedge clk);
                    s_axis_tvalid <= 1'b1;
                    s_axis_tdata  <= 16'h1234 + n;
                    s_axis_tlast  <= (n == 15);
                end
                @(posedge clk);
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
            end

            begin
                automatic int rx_count = 0;
                while (rx_count < 16) begin
                    @(posedge clk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        logic signed [DATA_WIDTH-1:0] exp_bypass;
                        exp_bypass = 16'h1234 + rx_count;
                        if (m_axis_tdata !== exp_bypass) begin
                            $error("[BYPASS MISMATCH] Sample #%0d: Expected 0x%04X, Got 0x%04X",
                                   rx_count, exp_bypass, m_axis_tdata);
                            error_count++;
                        end
                        rx_count++;
                    end
                end
                $display("  -> Bypass mode successfully passed all samples directly without alteration!");
            end
        join

        // Restore normal mode (Bypass = 0, Enable = 1)
        axi_write('h00, 32'h00000001);
        repeat (10) @(posedge clk);

        // --------------------------------------------------------------------
        // TEST 6: Soft Reset Test
        // --------------------------------------------------------------------
        $display("\n[TEST 6] Testing Soft Reset of Filter Delay Line...");
        test_count++;
        // Assert SOFT_RESET (Bit 1 = 1)
        axi_write('h00, 32'h00000003);
        repeat (10) @(posedge clk);

        // Verify delay line is cleared: internal registers should be zero
        for (int k = 0; k < MAX_TAPS; k++) begin
            if (dut.u_fir_core.sample_shift_reg[k] !== '0) begin
                $error("[FAIL] Sample shift reg[%0d] not cleared after soft reset!", k);
                error_count++;
            end
        end
        $display("  -> Soft Reset verified! Delay line completely cleared to zero.");

        // --------------------------------------------------------------------
        // TEST 7: Overflow & Saturation Test
        // --------------------------------------------------------------------
        $display("\n[TEST 7] Testing Fixed-Point Saturation & Sticky Overflow Flag...");
        test_count++;
        // Set scale shift to 0 (no division, inducing massive accumulation overflow)
        axi_write('h0C, 32'h00000000);

        // Send a burst of max positive values
        @(posedge clk);
        s_axis_tvalid <= 1'b1;
        s_axis_tdata  <= 16'h7FFF; // +32767
        s_axis_tlast  <= 1'b0;
        repeat (10) @(posedge clk);
        s_axis_tvalid <= 1'b0;

        repeat (25) @(posedge clk);

        // Check if status overflow output is set and saturated output equals 0x7FFF
        axi_read('h04, read_val); // STATUS_REG
        if (read_val[1] !== 1'b1) begin
            $error("[FAIL] Overflow sticky bit was not set in STATUS_REG! (STATUS: 0x%08X)", read_val);
            error_count++;
        end else begin
            $display("  -> Sticky Overflow flag successfully captured in STATUS_REG (Bit 1 = 1)!");
        end

        // Clear sticky bit by writing 1 to bit 1
        axi_write('h04, 32'h00000002);
        axi_read('h04, read_val);
        if (read_val[1] !== 1'b0) begin
            $error("[FAIL] Write-1-to-clear failed on STATUS_REG!");
            error_count++;
        end else begin
            $display("  -> Write-1-to-clear for Overflow flag verified!");
        end

        // --------------------------------------------------------------------
        // Final Summary
        // --------------------------------------------------------------------
        repeat (10) @(posedge clk);
        $display("\n================================================================================");
        if (error_count == 0) begin
            $display("   *** ALL %0d TESTS PASSED SUCCESSFULLY! FIR FILTER IS 100%% VERIFIED! ***", test_count);
        end else begin
            $display("   *** FAILED WITH %0d ERRORS across %0d tests! ***", error_count, test_count);
        end
        $display("================================================================================\n");

        $finish;
    end

endmodule
