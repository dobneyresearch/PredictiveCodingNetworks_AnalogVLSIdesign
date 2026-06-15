`default_nettype none
// Digital controller for one PCN module.
//
// N_ROWS x N_COLS weight matrix. In temporal reuse mode (Path B), the physical
// module is multiplexed across N_VIRT=8 virtual layers; the weight SRAM is
// widened to N_CELLS x N_VIRT entries and activations are saved per column
// via the SAR ADC, stored in act_sram, then replayed via inp_dac.
//
// Analog boundary ports:
//   adc_dac_out / adc_cmp  — SAR ADC trial DAC code and StrongARM result
//   inp_dac_addr/data/we   — R-2R activation input DAC
//   dac_addr/data/we       — R-2R weight DAC (unchanged from original)
//
module pcn_digital_top #(
    parameter N_ROWS  = 4,
    parameter N_COLS  = 8,
    parameter N_CELLS = N_ROWS * N_COLS,
    parameter CELL_AW = $clog2(N_CELLS)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] wb_addr_i,
    input  wire [31:0] wb_dat_i,
    input  wire  [3:0] wb_sel_i,
    input  wire        wb_we_i,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    output wire [31:0] wb_dat_o,
    output wire        wb_ack_o,
    output wire  [2:0] user_irq,    // [0]=load_done|temporal_done [1]=hebb_ovf [2]=sleep_ack
    output wire [31:0] la_data_out,
    output wire [15:0] dac_addr,    // weight DAC: cell address
    output wire  [7:0] dac_data,    // weight DAC: byte value
    output wire        dac_we,      // weight DAC: write strobe
    input  wire [N_ROWS-1:0] ierr,  // precision-gate error flags (one per row)
    output wire [N_ROWS-1:0] we_out,// Hebbian write enables (one per row)
    output wire        full_power,
    output wire        keep_alive,
    // SAR ADC analog boundary
    output wire  [7:0] adc_dac_out, // trial code to SAR reference DAC
    input  wire        adc_cmp,     // comparator result from StrongARM latch
    // Activation input DAC (inp_dac, R-2R, one per column)
    output wire [15:0] inp_dac_addr,
    output wire  [7:0] inp_dac_data,
    output wire        inp_dac_we
);
    // ── Internal signals ─────────────────────────────────────────────────────
    wire [15:0] cell_addr;
    wire  [7:0] weight_data;
    wire  [5:0] ctrl;
    wire [N_ROWS-1:0] hebb_mask;
    wire [N_ROWS-1:0] hebb_row_mask;
    wire [N_ROWS-1:0] eff_hebb_mask;   // hebb_mask & hebb_row_mask → hebb_ctrl
    wire [15:0] hebb_pw;
    wire  [3:0] status;
    wire  [7:0] sram_wdata, sram_rdata;
    wire        sram_we_wb;

    assign eff_hebb_mask = hebb_mask & hebb_row_mask;

    localparam VIRT_AW    = 3;
    localparam SRAM_AW    = CELL_AW + VIRT_AW;
    localparam SRAM_DEPTH = N_CELLS << VIRT_AW;  // N_CELLS * N_VIRT weight entries

    wire  [SRAM_AW-1:0] sram_addr_fsm;
    wire        start_load, load_all, rst_weights;
    wire        start_temporal;
    wire [VIRT_AW:0] n_virt_layers;
    wire        busy, ready, irq_load_done;
    wire        hebb_actv, irq_hebb_ovf;
    wire        sleep_ack, irq_sleep_ack;
    wire        irq_temporal_done;

    // ADC wires
    wire        adc_sample, adc_done;
    wire  [7:0] adc_data_w;

    // Activation SRAM wires — FSM path
    wire  [CELL_AW-1:0] act_addr_w;
    wire  [7:0]          act_wdata_w, act_rdata_w;
    wire                 act_we_w;

    // Activation SRAM wires — WB direct-access path (0x30)
    wire  [7:0] act_wb_wdata;
    wire        act_wb_we;

    // act_sram MUX: FSM owns when busy, WB drives when idle
    wire  [CELL_AW-1:0] act_addr_mux  = busy ? act_addr_w  : cell_addr[CELL_AW-1:0];
    wire  [7:0]          act_wdata_mux = busy ? act_wdata_w : act_wb_wdata;
    wire                 act_we_mux    = busy ? act_we_w    : act_wb_we;

    // inp_dac wires — FSM path (internal; MUXed below)
    wire [15:0] inp_dac_addr_fsm;
    wire  [7:0] inp_dac_data_fsm;
    wire        inp_dac_we_fsm;

    // inp_dac wires — WB direct-write path (0x2C)
    wire [15:0] inp_dac_wb_addr;
    wire  [7:0] inp_dac_wb_data;
    wire        inp_dac_wb_we;

    // inp_dac MUX: FSM owns when busy, WB drives when idle
    assign inp_dac_addr = busy ? inp_dac_addr_fsm : inp_dac_wb_addr;
    assign inp_dac_data = busy ? inp_dac_data_fsm : inp_dac_wb_data;
    assign inp_dac_we   = busy ? inp_dac_we_fsm   : inp_dac_wb_we;

    // start_adc_sweep from WB regs to FSM
    wire start_adc_sweep;

    // Current virtual layer index (debug visibility in la_data_out)
    wire  [VIRT_AW-1:0] virt_layer_idx;

    // Weight SRAM address: full SRAM_AW in temporal mode; WB access uses VL0
    wire  [SRAM_AW-1:0] sram_addr_mux = busy
        ? sram_addr_fsm
        : {{VIRT_AW{1'b0}}, cell_addr[CELL_AW-1:0]};

    assign status = {sleep_ack, hebb_actv, busy, ready};

    // ── Wishbone register file ───────────────────────────────────────────────
    pcn_wb_regs #(.N_ROWS(N_ROWS), .VIRT_AW(VIRT_AW)) u_regs (
        .clk            (clk),
        .rst_n          (rst_n),
        .wb_addr_i      (wb_addr_i),
        .wb_dat_i       (wb_dat_i),
        .wb_sel_i       (wb_sel_i),
        .wb_we_i        (wb_we_i),
        .wb_cyc_i       (wb_cyc_i),
        .wb_stb_i       (wb_stb_i),
        .wb_dat_o       (wb_dat_o),
        .wb_ack_o       (wb_ack_o),
        .weight_data    (weight_data),
        .cell_addr      (cell_addr),
        .ctrl           (ctrl),
        .hebb_mask      (hebb_mask),
        .hebb_pw        (hebb_pw),
        .status         (status),
        .sram_wdata     (sram_wdata),
        .sram_we        (sram_we_wb),
        .sram_rdata     (sram_rdata),
        .start_load     (start_load),
        .load_all       (load_all),
        .rst_weights    (rst_weights),
        .start_temporal  (start_temporal),
        .n_virt_layers   (n_virt_layers),
        .hebb_row_mask   (hebb_row_mask),
        .ierr_dig_i      (ierr),          // precision-gate flags → read-only WB register
        .start_adc_sweep (start_adc_sweep),
        .inp_dac_wb_data (inp_dac_wb_data),
        .inp_dac_wb_addr (inp_dac_wb_addr),
        .inp_dac_wb_we   (inp_dac_wb_we),
        .act_rdata_wb_i  (act_rdata_w),   // act_sram rdata (cell_addr pre-addressed when idle)
        .act_wb_wdata    (act_wb_wdata),
        .act_wb_we       (act_wb_we)
    );

    // ── Weight SRAM (SRAM_DEPTH entries, temporal VL tiles in upper address bits)
    sram_if #(.N_CELLS(SRAM_DEPTH)) u_sram (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (sram_addr_mux),
        .wdata (sram_wdata),
        .we    (sram_we_wb),
        .rdata (sram_rdata)
    );

    // ── SAR ADC ──────────────────────────────────────────────────────────────
    sar_adc #(.BITS(8)) u_adc (
        .clk     (clk),
        .rst_n   (rst_n),
        .sample  (adc_sample),
        .done    (adc_done),
        .data    (adc_data_w),
        .dac_out (adc_dac_out),
        .cmp     (adc_cmp)
    );

    // ── Activation SRAM (N_CELLS x 8-bit; synthesises to register file) ─────
    act_sram #(.DEPTH(N_CELLS)) u_act_sram (
        .clk   (clk),
        .addr  (act_addr_mux),
        .wdata (act_wdata_mux),
        .we    (act_we_mux),
        .rdata (act_rdata_w)
    );

    // ── Weight FSM ───────────────────────────────────────────────────────────
    weight_fsm #(.N_CELLS(N_CELLS)) u_wfsm (
        .clk              (clk),
        .rst_n            (rst_n),
        .start_load       (start_load),
        .load_all         (load_all),
        .rst_weights      (rst_weights),
        .cell_addr        (cell_addr),
        .weight_data      (weight_data),
        .hebb_pw          (hebb_pw),
        .sram_addr        (sram_addr_fsm),
        .sram_rdata       (sram_rdata),
        .dac_addr         (dac_addr),
        .dac_data         (dac_data),
        .dac_we           (dac_we),
        .busy             (busy),
        .ready            (ready),
        .irq_load_done    (irq_load_done),
        .start_temporal   (start_temporal),
        .start_adc_sweep  (start_adc_sweep),
        .n_virt_layers    (n_virt_layers),
        .adc_sample       (adc_sample),
        .adc_done         (adc_done),
        .adc_data         (adc_data_w),
        .act_addr         (act_addr_w),
        .act_wdata        (act_wdata_w),
        .act_we           (act_we_w),
        .act_rdata        (act_rdata_w),
        .inp_dac_addr     (inp_dac_addr_fsm),
        .inp_dac_data     (inp_dac_data_fsm),
        .inp_dac_we       (inp_dac_we_fsm),
        .virt_layer_idx   (virt_layer_idx),
        .irq_temporal_done(irq_temporal_done)
    );

    // ── Hebbian controller ───────────────────────────────────────────────────
    hebb_ctrl #(.N_ROWS(N_ROWS)) u_hebb (
        .clk         (clk),
        .rst_n       (rst_n),
        .hebb_en     (ctrl[2]),
        .hebb_mask   (eff_hebb_mask),   // static HEBB_MASK & firmware k-WTA HEBB_ROW_MASK
        .hebb_pw     (hebb_pw),
        .ierr        (ierr),
        .we_out      (we_out),
        .hebb_actv   (hebb_actv),
        .irq_hebb_ovf(irq_hebb_ovf)
    );

    // ── Power FSM ────────────────────────────────────────────────────────────
    power_fsm u_pwr (
        .clk          (clk),
        .rst_n        (rst_n),
        .sleep_req    (ctrl[3]),
        .busy         (busy),
        .full_power   (full_power),
        .keep_alive   (keep_alive),
        .sleep_ack    (sleep_ack),
        .irq_sleep_ack(irq_sleep_ack)
    );

    // ── IRQ outputs ──────────────────────────────────────────────────────────
    assign user_irq = {irq_sleep_ack, irq_hebb_ovf, irq_load_done | irq_temporal_done};

    // la_data_out: logic-analyser snapshot.
    // dac_addr[8:0] covers arrays up to 512 cells; virt_layer_idx[2:0] fills the gap.
    assign la_data_out = {
        we_out[3:0],          // [31:28] Hebbian enables  (first 4 rows)
        ierr[3:0],            // [27:24] prediction errors (first 4 rows)
        dac_addr[8:0],        // [23:15] current DAC cell address (lower 9 bits)
        virt_layer_idx,       // [14:12] current virtual layer index
        dac_data,             // [11:4]  current DAC weight value
        sleep_ack,            // [3]
        hebb_actv,            // [2]
        busy,                 // [1]
        ready                 // [0]
    };

endmodule
