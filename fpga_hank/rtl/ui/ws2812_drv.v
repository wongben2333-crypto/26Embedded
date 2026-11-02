// ============================================================================
// Module Name: ws2812_drv
// Description: 单颗 WS2812B (板载 U15, FPGA 球位 J16) 驱动
//              - 每 50ms 自动重发一次当前颜色，无需握手信号
//              - 50MHz 时钟下的位时序：T0H=20clk(0.40us) T1H=40clk(0.80us)
//                位周期 62clk(1.24us)，复位低电平 ~50ms（远大于 50us 要求）
// 颜色格式: {G[7:0], R[7:0], B[7:0]}  （WS2812 是 GRB 顺序）
// ============================================================================

module ws2812_drv #(
    parameter CLK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [23:0] color,   // {G,R,B}
    output reg         dout
);

    localparam T0H  = 6'd20;        // 0.40us
    localparam T1H  = 6'd40;        // 0.80us
    localparam TBIT = 6'd62;        // 1.24us 位周期
    localparam integer REFRESH = CLK_HZ / 20;   // 50ms 刷新一次

    reg [23:0] shreg;          // 当前发送的 24bit
    reg [5:0]  bit_cnt;        // 剩余位数
    reg [5:0]  cyc;            // 位内计数
    reg [31:0] refresh_cnt;    // 刷新节拍
    reg        busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout        <= 1'b0;
            shreg       <= 24'd0;
            bit_cnt     <= 6'd0;
            cyc         <= 6'd0;
            refresh_cnt <= REFRESH - 1;   // 复位后立刻发一帧
            busy        <= 1'b0;
        end else if (!busy) begin
            dout <= 1'b0;
            if (refresh_cnt >= REFRESH - 1) begin
                refresh_cnt <= 32'd0;
                shreg       <= color;
                bit_cnt     <= 6'd24;
                cyc         <= 6'd0;
                busy        <= 1'b1;
            end else begin
                refresh_cnt <= refresh_cnt + 1'b1;
            end
        end else begin
            if (cyc < TBIT - 1) begin
                // 高位在前：1 -> T1H，0 -> T0H
                dout <= (cyc < (shreg[23] ? T1H : T0H));
                cyc  <= cyc + 1'b1;
            end else begin
                cyc  <= 6'd0;
                dout <= 1'b0;
                if (bit_cnt <= 6'd1) begin
                    busy        <= 1'b0;
                    refresh_cnt <= 32'd0;
                end else begin
                    shreg   <= {shreg[22:0], 1'b0};
                    bit_cnt <= bit_cnt - 1'b1;
                end
            end
        end
    end

endmodule
