# AI Terminal daemon installer (Windows PowerShell)
# Usage:
#   irm https://dist.ai-terminal.org/install.ps1 | iex
# (use `iex (iwr -useb URL).Content` if `iwr | iex` corrupts UTF-8 on PS 5.1)

$ErrorActionPreference = 'Stop'

# === Console UTF-8 setup (avoid garbled non-ASCII output) ===
# PS 5.1 ConHost defaults to OEM CP; must chcp 65001 + Console.OutputEncoding = UTF-8.
# Under iex, the chcp.com subprocess side effect may not propagate to the parent console,
# so call kernel32 directly via P/Invoke.
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

function Write-Info($msg) { Write-Host "→ $msg" -ForegroundColor Blue }
function Write-Success($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "✗ $msg" -ForegroundColor Red }

# Override with $env:AITERMINAL_DOMAIN to point at a different CDN/mirror.
$DefaultDomain = 'dist.ai-terminal.org'
$Domain = if ($env:AITERMINAL_DOMAIN) { $env:AITERMINAL_DOMAIN } else { $DefaultDomain }
$InstallDir = if ($env:AITERMINAL_HOME) { $env:AITERMINAL_HOME } else { Join-Path $env:USERPROFILE '.aiterminal' }
$BinDir = Join-Path $InstallDir 'bin'
$PkgDir = Join-Path $InstallDir 'pkg'

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Blue
Write-Host "║      AI Terminal Installer           ║" -ForegroundColor Blue
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Blue
Write-Host ""

# 1. Detect Windows version (ConPTY requires Build 17763+)
$winVer = [System.Environment]::OSVersion.Version
if ($winVer.Major -lt 10 -or $winVer.Build -lt 17763) {
    Write-Err "Requires Windows 10 1809+ (Build 17763+), got: $($winVer.Major).$($winVer.Build)"
    exit 1
}
Write-Success "Windows $($winVer.Major).$($winVer.Build)"

# 2. PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Err "Requires PowerShell 5.1+ (got: $($PSVersionTable.PSVersion))"
    exit 1
}

# 3. Node.js 18+
try {
    $nodeVer = (node -v 2>$null).Trim().TrimStart('v')
    $nodeMajor = [int]($nodeVer -split '\.')[0]
    if ($nodeMajor -lt 18) {
        Write-Err "Node.js v$nodeVer too old (need 18+)"
        exit 1
    }
    Write-Success "Node.js v$nodeVer"
} catch {
    Write-Err "Node.js 18+ not found"
    Write-Host "  Download: https://nodejs.org" -ForegroundColor Yellow
    Write-Host "  Or:       winget install OpenJS.NodeJS.LTS" -ForegroundColor Blue
    exit 1
}

# 4. Detect + install psmux (Windows native tmux-compatible, provides tmux.exe)
if (Get-Command tmux -ErrorAction SilentlyContinue) {
    Write-Success "tmux/psmux already installed"
} else {
    Write-Info "Installing psmux..."
    $installed = $false
    # Pull psmux from our own CDN (avoids depending on github.com availability)
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    } else { 'x64' }
    $psmuxUrl = "https://${Domain}/psmux/psmux-win-${arch}.zip"
    $zipPath = Join-Path $env:TEMP "psmux-download.zip"
    $psmuxDir = Join-Path $InstallDir 'psmux'
    try {
        Write-Host "  Downloading psmux ($arch) from $Domain ..."
        Invoke-WebRequest -UseBasicParsing -Uri $psmuxUrl -OutFile $zipPath -TimeoutSec 60
        New-Item -ItemType Directory -Force -Path $psmuxDir | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $psmuxDir -Force
        Remove-Item $zipPath -Force
        # tmux.exe may live in a subfolder after unzip — locate it
        $exeDir = $psmuxDir
        if (-not (Test-Path (Join-Path $psmuxDir 'tmux.exe'))) {
            $found = Get-ChildItem -Path $psmuxDir -Recurse -Filter 'tmux.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $exeDir = $found.DirectoryName }
        }
        # Add to user-level PATH
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$exeDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$exeDir", 'User')
        }
        $env:Path = "$env:Path;$exeDir"
        if (Get-Command tmux -ErrorAction SilentlyContinue) {
            $installed = $true
            Write-Success "psmux installed at ($exeDir)"
        }
        # Redundancy: copy tmux.exe to bin/ so it's findable even if PATH doesn't refresh
        $psmuxTmux = Join-Path $exeDir 'tmux.exe'
        if (Test-Path $psmuxTmux) {
            New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
            Copy-Item $psmuxTmux (Join-Path $BinDir 'tmux.exe') -Force
            $psmuxExe = Join-Path $exeDir 'psmux.exe'
            if (Test-Path $psmuxExe) { Copy-Item $psmuxExe (Join-Path $BinDir 'psmux.exe') -Force }
        }
    } catch {
        Write-Err "psmux download failed: $_"
    }
    if (-not $installed) {
        Write-Err "psmux auto-install failed"
        Write-Host "  Install manually (any of): " -ForegroundColor Yellow
        Write-Host "    scoop install psmux     (recommended, no admin needed)" -ForegroundColor Blue
        Write-Host "    winget install -e --id marlocarlo.psmux  (will trigger UAC prompt)" -ForegroundColor Blue
        Write-Host "    cargo install psmux     (requires Rust toolchain)" -ForegroundColor Blue
        Write-Host "  Then re-run this installer"
        exit 1
    }
}

# 5. Create directories
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $PkgDir | Out-Null

# 6. Download daemon bundle
Write-Info "Downloading daemon bundle..."
$bundleUrl = "https://${Domain}/dist/aiterminal.js"
$bundlePath = Join-Path $BinDir 'aiterminal.js'
try {
    Invoke-WebRequest -UseBasicParsing -Uri $bundleUrl -OutFile $bundlePath
    Write-Success "daemon downloaded to $bundlePath"
} catch {
    Write-Err "Download failed: $bundleUrl"
    Write-Host "  Error: $_"
    exit 1
}

# 7. Create wrapper.cmd
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

# 8. Install node-pty
Write-Info "Installing node-pty (terminal native module)..."
Push-Location $PkgDir
try {
    if (-not (Test-Path 'package.json')) {
        '{ "name": "aiterminal-pkg", "version": "1.0.0", "private": true }' | Set-Content -Path 'package.json' -Encoding UTF8
    }
    npm install --no-save --silent node-pty@^1.1.0 2>$null | Out-Null
    Write-Success "node-pty installed"
} catch {
    Write-Warn "node-pty install failed; daemon may not be able to start PowerShell"
} finally {
    Pop-Location
}

# 9. Add to user PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$BinDir", 'User')
    $env:Path = "$env:Path;$BinDir"
    Write-Success "Added to user PATH"
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Success "Install complete"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  Run: " -NoNewline
Write-Host "aiterminal" -ForegroundColor Blue
Write-Host "  (or restart PowerShell then use the 'aiterminal' command)"
Write-Host ""

# 10. Generate tmux launcher (aiterminal-tmux.cmd) — used by shortcut + auto-open
$tmuxLauncher = Join-Path $BinDir 'aiterminal-tmux.cmd'
$tmuxLauncherContent = @"
@echo off
setlocal
set "PATH=$BinDir;$InstallDir\psmux;%PATH%"
title AI Terminal (tmux)
tmux new-session -A -s ai-terminal
"@
Set-Content -Path $tmuxLauncher -Value $tmuxLauncherContent -Encoding ASCII

# 11. Desktop + Start menu shortcut (always create; harmless, user can delete)
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
            $lnk.Description = 'Double-click to enter a tmux session. Run AI tools (claude/cursor/aider) or any shell command inside; your phone mirrors the screen.'
            $lnk.Save()
        }
        Write-Success "Shortcut created: Desktop + Start Menu"
        Write-Host "  💡 Double-click → tmux. Run claude/cursor/aider inside; phone mirrors live." -ForegroundColor Yellow
    } catch {
        Write-Warn "Shortcut creation failed: $_"
    }
}

# 12. Pre-authorize Windows Defender Firewall (avoids first-run "allow communication" dialog)
# Add inbound rule for daemon ports 29876 + 29877 (LAN pairing / management API).
# Use Start-Process -Verb RunAs to trigger one-time UAC prompt; if user denies, skip
# (daemon still runs; user just gets the native firewall prompt on first launch).
$fwAns = Read-Host "Pre-allow Windows Firewall for daemon ports? (Y/n) — recommended Y to skip the first-run prompt (one UAC needed)"
if ($fwAns -ne 'n' -and $fwAns -ne 'N') {
    try {
        $fwScript = @"
New-NetFirewallRule -DisplayName 'AI Terminal daemon (29876)' -Direction Inbound -Protocol TCP -LocalPort 29876 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName 'AI Terminal daemon (29877)' -Direction Inbound -Protocol TCP -LocalPort 29877 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
"@
        # Write to temp .ps1 then RunAs (Start-Process can't pass multi-line commands directly)
        $tmpFw = Join-Path $env:TEMP 'aiterminal-fw-allow.ps1'
        Set-Content -Path $tmpFw -Value $fwScript -Encoding UTF8
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmpFw -Verb RunAs -Wait
        Remove-Item $tmpFw -Force -ErrorAction SilentlyContinue
        Write-Success "Firewall rules added (TCP 29876, 29877)"
    } catch {
        Write-Warn "Firewall rule add failed (UAC may be denied), system prompt will appear on first daemon launch"
    }
}

# 13. Auto-start daemon at boot (uses cli.js enable-autostart, writes HKCU\Run + VBS hidden window)
$autostartAns = Read-Host "Start daemon at boot? (Y/n) — recommended Y so you don't have to manually start after reboot"
if ($autostartAns -ne 'n' -and $autostartAns -ne 'N') {
    try {
        & $wrapperPath enable-autostart
    } catch {
        Write-Warn "Autostart setup failed: $_"
    }
}

# 14. Launch daemon now
$launch = Read-Host "Start daemon now? (Y/n)"
if ($launch -ne 'n' -and $launch -ne 'N') {
    & $wrapperPath
}

# 15. Open tmux window so user can start using it immediately
$openNow = Read-Host "Open a tmux window now to get started? (Y/n)"
if ($openNow -ne 'n' -and $openNow -ne 'N') {
    Start-Process -FilePath $tmuxLauncher
    Write-Host ""
    Write-Host "  ✓ tmux window opened. Type " -NoNewline
    Write-Host "claude" -ForegroundColor Blue -NoNewline
    Write-Host " (or any AI CLI) inside to start"
    Write-Host "  ✓ Once paired, your phone will see this session automatically"
}
