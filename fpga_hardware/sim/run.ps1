# Run the hw_input_mgr self-checking testbench with Vivado xsim.
#   powershell -NoProfile -ExecutionPolicy Bypass -File sim\run.ps1
# Exit code 0 when the run ends with "RESULT: PASS".

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$X    = "D:\Vivado\Vivado\2018.3\bin"
$rtl  = Join-Path $root "rtl"

if (-not (Test-Path "$X\xvlog.bat")) { throw "Vivado xsim not found at $X" }

$work = Join-Path $here "vivado"
New-Item -ItemType Directory -Force -Path $work | Out-Null
Push-Location $work
Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue

& "$X\xvlog.bat" -sv "$here\tb_hw_input_mgr.sv" `
    "$rtl\io\uart_tx.v" "$rtl\io\i2c_master.v" "$rtl\io\hw_input_mgr.v"
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }
& "$X\xelab.bat" tb_hw_input_mgr -s sim
if ($LASTEXITCODE -ne 0) { Pop-Location; exit 1 }
$out = & "$X\xsim.bat" sim -R 2>&1
$out | Select-String -Pattern "FAIL|\[ ok \]|RESULT|dbg"
Pop-Location

if ($out -match "RESULT: PASS") { exit 0 } else { exit 1 }
