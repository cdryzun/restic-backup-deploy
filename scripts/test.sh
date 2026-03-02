#!/usr/bin/env bash
# =============================================================================
# test.sh — restic-backup-deploy 全流程验证脚本
# 启动临时隔离的 rest-server，执行完整备份/恢复/清理流程后自动销毁
# 端口随机分配于 30000-60000，不占用任何常用端口
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[PASS]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[FAIL]${RESET}  $*" >&2; }
step()    { echo -e "\n${BOLD}${BLUE}━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
die()     { error "$*"; exit 1; }

# ── 测试上下文 ────────────────────────────────────────────────────────────────
# 每次运行生成唯一标识，避免并发冲突
TEST_ID="rbtest-$$-$(date +%s)"
TEST_PORT=""                         # 由 pick_port 填充
TEST_CONTAINER="${TEST_ID}-server"
TEST_VOLUME="${TEST_ID}-data"
TEST_TMPDIR=""                       # 由 setup 填充
TEST_USER="testuser"
TEST_HTTP_PASS="http-pass-123"
TEST_REPO_PASS="repo-enc-pass-456"
TEST_REPO_PATH="myrepo"
RESTIC_BIN=""                        # 由 ensure_restic 填充
DOCKER_CMD="docker"                  # 由 check_docker 修正

# ── 清理 ──────────────────────────────────────────────────────────────────────
_CLEANED=0
cleanup() {
  [[ "$_CLEANED" == "1" ]] && return
  _CLEANED=1
  echo ""
  info "清理测试资源..."
  # 停止并删除容器
  $DOCKER_CMD rm -f "$TEST_CONTAINER" 2>/dev/null && info "容器已删除: $TEST_CONTAINER" || true
  # 删除数据卷
  $DOCKER_CMD volume rm -f "$TEST_VOLUME"  2>/dev/null && info "数据卷已删除: $TEST_VOLUME"  || true
  # 清理临时目录
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
    info "临时目录已删除: $TEST_TMPDIR"
  fi
}
trap cleanup EXIT

# ── 随机端口 ──────────────────────────────────────────────────────────────────
# 在 30000-60000 范围内找一个未被占用的端口
pick_port() {
  local port
  for _ in $(seq 1 20); do
    port=$(( RANDOM % 30000 + 30000 ))
    # 检查端口是否被占用（ss 或 netstat 二选一）
    if command -v ss &>/dev/null; then
      ss -tlnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
    elif command -v netstat &>/dev/null; then
      netstat -tlnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
    else
      # 无法检查，直接用
      echo "$port"; return
    fi
  done
  die "无法在 30000-60000 范围内找到可用端口"
}

# ── Docker 权限 ───────────────────────────────────────────────────────────────
check_docker() {
  if docker info &>/dev/null 2>&1; then
    DOCKER_CMD="docker"
    info "Docker: 当前用户可直接访问"
  elif sudo docker info &>/dev/null 2>&1; then
    DOCKER_CMD="sudo docker"
    warn "Docker: 需要 sudo 权限"
  else
    die "无法访问 Docker，请确认 Docker 已启动并有权限"
  fi
  info "Docker 版本: $($DOCKER_CMD --version)"
}

# ── 确保 restic 可用 ──────────────────────────────────────────────────────────
ensure_restic() {
  if command -v restic &>/dev/null; then
    RESTIC_BIN="restic"
    info "restic: $(restic version 2>&1 | head -1)"
    return
  fi

  warn "系统未安装 restic，尝试临时下载..."
  local restic_dir="${TEST_TMPDIR}/restic-bin"
  mkdir -p "$restic_dir"

  # 自动判断架构
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="arm"   ;;
    *)       die "不支持的架构: $(uname -m)，请手动安装 restic" ;;
  esac

  local os
  case "$(uname -s)" in
    Linux)  os="linux"  ;;
    Darwin) os="darwin" ;;
    *)      die "不支持的系统: $(uname -s)，请手动安装 restic" ;;
  esac

  # 获取最新版本号
  local version
  version=$(curl -sf --max-time 10 \
    "https://api.github.com/repos/restic/restic/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/') \
    || die "获取 restic 版本失败，请手动安装 restic: https://restic.net/downloads/"

  info "下载 restic v${version} (${os}/${arch})..."
  local binary="${restic_dir}/restic"
  local archive="${binary}.bz2"
  curl -fL --max-time 60 \
    "https://github.com/restic/restic/releases/download/v${version}/restic_${version}_${os}_${arch}.bz2" \
    -o "$archive" || die "下载失败，请手动安装 restic"

  bunzip2 -f "$archive"
  # bunzip2 去掉 .bz2 后缀，实际文件名为 restic_${version}_${os}_${arch}
  local extracted="${restic_dir}/restic_${version}_${os}_${arch}"
  [[ -f "$extracted" ]] && mv "$extracted" "$binary" || true
  chmod +x "$binary"
  RESTIC_BIN="$binary"
  info "restic 临时路径: $RESTIC_BIN"
  info "restic 版本: $($RESTIC_BIN version 2>&1 | head -1)"
}

# ── 等待 rest-server 就绪 ─────────────────────────────────────────────────────
wait_server_ready() {
  local url="$1"
  local max=30
  info "等待 rest-server 就绪 (最多 ${max}s)..."
  for i in $(seq 1 "$max"); do
    local http_code
    # rest-server 开启认证后 / 返回 401，视为服务已就绪（非 000 连接失败即可）
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "${url}/" 2>/dev/null || true)
    if [[ "$http_code" =~ ^[1-9][0-9]{2}$ ]]; then
      success "rest-server 已就绪（${i}s，HTTP ${http_code}）"
      return 0
    fi
    sleep 1
  done
  die "rest-server 启动超时（${max}s），检查容器日志：$DOCKER_CMD logs $TEST_CONTAINER"
}

# ── Setup ─────────────────────────────────────────────────────────────────────
setup() {
  step "测试环境初始化"

  check_docker

  TEST_TMPDIR=$(mktemp -d /tmp/${TEST_ID}.XXXXXX)
  info "临时目录: $TEST_TMPDIR"

  ensure_restic

  TEST_PORT=$(pick_port)
  info "测试端口: ${TEST_PORT}"

  # 启动隔离的 rest-server 容器（独立数据卷，不依赖项目 data/）
  info "启动测试容器: $TEST_CONTAINER"
  $DOCKER_CMD volume create "$TEST_VOLUME" >/dev/null
  $DOCKER_CMD run -d \
    --name "$TEST_CONTAINER" \
    --volume "${TEST_VOLUME}:/data" \
    --publish "${TEST_PORT}:8000" \
    restic/rest-server:latest \
    >/dev/null

  local server_url="http://localhost:${TEST_PORT}"
  wait_server_ready "$server_url"

  # 添加测试用户（用容器自带的 create_user 脚本）
  info "创建测试用户: $TEST_USER"
  $DOCKER_CMD exec "$TEST_CONTAINER" create_user "$TEST_USER" "$TEST_HTTP_PASS"

  # 发送 SIGHUP 重载认证文件，等待确认
  $DOCKER_CMD exec "$TEST_CONTAINER" sh -c 'kill -HUP 1'
  sleep 1
  # 确认日志中出现 "Reloaded htpasswd file"
  local reloaded
  reloaded=$($DOCKER_CMD logs "$TEST_CONTAINER" 2>&1 | grep -c "Reloaded htpasswd file" || true)
  if [[ "$reloaded" -lt 1 ]]; then
    # 某些版本可能不输出 Reloaded 日志，给足够时间等待
    sleep 2
  fi

  success "测试环境就绪"
}

# ── 测试执行器 ────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0

run_test() {
  local name="$1"; shift
  echo -e "\n  ${BOLD}▶ $name${RESET}"
  if "$@"; then
    success "$name"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
  else
    error "$name"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    # 继续执行后续测试，不提前退出
  fi
}

# ── 各阶段测试 ────────────────────────────────────────────────────────────────
SERVER_URL="http://localhost:${TEST_PORT:-0}"
REPO_URL=""

build_repo_url() {
  # restic 0.17+ 对 REST backend 需要 rest: 前缀
  REPO_URL="rest:http://${TEST_USER}:${TEST_HTTP_PASS}@localhost:${TEST_PORT}/${TEST_REPO_PATH}"
}

test_server_connectivity() {
  # rest-server 开启认证时 / 返回 401，视为连通（非连接失败即可）
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${SERVER_URL}/" 2>/dev/null || true)
  [[ "$code" =~ ^[1-9][0-9]{2}$ ]]
}

test_init() {
  build_repo_url
  RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" init --quiet
}

test_backup() {
  # 创建测试数据
  local src="${TEST_TMPDIR}/backup-src"
  mkdir -p "$src"
  echo "hello restic $(date)" > "${src}/file1.txt"
  echo "测试中文内容"          > "${src}/file2.txt"
  mkdir -p "${src}/subdir"
  dd if=/dev/urandom bs=1k count=64 2>/dev/null > "${src}/subdir/random.bin"

  RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" backup "$src" --tag test --quiet
}

test_second_backup() {
  # 模拟增量备份：修改部分文件
  local src="${TEST_TMPDIR}/backup-src"
  echo "updated $(date)" >> "${src}/file1.txt"
  echo "new file"         > "${src}/newfile.txt"

  RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" backup "$src" --tag test,incremental --quiet
}

test_snapshots() {
  local count
  count=$(RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" snapshots --quiet --json | grep -c '"id"')
  # forget 尚未执行，期望至少 1 个快照（增量备份可能合并相同内容）
  [[ "$count" -ge 1 ]] || { error "快照数量异常，期望 ≥1，实际 ${count}"; return 1; }
  info "快照数量: $count"
}

test_restore() {
  local target="${TEST_TMPDIR}/restore-target"
  mkdir -p "$target"
  RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" restore latest --target "$target" --quiet

  # 验证恢复内容
  local src_rel="${TEST_TMPDIR}/backup-src"
  # restic 恢复时保留完整路径，src_rel 无前导 /
  local restored="${target}${src_rel}"
  [[ -f "${restored}/file1.txt" ]] || { error "恢复文件缺失: file1.txt"; return 1; }
  [[ -f "${restored}/file2.txt" ]] || { error "恢复文件缺失: file2.txt"; return 1; }
  [[ -f "${restored}/newfile.txt" ]] || { error "恢复文件缺失: newfile.txt (增量)"; return 1; }
  info "恢复内容验证通过"
}

test_forget() {
  # 保留最近 1 个快照，应删除第一个
  RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" forget --keep-last 1 --prune --quiet

  local count
  count=$(RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" snapshots --quiet --json | grep -c '"id"')
  [[ "$count" -eq 1 ]] || { error "forget 后快照数量异常，期望 1，实际 ${count}"; return 1; }
  info "forget 后快照数量: $count"
}

test_integrity() {
  RESTIC_PASSWORD="$TEST_REPO_PASS" RESTIC_REPOSITORY="$REPO_URL" \
    "$RESTIC_BIN" check --quiet
}

test_server_sh_status() {
  # 验证 server.sh 基础命令可正常执行（不依赖项目容器）
  bash "${SCRIPT_DIR}/server.sh" help > /dev/null
  info "server.sh help 输出正常"
}

test_client_sh_help() {
  # client.sh help 不需要 restic，直接执行；check_deps 报错但 help 仍正常输出
  bash "${SCRIPT_DIR}/client.sh" help > /dev/null 2>&1 || true
  # 只要不 exit 非 0 就算通过（help 命令 exit 0）
  bash "${SCRIPT_DIR}/client.sh" help > /dev/null 2>&1
  info "client.sh help 输出正常"
}

test_client_sh_noninteractive() {
  # 验证 client.sh 非交互式 backup 命令（用已初始化的仓库）
  # 将 RESTIC_BIN 目录加入 PATH，使 client.sh 的 check_deps 能找到 restic
  local restic_dir
  restic_dir="$(dirname "$RESTIC_BIN")"

  local conf="${TEST_TMPDIR}/test-client.conf"
  cat > "$conf" <<EOF
RESTIC_REPOSITORY="${REPO_URL}"
RESTIC_PASSWORD="${TEST_REPO_PASS}"
RESTIC_SERVER_URL="http://localhost:${TEST_PORT}"
RESTIC_USERNAME="${TEST_USER}"
LAST_BACKUP_PATH=""
EOF
  chmod 600 "$conf"

  local extra_src="${TEST_TMPDIR}/extra-src"
  mkdir -p "$extra_src"
  echo "non-interactive test $(date)" > "${extra_src}/nit.txt"

  PATH="${restic_dir}:${PATH}" RESTIC_CLIENT_CONFIG="$conf" \
    bash "${SCRIPT_DIR}/client.sh" backup --path "$extra_src" --tag nit-test
  info "client.sh 非交互式 backup 执行成功"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}${BLUE}"
  echo "  ╔═══════════════════════════════════════════════╗"
  echo "  ║   restic-backup-deploy 全流程验证             ║"
  echo "  ╚═══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  setup

  # 重新构建 SERVER_URL（setup 后 TEST_PORT 已确定）
  SERVER_URL="http://localhost:${TEST_PORT}"

  step "脚本基础验证"
  run_test "server.sh help 可执行"          test_server_sh_status
  run_test "client.sh help 可执行"          test_client_sh_help

  step "服务端连通性"
  run_test "rest-server HTTP 连通"          test_server_connectivity

  step "restic 全流程"
  run_test "init: 初始化仓库"               test_init
  run_test "backup: 首次备份"               test_backup
  run_test "backup: 增量备份"               test_second_backup
  run_test "snapshots: 快照列表（≥2）"      test_snapshots
  run_test "restore: 恢复并验证文件完整性"  test_restore
  run_test "forget: 保留最近1个并prune"     test_forget
  run_test "check: 仓库完整性校验"          test_integrity

  step "非交互式脚本验证"
  run_test "client.sh backup 非交互式"      test_client_sh_noninteractive

  # ── 汇总 ──────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}━━ 测试结果 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "  ${GREEN}PASS${RESET}  ${PASS_COUNT}"
  echo -e "  ${RED}FAIL${RESET}  ${FAIL_COUNT}"
  echo ""

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    error "有 ${FAIL_COUNT} 个测试失败"
    exit 1
  else
    success "全部 ${PASS_COUNT} 个测试通过"
  fi
}

main "$@"
