`default_nettype none
module power_fsm (
    input  wire clk,
    input  wire rst_n,
    input  wire sleep_req,
    input  wire busy,
    output reg  full_power,
    output reg  keep_alive,
    output reg  sleep_ack,
    output reg  irq_sleep_ack
);
    localparam RUN=3'd0, FLUSH=3'd1, SLEEP_PREP=3'd2, SLEEPING=3'd3, WAKE=3'd4;
    localparam WAKE_CYCLES = 10'd500;
    reg [2:0] state;
    reg [9:0] wake_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= RUN; full_power <= 1'b1; keep_alive <= 1'b1;
            sleep_ack <= 1'b0; irq_sleep_ack <= 1'b0; wake_cnt <= 10'h0;
        end else begin
            irq_sleep_ack <= 1'b0;
            case (state)
                RUN: begin
                    full_power <= 1'b1; keep_alive <= 1'b1; sleep_ack <= 1'b0;
                    if (sleep_req) state <= FLUSH;
                end
                FLUSH: begin
                    if (!busy) state <= SLEEP_PREP;
                end
                SLEEP_PREP: begin
                    full_power <= 1'b0; keep_alive <= 1'b1; state <= SLEEPING;
                end
                SLEEPING: begin
                    sleep_ack <= 1'b1; irq_sleep_ack <= 1'b1;
                    if (!sleep_req) begin state <= WAKE; wake_cnt <= WAKE_CYCLES; end
                end
                WAKE: begin
                    full_power <= 1'b1; sleep_ack <= 1'b0;
                    if (wake_cnt == 10'h0) state <= RUN;
                    else wake_cnt <= wake_cnt - 1'b1;
                end
                default: state <= RUN;
            endcase
        end
    end
endmodule
