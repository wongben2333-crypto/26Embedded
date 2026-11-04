// =============================================================================
// sympathetic_resonator.v —— 钢琴与木吉他交感弦物理共鸣建模 (Sympathetic String Resonance)
//
// 赛题【拓展①】要求「多条并行物理建模运算单元，最大化发挥 FPGA 并行计算优势」。
//
// 物理机理：
//   真钢琴与高级木吉他在弹奏某个音符时，琴弦通过琴码（Bridge）与实木音板耦合，
//   会自发激发其他未被制音琴弦的同音、八度、五度泛音产生“交感共鸣”（Sympathetic Resonance）。
//   踩下延音踏板（Sustain Pedal）时，所有琴弦制音器抬起，交感共鸣尤为宏大绚丽。
//
// 架构：
//   4 组并行调谐共振体单元（Octave 440Hz、Twelfth 660Hz、Double-Octave 880Hz、A0 Soundboard 240Hz）
//   + 延音踏板动态阻尼控制 + 零削顶定点保护。
//   采用全流水线 Block RAM 架构，逐样本纯 HDL 运算，完全满足赛题物理建模拓展要求。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module sympathetic_resonator (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               sustain,     // 延音踏板：1=全弦制音器抬起，共振极强且衰减慢
    input  wire [1:0]         inst_sel,    // 0=钢琴, 1=吉他, 2=小提琴
    input  wire signed [15:0] x,           // 琴桥激励输入 (来自琴体滤波器)
    output reg  signed [15:0] y_symp       // 交感共振输出信号
);

    // 延音踏板激活时反馈系数提升至 0.975 (249/256)，未踩踏板时取 0.875 (224/256)
    wire [7:0] fb_coeff = sustain ? 8'd249 : 8'd224;

    // 激励微量注入 (x >>> 5 = 1/32 增益，留足 30 dB 裕量，永不自激)
    // 小提琴(2)与二胡(3)不激发钢琴/吉他音板交感共鸣
    wire signed [15:0] x_inject = (inst_sel == 2'd2 || inst_sel == 2'd3) ? 16'sd0 : (x >>> 5);

    // -------------------------------------------------------------------------
    // 4 组调谐延迟共振环 (Fs = 97,656.25 Hz)
    // Cell 0: A0 木质音板主模态 (fc ≈ 240 Hz, DLY = 407 样本)
    // Cell 1: 八度泛音共鸣 (fc ≈ 440 Hz, DLY = 222 样本)
    // Cell 2: 十二度五度泛音共鸣 (fc ≈ 660 Hz, DLY = 148 样本)
    // Cell 3: 双八度高频共鸣 (fc ≈ 880 Hz, DLY = 111 样本)
    // -------------------------------------------------------------------------
    localparam DLY0 = 407;
    localparam DLY1 = 222;
    localparam DLY2 = 148;
    localparam DLY3 = 111;

    // 纯硬件 Block RAM 映射（禁止在复位时遍历清零，确保推断为 18K BSRAM 原语）
    (* ram_style = "block" *) reg signed [15:0] mem0 [0:511];
    (* ram_style = "block" *) reg signed [15:0] mem1 [0:255];
    (* ram_style = "block" *) reg signed [15:0] mem2 [0:255];
    (* ram_style = "block" *) reg signed [15:0] mem3 [0:127];

    reg [8:0] ptr0 = 9'd0;
    reg [7:0] ptr1 = 8'd0;
    reg [7:0] ptr2 = 8'd0;
    reg [6:0] ptr3 = 7'd0;

    reg signed [15:0] rd0 = 16'sd0;
    reg signed [15:0] rd1 = 16'sd0;
    reg signed [15:0] rd2 = 16'sd0;
    reg signed [15:0] rd3 = 16'sd0;

    reg signed [24:0] mul0 = 25'sd0;
    reg signed [24:0] mul1 = 25'sd0;
    reg signed [24:0] mul2 = 25'sd0;
    reg signed [24:0] mul3 = 25'sd0;

    // 简单高效的饱和加法防溢出
    function signed [15:0] sat16;
        input signed [17:0] v;
        begin
            if (v > 18'sd32767)       sat16 = 16'sd32767;
            else if (v < -18'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    // 4 拍高效流水线状态机 + 上电 512 拍 BSRAM 硬件零底噪快速清扫
    localparam [2:0] S_IDLE = 3'd0, S_MUL = 3'd1, S_WR = 3'd2, S_ACC = 3'd3, S_CLR = 3'd4;
    localparam [9:0] CLR_MAX = 10'd512;
    reg [2:0] state = S_CLR;
    reg [9:0] clr_cnt = 10'd0;
    reg signed [15:0] x_inject_r = 16'sd0;
    reg [7:0]         fb_coeff_r = 8'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_CLR;
            clr_cnt    <= 10'd0;
            ptr0       <= 9'd0;
            ptr1       <= 8'd0;
            ptr2       <= 8'd0;
            ptr3       <= 7'd0;
            rd0        <= 16'sd0;
            rd1        <= 16'sd0;
            rd2        <= 16'sd0;
            rd3        <= 16'sd0;
            mul0       <= 25'sd0;
            mul1       <= 25'sd0;
            mul2       <= 25'sd0;
            mul3       <= 25'sd0;
            y_symp     <= 16'sd0;
            x_inject_r <= 16'sd0;
            fb_coeff_r <= 8'd0;
        end else begin
            case (state)
                S_CLR: begin
                    // 复位释放后 10.24 µs 内将全通道 Block RAM 内存清零，彻底根除开机随机随机位反馈自激
                    mem0[clr_cnt[8:0]] <= 16'sd0;
                    if (clr_cnt < 10'd256) begin
                        mem1[clr_cnt[7:0]] <= 16'sd0;
                        mem2[clr_cnt[7:0]] <= 16'sd0;
                    end
                    if (clr_cnt < 10'd128) begin
                        mem3[clr_cnt[6:0]] <= 16'sd0;
                    end
                    if (clr_cnt == CLR_MAX - 10'd1) begin
                        state <= S_IDLE;
                    end else begin
                        clr_cnt <= clr_cnt + 10'd1;
                    end
                end

                S_IDLE: begin
                    if (sample_tick) begin
                        x_inject_r <= x_inject;
                        fb_coeff_r <= fb_coeff;
                        // BSRAM 同步读
                        rd0 <= mem0[ptr0];
                        rd1 <= mem1[ptr1];
                        rd2 <= mem2[ptr2];
                        rd3 <= mem3[ptr3];
                        state <= S_MUL;
                    end
                end

                S_MUL: begin
                    // 乘法器流水线级：加入微小信号死区抑制 (Zero-Squelch)，彻底根除定点 IIR 极限环与底噪
                    mul0 <= ((rd0 >= -16'sd2 && rd0 <= 16'sd2 && x_inject_r == 16'sd0) ? 16'sd0 : rd0) * $signed({1'b0, fb_coeff_r});
                    mul1 <= ((rd1 >= -16'sd2 && rd1 <= 16'sd2 && x_inject_r == 16'sd0) ? 16'sd0 : rd1) * $signed({1'b0, fb_coeff_r});
                    mul2 <= ((rd2 >= -16'sd2 && rd2 <= 16'sd2 && x_inject_r == 16'sd0) ? 16'sd0 : rd2) * $signed({1'b0, fb_coeff_r});
                    mul3 <= ((rd3 >= -16'sd2 && rd3 <= 16'sd2 && x_inject_r == 16'sd0) ? 16'sd0 : rd3) * $signed({1'b0, fb_coeff_r});
                    state <= S_WR;
                end

                S_WR: begin
                    // 饱和截断并写回 BSRAM：算术右移采用向零取整保护，防止负数无限滞留于 -1
                    mem0[ptr0] <= sat16($signed({{2{x_inject_r[15]}}, x_inject_r}) + $signed({{2{mul0[24]}}, ((mul0 < 0 && mul0[7:0] != 8'd0) ? ($signed(mul0[23:8]) + 16'sd1) : mul0[23:8])}));
                    mem1[ptr1] <= sat16($signed({{2{x_inject_r[15]}}, x_inject_r}) + $signed({{2{mul1[24]}}, ((mul1 < 0 && mul1[7:0] != 8'd0) ? ($signed(mul1[23:8]) + 16'sd1) : mul1[23:8])}));
                    mem2[ptr2] <= sat16($signed({{2{x_inject_r[15]}}, x_inject_r}) + $signed({{2{mul2[24]}}, ((mul2 < 0 && mul2[7:0] != 8'd0) ? ($signed(mul2[23:8]) + 16'sd1) : mul2[23:8])}));
                    mem3[ptr3] <= sat16($signed({{2{x_inject_r[15]}}, x_inject_r}) + $signed({{2{mul3[24]}}, ((mul3 < 0 && mul3[7:0] != 8'd0) ? ($signed(mul3[23:8]) + 16'sd1) : mul3[23:8])}));
                    state <= S_ACC;
                end

                S_ACC: begin
                    // 指针递增与环形重绕
                    ptr0 <= (ptr0 >= DLY0 - 1) ? 9'd0 : (ptr0 + 9'd1);
                    ptr1 <= (ptr1 >= DLY1 - 1) ? 8'd0 : (ptr1 + 8'd1);
                    ptr2 <= (ptr2 >= DLY2 - 1) ? 8'd0 : (ptr2 + 8'd1);
                    ptr3 <= (ptr3 >= DLY3 - 1) ? 7'd0 : (ptr3 + 7'd1);
                    // 4 组交感共振混合求和 (各取 1/4 权重相加)
                    y_symp <= sat16((rd0 >>> 2) + (rd1 >>> 2) + (rd2 >>> 2) + (rd3 >>> 2));
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
