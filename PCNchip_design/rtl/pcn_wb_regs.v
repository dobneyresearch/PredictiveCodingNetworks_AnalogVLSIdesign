`default_nettype none
// For N_ROWS > 32, HEBB_MASK spans more than one 32-bit Wishbone word.
// Add HEBB_MASK_HI at offset 5'h07 before using N_ROWS > 32.
// cell_addr is 16 bits, covering up to 65536 cells within a chip (N_ROWS × N_COLS ≤ 65536).
//
// Register map (byte offsets; word-addressed at addr[6:2]):
//   0x00  WEIGHT_DATA   [7:0]         — weight byte to write
//   0x04  CELL_ADDR     [15:0]        — target cell (16-bit)
//   0x08  CTRL          [5:0]         — [0]=start_load [1]=load_all [2]=hebb_en
//                                       [3]=sleep_req  [4]=rst_weights [5]=start_temporal
//                                       [6]=start_adc_sweep (pulse; not stored in ctrl[5:0])
//   0x0C  STATUS        [3:0]         — read-only: {sleep_ack, hebb_actv, busy, ready}
//   0x10  HEBB_MASK     [N_ROWS-1:0]  — static row enable (1=row may do Hebbian updates)
//   0x14  HEBB_PW       [15:0]        — Hebbian pulse width in clock cycles
//   0x18  SRAM_DATA     [7:0]         — direct SRAM r/w at cell_addr
//   0x1C  (reserved — HEBB_MASK_HI for N_ROWS > 32)
//   0x20  N_VIRT_LAYERS [VIRT_AW:0]  — number of virtual layers for temporal reuse
//   0x24  HEBB_ROW_MASK [N_ROWS-1:0] — k-WTA per-step mask (firmware writes before each
//                                       Hebbian step; ANDed with HEBB_MASK for effective mask;
//                                       default all-ones = no additional gating)
//   0x28  IERR_DIG      [N_ROWS-1:0] — read-only: latched precision-gate error flags,
//                                       one bit per row; firmware reads to select top-k rows
//   0x2C  INP_DAC_DATA  [7:0]         — one-cycle inp_dac write at cell_addr (write only)
//   0x30  ACT_SRAM_DATA [7:0]         — act_sram r/w at cell_addr
//                                       (read: valid 1 cycle after cell_addr write)
module pcn_wb_regs #(
    parameter N_ROWS  = 4,   // controls hebb_mask/hebb_row_mask width; one bit per output row
    parameter VIRT_AW = 3    // must match weight_fsm / pcn_digital_top
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] wb_addr_i,
    input  wire [31:0] wb_dat_i,
    input  wire  [3:0] wb_sel_i,
    input  wire        wb_we_i,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o,
    output reg   [7:0] weight_data,
    output reg  [15:0] cell_addr,              // 16-bit: addresses up to 65536 cells
    output reg   [5:0] ctrl,
    output reg  [N_ROWS-1:0] hebb_mask,        // static row enable
    output reg  [15:0] hebb_pw,
    input  wire  [3:0] status,
    output reg   [7:0] sram_wdata,
    output reg         sram_we,
    input  wire  [7:0] sram_rdata,
    output reg         start_load,
    output reg         load_all,
    output reg         rst_weights,
    output reg         start_temporal,         // one-cycle pulse: triggers temporal FSM
    output reg  [VIRT_AW:0] n_virt_layers,    // number of virtual layers (1..N_VIRT)
    output reg  [N_ROWS-1:0] hebb_row_mask,   // k-WTA per-step mask (ANDed with hebb_mask)
    input  wire [N_ROWS-1:0] ierr_dig_i,       // latched error flags from precision gate
    output reg        start_adc_sweep,         // CTRL[6]: one-cycle pulse → standalone ADC sweep
    output reg  [7:0] inp_dac_wb_data,         // inp_dac write data  (0x2C)
    output reg [15:0] inp_dac_wb_addr,         // inp_dac address = cell_addr at write time
    output reg        inp_dac_wb_we,           // inp_dac write strobe (one cycle)
    input  wire [7:0] act_rdata_wb_i,          // act_sram read data at cell_addr (0x30)
    output reg  [7:0] act_wb_wdata,            // act_sram write data (0x30)
    output reg        act_wb_we                // act_sram write strobe (one cycle)
);
    wire sel = wb_cyc_i & wb_stb_i;
    wire [4:0] addr = wb_addr_i[6:2];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight_data    <= 8'h80; cell_addr <= 16'h0000; ctrl <= 6'h00;
            hebb_mask      <= {N_ROWS{1'b1}}; hebb_pw <= 16'd2500;
            wb_ack_o       <= 1'b0; wb_dat_o <= 32'h0;
            start_load     <= 1'b0; load_all <= 1'b0; rst_weights <= 1'b0;
            start_temporal <= 1'b0; n_virt_layers <= {(VIRT_AW+1){1'b0}};
            sram_we        <= 1'b0; sram_wdata <= 8'h00;
            hebb_row_mask  <= {N_ROWS{1'b1}};  // default: all rows permitted
            start_adc_sweep  <= 1'b0;
            inp_dac_wb_we    <= 1'b0; inp_dac_wb_data <= 8'h80; inp_dac_wb_addr <= 16'h0;
            act_wb_we        <= 1'b0; act_wb_wdata <= 8'h00;
        end else begin
            start_load     <= 1'b0; load_all <= 1'b0; rst_weights <= 1'b0;
            start_temporal <= 1'b0; start_adc_sweep <= 1'b0;
            sram_we        <= 1'b0; wb_ack_o <= 1'b0;
            inp_dac_wb_we  <= 1'b0; act_wb_we <= 1'b0;
            if (sel) begin
                wb_ack_o <= 1'b1;
                if (wb_we_i) begin
                    case (addr)
                        5'h00: weight_data <= wb_dat_i[7:0];
                        5'h01: cell_addr   <= wb_dat_i[15:0];    // 16-bit address
                        5'h02: begin
                            ctrl <= wb_dat_i[5:0];
                            if (wb_dat_i[0]) start_load      <= 1'b1;
                            if (wb_dat_i[1]) load_all        <= 1'b1;
                            if (wb_dat_i[4]) rst_weights     <= 1'b1;
                            if (wb_dat_i[5]) start_temporal  <= 1'b1;
                            if (wb_dat_i[6]) start_adc_sweep <= 1'b1;
                        end
                        5'h04: hebb_mask     <= wb_dat_i;        // truncates to N_ROWS bits
                        5'h05: hebb_pw       <= wb_dat_i[15:0];
                        5'h06: begin sram_wdata <= wb_dat_i[7:0]; sram_we <= 1'b1; end
                        5'h08: n_virt_layers <= wb_dat_i[VIRT_AW:0];
                        5'h09: hebb_row_mask <= wb_dat_i[N_ROWS-1:0]; // k-WTA step mask
                        // 5'h0A: IERR_DIG is read-only; writes are silently ignored
                        5'h0B: begin    // 0x2C INP_DAC_DATA: one-cycle inp_dac write
                            inp_dac_wb_data <= wb_dat_i[7:0];
                            inp_dac_wb_addr <= cell_addr;
                            inp_dac_wb_we   <= 1'b1;
                        end
                        5'h0C: begin    // 0x30 ACT_SRAM_DATA: write act_sram at cell_addr
                            act_wb_wdata <= wb_dat_i[7:0];
                            act_wb_we    <= 1'b1;
                        end
                        default: ;
                    endcase
                end else begin
                    case (addr)
                        5'h00: wb_dat_o <= {24'h0, weight_data};
                        5'h01: wb_dat_o <= {16'h0, cell_addr};   // 16-bit readback
                        5'h02: wb_dat_o <= {26'h0, ctrl};
                        5'h03: wb_dat_o <= {28'h0, status};
                        5'h04: wb_dat_o <= hebb_mask;            // zero-extends if N_ROWS < 32
                        5'h05: wb_dat_o <= {16'h0, hebb_pw};
                        5'h06: wb_dat_o <= {24'h0, sram_rdata};
                        5'h08: wb_dat_o <= {{(31-VIRT_AW){1'b0}}, n_virt_layers};
                        5'h09: wb_dat_o <= hebb_row_mask;        // zero-extends if N_ROWS < 32
                        5'h0A: wb_dat_o <= {{(32-N_ROWS){1'b0}}, ierr_dig_i}; // R/O error flags
                        5'h0C: wb_dat_o <= {24'h0, act_rdata_wb_i};             // ACT_SRAM_DATA
                        default: wb_dat_o <= 32'h0;
                    endcase
                end
            end
        end
    end
endmodule
