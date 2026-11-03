// =============================================================================
//  hw_input_mgr.v -- S5 hardware-instrument input manager (top MODE=3)
//
//  Inputs (all verified on this board by the hw_bringup firmwares & PCB v1):
//      key_raw[12:0]  J13 pins 1..10,13,14,15   pressed = 0 (internal pull-up)
//      photo_raw[5:0] J13 pins 16..21           blocked = 0 (PC817 / S9012)
//      ec1a/ec1b      J13 pins 22/23 (D17/A19)  EC11 #1 quadrature
//      scl_a/sda_a    J13 pins 24/25 (A18/D15)  ToF #1, VB22B @0x52, bus A
//
//  Outputs:
//      ev_*           serialized note events, one per pulse, >=16 clk apart
//                     (piano_engine load FSM needs 14 clk between note-ons:
//                     6 partials x (L_CALC+L_MUL) + L_DONE, no input queue)
//      volume         EC11 volume 0..127 (start VOL_INIT, +/-1 per quadrature
//                     step = +/-4 per detent), also syncs with ext_vol_valid
//                     (7-inch LCD touchscreen volume slider & MIDI CC7)
//      dbg_tx         115200 telemetry on U15:
//                     K=xxxx P=xx A=xxxx V=xx N=xxxxxx O=xx @xxxxxxxx CR LF
//                     K key state / P photo state / A ToF mm (FFFF=NACK) /
//                     V volume / N last event (90/80 note vel hex) / O block
//                     count (FIFO-full push attempts, must stay 00) / @ ms
//
//  Event map (INSTRUMENT-MAPPING.md §3 + PCB v1 6-string optical array):
//      key i      on/off note 60+i (C4..C5), vel 100
//      photo[0]   block edge = on note 40 (E2,  82.41 Hz) vel 110, release = off
//      photo[1]   block edge = on note 45 (A2, 110.00 Hz) vel 110, release = off
//      photo[2]   block edge = on note 50 (D3, 146.83 Hz) vel 110, release = off
//      photo[3]   block edge = on note 55 (G3, 196.00 Hz) vel 110, release = off
//      photo[4]   block edge = on note 59 (B3, 246.94 Hz) vel 110, release = off
//      photo[5]   block edge = on note 64 (E4, 329.63 Hz) vel 110, release = off
//      ToF #1     10..70 cm -> note 60..84 (24 mm/step, 24-boundary
//                 thermometer, zero DSP), +/-20 mm hysteresis, 5-point median;
//                 enter (3-sample dwell): on; change: off(old)+on(new),
//                 re-pluck, >=180 ms apart, glide=0 (engine glide steals the
//                 global last_voice -> never used); leave (>800 mm 200 ms or
//                 NACK 500 ms): off.  Distance 10->70 cm maps to rising pitch.
//      priority   photo > key > ToF at the FIFO write port; blocked pushes
//                 retry (nothing is dropped), O= counts block events.
//
//  Structure: single 50 MHz domain, zero BSRAM (FIFO = distributed RAM),
//  zero DSP (all multiplies are small constant LUT multiplies or shifts),
//  250 ms power-up mask, 2 ms/8 ms asymmetric debounce on 19 switch inputs.
// =============================================================================
`default_nettype none

module hw_input_mgr #(
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer SCL_HZ    = 10_000,  // full rate restored after moving I2C
                                           // from J8 (BANK7, shared with I2S) to
                                           // J13-24/25 (SDRAM0 bank): no audio
                                           // interference measured at 10 kHz
    parameter integer DB_ON_MS  = 2,
    parameter integer DB_OFF_MS = 8,
    parameter integer TOF_MS    = 20,     // ToF poll period, ms
    parameter integer MASK_MS   = 250,    // power-up event mask, ms
    parameter integer QUIET     = 0,      // bisect aid: 0 = I2C+telemetry live,
                                          //   1 = both frozen, 2 = telemetry frozen
                                          //   only, 3 = I2C frozen only
    parameter [6:0]   VOL_INIT  = 7'd100  // initial volume (100 for sim, 127 for top)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [12:0] key_raw,
    input  wire [5:0]  photo_raw,
    input  wire        ec1a_raw,
    input  wire        ec1b_raw,
    input  wire        ec2a_raw,
    input  wire        ec2b_raw,
    input  wire        ec3a_raw,
    input  wire        ec3b_raw,
    input  wire        ec4a_raw,
    input  wire        ec4b_raw,
    inout  wire        scl_a,
    inout  wire        sda_a,
    inout  wire        scl_b,
    inout  wire        sda_b,
    output wire        dbg_tx,
    // external volume override (from 7-inch LCD touchscreen slider or MIDI CC7)
    input  wire        ext_vol_valid,
    input  wire [6:0]  ext_vol_val,
    // note event stream (single event per pulse, >=16 clk apart)
    output reg         ev_on_valid,
    output reg  [6:0]  ev_on_note,
    output reg  [6:0]  ev_on_vel,
    output reg         ev_off_valid,
    output reg  [6:0]  ev_off_note,
    output reg         ev_glide_on,
    output reg  [6:0]  ev_glide_time,
    // post-mix volume for top.v gain stage
    output wire [6:0]  volume,
    // telemetry mirrors
    output wire [12:0] key_state,
    output wire [5:0]  photo_state,
    output wire [15:0] tof_dist,
    output wire [7:0]  ovf_cnt,
    output wire [7:0]  tof_ack_cnt,
    output wire [7:0]  tof_nack_cnt,
    output wire [7:0]  tof_curr_addr,
    output wire        tof_sda_raw
);

    // ---------------------------------------------------------- 1 ms tick --
    localparam integer MS_DIV = CLK_HZ / 1000;
    reg  [15:0] ms_div;
    reg         tick1ms;
    always @(posedge clk) begin
        if (!rst_n) begin
            ms_div <= 16'd0; tick1ms <= 1'b0;
        end else if (ms_div == MS_DIV - 1) begin
            ms_div <= 16'd0; tick1ms <= 1'b1;
        end else begin
            ms_div <= ms_div + 16'd1; tick1ms <= 1'b0;
        end
    end

    reg [31:0] ms_cnt;
    always @(posedge clk)
        if (!rst_n)       ms_cnt <= 32'd0;
        else if (tick1ms) ms_cnt <= ms_cnt + 32'd1;

    wire mask = (ms_cnt < MASK_MS);

    // --------------------------------------- 19x sync + debounce (2/8 ms) --
    wire [18:0] sw_raw = {photo_raw, key_raw};      // [18:13]=photo [12:0]=key
    reg  [18:0] sw_stable;

    genvar gi;
    generate
        for (gi = 0; gi < 19; gi = gi + 1) begin : g_db
            reg       meta, s1, st;
            reg [3:0] cnt;
            always @(posedge clk) begin
                if (!rst_n) begin
                    meta <= 1'b1; s1 <= 1'b1; st <= 1'b1; cnt <= 4'd0;
                end else begin
                    meta <= sw_raw[gi];
                    s1   <= meta;
                    if (tick1ms) begin
                        if (s1 == st) cnt <= 4'd0;
                        else if (cnt >= ((st == 1'b1) ? DB_ON_MS[3:0] - 4'd1
                                                      : DB_OFF_MS[3:0] - 4'd1)) begin
                            st  <= s1;
                            cnt <= 4'd0;
                        end else cnt <= cnt + 4'd1;
                    end
                end
            end
            assign sw_stable[gi] = st;
        end
    endgenerate

    assign key_state   = sw_stable[12:0];
    assign photo_state = sw_stable[18:13];

    // 1-clk edge pulses, computed at the 1 ms tick across all 13 keys & 6 optical strings
    reg [12:0] key_d;
    reg [5:0]  photo_d;
    reg [12:0] kp_1, kr_1;
    reg [5:0]  pp_1, pr_1;
    always @(posedge clk) begin
        if (!rst_n) begin
            key_d <= 13'h1FFF; photo_d <= 6'h3F;
            kp_1 <= 13'd0; kr_1 <= 13'd0; pp_1 <= 6'd0; pr_1 <= 6'd0;
        end else if (tick1ms) begin
            key_d   <= key_state;
            photo_d <= photo_state;
            kp_1 <= key_d & ~key_state;             // pressed  (active low)
            kr_1 <= ~key_d & key_state;             // released
            pp_1 <= photo_d & ~photo_state;         // beam blocked (all 6 channels)
            pr_1 <= ~photo_d & photo_state;         // beam clear (all 6 channels)
        end else begin
            kp_1 <= 13'd0; kr_1 <= 13'd0; pp_1 <= 6'd0; pr_1 <= 6'd0;
        end
    end

    // ------------------------------------------------------ EC11 #1 volume --
    // 2-FF sync, sampled at 1 kHz, single-quadrature-step adjacency only
    // (same proven decoder as hw_bringup/rtl/inputs_top.v), plus external
    // volume synchronization from 7-inch LCD touch slider / MIDI CC7.
    reg ea1, ea2, eb1, eb2;
    reg e2a1, e2a2, e2b1, e2b2;
    reg e3a1, e3a2, e3b1, e3b2;
    reg e4a1, e4a2, e4b1, e4b2;
    always @(posedge clk) begin
        if (!rst_n) begin
            ea1  <= 1'b1; ea2  <= 1'b1; eb1  <= 1'b1; eb2  <= 1'b1;
            e2a1 <= 1'b1; e2a2 <= 1'b1; e2b1 <= 1'b1; e2b2 <= 1'b1;
            e3a1 <= 1'b1; e3a2 <= 1'b1; e3b1 <= 1'b1; e3b2 <= 1'b1;
            e4a1 <= 1'b1; e4a2 <= 1'b1; e4b1 <= 1'b1; e4b2 <= 1'b1;
        end else begin
            ea1  <= ec1a_raw; ea2  <= ea1;  eb1  <= ec1b_raw; eb2  <= eb1;
            e2a1 <= ec2a_raw; e2a2 <= e2a1; e2b1 <= ec2b_raw; e2b2 <= e2b1;
            e3a1 <= ec3a_raw; e3a2 <= e3a1; e3b1 <= ec3b_raw; e3b2 <= e3b1;
            e4a1 <= ec4a_raw; e4a2 <= e4a1; e4b1 <= ec4b_raw; e4b2 <= e4b1;
        end
    end

    reg  [1:0] q1_d, q2_d, q3_d, q4_d;
    reg  [6:0] vol_r;
    reg signed [15:0] enc_dbg;

    function signed [1:0] qstep;
        input [1:0] prev;
        input [1:0] cur;
        reg [3:0] p;
        begin
            p = {prev, cur};
            case (p)
                4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: qstep = 2'sd1;
                4'b01_00, 4'b11_01, 4'b10_11, 4'b00_10: qstep = -2'sd1;
                default:                                qstep = 2'sd0;
            endcase
        end
    endfunction

    wire [1:0] q1 = {ea2,  eb2};
    wire [1:0] q2 = {e2a2, e2b2};
    wire [1:0] q3 = {e3a2, e3b2};
    wire [1:0] q4 = {e4a2, e4b2};
    wire signed [3:0] q_sum = qstep(q1_d, q1) + qstep(q2_d, q2) + qstep(q3_d, q3) + qstep(q4_d, q4);

    always @(posedge clk) begin
        if (!rst_n) begin
            q1_d <= 2'b11; q2_d <= 2'b11; q3_d <= 2'b11; q4_d <= 2'b11;
            vol_r <= VOL_INIT; enc_dbg <= 16'sd0;
        end else if (ext_vol_valid) begin
            vol_r <= ext_vol_val;
        end else if (tick1ms) begin
            q1_d <= q1; q2_d <= q2; q3_d <= q3; q4_d <= q4;
            enc_dbg <= enc_dbg + q_sum;
            if (q_sum > 0) begin
                if (vol_r != 7'd127) vol_r <= vol_r + 7'd1;
            end else if (q_sum < 0) begin
                if (vol_r != 7'd0)   vol_r <= vol_r - 7'd1;
            end
        end
    end

    assign volume = vol_r;

    // --------------------------------------------------- i2c master + seq --
    reg        m_go;
    reg  [1:0] m_cmd;
    reg  [7:0] m_wdata;
    reg        m_ack_bit;
    wire       m_busy, m_done, m_ack_err;
    wire [7:0] m_rdata;
    wire       i2c_scl_oe, i2c_sda_oe;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_i2c (
        .clk(clk), .rst_n(rst_n),
        .go(m_go), .cmd(m_cmd), .wdata(m_wdata), .ack_bit(m_ack_bit),
        .sda_in(sda_a),
        .busy(m_busy), .done(m_done), .ack_err(m_ack_err), .rdata(m_rdata),
        .scl_oe(i2c_scl_oe), .sda_oe(i2c_sda_oe)
    );

    // SCL push-pull: actively drives High (3.3V) and Low (0V), eliminating dependency on external pull-up resistor.
    assign scl_a = ~i2c_scl_oe;
    // SDA open-drain: tri-state when high for slave ACK/data
    assign sda_a = i2c_sda_oe ? 1'b0 : 1'bz;

    localparam [1:0] C_START = 2'd0, C_WRITE = 2'd1, C_READ = 2'd2, C_STOP = 2'd3;
    localparam [3:0] P_WAIT = 4'd0,  P_START = 4'd1, P_ADDR = 4'd2, P_REG = 4'd3,
                     P_RST = 4'd4,   P_RADR = 4'd5, P_RD0 = 4'd6,  P_RD1 = 4'd7,
                     P_RD2 = 4'd8,   P_STOP = 4'd9, P_REP = 4'd10, P_HOLD = 4'd11;

    reg  [3:0] ps;
    reg        nack_r;
    reg  [7:0] d_lo, d_hi;
    reg [31:0] tof_last_ms;
    reg [15:0] dist_r;

    reg  [7:0] i2c_dev_addr;
    reg  [3:0] nack_streak;
    reg  [7:0] ack_cnt_r;
    reg  [7:0] nack_cnt_r;

    // --- Second ToF I2C Master on Bus B (SCL2/SDA2: J13-29/30, F14/F13) ---
    reg        m_go_b;
    reg  [1:0] m_cmd_b;
    reg  [7:0] m_wdata_b;
    reg        m_ack_bit_b;
    wire       m_busy_b, m_done_b, m_ack_err_b;
    wire [7:0] m_rdata_b;
    wire       i2c_scl_oe_b, i2c_sda_oe_b;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_i2c_b (
        .clk(clk), .rst_n(rst_n),
        .go(m_go_b), .cmd(m_cmd_b), .wdata(m_wdata_b), .ack_bit(m_ack_bit_b),
        .sda_in(sda_b),
        .busy(m_busy_b), .done(m_done_b), .ack_err(m_ack_err_b), .rdata(m_rdata_b),
        .scl_oe(i2c_scl_oe_b), .sda_oe(i2c_sda_oe_b)
    );

    assign scl_b = ~i2c_scl_oe_b;
    assign sda_b = i2c_sda_oe_b ? 1'b0 : 1'bz;

    reg  [3:0] ps_b;
    reg        nack_b_r;
    reg  [7:0] d_lo_b, d_hi_b;
    reg [31:0] tof_last_ms_b;
    reg [15:0] dist_b_r;
    reg  [7:0] i2c_dev_addr_b;
    reg  [3:0] nack_streak_b;
    reg  [7:0] ack_cnt_b_r;
    reg  [7:0] nack_cnt_b_r;

    wire tof_smp   = (ps   == P_REP) && !m_busy;    // Bus 1 (SCL1/SDA1) completed read
    wire tof_smp_b = (ps_b == P_REP) && !m_busy_b;  // Bus 2 (SCL2/SDA2) completed read

    // VB22B auto-increment read returns HIGH byte first (measured on this
    // board 2026-10-23: 909 mm arrived as 03 8D).
    wire [15:0] dist_raw   = {d_lo, d_hi};
    wire [11:0] dist12     = (dist_raw > 16'd4095) ? 12'hFFF : dist_raw[11:0];
    wire [15:0] dist_raw_b = {d_lo_b, d_hi_b};
    wire [11:0] dist12_b   = (dist_raw_b > 16'd4095) ? 12'hFFF : dist_raw_b[11:0];

    // Auto-select active ToF bus for telemetry & Theremin pitch (Bus 1 priority, Bus 2 seamless fallback)
    wire bus_a_active    = (dist_r != 16'hFFFF);
    assign tof_dist      = bus_a_active ? dist_r      : dist_b_r;
    assign tof_ack_cnt   = (ack_cnt_r != 8'd0) ? ack_cnt_r : ack_cnt_b_r;
    assign tof_nack_cnt  = bus_a_active ? nack_cnt_r  : nack_cnt_b_r;
    assign tof_curr_addr = (ack_cnt_r != 8'd0) ? i2c_dev_addr : ((ack_cnt_b_r != 8'd0) ? i2c_dev_addr_b : i2c_dev_addr);
    assign tof_sda_raw   = sda_a & sda_b;

    always @(posedge clk) begin
        if (!rst_n) begin
            ps <= P_WAIT; m_go <= 1'b0; m_cmd <= C_START; m_wdata <= 8'h00;
            m_ack_bit <= 1'b0; nack_r <= 1'b0;
            d_lo <= 8'hFF; d_hi <= 8'hFF;
            dist_r <= 16'hFFFF; tof_last_ms <= 32'd0;
            i2c_dev_addr <= 8'hA4; // Default to 0xA4 (VB22B 7-bit 0x52)
            nack_streak  <= 4'd0;
            ack_cnt_r    <= 8'd0;
            nack_cnt_r   <= 8'd0;
        end else begin
            m_go <= 1'b0;
            case (ps)
                P_WAIT: if (ms_cnt >= 32'd100 && (QUIET != 1) && (QUIET != 3)) begin
                    nack_r <= 1'b0; ps <= P_START;
                end
                P_START: if (!m_busy) begin
                    m_cmd <= C_START; m_go <= 1'b1; ps <= P_ADDR;
                end
                P_ADDR: if (m_done) begin
                    m_cmd <= C_WRITE; m_wdata <= i2c_dev_addr; m_go <= 1'b1; ps <= P_REG;
                end
                P_REG: if (m_done) begin
                    if (m_ack_err) begin
                        nack_r <= 1'b1;
                        ps <= P_STOP;
                        if (nack_cnt_r != 8'hFF) nack_cnt_r <= nack_cnt_r + 8'd1;
                        // Alternate between 0xA4 (VB22B @0x52) and 0x52 (VL53L0X @0x29) after 8 failed attempts
                        if (nack_streak >= 4'd8) begin
                            nack_streak  <= 4'd0;
                            i2c_dev_addr <= (i2c_dev_addr == 8'hA4) ? 8'h52 : 8'hA4;
                        end else begin
                            nack_streak  <= nack_streak + 4'd1;
                        end
                    end else begin
                        if (ack_cnt_r != 8'hFF) ack_cnt_r <= ack_cnt_r + 8'd1;
                        nack_streak <= 4'd0;
                        m_cmd <= C_WRITE; m_wdata <= 8'h00; m_go <= 1'b1; ps <= P_RST;
                    end
                end
                P_RST: if (m_done) begin
                    if (m_ack_err) begin nack_r <= 1'b1; ps <= P_STOP; end
                    else begin m_cmd <= C_START; m_go <= 1'b1; ps <= P_RADR; end
                end
                P_RADR: if (m_done) begin
                    m_cmd <= C_WRITE; m_wdata <= {i2c_dev_addr[7:1], 1'b1}; m_go <= 1'b1; ps <= P_RD0;
                end
                P_RD0: if (m_done) begin
                    if (m_ack_err) begin nack_r <= 1'b1; ps <= P_STOP; end
                    else begin
                        if (ack_cnt_r != 8'hFF) ack_cnt_r <= ack_cnt_r + 8'd1;
                        // address write done -> issue READ of reg 0x00 (lo)
                        m_cmd <= C_READ; m_ack_bit <= 1'b1;
                        m_go <= 1'b1; ps <= P_RD1;
                    end
                end
                P_RD1: if (m_done) begin
                    // READ#1 done -> reg 0x00 = distance low byte
                    d_lo <= m_rdata;
                    m_cmd <= C_READ; m_ack_bit <= 1'b0;
                    m_go <= 1'b1; ps <= P_RD2;
                end
                P_RD2: if (m_done) begin
                    // READ#2 done -> reg 0x01 = distance high byte
                    d_hi <= m_rdata;
                    ps <= P_STOP;
                end
                P_STOP: if (!m_busy) begin
                    m_cmd <= C_STOP; m_go <= 1'b1; ps <= P_REP;
                end
                P_REP: if (!m_busy) begin
                    dist_r <= nack_r ? 16'hFFFF : dist_raw;
                    nack_r <= 1'b0;
                    tof_last_ms <= ms_cnt;
                    ps <= P_HOLD;
                end
                P_HOLD: if ((ms_cnt - tof_last_ms) >= TOF_MS) begin
                    nack_r <= 1'b0; ps <= P_START;
                end
                default: ps <= P_WAIT;
            endcase
        end
    end

    // Bus B (SCL2/SDA2) polling FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            ps_b <= P_WAIT; m_go_b <= 1'b0; m_cmd_b <= C_START; m_wdata_b <= 8'h00;
            m_ack_bit_b <= 1'b0; nack_b_r <= 1'b0;
            d_lo_b <= 8'hFF; d_hi_b <= 8'hFF;
            dist_b_r <= 16'hFFFF; tof_last_ms_b <= 32'd0;
            i2c_dev_addr_b <= 8'hA4;
            nack_streak_b  <= 4'd0;
            ack_cnt_b_r    <= 8'd0;
            nack_cnt_b_r   <= 8'd0;
        end else begin
            m_go_b <= 1'b0;
            case (ps_b)
                P_WAIT: if (ms_cnt >= 32'd105 && (QUIET != 1) && (QUIET != 3)) begin
                    nack_b_r <= 1'b0; ps_b <= P_START;
                end
                P_START: if (!m_busy_b) begin
                    m_cmd_b <= C_START; m_go_b <= 1'b1; ps_b <= P_ADDR;
                end
                P_ADDR: if (m_done_b) begin
                    m_cmd_b <= C_WRITE; m_wdata_b <= i2c_dev_addr_b; m_go_b <= 1'b1; ps_b <= P_REG;
                end
                P_REG: if (m_done_b) begin
                    if (m_ack_err_b) begin
                        nack_b_r <= 1'b1;
                        ps_b <= P_STOP;
                        if (nack_cnt_b_r != 8'hFF) nack_cnt_b_r <= nack_cnt_b_r + 8'd1;
                        if (nack_streak_b >= 4'd8) begin
                            nack_streak_b  <= 4'd0;
                            i2c_dev_addr_b <= (i2c_dev_addr_b == 8'hA4) ? 8'h52 : 8'hA4;
                        end else begin
                            nack_streak_b  <= nack_streak_b + 4'd1;
                        end
                    end else begin
                        if (ack_cnt_b_r != 8'hFF) ack_cnt_b_r <= ack_cnt_b_r + 8'd1;
                        nack_streak_b <= 4'd0;
                        m_cmd_b <= C_WRITE; m_wdata_b <= 8'h00; m_go_b <= 1'b1; ps_b <= P_RST;
                    end
                end
                P_RST: if (m_done_b) begin
                    if (m_ack_err_b) begin nack_b_r <= 1'b1; ps_b <= P_STOP; end
                    else begin m_cmd_b <= C_START; m_go_b <= 1'b1; ps_b <= P_RADR; end
                end
                P_RADR: if (m_done_b) begin
                    m_cmd_b <= C_WRITE; m_wdata_b <= {i2c_dev_addr_b[7:1], 1'b1}; m_go_b <= 1'b1; ps_b <= P_RD0;
                end
                P_RD0: if (m_done_b) begin
                    if (m_ack_err_b) begin nack_b_r <= 1'b1; ps_b <= P_STOP; end
                    else begin
                        if (ack_cnt_b_r != 8'hFF) ack_cnt_b_r <= ack_cnt_b_r + 8'd1;
                        m_cmd_b <= C_READ; m_ack_bit_b <= 1'b1;
                        m_go_b <= 1'b1; ps_b <= P_RD1;
                    end
                end
                P_RD1: if (m_done_b) begin
                    d_lo_b <= m_rdata_b;
                    m_cmd_b <= C_READ; m_ack_bit_b <= 1'b0;
                    m_go_b <= 1'b1; ps_b <= P_RD2;
                end
                P_RD2: if (m_done_b) begin
                    d_hi_b <= m_rdata_b;
                    ps_b <= P_STOP;
                end
                P_STOP: if (!m_busy_b) begin
                    m_cmd_b <= C_STOP; m_go_b <= 1'b1; ps_b <= P_REP;
                end
                P_REP: if (!m_busy_b) begin
                    dist_b_r <= nack_b_r ? 16'hFFFF : dist_raw_b;
                    nack_b_r <= 1'b0;
                    tof_last_ms_b <= ms_cnt;
                    ps_b <= P_HOLD;
                end
                P_HOLD: if ((ms_cnt - tof_last_ms_b) >= TOF_MS) begin
                    nack_b_r <= 1'b0; ps_b <= P_START;
                end
                default: ps_b <= P_WAIT;
            endcase
        end
    end

    // ------------------------------------------------ ToF median + quantize --
    // 5-point median of the last 5 valid readings, computed by a 1-swap-per-clk
    // bubble FSM (the filter only runs at 50 Hz; a combinational 10-compare
    // chain synthesized as ~40 ns of ripple and broke timing).  Distances are
    // clamped to 12 bits (0xFFF = "far"), so all compares are 12-bit.
    reg [11:0] f0, f1, f2, f3, f4;
    reg [11:0] med_r;

    wire valid_a = tof_smp   && !nack_r;
    wire valid_b = tof_smp_b && !nack_b_r;
    wire filt_we = valid_a || (valid_b && !bus_a_active);
    wire [11:0] dist12_sel = valid_a ? dist12 : dist12_b;

    always @(posedge clk) begin
        if (!rst_n) begin
            f0 <= 12'hFFF; f1 <= 12'hFFF; f2 <= 12'hFFF;
            f3 <= 12'hFFF; f4 <= 12'hFFF;
        end else if (filt_we) begin
            f0 <= f1; f1 <= f2; f2 <= f3; f3 <= f4; f4 <= dist12_sel;
        end
    end

    // bubble FSM: mst 1 = load window, 2..11 = the 10 compare-swaps, 12 = done
    reg [11:0] s0, s1, s2, s3, s4;
    reg [11:0] st;                       // swap temp
    reg [3:0]  mst;
    reg        med_d1, med_pulse;

    always @(posedge clk) begin
        if (!rst_n) begin
            mst <= 4'd0; med_r <= 12'hFFF; med_d1 <= 1'b0; med_pulse <= 1'b0;
        end else begin
            med_d1 <= 1'b0;
            med_pulse <= 1'b0;
            case (mst)
                4'd0: if (filt_we) mst <= 4'd1;
                4'd1: begin
                    s0 <= f0; s1 <= f1; s2 <= f2; s3 <= f3; s4 <= f4;
                    mst <= 4'd2;
                end
                4'd2: begin if (s0 > s1) begin st = s0; s0 <= s1; s1 <= st; end mst <= 4'd3; end
                4'd3: begin if (s1 > s2) begin st = s1; s1 <= s2; s2 <= st; end mst <= 4'd4; end
                4'd4: begin if (s2 > s3) begin st = s2; s2 <= s3; s3 <= st; end mst <= 4'd5; end
                4'd5: begin if (s3 > s4) begin st = s3; s3 <= s4; s4 <= st; end mst <= 4'd6; end
                4'd6: begin if (s0 > s1) begin st = s0; s0 <= s1; s1 <= st; end mst <= 4'd7; end
                4'd7: begin if (s1 > s2) begin st = s1; s1 <= s2; s2 <= st; end mst <= 4'd8; end
                4'd8: begin if (s2 > s3) begin st = s2; s2 <= s3; s3 <= st; end mst <= 4'd9; end
                4'd9: begin if (s0 > s1) begin st = s0; s0 <= s1; s1 <= st; end mst <= 4'd10; end
                4'd10: begin if (s1 > s2) begin st = s1; s1 <= s2; s2 <= st; end mst <= 4'd11; end
                4'd11: begin if (s0 > s1) begin st = s0; s0 <= s1; s1 <= st; end mst <= 4'd12; end
                4'd12: begin
                    med_r <= s2;
                    med_d1 <= 1'b1;
                    mst <= 4'd0;
                end
                default: mst <= 4'd0;
            endcase
            med_pulse <= med_d1;   // med_r valid one clk after it is written
        end
    end

    // ToF state (declared before the hysteresis boundary wires use t_note)
    localparam [1:0] T_OUT = 2'd0, T_IN = 2'd1;
    reg [1:0]  t_st;
    reg [4:0]  t_note;          // held note index 0..24 (note = 60 + t_note)
    reg [3:0]  t_exit;          // consecutive >800 mm samples (need 10 = 200 ms)
    reg [5:0]  t_nackn;         // consecutive NACK samples (need 25 = 500 ms)
    reg [15:0] tbuf [0:1];      // tiny ToF event buffer, word = {off,note,vel,glide}
    reg [1:0]  tcnt;
    reg [1:0]  t_dwell;         // consecutive in-range samples before entry (need 3)
    reg [31:0] t_last_on_ms;    // rate limit: >=180 ms between ToF on-events
    // NOTE: all ToF events use glide=0.  The engine's glide allocation reuses
    // the GLOBAL last_voice -- if a key voice sounded, a glide ToF on would
    // steal and retune THAT voice (measured 2026-10-23: harsh wrong pitches).
    // Re-pluck semantics + 180 ms rate limit instead.

    // note index k: count of 24 mm boundaries below med_r (b_i = 100+24*(i+1))
    wire [23:0] th;
    genvar gj;
    generate
        for (gj = 0; gj < 24; gj = gj + 1) begin : g_th
            assign th[gj] = (med_r >= 16'd124 + gj * 24);
        end
    endgenerate
    wire [4:0] k_th = th[0] + th[1] + th[2] + th[3] + th[4] + th[5] + th[6]
                    + th[7] + th[8] + th[9] + th[10] + th[11] + th[12] + th[13]
                    + th[14] + th[15] + th[16] + th[17] + th[18] + th[19]
                    + th[20] + th[21] + th[22] + th[23];

    // hysteresis boundaries around the held note: 100 + n*24 +/- 20
    wire [4:0]  tnp1 = t_note + 5'd1;
    wire [10:0] up_b = 11'd120 + {2'd0, tnp1, 4'b0000} + {3'd0, tnp1, 3'b000};
    wire [10:0] dn_b = 11'd80  + {2'd0, t_note, 4'b0000} + {3'd0, t_note, 3'b000};

    wire [6:0] tnote_cur = 7'd60 + {2'd0, t_note};
    wire [6:0] tnote_new = 7'd60 + {2'd0, k_th};

    // ------------------------------------- pending events + priority arbiter --
    // photo[0..5] > key[0..12] (lowest index first) > ToF
    reg [12:0] kpend_on, kpend_off;
    reg [5:0]  ppend_on, ppend_off;

    reg  [3:0] fwp, frp;
    reg  [4:0] fcnt;
    reg [15:0] fmem [0:15];

    wire fifo_room = (fcnt < 5'd16);

    reg  [2:0] pidx;
    reg        phit;
    integer pi;
    always @(*) begin
        pidx = 3'd6; phit = 1'b0;
        for (pi = 0; pi < 6; pi = pi + 1) begin
            if (!phit && (ppend_on[pi] | ppend_off[pi])) begin
                pidx = pi[2:0]; phit = 1'b1;
            end
        end
    end

    wire p_grant = fifo_room & phit;

    reg  [3:0] kidx;
    reg        khit;
    integer ki;
    always @(*) begin
        kidx = 4'd13; khit = 1'b0;
        for (ki = 0; ki < 13; ki = ki + 1) begin
            if (!khit && (kpend_on[ki] | kpend_off[ki])) begin
                kidx = ki[3:0]; khit = 1'b1;
            end
        end
    end

    wire k_grant = fifo_room & ~p_grant & khit;
    wire t_grant = fifo_room & ~p_grant & ~k_grant & (tcnt != 2'd0);
    wire push    = p_grant | k_grant | t_grant;

    wire [5:0]  pgrant_on_m  = (p_grant && ppend_on[pidx])  ? (6'd1 << pidx) : 6'd0;
    wire [5:0]  pgrant_off_m = (p_grant && !ppend_on[pidx] && ppend_off[pidx]) ? (6'd1 << pidx) : 6'd0;
    wire [12:0] kgrant_on_m  = (k_grant && kpend_on[kidx])  ? (13'd1 << kidx) : 13'd0;
    wire [12:0] kgrant_off_m = (k_grant && !kpend_on[kidx] && kpend_off[kidx]) ? (13'd1 << kidx) : 13'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            kpend_on <= 13'd0; kpend_off <= 13'd0;
            ppend_on <= 6'd0;  ppend_off <= 6'd0;
        end else if (!mask) begin
            kpend_on  <= (kpend_on  | kp_1) & ~kgrant_on_m;
            kpend_off <= (kpend_off | kr_1) & ~kgrant_off_m;
            ppend_on  <= (ppend_on  | pp_1) & ~pgrant_on_m;
            ppend_off <= (ppend_off | pr_1) & ~pgrant_off_m;
        end
    end

    // serializer control wires (declared before FIFO/serializer blocks use them)
    reg  [4:0]  spc;
    wire        spc_rdy = (spc == 5'd0);
    wire        emit;
    wire [15:0] ev_dat;

    reg [7:0] n_type;
    reg [6:0] n_note, n_vel;

    // 6-string guitar standard tuning lookup (INSTRUMENT-MAPPING.md §3):
    // String 0..5 -> E2(40), A2(45), D3(50), G3(55), B3(59), E4(64)
    function [6:0] photo_note;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: photo_note = 7'd40; // E2 (82.41 Hz)
                3'd1: photo_note = 7'd45; // A2 (110.00 Hz)
                3'd2: photo_note = 7'd50; // D3 (146.83 Hz)
                3'd3: photo_note = 7'd55; // G3 (196.00 Hz)
                3'd4: photo_note = 7'd59; // B3 (246.94 Hz)
                3'd5: photo_note = 7'd64; // E4 (329.63 Hz)
                default: photo_note = 7'd40;
            endcase
        end
    endfunction

    // push data mux (photo > key > ToF)
    reg [15:0] push_dat;
    always @(*) begin
        if (p_grant) begin
            push_dat = ppend_on[pidx] ? {1'b0, photo_note(pidx), 7'd110, 1'b0}
                                      : {1'b1, photo_note(pidx), 7'd0,   1'b0};
        end else if (k_grant) begin
            push_dat = kpend_on[kidx]
                     ? {1'b0, 7'd60 + {3'd0, kidx}, 7'd100, 1'b0}
                     : {1'b1, 7'd60 + {3'd0, kidx}, 7'd0,   1'b0};
        end else begin
            push_dat = tbuf[0];
        end
    end

    // FIFO: 16 x 16b distributed RAM, word = {off, note[6:0], vel[6:0], glide}
    always @(posedge clk) begin
        if (!rst_n) begin
            fwp <= 4'd0; frp <= 4'd0; fcnt <= 5'd0;
        end else begin
            if (push) begin
                fmem[fwp] <= push_dat;
                fwp <= fwp + 4'd1;
            end
            if (emit) frp <= frp + 4'd1;
            case ({push, emit})
                2'b10:   fcnt <= fcnt + 5'd1;
                2'b01:   fcnt <= fcnt - 5'd1;
                default: ;
            endcase
        end
    end

    // block counter: a source wanted to push while the FIFO was full
    wire want_push = (|ppend_on) | (|ppend_off) | (|kpend_on) | (|kpend_off) | (tcnt != 2'd0);
    wire block_now = want_push & ~fifo_room;
    reg  block_d;
    wire block_ev;

    reg [7:0] ovf_r;

    // -------------------------------------------- ToF FSM + buffer (merged) --
    // Single driver for tbuf/tcnt: arbiter drain first, FSM pushes gated off
    // on a grant clk (pushes are 20 ms apart, grants last one clk).
    always @(posedge clk) begin
        if (!rst_n) begin
            t_st <= T_OUT; t_note <= 5'd0; t_exit <= 4'd0; t_nackn <= 6'd0;
            tbuf[0] <= 16'd0; tbuf[1] <= 16'd0; tcnt <= 2'd0;
            t_dwell <= 2'd0; t_last_on_ms <= 32'd0;
        end else begin
            // arbiter drain (highest priority in this block)
            if (t_grant) begin
                tbuf[0] <= tbuf[1];
                tcnt <= tcnt - 2'd1;
            end
            // NACK tracking (any state: reset when either Bus 1 or Bus 2 responds)
            if (valid_a || valid_b) begin
                t_nackn <= 6'd0;
            end else if (tof_smp && nack_r && (dist_b_r == 16'hFFFF)) begin
                if (t_nackn != 6'd25) t_nackn <= t_nackn + 6'd1;
            end
            // event generation, only on clks without a drain
            if (!t_grant) begin
                // NACK timeout while playing -> treat as "hand left"
                if (t_st == T_IN && t_nackn >= 6'd25 && tcnt == 2'd0) begin
                    t_st <= T_OUT;
                    tbuf[0] <= {1'b1, tnote_cur, 7'd0, 1'b0};
                    tcnt <= 2'd1;
                end else if (med_pulse && !mask) begin
                    case (t_st)
                        T_OUT: begin
                            // entry dwell: 3 consecutive in-range medians (~60 ms)
                            // so a hand merely passing through does not trigger
                            if (med_r <= 16'd700 && tcnt == 2'd0) begin
                                if (t_dwell >= 2'd2) begin
                                    t_note <= k_th;
                                    t_exit <= 4'd0;
                                    t_dwell <= 2'd0;
                                    tbuf[0] <= {1'b0, tnote_new, 7'd100, 1'b0};
                                    tcnt <= 2'd1;
                                    t_st <= T_IN;
                                    t_last_on_ms <= ms_cnt;
                                end else begin
                                    t_dwell <= t_dwell + 2'd1;
                                end
                            end else begin
                                t_dwell <= 2'd0;
                            end
                        end
                        T_IN: begin
                            if (med_r > 16'd800) begin
                                if (t_exit != 4'd10) t_exit <= t_exit + 4'd1;
                                if (t_exit >= 4'd9 && tcnt == 2'd0) begin
                                    tbuf[0] <= {1'b1, tnote_cur, 7'd0, 1'b0};
                                    tcnt <= 2'd1;
                                    t_st <= T_OUT;
                                end
                            end else if (med_r <= 16'd700) begin
                                t_exit <= 4'd0;
                                // re-pluck pitch change, >=180 ms apart (rate limit
                                // keeps a moving hand from machine-gunning)
                                if (k_th > t_note && med_r >= {5'd0, up_b}
                                    && tcnt == 2'd0
                                    && (ms_cnt - t_last_on_ms >= 32'd180)) begin
                                    tbuf[0] <= {1'b1, tnote_cur, 7'd0, 1'b0};
                                    tbuf[1] <= {1'b0, tnote_new, 7'd100, 1'b0};
                                    tcnt <= 2'd2;
                                    t_note <= k_th;
                                    t_last_on_ms <= ms_cnt;
                                end else if (k_th < t_note && med_r <= {5'd0, dn_b}
                                    && tcnt == 2'd0
                                    && (ms_cnt - t_last_on_ms >= 32'd180)) begin
                                    tbuf[0] <= {1'b1, tnote_cur, 7'd0, 1'b0};
                                    tbuf[1] <= {1'b0, tnote_new, 7'd100, 1'b0};
                                    tcnt <= 2'd2;
                                    t_note <= k_th;
                                    t_last_on_ms <= ms_cnt;
                                end
                            end
                            // 700..800 mm: hysteresis band, hold everything
                        end
                        default: t_st <= T_OUT;
                    endcase
                end
            end
        end
    end

    // FIFO-full block event (rising edge of the blocked condition)
    assign block_ev = block_now & ~block_d;
    always @(posedge clk) block_d <= block_now;
    always @(posedge clk) begin
        if (!rst_n)                          ovf_r <= 8'd0;
        else if (block_ev && ovf_r != 8'hFF) ovf_r <= ovf_r + 8'd1;
    end
    assign ovf_cnt = ovf_r;

    // --------------------------------------------------------- serializer --
    // >=16 clk between events (engine load FSM needs 14; on AND off both use
    // the same channel, so one spacing counter rules them all).
    assign ev_dat = fmem[frp];
    assign emit   = (fcnt != 5'd0) & spc_rdy;

    always @(posedge clk) begin
        if (!rst_n) begin
            spc <= 5'd0;
            ev_on_valid <= 1'b0;  ev_on_note <= 7'd0;  ev_on_vel <= 7'd0;
            ev_off_valid <= 1'b0; ev_off_note <= 7'd0;
            ev_glide_on <= 1'b0;  ev_glide_time <= 7'd0;   // glide unused (S5 fix)
            n_type <= 8'h00; n_note <= 7'd0; n_vel <= 7'd0;
        end else begin
            ev_on_valid  <= 1'b0;
            ev_off_valid <= 1'b0;
            if (emit) begin
                spc <= 5'd16;
                n_type <= ev_dat[15] ? 8'h80 : 8'h90;
                n_note <= ev_dat[14:8];
                n_vel  <= ev_dat[7:1];
                if (ev_dat[15]) begin
                    ev_off_valid <= 1'b1;
                    ev_off_note  <= ev_dat[14:8];
                end else begin
                    ev_on_valid  <= 1'b1;
                    ev_on_note   <= ev_dat[14:8];
                    ev_on_vel    <= ev_dat[7:1];
                    ev_glide_on  <= ev_dat[0];
                end
            end else if (spc != 5'd0) begin
                spc <= spc - 5'd1;
            end
        end
    end

    // ------------------------------------------------------- telemetry -----
    reg        send_r;
    reg [31:0] rpt_ms;
    reg [12:0] k_cap;
    reg [5:0]  p_cap;
    reg [15:0] a_cap;
    reg [7:0]  v_cap, o_cap;
    reg [7:0]  nt_cap;
    reg [6:0]  nn_cap, nv_cap;
    reg [31:0] t_cap;

    always @(posedge clk) begin
        if (!rst_n) begin
            send_r <= 1'b0; rpt_ms <= 32'd0;
            k_cap <= 13'h1FFF; p_cap <= 6'h3F; a_cap <= 16'hFFFF;
            v_cap <= {1'b0, VOL_INIT}; o_cap <= 8'd0;
            nt_cap <= 8'h00; nn_cap <= 7'd0; nv_cap <= 7'd0; t_cap <= 32'd0;
        end else begin
            send_r <= 1'b0;
            if (tick1ms && (ms_cnt - rpt_ms >= 32'd40) && ((QUIET == 0) || (QUIET == 3))) begin
                rpt_ms <= ms_cnt;
                k_cap <= key_state;  p_cap <= photo_state;
                a_cap <= dist_r;     v_cap <= {1'b0, vol_r};
                o_cap <= ovf_r;      nt_cap <= n_type;
                nn_cap <= n_note;    nv_cap <= n_vel;
                t_cap <= ms_cnt;
                send_r <= 1'b1;
            end
        end
    end

    reg        sending;
    reg [5:0]  sidx;
    reg [7:0]  tx_data;
    reg        tx_start;
    wire       uart_busy;
    reg  [7:0] ch;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(115_200)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(tx_data), .start(tx_start),
        .busy(uart_busy), .tx(dbg_tx)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            sending <= 1'b0; sidx <= 6'd0; tx_data <= 8'h00; tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (!sending) begin
                if (send_r) begin sending <= 1'b1; sidx <= 6'd0; end
            end else if (!uart_busy && !tx_start) begin
                tx_data  <= ch;
                tx_start <= 1'b1;
                if (sidx == 6'd48) sending <= 1'b0;
                else               sidx     <= sidx + 6'd1;
            end
        end
    end

    function [7:0] hexc;
        input [3:0] n;
        begin
            hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h37 + {4'd0, n});
        end
    endfunction

    wire [3:0] a_nib  = 4'd1  - sidx[3:0];     // (17-sidx) mod 16: idx 14..17 -> nib 3..0
    wire [5:0] a_base = {a_nib, 2'b00};
    wire [3:0] t_nib  = 4'd14 - sidx[4:0];     // (46-sidx) mod 32: idx 39..46 -> nib 7..0
    wire [5:0] t_base = {t_nib, 2'b00};

    always @(*) begin
        ch = 8'h20;
        case (sidx)
            6'd0 : ch = 8'h4B;                          // 'K'
            6'd1 : ch = 8'h3D;                          // '='
            6'd2 : ch = hexc({3'b000, k_cap[12]});
            6'd3 : ch = hexc(k_cap[11:8]);
            6'd4 : ch = hexc(k_cap[7:4]);
            6'd5 : ch = hexc(k_cap[3:0]);
            6'd6 : ch = 8'h20;
            6'd7 : ch = 8'h50;                          // 'P'
            6'd8 : ch = 8'h3D;
            6'd9 : ch = hexc({2'b00, p_cap[5:4]});
            6'd10: ch = hexc(p_cap[3:0]);
            6'd11: ch = 8'h20;
            6'd12: ch = 8'h41;                          // 'A'
            6'd13: ch = 8'h3D;
            6'd14, 6'd15, 6'd16, 6'd17:
                   ch = hexc(a_cap[a_base +: 4]);
            6'd18: ch = 8'h20;
            6'd19: ch = 8'h56;                          // 'V'
            6'd20: ch = 8'h3D;
            6'd21: ch = hexc(v_cap[7:4]);
            6'd22: ch = hexc(v_cap[3:0]);
            6'd23: ch = 8'h20;
            6'd24: ch = 8'h4E;                          // 'N'
            6'd25: ch = 8'h3D;
            6'd26: ch = hexc(nt_cap[7:4]);
            6'd27: ch = hexc(nt_cap[3:0]);
            6'd28: ch = hexc({1'b0, nn_cap[6:4]});
            6'd29: ch = hexc(nn_cap[3:0]);
            6'd30: ch = hexc({1'b0, nv_cap[6:4]});
            6'd31: ch = hexc(nv_cap[3:0]);
            6'd32: ch = 8'h20;
            6'd33: ch = 8'h4F;                          // 'O'
            6'd34: ch = 8'h3D;
            6'd35: ch = hexc(o_cap[7:4]);
            6'd36: ch = hexc(o_cap[3:0]);
            6'd37: ch = 8'h20;
            6'd38: ch = 8'h40;                          // '@'
            6'd39, 6'd40, 6'd41, 6'd42,
            6'd43, 6'd44, 6'd45, 6'd46:
                   ch = hexc(t_cap[t_base +: 4]);
            6'd47: ch = 8'h0D;
            6'd48: ch = 8'h0A;
            default: ch = 8'h20;
        endcase
    end

endmodule

`default_nettype wire
