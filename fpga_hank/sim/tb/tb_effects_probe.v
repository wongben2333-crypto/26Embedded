// =============================================================================
//  tb_effects_probe.v —— 调试用最小探针（不是验收 TB，验收是 tb_effects.v）
//
//  目的：当 tb_effects 的判据 FAIL 时，用它**直接看 DUT 内部**定位原因，
//        而不是靠推理。用分层引用直接读 audio_fx / fx_echo 的内部信号。
//
//  跑法：
//      $env:FX_TB_ROOT=(Resolve-Path fpga_hank); cd $env:TEMP
//      vsim -c -do <abs>\_research\effects\run_tb_effects.do   （该 .do 会一并编译本文件）
//      然后 vsim -c -work <temp>/fx_tb_work tb_effects_probe
//
//  最小化设计：只做一件事 —— 灌一个脉冲进"延迟"模式，把输出和内部状态打出来。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_effects_probe;

    localparam integer TICK_DIV = 4;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n = 0, sample_tick = 0;
    reg [1:0] fx_sel = 2'b00;
    reg [6:0] param = 0;
    reg signed [15:0] fx_in = 0;
    wire signed [15:0] fx_out;

    audio_fx #(.N_FX(3)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .fx_sel(fx_sel), .param(param), .fx_in(fx_in), .fx_out(fx_out)
    );

    // tick 发生器：n 与 tick 同拍更新（模拟真实寄存源）
    integer tdc = 0, n = 0;
    reg tick_d = 0, tick_dd = 0;
    integer out_idx = -1;
    reg   dump = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            tdc <= 0; sample_tick <= 0; tick_d <= 0; tick_dd <= 0;
        end else begin
            if (tdc >= TICK_DIV-1) begin tdc <= 0; sample_tick <= 1; n <= n + 1; end
            else                   begin tdc <= tdc + 1; sample_tick <= 0; end
            tick_d  <= sample_tick;
            tick_dd <= tick_d;
            if (tick_dd) out_idx <= n;
        end
    end

    integer k;                                   // 主流程的循环计数器（任务里另有局部变量）
    integer imp_a = -1;
    reg     imp_on = 0;
    always @(*) fx_in = (imp_on && n == imp_a) ? 16'sd20000 : 16'sd0;

    // 只要读出的 d_rd 非 0 就打一行 —— 直接看"记忆有没有被读回来"。
    // ⚠️ 必须用 rst_n 门控：否则复位前 mem 全是 X，会打印几百万行把 transcript 淹掉
    //    （第一版就是这样，2 490 683 行，还害我以为仿真卡死了）。
    always @(posedge clk) begin
        if (rst_n && tick_dd && dut.u_echo.d_rd !== 16'sd0)
            $display("[probe] d_rd!=0  n=%0d wr_ptr=%0d rd_addr=%0d d_rd=%0d y=%0d out=%0d",
                     n, dut.u_echo.wr_ptr, dut.u_echo.rd_addr,
                     dut.u_echo.d_rd, dut.u_echo.y, fx_out);
    end

    // 输出监视：dump 期间任何非零输出都打印（含相对脉冲位置）
    always @(posedge clk) begin
        if (rst_n && dump && tick_dd && (fx_out > 16'sd50 || fx_out < -16'sd50))
            $display("[probe] out n=%0d 相对=%0d fx_out=%0d", n, n - imp_a, fx_out);
    end

    // ★★ 任务里必须用【局部变量】做循环计数器 ★★
    //  第一版用模块级 `k` 同时当 run_samples 的内部计数器 **和** 调用处的 for 循环
    //  变量；run_samples 每次进来把 k 清 0，外层 for 的计数器就被抹掉 ⇒ **外层死循环**
    //  （跑满 200 ms 看门狗、打印 249 万行）。这是 Verilog 里非常容易犯的别名错误。
    task run_samples;
        input integer kk;
        integer i;
        begin
            i = 0;
            while (i < kk) begin @(posedge clk); if (sample_tick) i = i + 1; end
        end
    endtask

    task waitc;
        input integer kk;
        integer i;
        begin
            for (i = 0; i < kk; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        $display("==== tb_effects_probe ====");
        rst_n = 0; waitc(20); rst_n = 1;
        waitc(60000);                                   // 远超清缓冲的 32768 拍
        $display("[probe] 清缓冲后: clr_en=%b clr_cnt=%0d", dut.clr_en, dut.clr_cnt);

        // ---- 延迟模式：灌一个脉冲 ----
        fx_sel = 2'b01; param = 7'd0;
        run_samples(100);
        $display("[probe] echo 内部: len=%0d wr_ptr=%0d d_rd=%0d y=%0d clr_en=%b",
                 dut.u_echo.len, dut.u_echo.wr_ptr, dut.u_echo.d_rd, dut.u_echo.y, dut.clr_en);
        imp_a = n;
        imp_on = 1;
        $display("[probe] 注入脉冲于 n=%0d（此刻 fx_in=%0d）", imp_a, fx_in);
        dump = 1;
        // 逐点打印脉冲前后 12 个采样点的内部状态
        for (k = 0; k < 12; k = k + 1) begin
            run_samples(1);
            $display("[probe] n=%0d fx_in=%0d | echo: wr_ptr=%0d rd_addr=%0d d_rd=%0d y=%0d | fx_out=%0d",
                     n, fx_in, dut.u_echo.wr_ptr, dut.u_echo.rd_addr,
                     dut.u_echo.d_rd, dut.u_echo.y, fx_out);
        end
        imp_on = 0;
        $display("[probe] 脉冲后 12 点: mem[6905]=%0d mem[6906]=%0d mem[6907]=%0d mem[6908]=%0d",
                 dut.u_echo.mem[6905], dut.u_echo.mem[6906],
                 dut.u_echo.mem[6907], dut.u_echo.mem[6908]);
        dump = 1;                                   // ★ 整个 12000 点都打印非零输出
        run_samples(12000);
        dump = 0;
        $display("[probe] 延迟模式跑完，n=%0d  mem[6906]=%0d", n, dut.u_echo.mem[6906]);
        $stop;
    end

    initial begin
        #200_000_000;
        $display("[probe] 超时");
        $finish;
    end

endmodule

`default_nettype wire
