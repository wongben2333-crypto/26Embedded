// =============================================================================
//  i2c_master.v -- minimal open-drain / push-pull I2C master (byte level)
//
//  Commands per `go` pulse:
//      0 = C_START    1 = C_WRITE byte (wdata)    2 = C_READ byte    3 = C_STOP
//  ack_bit selects the master ACK for a READ (1 = ACK, 0 = NACK).
//
//  scl_oe / sda_oe are "drive low" enables:
//      SCL can be push-pull (assign scl = ~scl_oe) to ensure sharp clock edges
//      SDA must be open-drain (assign sda = sda_oe ? 1'b0 : 1'bz)
// =============================================================================
`default_nettype none

module i2c_master #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 10_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       go,
    input  wire [1:0] cmd,
    input  wire [7:0] wdata,
    input  wire       ack_bit,
    input  wire       sda_in,
    output reg        busy,
    output reg        done,
    output reg        ack_err,     // 1 = slave NACKed a WRITE
    output reg  [7:0] rdata,
    output reg        scl_oe,
    output reg        sda_oe
);

    localparam integer DIV = CLK_HZ / (SCL_HZ * 4);

    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_WR = 3'd2, S_WR_ACK = 3'd3,
                     S_RD   = 3'd4, S_RD_ACK = 3'd5, S_STOP = 3'd6, S_END = 3'd7;

    localparam [1:0] C_START = 2'd0, C_WRITE = 2'd1, C_READ = 2'd2, C_STOP = 2'd3;

    reg [15:0] div;
    reg        tick;
    always @(posedge clk) begin
        if (!rst_n || !busy) begin
            div  <= 16'd0;
            tick <= 1'b0;
        end else if (div == DIV - 1) begin
            div  <= 16'd0;
            tick <= 1'b1;
        end else begin
            div  <= div + 16'd1;
            tick <= 1'b0;
        end
    end

    reg [2:0] st;
    reg [1:0] q;
    reg [3:0] bitn;
    reg [7:0] sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            q       <= 2'd0;
            bitn    <= 4'd0;
            sh      <= 8'd0;
            busy    <= 1'b0;
            done    <= 1'b0;
            ack_err <= 1'b0;
            rdata   <= 8'd0;
            scl_oe  <= 1'b0;
            sda_oe  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (st)
                // ------------------------------------------------------- idle
                S_IDLE: begin
                    if (go) begin
                        busy    <= 1'b1;
                        q       <= 2'd0;
                        bitn    <= 4'd0;
                        ack_err <= 1'b0;
                        sh      <= wdata;
                        case (cmd)
                            C_START: st <= S_START;
                            C_WRITE: st <= S_WR;
                            C_READ:  st <= S_RD;
                            default: st <= S_STOP;
                        endcase
                    end
                end

                // ------------------------------------------------------ start
                S_START: if (tick) begin
                    case (q)
                        2'd0: begin scl_oe <= 1'b0; sda_oe <= 1'b0; end // SCL=1, SDA=1
                        2'd1: begin sda_oe <= 1'b1; end                  // SDA=0 (START condition)
                        2'd2: begin scl_oe <= 1'b1; end                  // SCL=0
                        2'd3: begin st <= S_END; end
                    endcase
                    q <= q + 2'd1;
                end

                // ------------------------------------------------------ write
                S_WR: if (tick) begin
                    case (q)
                        2'd0: begin scl_oe <= 1'b1; sda_oe <= ~sh[7]; end
                        2'd1: begin scl_oe <= 1'b0; end
                        2'd2: begin end
                        2'd3: begin
                            scl_oe <= 1'b1;
                            sh     <= {sh[6:0], 1'b0};
                            if (bitn == 4'd7) begin
                                bitn <= 4'd0;
                                st   <= S_WR_ACK;
                            end else begin
                                bitn <= bitn + 4'd1;
                            end
                        end
                    endcase
                    q <= q + 2'd1;
                end

                // --------------------------------------------------- write ack
                S_WR_ACK: if (tick) begin
                    case (q)
                        2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end // Release SDA for slave ACK
                        2'd1: begin scl_oe <= 1'b0; end                  // SCL=1, sample ACK
                        2'd2: begin ack_err <= sda_in; end               // 0 = ACK, 1 = NACK
                        2'd3: begin scl_oe <= 1'b1; st <= S_END; end
                    endcase
                    q <= q + 2'd1;
                end

                // ------------------------------------------------------- read
                S_RD: if (tick) begin
                    case (q)
                        2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b0; end // Release SDA for slave data
                        2'd1: begin scl_oe <= 1'b0; end                  // SCL=1, sample data bit
                        2'd2: begin sh <= {sh[6:0], sda_in}; end
                        2'd3: begin
                            scl_oe <= 1'b1;
                            if (bitn == 4'd7) begin
                                bitn  <= 4'd0;
                                rdata <= sh;
                                st    <= S_RD_ACK;
                            end else begin
                                bitn <= bitn + 4'd1;
                            end
                        end
                    endcase
                    q <= q + 2'd1;
                end

                // ---------------------------------------------------- read ack
                // ack_bit = 1 -> master ACKs (pull SDA low)
                // ack_bit = 0 -> master NACKs (release SDA)
                S_RD_ACK: if (tick) begin
                    case (q)
                        2'd0: begin scl_oe <= 1'b1; sda_oe <= ack_bit; end
                        2'd1: begin scl_oe <= 1'b0; end
                        2'd2: begin end
                        2'd3: begin scl_oe <= 1'b1; sda_oe <= 1'b0; st <= S_END; end
                    endcase
                    q <= q + 2'd1;
                end

                // ------------------------------------------------------- stop
                S_STOP: if (tick) begin
                    case (q)
                        2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end // SCL=0, SDA=0
                        2'd1: begin scl_oe <= 1'b0; end                  // SCL=1
                        2'd2: begin sda_oe <= 1'b0; end                  // SDA=1 (STOP condition)
                        2'd3: begin st <= S_END; end
                    endcase
                    q <= q + 2'd1;
                end

                // -------------------------------------------------------- end
                S_END: begin
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    st     <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
