// =============================================================================
//  tb_piano_engine_xn.v —— 受限跨声部数回归（每个场景【累计 note-on ≤ 8】）
//
//  目的：验证 N_VOICES=20 与 N_VOICES=8 在"不该有差异"的场景下【逐字节一致】。
//
//  ⚠️ 判据的物理定义（这是本会话第三次修正判据，务必读）：
//     不是"≤8 个键同时按住"，也不是"≤8 个声部同时可闻"，而是
//     **【累计 note-on ≤ 8】** —— 因为声部在 note-off 之后仍算 active
//     （act_c = 包络顶字节非零，τ = 2.7~5.4 s）⇒ 衰减尾巴让"活跃"远长于"按住"。
//     只有累计 note-on ≤8 且不抢占时，两种声部数才【本该】完全一致。
//
//  ⚠️ 本 TB 每个场景【打印累计 note-on 数】⇒ 读者可独立核对判据是否被满足
//     （不许悄悄超出 8 个还宣称"应该一致"）。
//
//  ⚠️ 不比较 `active` 位宽：N=20 时 active 是 20 bit，用 8'b1111_1111 去比会得到
//     【测试台假失败】（上一轮 T6/T10 就是这么假失败的）。本 TB 只比音频 dump。
//
//  用法：vsim -c -do "run -all;quit -f" tb_piano_engine_xn   → out/xn_<场景>.txt
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_piano_engine_xn;
    localparam integer VDIV = 512;
`ifdef NV20
    localparam integer NV = 20;
`else
    localparam integer NV = 8;
`endif
    localparam integer NSAMP = 4096;        // 每场景 dump 的采样点数

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
    wire signed [15:0] mix; wire [NV-1:0] act;

    piano_engine #(.N_VOICES(NV), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(glide_on), .glide_time(glide_time),
        .vib_on(vib_on), .vib_depth(vib_depth), .vib_rate(vib_rate),
        .sustain(sustain), .inst_sel(2'd0),
        .mix_out(mix), .active(act));

    integer fd, k, g, ncount;
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask
    task do_on; input [6:0] n; input [6:0] v; begin
        @(posedge clk); on_n <= n; on_vel <= v; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0; ncount = ncount + 1; end
    endtask
    task do_off; input [6:0] n; begin
        @(posedge clk); off_n <= n; off_v <= 1'b1;
        @(posedge clk); off_v <= 1'b0; end
    endtask
    task dump; input [8*12-1:0] nm; input integer ns; begin
        $display("[XN] 场景 %0s：累计 note-on = %0d  （判据要求 ≤8）", nm, ncount);
        fd = $fopen({"/dev/null"}, "w");                 // 占位，真正文件在下面开
        fd = $fopen($sformatf("out/xn_%0s.txt", nm), "w");
        for (k = 0; k < ns; k = k + 1) begin
            wait_ticks(1); $fwrite(fd, "%0d\n", mix);
        end
        $fclose(fd);
    end endtask

    initial begin
        $display("[XN] N_VOICES=%0d  NSAMP=%0d", NV, NSAMP);
        // ---------------- S1 单音 ----------------
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        do_on(7'd69, 7'd100); wait_ticks(40); dump("s1_single", NSAMP);
        // ---------------- S2 三音和弦（累计 4）----------------
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        do_on(7'd60, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd64, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd67, 7'd100); wait_ticks(40); dump("s2_chord3", NSAMP);
        // ---------------- S3 恰好 8 音全按住（累计 8）----------------
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        do_on(7'd60,7'd100); repeat (20) @(posedge clk); do_on(7'd62,7'd100); repeat (20) @(posedge clk);
        do_on(7'd64,7'd100); repeat (20) @(posedge clk); do_on(7'd65,7'd100); repeat (20) @(posedge clk);
        do_on(7'd67,7'd100); repeat (20) @(posedge clk); do_on(7'd69,7'd100); repeat (20) @(posedge clk);
        do_on(7'd71,7'd100); repeat (20) @(posedge clk); do_on(7'd72,7'd100);
        wait_ticks(40); dump("s3_poly8", NSAMP);
        // ---------------- S4 单音 + 颤音（累计 1）----------------
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        vib_on <= 1'b1; vib_depth <= 7'd120; vib_rate <= 7'd64;
        do_on(7'd69, 7'd100); wait_ticks(60); dump("s4_vib", NSAMP);
        vib_on <= 1'b0; vib_depth <= 7'd0;
        // ---------------- S5 两音 + 滑音（滑音模式下仍是 1 个声部，累计 2）-----
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        glide_on <= 1'b1; glide_time <= 7'd64;
        do_on(7'd69, 7'd100); wait_ticks(2000);
        do_on(7'd81, 7'd100); wait_ticks(60); dump("s5_glide", NSAMP);
        glide_on <= 1'b0; glide_time <= 7'd0;
        // ---------------- S6 单音 + 延音踏板（累计 1）----------------
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        sustain <= 1'b1; do_on(7'd69, 7'd100); wait_ticks(30);
        do_off(7'd69); wait_ticks(30); dump("s6_sustain", NSAMP); sustain <= 1'b0;
        // ---------------- S7 8 音后全放（累计 8，测释放尾巴）----------------
        ncount = 0; rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        do_on(7'd60,7'd100); repeat (20) @(posedge clk); do_on(7'd64,7'd100); repeat (20) @(posedge clk);
        do_on(7'd67,7'd100); repeat (20) @(posedge clk); do_on(7'd71,7'd100); repeat (20) @(posedge clk);
        do_on(7'd74,7'd100); repeat (20) @(posedge clk); do_on(7'd78,7'd100); repeat (20) @(posedge clk);
        do_on(7'd81,7'd100); repeat (20) @(posedge clk); do_on(7'd84,7'd100);
        wait_ticks(30);
        do_off(7'd60); do_off(7'd64); do_off(7'd67); do_off(7'd71);
        do_off(7'd74); do_off(7'd78); do_off(7'd81); do_off(7'd84);
        wait_ticks(10); dump("s7_poly8_rel", NSAMP);
        $display("[XN] 全部场景完成（N_VOICES=%0d）", NV);
        $stop;
    end
endmodule
`default_nettype wire
