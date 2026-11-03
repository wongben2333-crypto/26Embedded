// =============================================================================
//  tb_interaction.v —— 验证【基础要求①：多维交互检测】的完整通路
//
//  ★ 为什么必须单独写这个 testbench：
//     在此之前的证据只有"编译通过 + 12 个引脚 constrained=Y"。
//     那证明的是"接线对了"，**不是"功能对了"** ——
//     按键按下到底有没有让 gate 变高、包络有没有真的起音、音色切换有没有生效，
//     全都没有验证过。对一项【基础要求】来说这是不够的。
//
//     要测这条通路必须让 TEST_MODE=0（演奏模式），而 TEST_MODE 原来是文件级
//     localparam、testbench 覆盖不了。已把它改成模块参数，本 testbench 用
//         top #(.TEST_MODE(0)) dut (...)
//     真正测到"按键 → 两级同步 → 去抖 → gate → ADSR 包络"。
//
//  ★ 被测的三个维度（赛题要求 ≥2 个独立可控维度）：
//     维度 1  key       (AB13)：演奏触发 —— 按住时 gate 全高、包络起音
//     维度 2  key2      (Y12) ：音色切换 —— 每按一下在 4 种表间循环
//     维度 3  key_pitch (Y22) ：半音变调 —— 每按一下升 1 个半音
//
//  ★ 验证内容（7 项）：
//     1) 复位后：gate 全 0、包络电平 0（静音）
//     2) 抖动用例：key 抖动 10 次 → 去抖后只认 1 次状态变化（边界用例）
//     3) 按住 key → gate 全 1，且包络开始起音（电平上升）
//     4) 松开 key → gate 全 0，且包络进入释放（电平下降）
//     5) 按一下 key2 → 音色号 +1
//     6) 连按 4 下 key2 → 音色号回到 0（4 种循环）
//     7) 按一下 key_pitch → pitch_semi 从 0 变为 +1（原调 → 升半音）
//
//  ★ 两个"独立性"的验证（这是"独立可控维度"的关键）：
//     · 按住 key 期间按 key2 换音色 → gate 不受影响（仍在发声）
//     · 按住 key 期间按 key_pitch 变调 → gate 不受影响
//     ⇒ 证明三个维度互不干扰，是真正"独立"的。
//
//  运行：vsim -c -work work tb_interaction
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_interaction;

    localparam real    TCLK = 20.0;      // 50 MHz
    localparam integer DB   = 131072;    // 去抖窗：2^17 clk = 2.621 ms

    reg clk = 1'b0;
    reg key = 1'b1;          // 板载按键：未按下 = 1（内部上拉），按下 = 0
    reg key2 = 1'b1;
    reg key_pitch = 1'b1;

    wire [3:0]  led;
    wire        HP_BCK, HP_WS, HP_DIN, PA_EN;

    // ★ TEST_MODE = 0 → 演奏模式，gate 由按键驱动（这才是要测的通路）
    top #(
        .TEST_MODE (0),
        .BCK_DIV   (1)
    ) dut (
        .clk       (clk),
        .led       (led),
        .HP_BCK    (HP_BCK),
        .HP_WS     (HP_WS),
        .HP_DIN    (HP_DIN),
        .PA_EN     (PA_EN),
        .key       (key),
        .key2      (key2),
        .key_pitch (key_pitch)
    );

    always #(TCLK/2.0) clk = ~clk;

    integer errors = 0;

    // ---- 观察点（层次化引用 DUT 内部信号，仅用于验证，不参与综合）----
    wire [31:0] gate = dut.gate;
    wire        key_db = dut.key_db;
    wire [1:0]  timbre_user = dut.timbre_user;
    wire [3:0]  pitch_step = dut.pitch_step;
    wire signed [3:0] pitch_semi = dut.pitch_semi;

    // 取第 0 路的包络电平（adsr 是逐路并行的 en_level 数组）
    wire [16:0] env0 = dut.u_adsr.en_level[0];

    // ------------------------------------------------------------------ 工具
    task wait_clk(input integer n);
        integer i;
        begin for (i = 0; i < n; i = i + 1) @(posedge clk); end
    endtask

    // 按一下某个键：按下保持 hold 拍，再松开
    task press(input integer which, input integer hold);
        begin
            case (which)
                1: key       = 1'b0;
                2: key2      = 1'b0;
                3: key_pitch = 1'b0;
            endcase
            wait_clk(hold);
            case (which)
                1: key       = 1'b1;
                2: key2      = 1'b1;
                3: key_pitch = 1'b1;
            endcase
            wait_clk(hold);
        end
    endtask

    // 抖动：快速通断 n 次（每次远短于去抖窗），最后保持 released
    task glitch(input integer which, input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                case (which)
                    1: key = 1'b0;
                    2: key2 = 1'b0;
                endcase
                wait_clk(3);
                case (which)
                    1: key = 1'b1;
                    2: key2 = 1'b1;
                endcase
                wait_clk(3);
            end
        end
    endtask

    // ------------------------------------------------------------------ 主流程
    initial begin
        $display("[INT] ================ 交互通路验证（TEST_MODE=0 演奏模式）================ ");

        // 复位（top 内部有 por 上电复位，等它释放：2^19 clk ≈ 10.5 ms，这里多等一些）
        key = 1'b1; key2 = 1'b1; key_pitch = 1'b1;
        wait_clk(600000);                       // ≈ 12 ms，越过 por 与去抖窗
        wait_clk(DB + 1000);

        // ---------- 1. 复位后应静音 ----------
        $display("[INT] 1) 复位后 : gate=%h  env0=%0d  key_db=%b", gate, env0, key_db);
        if (gate !== 32'd0) begin
            $display("[INT] ERROR 1: 复位后 gate 应为全 0，实际 %h", gate);
            errors = errors + 1;
        end
        if (env0 !== 17'd0) begin
            $display("[INT] ERROR 1b: 复位后包络电平应为 0，实际 %0d", env0);
            errors = errors + 1;
        end

        // ---------- 2. 抖动用例：短抖动不应被认账 ----------
        begin
            reg db_before_v;
            db_before_v = key_db;
            glitch(1, 10);                      // 抖动 10 次（每次 6 拍，远短于去抖窗）
            wait_clk(DB + 1000);                // 等去抖窗过去
            $display("[INT] 2) 抖动用例 : key_db 之前=%b 之后=%b（抖动 10 次）", db_before_v, key_db);
            if (key_db !== db_before_v) begin
                $display("[INT] ERROR 2: 短抖动被误认为按键（去抖失效）");
                errors = errors + 1;
            end
        end

        // ---------- 3. 按住 key → gate 全 1 且包络起音 ----------
        key = 1'b0;
        wait_clk(DB + 2000);                    // 越过去抖
        $display("[INT] 3) 按住 key : gate=%h  key_db=%b", gate, key_db);
        if (gate !== {32{1'b1}}) begin
            $display("[INT] ERROR 3: 按住 key 后 gate 应为全 1，实际 %h", gate);
            errors = errors + 1;
        end
        if (key_db !== 1'b1) begin
            $display("[INT] ERROR 3b: 去抖后 key_db 应为 1，实际 %b", key_db);
            errors = errors + 1;
        end
        begin
            reg [16:0] e_a, e_b;
            wait_clk(200000);                   // 给包络一点时间起音
            e_a = env0;
            wait_clk(400000);
            e_b = env0;
            $display("[INT] 4) 包络起音 : env0 %0d -> %0d（应递增）", e_a, e_b);
            if (e_b <= e_a) begin
                $display("[INT] ERROR 4: 按住期间包络电平没有上升（起音未生效）");
                errors = errors + 1;
            end
        end

        // ---------- 5. 按住期间换音色：gate 不应受影响（维度独立性）----------
        begin
            reg [1:0] t_before;
            t_before = timbre_user;
            // ★ 注意：key 仍按住不放，这正是"独立性"的关键测试条件
            press(2, DB + 2000);
            $display("[INT] 5) 按住期间换音色 : timbre %0d -> %0d，gate=%h",
                     t_before, timbre_user, gate);
            if (timbre_user !== (t_before + 2'd1)) begin
                $display("[INT] ERROR 5: 按一下 key2 后音色号未 +1");
                errors = errors + 1;
            end
            if (gate !== {32{1'b1}}) begin
                $display("[INT] ERROR 5b: 换音色影响了 gate（维度不独立！）gate=%h", gate);
                errors = errors + 1;
            end
        end

        // ---------- 6. 按住期间变调：gate 不应受影响 ----------
        begin
            reg signed [3:0] p_before;
            reg [3:0] s_before;
            p_before = pitch_semi;
            s_before = pitch_step;
            press(3, DB + 2000);
            $display("[INT] 6) 按住期间变调 : pitch_semi %0d -> %0d，gate=%h",
                     p_before, pitch_semi, gate);
            if (pitch_step !== (s_before + 4'd1)) begin
                $display("[INT] ERROR 6: 按一下 key_pitch 后变调档位未 +1");
                errors = errors + 1;
            end
            if (pitch_semi !== (p_before + 4'sd1)) begin
                $display("[INT] ERROR 6b: pitch_semi 未按预期变化");
                errors = errors + 1;
            end
            if (gate !== {32{1'b1}}) begin
                $display("[INT] ERROR 6c: 变调影响了 gate（维度不独立！）gate=%h", gate);
                errors = errors + 1;
            end
        end

        // ---------- 7. 松开 key → gate 全 0 且包络释放 ----------
        key = 1'b1;
        wait_clk(DB + 2000);
        $display("[INT] 7) 松开 key : gate=%h  key_db=%b", gate, key_db);
        if (gate !== 32'd0) begin
            $display("[INT] ERROR 7: 松开 key 后 gate 应为全 0，实际 %h", gate);
            errors = errors + 1;
        end
        begin
            reg [16:0] e_c, e_d;
            e_c = env0;
            wait_clk(600000);
            e_d = env0;
            $display("[INT] 8) 包络释放 : env0 %0d -> %0d（应递减）", e_c, e_d);
            if (e_d >= e_c) begin
                $display("[INT] ERROR 8: 松开后包络电平没有下降（释放未生效）");
                errors = errors + 1;
            end
        end

        // ---------- 9. 音色 4 档循环 ----------
        begin
            reg [1:0] t0, t1, t2, t3;
            t0 = timbre_user;
            press(2, DB + 2000); t1 = timbre_user;
            press(2, DB + 2000); t2 = timbre_user;
            press(2, DB + 2000); t3 = timbre_user;
            press(2, DB + 2000);
            $display("[INT] 9) 音色循环 : %0d -> %0d -> %0d -> %0d -> %0d（应回到起点）",
                     t0, t1, t2, t3, timbre_user);
            if (timbre_user !== t0) begin
                $display("[INT] ERROR 9: 连按 4 下后音色号未回到起点");
                errors = errors + 1;
            end
        end

        $display("==============================================================");
        if (errors == 0)
            $display("[TESTBENCH] PASS  interaction errors=0（三维度独立可控已验证）");
        else
            $display("[TESTBENCH] FAIL  interaction errors=%0d", errors);
        $display("==============================================================");
        $stop;
    end

endmodule

`default_nettype wire
