# =============================================================================
#  tests/run_selfcheck.ps1 —— 一条命令自检整个 fpga-verify skill
#
#  只使用本机已具备的工具（Python 3.14 + numpy/scipy + ModelSim）。
#  不含 verilator/iverilog/sby 的部分 → 那两个门禁预期返回 3（SKIPPED，属正常）。
#
#  用法： powershell -ExecutionPolicy Bypass -File tests\run_selfcheck.ps1
#  退出码 0 = 全部符合预期
# =============================================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$RunModelSim
)

$ErrorActionPreference = 'Continue'
$sk = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ProjectRoot) { $ProjectRoot = (Resolve-Path (Join-Path $sk '..\..\..')).Path }

$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { Write-Host "找不到 python" -ForegroundColor Red; exit 2 }

$script:results = @()
function Check([string]$name, [int]$expected, [scriptblock]$body) {
    Write-Host ""
    Write-Host "=== $name (期望 exit=$expected) ===" -ForegroundColor Cyan
    & $body
    $code = $LASTEXITCODE
    $ok = ($code -eq $expected)
    $script:results += [pscustomobject]@{ 检查 = $name; 期望 = $expected; 实际 = $code; 结论 = $(if ($ok) { 'OK' } else { 'MISMATCH' }) }
    if (-not $ok) { Write-Host "!! 实际 exit=$code" -ForegroundColor Red }
}

$tmp = Join-Path $PSScriptRoot '_sc'
New-Item -ItemType Directory -Force $tmp | Out-Null

Check "derive_fs 推导采样率" 0 { & $py "$sk\scripts\derive_fs.py" --project-root $ProjectRoot }
Check "derive_fs 拒绝错误的 48000 假设" 1 { & $py "$sk\scripts\derive_fs.py" --project-root $ProjectRoot --expect 48000 }

Check "合成 32 音 → 频谱 EXPECTED PASS" 0 {
    & $py "$sk\scripts\make_fixture.py" --out "$tmp\ok.txt" | Out-Null
    & $py "$sk\scripts\spectrum_report.py" --file "$tmp\ok.txt" --fs 48828.125 --no-plot
}
Check "削波信号 → 必须被检出（灵敏度对照）" 1 {
    & $py "$sk\scripts\make_fixture.py" --out "$tmp\clip.txt" --clip 0.5 | Out-Null
    & $py "$sk\scripts\spectrum_report.py" --file "$tmp\clip.txt" --fs 48828.125 --no-plot
}
Check "只发 16 音、用 32 路判据 → 必须报未命中（负对照）" 1 {
    & $py "$sk\scripts\make_fixture.py" --out "$tmp\half.txt" --count 16 | Out-Null
    & $py "$sk\scripts\spectrum_report.py" --file "$tmp\half.txt" --fs 48828.125 --no-plot
}

Check "延迟统计（合成 200 点，含 8ms 离群）" 0 {
    1..200 | ForEach-Object { if ($_ -eq 137) { 2000 } else { 1900 + ($_ % 5) * 5 } } |
        Set-Content "$tmp\lat.csv" -Encoding ascii
    & $py "$sk\scripts\latency_stats.py" --file "$tmp\lat.csv" --unit us --jitter-ms 200
}

# 红线自审：0=无红线、3=有需人工确认项，都算通过；1=命中红线才算失败
Write-Host ""
Write-Host "=== 红线自审（0 或 3 均通过；1 = 命中红线）===" -ForegroundColor Cyan
& $py "$sk\scripts\audit_compliance.py" --root (Join-Path $ProjectRoot 'fpga_hank')
$aud = $LASTEXITCODE
$script:results += [pscustomobject]@{ 检查 = 'audit_compliance'; 期望 = '0 或 3'; 实际 = $aud; 结论 = $(if ($aud -in 0, 3) { 'OK' } else { 'MISMATCH' }) }

# lint / formal 门禁：未安装工具时必须返回 3，绝不能是 0
Write-Host ""
Write-Host "=== lint / formal 门禁（未装工具应为 3 = SKIPPED）===" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\scripts\run_lint.ps1" -ProjectRoot $ProjectRoot
$lint = $LASTEXITCODE
& powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\scripts\run_formal.ps1" -ProjectRoot $ProjectRoot
$formal = $LASTEXITCODE
$script:results += [pscustomobject]@{ 检查 = 'run_lint 门禁'; 期望 = '0 或 3'; 实际 = $lint; 结论 = $(if ($lint -in 0, 3) { 'OK' } else { 'MISMATCH' }) }
$script:results += [pscustomobject]@{ 检查 = 'run_formal 门禁'; 期望 = '0 或 3'; 实际 = $formal; 结论 = $(if ($formal -in 0, 3) { 'OK' } else { 'MISMATCH' }) }

# 真实 ModelSim dump（可选）
$real = Join-Path $PSScriptRoot 'tone_samples.txt'
if ($RunModelSim -or (Test-Path $real)) {
    if (-not (Test-Path $real)) {
        Write-Host "`n=== 用 ModelSim 生成真实 dump ===" -ForegroundColor Cyan
        Push-Location $PSScriptRoot
        & 'F:\Modelsim_10.7\win64\vsim.exe' -c -do run_spectrum.do | Out-Null
        Pop-Location
    }
    Write-Host "`n=== 真实 RTL dump 取证（达标 0 / 增益不均 4 都算符合预期）===" -ForegroundColor Cyan
    & $py "$sk\scripts\spectrum_report.py" --file $real --plot "$PSScriptRoot\spectrum_32peaks.png" `
        --md-out "$PSScriptRoot\EVIDENCE-spectrum.md" --json-out "$PSScriptRoot\summary.json"
    $rc = $LASTEXITCODE
    $script:results += [pscustomobject]@{ 检查 = '真实 dump 取证'; 期望 = '0 或 4'; 实际 = $rc; 结论 = $(if ($rc -in 0, 4) { 'OK' } else { 'MISMATCH' }) }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================== 自检汇总 ====================" -ForegroundColor Cyan
$script:results | Format-Table -AutoSize | Out-String | Write-Host
$bad = @($script:results | Where-Object { $_.结论 -ne 'OK' })
if ($bad.Count -eq 0) {
    Write-Host "SELFCHECK: PASS（$($script:results.Count) 项全部符合预期）" -ForegroundColor Green
    exit 0
}
Write-Host "SELFCHECK: FAIL（$($bad.Count) 项不符）" -ForegroundColor Red
exit 1
