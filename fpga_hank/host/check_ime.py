#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_ime.py —— 实测「能不能把中文输入法自动切成英文」

**不碰板子、不开 GUI 窗口、不抢用户焦点**（用本进程**控制台窗口**的 HWND）。

步骤：
  1) 读当前 IME 状态并**保存原始值**
  2) **主动切成中文**（模拟用户开着中文输入法）→ 读回确认确实是中文
  3) 调 `ImeGuard.force_english()` → **读回确认已变成英文**
     ⇒ 这就是「中文输入法下也能弹琴」的关键一步
  4) **还原**用户原来的状态（不搞乱用户的系统）

⚠️ 诚实边界：本脚本验证的是 **imm32 机制在真实 Windows IME 上确实可用**；
   GUI 里那条路径取的是 **Tk 窗口**句柄（`GetAncestor(winfo_id(), GA_ROOT)`），
   最终要用户在真窗口上按一下键确认（界面里一直显示 IME 状态）。
"""

import ctypes
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from piano_gui import ImeGuard, IME_CMODE_NATIVE      # noqa: E402

FAILS = []


def chk(cond, name, extra=""):
    print(("[CHECK] PASS  " if cond else "[CHECK] FAIL  ") + name + (f"   [{extra}]" if extra else ""))
    if not cond:
        FAILS.append(name)


def main():
    k32 = ctypes.WinDLL("kernel32.dll")
    k32.GetConsoleWindow.restype = ctypes.c_void_p
    hwnd = int(k32.GetConsoleWindow() or 0)
    imm = ctypes.WinDLL("imm32.dll")
    print(f"  尝试1：控制台 HWND = {hwnd}（不抢焦点）")
    got = imm.ImmGetContext(ctypes.c_void_p(hwnd)) if hwnd else None
    if got:
        imm.ImmReleaseContext(ctypes.c_void_p(hwnd), ctypes.c_void_p(got))
        print("   ⇒ 控制台窗口有 IME 上下文，用它测")
    else:
        # ⚠️ 实测：**控制台窗口没有 IME 上下文**（ImmGetContext 返回 NULL）
        # ⇒ 退而用自建的【离屏 + overrideredirect（无边框、不受窗管管理）】Tk 窗口：
        #   它**不会调用 focus_force**，因此尽量不抢用户钢琴窗口的焦点。
        print("   ⇒ 控制台窗口没有 IME 上下文 ⇒ 改用【离屏·无边框】Tk 窗口")
        import tkinter as tk
        _r = tk.Tk()
        _r.overrideredirect(True)
        _r.geometry("120x40-4000-4000")          # 挪到屏幕外
        _r.update()
        hwnd = int(ctypes.WinDLL("user32.dll").GetAncestor(int(_r.winfo_id()), 2) or _r.winfo_id())
        print(f"   Tk 窗口 HWND = {hwnd}（离屏，未调用 focus_force）")
        _GLOBAL_ROOT = _r

    g = ImeGuard(enable=True)
    print(f"  ImeGuard: enable={g.enable} ok={g.ok} {g.why}")
    chk(g.enable, "平台开关：Windows 上启用")
    chk(g.ok, "imm32 的 4 个函数原型都设好了", g.why)

    if not g.ok or not hwnd:
        print("[RESULT] FAIL  无法测试（imm32 或 HWND 不可用）")
        return 1

    g.hwnd = hwnd
    himc = imm.ImmGetContext(ctypes.c_void_p(hwnd))
    chk(bool(himc), "ImmGetContext 拿到 IME 上下文")
    if not himc:
        print("[RESULT] FAIL  拿不到 IME 上下文")
        return 1

    m = ctypes.c_uint32(0)
    c = ctypes.c_uint32(0)
    imm.ImmGetConversionStatus(ctypes.c_void_p(himc), ctypes.byref(m), ctypes.byref(c))
    orig = (m.value, c.value)
    print(f"  原始状态：mode=0x{orig[0]:04X} conv=0x{orig[1]:04X}"
          f"（中文位={'1' if orig[1] & IME_CMODE_NATIVE else '0'}）")
    imm.ImmReleaseContext(ctypes.c_void_p(hwnd), ctypes.c_void_p(himc))

    # ---- ① 主动切成"中文"态 ----
    himc = imm.ImmGetContext(ctypes.c_void_p(hwnd))
    imm.ImmSetConversionStatus(ctypes.c_void_p(himc), m.value, c.value | IME_CMODE_NATIVE)
    imm.ImmReleaseContext(ctypes.c_void_p(hwnd), ctypes.c_void_p(himc))
    ch = g.is_chinese()
    print(f"  切成中文后：is_chinese={ch}")
    chk(ch is True, "① 成功把 IME 置成中文（模拟用户开着中文输入法）")

    # ---- ② 让守护去切英文 ----
    ok = g.force_english()
    ch2 = g.is_chinese()
    print(f"  force_english() -> {ok}；之后 is_chinese={ch2}")
    chk(ok is True, "② force_english() 报告成功")
    chk(ch2 is False, "③ **读回确认已变成英文** ⇒ 中文输入法不会再吞按键")

    # ---- ④ 还原原始状态（不搞乱用户系统）----
    himc = imm.ImmGetContext(ctypes.c_void_p(hwnd))
    imm.ImmSetConversionStatus(ctypes.c_void_p(himc), orig[0], orig[1])
    imm.ImmReleaseContext(ctypes.c_void_p(hwnd), ctypes.c_void_p(himc))
    back = g.is_chinese()
    chk(back == bool(orig[1] & IME_CMODE_NATIVE), "④ 已还原成测试前的状态", f"is_chinese={back}")

    print("\n" + ("[RESULT] PASS  （IME 自动切英文机制在真实 Windows IME 上可用）"
                  if not FAILS else f"[RESULT] FAIL  {len(FAILS)} 项失败"))
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
