# =============================================================================
#  run_formal.ps1 —— 形式验证门禁（SymbiYosys / sby）
#
#  工具缺失时返回 3 = SKIPPED（绝不返回 0，避免"没跑"被当成"证明通过"）。
#  sby 随 oss-cad-suite 一起装（Windows 包内含 sby + z3/boolector/cvc5），
#  见 _research/fpga-tools/INSTALL-PLAN.md P0 与 FINDINGS.md §4。
# =============================================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$SbyDir      = "",
    [string]$OutDir      = "",
    [int]$TimeoutSec     = 600
)

$ErrorActionPreference = 'Stop'

if (-not $ProjectRoot) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}
if (-not $SbyDir) { $SbyDir = Join-Path $PSScriptRoot '..\templates\formal' }
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'fpga_hank\out\verify\formal' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$sby = (Get-Command 'sby' -ErrorAction SilentlyContinue).Source
if (-not $sby) {
    Write-Host "[formal] SKIPPED：未安装 sby（SymbiYosys）—— 本次【没有】做形式验证。" -ForegroundColor Yellow
    Write-Host "         安装：oss-cad-suite（Windows 包内含 sby + z3/boolector/cvc5）" -ForegroundColor Yellow
    Write-Host "         见 _research/fpga-tools/INSTALL-PLAN.md P0" -ForegroundColor Yellow
    exit 3
}

$tasks = Get-ChildItem -Path $SbyDir -Filter *.sby -ErrorAction SilentlyContinue
if (-not $tasks -or $tasks.Count -eq 0) {
    Write-Host "[formal] $SbyDir 下没有 .sby 任务" -ForegroundColor Yellow
    exit 2
}

$failed = @()
foreach ($t in $tasks) {
    Write-Host "[formal] ==> sby $($t.Name)"
    $work = Join-Path $OutDir $t.BaseName
    Push-Location $OutDir
    try {
        & $sby -f $t.FullName -d $work 2>&1 | Tee-Object -FilePath (Join-Path $OutDir "$($t.BaseName).log")
        if ($LASTEXITCODE -ne 0) { $failed += $t.Name }
    } finally {
        Pop-Location
    }
}

if ($failed.Count -gt 0) {
    Write-Host "[formal] FAIL: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "[formal] PASS（$($tasks.Count) 个任务）" -ForegroundColor Green
exit 0
