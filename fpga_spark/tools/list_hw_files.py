import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

base = r"C:\Users\gjl50\Desktop\嵌赛\Tang_Mega_60K_138K硬件资料"
print("Base exists:", os.path.exists(base))
if os.path.exists(base):
    for root, dirs, files in os.walk(base):
        print("DIR:", root)
        for f in files:
            print("  FILE:", f)
