// ==============================================================================
// Module: i2s_transmitter
// Description: 标准 Philips I2S 数字音频发送控制器
//              输出标准 I2S 时序至外置 DAC (如 PCM5102A / MAX98357A)
//              采样率 48kHz, 左右双声道, 16/24-bit 传输
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module i2s_transmitter #(
    parameter CLK_FREQ = 50_000_000,
    parameter FS       = 48_000
)(
    input  wire        clk,            // 主时钟 50MHz
    input  wire        rst_n,          // 异步复位 (低有效)
    
    // 并行音频样本输入
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    input  wire               sample_tick,
    
    // I2S 物理接口
    output reg         i2s_mclk,       // 主时钟 MCLK (12.288MHz 或 ~12.5MHz)
    output reg         i2s_bclk,       // 位时钟 BCLK (64 * 48kHz = 3.072MHz)
    output reg         i2s_lrck,       // 声道选择时钟 LRCK (48kHz, 0=左, 1=右)
    output reg         i2s_sdata       // 串行音频数据
);

    // 50MHz 下分频产生 BCLK (3.072MHz ≈ 50MHz / 16.276)
    // 使用 16 分频: 50MHz / 16 = 3.125MHz (极为接近标准 3.072MHz, DAC 自适应锁相环完全兼容)
    reg [3:0] bclk_div;
    wire bclk_pulse = (bclk_div == 4'd15);
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_div <= 4'd0;
            i2s_bclk <= 1'b0;
        end else begin
            bclk_div <= bclk_div + 1'b1;
            if (bclk_div == 4'd7)
                i2s_bclk <= 1'b1;
            else if (bclk_div == 4'd15)
                i2s_bclk <= 1'b0;
        end
    end

    // MCLK: 50MHz 2分频 = 25MHz 或 4分频 = 12.5MHz (常用 256*Fs)
    reg [1:0] mclk_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mclk_div <= 2'd0;
            i2s_mclk <= 1'b0;
        end else begin
            mclk_div <= mclk_div + 1'b1;
            i2s_mclk <= mclk_div[1];
        end
    end

    // I2S 移位状态机 (每个采样周期包含 64 个 BCLK: 左声道 32 BCLK + 右声道 32 BCLK)
    reg [5:0] bit_cnt;
    reg [31:0] shift_reg_l;
    reg [31:0] shift_reg_r;

    always @(negedge i2s_bclk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt     <= 6'd0;
            i2s_lrck    <= 1'b1;
            i2s_sdata   <= 1'b0;
            shift_reg_l <= 32'd0;
            shift_reg_r <= 32'd0;
        end else begin
            bit_cnt <= bit_cnt + 1'b1;
            
            // 在第 63 拍末尾装载下一个周期的左右样本
            if (bit_cnt == 6'd63) begin
                // 标准 I2S: 延迟 1 个 BCLK 输出 MSB
                shift_reg_l <= {sample_left, 16'd0};
                shift_reg_r <= {sample_right, 16'd0};
                i2s_lrck    <= 1'b0; // 切换到左声道
            end else if (bit_cnt == 6'd31) begin
                i2s_lrck    <= 1'b1; // 切换到右声道
            end

            // 串行移位输出
            if (bit_cnt < 6'd32) begin
                i2s_sdata   <= shift_reg_l[31];
                shift_reg_l <= {shift_reg_l[30:0], 1'b0};
            end else begin
                i2s_sdata   <= shift_reg_r[31];
                shift_reg_r <= {shift_reg_r[30:0], 1'b0};
            end
        end
    end

endmodule
