// Blackbox stub for sky130_sram_1kbyte_1rw1r_8x1024_8 OpenRAM macro.
// Port list matches the LEF in sky130A/libs.ref/sky130_sram_macros/lef/.
// 8-bit wide, 1024-deep, 1-bit write mask (byte granularity = full word).
// Used during synthesis; macro placed as hard IP in PnR.

(* blackbox *)
module sky130_sram_1kbyte_1rw1r_8x1024_8 (
    input        clk0,
    input        csb0,
    input        web0,
    input        wmask0,    // 1-bit: covers all 8 data bits
    input  [9:0] addr0,
    input  [7:0] din0,
    output [7:0] dout0,
    input        clk1,
    input        csb1,
    input  [9:0] addr1,
    output [7:0] dout1
);
endmodule
