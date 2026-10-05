// =============================================================================
//  tb_uart_rx.v —— 串口接收 + MIDI 解析 自检平台
//
//  验证内容（每个都打印 [CHECK] 行，最后给 [RESULT] 汇总）：
//   1. 位流 0x90 0x45 0x64  → on_valid=1, on_note=0x45(69=A4), on_vel=0x64(100)
//   2. 0x90 0x45 0x00       → **NoteOn vel=0 必须当 NoteOff**（off_note=0x45）
//   3. 0x80 0x45 0x40       → NoteOff（off_note=0x45）
//   4. 0xB0 0x7B 0x00       → All Notes Off：连续 128 拍 off_valid，off_note=0..127
//   5. 假起始毛刺（低脉冲 < 半位）→ **不得**产出任何字节（抗干扰）
//   6. 连发两个音（复音）0x90 0x40 0x64 / 0x90 0x44 0x64 → 两个 on_valid，note 0x40/0x44
//
//  ⚠️ 所有 $display 一律用 **ASCII**：ModelSim 的 transcript 在中文 Windows 下会把
//     UTF-8 中文显示成乱码，且过长的字符串会被定宽向量截断 —— 用 ASCII 才能得到
//     干净、可直接贴进报告的原始输出。
//
//  运行： cd fpga_hank ; & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
//         （或 $env:SIM_TOP="tb_uart_rx"）
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_uart_rx;

    localparam integer CLK_HZ   = 50_000_000;
    localparam integer BAUD     = 115200;
    localparam integer DIV      = (CLK_HZ + BAUD/2) / BAUD;   // 434
    localparam real    TCLK     = 20.0;                       // 50 MHz

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    always #(TCLK/2.0) clk = ~clk;

    // ---- DUT ----
    reg         rx = 1'b1;              // idle high
    wire [7:0]  bdata;
    wire        bvalid;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(bdata), .valid(bvalid)
    );

    wire       on_valid;  wire [6:0] on_note;  wire [6:0] on_vel;
    wire       off_valid; wire [6:0] off_note;
    wire       cc_valid;  wire       reset_all;
    wire       glide_on;  wire [6:0] glide_time;
    wire       vib_on;    wire [6:0] vib_depth;  wire [6:0] vib_rate;
    wire       sustain;

    // ------------------------------------------------------------------
    // ★ 定向用例用的【字节注入通道】
    //   要在"CC123 的 128 拍扫描窗口内"精确打一个字节，走 uart_rx 粒度太粗
    //   （一位 434 clk，而窗口只有 128 clk）。所以加一个 mux：
    //   inj_mode=1 时由 TB 直接产生 byte_valid 脉冲，精确落在扫描窗口里。
    //   正常用例 inj_mode=0，字节完全由 uart_rx 驱动（不影响原有测试）。
    // ------------------------------------------------------------------
    reg        inj_mode  = 1'b0;
    reg        inj_valid = 1'b0;
    reg  [7:0] inj_data  = 8'h00;
    wire [7:0] m_bdata  = inj_mode ? inj_data  : bdata;
    wire       m_bvalid = inj_mode ? inj_valid : bvalid;

    midi_rx u_midi (
        .clk(clk), .rst_n(rst_n),
        .byte_data(m_bdata), .byte_valid(m_bvalid),
        .on_valid(on_valid), .on_note(on_note), .on_vel(on_vel),
        .off_valid(off_valid), .off_note(off_note),
        // ---- 表情参数（CC）----
        .cc_valid(cc_valid), .reset_all(reset_all),
        .glide_on(glide_on), .glide_time(glide_time),
        .vib_on(vib_on), .vib_depth(vib_depth), .vib_rate(vib_rate),
        .sustain(sustain)
    );

    // ---- 事件捕获 ----
    integer on_cnt  = 0;
    integer off_cnt = 0;
    integer bcnt    = 0;
    integer cc_cnt  = 0;
    integer rst_cnt = 0;
    reg [6:0] cap_on_note0, cap_on_vel0, cap_on_note1;
    reg [6:0] cap_off_note;
    reg [7:0] sweep_min, sweep_max;
    integer   sweep_cnt = 0;
    reg       sweep_mono = 1'b1;
    reg [7:0] sweep_last = 8'hFF;
    reg       inj_hit_sweep = 1'b0;     // 注入时扫描正在跑 ⇒ 证明真的打在窗口内

    always @(posedge clk) begin
        if (!rst_n) begin
            on_cnt <= 0; off_cnt <= 0; bcnt <= 0; cc_cnt <= 0; rst_cnt <= 0;
            sweep_cnt <= 0; sweep_mono <= 1'b1; sweep_last <= 8'hFF;
            sweep_min <= 8'hFF; sweep_max <= 8'h00;
        end else begin
            if (bvalid || inj_valid) bcnt <= bcnt + 1;
            if (cc_valid) cc_cnt <= cc_cnt + 1;
            if (reset_all) rst_cnt <= rst_cnt + 1;

            if (on_valid) begin
                if (on_cnt == 0) begin
                    cap_on_note0 <= on_note;
                    cap_on_vel0  <= on_vel;
                end else if (on_cnt == 1) begin
                    cap_on_note1 <= on_note;
                end
                on_cnt <= on_cnt + 1;
            end

            if (off_valid) begin
                cap_off_note <= off_note;
                off_cnt <= off_cnt + 1;
                if (sweep_cnt > 0 && off_note != sweep_last + 7'd1) sweep_mono <= 1'b0;
                sweep_last <= {1'b0, off_note};
                if (off_note < sweep_min) sweep_min <= {1'b0, off_note};
                if (off_note > sweep_max) sweep_max <= {1'b0, off_note};
                sweep_cnt  <= sweep_cnt + 1;
            end
        end
    end

    integer errors = 0;

    // case16（扫描窗口内注入）用的返回量
    integer r_on;
    integer r_hit;
    reg [6:0] r_note;

    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) $display("[CHECK] PASS  %0s", name);
            else      begin $display("[CHECK] FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // ---- UART 位流发送（115200 8N1，LSB first）----
    task send_byte;
        input [7:0] b;
        integer i;
        begin
            rx = 1'b0;                       // start bit
            repeat (DIV) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx = b[i];                   // LSB first
                repeat (DIV) @(posedge clk);
            end
            rx = 1'b1;                       // stop bit
            repeat (DIV) @(posedge clk);
        end
    endtask

    task clear_caps;
        begin
            on_cnt = 0; off_cnt = 0; bcnt = 0; cc_cnt = 0; rst_cnt = 0;
            sweep_cnt = 0; sweep_mono = 1'b1; sweep_min = 8'hFF; sweep_max = 8'h00;
            inj_hit_sweep = 1'b0;
        end
    endtask

    // 注入一个字节（1 个 clk 的 valid 脉冲，精确到拍）
    // ★ 两个要点（都是实测踩出来的）：
    //   1) 在【负边沿】驱动，远离正边沿采样点，避免与 DUT/监视块竞争；
    //   2) "是否落在扫描窗口"**在任务里直接判定**（正边沿后 #1 读稳定值），
    //      不要依赖另一个 always 块在同一拍采样 —— 那会受进程执行顺序影响。
    //   注：扫描期间 off_valid 每拍都是 1，所以"注入那一拍 off_valid==1"就是"打在窗口内"的证据。
    task inject_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            inj_data  = b;
            inj_valid = 1'b1;
            @(posedge clk);                  // ← DUT 在这一拍采到 byte_valid=1
            #1;                              //    等 NBA 更新落定
            $display("[DBG] inject b=%02h off_valid=%0d sweep_cnt=%0d off_note=%0d",
                     b, off_valid, sweep_cnt, off_note);
            if (off_valid) inj_hit_sweep = 1'b1;
            @(negedge clk);
            inj_valid = 1'b0;
        end
    endtask

    // ★ 定向用例：触发 CC123 扫描 → 走到第 n 拍 → 在窗口内注入整条 NoteOn 消息
    task sweep_inject_round;
        input         integer n;
        output        integer got_on;
        output [6:0]          got_note;
        output        integer hit;
        begin
            clear_caps;
            inj_valid = 1'b0;
            inj_mode  = 1'b1;                       // 切到注入通道
            inject_byte(8'hB0);                     // CC123：All Notes Off
            inject_byte(8'h7B);
            inject_byte(8'h00);
            wait (off_valid == 1'b1);               // 扫描已开始
            repeat (n) @(posedge clk);              // 走到扫描的第 n 拍
            inject_byte(8'h90);                     // ★ 窗口内注入 NoteOn A4 vel100
            inject_byte(8'h45);
            inject_byte(8'h64);
            repeat (300) @(posedge clk);            // 等扫描结束 + 解析完成
            got_on   = on_cnt;
            got_note = cap_on_note0;
            hit      = inj_hit_sweep;
            inj_mode = 1'b0;                        // 切回真实 uart 通道
        end
    endtask

    initial begin
        $display("================================================================");
        $display(" tb_uart_rx : 115200 8N1 @ CLK=%0d Hz  DIV=%0d", CLK_HZ, DIV);
        $display("================================================================");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ---------- case 1: 0x90 0x45 0x64 = NoteOn A4 vel100 ----------
        clear_caps;
        send_byte(8'h90); send_byte(8'h45); send_byte(8'h64);
        repeat (DIV*2) @(posedge clk);
        $display("[INFO] case1 bytes=%0d on_cnt=%0d off_cnt=%0d", bcnt, on_cnt, off_cnt);
        chk(bcnt == 3,                    "1a received 3 bytes");
        chk(on_cnt == 1,                  "1b on_valid pulsed once");
        chk(cap_on_note0 == 7'h45,        "1c on_note = 0x45 (69 = A4)");
        chk(cap_on_vel0  == 7'h64,        "1d on_vel  = 0x64 (100)");
        chk(off_cnt == 0,                 "1e no spurious NoteOff");

        // ---------- case 2: 0x90 0x45 0x00 -> NoteOn vel=0 means NoteOff ----------
        clear_caps;
        send_byte(8'h90); send_byte(8'h45); send_byte(8'h00);
        repeat (DIV*2) @(posedge clk);
        $display("[INFO] case2 on_cnt=%0d off_cnt=%0d off_note=0x%02h", on_cnt, off_cnt, cap_off_note);
        chk(on_cnt  == 0,                 "2a vel=0 produces no NoteOn");
        chk(off_cnt == 1,                 "2b vel=0 produces one NoteOff");
        chk(cap_off_note == 7'h45,        "2c off_note = 0x45");

        // ---------- case 3: 0x80 0x45 0x40 = NoteOff ----------
        clear_caps;
        send_byte(8'h80); send_byte(8'h45); send_byte(8'h40);
        repeat (DIV*2) @(posedge clk);
        $display("[INFO] case3 on_cnt=%0d off_cnt=%0d off_note=0x%02h", on_cnt, off_cnt, cap_off_note);
        chk(on_cnt  == 0,                 "3a NoteOff produces no NoteOn");
        chk(off_cnt == 1,                 "3b NoteOff produces one off_valid");
        chk(cap_off_note == 7'h45,        "3c off_note = 0x45");

        // ---------- case 4: 0xB0 0x7B 0x00 = All Notes Off ----------
        clear_caps;
        send_byte(8'hB0); send_byte(8'h7B); send_byte(8'h00);
        repeat (DIV*40) @(posedge clk);
        $display("[INFO] case4 off_cnt=%0d range=%0d..%0d monotonic=%0d",
                 off_cnt, sweep_min, sweep_max, sweep_mono);
        chk(off_cnt == 128,               "4a AllNotesOff emits 128 off_valid");
        chk(sweep_min == 8'd0 && sweep_max == 8'd127, "4b covers note 0..127");
        chk(sweep_mono == 1'b1,           "4c sweep is monotonic");

        // ---------- case 5: false-start glitch (< half bit) must yield no byte ----------
        clear_caps;
        rx = 1'b0; repeat (DIV/4) @(posedge clk);   // low for only 1/4 bit
        rx = 1'b1; repeat (DIV*2) @(posedge clk);
        $display("[INFO] case5 bytes after glitch=%0d", bcnt);
        chk(bcnt == 0,                    "5a glitch produces no byte");

        // ---------- case 6: polyphony (two NoteOn back to back) ----------
        clear_caps;
        send_byte(8'h90); send_byte(8'h40); send_byte(8'h64);   // E3
        send_byte(8'h90); send_byte(8'h44); send_byte(8'h64);   // G#3
        repeat (DIV*2) @(posedge clk);
        $display("[INFO] case6 on_cnt=%0d note1=0x%02h note2=0x%02h", on_cnt, cap_on_note0, cap_on_note1);
        chk(on_cnt == 2,                  "6a two NoteOn received");
        chk(cap_on_note0 == 7'h40,        "6b first note = 0x40");
        chk(cap_on_note1 == 7'h44,        "6c second note = 0x44");

        // ================= 表情参数 CC（新增） =================
        // --- case 7: CC5 滑音时间 + CC65 开关阈值 ---
        clear_caps;
        send_byte(8'hB0); send_byte(8'h05); send_byte(8'd25);   // CC5  = 25
        repeat (DIV) @(posedge clk);
        chk(glide_time == 7'd25,          "7a CC5=25 -> glide_time=25");
        send_byte(8'hB0); send_byte(8'h41); send_byte(8'd127);  // CC65 = 127
        repeat (DIV) @(posedge clk);
        chk(glide_on == 1'b1,             "7b CC65=127 -> glide_on=1");
        send_byte(8'hB0); send_byte(8'h41); send_byte(8'd63);   // CC65 = 63
        repeat (DIV) @(posedge clk);
        chk(glide_on == 1'b0,             "7c CC65=63 -> glide_on=0 (<=63 off)");

        // --- case 8: CC1 与 CC77 都写 vib_depth（后到的生效）---
        send_byte(8'hB0); send_byte(8'h01); send_byte(8'd64);   // CC1  = 64
        repeat (DIV) @(posedge clk);
        chk(vib_depth == 7'd64 && vib_on == 1'b1, "8a CC1=64 -> depth=64, vib_on=1");
        send_byte(8'hB0); send_byte(8'h4D); send_byte(8'd100);  // CC77 = 100
        repeat (DIV) @(posedge clk);
        chk(vib_depth == 7'd100,          "8b CC77=100 -> depth=100 (last wins)");
        send_byte(8'hB0); send_byte(8'h01); send_byte(8'd0);    // CC1  = 0
        repeat (DIV) @(posedge clk);
        chk(vib_depth == 7'd0 && vib_on == 1'b0, "8c CC1=0 -> depth=0, vib_on=0");

        // --- case 9: CC76 颤音速度 ---
        send_byte(8'hB0); send_byte(8'h4C); send_byte(8'd50);   // CC76 = 50
        repeat (DIV) @(posedge clk);
        chk(vib_rate == 7'd50,            "9a CC76=50 -> vib_rate=50 (下游换算 5.0Hz)");

        // --- case 10: CC64 阈值 63 关 / 64 开 ---
        send_byte(8'hB0); send_byte(8'h40); send_byte(8'd63);   // CC64 = 63
        repeat (DIV) @(posedge clk);
        chk(sustain == 1'b0,              "10a CC64=63 -> sustain=0");
        send_byte(8'hB0); send_byte(8'h40); send_byte(8'd64);   // CC64 = 64
        repeat (DIV) @(posedge clk);
        chk(sustain == 1'b1,              "10b CC64=64 -> sustain=1");
        $display("[INFO] case7-10 cc_valid pulses=%0d (expect 9)", cc_cnt);
        chk(cc_cnt == 9,                  "10c cc_valid pulsed once per implemented CC (9)");

        // --- case 11: 不认识的 CC 不得打乱后续解析 ---
        clear_caps;
        send_byte(8'hB0); send_byte(8'h4A); send_byte(8'd99);   // CC74 Brightness（未实现）
        send_byte(8'hB0); send_byte(8'h07); send_byte(8'd100);  // CC7  Volume（未实现）
        send_byte(8'h90); send_byte(8'h45); send_byte(8'd100);  // 其后 NoteOn 必须正常
        repeat (DIV*2) @(posedge clk);
        $display("[INFO] case11 on_cnt=%0d note=0x%02h cc_cnt=%0d", on_cnt, cap_on_note0, cc_cnt);
        chk(on_cnt == 1 && cap_on_note0 == 7'h45, "11a NoteOn after unknown CC parsed OK");
        chk(cc_cnt == 0,                  "11b unknown CC produces no cc_valid");

        // --- case 12: CC120 All Sound Off -> reset_all + 参数归位 ---
        // 先把参数改成非默认值，再复位，才能证明"真的归位"
        send_byte(8'hB0); send_byte(8'h05); send_byte(8'd99);   // CC5  = 99
        send_byte(8'hB0); send_byte(8'h01); send_byte(8'd77);   // CC1  = 77
        send_byte(8'hB0); send_byte(8'h4C); send_byte(8'd12);   // CC76 = 12
        send_byte(8'hB0); send_byte(8'h41); send_byte(8'd127);  // CC65 = 127
        send_byte(8'hB0); send_byte(8'h40); send_byte(8'd127);  // CC64 = 127
        repeat (DIV) @(posedge clk);
        clear_caps;                                             // 只统计复位之后的脉冲
        send_byte(8'hB0); send_byte(8'h78); send_byte(8'd0);    // CC120
        repeat (DIV) @(posedge clk);
        $display("[INFO] case12 rst_cnt=%0d glide=%0d vibd=%0d vibr=%0d g_on=%0d v_on=%0d sus=%0d",
                 rst_cnt, glide_time, vib_depth, vib_rate, glide_on, vib_on, sustain);
        chk(rst_cnt >= 1,                 "12a CC120 pulses reset_all");
        chk(glide_time == 7'd0 && vib_depth == 7'd0 && vib_rate == 7'd50,
            "12b CC120 resets glide_time/vib_depth/vib_rate(=50)");
        chk(glide_on == 1'b0 && vib_on == 1'b0 && sustain == 1'b0,
            "12c CC120 resets glide_on/vib_on/sustain");

        // --- case 13: CC121 Reset All Controllers -> 同样复位 ---
        send_byte(8'hB0); send_byte(8'h05); send_byte(8'd50);   // 改成非默认
        send_byte(8'hB0); send_byte(8'h40); send_byte(8'd127);  // sustain 开
        repeat (DIV) @(posedge clk);
        clear_caps;
        send_byte(8'hB0); send_byte(8'h79); send_byte(8'd0);    // CC121
        repeat (DIV) @(posedge clk);
        chk(rst_cnt >= 1,                 "13a CC121 pulses reset_all");
        chk(glide_time == 7'd0 && sustain == 1'b0, "13b CC121 resets params");

        // --- case 14: 回归 —— CC123 行为不变（收到 CC 后仍能 128 拍扫描）---
        clear_caps;
        send_byte(8'hB0); send_byte(8'h05); send_byte(8'd30);   // 先来一个表情 CC
        send_byte(8'hB0); send_byte(8'h7B); send_byte(8'h00);   // 再 All Notes Off
        repeat (DIV*40) @(posedge clk);
        $display("[INFO] case14 off_cnt=%0d range=%0d..%0d mono=%0d",
                 off_cnt, sweep_min, sweep_max, sweep_mono);
        chk(off_cnt == 128,               "14a CC123 still emits 128 off_valid");
        chk(sweep_min == 8'd0 && sweep_max == 8'd127, "14b CC123 still covers 0..127");
        chk(sweep_mono == 1'b1,           "14c CC123 sweep still monotonic");

        // --- case 15: 回归 —— vel=0 仍当 NoteOff（改了 CC 逻辑后不能退化）---
        clear_caps;
        send_byte(8'h90); send_byte(8'h50); send_byte(8'h00);
        repeat (DIV*2) @(posedge clk);
        chk(on_cnt == 0 && off_cnt == 1 && cap_off_note == 7'h50,
            "15a vel=0 still NoteOff (regression)");

        // ================= ★ case 16：字节恰好落在 CC123 的 128 拍扫描窗口内 =======
        //  旧实现是 `if (sweep_act) … else if (byte_valid) …` —— 两者【互斥】，
        //  扫描期间到达的字节被**整个丢掉**（115200 下每字节约 3% 概率撞上）。
        //  本用例把 NoteOn 的 3 个字节**精确注入扫描窗口内部**（第 1/64/126 拍），
        //  ⇒ 必须仍被正确解析；旧实现会丢字节、on_cnt=0。
        //  `hit=1` 用来证明"确实打在了窗口里"，否则用例没有覆盖到目标条件。
        sweep_inject_round(1,   r_on, r_note, r_hit);
        $display("[INFO] case16a inject@beat1   on_cnt=%0d note=0x%02h hit_sweep=%0d", r_on, r_note, r_hit);
        chk(r_hit == 1,                   "16a injection really landed inside sweep window");
        chk(r_on == 1 && r_note == 7'h45, "16b NoteOn parsed inside sweep (beat 1)");

        sweep_inject_round(64,  r_on, r_note, r_hit);
        $display("[INFO] case16b inject@beat64  on_cnt=%0d note=0x%02h hit_sweep=%0d", r_on, r_note, r_hit);
        chk(r_hit == 1,                   "16c injection landed inside sweep window (mid)");
        chk(r_on == 1 && r_note == 7'h45, "16d NoteOn parsed inside sweep (beat 64)");

        sweep_inject_round(126, r_on, r_note, r_hit);
        $display("[INFO] case16c inject@beat126 on_cnt=%0d note=0x%02h hit_sweep=%0d", r_on, r_note, r_hit);
        chk(r_hit == 1,                   "16e injection landed inside sweep window (tail)");
        chk(r_on == 1 && r_note == 7'h45, "16f NoteOn parsed inside sweep (beat 126)");

        // ---------- summary ----------
        $display("================================================================");
        if (errors == 0) $display("[RESULT] PASS  (all checks passed)");
        else             $display("[RESULT] FAIL  (%0d checks failed)", errors);
        $display("================================================================");
        $finish;
    end

    initial begin
        #50_000_000;                        // 50 ms timeout guard（CC 用例变多，留足余量）
        $display("[RESULT] TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
