# restic-backup-deploy

基于 [restic REST Server](https://github.com/restic/rest-server) 的一键部署方案，提供完整的备份服务端部署和客户端交互式备份工具。

## 特性

- **一键部署**：Docker Compose 启动 rest-server + Prometheus + Grafana 完整监控栈
- **交互式客户端**：引导式初始化、备份、恢复、清理全流程
- **安全设计**：bcrypt 认证、TLS 支持、仓库加密
- **可观测**：开箱即用的 Prometheus 指标 + Grafana 仪表板

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

### 客户端使用（交互式）

> 前提：客户端机器已安装 [restic](https://restic.net/downloads/)

```bash
# 进入交互菜单
./scripts/client.sh

# 或直接执行子命令
./scripts/client.sh init      # 初始化仓库
./scripts/client.sh backup    # 执行备份
./scripts/client.sh snapshots # 查看快照
./scripts/client.sh restore   # 恢复快照
```

## 目录结构

```
restic-backup-deploy/
├── docker-compose.yml        # 服务编排
├── .env.example              # 环境变量模板
├── .gitignore
├── config/
│   └── prometheus.yml        # Prometheus 采集配置
├── scripts/
│   ├── server.sh             # 服务端管理脚本
│   └── client.sh             # 客户端交互式脚本
├── data/                     # 备份数据（git 忽略）
└── certs/                    # TLS 证书（git 忽略）
```

## 环境变量说明

| 变量名              | 默认值    | 说明                              |
|--------------------|-----------|-----------------------------------|
| `RESTIC_PORT`      | `8000`    | rest-server 端口                  |
| `TLS_ENABLED`      | —         | 设置任意值启用 TLS                 |
| `EXTRA_OPTIONS`    | —         | 额外启动参数（如 `--append-only`） |
| `PROMETHEUS_PORT`  | `9090`    | Prometheus 端口                   |
| `GRAFANA_PORT`     | `3000`    | Grafana 端口                      |
| `GRAFANA_USER`     | `admin`   | Grafana 管理员用户名               |
| `GRAFANA_PASSWORD` | `changeme_grafana` | Grafana 管理员密码        |

## server.sh 命令参考

```bash
./scripts/server.sh <命令>

  up           启动所有服务
  down         停止所有服务
  restart      重启 rest-server
  status       查看容器状态
  logs [N]     查看最近 N 行日志（默认 50）
  users        列出所有认证用户
  add-user     添加或更新用户
  del-user     删除用户
  disk         查看数据目录磁盘占用
  menu         进入交互菜单（默认）
```

## client.sh 功能说明

| 功能           | 说明                                         |
|---------------|----------------------------------------------|
| 初始化仓库     | 引导配置服务端地址、认证信息，执行 `restic init` |
| 执行备份       | 选择目录、标签、排除规则，执行 `restic backup`  |
| 浏览快照       | 列出所有快照及元信息                           |
| 恢复快照       | 选择快照 ID 和恢复目标，支持部分路径恢复        |
| 清理快照       | 配置保留策略，执行 `restic forget --prune`     |
| 检查完整性     | 执行 `restic check` 验证数据完整性             |

配置文件保存在 `~/.restic-backup.conf`（权限 600）。

## 启用 TLS

```bash
# 1. 将证书放置到 ./certs/
cp your.crt ./certs/public_key
cp your.key ./certs/private_key

# 2. 在 .env 中启用 TLS
echo "TLS_ENABLED=true" >> .env

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
