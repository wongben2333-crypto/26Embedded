// =============================================================================
//  tb_erhu_steady.v 鈥斺€?浜岃儭銆愮ǔ鎬佹銆戣皭娉㈠箙搴︽祴閲忥紙Lead 瑕佹眰鐨?鍏堟祴鍐嶆敼"绗?1 姝ワ級
//
//  涓轰粈涔堥渶瑕佹柊 TB锛?//    鐜版湁 TB 鐨?dump 鍙湁 4k~32k 閲囨牱鐐癸紙鈮?2~330 ms锛夆湕
//    鑰屾垜浠鐨勭ǔ鎬佺獥鍙ｆ槸 **0.3 s ~ 1.5 s** 鈬?闇€瑕?鈮?17k 涓噰鏍风偣 鉁?//  鈿狅笍 涓轰粈涔?0.3~1.5 s"鏄ǔ鎬侊紙鏈?TB 鐨勫垽鎹紝蹇呴』鍐欐竻锛夛細
//    - 璧锋尟鏂滃潯鍒伴《闇€ 2^s/16 = 8192 鎷?鈮?**84 ms** 鈬?0.3 s 鏃躲€愭棭宸插埌椤躲€戔湏
//    - 浜岃儭鍦?gate_r=1 鏃剁敱 `drive` 鎸佺画渚涜兘 鈬?`env 鈫?env*` **鎭掑畾** 鈬?涓嶆槸琛板噺淇″彿 鉁?//    - 鎵€浠?0.3 s 涔嬪悗鏄€愮湡绋虫€併€戯紙閽㈢惔/鍚変粬涓嶆槸锛氬畠浠細琛板噺 鈬?鏈?TB 鍙敤浜庝簩鑳?鉁擄級
//
//  鐢ㄦ硶锛歍B 鍐?NOTE 鐢辫窇鑴氭湰鏂囨湰鏇挎崲锛?'d69 鈫?7'd62 / 7'd74锛?//        鈬?out/steady.txt锛堟瘡涓噰鏍风偣涓€琛岋級
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_erhu_steady;
    localparam integer VDIV   = 512;
    localparam integer NWAIT  = 15000;    // 鈮?.307 s 绛夊緟锛堣捣鎸?+ 鍒扮ǔ鎬侊級
    localparam integer NDUMP  = 48828;   // 鈮?.23 s 绋虫€佺獥

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
        .inst_sel(2'd3),                 // 浜岃儭锛?/3 閮芥槧灏勫埌绗笁妲斤級
        .bow_speed(7'd64),               // 鈽?鏄惧紡椹卞姩锛? 浼氶€€鍥?鍥哄畾涓€熷厹搴?锛岃繖閲岀粰 64
        .mix_out(mix), .active(act));

    integer fd, g;
    task wait_ticks; input integer nt; begin
        g = 0; while (g < nt) begin @(posedge clk); if (tick) g = g + 1; end end
    endtask

    initial begin
        // 文件名【带音高】：否则同一个 work 目录里连跑两个音高时，
        // 第二次的 "w" 会【静默覆盖】第一次的 dump（"看起来跑了两遍、实际只有一份"）
        fd = $fopen($sformatf("out/steady_n%d.txt", `NOTE), "w");
        $display("[STEADY] NOTE=%0d  wait=%0d ticks  dump=%0d ticks", `NOTE, NWAIT, NDUMP);
        rst_n = 1'b0; repeat (8) @(posedge clk); rst_n = 1'b1; wait_ticks(4);
        @(posedge clk); on_n <= `NOTE; on_vel <= 7'd100; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0;
        wait_ticks(NWAIT);
        for (g = 0; g < NDUMP; g = g + 1) begin
            wait_ticks(1);
            $fwrite(fd, "%0d\n", mix);
        end
        $fclose(fd);
        $display("[STEADY] done, wrote %0d samples", NDUMP);
        $stop;
    end
endmodule
`default_nettype wire