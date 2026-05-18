# AI Terminal daemon installer (Windows PowerShell)
# Usage / 用法:
#   irm https://dist.ai-terminal.org/install.ps1 | iex
# (use `iex (iwr -useb URL).Content` if `iwr | iex` corrupts UTF-8 on PS 5.1)

$ErrorActionPreference = 'Stop'

# === Console UTF-8 setup (避免中文乱码) ===
# PS 5.1 ConHost 默认 OEM CP, 必须 chcp 65001 + Console.OutputEncoding = UTF-8.
# iex 场景里 chcp.com 子进程副作用可能不传父 console, 用 P/Invoke 直调 kernel32.
try {
    $sig = @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleOutputCP(uint cp);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCP(uint cp);
'@
    $k32 = Add-Type -MemberDefinition $sig -Name 'AITKernel32' -Namespace 'AITNS' -PassThru -ErrorAction SilentlyContinue
    if ($k32) {
        [void]$k32::SetConsoleOutputCP(65001)
        [void]$k32::SetConsoleCP(65001)
    }
} catch {}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding  = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = [Console]::OutputEncoding

# === i18n: 检测语言 (zh/en), 用户可 $env:AITERMINAL_LANG=en 强制覆盖 ===
$Locale = if ($env:AITERMINAL_LANG) { $env:AITERMINAL_LANG } else { (Get-Culture).TwoLetterISOLanguageName }
$IsZh = $Locale -eq 'zh'
function T($zh, $en) { if ($IsZh) { return $zh } else { return $en } }

# === CDN 分流: 中文环境自动用 ai-terminal.cn (Aliyun CDN, 根域), 否则用 dist.ai-terminal.org (Cloudflare) ===
# 注: 国内 CDN 绑根域, 海外用 dist 子域 (二者不对称, 这是当前部署事实)
# 用户可 $env:AITERMINAL_DOMAIN=dist.ai-terminal.org 强制覆盖
$DefaultDomain = if ($IsZh) { 'ai-terminal.cn' } else { 'dist.ai-terminal.org' }

function Write-Info($msg) { Write-Host "→ $msg" -ForegroundColor Blue }
function Write-Success($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "✗ $msg" -ForegroundColor Red }

# 2026-05-15: 非交互 helper. 修 `irm | iex` 流下 Read-Host 卡死 bug.
# `irm | iex` 推荐用法是 non-interactive 但脚本里多个 Read-Host 等键盘 → silently hang.
# 自动 detect (Console::IsInputRedirected / Environment::UserInteractive 任一为真 = 非交互),
# 或 env AITERMINAL_NO_INTERACTIVE=1 强 default. 默认走脚本推荐值.
function Read-HostOrDefault($prompt, $default) {
    $isNonInteractive = $false
    try { if ([Console]::IsInputRedirected) { $isNonInteractive = $true } } catch {}
    if (-not [Environment]::UserInteractive) { $isNonInteractive = $true }
    if ($env:AITERMINAL_NO_INTERACTIVE) { $isNonInteractive = $true }
    if ($isNonInteractive) {
        Write-Host "${prompt} [non-interactive, using default → ${default}]" -ForegroundColor DarkGray
        return $default
    }
    return Read-Host $prompt
}

$Domain = if ($env:AITERMINAL_DOMAIN) { $env:AITERMINAL_DOMAIN } else { $DefaultDomain }
$InstallDir = if ($env:AITERMINAL_HOME) { $env:AITERMINAL_HOME } else { Join-Path $env:USERPROFILE '.aiterminal' }
$BinDir = Join-Path $InstallDir 'bin'
$PkgDir = Join-Path $InstallDir 'pkg'

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "║      AI Terminal Installer           ║" -ForegroundColor Blue
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""

# 1. 检测 Windows 版本 (ConPTY 要求 Build 17763+)
$winVer = [System.Environment]::OSVersion.Version
if ($winVer.Major -lt 10 -or $winVer.Build -lt 17763) {
    Write-Err (T "需要 Windows 10 1809+ (Build 17763+),当前: $($winVer.Major).$($winVer.Build)" `
                "Requires Windows 10 1809+ (Build 17763+), got: $($winVer.Major).$($winVer.Build)")
    exit 1
}
Write-Success "Windows $($winVer.Major).$($winVer.Build)"

# 2. PowerShell 版本
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Err (T "需要 PowerShell 5.1+ (当前: $($PSVersionTable.PSVersion))" `
                "Requires PowerShell 5.1+ (got: $($PSVersionTable.PSVersion))")
    exit 1
}

# 3. Node.js 18+
try {
    $nodeVer = (node -v 2>$null).Trim().TrimStart('v')
    $nodeMajor = [int]($nodeVer -split '\.')[0]
    if ($nodeMajor -lt 18) {
        Write-Err (T "Node.js v$nodeVer 过低 (需要 18+)" "Node.js v$nodeVer too old (need 18+)")
        exit 1
    }
    Write-Success "Node.js v$nodeVer"
} catch {
    Write-Err (T "没有检测到 Node.js 18+" "Node.js 18+ not found")
    Write-Host (T "  下载: https://nodejs.org" "  Download: https://nodejs.org") -ForegroundColor Yellow
    Write-Host (T "  或:   winget install OpenJS.NodeJS.LTS" "  Or:       winget install OpenJS.NodeJS.LTS") -ForegroundColor Blue
    exit 1
}

# 4. 检测 + 安装 psmux (Windows 原生 tmux 兼容,提供 tmux.exe)
if (Get-Command tmux -ErrorAction SilentlyContinue) {
    Write-Success (T "tmux/psmux 已安装" "tmux/psmux already installed")
} else {
    Write-Info (T "安装 psmux..." "Installing psmux...")
    $installed = $false
    # 从我们自己的 CDN 下 psmux (不走 github.com,避开国内访问问题)
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    } else { 'x64' }
    $psmuxUrl = "https://${Domain}/psmux/psmux-win-${arch}.zip"
    $zipPath = Join-Path $env:TEMP "psmux-download.zip"
    $psmuxDir = Join-Path $InstallDir 'psmux'
    try {
        Write-Host (T "  下载 psmux ($arch) 从 $Domain ..." "  Downloading psmux ($arch) from $Domain ...")
        Invoke-WebRequest -UseBasicParsing -Uri $psmuxUrl -OutFile $zipPath -TimeoutSec 60
        New-Item -ItemType Directory -Force -Path $psmuxDir | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $psmuxDir -Force
        Remove-Item $zipPath -Force
        # 解压后 tmux.exe 可能在子目录,找一下
        $exeDir = $psmuxDir
        if (-not (Test-Path (Join-Path $psmuxDir 'tmux.exe'))) {
            $found = Get-ChildItem -Path $psmuxDir -Recurse -Filter 'tmux.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $exeDir = $found.DirectoryName }
        }
        # 加用户级 PATH
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$exeDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$exeDir", 'User')
        }
        $env:Path = "$env:Path;$exeDir"
        if (Get-Command tmux -ErrorAction SilentlyContinue) {
            $installed = $true
            Write-Success (T "psmux 装好了 ($exeDir)" "psmux installed at ($exeDir)")
        }
        # 冗余: 把 tmux.exe 复制到 bin/, 即便 PATH 没刷新也能找到
        $psmuxTmux = Join-Path $exeDir 'tmux.exe'
        if (Test-Path $psmuxTmux) {
            New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
            Copy-Item $psmuxTmux (Join-Path $BinDir 'tmux.exe') -Force
            $psmuxExe = Join-Path $exeDir 'psmux.exe'
            if (Test-Path $psmuxExe) { Copy-Item $psmuxExe (Join-Path $BinDir 'psmux.exe') -Force }
        }
    } catch {
        Write-Err (T "psmux 下载失败: $_" "psmux download failed: $_")
    }
    if (-not $installed) {
        Write-Err (T "psmux 自动安装失败" "psmux auto-install failed")
        Write-Host (T "  手动装任选: " "  Install manually (any of): ") -ForegroundColor Yellow
        Write-Host (T "    scoop install psmux     (推荐,无需管理员)" `
                     "    scoop install psmux     (recommended, no admin needed)") -ForegroundColor Blue
        Write-Host (T "    winget install -e --id marlocarlo.psmux  (会弹 UAC 权限确认)" `
                     "    winget install -e --id marlocarlo.psmux  (will trigger UAC prompt)") -ForegroundColor Blue
        Write-Host (T "    cargo install psmux     (需 Rust 工具链)" `
                     "    cargo install psmux     (requires Rust toolchain)") -ForegroundColor Blue
        Write-Host (T "  装好后重跑本脚本" "  Then re-run this installer")
        exit 1
    }
}

# 5. 创建目录
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $PkgDir | Out-Null

# 6. 下载 daemon bundle
Write-Info (T "下载 daemon..." "Downloading daemon bundle...")
$bundleUrl = "https://${Domain}/dist/aiterminal.js"
$bundlePath = Join-Path $BinDir 'aiterminal.js'
try {
    Invoke-WebRequest -UseBasicParsing -Uri $bundleUrl -OutFile $bundlePath
    Write-Success (T "daemon 已下载到 $bundlePath" "daemon downloaded to $bundlePath")
} catch {
    Write-Err (T "下载失败: $bundleUrl" "Download failed: $bundleUrl")
    Write-Host (T "  错误: $_" "  Error: $_")
    exit 1
}

# 7. 创建 wrapper.cmd
$wrapperPath = Join-Path $BinDir 'aiterminal.cmd'
$wrapperContent = @"
@echo off
setlocal
set "PATH=$BinDir;$InstallDir\psmux;%PATH%"
set "NODE_PATH=$PkgDir\node_modules;%NODE_PATH%"
if not defined WS_PORT set "WS_PORT=29876"
node "$bundlePath" %*
"@
Set-Content -Path $wrapperPath -Value $wrapperContent -Encoding ASCII

# 8. (removed) node-pty 装
# 2026-05-15 daemon 重构: src/terminal/index.js 改为统一 re-export tmux, 不再使用 PtyBackend.
# node-pty 依赖 + pty-backend.js / backend.js 整体删除, daemon bundle 不含 node-pty 引用 (verified).
# 本步骤之前在 Windows 上需要 VS Build Tools + Python 装 native module, 大部分用户没装 → silent fail
# 且 error 全吞 (2>$null | Out-Null) 让用户看不到原因. 移除后 install.ps1 装成功率 ↑.

# 9. 加入 PATH (用户级)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$BinDir", 'User')
    $env:Path = "$env:Path;$BinDir"
    Write-Success (T "已添加 PATH (用户级)" "Added to user PATH")
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Success (T "安装完成" "Install complete")
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host (T "  启动: " "  Run: ") -NoNewline
Write-Host "aiterminal" -ForegroundColor Blue
Write-Host (T "  (或重启 PowerShell 后再用 aiterminal 命令)" `
             "  (or restart PowerShell then use the 'aiterminal' command)")
Write-Host ""

# 10. 生成 tmux 启动器 (aiterminal-tmux.cmd) — 给快捷方式 / 立刻打开 都用
$tmuxLauncher = Join-Path $BinDir 'aiterminal-tmux.cmd'
$tmuxLauncherContent = @"
@echo off
setlocal
set "PATH=$BinDir;$InstallDir\psmux;%PATH%"
title AI Terminal (tmux)
tmux new-session -A -s ai-terminal
"@
Set-Content -Path $tmuxLauncher -Value $tmuxLauncherContent -Encoding ASCII

# 11. 桌面+开始菜单快捷方式 (默认直接生成,不询问;无害,不要可删)
if ($true) {
    try {
        $WScript = New-Object -ComObject WScript.Shell
        $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Terminal.lnk'
        $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
        $startMenuLnk = Join-Path $startMenuDir 'AI Terminal.lnk'

        foreach ($lnkPath in @($desktopLnk, $startMenuLnk)) {
            $lnk = $WScript.CreateShortcut($lnkPath)
            $lnk.TargetPath = $tmuxLauncher
            $lnk.WorkingDirectory = $env:USERPROFILE
            $lnk.IconLocation = "$env:WINDIR\System32\cmd.exe,0"
            $lnk.Description = (T '双击进入 tmux 环境,在里面运行 AI 工具(claude/cursor/aider 等)或终端命令,手机即可同步看到/操控' `
                                  'Double-click to enter a tmux session. Run AI tools (claude/cursor/aider) or any shell command inside; your phone mirrors the screen.')
            $lnk.Save()
        }
        Write-Success (T "快捷方式已生成: 桌面 + 开始菜单" "Shortcut created: Desktop + Start Menu")
        Write-Host (T "  💡 双击进入 tmux,在里面跑 claude/cursor/aider 等,手机就能同步看到" `
                     "  💡 Double-click → tmux. Run claude/cursor/aider inside; phone mirrors live.") -ForegroundColor Yellow
    } catch {
        Write-Warn (T "快捷方式生成失败: $_" "Shortcut creation failed: $_")
    }
}

# 12. 预授权 Windows Defender Firewall (避免 daemon 首次启动弹"允许通信"对话框)
# 加 inbound 规则放行 daemon 端口 29876 + 29877 (LAN 配对/管理 API)
# 用 PS Start-Process -Verb RunAs 触发 UAC 一次性授权; 用户拒绝就跳过 (daemon 仍会跑, 只是首次会弹原生授权框)
$fwAns = Read-HostOrDefault (T "提前授权 Windows 防火墙开放 daemon 端口? (Y/n) — 推荐 Y, 避免首次启动弹授权框 (会弹一次 UAC)" `
                       "Pre-allow Windows Firewall for daemon ports? (Y/n) — recommended Y to skip the first-run prompt (one UAC needed)") 'Y'
if ($fwAns -ne 'n' -and $fwAns -ne 'N') {
    try {
        $fwScript = @"
New-NetFirewallRule -DisplayName 'AI Terminal daemon (29876)' -Direction Inbound -Protocol TCP -LocalPort 29876 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'AI Terminal daemon (29877)' -Direction Inbound -Protocol TCP -LocalPort 29877 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
"@
        # 写到临时 .ps1 然后 RunAs (Start-Process 不能直接传多行命令)
        $tmpFw = Join-Path $env:TEMP 'aiterminal-fw-allow.ps1'
        Set-Content -Path $tmpFw -Value $fwScript -Encoding UTF8
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmpFw -Verb RunAs -Wait
        Remove-Item $tmpFw -Force -ErrorAction SilentlyContinue
        Write-Success (T "防火墙规则已加 (TCP 29876, 29877)" "Firewall rules added (TCP 29876, 29877)")
    } catch {
        Write-Warn (T "防火墙规则添加失败 (可能拒绝了 UAC), daemon 首次启动会弹系统授权框" `
                     "Firewall rule add failed (UAC may be denied), system prompt will appear on first daemon launch")
    }
}

# 13. 开机自启 daemon (用 cli.js 的 enable-autostart, 写 HKCU\Run + VBS 隐藏窗口)
$autostartAns = Read-HostOrDefault (T "开机自启 daemon? (Y/n) — 推荐 Y, 这样 Windows 重启后无需手动启动" `
                            "Start daemon at boot? (Y/n) — recommended Y so you don't have to manually start after reboot") 'Y'
if ($autostartAns -ne 'n' -and $autostartAns -ne 'N') {
    try {
        & $wrapperPath enable-autostart
    } catch {
        Write-Warn (T "开机自启设置失败: $_" "Autostart setup failed: $_")
    }
}

# 13. 自动启动 daemon
$launch = Read-HostOrDefault (T "现在启动 daemon? (Y/n)" "Start daemon now? (Y/n)") 'Y'
if ($launch -ne 'n' -and $launch -ne 'N') {
    & $wrapperPath
}

# 13. 立刻打开 tmux 窗口让用户开始用
$openNow = Read-HostOrDefault (T "现在直接打开 tmux 让你开始用? (Y/n)" "Open a tmux window now to get started? (Y/n)") 'Y'
if ($openNow -ne 'n' -and $openNow -ne 'N') {
    Start-Process -FilePath $tmuxLauncher
    Write-Host ""
    Write-Host (T "  ✓ tmux 窗口已打开,在里面敲 " "  ✓ tmux window opened. Type ") -NoNewline
    Write-Host "claude" -ForegroundColor Blue -NoNewline
    Write-Host (T " (或其他 AI 工具) 即可开始用" " (or any AI CLI) inside to start")
    Write-Host (T "  ✓ 手机扫码完成后会自动看到这个 session" `
                 "  ✓ Once paired, your phone will see this session automatically")
}
