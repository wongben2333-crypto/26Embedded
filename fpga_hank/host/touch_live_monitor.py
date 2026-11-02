#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
touch_live_monitor.py —— 7寸电容触摸屏实机在线遥测与触控监控脚本
=============================================================
通过 Tang Mega 138K 板载 USB-UART (COM9 @ 115200 8N1) 实时读取
FPGA 内部纯硬件自适应触摸引擎的状态：
- 芯片型号识别：G (Goodix GT911 @ 0x14) / F (FocalTech FT5446 @ 0x38)
- 触控状态：DOWN (按下) / UP (释放)
- 实时像素物理坐标：(X, Y) 范围 0..799, 0..479
- 触控功能：顶部标签页切换、音色卡片切换、虚拟琴键弹奏
"""

import serial
import time
import sys

def main():
    port = 'COM9'
    baud = 115200
    print(f"==================================================")
    print(f"  Tang Mega 138K 纯硬件电容触摸引擎实机监听器")
    print(f"  连接端口: {port} @ {baud} bps")
    print(f"==================================================")

    try:
        ser = serial.Serial(port, baud, timeout=0.1)
    except Exception as e:
        print(f"打开串口 {port} 失败: {e}")
        return 1

    ser.reset_input_buffer()
    print("已成功连接 FPGA，正在持续监听触控事件 (按 Ctrl+C 退出)...\n")

    last_state = ""
    last_down = False
    
    try:
        while True:
            # 发送 'd' 请求一帧硬件遥测数据
            ser.write(b'd')
            time.sleep(0.04) # 25 Hz 监听
            line = ser.readline().decode('ascii', errors='ignore').strip()
            
            if 'T' in line:
                idx = line.find('T')
                sub = line[idx:] # e.g. "TG0000,000" or "TG12B0,10A"
                if len(sub) >= 9:
                    chip_code = sub[1]
                    down_code = sub[2]
                    x_hex = sub[3:6]
                    y_hex = sub[7:10]
                    
                    try:
                        x = int(x_hex, 16)
                        y = int(y_hex, 16)
                    except ValueError:
                        x, y = 0, 0
                    
                    chip_name = "Goodix GT911 (0x14)" if chip_code == 'G' else \
                                "Goodix GT911 (0x5D)" if chip_code == 'g' else \
                                "FocalTech FT5446 (0x38)" if chip_code == 'F' else "未识别/扫描中"
                    
                    is_down = (down_code == '1')
                    
                    # 状态改变或按下中持续打印
                    cur_str = f"Chip: [{chip_name}] | Status: {'>>> [PRESSED] <<<' if is_down else '[RELEASED]'} | Pos: X={x:3d}, Y={y:3d}"
                    
                    if is_down != last_down or (is_down and cur_str != last_state):
                        print(f"[{time.strftime('%H:%M:%S')}] {cur_str}")
                        last_down = is_down
                        last_state = cur_str
                        
    except KeyboardInterrupt:
        print("\n监听已停止。")
    finally:
        ser.close()

    return 0

if __name__ == '__main__':
    sys.exit(main())
