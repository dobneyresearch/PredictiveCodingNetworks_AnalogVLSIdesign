`default_nettype none
// One Hebbian pulse controller per output row.
// When ierr[r] fires, a pulse of duration hebb_pw clocks drives we_out[r] HIGH,
// enabling all N_COLS cells in that row to update their weights simultaneously.
module hebb_ctrl #(
    parameter N_ROWS = 4   // number of output rows (= ierr/we_out width)
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             hebb_en,
    input  wire [N_ROWS-1:0] hebb_mask,
    input  wire [15:0]      hebb_pw,
    input  wire [N_ROWS-1:0] ierr,
    output reg  [N_ROWS-1:0] we_out,
    output reg              hebb_actv,
    output reg              irq_hebb_ovf
);
    reg [15:0] cnt [0:N_ROWS-1];
    reg [N_ROWS-1:0] running;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            we_out <= {N_ROWS{1'b0}}; hebb_actv <= 1'b0; irq_hebb_ovf <= 1'b0;
            running <= {N_ROWS{1'b0}};
            for (i = 0; i < N_ROWS; i = i + 1) cnt[i] <= 16'h0;
        end else begin
            irq_hebb_ovf <= 1'b0;
            for (i = 0; i < N_ROWS; i = i + 1) begin
                if (!hebb_en || !hebb_mask[i]) begin
                    cnt[i] <= 16'h0; running[i] <= 1'b0; we_out[i] <= 1'b0;
                end else if (ierr[i] && !running[i]) begin
                    cnt[i] <= hebb_pw; running[i] <= 1'b1; we_out[i] <= 1'b1;
                end else if (running[i]) begin
                    if (cnt[i] == 16'h0) begin
                        running[i] <= 1'b0; we_out[i] <= 1'b0;
                        if (ierr[i]) irq_hebb_ovf <= 1'b1;
                    end else begin
                        cnt[i] <= cnt[i] - 1'b1;
                    end
                end
            end
            hebb_actv <= |running;
        end
    end
endmodule
