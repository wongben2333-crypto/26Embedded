// =============================================================================
//  midi_rx.v —— 标准 MIDI 3 字节消息解析（串口承载）
//                ① 音符命令（原有）  ② 表情参数 CC（2026-10-05 新增）
//                ③ 通用 CC 直通（2026-10-06 新增：CC20 乐器 / CC21 挂电 / CC22-24 效果器）
//
//  接口契约（Lead 固定，签名不可改）：
//      midi_rx (clk, rst_n, byte_data[7:0], byte_valid,
//               on_valid, on_note[6:0], on_vel[6:0], off_valid, off_note[6:0],
//               cc_valid, glide_on, glide_time[6:0],
//               vib_on, vib_depth[6:0], vib_rate[6:0], sustain, reset_all)
//
//  ── ① 音符命令（原有，行为不变）────────────────────────────────────────────
//      0x9n note vel  = NoteOn ；**vel == 0 视为 NoteOff**
//      0x8n note vel  = NoteOff
//      0xBn 0x7B 0x00 = All Notes Off (CC123) → **连续 128 拍 off_valid**，
//                       off_note 依次 0..127（契约无 all_off 端口，已获 Lead 批准）
//
//  ── ② 表情参数（新增，编号与 host/piano_gui.py 严格一致）──────────────────
//      编号已按 **MIDI Association 官方 Table 3** 查证（详见 host/README.md）：
//        CC 5   Portamento Time         → glide_time = d2
//        CC 1   Modulation Wheel        → vib_depth = d2（与 CC77 同时收，**后到的生效**）
//        CC 77  Sound Controller 8      → 规范里的 Vibrato Depth，同上
//        CC 76  Sound Controller 7      → vib_rate = d2
//        CC 64  Damper Pedal (Sustain)  → sustain  = (d2 >= 64)   [≤63 关 / ≥64 开]
//        CC 65  Portamento On/Off       → glide_on = (d2 >= 64)   [同一阈值语义]
//        CC 120 All Sound Off  ┐
//        CC 121 Reset All Ctrls├───────→ reset_all 打一拍 + 全部表情参数复位
//        CC 123 All Notes Off  ┘（保持原有 128 拍扫描行为）
//        其它 CC → 忽略（**不影响后续字节解析**）
//      · cc_valid：任一**已实现**的表情参数变化时打 1 拍（含复位），供 LED 提示。
//      · reset_all 后参数归位：glide_on=0, glide_time=0, vib_on=0, vib_depth=0,
//                               vib_rate=50, sustain=0   （50 → 5.0 Hz）
//
//  ── ③ ★ 数值→物理量的两条约定（**规范未定义，由本工程两侧约定**）──────────
//        滑音时间： t_glide ≈ v × 4 ms    （0=关，25→100ms，127→508ms）
//        颤音速度： f_lfo   ≈ v × 0.1 Hz  （50→5.0Hz，127→12.7Hz）
//      ⚠️ **本模块只做"传输层"：原样输出 0..127，不做任何换算** ——
//         0..127 是 MIDI 标准值域，任何外部 MIDI 设备/软件发来的也是这个值域；
//         若在传输层换算，外部工具就会算出错误结果。
//         **换算放在下游合成侧（piano_engine）**，请下游按上面两条约定实现。
//
//  ── ④ 稳健性 ──────────────────────────────────────────────────────────────
//      · 消息中途来新的状态字节（bit7=1）→ 按新消息重新开始（不把状态当数据）；
//      · 无状态字节时先来数据字节 → 丢弃；
//      · **All Notes Off 的 128 拍扫描与字节解析并行**，扫描期间**不丢字节**
//        （旧实现用 if/else 让二者互斥，115200 下每字节约 3% 概率撞进扫描窗口而丢失）。
// =============================================================================
`default_nettype none

module midi_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] byte_data,
    input  wire       byte_valid,
    // ---- 原有的音符命令总线（不动）----
    output reg        on_valid,
    output reg  [6:0] on_note,
    output reg  [6:0] on_vel,
    output reg        off_valid,
    output reg  [6:0] off_note,
    // ---- 表情参数（CC）----
    output reg        cc_valid,      // 任一表情参数变化（1 clk 脉冲，用于 LED 提示）
    output reg        glide_on,      // CC65 ≥64
    output reg  [6:0] glide_time,    // CC5
    output reg        vib_on,        // 深度 > 0 即视为开
    output reg  [6:0] vib_depth,     // CC77 或 CC1（**两个都收，取后到的**）
    output reg  [6:0] vib_rate,      // CC76
    output reg        sustain,       // CC64 ≥64
    output reg        reset_all,     // CC120/CC121：一次性复位全部表情参数（1 clk 脉冲）

    // ---- ★ 通用 CC 直通（2026-10-06 新增：CC20 乐器 / CC21 挂电 / CC22-24 效果器）----
    //  ★ 选「通用直通」而不是「每个 CC 加专用端口」的理由：
    //    1) **符合既定铁律**：RTL 只做传输层、原样透传 0..127，语义与换算在下游
    //       （AGENTS.md §4.1）。加 `instrument[1:0]`/`drive[6:0]` 会让本模块第一次"懂语义"。
    //    2) **一次到位**：以后再加 CC（效果器、音色、控制）**不用改本模块、不用重跑验收**。
    //    3) **风险最小**：只在 CC 分支里新增一条 latch，**不动任何既有分支**
    //       ⇒ 原有 45 项 PASS 在结构上不受影响。
    //    4) `top.v` 侧成本极低（一个 `case (cc_num)` 约 6 行），且把"哪个 CC 是什么意思"
    //       的策略**集中在一个文件**里。
    //  ⚠️ 现有 8 个表情端口**原样保留**（它们已 45 项 PASS 验证过），本直通是**附加**通道。
    output reg  [6:0] cc_num,        // 最近一个 CC 的编号（原样 0..127）
    output reg  [6:0] cc_val,        // 最近一个 CC 的值（原样 0..127）
    output reg        cc_any_valid   // **任一** CC 收到就打 1 拍（含未支持的 CC）
);

    // ---- CC 编号（与 host/piano_gui.py 严格一致，勿单方修改）----
    localparam [6:0] CC_MOD_WHEEL     = 7'd1;     // Modulation Wheel（惯例作颤音深度）
    localparam [6:0] CC_PORTAMENTO_T  = 7'd5;     // Portamento Time
    localparam [6:0] CC_SUSTAIN       = 7'd64;    // Damper Pedal (Sustain)
    localparam [6:0] CC_PORTAMENTO_SW = 7'd65;    // Portamento On/Off
    localparam [6:0] CC_VIB_RATE      = 7'd76;    // Sound Controller 7 = Vibrato Rate
    localparam [6:0] CC_VIB_DEPTH_SC  = 7'd77;    // Sound Controller 8 = Vibrato Depth
    localparam [6:0] CC_ALL_SOUND_OFF = 7'd120;   // [Channel Mode] All Sound Off
    localparam [6:0] CC_RESET_ALL     = 7'd121;   // [Channel Mode] Reset All Controllers
    localparam [6:0] CC_ALL_NOTES_OFF = 7'd123;   // [Channel Mode] All Notes Off

    localparam [6:0] ONOFF_THRESHOLD  = 7'd64;    // 规范：≤63 关 / ≥64 开
    localparam [6:0] VIB_RATE_DEFAULT = 7'd50;    // 约定 50 → 5.0 Hz

    // ---- 解析状态机 ----
    localparam [1:0] W_STATUS = 2'd0,   // 等状态字节
                     W_D1     = 2'd1,   // 等第 1 个数据字节（note / CC 号）
                     W_D2     = 2'd2;   // 等第 2 个数据字节（velocity / value）

    reg  [1:0] wstate;
    reg  [7:0] status;                  // 最近一次状态字节（含通道号）
    reg  [6:0] d1;                      // 第 1 个数据字节

    // ---- All Notes Off 扫描 ----
    reg        sweep_act;
    reg  [7:0] sweep_idx;

    wire [3:0] st_hi = status[7:4];     // 高半字节判类型（通道无关）
    wire       is_status_ok = (byte_data[7:4] == 4'h9) ||
                              (byte_data[7:4] == 4'h8) ||
                              (byte_data[7:4] == 4'hB);

    always @(posedge clk) begin
        if (!rst_n) begin
            wstate     <= W_STATUS;
            status     <= 8'h00;
            d1         <= 7'd0;
            on_valid   <= 1'b0;
            on_note    <= 7'd0;
            on_vel     <= 7'd0;
            off_valid  <= 1'b0;
            off_note   <= 7'd0;
            cc_valid   <= 1'b0;
            glide_on   <= 1'b0;
            glide_time <= 7'd0;
            vib_on     <= 1'b0;
            vib_depth  <= 7'd0;
            vib_rate   <= VIB_RATE_DEFAULT;   // 默认 50 → 5.0 Hz
            sustain    <= 1'b0;
            reset_all  <= 1'b0;
            sweep_act  <= 1'b0;
            sweep_idx  <= 8'd0;
            cc_num        <= 7'd0;       // ★ 通用 CC 直通
            cc_val        <= 7'd0;
            cc_any_valid  <= 1'b0;
        end else begin
            // 默认：所有脉冲都是单拍
            on_valid  <= 1'b0;
            off_valid <= 1'b0;
            cc_valid  <= 1'b0;
            reset_all <= 1'b0;
            cc_any_valid <= 1'b0;        // ★ 通用直通脉冲也是单拍

            // ------------------------------------------------------------------
            // ① All Notes Off 扫描（低优先级；与下面字节解析**并行**，互不丢信息）
            // ------------------------------------------------------------------
            if (sweep_act) begin
                off_valid <= 1'b1;
                off_note  <= sweep_idx[6:0];
                if (sweep_idx == 8'd127) begin
                    sweep_act <= 1'b0;
                    sweep_idx <= 8'd0;
                end else begin
                    sweep_idx <= sweep_idx + 8'd1;
                end
            end

            // ------------------------------------------------------------------
            // ② 字节解析（高优先级：写在后面，本拍的 off_valid/off_note 覆盖扫描值）
            // ------------------------------------------------------------------
            if (byte_valid) begin
                if (byte_data[7] && wstate != W_STATUS) begin
                    // 消息中途收到新的状态字节 ⇒ 按新消息重新开始（不把状态当数据）
                    status <= byte_data;
                    wstate <= is_status_ok ? W_D1 : W_STATUS;
                end else begin
                    case (wstate)
                        // ---------- 等状态字节 ----------
                        W_STATUS: begin
                            if (byte_data[7]) begin
                                status <= byte_data;
                                wstate <= is_status_ok ? W_D1 : W_STATUS;
                            end
                            // 数据字节但没有状态 → 丢弃（保持 W_STATUS）
                        end

                        // ---------- 等第 1 个数据字节 ----------
                        W_D1: begin
                            d1     <= byte_data[6:0];
                            wstate <= W_D2;
                        end

                        // ---------- 等第 2 个数据字节 ----------
                        W_D2: begin
                            case (st_hi)
                                // ================= NoteOn =================
                                4'h9: begin
                                    if (byte_data[6:0] == 7'd0) begin
                                        off_valid <= 1'b1;      // vel=0 ⇒ NoteOff
                                        off_note  <= d1;
                                    end else begin
                                        on_valid  <= 1'b1;
                                        on_note   <= d1;
                                        on_vel    <= byte_data[6:0];
                                    end
                                end

                                // ================= NoteOff ================
                                4'h8: begin
                                    off_valid <= 1'b1;
                                    off_note  <= d1;
                                end

                                // ================= Control Change =========
                                4'hB: begin
                                    // ★ 通用 CC 直通：**任何** CC（含未支持的）都先原样暴露，
                                    //   供 top.v 自行译码（CC20 乐器 / CC21 挂电 / CC22-24 …）。
                                    //   ⚠️ 放在 `case (d1)` **之前**，且**不改**下面任何既有分支。
                                    cc_num       <= d1;
                                    cc_val       <= byte_data[6:0];
                                    cc_any_valid <= 1'b1;
                                    case (d1)
                                        // ---- CC5 滑音时间 ----
                                        CC_PORTAMENTO_T: begin
                                            glide_time <= byte_data[6:0];
                                            cc_valid   <= 1'b1;
                                        end
                                        // ---- CC1 / CC77 都写颤音深度（后到的生效）----
                                        CC_MOD_WHEEL, CC_VIB_DEPTH_SC: begin
                                            vib_depth <= byte_data[6:0];
                                            vib_on    <= (byte_data[6:0] != 7'd0);
                                            cc_valid  <= 1'b1;
                                        end
                                        // ---- CC76 颤音速度 ----
                                        CC_VIB_RATE: begin
                                            vib_rate <= byte_data[6:0];
                                            cc_valid <= 1'b1;
                                        end
                                        // ---- CC64 延音踏板（≤63 关 / ≥64 开）----
                                        CC_SUSTAIN: begin
                                            sustain  <= (byte_data[6:0] >= ONOFF_THRESHOLD);
                                            cc_valid <= 1'b1;
                                        end
                                        // ---- CC65 滑音开关（同一阈值语义）----
                                        CC_PORTAMENTO_SW: begin
                                            glide_on <= (byte_data[6:0] >= ONOFF_THRESHOLD);
                                            cc_valid <= 1'b1;
                                        end
                                        // ---- CC123 All Notes Off（原有行为，不变）----
                                        CC_ALL_NOTES_OFF: begin
                                            if (byte_data[6:0] == 7'd0) begin
                                                sweep_act <= 1'b1;
                                                sweep_idx <= 8'd0;
                                            end
                                        end
                                        // ---- CC120 / CC121：复位全部表情参数 ----
                                        CC_ALL_SOUND_OFF, CC_RESET_ALL: begin
                                            reset_all  <= 1'b1;
                                            cc_valid   <= 1'b1;
                                            glide_on   <= 1'b0;
                                            glide_time <= 7'd0;
                                            vib_on     <= 1'b0;
                                            vib_depth  <= 7'd0;
                                            vib_rate   <= VIB_RATE_DEFAULT;
                                            sustain    <= 1'b0;
                                        end
                                        // ---- 其它 CC：忽略（不影响后续解析）----
                                        default: ;
                                    endcase
                                end

                                default: ;
                            endcase
                            wstate <= W_STATUS;
                        end

                        default: wstate <= W_STATUS;
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
