`timescale 1ns/1ps
module tb_dac_pcm;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0;
    reg signed [15:0] source=0;
    wire bck, ws, din;
    lcd_test_top dut(.sys_clk(clk),.sys_rst_n(1'b1),.key(1'b1),.key2(1'b1),
                     .uart_rx(1'b1),.HP_BCK(bck),.HP_WS(ws),.HP_DIN(din));
    reg [15:0] expected=0, shifted=0;
    reg [15:0] completed=0;
    reg check_capture=0;
    integer capture_addr=0;
    integer bit_count=0, channels=0, ticks=0;
    integer p, amplitude_case, y, center, half_height, amplitude, height, start_y, end_y;
    reg column_present;
    reg [15:0] forced_peak;
    task check_wave_pixels;
        begin
            for(y=start_y;y<=end_y;y=y+1) begin
                force dut.py=y;
                #2;
                if ((dut.ui_color == 16'h07ff) !==
                    (column_present && y>=center-height && y<=center+height))
                    $fatal(1,"Waveform fill mismatch: page %0d amp %0d valid %0d y %0d color %h",
                           p,amplitude,column_present,y,dut.ui_color);
            end
        end
    endtask
    always @(negedge clk) begin
        if (rst_n) source=source+16'sd179;
    end
    always @(posedge clk) begin
        check_capture=rst_n && dut.sample_tick;
        if (rst_n && dut.sample_tick) begin
            completed=expected;
            capture_addr={dut.u_visualizer.capture_bank,dut.u_visualizer.capture_pos};
            expected=source;
            ticks=ticks+1;
        end
        #1;
        if (check_capture && dut.u_visualizer.pcm[capture_addr] !== completed)
            $fatal(1,"Visualizer did not capture the completed DAC PCM frame");
        if (rst_n && dut.dac_pcm !== expected) $fatal(1,"DAC PCM changed inside a frame");
    end
    always @(posedge bck) begin
        if (rst_n && ticks>0) begin
            shifted={shifted[14:0],din};
            bit_count=bit_count+1;
            if(bit_count==16) begin
                if(shifted !== expected) $fatal(1,"Serial PCM mismatch: got %h expected %h",shifted,expected);
                bit_count=0;
                channels=channels+1;
            end
        end
    end
    initial begin
        force dut.rst_n=rst_n;
        force dut.audio_mix=source;
        repeat(8) @(negedge clk);
        rst_n=1;
        repeat(512*24) @(negedge clk);
        if(channels<40) $fatal(1,"Insufficient serial audio frames");
        $display("PASS DAC serial PCM: %0d channels match visualizer sample with continuously changing source",channels);
        force dut.wave0_peak=forced_peak;
        force dut.wave1_peak=forced_peak;
        force dut.wave0_valid=column_present;
        force dut.wave1_valid=column_present;
        force dut.px=10'd45;
        for(p=0;p<2;p=p+1) begin
            force dut.ui_page=p;
            center=p==0 ? 300 : 154;
            half_height=p==0 ? 80 : 48;
            start_y=p==0 ? 140 : 68;
            end_y=p==0 ? 460 : 240;
            for(amplitude_case=0;amplitude_case<4;amplitude_case=amplitude_case+1) begin
                case(amplitude_case)
                    0: amplitude=0;
                    1: amplitude=8192;
                    2: amplitude=16384;
                    3: amplitude=32768;
                endcase
                height=half_height*amplitude/32768;
                forced_peak=amplitude;
                column_present=1;
                #2;
                if(dut.live_scope_wave_y !== center-height || dut.live_scope_prev_y !== center+height)
                    $fatal(1,"Envelope is not symmetric about center");
                check_wave_pixels;
                column_present=0;
                check_wave_pixels;
            end
        end
        $display("PASS P0/P1 pixels: solid mirrored envelope, negative full scale and blank unfilled columns");
        $finish;
    end
endmodule
