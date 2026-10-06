// =============================================================================
//  tb_piano_engine_fuzz.v —— 「表情开启」随机 fuzz 回归（常设，Lead 2026-10-06 批准）
//
//  为什么要有它（两次事故同一个缺口）：
//    · 第一次：只测了"表情输入全 0"⇒ 表达式通路的问题没暴露
//    · 第二次：两拍窗口只对"单音、全相位"做了穷举，**从未进入 gliding=1**
//  两次都是【证据覆盖范围 ≠ 结论范围】。这个 TB 就是来堵这个缺口：
//    **随机化 vib/glide/sustain/力度/音符/时长，并且【在音符发声中途改表情】**，
//    把整段输出 dump 下来，供"改动前 vs 改动后"逐字节对比。
//
//  ⚠️ 随机种子【固定并打印】：否则"这次过了"不可复现。
//  ⚠️ 可移植：旧版没有 inst_sel 端口 ⇒ 用 `ifdef HAS_INST_SEL 控制。
//     旧树：vlog +define+HAS_INST_SEL=0（不定义）
//     新树：vlog +define+HAS_INST_SEL
//
//  用法：vsim -c -do "run -all;quit -f" tb_piano_engine_fuzz
//        输出 out/fuzz_dump.txt
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_piano_engine_fuzz;
    localparam integer VDIV = 512;
    localparam integer SEED = 32'h1234_5678;   // ★ 固定种子（报告里要写）
    localparam integer NNOTES = 160;           // 音符事件数

    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg [9:0] tc = 0; reg tick = 0;
    always @(posedge clk) begin
        if (tc == VDIV-1) begin tc <= 0; tick <= 1; end
        else begin tc <= tc + 1; tick <= 0; end
    end

    reg on_v = 0, off_v = 0;
    reg [6:0] on_n = 0, on_vel = 0, off_n = 0;
    reg glide_on = 0; reg [6:0] glide_time = 0;
    reg vib_on = 0;   reg [6:0] vib_depth = 0, vib_rate = 0;
    reg sustain = 0;
    wire signed [15:0] mix; wire [7:0] act;

    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(glide_on), .glide_time(glide_time),
        .vib_on(vib_on), .vib_depth(vib_depth), .vib_rate(vib_rate),
        .sustain(sustain),
`ifdef HAS_INST_SEL
        .inst_sel(2'd0),
`endif
        .mix_out(mix), .active(act));

    integer fd, i, g, rnd;
    reg [31:0] seed;
    reg [6:0] cur_note;
    reg       note_open;

    // 随机：$random(seed) 由 seed 决定，种子固定 ⇒ 序列可复现
    function integer rnd_range; input integer lo; input integer hi; begin
        rnd = $random(seed) % (hi - lo + 1);
        if (rnd < 0) rnd = rnd + (hi - lo + 1);
        rnd_range = lo + rnd;
    end endfunction

    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask

    initial begin
        seed = SEED;
        fd = $fopen("out/fuzz_dump.txt", "w");
        $display("[FUZZ] 固定种子 = 0x%08X，音符事件 %0d 个（可复现）", SEED, NNOTES);
        rst_n = 1'b0; repeat (8) @(posedge clk); rst_n = 1'b1;
        wait_ticks(4);
        note_open = 1'b0;

        for (i = 0; i < NNOTES; i = i + 1) begin
            // ---- 随机改表情（可能在音符发声中途，这正是要覆盖的路径）----
            case (rnd_range(0, 5))
                0: begin vib_on <= rnd_range(0,1); vib_depth <= rnd_range(0,127); end
                1: begin vib_rate <= rnd_range(0,127); vib_on <= 1'b1; end
                2: begin vib_on <= 1'b0; vib_depth <= 7'd0; end
                3: begin glide_on <= rnd_range(0,1); glide_time <= rnd_range(0,127); end
                4: begin sustain <= rnd_range(0,1); end
                default: begin glide_on <= 1'b0; sustain <= 1'b0; end
            endcase
            // ---- 偶尔先释放旧音 ----
            if (note_open && rnd_range(0,1) == 1) begin
                @(posedge clk); off_n <= cur_note; off_v <= 1'b1;
                @(posedge clk); off_v <= 1'b0;
                note_open = 1'b0;
                wait_ticks(rnd_range(0, 6));
            end
            // ---- 发新音（音高/力度/按住时长全随机）----
            cur_note = rnd_range(40, 92);
            @(posedge clk); on_n <= cur_note; on_vel <= rnd_range(1,127); on_v <= 1'b1;
            @(posedge clk); on_v <= 1'b0;
            note_open = 1'b1;
            // 按住时长：1..40 个采样点；含"极短"以触发抢占
            wait_ticks(rnd_range(1, 40));
            // ★ 每个事件后连续录 64 个采样点（覆盖起音瞬态、颤音/滑音的建立过程）
            //   ⚠️ 第一版只 dump 1 个点/事件（共 162 点）—— 那是"稀疏抽样"，
            //      正是我刚栽过的那种"覆盖范围不够"的坑 ⇒ 改成连续 64 点。
            for (g = 0; g < 64; g = g + 1) begin
                @(posedge clk); #1; $fwrite(fd, "%0d\n", mix);
            end
        end
        // ---- 收尾：全放掉，再录一段释放尾巴 ----
        if (note_open) begin
            @(posedge clk); off_n <= cur_note; off_v <= 1'b1;
            @(posedge clk); off_v <= 1'b0;
        end
        sustain <= 1'b0; vib_on <= 1'b0; glide_on <= 1'b0;
        wait_ticks(400);
        $fwrite(fd, "%0d\n", mix);
        wait_ticks(200);
        $fwrite(fd, "%0d\n", mix);
        $fclose(fd);
        $display("[FUZZ] 完成，输出写到 out/fuzz_dump.txt");
        $stop;
    end
endmodule
`default_nettype wire
