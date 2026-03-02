# 执行计划：restic-backup-deploy

## 任务描述
新建 restic REST Server 的使用方法仓库，使用 Docker Compose 一键部署，并提供交互式客户端脚本实现 CS 架构的备份管理。

## 目录结构
```
restic-backup-deploy/
├── docker-compose.yml        # rest-server + prometheus + grafana
├── .env.example              # 环境变量模板
├── .gitignore
├── config/
│   └── prometheus.yml        # 指标采集配置
├── scripts/
│   ├── server.sh             # 服务端管理（用户增删/状态/日志）
│   └── client.sh             # 客户端交互式备份（init/backup/restore/forget）
└── README.md
```

## 执行步骤
- [x] Step 1: git init + .gitignore + 目录结构
- [x] Step 2: docker-compose.yml + .env.example + prometheus.yml
- [x] Step 3: scripts/server.sh（交互菜单 + 参数模式）
- [x] Step 4: scripts/client.sh（init/backup/snapshots/restore/forget/check）
- [x] Step 5: README.md

## 关键设计决策
- server.sh 同时支持交互菜单和直接命令参数，兼顾自动化和手动操作
- client.sh 配置持久化到 ~/.restic-backup.conf（600权限），避免重复输入
- 密码在展示时始终脱敏（*** 替换）
- 使用 bcrypt 加密 htpasswd 密码
- SIGHUP 实现热重载认证文件，无需重启容器
