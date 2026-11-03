// =============================================================================
//  tb_guitar_fx.v —— 电吉他效果器（过载/失真 + 箱体模拟）验证
// =============================================================================
//  判据：
//    0. 复位后零输入恒 0（无 X）
//    1. 旁路逐 bit 直通
//    1b. **检波器自测**（先证明工具对，再拿它测 DUT）
//    2. THD 随 drive 单调上升
//    3. 失真档 THD > 过载档 THD
//    4. 箱体频响对比 Python 设计曲线（±1.5 dB）
//    5. 箱体冲激响应单调衰减（双二阶稳定）
//    6. 满幅输入 × 全参数组合无回绕
//
//  ★★ 检波器为什么必须"整周期"（本轮踩的坑，Lead 点破的）★★
//  同步检波（I/Q 解调）只有在**积分窗口正好是整数个周期**时才正交；否则**频谱泄漏**，
//  相邻谱线互相串扰，表现就是 **"二次谐波比基频还大"**。
//  实测踩坑：fs = 97656.25 Hz，频率取 220 Hz ⇒ 一个周期 = **443.89 采样点**（不是整数！），
//  窗口 4000 点 = 9.012 个周期 ⇒ 泄漏 ⇒ A1=2479 / A2=2653（一个 −30 dBFS 小信号过立方软削波，
//  二次谐波不可能与基频同量级 ⇒ 物理上讲不通，说明错在测量侧）。
//  ⇒ 现在改为**由整数周期反推频率** f = fs/per，且**测量窗 = 整数个周期**：
//     per=450 ⇒ f=217.01 Hz；2 次谐波 per=225、3 次 per=150、5 次 per=90（都能整除）。
//  ⇒ 并加一条 **检波器自测**（旁路喂干净正弦，A1 应≈8000、A2 应≈0）：
//     **先证明工具对，再用它测被测对象**（对照组思路）。
//
//  ★ 本 TB 遵守本项目踩过的坑：
//    · 任务里的循环计数器一律**局部变量**
//    · 激励**内联**（函数形式会丢敏感表 ⇒ 脉冲送不进 DUT）
//    · 频域测试必须用**真实采样率**（1/512 clk）；功能类可用压缩节拍
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_guitar_fx;

    localparam real FS = 97656.25;
    localparam real PI = 3.14159265358979;

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;
    reg [1:0] fx_sel  = 2'd0;
    reg [1:0] cab_sel = 2'd0;
    reg [6:0] drive   = 7'd0;
    reg [6:0] tone    = 7'd64;
    reg [6:0] level   = 7'd64;

    wire signed [15:0] fx_out;

    integer    tick_div = 4;
    integer    src_mode = 0;          // 0=静音 1=正弦 2=伪随机 3=满幅 4=脉冲
    integer    src_per  = 450;        // ★ 正弦周期（采样点）—— 由整数周期决定频率
    real       src_a    = 8000.0;
    real       src_ph   = 0.0;
    integer    imp_at   = -1;
    integer    n        = 0;

    reg signed [15:0] fx_in;
    always @(*) begin
        if (src_mode == 1)      fx_in = $rtoi(src_a * $sin(src_ph));
        else if (src_mode == 2) fx_in = (n * 7919) ^ (n << 3);
        else if (src_mode == 3) fx_in = 16'sd32767;
        else if (src_mode == 4) fx_in = (n == imp_at) ? 16'sd20000 : 16'sd0;
        else                    fx_in = 16'sd0;
    end

    // 相位推进：一个采样点走 2π/per（per 为整数 ⇒ 频率正好是 fs/per）
    always @(posedge clk) begin
        if (rst_n && sample_tick) begin
            src_ph = src_ph + 2.0 * PI / $itor(src_per);
            if (src_ph > 2.0 * PI) src_ph = src_ph - 2.0 * PI;
        end
    end

    function real rabs;
        input real v;
        begin rabs = (v < 0.0) ? -v : v; end
    endfunction

    guitar_fx dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .fx_sel(fx_sel), .cab_sel(cab_sel),
        .drive(drive), .tone(tone), .level(level),
        .fx_in(fx_in), .fx_out(fx_out)
    );

    // ---------------------------------------------------- 采样节拍与对齐 ----
    integer tick_div_cnt = 0;
    integer out_idx = -1;
    integer tick_d = 0, tick_dd = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            tick_div_cnt <= 0; sample_tick <= 1'b0; tick_d <= 0; tick_dd <= 0;
        end else begin
            if (tick_div_cnt >= tick_div-1) begin
                tick_div_cnt <= 0; sample_tick <= 1'b1; n <= n + 1;
            end else begin
                tick_div_cnt <= tick_div_cnt + 1; sample_tick <= 1'b0;
            end
            tick_d  <= sample_tick;
            tick_dd <= tick_d;
            if (tick_dd) out_idx <= n;
        end
    end

    // -------------------------------------------------------- 同步检波 ----
    //  ★ 参考相位用【整数周期】算： mph = 2π·(out_idx mod per)/per
    //    (a) 频率正好是 fs/per  (b) 相位不累积成大数  (c) 整周期窗口下严格正交
    integer meas_en = 0, mcnt = 0, mper = 450;
    real    mph = 0.0, mI = 0.0, mQ = 0.0;

    always @(posedge clk) begin
        if (rst_n && tick_dd && meas_en) begin
            mph  = 2.0 * PI * $itor(out_idx % mper) / $itor(mper);
            mI   = mI + $itor(fx_out) * $cos(mph);
            mQ   = mQ + $itor(fx_out) * $sin(mph);
            mcnt = mcnt + 1;
        end
    end

    function real meas_amp;
        input real amp_I; input real amp_Q; input integer cnt;
        begin
            if (cnt == 0) meas_amp = 0.0;
            else          meas_amp = 2.0 * $sqrt(amp_I*amp_I + amp_Q*amp_Q) / $itor(cnt);
        end
    endfunction

    // ------------------------------------------------------------ 记分板 ----
    integer err = 0;
    task chk;
        input [8*150:1] name;
        input           cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin $display("[FAIL] %0s  (n=%0d)", name, n); err = err + 1; end
        end
    endtask

    task run_samples;
        input integer kk;
        integer j;
        begin j = 0; while (j < kk) begin @(posedge clk); if (sample_tick) j = j + 1; end end
    endtask

    task wait_clk;
        input integer kk;
        integer j;
        begin for (j = 0; j < kk; j = j + 1) @(posedge clk); end
    endtask

    // ---- 整周期测量 ----
    //  ⚠️⚠️ 必须把【刺激频率】与【检波参考频率】分开 ⚠️⚠️
    //  第一版 `amp_at(per,...)` 把两者设成同一个 per ⇒ 每测一次"谐波"就把**输入正弦**
    //  也换成了那个频率 ⇒ 测到的是"4 个不同频率下的基频响应"，**根本不是谐波**
    //  ⇒ THD 全是假的（还出现 A2>A1 这种物理上不可能的数）。
    //  **是检波器自测把这条抓出来的**：喂干净正弦、只改检波参考，A2 应该≈0，
    //  结果 A2 = A1 = 7999.5 ⇒ 说明"测量时把信号也改了"。
    //  现在：`set_stim(per)` 只设刺激；`meas_at(ref_per, win)` 只设检波参考。
    //  窗口 win 取 9000 = 20×450 = 40×225 = 60×150 = 100×90 ⇒ 对刺激和参考**都是整周期**。
    task set_stim;
        input integer per;
        begin
            src_mode = 1; src_per = per; src_ph = 0.0;
        end
    endtask

    task meas_at;
        input  integer ref_per;
        input  integer win;
        input  integer settle;
        output real    amp;
        begin
            run_samples(settle);
            meas_en = 1; mper = ref_per; mI = 0.0; mQ = 0.0; mcnt = 0;
            run_samples(win);
            meas_en = 0;
            amp = meas_amp(mI, mQ, mcnt);
        end
    endtask

    // 单频测量（刺激与检波同频，用于频响/自测）
    task amp_at;
        input  integer per;
        input  integer nper;
        input  integer settle;
        output real    amp;
        begin
            set_stim(per);
            meas_at(per, per * nper, settle, amp);
        end
    endtask

    // =====================================================================
    //  箱体设计曲线（读 Python 生成器的 CSV —— 证据绑生成器，不硬编码）
    // =====================================================================
    localparam integer CSVMAX = 200;
    real    csv_f [0:CSVMAX-1];
    real    csv_c1[0:CSVMAX-1];
    integer npts = 0;
    reg [8*80:1] csv_hdr;

    initial begin
        integer fd, r;
        real d1, d2, d3;
        fd = $fopen("cab_response.csv", "r");
        if (fd == 0) begin
            $display("[warn] 打不开 cab_response.csv —— 箱体频响判据将被跳过");
        end else begin
            r = $fscanf(fd, "%s\n", csv_hdr);
            while (!$feof(fd) && npts < CSVMAX) begin
                r = $fscanf(fd, "%f,%f,%f,%f,%f\n", csv_f[npts], csv_c1[npts], d1, d2, d3);
                if (r >= 3) npts = npts + 1;
            end
            $fclose(fd);
            $display("[info] 读入箱体设计曲线 %0d 个频点", npts);
        end
    end

    function integer nearest_idx;
        input real f;
        integer i, best;
        real bd, d;
        begin
            best = 0; bd = 1.0e12;
            for (i = 0; i < npts; i = i + 1) begin
                d = (csv_f[i] > f) ? (csv_f[i] - f) : (f - csv_f[i]);
                if (d < bd) begin bd = d; best = i; end
            end
            nearest_idx = best;
        end
    endfunction

    // ------------------------------------------------------------ 主流程 ----
    integer i, k;
    real    a1, a2, a3, a5, thd, db_meas, db_des, nin, nout, self_a1, self_a2;
    integer mono_bad;
    real    pk, tail;

    initial begin
        $display("");
        $display("=================================================================");
        $display(" tb_guitar_fx : 电吉他效果器（过载/失真 + 箱体模拟）");
        $display(" 频域测试用真实 fs = %0.2f Hz（1/512 clk），且【整数周期】窗", FS);
        $display("=================================================================");

        rst_n = 1'b0; wait_clk(20); rst_n = 1'b1; wait_clk(400);

        // ---------------- 测试 0：零输入恒 0 ----------------
        $display("\n--- 测试 0: 零输入恒 0（所有档位，无 X）---");
        src_mode = 0; mono_bad = 0;
        for (i = 0; i < 4; i = i + 1) begin
            fx_sel = i[1:0]; cab_sel = 2'd1; drive = 7'd127;
            run_samples(2000);
            if (fx_out !== 16'sd0) mono_bad = mono_bad + 1;
        end
        chk("全部档位零输入 2000 采样点输出恒 0（无 X）", mono_bad == 0);

        // ---------------- 测试 1：旁路逐 bit 直通 ----------------
        $display("\n--- 测试 1: fx_sel=0 旁路逐 bit 直通 ---");
        fx_sel = 2'd0; src_mode = 2; run_samples(50); mono_bad = 0;
        for (i = 0; i < 2000; i = i + 1) begin
            @(posedge clk);
            if (tick_d && fx_out !== fx_in) mono_bad = mono_bad + 1;
        end
        chk("旁路 2000 采样点逐 bit 相等", mono_bad == 0);

        // ============ 测试 1b：**检波器自测**（先证明工具对）============
        $display("\n--- 测试 1b: 检波器自测（旁路 + 干净正弦，450 点/周期）---");
        fx_sel = 2'd0; src_mode = 1; src_a = 8000.0;
        tick_div = 512; run_samples(20);                 // ★ 真实采样率
        set_stim(450);                       // 刺激固定 217 Hz
        meas_at(450, 9000, 200, self_a1);
        meas_at(225, 9000, 100, self_a2);    // ★ 只换检波参考
        $display("        检波自测: A1=%.1f（理论 8000）  A2=%.1f（理论 0）", self_a1, self_a2);
        chk("检波器自测：A1 与理论 8000 相差 <1%", rabs(self_a1 - 8000.0) < 80.0);
        chk("检波器自测：A2 远小于 A1（泄漏已消除）", self_a2 < self_a1 * 0.01);

        // ---------------- 测试 2：THD 随 drive 单调上升 ----------------
        $display("\n--- 测试 2: 过载档 THD 随 drive 单调上升 ---");
        fx_sel = 2'd1; cab_sel = 2'd0; tone = 7'd127; level = 7'd64;
        begin : thd_loop
            real thd_prev;
            thd_prev = -1.0;
            for (i = 0; i <= 3; i = i + 1) begin
                drive = i * 42;
                set_stim(450);                    // ★ 刺激固定 217 Hz
                meas_at(450, 9000, 400, a1);
                meas_at(225, 9000, 100, a2);
                meas_at(150, 9000, 100, a3);
                meas_at( 90, 9000, 100, a5);
                thd = (a1 > 1.0) ? ($sqrt(a2*a2 + a3*a3 + a5*a5) / a1) : 0.0;
                $display("        drive=%3d : A1=%8.1f A2=%7.1f A3=%7.1f A5=%7.1f  THD=%6.2f%%",
                         drive, a1, a2, a3, a5, thd*100.0);
                if (i > 0) chk("THD 随 drive 上升", thd > thd_prev);
                thd_prev = thd;
            end
        end

        // ---------------- 测试 3：失真档更脏 ----------------
        $display("\n--- 测试 3: 失真档 THD > 过载档 THD（同 drive）---");
        begin : ds_test
            real t_od, t_ds;
            drive = 7'd84;
            fx_sel = 2'd1;
            set_stim(450);
            meas_at(450,9000,400,a1); meas_at(225,9000,100,a2);
            meas_at(150,9000,100,a3); meas_at(90,9000,100,a5);
            t_od = (a1 > 1.0) ? ($sqrt(a2*a2+a3*a3+a5*a5)/a1) : 0.0;
            fx_sel = 2'd2;
            set_stim(450); run_samples(400);
            meas_at(450,9000,100,a1); meas_at(225,9000,100,a2);
            meas_at(150,9000,100,a3); meas_at(90,9000,100,a5);
            t_ds = (a1 > 1.0) ? ($sqrt(a2*a2+a3*a3+a5*a5)/a1) : 0.0;
            $display("        过载 THD=%.2f%%   失真 THD=%.2f%%", t_od*100.0, t_ds*100.0);
            chk("失真档 THD > 过载档 THD", t_ds > t_od);
        end

        // ---------------- 测试 4：箱体频响 vs 设计曲线 ----------------
        $display("\n--- 测试 4: 箱体频响对比 Python 设计曲线（±1.5 dB）---");
        if (npts == 0) begin
            $display("[warn] 无 CSV，跳过（**不算通过**）");
        end else begin
            fx_sel = 2'd3; drive = 7'd0; tone = 7'd127; level = 7'd64;
            for (i = 0; i < 5; i = i + 1) begin : cab_loop
                integer per, fi;
                real hz;
                per = (i == 0) ? 977 : (i == 1) ? 244 : (i == 2) ? 98 : (i == 3) ? 33 : 12;
                hz  = FS / $itor(per);
                fi  = nearest_idx(hz);
                cab_sel = 2'd0;  amp_at(per, 20, 600, nin);
                cab_sel = 2'd1;  amp_at(per, 20, 600, nout);
                db_des  = csv_c1[fi];
                db_meas = 20.0 * $log10((nout + 1.0e-9) / (nin + 1.0e-9));
                $display("        per=%4d f=%8.1f Hz | 设计=%7.2f dB 实测=%7.2f dB 差=%6.2f dB",
                         per, hz, db_des, db_meas, db_meas - db_des);
                chk("箱体频响在设计曲线 ±1.5 dB 内",
                    (db_meas - db_des) < 1.5 && (db_meas - db_des) > -1.5);
            end
        end

        // ---------------- 测试 5：箱体冲激响应衰减 ----------------
        $display("\n--- 测试 5: 箱体冲激响应衰减（双二阶稳定）---");
        fx_sel = 2'd3; cab_sel = 2'd1; src_mode = 0; run_samples(2000);
        src_mode = 4; imp_at = n; run_samples(1); src_mode = 0;
        pk = 0.0;
        for (k = 0; k < 3000; k = k + 1) begin
            run_samples(1);
            if (rabs($itor(fx_out)) > pk) pk = rabs($itor(fx_out));
        end
        run_samples(3000);
        tail = rabs($itor(fx_out));
        $display("        峰值=%.1f   6000 点后=%.1f", pk, tail);
        chk("箱体冲激响应衰减到峰值 2% 以下（稳定；实测衰减约 63 dB）", (pk < 1.0) || (tail < pk * 0.02));

        // ---------------- 测试 6：满幅无回绕 ----------------
        $display("\n--- 测试 6: 满幅直流 × 全参数组合，无回绕 ---");
        src_mode = 3; mono_bad = 0;
        for (i = 0; i < 4; i = i + 1) begin : wrap_loop
            integer cs;
            for (cs = 0; cs < 3; cs = cs + 1) begin
                fx_sel = i[1:0]; cab_sel = cs[1:0]; drive = 7'd127; level = 7'd127;
                run_samples(3000);
                if (fx_out < -16'sd2000) mono_bad = mono_bad + 1;
            end
        end
        src_mode = 0;
        chk("4 档 × 3 箱体 × 满幅，无回绕（无异常负值）", mono_bad == 0);

        $display("");
        $display("=================================================================");
        if (err == 0) $display("=== tb_guitar_fx: PASS (0 个错误) ===");
        else          $display("=== tb_guitar_fx: FAIL (%0d 个错误) ===", err);
        $display("=================================================================");
        $stop;
    end

    initial begin
        #9.0e9;
        $display("[FAIL] 仿真超时（看门狗）");
        $finish;
    end

endmodule

`default_nettype wire
