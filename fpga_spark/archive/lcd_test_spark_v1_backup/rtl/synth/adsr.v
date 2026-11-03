// =============================================================================
//  adsr.v —— N 路并行状态存储 + 共享算术步进 ADSR 包络发生器（电平敏感 gate）
//
//  赛题要求"ADSR 包络调控"，且【振荡器统计规则】把"包络控制"列为构成一个
//  振荡器的三个必要条件之一（独立相位累加器 + 频率调控 + 包络控制）。
//  因此 32 路每一路都保留物理独立的包络状态与电平寄存器（en_level[0:31], en_phase[0:31]）。
//  同时利用 EN_DIV=512 拍的余裕，以 scan_v = en_div_cnt[4:0] 共享单套 17-bit
//  步进加减器与比较器，在不改变任何包络斜率/响应语义的前提下节省 ~2,800 LUT。
// =============================================================================
`default_nettype none

module adsr #(
    parameter integer N_VOICES  = 32,
    parameter integer LEVEL_W   = 17,
    parameter integer EN_DIV    = 512,          // 每个速率步进占用的 clk 数
    parameter integer DIV_W     = 16,           // en_div_cnt 位宽，须 > $clog2(EN_DIV)
    parameter integer ATK_SH    = 10,           // 起音：65536>>ATK_SH 步
    parameter integer DEC_SH    = 10,           // 衰减
    parameter integer REL_SH    = 13,           // 释放
    parameter integer SUS_LEVEL = 49152         // Q16，0.75 满幅 ≈ -2.5 dB
)(
    input  wire               clk,
    input  wire               rst_n,

    // 电平敏感 gate：1 = 该声部按住，0 = 松开
    input  wire [N_VOICES-1:0] gate,

    // 遍历读端口（调用方扫 voice_rd 取电平）
    input  wire [4:0]         voice_rd,
    output wire [LEVEL_W-1:0] level_rd,
    output wire [1:0]         phase_rd
);

    localparam [1:0] P_IDLE = 2'd0, P_ATK = 2'd1, P_DEC = 2'd2, P_SUS = 2'd3;

    (* syn_ramstyle = "registers", syn_preserve = 1 *) reg [LEVEL_W-1:0] en_level [0:N_VOICES-1];
    (* syn_ramstyle = "registers", syn_preserve = 1 *) reg [1:0]         en_phase [0:N_VOICES-1];

    assign level_rd = en_level[voice_rd];
    assign phase_rd = en_phase[voice_rd];

    // ---------------------------------------------------------- 速率与步长 ----
    localparam integer ATK_INC = (1 << 16) >> ATK_SH;
    localparam integer DEC_INC = (1 << (LEVEL_W - 1)) >> DEC_SH;
    localparam integer REL_INC = (1 << (LEVEL_W - 1)) >> REL_SH;

    reg [DIV_W-1:0] en_div_cnt;
    wire            en_step = (en_div_cnt == EN_DIV[DIV_W-1:0] - 1'b1);

    always @(posedge clk) begin
        if (!rst_n)       en_div_cnt <= {DIV_W{1'b0}};
        else if (en_step) en_div_cnt <= {DIV_W{1'b0}};
        else              en_div_cnt <= en_div_cnt + 1'b1;
    end

    // -------------------------------------- 共享步进 ALU + 32 路独立状态寄存器 ----
    wire [4:0]         scan_v   = en_div_cnt[4:0];
    wire               step_now = (en_div_cnt[DIV_W-1:5] == {(DIV_W-5){1'b0}});
    wire [LEVEL_W-1:0] cur      = en_level[scan_v];
    wire [1:0]         cph      = en_phase[scan_v];
    wire               g_on     = gate[scan_v];

    // 攻击增量（防止越过满幅）
    wire [LEVEL_W-1:0] atk_sum  = cur + ATK_INC[LEVEL_W-1:0];
    wire               atk_done = (atk_sum >= 17'h1_0000);
    wire [LEVEL_W-1:0] atk_next = atk_done ? 17'h1_0000 : atk_sum;

    // 衰减增量（降到 SUS 为止）
    wire               dec_done = (cur <= SUS_LEVEL[LEVEL_W-1:0] + DEC_INC[LEVEL_W-1:0]);
    wire [LEVEL_W-1:0] dec_next = dec_done ? SUS_LEVEL[LEVEL_W-1:0] : (cur - DEC_INC[LEVEL_W-1:0]);

    // 释放增量（降到 0 为止）
    wire               rel_done = (cur <= REL_INC[LEVEL_W-1:0]);
    wire [LEVEL_W-1:0] rel_next = rel_done ? 17'd0 : (cur - REL_INC[LEVEL_W-1:0]);

    genvar g;
    generate
    for (g = 0; g < N_VOICES; g = g + 1) begin : per_voice
        always @(posedge clk) begin
            if (!rst_n) begin
                en_level[g] <= {LEVEL_W{1'b0}};
                en_phase[g] <= P_IDLE;
            end else if (scan_v == g[4:0]) begin
                // ================= 相位机 =================
                if (!g_on && (cph != P_IDLE)) begin
                    if (step_now && rel_done) en_phase[g] <= P_IDLE;
                end else if (g_on && (cph == P_IDLE)) begin
                    en_phase[g] <= P_ATK;
                end else if (g_on && step_now) begin
                    if ((cph == P_ATK) && atk_done)      en_phase[g] <= P_DEC;
                    else if ((cph == P_DEC) && dec_done) en_phase[g] <= P_SUS;
                end

                // ================= 电平 =================
                if (!g_on && (cph != P_IDLE)) begin
                    if (step_now) en_level[g] <= rel_next;
                end else if (g_on && (cph == P_IDLE)) begin
                    en_level[g] <= {LEVEL_W{1'b0}};
                end else if (g_on && step_now) begin
                    case (cph)
                        P_ATK: en_level[g] <= atk_next;
                        P_DEC: en_level[g] <= dec_next;
                        P_SUS: en_level[g] <= SUS_LEVEL[LEVEL_W-1:0];
                        default: ;
                    endcase
                end
            end
        end
    end
    endgenerate

endmodule

`default_nettype wire
