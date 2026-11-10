# install.ps1 — 在一台已装好 Hermes 的 Windows 电脑上部署 Super-agent（幂等，可反复运行）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\install.ps1              # 按 superagent.config.json 部署
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun      # 只打印将要执行的命令，不改任何东西
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipCron    # 不建看门狗 cron
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Config 另一个.json
#
# 做什么（每一步都幂等）：
#   1. 定位 hermes 和 HERMES_HOME
#   2. 缺失的 profile 用 --clone 创建（继承默认 profile 的模型和密钥），并写入描述
#   3. 安装四个角色的 SOUL.md（旧文件备份到 backup\<时间戳>\）、技能、看门狗脚本
#   4. 写 kanban 配置：orchestrator_profile / default_assignee / auto_decompose / review_dispatch
#   5. 收窄 Router 的工具，按配置设置各角色模型
#   6. 如配置了投递目标，创建看门狗 cron（已存在则跳过）
#   7. 检查 Router profile 的飞书白名单，缺了就打印该怎么填（脚本不改 .env）
# 不做什么：不改 .env、不启用任何插件、不重启网关（结尾会提示）。
# 回滚：uninstall.ps1

param(
    [string]$Config = "",
    [switch]$DryRun,
    [switch]$SkipCron
)

$ErrorActionPreference = "Stop"
$Kit = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- 读配置 ----------
if (-not $Config) {
    $Config = Join-Path $Kit "superagent.config.json"
    if (-not (Test-Path $Config)) {
        Write-Host "没有找到 superagent.config.json，改用 superagent.config.example.json（占位符配置，看门狗 cron 和飞书检查会跳过）。" -ForegroundColor Yellow
        $Config = Join-Path $Kit "superagent.config.example.json"
    }
}
$cfg = Get-Content -Raw -Encoding UTF8 $Config | ConvertFrom-Json
$router = $cfg.router
$workers = @($cfg.workers)
$allRoles = @($router) + $workers

# ---------- 定位 hermes / HERMES_HOME ----------
function Find-Hermes {
    $cmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($h in @($env:HERMES_HOME, (Join-Path $env:LOCALAPPDATA "hermes"), (Join-Path $HOME ".hermes"))) {
        if ($h -and (Test-Path (Join-Path $h "bin\hermes.exe"))) { return (Join-Path $h "bin\hermes.exe") }
    }
    throw "找不到 hermes 命令。请先安装 Hermes：iex (irm https://hermes-agent.nousresearch.com/install.ps1)"
}
$Hermes = Find-Hermes

$Home_ = $cfg.hermes_home
if (-not $Home_) { $Home_ = $env:HERMES_HOME }
if (-not $Home_) {
    foreach ($h in @((Join-Path $env:LOCALAPPDATA "hermes"), (Join-Path $HOME ".hermes"))) {
        if (Test-Path (Join-Path $h "config.yaml")) { $Home_ = $h; break }
    }
}
if (-not $Home_ -or -not (Test-Path $Home_)) { throw "无法确定 HERMES_HOME，请在 superagent.config.json 的 hermes_home 里写明。" }
$env:HERMES_HOME = $Home_

Write-Host "hermes      = $Hermes"
Write-Host "HERMES_HOME = $Home_"
Write-Host "config      = $Config"
if ($DryRun) { Write-Host "DRY RUN：只打印，不执行" -ForegroundColor Cyan }
Write-Host ""

# ---------- 工具函数 ----------
function Run([string[]]$ArgList, [switch]$ReadOnly) {
    Write-Host ("  > hermes " + ($ArgList -join " ")) -ForegroundColor DarkGray
    if ($DryRun -and -not $ReadOnly) { return "" }   # 只读命令在空跑时也真的执行，这样判断才准
    $out = & $Hermes @ArgList 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host $out -ForegroundColor Yellow }
    return $out
}
function Render-RouterSoul([string]$Text) {
    # 把配置里的角色清单渲染进 Router 的 SOUL（<!-- ROSTER:BEGIN --> … <!-- ROSTER:END --> 之间）。
    # 角色随任务增减时只改 superagent.config.json，重跑安装即可，Router 自然知道现在有谁。
    $lines = @()
    foreach ($w in $workers) { $lines += "- ``$($w.profile)``：$($w.description)" }
    $block = "<!-- ROSTER:BEGIN -->`n" + ($lines -join "`n") + "`n<!-- ROSTER:END -->"
    if ($Text -match "(?s)<!-- ROSTER:BEGIN -->.*?<!-- ROSTER:END -->") {
        return [regex]::Replace($Text, "(?s)<!-- ROSTER:BEGIN -->.*?<!-- ROSTER:END -->", $block.Replace('$', '$$'))
    }
    return $Text + "`n`n## 当前可派的角色`n`n" + $block + "`n"
}
function Copy-WithBackup([string]$Src, [string]$Dst, [string]$BackupDir, [string]$BackupName) {
    if ($DryRun) { Write-Host "  copy $Src -> $Dst" -ForegroundColor DarkGray; return }
    if (Test-Path $Dst) {
        New-Item -ItemType Directory -Force $BackupDir | Out-Null
        Copy-Item $Dst (Join-Path $BackupDir $BackupName) -Force
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $Dst) | Out-Null
    Copy-Item $Src $Dst -Force
}

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = Join-Path $Kit "backup\$Stamp"

# ---------- 1. profile ----------
Write-Host "[1/6] profile"
$existing = @()
$listOut = Run @("profile", "list") -ReadOnly
foreach ($line in ($listOut -split "`n")) {
    if ($line -match '^\s*[◆\s]*([a-z0-9_-]+)\s') { $existing += $Matches[1] }
}
foreach ($role in $allRoles) {
    $name = $role.profile
    if ($existing -contains $name) {
        Write-Host "  $name 已存在，更新描述"
        Run @("profile", "describe", $name, "--text", $role.description) | Out-Null
    } else {
        Write-Host "  创建 $name（克隆默认 profile 的模型与密钥）"
        Run @("profile", "create", $name, "--clone", "--description", $role.description) | Out-Null
    }
}

# ---------- 2. SOUL / 技能 / 脚本 ----------
Write-Host "[2/6] SOUL、技能、看门狗脚本"
$rendered = Join-Path $env:TEMP "sa-souls-$Stamp"
New-Item -ItemType Directory -Force $rendered | Out-Null
foreach ($role in $allRoles) {
    $name = $role.profile
    $soulSrc = Join-Path $Kit "souls\$name.md"
    if (-not (Test-Path $soulSrc)) {
        # 新角色没有专属 SOUL 时，用通用工人模板渲染一份（把名字和职责填进去）
        $tmpl = Join-Path $Kit "souls\_worker_template.md"
        if (-not (Test-Path $tmpl)) { Write-Host "  跳过 $name：souls\$name.md 不存在" -ForegroundColor Yellow; continue }
        $text = (Get-Content -Raw -Encoding UTF8 $tmpl).Replace("{{PROFILE}}", $name).Replace("{{DESCRIPTION}}", $role.description)
        Write-Host "  $name 没有专属 SOUL，用 _worker_template.md 生成" -ForegroundColor Yellow
    } else {
        $text = Get-Content -Raw -Encoding UTF8 $soulSrc
    }
    if ($name -eq $router.profile) { $text = Render-RouterSoul $text }
    $tmp = Join-Path $rendered "$name.md"
    [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $false))
    Copy-WithBackup $tmp (Join-Path $Home_ "profiles\$name\SOUL.md") $Backup "$name.SOUL.md"
    Write-Host "  SOUL -> profiles\$name\SOUL.md"
}
$skillsTarget = Join-Path $Home_ "skills\superagent"
if (-not $DryRun) {
    New-Item -ItemType Directory -Force $skillsTarget | Out-Null
    Copy-Item (Join-Path $Kit "skills\superagent\*") $skillsTarget -Recurse -Force
}
Write-Host "  技能 -> $skillsTarget"
foreach ($dir in @((Join-Path $Home_ "scripts"), (Join-Path $Home_ "profiles\$($router.profile)\scripts"))) {
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item (Join-Path $Kit "scripts\sa_watchdog.py") $dir -Force
    }
    Write-Host "  看门狗 -> $dir\sa_watchdog.py"
}

# ---------- 3. kanban 配置 ----------
Write-Host "[3/6] kanban 配置（默认 profile 与 Router profile 各写一份）"
$autoDecompose = if ($cfg.kanban.auto_decompose) { "true" } else { "false" }
$reviewDispatch = if ($cfg.kanban.review_dispatch) { "true" } else { "false" }
foreach ($scope in @(@(), @("-p", $router.profile))) {
    Run ($scope + @("config", "set", "kanban.orchestrator_profile", $router.profile)) | Out-Null
    Run ($scope + @("config", "set", "kanban.default_assignee", $router.profile)) | Out-Null
    Run ($scope + @("config", "set", "kanban.auto_decompose", $autoDecompose)) | Out-Null
    Run ($scope + @("config", "set", "kanban.review_dispatch", $reviewDispatch)) | Out-Null
}

# ---------- 4. Router 收权 + 模型 ----------
Write-Host "[4/6] Router 收权与各角色模型"
foreach ($plat in $router.platforms) {
    Run (@("-p", $router.profile, "tools", "enable") + @($router.keep_toolsets) + @("--platform", $plat)) | Out-Null
    Run (@("-p", $router.profile, "tools", "disable") + @($router.drop_toolsets) + @("--platform", $plat)) | Out-Null
}
foreach ($role in $allRoles) {
    if ($role.model) {
        Run @("-p", $role.profile, "config", "set", "model.default", $role.model) | Out-Null
        Write-Host "  $($role.profile) 模型 = $($role.model)"
    }
}

# ---------- 5. 看门狗 cron ----------
Write-Host "[5/6] 看门狗 cron"
$deliver = "$($cfg.watchdog.deliver)"
if ($SkipCron -or -not $cfg.watchdog.enabled -or -not $deliver -or $deliver -match "替换") {
    Write-Host "  跳过（未配置投递目标或 -SkipCron）。手动创建：" -ForegroundColor Yellow
    Write-Host "  hermes -p $($router.profile) cron create `"$($cfg.watchdog.interval)`" --name sa-watchdog --no-agent --script sa_watchdog.py --deliver 平台:聊天id"
} else {
    $cronList = Run @("-p", $router.profile, "cron", "list") -ReadOnly
    if ($cronList -match "sa-watchdog") {
        Write-Host "  已存在 sa-watchdog，跳过"
    } else {
        Run @("-p", $router.profile, "cron", "create", $cfg.watchdog.interval, "--name", "sa-watchdog", "--no-agent", "--script", "sa_watchdog.py", "--deliver", $deliver) | Out-Null
        Write-Host "  已创建 sa-watchdog（$($cfg.watchdog.interval) -> $deliver）"
    }
}

# ---------- 6. 飞书白名单检查（只读） ----------
Write-Host "[6/6] 飞书白名单检查（不改 .env）"
$envFile = Join-Path $Home_ "profiles\$($router.profile)\.env"
$wantUsers = @($cfg.feishu.allowed_users) | Where-Object { $_ -and ($_ -notmatch "替换") }
if (Test-Path $envFile) {
    $envText = Get-Content -Raw -Encoding UTF8 $envFile
    $hasUsers = $envText -match "(?m)^FEISHU_ALLOWED_USERS=\S+"
    $policy = if ($envText -match "(?m)^FEISHU_GROUP_POLICY=(\S+)") { $Matches[1] } else { "(未设置)" }
    if ($hasUsers -and $policy -eq $cfg.feishu.group_policy) {
        Write-Host "  OK：白名单已设置，群策略 = $policy"
    } else {
        Write-Host "  请在 $envFile 里设置（这是门卫，不设等于不设防）：" -ForegroundColor Yellow
        Write-Host "    FEISHU_ALLOWED_USERS=$(if ($wantUsers) { $wantUsers -join ',' } else { 'ou_你的openid' })"
        Write-Host "    FEISHU_GROUP_POLICY=$($cfg.feishu.group_policy)"
    }
} else {
    Write-Host "  Router profile 还没有 .env（飞书未接入）。接入后再设 FEISHU_ALLOWED_USERS / FEISHU_GROUP_POLICY。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "完成。最后一步：hermes gateway restart（让工具与配置对网关生效）。" -ForegroundColor Green
Write-Host "验证：hermes profile list；hermes kanban stats；在飞书对 $($router.profile) 说一句需要多步的话。"
if (-not $DryRun -and (Test-Path $Backup)) { Write-Host "旧 SOUL 备份：$Backup" }
