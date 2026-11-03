# Auto-detect Gowin IDE gw_sh and run build.tcl
$GOWIN_SH_CANDIDATES = @(
    "D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe",
    "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe",
    "C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
)
$GW_SH = $GOWIN_SH_CANDIDATES | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $GW_SH) {
    Write-Host "[ERROR] Could not find gw_sh.exe. Please verify Gowin installation." -ForegroundColor Red
    exit 1
}

$PSScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TCL = Join-Path $PSScriptDir "tools\gowin\build.tcl"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Building FPGA Project with Gowin gw_sh" -ForegroundColor Cyan
Write-Host " gw_sh : $GW_SH"
Write-Host " script: $TCL"
Write-Host "==========================================================" -ForegroundColor Cyan

& $GW_SH $TCL
