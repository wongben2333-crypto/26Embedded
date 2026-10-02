// =============================================================================
//  tb_diag.v —— 诊断 tone_bank：每个采样周期里 32 个累加拍实际读到的 acc[索引] 次数
//
//  原理：sine_rom 是【1 拍延迟】（val <= mem[addr]，无地址寄存器）⇒
//        累加拍 B 加到 sum 上的是 f(addr(B-1))，所以统计 addr(B-1)。
//  在 negedge 采样，避开 posedge 的 NBA 观察顺序歧义。
//  读取次数直接决定该路电平：读 2 次 = +6 dB，读 3 次 = +9.5 dB，读 0 次 = 该音消失。
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_diag;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    wire               sample_tick;
    wire signed [15:0] mix;
    wire               bck_o, ws_o, din_o;

    always #10 clk = ~clk;          // 50 MHz

    pt8211_tx #(.BCK_DIV(2)) u_dac (
        .clk(clk), .reset(~rst_n),
        .sample_l(mix), .sample_r(mix),
        .sample_tick(sample_tick),
        .bck(bck_o), .ws(ws_o), .din(din_o)
    );

    tone_bank u_bank (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick),
        .mix_out(mix)
    );

    integer fd;
    integer seen  = 0;
    integer total = 0;
    integer periods_done = 0;
    reg rec = 1'b0;
    reg [4:0] prev_amux = 5'd0;
    integer hist [0:31];
    integer i;

    initial fd = $fopen("diag.txt", "w");

    initial begin
        for (i = 0; i < 32; i = i + 1) hist[i] = 0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
    end

    initial begin
        #2_000_000;
        $display("[diag] TIMEOUT");
        $finish;
    end

    // 只在 negedge 观察；以 sample_tick 计周期（每周期恰好一个 tick）
    always @(negedge clk) begin
        if (rst_n) begin
            if (sample_tick) begin
                seen = seen + 1;
                if (seen == 2) rec = 1'b1;
                if (seen == 7) rec = 1'b0;
            end
            if (rec) begin
                // 注意：这里的窗口长度必须与 tone_bank.v 的累加窗口一致。
                // 当前 RTL 用 samp_cnt <= N_VOICES+1 = 33（即 34 拍），故用 < 34。
                if (!sample_tick && u_bank.samp_cnt < 6'd34) begin
                    hist[prev_amux] = hist[prev_amux] + 1;
                    total = total + 1;
                end
                prev_amux = u_bank.addr_mux;
            end
            if (seen == 7 && periods_done == 0) begin
                periods_done = 1;
                $fdisplay(fd, "=== 每路读取次数（%0d 个完整采样周期，%0d 次累加）===", 5, total);
                for (i = 0; i < 32; i = i + 1)
                    $fdisplay(fd, "voice[%0d] freq=%0d Hz read_times=%0d", i, 200 + 200 * i, hist[i]);
                $display("[diag] wrote diag.txt total=%0d", total);
                $fclose(fd);
                $finish;
            end
        end
    end

endmodule

`default_nettype wire
