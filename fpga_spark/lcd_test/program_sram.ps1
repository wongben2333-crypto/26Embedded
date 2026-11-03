# Quick SRAM programming shortcut
$PSScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptDir "tools\gowin\program.ps1") -Mode sram
