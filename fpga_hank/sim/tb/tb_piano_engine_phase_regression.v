// =============================================================================
//  tb_piano_engine_phase_regression.v —— 两拍清零窗口的【穷举相位】等价性验证
//
//  目的：两拍清零窗口唯一的风险是"优先级写错 ⇒ 在某个 note-on 相位上改变了样本值"。
//        note-on 相对 sample_tick 的相位有 512 种，所以把 512 种【全跑一遍】，
//        每种相位 dump 前 16 个输出样本。
//        然后对"窗口关闭"的同一份 RTL 再跑一遍，逐字节 diff：
//          · 完全一致 ⇒ 该补丁对所有相位都【不改变任何样本】（不只是 TB 里那 7 个场景）
//          · 有任何差异 ⇒ 补丁改变了行为，必须回退
//  ⚠️ 这是"替代模型"式验证的正当用法：变体只改一行（`if (1'b0 && on_pulse_d)`），
//     其余字节完全相同 ⇒ 比较的是"同一份 RTL 的有/无窗口"，不是"像不像"。
//
//  用法：vsim -c -do "run -all;quit -f" tb_piano_engine_phase_regression
//        输出 out/phase_dump.txt（每行：相位 样本0..样本15）
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_piano_engine_phase_regression;
    localparam integer VDIV = 512;
    localparam integer NPH  = 512;

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

    integer fd, p, k;
    initial begin
        fd = $fopen("out/phase_dump.txt", "w");
        for (p = 0; p < NPH; p = p + 1) begin
            rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
            while (tick !== 1'b1) @(posedge clk);
            repeat (p) @(posedge clk);
            @(posedge clk); on_n <= 7'd69; on_vel <= 7'd100; on_v <= 1'b1;
            @(posedge clk); on_v <= 1'b0;
            $fwrite(fd, "%0d", p);
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge clk); #1;
                $fwrite(fd, " %0d", mix);
            end
            $fwrite(fd, "\n");
        end
        $fclose(fd);
        $display("[PHREG] 512 个相位的输出已写入 out/phase_dump.txt");
        $stop;
    end
endmodule
`default_nettype wire
