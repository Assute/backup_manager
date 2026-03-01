# Backup Manager

![Backup Manager](https://upload-bbs.miyoushe.com/upload/2026/03/01/363490070/e4f9fbad785cd0a3b53d88a9b21518ed_6185428099354103731.jpeg)

一个基于 Rsync 的自动备份管理工具，支持增量备份、定时备份、自定义 SSH 端口、开机自启、远程自动安装 rsync 等功能。

## 功能特性 v3.0

- 添加/修改/删除备份任务
- 基于 Rsync 增量同步，只传输变化部分，节省带宽
- 支持自定义 SSH 端口
- 定时自动备份（基于 cron）
- 开机自动执行备份
- 创建任务时立即执行首次备份
- 自动安装依赖（rsync、sshpass、cron）
- **新增 v3.0: 远程服务器自动检测和安装 rsync**
- **新增 v3.0: 快捷指令 `bf` 一键打开菜单**

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

运行脚本后会自动设置快捷指令 `bf`，之后可以直接使用：

```bash
bf
```

或者直接运行脚本：

```bash
sudo bash /opt/backup/backup_manager.sh
```

运行脚本后会显示菜单：

```
╔═══════════════════════════╗
║  Rsync 备份管理工具 v3.0  ║
╠═══════════════════════════╣
║                           ║
║  1. 添加备份              ║
║  2. 修改备份              ║
║  3. 删除备份              ║
║  4. 修改定时              ║
║  0. 退出脚本              ║
║                           ║
╚═══════════════════════════╝
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
| `backup_scripts/` | 自动生成的 rsync 备份脚本 |
| `backup_logs/` | 备份日志 |

## 系统要求

- Linux 系统（Debian/Ubuntu/CentOS）
- root 权限
- 支持的包管理器：apt-get、yum、dnf

## 版本更新

### v3.0 (当前版本)
- ✨ 新增：远程服务器自动检测和安装 rsync
- ✨ 新增：快捷指令 `bf` 一键打开菜单（首次运行脚本自动设置）
- ✨ 新增：远程目标目录自动创建

### v2.0
- 基础备份管理功能
- 定时备份和开机自启
- 依赖自动安装

## License

CC BY-NC-SA 4.0（知识共享 署名-非商业性使用-相同方式共享 4.0）

**禁止商业用途** - 详见 [LICENSE](./LICENSE) 文件
