// =============================================================================
//  uart_rx.v —— 115200 8N1 串口接收（中点采样 + 两级同步）
//
//  接口契约（Lead 固定，签名不可改）：
//      uart_rx #(CLK_HZ, BAUD)(clk, rst_n, rx, data[7:0], valid)
//      valid 为 **1 个 clk 的脉冲**；data 在 valid 同拍有效。
//
//  实现要点：
//   1. ★ 中点采样：检测到起始位下降沿后先等 **半个位周期** 再确认起始位，
//      之后每隔 **一个完整位周期** 采一次 → 采样点落在每位正中，抗抖动最好。
//      50 MHz / 115200 = 434.027… ⇒ DIV = 434，HALF = 217。
//   2. ★ rx 内部做两级同步（契约注释说"已两级同步"，此处再做一次是**幂等**的，
//      只多 2 个 clk 延迟 —— 相对 434 clk 的位周期可忽略；这样模块自包含，
//      即使顶层忘了同步也不会亚稳态）。
//   3. ★ 帧校验：停止位必须为 1 才输出 valid（噪声帧丢弃），避免把干扰当数据。
//   4. LSB first（标准 UART）。
// =============================================================================
`default_nettype none

module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,        // 串口接收线（本模块内部再做两级同步）
    output reg  [7:0] data,
    output reg        valid      // 1 个 clk 脉冲
);

    // 位周期（clk 数）：四舍五入，避免整除误差累积
    localparam integer DIV  = (CLK_HZ + (BAUD / 2)) / BAUD;   // 50e6/115200 -> 434
    localparam integer HALF = DIV / 2;                        // 217

    // ---------------------------------------------------------------- 两级同步
    reg rx_s1, rx_s2;
    always @(posedge clk) begin
        if (!rst_n) {rx_s2, rx_s1} <= 2'b11;
        else        {rx_s2, rx_s1} <= {rx_s1, rx};
    end
    wire rx_in = rx_s2;

    // ---------------------------------------------------------------- 状态机
    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_STOP  = 3'd3;

    reg  [2:0]  state;
    reg  [15:0] cnt;          // 位内计数（0 表示到采样点）
    reg  [2:0]  bitidx;
    reg  [7:0]  sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            cnt    <= 16'd0;
            bitidx <= 3'd0;
            sh     <= 8'd0;
            data   <= 8'd0;
            valid  <= 1'b0;
        end else begin
            valid <= 1'b0;                       // 默认：脉冲只维持 1 拍
            case (state)
                // 空闲：等起始位下降沿
                S_IDLE: begin
                    if (!rx_in) begin
                        state <= S_START;
                        cnt   <= HALF[15:0];     // 等半个位周期 → 起始位中点
                    end
                end

                // 起始位中点确认（防毛刺）
                S_START: begin
                    if (cnt == 16'd0) begin
                        if (!rx_in) begin
                            state  <= S_DATA;
                            bitidx <= 3'd0;
                            cnt    <= DIV[15:0] - 16'd1;
                        end else begin
                            state <= S_IDLE;     // 假起始（毛刺），退回
                        end
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                // 8 个数据位，LSB first，每位中点采样
                S_DATA: begin
                    if (cnt == 16'd0) begin
                        sh[bitidx] <= rx_in;
                        cnt        <= DIV[15:0] - 16'd1;
                        if (bitidx == 3'd7) state  <= S_STOP;
                        else                bitidx <= bitidx + 3'd1;
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                // 停止位中点：必须为 1 才认为这一帧有效
                S_STOP: begin
                    if (cnt == 16'd0) begin
                        if (rx_in) begin
                            data  <= sh;         // sh 已在数据位全部写齐
                            valid <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        cnt <= cnt - 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
