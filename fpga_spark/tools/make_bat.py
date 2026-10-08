import os

target = os.path.join(os.path.dirname(__file__), "..", "打开电脑钢琴.bat")
target = os.path.abspath(target)

bat_text = """@echo off
cd /d "%~dp0"
set PYTHON_EXE=%LOCALAPPDATA%\\Python\\pythoncore-3.14-64\\python.exe
if not exist "%PYTHON_EXE%" set PYTHON_EXE=python.exe
"%PYTHON_EXE%" "%~dp0run_piano_gui.py"
if errorlevel 1 pause
"""

# 写入纯 ASCII 与 Windows CRLF 换行
with open(target, "wb") as f:
    f.write(bat_text.replace("\n", "\r\n").replace("\r\r\n", "\r\n").encode("ascii"))

print(f"Successfully created: {target}")
