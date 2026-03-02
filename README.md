# restic-backup-deploy

[![Test](https://github.com/cdryzun/restic-backup-deploy/actions/workflows/test.yml/badge.svg)](https://github.com/cdryzun/restic-backup-deploy/actions/workflows/test.yml)

基于 [restic REST Server](https://github.com/restic/rest-server) 的一键部署方案，提供完整的备份服务端部署和客户端交互式备份工具。

## 特性

- **一键部署**：Docker Compose 启动 rest-server + Prometheus + Grafana 完整监控栈
- **交互式客户端**：引导式初始化、备份、恢复、清理全流程
- **非交互式支持**：所有命令支持命令行参数，适配 CI/CD 自动化
- **安全设计**：bcrypt 认证、TLS 支持、仓库加密
- **可观测**：开箱即用的 Prometheus 指标 + Grafana 仪表板
- **全流程验证**：内置测试脚本，GitHub Actions 自动化验证

## 快速开始

### 服务端部署（3 步）

```bash
# 1. 复制并编辑配置
cp .env.example .env
vim .env

# 2. 启动服务
./scripts/server.sh up

# 3. 添加备份用户
./scripts/server.sh add-user
```

服务端口：

| 服务         | 地址                     |
|-------------|--------------------------|
| rest-server | http://localhost:8000    |
| Prometheus  | http://localhost:9090    |
| Grafana     | http://localhost:3000    |

### 客户端使用

> 前提：客户端机器已安装 [restic](https://restic.net/downloads/)

**交互式：**

```bash
./scripts/client.sh
```

**非交互式（CI/CD 友好）：**

```bash
# 初始化仓库
./scripts/client.sh init \
  --server-url http://backup.example.com:8000 \
  --username myuser \
  --http-password "http-pass" \
  --repo-path myrepo \
  --repo-password "encryption-key" \
  --yes

# 执行备份
./scripts/client.sh backup --path /data --tag daily

# 清理旧快照
./scripts/client.sh forget --keep-daily 7 --keep-weekly 4 --yes
```

## 目录结构

```
restic-backup-deploy/
├── docker-compose.yml        # 服务编排
├── .env.example              # 环境变量模板
├── config/
│   ├── prometheus.yml        # Prometheus 采集配置
│   └── metrics_password      # Prometheus 认证密码
├── scripts/
│   ├── server.sh             # 服务端管理脚本
│   ├── client.sh             # 客户端脚本（交互式 + 非交互式）
│   └── test.sh               # 全流程验证脚本
├── .github/
│   └── workflows/
│       └── test.yml          # GitHub Actions CI
├── data/                     # 备份数据（git 忽略）
└── certs/                    # TLS 证书（git 忽略）
```

## 环境变量说明

| 变量名              | 默认值              | 说明                              |
|--------------------|---------------------|-----------------------------------|
| `RESTIC_PORT`      | `8000`              | rest-server 端口                  |
| `OPTIONS`          | `--prometheus`      | rest-server 启动参数              |
| `PROMETHEUS_PORT`  | `9090`              | Prometheus 端口                   |
| `METRICS_PASSWORD` | `changeme_metrics`  | Prometheus 抓取指标时的密码        |
| `GRAFANA_PORT`     | `3000`              | Grafana 端口                      |
| `GRAFANA_USER`     | `admin`             | Grafana 管理员用户名               |
| `GRAFANA_PASSWORD` | `changeme_grafana`  | Grafana 管理员密码                 |

## server.sh 命令参考

```bash
./scripts/server.sh <命令>

  up           启动所有服务
  down         停止所有服务
  restart      重启 rest-server
  status       查看容器状态
  logs [N]     查看最近 N 行日志（默认 50）
  users        列出所有认证用户
  add-user     添加或更新用户（支持 --username --password）
  del-user     删除用户（支持 --username --yes）
  disk         查看数据目录磁盘占用
  menu         进入交互菜单（默认）
  help, h      显示帮助
```

**非交互式示例：**

```bash
./scripts/server.sh add-user --username backup --password "secure123"
./scripts/server.sh del-user --username olduser --yes
```

## client.sh 命令参考

```bash
./scripts/client.sh <命令>

  menu         进入交互菜单（默认）
  init         初始化备份仓库
  backup       执行备份
  snapshots    浏览快照列表
  restore      恢复快照
  forget       清理旧快照（forget & prune）
  check        检查仓库完整性
  config       查看当前配置
  help, h      显示帮助
```

**非交互式参数：**

| 命令       | 参数                                      |
|-----------|-------------------------------------------|
| `init`    | `--server-url`, `--username`, `--http-password`, `--repo-path`, `--repo-password`, `--yes` |
| `backup`  | `--path`（必填）, `--tag`, `--exclude`    |
| `restore` | `--snapshot`, `--target`, `--include`, `--yes` |
| `forget`  | `--keep-last/hourly/daily/weekly/monthly N`, `--dry-run`, `--yes` |

## 验证测试

**本地验证：**

```bash
./scripts/test.sh
```

测试脚本会：
- 随机分配端口（30000-60000），不占用常用端口
- 自动下载 restic（如未安装）
- 启动隔离的 rest-server 容器
- 执行完整备份/恢复/清理流程
- 验证非交互式脚本
- 测试完成后自动清理所有资源

**GitHub Actions：**

推送代码或创建 PR 时自动运行全流程验证。

## 启用 TLS

```bash
# 1. 将证书放置到 ./certs/
cp your.crt ./certs/public_key
cp your.key ./certs/private_key

# 2. 在 .env 中启用 TLS
OPTIONS="--prometheus --tls"

# 3. 重启服务
./scripts/server.sh restart
```

> 使用 Let's Encrypt：`certbot certonly --standalone -d your.domain.com`

## 安全建议

- **生产环境必须启用 TLS**，避免密码在网络中明文传输
- 使用 `--append-only` 防止勒索软件删除备份
- 使用 `--private-repos` 隔离多用户仓库
- 定期执行 `restic check` 验证数据完整性
- 妥善保管仓库加密密码，丢失后无法恢复数据

## 许可证

MIT
