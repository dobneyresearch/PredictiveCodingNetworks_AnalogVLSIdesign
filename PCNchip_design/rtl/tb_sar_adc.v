// tb_sar_adc.v — smoke test for the 8-bit SAR ADC
//
// Compile and run:
//   iverilog -o tb_sar_adc.vvp rtl/tb_sar_adc.v rtl/sar_adc.v && vvp tb_sar_adc.vvp
//
// Tests:
//   T0     : parameter check — VREF_LO_MV=400, VREF_HI_MV=1400 (inp_dac rails)
//   T1–T5  : known voltage → code (floor, CODE_MIN, VCM, CODE_MAX, ceiling)
//   T6     : timing — done fires exactly BITS+1 cycles after rising edge of sample
//   T7     : level-high sample (FSM behavior) — done fires exactly once per
//              rising edge, no spurious restart while sample stays high
//   T8–T10 : additional voltage-domain checks covering mid-range and
//              the C4 inter-VL round-trip case (1071 mV → code 171)
//
// Comparator model:
//   All tests use a real-valued behavioural comparator that mirrors the
//   physical StrongARM latch:
//       cmp = 1  iff  vin_mv >= VREF_LO_MV + dac_out × (VREF_HI_MV−VREF_LO_MV)/255
//   This requires the SAR ADC Vref rails to be tied to the inp_dac Vref_lo/hi
//   pins, as documented in sar_adc.v.

`timescale 1ns/1ps

module tb_sar_adc;

    parameter BITS = 8;

    reg          clk, rst_n, sample;
    wire         done;
    wire [BITS-1:0] data, dac_out;

    // ── Real-valued voltage comparator model ──────────────────────────────────
    // Reads VREF_LO_MV and VREF_HI_MV from the DUT parameter block so that
    // the testbench stays in sync with whatever the module declares.
    real vin_mv;          // input voltage under test (millivolts)
    real vref_at_code;    // SAR reference voltage for the current dac_out code
    reg  cmp;             // comparator output driven to DUT

    always @(vin_mv or dac_out) begin
        vref_at_code = dut.VREF_LO_MV
                       + $itor(dac_out)
                         * (dut.VREF_HI_MV - dut.VREF_LO_MV) / 255.0;
        cmp = (vin_mv >= vref_at_code) ? 1'b1 : 1'b0;
    end

    sar_adc #(.BITS(BITS)) dut (
        .clk(clk), .rst_n(rst_n),
        .sample(sample), .done(done), .data(data),
        .dac_out(dac_out), .cmp(cmp)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ── Capture done events ───────────────────────────────────────────────────
    integer done_count;
    reg [BITS-1:0] done_data;

    always @(posedge clk) begin
        if (done) begin
            done_count <= done_count + 1;
            done_data  <= data;
        end
    end

    // ── Task: run one conversion and check result ─────────────────────────────
    // vin is in millivolts (real).  exp is the expected 8-bit output code.
    integer i;
    task run_conv;
        input real      vin;
        input [BITS-1:0] exp;
        input integer    test_num;
        begin
            vin_mv     = vin;
            done_count = 0;
            @(posedge clk); #1 sample = 1;
            @(posedge clk); #1 sample = 0;

            for (i = 0; i < BITS + 4; i = i + 1) @(posedge clk);

            if (!done_count)
                $display("FAIL T%0d: done never asserted (vin=%.1f mV)", test_num, vin);
            else if (done_data !== exp)
                $display("FAIL T%0d: vin=%.1f mV  exp=0x%02X  got=0x%02X",
                         test_num, vin, exp, done_data);
            else
                $display("PASS T%0d: vin=%.1f mV → code=0x%02X (%0d)",
                         test_num, vin, done_data, done_data);

            @(posedge clk);
        end
    endtask

    // ── Helper: exact DAC voltage for a given code ────────────────────────────
    // Returns the precise millivolt value that sits exactly on the DAC step,
    // guaranteeing round-trip code equality without rounding artefacts.
    function real dac_mv;
        input integer code;
        begin
            dac_mv = dut.VREF_LO_MV
                     + code * 1.0 * (dut.VREF_HI_MV - dut.VREF_LO_MV) / 255.0;
        end
    endfunction

    // ── Main test sequence ────────────────────────────────────────────────────
    integer edge_cycle;

    initial begin
        $dumpfile("tb_sar_adc.vcd");
        $dumpvars(0, tb_sar_adc);

        clk = 0; rst_n = 0; sample = 0; vin_mv = 900.0; done_count = 0;
        #20 rst_n = 1;
        @(posedge clk);

        // ── T0: parameter check ───────────────────────────────────────────────
        if (dut.VREF_LO_MV !== 400 || dut.VREF_HI_MV !== 1400)
            $display("FAIL T0: VREF params = %0d/%0d mV, expected 400/1400",
                     dut.VREF_LO_MV, dut.VREF_HI_MV);
        else
            $display("PASS T0: VREF_LO=%0d mV, VREF_HI=%0d mV (inp_dac rails)",
                     dut.VREF_LO_MV, dut.VREF_HI_MV);

        // ── T1–T5: voltage correctness ────────────────────────────────────────
        // Input voltages are the exact DAC output voltages for key codes,
        // so round-trip (voltage→ADC→code) must be exact.
        //
        //   T1: 400.0 mV = Vref_lo → code 0x00 (ADC floor)
        //   T2: dac_mv(71) ≈ 678.4 mV = CODE_MIN (Vw_min weight code)
        //   T3: dac_mv(128) ≈ 901.9 mV = CODE_MID (VCM)
        //   T4: dac_mv(192) ≈ 1153.0 mV = CODE_MAX (Vw_max weight code)
        //   T5: 1400.0 mV = Vref_hi → code 0xFF (ADC ceiling)
        run_conv(400.0,           8'h00, 1);
        run_conv(dac_mv(8'h47),   8'h47, 2);   // CODE_MIN = 71 = 0x47
        run_conv(dac_mv(8'h80),   8'h80, 3);   // CODE_MID = 128, VCM
        run_conv(dac_mv(8'hC0),   8'hC0, 4);   // CODE_MAX = 192
        run_conv(1400.0,           8'hFF, 5);

        // ── T6: timing — done asserts exactly BITS+1 cycles after rising edge ──
        vin_mv     = 900.0;   // VCM → code 128; value unimportant for timing test
        done_count = 0;
        edge_cycle = 0;
        @(posedge clk); #1 sample = 1;
        for (i = 0; i < BITS + 6; i = i + 1) begin
            @(posedge clk);
            if (done && edge_cycle == 0)
                edge_cycle = i + 1;
        end
        sample = 0;
        if (done_count == 0)
            $display("FAIL T6: done never fired");
        else if (edge_cycle == BITS + 2)
            $display("PASS T6: done observed at cycle %0d (= BITS+2 = %0d) ✓",
                     edge_cycle, BITS+2);
        else
            $display("FAIL T6: done at cycle %0d, expected %0d", edge_cycle, BITS+2);
        @(posedge clk);

        // ── T7: level-high sample — no spurious restart ────────────────────────
        // Sample stays HIGH for 3 × (BITS+4) = 36 cycles; done must fire exactly once.
        // Input: 1071.4 mV = C4 temporal-cascade VL0 output → expected code 0xAB = 171.
        vin_mv     = 1071.4;
        done_count = 0;
        done_data  = 0;
        @(posedge clk); #1 sample = 1;
        for (i = 0; i < 3 * (BITS + 4); i = i + 1) @(posedge clk);
        sample = 0;
        @(posedge clk);

        if (done_count != 1)
            $display("FAIL T7: done fired %0d times (expected 1) with level-high sample",
                     done_count);
        else if (done_data !== 8'hAB)
            $display("FAIL T7: result 0x%02X (expected 0xAB = 171)", done_data);
        else
            $display("PASS T7: level-high sample → single conversion, data=0x%02X (%0d)",
                     done_data, done_data);

        // ── T8–T10: additional voltage-domain checks ──────────────────────────
        //   T8:  dac_mv(128) ≈ 901.96 mV → code 0x80 = 128.
        //        Uses the exact DAC step voltage so the round-trip is identity.
        //        Note: VCM = 900.0 mV maps to code 127 (not 128) because the SAR
        //        comparator uses strict >=, placing the code-128 threshold at
        //        v_ref(128) = 401.96 mV above Vref_lo = 901.96 mV.  The
        //        round-trip error at VCM is |900.0 − 898.04| = 1.96 mV < 1 LSB.
        //   T9: 1071.4 mV → code 171 = 0xAB
        //        VL0 row-bus output from C4 (w=0.094, V_diff=50 mV).
        //        Verifies ADC captures a typical inter-VL activation correctly.
        //   T10: 700.0 mV → code 76 = 0x4C
        //        Sub-VCM case; floor(300/1000 × 255) = floor(76.47) = 76.
        run_conv(dac_mv(8'h80), 8'h80, 8);   // exact code-128 DAC voltage
        run_conv(1071.4,         8'hAB, 9);   // C4 VL0 output → 171
        run_conv(700.0,          8'h4C, 10);  // sub-VCM → 76

        $display("--- SAR ADC smoke test complete ---");
        #50 $finish;
    end

endmodule
