// =============================================================================
//  tof_debug_top.v -- Tang Mega 138K ToF Distance Sensor Debug Project
//
//  Target FPGA: Arora V GW5AST-LV138PG484AC1/I0 (GW5AST-138C, Dev C)
//  Clock: 50 MHz on V22
//  Outputs:
//    1. 7-inch 800x480 LCD (ATK-MD0700 via J14 8080 16-bit bus)
//    2. UART Serial Telemetry (115200 8N1 on U15 -> PC COM8)
//    3. 4x Board Diagnostic LEDs (T18, R18, R17, P16, active low)
//  Inputs:
//    1. Dual-Bus ToF I2C Ports:
//       - Bus 1: J13-24 (A18 SCL1), J13-25 (D15 SDA1)
//       - Bus 2: J13-29 (F14 SCL2), J13-30 (F13 SDA2)
//    2. Key0 (AB13): Manual trigger to re-scan full I2C bus (0x08..0x77)
// =============================================================================
`default_nettype none

module tof_debug_top (
    input  wire        clk,        // V22: 50 MHz Oscillator
    input  wire        key0,       // AB13: Rescan Bus button (active low)
    input  wire        key1,       // Y12: Reserved button (active low)

    // Board Status LEDs (Active Low: 0 = Lit)
    output wire [3:0]  led,        // T18, R18, R17, P16

    // Serial Diagnostics
    output wire        uart_tx,    // U15: FT2232H Channel B UART TX (115200)
    input  wire        uart_rx,    // V14: FT2232H Channel B UART RX

    // ToF Bus 1 (J13-24 / J13-25)
    inout  wire        scl_tof_1,  // A18
    inout  wire        sda_tof_1,  // D15

    // ToF Bus 2 (J13-29 / J13-30)
    inout  wire        scl_tof_2,  // F14
    inout  wire        sda_tof_2,  // F13

    // 7-inch 800x480 LCD 8080 Bus (J14)
    output wire        lcd_cs,     // AB21
    output wire        lcd_rs,     // R14
    output wire        lcd_wr,     // AB20
    output wire        lcd_rd,     // AB18
    output wire        lcd_rst,    // Y18
    inout  wire [15:0] lcd_db,     // V20, U20, Y22, AA20, N15, U17, P14, P15, N13, N14, AA21, P17, W21, W22, V17, AB22
    output wire        lcd_dpi_bl  // P20
);

    // ---------------------------------------------------- Power-On Reset ---
    reg [21:0] por_cnt = 22'd0;
    wire       rst_n = por_cnt[21]; // ~83 ms clean reset release
    always @(posedge clk) begin
        if (!rst_n) por_cnt <= por_cnt + 1'b1;
    end

    // ---------------------------------------------------- Key0 Debounce ----
    reg k0_s1, k0_s2, k0_prev;
    reg rescan_pulse;
    always @(posedge clk) begin
        if (!rst_n) begin
            k0_s1 <= 1'b1; k0_s2 <= 1'b1; k0_prev <= 1'b1; rescan_pulse <= 1'b0;
        end else begin
            k0_s1        <= key0;
            k0_s2        <= k0_s1;
            k0_prev      <= k0_s2;
            rescan_pulse <= (~k0_s2 & k0_prev); // Falling edge of Key0
        end
    end

    // ---------------------------------------------------- ToF Scanner & Mgr-
    wire         scan_busy;
    wire         scan_done_pulse;
    wire [127:0] scan_bitmap_1;
    wire [127:0] scan_bitmap_2;
    wire [3:0]   dev_count_1;
    wire [3:0]   dev_count_2;
    wire         active_bus;
    wire [6:0]   active_addr;
    wire         sensor_online;
    wire [7:0]   sensor_dev_id;
    wire [15:0]  distance_mm;
    wire [15:0]  ack_counter;
    wire [15:0]  nack_counter;
    wire         meas_tick_pulse;
    wire         scl1_raw, sda1_raw, scl2_raw, sda2_raw;

    tof_scan_mgr #(
        .CLK_HZ (50_000_000),
        .SCL_HZ (10_000)      // 10 kHz stable rate
    ) u_tof_mgr (
        .clk             (clk),
        .rst_n           (rst_n),
        .rescan_req      (rescan_pulse),
        .scl_1           (scl_tof_1),
        .sda_1           (sda_tof_1),
        .scl_2           (scl_tof_2),
        .sda_2           (sda_tof_2),
        .scan_busy       (scan_busy),
        .scan_done_pulse (scan_done_pulse),
        .scan_bitmap_1   (scan_bitmap_1),
        .scan_bitmap_2   (scan_bitmap_2),
        .dev_count_1     (dev_count_1),
        .dev_count_2     (dev_count_2),
        .active_bus      (active_bus),
        .active_addr     (active_addr),
        .sensor_online   (sensor_online),
        .sensor_dev_id   (sensor_dev_id),
        .distance_mm     (distance_mm),
        .ack_counter     (ack_counter),
        .nack_counter    (nack_counter),
        .meas_tick_pulse (meas_tick_pulse),
        .scl1_raw        (scl1_raw),
        .sda1_raw        (sda1_raw),
        .scl2_raw        (scl2_raw),
        .sda2_raw        (sda2_raw)
    );

    // ---------------------------------------------------- 7-inch LCD Engine-
    lcd_direct_ui u_lcd (
        .clk             (clk),
        .rst_n           (rst_n),
        .active_bus      (active_bus),
        .active_addr     (active_addr),
        .sensor_online   (sensor_online),
        .sensor_dev_id   (sensor_dev_id),
        .distance_mm     (distance_mm),
        .ack_counter     (ack_counter),
        .nack_counter    (nack_counter),
        .scan_bitmap_1   (scan_bitmap_1),
        .scan_bitmap_2   (scan_bitmap_2),
        .scl1_raw        (scl1_raw),
        .sda1_raw        (sda1_raw),
        .scl2_raw        (scl2_raw),
        .sda2_raw        (sda2_raw),
        .scan_busy       (scan_busy),
        .lcd_cs          (lcd_cs),
        .lcd_rs          (lcd_rs),
        .lcd_wr          (lcd_wr),
        .lcd_rd          (lcd_rd),
        .lcd_rst         (lcd_rst),
        .lcd_db          (lcd_db),
        .lcd_dpi_bl      (lcd_dpi_bl)
    );

    // ---------------------------------------------------- UART Serial Output
    uart_tx_str #(
        .CLK_HZ   (50_000_000),
        .BAUDRATE (115200)
    ) u_uart (
        .clk             (clk),
        .rst_n           (rst_n),
        .active_bus      (active_bus),
        .active_addr     (active_addr),
        .sensor_online   (sensor_online),
        .sensor_dev_id   (sensor_dev_id),
        .distance_mm     (distance_mm),
        .ack_counter     (ack_counter),
        .nack_counter    (nack_counter),
        .scl1_raw        (scl1_raw),
        .sda1_raw        (sda1_raw),
        .scl2_raw        (scl2_raw),
        .sda2_raw        (sda2_raw),
        .scan_done_pulse (scan_done_pulse),
        .dev_count_1     (dev_count_1),
        .dev_count_2     (dev_count_2),
        .scan_bitmap_1   (scan_bitmap_1),
        .scan_bitmap_2   (scan_bitmap_2),
        .uart_tx         (uart_tx)
    );

    // ---------------------------------------------------- LED Diagnostics --
    // LED[0] (T18): 1 Hz Heartbeat
    reg [24:0] heart_cnt = 25'd0;
    always @(posedge clk) heart_cnt <= heart_cnt + 1'b1;

    // LED[1] (R18): Activity toggle per I2C measurement
    reg i2c_act_led = 1'b0;
    always @(posedge clk) begin
        if (meas_tick_pulse) i2c_act_led <= ~i2c_act_led;
    end

    // LED[2] (R17): ACK success (Lit if sensor online)
    // LED[3] (P16): Valid distance in 100..800 mm range
    wire dist_in_range = sensor_online && (distance_mm >= 16'd100 && distance_mm <= 16'd800);

    // LEDs are active low (0 = Lit)
    assign led[0] = heart_cnt[24];        // 1 Hz blink
    assign led[1] = ~i2c_act_led;         // Activity flash
    assign led[2] = ~sensor_online;       // Lit when online
    assign led[3] = ~dist_in_range;       // Lit when hand is in 10-80cm range

endmodule
`default_nettype wire
