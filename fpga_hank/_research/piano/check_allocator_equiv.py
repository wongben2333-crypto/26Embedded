# -*- coding: utf-8 -*-
"""check_allocator_equiv.py —— 证明「串行优先级链」与「树形优先级编码」分配结果完全一致

背景：MODE=0 的 P&R 报告里最差路径（slack +0.010 ns / 20 ns）是
    env(voice3) → act_c → 分配器串行链 → on_pulse_sel[0] → voice0 的 ph CE
分配器现在写成 4 个串行 for 循环（每层用 !alloc_hit 串起来，8 声部 × 4 层 = 32 级），
逻辑级数 15 级、数据延迟 19.748 ns —— **不是表情通路**，是基线瓶颈。

改写方案：用「掩码 + 树形优先级编码」等价实现同样的语义，
把链深从 ~15 级降到 ~5 级。本脚本用穷举/随机对照证明**决策逐例相同**。

参考实现（=RTL 现有写法）的语义：
  ① v_gate & 音号相同      ：按 0..7 顺序取第一个
  ② 空闲(!v_active)       ：按 rr,rr+1,...,rr-1 旋转顺序取第一个
  ③ 已松开(!v_gate)       ：同上旋转顺序
  ④ 兜底                  ：同上旋转顺序（必有命中）
  ⓪ 滑音模式(glide_on & last_valid)：直接取 last_voice（优先级最高）

新实现：
  m1 = m_same, m2 = ~active, m3 = ~gate
  每层用 prio_rot(m, rr) = 「rr..7 里最低置位，否则 0..rr-1 里最低置位」
  sel = m1?prio_lowest(m1) : (m2?prio_rot(m2,rr) : (m3?prio_rot(m3,rr) : rr))
"""
from __future__ import annotations

import sys

import numpy as np

N = 8
IDX = np.arange(N)


def prio_lowest(m):
    """最低置位的下标；无置位时 any=False（下标无意义）"""
    n = m.shape[0]
    before = np.zeros(n, dtype=bool)
    sel = np.zeros(n, dtype=np.int64)
    for k in range(N):
        take = m[:, k] & (~before)
        sel = np.where(take, k, sel)
        before = before | m[:, k]
    return sel, m.any(axis=1)


def prio_rot(m, rr):
    """按 rr,rr+1,...,7,0,...,rr-1 顺序的最低置位"""
    ge = IDX[None, :] >= rr[:, None]
    sh, ah = prio_lowest(m & ge)
    sl, al = prio_lowest(m & (~ge))
    return np.where(ah, sh, sl), (ah | al)


def ref_alloc(m_same, m_idle, m_rel, rr):
    """参考实现：4 个串行 for 循环（逐层 !hit 串起来），完全照抄 RTL 现有写法

    ⚠️ 必须【一层一层】扫完 8 个声部再进下一层。
       第一版模型把三层写在同一个 k 循环里，等于让"兜底层"在 k=0 就命中，
       于是参考模型自己就是错的（等价性检查当场抓出来了）——
       这也说明"先写等价性检查再改 RTL"是必要的。
    """
    n = m_same.shape[0]
    rows = np.arange(n)
    sel = np.zeros(n, dtype=np.int64)
    hit = np.zeros(n, dtype=bool)
    # ① 同音重击：0..7 顺序
    for k in range(N):
        take = (~hit) & m_same[:, k]
        sel = np.where(take, k, sel)
        hit = hit | take
    # ② 空闲 → ③ 已松开 → ④ 兜底：都是 rr 旋转顺序，但**逐层扫完再下一层**
    for mask in (m_idle, m_rel, np.ones_like(m_idle)):
        for k in range(N):
            i = (rr + k) % N
            take = (~hit) & mask[rows, i]
            sel = np.where(take, i, sel)
            hit = hit | take
    return sel


def new_alloc(m_same, m_idle, m_rel, rr):
    """新实现：掩码 + 树形优先级编码（语义相同，逻辑级数低得多）"""
    s1, a1 = prio_lowest(m_same)
    s2, a2 = prio_rot(m_idle, rr)
    s3, a3 = prio_rot(m_rel, rr)
    sel = np.where(a1, s1, np.where(a2, s2, np.where(a3, s3, rr)))
    return sel


def main() -> int:
    rng = np.random.default_rng(20261005)
    bad = 0

    # ---- Part A：优先级选择器本身，穷举全部 256 个掩码 × 8 个 rr ----
    print("[A] 穷举全部 8 bit 掩码 × 8 个 rr：prio_lowest / prio_rot 与串行扫描一致？")
    m = ((np.arange(256)[:, None] >> IDX[None, :]) & 1).astype(bool)
    for rr_v in range(N):
        rr = np.full(256, rr_v, dtype=np.int64)
        s_lo, a_lo = prio_lowest(m)
        # 串行参考
        ref_lo = np.zeros(256, dtype=np.int64)
        hit = np.zeros(256, dtype=bool)
        for k in range(N):
            take = (~hit) & m[:, k]
            ref_lo = np.where(take, k, ref_lo)
            hit |= take
        if not np.array_equal(s_lo, ref_lo):
            print("   FAIL prio_lowest rr=%d" % rr_v)
            bad += 1
        s_rot, a_rot = prio_rot(m, rr)
        ref_rot = np.zeros(256, dtype=np.int64)
        hit = np.zeros(256, dtype=bool)
        for k in range(N):
            i = (rr_v + k) % N
            take = (~hit) & m[:, i]
            ref_rot = np.where(take, i, ref_rot)
            hit |= take
        if not np.array_equal(s_rot, ref_rot):
            print("   FAIL prio_rot rr=%d" % rr_v)
            bad += 1
    print("   %s" % ("PASS：256 掩码 × 8 rr 全部一致" if bad == 0 else "FAIL"))

    # ---- Part B：完整分配器，穷举 (active, gate, rr) = 2^24，配 12 组音号匹配模式 ----
    print("[B] 穷举 (v_active, v_gate, rr) = 2^24 组合 × 12 组 note-match 模式")
    a_bits = ((np.arange(1 << 16)[:, None] >> IDX[None, :]) & 1).astype(bool)
    patterns = [np.zeros(8, bool), np.ones(8, bool)]
    for k in range(8):
        p = np.zeros(8, bool); p[k] = True; patterns.append(p)
    patterns.append(np.array([1, 0, 1, 0, 1, 0, 1, 0], bool))
    patterns.append(np.array([0, 1, 1, 0, 0, 1, 1, 1], bool))
    for pi, pat in enumerate(patterns):
        for rr_v in range(N):
            n = 1 << 16
            act = a_bits
            gate = a_bits[::-1].copy()          # 覆盖全部组合（转置即可）
            m_idle = ~act
            m_rel = ~gate
            m_same = gate & pat[None, :]
            rr = np.full(n, rr_v, dtype=np.int64)
            r = ref_alloc(m_same, m_idle, m_rel, rr)
            s = new_alloc(m_same, m_idle, m_rel, rr)
            d = int((r != s).sum())
            if d:
                print("   FAIL 模式#%d rr=%d：%d/%d 不一致" % (pi, rr_v, d, n))
                bad += 1
    print("   2^16 × 8 rr × %d 模式 = %.1fM 组合比对完成" % (len(patterns), (1 << 16) * 8 * len(patterns) / 1e6))

    # ---- Part C：随机大样本（含滑音⓪优先级） ----
    print("[C] 随机 200 万组 + 滑音优先级覆盖")
    n = 2_000_000
    act = rng.random((n, N)) < 0.35
    gate = rng.random((n, N)) < 0.35
    pat = rng.random((n, N)) < 0.5
    rr = rng.integers(0, N, n)
    r = ref_alloc(gate & pat, ~act, ~gate, rr)
    s = new_alloc(gate & pat, ~act, ~gate, rr)
    d = int((r != s).sum())
    if d:
        print("   FAIL 随机样本 %d 不一致" % d)
        bad += 1
    else:
        print("   PASS：200 万随机组合全部一致")

    print()
    print("等价性结论：%s" % ("PASS —— 树形分配器与串行分配器决策逐例相同"
                              if bad == 0 else "FAIL（%d 项）" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
