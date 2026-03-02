#!/usr/bin/env bash
# =============================================================================
# install.sh — restic-backup-deploy 服务端快速安装脚本
# 用法：curl -fsSL https://raw.githubusercontent.com/cdryzun/restic-backup-deploy/main/install.sh | bash
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

# ── 横幅 ──────────────────────────────────────────────────────────────────────
show_banner() {
  echo -e "${BOLD}${BLUE}"
  echo "  ╔═════════════════════════════════════════════════╗"
  echo "  ║   restic-backup-deploy 服务端安装脚本           ║"
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

  # 检查 docker
  if ! command -v docker &>/dev/null; then
    error "未找到 docker"
    echo ""
    echo "安装方法："
    echo "  Ubuntu/Debian: curl -fsSL https://get.docker.com | sh"
    echo "  CentOS/RHEL  : curl -fsSL https://get.docker.com | sh"
    echo "  macOS        : brew install docker"
    echo ""
    die "请先安装 Docker"
  fi

  # 检查 docker compose
  if ! docker compose version &>/dev/null; then
    die "未找到 docker compose v2，请升级 Docker 到最新版本"
  fi

  success "依赖检查通过"
}

# ── 下载工具 ──────────────────────────────────────────────────────────────────
download() {
  local url="$1" output="$2"

  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" -o "$output" ;;
    wget) wget -q "$url" -O "$output" ;;
  esac
}

# ── 选择安装目录 ──────────────────────────────────────────────────────────────
select_install_dir() {
  local default_dir="${1:-$PWD/restic-backup-deploy}"

  echo ""
  echo -e "${BOLD}请选择安装目录：${RESET}"
  echo "  默认: ${default_dir}"
  echo ""
  read -rp "安装目录 [回车使用默认]: " install_dir
  install_dir="${install_dir:-$default_dir}"

  # 转换为绝对路径
  install_dir="$(cd "$(dirname "$install_dir")" 2>/dev/null && pwd)/$(basename "$install_dir")" || {
    # 父目录不存在时，直接使用输入路径
    install_dir="$(cd "$PWD" && echo "$install_dir")"
  }

  echo ""
  info "安装目录: $install_dir"
}

# ── 下载文件 ──────────────────────────────────────────────────────────────────
download_files() {
  local install_dir="$1"

  info "创建目录结构..."
  mkdir -p "$install_dir"/{scripts,config,data,certs}

  info "下载必要文件..."
  cd "$install_dir"

  # 核心文件
  download "${BASE_URL}/docker-compose.yml" "docker-compose.yml"
  download "${BASE_URL}/.env.example" ".env.example"
  download "${BASE_URL}/.gitignore" ".gitignore"

  # 脚本
  download "${BASE_URL}/scripts/server.sh" "scripts/server.sh"
  chmod +x scripts/server.sh

  # 配置文件
  download "${BASE_URL}/config/prometheus.yml" "config/prometheus.yml"
  download "${BASE_URL}/config/metrics_password" "config/metrics_password"

  success "文件下载完成"
}

# ── 配置向导 ──────────────────────────────────────────────────────────────────
config_wizard() {
  local install_dir="$1"

  cd "$install_dir"

  echo ""
  echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}配置向导${RESET}"
  echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════${RESET}"
  echo ""

  # 复制配置文件
  if [[ ! -f .env ]]; then
    cp .env.example .env
    info "已创建 .env 配置文件"
  else
    warn ".env 已存在，跳过创建"
  fi

  echo ""
  echo -e "${BOLD}请配置以下选项：${RESET}"
  echo ""

  # 端口配置
  read -rp "rest-server 端口 [8000]: " restic_port
  restic_port="${restic_port:-8000}"

  # 安全选项
  echo ""
  echo -e "${BOLD}安全选项：${RESET}"
  echo "  1) 标准模式（允许备份和删除）"
  echo "  2) 仅追加模式（防止勒索软件删除备份，推荐）"
  echo ""
  read -rp "选择模式 [1-2，默认 1]: " mode_choice
  mode_choice="${mode_choice:-1}"

  local options="--prometheus"
  [[ "$mode_choice" == "2" ]] && options="--prometheus --append-only"

  # TLS 配置
  echo ""
  echo -e "${BOLD}TLS 配置：${RESET}"
  echo "  生产环境强烈建议启用 TLS"
  echo ""
  read -rp "是否启用 TLS？[y/N]: " enable_tls
  if [[ "$enable_tls" =~ ^[Yy]$ ]]; then
    options="$options --tls"
    warn "请手动将证书放置到 ${install_dir}/certs/ 目录："
    echo "  - certs/public_key   (TLS 证书)"
    echo "  - certs/private_key  (TLS 私钥)"
  fi

  # 更新 .env
  sed -i.bak \
    -e "s|^RESTIC_PORT=.*|RESTIC_PORT=${restic_port}|" \
    -e "s|^OPTIONS=.*|OPTIONS=${options}|" \
    .env && rm -f .env.bak

  success "配置已保存到 .env"
}

# ── 启动服务 ──────────────────────────────────────────────────────────────────
start_service() {
  local install_dir="$1"

  cd "$install_dir"

  echo ""
  echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}启动服务${RESET}"
  echo -e "${BOLD}${BLUE}═════════════════════════════════════════════════${RESET}"
  echo ""

  read -rp "是否立即启动 rest-server？[Y/n]: " start_now
  if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
    info "启动 rest-server..."
    ./scripts/server.sh up
    success "服务已启动"
  else
    info "稍后可运行以下命令启动服务："
    echo "  cd ${install_dir}"
    echo "  ./scripts/server.sh up"
  fi
}

# ── 添加用户 ──────────────────────────────────────────────────────────────────
add_user() {
  local install_dir="$1"

  cd "$install_dir"

  echo ""
  read -rp "是否立即添加备份用户？[Y/n]: " add_now
  if [[ ! "$add_now" =~ ^[Nn]$ ]]; then
    ./scripts/server.sh add-user
  else
    info "稍后可运行以下命令添加用户："
    echo "  cd ${install_dir}"
    echo "  ./scripts/server.sh add-user"
  fi
}

# ── 完成提示 ──────────────────────────────────────────────────────────────────
show_success() {
  local install_dir="$1"

  echo ""
  echo -e "${BOLD}${GREEN}═════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${GREEN}✓ 安装完成！${RESET}"
  echo -e "${BOLD}${GREEN}═════════════════════════════════════════════════${RESET}"
  echo ""
  echo -e "${BOLD}安装目录：${RESET} ${install_dir}"
  echo ""
  echo -e "${BOLD}常用命令：${RESET}"
  echo "  cd ${install_dir}"
  echo "  ./scripts/server.sh status       # 查看状态"
  echo "  ./scripts/server.sh logs         # 查看日志"
  echo "  ./scripts/server.sh add-user     # 添加用户"
  echo "  ./scripts/server.sh menu         # 交互菜单"
  echo ""
  echo -e "${BOLD}监控服务：${RESET}"
  echo "  ./scripts/server.sh up --with-monitoring  # 启动监控"
  echo ""
  echo -e "${BOLD}文档：${RESET}"
  echo "  https://github.com/${REPO}"
  echo ""
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  show_banner
  check_deps
  select_install_dir "$@"
  download_files "$install_dir"
  config_wizard "$install_dir"
  start_service "$install_dir"
  add_user "$install_dir"
  show_success "$install_dir"
}

main "$@"
