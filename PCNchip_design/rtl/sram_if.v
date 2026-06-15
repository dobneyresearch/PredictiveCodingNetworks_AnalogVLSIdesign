`default_nettype none
// Parameterisable weight SRAM wrapper.
//
// N_CELLS  sets the required weight storage depth (one byte per cell).
// TILE_DEPTH is the depth of one physical macro — a PDK constant, not a design
// parameter.  N_TILES = ceil(N_CELLS / TILE_DEPTH) macros are instantiated and
// addressed transparently.  The interface to the rest of the design is unchanged.
//
// Scaling table for sky130 (TILE_DEPTH=1024, sky130_sram_1kbyte_1rw1r_8x1024_8):
//   N_CELLS  <= 1024 → N_TILES=1  (addr[9:0])
//   N_CELLS  <= 2048 → N_TILES=2  (addr[10] selects tile, addr[9:0] within)
//   N_CELLS  <= 4096 → N_TILES=4  (addr[11:10] selects tile, addr[9:0] within)
//
// To port to a different PDK: change TILE_DEPTH and the macro name inside
// `ifdef SYNTHESIS.  Simulation model, interface, and rest of design are unchanged.
//
module sram_if #(
    parameter N_CELLS    = 32,
    parameter TILE_DEPTH = 1024,                                     // entries per sky130_sram_1kbyte_1rw1r_8x1024_8
    parameter CELL_AW    = $clog2(N_CELLS),
    parameter TILE_AW    = $clog2(TILE_DEPTH),                       // 7 for 128-entry macro
    parameter N_TILES    = (N_CELLS + TILE_DEPTH - 1) / TILE_DEPTH   // ceil(N_CELLS/TILE_DEPTH)
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire  [CELL_AW-1:0] addr,
    input  wire          [7:0] wdata,
    input  wire                we,
    output wire          [7:0] rdata
);

`ifdef SYNTHESIS
    // ─── Address decomposition ────────────────────────────────────────────────
    // AEXT is at least TILE_AW+1 so that addr_x[AEXT-1:TILE_AW] is never an
    // empty range regardless of the relationship between CELL_AW and TILE_AW.
    localparam AEXT  = (CELL_AW > TILE_AW) ? CELL_AW : TILE_AW + 1;
    localparam SEL_W = AEXT - TILE_AW;              // bits for tile index (>=1)

    wire  [AEXT-1:0]    addr_x    = addr;            // zero-extends addr
    wire  [TILE_AW-1:0] tile_addr = addr_x[TILE_AW-1:0];  // within-tile address
    wire  [SEL_W-1:0]   tile_sel  = addr_x[AEXT-1:TILE_AW]; // tile index (0 when N_TILES=1)

    // ─── Physical macro instances ─────────────────────────────────────────────
    wire [7:0] tile_dout [0:N_TILES-1];

    genvar t;
    generate for (t = 0; t < N_TILES; t = t + 1) begin : g_tile
        // Active-low chip select: deassert all tiles except the addressed one.
        wire cs_n = (tile_sel != t);

        sky130_sram_1kbyte_1rw1r_8x1024_8 u_sram (
            .clk0  (clk),
            .csb0  (cs_n),
            .web0  (~we),
            .wmask0(1'b1),      // always enable all 8 data bits
            .addr0 (tile_addr),
            .din0  (wdata),
            .dout0 (tile_dout[t]),
            .clk1  (clk),
            .csb1  (1'b1),
            .addr1 (10'h0),
            .dout1 ()
        );
    end endgenerate

    // ─── Read-data mux ────────────────────────────────────────────────────────
    // Register tile_sel by one cycle to align with the SRAM's synchronous read
    // latency: the macro presents valid dout0 the cycle after csb0 is asserted.
    reg [SEL_W-1:0] sel_r;
    always @(posedge clk) sel_r <= tile_sel;

    assign rdata = tile_dout[sel_r];

`else
    // ─── Simulation model ─────────────────────────────────────────────────────
    // Generic reg array: scales to any N_CELLS, process-independent.
    // Initialises all weights to 0x80 (mid-scale = zero-weight operating point).
    reg [7:0] mem [0:N_CELLS-1];
    reg [7:0] rdata_r;
    integer ii;
    initial begin
        for (ii = 0; ii < N_CELLS; ii = ii + 1) mem[ii] = 8'h80;
    end
    always @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata_r <= mem[addr];
    end
    assign rdata = rdata_r;
`endif

endmodule
