// =============================================================================
//  tb_guitar_probe.v —— **最小探针**（只用来定位问题，不是交付判据）
// =============================================================================
//  目的：把 guitar_fx 内部逐级信号直接打出来，回答三个问题：
//    ① 失真级的直流增益对不对？（drive=0 时应该是 x/8，level=64 时单位增益）
//    ② 箱体到底做了什么？（直流看增益；再看一阶高通是否真的挡住直流）
//    ③ fx_out 与内部各级是否一致？
//  这套"逐层读内部信号"的办法在本项目救过一次（全通自持那个 bug）。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_guitar_probe;

    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0, sample_tick = 0;
    reg [1:0] fx_sel = 0, cab_sel = 0;
    reg [6:0] drive = 0, tone = 7'd127, level = 7'd64;
    reg signed [15:0] fx_in = 0;
    wire signed [15:0] fx_out;

    integer tick_div = 4, tdc = 0, n = 0;
    always @(posedge clk) begin
        if (!rst_n) begin tdc <= 0; sample_tick <= 0; end
        else begin
            if (tdc >= tick_div-1) begin tdc <= 0; sample_tick <= 1'b1; n <= n + 1; end
            else begin tdc <= tdc + 1; sample_tick <= 1'b0; end
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

    initial begin
        $display("");
        $display("=== tb_guitar_probe : 逐级读内部信号 ===");
        rst_n = 0; wait_clk(20); rst_n = 1; wait_clk(200);

        // ---- ① 直流阶跃：看失真级增益 ----
        fx_in = 16'sd8000;                       // 输入 8000 (= 0.244 FS)
        $display("\n--- 直流输入 8000，看各级稳态 ---");
        $display("drive  fx_sel cab_sel | dist_out  cab_out  fx_out");
        begin : sweep
            integer dv, fs, cs;
            for (dv = 0; dv <= 3; dv = dv + 1) begin
                for (cs = 0; cs <= 2; cs = cs + 1) begin
                    for (fs = 1; fs <= 3; fs = fs + 1) begin
                        drive = dv * 42; cab_sel = cs[1:0]; fx_sel = fs[1:0];
                        run_samples(3000);
                        $display("  %3d     %0d       %0d    | %8d  %8d  %8d",
                                 drive, fx_sel, cab_sel,
                                 dut.u_dist.y, dut.u_cab.y, fx_out);
                    end
                end
            end
        end

        // ---- ② 箱体的直流增益（应该被两级一阶高通压到接近 0）----
        $display("\n--- 箱体直流增益（fx_sel=3 清音，cab_sel 0->1）---");
        fx_sel = 2'd3; drive = 0; tone = 7'd127; level = 7'd64;
        fx_in = 16'sd8000; cab_sel = 2'd0; run_samples(4000);
        $display("  cab_sel=0 : fx_out=%0d", fx_out);
        cab_sel = 2'd1; run_samples(4000);
        $display("  cab_sel=1 : cab_out=%0d  fx_out=%0d  (直流应被高通挡掉 -> 接近 0)",
                 dut.u_cab.y, fx_out);
        cab_sel = 2'd2; run_samples(4000);
        $display("  cab_sel=2 : cab_out=%0d  fx_out=%0d", dut.u_cab.y, fx_out);

        // ---- ③ 正弦：输入输出峰峰值（真实速率）----
        $display("\n--- 正弦 220 Hz（真实 1/512 分频），输入幅度 8000 ---");
        tick_div = 512; run_samples(20);
        fx_sel = 2'd1; cab_sel = 2'd0; drive = 0;
        begin : sine
            integer k, vmin, vmax, imin, imax;
            real ph, inc;
            ph = 0.0; inc = 2.0*3.14159265358979*220.0/97656.25;
            vmin = 100000; vmax = -100000; imin = 100000; imax = -100000;
            for (k = 0; k < 4000; k = k + 1) begin
                fx_in = $rtoi(8000.0 * $sin(ph)); ph = ph + inc;
                run_samples(1);
                if (fx_in > imax) imax = fx_in;  if (fx_in < imin) imin = fx_in;
                if (fx_out > vmax) vmax = fx_out; if (fx_out < vmin) vmin = fx_out;
            end
            $display("  输入峰峰 = %0d   (理论 16000)", imax - imin);
            $display("  输出峰峰 = %0d   (drive=0 应 ≈ 输入/8 ≈ 2000)", vmax - vmin);
            // ---- 逐级追踪：正弦为什么会放大 ----
            $display("  单点内部追踪（每 500 点打一次）:");
            ph = 0.0;
            for (k = 0; k < 3000; k = k + 1) begin
                fx_in = $rtoi(8000.0 * $sin(ph)); ph = ph + inc;
                run_samples(1);
                if ((k % 100) == 0)
                    $display("    k=%4d fx_in=%6d | xg=%6d xa=%6d x_asym=%6d xA=%6d",
                             k, fx_in, dut.u_dist.xg, dut.u_dist.xa,
                             dut.u_dist.x_asym, dut.u_dist.xA);
            end
        end

        $display("\n=== probe done ===");
        $stop;
    end

    initial begin #2.0e9; $display("[probe] timeout"); $finish; end

endmodule

`default_nettype wire
