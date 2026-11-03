// 32-voice event-driven additive bank for the 138K advanced image.
// Each voice has its own phase accumulator, frequency word, gate and envelope.
// The sine/wave ROM is time-multiplexed; 512 clocks/sample leaves ample budget.
`default_nettype none

module poly32_bank #(
    parameter integer N_VOICES = 32,
    parameter integer PHASE_W  = 32
)(
    input  wire clk,
    input  wire rst_n,
    input  wire sample_tick,
    input  wire on_valid,
    input  wire [6:0] on_note,
    input  wire [6:0] on_vel,
    input  wire off_valid,
    input  wire [6:0] off_note,
    input  wire reset_all,
    input  wire signed [3:0] pitch_semi,
    input  wire [1:0] timbre,
    output reg signed [15:0] mix_out,
    output wire [N_VOICES-1:0] active,
    output reg [5:0] active_count
);

    reg [N_VOICES-1:0] gate;
    reg [PHASE_W-1:0] phase [0:N_VOICES-1];
    reg [PHASE_W-1:0] freq_mem [0:N_VOICES-1];
    reg [6:0] note_mem [0:N_VOICES-1];
    reg [16:0] env_mem [0:N_VOICES-1];
    reg [5:0] rr;
    assign active = gate;

    // The project LUT is generated for the real 97,656.25 Hz output rate.
    wire [31:0] lut_freq;
    wire [31:0] lut_beat;
    piano_note_lut u_note_lut (.note(on_note), .f0_step(lut_freq), .beat_step(lut_beat));

    function [15:0] pitch_coef;
        input signed [3:0] n;
        begin
            case (n)
                -4'sd8: pitch_coef = 16'd2580;
                -4'sd7: pitch_coef = 16'd2734;
                -4'sd6: pitch_coef = 16'd2896;
                -4'sd5: pitch_coef = 16'd3069;
                -4'sd4: pitch_coef = 16'd3251;
                -4'sd3: pitch_coef = 16'd3444;
                -4'sd2: pitch_coef = 16'd3649;
                -4'sd1: pitch_coef = 16'd3866;
                 4'sd0: pitch_coef = 16'd4096;
                 4'sd1: pitch_coef = 16'd4340;
                 4'sd2: pitch_coef = 16'd4598;
                 4'sd3: pitch_coef = 16'd4871;
                 4'sd4: pitch_coef = 16'd5161;
                 4'sd5: pitch_coef = 16'd5468;
                 4'sd6: pitch_coef = 16'd5793;
                 4'sd7: pitch_coef = 16'd6137;
                default: pitch_coef = 16'd4096;
            endcase
        end
    endfunction

    function [31:0] apply_pitch;
        input [31:0] f;
        input signed [3:0] n;
        reg [47:0] p;
        begin
            p = {16'd0, f} * {32'd0, pitch_coef(n)};
            apply_pitch = p[43:12];
        end
    endfunction

    wire [31:0] phase_inc [0:N_VOICES-1];
    genvar gi;
    generate
        for (gi = 0; gi < N_VOICES; gi = gi + 1) begin : g_inc
            assign phase_inc[gi] = apply_pitch(freq_mem[gi], pitch_semi);
        end
    endgenerate

    // Priority: retrigger same note, then idle voice, then round-robin steal.
    integer ai;
    reg [5:0] alloc_idx;
    reg alloc_found;
    always @* begin
        alloc_idx = 6'd0;
        alloc_found = 1'b0;
        if (on_valid && (on_vel != 7'd0)) begin
            for (ai = 0; ai < N_VOICES; ai = ai + 1)
                if (!alloc_found && gate[ai] && (note_mem[ai] == on_note)) begin
                    alloc_idx = ai[5:0];
                    alloc_found = 1'b1;
                end
            for (ai = 0; ai < N_VOICES; ai = ai + 1)
                if (!alloc_found && !gate[ai]) begin
                    alloc_idx = ai[5:0];
                    alloc_found = 1'b1;
                end
            if (!alloc_found)
                alloc_idx = rr;
        end
    end

    // Count is used only as a mode selector in the top-level advanced image.
    integer ci;
    always @* begin
        active_count = 6'd0;
        for (ci = 0; ci < N_VOICES; ci = ci + 1)
            active_count = active_count + (gate[ci] ? 6'd1 : 6'd0);
    end

    // One shared wave ROM, one cycle latency.
    reg [4:0] addr_mux;
    reg [5:0] scan_cnt;
    reg signed [22:0] sum;
    reg [16:0] env_d;
    wire [9:0] rom_addr = {timbre, phase[addr_mux][PHASE_W-1 -: 8]};
    wire signed [15:0] rom_val;
    wave_rom u_wave (.clk(clk), .addr(rom_addr), .data(rom_val));
    wire signed [33:0] scaled_full = $signed(rom_val) * $signed({1'b0, env_d});
    wire signed [16:0] scaled = scaled_full >>> 16;

    function signed [15:0] sat16;
        input signed [22:0] v;
        begin
            if (v > 23'sd32767) sat16 = 16'sd32767;
            else if (v < -23'sd32768) sat16 = -16'sd32768;
            else sat16 = v[15:0];
        end
    endfunction

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            gate <= {N_VOICES{1'b0}};
            rr <= 6'd0;
            addr_mux <= 5'd0;
            scan_cnt <= 6'd0;
            sum <= 23'sd0;
            env_d <= 17'd0;
            mix_out <= 16'sd0;
            for (k = 0; k < N_VOICES; k = k + 1) begin
                phase[k] <= {PHASE_W{1'b0}};
                freq_mem[k] <= 32'd0;
                note_mem[k] <= 7'd0;
                env_mem[k] <= 17'd0;
            end
        end else begin
            // Control events are independent of the audio scan pipeline.
            if (reset_all) begin
                gate <= {N_VOICES{1'b0}};
            end else begin
                if (on_valid && (on_vel != 7'd0)) begin
                    gate[alloc_idx] <= 1'b1;
                    note_mem[alloc_idx] <= on_note;
                    freq_mem[alloc_idx] <= lut_freq;
                    env_mem[alloc_idx] <= 17'd0;
                    phase[alloc_idx] <= {PHASE_W{1'b0}};
                    if (alloc_idx == N_VOICES-1) rr <= 6'd0;
                    else rr <= alloc_idx + 6'd1;
                end
                if (off_valid)
                    for (k = 0; k < N_VOICES; k = k + 1)
                        if (gate[k] && (note_mem[k] == off_note)) gate[k] <= 1'b0;
            end

            if (sample_tick) begin
                // Envelope and phase update: all 32 states are independent.
                for (k = 0; k < N_VOICES; k = k + 1) begin
                    if (gate[k]) begin
                        if (env_mem[k] >= 17'd64512) env_mem[k] <= 17'd65535;
                        else env_mem[k] <= env_mem[k] + 17'd1024;
                    end else if (env_mem[k] != 17'd0) begin
                        if (env_mem[k] < 17'd512) env_mem[k] <= 17'd0;
                        else env_mem[k] <= env_mem[k] - (env_mem[k] >> 9);
                    end
                    if (gate[k] || (env_mem[k] != 17'd0))
                        phase[k] <= phase[k] + phase_inc[k];
                end
                scan_cnt <= 6'd1;
                addr_mux <= 5'd0;
                sum <= 23'sd0;
            end else if ((scan_cnt >= 6'd1) && (scan_cnt <= N_VOICES)) begin
                scan_cnt <= scan_cnt + 6'd1;
                sum <= sum + scaled;
                if (addr_mux != N_VOICES-1) addr_mux <= addr_mux + 5'd1;
            end else if (scan_cnt == N_VOICES + 1) begin
                // 32-way sum is scaled by 1/64 to keep a full chord clean.
                mix_out <= sat16(sum >>> 6);
                scan_cnt <= 6'd0;
            end
            env_d <= env_mem[addr_mux];
        end
    end
endmodule

`default_nettype wire
