# =============================================================================
#  check_portability.ps1 —— 交付前检查：Gowin 工程是否"换台机器就打不开"
#
#  背景（本机实测结论，见 references/traps.md §7）：
#    · Gowin 的 .gprj 里 <File path="..."> 一律是【绝对路径】（含用户名与空格）；
#      实测用相对路径 add_file 也会被规范化成绝对路径 —— 无法规避。
#    · 把工程目录整体复制/移动到别处后，直接打开旧 .gprj 综合会硬失败：
#        ERROR (EX5998): Cannot open Verilog file '<旧绝对路径>'
#    · 正确交付姿势：交付【源码 + 约束 + build.tcl】，在目标机上重新生成工程。
#      本项目 tools/gowin/build.tcl 已用 [file dirname [info script]] 定位 ROOT，
#      因此重建是可靠的一键操作。
#
#  退出码：0 = 没找到 .gprj（走 Tcl 重建路线，最省事）
#          3 = 有 .gprj 且含绝对路径，但旁边有 build.tcl（正常；按提示重建即可）
#          1 = 有 .gprj 且含绝对路径，且【找不到 build.tcl】→ 真正的交付风险
# =============================================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$ScanDir      = ""
)

if (-not $ProjectRoot) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}
if (-not $ScanDir) { $ScanDir = Join-Path $ProjectRoot 'fpga_hank' }

$gprjs = @(Get-ChildItem -Path $ScanDir -Recurse -Filter *.gprj -ErrorAction SilentlyContinue)
$tlcs  = @(Get-ChildItem -Path $ScanDir -Recurse -Filter 'build.tcl' -ErrorAction SilentlyContinue)

Write-Host "[portability] 扫描 $ScanDir"
Write-Host "[portability] 找到 .gprj $($gprjs.Count) 个，build.tcl $($tlcs.Count) 个"

if ($gprjs.Count -eq 0) {
    Write-Host "[portability] 没有 .gprj —— 交付走「源码 + Tcl 重建」路线，无绝对路径依赖。" -ForegroundColor Green
    exit 0
}

$bad = 0
foreach ($g in $gprjs) {
    $lines = Select-String -Path $g.FullName -Pattern '<File\s+path="([^"]+)"' -Encoding UTF8 -AllMatches
    $abs = @(); $rel = @(); $missing = @()
    foreach ($m in $lines.Matches) {
        $p = $m.Groups[1].Value
        if ($p -match '^[A-Za-z]:/' -or $p -match '^\\\\' -or $p -match '^/') {
            $abs += $p
            if (-not (Test-Path ($p -replace '/', '\'))) { $missing += $p }
        } else {
            $rel += $p
        }
    }
    Write-Host ""
    Write-Host "== $($g.FullName.Replace($ProjectRoot, '.')) =="
    Write-Host "   绝对路径条目 $($abs.Count) / 相对路径条目 $($rel.Count)"
    if ($missing.Count -gt 0) {
        Write-Host "   ⚠ 其中 $($missing.Count) 个源文件当前已不存在（工程已失效）:" -ForegroundColor Yellow
        $missing | Select-Object -First 3 | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
    }
    if ($abs.Count -gt 0) {
        $bad++
        Write-Host "   → 该工程【不可移植】：换机器/换路径后 Gowin 会报 EX5998。" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($bad -gt 0 -and $tlcs.Count -eq 0) {
    Write-Host "[portability] FAIL：存在不可移植工程，且找不到 build.tcl（无法一键重建）。" -ForegroundColor Red
    Write-Host "   建议：补一个 build.tcl（用 [file dirname [info script]] 定位 ROOT），" -ForegroundColor Red
    Write-Host "         并把 eda_proj/ 视为可丢弃产物（不要作为交付物依赖）。" -ForegroundColor Red
    exit 1
}
if ($bad -gt 0) {
    Write-Host "[portability] 有绝对路径工程（Gowin 的固有行为），但可用 Tcl 一键重建 —— 正常。" -ForegroundColor Yellow
    foreach ($t in $tlcs) {
        Write-Host "   重建命令：& 'F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' '$($t.FullName)'"
    }
    Write-Host "   交付建议：交付 源码 + 约束 + build.tcl + 已生成的 .fs；" -ForegroundColor Cyan
    Write-Host "             【不要】依赖 eda_proj/*.gprj —— 它绑定了本机绝对路径。" -ForegroundColor Cyan
    exit 3
}
Write-Host "[portability] PASS：所有工程文件都用相对路径。" -ForegroundColor Green
exit 0
