# uninstall.ps1 — 撤掉 Super-agent 加上去的东西，profile 本身和看板数据保留
#
# 用法：powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 [-DryRun]
#
# 做什么：
#   1. 把各 profile 的 SOUL.md 恢复成 backup\ 里最早的那份（没有备份的只删不恢复）
#   2. 删除技能目录 skills\superagent
#   3. 删除两处 sa_watchdog.py 和它的状态文件
#   4. 删除名为 sa-watchdog 的 cron
#   5. 把 kanban.auto_decompose 恢复为 true（Hermes 默认），其余 kanban 键不动
# 不做什么：不删 profile、不删看板卡片、不改 .env、不恢复 Router 的工具（打印恢复命令）。

param([string]$Config = "", [switch]$DryRun)
$ErrorActionPreference = "Stop"
$Kit = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Config) {
    $Config = Join-Path $Kit "superagent.config.json"
    if (-not (Test-Path $Config)) { $Config = Join-Path $Kit "superagent.config.example.json" }
}
$cfg = Get-Content -Raw -Encoding UTF8 $Config | ConvertFrom-Json
$router = $cfg.router
$allRoles = @($router) + @($cfg.workers)

$cmd = Get-Command hermes -ErrorAction SilentlyContinue
$Hermes = if ($cmd) { $cmd.Source } else { Join-Path ($cfg.hermes_home) "bin\hermes.exe" }
$Home_ = $cfg.hermes_home
if (-not $Home_) { $Home_ = $env:HERMES_HOME }
if (-not $Home_) { $Home_ = Join-Path $env:LOCALAPPDATA "hermes" }
$env:HERMES_HOME = $Home_
Write-Host "HERMES_HOME = $Home_"
if ($DryRun) { Write-Host "DRY RUN" -ForegroundColor Cyan }

function Run([string[]]$ArgList) {
    Write-Host ("  > hermes " + ($ArgList -join " ")) -ForegroundColor DarkGray
    if (-not $DryRun) { & $Hermes @ArgList 2>&1 | Out-Null }
}
function Remove-IfExists([string]$Path) {
    if (Test-Path $Path) {
        Write-Host "  删除 $Path"
        if (-not $DryRun) { Remove-Item -Recurse -Force $Path }
    }
}

Write-Host "[1/5] 恢复 SOUL.md"
$backups = Get-ChildItem (Join-Path $Kit "backup") -Directory -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($role in $allRoles) {
    $name = $role.profile
    $dst = Join-Path $Home_ "profiles\$name\SOUL.md"
    $src = $null
    foreach ($b in $backups) { $cand = Join-Path $b.FullName "$name.SOUL.md"; if (Test-Path $cand) { $src = $cand; break } }
    if ($src) {
        Write-Host "  $name <- $src"
        if (-not $DryRun) { Copy-Item $src $dst -Force }
    } elseif (Test-Path $dst) {
        Write-Host "  $name 没有备份，删除当前 SOUL.md" -ForegroundColor Yellow
        if (-not $DryRun) { Remove-Item $dst -Force }
    }
}

Write-Host "[2/5] 技能"
Remove-IfExists (Join-Path $Home_ "skills\superagent")

Write-Host "[3/5] 看门狗脚本"
foreach ($dir in @((Join-Path $Home_ "scripts"), (Join-Path $Home_ "profiles\$($router.profile)\scripts"))) {
    Remove-IfExists (Join-Path $dir "sa_watchdog.py")
    Remove-IfExists (Join-Path $dir ".sa_watchdog_state.json")
}

Write-Host "[4/5] cron"
if (-not $DryRun) {
    $list = & $Hermes -p $router.profile cron list 2>&1 | Out-String
    foreach ($m in [regex]::Matches($list, "([0-9a-f]{12})\s+\[\w+\]\s*\r?\n\s*Name:\s+sa-watchdog")) {
        Run @("-p", $router.profile, "cron", "remove", $m.Groups[1].Value)
    }
} else { Write-Host "  （会删除名为 sa-watchdog 的 cron）" }

Write-Host "[5/5] kanban.auto_decompose 恢复默认 true"
Run @("config", "set", "kanban.auto_decompose", "true")
Run @("-p", $router.profile, "config", "set", "kanban.auto_decompose", "true")

Write-Host ""
Write-Host "完成。未自动恢复的：Router 的工具收窄与模型。若需恢复：" -ForegroundColor Green
foreach ($plat in $router.platforms) {
    Write-Host "  hermes -p $($router.profile) tools enable $($router.drop_toolsets -join ' ') --platform $plat"
}
Write-Host "然后 hermes gateway restart。"
