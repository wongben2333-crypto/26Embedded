<#
.SYNOPSIS
    fpga_hank 烧录脚本 —— 用高云官方命令行把 bitstream 下载到 Tang Mega 138K

.DESCRIPTION
    本脚本把"烧录"这一环从手工点 GUI 变成可复现的命令行。
    所有参数与操作码均来自官方 programmer_cli 的 --help 实测输出（V1.9.12.04 build 2743）。

    ★ 为什么默认用 SRAM 下载（-Mode sram）而不是写 flash：
      SRAM 下载是**易失**的 —— 掉电即丢，**不改动板上的外部 flash**。
      第一次上板、或每次改了 RTL 反复试的时候，用它最安全：
      即使 bitstream 有问题，也不会把板子刷成"上电就跑坏程序"的状态。
      确认一切正常后，再用 -Mode flash 写进 flash 实现"上电自动运行"。

.PARAMETER Mode
    sram  = 下载到 SRAM（易失、安全、默认）
    flash = 写入外部 flash（永久、上电自动运行）
    scan   = 只扫描，看缆线和器件是否被识别
    verify = 【不需要板子】让烧录工具解析 bitstream 并生成标准 JTAG 向量文件（SVF），
             用它证明 bitstream 本身对烧录工具是有效的

.PARAMETER Fs
    bitstream 路径。默认用构建产物 eda_proj\fpga_hank\impl\pnr\fpga_hank.fs

.EXAMPLE
    # 1) 先确认缆线和器件能被识别（板子要通电、USB 线要插对）
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode scan

    # 2) 下载到 SRAM（推荐的第一步）
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode sram

    # 3) 确认无误后写入 flash
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode flash

.NOTES
    ★ 实测结论（2026-10-03，无板状态下得出）：
      · programmer_cli.exe 存在于 F:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\
      · 其器件列表**包含 GW5AST-138C**（本板器件）
      · 无板时 --scan 输出：
          Target Cable: Gowin USB Cable(FT2CH)/0/None/null@2.5MHz
          Error: No Gowin devices found!, Cable at location: 0 has no valid JTAG target.
        ⇒ 说明**工具链本身工作正常**，报错是因为没有板/没通电。
      ⚠️ 因此本脚本的"能烧进去"这一环**仍需上板才能最终确认**。
#>
[CmdletBinding()]
param(
    # ★ 正确用法：.\program.ps1 -Mode sram|flash|scan|verify
    #   ⚠️ 本脚本【没有】-Op 参数；--operation_index 2/9 是脚本【内部】传给
    #      programmer_cli.exe 的，不是本脚本的参数。
    #      （2026-10-05：这个混淆差点被写进交付操作卡 —— 派活方的措辞也有责任）
    [ValidateSet('sram', 'flash', 'scan', 'verify')]
    [string]$Mode = 'sram',

    [string]$Fs = '',

    [string]$Device = 'GW5AST-138C',

    [string]$Frequency = '2.5MHz'
)

$ErrorActionPreference = 'Continue'

$ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # fpga_hank\
$CLI  = 'F:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe'

if (-not (Test-Path $CLI)) {
    Write-Host "[program] ❌ 找不到烧录工具: $CLI" -ForegroundColor Red
    Write-Host "          请确认高云 EDA V1.9.12.04 装在 F:\Gowin\Gowin_V1.9.12.04_x64" -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- 烧录凭证日志
# ★ 2026-10-05 新增（Lead 批准）：每次烧录/校验都追加一行凭证到 docs\flash-log.txt。
#   为什么：User Code 曾是逐次随机量、位流 SHA256 又不能当修订标识
#   （同源码两次构建哈希就不同）⇒ 事后无法证明"这块板当时烧的是哪一版"。
#   ⇒ 这一行把 时间 + 模式 + 操作码 + 文件名 + 大小 + SHA256 + User Code 固定下来。
#
#   ★ 操作码映射集中在这里，不要再散落到别处（避免再出现"把内部操作码当脚本参数"的混淆）：
#       sram -> 2   flash -> 9   verify -> 2 (--svfcreate 只支持 2)
$OP_MAP = @{ 'sram' = 2; 'flash' = 9; 'verify' = 2; 'scan' = 0 }

function Write-FlashLog {
    param(
        [Parameter(Mandatory = $true)][string]$FsPath,
        [string]$ModeName = '',
        [string]$ToolOutput = ''
    )
    try {
        $docsDir = Join-Path $ROOT 'docs'
        if (-not (Test-Path $docsDir)) { New-Item -ItemType Directory -Force -Path $docsDir | Out-Null }
        $logFile = Join-Path $docsDir 'flash-log.txt'

        # User Code 三个来源，按可信度排序：
        #   1) build.tcl 归档时写的 <位流>.usercode 边车文件（最可靠）
        #   2) 烧录工具输出里的 "User Code is: 0x..."
        #   3) '?'
        $uc = '?'
        $side = "$FsPath.usercode"
        if (Test-Path -LiteralPath $side) {
            $uc = (Get-Content -LiteralPath $side -Raw).Trim()
        } elseif ($ToolOutput -match 'User\s*Code[^0-9A-Fa-fx]*(0x[0-9A-Fa-f]+)') {
            $uc = $Matches[1]
        }

        $fi   = Get-Item -LiteralPath $FsPath
        $hash = (Get-FileHash -LiteralPath $FsPath -Algorithm SHA256).Hash
        $op   = if ($OP_MAP.ContainsKey($ModeName)) { $OP_MAP[$ModeName] } else { '?' }
        $line = "{0} | mode={1} op={2} | {3} | {4} B | sha256={5} | user_code={6}" -f `
                (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ModeName, $op, $fi.Name, $fi.Length, $hash, $uc
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
        Write-Host "[program] 📝 凭证已追加 -> docs\flash-log.txt" -ForegroundColor Green
        Write-Host "          $line"
    } catch {
        Write-Host "[program] ⚠️ 写凭证日志失败（不影响烧录结果）：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ([string]::IsNullOrWhiteSpace($Fs)) {
    $Fs = Join-Path $ROOT 'eda_proj\fpga_hank\impl\pnr\fpga_hank.fs'
}

Write-Host "=============================================================="
Write-Host " fpga_hank 烧录  |  模式=$Mode  器件=$Device"
Write-Host "=============================================================="

# ---------------------------------------------------------------- 1) 列缆线
Write-Host "`n[1/3] 扫描 Gowin USB 下载缆线 ..."
& $CLI --scan-cables 2>&1 | ForEach-Object { "      $_" }

# ---------------------------------------------------------------- 2) 扫器件
Write-Host "`n[2/3] 扫描 JTAG 链上的 Gowin 器件 ..."
$scanOut = & $CLI --scan 2>&1 | Out-String
$scanOut.Trim() -split "`n" | ForEach-Object { "      $_" }

# ---------------------------------------------------------------- verify
# ★ 不需要板子：让烧录工具解析 bitstream 并产出标准 JTAG 向量文件（SVF）。
#   能证明 bitstream 对烧录工具是有效的，并提取器件 ID。
if ($Mode -eq 'verify') {
    Write-Host "`n[verify] 解析 bitstream 并生成 SVF（不需要板子）..."
    if (-not (Test-Path $Fs)) {
        Write-Host "[verify] ❌ 找不到 bitstream: $Fs" -ForegroundColor Red
        Write-Host "         请先构建：gw_sh.exe `"$ROOT\tools\gowin\build.tcl`"" -ForegroundColor Yellow
        exit 1
    }
    $fi = Get-Item $Fs
    $hash = (Get-FileHash $Fs -Algorithm SHA256).Hash
    Write-Host "         bitstream : $($fi.FullName)"
    Write-Host "         大小      : $($fi.Length) B"
    Write-Host "         SHA256    : $($hash.Substring(0,32))..."
    Write-Host ""

    # 操作码 2 = SRAM Program；--svfcreate 时只有该操作码被支持（4 会报 Unsupported）
    $svfOut = Join-Path $env:TEMP ("gsvf_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $svfOut | Out-Null
    Push-Location $svfOut
    $vo = & $CLI --device $Device --fsFile $Fs --operation_index 2 --svfcreate 2>&1 | Out-String
    Pop-Location
    $vo.Trim() -split "`n" | ForEach-Object { "         $_" }

    # 工具固定输出到 Programmer\bin\output.svf
    $svf = Join-Path (Split-Path $CLI -Parent) 'output.svf'
    if (Test-Path $svf) {
        $si = Get-Item $svf
        $head = Get-Content $svf -TotalCount 12
        $devId = ($head | Select-String -Pattern 'Device ID:').Line
        $fsRef = ($head | Select-String -Pattern 'FS File:').Line
        $lines = (Get-Content $svf | Measure-Object).Count
        Write-Host ""
        Write-Host "         ✅ SVF 已生成" -ForegroundColor Green
        Write-Host "            路径    : $($si.FullName)"
        Write-Host "            大小    : $($si.Length) B"
        Write-Host "            行数    : $lines"
        Write-Host "            $($devId.Trim())"
        Write-Host "            （文件头里记录的来源）$($fsRef.Trim())"
        Write-Host ""
        Write-Host "         ⇒ 结论：烧录工具【成功解析】了本 bitstream 并提取出器件 ID，" -ForegroundColor Green
        Write-Host "            说明 bitstream 本身有效、器件匹配。剩下的只有'物理 JTAG 连接'一步。" -ForegroundColor Green
        Write-FlashLog -FsPath $Fs -ModeName $Mode -ToolOutput $vo
        exit 0
    } else {
        Write-Host "[verify] ❌ 未生成 SVF —— bitstream 可能无效或器件不匹配" -ForegroundColor Red
        exit 1
    }
}

if ($Mode -eq 'scan') {
    Write-Host "`n[program] 只做了扫描（-Mode scan）。" -ForegroundColor Cyan
    if ($scanOut -match 'No Gowin devices found') {
        Write-Host "[program] ⚠️ 没有检测到器件。上板前请检查：" -ForegroundColor Yellow
        Write-Host "          1) 板子是否已通电（长按 PWR 键约 2 秒开机）"
        Write-Host "          2) USB 线是否插在【下载口】(DEBUG-USB)，而不是只做供电的那个口"
        Write-Host "          3) 是否装了 Gowin USB Cable 驱动"
        Write-Host "             （F:\Gowin\...\Programmer\driver\GowinUSBCableDriverV5_for_win7+.exe）"
        Write-Host "          4) 单口 USB 供电会掉电重启 —— 建议 USB3.0 + DEBUG-USB 双供电，或 12V DC"
        exit 2
    }
    exit 0
}

# ---------------------------------------------------------------- 3) 烧录
if (-not (Test-Path $Fs)) {
    Write-Host "`n[program] ❌ 找不到 bitstream: $Fs" -ForegroundColor Red
    Write-Host "          请先构建：gw_sh.exe `"$ROOT\tools\gowin\build.tcl`"" -ForegroundColor Yellow
    exit 1
}

$fi   = Get-Item $Fs
$hash = (Get-FileHash $Fs -Algorithm SHA256).Hash
Write-Host "`n[3/3] bitstream 指纹（取证纪律：烧录前先记录）"
Write-Host "      路径  : $($fi.FullName)"
Write-Host "      大小  : $($fi.Length) B"
Write-Host "      mtime : $($fi.LastWriteTime)"
Write-Host "      SHA256: $hash"

# 操作码来自官方 --help 实测：
#   1: Reprogram           2: SRAM Program       4: SRAM Program and Verify
#   8: exFlash Erase,Program   9: exFlash Erase,Program,Verify
if ($Mode -eq 'sram') {
    # ★ 2026-10-05 真板实测：操作码 4（SRAM Program **and Verify**）在本板
    #   （Tang Mega 138K + 板载 FT2232H 缆线）上**必然报 "Error: Verify failed of at 0"**，
    #   但位流其实**已经正确写入** —— 证据：User Code 随位流变化而变化
    #   （测试模式位流 → 0x0000A86D；演奏模式位流 → 0x00005093）。
    #   ⇒ 这套硬件的**回读校验通路不可用**，不是烧录失败。
    #   Sipeed 官方文档 `system_report/fpga_programmer.md` 用的也正是
    #   **不含 Verify 的操作码 2**（"SRAM Program" → Result: OK）。
    #   故默认改用操作码 2，与官方一致；耗时也从 ~106 s 降到 ~21 s。
    $op = 2
    Write-Host "`n      操作  : SRAM Program（易失，掉电即丢，不动 flash）"
    Write-Host "              注：不用带 Verify 的操作码 4 —— 本板回读校验通路不可用，"
    Write-Host "                  会误报 Verify failed（位流其实已写入，已实测证实）"
} else {
    $op = 9
    Write-Host "`n      操作  : exFlash Erase,Program,Verify（写入外部 flash，上电自动运行）"
    Write-Host "      ⚠️ 这会改写板上的 flash。确定要写吗？" -ForegroundColor Yellow
}

$script:progOut = @()
Write-Host "`n[program] 开始烧录 ..."
& $CLI --device $Device --fsFile $Fs --operation_index $op --frequency $Frequency 2>&1 |
    ForEach-Object { "      $_"; $script:progOut += "$_" }
$rc = $LASTEXITCODE

# ★ 2026-10-05 实测踩到的坑：programmer_cli 在【回读校验失败】时
#   依然返回【退出码 0】，只在输出里打印 "Error: Verify failed of at ..."。
#   只看退出码会把"校验失败"误判成"烧录成功" —— 又一个"看起来成功"。
#   所以必须再检查输出里有没有 Error / Verify failed。
#   实测发生场景：单根 USB 供电（供电不足）时最容易出现。
if ($rc -eq 0) {
    $joined = ($script:progOut -join "`n")
    if ($joined -match 'Verify failed' -or $joined -match '(?m)^\s*Error:') {
        $rc = 97
        Write-Host ""
        Write-Host "      ⚠️ 工具返回退出码 0，但输出里有 Error / Verify failed ⇒ 判为【失败】" -ForegroundColor Red
        Write-Host "         最常见原因：供电不足（单根 USB 供电会让板子不稳）" -ForegroundColor Yellow
        Write-Host "         对策：DEBUG-USB + USB3.0 双线，或 12V DC 适配器" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($rc -eq 0) {
    Write-Host "[program] ✅ 完成（退出码 0）。" -ForegroundColor Green
    if ($Mode -eq 'sram') {
        Write-Host "          SRAM 下载已生效，板子现在应该在跑了。" -ForegroundColor Green
        Write-Host "          注意：掉电后会丢，重新上电需要再烧一次。" -ForegroundColor Yellow
    } else {
        Write-Host "          已写入 flash，之后上电会自动运行。" -ForegroundColor Green
    }
} else {
    Write-Host "[program] ❌ 失败（退出码 $rc）。常见原因：" -ForegroundColor Red
    Write-Host "          · 没检测到器件 —— 见上面 [2/3] 的扫描结果与排查清单"
    Write-Host "          · 缆线被其它程序（Gowin Programmer GUI / 另一个脚本）占用"
    Write-Host "            ⚠️ 同一时刻只允许一个程序访问下载缆线"
}
Write-FlashLog -FsPath $Fs -ModeName $Mode -ToolOutput ''
exit $rc
