// =============================================================================
//  tb_effects.v —— audio_fx（硬件音频效果器）功能验证
//
//  验证目标（逐条对应 task 的验收要求）：
//    0. 【上电清缓冲】复位后零输入时输出必须恒 0
//       —— 专门抓参考实现踩过的坑：**未初始化的 BSRAM 会给反馈回路"播种"**，
//          读出的垃圾被来回放大并顶到饱和（railed）。ModelSim 里 reg 数组初值是 X，
//          所以"没清干净"在仿真里会直接表现成输出出现 X —— 这条就是它的探针。
//    1. 【旁路直通】fx_sel=00 时 fx_out 必须【逐 bit 等于】fx_in
//    2. 【脉冲响应】fx_sel=01 时单样本脉冲必须在【预期采样点】出现回声，
//       且幅度符合 (脉冲 × wet) 与 (× fb) 的推算值
//    3. 【合唱调制】在两个不同 LFO 相位各注入一次脉冲，两次回声延迟必须明显不同
//       —— 这才证明"延迟量真的被 LFO 调制"，而不是一条固定延迟线
//    4. 【混响尾巴】激励结束后输出能量必须**持续衰减**（既不发散、也不立刻消失）
//    5. 【幅度有界】满幅正直流输入下，四种模式都不许发生 16 bit 回绕
//       （回绕会让正峰变负峰 ⇒ 反馈环立刻发散；正确行为是饱和而不是翻转）
//
//  ===========================================================================
//  ★★ 本 TB 的测量方法：事件日志（不是"窗口内找峰值"）★★
//  ===========================================================================
//  第一版用"在 [a,b] 采样点窗口里找 |fx_out| 最大点"来定位回声，结果**判据全错**，
//  排查花了很久。原因有两个，都值得记下来：
//    · 窗口边界与被测信号的相位差一个采样点，就会把真正的回声排除在窗口外；
//    · 峰值搜索器在"整窗全是 0"时会把窗口起点记成峰值（幅度 0），
//      于是报出"相对位置=9000、幅度=0"这种**看起来像 DUT 坏了**的结论，
//      而实际上 DUT 完全正常（用最小探针 tb_effects_probe.v 一看：
//      回声精确出现在相对 9766、幅度精确 12031）。
//  ⇒ 现在改成【事件日志】：只要 |fx_out| 超过阈值就把 (相对位置, 值) 记进数组，
//    判据直接对着数组下标断言。这样"回声出现在哪、幅度多少"是**读出来的**，
//    不是"搜出来的"，不再依赖窗口对齐。
//
//  ★ sample_tick：生产是每 512 clk 一个，本 TB 用 TICK_DIV=4，纯为压缩仿真时间。
//    · sample_tick 的生成是 top.v 的职责，不在 audio_fx 契约内；
//    · 所有位置断言以【采样点个数】为单位，与 tick 周期无关；
//    · TICK_DIV=4 还顺带卡住"必须等 tick"——若实现错成每个 clk 推进一步，
//      延迟会变成 1/4，位置判据立刻 FAIL。
//
//  ★ 采样点对齐（对齐错了位置判据就全错，这里写清楚）：
//    真实系统里 fx_in 来自**在 sample_tick 边沿更新的寄存器**（混音器输出），
//    所以 TB 让激励**与 tick 同拍更新**（n 在 tick 边沿自增）；DUT 在 tick_d
//    那一拍算、在该拍结束的边沿寄存 y，所以监视器要用 **tick_dd** 采样 fx_out，
//    并在同一拍把 out_idx 对齐到 n。
//
//  ★ 任务里的循环计数器一律用【局部变量】：第一版 run_samples 用了模块级 k，
//    而调用处又用 k 当 for 计数器 ⇒ 内层把外层计数抹掉 ⇒ **外层死循环**
//    （跑满看门狗、打印 249 万行）。这是 Verilog 里极易犯的别名错误。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_effects;

    localparam integer TICK_DIV = 4;

    reg clk = 1'b0;
    always #10 clk = ~clk;                       // 20 ns → 50 MHz

    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg [1:0] fx_sel = 2'b00;
    reg [6:0] param  = 7'd0;
    reg  signed [15:0] fx_in;       // 由下面的 always @(*) 内联驱动（见那条注释）
    wire signed [15:0] fx_out;

    audio_fx #(.N_FX(3)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .fx_sel(fx_sel), .param(param), .fx_in(fx_in), .fx_out(fx_out)
    );

    // =========================================================================
    //  工具（一律先声明后使用）
    // =========================================================================
    function integer abs16;
        input signed [15:0] v;
        begin
            abs16 = (v < 0) ? (0 - v) : v;       // 整数运算，-(-32768) 不溢出
        end
    endfunction

    integer err = 0;

    task chk;
        input [8*150:1] name;
        input           cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin
                $display("[FAIL] %0s  (out_idx=%0d t=%0t)", name, out_idx, $time);
                err = err + 1;
            end
        end
    endtask

    // ------------------------------------------------------------ tick 发生器 --
    integer tick_div_cnt = 0;
    integer n            = 0;
    integer out_idx      = -1;
    reg     tick_d       = 1'b0;
    reg     tick_dd      = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            tick_div_cnt <= 0;
            sample_tick  <= 1'b0;
            tick_d       <= 1'b0;
            tick_dd      <= 1'b0;
        end else begin
            if (tick_div_cnt >= TICK_DIV-1) begin
                tick_div_cnt <= 0;
                sample_tick  <= 1'b1;
                n            <= n + 1;           // ★ 与 tick 同拍：模拟真实寄存源
            end else begin
                tick_div_cnt <= tick_div_cnt + 1;
                sample_tick  <= 1'b0;
            end
            tick_d  <= sample_tick;
            tick_dd <= tick_d;
            if (tick_dd) out_idx <= n;           // ★ 与 fx_out 生效时刻对齐
        end
    end

    // ------------------------------------------------------------ 激励源 -----
    integer src_mode = 0;                        // 0=静音 1=脉冲 2=直流 3=伪随机
    integer dc_val   = 0;
    integer imp_a    = -1;
    integer imp_b    = -1;

    // ★★ 激励必须【内联】写，不能"函数 + always @(*) / assign" ★★
    //  这是本 TB 最隐蔽的坑，前后烧掉很久才定位，记录如下：
    //    · 原来写成 `function src_of(k)` 里读 `src_mode/dc_val/imp_a/imp_b`，
    //      外面用 `always @(*) fx_in = src_of(n);` 驱动 —— **脉冲永远送不进 DUT**。
    //      实测证据：`imp_a=44069`、`src_mode=1`，但在 n=44069 那一拍 `fx_in` 仍是 0，
    //      于是"延迟/合唱模式事件日志 0 条"，看起来像 DUT 坏了。
    //    · 换成 `assign fx_in = src_of(n);` **仍然不行**（连续赋值也没救回来）。
    //    · 最小探针 tb_effects_probe.v 里表达式是**内联**的，从头到尾都是好的 ——
    //      这就是定位的关键对照。
    //  ⇒ 结论：让 `fx_in` 的驱动语句【直接读到所有相关变量】，内联写死。
    //     这比"函数复用"啰嗦，但确定性优先：TB 的职责是可复现的证据，不是优雅。
    //  ⚠️ 对项目其它 TB 的建议：激励源一律内联，或至少不要让函数体内部的全局读
    //     成为唯一的敏感来源。
    always @(*) begin
        if (src_mode == 2) begin
            fx_in = dc_val;
        end else if (src_mode == 3) begin
            fx_in = (n * 7919) ^ (n << 3);
        end else if (src_mode == 1) begin
            if ((n == imp_a) || (n == imp_b)) fx_in = 16'sd20000;
            else                              fx_in = 16'sd0;
        end else begin
            fx_in = 16'sd0;
        end
    end

    // ★★ 必须用 `assign`（连续赋值），不能用 `always @(*) fx_in = src_of(n);` ★★
    //  这是本 TB 最隐蔽的一个坑，花了很久才定位：
    //    `src_of` 是个**函数**，它在函数体里读了 `src_mode` / `dc_val` / `imp_a` / `imp_b`。
    //    而 `always @(*)` 的敏感表只保证包含【语句本身直接读到】的变量（这里是 n），
    //    **不保证包含函数体内部的全局读**（IEEE 1364-2001 §9.7.5 的措辞留下了解释空间，
    //     实测 ModelSim 就不把它们算进去）。
    //    后果：把 `imp_a = n` 改掉之后，fx_in 要等到**下一次 n 变化**才重算 ——
    //    而 n 变化时已经跨过了 imp_a 那一个采样点 ⇒ **脉冲永远没被送进 DUT**，
    //    表现为"延迟/合唱模式事件日志 0 条"，看起来像 DUT 坏了，其实 DUT 完全正常
    //    （最小探针 tb_effects_probe.v 里表达式是内联的，所以它一直是好的）。
    //    `assign` 的连续赋值**一定**把所有被读到的变量（含函数体内部）都纳入敏感表。
    //  ⚠️ 这条对本项目其它 TB 也有价值：凡是"把激励写成函数再组合驱动"的地方，
    //     都要用 `assign`，不要用 `always @(*)`。


    // =========================================================================
    //  事件日志（取代"窗口内找峰值"）
    // =========================================================================
    localparam integer LOG_MAX = 64;
    integer  log_n     = 0;                      // 已记录条数
    integer  log_rel   [0:LOG_MAX-1];            // 相对 log_base 的位置
    integer  log_val   [0:LOG_MAX-1];
    integer  log_base  = 0;
    integer  log_th    = 500;
    integer  log_chk   = 0;

    // 各探针
    integer byp_chk = 0, byp_cnt = 0, byp_bad = 0;
    integer sil_chk = 0, sil_bad = 0;
    integer wrap_chk = 0, wrap_bad = 0;
    integer tail_chk = 0;

    // 混响尾巴窗口
    localparam integer WIN_LEN = 5000;
    integer win_acc = 0, win_n = 0, win_i = 0;
    integer win_mean [0:15];

    always @(posedge clk) begin
        if (rst_n && tick_dd) begin
            // ---- 事件日志 ----
            if (log_chk && abs16(fx_out) >= log_th && log_n < LOG_MAX) begin
                log_rel[log_n] = out_idx - log_base;
                log_val[log_n] = fx_out;
                log_n = log_n + 1;
            end
            // ---- 旁路逐 bit 比对 ----
            if (byp_chk) begin
                byp_cnt = byp_cnt + 1;
                if (fx_out !== fx_in) begin
                    byp_bad = byp_bad + 1;
                    if (byp_bad <= 4)
                        $display("[info] 旁路不等: out_idx=%0d in=%0d out=%0d",
                                 out_idx, fx_in, fx_out);
                end
            end
            // ---- 静音探针 ----
            if (sil_chk && fx_out !== 16'sd0) sil_bad = sil_bad + 1;
            // ---- 回绕探针 ----
            if (wrap_chk && fx_out < -16'sd100) begin
                wrap_bad = wrap_bad + 1;
                if (wrap_bad <= 4)
                    $display("[info] 疑似回绕: out_idx=%0d out=%0d", out_idx, fx_out);
            end
            // ---- 混响尾巴窗口 ----
            if (tail_chk) begin
                win_acc = win_acc + abs16(fx_out);
                win_n   = win_n + 1;
                if (win_n == WIN_LEN) begin
                    if (win_i < 16) win_mean[win_i] = win_acc / WIN_LEN;
                    win_i   = win_i + 1;
                    win_acc = 0;
                    win_n   = 0;
                end
            end
        end
    end

    task log_reset;
        input integer base, th;
        begin
            log_n = 0; log_base = base; log_th = th; log_chk = 1;
        end
    endtask

    // ---- 混响内部轨迹诊断（保留：它是"全通限幅自持"这个 OPEN BUG 的现场证据）----
    //  现象：零输入下 ap2_y 在 ±32767 之间翻转，而梳状已经衰减到 0
    //        ⇒ 全通级进入【饱和限幅自持（limit cycle）】，尾巴因此不衰减。
    //  这正是参考实现 xls32 记录过的失效模式："hits the clamp rails, where it sticks"。
    always @(posedge clk) begin
        if (rst_n && tail_chk && tick_dd && (win_n == WIN_LEN-1))
            $display("[dbg_rev] 窗口%0d末: c0.d_rd=%0d c0.lp=%0d ap1_y=%0d ap2_y=%0d wet_s=%0d rev_y=%0d",
                     win_i, dut.u_c0.d_rd, dut.u_c0.lp,
                     dut.u_ap1.y, dut.u_ap2.y, dut.wet_s, dut.rev_y);
    end

    // （原 dbg2 脉冲窗口打点已删除 —— 它的使命是定位"激励函数化导致脉冲送不进 DUT"
    //   那个坑，结论已写进上面的注释。保留会污染 transcript。）

    // --------------------------------------------------------------- 主流程 --
    integer i, t;

    task run_samples;                            // 跑 k 个采样点（局部计数器！）
        input integer kk;
        integer j;
        begin
            j = 0;
            while (j < kk) begin @(posedge clk); if (sample_tick) j = j + 1; end
        end
    endtask

    task wait_clk;
        input integer kk;
        integer j;
        begin
            for (j = 0; j < kk; j = j + 1) @(posedge clk);
        end
    endtask

    // ★★ 冲刷延迟线 ★★
    //  三条效果支路**永远都在跑**（设计如此），所以上一个测试的激励会留在延迟线里
    //  污染下一个测试。
    //  ⚠️ 第一版用"拉低 rst_n 再放开"来冲刷 —— **这条路走不通**，原因很具体：
    //     audio_fx 的 rst_n 会重启【清缓冲发生器】，它要 32768 拍把全部延迟线扫 0，
    //     这 32768 拍里 clr_en 一直为 1 ⇒ 所有模块的写入与输出更新都被门控住。
    //     实测：冲刷完 wr_ptr 只走到 1856（≈(40020−32768)/4），
    //     而且模块刚被复位，节拍与激励的对齐关系全部失效 —— 脉冲响应测不出来。
    //  ⇒ 改成**灌静音**：不碰 rst_n，只把输入置 0 跑足够多的采样点，让延迟线自然
    //     把旧数据"流干净"。长度取 12000（> 最长延迟线 9766）。
    //     （静音必须写在任务内部，见下面那条注释。）
    task flush_lines;
        begin
            src_mode = 0;
            imp_a = -1; imp_b = -1;
            log_chk = 0;
            run_samples(12000);                  // > 最长延迟线 9766，自然流干净
        end
    endtask

    initial begin
        $display("");
        $display("=========================================================");
        $display(" tb_effects : audio_fx 硬件效果器（旁路/延迟/合唱/混响）验证");
        $display(" sample_tick = 1/%0d clk（生产 1/512）；位置断言以【采样点】为单位", TICK_DIV);
        $display("=========================================================");

        rst_n = 1'b0; fx_sel = 2'b00; param = 7'd0;
        wait_clk(20);
        rst_n = 1'b1;
        wait_clk(40000);
        $display("\n[info] 复位 + 清缓冲完成（out_idx=%0d）", out_idx);

        // ================= 测试 0: 清缓冲 —— 零输入必须恒 0 =================
        $display("\n--- 测试 0: 清缓冲后零输入时输出恒 0（未初始化 BSRAM 探针）---");
        fx_sel = 2'b11; param = 7'd100; src_mode = 0;
        sil_bad = 0; sil_chk = 1;
        run_samples(20000);
        sil_chk = 0;
        chk("混响模式、零输入 20000 采样点，输出恒为 0（无 X / 无垃圾）", sil_bad == 0);
        $display("[info] 非零（含 X）输出计数 = %0d", sil_bad);

        // ==================== 测试 1: 旁路逐 bit 直通 ======================
        $display("\n--- 测试 1: fx_sel=00 旁路 → fx_out 必须逐 bit 等于 fx_in ---");
        fx_sel = 2'b00; src_mode = 3;
        run_samples(20);
        byp_cnt = 0; byp_bad = 0; byp_chk = 1;
        run_samples(2000);
        byp_chk = 0;
        chk("旁路 2000 个采样点全部逐 bit 相等", (byp_bad == 0) && (byp_cnt == 2000));
        $display("[info] 比对 %0d 点，不等 %0d 点", byp_cnt, byp_bad);

        // ==================== 测试 2: 延迟脉冲响应 =========================
        // param=0 ⇒ LEN = 9766 采样点 ≈ 100.0 ms
        //   干声脉冲 = 20000；第 1 次回声 = (20000×154)>>8 = 12031
        //   写回值 = (20000×96)>>8 = 7500 ⇒ 第 2 次回声 = (7500×154)>>8 = 4511
        $display("\n--- 测试 2: 延迟模式脉冲响应（param=0 ⇒ 延迟 9766 采样点 ≈100 ms）---");
        flush_lines();
        fx_sel = 2'b01; param = 7'd0;
        run_samples(50);
        src_mode = 1; imp_a = n; imp_b = -1;
        $display("[info] 脉冲注入于采样点 %0d（相对位置 0 = 干声）", imp_a);
        $display("[dbg] 测试2开始: fx_sel=%b param=%0d src_mode=%0d imp_a=%0d clr_en=%b wr_ptr=%0d",
                 fx_sel, param, src_mode, imp_a, dut.clr_en, dut.u_echo.wr_ptr);
        log_reset(imp_a, 500);
        run_samples(6);
        $display("[dbg] 脉冲后 6 点: n=%0d fx_in=%0d fx_out=%0d echo.d_rd=%0d echo.y=%0d",
                 n, fx_in, fx_out, dut.u_echo.d_rd, dut.u_echo.y);
        run_samples(21000 - 6);
        $display("[dbg] 测试2结束: echo.wr_ptr=%0d echo.d_rd=%0d echo.y=%0d clr_en=%b",
                 dut.u_echo.wr_ptr, dut.u_echo.d_rd, dut.u_echo.y, dut.clr_en);
        log_chk = 0;
        $display("[info] 事件日志 %0d 条:", log_n);
        for (i = 0; i < ((log_n < 6) ? log_n : 6); i = i + 1)
            $display("        事件%0d: 相对位置=%0d 值=%0d", i, log_rel[i], log_val[i]);
        chk("干声脉冲记录在相对位置 0（对齐自检）",
            (log_n >= 1) && (abs16(log_rel[0]) <= 1) && (abs16(log_val[0]) >= 19000));
        chk("第 1 次回声出现在相对 9766±2", (log_n >= 2) &&
            (log_rel[1] >= 9764) && (log_rel[1] <= 9768));
        chk("第 1 次回声幅度 = 12031±40", (log_n >= 2) &&
            (abs16(log_val[1] - 16'sd12031) <= 40));
        chk("第 2 次回声出现在相对 19532±4", (log_n >= 3) &&
            (log_rel[2] >= 19528) && (log_rel[2] <= 19536));
        chk("第 2 次回声幅度 = 4511±40", (log_n >= 3) &&
            (abs16(log_val[2] - 16'sd4511) <= 40));

        // ==================== 测试 3: 合唱的延迟确实被 LFO 调制 =============
        $display("\n--- 测试 3: 合唱 —— 两个 LFO 相位下的回声延迟必须不同 ---");
        flush_lines();
        fx_sel = 2'b10; param = 7'd64;               // 湿 0.5，调制 ±128 采样点
        run_samples(50);
        src_mode = 1;
        imp_a = n; imp_b = -1;
        log_reset(imp_a, 500);
        run_samples(2200);
        log_chk = 0;
        t = (log_n >= 2) ? log_rel[1] : -1;          // 相位 A 的回声延迟
        $display("[info] 相位 A: 事件 %0d 条，回声延迟=%0d 值=%0d",
                 log_n, t, (log_n >= 2) ? log_val[1] : 0);
        chk("相位 A 的回声延迟落在 700..1300（合唱延迟量级正确）",
            (log_n >= 2) && (t >= 700) && (t <= 1300));
        chk("相位 A 回声幅度 = 10000±400（湿 0.5 × 20000）",
            (log_n >= 2) && (abs16(log_val[1] - 16'sd10000) <= 400));

        imp_a = -1;
        run_samples(58000);                          // 推进到 LFO 另一相位
        imp_b = n;
        log_reset(imp_b, 500);
        run_samples(2200);
        log_chk = 0;
        $display("[info] 相位 B: 事件 %0d 条，回声延迟=%0d 值=%0d",
                 log_n, (log_n >= 2) ? log_rel[1] : -1, (log_n >= 2) ? log_val[1] : 0);
        chk("相位 B 的回声延迟落在 700..1300",
            (log_n >= 2) && (log_rel[1] >= 700) && (log_rel[1] <= 1300));
        chk("两相位回声延迟相差 > 100 采样点（证明延迟被 LFO 调制）",
            (log_n >= 2) && (abs16(log_rel[1] - t) > 100));
        $display("[info] 两相位延迟差 = %0d 采样点（LFO 调制范围 ±128）",
                 (log_n >= 2) ? (log_rel[1] - t) : 0);

        // ==================== 测试 4: 混响尾巴必须持续衰减 ==================
        // 用**直流突发**当激励：直流通过阻尼低通不衰减，尾巴衰减完全由梳状反馈 g
        // 决定，曲线干净。（参考实现提醒："持续正弦是最差的重混响测试信号"——
        // 它会停在某个梳状反共振点，看着像坏了。直流突发没这个毛病。）
        $display("\n--- 测试 4: 混响（param=100 ⇒ g≈0.895）尾巴衰减 ---");
        flush_lines();
        fx_sel = 2'b11; param = 7'd100;
        src_mode = 2; dc_val = 20000;
        run_samples(8000);                           // 直流突发
        src_mode = 0;                                // 立刻静音，只看尾巴
        win_i = 0; win_acc = 0; win_n = 0; tail_chk = 1;
        run_samples(WIN_LEN*16);
        tail_chk = 0;
        $display("[info] 混响尾巴（每窗口 %0d 采样点的平均幅度）:", WIN_LEN);
        for (i = 0; i < 16; i = i + 1)
            $display("        窗口%2d: 平均幅度 %0d", i, win_mean[i]);
        $display("[dbg3] 尾巴结束时内部: fx_in=%0d rev_in=%0d c0.d_rd=%0d c0.lp=%0d ap1_y=%0d ap2_y=%0d wet_s=%0d rev_y=%0d clr_en=%b",
                 fx_in, dut.rev_in, dut.u_c0.d_rd, dut.u_c0.lp,
                 dut.u_ap1.y, dut.u_ap2.y, dut.wet_s, dut.rev_y, dut.clr_en);
        chk("尾巴确实存在（窗口1 平均幅度 > 50）", win_mean[1] > 50);
        chk("尾巴在衰减（窗口8 < 窗口1 的 70%）", win_mean[8] < (win_mean[1]*7/10));
        chk("尾巴在继续衰减（窗口11 < 窗口8）", win_mean[11] < win_mean[8]);
        chk("整个观测期衰减明显（窗口11 < 窗口1 的 50%）", win_mean[11] < (win_mean[1]/2));
        chk("尾巴没有发散（窗口11 < 窗口0）", win_mean[11] < win_mean[0]);

        // ==================== 测试 5: 满幅输入下的幅度有界 ==================
        $display("\n--- 测试 5: 满幅正直流输入，四种模式都不许回绕 ---");
        wrap_bad = 0; wrap_chk = 1; dc_val = 32767; src_mode = 2;
        for (i = 0; i < 4; i = i + 1) begin
            fx_sel = i[1:0]; param = 7'd127;
            run_samples(30000);
        end
        wrap_chk = 0;
        chk("四种模式 × 满幅直流 12 万采样点，无回绕（无异常负值）", wrap_bad == 0);
        $display("[info] 疑似回绕计数 = %0d", wrap_bad);

        fx_sel = 2'b11; param = 7'd127; dc_val = 32767;
        run_samples(50000);
        chk("混响满幅直流 → 输出仍为正（饱和而非回绕成负）", fx_out > 16'sd0);
        $display("[info] 混响满幅直流下的稳态输出 = %0d", fx_out);

        // ============================== 汇总 ==============================
        $display("");
        $display("=========================================================");
        if (err == 0) $display("=== tb_effects: PASS (0 个错误) ===");
        else          $display("=== tb_effects: FAIL (%0d 个错误) ===", err);
        $display("=========================================================");
        $stop;
    end

    // -------------------------------------------------------------- 看门狗 ---
    initial begin
        #400_000_000;
        $display("[FAIL] 仿真超时（看门狗 400 ms）");
        $display("=== tb_effects: FAIL (timeout) ===");
        $finish;
    end

endmodule

`default_nettype wire
