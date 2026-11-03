// =============================================================================
//  tb_outphase.v —— 输出级流水线【逐时钟证据】
//
//  目的（Lead 批准的证据债，判据修正版）：
//    证明流水线是【纯 2 个时钟的延迟】，而不是"数值变了"。
//
//  方法：
//    ① 逐时钟 trace：**每当 mix_out 变化**就记一行 `clk_cnt value`。
//       ⇒ 如果一个采样周期只更新一次、且更新相位恒定，就说明它是"每采样点一个值"（纯延迟特征）
//    ② 相位测量：同时记录每次 `sample_tick` 的时钟号 ⇒
//       算出"mix_out 更新发生在 tick 之后第几拍" ⇒ 与设计文档的 **3 拍** 对照
//       （流水线前是 3 拍；流水线后应为 **5 拍** ⇒ 差正好 **2 拍 = 40 ns**）
//    ③ 定长 dump：**固定 N 个采样点**（不受"何时静音"影响）⇒ 长度恒定 ⇒ 可做逐字节比对
//
//  ⚠️ 只读设计、不改 RTL；用层级探针读 dut.mix_out 内部寄存器。
//  用法：vsim -c -do "run -all;quit -f" tb_outphase
//        ⇒ out/phase_trace.txt（每次变化一行）、out/phase_ticks.txt（每次 tick 一行）
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_outphase;
    localparam integer VDIV  = 512;
    localparam integer NTICK = 4000;      // 定长：4000 个采样点

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

    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(1'b0), .glide_time(7'd0), .vib_on(1'b0),
        .vib_depth(7'd0), .vib_rate(7'd0), .sustain(1'b0),
        .inst_sel(2'd0),
        .mix_out(mix), .active(act));

    integer clk_cnt = 0;
    integer fdt, fdk;
    integer k, g;
    reg signed [15:0] prev_mix = 0;
    integer tick_clk = 0;
    integer upd_cnt = 0;
    integer first_phase = -1;

    always @(posedge clk) clk_cnt = clk_cnt + 1;

    // ① 逐时钟 trace：mix_out 一变就记（含它距最近一次 tick 的拍数）
    always @(posedge clk) begin
        if (mix !== prev_mix) begin
            $fwrite(fdt, "%0d %0d %0d\n", clk_cnt, mix, clk_cnt - tick_clk);
            if (first_phase < 0) first_phase = clk_cnt - tick_clk;
            upd_cnt = upd_cnt + 1;
            prev_mix = mix;
        end
    end

    // ② 每次 sample_tick 记一行（用于算相位）
    always @(posedge clk) begin
        if (tick) begin
            tick_clk = clk_cnt;
            $fwrite(fdk, "%0d\n", clk_cnt);
        end
    end

    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask

    initial begin
        fdt = $fopen("out/phase_trace.txt", "w");
        fdk = $fopen("out/phase_ticks.txt", "w");
        rst_n = 1'b0; repeat (8) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        // 单音 A4（与本项目其它 dump 同场景）
        @(posedge clk); on_n <= 7'd69; on_vel <= 7'd100; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0;
        wait_ticks(NTICK);
        $fclose(fdt); $fclose(fdk);
        $display("[PHASE] clk_cnt=%0d  更新次数=%0d  首次相位=%0d 拍", clk_cnt, upd_cnt, first_phase);
        $display("[PHASE] 后 3 次更新相位见 out/phase_trace.txt 第 3 列");
        $stop;
    end
endmodule
`default_nettype wire
