// =============================================================================
//  tb_smoke.v —— 冒烟测试 S2、S6 的 RTL 级自检（两个 testbench 在同一文件里）
//
//  为什么要写它：S2 是「第一次出声」，也是全链路最关键的一级。
//  仿真能在没有板子的情况下先证明三件事：
//    1. S2 送进 DAC 的样本确实是 440 Hz 正弦，且【正负两半都在】
//       （负半被吃掉的话 DAC 出来的不是正弦而是失真波形）
//    2. PT8211 的 BCK/DIN 真的在动（不是恒 0），BCK 周期 = 320 ns（fs=97656.25 Hz）
//    3. S6 的「按键 → 出声」延迟到底是多少（含 2.621 ms 去抖），
//       并核对 FPGA 内部自测计数器 lat_val 与外部测得的边沿差是否一致
//
//  ⚠️ 这是【RTL 行为级】仿真，验证的是 RTL 语义本身。
//     它不能替代上板实测，也不能证明 Gowin 综合出的门级网表与 RTL 等价。
//
//  用法（在 fpga_hank 目录下）：
//     $env:SIM_TOP="tb_smoke_s2"     或     $env:SIM_TOP="tb_smoke_s6"
//     & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
//
//  ★ 全部用事件等待（@(posedge ...)）而不是每拍轮询：后者要跑 9.5e6 次解释循环，
//    ModelSim 会慢到不可用。
// =============================================================================
`timescale 1ns/1ps

// -----------------------------------------------------------------------------
//  S2：440 Hz 正弦 + I2S 活动性
// -----------------------------------------------------------------------------
module tb_smoke_s2;
    reg clk = 1'b0;
    always #10 clk = ~clk;                       // 50 MHz

    reg key  = 1'b1;                             // 板上按键低有效，1 = 未按
    reg key2 = 1'b1;

    wire [3:0] led;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN;
    wire DBG_KEY, DBG_GATE, DBG_AUDIO;

    smoke_top #(.STAGE(2)) dut (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );

    integer nsamp, npos, nneg, nzero;
    integer vmin, vmax, v, prev_v;
    integer zc_total;
    real    t_zc10, t_zc40;
    real    freq, amp, bck_period;
    integer din_hi, din_lo;
    real    t_b1, t_b20;
    integer nb;
    integer wmax;                                // ROM 输出最大绝对值（诊断包络用）
    integer wv;

    initial begin
        nsamp = 0; npos = 0; nneg = 0; nzero = 0;
        vmin = 1000000; vmax = -1000000; prev_v = 0;
        zc_total = 0; t_zc10 = 0.0; t_zc40 = 0.0;
        din_hi = 0; din_lo = 0; nb = 0; wmax = 0;

        // 包络要 84 ms 才爬到保持段，先等稳定
        #90ms;

        fork
            // ---- 逐个采样点统计波形 ----
            begin : sample_stats
                while ($realtime < 190ms) begin
                    @(posedge dut.sample_tick);
                    v = $signed(dut.mix16);
                    nsamp = nsamp + 1;
                    if (v > vmax) vmax = v;
                    if (v < vmin) vmin = v;
                    if (v > 0)      npos  = npos + 1;
                    else if (v < 0) nneg  = nneg + 1;
                    else            nzero = nzero + 1;
                    if (prev_v <= 0 && v > 0) begin
                        zc_total = zc_total + 1;
                        if (zc_total == 10) t_zc10 = $realtime;
                        if (zc_total == 40) t_zc40 = $realtime;
                    end
                    prev_v = v;
                    wv = $signed(dut.g_mono.wave_val);
                    if (wv < 0) wv = -wv;
                    if (wv > wmax) wmax = wv;
                end
            end
            // ---- I2S：测 20 个 BCK 周期 + 看 DIN 有没有高低电平 ----
            begin : i2s_stats
                while (nb < 20) begin
                    @(posedge HP_BCK);
                    nb = nb + 1;
                    if (nb == 1)  t_b1  = $realtime;
                    if (nb == 20) t_b20 = $realtime;
                end
                bck_period = (t_b20 - t_b1) / 19.0;      // ns
                repeat (4000) begin
                    @(posedge HP_BCK);
                    if (HP_DIN) din_hi = din_hi + 1;
                    else        din_lo = din_lo + 1;
                end
            end
        join

        freq = 0.0;
        if (t_zc40 > t_zc10) freq = 30.0 / ((t_zc40 - t_zc10) * 1.0e-9);
        amp  = (vmax - vmin) / 2.0;

        $display("=====================================================");
        $display("[S2] 采样点数          = %0d", nsamp);
        $display("[S2] 正 / 负 / 零 样本 = %0d / %0d / %0d", npos, nneg, nzero);
        $display("[S2] 样本最小/最大值   = %0d / %0d  (幅度 ~%0.0f)", vmin, vmax, amp);
        $display("[S2] 上穿零次数        = %0d  (100 ms 期望 ~44)", zc_total);
        $display("[S2] 实测频率          = %0.4f Hz   (期望 440.0)", freq);
        $display("[S2] ROM 输出最大幅值  = %0d  (表 0 满幅 32767)", wmax);
        $display("[S2] 包络电平 env_level = %0d  (保持段应 = 49152)", dut.g_mono.env_level);
        $display("[S2] BCK 周期          = %0.1f ns  (期望 320.0)", bck_period);
        $display("[S2] DIN 高/低 拍数    = %0d / %0d", din_hi, din_lo);
        $display("[S2] led = %b  PA_EN = %b  DBG_AUDIO = %b", led, PA_EN, DBG_AUDIO);

        if (npos > 100 && nneg > 100 && vmax > 8000 && vmin < -8000)
            $display("[S2] 极性/幅度 : PASS  (正负两半都在，负半没被吃掉)");
        else
            $display("[S2] 极性/幅度 : FAIL  (正负不对称 → 有符号乘法/移位有问题)");

        if (freq > 435.6 && freq < 444.4)
            $display("[S2] 频率      : PASS  (440 Hz ±1%%)");
        else
            $display("[S2] 频率      : FAIL  (实测 %0.3f Hz)", freq);

        if (bck_period > 316.0 && bck_period < 324.0 && din_hi > 100 && din_lo > 100)
            $display("[S2] I2S       : PASS  (BCK 周期对、DIN 有 0 有 1)");
        else
            $display("[S2] I2S       : FAIL  (BCK 周期 %0.1f ns, DIN 高/低 %0d/%0d)",
                     bck_period, din_hi, din_lo);
        $display("=====================================================");
        $finish;
    end
endmodule


// -----------------------------------------------------------------------------
//  S6：按键 → 出声 的延迟（含去抖）+ 核对内部自测计数器
// -----------------------------------------------------------------------------
module tb_smoke_s6;
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg key  = 1'b1;
    reg key2 = 1'b1;

    wire [3:0] led;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN;
    wire DBG_KEY, DBG_GATE, DBG_AUDIO;

    smoke_top #(.STAGE(6)) dut (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );

    real    t_press, t_sync, t_gate, t_audio;
    integer lat_self;
    real    lat_ms, self_ms;

    initial begin
        t_press = 0.0; t_sync = 0.0; t_gate = 0.0; t_audio = 0.0;

        #20ms;                                   // 等上电复位完成、逻辑稳定

        @(posedge clk);
        key = 1'b0;                              // 模拟"手指按下"（低有效）
        t_press = $realtime;

        fork
            begin
                @(posedge dut.key_raw);  t_sync  = $realtime;   // 过完 2 级同步
                @(posedge DBG_GATE);     t_gate  = $realtime;   // 去抖完成
                @(posedge DBG_AUDIO);    t_audio = $realtime;   // 音频已过阈值
            end
            begin
                #50ms;                                          // 超时保护
            end
        join_any
        disable fork;

        // ⚠️ 必须再等几拍再读 lat_val / led：
        //    lat_val 是【非阻塞赋值】在 audio_live 上升的同一拍写进去的，
        //    TB 在同一 delta 立刻读会读到旧值 0（本项目实测踩过）。
        repeat (10) @(posedge clk);

        lat_self = dut.lat_val;
        lat_ms   = (t_audio - t_press) * 1.0e-6;
        self_ms  = lat_self * 20.0e-6;

        $display("=====================================================");
        $display("[S6] TB 拉低 key(物理接触)      t = %0.3f us", t_press * 1.0e-3);
        $display("[S6] key_raw 上升(同步后)       t = %0.3f us", t_sync  * 1.0e-3);
        $display("[S6] DBG_GATE 上升(去抖完成)    t = %0.3f us  → 去抖 %0.3f ms",
                 t_gate * 1.0e-3, (t_gate - t_sync) * 1.0e-6);
        $display("[S6] DBG_AUDIO 上升(出声)       t = %0.3f us", t_audio * 1.0e-3);
        $display("[S6] ★ 物理接触 → 出声          = %0.3f ms", lat_ms);
        $display("[S6] 内部自测 lat_val           = %0d clk = %0.3f ms", lat_self, self_ms);
        $display("[S6] led = %b  (led3=<5ms led2=<10ms led1=按住 led0=心跳)", led);

        if (lat_ms > 0.0 && lat_ms < 10.0)
            $display("[S6] 基础要求② (<=10 ms) : PASS");
        else
            $display("[S6] 基础要求② (<=10 ms) : FAIL (%0.3f ms)", lat_ms);

        if (lat_ms > 0.0 && lat_ms < 5.0)
            $display("[S6] 拓展③    (< 5 ms)  : PASS");
        else
            $display("[S6] 拓展③    (< 5 ms)  : 未达");

        if ((self_ms - lat_ms < 0.2) && (lat_ms - self_ms < 0.2))
            $display("[S6] 自测 vs 外部测量一致（差 %0.3f ms）", self_ms - lat_ms);
        else
            $display("[S6] ⚠️ 自测与外部测量差 %0.3f ms，需要查", self_ms - lat_ms);
        $display("=====================================================");
        $finish;
    end
endmodule
