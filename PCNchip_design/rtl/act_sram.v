`default_nettype none
// Activation SRAM: N_CELLS x 8-bit synchronous-read register memory.
// Synchronous read (rdata registered on posedge clk) — weight_fsm pre-addresses
// by one cycle before reading, consistent with this latency.
// Write-and-read in the same cycle returns the old value (read-before-write).
// The weight_fsm never reads and writes the same address in the same cycle:
// the activation save and load phases are strictly sequential.
module act_sram #(
    parameter DEPTH = 32,
    parameter AW    = $clog2(DEPTH)
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,
    input  wire    [7:0] wdata,
    input  wire          we,
    output reg     [7:0] rdata
);
    reg [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[addr] <= wdata;
        rdata <= mem[addr];
    end
endmodule
