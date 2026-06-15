`default_nettype none
// 8-bit successive-approximation ADC register.
//
// Interface contract with weight_fsm (ST_T_ASAVE state):
//   sample   — level signal; FSM holds HIGH from ST_T_ASAVE entry until
//              adc_done is observed, then transitions away.  The ADC
//              triggers on the RISING EDGE of sample to avoid re-triggering
//              during the one extra cycle sample stays high after done.
//   done     — one-cycle HIGH pulse, exactly BITS+1 clk cycles after the
//              rising edge of sample (1 cycle to latch + BITS CONV cycles).
//   data     — result code, held stable until the next conversion starts.
//
// Analog boundary (connects to SPICE circuit or testbench model):
//   dac_out  — current trial code, drives the SAR reference DAC/capacitor
//              array.  Changes at posedge clk; comparator must settle before
//              the next posedge for correct operation.
//   cmp      — comparator result: 1 = vin >= v_ref(dac_out).  In the
//              physical chip this is a StrongARM latch output latched at
//              posedge clk.
//
// Vref requirement (VREF_LO_MV / VREF_HI_MV parameters):
//   The SAR capacitor array reference must be tied to the same Vref_lo and
//   Vref_hi rails as inp_dac.spice.  With VREF_LO_MV=400 and VREF_HI_MV=1400:
//
//       v_ref(code) = 0.4 + code/255 × 1.0 V
//
//   This ensures code 128 maps to Vcm = 0.9 V on both ADC and DAC sides,
//   making the temporal round-trip (V_row → ADC → SRAM → DAC → V_col_next)
//   an identity within ±0.5 LSB = ±1.96 mV.
//
//   If the ADC Vref were instead 0–1.8 V (full VDD range), code 128 would
//   map to 0.9 V on the ADC side but to 0.902 V on the DAC side, introducing
//   a systematic 2 mV offset; and signals near Vref_hi=1.4 V would clip to
//   ADC code 198 → DAC 1.176 V instead of 1.4 V (a 224 mV error).
//
//   Physical wiring: connect the SAR capacitor array bottom-plate reference to
//   Vref_inp_lo (= DAC_VMIN = 0.4 V) and top-plate reference to
//   Vref_inp_hi (= DAC_VMAX = 1.4 V).  These are the same pins used by
//   inp_dac.spice as its R-2R supply rails.
//
// Conversion sequence (bidx = BITS-1 downto 0, one cycle each):
//   IDLE → (sample_rise) → set dac_out = 0x80 (MSB trial), go to CONV
//   CONV: capture cmp for previous dac_out, update SAR register, advance
//         bidx.  On final bit (bidx=0): latch data, assert done, go to IDLE.
//
// Verified codes (voltage-domain comparator in tb_sar_adc, T0–T10):
//   400 mV→0x00, 678 mV→0x47, 902 mV→0x80, 1153 mV→0xC0, 1400 mV→0xFF.

module sar_adc #(
    parameter BITS       = 8,
    // Analog reference range — must match inp_dac Vref rails (millivolts).
    // These parameters are not used in the digital logic; they exist to
    // document the required wiring and allow testbenches to read them via
    // hierarchical reference (e.g. dut.VREF_LO_MV).
    parameter VREF_LO_MV = 400,   // lower reference = inp_dac Vref_lo (mV)
    parameter VREF_HI_MV = 1400   // upper reference = inp_dac Vref_hi (mV)
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             sample,          // level: held high by FSM while waiting
    output reg              done,            // one-cycle pulse: data valid
    output reg  [BITS-1:0]  data,            // result, held until next conversion
    output reg  [BITS-1:0]  dac_out,         // trial code to SAR reference DAC
    input  wire             cmp              // 1 = vin >= v_ref(dac_out)
);
    localparam IDX_W         = $clog2(BITS);
    localparam [BITS-1:0] ONE = {{(BITS-1){1'b0}}, 1'b1};

    localparam IDLE = 1'b0, CONV = 1'b1;

    reg             state;
    reg [BITS-1:0]  sar;
    reg [IDX_W-1:0] bidx;
    reg             sample_r;           // previous-cycle sample for rising-edge detect

    wire sample_rise = sample & ~sample_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= IDLE;
            sar      <= {BITS{1'b0}};
            bidx     <= {IDX_W{1'b0}};
            dac_out  <= {BITS{1'b0}};
            done     <= 1'b0;
            data     <= {BITS{1'b0}};
            sample_r <= 1'b0;
        end else begin
            sample_r <= sample;
            done     <= 1'b0;

            case (state)

                IDLE: begin
                    if (sample_rise) begin
                        sar     <= {BITS{1'b0}};
                        bidx    <= BITS - 1;
                        dac_out <= ONE << (BITS - 1);    // MSB trial
                        state   <= CONV;
                    end
                end

                CONV: begin
                    // Capture comparator result for the trial presented last cycle.
                    // Non-blocking: sar_old is read in the RHS expressions below.
                    if (cmp) sar[bidx] <= 1'b1;

                    if (bidx == {IDX_W{1'b0}}) begin
                        // Final bit: latch result (include current bit via sar_old | ONE)
                        data    <= cmp ? (sar | ONE) : sar;
                        done    <= 1'b1;
                        dac_out <= {BITS{1'b0}};
                        state   <= IDLE;
                    end else begin
                        bidx    <= bidx - 1'b1;
                        // Next trial = accumulated SAR (including this bit) | next trial bit
                        dac_out <= (cmp ? (sar | (ONE << bidx)) : sar)
                                 | (ONE << (bidx - 1'b1));
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
