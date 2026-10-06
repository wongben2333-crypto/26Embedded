// =============================================================================
//  tb_cab_probe.v —— **箱体逐级增益探针**（定位"整体差 4 倍 = +12 dB"）
// =============================================================================
//  线索来自 Lead：**12.04 dB = 20·log10(4)**，正好 4 倍 = 2 个二进制位
//  ⇒ 先量"每一级"的增益，看是哪一级引入了 ×4（比看整体响应快得多）。
//
//  做法：cab_sel=1、fx_sel=3（清音+箱体），喂 996.5 Hz 正弦（整数周期 per=98）、
//        峰峰值 16000，逐级测峰峰值：
//          fx_in -> [一阶高通#1] hp1_out -> [一阶高通#2] hp2_out
//                -> [峰值均衡] eq_out -> [二阶低通] lp_out -> fx_out
//  预期（我按发射的 Q2.18 系数手算过）：
//     hp1/hp2 ≈ ×0.993 各一次、峰值均衡在 1 kHz ≈ ×1.054、低通 ≈ ×0.967
//     ⇒ 总 ≈ ×1.005 ⇒ **峰峰值应 ≈ 16000**
//  若某一级明显是 ×4 或 ÷4，就直接定位到了。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_cab_probe;

    localparam real PI = 3.14159265358979;

    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0, sample_tick = 0;
    reg [1:0] fx_sel = 2'd3, cab_sel = 2'd1;
    reg [6:0] drive = 0, tone = 7'd127, level = 7'd64;
    reg signed [15:0] fx_in = 0;
    wire signed [15:0] fx_out;

    integer tdc = 0, tick_div = 512, n = 0;
    always @(posedge clk) begin
        if (!rst_n) begin tdc <= 0; sample_tick <= 0; end
        else begin
            if (tdc >= tick_div-1) begin tdc <= 0; sample_tick <= 1'b1; n <= n+1; end
            else begin tdc <= tdc+1; sample_tick <= 1'b0; end
        end
    end

    guitar_fx dut (.clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
                   .fx_sel(fx_sel), .cab_sel(cab_sel), .drive(drive),
                   .tone(tone), .level(level), .fx_in(fx_in), .fx_out(fx_out));

    task wait_clk; input integer k; integer j;
        begin for (j=0;j<k;j=j+1) @(posedge clk); end
    endtask
    task run_samples; input integer k; integer j;
        begin j=0; while (j<k) begin @(posedge clk); if (sample_tick) j=j+1; end end
    endtask

    // 逐级峰峰值
    integer imin,imax, h1min,h1max, h2min,h2max, eqmin,eqmax, lpmin,lpmax, omin,omax;
    integer k;
    real ph, inc;

    task reset_peaks;
        begin
            imin = 100000; imax = -100000;
            h1min = 100000; h1max = -100000;
            h2min = 100000; h2max = -100000;
            eqmin = 100000; eqmax = -100000;
            lpmin = 100000; lpmax = -100000;
            omin = 100000; omax = -100000;
        end
    endtask

    task track;
        begin
            if (fx_in            > imax) imax = fx_in;
            if (fx_in            < imin) imin = fx_in;
            if (dut.u_cab.hp1_out > h1max) h1max = dut.u_cab.hp1_out;
            if (dut.u_cab.hp1_out < h1min) h1min = dut.u_cab.hp1_out;
            if (dut.u_cab.hp2_out > h2max) h2max = dut.u_cab.hp2_out;
            if (dut.u_cab.hp2_out < h2min) h2min = dut.u_cab.hp2_out;
            if (dut.u_cab.eq_out  > eqmax) eqmax = dut.u_cab.eq_out;
            if (dut.u_cab.eq_out  < eqmin) eqmin = dut.u_cab.eq_out;
            if (dut.u_cab.lp_out  > lpmax) lpmax = dut.u_cab.lp_out;
            if (dut.u_cab.lp_out  < lpmin) lpmin = dut.u_cab.lp_out;
            if (fx_out            > omax) omax = fx_out;
            if (fx_out            < omin) omin = fx_out;
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_cab_probe : 箱体逐级增益（996.5 Hz，输入峰峰 16000）===");
        rst_n = 0; wait_clk(20); rst_n = 1; wait_clk(200);

        // 先稳定 4000 个采样点（让各级状态收敛）
        inc = 2.0*PI/98.0; ph = 0.0;
        for (k = 0; k < 4000; k = k + 1) begin
            fx_in = $rtoi(8000.0*$sin(ph)); ph = ph + inc;
            if (ph > 2.0*PI) ph = ph - 2.0*PI;
            run_samples(1);
        end

        // 再测 20 个整周期的峰峰值
        reset_peaks;
        ph = 0.0;
        for (k = 0; k < 98*20; k = k + 1) begin
            fx_in = $rtoi(8000.0*$sin(ph)); ph = ph + inc;
            if (ph > 2.0*PI) ph = ph - 2.0*PI;
            run_samples(1);
            track;
        end

        $display("  级            峰峰值      相对输入");
        $display("  fx_in        %8d      1.000", imax-imin);
        $display("  hp1_out      %8d      %.4f", h1max-h1min, $itor(h1max-h1min)/$itor(imax-imin));
        $display("  hp2_out      %8d      %.4f", h2max-h2min, $itor(h2max-h2min)/$itor(imax-imin));
        $display("  eq_out       %8d      %.4f", eqmax-eqmin, $itor(eqmax-eqmin)/$itor(imax-imin));
        $display("  lp_out       %8d      %.4f", lpmax-lpmin, $itor(lpmax-lpmin)/$itor(imax-imin));
        $display("  fx_out       %8d      %.4f", omax-omin, $itor(omax-omin)/$itor(imax-imin));
        $display("");
        $display("  逐级增益（相邻两级的比）：");
        $display("    hp1/in   = %.4f", $itor(h1max-h1min)/$itor(imax-imin));
        $display("    hp2/hp1  = %.4f", $itor(h2max-h2min)/$itor(h1max-h1min));
        $display("    eq/hp2   = %.4f", $itor(eqmax-eqmin)/$itor(h2max-h2min));
        $display("    lp/eq    = %.4f", $itor(lpmax-lpmin)/$itor(eqmax-eqmin));
        $display("    out/lp   = %.4f", $itor(omax-omin)/$itor(lpmax-lpmin));
        $display("=== probe done ===");
        // ---- 追加：原始序列（前 24 个采样点）----
        $display("");
        $display("  原始序列（前 24 点，per=98）:");
        $display("    n   fx_in   h1_d   h1_m>>>18  hp1_out  h1_x1  h1_y1");
        ph = 0.0;
        for (k = 0; k < 24; k = k + 1) begin
            fx_in = $rtoi(8000.0*$sin(ph)); ph = ph + inc;
            if (ph > 2.0*PI) ph = ph - 2.0*PI;
            run_samples(1);
            $display("   %3d %7d %7d %9d %8d %7d %7d",
                     k, fx_in, dut.u_cab.h1_d, (dut.u_cab.h1_m >>> 18),
                     dut.u_cab.hp1_out, dut.u_cab.h1_x1, dut.u_cab.h1_y1);
        end
        $stop;
    end

    initial begin #2.0e9; $display("[probe] timeout"); $finish; end

endmodule

`default_nettype wire
