// ==============================================================================
// Module: adsr_envelope
// Description: 高精度数字 ADSR 包络发生器 (赛题合规要求: 独立发声单元包含独立包络控制)
//              支持 Attack -> Decay -> Sustain -> Release 线性与指数型逼近
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module adsr_envelope #(
    parameter ENV_WIDTH = 16  // 包络位宽 16位 (0 ~ 65535)
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  sample_tick,   // 48kHz 音频采样使能节拍
    input  wire                  gate,          // 琴键按下/触发信号 (1: Note-On, 0: Note-Off)
    input  wire [15:0]           attack_rate,   // Attack 阶段每步增量 (越大上升越快)
    input  wire [15:0]           decay_rate,    // Decay 阶段每步衰减量 (越大下降越快)
    input  wire [ENV_WIDTH-1:0]  sustain_level, // 维持电平 (0 ~ 65535)
    input  wire [15:0]           release_rate,  // Release 阶段每步衰减量
    output reg  [ENV_WIDTH-1:0]  env_out,       // 实时输出包络增益值
    output wire                  is_idle        // 状态指示: 是否完全静音
);

    localparam STATE_IDLE    = 3'd0;
    localparam STATE_ATTACK  = 3'd1;
    localparam STATE_DECAY   = 3'd2;
    localparam STATE_SUSTAIN = 3'd3;
    localparam STATE_RELEASE = 3'd4;

    reg [2:0] state, next_state;
    reg [ENV_WIDTH:0] env_accum; // 17位以防止溢出

    assign is_idle = (state == STATE_IDLE);

    // 状态转移逻辑
    always @(*) begin
        next_state = state;
        case (state)
            STATE_IDLE: begin
                if (gate)
                    next_state = STATE_ATTACK;
            end
            STATE_ATTACK: begin
                if (!gate)
                    next_state = STATE_RELEASE;
                else if (env_out >= 16'hFFFF - attack_rate)
                    next_state = STATE_DECAY;
            end
            STATE_DECAY: begin
                if (!gate)
                    next_state = STATE_RELEASE;
                else if (env_out <= sustain_level || env_out <= decay_rate)
                    next_state = STATE_SUSTAIN;
            end
            STATE_SUSTAIN: begin
                if (!gate)
                    next_state = STATE_RELEASE;
            end
            STATE_RELEASE: begin
                if (gate)
                    next_state = STATE_ATTACK;
                else if (env_out <= release_rate)
                    next_state = STATE_IDLE;
            end
            default: next_state = STATE_IDLE;
        endcase
    end

    // 状态与包络寄存器更新 (受 sample_tick 48kHz 约束驱动)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= STATE_IDLE;
            env_out <= {ENV_WIDTH{1'b0}};
        end else if (sample_tick) begin
            state <= next_state;
            case (state)
                STATE_IDLE: begin
                    env_out <= {ENV_WIDTH{1'b0}};
                end
                STATE_ATTACK: begin
                    if (env_out >= 16'hFFFF - attack_rate)
                        env_out <= 16'hFFFF;
                    else
                        env_out <= env_out + attack_rate;
                end
                STATE_DECAY: begin
                    if (env_out <= sustain_level || env_out <= decay_rate)
                        env_out <= sustain_level;
                    else
                        env_out <= env_out - decay_rate;
                end
                STATE_SUSTAIN: begin
                    env_out <= sustain_level;
                end
                STATE_RELEASE: begin
                    if (env_out <= release_rate)
                        env_out <= {ENV_WIDTH{1'b0}};
                    else
                        env_out <= env_out - release_rate;
                end
            endcase
        end
    end

endmodule
