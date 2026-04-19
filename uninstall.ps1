# AI Terminal daemon uninstaller (Windows PowerShell)
# Usage / 用法:
#   irm https://dist.ai-terminal.org/uninstall.ps1 | iex
#   irm https://dist.ai-terminal.cn/uninstall.ps1  | iex   # 国内

$ErrorActionPreference = 'Continue'

# Console UTF-8 (避免中文乱码)
try {
    $sig = @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleOutputCP(uint cp);
'@
    $k32 = Add-Type -MemberDefinition $sig -Name 'AITKernel32U' -Namespace 'AITNS' -PassThru -ErrorAction SilentlyContinue
    if ($k32) { [void]$k32::SetConsoleOutputCP(65001) }
} catch {}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# i18n
$Locale = if ($env:AITERMINAL_LANG) { $env:AITERMINAL_LANG } else { (Get-Culture).TwoLetterISOLanguageName }
$IsZh = $Locale -eq 'zh'
function T($zh, $en) { if ($IsZh) { return $zh } else { return $en } }
function Write-Info($msg) { Write-Host "→ $msg" -ForegroundColor Blue }
function Write-Success($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }

$InstallDir = if ($env:AITERMINAL_HOME) { $env:AITERMINAL_HOME } else { Join-Path $env:USERPROFILE '.aiterminal' }
$BinDir = Join-Path $InstallDir 'bin'

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║   AI Terminal Uninstaller            ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""
Write-Host (T "将清除:" "Will remove:")
Write-Host "  • $InstallDir  $(T '(daemon + node-pty + psmux)' '(daemon + node-pty + psmux)')"
Write-Host (T "  • PATH 中的 daemon bin 目录" "  • daemon bin from PATH")
Write-Host (T "  • 开机自启 (HKCU\Run\AITerminalDaemon)" "  • Auto-start (HKCU\Run\AITerminalDaemon)")
Write-Host (T "  • 桌面 + 开始菜单快捷方式" "  • Desktop + Start Menu shortcuts")
Write-Host (T "  • Windows 防火墙规则 (TCP 29876, 29877) — 需 UAC" "  • Firewall rules (TCP 29876, 29877) — needs UAC")
Write-Host ""
Write-Host (T "保留:" "Will keep:") -ForegroundColor Yellow
Write-Host (T "  • Node.js (用户可能给别的程序用)" "  • Node.js (may be used by other apps)")
Write-Host (T "  • 你接收过的文件 (Documents/.aiterminal/* 不在 install 路径下)" "  • Files you received (under Documents, not install dir)")
Write-Host ""

$confirm = Read-Host (T "确认卸载? (y/N)" "Confirm uninstall? (y/N)")
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host (T "已取消" "Cancelled")
    exit 0
}

# 1. 关掉跑着的 daemon
Write-Info (T "停止 daemon..." "Stopping daemon...")
$wrapper = Join-Path $BinDir 'aiterminal.cmd'
if (Test-Path $wrapper) {
    try { & $wrapper stop 2>$null | Out-Null } catch {}
}
# 兜底: 直接 kill node 跑的 aiterminal.js
Get-Process -Name 'node' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -match 'aiterminal\.js' } catch { $false }
} | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Success (T "daemon 已停" "daemon stopped")

# 2. 关掉自启
Write-Info (T "禁用开机自启..." "Disabling auto-start...")
try {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'AITerminalDaemon' -ErrorAction SilentlyContinue
    Write-Success (T "已删 HKCU\Run\AITerminalDaemon" "Removed HKCU\Run\AITerminalDaemon")
} catch {}

# 3. 删快捷方式
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Terminal.lnk'
$startMenuLnk = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\AI Terminal.lnk'
foreach ($lnk in @($desktopLnk, $startMenuLnk)) {
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        Write-Success (T "已删: $lnk" "Removed: $lnk")
    }
}

# 4. 从 PATH 移除
Write-Info (T "从 PATH 移除..." "Removing from PATH...")
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$psmuxPath = Join-Path $InstallDir 'psmux'
$newPath = ($userPath -split ';' | Where-Object {
    $_ -ne $BinDir -and $_ -notlike "$psmuxPath*" -and $_ -ne ''
}) -join ';'
if ($newPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Success (T "PATH 已清理 (重启 shell 生效)" "PATH cleaned (restart shell to apply)")
}

# 5. 删防火墙规则 (需 UAC)
$fwAns = Read-Host (T "删除防火墙规则? (Y/n) — 会弹一次 UAC" "Remove firewall rules? (Y/n) — UAC prompt")
if ($fwAns -ne 'n' -and $fwAns -ne 'N') {
    try {
        $fwScript = @'
Remove-NetFirewallRule -DisplayName 'AI Terminal daemon (29876)' -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName 'AI Terminal daemon (29877)' -ErrorAction SilentlyContinue
'@
        $tmpFw = Join-Path $env:TEMP 'aiterminal-fw-remove.ps1'
        Set-Content -Path $tmpFw -Value $fwScript -Encoding UTF8
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmpFw -Verb RunAs -Wait
        Remove-Item $tmpFw -Force -ErrorAction SilentlyContinue
        Write-Success (T "防火墙规则已删" "Firewall rules removed")
    } catch {
        Write-Warn (T "防火墙规则删除失败 (可能拒绝了 UAC, 手动删: wf.msc)" "Firewall rule remove failed (open wf.msc to remove manually)")
    }
}

# 6. 删 install dir
if (Test-Path $InstallDir) {
    Write-Info (T "删除 $InstallDir ..." "Removing $InstallDir ...")
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Write-Warn (T "部分文件可能被占用,手动删: $InstallDir" "Some files may be locked, remove manually: $InstallDir")
    } else {
        Write-Success (T "已删 $InstallDir" "Removed $InstallDir")
    }
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Success (T "卸载完成" "Uninstall complete")
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
