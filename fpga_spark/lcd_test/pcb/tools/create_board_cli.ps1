# =============================================================================
#  create_board_cli.ps1 -- drive the REAL EasyEDA Pro editor through its official
#                          command-line client to build the 6-key touch piano PCB.
#
#  STATUS: NOT YET RUN. This machine's client (3.2.149) has only a stub cli.js and
#  no doctor/bridge, so the official CLI (v4.1.60+) is not available yet.
#  Be explicit about that: nothing in this file has been executed for real.
#
#  Design decisions (all from the official AI-oriented doc, cli-for-ai.md):
#    * NEVER invent API method names.  Step 2 runs `doc api` to READ them back.
#      We only know the CLASS names (DMT_Pcb, PCBPrimitivePad, BoardOutline...).
#    * `invoke` MUST carry --ext-uuid eda, else many APIs fail (hard rule #1).
#    * Forward slashes in paths (hard rule #2).
#    * Every step: check the top-level `ok` field AND verify on-disk artifacts,
#      then persist the raw JSON. (hard rules #7/#8 -- our own "fake success" lesson)
#    * Pin coordinates are never computed by hand: read them back with
#      getAllPinsByPrimitiveId() as the doc demands (hard rule #4).
#
#  Usage:
#     powershell -NoProfile -ExecutionPolicy Bypass -File create_board_cli.ps1 -Doctor
#     powershell ... -File create_board_cli.ps1 -Discover
#     powershell ... -File create_board_cli.ps1 -Build      (only after Discover)
# =============================================================================
param(
    [switch] $Doctor,      # just probe the endpoint / print version
    [switch] $Discover,    # dump the extension API reference (do this FIRST)
    [switch] $Build,       # actually draw the board (requires confirmed API names)
    [string] $ProjectPath = "",   # e.g. C:/Users/Danny/Documents/EasyEDA-Pro/projects/TouchPiano6/TouchPiano6.eprj3
    [string] $Cli = "easyeda-pro"
)

$ErrorActionPreference = "Stop"
$Ev = Join-Path $PSScriptRoot "..\..\..\_research\pcb\_cli_evidence"
New-Item -ItemType Directory -Force -Path $Ev | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

function Invoke-Cli {
    param([string[]] $Args, [string] $Tag)
    Write-Host ("[cli] easyeda-pro " + ($Args -join " "))
    $raw = & $Cli @Args 2>&1 | Out-String
    $file = Join-Path $Ev ("{0}_{1}.json" -f $Stamp, $Tag)
    [System.IO.File]::WriteAllText($file, $raw, (New-Object System.Text.UTF8Encoding($false)))
    # 硬约束 #7：只看 `ok`，不靠退出码（我们吃过"退出码 0 但内容失败"的亏）
    try {
        $j = $raw | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains "ok") {
            Write-Host ("[cli] ok = {0}   (evidence: {1})" -f $j.ok, (Split-Path $file -Leaf))
            if (-not $j.ok) { throw "command reported ok=false" }
        } else {
            Write-Host "[cli] WARNING: no top-level 'ok' field - inspect the evidence file"
        }
    } catch {
        Write-Host "[cli] WARNING: response is not JSON (see evidence file): $($_.Exception.Message)"
    }
    return $raw
}

# ---------------------------------------------------------------- 0. presence --
Write-Host "=== 0. 检查 CLI 是否存在 ==="
$cmd = Get-Command $Cli -ErrorAction SilentlyContinue
if (-not $cmd) {
    Write-Host "[cli] ✗ 找不到 '$Cli'。"
    Write-Host "[cli]   本机当前版本（3.2.149）没有官方 CLI —— 需要用户先升级到 v4.1.60+。"
    Write-Host "[cli]   见 fpga_hank/pcb/升级指引-立创EDA升级到CLI版.md"
    exit 2
}
Write-Host "[cli] 找到: $($cmd.Source)"

# ------------------------------------------------------------------ 1. doctor --
Invoke-Cli -Args @("doctor") -Tag "doctor" | Out-Null
if ($Doctor) { exit 0 }

# ------------------------------------------------------- 2. API discovery -----
# ★ 这一步不是可选的。我们只知道类名，不知道方法名 —— 官方文档也只给类名。
#   猜方法名会浪费时间且可能悄悄画错；必须先读回来。
if ($Discover) {
    Write-Host "=== 2. 读取扩展 API 参考（真实方法名）==="
    Invoke-Cli -Args @("doc", "api") -Tag "doc_api_all" | Out-Null
    foreach ($kw in @("BoardOutline", "PcbPrimitivePad", "Track", "String",
                      "PcbPrimitivePour", "Via", "PrimitiveComponent")) {
        Invoke-Cli -Args @("doc", "api", $kw) -Tag ("doc_api_" + $kw) | Out-Null
    }
    Write-Host ""
    Write-Host "⇒ 请打开 $Ev 下的 doc_api_*.json，把真实方法名抄进下面的 JS 片段。"
    Write-Host "  ⛔ 在这一步完成并核对之前，不要跑 -Build。"
    exit 0
}

if (-not $Build) {
    Write-Host "[cli] 什么都没做。用 -Doctor / -Discover / -Build 指定动作。"
    exit 0
}

# ------------------------------------------------------------------- 3. open ---
if (-not $ProjectPath) {
    Write-Host "[cli] -Build 需要 -ProjectPath（指向 .eprj3 工程）。"
    exit 2
}
$open = Invoke-Cli -Args @("open", "--path", $ProjectPath) -Tag "open"
$session = ($open | ConvertFrom-Json).session
if (-not $session) { Write-Host "[cli] ✗ open 没返回 session"; exit 3 }
Write-Host "[cli] session = $session"

# ---------------------------------------------------------------- 4. invoke ----
# ⚠️ 下面的 JS 是【骨架】：方法名占位符 <TODO-...> 必须先用 -Discover 换成真名。
#    ⛔ 不允许猜。硬约束 #4 也提醒：引脚坐标要用 getAllPinsByPrimitiveId() 读回，别自己算。
function Invoke-Js {
    param([string] $Code, [string] $Tag)
    Invoke-Cli -Args @("invoke", "--session", $session, "--ext-uuid", "eda",
                       "--code", $Code, "--timeout", "300000") -Tag $Tag | Out-Null
    # 硬约束 #6：改动后等 5~10 秒再查状态
    Start-Sleep -Seconds 6
}

Write-Host "=== 4. 画板（分步，每步都验证）==="
Write-Host "[cli] ⚠️ 本段方法名是占位符，必须先用 -Discover 读回真实名再跑。"

# 4.1 板框 164.5 x 172 mm，圆角 3 mm
# Invoke-Js -Tag "outline" -Code @'
# const pcb = eda.<TODO-DMT_Pcb 打开当前 PCB>;
# pcb.<TODO-设置板框>([{x:0,y:0},{x:164.5,y:0},{x:164.5,y:172},{x:0,y:172}], 3);
# '

# 4.2 6 个触摸焊盘 19 x 44 mm（白键前段 y=8..52）
# Invoke-Js -Tag "pads" -Code @'
# const pcb = eda.<TODO>;
# const X = [11.75,35.25,58.75,82.25,105.75,129.25];   // 6 个白键中心
# for (let i=0;i<X.length;i++){
#   pcb.<TODO-建焊盘>({ layer:"TOP", shape:"RECT", w:19, h:44,
#                       x:X[i], y:30, net:"PAD"+(i+1) });
# }
# '

# 4.3 排针 J1：2x6 2.54mm，通孔（孔 1.02 / 盘 1.60 —— 真值见 LCEDA-FORMAT.md §4）
# Invoke-Js -Tag "header" -Code @'
# const pcb = eda.<TODO>;
# const pins = [[11,12],[9,10],[7,8],[5,6],[3,4],[1,2]];
# for (let r=0;r<6;r++){
#   for (let c=0;c<2;c++){
#     pcb.<TODO-建通孔焊盘>({ layer:"MULTI", hole:{shape:"ROUND", d:1.02},
#                            shape:"RECT", w:1.60, h:1.60,
#                            x:82.25+(c-0.5)*2.54, y:161+(r-2.5)*2.54,
#                            number:String(pins[r][c]) });
#   }
# }
# '

# 4.4 走线（6 路信号 + 上拉 + 测试点；按我们的坐标，但落点要用读回值校验）
# 4.5 丝印：7 个音名 + 6 组 `pinN/球号` + 标题行 + 黑键实心
# 4.6 跑 DRC（等 5~10s 再读）
# 4.7 导 Gerber / BOM / 截图

# ----------------------------------------------------------------- 5. close ----
Invoke-Cli -Args @("session", "close", "--destroy", "--session", $session) -Tag "close" | Out-Null
Write-Host "[cli] 完成。全部原始 JSON 在 $Ev"
