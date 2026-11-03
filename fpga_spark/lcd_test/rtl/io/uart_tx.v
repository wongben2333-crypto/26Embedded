// =============================================================================
//  uart_tx.v -- minimal 8N1 UART transmitter
//
//  CLK_HZ / BAUD are parameters so the same file serves the 50 MHz board and a
//  fast simulation. 434 clocks per bit at 50 MHz / 115200 (error 0.007 %).
//
//  Handshake: pulse `start` for one clock while `busy` is low; `data` must be
//  valid on that clock.  `busy` rises on the next clock and falls after the
//  stop bit, so back-to-back bytes are allowed without gaps.
// =============================================================================
`default_nettype none

module uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output reg        busy,
    output reg        tx
);

    localparam integer DIV = CLK_HZ / BAUD;   // 434

    reg [15:0] cnt;
    reg [3:0]  bitn;
    reg [9:0]  sh;                            // {stop, data[7:0], start}

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            tx   <= 1'b1;
            cnt  <= 16'd0;
            bitn <= 4'd0;
            sh   <= 10'h3FF;
        end else if (!busy) begin
            tx <= 1'b1;
            if (start) begin
                sh   <= {1'b1, data, 1'b0};
                busy <= 1'b1;
                cnt  <= 16'd0;
                bitn <= 4'd0;
                tx   <= 1'b0;                 // start bit
            end
        end else begin
            if (cnt == DIV - 1) begin
                cnt <= 16'd0;
                if (bitn == 4'd9) begin
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    bitn <= bitn + 4'd1;
                    tx   <= sh[bitn + 4'd1];
                end
            end else begin
                cnt <= cnt + 16'd1;
            end
        end
    end

endmodule

`default_nettype wire
