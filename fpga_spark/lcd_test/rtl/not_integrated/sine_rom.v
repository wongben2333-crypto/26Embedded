// =============================================================================
//  sine_rom.v —— 正弦查找表（第一象限 + 组合镜像，供多路振荡器时分复用）
//
//  ⚠️ 本文件由 tools/gen/gen_sine_quarters.py 生成，请勿手工编辑。
//     手工写系数极易超出 16 bit 有符号范围（曾有版本写入 36030，溢出）。
//
//  只存第一象限 256 项，其余象限用符号与镜像推导：
//      addr[9:8] = 0 -> +q[addr[7:0]]                第一象限
//      addr[9:8] = 1 -> +q[255 - addr[7:0]]          第二象限（镜像）
//      addr[9:8] = 2 -> -q[addr[7:0]]                第三象限
//      addr[9:8] = 3 -> -q[255 - addr[7:0]]          第四象限（镜像）
//
//  用组合 case 实现 => 综合成分布式 LUT ROM，可被多路同时读。
//  （赛题规定单个波表查表只算 1 个振荡器，且 BSRAM 多端口会串行化 —— 见 tone_bank.v）
//
//  格式：16 bit 有符号，量程 ±32767
//        q[i] = round(32767 * sin(pi/2 * i / 256))
// =============================================================================
`default_nettype none

module sine_rom (
    input  wire        clk,
    input  wire [9:0]  addr,
    output reg  signed [15:0] val
);

    // ⚠️ sine_q 必须先声明再使用（Verilog 不允许先用后声明）
    wire signed [15:0] sine_q [0:255];

    always @(posedge clk) begin
        case (addr[9:8])
            2'd0: val <=  sine_q[addr[7:0]];
            2'd1: val <=  sine_q[10'd255 - addr[7:0]];
            2'd2: val <= -sine_q[addr[7:0]];
            2'd3: val <= -sine_q[10'd255 - addr[7:0]];
        endcase
    end
    assign sine_q[  0] = 16'sd0;
    assign sine_q[  1] = 16'sd201;
    assign sine_q[  2] = 16'sd402;
    assign sine_q[  3] = 16'sd603;
    assign sine_q[  4] = 16'sd804;
    assign sine_q[  5] = 16'sd1005;
    assign sine_q[  6] = 16'sd1206;
    assign sine_q[  7] = 16'sd1407;
    assign sine_q[  8] = 16'sd1608;
    assign sine_q[  9] = 16'sd1809;
    assign sine_q[ 10] = 16'sd2009;
    assign sine_q[ 11] = 16'sd2210;
    assign sine_q[ 12] = 16'sd2410;
    assign sine_q[ 13] = 16'sd2611;
    assign sine_q[ 14] = 16'sd2811;
    assign sine_q[ 15] = 16'sd3012;
    assign sine_q[ 16] = 16'sd3212;
    assign sine_q[ 17] = 16'sd3412;
    assign sine_q[ 18] = 16'sd3612;
    assign sine_q[ 19] = 16'sd3811;
    assign sine_q[ 20] = 16'sd4011;
    assign sine_q[ 21] = 16'sd4210;
    assign sine_q[ 22] = 16'sd4410;
    assign sine_q[ 23] = 16'sd4609;
    assign sine_q[ 24] = 16'sd4808;
    assign sine_q[ 25] = 16'sd5007;
    assign sine_q[ 26] = 16'sd5205;
    assign sine_q[ 27] = 16'sd5404;
    assign sine_q[ 28] = 16'sd5602;
    assign sine_q[ 29] = 16'sd5800;
    assign sine_q[ 30] = 16'sd5998;
    assign sine_q[ 31] = 16'sd6195;
    assign sine_q[ 32] = 16'sd6393;
    assign sine_q[ 33] = 16'sd6590;
    assign sine_q[ 34] = 16'sd6786;
    assign sine_q[ 35] = 16'sd6983;
    assign sine_q[ 36] = 16'sd7179;
    assign sine_q[ 37] = 16'sd7375;
    assign sine_q[ 38] = 16'sd7571;
    assign sine_q[ 39] = 16'sd7767;
    assign sine_q[ 40] = 16'sd7962;
    assign sine_q[ 41] = 16'sd8157;
    assign sine_q[ 42] = 16'sd8351;
    assign sine_q[ 43] = 16'sd8545;
    assign sine_q[ 44] = 16'sd8739;
    assign sine_q[ 45] = 16'sd8933;
    assign sine_q[ 46] = 16'sd9126;
    assign sine_q[ 47] = 16'sd9319;
    assign sine_q[ 48] = 16'sd9512;
    assign sine_q[ 49] = 16'sd9704;
    assign sine_q[ 50] = 16'sd9896;
    assign sine_q[ 51] = 16'sd10087;
    assign sine_q[ 52] = 16'sd10278;
    assign sine_q[ 53] = 16'sd10469;
    assign sine_q[ 54] = 16'sd10659;
    assign sine_q[ 55] = 16'sd10849;
    assign sine_q[ 56] = 16'sd11039;
    assign sine_q[ 57] = 16'sd11228;
    assign sine_q[ 58] = 16'sd11417;
    assign sine_q[ 59] = 16'sd11605;
    assign sine_q[ 60] = 16'sd11793;
    assign sine_q[ 61] = 16'sd11980;
    assign sine_q[ 62] = 16'sd12167;
    assign sine_q[ 63] = 16'sd12353;
    assign sine_q[ 64] = 16'sd12539;
    assign sine_q[ 65] = 16'sd12725;
    assign sine_q[ 66] = 16'sd12910;
    assign sine_q[ 67] = 16'sd13094;
    assign sine_q[ 68] = 16'sd13279;
    assign sine_q[ 69] = 16'sd13462;
    assign sine_q[ 70] = 16'sd13645;
    assign sine_q[ 71] = 16'sd13828;
    assign sine_q[ 72] = 16'sd14010;
    assign sine_q[ 73] = 16'sd14191;
    assign sine_q[ 74] = 16'sd14372;
    assign sine_q[ 75] = 16'sd14553;
    assign sine_q[ 76] = 16'sd14732;
    assign sine_q[ 77] = 16'sd14912;
    assign sine_q[ 78] = 16'sd15090;
    assign sine_q[ 79] = 16'sd15269;
    assign sine_q[ 80] = 16'sd15446;
    assign sine_q[ 81] = 16'sd15623;
    assign sine_q[ 82] = 16'sd15800;
    assign sine_q[ 83] = 16'sd15976;
    assign sine_q[ 84] = 16'sd16151;
    assign sine_q[ 85] = 16'sd16325;
    assign sine_q[ 86] = 16'sd16499;
    assign sine_q[ 87] = 16'sd16673;
    assign sine_q[ 88] = 16'sd16846;
    assign sine_q[ 89] = 16'sd17018;
    assign sine_q[ 90] = 16'sd17189;
    assign sine_q[ 91] = 16'sd17360;
    assign sine_q[ 92] = 16'sd17530;
    assign sine_q[ 93] = 16'sd17700;
    assign sine_q[ 94] = 16'sd17869;
    assign sine_q[ 95] = 16'sd18037;
    assign sine_q[ 96] = 16'sd18204;
    assign sine_q[ 97] = 16'sd18371;
    assign sine_q[ 98] = 16'sd18537;
    assign sine_q[ 99] = 16'sd18703;
    assign sine_q[100] = 16'sd18868;
    assign sine_q[101] = 16'sd19032;
    assign sine_q[102] = 16'sd19195;
    assign sine_q[103] = 16'sd19357;
    assign sine_q[104] = 16'sd19519;
    assign sine_q[105] = 16'sd19680;
    assign sine_q[106] = 16'sd19841;
    assign sine_q[107] = 16'sd20000;
    assign sine_q[108] = 16'sd20159;
    assign sine_q[109] = 16'sd20317;
    assign sine_q[110] = 16'sd20475;
    assign sine_q[111] = 16'sd20631;
    assign sine_q[112] = 16'sd20787;
    assign sine_q[113] = 16'sd20942;
    assign sine_q[114] = 16'sd21096;
    assign sine_q[115] = 16'sd21250;
    assign sine_q[116] = 16'sd21403;
    assign sine_q[117] = 16'sd21554;
    assign sine_q[118] = 16'sd21705;
    assign sine_q[119] = 16'sd21856;
    assign sine_q[120] = 16'sd22005;
    assign sine_q[121] = 16'sd22154;
    assign sine_q[122] = 16'sd22301;
    assign sine_q[123] = 16'sd22448;
    assign sine_q[124] = 16'sd22594;
    assign sine_q[125] = 16'sd22739;
    assign sine_q[126] = 16'sd22884;
    assign sine_q[127] = 16'sd23027;
    assign sine_q[128] = 16'sd23170;
    assign sine_q[129] = 16'sd23311;
    assign sine_q[130] = 16'sd23452;
    assign sine_q[131] = 16'sd23592;
    assign sine_q[132] = 16'sd23731;
    assign sine_q[133] = 16'sd23870;
    assign sine_q[134] = 16'sd24007;
    assign sine_q[135] = 16'sd24143;
    assign sine_q[136] = 16'sd24279;
    assign sine_q[137] = 16'sd24413;
    assign sine_q[138] = 16'sd24547;
    assign sine_q[139] = 16'sd24680;
    assign sine_q[140] = 16'sd24811;
    assign sine_q[141] = 16'sd24942;
    assign sine_q[142] = 16'sd25072;
    assign sine_q[143] = 16'sd25201;
    assign sine_q[144] = 16'sd25329;
    assign sine_q[145] = 16'sd25456;
    assign sine_q[146] = 16'sd25582;
    assign sine_q[147] = 16'sd25708;
    assign sine_q[148] = 16'sd25832;
    assign sine_q[149] = 16'sd25955;
    assign sine_q[150] = 16'sd26077;
    assign sine_q[151] = 16'sd26198;
    assign sine_q[152] = 16'sd26319;
    assign sine_q[153] = 16'sd26438;
    assign sine_q[154] = 16'sd26556;
    assign sine_q[155] = 16'sd26674;
    assign sine_q[156] = 16'sd26790;
    assign sine_q[157] = 16'sd26905;
    assign sine_q[158] = 16'sd27019;
    assign sine_q[159] = 16'sd27133;
    assign sine_q[160] = 16'sd27245;
    assign sine_q[161] = 16'sd27356;
    assign sine_q[162] = 16'sd27466;
    assign sine_q[163] = 16'sd27575;
    assign sine_q[164] = 16'sd27683;
    assign sine_q[165] = 16'sd27790;
    assign sine_q[166] = 16'sd27896;
    assign sine_q[167] = 16'sd28001;
    assign sine_q[168] = 16'sd28105;
    assign sine_q[169] = 16'sd28208;
    assign sine_q[170] = 16'sd28310;
    assign sine_q[171] = 16'sd28411;
    assign sine_q[172] = 16'sd28510;
    assign sine_q[173] = 16'sd28609;
    assign sine_q[174] = 16'sd28706;
    assign sine_q[175] = 16'sd28803;
    assign sine_q[176] = 16'sd28898;
    assign sine_q[177] = 16'sd28992;
    assign sine_q[178] = 16'sd29085;
    assign sine_q[179] = 16'sd29177;
    assign sine_q[180] = 16'sd29268;
    assign sine_q[181] = 16'sd29358;
    assign sine_q[182] = 16'sd29447;
    assign sine_q[183] = 16'sd29534;
    assign sine_q[184] = 16'sd29621;
    assign sine_q[185] = 16'sd29706;
    assign sine_q[186] = 16'sd29791;
    assign sine_q[187] = 16'sd29874;
    assign sine_q[188] = 16'sd29956;
    assign sine_q[189] = 16'sd30037;
    assign sine_q[190] = 16'sd30117;
    assign sine_q[191] = 16'sd30195;
    assign sine_q[192] = 16'sd30273;
    assign sine_q[193] = 16'sd30349;
    assign sine_q[194] = 16'sd30424;
    assign sine_q[195] = 16'sd30498;
    assign sine_q[196] = 16'sd30571;
    assign sine_q[197] = 16'sd30643;
    assign sine_q[198] = 16'sd30714;
    assign sine_q[199] = 16'sd30783;
    assign sine_q[200] = 16'sd30852;
    assign sine_q[201] = 16'sd30919;
    assign sine_q[202] = 16'sd30985;
    assign sine_q[203] = 16'sd31050;
    assign sine_q[204] = 16'sd31113;
    assign sine_q[205] = 16'sd31176;
    assign sine_q[206] = 16'sd31237;
    assign sine_q[207] = 16'sd31297;
    assign sine_q[208] = 16'sd31356;
    assign sine_q[209] = 16'sd31414;
    assign sine_q[210] = 16'sd31470;
    assign sine_q[211] = 16'sd31526;
    assign sine_q[212] = 16'sd31580;
    assign sine_q[213] = 16'sd31633;
    assign sine_q[214] = 16'sd31685;
    assign sine_q[215] = 16'sd31736;
    assign sine_q[216] = 16'sd31785;
    assign sine_q[217] = 16'sd31833;
    assign sine_q[218] = 16'sd31880;
    assign sine_q[219] = 16'sd31926;
    assign sine_q[220] = 16'sd31971;
    assign sine_q[221] = 16'sd32014;
    assign sine_q[222] = 16'sd32057;
    assign sine_q[223] = 16'sd32098;
    assign sine_q[224] = 16'sd32137;
    assign sine_q[225] = 16'sd32176;
    assign sine_q[226] = 16'sd32213;
    assign sine_q[227] = 16'sd32250;
    assign sine_q[228] = 16'sd32285;
    assign sine_q[229] = 16'sd32318;
    assign sine_q[230] = 16'sd32351;
    assign sine_q[231] = 16'sd32382;
    assign sine_q[232] = 16'sd32412;
    assign sine_q[233] = 16'sd32441;
    assign sine_q[234] = 16'sd32469;
    assign sine_q[235] = 16'sd32495;
    assign sine_q[236] = 16'sd32521;
    assign sine_q[237] = 16'sd32545;
    assign sine_q[238] = 16'sd32567;
    assign sine_q[239] = 16'sd32589;
    assign sine_q[240] = 16'sd32609;
    assign sine_q[241] = 16'sd32628;
    assign sine_q[242] = 16'sd32646;
    assign sine_q[243] = 16'sd32663;
    assign sine_q[244] = 16'sd32678;
    assign sine_q[245] = 16'sd32692;
    assign sine_q[246] = 16'sd32705;
    assign sine_q[247] = 16'sd32717;
    assign sine_q[248] = 16'sd32728;
    assign sine_q[249] = 16'sd32737;
    assign sine_q[250] = 16'sd32745;
    assign sine_q[251] = 16'sd32752;
    assign sine_q[252] = 16'sd32757;
    assign sine_q[253] = 16'sd32761;
    assign sine_q[254] = 16'sd32765;
    assign sine_q[255] = 16'sd32766;

endmodule

`default_nettype wire
