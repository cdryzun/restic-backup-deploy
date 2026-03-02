#!/usr/bin/env bash
# =============================================================================
# server.sh — restic-backup-deploy 服务端管理脚本
# 用法：./scripts/server.sh [命令] [选项]  或直接运行进入交互菜单
# 支持非交互式模式：通过命令行参数传入配置，跳过所有交互提示
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
CONTAINER="restic-rest-server"

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERR]${RESET}  $*" >&2; }
die()     { error "$*"; exit 1; }

# ── 前置检查 ──────────────────────────────────────────────────────────────────
check_deps() {
  command -v docker &>/dev/null || die "未找到 docker，请先安装"
  docker compose version &>/dev/null || die "未找到 docker compose v2，请升级 Docker"
}

check_running() {
  docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
    || die "容器 ${CONTAINER} 未运行，请先执行：docker compose up -d"
}

# ── 核心函数 ──────────────────────────────────────────────────────────────────

# 启动服务
cmd_up() {
  local with_monitoring=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-monitoring) with_monitoring=1; shift ;;
      *) warn "up: 未知参数 $1，已忽略"; shift ;;
    esac
  done

  cd "$PROJECT_DIR"
  [[ -f .env ]] || { warn ".env 不存在，从 .env.example 复制"; cp .env.example .env; }

  if [[ "$with_monitoring" == "1" ]]; then
    info "启动所有服务（含监控）..."
    docker compose --profile monitoring up -d
  else
    info "启动 rest-server（不含监控，使用 --with-monitoring 启动监控）..."
    docker compose up -d
  fi

  success "服务已启动"
  cmd_status
}

# 停止服务
cmd_down() {
  info "停止所有服务..."
  cd "$PROJECT_DIR"
  docker compose down
  success "服务已停止"
}

# 重启服务
cmd_restart() {
  info "重启 rest-server..."
  cd "$PROJECT_DIR"
  docker compose restart rest-server
  success "重启完成"
}

# 显示容器状态
cmd_status() {
  echo ""
  echo -e "${BOLD}── 容器状态 ─────────────────────────────${RESET}"
  cd "$PROJECT_DIR"
  docker compose ps
  echo ""
}

# 查看日志
cmd_logs() {
  local lines="${1:-50}"
  check_running
  info "显示最近 ${lines} 行日志（Ctrl+C 退出）..."
  docker logs -f --tail="$lines" "$CONTAINER"
}

# 列出所有用户
cmd_list_users() {
  check_running
  echo ""
  echo -e "${BOLD}── htpasswd 用户列表 ────────────────────${RESET}"
  if docker exec "$CONTAINER" test -f /data/.htpasswd 2>/dev/null; then
    docker exec "$CONTAINER" cat /data/.htpasswd \
      | awk -F: '{printf "  \033[0;36m%-20s\033[0m (加密方式: %s)\n", $1, \
          substr($2,1,1)=="$" ? "bcrypt" : "SHA"}'
  else
    warn ".htpasswd 不存在，尚未创建任何用户"
  fi
  echo ""
}

# 添加用户
# 非交互式用法：server.sh add-user --username USER --password PASS
cmd_add_user() {
  local opt_username="" opt_password=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --username) opt_username="$2"; shift 2 ;;
      --password) opt_password="$2"; shift 2 ;;
      *) die "add-user: 未知参数 $1" ;;
    esac
  done

  check_running
  echo ""
  echo -e "${BOLD}── 添加用户 ─────────────────────────────${RESET}"

  # 用户名
  local username="$opt_username"
  while [[ -z "$username" ]]; do
    read -rp "用户名: " username
  done

  # 检查用户是否已存在
  if docker exec "$CONTAINER" test -f /data/.htpasswd 2>/dev/null; then
    if docker exec "$CONTAINER" grep -q "^${username}:" /data/.htpasswd 2>/dev/null; then
      warn "用户 '${username}' 已存在，将更新密码"
    fi
  fi

  # 使用 bcrypt（根据文件是否存在决定是否加 -c 创建）
  local htpasswd_flag="-B"
  if ! docker exec "$CONTAINER" test -f /data/.htpasswd 2>/dev/null; then
    htpasswd_flag="-Bc"
  fi

  # 密码输入
  local password="$opt_password"
  if [[ -z "$password" ]]; then
    while true; do
      read -s -rp "密码: " password
      echo ""
      local password_confirm
      read -s -rp "确认密码: " password_confirm
      echo ""
      if [[ "$password" == "$password_confirm" ]]; then
        break
      else
        error "密码不匹配，请重新输入"
      fi
    done
  fi

  # 通过 stdin 传入密码，避免 -it 依赖
  docker exec -i "$CONTAINER" \
    sh -c "echo '${password}' | htpasswd ${htpasswd_flag} -i /data/.htpasswd '${username}'"

  success "用户 '${username}' 已添加/更新"

  # 发送 SIGHUP 重载认证文件
  docker exec "$CONTAINER" sh -c 'kill -HUP 1' 2>/dev/null || true
  info "已发送 SIGHUP，认证文件已重载"
}

# 删除用户
# 非交互式用法：server.sh del-user --username USER [--yes]
cmd_del_user() {
  local opt_username="" opt_yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --username) opt_username="$2"; shift 2 ;;
      -y|--yes)   opt_yes=1;         shift   ;;
      *) die "del-user: 未知参数 $1" ;;
    esac
  done

  check_running

  # 非交互时跳过用户列表展示
  [[ -n "$opt_username" ]] || cmd_list_users

  local username="$opt_username"
  while [[ -z "$username" ]]; do
    read -rp "请输入要删除的用户名: " username
  done

  if ! docker exec "$CONTAINER" grep -q "^${username}:" /data/.htpasswd 2>/dev/null; then
    die "用户 '${username}' 不存在"
  fi

  if [[ "$opt_yes" != "1" ]]; then
    read -rp "确认删除用户 '${username}'？[y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }
  fi

  docker exec "$CONTAINER" htpasswd -D /data/.htpasswd "$username"
  docker exec "$CONTAINER" sh -c 'kill -HUP 1' 2>/dev/null || true
  success "用户 '${username}' 已删除"
}

# 显示数据目录占用
cmd_disk() {
  check_running
  echo ""
  echo -e "${BOLD}── 数据目录磁盘占用 ─────────────────────${RESET}"
  docker exec "$CONTAINER" sh -c 'du -sh /data/* 2>/dev/null || echo "  (空)"'
  echo ""
  docker exec "$CONTAINER" df -h /data
  echo ""
}

# 帮助信息
cmd_help() {
  echo ""
  echo -e "${BOLD}用法: $0 <命令> [选项]${RESET}"
  echo ""
  echo -e "${BOLD}命令：${RESET}"
  echo -e "  ${CYAN}up${RESET}                  启动 rest-server（默认不启动监控）"
  echo -e "  ${CYAN}up --with-monitoring${RESET} 启动所有服务（含 Prometheus + Grafana）"
  echo -e "  ${CYAN}down${RESET}                停止所有服务"
  echo -e "  ${CYAN}restart${RESET}             重启 rest-server"
  echo -e "  ${CYAN}status${RESET}              查看容器状态"
  echo -e "  ${CYAN}logs [行数]${RESET}         查看日志（默认 50 行）"
  echo -e "  ${CYAN}users${RESET}               列出所有用户"
  echo -e "  ${CYAN}add-user${RESET}            添加/更新用户"
  echo -e "  ${CYAN}del-user${RESET}            删除用户"
  echo -e "  ${CYAN}disk${RESET}                查看磁盘占用"
  echo -e "  ${CYAN}menu${RESET}                进入交互菜单（默认）"
  echo -e "  ${CYAN}help, h${RESET}             显示此帮助"
  echo ""
  echo -e "${BOLD}非交互式选项：${RESET}"
  echo -e "  ${BOLD}add-user${RESET}"
  echo -e "    --username USER   用户名"
  echo -e "    --password PASS   密码（省略则交互输入）"
  echo ""
  echo -e "  ${BOLD}del-user${RESET}"
  echo -e "    --username USER   要删除的用户名"
  echo -e "    -y, --yes         跳过确认提示"
  echo ""
}

# ── 交互菜单 ──────────────────────────────────────────────────────────────────
show_banner() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔═══════════════════════════════════════╗"
  echo "  ║     restic REST Server 管理面板       ║"
  echo "  ╚═══════════════════════════════════════╝"
  echo -e "${RESET}"
}

main_menu() {
  while true; do
    show_banner
    cmd_status
    echo -e "${BOLD}请选择操作：${RESET}"
    echo ""
    echo "  1) 启动服务"
    echo "  2) 启动服务（含监控）"
    echo "  3) 停止服务"
    echo "  4) 重启 rest-server"
    echo "  5) 查看日志"
    echo "  6) 用户列表"
    echo "  7) 添加用户"
    echo "  8) 删除用户"
    echo "  9) 磁盘占用"
    echo "  0) 退出"
    echo ""
    read -rp "请输入选项 [0-9]: " choice

    case "$choice" in
      1) cmd_up ;;
      2) cmd_up --with-monitoring ;;
      3) cmd_down ;;
      4) cmd_restart ;;
      5) read -rp "显示最近多少行日志？[50]: " n; cmd_logs "${n:-50}" ;;
      6) cmd_list_users ;;
      7) cmd_add_user ;;
      8) cmd_del_user ;;
      9) cmd_disk ;;
      0) echo "再见！"; exit 0 ;;
      *) warn "无效选项" ;;
    esac

    echo ""
    read -rp "按 Enter 继续..." _
  done
}

# ── 入口 ──────────────────────────────────────────────────────────────────────
main() {
  check_deps

  local cmd="${1:-menu}"
  [[ $# -gt 0 ]] && shift

  case "$cmd" in
    up)               cmd_up "$@" ;;
    down)             cmd_down ;;
    restart)          cmd_restart ;;
    status)           cmd_status ;;
    logs)             cmd_logs "${1:-50}" ;;
    users)            cmd_list_users ;;
    add-user)         cmd_add_user "$@" ;;
    del-user)         cmd_del_user "$@" ;;
    disk)             cmd_disk ;;
    menu)             main_menu ;;
    help|h|-h|--help) cmd_help ;;
    *) error "未知命令: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"
