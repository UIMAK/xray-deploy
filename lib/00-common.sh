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
# XRAY_LOCATION_ASSET 优先经 config.json 的 env 段设置(官方 docs/config/env.md, 核心 ≥
# v26.7.11 在构建模块前应用该段); 旧核心由 service 文件注入(见 20-xray-core _create_xray_service)。
# 这里仅保留脚本自身调用(xray -test / direct 模式启动)时的进程级回退, 不再写入 service 文件。
export XRAY_LOCATION_ASSET="$ASSET_DIR"
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
# 官方顺序(docs/config/index.md): env → log → api → dns → routing → policy → inbounds →
# outbounds → stats → fakedns → metrics → observatory → burstObservatory → geodata → version。
# env 是 2026-07 新增(核心 ≥ v26.7.11), 旧核心会静默忽略该字段, 顺序本身对旧核心无影响。
readonly XRAY_TOP_FIELDS_JSON='["env","log","api","dns","routing","policy","inbounds","outbounds","stats","fakedns","metrics","observatory","burstObservatory","geodata","version"]'

# ---------------------------------------------------------------------------
# 默认 routing 规则集(唯一真相)
# 共用者: _init_config_if_empty(首次写配置, 20-xray-core) 与 _route_restore_default_rules
# (恢复默认规则, 30-geo)。**绝不允许在任一侧另写一份** —— 两处硬编码必然随时间漂移。
# 4 条规则中只有第 2、3 条会让 Xray 加载 geosite.dat / geoip.dat(各 ~20MB+),
# 这正是 [9] → 路由规则精简 要摘掉的两条(见 XRAY_PRIVATE_BLOCK_RULE_JSON)。
# 注意: regexp 内的 \\d / \\. 是 JSON 转义后的单个反斜杠, 单引号包裹以避免 bash 再吃一层。
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
# 私网/保留地址 block 规则 —— 用字面量 CIDR 等价替换 "geoip:private"
# 为什么需要它: 精简掉引用 geo 数据的规则后, 原 `ip:["geoip:private","geoip:cn"]` 一并消失,
# 客户端就能借节点访问本机私网与云元数据端点(169.254.169.254)。routing.md 的 ip 字段
# 接受字面量 CIDR, 因此把 private 段写死即可保住这层防护且**不加载 geoip.dat**。
# CIDR 清单取自 v2fly/geoip 的 private 列表原文(plugin/special/private.go), 与
# geoip:private 等价。
# ruleTag 是本项目的所有权标记: 精简是幂等操作(重复执行先按该 tag 剔除旧的再重插),
# 恢复默认规则时也靠它精确移除。Xray 支持 ruleTag(routing.md), 老核心忽略未知字段。
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

# Xray log.loglevel 合法取值(docs/config/log.md)。核心对未识别值静默回落 warning
# (infra/conf/log.go 的 default 分支), 不会报配置错误 —— 所以校验必须由脚本自己做。
# 注意 "none" 在核心里同时把 ErrorLogType 与 AccessLogType 置为 None, 即两个日志都停写。
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
        ip=$(curl -s4 --max-time 6 "$url" 2>/dev/null) && [ -n "$ip" ] && \
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && \
        (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) && \
        echo "$ip" && return 0
    done
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        # 与 _http_download 同一口径: --timeout 是 GNU 长选项, busybox wget 可能 unrecognized option (H1), 用 -T
        ip=$(wget -q -T 6 -O- "$url" 2>/dev/null) && [ -n "$ip" ] && \
        [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && \
        (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) && \
        echo "$ip" && return 0
    done
    # IPv6 兜底 —— **必须校验字面量**(#06)。旧写法只判 `[ -n "$ip" ]`, 源返回错误页/
    # 代理提示时那段文本会被当成服务器地址写进分享链接(实测复现见 implement.md)。
    for url in "https://api64.ipify.org" "https://6.ipw.cn" "https://ipv6.icanhazip.com"; do
        ip=$(curl -s6 --max-time 6 "$url" 2>/dev/null) && _is_ipv6_literal "$ip" && echo "$ip" && return 0
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
# 实现 NOTE(2026-09-13, Alpine musl 实测): 旧版"按字符迭代 + printf '%%02X' 'c"依赖
# locale 的字符/字节语义 —— glibc 下 LC_ALL=C 按字节迭代结果正确, 但 musl 的 C locale
# 本身是 UTF-8, printf "'c" 对非 ASCII 字节会返回 0xDF00+byte 一类的错误码值, CJK
# 名称被编码成 %DFE8 这类垃圾。现改为 od 拆字节后逐字节判定, 输出与平台/locale 无关:
# 允许集(字母/数字/.~_-)保留字面量, 其余字节 %XX 大写十六进制(与旧行为逐字节一致)。
# ---------------------------------------------------------------------------
_url_encode() {
    local s="$1" hex out="" b oct c o
    hex=$(printf '%s' "$s" | od -An -v -tx1 | tr -d ' \n')
    while [ -n "$hex" ]; do
        b=$((16#${hex:0:2})); hex="${hex:2}"
        if [ $(( (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 46 || b == 126 || b == 95 || b == 45 )) -eq 1 ]; then
            # 字面字符渲染: \xHH 转义与 %02x 指令相邻会让 printf 把 % 当 hex digit 报错,
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
# 旧实现只要求"全是 hex/冒号且含冒号", 于是 1::2::3 / ::::: / abc:def 全部放行 ——
# 用户拿到"配置已写入"后 xray 启动失败, 报错指向 core 而不是我们的输入校验。
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
            (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )) || return 1
            [ "$head" = "$a" ] && return 1     # 纯 IPv4 由 IPv4 分支处理
            a="${head}:0:0"                     # 内嵌 IPv4 占两段, 参与结构校验
            ;;
    esac
    # 连续 3 个及以上冒号一律非法。**必须先拦这一条**: 下面用 ${a//::/} 数 "::" 次数时,
    # "1:::2" 只会被消掉一个 "::"(dbl=1 通过), 而按段切分只产生 2 个空字段(empty=2 通过) ——
    # 两条守卫各自都看不出它是畸形输入。这正是"至多一个 ::"的规则没有被真正执行的原因。
    case "$a" in *:::* ) return 1 ;; esac
    # 单个前导/尾随冒号也必须拒绝: 它只贡献 1 个空字段(在 empty<=2 预算内), 且不产生 "::"
    # (dbl 仍为 0), 于是 "1:2:3:4:5:6:7:8:" / ":1:2:3:4:5:6:7:8" 两条守卫都放行 ——
    # 实测这两个畸形地址曾被 _validate_listen 接受, xray 启动时才报错。
    # 判据: 以单个 ':' 开头(后一个字符不是 ':')或以单个 ':' 结尾(前一个字符不是 ':')。
    # '::1' / '1::' 前后都是 ':' , 不受影响。
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
# 用户自定义值(path/密码/认证串/证书路径)进入 JSON 模板前的字符安全校验(2026-09-12 三审 M5)。
# _render_template 用 bash 占位符替换 + jq 兜底校验: 值含 " 或 \ 或换行/制表符会让渲染
# 产物 JSON 不合法, 用户只能看到一句含混的"模板渲染后 JSON 不合法"(fail-closed 但不可诊断);
# 含 {{ 占位符字样还会被后续替换轮次二次改写(如密码输入 "{{NETWORK}}" 会被偷换成 network 值)。
# 在输入侧直接拒绝这四类字符, 给出可理解的报错。正常值(字母数字/中文/空格/点/斜杠)不受影响。
# 用法: _validate_json_text <值>  非法返回 1
# ---------------------------------------------------------------------------
_validate_json_text() {
    case "$1" in
        *'"'*|*'\'*|*$'\n'*|*$'\r'*|*$'\t'*|*"{{"*) return 1 ;;
    esac
    # 其余控制字符(0x01-0x1F 中未被上面覆盖的)与 DEL(0x7F): 它们不是合法 JSON 字符串
    # 字面量, 会被 _render_template 原样拼进模板产出非法 JSON, 用户只看到含混的
    # "渲染后 JSON 不合法"。NUL 无法存在于 bash 变量, 故区间从 0x01 起。
    # shellcheck disable=SC1010
    case "$1" in
        *[$'\x01'-$'\x1f'$'\x7f']*) return 1 ;;
    esac
    return 0
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
# 2026-09-13(0.16.2 评审轮) 实测修正: ss 数据行的本机监听在 $4(Local Address:Port),
# $5 是对端(*:*, 无端口可提取) —— 原写法在装了 ss 的系统上是空扫(永远报未占用);
# netstat 分支的 $4 本来就正确。两分支统一按本机地址列提取。
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
        ss ${ss_opts} 2>/dev/null | awk 'NR > 1 {print $4}' | grep -q ":${port}$" && return 0
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
    #
    # 临时名必须唯一(mktemp), 不能是固定的 ${key}.tmp: 两个并发 _state_set 写同一个键时
    # 会往同一文件里交错写, 先到的 mv 会把后者的半截缓冲一并发布出去, 最终 state 内容
    # 损坏。state 键里含 cf_token 这类凭据, 故写完立即 chmod 600 —— umask 不可依赖
    # (调用方可能带任意 umask, 且 _ensure_dirs 只收紧它自己创建的那批文件)。
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
# 为什么必须封装: `crontab -l 2>/dev/null | grep -v MARKER | crontab -` 在 `crontab -l`
# 失败时会把**空输入**写回, 等于清空用户的全部定时任务(含与项目无关的任务); 而管道的
# 退出码取自最后的 `crontab -`, 仍是 0, 调用方据此认为"删除成功"。已实测复现:
# 令 `crontab -l` 返回 1, 用户的备份任务随之消失。
#
# 契约:
#   _crontab_read                → stdout = 现有内容; "本来没有 crontab" 视为空且返回 0;
#                                  真读不到(权限/瞬时 I/O)返回 1 且不输出任何内容
#   _crontab_replace <marker> [newline]
#                                → 按**字面**删除含 marker 的行(marker 里的 . - 不当正则),
#                                  可选追加 newline; 读或写任一步失败都返回 1 且不改动 crontab
#   _crontab_has_marker <marker> → 0 = 该行存在; 1 = 读到了且确实没有; 2 = 读取失败(未知)
#                                  三态而非布尔: "读失败"与"没启用"的处置相反, 合并会把
#                                  读失败当成没启用(见函数注释)
# ---------------------------------------------------------------------------
_crontab_read() {
    local cur rc err
    err=$(mktemp) || return 1
    cur=$(crontab -l 2>"$err"); rc=$?
    if [ "$rc" -ne 0 ]; then
        local errtext; errtext=$(cat "$err" 2>/dev/null)
        rm -f "$err"
        # "没有 crontab" 是正常空态(首次使用/被删空), 不是故障 —— 此时写回空内容是正确行为。
        # 其余错误(权限被 /etc/cron.allow 拒、SUID 异常、瞬时 I/O)必须 fail-closed:
        # 把它们当成空态会让调用方用空内容覆盖, 清空用户全部定时任务。
        # 只认"确实没有 crontab"这一种正常空态。**不能把 can't open/cannot open 一并
        # 当作空态** —— 它们同样出现在权限失败(如 cron.allow 拒绝、busybox
        # `crontab: can't open 'root': Permission denied`)上, 而那正是必须 fail-closed 的
        # 情形: 当成空态会让调用方用空内容覆盖, 清掉用户全部定时任务。
        # 只认规范的"确实没有 crontab"文案(Vixie/cronie/busybox 都用这句)。
        # **不能把 `No such file or directory` 也算进来**: 该串不只出现在"spool 文件缺失",
        # 也会出现在 crontab 包装器缺失/损坏、spool 路径权限异常等场景 —— 那些都必须
        # fail-closed, 否则 _crontab_read 返回 0+空输出, _crontab_replace 就会用空内容
        # 覆盖, 清掉用户全部定时任务(本 helper 存在的唯一理由就是防这个)。
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

_crontab_replace() {
    local marker="$1" newline="${2:-}" cur filtered grc
    [ -n "$marker" ] || return 1
    cur=$(_crontab_read) || return 1
    # -F: marker 含 "." "-" 等正则元字符, 按字面匹配才不会误删无关行。
    # **必须检查 grep 的退出码**: 命令替换的退出码不影响赋值语句, 所以 grep 真出错
    # (rc>=2, 二进制缺失/读错误)时 filtered 会是空串, 我们随即把**空内容**写回 ——
    # 又回到"清空用户全部 crontab"的灾难。注意 grep -v 在"所有行都被过滤掉"时**合法地**
    # 返回 1, 因此只有 rc>=2 才算错误。
    filtered=$(printf '%s\n' "$cur" | grep -vF "$marker"); grc=$?
    if [ "$grc" -ge 2 ]; then
        _error "过滤 crontab 失败(grep 返回 ${grc}), 已中止(避免覆盖并清空现有定时任务)"
        return 1
    fi
    if [ -n "$newline" ]; then
        filtered="${filtered:+${filtered}
}${newline}"
    fi
    printf '%s\n' "$filtered" | crontab - 2>/dev/null || return 1
    return 0
}

# 判断某条项目定时任务是否还在 —— **必须走 _crontab_read, 不能用裸管道**。
#
# 为什么不能写 `crontab -l 2>/dev/null | grep -qF "$marker"`: 那条管道的退出码把两种
# 完全相反的事实压成同一个 1 ——
#   (a) 读成功, 确实没有这行          => 应继续把 state 记为 off
#   (b) crontab -l 失败(权限/瞬时 I/O) => 行**可能仍在**, 绝不能记 off
# 实测复现(2026-09-21): 令 crontab -l 输出 "cannot open spool: Input/output error" 并
# 返回 2, 调用方(定时重启禁用)报"定时重启未启用"并写下 state=off —— 而 cron 行仍在,
# 于是进入"UI 说已关、cron 仍在无人值守地重启服务"的分裂状态, 用户下次看到"未启用"
# 也就不会再处理。这正是 _crontab_read 存在的理由, 该处却绕过了它。
#
# 返回码刻意是三态(而不是布尔): 两种"非 0"的处置完全相反 —— (a) 该记账, (b) 该拒绝记账
# 并告警。压成布尔就必然有一方被误判。
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
    # 用 while read 逐行消费 ls -1t 的输出, 不用 `for old in $(ls ...)` 词分割:
    # 后者在文件名含空白时会拆成多个不存在的路径, rm -f 静默失败 → 目录无界增长。
    # 只对确实是普通文件的条目计数(避免把目录/断链算进保留额度)。
    # (不用 find -printf: busybox 的 find 未必编译了该特性。)
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
    local u=""
    if [ -x "$XRAY_BIN" ]; then
        u=$("$XRAY_BIN" uuid 2>/dev/null)
    elif command -v uuidgen >/dev/null 2>&1; then
        u=$(uuidgen)
    else
        # 兜底:从 /proc/sys/kernel/random/uuid(Linux)
        u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    fi
    # 形状校验: 三个来源都可能失败(非 Linux 无 /proc、uuidgen 缺、xray 版本不支持 uuid),
    # 或把告警行混进 stdout。返回空串会让调用方把空 UUID 写进配置 —— 节点看似建好,
    # 客户端永远连不上, 且排查时很难想到是 UUID 为空。故这里 fail-closed。
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
    # 2026-09-12 三审(L5): 本函数在每次主菜单启动都会跑; 内容无变化时跳过写入,
    # 避免无条件 mv 让 config.json 的 mtime 每次启动都被刷新(纯 I/O 浪费)。
    local cur
    cur=$(cat "$CONFIG_FILE" 2>/dev/null) || cur=""
    [ "$content" = "$cur" ] && return 0
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

# 严格版 exe 归属判定 —— **杀进程专用**。与 _proc_exe_is 的唯一差别: exe 读不到时**拒绝**。
#
# 为什么必须分开: _proc_exe_is 的"读不到就放行"是为**判活**设计的(CLAUDE.md: 假阴性会让
# 调用方重复启动实例, 比多算更糟)。把同一宽松语义用在**杀进程**上是反向危害 —— 读不到 exe
# 时所有同名进程都被判成"我们的", 于是限定 exe 的杀进程扫描退化成它本该取代的全机 comm
# 扫描, 可能 SIGKILL 掉用户自己装的 cloudflared。
# 同理, 凡"凭 exe 归属决定是否 kill"的地方都必须用本函数: 55-hysteria 的
# _hysteria_proc_tree_has_bin(杀 supervisor 前的归属闸门)与 _hysteria_stop_and_verify 的
# 强杀循环都是 fail-closed 契约, 也都已改用它。
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
# 就地修改 config.json 前的共同前置校验(路由规则精简/恢复、日志级别切换共用)
# 缺任一条件即拒绝: 在不存在/空的配置上跑 jq 会产出空或半截配置(_atomic_write_json
# 已有空内容拦截, 这里前置判断以给出准确原因)。
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

# ---------------------------------------------------------------------------
# 跨进程配置修改锁(2026-09-12 审查 F5, 借鉴 singbox-lite _with_state_lock):
# 包住 _mutate_config 的 read-modify-write, 防止两个并发 xd 会话交叠产生丢失更新。
# best-effort 语义, 与 singbox-lite 的"缺 flock 硬失败"刻意不同:
#   - flock 不可用(裁剪版 busybox)时直接放行 —— 配置写者只有单管理员 TUI 一个,
#     为锁而拒绝服务比偶发竞态更伤; 放行属于已声明的降级而非静默吞错。
#   - 持锁者导出 XRAY_DEPLOY_LOCK_HELD=1 支持重入(当前无嵌套调用, 防御性保留)。
# 注意: "$@" 在子 shell 中执行 —— _mutate_config 及其下游不向调用方回传全局变量,
# 返回码经子 shell 退出码透传; fd 9 随子 shell 结束自动关闭并释放锁。
# ---------------------------------------------------------------------------
_with_config_lock() {
    if [ "${XRAY_DEPLOY_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    if ! command -v flock >/dev/null 2>&1; then
        "$@"
        return $?
    fi
    (
        mkdir -p "$DEPLOY_DIR" 2>/dev/null
        # 注意: exec 仅带重定向时重定向会**持久化**到整个子 shell —— 原写法
        # `exec 9>... 2>/dev/null` 把子 shell 的 stderr 永久吞掉, 事务体内的全部
        # _error/超时提示静默丢失(2026-09-13 Alpine 实测)。去掉 2>/dev/null:
        # open 失败时 bash 自身报错 + 下面的 _error 都可见, 语义更正确。
        if ! exec 9>"$DEPLOY_DIR/.config.lock"; then
            _error "无法创建配置锁文件 $DEPLOY_DIR/.config.lock(目录不可写?), 放弃本次修改"
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
        export XRAY_DEPLOY_LOCK_HELD=1
        "$@"
    )
}

# ---------------------------------------------------------------------------
# 节点改名(端口号出现在名称尾部)的安全替换(2026-09-12 审查 F8)。
# 原 `${name//${oldport}/${newport}}` 全局子串替换会把名称中恰好包含端口号的
# 其他数字一并改掉(实测: HY2-54321 + 5432→7777 得 HY2-77771)。默认命名形如
# <Proto>-<port>, 因此只替换 "-<oldport>" 后缀; 无后缀匹配时名称原样保留。
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
# 分享链接地址/端口改写(2026-09-12 审查 F7, 收口 _modify_port 与 _update_listen
# 原本各自维护的两份字符串手术)。@ 锚定分割, 不误伤 path/sni/name 段。
#   _rewrite_link_addr <link> <newaddr>          —— 只换 host 段, 保留端口(改监听)
#   _rewrite_link_port <link> <oldport> <newport>—— 换 host:port 段(改端口, host 不变)
# IPv6 目标自动加括号; IPv6 源 host_part 经 ${var%%]*} + 字面 "]" 还原成 "[addr]"。
# **链接不含 @**(被采纳节点的 "#tag (adopted)" 占位)时输出空串 —— 调用方必须
# 保留原链接并提示, 不得把 "@:新端口" 垃圾写回 metadata(实测复现过的 bug)。
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
    [[ "$after_at" == "$host_part:$oldport"* ]] || { printf ''; return 0; }
    printf '%s' "${before_at}@${host_part}:${newport}${after_at#"$host_part:$oldport"}"
}
