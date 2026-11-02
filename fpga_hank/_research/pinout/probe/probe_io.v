// probe_io.v -- generated
`timescale 1ns/1ps
module probe_io (
    input  wire clk,
    output wire [13:0] o
);
    reg [7:0] cnt;
    always @(posedge clk) cnt <= cnt + 8'd1;
    assign o = {cnt, {6{1'b0}}} ^ {cnt, {6{1'b0}}};
endmodule