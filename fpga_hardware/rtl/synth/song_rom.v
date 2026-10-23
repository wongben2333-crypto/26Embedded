// =============================================================================
//  song_rom.v —— 演示模式曲目 ROM（5 首，纯 `case` 常量表）
//
//  ★ 本 ROM 存的是【乐谱】（音符编号 + 时值），不是音频采样。
//    ROM 里没有任何 PCM / 波形数据 —— 声音由振荡器 + ADSR 逐样本实时合成，
//    符合赛题红线"严禁播放预录 PCM / 预置推流 / 整段录音触发"。
//
//  ⚠️ 本文件由 tools/gen/gen_song_rom.py 生成，请勿手工编辑。
//     重新生成：python tools/gen/gen_song_rom.py --write
//
//  ★ 为什么不用 $readmemh：Gowin 上 ROM 初始化有坑（见 wave_rom.v 记录），
//    本工程交付物一律用生成的 case 常量表，不依赖外部 .vh/.hex。
//    本 ROM 共 209 项，与 wave_rom.v（1024 项，已实测可综合）同量级。
//
//  ===========================================================================
//  ★★ 曲目版权状态（★ 如实记录，请勿删改 ★）★★
//  ===========================================================================
//  本项目含一首【未获授权】的流行曲，这是**使用者的知情决定**，
//  **风险由使用者承担**。如实记录在案，不掩盖、不含糊。
//
//   [0] 我落泪情绪零碎 (副歌 m.29-31)         ⛔ 受版权保护，本队未获授权
//        ⛔ 本曲为【受版权保护的流行歌曲】。乐谱由【使用者本人】从 EveryonePiano.com 获取并提供（编配者 JenaV）。【本队未获授权】（即：从未获得任何授权）。纳入演示模式是使用者的【知情决定】，版权风险由使用者承担。—— 与此前 Faded 的处理方式一致（该曲已按裁决删除）：如实记录、不隐瞒、不用'改编/引用'淡化。读谱方式：逐小节 3 倍放大 + 像素级判读，并用歌词音节数交叉验证（详见 _research/songs/WO-LUO-LEI-NOTES.md）。
//   [1] Ode to Joy (欢乐颂)             ✅ 公有领域
//        Beethoven《第九交响曲》第四乐章主题，作者 1827 年去世已逾 70 年，公有领域。音符数据由本队自行整理，未复制第三方文件。
//   [2] Twinkle Twinkle (小星星)        ✅ 公有领域
//        法国歌曲《Ah! vous dirai-je, maman》，1761 年出版，公有领域。音符数据由本队自行整理，未复制第三方文件。
//   [3] Jingle Bells (铃儿响叮当)         ✅ 公有领域
//        James Lord Pierpont，1857 年，公有领域。音符数据由本队自行整理，未复制第三方文件。
//   [4] Für Elise (致爱丽丝)             ✅ 公有领域
//        Beethoven，1810 年作、1867 年出版，作者 1827 年去世已逾 70 年，公有领域。音符数据由本队自行整理，未复制第三方文件。
//
//   ⚠️ 上表 1 首标 ⛔ 的曲目为使用者知情决定纳入，风险由使用者承担；
//      若要移除，在 tools/gen/gen_song_rom.py 的 SONGS 里删掉对应项并重新生成即可，RTL 无需改动。
//
//  ---------------------------------------------------------------------------
//  ★ 音符数据来源（逐首交代）
//    · 公有领域曲目：由本队**自行整理**，未复制任何第三方文件。
//    · 我落泪情绪零碎：乐谱由**使用者本人**提供（EveryonePiano.com，编配 JenaV），
//      本队**逐小节 3 倍放大 + 像素级判读**自行读谱，未复制任何第三方数据文件；
//      并用歌词音节数交叉验证（详见 _research/songs/WO-LUO-LEI-NOTES.md）。
//    ⛔ [2026-10-06 已删除] Faded：原条目取自本队 `26Embedded/fpga_spark/sim/
//       simulate_faded_guitar.py`，因**数据源被用户亲耳否掉**、副歌起点从未确认，
//       经 Lead 裁决**彻底删除**（不留空占位）。删除后各曲下标整体前移，
//       [0] 由 Faded 变为《欢乐颂》(公有领域)。
//    ⛔ 调研中 star 最高的开源蜂鸣器曲库 robsoncouto/arduino-songs 经 GitHub API
//       实测 `license: null`（无许可证文件），其 README 口头许可无法举证，
//       因此本工程**没有使用它的任何数据文件**，只在"音符怎么编码、怎么断句"上
//       借鉴公开结构思路。
//    ✅ 借鉴的两个参考工程均为 **MIT** 许可（只学结构，不抄数据）：
//         sirius1242/musicbox（Verilog 八音盒，LICENSE 原文已核对）
//             → 乐谱文本编码 + "音符响满时值后再插 1 ms 静音"的断句做法
//         JN513/Simple-FPGA-Music-Player-with-PWM（API 实测 spdx_id = MIT）
//             → 乐谱驱动的状态机结构；它是 PWM 单音输出，与本工程
//               I2S/PT8211 通路无关，未借鉴其音频通路
//    ⛔ 未使用 MAESTRO（CC BY-NC-SA 4.0，非商业 + 传染性）。
//
//  ---------------------------------------------------------------------------
//  曲目清单
//    #  曲名                        BPM  音符数  时长    授权
//    0  我落泪情绪零碎 (副歌 m.29-31)        67     18   10.7s  COPYRIGHT
//    1  Ode to Joy (欢乐颂)           100     62   38.4s  PD
//    2  Twinkle Twinkle (小星星)      120     42   24.0s  PD
//    3  Jingle Bells (铃儿响叮当)       140     50   27.4s  PD
//    4  Für Elise (致爱丽丝)           120     37    6.1s  PD
//
//  ★ 与 song_player.v 的一致性：歌曲总数由本模块的 n_songs 输出端口给出，
//    播放器直接透传到 song_count，**不存在两处硬编码不同步的可能**。
// =============================================================================
`default_nettype none

module song_rom (
    input  wire        clk,
    input  wire [3:0]  song,      // 歌曲序号 0..4
    input  wire [8:0]  addr,      // 音符序号 0..511
    output reg  [34:0]  dout,      // {is_end, note, vel, dur}
    output wire [3:0]  n_songs    // 本 ROM 里实际有几首歌（给 song_count）
);

    localparam [3:0] N_SONGS = 4'd5;
    assign n_songs = N_SONGS;

    // 注：addr 是【组合】地址（由播放器直接给出寄存器值），本 ROM 同步读出，
    //     因此 dout 比 addr 晚一拍 —— 播放器用 S_LOAD→S_LATCH 两拍对齐，
    //     详见 song_player.v 的流水说明。这是与 wave_rom.v 相同的读时序。
    always @(posedge clk) begin
        case ({song, addr})
            // ---- song 0 : 我落泪情绪零碎 (副歌 m.29-31) ----
            13'd0   : dout <= 35'h1FE42AB3B;  // D#4   dur=174907
            13'd1   : dout <= 35'h1EE40AACF;  // C#4   dur=43727
            13'd2   : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd3   : dout <= 35'h20640AACF;  // E4    dur=43727
            13'd4   : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd5   : dout <= 35'h1FE42AB3B;  // D#4   dur=174907
            13'd6   : dout <= 35'h1EE40AACF;  // C#4   dur=43727
            13'd7   : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd8   : dout <= 35'h20640AACF;  // E4    dur=43727
            13'd9   : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd10  : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd11  : dout <= 35'h1EE40AACF;  // C#4   dur=43727
            13'd12  : dout <= 35'h1DE40AACF;  // B3    dur=43727
            13'd13  : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd14  : dout <= 35'h1FE40AACF;  // D#4   dur=43727
            13'd15  : dout <= 35'h22640AACF;  // G#4   dur=43727
            13'd16  : dout <= 35'h22640AACF;  // G#4   dur=43727
            13'd17  : dout <= 35'h21640AACF;  // F#4   dur=43727
            // ---- song 1 : Ode to Joy (欢乐颂) ----
            13'd512 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd513 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd514 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd515 : dout <= 35'h21E40E4E2;  // G4    dur=58594
            13'd516 : dout <= 35'h21E40E4E2;  // G4    dur=58594
            13'd517 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd518 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd519 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd520 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd521 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd522 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd523 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd524 : dout <= 35'h206415753;  // E4    dur=87891
            13'd525 : dout <= 35'h1F6407271;  // D4    dur=29297
            13'd526 : dout <= 35'h1F641C9C4;  // D4    dur=117188
            13'd527 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd528 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd529 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd530 : dout <= 35'h21E40E4E2;  // G4    dur=58594
            13'd531 : dout <= 35'h21E40E4E2;  // G4    dur=58594
            13'd532 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd533 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd534 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd535 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd536 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd537 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd538 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd539 : dout <= 35'h1F6415753;  // D4    dur=87891
            13'd540 : dout <= 35'h1E6407271;  // C4    dur=29297
            13'd541 : dout <= 35'h1E641C9C4;  // C4    dur=117188
            13'd542 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd543 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd544 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd545 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd546 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd547 : dout <= 35'h206407271;  // E4    dur=29297
            13'd548 : dout <= 35'h20E407271;  // F4    dur=29297
            13'd549 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd550 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd551 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd552 : dout <= 35'h206407271;  // E4    dur=29297
            13'd553 : dout <= 35'h20E407271;  // F4    dur=29297
            13'd554 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd555 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd556 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd557 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd558 : dout <= 35'h1BE41C9C4;  // G3    dur=117188
            13'd559 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd560 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd561 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd562 : dout <= 35'h21E40E4E2;  // G4    dur=58594
            13'd563 : dout <= 35'h21E40E4E2;  // G4    dur=58594
            13'd564 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd565 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd566 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd567 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd568 : dout <= 35'h1E640E4E2;  // C4    dur=58594
            13'd569 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd570 : dout <= 35'h20640E4E2;  // E4    dur=58594
            13'd571 : dout <= 35'h1F6415753;  // D4    dur=87891
            13'd572 : dout <= 35'h1E6407271;  // C4    dur=29297
            13'd573 : dout <= 35'h1E641C9C4;  // C4    dur=117188
            // ---- song 2 : Twinkle Twinkle (小星星) ----
            13'd1024: dout <= 35'h1E640BEBC;  // C4    dur=48828
            13'd1025: dout <= 35'h1E640BEBC;  // C4    dur=48828
            13'd1026: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1027: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1028: dout <= 35'h22E40BEBC;  // A4    dur=48828
            13'd1029: dout <= 35'h22E40BEBC;  // A4    dur=48828
            13'd1030: dout <= 35'h21E417D78;  // G4    dur=97656
            13'd1031: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1032: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1033: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1034: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1035: dout <= 35'h1F640BEBC;  // D4    dur=48828
            13'd1036: dout <= 35'h1F640BEBC;  // D4    dur=48828
            13'd1037: dout <= 35'h1E6417D78;  // C4    dur=97656
            13'd1038: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1039: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1040: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1041: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1042: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1043: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1044: dout <= 35'h1F6417D78;  // D4    dur=97656
            13'd1045: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1046: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1047: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1048: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1049: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1050: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1051: dout <= 35'h1F6417D78;  // D4    dur=97656
            13'd1052: dout <= 35'h1E640BEBC;  // C4    dur=48828
            13'd1053: dout <= 35'h1E640BEBC;  // C4    dur=48828
            13'd1054: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1055: dout <= 35'h21E40BEBC;  // G4    dur=48828
            13'd1056: dout <= 35'h22E40BEBC;  // A4    dur=48828
            13'd1057: dout <= 35'h22E40BEBC;  // A4    dur=48828
            13'd1058: dout <= 35'h21E417D78;  // G4    dur=97656
            13'd1059: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1060: dout <= 35'h20E40BEBC;  // F4    dur=48828
            13'd1061: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1062: dout <= 35'h20640BEBC;  // E4    dur=48828
            13'd1063: dout <= 35'h1F640BEBC;  // D4    dur=48828
            13'd1064: dout <= 35'h1F640BEBC;  // D4    dur=48828
            13'd1065: dout <= 35'h1E6417D78;  // C4    dur=97656
            // ---- song 3 : Jingle Bells (铃儿响叮当) ----
            13'd1536: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1537: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1538: dout <= 35'h2064146F9;  // E4    dur=83705
            13'd1539: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1540: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1541: dout <= 35'h2064146F9;  // E4    dur=83705
            13'd1542: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1543: dout <= 35'h21E40A37D;  // G4    dur=41853
            13'd1544: dout <= 35'h1E640A37D;  // C4    dur=41853
            13'd1545: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1546: dout <= 35'h206428DF3;  // E4    dur=167411
            13'd1547: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1548: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1549: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1550: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1551: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1552: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1553: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1554: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1555: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1556: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1557: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1558: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1559: dout <= 35'h1F64146F9;  // D4    dur=83705
            13'd1560: dout <= 35'h21E4146F9;  // G4    dur=83705
            13'd1561: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1562: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1563: dout <= 35'h2064146F9;  // E4    dur=83705
            13'd1564: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1565: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1566: dout <= 35'h2064146F9;  // E4    dur=83705
            13'd1567: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1568: dout <= 35'h21E40A37D;  // G4    dur=41853
            13'd1569: dout <= 35'h1E640A37D;  // C4    dur=41853
            13'd1570: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1571: dout <= 35'h206428DF3;  // E4    dur=167411
            13'd1572: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1573: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1574: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1575: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1576: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1577: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1578: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1579: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1580: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1581: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1582: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1583: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1584: dout <= 35'h1F64146F9;  // D4    dur=83705
            13'd1585: dout <= 35'h21E4146F9;  // G4    dur=83705
            // ---- song 4 : Für Elise (致爱丽丝) ----
            13'd2048: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2049: dout <= 35'h25E402FAF;  // D#5   dur=12207
            13'd2050: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2051: dout <= 35'h25E402FAF;  // D#5   dur=12207
            13'd2052: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2053: dout <= 35'h23E402FAF;  // B4    dur=12207
            13'd2054: dout <= 35'h256402FAF;  // D5    dur=12207
            13'd2055: dout <= 35'h246402FAF;  // C5    dur=12207
            13'd2056: dout <= 35'h22E408F0D;  // A4    dur=36621
            13'd2057: dout <= 35'h1E6402FAF;  // C4    dur=12207
            13'd2058: dout <= 35'h206402FAF;  // E4    dur=12207
            13'd2059: dout <= 35'h22E402FAF;  // A4    dur=12207
            13'd2060: dout <= 35'h23E408F0D;  // B4    dur=36621
            13'd2061: dout <= 35'h206402FAF;  // E4    dur=12207
            13'd2062: dout <= 35'h226402FAF;  // G#4   dur=12207
            13'd2063: dout <= 35'h23E402FAF;  // B4    dur=12207
            13'd2064: dout <= 35'h246408F0D;  // C5    dur=36621
            13'd2065: dout <= 35'h206402FAF;  // E4    dur=12207
            13'd2066: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2067: dout <= 35'h25E402FAF;  // D#5   dur=12207
            13'd2068: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2069: dout <= 35'h25E402FAF;  // D#5   dur=12207
            13'd2070: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2071: dout <= 35'h25E402FAF;  // D#5   dur=12207
            13'd2072: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2073: dout <= 35'h23E402FAF;  // B4    dur=12207
            13'd2074: dout <= 35'h256402FAF;  // D5    dur=12207
            13'd2075: dout <= 35'h246402FAF;  // C5    dur=12207
            13'd2076: dout <= 35'h22E408F0D;  // A4    dur=36621
            13'd2077: dout <= 35'h1E6402FAF;  // C4    dur=12207
            13'd2078: dout <= 35'h206402FAF;  // E4    dur=12207
            13'd2079: dout <= 35'h22E402FAF;  // A4    dur=12207
            13'd2080: dout <= 35'h23E408F0D;  // B4    dur=36621
            13'd2081: dout <= 35'h206402FAF;  // E4    dur=12207
            13'd2082: dout <= 35'h246402FAF;  // C5    dur=12207
            13'd2083: dout <= 35'h23E402FAF;  // B4    dur=12207
            13'd2084: dout <= 35'h22E408F0D;  // A4    dur=36621
            // 越界 / 未使用地址 = 曲末标记（播放器据此回到第 0 个音符）
            default: dout <= 35'h400000000;
        endcase
    end

endmodule

`default_nettype wire
