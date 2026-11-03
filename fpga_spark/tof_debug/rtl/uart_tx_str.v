// =============================================================================
//  uart_tx_str.v -- Diagnostic Text Serial Transmitter (115200 8N1 on U15)
//  Formats ASCII strings for PC terminal monitoring
// =============================================================================
`default_nettype none

module uart_tx_str #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer BAUDRATE = 115200
)(
    input  wire        clk,
    input  wire        rst_n,

    // Inputs to report
    input  wire        active_bus,       // 0=Bus 1, 1=Bus 2
    input  wire [6:0]  active_addr,
    input  wire        sensor_online,
    input  wire [7:0]  sensor_dev_id,
    input  wire [15:0] distance_mm,
    input  wire [15:0] ack_counter,
    input  wire [15:0] nack_counter,
    input  wire        scl1_raw,
    input  wire        sda1_raw,
    input  wire        scl2_raw,
    input  wire        sda2_raw,
    input  wire        scan_done_pulse,
    input  wire [3:0]  dev_count_1,
    input  wire [3:0]  dev_count_2,
    input  wire [127:0] scan_bitmap_1,
    input  wire [127:0] scan_bitmap_2,

    output reg         uart_tx
);

    // Baudrate generator (50_000_000 / 115200 = 434)
    localparam integer BAUD_DIV = CLK_HZ / BAUDRATE;
    reg [11:0] baud_cnt;
    reg        baud_tick;
    always @(posedge clk) begin
        if (!rst_n) begin
            baud_cnt  <= 12'd0;
            baud_tick <= 1'b0;
        end else if (baud_cnt == BAUD_DIV - 1) begin
            baud_cnt  <= 12'd0;
            baud_tick <= 1'b1;
        end else begin
            baud_cnt  <= baud_cnt + 1'b1;
            baud_tick <= 1'b0;
        end
    end

    // 250 ms Periodic Report Trigger
    localparam integer TICK_250MS = CLK_HZ / 4;
    reg [23:0] cnt_250ms;
    reg        send_trig;
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_250ms <= 24'd0; send_trig <= 1'b0;
        end else if (cnt_250ms == TICK_250MS - 1) begin
            cnt_250ms <= 24'd0; send_trig <= 1'b1;
        end else begin
            cnt_250ms <= cnt_250ms + 1'b1; send_trig <= 1'b0;
        end
    end

    // Byte Transmitter
    reg [7:0] tx_byte;
    reg       tx_start;
    reg       tx_busy;
    reg [3:0] bit_idx;
    reg [9:0] shift_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            uart_tx   <= 1'b1;
            tx_busy   <= 1'b0;
            bit_idx   <= 4'd0;
            shift_reg <= 10'h3FF;
        end else if (tx_start && !tx_busy) begin
            shift_reg <= {1'b1, tx_byte, 1'b0};
            bit_idx   <= 4'd0;
            tx_busy   <= 1'b1;
        end else if (tx_busy && baud_tick) begin
            uart_tx   <= shift_reg[0];
            shift_reg <= {1'b1, shift_reg[9:1]};
            if (bit_idx == 4'd9) tx_busy <= 1'b0;
            else bit_idx <= bit_idx + 1'b1;
        end
    end

    // Hex to ASCII
    function [7:0] h2a;
        input [3:0] n;
        h2a = (n < 4'd10) ? ("0" + {4'd0, n}) : ("A" + {4'd0, n - 4'd10});
    endfunction

    // Buffer to sequence outgoing ASCII characters (Max 96 bytes)
    reg [7:0] str_buf [0:95];
    reg [6:0] str_len;
    reg [6:0] str_ptr;
    reg       str_sending;

    // Decimal conversion for distance_mm
    wire [13:0] d_val = (distance_mm > 16'd9999) ? 14'd9999 : distance_mm[13:0];
    wire [3:0]  d_th  = d_val / 1000;
    wire [13:0] r_th  = d_val % 1000;
    wire [3:0]  d_hu  = r_th / 100;
    wire [13:0] r_hu  = r_th % 100;
    wire [3:0]  d_te  = r_hu / 10;
    wire [3:0]  d_un  = r_hu % 10;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_start    <= 1'b0;
            tx_byte     <= 8'h00;
            str_sending <= 1'b0;
            str_len     <= 7'd0;
            str_ptr     <= 7'd0;
        end else begin
            tx_start <= 1'b0;

            if (!str_sending) begin
                if (send_trig) begin
                    str_buf[0]  <= "["; str_buf[1]  <= "T"; str_buf[2]  <= "O"; str_buf[3]  <= "F"; str_buf[4]  <= "]";
                    str_buf[5]  <= " "; str_buf[6]  <= "B"; str_buf[7]  <= "U"; str_buf[8]  <= "S"; str_buf[9]  <= "=";
                    str_buf[10] <= active_bus ? "2" : "1";
                    str_buf[11] <= " "; str_buf[12] <= "A"; str_buf[13] <= "D"; str_buf[14] <= "D"; str_buf[15] <= "R"; str_buf[16] <= "=";
                    str_buf[17] <= "0"; str_buf[18] <= "x";
                    str_buf[19] <= h2a({1'b0, active_addr[6:4]}); str_buf[20] <= h2a(active_addr[3:0]);
                    str_buf[21] <= " "; str_buf[22] <= "I"; str_buf[23] <= "D"; str_buf[24] <= "=";
                    str_buf[25] <= "0"; str_buf[26] <= "x";
                    str_buf[27] <= h2a(sensor_dev_id[7:4]); str_buf[28] <= h2a(sensor_dev_id[3:0]);
                    str_buf[29] <= " "; str_buf[30] <= "D"; str_buf[31] <= "I"; str_buf[32] <= "S"; str_buf[33] <= "T"; str_buf[34] <= "=";
                    if (sensor_online && distance_mm != 16'hFFFF) begin
                        str_buf[35] <= (d_th > 0) ? ("0" + {4'd0, d_th}) : " ";
                        str_buf[36] <= (d_th > 0 || d_hu > 0) ? ("0" + {4'd0, d_hu}) : " ";
                        str_buf[37] <= (d_th > 0 || d_hu > 0 || d_te > 0) ? ("0" + {4'd0, d_te}) : " ";
                        str_buf[38] <= "0" + {4'd0, d_un};
                    end else begin
                        str_buf[35] <= "-"; str_buf[36] <= "-"; str_buf[37] <= "-"; str_buf[38] <= "-";
                    end
                    str_buf[39] <= " "; str_buf[40] <= "m"; str_buf[41] <= "m";
                    str_buf[42] <= " "; str_buf[43] <= "A"; str_buf[44] <= "C"; str_buf[45] <= "K"; str_buf[46] <= "=";
                    str_buf[47] <= h2a(ack_counter[15:12]); str_buf[48] <= h2a(ack_counter[11:8]);
                    str_buf[49] <= h2a(ack_counter[7:4]);   str_buf[50] <= h2a(ack_counter[3:0]);
                    str_buf[51] <= " "; str_buf[52] <= "N"; str_buf[53] <= "A"; str_buf[54] <= "C"; str_buf[55] <= "K"; str_buf[56] <= "=";
                    str_buf[57] <= h2a(nack_counter[15:12]); str_buf[58] <= h2a(nack_counter[11:8]);
                    str_buf[59] <= h2a(nack_counter[7:4]);   str_buf[60] <= h2a(nack_counter[3:0]);
                    str_buf[61] <= " "; str_buf[62] <= "S"; str_buf[63] <= "1"; str_buf[64] <= "=";
                    str_buf[65] <= scl1_raw ? "1" : "0";
                    str_buf[66] <= ","; str_buf[67] <= sda1_raw ? "1" : "0";
                    str_buf[68] <= " "; str_buf[69] <= "S"; str_buf[70] <= "2"; str_buf[71] <= "=";
                    str_buf[72] <= scl2_raw ? "1" : "0";
                    str_buf[73] <= ","; str_buf[74] <= sda2_raw ? "1" : "0";
                    str_buf[75] <= " "; str_buf[76] <= "M"; str_buf[77] <= "1"; str_buf[78] <= ":";
                    str_buf[79] <= h2a(scan_bitmap_1[71:68]); str_buf[80] <= h2a(scan_bitmap_1[67:64]); // bits around 0x52 / 0x29
                    str_buf[81] <= " "; str_buf[82] <= "M"; str_buf[83] <= "2"; str_buf[84] <= ":";
                    str_buf[85] <= h2a(scan_bitmap_2[71:68]); str_buf[86] <= h2a(scan_bitmap_2[67:64]);
                    str_buf[87] <= 8'h0D; str_buf[88] <= 8'h0A; // \r\n
                    str_len     <= 7'd89;
                    str_ptr     <= 7'd0;
                    str_sending <= 1'b1;
                end
            end else begin
                // Stream out buffer
                if (!tx_busy && !tx_start) begin
                    if (str_ptr < str_len) begin
                        tx_byte  <= str_buf[str_ptr];
                        tx_start <= 1'b1;
                        str_ptr  <= str_ptr + 1'b1;
                    end else begin
                        str_sending <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
`default_nettype wire
