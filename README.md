# Backup Manager

一个基于 SCP 的自动备份管理工具，支持定时备份、自定义 SSH 端口、开机自启等功能。

## 功能特性

- 添加/修改/删除备份任务
- 支持自定义 SSH 端口
- 定时自动备份（基于 cron）
- 开机自动执行备份
- 创建任务时立即执行首次备份
- 自动安装依赖（expect、scp、cron）

## 一键安装

国内服务器：
```bash
bash <(curl -sL https://gitee.com/Assute/backup_manager/raw/master/backup_manager.sh)
```

国外服务器：
```bash
bash <(curl -sL https://raw.githubusercontent.com/Assute/backup_manager/main/backup_manager.sh)
```

## 使用方法

运行脚本后会显示菜单：

```
╔════════════════════════════════╗
║     SCP 备份管理工具 v1.0      ║
╠════════════════════════════════╣
║                                ║
║  1. 添加备份                   ║
║  2. 修改备份                   ║
║  3. 删除备份                   ║
║  4. 修改定时                   ║
║  0. 退出脚本                   ║
║                                ║
╚════════════════════════════════╝
```

### 添加备份任务

按提示依次输入：
1. 任务名称（英文）
2. 需要备份的路径
3. 目标服务器 IP/域名
4. SSH 端口（默认 22）
5. 用户名（默认 root）
6. 服务器密码
7. 目标存放目录
8. 备份间隔（分钟）

## 文件说明

脚本运行后会在 `/opt/backup/` 下创建：

| 目录 | 说明 |
|------|------|
| `backup_configs/` | 备份任务配置文件 |
| `backup_scripts/` | 自动生成的 expect 脚本 |
| `backup_logs/` | 备份日志 |

## 系统要求

- Linux 系统（Debian/Ubuntu/CentOS）
- root 权限
- 支持的包管理器：apt-get、yum、dnf

## License

MIT
