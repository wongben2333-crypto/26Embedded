// 临时探针 TB（非交付物）：复现 flow-verifier 的 TICKDIV=8 时序，看为什么第二个 note-on 无效
`timescale 1ns/1ps
`default_nettype none
module tb_probe2;
    localparam integer TICKDIV = 8;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg tick = 0; integer td = 0;
    always @(posedge clk) begin td <= td + 1; tick <= ((td % TICKDIV) == 0); end

    reg on_valid = 0, off_valid = 0;
    reg [6:0] on_note = 0, on_vel = 0, off_note = 0;
    wire signed [15:0] mix;
    wire [7:0] active;
    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_valid), .on_note(on_note), .on_vel(on_vel),
        .off_valid(off_valid), .off_note(off_note),
        .mix_out(mix), .active(active));

    integer g, k;
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask
    task do_on; input [6:0] n; input [6:0] v; begin
        @(posedge clk); on_note <= n; on_vel <= v; on_valid <= 1'b1;
        @(posedge clk); on_valid <= 1'b0; @(posedge clk); end
    endtask
    task do_off; input [6:0] n; begin
        @(posedge clk); off_note <= n; off_valid <= 1'b1;
        @(posedge clk); off_valid <= 1'b0; @(posedge clk); end
    endtask
    task dump; input [8*24-1:0] tag; begin
        $display("%-10s active=%b ld_st=%0d ld_busy=%b ld_sel=%0d ld_stb=%b alloc=%0d rr=%0d dsel=%0d | v0 g=%b n=%0d env0=%0d v1 g=%b n=%0d env0=%0d vout0=%0d vout1=%0d",
            tag, active, dut.ld_st, dut.ld_busy, dut.ld_sel, dut.ld_stb, dut.alloc_sel, dut.rr, dut.ld_sel,
            dut.g_voice[0].u_voice.gate_r, dut.g_voice[0].u_voice.note_r, dut.g_voice[0].u_voice.env[0][31:16],
            dut.g_voice[1].u_voice.gate_r, dut.g_voice[1].u_voice.note_r, dut.g_voice[1].u_voice.env[0][31:16],
            dut.g_voice[0].u_voice.vout, dut.g_voice[1].u_voice.vout);
    end endtask

    initial begin
        repeat (20) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk);
        // ---- A4 ----
        do_on(7'd69, 7'd100); wait_ticks(200); dump("A4 on+200");
        wait_ticks(1800); dump("A4 cap-end");
        do_off(7'd69); wait_ticks(3000); dump("A4 off+3k");
        // ---- A5（flow-verifier 在这一点失败）----
        do_on(7'd81, 7'd100);
        repeat (40) @(posedge clk); dump("A5 +40clk");
        wait_ticks(2000); dump("A5 +2k");
        wait_ticks(2000); dump("A5 +4k");
        do_off(7'd81); wait_ticks(3000); dump("A5 off+3k");
        $stop;
    end
endmodule
`default_nettype wire
