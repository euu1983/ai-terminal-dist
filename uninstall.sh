#!/usr/bin/env bash
# AI Terminal daemon uninstaller (macOS / Linux / WSL)
# Usage:
#   curl -fsSL https://get.ai-terminal.org/uninstall.sh | bash
#   AITERMINAL_FORCE=1 curl ... | bash    # 跳过确认 (CI / 自动化)

# === stdin re-exec guard (curl|bash 模式) ===
# 跟 install.sh 同款: curl|bash 时 bash stdin = pipe (script 内容), 不是终端,
# 'read -p ... < /dev/tty' 在某些环境 (Windows cmd 调 WSL bash 等) 仍不通.
# 解决: 检测 stdin 不是 tty 时, dump script 到 tmp 再 exec 跑, 让新 bash 的
# stdin = 终端, read prompt 才能交互.
if [ ! -t 0 ] && [ -z "$_AITERMINAL_UNINSTALL_REEXEC" ]; then
  rm -f /tmp/aiterminal-uninstall-*.sh 2>/dev/null
  _TMP_UN=/tmp/aiterminal-uninstall-$$-$RANDOM.sh
  trap 'rm -f "$_TMP_UN"' EXIT
  if ! cat > "$_TMP_UN"; then
    echo "Uninstaller: failed to write $_TMP_UN" >&2
    exit 1
  fi
  export _AITERMINAL_UNINSTALL_REEXEC=1
  exec bash "$_TMP_UN" "$@"
fi

set +e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="${AITERMINAL_HOME:-$HOME/.aiterminal}"
BIN_DIR="$INSTALL_DIR/bin"

# Detect OS (decides launchd / systemd removal + desktop shortcut path)
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
echo -e "Will remove:"
echo -e "  • $INSTALL_DIR  (daemon + node-pty)"
echo -e "  • PATH line in shell rc"
echo -e "  • Auto-start (systemd user / launchd)"
echo -e "  • Desktop / app menu shortcuts"
echo -e "  • Firewall rules (29876/29877 in ufw/firewalld)"
echo ""
echo -e "${YELLOW}Will keep:${NC}"
echo -e "  • Node.js / tmux (may be used by other apps)"
echo -e "  • Received files (under ~/Documents, not install dir)"
echo ""

# 2026-05-07: 加 AITERMINAL_FORCE=1 跳过 prompt 兜底 (CI / 自动化 / 极少环境
# /dev/tty 不通的 fallback). 加 stdin tty 检测, 非 tty 时不 read, 直接退 cancel
# 让用户用 FORCE env 显式同意, 不会无故卸载.
if [ "${AITERMINAL_FORCE:-0}" = "1" ]; then
  echo -e "${YELLOW}[AITERMINAL_FORCE=1] 跳过确认, 强制卸载${NC}"
  REPLY="y"
elif [ -t 0 ]; then
  read -p "Confirm uninstall? (y/N) " -n 1 -r REPLY < /dev/tty || REPLY=""
  echo
else
  echo -e "${RED}非交互环境 (curl|bash 等 stdin 不是 tty), 无法读 y/N 确认.${NC}"
  echo -e "请用以下任一方式:"
  echo -e "  1. 重新跑加 ${YELLOW}AITERMINAL_FORCE=1${NC}: AITERMINAL_FORCE=1 curl ... | bash"
  echo -e "  2. 下载到本地再跑: curl ... -o /tmp/un.sh && bash /tmp/un.sh"
  exit 1
fi
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "Cancelled"
  exit 0
fi

# 1. Stop running daemon
echo -e "${BLUE}→${NC} Stopping daemon..."
if [ -x "$BIN_DIR/aiterminal" ]; then
  "$BIN_DIR/aiterminal" stop 2>/dev/null || true
fi
# Fallback: pgrep+kill
pkill -f 'aiterminal\.js' 2>/dev/null || true
echo -e "${GREEN}✓${NC} daemon stopped"

# 2. Disable auto-start
echo -e "${BLUE}→${NC} Disabling auto-start..."
case $OS in
  macos)
    # cli.js enableAutostart writes to this plist (must stay in sync with cli.js src)
    plist="$HOME/Library/LaunchAgents/com.openclaw.aiterminal.plist"
    if [ -f "$plist" ]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      echo -e "${GREEN}✓${NC} Removed launchd plist"
    fi ;;
  linux|wsl)
    # cli.js enableAutostart writes aiterminal.service (must stay in sync with cli.js src)
    unit="$HOME/.config/systemd/user/aiterminal.service"
    if [ -f "$unit" ]; then
      systemctl --user disable --now aiterminal.service 2>/dev/null || true
      rm -f "$unit"
      systemctl --user daemon-reload 2>/dev/null || true
      echo -e "${GREEN}✓${NC} Removed systemd user unit"
    fi ;;
esac

# 3. Remove shortcuts
case $OS in
  macos)
    rm -f "$HOME/Applications/AI Terminal.command" 2>/dev/null && \
      echo -e "${GREEN}✓${NC} Removed: ~/Applications/AI Terminal.command" ;;
  wsl)
    win_user=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
    if [ -n "$win_user" ]; then
      rm -f "/mnt/c/Users/$win_user/Desktop/AI Terminal.lnk" 2>/dev/null && \
        echo -e "${GREEN}✓${NC} Windows desktop shortcut removed"
    fi ;;
  linux)
    rm -f "$HOME/.local/share/applications/aiterminal.desktop" 2>/dev/null && \
      echo -e "${GREEN}✓${NC} Removed .desktop" ;;
esac

# 4. Remove PATH + alias from shell rc files
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.config/fish/config.fish"; do
  [ ! -f "$rc" ] && continue
  if grep -qE "(\.aiterminal/bin|aiterminal-tmux|^# AI Terminal)" "$rc"; then
    # Backup before editing
    cp "$rc" "$rc.aiterminal.bak"
    # Drop "# AI Terminal" comment + next two lines (PATH + alias)
    sed -i.tmp -e '/^# AI Terminal/,+2d' -e '/aiterminal\/bin/d' -e '/aiterminal-tmux/d' "$rc"
    rm -f "$rc.tmp"
    echo -e "${GREEN}✓${NC} PATH/alias removed from $rc (backup: $rc.aiterminal.bak)"
  fi
done

# 5. Firewall rules
case $OS in
  linux|wsl)
    if command -v ufw >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo ufw delete allow 29876/tcp 2>/dev/null || true
      sudo ufw delete allow 29877/tcp 2>/dev/null || true
      echo -e "${GREEN}✓${NC} ufw rules removed (29876, 29877)"
    elif command -v firewall-cmd >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo firewall-cmd --remove-port=29876/tcp --permanent 2>/dev/null || true
      sudo firewall-cmd --remove-port=29877/tcp --permanent 2>/dev/null || true
      sudo firewall-cmd --reload 2>/dev/null || true
      echo -e "${GREEN}✓${NC} firewalld rules removed"
    else
      echo -e "${YELLOW}!${NC} ufw/firewalld not enabled or no sudo, skipped"
    fi ;;
  macos)
    # macOS Application Firewall rules use socketfilterfw, but install didn't add them, so nothing to remove
    : ;;
esac

# 6. Remove install dir
if [ -d "$INSTALL_DIR" ]; then
  echo -e "${BLUE}→${NC} Removing $INSTALL_DIR ..."
  rm -rf "$INSTALL_DIR"
  if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}!${NC} Some files may be locked, remove manually"
  else
    echo -e "${GREEN}✓${NC} Removed $INSTALL_DIR"
  fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Uninstall complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Restart your shell for PATH changes"
