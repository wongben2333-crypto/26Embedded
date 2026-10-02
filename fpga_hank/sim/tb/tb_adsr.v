// =============================================================================
//  tb_adsr.v —— ADSR 包络验证（电平敏感 gate）
//
//  ★ 接口语义：gate[v] 高 = 该声部按键【按住】；低 = 松开。
//    不是单拍脉冲 —— 这是本模块第一版最大的设计错误。
//
//  ★ 测试方法：不用"等固定拍数再断言"。
//    第一版就是这么写的，结果因为算错相位而误报（在 SUS 阶段断言 DEC）。
//    改为【轮询状态转移】：记录看到过的 phase 序列，再断言序列正确、
//    以及每个阶段结束时的电平正确。这样与具体拍数无关，不会算错。
//
//  预期相位序列（gate 从高到低）：
//     IDLE(0) → ATK(1) → DEC(2) → SUS(3) → [gate 松] → IDLE(0)
//
//  时序（EN_DIV=8, clk=50 MHz，每步 160 ns）：
//     ATK_INC = (1<<16)>>8  = 256  → 512 步   ≈ 4.1 µs 爬满
//     DEC_INC = (1<<16)>>10 = 64   → 81920 步 ≈ 655 µs 降到 SUS
//     REL_INC = (1<<16)>>12 = 16   → 8192 步  ≈ 65.5 ms 释放完
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_adsr;

    localparam real TCLK = 20.0;
    localparam integer NV = 4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [NV-1:0] gate = {NV{1'b0}};

    reg [4:0]  voice_rd = 5'd0;
    wire [16:0] level_rd;
    wire [1:0]  phase_rd;

    // ★ 参数必须与 top.v 的实际例化一致，否则波形图描述的是"过期设计"。
//   本项目踩过：本测试台长期用 EN_DIV=8/ATK_SH=8（旧值），而 top.v 已改为
//   EN_DIV=512/DIV_W=16/ATK_SH=10/REL_SH=13，导致导出的包络曲线
//   与真实设计不符（图上量到的时长与题注差约 100 倍）。
// ★ 超时必须【由参数推导】，不能硬编码。
//   本项目踩过：测试台原写死 ATK 超时 100000 拍（=2 ms），而 EN_DIV=512 时
//   起音需要 2^10 × 512 = 524288 拍（10.5 ms）才完成，于是误报
//   "未从 ATK 进入 DEC"。参数一改就对不上 —— 所以这里全部按公式算。
localparam integer EN_DIV_P = 512;
localparam integer ATK_STEPS = (1 << 10);                    // 65536 >> ATK_SH
localparam integer DEC_STEPS = (1 << 10);                    // 65536 >> DEC_SH
localparam integer REL_STEPS = 49152 / ((1 << 16) >> 13);    // sustain / REL_INC
localparam integer TO_ATK = ATK_STEPS * EN_DIV_P * 2 + 10000;
localparam integer TO_DEC = DEC_STEPS * EN_DIV_P * 2 + 10000;
localparam integer TO_REL = REL_STEPS * EN_DIV_P * 3 + 10000;
adsr #(.N_VOICES(NV), .EN_DIV(512), .DIV_W(16), .ATK_SH(10), .DEC_SH(10), .REL_SH(13),
           .SUS_LEVEL(49152)) dut (
        .clk(clk), .rst_n(rst_n), .gate(gate),
        .voice_rd(voice_rd), .level_rd(level_rd), .phase_rd(phase_rd)
    );

    always #(TCLK/2.0) clk = ~clk;

    integer errors = 0;

    // 轮询直到相位变化或超时，返回等待的拍数
    task wait_phase_change(input [1:0] from, input integer limit, output integer waited);
        integer i;
        begin
            i = 0;
            while (phase_rd === from && i < limit) begin
                @(posedge clk);
                i = i + 1;
            end
            waited = i;
        end
    endtask

    // --------------------------------------------- 包络曲线导出（真实仿真值）---
    integer wf_fd;
    initial wf_fd = $fopen("C:/Users/Danny/Desktop/FPGA competition/fpga_hank/out/wave_adsr.csv", "w");
    // 每 512 个 clk 采一次包络电平，覆盖完整的 起音→衰减→保持→释放
    initial begin
        forever begin
            repeat (512) @(posedge clk);
            if (wf_fd != 0) $fwrite(wf_fd, "%0d,%0d,%0d,%b\n", $time, level_rd, phase_rd, gate[0]);
        end
    end
    initial begin
        integer w;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        voice_rd = 5'd0;

        // ---------- 1. 复位后静音 ----------
        if (level_rd !== 17'd0 || phase_rd !== 2'd0) begin
            $display("[ADSR] ERROR 1: 复位后 level=%0d phase=%0d（应 0/0）", level_rd, phase_rd);
            errors = errors + 1;
        end else $display("[ADSR] ok 1: 复位后静音");

        // ---------- 2. 按住：IDLE -> ATK ----------
        gate[0] = 1'b1;
        wait_phase_change(2'd0, 10, w);
        if (phase_rd !== 2'd1) begin
            $display("[ADSR] ERROR 2: 按住后未进入 ATK，phase=%0d", phase_rd);
            errors = errors + 1;
        end else $display("[ADSR] ok 2: 按住 → ATK");

        // ---------- 3. ATK -> DEC，且到 DEC 时电平应接近满幅 ----------
        wait_phase_change(2'd1, TO_ATK, w);
        if (phase_rd !== 2'd2) begin
            $display("[ADSR] ERROR 3: 未从 ATK 进入 DEC，phase=%0d level=%0d", phase_rd, level_rd);
            errors = errors + 1;
        end else begin
            $display("[ADSR] ok 3: ATK → DEC（%0d 拍），DEC 起点 level=%0d", w, level_rd);
            if (level_rd < 17'h0_F000) begin
                $display("[ADSR] ERROR 3b: 进入 DEC 时电平过低 (%0d)，应接近满幅", level_rd);
                errors = errors + 1;
            end
        end

        // ---------- 4. DEC -> SUS，且 SUS 电平应等于 49152 ----------
        wait_phase_change(2'd2, TO_DEC, w);
        if (phase_rd !== 2'd3) begin
            $display("[ADSR] ERROR 4: 未从 DEC 进入 SUS，phase=%0d level=%0d", phase_rd, level_rd);
            errors = errors + 1;
        end else begin
            $display("[ADSR] ok 4: DEC → SUS（%0d 拍），level=%0d (%.3f)", w, level_rd,
                     $itor(level_rd)/65536.0);
            if (level_rd !== 17'd49152) begin
                $display("[ADSR] ERROR 4b: SUS 电平应为 49152，实测 %0d", level_rd);
                errors = errors + 1;
            end
        end

        // ---------- 5. SUS 阶段必须稳定 ----------
        begin
            reg [16:0] hold_a;
            integer k;
            hold_a = level_rd;
            for (k = 0; k < 2000; k = k + 1) @(posedge clk);
            if (level_rd !== hold_a) begin
                $display("[ADSR] ERROR 5: SUS 阶段电平漂移 %0d -> %0d", hold_a, level_rd);
                errors = errors + 1;
            end else $display("[ADSR] ok 5: SUS 阶段稳定 (=%0d)", level_rd);
        end

        // ---------- 6. 松开：电平必须开始下降 ----------
        gate[0] = 1'b0;
        repeat (EN_DIV_P * 64) @(posedge clk);   // 由参数推导，原写死 4000 太短
        $display("[ADSR] release 中途: level=%0d phase=%0d", level_rd, phase_rd);
        if (level_rd >= 49152) begin
            $display("[ADSR] ERROR 6: 松开后电平未下降（仍 %0d）", level_rd);
            errors = errors + 1;
        end else $display("[ADSR] ok 6: 松开后电平下降中");

        // ---------- 7. 释放完 → 回 IDLE，电平 0 ----------
        wait_phase_change(2'd3, TO_REL, w);
        if (phase_rd !== 2'd0 || level_rd !== 17'd0) begin
            $display("[ADSR] ERROR 7: 释放未回 0/IDLE，level=%0d phase=%0d", level_rd, phase_rd);
            errors = errors + 1;
        end else $display("[ADSR] ok 7: 释放完成 → IDLE（%0d 拍），level=0", w);

        // ---------- 8. 二次触发必须能重新起音（声部可复用） ----------
        gate[0] = 1'b1;
        wait_phase_change(2'd0, 10, w);
        if (phase_rd !== 2'd1 || level_rd !== 17'd0) begin
            $display("[ADSR] ERROR 8: 二次触发未重新起音，level=%0d phase=%0d", level_rd, phase_rd);
            errors = errors + 1;
        end else $display("[ADSR] ok 8: 二次触发重新起音");
        gate[0] = 1'b0;
        repeat (EN_DIV_P * 64) @(posedge clk);

        // ---------- 9. 未触发声部必须恒为 0 ----------
        begin
            integer i;
            integer bad = 0;
            for (i = 1; i < NV; i = i + 1) begin
                voice_rd = i[4:0];
                repeat (2) @(posedge clk);
                if (level_rd !== 17'd0) begin
                    $display("[ADSR] ERROR 9: 未触发声部 %0d 电平=%0d（应 0）", i, level_rd);
                    bad = bad + 1;
                end
            end
            voice_rd = 5'd0;
            if (bad == 0) $display("[ADSR] ok 9: 未触发声部全部静音");
            errors = errors + bad;
        end

        $display("==============================================");
        if (errors == 0) $display("[TESTBENCH] PASS  ADSR errors=0");
        else             $display("[TESTBENCH] FAIL  ADSR errors=%0d", errors);
        $display("==============================================");
        $stop;   // ★ 用 $stop 而非 $finish：run.do 要连续跑多个 tb，$finish 会终止整个 vsim
    end

endmodule

`default_nettype wire
