#!/usr/bin/env bash
# AI Terminal daemon installer (macOS / Linux / WSL)
# Usage:
#   curl -fsSL https://dist.ai-terminal.org/install.sh | bash

# === stdin re-exec guard for curl|bash mode ===
# When run via curl|bash, bash's stdin is the curl pipe (= script content).
# Child processes (e.g. cmd.exe / powershell.exe under WSL) inherit that stdin
# and consume the rest of the script, causing bash to hit EOF early and skip
# later steps (daemon launch, tmux prompt). Workaround: detect non-tty stdin,
# dump it to a tmp file, then exec bash on that file — the new bash's stdin is
# no longer the script source, so the hazard goes away.
if [ ! -t 0 ] && [ -z "$_AITERMINAL_REEXEC" ]; then
  _TMP_INST=$(mktemp /tmp/aiterminal-install-XXXXXX.sh)
  cat > "$_TMP_INST"
  export _AITERMINAL_REEXEC=1
  exec bash "$_TMP_INST" "$@"
fi

set -e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Override with AITERMINAL_DOMAIN to point at a different CDN/mirror.
DEFAULT_DOMAIN='dist.ai-terminal.org'
DOMAIN="${AITERMINAL_DOMAIN:-$DEFAULT_DOMAIN}"
INSTALL_DIR="${AITERMINAL_HOME:-$HOME/.aiterminal}"
BIN_DIR="$INSTALL_DIR/bin"
PKG_DIR="$INSTALL_DIR/pkg"

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      AI Terminal Installer           ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

# 1. Detect OS
OS="unknown"
case "$(uname -s)" in
  Linux*)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      OS="wsl"; echo -e "${GREEN}✓${NC} Detected WSL2 environment"
    else
      OS="linux"; echo -e "${GREEN}✓${NC} Detected Linux"
    fi ;;
  Darwin*)
    OS="macos"; echo -e "${GREEN}✓${NC} Detected macOS" ;;
  *)
    echo -e "${RED}✗${NC} Unsupported system: $(uname -s)"
    echo -e "  For Windows, use PowerShell: ${BLUE}irm https://${DOMAIN}/install.ps1 | iex${NC}"
    exit 1 ;;
esac

# 2. Detect Node.js 18+
if ! command -v node >/dev/null 2>&1; then
  echo -e "${RED}✗${NC} Node.js 18+ not found"
  case $OS in
    macos)
      echo -e "  ${BLUE}brew install node${NC}  or  https://nodejs.org" ;;
    linux|wsl)
      echo -e "  Ubuntu/Debian: ${BLUE}curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs${NC}"
      echo -e "  or nvm:        ${BLUE}curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash${NC}" ;;
  esac
  exit 1
fi
NODE_VERSION=$(node -v | sed 's/v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo -e "${RED}✗${NC} Node.js v$NODE_VERSION too old (need 18+)"
  exit 1
fi
echo -e "${GREEN}✓${NC} Node.js v$NODE_VERSION"

# 3. Detect tmux + auto-install fallback (brew/apt/dnf/pacman/zypper/apk)
if ! command -v tmux >/dev/null 2>&1; then
  echo -e "${YELLOW}!${NC} tmux missing, trying to auto-install..."
  TMUX_INSTALLED=false
  case $OS in
    macos)
      if command -v brew >/dev/null 2>&1; then
        brew install tmux 2>&1 | tail -3 && TMUX_INSTALLED=true
      else
        echo -e "${YELLOW}!${NC} Homebrew not installed"
        echo -e "  Install: ${BLUE}/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"${NC}"
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
        echo -e "${YELLOW}!${NC} No known package manager detected"
      fi ;;
  esac
  if [ "$TMUX_INSTALLED" = true ] && command -v tmux >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} tmux $(tmux -V | awk '{print $2}')"
  else
    echo -e "${RED}✗${NC} tmux auto-install failed"
    case $OS in
      macos)    echo -e "  Install manually: ${BLUE}brew install tmux${NC}" ;;
      linux|wsl) echo -e "  Install manually: ${BLUE}sudo apt install -y tmux${NC} or your distro package manager" ;;
    esac
    read -p "  Install tmux first then re-run? Continue anyway? (y/N) " -n 1 -r REPLY < /dev/tty || REPLY=""
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
  fi
else
  echo -e "${GREEN}✓${NC} tmux $(tmux -V | awk '{print $2}')"
fi

# 4. Download daemon bundle
mkdir -p "$BIN_DIR" "$PKG_DIR"
echo -e "${BLUE}→${NC} Downloading daemon bundle..."
if ! curl -fsSL "https://${DOMAIN}/dist/aiterminal.js" -o "$BIN_DIR/aiterminal.js"; then
  echo -e "${RED}✗${NC} Download failed (https://${DOMAIN}/dist/aiterminal.js)"
  exit 1
fi
chmod +x "$BIN_DIR/aiterminal.js"

# Wrapper script (handles node-pty NODE_PATH)
cat > "$BIN_DIR/aiterminal" <<EOF
#!/bin/sh
export NODE_PATH="$PKG_DIR/node_modules:\${NODE_PATH:-}"
exec node "$BIN_DIR/aiterminal.js" "\$@"
EOF
chmod +x "$BIN_DIR/aiterminal"
echo -e "${GREEN}✓${NC} daemon downloaded to $BIN_DIR"

# 5. Install node-pty
echo -e "${BLUE}→${NC} Installing node-pty (terminal native module)..."
cd "$PKG_DIR"
if [ ! -f package.json ]; then
  cat > package.json <<EOF
{ "name": "aiterminal-pkg", "version": "1.0.0", "private": true }
EOF
fi
if npm install --no-save --silent node-pty@^1.1.0 2>/dev/null; then
  echo -e "${GREEN}✓${NC} node-pty installed"
else
  echo -e "${YELLOW}!${NC} node-pty install failed (terminal features will be limited)"
fi

# 6. Add to PATH
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
  echo -e "${GREEN}✓${NC} Added PATH to $SHELL_RC"
fi

# 7. Detect desktop environment / WSL (decides shortcut style)
HAS_DESKTOP=false
IS_WSL=false
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
  HAS_DESKTOP=true
fi
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=true
fi

# 8. Create shortcuts + tmux entry per platform
TMUX_CMD="tmux new-session -A -s ai-terminal"
make_shortcut() {
  case $OS in
    macos)
      mkdir -p "$HOME/Applications"
      local target="$HOME/Applications/AI Terminal.command"
      cat > "$target" <<EOF
#!/bin/bash
# Double-click to enter tmux. Run AI tools (claude/cursor/aider) inside; phone mirrors live.
$TMUX_CMD
EOF
      chmod +x "$target"
      xattr -d com.apple.quarantine "$target" 2>/dev/null || true
      echo -e "${GREEN}✓${NC} Shortcut: ${BLUE}~/Applications/AI Terminal.command${NC}"
      echo -e "    💡 Drag to Dock or search 'AI Terminal' in Spotlight to launch"
      ;;
    wsl)
      local win_user
      # < /dev/null: in curl|bash mode, bash reads install.sh from stdin and
      # cmd.exe / powershell.exe inherit that stdin by default — they would
      # consume the rest of the script and bash would hit EOF early.
      win_user=$(cmd.exe /c "echo %USERNAME%" < /dev/null 2>/dev/null | tr -d '\r\n')
      if [ -z "$win_user" ]; then
        echo -e "${YELLOW}!${NC} Cannot detect Windows username, skipping shortcut"
        return
      fi
      local desktop="/mnt/c/Users/$win_user/Desktop"
      if [ ! -d "$desktop" ]; then
        echo -e "${YELLOW}!${NC} Windows desktop not found: $desktop"
        return
      fi
      local distro="${WSL_DISTRO_NAME:-Ubuntu}"
      local desc="Double-click to enter WSL($distro) tmux. Run AI tools inside; phone mirrors live."
      # Under set -e, powershell.exe non-zero exit (even with successful .lnk
      # creation but a warning) would abort the rest of install.sh. Use || true
      # to avoid PowerShell exit-code side effects.
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
        echo -e "${GREEN}✓${NC} Windows desktop shortcut created (WSL: $distro)"
      else
        echo -e "${YELLOW}!${NC} Windows desktop shortcut creation failed (PowerShell error)"
      fi
      if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ]; then
        # Note: under set -e, `! grep -q` may abort in some bash versions even
        # inside an if condition. Use explicit if/then to avoid the ! operator.
        if ! grep -q "aiterminal-tmux" "$SHELL_RC" 2>/dev/null; then
          echo "alias aiterminal-tmux='$TMUX_CMD'" >> "$SHELL_RC" || true
        fi
      fi
      return 0  # force return 0 so case's last command non-zero doesn't abort main flow
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
          echo -e "${YELLOW}!${NC} No known terminal emulator found, .desktop falls back to xterm"
          term_cmd="xterm -e $TMUX_CMD"
        fi
        local comment="Double-click to enter tmux. Run AI tools (claude/cursor/aider) inside; phone mirrors live."
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
        echo -e "${GREEN}✓${NC} Application menu shortcut: ${BLUE}AI Terminal${NC}"
      else
        if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && ! grep -q "aiterminal-tmux" "$SHELL_RC"; then
          echo "" >> "$SHELL_RC"
          echo "# AI Terminal — quick tmux entry (run AI tools / shell, phone mirrors)" >> "$SHELL_RC"
          echo "alias aiterminal-tmux='$TMUX_CMD'" >> "$SHELL_RC"
          echo -e "${GREEN}✓${NC} shell alias added to $SHELL_RC"
          echo -e "  💡 Restart shell or ${BLUE}source $SHELL_RC${NC}, then run ${BLUE}aiterminal-tmux${NC} to enter tmux"
        fi
      fi
      ;;
  esac
  return 0  # safety: prevent any in-case command (esp. grep under set -e) from aborting main flow
}

PLATFORM=$OS
[ "$IS_WSL" = true ] && PLATFORM=wsl

# Always create shortcut (harmless, user can delete)
OS=$PLATFORM make_shortcut

# 8.5 Pre-authorize firewall (avoids first-run dialog when phone scans for daemon over LAN)
# - Linux: ufw / firewalld open 29876 (LAN proxy) + 29877 (HTTP)
# - macOS: socketfilterfw allowlist node binary (App Firewall)
# - WSL: skip (uses wsl2 NAT; install.ps1 already opens Windows firewall)
if [ "$PLATFORM" = "linux" ] && [ -t 1 ]; then
  if command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
    read -p "Pre-allow firewall for daemon ports (29876, 29877)? (Y/n) — needs sudo " -n 1 -r REPLY < /dev/tty || REPLY="y"
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
      if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow 29876/tcp comment 'AI Terminal daemon (LAN proxy)' >/dev/null 2>&1 \
          && sudo ufw allow 29877/tcp comment 'AI Terminal daemon (HTTP)' >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} ufw rules added (29876, 29877)" \
          || echo -e "${YELLOW}!${NC} ufw rule add failed (no sudo?)"
      elif command -v firewall-cmd >/dev/null 2>&1; then
        sudo firewall-cmd --add-port=29876/tcp --permanent >/dev/null 2>&1 \
          && sudo firewall-cmd --add-port=29877/tcp --permanent >/dev/null 2>&1 \
          && sudo firewall-cmd --reload >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} firewalld rules added" \
          || echo -e "${YELLOW}!${NC} firewalld rule add failed (no sudo?)"
      fi
    fi
  fi
elif [ "$PLATFORM" = "macos" ] && [ -t 1 ]; then
  # macOS App Firewall: add node binary to unblock list + signing
  read -p "Pre-allow macOS firewall for node? (Y/n) — needs sudo, skips the first-run dialog " -n 1 -r REPLY < /dev/tty || REPLY="y"
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    NODE_BIN="$(command -v node)"
    if [ -n "$NODE_BIN" ]; then
      sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$NODE_BIN" >/dev/null 2>&1 \
        && sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$NODE_BIN" >/dev/null 2>&1 \
        && echo -e "${GREEN}✓${NC} macOS firewall allowed $NODE_BIN" \
        || echo -e "${YELLOW}!${NC} Firewall rule add failed (no sudo?)"
    fi
  fi
fi

# 8.6 Auto-start at boot (Linux: systemd user; macOS: launchd; WSL: skip — Windows side handles this)
if [ "$PLATFORM" != "wsl" ] && [ -t 1 ]; then
  read -p "Start daemon at boot? (Y/n) — recommended, no manual start after reboot " -n 1 -r REPLY < /dev/tty || REPLY="y"
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if "$BIN_DIR/aiterminal" enable-autostart 2>&1 | tail -5; then
      echo -e "${GREEN}✓${NC} Auto-start enabled"
    else
      echo -e "${YELLOW}!${NC} Auto-start setup failed (run manually: aiterminal enable-autostart)"
    fi
  fi
fi

# 9. Done banner
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Install complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  daemon command:  ${BLUE}aiterminal${NC}  (after restarting shell)"
echo ""

# Prompt helper: tty stdin → interactive read; otherwise echo + default Y
# (under curl|bash, stdin is a pipe; read < /dev/tty also fails because there is no controlling tty)
ask_yn() {
  local prompt="$1"
  local default_y="${2:-y}"
  if [ -t 0 ]; then
    read -p "$prompt" -n 1 -r REPLY < /dev/tty || REPLY="$default_y"
    echo
  else
    echo -e "${BLUE}→${NC} ${prompt}[curl|bash auto Y]"
    REPLY="$default_y"
  fi
}

# 10. Auto-start daemon
ask_yn 'Start daemon now? (Y/n) '
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  "$BIN_DIR/aiterminal" &
  DAEMON_PID=$!
  sleep 2
  echo -e "${GREEN}✓${NC} daemon started in background (view QR: aiterminal stop && aiterminal)"
fi

# 11. Open a tmux window so user can start using it immediately
ask_yn 'Open a tmux window now to get started? (Y/n) '
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    case $PLATFORM in
      macos)
        osascript -e "tell application \"Terminal\" to do script \"$TMUX_CMD\"" >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} Opened tmux session in Terminal.app"
        ;;
      wsl)
        WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}"
        cmd.exe /c "start cmd /k wsl -d $WSL_DISTRO -- $TMUX_CMD" < /dev/null >/dev/null 2>&1 \
          && echo -e "${GREEN}✓${NC} Opened Windows cmd window with WSL tmux"
        ;;
      linux)
        if [ "$HAS_DESKTOP" = true ]; then
          for t in gnome-terminal konsole xfce4-terminal x-terminal-emulator xterm; do
            if command -v "$t" >/dev/null 2>&1; then
              case $t in
                gnome-terminal) setsid $t -- bash -c "$TMUX_CMD" >/dev/null 2>&1 & ;;
                *)              setsid $t -e "$TMUX_CMD" >/dev/null 2>&1 & ;;
              esac
              echo -e "${GREEN}✓${NC} Opened $t with tmux"
              break
            fi
          done
        else
          tmux new-session -d -s ai-terminal 2>/dev/null || true
          echo -e "${GREEN}✓${NC} tmux session 'ai-terminal' started (detached)"
          echo -e "  ${BLUE}tmux attach -t ai-terminal${NC}  to attach"
        fi
        ;;
    esac
    echo ""
    echo -e "  💡 Run ${BLUE}claude${NC} (or any AI CLI) inside tmux. Once paired, phone mirrors live."
fi
