// =============================================================================
//  touch_notes.v —— 把 `touch_key.v` 的"按下电平 + 力度"翻译成【音符事件】
//
//  为什么需要它：`touch_key.v` 输出的是**电平**（`pressed` / `strength`），
//  而 `piano_engine.v` 要的是**1 拍脉冲**（`on_valid/on_note/on_vel`、`off_valid/off_note`）。
//  本模块做这层翻译，并负责**力度 = f(strength)** 的映射。
//
//  设计要点：
//   · **轮询扫描**（每拍看一个通道）：N 个通道一共 N 拍就全部看过一遍，
//     ⇒ 任何 `pressed` 变化都会在 N 拍内被发现，**不需要仲裁器/优先级编码器**，
//     而且**每拍最多发一个事件** ⇒ 两条 1 拍脉冲绝不会撞车丢失。
//   · **边沿检测**：`pressed[i]` 上升沿 ⇒ NoteOn；下降沿 ⇒ NoteOff。
//   · **力度映射（无乘法器）**：`vel = 1 + (strength >> VEL_SH)`，夹到 [1,127]。
//     strength 是 `touch_key` 输出的"RC 计数相对基线的增量"（0..65535）。
//     例（VEL_SH=3）：strength=93 ⇒ vel=12；strength=931 ⇒ vel=117；≥1016 ⇒ 127。
//   · 音高映射：`note = BASE_NOTE + i × NOTE_STRIDE`（默认 PAD0 = C4 = 60）。
//
//  ⚠️ 本模块是给 Lead 集成用的**可选项**：`top.v` 里也可以自己写这层映射。
// =============================================================================
`default_nettype none

module touch_notes #(
    parameter integer N_PAD       = 4,
    parameter integer BASE_NOTE   = 60,     // PAD0 的 MIDI 音号（60 = C4 = 261.63 Hz）
    parameter integer NOTE_STRIDE = 2,      // 相邻 PAD 的音程（半音）
    parameter integer VEL_SH      = 3       // vel = 1 + (strength >> VEL_SH)
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [N_PAD-1:0]  pressed,       // 来自 touch_key（已去抖）
    input  wire [N_PAD*16-1:0] strength,    // 来自 touch_key（每通道 16 bit 扁平）
    output reg               on_valid,      // 1 拍脉冲
    output reg  [6:0]        on_note,
    output reg  [6:0]        on_vel,
    output reg               off_valid,     // 1 拍脉冲
    output reg  [6:0]        off_note,
    output reg  [N_PAD-1:0]  held           // 当前认为"已按下并发过 NoteOn"的通道
);

    reg [N_PAD-1:0] pressed_d = {N_PAD{1'b0}};
    reg [31:0]      scan      = 32'd0;

    // 音高：BASE_NOTE + scan*NOTE_STRIDE（乘常数，综合成移位/加法）
    wire [31:0] note_calc = BASE_NOTE[31:0] + scan * NOTE_STRIDE[31:0];

    // 力度：当前扫描通道的 strength ⇒ vel（无除法/乘法器）
    wire [15:0] str_sel = strength[scan*16 +: 16];
    wire [15:0] vel_calc = 16'd1 + (str_sel >> VEL_SH);
    wire [6:0]  vel_clamp = (vel_calc > 16'd127) ? 7'd127 : vel_calc[6:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            on_valid  <= 1'b0;
            on_note   <= 7'd0;
            on_vel    <= 7'd0;
            off_valid <= 1'b0;
            off_note  <= 7'd0;
            held      <= {N_PAD{1'b0}};
            pressed_d <= {N_PAD{1'b0}};
            scan      <= 32'd0;
        end else begin
            // 默认：脉冲只维持 1 拍
            on_valid  <= 1'b0;
            off_valid <= 1'b0;

            // 只检查"本拍轮到的那个通道"
            if (pressed[scan] != pressed_d[scan]) begin
                pressed_d[scan] <= pressed[scan];
                if (pressed[scan]) begin
                    // ---------------- 上升沿 ⇒ NoteOn ----------------
                    on_valid <= 1'b1;
                    on_note  <= note_calc[6:0];
                    on_vel   <= vel_clamp;
                    held[scan] <= 1'b1;
                end else begin
                    // ---------------- 下降沿 ⇒ NoteOff ----------------
                    off_valid <= 1'b1;
                    off_note  <= note_calc[6:0];
                    held[scan] <= 1'b0;
                end
            end

            scan <= (scan == N_PAD - 1) ? 32'd0 : (scan + 32'd1);
        end
    end

endmodule

`default_nettype wire
