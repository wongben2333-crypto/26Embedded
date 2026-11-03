// =============================================================================
//  tb_wave.v —— 产出「能直接看的仿真波形数据」的四个 testbench
//
//  目的：为 docs/waveforms/ 里的波形图提供【真实仿真数据】。
//  每个 tb 都把关心的信号按固定节奏写进 CSV，再由 _smoke-test/render_waves.py
//  画成 PNG。这样图上的每一点都来自真实仿真，不是手画的示意。
//
//  ┌─────────────────┬──────────────────────────────────────────────┐
//  │ tb_wave_pt8211  │ ① PT8211 I2S：BCK / WS / DIN 三根线，看位序  │
//  │ tb_wave_adsr    │ ② ADSR：gate 与包络电平曲线（起音/释放斜坡） │
//  │ tb_wave_tonebank│ ③ tone_bank：32 路混音 mix_out 波形          │
//  │ tb_wave_chain   │ ④ 交互链路：按键→去抖→gate→包络→出声 的因果 │
//  └─────────────────┴──────────────────────────────────────────────┘
//
//  用法（在 fpga_hank 目录下）：
//     $env:SIM_TOP="tb_wave_pt8211"; & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
//
//  ★ 刻意只用 Verilog-2001 语法（不用 join_any / 块内声明等 SystemVerilog 构造），
//    这样高云 GUI 的仿真入口（可能用普通 vlog 而不是 vlog -sv）也能直接编译。
//  ★ CSV 输出目录默认 ../_smoke-test/simdata/（CWD = fpga_hank 时）；
//    打不开就退到当前目录同名文件，**再不行只警告、不中断仿真** ——
//    因为 CSV 只是附带中间数据，WLF/波形才是主产物（原先会 $finish，导致在别的
//    目录编译运行时连波形都产不出来，实测踩过）。
//  ★ 采样一律用「等间隔抽点 + $fwrite」，不靠 VCD：CSV 更好画、也更小。
// =============================================================================
`timescale 1ns/1ps

// -----------------------------------------------------------------------------
//  ① PT8211 I2S 发送器：BCK / WS / DIN
//     左声道样本 = 16'b1010_1010_1010_1010，右声道 = 16'b0101_0101_0101_0101。
//     这两组值在 DIN 上变成"左声道是方波、右声道是反相方波"，
//     WS 边沿处能一眼看出 16 位/声道、MSB 先出、以及左右边界。
// -----------------------------------------------------------------------------
module tb_wave_pt8211;
    reg clk = 1'b0;
    always #10 clk = ~clk;                 // 50 MHz

    reg               reset = 1'b1;
    reg  signed [15:0] sl = 16'b1010_1010_1010_1010;
    reg  signed [15:0] sr = 16'b0101_0101_0101_0101;

    wire              sample_tick, bck, ws, din;

    integer fd;
    integer i;

    pt8211_tx #(.BCK_DIV(1)) dut (
        .clk         (clk),
        .reset       (reset),
        .sample_l    (sl),
        .sample_r    (sr),
        .sample_tick (sample_tick),
        .bck         (bck),
        .ws          (ws),
        .din         (din)
    );

    initial begin
        // CSV 只是附带产物；打不开就退到当前目录，再不行只警告、不中断仿真
        // （否则在别的目录跑时连 WLF 波形都产不出来 —— 实测踩过）
        fd = $fopen("../_smoke-test/simdata/pt8211.csv", "w");
        if (fd == 0) fd = $fopen("pt8211.csv", "w");
        if (fd == 0) begin
            $display("[tb_wave] 警告: CSV pt8211.csv 打不开, 不影响仿真与波形, 继续");
        end else begin
            $fwrite(fd, "t_ns,bck,ws,din,sample_tick\n");
        end

        #200;
        reset = 1'b0;

        // 跳过第一帧，从帧边界开始记录 1650 个 clk（≈3.2 个立体声帧）
        for (i = 0; i < 1650; i = i + 1) begin
            @(posedge clk);
            #1;
            $fwrite(fd, "%0d,%b,%b,%b,%b\n", $time, bck, ws, din, sample_tick);
        end

        if (fd != 0) $fclose(fd);
        $display("[tb_wave_pt8211] 写完 pt8211.csv：%0d 个 clk", i);
        $finish;
    end
endmodule


// -----------------------------------------------------------------------------
//  ② ADSR 包络：gate 与 level
//     参数 EN_DIV=64, ATK_SH=13, DEC/REL_SH=16（50 MHz 下）：
//       起音 = 65536/(65536>>13) = 8192 步 × 64 clk = 524288 clk = **10.49 ms**
//       衰减 = 16384 步 × 64 clk = 1048576 clk = 20.97 ms
//       释放 = 49152 步 × 64 clk = 3145728 clk = **62.91 ms**
//     按住 200 ms、松开后 150 ms，三个斜坡都完整落在图里。
//     ★ 为什么是 ATK_SH=13 而不是 16：adsr.v 只有一个全局 EN_DIV，
//       起音时长 = 2^ATK_SH × EN_DIV × 20 ns。要同时得到 10.49 ms 起音
//       与 62.91 ms 释放，解出 EN_DIV=64、ATK_SH=13、REL_SH=16。
//       （EN_DIV=64+SH=16 会得到 83.9 ms 起音 —— 那是另一种取舍，见 REPORT.md）
// -----------------------------------------------------------------------------
module tb_wave_adsr;
    reg  clk   = 1'b0;
    always #10 clk = ~clk;

    reg        rst_n = 1'b0;
    reg  [0:0] gate  = 1'b0;
    wire [16:0] level;

    integer fd;
    reg [8:0] cnt = 9'd0;

    adsr #(
        .N_VOICES  (1),
        .EN_DIV    (64),
        .ATK_SH    (13),
        .DEC_SH    (16),
        .REL_SH    (16),
        .SUS_LEVEL (49152)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .gate     (gate),
        .voice_rd (5'd0),
        .level_rd (level),
        .phase_rd ()
    );

    // 每 512 clk（10.24 µs）抽一个点 → 约 34k 行
    always @(posedge clk) begin
        cnt <= cnt + 9'd1;
        if (cnt == 9'd0 && fd != 0)
            $fwrite(fd, "%0d,%b,%0d\n", $time / 1000, gate, level);
    end

    initial begin
        // CSV 只是附带产物；打不开就退到当前目录，再不行只警告、不中断仿真
        // （否则在别的目录跑时连 WLF 波形都产不出来 —— 实测踩过）
        fd = $fopen("../_smoke-test/simdata/adsr.csv", "w");
        if (fd == 0) fd = $fopen("adsr.csv", "w");
        if (fd == 0) begin
            $display("[tb_wave] 警告: CSV adsr.csv 打不开, 不影响仿真与波形, 继续");
        end else begin
            $fwrite(fd, "t_us,gate,level\n");
        end

        #1000;
        rst_n = 1'b1;
        #100000;                 // 稳定 100 µs
        gate = 1'b1;             // ---- 起音 ----
        #200000000;              // 按住 200 ms
        gate = 1'b0;             // ---- 释放 ----
        #150000000;              // 再跑 150 ms
        if (fd != 0) $fclose(fd);
        $display("[tb_wave_adsr] 写完 adsr.csv");
        $finish;
    end
endmodule


// -----------------------------------------------------------------------------
//  ③ tone_bank 32 路混音：mix_out
//     gate 全按住（bench_gate TEST_MODE=1），音色锁表 0（纯正弦）。
//     记录从 0 到 20 ms 的每一个采样点（fs = 97656.25 Hz → 约 1950 点），
//     覆盖"起音 → 衰减 → 保持"全过程。
// -----------------------------------------------------------------------------
module tb_wave_tonebank;
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;

    wire               sample_tick;
    wire signed [15:0] mix16;
    wire [31:0]        gate32;
    wire [4:0]         env_voice;
    wire [16:0]        env_level32;

    integer fd;
    integer n;

    // 只为产生 sample_tick（与 smoke_top 里的做法一致）
    pt8211_tx #(.BCK_DIV(1)) u_dac (
        .clk         (clk),
        .reset       (~rst_n),
        .sample_l    (mix16),
        .sample_r    (mix16),
        .sample_tick (sample_tick),
        .bck         (),
        .ws          (),
        .din         ()
    );

    bench_gate #(.N_VOICES(32), .TEST_MODE(1)) u_bench (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .gate        (gate32)
    );

    adsr #(
        .N_VOICES  (32),
        .EN_DIV    (8),
        .ATK_SH    (8),
        .DEC_SH    (10),
        .REL_SH    (12),
        .SUS_LEVEL (49152)
    ) u_adsr (
        .clk      (clk),
        .rst_n    (rst_n),
        .gate     (gate32),
        .voice_rd (env_voice),
        .level_rd (env_level32),
        .phase_rd ()
    );

    tone_bank #(
        .N_VOICES     (32),
        .ROM_PARALLEL (1)
    ) u_bank (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .gate_in     (gate32),
        .timbre      (2'd0),
        .env_voice   (env_voice),
        .env_level   (env_level32),
        .mix_out     (mix16)
    );

    initial begin
        // CSV 只是附带产物；打不开就退到当前目录，再不行只警告、不中断仿真
        // （否则在别的目录跑时连 WLF 波形都产不出来 —— 实测踩过）
        fd = $fopen("../_smoke-test/simdata/tonebank.csv", "w");
        if (fd == 0) fd = $fopen("tonebank.csv", "w");
        if (fd == 0) begin
            $display("[tb_wave] 警告: CSV tonebank.csv 打不开, 不影响仿真与波形, 继续");
        end else begin
            $fwrite(fd, "t_us,mix16\n");
        end

        #1000;
        rst_n = 1'b1;
        n = 0;
        while (n < 2000) begin
            @(posedge sample_tick);
            #1;
            $fwrite(fd, "%0d,%0d\n", $time / 1000, $signed(mix16));
            n = n + 1;
        end
        if (fd != 0) $fclose(fd);
        $display("[tb_wave_tonebank] 写完 tonebank.csv：%0d 个采样点", n);
        $finish;
    end
endmodule


// -----------------------------------------------------------------------------
//  ④ 交互链路：按键 → 同步 → 去抖 → gate → 包络 → 出声
//     直接用 S6（smoke_top STAGE=6），因为它的快包络就是正式演奏参数。
//     按住 100 ms、松开后再跑 100 ms；每 10.24 µs 抽一点。
// -----------------------------------------------------------------------------
module tb_wave_chain;
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg key  = 1'b1;                 // 板上按键低有效，1 = 未按
    reg key2 = 1'b1;

    wire [3:0] led;
    wire       HP_BCK, HP_WS, HP_DIN, PA_EN;
    wire       DBG_KEY, DBG_GATE, DBG_AUDIO;

    integer fd;
    reg [8:0] cnt = 9'd0;

    smoke_top #(.STAGE(6)) dut (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );

    always @(posedge clk) begin
        cnt <= cnt + 9'd1;
        if (cnt == 9'd0 && fd != 0)
            $fwrite(fd, "%0d,%b,%b,%b,%b,%b,%0d\n",
                    $time / 1000,
                    key,                       // 物理按键（低有效）
                    dut.key_raw,               // 两级同步后（按下 = 1）
                    dut.key_db,                // 去抖后 = gate
                    dut.DBG_GATE,              // 打标：应当发声
                    dut.DBG_AUDIO,             // 打标：已出声
                    dut.g_mono.env_level);     // 包络电平
    end

    initial begin
        // CSV 只是附带产物；打不开就退到当前目录，再不行只警告、不中断仿真
        // （否则在别的目录跑时连 WLF 波形都产不出来 —— 实测踩过）
        fd = $fopen("../_smoke-test/simdata/chain.csv", "w");
        if (fd == 0) fd = $fopen("chain.csv", "w");
        if (fd == 0) begin
            $display("[tb_wave] 警告: CSV chain.csv 打不开, 不影响仿真与波形, 继续");
        end else begin
            $fwrite(fd, "t_us,key,key_raw,key_db,dbg_gate,audio_live,env\n");
        end

        // ⚠️ 必须等过【上电复位】再按键：smoke_top 的 POR 是 2^19 clk = 10.49 ms
        //    （不是几十微秒）。本项目实测踩过：写成 #20000 会在复位期间按键，
        //    结果 key_sync 被复位钉死、key_raw 恒 1、根本没有 0→1 沿，
        //    画出来的图是死的。
        #15000000;               // 15 ms：越过 POR
        key = 1'b0;              // ---- 按下 ----
        #100000000;              // 按住 100 ms
        key = 1'b1;              // ---- 松开 ----
        #100000000;              // 再跑 100 ms
        if (fd != 0) $fclose(fd);
        $display("[tb_wave_chain] 写完 chain.csv");
        $finish;
    end
endmodule


// -----------------------------------------------------------------------------
//  ⑤ 边界用例：**按键机械抖动**（学 naelolaiz/learning_fpga 的 debounce_bounce 用例）
//     用 S1（smoke_top STAGE=1）——它没有音频、只有按键通路，最适合单独验去抖。
//     激励：按下时先抖 0.8 ms（10 次通断），稳定按住；松开时再抖 0.5 ms。
//     判据：key_raw 抖动很厉害，但 key_db 只在稳定 2.621 ms 后才变一次，
//           且 press_cnt 恰好 +1（抖动的每一次通断都不算数）。
// -----------------------------------------------------------------------------
module tb_wave_bounce;
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg key  = 1'b1;                 // 低有效：1 = 松开
    reg key2 = 1'b1;

    wire [3:0] led;
    wire       HP_BCK, HP_WS, HP_DIN, PA_EN;
    wire       DBG_KEY, DBG_GATE, DBG_AUDIO;

    integer fd;
    integer i;
    reg [8:0] cnt = 9'd0;

    smoke_top #(.STAGE(1)) dut (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );

    // 每 2.048 µs 抽一点（比 2.621 ms 去抖窗口细 1000 倍，抖动看得清）
    always @(posedge clk) begin
        cnt <= cnt + 9'd1;
        if (cnt == 9'd0 && fd != 0)
            $fwrite(fd, "%0d,%b,%b,%b,%0d\n",
                    $time / 1000, key, dut.key_raw, dut.key_db, dut.press_cnt);
    end

    initial begin
        // CSV 只是附带产物；打不开就退到当前目录，再不行只警告、不中断仿真
        // （否则在别的目录跑时连 WLF 波形都产不出来 —— 实测踩过）
        fd = $fopen("../_smoke-test/simdata/bounce.csv", "w");
        if (fd == 0) fd = $fopen("bounce.csv", "w");
        if (fd == 0) begin
            $display("[tb_wave] 警告: CSV bounce.csv 打不开, 不影响仿真与波形, 继续");
        end else begin
            $fwrite(fd, "t_us,key,key_raw,key_db,press_cnt\n");
        end

        // 越过 POR（2^19 clk = 10.49 ms）再动
        #15000000;

        // ---- 按下：抖 10 次（每次 40 µs 通断）----
        for (i = 0; i < 10; i = i + 1) begin
            key = 1'b0; #20000;
            key = 1'b1; #20000;
        end
        key = 1'b0;              // 最终稳定按下
        #5000000;                // 按住 5 ms

        // ---- 松开：抖 5 次 ----
        for (i = 0; i < 5; i = i + 1) begin
            key = 1'b1; #20000;
            key = 1'b0; #20000;
        end
        key = 1'b1;              // 最终稳定松开
        #5000000;

        if (fd != 0) $fclose(fd);
        $display("[tb_wave_bounce] 写完 bounce.csv（press_cnt 应为 1）");
        $finish;
    end
endmodule
