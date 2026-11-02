`default_nettype none

// Three-second waveform history ends at the spectrum/peak meter PCM block.
// Capture never waits for the LCD; the display bank changes only at frame_sync.
module audio_visualizer #(
    parameter integer AUDIO_BCK_DIV = 1
)(
    input wire clk, rst_n, sample_tick,
    input wire signed [15:0] sample,
    input wire frame_sync, run,
    input wire [8:0] wave0_col,
    input wire [9:0] wave1_col,
    input wire [4:0] spectrum_col,
    output wire [15:0] wave0_peak, wave1_peak,
    output wire wave0_valid, wave1_valid,
    output wire [7:0] spectrum_level, benchmark_level, vu_level,
    output wire audio_active,
    output reg display_valid,
    output reg [31:0] display_id
);
    localparam IDLE=0, LOAD_READ=1, LOAD_MUL=2, LOAD_WRITE=3,
               FFT_START=4, CLEAR=5, WAIT_FFT=6, SCAN_READ=7,
               SCAN_SQUARE=8, SCAN_ADD=9, SCAN_ACCUM=10,
               LEVEL_READ=11, LEVEL_LATCH=12, LEVEL_WRITE=13;
    reg [3:0] state;
    reg capture_bank, read_bank, work_bank, display_bank;
    reg [11:0] capture_pos, load_pos;
    reg signed [28:0] capture_sum;
    reg [15:0] capture_peak, work_peak, display_peak;
    reg signed [15:0] block_mean;
    reg [31:0] capture_id, work_id;
    reg pending;
    wire accept_block = sample_tick && (capture_pos == 12'd4095) &&
                        (state == IDLE) && !pending && run;
    wire [15:0] sample_abs = sample[15] ? (~sample + 16'd1) : sample;
    wire signed [28:0] block_sum = capture_sum + {{13{sample[15]}},sample};
    wire [15:0] block_peak = (sample_abs > capture_peak) ? sample_abs : capture_peak;
    reg signed [15:0] pcm [0:8191];
    reg signed [15:0] pcm_q;
    reg [15:0] hann [0:4095];
    reg signed [15:0] hann_q;
    reg signed [32:0] window_product;
    wire signed [16:0] centered = {pcm_q[15],pcm_q} - {block_mean[15],block_mean};
    initial $readmemh("rtl/visualizer/fft_hann.hex", hann);

    always @(posedge clk) begin
        if (sample_tick) pcm[{capture_bank,capture_pos}] <= sample;
        pcm_q <= pcm[{read_bank,load_pos}];
        hann_q <= $signed(hann[load_pos]);
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            capture_bank <= 1'b0; capture_pos <= 12'd0;
            capture_sum <= 29'sd0; capture_peak <= 16'd0; capture_id <= 32'd0;
        end else if (sample_tick) begin
            if (capture_pos == 12'd4095) begin
                capture_pos <= 12'd0; capture_sum <= 29'sd0; capture_peak <= 16'd0;
                capture_id <= capture_id + 32'd1;
                if (accept_block) capture_bank <= ~capture_bank;
            end else begin
                capture_pos <= capture_pos + 12'd1;
                capture_sum <= block_sum; capture_peak <= block_peak;
            end
        end
    end

    wire wave0_busy, wave1_busy;
    rolling_waveform #(.WIDTH(420), .ADDR_BITS(10), .AUDIO_BCK_DIV(AUDIO_BCK_DIV)) u_wave0 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sample(sample),
        .snapshot(accept_block), .snapshot_bank(~display_bank),
        .display_bank(display_bank), .display_valid(display_valid), .column(wave0_col),
        .amplitude(wave0_peak), .column_valid(wave0_valid), .busy(wave0_busy)
    );
    rolling_waveform #(.WIDTH(758), .ADDR_BITS(11), .AUDIO_BCK_DIV(AUDIO_BCK_DIV)) u_wave1 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sample(sample),
        .snapshot(accept_block), .snapshot_bank(~display_bank),
        .display_bank(display_bank), .display_valid(display_valid), .column(wave1_col),
        .amplitude(wave1_peak), .column_valid(wave1_valid), .busy(wave1_busy)
    );

    wire fft_busy, fft_done;
    wire signed [17:0] fft_re, fft_im;
    wire signed [17:0] fft_input = window_product >>> 15;
    reg [11:0] bin_index;
    fft4096 u_fft (
        .clk(clk), .rst_n(rst_n), .load(state == LOAD_WRITE), .load_index(load_pos),
        .load_sample(fft_input), .start(state == FFT_START), .busy(fft_busy),
        .done(fft_done), .rd_index(bin_index), .rd_re(fft_re), .rd_im(fft_im)
    );
    `include "visualizer/fft_bands.vh"
    reg [35:0] re_square, im_square;
    reg [36:0] bin_power;
    (* syn_ramstyle = "block_ram" *) reg [36:0] bands [0:31]; /* synthesis syn_ramstyle = "block_ram" */
    (* syn_ramstyle = "block_ram" *) reg [36:0] bench [0:31]; /* synthesis syn_ramstyle = "block_ram" */
    reg [5:0] level_index;
    reg [36:0] level_power;
    (* syn_ramstyle = "block_ram" *) reg [7:0] spec_levels  [0:63]; /* synthesis syn_ramstyle = "block_ram" */
    (* syn_ramstyle = "block_ram" *) reg [7:0] bench_levels [0:63]; /* synthesis syn_ramstyle = "block_ram" */
    wire [5:0] band_slot = spectrum_band(bin_index);
    wire [5:0] bench_slot = benchmark_band(bin_index);

    // 0..144 px is approximately -72..0 dBFS for a Hann-windowed sine.
    // A leading bit and 4-bit mantissa replace a divider and square root.
    function [7:0] power_height;
        input [36:0] power;
        integer bit_index;
        reg [5:0] msb;
        reg [36:0] normalized;
        reg [9:0] log_q4;
        reg [11:0] scaled;
        begin
            msb = 6'd0;
            for (bit_index=0; bit_index<37; bit_index=bit_index+1)
                if (power[bit_index]) msb = bit_index;
            normalized = (msb >= 6'd4) ? (power >> (msb - 6'd4)) : (power << (6'd4 - msb));
            log_q4 = {msb,4'b0} + {6'd0,normalized[3:0]};
            scaled = (log_q4 > 10'd32) ? ((log_q4 - 10'd32) * 12'd3) : 12'd0;
            if (power <= 37'd4) power_height = 8'd0;
            else if (scaled >= 12'd1152) power_height = 8'd144;
            else power_height = scaled[10:3];
        end
    endfunction

    // Synchronous SDPB read/write ports for BSRAM inference (saves ~3,400 FFs & ~3,500 LUTs)
    wire [4:0]  band_rd_addr  = (state == LEVEL_READ) ? level_index[4:0] : band_slot[4:0];
    wire [4:0]  bench_rd_addr = (state == LEVEL_READ) ? level_index[4:0] : bench_slot[4:0];
    reg  [36:0] band_rd_q, bench_rd_q;
    reg  [7:0]  spec_level_q, bench_level_q;

    wire        band_we    = (state == CLEAR) || ((state == SCAN_ACCUM) && !band_slot[5] && (bin_power > band_rd_q));
    wire [4:0]  band_waddr = (state == CLEAR) ? level_index[4:0] : band_slot[4:0];
    wire [36:0] band_wdata = (state == CLEAR) ? 37'd0 : bin_power;

    wire        bench_we    = (state == CLEAR) || ((state == SCAN_ACCUM) && !bench_slot[5] && (bin_power > bench_rd_q));
    wire [4:0]  bench_waddr = (state == CLEAR) ? level_index[4:0] : bench_slot[4:0];
    wire [36:0] bench_wdata = (state == CLEAR) ? 37'd0 : bin_power;

    wire [7:0]  cur_power_height = power_height(level_power);

    always @(posedge clk) begin
        if (band_we)  bands[band_waddr] <= band_wdata;
        band_rd_q <= bands[band_rd_addr];

        if (bench_we) bench[bench_waddr] <= bench_wdata;
        bench_rd_q <= bench[bench_rd_addr];

        if ((state == LEVEL_WRITE) && !level_index[5])
            spec_levels[{work_bank, level_index[4:0]}] <= cur_power_height;
        spec_level_q <= spec_levels[{display_bank, spectrum_col}];

        if ((state == LEVEL_WRITE) && level_index[5])
            bench_levels[{work_bank, level_index[4:0]}] <= cur_power_height;
        bench_level_q <= bench_levels[{display_bank, spectrum_col}];
    end

    assign spectrum_level = display_valid ? spec_level_q : 8'd0;
    assign benchmark_level = display_valid ? bench_level_q : 8'd0;
    assign vu_level = !display_valid ? 8'd0 : (display_peak[15] ? 8'd255 : display_peak[14:7]);
    assign audio_active = display_valid && (display_peak > 16'd32);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; read_bank <= 1'b0; work_bank <= 1'b1; display_bank <= 1'b0;
            display_valid <= 1'b0; display_id <= 32'd0; display_peak <= 16'd0; pending <= 1'b0;
            load_pos <= 12'd0; bin_index <= 12'd1; level_index <= 6'd0;
        end else begin
            if (frame_sync && pending && run) begin
                display_bank <= work_bank; display_peak <= work_peak; display_id <= work_id;
                display_valid <= 1'b1; pending <= 1'b0;
            end
            case (state)
                IDLE: if (accept_block) begin
                    read_bank <= capture_bank; work_bank <= ~display_bank;
                    work_id <= capture_id; work_peak <= block_peak; block_mean <= block_sum[27:12];
                    load_pos <= 12'd0;
                    state <= LOAD_READ;
                end
                LOAD_READ: state <= LOAD_MUL;
                LOAD_MUL: begin
                    window_product <= centered * hann_q;
                    state <= LOAD_WRITE;
                end
                LOAD_WRITE: begin
                    if (load_pos == 12'd4095) state <= FFT_START;
                    else begin load_pos <= load_pos + 12'd1; state <= LOAD_READ; end
                end
                FFT_START: begin level_index <= 6'd0; state <= CLEAR; end
                CLEAR: begin
                    if (level_index == 6'd31) state <= WAIT_FFT;
                    else level_index <= level_index + 6'd1;
                end
                WAIT_FFT: if (fft_done && !wave0_busy && !wave1_busy) begin
                    bin_index <= 12'd1; state <= SCAN_READ;
                end
                SCAN_READ: state <= SCAN_SQUARE;
                SCAN_SQUARE: begin
                    re_square <= fft_re * fft_re; im_square <= fft_im * fft_im;
                    state <= SCAN_ADD;
                end
                SCAN_ADD: begin bin_power <= {1'b0,re_square} + {1'b0,im_square}; state <= SCAN_ACCUM; end
                SCAN_ACCUM: begin
                    if (bin_index == 12'd2047) begin level_index <= 6'd0; state <= LEVEL_READ; end
                    else begin bin_index <= bin_index + 12'd1; state <= SCAN_READ; end
                end
                LEVEL_READ: begin
                    state <= LEVEL_LATCH;
                end
                LEVEL_LATCH: begin
                    level_power <= level_index[5] ? bench_rd_q : band_rd_q;
                    state <= LEVEL_WRITE;
                end
                LEVEL_WRITE: begin
                    if (level_index == 6'd63) begin pending <= 1'b1; state <= IDLE; end
                    else begin level_index <= level_index + 6'd1; state <= LEVEL_READ; end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
