#!/usr/bin/env bash
# =============================================================================
# client.sh — restic 交互式备份客户端
# 连接到 rest-server，提供初始化/备份/快照/恢复/清理 全功能交互界面
# =============================================================================
set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[✔]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET}   $*"; }
error()   { echo -e "${RED}[✘]${RESET}   $*" >&2; }
die()     { error "$*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }

# ── 配置文件 ──────────────────────────────────────────────────────────────────
CONFIG_FILE="${RESTIC_CLIENT_CONFIG:-$HOME/.restic-backup.conf}"

load_config() {
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true
  # 导出供 restic 使用的环境变量
  [[ -n "${RESTIC_REPOSITORY:-}" ]] && export RESTIC_REPOSITORY
  [[ -n "${RESTIC_PASSWORD:-}" ]]   && export RESTIC_PASSWORD
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# restic 客户端配置（由 client.sh 自动生成）
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
RESTIC_SERVER_URL="${RESTIC_SERVER_URL:-}"
RESTIC_USERNAME="${RESTIC_USERNAME:-}"
LAST_BACKUP_PATH="${LAST_BACKUP_PATH:-}"
EOF
  chmod 600 "$CONFIG_FILE"
  success "配置已保存到 $CONFIG_FILE"
}

# ── 前置检查 ──────────────────────────────────────────────────────────────────
check_deps() {
  if ! command -v restic &>/dev/null; then
    echo ""
    error "未找到 restic 命令"
    echo ""
    echo -e "${BOLD}安装方法：${RESET}"
    echo "  Debian/Ubuntu : sudo apt install restic"
    echo "  macOS         : brew install restic"
    echo "  其他          : https://restic.net/downloads/"
    echo ""
    exit 1
  fi
  local ver
  ver=$(restic version 2>&1 | head -1)
  info "restic 版本: $ver"
}

check_config() {
  if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
    warn "尚未配置仓库，请先执行「初始化仓库」"
    return 1
  fi
  return 0
}

# ── 连通性测试 ────────────────────────────────────────────────────────────────
test_connection() {
  local url="$1"
  info "测试服务端连通性..."
  if curl -sf --max-time 5 "${url%/}/" -o /dev/null; then
    success "服务端连接正常"
    return 0
  else
    error "无法连接到 ${url}，请检查地址和网络"
    return 1
  fi
}

# ── 菜单：初始化仓库 ──────────────────────────────────────────────────────────
menu_init() {
  step "初始化 restic 备份仓库"
  echo ""
  echo -e "${DIM}将在 rest-server 上创建新的加密备份仓库${RESET}"
  echo ""

  # 服务端地址
  local default_url="${RESTIC_SERVER_URL:-http://localhost:8000}"
  read -rp "服务端地址 [${default_url}]: " input_url
  local server_url="${input_url:-$default_url}"
  server_url="${server_url%/}"  # 去除末尾斜杠

  # 认证用户名
  local default_user="${RESTIC_USERNAME:-}"
  read -rp "认证用户名${default_user:+ [${default_user}]}: " input_user
  local username="${input_user:-$default_user}"

  # 认证密码
  local http_password=""
  read -rsp "认证密码: " http_password
  echo ""

  # 仓库名（路径）
  local default_repo="${username:-mybackup}"
  read -rp "仓库路径（相对于服务端根目录）[${default_repo}]: " input_repo
  local repo_path="${input_repo:-$default_repo}"
  repo_path="${repo_path#/}"  # 去除开头斜杠

  # 构建仓库 URL
  local proto="${server_url%%://*}"
  local host_path="${server_url#*://}"
  local repo_url="${proto}://${username}:${http_password}@${host_path}/${repo_path}"

  # 连通性测试（使用不含密码的 URL 避免在日志暴露）
  test_connection "$server_url" || return 1

  # 仓库加密密码
  echo ""
  warn "以下密码用于加密仓库数据，与服务端认证密码不同，请妥善保管！"
  echo ""
  local repo_password=""
  local repo_password_confirm=""
  while true; do
    read -rsp "仓库加密密码: " repo_password
    echo ""
    read -rsp "确认加密密码: " repo_password_confirm
    echo ""
    [[ "$repo_password" == "$repo_password_confirm" ]] && break
    error "两次输入不一致，请重试"
  done

  # 确认信息
  echo ""
  echo -e "${BOLD}── 确认以下配置 ─────────────────────────${RESET}"
  echo -e "  服务端地址: ${CYAN}${server_url}${RESET}"
  echo -e "  认证用户名: ${CYAN}${username}${RESET}"
  echo -e "  仓库路径:   ${CYAN}/${repo_path}${RESET}"
  echo -e "  完整 URL:   ${CYAN}${proto}://${username}:***@${host_path}/${repo_path}${RESET}"
  echo ""
  read -rp "确认初始化？[y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }

  # 执行初始化
  echo ""
  info "正在初始化仓库..."
  RESTIC_PASSWORD="$repo_password" RESTIC_REPOSITORY="$repo_url" \
    restic init && {
      success "仓库初始化成功！"

      # 保存配置
      RESTIC_REPOSITORY="$repo_url"
      RESTIC_PASSWORD="$repo_password"
      RESTIC_SERVER_URL="$server_url"
      RESTIC_USERNAME="$username"
      export RESTIC_REPOSITORY RESTIC_PASSWORD
      save_config
    } || {
      error "初始化失败，请检查服务端状态和认证信息"
    }
}

# ── 菜单：执行备份 ────────────────────────────────────────────────────────────
menu_backup() {
  step "执行备份"
  check_config || return

  # 选择备份路径
  local default_path="${LAST_BACKUP_PATH:-$HOME}"
  read -rp "要备份的目录/文件 [${default_path}]: " input_path
  local backup_path="${input_path:-$default_path}"

  [[ -e "$backup_path" ]] || { error "路径不存在: $backup_path"; return 1; }

  # 可选标签
  read -rp "备份标签（可选，多个用逗号分隔）: " input_tags

  # 可选排除规则
  read -rp "排除规则（可选，如 '*.log,node_modules'）: " input_exclude

  # 构建命令参数
  local args=("$backup_path")

  if [[ -n "$input_tags" ]]; then
    IFS=',' read -ra tags <<< "$input_tags"
    for tag in "${tags[@]}"; do
      args+=(--tag "${tag// /}")
    done
  fi

  if [[ -n "$input_exclude" ]]; then
    IFS=',' read -ra excludes <<< "$input_exclude"
    for ex in "${excludes[@]}"; do
      args+=(--exclude "${ex// /}")
    done
  fi

  echo ""
  info "开始备份: ${backup_path}"
  echo -e "${DIM}目标仓库: ${RESTIC_REPOSITORY%%@*}@...${RESET}"
  echo ""

  # 保存最近备份路径
  LAST_BACKUP_PATH="$backup_path"
  save_config

  restic backup "${args[@]}" && {
    echo ""
    success "备份完成！"
    echo ""
    info "最新快照信息:"
    restic snapshots --last 1
  } || {
    error "备份失败"
  }
}

# ── 菜单：浏览快照 ────────────────────────────────────────────────────────────
menu_snapshots() {
  step "快照列表"
  check_config || return

  echo ""
  restic snapshots && echo "" || { error "获取快照列表失败"; return 1; }

  echo -e "${DIM}提示：可使用快照 ID 前 8 位进行恢复${RESET}"
  echo ""
}

# ── 菜单：恢复快照 ────────────────────────────────────────────────────────────
menu_restore() {
  step "恢复快照"
  check_config || return

  # 显示快照列表
  info "当前快照列表："
  echo ""
  restic snapshots || { error "获取快照列表失败"; return 1; }
  echo ""

  # 选择快照
  local snapshot_id=""
  read -rp "快照 ID（输入 'latest' 恢复最新）: " snapshot_id
  [[ -n "$snapshot_id" ]] || { warn "已取消"; return; }

  # 恢复目标目录
  local default_target="/tmp/restic-restore"
  read -rp "恢复到目录 [${default_target}]: " input_target
  local target="${input_target:-$default_target}"

  # 可选：仅恢复部分路径
  read -rp "仅恢复指定路径（可选，如 '/home/user/docs'）: " include_path

  local args=("$snapshot_id" --target "$target")
  [[ -n "$include_path" ]] && args+=(--include "$include_path")

  # 确认
  echo ""
  echo -e "${BOLD}── 确认恢复操作 ─────────────────────────${RESET}"
  echo -e "  快照 ID: ${CYAN}${snapshot_id}${RESET}"
  echo -e "  恢复到:  ${CYAN}${target}${RESET}"
  [[ -n "$include_path" ]] && echo -e "  包含路径: ${CYAN}${include_path}${RESET}"
  echo ""
  warn "恢复操作会覆盖目标目录中的同名文件！"
  read -rp "确认恢复？[y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }

  echo ""
  info "开始恢复..."
  mkdir -p "$target"
  restic restore "${args[@]}" && {
    success "恢复完成！文件已还原到: $target"
  } || {
    error "恢复失败"
  }
}

# ── 菜单：清理快照 ────────────────────────────────────────────────────────────
menu_forget() {
  step "清理快照（forget & prune）"
  check_config || return

  echo ""
  echo -e "${BOLD}设置保留策略（保持为空则不限制）：${RESET}"
  echo ""

  read -rp "保留最近 N 个快照: "        keep_last
  read -rp "保留每小时最新快照 N 小时: " keep_hourly
  read -rp "保留每天最新快照 N 天: "     keep_daily
  read -rp "保留每周最新快照 N 周: "     keep_weekly
  read -rp "保留每月最新快照 N 月: "     keep_monthly

  local args=()
  [[ -n "$keep_last" ]]    && args+=(--keep-last    "$keep_last")
  [[ -n "$keep_hourly" ]]  && args+=(--keep-hourly  "$keep_hourly")
  [[ -n "$keep_daily" ]]   && args+=(--keep-daily   "$keep_daily")
  [[ -n "$keep_weekly" ]]  && args+=(--keep-weekly  "$keep_weekly")
  [[ -n "$keep_monthly" ]] && args+=(--keep-monthly "$keep_monthly")

  if [[ ${#args[@]} -eq 0 ]]; then
    warn "未设置任何保留策略，已取消"
    return
  fi

  echo ""
  info "预览将要删除的快照（dry-run）..."
  echo ""
  restic forget "${args[@]}" --dry-run
  echo ""

  read -rp "确认执行清理并 prune 数据？[y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }

  echo ""
  info "执行清理..."
  restic forget "${args[@]}" --prune && {
    success "清理完成！"
  } || {
    error "清理失败"
  }
}

# ── 菜单：检查仓库 ────────────────────────────────────────────────────────────
menu_check() {
  step "检查仓库完整性"
  check_config || return

  echo ""
  info "正在检查仓库完整性（此操作可能较慢）..."
  restic check && {
    success "仓库完整性检查通过！"
  } || {
    error "仓库检查失败，可能存在数据损坏"
  }
}

# ── 菜单：显示配置 ────────────────────────────────────────────────────────────
menu_show_config() {
  step "当前配置"
  echo ""
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${DIM}配置文件: $CONFIG_FILE${RESET}"
    echo ""
    # 隐藏密码显示
    sed 's/\(RESTIC_PASSWORD=\).*/\1"***"/' "$CONFIG_FILE" \
      | grep -v '^#' | grep -v '^$' \
      | while IFS= read -r line; do
          echo -e "  ${CYAN}${line}${RESET}"
        done
  else
    warn "配置文件不存在，请先初始化仓库"
  fi
  echo ""
}

# ── 菜单：修改配置 ────────────────────────────────────────────────────────────
menu_edit_config() {
  step "修改连接配置"
  echo ""
  echo -e "${DIM}直接编辑仓库连接（不重新 init）${RESET}"
  echo ""

  local current_url="${RESTIC_SERVER_URL:-}"
  read -rp "服务端地址 [${current_url:-http://localhost:8000}]: " input_url
  RESTIC_SERVER_URL="${input_url:-${current_url:-http://localhost:8000}}"

  local current_user="${RESTIC_USERNAME:-}"
  read -rp "认证用户名 [${current_user}]: " input_user
  RESTIC_USERNAME="${input_user:-$current_user}"

  read -rsp "认证密码（直接回车跳过）: " http_pass
  echo ""

  local current_repo_path=""
  if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
    current_repo_path="${RESTIC_REPOSITORY##*/}"
  fi
  read -rp "仓库路径 [${current_repo_path}]: " input_repo
  local repo_path="${input_repo:-$current_repo_path}"
  repo_path="${repo_path#/}"

  if [[ -n "$http_pass" ]]; then
    local proto="${RESTIC_SERVER_URL%%://*}"
    local host_path="${RESTIC_SERVER_URL#*://}"
    RESTIC_REPOSITORY="${proto}://${RESTIC_USERNAME}:${http_pass}@${host_path}/${repo_path}"
  fi

  read -rsp "仓库加密密码（直接回车跳过）: " new_repo_pass
  echo ""
  [[ -n "$new_repo_pass" ]] && RESTIC_PASSWORD="$new_repo_pass"

  export RESTIC_REPOSITORY RESTIC_PASSWORD
  save_config
}

# ── Banner ────────────────────────────────────────────────────────────────────
show_banner() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║      restic 交互式备份客户端              ║"
  echo "  ║      连接到 restic REST Server            ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${RESET}"

  # 显示当前连接状态
  if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
    local display_url
    display_url=$(echo "$RESTIC_REPOSITORY" | sed 's|://[^:]*:[^@]*@|://***:***@|')
    echo -e "  ${DIM}仓库: ${display_url}${RESET}"
  else
    echo -e "  ${YELLOW}  ⚠ 尚未配置仓库，请先执行「初始化仓库」${RESET}"
  fi
  echo ""
}

# ── 主菜单 ────────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    show_banner

    echo -e "${BOLD}  主菜单${RESET}"
    echo ""
    echo "  1) 🚀  初始化备份仓库"
    echo "  2) 💾  执行备份"
    echo "  3) 📋  浏览快照列表"
    echo "  4) 🔄  恢复快照"
    echo "  5) 🧹  清理旧快照（forget & prune）"
    echo "  6) 🔍  检查仓库完整性"
    echo "  ─────────────────────────"
    echo "  7) ⚙️   查看当前配置"
    echo "  8) ✏️   修改连接配置"
    echo "  0) 退出"
    echo ""
    read -rp "  请输入选项 [0-8]: " choice
    echo ""

    case "$choice" in
      1) menu_init ;;
      2) menu_backup ;;
      3) menu_snapshots ;;
      4) menu_restore ;;
      5) menu_forget ;;
      6) menu_check ;;
      7) menu_show_config ;;
      8) menu_edit_config; load_config ;;
      0) echo -e "\n  ${GREEN}再见！${RESET}\n"; exit 0 ;;
      *) warn "无效选项: $choice" ;;
    esac

    echo ""
    read -rp "  按 Enter 返回主菜单..." _
  done
}

# ── 入口 ──────────────────────────────────────────────────────────────────────
main() {
  check_deps
  load_config

  case "${1:-menu}" in
    menu)      main_menu ;;
    init)      menu_init ;;
    backup)    menu_backup ;;
    snapshots) menu_snapshots ;;
    restore)   menu_restore ;;
    forget)    menu_forget ;;
    check)     menu_check ;;
    config)    menu_show_config ;;
    *)
      echo "用法: $0 [menu|init|backup|snapshots|restore|forget|check|config]"
      exit 1
      ;;
  esac
}

main "$@"
