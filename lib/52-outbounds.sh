#!/usr/bin/env bash

# 出口分享链接导入：解析协议/传输/TLS/Reality/FinalMask，只追加 outbounds。
# 结构以目标 Xray 版本为准：allowInsecure 已移除；Reality 用 spiderX/mldsa65Verify；
# Hysteria 认证在 hysteriaSettings.auth，端口跳跃/混淆/brutal 在 finalmask。

_OB_SUPPORTED_TEXT='Hysteria2/Hy2、VLESS、VMess、Trojan、Shadowsocks、SOCKS'
_OB_MAX_TAG_LENGTH=128

_OB_ERR=''
_OB_LINKS=()
_OB_INPUTS=()
_OB_PREFETCH=''
_OB_PREFETCH_SET=false
_OB_BATCH='[]'
_OB_COUNT=0
_OB_SKIPPED=0
_OB_DEFAULT_TAGS=()
_OB_PROTOCOLS=()
_OB_SERVERS=()
_OB_PORTS=()
_OB_ACCEPTED_TAGS=()

_OB_TAG=''
_OB_PROTOCOL=''
_OB_SERVER=''
_OB_PORT=0
_OB_OUTBOUND=''
_OB_STREAM_JSON=''
_OB_NETWORK=''
_OB_TRANSPORT_JSON=''
_OB_SECURITY_JSON='{}'
_OB_SECURITY_SNI=''
_OB_SNI_VALUE=''
_OB_ALPN_JSON=''
_OB_FP_VALUE=''
_OB_PIN_VALUE=''
_OB_VCN_VALUE=''
_OB_ECH_VALUE=''
_OB_PBK_VALUE=''
_OB_SID_VALUE=''
_OB_SPX_VALUE=''
_OB_PQV_VALUE=''
_OB_QUIC_JSON=''
_OB_DECODED=''
_OB_B64_PADDED=''
_OB_QVALUE=''
_OB_OPT_VALUE=''
_OB_PARAM_VALUE=''
_OB_INT_VALUE=0
_OB_BOOL_VALUE=0
_OB_JSON_VALUE=''
_OB_JSON_ALIAS_VALUE=''
_OB_HP_HOST=''
_OB_HP_PORT=''
_OB_SCHEME=''
_OB_FRAGMENT=''
_OB_RAW_QUERY=''
_OB_USERINFO=''
_OB_AUTHORITY=''
_OB_HOSTPORT=''
_OB_PATH=''
_OB_QUERY=''
_OB_DUP_KEYS=''
_OB_PATH_VALUE=''
_OB_UUID_VALUE=''
_OB_CIPHER_VALUE=''
_OB_PORTS_VALUE=''
_OB_MPORT_VALUE=''
_OB_BW_VALUE=''
_OB_TAG_INPUT=''

_OB_LINK_SCHEME_RE='(hysteria2|hy2|anytls|vless|vmess|trojan-go|trojan|ssr|ss|socks5?|tuic|hysteria|shadowtls|naive\+https|https?)://'

_outbound_fail() {
    _OB_ERR="$*"
    return 1
}

# ---------------------------------------------------------------------------
# 编码与基础校验
# ---------------------------------------------------------------------------

# 百分号解码按字节处理；plus 为 plus 时把 "+" 当空格(表单式查询参数)。
_outbound_percent_decode() {
    local raw="$1" plus="${2:-}" out='' ch hex
    while [ -n "$raw" ]; do
        case "$raw" in
            %*)
                hex="${raw:1:2}"
                [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || { _outbound_fail "百分号编码无效"; return 1; }
                [ "$hex" = "00" ] && { _outbound_fail "编码内容包含 NUL"; return 1; }
                printf -v ch '%b' "\\x${hex}"
                out+="$ch"
                raw="${raw:3}"
                ;;
            +*)
                if [ "$plus" = plus ]; then out+=' '; else out+='+'; fi
                raw="${raw:1}"
                ;;
            *)
                out+="${raw:0:1}"
                raw="${raw:1}"
                ;;
        esac
    done
    if printf '%s' "$out" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "内容包含控制字符"
        return 1
    fi
    _OB_DECODED="$out"
}

# 只做 Base64 规范化，输出到全局 _OB_B64_PADDED；调用方必须在当前 shell 调用。
_outbound_base64_normalize() {
    local raw="$1" s pad padded=''
    [ -n "$raw" ] || return 1
    case "$raw" in *[[:space:]]*) return 1 ;; esac
    s="${raw//-/+}"
    s="${s//_/\/}"
    [[ "$s" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
    s="${s%%=*}"
    [ -n "$s" ] || return 1
    [ $(( ${#s} % 4 )) -ne 1 ] || return 1
    pad=$(( (4 - ${#s} % 4) % 4 ))
    padded="$s"
    while [ "$pad" -gt 0 ]; do padded+='='; pad=$((pad - 1)); done
    _OB_B64_PADDED="$padded"
}

_outbound_base64_decode() {
    _outbound_base64_normalize "$1" || return 1
    printf '%s' "$_OB_B64_PADDED" | base64 -d 2>/dev/null
}

_outbound_base64_byte_len() {   # <padded> <expected>
    local len
    len=$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c) || return 1
    len="${len//[[:space:]]/}"
    [ "$len" = "$2" ]
}

_outbound_valid_ipv4() {
    local h="$1" o
    [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ "${#o}" -le 3 ] || return 1
        case "$o" in
            0|[1-9]*) ;;
            *) return 1 ;;
        esac
        [ $((10#$o)) -le 255 ] || return 1
    done
}

_outbound_validate_host() {
    local h="$1" label="${2:-服务器地址}" part
    [ -n "$h" ] || { _outbound_fail "${label}不能为空"; return 1; }
    case "$h" in *[[:space:]/?#@\[\]]*) _outbound_fail "${label}格式无效"; return 1 ;; esac
    if [[ "$h" == *:* ]]; then
        _is_ipv6_literal "$h" || { _outbound_fail "${label}不是有效 IPv6"; return 1; }
        return 0
    fi
    if [[ "$h" =~ ^[0-9.]+$ ]]; then
        _outbound_valid_ipv4 "$h" || { _outbound_fail "${label}不是有效 IPv4"; return 1; }
        return 0
    fi
    [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || { _outbound_fail "${label}格式无效"; return 1; }
    h="${h%.}"
    [ -n "$h" ] && [ "${#h}" -le 253 ] || { _outbound_fail "${label}格式无效"; return 1; }
    local IFS='.'
    for part in $h; do
        [ -n "$part" ] && [ "${#part}" -le 63 ] || { _outbound_fail "${label}格式无效"; return 1; }
        [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || {
            _outbound_fail "${label}格式无效"
            return 1
        }
    done
}

_outbound_validate_port() {
    local p="$1" label="${2:-端口}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || { _outbound_fail "${label}必须是十进制整数"; return 1; }
    n=$((10#$p))
    [ "$n" -ge 1 ] && [ "$n" -le 65535 ] || { _outbound_fail "${label}须在 1-65535"; return 1; }
    _OB_PORT_VALUE="$n"
}

_outbound_uuid_value() {
    local v="$1"
    if [[ "$v" =~ ^[0-9A-Fa-f]{32}$ ]]; then
        v="${v:0:8}-${v:8:4}-${v:12:4}-${v:16:4}-${v:20:12}"
    fi
    [[ "$v" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        _outbound_fail "UUID 格式无效"
        return 1
    }
    _OB_UUID_VALUE="${v,,}"
}

_outbound_validate_path() {
    local p="$1" label="${2:-path}"
    [ -n "$p" ] || { _OB_PATH_VALUE=''; return 0; }
    case "$p" in *[[:space:]]*) _outbound_fail "${label}不能包含空白"; return 1 ;; esac
    if printf '%s' "$p" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "${label}包含控制字符"
        return 1
    fi
    case "$p" in /*) ;; *) p="/$p" ;; esac
    _OB_PATH_VALUE="$p"
}

# ---------------------------------------------------------------------------
# URL 与查询参数
# ---------------------------------------------------------------------------

_outbound_split_url() {
    local link="$1" rest
    _OB_SCHEME=''
    _OB_FRAGMENT=''
    _OB_RAW_QUERY=''
    _OB_USERINFO=''
    _OB_AUTHORITY=''
    _OB_HOSTPORT=''
    _OB_PATH=''
    case "$link" in
        *'://'*) ;;
        *) _outbound_fail "分享链接缺少协议前缀"; return 1 ;;
    esac
    _OB_SCHEME="${link%%://*}"
    _OB_SCHEME="${_OB_SCHEME,,}"
    rest="${link#*://}"
    case "$rest" in *'#'*) _OB_FRAGMENT="${rest#*#}"; rest="${rest%%#*}" ;; esac
    case "$rest" in *'?'*) _OB_RAW_QUERY="${rest#*\?}"; rest="${rest%%\?*}" ;; esac
    case "$rest" in
        */*) _OB_AUTHORITY="${rest%%/*}"; _OB_PATH="/${rest#*/}" ;;
        *) _OB_AUTHORITY="$rest" ;;
    esac
    case "$_OB_AUTHORITY" in
        *@*) _OB_USERINFO="${_OB_AUTHORITY%@*}"; _OB_HOSTPORT="${_OB_AUTHORITY##*@}" ;;
        *) _OB_HOSTPORT="$_OB_AUTHORITY" ;;
    esac
    [ -n "$_OB_HOSTPORT" ] || { _outbound_fail "链接缺少服务器地址"; return 1; }
}

_outbound_parse_hostport() {
    local hp="$1" host port
    [ -n "$hp" ] || { _outbound_fail "链接缺少服务器地址"; return 1; }
    if [[ "$hp" == \[* ]]; then
        [[ "$hp" =~ ^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$ ]] || {
            _outbound_fail "IPv6 地址格式无效"
            return 1
        }
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
    else
        case "$hp" in
            *:*) host="${hp%:*}"; port="${hp##*:}" ;;
            *) host="$hp"; port='' ;;
        esac
        if [[ "$host" == *:* ]]; then
            _outbound_fail "IPv6 地址需用 [] 包裹"
            return 1
        fi
    fi
    _outbound_validate_host "$host" || return 1
    _OB_HP_HOST="$host"
    _OB_HP_PORT="$port"
}

_outbound_parse_query() {
    local raw="$1" part key val
    _OB_QUERY=''
    _OB_DUP_KEYS=''
    [ -z "$raw" ] && return 0
    while :; do
        part="${raw%%&*}"
        [ -n "$part" ] || { _outbound_fail "查询字符串包含空参数"; return 1; }
        key="${part%%=*}"
        if [ "$key" = "$part" ]; then val=''; else val="${part#*=}"; fi
        _outbound_percent_decode "$key" plus || return 1
        key="${_OB_DECODED,,}"
        [[ "$key" =~ ^[a-z0-9_.-]+$ ]] || { _outbound_fail "查询参数名无效"; return 1; }
        case $'\n'"$_OB_DUP_KEYS" in
            *$'\n'"$key"$'\n'*) _outbound_fail "查询参数重复: $key"; return 1 ;;
        esac
        _OB_DUP_KEYS+="$key"$'\n'
        _outbound_percent_decode "$val" plus || return 1
        val="$_OB_DECODED"
        [ -n "$val" ] && _OB_QUERY+="$key"$'\t'"$val"$'\n'
        [ "$raw" = "$part" ] && break
        raw="${raw#*&}"
    done
    return 0
}

_outbound_q_get() {
    local want="$1" k v
    _OB_QVALUE=''
    while IFS=$'\t' read -r k v; do
        if [ "$k" = "$want" ]; then
            _OB_QVALUE="$v"
            return 0
        fi
    done <<< "$_OB_QUERY"
    return 1
}

_outbound_get_opt() {
    _OB_OPT_VALUE=''
    _outbound_q_get "$1" || return 1
    _OB_OPT_VALUE="$_OB_QVALUE"
}

_outbound_any_query() {
    local name
    for name in "$@"; do
        if _outbound_q_get "$name"; then return 0; fi
    done
    return 1
}

_outbound_alias_get() {
    local label="$1" name v found='' set=0
    shift
    for name in "$@"; do
        if _outbound_q_get "$name"; then
            v="$_OB_QVALUE"
            if [ "$set" -eq 1 ] && [ "$v" != "$found" ]; then
                _outbound_fail "${label}参数冲突"
                return 2
            fi
            found="$v"
            set=1
        fi
    done
    [ "$set" -eq 1 ] || return 1
    _OB_PARAM_VALUE="$found"
    return 0
}

_outbound_bool_get() {
    local label="$1" rc value
    shift
    _outbound_alias_get "$label" "$@"
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -ne 0 ] && return 2
    value="${_OB_PARAM_VALUE,,}"
    case "$value" in
        1|true|yes|on) _OB_BOOL_VALUE=1 ;;
        0|false|no|off) _OB_BOOL_VALUE=0 ;;
        *) _outbound_fail "${label}只能为 0/1/true/false"; return 2 ;;
    esac
    return 0
}

_outbound_int_get() {
    local label="$1" min="$2" max="$3" rc value
    shift 3
    _outbound_alias_get "$label" "$@"
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -ne 0 ] && return 2
    value="$_OB_PARAM_VALUE"
    [[ "$value" =~ ^[0-9]{1,9}$ ]] || { _outbound_fail "${label}必须是十进制整数"; return 2; }
    value=$((10#$value))
    [ "$value" -ge "$min" ] && [ "$value" -le "$max" ] || {
        _outbound_fail "${label}须在 ${min}-${max}"
        return 2
    }
    _OB_INT_VALUE="$value"
}

_outbound_check_query() {
    local allowed=" $* " k v
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        case "$allowed" in
            *" $k "*) ;;
            *) _outbound_fail "链接包含暂不支持的参数: $k"; return 1 ;;
        esac
    done <<< "$_OB_QUERY"
}

_outbound_set_tag_from_fragment() {
    local raw="$1" fallback="${2:-}"
    _OB_TAG=''
    if [ -n "$raw" ]; then
        _outbound_percent_decode "$raw" || return 1
        _OB_TAG="$_OB_DECODED"
    elif [ -n "$fallback" ]; then
        _OB_TAG="$fallback"
    fi
}

# ---------------------------------------------------------------------------
# TLS / Reality
# ---------------------------------------------------------------------------

_outbound_set_sni_value() {
    local h="$1"
    case "$h" in
        \[*\])
            h="${h#\[}"
            h="${h%\]}"
            ;;
        *\[*|*\]*)
            _outbound_fail "SNI 格式无效"
            return 1
            ;;
    esac
    _outbound_validate_host "$h" "SNI" || return 1
    if [[ "$h" == *:* ]]; then h="[$h]"; fi
    _OB_SNI_VALUE="$h"
}

_outbound_read_sni() {   # <server> <yes|no>
    local server="$1" required="$2" rc
    _OB_SNI_VALUE=''
    _outbound_alias_get "SNI" sni peer servername
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _outbound_set_sni_value "$_OB_PARAM_VALUE" || return 2
        return 0
    fi
    [ "$rc" -eq 2 ] && return 2
    if [ "$required" = yes ]; then
        _outbound_fail "Reality 链接缺少 SNI"
        return 2
    fi
    _outbound_set_sni_value "$server" || return 2
}

_outbound_read_alpn() {
    local v item
    local -a items
    if _outbound_get_opt alpn; then
        v="$_OB_OPT_VALUE"
        IFS=',' read -r -a items <<< "$v"
        for item in "${items[@]}"; do
            [ -n "$item" ] || { _outbound_fail "alpn 包含空值"; return 2; }
            case "$item" in
                *[!A-Za-z0-9._+/:-]*) _outbound_fail "alpn 格式无效"; return 2 ;;
            esac
        done
        _OB_ALPN_JSON=$(jq -cn --arg v "$v" '$v | split(",")') || {
            _outbound_fail "alpn 解析失败"
            return 2
        }
        return 0
    fi
    return 1
}

_outbound_read_fp() {
    local fp
    if _outbound_get_opt fp; then
        fp="${_OB_OPT_VALUE,,}"
        case "$fp" in
            chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|randomizednoalpn|unsafe) ;;
            hello*)
                [[ "$fp" =~ ^hello[a-z0-9_]+$ ]] || { _outbound_fail "不支持的 uTLS 指纹: $fp"; return 2; }
                ;;
            *)
                _outbound_fail "不支持的 uTLS 指纹: $fp"
                return 2
                ;;
        esac
        _OB_FP_VALUE="$fp"
        return 0
    fi
    return 1
}

_outbound_read_pins() {
    local rc v p out=''
    local -a parts
    _outbound_alias_get "证书 pin" pcs pinsha256 pinnedpeercertsha256 pin-sha256 pin_sha256
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -ne 0 ] && return 2
    v="$_OB_PARAM_VALUE"
    IFS=',' read -r -a parts <<< "$v"
    for p in "${parts[@]}"; do
        p="${p//:/}"
        [[ "$p" =~ ^[0-9A-Fa-f]{64}$ ]] || { _outbound_fail "pinnedPeerCertSha256 必须是 64 位十六进制"; return 2; }
        [ -n "$out" ] && out+=","
        out+="${p,,}"
    done
    [ -n "$out" ] || { _outbound_fail "pinnedPeerCertSha256 不能为空"; return 2; }
    _OB_PIN_VALUE="$out"
}

_outbound_read_vcn() {
    local rc v p out=''
    local -a parts
    _outbound_alias_get "verifyPeerCertByName" vcn verifypeercertbyname
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -ne 0 ] && return 2
    v="$_OB_PARAM_VALUE"
    IFS=',' read -r -a parts <<< "$v"
    for p in "${parts[@]}"; do
        [ -n "$p" ] || { _outbound_fail "verifyPeerCertByName 包含空值"; return 2; }
        case "$p" in
            *[!A-Za-z0-9._*-]*) _outbound_fail "verifyPeerCertByName 格式无效"; return 2 ;;
        esac
        [ -n "$out" ] && out+=","
        out+="$p"
    done
    [ -n "$out" ] || { _outbound_fail "verifyPeerCertByName 不能为空"; return 2; }
    _OB_VCN_VALUE="$out"
}

_outbound_read_ech() {
    local rc v
    _outbound_alias_get "ECH" ech
    rc=$?
    [ "$rc" -eq 1 ] && return 1
    [ "$rc" -ne 0 ] && return 2
    v="$_OB_PARAM_VALUE"
    case "$v" in
        *://*)
            case "$v" in *[[:space:]]*) _outbound_fail "ECH 配置格式无效"; return 2 ;; esac
            ;;
        *)
            _outbound_base64_normalize "$v" || { _outbound_fail "ECH 配置不是有效 Base64"; return 2; }
            v="$_OB_B64_PADDED"
            ;;
    esac
    _OB_ECH_VALUE="$v"
}

_outbound_read_reality() {
    local rc v
    _OB_PBK_VALUE=''
    _OB_SID_VALUE=''
    _OB_SPX_VALUE=''
    _OB_PQV_VALUE=''

    _outbound_alias_get "Reality 公钥 pbk" pbk publickey public-key
    rc=$?
    if [ "$rc" -eq 0 ]; then
        v="$_OB_PARAM_VALUE"
        [[ "$v" =~ ^[A-Za-z0-9_-]{43}$ ]] || { _outbound_fail "Reality 公钥 pbk 格式无效"; return 1; }
        _outbound_base64_normalize "$v" || { _outbound_fail "Reality 公钥 pbk 不是有效 Base64Url"; return 1; }
        _outbound_base64_byte_len "$_OB_B64_PADDED" 32 || {
            _outbound_fail "Reality 公钥 pbk 长度不是 32 字节"
            return 1
        }
        _OB_PBK_VALUE="$v"
    elif [ "$rc" -eq 2 ]; then
        return 1
    fi
    [ -n "$_OB_PBK_VALUE" ] || { _outbound_fail "Reality 链接缺少公钥 pbk"; return 1; }

    _outbound_alias_get "Reality shortId" sid shortid short-id
    rc=$?
    if [ "$rc" -eq 0 ]; then
        v="$_OB_PARAM_VALUE"
        [[ "$v" =~ ^[0-9A-Fa-f]{0,16}$ ]] && [ $(( ${#v} % 2 )) -eq 0 ] || {
            _outbound_fail "Reality shortId 必须是不超过 16 位的偶数长度十六进制"
            return 1
        }
        _OB_SID_VALUE="$v"
    elif [ "$rc" -eq 2 ]; then
        return 1
    fi

    _outbound_alias_get "Reality spiderX" spx spiderx spider-x
    rc=$?
    if [ "$rc" -eq 0 ]; then
        v="$_OB_PARAM_VALUE"
        case "$v" in
            /*) ;;
            *) _outbound_fail "Reality spiderX 必须以 / 开头"; return 1 ;;
        esac
        case "$v" in *[[:space:]]*) _outbound_fail "Reality spiderX 不能包含空白"; return 1 ;; esac
        _OB_SPX_VALUE="$v"
    elif [ "$rc" -eq 2 ]; then
        return 1
    fi

    _outbound_alias_get "Reality mldsa65Verify" pqv mldsa65verify mldsa65-verify
    rc=$?
    if [ "$rc" -eq 0 ]; then
        v="$_OB_PARAM_VALUE"
        [ "${#v}" -eq 2603 ] || {
            _outbound_fail "Reality pqv 必须是 2603 位 Base64Url"
            return 1
        }
        case "$v" in
            *[!A-Za-z0-9_-]*) _outbound_fail "Reality pqv 必须是 2603 位 Base64Url"; return 1 ;;
        esac
        _outbound_base64_normalize "$v" || { _outbound_fail "Reality pqv 不是有效 Base64Url"; return 1; }
        _outbound_base64_byte_len "$_OB_B64_PADDED" 1952 || {
            _outbound_fail "Reality pqv 长度不是 1952 字节"
            return 1
        }
        _OB_PQV_VALUE="$v"
    elif [ "$rc" -eq 2 ]; then
        return 1
    fi
}

_outbound_build_tls_settings() {   # <none|tls|reality> <server>
    local mode="$1" server="$2" rc
    local sni='' alpn_json='' fp='' pins='' vcn='' ech=''
    local insecure=0 have_insecure=0

    _OB_SECURITY_JSON='{}'
    _OB_SECURITY_SNI="$server"

    case "$mode" in
        none)
            if _outbound_any_query sni peer servername pbk publickey public-key \
                sid shortid short-id fp alpn insecure allowinsecure skip-cert-verify \
                pcs pinsha256 pinnedpeercertsha256 pin-sha256 pin_sha256 vcn verifypeercertbyname \
                ech spx spiderx spider-x pqv mldsa65verify mldsa65-verify; then
                _outbound_fail "未启用 TLS/Reality，却包含 TLS 参数"
                return 1
            fi
            return 0
            ;;
        tls)
            _outbound_read_sni "$server" no || return 1
            sni="$_OB_SNI_VALUE"

            _outbound_read_alpn
            rc=$?
            [ "$rc" -eq 1 ] || {
                [ "$rc" -eq 0 ] || return 1
                alpn_json="$_OB_ALPN_JSON"
            }

            _outbound_read_fp
            rc=$?
            [ "$rc" -eq 1 ] || {
                [ "$rc" -eq 0 ] || return 1
                fp="$_OB_FP_VALUE"
            }

            _outbound_read_pins
            rc=$?
            [ "$rc" -eq 1 ] || {
                [ "$rc" -eq 0 ] || return 1
                pins="$_OB_PIN_VALUE"
            }

            _outbound_read_vcn
            rc=$?
            [ "$rc" -eq 1 ] || {
                [ "$rc" -eq 0 ] || return 1
                vcn="$_OB_VCN_VALUE"
            }

            _outbound_read_ech
            rc=$?
            [ "$rc" -eq 1 ] || {
                [ "$rc" -eq 0 ] || return 1
                ech="$_OB_ECH_VALUE"
            }

            _outbound_bool_get "insecure" insecure allowinsecure skip-cert-verify skipcertverify
            rc=$?
            if [ "$rc" -eq 0 ]; then
                have_insecure=1
                insecure="$_OB_BOOL_VALUE"
            elif [ "$rc" -ne 1 ]; then
                return 1
            fi
            if [ "$have_insecure" -eq 1 ] && [ "$insecure" -eq 1 ] && [ -z "$pins" ] && [ -z "$vcn" ]; then
                _outbound_fail "Xray 已移除 allowInsecure；请改用 pcs(pinnedPeerCertSha256) 或 vcn(verifyPeerCertByName)"
                return 1
            fi
            if _outbound_any_query pbk publickey public-key sid shortid short-id \
                spx spiderx spider-x pqv mldsa65verify mldsa65-verify; then
                _outbound_fail "非 Reality 链接包含 Reality 参数"
                return 1
            fi

            _OB_SECURITY_JSON=$(jq -cn \
                --arg sni "$sni" \
                --argjson alpn "${alpn_json:-null}" \
                --arg fp "$fp" \
                --arg pins "$pins" \
                --arg vcn "$vcn" \
                --arg ech "$ech" '
                {serverName:$sni}
                + (if $alpn != null then {alpn:$alpn} else {} end)
                + (if $fp != "" then {fingerprint:$fp} else {} end)
                + (if $pins != "" then {pinnedPeerCertSha256:$pins} else {} end)
                + (if $vcn != "" then {verifyPeerCertByName:$vcn} else {} end)
                + (if $ech != "" then {echConfigList:$ech} else {} end)
            ') || { _outbound_fail "TLS 配置生成失败"; return 1; }
            _OB_SECURITY_SNI="$sni"
            ;;
        reality)
            _outbound_read_sni "$server" yes || return 1
            sni="$_OB_SNI_VALUE"
            _outbound_read_reality || return 1

            _outbound_read_fp
            rc=$?
            [ "$rc" -eq 1 ] || {
                [ "$rc" -eq 0 ] || return 1
                fp="$_OB_FP_VALUE"
            }
            if [ "$fp" = "unsafe" ] || [ "$fp" = "hellogolang" ]; then
                _outbound_fail "Reality 不支持 uTLS 指纹: $fp"
                return 1
            fi

            _outbound_bool_get "insecure" insecure allowinsecure skip-cert-verify skipcertverify
            rc=$?
            if [ "$rc" -eq 0 ] && [ "$_OB_BOOL_VALUE" -eq 1 ]; then
                _outbound_fail "Reality 不能同时启用 insecure"
                return 1
            elif [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
                return 1
            fi
            if _outbound_any_query alpn pcs pinsha256 pinnedpeercertsha256 pin-sha256 pin_sha256 \
                vcn verifypeercertbyname ech; then
                _outbound_fail "Reality 不支持 alpn/pcs/vcn/ech 参数"
                return 1
            fi

            _OB_SECURITY_JSON=$(jq -cn \
                --arg sni "$sni" \
                --arg pbk "$_OB_PBK_VALUE" \
                --arg sid "$_OB_SID_VALUE" \
                --arg spx "$_OB_SPX_VALUE" \
                --arg pqv "$_OB_PQV_VALUE" \
                --arg fp "$fp" '
                {serverName:$sni, publicKey:$pbk}
                + (if $sid != "" then {shortId:$sid} else {} end)
                + (if $spx != "" then {spiderX:$spx} else {} end)
                + (if $pqv != "" then {mldsa65Verify:$pqv} else {} end)
                + (if $fp != "" then {fingerprint:$fp} else {} end)
            ') || { _outbound_fail "Reality 配置生成失败"; return 1; }
            _OB_SECURITY_SNI="$sni"
            ;;
        *)
            _outbound_fail "未知安全类型: $mode"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 传输
# ---------------------------------------------------------------------------

_outbound_read_transport_kind() {
    local rc kind=''
    _outbound_alias_get "传输类型" type net
    rc=$?
    [ "$rc" -eq 2 ] && return 1
    if [ "$rc" -eq 0 ]; then kind="${_OB_PARAM_VALUE,,}"; fi
    [ -z "$kind" ] && kind=tcp
    case "$kind" in
        tcp|raw) _OB_KIND=raw ;;
        ws|websocket) _OB_KIND=ws ;;
        httpupgrade) _OB_KIND=httpupgrade ;;
        xhttp|splithttp) _OB_KIND=xhttp ;;
        grpc) _OB_KIND=grpc ;;
        http|h2|h3|quic)
            _outbound_fail "Xray 已移除 ${kind} 传输，请改用 XHTTP"
            return 1
            ;;
        kcp|mkcp)
            _outbound_fail "KCP 已迁移到 FinalMask，暂不支持从分享链接导入"
            return 1
            ;;
        *)
            _outbound_fail "不支持的传输类型: $kind"
            return 1
            ;;
    esac
}

_outbound_check_earlydata_header() {   # <kind>
    local kind="$1" header
    _outbound_get_opt earlydataheadername || return 0
    header="${_OB_OPT_VALUE,,}"
    if [ "$kind" != ws ]; then
        _outbound_fail "earlyDataHeaderName 只适用于 WebSocket 传输"
        return 1
    fi
    case "$header" in
        ''|sec-websocket-protocol) ;;
        *)
            _outbound_fail "Xray 只使用 Sec-WebSocket-Protocol 作为 WS early data 头"
            return 1
            ;;
    esac
}

_outbound_build_transport() {   # <kind> <server> <sni>
    local kind="$1" server="$2" sni="$3"
    local host='' path='' service='' authority='' mode='' extra='' ed=''
    local multi=0 rc

    _OB_NETWORK=''
    _OB_TRANSPORT_JSON=''

    _outbound_get_opt host && host="$_OB_OPT_VALUE"
    _outbound_get_opt path && path="$_OB_OPT_VALUE"
    _outbound_get_opt servicename && service="$_OB_OPT_VALUE"
    _outbound_get_opt authority && authority="$_OB_OPT_VALUE"
    _outbound_get_opt mode && mode="$_OB_OPT_VALUE"
    _outbound_get_opt extra && extra="$_OB_OPT_VALUE"
    _outbound_get_opt ed && ed="$_OB_OPT_VALUE"

    case "$kind" in
        raw)
            [ -z "$host$path$service$authority$extra$ed" ] || {
                _outbound_fail "RAW 传输不支持 host/path/serviceName/authority/extra/ed"
                return 1
            }
            [ -z "$mode" ] || [ "${mode,,}" = auto ] || {
                _outbound_fail "RAW 传输不支持 mode"
                return 1
            }
            _OB_NETWORK=raw
            ;;
        ws|httpupgrade)
            [ -z "$service$authority$extra" ] || {
                _outbound_fail "WebSocket/HTTPUpgrade 传输不支持 serviceName/authority/extra"
                return 1
            }
            [ -z "$mode" ] || [ "${mode,,}" = auto ] || {
                _outbound_fail "WebSocket/HTTPUpgrade 传输不支持 mode"
                return 1
            }
            path="${path:-/}"
            _outbound_validate_path "$path" "path" || return 1
            path="$_OB_PATH_VALUE"
            if [ -n "$ed" ]; then
                [[ "$ed" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$ed))" -ge 1 ] && [ "$((10#$ed))" -le 65535 ] || {
                    _outbound_fail "ed 须在 1-65535"
                    return 1
                }
                case "$path" in
                    *'?ed='*|*'&ed='*) ;;
                    *\?*) path+="&ed=$((10#$ed))" ;;
                    *) path+="?ed=$((10#$ed))" ;;
                esac
            fi
            if [ -n "$host" ]; then
                _outbound_validate_host "$host" "Host" || return 1
            fi
            if [ "$kind" = ws ]; then _OB_NETWORK=websocket; else _OB_NETWORK=httpupgrade; fi
            _OB_TRANSPORT_JSON=$(jq -cn --arg host "$host" --arg path "$path" '
                {path:$path} + (if $host != "" then {host:$host} else {} end)
            ') || { _outbound_fail "传输配置生成失败"; return 1; }
            ;;
        xhttp)
            [ -z "$service$authority$ed" ] || {
                _outbound_fail "XHTTP 传输不支持 serviceName/authority/ed"
                return 1
            }
            mode="${mode:-auto}"
            mode="${mode//_/-}"
            case "$mode" in
                auto|packet-up|stream-up|stream-one) ;;
                *) _outbound_fail "XHTTP mode 只支持 auto/packet-up/stream-up/stream-one"; return 1 ;;
            esac
            path="${path:-/}"
            _outbound_validate_path "$path" "path" || return 1
            path="$_OB_PATH_VALUE"
            if [ -n "$host" ]; then
                _outbound_validate_host "$host" "Host" || return 1
            fi
            if [ -n "$extra" ]; then
                printf '%s' "$extra" | jq -e 'type == "object"' >/dev/null 2>&1 || {
                    _outbound_fail "XHTTP extra 必须是 JSON 对象"
                    return 1
                }
            fi
            _OB_NETWORK=xhttp
            _OB_TRANSPORT_JSON=$(jq -cn \
                --arg host "$host" \
                --arg path "$path" \
                --arg mode "$mode" \
                --argjson extra "${extra:-null}" '
                {path:$path, mode:$mode}
                + (if $host != "" then {host:$host} else {} end)
                + (if $extra != null then {extra:$extra} else {} end)
            ') || { _outbound_fail "XHTTP 配置生成失败"; return 1; }
            ;;
        grpc)
            [ -z "$host$extra$ed" ] || {
                _outbound_fail "gRPC 传输不支持 host/extra/ed"
                return 1
            }
            if [ -n "$path" ] && [ -z "$service" ]; then
                service="${path#/}"
                path=''
            fi
            [ -z "$path" ] || { _outbound_fail "gRPC 请使用 serviceName"; return 1; }
            mode="${mode,,}"
            case "$mode" in
                ''|gun) multi=0 ;;
                multi) multi=1 ;;
                *) _outbound_fail "gRPC mode 只支持 gun/multi"; return 1 ;;
            esac
            if [ -n "$authority" ]; then
                case "$authority" in
                    *[[:space:]/]*) _outbound_fail "gRPC authority 格式无效"; return 1 ;;
                esac
            fi
            _OB_NETWORK=grpc
            _OB_TRANSPORT_JSON=$(jq -cn \
                --arg service "$service" \
                --arg authority "$authority" \
                --argjson multi "$multi" '
                {serviceName:$service}
                + (if $multi == 1 then {multiMode:true} else {} end)
                + (if $authority != "" then {authority:$authority} else {} end)
            ') || { _outbound_fail "gRPC 配置生成失败"; return 1; }
            ;;
        *)
            _outbound_fail "未知传输类型"
            return 1
            ;;
    esac
    return 0
}

_outbound_build_stream() {   # <security> <security_json>
    local security="$1" sec_json="$2"
    if [ "$security" = reality ]; then
        case "$_OB_NETWORK" in
            raw|xhttp|grpc) ;;
            *)
                _outbound_fail "Reality 只支持 RAW/XHTTP/gRPC 传输"
                return 1
                ;;
        esac
    fi
    _OB_STREAM_JSON=$(jq -cn \
        --arg network "$_OB_NETWORK" \
        --arg security "$security" \
        --argjson sec "$sec_json" \
        --argjson tr "${_OB_TRANSPORT_JSON:-null}" '
        ({network:$network, security:$security}
         + (if $security == "tls" then {tlsSettings:$sec}
            elif $security == "reality" then {realitySettings:$sec}
            else {} end))
        + (if $tr == null then {}
           elif $network == "websocket" then {wsSettings:$tr}
           elif $network == "httpupgrade" then {httpupgradeSettings:$tr}
           elif $network == "xhttp" then {xhttpSettings:$tr}
           elif $network == "grpc" then {grpcSettings:$tr}
           else {} end)
    ') || { _outbound_fail "streamSettings 生成失败"; return 1; }
}

# ---------------------------------------------------------------------------
# 协议解析
# ---------------------------------------------------------------------------

_outbound_parse_vless() {
    local link="$1" uuid enc='none' flow='' security='none' kind
    local port

    _outbound_split_url "$link" || return 1
    [ "$_OB_SCHEME" = vless ] || { _outbound_fail "不是 VLESS 链接"; return 1; }
    [ -n "$_OB_USERINFO" ] || { _outbound_fail "VLESS 链接缺少 UUID"; return 1; }
    _outbound_percent_decode "$_OB_USERINFO" || return 1
    _outbound_uuid_value "$_OB_DECODED" || return 1
    uuid="$_OB_UUID_VALUE"
    [ -z "$_OB_PATH" ] || [ "$_OB_PATH" = "/" ] || { _outbound_fail "VLESS 链接路径无效"; return 1; }

    _outbound_parse_hostport "$_OB_HOSTPORT" || return 1
    [ -n "$_OB_HP_PORT" ] || { _outbound_fail "VLESS 链接缺少端口"; return 1; }
    _outbound_validate_port "$_OB_HP_PORT" || return 1
    port="$_OB_PORT_VALUE"

    _outbound_parse_query "$_OB_RAW_QUERY" || return 1
    _outbound_check_query encryption flow security sni peer servername pbk publickey public-key \
        sid shortid short-id fp type net headertype host path servicename mode authority extra ed \
        earlydataheadername alpn insecure allowinsecure skip-cert-verify pcs pinsha256 \
        pinnedpeercertsha256 pin-sha256 pin_sha256 vcn verifypeercertbyname ech spx spiderx \
        spider-x pqv mldsa65verify mldsa65-verify packetencoding || return 1

    _outbound_get_opt encryption && enc="$_OB_OPT_VALUE"
    [ -n "$enc" ] || enc='none'
    case "$enc" in *[[:space:]]*) _outbound_fail "VLESS encryption 不能包含空白"; return 1 ;; esac

    if _outbound_get_opt security; then
        security="${_OB_OPT_VALUE,,}"
        case "$security" in
            ''|none) security=none ;;
            tls|reality) ;;
            xtls) _outbound_fail "Xray 已移除旧 XTLS，请改用 Reality/TLS + xtls-rprx-vision"; return 1 ;;
            *) _outbound_fail "VLESS security 只支持 none/tls/reality"; return 1 ;;
        esac
    fi

    if _outbound_get_opt flow; then flow="$_OB_OPT_VALUE"; fi
    if [ -n "$flow" ]; then
        case "$flow" in
            xtls-rprx-vision|xtls-rprx-vision-udp443) ;;
            *) _outbound_fail "VLESS flow 只支持 xtls-rprx-vision(-udp443)"; return 1 ;;
        esac
        [ "$security" = tls ] || [ "$security" = reality ] || {
            _outbound_fail "VLESS flow 需要 TLS 或 Reality"
            return 1
        }
    fi

    _outbound_read_transport_kind || return 1
    kind="$_OB_KIND"
    _outbound_check_earlydata_header "$kind" || return 1
    [ -z "$flow" ] || [ "$kind" = raw ] || {
        _outbound_fail "VLESS flow 只支持 RAW/TCP 传输"
        return 1
    }
    if _outbound_get_opt headertype; then
        case "${_OB_OPT_VALUE,,}" in
            ''|none) ;;
            *) _outbound_fail "VLESS 不支持 headerType 伪装"; return 1 ;;
        esac
    fi
    if _outbound_q_get packetencoding; then
        _outbound_fail "Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理"
        return 1
    fi

    _outbound_build_tls_settings "$security" "$_OB_HP_HOST" || return 1
    _outbound_build_transport "$kind" "$_OB_HP_HOST" "$_OB_SECURITY_SNI" || return 1
    _outbound_build_stream "$security" "$_OB_SECURITY_JSON" || return 1

    _OB_OUTBOUND=$(jq -cn \
        --arg addr "$_OB_HP_HOST" \
        --argjson port "$port" \
        --arg id "$uuid" \
        --arg enc "$enc" \
        --arg flow "$flow" \
        --argjson stream "$_OB_STREAM_JSON" '
        {protocol:"vless",
         settings:({address:$addr, port:$port, id:$id, encryption:$enc}
                   + (if $flow != "" then {flow:$flow} else {} end)),
         streamSettings:$stream}
    ') || { _outbound_fail "VLESS 出口生成失败"; return 1; }
    _OB_PROTOCOL='vless'
    _OB_SERVER="$_OB_HP_HOST"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$_OB_FRAGMENT" || return 1
}

_outbound_vmess_cipher() {
    local v="${1:-}"
    v="${v,,}"
    case "$v" in
        ''|auto) _OB_CIPHER_VALUE=auto ;;
        aes-128-gcm) _OB_CIPHER_VALUE=aes-128-gcm ;;
        chacha20-poly1305|chacha20-ietf-poly1305) _OB_CIPHER_VALUE=chacha20-poly1305 ;;
        *)
            _outbound_fail "VMess 加密只支持 auto/aes-128-gcm/chacha20-poly1305"
            return 1
            ;;
    esac
}

_outbound_parse_vmess_url() {
    local link="$1" uuid cipher='' tls_mode='none' sec='' port kind
    local rc

    _outbound_split_url "$link" || return 1
    [ "$_OB_SCHEME" = vmess ] || { _outbound_fail "不是 VMess 链接"; return 1; }
    [ -n "$_OB_USERINFO" ] || { _outbound_fail "VMess 链接缺少 UUID"; return 1; }
    _outbound_percent_decode "$_OB_USERINFO" || return 1
    _outbound_uuid_value "$_OB_DECODED" || return 1
    uuid="$_OB_UUID_VALUE"
    [ -z "$_OB_PATH" ] || [ "$_OB_PATH" = "/" ] || { _outbound_fail "VMess 链接路径无效"; return 1; }

    _outbound_parse_hostport "$_OB_HOSTPORT" || return 1
    [ -n "$_OB_HP_PORT" ] || { _outbound_fail "VMess 链接缺少端口"; return 1; }
    _outbound_validate_port "$_OB_HP_PORT" || return 1
    port="$_OB_PORT_VALUE"

    _outbound_parse_query "$_OB_RAW_QUERY" || return 1
    _outbound_check_query type net security scy encryption host path sni peer servername fp alpn \
        insecure allowinsecure skip-cert-verify pcs pinsha256 pinnedpeercertsha256 pin-sha256 \
        pin_sha256 vcn verifypeercertbyname ech aid alterid packetencoding headertype flow mode \
        servicename authority extra ed earlydataheadername pbk publickey public-key sid shortid \
        short-id spx spiderx spider-x pqv mldsa65verify mldsa65-verify || return 1

    _outbound_get_opt scy && cipher="$_OB_OPT_VALUE"
    if _outbound_get_opt encryption; then
        [ -z "$cipher" ] || { _outbound_fail "VMess scy 与 encryption 重复"; return 1; }
        cipher="$_OB_OPT_VALUE"
    fi
    if _outbound_get_opt security; then
        sec="${_OB_OPT_VALUE,,}"
        case "$sec" in
            ''|none) ;;
            tls) tls_mode=tls ;;
            reality) tls_mode=reality ;;
            auto|aes-128-gcm|chacha20-poly1305|chacha20-ietf-poly1305)
                [ -z "$cipher" ] || { _outbound_fail "VMess security 与 scy/encryption 重复"; return 1; }
                cipher="$sec"
                ;;
            *) _outbound_fail "VMess security 只支持 none/tls/reality 或加密方法"; return 1 ;;
        esac
    fi
    _outbound_vmess_cipher "$cipher" || return 1
    cipher="$_OB_CIPHER_VALUE"

    _outbound_int_get "VMess alterId" 0 0 aid alterid
    rc=$?
    [ "$rc" -eq 2 ] && return 1

    if _outbound_q_get flow; then
        _outbound_fail "Xray 不支持 VMess flow"
        return 1
    fi
    if _outbound_q_get packetencoding; then
        _outbound_fail "Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理"
        return 1
    fi
    if _outbound_get_opt headertype; then
        case "${_OB_OPT_VALUE,,}" in
            ''|none) ;;
            *) _outbound_fail "VMess 不支持 headerType 伪装"; return 1 ;;
        esac
    fi

    _outbound_read_transport_kind || return 1
    kind="$_OB_KIND"
    _outbound_check_earlydata_header "$kind" || return 1
    _outbound_build_tls_settings "$tls_mode" "$_OB_HP_HOST" || return 1
    _outbound_build_transport "$kind" "$_OB_HP_HOST" "$_OB_SECURITY_SNI" || return 1
    _outbound_build_stream "$tls_mode" "$_OB_SECURITY_JSON" || return 1

    _OB_OUTBOUND=$(jq -cn \
        --arg addr "$_OB_HP_HOST" \
        --argjson port "$port" \
        --arg id "$uuid" \
        --arg security "$cipher" \
        --argjson stream "$_OB_STREAM_JSON" '
        {protocol:"vmess",
         settings:{address:$addr, port:$port, id:$id, security:$security},
         streamSettings:$stream}
    ') || { _outbound_fail "VMess 出口生成失败"; return 1; }
    _OB_PROTOCOL='vmess'
    _OB_SERVER="$_OB_HP_HOST"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$_OB_FRAGMENT" || return 1
}

_outbound_json_get() {   # <json> <key>
    local v
    v=$(jq -r --arg k "$2" '
        if has($k) and .[$k] != null then
            .[$k] | if type == "string" then . else tostring end
        else empty end
    ' <<< "$1") || return 1
    if printf '%s' "$v" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "VMess JSON 字段 ${2} 包含控制字符"
        return 1
    fi
    _OB_JSON_VALUE="$v"
}

_outbound_json_alias_get() {   # <json> <label> <key...>
    local json="$1" label="$2" k v found='' set=0
    shift 2
    for k in "$@"; do
        v=$(jq -r --arg k "$k" '
            if has($k) and .[$k] != null then
                .[$k] | if type == "string" then . else tostring end
            else empty end
        ' <<< "$json") || return 2
        [ -n "$v" ] || continue
        if [ "$set" -eq 1 ] && [ "$v" != "$found" ]; then
            _outbound_fail "${label}字段冲突"
            return 2
        fi
        found="$v"
        set=1
    done
    [ "$set" -eq 1 ] || return 1
    if printf '%s' "$found" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "VMess JSON 字段 ${label} 包含控制字符"
        return 2
    fi
    _OB_JSON_ALIAS_VALUE="$found"
}

_outbound_query_add() {
    [ -n "$2" ] && _OB_QUERY+="$1"$'\t'"$2"$'\n'
}

_outbound_parse_vmess_legacy() {
    local link="$1" raw body fragment text data unknown
    local host='' port_raw='' uuid='' aid_raw='' cipher='' net='' header='' tls_raw='' tls_mode='none'
    local security_tls=0 security_reality=0
    local ps='' mode='' service='' kind port

    raw="${link#vmess://}"
    fragment=''
    case "$raw" in *'#'*) fragment="${raw#*#}"; raw="${raw%%#*}" ;; esac
    case "$raw" in *'?'*) _outbound_fail "VMess Base64 链接不能包含查询字符串"; return 1 ;; esac
    body="$raw"
    [ -n "$body" ] || { _outbound_fail "VMess 链接为空"; return 1; }
    text=$(_outbound_base64_decode "$body") || { _outbound_fail "VMess 链接 Base64 无效"; return 1; }
    data=$(printf '%s' "$text" | jq -c 'if type == "object" then . else error("not object") end' 2>/dev/null) || {
        _outbound_fail "VMess Base64 内容不是有效 JSON 对象"
        return 1
    }

    unknown=$(jq -r --argjson allowed '["v","ps","add","port","id","aid","scy","security","net","type","host","path","tls","sni","alpn","fp","insecure","allowinsecure","skip-cert-verify","packetencoding","mode","serviceName","authority","extra","ed","earlydataheadername","pcs","vcn","ech","pbk","publicKey","public-key","sid","shortId","short-id","spx","spiderX","spider-x","pqv","mldsa65Verify","mldsa65-verify"]' '
        [ to_entries[]
          | . as $e
          | select(($allowed | index($e.key)) == null)
          | select(
              ((.value == null) or (.value == "") or
               ((.value | type) == "array" and (.value | length) == 0) or
               ((.value | type) == "object" and (.value | length) == 0)) | not
            )
          | .key
        ] | join(",")
    ' <<< "$data") || { _outbound_fail "VMess JSON 校验失败"; return 1; }
    [ -z "$unknown" ] || { _outbound_fail "VMess JSON 包含暂不支持的字段: $unknown"; return 1; }

    _outbound_json_get "$data" add || return 1
    host="$_OB_JSON_VALUE"
    _outbound_validate_host "$host" || return 1
    _outbound_json_get "$data" port || return 1
    port_raw="$_OB_JSON_VALUE"
    [ -n "$port_raw" ] || { _outbound_fail "VMess JSON 缺少端口 port"; return 1; }
    _outbound_validate_port "$port_raw" "VMess 端口" || return 1
    port="$_OB_PORT_VALUE"

    _outbound_json_get "$data" id || return 1
    _outbound_uuid_value "$_OB_JSON_VALUE" || return 1
    uuid="$_OB_UUID_VALUE"

    aid_raw=$(jq -r '.aid // 0 | tostring' <<< "$data") || return 1
    [ "$aid_raw" = "0" ] || { _outbound_fail "VMess 只支持 AEAD，alterId 必须为 0"; return 1; }

    _outbound_json_get "$data" ps || return 1
    ps="$_OB_JSON_VALUE"
    _outbound_json_get "$data" scy || return 1
    cipher="$_OB_JSON_VALUE"
    _outbound_json_get "$data" security || return 1
    if [ -n "$_OB_JSON_VALUE" ]; then
        case "${_OB_JSON_VALUE,,}" in
            tls)
                security_tls=1
                tls_mode=tls
                ;;
            reality)
                security_reality=1
                tls_mode=reality
                ;;
            none) ;;
            auto|aes-128-gcm|chacha20-poly1305|chacha20-ietf-poly1305)
                [ -z "$cipher" ] || { _outbound_fail "VMess scy 与 security 重复"; return 1; }
                cipher="$_OB_JSON_VALUE"
                ;;
            *) _outbound_fail "VMess JSON security 无效"; return 1 ;;
        esac
    fi
    _outbound_vmess_cipher "$cipher" || return 1
    cipher="$_OB_CIPHER_VALUE"

    _outbound_json_get "$data" tls || return 1
    tls_raw="$_OB_JSON_VALUE"
    case "${tls_raw,,}" in
        '') ;;
        none)
            [ "$security_tls" -eq 0 ] && [ "$security_reality" -eq 0 ] || { _outbound_fail "VMess tls 与 security 冲突"; return 1; }
            tls_mode=none
            ;;
        tls)
            [ "$security_reality" -eq 0 ] || { _outbound_fail "VMess tls 与 security 冲突"; return 1; }
            tls_mode=tls
            ;;
        true)
            [ "$security_reality" -eq 0 ] || { _outbound_fail "VMess tls 与 security 冲突"; return 1; }
            tls_mode=tls
            ;;
        false)
            [ "$security_tls" -eq 0 ] && [ "$security_reality" -eq 0 ] || { _outbound_fail "VMess tls 与 security 冲突"; return 1; }
            tls_mode=none
            ;;
        reality)
            [ "$security_tls" -eq 0 ] || { _outbound_fail "VMess tls 与 security 冲突"; return 1; }
            tls_mode=reality
            ;;
        *) _outbound_fail "VMess JSON 只支持 tls/reality 或明文"; return 1 ;;
    esac

    _outbound_json_get "$data" net || return 1
    net="${_OB_JSON_VALUE,,}"
    [ -n "$net" ] || net=tcp
    case "$net" in
        tcp|raw) kind=raw ;;
        ws|websocket) kind=ws ;;
        httpupgrade) kind=httpupgrade ;;
        xhttp|splithttp) kind=xhttp ;;
        grpc)
            kind=grpc
            _outbound_json_get "$data" serviceName || return 1
            service="$_OB_JSON_VALUE"
            _outbound_json_get "$data" mode || return 1
            mode="$_OB_JSON_VALUE"
            _outbound_json_get "$data" path || return 1
            [ -n "$service" ] || service="${_OB_JSON_VALUE#/}"
            _outbound_json_get "$data" type || return 1
            [ -n "$mode" ] || mode="$_OB_JSON_VALUE"
            ;;
        http|h2|h3|quic)
            _outbound_fail "Xray 已移除 ${net} 传输，请改用 XHTTP"
            return 1
            ;;
        kcp|mkcp)
            _outbound_fail "KCP 已迁移到 FinalMask，暂不支持从分享链接导入"
            return 1
            ;;
        *) _outbound_fail "VMess JSON 不支持的传输: $net"; return 1 ;;
    esac

    if [ "$kind" != grpc ]; then
        _outbound_json_get "$data" type || return 1
        header="${_OB_JSON_VALUE,,}"
        case "$header" in
            ''|none) ;;
            *) _outbound_fail "VMess 不支持 headerType 伪装"; return 1 ;;
        esac
    fi

    _OB_QUERY=''
    _OB_DUP_KEYS=''
    if [ "$tls_mode" != none ]; then
        _outbound_json_get "$data" sni || return 1
        _outbound_query_add sni "$_OB_JSON_VALUE"
        _outbound_json_get "$data" alpn || return 1
        if [ -n "$_OB_JSON_VALUE" ]; then
            _outbound_query_add alpn "$_OB_JSON_VALUE"
        fi
        _outbound_json_get "$data" fp || return 1
        _outbound_query_add fp "$_OB_JSON_VALUE"
        _outbound_json_get "$data" pcs || return 1
        _outbound_query_add pcs "$_OB_JSON_VALUE"
        _outbound_json_get "$data" vcn || return 1
        _outbound_query_add vcn "$_OB_JSON_VALUE"
        _outbound_json_get "$data" ech || return 1
        _outbound_query_add ech "$_OB_JSON_VALUE"
        local insecure_raw
        insecure_raw=$(jq -r '
            if has("insecure") and (.insecure == true or .insecure == 1 or .insecure == "1" or .insecure == "true") then "1"
            elif has("allowinsecure") and (.allowinsecure == true or .allowinsecure == 1 or .allowinsecure == "1" or .allowinsecure == "true") then "1"
            elif has("skip-cert-verify") and (.["skip-cert-verify"] == true or .["skip-cert-verify"] == 1 or .["skip-cert-verify"] == "1" or .["skip-cert-verify"] == "true") then "1"
            else empty end
        ' <<< "$data") || return 1
        [ -n "$insecure_raw" ] && _outbound_query_add insecure "$insecure_raw"
    else
        if jq -e '[(.sni // ""), (.alpn // ""), (.fp // ""), (.pcs // ""), (.vcn // ""), (.ech // ""), (.insecure // false), (.allowinsecure // false), (.["skip-cert-verify"] // false)] | any(. != "" and . != false)' >/dev/null 2>&1 <<< "$data"; then
            _outbound_fail "VMess 未启用 TLS，却包含 TLS 参数"
            return 1
        fi
    fi
    _outbound_json_alias_get "$data" "Reality pbk" pbk publicKey public-key
    case $? in
        0) _outbound_query_add pbk "$_OB_JSON_ALIAS_VALUE" ;;
        1) ;;
        *) return 1 ;;
    esac
    _outbound_json_alias_get "$data" "Reality sid" sid shortId short-id
    case $? in
        0) _outbound_query_add sid "$_OB_JSON_ALIAS_VALUE" ;;
        1) ;;
        *) return 1 ;;
    esac
    _outbound_json_alias_get "$data" "Reality spx" spx spiderX spider-x
    case $? in
        0) _outbound_query_add spx "$_OB_JSON_ALIAS_VALUE" ;;
        1) ;;
        *) return 1 ;;
    esac
    _outbound_json_alias_get "$data" "Reality pqv" pqv mldsa65Verify mldsa65-verify
    case $? in
        0) _outbound_query_add pqv "$_OB_JSON_ALIAS_VALUE" ;;
        1) ;;
        *) return 1 ;;
    esac

    _outbound_json_get "$data" host || return 1
    _outbound_query_add host "$_OB_JSON_VALUE"
    _outbound_json_get "$data" path || return 1
    if [ "$kind" != grpc ]; then
        _outbound_query_add path "$_OB_JSON_VALUE"
    fi
    _outbound_json_get "$data" authority || return 1
    _outbound_query_add authority "$_OB_JSON_VALUE"
    _outbound_json_get "$data" extra || return 1
    _outbound_query_add extra "$_OB_JSON_VALUE"
    _outbound_json_get "$data" ed || return 1
    _outbound_query_add ed "$_OB_JSON_VALUE"
    _outbound_json_get "$data" earlydataheadername || return 1
    _outbound_query_add earlydataheadername "$_OB_JSON_VALUE"
    _outbound_json_get "$data" mode || return 1
    if [ "$kind" != grpc ]; then
        _outbound_query_add mode "$_OB_JSON_VALUE"
    fi
    if [ "$kind" = grpc ]; then
        _outbound_query_add servicename "$service"
        _outbound_query_add mode "$mode"
    fi

    _outbound_json_get "$data" packetencoding || return 1
    if [ -n "$_OB_JSON_VALUE" ]; then
        _outbound_fail "Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理"
        return 1
    fi

    _outbound_check_earlydata_header "$kind" || return 1
    _outbound_build_tls_settings "$tls_mode" "$host" || return 1
    _outbound_build_transport "$kind" "$host" "$_OB_SECURITY_SNI" || return 1
    _outbound_build_stream "$tls_mode" "$_OB_SECURITY_JSON" || return 1

    _OB_OUTBOUND=$(jq -cn \
        --arg addr "$host" \
        --argjson p "$port" \
        --arg id "$uuid" \
        --arg security "$cipher" \
        --argjson stream "$_OB_STREAM_JSON" '
        {protocol:"vmess",
         settings:{address:$addr, port:$p, id:$id, security:$security},
         streamSettings:$stream}
    ') || { _outbound_fail "VMess 出口生成失败"; return 1; }
    _OB_PROTOCOL='vmess'
    _OB_SERVER="$host"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$fragment" "$ps" || return 1
}

_outbound_parse_vmess() {
    local link="$1" raw body
    raw="${link#vmess://}"
    body="${raw%%#*}"
    body="${body%%\?*}"
    case "$body" in
        *@*) _outbound_parse_vmess_url "$link" ;;
        *) _outbound_parse_vmess_legacy "$link" ;;
    esac
}

_outbound_parse_trojan() {
    local link="$1" password security='tls' kind port rc

    _outbound_split_url "$link" || return 1
    [ "$_OB_SCHEME" = trojan ] || { _outbound_fail "不是 Trojan 链接"; return 1; }
    [ -n "$_OB_USERINFO" ] || { _outbound_fail "Trojan 链接缺少密码"; return 1; }
    _outbound_percent_decode "$_OB_USERINFO" || return 1
    password="$_OB_DECODED"
    [ -n "$password" ] || { _outbound_fail "Trojan 密码不能为空"; return 1; }
    [ -z "$_OB_PATH" ] || [ "$_OB_PATH" = "/" ] || { _outbound_fail "Trojan 链接路径无效"; return 1; }

    _outbound_parse_hostport "$_OB_HOSTPORT" || return 1
    [ -n "$_OB_HP_PORT" ] || { _outbound_fail "Trojan 链接缺少端口"; return 1; }
    _outbound_validate_port "$_OB_HP_PORT" || return 1
    port="$_OB_PORT_VALUE"

    _outbound_parse_query "$_OB_RAW_QUERY" || return 1
    _outbound_check_query security sni peer servername alpn fp type net host path servicename mode \
        authority extra ed headertype insecure allowinsecure skip-cert-verify pcs pinsha256 \
        pinnedpeercertsha256 pin-sha256 pin_sha256 vcn verifypeercertbyname ech flow packetencoding \
        earlydataheadername pbk publickey public-key sid shortid short-id spx spiderx spider-x \
        pqv mldsa65verify mldsa65-verify || return 1

    if _outbound_get_opt security; then
        security="${_OB_OPT_VALUE,,}"
        case "$security" in
            ''|tls) security=tls ;;
            none) security=none ;;
            xtls) _outbound_fail "Xray 已移除旧 XTLS"; return 1 ;;
            reality) security=reality ;;
            *) _outbound_fail "Trojan security 只支持 reality/tls/none"; return 1 ;;
        esac
    fi
    if _outbound_q_get flow; then
        _outbound_fail "Xray 已移除 Trojan flow"
        return 1
    fi
    if _outbound_q_get packetencoding; then
        _outbound_fail "Xray 出站没有 packetEncoding 字段；UDP 由核心按 XUDP/Mux 处理"
        return 1
    fi
    if _outbound_get_opt headertype; then
        case "${_OB_OPT_VALUE,,}" in
            ''|none) ;;
            *) _outbound_fail "Trojan 不支持 headerType 伪装"; return 1 ;;
        esac
    fi
    _outbound_read_transport_kind || return 1
    kind="$_OB_KIND"
    _outbound_check_earlydata_header "$kind" || return 1
    _outbound_build_tls_settings "$security" "$_OB_HP_HOST" || return 1
    _outbound_build_transport "$kind" "$_OB_HP_HOST" "$_OB_SECURITY_SNI" || return 1
    _outbound_build_stream "$security" "$_OB_SECURITY_JSON" || return 1

    _OB_OUTBOUND=$(jq -cn \
        --arg addr "$_OB_HP_HOST" \
        --argjson p "$port" \
        --arg password "$password" \
        --argjson stream "$_OB_STREAM_JSON" '
        {protocol:"trojan",
         settings:{address:$addr, port:$p, password:$password},
         streamSettings:$stream}
    ') || { _outbound_fail "Trojan 出口生成失败"; return 1; }
    _OB_PROTOCOL='trojan'
    _OB_SERVER="$_OB_HP_HOST"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$_OB_FRAGMENT" || return 1
}

_outbound_ss2022_valid() {
    local method="$1" password="$2" need part len
    local -a parts
    case "$method" in
        2022-blake3-aes-128-gcm) need=16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) need=32 ;;
        *) return 0 ;;
    esac
    case "$password" in *:*:*) return 1 ;; esac
    IFS=':' read -r -a parts <<< "$password"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || return 1
        _outbound_base64_normalize "$part" || return 1
        len=$(printf '%s' "$_OB_B64_PADDED" | base64 -d 2>/dev/null | wc -c) || return 1
        len="${len//[[:space:]]/}"
        [ "$len" = "$need" ] || return 1
    done
}

_outbound_parse_ss() {
    local link="$1" raw body fragment query userinfo endpoint method_password decoded
    local method password port

    raw="${link#ss://}"
    case "$raw" in *'#'*) fragment="${raw#*#}"; raw="${raw%%#*}" ;; *) fragment='' ;; esac
    case "$raw" in *'?'*) query="${raw#*\?}"; raw="${raw%%\?*}" ;; *) query='' ;; esac
    [ -n "$raw" ] || { _outbound_fail "Shadowsocks 链接为空"; return 1; }

    if [ -n "$query" ]; then
        _outbound_parse_query "$query" || return 1
        if _outbound_q_get plugin || _outbound_q_get plugin-opts; then
            _outbound_fail "Xray Shadowsocks 出站不支持 SIP003 插件"
            return 1
        fi
        _outbound_check_query || return 1
    fi

    if [[ "$raw" == *@* ]]; then
        userinfo="${raw%@*}"
        endpoint="${raw##*@}"
        _outbound_percent_decode "$userinfo" || return 1
        userinfo="$_OB_DECODED"
        if [[ "$userinfo" == *:* ]]; then
            method_password="$userinfo"
        else
            method_password=$(_outbound_base64_decode "$userinfo") || {
                _outbound_fail "Shadowsocks 凭据 Base64 无效"
                return 1
            }
        fi
    else
        decoded=$(_outbound_base64_decode "$raw") || {
            _outbound_fail "Shadowsocks 整串 Base64 无效"
            return 1
        }
        [[ "$decoded" == *@* ]] || { _outbound_fail "Shadowsocks Base64 内容缺少服务器地址"; return 1; }
        method_password="${decoded%@*}"
        endpoint="${decoded##*@}"
    fi

    [[ "$method_password" == *:* ]] || { _outbound_fail "Shadowsocks 链接缺少加密方法或密码"; return 1; }
    method="${method_password%%:*}"
    password="${method_password#*:}"
    method="${method,,}"
    case "$method" in
        aead_aes_128_gcm) method=aes-128-gcm ;;
        aead_aes_256_gcm) method=aes-256-gcm ;;
        aead_chacha20_poly1305|chacha20-ietf-poly1305) method=chacha20-poly1305 ;;
        aead_xchacha20_poly1305|xchacha20-ietf-poly1305) method=xchacha20-poly1305 ;;
        aes-128-gcm|aes-256-gcm|chacha20-poly1305|xchacha20-poly1305|\
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;;
        *)
            _outbound_fail "Shadowsocks 加密方法不在 Xray 支持范围内: $method"
            return 1
            ;;
    esac
    [ -n "$password" ] || { _outbound_fail "Shadowsocks 密码不能为空"; return 1; }
    _outbound_ss2022_valid "$method" "$password" || {
        _outbound_fail "Shadowsocks 2022 密钥长度或 Base64 与服务端算法不匹配"
        return 1
    }

    _outbound_parse_hostport "$endpoint" || return 1
    [ -n "$_OB_HP_PORT" ] || { _outbound_fail "Shadowsocks 链接缺少端口"; return 1; }
    _outbound_validate_port "$_OB_HP_PORT" || return 1
    port="$_OB_PORT_VALUE"

    _OB_OUTBOUND=$(jq -cn \
        --arg addr "$_OB_HP_HOST" \
        --argjson p "$port" \
        --arg method "$method" \
        --arg password "$password" '
        {protocol:"shadowsocks",
         settings:{address:$addr, port:$p, method:$method, password:$password}}
    ') || { _outbound_fail "Shadowsocks 出口生成失败"; return 1; }
    _OB_PROTOCOL='shadowsocks'
    _OB_SERVER="$_OB_HP_HOST"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$fragment" || return 1
}

_outbound_parse_socks() {
    local link="$1" raw body fragment query decoded username='' password='' port
    local scheme

    scheme="${link%%://*}"
    raw="${link#*://}"
    case "$raw" in *'#'*) fragment="${raw#*#}"; raw="${raw%%#*}" ;; *) fragment='' ;; esac
    case "$raw" in *'?'*) query="${raw#*\?}"; raw="${raw%%\?*}" ;; *) query='' ;; esac
    [ -n "$raw" ] || { _outbound_fail "SOCKS 链接为空"; return 1; }

    if [ -n "$query" ]; then
        _outbound_parse_query "$query" || return 1
        _outbound_check_query || return 1
    else
        _OB_QUERY=''
        _OB_DUP_KEYS=''
    fi

    if [[ "$raw" != *@* ]] && [[ "$raw" != *:* ]]; then
        decoded=$(_outbound_base64_decode "$raw") || {
            _outbound_fail "SOCKS 整串 Base64 无效"
            return 1
        }
        [[ "$decoded" == *@* ]] || { _outbound_fail "SOCKS 整串 Base64 缺少用户信息"; return 1; }
        raw="$decoded"
    fi

    _outbound_split_url "${scheme}://$raw" || return 1
    [ -z "$_OB_PATH" ] || [ "$_OB_PATH" = "/" ] || { _outbound_fail "SOCKS 链接不能包含路径"; return 1; }
    _outbound_parse_hostport "$_OB_HOSTPORT" || return 1
    [ -n "$_OB_HP_PORT" ] || { _outbound_fail "SOCKS 链接缺少端口"; return 1; }
    _outbound_validate_port "$_OB_HP_PORT" || return 1
    port="$_OB_PORT_VALUE"

    if [ -n "$_OB_USERINFO" ]; then
        _outbound_percent_decode "$_OB_USERINFO" || return 1
        if [[ "$_OB_DECODED" == *:* ]]; then
            username="${_OB_DECODED%%:*}"
            password="${_OB_DECODED#*:}"
        else
            decoded=$(_outbound_base64_decode "$_OB_DECODED") || {
                _outbound_fail "SOCKS 认证 Base64 无效"
                return 1
            }
            [[ "$decoded" == *:* ]] || { _outbound_fail "SOCKS 认证缺少密码"; return 1; }
            username="${decoded%%:*}"
            password="${decoded#*:}"
        fi
        if [ -n "$username" ] && [ -z "$password" ]; then
            _outbound_fail "SOCKS 用户名和密码不能只填一个"
            return 1
        fi
        if [ -z "$username" ] && [ -n "$password" ]; then
            _outbound_fail "SOCKS 用户名和密码不能只填一个"
            return 1
        fi
    fi

    if [ -n "$username" ]; then
        _OB_OUTBOUND=$(jq -cn \
            --arg addr "$_OB_HP_HOST" \
            --argjson p "$port" \
            --arg user "$username" \
            --arg pass "$password" '
            {protocol:"socks",
             settings:{address:$addr, port:$p, user:$user, pass:$pass}}
        ') || { _outbound_fail "SOCKS 出口生成失败"; return 1; }
    else
        _OB_OUTBOUND=$(jq -cn \
            --arg addr "$_OB_HP_HOST" \
            --argjson p "$port" '
            {protocol:"socks",
             settings:{address:$addr, port:$p}}
        ') || { _outbound_fail "SOCKS 出口生成失败"; return 1; }
    fi
    _OB_PROTOCOL='socks'
    _OB_SERVER="$_OB_HP_HOST"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$fragment" || return 1
}

_outbound_mport_normalize() {
    local raw="$1" out='' item a b
    local -a items
    [ -n "$raw" ] || { _outbound_fail "mport 不能为空"; return 1; }
    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        item="${item// /}"
        [ -n "$item" ] || { _outbound_fail "mport 包含空范围"; return 1; }
        case "$item" in
            *-*)
                [[ "$item" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || { _outbound_fail "mport 范围格式无效"; return 1; }
                a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
                ;;
            *:*)
                [[ "$item" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]] || { _outbound_fail "mport 范围格式无效"; return 1; }
                a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
                ;;
            *)
                [[ "$item" =~ ^[0-9]{1,5}$ ]] || { _outbound_fail "mport 端口必须是十进制整数"; return 1; }
                a="$item"; b="$item"
                ;;
        esac
        a=$((10#$a)); b=$((10#$b))
        [ "$a" -ge 1 ] && [ "$a" -le 65535 ] && [ "$b" -ge 1 ] && [ "$b" -le 65535 ] || {
            _outbound_fail "mport 端口须在 1-65535"
            return 1
        }
        [ "$a" -le "$b" ] || { local t="$a"; a="$b"; b="$t"; }
        [ -n "$out" ] && out+=","
        if [ "$a" = "$b" ]; then out+="$a"; else out+="$a-$b"; fi
    done
    [ -n "$out" ] || { _outbound_fail "mport 不能为空"; return 1; }
    _OB_MPORT_VALUE="$out"
}

_outbound_bandwidth_value() {   # <value> <label>
    local v="${1,,}" label="$2" num unit
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [[ "$v" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)[[:space:]]*([a-z]*)$ ]] || {
        _outbound_fail "${label}格式无效，应为 100、0.5 或 100 mbps"
        return 1
    }
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
    [ -n "$unit" ] || unit=mbps
    case "$unit" in
        b|bps|k|kb|kbps|m|mb|mbps|g|gb|gbps|t|tb|tbps) ;;
        *)
            _outbound_fail "${label}单位无效"
            return 1
            ;;
    esac
    _hy2_brutal_rate_valid "$num $unit" false || {
        _outbound_fail "${label}非零时至少 512 kbps (0.5 mbps)"
        return 1
    }
    if jq -en --arg n "$num" '($n | tonumber) == 0' >/dev/null 2>&1; then
        _OB_BW_VALUE=''
    else
        _OB_BW_VALUE="$num $unit"
    fi
}

_outbound_hysteria_bandwidth() {
    local up='' down='' rc u='' d=''
    _outbound_alias_get "上行带宽" up upmbps
    rc=$?
    [ "$rc" -eq 0 ] && up="$_OB_PARAM_VALUE"
    [ "$rc" -eq 2 ] && return 1
    _outbound_alias_get "下行带宽" down downmbps
    rc=$?
    [ "$rc" -eq 0 ] && down="$_OB_PARAM_VALUE"
    [ "$rc" -eq 2 ] && return 1

    if [ -z "$up" ] && [ -z "$down" ]; then return 0; fi
    if [ -z "$up" ] || [ -z "$down" ]; then
        _outbound_fail "Hysteria2 的 up/down 必须同时提供"
        return 1
    fi
    _outbound_bandwidth_value "$up" "Hysteria2 up" || return 1
    u="$_OB_BW_VALUE"
    _outbound_bandwidth_value "$down" "Hysteria2 down" || return 1
    d="$_OB_BW_VALUE"
    if [ -z "$u$d" ]; then
        _OB_QUIC_JSON=''
        return 0
    fi
    _OB_QUIC_JSON=$(jq -cn --arg up "$u" --arg down "$d" '
        {congestion:"brutal"}
        + (if $up != "" then {brutalUp:$up} else {} end)
        + (if $down != "" then {brutalDown:$down} else {} end)
    ') || { _outbound_fail "Hysteria2 brutal 配置生成失败"; return 1; }
}

_outbound_parse_hysteria2() {
    local link="$1" password='' security_json port sni
    local obfs='' obfs_pw='' low='' high='' size='' masks_json='[]' finalmask=''
    local mport='' udp_idle='' hysteria_settings
    local -a masks=()
    local rc

    _outbound_split_url "$link" || return 1
    [ "$_OB_SCHEME" = hysteria2 ] || [ "$_OB_SCHEME" = hy2 ] || {
        _outbound_fail "不是 Hysteria2 链接"
        return 1
    }
    [ -n "$_OB_USERINFO" ] || { _outbound_fail "Hysteria2 链接缺少密码"; return 1; }
    _outbound_percent_decode "$_OB_USERINFO" || return 1
    password="$_OB_DECODED"
    [ -n "$password" ] || { _outbound_fail "Hysteria2 密码不能为空"; return 1; }
    [ -z "$_OB_PATH" ] || [ "$_OB_PATH" = "/" ] || { _outbound_fail "Hysteria2 链接路径无效"; return 1; }

    _outbound_parse_hostport "$_OB_HOSTPORT" || return 1
    if [ -n "$_OB_HP_PORT" ]; then
        _outbound_validate_port "$_OB_HP_PORT" || return 1
        port="$_OB_PORT_VALUE"
    else
        port=443
    fi

    _outbound_parse_query "$_OB_RAW_QUERY" || return 1
    _outbound_check_query sni peer servername insecure allowinsecure skip-cert-verify \
        obfs obfs-password obfs_password obfspassword minpacketsize maxpacketsize mport alpn \
        up down upmbps downmbps pinsha256 pcs pinnedpeercertsha256 pin-sha256 pin_sha256 \
        vcn verifypeercertbyname ech udpidletimeout fp || return 1

    if _outbound_q_get fp; then
        _outbound_fail "Hysteria2 是 QUIC 传输，不支持 fp/uTLS 指纹"
        return 1
    fi
    if _outbound_q_get security; then
        _outbound_fail "Hysteria2 不支持 security 参数"
        return 1
    fi
    _outbound_build_tls_settings tls "$_OB_HP_HOST" || return 1
    security_json="$_OB_SECURITY_JSON"
    sni="$_OB_SECURITY_SNI"

    if _outbound_get_opt obfs; then
        obfs="${_OB_OPT_VALUE,,}"
        case "$obfs" in
            salamander|gecko) ;;
            *) _outbound_fail "Hysteria2 混淆只支持 salamander/gecko"; return 1 ;;
        esac
        _outbound_alias_get "Hysteria2 混淆密码" obfs-password obfs_password obfspassword
        rc=$?
        [ "$rc" -eq 0 ] || { _outbound_fail "Hysteria2 启用混淆时必须提供 obfs-password"; return 1; }
        obfs_pw="$_OB_PARAM_VALUE"
        [ -n "$obfs_pw" ] || { _outbound_fail "Hysteria2 混淆密码不能为空"; return 1; }

        _outbound_int_get "Gecko 最小包长" 1 2048 minpacketsize
        rc=$?
        [ "$rc" -eq 0 ] && low="$_OB_INT_VALUE"
        [ "$rc" -eq 2 ] && return 1
        _outbound_int_get "Gecko 最大包长" 1 2048 maxpacketsize
        rc=$?
        [ "$rc" -eq 0 ] && high="$_OB_INT_VALUE"
        [ "$rc" -eq 2 ] && return 1
        if [ "$obfs" = salamander ]; then
            [ -z "$low$high" ] || { _outbound_fail "minPacketSize/maxPacketSize 只适用于 Gecko"; return 1; }
        else
            low="${low:-512}"
            high="${high:-1200}"
            [ "$low" -le "$high" ] || { _outbound_fail "Gecko 最小包长不能大于最大包长"; return 1; }
            size=$(_hy2_obfs_size_canon "${low}-${high}") || { _outbound_fail "Gecko packetSize 规范化失败"; return 1; }
        fi
        masks+=("$(jq -cn --arg pw "$obfs_pw" --arg size "$size" '
            {type:"salamander", settings:({password:$pw} + (if $size != "" then {packetSize:$size} else {} end))}
        ')") || { _outbound_fail "Hysteria2 混淆配置生成失败"; return 1; }
    else
        if _outbound_any_query obfs-password obfs_password obfspassword minpacketsize maxpacketsize; then
            _outbound_fail "Hysteria2 链接包含混淆参数，但没有 obfs 类型"
            return 1
        fi
    fi

    if _outbound_get_opt mport; then
        _outbound_mport_normalize "$_OB_OPT_VALUE" || return 1
        mport="$_OB_MPORT_VALUE"
        masks=("$(jq -cn --arg ports "$mport" '
            {type:"udphop", settings:{mode:"perconnremote", remotePorts:$ports}}
        ')" "${masks[@]}")
    fi

    _outbound_hysteria_bandwidth || return 1
    if _outbound_int_get "Hysteria2 udpIdleTimeout" 0 600 udpidletimeout; then
        case "$_OB_INT_VALUE" in
            0) ;;
            1)
                _outbound_fail "Hysteria2 udpIdleTimeout 只能为 0(默认) 或 2-600"
                return 1
                ;;
            *) udp_idle="$_OB_INT_VALUE" ;;
        esac
    else
        rc=$?
        [ "$rc" -eq 1 ] || return 1
    fi

    if [ ${#masks[@]} -gt 0 ]; then
        local m
        for m in "${masks[@]}"; do
            masks_json=$(jq -cn --argjson a "$masks_json" --argjson m "$m" '$a + [$m]') || {
                _outbound_fail "Hysteria2 FinalMask 生成失败"
                return 1
            }
        done
    fi
    if [ "$masks_json" != '[]' ] || [ -n "$_OB_QUIC_JSON" ]; then
        finalmask=$(jq -cn \
            --argjson udp "$masks_json" \
            --argjson quic "${_OB_QUIC_JSON:-null}" '
            {}
            + (if ($udp | length) > 0 then {udp:$udp} else {} end)
            + (if $quic != null then {quicParams:$quic} else {} end)
        ') || { _outbound_fail "Hysteria2 FinalMask 生成失败"; return 1; }
    fi

    hysteria_settings=$(jq -cn --arg auth "$password" --argjson idle "${udp_idle:-null}" '
        {version:2, auth:$auth}
        + (if $idle != null then {udpIdleTimeout:$idle} else {} end)
    ') || { _outbound_fail "Hysteria2 传输配置生成失败"; return 1; }

    _OB_STREAM_JSON=$(jq -cn \
        --argjson tls "$security_json" \
        --argjson hs "$hysteria_settings" \
        --argjson fm "${finalmask:-null}" '
        {network:"hysteria", security:"tls", tlsSettings:$tls, hysteriaSettings:$hs}
        + (if $fm != null then {finalmask:$fm} else {} end)
    ') || { _outbound_fail "Hysteria2 streamSettings 生成失败"; return 1; }

    _OB_OUTBOUND=$(jq -cn \
        --arg addr "$_OB_HP_HOST" \
        --argjson p "$port" \
        --argjson stream "$_OB_STREAM_JSON" '
        {protocol:"hysteria",
         settings:{version:2, address:$addr, port:$p},
         streamSettings:$stream}
    ') || { _outbound_fail "Hysteria2 出口生成失败"; return 1; }
    _OB_PROTOCOL='hysteria2'
    _OB_SERVER="$_OB_HP_HOST"
    _OB_PORT="$port"
    _outbound_set_tag_from_fragment "$_OB_FRAGMENT" || return 1
}

# ---------------------------------------------------------------------------
# 批量解析
# ---------------------------------------------------------------------------

_outbound_append_link() {
    local cleaned
    cleaned=$(printf '%s' "$1" | sed -E 's/^[[:space:],;，；]+//; s/[[:space:],;，；]+$//')
    [ -n "$cleaned" ] || return 0
    _OB_LINKS+=("$cleaned")
}

_outbound_split_line_links() {
    local rest="$1" current='' before scheme
    while [ -n "$rest" ]; do
        if [[ "$rest" =~ $_OB_LINK_SCHEME_RE ]]; then
            scheme="${BASH_REMATCH[0]}"
            before="${rest%%"$scheme"*}"
            if [ -n "$current" ]; then
                _outbound_append_link "$current$before"
            elif [ -n "$before" ]; then
                _outbound_append_link "$before"
            fi
            current="$scheme"
            rest="${rest#*"$scheme"}"
        else
            current+="$rest"
            rest=''
        fi
    done
    [ -z "$current" ] || _outbound_append_link "$current"
}

_outbound_collect_links() {
    local text="$1" compact decoded depth=0 line
    local nocase=0
    _OB_LINKS=()
    text="${text#$'\xef\xbb\xbf'}"
    while :; do
        compact=$(printf '%s' "$text" | tr -d '[:space:]')
        [ -n "$compact" ] || { _outbound_fail "分享链接不能为空"; return 1; }
        case "$compact" in *://*) break ;; esac
        [ "$depth" -lt 3 ] || { _outbound_fail "Base64 分享链接嵌套层数过多"; return 1; }
        decoded=$(_outbound_base64_decode "$compact") || { _outbound_fail "Base64 内容无法解码"; return 1; }
        case "$decoded" in
            *://*) text="$decoded" ;;
            *) _outbound_fail "Base64 内容不是分享链接"; return 1 ;;
        esac
        depth=$((depth + 1))
    done

    text="${text//$'\r\n'/$'\n'}"
    text="${text//$'\r'/$'\n'}"
    text="${text//，/$'\n'}"
    text="${text//；/$'\n'}"
    shopt -q nocasematch && nocase=1
    shopt -s nocasematch
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _outbound_split_line_links "$line"
    done <<< "$text"
    [ "$nocase" -eq 1 ] || shopt -u nocasematch
    [ ${#_OB_LINKS[@]} -gt 0 ] || { _outbound_fail "分享链接不能为空"; return 1; }
}

_outbound_parse_link() {
    local link="$1" scheme rest
    _OB_ERR=''
    _OB_TAG=''
    _OB_PROTOCOL=''
    _OB_SERVER=''
    _OB_PORT=0
    _OB_OUTBOUND=''
    _OB_STREAM_JSON=''
    _OB_NETWORK=''
    _OB_TRANSPORT_JSON=''
    _OB_SECURITY_JSON='{}'
    _OB_SECURITY_SNI=''
    _OB_QUIC_JSON=''

    link="${link#$'\xef\xbb\xbf'}"
    [ -n "$link" ] || { _outbound_fail "分享链接不能为空"; return 1; }
    if printf '%s' "$link" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "分享链接不能包含换行或控制字符"
        return 1
    fi
    case "$link" in
        *'://'*) ;;
        *) _outbound_fail "无法识别分享链接协议"; return 1 ;;
    esac
    scheme="${link%%://*}"
    scheme="${scheme,,}"
    rest="${link#*://}"
    link="${scheme}://${rest}"

    case "$scheme" in
        hysteria2|hy2) _outbound_parse_hysteria2 "$link" ;;
        vless) _outbound_parse_vless "$link" ;;
        vmess) _outbound_parse_vmess "$link" ;;
        trojan) _outbound_parse_trojan "$link" ;;
        ss) _outbound_parse_ss "$link" ;;
        socks|socks5) _outbound_parse_socks "$link" ;;
        anytls|tuic|hysteria|shadowtls|naive+https|ssr|trojan-go|http|https)
            _outbound_fail "暂不支持 ${scheme}:// 链接；当前支持 ${_OB_SUPPORTED_TEXT}"
            return 1
            ;;
        *)
            _outbound_fail "无法识别分享链接协议；当前支持 ${_OB_SUPPORTED_TEXT}"
            return 1
            ;;
    esac || return 1
    [ -n "$_OB_OUTBOUND" ] || { _outbound_fail "内部错误: 未生成出口"; return 1; }
}

_outbound_parse_batch() {
    if [ "$#" -eq 0 ]; then
        _outbound_fail "分享链接不能为空"
        return 1
    fi
    local text="$1" arg link index=0 skipped=0 total why
    shift || true
    for arg in "$@"; do text+=$'\n'"$arg"; done

    _OB_BATCH='[]'
    _OB_COUNT=0
    _OB_SKIPPED=0
    _OB_DEFAULT_TAGS=()
    _OB_PROTOCOLS=()
    _OB_SERVERS=()
    _OB_PORTS=()

    _outbound_collect_links "$text" || return 1
    total=${#_OB_LINKS[@]}
    for link in "${_OB_LINKS[@]}"; do
        index=$((index + 1))
        if ! _outbound_parse_link "$link"; then
            why="${_OB_ERR:-解析失败}"
            if [ "$total" -eq 1 ]; then
                _outbound_fail "第 ${index} 条: ${why}"
                return 1
            fi
            skipped=$((skipped + 1))
            _warn "已跳过第 ${index} 条: ${why}"
            continue
        fi
        _OB_BATCH=$(jq -cn \
            --argjson b "$_OB_BATCH" \
            --argjson o "$_OB_OUTBOUND" \
            --arg tag "$_OB_TAG" \
            --arg protocol "$_OB_PROTOCOL" \
            --arg server "$_OB_SERVER" \
            --argjson port "$_OB_PORT" '
            $b + [{tag:$tag, protocol:$protocol, server:$server, port:$port, outbound:$o}]
        ') || { _outbound_fail "构造解析结果失败"; return 1; }
        _OB_DEFAULT_TAGS+=("$_OB_TAG")
        _OB_PROTOCOLS+=("$_OB_PROTOCOL")
        _OB_SERVERS+=("$_OB_SERVER")
        _OB_PORTS+=("$_OB_PORT")
        _OB_COUNT=$((_OB_COUNT + 1))
    done
    _OB_SKIPPED="$skipped"
    [ "$_OB_COUNT" -gt 0 ] || {
        _outbound_fail "没有可导入的有效链接"
        return 1
    }
    [ "$skipped" -eq 0 ] || _warn "已跳过 ${skipped} 条无法解析的链接"
}

# ---------------------------------------------------------------------------
# tag 与提交
# ---------------------------------------------------------------------------

_outbound_tag_valid() {
    local tag="$1"
    [ -n "$tag" ] || { _outbound_fail "出口 tag 不能为空"; return 1; }
    [ "${#tag}" -le "$_OB_MAX_TAG_LENGTH" ] || {
        _outbound_fail "出口 tag 最长 ${_OB_MAX_TAG_LENGTH} 个字符"
        return 1
    }
    case "$tag" in
        */*|*\\*) _outbound_fail "出口 tag 不能包含 / 或 \\"; return 1 ;;
        [[:space:]]*|*[[:space:]]) _outbound_fail "出口 tag 首尾不能有空白"; return 1 ;;
    esac
    if printf '%s' "$tag" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "出口 tag 不能包含控制字符"
        return 1
    fi
    case "$tag" in
        direct|block|warp) _outbound_fail "出口 tag 是保留名称: $tag"; return 1 ;;
    esac
}

_outbound_tag_exists() {
    local tag="$1"
    _config_jq -e --arg t "$tag" \
        '[(.inbounds[]?.tag // empty), (.outbounds[]?.tag // empty)] | index($t) != null' \
        >/dev/null 2>&1
}

_outbound_accept_tag() {
    local tag="$1" seen
    _outbound_tag_valid "$tag" || return 1
    if _outbound_tag_exists "$tag"; then
        _outbound_fail "出口 tag 已存在: $tag，请换一个"
        return 1
    fi
    if [ ${#_OB_ACCEPTED_TAGS[@]} -gt 0 ]; then
        for seen in "${_OB_ACCEPTED_TAGS[@]}"; do
            if [ "$seen" = "$tag" ]; then
                _outbound_fail "本次添加的出口 tag 重复: $tag，请换一个"
                return 1
            fi
        done
    fi
}

_outbound_read_link_inputs() {   # <first line>
    local line
    _OB_INPUTS=("$1")
    _OB_PREFETCH=''
    _OB_PREFETCH_SET=false
    while IFS= read -r -t 1 line; do
        line="${line%$'\r'}"
        if [ -n "$line" ]; then
            if [[ "$line" == *"://"* ]]; then
                _OB_INPUTS+=("$line")
            else
                _OB_PREFETCH="$line"
                _OB_PREFETCH_SET=true
                return 0
            fi
        else
            _OB_PREFETCH_SET=true
            return 0
        fi
    done
    return 0
}

_outbound_prompt_tag() {
    local label="$1" default="$2" input
    while :; do
        if [ "$_OB_PREFETCH_SET" = true ]; then
            input="$_OB_PREFETCH"
            _OB_PREFETCH=''
            _OB_PREFETCH_SET=false
            input="${input%$'\r'}"
            [ -n "$input" ] || input="$default"
        elif [ -n "$default" ]; then
            read -e -r -p "  ${label} (默认 ${default}): " input || {
                _warn "输入已结束, 已取消"
                return 1
            }
            input="${input%$'\r'}"
            input="${input:-$default}"
        else
            read -e -r -p "  ${label} (链接没有可用 tag, 必须输入): " input || {
                _warn "输入已结束, 已取消"
                return 1
            }
            input="${input%$'\r'}"
        fi
        if _outbound_accept_tag "$input"; then
            _OB_TAG_INPUT="$input"
            return 0
        fi
        _error "$_OB_ERR"
    done
}

_outbound_commit() {
    local obs="$1"
    printf '%s' "$obs" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || {
        _error "候选出口无效"
        return 1
    }
    _mutate_config --argjson obs "$obs" '
        . as $cfg
        | ($cfg.outbounds // []) as $cur
        | if ($cur | type) != "array" then error("当前配置的 outbounds 不是数组")
          else
            ($obs | map(.tag)) as $new
            | ([ $cfg.inbounds[]?.tag, $cur[]?.tag ] | map(select(. != null))) as $used
            | if ($new | length) != ($new | unique | length) then error("本次出口 tag 重复")
              elif any($new[]; . as $t | $used | index($t) != null) then error("出口 tag 已被占用")
              else .outbounds = ($cur + $obs)
              end
          end
    '
}

_outbound_add_prompt() {
    clear
    echo
    echo -e "  ${CYAN}【添加出口 — 导入分享链接】${NC}"
    _info "支持 ${_OB_SUPPORTED_TEXT}"
    _info "识别后只追加 outbounds，不修改默认路由或现有分流规则"
    _info "一次可粘贴一条或多条链接，也支持 v2rayN 的 Base64 整段"
    [ -x "$XRAY_BIN" ] || {
        _error "Xray 未安装, 请先到主菜单的 [Xray 核心管理] 安装核心"
        return 1
    }
    _config_present || { _error "配置不存在, 请先初始化配置或添加节点"; return 1; }
    _config_jq -e 'type == "object"' >/dev/null 2>&1 || {
        _error "当前配置无法解析, 拒绝添加出口"
        return 1
    }

    local first
    read -e -r -p "  分享链接: " first || { _warn "输入已结束, 已取消"; return 1; }
    first="${first%$'\r'}"
    _outbound_read_link_inputs "$first"
    _outbound_parse_batch "${_OB_INPUTS[@]}" || {
        _OB_PREFETCH=''
        _OB_PREFETCH_SET=false
        _error "$_OB_ERR"
        return 1
    }

    local i count="$_OB_COUNT"
    _info "已识别 ${count} 个出口"
    for ((i = 0; i < count; i++)); do
        _info "[$((i + 1))/${count}] ${_OB_PROTOCOLS[$i]}: ${_OB_SERVERS[$i]}:${_OB_PORTS[$i]}"
    done

    _OB_ACCEPTED_TAGS=()
    local -a tags=()
    local label
    for ((i = 0; i < count; i++)); do
        label='出口 tag'
        [ "$count" -eq 1 ] || label="出口 tag [$((i + 1))/${count}]"
        _outbound_prompt_tag "$label" "${_OB_DEFAULT_TAGS[$i]}" || return 1
        tags+=("$_OB_TAG_INPUT")
        _OB_ACCEPTED_TAGS+=("$_OB_TAG_INPUT")
    done

    local tags_json joined outbounds_json
    tags_json=$(jq -cn '$ARGS.positional' --args "${tags[@]}") || {
        _error "构造出口 tag 列表失败"
        return 1
    }
    outbounds_json=$(jq -cn --argjson batch "$_OB_BATCH" --argjson tags "$tags_json" '
        [range(0; ($batch | length)) as $i | $batch[$i].outbound + {tag:$tags[$i]}]
    ') || { _error "构造出口失败"; return 1; }

    joined=$(printf '%s, ' "${tags[@]}")
    joined="${joined%, }"
    if [ "$count" -eq 1 ]; then
        _info "将添加出口: ${joined}；不会修改默认路由或分流规则"
    else
        _info "将添加 ${count} 个出口: ${joined}；不会修改默认路由或分流规则"
    fi
    local ans
    read -e -r -p "  确认添加? [y/N]: " ans || {
        _warn "输入已结束, 已取消"
        return 1
    }
    ans="${ans%$'\r'}"
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; return 0 ;;
    esac

    _outbound_commit "$outbounds_json" || {
        _error "出口写入失败, 配置未改变"
        return 1
    }
    if [ "$count" -eq 1 ]; then
        _success "出口已添加: ${joined}；routing 未改变"
    else
        _success "已添加 ${count} 个出口: ${joined}；routing 未改变"
    fi
}
