// =============================================================================
//  tb_alloc32_proof.v —— 32 声部分配器的【语义等价性证明】（N_VOICES=20/32 用）
//
//  背景：现有树形分配器只覆盖 N_VOICES<=8（8 bit 掩码）；>8 会退回串行链
//  （MODE=1 裕量只有 +0.009 ns ⇒ 串行链必然违例）。所以要把树形扩到 32 bit。
//
//  本 TB 把【新模式】与【串行黄金模型】放在同一模块里逐例比对：
//    新模式：32 bit 掩码 + 两级树形 low32（深度 5 级）
//    黄金模型：4 层串行优先级（与 RTL 原写法同语义：① 同音重击(0..N-1)
//              ②③④ 按 rr 旋转顺序）
//  ⚠️ 为什么等价性必须在【改 RTL 之前】先证：8 bit 版当初就是"先证后改"，
//     结果抓出 2'd4 回绕、s1[SEL_W-1:0] 越界两个真 bug。
//
//  用法：vsim -c -do "run -all;quit -f" tb_alloc32_proof
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_alloc32_proof;
    localparam integer N = 20;          // 目标声部数（32 也支持，见 N32 段）

    // ---------------- 新模式：8/16/32 bit 树形"最低置位" ----------------
    function [2:0] low8t;               // 已证版本
        input [7:0] m;
        reg [2:0] q0, q1, q2, q3, h0, h1;
        reg       a0, a1, a2, a3, b0, b1;
        begin
            a0 = m[0]|m[1]; q0 = m[0] ? 3'd0 : 3'd1;
            a1 = m[2]|m[3]; q1 = m[2] ? 3'd2 : 3'd3;
            a2 = m[4]|m[5]; q2 = m[4] ? 3'd4 : 3'd5;
            a3 = m[6]|m[7]; q3 = m[6] ? 3'd6 : 3'd7;
            b0 = a0|a1;     h0 = a0 ? q0 : q1;
            b1 = a2|a3;     h1 = a2 ? q2 : q3;
            low8t = b0 ? h0 : h1;
        end
    endfunction
    function [3:0] low16t;
        input [15:0] m;
        reg [2:0] lo, hi; reg alo, ahi;
        begin
            lo = low8t(m[7:0]);   alo = |m[7:0];
            hi = low8t(m[15:8]);  ahi = |m[15:8];
            low16t = alo ? {1'b0, lo} : {1'b1, hi};        // hi 要 +8
        end
    endfunction
    function [4:0] low32t;
        input [31:0] m;
        reg [3:0] lo, hi; reg alo, ahi;
        begin
            lo = low16t(m[15:0]);   alo = |m[15:0];
            hi = low16t(m[31:16]);  ahi = |m[31:16];
            low32t = alo ? {1'b0, lo} : {1'b1, hi};        // hi 要 +16
        end
    endfunction

    // ⚠️ 黄金模型的输入必须【先声明】：Verilog 要求声明在用之前
    //    （本 TB 第一版把 g_act/g_gate/g_nmatch 声明写在了 always 之后 ⇒ vlog 报 Undefined）
    reg [31:0] g_act, g_gate, g_nmatch;

    reg [31:0] vm, m_same, m_idle, m_rel, ge, lt;
    reg [4:0]  rr;
    reg [4:0]  new_sel;
    reg        n_same, n_idle, n_rel;
    reg [4:0]  s1, s2, s3;
    always @(*) begin
        vm     = (N >= 32) ? 32'hFFFF_FFFF : ((32'd1 << N) - 32'd1);
        m_same = vm & g_gate & g_nmatch;
        m_idle = vm & ~g_act;
        m_rel  = vm & ~g_gate;
        ge     = vm & (32'hFFFF_FFFF << rr);
        lt     = vm & ~(32'hFFFF_FFFF << rr);
        s1     = low32t(m_same);
        s2     = (|(m_idle & ge)) ? low32t(m_idle & ge) : low32t(m_idle & lt);
        s3     = (|(m_rel  & ge)) ? low32t(m_rel  & ge) : low32t(m_rel  & lt);
        n_same = |m_same; n_idle = |m_idle; n_rel = |m_rel;
        // 新模式（= 将来 RTL 的写法）
        if      (n_same) new_sel = s1[4:0];
        else if (n_idle) new_sel = s2[4:0];
        else if (n_rel)  new_sel = s3[4:0];
        else             new_sel = rr;
    end

    // ---------------- 黄金模型：串行优先（原语义） ----------------
    // （g_act/g_gate/g_nmatch 已在上面声明 —— 重复声明会报 vlog-2388）
    reg [4:0]  ref_sel;
    integer    ai; reg [4:0] idx; reg hit;
    always @(*) begin
        ref_sel = 5'd0; hit = 1'b0;
        for (ai = 0; ai < N; ai = ai + 1)                        // ① 同音重击 0..N-1
            if (!hit && g_gate[ai] && g_nmatch[ai]) begin ref_sel = ai[4:0]; hit = 1'b1; end
        for (ai = 0; ai < N; ai = ai + 1) begin                  // ② 空闲（旋转）
            idx = rr + ai[4:0];
            if (idx >= N) idx = idx - N[4:0];
            if (!hit && !g_act[idx])  begin ref_sel = idx; hit = 1'b1; end
        end
        for (ai = 0; ai < N; ai = ai + 1) begin                  // ③ 已松开（旋转）
            idx = rr + ai[4:0];
            if (idx >= N) idx = idx - N[4:0];
            if (!hit && !g_gate[idx]) begin ref_sel = idx; hit = 1'b1; end
        end
        for (ai = 0; ai < N; ai = ai + 1) begin                  // ④ 兜底（旋转）
            idx = rr + ai[4:0];
            if (idx >= N) idx = idx - N[4:0];
            if (!hit) begin ref_sel = idx; hit = 1'b1; end
        end
    end

    integer seed, i, k, nbad, nchk, b1, b2;
    reg [31:0] pat;
    initial begin
        seed = 32'hC0FFEE01; nbad = 0; nchk = 0;   // ★ 固定种子
        $display("[ALLOC32] N=%0d, 固定种子 0x%08X", N, seed);

        // ---- A. 结构化穷举：rr × 单活跃位 × 单门控位 × 4 种匹配模式 ----
        for (k = 0; k < N; k = k + 1) begin
            for (i = 0; i < N; i = i + 1) begin
                for (b1 = 0; b1 < N; b1 = b1 + 1) begin
                    g_act   = 32'd0; g_gate = 32'd0;
                    g_act[i] = 1'b1;  g_gate[b1] = 1'b1;
                    for (b2 = 0; b2 < 4; b2 = b2 + 1) begin
                        g_nmatch = (b2 == 0) ? 32'd0 :
                                   (b2 == 1) ? 32'hFFFF_FFFF :
                                   (b2 == 2) ? g_gate : (~g_gate);
                        rr = k[4:0]; #1;
                        nchk = nchk + 1;
                        if (new_sel !== ref_sel) begin
                            nbad = nbad + 1;
                            if (nbad <= 5)
                                $display("  MISMATCH rr=%0d act=%h gate=%h nm=%h new=%0d ref=%0d",
                                         rr, g_act, g_gate, g_nmatch, new_sel, ref_sel);
                        end
                    end
                end
            end
        end
        $display("[ALLOC32] A 结构化：检查 %0d 例，不一致 %0d", nchk, nbad);

        // ---- B. 随机 20 万例（含密集占用/释放混合） ----
        for (i = 0; i < 200000; i = i + 1) begin
            pat = $random(seed);
            g_act   = pat;
            g_gate  = $random(seed);
            g_nmatch= $random(seed);
            // ⚠️ rr 必须落在 0..N-1。第一版写 `rr = $random(seed) % N;`
            //    —— $random 是有符号的，负值取模后再截断进 5 bit 无符号 rr，
            //    会得到 20..31 这种【非法 rr】⇒ 黄金模型的旋转语义本身失效
            //    ⇒ 报出 150 例"假不一致"。这正是"检查工具本身要先自检"的又一例。
            rr      = ($random(seed) & 32'h7FFF_FFFF) % N;
            #1;
            nchk = nchk + 1;
            if (new_sel !== ref_sel) begin
                nbad = nbad + 1;
                if (nbad <= 10)
                    $display("  MISMATCH(rand) rr=%0d act=%h gate=%h nm=%h new=%0d ref=%0d",
                             rr, g_act, g_gate, g_nmatch, new_sel, ref_sel);
            end
        end
        $display("[ALLOC32] B 随机 20 万例：累计检查 %0d 例，不一致 %0d", nchk, nbad);
        if (nbad == 0)
            $display("[ALLOC32] ✅ PASS：32 bit 两级树形分配器与串行黄金模型【逐例一致】");
        else
            $display("[ALLOC32] ❌ FAIL：%0d 例不一致", nbad);
        $stop;
    end
endmodule
`default_nettype wire
