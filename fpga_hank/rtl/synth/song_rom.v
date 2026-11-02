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
//    本 ROM 共 535 项，与 wave_rom.v（1024 项，已实测可综合）同量级。
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
//    0  我落泪情绪零碎 (副歌 m.29-31)        67     68   21.5s  COPYRIGHT
//    1  Ode to Joy (欢乐颂)           100    135   38.4s  PD
//    2  Twinkle Twinkle (小星星)      120    112   24.0s  PD
//    3  Jingle Bells (铃儿响叮当)       140    116   27.4s  PD
//    4  Für Elise (致爱丽丝)           120    104   12.0s  PD
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
            13'd0   : dout <= 35'h1644000AF;  // G#2   dur=175
            13'd1   : dout <= 35'h19C4000AF;  // D#3   dur=175
            13'd2   : dout <= 35'h1DC4000AF;  // B3    dur=175
            13'd3   : dout <= 35'h1FE42A92E;  // D#4   dur=174382
            13'd4   : dout <= 35'h1ED60AACF;  // C#4   dur=43727
            13'd5   : dout <= 35'h1FDA0AACF;  // D#4   dur=43727
            13'd6   : dout <= 35'h20600AACF;  // E4    dur=43727
            13'd7   : dout <= 35'h1FDC0AACF;  // D#4   dur=43727
            13'd8   : dout <= 35'h1446000AF;  // E2    dur=175
            13'd9   : dout <= 35'h17C6000AF;  // B2    dur=175
            13'd10  : dout <= 35'h1C46000AF;  // G#3   dur=175
            13'd11  : dout <= 35'h1FE62A92E;  // D#4   dur=174382
            13'd12  : dout <= 35'h1ED80AACF;  // C#4   dur=43727
            13'd13  : dout <= 35'h1FDC0AACF;  // D#4   dur=43727
            13'd14  : dout <= 35'h20620AACF;  // E4    dur=43727
            13'd15  : dout <= 35'h1FDE0AACF;  // D#4   dur=43727
            13'd16  : dout <= 35'h1544000AF;  // F#2   dur=175
            13'd17  : dout <= 35'h18C4000AF;  // C#3   dur=175
            13'd18  : dout <= 35'h1D44000AF;  // A#3   dur=175
            13'd19  : dout <= 35'h1FE00A8C2;  // D#4   dur=43202
            13'd20  : dout <= 35'h1EDA0AACF;  // C#4   dur=43727
            13'd21  : dout <= 35'h17C4000AF;  // B2    dur=175
            13'd22  : dout <= 35'h1B44000AF;  // F#3   dur=175
            13'd23  : dout <= 35'h1DDE0A971;  // B3    dur=43377
            13'd24  : dout <= 35'h1FE20AACF;  // D#4   dur=43727
            13'd25  : dout <= 35'h1446000AF;  // E2    dur=175
            13'd26  : dout <= 35'h17C6000AF;  // B2    dur=175
            13'd27  : dout <= 35'h1C46000AF;  // G#3   dur=175
            13'd28  : dout <= 35'h1FE60A8C2;  // D#4   dur=43202
            13'd29  : dout <= 35'h226E0AACF;  // G#4   dur=43727
            13'd30  : dout <= 35'h22E002AB4;  // A4    dur=10932
            13'd31  : dout <= 35'h226C0801B;  // G#4   dur=32795
            13'd32  : dout <= 35'h1544000AF;  // F#2   dur=175
            13'd33  : dout <= 35'h18C4000AF;  // C#3   dur=175
            13'd34  : dout <= 35'h21660A971;  // F#4   dur=43377
            13'd35  : dout <= 35'h17C6000AF;  // B2    dur=175
            13'd36  : dout <= 35'h1B46000AF;  // F#3   dur=175
            13'd37  : dout <= 35'h1FC6000AF;  // D#4   dur=175
            13'd38  : dout <= 35'h21681FE5F;  // F#4   dur=130655
            13'd39  : dout <= 35'h1FDA0AACF;  // D#4   dur=43727
            13'd40  : dout <= 35'h13C4000AF;  // D#2   dur=175
            13'd41  : dout <= 35'h1744000AF;  // A#2   dur=175
            13'd42  : dout <= 35'h1B44000AF;  // F#3   dur=175
            13'd43  : dout <= 35'h21640A8C2;  // F#4   dur=43202
            13'd44  : dout <= 35'h226A0AACF;  // G#4   dur=43727
            13'd45  : dout <= 35'h23700AACF;  // A#4   dur=43727
            13'd46  : dout <= 35'h23F20AACF;  // B4    dur=43727
            13'd47  : dout <= 35'h1648000AF;  // G#2   dur=175
            13'd48  : dout <= 35'h19C8000AF;  // D#3   dur=175
            13'd49  : dout <= 35'h1DC8000AF;  // B3    dur=175
            13'd50  : dout <= 35'h226C1FE5F;  // G#4   dur=130655
            13'd51  : dout <= 35'h1FDC0AACF;  // D#4   dur=43727
            13'd52  : dout <= 35'h1444000AF;  // E2    dur=175
            13'd53  : dout <= 35'h17C4000AF;  // B2    dur=175
            13'd54  : dout <= 35'h1C44000AF;  // G#3   dur=175
            13'd55  : dout <= 35'h20620A8C2;  // E4    dur=43202
            13'd56  : dout <= 35'h21660AACF;  // F#4   dur=43727
            13'd57  : dout <= 35'h226A0AACF;  // G#4   dur=43727
            13'd58  : dout <= 35'h20600AACF;  // E4    dur=43727
            13'd59  : dout <= 35'h1546000AF;  // F#2   dur=175
            13'd60  : dout <= 35'h18C6000AF;  // C#3   dur=175
            13'd61  : dout <= 35'h1D46000AF;  // A#3   dur=175
            13'd62  : dout <= 35'h21682A92E;  // F#4   dur=174382
            13'd63  : dout <= 35'h11C8000AF;  // B1    dur=175
            13'd64  : dout <= 35'h17C8000AF;  // B2    dur=175
            13'd65  : dout <= 35'h1B48000AF;  // F#3   dur=175
            13'd66  : dout <= 35'h1FC8000AF;  // D#4   dur=175
            13'd67  : dout <= 35'h1DE42A87F;  // B3    dur=174207
            // ---- song 1 : Ode to Joy (欢乐颂) ----
            13'd512 : dout <= 35'h184400075;  // C3    dur=117
            13'd513 : dout <= 35'h1BC400075;  // G3    dur=117
            13'd514 : dout <= 35'h20620E3F7;  // E4    dur=58359
            13'd515 : dout <= 35'h205E0E4E2;  // E4    dur=58594
            13'd516 : dout <= 35'h20E20E4E2;  // F4    dur=58594
            13'd517 : dout <= 35'h15C600075;  // G2    dur=117
            13'd518 : dout <= 35'h1DC600075;  // B3    dur=117
            13'd519 : dout <= 35'h21E80E3F7;  // G4    dur=58359
            13'd520 : dout <= 35'h15C400075;  // G2    dur=117
            13'd521 : dout <= 35'h1DC400075;  // B3    dur=117
            13'd522 : dout <= 35'h21E60E3F7;  // G4    dur=58359
            13'd523 : dout <= 35'h20E00E4E2;  // F4    dur=58594
            13'd524 : dout <= 35'h184200075;  // C3    dur=117
            13'd525 : dout <= 35'h1BC200075;  // G3    dur=117
            13'd526 : dout <= 35'h205E0E3F7;  // E4    dur=58359
            13'd527 : dout <= 35'h1F5A0E4E2;  // D4    dur=58594
            13'd528 : dout <= 35'h184400075;  // C3    dur=117
            13'd529 : dout <= 35'h1A4400075;  // E3    dur=117
            13'd530 : dout <= 35'h1E600E3F7;  // C4    dur=58359
            13'd531 : dout <= 35'h1E5C0E4E2;  // C4    dur=58594
            13'd532 : dout <= 35'h1F600E4E2;  // D4    dur=58594
            13'd533 : dout <= 35'h184400075;  // C3    dur=117
            13'd534 : dout <= 35'h1BC400075;  // G3    dur=117
            13'd535 : dout <= 35'h20640E3F7;  // E4    dur=58359
            13'd536 : dout <= 35'h15C600075;  // G2    dur=117
            13'd537 : dout <= 35'h1DC600075;  // B3    dur=117
            13'd538 : dout <= 35'h206615668;  // E4    dur=87656
            13'd539 : dout <= 35'h1F5607271;  // D4    dur=29297
            13'd540 : dout <= 35'h15C200075;  // G2    dur=117
            13'd541 : dout <= 35'h1BC200075;  // G3    dur=117
            13'd542 : dout <= 35'h1DC200075;  // B3    dur=117
            13'd543 : dout <= 35'h1F601C864;  // D4    dur=116836
            13'd544 : dout <= 35'h184800075;  // C3    dur=117
            13'd545 : dout <= 35'h1BC800075;  // G3    dur=117
            13'd546 : dout <= 35'h20660E3F7;  // E4    dur=58359
            13'd547 : dout <= 35'h20620E4E2;  // E4    dur=58594
            13'd548 : dout <= 35'h20E60E4E2;  // F4    dur=58594
            13'd549 : dout <= 35'h15CA00075;  // G2    dur=117
            13'd550 : dout <= 35'h1DCA00075;  // B3    dur=117
            13'd551 : dout <= 35'h21EC0E3F7;  // G4    dur=58359
            13'd552 : dout <= 35'h15C800075;  // G2    dur=117
            13'd553 : dout <= 35'h1DC800075;  // B3    dur=117
            13'd554 : dout <= 35'h21EA0E3F7;  // G4    dur=58359
            13'd555 : dout <= 35'h20E40E4E2;  // F4    dur=58594
            13'd556 : dout <= 35'h184600075;  // C3    dur=117
            13'd557 : dout <= 35'h1BC600075;  // G3    dur=117
            13'd558 : dout <= 35'h20620E3F7;  // E4    dur=58359
            13'd559 : dout <= 35'h1F5E0E4E2;  // D4    dur=58594
            13'd560 : dout <= 35'h16C600075;  // A2    dur=117
            13'd561 : dout <= 35'h1A4600075;  // E3    dur=117
            13'd562 : dout <= 35'h1E620E3F7;  // C4    dur=58359
            13'd563 : dout <= 35'h1E5E0E4E2;  // C4    dur=58594
            13'd564 : dout <= 35'h15C600075;  // G2    dur=117
            13'd565 : dout <= 35'h1AC600075;  // F3    dur=117
            13'd566 : dout <= 35'h1F640E3F7;  // D4    dur=58359
            13'd567 : dout <= 35'h20660E4E2;  // E4    dur=58594
            13'd568 : dout <= 35'h15C400075;  // G2    dur=117
            13'd569 : dout <= 35'h1AC400075;  // F3    dur=117
            13'd570 : dout <= 35'h1DC400075;  // B3    dur=117
            13'd571 : dout <= 35'h1F64155F3;  // D4    dur=87539
            13'd572 : dout <= 35'h1E5807271;  // C4    dur=29297
            13'd573 : dout <= 35'h184A00075;  // C3    dur=117
            13'd574 : dout <= 35'h1A4A00075;  // E3    dur=117
            13'd575 : dout <= 35'h1BCA00075;  // G3    dur=117
            13'd576 : dout <= 35'h1E681C864;  // C4    dur=116836
            13'd577 : dout <= 35'h15BC00075;  // G2    dur=117
            13'd578 : dout <= 35'h1DBC00075;  // B3    dur=117
            13'd579 : dout <= 35'h1F560E3F7;  // D4    dur=58359
            13'd580 : dout <= 35'h1F540E4E2;  // D4    dur=58594
            13'd581 : dout <= 35'h183E00075;  // C3    dur=117
            13'd582 : dout <= 35'h1BBE00075;  // G3    dur=117
            13'd583 : dout <= 35'h205A0E3F7;  // E4    dur=58359
            13'd584 : dout <= 35'h1E540E4E2;  // C4    dur=58594
            13'd585 : dout <= 35'h15C000075;  // G2    dur=117
            13'd586 : dout <= 35'h1DC000075;  // B3    dur=117
            13'd587 : dout <= 35'h1F5C0E3F7;  // D4    dur=58359
            13'd588 : dout <= 35'h206007271;  // E4    dur=29297
            13'd589 : dout <= 35'h20E407271;  // F4    dur=29297
            13'd590 : dout <= 35'h184000075;  // C3    dur=117
            13'd591 : dout <= 35'h1BC000075;  // G3    dur=117
            13'd592 : dout <= 35'h205E0E3F7;  // E4    dur=58359
            13'd593 : dout <= 35'h1E560E4E2;  // C4    dur=58594
            13'd594 : dout <= 35'h164200075;  // G#2   dur=117
            13'd595 : dout <= 35'h1A4200075;  // E3    dur=117
            13'd596 : dout <= 35'h1F600E3F7;  // D4    dur=58359
            13'd597 : dout <= 35'h206407271;  // E4    dur=29297
            13'd598 : dout <= 35'h20E807271;  // F4    dur=29297
            13'd599 : dout <= 35'h16C400075;  // A2    dur=117
            13'd600 : dout <= 35'h1A4400075;  // E3    dur=117
            13'd601 : dout <= 35'h20620E3F7;  // E4    dur=58359
            13'd602 : dout <= 35'h1F5E0E4E2;  // D4    dur=58594
            13'd603 : dout <= 35'h194400075;  // D3    dur=117
            13'd604 : dout <= 35'h1B4400075;  // F#3   dur=117
            13'd605 : dout <= 35'h1E600E3F7;  // C4    dur=58359
            13'd606 : dout <= 35'h1F640E4E2;  // D4    dur=58594
            13'd607 : dout <= 35'h15CA00075;  // G2    dur=117
            13'd608 : dout <= 35'h194A00075;  // D3    dur=117
            13'd609 : dout <= 35'h1DCA00075;  // B3    dur=117
            13'd610 : dout <= 35'h1BEA1C864;  // G3    dur=116836
            13'd611 : dout <= 35'h184E00075;  // C3    dur=117
            13'd612 : dout <= 35'h1BCE00075;  // G3    dur=117
            13'd613 : dout <= 35'h1E4E00075;  // C4    dur=117
            13'd614 : dout <= 35'h20700E382;  // E4    dur=58242
            13'd615 : dout <= 35'h206C0E4E2;  // E4    dur=58594
            13'd616 : dout <= 35'h20EE0E4E2;  // F4    dur=58594
            13'd617 : dout <= 35'h15D000075;  // G2    dur=117
            13'd618 : dout <= 35'h195000075;  // D3    dur=117
            13'd619 : dout <= 35'h1DD000075;  // B3    dur=117
            13'd620 : dout <= 35'h21F40E382;  // G4    dur=58242
            13'd621 : dout <= 35'h1A4C00075;  // E3    dur=117
            13'd622 : dout <= 35'h1DCC00075;  // B3    dur=117
            13'd623 : dout <= 35'h21F20E3F7;  // G4    dur=58359
            13'd624 : dout <= 35'h20EC0E4E2;  // F4    dur=58594
            13'd625 : dout <= 35'h184A00075;  // C3    dur=117
            13'd626 : dout <= 35'h1BCA00075;  // G3    dur=117
            13'd627 : dout <= 35'h206A0E3F7;  // E4    dur=58359
            13'd628 : dout <= 35'h1F660E4E2;  // D4    dur=58594
            13'd629 : dout <= 35'h16CA00075;  // A2    dur=117
            13'd630 : dout <= 35'h1A4A00075;  // E3    dur=117
            13'd631 : dout <= 35'h1E6A0E3F7;  // C4    dur=58359
            13'd632 : dout <= 35'h1E660E4E2;  // C4    dur=58594
            13'd633 : dout <= 35'h15CC00075;  // G2    dur=117
            13'd634 : dout <= 35'h194C00075;  // D3    dur=117
            13'd635 : dout <= 35'h1F6C0E3F7;  // D4    dur=58359
            13'd636 : dout <= 35'h206E0E4E2;  // E4    dur=58594
            13'd637 : dout <= 35'h15CC00075;  // G2    dur=117
            13'd638 : dout <= 35'h1ACC00075;  // F3    dur=117
            13'd639 : dout <= 35'h1DCC00075;  // B3    dur=117
            13'd640 : dout <= 35'h1F6C155F3;  // D4    dur=87539
            13'd641 : dout <= 35'h1E6007271;  // C4    dur=29297
            13'd642 : dout <= 35'h125200075;  // C2    dur=117
            13'd643 : dout <= 35'h185200075;  // C3    dur=117
            13'd644 : dout <= 35'h1A5200075;  // E3    dur=117
            13'd645 : dout <= 35'h1BD200075;  // G3    dur=117
            13'd646 : dout <= 35'h1E741C7EF;  // C4    dur=116719
            // ---- song 2 : Twinkle Twinkle (小星星) ----
            13'd1024: dout <= 35'h1846006AD;  // C3    dur=1709
            13'd1025: dout <= 35'h1A46006AD;  // E3    dur=1709
            13'd1026: dout <= 35'h1BC6006AD;  // G3    dur=1709
            13'd1027: dout <= 35'h1E600AAB5;  // C4    dur=43701
            13'd1028: dout <= 35'h1E580BEBC;  // C4    dur=48828
            13'd1029: dout <= 35'h1844006AD;  // C3    dur=1709
            13'd1030: dout <= 35'h1A44006AD;  // E3    dur=1709
            13'd1031: dout <= 35'h21E60B162;  // G4    dur=45410
            13'd1032: dout <= 35'h21DE0BEBC;  // G4    dur=48828
            13'd1033: dout <= 35'h14C8006AD;  // F2    dur=1709
            13'd1034: dout <= 35'h1848006AD;  // C3    dur=1709
            13'd1035: dout <= 35'h1AC8006AD;  // F3    dur=1709
            13'd1036: dout <= 35'h22EA0AAB5;  // A4    dur=43701
            13'd1037: dout <= 35'h22E20BEBC;  // A4    dur=48828
            13'd1038: dout <= 35'h1846006AD;  // C3    dur=1709
            13'd1039: dout <= 35'h1A46006AD;  // E3    dur=1709
            13'd1040: dout <= 35'h1E46006AD;  // C4    dur=1709
            13'd1041: dout <= 35'h21E416971;  // G4    dur=92529
            13'd1042: dout <= 35'h14C4006AD;  // F2    dur=1709
            13'd1043: dout <= 35'h1CC4006AD;  // A3    dur=1709
            13'd1044: dout <= 35'h1E44006AD;  // C4    dur=1709
            13'd1045: dout <= 35'h20E20AAB5;  // F4    dur=43701
            13'd1046: dout <= 35'h20DA0BEBC;  // F4    dur=48828
            13'd1047: dout <= 35'h1842006AD;  // C3    dur=1709
            13'd1048: dout <= 35'h1BC2006AD;  // G3    dur=1709
            13'd1049: dout <= 35'h205E0B162;  // E4    dur=45410
            13'd1050: dout <= 35'h20580BEBC;  // E4    dur=48828
            13'd1051: dout <= 35'h15C2006AD;  // G2    dur=1709
            13'd1052: dout <= 35'h1AC2006AD;  // F3    dur=1709
            13'd1053: dout <= 35'h1DC2006AD;  // B3    dur=1709
            13'd1054: dout <= 35'h1F5C0AAB5;  // D4    dur=43701
            13'd1055: dout <= 35'h1F560BEBC;  // D4    dur=48828
            13'd1056: dout <= 35'h1846006AD;  // C3    dur=1709
            13'd1057: dout <= 35'h1A46006AD;  // E3    dur=1709
            13'd1058: dout <= 35'h1BC6006AD;  // G3    dur=1709
            13'd1059: dout <= 35'h1E6016971;  // C4    dur=92529
            13'd1060: dout <= 35'h1844006AD;  // C3    dur=1709
            13'd1061: dout <= 35'h2044006AD;  // E4    dur=1709
            13'd1062: dout <= 35'h21E60B162;  // G4    dur=45410
            13'd1063: dout <= 35'h21DC0BEBC;  // G4    dur=48828
            13'd1064: dout <= 35'h14C2006AD;  // F2    dur=1709
            13'd1065: dout <= 35'h1CC2006AD;  // A3    dur=1709
            13'd1066: dout <= 35'h20E20B162;  // F4    dur=45410
            13'd1067: dout <= 35'h20DA0BEBC;  // F4    dur=48828
            13'd1068: dout <= 35'h1840006AD;  // C3    dur=1709
            13'd1069: dout <= 35'h1BC0006AD;  // G3    dur=1709
            13'd1070: dout <= 35'h205E0B162;  // E4    dur=45410
            13'd1071: dout <= 35'h20580BEBC;  // E4    dur=48828
            13'd1072: dout <= 35'h15C4006AD;  // G2    dur=1709
            13'd1073: dout <= 35'h1944006AD;  // D3    dur=1709
            13'd1074: dout <= 35'h1DC4006AD;  // B3    dur=1709
            13'd1075: dout <= 35'h1F6016971;  // D4    dur=92529
            13'd1076: dout <= 35'h1846006AD;  // C3    dur=1709
            13'd1077: dout <= 35'h2046006AD;  // E4    dur=1709
            13'd1078: dout <= 35'h21E80B162;  // G4    dur=45410
            13'd1079: dout <= 35'h21DE0BEBC;  // G4    dur=48828
            13'd1080: dout <= 35'h14C4006AD;  // F2    dur=1709
            13'd1081: dout <= 35'h1CC4006AD;  // A3    dur=1709
            13'd1082: dout <= 35'h20E40B162;  // F4    dur=45410
            13'd1083: dout <= 35'h20DC0BEBC;  // F4    dur=48828
            13'd1084: dout <= 35'h1842006AD;  // C3    dur=1709
            13'd1085: dout <= 35'h1BC2006AD;  // G3    dur=1709
            13'd1086: dout <= 35'h20600B162;  // E4    dur=45410
            13'd1087: dout <= 35'h20580BEBC;  // E4    dur=48828
            13'd1088: dout <= 35'h15C4006AD;  // G2    dur=1709
            13'd1089: dout <= 35'h1944006AD;  // D3    dur=1709
            13'd1090: dout <= 35'h1DC4006AD;  // B3    dur=1709
            13'd1091: dout <= 35'h1F5E16971;  // D4    dur=92529
            13'd1092: dout <= 35'h1846006AD;  // C3    dur=1709
            13'd1093: dout <= 35'h1A46006AD;  // E3    dur=1709
            13'd1094: dout <= 35'h1BC6006AD;  // G3    dur=1709
            13'd1095: dout <= 35'h1E620AAB5;  // C4    dur=43701
            13'd1096: dout <= 35'h205A05F5E;  // E4    dur=24414
            13'd1097: dout <= 35'h1E5605F5E;  // C4    dur=24414
            13'd1098: dout <= 35'h1A46006AD;  // E3    dur=1709
            13'd1099: dout <= 35'h1E46006AD;  // C4    dur=1709
            13'd1100: dout <= 35'h21E80B162;  // G4    dur=45410
            13'd1101: dout <= 35'h205C05F5E;  // E4    dur=24414
            13'd1102: dout <= 35'h21E005F5E;  // G4    dur=24414
            13'd1103: dout <= 35'h14CA006AD;  // F2    dur=1709
            13'd1104: dout <= 35'h184A006AD;  // C3    dur=1709
            13'd1105: dout <= 35'h1ACA006AD;  // F3    dur=1709
            13'd1106: dout <= 35'h22EC0AAB5;  // A4    dur=43701
            13'd1107: dout <= 35'h246605F5E;  // C5    dur=24414
            13'd1108: dout <= 35'h22E005F5E;  // A4    dur=24414
            13'd1109: dout <= 35'h1848006AD;  // C3    dur=1709
            13'd1110: dout <= 35'h1A48006AD;  // E3    dur=1709
            13'd1111: dout <= 35'h1E48006AD;  // C4    dur=1709
            13'd1112: dout <= 35'h21E816971;  // G4    dur=92529
            13'd1113: dout <= 35'h14C6006AD;  // F2    dur=1709
            13'd1114: dout <= 35'h1CC6006AD;  // A3    dur=1709
            13'd1115: dout <= 35'h1E46006AD;  // C4    dur=1709
            13'd1116: dout <= 35'h20E40AAB5;  // F4    dur=43701
            13'd1117: dout <= 35'h22DE05F5E;  // A4    dur=24414
            13'd1118: dout <= 35'h20DA05F5E;  // F4    dur=24414
            13'd1119: dout <= 35'h1844006AD;  // C3    dur=1709
            13'd1120: dout <= 35'h1BC4006AD;  // G3    dur=1709
            13'd1121: dout <= 35'h1E44006AD;  // C4    dur=1709
            13'd1122: dout <= 35'h20600AAB5;  // E4    dur=43701
            13'd1123: dout <= 35'h21DC05F5E;  // G4    dur=24414
            13'd1124: dout <= 35'h205805F5E;  // E4    dur=24414
            13'd1125: dout <= 35'h15C4006AD;  // G2    dur=1709
            13'd1126: dout <= 35'h1AC4006AD;  // F3    dur=1709
            13'd1127: dout <= 35'h1DC4006AD;  // B3    dur=1709
            13'd1128: dout <= 35'h1F5E0AAB5;  // D4    dur=43701
            13'd1129: dout <= 35'h20DA05F5E;  // F4    dur=24414
            13'd1130: dout <= 35'h1F5605F5E;  // D4    dur=24414
            13'd1131: dout <= 35'h124C006AD;  // C2    dur=1709
            13'd1132: dout <= 35'h15CC006AD;  // G2    dur=1709
            13'd1133: dout <= 35'h1A4C006AD;  // E3    dur=1709
            13'd1134: dout <= 35'h1BCC006AD;  // G3    dur=1709
            13'd1135: dout <= 35'h1E6C162C4;  // C4    dur=90820
            // ---- song 3 : Jingle Bells (铃儿响叮当) ----
            13'd1536: dout <= 35'h184600054;  // C3    dur=84
            13'd1537: dout <= 35'h1BC600054;  // G3    dur=84
            13'd1538: dout <= 35'h1E4600054;  // C4    dur=84
            13'd1539: dout <= 35'h20660A282;  // E4    dur=41602
            13'd1540: dout <= 35'h20600A37D;  // E4    dur=41853
            13'd1541: dout <= 35'h184800054;  // C3    dur=84
            13'd1542: dout <= 35'h1BC800054;  // G3    dur=84
            13'd1543: dout <= 35'h206A14652;  // E4    dur=83538
            13'd1544: dout <= 35'h184600054;  // C3    dur=84
            13'd1545: dout <= 35'h1BC600054;  // G3    dur=84
            13'd1546: dout <= 35'h1E4600054;  // C4    dur=84
            13'd1547: dout <= 35'h20680A282;  // E4    dur=41602
            13'd1548: dout <= 35'h20620A37D;  // E4    dur=41853
            13'd1549: dout <= 35'h184800054;  // C3    dur=84
            13'd1550: dout <= 35'h1BC800054;  // G3    dur=84
            13'd1551: dout <= 35'h206C14652;  // E4    dur=83538
            13'd1552: dout <= 35'h184600054;  // C3    dur=84
            13'd1553: dout <= 35'h1BC600054;  // G3    dur=84
            13'd1554: dout <= 35'h20680A2D5;  // E4    dur=41685
            13'd1555: dout <= 35'h21EE0A37D;  // G4    dur=41853
            13'd1556: dout <= 35'h16C400054;  // A2    dur=84
            13'd1557: dout <= 35'h1A4400054;  // E3    dur=84
            13'd1558: dout <= 35'h1E660F494;  // C4    dur=62612
            13'd1559: dout <= 35'h1F5E051BE;  // D4    dur=20926
            13'd1560: dout <= 35'h184A00054;  // C3    dur=84
            13'd1561: dout <= 35'h1BCA00054;  // G3    dur=84
            13'd1562: dout <= 35'h1E4A00054;  // C4    dur=84
            13'd1563: dout <= 35'h206E28CF8;  // E4    dur=167160
            13'd1564: dout <= 35'h14C800054;  // F2    dur=84
            13'd1565: dout <= 35'h184800054;  // C3    dur=84
            13'd1566: dout <= 35'h1CC800054;  // A3    dur=84
            13'd1567: dout <= 35'h20EA0A282;  // F4    dur=41602
            13'd1568: dout <= 35'h20E40A37D;  // F4    dur=41853
            13'd1569: dout <= 35'h20E80F53B;  // F4    dur=62779
            13'd1570: dout <= 35'h20DC051BE;  // F4    dur=20926
            13'd1571: dout <= 35'h184600054;  // C3    dur=84
            13'd1572: dout <= 35'h1BC600054;  // G3    dur=84
            13'd1573: dout <= 35'h1E4600054;  // C4    dur=84
            13'd1574: dout <= 35'h20E60A282;  // F4    dur=41602
            13'd1575: dout <= 35'h20620A37D;  // E4    dur=41853
            13'd1576: dout <= 35'h20600A37D;  // E4    dur=41853
            13'd1577: dout <= 35'h205A051BE;  // E4    dur=20926
            13'd1578: dout <= 35'h205C051BE;  // E4    dur=20926
            13'd1579: dout <= 35'h194600054;  // D3    dur=84
            13'd1580: dout <= 35'h1B4600054;  // F#3   dur=84
            13'd1581: dout <= 35'h1CC600054;  // A3    dur=84
            13'd1582: dout <= 35'h20660A282;  // E4    dur=41602
            13'd1583: dout <= 35'h1F620A37D;  // D4    dur=41853
            13'd1584: dout <= 35'h1F620A37D;  // D4    dur=41853
            13'd1585: dout <= 35'h20660A37D;  // E4    dur=41853
            13'd1586: dout <= 35'h15C800054;  // G2    dur=84
            13'd1587: dout <= 35'h194800054;  // D3    dur=84
            13'd1588: dout <= 35'h1DC800054;  // B3    dur=84
            13'd1589: dout <= 35'h1F68145FE;  // D4    dur=83454
            13'd1590: dout <= 35'h15CE00054;  // G2    dur=84
            13'd1591: dout <= 35'h1DCE00054;  // B3    dur=84
            13'd1592: dout <= 35'h1F4E00054;  // D4    dur=84
            13'd1593: dout <= 35'h21F2145FE;  // G4    dur=83454
            13'd1594: dout <= 35'h184800054;  // C3    dur=84
            13'd1595: dout <= 35'h1BC800054;  // G3    dur=84
            13'd1596: dout <= 35'h1E4800054;  // C4    dur=84
            13'd1597: dout <= 35'h206A0A282;  // E4    dur=41602
            13'd1598: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1599: dout <= 35'h184A00054;  // C3    dur=84
            13'd1600: dout <= 35'h1BCA00054;  // G3    dur=84
            13'd1601: dout <= 35'h206E14652;  // E4    dur=83538
            13'd1602: dout <= 35'h184800054;  // C3    dur=84
            13'd1603: dout <= 35'h1BC800054;  // G3    dur=84
            13'd1604: dout <= 35'h1E4800054;  // C4    dur=84
            13'd1605: dout <= 35'h206C0A282;  // E4    dur=41602
            13'd1606: dout <= 35'h20660A37D;  // E4    dur=41853
            13'd1607: dout <= 35'h184A00054;  // C3    dur=84
            13'd1608: dout <= 35'h1BCA00054;  // G3    dur=84
            13'd1609: dout <= 35'h207014652;  // E4    dur=83538
            13'd1610: dout <= 35'h184800054;  // C3    dur=84
            13'd1611: dout <= 35'h1BC800054;  // G3    dur=84
            13'd1612: dout <= 35'h206A0A2D5;  // E4    dur=41685
            13'd1613: dout <= 35'h21F00A37D;  // G4    dur=41853
            13'd1614: dout <= 35'h16C600054;  // A2    dur=84
            13'd1615: dout <= 35'h1A4600054;  // E3    dur=84
            13'd1616: dout <= 35'h1E680F494;  // C4    dur=62612
            13'd1617: dout <= 35'h1F60051BE;  // D4    dur=20926
            13'd1618: dout <= 35'h184C00054;  // C3    dur=84
            13'd1619: dout <= 35'h1BCC00054;  // G3    dur=84
            13'd1620: dout <= 35'h1E4C00054;  // C4    dur=84
            13'd1621: dout <= 35'h207028CF8;  // E4    dur=167160
            13'd1622: dout <= 35'h14CA00054;  // F2    dur=84
            13'd1623: dout <= 35'h184A00054;  // C3    dur=84
            13'd1624: dout <= 35'h1CCA00054;  // A3    dur=84
            13'd1625: dout <= 35'h20EC0A282;  // F4    dur=41602
            13'd1626: dout <= 35'h20E60A37D;  // F4    dur=41853
            13'd1627: dout <= 35'h20EA0F53B;  // F4    dur=62779
            13'd1628: dout <= 35'h20E0051BE;  // F4    dur=20926
            13'd1629: dout <= 35'h184800054;  // C3    dur=84
            13'd1630: dout <= 35'h1BC800054;  // G3    dur=84
            13'd1631: dout <= 35'h1E4800054;  // C4    dur=84
            13'd1632: dout <= 35'h20EA0A282;  // F4    dur=41602
            13'd1633: dout <= 35'h20660A37D;  // E4    dur=41853
            13'd1634: dout <= 35'h20640A37D;  // E4    dur=41853
            13'd1635: dout <= 35'h205E051BE;  // E4    dur=20926
            13'd1636: dout <= 35'h2060051BE;  // E4    dur=20926
            13'd1637: dout <= 35'h15CC00054;  // G2    dur=84
            13'd1638: dout <= 35'h194C00054;  // D3    dur=84
            13'd1639: dout <= 35'h1DCC00054;  // B3    dur=84
            13'd1640: dout <= 35'h21F00A282;  // G4    dur=41602
            13'd1641: dout <= 35'h21EE0A37D;  // G4    dur=41853
            13'd1642: dout <= 35'h15CA00054;  // G2    dur=84
            13'd1643: dout <= 35'h1ACA00054;  // F3    dur=84
            13'd1644: dout <= 35'h1DCA00054;  // B3    dur=84
            13'd1645: dout <= 35'h20EA0A282;  // F4    dur=41602
            13'd1646: dout <= 35'h1F640A37D;  // D4    dur=41853
            13'd1647: dout <= 35'h125200054;  // C2    dur=84
            13'd1648: dout <= 35'h185200054;  // C3    dur=84
            13'd1649: dout <= 35'h1A5200054;  // E3    dur=84
            13'd1650: dout <= 35'h1BD200054;  // G3    dur=84
            13'd1651: dout <= 35'h1E7628CA4;  // C4    dur=167076
            // ---- song 4 : Für Elise (致爱丽丝) ----
            13'd2048: dout <= 35'h265202FAF;  // E5    dur=12207
            13'd2049: dout <= 35'h25CE02FAF;  // D#5   dur=12207
            13'd2050: dout <= 35'h265402FAF;  // E5    dur=12207
            13'd2051: dout <= 35'h25D002FAF;  // D#5   dur=12207
            13'd2052: dout <= 35'h265602FAF;  // E5    dur=12207
            13'd2053: dout <= 35'h23D202FAF;  // B4    dur=12207
            13'd2054: dout <= 35'h255802FAF;  // D5    dur=12207
            13'd2055: dout <= 35'h245402FAF;  // C5    dur=12207
            13'd2056: dout <= 35'h16C200062;  // A2    dur=98
            13'd2057: dout <= 35'h1A4200062;  // E3    dur=98
            13'd2058: dout <= 35'h22DC05E9B;  // A4    dur=24219
            13'd2059: dout <= 35'h1CC002FAF;  // A3    dur=12207
            13'd2060: dout <= 35'h1E4E02FAF;  // C4    dur=12207
            13'd2061: dout <= 35'h205402FAF;  // E4    dur=12207
            13'd2062: dout <= 35'h22DC02FAF;  // A4    dur=12207
            13'd2063: dout <= 35'h144200062;  // E2    dur=98
            13'd2064: dout <= 35'h1A4200062;  // E3    dur=98
            13'd2065: dout <= 35'h23DE05E9B;  // B4    dur=24219
            13'd2066: dout <= 35'h1C4002FAF;  // G#3   dur=12207
            13'd2067: dout <= 35'h205002FAF;  // E4    dur=12207
            13'd2068: dout <= 35'h225602FAF;  // G#4   dur=12207
            13'd2069: dout <= 35'h23DE02FAF;  // B4    dur=12207
            13'd2070: dout <= 35'h16C400062;  // A2    dur=98
            13'd2071: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2072: dout <= 35'h246005E9B;  // C5    dur=24219
            13'd2073: dout <= 35'h1CC202FAF;  // A3    dur=12207
            13'd2074: dout <= 35'h204E02FAF;  // E4    dur=12207
            13'd2075: dout <= 35'h265402FAF;  // E5    dur=12207
            13'd2076: dout <= 35'h25D002FAF;  // D#5   dur=12207
            13'd2077: dout <= 35'h265602FAF;  // E5    dur=12207
            13'd2078: dout <= 35'h25D202FAF;  // D#5   dur=12207
            13'd2079: dout <= 35'h265802FAF;  // E5    dur=12207
            13'd2080: dout <= 35'h23D402FAF;  // B4    dur=12207
            13'd2081: dout <= 35'h255A02FAF;  // D5    dur=12207
            13'd2082: dout <= 35'h245602FAF;  // C5    dur=12207
            13'd2083: dout <= 35'h16C400062;  // A2    dur=98
            13'd2084: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2085: dout <= 35'h22DE05E9B;  // A4    dur=24219
            13'd2086: dout <= 35'h1CC202FAF;  // A3    dur=12207
            13'd2087: dout <= 35'h1E5002FAF;  // C4    dur=12207
            13'd2088: dout <= 35'h205602FAF;  // E4    dur=12207
            13'd2089: dout <= 35'h22DE02FAF;  // A4    dur=12207
            13'd2090: dout <= 35'h144400062;  // E2    dur=98
            13'd2091: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2092: dout <= 35'h23E005E9B;  // B4    dur=24219
            13'd2093: dout <= 35'h1C4202FAF;  // G#3   dur=12207
            13'd2094: dout <= 35'h205202FAF;  // E4    dur=12207
            13'd2095: dout <= 35'h245E02FAF;  // C5    dur=12207
            13'd2096: dout <= 35'h23D802FAF;  // B4    dur=12207
            13'd2097: dout <= 35'h16C400062;  // A2    dur=98
            13'd2098: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2099: dout <= 35'h1CC400062;  // A3    dur=98
            13'd2100: dout <= 35'h22DC08DE8;  // A4    dur=36328
            13'd2101: dout <= 35'h23D802FAF;  // B4    dur=12207
            13'd2102: dout <= 35'h245C02FAF;  // C5    dur=12207
            13'd2103: dout <= 35'h256002FAF;  // D5    dur=12207
            13'd2104: dout <= 35'h184800062;  // C3    dur=98
            13'd2105: dout <= 35'h1BC800062;  // G3    dur=98
            13'd2106: dout <= 35'h266808E4A;  // E5    dur=36426
            13'd2107: dout <= 35'h21D402FAF;  // G4    dur=12207
            13'd2108: dout <= 35'h26EA02FAF;  // F5    dur=12207
            13'd2109: dout <= 35'h266402FAF;  // E5    dur=12207
            13'd2110: dout <= 35'h15C800062;  // G2    dur=98
            13'd2111: dout <= 35'h1BC800062;  // G3    dur=98
            13'd2112: dout <= 35'h256608E4A;  // D5    dur=36426
            13'd2113: dout <= 35'h20D202FAF;  // F4    dur=12207
            13'd2114: dout <= 35'h266602FAF;  // E5    dur=12207
            13'd2115: dout <= 35'h256002FAF;  // D5    dur=12207
            13'd2116: dout <= 35'h16C600062;  // A2    dur=98
            13'd2117: dout <= 35'h1A4600062;  // E3    dur=98
            13'd2118: dout <= 35'h246208E4A;  // C5    dur=36426
            13'd2119: dout <= 35'h205002FAF;  // E4    dur=12207
            13'd2120: dout <= 35'h256202FAF;  // D5    dur=12207
            13'd2121: dout <= 35'h245C02FAF;  // C5    dur=12207
            13'd2122: dout <= 35'h144400062;  // E2    dur=98
            13'd2123: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2124: dout <= 35'h23DE05E9B;  // B4    dur=24219
            13'd2125: dout <= 35'h204C02FAF;  // E4    dur=12207
            13'd2126: dout <= 35'h265402FAF;  // E5    dur=12207
            13'd2127: dout <= 35'h25D002FAF;  // D#5   dur=12207
            13'd2128: dout <= 35'h265602FAF;  // E5    dur=12207
            13'd2129: dout <= 35'h25D202FAF;  // D#5   dur=12207
            13'd2130: dout <= 35'h265802FAF;  // E5    dur=12207
            13'd2131: dout <= 35'h23D402FAF;  // B4    dur=12207
            13'd2132: dout <= 35'h255A02FAF;  // D5    dur=12207
            13'd2133: dout <= 35'h245602FAF;  // C5    dur=12207
            13'd2134: dout <= 35'h16C400062;  // A2    dur=98
            13'd2135: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2136: dout <= 35'h22DE05E9B;  // A4    dur=24219
            13'd2137: dout <= 35'h1CC202FAF;  // A3    dur=12207
            13'd2138: dout <= 35'h1E5002FAF;  // C4    dur=12207
            13'd2139: dout <= 35'h205602FAF;  // E4    dur=12207
            13'd2140: dout <= 35'h22DE02FAF;  // A4    dur=12207
            13'd2141: dout <= 35'h144400062;  // E2    dur=98
            13'd2142: dout <= 35'h1A4400062;  // E3    dur=98
            13'd2143: dout <= 35'h23E005E9B;  // B4    dur=24219
            13'd2144: dout <= 35'h1C4202FAF;  // G#3   dur=12207
            13'd2145: dout <= 35'h205202FAF;  // E4    dur=12207
            13'd2146: dout <= 35'h245E02FAF;  // C5    dur=12207
            13'd2147: dout <= 35'h23D802FAF;  // B4    dur=12207
            13'd2148: dout <= 35'h16C800062;  // A2    dur=98
            13'd2149: dout <= 35'h1A4800062;  // E3    dur=98
            13'd2150: dout <= 35'h1E4800062;  // C4    dur=98
            13'd2151: dout <= 35'h22E00ED46;  // A4    dur=60742
            // 越界 / 未使用地址 = 曲末标记（播放器据此回到第 0 个音符）
            default: dout <= 35'h400000000;
        endcase
    end

endmodule

`default_nettype wire
