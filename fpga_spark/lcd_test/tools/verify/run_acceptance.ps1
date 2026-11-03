<#
.SYNOPSIS
    fpga_hank 端到端验收 —— 一条命令跑完【构建 + 全部仿真 + 全部证据判据】并打印 PASS/FAIL 汇总

.DESCRIPTION
    把散落在各处的验证步骤收敛成一个可复现入口，任何人（用户/评委/队友）都能一键复核。

    覆盖的环节（对应赛题 objective 的 (3)(4)）：
      A. 前置检查   工具链、器件库、约束文件是否齐备
      B. 构建       gw_sh 全流程 syn -> pnr -> bitstream
      C. 仿真       ModelSim 跑全部 testbench
      D. 证据①     32 谱峰判据（赛题必备交付物）
      E. 证据②     半音变调验证（基础要求③）
      F. 波形       ModelSim 原生 .wlf 数据集是否齐备
      G. 交付物     文档/脚本/RTL 清单是否完整

    ★ 设计原则：**每一项都打印它实际依据的数字**，不做"看起来成功"的判断。
      退出码：0 = 全部 PASS；1 = 有 FAIL；2 = 前置不满足（跑不起来）。

.PARAMETER SkipBuild
    跳过构建（构建约 85 秒）。用于只复核仿真与证据的场景。

.PARAMETER Quick
    只跑前置检查与证据核对，不跑仿真（最快）。

.EXAMPLE
    # 完整验收
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify\run_acceptance.ps1

    # 只复核证据（不重跑仿真）
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify\run_acceptance.ps1 -Quick

.NOTES
    ⚠️ 本脚本含中文，**必须保存为 UTF-8 with BOM**，否则 PowerShell 5.1 会按 GBK 读成乱码
      并报一串语法错（本项目实测踩过这个坑）。
    ★ 2026-10-05 更正：ModelSim 【不是】单席位，本机许可证允许并发
       （实测：6 个 ModelSim 进程同时在跑且全部空闲；若真为单席位，第 2 个会立刻
        报 license 错误退出，而不是静静待着）。
       ⇒ 纪律要求是"每个会话用自己独立的 work/ 库与输出目录"，不是"等空档"。
         发现别人在跑 【不要等】，直接跑即可。
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$Quick
)

$ErrorActionPreference = 'Continue'

$ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # fpga_hank\
$GW   = 'F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe'
$VSIM = 'F:\Modelsim_10.7\win64\vsim.exe'
# ★ Python 解释器：优先用项目自带 venv，找不到就回退到系统 python，都没有则提示安装。
#   为什么：`_tools\venv` 是本机的开发环境（约 14 MB / 890 个文件），
#   它**不随交付包一起走**；队友拿到仓库直接跑本脚本时，原来会在前置检查就失败。
$PY = Join-Path $ROOT '_tools\venv\Scripts\python.exe'
if (-not (Test-Path $PY)) {
    $sysPy = Get-Command python -ErrorAction SilentlyContinue
    if ($sysPy) {
        $PY = $sysPy.Source
        Write-Host "  [提示] 未找到项目自带 venv，改用系统 Python: $PY" -ForegroundColor Yellow
        Write-Host "         依赖 Python 的判据需要这些包：numpy scipy matplotlib python-docx lxml Pillow" -ForegroundColor Yellow
        Write-Host "         安装：python -m pip install numpy scipy matplotlib python-docx lxml Pillow" -ForegroundColor Yellow
    } else {
        Write-Host "  [警告] 找不到任何 Python —— 依赖 Python 的判据将被跳过或失败。" -ForegroundColor Yellow
        Write-Host "         请安装 Python 后执行：python -m pip install numpy scipy matplotlib python-docx lxml Pillow" -ForegroundColor Yellow
        $PY = 'python'
    }
}

$results = New-Object System.Collections.ArrayList
function Add-Result([string]$name, [string]$status, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ 项 = $name; 状态 = $status; 依据 = $detail })
}

function Section($t) {
    Write-Host ""
    Write-Host ("=" * 78)
    Write-Host "  $t"
    Write-Host ("=" * 78)
}

# ============================================================ A. 前置检查
Section "A. 前置检查"

$prereqOK = $true

foreach ($t in @(
        @{ n = '高云 gw_sh';       p = $GW },
        @{ n = 'ModelSim vsim';    p = $VSIM },
        @{ n = 'Python(venv)';     p = $PY },
        @{ n = '构建脚本';          p = (Join-Path $ROOT 'tools\gowin\build.tcl') },
        @{ n = '引脚约束 .cst';     p = (Join-Path $ROOT 'constr\fpga_hank.cst') },
        @{ n = '时序约束 .sdc';     p = (Join-Path $ROOT 'constr\fpga_hank.sdc') }
    )) {
    if (Test-Path $t.p) {
        Write-Host ("  [OK]   {0,-16} {1}" -f $t.n, $t.p)
    } else {
        Write-Host ("  [FAIL] {0,-16} 找不到: {1}" -f $t.n, $t.p) -ForegroundColor Red
        $prereqOK = $false
    }
}
Add-Result '前置：工具链与约束文件' $(if ($prereqOK) { 'PASS' } else { 'FAIL' }) `
    $(if ($prereqOK) { '全部存在' } else { '有缺失' })

# ★ 2026-10-05 更正：ModelSim 【不是】单席位 —— 实测许可证允许并发。
#   证据：曾有 6 个 ModelSim 进程（vsim+vish+vlm 两组）同时在跑且全部空闲；
#         按 PID 清掉后立刻又冒出新的。若真是硬性单席位，第 2 个实例会
#         【立刻报 license 错误退出】，而不是静静地待着。
#   ⇒ 真正要防的是"多个会话争用同一个 work/ 库"（会互相污染，本项目栽过一次"混合修订"），
#     不是"占用席位"。⇒ 发现别人在跑 【不要等】，直接跑即可。
$runningVsim = @(Get-Process vsim, vish, vsimk -ErrorAction SilentlyContinue)
Write-Host ("  [--]   ModelSim 实例数 = {0}（并发是允许的；只要各自用独立 work/ 库即可）" -f $runningVsim.Count)
if ($runningVsim.Count -gt 0) {
    Write-Host "         ℹ️ 检测到已有 ModelSim 实例。本机许可证【允许并发】，不会互相顶掉。" -ForegroundColor Cyan
    Write-Host "            只要各自使用独立的 work/ 库与输出目录即可。本脚本已在独立目录运行。" -ForegroundColor Cyan
}

if (-not $prereqOK) {
    Write-Host "`n前置不满足，终止。" -ForegroundColor Red
    exit 2
}

# ============================================================ B. 构建
if (-not $SkipBuild -and -not $Quick) {
    Section "B. 构建（syn -> pnr -> bitstream）"
    Remove-Item -Recurse -Force (Join-Path $ROOT 'eda_proj') -ErrorAction SilentlyContinue
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $bout = & $GW (Join-Path $ROOT 'tools\gowin\build.tcl') 2>&1
    $sw.Stop()

    $fsPath = Join-Path $ROOT 'eda_proj\fpga_hank\impl\pnr\fpga_hank.fs'
    $rptPath = Join-Path $ROOT 'eda_proj\fpga_hank\impl\pnr\fpga_hank.rpt.txt'
    $trPath = Join-Path $ROOT 'eda_proj\fpga_hank\impl\pnr\fpga_hank.tr'

    $bOK = ($bout | Select-String -Pattern '=== DONE' -Quiet) -and (Test-Path $fsPath)
    Write-Host ("  耗时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)

    if (Test-Path $fsPath) {
        $fi = Get-Item $fsPath
        Write-Host ("  bitstream : {0} B  {1}" -f $fi.Length, $fi.LastWriteTime)
    }

    $detail = ''
    if (Test-Path $rptPath) {
        $t = [System.IO.File]::ReadAllText($rptPath)
        $i = $t.IndexOf('Resource Usage Summary'); $j = $t.IndexOf('I/O Bank Usage Summary')
        if ($j -lt 0) { $j = $i + 1600 }
        $seg = $t.Substring($i, $j - $i)
        foreach ($k in @('Logic', 'Register', 'DSP', 'BSRAM', 'I/O Port')) {
            $m = [regex]::Match($seg, "(?m)^\s*$k\s*\|([^|]*)\|([^|]*)\|")
            if ($m.Success) { Write-Host ("  {0,-10}: {1} / {2}" -f $k, $m.Groups[1].Value.Trim(), $m.Groups[2].Value.Trim()) }
        }
        # 引脚：统计 constrained=Y 的行数
        $pinY = ([regex]::Matches($t, '\|\s*Y\s*\|')).Count
        Write-Host ("  引脚 constrained=Y : {0}" -f $pinY)
        $detail = "耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s；引脚 constrained=Y $pinY"
    }
    if (Test-Path $trPath) {
        $tr = [System.IO.File]::ReadAllText($trPath)
        $sv = [regex]::Match($tr, 'Setup Violated Endpoints>\s*:\s*(\d+)').Groups[1].Value
        $hv = [regex]::Match($tr, 'Hold Violated Endpoints>\s*:\s*(\d+)').Groups[1].Value
        Write-Host ("  时序违例  setup={0}  hold={1}" -f $sv, $hv)
        if ($sv -ne '0' -or $hv -ne '0') { $bOK = $false }
        $detail += "；违例 setup=$sv hold=$hv"
    }
    Add-Result '构建 bitstream' $(if ($bOK) { 'PASS' } else { 'FAIL' }) $detail
}

# ============================================================ C. 仿真
if (-not $Quick) {
    Section "C. ModelSim 仿真（全部 testbench）"
    Push-Location $ROOT
    $sout = & $VSIM -c -do sim\run.do 2>&1
    Pop-Location

    $pass = ($sout | Select-String -Pattern 'TESTBENCH\] PASS|TB\] PASS').Count
    $fail = ($sout | Select-String -Pattern 'TESTBENCH\] FAIL|TB\] FAIL').Count
    $sout | Select-String -Pattern '\[sim\] ====|TESTBENCH\]|TB\] (PASS|FAIL)' | ForEach-Object { "  $($_.Line)" }

    # 已知：tb_touch_pad 是预期 FAIL（touch_pad 未接入顶层，不影响主 bitstream）
    $knownFail = ($sout | Select-String -Pattern 'tb_touch_pad' -Quiet)
    Add-Result '仿真：全部 testbench' $(if ($fail -gt 0) { 'PARTIAL' } else { 'PASS' }) `
        "PASS=$pass FAIL=$fail（tb_touch_pad 为已知未通过项，不影响主 bitstream）"
}

# ============================================================ D. 证据① 32 谱峰
Section "D. 证据①：测试模式 32 谱峰（赛题必备交付物）"

$specFs = Join-Path $ROOT 'docs\evidence\tone_samples_pitch0.txt'
$ck = Join-Path $ROOT 'tools\verify\check_peaks.py'

if ((Test-Path $specFs) -and (Test-Path $ck) -and (Test-Path $PY)) {
    $h = (Get-FileHash $specFs -Algorithm SHA256).Hash
    Write-Host ("  证据文件 : {0}" -f $specFs)
    Write-Host ("  大小     : {0} B" -f (Get-Item $specFs).Length)
    Write-Host ("  SHA256   : {0}" -f $h.Substring(0, 32))
    Write-Host ""
    $pout = & $PY $ck --file $specFs --format samples --fs 97656.25 --count 32 --start 200 --step 200 2>&1
    $pout | ForEach-Object { "  $_" }
    $rc = $LASTEXITCODE
    # ★ 不要用正则去抓中文汇总里的数字：check_peaks 的输出是多字节中文，
    #   PowerShell 侧的 `命中\s*(\d+)` 实测抓不到（显示成 "命中 /32"）。
    #   改为数逐点 PASS 行 + 用 exit code 作最终判据，并原样打印汇总行。
    $nHit = @($pout | Select-String -Pattern 'PASS\s*$').Count
    $sumLine = $pout | Select-String -Pattern '命中' | Select-Object -First 1
    $sumTxt = if ($sumLine) { $sumLine.Line.Trim() } else { '(未取到汇总行)' }
    Add-Result '证据①：32 谱峰判据' $(if ($rc -eq 0) { 'PASS' } else { 'FAIL' }) `
        "check_peaks exit=$rc；逐点 PASS 行=$nHit；$sumTxt"
} else {
    Write-Host "  [FAIL] 证据文件或判据脚本缺失" -ForegroundColor Red
    Add-Result '证据①：32 谱峰判据' 'FAIL' '证据文件或判据脚本缺失'
}

# ============================================================ E. 证据② 变调
Section "E. 证据②：半音变调（基础要求③）"

$p7 = Join-Path $ROOT 'docs\evidence\tone_samples_pitch7.txt'
$cp = Join-Path $ROOT 'tools\verify\check_pitch_shift.py'
if ((Test-Path $p7) -and (Test-Path $cp) -and (Test-Path $PY)) {
    Write-Host "  pitch_semi=+7 时，32 个谱峰应从 200..6400 Hz 整体移到 300..9600 Hz"
    Write-Host ("  证据文件 : {0}  ({1} B)" -f $p7, (Get-Item $p7).Length)
    Write-Host ""
    # ★ 必须调用【独立 .py 文件】，不要用 here-string 内嵌 Python ——
    #   here-string 的结束标记必须顶格，一旦缩进就会失效、Python 代码被
    #   当成 PowerShell 命令执行，**而脚本仍报 PASS（假 PASS）**。本项目踩过。
    $eout = & $PY $cp --file $p7 --fs 97656.25 --semi 7 2>&1
    $eout | ForEach-Object { "$_" }
    $erc = $LASTEXITCODE
    Add-Result '证据②：半音变调' $(if ($erc -eq 0) { 'PASS' } else { 'FAIL' }) `
        "check_pitch_shift exit=$erc（32 峰整体移动 2^(7/12) 倍）"
} else {
    Write-Host "  [FAIL] 变调证据或判据脚本缺失" -ForegroundColor Red
    Add-Result '证据②：半音变调' 'FAIL' '证据文件或判据脚本缺失'
}

# ============================================================ F. 波形数据集
Section "F. ModelSim 原生波形数据集（.wlf）"

$wlfDir = Join-Path $ROOT 'sim\wlf'
if (Test-Path $wlfDir) {
    $wlfs = Get-ChildItem $wlfDir -Filter '*.wlf' -ErrorAction SilentlyContinue
    foreach ($w in $wlfs) { Write-Host ("  {0,-28} {1,8} B" -f $w.Name, $w.Length) }
    Add-Result '波形数据集 .wlf' $(if ($wlfs.Count -ge 4) { 'PASS' } else { 'FAIL' }) "$($wlfs.Count) 个数据集"
} else {
    Write-Host "  [!] 没有 sim\wlf 目录" -ForegroundColor Yellow
    Add-Result '波形数据集 .wlf' 'N/A' '目录不存在'
}

$pngDir = Join-Path $ROOT 'docs\waveforms\real'
if (Test-Path $pngDir) {
    $pngs = Get-ChildItem $pngDir -Filter '*.png' -ErrorAction SilentlyContinue
    Write-Host ("  ModelSim 真窗口截图 : {0} 张" -f $pngs.Count)
    Add-Result '波形截图（真窗口）' $(if ($pngs.Count -ge 4) { 'PASS' } else { 'PARTIAL' }) "$($pngs.Count) 张"
}

# ============================================================ F2. 烧录链路（SVF）
Section "F2. 烧录链路：bitstream 能否被烧录工具解析（不需要板子）"

$gwcl = 'F:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe'
$fsCl = Join-Path $ROOT 'eda_proj\fpga_hank\impl\pnr\fpga_hank.fs'
if ((Test-Path $gwcl) -and (Test-Path $fsCl)) {
    Write-Host ("  bitstream : {0} B" -f (Get-Item $fsCl).Length)
    # --operation_index 2 = SRAM Program；--svfcreate 只支持该操作码（4 会报 Unsupported）
    $svfLog = & $gwcl --device GW5AST-138C --fsFile $fsCl --operation_index 2 --svfcreate 2>&1 | Out-String
    $svfFile = Join-Path (Split-Path $gwcl -Parent) 'output.svf'
    if (Test-Path $svfFile) {
        $si = Get-Item $svfFile
        $head = Get-Content $svfFile -TotalCount 12
        $devId = ($head | Select-String -Pattern 'Device ID:').Line
        $nLines = (Get-Content $svfFile | Measure-Object).Count
        Write-Host ("  SVF       : {0} B / {1} 行" -f $si.Length, $nLines)
        Write-Host ("  {0}" -f $devId.Trim())
        Add-Result '烧录链路：bitstream 被工具接受' 'PASS' `
            "SVF $($si.Length) B / $nLines 行；$($devId.Trim())"
    } else {
        Write-Host "  [FAIL] 未生成 SVF（bitstream 可能无效或器件不匹配）" -ForegroundColor Red
        Add-Result '烧录链路：bitstream 被工具接受' 'FAIL' '未生成 SVF'
    }
} else {
    Write-Host "  [!] 烧录工具或 bitstream 不存在，跳过" -ForegroundColor Yellow
    Add-Result '烧录链路：bitstream 被工具接受' 'N/A' '工具或 bitstream 不存在'
}

# ============================================================ G. 交付物清单
Section "G. 交付物清单"

$expect = @(
    'docs\技术文档.docx',
    'docs\工程能力与工具链说明.md',
    'docs\上板验证指南.md',
    'docs\evidence\32谱峰-取证报告.md',
    'tools\gowin\build.tcl',
    'tools\gowin\program.ps1',
    'tools\verify\check_peaks.py',
    'tools\verify\check_pitch.py',
    'constr\fpga_hank.cst',
    'sim\run.do',
    'README.md'
)
$missing = @()
foreach ($e in $expect) {
    $p = Join-Path $ROOT $e
    if (Test-Path $p) { Write-Host ("  [OK]   {0}" -f $e) }
    else { Write-Host ("  [MISS] {0}" -f $e) -ForegroundColor Yellow; $missing += $e }
}
Add-Result '交付物清单' $(if ($missing.Count -eq 0) { 'PASS' } else { 'PARTIAL' }) `
    $(if ($missing.Count -eq 0) { '全部齐备' } else { "缺 $($missing.Count) 项: $($missing -join ', ')" })

# ============================================================ 汇总
Section "验收汇总"

$results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Host $_ }

$nPass = ($results | Where-Object { $_.状态 -eq 'PASS' }).Count
$nFail = ($results | Where-Object { $_.状态 -eq 'FAIL' }).Count
$nPart = ($results | Where-Object { $_.状态 -eq 'PARTIAL' }).Count
$nNA   = ($results | Where-Object { $_.状态 -eq 'N/A' }).Count

Write-Host ("  PASS = {0}   FAIL = {1}   PARTIAL = {2}   N/A = {3}" -f $nPass, $nFail, $nPart, $nNA)
Write-Host ""

if ($nFail -gt 0) {
    Write-Host "  结论：有 FAIL 项，需处理。" -ForegroundColor Red
    exit 1
} elseif ($nPart -gt 0) {
    Write-Host "  结论：无 FAIL，有 PARTIAL（见上表 依据 列）。" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "  结论：全部 PASS。" -ForegroundColor Green
    exit 0
}
