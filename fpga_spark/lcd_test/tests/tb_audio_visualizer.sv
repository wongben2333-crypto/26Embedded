`timescale 1ns/1ps
module tb_audio_visualizer;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, sample_tick=0, frame_sync=0, run=1;
    reg signed [15:0] sample=0;
    reg [8:0] wave0_col=0;
    reg [9:0] wave1_col=0;
    reg [4:0] spectrum_col=0;
    wire [15:0] wave0_peak, wave1_peak;
    wire wave0_valid, wave1_valid;
    wire [7:0] spectrum_level, benchmark_level, vu_level;
    wire audio_active, display_valid;
    wire [31:0] display_id;
    audio_visualizer dut(.*);
    reg [15:0] vectors [0:40959];
    reg [2047:0] vector_path, output_path;
    integer fd, c, i, count, cases, old_bank, old_id;
    reg [16:0] saved0 [0:419];
    reg [16:0] saved1 [0:757];
    reg [7:0] saved_levels [0:63];
    reg [31:0] last_id=0;
    reg last_valid=0;

    always @(posedge clk) begin
        #1;
        if (rst_n && ((display_id != last_id) || (display_valid != last_valid)))
            if (!frame_sync || !run) $fatal(1,"Publication outside LCD frame boundary");
        last_id=display_id;
        last_valid=display_valid;
    end

    task pulse_frame;
        begin
            @(negedge clk); frame_sync=1;
            @(negedge clk); frame_sync=0;
        end
    endtask

    initial begin
        if (!$value$plusargs("vectors=%s",vector_path)) $fatal;
        if (!$value$plusargs("output=%s",output_path)) $fatal;
        if (!$value$plusargs("cases=%d",cases)) $fatal;
        $readmemh(vector_path,vectors);
        fd=$fopen(output_path,"w");
        repeat(4) @(negedge clk);
        rst_n=1;
        repeat(2) @(negedge clk);
        if (display_valid || vu_level || spectrum_level || wave0_peak || wave0_valid) $fatal(1,"Invalid reset display");
        for(c=0;c<cases;c=c+1) begin
            old_bank=dut.display_bank;
            old_id=display_id;
            if (display_valid) begin
                for(i=0;i<420;i=i+1) saved0[i]=dut.u_wave0.display_ram[old_bank*512+i];
                for(i=0;i<758;i=i+1) saved1[i]=dut.u_wave1.display_ram[old_bank*1024+i];
                for(i=0;i<64;i=i+1) saved_levels[i]=dut.levels[old_bank*64+i];
            end
            for(i=0;i<4096;i=i+1) begin
                @(negedge clk); sample=vectors[c*4096+i]; sample_tick=1;
                @(negedge clk); sample_tick=0;
                repeat(6) @(negedge clk);
            end
            // Continue capture into the other bank while this FFT is running.
            for(i=0;i<4096;i=i+1) begin
                @(negedge clk); sample=16'sh5555; sample_tick=1;
                @(negedge clk); sample_tick=0;
                repeat(6) @(negedge clk);
            end
            count=0;
            while (!dut.pending && count<250000) begin
                @(negedge clk); count=count+1;
            end
            if (!dut.pending) $fatal(1,"FFT timeout, state=%d",dut.state);
            if (dut.display_bank != old_bank || display_id != old_id) $fatal(1,"Early publication");
            if (display_valid) begin
                for(i=0;i<420;i=i+1)
                    if (saved0[i] !== dut.u_wave0.display_ram[old_bank*512+i]) $fatal(1,"Visible wave0 overwritten");
                for(i=0;i<758;i=i+1)
                    if (saved1[i] !== dut.u_wave1.display_ram[old_bank*1024+i]) $fatal(1,"Visible wave1 overwritten");
                for(i=0;i<64;i=i+1)
                    if (saved_levels[i] !== dut.levels[old_bank*64+i]) $fatal(1,"Visible FFT overwritten");
            end
            run=0;
            pulse_frame;
            if (dut.display_bank != old_bank || display_id != old_id) $fatal(1,"Freeze failed");
            run=1;
            pulse_frame;
            repeat(2) @(negedge clk);
            if (!display_valid || display_id != c*2) $fatal(1,"Snapshot metadata mismatch");
            $fdisplay(fd,"CASE %0d %0d %0d %0d",c,vu_level,display_id,audio_active);
            for(i=0;i<4096;i=i+1)
                $fdisplay(fd,"FFT %0d %0d %0d",i,$signed(dut.u_fft.ram[i][35:18]),$signed(dut.u_fft.ram[i][17:0]));
            for(i=0;i<758;i=i+1) begin
                wave1_col=i;
                if(i<420) wave0_col=i;
                repeat(2) @(negedge clk);
                $fdisplay(fd,"W1 %0d %0d %0d",i,wave1_peak,wave1_valid);
                if(i<420) $fdisplay(fd,"W0 %0d %0d %0d",i,wave0_peak,wave0_valid);
            end
            for(i=0;i<32;i=i+1) begin
                spectrum_col=i;
                @(negedge clk);
                $fdisplay(fd,"B %0d %0d %0d",i,spectrum_level,benchmark_level);
            end
            $display("RTL case %0d passed frame/freeze/bank checks",c);
        end
        $fclose(fd);
        $finish;
    end
endmodule
