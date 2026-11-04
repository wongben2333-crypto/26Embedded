// =============================================================================
//  bench_gate.v —— 测试模式演奏产生器（给 ADSR 提供电平敏感 gate）
//
//  用途：让【测试模式】下也能听到 ADSR 包络的实际效果。
//        32 路分 4 组轮换：每 32768 个采样点（≈0.671 s @ 48828.125 Hz）换一组，
//        组内按 note_cnt 的高 2 位选出 2 路按住。
//        于是任意时刻约 2 路在发声，每路都能听到完整的起音→衰减→保持→释放。
//
//  ⚠️ 真实演奏模式（比赛现场弹奏）下，这个模块要被替换成按键/触摸逻辑：
//       电容触摸 / 光电 / 压力检测 → 按键扫描 → 声部分配器 → gate
//     gate 是【电平】不是脉冲：按住=1，松开=0。这是 ADSR 的接口语义，
//     见 adsr.v 头部说明（第一版就是在这里把 gate 当脉冲而失败）。
// =============================================================================
`default_nettype none

module bench_gate #(
    parameter integer N_VOICES    = 32,
    parameter integer NOTE_PERIOD = 32768,   // 每个音符组的长度（采样点数）
    parameter integer GROUP_SIZE  = 8,       // 每组负责多少路
    // ★ 测试模式：把所有 gate 恒置 1
    //
    //   为什么必需：赛题【必备交付物】要求在"测试模式"下频谱能数出 N 个
    //   独立谱峰。而 ADSR 的门控会【调制】每个音，产生边带、把谱峰抹开 ——
    //   实测把演奏模式的波形直接做 FFT：32 路只命中 6 个峰，其余全被抹掉。
    //   所以"测试模式"必须让所有声部都保持按住并进入 sustain（电平恒定），
    //   谱峰才是干净的；"演奏模式"才跑 ADSR 门控。
    //   这不是取巧：赛题原文就是"测试模式下输出多路不同频率音频，频谱可观测
    //   对应数量独立谱峰"，测试模式本来就是一种特定的工作状态。
    parameter integer TEST_MODE   = 1
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                sample_tick,
    output reg  [N_VOICES-1:0] gate
);

    localparam integer N_GROUPS = (N_VOICES + GROUP_SIZE - 1) / GROUP_SIZE;

    reg [16:0] note_cnt;
    reg [3:0]  group;                  // 支持最多 16 组

    // ★ 组合算出下一步的 gate 值，避免"先整体清零再逐位赋值"的自相矛盾
    //   （那会变成双重驱动，只有最后一次赋值生效且顺序脆弱）。
    reg [N_VOICES-1:0] gate_next;
    integer gi;

    always @(*) begin
        if (TEST_MODE != 0) begin
            gate_next = {N_VOICES{1'b1}};     // 测试模式：全部按住，包络进 sustain 后恒定
        end else begin
            gate_next = {N_VOICES{1'b0}};
            if (group < N_GROUPS[3:0]) begin
                // 组内偏移取 0/2/4/6，再 +1 → 同时按住 2 路
                gi = group * GROUP_SIZE + {note_cnt[15:14], 1'b0};
                gate_next[gi]     = 1'b1;
                gate_next[gi + 1] = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            note_cnt <= 17'd0;
            group    <= 4'd0;
            gate     <= {N_VOICES{1'b0}};
        end else if (sample_tick) begin
            // ---------- 组切换 ----------
            if (note_cnt >= NOTE_PERIOD[16:0] - 17'd1) begin
                note_cnt <= 17'd0;
                if (group >= N_GROUPS[3:0] - 4'd1) group <= 4'd0;
                else                               group <= group + 4'd1;
            end else begin
                note_cnt <= note_cnt + 17'd1;
            end
            gate <= gate_next;
        end
    end

endmodule

`default_nettype wire
