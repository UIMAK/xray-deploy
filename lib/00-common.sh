#!/bin/bash
# =============================================================================
# lib/00-common.sh — 公共基础层
# 颜色 / 日志 / 常量 / 通用工具函数
# 被主脚本与所有 lib 模块 source,不直接执行。
# =============================================================================

# ---------------------------------------------------------------------------
# 常量:安装目录收口 /opt/xray-deploy(用户需求 R2)
# ---------------------------------------------------------------------------
export DEPLOY_DIR="/opt/xray-deploy"
export BIN_DIR="$DEPLOY_DIR/bin"
export ASSET_DIR="$DEPLOY_DIR/assets"          # XRAY_LOCATION_ASSET 指向此处
export CONFIG_FILE="$DEPLOY_DIR/config.json"
export NODES_DIR="$DEPLOY_DIR/nodes"           # 每节点元数据
export CERT_DIR="$DEPLOY_DIR/certs"
export LOG_DIR="$DEPLOY_DIR/logs"
export STATE_DIR="$DEPLOY_DIR/state"
export BACKUP_DIR="$STATE_DIR/backup"

export XRAY_BIN="$BIN_DIR/xray"
export XRAY_LOCATION_ASSET="$ASSET_DIR"        # 官方 docs/config/features/env.md
export GEO_LOG="$LOG_DIR/geo.log"

# cloudflared 是唯一例外,落官方默认点(不收口 /opt/xray-deploy)
export CF_BIN="/usr/local/bin/cloudflared"
export CF_UNIT_SYSTEMD="/etc/systemd/system/cloudflared.service"
export CF_UNIT_OPENRC="/etc/init.d/cloudflared"

# 脚本自身
export CMD_NAME="xd"                            # 快捷命令名(用户确认)

# GitHub 资产
export XRAY_REPO_API="https://api.github.com/repos/XTLS/Xray-core/releases"
export GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
export CF_DL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

# Xray config.json 官方顶层字段顺序(DRY: _normalize_config_format 与 _mutate_config 共用)
readonly XRAY_TOP_FIELDS_JSON='["log","api","dns","routing","policy","inbounds","outbounds","stats","fakedns","metrics","observatory","burstObservatory","geodata","version"]'

# ---------------------------------------------------------------------------
# 颜色定义(借鉴 singbox-lite,统一配色)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
SKYBLUE='\033[0;94m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# 日志打印函数(沿用 singbox-lite 命名,输出到 stderr 不污染管道)
# ---------------------------------------------------------------------------
_info()    { echo -e "${CYAN}[信息]${NC} $1" >&2; }
_success() { echo -e "${GREEN}[成功]${NC} $1" >&2; }
_warn()    { echo -e "${YELLOW}[注意]${NC} $1" >&2; }
_error()   { echo -e "${RED}[错误]${NC} $1" >&2; }
_tip()     { echo -e "${SKYBLUE}[提示]${NC} $1" >&2; }

# ---------------------------------------------------------------------------
# root 检测
# ---------------------------------------------------------------------------
_check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        _error "请以 root 用户运行本脚本"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 公网 IP 获取(直连节点链接服务器地址用)
# ---------------------------------------------------------------------------
_get_public_ip() {
    local ip url
    # IPv4 多源兜底(curl 优先, wget 兜底)
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb" "https://4.ipw.cn" "https://ipv4.icanhazip.com"; do
        ip=$(curl -s4 --max-time 6 "$url" 2>/dev/null) && [ -n "$ip" ] && \
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && \
        (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) && \
        echo "$ip" && return 0
    done
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        ip=$(wget -q -O- --timeout=6 "$url" 2>/dev/null) && [ -n "$ip" ] && \
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && \
        (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) && \
        echo "$ip" && return 0
    done
    # IPv6 兜底
    for url in "https://api64.ipify.org" "https://6.ipw.cn" "https://ipv6.icanhazip.com"; do
        ip=$(curl -s6 --max-time 6 "$url" 2>/dev/null) && [ -n "$ip" ] && echo "$ip" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# URL 编解码(节点链接生成用)
# ---------------------------------------------------------------------------
_url_encode() {
    local LC_ALL=C
    local s="$1" out="" i c o
    for ((i=0; i<${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v o '%%%02X' "'$c"; out+="$o" ;;
        esac
    done
    echo "$out"
}

_url_decode() {
    local s="$1"
    printf '%b' "${s//%/\\x}"
}

# ---------------------------------------------------------------------------
# 监听地址合法性校验(R7)
# 接受 ::、0.0.0.0、127.0.0.1、::1、具体 IPv4/IPv6;非法返回非 0
# ---------------------------------------------------------------------------
_validate_listen() {
    local addr="$1"
    [ -z "$addr" ] && return 1
    case "$addr" in
        "::"|"0.0.0.0"|"127.0.0.1"|"::1") return 0 ;;
    esac
    # IPv4 字面量
    if [[ "$addr" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
        return 0
    fi
    # IPv6 字面量(简单校验:含多个冒号且字符合法)
    if [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$addr" == *:* ]]; then
        return 0
    fi
    return 1
}

# 判断监听是否为回环(用于联动链接服务器地址 R7)
_is_listen_loopback() {
    case "$1" in
        "127.0.0.1"|"::1"|"localhost") return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 端口合法性校验
# ---------------------------------------------------------------------------
_validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# ---------------------------------------------------------------------------
# 端口占用检测(复用 singbox-lite 思路)
# ---------------------------------------------------------------------------
_check_port_occupied() {
    local port="$1" proto="${2:-}"
    local ss_opts
    case "$proto" in
        tcp) ss_opts="-ltn" ;;
        udp) ss_opts="-lun" ;;
        *)   ss_opts="-lntu" ;;
    esac
    if command -v ss >/dev/null 2>&1; then
        ss ${ss_opts} 2>/dev/null | awk '{print $5}' | grep -q ":${port}$" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat ${ss_opts} 2>/dev/null | awk '{print $4}' | grep -q ":${port}$" && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 原子写 JSON:临时文件写 + 校验 + mv(配合 xray -test)
# 用法:_atomic_write_json <目标文件> <内容>
# ---------------------------------------------------------------------------
_atomic_write_json() {
    local target="$1" content="$2" tmp
    tmp=$(mktemp "${target}.XXXXXX")
    printf '%s' "$content" > "$tmp"
    # 语法校验(jq 可用时)
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            _error "生成的 JSON 语法不合法,已放弃写入"
            return 1
        fi
    fi
    mv -f "$tmp" "$target"
}

# ---------------------------------------------------------------------------
# 确保部署目录结构存在
# ---------------------------------------------------------------------------
_ensure_dirs() {
    for d in "$BIN_DIR" "$ASSET_DIR" "$NODES_DIR" "$CERT_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"; do
        mkdir -p "$d"
    done
}

# ---------------------------------------------------------------------------
# 读取/写入状态(轻量 kv,存 state/ 下)
# 用法:_state_get <key> / _state_set <key> <value>
# ---------------------------------------------------------------------------
_state_get() {
    local key="$1"
    [ -f "$STATE_DIR/$key" ] && cat "$STATE_DIR/$key" 2>/dev/null | tr -d '\n'
}

_state_set() {
    local key="$1" val="$2"
    mkdir -p "$STATE_DIR"
    printf '%s' "$val" > "$STATE_DIR/${key}.tmp" && mv -f "$STATE_DIR/${key}.tmp" "$STATE_DIR/$key"
}

# ---------------------------------------------------------------------------
# 配置备份/回滚(写 config.json 前调用)
# ---------------------------------------------------------------------------
_backup_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    local tmp
    tmp=$(mktemp "${BACKUP_DIR}/config.json.XXXXXX.bak") || return 1
    cp -f "$CONFIG_FILE" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    cp -f "$CONFIG_FILE" "$BACKUP_DIR/config.json.lastbak" 2>/dev/null || return 1
}

_restore_config() {
    [ -f "$BACKUP_DIR/config.json.lastbak" ] || return 1
    cp -f "$BACKUP_DIR/config.json.lastbak" "$CONFIG_FILE"
    _warn "已回滚到上次配置"
}

# ---------------------------------------------------------------------------
# 随机生成(无需 Date.now/Math.random —— 用系统源)
# ---------------------------------------------------------------------------
_gen_uuid() {
    if [ -x "$XRAY_BIN" ]; then
        "$XRAY_BIN" uuid 2>/dev/null
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        # 兜底:从 /proc/sys/kernel/random/uuid(Linux)
        cat /proc/sys/kernel/random/uuid 2>/dev/null
    fi
}

_gen_short_id() {
    # 4 字节 → 8 hex
    head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8
}

_gen_rand_path() {
    # 生成随机 ws/xhttp path,如 /xxxxxxxx
    echo "/"$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
}

# ---------------------------------------------------------------------------
# 格式化 config.json: 按官方顺序重排字段 + 统一缩进
# 幂等操作, 可在启动/检查配置时安全调用
# ---------------------------------------------------------------------------
_normalize_config_format() {
    [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    # 按官方顺序排已知字段, 未知字段追加到末尾, 去除 null 值
    if jq '
        . as $c |
        ('"${XRAY_TOP_FIELDS_JSON}"') as $known |
        (reduce $known[] as $k ({}; .[$k] = $c[$k]) | with_entries(select(.value != null))) as $ordered |
        ($c | to_entries | map(select(.key as $k | $known | index($k) | not)) | from_entries) as $extra |
        $ordered + $extra
    ' "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$CONFIG_FILE"
    else
        rm -f "$tmp"
    fi
}

# ---------------------------------------------------------------------------
# 任意键继续
# ---------------------------------------------------------------------------
_press_any_key() {
    echo -e "${YELLOW}按回车键继续...${NC}" >&2
    read -r
}
