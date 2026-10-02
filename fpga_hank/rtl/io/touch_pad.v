// =============================================================================
//  touch_pad.v —— 电容触摸检测（RC 充放电时间测量法）
//
//  原理（赛题点名的四类交互方案之一）：
//    电极片 + 约 1 MΩ 上拉。一个测量周期分三步：
//      1) DISCHARGE：把 IO 驱低一段固定时间，把电极电容放干净
//      2) RELEASE  ：IO 切成高阻（inout 且 drive 0），电容经上拉电阻充电
//      3) MEASURE  ：数有多少个 clk 才充到逻辑 1
//    手指靠近 → 电极对地电容增大 → 充电变慢 → 计数值变大
//    ★ 关键：这是【相对变化】测量，绝对计数值随温度/湿度/元件漂移，
//      所以必须用"基线 + 阈值"判按，而不是固定阈值。
//
//  抗干扰（赛题要求"交互逻辑灵敏稳定，现场演示不能乱响"）：
//    · 基线自适应：未按下时缓慢跟踪计数值，抵消环境漂移
//    · 迟滞：按下/松开的阈值不同，避免在阈值附近抖动
//    · 去抖计数：连续 N 次超过阈值才算真按下，连续 M 次低于才算松开
//
//  ⚠️ 引脚选择：必须用真正的 GPIO（PMOD / 40P 排针）。
//     本项目用 Sipeed 板级约束 pmod_led 里验证过的 PMOD 引脚：
//       P19 R19 T21 U21 Y21 Y22 AB21 AB22 AA20 AA21 AA19 AB20 R17 R18 T18 P16
//     （T18/R18/R17/P16 与板载 LED 复用，做触摸时不要同时当 LED 用。）
//
//  典型用法：把 8 个电极接到 8 个 GPIO，每个 GPIO 一个本模块实例，
//            再用 touch_scan.v 汇总成"按了哪个键"。
// =============================================================================
`default_nettype none

module touch_pad #(
    // 放电时间（clk 数）。足够长以放净电极电容，又不至于让扫描变慢。
    parameter integer DISCHARGE_CLKS = 512,
    // 单次测量的最大等待 clk 数。超时视为"始终为 1"（电极短路/未接），
    // 上报 max 值而不是挂死。
    parameter integer MEASURE_MAX    = 4096,
    // 基线跟踪：每次测量后基线向当前值靠拢的右移位数。
    // 值越大基线越稳、越慢跟随；6 ≈ 1/64 的跟随速度。
    parameter integer BASE_SH        = 6,
    // 按下阈值：当前值 > 基线 + THRESH 视为触摸
    parameter integer THRESH         = 24,
    // 迟滞：松开阈值比按下阈值低 HYST，避免抖动
    parameter integer HYST           = 8,
    // 去抖：连续 PRESS_N 次超阈值才报按下；连续 RELEASE_N 次低于才报松开
    parameter integer PRESS_N        = 3,
    parameter integer RELEASE_N      = 4,
    // 计数值位宽
    parameter integer CNT_W          = 13
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,        // 单拍脉冲：启动一次测量
    // ★ 电极接口：拆成"输出使能 + 输出值 + 输入"三个显式信号，
    //   而不是一个 inout。这样验证环境可以直接充当电极模型，
    //   不需要用 Verilog 强度裁决去模拟三态 —— 本项目在这上面踩过坑：
    //   模型用 `pad === 1'b0` 判断"DUT 是否在驱动"，而模型自己的弱下拉
    //   也让节点为 0，于是模型永远以为 DUT 还在放电，形成死锁（测量全超时）。
    output wire                pad_oe,       // 1 = 本模块驱动电极
    output wire                pad_out,      // 驱动值（放电阶段为 0）
    input  wire                pad_in,       // 电极电平（读回）
    output reg                 touch,        // 去抖后的触摸状态
    output reg  [CNT_W-1:0]    value,        // 本次测量计数值
    output reg  [CNT_W-1:0]    baseline,     // 当前基线
    output reg                 busy
);

    // ---------------------------------------------------------------- 状态 ---
    localparam [1:0] S_IDLE  = 2'd0,
                     S_DISCH = 2'd1,
                     S_WAIT  = 2'd2,
                     S_DONE  = 2'd3;

    reg [1:0]          st;
    reg [15:0]         wait_cnt;
    reg [CNT_W-1:0]    meas;
    reg                drive_low;      // 1 = 驱动 0，0 = 高阻

    // 电极驱动：drive_low 时驱动 0，否则释放（高阻）由外部上拉充电
    assign pad_oe  = drive_low;
    assign pad_out = 1'b0;

    // 顶层把这三个信号接到一个 IOBUF / inout 端口：
    //   assign pad = pad_oe ? pad_out : 1'bz;
    //   assign pad_in = pad;

    // 去抖计数
    reg [3:0] press_cnt;
    reg [3:0] rel_cnt;

    // 基线寄存器（CNT_W 位无符号）
    wire [CNT_W-1:0] base_plus  = baseline + THRESH[CNT_W-1:0];
    wire [CNT_W-1:0] base_minus = baseline - HYST[CNT_W-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            wait_cnt  <= 16'd0;
            meas      <= {CNT_W{1'b0}};
            drive_low <= 1'b0;
            busy      <= 1'b0;
            touch     <= 1'b0;
            value     <= {CNT_W{1'b0}};
            baseline  <= {CNT_W{1'b0}};
            press_cnt <= 4'd0;
            rel_cnt   <= 4'd0;
        end else begin
            case (st)
                // ---------------- 空闲：等 start ----------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        st        <= S_DISCH;
                        busy      <= 1'b1;
                        wait_cnt  <= 16'd0;
                        drive_low <= 1'b1;      // 开始放电
                    end
                end

                // ---------------- 放电 ----------------
                S_DISCH: begin
                    if (wait_cnt >= DISCHARGE_CLKS[15:0] - 16'd1) begin
                        drive_low <= 1'b0;      // 切高阻，开始充电
                        meas      <= {CNT_W{1'b0}};
                        wait_cnt  <= 16'd0;
                        st        <= S_WAIT;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                // ---------------- 测量充电时间 ----------------
                // ★ 用非阻塞采样 pad：pad 是外部信号，需要同步化。
                //   这里每个 clk 采一次，计到出现 1 或超时为止。
                S_WAIT: begin
                    if (pad_in === 1'b1) begin
                        value <= meas;
                        st    <= S_DONE;
                    end else if (wait_cnt >= MEASURE_MAX[15:0] - 16'd1) begin
                        // 超时：上报最大值，不挂死
                        value <= {CNT_W{1'b1}};
                        st    <= S_DONE;
                    end else begin
                        meas     <= meas + {{(CNT_W-1){1'b0}}, 1'b1};
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                // ---------------- 收尾：更新基线 + 去抖 ----------------
                S_DONE: begin
                    busy <= 1'b0;

                    // 基线自适应：只在"未按下"时跟踪，否则按下会把基线拉高
                    // 而"自己学会"忽略这次触摸。
                    if (!touch) begin
                        // baseline += (value - baseline) >> BASE_SH
                        // 用 (value - baseline) 的有符号处理，避免下溢
                        if (value > baseline)
                            baseline <= baseline + ((value - baseline) >> BASE_SH);
                        else if (value < baseline)
                            baseline <= baseline - ((baseline - value) >> BASE_SH);
                    end

                    // 去抖：按下需要连续 PRESS_N 次，松开需要连续 RELEASE_N 次
                    if (!touch) begin
                        if (value > base_plus) begin
                            if (press_cnt >= PRESS_N[3:0] - 4'd1) begin
                                touch     <= 1'b1;
                                press_cnt <= 4'd0;
                            end else begin
                                press_cnt <= press_cnt + 4'd1;
                            end
                        end else begin
                            press_cnt <= 4'd0;
                        end
                    end else begin
                        if (value < base_minus) begin
                            if (rel_cnt >= RELEASE_N[3:0] - 4'd1) begin
                                touch   <= 1'b0;
                                rel_cnt <= 4'd0;
                            end else begin
                                rel_cnt <= rel_cnt + 4'd1;
                            end
                        end else begin
                            rel_cnt <= 4'd0;
                        end
                    end

                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
