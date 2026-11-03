`timescale 1ns/1ps
//=============================================================================
// tb_hw_input_mgr -- xsim self-checking testbench for the S5 input manager.
//
// Sim-speed parameter overrides: DB_ON/OFF=1 ms, TOF_MS=2, MASK_MS=5,
// SCL_HZ=200 kHz.  An I2C slave BFM answers 0xA4/0xA5 and streams a
// programmable 16-bit distance (little-endian on the wire, like VB22B).
//
// Scenarios (each has a binary pass condition):
//   S1 power-up mask: press+release inside the mask window -> no events
//   S2 key0 press/release          -> on(60,100,g0) / off(60)
//   S3 all 13 keys, in order       -> 13 ons 60..72, then 13 offs
//   S4 photo block/clear           -> on(40,110,g0) / off(40)
//   S5 ToF: enter 300mm -> on(68,g0); 324mm hysteresis hold; 340mm ->
//      off(68)+on(70,g1); 850mm -> off(70); 150mm -> on(62,g0);
//      NACK burst -> off(62)
//   S6 EC11: CW detent -> vol 104; CCW -> 100; 30 CCW -> clamp 0; 10 CW -> 40
//   S7 global: any two events < 16 clk apart -> FAIL
//   S8 FIFO block counter stays 0
//=============================================================================
module tb_hw_input_mgr;

    localparam integer CLK_PERIOD = 20;   // 50 MHz

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [12:0] key_raw = 13'h1FFF;
    reg [5:0]  photo_raw = 6'h3F;
    reg        ec1a_raw = 1'b1;
    reg        ec1b_raw = 1'b1;

    wire scl, sda;
    pullup(scl);
    pullup(sda);
    wire dbg_tx;
    wire ev_on_valid, ev_off_valid, ev_glide_on;
    wire [6:0] ev_on_note, ev_on_vel, ev_off_note, ev_glide_time;
    wire [6:0] volume;
    wire [12:0] key_state;
    wire [5:0]  photo_state;
    wire [15:0] tof_dist;
    wire [7:0]  ovf_cnt;

    hw_input_mgr #(
        .CLK_HZ   (50_000_000),
        .SCL_HZ   (200_000),
        .DB_ON_MS (1),
        .DB_OFF_MS(1),
        .TOF_MS   (2),
        .MASK_MS  (5)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_raw    (key_raw),
        .photo_raw  (photo_raw),
        .ec1a_raw   (ec1a_raw),
        .ec1b_raw   (ec1b_raw),
        .scl_a      (scl),
        .sda_a      (sda),
        .dbg_tx     (dbg_tx),
        .ext_vol_valid(1'b0),
        .ext_vol_val(7'd100),
        .ev_on_valid(ev_on_valid),
        .ev_on_note (ev_on_note),
        .ev_on_vel  (ev_on_vel),
        .ev_off_valid(ev_off_valid),
        .ev_off_note (ev_off_note),
        .ev_glide_on (ev_glide_on),
        .ev_glide_time(ev_glide_time),
        .volume     (volume),
        .key_state  (key_state),
        .photo_state(photo_state),
        .tof_dist   (tof_dist),
        .ovf_cnt    (ovf_cnt)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    //------------------------------------------------------- event capture --
    int q_type[$];
    int q_note[$];
    int q_vel[$];
    int q_gl[$];
    int fail_cnt = 0;
    int clk_cnt = 0;
    int last_ev = -1000;

    always @(posedge clk) begin
        clk_cnt = clk_cnt + 1;
        if (ev_on_valid || ev_off_valid) begin
            if (clk_cnt - last_ev < 16) begin
                fail_cnt++;
                $display("[FAIL] event spacing %0d clk < 16", clk_cnt - last_ev);
            end
            last_ev = clk_cnt;
            if (ev_on_valid) begin
                q_type.push_back(0);
                q_note.push_back(ev_on_note);
                q_vel.push_back(ev_on_vel);
                q_gl.push_back(ev_glide_on);
            end else begin
                q_type.push_back(1);
                q_note.push_back(ev_off_note);
                q_vel.push_back(0);
                q_gl.push_back(0);
            end
        end
    end

    task automatic wait_ms(input int ms);
        repeat (ms * 50_000) @(posedge clk);
    endtask

    task automatic expect_ev(input int typ, input int note, input int vel,
                             input int gl, input int maxwait_ms, input string tag);
        int guard = 0;
        while (q_type.size() == 0 && guard < maxwait_ms * 50_000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        if (q_type.size() == 0) begin
            $display("[FAIL] %s: timeout waiting for event", tag);
            fail_cnt++;
        end else begin
            int at = q_type.pop_front();
            int an = q_note.pop_front();
            int av = q_vel.pop_front();
            int ag = q_gl.pop_front();
            if (at != typ || an != note || av != vel || ag != gl) begin
                $display("[FAIL] %s: got (typ=%0d note=%0d vel=%0d gl=%0d) exp (typ=%0d note=%0d vel=%0d gl=%0d)",
                         tag, at, an, av, ag, typ, note, vel, gl);
                fail_cnt++;
            end else begin
                $display("[ ok ] %s", tag);
            end
        end
    endtask

    task automatic expect_silence(input int ms, input string tag);
        int n0 = q_type.size();
        repeat (ms * 50_000) @(posedge clk);
        if (q_type.size() != n0) begin
            $display("[FAIL] %s: unexpected event(s)", tag);
            fail_cnt++;
        end else begin
            $display("[ ok ] %s", tag);
        end
    endtask

    //---------------------------------------------------- I2C slave BFM ----
    reg [15:0] tb_dist = 16'h0300;
    reg        tb_nack = 1'b0;
    reg        bfm_oe = 1'b0;
    assign sda = bfm_oe ? 1'b0 : 1'bz;

    localparam int B_ADDR = 0, B_REG = 1, B_RD = 2, B_IDLE = 3;
    int         bst = B_IDLE;
    int         cyc = 0;          // completed scl posedges since START
    reg [7:0]   rx;
    reg         byte_done = 1'b0;
    reg [7:0]   byte_r;
    reg [15:0]  rd_sh;
    int         rcnt = 0;

    always @(negedge sda) begin
        if (scl === 1'b1) begin                      // START
            bst = B_ADDR; cyc = 0; byte_done = 0; bfm_oe = 0; rcnt = 0;
        end
    end

    always @(posedge sda) begin
        if (scl === 1'b1) begin                      // STOP
            bst = B_IDLE; bfm_oe = 0; cyc = 0;
        end
    end

    always @(posedge scl) begin
        if (bst == B_ADDR || bst == B_REG) begin
            if (cyc % 9 < 8) begin
                if (cyc % 9 == 7) byte_r = {rx[6:0], sda};
                rx = {rx[6:0], sda};
                if (cyc % 9 == 7) byte_done = 1;
            end
        end
        cyc = cyc + 1;
    end

    always @(negedge scl) begin
        bfm_oe = 0;
        if (byte_done) begin
            byte_done = 0;
            if (!tb_nack) begin
                if (bst == B_ADDR && (byte_r == 8'hA4 || byte_r == 8'hA5)) begin
                    bfm_oe = 1;                      // ACK address
                    if (byte_r == 8'hA5) begin
                        bst = B_RD; rcnt = 0;
                        // real board order: HIGH byte first (measured 2026-10-23)
                        rd_sh = {tb_dist[15:8], tb_dist[7:0]};
                    end else begin
                        bst = B_REG;
                    end
                end else if (bst == B_REG) begin
                    bfm_oe = 1;                      // ACK register pointer
                end
            end
        end else if (bst == B_RD && rcnt < 16) begin
            if (cyc % 9 != 8) begin
                bfm_oe = ~rd_sh[15];
                rd_sh = {rd_sh[14:0], 1'b0};
                rcnt = rcnt + 1;
            end
        end
    end

    //---------------------------------------------------------- sequence ---
    // debug: trace ToF distance and BFM bytes
    reg [15:0] dbg_dist_d = 16'hFFFF;
    always @(posedge clk) begin
        if (dut.dist_r !== dbg_dist_d) begin
            dbg_dist_d <= dut.dist_r;
            $display("[dbg ] %0t dist_r=%h med=%h", $time, dut.dist_r, dut.med_r);
        end
    end
    always @(negedge scl)
        if (byte_done) $display("[dbg ] %0t BFM byte_r=%h bst=%0d", $time, byte_r, bst);

    // debug: edge-level trace of the first two transactions
    always @(posedge clk) if (dut.filt_we) $display("[f  ] %0t f=%h %h %h %h %h d12=%h", $time, dut.f0, dut.f1, dut.f2, dut.f3, dut.f4, dut.dist12);
    always @(posedge clk) if (dut.mst == 4'd12) $display("[med] %0t s=%h %h %h %h %h", $time, dut.s0, dut.s1, dut.s2, dut.s3, dut.s4);
    integer dbg_edges = 0;
    always @(posedge scl) begin
        if (dbg_edges < 60) begin
            $display("[edg+] %0t cyc=%0d bst=%0d sda=%b oe=%b ps=%0d", $time, cyc, bst, sda, bfm_oe, dut.ps);
            dbg_edges = dbg_edges + 1;
        end
    end
    always @(negedge scl) begin
        if (dbg_edges < 60 && dbg_edges > 0) begin
            $display("[edg-] %0t cyc=%0d bst=%0d oe=%b rsh=%h", $time, cyc, bst, bfm_oe, rd_sh);
            dbg_edges = dbg_edges + 1;
        end
    end

    initial begin
        // global watchdog (scenario total is ~1.1 s after the S5 rate-limit fix)
        #1_200_000_000;   // 1.2 s sim time
        $display("[FAIL] global watchdog timeout");
        $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        wait_ms(1);
        rst_n = 1;

        // S1: press+release inside the 5 ms mask window -> no events ever
        key_raw[0] = 1'b0;
        wait_ms(1);
        key_raw[0] = 1'b1;
        wait_ms(8);
        expect_silence(10, "S1 mask swallows press+release");

        // S2: key0 clean press / release
        key_raw[0] = 1'b0;
        expect_ev(0, 60, 100, 0, 8, "S2 key0 press -> on(60,100)");
        key_raw[0] = 1'b1;
        expect_ev(1, 60, 0, 0, 8, "S2 key0 release -> off(60)");

        // S3: all 13 keys, ascending
        for (int i = 0; i < 13; i = i + 1) begin
            key_raw[i] = 1'b0;
            wait_ms(2);
        end
        for (int i = 0; i < 13; i = i + 1)
            expect_ev(0, 60 + i, 100, 0, 10, $sformatf("S3 key%0d on", i));
        for (int i = 0; i < 13; i = i + 1) begin
            key_raw[i] = 1'b1;
            wait_ms(2);
        end
        for (int i = 0; i < 13; i = i + 1)
            expect_ev(1, 60 + i, 0, 0, 10, $sformatf("S3 key%0d off", i));

        // S4: photo #1
        photo_raw[0] = 1'b0;
        expect_ev(0, 40, 110, 0, 8, "S4 photo block -> on(40,110)");
        photo_raw[0] = 1'b1;
        expect_ev(1, 40, 0, 0, 8, "S4 photo clear -> off(40)");

        // S5: ToF (polling starts 100 ms after reset)
        // S5 fix 2026-10-23: glide=0 everywhere (engine glide steals the global
        // last_voice), pitch changes rate-limited to >=180 ms, entry needs a
        // 3-sample dwell.
        wait_ms(120);
        tb_dist = 16'd300;
        expect_ev(0, 68, 100, 0, 60, "S5 enter 300mm -> on(68,g0)");
        tb_dist = 16'd324;
        expect_silence(20, "S5 324mm inside hysteresis -> hold");
        tb_dist = 16'd340;
        expect_ev(1, 68, 0, 0, 220, "S5 340mm -> off(68)");      // 180 ms rate limit
        expect_ev(0, 70, 100, 0, 40, "S5 340mm -> on(70,g0) re-pluck");
        tb_dist = 16'd850;
        wait_ms(30);
        expect_ev(1, 70, 0, 0, 40, "S5 850mm x10 -> off(70)");
        tb_dist = 16'd150;
        wait_ms(10);
        expect_ev(0, 62, 100, 0, 150, "S5 reenter 150mm -> on(62,g0)");
        tb_nack = 1;
        wait_ms(70);
        expect_ev(1, 62, 0, 0, 40, "S5 NACK burst -> off(62)");
        tb_nack = 0;

        // S6: EC11 volume (each detent = 4 quadrature steps)
        // one CW detent from idle 11: 11->10->00->01->11
        ec1b_raw = 1'b0; wait_ms(2);
        ec1a_raw = 1'b0; wait_ms(2);
        ec1b_raw = 1'b1; wait_ms(2);
        ec1a_raw = 1'b1; wait_ms(3);
        if (volume !== 7'd104) begin
            fail_cnt++; $display("[FAIL] S6 CW detent: vol=%0d exp 104", volume);
        end else $display("[ ok ] S6 CW detent -> 104");
        // one CCW detent: 11->01->00->10->11
        ec1a_raw = 1'b0; wait_ms(2);
        ec1b_raw = 1'b0; wait_ms(2);
        ec1a_raw = 1'b1; wait_ms(2);
        ec1b_raw = 1'b1; wait_ms(3);
        if (volume !== 7'd100) begin
            fail_cnt++; $display("[FAIL] S6 CCW detent: vol=%0d exp 100", volume);
        end else $display("[ ok ] S6 CCW detent -> 100");
        // 30 CCW detents -> clamp at 0
        for (int d = 0; d < 30; d = d + 1) begin
            ec1a_raw = 1'b0; wait_ms(2);
            ec1b_raw = 1'b0; wait_ms(2);
            ec1a_raw = 1'b1; wait_ms(2);
            ec1b_raw = 1'b1; wait_ms(2);
        end
        wait_ms(3);
        if (volume !== 7'd0) begin
            fail_cnt++; $display("[FAIL] S6 clamp low: vol=%0d exp 0", volume);
        end else $display("[ ok ] S6 30 CCW detents -> clamp 0");
        // 10 CW detents -> 40
        for (int d = 0; d < 10; d = d + 1) begin
            ec1b_raw = 1'b0; wait_ms(2);
            ec1a_raw = 1'b0; wait_ms(2);
            ec1b_raw = 1'b1; wait_ms(2);
            ec1a_raw = 1'b1; wait_ms(2);
        end
        wait_ms(3);
        if (volume !== 7'd40) begin
            fail_cnt++; $display("[FAIL] S6 10 CW: vol=%0d exp 40", volume);
        end else $display("[ ok ] S6 10 CW detents -> 40");

        // S8: FIFO never blocked in these scenarios
        if (ovf_cnt !== 8'd0) begin
            fail_cnt++; $display("[FAIL] S8 ovf_cnt=%0d exp 0", ovf_cnt);
        end else $display("[ ok ] S8 FIFO block counter = 0");

        if (fail_cnt == 0) $display("RESULT: PASS");
        else               $display("RESULT: FAIL (%0d failures)", fail_cnt);
        $finish;
    end

endmodule
