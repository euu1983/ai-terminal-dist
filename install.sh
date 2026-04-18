#!/usr/bin/env bash
# AI Terminal daemon installer (macOS / Linux / WSL)
# 用法: curl -fsSL https://dist.ai-terminal.org/install.sh | bash

set -e

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN="${AITERMINAL_DOMAIN:-dist.ai-terminal.org}"
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
      OS="wsl"; echo -e "${GREEN}✓${NC} 检测到 WSL2 环境"
    else
      OS="linux"; echo -e "${GREEN}✓${NC} 检测到 Linux"
    fi ;;
  Darwin*)
    OS="macos"; echo -e "${GREEN}✓${NC} 检测到 macOS" ;;
  *)
    echo -e "${RED}✗${NC} 不支持的系统: $(uname -s)"
    echo -e "  Windows 用户请用 PowerShell: ${BLUE}iwr -useb $DOMAIN/install.ps1 | iex${NC}"
    exit 1 ;;
esac

# 2. 检测 Node.js 18+
if ! command -v node >/dev/null 2>&1; then
  echo -e "${RED}✗${NC} 没有检测到 Node.js 18+"
  case $OS in
    macos)
      echo -e "  ${BLUE}brew install node${NC}  或  https://nodejs.org" ;;
    linux|wsl)
      echo -e "  Ubuntu/Debian: ${BLUE}curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs${NC}"
      echo -e "  或 nvm:        ${BLUE}curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash${NC}" ;;
  esac
  exit 1
fi
NODE_VERSION=$(node -v | sed 's/v//')
NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo -e "${RED}✗${NC} Node.js v$NODE_VERSION 过低 (需要 18+)"
  exit 1
fi
echo -e "${GREEN}✓${NC} Node.js v$NODE_VERSION"

# 3. 检测 tmux
if ! command -v tmux >/dev/null 2>&1; then
  echo -e "${YELLOW}!${NC} 缺少 tmux"
  case $OS in
    macos)    echo -e "  ${BLUE}brew install tmux${NC}" ;;
    linux|wsl) echo -e "  ${BLUE}sudo apt install -y tmux${NC}  或  ${BLUE}sudo dnf install -y tmux${NC}" ;;
  esac
  read -p "  装好 tmux 后再继续? 现在继续安装? (y/N) " -n 1 -r REPLY < /dev/tty || REPLY=""
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# 4. 下载 daemon bundle
mkdir -p "$BIN_DIR" "$PKG_DIR"
echo -e "${BLUE}→${NC} 下载 daemon..."
if ! curl -fsSL "https://${DOMAIN}/dist/aiterminal.js" -o "$BIN_DIR/aiterminal.js"; then
  echo -e "${RED}✗${NC} 下载失败 (https://${DOMAIN}/dist/aiterminal.js)"
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
echo -e "${GREEN}✓${NC} daemon 已下载到 $BIN_DIR"

# 5. 装 node-pty (用户本地编译/拉 prebuild)
echo -e "${BLUE}→${NC} 安装 node-pty (终端原生模块)..."
cd "$PKG_DIR"
if [ ! -f package.json ]; then
  cat > package.json <<EOF
{ "name": "aiterminal-pkg", "version": "1.0.0", "private": true }
EOF
fi
if npm install --no-save --silent node-pty@^1.1.0 2>/dev/null; then
  echo -e "${GREEN}✓${NC} node-pty 安装成功"
else
  echo -e "${YELLOW}!${NC} node-pty 安装失败 (Windows 系统会回退到 ConPTY,Linux/macOS 终端功能受限)"
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
  echo -e "${GREEN}✓${NC} 已添加 PATH 到 $SHELL_RC"
fi

# 7. 提示启动
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ 安装完成${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  启动:  ${BLUE}$BIN_DIR/aiterminal${NC}"
echo -e "  或重启 shell 后:  ${BLUE}aiterminal${NC}"
echo ""

# 8. 自动启动 (有 TTY 时)
if [ -t 1 ]; then
  read -p "现在启动? (Y/n) " -n 1 -r REPLY < /dev/tty || REPLY="y"
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    exec "$BIN_DIR/aiterminal"
  fi
fi
