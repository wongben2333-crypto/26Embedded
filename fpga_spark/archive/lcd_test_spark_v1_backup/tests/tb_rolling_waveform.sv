`timescale 1ns/1ps
module tb_rolling_waveform;
    reg clk=0;
    always #10 clk=~clk;
    reg rst_n=0, sample_tick=0, snapshot=0, snapshot_bank=1, display_bank=0, display_valid=0;
    reg signed [15:0] sample=0;
    reg [8:0] col0=0;
    reg [9:0] col1=0;
    wire [15:0] peak0, peak1;
    wire valid0, valid1, busy0, busy1;
    rolling_waveform #(.WIDTH(420),.ADDR_BITS(10)) w0 (
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.sample(sample),
        .snapshot(snapshot),.snapshot_bank(snapshot_bank),.display_bank(display_bank),
        .display_valid(display_valid),.column(col0),.amplitude(peak0),.column_valid(valid0),.busy(busy0));
    rolling_waveform #(.WIDTH(758),.ADDR_BITS(11)) w1 (
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.sample(sample),
        .snapshot(snapshot),.snapshot_bank(snapshot_bank),.display_bank(display_bank),
        .display_valid(display_valid),.column(col1),.amplitude(peak1),.column_valid(valid1),.busy(busy1));
    reg [2047:0] output_path;
    integer fd, n, i, milestone, target, level;

    function integer checkpoint;
        input integer index;
        case(index)
            0: checkpoint=0;
            1: checkpoint=1;
            2: checkpoint=697; // P0 column closure on snapshot edge
            3: checkpoint=5000;
            4: checkpoint=292968; // Just before the three-second boundary
            5: checkpoint=292969;
            6: checkpoint=300000;
            7: checkpoint=600000;
            8: checkpoint=850000; // Both physical history rings have wrapped
            9: checkpoint=1200000; // More than three seconds of trailing silence
            default: checkpoint=1200001;
        endcase
    endfunction

    initial begin
        if (!$value$plusargs("output=%s",output_path)) $fatal;
        fd=$fopen(output_path,"w");
        repeat(4) @(negedge clk);
        rst_n=1;
        n=0;
        for(milestone=0;milestone<10;milestone=milestone+1) begin
            target=checkpoint(milestone);
            while(n<target) begin
                level=1000+((n/1300)*137)%28000;
                if(n%10007==0) level=32768;
                if(n>=900000) level=0;
                @(negedge clk);
                sample=(n%2==0) ? -level : (level==32768 ? 32767 : level);
                sample_tick=1;
                snapshot=(n==target-1);
                @(negedge clk); sample_tick=0; snapshot=0;
                n=n+1;
            end
            if(target==0) begin
                @(negedge clk); snapshot=1;
                @(negedge clk); snapshot=0;
            end
            while(busy0 || busy1) @(negedge clk);
            display_bank=snapshot_bank; display_valid=1;
            snapshot_bank=~snapshot_bank;
            repeat(2) @(negedge clk);
            $fdisplay(fd,"SNAP %0d",target);
            for(i=0;i<758;i=i+1) begin
                col1=i;
                if(i<420) col0=i;
                repeat(2) @(negedge clk);
                $fdisplay(fd,"W1 %0d %0d %0d",i,peak1,valid1);
                if(i<420) $fdisplay(fd,"W0 %0d %0d %0d",i,peak0,valid0);
            end
        end
        // Reset must invalidate old history without clearing the RAM contents.
        rst_n=0; display_valid=0;
        repeat(2) @(negedge clk);
        if(valid0 || valid1 || peak0 || peak1) $fatal(1,"Reset exposed stale waveform");
        rst_n=1;
        @(negedge clk); snapshot=1;
        @(negedge clk); snapshot=0;
        while(busy0 || busy1) @(negedge clk);
        display_bank=snapshot_bank; display_valid=1;
        repeat(2) @(negedge clk);
        for(i=0;i<758;i=i+1) begin
            col1=i;
            if(i<420) col0=i;
            repeat(2) @(negedge clk);
            if(valid1 || peak1 || valid0 || peak0) $fatal(1,"Reset snapshot contains old history");
        end
        $fclose(fd);
        $display("PASS rolling waveform: warm-up, three-second fill, scrolling, ring wrap, silence and reset");
        $finish;
    end
endmodule
