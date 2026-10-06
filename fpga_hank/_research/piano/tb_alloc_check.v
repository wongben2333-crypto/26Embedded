// =============================================================================
//  tb_alloc_check.v —— 把"树形分配器"与"老串行分配器"的参考模型【逐拍】对照
//
//  背景：换掉分配器后逐样本回归在 T4/T5/T6 上不一致（T1~T3 一致），
//  说明新老算法在某些输入组合下决策不同。光靠"读代码"看不出来，
//  所以这里把老算法写成参考模型（组合逻辑），每一拍和 DUT 的 alloc_sel 对照，
//  一旦不同就打印当时的所有输入 —— 直接定位到具体是哪一组状态。
//
//  用法：vsim -c -do "run -all;quit -f" tb_alloc_check
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_alloc_check;
    localparam integer VDIV = 512;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg [9:0] tc = 0; reg tick = 0;
    always @(posedge clk) begin
        if (tc == VDIV-1) begin tc <= 0; tick <= 1; end
        else begin tc <= tc + 1; tick <= 0; end
    end

    reg on_v = 0, off_v = 0;
    reg [6:0] on_n = 0, on_vel = 0, off_n = 0;
    wire signed [15:0] mix; wire [7:0] act;
    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(1'b0), .glide_time(7'd0), .vib_on(1'b0),
        .vib_depth(7'd0), .vib_rate(7'd0), .inst_sel(2'd0), .sustain(1'b0),
        .mix_out(mix), .active(act));

    // ---------------- 老串行分配器的参考模型（照抄改动前的代码） ----------------
    reg  [3:0] r_sel;
    reg        r_hit;
    integer    ai;
    reg  [3:0] idx;
    reg  [7:0] v_gate, v_act;
    reg  [55:0] v_note;
    assign v_gate = dut.v_gate;
    assign v_act  = dut.v_active;
    assign v_note = dut.v_note_flat;
    always @(*) begin
        r_sel = 4'd0;
        r_hit = 1'b0;
        // ⓪ 滑音（本 TB 恒 0）
        if (1'b0) begin r_sel = 4'd0; r_hit = 1'b1; end
        // ① 同音重击
        for (ai = 0; ai < 8; ai = ai + 1) begin
            if (!r_hit && v_gate[ai] && (v_note[ai*7 +: 7] == on_n)) begin
                r_sel = ai[3:0]; r_hit = 1'b1;
            end
        end
        // ② 空闲
        for (ai = 0; ai < 8; ai = ai + 1) begin
            idx = dut.rr + ai[3:0];
            if (idx >= 4'd8) idx = idx - 4'd8;
            if (!r_hit && !v_act[idx]) begin r_sel = idx; r_hit = 1'b1; end
        end
        // ③ 已松开
        for (ai = 0; ai < 8; ai = ai + 1) begin
            idx = dut.rr + ai[3:0];
            if (idx >= 4'd8) idx = idx - 4'd8;
            if (!r_hit && !v_gate[idx]) begin r_sel = idx; r_hit = 1'b1; end
        end
        // ④ 兜底
        for (ai = 0; ai < 8; ai = ai + 1) begin
            idx = dut.rr + ai[3:0];
            if (idx >= 4'd8) idx = idx - 4'd8;
            if (!r_hit) begin r_sel = idx; r_hit = 1'b1; end
        end
    end

    integer nbad, nchk;
    always @(posedge clk) begin
        #1;
        nchk = nchk + 1;
        if (dut.alloc_sel !== r_sel) begin
            nbad = nbad + 1;
            if (nbad <= 12)
                $display("MISMATCH t=%0t dut=%0d ref=%0d | rr=%0d gate=%b act=%b on_n=%0d lastv=%b/%0d | vm=%b m_same=%b m_idle=%b m_rel=%b ge=%b lt=%b s1=%0d s2=%0d s3=%0d",
                         $time, dut.alloc_sel, r_sel, dut.rr, v_gate, v_act, on_n,
                         dut.last_valid, dut.last_voice,
                         dut.valid_mask, dut.g_alloc_tree.m_same, dut.g_alloc_tree.m_idle,
                         dut.g_alloc_tree.m_rel, dut.g_alloc_tree.ge, dut.g_alloc_tree.lt,
                         dut.g_alloc_tree.s1, dut.g_alloc_tree.s2, dut.g_alloc_tree.s3);
        end
    end

    task do_on; input [6:0] n; input [6:0] v; begin
        @(posedge clk); on_n <= n; on_vel <= v; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0; @(posedge clk); end
    endtask
    task do_off; input [6:0] n; begin
        @(posedge clk); off_n <= n; off_v <= 1'b1;
        @(posedge clk); off_v <= 1'b0; @(posedge clk); end
    endtask
    integer g;
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask

    initial begin
        nbad = 0; nchk = 0;
        repeat (40) @(posedge clk); rst_n = 1;
        repeat (20) @(posedge clk);
        // 复现 TB 里 T3（三音和弦）→ note-off → wait → T4（单音）
        do_on(7'd60, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd64, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd67, 7'd100); repeat (200) @(posedge clk);
        do_off(7'd60); do_off(7'd64); do_off(7'd67);
        wait_ticks(40000);
        do_on(7'd69, 7'd30);
        wait_ticks(2000);
        do_off(7'd69);
        wait_ticks(40000);
        // 再复现 T6（8 音）
        do_on(7'd60, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd64, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd67, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd71, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd74, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd78, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd81, 7'd100); repeat (20) @(posedge clk);
        do_on(7'd84, 7'd100);
        wait_ticks(2000);
        $display("对照完成：检查 %0d 拍，不一致 %0d 拍", nchk, nbad);
        if (nbad == 0) $display("PASS: 树形分配器与串行参考模型逐拍一致");
        else          $display("FAIL: 存在决策不一致（见上面 MISMATCH）");
        $stop;
    end
endmodule
`default_nettype wire
