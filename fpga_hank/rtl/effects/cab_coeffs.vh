// ============================================================================
// cab_coeffs.vh —— **由 tools/gen/gen_cab_coeffs.py 自动生成，请勿手改**
//
// 吉他箱体模拟：两级一阶高通(12dB/oct) -> 峰值均衡 -> 二阶低通
// fs = 97656.25 Hz（= 50 MHz / 512）  系数 = Q2.18（21 bit 有符号）
//
// ⚠️ 为什么不用 IR 卷积：赛题红线'严禁预录 PCM'，IR 本质是实测样本；
//    且大抽头 FIR 与本工程 MODE=1 的 +0.009 ns 裕量冲突。
//    参数化 IIR 让'系数怎么来的'可自证（见生成脚本与设计文档）。
// ⚠️ 低频为什么用两级一阶而不是二阶双二阶：fs=97.656kHz 时 90Hz 的二阶极点
//    半径达 0.9964（贴近 z=1，量化可能推到 >1 而失稳）；一阶极点 0.9942 且
//    量化步长远小于 (1-a)，既稳又准。**这是自检报出来的，不是猜的。**
// ⚠️ 绝不要把系数改成 signed [7:0] —— 本项目已因'装不下 >127'翻过车。
// ============================================================================

// ---- cab_sel = 2'd1 : 4x12 密闭 ----
// 已按 1 kHz = 0 dB 归一化（g = 0.943634 乘进 b0/b1/b2）
localparam signed [20:0] CAB1_HP1_A  = 21'sd260635;
localparam signed [20:0] CAB1_HP2_A  = 21'sd260635;
localparam signed [20:0] CAB1_EQ_B0 = 21'sd256889;
localparam signed [20:0] CAB1_EQ_B1 = -21'sd463706;
localparam signed [20:0] CAB1_EQ_B2 = 21'sd213381;
localparam signed [20:0] CAB1_EQ_A1 = -21'sd491404;
localparam signed [20:0] CAB1_EQ_A2 = 21'sd236217;
localparam signed [20:0] CAB1_LP_B0 = 21'sd4808;
localparam signed [20:0] CAB1_LP_B1 = 21'sd9616;
localparam signed [20:0] CAB1_LP_B2 = 21'sd4808;
localparam signed [20:0] CAB1_LP_A1 = -21'sd410387;
localparam signed [20:0] CAB1_LP_A2 = 21'sd168623;
//   一阶高通#1 极点半径 |p| = 0.994243
//   一阶高通#2 极点半径 |p| = 0.994243
//   峰值均衡 极点半径 |p| = 0.949260
//   二阶低通 极点半径 |p| = 0.802026

// ---- cab_sel = 2'd2 : 1x12 开放 ----
// 已按 1 kHz = 0 dB 归一化（g = 0.983083 乘进 b0/b1/b2）
localparam signed [20:0] CAB2_HP1_A  = 21'sd260302;
localparam signed [20:0] CAB2_HP2_A  = 21'sd260302;
localparam signed [20:0] CAB2_EQ_B0 = 21'sd266129;
localparam signed [20:0] CAB2_EQ_B1 = -21'sd464577;
localparam signed [20:0] CAB2_EQ_B2 = 21'sd208471;
localparam signed [20:0] CAB2_EQ_A1 = -21'sd472571;
localparam signed [20:0] CAB2_EQ_A2 = 21'sd220623;
localparam signed [20:0] CAB2_LP_B0 = 21'sd6400;
localparam signed [20:0] CAB2_LP_B1 = 21'sd12800;
localparam signed [20:0] CAB2_LP_B2 = 21'sd6400;
localparam signed [20:0] CAB2_LP_A1 = -21'sd394224;
localparam signed [20:0] CAB2_LP_A2 = 21'sd158120;
//   一阶高通#1 极点半径 |p| = 0.992972
//   一阶高通#2 极点半径 |p| = 0.992972
//   峰值均衡 极点半径 |p| = 0.917394
//   二阶低通 极点半径 |p| = 0.776646

// 稳定性总判据：二阶节最大极点半径 = 0.949260 （须 < 0.99）
//               一阶节最小量化余量 = 0.005757 （须 > 0，即量化后仍 < 1）
// 量化误差总判据：Q2.18 vs 理想，全频段最大偏差 = 0.0021 dB （须 < 0.5 dB）
