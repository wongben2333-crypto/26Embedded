# =============================================================================
#  build_smoke.ps1 —— 一键构建 S0..S6 全部七级冒烟测试
#
#  用法（本机执行策略是 AllSigned，必须显式 -ExecutionPolicy Bypass）：
#     powershell -NoProfile -ExecutionPolicy Bypass -File `
#       "C:\Users\Danny\Desktop\FPGA competition\fpga_hank\tools\gowin\build_smoke.ps1"
#
#  只构建某一级：
#     powershell -NoProfile -ExecutionPolicy Bypass -File <本文件> -Stages 2
#     或  -Stages 0,1,2
#
#  产物：竞赛根\_smoke-test\eda_s<N>\smoke_top_s<N>\impl\pnr\smoke_top_s<N>.fs  ← 烧录用这个
#        （create_project -dir X -name N 的真实工程目录是 X\N，多一层，别找错）
#        每级的完整控制台输出同时存到 _smoke-test\logs\build_s<N>.log
# =============================================================================
param(
    [int[]] $Stages = @(0,1,2,3,4,5,6)
)

$ErrorActionPreference = "Continue"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # fpga_hank\tools\gowin
$Root     = (Resolve-Path (Join-Path $ToolsDir "..\..")).Path     # fpga_hank
$OutRoot  = (Resolve-Path (Join-Path $Root "..")).Path            # 竞赛根
$LogDir   = Join-Path $OutRoot "_smoke-test\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$GwSh = "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
$Tcl  = Join-Path $ToolsDir "build_smoke.tcl"

if (-not (Test-Path $GwSh)) { Write-Error "找不到 gw_sh.exe：$GwSh"; exit 2 }
if (-not (Test-Path $Tcl))  { Write-Error "找不到 build_smoke.tcl：$Tcl"; exit 2 }

$results = @()
foreach ($s in $Stages) {
    $log = Join-Path $LogDir "build_s$s.log"
    Write-Host "==================== SMOKE S$s ====================" -ForegroundColor Cyan
    $env:SMOKE_STAGE = "$s"
    # ⚠️ gw_sh 会间歇性往 stderr 打 OpenGL 错误（"wglCreateContext failed"）。
    #    那是纯噪声（本机没有可用的 GL 上下文），但 PowerShell 会把它变成
    #    NativeCommandError，导致【脚本结束时退出码变成 1】—— 看起来像构建失败。
    #    真实判据只有一条：.fs 是否产出。别用退出码判断。
    $ErrorActionPreference = "Continue"
    & $GwSh $Tcl 2>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    $fs   = Join-Path $OutRoot "_smoke-test\eda_s$s\smoke_top_s$s\impl\pnr\smoke_top_s$s.fs"
    $ok   = (Test-Path $fs) -and ((Get-Item $fs).Length -gt 0)
    $results += [pscustomobject]@{
        Stage = $s; ExitCode = $code; Bitstream = $ok
        FsBytes = if ($ok) { (Get-Item $fs).Length } else { 0 }
        Log = $log
    }
}
Remove-Item Env:\SMOKE_STAGE -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================== 汇总 ====================" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
$bad = ($results | Where-Object { -not $_.Bitstream }).Count
if ($bad -eq 0) {
    Write-Host "全部 $($results.Count) 级都产出了 bitstream" -ForegroundColor Green
    exit 0            # 明确以 0 退出，避免被 gw_sh 的 stderr 噪声带成 1
} else {
    Write-Host "$bad 级没有产出 bitstream，见上面的日志" -ForegroundColor Red
    exit 1
}
