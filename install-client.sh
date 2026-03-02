#!/usr/bin/env bash
# =============================================================================
# install-client.sh — restic-backup-deploy 客户端快速安装脚本
# 用法：curl -fsSL https://raw.githubusercontent.com/cdryzun/restic-backup-deploy/main/install-client.sh | bash
# =============================================================================
set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────────────────────────
REPO="cdryzun/restic-backup-deploy"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
die()     { error "$*"; exit 1; }

# ── 交互输入（支持管道执行）──────────────────────────────────────────────────
ask() {
  local prompt="$1"
  local var="$2"

  if [[ -t 0 ]]; then
    # 标准终端输入（-e 启用 readline，支持退格/方向键）
    read -e -rp "$prompt" "$var"
  else
    # 管道执行时从 /dev/tty 读取
    read -e -rp "$prompt" "$var" </dev/tty
  fi
}

# ── 横幅 ──────────────────────────────────────────────────────────────────────
show_banner() {
  echo -e "${BOLD}${BLUE}"
  echo "  ╔═════════════════════════════════════════════════╗"
  echo "  ║   restic-backup-deploy 客户端安装脚本           ║"
  echo "  ╚═════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ── 依赖检查 ──────────────────────────────────────────────────────────────────
check_deps() {
  info "检查依赖..."

  # 检查 curl 或 wget
  if command -v curl &>/dev/null; then
    DOWNLOADER="curl"
  elif command -v wget &>/dev/null; then
    DOWNLOADER="wget"
  else
    die "需要 curl 或 wget，请先安装其中之一"
  fi

  # 检查 restic
  if ! command -v restic &>/dev/null; then
    error "未找到 restic"
    echo ""
    echo "安装方法："
    echo "  Ubuntu/Debian: sudo apt install restic"
    echo "  CentOS/RHEL  : sudo yum install restic"
    echo "  macOS        : brew install restic"
    echo "  其他         : https://restic.net/downloads/"
    echo ""

    ask "是否自动安装 restic？[y/N]: " auto_install
    if [[ "$auto_install" =~ ^[Yy]$ ]]; then
      install_restic
    else
      die "请先安装 restic"
    fi
  else
    local ver
    ver=$(restic version 2>&1 | head -1)
    success "restic 已安装: $ver"
  fi
}

# ── 安装 restic ───────────────────────────────────────────────────────────────
install_restic() {
  info "自动安装 restic..."

  local os arch url latest_url

  # 检测操作系统
  case "$(uname -s)" in
    Linux*)  os="linux" ;;
    Darwin*) os="darwin" ;;
    *)       die "不支持的操作系统: $(uname -s)" ;;
  esac

  # 检测架构
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armhf)  arch="arm" ;;
    *)             die "不支持的架构: $(uname -m)" ;;
  esac

  # 获取最新版本（兼容 macOS）
  info "获取最新版本..."
  local version
  if [[ "$DOWNLOADER" == "curl" ]]; then
    version=$(curl -fsSL -o /dev/null -w "%{url_effective}" "$latest_url" | sed 's|.*/tag/v||')
  else
    version=$(wget -qO- "$latest_url" 2>&1 | grep -o 'tag/v[0-9.]*' | head -1 | sed 's|tag/v||')
  fi

  if [[ -z "$version" ]]; then
    warn "无法获取最新版本，使用 0.17.3"
    version="0.17.3"
  fi

  local download_url="https://github.com/restic/restic/releases/download/v${version}/restic_${version}_${os}_${arch}.bz2"

  info "下载 restic v${version} (${os}/${arch})..."
  local tmp_file="/tmp/restic.bz2"

  case "$DOWNLOADER" in
    curl) curl -fSL "$download_url" -o "$tmp_file" ;;
    wget) wget -q "$download_url" -O "$tmp_file" ;;
  esac

  # 解压并安装
  info "安装 restic..."
  bunzip2 -f "$tmp_file"
  sudo mv /tmp/restic /usr/local/bin/restic
  sudo chmod +x /usr/local/bin/restic

  success "restic 安装完成: $(restic version | head -1)"
}

# ── 下载工具 ──────────────────────────────────────────────────────────────────
download() {
  local url="$1" output="$2"

  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" -o "$output" ;;
    wget) wget -q "$url" -O "$output" ;;
  esac
}

# ── 选择安装方式 ──────────────────────────────────────────────────────────────
select_install_method() {
  echo ""
  echo -e "${BOLD}请选择安装方式：${RESET}"
  echo ""
  echo "  1) 系统级安装（推荐）"
  echo "     安装到: /usr/local/bin/restic-backup"
  echo "     所有用户可用"
  echo ""
  echo "  2) 用户级安装"
  echo "     安装到: ~/bin/restic-backup"
  echo "     仅当前用户可用"
  echo ""
  echo "  3) 当前目录"
  echo "     安装到: $(pwd)/client.sh"
  echo "     便携式，适合临时使用"
  echo ""

  ask "选择 [1-3，默认 1]: " method
  method="${method:-1}"

  case "$method" in
    1)
      INSTALL_DIR="/usr/local/bin"
      SCRIPT_NAME="restic-backup"
      NEED_SUDO=1
      ;;
    2)
      INSTALL_DIR="$HOME/bin"
      SCRIPT_NAME="restic-backup"
      NEED_SUDO=0
      mkdir -p "$INSTALL_DIR"
      ;;
    3)
      INSTALL_DIR="$PWD"
      SCRIPT_NAME="client.sh"
      NEED_SUDO=0
      ;;
    *)
      die "无效选择"
      ;;
  esac

  INSTALL_PATH="${INSTALL_DIR}/${SCRIPT_NAME}"
}

# ── 下载脚本 ──────────────────────────────────────────────────────────────────
download_script() {
  info "下载 client.sh..."

  local tmp_file="/tmp/restic-backup-client.sh"
  download "${BASE_URL}/scripts/client.sh" "$tmp_file"

  if [[ "$NEED_SUDO" == "1" ]]; then
    sudo mv "$tmp_file" "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"
  else
    mv "$tmp_file" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
  fi

  success "脚本已安装到: ${INSTALL_PATH}"
}

# ── 配置向导 ──────────────────────────────────────────────────────────────────
config_wizard() {
  echo ""
  echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}配置向导（可选）${RESET}"
  echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════${RESET}"
  echo ""

  ask "是否立即配置备份仓库？[Y/n]: " do_config
  if [[ "$do_config" =~ ^[Nn]$ ]]; then
    return
  fi

  echo ""
  ask "服务端地址 (如 http://backup.example.com:8000): " server_url
  ask "用户名: " username

  # HTTP 密码隐藏输入
  echo -n "HTTP 密码: "
  if [[ -t 0 ]]; then
    read -e -s http_password
  else
    read -e -s http_password </dev/tty
  fi
  echo ""

  ask "仓库名称 (如 myrepo): " repo_path

  # 仓库加密密码隐藏输入
  echo -n "仓库加密密码: "
  if [[ -t 0 ]]; then
    read -e -s repo_password
  else
    read -e -s repo_password </dev/tty
  fi
  echo ""

  echo ""
  info "测试连接..."
  # 只测试服务端是否可达，不测试仓库是否存在（初始化前仓库不存在）
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    -u "${username}:${http_password}" "${server_url%/}/" 2>&1) || true

  case "$http_code" in
    200|401|403)
      success "服务端连接正常 (HTTP $http_code)"
      ;;
    404)
      success "服务端连接正常，仓库不存在（稍后将初始化）"
      ;;
    000)
      warn "无法连接到服务端，请检查地址和网络"
      ;;
    *)
      warn "服务端返回异常状态码: HTTP $http_code"
      ;;
  esac

  echo ""
  ask "是否初始化仓库？[Y/n]: " do_init
  if [[ ! "$do_init" =~ ^[Nn]$ ]]; then
    "${INSTALL_PATH}" init \
      --server-url "$server_url" \
      --username "$username" \
      --http-password "$http_password" \
      --repo-path "$repo_path" \
      --repo-password "$repo_password" \
      --yes
  fi
}

# ── 完成提示 ──────────────────────────────────────────────────────────────────
show_success() {
  echo ""
  echo -e "${BOLD}${GREEN}═════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}✓ 安装完成！${RESET}"
  echo -e "${BOLD}${GREEN}═════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "${BOLD}安装位置：${RESET} ${INSTALL_PATH}"
  echo ""

  if [[ "$NEED_SUDO" != "1" ]] && [[ "$INSTALL_DIR" == "$HOME/bin" ]]; then
    if ! echo "$PATH" | grep -q "$HOME/bin"; then
      warn "请将以下内容添加到 ~/.bashrc 或 ~/.zshrc："
      echo '  export PATH="$HOME/bin:$PATH"'
      echo ""
    fi
  fi

  echo -e "${BOLD}常用命令：${RESET}"
  echo "  ${INSTALL_PATH}              # 交互菜单"
  echo "  ${INSTALL_PATH} backup --path /data  # 执行备份"
  echo "  ${INSTALL_PATH} snapshots            # 查看快照"
  echo "  ${INSTALL_PATH} help                 # 帮助信息"
  echo ""
  echo -e "${BOLD}文档：${RESET}"
  echo "  https://github.com/${REPO}"
  echo ""
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  show_banner
  check_deps
  select_install_method
  download_script
  config_wizard
  show_success
}

main "$@"
