# AI Terminal daemon uninstaller (Windows PowerShell)
# Usage:
#   irm https://dist.ai-terminal.org/uninstall.ps1 | iex

$ErrorActionPreference = 'Continue'

# Console UTF-8 (avoid garbled non-ASCII output)
try {
    $sig = @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleOutputCP(uint cp);
'@
    $k32 = Add-Type -MemberDefinition $sig -Name 'AITKernel32U' -Namespace 'AITNS' -PassThru -ErrorAction SilentlyContinue
    if ($k32) { [void]$k32::SetConsoleOutputCP(65001) }
} catch {}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Write-Info($msg) { Write-Host "→ $msg" -ForegroundColor Blue }
function Write-Success($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }

$InstallDir = if ($env:AITERMINAL_HOME) { $env:AITERMINAL_HOME } else { Join-Path $env:USERPROFILE '.aiterminal' }
$BinDir = Join-Path $InstallDir 'bin'

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║   AI Terminal Uninstaller            ║" -ForegroundColor Yellow
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""
Write-Host "Will remove:"
Write-Host "  • $InstallDir  (daemon + node-pty + psmux)"
Write-Host "  • daemon bin from PATH"
Write-Host "  • Auto-start (HKCU\Run\AITerminalDaemon)"
Write-Host "  • Desktop + Start Menu shortcuts"
Write-Host "  • Firewall rules (TCP 29876, 29877) — needs UAC"
Write-Host ""
Write-Host "Will keep:" -ForegroundColor Yellow
Write-Host "  • Node.js (may be used by other apps)"
Write-Host "  • Files you received (under Documents, not install dir)"
Write-Host ""

$confirm = Read-Host "Confirm uninstall? (y/N)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host "Cancelled"
    exit 0
}

# 1. Stop running daemon
Write-Info "Stopping daemon..."
$wrapper = Join-Path $BinDir 'aiterminal.cmd'
if (Test-Path $wrapper) {
    try { & $wrapper stop 2>$null | Out-Null } catch {}
}
# Fallback: kill node processes running aiterminal.js
Get-Process -Name 'node' -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -match 'aiterminal\.js' } catch { $false }
} | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Success "daemon stopped"

# 2. Disable auto-start
Write-Info "Disabling auto-start..."
try {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'AITerminalDaemon' -ErrorAction SilentlyContinue
    Write-Success "Removed HKCU\Run\AITerminalDaemon"
} catch {}

# 3. Remove shortcuts
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AI Terminal.lnk'
$startMenuLnk = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\AI Terminal.lnk'
foreach ($lnk in @($desktopLnk, $startMenuLnk)) {
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        Write-Success "Removed: $lnk"
    }
}

# 4. Remove from PATH
Write-Info "Removing from PATH..."
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$psmuxPath = Join-Path $InstallDir 'psmux'
$newPath = ($userPath -split ';' | Where-Object {
    $_ -ne $BinDir -and $_ -notlike "$psmuxPath*" -and $_ -ne ''
}) -join ';'
if ($newPath -ne $userPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Success "PATH cleaned (restart shell to apply)"
}

# 5. Remove firewall rules (needs UAC)
$fwAns = Read-Host "Remove firewall rules? (Y/n) — UAC prompt"
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
        Write-Success "Firewall rules removed"
    } catch {
        Write-Warn "Firewall rule remove failed (open wf.msc to remove manually)"
    }
}

# 6. Remove install dir
if (Test-Path $InstallDir) {
    Write-Info "Removing $InstallDir ..."
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Write-Warn "Some files may be locked, remove manually: $InstallDir"
    } else {
        Write-Success "Removed $InstallDir"
    }
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Success "Uninstall complete"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
