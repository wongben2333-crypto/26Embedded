// =============================================================================
//  touch_key.v —— 电容触摸琴键（RC 充放电时间测量法，**不需要 ADC、不需要专用触摸芯片**）
//
//  原理（三步测量，纯数字计时）：
//      1) DISCHARGE：把 PAD 强驱低一段固定时间，把电极电容放干净
//      2) RELEASE  ：PAD 切高阻（1'bz），电极经【外部上拉电阻】充电
//      3) MEASURE  ：数多少个 clk 才读到逻辑 1 ⇒ 这个计数就是 RC 时间
//    手指靠近 → 电极对地电容变大 → 充电变慢 → 计数变大
//
//  ★ 为什么这是【相对】测量：绝对计数值随温度/湿度/元件容差漂移，
//    所以必须用"**基线 + 阈值 + 迟滞 + 去抖**"判定，不能用固定阈值。
//
//  ── 接线（推荐拓扑，**关键：上拉电阻必须从 PAD 接到 3.3V**）──────────────────
//        FPGA_PIN ──┬───────────── PAD（铜箔/覆铜，10~15 mm 见方）
//                   │
//                [1 MΩ 1%]        手指按下 ≈ 并联 5~20 pF 到地
//                   │
//                  3.3V
//    · 串联保护电阻（可选）：在 FPGA_PIN 与 PAD 之间串 **100 Ω ~ 1 kΩ**（ESD/限流）。
//      1 kΩ 相对 1 MΩ 只增加 0.1% 的充电时间 ⇒ 对测量几乎无影响。
//    · **不要**在贴近 PAD 的地方铺大面积地铜（会加大基础电容、降低灵敏度）；
//      地铜离 PAD ≥ 2 mm。
//    · PAD 走线要短（长线加大电容、易拾噪），**不要与 I2S/时钟线并行走**。
//
//  ── 引脚（Lead 实测过的 7 个可用脚，138C 上非 CPU/SSPI 专用）────────────────
//       R19 AB21 AB22 AA20 AA21 AA19 AB20
//    ⛔ P19 T21 U21 Y21 是 CPU/SSPI 专用脚（P&R 报 PR2017），**不可用**
//    ⛔ 已占用：T18 R18 R17 P16(LED) / Y17 AB17 AA16 AB16(I2S,PA) / AB13 Y12(按键)
//              / Y22(key_pitch) / V14(uart_rx) / V22(clk)
//
//  ── 扫描方式：**分时复用**（一个测量引擎轮流扫 N 个通道）────────────────────
//    理由：N 个通道只需要 1 套计时器 + 每通道几个寄存器，资源最省；
//          同时扫描（每通道一个计数器）会多 N 倍寄存器且通道间更容易串扰。
//    实测扫描周期见 sim/tb/tb_touch_key.v 的 [SCAN] 输出。
//
//  ── 与音频的关系（**不阻塞音频**）──────────────────────────────────────────
//    本模块只有一个自己的 always 块，**不产生任何 clock enable / 等待**，
//    不影响其它逻辑的时序。唯一需要注意的是**电气噪声耦合**（见上面接线建议）。
//    tb 里用一个 97 656.25 Hz 的 sample_tick 计数器实测了"扫描期间 tick 速率不变"。
//
//  ── 接口说明（与 Lead 契约的差异，**已在注释里写明理由**）──────────────────
//    ① 契约里的 `output reg [15:0] strength [0:N_PAD-1]` 是**数组端口**。
//       Gowin 对数组端口支持不可靠 ⇒ 改成**扁平总线** `[N_PAD*16-1:0]`，
//       通道 i 占 `strength[i*16 +: 16]`（这也是 Lead 自己给的备选方案）。
//    ② 契约里的 `pad` 保持 `inout`（顶层要接真实三态脚）。
//       ⚠️ 历史教训：上一版 `touch_pad.v` 因为 **tb 的三态电极模型**死锁而放弃 inout，
//          但那是**测试台建模问题，不是 RTL 问题**。本模块的 tb 用
//          "**弱 1 上拉 + 只靠强 0 判放电**"解决（模型从不驱动 0 ⇒ `pad===0` 只可能是 DUT 在放电）。
//    ③ 契约没有的额外端口：**一个都没有**（保持最小集成面）。
//       "电极开路/超时"这种故障通过约定的 `dbg_count0 == 16'hFFFF` 暴露。
// =============================================================================
`default_nettype none

module touch_key #(
    parameter integer N_PAD   = 4,          // 触摸通道数
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer THRESH  = 0,          // 0 = 自适应阈值（基线的一定比例）

    // ---- 以下为可选微调（默认值按 50 MHz / 1 MΩ / ~20 pF 估的，可不动）----
    // 放电时间（clk）。256 @50 MHz = 5.12 µs，远大于 RC 时间常数 ⇒ 能放干净。
    parameter integer DISCHARGE_CLKS = 256,
    // 单通道最长等待。超过就判"超时/电极开路"，**不许挂死**。
    parameter integer MEASURE_MAX    = 8192,
    // 基线跟踪速度：baseline += (cnt - baseline) >> BASE_SH （只在未按下时跟踪）
    parameter integer BASE_SH        = 6,
    // 自适应阈值 = 基线 >> THRESH_SH，下限 ABS_MIN 个计数（防止基线很小时被噪声触发）
    parameter integer THRESH_SH      = 2,   // >>2 = 25% 的基线
    parameter integer ABS_MIN        = 8,
    // 迟滞：松开阈值 = 按下阈值 - (按下阈值 >> HYST_SH)，至少 1
    parameter integer HYST_SH        = 3,
    // 去抖：连续 PRESS_N 次超阈值才报按下；连续 RELEASE_N 次低于松开阈值才报松开
    parameter integer PRESS_N        = 3,
    parameter integer RELEASE_N      = 3,
    // 通道之间的空闲间隔（clk），按 CLK_HZ 换算：默认 4 µs
    parameter integer SCAN_DIV = (CLK_HZ / 250_000)
)(
    input  wire                clk,
    input  wire                rst_n,
    inout  wire [N_PAD-1:0]    pad,          // 触摸 PAD（先驱动低放电，再变高阻）
    output reg  [N_PAD-1:0]    pressed,      // 每通道"按下"（已去抖）
    output reg  [N_PAD*16-1:0] strength,     // 每通道 RC 时间相对基线的增量（可当力度）
    output wire [15:0]         dbg_count0    // 通道 0 的原始计数（0xFFFF = 超时/开路）
);

    localparam integer PW = 16;                      // 计数/基线位宽

    // ---------------------------------------------------------------- 三态驱动
    // 只有"当前正在测的通道"且处于放电阶段才驱动 0，其余一律高阻。
    reg              drive_low;
    reg  [31:0]      pad_idx;                        // 当前通道号（位宽取够，方便比较）
    genvar gi;
    generate
        for (gi = 0; gi < N_PAD; gi = gi + 1) begin : g_pad
            assign pad[gi] = (drive_low && (pad_idx == gi)) ? 1'b0 : 1'bz;
        end
    endgenerate

    // ---------------------------------------------------------------- 输入同步
    // pad 是异步信号（手指/RC 节点），必须两级同步再判 1。
    // 2 拍延迟是个【常数偏置】，会被基线自动吸收，不影响判定。
    wire pad_sel_raw = pad[pad_idx[31:0]];
    reg  pad_s1, pad_s2;
    always @(posedge clk) begin
        if (!rst_n) begin
            pad_s1 <= 1'b0;
            pad_s2 <= 1'b0;
        end else begin
            pad_s1 <= pad_sel_raw;
            pad_s2 <= pad_s1;
        end
    end
    wire pad_hi = pad_s2;

    // ---------------------------------------------------------------- 状态机
    localparam [1:0] S_GAP   = 2'd0,     // 通道间空闲
                     S_DISCH = 2'd1,     // 放电
                     S_WAIT  = 2'd2,     // 等充电到 1
                     S_DONE  = 2'd3;     // 收尾：基线/阈值/去抖
    reg [1:0]  st;
    reg [31:0] wait_cnt;
    reg [PW-1:0] meas;

    // ---------------------------------------------------------------- 每通道状态
    reg [PW-1:0] base_r [0:N_PAD-1];      // 基线
    reg [PW-1:0] cnt_r  [0:N_PAD-1];      // 最近一次计数
    reg [2:0]    pcnt_r [0:N_PAD-1];      // 连续超阈值次数
    reg [2:0]    rcnt_r [0:N_PAD-1];      // 连续低于松开阈值次数
    reg [N_PAD-1:0] touch_r;              // 去抖后的触摸状态
    reg [N_PAD-1:0] tmo_r;                // 该通道上一次是否超时（开路诊断）
    // ★★ 上电初始化标志（**没有它会有致命 bug**）：
    //    上电时基线=0，而真实计数≈800 ⇒ 头几次会被判成"按下"；
    //    而基线**只在未按下时**更新（否则会把触摸学会忽略）⇒ 状态会**永久锁死在"按下"**。
    //    所以：每个通道的【第一次有效测量】直接把基线设为该次测量值，且**不判按下**。
    reg [N_PAD-1:0] init_done;

    integer i;

    // 当前通道的阈值（组合）
    wire [PW-1:0] base_cur = base_r[pad_idx[31:0]];
    wire [PW-1:0] thr_auto = (base_cur >> THRESH_SH);
    wire [PW-1:0] thr_eff  = (THRESH != 0) ? THRESH[PW-1:0]
                                           : ((thr_auto > ABS_MIN[PW-1:0]) ? thr_auto : ABS_MIN[PW-1:0]);
    wire [PW-1:0] hyst_val = (thr_eff >> HYST_SH) > 16'd0 ? (thr_eff >> HYST_SH) : 16'd1;
    wire [PW-1:0] thr_hi   = base_cur + thr_eff;                    // 按下阈值
    wire [PW-1:0] thr_lo   = (base_cur + thr_eff) - hyst_val;       // 松开阈值（迟滞）

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_GAP;
            wait_cnt  <= 32'd0;
            meas      <= {PW{1'b0}};
            drive_low <= 1'b0;
            pad_idx   <= 32'd0;
            pressed   <= {N_PAD{1'b0}};
            strength  <= {(N_PAD*16){1'b0}};
            touch_r   <= {N_PAD{1'b0}};
            tmo_r     <= {N_PAD{1'b0}};
            init_done <= {N_PAD{1'b0}};
            for (i = 0; i < N_PAD; i = i + 1) begin
                base_r[i] <= {PW{1'b0}};
                cnt_r[i]  <= {PW{1'b0}};
                pcnt_r[i] <= 3'd0;
                rcnt_r[i] <= 3'd0;
            end
        end else begin
            case (st)
                // ---------------- 通道间空闲 ----------------
                S_GAP: begin
                    drive_low <= 1'b0;
                    if (wait_cnt >= SCAN_DIV[31:0] - 32'd1) begin
                        wait_cnt  <= 32'd0;
                        drive_low <= 1'b1;          // 开始放电
                        st        <= S_DISCH;
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ---------------- 放电 ----------------
                S_DISCH: begin
                    if (wait_cnt >= DISCHARGE_CLKS[31:0] - 32'd1) begin
                        drive_low <= 1'b0;          // 切高阻 ⇒ 外部上拉开始充电
                        meas      <= {PW{1'b0}};
                        wait_cnt  <= 32'd0;
                        st        <= S_WAIT;
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ---------------- 测充电时间 ----------------
                S_WAIT: begin
                    if (pad_hi) begin
                        cnt_r[pad_idx[31:0]] <= meas;       // 正常：记下 RC 计数
                        tmo_r[pad_idx[31:0]] <= 1'b0;
                        st <= S_DONE;
                    end else if (wait_cnt >= MEASURE_MAX[31:0] - 32'd1) begin
                        cnt_r[pad_idx[31:0]] <= {PW{1'b1}}; // 超时 ⇒ 饱和值（开路诊断）
                        tmo_r[pad_idx[31:0]] <= 1'b1;
                        st <= S_DONE;
                    end else begin
                        meas     <= meas + {{(PW-1){1'b0}}, 1'b1};
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ---------------- 收尾：基线 + 去抖 + 力度 ----------------
                S_DONE: begin
                    // ★ 超时（电极开路/没上拉）**绝不算按下** —— fail-safe，否则会一直响
                    if (tmo_r[pad_idx[31:0]] || (cnt_r[pad_idx[31:0]] >= {PW{1'b1}})) begin
                        touch_r[pad_idx[31:0]] <= 1'b0;
                        pcnt_r[pad_idx[31:0]]  <= 3'd0;
                        rcnt_r[pad_idx[31:0]]  <= 3'd0;
                    end else if (!init_done[pad_idx[31:0]]) begin
                        // ★★ 第一次有效测量：直接用当前值当基线，**不判按下、不做去抖**
                        //    （避免"上电基线=0 ⇒ 立刻误判按下 ⇒ 永久锁死"）
                        base_r[pad_idx[31:0]]    <= cnt_r[pad_idx[31:0]];
                        init_done[pad_idx[31:0]] <= 1'b1;
                        touch_r[pad_idx[31:0]]   <= 1'b0;
                        pcnt_r[pad_idx[31:0]]    <= 3'd0;
                        rcnt_r[pad_idx[31:0]]    <= 3'd0;
                    end else if (!touch_r[pad_idx[31:0]]) begin
                        // ---- 未按下：先更新基线，再判是否达到"按下"条件 ----
                        // 注意顺序：基线只跟踪"未按下"的样本，否则会把触摸学会忽略
                        if (cnt_r[pad_idx[31:0]] > base_r[pad_idx[31:0]])
                            base_r[pad_idx[31:0]] <= base_r[pad_idx[31:0]]
                                   + ((cnt_r[pad_idx[31:0]] - base_r[pad_idx[31:0]]) >> BASE_SH);
                        else
                            base_r[pad_idx[31:0]] <= base_r[pad_idx[31:0]]
                                   - ((base_r[pad_idx[31:0]] - cnt_r[pad_idx[31:0]]) >> BASE_SH);

                        if (cnt_r[pad_idx[31:0]] > thr_hi) begin
                            if (pcnt_r[pad_idx[31:0]] >= PRESS_N[2:0] - 3'd1) begin
                                touch_r[pad_idx[31:0]] <= 1'b1;
                                pcnt_r[pad_idx[31:0]]  <= 3'd0;
                            end else begin
                                pcnt_r[pad_idx[31:0]] <= pcnt_r[pad_idx[31:0]] + 3'd1;
                            end
                        end else begin
                            pcnt_r[pad_idx[31:0]] <= 3'd0;
                        end
                    end else begin
                        // ---- 已按下：判松开（迟滞）----
                        if (cnt_r[pad_idx[31:0]] < thr_lo) begin
                            if (rcnt_r[pad_idx[31:0]] >= RELEASE_N[2:0] - 3'd1) begin
                                touch_r[pad_idx[31:0]] <= 1'b0;
                                rcnt_r[pad_idx[31:0]]  <= 3'd0;
                            end else begin
                                rcnt_r[pad_idx[31:0]] <= rcnt_r[pad_idx[31:0]] + 3'd1;
                            end
                        end else begin
                            rcnt_r[pad_idx[31:0]] <= 3'd0;
                        end
                    end

                    // ---- 力度/表情：RC 计数相对基线的**增量**（0 截止，不下溢）----
                    if (cnt_r[pad_idx[31:0]] > base_r[pad_idx[31:0]])
                        strength[pad_idx[31:0]*16 +: 16] <= cnt_r[pad_idx[31:0]] - base_r[pad_idx[31:0]];
                    else
                        strength[pad_idx[31:0]*16 +: 16] <= 16'd0;

                    // ---- 推进到下一通道 ----
                    pad_idx  <= (pad_idx == N_PAD - 1) ? 32'd0 : (pad_idx + 32'd1);
                    wait_cnt <= 32'd0;
                    st       <= S_GAP;
                end

                default: st <= S_GAP;
            endcase

            // ---- 对外输出（每通道独立，与当前扫描位置无关）----
            pressed <= touch_r;
        end
    end

    assign dbg_count0 = cnt_r[0];

endmodule

`default_nettype wire
