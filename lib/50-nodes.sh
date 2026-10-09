#!/bin/bash
# lib/50-nodes.sh — 节点创建、元数据、导出与恢复；配置修改复用统一锁和事务。

# ---------------------------------------------------------------------------
# 协议清单
# ---------------------------------------------------------------------------
PROTOCOLS=(
    "vless-tcp-reality-vision|VLESS+TCP+Reality+Vision|reality|direct|可选直连/Tunnel(防偷跑)"
    "vless-xhttp-reality|VLESS+XHTTP+Reality|reality|direct|可选直连/Tunnel(防偷跑)"
    "vless-enc|VLESS+ENC|enc|direct|内置加密·类似SS·轻量无TLS"
    "vless-xhttp-cdn|VLESS+XHTTP(无TLS)|none|cdn|必须套CDN·禁止直连"
    "vless-ws-cdn|VLESS+WS(无TLS)|none|cdn|必须套CDN·禁止直连"
    "shadowsocks|Shadowsocks|none|direct|"
    "hysteria2|Hysteria2|tls|direct|必须套TLS证书·QUIC"
)

# ---------------------------------------------------------------------------
# 带宽格式化: 纯数字自动补 mbps 单位
# ---------------------------------------------------------------------------
# 发布核心按 1024 倍单位转为字节/秒；上下行非零时至少 65536，force 上行必须非零。
# 不把微小正数截断为零当作不限速；只有输入数值零可免除最低速率。
# Xray v26.9.30: infra/conf/transport_method.go Bandwidth.Bps / transport_internet.go Build。
_hy2_brutal_rate_valid() {
    local v="${1,,}" required="${2:-false}" rate unit mul
    if [ -z "$v" ]; then
        [ "$required" != "true" ]
        return $?
    fi
    [[ "$v" =~ ^[[:space:]]*([0-9]+([.][0-9]*)?|[.][0-9]+)[[:space:]]*([a-z]*)[[:space:]]*$ ]] || return 1
    rate="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}"
    case "$unit" in
        ''|b|bps) mul=1 ;;
        k|kb|kbps) mul=1024 ;;
        m|mb|mbps) mul=1048576 ;;
        g|gb|gbps) mul=1073741824 ;;
        t|tb|tbps) mul=1099511627776 ;;
        *) return 1 ;;
    esac
    jq -en --arg rate "$rate" --argjson mul "$mul" --arg required "$required" \
        '((($rate | tonumber) * $mul | floor) / 8 | floor) as $bps |
         $bps >= 65536 or (($rate | tonumber) == 0 and $required != "true")' >/dev/null 2>&1
}

_hy2_force_brutal_up_valid() {
    _hy2_brutal_rate_valid "$1" true
}

_normalize_bandwidth() {
    local v="$1"
    [ -z "$v" ] && { echo ""; return; }
    # 纯数字补mbps，短单位展开；核心要求带单位的速率字符串。
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "${v} mbps"
    # 短后缀展开为gbps/mbps。
    elif [[ "$v" =~ ^[0-9]+g$ ]]; then
        echo "${v%g} gbps"
    elif [[ "$v" =~ ^[0-9]+m$ ]]; then
        echo "${v%m} mbps"
    else
        echo "$v"
    fi
}

# 混淆仅写 finalmask.udp；无混淆留空数组，salamander 密码启用，gecko 增加 packetSize。
# Xray finalmask.md: gecko 在服务端仍为 salamander，客户端按分片尺寸导出。

# packetSize 去空格、排序、去前导零后统一输出；服务端与客户端必须使用同一区间。
# 非法尺寸返回1且无输出；调用方必须判返码，不把空输出当关闭。
_hy2_obfs_size_canon() {
    local raw="$1" a b
    raw="${raw// /}"                      # 去掉空格, 便于接受 "512 - 1200" 这类写法
    [ -z "$raw" ] && return 0
    if [[ "$raw" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    elif [[ "$raw" =~ ^[0-9]+$ ]]; then
        a="$raw"; b="$raw"
    else
        return 1
    fi
    # 整数先限长度再比较；bash 超大整数比较不能作为有效上界校验。
    [ "${#a}" -le 10 ] && [ "${#b}" -le 10 ] || return 1
    # 去前导零后按十进制处理；避免 bash 八进制与客户端尺寸不一致。
    a=$((10#$a)); b=$((10#$b))
    # Int32Range: From>To 自动交换 —— 规范化阶段就交换, 使所有下游看到同一区间
    if [ "$a" -gt "$b" ]; then local t="$a"; a="$b"; b="$t"; fi
    if [ "$a" = "$b" ]; then echo "$a"; else echo "${a}-${b}"; fi
}

# 尺寸校验输出空串表示合法，否则输出原因；规范化与校验共用 _hy2_obfs_size_canon。
_hy2_obfs_size_invalid() {
    local raw="$1" canon
    raw="${raw// /}"
    [ -z "$raw" ] && return 0
    if ! [[ "$raw" =~ ^[0-9]+$ || "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo "packetSize 只能是数字或 \"min-max\" 形式"
        return 0
    fi
    canon=$(_hy2_obfs_size_canon "$raw") || { echo "数值超出 Int32Range 可表示范围"; return 0; }
    local a="${canon%%-*}" b="${canon##*-}"
    if [ "$a" -le 0 ]; then
        echo "本脚本要求最小值 >= 1(0 长度分片无意义)"
    elif [ "$b" -gt 2048 ]; then
        echo "最大值不得超过 2048"
    fi
}

# 读取元数据里的 packetSize 值(规范形式, 用于分享链接/clash/回显); 未设置 → 空
_hy2_obfs_size_get() {
    local meta="$1"
    jq -r '(.obfs_packet_size // "") | tostring' "$meta" 2>/dev/null
}

# metadata 统一客户端语义：none/salamander/gecko；旧 salamander+非空 packetSize 按 gecko 读取。

# gecko 默认尺寸 512-1200；官方 Full-Client-Config 的默认范围可省略。
_HY2_GECKO_DEFAULT_SIZE="512-1200"

# 客户端类型只输出 none/salamander/gecko；未知类型拒绝，避免元数据静默漂移。
_hy2_obfs_kind() {
    local meta="$1" otype
    otype=$(jq -r '.obfs_type // empty' "$meta" 2>/dev/null)
    case "$otype" in
        "")         echo "none"; return 0 ;;
        salamander)
            if [ -n "$(_hy2_obfs_size_get "$meta")" ]; then echo "gecko"; else echo "salamander"; fi
            return 0 ;;
        *)          return 1 ;;   # 未知 obfs_type ⇒ fail-closed
    esac
}

# 尺寸是否恰好等于官方默认(= 可被 obfs=gecko 完整表达); 未填/非法 → 1
_hy2_obfs_size_is_default() {
    local canon
    canon=$(_hy2_obfs_size_canon "$(_hy2_obfs_size_get "$1")") || return 1
    [ "$canon" = "$_HY2_GECKO_DEFAULT_SIZE" ]
}

# gecko 自定义尺寸无法用官方 URI 表达；默认 512-1200 可表达(URI-Scheme)。
_hy2_link_unexpressible() {
    # 损坏的 obfs_type(_hy2_obfs_kind rc≠0)按"不是不可表达"处理 —— 调用方会走
    # "保留旧链接 + 如实报告"分支(保守侧), 而不是清空一条可能仍可用的旧链接。
    local meta="$1" auth host port congestion name
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    host=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    port=$(jq -r '.port // empty' "$meta" 2>/dev/null)
    congestion=$(jq -r '.congestion // empty' "$meta" 2>/dev/null)
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    [ -n "$auth" ] && [ -n "$host" ] && [ -n "$port" ] && [ -n "$congestion" ] && [ -n "$name" ] || return 1
    [ "$(_hy2_obfs_kind "$meta")" = "gecko" ] || return 1
    _hy2_obfs_size_is_default "$meta" && return 1
    return 0
}

# 只替换 settings.xd_managed=true 的自有层，关闭用 XD_UDP_NEW=null；外来同类层保留。
# XD_UDP_OUR_TYPE/XD_UDP_OUR_MARKER 为匹配键；udp 是多层数组(finalmask.md)。
XD_UDP_OUR_TYPE="salamander"
XD_UDP_OUR_MARKER="xd_managed"
XD_UDP_JQ_UPSERT='def xd_udp_ours($new): .streamSettings.finalmask.udp = ((.streamSettings.finalmask.udp // []) as $a | ($a | map(.type == $ourtype and (.settings // {})[$ourmark] == true) | index(true)) as $i | if $i == null then (if $new == null then $a else $a + [$new] end) else (if $new == null then $a[0:$i] + $a[$i+1:] else $a[0:$i] + [$new] + $a[$i+1:] end) end); (.inbounds[] | select(.tag == $t)) |= xd_udp_ours($new)'

# 探测无归属标记的 salamander 层；外来层不得由本脚本替换。
_hy2_udp_has_foreign_salamander() {
    local tag="$1"
    _config_jq -e --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" \
        '[.inbounds[]? | select(.tag == $t) | (.streamSettings.finalmask.udp // [])[]
          | select(.type == $ourtype and (.settings // {})[$ourmark] != true)] | length > 0' \
        >/dev/null 2>&1
}

# 从 type/password/packetSize 构造单层并加 xd_managed；gecko 在 Xray 侧仍叫 salamander。
# 非法尺寸返回1且无输出；调用方必须判返码，不把空输出当关闭。
_hy2_obfs_mask_block() {
    local otype="$1" opw="$2" osize="$3" canon=""
    [ -z "$otype" ] && return 0
    canon=$(_hy2_obfs_size_canon "$osize") || return 1
    # 单值(如 "2048")与区间在 Int32Range 下等价; 区间时写成字符串, 单值时写裸数字。
    local size_json=""
    [ -n "$canon" ] && { case "$canon" in *-*) size_json="\"$canon\"" ;; *) size_json="$canon" ;; esac; }
    # 格式串必须是字面量: size_json 的正则一旦放宽, 兼作格式串的实参就是用户可控的
    # printf 格式串注入。这里用 %s 逐个拼装, 用户数据永远只当数据。
    printf '%s' "{\"type\": \"${otype}\", \"settings\": {\"password\": \"${opw}\", \"${XD_UDP_OUR_MARKER}\": true${size_json:+, \"packetSize\": ${size_json}}}}"
}

# gecko 要求 >=v26.6.1；v26.3.27~v26.5.9 无 packetSize，v26.7.11 改为 Int32Range。
# 依据 infra/conf/transport_internet.go 各 tag；旧核心静默忽略未知字段，必须先门控。
_HY2_GECKO_MIN_VER="v26.6.1"
_hy2_gecko_supported() {
    [ -x "$XRAY_BIN" ] || return 1
    declare -F _xray_version_ge >/dev/null 2>&1 || return 1
    # _xray_version_ge <min>: 内部自取当前版本(纯数字三段比较, busybox 安全);
    # 版本读不到时返回 1 = 不满足, 正好是保守侧。
    _xray_version_ge "$_HY2_GECKO_MIN_VER"
}

# masquerade 仅改 hysteriaSettings.masquerade，独立于 finalmask.udp；Xray 使用扁平字段。
# >=v26.3.23 支持基本字段，>=v26.9.8 支持 unix/xForwarded(transport_method.go/hysteria/hub.go)。
_HY2_MASQ_MIN_VER="26.3.23"
_HY2_MASQ_UNIX_MIN_VER="26.9.8"
_hy2_masq_supported() {
    [ -x "$XRAY_BIN" ] || return 1
    declare -F _xray_version_ge >/dev/null 2>&1 || return 1
    _xray_version_ge "$_HY2_MASQ_MIN_VER"
}

# unix socket / xForwarded 的可用性(比 masquerade 本体更晚引入)
_hy2_masq_unix_supported() {
    [ -x "$XRAY_BIN" ] || return 1
    declare -F _xray_version_ge >/dev/null 2>&1 || return 1
    _xray_version_ge "$_HY2_MASQ_UNIX_MIN_VER"
}

# 完整已知字段按 Masquerade json tag 清理；保留未知字段以免覆盖外部配置。
XD_MASQ_KNOWN_KEYS_JSON='["type","dir","url","rewriteHost","xForwarded","insecure","content","headers","statusCode"]'

# 本机支持字段按核心版本筛选；旧核心未知字段不能显示为已生效。
XD_MASQ_KNOWN_KEYS_BASE_JSON='["type","dir","url","rewriteHost","insecure","content","headers","statusCode"]'
_hy2_masq_known_keys_json() {
    if _hy2_masq_unix_supported; then
        printf '%s' "$XD_MASQ_KNOWN_KEYS_JSON"
    else
        printf '%s' "$XD_MASQ_KNOWN_KEYS_BASE_JSON"
    fi
}

# 集合写入(唯一入口)。$m = 新 masquerade 对象, $known = 已知字段表。
# 只命中选中 tag 的那一个入站; 路径不存在时 jq 会自动补齐 streamSettings/hysteriaSettings。
XD_MASQ_JQ_SET='(.inbounds[] | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade) |= ($m + (if ((. // {}) | type) == "object" then (. // {}) else {} end | with_entries(select(.key as $k | ($known | index($k)) | not))))'

# 清除伪装段(= 官方默认 404)。用 del 而不是写 {"type":""}: "默认 404"的唯一表示就是
# 该段不存在(官方 docs: 不填为默认的 404 页面), 少一个形态就少一处"两个值表达同一件事"。
XD_MASQ_JQ_CLEAR='del(.inbounds[] | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade)'

# 去掉首尾空白: read 会保留用户输入的空格, 响应头行 "  Server: x" 不去掉就是非法字段名。
_hy2_masq_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# 当前伪装的一句话描述(菜单唯一展示入口; 单次 jq, 避免"同一状态两处各自解释")。
# type 按核心口径不区分大小写(hub.go: strings.ToLower(config.MasqType))。
_hy2_masq_desc() {
    local tag="$1"
    _config_present || return 0
    _config_jq -r --arg t "$tag" '
        (.inbounds[]? | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade) as $m
        | if ($m | type) != "object" then "默认 404 页面"
          else
            (($m.type // "") | tostring | ascii_downcase) as $ty
            | if $ty == "" or $ty == "404" then "默认 404 页面"
              elif $ty == "file" then "文件伪装: \($m.dir // "")"
              elif $ty == "proxy" then "反向代理: \($m.url // "")"
                   + (if ($m.rewriteHost // false) then " (改写 Host)" else "" end)
                   + (if ($m.insecure // false) then " (跳过证书校验)" else "" end)
                   + (if ($m.xForwarded // false) then " (X-Forwarded)" else "" end)
              elif $ty == "string" then "固定字符串: \(($m.content // "") | length) 字符, HTTP \(if (($m.statusCode // 0) | tostring) != "0" then (($m.statusCode) | tostring) else "200" end)"
                   + (if (($m.headers // {}) | length) > 0 then ", \((($m.headers) | length) | tostring) 个响应头" else "" end)
              else "未知类型 \($ty) —— 核心会拒绝启动, 请改正或改回默认 404" end
          end' 2>/dev/null
}

# 输入校验返回空串或原因；非法输入不返回失败码，避免交互 set -e 误退。
_hy2_masq_url_invalid() {
    local u="$1" scheme host sock
    [ -n "$u" ] || { printf '%s' "URL 不能为空"; return; }
    case "$u" in
        *[[:space:]]*) printf '%s' "URL 不能含空格/制表符(空格需写成 %20)"; return ;;
    esac
    # URL 仅开放本机核心的 scheme；unix/空 scheme 要求 >=v26.9.8(hysteria/hub.go)。
    scheme="${u%%://*}"
    case "$u" in
        http://*|https://*)
            host="${u#*://}"; host="${host%%/*}"
            [ -n "$host" ] || { printf '%s' "URL 缺少主机名(形如 https://example.com)"; return; }
            printf '%s' ""
            return ;;
        unix://*)
            _hy2_masq_unix_supported || { printf '%s' "Unix socket 伪装需要 Xray >= v${_HY2_MASQ_UNIX_MIN_VER}(当前核心不支持, 写入会被静默忽略)"; return; }
            sock="${u#unix://}"
            case "$sock" in
                /*) printf '%s' "" ;;
                *) printf '%s' "unix:// 之后必须是绝对路径(如 unix:///run/site.sock)" ;;
            esac
            return ;;
        /*)
            # 裸绝对路径等价 unix(核心 case "", "unix" 取 u.Path 作 socket 路径)
            _hy2_masq_unix_supported || { printf '%s' "Unix socket 伪装需要 Xray >= v${_HY2_MASQ_UNIX_MIN_VER}(当前核心不支持, 写入会被静默忽略)"; return; }
            printf '%s' ""
            return ;;
    esac
    case "$scheme" in
        "") printf '%s' "URL 缺少 scheme: 请写 http(s)://… 或 unix:///绝对路径"; return ;;
    esac
    printf '%s' "不支持的 scheme ${scheme%%:*}(核心仅认 http / https / unix)"
}

_hy2_masq_dir_invalid() {
    local d="$1"
    [ -n "$d" ] || { printf '%s' "目录不能为空"; return; }
    case "$d" in
        /*) ;;
        *) printf '%s' "请填绝对路径(相对路径会被核心按服务进程的工作目录解析, 结果不可预期)"; return ;;
    esac
    printf '%s' ""
}

_hy2_masq_status_invalid() {
    local s="$1"
    [ -z "$s" ] && { printf '%s' ""; return; }
    [[ "$s" =~ ^[0-9]{3}$ ]] || { printf '%s' "HTTP 状态码必须是 3 位数字(如 200), 留空用 200"; return; }
    [ "$s" -ge 100 ] && [ "$s" -le 599 ] || { printf '%s' "HTTP 状态码须为 100-599(本脚本限制; 越界值核心写响应头时会 panic 并断开连接)"; return; }
    printf '%s' ""
}

# 解析名称:值并合并 headers；重复键覆盖，非法名称或控制字符拒绝。
_hy2_masq_headers_merge() {
    local h="$1" line="$2" name value
    case "$line" in
        *:*) ;;
        *) printf '%s' "格式应为 名称: 值(缺少冒号)"; return 1 ;;
    esac
    name=$(_hy2_masq_trim "${line%%:*}")
    value=$(_hy2_masq_trim "${line#*:}")
    [ -n "$name" ] || { printf '%s' "响应头名称不能为空"; return 1; }
    case "$name" in
        *[[:space:]]*) printf '%s' "响应头名称不能含空白(名称与冒号之间不要留空格)"; return 1 ;;
        *[![:print:]]*) printf '%s' "响应头名称含不可打印字符"; return 1 ;;
    esac
    jq -nc --argjson h "$h" --arg n "$name" --arg v "$value" '$h + {($n): $v}'
}

# payload 一律用 jq --arg 构造；JSON 转义不靠字符串拼接。
_hy2_masq_json_file() {
    jq -nc --arg d "$1" '{type: "file", dir: $d}'
}

# proxy 参数为 rewriteHost/insecure/xForwarded 布尔字面量；headers 是 JSON 对象。
_hy2_masq_json_proxy() {
    local xf="${4:-}"
    if _hy2_masq_unix_supported; then
        jq -nc --arg u "$1" --argjson rh "$2" --argjson ins "$3" --argjson xf "${xf:-false}" \
            '{type: "proxy", url: $u, rewriteHost: $rh, insecure: $ins, xForwarded: $xf}'
    else
        jq -nc --arg u "$1" --argjson rh "$2" --argjson ins "$3" \
            '{type: "proxy", url: $u, rewriteHost: $rh, insecure: $ins}'
    fi
}

# $2 = 状态码字符串(空 = 用核心默认 200); $3 = headers JSON 对象
_hy2_masq_json_string() {
    local c="$1" sc="$2" h=""
    # 空值单独补{}；参数展开内的右花括号会截断默认值并破坏JSON。
    h="${3:-}"
    [ -n "$h" ] || h='{}'
    jq -nc --arg c "$c" --arg sc "$sc" --argjson h "$h" \
        '{type: "string", content: $c}
         + (if $sc == "" then {} else {statusCode: ($sc | tonumber)} end)
         + (if ($h | length) == 0 then {} else {headers: $h} end)'
}

# 空 payload 清除伪装(默认404)，提交复用 _mutate_config；失败按原事务恢复。
_hy2_masq_apply() {
    local tag="$1" payload="${2:-}"
    if [ -z "$payload" ]; then
        _mutate_config --arg t "$tag" "$XD_MASQ_JQ_CLEAR"
    else
        # known 表必须按本机核心能力取(见 _hy2_masq_known_keys_json): 旧核心上把
        # xForwarded 排除在"已知"之外, 它才会作为 unknown key 被原样保留。
        local known
        known=$(_hy2_masq_known_keys_json)
        _mutate_config --arg t "$tag" --argjson m "$payload" --argjson known "$known" "$XD_MASQ_JQ_SET"
    fi
}

# 端口跳跃操作只写本节点 DNAT；删除节点必须同时清理 runtime 与持久化状态。

# 确保 iptables 已安装(Debian 同时装 iptables-persistent 做开机恢复)
_ensure_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    _info "iptables 未安装, 正在安装..."
    local fam
    fam=$(_detect_os_family)
    case "$fam" in
        debian)
            _pkg_install iptables || return 1
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq --no-install-recommends iptables-persistent >/dev/null 2>&1 || true
            ;;
        *)
            _pkg_install iptables || return 1
            ;;
    esac
    if ! command -v iptables >/dev/null 2>&1; then
        _error "iptables 安装失败, 请手动安装"
        return 1
    fi
    _success "iptables 已安装"
}

# 解析端口范围字符串 → "start:end start:end ..."
_parse_hop_ranges() {
    local input="$1"
    local result=""
    local entries
    IFS=',' read -ra entries <<< "$input"
    local all_starts=() all_ends=()
    local entry
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | tr -d ' ')
        [ -z "$entry" ] && continue
        local start end
        if echo "$entry" | grep -q '-'; then
            start=$(echo "$entry" | cut -d'-' -f1)
            end=$(echo "$entry" | cut -d'-' -f2)
        else
            start="$entry"
            end="$entry"
        fi
        if ! _validate_port "$start" || ! _validate_port "$end"; then
            _error "无效端口: $entry"
            return 1
        fi
        if [ "$start" -gt "$end" ]; then
            _error "起始端口大于结束端口: $entry"
            return 1
        fi
        local i
        for ((i=0; i<${#all_starts[@]}; i++)); do
            if [ "$start" -le "${all_ends[$i]}" ] && [ "$end" -ge "${all_starts[$i]}" ]; then
                _error "范围重叠: $entry 与 ${all_starts[$i]}-${all_ends[$i]}"
                return 1
            fi
        done
        all_starts+=("$start")
        all_ends+=("$end")
        if [ "$start" = "$end" ]; then
            result="${result:+$result }${start}"
        else
            result="${result:+$result }${start}:${end}"
        fi
    done
    [ -z "$result" ] && { _error "无有效端口范围"; return 1; }
    echo "$result"
}

# 精确匹配 --to-destination :<port>(边界: 后随空白或行尾, ), 避免 :443 误匹配 :4430/:44300 等其他节点规则
# 用法: 过滤 stdin 中的 iptables -S 行; 与 dport 的 "dport X " / "dport X$" 同风格
_hy2_match_target() {
    local port="$1"
    grep -e "--to-destination :${port} " -e "--to-destination :${port}\$"
}

# 持久化路径统一读取 rules.v4/rules.v6 或 Alpine rules-save；与保存入口一致。
_hy2_conf_save_path() {   # <conf> <key> <default>
    local conf="$1" key="$2" def="$3" line value=""
    if [ -r "$conf" ]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            case "$line" in
                "$key"=*) value="${line#*=}"; break ;;
            esac
        done < "$conf"
    fi
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    case "$value" in
        /*) printf '%s\n' "$value" ;;
        *) printf '%s\n' "$def" ;;
    esac
}

_hy2_iptables_persist_files() {
    local ipt_dir="${HY2_IPTABLES_DIR:-/etc/iptables}"
    local initd_dir="${HY2_INITD_DIR:-/etc/init.d}"
    local conf_dir="${HY2_CONF_DIR:-/etc/conf.d}"
    local fam=""
    declare -F _detect_os_family >/dev/null 2>&1 && fam=$(_detect_os_family 2>/dev/null)
    printf '%s\n' "$ipt_dir/rules.v4" "$ipt_dir/rules.v6"
    if [ "$fam" = alpine ]; then
        _hy2_conf_save_path "$conf_dir/iptables" IPTABLES_SAVE "$ipt_dir/rules-save"
        _hy2_conf_save_path "$conf_dir/ip6tables" IP6TABLES_SAVE "$ipt_dir/rules6-save"
    elif [ -x "$initd_dir/iptables" ] || [ -x "$initd_dir/ip6tables" ]; then
        # A test/container may expose the OpenRC scripts without being classified Alpine;
        # their default save paths are still part of the persistence surface.
        _hy2_conf_save_path "$conf_dir/iptables" IPTABLES_SAVE "$ipt_dir/rules-save"
        _hy2_conf_save_path "$conf_dir/ip6tables" IP6TABLES_SAVE "$ipt_dir/rules6-save"
    fi
}

# 确认无 hop 必须观察 runtime，再确认持久化文件无规则；无法观察返回 UNKNOWN。
# IPv6 三态 ip6tables/absent/unknown：仅无 nft 且未注册 nat 可判 absent；其余保守拒绝。
_hy2_ipv6_state() {
    local q
    if command -v ip6tables >/dev/null 2>&1; then
        printf 'ip6tables\n'; return 0
    fi
    # xtables-nft 下 IPv6 NAT 规则进入 nf_tables, 只查 x_tables 注册表不足以证明不存在。
    if command -v nft >/dev/null 2>&1; then
        printf 'unknown nft\n'; return 0
    fi
    if [ -e /proc/net/ip6_tables_names ]; then
        if ! q=$(cat /proc/net/ip6_tables_names 2>/dev/null); then
            printf 'unknown proc_unreadable\n'; return 0
        fi
        printf '%s\n' "$q" | grep -qx "nat" && { printf 'unknown proc_nat\n'; return 0; }
    fi
    printf 'absent\n'; return 0
}

# 返回: 0 = 有证据表明无 hop 规则; 1 = 有规则, 或无观察能力(UNKNOWN)
_hy2_no_hop_rules_at_all() {
    local q f runtime_clean=0 persist_files persist_rc
    if command -v iptables >/dev/null 2>&1; then
        q=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 1
        printf '%s\n' "$q" | grep -q "xray-deploy-hy2-hop" && return 1
        # IPv6 统一三态观察；未知时保留现场，不猜测无规则。
        case "$(_hy2_ipv6_state)" in
            ip6tables)
                q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || return 1
                printf '%s\n' "$q" | grep -q "xray-deploy-hy2-hop" && return 1
                ;;
            absent) : ;;
            'unknown nft')
                _warn "ip6tables 不可用但检测到 nft, 无法确认是否存在 IPv6 跳跃规则"
                return 1 ;;
            *)
                _warn "无法确认是否存在 IPv6 跳跃规则(IPv6 nat 注册表读不到或已注册 nat)"
                return 1 ;;
        esac
        runtime_clean=1
    else
        # 无 iptables 时仅内核从未使用 nat 可证明无规则；持久化文件缺失不构成 runtime 证据。
        if command -v nft >/dev/null 2>&1; then
            _warn "iptables 不可用但检测到 nft, 无法确认是否存在跳跃规则"
            return 1
        fi
        if [ -e /proc/net/ip_tables_names ]; then
            if ! q=$(cat /proc/net/ip_tables_names 2>/dev/null); then
                return 1   # 存在但读不到(权限/容器限制): UNKNOWN
            fi
            printf '%s\n' "$q" | grep -qx "nat" && return 1   # nat 表在用, 但无从查询内容
        fi
        runtime_clean=1
    fi
    [ "$runtime_clean" -eq 1 ] || return 1
    # runtime 已确认无规则; 持久化文件会在重启时重新加载, 同样必须干净
    persist_files=$(_hy2_iptables_persist_files) || return 1
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        grep -q "xray-deploy-hy2-hop" "$f" 2>/dev/null; persist_rc=$?
        case "$persist_rc" in
            0|2) return 1 ;;
        esac
    done <<< "$persist_files"
    return 0
}

# DNAT 添加幂等且拒绝跨节点冲突；查询失败中止，失败回滚本次已加规则。
_hy2_add_hop_rules() {
    # hop 归属由 dport+目标端口和 metadata 记录；不按外部来源规则推断。
    local hy2_port="$1"; shift
    local range q v6ok="" v6q=""
    if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
        _error "无法读取 PREROUTING 规则(iptables -S 失败), 中止添加"
        return 1
    fi
    # IPv6 快照一次获取并复用。v6ok 标记 ip6tables 命令可用(空表也须进入补建分支);
    # 查询失败仅警告, IPv6 跳跃规则整体跳过(仅 IPv4 生效)。v6q 为空表示"无既有 IPv6 规则"。
    if command -v ip6tables >/dev/null 2>&1; then
        if v6q=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
            v6ok=1
        else
            _warn "无法读取 IPv6 PREROUTING 规则, 本次仅维护 IPv4 跳跃规则(best-effort)"
            v6q=""
            v6ok=""
        fi
    fi
    for range in "$@"; do
        local req_start req_end existing existing_range existing_target existing_start existing_end idx
        req_start="${range%%:*}"
        req_end="$req_start"
        [ "$range" = "$req_start" ] || req_end="${range##*:}"
        while IFS= read -r existing; do
            [[ "$existing" == *xray-deploy-hy2-hop* ]] || continue
            local fields=()
            read -ra fields <<< "$existing"
            existing_range=""; existing_target=""
            for ((idx=0; idx<${#fields[@]}; idx++)); do
                case "${fields[$idx]}" in
                    --dport) existing_range="${fields[$((idx+1))]:-}" ;;
                    --to-destination) existing_target="${fields[$((idx+1))]:-}" ;;
                esac
            done
            [[ "$existing_range" =~ ^[0-9]{1,5}(:[0-9]{1,5})?$ ]] || continue
            existing_start="${existing_range%%:*}"
            existing_end="$existing_start"
            [ "$existing_range" = "$existing_start" ] || existing_end="${existing_range##*:}"
            _validate_port "$existing_start" && _validate_port "$existing_end" || continue
            if [ "$req_start" -le "$existing_end" ] && [ "$req_end" -ge "$existing_start" ]; then
                if [ "$existing_target" != ":${hy2_port}" ]; then
                    _error "端口范围 ${range} 与现有范围 ${existing_range} 数值重叠且指向其他节点, 拒绝添加"
                    return 1
                fi
            fi
        done <<< "$q"

        local dports
        dports=$(printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" \
                | grep -e "dport ${range} " -e "dport ${range}\$")
        if [ -n "$dports" ]; then
            if echo "$dports" | _hy2_match_target "$hy2_port" | grep -q .; then
                :  # 同 dport 且同目标端口已存在: IPv4 幂等跳过(不输出, 不属于本次 CREATED)
            else
                _error "端口范围 ${range} 已被其他节点占用(目标端口不同), 拒绝添加"
                return 1
            fi
        else
            iptables -t nat -A PREROUTING -p udp --dport "${range}" \
                -m comment --comment "xray-deploy-hy2-hop" \
                -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || return 1
            printf 'v4:%s ' "$range"
        fi
        # IPv6 独立补建——即使 IPv4 已存在也检查/添加, 保证 best-effort 可重试
        if [ -n "$v6ok" ]; then
            local v6_existing v6_range v6_target v6_start v6_end
            while IFS= read -r v6_existing; do
                [[ "$v6_existing" == *xray-deploy-hy2-hop* ]] || continue
                local v6_fields=() v6_idx
                read -ra v6_fields <<< "$v6_existing"
                v6_range=""; v6_target=""
                for ((v6_idx=0; v6_idx<${#v6_fields[@]}; v6_idx++)); do
                    case "${v6_fields[$v6_idx]}" in
                        --dport) v6_range="${v6_fields[$((v6_idx+1))]:-}" ;;
                        --to-destination) v6_target="${v6_fields[$((v6_idx+1))]:-}" ;;
                    esac
                done
                [[ "$v6_range" =~ ^[0-9]{1,5}(:[0-9]{1,5})?$ ]] || continue
                v6_start="${v6_range%%:*}"; v6_end="$v6_start"
                [ "$v6_range" = "$v6_start" ] || v6_end="${v6_range##*:}"
                _validate_port "$v6_start" && _validate_port "$v6_end" || continue
                if [ "$req_start" -le "$v6_end" ] && [ "$req_end" -ge "$v6_start" ] \
                   && [ "$v6_target" != ":${hy2_port}" ]; then
                    _error "IPv6 端口范围 ${range} 与现有范围 ${v6_range} 数值重叠且指向其他节点, 拒绝添加"
                    return 1
                fi
            done <<< "$v6q"
            v6d=$(printf '%s\n' "$v6q" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$")
            if [ -n "$v6d" ]; then
                if ! echo "$v6d" | _hy2_match_target "$hy2_port" | grep -q .; then
                    _warn "IPv6 端口范围 ${range} 已被其他规则占用(目标端口不同), 未添加 IPv6 跳跃规则"
                fi
            else
                if ! ip6tables -t nat -A PREROUTING -p udp --dport "${range}" \
                     -m comment --comment "xray-deploy-hy2-hop" \
                     -j DNAT --to-destination ":${hy2_port}" 2>/dev/null; then
                    _warn "IPv6 Hysteria2 跳跃规则添加失败(${range}, 可能缺少 IPv6 NAT 支持)"
                else
                    printf 'v6:%s ' "$range"
                fi
            fi
        fi
    done
}

# 删除先读实际 rule spec 再精确 -D；查询或删除失败不得报告完成。
_hy2_remove_hop_rules() {
    local hy2_port="$1"; shift
    local range remain_any=0 v6ok=0
    # IPv6 观测能力预检(统一走 `_hy2_ipv6_state`, 与另外两个观察点同口径):
    # ip6tables 缺失时只有内核 ip6 x_tables 从未注册 nat 表且无 nft 才能证明无需清理。
    case "$(_hy2_ipv6_state)" in
        ip6tables) v6ok=1 ;;
        absent) : ;;
        'unknown nft')
            _error "ip6tables 不可用但检测到 nft, 无法确认/清理 IPv6 跳跃规则"
            return 1 ;;
        'unknown proc_unreadable')
            _error "无法确认 IPv6 NAT 状态(读取 /proc/net/ip6_tables_names 失败), 中止删除"
            return 1 ;;
        *)
            _error "ip6tables 不可用但内核注册了 IPv6 nat 表, 无法安全清理 IPv6 跳跃规则"
            return 1 ;;
    esac
    for range in "$@"; do
        local q specs
        if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
            _error "无法读取 PREROUTING 规则(iptables -S 失败), 中止删除"
            return 1
        fi
        # 精确锚定 dport 值(其后必须是空白或行尾) + 目标端口精确匹配, 避免单端口 443 子串误匹配 4430:4440 等其他节点规则
        specs=$(printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" \
                | grep -e "dport ${range} " -e "dport ${range}\$" \
                | _hy2_match_target "$hy2_port" | sed 's/^-A/-D/')
        local line
        while IFS= read -r line; do
            [ -n "$line" ] && iptables -t nat $line 2>/dev/null || true
        done <<< "$specs"
        # 删除后核验: 重新查询当前状态(不能用删除前的 q), 若该范围仍残留则显式提示并置失败标记
        local remain
        if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
            _error "无法读取 PREROUTING 规则核验(iptables -S 失败)"
            return 1
        fi
        remain=$(printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" \
                | grep -e "dport ${range} " -e "dport ${range}\$" \
                | _hy2_match_target "$hy2_port")
        if [ -n "$remain" ]; then
            _warn "IPv4 范围 ${range} 的跳跃规则删除后仍残留, 请手动检查"
            remain_any=1
        fi
        if [ "$v6ok" -eq 1 ]; then
            local q6 specs6
            if ! q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
                _error "无法读取 IPv6 PREROUTING 规则, 中止删除"
                return 1
            fi
            specs6=$(printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$" \
                    | _hy2_match_target "$hy2_port" | sed 's/^-A/-D/')
            while IFS= read -r line; do
                if [ -n "$line" ]; then
                    ip6tables -t nat $line 2>/dev/null || remain_any=1
                fi
            done <<< "$specs6"
            if ! q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
                _error "无法读取 IPv6 PREROUTING 规则核验, 中止删除"
                return 1
            fi
            remain=$(printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$" \
                    | _hy2_match_target "$hy2_port")
            if [ -n "$remain" ]; then
                _warn "IPv6 范围 ${range} 的跳跃规则删除后仍残留, 请手动检查"
                remain_any=1
            fi
        fi
    done
    return "$remain_any"
}

# IPv4 save 是权威提交；失败返回1，IPv6 按可观察能力处理。
# v4 规则原子持久化; 目录创建失败计入返回码, 但仍尝试写入。
_hy2_persist_v4_rules() {
    local ipt_dir="$1" ok=0 tmp
    mkdir -p "$ipt_dir" 2>/dev/null || ok=1
    tmp="$ipt_dir/rules.v4.tmp.$$"
    if iptables-save > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$ipt_dir/rules.v4" 2>/dev/null || { rm -f "$tmp"; ok=1; }
    else
        rm -f "$tmp"; ok=1
    fi
    return "$ok"
}

# v6 规则 best-effort 持久化; 无 ip6tables-save 时跳过, 失败只告警。
# ensure_dir=1 时自行创建目录(alpine 缺 init.d ip6tables 的回退路径)。
_hy2_persist_v6_rules() {
    local ipt_dir="$1" ensure_dir="${2:-0}" tmp
    command -v ip6tables-save >/dev/null 2>&1 || return 0
    if [ "$ensure_dir" = 1 ]; then
        mkdir -p "$ipt_dir" 2>/dev/null || _warn "无法创建 $ipt_dir, IPv6 规则持久化失败(best-effort)"
    fi
    tmp="$ipt_dir/rules.v6.tmp.$$"
    if ip6tables-save > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$ipt_dir/rules.v6" 2>/dev/null || { rm -f "$tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
    else
        rm -f "$tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
    fi
    return 0
}

_hy2_persist_iptables() {
    # 需要持久化而无 iptables-save 必须失败；runtime 成功不等于事务完成。
    if ! command -v iptables-save >/dev/null 2>&1; then
        _error "iptables-save 不可用, 无法安全持久化端口跳跃规则(重启后规则会丢失)"
        return 1
    fi
    local ok=0 fam ipt_dir="${HY2_IPTABLES_DIR:-/etc/iptables}" \
        initd_dir="${HY2_INITD_DIR:-/etc/init.d}"
    fam=$(_detect_os_family)
    case "$fam" in
        debian)
            _hy2_persist_v4_rules "$ipt_dir" || ok=1
            _hy2_persist_v6_rules "$ipt_dir"
            ;;
        alpine)
            if [ -x "$initd_dir/iptables" ]; then
                # init.d save 由服务脚本自行管理其持久化文件, 无法原子化, 仅检查返回
                "$initd_dir/iptables" save >/dev/null 2>&1 || ok=1
                # ip6 侧先确认 init.d 脚本存在; 不存在但 ip6tables-save 可用时
                # 回退到直接原子写(与无 init.d 分支一致), 避免调用不存在的脚本 rc127 误报失败
                if [ -x "$initd_dir/ip6tables" ]; then
                    "$initd_dir/ip6tables" save >/dev/null 2>&1 || _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                else
                    _hy2_persist_v6_rules "$ipt_dir" 1
                fi
            else
                _hy2_persist_v4_rules "$ipt_dir" || ok=1
                _hy2_persist_v6_rules "$ipt_dir"
            fi
            ;;
        *)
            _hy2_persist_v4_rules "$ipt_dir" || ok=1
            ;;
    esac
    return "$ok"
}

# hop runtime、持久化、metadata 整体提交；任一失败恢复前态。
_hy2_hop_txn() {
    _with_config_lock _with_config_write_barrier _hy2_hop_txn_locked "$@"
}

_hy2_hop_txn_locked() {
    local op="$1" meta="$2" _stale_newmeta="$3" port="$4"; shift 4
    local created tag orig current_port current_ranges requested_ranges hopmeta newmeta range normalized rs re
    # 非 config writer 的 runtime+metadata 事务也必须遵守同一 pending guard。
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    orig=$(cat "$meta" 2>/dev/null) || { _error "读取 Hysteria2 元数据失败: $meta"; return 1; }
    tag=$(jq -r '.tag // empty' <<< "$orig" 2>/dev/null)
    current_port=$(jq -r '.port // empty' <<< "$orig" 2>/dev/null)
    if [ -z "$tag" ] || [ "$meta" != "$NODES_DIR/${tag}.json" ] || [ "$current_port" != "$port" ] || \
       [ "$(jq -r '.protocol // empty' <<< "$orig" 2>/dev/null)" != hysteria2 ]; then
        _error "节点元数据已变化, 拒绝修改端口跳跃: $meta"
        return 1
    fi
    _hy2_hop_meta_ok "$tag" || return 1
    current_ranges=$(_read_hop_ranges "$meta")
    requested_ranges="$*"
    if [ "$op" = add ]; then
        [ -z "$current_ranges" ] || { _error "节点端口跳跃状态已变化, 请重新选择"; return 1; }
        if ! _config_jq -e --arg t "$tag" --argjson p "$port" '[.inbounds[]? | select(.tag == $t and .protocol == "hysteria" and .port == $p)] | length == 1' >/dev/null 2>&1; then
            _error "config 中的节点已变化, 拒绝启用端口跳跃"
            return 1
        fi
        normalized=""
        for range in "$@"; do
            rs="${range%%:*}"; re="$rs"
            [ "$range" = "$rs" ] || re="${range##*:}"
            if [ "$rs" = "$re" ]; then normalized="${normalized:+$normalized,}$rs"
            else normalized="${normalized:+$normalized,}$rs-$re"
            fi
        done
        hopmeta=$(jq --arg r "$normalized" '.hop_ranges=$r | .udp_hop_ports=$r | del(.hop_start) | del(.hop_end)' <<< "$orig") || return 1
    elif [ "$op" = remove ]; then
        [ -n "$current_ranges" ] && [ "$current_ranges" = "$requested_ranges" ] || {
            _error "节点端口跳跃范围已变化, 请重新选择"; return 1;
        }
        if ! _config_jq -e --arg t "$tag" --argjson p "$port" '[.inbounds[]? | select(.tag == $t and .protocol == "hysteria" and .port == $p)] | length == 1' >/dev/null 2>&1; then
            _error "config 中的节点已变化, 拒绝禁用端口跳跃"
            return 1
        fi
        hopmeta=$(jq 'del(.hop_ranges) | del(.hop_start) | del(.hop_end) | del(.udp_hop_ports)' <<< "$orig") || return 1
    else
        _error "未知的端口跳跃事务类型: $op"
        return 1
    fi
    newmeta=$(_hy2_gen_newmeta "$meta" "$hopmeta") || { _error "重建分享链接失败"; return 1; }
    # 1+2. runtime 修改 + 原子持久化(失败自动回滚 runtime)。保留 CREATED 集合供 metadata
    # 提交失败时精确回滚; add 的幂等跳过项不属于本事务, 不能因后续失败而被删除。
    if ! created=$(_hy2_hop_apply "$op" "$port" "$@"); then
        return 1
    fi
    # 3. 原子提交 metadata(_atomic_write_json 失败时目标文件原样, 无需恢复 metadata)
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "节点 metadata 提交失败, 回滚运行时规则..."
        if [ "$op" = add ]; then
            local created_ranges=()
            [ -n "$created" ] && read -ra created_ranges <<< "$created"
            if [ ${#created_ranges[@]} -gt 0 ]; then
                if ! _hy2_hop_reverse add "$port" "${created_ranges[@]}"; then
                    _error "回滚运行时规则失败, 请手动检查 iptables"
                fi
            fi
        else
            if ! _hy2_hop_reverse remove "$port" "$@"; then
                _error "回滚运行时规则失败, 请手动检查 iptables"
            fi
        fi
        return 1
    fi
    return 0
}

# runtime 修改 + 原子持久化; 持久化失败则回滚 runtime 并重新持久化, 返回 1
_hy2_hop_apply() {
    local op="$1" port="$2"; shift 2
    local created="" rc
    if [ "$op" = add ]; then
        # created 只含本事务实际新增的 family-tagged records; 幂等跳过的既有规则不在内,
        # 回滚只删 CREATED, 绝不误删事务开始前已存在的同目标规则。
        created=$(_hy2_add_hop_rules "$port" "$@"); rc=$?
        if [ "$rc" != 0 ]; then
            _warn "跳跃规则添加失败, 回滚本事务实际新增的规则..."
            # shellcheck disable=SC2086
            _hy2_hop_reverse add "$port" $created || _error "回滚已添加的规则失败, 请手动检查 iptables"
            return 1
        fi
    else
        # 删除残留即失败: 不能让"删了一半"的运行时规则与 metadata 分叉;
        # 用幂等 add 恢复已成功删除的范围(残留规则同 dport+同目标端口会被跳过, 不会重复添加)
        _hy2_remove_hop_rules "$port" "$@" || {
            _warn "旧规则删除不干净, 恢复已删除的规则..."
            _hy2_hop_reverse remove "$port" "$@" || _error "恢复已删除的规则失败, 请手动检查 iptables"
            return 1
        }
    fi
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚运行时规则..."
        if [ "$op" = add ]; then
            # 只回滚本事务新增的 created; remove 分支则恢复全部(本事务删除的都是本次副作用)
            # shellcheck disable=SC2086
            _hy2_hop_reverse add "$port" $created || _error "回滚运行时规则失败, 请手动检查 iptables"
        else
            _hy2_hop_reverse remove "$port" "$@" || _error "回滚运行时规则失败, 请手动检查 iptables"
        fi
        return 1
    fi
    printf '%s' "$created"
    return 0
}

# Remove only transaction-owned family-tagged records emitted by _hy2_add_hop_rules.
# Records are v4:<range> or v6:<range>; an untagged legacy record is treated as v4.
_hy2_remove_created_hop_rules() {
    local port="$1" rec family range cmd q specs line remain rc=0
    shift
    for rec in "$@"; do
        case "$rec" in
            v4:*) family=v4; range="${rec#v4:}" ;;
            v6:*) family=v6; range="${rec#v6:}" ;;
            *) family=v4; range="$rec" ;;
        esac
        [ -n "$range" ] || continue
        if [ "$family" = v6 ]; then cmd=ip6tables; else cmd=iptables; fi
        q=$($cmd -t nat -S PREROUTING 2>/dev/null) || { rc=1; continue; }
        specs=$(printf '%s\n' "$q" | grep 'xray-deploy-hy2-hop' \
            | grep -e "dport ${range} " -e "dport ${range}\$" \
            | _hy2_match_target "$port" | sed 's/^-A/-D/') || specs=""
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            $cmd -t nat $line 2>/dev/null || rc=1
        done <<< "$specs"
        q=$($cmd -t nat -S PREROUTING 2>/dev/null) || { rc=1; continue; }
        remain=$(printf '%s\n' "$q" | grep 'xray-deploy-hy2-hop' \
            | grep -e "dport ${range} " -e "dport ${range}\$" \
            | _hy2_match_target "$port") || remain=""
        [ -z "$remain" ] || rc=1
    done
    return "$rc"
}

# 返回 0=回滚成功; 1=回滚过程中仍有失败(runtime 或持久化), 调用方必须显式报告, 不能当作"已恢复原状"
_hy2_hop_reverse() {
    local op="$1" port="$2"; shift 2
    local ok=0
    if [ "$op" = add ]; then
        _hy2_remove_created_hop_rules "$port" "$@" || ok=1
    else
        # 恢复操作不需要 CREATED 集合输出(add 的 stdout 仅由 _hy2_hop_apply/retarget
        # 按需捕获), 显式丢弃, 避免裸行泄漏到终端
        _hy2_add_hop_rules "$port" "$@" >/dev/null || ok=1
    fi
    _hy2_persist_iptables || ok=1
    return "$ok"
}

# 删除节点前的端口跳跃清理事务: remove + 原子持久化; 任一步失败都恢复 runtime 已删规则并返回 1。
# 调用方必须: teardown 成功才允许删除节点 metadata/config; teardown 失败 -> 取消删除, 节点整体保持原状。
_hy2_hop_teardown() {
    local port="$1"; shift
    if ! _hy2_remove_hop_rules "$port" "$@"; then
        _warn "端口跳跃规则删除不干净, 恢复已删除的规则..."
        local rok=0
        _hy2_add_hop_rules "$port" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables || rok=1
        [ "$rok" = 1 ] && _error "恢复失败, 请手动检查 iptables"
        return 1
    fi
    # persist 失败必须回滚已删除的 runtime 规则, 否则出现 metadata=enabled 而 runtime=disabled 的分裂
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚已删除的运行时规则..."
        _hy2_hop_reverse remove "$port" "$@" || _error "回滚失败, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# 批量 teardown 逐节点记录可删除与跳过项；失败项保留，提交失败恢复已清理规则。
_HY2_HOP_TD=()
_HY2_HOP_SKIP=()
_hy2_hop_teardown_all() {
    # 每个事务从空开始, 避免上一次批量删除的 tag 跨事务残留
    _HY2_HOP_TD=()
    _HY2_HOP_SKIP=()
    local tag total=0
    for tag in "$@"; do
        total=$((total+1))
        local proto hop_port ranges
        # metadata 损坏不能当非HY2；无法定位 hop 时保留节点避免孤儿DNAT。
        if ! proto=$(_node_protocol_safe "$tag"); then
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        [ "$proto" = "hysteria2" ] || continue
        if ! hop_port=$(jq -r '.port // empty' "$NODES_DIR/${tag}.json" 2>/dev/null); then
            _error "节点元数据损坏, 无法确认端口: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        [[ "$hop_port" =~ ^[0-9]+$ ]] || {
            _error "节点元数据损坏(端口无效): $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        }
        # metadata.port 必须与真实监听一致；否则规则目标无法安全定位。
        local cfg_port
        cfg_port=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' 2>/dev/null)
        if [ -n "$cfg_port" ] && [ "$cfg_port" != "$hop_port" ]; then
            _error "节点元数据端口($hop_port)与 config 监听端口($cfg_port)不一致, 无法安全删除: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        # hop 范围字段存在但无法解析 → 拒绝删除该项(不当作"无 hop"跳过 teardown)
        _hy2_hop_meta_ok "$tag" || {
            _HY2_HOP_SKIP+=("$tag")
            continue
        }
        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        [ -n "$ranges" ] || continue
        # 存在 hop 规则但 iptables 不可用 → 无法安全删除(fail-closed; 与单删一致)
        if ! command -v iptables >/dev/null 2>&1; then
            _error "节点存在端口跳跃规则, 但 iptables 不可用, 无法安全删除: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        # shellcheck disable=SC2086
        if ! _hy2_hop_teardown "$hop_port" $ranges; then
            _error "端口跳跃规则清理失败, 已跳过该节点(节点未动): $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        _HY2_HOP_TD+=("$tag")
    done
    if [ ${#_HY2_HOP_SKIP[@]} -gt 0 ]; then
        _warn "以下节点无法安全清理端口跳跃规则, 已从本次删除中排除: ${_HY2_HOP_SKIP[*]}"
    fi
    # 无参调用(total=0)视为成功(无事可做, 避免调用方把"没节点"误判成"全部失败");
    # 有参时"全部被排除"才算失败
    [ "$total" -eq 0 ] && return 0
    [ ${#_HY2_HOP_SKIP[@]} -lt "$total" ]
}

# 从待删列表里剔除 _HY2_HOP_SKIP 中的 tag, 结果写入全局 _HY2_DEL_KEEP。
# 用法: _hy2_filter_skipped "${del_tags[@]}"; del_tags=("${_HY2_DEL_KEEP[@]}")
_HY2_DEL_KEEP=()
_hy2_filter_skipped() {
    _HY2_DEL_KEEP=()
    local t s skip
    for t in "$@"; do
        skip=0
        for s in "${_HY2_HOP_SKIP[@]}"; do
            [ "$s" = "$t" ] && { skip=1; break; }
        done
        [ "$skip" -eq 0 ] && _HY2_DEL_KEEP+=("$t")
    done
}

# 恢复 teardown 的节点用幂等 add+持久化；任一未恢复返回失败保留现场。
_hy2_hop_restore_after_teardown() {
    local tag remain=()
    for tag in "${_HY2_HOP_TD[@]}"; do
        local pp rr
        pp=$(jq -r '.port' "$NODES_DIR/${tag}.json" 2>/dev/null)
        rr=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        # shellcheck disable=SC2086
        if ! _hy2_hop_reverse remove "$pp" $rr 2>/dev/null; then
            _error "恢复端口跳跃规则失败: $tag, 请手动检查 iptables"
            remain+=("$tag")
        fi
    done
    _HY2_HOP_TD=("${remain[@]}")
}

# 端口跳跃改目标端口(metadata 不变): remove old + add new + 原子持久化; 失败回滚到旧端口规则
_hy2_hop_retarget() {
    local oldport="$1" newport="$2"; shift 2
    if ! _hy2_remove_hop_rules "$oldport" "$@"; then
        # 首步 remove 也可能"部分成功"(几个范围删掉、一个残留), 必须先恢复已删范围再中止,
        #      否则 runtime 处于"旧端口规则删了一半"的中间态, 与 metadata 分叉
        _warn "旧端口规则删除不干净, 恢复已删除的规则..."
        local rok=0
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "旧端口规则恢复失败, 请手动检查 iptables"
        return 1
    fi
    # created_new 只含本事务实际新增的 newport 规则(add 输出; 幂等跳过的既有规则
    # 不在内), 后续失败回滚只清理它, 绝不误删 retarget 前已存在的同目标规则
    local created_new rc
    created_new=$(_hy2_add_hop_rules "$newport" "$@"); rc=$?
    if [ "$rc" != 0 ]; then
        _error "新端口跳跃规则添加失败, 恢复旧规则..."
        # 先清理本事务实际新增的新端口规则(created_new), 再恢复旧端口规则(幂等 add 不会重复);
        # 三步都尽力执行并聚合结果
        local rok=0
        # shellcheck disable=SC2086
        _hy2_remove_created_hop_rules "$newport" $created_new 2>/dev/null || rok=1
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "端口回滚不完整, 请手动检查 iptables"
        return 1
    fi
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚到旧端口规则..."
        local rok=0
        # shellcheck disable=SC2086
        _hy2_remove_created_hop_rules "$newport" $created_new 2>/dev/null || rok=1
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "端口回滚不完整, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# 在内存中生成完整新 metadata: 传入 hop 字段变换后的 hopmeta 内容, 重建分享链接(读临时文件,
# 因为 _rebuild_hy2_link 从文件读), 输出 newmeta(hop 字段 + 新 share_link)。失败返回 1(未落地任何文件)。
_hy2_gen_newmeta() {
    local meta="$1" hopmeta="$2" tmp_meta newlink rc
    tmp_meta=$(mktemp "${meta}.hop.XXXXXX") || return 1
    printf '%s' "$hopmeta" > "$tmp_meta" || { rm -f "$tmp_meta"; return 1; }
    newlink=$(_rebuild_hy2_link "$tmp_meta"); rc=$?
    # 两种失败必须区分(同 _hy2_sync_derived): 不可表达(gecko 自定义尺寸) ⇒ 链接留空
    # 是正常结果, clash 能完整承载该尺寸; 元数据缺字段 ⇒ 无法安全重建, 拒绝(不写坏链接)。
    if [ "$rc" != 0 ] && ! _hy2_link_unexpressible "$tmp_meta"; then
        rm -f "$tmp_meta"
        return 1
    fi
    rm -f "$tmp_meta"
    jq --arg l "$newlink" '.share_link=$l' <<< "$hopmeta"
}

# 新 metadata 只在内存构造；端口、名称与分享链接必须一起更新。
_hy2_gen_port_newmeta() {
    local meta="$1" newport="$2" oldport tmpm newlink rc name newname
    oldport=$(jq -r '.port' "$meta")
    [ -n "$oldport" ] || return 1
    name=$(jq -r '.name' "$meta")
    # 仅替换 "-<oldport>" 后缀, 全局子串替换会破坏名称中含端口号的其他数字
    newname=$(_rename_node_with_port "$name" "$oldport" "$newport")
    tmpm=$(mktemp "${meta}.port.XXXXXX") || return 1
    # 临时文件必须同时承载新端口与新名称: 链接的 #fragment 取 .name, 只改端口会让重建出的
    # 链接停在旧名。与 Reality 分支"临时文件承载新 port + 新 name 再重建"同源。
    jq --argjson p "$newport" --arg n "$newname" '.port=$p | .name=$n' "$meta" > "$tmpm" || { rm -f "$tmpm"; return 1; }
    newlink=$(_rebuild_hy2_link "$tmpm"); rc=$?
    # 同 _hy2_sync_derived: gecko 自定义尺寸 ⇒ 链接留空(正常); 元数据缺字段 ⇒ 拒绝
    if [ "$rc" != 0 ] && ! _hy2_link_unexpressible "$tmpm"; then
        rm -f "$tmpm"
        return 1
    fi
    rm -f "$tmpm"
    jq --argjson p "$newport" --arg n "$newname" --arg l "$newlink" \
       '.port=$p | .name=$n | .share_link=$l' "$meta"
}

# hy2+hop 端口事务在锁内：journal→DNAT→metadata→config，失败逆序恢复。
# config 失败保留无法恢复的 journal，启动期由 _port_txn_recover 收敛。
_hy2_port_txn() {
    _with_config_lock _hy2_port_txn_locked "$@"
}

_hy2_port_txn_locked() {
    local tag="$1" meta="$2" oldport="$3" newport="$4" _stale_newmeta="$5"; shift 5
    local ranges="$*" orig journal rok current_port current_ranges
    # 本事务临界区标记(local 动态作用域, 事务返回即消失): 自己的 journal 在写 config 时
    # 不算"未收敛现场" —— 见 _txn_allow_config_write 的 port 段。
    local XD_PORT_TXN_ACTIVE=1
    journal="${meta}.porttxn"
    orig=$(cat "$meta" 2>/dev/null) || { _error "读取元数据失败: $meta"; return 1; }
    current_port=$(jq -r '.port // empty' <<< "$orig" 2>/dev/null)
    if [ "$(jq -r '.tag // empty' <<< "$orig" 2>/dev/null)" != "$tag" ] || \
       [ "$current_port" != "$oldport" ] || ! _validate_port "$oldport" || ! _validate_port "$newport"; then
        _error "节点元数据已变化, 请重新选择端口: $tag"
        return 1
    fi
    if ! _hy2_hop_meta_ok "$tag"; then return 1; fi
    current_ranges=$(_read_hop_ranges "$meta")
    if [ "$current_ranges" != "$ranges" ]; then
        _error "节点端口跳跃范围已变化, 请重新选择端口: $tag"
        return 1
    fi
    if ! _config_jq -e --arg t "$tag" --argjson p "$oldport" \
        '[.inbounds[]? | select(.tag == $t and .protocol == "hysteria" and .port == $p)] | length == 1' \
        >/dev/null 2>&1; then
        _error "config 中的 Hysteria2 端口已变化, 拒绝开始端口事务: $tag"
        return 1
    fi
    if ! newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport"); then
        if [ "$(jq -r 'has("share_link") or has("uuid")' <<< "$orig" 2>/dev/null)" = false ]; then
            local old_name new_name
            old_name=$(jq -r '.name // empty' <<< "$orig" 2>/dev/null)
            new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")
            newmeta=$(jq --argjson p "$newport" --arg n "$new_name" '.port=$p | .name=$n' <<< "$orig") || return 1
        else
            _error "无法从当前元数据重建端口链接, 事务未开始: $tag"
            return 1
        fi
    fi
    # journal 先于第一个 runtime 变更；写失败不触碰真实状态。
    if ! _port_txn_journal_write "$meta" "$meta" hy2hop "$oldport" "$newport" "$ranges" "$orig" "$newmeta"; then
        _error "端口事务 journal 写入失败, 未做任何修改"
        return 1
    fi
    # DNAT retarget 失败仍复核回滚；只有完整恢复才删除 journal。
    if ! _hy2_hop_retarget "$oldport" "$newport" $ranges; then
        return 1
    fi
    # 2. 原子提交 metadata(失败回滚 iptables, config 未动)
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 回滚 iptables 到旧端口..."
        # shellcheck disable=SC2086
        if _hy2_hop_retarget "$newport" "$oldport" $ranges; then
            rm -f "$journal"
        else
            _error "iptables 回滚失败, 保留 journal 待启动恢复: $journal"
        fi
        return 1
    fi
    # 3. 提交 config(_mutate_config 失败会自行恢复旧 config 并重启回旧端口)
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口配置提交失败, 回滚 metadata + iptables 到旧端口..."
        rok=0
        _atomic_write_json "$meta" "$orig" || { _error "元数据回滚失败, 请手动检查"; rok=1; }
        # shellcheck disable=SC2086
        _hy2_hop_retarget "$newport" "$oldport" $ranges || { _error "iptables 回滚失败, 请手动检查"; rok=1; }
        # 两边都回滚干净才删 journal; 任一失败保留它, 启动期恢复幂等收敛
        if [ "$rok" = 0 ]; then
            rm -f "$journal"
        else
            _error "保留 journal 待启动恢复: $journal"
        fi
        return 1
    fi
    rm -f "$journal"
    return 0
}

# _modify_port 的 hy2+hop 分支: 内存生成完整新 metadata -> _hy2_port_txn 统一提交;
# 返回 0=成功, 1=失败(已回滚到旧端口)
_modify_port_hop() {
    local tag="$1" meta="$2" oldport="$3" newport="$4"; shift 4
    local ranges="$*" newmeta display
    display=$(_read_hop_ranges_display "$meta")
    local old_name; old_name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport") || { _error "生成新元数据失败"; return 1; }
    _info "检测到端口跳跃规则, 正在统一事务更新(config/metadata/iptables)..."
    # shellcheck disable=SC2086
    if ! _hy2_port_txn "$tag" "$meta" "$oldport" "$newport" "$newmeta" $ranges; then
        _warn "端口修改未完成, 已回滚到旧端口(config/metadata/iptables 保持一致)"
        _warn "请检查 iptables 环境后重试"
        return 1
    fi
    _tip "端口跳跃规则已更新: ${display} → ${newport}"
    # 派生状态(链接 + clash)走唯一入口, 并传 old_name 删除改名前的 clash 条目
    # (与 _modify_port 非 hop 路径完全同源; hy2 改端口不存在第二份派生逻辑)
    _hy2_sync_derived "$meta" "$old_name" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    return 0
}

# 从元数据读取端口跳跃范围(兼容旧格式 hop_start/hop_end)
_read_hop_ranges() {    local meta="$1"
    # 优先读 hop_ranges (iptables 时代格式)
    local ranges
    ranges=$(jq -r '.hop_ranges // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges" | tr ',' ' ' | tr '-' ':'
        return
    fi
    # 兼容 udp_hop_ports (udpHop 时代格式, 同样可用于 iptables)
    ranges=$(jq -r '.udp_hop_ports // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges" | tr ',' ' ' | tr '-' ':'
        return
    fi
    # 最旧格式兼容
    local hop_s hop_e
    hop_s=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
    hop_e=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
    if [ -n "$hop_s" ] && [ -n "$hop_e" ]; then
        if [ "$hop_s" = "$hop_e" ]; then echo "$hop_s"; else echo "${hop_s}:${hop_e}"; fi
    fi
}

# HY2 hop metadata 校验区分无hop与损坏；损坏时拒绝破坏性操作。
_hy2_hop_meta_ok() {
    local tag="$1"
    local meta="$NODES_DIR/${tag}.json"
    if ! jq -e . "$meta" >/dev/null 2>&1; then
        _error "节点元数据损坏, 无法安全读取: $tag"
        return 1
    fi
    local f v r hs he s e toks tok
    for f in hop_ranges udp_hop_ports; do
        if jq -e "has(\"$f\")" "$meta" >/dev/null 2>&1; then
            v=$(jq -r ".$f" "$meta" 2>/dev/null)
            if [ -z "$v" ]; then
                _error "节点 hop 字段为空, 无法安全操作: $tag ($f)"
                return 1
            fi
            toks=$(printf '%s' "$v" | tr ',' ' ' | tr '-' ':')
            # 字段存在但无任何有效 token(",," 等 → 只剩空白) → 损坏, 不当作"无 hop"
            local ntok=0
            for tok in $toks; do
                ntok=$((ntok+1))
                if [[ "$tok" =~ ^[0-9]+$ ]]; then
                    if ! { [ "$tok" -ge 1 ] && [ "$tok" -le 65535 ]; }; then
                        _error "节点 hop 端口越界(1-65535), 无法安全操作: $tag ($f=$tok)"
                        return 1
                    fi
                elif [[ "$tok" =~ ^([0-9]+):([0-9]+)$ ]]; then
                    s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
                    if ! { [ "$s" -ge 1 ] && [ "$s" -le 65535 ] && [ "$e" -ge 1 ] && [ "$e" -le 65535 ] && [ "$s" -le "$e" ]; }; then
                        _error "节点 hop 范围非法(start/end 或越界), 无法安全操作: $tag ($f=$tok)"
                        return 1
                    fi
                else
                    _error "节点 hop 范围无法解析, 无法安全操作: $tag ($f=$tok)"
                    return 1
                fi
            done
            [ "$ntok" -gt 0 ] || {
                _error "节点 hop 字段无有效范围, 无法安全操作: $tag ($f=$v)"
                return 1
            }
        fi
    done
    if jq -e 'has("hop_start") or has("hop_end")' "$meta" >/dev/null 2>&1; then
        hs=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
        he=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
        # 旧格式键存在即须 hs/he 均为非空数字且 1-65535、start<=end
        if [ -z "$hs" ] || [ -z "$he" ] || \
           ! [[ "$hs" =~ ^[0-9]+$ ]] || ! [[ "$he" =~ ^[0-9]+$ ]] || \
           [ "$hs" -lt 1 ] || [ "$hs" -gt 65535 ] || \
           [ "$he" -lt 1 ] || [ "$he" -gt 65535 ] || [ "$hs" -gt "$he" ]; then
            _error "节点旧格式 hop 范围非法(数值/边界), 无法安全操作: $tag"
            return 1
        fi
    fi
    return 0
}

# 从元数据读取端口跳跃范围(人类可读格式)
_read_hop_ranges_display() {
    local meta="$1"
    local ranges
    ranges=$(jq -r '.hop_ranges // empty' "$meta" 2>/dev/null)
    [ -z "$ranges" ] && ranges=$(jq -r '.udp_hop_ports // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges"
        return
    fi
    local hop_s hop_e
    hop_s=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
    hop_e=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
    if [ -n "$hop_s" ] && [ -n "$hop_e" ]; then
        if [ "$hop_s" = "$hop_e" ]; then echo "$hop_s"; else echo "${hop_s}-${hop_e}"; fi
    fi
}

# 列出所有 xray-deploy 端口跳跃规则(IPv4 + IPv6)
_hy2_list_all_hop_rules() {
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -S PREROUTING 2>/dev/null | grep "xray-deploy-hy2-hop" || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -S PREROUTING 2>/dev/null | grep "xray-deploy-hy2-hop" || true
    fi
}

# 清理候选输出 family(4/6)+精确 spec；仅匹配本项目规则，查询失败不产出成功结果。
_hy2_hop_cleanup_candidates() {
    [ -d "$NODES_DIR" ] || return 0
    local f proto port ranges any=0
    # 先判"是否真有会被删除的节点": 没有 hop 的机器不因 iptables 缺失而阻塞 reset/uninstall。
    # 谓词与下面清理循环一致(protocol=hysteria2 + 非空 ranges + 非空 port)。
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        port=$(jq -r '.port' "$f" 2>/dev/null)
        [ -n "$port" ] || continue
        ranges=$(_read_hop_ranges "$f")
        [ -n "$ranges" ] || continue
        any=1
        break
    done
    [ "$any" -eq 1 ] || return 0
    command -v iptables >/dev/null 2>&1 || return 1
    local q q6="" v6ok=0
    q=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 1
    # 统一三态观察( 之前这里缺 /proc/net/ip6_tables_names 分支, 会只枚举 IPv4,
    # 把可能存在却观察不到的 IPv6 规则漏出恢复源; 现在与另两个观察点完全同口径。
    case "$(_hy2_ipv6_state)" in
        ip6tables)
            # IPv6 与 IPv4 同为"会被删除的 runtime": 查不到就建不起恢复源 ⇒ 返回 1(fail-closed)。
            q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || return 1
            v6ok=1 ;;
        absent) : ;;
        'unknown nft')
            _error "ip6tables 不可用但检测到 nft, 无法枚举 IPv6 端口跳跃恢复源"
            return 1 ;;
        *)
            _error "无法确认 IPv6 NAT 状态(nat 注册表读不到或已注册), 无法枚举 IPv6 端口跳跃恢复源"
            return 1 ;;
    esac
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        port=$(jq -r '.port' "$f" 2>/dev/null)
        [ -n "$port" ] || continue
        ranges=$(_read_hop_ranges "$f")
        [ -n "$ranges" ] || continue
        # 目标端口在节点间唯一(即 hy2 监听端口), 故按 target 取到的就是本节点的全部规则;
        # 即便 metadata 的 range 与 runtime 有出入, 作为"恢复源"取超集也是安全的(回滚只补缺失项)。
        printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" | _hy2_match_target "$port" | sed 's/^/4 /'
        if [ "$v6ok" -eq 1 ]; then
            printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" | _hy2_match_target "$port" | sed 's/^/6 /'
        fi
    done
}

# 恢复候选用 family+spec 精确添加；幂等查询失败也算恢复失败。
_hy2_restore_hop_rules() {
    local line fam spec q="" cur_fam="" ok=0
    [ "$#" -gt 0 ] || return 0
    for line in "$@"; do
        [ -n "$line" ] || continue
        fam="${line%% *}"; spec="${line#* }"
        case "$fam" in
            4) [ "$spec" != "$line" ] || { ok=1; continue; } ;;
            6) [ "$spec" != "$line" ] || { ok=1; continue; } ;;
            *) ok=1; continue ;;
        esac
        if [ "$cur_fam" != "$fam" ]; then
            if [ "$fam" = "4" ]; then
                command -v iptables >/dev/null 2>&1 || { ok=1; cur_fam="$fam"; q=""; continue; }
                q=$(iptables -t nat -S PREROUTING 2>/dev/null) || { ok=1; q=""; }
            else
                command -v ip6tables >/dev/null 2>&1 || { ok=1; cur_fam="$fam"; q=""; continue; }
                q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || { ok=1; q=""; }
            fi
            cur_fam="$fam"
        fi
        printf '%s\n' "$q" | grep -qF -- "$spec" && continue
        # spec 来自 `iptables -S`(`-A PREROUTING ...`, 无引号空白), 直接作为命令回放。
        # shellcheck disable=SC2086
        if [ "$fam" = "4" ]; then
            if iptables -t nat $spec 2>/dev/null; then
                q=$(iptables -t nat -S PREROUTING 2>/dev/null) || { ok=1; q=""; }
            else
                ok=1
            fi
        else
            if ip6tables -t nat $spec 2>/dev/null; then
                q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || { ok=1; q=""; }
            else
                ok=1
            fi
        fi
    done
    return "$ok"
}

# 回滚并刷新持久化均成功才返回0；否则返回1且保留现场。
_hy2_restore_hop_rules_checked() {
    [ "$#" -gt 0 ] || return 0
    if ! _hy2_restore_hop_rules "$@"; then
        _error "回滚未能恢复全部端口跳跃规则, metadata 与 runtime 可能分裂, 请手动检查: iptables -t nat -S PREROUTING"
        return 1
    fi
    if ! _hy2_persist_iptables; then
        _error "端口跳跃规则已恢复到 runtime, 但持久化刷新失败: 重启后状态可能不一致, 现场已保留待重试"
        return 1
    fi
    return 0
}

# 全节点 hop 清理先保存候选再删除和持久化；失败恢复候选。
_hy2_cleanup_all_hops() {
    local found=0 residual=0 metadata_hop=0
    local saved=()
    if [ -d "$NODES_DIR" ] && grep -lq 'hop_ranges\|udp_hop_ports\|hop_start\|hop_end' \
        "$NODES_DIR"/*.json 2>/dev/null; then
        metadata_hop=1
    fi
    if [ "$metadata_hop" -eq 1 ] && ! command -v iptables >/dev/null 2>&1; then
        # metadata says we own hop rules, but cannot issue precise -D or verify runtime:
        # preserve the deployment tree.
        _error "iptables 不可用, 无法安全清理端口跳跃规则(存在 hop metadata), 已保留节点数据"
        return 1
    fi
    if command -v iptables >/dev/null 2>&1 && [ -d "$NODES_DIR" ]; then
        local _cand_all _cand
        # 恢复源建不起来就绝不动 runtime(否则失败后无法回补, 直接造成 metadata/runtime 分裂)。
        if ! _cand_all=$(_hy2_hop_cleanup_candidates 2>/dev/null); then
            _error "无法枚举待清理的端口跳跃规则(恢复源获取失败), 已中止清理以避免 metadata/runtime 分裂"
            return 1
        fi
        while IFS= read -r _cand; do
            [ -n "$_cand" ] && saved+=("$_cand")
        done <<< "$_cand_all"
        for f in "$NODES_DIR"/*.json; do
            [ -f "$f" ] || continue
            local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
            [ "$proto" = "hysteria2" ] || continue
            local port ranges
            port=$(jq -r '.port' "$f" 2>/dev/null)
            ranges=$(_read_hop_ranges "$f")
            if [ -n "$ranges" ] && [ -n "$port" ]; then
                # shellcheck disable=SC2086
                _hy2_remove_hop_rules "$port" $ranges || residual=1
                found=1
            fi
        done
    fi
    if [ "$found" -eq 1 ] && ! _hy2_persist_iptables; then
        _error "iptables 规则持久化失败, 端口跳跃清理未完成"
        residual=1
    fi
    # 无 metadata 也要观察实际DNAT；不能以无节点文件代替清理结果。
    if ! declare -F _hy2_no_hop_rules_at_all >/dev/null 2>&1 || ! _hy2_no_hop_rules_at_all; then
        _error "无法证明端口跳跃规则已清空, 或仍存在孤儿规则; 已保留现场, 请手动检查 iptables -t nat -S PREROUTING"
        residual=1
    fi
    if [ "$residual" -ne 0 ]; then
        if [ "${#saved[@]}" -gt 0 ]; then
            _error "端口跳跃清理未完成, 正在回滚本次已删除的规则, 使 metadata 与 runtime 保持一致..."
            if _hy2_restore_hop_rules_checked "${saved[@]}"; then
                _error "已回滚到清理前状态; 节点数据保留, 请处理后重试"
            else
                _error "回滚未完整收敛(见上), 请手动检查 iptables 与持久化文件后重试"
            fi
        else
            _error "端口跳跃规则清理未完成, 请手动检查 iptables -t nat -S PREROUTING"
        fi
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 通用端口输入(带冲突检测)
# ---------------------------------------------------------------------------

# 生成随机端口(20000-65000)
_gen_random_port() {
    local lo hi range r
    lo=20000; hi=65000; range=$((hi-lo+1))
    # /dev/urandom 取 2 字节做随机数(无 Math.random 限制)
    r=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
    [ -z "$r" ] && r=${RANDOM:-$(( $$ % 45000 + 20000 ))}
    echo $(( lo + (r % range) ))
}

_input_port() {
    local proto="${1:-}"  # optional: tcp, udp, or empty (both)
    local port="" def
    def=$(_gen_random_port)
    while true; do
        read -rp "  监听端口 (回车随机生成): " port
        port=${port:-$def}
        if ! _validate_port "$port"; then
            _warn "无效端口(1-65535)"; continue
        fi
        if _check_port_occupied "$port" "${proto:-}"; then
            _warn "端口 ${port} 已被占用,换一个"; def=$(_gen_random_port); continue
        fi
        if _check_port_in_config "$port"; then
            _warn "端口 ${port} 已被其他节点使用,换一个"; def=$(_gen_random_port); continue
        fi
        break
    done
    echo "$port"
}

# tunnel 只听127.0.0.1，随机端口排除配置与监听冲突；多节点需独立端口。
_gen_free_tunnel_port() {
    local exclude="${1:-}" i r
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        r=$(_gen_random_port)
        [ -n "$exclude" ] && [ "$r" = "$exclude" ] && continue
        _check_port_occupied "$r" "" && continue
        _check_port_in_config "$r" && continue
        printf '%s' "$r"
        return 0
    done
    printf '%s' "$(_gen_random_port)"
    return 0
}

# 检查端口是否已存在于配置
_check_port_in_config() {
    local port="$1"
    # 入口校验: port 必须为数字 (--argjson 对非数字行为未定义)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    _config_present || return 1
    _config_jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Reality 密钥生成(xray x25519)
# 输出全局: REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY / REALITY_SHORT_ID
# ---------------------------------------------------------------------------
_generate_reality_keys() {
    local keypair
    keypair=$(XRAY_LOCATION_ASSET= "$XRAY_BIN" x25519 2>/dev/null)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk -F': ' '/^Private/ {print $2}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk -F': ' '/PublicKey/ {print $2}')
    REALITY_SHORT_ID=$(_gen_short_id)
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "Reality 密钥生成失败"
        return 1
    fi
    _info "Reality 密钥已生成 (PrivateKey: ${REALITY_PRIVATE_KEY:0:8}...)"
}

# 模板占位符读取 R_* 全局并用 jq 输出合法JSON；未知占位符不应进入核心。
_render_template() {
    local tpl="$1" content
    content=$(cat "$tpl" 2>/dev/null)
    [ -z "$content" ] && { _error "模板读取失败: $tpl"; return 1; }

    # 给所有占位符变量设默认空值(避免 set -u 下 unbound; 各协议函数只设自己需要的)
    : "${R_LISTEN:=}" "${R_PORT:=}" "${R_TAG:=}" "${R_UUID:=}" "${R_TARGET:=}"
    : "${R_SERVER_NAME:=}" "${R_PRIVATE_KEY:=}" "${R_SHORT_ID:=}" "${R_PATH:=}"
    : "${R_HOST:=}" "${R_METHOD:=}" "${R_PASSWORD:=}" "${R_MLDSA65_SEED:=}"
    : "${R_AUTH:=}" "${R_CERT_FILE:=}" "${R_KEY_FILE:=}"
    : "${R_CONGESTION:=}" "${R_BRUTAL_PARAMS_BLOCK:=}" "${R_OBFS_MASK_BLOCK:=}"
    : "${R_TUNNEL_PORT:=}" "${R_TUNNEL_TAG:=}"
    : "${R_FLOW:=}" "${R_DECRYPTION:=none}" "${R_NETWORK:=}"

    # 模板已是纯 JSON(无注释),无需 sed 去注释

    # 占位符替换(用变量存 pattern, 避免 ${//\{\{...\}\}//} 转义歧义)
    local p
    p="{{LISTEN}}";       content="${content//$p/"$R_LISTEN"}"
    p="{{PORT}}";         content="${content//$p/"$R_PORT"}"
    p="{{TAG}}";          content="${content//$p/"$R_TAG"}"
    p="{{UUID}}";         content="${content//$p/"$R_UUID"}"
    p="{{TARGET}}";       content="${content//$p/"$R_TARGET"}"
    p="{{SERVER_NAME}}";  content="${content//$p/"$R_SERVER_NAME"}"
    p="{{PRIVATE_KEY}}";  content="${content//$p/"$R_PRIVATE_KEY"}"
    p="{{SHORT_ID}}";     content="${content//$p/"$R_SHORT_ID"}"
    p="{{PATH}}";         content="${content//$p/"$R_PATH"}"
    p="{{HOST}}";         content="${content//$p/"$R_HOST"}"
    p="{{METHOD}}";       content="${content//$p/"$R_METHOD"}"
    p="{{PASSWORD}}";     content="${content//$p/"$R_PASSWORD"}"
    p="{{TUNNEL_PORT}}";  content="${content//$p/"$R_TUNNEL_PORT"}"
    p="{{TUNNEL_TAG}}";   content="${content//$p/"$R_TUNNEL_TAG"}"
    p="{{FLOW}}";          content="${content//$p/"$R_FLOW"}"
    p="{{DECRYPTION}}";    content="${content//$p/"$R_DECRYPTION"}"
    p="{{NETWORK}}";      content="${content//$p/"$R_NETWORK"}"
    p="{{AUTH}}";         content="${content//$p/"$R_AUTH"}"
    p="{{CERT_FILE}}";    content="${content//$p/"$R_CERT_FILE"}"
    p="{{KEY_FILE}}";     content="${content//$p/"$R_KEY_FILE"}"
    p="{{CONGESTION}}";   content="${content//$p/"$R_CONGESTION"}"
    # Hysteria2 brutal 参数块(可选: brutal 模式注入, 否则置空)
    p="{{BRUTAL_PARAMS_BLOCK}}"
    if [ -n "$R_BRUTAL_PARAMS_BLOCK" ]; then
        content="${content//$p/"$R_BRUTAL_PARAMS_BLOCK"}"
    else
        content="${content//$p/}"
    fi
    # Hysteria2 混淆块(可选: 官方文档 finalmask.udp 数组; 未启用混淆时置空 → "udp": [])
    p="{{OBFS_MASK_BLOCK}}"
    if [ -n "$R_OBFS_MASK_BLOCK" ]; then
        content="${content//$p/"$R_OBFS_MASK_BLOCK"}"
    else
        content="${content//$p/}"
    fi
    # 后量子 seed 块(可选)
    p="{{MLDSA65_SEED_BLOCK}}"
    if [ -n "$R_MLDSA65_SEED" ]; then
        content="${content//$p/,
            \"mldsa65Seed\": \"$R_MLDSA65_SEED\"}"
    else
        content="${content//$p/}"
    fi

    # jq 合法化 + 美化(每字段单独行, 2 空格缩进)
    echo "$content" | jq . 2>/dev/null || {
        _error "模板渲染后 JSON 不合法"
        return 1
    }
}

# 配置修改入口：闸门→锁→备份→jq→原子替换→verified restart；失败恢复旧配置。
_mutate_config() {
    # 未收敛 reset journal 阻断常规写入；避免覆盖恢复现场。
    if declare -F _reset_journal_path >/dev/null 2>&1 && [ -e "$(_reset_journal_path 2>/dev/null)" ]; then
        _error "存在未收敛的 reset 事务日志, 已阻止本次配置修改; 请重启脚本以收敛(或先修复现场)"
        return 1
    fi
    _with_config_lock _mutate_config_locked "$@"
}

# 闸门、备份和写入同锁域；禁止锁外检查后再写入的竞态。
_mutate_config_locked() {
    _with_config_write_barrier _mutate_config_write "$@"
}

_mutate_config_write() {
    # 统一闸门: reset / core(仅非终态) / port 三套账本任一未收敛即拒绝。
    # 混装旧 lib 缺 helper 时放行(declare -F 守卫在 helper 内)。
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    if ! _backup_config; then
        _error "配置备份失败,中止操作"
        return 1
    fi
    # 用户 filter 是最后一个参数, 其余是 jq 选项 —— 原样转给 _config_jq(它在合并视图上跑 jq)
    local content user_filter="${!#}"
    local args=("${@:1:$#-1}" "$user_filter")
    if ! content=$(_config_jq "${args[@]}" 2>/dev/null); then
        #  仅失败路径重放一次拿 jq stderr(正常路径零开销),
        # 否则用户只见一句"jq 处理失败", 无法定位是哪段过滤/哪份手改配置出的问题。
        local jq_err; jq_err=$(_config_jq "${args[@]}" 2>&1 >/dev/null | head -3)
        _error "jq 处理失败: ${jq_err:-未知错误}"
        return 1
    fi
    [ -n "$content" ] || { _error "生成的配置为空"; return 1; }
    # 拆回 confs(逐字段原子写)。有文件写失败时现场可能半新半旧, 直接用本次备份整体恢复。
    if ! _config_write_merged "$content"; then
        _error "配置写入失败, 正在回滚"
        _restore_config || _error "回滚失败($BACKUP_DIR/confs.lastbak 不存在或恢复出错)"
        return 1
    fi
    # 低内存 VPS: 不预跑 xray -test(会与运行实例同时加载两份二进制+geo 触发 OOM),
    # 改为重启后校验服务稳定在运行态; 坏配置/被 OOM 都会启动失败并回滚旧配置。
    if ! _restart_xray_verified; then
        _error "xray 启动失败,回滚配置"
        if ! _restore_config; then
            _error "回滚失败($BACKUP_DIR/confs.lastbak 不存在或恢复出错),未尝试重启"
            return 1
        fi
        if _restart_xray_verified; then
            _warn "已回滚到旧配置并重启"
        else
            _error "回滚后 xray 仍启动失败,请手动检查"
        fi
        return 1
    fi
    return 0
}

# 把渲染好的 inbound 加入配置
_commit_inbound() {
    local inbound="$1"
    _mutate_config --argjson nb "$inbound" '.inbounds += [$nb]' || return 1
}

# Reality 专用: tunnel + reality inbound + 2 条路由规则
_commit_reality_inbound() {
    local tunnel="$1" reality="$2" tunnel_tag="$3" domain="$4"
    _mutate_config --argjson tb "$tunnel" --argjson rb "$reality" \
       --arg tg "$tunnel_tag" --arg dom "$domain" \
       '.inbounds += [$tb, $rb] | .routing.rules = [
            {inboundTag: [$tg], domain: [$dom], outboundTag: "direct"},
            {inboundTag: [$tg], outboundTag: "block"}] + .routing.rules' || return 1
}

# 新增节点在锁内复核tag/name，提交metadata与config；失败删除仅本次新建状态。
_commit_node_txn() {            # <tag> <inbound_json> <meta_json> [<clash_line> <name>]
    _with_config_lock _commit_node_txn_locked "$@"
}
_commit_node_txn_locked() {
    local tag="$1" inbound="$2" meta_json="$3" clash_line="${4:-}" name="${5:-}"
    # 锁内占用校验( 锁外的"端口空闲/名称唯一"都是 TOCTOU 检查 —— 并发会话可以
    # 在两次检查之间提交同名/同 tag 节点。这里在真正写入前再验一次, 冲突则整个事务拒绝。
    if [ -e "$NODES_DIR/${tag}.json" ] || \
       _config_jq -e --arg t "$tag" '[.inbounds[]? | select((.tag // "") == $t)] | length > 0' >/dev/null 2>&1; then
        _error "节点 tag 已被占用(可能刚被其他会话创建), 已取消: ${tag}"
        return 1
    fi
    local meta_name
    meta_name=$(printf '%s' "$meta_json" | jq -r '.name // empty' 2>/dev/null)
    if [ -n "$meta_name" ] && ! _ensure_unique_name "$meta_name"; then
        _error "节点名称已被占用(可能刚被其他会话创建), 已取消: ${meta_name}"
        return 1
    fi
    _commit_inbound "$inbound" || return 1
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "元数据写入失败, 正在回滚入站: $tag"
        _mutate_config --arg t "$tag" \
            '.inbounds |= map(select((type != "object") or ((.tag // "") != $t)))' || \
            _error "回滚入站失败, 请手动检查配置: $tag"
        return 1
    fi
    [ -n "$clash_line" ] && { _add_node_to_yaml "$clash_line" "$name" || true; }
    return 0
}

_commit_reality_node_txn() {    # <tag> <tunnel_json> <reality_json> <tunnel_tag> <domain> <meta_json> [<clash_line> <name>]
    _with_config_lock _commit_reality_node_txn_locked "$@"
}

# Hy2证书snapshot/生成和config+metadata提交同锁域；共享 $CERT_DIR/$tag 不能被并发覆盖。
# 失败先恢复证书，无法恢复返回2且保留快照；提交后不得撤销正在引用的证书。
_commit_hy2_node_txn() {
    _with_config_lock _commit_hy2_node_txn_locked "$@"
}
_commit_hy2_node_txn_locked() {
    local tag="$1" name="$2" addr="$3" port="$4" listen="$5" auth="$6" sni="$7" self_signed="$8" self_domain="$9"
    shift 9
    local congestion="$1" brutal_up="$2" brutal_down="$3" obfs_type="$4" obfs_pw="$5" obfs_size="$6" cert_file="$7" key_file="$8"
    if { [ "$congestion" = "brutal" ] || [ "$congestion" = "force-brutal" ]; } &&
       { ! _hy2_brutal_rate_valid "$brutal_up" || ! _hy2_brutal_rate_valid "$brutal_down"; }; then
        _error "brutal 上下行须为有效速率: 0/回车不限, 非零至少 512 kbps (0.5 mbps)"
        return 1
    fi
    if [ "$congestion" = "force-brutal" ] && ! _hy2_force_brutal_up_valid "$brutal_up"; then
        _error "force-brutal 服务器上传至少 524288 bps (512 kbps / 0.5 mbps)"
        return 1
    fi

    # (1) 锁内占用校验 —— 必须在任何证书操作之前, 冲突直接返回且不碰共享证书路径。
    if [ -e "$NODES_DIR/${tag}.json" ] || \
       _config_jq -e --arg t "$tag" '[.inbounds[]? | select((.tag // "") == $t)] | length > 0' >/dev/null 2>&1; then
        _error "节点 tag 已被占用(可能刚被其他会话创建), 已取消且未生成证书: ${tag}"
        return 1
    fi
    if [ -n "$name" ] && ! _ensure_unique_name "$name"; then
        _error "节点名称已被占用(可能刚被其他会话创建), 已取消: ${name}"
        return 1
    fi

    # (2) 自签证书准备。所有提问已经结束, 生成失败/取消路径见各自回滚。
    #     既有证书(可复用)与自定义证书不生成 ⇒ 无快照、不进入回滚路径。
    local cert_bak="" cert_dirty="false" cert_dir_existed="false" cert_dir="$CERT_DIR/$tag"
    if [ "$self_signed" = "true" ]; then
        cert_file="$CERT_DIR/$tag/cert.pem"; key_file="$CERT_DIR/$tag/key.pem"
        local genrc=0
        [ -e "$cert_dir" ] && cert_dir_existed="true"
        if _hy2_cert_reusable "$cert_file" "$key_file" "$self_domain"; then
            # 已有证书且(有 openssl 时)SAN 覆盖本次域名 ⇒ 沿用。无 openssl 时无从校验 SAN,
            # 复用但如实报告, 不假装证书身份已与输入域名统一。
            if ! command -v openssl >/dev/null 2>&1; then
                _warn "无 openssl, 无法校验已有证书 SAN; 将复用既有证书(证书身份可能非 ${self_domain})"
                _tip "如需确保证书 SAN 与域名一致, 请安装 openssl 后重新添加该节点"
            fi
            _info "已有证书, 复用: $cert_dir"
        else
            [ -f "$cert_file" ] && [ -f "$key_file" ] && \
                _warn "已有证书不可复用(SAN 不含 ${self_domain}, 或 cert/key 不匹配), 重新生成: $cert_dir"
            cert_bak=$(_hy2_cert_snapshot "$cert_file" "$key_file") || {
                _error "证书快照失败(无法备份既有证书), 已中止, 未生成新证书"; return 1; }
            _gen_hy2_cert "$tag" "$self_domain" || genrc=$?
            if [ "$genrc" != 0 ]; then
                # 生成失败: 证书已是提交前状态(生成器自带回滚), 丢掉快照即可;
                # 目录是本次新建且已空 ⇒ 顺手清掉(rc=2 的备份必须保留, 绝不动)
                if ! _hy2_cert_snapshot_drop "$cert_bak"; then
                    _warn "证书快照未清理干净(内含旧私钥副本), 请手工删除: $cert_bak"
                fi
                [ "$genrc" = 1 ] && [ "$cert_dir_existed" = "false" ] && rmdir "$cert_dir" 2>/dev/null
                return 1
            fi
            cert_dirty="true"
        fi
        # SNI 优先证书SAN，CN-only兼容回退CN，无读取能力则用本次域名；不得用无关默认值(tls.md)。
        local self_cert_domain
        self_cert_domain=$(_hy2_cert_domain "$cert_file" "$self_domain")
        sni=${self_cert_domain:-$self_domain}
    fi

    # (3) 渲染参数块与 inbound
    local brutal_block=""
    if [ "$congestion" = "brutal" ] || [ "$congestion" = "force-brutal" ]; then
        brutal_block=""
        [ -n "$brutal_up" ] && brutal_block="${brutal_block}, \"brutalUp\": \"${brutal_up}\""
        [ -n "$brutal_down" ] && brutal_block="${brutal_block}, \"brutalDown\": \"${brutal_down}\""
    fi
    local obfs_mask=""
    if [ -n "$obfs_type" ]; then
        if ! obfs_mask=$(_hy2_obfs_mask_block "$obfs_type" "$obfs_pw" "$obfs_size"); then
            _error "混淆参数构造失败"
            _hy2_cert_rollback "$cert_dirty" "$cert_bak" "$cert_file" "$key_file" "$cert_dir" || return 2
            return 1
        fi
    fi
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag"
    R_AUTH="$auth" R_CERT_FILE="$cert_file" R_KEY_FILE="$key_file"
    R_CONGESTION="$congestion" R_BRUTAL_PARAMS_BLOCK="$brutal_block"
    R_OBFS_MASK_BLOCK="$obfs_mask"
    local inbound
    if ! inbound=$(_render_template "$(_tpl_path hysteria2)"); then
        _hy2_cert_rollback "$cert_dirty" "$cert_bak" "$cert_file" "$key_file" "$cert_dir" || return 2
        return 1
    fi

    # (4) canonical metadata → config+metadata 原子提交(复用通用事务的锁内复核)。
    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "hysteria2" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg auth "$auth" --arg sni "$sni" --arg congestion "$congestion" \
        --arg brutalUp "$brutal_up" --arg brutalDown "$brutal_down" \
        --arg obfsType "$obfs_type" --arg obfsPw "$obfs_pw" --arg obfsSize "$obfs_size" \
        --argjson ss "$self_signed" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,auth:$auth,sni:$sni,congestion:$congestion,brutal_up:$brutalUp,brutal_down:$brutalDown,obfs_type:$obfsType,obfs_password:$obfsPw,obfs_packet_size:(if $obfsSize == "" then null else $obfsSize end),self_signed:$ss,share_link:""}')
    if ! _commit_node_txn_locked "$tag" "$inbound" "$meta_json"; then
        _hy2_cert_rollback "$cert_dirty" "$cert_bak" "$cert_file" "$key_file" "$cert_dir" || return 2
        return 1
    fi
    # 配置与 metadata 均已提交(节点已引用该证书) ⇒ 回滚点作废; 删不掉要如实报(快照内含旧私钥副本)
    if [ "$cert_dirty" = "true" ] && ! _hy2_cert_snapshot_drop "$cert_bak"; then
        _warn "证书快照未清理干净(内含旧私钥副本), 请手工删除: $cert_bak"
    fi
    return 0
}
_commit_reality_node_txn_locked() {
    local tag="$1" tunnel="$2" reality="$3" tunnel_tag="$4" domain="$5" meta_json="$6" clash_line="${7:-}" name="${8:-}"
    # 锁内占用校验( tag 与 tunnel_tag 都必须仍空闲; name 也必须仍唯一。
    if [ -e "$NODES_DIR/${tag}.json" ] || \
       _config_jq -e --arg t "$tag" --arg tt "$tunnel_tag" \
          '[.inbounds[]? | select((.tag // "") == $t or (.tag // "") == $tt)] | length > 0' \
          >/dev/null 2>&1; then
        _error "节点 tag 已被占用(可能刚被其他会话创建), 已取消: ${tag}"
        return 1
    fi
    local meta_name
    meta_name=$(printf '%s' "$meta_json" | jq -r '.name // empty' 2>/dev/null)
    if [ -n "$meta_name" ] && ! _ensure_unique_name "$meta_name"; then
        _error "节点名称已被占用(可能刚被其他会话创建), 已取消: ${meta_name}"
        return 1
    fi
    _commit_reality_inbound "$tunnel" "$reality" "$tunnel_tag" "$domain" || return 1
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "元数据写入失败, 正在回滚入站与路由: $tag"
        # 同时移除两个入站与该 tunnel 的路由引用(非对象元素保留, 与删除路径同口径)。
        _mutate_config --arg tg "$tunnel_tag" --arg t "$tag" \
            '.inbounds |= map(select((type != "object") or ((.tag // "") as $x | ($x != $t and $x != $tg))))
             | .routing.rules |= map(select((type != "object") or .inboundTag == null
                   or ([.inboundTag[]? | . as $it | ($it != $tg)] | all)))' || \
            _error "回滚入站/路由失败, 请手动检查配置: $tag"
        return 1
    fi
    [ -n "$clash_line" ] && { _add_node_to_yaml "$clash_line" "$name" || true; }
    return 0
}

# Reality direct 指向伪装站，tunnel 指向本地隧道；两模式使用现有协议键。

# 创建模式选择输出 REALITY_MODE；0已选定，1取消，避免输出文本混入结果。
_prompt_reality_mode() {
    local choice
    REALITY_MODE=""
    while true; do
        echo
        echo -e "  ${CYAN}【Reality 部署模式】${NC}"
        echo -e "  ${GREEN}[1]${NC} 直连模式 (默认) — target 直指伪装站, 仅 1 个入站, 无额外路由"
        echo -e "  ${GREEN}[2]${NC} Tunnel 模式 — 多一个本地 tunnel 入站 + 2 条路由规则, 防偷跑"
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择 (回车=直连): " choice
        case "${choice:-1}" in
            1)
                REALITY_MODE="direct"
                _warn "直连模式: 鉴权失败的流量会被 Reality 直接转发到伪装站"
                _tip "伪装域名若在 CDN 后(如 Cloudflare 站), 可能被扫描后偷跑流量; 建议选非 CDN 的国外站"
                _tip "如需防偷跑请改选 [2] Tunnel 模式"
                return 0
                ;;
            2)
                REALITY_MODE="tunnel"
                _tip "Tunnel 模式会额外占用一个本机随机端口(仅监听 127.0.0.1)"
                return 0
                ;;
            0)
                _info "已取消"
                return 1
                ;;
            *)
                _warn "无效选择"
                ;;
        esac
    done
}

# 模式判定只走 _reality_node_mode，stdout 恒为 direct/tunnel。
# config target 与 metadata 交叉校验，矛盾/未知回退tunnel；direct 不能跳过有疑义的关联检查。
_reality_node_mode() {
    local tag="$1" meta mode ttag target host port cfg_mode
    meta="$NODES_DIR/${tag}.json"

    # 第 1 步: config 归类(实际状态)
    target=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.target // empty' 2>/dev/null) || target=""
    case "$target" in
        *:*) ;;
        *) printf 'tunnel'; return 0 ;;
    esac
    port="${target##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || { printf 'tunnel'; return 0; }
    host="${target%:*}"
    host="${host#[}"
    host="${host%]}"
    if _is_reality_loopback_host "$host"; then
        cfg_mode="tunnel"
    else
        cfg_mode="direct"
    fi

    if [ -f "$meta" ]; then
        mode=$(jq -r '.reality_mode // empty' "$meta" 2>/dev/null) || mode=""
        # 第 2 步: 交叉校验 —— 仅当 metadata 声明合法值; 非法/未知值一律忽略(见上方注释),
        # 落到第 3 步 tunnel_tag / config 判定, 绝不把非法字符串原样返回。
        case "$mode" in
            direct)
                if [ "$cfg_mode" != "direct" ]; then
                    _warn "Reality 节点 $tag: metadata 声明 direct, 但 config target=${target} 非直连, 判定为 tunnel(防绕过)"
                    printf 'tunnel'; return 0
                fi
                printf 'direct'; return 0
                ;;
            tunnel)
                if [ "$cfg_mode" = "direct" ]; then
                    _warn "Reality 节点 $tag: metadata 声明 tunnel, 但 config target=${target} 非回环, 判定为 tunnel(fail-closed)"
                    printf 'tunnel'; return 0
                fi
                printf 'tunnel'; return 0
                ;;
        esac
        # 第 3 步: metadata 无(或非法)reality_mode —— tunnel_tag 非空即 tunnel
        ttag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null) || ttag=""
        [ -n "$ttag" ] && { printf 'tunnel'; return 0; }
    fi

    printf '%s' "$cfg_mode"
    return 0
}

# 回环target判为tunnel；非回环direct不创建隧道。
_is_reality_loopback_host() {
    case "$1" in
        "127.0.0.1"|"::1"|"0:0:0:0:0:0:0:1"|"localhost"|"localhost."|"ip6-localhost"|"ip6-localhost.") return 0 ;;
    esac
    # 127.0.0.0/8: 127.<a>.<b>.<c>, 每段 0-255。10#$ 强制十进制, 避免 08/09 被当八进制
    if [[ "$1" =~ ^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
        if (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 )); then
            return 0
        fi
    fi
    return 1
}

# metadata 每节点独立文件，以原子JSON写入；配置已提交后失败必须如实返回。
_save_node_meta() {
    local tag="$1" json="$2"
    # metadata 是节点身份的一部分；写失败不能当创建完成。
    mkdir -p "$NODES_DIR" || { _error "无法创建节点元数据目录: $NODES_DIR"; return 1; }
    if ! _atomic_write_json "$NODES_DIR/${tag}.json" "$json"; then
        return 1
    fi
    # umask 077 下通常已是 600; chmod 失败属非致命加固项, 提示即可(不阻断写入成功)
    chmod 600 "$NODES_DIR/${tag}.json" 2>/dev/null || _warn "节点元数据权限设置失败(不影响功能): $tag"
    return 0
}

# 节点名必须唯一且精确匹配；Clash/Mihomo 重复名无效，派生缓存按name定位。
_ensure_unique_name() {
    local name="$1" f n rc bad=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$(jq -r '.name // empty' "$f" 2>/dev/null)
        rc=$?
        if [ "$rc" -ne 0 ] || [ ! -s "$f" ]; then
            bad=$((bad+1))
            continue
        fi
        [ -n "$n" ] && [ "$n" = "$name" ] && {
            _error "节点名称已存在: ${name}, 请使用不同名称"
            return 1
        }
    done
    [ "$bad" -eq 0 ] || {
        _warn "有 ${bad} 个节点元数据损坏/为空, 已跳过名称查重(唯一性降级为 best-effort)"
        _tip "请人工核对 ${NODES_DIR} 并修复/删除这些文件, 否则可能出现同名节点"
    }
    return 0
}

# ---------------------------------------------------------------------------
# 询问客户端连接地址(直连场景: 默认公网 IP, 取不到则必填)
# 输出地址到 stdout
# ---------------------------------------------------------------------------
_ask_link_addr() {
    local pubip="" hint
    pubip=$(_get_public_ip 2>/dev/null) || true
    if [ -n "$pubip" ]; then
        local addr
        read -rp "  客户端连接地址 (回车用公网IP ${pubip}): " addr
        addr=${addr:-$pubip}
        echo "$addr"
    else
        _warn "未能自动获取公网 IP,请手动填写客户端连接地址(公网IP或域名)"
        while true; do
            local addr
            # EOF(管道驱动/会话异常)下 read 立即返回且 addr 恒空, 无守卫会死循环刷告警;
            # 显式 return 1, 调用方按"孤儿入站"惯例中止(5 个调用点均校验)。
            read -rp "  客户端连接地址: " addr || return 1
            [ -n "$addr" ] && { echo "$addr"; return 0; }
            _warn "不能为空"
        done
    fi
}

_node_count() {
    local n=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] && n=$((n+1))
    done
    echo "$n"
}

# 删除确认在锁外，锁内比较 _node_identity；防止删除被并发替换的同tag节点。
_node_identity() {
    local tag="$1" meta tt cfg
    meta=$(jq -S -c . "$NODES_DIR/${tag}.json" 2>/dev/null) || return 1
    tt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${tag}.json" 2>/dev/null)
    cfg=$(_config_jq -S -c --arg t "$tag" --arg tt "$tt" \
        '[.inbounds[]? | select((.tag // "") == $t or ($tt != "" and (.tag // "") == $tt))]' \
        2>/dev/null) || return 1
    printf '%s\n%s\n' "$meta" "${cfg:-[]}" | \
        { if command -v cksum >/dev/null 2>&1; then cksum | awk '{print $1":"$2}'; else sha256sum | awk '{print $1}'; fi; }
}

# ---------------------------------------------------------------------------
# 列出配置中有元数据文件的入站 tag 集合(含 tunnel_tag)
# 输出: 每行一个 tag
# ---------------------------------------------------------------------------
_known_tags() {
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        basename "$f" .json
        local ttag
        ttag=$(jq -r '.tunnel_tag // empty' "$f" 2>/dev/null)
        # 损坏/不可读 metadata 显式告警, 不静默丢 tunnel_tag(否则 tunnel 成永久孤儿)
        if [ $? -ne 0 ]; then
            _warn "节点元数据不可读, 无法读取 tunnel_tag: $f"
            continue
        fi
        [ -n "$ttag" ] && echo "$ttag"
    done
}

# 无tag入站补唯一tag；保留现有tag且一次性提交，避免关联定位漂移。
_auto_tag_tagless_inbounds() {
    _config_present || return 0
    _with_config_lock _auto_tag_tagless_inbounds_locked
}
_auto_tag_tagless_inbounds_locked() {
    _config_present || return 0
    # 检查与写入同处 core lock；手工同步也须守住同一恢复闸门。
    _with_config_write_barrier _auto_tag_tagless_inbounds_write
}

_auto_tag_tagless_inbounds_write() {
    # 本函数是直写 config 的入口(不经 _mutate_config), 必须自带核心事务闸门。
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    # 一次性读取所有入站的 tag/port/listen, 减少 jq 调用
    local inbounds_info
    inbounds_info=$(_config_jq -c '[.inbounds | to_entries[] | {idx: .key, tag: (.value.tag // ""), port: (.value.port // 0), listen: (.value.listen // "")}]' 2>/dev/null) || {
        _warn "启动期自动分配 inbound tag 失败: 无法解析 $CONFIG_DIR"
        return 1
    }
    [ -z "$inbounds_info" ] || [ "$inbounds_info" = "[]" ] && return 0

    local used_tags
    used_tags=$(jq -r '.[] | select(.tag != "") | .tag' <<< "$inbounds_info" 2>/dev/null)

    local tagged=0
    local entry idx tag port listen new_tag
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        idx=$(jq -r '.idx' <<< "$entry")
        tag=$(jq -r '.tag' <<< "$entry")
        [ -n "$tag" ] && continue  # 已有 tag, 跳过

        port=$(jq -r '.port' <<< "$entry")
        listen=$(jq -r '.listen' <<< "$entry")

        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] 2>/dev/null; then
            new_tag="manual-${port}"
        elif [ -n "$listen" ]; then
            local sock_name
            sock_name=$(basename "${listen%%,*}" | tr '[:upper:]' '[:lower:]' | sed 's/\.socket$/-socket/' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')
            [ -z "$sock_name" ] && sock_name="sock-${idx}"
            new_tag="manual-${sock_name}"
        else
            new_tag="manual-${idx}"
        fi

        # 去重: 已存在则追加 -2 -3 ...
        local base="$new_tag" n=2
        while grep -qxF "$new_tag" <<< "$used_tags"; do
            new_tag="${base}-${n}"
            n=$((n+1))
        done
        used_tags="${used_tags}"$'\n'"${new_tag}"

        # 补tag原子写config但不重启；写失败中止启动维护。
        local newcfg
        newcfg=$(_config_jq --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].tag = $t') || {
            _warn "启动期为 inbound[$idx] 生成 tag 失败"
            return 1
        }
        _config_write_merged "$newcfg" || {
            _warn "启动期写入 inbound tag 失败: $new_tag"
            return 1
        }
        tagged=$((tagged+1))
    done <<< "$(jq -c '.[]' <<< "$inbounds_info" 2>/dev/null)"

    [ "$tagged" -gt 0 ] && _info "已自动给 ${tagged} 个无 tag 入站分配标识"
    return 0
}

# Reality→tunnel 用回环target端口唯一关联，不用域名/名称；0唯一、1无、2歧义。
_find_reality_tunnel_tag() {
    local tag="$1" proto
    proto=$(_detect_inbound_protocol "$tag")
    case "$proto" in vless-tcp-reality-vision|vless-xhttp-reality) ;; *) return 1 ;; esac
    local target tport n ttag=""
    target=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.target // empty' 2>/dev/null)
    if [ -n "$target" ]; then
        # 非回环target属于direct；不为direct猜测隧道关联。
        local thost="${target%:*}"
        thost="${thost#[}"
        thost="${thost%]}"
        _is_reality_loopback_host "$thost" || return 1
        # 回环target端口必须唯一匹配tunnel.port；多命中不能任取第一条。
        tport="${target##*:}"
        [[ "$tport" =~ ^[0-9]+$ ]] || return 1
        n=$(_config_jq -r --argjson p "$tport" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p)] | length' 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        if [ "$n" -eq 1 ]; then
            ttag=$(_config_jq -r --argjson p "$tport" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p) | .tag][0]' 2>/dev/null)
            printf '%s' "$ttag"
            return 0
        fi
        [ "$n" -gt 1 ] && return 2
        return 1
    fi
    # target 缺失(旧版/手工配置) → legacy tag 后缀 fallback, 同样 count==1 才绑定
    local pport
    pport=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' 2>/dev/null)
    [[ "$pport" =~ ^[0-9]+$ ]] || return 1
    n=$(_config_jq -r --arg sfx "-${pport}" '[.inbounds[] | select(.protocol == "tunnel") | select(.tag | endswith($sfx))] | length' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    if [ "$n" -eq 1 ]; then
        ttag=$(_config_jq -r --arg sfx "-${pport}" '[.inbounds[] | select(.protocol == "tunnel") | select(.tag | endswith($sfx)) | .tag][0]' 2>/dev/null)
        printf '%s' "$ttag"
        return 0
    fi
    [ "$n" -gt 1 ] && return 2
    return 1
}

# protocol 读取失败返回UNKNOWN，不能当非HY2；已证实无hop才允许无损后续操作。
_node_protocol_safe() {
    local tag="$1" proto meta
    # 注意: 不能写成 `local tag="$1" meta="$NODES_DIR/${tag}.json"` —— bash 会先展开
    # local 的全部参数再执行赋值, 那里的 ${tag} 取到的是调用方作用域的 tag(或空), 不是 $1。
    meta="$NODES_DIR/${tag}.json"
    proto=$(jq -r '.protocol // empty' "$meta" 2>/dev/null) || proto=""
    if [ -n "$proto" ]; then
        printf '%s' "$proto"
        return 0
    fi
    if _hy2_no_hop_rules_at_all; then
        _warn "节点元数据损坏或缺少 protocol, 但本机无任何端口跳跃规则, 按非 HY2 处理: $tag"
        printf '%s' "unknown"
        return 0
    fi
    _error "节点元数据损坏且本机存在端口跳跃规则, 无法确认归属, 拒绝删除: $tag"
    _tip "请核对 iptables -t nat -S PREROUTING 与 ${meta}, 手工清理后重试"
    return 1
}

# 反向关联只认回环target+端口；无parent保留孤儿，歧义拒绝自动删除。
_find_reality_for_tunnel_tag() {
    local tag="$1" proto tport target
    proto=$(_detect_inbound_protocol "$tag")
    [ "$proto" = "tunnel" ] || return 0
    tport=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' 2>/dev/null)
    [[ "$tport" =~ ^[0-9]+$ ]] || return 0
    target="127.0.0.1:${tport}"
    _config_jq -r --arg target "$target" \
        '[.inbounds[] | select(.protocol == "vless") | select((.streamSettings.realitySettings.target // "") == $target) | .tag][]' \
        2>/dev/null
}

# ---------------------------------------------------------------------------
_reality_tunnel_has_surviving_refs() {
    local tunnel_tag="$1" refs rt removed found tunnel_count
    shift
    tunnel_count=$(_config_jq -r --arg t "$tunnel_tag" '[.inbounds[]? | select(.tag == $t and .protocol == "tunnel")] | length' 2>/dev/null) || return 2
    [ "$tunnel_count" = 1 ] || return 2
    if ! refs=$(_find_reality_for_tunnel_tag "$tunnel_tag"); then
        return 2
    fi
    while IFS= read -r rt; do
        [ -n "$rt" ] || continue
        found=0
        for removed in "$@"; do
            [ "$rt" = "$removed" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || return 0
    done <<< "$refs"
    return 1
}


# 采纳由配置推断metadata并原子写入；写失败保留未采纳状态。
_adopt_single_inbound() {
    _with_config_lock _adopt_single_inbound_locked "$@"
}
_adopt_single_inbound_locked() {
    # 检查与写入同处 core lock；自动采纳与手工同步共用闸门。
    _with_config_write_barrier _adopt_single_inbound_write "$@"
}

_adopt_single_inbound_write() {
    local tag="$1" suffix="${2:-adopted}"
    # 采纳写 metadata(不经 _mutate_config), 同样属于"未收敛核心事务期间不得变更现场"。
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    local proto port listen
    proto=$(_detect_inbound_protocol "$tag")
    [ "$proto" = "tunnel" ] && return 1

    # name 采用 tag, 必须保持 name 唯一不变量——若现有节点已用该名, 拒绝采纳
    if ! _ensure_unique_name "$tag"; then
        return 1
    fi

    port=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // 0' 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    listen=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen // "::"' 2>/dev/null)
    [ -z "$listen" ] && listen="::"

    local uuid=""
    uuid=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.clients[0].id // empty' 2>/dev/null)
    local sni=""
    sni=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.serverNames[0] // empty' 2>/dev/null)

    # Reality采纳：唯一隧道写tag，无关联兼容空值，歧义拒绝；direct不推导tunnel。
    local ttag="" trc=1 rmode=""
    if [ "$proto" = "vless-tcp-reality-vision" ] || [ "$proto" = "vless-xhttp-reality" ]; then
        rmode=$(_reality_node_mode "$tag")
        if [ "$rmode" = "tunnel" ]; then
            ttag=$(_find_reality_tunnel_tag "$tag"); trc=$?
            if [ "$trc" = "2" ]; then
                _error "Reality tunnel 关联存在歧义(多个 tunnel 命中同端口), 拒绝采纳: $tag"
                return 1
            fi
        fi
    fi

    local link="#${tag} (${suffix})"
    local meta_json
    # direct metadata 不写 tunnel_tag；仅tunnel拓扑追加此键，防止空字段造成错误关联。
    meta_json=$(jq -n \
        --arg tag "$tag" --arg proto "$proto" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg sni "$sni" --arg link "$link" \
        '{tag:$tag,name:$tag,protocol:$proto,port:$port,listen:$listen,uuid:$uuid,sni:$sni,link_addr:$listen,share_link:$link}') || {
        _warn "采纳失败: 元数据生成失败($tag)"
        return 1
    }
    if [ "$rmode" = "tunnel" ]; then
        meta_json=$(echo "$meta_json" | jq --arg ttag "$ttag" '. + {tunnel_tag:$ttag}') || {
            _warn "采纳失败: 元数据生成失败($tag)"
            return 1
        }
    fi
    # 仅 Reality 协议带 reality_mode 字段(其它协议无此概念)
    if [ -n "$rmode" ]; then
        meta_json=$(echo "$meta_json" | jq --arg m "$rmode" '. + {reality_mode:$m}') || {
            _warn "采纳失败: 元数据生成失败($tag)"
            return 1
        }
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _warn "采纳失败: 元数据写入失败($tag)"
        return 1
    fi
    return 0
}

# 孤儿采纳为无metadata入站建身份；歧义关联拒绝而不猜测。
_auto_adopt_orphans() {
    _config_present || return 0
    _with_config_lock _auto_adopt_orphans_locked
}
_auto_adopt_orphans_locked() {
    _config_present || return 0
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"
    local known_list
    known_list=$(_known_tags)

    local tags_json
    tags_json=$(_config_jq -c '[.inbounds[]?.tag // empty]' 2>/dev/null) || {
        _warn "启动期自动采纳孤儿入站失败: 无法解析 $CONFIG_DIR"
        return 1
    }
    [ -z "$tags_json" ] || [ "$tags_json" = "[]" ] && return 0

    local orphans=()
    local tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if ! grep -qxF "$tag" <<< "$known_list"; then
            orphans+=("$tag")
        fi
    done <<< "$(jq -r '.[]' <<< "$tags_json" 2>/dev/null)"

    [ ${#orphans[@]} -eq 0 ] && return 0

    local adopted=0
    for tag in "${orphans[@]}"; do
        if _adopt_single_inbound "$tag" "auto-adopted"; then
            adopted=$((adopted+1))
        fi
    done
    [ "$adopted" -gt 0 ] && _info "已自动采纳 ${adopted} 个手动入站(分享链接需手动重建)"
    return 0
}

# ---------------------------------------------------------------------------
# 从配置入站推断协议类型(按 tag)
# ---------------------------------------------------------------------------
_detect_inbound_protocol() {
    local tag="$1"
    local proto security net
    proto=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .protocol' 2>/dev/null)
    [ "$proto" = "tunnel" ] && { echo "tunnel"; return; }
    if [ "$proto" = "vless" ]; then
        security=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.security // "none"' 2>/dev/null)
        net=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.network // "raw"' 2>/dev/null)
        case "$security" in
            reality)
                case "$net" in
                    xhttp) echo "vless-xhttp-reality" ;;
                    *)     echo "vless-tcp-reality-vision" ;;
                esac ;;
            tls)     echo "vless-tls-$net" ;;
            *)
                # 检测 VLESS+ENC: 有 decryption 字段且 network=raw
                local dec
                dec=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.decryption // empty' 2>/dev/null)
                if [ -n "$dec" ] && [ "$dec" != "none" ] && [ "$net" = "raw" ]; then
                    echo "vless-enc"
                else
                    case "$net" in
                        xhttp)     echo "vless-xhttp-cdn" ;;
                        websocket) echo "vless-ws-cdn" ;;
                        *)         echo "vless-$net" ;;
                    esac
                fi
                ;;
        esac
    elif [ "$proto" = "shadowsocks" ]; then
        echo "shadowsocks"
    elif [ "$proto" = "hysteria" ]; then
        echo "hysteria2"
    else
        echo "$proto"
    fi
}

# ---------------------------------------------------------------------------
# 添加节点:协议分发
# PROTOCOLS 的 name 字段已含对齐空格, 直接打印
# ---------------------------------------------------------------------------
_add_node() {
    clear
    # 跨函数提示不硬编码菜单号；菜单重排不应使导航失真。
    [ -x "$XRAY_BIN" ] || { _error "Xray 未安装,请先到主菜单的 [Xray 核心管理] 安装核心"; _press_any_key; return 1; }
    _ensure_dirs || return 1
    echo
    echo -e "  ${CYAN}【添加节点 — 选择协议】${NC}"
    echo -e "  ${YELLOW}提示: 标记「必须套CDN」的协议不能直连, 需经 CDN 回源${NC}"
    echo
    local i=1
    for p in "${PROTOCOLS[@]}"; do
        local key name tls route desc
        IFS='|' read -r key name tls route desc <<< "$p"
        if [ -n "$desc" ]; then
            printf "  ${GREEN}[%d]${NC} %s   %s\n" "$i" "$name" "$desc"
        else
            printf "  ${GREEN}[%d]${NC} %s\n" "$i" "$name"
        fi
        i=$((i+1))
    done
    echo -e "  ${GREEN}[0]${NC} 返回"
    echo
    read -rp "  请选择协议: " choice
    [ "$choice" = "0" ] && return
    local idx
    idx=$(_xd_index_from_choice "$choice" "${#PROTOCOLS[@]}") || { _warn "无效选择"; _press_any_key; return; }
    local sel="${PROTOCOLS[$idx]:-}"
    [ -z "$sel" ] && { _warn "无效选择"; _press_any_key; return; }

    local key tls route desc
    IFS='|' read -r key name tls route desc <<< "$sel"
    case "$key" in
        vless-tcp-reality-vision) _add_vless_tcp_reality_vision ;;
        vless-xhttp-reality)      _add_vless_xhttp_reality ;;
        vless-enc)                _add_vless_enc ;;
        vless-xhttp-cdn)          _add_vless_xhttp_cdn ;;
        vless-ws-cdn)             _add_vless_ws_cdn ;;
        shadowsocks)              _add_shadowsocks ;;
        hysteria2)                _add_hysteria2 ;;
        *) _warn "未知协议" ;;
    esac
    _press_any_key
}

# add 协议共用助手
_node_name_prompt() {   # 读取节点名(默认 default_name)并查重; 依赖调用方局部 default_name/name
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1
}

_enc_opts_prompt() {   # 提示加密选项并把 R_DECRYPTION 写入调用方作用域
    _prompt_encryption || return 1
    R_DECRYPTION="${ENC_DECRYPTION:-none}"
}

_enc_param() {   # 输出 none 或 url-encoded 加密参数(ENC_ENABLED/ENC_ENCRYPTION)
    if [ "$ENC_ENABLED" -eq 1 ]; then
        _url_encode "$ENC_ENCRYPTION"
    else
        printf 'none'
    fi
}

_enc_meta_json() {   # <meta_json>; 未启用加密时原样返回
    if [ "$ENC_ENABLED" -eq 1 ]; then
        printf '%s' "$1" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}'
    else
        printf '%s' "$1"
    fi
}

# ---------------------------------------------------------------------------
# 协议1: VLESS+TCP+Reality+Vision (可选 直连 / Tunnel 模式, 见 _prompt_reality_mode)
# ---------------------------------------------------------------------------
_add_vless_tcp_reality_vision() {
    _prompt_reality_mode || return 1
    local mode="$REALITY_MODE" mode_label="直连模式"
    [ "$mode" = "tunnel" ] && mode_label="Tunnel 模式·防偷跑"
    echo -e "\n  ${CYAN}=== VLESS+TCP+Reality+Vision (${mode_label}) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}
    # SNI 会被拼进 tunnel inbound tag, 含空格/引号会破坏按 tag 的关联匹配
    _validate_domain "$sni" || { _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $sni"; return 1; }

    # 直连模式无 tunnel 入站, 不申请 tunnel 端口
    # 生成放在 Reality 端口输入之后, 以便把用户端口加入排除项
    local tunnel_port=""
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)
    if [ "$mode" = "tunnel" ]; then
        tunnel_port=$(_gen_free_tunnel_port "$port")
        _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    fi

    local default_name="Reality-Vision-${port}"
    _node_name_prompt || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    _enc_opts_prompt || return 1

    local tag="xd-reality-vision-${port}"
    local tunnel_tag=""
    local listen="::"
    local reality_json

    if [ "$mode" = "tunnel" ]; then
        # tag 长度封顶(见 _gen_tunnel_tag), 避免最长合法 SNI 拼出 270+ 字符的 tag
        tunnel_tag=$(_gen_tunnel_tag "$sni" "$tunnel_port" "$port")
        # 渲染 tunnel inbound
        R_LISTEN="127.0.0.1" R_PORT="$tunnel_port" R_TAG="$tunnel_tag" R_TARGET="$sni"
        local tunnel_json
        tunnel_json=$(_render_template "$(_tpl_path tunnel)") || return 1

        # 渲染 reality inbound (target → 127.0.0.1:<tunnel_port>)
        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_TUNNEL_PORT="$tunnel_port" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-tcp-reality-vision-tunnel)") || return 1

    else
        # 直连: target = <sni>:443, 只提交 1 个入站, 不写任何路由规则
        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_TARGET="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-tcp-reality-vision-direct)") || return 1
    fi

    #  连接地址询问必须在 config 提交前完成, config+metadata 由事务一次性提交
    local addr; addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址(输入已结束), 已取消(未写入 config)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    local enc_param
    enc_param=$(_enc_param)
    # 分享链接标准(XTLS VMess/VLESS 提案): type 必须是 tcp(不是 raw)、REALITY 时 fp 不可省略
    # 且默认 chrome、sni 等 URL 字段 Value 一律 encodeURIComponent。
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    # 所有用户字段经 _yaml_dq 双引号转义；派生YAML不能改变字段结构。
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, flow: xtls-rprx-vision, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, network: tcp}"

    # reality_mode 是模式的权威标记(见 _reality_node_mode); 直连节点不写 tunnel_tag/tunnel_port
    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-tcp-reality-vision" \
        --arg mode "$mode" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg pqv "$pq_verify" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,reality_mode:$mode,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,mldsa65_verify:$pqv,share_link:$link}')
    if [ "$mode" = "tunnel" ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
            '. + {tunnel_tag:$ttag,tunnel_port:$tport}')
    fi
    meta_json=$(_enc_meta_json "$meta_json")
    # 原子提交( config + metadata + 派生 YAML(metadata 失败会回滚入站/路由)。
    if [ "$mode" = "tunnel" ]; then
        _commit_reality_node_txn "$tag" "$tunnel_json" "$reality_json" "$tunnel_tag" "$sni" "$meta_json" "$clash" "$name" || return 1
    else
        _commit_node_txn "$tag" "$reality_json" "$meta_json" "$clash" "$name" || return 1
    fi

    _success "节点 [${name}] 创建成功"
    if [ "$mode" = "tunnel" ]; then
        _tip "Tunnel: ${tunnel_port} → ${sni}:443 | Reality: ${port}"
    else
        _tip "直连: Reality ${port} → target ${sni}:443 (无 tunnel 入站/路由规则)"
    fi
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议2: VLESS+XHTTP+Reality (可选 直连 / Tunnel 模式, 见 _prompt_reality_mode)
# ---------------------------------------------------------------------------
_add_vless_xhttp_reality() {
    _prompt_reality_mode || return 1
    local mode="$REALITY_MODE" mode_label="直连模式"
    [ "$mode" = "tunnel" ] && mode_label="Tunnel 模式·防偷跑"
    echo -e "\n  ${CYAN}=== VLESS+XHTTP+Reality (${mode_label}) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}
    # SNI 会被拼进 tunnel inbound tag, 含空格/引号会破坏按 tag 的关联匹配
    _validate_domain "$sni" || { _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $sni"; return 1; }

    # 直连模式无 tunnel 入站, 不申请 tunnel 端口
    # 生成放在 Reality 端口输入之后, 以便把用户端口加入排除项
    local tunnel_port=""
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)
    if [ "$mode" = "tunnel" ]; then
        tunnel_port=$(_gen_free_tunnel_port "$port")
        _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    fi

    local path=$(_gen_rand_path)
    read -rp "  XHTTP path (默认 ${path}): " custom_path
    path=${custom_path:-$path}
    # path 直拼 JSON 模板, 含 " \ 换行或 {{ 占位符会让渲染失败/值被二次替换, 输入侧拒绝
    _validate_json_text "$path" || { _error "path 含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="Reality-XHTTP-${port}"
    _node_name_prompt || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    _enc_opts_prompt || return 1

    local tag="xd-reality-xhttp-${port}"
    local tunnel_tag=""
    local listen="::"
    local reality_json

    if [ "$mode" = "tunnel" ]; then
        # tag 长度封顶(见 _gen_tunnel_tag)
        tunnel_tag=$(_gen_tunnel_tag "$sni" "$tunnel_port" "$port")

        R_LISTEN="127.0.0.1" R_PORT="$tunnel_port" R_TAG="$tunnel_tag" R_TARGET="$sni"
        local tunnel_json
        tunnel_json=$(_render_template "$(_tpl_path tunnel)") || return 1

        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_PATH="$path" R_TUNNEL_PORT="$tunnel_port" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-xhttp-reality-tunnel)") || return 1

    else
        # 直连: target = <sni>:443, 单入站提交, 无路由规则
        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_TARGET="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_PATH="$path" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-xhttp-reality-direct)") || return 1
    fi

    #  连接地址询问必须在 config 提交前完成
    local addr; addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址(输入已结束), 已取消(未写入 config)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    local enc_param
    enc_param=$(_enc_param)
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=xhttp&mode=auto&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}&path=$(_url_encode "$path")"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    # clash yaml (mihomo 格式): 见 _add_vless_tcp_reality_vision 同处注释 ——
    # support-x25519mlkem768 必须显式开启, client-fingerprint 用 chrome。
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, network: xhttp, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\"}}"

    # reality_mode 是模式的权威标记(见 _reality_node_mode); 直连节点不写 tunnel_tag/tunnel_port
    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-reality" \
        --arg mode "$mode" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg path "$path" --arg pqv "$pq_verify" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,reality_mode:$mode,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,path:$path,mldsa65_verify:$pqv,share_link:$link}')
    if [ "$mode" = "tunnel" ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
            '. + {tunnel_tag:$ttag,tunnel_port:$tport}')
    fi
    meta_json=$(_enc_meta_json "$meta_json")
    # 原子提交( config + metadata + 派生 YAML(metadata 失败会回滚入站/路由)。
    if [ "$mode" = "tunnel" ]; then
        _commit_reality_node_txn "$tag" "$tunnel_json" "$reality_json" "$tunnel_tag" "$sni" "$meta_json" "$clash" "$name" || return 1
    else
        _commit_node_txn "$tag" "$reality_json" "$meta_json" "$clash" "$name" || return 1
    fi

    _success "节点 [${name}] 创建成功"
    if [ "$mode" = "tunnel" ]; then
        _tip "Tunnel: ${tunnel_port} → ${sni}:443 | Reality: ${port}"
    else
        _tip "直连: Reality ${port} → target ${sni}:443 (无 tunnel 入站/路由规则)"
    fi
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# VLESS+ENC 无TLS直连；创建密钥、客户端encryption与服务端decryption保持成对。

# xray vlessenc 本地生成密钥；解析或生成失败必须中止创建。
_generate_vless_enc_keys() {
    local auth_type="${1:-x25519}"
    local output
    output=$(XRAY_LOCATION_ASSET= "$XRAY_BIN" vlessenc 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$output" ]; then
        _error "VLESS+ENC 密钥生成失败 (需要较新版本的 Xray 核心)"
        return 1
    fi

    VLESS_ENC_DECRYPTION=""
    VLESS_ENC_ENCRYPTION=""

    # 检测新版格式: 包含 "Authentication:" section header
    if echo "$output" | grep -q "^Authentication:"; then
        _info "检测到新版 vlessenc 输出, 选择认证: ${auth_type}"
        VLESS_ENC_DECRYPTION=$(echo "$output" | awk -v target="$auth_type" '
            /^Authentication:/ {
                line = tolower($0); gsub(/-/, "", line)
                in_section = (index(line, target) > 0); next
            }
            in_section && /^"decryption":/ {
                sub(/.*"decryption"[[:space:]]*:[[:space:]]*"/, "")
                sub(/".*/, "")
                print
            }
        ' | head -1)
        VLESS_ENC_ENCRYPTION=$(echo "$output" | awk -v target="$auth_type" '
            /^Authentication:/ {
                line = tolower($0); gsub(/-/, "", line)
                in_section = (index(line, target) > 0); next
            }
            in_section && /^"encryption":/ {
                sub(/.*"encryption"[[:space:]]*:[[:space:]]*"/, "")
                sub(/".*/, "")
                print
            }
        ' | head -1)
        # section-aware grep+sed 兜底: awk 窄化到目标 section, 再 grep+sed 提取值
        if [ -z "$VLESS_ENC_DECRYPTION" ] || [ -z "$VLESS_ENC_ENCRYPTION" ]; then
            local section
            section=$(echo "$output" | awk -v target="$auth_type" '
                /^Authentication:/ { line = tolower($0); gsub(/-/, "", line); in_section = (index(line, target) > 0); next }
                in_section { print }
            ')
            if [ -z "$VLESS_ENC_DECRYPTION" ]; then
                VLESS_ENC_DECRYPTION=$(echo "$section" | grep '"decryption"' | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
            fi
            if [ -z "$VLESS_ENC_ENCRYPTION" ]; then
                VLESS_ENC_ENCRYPTION=$(echo "$section" | grep '"encryption"' | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
            fi
        fi
    else
        # 旧版格式回退: jq 优先(纯 JSON 场景)
        VLESS_ENC_DECRYPTION=$(echo "$output" | jq -r '.decryption // empty' 2>/dev/null)
        VLESS_ENC_ENCRYPTION=$(echo "$output" | jq -r '.encryption // empty' 2>/dev/null)
        # grep + sed 兜底(输出含额外文本时 jq 会失败)
        if [ -z "$VLESS_ENC_DECRYPTION" ]; then
            VLESS_ENC_DECRYPTION=$(echo "$output" | grep '"decryption"' | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        fi
        if [ -z "$VLESS_ENC_ENCRYPTION" ]; then
            VLESS_ENC_ENCRYPTION=$(echo "$output" | grep '"encryption"' | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        fi
    fi

    if [ -z "$VLESS_ENC_DECRYPTION" ] || [ -z "$VLESS_ENC_ENCRYPTION" ]; then
        _error "VLESS+ENC 密钥解析失败 (xray vlessenc 输出格式异常)"
        return 1
    fi
    _info "VLESS+ENC 密钥已生成 (decryption: ${VLESS_ENC_DECRYPTION:0:30}...)"
}

# VLESS 内置加密选项提示(供各 VLESS 变体复用)
# 设置全局变量: ENC_ENABLED, ENC_AUTH, ENC_DECRYPTION, ENC_ENCRYPTION
_prompt_encryption() {
    local choice
    echo ""
    _info "VLESS 内置加密 (encryption):"
    echo "  0) 不启用 (默认)"
    echo "  1) X25519 (经典 ECDH, 兼容性最好)"
    echo "  2) ML-KEM-768 (后量子, 需客户端 PQC 支持)"
    read -rp "  请选择(0-2, 默认 0): " choice
    ENC_ENABLED=0; ENC_AUTH=""; ENC_DECRYPTION=""; ENC_ENCRYPTION=""
    case "${choice:-0}" in
        1)
            if ! _generate_vless_enc_keys x25519; then return 1; fi
            ENC_ENABLED=1; ENC_AUTH="x25519"
            ENC_DECRYPTION="$VLESS_ENC_DECRYPTION"
            ENC_ENCRYPTION="$VLESS_ENC_ENCRYPTION"
            ;;
        2)
            if ! _generate_vless_enc_keys mlkem768; then return 1; fi
            ENC_ENABLED=1; ENC_AUTH="mlkem768"
            ENC_DECRYPTION="$VLESS_ENC_DECRYPTION"
            ENC_ENCRYPTION="$VLESS_ENC_ENCRYPTION"
            ;;
    esac
    return 0
}

_add_vless_enc() {
    echo -e "\n  ${CYAN}=== VLESS+ENC (内置加密 · 无 TLS · 类似 SS 轻量直连) ===${NC}"
    local port=$(_input_port tcp)

    # 认证算法选择
    echo -e "  认证算法:"
    echo -e "  ${GREEN}[1]${NC} X25519 (默认, 兼容性好)"
    echo -e "  ${GREEN}[2]${NC} ML-KEM-768 (Post-Quantum, 抗量子攻击)"
    read -rp "  选择 (默认 1): " auth_choice
    local AUTH_TYPE="x25519"
    [ "${auth_choice:-1}" = "2" ] && AUTH_TYPE="mlkem768"

    # flow 选项(xtls-rprx-vision 可启用 splice 优化)
    echo -e "  流控模式:"
    echo -e "  ${GREEN}[1]${NC} 无 (默认, 通用兼容)"
    echo -e "  ${GREEN}[2]${NC} xtls-rprx-vision (splice 优化, 性能更好)"
    read -rp "  选择 (默认 1): " flow_choice
    local flow=""
    [ "${flow_choice:-1}" = "2" ] && flow="xtls-rprx-vision"

    local default_name="ENC-${port}"
    _node_name_prompt || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_vless_enc_keys "$AUTH_TYPE" || return 1

    local tag="xd-vless-enc-${port}"
    local listen="::"

    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
    R_FLOW="$flow" R_DECRYPTION="$VLESS_ENC_DECRYPTION"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-enc)") || return 1
    #  连接地址询问提前到提交之前; config+metadata 由事务一次性提交
    local addr; addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址(输入已结束), 已取消(未写入 config)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"

    # 分享链接: encryption 参数为客户端密钥(URL 编码, 含点号和特殊字符); type=tcp 符合分享链接标准
    local enc_encoded; enc_encoded=$(_url_encode "$VLESS_ENC_ENCRYPTION")
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_encoded}&security=none&type=tcp"
    [ -n "$flow" ] && link="${link}&flow=${flow}"
    link="${link}#$(_url_encode "$name")"

    # clash yaml (Clash Meta / mihomo 格式)
    local clash_flow=""
    [ -n "$flow" ] && clash_flow=", flow: ${flow}"
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, encryption: \"$(_yaml_dq "$VLESS_ENC_ENCRYPTION")\", network: tcp, tls: false${clash_flow}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-enc" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg flow "$flow" --arg auth "$AUTH_TYPE" \
        --arg dec "$VLESS_ENC_DECRYPTION" --arg enc "$VLESS_ENC_ENCRYPTION" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,flow:$flow,auth:$auth,decryption:$dec,encryption:$enc,share_link:$link}')
    _commit_node_txn "$tag" "$inbound" "$meta_json" "$clash" "$name" || return 1

    _success "节点 [${name}] 创建成功"
    [ -n "$flow" ] && _tip "已启用 xtls-rprx-vision (splice 优化)"
    _tip "认证算法: ${AUTH_TYPE}"
    [ "$AUTH_TYPE" = "mlkem768" ] && _tip "ML-KEM-768 需客户端支持 Post-Quantum 加密"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议4: VLESS+XHTTP(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_xhttp_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+XHTTP (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port
    port=$(_input_port tcp)
    # 走 CDN 建议用 CF 支持的 HTTP 端口(仅警告, 不强制)
    case "$port" in 80|8080|8880|2052|2082|2086|2095|443|2053|2083|2087|2096|8443) ;; *)
        _warn "非 CF 推荐端口, 建议使用 80/8080/2052/2086/2095 等, 仍可继续"
        ;;
    esac

    local host
    read -rp "  CDN 域名(Host, 你在 CF 绑定的域名): " host
    [ -z "$host" ] && { _warn "CDN 协议必须填域名"; return 1; }
    # Host 会进 inbound 模板与 clash 条目; 含空格/引号会破坏模板渲染与 YAML
    _validate_domain "$host" || { _error "CDN 域名格式非法(仅字母/数字/连字符, 点分段): $host"; return 1; }

    local preferred_addr
    read -rp "  优选域名/IP(分享链接使用, 默认 ${host}): " preferred_addr
    preferred_addr=${preferred_addr:-$host}

    local preferred_port
    read -rp "  优选端口(默认 443): " preferred_port
    preferred_port=${preferred_port:-443}
    [[ "$preferred_port" =~ ^[0-9]+$ && "$preferred_port" -ge 1 && "$preferred_port" -le 65535 ]] || { _warn "端口无效, 使用默认 443"; preferred_port=443; }

    local path=$(_gen_rand_path)
    read -rp "  XHTTP path (默认 ${path}): " custom_path
    path=${custom_path:-$path}
    # 见 _add_vless_xhttp_reality 同处说明
    _validate_json_text "$path" || { _error "path 含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="XHTTP-CDN-${port}"
    _node_name_prompt || return 1

    local uuid; uuid=$(_gen_uuid) || return 1

    _enc_opts_prompt || return 1

    local tag="xd-xhttp-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-xhttp-cdn)") || return 1

    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local enc_param
    enc_param=$(_enc_param)
    # 分享链接标准: fp 默认 chrome; 标准无 insecure/allowInsecure 字段(Xray 已移除该配置项),
    # 且本节点经 CF 边缘合法证书, 无需跳过校验; sni/host 必须 encodeURIComponent
    local link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$host")&fp=chrome&alpn=h2&type=xhttp&mode=auto&host=$(_url_encode "$host")&path=$(_url_encode "$path")#$(_url_encode "$name")"
    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$preferred_addr")\", port: $preferred_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": chrome, network: xhttp, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\", host: \"$(_yaml_dq "$host")\"}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-cdn" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg host "$host" --arg path "$path" \
        --arg preferred_addr "$preferred_addr" --argjson preferred_port "$preferred_port" \
        --arg sni "$host" --arg fp "chrome" --arg alpn "h2" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$preferred_addr,uuid:$uuid,host:$host,path:$path,preferred_addr:$preferred_addr,preferred_port:$preferred_port,sni:$sni,fp:$fp,alpn:$alpn,share_link:$link}')
    meta_json=$(_enc_meta_json "$meta_json")
    _commit_node_txn "$tag" "$inbound" "$meta_json" "$clash" "$name" || return 1

    _success "节点 [${name}] 创建成功"
    _warn "请确保: CF 已将该域名指向本机并开启小黄云(代理), SSL 模式 Flexible"
    echo -e "  ${CYAN}分享链接(经CDN):${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议5: VLESS+WS(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_ws_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+WS (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port=$(_input_port tcp)

    local host
    read -rp "  CDN 域名(Host, 你在 CF 绑定的域名): " host
    [ -z "$host" ] && { _warn "CDN 协议必须填域名"; return 1; }
    # Host 会进 inbound 模板与 clash 条目; 含空格/引号会破坏模板渲染与 YAML
    _validate_domain "$host" || { _error "CDN 域名格式非法(仅字母/数字/连字符, 点分段): $host"; return 1; }

    local preferred_addr
    read -rp "  优选域名/IP(分享链接使用, 默认 ${host}): " preferred_addr
    preferred_addr=${preferred_addr:-$host}

    local preferred_port
    read -rp "  优选端口(默认 443): " preferred_port
    preferred_port=${preferred_port:-443}
    [[ "$preferred_port" =~ ^[0-9]+$ && "$preferred_port" -ge 1 && "$preferred_port" -le 65535 ]] || { _warn "端口无效, 使用默认 443"; preferred_port=443; }

    local path=$(_gen_rand_path)
    read -rp "  WS path (默认 ${path}): " custom_path
    path=${custom_path:-$path}
    # 见 _add_vless_xhttp_reality 同处说明
    _validate_json_text "$path" || { _error "path 含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="WS-CDN-${port}"
    _node_name_prompt || return 1

    local uuid; uuid=$(_gen_uuid) || return 1

    _enc_opts_prompt || return 1

    local tag="xd-ws-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-ws-cdn)") || return 1

    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local enc_param
    enc_param=$(_enc_param)
    local link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$host")&fp=chrome&type=ws&host=$(_url_encode "$host")&path=$(_url_encode "${path}?ed=2560")#$(_url_encode "$name")"
    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$preferred_addr")\", port: $preferred_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": chrome, network: ws, \"ws-opts\": {path: \"$(_yaml_dq "$path")\", headers: {Host: \"$(_yaml_dq "$host")\"}}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-ws-cdn" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg host "$host" --arg path "$path" \
        --arg preferred_addr "$preferred_addr" --argjson preferred_port "$preferred_port" \
        --arg sni "$host" --arg fp "chrome" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$preferred_addr,uuid:$uuid,host:$host,path:$path,preferred_addr:$preferred_addr,preferred_port:$preferred_port,sni:$sni,fp:$fp,share_link:$link}')
    meta_json=$(_enc_meta_json "$meta_json")
    _commit_node_txn "$tag" "$inbound" "$meta_json" "$clash" "$name" || return 1

    _success "节点 [${name}] 创建成功"
    _warn "请确保: CF 已将该域名指向本机并开启小黄云(代理), SSL 模式 Flexible"
    echo -e "  ${CYAN}分享链接(经CDN):${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议6: Shadowsocks(3 种加密: aes-256-gcm / 2022-blake3-aes-256-gcm / 2022-blake3-chacha20-poly1305)
# ---------------------------------------------------------------------------
_add_shadowsocks() {
    echo -e "\n  ${CYAN}=== Shadowsocks (可直连) ===${NC}"
    # TCP/UDP 协议选择
    echo -e "  监听协议:"
    echo -e "  ${GREEN}[1]${NC} TCP+UDP (默认)"
    echo -e "  ${GREEN}[2]${NC} 仅 TCP"
    echo -e "  ${GREEN}[3]${NC} 仅 UDP"
    read -rp "  选择 (默认 1): " net_choice
    local proto_arg network_val
    case "${net_choice:-1}" in
        1) proto_arg="";   network_val="tcp,udp" ;;
        2) proto_arg="tcp"; network_val="tcp" ;;
        3) proto_arg="udp"; network_val="udp" ;;
        *) _warn "无效,默认 TCP+UDP"; proto_arg=""; network_val="tcp,udp" ;;
    esac
    local port=$(_input_port "$proto_arg")
    echo -e "  加密方式:"
    echo -e "  ${GREEN}[1]${NC} aes-256-gcm"
    echo -e "  ${GREEN}[2]${NC} 2022-blake3-aes-256-gcm"
    echo -e "  ${GREEN}[3]${NC} 2022-blake3-chacha20-poly1305"
    read -rp "  选择 (默认 1): " mc
    local method
    case "${mc:-1}" in
        1) method="aes-256-gcm" ;;
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        *) _warn "无效,默认 aes-256-gcm"; method="aes-256-gcm" ;;
    esac
    # 2022 系列密码需标准 base64(32 字节密钥, 带 = 填充, Go base64 解码要求)
    local password
    if [[ "$method" == 2022* ]]; then
        password=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    else
        password=$(head -c 16 /dev/urandom | base64 | tr -d '\n=' | head -c 22)
    fi
    read -rp "  密码 (默认随机): " custom_pw
    password=${custom_pw:-$password}
    # 密码直拼 JSON 模板与 SS 链接, 含 " \ 换行或 {{ 会让渲染失败/值被二次替换
    _validate_json_text "$password" || { _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="SS-${method%%-*}-${port}"
    _node_name_prompt || return 1

    local tag="xd-ss-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_METHOD="$method" R_PASSWORD="$password" R_NETWORK="$network_val"
    local inbound
    inbound=$(_render_template "$(_tpl_path shadowsocks)") || return 1
    #  连接地址询问提前到提交之前; config+metadata 由事务一次性提交
    local addr
    addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址(输入已结束), 已取消(未写入 config)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    # SIP002 userinfo 用无填充base64url；客户端不能把 +/= 当URL结构。
    local userinfo="${method}:${password}"
    local b64=$(printf '%s' "$userinfo" | base64 | tr -d '\n=' | tr '+/' '-_')
    local link="ss://${b64}@${link_ip}:${port}#$(_url_encode "$name")"

    # mihomo 的 ss `udp` 默认 false(通用字段); 服务端 network 含 udp 才声明,
    # 否则声明了 UDP 也会连不上(与 _input_port 的协议选择一致)
    local clash_udp=""
    [[ "$network_val" == *"udp"* ]] && clash_udp=", udp: true"
    local clash="- {name: \"$(_yaml_dq "$name")\", type: ss, server: \"$(_yaml_dq "$addr")\", port: $port, cipher: $method, password: \"$(_yaml_dq "$password")\"${clash_udp}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "shadowsocks" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg method "$method" --arg password "$password" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,method:$method,password:$password,share_link:$link}')
    _commit_node_txn "$tag" "$inbound" "$meta_json" "$clash" "$name" || return 1

    _success "节点 [${name}] 创建成功"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# Hysteria2 QUIC必须有TLS证书；已有证书可复用，自签需事务式替换。
_hy2_cert_san_names() {
    local cert="$1" text=""
    command -v openssl >/dev/null 2>&1 || return 0
    [ -f "$cert" ] || return 0
    # 优先 -ext subjectAltName(OpenSSL 1.1.1+/LibreSSL 3.1+), 不支持时回退整份 -text
    text=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)
    [ -n "$text" ] || text=$(openssl x509 -in "$cert" -noout -text 2>/dev/null)
    printf '%s\n' "$text" | grep -oE 'DNS:[^,[:space:]]+' | sed 's/^DNS://' | sort -u
}

# 证书 SAN 是否精确覆盖给定域名(含则返回 0)
_hy2_cert_san_has() {
    local cert="$1" domain="$2"
    [ -n "$domain" ] || return 1
    _hy2_cert_san_names "$cert" | grep -qxF "$domain"
}

# cert/key 公钥一致才可复用；文件存在不表示属于同一对。
_hy2_cert_key_match() {
    local cert="$1" key="$2" cpub kpub
    command -v openssl >/dev/null 2>&1 || return 0
    [ -f "$cert" ] && [ -f "$key" ] || return 1
    cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) || return 1
    kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
    [ -n "$cpub" ] && [ "$cpub" = "$kpub" ]
}

# 删除证书备份文件。删不掉不算事务失败(残留 .bak 不影响运行态), 但必须如实报告 ——
# 项目原则: 文件操作失败不得静默吞掉(logrotate 的 `|| true` 洗返回码就是 P1 教训)。
_hy2_cert_bak_rm() {
    local f
    for f in "$@"; do
        [ -n "$f" ] || continue
        rm -f "$f" 2>/dev/null
        [ -e "$f" ] && _warn "证书备份删除失败, 已残留(不影响运行): $f"
    done
    return 0
}

# 校验临时cert/key后替换正式路径；失败恢复旧内容或旧不存在状态。
# 返回0表示提交；返回1表示失败（未改正式文件或已复核回滚）；返回2表示回滚未完成并保留备份。
_hy2_cert_commit() {
    local tmp_cert="$1" tmp_key="$2" cert="$3" key="$4"
    local bak_cert="" bak_key="" rc=1 post_ok=1
    # 备份既有文件(可能不存在 —— 首次生成时), 备份名以 XXXXXX 结尾满足 Alpine musl mktemp
    if [ -f "$cert" ]; then
        bak_cert=$(mktemp "${cert}.bak.XXXXXX") || return 1
        cp -p "$cert" "$bak_cert" 2>/dev/null || { _hy2_cert_bak_rm "$bak_cert"; return 1; }
    fi
    if [ -f "$key" ]; then
        bak_key=$(mktemp "${key}.bak.XXXXXX") || { _hy2_cert_bak_rm "$bak_cert"; return 1; }
        cp -p "$key" "$bak_key" 2>/dev/null || { _hy2_cert_bak_rm "$bak_key" "$bak_cert"; return 1; }
    fi
    # 提交(两步)+ 提交后校验正式路径确为一对匹配的 cert/key(兜底 rename 语义异常/外部干扰)
    if mv -f "$tmp_cert" "$cert" 2>/dev/null && mv -f "$tmp_key" "$key" 2>/dev/null \
       && _hy2_cert_key_match "$cert" "$key"; then
        rc=0
    fi
    if [ "$rc" != 0 ]; then
        # 原本不存在则删除，原本存在则还原备份；复原目标是提交前状态。
        if [ -n "$bak_cert" ]; then cp -p "$bak_cert" "$cert" 2>/dev/null; else rm -f "$cert" 2>/dev/null; fi
        if [ -n "$bak_key" ]; then cp -p "$bak_key" "$key" 2>/dev/null; else rm -f "$key" 2>/dev/null; fi
        # 回滚后逐个对比备份/不存在状态；验证失败保留备份返回2。
        if [ -n "$bak_cert" ]; then
            if [ -f "$cert" ]; then cmp -s "$bak_cert" "$cert" || post_ok=0; else post_ok=0; fi
        else
            [ ! -e "$cert" ] || post_ok=0
        fi
        if [ -n "$bak_key" ]; then
            if [ -f "$key" ]; then cmp -s "$bak_key" "$key" || post_ok=0; else post_ok=0; fi
        else
            [ ! -e "$key" ] || post_ok=0
        fi
        if [ "$post_ok" = 0 ]; then
            # 回滚不完整: 保留未被消费的备份(它们可能是旧文件的唯一副本), 报告路径供人工恢复
            _error "证书提交失败, 且回滚未完成; cert/key 可能处于不一致状态, 请人工检查"
            [ -n "$bak_cert" ] && [ -f "$bak_cert" ] && _warn "旧 cert 备份保留在: $bak_cert"
            [ -n "$bak_key" ] && [ -f "$bak_key" ] && _warn "旧 key 备份保留在: $bak_key"
            return 2
        fi
        # 状态已确认回到提交前: 删掉备份(删不掉只告警, 不改返回码)
        _hy2_cert_bak_rm "$bak_cert" "$bak_key"
        return 1
    fi
    _hy2_cert_bak_rm "$bak_cert" "$bak_key"
    return 0
}

# 证书SNI取具体DNS SAN；通配符不能作为客户端具体serverName(tls.md)。
_hy2_cert_domain() {
    local cert="$1" preferred="${2:-}" d=""
    if [ -n "$preferred" ] && _hy2_cert_san_has "$cert" "$preferred"; then
        printf '%s' "$preferred"; return 0
    fi
    d=$(_hy2_cert_san_names "$cert" | head -1)
    if [ -z "$d" ] && command -v openssl >/dev/null 2>&1; then
        d=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's|/.*||')
    fi
    printf '%s' "$d"
}

# 自签EC-256/10年优先openssl，缺失时 xray tls cert；全程校验后再提交。
# --file 是前缀，输出 .crt/.key；不安装新工具，不依赖外部证书服务。
_hy2_cert_reusable() {
    local cert="$1" key="$2" domain="$3"
    [ -f "$cert" ] && [ -f "$key" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 0   # 读不到 SAN/无法校验, 只能信任既有证书
    # SAN 必须覆盖本次域名, 且 cert/key 必须同属一个密钥对 —— 后者让历史遗留的错配对
    # (旧版本失败路径可能留下)在下一次调用时被判为不可复用, 从而被重新生成(自愈)。
    _hy2_cert_san_has "$cert" "$domain" || return 1
    _hy2_cert_key_match "$cert" "$key" || return 1
    return 0
}

# 用法:_gen_hy2_cert <tag> [domain]  输出: CERT_FILE_PATH / KEY_FILE_PATH 全局变量
_gen_hy2_cert() {
    local tag="$1" domain="${2:-build.nvidia.com}"
    # 证书域名会写进 X.509 CN/SAN, 从输入侧拒绝非法值(仅 LDH 域名, 与 _validate_domain 同口径)
    _validate_domain "$domain" || { _error "证书域名格式非法(仅字母/数字/连字符, 点分段): $domain"; return 1; }
    local cert_dir="$CERT_DIR/$tag"
    mkdir -p "$cert_dir"
    CERT_FILE_PATH="${cert_dir}/cert.pem"
    KEY_FILE_PATH="${cert_dir}/key.pem"
    # 是否复用由 _hy2_cert_reusable 决定；本函数只生成，不擅自覆盖调用方的复用决策。
    _info "生成 TLS 自签证书 (CN=${domain}, SAN=DNS:${domain})..."
    # 先生成临时文件，校验cert/key与SAN，再成对提交；失败删除临时文件不动旧材料。
    local tmp_cert tmp_key rc=1
    tmp_cert=$(mktemp "${cert_dir}/.cert.tmp.XXXXXX") || return 1
    tmp_key=$(mktemp "${cert_dir}/.key.tmp.XXXXXX") || { rm -f "$tmp_cert"; return 1; }
    if command -v openssl >/dev/null 2>&1; then
        # SAN 走 openssl.cnf(不用 OpenSSL 专有的命令行扩展参数): Alpine 的 LibreSSL 不认
        # 后者, cnf 方式在 OpenSSL/LibreSSL 两边都可用。
        local cnf
        cnf=$(mktemp "${cert_dir}/openssl.XXXXXX")
        if [ -n "$cnf" ]; then
            cat > "$cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${domain}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${domain}
EOF
            openssl ecparam -genkey -name prime256v1 -out "$tmp_key" 2>/dev/null \
                && openssl req -new -x509 -days 3650 -key "$tmp_key" \
                    -out "$tmp_cert" -config "$cnf" 2>/dev/null
            rm -f "$cnf"
        fi
    fi
    #  openssl 缺失或执行失败(旧版/被裁剪)时回退 xray tls cert,
    # 而不是"openssl 存在但失败就直接报错"—— 报错文案明明写着"需安装 openssl 或使用 xray tls cert"。
    if { [ ! -s "$tmp_cert" ] || [ ! -s "$tmp_key" ]; } && [ -x "$XRAY_BIN" ]; then
        # xray tls cert --file 为路径前缀；按 .crt/.key 读取并转换到正式路径。
        local xpre="${cert_dir}/.xcert.$$"
        XRAY_LOCATION_ASSET= "$XRAY_BIN" tls cert --domain "$domain" --file "$xpre" 2>/dev/null
        [ -s "${xpre}.crt" ] && mv -f "${xpre}.crt" "$tmp_cert"
        [ -s "${xpre}.key" ] && mv -f "${xpre}.key" "$tmp_key"
        rm -f "${xpre}.crt" "${xpre}.key" 2>/dev/null
        # 清理历史错误写法可能残留在父目录的 <tag>.crt/.key
        rm -f "${CERT_DIR}/${tag}.crt" "${CERT_DIR}/${tag}.key" 2>/dev/null
    fi
    if [ -s "$tmp_cert" ] && [ -s "$tmp_key" ]; then
        # openssl可用时校验SAN确含本次域名；CN-only不能冒充新生成的可用证书。
        if { ! command -v openssl >/dev/null 2>&1 || _hy2_cert_san_has "$tmp_cert" "$domain"; } \
           && _hy2_cert_key_match "$tmp_cert" "$tmp_key"; then
            _hy2_cert_commit "$tmp_cert" "$tmp_key" "$CERT_FILE_PATH" "$KEY_FILE_PATH"
            rc=$?
        fi
    fi
    rm -f "$tmp_cert" "$tmp_key"
    if [ "$rc" = 2 ]; then
        # 提交失败且回滚未完成 —— 具体原因/备份路径已由 _hy2_cert_commit 打印, 此处不重复。
        # 返回 2 而非 1: 让"回滚失败"这一状态在整条调用链上可区分(调用方只判非零, 行为不变)。
        _error "证书提交失败且回滚未完成, 已中止(未继续创建节点)"
        return 2
    fi
    if [ "$rc" != 0 ]; then
        _error "证书生成失败(cert/key 不完整、SAN 不含 ${domain} 或二者不匹配); 既有证书保持原样, 需安装 openssl 或使用 xray tls cert"
        return 1
    fi
    _success "TLS 证书已生成: $cert_dir"
}

# env值通过全局 _HY2_ENV_VAL/_HY2_CERT_ROOT 传递；命令替换会剥尾随换行。
# 读取当前环境依次 printenv/env -0/busybox printenv，NUL终止保全字节；0存在、1缺失、2未知。
_HY2_ENV_VAL=""
# 环境读取不使用 /proc/self/environ 或逐行awk；前者是初始环境，后者丢失换行值。
_hy2_env_from_tool() {
    local name="$1"; shift
    local kv="" rcstr=""
    {
        IFS= read -r -d '' kv <&3 || return 2    # 通道里没有分隔符 ⇒ 通道异常, 不猜
        IFS= read -r rcstr <&3     || return 2
    } 3< <( { "$@" "$name" 2>/dev/null; trc=$?; printf '\0'; printf '%s\n' "$trc"; } )
    case "$rcstr" in
        0) _HY2_ENV_VAL=${kv%$'\n'}; return 0 ;;   # 值 = 输出减去工具补的那**一个**换行
        1) return 1 ;;                             # 变量确实不存在
        *) return 2 ;;                             # 工具自身故障 ⇒ 无法判定
    esac
}

_hy2_env_get() {
    local name="$1" kv="" rc=0
    _HY2_ENV_VAL=""
    [ -n "$name" ] || return 1
    # ① printenv(首选: 读当前环境 —— 脚本自身 export 的变量同样可见)
    #    rc=2 ⇒ 该读取器自身故障(不是"不存在"), 换下一个读取器继续; 0/1 才是确定结论。
    if command -v printenv >/dev/null 2>&1; then
        _hy2_env_from_tool "$name" printenv; rc=$?
        [ "$rc" -ne 2 ] && return "$rc"
    fi
    # env -0 用临时普通文件保留NUL边界；解析失败或无法观察返回UNKNOWN，不猜测为空。
    if command -v env >/dev/null 2>&1; then
        local ef="" erc=125 erd=1 efd="" hit="" found=0
        ef=$(mktemp 2>/dev/null) || ef=""
        [ -n "$ef" ] && { env -0 > "$ef" 2>/dev/null; erc=$?; }
        if [ "$erc" -eq 0 ]; then
            erd=0
            # 用 {var}< 取一个高位空闲 fd, 不动调用方可能正在用的 3/4
            if exec {efd}< "$ef" 2>/dev/null; then
                # exec成功后仍确认普通文件再read；目录read可失败且无法证明环境值。
                if [ -d /proc/self/fd ]; then
                    [ -f "/proc/self/fd/$efd" ] || erd=2       # 机制可用 ⇒ 只信 fd
                else
                    [ -f "$ef" ] || erd=2                      # 无 /proc ⇒ 退回路径检查
                fi
                if [ "$erd" -eq 0 ]; then
                    while :; do
                        kv=""                              # 先清空: 使"EOF 后仍有残留"可判定
                        IFS= read -r -d '' kv <&"$efd"; erd=$?
                        [ "$erd" -ne 0 ] && break
                        case "$kv" in
                            "$name="*) hit="${kv#"$name="}"; found=1; break ;;
                        esac
                    done
                fi
                exec {efd}<&-
            else
                erd=2                                       # 打不开 ⇒ 无法确认完整性
            fi
            rm -f "$ef"
            [ "$erd" -gt 1 ] && return 2                    # 读错误 ⇒ UNKNOWN
            [ "$erd" -eq 1 ] && [ -n "$kv" ] && return 2    # 末条缺 NUL(截断) ⇒ UNKNOWN
            if [ "$found" -eq 1 ]; then _HY2_ENV_VAL="$hit"; return 0; fi
            return 1                                        # 读取正常结束且未命中 ⇒ 确实不存在
        fi
        [ -n "$ef" ] && rm -f "$ef"
        # 该读取器不可用 ⇒ 落到 ③(busybox printenv); 全不可用才 UNKNOWN
    fi
    # ③ busybox printenv: `command -v printenv` 失败不等于 busybox 没有该 applet ——
    #    可能只是 applet 没建 symlink, 故显式走 `busybox printenv`(仍是当前环境)。
    if command -v busybox >/dev/null 2>&1 && busybox printenv >/dev/null 2>&1; then
        _hy2_env_from_tool "$name" busybox printenv; rc=$?
        [ "$rc" -ne 2 ] && return "$rc"
    fi
    # 无当前环境读取器返回2；不回退初始环境或逐行解析。
    return 2
}

# config.env 同名键覆盖进程环境；值保持字节完整，畸形env返回UNKNOWN。
_hy2_cert_env_ok() {
    _config_present || return 0
    local t
    # env要求对象、字符串值、键非空且无等号/NUL、值无NUL；对应Go解析及os.Setenv约束。
    t=$(_config_jq -r 'if has("env") then
            if .env == null then "null"
            elif (.env | type) != "object" then "invalid"
            elif (.env | all(to_entries[];
                    (.key | (length > 0)
                           and ((contains("\u0000")) | not)
                           and ((contains("=")) | not))
                    and (.value | if . == null then true
                                   elif type == "string" then ((contains("\u0000")) | not)
                                   else false end)
                 )) then "object"
            else "invalid" end
        else "null" end' 2>/dev/null) || return 2
    case "$t" in
        null|object) return 0 ;;
        *) return 2 ;;
    esac
}

_hy2_env_final() {
    local name="$1" kv=""
    _HY2_ENV_VAL=""
    # 配置损坏(.env 类型非法 / config 无法解析)⇒ 未知, 不回落进程环境(返回 2)
    _hy2_cert_env_ok || return 2
    [ -n "$name" ] || return 1
    if _config_present \
       && _config_jq -e --arg k "$name" '(.env // {}) | has($k)' >/dev/null 2>&1; then
        # jq -j+NUL读取保全尾随换行；不能改成 jq -r/命令替换。
        IFS= read -r -d '' kv < <( { _config_jq -j --arg k "$name" '(.env // {}) | (.[$k] // "")' 2>/dev/null; printf '\0'; } ) || return 2
        _HY2_ENV_VAL="$kv"
        return 0
    fi
    _hy2_env_get "$name"
}

# NewEnvFlag 先 exact(xray.location.cert)，缺失再大写下划线；空值也是命中。
_hy2_envflag_get() {
    local exact="$1" norm="$2" rc=0
    _hy2_env_final "$exact"; rc=$?
    [ "$rc" = 2 ] && return 2
    if [ "$rc" = 0 ]; then return 0; fi
    _hy2_env_final "$norm"; rc=$?
    [ "$rc" = 2 ] && return 2
    if [ "$rc" = 0 ]; then return 0; fi
    _HY2_ENV_VAL=""
    return 1
}

# 证书实际基准按envflag，缺失用可执行文件目录；空/相对/未知基准拒绝破坏性操作。
_hy2_xray_cert_root() {
    local xb="" rc=0
    _HY2_CERT_ROOT=""
    _hy2_envflag_get "xray.location.cert" "XRAY_LOCATION_CERT"; rc=$?
    if [ "$rc" = 0 ]; then
        case "$_HY2_ENV_VAL" in
            /*) _HY2_CERT_ROOT="$_HY2_ENV_VAL"; return 0 ;;
            *) return 1 ;;      # 空串/相对路径 ⇒ Xray 按自身 cwd 解析, 未知
        esac
    fi
    [ "$rc" = 2 ] && return 1   # 无法判定/配置损坏 ⇒ 未知(禁止据此判定删除目标)
    xb="${XRAY_BIN:-}"
    [ -n "$xb" ] || return 1
    xb=$(dirname "$xb")
    case "$xb" in
        /*) _HY2_CERT_ROOT="$xb"; return 0 ;;
        *) return 1 ;;
    esac
}

# 候选基准为实际基准+可执行目录；并集只扩大保留范围，不能改变删除目标。
_hy2_xray_cert_bases() {
    local xb="" seen=""
    _HY2_BASES=()
    if _hy2_xray_cert_root; then
        seen="$_HY2_CERT_ROOT"
        [ -n "$seen" ] && _HY2_BASES+=("$seen")
    fi
    xb="${XRAY_BIN:-}"
    if [ -n "$xb" ]; then
        xb=$(dirname "$xb")
        [ "$xb" != "$seen" ] && _HY2_BASES+=("$xb")
    fi
    return 0
}

# 相对引用按全部候选基准展开；绝对引用只用自身，输出到全局数组避免剥尾。
_hy2_cert_ref_abspaths() {
    local ref="$1" base
    _HY2_ABSPATHS=()
    [ -n "$ref" ] || return 1
    case "$ref" in
        /*) _HY2_ABSPATHS+=("$ref"); return 0 ;;
    esac
    _hy2_xray_cert_bases
    for base in "${_HY2_BASES[@]}"; do
        [ -n "$base" ] || continue
        _HY2_ABSPATHS+=("$base/$ref")
    done
    return 0
}

# canonical解析不依赖cwd，优先realpath再readlink；未知返回失败不猜路径。
_hy2_realpath() {
    local p="$1" dir base out
    [ -n "$p" ] || return 1
    dir=$(dirname "$p"); base=$(basename "$p")
    [ -e "$dir" ] || [ -L "$dir" ] || return 1
    out=$( ( cd "$dir" 2>/dev/null && readlink -f "$base" 2>/dev/null ) ) || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# 破坏性操作先核对真实身份在CERT_DIR内；符号链接越界不能删除。
_hy2_cert_path_inside() {
    local p="$1" base real comp
    case "$p" in
        "$CERT_DIR"/?*) ;;
        *) return 1 ;;
    esac
    local IFS='/'
    for comp in $p; do
        [ "$comp" = ".." ] && return 1
    done
    base=$(cd "$CERT_DIR" 2>/dev/null && pwd -P) || return 1
    # 目标不存在(且不是符号链接): 不能直接放行 —— 父目录若是指向 CERT_DIR 之外的符号链接,
    # 目标一旦被创建就落在外面(certs/linkdir -> /outside 下的 new.pem)。故此时解析父目录。
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
        local parent; parent=$(dirname "$p")
        [ -e "$parent" ] || [ -L "$parent" ] || return 0   # 父目录也不存在 ⇒ 无落点可言
        real=$(_hy2_realpath "$parent") || return 1
        # 父目录归约后等于 base ⇒ 目标是 CERT_DIR 的直接子项(其自身已在上面通过词法校验)
        case "$real" in
            "$base"|"$base"/?*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # 必须对目标自身做 canonical 解析: 只解析父目录会让"文件本身是指向 CERT_DIR 之外的
    # 符号链接"蒙混过关(certs/tag/cert.pem -> /outside/x.pem), 而后续 cp/rm 会落到目标上。
    real=$(_hy2_realpath "$p") || real=""
    if [ -z "$real" ]; then
        # 无 readlink -f(极老 busybox)或解析失败: 非符号链接才可用"父目录 + 文件名"回退;
        # 符号链接(含悬浮)无法证实落点 ⇒ fail-closed, 拒绝
        if [ ! -L "$p" ]; then
            if [ -d "$p" ]; then
                real=$(cd "$p" 2>/dev/null && pwd -P)
            else
                real=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")
            fi
        fi
        [ -n "$real" ] || return 1
    fi
    case "$real" in
        "$base"/?*) return 0 ;;
        *) return 1 ;;
    esac
}

# 证书 Subject CN(无 openssl / 读不到 ⇒ 空输出)
_hy2_cert_cn() {
    local cert="$1"
    command -v openssl >/dev/null 2>&1 || return 0
    [ -f "$cert" ] || return 0
    openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's|/.*||'
}

# 可作为客户端 SNI 默认值的具体 SAN 名(通配符 *.example.com 是匹配规则、不是合法 SNI,
# 故跳过; 证书另有具体 SAN 时仍会命中它)。无可用项返回 1。
_hy2_cert_sni_hint() {
    local cert="$1" n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in \*.*) continue ;; esac
        printf '%s' "$n"; return 0
    done <<< "$(_hy2_cert_san_names "$cert")"
    return 1
}

# 证书快照纳入节点创建事务；回滚以旧存在状态和内容为准。
_hy2_cert_snapshot() {
    local cert="$1" key="$2" dir rc=0
    dir=$(mktemp -d "$DEPLOY_DIR/hy2cert.bak.XXXXXX") || return 1
    if [ -f "$cert" ]; then cp -p "$cert" "$dir/cert.pem" 2>/dev/null || rc=1; fi
    if [ "$rc" = 0 ] && [ -f "$key" ]; then cp -p "$key" "$dir/key.pem" 2>/dev/null || rc=1; fi
    if [ "$rc" != 0 ]; then
        rm -rf "$dir" 2>/dev/null
        [ -e "$dir" ] && _warn "证书快照清理失败, 已残留: $dir"
        return 1
    fi
    printf '%s' "$dir"
}

# 丢弃证书快照(节点创建成功后调用 —— 本次改动已被节点引用, 不再需要回滚点)
# 返回: 0 = 已删除(或本就无快照); 1 = 删除失败, 快照仍在(内含旧私钥副本, 调用方须如实报告)
_hy2_cert_snapshot_drop() {
    local bak="$1"
    [ -n "$bak" ] || return 0
    rm -rf "$bak" 2>/dev/null
    if [ -e "$bak" ]; then
        _warn "证书快照清理失败, 已残留(内含旧私钥副本): $bak"
        return 1
    fi
    return 0
}

# 只在config未提交时恢复证书；完整验证后删除快照，否则保留证据返回2。
_hy2_cert_restore() {
    local bak="$1" cert="$2" key="$3" cdir="$4" ok=1
    # cert 与 key 都要过闸门: 只查 cert 时, key 若是指向目录外的符号链接, 下面的 cp
    # 会跟随它写到外部(路径闸门的契约是"两个目标都在 CERT_DIR 内")
    if ! _hy2_cert_path_inside "$cert" || ! _hy2_cert_path_inside "$key"; then
        _warn "证书回滚跳过(路径不在 ${CERT_DIR} 内或为指向外部的符号链接): $cert / $key"
        _error "证书回滚未完成: 回滚目标不安全; 快照已保留, 请人工恢复"
        [ -n "$bak" ] && _warn "旧证书快照保留在: $bak"
        return 2
    fi
    if [ -n "$bak" ] && [ -f "$bak/cert.pem" ]; then
        cp -p "$bak/cert.pem" "$cert" 2>/dev/null || ok=0
    else
        rm -f "$cert" 2>/dev/null || ok=0
    fi
    if [ -n "$bak" ] && [ -f "$bak/key.pem" ]; then
        cp -p "$bak/key.pem" "$key" 2>/dev/null || ok=0
    else
        rm -f "$key" 2>/dev/null || ok=0
    fi
    if [ "$ok" != 1 ]; then
        _error "证书回滚未完成(cert/key 可能不一致); 快照已保留, 请人工恢复"
        [ -n "$bak" ] && _warn "旧证书快照保留在: $bak"
        return 2
    fi
    # 清掉已空的目录(rmdir 仅在空目录成功 ⇒ 不会误删既有内容; 非空失败即静默保留)
    [ -d "$cdir" ] && rmdir "$cdir" 2>/dev/null
    # 证书已恢复, 但快照删不掉 ⇒ 不能报"完整恢复": 快照里是旧私钥副本, 残留需人工处理
    if ! _hy2_cert_snapshot_drop "$bak"; then
        _warn "证书已恢复, 但快照未清理干净(内含旧私钥副本), 请手工删除: ${bak:-无}"
        return 1
    fi
    return 0
}

# 创建失败统一 _hy2_cert_rollback；恢复失败返回2并保留现场，不假报无变化。
_hy2_cert_rollback() {
    local dirty="$1" bak="$2" cert="$3" key="$4" cdir="$5" rc=0
    [ "$dirty" = "true" ] || return 0
    _hy2_cert_restore "$bak" "$cert" "$key" "$cdir"; rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            # 证书已恢复, 只是快照(旧私钥副本)没删掉 —— 不能报"回滚未完成"吓用户
            _warn "证书已恢复; 快照未清理干净(内含旧私钥副本), 请手工删除: ${bak:-无}"
            return 0
            ;;
        *)
            _error "证书回滚未完成, 快照已保留待人工恢复: ${bak:-无}"
            return 2
            ;;
    esac
}
# 自签目录仅返回可证明属本节点的CERT_DIR/<tag>；外来证书/未知归属返回1且无输出。
_hy2_self_cert_dir() {
    local tag="$1" refs ref rreal cand cbase
    cand="$CERT_DIR/$tag"
    cbase=$(_hy2_realpath "$CERT_DIR") || cbase="$CERT_DIR"
    # 基准空/相对/未知时不能证明归属；保留证书不删除。
    _hy2_xray_cert_root || return 1
    [ "$(jq -r '.self_signed // false' "$NODES_DIR/${tag}.json" 2>/dev/null)" = "true" ] || return 1
    _hy2_cert_path_inside "$cand" || return 1
    # 删除候选固定CERT_DIR/<tag>，config只交叉校验；不能由引用反推其它节点目录。
    cand=$(_hy2_realpath "$cand") || cand="$CERT_DIR/$tag"
    # 该入站引用的每个 cert/key 都必须 canonicalize 到 cand 之下(多证书/共享目录/外部链接
    # 一律判为"归属不明确" ⇒ 返回 1, 不进入 purge)
    refs=$(_config_jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.tlsSettings.certificates[]? | (.certificateFile // empty), (.keyFile // empty)' 2>/dev/null) || return 1
    # 实际生效基准决定删除身份，额外候选只用于保留；归属冲突拒绝。
    local ref aref rreal lex_ours ours foreign unres
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        ours=0; foreign=0; unres=0; idx=0
        _hy2_cert_ref_abspaths "$ref"
        for aref in "${_HY2_ABSPATHS[@]}"; do
            [ -n "$aref" ] || continue
            idx=$((idx + 1))
            # 第一个候选 = 实际生效基准: 只有它能决定"材料是否在 CERT_DIR 之外"(删除目标只看它);
            # 额外候选(可执行文件目录)仅用于保留判断(命中本节点目录即可), 不作冲突来源。
            is_eff=0; [ "$idx" = 1 ] && is_eff=1
            lex_ours=0
            case "$aref" in "$cand"/?*) lex_ours=1 ;; esac
            rreal=$(_hy2_realpath "$aref") || rreal=""
            if [ -z "$rreal" ]; then
                # 无法 canonicalize(文件已删除等): 词法兜底
                if [ "$lex_ours" = 1 ]; then ours=1
                elif [ "${aref#"$CERT_DIR"/}" != "$aref" ]; then unres=1
                elif [ "$is_eff" = 1 ]; then foreign=1
                fi
                continue
            fi
            if [ "${rreal#"$cand"/}" != "$rreal" ]; then ours=1          # 落点在本节点目录
            elif [ "${rreal#"$cbase"/}" != "$rreal" ]; then
                # 目录内指向其它证书的链接只删除自身链接；非本节点词法路径的共享引用判未知。
                if [ "$lex_ours" = 1 ]; then ours=1; else unres=1; fi
            elif [ "$is_eff" = 1 ]; then foreign=1                             # 材料在 CERT_DIR 之外
            fi
        done
        # 归属成立、材料没落到 CERT_DIR 之外、且无归属不明候选 ⇒ 本节点
        [ "$ours" = 1 ] && [ "$foreign" = 0 ] && [ "$unres" = 0 ] && continue
        # 其余一律拒绝(冲突/归属不明/自定义证书), 朝保留侧失败
        return 1
    done <<< "$refs"
    printf '%s' "$cand"
}

# 证书目录是否仍被 config 里的入站引用(节点删除成功后才调用 ⇒ 命中的都是存活引用)。
# config 里被手工写成 `..` 形式的引用无法安全比较, 一律保守判定为"仍被引用"。
_hy2_cert_dir_referenced() {
    local dir="$1" refs ref
    # certificateFile/keyFile 都扫描；只扫证书会漏掉存活节点的共享私钥。
    refs=$(_config_jq -r '.inbounds[]? | .streamSettings.tlsSettings.certificates[]? | (.certificateFile // empty), (.keyFile // empty)' 2>/dev/null) || return 0
    [ -n "$refs" ] || return 1
    local dreal cbase_real
    dreal=$(_hy2_realpath "$dir") || dreal=""
    cbase_real=$(_hy2_realpath "$CERT_DIR") || cbase_real="$CERT_DIR"
    if [ -z "$dreal" ]; then
        # 无法 canonicalize 待删目录 ⇒ fail-closed(与 jq 失败同口径): 目录存在就保守保留,
        # 免得"解析失败 ⇒ 退回词法比较 ⇒ 误判无引用 ⇒ 删掉仍在用的证书"
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            _warn "无法解析证书目录真实路径, 保守保留: $dir"
            return 0
        fi
        dreal="$dir"
    fi
    local ref aref rreal in_scope elsewhere
    # 生效基准未知(envflag 为空串/相对路径 ⇒ 落点取决于 Xray 自身 cwd)时, 相对引用的真实
    # 位置无从判定 ⇒ 只要存在相对引用就保守视为"可能指向本目录"(朝保留侧失败)
    local root_known=0
    _hy2_xray_cert_root && root_known=1
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        case "$ref" in
            /*) ;;
            *) [ "$root_known" = 0 ] && return 0 ;;
        esac
        # 一条引用可能对应多个绝对路径(生效基准 + 可执行文件目录两个候选), 逐个解析;
        # 任一命中即视为仍被引用(朝保留侧失败)。
        in_scope=0; elsewhere=0
        _hy2_cert_ref_abspaths "$ref"
        for aref in "${_HY2_ABSPATHS[@]}"; do
            [ -n "$aref" ] || continue
            # 引用先canonical，再词法兜底；外部词法路径也可能链接到待删目录。
            rreal=$(_hy2_realpath "$aref") || rreal=""
            if [ -n "$rreal" ]; then
                case "$rreal" in "$dreal"/?*) return 0 ;; esac     # 归约后位于待删目录之下
                # 归约成功即确定落点: 不在待删目录之下 ⇒ 该候选与本目录无关(即便它落在
                # CERT_DIR 内的别处, 也只是"指向别处的文件", 与本目录无关)
                elsewhere=1
                continue
            fi
            # ② 无法 canonicalize: 词法兜底 —— 词法就在待删目录下 ⇒ 直接算被引用;
            #    词法在 CERT_DIR 内 ⇒ 记入 in_scope(交由 ③ 保守处理)
            case "$aref" in "$dir"/?*) return 0 ;; esac
            case "$aref" in "$CERT_DIR"/?*) in_scope=1 ;; esac
        done
        # ③ 与本目录无关(不在 CERT_DIR 内, 或已归约到别处)⇒ 下一条
        [ "$in_scope" = 1 ] || continue
        [ "$elsewhere" = 1 ] && continue
        # CERT_DIR内含 .. 或符号链接但解析失败时保留；不能证明无引用。
        case "$ref" in *".."*) return 0 ;; esac
        [ -L "$ref" ] && return 0
        continue
    done <<< "$refs"
    return 1
}

# 删除节点时询问是否一并删除自签证书(自定义证书不提示、不删除)。结果放入 _HY2_CERT_PURGE,
# 由 _hy2_purge_self_certs 在节点删除成功后落地 —— 删除失败(已回滚)时不能动证书。
_HY2_CERT_PURGE=()
_hy2_ask_purge_self_certs() {
    _HY2_CERT_PURGE=()
    local dirs=() t d i dup ans
    for t in "$@"; do
        d=$(_hy2_self_cert_dir "$t") || continue
        dup=0
        i=0
        while [ "$i" -lt "${#dirs[@]}" ]; do
            [ "${dirs[$i]}" = "$d" ] && { dup=1; break; }
            i=$((i+1))
        done
        [ "$dup" = 1 ] && continue
        dirs+=("$d")
    done
    [ "${#dirs[@]}" -gt 0 ] || return 0
    echo -e "  ${CYAN}检测到 ${#dirs[@]} 个节点使用自签证书:${NC}"
    for d in "${dirs[@]}"; do echo "    - $d"; done
    read -rp "  一并删除这些自签证书? [y/N]: " ans
    case "$ans" in
        y|Y) _HY2_CERT_PURGE=("${dirs[@]}") ;;
        *) _info "保留自签证书(仅删除节点)" ;;
    esac
    return 0
}

# 仅节点删除提交后purge已收集目录；未知存活引用保留，不影响配置提交。
_hy2_purge_self_certs() {
    [ "${#_HY2_CERT_PURGE[@]}" -gt 0 ] || return 0
    local d n=0
    for d in "${_HY2_CERT_PURGE[@]}"; do
        _hy2_cert_path_inside "$d" || { _warn "跳过 ${CERT_DIR} 之外的证书路径: $d"; continue; }
        if _hy2_cert_dir_referenced "$d"; then
            _warn "证书目录仍被其它入站引用, 已保留: $d"
            continue
        fi
        rm -rf "$d" 2>/dev/null
        if [ -e "$d" ]; then _warn "自签证书删除失败, 已残留: $d"; else n=$((n+1)); fi
    done
    [ "$n" -gt 0 ] && _info "已删除 ${n} 个自签证书目录"
    _HY2_CERT_PURGE=()
    return 0
}

_add_hysteria2() {
    echo -e "\n  ${CYAN}=== Hysteria2 (QUIC · 可直连 · 需 TLS 证书) ===${NC}"
    local port=$(_input_port udp)

    # TLS 证书: 回车自签, 或输入证书路径
    local tag="xd-hy2-${port}"
    local cert_file="" key_file="" self_signed="false" sni="" self_domain="" tls_mode=""
    echo -e "  TLS 证书 回车使用自签证书, 或输入证书文件路径"
    read -rp "  cert 路径 (回车自签): " custom_cert
    if [ -n "$custom_cert" ]; then
        read -rp "  key 路径: " custom_key
        # 证书路径直拼 JSON 模板, 先做字符校验再判存在性(报错可理解)
        _validate_json_text "$custom_cert" || { _error "cert 路径含非法字符(双引号/反斜杠/换行/制表符或 {{)"; return 1; }
        _validate_json_text "$custom_key" || { _error "key 路径含非法字符(双引号/反斜杠/换行/制表符或 {{)"; return 1; }
        if [ ! -f "$custom_cert" ] || [ ! -f "$custom_key" ]; then
            _error "证书文件不存在"; return 1
        fi
        cert_file="$custom_cert"; key_file="$custom_key"
        tls_mode="custom"
        _info "使用自定义证书: $cert_file"
        # SNI 默认只取可用具体DNS SAN；无具体SAN必须询问，不能默默套默认。
        local cert_hint="" cert_cn="" sni_in=""
        cert_hint=$(_hy2_cert_sni_hint "$cert_file") || cert_hint=""
        if [ -z "$cert_hint" ]; then
            if [ -n "$(_hy2_cert_san_names "$cert_file")" ]; then
                _warn "证书 SAN 只有通配符; 通配符不能作为客户端 SNI, 请填写一个具体主机名"
            else
                cert_cn=$(_hy2_cert_cn "$cert_file")
                [ -n "$cert_cn" ] && _warn "证书只有 CN(${cert_cn}) 且无 SAN; 现代 TLS 主机名校验忽略 CN, 该证书可能无法通过客户端校验"
            fi
        fi
        # 输入EOF直接取消；不能把read失败当空值重试导致无限循环。
        while :; do
            if [ -n "$cert_hint" ]; then
                read -rp "  SNI (默认 ${cert_hint}): " sni_in || return 1
                sni_in=${sni_in:-$cert_hint}
            else
                read -rp "  SNI (证书无可用 SAN, 请手动输入具体主机名): " sni_in || return 1
            fi
            [ "$sni_in" = "0" ] && { _info "已取消"; return 1; }
            if [ -z "$sni_in" ]; then
                _error "无法从证书读取可用 SAN, SNI 不能为空"
                continue
            fi
            if _validate_domain "$sni_in"; then sni="$sni_in"; break; fi
            _error "SNI 格式非法(仅字母/数字/连字符, 点分段): ${sni_in}"
        done
    else
        # 自签域名同时写CN/SAN并用于SNI；必须允许用户选择而非硬编码。
        while :; do
            # 域名输入EOF取消；不能把失败套成默认域名。
            read -rp "  自签证书域名/SAN (回车默认 build.nvidia.com): " self_domain || return 1
            [ "$self_domain" = "0" ] && { _info "已取消"; return 1; }
            self_domain=${self_domain:-build.nvidia.com}
            _validate_domain "$self_domain" && break
            _error "域名格式非法(仅字母/数字/连字符, 点分段): ${self_domain}"
        done
        tls_mode="selfsigned"; self_signed="true"
    fi

    # 认证密码
    local auth
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  认证密码 (回车随机): " custom_auth
    auth=${custom_auth:-$auth}
    # 认证串直拼 JSON 模板与 hy2 链接, 校验同 _add_shadowsocks
    _validate_json_text "$auth" || { _error "认证密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    # 拥塞控制
    echo -e "  拥塞控制:"
    echo -e "  ${GREEN}[1]${NC} bbr"
    echo -e "  ${GREEN}[2]${NC} brutal"
    echo -e "  ${GREEN}[3]${NC} force-brutal"
    local cc_choice
    read -rp "  选择 (默认 1): " cc_choice
    local congestion="bbr"
    local brutal_up="" brutal_down=""
    case "${cc_choice:-1}" in
        2|3)
            [ "${cc_choice}" = "3" ] && congestion="force-brutal" || congestion="brutal"
            echo -e "  ${YELLOW}${congestion} 带宽格式: 100 mbps / 10m / 1g; 非零上下行至少 512 kbps (0.5 mbps), force-brutal 上传必须非零${NC}"
            while :; do
                read -rp "  上传带宽 (服务器→客户端, brutal 回车不限): " brutal_up || return 1
                brutal_up=$(_normalize_bandwidth "$brutal_up")
                if _hy2_brutal_rate_valid "$brutal_up" &&
                   { [ "$congestion" != "force-brutal" ] || _hy2_force_brutal_up_valid "$brutal_up"; }; then
                    break
                fi
                _error "上传须为有效速率: 非零至少 512 kbps (0.5 mbps), force-brutal 不允许空/零"
            done
            while :; do
                read -rp "  下载带宽 (客户端→服务器, 0/回车不限): " brutal_down || return 1
                brutal_down=$(_normalize_bandwidth "$brutal_down")
                _hy2_brutal_rate_valid "$brutal_down" && break
                _error "下载须为有效速率: 0/回车不限, 非零至少 512 kbps (0.5 mbps)"
            done
            ;;
    esac

    local default_name="HY2-${port}"
    _node_name_prompt || return 1

    local listen="::"

    # 混淆仅写finalmask.udp，默认关闭；客户端类型与Xray类型分别处理(finalmask.md)。
    local obfs_type="" obfs_pw="" obfs_size="" obfs_mask="" obfs_pw_in="" obfs_choice
    echo -e "  混淆 (FinalMask.udp, 默认关闭):"
    echo -e "  ${GREEN}[1]${NC} 不启用  ${GREEN}[2]${NC} salamander  ${GREEN}[3]${NC} gecko"
    read -rp "  选择 (默认 1): " obfs_choice
    case "${obfs_choice:-1}" in
        2|3)
            obfs_type="salamander"
            obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " obfs_pw_in
            obfs_pw=${obfs_pw_in:-$obfs_pw}
            _validate_json_text "$obfs_pw" || { _error "混淆密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }
            if [ "$obfs_choice" = "3" ]; then
                # gecko先版本门控；旧核心静默忽略packetSize会造成客户端不兼容。
                if ! _hy2_gecko_supported; then
                    _error "当前核心不支持 gecko 分片(packetSize 需核心 >= ${_HY2_GECKO_MIN_VER}); 已取消, 未修改任何配置"
                    _tip "请先升级/切换 Xray 核心(核心版本门控见项目文档), 或改选 [2] 普通 salamander"
                    return 1
                fi
                # gecko必须非空合法packetSize，默认512-1200；同时保存客户端类型与服务端范围。
                read -rp "  packetSize (Int32Range, 如 512-1200; 回车用 Hysteria 官方 gecko 默认 512-1200): " obfs_size
                obfs_size="${obfs_size:-512-1200}"
                local size_why; size_why=$(_hy2_obfs_size_invalid "$obfs_size")
                [ -n "$size_why" ] && { _error "packetSize 非法: ${size_why}"; return 1; }
                # 规范化(排序 + 去前导零)后回写, 使元数据/clash 与 Xray 看到同一区间
                obfs_size=$(_hy2_obfs_size_canon "$obfs_size") || { _error "packetSize 规范化失败"; return 1; }
            fi
            # obfs_mask / brutal_block 由提交事务内部构造( 证书与提交同锁)
            ;;
    esac

    # 自签snapshot、生成、config/metadata同锁；失败返回1已恢复、2保留未恢复现场。
    local addr
    addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址(输入已结束), 已取消(未生成证书/未写入 config)"; return 1; }

    local rc=0
    _commit_hy2_node_txn "$tag" "$name" "$addr" "$port" "$listen" "$auth" "$sni" "$self_signed" "$self_domain" \
        "$congestion" "$brutal_up" "$brutal_down" "$obfs_type" "$obfs_pw" "$obfs_size" "$cert_file" "$key_file" || rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi

    local meta="$NODES_DIR/${tag}.json"
    # 派生状态(链接 + clash)走唯一入口(clash 步骤是 upsert, 新建节点会追加条目);
    # 失败只告警, 不回滚已提交的 config/metadata。
    _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    local link=""
    link=$(jq -r '.share_link // ""' "$meta" 2>/dev/null)
    # 自签证书的 SNI 在锁内由证书 SAN 决定(子 shell 不传值), 显示时从 metadata 回读
    sni=$(jq -r '.sni // empty' "$meta" 2>/dev/null)

    _success "节点 [${name}] 创建成功"
    if [ "$self_signed" = "true" ]; then
        _tip "自签证书, 客户端须手动信任证书 (insecure=1)"
    else
        _tip "使用自定义证书, SNI: ${sni}"
    fi
    echo -e "  ${CYAN}拥塞控制:${NC} ${congestion}"
    if [ -n "$obfs_type" ]; then
        if [ -n "$obfs_size" ]; then
            echo -e "  ${CYAN}混淆:${NC} gecko (FinalMask.udp) · packetSize=${obfs_size}"
        else
            echo -e "  ${CYAN}混淆:${NC} salamander (FinalMask.udp)"
        fi
    fi
    if [ -n "$link" ]; then
        echo -e "  ${CYAN}分享链接:${NC} ${link}"
    else
        echo -e "  ${YELLOW}分享链接: 无(见上方说明; 客户端配置见 Clash 条目)${NC}"
    fi
}

# ---------------------------------------------------------------------------
# 分享链接重建(HY2 / Reality 域名切换后更新链接用)
# ---------------------------------------------------------------------------

# Hy2分享链接从metadata重建；自定义gecko尺寸不可表达时返回失败不编造URI。
_rebuild_hy2_link() {
    local meta="$1"
    local auth host port sni congestion brutal_up brutal_down name self_signed
    auth=$(jq -r '.auth // empty' "$meta")
    host=$(jq -r '.link_addr // empty' "$meta")
    port=$(jq -r '.port // empty' "$meta")
    sni=$(jq -r '.sni // "build.nvidia.com"' "$meta")
    congestion=$(jq -r '.congestion // empty' "$meta")
    brutal_up=$(jq -r '.brutal_up // empty' "$meta")
    brutal_down=$(jq -r '.brutal_down // empty' "$meta")
    self_signed=$(jq -r '.self_signed // "false"' "$meta")
    name=$(jq -r '.name // empty' "$meta")
    if [ -z "$auth" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$congestion" ] || [ -z "$name" ]; then
        _error "节点元数据缺少必要字段(auth/link_addr/port/congestion/name), 无法重建分享链接: $meta"
        return 1
    fi
    # URI类型按Hysteria URI-Scheme；Xray salamander+packetSize 在客户端是gecko。
    local obfs_kind obfs_pw obfs_size
    # 未知 obfs_type = 损坏 metadata ⇒ 拒绝生成(不产出半成品链接)
    obfs_kind=$(_hy2_obfs_kind "$meta") || return 1
    obfs_pw=$(jq -r '.obfs_password // empty' "$meta")
    obfs_size=$(_hy2_obfs_size_get "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link="hy2://$(_url_encode "$auth")@${link_ip}:${port}/?sni=$(_url_encode "$sni")"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1&allowInsecure=1"
    link="${link}&congestion=${congestion}"
    # 服务端上行 = 客户端下行；metadata 保留服务端方向(finalmask.md: QuicParamsObject)。
    [ -n "$brutal_down" ] && link="${link}&up=$(_url_encode "$brutal_down")"
    [ -n "$brutal_up" ] && link="${link}&down=$(_url_encode "$brutal_up")"
    if [ "$obfs_kind" != "none" ]; then
        # 自定义尺寸无法用 URI 表达 ⇒ 拒绝(默认 512-1200 可表达, 见 _hy2_link_unexpressible)
        [ "$obfs_kind" = "gecko" ] && ! _hy2_obfs_size_is_default "$meta" && return 1
        link="${link}&obfs=${obfs_kind}&obfs-password=$(_url_encode "$obfs_pw")"
    fi
    # 端口跳跃端口(如果已配置, 统一通过 _read_hop_ranges_display 读取, )
    local hop_ports
    hop_ports=$(_read_hop_ranges_display "$meta" 2>/dev/null)
    [ -n "$hop_ports" ] && link="${link}&mport=$(_url_encode "$hop_ports")"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# _hy2_clash_line 为唯一Hy2 Clash入口；带宽服务端→客户端交换，metadata方向不变。
# mihomo up/down触发brutal，ports须引号；gecko用 obfs-min/max-packet-size。
_hy2_clash_line() {
    local meta="$1"
    local name addr port auth sni congestion brutal_up brutal_down self_signed
    name=$(jq -r '.name // empty' "$meta")
    addr=$(jq -r '.link_addr // empty' "$meta")
    port=$(jq -r '.port // empty' "$meta")
    auth=$(jq -r '.auth // empty' "$meta")
    sni=$(jq -r '.sni // "build.nvidia.com"' "$meta")
    congestion=$(jq -r '.congestion // empty' "$meta")
    brutal_up=$(jq -r '.brutal_up // empty' "$meta")
    brutal_down=$(jq -r '.brutal_down // empty' "$meta")
    self_signed=$(jq -r '.self_signed // "false"' "$meta")
    # gecko尺寸只在obfs=gecko被mihomo读取；客户端类型不能沿用服务端salamander名称。
    local obfs_kind obfs_pw obfs_size obfs_min="" obfs_max=""
    # 未知 obfs_type = 损坏 metadata ⇒ 拒绝产出条目(不写"写着 salamander、服务端在分片"的行)
    obfs_kind=$(_hy2_obfs_kind "$meta") || return 1
    obfs_pw=$(jq -r '.obfs_password // empty' "$meta")
    obfs_size=$(_hy2_obfs_size_get "$meta")
    if [ "$obfs_kind" = "gecko" ]; then
        # min/max 必须来自同一规范化结果, 与 Xray 侧的 packetSize 同区间: 直接按 "-"
        # 切分会把 1500-800 原样导出成 min=1500/max=800, 而 mihomo 要求 max>=min。
        local obfs_canon
        obfs_canon=$(_hy2_obfs_size_canon "$obfs_size") || obfs_canon=""
        obfs_min="${obfs_canon%%-*}"
        obfs_max="${obfs_canon##*-}"
        # 有尺寸却解析不出两端 = 畸形元数据; 宁可拒绝也不产出"写着 salamander、服务端在分片"的条目
        [ -n "$obfs_min" ] && [ -n "$obfs_max" ] || return 1
    fi
    if [ -z "$name" ] || [ -z "$addr" ] || [ -z "$port" ] || [ -z "$auth" ]; then
        _error "节点元数据缺少必要字段(name/link_addr/port/auth), 无法生成 clash 条目: $meta"
        return 1
    fi
    local line="- {name: \"$(_yaml_dq "$name")\", type: hysteria2, server: \"$(_yaml_dq "$addr")\", port: $port, password: \"$(_yaml_dq "$auth")\", sni: \"$(_yaml_dq "$sni")\""
    # brutal/force-brutal: mihomo 以 up/down 触发 brutal 速率控制; 带宽未填则省略(与分享链接一致)
    if [ "$congestion" = "brutal" ] || [ "$congestion" = "force-brutal" ]; then
        [ -n "$brutal_down" ] && line="${line}, up: \"$(_yaml_dq "$brutal_down")\""
        [ -n "$brutal_up" ] && line="${line}, down: \"$(_yaml_dq "$brutal_up")\""
    fi
    # 混淆: mihomo 有独立字段可完整表达(含 gecko 分片尺寸; 官方 hy2 URI 无尺寸参数)
    if [ "$obfs_kind" != "none" ]; then
        line="${line}, obfs: ${obfs_kind}, obfs-password: \"$(_yaml_dq "$obfs_pw")\""
        [ -n "$obfs_min" ] && line="${line}, obfs-min-packet-size: ${obfs_min}"
        [ -n "$obfs_max" ] && line="${line}, obfs-max-packet-size: ${obfs_max}"
    fi
    # 端口跳跃: 引号必须有 —— flow 映射上下文里裸逗号会被解析成字段分隔符
    local hop_ports
    hop_ports=$(_read_hop_ranges_display "$meta" 2>/dev/null)
    [ -n "$hop_ports" ] && line="${line}, ports: \"${hop_ports}\""
    [ "$self_signed" = "true" ] && line="${line}, skip-cert-verify: true"
    printf '%s}' "$line"
}

# _hy2_sync_derived 统一同步分享链接+Clash；不可表达时清链接但仍同步Clash。
# config/metadata是权威，派生失败只告警且如实返回，不回滚权威状态。
_hy2_sync_derived() {
    local meta="$1" old_name="${2:-}" link="" nname="" nline="" lrc=0 crc=0
    # (1) share_link: 派生值, 但写在 metadata 里、是用户直接看到的主输出 —— 失败要单独报。
    link=$(_rebuild_hy2_link "$meta") || lrc=$?
    if [ "$lrc" -eq 0 ] && [ -n "$link" ]; then
        _meta_update "$meta" '.share_link=$l' --arg l "$link" || {
            lrc=1
            _error "分享链接写入失败(节点元数据不可写?): $meta"
        }
    elif _hy2_link_unexpressible "$meta"; then
        lrc=0
        _meta_update "$meta" '.share_link=""' || {
            lrc=1
            _error "分享链接清空失败(节点元数据不可写?): $meta"
        }
        _warn "当前混淆(gecko 带自定义分片尺寸)无法用官方 hy2 链接表达, 已清空分享链接"
        _tip "官方 URI 的 obfs 只表达类型(salamander/gecko), 没有尺寸参数; 只有默认 512-1200 可表达"
        _tip "请用 Clash 条目(含 obfs-min/max-packet-size)导入客户端"
    else
        lrc=1
        _warn "分享链接重建失败(元数据缺少必要字段), 已保留原链接"
    fi
    # (2) clash.yaml: 可再生派生缓存 —— 失败单独报, 且不回滚权威状态。
    # 必须 upsert(条目在 → 替换; 不在 → 追加), 否则新建节点会静默漏条目。
    nname=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    local key
    if [ -n "$nname" ] && nline=$(_hy2_clash_line "$meta"); then
        # 改名(改端口默认连带改名)时先删旧名条目, 否则旧条目会以"另一个节点"的形态留在
        # clash.yaml 里指向旧端口(幽灵条目)。与 _sync_node_clash 的 old_name 处理同源。
        if [ -n "$old_name" ] && [ "$old_name" != "$nname" ]; then
            _remove_node_from_yaml_by_name "$old_name" 2>/dev/null || {
                crc=1
                _warn "Clash YAML 旧条目删除失败(${old_name}), 可手工编辑 ${CLASH_YAML}"
            }
        fi
        key=$(_yaml_dq "$nname")
        if [ -f "$CLASH_YAML" ] && grep -qF "name: \"${key}\"" "$CLASH_YAML" 2>/dev/null; then
            _replace_node_in_yaml "$nline" "$nname" || {
                crc=1
                _warn "Clash YAML 条目同步失败, 可手工编辑 ${CLASH_YAML}"
            }
        else
            _add_node_to_yaml "$nline" "$nname" || {
                crc=1
                _warn "Clash YAML 条目追加失败, 可手工编辑 ${CLASH_YAML}"
            }
        fi
    else
        crc=1
        _warn "Clash 条目生成失败(元数据不完整), 可手工编辑 ${CLASH_YAML}"
    fi
    # 返回码 = 两部分合并(1 = 至少一部分失败)。具体哪一部分失败已在上方分别报出 ——
    # 调用方只据此提示"详情见上", 不要再把它们混成一句笼统文案。
    [ "$lrc" -eq 0 ] && [ "$crc" -eq 0 ] && return 0
    return 1
}

# _rebuild_clash_line 从metadata重建全协议派生行；缺必要字段返回1不写半成品。
_rebuild_clash_line() {
    local meta="$1" proto name addr port uuid enc enc_clash=""
    proto=$(jq -r '.protocol // empty' "$meta" 2>/dev/null)
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    port=$(jq -r '.port // empty' "$meta" 2>/dev/null)
    uuid=$(jq -r '.uuid // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] && [ -n "$addr" ] && [ -n "$port" ] || return 1
    enc=$(jq -r '.encryption // "none"' "$meta" 2>/dev/null)
    if [ -n "$enc" ] && [ "$enc" != "none" ]; then
        enc_clash=", encryption: \"$(_yaml_dq "$enc")\""
    fi
    case "$proto" in
        hysteria2)
            _hy2_clash_line "$meta"
            ;;
        vless-tcp-reality-vision)
            local pk sid sni
            pk=$(jq -r '.public_key // empty' "$meta")
            sid=$(jq -r '.short_id // empty' "$meta")
            sni=$(jq -r '.sni // empty' "$meta")
            [ -n "$uuid" ] && [ -n "$pk" ] && [ -n "$sid" ] && [ -n "$sni" ] || return 1
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, flow: xtls-rprx-vision, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $pk, short-id: $sid, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, network: tcp}"
            ;;
        vless-xhttp-reality)
            local pk sid sni path
            pk=$(jq -r '.public_key // empty' "$meta")
            sid=$(jq -r '.short_id // empty' "$meta")
            sni=$(jq -r '.sni // empty' "$meta")
            path=$(jq -r '.path // empty' "$meta")
            [ -n "$uuid" ] && [ -n "$pk" ] && [ -n "$sid" ] && [ -n "$sni" ] && [ -n "$path" ] || return 1
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, network: xhttp, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $pk, short-id: $sid, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\"}}"
            ;;
        vless-enc)
            # enc 节点必有密钥(创建即生成); metadata 缺 encryption 说明是半套元数据, 不重建
            [ -n "$uuid" ] && [ -n "$enc" ] && [ "$enc" != "none" ] || return 1
            local flow fl=""
            flow=$(jq -r '.flow // empty' "$meta")
            [ -n "$flow" ] && fl=", flow: ${flow}"
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, encryption: \"$(_yaml_dq "$enc")\", network: tcp, tls: false${fl}}"
            ;;
        vless-xhttp-cdn|vless-ws-cdn)
            # CDN 条目指向 CDN 入口(preferred_addr/port), 不是 xray 监听端口
            local pref_addr pref_port host path fp
            fp=$(jq -r '.fp // "chrome"' "$meta")
            pref_addr=$(jq -r '.preferred_addr // .host // empty' "$meta")
            pref_port=$(jq -r '.preferred_port // "443"' "$meta")
            host=$(jq -r '.host // empty' "$meta")
            path=$(jq -r '.path // empty' "$meta")
            [ -n "$uuid" ] && [ -n "$host" ] && [ -n "$path" ] && [ -n "$pref_addr" ] || return 1
            [[ "$pref_port" =~ ^[0-9]+$ ]] || pref_port=443
            if [ "$proto" = "vless-xhttp-cdn" ]; then
                printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$pref_addr")\", port: $pref_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": \"$(_yaml_dq "$fp")\", network: xhttp, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\", host: \"$(_yaml_dq "$host")\"}}"
            else
                printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$pref_addr")\", port: $pref_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": \"$(_yaml_dq "$fp")\", network: ws, \"ws-opts\": {path: \"$(_yaml_dq "$path")\", headers: {Host: \"$(_yaml_dq "$host")\"}}}"
            fi
            ;;
        shadowsocks)
            # udp 标志的权威来源是 config 的 settings.network(metadata 未存)
            # net 给默认值: metadata 缺 tag 时(手工编辑/损坏)上一行短路, set -u 下读 $net 会崩溃
            local method password net="" udp_clash=""
            method=$(jq -r '.method // empty' "$meta")
            password=$(jq -r '.password // empty' "$meta")
            [ -n "$method" ] && [ -n "$password" ] || return 1
            local tag; tag=$(jq -r '.tag // empty' "$meta" 2>/dev/null)
            [ -n "$tag" ] && net=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.network // "tcp,udp"' 2>/dev/null)
            [[ "$net" == *"udp"* ]] && udp_clash=", udp: true"
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: ss, server: \"$(_yaml_dq "$addr")\", port: $port, cipher: $method, password: \"$(_yaml_dq "$password")\"${udp_clash}}"
            ;;
        *) return 1 ;;
    esac
}

# _sync_node_clash 失败告警并返回1；调用者保留已提交config/metadata，不伪报同步成功。
_sync_node_clash() {
    _with_config_lock _sync_node_clash_locked "$@"
}

_sync_node_clash_locked() {
    local meta="$1" old_name="${2:-}" line name key crc=0
    # 元数据缺必填字段时保留 clash 旧行(它可能仍指向一个可用的旧配置), 但如实返回失败
    if ! line=$(_rebuild_clash_line "$meta"); then
        _warn "Clash 条目重建失败(元数据缺少必要字段), clash.yaml 未同步: $meta"
        return 1
    fi
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] || return 1
    if [ -n "$old_name" ] && [ "$old_name" != "$name" ]; then
        _remove_node_from_yaml_by_name "$old_name" 2>/dev/null || {
            crc=1
            _warn "Clash YAML 旧条目删除失败(${old_name}), 可手工编辑 ${CLASH_YAML}"
        }
    fi
    key=$(_yaml_dq "$name")
    if [ -f "$CLASH_YAML" ] && grep -qF "name: \"${key}\"" "$CLASH_YAML" 2>/dev/null; then
        _replace_node_in_yaml "$line" "$name" || {
            crc=1
            _warn "Clash YAML 条目同步失败, 可手工编辑 ${CLASH_YAML}"
        }
    else
        _add_node_to_yaml "$line" "$name" || {
            crc=1
            _warn "Clash YAML 条目追加失败, 可手工编辑 ${CLASH_YAML}"
        }
    fi
    return "$crc"
}

# Reality分享链接从metadata重建；pqv取客户端verify，不泄露seed。
_rebuild_reality_link() {
    local meta="$1" new_sni="${2:-}"
    local uuid host port proto sni pk sid pqv name path
    uuid=$(jq -r '.uuid // empty' "$meta")
    host=$(jq -r '.link_addr // empty' "$meta")
    port=$(jq -r '.port // empty' "$meta")
    proto=$(jq -r '.protocol // empty' "$meta")
    sni=$(jq -r '.sni // empty' "$meta")
    [ -n "$new_sni" ] && sni="$new_sni"
    pk=$(jq -r '.public_key // empty' "$meta")
    sid=$(jq -r '.short_id // empty' "$meta")
    pqv=$(jq -r '.mldsa65_verify // empty' "$meta")
    name=$(jq -r '.name // empty' "$meta")
    path=$(jq -r '.path // empty' "$meta")
    if [ -z "$uuid" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$sni" ] \
       || [ -z "$pk" ] || [ -z "$sid" ] || [ -z "$name" ]; then
        _error "节点元数据缺少必要字段(uuid/link_addr/port/sni/public_key/short_id/name), 无法重建分享链接: $meta"
        return 1
    fi
    local enc; enc=$(jq -r '.encryption // "none"' "$meta")
    local enc_param
    if [ "$enc" != "none" ] && [ -n "$enc" ]; then
        enc_param=$(_url_encode "$enc")
    else
        enc_param="none"
    fi
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link
    case "$proto" in
        vless-tcp-reality-vision)
            # 分享链接标准: type=tcp(非 raw)、REALITY 必带 fp 且默认 chrome、sni 需转义
            link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}"
            ;;
        vless-xhttp-reality)
            link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=xhttp&mode=auto&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}&path=$(_url_encode "$path")"
            ;;
        *) echo ""; return 1 ;;
    esac
    [ -n "$pqv" ] && link="${link}&pqv=${pqv}"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 vless-enc:// 分享链接(从元数据读参数)
# 用法:_rebuild_vless_enc_link <meta_file>
_rebuild_vless_enc_link() {
    local meta="$1"
    local uuid host port flow enc name
    uuid=$(jq -r '.uuid' "$meta")
    host=$(jq -r '.link_addr' "$meta")
    port=$(jq -r '.port' "$meta")
    flow=$(jq -r '.flow // empty' "$meta")
    enc=$(jq -r '.encryption // "none"' "$meta")
    name=$(jq -r '.name' "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local enc_encoded; enc_encoded=$(_url_encode "$enc")
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_encoded}&security=none&type=tcp"
    [ -n "$flow" ] && link="${link}&flow=${flow}"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 CDN 节点分享链接(从元数据读参数)
# 用法:_rebuild_cdn_link <meta_file>
_rebuild_cdn_link() {
    local meta="$1"
    local uuid host path name proto preferred_addr preferred_port sni fp alpn
    uuid=$(jq -r '.uuid' "$meta")
    host=$(jq -r '.host' "$meta")
    path=$(jq -r '.path // empty' "$meta")
    name=$(jq -r '.name' "$meta")
    proto=$(jq -r '.protocol' "$meta")
    preferred_addr=$(jq -r '.preferred_addr // .host' "$meta")
    preferred_port=$(jq -r '.preferred_port // "443"' "$meta")
    sni=$(jq -r '.sni // .host' "$meta")
    # 已选指纹原样导出；Firefox 仍受支持，缺失时默认 Chrome(transport.md: fingerprint)。
    fp=$(jq -r '.fp // "chrome"' "$meta")
    alpn=$(jq -r '.alpn // "h2"' "$meta")
    local enc; enc=$(jq -r '.encryption // "none"' "$meta")
    local enc_param
    if [ "$enc" != "none" ] && [ -n "$enc" ]; then
        enc_param=$(_url_encode "$enc")
    else
        enc_param="none"
    fi
    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local link
    case "$proto" in
        vless-xhttp-cdn)
            link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$sni")&fp=${fp}&alpn=${alpn}&type=xhttp&mode=auto&host=$(_url_encode "$host")&path=$(_url_encode "$path")"
            ;;
        vless-ws-cdn)
            link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$sni")&fp=${fp}&type=ws&host=$(_url_encode "$host")&path=$(_url_encode "${path}?ed=2560")"
            ;;
        *) echo ""; return 1 ;;
    esac
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# ---------------------------------------------------------------------------
# 模板路径辅助
# ---------------------------------------------------------------------------
_tpl_path() {
    local key="$1"
    case "$key" in
        # direct/tunnel只改变target拓扑；同协议处理由 _reality_node_mode 区分。
        vless-tcp-reality-vision-tunnel) echo "/opt/xray-deploy/templates/vless-tcp-reality-vision-tunnel.server.jsonc" ;;
        vless-tcp-reality-vision-direct) echo "/opt/xray-deploy/templates/vless-tcp-reality-vision-direct.server.jsonc" ;;
        vless-xhttp-reality-tunnel)      echo "/opt/xray-deploy/templates/vless-xhttp-reality-tunnel.server.jsonc" ;;
        vless-xhttp-reality-direct)      echo "/opt/xray-deploy/templates/vless-xhttp-reality-direct.server.jsonc" ;;
        tunnel)                   echo "/opt/xray-deploy/templates/tunnel.server.jsonc" ;;
        vless-enc)                echo "/opt/xray-deploy/templates/vless-enc.server.jsonc" ;;
        vless-xhttp-cdn)          echo "/opt/xray-deploy/templates/vless-xhttp-cdn.server.jsonc" ;;
        vless-ws-cdn)             echo "/opt/xray-deploy/templates/vless-ws-cdn.server.jsonc" ;;
        shadowsocks)              echo "/opt/xray-deploy/templates/shadowsocks.server.jsonc" ;;
        hysteria2)                echo "/opt/xray-deploy/templates/hysteria2.server.jsonc" ;;
    esac
}

# ---------------------------------------------------------------------------
# 查看节点(含监听列 )
# ---------------------------------------------------------------------------
_view_nodes() {
    clear
    local count
    count=$(_node_count)
    echo
    echo -e "  ${CYAN}【节点列表】${NC} (共 ${count} 个)"
    if [ "$count" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无节点${NC}"
        _press_any_key; return
    fi
    echo
    printf "  %-3s %-20s %-26s %-8s %-7s %-10s %-16s %-18s\n" "#" "名称" "协议" "模式" "端口" "认证" "监听" "链接地址"
    echo "  ----------------------------------------------------------------------------------------------------------"
    local i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name proto port auth listen addr tag rmode
        tag=$(basename "$f" .json)
        name=$(jq -r '.name' "$f" 2>/dev/null)
        proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        port=$(jq -r '.port' "$f" 2>/dev/null)
        auth=$(jq -r '.auth // "—"' "$f" 2>/dev/null)
        listen=$(jq -r '.listen' "$f" 2>/dev/null)
        addr=$(jq -r '.link_addr' "$f" 2>/dev/null)
        # 列表区分direct/tunnel；避免协议键相同导致部署模式不可见。
        rmode="——"
        case "$proto" in
            vless-tcp-reality-vision|vless-xhttp-reality)
                if [ "$(_reality_node_mode "$tag")" = "direct" ]; then
                    rmode="直连"
                else
                    rmode="隧道"
                fi
                ;;
        esac
        printf "  %-3s %-20s %-26s %-8s %-7s %-10s %-16s %-18s\n" "[$i]" "${name}" "${proto}" "${rmode}" "${port}" "${auth}" "${listen}" "${addr}"
        i=$((i+1))
    done
    echo
    echo -e "  ${YELLOW}查看某节点分享链接?${NC}"
    read -rp "  输入编号(0 返回): " choice
    [ "$choice" = "0" ] && return
    # 本函数按显示序号遍历(没有 tags 数组), 故上界是节点总数 count; 复用共享边界解析
    # 以避免超大编号回绕成负索引而命中别的节点。
    local idx n=0
    idx=$(_xd_index_from_choice "$choice" "$count") || { _warn "无效选择"; _press_any_key; return; }
    idx=$((idx + 1))
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$((n+1))
        if [ "$n" -eq "$idx" ]; then
            local name link auth
            name=$(jq -r '.name' "$f"); link=$(jq -r '.share_link' "$f")
            auth=$(jq -r '.auth // "—"' "$f" 2>/dev/null)
            echo
            echo -e "  ${CYAN}【${name}】${NC}"
            [ "$auth" != "—" ] && echo -e "  认证算法: ${auth}"
            # 空链接可能是无法表达的gecko自定义尺寸；显示提示，不拼造连接信息。
            if [ -z "$link" ] || [ "$link" = "null" ]; then
                echo -e "  ${YELLOW}该节点当前无可用分享链接${NC}"
                if _hy2_link_unexpressible "$f"; then
                    echo -e "  ${YELLOW}原因: gecko 使用了自定义分片尺寸(官方 hy2 URI 的 obfs 只表达类型, 无尺寸参数)${NC}"
                    echo -e "  ${YELLOW}请改用 clash/mihomo 条目导入(含 obfs-min/max-packet-size), 见 ${CLASH_YAML}${NC}"
                else
                    echo -e "  ${YELLOW}原因: 节点元数据缺少链接所需字段(请删除该节点后重建)${NC}"
                fi
            else
                echo -e "  ${GREEN}${link}${NC}"
            fi
            local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
            case "$proto" in *cdn*) _warn "此为 CDN 协议, 禁止直连, 须经 Cloudflare 回源" ;; esac
            break
        fi
    done
    _press_any_key
}

# 删除锁外选择确认，锁内校验身份并提交；证书仅在配置删除成功后清理。
_delete_node() {
    clear
    local count; count=$(_node_count)
    [ "$count" -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【删除节点】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local tag name
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %s\n" "$i" "$name"
        i=$((i+1))
    done
    echo -e "  ${RED}[a]${NC} ${RED}全部删除${NC} | 多选: 逗号分隔(如1,3)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择: " choice
    [ "$choice" = "0" ] && return

    # 全部删除(y/N 确认)
    if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
        echo -e "  ${RED}确认删除全部 ${#tags[@]} 个节点? 此操作不可恢复${NC}"
        read -rp "  继续? [y/N]: " ans
        case "$ans" in
            y|Y) ;;
            *) _info "已取消"; _press_any_key; return ;;
        esac
        # 自签证书询问在锁外完成；把人工思考时间留在临界区外。
        _hy2_ask_purge_self_certs "${tags[@]}"
        _with_config_lock _delete_node_apply_all
        _press_any_key; return
    fi

    # 多选删除:逗号分隔(如1,3,5)
    if [[ "$choice" == *","* ]]; then
        IFS=',' read -ra nums <<< "$choice"
        local del_tags=()
        for n in "${nums[@]}"; do
            n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
            local di
            di=$(_xd_index_from_choice "$n" "${#tags[@]}") || continue
            local dt="${tags[$di]:-}"
            [ -z "$dt" ] && continue
            # 去重
            local dup=0
            for existing in "${del_tags[@]}"; do [ "$existing" = "$dt" ] && { dup=1; break; }; done
            [ "$dup" -eq 1 ] && continue
            del_tags+=("$dt")
        done
        [ ${#del_tags[@]} -eq 0 ] && { _warn "无效选择"; _press_any_key; return; }

        echo -e "  ${RED}确认删除以下 ${#del_tags[@]} 个节点?${NC}"
        for dt in "${del_tags[@]}"; do
            local dn; dn=$(jq -r '.name' "$NODES_DIR/${dt}.json" 2>/dev/null)
            echo "    - $dn"
        done
        read -rp "  继续? [y/N]: " ans
        case "$ans" in y|Y) ;; *) _info "已取消"; _press_any_key; return ;; esac

        # 身份绑定：每个 tag 带上确认时的指纹, 锁内逐一复核。
        local del_idents=() _dt _idt
        for _dt in "${del_tags[@]}"; do
            _idt=$(_node_identity "$_dt") || { _error "无法读取节点身份, 已取消: $_dt"; _press_any_key; return; }
            del_idents+=("$_dt" "$_idt")
        done
        _hy2_ask_purge_self_certs "${del_tags[@]}"
        _with_config_lock _delete_node_apply_multi "${del_idents[@]}"
        _press_any_key; return
    fi

    local idx
    idx=$(_xd_index_from_choice "$choice" "${#tags[@]}") || { _warn "无效选择"; _press_any_key; return; }
    local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    # 身份绑定：锁外选的 tag 可能已被并发删除/重建 —— 锁内必须复核指纹。
    local ident
    ident=$(_node_identity "$tag") || { _error "无法读取节点身份, 已取消: $tag"; _press_any_key; return; }
    _hy2_ask_purge_self_certs "$tag"
    _with_config_lock _delete_node_apply_single "$tag" "$ident"
    _press_any_key
}

# 删除apply必须已持锁；身份不一致取消，返回0已提交/1失败。
_delete_node_apply_all() {
    local tags=() tag f
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        tags+=("$(basename "$f" .json)")
    done
    if [ ${#tags[@]} -eq 0 ]; then
        _error "当前没有可删除的节点(metadata 为空), 已取消"
        return 1
    fi
    # 先teardown hop并记录回滚；不能先删metadata丢失规则定位。
    if ! _hy2_hop_teardown_all "${tags[@]}"; then
        _error "所有节点都无法安全清理端口跳跃规则, 已取消删除(节点未动)"
        return 1
    fi
    _hy2_filter_skipped "${tags[@]}"
    local del_all=("${_HY2_DEL_KEEP[@]}")
    if [ ${#del_all[@]} -eq 0 ]; then
        _error "没有可安全删除的节点"
        return 1
    fi
    # 证书询问在锁外，锁内只消费结果；实际purge必须等config提交。
    local all_filter='.inbounds = [] | .routing.rules |= map(select((type != "object") or .inboundTag == null or ((.inboundTag | type) == "array" and (.inboundTag | length) == 0)))'
    local all_ok=0
    if [ ${#_HY2_HOP_SKIP[@]} -eq 0 ]; then
        _mutate_config "$all_filter" && all_ok=1
    else
        local keep_tags=() kt ktt rrc
        for kt in "${del_all[@]}"; do
            keep_tags+=("$kt")
            ktt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${kt}.json" 2>/dev/null)
            [ -n "$ktt" ] || continue
            _reality_tunnel_has_surviving_refs "$ktt" "${del_all[@]}"; rrc=$?
            if [ "$rrc" = 0 ]; then
                continue
            elif [ "$rrc" = 2 ]; then
                _warn "无法确认 Reality tunnel 是否仍被引用, 保留 tunnel 与路由规则: $ktt"
                continue
            fi
            keep_tags+=("$ktt")
        done
        local rm_json
        rm_json=$(printf '%s\n' "${keep_tags[@]}" | jq -R . | jq -c -s .) || rm_json=""
        if [ -z "$rm_json" ]; then
            _error "生成移除集合失败"
            _hy2_hop_restore_after_teardown
            return 1
        fi
        _mutate_config --argjson rm "$rm_json" \
            '.inbounds |= map(select((type != "object") or ((.tag // "") as $tg | ($rm | index($tg)) == null)))
             | .routing.rules |= map(select((type != "object") or .inboundTag == null
                   or ([.inboundTag[]? | . as $it | ($rm | index($it)) == null] | all)))' && all_ok=1
    fi
    if [ "$all_ok" -eq 1 ]; then
        for tag in "${del_all[@]}"; do
            # 先删 metadata 再删 YAML 会读不到 name; 但 YAML 删除失败不阻断,
            # 顺序仍是"先 YAML(读 json 的 name) 后 json"
            _remove_node_from_yaml_by_tag "$tag" || \
                _warn "Clash YAML 同步删除失败($tag), 可手工编辑 ${CLASH_YAML} 清除该行"
            rm -f "$NODES_DIR/${tag}.json"
        done
        # 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
        _HY2_HOP_TD=()
        # 仅在"确实全删干净"时才截断 clash.yaml; 有保留节点时不能清空
        if [ ${#_HY2_HOP_SKIP[@]} -eq 0 ] && [ -f "$CLASH_YAML" ]; then
            printf 'proxies:\n' > "$CLASH_YAML"
        fi
        _success "已删除 ${#del_all[@]} 个节点"
        _hy2_purge_self_certs
        return 0
    fi
    # config 提交失败(已回滚): 恢复已 teardown 的 hop 规则
    _hy2_hop_restore_after_teardown
    _error "删除失败, 已回滚"
    return 1
}

_delete_node_apply_multi() {
    # 参数是 tag/fingerprint 交错对( 只有指纹与当前内容一致才允许删除。
    local del_tags=() del_idents=() dt now
    while [ "$#" -gt 0 ]; do
        del_tags+=("$1"); shift
        del_idents+=("${1:-}")
        [ "$#" -gt 0 ] && shift
    done
    local _i
    for _i in "${!del_tags[@]}"; do
        if [ -z "${del_idents[$_i]:-}" ]; then
            _error "缺少节点身份指纹, 拒绝删除(请重新选择): ${del_tags[$_i]}"
            return 1
        fi
        now=$(_node_identity "${del_tags[$_i]}") || { _error "无法重新读取节点身份: ${del_tags[$_i]}"; return 1; }
        if [ "$now" != "${del_idents[$_i]}" ]; then
            _error "节点内容已变化(可能被并发删除/重建/修改), 请重新选择: ${del_tags[$_i]}"
            return 1
        fi
    done
    # //同 _delete_node_apply_all —— teardown 在锁内, 逐项判定。
    if ! _hy2_hop_teardown_all "${del_tags[@]}"; then
        _error "所选节点都无法安全清理端口跳跃规则, 已取消删除(节点未动)"
        return 1
    fi
    _hy2_filter_skipped "${del_tags[@]}"
    del_tags=("${_HY2_DEL_KEEP[@]}")
    if [ ${#del_tags[@]} -eq 0 ]; then
        _error "没有可安全删除的节点"
        return 1
    fi
    # 自签证书询问在锁外(_delete_node)完成, 这里只消费回答
    local del_ttags=() dtt rrc existing
    for dt in "${del_tags[@]}"; do
        dtt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${dt}.json" 2>/dev/null)
        [ -n "$dtt" ] || continue
        _reality_tunnel_has_surviving_refs "$dtt" "${del_tags[@]}"; rrc=$?
        if [ "$rrc" = 0 ]; then
            continue
        elif [ "$rrc" = 2 ]; then
            _warn "无法确认 Reality tunnel 是否仍被引用, 保留 tunnel 与路由规则: $dtt"
            continue
        fi
        local duplicate=0
        for existing in "${del_ttags[@]}"; do
            [ "$existing" = "$dtt" ] && { duplicate=1; break; }
        done
        [ "$duplicate" -eq 1 ] || del_ttags+=("$dtt")
    done

    local tun_json='[]'
    [ ${#del_ttags[@]} -gt 0 ] && tun_json=$(printf '%s\n' "${del_ttags[@]}" | jq -R . | jq -s .)
    local all_json; all_json=$(printf '%s\n' "${del_tags[@]}" "${del_ttags[@]}" | jq -R . | jq -s .)

    # 同口径: type 守卫防止非对象规则/入站元素让 jq 整体报错。
    # tag 同样需 as 绑定后再 index(index 参数以 $all_tags 为输入求值)
    local jq_multi='.inbounds |= map(select((type != "object") or ((.tag // "") as $tg | ($all_tags | index($tg)) == null)))'
    if [ ${#del_ttags[@]} -gt 0 ]; then
        jq_multi="$jq_multi | .routing.rules |= map(select((type != \"object\") or .inboundTag == null or ((.inboundTag as \$it | \$tun_tags | index(\$it)) == null)))"
    fi

    if _mutate_config --argjson all_tags "$all_json" --argjson tun_tags "$tun_json" "$jq_multi"; then
        # 消费 YAML 删除返回值, 失败则累计并显式告警(不静默; clash.yaml 属派生导出)
        local yaml_fail=0
        for dt in "${del_tags[@]}"; do
            # 先删 YAML(需读 json 的 name)再删 json, 否则幽灵节点残留在 clash.yaml
            _remove_node_from_yaml_by_tag "$dt" || yaml_fail=1
            rm -f "$NODES_DIR/${dt}.json"
        done
        # 不再指向不存在的"重新生成 Clash 配置"功能, 给出真实可执行的路径
        [ "$yaml_fail" -eq 1 ] && \
            _warn "部分节点 Clash YAML 同步删除失败, 已从 Xray 删除; 可手工编辑 ${CLASH_YAML} 删除对应行"
        # 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
        _HY2_HOP_TD=()
        _success "已删除 ${#del_tags[@]} 个节点"
        _hy2_purge_self_certs
        return 0
    fi
    # config 提交失败(已回滚): 恢复已 teardown 的 hop 规则
    _hy2_hop_restore_after_teardown
    _error "删除失败, 已回滚"
    return 1
}

_delete_node_apply_single() {
    local tag="$1" expect="${2:-}" now
    # 身份绑定：缺指纹或与当前内容不符一律拒绝 —— 防止误删并发重建的同名节点。
    if [ -z "$expect" ]; then
        _error "缺少节点身份指纹, 拒绝删除(请重新选择): $tag"
        return 1
    fi
    now=$(_node_identity "$tag") || { _error "无法重新读取节点身份: $tag"; return 1; }
    if [ "$now" != "$expect" ]; then
        _error "节点内容已变化(可能被并发删除/重建/修改), 请重新选择: $tag"
        return 1
    fi
    # 读取 tunnel_tag, 一次性删除 tunnel + reality + 路由(原子操作)
    # 同口径: type 守卫防止非对象入站/规则元素让 jq 整体报错(手改 config 时删除被拒绝服务)
    local tunnel_tag preserve_tunnel=0 shared_rc proto
    tunnel_tag=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${tag}.json" 2>/dev/null)
    proto=$(jq -r '.protocol // empty' "$NODES_DIR/${tag}.json" 2>/dev/null)
    if [ -n "$tunnel_tag" ] && { [ "$proto" = vless-tcp-reality-vision ] || [ "$proto" = vless-xhttp-reality ]; }; then
        _reality_tunnel_has_surviving_refs "$tunnel_tag" "$tag"; shared_rc=$?
        case "$shared_rc" in
            0) preserve_tunnel=1 ;;
            2) preserve_tunnel=1; _warn "无法确认 Reality tunnel 是否仍被引用, 保留 tunnel 与路由规则: $tunnel_tag" ;;
        esac
    fi
    local jq_filter='.inbounds |= map(select((type != "object") or ((.tag // "") != $t)))'
    if [ -n "$tunnel_tag" ] && [ "$preserve_tunnel" -eq 0 ]; then
        jq_filter="$jq_filter | .routing.rules |= map(select((type != \"object\") or .inboundTag == null or ((.inboundTag | index(\$tg)) == null)))
            | .inbounds |= map(select((type != \"object\") or ((.tag // \"\") != \$tg)))"
    fi
    # //hop 校验与 teardown 都在锁内完成; 任一失败即取消删除, 节点保持原状。
    local hop_port ranges=""
    if ! proto=$(_node_protocol_safe "$tag"); then
        return 1
    fi
    if [ "$proto" = "hysteria2" ]; then
        _hy2_hop_meta_ok "$tag" || return 1
        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        if [ -n "$ranges" ]; then
            # 存在 hop 规则但 iptables 不可用 → 无法安全删除(否则删 config/metadata
            # 留孤儿 DNAT, 且 metadata 已删后无法追溯 dport 归属)
            if ! command -v iptables >/dev/null 2>&1; then
                _error "节点存在端口跳跃规则, 但 iptables 不可用, 无法安全删除: $tag"
                return 1
            fi
            if ! hop_port=$(jq -r '.port // empty' "$NODES_DIR/${tag}.json" 2>/dev/null); then
                _error "节点元数据损坏, 无法确认端口: $tag"
                return 1
            fi
            [[ "$hop_port" =~ ^[0-9]+$ ]] || {
                _error "节点元数据损坏(端口无效): $tag"
                return 1
            }
            # 删hop前校验metadata端口等于真实监听；否则保留节点及规则。
            local cfg_port
            cfg_port=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' 2>/dev/null)
            if [ -n "$cfg_port" ] && [ "$cfg_port" != "$hop_port" ]; then
                _error "节点元数据端口($hop_port)与 config 监听端口($cfg_port)不一致, 无法安全删除: $tag"
                return 1
            fi
            _info "清理端口跳跃规则..."
            # shellcheck disable=SC2086
            if ! _hy2_hop_teardown "$hop_port" $ranges; then
                _error "端口跳跃规则清理失败, 已取消删除(节点未动)"
                return 1
            fi
        fi
    fi
    # 自签证书询问在锁外(_delete_node)完成, 这里只消费回答
    if _mutate_config --arg t "$tag" --arg tg "$tunnel_tag" "$jq_filter"; then
        # 先按name删YAML再删JSON；JSON是派生缓存定位依据。
        if ! _remove_node_from_yaml_by_tag "$tag"; then
            _warn "Clash YAML 同步删除失败($tag), 节点已从 Xray 删除; 可手工编辑 ${CLASH_YAML} 删除对应行"
        fi
        rm -f "$NODES_DIR/${tag}.json"
        # 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
        _HY2_HOP_TD=()
        _success "节点已删除"
        _hy2_purge_self_certs
        return 0
    fi
    # config失败恢复hop并持久化；未恢复项保留日志供重试。
    if [ -n "$ranges" ]; then
        # shellcheck disable=SC2086
        _hy2_hop_reverse remove "$hop_port" $ranges 2>/dev/null || \
            _error "恢复端口跳跃规则失败, 请手动检查 iptables"
    fi
    _error "删除失败, 已回滚"
    return 1
}

# Reality改端口全程同锁：journal→metadata重命名→config；失败恢复tag和内容。
_reality_port_txn() {
    _with_config_lock _reality_port_txn_locked "$@"
}
_reality_port_txn_locked() {
    local tag="$1" meta="$2" oldport="$3" newport="$4"
    # 本事务临界区标记(见 _hy2_port_txn_locked 同名说明)
    local XD_PORT_TXN_ACTIVE=1 current_tag current_port
    current_tag=$(jq -r '.tag // empty' "$meta" 2>/dev/null) || return 1
    current_port=$(jq -r '.port // empty' "$meta" 2>/dev/null) || return 1
    if [ "$current_tag" != "$tag" ] || [ "$current_port" != "$oldport" ] || \
       ! _validate_port "$oldport" || ! _validate_port "$newport"; then
        _error "Reality 节点元数据已变化, 请重新选择端口: $tag"
        return 1
    fi
    if ! _config_jq -e --arg t "$tag" --argjson p "$oldport" \
        '[.inbounds[]? | select(.tag == $t and .protocol == "vless" and .port == $p and .streamSettings.realitySettings != null)] | length == 1' \
        >/dev/null 2>&1; then
        _error "config 中的 Reality 节点已变化, 拒绝开始端口事务: $tag"
        return 1
    fi
    # 判模式统一 _reality_node_mode；direct无tunnel，未知保守走tunnel检查。
    local tunnel_tag="" tunnel_port sni trc rmode
    rmode=$(_reality_node_mode "$tag")
    if [ "$rmode" = "tunnel" ]; then
        # 缺tunnel_tag由配置唯一关联推导；歧义拒绝，不能盲选。
        tunnel_tag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null)
        tunnel_port=$(jq -r '.tunnel_port // empty' "$meta" 2>/dev/null)
        sni=$(jq -r '.sni // empty' "$meta" 2>/dev/null)
        if [ -z "$tunnel_tag" ]; then
            tunnel_tag=$(_find_reality_tunnel_tag "$tag"); trc=$?
            if [ "$trc" != "0" ]; then
                _error "无法唯一关联 Reality tunnel (rc=${trc}), 无法安全修改端口: $tag"
                _tip "请检查配置的 realitySettings.target 与 tunnel 入站, 或删除后重建节点"
                return 1
            fi
        else
            # 已有tunnel_tag仍需交叉校验真实target/port；metadata不能单独证明归属。
            if ! _config_jq -e --arg tg "$tunnel_tag" \
                '[.inbounds[] | select(.tag == $tg and .protocol == "tunnel")] | length > 0' \
                >/dev/null 2>&1; then
                _error "metadata 记录的 tunnel_tag (${tunnel_tag}) 在 config 中不存在, 无法安全修改端口"
                _tip "请检查配置中是否仍有该 tunnel 入站, 缺失时删除该节点后重建"
                return 1
            fi
        fi
    fi

    # 主 tag 前缀(xd-reality-vision / xd-reality-xhttp) + 新端口
    local new_tag="${tag%-*}-${newport}"
    # 单节点沿用端口后缀；共享 tunnel 保持 tag，避免其它节点 metadata 引用失效。
    local new_tunnel_tag="" targets target host shared_tunnel=0
    if [ -n "$tunnel_tag" ]; then
        tunnel_port=$(_config_jq -er --arg tg "$tunnel_tag" \
            '.inbounds[] | select(.tag == $tg and .protocol == "tunnel") | .port') || return 1
        # 先以 metadata 交叉确认共享引用；旧节点即使 config target 缺失/格式异常，
        # 也不能把仍被引用的 tunnel 当成独占资源。
        local peer peer_tunnel peer_port
        for peer in "$NODES_DIR"/*.json; do
            [ -f "$peer" ] || continue
            [ "$peer" = "$meta" ] && continue
            jq -e . "$peer" >/dev/null 2>&1 || {
                _error "其他节点 metadata 无法解析, 无法确认 tunnel 是否共享: $peer"
                return 1
            }
            peer_tunnel=$(jq -r '.tunnel_tag // empty' "$peer" 2>/dev/null)
            peer_port=$(jq -r '.tunnel_port // empty' "$peer" 2>/dev/null)
            if [ -n "$peer_tunnel" ] && [ "$peer_tunnel" = "$tunnel_tag" ]; then
                shared_tunnel=1; break
            fi
            if [ -n "$peer_port" ] && [ -n "$peer_tunnel" ] && [ "$peer_tunnel" = "$tunnel_tag" ] \
                && [ "$(jq -nr --arg p "$peer_port" --argjson t "$tunnel_port" 'try (($p | tonumber) == $t) catch false')" = true ]; then
                shared_tunnel=1; break
            fi
        done
        if [ "$shared_tunnel" -eq 0 ]; then
            targets=$(_config_jq -r --arg t "$tag" \
                '.inbounds[] | select(.tag != $t and .protocol == "vless")
                 | .streamSettings.realitySettings.target // empty') || return 1
            while IFS= read -r target; do
                [ -n "$target" ] || continue
                local parsed_host parsed_port
                parsed_host=$(jq -nr --arg v "$target" 'try ($v | capture("^(?<host>\\[[^]]+\\]|[^:]+):(?<port>[0-9]+)$") | .host) catch empty')
                parsed_port=$(jq -nr --arg v "$target" 'try ($v | capture("^(?<host>\\[[^]]+\\]|[^:]+):(?<port>[0-9]+)$") | .port) catch empty')
                if [ -z "$parsed_host" ] || [ -z "$parsed_port" ]; then
                    _error "config 中存在无法解析的 Reality target, 无法确认 tunnel 是否共享"
                    return 1
                fi
                if [ "$(jq -nr --arg p "$parsed_port" --argjson t "$tunnel_port" 'try (($p | tonumber) == $t) catch false')" = true ]; then
                    host="${parsed_host#[}"; host="${host%]}"
                    if _is_reality_loopback_host "$host"; then shared_tunnel=1; break; fi
                fi
            done <<< "$targets"
        fi
        if [ "$shared_tunnel" -eq 1 ]; then
            new_tunnel_tag="$tunnel_tag"
        else
            new_tunnel_tag="${tunnel_tag%-*}-${newport}"
        fi
    fi

    # 新 tag 冲突检查 —— 目标元数据文件已存在说明该端口/标签被其他节点占用,
    # mv 会静默覆盖。不依赖 _input_port 的上游间接保证, 这里显式校验。
    if [ -e "$NODES_DIR/${new_tag}.json" ]; then
        _error "目标标签 ${new_tag} 已存在(端口 ${newport} 可能已被其他节点使用), 请换一个端口"
        return 1
    fi

    # 新metadata仅内存构造；port/tag/tunnel_tag/name/share_link一起更新。
    local tmpm newmeta newlink old_name new_name
    tmpm=$(mktemp "${meta}.port.XXXXXX") || { _error "创建临时文件失败"; return 1; }
    old_name=$(jq -r '.name' "$meta")
    # 仅替换 "-<oldport>" 后缀, 全局子串替换会破坏名称中含端口号的其他数字
    new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")
    # 顺带回填 reality_mode —— 旧节点(无该字段)改端口后元数据自描述, 不再依赖推导
    if ! jq --argjson p "$newport" --arg nt "$new_tag" --arg ntg "$new_tunnel_tag" \
        --arg nn "$new_name" --arg rm "$rmode" \
        '.port=$p | .tag=$nt | (if $ntg != "" then .tunnel_tag=$ntg else . end) | .name=$nn | .reality_mode=$rm' \
        "$meta" > "$tmpm"; then
        rm -f "$tmpm"; _error "生成元数据失败"; return 1
    fi
    if ! newlink=$(_rebuild_reality_link "$tmpm") || [ -z "$newlink" ]; then
        rm -f "$tmpm"
        _warn "分享链接重建失败(元数据缺少必要字段), 端口未修改"
        _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
        return 1
    fi
    if ! newmeta=$(jq --arg l "$newlink" '.share_link=$l' "$tmpm") || [ -z "$newmeta" ]; then
        rm -f "$tmpm"; _error "生成元数据失败"; return 1
    fi
    rm -f "$tmpm"

    # 统一事务journal先写，metadata先提交，再config；回滚失败保留journal。
    local orig journal rrok
    journal="$NODES_DIR/${tag}.json.porttxn"
    orig=$(cat "$meta" 2>/dev/null) || { _error "读取元数据失败"; return 1; }
    if ! _port_txn_journal_write "$NODES_DIR/${tag}.json" "$NODES_DIR/${new_tag}.json" \
            reality "$oldport" "$newport" "" "$orig" "$newmeta"; then
        _error "端口事务 journal 写入失败, 未做任何修改"
        return 1
    fi

    # 1. 主 tag 即元数据文件名 —— 先重命名(config 未动, 失败干净中止)
    if ! mv "$NODES_DIR/${tag}.json" "$NODES_DIR/${new_tag}.json"; then
        _error "节点元数据文件重命名失败(${tag}.json → ${new_tag}.json), 未做任何修改"
        rm -f "$journal"
        return 1
    fi
    meta="$NODES_DIR/${new_tag}.json"

    # 2. 原子提交新 metadata; 失败时反向 mv 恢复文件名(此时新文件仍是原内容), config 未动
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 恢复原文件名..."
        rrok=0
        mv -f "$NODES_DIR/${new_tag}.json" "$NODES_DIR/${tag}.json" 2>/dev/null || \
            { _error "元数据文件名恢复失败, 请手动检查 ${NODES_DIR}"; rrok=1; }
        # 反向 mv 成功才删 journal; 失败保留, 启动期恢复会按"config 未提交"收敛
        if [ "$rrok" = 0 ]; then rm -f "$journal"; else _error "保留 journal 待启动恢复: $journal"; fi
        return 1
    fi

    # 3. 最后提交 config(改端口 + 重命名主 tag + tunnel tag + 路由规则引用)。
    #    _mutate_config 失败会自行恢复旧 config 并重启回旧端口; 这里同步回滚 metadata。
    local jq_filter
    jq_filter='(.inbounds[] | select(.tag == $t) | .tag) = $new_t
| (.inbounds[] | select(.tag == $new_t) | .port) = $p'
    if [ -n "$tunnel_tag" ] && [ "$tunnel_tag" != "$new_tunnel_tag" ]; then
        jq_filter="$jq_filter
| (.inbounds[] | select(.tag == \$tg) | .tag) = \$new_tg
| .routing.rules |= map(
    if .inboundTag != null and (.inboundTag | type) == \"array\"
    then .inboundTag |= map(if . == \$tg then \$new_tg else . end)
    else . end)"
    fi
    if ! _mutate_config --arg t "$tag" --arg new_t "$new_tag" --argjson p "$newport" \
         --arg tg "$tunnel_tag" --arg new_tg "$new_tunnel_tag" "$jq_filter"; then
        _error "端口配置提交失败, 回滚元数据到旧文件名与旧内容..."
        rrok=0
        rm -f "$NODES_DIR/${new_tag}.json" 2>/dev/null
        _atomic_write_json "$NODES_DIR/${tag}.json" "$orig" || \
            { _error "元数据回滚失败, 请手动检查 ${NODES_DIR}/${tag}.json"; rrok=1; }
        # 文件名与内容都回到旧态才删 journal; 否则保留, 启动期恢复按"config 未提交"收敛
        if [ "$rrok" = 0 ]; then rm -f "$journal"; else _error "保留 journal 待启动恢复: $journal"; fi
        return 1
    fi
    rm -f "$journal"

    if [ "$shared_tunnel" -eq 1 ]; then
        _success "端口已改为 ${newport}(节点标签已更新, 共享 tunnel 标签保持不变)"
    elif [ "$rmode" = "tunnel" ]; then
        _success "端口已改为 ${newport}(标签与 tunnel 标签已同步更新)"
    else
        _success "端口已改为 ${newport}(直连模式, 标签已同步更新)"
    fi
    # 派生缓存同步失败不撤销已提交端口；如实告警并提示核对。
    _sync_node_clash "$meta" "$old_name" || \
        _tip "clash 派生缓存未同步(节点本体已生效), 可在 [查看节点] 里核对 ${CLASH_YAML}"
}

# _port_txn 在同锁域执行journal→metadata→config，失败还原metadata；config由 _mutate_config 恢复。
# journal后缀.porttxn避免当节点扫描；三类端口事务由 _port_txn_recover 统一收敛。
_port_txn() {
    _with_config_lock _port_txn_locked "$@"
}

# journal由单一入口构造，port/hy2hop/reality共享schema；避免恢复格式漂移。
_port_txn_journal_write() {  # <old_path> <new_path> <kind> <oldport> <newport> <ranges> <old_json> <new_json>
    local old_path="$1" new_path="$2" kind="$3" oldport="$4" newport="$5" ranges="$6" old_json="$7" new_json="$8"
    # 写journal前统一恢复闸门；未收敛事务不能叠加新的配置修改。
    local _ex
    for _ex in "$NODES_DIR"/*.porttxn; do
        [ -e "$_ex" ] || continue
        _error "已存在未收敛的端口事务 journal, 拒绝开启新事务/覆盖现场: ${_ex##*/}"
        _tip "请重启脚本让启动恢复先收敛该 journal(现场已保留)"
        return 1
    done
    # (b) 统一闸门: reset / core 账本未收敛同样禁止开启端口事务(port 段由上面的检查承担,
    #     或在事务临界区内被 XD_PORT_TXN_ACTIVE 跳过)。
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    local payload
    payload=$(jq -n --arg kind "$kind" --argjson op "$oldport" --argjson np "$newport" \
        --arg opath "$old_path" --arg npath "$new_path" --arg ranges "$ranges" \
        --argjson old "$old_json" --argjson new "$new_json" \
        '{kind:$kind, tag:($old.tag // ""), newtag:($new.tag // ""), oldport:$op, newport:$np,
          old_path:$opath, new_path:$npath, ranges:$ranges, old:$old, new:$new}') || return 1
    _atomic_write_json "${old_path}.porttxn" "$payload"
}

_port_txn_build_newmeta() {
    local meta="$1" orig="$2" oldport="$3" newport="$4"
    local proto old_name new_name tmpm newlink="" rebuild_rc=0 newmeta=""
    proto=$(jq -r '.protocol // empty' <<< "$orig" 2>/dev/null) || return 1
    old_name=$(jq -r '.name // empty' <<< "$orig" 2>/dev/null) || return 1
    new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")
    if [ "$proto" = hysteria2 ]; then
        if newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport"); then
            printf '%s' "$newmeta"
            return 0
        fi
        # Test/adopted metadata without any link identity can only update its numeric port/name.
        if [ "$(jq -r 'has("share_link") or has("uuid")' <<< "$orig")" = false ]; then
            jq --argjson p "$newport" --arg n "$new_name" '.port=$p | .name=$n' <<< "$orig"
            return $?
        fi
        return 1
    fi
    tmpm=$(mktemp "${meta}.port.XXXXXX") || return 1
    if ! jq --argjson p "$newport" --arg n "$new_name" '.port=$p | .name=$n' <<< "$orig" > "$tmpm"; then
        rm -f "$tmpm"
        return 1
    fi
    case "$proto" in
        vless-tcp-reality-vision|vless-xhttp-reality) newlink=$(_rebuild_reality_link "$tmpm") || rebuild_rc=1 ;;
        vless-enc) newlink=$(_rebuild_vless_enc_link "$tmpm") || rebuild_rc=1 ;;
        vless-xhttp-cdn|vless-ws-cdn) newlink=$(_rebuild_cdn_link "$tmpm") || rebuild_rc=1 ;;
        *)
            local oldlink
            oldlink=$(jq -r '.share_link // empty' <<< "$orig" 2>/dev/null)
            newlink=$(_rewrite_link_port "$oldlink" "$oldport" "$newport")
            [ -n "$newlink" ] || rebuild_rc=1
            ;;
    esac
    if [ "$rebuild_rc" -ne 0 ] || [ -z "$newlink" ]; then
        newmeta=$(cat "$tmpm" 2>/dev/null) || newmeta=""
    else
        newmeta=$(jq --arg l "$newlink" '.share_link=$l' "$tmpm") || newmeta=""
    fi
    rm -f "$tmpm"
    [ -n "$newmeta" ] || return 1
    printf '%s' "$newmeta"
}


_port_txn_locked() {
    local tag="$1" meta="$2" newport="$3" _stale_newmeta="$4" expected_oldport="${5:-}" orig oldport journal newmeta
    # 本事务临界区标记(见 _hy2_port_txn_locked 同名说明)
    local XD_PORT_TXN_ACTIVE=1
    journal="${meta}.porttxn"
    [ -n "$_stale_newmeta" ] || { _error "新元数据为空, 端口事务未开始"; return 1; }
    orig=$(cat "$meta" 2>/dev/null) || { _error "读取元数据失败: $meta"; return 1; }
    [ -n "$orig" ] || { _error "元数据为空, 放弃端口修改: $meta"; return 1; }
    oldport=$(jq -r '.port // empty' <<< "$orig" 2>/dev/null)
    if [ "$(jq -r '.tag // empty' <<< "$orig" 2>/dev/null)" != "$tag" ] || \
       ! _validate_port "$oldport" || ! _validate_port "$newport"; then
        _error "节点元数据已变化, 请重新选择端口: $tag"
        return 1
    fi
    if [ -n "$expected_oldport" ] && [ "$expected_oldport" != "$oldport" ]; then
        _error "节点端口已变化, 请重新选择端口: $tag"
        return 1
    fi
    if _config_present && ! _config_jq -e --arg t "$tag" --argjson p "$oldport" '[.inbounds[]? | select(.tag == $t and .port == $p)] | length == 1' >/dev/null 2>&1; then
        _error "config 中的节点端口已变化, 拒绝开始端口事务: $tag"
        return 1
    fi
    newmeta=$(_port_txn_build_newmeta "$meta" "$orig" "$oldport" "$newport") || {
        _error "无法从当前节点元数据重建端口链接, 事务未开始: $tag"
        return 1
    }
    # 1. journal: 先于任何真实状态改动落盘
    if ! _port_txn_journal_write "$meta" "$meta" port "$oldport" "$newport" "" "$orig" "$newmeta"; then
        _error "端口事务 journal 写入失败, 未做任何修改"
        return 1
    fi
    # 2. 原子提交 metadata
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 未做任何修改"
        rm -f "$journal"
        return 1
    fi
    # 3. 提交 config
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口配置提交失败, 回滚元数据到旧端口..."
        # 回滚完整才删 journal; 回滚失败保留它, 让启动期恢复收敛(恢复路径幂等)
        if _atomic_write_json "$meta" "$orig"; then
            rm -f "$journal"
        else
            _error "元数据回滚失败, 保留 journal 待启动恢复: $journal"
        fi
        return 1
    fi
    rm -f "$journal"
    return 0
}

# ---------------------------------------------------------------------------
# iptables 可用性判据(单独成函数, 便于测试注入; 恢复的 hop 修复需要它)
_hy2_hop_available() { command -v iptables >/dev/null 2>&1; }

# 启动恢复与端口事务同锁，以config实际port或Reality(newtag,newport)判提交。
# 已提交收敛new，否则old并回退DNAT；metadata须匹配old/new，外部更新保留现场。
# 所有journal收敛才返回0；隔离不删除证据、保留待重试均返回1阻断后续写入。
_ptx_journal_quarantine() {
    local j="$1" why="$2" dest i
    # 不覆盖既有 .corrupt 证据: 依次找第一个空位(.corrupt / .corrupt.1 / … / .corrupt.9)。
    # 恢复在 config 锁内执行, 不存在并发竞争; 全被占满则保留原文件(仍不删)。
    dest=""
    for i in "" .1 .2 .3 .4 .5 .6 .7 .8 .9; do
        [ -e "${j}.corrupt${i}" ] || { dest="${j}.corrupt${i}"; break; }
    done
    if [ -n "$dest" ] && mv -f "$j" "$dest" 2>/dev/null; then
        _warn "端口事务 journal ${why}, 已隔离为 ${dest##*/} 待人工核对: $j"
    else
        _warn "端口事务 journal ${why}, 且隔离失败, 原文件保留待人工核对(未删除): $j"
    fi
}

# journal校验kind及全部字段结构；合法JSON不能证明合法事务身份。
_ptx_journal_ok() {
    jq -e --arg nodes "$NODES_DIR" --arg journal "$1" '
      def port_ok: (type == "number") and (. >= 1) and (. <= 65535) and (. == floor);
      def ranges_ok:
        (type == "string") and (. == "")
        # hop分隔符校验与实际读写入口一致；不能恢复任意损坏范围。
        or ((test("^[0-9]{1,5}(:[0-9]{1,5})?([,[:space:]]+[0-9]{1,5}(:[0-9]{1,5})?)*$"))
            and ([ splits("[,\\s]+") ] | map(select(length > 0)) | length > 0)
            and ([ splits("[,\\s]+") | select(length > 0) |
                   if test(":") then
                     (split(":") | (.[0]|tonumber) >= 1 and (.[0]|tonumber) <= 65535
                                 and (.[1]|tonumber) >= 1 and (.[1]|tonumber) <= 65535
                                 and (.[0]|tonumber) <= (.[1]|tonumber))
                   else ((tonumber) >= 1 and (tonumber) <= 65535) end ] | all));
      (.kind as $k
       | ($k == "port" or $k == "hy2hop" or $k == "reality")
       and (.tag | type == "string" and length > 0)
       and (.newtag | type == "string" and length > 0)
       and (.newport | port_ok)
       and (.oldport | port_ok)
       and (.old | type == "object")
       and (.new | type == "object")
       and (.old.tag == .tag)
       and (.new.tag == .newtag)
       # 四元组必须自洽: 恢复是把整份 old/new 写回 metadata, 若 old.port 与 oldport 打架,
       # 会写出 config.port 与 metadata.port 互相矛盾的残局 ⇒ 一并校验(含取值合法性)。
       and (.old.port | port_ok)
       and (.new.port | port_ok)
       and (.old.port == .oldport)
       and (.new.port == .newport)
       and (.tag | type == "string" and length > 0 and (contains("/") | not) and . != "." and . != "..")
       and (.newtag | type == "string" and length > 0 and (contains("/") | not) and . != "." and . != "..")
       and (.old_path == ($nodes + "/" + .tag + ".json"))
       and (.new_path == ($nodes + "/" + .newtag + ".json"))
       and ($journal == (.old_path + ".porttxn"))
       and (.ranges | ranges_ok)
       and (if $k == "hy2hop" then (.ranges | length > 0) else (.ranges == "") end)
       and (if $k == "reality" then (.old_path != .new_path and .tag != .newtag)
            else (.old_path == .new_path and .tag == .newtag) end))
    ' "$1" >/dev/null 2>&1
}

_port_txn_recover() {
    _with_config_lock _port_txn_recover_locked
}

_port_txn_recover_locked() {
    [ -d "$NODES_DIR" ] || return 0
    local j kind tag newtag oldport newport old_path new_path ranges
    local committed cur_path p cur_canon old_canon new_canon tgt_path tgt_obj
    # failed: 任一 journal 未收敛(被隔离/保留待人工) ⇒ 返回非零, 由调用方(启动维护链)
    # 空目录/全部收敛才返回0；隔离仍未收敛，阻断后续写入以保留现场。
    local failed=0
    for j in "$NODES_DIR"/*.porttxn; do
        [ -L "$j" ] && { _warn "端口事务 journal 是符号链接, 保留现场待人工核对: $j"; failed=1; continue; }
        [ -f "$j" ] || continue
        # 1) 必须是可解析的 JSON
        if ! jq -e . "$j" >/dev/null 2>&1; then
            _ptx_journal_quarantine "$j" "无法解析"
            failed=1
            continue
        fi
        # 合法事务schema才能恢复；未知kind或非法字段隔离而非猜测。
        if ! _ptx_journal_ok "$j"; then
            _ptx_journal_quarantine "$j" "schema 不合法(kind/字段/取值/结构)"
            failed=1
            continue
        fi
        kind=$(jq -r '.kind' "$j" 2>/dev/null)
        tag=$(jq -r '.tag' "$j" 2>/dev/null)
        newtag=$(jq -r '.newtag' "$j" 2>/dev/null)
        oldport=$(jq -r '.oldport' "$j" 2>/dev/null)
        newport=$(jq -r '.newport' "$j" 2>/dev/null)
        old_path=$(jq -r '.old_path' "$j" 2>/dev/null)
        new_path=$(jq -r '.new_path' "$j" 2>/dev/null)
        ranges=$(jq -r '.ranges // ""' "$j" 2>/dev/null)

        # (a) config is the recovery authority; unreadable, malformed, or non-canonical states
        # cannot be guessed as "not committed" because that could overwrite newer metadata.
        local cfg_state
        if ! _config_jq -e 'type == "object" and (.inbounds | type == "array")' \
            >/dev/null 2>&1; then
            _warn "端口事务恢复无法读取有效配置, 保留 journal 与现场: $j"
            failed=1
            continue
        fi
        if ! cfg_state=$(_config_jq -er --arg ot "$tag" --arg nt "$newtag" \
            --argjson op "$oldport" --argjson np "$newport" '
            ([.inbounds[] | select(type == "object" and .tag == $ot and .port == $op)] | length) as $old_count
            | ([.inbounds[] | select(type == "object" and .tag == $nt and .port == $np)] | length) as $new_count
            | if $old_count == 1 and $new_count == 0 then "old"
              elif $old_count == 0 and $new_count == 1 then "new"
              else "unknown" end' 2>/dev/null); then
            _warn "端口事务恢复无法判定配置中的节点状态, 保留 journal: $j"
            failed=1
            continue
        fi
        case "$cfg_state" in
            old) committed=0 ;;
            new) committed=1 ;;
            *)
                _warn "端口事务恢复遇到非旧/新目标的 config 状态, 保留 journal 与现场: $j"
                failed=1
                continue ;;
        esac

        # (b) 定位 metadata 当前文件(旧名优先), 并做事务身份校验
        cur_path=""
        for p in "$old_path" "$new_path"; do
            if [ -L "$p" ]; then
                _warn "端口事务元数据路径是符号链接, 保留 journal 与现场: $p"
                failed=1
                cur_path="unsafe"
                break
            fi
            [ -f "$p" ] && { cur_path="$p"; break; }
        done
        [ "$cur_path" = unsafe ] && continue
        if [ -z "$cur_path" ]; then
            # 两个候选路径都没有元数据 —— 说不清的现场, 与其它非法 journal 同策: 隔离而非删除
            _ptx_journal_quarantine "$j" "对应的元数据文件已不存在"
            failed=1
            continue
        fi
        cur_canon=$(jq -S . "$cur_path" 2>/dev/null)
        old_canon=$(jq -S '.old' "$j" 2>/dev/null)
        new_canon=$(jq -S '.new' "$j" 2>/dev/null)
        if [ "$cur_canon" != "$old_canon" ] && [ "$cur_canon" != "$new_canon" ]; then
            _warn "端口事务 journal 残留, 但 metadata 已被外部修改, 不自动处理(请人工核对): $cur_path"
            failed=1
            continue
        fi
        # metadata须语义匹配journal old/new；否则保留外部修改，不覆盖用户更新。
        if [ "$committed" = 1 ] && [ "$cur_canon" = "$old_canon" ]; then
            _warn "端口事务 journal 残留: config 已在目标态而 metadata 仍是旧态(本事务不可能产生), 不自动处理(请人工核对): $cur_path"
            failed=1
            continue
        fi

        # (c) 收敛到目标态: 必要时先改文件名(Reality 的 tag 改名), 再原子写内容
        if [ "$committed" = 1 ]; then tgt_path="$new_path"; tgt_obj=".new"; else tgt_path="$old_path"; tgt_obj=".old"; fi
        if [ "$cur_path" != "$tgt_path" ]; then
            # 目标路径已存在非正常重命名残局；保留现场避免覆盖其它节点。
            if [ -e "$tgt_path" ]; then
                _warn "端口事务恢复的目标文件已存在(疑似外部重建), 不覆盖, 保留 journal 待人工核对: $tgt_path"
                failed=1
                continue
            fi
            # mv -n: 即便在"检查"与"改名"之间被塞进目标文件也不覆盖(-n 不可用时报错 ⇒ 走失败
            # 分支保留 journal, 仍不丢数据)。改名后源路径消失, 故下面统一对 tgt_path 写内容。
            if ! mv -n "$cur_path" "$tgt_path" 2>/dev/null; then
                _warn "端口事务恢复的元数据重命名失败, 保留 journal: $j"
                failed=1
                continue
            fi
            # mv -n 在"目标已存在"时可能静默不动作却返回 0 ⇒ 事后核验源路径确实消失,
            # 否则视为未生效(有竞态插入), 保留 journal 而不是继续写目标文件
            if [ -e "$cur_path" ]; then
                _warn "端口事务恢复的元数据重命名未生效(目标已存在?), 不覆盖, 保留 journal: $tgt_path"
                failed=1
                continue
            fi
        fi
        if ! _atomic_write_json "$tgt_path" "$(jq "$tgt_obj" "$j" 2>/dev/null)"; then
            _warn "端口事务恢复的元数据写回失败, 保留 journal: $j"
            failed=1
            continue
        fi

        # (d) hy2hop 回滚分支: DNAT 已被改到新端口, 必须一并 retarget 回旧端口
        if [ "$kind" = "hy2hop" ] && [ "$committed" = 0 ] && [ -n "$ranges" ]; then
            if ! _hy2_hop_available; then
                _warn "端口跳跃规则需 iptables 修复, 保留 journal 待下次启动: $j"
                failed=1
                continue
            fi
            # shellcheck disable=SC2086
            if ! _hy2_hop_retarget "$newport" "$oldport" $ranges; then
                _warn "端口跳跃规则回滚失败, 保留 journal: $j"
                failed=1
                continue
            fi
        fi

        rm -f "$j"
        if [ "$committed" = 1 ]; then
            _info "已补完上次中断的端口修改: ${tgt_path##*/} (端口 ${newport})"
        else
            _info "已回滚上次中断的端口修改: ${tgt_path##*/} (config 未提交该事务)"
        fi
    done
    [ "$failed" -eq 0 ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 修改端口(沿用思路, 适配新元数据)
# ---------------------------------------------------------------------------
_modify_port() {
    clear
    local count; count=$(_node_count)
    [ "$count" -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【修改端口】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local tag name port
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); port=$(jq -r '.port' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 当前端口 %s\n" "$i" "$name" "$port"
        i=$((i+1))
    done
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择: " choice
    [ "$choice" = "0" ] && return
    local idx
    idx=$(_xd_index_from_choice "$choice" "${#tags[@]}") || { _warn "无效选择"; _press_any_key; return; }
    local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local newport=$(_input_port)

    # 更新元数据 + 链接(端口出现在链接里)
    local meta="$NODES_DIR/${tag}.json"
    local oldport; oldport=$(jq -r '.port' "$meta")
    local proto; proto=$(jq -r '.protocol' "$meta" 2>/dev/null)

    # 端口未变化时直接返回, 避免无意义重启; 也防止 Reality 分支对同名元数据文件 mv(同文件错误)
    [ "$newport" = "$oldport" ] && { _info "端口未变化"; _press_any_key; return; }

    # hy2+hop改端口只走 _hy2_port_txn；避免config与DNAT分步提交漂移。
    if [ "$proto" = "hysteria2" ]; then
        # 与删除语义一致——hop metadata 存在但无法解析时 fail-closed, 不能把
        # "损坏"当成"没有 hop"走普通 _mutate_config 改监听端口(否则旧 DNAT 残留, hop 失效)
        if ! _hy2_hop_meta_ok "$tag"; then
            _error "节点 hop 元数据损坏, 无法安全修改端口: $tag"
            _press_any_key; return 1
        fi
        local ranges
        ranges=$(_read_hop_ranges "$meta")
        if [ -n "$ranges" ]; then
            if ! command -v iptables >/dev/null 2>&1; then
                _error "节点已启用端口跳跃, 但 iptables 不可用, 无法安全修改端口: $tag"
                _tip "已持久化的 DNAT 仍指向旧端口 ${oldport}; 请安装 iptables 后重试"
                _press_any_key; return 1
            fi
            # shellcheck disable=SC2086
            if _modify_port_hop "$tag" "$meta" "$oldport" "$newport" $ranges; then
                _success "端口已改为 ${newport}(含端口跳跃规则)"
            else
                _warn "端口修改未完成"
            fi
            _press_any_key
            return
        fi
    fi

    # Reality改端口同步tag/tunnel/routing；关联歧义拒绝而非降级普通端口路径。
    if [ "$proto" = "vless-tcp-reality-vision" ] || [ "$proto" = "vless-xhttp-reality" ]; then
        if ! _reality_port_txn "$tag" "$meta" "$oldport" "$newport"; then
            _press_any_key; return 1
        fi
        _press_any_key
        return
    fi

    # 非hop走 _port_txn；锁内重读metadata避免覆盖并发字段更新。
    local old_name new_name newmeta tmpm newlink rebuild_rc=0
    old_name=$(jq -r '.name' "$meta")
    # 仅替换 "-<oldport>" 后缀, 全局子串替换会破坏名称中含端口号的其他数字
    new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")

    if [ "$proto" = "hysteria2" ]; then
        # Hy2派生只走 _hy2_sync_derived；不能独立拼链接丢失不可表达语义。
        newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport") || {
            _error "生成新元数据失败(元数据缺少必要字段), 端口未修改"
            _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
            _press_any_key; return 1
        }
        if ! _port_txn "$tag" "$meta" "$newport" "$newmeta" "$oldport"; then
            _press_any_key; return 1
        fi
        # 链接已随 metadata 一次提交; 这里补 clash 派生缓存(传 old_name: 改名后必须删掉旧名
        # 条目, 否则 clash.yaml 残留指向旧端口的幽灵条目)
        _hy2_sync_derived "$meta" "$old_name" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
        _success "端口已改为 ${newport}"
        _press_any_key
        return 0
    fi

    # 非 hy2: 同样在内存生成完整新 metadata, 从"承载新端口 + 新名称"的临时文件重建分享链接
    # (链接的 #fragment 取 .name, 与 Reality 分支 / hy2 分支同源), 未落地任何真实文件。
    tmpm=$(mktemp "${meta}.port.XXXXXX") || { _error "创建临时文件失败"; _press_any_key; return 1; }
    if ! jq --argjson p "$newport" --arg n "$new_name" '.port=$p | .name=$n' "$meta" > "$tmpm"; then
        rm -f "$tmpm"; _error "生成元数据失败"; _press_any_key; return 1
    fi
    case "$proto" in
        vless-tcp-reality-vision|vless-xhttp-reality) newlink=$(_rebuild_reality_link "$tmpm") || rebuild_rc=1 ;;
        vless-enc) newlink=$(_rebuild_vless_enc_link "$tmpm") || rebuild_rc=1 ;;
        vless-xhttp-cdn|vless-ws-cdn) newlink=$(_rebuild_cdn_link "$tmpm") || rebuild_rc=1 ;;
        *)
            # 其它协议用@后host:port锚定替换；path/sni/name里的端口不改。
            local oldlink; oldlink=$(jq -r '.share_link' "$meta" 2>/dev/null)
            newlink=$(_rewrite_link_port "$oldlink" "$oldport" "$newport")
            [ -n "$newlink" ] || rebuild_rc=1
            ;;
    esac

    # 重建失败或结果为空(被采纳节点缺字段) -> 保留原 share_link, 只报告; 端口与
    # 名称照常提交 —— 事务尚未开始, 不会出现"config 已改而链接没跟上"的中间态。
    if [ "$rebuild_rc" -ne 0 ] || [ -z "$newlink" ]; then
        _warn "分享链接重建失败(元数据缺少必要字段), 分享链接保持旧值"
        _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
        newmeta=$(cat "$tmpm" 2>/dev/null) || newmeta=""
    else
        newmeta=$(jq --arg l "$newlink" '.share_link=$l' "$tmpm") || newmeta=""
    fi
    rm -f "$tmpm"
    [ -n "$newmeta" ] || { _error "生成元数据失败"; _press_any_key; return 1; }

    if ! _port_txn "$tag" "$meta" "$newport" "$newmeta" "$oldport"; then
        _press_any_key; return 1
    fi
    # config/metadata 已一致, 同步 clash 派生缓存(端口与名称都可能已变)
    _sync_node_clash "$meta" "$old_name" || \
        _tip "clash 派生缓存未同步(节点本体已生效), 可在 [查看节点] 里核对 ${CLASH_YAML}"
    _success "端口已改为 ${newport}"
    _press_any_key
}

# ---------------------------------------------------------------------------
_update_listen_commit() {
    _with_config_lock _with_config_write_barrier _update_listen_commit_locked "$@"
}

_update_listen_commit_locked() {
    local tag="$1" expected="$2" newlisten="$3" newaddr="$4" newlink="$5"
    local meta="$NODES_DIR/${tag}.json" now old_inbound oldlisten had_listen
    now=$(_node_identity "$tag") || { _error "无法重新读取节点身份, 监听未更新: $tag"; return 1; }
    if [ "$now" != "$expected" ]; then
        _error "节点内容已变化, 请重新选择监听地址: $tag"
        return 1
    fi
    old_inbound=$(_config_jq -c --arg t "$tag" '[.inbounds[]? | select(.tag == $t)]' 2>/dev/null) || return 1
    [ "$(jq -r 'length' <<< "$old_inbound" 2>/dev/null)" = 1 ] || {
        _error "config 中的节点已变化, 监听未更新: $tag"
        return 1
    }
    had_listen=$(jq -r '.[0] | has("listen")' <<< "$old_inbound")
    oldlisten=$(jq -c '.[0].listen' <<< "$old_inbound")
    if ! _mutate_config --arg t "$tag" --arg l "$newlisten" \
         '(.inbounds[] | select(.tag == $t) | .listen) = $l'; then
        _error "监听修改失败, 已回滚"
        return 1
    fi
    if [ -n "$newlink" ]; then
        if _meta_update "$meta" '.listen=$l | .link_addr=$a
            | (if has("preferred_addr") then .preferred_addr=$a else . end)
            | .share_link=$link' \
            --arg l "$newlisten" --arg a "$newaddr" --arg link "$newlink"; then
            return 0
        fi
    else
        if _meta_update "$meta" '.listen=$l | .link_addr=$a
            | (if has("preferred_addr") then .preferred_addr=$a else . end)' \
            --arg l "$newlisten" --arg a "$newaddr"; then
            return 0
        fi
    fi
    _error "监听元数据写入失败, 正在恢复 config 监听..."
    if ! _mutate_config --arg t "$tag" --argjson old "$oldlisten" --argjson had "$had_listen" \
        '(.inbounds[] | select(.tag == $t)) |= (if $had then .listen=$old else del(.listen) end)'; then
        _error "config 监听回滚失败, 请手动检查节点与 metadata"
    fi
    return 1
}


# 更新监听(单节点 )
# ---------------------------------------------------------------------------
_update_listen() {
    clear
    local count; count=$(_node_count)
    [ "$count" -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【更新监听 — 单节点】${NC}"
    echo -e "  ${YELLOW}仅修改所选节点的 listen, 其他节点不变${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local tag name port listen
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        port=$(jq -r '.port' "$f"); listen=$(jq -r '.listen' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 端口 %-7s 当前监听 %s\n" "$i" "$name" "$port" "$listen"
        i=$((i+1))
    done
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择: " choice
    [ "$choice" = "0" ] && return
    local idx
    idx=$(_xd_index_from_choice "$choice" "${#tags[@]}") || { _warn "无效选择"; _press_any_key; return; }
    local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local listen_identity
    listen_identity=$(_node_identity "$tag") || { _error "无法读取节点身份, 监听未更新"; _press_any_key; return 1; }
    local curlisten; curlisten=$(jq -r '.listen' "$meta")
    echo -e "  当前监听: ${CYAN}${curlisten}${NC}"
    echo -e "  可选: :: (双栈默认) / 0.0.0.0 / 127.0.0.1 (回环, 供 cloudflared/中转回源) / ::1 / 具体 IP"
    local newlisten
    read -rp "  新监听地址: " newlisten
    if ! _validate_listen "$newlisten"; then
        _warn "监听地址不合法"; _press_any_key; return
    fi

    # 联动链接服务器地址(确认 A); 所有提示与验证必须先于 config 提交。

    local proto oldaddr newaddr
    proto=$(jq -r '.protocol' "$meta")
    oldaddr=$(jq -r '.link_addr' "$meta")
    # CDN 协议强制填域名(CDN 节点填公网 IP 会导致直连失效)
    case "$proto" in *-cdn)
        echo -e "  ${YELLOW}该节点为 CDN 协议, 必须使用 CDN 域名${NC}"
        echo -e "  当前链接服务器地址: ${oldaddr}"
        read -rp "  请输入 CDN 域名: " newaddr
        # CDN只接受域名；复用 _validate_domain，避免IPv4被当作域名。
        _validate_domain "$newaddr" || { _warn "CDN 节点须填域名, 而非 IP"; _press_any_key; return; }
        ;;
    *)
        if _is_listen_loopback "$newlisten"; then
            echo -e "  ${YELLOW}监听已改为回环, 该节点仅本机可达(适合 cloudflared 回源)${NC}"
            echo -e "  当前链接服务器地址: ${oldaddr}"
            read -rp "  请输入新的链接服务器地址(CDN 域名): " newaddr
        else
            echo -e "  监听已改为全监听(${newlisten}), 该节点对外可达"
            local pubip; pubip=$(_get_public_ip)
            read -rp "  请输入链接服务器地址(公网 IP/域名, 默认 ${pubip}): " newaddr
            newaddr=${newaddr:-$pubip}
        fi
        ;;
    esac
    [ -z "$newaddr" ] && newaddr="$oldaddr"

    # 地址改写统一 _rewrite_link_addr；URI和Clash派生同步，失败保持权威状态。
    local oldlink newlink
    oldlink=$(jq -r '.share_link' "$meta" 2>/dev/null)
    newlink=$(_rewrite_link_addr "$oldlink" "$newaddr")
    if [ -z "$newlink" ]; then
        _warn "分享链接非标准格式(被采纳节点?), 仅更新监听与链接地址记录"
    fi
    if ! _update_listen_commit "$tag" "$listen_identity" "$newlisten" "$newaddr" "$newlink"; then
        _press_any_key
        return 1
    fi
    # 监听/链接地址变化需同步 clash 条目的 server 字段(失败只提示, 不回滚权威状态)
    _sync_node_clash "$meta" || \
        _tip "clash 派生缓存未同步(节点本体已生效), 可在 [查看节点] 里核对 ${CLASH_YAML}"

    _success "监听已更新为 ${newlisten}, 链接地址更新为 ${newaddr}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# clash.yaml 输出辅助(纯文本追加, 不用 jq —— jq 不能解析 yaml)
# 用法:_add_node_to_yaml <yaml_node_line>   (传入的是一行 yaml 节点: - {name: ...})
# ---------------------------------------------------------------------------
CLASH_YAML="$DEPLOY_DIR/clash.yaml"

_add_node_to_yaml() {
    local line="$1" name="$2"
    mkdir -p "$DEPLOY_DIR" || return 1
    if [ ! -f "$CLASH_YAML" ]; then
        printf 'proxies:\n' > "$CLASH_YAML" || return 1
    fi
    # name 由调用方显式传入, 不再从整行反解析 — 避免 YAML 转义/特殊字符
    # 导致的"解析 name != 实际 name"(name 已是唯一性约束下的稳定身份)
    if [ -n "$name" ]; then
        _remove_node_from_yaml_by_name "$name" 2>/dev/null || \
            _warn "Clash YAML 去重删除旧同名条目失败(${name}), 继续追加"
    fi
    if ! printf '  %s\n' "$line" >> "$CLASH_YAML"; then
        _warn "Clash YAML 追加失败(节点已创建), 可手工编辑 ${CLASH_YAML} 补齐该行"
        return 1
    fi
    return 0
}

_remove_node_from_yaml_by_name() {
    local name="$1"
    [ -f "$CLASH_YAML" ] || return 0
    local tmp grc=0
    # mktemp 失败显式报错
    if ! tmp=$(mktemp); then
        _error "无法创建临时 Clash YAML 文件"
        return 1
    fi
    # Clash name固定字符串带闭合引号匹配；避免子串/正则误删。
    local key; key=$(_yaml_dq "$name")
    grep -vF "name: \"${key}\"" "$CLASH_YAML" > "$tmp" 2>/dev/null
    grc=$?
    # grep rc: 0=有选中行(已写入) 1=无选中行(节点不在, 合法) 2=读取/写入错误
    if [ "$grc" -ge 2 ]; then
        rm -f "$tmp"
        _error "Clash YAML 读取/过滤失败(grep rc=$grc)"
        return 1
    fi
    # 过滤结果为空(最后一个节点被删)时保留 proxies: 头, 避免 YAML 变成空文件
    if [ ! -s "$tmp" ]; then
        if ! printf 'proxies:\n' > "$tmp"; then
            rm -f "$tmp"
            _error "Clash YAML 写入失败"
            return 1
        fi
    fi
    if ! mv -f "$tmp" "$CLASH_YAML"; then
        rm -f "$tmp"
        _error "Clash YAML 替换失败"
        return 1
    fi
    return 0
}

_remove_node_from_yaml_by_tag() {
    local tag="$1" name
    name=$(jq -r '.name' "$NODES_DIR/${tag}.json" 2>/dev/null)
    # 读不到 name(如 json 已被删/损坏)视为删除失败, 由调用方决定取消或显式告警
    [ -z "$name" ] && return 1
    _remove_node_from_yaml_by_name "$name"
}

# 按精确name原位替换Clash条目；不存在则追加，避免更新生成重复代理。
_replace_node_in_yaml() {
    local line="$1" name="$2"
    [ -f "$CLASH_YAML" ] || return 0
    local key tmp
    key=$(_yaml_dq "$name")
    if ! tmp=$(mktemp); then
        _error "无法创建临时 Clash YAML 文件"
        return 1
    fi
    local replaced=0 l
    # || [ -n "$l" ]: read 在 EOF 且末行无结尾换行时返回 1 但 $l 已含该行内容,
    # 缺此守卫会把最后一行留在循环外 —— 替换中间条目时会随 mv 静默丢掉它
    while IFS= read -r l || [ -n "$l" ]; do
        if [ "$replaced" = 0 ] && printf '%s' "$l" | grep -qF "name: \"${key}\""; then
            printf '  %s\n' "$line" >> "$tmp"
            replaced=1
        else
            printf '%s\n' "$l" >> "$tmp"
        fi
    done < "$CLASH_YAML"
    if [ "$replaced" = 0 ]; then
        rm -f "$tmp"
        _warn "Clash YAML 未找到节点 [${name}] 条目, 跳过替换"
        return 0
    fi
    if ! mv -f "$tmp" "$CLASH_YAML"; then
        rm -f "$tmp"
        _error "Clash YAML 替换失败"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Hysteria2 端口跳跃管理 (iptables DNAT)
# ---------------------------------------------------------------------------

# 启用/禁用端口跳跃 (iptables DNAT + 分享链接 mport)
_hy2_toggle_hop() {
    clear
    _has_hy2_nodes || { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    _ensure_iptables || { _press_any_key; return; }

    echo; echo -e "  ${CYAN}【端口跳跃 — 启用/禁用】${NC}"
    echo -e "  ${YELLOW}iptables DNAT 将 UDP 端口范围转发到 Hysteria2 监听端口${NC}"
    echo -e "  ${YELLOW}客户端可连接范围内任意端口, 提高抗封锁能力${NC}"
    echo
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local tag name port ranges_display
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); port=$(jq -r '.port' "$f")
        ranges_display=$(_read_hop_ranges_display "$f")
        tags+=("$tag")
        if [ -n "$ranges_display" ]; then
            printf "  ${GREEN}[%d]${NC} %-20s 端口 %-7s 跳跃: ${GREEN}%s${NC}\n" "$i" "$name" "$port" "$ranges_display"
        else
            printf "  ${GREEN}[%d]${NC} %-20s 端口 %-7s 跳跃: ${RED}未启用${NC}\n" "$i" "$name" "$port"
        fi
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    local idx
    idx=$(_xd_index_from_choice "$choice" "${#tags[@]}") || { _warn "无效选择"; _press_any_key; return; }
    local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local port; port=$(jq -r '.port' "$meta")
    local cur_ranges
    cur_ranges=$(_read_hop_ranges "$meta")
    local cur_display
    cur_display=$(_read_hop_ranges_display "$meta")

    if [ -n "$cur_ranges" ]; then
        # 已启用 → 禁用
        echo -e "  当前端口跳跃: ${GREEN}${cur_display}${NC} → ${port}"
        read -rp "  确认禁用端口跳跃? [y/N]: " ans
        case "$ans" in
            y|Y)
                # 事务: 生成新 metadata(删 hop 字段, 链接不再含 &mport=) ->
                # runtime remove -> 原子持久化 -> 原子提交 metadata; 任一步失败回滚, 不永久分叉
                local hopmeta newmeta
                hopmeta=$(jq 'del(.hop_ranges) | del(.hop_start) | del(.hop_end) | del(.udp_hop_ports)' "$meta") || { _error "生成元数据失败"; _press_any_key; return; }
                newmeta=$(_hy2_gen_newmeta "$meta" "$hopmeta") || { _error "重建分享链接失败"; _press_any_key; return; }
                # shellcheck disable=SC2086
                if ! _hy2_hop_txn remove "$meta" "$newmeta" "$port" $cur_ranges; then
                    _error "端口跳跃禁用失败, 已回滚(iptables/metadata 保持一致)"
                    _press_any_key; return
                fi
                _success "端口跳跃已禁用"
                # 派生状态(链接 + clash)走唯一入口(去掉 mport / ports)
                _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
                ;;
            *) _info "已取消" ;;
        esac
    else
        # 未启用 → 设置端口范围
        echo -e "  当前 Hysteria2 端口: ${CYAN}${port}${NC}"
        echo -e "  ${YELLOW}端口范围格式:${NC}"
        echo -e "    单个端口:     ${CYAN}3050${NC}"
        echo -e "    连续范围:     ${CYAN}20000-50000${NC}"
        echo -e "    混合(逗号分隔): ${CYAN}11,13,15-17${NC}"
        echo
        local hop_input
        read -rp "  端口范围: " hop_input
        [ -z "$hop_input" ] && { _info "已取消"; _press_any_key; return; }
        # 解析并验证
        local parsed
        parsed=$(_parse_hop_ranges "$hop_input") || { _press_any_key; return; }
        # 规范化输入(用于存储和显示)
        local normalized=""
        local range
        for range in $parsed; do
            local rs re
            rs=$(echo "$range" | cut -d: -f1)
            re=$(echo "$range" | cut -d: -f2)
            if [ "$rs" = "$re" ]; then
                normalized="${normalized:+$normalized,}$rs"
            else
                normalized="${normalized:+$normalized,}$rs-$re"
            fi
        done
        # 事务: 生成新 metadata(hop 字段 + 含 &mport= 的分享链接) ->
        # runtime add -> 原子持久化 -> 原子提交 metadata; 任一步失败回滚, 不永久分叉
        local hopmeta newmeta
        hopmeta=$(jq --arg r "$normalized" \
                   '.hop_ranges=$r | .udp_hop_ports=$r | del(.hop_start) | del(.hop_end)' "$meta") || { _error "生成元数据失败"; _press_any_key; return; }
        newmeta=$(_hy2_gen_newmeta "$meta" "$hopmeta") || { _error "重建分享链接失败"; _press_any_key; return; }
        # shellcheck disable=SC2086
        if ! _hy2_hop_txn add "$meta" "$newmeta" "$port" $parsed; then
            _error "iptables 规则添加失败或已回滚, 请检查内核是否支持 nat 模块"
            _press_any_key; return
        fi
        _success "端口跳跃已启用: ${normalized} → ${port}"
        # 派生状态(链接 + clash)走唯一入口(加入 mport / ports)
        _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
        _tip "iptables DNAT 已生效, 客户端可连接范围内任意端口"
        _tip "请确保防火墙/安全组已放行该 UDP 端口范围"
    fi
    _press_any_key
}

# 查看端口跳跃状态
_hy2_view_hop() {
    clear
    echo; echo -e "  ${CYAN}【端口跳跃状态】${NC}"
    echo
    local found=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local name port ranges_display
        name=$(jq -r '.name' "$f"); port=$(jq -r '.port' "$f")
        ranges_display=$(_read_hop_ranges_display "$f")
        if [ -n "$ranges_display" ]; then
            echo -e "  ${GREEN}●${NC} ${name}: ${CYAN}${ranges_display}${NC} → ${port} (UDP)"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无启用端口跳跃的节点${NC}"
    fi
    echo
    if command -v iptables >/dev/null 2>&1; then
        local rules
        rules=$(_hy2_list_all_hop_rules)
        if [ -n "$rules" ]; then
            echo -e "  ${CYAN}iptables nat 规则:${NC}"
            echo "$rules" | while read -r line; do
                echo -e "  ${GREEN}▸${NC} $line"
            done
        fi
    fi
    _press_any_key
}
