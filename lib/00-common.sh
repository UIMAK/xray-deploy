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
# 通用 HTTP 下载: curl 优先, wget 兜底
# 关键: wget 只用 busybox/GNU 都支持的 -q -T -O(禁用 --show-progress/-4 等 GNU 专有选项,
# busybox wget 遇到会直接 unrecognized option 中止)。成功且文件非空才返回 0。
# 用法: _http_download <url> <dest> [timeout_sec]
# ---------------------------------------------------------------------------
_http_download() {
    local url="$1" dest="$2" timeout_s="${3:-60}"
    local dir; dir=$(dirname "$dest")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --retry 2 --max-time "$timeout_s" -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -q -T "$timeout_s" -O "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
    fi
    rm -f "$dest" 2>/dev/null
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
# 域名合法性校验(R38): 伪装域名会被拼进 inbound tag(Tunnel-<sni>-<tport>-<port>),
# tag 含空格/引号会破坏后续按 tag 的关联匹配与 Clash 条目; 从输入侧就禁止。
# 只接受 LDH 形式(字母/数字/连字符, 点分段), 单段 1-63 字符, 总长 <=253。
# ---------------------------------------------------------------------------
_validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    [ "${#d}" -le 253 ] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# ---------------------------------------------------------------------------
# 生成 Reality 的 tunnel inbound tag(R39)
# 形态: Tunnel-<sni>-<tunnel_port>-<reality_port>
# 为什么要单独封装并限长: tag 是内部标识, 不该无界地携带 display 信息。合法 SNI 最长
# 253 字符, 拼出来的 tag 可达 270+; 虽然本项目从不用 tunnel_tag 作文件名(metadata 文件名
# 是 xd-<proto>-<port>), config.json 也能容纳, 但超长 tag 会污染菜单显示、日志与人工排查,
# 且一旦将来有人拿 tag 拼路径就会撞上 NAME_MAX(255)。这里把 SNI 段截断, 使整个 tag
# <= 200 字符 —— 关联推导不受影响: 主键是 realitySettings.target 的端口, legacy 兜底按
# "-<reality_port>" 后缀匹配, 两者都不依赖 SNI 段的完整性。
# 用法: tag=$(_gen_tunnel_tag <sni> <tunnel_port> <reality_port>)
# ---------------------------------------------------------------------------
_gen_tunnel_tag() {
    local sni="$1" tport="$2" nport="$3"
    local suffix="-${tport}-${nport}"
    local max=200
    # 预算 = 200 - len("Tunnel-") - len(suffix)
    local budget=$(( max - 7 - ${#suffix} ))
    [ "$budget" -lt 8 ] && budget=8
    if [ "${#sni}" -gt "$budget" ]; then
        sni="${sni:0:$budget}"
    fi
    printf 'Tunnel-%s%s' "$sni" "$suffix"
}

# ---------------------------------------------------------------------------
# YAML 双引号标量最小转义(R38)
# clash.yaml 的 proxy 条目是单行 flow 映射, 用户可控字段(节点名/密码/SNI/地址)直接
# 插进 "..." 里。实测(pyyaml)双引号标量内只有三类字符会破坏或改变语义:
#   "  -> 提前闭合标量, 整份 YAML 不可解析(不只该节点, 导致整个订阅报错)
#   \  -> 被当作转义引导符, 值被静默改写
#   CR/LF -> 条目被截成两行, flow 映射结构损坏
# 其余(  {} , # : ' 空格 Tab 中文 )在双引号内均安全, 无需处理。
# 用法: v=$(_yaml_dq "$raw"); 输出的是"可直接放进双引号内"的内容, 不含外层引号。
# ---------------------------------------------------------------------------
_yaml_dq() {
    local s="$1"
    s="${s//\\/\\\\}"   # 反斜杠先转义(必须最先, 否则会二次转义下面新加的反斜杠)
    s="${s//\"/\\\"}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
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
    # tmp 构造必须完整成功(磁盘满/IO/配额时可能写一半), 否则 mv 会把损坏 JSON 当成正式文件提交
    tmp=$(mktemp "${target}.XXXXXX") || { _error "无法创建临时 JSON 文件: $target"; return 1; }
    if ! printf '%s' "$content" > "$tmp"; then
        rm -f "$tmp"
        _error "写入临时 JSON 文件失败: $target"
        return 1
    fi
    # R38(P1): 空内容必须拦在这里。上游普遍写成 _atomic_write_json "$f" "$(jq ...)",
    # jq 失败时命令替换为空串; 而 `jq empty` 对 0 字节/纯空白文件返回 0(不报错),
    # 于是会把空文件当合法 JSON 提交 —— 表现为"节点元数据变 0 字节却报创建成功"、
    # "config.json 被截断成 0 字节"、"回滚到空配置却报回滚成功"。
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        _error "生成的 JSON 内容为空,已放弃写入: $target"
        return 1
    fi
    # 语法校验(jq 可用时)。用 `jq -e .` 而非 `jq empty`: -e 让 null/false 也判失败,
    # 空白输入返回 4, 从而拒绝"语法上没报错但没有内容"的情况。
    if command -v jq >/dev/null 2>&1; then
        if ! jq -e . "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"
            _error "生成的 JSON 语法不合法,已放弃写入"
            return 1
        fi
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        _error "替换 JSON 文件失败: $target"
        return 1
    fi
    return 0
}

# 原子更新 JSON 文件(R15): 先 jq 变换到内存(未落地), 成功后用 _atomic_write_json 提交。
# 目标文件在失败时保持原样, 无 .tmp 残留。替代所有裸 "jq ... > tmp && mv" 写法。
# 用法: _meta_update <目标文件> <jq-filter> [jq 参数...]  (jq 参数置于 filter 前, 如 --arg l "$link")
# 返回: 0 成功; 1 jq 变换或原子写失败
_meta_update() {
    local target="$1" filter="$2"; shift 2
    local content
    content=$(jq "$@" "$filter" "$target") || { _error "元数据变换失败: $target"; return 1; }
    # R38(P1): jq 对 0 字节输入返回 0 且输出空; 空内容不得提交(会把 metadata 清成 0 字节)
    [ -n "$content" ] || { _error "元数据变换结果为空(源文件损坏?): $target"; return 1; }
    _atomic_write_json "$target" "$content"
}

# ---------------------------------------------------------------------------
# 确保部署目录结构存在
# ---------------------------------------------------------------------------
_ensure_dirs() {
    local ok=1
    for d in "$BIN_DIR" "$ASSET_DIR" "$NODES_DIR" "$CERT_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"; do
        mkdir -p "$d" || ok=0
        chmod 700 "$d" 2>/dev/null || ok=0
    done
    # 存量敏感文件收紧为仅 root 可读(私钥/密码/token; umask 只对新建文件生效, 这里回填旧文件)
    [ -f "$CONFIG_FILE" ] && { chmod 600 "$CONFIG_FILE" 2>/dev/null || ok=0; }
    local f
    for f in "$NODES_DIR"/*.json "$STATE_DIR"/cf_token "$DEPLOY_DIR"/clash.yaml; do
        [ -f "$f" ] && { chmod 600 "$f" 2>/dev/null || ok=0; }
    done
    # 安全加固是启动前提: 目录/敏感文件权限设置失败必须让初始化失败, 不能静默当作成功
    if [ "$ok" -ne 1 ]; then
        _error "目录/敏感文件权限设置失败(只读文件系统/权限异常?), 请检查后重试"
        return 1
    fi
    return 0
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
    local key="$1" val="$2" tmp
    # 严格半事务(R14): mkdir/printf/mv 任一步失败都返回 1 并清理 tmp,
    # 避免"业务成功但 state 写失败被调用方忽略"导致 service/config 与 state 状态分裂
    mkdir -p "$STATE_DIR" || return 1
    tmp="$STATE_DIR/${key}.tmp"
    if ! printf '%s' "$val" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$STATE_DIR/$key"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 配置备份/回滚(写 config.json 前调用)
# ---------------------------------------------------------------------------
_backup_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    local tmp
    # 注意: busybox/musl 的 mktemp 要求模板以 XXXXXX 结尾, 后缀必须放在 X 之前(否则 EINVAL)
    tmp=$(mktemp "${BACKUP_DIR}/config.json.bak.XXXXXX") || return 1
    cp -f "$CONFIG_FILE" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    # R38(P1): 备份必须非空——磁盘满时 cp 可能返回 0 却只落地 0 字节, 之后 _restore_config
    # 就会以"空配置"回滚。空备份视为备份失败, 由调用方中止事务。
    [ -s "$tmp" ] || { rm -f "$tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    # 备份含密码/UUID/私钥等敏感信息: chmod 600 失败视为备份失败(R13), 不能留下 0644 备份
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    # R23: lastbak 原子更新 — 先写临时文件并 chmod, 再 mv; 旧 lastbak 保持到新备份完整成功。
    # 直接 cp 覆盖在 I/O 失败时会截断 lastbak, 损坏整个 rollback 基础。
    local last_tmp
    last_tmp=$(mktemp "${BACKUP_DIR}/config.json.lastbak.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp -f "$CONFIG_FILE" "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    # R38(P1): 同上——lastbak 是回滚基础, 0 字节比"没有备份"更危险
    [ -s "$last_tmp" ] || { rm -f "$tmp" "$last_tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    chmod 600 "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    mv -f "$last_tmp" "$BACKUP_DIR/config.json.lastbak" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    # 轮转历史快照: 仅保留最新 10 份随机备份(回滚只用 lastbak, 其余仅作人工追溯)
    local old i=0
    # ls -1t 按修改时间新→旧(busybox/coreutils 均支持), 跳过 lastbak
    for old in $(ls -1t "$BACKUP_DIR" 2>/dev/null | grep '^config.json.bak.'); do
        i=$((i+1))
        [ "$i" -gt 10 ] && rm -f "$BACKUP_DIR/$old"
    done
    return 0
}

_restore_config() {
    [ -f "$BACKUP_DIR/config.json.lastbak" ] || return 1
    # R23: 原子回滚 — 直接 cp 覆盖在 I/O 失败时可能把 config 截断成半截(比回滚失败更糟);
    # 复用 _atomic_write_json(tmp 构造→校验→mv), 失败时旧 config 保持原样
    # R38(P1): 备份本身可能是 0 字节(上一次备份时磁盘满等), 必须先判非空——否则
    # "回滚"会把 config.json 变成空文件却报成功(_atomic_write_json 已补空内容拦截, 这里
    # 再前置判断以给出准确原因)。
    [ -s "$BACKUP_DIR/config.json.lastbak" ] || {
        _error "备份文件为空, 无法回滚($BACKUP_DIR/config.json.lastbak)"
        return 1
    }
    local content
    content=$(cat "$BACKUP_DIR/config.json.lastbak" 2>/dev/null) || { _error "读取备份失败($BACKUP_DIR/config.json.lastbak)"; return 1; }
    if ! _atomic_write_json "$CONFIG_FILE" "$content"; then
        _error "配置回滚失败($CONFIG_FILE)"
        return 1
    fi
    _warn "已回滚到上次配置"
    return 0
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
# R35(P2): 复用 _atomic_write_json 单一严格写入器(内存变换 -> 原子写), 不再维护第二套
# tmp/mv 逻辑; 失败时原文件保持原样, 调用方(启动/检查)均不检查返回值, 不阻塞。
# R38(P1): jq 对"只含空白的文件"不报错但输出空, 旧写法会把 config.json 截断成 0 字节。
# 现由 _atomic_write_json 的空内容拦截兜住, 这里再显式判一次以避免无谓的错误输出。
# ---------------------------------------------------------------------------
_normalize_config_format() {
    [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local content
    # 按官方顺序排已知字段, 未知字段追加到末尾, 去除 null 值; jq 失败保持原文件不动
    content=$(jq '
        . as $c |
        ('"${XRAY_TOP_FIELDS_JSON}"') as $known |
        (reduce $known[] as $k ({}; .[$k] = $c[$k]) | with_entries(select(.value != null))) as $ordered |
        ($c | to_entries | map(select(.key as $k | $known | index($k) | not)) | from_entries) as $extra |
        $ordered + $extra
    ' "$CONFIG_FILE" 2>/dev/null) || return 0
    # 变换结果为空(输入是空白/非对象): 保持原文件不动, 交由 xray 自己报配置错误
    [ -n "$content" ] || return 0
    _atomic_write_json "$CONFIG_FILE" "$content"
}

# ---------------------------------------------------------------------------
# 进程归属判定辅助(R38, M3)
# 背景: 只按 comm 全机扫描"有没有叫 xray 的进程"会把**别的**安装(从 x-ui/3x-ui 迁移的
# 残留、用户自己跑的 xray)也算成"我们的服务在跑" —— 于是本脚本的 unit 起不来也会被判
# running, _restart_xray_verified 恒成功, 直接击穿本 PR 的核心保证。
# 这两个 helper 用于把判活绑定到具体的 service 进程树上。
# ---------------------------------------------------------------------------

# 读取指定 pid 的父 pid。/proc/<pid>/stat 的 comm 字段可能含空格与括号,
# 因此从最后一个 ') ' 之后开始取字段: $1=state $2=ppid。
_proc_ppid() {
    local pid="$1" line
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    line="${line##*') '}"
    # shellcheck disable=SC2086
    set -- $line
    [ -n "${2:-}" ] || return 1
    printf '%s' "$2"
}

# 判断"以 anchor_pid 为祖先(含自身)的进程里, 是否存在 comm == name 的进程"。
# 用法: _proc_named_under <anchor_pid> <comm> [max_depth]
# openrc 的 supervise-daemon 把自身 pid 写进 pidfile, 真正的业务进程是它的子进程,
# 因此需要向上回溯 ppid 链来确认归属(默认回溯 4 层, 足够覆盖 supervisor→业务进程)。
_proc_named_under() {
    local anchor="$1" name="$2" depth="${3:-4}"
    [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
    [ "$anchor" != "0" ] || return 1
    # anchor 自身就是目标进程
    [ "$(cat "/proc/$anchor/comm" 2>/dev/null)" = "$name" ] && return 0
    local p c cur i
    for p in /proc/[0-9]*; do
        read -r c 2>/dev/null < "$p/comm" || continue
        [ "$c" = "$name" ] || continue
        cur="${p#/proc/}"
        i=0
        while [ "$i" -lt "$depth" ]; do
            cur=$(_proc_ppid "$cur") || break
            [ "$cur" = "$anchor" ] && return 0
            # 到达 init/内核态即停止回溯(写成显式 if, 不依赖 `A || B && C` 的结合律)
            if [ "$cur" = "1" ] || [ "$cur" = "0" ]; then
                break
            fi
            i=$((i+1))
        done
    done
    return 1
}

# R40: 校验 pid 的可执行文件是否就是期望的那个二进制。全机 comm 扫描的已知局限是
# "无法区分本脚本管理的实例与宿主上别人的同名进程"(x-ui/3x-ui 迁移残留、用户手跑的
# xray), 而 /proc/<pid>/exe 正好能把这个区分做出来 —— 本脚本的 unit/init 脚本里
# ExecStart / command 永远是自己生成的 $XRAY_BIN, 别人的实例不可能指向同一路径。
# fail-open 的边界要分清, 两种"读不到"不是一回事:
#   - exe 读不到(权限/内核/进程刚退出) => 放行。这是判活的最后兜底路径, 假阴性会让上层
#     认为"没在跑"而再起一个实例 → 端口冲突/双实例, 比"把别人的进程算成自己的"更糟。
#   - exe 读到了但与期望路径不同 => 拒绝, 即使期望路径本身解析不出来。此时"不同"已经是
#     确定结论, 再放行等于把这层过滤整个作废(exe=别人的路径 + 我们的二进制被删 => 误判 running)。
_proc_exe_is() {
    local pid="${1:-}" want="${2:-}" got rw
    [ -n "$want" ] || return 0                  # 未指定期望路径 => 不做这层过滤
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    got=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 0   # 读不到 => 放行
    [ -n "$got" ] || return 0
    # 就地替换二进制(升级)后, 运行中进程的 exe 链会带 " (deleted)" 后缀
    got="${got% (deleted)}"
    [ "$got" = "$want" ] && return 0
    # 路径可能经由 symlink 呈现不同前缀(如 /opt 本身是软链, exe 记录的是解析后的真实路径),
    # 把期望路径也解析一次再比。解析失败(路径不存在/断链)时以上面的字面比较为结论 => 拒绝。
    rw=$(readlink -f "$want" 2>/dev/null) || return 1
    [ -n "$rw" ] || return 1
    [ "$got" = "$rw" ] && return 0
    return 1
}

# 全机按 comm 扫描(仅作最后回退)。可选第 2 参数 = 期望的二进制路径, 传了就只认
# exe 指向该路径的进程(见 _proc_exe_is); 不传则维持"任何同名进程都算"的旧语义。
_proc_any_named() {
    local name="$1" want="${2:-}" p c pid pids
    pids=$(pidof "$name" 2>/dev/null | tr ' ' '\n' | grep -e '^[0-9][0-9]*$')
    if [ -n "$pids" ]; then
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            _proc_exe_is "$pid" "$want" && return 0
        done <<< "$pids"
        # pidof 报了同名进程但没有一个是期望的二进制: 不能就此判"没有" ——
        # busybox pidof 在部分容器里会漏报(见 _xray_is_running 坑2), 继续 /proc 扫描兜底
    fi
    for p in /proc/[0-9]*; do
        read -r c 2>/dev/null < "$p/comm" || continue
        [ "$c" = "$name" ] || continue
        _proc_exe_is "${p#/proc/}" "$want" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 任意键继续
# ---------------------------------------------------------------------------
_press_any_key() {
    echo -e "${YELLOW}按回车键继续...${NC}" >&2
    read -r
}
