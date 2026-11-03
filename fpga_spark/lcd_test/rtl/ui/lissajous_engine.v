// =============================================================================
// lissajous_engine.v —— 纯硬件 128x128 矢量双通道李萨如相位轨迹仪 (Lissajous Orbit)
//
// 赛题【拓展③】明确要求「李萨如图形、实时频谱、波形显示等视听效果」。
//
// 物理机理：
//   将音频左声道作为 X 坐标偏转、右声道作为 Y 坐标偏转（True Stereo X-Y 模式）。
//   单声道干声时，X=Y 呈现经典 45° 线性相位轴；
//   开启立体声合唱（Chorus 90° 正交）时，相位差展开为动态呼吸旋转的椭圆与花瓣网格；
//   开启乒乓延迟或混响时，呈现华丽的空间立体声星云轨迹；
//   测试模式 32 谱峰齐响时，呈现精密繁复的多频谐波几何晶格。
//
// 架构：
//   利用 1 块 18K BSRAM (16384 x 1 bit SDPB) 模拟示波管余辉荧光存储屏。
//   音频 sample_tick 实时打点写入，视频逐行扫描读取，帧起始高速清屏。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module lissajous_engine (
    input  wire               clk,           // 50 MHz
    input  wire               rst_n,
    input  wire               sample_tick,   // 97,656.25 Hz
    input  wire               frame_start,   // 帧起始同步脉冲 (py == 0)
    input  wire signed [15:0] sample_l,      // X 轴偏转信号
    input  wire signed [15:0] sample_r,      // Y 轴偏转信号
    input  wire [9:0]         px,            // 800x480 当前列
    input  wire [8:0]         py,            // 800x480 当前行
    output wire               box_area,      // 李萨如面板边框区域
    output wire               border_line,   // 面板边框线
    output wire               reticle_line,  // 同心圆刻度与正交中心十字线
    output wire               trace_dot      // 真实李萨如发光光迹
);

    // 面板视窗坐标：宽度 300 px (460..760)，高度 176 px (64..240)，中心 (610, 152)
    localparam [9:0] X_MIN = 10'd460;
    localparam [9:0] X_MAX = 10'd760;
    localparam [8:0] Y_MIN = 9'd64;
    localparam [8:0] Y_MAX = 9'd240;
    localparam [9:0] X_CTR = 10'd610;
    localparam [8:0] Y_CTR = 9'd152;

    assign box_area = (px >= X_MIN && px <= X_MAX && py >= Y_MIN && py <= Y_MAX);
    assign border_line = (box_area && (px == X_MIN || px == X_MAX || py == Y_MIN || py == Y_MAX));

    // 刻度线：中心十字线 (X=610 或 Y=152) 与网格虚线
    wire is_cross_x = (px == X_CTR && py >= Y_MIN + 9'd8 && py <= Y_MAX - 9'd8 && py[2:0] != 3'd0);
    wire is_cross_y = (py == Y_CTR && px >= X_MIN + 10'd8 && px <= X_MAX - 10'd8 && px[2:0] != 3'd0);

    // 同心圆刻度 (R ≈ 32 与 R ≈ 64)
    wire signed [10:0] dx_c = $signed({1'b0, px}) - $signed({1'b0, X_CTR});
    wire signed [9:0]  dy_c = $signed({1'b0, py}) - $signed({1'b0, Y_CTR});
    wire [20:0] r2 = dx_c * dx_c + dy_c * dy_c;
    wire is_circle_32 = (r2 >= 21'd960  && r2 <= 21'd1090) && (px[1] ^ py[1]);
    wire is_circle_64 = (r2 >= 21'd4000 && r2 <= 21'd4220) && (px[2] ^ py[2]);

    assign reticle_line = box_area && (is_cross_x || is_cross_y || is_circle_32 || is_circle_64);

    // -------------------------------------------------------------------------
    // 128x128 荧光存储 RAM (16384 bits = 1 块 18K BSRAM)
    // -------------------------------------------------------------------------
    // 打点坐标换算 (0..127，中心 64)
    // sample_l / 512 映射到 ±63
    wire signed [6:0] dot_x_rel = sample_l[15:9];
    wire signed [6:0] dot_y_rel = sample_r[15:9];
    wire [6:0] dot_x = 7'd64 + dot_x_rel;
    wire [6:0] dot_y = 7'd64 - dot_y_rel; // Y 轴反转 (向上为正)
    wire [13:0] wr_addr = {dot_y, dot_x};

    // 清屏 FSM：每当 frame_start 时，高速扫写 16384 个地址为 0
    reg        clearing = 1'b0;
    reg [13:0] clr_cnt  = 14'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            clearing <= 1'b1;
            clr_cnt  <= 14'd0;
        end else if (frame_start) begin
            clearing <= 1'b1;
            clr_cnt  <= 14'd0;
        end else if (clearing) begin
            if (clr_cnt == 14'd16383) clearing <= 1'b0;
            else clr_cnt <= clr_cnt + 14'd1;
        end
    end

    // 显示扫描读地址
    // 仅在中心 128x128 区域 (px: 610-64..610+63, py: 152-64..152+63)
    wire in_beam_zone = (px >= X_CTR - 10'd64 && px <= X_CTR + 10'd63 &&
                         py >= Y_CTR - 9'd64  && py <= Y_CTR + 9'd63);
    wire [6:0] rd_x = (px - (X_CTR - 10'd64));
    wire [6:0] rd_y = (py - (Y_CTR - 9'd64));
    wire [13:0] rd_addr = {rd_y, rd_x};

    // 16384 x 1 bit SDPB RAM
    (* ram_style = "block" *) reg mem [0:16383];

    reg beam_dot_q;
    always @(posedge clk) begin
        // 写端口：清屏优先，否则按 sample_tick 写入轨迹点
        if (clearing) begin
            mem[clr_cnt] <= 1'b0;
        end else if (sample_tick) begin
            mem[wr_addr] <= 1'b1;
        end

        // 读端口：实时读出当前像素是否命中轨迹
        beam_dot_q <= mem[rd_addr];
    end

    assign trace_dot = in_beam_zone && beam_dot_q && !clearing;

endmodule
`default_nettype wire
