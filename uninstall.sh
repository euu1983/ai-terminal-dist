#!/usr/bin/env bash
# AI Terminal daemon uninstaller (macOS / Linux / WSL)
# Usage / 用法:
#   curl -fsSL https://dist.ai-terminal.org/uninstall.sh | bash
#   curl -fsSL https://ai-terminal.cn/uninstall.sh       | bash   # 国内

set +e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# i18n
LANG_PREFIX="${AITERMINAL_LANG:-${LC_ALL:-${LANG:-en}}}"
LANG_PREFIX="${LANG_PREFIX:0:2}"
case "$LANG_PREFIX" in zh|ZH) IS_ZH=true ;; *) IS_ZH=false ;; esac
T() { if [ "$IS_ZH" = true ]; then echo "$1"; else echo "$2"; fi }

INSTALL_DIR="${AITERMINAL_HOME:-$HOME/.aiterminal}"
BIN_DIR="$INSTALL_DIR/bin"

# 检测 OS (用于决定 launchd / systemd 删法 + 桌面快捷方式删法)
OS="unknown"
case "$(uname -s)" in
  Darwin*) OS="macos" ;;
  Linux*)
    if grep -qi microsoft /proc/version 2>/dev/null; then OS="wsl"; else OS="linux"; fi ;;
esac

echo -e "${YELLOW}╔══════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   AI Terminal Uninstaller            ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "$(T '将清除:' 'Will remove:')"
echo -e "  • $INSTALL_DIR  $(T '(daemon + node-pty)' '(daemon + node-pty)')"
echo -e "  $(T '• shell rc 中的 PATH 行' '• PATH line in shell rc')"
echo -e "  $(T '• 开机自启 (systemd user / launchd)' '• Auto-start (systemd user / launchd)')"
echo -e "  $(T '• 桌面 / 应用菜单快捷方式' '• Desktop / app menu shortcuts')"
echo -e "  $(T '• 防火墙规则 (ufw/firewalld 中的 29876/29877)' '• Firewall rules (29876/29877 in ufw/firewalld)')"
echo ""
echo -e "${YELLOW}$(T '保留:' 'Will keep:')${NC}"
echo -e "  $(T '• Node.js / tmux (用户可能给别的程序用)' '• Node.js / tmux (may be used by other apps)')"
echo -e "  $(T '• 接收过的文件 (~/Documents 等不在 install 路径下)' '• Received files (under ~/Documents, not install dir)')"
echo ""

read -p "$(T '确认卸载? (y/N) ' 'Confirm uninstall? (y/N) ')" -n 1 -r REPLY < /dev/tty || REPLY=""
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "$(T '已取消' 'Cancelled')"
  exit 0
fi

# 1. 关掉跑着的 daemon
echo -e "${BLUE}→${NC} $(T '停止 daemon...' 'Stopping daemon...')"
if [ -x "$BIN_DIR/aiterminal" ]; then
  "$BIN_DIR/aiterminal" stop 2>/dev/null || true
fi
# 兜底: pgrep+kill
pkill -f 'aiterminal\.js' 2>/dev/null || true
echo -e "${GREEN}✓${NC} $(T 'daemon 已停' 'daemon stopped')"

# 2. 关掉自启
echo -e "${BLUE}→${NC} $(T '禁用开机自启...' 'Disabling auto-start...')"
case $OS in
  macos)
    # cli.js enableAutostart 写到这个 plist (与 cli.js src 严格保持一致)
    plist="$HOME/Library/LaunchAgents/com.openclaw.aiterminal.plist"
    if [ -f "$plist" ]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      echo -e "${GREEN}✓${NC} $(T '已删 launchd plist' 'Removed launchd plist')"
    fi ;;
  linux|wsl)
    # cli.js enableAutostart 写到 aiterminal.service (与 cli.js src 严格保持一致)
    unit="$HOME/.config/systemd/user/aiterminal.service"
    if [ -f "$unit" ]; then
      systemctl --user disable --now aiterminal.service 2>/dev/null || true
      rm -f "$unit"
      systemctl --user daemon-reload 2>/dev/null || true
      echo -e "${GREEN}✓${NC} $(T '已删 systemd user unit' 'Removed systemd user unit')"
    fi ;;
esac

# 3. 删快捷方式
case $OS in
  macos)
    rm -f "$HOME/Applications/AI Terminal.command" 2>/dev/null && \
      echo -e "${GREEN}✓${NC} $(T '已删: ~/Applications/AI Terminal.command' 'Removed: ~/Applications/AI Terminal.command')" ;;
  wsl)
    win_user=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
    if [ -n "$win_user" ]; then
      rm -f "/mnt/c/Users/$win_user/Desktop/AI Terminal.lnk" 2>/dev/null && \
        echo -e "${GREEN}✓${NC} $(T 'Windows 桌面快捷方式已删' 'Windows desktop shortcut removed')"
    fi ;;
  linux)
    rm -f "$HOME/.local/share/applications/aiterminal.desktop" 2>/dev/null && \
      echo -e "${GREEN}✓${NC} $(T '已删 .desktop' 'Removed .desktop')" ;;
esac

# 4. 从 shell rc 中移除 PATH + alias
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
  [ ! -f "$rc" ] && continue
  if grep -qE "(\.aiterminal/bin|aiterminal-tmux|^# AI Terminal)" "$rc"; then
    # 备份再清
    cp "$rc" "$rc.aiterminal.bak"
    # 删 # AI Terminal 注释 + 它后两行 (PATH + alias)
    sed -i.tmp -e '/^# AI Terminal/,+2d' -e '/aiterminal\/bin/d' -e '/aiterminal-tmux/d' "$rc"
    rm -f "$rc.tmp"
    echo -e "${GREEN}✓${NC} $(T "PATH/alias 已从 $rc 移除 (备份: $rc.aiterminal.bak)" "PATH/alias removed from $rc (backup: $rc.aiterminal.bak)")"
  fi
done

# 5. 防火墙规则
case $OS in
  linux|wsl)
    if command -v ufw >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo ufw delete allow 29876/tcp 2>/dev/null || true
      sudo ufw delete allow 29877/tcp 2>/dev/null || true
      echo -e "${GREEN}✓${NC} $(T 'ufw 规则已删 (29876, 29877)' 'ufw rules removed (29876, 29877)')"
    elif command -v firewall-cmd >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo firewall-cmd --remove-port=29876/tcp --permanent 2>/dev/null || true
      sudo firewall-cmd --remove-port=29877/tcp --permanent 2>/dev/null || true
      sudo firewall-cmd --reload 2>/dev/null || true
      echo -e "${GREEN}✓${NC} $(T 'firewalld 规则已删' 'firewalld rules removed')"
    else
      echo -e "${YELLOW}!${NC} $(T 'ufw/firewalld 未启用或无 sudo, 跳过' 'ufw/firewalld not enabled or no sudo, skipped')"
    fi ;;
  macos)
    # macOS Application Firewall 规则用 socketfilterfw, 但 install 没加, uninstall 也无需删
    : ;;
esac

# 6. 删 install dir
if [ -d "$INSTALL_DIR" ]; then
  echo -e "${BLUE}→${NC} $(T "删除 $INSTALL_DIR ..." "Removing $INSTALL_DIR ...")"
  rm -rf "$INSTALL_DIR"
  if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}!${NC} $(T '部分文件可能被占用, 手动删' 'Some files may be locked, remove manually')"
  else
    echo -e "${GREEN}✓${NC} $(T "已删 $INSTALL_DIR" "Removed $INSTALL_DIR")"
  fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ $(T '卸载完成' 'Uninstall complete')${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "$(T '重启 shell 让 PATH 改动生效' 'Restart your shell for PATH changes')"
