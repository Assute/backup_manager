#!/bin/bash

# ================================================
# 备份管理工具 v4.1
# 功能: 添加/修改/删除Rsync备份任务, 定时管理, 服务器列表管理
# 新增: 服务器凭据加密保存，可在添加备份时直接选择服务器列表
# ================================================

VERSION="v4.1"

# 脚本所在目录
SCRIPT_BASE_DIR="/opt/backup"
CONFIG_DIR="${SCRIPT_BASE_DIR}/backup_configs"
SCRIPT_DIR="${SCRIPT_BASE_DIR}/backup_scripts"
LOG_DIR="${SCRIPT_BASE_DIR}/backup_logs"
SERVER_DIR="${SCRIPT_BASE_DIR}/server_configs"
LOCK_DIR="${SCRIPT_BASE_DIR}/backup_locks"
SECRET_KEY_FILE="${SCRIPT_BASE_DIR}/.backup_secret.key"
INSTALLED_SCRIPT_PATH="${SCRIPT_BASE_DIR}/backup_manager.sh"
UPDATE_URL_GITHUB="https://raw.githubusercontent.com/Assute/backup_manager/main/backup_manager.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 通用工具 ====================

ensure_directories() {
    mkdir -p "$CONFIG_DIR" "$SCRIPT_DIR" "$LOG_DIR" "$SERVER_DIR" "$LOCK_DIR"
}

ensure_secret_key() {
    ensure_directories
    if [ ! -f "$SECRET_KEY_FILE" ]; then
        openssl rand -base64 48 > "$SECRET_KEY_FILE" 2>/dev/null || {
            echo -e "${RED}[✗] 无法生成加密密钥文件: ${SECRET_KEY_FILE}${NC}"
            return 1
        }
        chmod 600 "$SECRET_KEY_FILE"
    fi
}

encrypt_value() {
    local plain_text="$1"
    ensure_secret_key || return 1
    printf '%s' "$plain_text" | openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass file:"$SECRET_KEY_FILE" 2>/dev/null
}

decrypt_value() {
    local cipher_text="$1"
    if [ -z "$cipher_text" ]; then
        return 1
    fi
    [ -f "$SECRET_KEY_FILE" ] || return 1
    printf '%s' "$cipher_text" | openssl enc -aes-256-cbc -a -A -d -pbkdf2 -pass file:"$SECRET_KEY_FILE" 2>/dev/null
}

resolve_plain_password() {
    local encrypted="$1"
    local legacy_plain="$2"

    if [ -n "$encrypted" ]; then
        decrypt_value "$encrypted"
        return $?
    fi

    printf '%s' "$legacy_plain"
}

sanitize_name() {
    printf '%s' "$1" | tr -cd 'a-zA-Z0-9_-'
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_positive_integer() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]
}

format_display_label() {
    local internal_name="$1"
    local remark="$2"

    if [ -n "$remark" ]; then
        printf '%s (%s)' "$remark" "$internal_name"
    else
        printf '%s' "$internal_name"
    fi
}

build_rsync_source_path() {
    local source_path="$1"

    if [ -d "$source_path" ]; then
        printf '%s/' "${source_path%/}"
    else
        printf '%s' "$source_path"
    fi
}

normalize_compare_path() {
    local path="$1"
    path="${path%/}"
    if [ -z "$path" ]; then
        path="/"
    fi
    printf '%s' "$path"
}

is_local_host() {
    local host="$1"
    local current_host=""
    local short_host=""

    case "$host" in
        localhost|127.0.0.1|::1)
            return 0
            ;;
    esac

    current_host=$(hostname 2>/dev/null || true)
    short_host="${current_host%%.*}"

    case "$host" in
        "$current_host"|"$short_host")
            return 0
            ;;
    esac

    return 1
}

acquire_backup_lock() {
    local task_label="$1"
    local lock_name
    lock_name=$(sanitize_name "$task_label")
    [ -n "$lock_name" ] || lock_name="backup_task"

    local lock_dir="${LOCK_DIR}/${lock_name}.lock"
    local pid_file="${lock_dir}/pid"
    local old_pid=""

    mkdir -p "$LOCK_DIR"

    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$pid_file"
        printf '%s' "$lock_dir"
        return 0
    fi

    if [ -f "$pid_file" ]; then
        old_pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo -e "${YELLOW}[!] 备份任务 [${task_label}] 已在运行中，跳过本次执行${NC}" >&2
            return 1
        fi
    fi

    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$pid_file"
        printf '%s' "$lock_dir"
        return 0
    fi

    echo -e "${RED}[✗] 无法创建备份锁，请检查目录权限: ${lock_dir}${NC}" >&2
    return 1
}

release_backup_lock() {
    local lock_dir="$1"
    [ -n "$lock_dir" ] && rm -rf "$lock_dir"
}

generate_internal_name() {
    local prefix="$1"
    local target_dir="$2"
    local candidate=""

    while true; do
        candidate="${prefix}_$(date '+%Y%m%d_%H%M%S')_$RANDOM"
        if [ ! -f "${target_dir}/${candidate}.conf" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
}

get_real_path() {
    local path="$1"
    if command -v readlink &>/dev/null; then
        readlink -f "$path" 2>/dev/null || printf '%s' "$path"
    else
        printf '%s' "$path"
    fi
}

sync_script_to_installed_path() {
    local source_script="$1"
    [ -n "$source_script" ] || return 1
    [ -f "$source_script" ] || return 1

    local source_real
    local installed_real
    source_real=$(get_real_path "$source_script")
    installed_real=$(get_real_path "$INSTALLED_SCRIPT_PATH")

    if [ "$source_real" != "$installed_real" ]; then
        cp "$source_script" "$INSTALLED_SCRIPT_PATH"
        chmod +x "$INSTALLED_SCRIPT_PATH"
        echo -e "${GREEN}[✔] 脚本已覆盖安装到 ${INSTALLED_SCRIPT_PATH}${NC}"
    fi
}

download_remote_script() {
    local target_file="$1"
    local success=1

    if command -v curl &>/dev/null; then
        if curl -fsSL "$UPDATE_URL_GITHUB" -o "$target_file" 2>/dev/null; then
            success=0
        fi
    elif command -v wget &>/dev/null; then
        if wget -qO "$target_file" "$UPDATE_URL_GITHUB" 2>/dev/null; then
            success=0
        fi
    else
        echo -e "${RED}[✗] 缺少下载工具，请先安装 curl 或 wget${NC}"
        return 1
    fi

    return $success
}

rotate_log_if_needed() {
    local log_file="$1"
    local max_log_size=5242880

    if [ -f "$log_file" ]; then
        local file_size
        file_size=$(stat -c%s "$log_file" 2>/dev/null || stat -f%z "$log_file" 2>/dev/null || echo 0)
        if [ "$file_size" -gt "$max_log_size" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志已超过5MB，自动清空" > "$log_file"
        fi
    fi
}

log_message() {
    local log_file="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" >> "$log_file"
}

# ==================== 配置读写 ====================

get_config_list() {
    CONFIG_LIST=()
    if [ -d "$CONFIG_DIR" ]; then
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] && CONFIG_LIST+=("$f")
        done
    fi
}

get_server_list() {
    SERVER_LIST=()
    if [ -d "$SERVER_DIR" ]; then
        for f in "$SERVER_DIR"/*.conf; do
            [ -f "$f" ] && SERVER_LIST+=("$f")
        done
    fi
}

load_backup_config() {
    local conf="$1"
    [ -f "$conf" ] || return 1

    local BACKUP_NAME=""
    local BACKUP_REMARK=""
    local SOURCE_FOLDER=""
    local DEST_FOLDER=""
    local INTERVAL=""
    local SERVER_MODE=""
    local SERVER_NAME=""
    local HOST=""
    local PORT=""
    local USERNAME=""
    local PASSWORD=""
    local PASSWORD_ENC=""

    # shellcheck disable=SC1090
    . "$conf" || return 1

    LOADED_BACKUP_NAME="$BACKUP_NAME"
    LOADED_BACKUP_REMARK="$BACKUP_REMARK"
    LOADED_BACKUP_SOURCE_FOLDER="$SOURCE_FOLDER"
    LOADED_BACKUP_DEST_FOLDER="$DEST_FOLDER"
    LOADED_BACKUP_INTERVAL="${INTERVAL:-60}"
    LOADED_BACKUP_SERVER_MODE="${SERVER_MODE:-manual}"
    LOADED_BACKUP_SERVER_NAME="$SERVER_NAME"
    LOADED_BACKUP_HOST="$HOST"
    LOADED_BACKUP_PORT="${PORT:-22}"
    LOADED_BACKUP_USERNAME="$USERNAME"
    LOADED_BACKUP_PASSWORD="$PASSWORD"
    LOADED_BACKUP_PASSWORD_ENC="$PASSWORD_ENC"
}

load_server_config() {
    local conf="$1"
    [ -f "$conf" ] || return 1

    local SERVER_NAME=""
    local SERVER_REMARK=""
    local HOST=""
    local PORT=""
    local USERNAME=""
    local PASSWORD=""
    local PASSWORD_ENC=""

    # shellcheck disable=SC1090
    . "$conf" || return 1

    LOADED_SERVER_NAME="$SERVER_NAME"
    LOADED_SERVER_REMARK="$SERVER_REMARK"
    LOADED_SERVER_HOST="$HOST"
    LOADED_SERVER_PORT="${PORT:-22}"
    LOADED_SERVER_USERNAME="$USERNAME"
    LOADED_SERVER_PASSWORD="$PASSWORD"
    LOADED_SERVER_PASSWORD_ENC="$PASSWORD_ENC"
}

resolve_backup_runtime() {
    local conf="$1"
    RESOLVED_BACKUP_NAME=""
    RESOLVED_BACKUP_REMARK=""
    RESOLVED_SOURCE_FOLDER=""
    RESOLVED_DEST_FOLDER=""
    RESOLVED_INTERVAL=""
    RESOLVED_SERVER_MODE=""
    RESOLVED_SERVER_NAME=""
    RESOLVED_SERVER_REMARK=""
    RESOLVED_HOST=""
    RESOLVED_PORT=""
    RESOLVED_USERNAME=""
    RESOLVED_PASSWORD=""
    RESOLVED_PASSWORD_ENC=""
    RESOLVED_SERVER_LABEL=""

    load_backup_config "$conf" || return 1

    RESOLVED_BACKUP_NAME="$LOADED_BACKUP_NAME"
    RESOLVED_BACKUP_REMARK="$LOADED_BACKUP_REMARK"
    RESOLVED_SOURCE_FOLDER="$LOADED_BACKUP_SOURCE_FOLDER"
    RESOLVED_DEST_FOLDER="$LOADED_BACKUP_DEST_FOLDER"
    RESOLVED_INTERVAL="$LOADED_BACKUP_INTERVAL"
    RESOLVED_SERVER_MODE="$LOADED_BACKUP_SERVER_MODE"
        RESOLVED_SERVER_NAME="$LOADED_BACKUP_SERVER_NAME"

    if [ "$LOADED_BACKUP_SERVER_MODE" = "profile" ]; then
        local server_file="$SERVER_DIR/${LOADED_BACKUP_SERVER_NAME}.conf"
        if [ ! -f "$server_file" ]; then
            return 2
        fi

        load_server_config "$server_file" || return 1
        RESOLVED_HOST="$LOADED_SERVER_HOST"
        RESOLVED_PORT="$LOADED_SERVER_PORT"
        RESOLVED_USERNAME="$LOADED_SERVER_USERNAME"
        RESOLVED_PASSWORD="$LOADED_SERVER_PASSWORD"
        RESOLVED_PASSWORD_ENC="$LOADED_SERVER_PASSWORD_ENC"
        RESOLVED_SERVER_REMARK="$LOADED_SERVER_REMARK"
        RESOLVED_SERVER_LABEL="$LOADED_SERVER_NAME"
    else
        RESOLVED_HOST="$LOADED_BACKUP_HOST"
        RESOLVED_PORT="$LOADED_BACKUP_PORT"
        RESOLVED_USERNAME="$LOADED_BACKUP_USERNAME"
        RESOLVED_PASSWORD="$LOADED_BACKUP_PASSWORD"
        RESOLVED_PASSWORD_ENC="$LOADED_BACKUP_PASSWORD_ENC"
        RESOLVED_SERVER_REMARK=""
        RESOLVED_SERVER_LABEL=""
    fi
}

save_server_config() {
    local server_name="$1"
    local server_remark="$2"
    local host="$3"
    local port="$4"
    local username="$5"
    local password="$6"
    local encrypted_password
    local tmp_file="$SERVER_DIR/${server_name}.conf.tmp"

    encrypted_password=$(encrypt_value "$password") || {
        echo -e "  ${RED}[✗] 服务器密码加密失败${NC}"
        return 1
    }

    {
        printf 'SERVER_NAME=%q\n' "$server_name"
        printf 'SERVER_REMARK=%q\n' "$server_remark"
        printf 'HOST=%q\n' "$host"
        printf 'PORT=%q\n' "$port"
        printf 'USERNAME=%q\n' "$username"
        printf 'PASSWORD_ENC=%q\n' "$encrypted_password"
    } > "$tmp_file"

    chmod 600 "$tmp_file"
    mv "$tmp_file" "$SERVER_DIR/${server_name}.conf"
}

save_backup_config() {
    local backup_name="$1"
    local backup_remark="$2"
    local source_folder="$3"
    local dest_folder="$4"
    local interval="$5"
    local server_mode="$6"
    local server_name="$7"
    local host="$8"
    local port="$9"
    local username="${10}"
    local password="${11}"
    local tmp_file="$CONFIG_DIR/${backup_name}.conf.tmp"
    local encrypted_password=""

    if [ "$server_mode" = "manual" ]; then
        encrypted_password=$(encrypt_value "$password") || {
            echo -e "  ${RED}[✗] 服务器密码加密失败${NC}"
            return 1
        }
    fi

    {
        printf 'BACKUP_NAME=%q\n' "$backup_name"
        printf 'BACKUP_REMARK=%q\n' "$backup_remark"
        printf 'SOURCE_FOLDER=%q\n' "$source_folder"
        printf 'DEST_FOLDER=%q\n' "$dest_folder"
        printf 'INTERVAL=%q\n' "$interval"
        printf 'SERVER_MODE=%q\n' "$server_mode"

        if [ "$server_mode" = "profile" ]; then
            printf 'SERVER_NAME=%q\n' "$server_name"
        else
            printf 'HOST=%q\n' "$host"
            printf 'PORT=%q\n' "$port"
            printf 'USERNAME=%q\n' "$username"
            printf 'PASSWORD_ENC=%q\n' "$encrypted_password"
        fi
    } > "$tmp_file"

    chmod 600 "$tmp_file"
    mv "$tmp_file" "$CONFIG_DIR/${backup_name}.conf"
}

# ==================== 依赖检测 ====================

check_dependencies() {
    local missing=()

    if ! command -v rsync &>/dev/null; then
        missing+=("rsync")
    fi

    if ! command -v sshpass &>/dev/null; then
        missing+=("sshpass")
    fi

    if ! command -v crontab &>/dev/null; then
        missing+=("cron")
    fi

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        missing+=("curl")
    fi

    if ! command -v openssl &>/dev/null; then
        missing+=("openssl")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}[!] 缺少以下依赖: ${missing[*]}${NC}"
        echo -e "${CYAN}[*] 正在自动安装...${NC}"

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
                curl)
                    $pkg_cmd install -y curl &>/dev/null
                    ;;
                openssl)
                    $pkg_cmd install -y openssl &>/dev/null
                    ;;
            esac

            case "$dep" in
                rsync)   command -v rsync &>/dev/null   && echo -e "  ${GREEN}✔ rsync 安装成功${NC}"   || echo -e "  ${RED}✗ rsync 安装失败${NC}" ;;
                sshpass) command -v sshpass &>/dev/null && echo -e "  ${GREEN}✔ sshpass 安装成功${NC}" || echo -e "  ${RED}✗ sshpass 安装失败${NC}" ;;
                cron)    command -v crontab &>/dev/null && echo -e "  ${GREEN}✔ crontab 安装成功${NC}" || echo -e "  ${RED}✗ crontab 安装失败${NC}" ;;
                curl)
                    if command -v curl &>/dev/null || command -v wget &>/dev/null; then
                        echo -e "  ${GREEN}✔ 下载工具安装成功${NC}"
                    else
                        echo -e "  ${RED}✗ 下载工具安装失败${NC}"
                    fi
                    ;;
                openssl) command -v openssl &>/dev/null && echo -e "  ${GREEN}✔ openssl 安装成功${NC}" || echo -e "  ${RED}✗ openssl 安装失败${NC}" ;;
            esac
        done
    fi

    if ! systemctl is-active crond &>/dev/null && ! systemctl is-active cron &>/dev/null; then
        systemctl start crond &>/dev/null || systemctl start cron &>/dev/null
    fi

    ensure_directories
    ensure_secret_key || exit 1
}

check_runtime_dependencies() {
    local dep
    for dep in rsync sshpass ssh openssl; do
        if ! command -v "$dep" &>/dev/null; then
            echo "缺少运行依赖: $dep"
            return 1
        fi
    done

    ensure_directories
    ensure_secret_key
}

# ==================== 展示/选择函数 ====================

get_backups_using_server() {
    local server_name="$1"
    USED_BACKUPS=()

    get_config_list
    for conf in "${CONFIG_LIST[@]}"; do
        load_backup_config "$conf" || continue
        if [ "$LOADED_BACKUP_SERVER_MODE" = "profile" ] && [ "$LOADED_BACKUP_SERVER_NAME" = "$server_name" ]; then
            USED_BACKUPS+=("$(format_display_label "$LOADED_BACKUP_NAME" "$LOADED_BACKUP_REMARK")")
        fi
    done
}

list_servers() {
    get_server_list
    if [ ${#SERVER_LIST[@]} -eq 0 ]; then
        echo -e "${YELLOW}  暂无服务器配置${NC}"
        return 1
    fi

    echo ""
    printf "  ${BLUE}%-4s %-28s %-25s %-12s %-8s${NC}\n" "序号" "备注/名称" "服务器" "用户名" "引用数"
    printf "  ${BLUE}%s${NC}\n" "------------------------------------------------------------------------------------------------"

    local i=1
    for conf in "${SERVER_LIST[@]}"; do
        load_server_config "$conf" || continue
        get_backups_using_server "$LOADED_SERVER_NAME"
        local server_label
        server_label=$(format_display_label "$LOADED_SERVER_NAME" "$LOADED_SERVER_REMARK")
        printf "  %-4s %-28s %-25s %-12s %s\n" \
            "$i" "$server_label" "${LOADED_SERVER_HOST}:${LOADED_SERVER_PORT}" "$LOADED_SERVER_USERNAME" "${#USED_BACKUPS[@]}"
        ((i++))
    done
    echo ""
    return 0
}

select_server_profile() {
    local current_server_name="$1"
    local current_server_remark="$2"
    get_server_list
    if [ ${#SERVER_LIST[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}[!] 服务器列表为空，请先新增服务器${NC}"
        return 1
    fi

    list_servers || return 1

    local prompt="  请选择服务器序号"
    local server_num=""
    if [ -n "$current_server_name" ]; then
        local current_label
        current_label=$(format_display_label "$current_server_name" "$current_server_remark")
        prompt+=" [回车保持: ${current_label}]"
    fi
    prompt+=": "

    read -rp "$prompt" server_num
    if [ -z "$server_num" ] && [ -n "$current_server_name" ]; then
        local current_conf="$SERVER_DIR/${current_server_name}.conf"
        if [ -f "$current_conf" ]; then
            load_server_config "$current_conf" || return 1
            SELECTED_SERVER_NAME="$LOADED_SERVER_NAME"
            SELECTED_SERVER_REMARK="$LOADED_SERVER_REMARK"
            SELECTED_SERVER_HOST="$LOADED_SERVER_HOST"
            SELECTED_SERVER_PORT="$LOADED_SERVER_PORT"
            SELECTED_SERVER_USERNAME="$LOADED_SERVER_USERNAME"
            SELECTED_SERVER_PASSWORD="$LOADED_SERVER_PASSWORD"
            SELECTED_SERVER_PASSWORD_ENC="$LOADED_SERVER_PASSWORD_ENC"
            return 0
        fi
    fi

    if ! [[ "$server_num" =~ ^[0-9]+$ ]] || [ "$server_num" -lt 1 ] || [ "$server_num" -gt ${#SERVER_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的服务器序号${NC}"
        return 1
    fi

    local selected_conf="${SERVER_LIST[$((server_num-1))]}"
    load_server_config "$selected_conf" || return 1
    SELECTED_SERVER_NAME="$LOADED_SERVER_NAME"
    SELECTED_SERVER_REMARK="$LOADED_SERVER_REMARK"
    SELECTED_SERVER_HOST="$LOADED_SERVER_HOST"
    SELECTED_SERVER_PORT="$LOADED_SERVER_PORT"
    SELECTED_SERVER_USERNAME="$LOADED_SERVER_USERNAME"
    SELECTED_SERVER_PASSWORD="$LOADED_SERVER_PASSWORD"
    SELECTED_SERVER_PASSWORD_ENC="$LOADED_SERVER_PASSWORD_ENC"
}

prompt_manual_server_fields() {
    local default_host="$1"
    local default_port="$2"
    local default_username="$3"
    local default_password="$4"

    local host_prompt="  目标服务器IP/域名"
    local port_prompt="  SSH端口"
    local user_prompt="  目标服务器用户名"
    local pass_prompt="  服务器密码"

    [ -n "$default_host" ] && host_prompt+=" [${default_host}]"
    [ -n "$default_port" ] && port_prompt+=" [${default_port}]" || port_prompt+=" [22]"
    [ -n "$default_username" ] && user_prompt+=" [${default_username}]" || user_prompt+=" [root]"
    [ -n "$default_password" ] && pass_prompt+=" [回车保持原密码]"

    host_prompt+=": "
    port_prompt+=": "
    user_prompt+=": "
    pass_prompt+=": "

    read -rp "$host_prompt" FORM_HOST
    FORM_HOST=${FORM_HOST:-$default_host}
    if [ -z "$FORM_HOST" ]; then
        echo -e "  ${RED}[✗] 服务器地址不能为空${NC}"
        return 1
    fi

    read -rp "$port_prompt" FORM_PORT
    FORM_PORT=${FORM_PORT:-${default_port:-22}}
    if ! validate_port "$FORM_PORT"; then
        echo -e "  ${RED}[✗] 端口必须为1-65535之间的数字${NC}"
        return 1
    fi

    read -rp "$user_prompt" FORM_USERNAME
    FORM_USERNAME=${FORM_USERNAME:-${default_username:-root}}

    read -rsp "$pass_prompt" FORM_PASSWORD
    echo ""
    FORM_PASSWORD=${FORM_PASSWORD:-$default_password}
    if [ -z "$FORM_PASSWORD" ]; then
        echo -e "  ${RED}[✗] 密码不能为空${NC}"
        return 1
    fi

    FORM_SERVER_MODE="manual"
    FORM_SERVER_NAME=""
    FORM_SERVER_REMARK=""
}

prompt_backup_server_config() {
    local default_mode="$1"
    local current_server_name="$2"
    local current_server_remark="$3"
    local current_host="$4"
    local current_port="$5"
    local current_username="$6"
    local current_password="$7"

    FORM_SERVER_MODE=""
    FORM_SERVER_NAME=""
    FORM_SERVER_REMARK=""
    FORM_HOST=""
    FORM_PORT=""
    FORM_USERNAME=""
    FORM_PASSWORD=""

    get_server_list
    local can_use_profile=0
    if [ ${#SERVER_LIST[@]} -gt 0 ]; then
        can_use_profile=1
    fi

    local default_choice="1"
    if [ "$default_mode" = "profile" ] && [ $can_use_profile -eq 1 ]; then
        default_choice="2"
    fi

    echo -e "  ${CYAN}服务器配置方式:${NC}"
    echo "    1. 手动输入服务器"
    if [ $can_use_profile -eq 1 ]; then
        echo "    2. 从服务器列表选择"
    else
        echo "    2. 从服务器列表选择（当前暂无服务器配置）"
    fi

    local mode_choice=""
    read -rp "  请选择 [1/2] [默认: ${default_choice}]: " mode_choice
    mode_choice=${mode_choice:-$default_choice}

    if [ "$mode_choice" = "2" ]; then
        if [ $can_use_profile -eq 0 ]; then
            echo -e "  ${YELLOW}[!] 当前没有可选服务器，将切换为手动输入${NC}"
            prompt_manual_server_fields "$current_host" "$current_port" "$current_username" "$current_password"
            return $?
        fi

        select_server_profile "$current_server_name" "$current_server_remark" || return 1
        FORM_SERVER_MODE="profile"
        FORM_SERVER_NAME="$SELECTED_SERVER_NAME"
        FORM_SERVER_REMARK="$SELECTED_SERVER_REMARK"
        FORM_HOST="$SELECTED_SERVER_HOST"
        FORM_PORT="$SELECTED_SERVER_PORT"
        FORM_USERNAME="$SELECTED_SERVER_USERNAME"
        FORM_PASSWORD="$(resolve_plain_password "$SELECTED_SERVER_PASSWORD_ENC" "$SELECTED_SERVER_PASSWORD")"
        return 0
    fi

    if [ "$mode_choice" != "1" ]; then
        echo -e "  ${RED}[✗] 无效选项${NC}"
        return 1
    fi

    prompt_manual_server_fields "$current_host" "$current_port" "$current_username" "$current_password"
}

list_backups() {
    get_config_list
    if [ ${#CONFIG_LIST[@]} -eq 0 ]; then
        echo -e "${YELLOW}  暂无备份任务${NC}"
        return 1
    fi

    echo ""
    printf "  ${BLUE}%-4s %-28s %-22s %-12s %-36s %-8s${NC}\n" "序号" "备注/名称" "源路径" "服务器模式" "目标服务器" "间隔"
    printf "  ${BLUE}%s${NC}\n" "--------------------------------------------------------------------------------------------------------------------------------"

    local i=1
    for conf in "${CONFIG_LIST[@]}"; do
        if resolve_backup_runtime "$conf"; then
            local mode_display="手动输入"
            local target_display="${RESOLVED_HOST}:${RESOLVED_PORT}:${RESOLVED_DEST_FOLDER}"
            local backup_label
            backup_label=$(format_display_label "$RESOLVED_BACKUP_NAME" "$RESOLVED_BACKUP_REMARK")
            if [ "$RESOLVED_SERVER_MODE" = "profile" ]; then
                mode_display="服务器列表"
                local server_label
                server_label=$(format_display_label "$RESOLVED_SERVER_NAME" "$RESOLVED_SERVER_REMARK")
                target_display="${server_label}(${RESOLVED_HOST}:${RESOLVED_PORT}):${RESOLVED_DEST_FOLDER}"
            fi
            printf "  %-4s %-28s %-22s %-12s %-36s %s分钟\n" \
                "$i" "$backup_label" "$RESOLVED_SOURCE_FOLDER" "$mode_display" "$target_display" "$RESOLVED_INTERVAL"
        else
            load_backup_config "$conf" || continue
            local backup_label
            backup_label=$(format_display_label "$LOADED_BACKUP_NAME" "$LOADED_BACKUP_REMARK")
            printf "  %-4s %-28s %-22s %-12s %-36s %s分钟\n" \
                "$i" "$backup_label" "$LOADED_BACKUP_SOURCE_FOLDER" "配置异常" "服务器配置缺失" "$LOADED_BACKUP_INTERVAL"
        fi
        ((i++))
    done
    echo ""
    return 0
}

# ==================== 定时与执行 ====================

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
        local mins=$((interval % 60))
        local hours=$((interval / 60))
        echo "*/${mins} */${hours} * * *"
    fi
}

generate_backup_script() {
    local name="$1"
    local script_path="$SCRIPT_DIR/${name}.sh"

    cat > "$script_path" <<EOF
#!/bin/bash
exec bash "$INSTALLED_SCRIPT_PATH" --run "$name"
EOF

    chmod +x "$script_path"
}

add_cron_job() {
    local name="$1"
    local interval="$2"
    local script_path="$SCRIPT_DIR/${name}.sh"
    local schedule
    schedule=$(make_cron_schedule "$interval")

    remove_cron_job "$name"
    (crontab -l 2>/dev/null; echo "${schedule} ${script_path} >/dev/null 2>&1 # backup_task_${name}") | crontab -
}

remove_cron_job() {
    local name="$1"
    crontab -l 2>/dev/null | grep -v "# backup_task_${name}$" | crontab -
}

add_startup_job() {
    local name="$1"
    local script_path="$SCRIPT_DIR/${name}.sh"

    remove_startup_job "$name"
    (crontab -l 2>/dev/null; echo "@reboot sleep 30 && ${script_path} >/dev/null 2>&1 # startup_task_${name}") | crontab -
}

remove_startup_job() {
    local name="$1"
    crontab -l 2>/dev/null | grep -v "# startup_task_${name}$" | crontab -
}

run_backup_runtime_flow() {
    local source_folder="$1"
    local host="$2"
    local port="$3"
    local username="$4"
    local password="$5"
    local dest_folder="$6"
    local log_file="$7"
    local task_label="${8:-临时备份}"

    if [ -z "$source_folder" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$username" ] || [ -z "$password" ] || [ -z "$dest_folder" ]; then
        rotate_log_if_needed "$log_file"
        log_message "$log_file" "备份失败：缺少必要参数"
        echo -e "${RED}[✗] 备份参数不完整，无法执行${NC}"
        return 1
    fi

    if [ ! -e "$source_folder" ]; then
        rotate_log_if_needed "$log_file"
        log_message "$log_file" "备份失败：源路径不存在 ${source_folder}"
        echo -e "${RED}[✗] 源路径不存在: ${source_folder}${NC}"
        return 1
    fi

    local normalized_source
    local normalized_dest
    normalized_source=$(normalize_compare_path "$source_folder")
    normalized_dest=$(normalize_compare_path "$dest_folder")

    if is_local_host "$host"; then
        if [ "$normalized_source" = "$normalized_dest" ]; then
            rotate_log_if_needed "$log_file"
            log_message "$log_file" "备份失败：本机备份时目标路径不能与源路径相同"
            echo -e "${RED}[✗] 本机备份时，目标路径不能与源路径相同: ${normalized_source}${NC}"
            return 1
        fi

        case "$normalized_dest" in
            "${normalized_source}"/*)
                rotate_log_if_needed "$log_file"
                log_message "$log_file" "备份失败：本机备份时目标路径不能位于源路径内部"
                echo -e "${RED}[✗] 本机备份时，目标路径不能位于源路径内部: ${normalized_dest}${NC}"
                return 1
                ;;
        esac
    fi

    local rsync_source
    local lock_dir=""
    local result=0
    rsync_source=$(build_rsync_source_path "$source_folder")
    lock_dir=$(acquire_backup_lock "$task_label") || return 1

    rotate_log_if_needed "$log_file"
    log_message "$log_file" "开始备份 [${task_label}] ${source_folder} → ${username}@${host}:${port}:${dest_folder}"
    log_message "$log_file" "检查远程 rsync..."

    export SSHPASS="$password"

    sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no "$username@$host" "command -v rsync" &>/dev/null
    if [ $? -ne 0 ]; then
        log_message "$log_file" "远程未安装 rsync，正在安装..."

        sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no "$username@$host" <<'REMOTE_INSTALL'
if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y rsync &>/dev/null
elif command -v yum &>/dev/null; then
    yum install -y rsync &>/dev/null
elif command -v dnf &>/dev/null; then
    dnf install -y rsync &>/dev/null
elif command -v apk &>/dev/null; then
    apk add rsync &>/dev/null
fi
REMOTE_INSTALL

        sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no "$username@$host" "command -v rsync" &>/dev/null
        if [ $? -eq 0 ]; then
            log_message "$log_file" "远程 rsync 安装成功"
        else
            log_message "$log_file" "远程 rsync 安装失败，请手动检查"
            unset SSHPASS
            release_backup_lock "$lock_dir"
            return 1
        fi
    else
        log_message "$log_file" "远程已安装 rsync"
    fi

    log_message "$log_file" "检查远程目录..."
    sshpass -e ssh -p "$port" -o StrictHostKeyChecking=no "$username@$host" \
        "mkdir -p \"$dest_folder\" && chmod 755 \"$dest_folder\"" &>/dev/null

    log_message "$log_file" "开始传输文件..."
    sshpass -e rsync -avz --progress \
        -e "ssh -p $port -o StrictHostKeyChecking=no" \
        "$rsync_source" \
        "$username@$host:$dest_folder" \
        >> "$log_file" 2>&1

    result=$?
    if [ $result -eq 0 ]; then
        log_message "$log_file" "备份完成"
    else
        log_message "$log_file" "备份失败 (退出码: ${result})"
    fi

    unset SSHPASS
    release_backup_lock "$lock_dir"
    return $result
}

run_backup_task() {
    local name="$1"
    local conf="$CONFIG_DIR/${name}.conf"
    local log_file="$LOG_DIR/${name}.log"

    if [ ! -f "$conf" ]; then
        echo -e "${RED}[✗] 备份任务不存在: ${name}${NC}"
        return 1
    fi

    if ! resolve_backup_runtime "$conf"; then
        rotate_log_if_needed "$log_file"
        log_message "$log_file" "备份失败：无法读取备份配置或服务器配置缺失"
        echo -e "${RED}[✗] 备份配置异常或引用的服务器不存在: ${name}${NC}"
        return 1
    fi

    local password
    password=$(resolve_plain_password "$RESOLVED_PASSWORD_ENC" "$RESOLVED_PASSWORD") || {
        rotate_log_if_needed "$log_file"
        log_message "$log_file" "备份失败：无法解密服务器密码"
        echo -e "${RED}[✗] 无法解密服务器密码，请检查密钥文件${NC}"
        return 1
    }

    run_backup_runtime_flow \
        "$RESOLVED_SOURCE_FOLDER" \
        "$RESOLVED_HOST" \
        "$RESOLVED_PORT" \
        "$RESOLVED_USERNAME" \
        "$password" \
        "$RESOLVED_DEST_FOLDER" \
        "$log_file" \
        "$name"
}

# ==================== 服务器管理 ====================

do_add_server() {
    echo ""
    echo -e "${GREEN}========== 新增服务器 ==========${NC}"
    echo ""

    read -rp "  服务器备注（可中文，可留空）: " server_remark
    local server_name
    server_name=$(generate_internal_name "srv" "$SERVER_DIR")
    prompt_manual_server_fields "" "22" "root" "" || return

    echo ""
    echo -e "  ${CYAN}--- 确认信息 ---${NC}"
    [ -n "$server_remark" ] && echo -e "  服务器备注: ${GREEN}${server_remark}${NC}"
    echo -e "  服务器地址: ${GREEN}${FORM_HOST}:${FORM_PORT}${NC}"
    echo -e "  登录用户:   ${GREEN}${FORM_USERNAME}${NC}"
    echo ""
    read -rp "  确认添加? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"
        return
    fi

    save_server_config "$server_name" "$server_remark" "$FORM_HOST" "$FORM_PORT" "$FORM_USERNAME" "$FORM_PASSWORD" || return
    local server_label
    server_label=$(format_display_label "$server_name" "$server_remark")
    echo -e "  ${GREEN}[✔] 服务器 [${server_label}] 已加密保存${NC}"
}

do_modify_server() {
    echo ""
    echo -e "${GREEN}========== 修改服务器 ==========${NC}"

    list_servers || return

    get_server_list
    read -rp "  请输入要修改的服务器序号: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#SERVER_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"
        return
    fi

    local conf="${SERVER_LIST[$((num-1))]}"
    load_server_config "$conf" || return

    local current_password
    current_password=$(resolve_plain_password "$LOADED_SERVER_PASSWORD_ENC" "$LOADED_SERVER_PASSWORD") || current_password=""

    echo ""
    echo -e "  ${YELLOW}提示: 直接按回车保持原值不修改${NC}"
    echo ""

    local server_remark_prompt="  服务器备注（可中文，可留空）"
    [ -n "$LOADED_SERVER_REMARK" ] && server_remark_prompt+=" [${LOADED_SERVER_REMARK}]"
    server_remark_prompt+=": "
    read -rp "$server_remark_prompt" new_server_remark
    new_server_remark=${new_server_remark:-$LOADED_SERVER_REMARK}

    prompt_manual_server_fields "$LOADED_SERVER_HOST" "$LOADED_SERVER_PORT" "$LOADED_SERVER_USERNAME" "$current_password" || return
    save_server_config "$LOADED_SERVER_NAME" "$new_server_remark" "$FORM_HOST" "$FORM_PORT" "$FORM_USERNAME" "$FORM_PASSWORD" || return

    echo ""
    local server_label
    server_label=$(format_display_label "$LOADED_SERVER_NAME" "$new_server_remark")
    echo -e "  ${GREEN}[✔] 服务器 [${server_label}] 修改成功！${NC}"
}

do_delete_server() {
    echo ""
    echo -e "${GREEN}========== 删除服务器 ==========${NC}"

    list_servers || return

    get_server_list
    read -rp "  请输入要删除的服务器序号: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#SERVER_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"
        return
    fi

    local conf="${SERVER_LIST[$((num-1))]}"
    load_server_config "$conf" || return
    get_backups_using_server "$LOADED_SERVER_NAME"
    local server_label
    server_label=$(format_display_label "$LOADED_SERVER_NAME" "$LOADED_SERVER_REMARK")

    if [ ${#USED_BACKUPS[@]} -gt 0 ]; then
        echo -e "  ${YELLOW}[!] 服务器 [${server_label}] 正被以下备份任务使用:${NC}"
        printf '    - %s\n' "${USED_BACKUPS[@]}"
        echo -e "  ${YELLOW}[!] 请先修改这些备份任务，再删除服务器配置${NC}"
        return
    fi

    read -rp "  确认删除服务器 [${server_label}]? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"
        return
    fi

    rm -f "$conf"
    echo -e "  ${GREEN}[✔] 服务器 [${server_label}] 已删除${NC}"
}

show_server_menu() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════╗${NC}"
    echo -e "${BLUE}║  ${CYAN}服务器管理${BLUE}                  ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════╣${NC}"
    echo -e "${BLUE}║                              ║${NC}"
    echo -e "${BLUE}║  ${GREEN}1.${NC} 新增服务器               ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}2.${NC} 修改服务器               ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}3.${NC} 删除服务器               ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}4.${NC} 查看服务器列表           ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${RED}0.${NC} 返回上级菜单             ${BLUE}║${NC}"
    echo -e "${BLUE}║                              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════╝${NC}"
    echo ""
}

do_server_management() {
    while true; do
        clear
        show_server_menu
        read -rp "  请选择操作 [0-4]: " choice
        case "$choice" in
            1) do_add_server ;;
            2) do_modify_server ;;
            3) do_delete_server ;;
            4)
                clear
                list_servers
                read -rp "  按回车返回上级菜单..." _
                ;;
            0) return ;;
            *) echo -e "  ${RED}[✗] 无效选项，请输入 0-4${NC}" ;;
        esac
    done
}

# ==================== 备份管理 ====================

do_add_backup() {
    echo ""
    echo -e "${GREEN}========== 添加备份任务 ==========${NC}"
    echo ""

    read -rp "  备份备注（可中文，可留空）: " backup_remark
    local backup_name
    backup_name=$(generate_internal_name "bk" "$CONFIG_DIR")

    read -rp "  需要备份的路径（文件或文件夹）: " source_folder
    if [ -z "$source_folder" ]; then
        echo -e "  ${RED}[✗] 源路径不能为空${NC}"
        return
    fi

    prompt_backup_server_config "manual" "" "" "" "22" "root" "" || return

    read -rp "  目标存放目录 [默认: 原路径]: " dest_folder
    dest_folder=${dest_folder:-$source_folder}
    if [ -z "$dest_folder" ]; then
        echo -e "  ${RED}[✗] 目标目录不能为空${NC}"
        return
    fi

    read -rp "  备份间隔（分钟）[默认: 60]: " interval
    interval=${interval:-60}
    if ! validate_positive_integer "$interval"; then
        echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"
        return
    fi

    echo ""
    echo -e "  ${CYAN}--- 确认信息 ---${NC}"
    [ -n "$backup_remark" ] && echo -e "  任务备注:   ${GREEN}${backup_remark}${NC}"
    echo -e "  源路径:     ${GREEN}${source_folder}${NC}"
    if [ "$FORM_SERVER_MODE" = "profile" ]; then
        local server_label
        server_label=$(format_display_label "$FORM_SERVER_NAME" "$FORM_SERVER_REMARK")
        echo -e "  服务器来源: ${GREEN}服务器列表 / ${server_label}${NC}"
    else
        echo -e "  服务器来源: ${GREEN}手动输入${NC}"
    fi
    echo -e "  目标服务器: ${GREEN}${FORM_HOST}:${FORM_PORT}${NC}"
    echo -e "  目标用户:   ${GREEN}${FORM_USERNAME}${NC}"
    echo -e "  目标目录:   ${GREEN}${dest_folder}${NC}"
    echo -e "  备份间隔:   ${GREEN}${interval} 分钟${NC}"
    echo ""
    read -rp "  确认添加? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"
        return
    fi

    save_backup_config "$backup_name" "$backup_remark" "$source_folder" "$dest_folder" "$interval" "$FORM_SERVER_MODE" "$FORM_SERVER_NAME" "$FORM_HOST" "$FORM_PORT" "$FORM_USERNAME" "$FORM_PASSWORD" || return
    generate_backup_script "$backup_name"
    add_cron_job "$backup_name" "$interval"
    add_startup_job "$backup_name"

    echo ""
    echo -e "  ${CYAN}[*] 正在执行首次备份...${NC}"
    run_backup_task "$backup_name"
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[✔] 首次备份完成！${NC}"
    else
        echo -e "  ${YELLOW}[!] 首次备份可能失败，请检查日志: ${LOG_DIR}/${backup_name}.log${NC}"
    fi

    echo ""
    local backup_label
    backup_label=$(format_display_label "$backup_name" "$backup_remark")
    echo -e "  ${GREEN}[✔] 备份任务 [${backup_label}] 添加成功！${NC}"
    echo -e "  ${GREEN}[✔] 已设置每 ${interval} 分钟自动备份一次${NC}"
    echo -e "  ${GREEN}[✔] 已添加服务器启动自动备份${NC}"
}

do_run_backup_once() {
    echo ""
    echo -e "${GREEN}========== 临时执行一次备份 ==========${NC}"
    echo ""

    read -rp "  需要备份的路径（文件或文件夹）: " source_folder
    if [ -z "$source_folder" ]; then
        echo -e "  ${RED}[✗] 源路径不能为空${NC}"
        return
    fi

    prompt_backup_server_config "manual" "" "" "" "22" "root" "" || return

    read -rp "  目标存放目录 [默认: 原路径]: " dest_folder
    dest_folder=${dest_folder:-$source_folder}
    if [ -z "$dest_folder" ]; then
        echo -e "  ${RED}[✗] 目标目录不能为空${NC}"
        return
    fi

    echo ""
    echo -e "  ${CYAN}--- 确认信息 ---${NC}"
    echo -e "  源路径:     ${GREEN}${source_folder}${NC}"
    if [ "$FORM_SERVER_MODE" = "profile" ]; then
        local server_label
        server_label=$(format_display_label "$FORM_SERVER_NAME" "$FORM_SERVER_REMARK")
        echo -e "  服务器来源: ${GREEN}服务器列表 / ${server_label}${NC}"
    else
        echo -e "  服务器来源: ${GREEN}手动输入${NC}"
    fi
    echo -e "  目标服务器: ${GREEN}${FORM_HOST}:${FORM_PORT}${NC}"
    echo -e "  目标用户:   ${GREEN}${FORM_USERNAME}${NC}"
    echo -e "  目标目录:   ${GREEN}${dest_folder}${NC}"
    echo ""
    read -rp "  确认立即执行一次备份? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"
        return
    fi

    local log_file="${LOG_DIR}/manual_$(date '+%Y%m%d_%H%M%S').log"

    echo ""
    echo -e "  ${CYAN}[*] 正在执行临时备份...${NC}"
    run_backup_runtime_flow \
        "$source_folder" \
        "$FORM_HOST" \
        "$FORM_PORT" \
        "$FORM_USERNAME" \
        "$FORM_PASSWORD" \
        "$dest_folder" \
        "$log_file" \
        "manual_once"

    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[✔] 临时备份执行完成！${NC}"
        echo -e "  ${GREEN}[✔] 日志文件: ${log_file}${NC}"
    else
        echo -e "  ${YELLOW}[!] 临时备份执行失败，请检查日志: ${log_file}${NC}"
    fi
}

do_run_saved_backup_now() {
    echo ""
    echo -e "${GREEN}========== 立即执行已有备份任务 ==========${NC}"

    list_backups || return

    get_config_list
    read -rp "  请输入要立即执行的备份序号: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"
        return
    fi

    local conf="${CONFIG_LIST[$((num-1))]}"
    load_backup_config "$conf" || return
    local backup_name="$LOADED_BACKUP_NAME"
    local backup_label
    backup_label=$(format_display_label "$LOADED_BACKUP_NAME" "$LOADED_BACKUP_REMARK")
    local log_file="${LOG_DIR}/${backup_name}.log"

    echo ""
    echo -e "  ${CYAN}[*] 正在立即执行备份任务 [${backup_label}]...${NC}"
    run_backup_task "$backup_name"
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[✔] 备份任务 [${backup_label}] 执行完成！${NC}"
        echo -e "  ${GREEN}[✔] 日志文件: ${log_file}${NC}"
    else
        echo -e "  ${YELLOW}[!] 备份任务 [${backup_label}] 执行失败，请检查日志: ${log_file}${NC}"
    fi
}

do_modify_backup() {
    echo ""
    echo -e "${GREEN}========== 修改备份任务 ==========${NC}"

    list_backups || return

    get_config_list
    read -rp "  请输入要修改的备份序号: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"
        return
    fi

    local conf="${CONFIG_LIST[$((num-1))]}"
    load_backup_config "$conf" || return
    local resolve_status=0
    resolve_backup_runtime "$conf" >/dev/null 2>&1 || resolve_status=$?

    local current_host="$LOADED_BACKUP_HOST"
    local current_port="$LOADED_BACKUP_PORT"
    local current_username="$LOADED_BACKUP_USERNAME"
    local current_password=""
    if [ $resolve_status -eq 0 ]; then
        current_host="$RESOLVED_HOST"
        current_port="$RESOLVED_PORT"
        current_username="$RESOLVED_USERNAME"
        current_password=$(resolve_plain_password "$RESOLVED_PASSWORD_ENC" "$RESOLVED_PASSWORD" 2>/dev/null) || current_password=""
    else
        current_password=$(resolve_plain_password "$LOADED_BACKUP_PASSWORD_ENC" "$LOADED_BACKUP_PASSWORD" 2>/dev/null) || current_password=""
    fi

    echo ""
    echo -e "  ${YELLOW}提示: 直接按回车保持原值不修改${NC}"
    echo ""

    local backup_remark_prompt="  备份备注（可中文，可留空）"
    [ -n "$LOADED_BACKUP_REMARK" ] && backup_remark_prompt+=" [${LOADED_BACKUP_REMARK}]"
    backup_remark_prompt+=": "
    read -rp "$backup_remark_prompt" new_backup_remark
    new_backup_remark=${new_backup_remark:-$LOADED_BACKUP_REMARK}

    read -rp "  源目录 [${LOADED_BACKUP_SOURCE_FOLDER}]: " new_source
    new_source=${new_source:-$LOADED_BACKUP_SOURCE_FOLDER}

    read -rp "  目标存放目录 [${LOADED_BACKUP_DEST_FOLDER}]: " new_dest
    new_dest=${new_dest:-$LOADED_BACKUP_DEST_FOLDER}

    read -rp "  备份间隔(分钟) [${LOADED_BACKUP_INTERVAL}]: " new_interval
    new_interval=${new_interval:-$LOADED_BACKUP_INTERVAL}
    if ! validate_positive_integer "$new_interval"; then
        echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"
        return
    fi

    prompt_backup_server_config "$LOADED_BACKUP_SERVER_MODE" "$LOADED_BACKUP_SERVER_NAME" "$LOADED_BACKUP_SERVER_REMARK" "$current_host" "$current_port" "$current_username" "$current_password" || return

    save_backup_config "$LOADED_BACKUP_NAME" "$new_backup_remark" "$new_source" "$new_dest" "$new_interval" "$FORM_SERVER_MODE" "$FORM_SERVER_NAME" "$FORM_HOST" "$FORM_PORT" "$FORM_USERNAME" "$FORM_PASSWORD" || return
    generate_backup_script "$LOADED_BACKUP_NAME"
    add_cron_job "$LOADED_BACKUP_NAME" "$new_interval"

    echo ""
    local backup_label
    backup_label=$(format_display_label "$LOADED_BACKUP_NAME" "$new_backup_remark")
    echo -e "  ${GREEN}[✔] 备份任务 [${backup_label}] 修改成功！${NC}"
}

do_delete_backup() {
    echo ""
    echo -e "${GREEN}========== 删除备份任务 ==========${NC}"

    list_backups || return

    get_config_list
    read -rp "  请输入要删除的备份序号: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
        echo -e "  ${RED}[✗] 无效的序号${NC}"
        return
    fi

    local conf="${CONFIG_LIST[$((num-1))]}"
    load_backup_config "$conf" || return
    local backup_label
    backup_label=$(format_display_label "$LOADED_BACKUP_NAME" "$LOADED_BACKUP_REMARK")

    read -rp "  确认删除备份任务 [${backup_label}]? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"
        return
    fi

    remove_cron_job "$LOADED_BACKUP_NAME"
    remove_startup_job "$LOADED_BACKUP_NAME"
    rm -f "$conf"
    rm -f "$SCRIPT_DIR/${LOADED_BACKUP_NAME}.sh"
    rm -f "$LOG_DIR/${LOADED_BACKUP_NAME}.log"

    echo -e "  ${GREEN}[✔] 备份任务 [${backup_label}] 已删除！${NC}"
}

do_modify_schedule() {
    echo ""
    echo -e "${GREEN}========== 修改定时间隔 ==========${NC}"

    list_backups || return

    get_config_list
    echo -e "  ${CYAN}输入 0 可批量修改所有任务的间隔${NC}"
    read -rp "  请输入备份序号 (0=全部修改): " num

    if [ "$num" = "0" ]; then
        read -rp "  新的备份间隔(分钟): " new_interval
        if ! validate_positive_integer "$new_interval"; then
            echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"
            return
        fi

        for conf in "${CONFIG_LIST[@]}"; do
            load_backup_config "$conf" || continue
            sed -i "s/^INTERVAL=.*/INTERVAL=$(printf '%q' "$new_interval")/" "$conf"
            add_cron_job "$LOADED_BACKUP_NAME" "$new_interval"
            local backup_label
            backup_label=$(format_display_label "$LOADED_BACKUP_NAME" "$LOADED_BACKUP_REMARK")
            echo -e "  ${GREEN}✔ [${backup_label}] → 每 ${new_interval} 分钟${NC}"
        done
        echo ""
        echo -e "  ${GREEN}[✔] 所有任务定时已更新！${NC}"
    else
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#CONFIG_LIST[@]} ]; then
            echo -e "  ${RED}[✗] 无效的序号${NC}"
            return
        fi

        local conf="${CONFIG_LIST[$((num-1))]}"
        load_backup_config "$conf" || return

        echo -e "  当前间隔: ${YELLOW}${LOADED_BACKUP_INTERVAL} 分钟${NC}"
        read -rp "  新的备份间隔(分钟): " new_interval
        if ! validate_positive_integer "$new_interval"; then
            echo -e "  ${RED}[✗] 间隔必须为正整数${NC}"
            return
        fi

        sed -i "s/^INTERVAL=.*/INTERVAL=$(printf '%q' "$new_interval")/" "$conf"
        add_cron_job "$LOADED_BACKUP_NAME" "$new_interval"
        local backup_label
        backup_label=$(format_display_label "$LOADED_BACKUP_NAME" "$LOADED_BACKUP_REMARK")
        echo -e "  ${GREEN}[✔] [${backup_label}] 定时已修改为每 ${new_interval} 分钟${NC}"
    fi
}

# ==================== 安装与入口 ====================

ensure_script_installed() {
    ensure_directories

    local current_script="${BASH_SOURCE[0]}"
    if [ -n "$current_script" ] && [ -f "$current_script" ]; then
        sync_script_to_installed_path "$current_script"
        return
    fi

    echo -e "${CYAN}[*] 正在覆盖安装最新脚本到 ${INSTALLED_SCRIPT_PATH}...${NC}"
    if ! download_remote_script "$INSTALLED_SCRIPT_PATH"; then
            echo -e "${RED}[✗] 脚本下载失败，请检查网络或更新地址${NC}"
            return 1
    fi
    chmod +x "$INSTALLED_SCRIPT_PATH"
    echo -e "${GREEN}[✔] 脚本已覆盖安装${NC}"
}

relaunch_from_installed_script_if_needed() {
    local current_script="${BASH_SOURCE[0]}"
    local current_real
    local installed_real

    [ -n "$current_script" ] || return 0
    [ -f "$current_script" ] || return 0
    [ "${BACKUP_RELAUNCHED:-0}" = "1" ] && return 0

    current_real=$(get_real_path "$current_script")
    installed_real=$(get_real_path "$INSTALLED_SCRIPT_PATH")

    if [ "$current_real" != "$installed_real" ]; then
        export BACKUP_RELAUNCHED=1
        exec bash "$INSTALLED_SCRIPT_PATH" "$@"
    fi
}

install_shortcut() {
    cat > /usr/local/bin/bf <<'EOF'
#!/bin/bash
if [ "$(id -u)" = "0" ]; then
    exec bash /opt/backup/backup_manager.sh "$@"
elif command -v sudo &>/dev/null; then
    exec sudo bash /opt/backup/backup_manager.sh "$@"
else
    echo "请使用 root 权限运行: bash /opt/backup/backup_manager.sh"
    exit 1
fi
EOF
    chmod +x /usr/local/bin/bf
    echo -e "${GREEN}[✔] 快捷指令 'bf' 已设置！使用 ${YELLOW}bf${GREEN} 命令快速打开菜单${NC}"
    echo ""
}

do_update_script() {
    echo ""
    echo -e "${GREEN}========== 更新脚本 ==========${NC}"
    echo -e "  ${CYAN}更新源:${NC} ${UPDATE_URL_GITHUB}"
    echo ""
    read -rp "  确认从远程拉取最新脚本并覆盖本地安装? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "  ${YELLOW}已取消${NC}"
        return
    fi

    local tmp_file="${SCRIPT_BASE_DIR}/backup_manager.update.tmp"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local installed_backup="${INSTALLED_SCRIPT_PATH}.bak.${timestamp}"
    local current_script="${BASH_SOURCE[0]}"
    local current_real="$current_script"
    local installed_real="$INSTALLED_SCRIPT_PATH"

    if command -v readlink &>/dev/null; then
        current_real=$(readlink -f "$current_script" 2>/dev/null || printf '%s' "$current_script")
        installed_real=$(readlink -f "$INSTALLED_SCRIPT_PATH" 2>/dev/null || printf '%s' "$INSTALLED_SCRIPT_PATH")
    fi

    echo -e "  ${CYAN}[*] 正在下载最新脚本...${NC}"
    if ! download_remote_script "$tmp_file"; then
        rm -f "$tmp_file"
        echo -e "  ${RED}[✗] 下载失败，请检查网络或更新地址${NC}"
        return
    fi

    if ! bash -n "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        echo -e "  ${RED}[✗] 下载到的脚本语法校验失败，已取消更新${NC}"
        return
    fi

    if [ -f "$INSTALLED_SCRIPT_PATH" ]; then
        cp "$INSTALLED_SCRIPT_PATH" "$installed_backup"
        echo -e "  ${GREEN}[✔] 已备份当前安装脚本: ${installed_backup}${NC}"
    fi

    cp "$tmp_file" "$INSTALLED_SCRIPT_PATH"
    chmod +x "$INSTALLED_SCRIPT_PATH"

    if [ -n "$current_script" ] && [ -f "$current_script" ] && [ "$current_real" != "$installed_real" ]; then
        cp "$tmp_file" "$current_script"
        chmod +x "$current_script"
    fi

    rm -f "$tmp_file"
    install_shortcut

    local new_version
    new_version=$(grep -E '^VERSION=' "$INSTALLED_SCRIPT_PATH" 2>/dev/null | head -n1 | cut -d'"' -f2)
    new_version=${new_version:-未知版本}

    echo -e "  ${GREEN}[✔] 脚本更新成功！当前版本: ${new_version}${NC}"
    echo -e "  ${CYAN}[*] 正在自动重启脚本...${NC}"
    sleep 1
    exec bash "$INSTALLED_SCRIPT_PATH"
}

show_menu() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════╗${NC}"
    echo -e "${BLUE}║  ${CYAN}Rsync 备份管理工具 ${VERSION}${BLUE}     ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════╣${NC}"
    echo -e "${BLUE}║                              ║${NC}"
    echo -e "${BLUE}║  ${GREEN}1.${NC} 添加备份任务            ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}2.${NC} 临时执行一次备份        ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}3.${NC} 立即执行已有备份        ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}4.${NC} 修改备份任务            ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}5.${NC} 删除备份任务            ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}6.${NC} 修改定时                ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}7.${NC} 服务器管理              ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${GREEN}8.${NC} 更新脚本                ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${RED}0.${NC} 退出脚本                ${BLUE}║${NC}"
    echo -e "${BLUE}║                              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════╝${NC}"
    echo ""
}

handle_run_mode() {
    local backup_name="$1"
    if [ -z "$backup_name" ]; then
        echo "缺少备份任务名称"
        exit 1
    fi

    if [ "$(id -u)" != "0" ]; then
        echo "请使用 root 权限运行备份任务"
        exit 1
    fi

    check_runtime_dependencies || exit 1
    run_backup_task "$backup_name"
    exit $?
}

main() {
    if [ "$1" = "--run" ]; then
        shift
        handle_run_mode "$1"
    fi

    clear

    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}[✗] 请使用 root 权限运行此脚本！${NC}"
        echo -e "${YELLOW}    用法: sudo bash $0${NC}"
        exit 1
    fi

    check_dependencies
    ensure_script_installed || exit 1
    install_shortcut
    relaunch_from_installed_script_if_needed "$@"

    while true; do
        clear
        show_menu
        read -rp "  请选择操作 [0-8]: " choice
        case "$choice" in
            1) do_add_backup ;;
            2) do_run_backup_once ;;
            3) do_run_saved_backup_now ;;
            4) do_modify_backup ;;
            5) do_delete_backup ;;
            6) do_modify_schedule ;;
            7) do_server_management ;;
            8) do_update_script ;;
            0)
                echo ""
                echo -e "  ${GREEN}感谢使用，再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "  ${RED}[✗] 无效选项，请输入 0-8${NC}"
                ;;
        esac
    done
}

main "$@"
