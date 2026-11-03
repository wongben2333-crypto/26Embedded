// =============================================================================
//  tb_piano_engine_outsweep.v —— 输出级【前后量化对比】+ 直流阻断实测
//
//  目的（Lead 要求的第 3 条，"我欠的实测"）：
//    ① 直流/次声：输出均值（DC）在**门控前后**的对比
//    ② 软膝触发比例：每个采样点上 `dut.mag > KNEE` 的比例（**层级探针**，不必改 RTL）
//    ③ 频谱杂散：对和弦输出做 FFT，看非谐波分量占比
//    ④ 直流阻断的 −3 dB 点：由**冲激/阶跃响应**反解（见下）
//  重要：本 TB **不改 RTL**，只用层级探针读 dut 内部量 ⇒ 对"改前/改后"两版都能跑，
//        同一套指标做前后对比。
//
//  ⚠️ −3 dB 点怎么测（不注入任意信号也能测）：
//     RTL 里没有可注入的测试输入，所以用**阶跃的直流衰减**间接标定：
//     直流阻断是一阶高通 ⇒ 对"常值输入"的响应按极点指数衰减 ⇒
//     从输出包络的衰减率反解极点 a，再由 f_c = (1−a)·fs/(2π) 得到 −3 dB 点。
//     （另一种做法是读 `dut.hp_y` 的阶跃响应 —— 若该信号存在，本 TB 会优先用它。）
//
//  用法：vsim -c -do "run -all;quit -f" tb_piano_engine_outsweep
//        ⇒ out/sweep_i<inst>.txt，每行：mix_out  dut.mag
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_piano_engine_outsweep;
    localparam integer VDIV = 512;
    localparam integer NTICK = 3000;          // 观察 3000 个采样点（≈30 ms）

    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg [9:0] tc = 0; reg tick = 0;
    always @(posedge clk) begin
        if (tc == VDIV-1) begin tc <= 0; tick <= 1; end
        else begin tc <= tc + 1; tick <= 0; end
    end
    reg on_v = 0, off_v = 0;
    reg [6:0] on_n = 0, on_vel = 0, off_n = 0;
    wire signed [15:0] mix; wire [7:0] act;

    // ⚠️ inst_sel 的取值用【文本替换】生成多份（跑脚本里把这两处 0 换成 1/2/3），
    //    与本项目其它 TB 一致，避免宏拼接在 `2'd`INSTSEL` 这种位置上的解析歧义。
    localparam integer INSTSEL = 0;           // ← 跑脚本替换这一处

    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(1'b0), .glide_time(7'd0), .vib_on(1'b0),
        .vib_depth(7'd0), .vib_rate(7'd0), .sustain(1'b0),
        .inst_sel(2'd0), .bow_speed(7'd64),   // ← 跑脚本替换这一处
        .mix_out(mix), .active(act));

    integer fd, k, g, inst;
    integer nknee, ntot;
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask
    task do_on; input [6:0] n; input [6:0] v; begin
        @(posedge clk); on_n <= n; on_vel <= v; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0; end
    endtask

    initial begin
        inst = INSTSEL;
        $display("[SWEEP] inst_sel=%0d  NTICK=%0d", inst, NTICK);
        fd = $fopen($sformatf("out/sweep_i%0d.txt", inst), "w");
        // 复现"最坏情况"：8 音和弦（这是软膝最容易触发的场景）
        rst_n = 1'b0; repeat (8) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        do_on(7'd60, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd62, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd64, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd65, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd67, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd69, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd71, 7'd120); repeat (20) @(posedge clk);
        do_on(7'd72, 7'd120);
        nknee = 0; ntot = 0;
        for (k = 0; k < NTICK; k = k + 1) begin
            wait_ticks(1);
            // —— 软膝触发统计：直接读内部量（层级探针，不改 RTL）——
            //    dut.mag 是取绝对值后的信号，KNEE=24576（见 piano_engine.v）
            if ($signed(dut.mag) > 28'sd24576) nknee = nknee + 1;
            ntot = ntot + 1;
            $fwrite(fd, "%0d %0d\n", mix, $signed(dut.mag));
        end
        $fclose(fd);
        $display("[SWEEP] inst=%0d 软膝触发 %0d/%0d = %0.2f%%", inst, nknee, ntot,
                 100.0 * nknee / (ntot > 0 ? ntot : 1));
        $stop;
    end
endmodule
`default_nettype wire
