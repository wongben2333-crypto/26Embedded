// =============================================================================
//  tb_piano_engine_notescan.v —— 扫 note 0..127，找【哪些 note 失声】
//
//  用户报"17 个键里有键按下去没声音"。这个 TB 每个 note 单独复位后弹一次，
//  记录输出峰值与能量，输出 out/notescan.txt（note, peak, sumsq），
//  再由 Python 判哪些 note 静音。
//  每个 note 用【全新复位的空闲声部】⇒ 排除"复音数不够被抢占"的干扰。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_piano_engine_notescan;
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
        .vib_depth(7'd0), .vib_rate(7'd0), .sustain(1'b0),
        .inst_sel(2'd0),
        .mix_out(mix), .active(act));

    integer fd, n, k, g;
    integer peak, sumsq, v;
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask

    initial begin
        fd = $fopen("out/notescan.txt", "w");
        $display("[SCAN] 扫 note 0..127（每个 note 独立复位、力度 100）");
        for (n = 0; n < 128; n = n + 1) begin
            rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
            wait_ticks(2);
            // 发 note-on
            @(posedge clk); on_n <= n[6:0]; on_vel <= 7'd100; on_v <= 1'b1;
            @(posedge clk); on_v <= 1'b0;
            // 等 4 个采样点让包络/相位起来，再统计 8 个采样点
            wait_ticks(4);
            peak = 0; sumsq = 0;
            for (k = 0; k < 8; k = k + 1) begin
                wait_ticks(1);
                v = mix;
                if (v < 0) v = -v;
                if (v > peak) peak = v;
                sumsq = sumsq + v * v;
            end
            $fwrite(fd, "%0d %0d %0d\n", n, peak, sumsq);
        end
        $fclose(fd);
        $display("[SCAN] 完成 → out/notescan.txt");
        $stop;
    end
endmodule
`default_nettype wire
