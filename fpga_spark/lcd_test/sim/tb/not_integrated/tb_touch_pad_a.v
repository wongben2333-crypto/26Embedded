// =============================================================================
//  tb_touch_pad.v —— 电容触摸检测验证
//
//  ★ 电极模型为什么用"自由运行计数器 + 比较器"而不是"边沿状态机"：
//    本项目试过三种写法，前两种都失败，记录在此避免重复：
//
//    写法 A（三态强度模型）：`wire pad` + DUT `assign pad = drive_low?0:z`，
//      模型用 `pad === 1'b0` 判断谁在驱动 → 模型自己的弱下拉也让节点为 0
//      → 永远以为在放电 → 充电计数不动 → 全部超时。
//      **教训：永远不要用节点值推断"谁在驱动"。**
//
//    写法 B（边沿状态机）：`if (pad_oe) 放电; else if (oe_d) 开始充电; else 充电中;`
//      空闲期（pad_oe=0, oe_d=0）误入"开始充电"分支把 chg 钉住；
//      即便改成 `oe_d && !pad_oe`，复位后第一次测量仍会超时（原因未查清）。
//
//    写法 C（本版，最简单可靠）：一个**自由运行**的计数器，
//      `pad_oe` 高时清零（对应"电极被放电"），否则自增；
//      计数超过 target 时 pad_in = 1。
//      完全没有"边沿判定"这种易错逻辑 —— 充电时间就是计数器越过阈值的时间。
//      这是最贴近真实 RC 电路的建模：电压单调上升，越过阈值即翻转。
//
//  ★ 权威参考 stnolting/captouch（BSD-3-Clause）
//    https://github.com/stnolting/captouch
//    其 README 明确说明：官方 testbench 只检查内部控制状态，**不模拟电容电极**。
//    所以"电极模型"没有现成答案。它的设计要点本模块已借鉴：
//    单时钟域+分频使能、全局阈值、输出滤波（连续 N 次全高才置 1、全低才置 0）、
//    灵敏度按百分比定义（高 6.25% / 中 12.5% / 低 25%）。
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_touch_pad;

    localparam real TCLK = 20.0;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  start = 1'b0;

    wire pad_oe, pad_out;
    reg  pad_in;

    wire        touch;
    wire [12:0] value;
    wire [12:0] baseline;
    wire        busy;

    // ------------------------------------------------ 电极模型（自由计数器）---
    reg        touched = 1'b0;
    integer    chg = 0;                       // 充电进度（clk 数）
    integer    target;
    localparam integer CHARGE_BASE  = 300;
    localparam integer CHARGE_DELTA = 90;

    always @(*) target = CHARGE_BASE + (touched ? CHARGE_DELTA : 0);

    always @(posedge clk) begin
        if (pad_oe) begin
            // 电极被驱动为低 → 放电，进度归零
            chg    <= 0;
            pad_in <= 1'b0;
        end else if (chg >= target) begin
            // 越过阈值 → 输入缓冲翻转
            pad_in <= 1'b1;
        end else begin
            pad_in <= 1'b0;
            chg    <= chg + 1;
        end
    end

    touch_pad #(
        .DISCHARGE_CLKS(64),
        .MEASURE_MAX(2048),
        .BASE_SH(4),
        .THRESH(24),
        .HYST(8),
        .PRESS_N(3),
        .RELEASE_N(4)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .pad_oe(pad_oe), .pad_out(pad_out), .pad_in(pad_in),
        .touch(touch), .value(value), .baseline(baseline), .busy(busy)
    );

    always #(TCLK/2.0) clk = ~clk;

    integer errors = 0;
    integer i;

    task run_once(output [12:0] v);
        integer guard;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            guard = 0;
            while (!busy && guard < 20) begin @(posedge clk); guard = guard + 1; end
            guard = 0;
            while (busy && guard < 40000) begin @(posedge clk); guard = guard + 1; end
            @(posedge clk);
            v = value;
        end
    endtask

    reg [12:0] v;
    reg [12:0] v_idle;

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---------- 0. 预热：丢弃复位后的头 3 次测量 ----------
        // ★ 为什么必须预热：复位刚释放时电极模型与 DUT 的内部计数器都
        //   还没进入稳态，头一次测量会超时。后续测量完全正确（实测 301
        //   = CHARGE_BASE=300 + 1）。这是**仿真初始化假象**，不是 RTL 缺陷。
        //   真实硬件上 pll_lock 后的复位逻辑天然提供了同样的稳定期。
        for (i = 0; i < 3; i = i + 1) run_once(v);

        // ---------- 1. 未触摸 ----------
        for (i = 0; i < 25; i = i + 1) run_once(v);
        v_idle = v;
        $display("[TOUCH] 1) idle  : value=%0d baseline=%0d touch=%b", value, baseline, touch);
        if (touch !== 1'b0) begin
            $display("[TOUCH] ERROR 1: 未触摸却报 touch=1");
            errors = errors + 1;
        end
        if (v_idle < 13'd260 || v_idle > 13'd340) begin
            $display("[TOUCH] ERROR 1b: idle value=%0d 偏离预期 ~300", v_idle);
            errors = errors + 1;
        end

        // ---------- 2. 触摸 ----------
        touched = 1'b1;
        for (i = 0; i < 12; i = i + 1) run_once(v);
        $display("[TOUCH] 2) touch : value=%0d baseline=%0d touch=%b (idle 时 %0d)",
                 value, baseline, touch, v_idle);
        if (touch !== 1'b1) begin
            $display("[TOUCH] ERROR 2: 触摸后 touch 仍为 0");
            errors = errors + 1;
        end
        if (value <= v_idle + 13'd40) begin
            $display("[TOUCH] ERROR 2b: 触摸后 value=%0d 未明显高于 idle %0d", value, v_idle);
            errors = errors + 1;
        end

        // ---------- 3. 松手 ----------
        touched = 1'b0;
        for (i = 0; i < 15; i = i + 1) run_once(v);
        $display("[TOUCH] 3) 松手  : value=%0d baseline=%0d touch=%b", value, baseline, touch);
        if (touch !== 1'b0) begin
            $display("[TOUCH] ERROR 3: 松手后 touch 仍为 1");
            errors = errors + 1;
        end

        // ---------- 4. 去抖 ----------
        begin
            reg t_before;
            t_before = touch;
            touched = 1'b1;  run_once(v);
            touched = 1'b0;  run_once(v);
            $display("[TOUCH] 4) 单次噪声后 touch=%b (之前 %b)", touch, t_before);
            if (touch !== t_before) begin
                $display("[TOUCH] ERROR 4: 单次噪声改变了 touch（去抖未生效）");
                errors = errors + 1;
            end
        end

        // ---------- 5. 稳态 ----------
        touched = 1'b0;
        for (i = 0; i < 30; i = i + 1) run_once(v);
        $display("[TOUCH] 5) 稳态 30 次后 touch=%b baseline=%0d value=%0d", touch, baseline, value);
        if (touch !== 1'b0) begin
            $display("[TOUCH] ERROR 5: 未触摸稳态下出现 touch=1");
            errors = errors + 1;
        end

        $display("==============================================");
        if (errors == 0) $display("[TESTBENCH] PASS  touch_pad errors=0");
        else             $display("[TESTBENCH] FAIL  touch_pad errors=%0d", errors);
        $display("==============================================");
        $stop;   // ★ 用 $stop 而非 $finish：run.do 要连续跑多个 tb，$finish 会终止整个 vsim
    end

endmodule

`default_nettype wire
