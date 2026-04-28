#!/usr/bin/env bash
# AI Terminal daemon installer (macOS / Linux / WSL)
# Usage / 用法 (单一入口, CF Worker server-side 看 IP 自动分流 CDN):
#   curl -fsSL https://get.ai-terminal.org/install.sh | bash

# === stdin re-exec guard (curl|bash 模式) ===
# 用 curl|bash 跑时, bash 的 stdin 是 curl 管道 (= script 内容). 脚本里调
# cmd.exe / powershell.exe 等 Windows 子进程时, 它们继承 bash stdin 会消耗
# script 后半部分内容, bash 读到 EOF 提前退出, 后续 daemon 启动 + tmux prompt 跑不到.
# 解决: 检测 stdin 不是 tty (= 管道), 把 stdin 全部内容 dump 到 tmp 文件,
# 然后 exec bash 跑那个 tmp 文件 — 新 bash 的 stdin 不是 script 源, 没有这个 hazard.
if [ ! -t 0 ] && [ -z "$_AITERMINAL_REEXEC" ]; then
  # 之前用 mktemp 在 macOS 反复 install 失败时 /tmp/aiterminal-install-* 残留,
  # BSD mktemp 找不到唯一名 → mkstemp failed → cat > "" + exec bash "" 全炸.
  # 改用 PID + RANDOM 不依赖 mktemp 重试; 顺手清掉历史残留.
  rm -f /tmp/aiterminal-install-*.sh 2>/dev/null
  _TMP_INST=/tmp/aiterminal-install-$$-$RANDOM.sh
  trap 'rm -f "$_TMP_INST"' EXIT
  if ! cat > "$_TMP_INST"; then
    echo "Installer: failed to write $_TMP_INST" >&2
    exit 1
  fi
  export _AITERMINAL_REEXEC=1
  exec bash "$_TMP_INST" "$@"
fi

set -e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# === i18n: 检测语言 (zh/en), 用户可 AITERMINAL_LANG=en 强制覆盖 ===
LANG_PREFIX="${AITERMINAL_LANG:-${LC_ALL:-${LANG:-en}}}"
LANG_PREFIX="${LANG_PREFIX:0:2}"
case "$LANG_PREFIX" in zh|ZH) IS_ZH=true ;; *) IS_ZH=false ;; esac
T() { if [ "$IS_ZH" = true ]; then echo "$1"; else echo "$2"; fi }

# === CDN 选择 (Phase 2 后, 三层优先级) ===
# 1. AITERMINAL_DOMAIN env override (最高, 用户显式指定)
# 2. _INSTALL_SELF_DOMAIN (publish 时 sed 注入, 跟用户实际下载这份脚本的 CDN 一致)
# 3. IS_ZH locale fallback (老逻辑, 没 sed 注入时 fallback)
#
# Phase 2 = CF Worker get.ai-terminal.org → 302 到对应 CDN 的 install.sh,
# ai-terminal-dist publish 脚本在推 ai-terminal.cn / dist.ai-terminal.org 时各自
# sed 替换 dist.ai-terminal.org 成对应域. 这样 CF Worker 把用户分流到
# 哪个 CDN, install.sh 后续 binary 下载就走那个 CDN, 全程一致, 不会拉错.
_INSTALL_SELF_DOMAIN="dist.ai-terminal.org"
# 检测 placeholder 没被 sed 替换 (本地开发或老 publish), fallback 到 IS_ZH
case "$_INSTALL_SELF_DOMAIN" in
  __INSTALL_DOMAIN_*__|"")
    if [ "$IS_ZH" = true ]; then
      DEFAULT_DOMAIN='ai-terminal.cn'
    else
      DEFAULT_DOMAIN='dist.ai-terminal.org'
    fi
    ;;
  *)
    DEFAULT_DOMAIN="$_INSTALL_SELF_DOMAIN"
    ;;
esac
DOMAIN="${AITERMINAL_DOMAIN:-$DEFAULT_DOMAIN}"
INSTALL_DIR="${AITERMINAL_HOME:-$HOME/.aiterminal}"
BIN_DIR="$INSTALL_DIR/bin"
PKG_DIR="$INSTALL_DIR/pkg"

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      AI Terminal Installer           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

# 1. 检测系统
OS="unknown"
case "$(uname -s)" in
  Linux*)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      OS="wsl"; echo -e "${GREEN}✓${NC} $(T '检测到 WSL2 环境' 'Detected WSL2 environment')"
    else
      OS="linux"; echo -e "${GREEN}✓${NC} $(T '检测到 Linux' 'Detected Linux')"
    fi ;;
  Darwin*)
    OS="macos"; echo -e "${GREEN}✓${NC} $(T '检测到 macOS' 'Detected macOS') "
    # Apple Silicon homebrew 默认装在 /opt/homebrew, Intel Mac 在 /usr/local. ssh 非 login shell PATH
    # 不含这些, 后续 command -v brew/tmux/node 全找不到. 显式 shellenv 加进 PATH.
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    ;;
  *)
    echo -e "${RED}✗${NC} $(T '不支持的系统:' 'Unsupported system:') $(uname -s)"
    echo -e "  $(T 'Windows 用户请用 PowerShell:' 'For Windows, use PowerShell:') ${BLUE}irm https://${DOMAIN}/install.ps1 | iex${NC}"
    exit 1 ;;
esac

# 2. 检测 Node.js 18+
if ! command -v node >/dev/null 2>&1; then
  echo -e "${RED}✗${NC} $(T '没有检测到 Node.js 18+' 'Node.js 18+ not found')"
  case $OS in
    macos)
      echo -e "  ${BLUE}brew install node${NC}  $(T '或' 'or')  https://nodejs.org" ;;
    linux|wsl)
      echo -e "  Ubuntu/Debian: ${BLUE}curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs${NC}"
      echo -e "  $(T '或 nvm:       ' 'or nvm:        ') ${BLUE}curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash${NC}" ;;
  esac
  exit 1
fi
NODE_VERSION=$(node -v | sed 's/v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo -e "${RED}✗${NC} $(T "Node.js v$NODE_VERSION 过低 (需要 18+)" "Node.js v$NODE_VERSION too old (need 18+)")"
  exit 1
fi
echo -e "${GREEN}✓${NC} Node.js v$NODE_VERSION"

# 3. 检测 tmux + 自动安装 (兜底, brew/apt/dnf/pacman/zypper)
if ! command -v tmux >/dev/null 2>&1; then
  echo -e "${YELLOW}!${NC} $(T '缺少 tmux, 尝试自动安装...' 'tmux missing, trying to auto-install...')"
  TMUX_INSTALLED=false
  case $OS in
    macos)
      if command -v brew >/dev/null 2>&1; then
        brew install tmux 2>&1 | tail -3 && TMUX_INSTALLED=true
      else
        echo -e "${YELLOW}!${NC} $(T '没装 Homebrew' 'Homebrew not installed')"
        echo -e "  $(T '装一下:' 'Install:') ${BLUE}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}"
      fi ;;
    linux|wsl)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y tmux && TMUX_INSTALLED=true
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y tmux && TMUX_INSTALLED=true
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y tmux && TMUX_INSTALLED=true
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm tmux && TMUX_INSTALLED=true
      elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y tmux && TMUX_INSTALLED=true
      elif command -v apk >/dev/null 2>&1; then
        sudo apk add tmux && TMUX_INSTALLED=true
      else
        echo -e "${YELLOW}!${NC} $(T '没识别出包管理器' 'No known package manager detected')"
      fi ;;
  esac
  if [ "$TMUX_INSTALLED" = true ] && command -v tmux >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} tmux $(tmux -V | awk '{print $2}')"
  else
    echo -e "${RED}✗${NC} $(T 'tmux 自动安装失败' 'tmux auto-install failed')"
    case $OS in
      macos)    echo -e "  $(T '手动装:' 'Install manually:') ${BLUE}brew install tmux${NC}" ;;
      linux|wsl) echo -e "  $(T '手动装:' 'Install manually:') ${BLUE}sudo apt install -y tmux${NC}  $(T '或对应的包管理器' 'or your distro package manager')" ;;
    esac
    read -p "$(T '  装好 tmux 后再继续? 现在继续? (y/N) ' '  Install tmux first then re-run? Continue anyway? (y/N) ')" -n 1 -r REPLY < /dev/tty || REPLY=""
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
  fi
else
  echo -e "${GREEN}✓${NC} tmux $(tmux -V | awk '{print $2}')"
fi

# 4. 下载 daemon bundle
mkdir -p "$BIN_DIR" "$PKG_DIR"
echo -e "${BLUE}→${NC} $(T '下载 daemon...' 'Downloading daemon bundle...')"
if ! curl -fsSL "https://${DOMAIN}/dist/aiterminal.js" -o "$BIN_DIR/aiterminal.js"; then
  echo -e "${RED}✗${NC} $(T '下载失败' 'Download failed') (https://${DOMAIN}/dist/aiterminal.js)"
  exit 1
fi
chmod +x "$BIN_DIR/aiterminal.js"

# 创建 wrapper 脚本 (handles node-pty NODE_PATH)
cat > "$BIN_DIR/aiterminal" <<EOF
#!/bin/sh
export NODE_PATH="$PKG_DIR/node_modules:\${NODE_PATH:-}"
exec node "$BIN_DIR/aiterminal.js" "\$@"
EOF
chmod +x "$BIN_DIR/aiterminal"
echo -e "${GREEN}✓${NC} $(T "daemon 已下载到 $BIN_DIR" "daemon downloaded to $BIN_DIR")"

# 5. 装 node-pty
echo -e "${BLUE}→${NC} $(T '安装 node-pty (终端原生模块)...' 'Installing node-pty (terminal native module)...')"
cd "$PKG_DIR"
if [ ! -f package.json ]; then
  cat > package.json <<EOF
{ "name": "aiterminal-pkg", "version": "1.0.0", "private": true }
EOF
fi
if npm install --no-save --silent node-pty@^1.1.0 2>/dev/null; then
  echo -e "${GREEN}✓${NC} $(T 'node-pty 安装成功' 'node-pty installed')"
else
  echo -e "${YELLOW}!${NC} $(T 'node-pty 安装失败 (Linux/macOS 终端功能受限)' 'node-pty install failed (terminal features will be limited)')"
fi

# 6. 加入 PATH
SHELL_RC=""
case "$SHELL" in
  */zsh)  SHELL_RC="$HOME/.zshrc" ;;
  */bash) SHELL_RC="$HOME/.bashrc" ;;
  */fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
esac
PATH_LINE='export PATH="$HOME/.aiterminal/bin:$PATH"'
if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && ! grep -q ".aiterminal/bin" "$SHELL_RC"; then
  echo "" >> "$SHELL_RC"
  echo "# AI Terminal" >> "$SHELL_RC"
  echo "$PATH_LINE" >> "$SHELL_RC"
  echo -e "${GREEN}✓${NC} $(T "已添加 PATH 到 $SHELL_RC" "Added PATH to $SHELL_RC")"
fi

# 7. 检测桌面环境 / WSL (决定快捷方式做法)
HAS_DESKTOP=false
IS_WSL=false
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
  HAS_DESKTOP=true
fi
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=true
fi

# 8. 生成快捷方式 + tmux 入口 (按平台分支)
TMUX_CMD="tmux new-session -A -s ai-terminal"
make_shortcut() {
  case $OS in
    macos)
      mkdir -p "$HOME/Applications"
      local target="$HOME/Applications/AI Terminal.command"
      cat > "$target" <<EOF
#!/bin/bash
# Double-click to enter tmux. Run AI tools (claude/cursor/aider) inside; phone mirrors live.
# 双击进入 tmux, 跑 AI 工具(claude/cursor/aider 等)或终端命令, 手机即可同步
$TMUX_CMD
EOF
      chmod +x "$target"
      xattr -d com.apple.quarantine "$target" 2>/dev/null || true
      echo -e "${GREEN}✓${NC} $(T '快捷方式:' 'Shortcut:') ${BLUE}~/Applications/AI Terminal.command${NC}"
      echo -e "  $(T "  💡 拖到 Dock 或用 Spotlight 搜 'AI Terminal' 快速打开" "  💡 Drag to Dock or search 'AI Terminal' in Spotlight to launch")"
      ;;
    wsl)
      local win_user
      # 注意 < /dev/null: curl|bash 模式 bash 从 stdin 读 install.sh, cmd.exe / powershell.exe
      # 默认继承 bash 的 stdin (curl 管道), 会吸走 script 后半部分导致 bash 提前 EOF 退出
      win_user=$(cmd.exe /c "echo %USERNAME%" < /dev/null 2>/dev/null | tr -d '\r\n')
      if [ -z "$win_user" ]; then
        echo -e "${YELLOW}!${NC} $(T '无法检测 Windows 用户, 跳过快捷方式' 'Cannot detect Windows username, skipping shortcut')"
        return
      fi
      local desktop="/mnt/c/Users/$win_user/Desktop"
      if [ ! -d "$desktop" ]; then
        echo -e "${YELLOW}!${NC} $(T "找不到 Windows 桌面: $desktop" "Windows desktop not found: $desktop")"
        return
      fi
      local distro="${WSL_DISTRO_NAME:-Ubuntu}"
      local desc
      desc=$(T "双击进入 WSL($distro) tmux,在里面跑 AI 工具,手机即可同步" \
                "Double-click to enter WSL($distro) tmux. Run AI tools inside; phone mirrors live.")
      # set -e 下: powershell.exe 退出码非零 (即便 .lnk 创建成功也可能因 warning 非0)
      # 会触发 set -e 让整个 install.sh abort → 后面的 ask_yn 都跑不到
      # 用 || true 兜底, 避免 PowerShell 退出码副作用
      if powershell.exe -NoProfile -Command "
\$ws = New-Object -ComObject WScript.Shell
\$lnk = \$ws.CreateShortcut('C:\\Users\\$win_user\\Desktop\\AI Terminal.lnk')
\$lnk.TargetPath = 'C:\\Windows\\System32\\wsl.exe'
\$lnk.Arguments = '-d $distro -- $TMUX_CMD'
\$lnk.WorkingDirectory = '%USERPROFILE%'
\$lnk.IconLocation = 'C:\\Windows\\System32\\cmd.exe,0'
\$lnk.Description = '$desc'
\$lnk.Save()
" < /dev/null 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $(T "Windows 桌面快捷方式已创建 (WSL: $distro)" "Windows desktop shortcut created (WSL: $distro)")"
      else
        echo -e "${YELLOW}!${NC} $(T "Windows 桌面快捷方式创建失败 (PowerShell 错误)" "Windows desktop shortcut creation failed (PowerShell error)")"
      fi
      if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ]; then
        # 注意: set -e + `! grep -q` 在某些 bash 版本里会触发 abort (即便在 if condition 内)
        # 拆成显式 if/then 避免 ! 操作符
        if ! grep -q "aiterminal-tmux" "$SHELL_RC" 2>/dev/null; then
          echo "alias aiterminal-tmux='$TMUX_CMD'" >> "$SHELL_RC" || true
        fi
      fi
      return 0  # 强制 return 0, 防止 case 内最后命令非0让 set -e abort 主流程
      ;;
    linux)
      if [ "$HAS_DESKTOP" = true ]; then
        local appdir="$HOME/.local/share/applications"
        mkdir -p "$appdir"
        local term_cmd=""
        for t in gnome-terminal konsole xfce4-terminal mate-terminal lxterminal kitty alacritty wezterm xterm x-terminal-emulator; do
          if command -v "$t" >/dev/null 2>&1; then
            case $t in
              gnome-terminal|mate-terminal) term_cmd="$t -- bash -c '$TMUX_CMD'" ;;
              konsole|xfce4-terminal|lxterminal) term_cmd="$t -e bash -c '$TMUX_CMD; exec bash'" ;;
              kitty|alacritty|wezterm|xterm|x-terminal-emulator) term_cmd="$t -e bash -c '$TMUX_CMD'" ;;
            esac
            break
          fi
        done
        if [ -z "$term_cmd" ]; then
          echo -e "${YELLOW}!${NC} $(T '没找到已知终端模拟器, .desktop Exec 用 xterm 兜底' 'No known terminal emulator found, .desktop falls back to xterm')"
          term_cmd="xterm -e $TMUX_CMD"
        fi
        local comment
        comment=$(T '双击进 tmux,在里面跑 AI 工具(claude/cursor/aider 等),手机即可同步' \
                    'Double-click to enter tmux. Run AI tools (claude/cursor/aider) inside; phone mirrors live.')
        cat > "$appdir/aiterminal.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=AI Terminal
Comment=$comment
Exec=$term_cmd
Icon=utilities-terminal
Terminal=false
Categories=Development;TerminalEmulator;
EOF
        chmod +x "$appdir/aiterminal.desktop"
        update-desktop-database "$appdir" 2>/dev/null || true
        echo -e "${GREEN}✓${NC} $(T '应用菜单快捷方式:' 'Application menu shortcut:') ${BLUE}AI Terminal${NC}"
      else
        if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && ! grep -q "aiterminal-tmux" "$SHELL_RC"; then
          echo "" >> "$SHELL_RC"
          echo "# AI Terminal — quick tmux entry (run AI tools / shell, phone mirrors)" >> "$SHELL_RC"
          echo "alias aiterminal-tmux='$TMUX_CMD'" >> "$SHELL_RC"
          echo -e "${GREEN}✓${NC} $(T "shell alias 已加到 $SHELL_RC" "shell alias added to $SHELL_RC")"
          echo -e "  $(T "💡 重启 shell 或 ${BLUE}source $SHELL_RC${NC} 后, 敲 ${BLUE}aiterminal-tmux${NC} 进 tmux" "💡 Restart shell or ${BLUE}source $SHELL_RC${NC}, then run ${BLUE}aiterminal-tmux${NC} to enter tmux")"
        fi
      fi
      ;;
  esac
  return 0  # 兜底: 防 case 内任何命令 (尤其 grep 在 set -e 下) 让函数返回非0导致主流程 abort
}

PLATFORM=$OS
[ "$IS_WSL" = true ] && PLATFORM=wsl

# 默认直接生成快捷方式,不询问 (无害,不要可删)
OS=$PLATFORM make_shortcut

# 8.5 防火墙预授权 (避免 daemon 首次启动手机 LAN 配对扫不到)
# - Linux: ufw / firewalld 主动开 29876 (LAN proxy) + 29877 (HTTP)
# - macOS: socketfilterfw 加 node 二进制白名单 (App Firewall)
# - WSL: 跳过 (走 wsl2 nat, Windows 端 install.ps1 已开 firewall)
if [ "$PLATFORM" = "linux" ] && [ -t 1 ]; then
  if command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
    read -p "$(T '提前授权防火墙开 daemon 端口 (29876, 29877)? (Y/n) — 需要 sudo ' 'Pre-allow firewall for daemon ports (29876, 29877)? (Y/n) — needs sudo ')" -n 1 -r REPLY < /dev/tty || REPLY="y"
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow 29876/tcp comment 'AI Terminal daemon (LAN proxy)' >/dev/null 2>&1 \
          && sudo ufw allow 29877/tcp comment 'AI Terminal daemon (HTTP)' >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} $(T 'ufw 规则已加 (29876, 29877)' 'ufw rules added (29876, 29877)')" \
          || echo -e "${YELLOW}!${NC} $(T 'ufw 规则添加失败 (可能没 sudo)' 'ufw rule add failed (no sudo?)')"
      elif command -v firewall-cmd >/dev/null 2>&1; then
        sudo firewall-cmd --add-port=29876/tcp --permanent >/dev/null 2>&1 \
          && sudo firewall-cmd --add-port=29877/tcp --permanent >/dev/null 2>&1 \
          && sudo firewall-cmd --reload >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} $(T 'firewalld 规则已加' 'firewalld rules added')" \
          || echo -e "${YELLOW}!${NC} $(T 'firewalld 规则添加失败 (可能没 sudo)' 'firewalld rule add failed (no sudo?)')"
      fi
    fi
  fi
elif [ "$PLATFORM" = "macos" ] && [ -t 1 ]; then
  # macOS App Firewall: 给 node 二进制加 unblock 列表 + signing
  read -p "$(T '提前授权 macOS 防火墙放行 node? (Y/n) — 需要 sudo, 避免首次启动弹"允许网络连接"框 ' 'Pre-allow macOS firewall for node? (Y/n) — needs sudo, skips the first-run dialog ')" -n 1 -r REPLY < /dev/tty || REPLY="y"
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    NODE_BIN="$(command -v node)"
    if [ -n "$NODE_BIN" ]; then
      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$NODE_BIN" >/dev/null 2>&1 \
        && sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$NODE_BIN" >/dev/null 2>&1 \
        && echo -e "${GREEN}✓${NC} $(T "macOS 防火墙已放行 $NODE_BIN" "macOS firewall allowed $NODE_BIN")" \
        || echo -e "${YELLOW}!${NC} $(T '防火墙规则添加失败 (可能没 sudo)' 'Firewall rule add failed (no sudo?)')"
    fi
  fi
fi

# 8.6 开机自启 (Linux: systemd user; macOS: launchd; WSL: skip — Windows 已有)
if [ "$PLATFORM" != "wsl" ] && [ -t 1 ]; then
  read -p "$(T '开机自启 daemon? (Y/n) — 推荐 Y, 重启电脑后无需手动启动 ' 'Start daemon at boot? (Y/n) — recommended, no manual start after reboot ')" -n 1 -r REPLY < /dev/tty || REPLY="y"
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if "$BIN_DIR/aiterminal" enable-autostart 2>&1 | tail -5; then
      echo -e "${GREEN}✓${NC} $(T '开机自启已启用' 'Auto-start enabled')"
    else
      echo -e "${YELLOW}!${NC} $(T '开机自启设置失败 (手动: aiterminal enable-autostart)' 'Auto-start setup failed (run manually: aiterminal enable-autostart)')"
    fi
  fi
fi

# 9. 提示启动
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ $(T '安装完成' 'Install complete')${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  $(T 'daemon 命令:' 'daemon command:')  ${BLUE}aiterminal${NC}  $(T '(重启 shell 后)' '(after restarting shell)')"
echo ""

# prompt 辅助: stdin 是 tty 走交互, 否则 echo 提示 + 默认 Y
# (curl|bash 模式下 stdin 是 pipe, read < /dev/tty 也会失败因为没 controlling tty)
ask_yn() {
  local prompt_zh="$1"
  local prompt_en="$2"
  local default_y="${3:-y}"
  if [ -t 0 ]; then
    read -p "$(T "$prompt_zh" "$prompt_en")" -n 1 -r REPLY < /dev/tty || REPLY="$default_y"
    echo
  else
    echo -e "${BLUE}→${NC} $(T "$prompt_zh" "$prompt_en")$(T '[curl|bash 自动 Y]' '[curl|bash auto Y]')"
    REPLY="$default_y"
  fi
}

# 10. 自动启动 daemon
ask_yn '现在启动 daemon? (Y/n) ' 'Start daemon now? (Y/n) '
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  "$BIN_DIR/aiterminal" &
  DAEMON_PID=$!
  sleep 2
  echo -e "${GREEN}✓${NC} $(T 'daemon 已后台启动 (查看 QR: aiterminal stop && aiterminal)' 'daemon started in background (view QR: aiterminal stop && aiterminal)')"
fi

# 11. 立刻打开 tmux 窗口让用户开始用
ask_yn '现在直接打开 tmux 让你开始用? (Y/n) ' 'Open a tmux window now to get started? (Y/n) '
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    case $PLATFORM in
      macos)
        osascript -e "tell application \"Terminal\" to do script \"$TMUX_CMD\"" >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} $(T 'Terminal.app 已打开 tmux session' 'Opened tmux session in Terminal.app')"
        ;;
      wsl)
        WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}"
        cmd.exe /c "start cmd /k wsl -d $WSL_DISTRO -- $TMUX_CMD" < /dev/null >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} $(T '已打开 Windows cmd 窗口进入 WSL tmux' 'Opened Windows cmd window with WSL tmux')"
        ;;
      linux)
        if [ "$HAS_DESKTOP" = true ]; then
          for t in gnome-terminal konsole xfce4-terminal x-terminal-emulator xterm; do
            if command -v "$t" >/dev/null 2>&1; then
              case $t in
                gnome-terminal) setsid $t -- bash -c "$TMUX_CMD" >/dev/null 2>&1 & ;;
                *)              setsid $t -e "$TMUX_CMD" >/dev/null 2>&1 & ;;
              esac
              echo -e "${GREEN}✓${NC} $(T "已打开 $t 进入 tmux" "Opened $t with tmux")"
              break
            fi
          done
        else
          tmux new-session -d -s ai-terminal 2>/dev/null || true
          echo -e "${GREEN}✓${NC} $(T "tmux session 'ai-terminal' 已起 (detached)" "tmux session 'ai-terminal' started (detached)")"
          echo -e "  ${BLUE}tmux attach -t ai-terminal${NC}  $(T '进入' 'to attach')"
        fi
        ;;
    esac
    echo ""
    echo -e "  $(T "💡 在 tmux 里跑 ${BLUE}claude${NC} (或其他 AI CLI),手机扫码后自动同步看到" "💡 Run ${BLUE}claude${NC} (or any AI CLI) inside tmux. Once paired, phone mirrors live.")"
fi
