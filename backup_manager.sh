#!/bin/bash

# ================================================
# 备份管理工具 v2.0
# 功能: 添加/修改/删除Rsync备份任务, 定时管理
# ================================================

# 脚本所在目录
SCRIPT_BASE_DIR="/opt/backup"
CONFIG_DIR="${SCRIPT_BASE_DIR}/backup_configs"
SCRIPT_DIR="${SCRIPT_BASE_DIR}/backup_scripts"
LOG_DIR="${SCRIPT_BASE_DIR}/backup_logs"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 依赖检测 ====================

check_dependencies() {
    echo -e "${CYAN}[*] 正在检查依赖模块...${NC}"
    local missing=()

    # 检查 rsync
    if ! command -v rsync &>/dev/null; then
        missing+=("rsync")
    else
        echo -e "  ${GREEN}✔ rsync 已安装${NC}"
    fi

    # 检查 sshpass
    if ! command -v sshpass &>/dev/null; then
        missing+=("sshpass")
    else
        echo -e "  ${GREEN}✔ sshpass 已安装${NC}"
    fi

    # 检查 crontab
    if ! command -v crontab &>/dev/null; then
        missing+=("cron")
    else
        echo -e "  ${GREEN}✔ crontab 已安装${NC}"
    fi

    # 如果有缺失的依赖，自动安装
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}[!] 缺少以下依赖: ${missing[*]}${NC}"
        echo -e "${CYAN}[*] 正在自动安装...${NC}"

        # 检测包管理器
        local pkg_cmd=""
        if command -v apt-get &>/dev/null; then
            pkg_cmd="apt-get"
            apt-get update -y -qq
        elif command -v yum &>/dev/null; then
            pkg_cmd="yum"
        elif command -v dnf &>/dev/null; then
            pkg_cmd="dnf"
        else
            echo -e "${RED}[✗] 无法识别包管理器，请手动安装: ${missing[*]}${NC}"
            exit 1
        fi

        for dep in "${missing[@]}"; do
            echo -e "${CYAN}  → 安装 ${dep}...${NC}"
            case "$dep" in
                rsync)
                    $pkg_cmd install -y rsync &>/dev/null
                    ;;
                sshpass)
                    $pkg_cmd install -y sshpass &>/dev/null
                    ;;
                cron)
                    if [ "$pkg_cmd" = "apt-get" ]; then
                        $pkg_cmd install -y cron &>/dev/null
                        systemctl enable cron &>/dev/null && systemctl start cron &>/dev/null
                    else
                        $pkg_cmd install -y cronie &>/dev/null
                        systemctl enable crond &>/dev/null && systemctl start crond &>/dev/null
                    fi
                    ;;
            esac

            # 验证安装结果
            case "$dep" in
                rsync)   command -v rsync &>/dev/null   && echo -e "  ${GREEN}✔ rsync 安装成功${NC}"   || echo -e "  ${RED}✗ rsync 安装失败${NC}" ;;
                sshpass) command -v sshpass &>/dev/null && echo -e "  ${GREEN}✔ sshpass 安装成功${NC}" || echo -e "  ${RED}✗ sshpass 安装失败${NC}" ;;
                cron)    command -v crontab &>/dev/null && echo -e "  ${GREEN}✔ crontab 安装成功${NC}" || echo -e "  ${RED}✗ crontab 安装失败${NC}" ;;
            esac
        done
    fi

    # 确保 cron 服务正在运行
    if systemctl is-active crond &>/dev/null || systemctl is-active cron &>/dev/null; then
        echo -e "  ${GREEN}✔ cron 服务运行中${NC}"
    else
        systemctl start crond &>/dev/null || systemctl start cron &>/dev/null
        echo -e "  ${YELLOW}✔ cron 服务已启动${NC}"
    fi

    # 创建必要目录
    mkdir -p "$CONFIG_DIR" "$SCRIPT_DIR" "$LOG_DIR"

    echo -e "${GREEN}[✔] 依赖检查完成！${NC}"
    echo ""
}

# ==================== 工具函数 ====================

# 获取所有配置文件列表(数组)
get_config_list() {
    CONFIG_LIST=()
    if [ -d "$CONFIG_DIR" ]; then
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] && CONFIG_LIST+=("$f")
        done
    fi
}

# 显示备份列表
list_backups() {
    get_config_list
    if [ ${#CONFIG_LIST[@]} -eq 0 ]; then
        echo -e "${YELLOW}  暂无备份任务${NC}"
        return 1
    fi

    echo ""
    printf "  ${BLUE}%-4s %-15s %-25s %-10s %-28s %-8s${NC}\n" "序号" "名称" "源路径" "用户名" "目标服务器" "间隔"
    printf "  ${BLUE}%s${NC}\n" "------------------------------------------------------------------------------------------------------"

    local i=1
    for conf in "${CONFIG_LIST[@]}"; do
        eval "$(grep -E '^(BACKUP_NAME|SOURCE_FOLDER|USERNAME|HOST|PORT|DEST_FOLDER|INTERVAL)=' "$conf")"
        PORT=${PORT:-22}
        printf "  %-4s %-15s %-25s %-10s %-28s %s分钟\n" \
            "$i" "$BACKUP_NAME" "$SOURCE_FOLDER" "$USERNAME" "${HOST}:${PORT}:${DEST_FOLDER}" "$INTERVAL"
        ((i++))
    done
    echo ""
    return 0
}

# 生成 cron 时间表达式
make_cron_schedule() {
    local interval=$1
    if [ "$interval" -le 0 ]; then
        echo "0 * * * *"
        return
    fi

    if [ "$interval" -lt 60 ]; then
        echo "*/${interval} * * * *"
    elif [ "$interval" -eq 60 ]; then
        echo "0 * * * *"
    elif [ $((interval % 60)) -eq 0 ]; then
        local hours=$((interval / 60))
        if [ "$hours" -lt 24 ]; then
            echo "0 */${hours} * * *"
        else
            echo "0 0 * * *"
        fi
    else
        # 不能整除60的分钟数，用分钟表示（cron只支持0-59，取余处理）
        local mins=$((interval % 60))
        local hours=$((interval / 60))
        echo "*/${mins} */${hours} * * *"
    fi
}

# 生成 rsync 备份脚本
generate_backup_script() {
    local name="$1"
    eval "$(grep -E '^(SOURCE_FOLDER|USERNAME|HOST|PORT|DEST_FOLDER|PASSWORD)=' "$CONFIG_DIR/${name}.conf")"
    PORT=${PORT:-22}
    local log_file="${LOG_DIR}/${name}.log"

    cat > "$SCRIPT_DIR/${name}.sh" << 'EOF'
#!/bin/bash
EOF

    cat >> "$SCRIPT_DIR/${name}.sh" << SCRIPT

# 备份任务: ${name}
# 自动生成，请勿手动修改

SOURCE_FOLDER="${SOURCE_FOLDER}"
USERNAME="${USERNAME}"
HOST="${HOST}"
PORT="${PORT}"
DEST_FOLDER="${DEST_FOLDER}"
PASSWORD="${PASSWORD}"
LOG_FILE="${log_file}"

MAX_LOG_SIZE=5242880

# 日志大小检查，超过5MB则清空
if [ -f "\$LOG_FILE" ]; then
    fsize=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || stat -f%z "\$LOG_FILE" 2>/dev/null || echo 0)
    if [ "\$fsize" -gt "\$MAX_LOG_SIZE" ]; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - 日志已超过5MB，自动清空" > "\$LOG_FILE"
    fi
fi

# 记录开始日志
echo "\$(date '+%Y-%m-%d %H:%M:%S') - 开始备份 \$SOURCE_FOLDER → \$USERNAME@\$HOST:\$PORT:\$DEST_FOLDER" >> "\$LOG_FILE"

# 使用 rsync + sshpass 进行增量备份
export SSHPASS="\$PASSWORD"
sshpass -e rsync -avz --progress \\
    -e "ssh -p \$PORT -o StrictHostKeyChecking=no" \\
    "\$SOURCE_FOLDER" \\
    "\$USERNAME@\$HOST:\$DEST_FOLDER" \\
    >> "\$LOG_FILE" 2>&1

RESULT=\$?

if [ \$RESULT -eq 0 ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 备份完成" >> "\$LOG_FILE"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 备份失败 (退出码: \$RESULT)" >> "\$LOG_FILE"
fi

unset SSHPASS
exit \$RESULT
SCRIPT

    chmod +x "$SCRIPT_DIR/${name}.sh"
}

# 添加 cron 定时任务
add_cron_job() {
    local name="$1"
    local interval="$2"
    local script_path="$SCRIPT_DIR/${name}.sh"
    local schedule
    schedule=$(make_cron_schedule "$interval")

    # 先移除旧的
    remove_cron_job "$name"

    # 添加新的定时任务
    (crontab -l 2>/dev/null; echo "${schedule} ${script_path} >/dev/null 2>&1 # backup_task_${name}") | crontab -
}

# 移除 cron 定时任务
remove_cron_job() {
    local name="$1"
    crontab -l 2>/dev/null | grep -v "# backup_task_${name}$" | crontab -
}

# 添加开机自启任务
add_startup_job() {
    local name="$1"
    local script_path="$SCRIPT_DIR/${name}.sh"

    remove_startup_job "$name"
    (crontab -l 2>/dev/null; echo "@reboot sleep 30 && ${script_path} >/dev/null 2>&1 # startup_task_${name}") | crontab -
}

# 移除开机自启任务
remove_startup_job() {
    local name="$1"
    crontab -l 2>/dev/null | grep -v "# startup_task_${name}$" | crontab -
}

# ==================== 核心功能 ====================

# 1. 添加备份
do_add_backup() {
    echo ""
    echo -e "${GREEN}========== 添加备份任务 ==========${NC}"
    echo ""

    # 任务名称
    read -rp "  备份任务名称（英文，无空格）: " backup_name
    if [ -z "$backup_name" ]; then
        echo -e "  ${RED}[✗] 名称不能为空${NC}"; return
    fi
    # 过滤非法字符
    backup_name=$(echo "$backup_name" | tr -cd 'a-zA-Z0-9_-')
    if [ -z "$backup_name" ]; then
        echo -e "  ${RED}[✗] 名称包含非法字符${NC}"; return
    fi
    if [ -f "$CONFIG_DIR/${backup_name}.conf" ]; then
        echo -e "  ${RED}[✗] 任务名称 [${backup_name}] 已存在${NC}"; return
    fi

    # 源路径（文件或文件夹）
    read -rp "  需要备份的路径（文件或文件夹）: " source_folder
    if [ -z "$source_folder" ]; then
        echo -e "  ${RED}[✗] 源路径不能为空${NC}"; return
    fi

    # 目标服务器地址
    read -rp "  目标服务器IP/域名: " host
    if [ -z "$host" ]; then
        echo -e "  ${RED}[✗] 服务器地址不能为空${NC}"; return
    fi

    # SSH端口
    read -rp "  SSH端口 [默认: 22]: " port
    port=${port:-22}
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "  ${RED}[✗] 端口必须为1-65535之间的数字${NC}"; return
    fi

    # 目标服务器用户名
    read -rp "  目标服务器用户名 [默认: root]: " username
    username=${username:-root}

    # 密码
    read -rsp "  服务器密码: " password
    echo ""
    if [ -z "$password" ]; then
        echo -e "  ${RED}[✗] 密码不能为空${NC}"; return
    fi

    # 目标目录
    read -rp "  目标存放目录: " dest_folder
    if [ -z "$dest_folder" ]; then
        echo -e "  ${RED}[✗] 目标目录不能为空${NC}"; return
    fi

    # 备份间隔
    read -rp "  备份间隔（分钟）[默认: 60]: " interval
    interval=${interval:-60}
    # 校验数字
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
        echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"; return
    fi

    echo ""
    echo -e "  ${CYAN}--- 确认信息 ---${NC}"
    echo -e "  任务名称:   ${GREEN}${backup_name}${NC}"
    echo -e "  源路径:     ${GREEN}${source_folder}${NC}"
    echo -e "  目标服务器: ${GREEN}${host}:${port}${NC}"
    echo -e "  目标用户:   ${GREEN}${username}${NC}"
    echo -e "  目标目录:   ${GREEN}${dest_folder}${NC}"
    echo -e "  备份间隔:   ${GREEN}${interval} 分钟${NC}"
    echo ""
    read -rp "  确认添加? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"; return
    fi

    # 保存配置文件
    cat > "$CONFIG_DIR/${backup_name}.conf" << EOF
BACKUP_NAME="${backup_name}"
SOURCE_FOLDER="${source_folder}"
USERNAME="${username}"
HOST="${host}"
PORT="${port}"
DEST_FOLDER="${dest_folder}"
PASSWORD="${password}"
INTERVAL="${interval}"
EOF
    chmod 600 "$CONFIG_DIR/${backup_name}.conf"

    # 生成 rsync 备份脚本
    generate_backup_script "$backup_name"

    # 添加定时任务
    add_cron_job "$backup_name" "$interval"

    # 添加开机自启
    add_startup_job "$backup_name"

    # 立即执行一次备份
    echo ""
    echo -e "  ${CYAN}[*] 正在执行首次备份...${NC}"
    "$SCRIPT_DIR/${backup_name}.sh"
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[✔] 首次备份完成！${NC}"
    else
        echo -e "  ${YELLOW}[!] 首次备份可能失败，请检查日志: ${LOG_DIR}/${backup_name}.log${NC}"
    fi

    echo ""
    echo -e "  ${GREEN}[✔] 备份任务 [${backup_name}] 添加成功！${NC}"
    echo -e "  ${GREEN}[✔] 已设置每 ${interval} 分钟自动备份一次${NC}"
    echo -e "  ${GREEN}[✔] 已添加服务器启动自动备份${NC}"
}

# 2. 修改备份
do_modify_backup() {
    echo ""
    echo -e "${GREEN}========== 修改备份任务 ==========${NC}"

    list_backups || return

    get_config_list
    read -rp "  请输入要修改的备份序号: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"; return
    fi

    local conf="${CONFIG_LIST[$((num-1))]}"
    eval "$(grep -E '^(BACKUP_NAME|SOURCE_FOLDER|USERNAME|HOST|PORT|DEST_FOLDER|PASSWORD|INTERVAL)=' "$conf")"
    PORT=${PORT:-22}

    echo ""
    echo -e "  ${YELLOW}提示: 直接按回车保持原值不修改${NC}"
    echo ""

    read -rp "  源目录 [${SOURCE_FOLDER}]: " new_source
    new_source=${new_source:-$SOURCE_FOLDER}

    read -rp "  目标服务器地址 [${HOST}]: " new_host
    new_host=${new_host:-$HOST}

    read -rp "  SSH端口 [${PORT}]: " new_port
    new_port=${new_port:-$PORT}
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "  ${RED}[✗] 端口必须为1-65535之间的数字${NC}"; return
    fi

    read -rp "  目标服务器用户名 [${USERNAME}]: " new_username
    new_username=${new_username:-$USERNAME}

    read -rsp "  服务器密码 [回车保持原密码]: " new_password
    echo ""
    new_password=${new_password:-$PASSWORD}

    read -rp "  目标存放目录 [${DEST_FOLDER}]: " new_dest
    new_dest=${new_dest:-$DEST_FOLDER}

    read -rp "  备份间隔(分钟) [${INTERVAL}]: " new_interval
    new_interval=${new_interval:-$INTERVAL}

    if ! [[ "$new_interval" =~ ^[0-9]+$ ]] || [ "$new_interval" -le 0 ]; then
        echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"; return
    fi

    # 更新配置
    cat > "$conf" << EOF
BACKUP_NAME="${BACKUP_NAME}"
SOURCE_FOLDER="${new_source}"
USERNAME="${new_username}"
HOST="${new_host}"
PORT="${new_port}"
DEST_FOLDER="${new_dest}"
PASSWORD="${new_password}"
INTERVAL="${new_interval}"
EOF
    chmod 600 "$conf"

    # 重新生成 rsync 备份脚本
    generate_backup_script "$BACKUP_NAME"

    # 更新定时任务
    add_cron_job "$BACKUP_NAME" "$new_interval"

    echo ""
    echo -e "  ${GREEN}[✔] 备份任务 [${BACKUP_NAME}] 修改成功！${NC}"
}

# 3. 删除备份
do_delete_backup() {
    echo ""
    echo -e "${GREEN}========== 删除备份任务 ==========${NC}"

    list_backups || return

    get_config_list
    read -rp "  请输入要删除的备份序号: " num

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"; return
    fi

    local conf="${CONFIG_LIST[$((num-1))]}"
    eval "$(grep -E '^BACKUP_NAME=' "$conf")"

    read -rp "  确认删除备份任务 [${BACKUP_NAME}]? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"; return
    fi

    # 移除定时任务和开机自启
    remove_cron_job "$BACKUP_NAME"
    remove_startup_job "$BACKUP_NAME"

    # 删除配置和脚本
    rm -f "$conf"
    rm -f "$SCRIPT_DIR/${BACKUP_NAME}.sh"
    rm -f "$LOG_DIR/${BACKUP_NAME}.log"

    echo -e "  ${GREEN}[✔] 备份任务 [${BACKUP_NAME}] 已删除！${NC}"
}

# 4. 修改定时
do_modify_schedule() {
    echo ""
    echo -e "${GREEN}========== 修改定时间隔 ==========${NC}"

    list_backups || return

    get_config_list
    echo -e "  ${CYAN}输入 0 可批量修改所有任务的间隔${NC}"
    read -rp "  请输入备份序号 (0=全部修改): " num

    if [ "$num" = "0" ]; then
        read -rp "  新的备份间隔(分钟): " new_interval
        if ! [[ "$new_interval" =~ ^[0-9]+$ ]] || [ "$new_interval" -le 0 ]; then
            echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"; return
        fi

        for conf in "${CONFIG_LIST[@]}"; do
            eval "$(grep -E '^BACKUP_NAME=' "$conf")"
            sed -i "s/^INTERVAL=.*/INTERVAL=\"${new_interval}\"/" "$conf"
            add_cron_job "$BACKUP_NAME" "$new_interval"
            echo -e "  ${GREEN}✔ [${BACKUP_NAME}] → 每 ${new_interval} 分钟${NC}"
        done
        echo ""
        echo -e "  ${GREEN}[✔] 所有任务定时已更新！${NC}"
    else
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
            echo -e "  ${RED}[✗] 无效的序号${NC}"; return
        fi

        local conf="${CONFIG_LIST[$((num-1))]}"
        eval "$(grep -E '^(BACKUP_NAME|INTERVAL)=' "$conf")"

        echo -e "  当前间隔: ${YELLOW}${INTERVAL} 分钟${NC}"
        read -rp "  新的备份间隔(分钟): " new_interval
        if ! [[ "$new_interval" =~ ^[0-9]+$ ]] || [ "$new_interval" -le 0 ]; then
            echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"; return
        fi

        sed -i "s/^INTERVAL=.*/INTERVAL=\"${new_interval}\"/" "$conf"
        add_cron_job "$BACKUP_NAME" "$new_interval"

        echo -e "  ${GREEN}[✔] [${BACKUP_NAME}] 定时已修改为每 ${new_interval} 分钟${NC}"
    fi
}

# ==================== 主菜单 ====================

show_menu() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════╗${NC}"
    echo -e "${BLUE}║  ${CYAN}Rsync 备份管理工具 v2.0${BLUE}  ║${NC}"
    echo -e "${BLUE}╠═══════════════════════════╣${NC}"
    echo -e "${BLUE}║                           ║${NC}"
    echo -e "${BLUE}║  ${GREEN}1.${NC} 添加备份              ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}2.${NC} 修改备份              ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}3.${NC} 删除备份              ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}4.${NC} 修改定时              ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${RED}0.${NC} 退出脚本              ${BLUE}║${NC}"
    echo -e "${BLUE}║                           ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════╝${NC}"
    echo ""
}

main() {
    clear

    # 检查 root 权限
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}[✗] 请使用 root 权限运行此脚本！${NC}"
        echo -e "${YELLOW}    用法: sudo bash $0${NC}"
        exit 1
    fi

    # 检查并安装依赖
    check_dependencies

    # 主循环
    while true; do
        show_menu
        read -rp "  请选择操作 [0-4]: " choice
        case "$choice" in
            1) do_add_backup ;;
            2) do_modify_backup ;;
            3) do_delete_backup ;;
            4) do_modify_schedule ;;
            0)
                echo ""
                echo -e "  ${GREEN}感谢使用，再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "  ${RED}[✗] 无效选项，请输入 0-4${NC}"
                ;;
        esac
    done
}

main "$@"
