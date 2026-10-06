// =============================================================================
//  piano_rom.v —— 钢琴音色引擎常量表（由 tools/gen/gen_piano_rom.py 生成）
//
//  ⚠️ 本文件由脚本生成，请勿手工编辑。改参数请改 tools/gen/gen_piano_rom.py。
//
//  采样率 fs = 97656.2 Hz（= 50 MHz / 512，BCK_DIV=1）。改 BCK_DIV 必须重跑本脚本。
//
//  本文件含 4 个模块：
//    piano_sin_rom      8 bit 相位 → 16 bit 正弦（象限折叠，仅存 65 项 1/4 波表）
//    piano_note_lut     音符 → 基频相位增量(32 bit Q32) + 齐奏拍频增量
//    piano_vel_lut      力度 → Q16 增益 + 琴槌噪声低通档位
//    piano_partial_lut  泛音序号 → 幅度/明亮度/衰减移位/非谐性拉伸移位
//
//  ★ 不用 $readmemh 读外部文件：参考实现 26Embedded/fpga_spark 的 piano_voice.v
//    用 $readmemh("wavetable_sine.hex")，文件不在工作目录时 ROM 全 0（完全静音），
//    极难排查。本工程一律 case 常量表（与 wave_rom.v 一致）。
//
//  ★ 16 bit 有符号常数一律写成 -16'sdNNN；写 16'sd-NNN 在 Verilog 里是非法字面量
//    （本项目实测报过 508 个 Expecting numeric digits）。
// =============================================================================
`default_nettype none

// -----------------------------------------------------------------------------
//  piano_sin_rom —— 1/4 波表 + 象限折叠
//    phase[7:6] = 象限，phase[5:0] = 象限内位置
//    idx = phase[6] ? (64 - pos) : pos   （0..64，含 90° 端点）
//    neg = phase[7]
//  只存 65 项，面积约为 256 项全表的 1/4。
// -----------------------------------------------------------------------------
module piano_sin_rom (
    input  wire               clk,
    input  wire [7:0]         phase,     // 一个整周期 = 256 步
    output reg  signed [15:0] data
);

    wire [6:0] pos = {1'b0, phase[5:0]};
    wire [6:0] idx = phase[6] ? (7'd64 - pos) : pos;
    wire       neg = phase[7];

    reg signed [15:0] q;

    always @(*) begin
        case (idx)
            7'd0: q = 16'sd0;
            7'd1: q = 16'sd804;
            7'd2: q = 16'sd1608;
            7'd3: q = 16'sd2410;
            7'd4: q = 16'sd3212;
            7'd5: q = 16'sd4011;
            7'd6: q = 16'sd4808;
            7'd7: q = 16'sd5602;
            7'd8: q = 16'sd6393;
            7'd9: q = 16'sd7179;
            7'd10: q = 16'sd7962;
            7'd11: q = 16'sd8739;
            7'd12: q = 16'sd9512;
            7'd13: q = 16'sd10278;
            7'd14: q = 16'sd11039;
            7'd15: q = 16'sd11793;
            7'd16: q = 16'sd12539;
            7'd17: q = 16'sd13279;
            7'd18: q = 16'sd14010;
            7'd19: q = 16'sd14732;
            7'd20: q = 16'sd15446;
            7'd21: q = 16'sd16151;
            7'd22: q = 16'sd16846;
            7'd23: q = 16'sd17530;
            7'd24: q = 16'sd18204;
            7'd25: q = 16'sd18868;
            7'd26: q = 16'sd19519;
            7'd27: q = 16'sd20159;
            7'd28: q = 16'sd20787;
            7'd29: q = 16'sd21403;
            7'd30: q = 16'sd22005;
            7'd31: q = 16'sd22594;
            7'd32: q = 16'sd23170;
            7'd33: q = 16'sd23731;
            7'd34: q = 16'sd24279;
            7'd35: q = 16'sd24811;
            7'd36: q = 16'sd25329;
            7'd37: q = 16'sd25832;
            7'd38: q = 16'sd26319;
            7'd39: q = 16'sd26790;
            7'd40: q = 16'sd27245;
            7'd41: q = 16'sd27683;
            7'd42: q = 16'sd28105;
            7'd43: q = 16'sd28510;
            7'd44: q = 16'sd28898;
            7'd45: q = 16'sd29268;
            7'd46: q = 16'sd29621;
            7'd47: q = 16'sd29956;
            7'd48: q = 16'sd30273;
            7'd49: q = 16'sd30571;
            7'd50: q = 16'sd30852;
            7'd51: q = 16'sd31113;
            7'd52: q = 16'sd31356;
            7'd53: q = 16'sd31580;
            7'd54: q = 16'sd31785;
            7'd55: q = 16'sd31971;
            7'd56: q = 16'sd32137;
            7'd57: q = 16'sd32285;
            7'd58: q = 16'sd32412;
            7'd59: q = 16'sd32521;
            7'd60: q = 16'sd32609;
            7'd61: q = 16'sd32678;
            7'd62: q = 16'sd32728;
            7'd63: q = 16'sd32757;
            7'd64: q = 16'sd32767;
            default: q = 16'sd0;
        endcase
    end

    always @(posedge clk)
        data <= neg ? (-q) : q;

endmodule

// -----------------------------------------------------------------------------
//  piano_note_lut —— MIDI 音符 → 频率
//    f0_step  : 等程律 f = 440 × 2^((n-69)/12)，相位增量 = round(f × 2^32 / fs)
//    beat_step: 同音多弦的失谐拍频（Hz → 相位增量）
//               取自 Faust STK piano1.dsp 的 detuningHz 表：
//               低音 0.003 Hz → 中音 0.25 Hz → 高音 1.0 Hz
//               ⚠️ 是【零点几 Hz 的拍频】，不是固定 0.1%% 的频率偏移
//  组合逻辑（只在 note-on 那一拍被读），无寄存器。
// -----------------------------------------------------------------------------
module piano_note_lut (
    input  wire [6:0]  note,
    output reg  [31:0] f0_step,
    output reg  [31:0] beat_step
);

    always @(*) begin
        case (note)
            7'd0: begin f0_step = 32'd359575; beat_step = 32'd132; end // 8.18 Hz, beat 0.0030 Hz
            7'd1: begin f0_step = 32'd380957; beat_step = 32'd132; end // 8.66 Hz, beat 0.0030 Hz
            7'd2: begin f0_step = 32'd403610; beat_step = 32'd132; end // 9.18 Hz, beat 0.0030 Hz
            7'd3: begin f0_step = 32'd427610; beat_step = 32'd132; end // 9.72 Hz, beat 0.0030 Hz
            7'd4: begin f0_step = 32'd453037; beat_step = 32'd132; end // 10.30 Hz, beat 0.0030 Hz
            7'd5: begin f0_step = 32'd479976; beat_step = 32'd132; end // 10.91 Hz, beat 0.0030 Hz
            7'd6: begin f0_step = 32'd508516; beat_step = 32'd132; end // 11.56 Hz, beat 0.0030 Hz
            7'd7: begin f0_step = 32'd538754; beat_step = 32'd132; end // 12.25 Hz, beat 0.0030 Hz
            7'd8: begin f0_step = 32'd570790; beat_step = 32'd132; end // 12.98 Hz, beat 0.0030 Hz
            7'd9: begin f0_step = 32'd604731; beat_step = 32'd132; end // 13.75 Hz, beat 0.0030 Hz
            7'd10: begin f0_step = 32'd640691; beat_step = 32'd132; end // 14.57 Hz, beat 0.0030 Hz
            7'd11: begin f0_step = 32'd678788; beat_step = 32'd132; end // 15.43 Hz, beat 0.0030 Hz
            7'd12: begin f0_step = 32'd719151; beat_step = 32'd132; end // 16.35 Hz, beat 0.0030 Hz
            7'd13: begin f0_step = 32'd761914; beat_step = 32'd132; end // 17.32 Hz, beat 0.0030 Hz
            7'd14: begin f0_step = 32'd807220; beat_step = 32'd132; end // 18.35 Hz, beat 0.0030 Hz
            7'd15: begin f0_step = 32'd855219; beat_step = 32'd132; end // 19.45 Hz, beat 0.0030 Hz
            7'd16: begin f0_step = 32'd906073; beat_step = 32'd132; end // 20.60 Hz, beat 0.0030 Hz
            7'd17: begin f0_step = 32'd959951; beat_step = 32'd132; end // 21.83 Hz, beat 0.0030 Hz
            7'd18: begin f0_step = 32'd1017033; beat_step = 32'd132; end // 23.12 Hz, beat 0.0030 Hz
            7'd19: begin f0_step = 32'd1077509; beat_step = 32'd132; end // 24.50 Hz, beat 0.0030 Hz
            7'd20: begin f0_step = 32'd1141581; beat_step = 32'd132; end // 25.96 Hz, beat 0.0030 Hz
            7'd21: begin f0_step = 32'd1209463; beat_step = 32'd132; end // 27.50 Hz, beat 0.0030 Hz
            7'd22: begin f0_step = 32'd1281381; beat_step = 32'd132; end // 29.14 Hz, beat 0.0030 Hz
            7'd23: begin f0_step = 32'd1357576; beat_step = 32'd132; end // 30.87 Hz, beat 0.0030 Hz
            7'd24: begin f0_step = 32'd1438302; beat_step = 32'd132; end // 32.70 Hz, beat 0.0030 Hz
            7'd25: begin f0_step = 32'd1523828; beat_step = 32'd132; end // 34.65 Hz, beat 0.0030 Hz
            7'd26: begin f0_step = 32'd1614439; beat_step = 32'd132; end // 36.71 Hz, beat 0.0030 Hz
            7'd27: begin f0_step = 32'd1710439; beat_step = 32'd132; end // 38.89 Hz, beat 0.0030 Hz
            7'd28: begin f0_step = 32'd1812147; beat_step = 32'd132; end // 41.20 Hz, beat 0.0030 Hz
            7'd29: begin f0_step = 32'd1919903; beat_step = 32'd2639; end // 43.65 Hz, beat 0.0600 Hz
            7'd30: begin f0_step = 32'd2034066; beat_step = 32'd3518; end // 46.25 Hz, beat 0.0800 Hz
            7'd31: begin f0_step = 32'd2155018; beat_step = 32'd4398; end // 49.00 Hz, beat 0.1000 Hz
            7'd32: begin f0_step = 32'd2283162; beat_step = 32'd4486; end // 51.91 Hz, beat 0.1020 Hz
            7'd33: begin f0_step = 32'd2418926; beat_step = 32'd4574; end // 55.00 Hz, beat 0.1040 Hz
            7'd34: begin f0_step = 32'd2562762; beat_step = 32'd4662; end // 58.27 Hz, beat 0.1060 Hz
            7'd35: begin f0_step = 32'd2715152; beat_step = 32'd4750; end // 61.74 Hz, beat 0.1080 Hz
            7'd36: begin f0_step = 32'd2876604; beat_step = 32'd4838; end // 65.41 Hz, beat 0.1100 Hz
            7'd37: begin f0_step = 32'd3047655; beat_step = 32'd4911; end // 69.30 Hz, beat 0.1117 Hz
            7'd38: begin f0_step = 32'd3228878; beat_step = 32'd4984; end // 73.42 Hz, beat 0.1133 Hz
            7'd39: begin f0_step = 32'd3420877; beat_step = 32'd5058; end // 77.78 Hz, beat 0.1150 Hz
            7'd40: begin f0_step = 32'd3624293; beat_step = 32'd5131; end // 82.41 Hz, beat 0.1167 Hz
            7'd41: begin f0_step = 32'd3839805; beat_step = 32'd5204; end // 87.31 Hz, beat 0.1183 Hz
            7'd42: begin f0_step = 32'd4068132; beat_step = 32'd5278; end // 92.50 Hz, beat 0.1200 Hz
            7'd43: begin f0_step = 32'd4310035; beat_step = 32'd5864; end // 98.00 Hz, beat 0.1333 Hz
            7'd44: begin f0_step = 32'd4566323; beat_step = 32'd6450; end // 103.83 Hz, beat 0.1467 Hz
            7'd45: begin f0_step = 32'd4837851; beat_step = 32'd7037; end // 110.00 Hz, beat 0.1600 Hz
            7'd46: begin f0_step = 32'd5125525; beat_step = 32'd7623; end // 116.54 Hz, beat 0.1733 Hz
            7'd47: begin f0_step = 32'd5430304; beat_step = 32'd8210; end // 123.47 Hz, beat 0.1867 Hz
            7'd48: begin f0_step = 32'd5753207; beat_step = 32'd8796; end // 130.81 Hz, beat 0.2000 Hz
            7'd49: begin f0_step = 32'd6095311; beat_step = 32'd8796; end // 138.59 Hz, beat 0.2000 Hz
            7'd50: begin f0_step = 32'd6457757; beat_step = 32'd8796; end // 146.83 Hz, beat 0.2000 Hz
            7'd51: begin f0_step = 32'd6841755; beat_step = 32'd8796; end // 155.56 Hz, beat 0.2000 Hz
            7'd52: begin f0_step = 32'd7248587; beat_step = 32'd8796; end // 164.81 Hz, beat 0.2000 Hz
            7'd53: begin f0_step = 32'd7679610; beat_step = 32'd8796; end // 174.61 Hz, beat 0.2000 Hz
            7'd54: begin f0_step = 32'd8136263; beat_step = 32'd8796; end // 185.00 Hz, beat 0.2000 Hz
            7'd55: begin f0_step = 32'd8620071; beat_step = 32'd9163; end // 196.00 Hz, beat 0.2083 Hz
            7'd56: begin f0_step = 32'd9132647; beat_step = 32'd9529; end // 207.65 Hz, beat 0.2167 Hz
            7'd57: begin f0_step = 32'd9675702; beat_step = 32'd9896; end // 220.00 Hz, beat 0.2250 Hz
            7'd58: begin f0_step = 32'd10251050; beat_step = 32'd10262; end // 233.08 Hz, beat 0.2333 Hz
            7'd59: begin f0_step = 32'd10860609; beat_step = 32'd10629; end // 246.94 Hz, beat 0.2417 Hz
            7'd60: begin f0_step = 32'd11506414; beat_step = 32'd10995; end // 261.63 Hz, beat 0.2500 Hz
            7'd61: begin f0_step = 32'd12190621; beat_step = 32'd11142; end // 277.18 Hz, beat 0.2533 Hz
            7'd62: begin f0_step = 32'd12915513; beat_step = 32'd11288; end // 293.66 Hz, beat 0.2567 Hz
            7'd63: begin f0_step = 32'd13683509; beat_step = 32'd11435; end // 311.13 Hz, beat 0.2600 Hz
            7'd64: begin f0_step = 32'd14497173; beat_step = 32'd11582; end // 329.63 Hz, beat 0.2633 Hz
            7'd65: begin f0_step = 32'd15359220; beat_step = 32'd11728; end // 349.23 Hz, beat 0.2667 Hz
            7'd66: begin f0_step = 32'd16272527; beat_step = 32'd11875; end // 369.99 Hz, beat 0.2700 Hz
            7'd67: begin f0_step = 32'd17240142; beat_step = 32'd12095; end // 392.00 Hz, beat 0.2750 Hz
            7'd68: begin f0_step = 32'd18265294; beat_step = 32'd12315; end // 415.30 Hz, beat 0.2800 Hz
            7'd69: begin f0_step = 32'd19351405; beat_step = 32'd12534; end // 440.00 Hz, beat 0.2850 Hz
            7'd70: begin f0_step = 32'd20502099; beat_step = 32'd12754; end // 466.16 Hz, beat 0.2900 Hz
            7'd71: begin f0_step = 32'd21721217; beat_step = 32'd12974; end // 493.88 Hz, beat 0.2950 Hz
            7'd72: begin f0_step = 32'd23012828; beat_step = 32'd13194; end // 523.25 Hz, beat 0.3000 Hz
            7'd73: begin f0_step = 32'd24381242; beat_step = 32'd13561; end // 554.37 Hz, beat 0.3083 Hz
            7'd74: begin f0_step = 32'd25831026; beat_step = 32'd13927; end // 587.33 Hz, beat 0.3167 Hz
            7'd75: begin f0_step = 32'd27367019; beat_step = 32'd14294; end // 622.25 Hz, beat 0.3250 Hz
            7'd76: begin f0_step = 32'd28994347; beat_step = 32'd14660; end // 659.26 Hz, beat 0.3333 Hz
            7'd77: begin f0_step = 32'd30718440; beat_step = 32'd15027; end // 698.46 Hz, beat 0.3417 Hz
            7'd78: begin f0_step = 32'd32545054; beat_step = 32'd15393; end // 739.99 Hz, beat 0.3500 Hz
            7'd79: begin f0_step = 32'd34480283; beat_step = 32'd16493; end // 783.99 Hz, beat 0.3750 Hz
            7'd80: begin f0_step = 32'd36530588; beat_step = 32'd17592; end // 830.61 Hz, beat 0.4000 Hz
            7'd81: begin f0_step = 32'd38702809; beat_step = 32'd18692; end // 880.00 Hz, beat 0.4250 Hz
            7'd82: begin f0_step = 32'd41004198; beat_step = 32'd19791; end // 932.33 Hz, beat 0.4500 Hz
            7'd83: begin f0_step = 32'd43442435; beat_step = 32'd20891; end // 987.77 Hz, beat 0.4750 Hz
            7'd84: begin f0_step = 32'd46025656; beat_step = 32'd21990; end // 1046.50 Hz, beat 0.5000 Hz
            7'd85: begin f0_step = 32'd48762484; beat_step = 32'd22892; end // 1108.73 Hz, beat 0.5205 Hz
            7'd86: begin f0_step = 32'd51662052; beat_step = 32'd23793; end // 1174.66 Hz, beat 0.5410 Hz
            7'd87: begin f0_step = 32'd54734038; beat_step = 32'd24695; end // 1244.51 Hz, beat 0.5615 Hz
            7'd88: begin f0_step = 32'd57988693; beat_step = 32'd25597; end // 1318.51 Hz, beat 0.5820 Hz
            7'd89: begin f0_step = 32'd61436880; beat_step = 32'd26498; end // 1396.91 Hz, beat 0.6025 Hz
            7'd90: begin f0_step = 32'd65090107; beat_step = 32'd27400; end // 1479.98 Hz, beat 0.6230 Hz
            7'd91: begin f0_step = 32'd68960566; beat_step = 32'd28301; end // 1567.98 Hz, beat 0.6435 Hz
            7'd92: begin f0_step = 32'd73061175; beat_step = 32'd29203; end // 1661.22 Hz, beat 0.6640 Hz
            7'd93: begin f0_step = 32'd77405619; beat_step = 32'd30621; end // 1760.00 Hz, beat 0.6963 Hz
            7'd94: begin f0_step = 32'd82008396; beat_step = 32'd32040; end // 1864.66 Hz, beat 0.7285 Hz
            7'd95: begin f0_step = 32'd86884869; beat_step = 32'd33458; end // 1975.53 Hz, beat 0.7608 Hz
            7'd96: begin f0_step = 32'd92051312; beat_step = 32'd34877; end // 2093.00 Hz, beat 0.7930 Hz
            7'd97: begin f0_step = 32'd97524968; beat_step = 32'd37911; end // 2217.46 Hz, beat 0.8620 Hz
            7'd98: begin f0_step = 32'd103324105; beat_step = 32'd40946; end // 2349.32 Hz, beat 0.9310 Hz
            7'd99: begin f0_step = 32'd109468076; beat_step = 32'd43980; end // 2489.02 Hz, beat 1.0000 Hz
            7'd100: begin f0_step = 32'd115977386; beat_step = 32'd43980; end // 2637.02 Hz, beat 1.0000 Hz
            7'd101: begin f0_step = 32'd122873760; beat_step = 32'd43980; end // 2793.83 Hz, beat 1.0000 Hz
            7'd102: begin f0_step = 32'd130180214; beat_step = 32'd43980; end // 2959.96 Hz, beat 1.0000 Hz
            7'd103: begin f0_step = 32'd137921133; beat_step = 32'd43980; end // 3135.96 Hz, beat 1.0000 Hz
            7'd104: begin f0_step = 32'd146122350; beat_step = 32'd43980; end // 3322.44 Hz, beat 1.0000 Hz
            7'd105: begin f0_step = 32'd154811237; beat_step = 32'd43980; end // 3520.00 Hz, beat 1.0000 Hz
            7'd106: begin f0_step = 32'd164016792; beat_step = 32'd43980; end // 3729.31 Hz, beat 1.0000 Hz
            7'd107: begin f0_step = 32'd173769738; beat_step = 32'd43980; end // 3951.07 Hz, beat 1.0000 Hz
            7'd108: begin f0_step = 32'd184102625; beat_step = 32'd43980; end // 4186.01 Hz, beat 1.0000 Hz
            7'd109: begin f0_step = 32'd195049936; beat_step = 32'd43980; end // 4434.92 Hz, beat 1.0000 Hz
            7'd110: begin f0_step = 32'd206648209; beat_step = 32'd43980; end // 4698.64 Hz, beat 1.0000 Hz
            7'd111: begin f0_step = 32'd218936151; beat_step = 32'd43980; end // 4978.03 Hz, beat 1.0000 Hz
            7'd112: begin f0_step = 32'd231954772; beat_step = 32'd43980; end // 5274.04 Hz, beat 1.0000 Hz
            7'd113: begin f0_step = 32'd245747521; beat_step = 32'd43980; end // 5587.65 Hz, beat 1.0000 Hz
            7'd114: begin f0_step = 32'd260360429; beat_step = 32'd43980; end // 5919.91 Hz, beat 1.0000 Hz
            7'd115: begin f0_step = 32'd275842266; beat_step = 32'd43980; end // 6271.93 Hz, beat 1.0000 Hz
            7'd116: begin f0_step = 32'd292244700; beat_step = 32'd43980; end // 6644.88 Hz, beat 1.0000 Hz
            7'd117: begin f0_step = 32'd309622474; beat_step = 32'd43980; end // 7040.00 Hz, beat 1.0000 Hz
            7'd118: begin f0_step = 32'd328033585; beat_step = 32'd43980; end // 7458.62 Hz, beat 1.0000 Hz
            7'd119: begin f0_step = 32'd347539477; beat_step = 32'd43980; end // 7902.13 Hz, beat 1.0000 Hz
            7'd120: begin f0_step = 32'd368205249; beat_step = 32'd43980; end // 8372.02 Hz, beat 1.0000 Hz
            7'd121: begin f0_step = 32'd390099873; beat_step = 32'd43980; end // 8869.84 Hz, beat 1.0000 Hz
            7'd122: begin f0_step = 32'd413296419; beat_step = 32'd43980; end // 9397.27 Hz, beat 1.0000 Hz
            7'd123: begin f0_step = 32'd437872302; beat_step = 32'd43980; end // 9956.06 Hz, beat 1.0000 Hz
            7'd124: begin f0_step = 32'd463909545; beat_step = 32'd43980; end // 10548.08 Hz, beat 1.0000 Hz
            7'd125: begin f0_step = 32'd491495042; beat_step = 32'd43980; end // 11175.30 Hz, beat 1.0000 Hz
            7'd126: begin f0_step = 32'd520720858; beat_step = 32'd43980; end // 11839.82 Hz, beat 1.0000 Hz
            7'd127: begin f0_step = 32'd551684531; beat_step = 32'd43980; end // 12543.85 Hz, beat 1.0000 Hz
            default: begin f0_step = 32'd0; beat_step = 32'd0; end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_vel_lut —— 力度 → 增益 / 琴槌噪声低通档位
//    gain_q16 : 0.12 .. 1.0（≈ -18 dB 动态），曲线 (v/127)^1.6
//    lp_sh    : 一阶低通右移量，力度越大越小（越亮）
// -----------------------------------------------------------------------------
module piano_vel_lut (
    input  wire [6:0]  vel,
    input  wire [1:0]  inst,          // 0=钢琴 1=电吉他 2=古筝
    output reg  [16:0] gain_q16,
    output reg  [2:0]  lp_sh
);

    always @(*) begin
        case ({inst, vel})
            10'd0: begin gain_q16 = 17'd7864; lp_sh = 3'd3; end
            10'd1: begin gain_q16 = 17'd7889; lp_sh = 3'd3; end
            10'd2: begin gain_q16 = 17'd7940; lp_sh = 3'd3; end
            10'd3: begin gain_q16 = 17'd8008; lp_sh = 3'd3; end
            10'd4: begin gain_q16 = 17'd8092; lp_sh = 3'd3; end
            10'd5: begin gain_q16 = 17'd8190; lp_sh = 3'd3; end
            10'd6: begin gain_q16 = 17'd8301; lp_sh = 3'd3; end
            10'd7: begin gain_q16 = 17'd8423; lp_sh = 3'd3; end
            10'd8: begin gain_q16 = 17'd8556; lp_sh = 3'd3; end
            10'd9: begin gain_q16 = 17'd8699; lp_sh = 3'd3; end
            10'd10: begin gain_q16 = 17'd8853; lp_sh = 3'd3; end
            10'd11: begin gain_q16 = 17'd9015; lp_sh = 3'd3; end
            10'd12: begin gain_q16 = 17'd9187; lp_sh = 3'd3; end
            10'd13: begin gain_q16 = 17'd9368; lp_sh = 3'd3; end
            10'd14: begin gain_q16 = 17'd9557; lp_sh = 3'd3; end
            10'd15: begin gain_q16 = 17'd9755; lp_sh = 3'd3; end
            10'd16: begin gain_q16 = 17'd9961; lp_sh = 3'd3; end
            10'd17: begin gain_q16 = 17'd10174; lp_sh = 3'd3; end
            10'd18: begin gain_q16 = 17'd10395; lp_sh = 3'd3; end
            10'd19: begin gain_q16 = 17'd10624; lp_sh = 3'd3; end
            10'd20: begin gain_q16 = 17'd10860; lp_sh = 3'd3; end
            10'd21: begin gain_q16 = 17'd11103; lp_sh = 3'd3; end
            10'd22: begin gain_q16 = 17'd11354; lp_sh = 3'd3; end
            10'd23: begin gain_q16 = 17'd11611; lp_sh = 3'd3; end
            10'd24: begin gain_q16 = 17'd11875; lp_sh = 3'd3; end
            10'd25: begin gain_q16 = 17'd12146; lp_sh = 3'd3; end
            10'd26: begin gain_q16 = 17'd12423; lp_sh = 3'd3; end
            10'd27: begin gain_q16 = 17'd12707; lp_sh = 3'd3; end
            10'd28: begin gain_q16 = 17'd12997; lp_sh = 3'd3; end
            10'd29: begin gain_q16 = 17'd13293; lp_sh = 3'd3; end
            10'd30: begin gain_q16 = 17'd13596; lp_sh = 3'd3; end
            10'd31: begin gain_q16 = 17'd13905; lp_sh = 3'd3; end
            10'd32: begin gain_q16 = 17'd14219; lp_sh = 3'd3; end
            10'd33: begin gain_q16 = 17'd14540; lp_sh = 3'd3; end
            10'd34: begin gain_q16 = 17'd14867; lp_sh = 3'd3; end
            10'd35: begin gain_q16 = 17'd15199; lp_sh = 3'd3; end
            10'd36: begin gain_q16 = 17'd15537; lp_sh = 3'd3; end
            10'd37: begin gain_q16 = 17'd15881; lp_sh = 3'd3; end
            10'd38: begin gain_q16 = 17'd16231; lp_sh = 3'd3; end
            10'd39: begin gain_q16 = 17'd16586; lp_sh = 3'd3; end
            10'd40: begin gain_q16 = 17'd16946; lp_sh = 3'd3; end
            10'd41: begin gain_q16 = 17'd17312; lp_sh = 3'd3; end
            10'd42: begin gain_q16 = 17'd17684; lp_sh = 3'd3; end
            10'd43: begin gain_q16 = 17'd18060; lp_sh = 3'd3; end
            10'd44: begin gain_q16 = 17'd18442; lp_sh = 3'd3; end
            10'd45: begin gain_q16 = 17'd18830; lp_sh = 3'd3; end
            10'd46: begin gain_q16 = 17'd19222; lp_sh = 3'd3; end
            10'd47: begin gain_q16 = 17'd19620; lp_sh = 3'd3; end
            10'd48: begin gain_q16 = 17'd20022; lp_sh = 3'd3; end
            10'd49: begin gain_q16 = 17'd20430; lp_sh = 3'd3; end
            10'd50: begin gain_q16 = 17'd20843; lp_sh = 3'd3; end
            10'd51: begin gain_q16 = 17'd21261; lp_sh = 3'd3; end
            10'd52: begin gain_q16 = 17'd21683; lp_sh = 3'd3; end
            10'd53: begin gain_q16 = 17'd22111; lp_sh = 3'd3; end
            10'd54: begin gain_q16 = 17'd22544; lp_sh = 3'd3; end
            10'd55: begin gain_q16 = 17'd22981; lp_sh = 3'd3; end
            10'd56: begin gain_q16 = 17'd23423; lp_sh = 3'd3; end
            10'd57: begin gain_q16 = 17'd23870; lp_sh = 3'd3; end
            10'd58: begin gain_q16 = 17'd24322; lp_sh = 3'd3; end
            10'd59: begin gain_q16 = 17'd24778; lp_sh = 3'd3; end
            10'd60: begin gain_q16 = 17'd25239; lp_sh = 3'd3; end
            10'd61: begin gain_q16 = 17'd25705; lp_sh = 3'd3; end
            10'd62: begin gain_q16 = 17'd26175; lp_sh = 3'd3; end
            10'd63: begin gain_q16 = 17'd26650; lp_sh = 3'd3; end
            10'd64: begin gain_q16 = 17'd27129; lp_sh = 3'd2; end
            10'd65: begin gain_q16 = 17'd27613; lp_sh = 3'd2; end
            10'd66: begin gain_q16 = 17'd28101; lp_sh = 3'd2; end
            10'd67: begin gain_q16 = 17'd28594; lp_sh = 3'd2; end
            10'd68: begin gain_q16 = 17'd29091; lp_sh = 3'd2; end
            10'd69: begin gain_q16 = 17'd29593; lp_sh = 3'd2; end
            10'd70: begin gain_q16 = 17'd30099; lp_sh = 3'd2; end
            10'd71: begin gain_q16 = 17'd30610; lp_sh = 3'd2; end
            10'd72: begin gain_q16 = 17'd31124; lp_sh = 3'd2; end
            10'd73: begin gain_q16 = 17'd31643; lp_sh = 3'd2; end
            10'd74: begin gain_q16 = 17'd32167; lp_sh = 3'd2; end
            10'd75: begin gain_q16 = 17'd32694; lp_sh = 3'd2; end
            10'd76: begin gain_q16 = 17'd33226; lp_sh = 3'd2; end
            10'd77: begin gain_q16 = 17'd33762; lp_sh = 3'd2; end
            10'd78: begin gain_q16 = 17'd34302; lp_sh = 3'd2; end
            10'd79: begin gain_q16 = 17'd34847; lp_sh = 3'd2; end
            10'd80: begin gain_q16 = 17'd35395; lp_sh = 3'd2; end
            10'd81: begin gain_q16 = 17'd35948; lp_sh = 3'd2; end
            10'd82: begin gain_q16 = 17'd36505; lp_sh = 3'd2; end
            10'd83: begin gain_q16 = 17'd37066; lp_sh = 3'd2; end
            10'd84: begin gain_q16 = 17'd37631; lp_sh = 3'd2; end
            10'd85: begin gain_q16 = 17'd38200; lp_sh = 3'd2; end
            10'd86: begin gain_q16 = 17'd38773; lp_sh = 3'd2; end
            10'd87: begin gain_q16 = 17'd39350; lp_sh = 3'd2; end
            10'd88: begin gain_q16 = 17'd39931; lp_sh = 3'd2; end
            10'd89: begin gain_q16 = 17'd40516; lp_sh = 3'd2; end
            10'd90: begin gain_q16 = 17'd41105; lp_sh = 3'd2; end
            10'd91: begin gain_q16 = 17'd41698; lp_sh = 3'd2; end
            10'd92: begin gain_q16 = 17'd42294; lp_sh = 3'd2; end
            10'd93: begin gain_q16 = 17'd42895; lp_sh = 3'd2; end
            10'd94: begin gain_q16 = 17'd43500; lp_sh = 3'd2; end
            10'd95: begin gain_q16 = 17'd44108; lp_sh = 3'd2; end
            10'd96: begin gain_q16 = 17'd44721; lp_sh = 3'd2; end
            10'd97: begin gain_q16 = 17'd45337; lp_sh = 3'd2; end
            10'd98: begin gain_q16 = 17'd45957; lp_sh = 3'd2; end
            10'd99: begin gain_q16 = 17'd46581; lp_sh = 3'd2; end
            10'd100: begin gain_q16 = 17'd47208; lp_sh = 3'd1; end
            10'd101: begin gain_q16 = 17'd47840; lp_sh = 3'd1; end
            10'd102: begin gain_q16 = 17'd48475; lp_sh = 3'd1; end
            10'd103: begin gain_q16 = 17'd49114; lp_sh = 3'd1; end
            10'd104: begin gain_q16 = 17'd49756; lp_sh = 3'd1; end
            10'd105: begin gain_q16 = 17'd50403; lp_sh = 3'd1; end
            10'd106: begin gain_q16 = 17'd51053; lp_sh = 3'd1; end
            10'd107: begin gain_q16 = 17'd51706; lp_sh = 3'd1; end
            10'd108: begin gain_q16 = 17'd52364; lp_sh = 3'd1; end
            10'd109: begin gain_q16 = 17'd53025; lp_sh = 3'd1; end
            10'd110: begin gain_q16 = 17'd53690; lp_sh = 3'd1; end
            10'd111: begin gain_q16 = 17'd54358; lp_sh = 3'd1; end
            10'd112: begin gain_q16 = 17'd55030; lp_sh = 3'd1; end
            10'd113: begin gain_q16 = 17'd55706; lp_sh = 3'd1; end
            10'd114: begin gain_q16 = 17'd56385; lp_sh = 3'd1; end
            10'd115: begin gain_q16 = 17'd57068; lp_sh = 3'd1; end
            10'd116: begin gain_q16 = 17'd57754; lp_sh = 3'd1; end
            10'd117: begin gain_q16 = 17'd58444; lp_sh = 3'd1; end
            10'd118: begin gain_q16 = 17'd59137; lp_sh = 3'd1; end
            10'd119: begin gain_q16 = 17'd59834; lp_sh = 3'd1; end
            10'd120: begin gain_q16 = 17'd60535; lp_sh = 3'd1; end
            10'd121: begin gain_q16 = 17'd61239; lp_sh = 3'd1; end
            10'd122: begin gain_q16 = 17'd61946; lp_sh = 3'd1; end
            10'd123: begin gain_q16 = 17'd62657; lp_sh = 3'd1; end
            10'd124: begin gain_q16 = 17'd63372; lp_sh = 3'd1; end
            10'd125: begin gain_q16 = 17'd64090; lp_sh = 3'd1; end
            10'd126: begin gain_q16 = 17'd64811; lp_sh = 3'd1; end
            10'd127: begin gain_q16 = 17'd65536; lp_sh = 3'd1; end
            10'd128: begin gain_q16 = 17'd7864; lp_sh = 3'd2; end
            10'd129: begin gain_q16 = 17'd7889; lp_sh = 3'd2; end
            10'd130: begin gain_q16 = 17'd7940; lp_sh = 3'd2; end
            10'd131: begin gain_q16 = 17'd8008; lp_sh = 3'd2; end
            10'd132: begin gain_q16 = 17'd8092; lp_sh = 3'd2; end
            10'd133: begin gain_q16 = 17'd8190; lp_sh = 3'd2; end
            10'd134: begin gain_q16 = 17'd8301; lp_sh = 3'd2; end
            10'd135: begin gain_q16 = 17'd8423; lp_sh = 3'd2; end
            10'd136: begin gain_q16 = 17'd8556; lp_sh = 3'd2; end
            10'd137: begin gain_q16 = 17'd8699; lp_sh = 3'd2; end
            10'd138: begin gain_q16 = 17'd8853; lp_sh = 3'd2; end
            10'd139: begin gain_q16 = 17'd9015; lp_sh = 3'd2; end
            10'd140: begin gain_q16 = 17'd9187; lp_sh = 3'd2; end
            10'd141: begin gain_q16 = 17'd9368; lp_sh = 3'd2; end
            10'd142: begin gain_q16 = 17'd9557; lp_sh = 3'd2; end
            10'd143: begin gain_q16 = 17'd9755; lp_sh = 3'd2; end
            10'd144: begin gain_q16 = 17'd9961; lp_sh = 3'd2; end
            10'd145: begin gain_q16 = 17'd10174; lp_sh = 3'd2; end
            10'd146: begin gain_q16 = 17'd10395; lp_sh = 3'd2; end
            10'd147: begin gain_q16 = 17'd10624; lp_sh = 3'd2; end
            10'd148: begin gain_q16 = 17'd10860; lp_sh = 3'd2; end
            10'd149: begin gain_q16 = 17'd11103; lp_sh = 3'd2; end
            10'd150: begin gain_q16 = 17'd11354; lp_sh = 3'd2; end
            10'd151: begin gain_q16 = 17'd11611; lp_sh = 3'd2; end
            10'd152: begin gain_q16 = 17'd11875; lp_sh = 3'd2; end
            10'd153: begin gain_q16 = 17'd12146; lp_sh = 3'd2; end
            10'd154: begin gain_q16 = 17'd12423; lp_sh = 3'd2; end
            10'd155: begin gain_q16 = 17'd12707; lp_sh = 3'd2; end
            10'd156: begin gain_q16 = 17'd12997; lp_sh = 3'd2; end
            10'd157: begin gain_q16 = 17'd13293; lp_sh = 3'd2; end
            10'd158: begin gain_q16 = 17'd13596; lp_sh = 3'd2; end
            10'd159: begin gain_q16 = 17'd13905; lp_sh = 3'd2; end
            10'd160: begin gain_q16 = 17'd14219; lp_sh = 3'd2; end
            10'd161: begin gain_q16 = 17'd14540; lp_sh = 3'd2; end
            10'd162: begin gain_q16 = 17'd14867; lp_sh = 3'd2; end
            10'd163: begin gain_q16 = 17'd15199; lp_sh = 3'd2; end
            10'd164: begin gain_q16 = 17'd15537; lp_sh = 3'd2; end
            10'd165: begin gain_q16 = 17'd15881; lp_sh = 3'd2; end
            10'd166: begin gain_q16 = 17'd16231; lp_sh = 3'd2; end
            10'd167: begin gain_q16 = 17'd16586; lp_sh = 3'd2; end
            10'd168: begin gain_q16 = 17'd16946; lp_sh = 3'd2; end
            10'd169: begin gain_q16 = 17'd17312; lp_sh = 3'd2; end
            10'd170: begin gain_q16 = 17'd17684; lp_sh = 3'd2; end
            10'd171: begin gain_q16 = 17'd18060; lp_sh = 3'd2; end
            10'd172: begin gain_q16 = 17'd18442; lp_sh = 3'd2; end
            10'd173: begin gain_q16 = 17'd18830; lp_sh = 3'd2; end
            10'd174: begin gain_q16 = 17'd19222; lp_sh = 3'd2; end
            10'd175: begin gain_q16 = 17'd19620; lp_sh = 3'd2; end
            10'd176: begin gain_q16 = 17'd20022; lp_sh = 3'd2; end
            10'd177: begin gain_q16 = 17'd20430; lp_sh = 3'd2; end
            10'd178: begin gain_q16 = 17'd20843; lp_sh = 3'd2; end
            10'd179: begin gain_q16 = 17'd21261; lp_sh = 3'd2; end
            10'd180: begin gain_q16 = 17'd21683; lp_sh = 3'd2; end
            10'd181: begin gain_q16 = 17'd22111; lp_sh = 3'd2; end
            10'd182: begin gain_q16 = 17'd22544; lp_sh = 3'd2; end
            10'd183: begin gain_q16 = 17'd22981; lp_sh = 3'd2; end
            10'd184: begin gain_q16 = 17'd23423; lp_sh = 3'd2; end
            10'd185: begin gain_q16 = 17'd23870; lp_sh = 3'd2; end
            10'd186: begin gain_q16 = 17'd24322; lp_sh = 3'd2; end
            10'd187: begin gain_q16 = 17'd24778; lp_sh = 3'd2; end
            10'd188: begin gain_q16 = 17'd25239; lp_sh = 3'd2; end
            10'd189: begin gain_q16 = 17'd25705; lp_sh = 3'd2; end
            10'd190: begin gain_q16 = 17'd26175; lp_sh = 3'd2; end
            10'd191: begin gain_q16 = 17'd26650; lp_sh = 3'd2; end
            10'd192: begin gain_q16 = 17'd27129; lp_sh = 3'd1; end
            10'd193: begin gain_q16 = 17'd27613; lp_sh = 3'd1; end
            10'd194: begin gain_q16 = 17'd28101; lp_sh = 3'd1; end
            10'd195: begin gain_q16 = 17'd28594; lp_sh = 3'd1; end
            10'd196: begin gain_q16 = 17'd29091; lp_sh = 3'd1; end
            10'd197: begin gain_q16 = 17'd29593; lp_sh = 3'd1; end
            10'd198: begin gain_q16 = 17'd30099; lp_sh = 3'd1; end
            10'd199: begin gain_q16 = 17'd30610; lp_sh = 3'd1; end
            10'd200: begin gain_q16 = 17'd31124; lp_sh = 3'd1; end
            10'd201: begin gain_q16 = 17'd31643; lp_sh = 3'd1; end
            10'd202: begin gain_q16 = 17'd32167; lp_sh = 3'd1; end
            10'd203: begin gain_q16 = 17'd32694; lp_sh = 3'd1; end
            10'd204: begin gain_q16 = 17'd33226; lp_sh = 3'd1; end
            10'd205: begin gain_q16 = 17'd33762; lp_sh = 3'd1; end
            10'd206: begin gain_q16 = 17'd34302; lp_sh = 3'd1; end
            10'd207: begin gain_q16 = 17'd34847; lp_sh = 3'd1; end
            10'd208: begin gain_q16 = 17'd35395; lp_sh = 3'd1; end
            10'd209: begin gain_q16 = 17'd35948; lp_sh = 3'd1; end
            10'd210: begin gain_q16 = 17'd36505; lp_sh = 3'd1; end
            10'd211: begin gain_q16 = 17'd37066; lp_sh = 3'd1; end
            10'd212: begin gain_q16 = 17'd37631; lp_sh = 3'd1; end
            10'd213: begin gain_q16 = 17'd38200; lp_sh = 3'd1; end
            10'd214: begin gain_q16 = 17'd38773; lp_sh = 3'd1; end
            10'd215: begin gain_q16 = 17'd39350; lp_sh = 3'd1; end
            10'd216: begin gain_q16 = 17'd39931; lp_sh = 3'd1; end
            10'd217: begin gain_q16 = 17'd40516; lp_sh = 3'd1; end
            10'd218: begin gain_q16 = 17'd41105; lp_sh = 3'd1; end
            10'd219: begin gain_q16 = 17'd41698; lp_sh = 3'd1; end
            10'd220: begin gain_q16 = 17'd42294; lp_sh = 3'd1; end
            10'd221: begin gain_q16 = 17'd42895; lp_sh = 3'd1; end
            10'd222: begin gain_q16 = 17'd43500; lp_sh = 3'd1; end
            10'd223: begin gain_q16 = 17'd44108; lp_sh = 3'd1; end
            10'd224: begin gain_q16 = 17'd44721; lp_sh = 3'd1; end
            10'd225: begin gain_q16 = 17'd45337; lp_sh = 3'd1; end
            10'd226: begin gain_q16 = 17'd45957; lp_sh = 3'd1; end
            10'd227: begin gain_q16 = 17'd46581; lp_sh = 3'd1; end
            10'd228: begin gain_q16 = 17'd47208; lp_sh = 3'd0; end
            10'd229: begin gain_q16 = 17'd47840; lp_sh = 3'd0; end
            10'd230: begin gain_q16 = 17'd48475; lp_sh = 3'd0; end
            10'd231: begin gain_q16 = 17'd49114; lp_sh = 3'd0; end
            10'd232: begin gain_q16 = 17'd49756; lp_sh = 3'd0; end
            10'd233: begin gain_q16 = 17'd50403; lp_sh = 3'd0; end
            10'd234: begin gain_q16 = 17'd51053; lp_sh = 3'd0; end
            10'd235: begin gain_q16 = 17'd51706; lp_sh = 3'd0; end
            10'd236: begin gain_q16 = 17'd52364; lp_sh = 3'd0; end
            10'd237: begin gain_q16 = 17'd53025; lp_sh = 3'd0; end
            10'd238: begin gain_q16 = 17'd53690; lp_sh = 3'd0; end
            10'd239: begin gain_q16 = 17'd54358; lp_sh = 3'd0; end
            10'd240: begin gain_q16 = 17'd55030; lp_sh = 3'd0; end
            10'd241: begin gain_q16 = 17'd55706; lp_sh = 3'd0; end
            10'd242: begin gain_q16 = 17'd56385; lp_sh = 3'd0; end
            10'd243: begin gain_q16 = 17'd57068; lp_sh = 3'd0; end
            10'd244: begin gain_q16 = 17'd57754; lp_sh = 3'd0; end
            10'd245: begin gain_q16 = 17'd58444; lp_sh = 3'd0; end
            10'd246: begin gain_q16 = 17'd59137; lp_sh = 3'd0; end
            10'd247: begin gain_q16 = 17'd59834; lp_sh = 3'd0; end
            10'd248: begin gain_q16 = 17'd60535; lp_sh = 3'd0; end
            10'd249: begin gain_q16 = 17'd61239; lp_sh = 3'd0; end
            10'd250: begin gain_q16 = 17'd61946; lp_sh = 3'd0; end
            10'd251: begin gain_q16 = 17'd62657; lp_sh = 3'd0; end
            10'd252: begin gain_q16 = 17'd63372; lp_sh = 3'd0; end
            10'd253: begin gain_q16 = 17'd64090; lp_sh = 3'd0; end
            10'd254: begin gain_q16 = 17'd64811; lp_sh = 3'd0; end
            10'd255: begin gain_q16 = 17'd65536; lp_sh = 3'd0; end
            10'd256: begin gain_q16 = 17'd7864; lp_sh = 3'd3; end
            10'd257: begin gain_q16 = 17'd7889; lp_sh = 3'd3; end
            10'd258: begin gain_q16 = 17'd7940; lp_sh = 3'd3; end
            10'd259: begin gain_q16 = 17'd8008; lp_sh = 3'd3; end
            10'd260: begin gain_q16 = 17'd8092; lp_sh = 3'd3; end
            10'd261: begin gain_q16 = 17'd8190; lp_sh = 3'd3; end
            10'd262: begin gain_q16 = 17'd8301; lp_sh = 3'd3; end
            10'd263: begin gain_q16 = 17'd8423; lp_sh = 3'd3; end
            10'd264: begin gain_q16 = 17'd8556; lp_sh = 3'd3; end
            10'd265: begin gain_q16 = 17'd8699; lp_sh = 3'd3; end
            10'd266: begin gain_q16 = 17'd8853; lp_sh = 3'd3; end
            10'd267: begin gain_q16 = 17'd9015; lp_sh = 3'd3; end
            10'd268: begin gain_q16 = 17'd9187; lp_sh = 3'd3; end
            10'd269: begin gain_q16 = 17'd9368; lp_sh = 3'd3; end
            10'd270: begin gain_q16 = 17'd9557; lp_sh = 3'd3; end
            10'd271: begin gain_q16 = 17'd9755; lp_sh = 3'd3; end
            10'd272: begin gain_q16 = 17'd9961; lp_sh = 3'd3; end
            10'd273: begin gain_q16 = 17'd10174; lp_sh = 3'd3; end
            10'd274: begin gain_q16 = 17'd10395; lp_sh = 3'd3; end
            10'd275: begin gain_q16 = 17'd10624; lp_sh = 3'd3; end
            10'd276: begin gain_q16 = 17'd10860; lp_sh = 3'd3; end
            10'd277: begin gain_q16 = 17'd11103; lp_sh = 3'd3; end
            10'd278: begin gain_q16 = 17'd11354; lp_sh = 3'd3; end
            10'd279: begin gain_q16 = 17'd11611; lp_sh = 3'd3; end
            10'd280: begin gain_q16 = 17'd11875; lp_sh = 3'd3; end
            10'd281: begin gain_q16 = 17'd12146; lp_sh = 3'd3; end
            10'd282: begin gain_q16 = 17'd12423; lp_sh = 3'd3; end
            10'd283: begin gain_q16 = 17'd12707; lp_sh = 3'd3; end
            10'd284: begin gain_q16 = 17'd12997; lp_sh = 3'd3; end
            10'd285: begin gain_q16 = 17'd13293; lp_sh = 3'd3; end
            10'd286: begin gain_q16 = 17'd13596; lp_sh = 3'd3; end
            10'd287: begin gain_q16 = 17'd13905; lp_sh = 3'd3; end
            10'd288: begin gain_q16 = 17'd14219; lp_sh = 3'd3; end
            10'd289: begin gain_q16 = 17'd14540; lp_sh = 3'd3; end
            10'd290: begin gain_q16 = 17'd14867; lp_sh = 3'd3; end
            10'd291: begin gain_q16 = 17'd15199; lp_sh = 3'd3; end
            10'd292: begin gain_q16 = 17'd15537; lp_sh = 3'd3; end
            10'd293: begin gain_q16 = 17'd15881; lp_sh = 3'd3; end
            10'd294: begin gain_q16 = 17'd16231; lp_sh = 3'd3; end
            10'd295: begin gain_q16 = 17'd16586; lp_sh = 3'd3; end
            10'd296: begin gain_q16 = 17'd16946; lp_sh = 3'd3; end
            10'd297: begin gain_q16 = 17'd17312; lp_sh = 3'd3; end
            10'd298: begin gain_q16 = 17'd17684; lp_sh = 3'd3; end
            10'd299: begin gain_q16 = 17'd18060; lp_sh = 3'd3; end
            10'd300: begin gain_q16 = 17'd18442; lp_sh = 3'd3; end
            10'd301: begin gain_q16 = 17'd18830; lp_sh = 3'd3; end
            10'd302: begin gain_q16 = 17'd19222; lp_sh = 3'd3; end
            10'd303: begin gain_q16 = 17'd19620; lp_sh = 3'd3; end
            10'd304: begin gain_q16 = 17'd20022; lp_sh = 3'd3; end
            10'd305: begin gain_q16 = 17'd20430; lp_sh = 3'd3; end
            10'd306: begin gain_q16 = 17'd20843; lp_sh = 3'd3; end
            10'd307: begin gain_q16 = 17'd21261; lp_sh = 3'd3; end
            10'd308: begin gain_q16 = 17'd21683; lp_sh = 3'd3; end
            10'd309: begin gain_q16 = 17'd22111; lp_sh = 3'd3; end
            10'd310: begin gain_q16 = 17'd22544; lp_sh = 3'd3; end
            10'd311: begin gain_q16 = 17'd22981; lp_sh = 3'd3; end
            10'd312: begin gain_q16 = 17'd23423; lp_sh = 3'd3; end
            10'd313: begin gain_q16 = 17'd23870; lp_sh = 3'd3; end
            10'd314: begin gain_q16 = 17'd24322; lp_sh = 3'd3; end
            10'd315: begin gain_q16 = 17'd24778; lp_sh = 3'd3; end
            10'd316: begin gain_q16 = 17'd25239; lp_sh = 3'd3; end
            10'd317: begin gain_q16 = 17'd25705; lp_sh = 3'd3; end
            10'd318: begin gain_q16 = 17'd26175; lp_sh = 3'd3; end
            10'd319: begin gain_q16 = 17'd26650; lp_sh = 3'd3; end
            10'd320: begin gain_q16 = 17'd27129; lp_sh = 3'd2; end
            10'd321: begin gain_q16 = 17'd27613; lp_sh = 3'd2; end
            10'd322: begin gain_q16 = 17'd28101; lp_sh = 3'd2; end
            10'd323: begin gain_q16 = 17'd28594; lp_sh = 3'd2; end
            10'd324: begin gain_q16 = 17'd29091; lp_sh = 3'd2; end
            10'd325: begin gain_q16 = 17'd29593; lp_sh = 3'd2; end
            10'd326: begin gain_q16 = 17'd30099; lp_sh = 3'd2; end
            10'd327: begin gain_q16 = 17'd30610; lp_sh = 3'd2; end
            10'd328: begin gain_q16 = 17'd31124; lp_sh = 3'd2; end
            10'd329: begin gain_q16 = 17'd31643; lp_sh = 3'd2; end
            10'd330: begin gain_q16 = 17'd32167; lp_sh = 3'd2; end
            10'd331: begin gain_q16 = 17'd32694; lp_sh = 3'd2; end
            10'd332: begin gain_q16 = 17'd33226; lp_sh = 3'd2; end
            10'd333: begin gain_q16 = 17'd33762; lp_sh = 3'd2; end
            10'd334: begin gain_q16 = 17'd34302; lp_sh = 3'd2; end
            10'd335: begin gain_q16 = 17'd34847; lp_sh = 3'd2; end
            10'd336: begin gain_q16 = 17'd35395; lp_sh = 3'd2; end
            10'd337: begin gain_q16 = 17'd35948; lp_sh = 3'd2; end
            10'd338: begin gain_q16 = 17'd36505; lp_sh = 3'd2; end
            10'd339: begin gain_q16 = 17'd37066; lp_sh = 3'd2; end
            10'd340: begin gain_q16 = 17'd37631; lp_sh = 3'd2; end
            10'd341: begin gain_q16 = 17'd38200; lp_sh = 3'd2; end
            10'd342: begin gain_q16 = 17'd38773; lp_sh = 3'd2; end
            10'd343: begin gain_q16 = 17'd39350; lp_sh = 3'd2; end
            10'd344: begin gain_q16 = 17'd39931; lp_sh = 3'd2; end
            10'd345: begin gain_q16 = 17'd40516; lp_sh = 3'd2; end
            10'd346: begin gain_q16 = 17'd41105; lp_sh = 3'd2; end
            10'd347: begin gain_q16 = 17'd41698; lp_sh = 3'd2; end
            10'd348: begin gain_q16 = 17'd42294; lp_sh = 3'd2; end
            10'd349: begin gain_q16 = 17'd42895; lp_sh = 3'd2; end
            10'd350: begin gain_q16 = 17'd43500; lp_sh = 3'd2; end
            10'd351: begin gain_q16 = 17'd44108; lp_sh = 3'd2; end
            10'd352: begin gain_q16 = 17'd44721; lp_sh = 3'd2; end
            10'd353: begin gain_q16 = 17'd45337; lp_sh = 3'd2; end
            10'd354: begin gain_q16 = 17'd45957; lp_sh = 3'd2; end
            10'd355: begin gain_q16 = 17'd46581; lp_sh = 3'd2; end
            10'd356: begin gain_q16 = 17'd47208; lp_sh = 3'd1; end
            10'd357: begin gain_q16 = 17'd47840; lp_sh = 3'd1; end
            10'd358: begin gain_q16 = 17'd48475; lp_sh = 3'd1; end
            10'd359: begin gain_q16 = 17'd49114; lp_sh = 3'd1; end
            10'd360: begin gain_q16 = 17'd49756; lp_sh = 3'd1; end
            10'd361: begin gain_q16 = 17'd50403; lp_sh = 3'd1; end
            10'd362: begin gain_q16 = 17'd51053; lp_sh = 3'd1; end
            10'd363: begin gain_q16 = 17'd51706; lp_sh = 3'd1; end
            10'd364: begin gain_q16 = 17'd52364; lp_sh = 3'd1; end
            10'd365: begin gain_q16 = 17'd53025; lp_sh = 3'd1; end
            10'd366: begin gain_q16 = 17'd53690; lp_sh = 3'd1; end
            10'd367: begin gain_q16 = 17'd54358; lp_sh = 3'd1; end
            10'd368: begin gain_q16 = 17'd55030; lp_sh = 3'd1; end
            10'd369: begin gain_q16 = 17'd55706; lp_sh = 3'd1; end
            10'd370: begin gain_q16 = 17'd56385; lp_sh = 3'd1; end
            10'd371: begin gain_q16 = 17'd57068; lp_sh = 3'd1; end
            10'd372: begin gain_q16 = 17'd57754; lp_sh = 3'd1; end
            10'd373: begin gain_q16 = 17'd58444; lp_sh = 3'd1; end
            10'd374: begin gain_q16 = 17'd59137; lp_sh = 3'd1; end
            10'd375: begin gain_q16 = 17'd59834; lp_sh = 3'd1; end
            10'd376: begin gain_q16 = 17'd60535; lp_sh = 3'd1; end
            10'd377: begin gain_q16 = 17'd61239; lp_sh = 3'd1; end
            10'd378: begin gain_q16 = 17'd61946; lp_sh = 3'd1; end
            10'd379: begin gain_q16 = 17'd62657; lp_sh = 3'd1; end
            10'd380: begin gain_q16 = 17'd63372; lp_sh = 3'd1; end
            10'd381: begin gain_q16 = 17'd64090; lp_sh = 3'd1; end
            10'd382: begin gain_q16 = 17'd64811; lp_sh = 3'd1; end
            10'd383: begin gain_q16 = 17'd65536; lp_sh = 3'd1; end
            default: begin gain_q16 = 17'd7864; lp_sh = 3'd3; end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_partial_lut —— 第 n 个泛音分量的全部参数（n = 0..5 对应 1..6 次泛音）
//    amp_q16  : 幅度系数（Q16，满幅 = 65536）。6 个之和在最强奏时 ≈ 1.0
//    k_q12    : 力度→明亮度系数（Q12），实际增益 ×(1 + K/4096)
//    s_ring   : 按住时的衰减移位（env -= env >> s_ring）
//    s_damp   : 松开后的衰减移位（阻音器）
//    st1/st2  : 非谐性拉伸（inc = n·f0 + (f0>>st1) + (f0>>st2)），31 = 该项为 0
//  设计依据见 gen_piano_rom.py 头部（AMY / Faust STK）。
// -----------------------------------------------------------------------------
module piano_partial_lut (
    input  wire [2:0]  n,
    input  wire [1:0]  inst,          // 0=钢琴 1=电吉他 2=古筝
    output reg  [16:0] amp_q16,
    output reg  [15:0] k_q12,
    output reg  [4:0]  s_ring,
    output reg  [4:0]  s_damp,
    output reg  [4:0]  st1,
    output reg  [4:0]  st2
);

    //  ⚠️ amp/k/st1/st2 随乐器变；**s_ring/s_damp 三个乐器给同一组值**
    //     —— 因为它们在声部里是【常量索引查表 ⇒ 综合时折叠成常数移位】，
    //        一旦随乐器变就会在每采样路径长出桶形移位器（MODE=1 裕量只有 +0.009 ns）。
    //        乐器的衰减差异改由 ksh_ofs（piano_inst_lut）表达。
    always @(*) begin
        case ({inst, n})
            5'd0: begin amp_q16 = 17'd27594; k_q12 = 16'd0; s_ring = 5'd17; s_damp = 5'd11; st1 = 5'd13; st2 = 5'd14; end
            5'd1: begin amp_q16 = 17'd8278; k_q12 = 16'd3686; s_ring = 5'd16; s_damp = 5'd10; st1 = 5'd10; st2 = 5'd11; end
            5'd2: begin amp_q16 = 17'd3311; k_q12 = 16'd8192; s_ring = 5'd15; s_damp = 5'd9; st1 = 5'd8; st2 = 5'd9; end
            5'd3: begin amp_q16 = 17'd1380; k_q12 = 16'd14336; s_ring = 5'd14; s_damp = 5'd8; st1 = 5'd7; st2 = 5'd8; end
            5'd4: begin amp_q16 = 17'd552; k_q12 = 16'd22528; s_ring = 5'd13; s_damp = 5'd7; st1 = 5'd6; st2 = 5'd7; end
            5'd5: begin amp_q16 = 17'd276; k_q12 = 16'd32768; s_ring = 5'd12; s_damp = 5'd6; st1 = 5'd5; st2 = 5'd6; end
            5'd8: begin amp_q16 = 17'd8685; k_q12 = 16'd0; s_ring = 5'd17; s_damp = 5'd11; st1 = 5'd15; st2 = 5'd16; end
            5'd9: begin amp_q16 = 17'd6709; k_q12 = 16'd3686; s_ring = 5'd16; s_damp = 5'd10; st1 = 5'd12; st2 = 5'd13; end
            5'd10: begin amp_q16 = 17'd5451; k_q12 = 16'd8192; s_ring = 5'd15; s_damp = 5'd9; st1 = 5'd10; st2 = 5'd11; end
            5'd11: begin amp_q16 = 17'd4409; k_q12 = 16'd14336; s_ring = 5'd14; s_damp = 5'd8; st1 = 5'd9; st2 = 5'd10; end
            5'd12: begin amp_q16 = 17'd3468; k_q12 = 16'd22528; s_ring = 5'd13; s_damp = 5'd7; st1 = 5'd8; st2 = 5'd9; end
            5'd13: begin amp_q16 = 17'd2603; k_q12 = 16'd32768; s_ring = 5'd12; s_damp = 5'd6; st1 = 5'd7; st2 = 5'd8; end
            5'd16: begin amp_q16 = 17'd1210; k_q12 = 16'd0; s_ring = 5'd17; s_damp = 5'd11; st1 = 5'd14; st2 = 5'd15; end
            5'd17: begin amp_q16 = 17'd6958; k_q12 = 16'd2949; s_ring = 5'd16; s_damp = 5'd10; st1 = 5'd11; st2 = 5'd12; end
            5'd18: begin amp_q16 = 17'd12826; k_q12 = 16'd6554; s_ring = 5'd15; s_damp = 5'd9; st1 = 5'd9; st2 = 5'd10; end
            5'd19: begin amp_q16 = 17'd4816; k_q12 = 16'd11469; s_ring = 5'd14; s_damp = 5'd8; st1 = 5'd8; st2 = 5'd9; end
            5'd20: begin amp_q16 = 17'd171; k_q12 = 16'd18022; s_ring = 5'd13; s_damp = 5'd7; st1 = 5'd7; st2 = 5'd8; end
            5'd21: begin amp_q16 = 17'd61; k_q12 = 16'd26214; s_ring = 5'd12; s_damp = 5'd6; st1 = 5'd6; st2 = 5'd7; end
            default: begin
                amp_q16 = 17'd0; k_q12 = 16'd0;
                s_ring = 5'd18; s_damp = 5'd13; st1 = 5'd31; st2 = 5'd31;
            end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_inst_lut —— 乐器级参数（2026-10-06 多乐器）
//    ham_gain_q16 : 激励（琴槌/拨片/指甲）的初始能量。钢琴 = 原来的 HAM_GAIN_Q16 = 19661
//    ksh_ofs      : 包络更新速率的乐器偏移（2 bit 编码：0→−1, 1→0, 2→+1）
//                   ⇒ 古筝 +1（木共鸣箱衰减更长）、吉他 −1（本体短，延音靠音箱）
//  ⚠️ 钢琴行必须与原值逐位相同（回归要求）
// -----------------------------------------------------------------------------
module piano_inst_lut (
    input  wire [1:0]  inst,
    output reg  [16:0] ham_gain_q16,
    output reg  [1:0]  ksh_ofs_enc
);

    always @(*) begin
        case (inst)
            2'd0: begin ham_gain_q16 = 17'd19661; ksh_ofs_enc = 2'd1; end // piano
            2'd1: begin ham_gain_q16 = 17'd24000; ksh_ofs_enc = 2'd0; end // guitar
            2'd2: begin ham_gain_q16 = 17'd12000; ksh_ofs_enc = 2'd1; end // erhu
            default: begin ham_gain_q16 = 17'd19661; ksh_ofs_enc = 2'd1; end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_vib_lut —— 颤音速率（拓展② 表情维度）
//    rate 0..127 → LFO 频率 f_lfo = rate × 0.1 Hz（0 → 0，50 → 5.0 Hz，127 → 12.7 Hz）
//    输出 inc = round(f_lfo × 2^32 / fs)，直接当 32 bit 相位累加增量用
//    调制度公式见 piano_engine.v 文件头（depth → ±49.6 cent 线性）
// -----------------------------------------------------------------------------
module piano_vib_lut (
    input  wire [6:0]  rate,
    output reg  [31:0] inc
);

    always @(*) begin
        case (rate)
            7'd0: inc = 32'd0;   // f_lfo = 0.0 Hz
            7'd1: inc = 32'd4398;   // f_lfo = 0.1 Hz
            7'd2: inc = 32'd8796;   // f_lfo = 0.2 Hz
            7'd3: inc = 32'd13194;   // f_lfo = 0.3 Hz
            7'd4: inc = 32'd17592;   // f_lfo = 0.4 Hz
            7'd5: inc = 32'd21990;   // f_lfo = 0.5 Hz
            7'd6: inc = 32'd26388;   // f_lfo = 0.6 Hz
            7'd7: inc = 32'd30786;   // f_lfo = 0.7 Hz
            7'd8: inc = 32'd35184;   // f_lfo = 0.8 Hz
            7'd9: inc = 32'd39582;   // f_lfo = 0.9 Hz
            7'd10: inc = 32'd43980;   // f_lfo = 1.0 Hz
            7'd11: inc = 32'd48379;   // f_lfo = 1.1 Hz
            7'd12: inc = 32'd52777;   // f_lfo = 1.2 Hz
            7'd13: inc = 32'd57175;   // f_lfo = 1.3 Hz
            7'd14: inc = 32'd61573;   // f_lfo = 1.4 Hz
            7'd15: inc = 32'd65971;   // f_lfo = 1.5 Hz
            7'd16: inc = 32'd70369;   // f_lfo = 1.6 Hz
            7'd17: inc = 32'd74767;   // f_lfo = 1.7 Hz
            7'd18: inc = 32'd79165;   // f_lfo = 1.8 Hz
            7'd19: inc = 32'd83563;   // f_lfo = 1.9 Hz
            7'd20: inc = 32'd87961;   // f_lfo = 2.0 Hz
            7'd21: inc = 32'd92359;   // f_lfo = 2.1 Hz
            7'd22: inc = 32'd96757;   // f_lfo = 2.2 Hz
            7'd23: inc = 32'd101155;   // f_lfo = 2.3 Hz
            7'd24: inc = 32'd105553;   // f_lfo = 2.4 Hz
            7'd25: inc = 32'd109951;   // f_lfo = 2.5 Hz
            7'd26: inc = 32'd114349;   // f_lfo = 2.6 Hz
            7'd27: inc = 32'd118747;   // f_lfo = 2.7 Hz
            7'd28: inc = 32'd123145;   // f_lfo = 2.8 Hz
            7'd29: inc = 32'd127543;   // f_lfo = 2.9 Hz
            7'd30: inc = 32'd131941;   // f_lfo = 3.0 Hz
            7'd31: inc = 32'd136339;   // f_lfo = 3.1 Hz
            7'd32: inc = 32'd140737;   // f_lfo = 3.2 Hz
            7'd33: inc = 32'd145136;   // f_lfo = 3.3 Hz
            7'd34: inc = 32'd149534;   // f_lfo = 3.4 Hz
            7'd35: inc = 32'd153932;   // f_lfo = 3.5 Hz
            7'd36: inc = 32'd158330;   // f_lfo = 3.6 Hz
            7'd37: inc = 32'd162728;   // f_lfo = 3.7 Hz
            7'd38: inc = 32'd167126;   // f_lfo = 3.8 Hz
            7'd39: inc = 32'd171524;   // f_lfo = 3.9 Hz
            7'd40: inc = 32'd175922;   // f_lfo = 4.0 Hz
            7'd41: inc = 32'd180320;   // f_lfo = 4.1 Hz
            7'd42: inc = 32'd184718;   // f_lfo = 4.2 Hz
            7'd43: inc = 32'd189116;   // f_lfo = 4.3 Hz
            7'd44: inc = 32'd193514;   // f_lfo = 4.4 Hz
            7'd45: inc = 32'd197912;   // f_lfo = 4.5 Hz
            7'd46: inc = 32'd202310;   // f_lfo = 4.6 Hz
            7'd47: inc = 32'd206708;   // f_lfo = 4.7 Hz
            7'd48: inc = 32'd211106;   // f_lfo = 4.8 Hz
            7'd49: inc = 32'd215504;   // f_lfo = 4.9 Hz
            7'd50: inc = 32'd219902;   // f_lfo = 5.0 Hz
            7'd51: inc = 32'd224300;   // f_lfo = 5.1 Hz
            7'd52: inc = 32'd228698;   // f_lfo = 5.2 Hz
            7'd53: inc = 32'd233096;   // f_lfo = 5.3 Hz
            7'd54: inc = 32'd237495;   // f_lfo = 5.4 Hz
            7'd55: inc = 32'd241893;   // f_lfo = 5.5 Hz
            7'd56: inc = 32'd246291;   // f_lfo = 5.6 Hz
            7'd57: inc = 32'd250689;   // f_lfo = 5.7 Hz
            7'd58: inc = 32'd255087;   // f_lfo = 5.8 Hz
            7'd59: inc = 32'd259485;   // f_lfo = 5.9 Hz
            7'd60: inc = 32'd263883;   // f_lfo = 6.0 Hz
            7'd61: inc = 32'd268281;   // f_lfo = 6.1 Hz
            7'd62: inc = 32'd272679;   // f_lfo = 6.2 Hz
            7'd63: inc = 32'd277077;   // f_lfo = 6.3 Hz
            7'd64: inc = 32'd281475;   // f_lfo = 6.4 Hz
            7'd65: inc = 32'd285873;   // f_lfo = 6.5 Hz
            7'd66: inc = 32'd290271;   // f_lfo = 6.6 Hz
            7'd67: inc = 32'd294669;   // f_lfo = 6.7 Hz
            7'd68: inc = 32'd299067;   // f_lfo = 6.8 Hz
            7'd69: inc = 32'd303465;   // f_lfo = 6.9 Hz
            7'd70: inc = 32'd307863;   // f_lfo = 7.0 Hz
            7'd71: inc = 32'd312261;   // f_lfo = 7.1 Hz
            7'd72: inc = 32'd316659;   // f_lfo = 7.2 Hz
            7'd73: inc = 32'd321057;   // f_lfo = 7.3 Hz
            7'd74: inc = 32'd325455;   // f_lfo = 7.4 Hz
            7'd75: inc = 32'd329853;   // f_lfo = 7.5 Hz
            7'd76: inc = 32'd334252;   // f_lfo = 7.6 Hz
            7'd77: inc = 32'd338650;   // f_lfo = 7.7 Hz
            7'd78: inc = 32'd343048;   // f_lfo = 7.8 Hz
            7'd79: inc = 32'd347446;   // f_lfo = 7.9 Hz
            7'd80: inc = 32'd351844;   // f_lfo = 8.0 Hz
            7'd81: inc = 32'd356242;   // f_lfo = 8.1 Hz
            7'd82: inc = 32'd360640;   // f_lfo = 8.2 Hz
            7'd83: inc = 32'd365038;   // f_lfo = 8.3 Hz
            7'd84: inc = 32'd369436;   // f_lfo = 8.4 Hz
            7'd85: inc = 32'd373834;   // f_lfo = 8.5 Hz
            7'd86: inc = 32'd378232;   // f_lfo = 8.6 Hz
            7'd87: inc = 32'd382630;   // f_lfo = 8.7 Hz
            7'd88: inc = 32'd387028;   // f_lfo = 8.8 Hz
            7'd89: inc = 32'd391426;   // f_lfo = 8.9 Hz
            7'd90: inc = 32'd395824;   // f_lfo = 9.0 Hz
            7'd91: inc = 32'd400222;   // f_lfo = 9.1 Hz
            7'd92: inc = 32'd404620;   // f_lfo = 9.2 Hz
            7'd93: inc = 32'd409018;   // f_lfo = 9.3 Hz
            7'd94: inc = 32'd413416;   // f_lfo = 9.4 Hz
            7'd95: inc = 32'd417814;   // f_lfo = 9.5 Hz
            7'd96: inc = 32'd422212;   // f_lfo = 9.6 Hz
            7'd97: inc = 32'd426611;   // f_lfo = 9.7 Hz
            7'd98: inc = 32'd431009;   // f_lfo = 9.8 Hz
            7'd99: inc = 32'd435407;   // f_lfo = 9.9 Hz
            7'd100: inc = 32'd439805;   // f_lfo = 10.0 Hz
            7'd101: inc = 32'd444203;   // f_lfo = 10.1 Hz
            7'd102: inc = 32'd448601;   // f_lfo = 10.2 Hz
            7'd103: inc = 32'd452999;   // f_lfo = 10.3 Hz
            7'd104: inc = 32'd457397;   // f_lfo = 10.4 Hz
            7'd105: inc = 32'd461795;   // f_lfo = 10.5 Hz
            7'd106: inc = 32'd466193;   // f_lfo = 10.6 Hz
            7'd107: inc = 32'd470591;   // f_lfo = 10.7 Hz
            7'd108: inc = 32'd474989;   // f_lfo = 10.8 Hz
            7'd109: inc = 32'd479387;   // f_lfo = 10.9 Hz
            7'd110: inc = 32'd483785;   // f_lfo = 11.0 Hz
            7'd111: inc = 32'd488183;   // f_lfo = 11.1 Hz
            7'd112: inc = 32'd492581;   // f_lfo = 11.2 Hz
            7'd113: inc = 32'd496979;   // f_lfo = 11.3 Hz
            7'd114: inc = 32'd501377;   // f_lfo = 11.4 Hz
            7'd115: inc = 32'd505775;   // f_lfo = 11.5 Hz
            7'd116: inc = 32'd510173;   // f_lfo = 11.6 Hz
            7'd117: inc = 32'd514571;   // f_lfo = 11.7 Hz
            7'd118: inc = 32'd518969;   // f_lfo = 11.8 Hz
            7'd119: inc = 32'd523368;   // f_lfo = 11.9 Hz
            7'd120: inc = 32'd527766;   // f_lfo = 12.0 Hz
            7'd121: inc = 32'd532164;   // f_lfo = 12.1 Hz
            7'd122: inc = 32'd536562;   // f_lfo = 12.2 Hz
            7'd123: inc = 32'd540960;   // f_lfo = 12.3 Hz
            7'd124: inc = 32'd545358;   // f_lfo = 12.4 Hz
            7'd125: inc = 32'd549756;   // f_lfo = 12.5 Hz
            7'd126: inc = 32'd554154;   // f_lfo = 12.6 Hz
            7'd127: inc = 32'd558552;   // f_lfo = 12.7 Hz
            default: inc = 32'd0;
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_glide_lut —— 滑音时长（拓展② 表情维度）
//    t 0..127 → 时长 t_glide = t × 4 ms（127 → 508 ms，0 → 立即跳变）
//    输出 r = round(2^24 / N)，N = 该时长的采样点数（16 bit，误差 ≤ 0.15%）
//    RTL: step = (delta × r) >> 24 ⇒ 每采样点线性推进（一次 17×16 乘法，无除法器）
//    ⚠️ 用 Q24 而不是 Q32：N<2^16 ⇒ 2^24/N 天然只有 16 bit，乘法小一个数量级；
//      用 Q32 会变成 33×33 乘法，单周期收敛不了（MODE=1 时序违例元凶之一）。
// -----------------------------------------------------------------------------
module piano_glide_lut (
    input  wire [6:0]  t,
    output reg  [15:0] recip
);

    always @(*) begin
        case (t)
            7'd0: recip = 16'd65535;  // N = 1 采样 = 0.0 ms
            7'd1: recip = 16'd42908;  // N = 391 采样 = 4.0 ms
            7'd2: recip = 16'd21482;  // N = 781 采样 = 8.0 ms
            7'd3: recip = 16'd14315;  // N = 1172 采样 = 12.0 ms
            7'd4: recip = 16'd10741;  // N = 1562 采样 = 16.0 ms
            7'd5: recip = 16'd8590;  // N = 1953 采样 = 20.0 ms
            7'd6: recip = 16'd7158;  // N = 2344 采样 = 24.0 ms
            7'd7: recip = 16'd6137;  // N = 2734 采样 = 28.0 ms
            7'd8: recip = 16'd5369;  // N = 3125 采样 = 32.0 ms
            7'd9: recip = 16'd4772;  // N = 3516 采样 = 36.0 ms
            7'd10: recip = 16'd4295;  // N = 3906 采样 = 40.0 ms
            7'd11: recip = 16'd3904;  // N = 4297 采样 = 44.0 ms
            7'd12: recip = 16'd3579;  // N = 4688 采样 = 48.0 ms
            7'd13: recip = 16'd3304;  // N = 5078 采样 = 52.0 ms
            7'd14: recip = 16'd3068;  // N = 5469 采样 = 56.0 ms
            7'd15: recip = 16'd2863;  // N = 5859 采样 = 60.0 ms
            7'd16: recip = 16'd2684;  // N = 6250 采样 = 64.0 ms
            7'd17: recip = 16'd2526;  // N = 6641 采样 = 68.0 ms
            7'd18: recip = 16'd2386;  // N = 7031 采样 = 72.0 ms
            7'd19: recip = 16'd2260;  // N = 7422 采样 = 76.0 ms
            7'd20: recip = 16'd2148;  // N = 7812 采样 = 80.0 ms
            7'd21: recip = 16'd2045;  // N = 8203 采样 = 84.0 ms
            7'd22: recip = 16'd1952;  // N = 8594 采样 = 88.0 ms
            7'd23: recip = 16'd1867;  // N = 8984 采样 = 92.0 ms
            7'd24: recip = 16'd1790;  // N = 9375 采样 = 96.0 ms
            7'd25: recip = 16'd1718;  // N = 9766 采样 = 100.0 ms
            7'd26: recip = 16'd1652;  // N = 10156 采样 = 104.0 ms
            7'd27: recip = 16'd1591;  // N = 10547 采样 = 108.0 ms
            7'd28: recip = 16'd1534;  // N = 10938 采样 = 112.0 ms
            7'd29: recip = 16'd1481;  // N = 11328 采样 = 116.0 ms
            7'd30: recip = 16'd1432;  // N = 11719 采样 = 120.0 ms
            7'd31: recip = 16'd1386;  // N = 12109 采样 = 124.0 ms
            7'd32: recip = 16'd1342;  // N = 12500 采样 = 128.0 ms
            7'd33: recip = 16'd1301;  // N = 12891 采样 = 132.0 ms
            7'd34: recip = 16'd1263;  // N = 13281 采样 = 136.0 ms
            7'd35: recip = 16'd1227;  // N = 13672 采样 = 140.0 ms
            7'd36: recip = 16'd1193;  // N = 14063 采样 = 144.0 ms
            7'd37: recip = 16'd1161;  // N = 14453 采样 = 148.0 ms
            7'd38: recip = 16'd1130;  // N = 14844 采样 = 152.0 ms
            7'd39: recip = 16'd1101;  // N = 15234 采样 = 156.0 ms
            7'd40: recip = 16'd1074;  // N = 15625 采样 = 160.0 ms
            7'd41: recip = 16'd1048;  // N = 16016 采样 = 164.0 ms
            7'd42: recip = 16'd1023;  // N = 16406 采样 = 168.0 ms
            7'd43: recip = 16'd999;  // N = 16797 采样 = 172.0 ms
            7'd44: recip = 16'd976;  // N = 17188 采样 = 176.0 ms
            7'd45: recip = 16'd954;  // N = 17578 采样 = 180.0 ms
            7'd46: recip = 16'd934;  // N = 17969 采样 = 184.0 ms
            7'd47: recip = 16'd914;  // N = 18359 采样 = 188.0 ms
            7'd48: recip = 16'd895;  // N = 18750 采样 = 192.0 ms
            7'd49: recip = 16'd877;  // N = 19141 采样 = 196.0 ms
            7'd50: recip = 16'd859;  // N = 19531 采样 = 200.0 ms
            7'd51: recip = 16'd842;  // N = 19922 采样 = 204.0 ms
            7'd52: recip = 16'd826;  // N = 20312 采样 = 208.0 ms
            7'd53: recip = 16'd810;  // N = 20703 采样 = 212.0 ms
            7'd54: recip = 16'd795;  // N = 21094 采样 = 216.0 ms
            7'd55: recip = 16'd781;  // N = 21484 采样 = 220.0 ms
            7'd56: recip = 16'd767;  // N = 21875 采样 = 224.0 ms
            7'd57: recip = 16'd753;  // N = 22266 采样 = 228.0 ms
            7'd58: recip = 16'd741;  // N = 22656 采样 = 232.0 ms
            7'd59: recip = 16'd728;  // N = 23047 采样 = 236.0 ms
            7'd60: recip = 16'd716;  // N = 23438 采样 = 240.0 ms
            7'd61: recip = 16'd704;  // N = 23828 采样 = 244.0 ms
            7'd62: recip = 16'd693;  // N = 24219 采样 = 248.0 ms
            7'd63: recip = 16'd682;  // N = 24609 采样 = 252.0 ms
            7'd64: recip = 16'd671;  // N = 25000 采样 = 256.0 ms
            7'd65: recip = 16'd661;  // N = 25391 采样 = 260.0 ms
            7'd66: recip = 16'd651;  // N = 25781 采样 = 264.0 ms
            7'd67: recip = 16'd641;  // N = 26172 采样 = 268.0 ms
            7'd68: recip = 16'd632;  // N = 26563 采样 = 272.0 ms
            7'd69: recip = 16'd622;  // N = 26953 采样 = 276.0 ms
            7'd70: recip = 16'd614;  // N = 27344 采样 = 280.0 ms
            7'd71: recip = 16'd605;  // N = 27734 采样 = 284.0 ms
            7'd72: recip = 16'd597;  // N = 28125 采样 = 288.0 ms
            7'd73: recip = 16'd588;  // N = 28516 采样 = 292.0 ms
            7'd74: recip = 16'd580;  // N = 28906 采样 = 296.0 ms
            7'd75: recip = 16'd573;  // N = 29297 采样 = 300.0 ms
            7'd76: recip = 16'd565;  // N = 29688 采样 = 304.0 ms
            7'd77: recip = 16'd558;  // N = 30078 采样 = 308.0 ms
            7'd78: recip = 16'd551;  // N = 30469 采样 = 312.0 ms
            7'd79: recip = 16'd544;  // N = 30859 采样 = 316.0 ms
            7'd80: recip = 16'd537;  // N = 31250 采样 = 320.0 ms
            7'd81: recip = 16'd530;  // N = 31641 采样 = 324.0 ms
            7'd82: recip = 16'd524;  // N = 32031 采样 = 328.0 ms
            7'd83: recip = 16'd517;  // N = 32422 采样 = 332.0 ms
            7'd84: recip = 16'd511;  // N = 32812 采样 = 336.0 ms
            7'd85: recip = 16'd505;  // N = 33203 采样 = 340.0 ms
            7'd86: recip = 16'd499;  // N = 33594 采样 = 344.0 ms
            7'd87: recip = 16'd494;  // N = 33984 采样 = 348.0 ms
            7'd88: recip = 16'd488;  // N = 34375 采样 = 352.0 ms
            7'd89: recip = 16'd483;  // N = 34766 采样 = 356.0 ms
            7'd90: recip = 16'd477;  // N = 35156 采样 = 360.0 ms
            7'd91: recip = 16'd472;  // N = 35547 采样 = 364.0 ms
            7'd92: recip = 16'd467;  // N = 35938 采样 = 368.0 ms
            7'd93: recip = 16'd462;  // N = 36328 采样 = 372.0 ms
            7'd94: recip = 16'd457;  // N = 36719 采样 = 376.0 ms
            7'd95: recip = 16'd452;  // N = 37109 采样 = 380.0 ms
            7'd96: recip = 16'd447;  // N = 37500 采样 = 384.0 ms
            7'd97: recip = 16'd443;  // N = 37891 采样 = 388.0 ms
            7'd98: recip = 16'd438;  // N = 38281 采样 = 392.0 ms
            7'd99: recip = 16'd434;  // N = 38672 采样 = 396.0 ms
            7'd100: recip = 16'd430;  // N = 39062 采样 = 400.0 ms
            7'd101: recip = 16'd425;  // N = 39453 采样 = 404.0 ms
            7'd102: recip = 16'd421;  // N = 39844 采样 = 408.0 ms
            7'd103: recip = 16'd417;  // N = 40234 采样 = 412.0 ms
            7'd104: recip = 16'd413;  // N = 40625 采样 = 416.0 ms
            7'd105: recip = 16'd409;  // N = 41016 采样 = 420.0 ms
            7'd106: recip = 16'd405;  // N = 41406 采样 = 424.0 ms
            7'd107: recip = 16'd401;  // N = 41797 采样 = 428.0 ms
            7'd108: recip = 16'd398;  // N = 42188 采样 = 432.0 ms
            7'd109: recip = 16'd394;  // N = 42578 采样 = 436.0 ms
            7'd110: recip = 16'd390;  // N = 42969 采样 = 440.0 ms
            7'd111: recip = 16'd387;  // N = 43359 采样 = 444.0 ms
            7'd112: recip = 16'd383;  // N = 43750 采样 = 448.0 ms
            7'd113: recip = 16'd380;  // N = 44141 采样 = 452.0 ms
            7'd114: recip = 16'd377;  // N = 44531 采样 = 456.0 ms
            7'd115: recip = 16'd373;  // N = 44922 采样 = 460.0 ms
            7'd116: recip = 16'd370;  // N = 45312 采样 = 464.0 ms
            7'd117: recip = 16'd367;  // N = 45703 采样 = 468.0 ms
            7'd118: recip = 16'd364;  // N = 46094 采样 = 472.0 ms
            7'd119: recip = 16'd361;  // N = 46484 采样 = 476.0 ms
            7'd120: recip = 16'd358;  // N = 46875 采样 = 480.0 ms
            7'd121: recip = 16'd355;  // N = 47266 采样 = 484.0 ms
            7'd122: recip = 16'd352;  // N = 47656 采样 = 488.0 ms
            7'd123: recip = 16'd349;  // N = 48047 采样 = 492.0 ms
            7'd124: recip = 16'd346;  // N = 48438 采样 = 496.0 ms
            7'd125: recip = 16'd344;  // N = 48828 采样 = 500.0 ms
            7'd126: recip = 16'd341;  // N = 49219 采样 = 504.0 ms
            7'd127: recip = 16'd338;  // N = 49609 采样 = 508.0 ms
            default: recip = 16'd0;
        endcase
    end

endmodule

`default_nettype wire
