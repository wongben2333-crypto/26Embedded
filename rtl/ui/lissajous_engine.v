// =============================================================================
// lissajous_engine.v —— 纯硬件 128x128 矢量双通道李萨如相位轨迹仪 (BSRAM 零逻辑膨胀版)
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

    assign box_area    = (px >= X_MIN && px <= X_MAX && py >= Y_MIN && py <= Y_MAX);
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
    // 1. 正交移相网络 (128x16 BSRAM 环形延迟线 + 一阶高通谐波差分)
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) reg signed [15:0] delay_ram [0:127];
    reg  [6:0]         dly_wr_ptr = 7'd0;
    wire [6:0]         dly_rd_ptr = dly_wr_ptr - 7'd92;
    reg  signed [15:0] tap_92     = 16'sd0;
    reg  signed [15:0] lp_sig     = 16'sd0;

    always @(posedge clk) begin
        if (sample_tick) begin
            delay_ram[dly_wr_ptr] <= sample_l;
            tap_92                <= delay_ram[dly_rd_ptr];
            dly_wr_ptr            <= dly_wr_ptr + 7'd1;
            lp_sig                <= lp_sig + ((sample_l - lp_sig) >>> 3);
        end
    end

    wire signed [16:0] hp_diff   = $signed({sample_l[15], sample_l}) - $signed({lp_sig[15], lp_sig});
    wire signed [16:0] stereo_df = $signed({sample_r[15], sample_r}) - $signed({sample_l[15], sample_l});
    wire signed [17:0] quad_y    = $signed({{2{tap_92[15]}}, tap_92}) +
                                   $signed({hp_diff[16], hp_diff >>> 1}) +
                                   $signed({stereo_df[16], stereo_df});

    // 高灵敏度缩放 (>>> 6 放大 8 倍，配合 ±58 px 限幅)
    wire signed [10:0] raw_dx = sample_l[15:6];
    wire signed [11:0] raw_dy = quad_y[17:6];

    wire signed [7:0] clamped_dx = (raw_dx > 11'sd58)  ?  8'sd58 :
                                   (raw_dx < -11'sd58) ? -8'sd58 : raw_dx[7:0];
    wire signed [7:0] clamped_dy = (raw_dy > 12'sd58)  ?  8'sd58 :
                                   (raw_dy < -12'sd58) ? -8'sd58 : raw_dy[7:0];

    wire [6:0] target_x = 7'd64 + clamped_dx[6:0];
    wire [6:0] target_y = 7'd64 - clamped_dy[6:0];

    // -------------------------------------------------------------------------
    // 2. 无乘法器 8 步连线插值器 + 单端口写入 16384x1 BSRAM
    // -------------------------------------------------------------------------
    reg        frame_div = 1'b0;
    reg        clearing  = 1'b0;
    reg [13:0] clr_cnt   = 14'd0;

    // 10.3 定点累加坐标，无任何乘法器，8 步平滑连线 + 双像素加粗
    reg [6:0]  prev_x    = 7'd64;
    reg [6:0]  prev_y    = 7'd64;
    reg [9:0]  acc_x     = {7'd64, 3'd0};
    reg [9:0]  acc_y     = {7'd64, 3'd0};
    reg signed [7:0] step_dx = 8'sd0;
    reg signed [7:0] step_dy = 8'sd0;
    reg [3:0]  interp_cnt = 4'd0;
    reg        plot_en    = 1'b0;

    wire [6:0] cur_px_x = acc_x[9:3] + (interp_cnt[0] && (acc_x[9:3] < 7'd127) ? 7'd1 : 7'd0);
    wire [6:0] cur_px_y = acc_y[9:3];
    wire [13:0] wr_addr = {cur_px_y, cur_px_x};

    always @(posedge clk) begin
        if (!rst_n) begin
            frame_div  <= 1'b0;
            clearing   <= 1'b1;
            clr_cnt    <= 14'd0;
            prev_x     <= 7'd64;
            prev_y     <= 7'd64;
            acc_x      <= {7'd64, 3'd0};
            acc_y      <= {7'd64, 3'd0};
            step_dx    <= 8'sd0;
            step_dy    <= 8'sd0;
            interp_cnt <= 4'd0;
            plot_en    <= 1'b0;
        end else begin
            if (frame_start) begin
                frame_div <= ~frame_div;
                if (frame_div) begin
                    clearing <= 1'b1;
                    clr_cnt  <= 14'd0;
                end
            end else if (clearing) begin
                if (clr_cnt == 14'd16383) clearing <= 1'b0;
                else clr_cnt <= clr_cnt + 14'd1;
            end

            if (sample_tick) begin
                acc_x      <= {prev_x, 3'd0};
                acc_y      <= {prev_y, 3'd0};
                step_dx    <= $signed({1'b0, target_x}) - $signed({1'b0, prev_x});
                step_dy    <= $signed({1'b0, target_y}) - $signed({1'b0, prev_y});
                prev_x     <= target_x;
                prev_y     <= target_y;
                interp_cnt <= 4'd0;
                plot_en    <= 1'b1;
            end else if (plot_en) begin
                if (interp_cnt[0] == 1'b1) begin
                    acc_x <= $signed({1'b0, acc_x}) + $signed({{3{step_dx[7]}}, step_dx});
                    acc_y <= $signed({1'b0, acc_y}) + $signed({{3{step_dy[7]}}, step_dy});
                end
                if (interp_cnt == 4'd15)
                    plot_en <= 1'b0;
                else
                    interp_cnt <= interp_cnt + 4'd1;
            end
        end
    end

    // 显示扫描读地址：中心 128x128 区域 (px: 610-64..610+63, py: 152-64..152+63)
    wire in_beam_zone = (px >= X_CTR - 10'd64 && px <= X_CTR + 10'd63 &&
                         py >= Y_CTR - 9'd64  && py <= Y_CTR + 9'd63);
    wire [6:0] rd_x = (px - (X_CTR - 10'd64));
    wire [6:0] rd_y = (py - (Y_CTR - 9'd64));
    wire [13:0] rd_addr = {rd_y, rd_x};

    // 16384 x 1 bit SDPB BSRAM (零 LUT 消耗)
    (* ram_style = "block" *) reg mem [0:16383];

    reg beam_dot_q;
    always @(posedge clk) begin
        if (clearing) begin
            mem[clr_cnt] <= 1'b0;
        end else if (plot_en) begin
            mem[wr_addr] <= 1'b1;
        end
        beam_dot_q <= mem[rd_addr];
    end

    assign trace_dot = in_beam_zone && beam_dot_q && !clearing;

endmodule
`default_nettype wire
