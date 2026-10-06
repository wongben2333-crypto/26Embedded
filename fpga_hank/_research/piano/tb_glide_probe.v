// 临时探针（非交付物）：滑音为什么不 ramp
`timescale 1ns/1ps
`default_nettype none
module tb_glide_probe;
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
    reg glide_on = 0; reg [6:0] glide_time = 0;
    wire signed [15:0] mix; wire [7:0] act;
    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(glide_on), .glide_time(glide_time), .vib_on(1'b0),
        .vib_depth(7'd0), .vib_rate(7'd0), .inst_sel(2'd0), .sustain(1'b0),
        .mix_out(mix), .active(act));

    integer g; integer n;
    task do_on; input [6:0] nn; input [6:0] vv; begin
        @(posedge clk); on_n <= nn; on_vel <= vv; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0; @(posedge clk); end
    endtask
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask

    initial begin
        repeat (40) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk);
        glide_on = 1'b1; glide_time = 7'd64;
        $display("glide_act=%b recip=%0d", dut.glide_act, dut.glide_recip_bus);
        do_on(7'd69, 7'd100);
        wait_ticks(2000);
        $display("A4: sel=%0d lf0=%0d cur0=%0d gliding0=%b", dut.alloc_sel, dut.ld_f0,
                 dut.g_voice[0].u_voice.f0_cur, dut.g_voice[0].u_voice.gliding);
        // 第二个音符 → 应该滑
        do_on(7'd81, 7'd100);
        for (n = 0; n < 6; n = n + 1) begin
            wait_ticks(2000);
            $display("t%0d: glide_on=%b glide_time=%0d glide_act=%b recip16=%0d | engine: g_step=%0d ld_f0=%0d ld_sel=%0d | v0: f0_cur=%0d f0_tgt=%0d gstep=%0d gliding=%b gate=%b hold=%b",
                     n, glide_on, glide_time, dut.glide_act, dut.glide_recip_bus[15:0],
                     dut.g_step_r, dut.ld_f0, dut.ld_sel,
                     dut.g_voice[0].u_voice.f0_cur, dut.g_voice[0].u_voice.f0_tgt,
                     dut.g_voice[0].u_voice.gstep_r, dut.g_voice[0].u_voice.gliding,
                     dut.g_voice[0].u_voice.gate_r, dut.g_voice[0].u_voice.glide_hold);
        end
        $stop;
    end
endmodule
`default_nettype wire
