// 临时探针 TB（非交付物）：把 piano_voice 内部关键节点打出来看直流/削顶从哪来
`timescale 1ns/1ps
`default_nettype none
module tb_probe;
    reg clk = 0; always #10 clk = ~clk;
    reg rst_n = 0;
    reg [9:0] tc = 0; reg tick = 0;
    always @(posedge clk) begin
        if (tc == 10'd511) begin tc <= 0; tick <= 1; end
        else begin tc <= tc + 1; tick <= 0; end
    end
    reg on_v = 0, off_v = 0;
    reg [6:0] on_n = 0, on_vel = 0, off_n = 0;
    wire signed [15:0] mix;
    wire [7:0] act;
    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .mix_out(mix), .active(act));

    integer k;
    initial begin
        repeat (40) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);
        @(posedge clk); on_n <= 7'd69; on_vel <= 7'd100; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0;
        // 等第 3 个采样点（相位已经推进过）
        for (k = 0; k < 6; k = k + 1) begin
            @(posedge clk);
            while (!tick) @(posedge clk);
        end
        $display("--- 逐采样点探针（第 6..16 个 tick）---");
        for (k = 0; k < 12; k = k + 1) begin
            @(posedge clk);
            while (!tick) @(posedge clk);
            #4;
            $display("t%0d mix=%0d vsum=%0d norm=%0d | v0: uni=%0d psum=%0d prod0=%0d prod1=%0d ham=%0d vout=%0d env0_hi=%0d ph0=%h lfo=%h",
                k, mix, dut.vsum, dut.norm,
                dut.g_voice[0].u_voice.uni_q, dut.g_voice[0].u_voice.psum,
                dut.g_voice[0].u_voice.prod[0], dut.g_voice[0].u_voice.prod[1],
                dut.g_voice[0].u_voice.ham_prod, dut.g_voice[0].u_voice.vout,
                dut.g_voice[0].u_voice.env[0][31:16],
                dut.g_voice[0].u_voice.ph[0], dut.g_voice[0].u_voice.lfo_ph);
        end
        $stop;
    end
endmodule
`default_nettype wire
