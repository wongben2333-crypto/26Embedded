# -*- coding: utf-8 -*-
"""
Tang Mega 138K ToF 测距与 I2C 总线调试控制台监视器
通过串口实时接收 FPGA 发来的诊断报文，动态显示距离、设备 ID、ACK/NACK 与总线电平。
"""
import sys, time, re
try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.exit("请先安装 pyserial: pip install pyserial")

def find_default_port():
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        if "COM8" in p.device:
            return "COM8"
    if ports:
        return ports[0].device
    return "COM8"

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else find_default_port()
    baud = 115200

    print("=" * 70)
    print(" Tang Mega 138K - ToF 测距与 I2C 调试监视器")
    print(f" 连接串口: {port} @ {baud} 8N1")
    print(" 提示: 按板载按键 Key0 (AB13) 可随时命令 FPGA 重新执行全总线 I2C 扫描")
    print("=" * 70)

    try:
        ser = serial.Serial(port, baud, timeout=1.0)
        ser.reset_input_buffer()
    except Exception as e:
        print(f"[ERROR] 无法打开串口 {port}: {e}")
        print("请检查 USB 线连接及端口占用。")
        sys.exit(1)

    print(f"[OK] 串口 {port} 已打开，正在等待硬件诊断报文...\n")

    # Pattern: [TOF] BUS=1 ADDR=0x52 ID=0x4A DIST= 245 mm ACK=003C NACK=0000 S1=1,1 S2=1,1
    pat = re.compile(
        r"\[TOF\]\s+BUS=(\d+)\s+ADDR=0x([0-9A-Fa-f]+)\s+ID=0x([0-9A-Fa-f]+)\s+DIST=\s*([0-9\-]+)\s*mm\s+ACK=([0-9A-Fa-f]+)\s+NACK=([0-9A-Fa-f]+)\s+S1=(\d),(\d)\s+S2=(\d),(\d)"
    )

    try:
        while True:
            line = ser.readline().decode("ascii", errors="replace").strip()
            if not line:
                continue

            m = pat.match(line)
            if m:
                bus = m.group(1)
                addr = m.group(2)
                dev_id = m.group(3)
                dist_str = m.group(4)
                ack_hex = m.group(5)
                nack_hex = m.group(6)
                scl1, sda1 = m.group(7), m.group(8)
                scl2, sda2 = m.group(9), m.group(10)

                ack_cnt = int(ack_hex, 16)
                nack_cnt = int(nack_hex, 16)
                total = ack_cnt + nack_cnt
                rate = (ack_cnt / total * 100.0) if total > 0 else 0.0

                if dist_str != "----":
                    dist_mm = int(dist_str)
                    bar_len = min(40, max(0, dist_mm // 25))
                    bar = "■" * bar_len + " " * (40 - bar_len)
                    status_text = f"\033[92m[ONLINE]\033[0m 距离: \033[93m{dist_mm:4d} mm\033[0m ({dist_mm/10.0:4.1f} cm) |{bar}|"
                else:
                    status_text = "\033[91m[OFFLINE / NACK]\033[0m 未检测到有效测距响应 (距离: ---- mm)"

                dev_type = " (VB22B 匹配!)" if dev_id.upper() == "4A" else ""

                print(f"\r{status_text} | 总线:Bus{bus}(0x{addr}) ID:0x{dev_id}{dev_type} | ACK:{ack_cnt} NACK:{nack_cnt} ({rate:.1f}%) | 电平:[B1: {scl1},{sda1} B2: {scl2},{sda2}]", end="", flush=True)
            else:
                print(f"\n{line}")
    except KeyboardInterrupt:
        print("\n[INFO] 用户终止监控。")
    finally:
        ser.close()

if __name__ == "__main__":
    main()
