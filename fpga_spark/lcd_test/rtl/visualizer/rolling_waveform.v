`default_nettype none

// Three seconds of absolute PCM peaks, continuously captured independently
// of display refresh. A spare history window keeps snapshot copies stable.
module rolling_waveform #(
    parameter integer WIDTH = 758,
    parameter integer ADDR_BITS = 11,
    parameter integer AUDIO_BCK_DIV = 1,
    parameter integer CLK_HZ = 50000000
)(
    input wire clk, rst_n, sample_tick,
    input wire signed [15:0] sample,
    input wire snapshot, snapshot_bank, display_bank, display_valid,
    input wire [ADDR_BITS-2:0] column,
    output wire [15:0] amplitude,
    output wire column_valid,
    output reg busy
);
    localparam integer PHASE_LIMIT = 3 * CLK_HZ;
    localparam integer PHASE_STEP = WIDTH * 512 * AUDIO_BCK_DIV;
    localparam COPY_READ = 1'b0, COPY_WRITE = 1'b1;
    reg [31:0] phase;
    wire [32:0] next_phase = {1'b0,phase} + PHASE_STEP;
    wire close_column = next_phase >= PHASE_LIMIT;
    wire [15:0] magnitude = sample[15] ? (~sample + 16'd1) : sample;
    reg [15:0] peak;
    reg partial_valid;
    wire [15:0] next_peak = magnitude > peak ? magnitude : peak;
    reg [ADDR_BITS-1:0] write_pos, history_count;
    reg [15:0] history [0:(1<<ADDR_BITS)-1];

    wire closing = sample_tick && close_column;
    wire [ADDR_BITS-1:0] endpoint_pos = write_pos + closing;
    wire [ADDR_BITS-1:0] endpoint_count = history_count +
        ((closing && history_count < WIDTH) ? 1'b1 : 1'b0);
    wire endpoint_partial = sample_tick ? !close_column : partial_valid;
    wire [ADDR_BITS:0] available = {1'b0,endpoint_count} + endpoint_partial;
    wire [ADDR_BITS-1:0] visible_count = (available > WIDTH) ? WIDTH[ADDR_BITS-1:0] : available[ADDR_BITS-1:0];
    wire [ADDR_BITS-1:0] complete_count = visible_count - endpoint_partial;
    reg [ADDR_BITS-1:0] copy_origin, copy_count;
    reg [ADDR_BITS-2:0] copy_col;
    reg copy_bank, copy_partial, copy_state;
    reg [15:0] copy_peak, history_q;
    wire [ADDR_BITS-1:0] history_addr = copy_origin + copy_col;
    wire copying_partial = copy_partial && ({1'b0,copy_col} == copy_count - 1'b1);
    wire [16:0] copy_value = ({1'b0,copy_col} < copy_count) ?
        {1'b1,copying_partial ? copy_peak : history_q} : 17'd0;
    reg [16:0] display_ram [0:(1<<ADDR_BITS)-1];
    reg [16:0] display_q;

    always @(posedge clk) begin
        if (rst_n && closing) history[write_pos] <= next_peak;
        history_q <= history[history_addr];
        if (busy && copy_state == COPY_WRITE)
            display_ram[{copy_bank,copy_col}] <= copy_value;
        display_q <= display_ram[{display_bank,column}];
    end
    assign amplitude = display_valid ? display_q[15:0] : 16'd0;
    assign column_valid = display_valid && display_q[16];

    always @(posedge clk) begin
        if (!rst_n) begin
            phase <= 0; peak <= 0; partial_valid <= 0;
            write_pos <= 0; history_count <= 0;
            busy <= 0; copy_state <= COPY_READ; copy_col <= 0;
            copy_origin <= 0; copy_count <= 0; copy_bank <= 0;
            copy_partial <= 0; copy_peak <= 0;
        end else begin
            if (sample_tick) begin
                if (close_column) begin
                    phase <= next_phase[31:0] - PHASE_LIMIT[31:0];
                    peak <= 0; partial_valid <= 0;
                    write_pos <= write_pos + 1'b1;
                    if (history_count < WIDTH) history_count <= history_count + 1'b1;
                end else begin
                    phase <= next_phase[31:0]; peak <= next_peak; partial_valid <= 1;
                end
            end
            if (snapshot && !busy) begin
                copy_origin <= endpoint_pos - complete_count;
                copy_count <= visible_count; copy_partial <= endpoint_partial;
                copy_peak <= sample_tick ? next_peak : peak;
                copy_bank <= snapshot_bank; copy_col <= 0;
                copy_state <= COPY_READ; busy <= 1;
            end else if (busy) begin
                if (copy_state == COPY_READ) copy_state <= COPY_WRITE;
                else if (copy_col == WIDTH-1) busy <= 0;
                else begin copy_col <= copy_col + 1'b1; copy_state <= COPY_READ; end
            end
        end
    end
endmodule
`default_nettype wire
