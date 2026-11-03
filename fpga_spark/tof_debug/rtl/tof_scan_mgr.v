// =============================================================================
//  tof_scan_mgr.v -- Dual-Bus I2C Full Address Scanner & ToF Distance Manager
//
//  Capabilities:
//    1. Full I2C Address Scan (0x08 - 0x77) on both Bus 1 (A18/D15) and Bus 2 (F14/F13)
//    2. Device identification (Read Reg 0x03 -> ID 0x4A for VB22B)
//    3. Continuous Distance readout (Read Reg 0x00/0x01 burst -> distance in mm)
//    4. Continuous Auto-Scan: re-scans every 1s until a device is found
//    5. Push-Pull SCL for sharp clock transitions + Open-Drain SDA with pull-up
// =============================================================================
`default_nettype none

module tof_scan_mgr #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 10_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rescan_req,       // Key pulse to re-run full bus scan

    // Bus 1 Physical Pins (J13-24/25: A18/D15)
    inout  wire        scl_1,
    inout  wire        sda_1,

    // Bus 2 Physical Pins (J13-29/30: F14/F13)
    inout  wire        scl_2,
    inout  wire        sda_2,

    // Status & Telemetry Outputs
    output reg         scan_busy,        // High while scanning 0x08..0x77
    output reg         scan_done_pulse,  // 1-cycle pulse when full scan finishes
    output reg [127:0] scan_bitmap_1,    // Bitmask of responding devices on Bus 1
    output reg [127:0] scan_bitmap_2,    // Bitmask of responding devices on Bus 2
    output reg [3:0]   dev_count_1,      // Total devices detected on Bus 1
    output reg [3:0]   dev_count_2,      // Total devices detected on Bus 2

    output reg         active_bus,       // 0 = Bus 1, 1 = Bus 2
    output reg [6:0]   active_addr,      // Currently tracked 7-bit device address
    output reg         sensor_online,    // 1 = Active sensor responding with ACK
    output reg [7:0]   sensor_dev_id,    // Read from Reg 0x03 (0x4A for VB22B)
    output reg [15:0]  distance_mm,      // Read from Reg 0x00..0x01 (0xFFFF = invalid)
    output reg [15:0]  ack_counter,      // Number of successful ACKs
    output reg [15:0]  nack_counter,     // Number of NACK errors
    output reg         meas_tick_pulse,  // 1-cycle pulse per distance measurement

    // Raw bus level indicators
    output wire        scl1_raw,
    output wire        sda1_raw,
    output wire        scl2_raw,
    output wire        sda2_raw
);

    // ---------------------------------------------------- 1 ms Base Timer ---
    localparam integer MS_DIV = CLK_HZ / 1000;
    reg [15:0] ms_cnt_div;
    reg        tick1ms;
    always @(posedge clk) begin
        if (!rst_n) begin
            ms_cnt_div <= 16'd0; tick1ms <= 1'b0;
        end else if (ms_cnt_div == MS_DIV - 1) begin
            ms_cnt_div <= 16'd0; tick1ms <= 1'b1;
        end else begin
            ms_cnt_div <= ms_cnt_div + 16'd1; tick1ms <= 1'b0;
        end
    end

    // ---------------------------------------------------- I2C Master --------
    reg        m_go;
    reg  [1:0] m_cmd;
    reg  [7:0] m_wdata;
    reg        m_ack_bit;
    wire       m_busy, m_done, m_ack_err;
    wire [7:0] m_rdata;
    wire       m_scl_oe, m_sda_oe;

    reg        bus_sel_r; // 0 = Bus 1, 1 = Bus 2
    wire       cur_sda_in = bus_sel_r ? sda_2 : sda_1;

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_master (
        .clk     (clk),
        .rst_n   (rst_n),
        .go      (m_go),
        .cmd     (m_cmd),
        .wdata   (m_wdata),
        .ack_bit (m_ack_bit),
        .sda_in  (cur_sda_in),
        .busy    (m_busy),
        .done    (m_done),
        .ack_err (m_ack_err),
        .rdata   (m_rdata),
        .scl_oe  (m_scl_oe),
        .sda_oe  (m_sda_oe)
    );

    // SCL Push-Pull (guarantees fast clock edges even without external pull-ups)
    // SDA Open-Drain (required for bidirectional I2C protocol)
    assign scl_1 = (bus_sel_r == 1'b0) ? ~m_scl_oe : 1'b1;
    assign sda_1 = (bus_sel_r == 1'b0 && m_sda_oe) ? 1'b0 : 1'bz;

    assign scl_2 = (bus_sel_r == 1'b1) ? ~m_scl_oe : 1'b1;
    assign sda_2 = (bus_sel_r == 1'b1 && m_sda_oe) ? 1'b0 : 1'bz;

    assign scl1_raw = scl_1;
    assign sda1_raw = sda_1;
    assign scl2_raw = scl_2;
    assign sda2_raw = sda_2;

    // ---------------------------------------------------- Main FSM ---------
    localparam [1:0] C_START = 2'd0, C_WRITE = 2'd1, C_READ = 2'd2, C_STOP = 2'd3;

    localparam [4:0]
        ST_POR_WAIT     = 5'd0,
        // Scanner Phase
        ST_SCAN_START   = 5'd1,
        ST_SCAN_WR_ADDR = 5'd2,
        ST_SCAN_CHK_ACK = 5'd3,
        ST_SCAN_STOP    = 5'd4,
        ST_SCAN_NEXT    = 5'd5,
        ST_SCAN_EVAL    = 5'd6,
        // Measure Phase: Read Device ID (Reg 0x03)
        ST_ID_START     = 5'd7,
        ST_ID_WR_DEV    = 5'd8,
        ST_ID_WR_REG    = 5'd9,
        ST_ID_REP_START = 5'd10,
        ST_ID_RD_DEV    = 5'd11,
        ST_ID_RD_BYTE   = 5'd12,
        ST_ID_STOP      = 5'd13,
        // Measure Phase: Read Distance (Reg 0x00 burst 2 bytes)
        ST_DIST_START   = 5'd14,
        ST_DIST_WR_DEV  = 5'd15,
        ST_DIST_WR_REG  = 5'd16,
        ST_DIST_REP_ST  = 5'd17,
        ST_DIST_RD_DEV  = 5'd18,
        ST_DIST_RD_HI   = 5'd19,
        ST_DIST_RD_LO   = 5'd20,
        ST_DIST_STOP    = 5'd21,
        ST_DIST_EVAL    = 5'd22,
        ST_INTERVAL_WAIT= 5'd23;

    reg [4:0]  state;
    reg [15:0] timer_ms;
    reg [6:0]  scan_addr;
    reg        scan_bus_idx; // 0 = Bus 1, 1 = Bus 2
    reg [7:0]  d_hi_byte, d_lo_byte;
    reg [15:0] offline_retry_cnt;
    reg        id_check_needed;
    reg        curr_op_failed;

    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= ST_POR_WAIT;
            m_go              <= 1'b0;
            m_cmd             <= C_START;
            m_wdata           <= 8'h00;
            m_ack_bit         <= 1'b0;
            bus_sel_r         <= 1'b0;
            timer_ms          <= 16'd0;
            scan_busy         <= 1'b1;
            scan_done_pulse   <= 1'b0;
            scan_bitmap_1     <= 128'd0;
            scan_bitmap_2     <= 128'd0;
            dev_count_1       <= 4'd0;
            dev_count_2       <= 4'd0;
            active_bus        <= 1'b0;
            active_addr       <= 7'h52; // Default VB22B
            sensor_online     <= 1'b0;
            sensor_dev_id     <= 8'h00;
            distance_mm       <= 16'hFFFF;
            ack_counter       <= 16'd0;
            nack_counter      <= 16'd0;
            meas_tick_pulse   <= 1'b0;
            scan_addr         <= 7'h08;
            scan_bus_idx      <= 1'b0;
            d_hi_byte         <= 8'hFF;
            d_lo_byte         <= 8'hFF;
            offline_retry_cnt <= 16'd0;
            id_check_needed   <= 1'b1;
            curr_op_failed    <= 1'b0;
        end else begin
            m_go            <= 1'b0;
            scan_done_pulse <= 1'b0;
            meas_tick_pulse <= 1'b0;

            if (tick1ms && timer_ms != 16'd0)
                timer_ms <= timer_ms - 16'd1;

            // Manual rescan trigger
            if (rescan_req && (state == ST_INTERVAL_WAIT)) begin
                state           <= ST_SCAN_START;
                scan_busy       <= 1'b1;
                scan_addr       <= 7'h08;
                scan_bus_idx    <= 1'b0;
                scan_bitmap_1   <= 128'd0;
                scan_bitmap_2   <= 128'd0;
                dev_count_1     <= 4'd0;
                dev_count_2     <= 4'd0;
                id_check_needed <= 1'b1;
            end

            case (state)
                // ----------------------------------------------------------------
                // 0. Power-On Reset Dwell (150 ms)
                // ----------------------------------------------------------------
                ST_POR_WAIT: begin
                    if (timer_ms == 16'd0) begin
                        timer_ms     <= 16'd150;
                        state        <= ST_SCAN_START;
                        scan_busy    <= 1'b1;
                        scan_addr    <= 7'h08;
                        scan_bus_idx <= 1'b0;
                    end
                end

                // ----------------------------------------------------------------
                // 1. Bus Scanner Phase (Bus 1, then Bus 2, Addr 0x08..0x77)
                // ----------------------------------------------------------------
                ST_SCAN_START: begin
                    bus_sel_r <= scan_bus_idx;
                    if (!m_busy) begin
                        m_cmd <= C_START; m_go <= 1'b1;
                        state <= ST_SCAN_WR_ADDR;
                    end
                end

                ST_SCAN_WR_ADDR: begin
                    if (m_done) begin
                        m_cmd   <= C_WRITE;
                        m_wdata <= {scan_addr, 1'b0}; // Write mode to probe ACK
                        m_go    <= 1'b1;
                        state   <= ST_SCAN_CHK_ACK;
                    end
                end

                ST_SCAN_CHK_ACK: begin
                    if (m_done) begin
                        if (!m_ack_err) begin
                            // Received ACK!
                            if (scan_bus_idx == 1'b0) begin
                                scan_bitmap_1[scan_addr] <= 1'b1;
                                dev_count_1 <= dev_count_1 + 1'b1;
                            end else begin
                                scan_bitmap_2[scan_addr] <= 1'b1;
                                dev_count_2 <= dev_count_2 + 1'b1;
                            end
                        end
                        m_cmd <= C_STOP; m_go <= 1'b1;
                        state <= ST_SCAN_STOP;
                    end
                end

                ST_SCAN_STOP: begin
                    if (m_done) state <= ST_SCAN_NEXT;
                end

                ST_SCAN_NEXT: begin
                    if (scan_addr < 7'h77) begin
                        scan_addr <= scan_addr + 1'b1;
                        state     <= ST_SCAN_START;
                    end else if (scan_bus_idx == 1'b0) begin
                        // Switch to Bus 2
                        scan_bus_idx <= 1'b1;
                        scan_addr    <= 7'h08;
                        state        <= ST_SCAN_START;
                    end else begin
                        // Scan complete for both buses!
                        scan_busy       <= 1'b0;
                        scan_done_pulse <= 1'b1;
                        state           <= ST_SCAN_EVAL;
                    end
                end

                ST_SCAN_EVAL: begin
                    if (scan_bitmap_1[7'h52]) begin
                        active_bus  <= 1'b0;
                        active_addr <= 7'h52;
                    end else if (scan_bitmap_2[7'h52]) begin
                        active_bus  <= 1'b1;
                        active_addr <= 7'h52;
                    end else if (scan_bitmap_1[7'h29]) begin
                        active_bus  <= 1'b0;
                        active_addr <= 7'h29;
                    end else if (scan_bitmap_2[7'h29]) begin
                        active_bus  <= 1'b1;
                        active_addr <= 7'h29;
                    end else if (dev_count_1 > 0) begin
                        active_bus  <= 1'b0;
                        active_addr <= 7'h52;
                    end else if (dev_count_2 > 0) begin
                        active_bus  <= 1'b1;
                        active_addr <= 7'h52;
                    end else begin
                        // Alternating probe between Bus 1 and Bus 2
                        active_bus  <= ~active_bus;
                        active_addr <= 7'h52;
                    end

                    bus_sel_r <= active_bus;
                    state     <= id_check_needed ? ST_ID_START : ST_DIST_START;
                end

                // ----------------------------------------------------------------
                // 2. Read Device ID (Reg 0x03, expect 0x4A)
                // ----------------------------------------------------------------
                ST_ID_START: begin
                    bus_sel_r <= active_bus;
                    if (!m_busy) begin
                        m_cmd <= C_START; m_go <= 1'b1;
                        state <= ST_ID_WR_DEV;
                    end
                end

                ST_ID_WR_DEV: begin
                    if (m_done) begin
                        m_cmd   <= C_WRITE;
                        m_wdata <= {active_addr, 1'b0};
                        m_go    <= 1'b1;
                        state   <= ST_ID_WR_REG;
                    end
                end

                ST_ID_WR_REG: begin
                    if (m_done) begin
                        if (m_ack_err) begin
                            m_cmd <= C_STOP; m_go <= 1'b1;
                            state <= ST_ID_STOP;
                        end else begin
                            m_cmd   <= C_WRITE;
                            m_wdata <= 8'h03; // Device ID register
                            m_go    <= 1'b1;
                            state   <= ST_ID_REP_START;
                        end
                    end
                end

                ST_ID_REP_START: begin
                    if (m_done) begin
                        m_cmd <= C_START; m_go <= 1'b1;
                        state <= ST_ID_RD_DEV;
                    end
                end

                ST_ID_RD_DEV: begin
                    if (m_done) begin
                        m_cmd   <= C_WRITE;
                        m_wdata <= {active_addr, 1'b1}; // Read mode
                        m_go    <= 1'b1;
                        state   <= ST_ID_RD_BYTE;
                    end
                end

                ST_ID_RD_BYTE: begin
                    if (m_done) begin
                        if (m_ack_err) begin
                            m_cmd <= C_STOP; m_go <= 1'b1;
                            state <= ST_ID_STOP;
                        end else begin
                            m_cmd     <= C_READ;
                            m_ack_bit <= 1'b0; // Master NACK for single byte
                            m_go      <= 1'b1;
                            state     <= ST_ID_STOP;
                        end
                    end
                end

                ST_ID_STOP: begin
                    if (m_done) begin
                        sensor_dev_id   <= m_rdata;
                        id_check_needed <= 1'b0;
                        m_cmd           <= C_STOP;
                        m_go            <= 1'b1;
                        state           <= ST_DIST_START;
                    end
                end

                // ----------------------------------------------------------------
                // 3. Continuous Distance Readout (Reg 0x00 Burst 2 bytes: High, Low)
                // ----------------------------------------------------------------
                ST_DIST_START: begin
                    bus_sel_r      <= active_bus;
                    curr_op_failed <= 1'b0;
                    if (!m_busy) begin
                        m_cmd <= C_START; m_go <= 1'b1;
                        state <= ST_DIST_WR_DEV;
                    end
                end

                ST_DIST_WR_DEV: begin
                    if (m_done) begin
                        m_cmd   <= C_WRITE;
                        m_wdata <= {active_addr, 1'b0};
                        m_go    <= 1'b1;
                        state   <= ST_DIST_WR_REG;
                    end
                end

                ST_DIST_WR_REG: begin
                    if (m_done) begin
                        if (m_ack_err) begin
                            curr_op_failed <= 1'b1;
                            m_cmd <= C_STOP; m_go <= 1'b1;
                            state <= ST_DIST_EVAL;
                        end else begin
                            m_cmd   <= C_WRITE;
                            m_wdata <= 8'h00; // Distance register base
                            m_go    <= 1'b1;
                            state   <= ST_DIST_REP_ST;
                        end
                    end
                end

                ST_DIST_REP_ST: begin
                    if (m_done) begin
                        m_cmd <= C_START; m_go <= 1'b1;
                        state <= ST_DIST_RD_DEV;
                    end
                end

                ST_DIST_RD_DEV: begin
                    if (m_done) begin
                        m_cmd   <= C_WRITE;
                        m_wdata <= {active_addr, 1'b1}; // Read mode
                        m_go    <= 1'b1;
                        state   <= ST_DIST_RD_HI;
                    end
                end

                ST_DIST_RD_HI: begin
                    if (m_done) begin
                        if (m_ack_err) begin
                            curr_op_failed <= 1'b1;
                            m_cmd <= C_STOP; m_go <= 1'b1;
                            state <= ST_DIST_EVAL;
                        end else begin
                            // Burst read byte 1 (High byte) with Master ACK (ack_bit=1)
                            m_cmd     <= C_READ;
                            m_ack_bit <= 1'b1;
                            m_go      <= 1'b1;
                            state     <= ST_DIST_RD_LO;
                        end
                    end
                end

                ST_DIST_RD_LO: begin
                    if (m_done) begin
                        d_hi_byte <= m_rdata;
                        // Burst read byte 2 (Low byte) with Master NACK (ack_bit=0)
                        m_cmd     <= C_READ;
                        m_ack_bit <= 1'b0;
                        m_go      <= 1'b1;
                        state     <= ST_DIST_STOP;
                    end
                end

                ST_DIST_STOP: begin
                    if (m_done) begin
                        d_lo_byte <= m_rdata;
                        m_cmd     <= C_STOP;
                        m_go      <= 1'b1;
                        state     <= ST_DIST_EVAL;
                    end
                end

                ST_DIST_EVAL: begin
                    if (m_done) begin
                        meas_tick_pulse <= 1'b1;
                        if (curr_op_failed) begin
                            nack_counter      <= nack_counter + 1'b1;
                            sensor_online     <= 1'b0;
                            distance_mm       <= 16'hFFFF;
                            offline_retry_cnt <= offline_retry_cnt + 1'b1;
                        end else begin
                            // Valid measurement! VB22B burst order: {d_hi_byte, d_lo_byte}
                            ack_counter       <= ack_counter + 1'b1;
                            sensor_online     <= 1'b1;
                            distance_mm       <= {d_hi_byte, d_lo_byte};
                            offline_retry_cnt <= 16'd0;
                        end
                        timer_ms <= 16'd50; // 50 ms polling interval (20 Hz)
                        state    <= ST_INTERVAL_WAIT;
                    end
                end

                ST_INTERVAL_WAIT: begin
                    if (timer_ms == 16'd0) begin
                        // If offline for >20 consecutive cycles (~1s), auto-trigger bus re-scan!
                        if (!sensor_online && (offline_retry_cnt >= 16'd20)) begin
                            offline_retry_cnt <= 16'd0;
                            state             <= ST_SCAN_START;
                            scan_busy         <= 1'b1;
                            scan_addr         <= 7'h08;
                            scan_bus_idx      <= 1'b0;
                            scan_bitmap_1     <= 128'd0;
                            scan_bitmap_2     <= 128'd0;
                            dev_count_1       <= 4'd0;
                            dev_count_2       <= 4'd0;
                            id_check_needed   <= 1'b1;
                        end else begin
                            state <= ST_DIST_START;
                        end
                    end
                end

                default: state <= ST_POR_WAIT;
            endcase
        end
    end

endmodule
`default_nettype wire
