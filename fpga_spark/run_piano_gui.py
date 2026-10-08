"""
==============================================================================
Script: run_piano_gui.py
Description: 电脑钢琴模拟交互界面启动器
==============================================================================
"""
import os
import sys
import traceback

cur_dir = os.path.dirname(os.path.abspath(__file__))
log_file = os.path.join(cur_dir, "piano_gui.log")

try:
    with open(log_file, "w", encoding="utf-8") as f:
        f.write("Starting piano GUI launcher...\n")

    # 1. 自动定位 Python DLLs 目录并加入 DLL 搜索路径，解决 _tkinter.pyd 加载崩溃问题
    dll_dir = os.path.join(sys.prefix, "DLLs")
    if os.path.exists(dll_dir) and hasattr(os, "add_dll_directory"):
        try:
            os.add_dll_directory(dll_dir)
        except Exception as e:
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(f"add_dll_directory note: {e}\n")
    os.environ["PATH"] = dll_dir + ";" + os.environ.get("PATH", "")

    # 2. 定位 fpga_hank 目录并导入运行 piano_gui
    hank_dir = os.path.abspath(os.path.join(cur_dir, "..", "fpga_hank"))
    host_dir = os.path.join(hank_dir, "host")
    if host_dir not in sys.path:
        sys.path.insert(0, host_dir)
    os.chdir(hank_dir)

    with open(log_file, "a", encoding="utf-8") as f:
        f.write(f"Working directory: {hank_dir}\n")
        f.write("Importing piano_gui...\n")

    import piano_gui

    with open(log_file, "a", encoding="utf-8") as f:
        f.write("Calling piano_gui.main()...\n")

    piano_gui.main()

    with open(log_file, "a", encoding="utf-8") as f:
        f.write("piano_gui.main() finished successfully.\n")

except Exception:
    err_str = traceback.format_exc()
    with open(log_file, "a", encoding="utf-8") as f:
        f.write("Exception caught:\n" + err_str + "\n")
    print(err_str, file=sys.stderr)
    input("Press Enter to exit...")
