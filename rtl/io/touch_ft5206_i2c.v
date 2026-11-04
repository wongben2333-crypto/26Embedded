// =============================================================================
//  touch_ft5206_i2c.v —— 7寸电容触摸屏通用自适应纯硬件 I2C 驱动 (Universal Capacitive Touch Engine)
//
//  支持芯片：
//    1. 敦泰 FocalTech FT5446 / FT5206 / FT5426 (I2C 地址 0x38, 8位寄存器)
//    2. 汇顶 Goodix GT911 / GT9271 / GT9147 (I2C 地址 0x14 或 0x5D, 16位寄存器)
//
//  关键特性与工业级鲁棒性 (2026-11-03 修复版)：
//    1. 严格遵循 GT911 编程手册上电复位与 INT 地址选择时序 (RST/INT 协同锁定 0x14 后释放 INT 为高阻输入)
//       以及探测成功后写入 0x8040 = 0x00 进入坐标读取模式。
//    2. 修复 GT911 0x814E 缓冲区清零时序：
//       - 完整读取 0x814E..0x8153 6 字节数据；
//       - 仅当 0x814E 最高位 buffer_status (gt_tpinfo[7]) == 1 时才向 0x814E 写入 0x00，
//         避免在 gt_tpinfo[7] == 0 扫描期间强行清零导致 GT911 扫描状态机被周期性打断。
//    3. 兼容横屏 (800x480) 与竖屏 (480x800) 固件坐标映射，绝不丢弃有效触点。
// =============================================================================
`default_nettype none

module touch_ft5206_i2c #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer SCL_HZ   = 100_000,     // 100 kHz 稳定抗噪 I2C
    parameter integer POLL_HZ  = 100          // 100 Hz (10 ms) 轮询频率
)(
    input  wire        clk,
    input  wire        rst_n,

    // I2C 物理引脚 (接 J14 / ATK-MD0700 P1)
    output wire        tp_scl,      // FPGA 推挽驱动 (Push-Pull, DRIVE=8)
    inout  wire        tp_sda,      // 双向开漏带上拉 (Open-Drain, DRIVE=8)
    inout  wire        tp_int,      // 触摸中断/复位地址选择引脚 (复位期输出，运行期高阻输入)
    output reg         tp_rst_n,    // 触摸复位输出 (低有效)

    // 解码输出
    output reg         touch_valid, // 1 周期脉冲：完成一次有效读取
    output reg         touch_down,  // 1: 屏幕正在被触摸，0: 未触摸
    output reg  [9:0]  touch_x,     // 0..799
    output reg  [8:0]  touch_y,     // 0..479
    output reg  [2:0]  touch_cnt,   // 触摸点数 (0..5)
    output reg  [1:0]  chip_type,   // 0: 扫描探测中, 1: FT5446(0x38), 2: GT911(0x14), 3: GT911(0x5D)
    output reg         dbg_ack_ok,  // 调试标志：收到有效从机 ACK
    output reg  [7:0]  dbg_tpinfo   // 调试状态：最近一次 0x814E / 0x02 状态字节
);

    // -------------------------------------------------------------------------
    // 0. 常量定义
    // -------------------------------------------------------------------------
    localparam [1:0]
        CHIP_NONE     = 2'd0,
        CHIP_FT5446   = 2'd1, // 0x38
        CHIP_GT911_14 = 2'd2, // 0x14
        CHIP_GT911_5D = 2'd3; // 0x5D

    // 50 MHz 下 GT911 严格上电复位与地址锁定 (0x14) 时序常量：
    localparam integer RST_T0_CLKS    = 500_000;            // 0..10 ms: RST=0, INT=0
    localparam integer RST_T1_CLKS    = 750_000;            // 10..15 ms: RST=0, INT=1 (>100us before RST rises -> 0x14)
    localparam integer RST_T2_CLKS    = 1_250_000;          // 15..25 ms: RST=1, INT=1 (>5ms hold after RST rises)
    localparam integer RST_T3_CLKS    = 5_000_000;          // 25..100 ms: RST=1, INT=Hi-Z (wait >55ms for GT911 boot)
    localparam integer POLL_INTERVAL  = CLK_HZ / POLL_HZ;   // 10 ms (500,000 拍)
    localparam integer SCAN_RETRY_GAP = CLK_HZ / 20;        // 50 ms 探针重试间隔

    // -------------------------------------------------------------------------
    // 1. 上电复位与 GT911 INT 地址配置时序发生器
    // -------------------------------------------------------------------------
    reg [23:0] boot_cnt  = 24'd0;
    reg        boot_done = 1'b0;
    reg        int_oe    = 1'b1;
    reg        int_out   = 1'b0;

    assign tp_int = int_oe ? int_out : 1'bz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_cnt  <= 24'd0;
            tp_rst_n  <= 1'b0;
            int_oe    <= 1'b1;
            int_out   <= 1'b0;
            boot_done <= 1'b0;
        end else if (!boot_done) begin
            if (boot_cnt < RST_T0_CLKS) begin
                tp_rst_n <= 1'b0;
                int_oe   <= 1'b1;
                int_out  <= 1'b0;
                boot_cnt <= boot_cnt + 24'd1;
            end else if (boot_cnt < RST_T1_CLKS) begin
                tp_rst_n <= 1'b0;
                int_oe   <= 1'b1;
                int_out  <= 1'b1;
                boot_cnt <= boot_cnt + 24'd1;
            end else if (boot_cnt < RST_T2_CLKS) begin
                tp_rst_n <= 1'b1;
                int_oe   <= 1'b1;
                int_out  <= 1'b1;
                boot_cnt <= boot_cnt + 24'd1;
            end else if (boot_cnt < RST_T3_CLKS) begin
                tp_rst_n <= 1'b1;
                int_oe   <= 1'b0;
                int_out  <= 1'b0;
                boot_cnt <= boot_cnt + 24'd1;
            end else begin
                tp_rst_n  <= 1'b1;
                int_oe    <= 1'b0;
                int_out   <= 1'b0;
                boot_done <= 1'b1;
                boot_cnt  <= 24'd0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. 中断去抖与轮询定时
    // -------------------------------------------------------------------------
    reg [2:0] int_sync = 3'b111;
    always @(posedge clk) int_sync <= {int_sync[1:0], tp_int};
    wire int_fall = (int_sync[2:1] == 2'b10);
    wire int_rise = (int_sync[2:1] == 2'b01);

    reg [23:0] poll_cnt = 24'd0;
    reg        trigger_poll = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            poll_cnt     <= 24'd0;
            trigger_poll <= 1'b0;
        end else if (boot_done) begin
            trigger_poll <= 1'b0;
            if (int_fall || int_rise) begin
                trigger_poll <= 1'b1;
            end else if (poll_cnt >= ((chip_type == CHIP_NONE) ? SCAN_RETRY_GAP : POLL_INTERVAL)) begin
                poll_cnt     <= 24'd0;
                trigger_poll <= 1'b1;
            end else begin
                poll_cnt <= poll_cnt + 24'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. I2C 100 kHz 时钟节拍生成 (4 相位控制，每相位 2.5 us)
    // -------------------------------------------------------------------------
    localparam integer QUARTER_CLK = CLK_HZ / (SCL_HZ * 4);
    reg [8:0] i2c_div  = 9'd0;
    reg       i2c_tick = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_div  <= 9'd0;
            i2c_tick <= 1'b0;
        end else if (i2c_div >= (QUARTER_CLK - 1)) begin
            i2c_div  <= 9'd0;
            i2c_tick <= 1'b1;
        end else begin
            i2c_div  <= i2c_div + 9'd1;
            i2c_tick <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // 4. I2C 物理引脚驱动 (SCL 推挽输出，SDA 双向开漏)
    // -------------------------------------------------------------------------
    reg scl_out = 1'b1;
    reg sda_out = 1'b1;
    reg sda_oe  = 1'b0; // 0: 高阻带上拉输入, 1: 驱动 sda_out

    assign tp_scl = scl_out;
    assign tp_sda = (sda_oe && !sda_out) ? 1'b0 : 1'bz;

    reg [1:0] sda_sync = 2'b11;
    always @(posedge clk) sda_sync <= {sda_sync[0], tp_sda};
    wire sda_in = sda_sync[1];

    // -------------------------------------------------------------------------
    // 5. 状态机定义
    // -------------------------------------------------------------------------
    localparam [5:0]
        S_IDLE            = 6'd0,
        // 探针扫描 (Probe Scan)
        S_PRB_START       = 6'd1,
        S_PRB_ADDR        = 6'd2,
        S_PRB_ACK         = 6'd3,
        S_PRB_STOP        = 6'd4,
        // FT5446 读坐标流程
        S_FT_START1       = 6'd5,
        S_FT_ADDR_W       = 6'd6,
        S_FT_ACK1         = 6'd7,
        S_FT_REG          = 6'd8,
        S_FT_ACK2         = 6'd9,
        S_FT_START2       = 6'd10,
        S_FT_ADDR_R       = 6'd11,
        S_FT_ACK3         = 6'd12,
        S_FT_RD_BYTE      = 6'd13,
        S_FT_MACK         = 6'd14,
        S_FT_STOP         = 6'd15,
        // GT911 读坐标流程 (16位寄存器: 0x814E..0x8153)
        S_GT_START1       = 6'd16,
        S_GT_ADDR_W       = 6'd17,
        S_GT_ACK1         = 6'd18,
        S_GT_REG_H        = 6'd19,
        S_GT_ACK2         = 6'd20,
        S_GT_REG_L        = 6'd21,
        S_GT_ACK3         = 6'd22,
        S_GT_START2       = 6'd23,
        S_GT_ADDR_R       = 6'd24,
        S_GT_ACK4         = 6'd25,
        S_GT_RD_BYTE      = 6'd26,
        S_GT_MACK         = 6'd27,
        S_GT_STOP1        = 6'd28,
        // GT911 写寄存器流程 (写 0x00 到 0x8040 初始化 或 写 0x00 到 0x814E 清零状态)
        S_GT_CLR_START    = 6'd29,
        S_GT_CLR_ADDR     = 6'd30,
        S_GT_CLR_ACK1     = 6'd31,
        S_GT_CLR_REG_H    = 6'd32,
        S_GT_CLR_ACK2     = 6'd33,
        S_GT_CLR_REG_L    = 6'd34,
        S_GT_CLR_ACK3     = 6'd35,
        S_GT_CLR_DATA     = 6'd36,
        S_GT_CLR_ACK4     = 6'd37,
        S_GT_CLR_STOP     = 6'd38,
        // 成功完成与异常中止
        S_DONE            = 6'd39,
        S_ABORT_STOP      = 6'd40;

    reg [5:0] state   = S_IDLE;
    reg [1:0] phase   = 2'd0;
    reg [2:0] bit_cnt = 3'd0;
    reg [2:0] byte_idx= 3'd0;
    reg [7:0] tx_data = 8'd0;
    reg [7:0] rx_data = 8'd0;

    // 探针与 GT911 软初始化状态
    reg [1:0] prb_cand     = 2'd0; // 0: 0x38, 1: 0x14, 2: 0x5D
    reg [6:0] active_addr  = 7'h38;
    reg [3:0] fail_cnt     = 4'd0;
    reg [4:0] no_ready_cnt = 5'd0;
    reg       gt_init_done = 1'b0;

    // 接收寄存器缓冲区
    reg [7:0] ft_td_status = 8'd0;
    reg [7:0] ft_xh = 8'd0;
    reg [7:0] ft_xl = 8'd0;
    reg [7:0] ft_yh = 8'd0;
    reg [7:0] ft_yl = 8'd0;

    reg [7:0] gt_tpinfo = 8'd0;
    reg [7:0] gt_xl     = 8'd0;
    reg [7:0] gt_xh     = 8'd0;
    reg [7:0] gt_yl     = 8'd0;
    reg [7:0] gt_yh     = 8'd0;

    // -------------------------------------------------------------------------
    // 6. 主控制状态机
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            phase        <= 2'd0;
            bit_cnt      <= 3'd0;
            byte_idx     <= 3'd0;
            scl_out      <= 1'b1;
            sda_out      <= 1'b1;
            sda_oe       <= 1'b0;
            touch_valid  <= 1'b0;
            touch_down   <= 1'b0;
            touch_x      <= 10'd0;
            touch_y      <= 9'd0;
            touch_cnt    <= 3'd0;
            chip_type    <= CHIP_NONE;
            dbg_ack_ok   <= 1'b0;
            dbg_tpinfo   <= 8'h00;
            prb_cand     <= 2'd0;
            active_addr  <= 7'h38;
            fail_cnt     <= 4'd0;
            no_ready_cnt <= 5'd0;
            gt_init_done <= 1'b0;
        end else if (!boot_done) begin
            state        <= S_IDLE;
            scl_out      <= 1'b1;
            sda_out      <= 1'b1;
            sda_oe       <= 1'b0;
            touch_valid  <= 1'b0;
            touch_down   <= 1'b0;
            no_ready_cnt <= 5'd0;
            gt_init_done <= 1'b0;
        end else begin
            touch_valid <= 1'b0;

            if (i2c_tick) begin
                phase <= phase + 2'd1;

                case (state)
                    // =========================================================
                    // 空闲就绪
                    // =========================================================
                    S_IDLE: begin
                        scl_out <= 1'b1;
                        sda_out <= 1'b1;
                        sda_oe  <= 1'b0;
                        phase   <= 2'd0;

                        if (trigger_poll) begin
                            if (chip_type == CHIP_NONE) begin
                                // 探针模式：尝试当前候选地址
                                state   <= S_PRB_START;
                                case (prb_cand)
                                    2'd0: tx_data <= {7'h38, 1'b0}; // FT5446
                                    2'd1: tx_data <= {7'h14, 1'b0}; // GT911 default
                                    2'd2: tx_data <= {7'h5D, 1'b0}; // GT911 alt
                                    default: tx_data <= {7'h38, 1'b0};
                                endcase
                            end else if (chip_type == CHIP_FT5446) begin
                                state   <= S_FT_START1;
                                tx_data <= {7'h38, 1'b0};
                            end else begin
                                tx_data <= {active_addr, 1'b0};
                                if (!gt_init_done)
                                    state <= S_GT_CLR_START; // 首次探测到 GT911：写 0x8040 = 0x00 进入读坐标模式
                                else
                                    state <= S_GT_START1;    // 正常轮询 0x814E..0x8153
                            end
                            bit_cnt <= 3'd7;
                        end
                    end

                    // =========================================================
                    // 探针扫描流程 (Probe Scan FSM)
                    // =========================================================
                    S_PRB_START: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end // START 产生
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd3: begin scl_out <= 1'b0; state <= S_PRB_ADDR; end
                        endcase
                    end

                    S_PRB_ADDR: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_PRB_ACK;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_PRB_ACK: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (!sda_in) begin
                                    // 探针收到从机 ACK!
                                    dbg_ack_ok   <= 1'b1;
                                    fail_cnt     <= 4'd0;
                                    gt_init_done <= 1'b0;
                                    if (prb_cand == 2'd0) begin
                                        chip_type   <= CHIP_FT5446;
                                        active_addr <= 7'h38;
                                    end else if (prb_cand == 2'd1) begin
                                        chip_type   <= CHIP_GT911_14;
                                        active_addr <= 7'h14;
                                    end else begin
                                        chip_type   <= CHIP_GT911_5D;
                                        active_addr <= 7'h5D;
                                    end
                                end else begin
                                    // NACK: 轮询下一个候选
                                    dbg_ack_ok <= 1'b0;
                                    if (prb_cand == 2'd2) prb_cand <= 2'd0;
                                    else prb_cand <= prb_cand + 2'd1;
                                end
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_PRB_STOP;
                                sda_oe  <= 1'b1;
                                sda_out <= 1'b0;
                            end
                        endcase
                    end

                    S_PRB_STOP: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b1; end // STOP
                            2'd3: begin
                                scl_out <= 1'b1;
                                sda_oe  <= 1'b0;
                                state   <= S_IDLE;
                            end
                        endcase
                    end

                    // =========================================================
                    // FT5446 / FT5206 读取流程
                    // =========================================================
                    S_FT_START1: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd3: begin scl_out <= 1'b0; state <= S_FT_ADDR_W; end
                        endcase
                    end

                    S_FT_ADDR_W: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_FT_ACK1;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_FT_ACK1: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_FT_REG;
                                    tx_data <= 8'h02; // FT 触摸状态寄存器
                                    bit_cnt <= 3'd7;
                                    sda_oe  <= 1'b1;
                                end
                            end
                        endcase
                    end

                    S_FT_REG: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_FT_ACK2;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_FT_ACK2: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_FT_START2;
                                    sda_oe  <= 1'b1;
                                    sda_out <= 1'b1;
                                end
                            end
                        endcase
                    end

                    S_FT_START2: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b0; end // RESTART
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_FT_ADDR_R;
                                tx_data <= {7'h38, 1'b1};
                                bit_cnt <= 3'd7;
                            end
                        endcase
                    end

                    S_FT_ADDR_R: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state    <= S_FT_ACK3;
                                    sda_oe   <= 1'b0;
                                    byte_idx <= 3'd0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_FT_ACK3: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_FT_RD_BYTE;
                                    bit_cnt <= 3'd7;
                                    rx_data <= 8'd0;
                                end
                            end
                        endcase
                    end

                    S_FT_RD_BYTE: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; rx_data[bit_cnt] <= sda_in; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    case (byte_idx)
                                        3'd0: ft_td_status <= {rx_data[7:1], sda_in};
                                        3'd1: ft_xh        <= {rx_data[7:1], sda_in};
                                        3'd2: ft_xl        <= {rx_data[7:1], sda_in};
                                        3'd3: ft_yh        <= {rx_data[7:1], sda_in};
                                        3'd4: ft_yl        <= {rx_data[7:1], sda_in};
                                        default: ;
                                    endcase
                                    state   <= S_FT_MACK;
                                    sda_oe  <= 1'b1;
                                    sda_out <= (byte_idx == 3'd4) ? 1'b1 : 1'b0; // 最后一字节发 NACK
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_FT_MACK: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= (byte_idx == 3'd4) ? 1'b1 : 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (byte_idx == 3'd4) begin
                                    state   <= S_FT_STOP;
                                    sda_oe  <= 1'b1;
                                    sda_out <= 1'b0;
                                end else begin
                                    byte_idx <= byte_idx + 3'd1;
                                    state    <= S_FT_RD_BYTE;
                                    bit_cnt  <= 3'd7;
                                    sda_oe   <= 1'b0;
                                end
                            end
                        endcase
                    end

                    S_FT_STOP: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b1; end // STOP
                            2'd3: begin
                                scl_out    <= 1'b1;
                                sda_oe     <= 1'b0;
                                dbg_tpinfo <= ft_td_status;
                                state      <= S_DONE;
                            end
                        endcase
                    end

                    // =========================================================
                    // GT911 读取流程 (16位寄存器: 0x814E..0x8153)
                    // =========================================================
                    S_GT_START1: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd3: begin scl_out <= 1'b0; state <= S_GT_ADDR_W; end
                        endcase
                    end

                    S_GT_ADDR_W: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_ACK1;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_ACK1: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_GT_REG_H;
                                    tx_data <= 8'h81; // 寄存器高字节
                                    bit_cnt <= 3'd7;
                                    sda_oe  <= 1'b1;
                                end
                            end
                        endcase
                    end

                    S_GT_REG_H: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_ACK2;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_ACK2: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_GT_REG_L;
                                    tx_data <= 8'h4E; // 寄存器低字节 0x814E
                                    bit_cnt <= 3'd7;
                                    sda_oe  <= 1'b1;
                                end
                            end
                        endcase
                    end

                    S_GT_REG_L: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_ACK3;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_ACK3: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_GT_START2;
                                    sda_oe  <= 1'b1;
                                    sda_out <= 1'b1;
                                end
                            end
                        endcase
                    end

                    S_GT_START2: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b0; end // RESTART
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_GT_ADDR_R;
                                tx_data <= {active_addr, 1'b1}; // 读操作
                                bit_cnt <= 3'd7;
                            end
                        endcase
                    end

                    S_GT_ADDR_R: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state    <= S_GT_ACK4;
                                    sda_oe   <= 1'b0;
                                    byte_idx <= 3'd0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_ACK4: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin
                                scl_out <= 1'b1;
                                if (sda_in) state <= S_ABORT_STOP;
                            end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (state != S_ABORT_STOP) begin
                                    state   <= S_GT_RD_BYTE;
                                    bit_cnt <= 3'd7;
                                    rx_data <= 8'd0;
                                end
                            end
                        endcase
                    end

                    S_GT_RD_BYTE: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; rx_data[bit_cnt] <= sda_in; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    case (byte_idx)
                                        3'd0: gt_tpinfo <= {rx_data[7:1], sda_in}; // 0x814E
                                        3'd1: ;                                    // 0x814F: Track ID
                                        3'd2: gt_xl     <= {rx_data[7:1], sda_in}; // 0x8150
                                        3'd3: gt_xh     <= {rx_data[7:1], sda_in}; // 0x8151
                                        3'd4: gt_yl     <= {rx_data[7:1], sda_in}; // 0x8152
                                        3'd5: gt_yh     <= {rx_data[7:1], sda_in}; // 0x8153
                                        default: ;
                                    endcase
                                    state   <= S_GT_MACK;
                                    sda_oe  <= 1'b1;
                                    sda_out <= (byte_idx == 3'd5) ? 1'b1 : 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_MACK: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= (byte_idx == 3'd5) ? 1'b1 : 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (byte_idx == 3'd5) begin
                                    state   <= S_GT_STOP1;
                                    sda_oe  <= 1'b1;
                                    sda_out <= 1'b0;
                                end else begin
                                    byte_idx <= byte_idx + 3'd1;
                                    state    <= S_GT_RD_BYTE;
                                    bit_cnt  <= 3'd7;
                                    sda_oe   <= 1'b0;
                                end
                            end
                        endcase
                    end

                    S_GT_STOP1: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b1; end
                            2'd3: begin
                                scl_out    <= 1'b1;
                                sda_oe     <= 1'b0;
                                dbg_tpinfo <= gt_tpinfo;
                                // 关键修复：仅当 gt_tpinfo[7] == 1 (Buffer Status Ready) 时才写 0x00 到 0x814E！
                                // 若 gt_tpinfo[7] == 0 时强写 0x814E，会周期性重置 GT911 扫描缓冲导致永远无法产生触点。
                                if (gt_tpinfo[7]) begin
                                    state   <= S_GT_CLR_START;
                                    tx_data <= {active_addr, 1'b0};
                                    bit_cnt <= 3'd7;
                                end else begin
                                    state   <= S_DONE;
                                end
                            end
                        endcase
                    end

                    // GT911 写寄存器 (gt_init_done=0 时写 0x8040=0x00 进入读坐标模式；gt_init_done=1 时写 0x814E=0x00 清零标志)
                    S_GT_CLR_START: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd3: begin scl_out <= 1'b0; state <= S_GT_CLR_ADDR; end
                        endcase
                    end

                    S_GT_CLR_ADDR: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_CLR_ACK1;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_CLR_ACK1: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_GT_CLR_REG_H;
                                tx_data <= gt_init_done ? 8'h81 : 8'h80;
                                bit_cnt <= 3'd7;
                                sda_oe  <= 1'b1;
                            end
                        endcase
                    end

                    S_GT_CLR_REG_H: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_CLR_ACK2;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_CLR_ACK2: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_GT_CLR_REG_L;
                                tx_data <= gt_init_done ? 8'h4E : 8'h40;
                                bit_cnt <= 3'd7;
                                sda_oe  <= 1'b1;
                            end
                        endcase
                    end

                    S_GT_CLR_REG_L: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_CLR_ACK3;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_CLR_ACK3: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_GT_CLR_DATA;
                                tx_data <= 8'h00; // 写 0x00
                                bit_cnt <= 3'd7;
                                sda_oe  <= 1'b1;
                            end
                        endcase
                    end

                    S_GT_CLR_DATA: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= tx_data[bit_cnt]; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                if (bit_cnt == 3'd0) begin
                                    state  <= S_GT_CLR_ACK4;
                                    sda_oe <= 1'b0;
                                end else begin
                                    bit_cnt <= bit_cnt - 3'd1;
                                end
                            end
                        endcase
                    end

                    S_GT_CLR_ACK4: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; end
                            2'd2: begin scl_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b0;
                                state   <= S_GT_CLR_STOP;
                                sda_oe  <= 1'b1;
                                sda_out <= 1'b0;
                            end
                        endcase
                    end

                    S_GT_CLR_STOP: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b1; end
                            2'd3: begin
                                scl_out <= 1'b1;
                                sda_oe  <= 1'b0;
                                if (!gt_init_done) begin
                                    gt_init_done <= 1'b1;
                                    state        <= S_IDLE;
                                end else begin
                                    state        <= S_DONE;
                                end
                            end
                        endcase
                    end

                    // =========================================================
                    // 事务正常完成：坐标解码与输出 (1:1 真实物理坐标 + 竖屏兼容)
                    // =========================================================
                    S_DONE: begin
                        state       <= S_IDLE;
                        touch_valid <= 1'b1;
                        fail_cnt    <= 4'd0;

                        if (chip_type == CHIP_FT5446) begin
                            // FT5446: td_status[3:0] 触点数 1..5, ft_xh[7:6] != 2'b01(抬起)
                            if ((ft_td_status[3:0] >= 4'd1) && (ft_td_status[3:0] <= 4'd5) && (ft_xh[7:6] != 2'b01)) begin
                                touch_down <= 1'b1;
                                touch_cnt  <= ft_td_status[2:0];
                                // FT5446 800x480 横屏官方映射 (DIR_90): X = raw_y, Y = raw_x
                                if ({ft_yh[3:0], ft_yl} < 12'd800 && {ft_xh[3:0], ft_xl} < 12'd480) begin
                                    touch_x <= {ft_yh[1:0], ft_yl};
                                    touch_y <= {ft_xh[0], ft_xl};
                                end else if ({ft_xh[3:0], ft_xl} < 12'd800 && {ft_yh[3:0], ft_yl} < 12'd480) begin
                                    touch_x <= {ft_xh[1:0], ft_xl};
                                    touch_y <= {ft_yh[0], ft_yl};
                                end
                            end else begin
                                touch_down <= 1'b0;
                                touch_cnt  <= 3'd0;
                            end
                        end else if (chip_type == CHIP_GT911_14 || chip_type == CHIP_GT911_5D) begin
                            // GT911: gt_tpinfo[7]=ready, gt_tpinfo[3:0]=触点 1..5
                            if (gt_tpinfo[7] && (gt_tpinfo[3:0] >= 4'd1) && (gt_tpinfo[3:0] <= 4'd5)) begin
                                no_ready_cnt <= 5'd0;
                                touch_down   <= 1'b1;
                                touch_cnt    <= gt_tpinfo[2:0];
                                // GT911 在 ATK-MD0700 横屏 (800x480):
                                if ({gt_xh, gt_xl} < 16'd800 && {gt_yh, gt_yl} < 16'd480) begin
                                    touch_x <= {gt_xh[1:0], gt_xl};
                                    touch_y <= {gt_yh[0], gt_yl};
                                end else if ({gt_xh, gt_xl} < 16'd480 && {gt_yh, gt_yl} < 16'd800) begin
                                    // 兼容 GT911 竖屏 480x800 固件配置自动旋转为 800x480 横屏坐标
                                    touch_x <= {gt_yh[1:0], gt_yl};
                                    touch_y <= 9'd479 - {gt_xh[0], gt_xl};
                                end else begin
                                    touch_x <= ({gt_xh, gt_xl} >= 16'd800) ? 10'd799 : {gt_xh[1:0], gt_xl};
                                    touch_y <= ({gt_yh, gt_yl} >= 16'd480) ? 9'd479  : {gt_yh[0], gt_yl};
                                end
                            end else if (gt_tpinfo[7] && (gt_tpinfo[3:0] == 4'd0)) begin
                                // 0x814E == 0x80: 真实松开手指事件
                                no_ready_cnt <= 5'd0;
                                touch_down   <= 1'b0;
                                touch_cnt    <= 3'd0;
                            end else begin
                                // gt_tpinfo[7] == 0: GT911 正在扫描转换中，保持当前 touch_down 状态
                                if (touch_down) begin
                                    if (no_ready_cnt >= 5'd12) begin
                                        no_ready_cnt <= 5'd0;
                                        touch_down   <= 1'b0;
                                        touch_cnt    <= 3'd0;
                                    end else begin
                                        no_ready_cnt <= no_ready_cnt + 5'd1;
                                    end
                                end
                            end
                        end
                    end

                    // =========================================================
                    // 异常处理：NACK 中止与保护重连
                    // =========================================================
                    S_ABORT_STOP: begin
                        case (phase)
                            2'd0: begin scl_out <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd1: begin scl_out <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl_out <= 1'b1; sda_out <= 1'b1; end // 产生 STOP 释放
                            2'd3: begin
                                scl_out <= 1'b1;
                                sda_oe  <= 1'b0;
                                state   <= S_IDLE;
                                // 连续 5 次通讯失败才判定断连
                                if (fail_cnt >= 4'd5) begin
                                    chip_type    <= CHIP_NONE;
                                    gt_init_done <= 1'b0;
                                    fail_cnt     <= 4'd0;
                                    touch_down   <= 1'b0;
                                    touch_cnt    <= 3'd0;
                                    no_ready_cnt <= 5'd0;
                                    touch_valid  <= 1'b1;
                                end else begin
                                    fail_cnt <= fail_cnt + 4'd1;
                                end
                            end
                        endcase
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
