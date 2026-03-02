#!/usr/bin/env bash
# =============================================================================
# client.sh — restic 交互式备份客户端
# 连接到 rest-server，提供初始化/备份/快照/恢复/清理 全功能交互界面
# 支持非交互式模式：通过命令行参数或环境变量传入所有配置
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
  local tmp_file
  tmp_file=$(mktemp "${CONFIG_FILE}.XXXXXX")
  chmod 600 "$tmp_file"
  cat > "$tmp_file" <<EOF
# restic 客户端配置（由 client.sh 自动生成）
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
RESTIC_SERVER_URL="${RESTIC_SERVER_URL:-}"
RESTIC_USERNAME="${RESTIC_USERNAME:-}"
LAST_BACKUP_PATH="${LAST_BACKUP_PATH:-}"
EOF
  mv "$tmp_file" "$CONFIG_FILE"
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
    error "尚未配置仓库，请先执行初始化："
    echo ""
    echo "  $0 init"
    echo ""
    return 1
  fi
  return 0
}

# ── 连通性测试 ────────────────────────────────────────────────────────────────
test_connection() {
  local url="$1"
  info "测试服务端连通性..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -I "${url%/}/" 2>/dev/null) || true
  case "$http_code" in
    200|401|403|404|405)
      success "服务端连接正常 (HTTP $http_code)"
      return 0
      ;;
    000)
      error "无法连接到 ${url}，请检查地址和网络"
      return 1
      ;;
    *)
      warn "服务端返回状态码: HTTP $http_code"
      return 0
      ;;
  esac
}

# ── 非交互式输入辅助 ──────────────────────────────────────────────────────────
# 用法: prompt_input <变量名引用> <提示文字> <默认值> [required]
# 若变量已有值则跳过交互；required=1 时空值报错退出
prompt_input() {
  local -n _ref=$1
  local prompt="$2"
  local default="${3:-}"
  local required="${4:-0}"

  if [[ -n "${_ref:-}" ]]; then
    return 0  # 已通过参数或环境变量提供，跳过
  fi

  local display_default=""
  [[ -n "$default" ]] && display_default=" [${default}]"
  read -rp "${prompt}${display_default}: " _ref
  _ref="${_ref:-$default}"

  if [[ "$required" == "1" && -z "${_ref:-}" ]]; then
    die "必填项未提供: ${prompt}"
  fi
}

# 静默密码输入，已有值则跳过
prompt_password() {
  local -n _ref=$1
  local prompt="$2"
  local required="${3:-0}"

  if [[ -n "${_ref:-}" ]]; then
    return 0
  fi

  read -rsp "${prompt}: " _ref
  echo ""

  if [[ "$required" == "1" && -z "${_ref:-}" ]]; then
    die "必填项未提供: ${prompt}"
  fi
}

# ── 菜单：初始化仓库 ──────────────────────────────────────────────────────────
# 非交互式用法：
#   client.sh init --server-url URL --username USER --http-password PASS \
#                  [--repo-path PATH] --repo-password REPO_PASS [--yes]
menu_init() {
  # 解析本命令参数
  local opt_server_url="" opt_username="" opt_http_password=""
  local opt_repo_path="" opt_repo_password="" opt_yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-url)      opt_server_url="$2";      shift 2 ;;
      --username)        opt_username="$2";         shift 2 ;;
      --http-password)   opt_http_password="$2";   shift 2 ;;
      --repo-path)       opt_repo_path="$2";        shift 2 ;;
      --repo-password)   opt_repo_password="$2";   shift 2 ;;
      -y|--yes)          opt_yes=1;                 shift   ;;
      *) die "init: 未知参数 $1" ;;
    esac
  done

  step "初始化 restic 备份仓库"
  echo ""
  echo -e "${DIM}restic 将使用 REST 协议连接服务端${RESET}"
  echo ""

  # 服务端地址
  local server_url="${opt_server_url:-${RESTIC_SERVER_URL:-}}"
  prompt_input server_url "服务端地址" "http://localhost:8000" 1
  server_url="${server_url%/}"

  # 认证用户名
  local username="${opt_username:-${RESTIC_USERNAME:-}}"
  prompt_input username "认证用户名" "" 1

  # 认证密码（HTTP）
  local http_password="$opt_http_password"
  prompt_password http_password "认证密码（HTTP）" 1

  # 仓库路径
  local repo_path="${opt_repo_path:-}"
  local default_repo="${username:-mybackup}"
  prompt_input repo_path "仓库路径（相对于服务端根目录）" "$default_repo" 1
  repo_path="${repo_path#/}"

  # 构建仓库 URL（restic REST 后端需要 rest: 前缀）
  local proto="${server_url%%://*}"
  local host_path="${server_url#*://}"
  local repo_url="rest:${proto}://${username}:${http_password}@${host_path}/${repo_path}"

  # 连通性测试
  test_connection "$server_url" || return 1

  # 仓库加密密码
  local repo_password="$opt_repo_password"
  if [[ -z "$repo_password" ]]; then
    echo ""
    warn "以下密码用于加密仓库数据，与服务端认证密码不同，请妥善保管！"
    echo ""
    local repo_password_confirm=""
    while true; do
      read -rsp "仓库加密密码: " repo_password
      echo ""
      read -rsp "确认加密密码: " repo_password_confirm
      echo ""
      [[ "$repo_password" == "$repo_password_confirm" ]] && break
      error "两次输入不一致，请重试"
    done
  fi
  [[ -n "$repo_password" ]] || die "仓库加密密码不能为空"

  # 确认信息
  echo ""
  echo -e "${BOLD}── 确认以下配置 ─────────────────────────${RESET}"
  echo -e "  服务端地址: ${CYAN}${server_url}${RESET}"
  echo -e "  认证用户名: ${CYAN}${username}${RESET}"
  echo -e "  仓库路径:   ${CYAN}/${repo_path}${RESET}"
  echo -e "  完整 URL:   ${CYAN}${proto}://${username}:***@${host_path}/${repo_path}${RESET}"
  echo ""

  if [[ "$opt_yes" != "1" ]]; then
    read -rp "确认初始化？[y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }
  fi

  # 执行初始化
  echo ""
  info "正在初始化仓库..."
  if RESTIC_PASSWORD="$repo_password" RESTIC_REPOSITORY="$repo_url" restic init; then
    success "仓库初始化成功！"

    # 保存配置
    RESTIC_REPOSITORY="$repo_url"
    RESTIC_PASSWORD="$repo_password"
    RESTIC_SERVER_URL="$server_url"
    RESTIC_USERNAME="$username"
    export RESTIC_REPOSITORY RESTIC_PASSWORD
    save_config
  else
    echo ""
    warn "restic init 失败（仓库可能已存在）"
    echo ""
    echo -e "  若仓库已存在，是否直接使用该仓库并保存配置？"
    local use_existing="n"
    if [[ "$opt_yes" == "1" ]]; then
      # 非交互模式：仓库已存在时自动使用（调用方已确认）
      use_existing="y"
    else
      read -rp "  使用现有仓库？[y/N] " use_existing
    fi
    if [[ "$use_existing" =~ ^[Yy]$ ]]; then
      RESTIC_REPOSITORY="$repo_url"
      RESTIC_PASSWORD="$repo_password"
      RESTIC_SERVER_URL="$server_url"
      RESTIC_USERNAME="$username"
      export RESTIC_REPOSITORY RESTIC_PASSWORD
      save_config
      info "已保存现有仓库配置，可尝试执行 snapshots 验证连接"
    else
      error "初始化失败，请检查服务端状态和认证信息"
      return 1
    fi
  fi
}

# ── 菜单：执行备份 ────────────────────────────────────────────────────────────
# 非交互式用法：
#   client.sh backup --path /data [--tag tag1,tag2] [--exclude '*.log,node_modules']
menu_backup() {
  local opt_path="" opt_tags="" opt_exclude=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)    opt_path="$2";    shift 2 ;;
      --tag)     opt_tags="$2";    shift 2 ;;
      --exclude) opt_exclude="$2"; shift 2 ;;
      *) die "backup: 未知参数 $1" ;;
    esac
  done

  step "执行备份"
  check_config || return

  # 备份路径
  local backup_path="$opt_path"
  local default_path="${LAST_BACKUP_PATH:-$HOME}"
  prompt_input backup_path "要备份的目录/文件" "$default_path" 1

  [[ -e "$backup_path" ]] || { error "路径不存在: $backup_path"; return 1; }

  # 标签（非交互时已通过参数提供，交互时提示）
  local input_tags="$opt_tags"
  [[ -n "$opt_path" ]] || prompt_input input_tags "备份标签（可选，多个用逗号分隔）" "" 0

  # 排除规则
  local input_exclude="$opt_exclude"
  [[ -n "$opt_path" ]] || prompt_input input_exclude "排除规则（可选，如 '*.log,node_modules'）" "" 0

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

  if restic backup "${args[@]}"; then
    echo ""
    success "备份完成！"
    echo ""
    info "最新快照信息:"
    restic snapshots --latest 1
  else
    error "备份失败"
    return 1
  fi
}

# ── 菜单：浏览快照 ────────────────────────────────────────────────────────────
menu_snapshots() {
  step "快照列表"
  check_config || return

  echo ""
  if restic snapshots; then
    echo ""
    echo -e "${DIM}提示：可使用快照 ID 前 8 位进行恢复${RESET}"
    echo ""
  else
    error "获取快照列表失败"
    return 1
  fi
}

# ── 菜单：恢复快照 ────────────────────────────────────────────────────────────
# 非交互式用法：
#   client.sh restore --snapshot SNAPSHOT_ID --target /path/to/restore \
#                     [--include /path] [--yes]
menu_restore() {
  local opt_snapshot="" opt_target="" opt_include="" opt_yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot) opt_snapshot="$2"; shift 2 ;;
      --target)   opt_target="$2";   shift 2 ;;
      --include)  opt_include="$2";  shift 2 ;;
      -y|--yes)   opt_yes=1;         shift   ;;
      *) die "restore: 未知参数 $1" ;;
    esac
  done

  step "恢复快照"
  check_config || return

  # 非交互时跳过列表展示（已知快照 ID），交互时展示
  if [[ -z "$opt_snapshot" ]]; then
    info "当前快照列表："
    echo ""
    restic snapshots || { error "获取快照列表失败"; return 1; }
    echo ""
  fi

  # 快照 ID
  local snapshot_id="$opt_snapshot"
  prompt_input snapshot_id "快照 ID（输入 'latest' 恢复最新）" "" 1

  # 恢复目标
  local target="$opt_target"
  prompt_input target "恢复到目录" "/tmp/restic-restore" 1

  # 可选路径过滤
  local include_path="$opt_include"
  [[ -n "$opt_snapshot" ]] || prompt_input include_path "仅恢复指定路径（可选，如 '/home/user/docs'）" "" 0

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

  if [[ "$opt_yes" != "1" ]]; then
    read -rp "确认恢复？[y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }
  fi

  echo ""
  info "开始恢复..."
  mkdir -p "$target"
  if restic restore "${args[@]}"; then
    success "恢复完成！文件已还原到: $target"
  else
    error "恢复失败"
    return 1
  fi
}

# ── 菜单：清理快照 ────────────────────────────────────────────────────────────
# 非交互式用法：
#   client.sh forget [--keep-last N] [--keep-hourly N] [--keep-daily N] \
#                    [--keep-weekly N] [--keep-monthly N] [--dry-run] [--yes]
menu_forget() {
  local opt_keep_last="" opt_keep_hourly="" opt_keep_daily=""
  local opt_keep_weekly="" opt_keep_monthly="" opt_dry_run=0 opt_yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-last)    opt_keep_last="$2";    shift 2 ;;
      --keep-hourly)  opt_keep_hourly="$2";  shift 2 ;;
      --keep-daily)   opt_keep_daily="$2";   shift 2 ;;
      --keep-weekly)  opt_keep_weekly="$2";  shift 2 ;;
      --keep-monthly) opt_keep_monthly="$2"; shift 2 ;;
      --dry-run)      opt_dry_run=1;         shift   ;;
      -y|--yes)       opt_yes=1;             shift   ;;
      *) die "forget: 未知参数 $1" ;;
    esac
  done

  step "清理快照（forget & prune）"
  check_config || return

  # 非交互模式：参数已提供时直接使用，否则提示输入
  local noninteractive=0
  [[ -n "$opt_keep_last$opt_keep_hourly$opt_keep_daily$opt_keep_weekly$opt_keep_monthly" ]] \
    && noninteractive=1

  local keep_last="$opt_keep_last"
  local keep_hourly="$opt_keep_hourly"
  local keep_daily="$opt_keep_daily"
  local keep_weekly="$opt_keep_weekly"
  local keep_monthly="$opt_keep_monthly"

  if [[ "$noninteractive" == "0" ]]; then
    echo ""
    echo -e "${BOLD}设置保留策略（保持为空则不限制）：${RESET}"
    echo ""
    prompt_input keep_last    "保留最近 N 个快照" "" 0
    prompt_input keep_hourly  "保留每小时最新快照 N 小时" "" 0
    prompt_input keep_daily   "保留每天最新快照 N 天" "" 0
    prompt_input keep_weekly  "保留每周最新快照 N 周" "" 0
    prompt_input keep_monthly "保留每月最新快照 N 月" "" 0
  fi

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

  # dry-run 预览
  echo ""
  info "预览将要删除的快照（dry-run）..."
  echo ""
  restic forget "${args[@]}" --dry-run
  echo ""

  # --dry-run 标志：只预览不执行
  if [[ "$opt_dry_run" == "1" ]]; then
    info "dry-run 模式，未实际执行清理"
    return
  fi

  if [[ "$opt_yes" != "1" ]]; then
    read -rp "确认执行清理并 prune 数据？[y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; return; }
  fi

  echo ""
  info "执行清理..."
  if restic forget "${args[@]}" --prune; then
    success "清理完成！"
  else
    error "清理失败"
    return 1
  fi
}

# ── 菜单：检查仓库 ────────────────────────────────────────────────────────────
menu_check() {
  step "检查仓库完整性"
  check_config || return

  echo ""
  info "正在检查仓库完整性（此操作可能较慢）..."
  if restic check; then
    success "仓库完整性检查通过！"
  else
    error "仓库检查失败，可能存在数据损坏"
    return 1
  fi
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
    RESTIC_REPOSITORY="rest:${proto}://${RESTIC_USERNAME}:${http_pass}@${host_path}/${repo_path}"
  fi

  read -rsp "仓库加密密码（直接回车跳过）: " new_repo_pass
  echo ""
  [[ -n "$new_repo_pass" ]] && RESTIC_PASSWORD="$new_repo_pass"

  export RESTIC_REPOSITORY RESTIC_PASSWORD
  save_config
}

# ── 帮助信息 ──────────────────────────────────────────────────────────────────
cmd_help() {
  echo ""
  echo -e "${BOLD}用法: $0 <命令> [选项]${RESET}"
  echo ""
  echo -e "${BOLD}命令：${RESET}"
  echo -e "  ${CYAN}menu${RESET}       进入交互菜单（默认）"
  echo -e "  ${CYAN}init${RESET}       初始化备份仓库"
  echo -e "  ${CYAN}backup${RESET}     执行备份"
  echo -e "  ${CYAN}snapshots${RESET}  浏览快照列表"
  echo -e "  ${CYAN}restore${RESET}    恢复快照"
  echo -e "  ${CYAN}forget${RESET}     清理旧快照（forget & prune）"
  echo -e "  ${CYAN}check${RESET}      检查仓库完整性"
  echo -e "  ${CYAN}config${RESET}     查看当前配置"
  echo -e "  ${CYAN}help, h${RESET}    显示此帮助"
  echo ""
  echo -e "${BOLD}非交互式选项：${RESET}"
  echo -e "  ${BOLD}init${RESET}"
  echo -e "    --server-url    URL    服务端地址（默认 http://localhost:8000）"
  echo -e "    --username      USER   HTTP 认证用户名"
  echo -e "    --http-password PASS   HTTP 认证密码"
  echo -e "    --repo-path     PATH   仓库路径（默认同用户名）"
  echo -e "    --repo-password PASS   仓库加密密码"
  echo -e "    -y, --yes              跳过确认提示"
  echo ""
  echo -e "  ${BOLD}backup${RESET}"
  echo -e "    --path          PATH   备份目标路径（必填）"
  echo -e "    --tag           TAGS   标签，逗号分隔（可选）"
  echo -e "    --exclude       PATS   排除规则，逗号分隔（可选）"
  echo ""
  echo -e "  ${BOLD}restore${RESET}"
  echo -e "    --snapshot      ID     快照 ID 或 'latest'"
  echo -e "    --target        PATH   恢复目标目录"
  echo -e "    --include       PATH   仅恢复指定路径（可选）"
  echo -e "    -y, --yes              跳过确认提示"
  echo ""
  echo -e "  ${BOLD}forget${RESET}"
  echo -e "    --keep-last     N      保留最近 N 个快照"
  echo -e "    --keep-hourly   N      每小时保留 N 个"
  echo -e "    --keep-daily    N      每天保留 N 个"
  echo -e "    --keep-weekly   N      每周保留 N 个"
  echo -e "    --keep-monthly  N      每月保留 N 个"
  echo -e "    --dry-run              仅预览，不实际执行"
  echo -e "    -y, --yes              跳过确认提示"
  echo ""
  echo -e "${BOLD}环境变量：${RESET}"
  echo -e "  RESTIC_REPOSITORY    仓库 URL（优先于配置文件）"
  echo -e "  RESTIC_PASSWORD      仓库加密密码"
  echo -e "  RESTIC_CLIENT_CONFIG 配置文件路径（默认 ~/.restic-backup.conf）"
  echo ""
  echo -e "${DIM}配置文件: ${CONFIG_FILE}${RESET}"
  echo ""
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
    echo "  1) 初始化备份仓库"
    echo "  2) 执行备份"
    echo "  3) 浏览快照列表"
    echo "  4) 恢复快照"
    echo "  5) 清理旧快照（forget & prune）"
    echo "  6) 检查仓库完整性"
    echo "  ─────────────────────────"
    echo "  7) 查看当前配置"
    echo "  8) 修改连接配置"
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

  local cmd="${1:-menu}"
  [[ $# -gt 0 ]] && shift

  case "$cmd" in
    menu)             main_menu ;;
    init)             menu_init "$@" ;;
    backup)           menu_backup "$@" ;;
    snapshots)        menu_snapshots ;;
    restore)          menu_restore "$@" ;;
    forget)           menu_forget "$@" ;;
    check)            menu_check ;;
    config)           menu_show_config ;;
    help|h|-h|--help) cmd_help ;;
    *)
      error "未知命令: $cmd"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
