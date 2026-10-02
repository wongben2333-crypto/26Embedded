# =============================================================================
#  run_lint.ps1 —— Lint 门禁（verilator --lint-only + Verible）
#
#  设计原则：**工具缺失时绝不返回 0**。返回 3 = SKIPPED，让调用方无法把
#  "没跑" 误当成 "通过"（这是 verilog-review / 验证流程最容易自欺的地方）。
#
#  安装指引见 _research/fpga-tools/INSTALL-PLAN.md（P0 oss-cad-suite / P2 Verible）。
# =============================================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$RtlDir      = "",
    [string]$TopModule   = "top",
    [string]$OutDir      = "",
    [string[]]$ExtraFiles = @()
)

$ErrorActionPreference = 'Stop'

if (-not $ProjectRoot) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}
if (-not $RtlDir) { $RtlDir = Join-Path $ProjectRoot 'fpga_hank\rtl' }
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'fpga_hank\out\verify' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# 收集 RTL（排除 testbench）
$files = @()
if (Test-Path $RtlDir) {
    $files += Get-ChildItem -Path $RtlDir -Recurse -Include *.v, *.sv |
              Where-Object { $_.FullName -notmatch '\\tb\\|\\sim\\' } |
              ForEach-Object { $_.FullName }
}
$files += $ExtraFiles
if ($files.Count -eq 0) {
    Write-Host "[lint] 未找到 RTL 文件（$RtlDir）" -ForegroundColor Yellow
    exit 2
}

function Get-Tool([string]$name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

$verilator = Get-Tool 'verilator'
$veribleLint = Get-Tool 'verible-verilog-lint'

Write-Host "[lint] RTL 文件 $($files.Count) 个"
Write-Host "[lint] verilator        : $(if ($verilator) { $verilator } else { '未安装' })"
Write-Host "[lint] verible-verilog-lint : $(if ($veribleLint) { $veribleLint } else { '未安装' })"

$anyRun = $false
$failed = @()

if ($verilator) {
    $anyRun = $true
    $log = Join-Path $OutDir 'verilator-lint.log'
    Write-Host "[lint] ==> verilator --lint-only -Wall"
    # --lint-only 不需要 C++ 编译器；-Wno-fatal 让全部告警都记录下来再判定
    & $verilator --lint-only -Wall -Wno-fatal --top-module $TopModule @files 2>&1 |
        Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) { $failed += "verilator(--lint-only) exit=$LASTEXITCODE" }
    Write-Host "[lint] verilator 日志: $log"
}

if ($veribleLint) {
    $anyRun = $true
    $log = Join-Path $OutDir 'verible-lint.log'
    Write-Host "[lint] ==> verible-verilog-lint"
    & $veribleLint --rules_config_search @files 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) { $failed += "verible-verilog-lint exit=$LASTEXITCODE" }
    Write-Host "[lint] verible 日志: $log"
}

if (-not $anyRun) {
    Write-Host ""
    Write-Host "[lint] SKIPPED：verilator 与 verible 都未安装 —— 本次【没有】做 lint。" -ForegroundColor Yellow
    Write-Host "       安装：见 _research/fpga-tools/INSTALL-PLAN.md" -ForegroundColor Yellow
    Write-Host "         P0  oss-cad-suite（含 verilator）   P2  Verible win64 zip" -ForegroundColor Yellow
    Write-Host "       注意：verilator --lint-only 不需要 C++ 编译器，装上即可用。" -ForegroundColor Yellow
    exit 3
}

if ($failed.Count -gt 0) {
    Write-Host "[lint] FAIL:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "[lint] PASS" -ForegroundColor Green
exit 0
