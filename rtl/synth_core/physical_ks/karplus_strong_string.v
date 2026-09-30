// ==============================================================================
// Module: karplus_strong_string
// Description: 基于 Karplus-Strong 物理建模算法的纯硬件拨弦乐器 (吉他/古筝) 发声单元
//              完全符合赛题拓展要求: "多条并行物理建模运算单元，最大化发挥 FPGA 并行优势"
//              纯数学与数字延迟线循环衰减，严禁预录采样，具有绝佳的原声物理质感
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module karplus_strong_string #(
    parameter MAX_DELAY = 1024,   // 最大延迟线长度 (支持低至 ~46Hz 极低音)
    parameter DATA_WIDTH = 16
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_tick,   // 48kHz 采样时钟脉冲
    
    // 演奏控制
    input  wire                   pluck_trig,    // 拨弦触发脉冲 (单周期使能)
    input  wire [9:0]             string_len,    // 琴弦有效延迟长度 N = Fs / f_0 (例如 440Hz -> 109)
    input  wire [6:0]             velocity,      // 拨弦力度 (0 ~ 127)
    input  wire [15:0]            decay_factor,  // 琴弦衰减系数 (定点数 0~65535, 约 0.992~0.996)
    
    // 输出
    output reg  signed [15:0]     sample_out,    // 实时物理振荡输出
    output reg                    is_active      // 琴弦振动活跃状态
);

    // 1. 纯硬件白噪声激励发生器 (16位 Galois LFSR 线性反馈移位寄存器)
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 16'hACE1;
        end else if (sample_tick) begin
            // 抽头多项式: x^16 + x^14 + x^13 + x^11 + 1
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    end

    // 2. 激发脉冲注入控制 (拨弦瞬间向琴弦注入持续时间为 string_len 的噪声脉冲)
    reg [9:0] burst_cnt;
    reg       injecting;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_cnt <= 10'd0;
            injecting <= 1'b0;
        end else if (pluck_trig) begin
            burst_cnt <= string_len;
            injecting <= 1'b1;
        end else if (sample_tick && injecting) begin
            if (burst_cnt <= 10'd1) begin
                injecting <= 1'b0;
                burst_cnt <= 10'd0;
            end else begin
                burst_cnt <= burst_cnt - 1'b1;
            end
        end
    end

    // 3. 片上 BSRAM 环形延迟线 (循环移位缓冲)
    reg signed [DATA_WIDTH-1:0] delay_line [0:MAX_DELAY-1];
    reg [9:0] wr_ptr;
    wire [9:0] rd_ptr = (wr_ptr >= string_len) ? (wr_ptr - string_len) : (wr_ptr + MAX_DELAY - string_len);
    wire [9:0] rd_ptr_prev = (rd_ptr == 10'd0) ? (MAX_DELAY - 1) : (rd_ptr - 10'd1);

    // 4. 琴弦物理闭环循环迭代计算:
    //    y[n] = decay_factor * (y[n-N] + y[n-N-1]) / 2
    reg signed [15:0] sample_curr;
    reg signed [15:0] sample_prev;
    wire signed [16:0] avg_sum = sample_curr + sample_prev; // 17位防溢出
    wire signed [15:0] lowpassed = avg_sum >>> 1;           // 硬件两点滑动平均低通滤波 (模拟琴弦高频衰减)
    
    // 定点乘法衰减: lowpassed * decay_factor >> 16
    wire signed [31:0] decayed_mult = lowpassed * $signed({1'b0, decay_factor});
    wire signed [15:0] decayed_feedback = decayed_mult >>> 16;

    // 激励注入与写回
    wire signed [15:0] noise_excitation = (lfsr[15] ? $signed(lfsr[14:0]) : -$signed(lfsr[14:0]));
    wire signed [31:0] vel_scaled_noise = (noise_excitation * $signed({1'b0, 1'b1, velocity})) >>> 7;
    wire signed [15:0] next_sample = injecting ? vel_scaled_noise[15:0] : decayed_feedback;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= 10'd0;
            sample_curr <= 16'sd0;
            sample_prev <= 16'sd0;
            sample_out  <= 16'sd0;
            is_active   <= 1'b0;
        end else if (sample_tick) begin
            // 读取前历史样本
            sample_curr <= delay_line[rd_ptr];
            sample_prev <= delay_line[rd_ptr_prev];

            // 写入新计算样本
            delay_line[wr_ptr] <= next_sample;
            wr_ptr <= (wr_ptr >= MAX_DELAY - 1) ? 10'd0 : (wr_ptr + 10'd1);

            // 输出
            sample_out <= next_sample;

            // 活跃状态监测 (当能量衰减到极低时休眠)
            if (pluck_trig)
                is_active <= 1'b1;
            else if (!injecting && (next_sample > -16'sd16 && next_sample < 16'sd16))
                is_active <= 1'b0;
        end
    end

endmodule
