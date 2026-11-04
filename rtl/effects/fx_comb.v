// =============================================================================
//  fx_comb.v —— Schroeder/Freeverb 并联梳状滤波器（一个梳状支路）
//
//  用途：硬件混响的 4 条并联梳状支路之一。4 条各自不同延迟长度、并联求和，
//        再串两个全通扩散器（fx_allpass.v），就是经典的 Schroeder 混响结构。
//
//  ===========================================================================
//  ★ 结构（Freeverb 的 comb，逐字对应它的 C 参考实现）
//  ===========================================================================
//      d[n]   = 延迟线在 (wr_ptr - DLY) 处的值        ← 即 y[n-DLY]，本支路输出
//      lp[n]  = (d[n]*DAMP_NEW + lp[n-1]*DAMP_OLD) >> 8     ← 反馈路径里的一阶低通
//      wr     = sat16( x[n] + (lp[n]*fb) >> 8 )            ← 写回延迟线
//      y[n]   = d[n]                                        ← 支路输出
//
//    · DAMP_NEW + DAMP_OLD 必须【恰好 = 256】(Q8)。这不只是"系数归一"的美学：
//      两个系数和 = 256 ⇒ lp 是两个操作数的**凸组合**，结果必然落在
//      [min(d,lp), max(d,lp)] 内 ⇒ **数学上不可能溢出**，也就不需要在 lp 上做
//      饱和。参考实现 xls32-fpga-synth 在这里翻过车，原文（M14 里程碑）：
//        "**Damping must be `(old+new)/2`, not `0.875·old+0.125·new`.** A small-step
//         damping shift (`>>3`) both crushed the audio band (→ short tail *regardless*
//         of `g`) and could push `curdlp + Δ` past ±32767 and **wrap** the 16-bit
//         state → sign flip → runaway feedback. Averaging (`>>1`) is inherently
//         overflow-safe (result always between its two operands) *and* preserves the band."
//      本模块取 DAMP_OLD=64 / DAMP_NEW=192（= Freeverb damp≈0.25，轻阻尼），
//      和恰好 256，因此同样具备"凸组合不溢出"的性质。
//      对比它踩坑的 0.875/0.125——那组系数和也是 1，但它是用**小步移位**实现的，
//      中间量 `lp*Δ` 单独累加时越过了 16 bit。所以本模块的乘法一律在
//      **全宽（24/25 bit）网络上形成后再移位**，绝不在 16 bit 状态上原地累加。
//
//  ===========================================================================
//  ★ 读地址为什么是 `wr_ptr - DLY + 1`（这个 +1 是最容易错的地方，务必看懂）
//  ===========================================================================
//    BSRAM 是**同步读**：本拍给地址，下一拍出数据。而写指针在 sample_tick
//    的边沿自增、写动作在下一拍（tick_d）发生。于是：
//        · 第 T 拍   : sample_tick=1，本拍结束时 wr_ptr 自增为 a[n]
//        · 第 T+1 拍 : tick_d=1，本拍结束时把 y[n] 写进 mem[wr_ptr] = mem[a[n]]
//                     同时本拍的读地址 rd_addr(T+1) = a[n] - DLY + 1
//        · 而我们在第 T+1 拍用到的 rd_data，是**第 T 拍采样的地址**的读出结果，
//          即 mem[rd_addr(T)]。第 T 拍时 wr_ptr 还是 a[n-1]，所以
//              rd_addr(T) = a[n-1] - DLY + 1 = a[n] - DLY
//          ⇒ rd_data(T+1) = mem[a[n] - DLY] = **y[n-DLY]** ✅ 正是我们要的。
//    若把 +1 去掉，读出来的就是 y[n-DLY-1]，整个混响的所有延迟长度都差 1 个
//    采样点——听不出来，但脉冲响应测试会立刻抓到，而且 4 条梳状支路的相对
//    关系全错。本项目在 song_player 上已经吃过一次同类的 off-by-one。
//
//  ⚠️ 约束：**DLY ≥ 2** 且 DLY ≤ DEPTH-1（DEPTH 必须是 2 的幂，借位自动回绕）。
//    为什么 DLY 不能是 1 —— 两条独立的理由，都来自官方文档（不是猜的）：
//      · SUG949《Gowin HDL 编码风格用户指南》§8 明文警告：
//        「不要同时对同一地址的 RAM 进行读写操作。」
//        DLY=1 时，读地址 rd_addr(T+1) = a[n] 恰好等于同一拍要写的地址 a[n] ⇒ 违规。
//      · UG300《Arora V 存储器用户指南》注 1：**138K 器件不支持 Read-before-Write
//        模式**（WRITE_MODE 只能用 Normal / write-through）。也就是说"同址读写时
//        读回旧值"这个行为根本不能用，必须靠【地址错开】来保证读的是旧数据。
//    本设计所有延迟线的 DLY 都远大于 2（最短是合唱的 771），所以天然满足。
//    ⇒ 这也是本模块**故意不用**"缓冲长度恰好等于延迟、就在 wr_ptr 处读"那种
//      写法的原因：那种写法依赖同址读回旧值 = read-before-write，我们的器件不支持。
// =============================================================================
`default_nettype none

module fx_comb #(
    parameter integer AW       = 12,      // 地址位宽，DEPTH = 2^AW
    parameter integer DEPTH    = 4096,
    parameter integer DLY      = 2471,    // 本支路延迟长度（采样点）
    // ---- 阻尼系数：必须是 Freeverb 默认阻尼【按采样率重算】后的值 ----
    //  Freeverb 的阻尼级是一阶低通 `fs_out = d*damp2 + fs_prev*damp1`，
    //  其转折频率 **与采样率成正比**。我们的采样率是 44.1 kHz 的 2.2144 倍，
    //  若照抄 44.1 kHz 的系数，高频会少衰减 2.2144 倍 ⇒ **尾巴明显偏亮**。
    //  保持转折频率不变的重算公式：damp1_new = 1 - (1 - damp1_old)^(1/k)，
    //  k = 97656.25/44100 = 2.2144286：
    //      1 - (1 - 0.20)^(1/2.2144286) = 1 - 0.8^0.4516 = 0.0959
    //  ⇒ damp1 = 0.096、damp2 = 0.904 ⇒ Q8 取 **25 / 231**（和恰为 256）。
    //  （这是 dsh-plugins 从 Freeverb 源码 tuning.h 的注释
    //    "These values assume 44.1KHz … but would need scaling for 96KHz" 推出的；
    //     数学确定，但**未上板听感验证**——本模块如实标注这一点。）
    parameter integer DAMP_OLD = 25,      // Q8，必须与 DAMP_NEW 之和 = 256
    parameter integer DAMP_NEW = 231      // Q8
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,   // 1 clk 脉冲
    input  wire               clr_en,        // 清缓冲（上电必须做，见 audio_fx.v）
    input  wire [14:0]        clr_addr,
    input  wire signed [15:0] x,
    input  wire [7:0]         fb_q8,         // Q8 反馈系数（必须 < 256 才稳定）
    output wire signed [15:0] y              // 本支路输出 = y[n-DLY]
);

    localparam integer DLY_C = (DLY < 1) ? 1 : ((DLY > DEPTH-1) ? DEPTH-1 : DLY);

    reg  signed [15:0] mem [0:DEPTH-1];
    reg  [AW-1:0]      wr_ptr;
    reg  signed [15:0] lp;                   // 阻尼低通状态
    reg  signed [15:0] d_rd;                 // 同步读数据
    reg                tick_d;

    // 见文件头推导：+1 用来抵消"写指针在 tick 边沿自增、写动作晚一拍"
    wire [AW-1:0] rd_addr = wr_ptr - (DLY_C[AW-1:0] - 1'b1);

    // ---------------------------------------------------------- 组合计算 ----
    // ★ 全部乘法在【全宽】上形成后再移位（本项目在包络/变调乘法上反复踩过
    //   "先截断再移位 → 变噪声"的坑，这里同理）。
    // ⚠️⚠️ 阻尼系数必须声明成【无符号】再显式零扩展，**绝不能声明成 signed [7:0]** ⚠️⚠️
    //  这是本项目花最久才定位的一个 bug，教训很典型，写在这里：
    //      `localparam signed [7:0] DAMP_NEW_C = 231;`
    //  在 Verilog 里 **231 的 8 bit 有符号表示是 −25**（0xE7 的补码）。
    //  一旦它变成负系数，阻尼级 `lp = (d·damp_new + lp·damp_old)>>8` 就变成
    //  `lp = (−25·d + 25·lp)>>8`，后果是**两个**：
    //    ① 直流增益变成 (25−25)/256 = **0** ⇒ 梳状反馈的直流通路被切断
    //       ⇒ 梳状状态几拍内就掉到 0（实测 c0.d_rd 从 ~2971 掉到 1）；
    //    ② 负系数进了反馈环 ⇒ 变成**振荡器**，状态在饱和轨之间翻转
    //       ⇒ 全通级被大信号顶到 ±32767 并**自持不衰减**
    //       （现象长得像"全通坏了"，其实是梳状送进来的信号本身就是振的）。
    //  ⇒ 正确写法就是其它模块里的那一套：系数用【无符号】常量，
    //     乘法时用 $signed({1'b0, X}) 显式补一个 0 变正数。
    //  ⚠️ 通用规则：**凡系数可能 >127，就绝不能声明成 signed [7:0]。**
    localparam [7:0] DAMP_NEW_C = DAMP_NEW;
    localparam [7:0] DAMP_OLD_C = DAMP_OLD;

    wire signed [23:0] p_new = d_rd * $signed({1'b0, DAMP_NEW_C});
    wire signed [23:0] p_old = lp   * $signed({1'b0, DAMP_OLD_C});
    wire signed [24:0] damp_f = p_new + p_old;
    // DAMP_OLD+DAMP_NEW=256 ⇒ |damp_f| ≤ 256·32768 = 2^23 ⇒ >>8 后必在 17 bit 内，
    // 无需饱和（这就是"凸组合"的好处）
    wire signed [16:0] lp_n = damp_f >>> 8;

    wire signed [24:0] fb_f = lp_n * $signed({1'b0, fb_q8});
    wire signed [16:0] fb_s = fb_f >>> 8;
    wire signed [17:0] wr_f = {x[15], x} + {{1'b0, fb_s[16]}, fb_s};
    wire signed [15:0] wr_n = sat16(wr_f);

    function signed [15:0] sat16;
        input signed [17:0] v;
        begin
            if      (v > 18'sd32767)  sat16 = 16'sd32767;
            else if (v < -18'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    assign y = d_rd;

    // -------------------------------------------------------------- 时序 ----
    // ⚠️ 一个数组只能有【一处】写语句。写成"两个 always 各写一次"会被推断成
    //    双口 BSRAM，然后工具报一个关于 DPB 写模式的莫名其妙错误（本项目记录过）。
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {AW{1'b0}};
            lp     <= 16'sd0;
            d_rd   <= 16'sd0;
            tick_d <= 1'b0;
        end else begin
            tick_d <= sample_tick;

            // ---- 唯一的一处写：清缓冲优先，其次才是正常写 ----
            if (clr_en) begin
                mem[clr_addr[AW-1:0]] <= 16'sd0;
            end else if (tick_d) begin
                mem[wr_ptr] <= wr_n;
            end

            // 写指针在 sample_tick 边沿自增（写动作晚一拍，见文件头推导）
            if (sample_tick && !clr_en) wr_ptr <= wr_ptr + 1'b1;

            // 同步读（每拍都读，地址由 wr_ptr 组合产生，采样期内稳定）
            d_rd <= mem[rd_addr];

            // 阻尼低通状态（只在有效采样点更新；清缓冲期间冻结）
            if (tick_d && !clr_en) lp <= lp_n;
        end
    end

endmodule

`default_nettype wire
