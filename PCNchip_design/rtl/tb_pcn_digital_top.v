// tb_pcn_digital_top.v — smoke test for register access, FSM sequencing, and
// full temporal loop (T8): one complete N_VL=1 temporal inference cycle.

`timescale 1ns/1ps

module tb_pcn_digital_top;

    localparam N_ROWS  = 4;
    localparam N_COLS  = 8;
    localparam N_CELLS = N_ROWS * N_COLS;   // = 32

    reg clk, rst_n;
    reg [31:0] wb_addr; reg [31:0] wb_dat_i; reg [3:0] wb_sel;
    reg wb_we, wb_cyc, wb_stb;
    wire [31:0] wb_dat_o; wire wb_ack;
    wire [2:0]  user_irq;
    wire [31:0] la_out;
    wire [N_ROWS-1:0] we_out;
    wire [15:0] dac_addr;
    wire  [7:0] dac_data; wire dac_we;
    wire        full_power, keep_alive;

    // SAR ADC analog boundary
    wire  [7:0] adc_dac_out;
    reg         adc_cmp;

    // Activation DAC analog boundary
    wire [15:0] inp_dac_addr;
    wire  [7:0] inp_dac_data;
    wire        inp_dac_we;

    wire [N_ROWS-1:0] ierr = {{(N_ROWS-1){1'b0}}, 1'b1};  // row 0 error only

    pcn_digital_top #(.N_ROWS(N_ROWS), .N_COLS(N_COLS)) dut (
        .clk(clk), .rst_n(rst_n),
        .wb_addr_i(wb_addr), .wb_dat_i(wb_dat_i), .wb_sel_i(wb_sel),
        .wb_we_i(wb_we), .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb),
        .wb_dat_o(wb_dat_o), .wb_ack_o(wb_ack),
        .user_irq(user_irq), .la_data_out(la_out),
        .dac_addr(dac_addr), .dac_data(dac_data), .dac_we(dac_we),
        .ierr(ierr), .we_out(we_out),
        .full_power(full_power), .keep_alive(keep_alive),
        .adc_dac_out(adc_dac_out), .adc_cmp(adc_cmp),
        .inp_dac_addr(inp_dac_addr), .inp_dac_data(inp_dac_data),
        .inp_dac_we(inp_dac_we)
    );

    // Behavioural SAR comparator: fixed vin=0xA0 for T8
    localparam [7:0] VIN = 8'hA0;
    always @(*) adc_cmp = (adc_dac_out <= VIN);

    always #10 clk = ~clk;     // 50 MHz

    task wb_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            wb_addr = addr; wb_dat_i = data; wb_sel = 4'hF;
            wb_we = 1; wb_cyc = 1; wb_stb = 1;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            wb_cyc = 0; wb_stb = 0; wb_we = 0;
        end
    endtask

    task wb_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            wb_addr = addr; wb_sel = 4'hF;
            wb_we = 0; wb_cyc = 1; wb_stb = 1;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            data = wb_dat_o;
            wb_cyc = 0; wb_stb = 0;
        end
    endtask

    // Count inp_dac_we rising edges (one per cell column) and catch irq[0]
    integer inp_dac_we_count;
    reg     irq_temporal_seen;
    reg     inp_dac_we_prev;
    always @(posedge clk) begin
        if (inp_dac_we && !inp_dac_we_prev) inp_dac_we_count = inp_dac_we_count + 1;
        inp_dac_we_prev <= inp_dac_we;
        if (user_irq[0]) irq_temporal_seen = 1;
    end

    // Poll STATUS.READY up to max_cycles; return ready bit
    task wait_ready;
        input integer max_cycles;
        output ready;
        reg ready;
        integer cnt;
        reg [31:0] rd;
        begin
            ready = 0; cnt = 0;
            while (!ready && cnt < max_cycles) begin
                repeat(20) @(posedge clk);
                cnt = cnt + 20;
                wb_read(32'h3000_000C, rd);
                ready = rd[0];
            end
        end
    endtask

    reg [31:0] rdata;
    reg t8_ready;

    // T11/T12 capture: latch last inp_dac write seen on the output pins
    reg [15:0] last_inp_dac_addr;
    reg  [7:0] last_inp_dac_data;
    reg        t12_irq_seen;
    reg        t12_ready;

    always @(posedge clk) begin
        if (inp_dac_we) begin
            last_inp_dac_addr <= inp_dac_addr;
            last_inp_dac_data <= inp_dac_data;
        end
        if (user_irq[0]) t12_irq_seen = 1;
    end

    initial begin
        clk = 0; rst_n = 0; wb_cyc = 0; wb_stb = 0; wb_we = 0;
        inp_dac_we_count = 0; irq_temporal_seen = 0; inp_dac_we_prev = 0;
        last_inp_dac_addr = 0; last_inp_dac_data = 0;
        t12_irq_seen = 0; t12_ready = 0;
        #50 rst_n = 1;

        // ── T1: STATUS.READY = 1 ───────────────────────────────────────────────
        wb_read(32'h3000_000C, rdata);
        if (rdata[0] !== 1'b1) $display("FAIL T1: STATUS.READY not set");
        else                   $display("PASS T1: STATUS.READY = 1");

        // ── T2: single weight write ────────────────────────────────────────────
        wb_write(32'h3000_0000, 32'h0000_00AB);  // WEIGHT_DATA = 0xAB
        wb_write(32'h3000_0004, 32'h0000_0003);  // CELL_ADDR = 3
        wb_write(32'h3000_0008, 32'h0000_0001);  // CTRL.START_LOAD
        repeat(5000) @(posedge clk);
        wb_read(32'h3000_000C, rdata);
        if (rdata[0] !== 1'b1) $display("FAIL T2: weight write timed out");
        else                   $display("PASS T2: single weight written");

        // ── T3: 16-bit cell_addr round-trip ───────────────────────────────────
        wb_write(32'h3000_0004, 32'h0000_0105);
        wb_read(32'h3000_0004, rdata);
        if (rdata[15:0] !== 16'h0105) $display("FAIL T3: cell_addr got %04X", rdata[15:0]);
        else                          $display("PASS T3: 16-bit cell_addr 0x0105 round-trips");

        // ── T4: direct SRAM write/readback ────────────────────────────────────
        wb_write(32'h3000_0004, 32'h0000_0005);
        wb_write(32'h3000_0018, 32'h0000_00AB);
        repeat(3) @(posedge clk);
        wb_read(32'h3000_0018, rdata);
        if (rdata[7:0] !== 8'hAB) $display("FAIL T4: SRAM readback %02X", rdata[7:0]);
        else                      $display("PASS T4: SRAM readback 0xAB");

        // ── T5: Hebbian we_out[0] pulses ──────────────────────────────────────
        wb_write(32'h3000_0014, 32'h0000_000A);
        wb_write(32'h3000_0010, 32'hFFFF_FFFF);
        wb_write(32'h3000_0008, 32'h0000_0004);  // CTRL.HEBB_EN
        repeat(30) @(posedge clk);
        if (!we_out[0]) $display("FAIL T5: we_out[0] never asserted");
        else            $display("PASS T5: Hebbian we_out[0] pulsed");

        // ── T6: rst_weights ───────────────────────────────────────────────────
        wb_write(32'h3000_0014, 32'h0000_0005);
        wb_write(32'h3000_0008, 32'h0000_0010);  // CTRL.RST_W
        repeat(5000) @(posedge clk);
        wb_read(32'h3000_000C, rdata);
        if (rdata[0] !== 1'b1) $display("FAIL T6: rst_weights timed out");
        else                   $display("PASS T6: rst_weights completed");

        // ── T7: temporal WB registers + FSM entry check ───────────────────────
        wb_write(32'h3000_0020, 32'h0000_0002);
        wb_read(32'h3000_0020, rdata);
        if (rdata[3:0] !== 4'd2)
            $display("FAIL T7a: n_virt_layers readback %0d (expected 2)", rdata[3:0]);
        else
            $display("PASS T7a: n_virt_layers = 2 round-trips");

        wb_write(32'h3000_0008, 32'h0000_0020);   // CTRL[5] = start_temporal
        repeat(50) @(posedge clk);
        wb_read(32'h3000_000C, rdata);
        if (rdata[1] !== 1'b1)
            $display("FAIL T7b: busy not set after start_temporal");
        else
            $display("PASS T7b: busy=1 after start_temporal");

        // Reset before T8
        rst_n = 0; repeat(5) @(posedge clk); rst_n = 1;
        inp_dac_we_count = 0; irq_temporal_seen = 0; inp_dac_we_prev = 0;
        repeat(5) @(posedge clk);

        // ── T8: full temporal loop — N_VL=1, hebb_pw=2, vin=0xA0 ─────────────
        // ADC: 32 conversions × 10 cycles = 320 cycles
        // Weight DAC: 32 × (hebb_pw+1=3) = 96 cycles
        // inp_dac:    32 × (hebb_pw+1=3) = 96 cycles
        // Total ≈ 520 cycles + FSM overhead — budget 2000
        wb_write(32'h3000_0014, 32'h0000_0002);   // HEBB_PW = 2 (minimal settle)
        wb_write(32'h3000_0020, 32'h0000_0001);   // N_VIRT_LAYERS = 1
        wb_write(32'h3000_0008, 32'h0000_0020);   // CTRL[5] = start_temporal
        wait_ready(2000, t8_ready);
        if (!t8_ready)
            $display("FAIL T8a: temporal loop not ready within 2000 cycles");
        else
            $display("PASS T8a: temporal loop completed (ready=1)");
        if (inp_dac_we_count !== N_CELLS)
            $display("FAIL T8b: inp_dac_we count=%0d (expected %0d)",
                     inp_dac_we_count, N_CELLS);
        else
            $display("PASS T8b: inp_dac_we pulsed %0d times = N_CELLS", inp_dac_we_count);
        if (!irq_temporal_seen)
            $display("FAIL T8c: user_irq[0] never pulsed");
        else
            $display("PASS T8c: user_irq[0] pulsed (temporal_done)");

        // ── T9: HEBB_ROW_MASK read/write round-trip ──────────────────────────
        // After reset hebb_row_mask defaults to all-ones (N_ROWS=4 → 0xF).
        wb_read(32'h3000_0024, rdata);
        if (rdata[N_ROWS-1:0] !== {N_ROWS{1'b1}})
            $display("FAIL T9a: HEBB_ROW_MASK reset default 0x%0X (expected 0x%0X)",
                     rdata[N_ROWS-1:0], {N_ROWS{1'b1}});
        else
            $display("PASS T9a: HEBB_ROW_MASK default = 0x%0X (all rows allowed)",
                     rdata[N_ROWS-1:0]);

        // Write k-WTA mask: allow only rows 0 and 2 (k=2 of 4)
        wb_write(32'h3000_0024, 32'h0000_0005);   // 4'b0101 = rows 0,2 only
        wb_read(32'h3000_0024, rdata);
        if (rdata[N_ROWS-1:0] !== 4'b0101)
            $display("FAIL T9b: HEBB_ROW_MASK readback 0x%0X (expected 0x5)",
                     rdata[N_ROWS-1:0]);
        else
            $display("PASS T9b: HEBB_ROW_MASK = 0x5 (rows 0,2 selected)");

        // With ierr=4'b0001 (row 0 only) and hebb_mask=all-ones, hebb_row_mask=0x5,
        // eff_hebb_mask = 0xF & 0x5 = 0x5.  Row 0 has ierr=1 and is in mask → fires.
        // Row 1 has ierr=0 → no fire. Row 2 has ierr=0 → no fire (mask bit is set
        // but ierr not active). Verify we_out[0] still fires (row 0 in mask AND ierr).
        // Set hebb_pw=50 so the pulse outlasts the 20-cycle sample window.
        wb_write(32'h3000_0014, 32'h0000_0032);   // HEBB_PW = 50 (pulse > 20-cycle window)
        wb_write(32'h3000_0008, 32'h0000_0004);   // CTRL[2] = hebb_en
        repeat(20) @(posedge clk);
        if (!we_out[0])
            $display("FAIL T9c: we_out[0] did not fire (row in mask + ierr active)");
        else
            $display("PASS T9c: we_out[0] fires when row 0 in HEBB_ROW_MASK + ierr[0]");
        wb_write(32'h3000_0008, 32'h0000_0000);   // hebb_en = 0
        repeat(5) @(posedge clk);

        // ── T10: IERR_DIG read-only register ─────────────────────────────────
        // ierr input is wired to 4'b0001 (row 0 only) in this testbench.
        wb_read(32'h3000_0028, rdata);
        if (rdata[N_ROWS-1:0] !== 4'b0001)
            $display("FAIL T10a: IERR_DIG = 0x%0X (expected 0x1, row 0 active)",
                     rdata[N_ROWS-1:0]);
        else
            $display("PASS T10a: IERR_DIG = 0x1 (row 0 error flag visible)");

        // Writes to IERR_DIG should be silently ignored (register stays at input value)
        wb_write(32'h3000_0028, 32'hFFFF_FFFF);
        wb_read(32'h3000_0028, rdata);
        if (rdata[N_ROWS-1:0] !== 4'b0001)
            $display("FAIL T10b: IERR_DIG changed after write (should be read-only, got 0x%0X)",
                     rdata[N_ROWS-1:0]);
        else
            $display("PASS T10b: IERR_DIG is read-only (write ignored, still 0x1)");

        // ── T11: direct inp_dac write via WB at 0x2C ──────────────────────────
        // Write cell_addr=7, then write 0xCD to INP_DAC_DATA.
        // Verify inp_dac_we fires for one cycle with correct addr and data.
        wb_write(32'h3000_0004, 32'h0000_0007);   // CELL_ADDR = 7
        wb_write(32'h3000_002C, 32'h0000_00CD);   // INP_DAC_DATA = 0xCD at cell 7
        @(posedge clk);   // allow always-block to capture at posedge after WB ACK
        if (last_inp_dac_data !== 8'hCD)
            $display("FAIL T11a: inp_dac_data = 0x%02X (expected 0xCD)", last_inp_dac_data);
        else
            $display("PASS T11a: inp_dac_data = 0xCD via WB write");
        if (last_inp_dac_addr !== 16'h0007)
            $display("FAIL T11b: inp_dac_addr = 0x%04X (expected 0x0007)", last_inp_dac_addr);
        else
            $display("PASS T11b: inp_dac_addr = 0x0007 (= cell_addr at write time)");

        // ── T12: standalone ADC sweep via CTRL[6] ─────────────────────────────
        // CTRL[6] triggers start_adc_sweep: FSM sweeps all N_CELLS columns,
        // stores ADC results in act_sram, then pulses irq[0] and returns ready.
        // VIN = 0xA0 → expect act_sram[0..N_CELLS-1] = 0xA0.
        // Budget: N_CELLS × ~15 cycles = 480 + overhead → 1000 cycles.
        t12_irq_seen = 0;
        wb_write(32'h3000_0008, 32'h0000_0040);   // CTRL[6] = start_adc_sweep
        repeat(5) @(posedge clk);
        wb_read(32'h3000_000C, rdata);
        if (rdata[1] !== 1'b1)
            $display("FAIL T12a: busy not set after start_adc_sweep");
        else
            $display("PASS T12a: busy=1 after start_adc_sweep");
        wait_ready(1000, t12_ready);
        if (!t12_ready)
            $display("FAIL T12b: ADC sweep not ready within 1000 cycles");
        else
            $display("PASS T12b: ADC sweep completed (ready=1)");
        if (!t12_irq_seen)
            $display("FAIL T12c: user_irq[0] never pulsed after ADC sweep");
        else
            $display("PASS T12c: user_irq[0] pulsed (irq_load_done from ADC sweep)");

        // ── T13: read act_sram via WB at 0x30 after ADC sweep ─────────────────
        // After the sweep, act_sram[cell] = ADC(VIN=0xA0) = 0xA0.
        // Set cell_addr=5, then read ACT_SRAM_DATA; expect 0xA0.
        wb_write(32'h3000_0004, 32'h0000_0005);   // CELL_ADDR = 5
        wb_read(32'h3000_0030, rdata);             // ACT_SRAM_DATA at cell 5
        if (rdata[7:0] !== 8'hA0)
            $display("FAIL T13: act_sram[5] = 0x%02X (expected 0xA0)", rdata[7:0]);
        else
            $display("PASS T13: act_sram[5] = 0xA0 (ADC result via WB read)");

        $display("--- Digital core smoke test complete ---");
        #100 $finish;
    end

endmodule
