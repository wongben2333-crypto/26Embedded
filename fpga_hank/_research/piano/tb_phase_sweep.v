// =============================================================================
//  tb_phase_sweep.v —— note-on 相对 sample_tick 的【相位扫描】回归测试
//
//  背景：本项目真实踩过一个"撞拍丢音"的 bug —— piano_voice 里 `ld_for_me`
//  装载块写在 sample_tick 块【之前】，同一拍相遇时包络衰减会用旧值(0)覆盖刚装载
//  的初值 ⇒ 声部被分配、note_r 也对，但 env 恒 0、这个音完全没声音。
//  该 bug 只在 note-on 与 sample_tick 的相位差命中特定值时出现，
//  所以 flow-verifier 的固定时序 TB 里 A4 响、A5/C4 无声。
//
//  本 TB 对 note-on 相对于 sample_tick 的每一个相位都测一遍：
//  只要有任何一拍出现 env==0，就说明"撞拍丢音"回来了。
//  用法：vsim -c -do "run -all;quit -f" tb_phase_sweep
//        （TICKDIV 用 +TICKDIV=<n> 覆盖，默认 512 = 真机）
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_phase_sweep;
    integer TICKDIV = 512;
    integer NPHASE  = 64;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0;
    reg tick = 0;
    integer td = 0;
    always @(posedge clk) begin
        td <= (td >= TICKDIV - 1) ? 0 : td + 1;
        tick <= (td >= TICKDIV - 1);
    end

    reg on_valid = 0, off_valid = 0;
    reg [6:0] on_note = 0, on_vel = 0, off_note = 0;
    wire signed [15:0] mix;
    wire [7:0] active;

    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_valid), .on_note(on_note), .on_vel(on_vel),
        .off_valid(off_valid), .off_note(off_note),
        // ⚠️ 表情输入必须显式接 0：不接就是 Z，而本设计表情通路是电平敏感的，
        //    Z 会让 pmod_act=x → 相位增量 x → 正弦 ROM 落到 default 分支输出 0 ⇒ 静音。
        .glide_on(1'b0), .glide_time(7'd0), .vib_on(1'b0),
        .vib_depth(7'd0), .vib_rate(7'd0), .inst_sel(2'd0), .sustain(1'b0),
        .mix_out(mix), .active(active));

    integer p, i, ok, bad, firstbad;
    integer tk;

    initial begin
        if (!$value$plusargs("TICKDIV=%d", TICKDIV)) TICKDIV = 512;
        if (!$value$plusargs("NPHASE=%d", NPHASE))   NPHASE  = 64;
        ok = 0; bad = 0; firstbad = -1;
        $display("[SWEEP] TICKDIV=%0d  NPHASE=%0d  （note-on 相对 sample_tick 的相位扫描）",
                 TICKDIV, NPHASE);
        for (p = 0; p < NPHASE; p = p + 1) begin
            // 每个相位都从复位开始，保证分配到的总是 voice 0、状态干净
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            // 对齐到 sample_tick 那一拍
            tk = 0;
            while (tick !== 1'b1 && tk < TICKDIV * 4) begin
                @(posedge clk);
                tk = tk + 1;
            end
            // 再偏移 p 拍后发 note-on
            repeat ((p * TICKDIV) / NPHASE) @(posedge clk);
            @(posedge clk);
            on_note <= 7'd69; on_vel <= 7'd100; on_valid <= 1'b1;
            @(posedge clk);
            on_valid <= 1'b0;
            // 等装载完成（最长 14 拍）+ 余量
            repeat (40) @(posedge clk);
            if (dut.g_voice[0].u_voice.env[0] === 24'd0 ||
                dut.g_voice[0].u_voice.gate_r !== 1'b1) begin
                bad = bad + 1;
                if (firstbad < 0) firstbad = p;
                $display("  [FAIL] 相位偏移 %0d 拍：gate=%b env[0]=%0d（应 >0）",
                         p, dut.g_voice[0].u_voice.gate_r,
                         dut.g_voice[0].u_voice.env[0]);
            end else begin
                ok = ok + 1;
            end
        end
        $display("[SWEEP] 结果：正常 %0d / %0d，异常 %0d%s",
                 ok, NPHASE, bad,
                 (firstbad < 0) ? "" : "（首个异常相位偏移见上）");
        if (bad == 0)
            $display("[SWEEP] PASS: 所有相位下 note-on 都能正确装载包络（撞拍丢音已修）");
        else
            $display("[SWEEP] FAIL: 存在撞拍丢音");
        $stop;
    end
endmodule
`default_nettype wire
