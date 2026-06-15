`default_nettype none
// Weight load FSM with temporal layer reuse extension (Path B, §52).
//
// Original interface (load_all / start_load / rst_weights):
//   Load weight SRAM contents to the analog DAC cells.  Unchanged.
//
// Temporal reuse interface (start_temporal / n_virt_layers):
//   Orchestrates N virtual layer cycles on one physical module.
//   Per cycle: save activations → load weights → load activations → compute.
//
//   Save activations: assert adc_sample per column, wait adc_done, write
//     adc_data to activation SRAM (act_*).
//   Load weights: iterate weight SRAM from base address vl_idx × N_CELLS;
//     same DAC write path as original SETUP/WRITE/NEXT_CELL states.
//   Load activations: read activation SRAM, drive inp_dac (inp_dac_*) for
//     each column, using hebb_pw as the settle count.
//
// SRAM addressing in temporal mode:
//   Weight SRAM depth must be N_CELLS × N_VIRT bytes.
//   sram_addr[SRAM_AW-1:CELL_AW] = virt_layer_idx  (tile-select upper bits)
//   sram_addr[CELL_AW-1:0]       = cell_idx
//   With default N_CELLS=32, N_VIRT=8: SRAM_AW=8, depth=256 bytes (2 tiles).
//
// ADC interface notes:
//   adc_sample: level signal, asserted while waiting for conversion.
//   adc_done:   single-cycle pulse from SAR ADC when conversion is complete.
//   An ADC stub (for simulation) should respond within a bounded number of
//   cycles (e.g., 8 cycles for 8-bit successive approximation).
//
// Timing contract for temporal mode:
//   The host must ensure the analog module has settled before asserting
//   start_temporal, and again before each new VL's activations are valid.
//   The FSM does not insert settle waits between VLs; the physical settling
//   time (~τ_OTA ~ 10 ns) is much shorter than hebb_pw (the DAC write pulse
//   width), so in practice the module settles during the next weight write.
//
module weight_fsm #(
    parameter N_CELLS  = 32,
    parameter N_VIRT   = 8,
    parameter CELL_AW  = $clog2(N_CELLS),
    parameter VIRT_AW  = $clog2(N_VIRT),
    parameter SRAM_AW  = CELL_AW + VIRT_AW   // weight SRAM address width
) (
    input  wire              clk,
    input  wire              rst_n,

    // ── Original weight-load interface ────────────────────────────────────────
    input  wire              start_load,
    input  wire              load_all,
    input  wire              rst_weights,
    input  wire       [15:0] cell_addr,
    input  wire        [7:0] weight_data,
    input  wire       [15:0] hebb_pw,         // DAC settle pulse width (cycles)

    // ── Weight SRAM interface (widened for temporal: SRAM_AW bits) ────────────
    output reg  [SRAM_AW-1:0] sram_addr,
    input  wire          [7:0] sram_rdata,

    // ── Weight DAC interface ──────────────────────────────────────────────────
    output reg        [15:0] dac_addr,
    output reg         [7:0] dac_data,
    output reg               dac_we,

    // ── Status (original) ─────────────────────────────────────────────────────
    output reg               busy,
    output reg               ready,
    output reg               irq_load_done,

    // ── Temporal reuse interface (Path B) ─────────────────────────────────────
    input  wire              start_temporal,
    input  wire              start_adc_sweep,  // trigger standalone ADC sweep → act_sram
    input  wire  [VIRT_AW:0] n_virt_layers,  // 1..N_VIRT

    // ADC interface: one conversion per column output per VL
    output reg               adc_sample,     // asserted while ADC is running
    input  wire              adc_done,
    input  wire        [7:0] adc_data,

    // Activation SRAM: N_CELLS × 8-bit (one page; same depth as weight SRAM tile)
    output reg  [CELL_AW-1:0] act_addr,
    output reg           [7:0] act_wdata,
    output reg                 act_we,
    input  wire          [7:0] act_rdata,

    // Input DAC: drives the inp node of each column's MAC cell
    output reg        [15:0] inp_dac_addr,
    output reg         [7:0] inp_dac_data,
    output reg               inp_dac_we,

    // Temporal status
    output reg  [VIRT_AW-1:0] virt_layer_idx,
    output reg               irq_temporal_done
);

    // ── State encoding ────────────────────────────────────────────────────────
    localparam ST_IDLE        = 5'd0;
    // Original weight-load states
    localparam ST_SETUP       = 5'd1;
    localparam ST_WRITE       = 5'd2;
    localparam ST_NEXT_CELL   = 5'd3;
    localparam ST_DONE        = 5'd4;
    // Temporal reuse states
    localparam ST_T_INIT      = 5'd5;   // latch n_virt_layers, zero indices
    localparam ST_T_ASAVE     = 5'd6;   // assert adc_sample; wait adc_done
    localparam ST_T_ASAVE_MEM = 5'd7;   // write adc_data to act_sram[cell_idx]
    localparam ST_T_ASAVE_NX  = 5'd8;   // advance cell or move to weight load
    localparam ST_T_WT_SETUP  = 5'd9;   // present weight SRAM data to DAC
    localparam ST_T_WT_WRITE  = 5'd10;  // DAC write pulse (hebb_pw cycles)
    localparam ST_T_WT_NEXT   = 5'd11;  // advance cell or move to act load
    localparam ST_T_ALOAD     = 5'd12;  // read act_sram; present to inp_dac
    localparam ST_T_ALOAD_WR  = 5'd13;  // inp_dac write pulse (hebb_pw cycles)
    localparam ST_T_ALOAD_NX  = 5'd14;  // advance cell or move to next VL
    localparam ST_T_NEXTVL    = 5'd15;  // increment virt_layer_idx
    localparam ST_T_DONE      = 5'd16;  // all VLs complete
    // Standalone ADC sweep states (GHA firmware support, §66.5 Change B)
    localparam ST_ADC_INIT    = 5'd17;  // zero cell_idx, pre-address act_sram
    localparam ST_ADC_SAMPLE  = 5'd18;  // assert adc_sample; wait adc_done
    localparam ST_ADC_MEM     = 5'd19;  // write adc_data to act_sram[cell_idx]
    localparam ST_ADC_NX      = 5'd20;  // advance cell_idx or finish
    localparam ST_ADC_DONE    = 5'd21;  // pulse irq_load_done, return to IDLE

    reg [4:0]            state;
    reg                  doing_all;
    reg                  do_reset;
    reg  [CELL_AW-1:0]   cell_idx;
    reg [15:0]           settle_cnt;
    reg  [VIRT_AW:0]     vl_total;         // latched n_virt_layers
    reg  [SRAM_AW-1:0]   wt_base;          // = virt_layer_idx << CELL_AW

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            doing_all         <= 1'b0;
            do_reset          <= 1'b0;
            cell_idx          <= {CELL_AW{1'b0}};
            settle_cnt        <= 16'h0;
            dac_we            <= 1'b0;
            dac_addr          <= 16'h0;
            dac_data          <= 8'h80;
            sram_addr         <= {SRAM_AW{1'b0}};
            busy              <= 1'b0;
            ready             <= 1'b1;
            irq_load_done     <= 1'b0;
            adc_sample        <= 1'b0;
            act_addr          <= {CELL_AW{1'b0}};
            act_wdata         <= 8'h0;
            act_we            <= 1'b0;
            inp_dac_addr      <= 16'h0;
            inp_dac_data      <= 8'h80;
            inp_dac_we        <= 1'b0;
            virt_layer_idx    <= {VIRT_AW{1'b0}};
            vl_total          <= {(VIRT_AW+1){1'b0}};
            wt_base           <= {SRAM_AW{1'b0}};
            irq_temporal_done <= 1'b0;
        end else begin
            // Default deasserts every cycle
            dac_we            <= 1'b0;
            irq_load_done     <= 1'b0;
            adc_sample        <= 1'b0;
            act_we            <= 1'b0;
            inp_dac_we        <= 1'b0;
            irq_temporal_done <= 1'b0;

            case (state)

                // ── Original weight-load states ───────────────────────────────
                ST_IDLE: begin
                    busy  <= 1'b0;
                    ready <= 1'b1;
                    if (start_temporal) begin
                        busy  <= 1'b1;
                        ready <= 1'b0;
                        state <= ST_T_INIT;
                    end else if (load_all) begin
                        doing_all <= 1'b1;
                        do_reset  <= 1'b0;
                        cell_idx  <= {CELL_AW{1'b0}};
                        sram_addr <= {SRAM_AW{1'b0}};
                        busy      <= 1'b1;
                        ready     <= 1'b0;
                        state     <= ST_SETUP;
                    end else if (start_load) begin
                        doing_all <= 1'b0;
                        do_reset  <= 1'b0;
                        dac_addr  <= cell_addr;
                        dac_data  <= weight_data;
                        busy      <= 1'b1;
                        ready     <= 1'b0;
                        state     <= ST_SETUP;
                    end else if (rst_weights) begin
                        doing_all <= 1'b1;
                        do_reset  <= 1'b1;
                        cell_idx  <= {CELL_AW{1'b0}};
                        sram_addr <= {SRAM_AW{1'b0}};
                        busy      <= 1'b1;
                        ready     <= 1'b0;
                        state     <= ST_SETUP;
                    end else if (start_adc_sweep) begin
                        busy     <= 1'b1;
                        ready    <= 1'b0;
                        state    <= ST_ADC_INIT;
                    end
                end

                ST_SETUP: begin
                    if (doing_all) begin
                        dac_addr <= {{(16-CELL_AW){1'b0}}, cell_idx};
                        dac_data <= do_reset ? 8'h80 : sram_rdata;
                    end
                    settle_cnt <= hebb_pw;
                    state      <= ST_WRITE;
                end

                ST_WRITE: begin
                    dac_we <= 1'b1;
                    if (settle_cnt == 16'h0)
                        state <= doing_all ? ST_NEXT_CELL : ST_DONE;
                    else
                        settle_cnt <= settle_cnt - 1'b1;
                end

                ST_NEXT_CELL: begin
                    if (cell_idx == N_CELLS-1) begin
                        state <= ST_DONE;
                    end else begin
                        cell_idx  <= cell_idx + 1'b1;
                        sram_addr <= {{VIRT_AW{1'b0}}, cell_idx + 1'b1};
                        state     <= ST_SETUP;
                    end
                end

                ST_DONE: begin
                    irq_load_done <= 1'b1;
                    busy          <= 1'b0;
                    ready         <= 1'b1;
                    do_reset      <= 1'b0;
                    state         <= ST_IDLE;
                end

                // ── Temporal reuse states (Path B) ────────────────────────────
                ST_T_INIT: begin
                    vl_total       <= n_virt_layers;
                    virt_layer_idx <= {VIRT_AW{1'b0}};
                    wt_base        <= {SRAM_AW{1'b0}};
                    cell_idx       <= {CELL_AW{1'b0}};
                    act_addr       <= {CELL_AW{1'b0}};
                    sram_addr      <= {SRAM_AW{1'b0}};
                    state          <= ST_T_ASAVE;
                end

                // Save activations: trigger ADC for each column output
                ST_T_ASAVE: begin
                    adc_sample <= 1'b1;
                    if (adc_done)
                        state <= ST_T_ASAVE_MEM;
                end

                ST_T_ASAVE_MEM: begin
                    act_addr  <= cell_idx;
                    act_wdata <= adc_data;
                    act_we    <= 1'b1;
                    state     <= ST_T_ASAVE_NX;
                end

                ST_T_ASAVE_NX: begin
                    if (cell_idx == N_CELLS-1) begin
                        // All columns saved; load weights for this VL
                        cell_idx  <= {CELL_AW{1'b0}};
                        sram_addr <= wt_base;   // first weight of this VL
                        state     <= ST_T_WT_SETUP;
                    end else begin
                        cell_idx <= cell_idx + 1'b1;
                        act_addr <= cell_idx + 1'b1;
                        state    <= ST_T_ASAVE;
                    end
                end

                // Load weights: iterate weight SRAM from wt_base
                ST_T_WT_SETUP: begin
                    // sram_addr was set last cycle; sram_rdata is valid now
                    dac_addr   <= {{(16-SRAM_AW){1'b0}}, sram_addr};
                    dac_data   <= sram_rdata;
                    settle_cnt <= hebb_pw;
                    state      <= ST_T_WT_WRITE;
                end

                ST_T_WT_WRITE: begin
                    dac_we <= 1'b1;
                    if (settle_cnt == 16'h0)
                        state <= ST_T_WT_NEXT;
                    else
                        settle_cnt <= settle_cnt - 1'b1;
                end

                ST_T_WT_NEXT: begin
                    if (cell_idx == N_CELLS-1) begin
                        // All weights loaded; load activations
                        cell_idx <= {CELL_AW{1'b0}};
                        act_addr <= {CELL_AW{1'b0}};  // pre-address for SRAM read
                        state    <= ST_T_ALOAD;
                    end else begin
                        cell_idx  <= cell_idx + 1'b1;
                        sram_addr <= wt_base + (cell_idx + 1'b1);
                        state     <= ST_T_WT_SETUP;
                    end
                end

                // Load activations: read act_sram → drive inp_dac per column
                ST_T_ALOAD: begin
                    // act_addr set last cycle; act_rdata is valid now
                    inp_dac_addr <= {{(16-CELL_AW){1'b0}}, cell_idx};
                    inp_dac_data <= act_rdata;
                    settle_cnt   <= hebb_pw;
                    state        <= ST_T_ALOAD_WR;
                end

                ST_T_ALOAD_WR: begin
                    inp_dac_we <= 1'b1;
                    if (settle_cnt == 16'h0)
                        state <= ST_T_ALOAD_NX;
                    else
                        settle_cnt <= settle_cnt - 1'b1;
                end

                ST_T_ALOAD_NX: begin
                    if (cell_idx == N_CELLS-1) begin
                        state <= ST_T_NEXTVL;
                    end else begin
                        cell_idx <= cell_idx + 1'b1;
                        act_addr <= cell_idx + 1'b1;
                        state    <= ST_T_ALOAD;
                    end
                end

                ST_T_NEXTVL: begin
                    if (virt_layer_idx == vl_total - 1) begin
                        state <= ST_T_DONE;
                    end else begin
                        // Advance to next virtual layer
                        virt_layer_idx <= virt_layer_idx + 1'b1;
                        wt_base        <= wt_base + N_CELLS[SRAM_AW-1:0];
                        cell_idx       <= {CELL_AW{1'b0}};
                        act_addr       <= {CELL_AW{1'b0}};
                        // Pre-address weight SRAM for first cell of next VL
                        sram_addr      <= wt_base + N_CELLS[SRAM_AW-1:0];
                        state          <= ST_T_ASAVE;
                    end
                end

                ST_T_DONE: begin
                    irq_temporal_done <= 1'b1;
                    busy              <= 1'b0;
                    ready             <= 1'b1;
                    state             <= ST_IDLE;
                end

                // ── Standalone ADC sweep (GHA firmware support) ───────────────
                ST_ADC_INIT: begin
                    cell_idx <= {CELL_AW{1'b0}};
                    state    <= ST_ADC_SAMPLE;
                end

                ST_ADC_SAMPLE: begin
                    adc_sample <= 1'b1;
                    if (adc_done)
                        state <= ST_ADC_MEM;
                end

                ST_ADC_MEM: begin
                    act_addr  <= cell_idx;
                    act_wdata <= adc_data;
                    act_we    <= 1'b1;
                    state     <= ST_ADC_NX;
                end

                ST_ADC_NX: begin
                    if (cell_idx == N_CELLS-1) begin
                        state <= ST_ADC_DONE;
                    end else begin
                        cell_idx <= cell_idx + 1'b1;
                        state    <= ST_ADC_SAMPLE;
                    end
                end

                ST_ADC_DONE: begin
                    irq_load_done <= 1'b1;
                    busy          <= 1'b0;
                    ready         <= 1'b1;
                    state         <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
