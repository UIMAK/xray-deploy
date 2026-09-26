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
export ASSET_DIR="$DEPLOY_DIR/assets"          # 资源目录(geoip.dat/geosite.dat)
export CONFIG_FILE="$DEPLOY_DIR/config.json"
export NODES_DIR="$DEPLOY_DIR/nodes"           # 每节点元数据
export CERT_DIR="$DEPLOY_DIR/certs"
export LOG_DIR="$DEPLOY_DIR/logs"
export STATE_DIR="$DEPLOY_DIR/state"
export BACKUP_DIR="$STATE_DIR/backup"

export XRAY_BIN="$BIN_DIR/xray"
# XRAY_LOCATION_ASSET: 优先 config.json 的 env 段(核心 ≥ v26.7.11); 旧核心由 service 文件注入
# (见 20-xray-core)。这里只是脚本自身调用(xray -test / direct 启动)的进程级回退。
export XRAY_LOCATION_ASSET="$ASSET_DIR"
export GEO_LOG="$LOG_DIR/geo.log"

# cloudflared 是唯一例外,落官方默认点(不收口 /opt/xray-deploy)
export CF_BIN="/usr/local/bin/cloudflared"
export CF_UNIT_SYSTEMD="/etc/systemd/system/cloudflared.service"
export CF_UNIT_OPENRC="/etc/init.d/cloudflared"

# ---------------------------------------------------------------------------
# 进程间锁根目录(2026-09-26): 固定 `/var/lock/xray-deploy`(FHS 标准位置, 通常 tmpfs, 重启
# 自愈陈旧锁, 且不污染 /opt)。必须在 `$DEPLOY_DIR` 之外 —— 卸载的 rm -rf 不会把锁拆成
# 新旧 inode。**不接受环境变量覆盖**(会致两进程各持不同锁而互不排斥); 测试直接改写本函数。
# 建不出时退 /run/lock; 仍失败**不回落到 /opt**, 返回 /var/lock 让调用方 fail-closed。
# 与 install.sh 的 `_install_lock_root` 同口径。
# ---------------------------------------------------------------------------
_deploy_lock_root() {
    if mkdir -p /var/lock/xray-deploy 2>/dev/null; then printf '%s' "/var/lock/xray-deploy"; return 0; fi
    if mkdir -p /run/lock/xray-deploy 2>/dev/null; then printf '%s' "/run/lock/xray-deploy"; return 0; fi
    printf '%s' "/var/lock/xray-deploy"
}

# 脚本自身
export CMD_NAME="xd"                            # 快捷命令名(用户确认)

# GitHub 资产
export XRAY_REPO_API="https://api.github.com/repos/XTLS/Xray-core/releases"
export GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
export CF_DL_BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"

# Xray config.json 官方顶层字段顺序(官方 docs/config/index.md; _normalize_config_format 与
# _mutate_config 共用)。env 为 2026-07 新增(核心 ≥ v26.7.11), 旧核心静默忽略, 顺序无影响。
readonly XRAY_TOP_FIELDS_JSON='["env","log","api","dns","routing","policy","inbounds","outbounds","stats","fakedns","metrics","observatory","burstObservatory","geodata","version"]'

# ---------------------------------------------------------------------------
# 默认 routing 规则集(唯一真相): _init_config_if_empty(20-xray-core) 与
# _route_restore_default_rules(30-geo) 共用, **绝不允许任一侧另写一份**。
# 4 条中只有第 2、3 条会让 Xray 加载 geosite.dat/geoip.dat(各 ~20MB+), 这正是
# [9] → 路由规则精简 要摘掉的两条(见 XRAY_PRIVATE_BLOCK_RULE_JSON)。
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
        # 与 _http_download 同一口径: --timeout 是 GNU 长选项, busybox wget 可能 unrecognized option (H1), 用 -T
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
# 实现 NOTE(Alpine musl): 旧"按字符 + printf '%%02X'"依赖 locale 的字符/字节语义, musl 的
# C locale 是 UTF-8, CJK 被编成 %DFE8 一类垃圾。现用 od 拆字节后逐字节判定, 与平台/locale
# 无关: 允许集(字母/数字/.~_-)保留字面量, 其余字节 %XX 大写十六进制。
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
# 监听地址合法性校验(R7)
# 接受 ::、0.0.0.0、127.0.0.1、::1、具体 IPv4/IPv6;非法返回非 0
# ---------------------------------------------------------------------------
_validate_listen() {
    local addr="$1"
    [ -z "$addr" ] && return 1
    case "$addr" in
        "::"|"0.0.0.0"|"127.0.0.1"|"::1") return 0 ;;
    esac
    # IPv4 字面量(每段 0-255; 裸 [0-9]+ 会放行 999.1.1.1, xray 启动才报错)
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) && return 0
        return 1
    fi
    # IPv6 字面量(严格校验, 见 _is_ipv6_literal)
    _is_ipv6_literal "$addr" && return 0
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
# 域名合法性校验(R38): 伪装域名会被拼进 inbound tag, tag 含空格/引号会破坏按 tag 的关联
# 匹配与 Clash 条目, 故从输入侧禁止。只接受 LDH 形式, 单段 1-63, 总长 ≤253。
# ---------------------------------------------------------------------------
_validate_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    [ "${#d}" -le 253 ] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# ---------------------------------------------------------------------------
# 用户自定义值(path/密码/认证串/证书路径)进入 JSON 模板前的字符安全校验(2026-09-12 三审 M5)。
# 值含 " \ 或换行/制表符会让渲染产物 JSON 不合法(用户只看到一句含混的"JSON 不合法");
# 含 {{ 字样还会被后续替换轮次二次改写。在输入侧直接拒绝, 给出可理解的报错。
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
# 生成 Reality 的 tunnel inbound tag(R39): 形态 Tunnel-<sni>-<tunnel_port>-<reality_port>
# 合法 SNI 最长 253, 拼出的 tag 可达 270+ —— 内部标识不该无界携带 display 信息(污染菜单/
# 日志, 且将来拿 tag 拼路径会撞 NAME_MAX)。这里截断 SNI 段使 tag ≤ 200 字符; 关联推导
# 不受影响(主键是 realitySettings.target 端口, legacy 兜底按 "-<reality_port>" 后缀匹配)。
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
# clash.yaml 的 proxy 条目是单行 flow 映射, 用户可控字段直接插进 "..."。只有三类字符会
# 破坏语义: " 提前闭合(整份 YAML 不可解析) / \ 被当转义符静默改写 / CR/LF 截断条目。
# 其余( {} , # : ' 空格 Tab 中文 )在双引号内均安全。
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
# 持久化屏障: `mv` 只保证 rename **原子**(读不到半份文件), **不等于掉电持久**。
# 事务账本的 phase barrier 声称 durable 就必须刷两次 —— 先刷临时文件(数据落盘), rename
# 之后再刷**父目录**(新目录项落盘); 只刷文件时断电后目录项可能仍是旧的。
# 手段按平台级联: `sync <path>`(coreutils ≥8.24 / busybox ≥1.31) → `sync -f <path>`(GNU) →
# 全系统 `sync`(更重但永远正确)。尽力而为: 任一步成功返回 0, 全失败才告警。
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
    # R38(P1): 空内容必须拦在这里。上游普遍写 _atomic_write_json "$f" "$(jq ...)",
    # jq 失败时为空串; 而 `jq empty` 对 0 字节返回 0, 于是空文件会被当合法 JSON 提交 ——
    # 表现为"metadata 变 0 字节却报创建成功"、"config 被截断仍报回滚成功"。
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

# 原子更新 JSON 文件(R15): 先 jq 变换到内存, 成功后用 _atomic_write_json 提交。
# 目标文件失败时保持原样, 无 .tmp 残留。替代所有裸 "jq ... > tmp && mv"。
# 用法: _meta_update <目标文件> <jq-filter> [jq 参数...]  (jq 参数置于 filter 前)
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
    # 严格半事务(R14): mkdir/printf/mv 任一步失败都返回 1 并清理 tmp, 避免
    # "业务成功但 state 写失败被忽略"导致 service/config 与 state 分裂。
    # 临时名必须唯一(mktemp): 两个并发 _state_set 写同一键时会交错写同一文件, 发布出半截状态。
    # state 键含 cf_token 等凭据, 写完立即 chmod 600(umask 不可依赖)。
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
        # "没有 crontab" 是正常空态(此时写回空内容正确); 其余错误(权限/I/O)必须 fail-closed,
        # 当成空态会让调用方用空内容清空用户全部定时任务。
        # 只认规范文案 "no crontab"(Vixie/cronie/busybox 共用)。**不能**把 can't open /
        # cannot open / No such file or directory 也算进来 —— 它们同样出现在权限失败或
        # crontab 包装器损坏场景, 而那正是必须 fail-closed 的情形。
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

# 三十四轮 P2: crontab 是独立于 config.json 的共享状态, 但同样是 RMW —— 并发会话会最后
# 写入者覆盖前者。这里复用项目唯一的进程间事务锁(config lock), 不新建第二套锁机制。
# 锁可重入: 已在 config lock 内的调用者不会自锁死。只读的 _crontab_read 不取锁。
_crontab_replace() {
    _with_config_lock _crontab_replace_locked "$@"
}
_crontab_replace_locked() {
    local marker="$1" newline="${2:-}" cur filtered grc
    [ -n "$marker" ] || return 1
    cur=$(_crontab_read) || return 1
    # -F: marker 含 "." "-" 等正则元字符, 按字面匹配。**必须检查 grep 退出码**:
    # 命令替换的退出码不影响赋值, grep 真出错(rc>=2)时 filtered 为空串, 写回即清空 crontab。
    # grep -v 在"所有行都被过滤掉"时**合法地**返回 1, 故只有 rc>=2 才算错误。
    filtered=$(printf '%s\n' "$cur" | grep -vF "$marker"); grc=$?
    if [ "$grc" -ge 2 ]; then
        _error "过滤 crontab 失败(grep 返回 ${grc}), 已中止(避免覆盖并清空现有定时任务)"
        return 1
    fi
    if [ -n "$newline" ]; then
        # **不能**在字符串里换行写 "${filtered:+${filtered}\n}": 源码会造出一行以 `}`
        # 开头的内容行, 让测试套件的函数体提取器(_fn_body_extract 以行首 `}` 结束)截断函数;
        # 用变量承载换行, 行为不变且函数可被完整提取。
        local nl=$'\n'
        filtered="${filtered:+${filtered}${nl}}${newline}"
    fi
    printf '%s\n' "$filtered" | crontab - 2>/dev/null || return 1
    return 0
}

# 判断某条项目定时任务是否还在 —— **必须走 _crontab_read, 不能用裸管道**。
#
# `crontab -l 2>/dev/null | grep -qF "$marker"` 的退出码把两种相反事实压成同一个 1:
#   (a) 读成功, 确实没有这行          => 应继续把 state 记为 off
#   (b) crontab -l 失败(权限/瞬时 I/O) => 行**可能仍在**, 绝不能记 off
# (b) 会把系统留在"UI 说已关、cron 仍在无人值守重启服务"的分裂状态。
#
# 返回码刻意三态(而非布尔): 两种"非 0"的处置完全相反, 压成布尔必然误判一方。
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
# 配置备份/回滚(写 config.json 前调用)
# ---------------------------------------------------------------------------
_backup_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    local tmp
    # 注意: busybox/musl 的 mktemp 要求模板以 XXXXXX 结尾, 后缀必须放在 X 之前(否则 EINVAL)
    tmp=$(mktemp "${BACKUP_DIR}/config.json.bak.XXXXXX") || return 1
    cp -f "$CONFIG_FILE" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    # R38(P1): 备份必须非空 —— 磁盘满时 cp 可能返回 0 却只落地 0 字节, 之后回滚就会
    # 以"空配置"覆盖。空备份视为备份失败, 由调用方中止事务。
    [ -s "$tmp" ] || { rm -f "$tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    # 备份含密码/UUID/私钥: chmod 600 失败视为备份失败(R13), 不能留下 0644 备份
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    # R23: lastbak 原子更新 —— 旧 lastbak 保持到新备份完整成功(直接 cp 覆盖在 I/O 失败时
    # 会截断 lastbak, 损坏整个 rollback 基础)。
    local last_tmp
    last_tmp=$(mktemp "${BACKUP_DIR}/config.json.lastbak.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp -f "$CONFIG_FILE" "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    # R38(P1): 同上 —— lastbak 是回滚基础, 0 字节比"没有备份"更危险
    [ -s "$last_tmp" ] || { rm -f "$tmp" "$last_tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    chmod 600 "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    mv -f "$last_tmp" "$BACKUP_DIR/config.json.lastbak" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    # 轮转历史快照: 仅保留最新 10 份随机备份(回滚只用 lastbak, 其余作人工追溯)。
    # while read 逐行消费 ls -1t, 不用 `for old in $(ls ...)` 词分割(文件名含空白时 rm -f
    # 静默失败 → 目录无界增长); 只对普通文件计数。不用 find -printf(busybox 未必编译)。
    local i=0 old
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        [ -f "$BACKUP_DIR/$old" ] || continue
        i=$((i+1))
        [ "$i" -gt 10 ] && rm -f "$BACKUP_DIR/$old"
    done <<< "$(ls -1t "$BACKUP_DIR" 2>/dev/null | grep '^config\.json\.bak\.')"
    return 0
}

_restore_config() {
    [ -f "$BACKUP_DIR/config.json.lastbak" ] || return 1
    # R23: 原子回滚 —— 直接 cp 覆盖在 I/O 失败时可能把 config 截断; 复用 _atomic_write_json
    # (tmp → 校验 → mv), 失败时旧 config 保持原样。
    # R38(P1): 前置判非空, 否则"回滚"会把 config 变成空文件却报成功。
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
    local u=""
    if [ -x "$XRAY_BIN" ]; then
        u=$("$XRAY_BIN" uuid 2>/dev/null)
    elif command -v uuidgen >/dev/null 2>&1; then
        u=$(uuidgen)
    else
        # 兜底:从 /proc/sys/kernel/random/uuid(Linux)
        u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    fi
    # 形状校验: 三个来源都可能失败(非 Linux 无 /proc、uuidgen 缺、xray 版本不支持), 或把
    # 告警行混进 stdout。空 UUID 写进配置会让节点看似建好却永远连不上, 故 fail-closed。
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
# 格式化 config.json: 按官方顺序重排字段 + 统一缩进, 幂等
# R35(P2): 复用 _atomic_write_json 单一严格写入器, 不再维护第二套 tmp/mv 逻辑;
# R38(P1): 空内容由 _atomic_write_json 拦截, 这里再显式判一次避免无谓错误输出。
#
# 三十三轮 P1: 本函数是"读整份 config → jq 重排 → 原子写回"的 RMW, 必须在 config lock
# 内执行, 否则并发节点事务提交后会被旧快照整份覆盖(lost update)。外层先做廉价守卫。
# ---------------------------------------------------------------------------
_normalize_config_format() {
    [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return 0
    _with_config_lock _normalize_config_format_locked
}
_normalize_config_format_locked() {
    # 廉价守卫留在屏障外(不必要为空/无 jq 的 no-op 去取 core lock)
    [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    _with_config_write_barrier _normalize_config_format_write
}

_normalize_config_format_write() {
    # 直写整份 config 的 RMW(不经 _mutate_config), 必须自带未收敛事务闸门(复审 P1):
    # reset / core(仅非终态) / port 任一未收敛时, 连"重排字段"也会改变现场。
    # 屏障保证"检查"与"写入"同一 core lock 临界区(TOCTOU)。
    # guard 是软依赖: 混装旧 lib 缺 helper 时放行(与项目口径一致)。
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
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
    # 2026-09-12 三审(L5): 本函数每次主菜单启动都跑; 内容无变化时跳过写入,
    # 避免无条件 mv 刷新 mtime(纯 I/O 浪费)。
    local cur
    cur=$(cat "$CONFIG_FILE" 2>/dev/null) || cur=""
    [ "$content" = "$cur" ] && return 0
    _atomic_write_json "$CONFIG_FILE" "$content"
}

# ---------------------------------------------------------------------------
# 进程归属判定辅助(R38, M3)
# 只按 comm 全机扫描会把**别的**安装(x-ui/3x-ui 残留、用户自己跑的 xray)也算成"我们的
# 服务在跑", _restart_xray_verified 恒成功, 击穿核心保证。这些 helper 把判活绑定到具体
# service 进程树。
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

# TERM -> 等待 -> KILL; 等待与强杀都绑定**同一进程化身**(starttime), 但**不是**硬保证。
#
# 裸 `kill -0` 等待会把"等待窗口内退出并被复用的 PID"当成"仍活着", 随后的 SIGKILL 就落到
# 无关进程上。抓一次 starttime 并在每次判定与强杀前比对, 把风险从"整个等待期"收窄到
# "最后一次读 stat 与 kill(2) 之间"。
#
# **残余窗口在本项目依赖范围内无法消除(不可写成"绝不误杀")**: 无竞争信号需要 pidfd;
# Debian/Ubuntu 的 kill 由 procps 提供(无 --timeout), Alpine 是 busybox, bash 内建 kill 无该
# 原语, python3 不是运行期依赖。契约是 **best-effort**。
#
# 读不到身份时**不做**延迟强杀(fail-closed, 与 `_proc_exe_is_strict` 对破坏性操作的口径一致):
# 退回 `kill -0 + kill -9` 恰好会重建本函数要消除的缺陷。此时只发 TERM 并如实告警。
#
# 用法: _xd_kill_pid_graceful <pid> [grace_seconds] [expected_starttime]
#
# **expected_starttime 是身份链闭合的关键**(复审 P1): 调用方复核身份后必须把**那次复核所用
# 的 starttime** 传进来, 否则本函数重读一次, 两次读取之间 PID 仍可能被复用 ⇒ "复核的是 A、
# 杀的是 B"。为空时退化为"自己抓一次"(openrc 纯 PID pidfile 等, 属已声明的 best-effort)。
_xd_kill_pid_graceful() {
    local pid="${1:-}" grace="${2:-5}" expected_st="${3:-}" st k=0
    # 规范 PID: `kill 0` 发给整个进程组(非 PID 0), 会误伤整组; 前导零/超长一律拒绝。
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [ "${#pid}" -le 7 ] || return 1
    # **必须在 TERM 之前取身份**(复审 P1): 先 TERM 再读时原进程可能已退出并被复用,
    # 读到的是**新进程**的 starttime, 强杀就正好打在新进程上。
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
# direct 后端的进程身份 pidfile: 记录 "PID starttime", 使停止时能证明"还是启动时那个进程"。
#
# 只记 PID 时, 调用点 comm/exe 检查与真正的 kill 之间仍有窗口 —— PID 被复用后, 即使复用者
# 同名/同路径也分不出来(如两个 xray 实例)。启动时记录的 starttime 来自 fork 那一刻。
# 兼容: 只含 PID 的旧 pidfile 与 openrc 自写 pidfile 没有第二字段 ⇒ 退化为"PID 存活即视为
# 同一进程"(与旧行为一致), 与 `_proc_exe_is` 的 fail-open 口径同源。
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

# 严格版 exe 归属判定 —— **杀进程专用**。与 _proc_exe_is 的唯一差别: exe 读不到时**拒绝**。
#
# _proc_exe_is 的"读不到就放行"是为**判活**设计的(假阴性会让调用方重复启动实例, 比多算更糟)。
# 用在杀进程上则是反向危害: 读不到 exe 时所有同名进程都被判成"我们的", 限定 exe 的杀进程
# 扫描退化成它本该取代的全机 comm 扫描, 可能 SIGKILL 掉用户自己装的 cloudflared。
# 凡"凭 exe 归属决定是否 kill"的地方都必须用本函数(55-hysteria 的两处杀 supervisor 闸门)。
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

# R40: 校验 pid 的 exe 是否就是期望的二进制 —— 全机 comm 扫描无法区分本脚本的实例与别人
# 的同名进程(x-ui 残留、用户手跑), 而本脚本的 unit/init 永远指向自己的 $XRAY_BIN。
# fail-open 的两种"读不到"要分清:
#   - exe 读不到(权限/内核/刚退出) => 放行。判活的最后兜底, 假阴性会导致双实例, 更糟。
#   - exe 读到但与期望不同 => 拒绝(即便期望路径解析不出来); "不同"已是确定结论。
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
# 就地修改 config.json 前的共同前置校验(路由规则精简/恢复、日志级别切换共用):
# 缺任一条件即拒绝并给出准确原因(而不是让下游 jq 产出空配置)。
# 用法: _config_edit_preflight [操作名]   —— 操作名仅用于错误文案
# ---------------------------------------------------------------------------
_config_edit_preflight() {
    local what="${1:-修改配置}"
    if [ ! -x "$XRAY_BIN" ]; then
        _error "Xray 未安装, 无法${what}"
        return 1
    fi
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        _error "配置文件不存在或为空, 无法${what}: $CONFIG_FILE"
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

# 无 flock 时的 config 锁退路(二十轮 P1-2): 与 install/core 的 mkdir 退路同一契约 ——
# 锁根下 `config.lock.d` 原子 mkdir + pid, **永不自动接管**既有目录(活持有者/死 pid/无 pid
# 一律拒绝并给人工清理命令)。SIGKILL 残局需人工 rm -rf, 是相对 flock 的已知代价; 但直接
# 放行会让 reset 事务与普通 config writer 完全失去互斥。
# **跨版本协调**: 覆盖 L1/L2 × flock文件/mkdir目录 四种组合, 复用 `_xray_legacy_lock_name`
# 的无-flock 分支; 缺该助手时 fail-closed。
_with_config_lock_mkdir() {
    local deploy_path="${DEPLOY_DIR%/}" lock_dir rc owner
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
# 跨进程配置修改锁(2026-09-12 审查 F5): 包住 config 的 read-modify-write, 防并发 xd 会话
# 丢失更新。主锁在锁根 `/var/lock/xray-deploy/config.lock`(见 `_deploy_lock_root`): 卸载的
# rm -rf $DEPLOY_DIR 不会把它拆成两个 inode, config writer 与全站破坏性操作才能真互斥。
# **跨版本协调**: L1(父目录)/L2(目录内) × flock/mkdir 四种组合, 统一走 `_xray_legacy_lock_name`;
# 只对**已存在**的旧路径协调(不凭空重建)。旧版(<=0.17.11)无锁写者无从协调。
# 锁序: install → config → core(破坏性操作先取 install lock; 本函数**不自取** install lock ——
# 那会让每次普通写入都创建旧版目录锁标记, SIGKILL 残局把菜单锁死)。
# flock 不可用时走 `_with_config_lock_mkdir`(fail-closed, 不 best-effort 直通)。
# 持锁者导出 `XRAY_DEPLOY_LOCK_HELD=1` 支持重入。$@ 在子 shell 中执行: 返回码经退出码透传,
# fd 随子 shell 结束自动关闭释放锁。
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
    local config_lock_file legacy1_lock_file legacy_lock_file
    local legacy1_lock_dir legacy_lock_dir
    config_lock_file="$(_deploy_lock_root)/config.lock"
    legacy1_lock_file="${DEPLOY_DIR%/*}/.${DEPLOY_DIR##*/}.config.lock"
    legacy1_lock_dir="${DEPLOY_DIR%/*}/.${DEPLOY_DIR##*/}.config.lock.d"
    legacy_lock_file="$DEPLOY_DIR/.config.lock"
    legacy_lock_dir="$DEPLOY_DIR/.config.lock.d"
    (
        # **只创建锁根目录**, 绝不创建 `$DEPLOY_DIR`: 与卸载竞态时会把它重新制造出来;
        # 目录存在性改为**取到主锁之后**再判定, 不存在就 fail-closed。
        mkdir -p "$(dirname "$config_lock_file")" 2>/dev/null
        # 主锁文件在锁根, 不被卸载的 rm -rf 拆分。**已存在**的旧版 L1/L2 路径会被一并打开
        # 占用以排斥旧版写者; 不存在则跳过。
        # 注意: 仅带重定向的 exec 会把 stderr 重定向**持久化**到整个子 shell —— 原写法
        # `exec 9>... 2>/dev/null` 吞掉事务体内全部 _error(2026-09-13 Alpine 实测);
        # 去掉 2>/dev/null, open 失败时 bash 自身报错 + 下面的 _error 都可见。
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
# 普通 config/metadata 写入的**核心屏障**(复审 P1, 2026-09-26)。
# 调用前提: 已持 config lock; 本包装再取 core lock 并在其内执行写入体, 使"未收敛事务检查
# + 写入 + verified restart"处于**同一**临界区 —— 只做一次瞬时探测再写是 TOCTOU。
# 锁序 config → core 成立(核心事务侧从不取 config lock), 屏障内的嵌套调用经持锁标记
# 退化为直接调用, 不死锁。缺 `_with_core_lock`(混装旧 lib)时直接执行。
# ---------------------------------------------------------------------------
_with_config_write_barrier() {
    if declare -F _with_core_lock >/dev/null 2>&1; then
        _with_core_lock "$@"
        return $?
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# 节点改名的安全替换(F8): 全局子串替换会误伤名称里含端口号的数字(5432 会改到 54321)。
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
# 分享链接地址/端口改写(F7, 收口 _modify_port 与 _update_listen 各自的字符串手术)。
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
    # 前缀判断, 不是"包含"判断: 旧写法 `!= *"["*` 会把任何含 "[" 的地址都当成已加括号
    # (如 "a[bc"), 于是不做包裹。正常地址不含 "[" , 这里收紧只为让判定与意图一致。
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
    # 2026-09-12 三审(L2): oldport 与链接实际端口不符(metadata 被手改/损坏)时,
    # 下面的 ${after_at#...} 删除不生效, 结果会变成 "host:9999host:443?..." 拼接垃圾。
    # 与 F7 同一口径: 无法确定改写目标时输出空串, 调用方保留原链接。
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
