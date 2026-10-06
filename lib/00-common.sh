#!/bin/bash
# =============================================================================
# lib/00-common.sh — 公共基础层
# 颜色 / 日志 / 常量 / 通用工具函数
# 被主脚本与所有 lib 模块 source,不直接执行。
# =============================================================================

# ---------------------------------------------------------------------------
# 常量:安装目录收口 /opt/xray-deploy
# ---------------------------------------------------------------------------
export DEPLOY_DIR="/opt/xray-deploy"
export BIN_DIR="$DEPLOY_DIR/bin"
export ASSET_DIR="$DEPLOY_DIR/assets"          # 资源目录(geoip.dat/geosite.dat)
export CONFIG_DIR="$DEPLOY_DIR/confs"          # 多文件配置目录: 一个顶层字段一个文件
export LEGACY_CONFIG_FILE="$DEPLOY_DIR/config.json"   # 旧版单文件配置; 仅迁移时读一次
export NODES_DIR="$DEPLOY_DIR/nodes"           # 每节点元数据
export CERT_DIR="$DEPLOY_DIR/certs"
export LOG_DIR="$DEPLOY_DIR/logs"
export STATE_DIR="$DEPLOY_DIR/state"
export BACKUP_DIR="$STATE_DIR/backup"

export XRAY_BIN="$BIN_DIR/xray"
# XRAY_LOCATION_ASSET: 核心 ≥ v26.7.11 读 config 的 env 段, 旧核心由 service 文件注入
# (见 20-xray-core)。这里只是脚本自身调用(xray -test / direct 启动)的进程级回退。
export XRAY_LOCATION_ASSET="$ASSET_DIR"
export GEO_LOG="$LOG_DIR/geo.log"

# cloudflared 是唯一例外,落官方默认点(不收口 /opt/xray-deploy)
export CF_BIN="/usr/local/bin/cloudflared"
export CF_UNIT_SYSTEMD="/etc/systemd/system/cloudflared.service"
export CF_UNIT_OPENRC="/etc/init.d/cloudflared"

# ---------------------------------------------------------------------------
# 锁根固定在部署树外, 卸载不能拆开锁 inode; 不接受环境变量覆盖。
# /var/lock 创建失败退 /run/lock, 均失败返回前者让调用方 fail-closed; 见 install.sh _install_lock_root。
# ---------------------------------------------------------------------------
_deploy_lock_root() {
    if mkdir -p /var/lock/xray-deploy 2>/dev/null; then printf '%s' "/var/lock/xray-deploy"; return 0; fi
    if mkdir -p /run/lock/xray-deploy 2>/dev/null; then printf '%s' "/run/lock/xray-deploy"; return 0; fi
    printf '%s' "/var/lock/xray-deploy"
}


# Primary lock interlock: flock holders also own the fallback directory; mkdir holders
# reserve it first and then inspect open flock descriptors. This closes the mixed-backend
# check/acquire race without changing either backend's normal stale-lock policy.
_xray_primary_flock_marker_take() {  # <fd> <lock-file> <fallback-dir> <label>; caller holds flock
    local fd="$1" lock_file="$2" lock_dir="$3" label="$4" devino witness owner i
    [ -n "$fd" ] && [ -e "$lock_file" ] || { _error "${label} flock 文件/FD 不可用"; return 1; }
    devino=$(stat -c '%d:%i' "$lock_file" 2>/dev/null) || devino=""
    [ -n "$devino" ] || { _error "无法读取${label} flock 文件标识, 放弃操作"; return 1; }
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if mkdir "$lock_dir" 2>/dev/null; then
            owner="${BASHPID:-$$}"
            if printf '%s\n' "$owner" > "$lock_dir/pid" 2>/dev/null \
               && printf '%s\n' "$devino" > "$lock_dir/.witness" 2>/dev/null \
               && [ "$(cat "$lock_dir/.witness" 2>/dev/null)" = "$devino" ]; then
                return 0
            fi
            [ "$(cat "$lock_dir/pid" 2>/dev/null)" = "$owner" ] && rm -rf "$lock_dir" 2>/dev/null
            _error "无法建立${label}跨后端见证标记: $lock_dir"
            return 1
        fi
        if [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] \
           && [ -f "$lock_dir/.witness" ] && [ ! -L "$lock_dir/.witness" ]; then
            witness=$(cat "$lock_dir/.witness" 2>/dev/null) || witness=""
            if [ "$witness" = "$devino" ]; then
                # Exclusive flock proves no previous flock owner remains; mkdir-only owners
                # never write this inode witness, so only our interrupted marker is removable.
                if rm -rf "$lock_dir" 2>/dev/null && [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
                    continue
                fi
                _error "无法清理${label}陈旧 flock 见证标记: $lock_dir"
                return 1
            fi
            _error "${label}锁目录见证身份不符, 拒绝接管: $lock_dir"
            return 1
        fi
        sleep 1
    done
    _error "等待${label} mkdir 后端互斥超时或发现残留锁: $lock_dir"
    return 1
}

_xray_primary_flock_marker_release() {  # <lock-file> <fallback-dir> <label>
    local lock_file="$1" lock_dir="$2" label="$3" devino owner witness
    [ -d "$lock_dir" ] || { _error "${label}见证目录丢失: $lock_dir"; return 1; }
    owner=$(cat "$lock_dir/pid" 2>/dev/null) || owner=""
    witness=$(cat "$lock_dir/.witness" 2>/dev/null) || witness=""
    devino=$(stat -c '%d:%i' "$lock_file" 2>/dev/null) || devino=""
    if [ "$owner" != "${BASHPID:-$$}" ] || [ -z "$devino" ] || [ "$witness" != "$devino" ]; then
        _error "${label}见证标记归属/身份校验失败, 保留: $lock_dir"
        return 1
    fi
    if ! rm -rf "$lock_dir" 2>/dev/null || [ -e "$lock_dir" ] || [ -L "$lock_dir" ]; then
        _error "无法删除${label}见证标记: $lock_dir"
        return 1
    fi
    return 0
}

# 脚本自身
export CMD_NAME="xd"                            # 快捷命令名(用户确认)

# GitHub 资产
export XRAY_REPO_API="https://api.github.com/repos/XTLS/Xray-core/releases"
export GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
export CF_DL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"


# ---------------------------------------------------------------------------
# 默认 dns 段(唯一真相): _init_config_if_empty(20-xray-core) 与 DNS 菜单的
# [恢复默认](30-geo) 共用, **绝不允许任一侧另写一份**。
# 三个 https+local:// 直连 DoH 上游策略相同且不单设 tag, 同组竞速首个成功响应(dns.md)。
# ---------------------------------------------------------------------------
readonly XRAY_DEFAULT_DNS_JSON='{
    "enableParallelQuery": true,
    "queryStrategy": "UseIP",
    "servers": [
      {
        "address": "https+local://cloudflare-dns.com/dns-query"
      },
      {
        "address": "https+local://dns.quad9.net/dns-query"
      },
      {
        "address": "https+local://freedns.controld.com/p0"
      }
    ],
    "tag": "dns_inbound",
    "useSystemHosts": false
  }'

# ---------------------------------------------------------------------------
# 默认 routing 规则集(唯一真相): _init_config_if_empty(20-xray-core) 与
# _route_restore_default_rules(30-geo) 共用, **绝不允许任一侧另写一份**。
# 4 条中只有第 2、3 条会让 Xray 加载 geosite.dat/geoip.dat(各 ~20MB+), 这正是
# Geo 自动更新 → [路由规则] 精简 要摘掉的两条(见 XRAY_PRIVATE_BLOCK_RULE_JSON)。
# regexp 内 \\d / \\. 是 JSON 转义后的单个反斜杠(单引号防 bash 再吃一层)。
# ---------------------------------------------------------------------------
readonly XRAY_DEFAULT_ROUTING_RULES_JSON='[
  {
    "protocol": [
      "bittorrent"
    ],
    "outboundTag": "block"
  },
  {
    "domain": [
      "geosite:category-ads-all",
      "geosite:private"
    ],
    "outboundTag": "block"
  },
  {
    "ip": [
      "geoip:private",
      "geoip:cn"
    ],
    "outboundTag": "block"
  },
  {
    "domain": [
      "pypi.org",
      "unpkg.com",
      "debian.org",
      "github.com",
      "nodejs.org",
      "ubuntu.com",
      "kali.download",
      "pypi.python.org",
      "ssl.gstatic.com",
      "www.gstatic.com",
      "cp.cloudflare.com",
      "dockerstatic.com",
      "fonts.gstatic.com",
      "registry.npmjs.org",
      "cdnjs.cloudflare.com",
      "githubusercontent.com",
      "www.msftconnecttest.com",
      "regexp:^(mt|khm)\\d?\\.google\\.com$",
      "regexp:(gstatic|fonts|dl|ajax)\\.google(apis)?\\.com$"
    ],
    "outboundTag": "direct"
  }
]'

# ---------------------------------------------------------------------------
# 私网/保留地址 block 规则: 用字面量 CIDR 等价替换 "geoip:private"。精简掉引用 geo 的规则
# 后原 ip 段一并消失, 客户端就能借节点访问本机私网与云元数据(169.254.169.254); 写死
# private 段即可保住防护且**不加载 geoip.dat**。CIDR 取自 v2fly/geoip private 列表原文。
# ruleTag 是所有权标记: 精简/恢复都靠它精确增删(Xray 支持, 老核心忽略未知字段)。
# ---------------------------------------------------------------------------
readonly XRAY_PRIVATE_BLOCK_RULE_TAG="xd-block-private"
readonly XRAY_PRIVATE_BLOCK_RULE_JSON='{
  "ruleTag": "xd-block-private",
  "ip": [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "255.255.255.255/32",
    "::/128",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8"
  ],
  "outboundTag": "block"
}'

# Xray log.loglevel 合法取值。核心对未识别值静默回落 warning, 校验必须由脚本自己做。
# "none" 同时停写 error 与 access 两个日志(infra/conf/log.go)。
readonly XRAY_LOG_LEVELS="debug info warning error none"

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
        ip=$(curl -fsS4 --max-time 6 "$url" 2>/dev/null) && [ -n "$ip" ] && \
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && \
        (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 )) && \
        echo "$ip" && return 0
    done
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        # 与 _http_download 同一口径: --timeout 是 GNU 长选项, busybox wget 可能 unrecognized option , 用 -T
        ip=$(wget -q -T 6 -O- "$url" 2>/dev/null) && [ -n "$ip" ] && \
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && \
        (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 )) && \
        echo "$ip" && return 0
    done
    # IPv6 兜底 —— **必须校验字面量**(#06): 只判非空会把错误页/代理提示写进分享链接。
    for url in "https://api64.ipify.org" "https://6.ipw.cn" "https://ipv6.icanhazip.com"; do
        ip=$(curl -fsS6 --max-time 6 "$url" 2>/dev/null) && _is_ipv6_literal "$ip" && echo "$ip" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 通用 HTTP 下载: curl 优先, wget 兜底。wget 只用 busybox/GNU 都支持的 -q -T -O
# (GNU 专有选项会让 busybox wget unrecognized option 中止)。成功且文件非空才返回 0。
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
# 按 od 输出的字节编码, 不依赖 libc/locale 的字符语义。
# 字母/数字/.~_- 保留字面量, 其余字节编码为 %XX 大写十六进制。
# ---------------------------------------------------------------------------
_url_encode() {
    local s="$1" hex out="" b oct c o
    hex=$(printf '%s' "$s" | od -An -v -tx1 | tr -d ' \n')
    while [ -n "$hex" ]; do
        b=$((16#${hex:0:2})); hex="${hex:2}"
        if [ $(( (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 46 || b == 126 || b == 95 || b == 45 )) -eq 1 ]; then
            # 字面字符渲染: \xHH 与 %02x 相邻会让 printf 把 % 当 hex digit 报错,
            # 用 %b + 八进制两步构造(\141 -> a), 无子 shell
            printf -v oct '%03o' "$b"
            printf -v c '%b' "\\${oct}"
            out+="$c"
        else
            printf -v o '%%%02X' "$b"
            out+="$o"
        fi
    done
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# IPv6 字面量校验(严格到足以拦住 xray 启动才报错的畸形输入)
# 规则: 至多一个 "::"(至多 2 个空字段); 有 "::" 时非空段 ≤7, 无 "::" 时恰好 8 段;
# 每段 1-4 位 hex; 允许尾部内嵌 IPv4(::ffff:1.2.3.4), 但纯 IPv4 不算 IPv6。
# ---------------------------------------------------------------------------
_is_ipv6_literal() {
    local a="$1" tail head
    [ -n "$a" ] || return 1
    case "$a" in
        *"."*)
            tail="${a##*:}"; head="${a%:*}"
            [[ "$tail" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
            (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 )) || return 1
            [ "$head" = "$a" ] && return 1     # 纯 IPv4 由 IPv4 分支处理
            a="${head}:0:0"                     # 内嵌 IPv4 占两段, 参与结构校验
            ;;
    esac
    # 连续 3 个及以上冒号一律非法。**必须先拦这一条**: ${a//::/} 计数与按段切分各自都
    # 看不出 "1:::2" 畸形(dbl=1、empty=2 都通过)。
    case "$a" in *:::* ) return 1 ;; esac
    # 单个前导/尾随冒号也必须拒绝: 它只贡献 1 个空字段且不产生 "::", 两条守卫都会放行。
    # 判据: 单个 ':' 开头(后一个不是 ':')或单个 ':' 结尾(前一个不是 ':')。
    case "$a" in
        :[!:]*|*[!:]:) return 1 ;;
    esac
    # 统计非重叠 "::" 出现次数(此时已保证不存在 ":::")
    local stripped="${a//::/}"
    local dbl=$(( (${#a} - ${#stripped}) / 2 ))
    [ "$dbl" -le 1 ] || return 1
    local IFS=':' seg count=0 empty=0
    local -a parts
    read -ra parts <<< "$a"
    for seg in "${parts[@]}"; do
        if [ -z "$seg" ]; then empty=$((empty+1)); continue; fi
        [[ "$seg" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        count=$((count+1))
    done
    [ "$empty" -le 2 ] || return 1
    if [ "$dbl" -eq 1 ]; then
        [ "$count" -le 7 ] || return 1
    else
        [ "$count" -eq 8 ] || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 监听地址合法性校验
# 接受 ::、0.0.0.0、127.0.0.1、::1、具体 IPv4/IPv6;非法返回非 0
# ---------------------------------------------------------------------------
_validate_listen() {
    local addr="$1" oct
    [ -z "$addr" ] && return 1
    case "$addr" in
        *[[:space:]]*) return 1 ;;
    esac
    case "$addr" in
        "::"|"0.0.0.0"|"127.0.0.1"|"::1") return 0 ;;
    esac
    # IPv4 字面量(规范十进制八位组, 每段 0-255; 拒绝前导零, 避免 bash 八进制解释)
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for oct in "${BASH_REMATCH[@]:1}"; do
            [[ "$oct" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
            (( oct <= 255 )) || return 1
        done
        return 0
    fi
    # IPv6 字面量(严格校验, 见 _is_ipv6_literal)
    _is_ipv6_literal "$addr" && return 0
    return 1
}

# 判断监听是否为回环，用于联动链接服务器地址。
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
    # 只接受规范十进制: 前导零不是合法 JSON 整数, 且未校验的超长串会溢出 bash 算术。
    [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    [ "$p" -le 65535 ]
}

# 菜单序号 -> 零基数组下标, 不把未校验输入直接进 shell 算术。
# 输出到 stdout; 拒绝 0、溢出与越界。
_xd_index_from_choice() {
    local choice="${1:-}" total="${2:-}" zeros n max
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    zeros="${choice%%[!0]*}"
    n="${choice#"$zeros"}"
    [ -n "$n" ] || return 1
    [ "${#n}" -le 6 ] || return 1
    [ "${#total}" -le 6 ] || return 1
    max=$((10#$total))
    [ "$max" -gt 0 ] || return 1
    local value=$((10#$n))
    [ "$value" -ge 1 ] && [ "$value" -le "$max" ] || return 1
    printf '%s' "$((value - 1))"
}

# ---------------------------------------------------------------------------
# 域名合法性校验: 伪装域名会被拼进 inbound tag, tag 含空格/引号会破坏按 tag 的关联
# 匹配与 Clash 条目, 故从输入侧禁止。只接受 LDH 形式, 单段 1-63, 总长 ≤253。
# ---------------------------------------------------------------------------
_validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    [ "${#d}" -le 253 ] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# ---------------------------------------------------------------------------
# JSON 模板值拒绝引号、反斜杠、换行/制表符与 {{, 防止非法 JSON 或二次替换。
# 用法: _validate_json_text <值>  非法返回 1
# ---------------------------------------------------------------------------
_validate_json_text() {
    case "$1" in
        *'"'*|*'\'*|*$'\n'*|*$'\r'*|*$'\t'*|*"{{"*) return 1 ;;
    esac
    # 其余控制字符(0x01-0x1F 中未被上面覆盖的)与 DEL(0x7F)不是合法 JSON 字符串字面量,
    # 同样会被原样拼进模板。NUL 无法存在于 bash 变量, 故区间从 0x01 起。
    # shellcheck disable=SC1010
    case "$1" in
        *[$'\x01'-$'\x1f'$'\x7f']*) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Reality tunnel tag: Tunnel-<sni>-<tunnel_port>-<reality_port>; 截断 SNI 使总长 ≤200。
# 关联按 realitySettings.target 端口与 legacy 后缀推导, 不依赖完整显示域名。
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
# YAML 双引号标量转义: 处理引号、反斜杠与 CR/LF, 防止闭合/改写/截断条目。
# 用法: v=$(_yaml_dq "$raw"); 输出可直接放进双引号内, 不含外层引号。
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
# ss 同时列 TCP+UDP 时会多一个 Netid 列, Local Address:Port 从 $4 移到 $5; 故分别查询
# 每种协议保持列布局一致。空协议表示检查 TCP 与 UDP 两者。
# ---------------------------------------------------------------------------
_check_port_occupied() {
    local port="$1" proto="${2:-}"
    local ss_opts netstat_opts
    if command -v ss >/dev/null 2>&1; then
        case "$proto" in
            tcp) ss_opts="-ltn" ;;
            udp) ss_opts="-lun" ;;
            *)
                for ss_opts in -ltn -lun; do
                    ss $ss_opts 2>/dev/null | awk -v p="$port" 'NR > 1 { a=$4; sub(/^.*:/,"",a); if (a == p) found=1 } END { exit !found }' && return 0
                done
                return 1 ;;
        esac
        ss $ss_opts 2>/dev/null | awk -v p="$port" 'NR > 1 { a=$4; sub(/^.*:/,"",a); if (a == p) found=1 } END { exit !found }' && return 0
    elif command -v netstat >/dev/null 2>&1; then
        case "$proto" in
            tcp) netstat_opts="-lnt" ;;
            udp) netstat_opts="-lnu" ;;
            *)
                for netstat_opts in -lnt -lnu; do
                    netstat $netstat_opts 2>/dev/null | awk -v p="$port" 'NR > 1 { a=$4; sub(/^.*:/,"",a); if (a == p) found=1 } END { exit !found }' && return 0
                done
                return 1 ;;
        esac
        netstat $netstat_opts 2>/dev/null | awk -v p="$port" 'NR > 1 { a=$4; sub(/^.*:/,"",a); if (a == p) found=1 } END { exit !found }' && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# rename 只保证原子可见性; 持久化须先刷临时文件, rename 后再刷父目录。
# 按平台尝试 sync <path>(coreutils ≥8.24 / BusyBox ≥1.31)、sync -f(GNU)、全系统 sync。
# best-effort: 任一步成功返回 0, 全失败才告警。
# ---------------------------------------------------------------------------
_fsync_path() {   # <path>
    local p="$1"
    [ -n "$p" ] || return 0
    sync "$p" >/dev/null 2>&1 && return 0
    sync -f "$p" >/dev/null 2>&1 && return 0
    sync >/dev/null 2>&1 && return 0
    _warn "无法把 $p 刷入持久存储(平台不支持按路径 fsync), 掉电一致性降级"
    return 1
}

# ---------------------------------------------------------------------------
# 原子写 JSON: 临时文件写 + 校验 + fsync + mv + 目录 fsync(配合 xray -test)
# 用法: _atomic_write_json <目标文件> <内容>
# 事务账本(phase barrier)、config 与节点元数据的**唯一**提交点, 持久化屏障只加这里。
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
    # 拒绝空内容: jq 对零字节输入可能成功却无输出, 不得据此截断配置/元数据。
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
    # 校验全部通过后才刷: 刷一个马上要丢弃的临时文件是白等。数据块必须先于 rename 落盘,
    # 否则 rename 后断电可能留下"新名字 + 空内容"。
    _fsync_path "$tmp"
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        _error "替换 JSON 文件失败: $target"
        return 1
    fi
    # rename 之后刷**父目录**: 让新目录项本身落盘。
    _fsync_path "$(dirname "$target")"
    return 0
}

# 原子更新 JSON 文件: 先 jq 变换到内存, 成功后用 _atomic_write_json 提交。
# 目标文件失败时保持原样, 无 .tmp 残留。替代所有裸 "jq ... > tmp && mv"。
# 用法: _meta_update <目标文件> <jq-filter> [jq 参数...]  (jq 参数置于 filter 前)
# 返回: 0 成功; 1 jq 变换或原子写失败
_meta_update() {
    local target="$1" filter="$2"; shift 2
    local content
    content=$(jq "$@" "$filter" "$target") || { _error "元数据变换失败: $target"; return 1; }
    # jq 对 0 字节输入返回 0 且输出空; 空内容不得提交(会把 metadata 清成 0 字节)
    [ -n "$content" ] || { _error "元数据变换结果为空(源文件损坏?): $target"; return 1; }
    _atomic_write_json "$target" "$content"
}

# ---------------------------------------------------------------------------
# 多文件配置(confs 目录): 一个顶层字段一个文件, 文件名固定。
# 管理器仅管理 *.json 的一字段一文件布局; Xray confdir 本身也支持 *.jsonc。
# ---------------------------------------------------------------------------
_conf_file_for_field() {   # <顶层字段> → <文件名>
    case "$1" in
        env) printf '01_env.json' ;;
        log) printf '02_log.json' ;;
        api) printf '03_api.json' ;;
        dns) printf '04_dns.json' ;;
        routing) printf '05_routing.json' ;;
        policy) printf '06_policy.json' ;;
        inbounds) printf '07_inbounds.json' ;;
        outbounds) printf '08_outbounds.json' ;;
        stats) printf '09_stats.json' ;;
        fakedns) printf '10_fakedns.json' ;;
        metrics) printf '11_metrics.json' ;;
        observatory) printf '12_observatory.json' ;;
        burstObservatory) printf '13_burstObservatory.json' ;;
        geodata) printf '14_geodata.json' ;;
        version) printf '15_version.json' ;;
        *) printf '99_%s.json' "$1" ;;
    esac
}

# confs 里是否至少有一个非空配置文件。空目录会让 xray 转去读 STDIN 并以晦涩错误失败,
# 故所有"配置是否存在"的守卫都走这里。
_config_present() {
    local f
    for f in "$CONFIG_DIR"/*.json; do
        [ -f "$f" ] && [ -s "$f" ] && return 0
    done
    return 1
}

# 管理器只支持每个顶层字段一份片段; 重复字段使用核心的另一套合并语义, 不可覆盖回写。
_config_layout_valid() {
    local dir="${1:-$CONFIG_DIR}" repair="${2:-}" keys='[]' f fields
    for f in "$dir"/*.json; do
        [ -f "$f" ] && [ -s "$f" ] || continue
        if ! fields=$(jq -e 'if type == "object" then keys else error("配置片段必须是 object") end' "$f" 2>/dev/null); then
            # 完整快照回写允许替换损坏文件; 正常读取仍须拒绝。
            [ "$repair" = repair ] && continue
            _error "配置片段无法解析: $f"
            return 1
        fi
        keys=$(jq -cn --argjson a "$keys" --argjson b "$fields" '$a + $b') || return 1
    done
    if ! printf '%s' "$keys" | jq -e 'group_by(.) | all(.[]; length == 1)' >/dev/null; then
        _error "配置片段含重复顶层字段, 拒绝修改: $dir"
        return 1
    fi
}

# 合并管理器的一字段一文件布局(输出到 stdout)。
_config_merged() {
    _config_layout_valid || return 1
    local files=()
    local f
    for f in "$CONFIG_DIR"/*.json; do
        [ -f "$f" ] && [ -s "$f" ] && files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        printf '{}'
        return 0
    fi
    jq -s 'reduce .[] as $o ({}; reduce ($o | to_entries[]) as $e (.; .[$e.key] = $e.value))' "${files[@]}"
}

# 在合并视图上跑 jq: 参数与 jq 完全一致(jq 选项在前, filter 在最后), 输入改为合并后的配置。
# 用法: _config_jq [-r] [--arg k v ...] '<filter>'
_config_jq() {
    [ "$#" -ge 1 ] || return 1
    local filter="${!#}" opts=() merged
    [ "$#" -gt 1 ] && opts=("${@:1:$#-1}")
    # 先检查合并返回码再调用 jq; 无 pipefail 的管道会掩盖读取失败并误判为空配置。
    merged=$(_config_merged) || return 1
    if [ "${#opts[@]}" -gt 0 ]; then
        printf '%s' "$merged" | jq "${opts[@]}" "$filter"
    else
        printf '%s' "$merged" | jq "$filter"
    fi
}

# 把一份完整配置拆回 confs(每字段一个文件, 文件内容是 `{"<字段>": <值>}` 的合法配置片段),
# 并删除内容里已不存在的字段所对应的文件(例如 del(.geodata) 必须真的让 14_geodata.json 消失)。
# 第二个参数可指定目标目录(DNS 菜单用它把候选配置写进临时目录做 xray -test 预检)。
_config_write_merged() {   # <完整配置 JSON> [目标目录]
    local content="$1" dir="${2:-$CONFIG_DIR}"
    [ -n "$content" ] || return 1
    printf '%s' "$content" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    _config_layout_valid "$dir" repair || return 1
    mkdir -p "$dir" || return 1
    local k v f written=$'\n'
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
        f=$(_conf_file_for_field "$k") || return 1
        v=$(printf '%s' "$v" | jq --arg k "$k" '{($k): .}') || return 1
        _atomic_write_json "$dir/$f" "$v" || return 1
        written="${written}${f}"$'\n'
    done < <(printf '%s' "$content" | jq -j 'to_entries[] | "\(.key)\u0000\(.value | tojson)\u0000"')
    local old
    for old in "$dir"/*.json; do
        [ -f "$old" ] || continue
        if ! grep -qxF "$(basename "$old")" <<< "$written"; then
            rm -f "$old" || return 1
        fi
    done
    return 0
}

# 旧配置作为本次迁移恢复源; service/启动失败恢复原路径、service 和运行态。
_config_migrate_legacy() {
    [ -f "${LEGACY_CONFIG_FILE}.bak" ] && return 0
    _config_present && return 0
    [ -f "$LEGACY_CONFIG_FILE" ] && [ -s "$LEGACY_CONFIG_FILE" ] || return 0
    local content snapshot="" snapshot_dir="" unit="" running=0 failed=0 mask_taken=0
    content=$(jq . "$LEGACY_CONFIG_FILE" 2>/dev/null) || {
        _error "旧配置文件解析失败, 未迁移(保持原样): $LEGACY_CONFIG_FILE"
        return 1
    }
    [ -n "$content" ] || return 1
    if [ -x "$XRAY_BIN" ]; then
        snapshot=$(mktemp -d) || return 1
        unit=$(_xray_service_unit_path) || unit=""
        if [ -n "$unit" ]; then
            if [ "${INIT_SYSTEM:-}" = systemd ] && _xray_service_is_masked "$unit"; then
                snapshot_dir=$(mktemp -d "$(dirname "$unit")/.xray-migrate.XXXXXX") || { rm -rf "$snapshot"; return 1; }
                rm -rf "$snapshot"
                snapshot=$snapshot_dir
            fi
            if [ "${INIT_SYSTEM:-}" = systemd ] && _xray_service_is_masked "$unit"; then
                _xray_service_take_mask_snapshot "$unit" "$snapshot/masked" || {
                    rm -rf "$snapshot"
                    _error "无法安全快照 stale systemd mask, 取消配置迁移"
                    return 1
                }
                mask_taken=1
                systemctl daemon-reload || {
                    _xray_service_restore_mask "$unit" "$snapshot/masked" >/dev/null 2>&1 || :
                    systemctl daemon-reload >/dev/null 2>&1 || :
                    rm -rf "$snapshot"
                    _error "移除 stale systemd mask 后 daemon-reload 失败"
                    return 1
                }
            elif [ -f "$unit" ]; then
                cp -p "$unit" "$snapshot/service" || { rm -rf "$snapshot"; return 1; }
            fi
            _xray_service_snapshot_enable "$unit" "$snapshot/enabled" || {
                if [ -f "$snapshot/masked" ]; then
                    _xray_service_restore_mask "$unit" "$snapshot/masked" >/dev/null 2>&1 || :
                    systemctl daemon-reload >/dev/null 2>&1 || :
                fi
                rm -rf "$snapshot"
                return 1
            }
        fi
        [ "$(_manage_xray status 2>/dev/null)" = running ] && running=1
    fi
    if ! _config_write_merged "$content"; then
        rm -f "$CONFIG_DIR"/*.json
        if [ "$mask_taken" -eq 1 ] && [ -f "$snapshot/masked" ]; then
            _xray_service_restore_mask "$unit" "$snapshot/masked" >/dev/null 2>&1 || :
            systemctl daemon-reload >/dev/null 2>&1 || :
        fi
        [ -z "$snapshot" ] || rm -rf "$snapshot"
        _error "配置迁移写入失败, 旧配置保持原样"
        return 1
    fi
    if ! mv -f "$LEGACY_CONFIG_FILE" "${LEGACY_CONFIG_FILE}.bak"; then
        rm -f "$CONFIG_DIR"/*.json
        if [ "$mask_taken" -eq 1 ] && [ -f "$snapshot/masked" ]; then
            _xray_service_restore_mask "$unit" "$snapshot/masked" >/dev/null 2>&1 || :
            systemctl daemon-reload >/dev/null 2>&1 || :
        fi
        [ -z "$snapshot" ] || rm -rf "$snapshot"
        return 1
    fi
    if [ -n "$snapshot" ]; then
        _create_xray_service || failed=1
        if [ "$failed" -eq 0 ] && [ "$running" -eq 1 ]; then
            _restart_xray_verified || failed=1
        fi
        if [ "$failed" -eq 1 ]; then
            _manage_xray stop
            mv -f "${LEGACY_CONFIG_FILE}.bak" "$LEGACY_CONFIG_FILE" || return 1
            if [ -n "$unit" ]; then
                if [ -f "$snapshot/masked" ]; then
                    _xray_service_restore_mask "$unit" "$snapshot/masked" || return 1
                    if [ "${INIT_SYSTEM:-}" = systemd ]; then
                        systemctl daemon-reload || return 1
                    fi
                elif [ -f "$snapshot/service" ]; then
                    _xray_service_restore_file "$snapshot/service" "$unit" || return 1
                else
                    rm -f "$unit" || return 1
                    if [ "${INIT_SYSTEM:-}" = systemd ]; then
                        systemctl daemon-reload || return 1
                    fi
                fi
                _xray_service_restore_enable "$snapshot/enabled" || _warn "旧 service 开机状态恢复失败, 继续恢复运行状态"
            fi
            rm -f "$CONFIG_DIR"/*.json || return 1
            if [ "$running" -eq 1 ]; then
                _restart_xray_verified || _error "旧配置已恢复, 但 Xray 启动仍失败"
            fi
            rm -rf "$snapshot"
            _error "配置迁移失败, 已恢复旧配置与 service"
            return 1
        fi
        rm -rf "$snapshot"
    fi
    _info "配置已迁移到 $CONFIG_DIR(旧文件保留为 ${LEGACY_CONFIG_FILE}.bak)"
    return 0
}

# ---------------------------------------------------------------------------
# 确保部署目录结构存在
# ---------------------------------------------------------------------------
_ensure_dirs() {
    local ok=1
    for d in "$BIN_DIR" "$ASSET_DIR" "$NODES_DIR" "$CERT_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$CONFIG_DIR"; do
        mkdir -p "$d" || ok=0
        chmod 700 "$d" 2>/dev/null || ok=0
    done
    # 存量敏感文件收紧为仅 root 可读(私钥/密码/token; umask 只对新建文件生效, 这里回填旧文件)
    local f
    for f in "$CONFIG_DIR"/*.json "$NODES_DIR"/*.json "$STATE_DIR"/cf_token "$DEPLOY_DIR"/clash.yaml; do
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
    # mkdir/printf/mv 任一步失败返回 1 并清理 tmp; 唯一临时名防止并发写入交错。
    # state 可含凭据, 写入后必须 chmod 600。
    mkdir -p "$STATE_DIR" || return 1
    tmp=$(mktemp "$STATE_DIR/${key}.tmp.XXXXXX") || return 1
    if ! printf '%s' "$val" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if ! mv -f "$tmp" "$STATE_DIR/$key"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# crontab 读取/改写(30-geo 与 90-menu 共用, 避免两处各自演化)
#
# 为什么必须封装: `crontab -l 2>/dev/null | grep -v MARKER | crontab -` 在 crontab -l 失败时
# 会把**空输入**写回, 等于清空用户全部定时任务; 且管道退出码取自最后的 crontab -, 仍是 0。
#
# 契约:
#   _crontab_read                → stdout = 现有内容; "本来没有 crontab" 视为空返回 0;
#                                  真读不到(权限/瞬时 I/O)返回 1 且不输出内容
#   _crontab_replace <marker> [newline]
#                                → 按**字面**删除含 marker 的行, 可选追加 newline;
#                                  读或写任一步失败都返回 1 且不改动 crontab
#   _crontab_has_marker <marker> → 0 = 存在; 1 = 读到了且确实没有; 2 = 读取失败(未知)
#                                  三态而非布尔: 两种"非 0"的处置完全相反
# ---------------------------------------------------------------------------
_crontab_read() {
    local cur rc err
    err=$(mktemp) || return 1
    cur=$(crontab -l 2>"$err"); rc=$?
    if [ "$rc" -ne 0 ]; then
        local errtext; errtext=$(cat "$err" 2>/dev/null)
        rm -f "$err"
        # 只认规范 no crontab 为空态; 权限/I/O/包装器损坏均 fail-closed, 不得清空用户任务。
        case "$errtext" in
            *"no crontab"*)
                return 0 ;;
        esac
        _error "读取 crontab 失败, 已中止(避免覆盖并清空现有定时任务): ${errtext:-未知错误}"
        return 1
    fi
    rm -f "$err"
    printf '%s' "$cur"
    return 0
}

# crontab RMW 复用可重入 config lock 防止并发覆盖; 只读 _crontab_read 不取锁。
_crontab_replace() {
    _with_config_lock _crontab_replace_locked "$@"
}
_crontab_replace_locked() {
    local marker="$1" newline="${2:-}" cur filtered grc
    [ -n "$marker" ] || return 1
    cur=$(_crontab_read) || return 1
    # -F 按字面匹配 marker; grep -v 返回 1 是合法空结果, rc>=2 必须拒绝写回。
    filtered=$(printf '%s\n' "$cur" | grep -vF "$marker"); grc=$?
    if [ "$grc" -ge 2 ]; then
        _error "过滤 crontab 失败(grep 返回 ${grc}), 已中止(避免覆盖并清空现有定时任务)"
        return 1
    fi
    if [ -n "$newline" ]; then
        # 用变量承载换行, 避免源码行首 } 截断测试套件的 _fn_body_extract。
        local nl=$'\n'
        filtered="${filtered:+${filtered}${nl}}${newline}"
    fi
    printf '%s\n' "$filtered" | crontab - 2>/dev/null || return 1
    return 0
}

# 查询任务必须走 _crontab_read; 读失败不能等同于不存在, 否则 UI/cron 状态分裂。
# 返回三态见 crontab 契约: 0=存在, 1=确实没有, 2=读取失败(未知)。
_crontab_has_marker() {
    local marker="$1" cur rc
    [ -n "$marker" ] || return 2
    cur=$(_crontab_read) || return 2      # 读失败: 不输出内容, 上层按"未知"处理
    printf '%s\n' "$cur" | grep -qF -- "$marker"; rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
    esac
    # grep 真出错(rc>=2, 二进制缺失等): 同样属于"未知", 不能报"没有"
    _error "检查 crontab 内容失败(grep 返回 $rc)"
    return 2
}

# ---------------------------------------------------------------------------
# 配置备份/回滚(写 confs 前调用)。备份单位是**整个 confs 目录**。
# ---------------------------------------------------------------------------
# 备份须至少一份非空 *.json; 文件存在不等于内容可用于恢复。
_backup_config_has_bytes() {
    local f
    for f in "$1"/*.json; do [ -f "$f" ] && [ -s "$f" ] && return 0; done
    return 1
}

_backup_config() {
    _config_present || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    local tmp
    # 注意: busybox/musl 的 mktemp 要求模板以 XXXXXX 结尾, 后缀必须放在 X 之前(否则 EINVAL)
    tmp=$(mktemp -d "${BACKUP_DIR}/confs.bak.XXXXXX") || return 1
    cp -f "$CONFIG_DIR"/*.json "$tmp"/ 2>/dev/null || { rm -rf "$tmp"; return 1; }
    # 非空判据见 _backup_config_has_bytes。
    _backup_config_has_bytes "$tmp" || { rm -rf "$tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    # 备份含密码/UUID/私钥: chmod 600 失败视为备份失败, 不能留下 0644 备份
    chmod 700 "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    chmod 600 "$tmp"/*.json 2>/dev/null || { rm -rf "$tmp"; return 1; }
    # 新副本完整且权限就绪后才替换 lastbak; rm + mv 不是整目录原子提交。
    local last_tmp
    last_tmp=$(mktemp -d "${BACKUP_DIR}/confs.lastbak.XXXXXX") || { rm -rf "$tmp"; return 1; }
    cp -f "$CONFIG_DIR"/*.json "$last_tmp"/ 2>/dev/null || { rm -rf "$tmp" "$last_tmp"; return 1; }
    # lastbak 同样必须通过非空检查。
    _backup_config_has_bytes "$last_tmp" || { rm -rf "$tmp" "$last_tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    chmod 700 "$last_tmp" 2>/dev/null || { rm -rf "$tmp" "$last_tmp"; return 1; }
    chmod 600 "$last_tmp"/*.json 2>/dev/null || { rm -rf "$tmp" "$last_tmp"; return 1; }
    rm -rf "$BACKUP_DIR/confs.lastbak"
    mv -f "$last_tmp" "$BACKUP_DIR/confs.lastbak" 2>/dev/null || { rm -rf "$tmp" "$last_tmp"; return 1; }
    # 随机快照保留最新 10 份; 按行读取目录名兼容空白, 不依赖 find -printf。
    local i=0 old
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        [ -d "$BACKUP_DIR/$old" ] || continue
        i=$((i+1))
        [ "$i" -gt 10 ] && rm -rf "$BACKUP_DIR/$old"
    done <<< "$(ls -1t "$BACKUP_DIR" 2>/dev/null | grep '^confs\.bak\.')"
    return 0
}

_restore_config() {
    [ -d "$BACKUP_DIR/confs.lastbak" ] || return 1
    # 逐文件回写(_config_write_merged), 非整目录原子回滚; 失败可能已恢复部分文件。
    # 先拒绝无 JSON 的备份目录; 读取/写回失败返回 1。
    ls -1 "$BACKUP_DIR/confs.lastbak"/*.json >/dev/null 2>&1 || {
        _error "备份为空, 无法回滚($BACKUP_DIR/confs.lastbak)"
        return 1
    }
    local content
    content=$(cat "$BACKUP_DIR/confs.lastbak"/*.json 2>/dev/null | jq -s 'reduce .[] as $o ({}; reduce ($o | to_entries[]) as $e (.; .[$e.key] = $e.value))') || {
        _error "读取备份失败($BACKUP_DIR/confs.lastbak)"
        return 1
    }
    [ -n "$content" ] || { _error "读取备份失败($BACKUP_DIR/confs.lastbak)"; return 1; }
    if ! _config_write_merged "$content"; then
        _error "配置回滚失败($CONFIG_DIR)"
        return 1
    fi
    _warn "已回滚到上次配置"
    return 0
}

# ---------------------------------------------------------------------------
# 随机生成(无需 Date.now/Math.random —— 用系统源)
# ---------------------------------------------------------------------------
_gen_uuid() {
    local u=""
    if [ -x "$XRAY_BIN" ]; then
        u=$("$XRAY_BIN" uuid 2>/dev/null)
    elif command -v uuidgen >/dev/null 2>&1; then
        u=$(uuidgen)
    else
        # 兜底:从 /proc/sys/kernel/random/uuid(Linux)
        u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    fi
    # 各来源输出均须验证 UUID 形状, 缺失或告警文本不得写进配置。
    if [[ "$u" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        printf '%s\n' "$u"
        return 0
    fi
    return 1
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
# 进程归属 helper: 判活绑定 service 进程树, 避免别的同名安装掩盖启动失败。
# ---------------------------------------------------------------------------

# 读取指定 pid 的父 pid。comm 字段可能含空格与括号, 故从最后一个 ') ' 之后取字段。
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

# Read Linux process start time (proc stat field 22) to detect PID reuse across delayed signals.
_proc_starttime() {
    local pid="${1:-}" line
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    line="${line##*') '}"
    local -a fields
    read -ra fields <<< "$line"
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf '%s' "${fields[19]}"
}

# True while <pid> still refers to the same process incarnation whose start time is <starttime>.
_xd_pid_unchanged() {
    local pid="${1:-}" st="${2:-}" now
    [ -n "$st" ] || return 1
    now=$(_proc_starttime "$pid") || return 1
    [ "$now" = "$st" ]
}

# TERM → 等待 → KILL 均复核 starttime, 限制 PID 复用导致的误杀。
# best-effort: 最后一次 stat 与 kill 之间仍有窗口, 不依赖 pidfd/python3, 不承诺绝不误杀。
# 身份读不到只发 TERM 并告警, 不退回 kill -0 + kill -9 的延迟强杀。
# 用法: _xd_kill_pid_graceful <pid> [grace_seconds] [expected_starttime]
# 调用方须传复核时的 expected_starttime 闭合身份链; 省略时自行读取, 仍属 best-effort。
_xd_kill_pid_graceful() {
    local pid="${1:-}" grace="${2:-5}" expected_st="${3:-}" st k=0
    # 规范 PID: `kill 0` 发给整个进程组(非 PID 0), 会误伤整组; 前导零/超长一律拒绝。
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [ "${#pid}" -le 7 ] || return 1
    # 必须在 TERM 前取身份, 否则可能记录退出后复用 PID 的新进程。
    st=$(_proc_starttime "$pid") || st=""
    if [ -n "$expected_st" ]; then
        # 身份链闭合: 当前化身必须与调用方复核过的记录一致, 否则一个信号都不发。
        [ "$st" = "$expected_st" ] || return 0
        st="$expected_st"
    fi
    kill "$pid" 2>/dev/null || return 0     # 已退出 => 无需再处理
    if [ -z "$st" ]; then
        _warn "无法确认 PID $pid 的启动时间, 跳过延迟强杀(仅已发送 TERM)"
        while [ "$k" -lt "$grace" ]; do
            sleep 1
            [ -d "/proc/$pid" ] || return 0
            k=$((k+1))
        done
        return 0
    fi
    while [ "$k" -lt "$grace" ]; do
        _xd_pid_unchanged "$pid" "$st" || return 0
        sleep 1
        k=$((k+1))
    done
    # best-effort 强杀: 先确认仍是同一化身, 再把 read->kill 窗口压到最小(仍非原子, 见上)。
    _xd_pid_unchanged "$pid" "$st" && kill -9 "$pid" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# direct pidfile 记录 PID starttime; 同名同路径也须区分进程化身。
# 兼容旧纯 PID / OpenRC pidfile: 无 starttime 时仅检查存活, 属已声明的 best-effort。
# ---------------------------------------------------------------------------
_xd_pidfile_pid() {   # <file> -> stdout: 规范 PID, 否则空
    local f="${1:-}" pid=""
    [ -f "$f" ] || return 0
    read -r pid _ < "$f" 2>/dev/null || true
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
    [ "${#pid}" -le 7 ] || return 0
    printf '%s' "$pid"
}

_xd_pidfile_starttime() {   # <file> -> stdout: 记录的 starttime, 无则空
    local f="${1:-}" pid="" st=""
    [ -f "$f" ] || return 0
    read -r pid st < "$f" 2>/dev/null || true
    [ -n "$st" ] || return 0
    [[ "$st" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$st"
}

# 写入 "PID starttime"; starttime 读不到时只写 PID(调用方语义退化为旧行为)。
_xd_pidfile_write() {   # <file> <pid>
    local f="${1:-}" pid="${2:-}" st
    [ -n "$f" ] || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    st=$(_proc_starttime "$pid") || st=""
    if [ -n "$st" ]; then
        printf '%s %s\n' "$pid" "$st" > "$f"
    else
        printf '%s\n' "$pid" > "$f"
    fi
}

# 记录的身份是否仍指向同一进程: 有 starttime 时必须相符; 无 starttime 时只要求 PID 仍存在。
_xd_pidfile_identity_ok() {   # <file>
    local f="${1:-}" pid st
    [ -f "$f" ] || return 1
    pid=$(_xd_pidfile_pid "$f")
    [ -n "$pid" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    st=$(_xd_pidfile_starttime "$f")
    if [ -n "$st" ]; then
        _xd_pid_unchanged "$pid" "$st" || return 1
    fi
    return 0
}

# kill 专用 exe 判定: 身份读不到即拒绝; 判活 _proc_exe_is 为防重复启动而 fail-open。
# 凡凭 exe 归属决定是否 kill 都必须用本函数(含 55-hysteria supervisor 清理)。
# ---------------------------------------------------------------------------
_proc_exe_is_strict() {
    local pid="${1:-}" want="${2:-}" got rw
    [ -n "$want" ] || return 1                  # 没有期望路径 => 无法证明归属 => 拒绝
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    got=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1   # 读不到 => 拒绝
    [ -n "$got" ] || return 1
    got="${got% (deleted)}"
    [ "$got" = "$want" ] && return 0
    rw=$(readlink -f "$want" 2>/dev/null) || return 1
    [ -n "$rw" ] || return 1
    [ "$got" = "$rw" ] && return 0
    return 1
}

# 判断"以 anchor_pid 为祖先(含自身)的进程里, 是否存在 comm == name 的进程"。
# 用法: _proc_named_under <anchor_pid> <comm> [max_depth]
# openrc 的 pidfile 记的是 supervise-daemon(真正的业务进程是其子进程), 故需回溯 ppid 链
# 确认归属(默认 4 层, 足够覆盖 supervisor→业务进程)。
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

# exe 归属判活: 路径匹配才接受, 防止混入其它安装的同名进程。
# exe 读不到但 PID 仍存在则 fail-open, 防止误判停止后重复启动; 读到不匹配则拒绝。
_proc_exe_is() {
    local pid="${1:-}" want="${2:-}" got rw
    [ -n "$want" ] || return 0                  # 未指定期望路径 => 不做这层过滤
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1              # 已退出/不存在不是"无法读取", 而是明确停止
    # 读不到 exe 仍 fail-open, 但先复核 PID 是否还存在: 进程恰在扫描后退出时, 不能把它
    # 当成活进程报告。存在但受 hidepid/权限限制时仍按既定 liveness 契约放行。
    got=$(readlink "/proc/$pid/exe" 2>/dev/null) || { [ -d "/proc/$pid" ] && return 0; return 1; }
    [ -n "$got" ] || { [ -d "/proc/$pid" ] && return 0; return 1; }
    # 就地替换二进制(升级)后, 运行中进程的 exe 链会带 " (deleted)" 后缀
    got="${got% (deleted)}"
    [ "$got" = "$want" ] && { [ -d "/proc/$pid" ] && return 0; return 1; }
    # 路径可能经由 symlink 呈现不同前缀(如 /opt 本身是软链, exe 记录的是解析后的真实路径),
    # 把期望路径也解析一次再比。解析失败(路径不存在/断链)时以上面的字面比较为结论 => 拒绝。
    rw=$(readlink -f "$want" 2>/dev/null) || return 1
    [ -n "$rw" ] || return 1
    [ "$got" = "$rw" ] && { [ -d "/proc/$pid" ] && return 0; return 1; }
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
        # pidof 可能漏报, 未命中期望二进制时继续 /proc 扫描(见 _xray_is_running)。
    fi
    for p in /proc/[0-9]*; do
        read -r c 2>/dev/null < "$p/comm" || continue
        [ "$c" = "$name" ] || continue
        _proc_exe_is "${p#/proc/}" "$want" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 就地修改配置前的共同前置校验(路由规则精简/恢复、日志级别切换、DNS 设置共用):
# 缺任一条件即拒绝并给出准确原因(而不是让下游 jq 产出空配置)。
# 用法: _config_edit_preflight [操作名]   —— 操作名仅用于错误文案
# ---------------------------------------------------------------------------
_config_edit_preflight() {
    local what="${1:-修改配置}"
    if [ ! -x "$XRAY_BIN" ]; then
        _error "Xray 未安装, 无法${what}"
        return 1
    fi
    if ! _config_present; then
        _error "配置不存在或为空, 无法${what}: $CONFIG_DIR"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _error "jq 不可用, 无法${what}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 任意键继续
# ---------------------------------------------------------------------------
_press_any_key() {
    echo -e "${YELLOW}按回车键继续...${NC}" >&2
    read -r
}

# 无 flock 时 config.lock.d 原子 mkdir + pid; 既有目录一律拒绝, SIGKILL 残留需人工清理。
# 跨版本 L1/L2 × flock/mkdir 协调见 _xray_legacy_lock_name; 缺 helper 时 fail-closed。
_with_config_lock_mkdir() {
    local deploy_path="${DEPLOY_DIR%/}" lock_dir lock_file rc owner lrc
    local legacy_lock_file legacy_lock_dir legacy1_lock_file legacy1_lock_dir
    local legacy_fd="" legacy_dir="" legacy1_fd="" legacy1_dir=""
    case "$deploy_path" in
        /*) ;;
        *) _error "部署目录必须是绝对路径, 无法建立配置锁: $DEPLOY_DIR"; return 1 ;;
    esac
    if [ -z "$deploy_path" ] || [ "$deploy_path" = "/" ]; then
        _error "部署目录路径无效, 无法建立配置锁: $DEPLOY_DIR"
        return 1
    fi
    legacy_lock_file="$deploy_path/.config.lock"
    legacy_lock_dir="$deploy_path/.config.lock.d"
    legacy1_lock_file="${deploy_path%/*}/.${deploy_path##*/}.config.lock"
    legacy1_lock_dir="${deploy_path%/*}/.${deploy_path##*/}.config.lock.d"
    lock_file="$(_deploy_lock_root)/config.lock"
    lock_dir="$(_deploy_lock_root)/config.lock.d"
    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || {
        _error "无法创建配置锁目录 $(dirname "$lock_dir")(权限/只读文件系统?), 放弃本次修改"
        return 1
    }
    if ! mkdir "$lock_dir" 2>/dev/null; then
        owner=$(cat "$lock_dir/pid" 2>/dev/null)
        _error "配置锁目录已存在(可能有其他会话, 或上次被强杀): $lock_dir (pid ${owner:-未知})"
        _tip "确认没有会话在修改配置后, 请手动删除该锁目录: rm -rf -- '$lock_dir'"
        return 1
    fi
    if ! printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null; then
        rm -f "$lock_dir/pid" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null
        _error "无法写入配置锁持有者记录 $lock_dir/pid(磁盘空间/权限?), 放弃本次修改"
        return 1
    fi
    if ! declare -F _xray_legacy_flock_active >/dev/null 2>&1; then
        _error "无法确认配置 flock 主锁是否空闲(缺少 /proc 检查助手), 放弃本次修改"
        rm -f "$lock_dir/pid" 2>/dev/null; rmdir "$lock_dir" 2>/dev/null
        return 1
    fi
    _xray_legacy_flock_active "$lock_file"; lrc=$?
    case "$lrc" in
        0|2)
            _error "配置 flock 主锁被占用或无法确认, 放弃本次修改"
            rm -f "$lock_dir/pid" 2>/dev/null; rmdir "$lock_dir" 2>/dev/null
            return 1
            ;;
    esac
    if [ ! -d "$deploy_path" ]; then
        _error "部署目录不存在, 放弃本次配置修改(可能刚被卸载): $deploy_path"
        rm -f "$lock_dir/pid" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null
        return 1
    fi
    # L2 路径不存在时补删除树扫描(旧版锁文件在部署树内, rm -rf 后 fd 仍在)。
    if [ ! -e "$legacy_lock_file" ] && [ ! -e "$legacy_lock_dir" ] \
       && declare -F _xray_legacy_deleted_tree_active >/dev/null 2>&1; then
        if _xray_legacy_deleted_tree_active "$deploy_path"; then
            _error "检测到旧版进程仍持有已删除部署树的文件, 放弃本次配置修改"
            rm -f "$lock_dir/pid" 2>/dev/null
            rmdir "$lock_dir" 2>/dev/null
            return 1
        fi
    fi
    # 跨版本协调(仅对已存在的旧路径)。
    if [ -e "$legacy_lock_file" ] || [ -e "$legacy_lock_dir" ]; then
        if ! declare -F _xray_legacy_lock_name >/dev/null 2>&1 \
           || ! _xray_legacy_lock_name legacy_fd legacy_dir \
                "$legacy_lock_file" "$legacy_lock_dir" "旧版配置锁"; then
            _error "无法协调旧版配置锁, 放弃本次修改"
            rm -f "$lock_dir/pid" 2>/dev/null
            rmdir "$lock_dir" 2>/dev/null
            return 1
        fi
    fi
    if [ -e "$legacy1_lock_file" ] || [ -e "$legacy1_lock_dir" ]; then
        if ! declare -F _xray_legacy_lock_name >/dev/null 2>&1 \
           || ! _xray_legacy_lock_name legacy1_fd legacy1_dir \
                "$legacy1_lock_file" "$legacy1_lock_dir" "旧版L1配置锁"; then
            _error "无法协调旧版L1配置锁, 放弃本次修改"
            declare -F _xray_legacy_lock_release >/dev/null 2>&1 && _xray_legacy_lock_release legacy_fd legacy_dir
            rm -f "$lock_dir/pid" 2>/dev/null
            rmdir "$lock_dir" 2>/dev/null
            return 1
        fi
    fi
    (
        XRAY_DEPLOY_LOCK_HELD=1
        export XRAY_DEPLOY_LOCK_HELD
        "$@"
    )
    rc=$?
    if declare -F _xray_legacy_lock_release >/dev/null 2>&1; then
        _xray_legacy_lock_release legacy1_fd legacy1_dir
        _xray_legacy_lock_release legacy_fd legacy_dir
    fi
    owner=$(cat "$lock_dir/pid" 2>/dev/null)
    if [ "$owner" != "$$" ] || ! rm -f "$lock_dir/pid" 2>/dev/null || ! rmdir "$lock_dir" 2>/dev/null; then
        _error "配置锁释放失败或所有权记录不匹配, 锁目录保留: $lock_dir"
        _tip "确认没有配置事务仍在运行后, 请手动检查并清理该锁目录"
        return 1
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# 配置 RMW 锁: 锁根在部署树外, 卸载不能拆开 inode 导致并发覆盖。
# 跨版本协调已存在的 L1/L2 × flock/mkdir, 见 _xray_legacy_lock_name; 无锁旧写者无法协调。
# 锁序 install → config → core; 本函数不自取 install lock, 无 flock 时 mkdir 退路 fail-closed。
# XRAY_DEPLOY_LOCK_HELD=1 支持重入; 子 shell 透传返回码并在退出时释放 fd。
# ---------------------------------------------------------------------------
_with_config_lock() {
    if [ "${XRAY_DEPLOY_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    if ! command -v flock >/dev/null 2>&1; then
        _with_config_lock_mkdir "$@"
        return $?
    fi
    local config_lock_file config_lock_dir legacy1_lock_file legacy_lock_file
    local legacy1_lock_dir legacy_lock_dir
    config_lock_file="$(_deploy_lock_root)/config.lock"
    config_lock_dir="$(_deploy_lock_root)/config.lock.d"
    legacy1_lock_file="${DEPLOY_DIR%/*}/.${DEPLOY_DIR##*/}.config.lock"
    legacy1_lock_dir="${DEPLOY_DIR%/*}/.${DEPLOY_DIR##*/}.config.lock.d"
    legacy_lock_file="$DEPLOY_DIR/.config.lock"
    legacy_lock_dir="$DEPLOY_DIR/.config.lock.d"
    (
        # 只建锁根不重建部署树; 主锁后确认部署仍存在。
        mkdir -p "$(dirname "$config_lock_file")" 2>/dev/null
        # 主锁在锁根, 旧锁仅协调已存在路径; exec 不得永久重定向 stderr 吞掉事务错误。
        if ! exec 9>"$config_lock_file"; then
            _error "无法创建配置锁文件 $config_lock_file(目录不可写?), 放弃本次修改"
            exit 1
        fi
        local i
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            flock -n 9 2>/dev/null && break
            sleep 1
        done
        if ! flock -n 9 2>/dev/null; then
            _error "等待配置锁超时(15s), 可能有其他 xd 会话正在修改配置"
            exit 1
        fi
        if ! _xray_primary_flock_marker_take 9 "$config_lock_file" "$config_lock_dir" "配置锁"; then
            flock -u 9 2>/dev/null || :
            exit 1
        fi
        trap '_xray_primary_flock_marker_release "$config_lock_file" "$config_lock_dir" "配置锁" || exit 1; flock -u 9 2>/dev/null || :' EXIT
        # 主锁已在手, 此时才判部署树是否存在(锁内真实状态): 不存在 ⇒ 确实没有部署
        # (或刚被卸载), fail-closed 不重建。
        if [ ! -d "$DEPLOY_DIR" ]; then
            _error "部署目录不存在, 放弃本次配置修改(可能刚被卸载): $DEPLOY_DIR"
            exit 1
        fi
        # L2 路径不存在时补删除树扫描(旧版锁文件在部署树内, rm -rf 后 fd 仍在)。
        if [ ! -e "$legacy_lock_file" ] && [ ! -e "$legacy_lock_dir" ] \
           && declare -F _xray_legacy_deleted_tree_active >/dev/null 2>&1; then
            if _xray_legacy_deleted_tree_active "$DEPLOY_DIR"; then
                _error "检测到旧版进程仍持有已删除部署树的文件, 放弃本次配置修改"
                exit 1
            fi
        fi
        # 跨版本协调(仅对**已存在**的旧路径)。复用 core 的通用助手: flock 旧文件、检查同名
        # mkdir 目录, lfile 缺失时拒绝而不是新建。混装版本缺该助手时 fail-closed。
        local legacy_fd="" legacy_dir="" legacy1_fd="" legacy1_dir=""
        if [ -e "$legacy_lock_file" ] || [ -e "$legacy_lock_dir" ]; then
            if ! declare -F _xray_legacy_lock_name >/dev/null 2>&1 \
               || ! _xray_legacy_lock_name legacy_fd legacy_dir \
                    "$legacy_lock_file" "$legacy_lock_dir" "旧版配置锁"; then
                _error "无法协调旧版配置锁, 放弃本次修改"
                exit 1
            fi
        fi
        if [ -e "$legacy1_lock_file" ] || [ -e "$legacy1_lock_dir" ]; then
            if ! declare -F _xray_legacy_lock_name >/dev/null 2>&1 \
               || ! _xray_legacy_lock_name legacy1_fd legacy1_dir \
                    "$legacy1_lock_file" "$legacy1_lock_dir" "旧版L1配置锁"; then
                _error "无法协调旧版L1配置锁, 放弃本次修改"
                declare -F _xray_legacy_lock_release >/dev/null 2>&1 && _xray_legacy_lock_release legacy_fd legacy_dir
                exit 1
            fi
        fi
        export XRAY_DEPLOY_LOCK_HELD=1
        "$@"
        local rc=$?
        if declare -F _xray_legacy_lock_release >/dev/null 2>&1; then
            _xray_legacy_lock_release legacy1_fd legacy1_dir
            _xray_legacy_lock_release legacy_fd legacy_dir
        fi
        exit "$rc"
    )
}

# ---------------------------------------------------------------------------
# 普通 config/metadata 核心屏障: 已持 config lock 后再取 core lock。
# 检查 + 写入 + verified restart 必须同一临界区, 防止 TOCTOU。
# 锁序 config → core, 核心事务不反向取锁; HELD 标记支持嵌套, 混装缺 helper 时直接执行。
# ---------------------------------------------------------------------------
_with_config_write_barrier() {
    if declare -F _with_core_lock >/dev/null 2>&1; then
        _with_core_lock "$@"
        return $?
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# 节点改名的安全替换: 全局子串替换会误伤名称里含端口号的数字(5432 会改到 54321)。
# 默认命名形如 <Proto>-<port>, 只替换 "-<oldport>" 后缀; 无匹配则原样保留。
# 用法: new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")
# ---------------------------------------------------------------------------
_rename_node_with_port() {
    local name="$1" oldport="$2" newport="$3"
    if [ -n "$name" ] && [ -n "$oldport" ] && [ -n "$newport" ] \
       && [[ "$name" == *"-${oldport}" ]]; then
        printf '%s-%s' "${name%"-${oldport}"}" "$newport"
    else
        printf '%s' "$name"
    fi
}

# ---------------------------------------------------------------------------
# 分享链接地址/端口改写。
# @ 锚定分割, 不误伤 path/sni/name 段; IPv6 目标自动加括号, 源 host_part 还原成 "[addr]"。
#   _rewrite_link_addr <link> <newaddr>          —— 只换 host 段, 保留端口(改监听)
#   _rewrite_link_port <link> <oldport> <newport>—— 换 host:port 段(改端口, host 不变)
# **链接不含 @**时输出空串 —— 调用方必须保留原链接并提示, 不得把垃圾写回 metadata。
# ---------------------------------------------------------------------------
_rewrite_link_addr() {
    local oldlink="$1" newaddr="$2"
    [[ "$oldlink" == *@* ]] || { printf ''; return 0; }
    local before_at="${oldlink%%@*}" after_at="${oldlink#*@}"
    local host_part
    if [[ "$after_at" == "["* ]]; then
        host_part="${after_at%%]*}]"
    else
        host_part="${after_at%%[:/?#]*}"
    fi
    local new_host="$newaddr"
    # 仅按前缀判断 IPv6 括号, 不能把地址中任意 [ 当成已包裹。
    if [[ "$newaddr" == *":"* && "$newaddr" != "["* ]]; then
        new_host="[${newaddr}]"
    fi
    printf '%s' "${before_at}@${new_host}${after_at#"$host_part"}"
}

_rewrite_link_port() {
    local oldlink="$1" oldport="$2" newport="$3"
    [[ "$oldlink" == *@* ]] || { printf ''; return 0; }
    local before_at="${oldlink%%@*}" after_at="${oldlink#*@}"
    local host_part
    if [[ "$after_at" == "["* ]]; then
        host_part="${after_at%%]*}]"
    else
        host_part="${after_at%%[:/?#]*}"
    fi
    # oldport 与实际端口不符时输出空串; 调用方须保留原链接, 防止拼接损坏。
    local prefix="$host_part:$oldport" suffix
    [[ "$after_at" == "$prefix"* ]] || { printf ''; return 0; }
    suffix="${after_at#"$prefix"}"
    # The port must end here or be followed by a URI delimiter. A prefix-only check lets oldport=443
    # rewrite a real :4430 as :<newport>0, silently corrupting the share link.
    case "$suffix" in
        ""|/*|\?*|\#*) ;;
        *) printf ''; return 0 ;;
    esac
    printf '%s' "${before_at}@${host_part}:${newport}${suffix}"
}
