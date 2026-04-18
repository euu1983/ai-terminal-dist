# AI Terminal daemon installer (Windows PowerShell)
# 用法: iwr -useb https://dist.ai-terminal.org/install.ps1 | iex

$ErrorActionPreference = 'Stop'
# 让 Write-Host 输出的中文显示正常 (PowerShell 默认 console 编码可能是 GBK/CP936)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info($msg) { Write-Host "→ $msg" -ForegroundColor Blue }
function Write-Success($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "! $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "✗ $msg" -ForegroundColor Red }

$Domain = if ($env:AITERMINAL_DOMAIN) { $env:AITERMINAL_DOMAIN } else { 'dist.ai-terminal.org' }
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
    Write-Err "需要 Windows 10 1809+ (Build 17763+),当前: $($winVer.Major).$($winVer.Build)"
    exit 1
}
Write-Success "Windows $($winVer.Major).$($winVer.Build)"

# 2. PowerShell 版本
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Err "需要 PowerShell 5.1+ (当前: $($PSVersionTable.PSVersion))"
    exit 1
}

# 3. Node.js 18+
try {
    $nodeVer = (node -v 2>$null).Trim().TrimStart('v')
    $nodeMajor = [int]($nodeVer -split '\.')[0]
    if ($nodeMajor -lt 18) { Write-Err "Node.js v$nodeVer 过低 (需要 18+)"; exit 1 }
    Write-Success "Node.js v$nodeVer"
} catch {
    Write-Err "没有检测到 Node.js 18+"
    Write-Host "  下载: https://nodejs.org" -ForegroundColor Yellow
    Write-Host "  或:   winget install OpenJS.NodeJS.LTS" -ForegroundColor Blue
    exit 1
}

# 4. 检测 + 安装 psmux (Windows 原生 tmux 兼容,提供 tmux.exe)
if (Get-Command tmux -ErrorAction SilentlyContinue) {
    Write-Success "tmux/psmux 已安装"
} else {
    Write-Info "安装 psmux..."
    $installed = $false
    # 从我们自己的 CDN 下 psmux (不走 github.com,避开国内访问问题)
    $arch = if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    } else { 'x64' }
    $psmuxUrl = "https://${Domain}/psmux/psmux-win-${arch}.zip"
    $zipPath = Join-Path $env:TEMP "psmux-download.zip"
    $psmuxDir = Join-Path $InstallDir 'psmux'
    try {
        Write-Host "  下载 psmux ($arch) 从 $Domain ..."
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
            Write-Success "psmux 装好了 ($exeDir)"
        }
    } catch {
        Write-Err "psmux 下载失败: $_"
    }
    if (-not $installed) {
        Write-Err "psmux 自动安装失败"
        Write-Host "  手动装任选: " -ForegroundColor Yellow
        Write-Host "    scoop install psmux     (推荐,无需管理员)" -ForegroundColor Blue
        Write-Host "    winget install -e --id marlocarlo.psmux  (会弹 UAC 权限确认)" -ForegroundColor Blue
        Write-Host "    cargo install psmux     (需 Rust 工具链)" -ForegroundColor Blue
        Write-Host "  装好后重跑本脚本"
        exit 1
    }
}

# 5. 创建目录
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $PkgDir | Out-Null

# 5. 下载 daemon bundle
Write-Info "下载 daemon..."
$bundleUrl = "https://${Domain}/dist/aiterminal.js"
$bundlePath = Join-Path $BinDir 'aiterminal.js'
try {
    Invoke-WebRequest -UseBasicParsing -Uri $bundleUrl -OutFile $bundlePath
    Write-Success "daemon 已下载到 $bundlePath"
} catch {
    Write-Err "下载失败: $bundleUrl"
    Write-Host "  错误: $_"
    exit 1
}

# 6. 创建 wrapper (.cmd)
$wrapperPath = Join-Path $BinDir 'aiterminal.cmd'
$wrapperContent = @"
@echo off
set NODE_PATH=$PkgDir\node_modules;%NODE_PATH%
node "$bundlePath" %*
"@
Set-Content -Path $wrapperPath -Value $wrapperContent -Encoding ASCII

# 7. 装 node-pty (会拉 win32-x64 prebuild)
Write-Info "安装 node-pty (终端原生模块)..."
Push-Location $PkgDir
try {
    if (-not (Test-Path 'package.json')) {
        '{ "name": "aiterminal-pkg", "version": "1.0.0", "private": true }' | Set-Content -Path 'package.json' -Encoding UTF8
    }
    npm install --no-save --silent node-pty@^1.1.0 2>$null | Out-Null
    Write-Success "node-pty 已安装"
} catch {
    Write-Warn "node-pty 安装失败,daemon 可能无法启动 PowerShell"
} finally {
    Pop-Location
}

# 8. 加入 PATH (用户级,无需管理员)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$BinDir", 'User')
    $env:Path = "$env:Path;$BinDir"
    Write-Success "已添加 PATH (用户级)"
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Success "安装完成"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
Write-Host ""
Write-Host "  启动: " -NoNewline
Write-Host "aiterminal" -ForegroundColor Blue
Write-Host "  (或重启 PowerShell 后再用 aiterminal 命令)"
Write-Host ""

# 9. 自动启动
$launch = Read-Host "现在启动 daemon? (Y/n)"
if ($launch -ne 'n' -and $launch -ne 'N') {
    & $wrapperPath
}
