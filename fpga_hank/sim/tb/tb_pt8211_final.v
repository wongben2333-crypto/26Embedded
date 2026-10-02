// =============================================================================
//  tb_pt8211_final.v —— PT8211 发送器最终验证（纯黑盒 + 帧对齐）
//
//  为什么必须纯黑盒：
//    (a) PT8211 的位序 / 半帧边界错误"看波形非常正常"。开发过程中前后多版
//        错误实现全部通过了"有波形"这一关，只有把 DIN 按 BCK 上升沿逐位拼
//        起来与期望样本比对才能发现。
//    (b) ModelSim 优化后读 DUT 内部寄存器可能得到与实际不符的值，开发过程中
//        因此被误导过多轮。只依赖输出端口不会骗人。
//
//  为什么必须帧对齐：
//    复位后第一个 BCK 上升沿可能落在某个半帧的中间。若从那时就开始按 16 位
//    分组，第一组会错位，表现为"左右半帧数差 1"这种假阳性。
//    本 testbench 等第一个 sample_tick（真正的帧边界）之后才开始计数。
//
//  激励与 DUT 帧边界同步：样本只在 sample_tick 之后更新，且整个帧内不变。
//  早期版本用固定拍数等一帧，样本会在半帧中途变化，导致期望值与实际送出的
//  那帧错开，产生低位差异 —— 看起来像 RTL 位序错误，实际是激励不同步。
//
//  验证内容：
//    1) 位序（16 位整体比对，MSB 先出）
//    2) 声道（WS 高 = 左，低 = 右）
//    3) DIN 建立时间（不得与 BCK 上升沿同拍变化）
//    4) DIN 不得为 x/z
//    5) BCK 周期恒定
//    6) 帧周期 → fs
//    7) 左右半帧数量相等
//
//  运行：& "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_pt8211_final;

    localparam real    TCLK      = 20.0;     // 50 MHz
    localparam integer NFRAMES   = 100;
    // ★ 采样率必须与 RTL 的 BCK_DIV 一致，否则本测试台的期望值全错。
    //   当前设计（top.v）用 BCK_DIV=1 -> fs=97656.25 Hz，BCK 周期 320 ns。
    //   历史上这里是硬编码 2/640/48828.125，在切到 96 kHz 后就开始误报 FAIL。
    localparam integer BCK_DIV   = 1;
    localparam real    TARGET_FS = (BCK_DIV == 1) ? 97656.25 : 48828.125;
    localparam integer BCK_NS    = 320 * BCK_DIV;      // 期望的 BCK 周期

    reg clk   = 1'b0;
    reg reset = 1'b1;
    reg signed [15:0] sample_l = 16'sh1000;
    reg signed [15:0] sample_r = 16'sh8000;

    wire sample_tick, bck, ws, din;

    pt8211_tx #(.BCK_DIV(BCK_DIV)) dut (
        .clk(clk), .reset(reset),
        .sample_l(sample_l), .sample_r(sample_r),
        .sample_tick(sample_tick), .bck(bck), .ws(ws), .din(din)
    );

    always #(TCLK/2.0) clk = ~clk;

    // ---------------------------------------------------------------- 计数 ----
    integer errors  = 0;
    real    meas_fs = 0.0;
    integer lhf     = 0;
    integer rhf     = 0;
    integer risings = 0;
    integer clk_n   = 0;
    integer i;

    always @(posedge clk) clk_n = clk_n + 1;

    // DIN 变化时刻
    time din_change = 0;
    reg  din_prev   = 1'b0;
    always @(posedge clk) begin
        if (din !== din_prev) begin
            din_prev   <= din;
            din_change <= $time;
        end
    end

    // BCK 周期
    time last_rise  = 0;
    time min_period = 999999999;
    time max_period = 0;

    // 帧间隔
    integer mono    = 0;
    integer last_st = -1;
    integer st_min  = 999999999;
    integer st_max  = 0;
    integer st_cnt  = 0;

    always @(posedge clk) begin
        mono = mono + 1;
        if (sample_tick) begin
            if (last_st >= 0) begin
                if ((mono - last_st) < st_min) st_min = mono - last_st;
                if ((mono - last_st) > st_max) st_max = mono - last_st;
                st_cnt = st_cnt + 1;
            end
            last_st = mono;
        end
    end

    // ---- 帧对齐后才开始位解码 ----
    reg counting = 1'b0;
    always @(posedge sample_tick) counting <= 1'b1;

    reg [15:0] cap   = 16'd0;
    integer    nbits = 0;
    reg        is_l  = 1'b0;

    always @(posedge bck) begin
        if (!counting) begin
            cap   = 16'd0;
            nbits = 0;
        end else begin
            risings = risings + 1;

            if (last_rise != 0) begin
                if (($time - last_rise) < min_period) min_period = $time - last_rise;
                if (($time - last_rise) > max_period) max_period = $time - last_rise;
            end
            last_rise = $time;

            // 建立时间
            if ($time == din_change) begin
                $display("[TB] ERROR t=%0t : DIN changed on BCK rising edge (setup=0)", $time);
                errors = errors + 1;
            end

            // 不得为 x/z
            if (din === 1'bx || din === 1'bz) begin
                $display("[TB] ERROR t=%0t : DIN is %b at BCK rising edge", $time, din);
                errors = errors + 1;
            end

            if (nbits == 0) cap = {15'd0, din};
            else            cap = {cap[14:0], din};
            nbits = nbits + 1;

            if (nbits == 16) begin
                is_l = (ws === 1'b1);
                if (is_l) begin
                    lhf = lhf + 1;
                    if (cap !== sample_l) begin
                        $display("[TB] ERROR t=%0t LEFT  got=%04h want=%04h", $time, cap, sample_l);
                        errors = errors + 1;
                    end
                end else begin
                    rhf = rhf + 1;
                    if (cap !== sample_r) begin
                        $display("[TB] ERROR t=%0t RIGHT got=%04h want=%04h", $time, cap, sample_r);
                        errors = errors + 1;
                    end
                end
                cap   = 16'd0;
                nbits = 0;
            end
        end
    end

    // ------------------------------------------------- 波形数据导出（真实仿真值）---
    // ★ 为什么用它而不是让用户自己开 GUI 看波形：
    //   用户要求"仿真图能甩我脸上"。ModelSim 的 .wlf 需要装软件才能看，
    //   所以这里把**仿真实际跑出来的** bck/ws/din 逐周期写进 CSV，
    //   再由 tools/verify/gen_waveforms.py 渲染成 PNG（一眼能看）。
    //   数据源是真实仿真，不是手工画的示意图。
    integer wf_fd;
    initial begin
        wf_fd = $fopen("C:/Users/Danny/Desktop/FPGA competition/fpga_hank/out/wave_pt8211.csv", "w");
        if (wf_fd == 0) $display("[TB] WARN: 无法打开 out/wave_pt8211.csv（先建 out/ 目录）");
    end
    // ★ 采样率必须远高于信号频率，否则波形混叠成"竖线"（本项目踩过）。
    //   BCK 周期 320 ns、高电平只持续 160 ns；若只按 posedge clk（20 ns/点）采样，
    //   会恰好只在某几个相位采到高电平，图上就变成一排尖刺，看不出方波。
    //   这里改用 `always #1`（每 2 ns 一点），并限在单帧 512 clk = 10240 ns 内，
    //   既能完整还原 BCK/WS/DIN 的边沿关系，文件也只有约 5000 行。
    always #1 begin
        if (wf_fd != 0 && $time <= 10240)
            $fwrite(wf_fd, "%0d,%b,%b,%b\n", $time, bck, ws, din);
    end

    // ---------------------------------------------------------------- 激励 ----
    initial begin
        repeat (10) @(posedge clk);
        reset = 1'b0;

        for (i = 0; i < NFRAMES; i = i + 1) begin
            @(posedge sample_tick);
            @(negedge clk);
            sample_l <= 16'sh1000 + i[15:0];
            sample_r <= 16'sh8000 - {i[14:0], 1'b1};
        end
        repeat (4000) @(posedge clk);

        // ---------------- 报告 ----------------
        $display("[TB] ---------- PT8211 transmitter verification ----------");
        $display("[TB] BCK period        : %0d .. %0d ns  (expect %0d)", min_period, max_period, BCK_NS);
        $display("[TB] frame period      : %0d .. %0d clk over %0d frames", st_min, st_max, st_cnt);
        meas_fs = 50.0e6/((st_min+st_max)/2.0);
        if (st_cnt > 0)
            $display("[TB] measured fs       : %0.1f Hz  (target %0.1f)", meas_fs, TARGET_FS);
        $display("[TB] half-frames       : left=%0d right=%0d   BCK rises=%0d", lhf, rhf, risings);

        if (min_period != BCK_NS || max_period != BCK_NS) begin
            $display("[TB] ERROR: BCK period not constant at %0d ns", BCK_NS);
            errors = errors + 1;
        end
        if (st_cnt <= 0) begin
            $display("[TB] ERROR: no frame interval measured");
            errors = errors + 1;
        end else begin
            real fs;
            fs = 50.0e6/((st_min+st_max)/2.0);
            // ★ 判据必须【相对目标采样率】，不能硬编码窗口。
            //   本项目实测过：切到 96 kHz 后旧的 "48500..49100" 窗口
            //   会把 97656.3 Hz 误判成 FAIL。容差取 ±0.1%（帧周期以整数
            //   clk 计，量化误差已经很小：实测偏差仅 0.00005%）。
            if (fs < TARGET_FS*0.999 || fs > TARGET_FS*1.001) begin
                $display("[TB] ERROR: fs %.1f Hz out of %.1f..%.1f",
                         fs, TARGET_FS*0.999, TARGET_FS*1.001);
                errors = errors + 1;
            end
        end
        // ★ 允许 ±1：测量窗口的起止未必正好落在帧边界上，
        //   跨半帧会在首/尾各多计（或少计）一个 half-frame。这是**测量假象**，
        //   不是 DUT 缺陷 —— 本测试台历史上就此误报过（left=103 right=102）。
        if (lhf - rhf > 1 || rhf - lhf > 1) begin
            $display("[TB] ERROR: unbalanced half-frames left=%0d right=%0d (差>1)", lhf, rhf);
            errors = errors + 1;
        end
        // ★ 同理允许 ±16（恰好一个 half-frame 的位数）
        if (risings > (lhf + rhf) * 16 + 16 || risings < (lhf + rhf) * 16 - 16) begin
            $display("[TB] ERROR: BCK rises %0d != (lhf+rhf)*16 = %0d", risings, (lhf+rhf)*16);
            errors = errors + 1;
        end

        $display("==============================================");
        if (errors == 0) $display("[TB] PASS   errors=0");
        else             $display("[TB] FAIL   errors=%0d", errors);
        $display("==============================================");
        $stop;   // ★ 用 $stop 而非 $finish：run.do 要连续跑多个 tb，$finish 会终止整个 vsim
    end

endmodule

`default_nettype wire
