#!/bin/bash
# lib/35-warp.sh — WARP 自动注册与 Xray WireGuard/MASQUE 出站。
# 账号类型: 免费 WARP / WARP+ license / Zero Trust team token。
# WireGuard 免费账号按 warp-reg.sh → wgcf-cli → 注册 API 回退; WARP+、Zero Trust 与 MASQUE 直接走 Cloudflare 设备注册 API。
# 配置唯一事实来源是 confs 里的 Xray 片段: 注册结果保存在 tag=warp 出站里。
# 写入一律走 _mutate_config(定义在 50 模块, 调用时才解析); 见 _warp_apply / _warp_delete。

WARP_TAG="warp"
WARP_DEFAULT_PORT="2408"
WARP_REG_SCRIPT_URL="https://raw.githubusercontent.com/chise0713/warp-reg.sh/master/warp-reg.sh"
WARP_WGCF_URL="https://github.com/ArchiveNetwork/wgcf-cli/releases/download/v0.3.6"
WARP_API_URL="https://warp.cloudflare.now.cc/?run=register&format=xray"
# Cloudflare 设备管理 API 与 usque v4.2.1 对齐; MASQUE H2 按账号类型选择 anycast 段。
WARP_API_BASE="https://api.cloudflareclient.com/v0a4471"
WARP_MASQUE_ENDPOINT="162.159.198.2"
WARP_MASQUE_ENDPOINT_PLUS="162.159.199.2"
WARP_MASQUE_ENDPOINT_TEAM="162.159.197.2"
WARP_MASQUE_PORT="443"
# usque README 推荐使用 zt-masque; consumer-masque 虽可用但在部分网络会被重置。
WARP_MASQUE_SERVER_NAME="zt-masque.cloudflareclient.com"
_WARP_REASON=""
_WARP_HTTP_CODE=""

# 归一/生成共用的 jq 定义: 内部表示字段名与类型固定, 缺必填字段或非法 reserved 一律 error 退出。
# reserved 按官方文档是可选项(默认全 0), 省略时补 [0,0,0]; mtu 缺省取 1280 是 Cloudflare WARP 的
# 推荐值(也是 wgcf 的输出值), Xray WireGuard 出站的通用默认是 1420。
# (error 让 jq 非零退出且不产生输出, 满足"失败时 stdout 为空")。
# 注册端点无论上游只返回 v4、只返回 v6 还是双栈, 都统一使用 engage.cloudflareclient.com,
# 由 Xray 内置 DNS 选择; Xray WireGuard 出站的 endpoint 支持域名。
_WARP_NORM_JQ='
def fld($k): if (type == "object") then (.[$k] // null) else null end;
def hasstr($k): ((fld($k) | type) == "string") and ((fld($k) // "") != "");
def warpdomain: "engage.cloudflareclient.com";
def arr($v): if ($v | type) == "array" then $v
             elif (($v | type) == "string") and $v != "" then [$v]
             else [] end;
def addrmask: if test("/") then . else (if test(":") then . + "/128" else . + "/32" end) end;
def wgs:
  if (type == "object") and ((.settings | type) == "object") and ((.settings.secretKey | type) == "string") then .settings
  elif (type == "object") and ((.outbounds | type) == "array") then ([.outbounds[] | select((.settings.secretKey | type) == "string")][0].settings // null)
  elif (type == "object") and ((.config | type) == "object") and ((.config.outbounds | type) == "array") then ([.config.outbounds[] | select((.settings.secretKey | type) == "string")][0].settings // null)
  elif (type == "object") and ((.data | type) == "object") and ((.data.settings | type) == "object") and ((.data.settings.secretKey | type) == "string") then .data.settings
  elif (type == "object") and ((.data | type) == "object") and ((.data.outbounds | type) == "array") then ([.data.outbounds[] | select((.settings.secretKey | type) == "string")][0].settings // null)
  elif (type == "object") and ((.secretKey | type) == "string") then .
  else null end;
def wgcheck:
  if (type == "object") then . else error("归一对象必须是 object") end
  | . as $o
  | if (($o.secretKey | type) == "string") and ($o.secretKey != "") then . else error("缺少 secretKey") end
  | if (($o.address | type) == "array") and (($o.address | length) > 0)
       and (([$o.address[] | select((type == "string") and (. != ""))] | length) == ($o.address | length))
    then . else error("address 非法") end
  | if (($o.publicKey | type) == "string") and ($o.publicKey != "") then . else error("缺少 publicKey") end
  | if (($o.endpoint | type) == "string") and ($o.endpoint != "") then . else error("缺少 endpoint") end
  | if (($o.allowedIPs | type) == "array") and (($o.allowedIPs | length) > 0) then . else error("allowedIPs 非法") end
  | if (($o.reserved | type) == "array") and (($o.reserved | length) == 3)
       and (([$o.reserved[] | select((type == "number") and (. == floor) and (. >= 0) and (. <= 255))] | length) == 3)
    then . else error("reserved 必须是 3 个 0-255 整数") end
  | if (($o.mtu | type) == "number") and ($o.mtu > 0) and ($o.mtu <= 65535) and (($o.mtu | floor) == $o.mtu)
    then . else error("mtu 非法") end;
def masquecheck:
  if (type == "object") then . else error("MASQUE 归一对象必须是 object") end
  | . as $o
  | if hasstr("privateKey") then . else error("缺少 privateKey") end
  | if hasstr("publicKey") then . else error("缺少 publicKey") end
  | if (($o.address | type) == "array") and (($o.address | length) > 0)
       and (([$o.address[] | select((type == "string") and (. != ""))] | length) == ($o.address | length))
    then . else error("MASQUE address 非法") end
  | if hasstr("server") then . else error("缺少 server") end
  | if (($o.port | type) == "number") and ($o.port >= 1) and ($o.port <= 65535)
       and (($o.port | floor) == $o.port)
    then . else error("MASQUE port 非法") end
  | if hasstr("serverName") then . else error("缺少 serverName") end
  | if (($o.alpn | type) == "array") and (($o.alpn | length) > 0)
    then . else error("MASQUE alpn 非法") end;
def reg2norm:
  . as $r
  | {
      secretKey: (($r | fld("private_key")) | if type == "string" then . else "" end),
      address: ([ ($r | fld("v4")), ($r | fld("v6")),
                  ($r | fld("addresses") | fld("v4")), ($r | fld("addresses") | fld("v6")) ]
                | map(select((type == "string") and (. != ""))) | unique | map(addrmask)),
      reserved: (($r | fld("reserved_dec")) | if type == "null" then [0, 0, 0]
                  elif type == "array" then . else error("reserved_dec 必须是数组") end),
      endpoint: (($r | fld("endpoint"))
                 | if type == "object" then
                     (if (hasstr("v4") or hasstr("v6")) then warpdomain else "" end)
                   elif type == "string" then .
                   else "" end),
      publicKey: (($r | fld("public_key")) | if type == "string" then . else "" end),
      allowedIPs: ["0.0.0.0/0", "::/0"],
      mtu: 1280
    }
  | wgcheck;
# 账号注册 (WARP+ / Zero Trust) 的原始响应; 私钥与 reserved 由注册流程另行生成。
def wgacct2norm:
  . as $r
  | (($r.response // {}) | .config // {}) as $c
  | (($c.peers // [])[0] // {}) as $p
  | (($c.interface // {}).addresses // {}) as $a
  | {
      secretKey: (($r.privateKey // "") | if type == "string" then . else "" end),
      address: ([$a.v4, $a.v6] | map(select((type == "string") and (. != ""))) | map(addrmask)),
      reserved: ($r.reserved // []),
      endpoint: (if ($p.endpoint | type) == "string" then $p.endpoint
                 elif (($p.endpoint.v4 // "") != "") then $p.endpoint.v4
                 elif (($p.endpoint.v6 // "") != "") then $p.endpoint.v6
                 elif (($p.endpoint.host // "") != "") then $p.endpoint.host
                 else "" end),
      publicKey: (($p.public_key // "") | if type == "string" then . else "" end),
      allowedIPs: ["0.0.0.0/0", "::/0"],
      mtu: 1280
    }
  | wgcheck;
# Xray 出站形态的 endpoint 已是单值, 保持上游返回值, 不套用注册端点域名规则。
def out2norm:
  wgs as $s
  | if ($s | type) != "object" then error("不是 Xray WireGuard 出站结构") else . end
  | ($s.peers | if (type == "array") and (length > 0) and ((.[0] | type) == "object") then .[0] else {} end) as $p
  | {
      secretKey: ($s.secretKey | if type == "string" then . else "" end),
      address: (arr($s.address) | map(select((type == "string") and (. != ""))) | map(addrmask)),
      reserved: ($s.reserved | if type == "null" then [0, 0, 0]
                  elif type == "array" then . else error("reserved 必须是数组") end),
      endpoint: ($p.endpoint | if type == "string" then . else "" end),
      publicKey: ($p.publicKey | if type == "string" then . else "" end),
      allowedIPs: (arr($p.allowedIPs) | if length > 0 then . else ["0.0.0.0/0", "::/0"] end),
      mtu: (if ($s.mtu | type) == "number" then $s.mtu else 1280 end)
    }
  | wgcheck;
def masque2norm:
  . as $r
  | ($r.response // {}) as $a
  | ($a.config.interface.addresses // {}) as $i
  | ($a.config.peers[0] // {}) as $p
  | {
      kind: "masque",
      privateKey: (($r.privateKey // "") | if type == "string" then gsub("[[:space:]]"; "") else "" end),
      publicKey: ($p.public_key // ""),
      address: ([$i.v4, $i.v6] | map(select((type == "string") and (. != ""))) | map(addrmask)),
      server: $server,
      port: $port,
      serverName: $sni,
      alpn: ["h2"]
    }
  | masquecheck;
'

# ---------------------------------------------------------------------------
# endpoint 规范化: v6 必须带方括号, 裸 IP 补默认端口(WireGuard 2408 / MASQUE 443),
# 端口 0 视为未指定。用法: ep=$(_warp_endpoint_norm "<来源 endpoint>" [默认端口])
# ---------------------------------------------------------------------------
_warp_endpoint_norm() {
    local ep="${1:-}" default_port="${2:-$WARP_DEFAULT_PORT}" host="" port="" p
    ep="${ep#"${ep%%[![:space:]]*}"}"
    ep="${ep%"${ep##*[![:space:]]}"}"
    [ -n "$ep" ] || return 1
    if [ "${ep:0:1}" = "[" ]; then
        [[ "$ep" =~ ^\[([^]]+)\](:([0-9]+))?$ ]] || return 1
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        [[ "$host" == *:* ]] || return 1
    elif [[ "$ep" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$ep" == *:* ]]; then
        # 多个冒号且无端口后缀: 裸 IPv6。不允许点分 IPv4 混入; 非压缩形式必须是 8 组。
        [[ "$ep" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        case "$ep" in
            *::*) ;;
            *) [ "${ep//[^:]/}" = ":::::::" ] || return 1 ;;
        esac
        host="$ep"
    else
        host="$ep"
    fi
    [ -n "$host" ] || return 1
    [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    if [ -z "$port" ] || [ "$port" = "0" ]; then
        port="$default_port"
    fi
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    p=$((10#$port))
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    if [[ "$host" == *:* ]]; then
        printf '[%s]:%d' "$host" "$p"
    else
        printf '%s:%d' "$host" "$p"
    fi
}

# 账号类型对应的 MASQUE 端点; WireGuard 使用注册响应里的 endpoint。
_warp_masque_endpoint() {   # [free|plus|team]
    case "${1:-free}" in
        plus) printf '%s' "$WARP_MASQUE_ENDPOINT_PLUS" ;;
        team) printf '%s' "$WARP_MASQUE_ENDPOINT_TEAM" ;;
        *) printf '%s' "$WARP_MASQUE_ENDPOINT" ;;
    esac
}

_warp_account_label() {   # [free|plus|team]
    case "${1:-free}" in
        plus) printf 'WARP+' ;;
        team) printf 'Zero Trust' ;;
        *) printf '免费 WARP' ;;
    esac
}

_warp_valid_license() {
    [[ "${1:-}" =~ ^[0-9A-Za-z]{8}-[0-9A-Za-z]{8}-[0-9A-Za-z]{8}$ ]]
}

_warp_valid_team_token() {
    local token="${1:-}"
    [ -n "$token" ] || return 1
    case "$token" in
        *[[:space:]\"\\]*) return 1 ;;
    esac
    [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

# 归一收尾: endpoint 交给 bash 规范化后回写, 其余字段原样保留。失败不输出任何内容。
_warp_finalize() {   # <候选内部表示 JSON>
    local obj="${1:-}" kind ep out
    [ -n "$obj" ] || return 1
    kind=$(printf '%s' "$obj" | jq -r '.kind // ""' 2>/dev/null) || return 1
    if [ "$kind" = "masque" ]; then
        printf '%s\n' "$obj"
        return 0
    fi
    ep=$(printf '%s' "$obj" | jq -r '.endpoint // ""' 2>/dev/null) || return 1
    ep=$(_warp_endpoint_norm "$ep") || return 1
    out=$(printf '%s' "$obj" | jq -c --arg ep "$ep" '.endpoint = $ep' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# 获取: 原始响应只写入 <outfile>, 不写 stdout。成功返回 0, 失败返回 1。
# ---------------------------------------------------------------------------
# WARP 专用 HTTPS 下载: 保留 HTTP 状态码和响应体, 失败时用于说明原因。
_warp_http_get() {   # <url> <dest> [timeout_sec]
    local url="${1:-}" dest="${2:-}" timeout_s="${3:-25}" code=""
    _WARP_HTTP_CODE=""
    case "$url" in https://*) ;; *) return 1 ;; esac
    [ -n "$dest" ] || return 1
    : > "$dest" || return 1
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -sSL --proto '=https' --proto-redir '=https' --max-redirs 5 \
            --connect-timeout 8 --max-time "$timeout_s" -o "$dest" -w '%{http_code}' "$url" 2>/dev/null) || {
            _WARP_HTTP_CODE="$code"
            return 1
        }
        _WARP_HTTP_CODE="$code"
        case "$code" in 2*) ;; *) return 1 ;; esac
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T "$timeout_s" -O "$dest" "$url" 2>/dev/null || {
            _WARP_HTTP_CODE="000"
            return 1
        }
        _WARP_HTTP_CODE="000"
    else
        return 1
    fi
    [ -s "$dest" ]
}

_warp_http_reason() {   # <dest>
    local out="${1:-}" msg=""
    [ -s "$out" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        msg=$(jq -r '(.error // .message // empty) | if type == "string" then . else tostring end' "$out" 2>/dev/null) || msg=""
    fi
    if [ -z "$msg" ]; then
        msg=$(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')
        msg="${msg#"${msg%%[![:space:]]*}"}"
        msg="${msg%"${msg##*[![:space:]]}"}"
    fi
    [ -n "$msg" ] || return 1
    if [ -n "${_WARP_HTTP_CODE:-}" ] && [ "$_WARP_HTTP_CODE" != "000" ]; then
        printf 'HTTP %s: %s' "$_WARP_HTTP_CODE" "$msg"
    else
        printf '%s' "$msg"
    fi
}

# 外部注册工具可能因网络半开阻塞; timeout 可用时统一限时, 不可用时保持原行为。
_warp_run() {   # <timeout_sec> <cmd...>
    local timeout_s="${1:-30}" kind=""
    shift
    [ "$#" -gt 0 ] || return 1
    kind=$(type -t "$1" 2>/dev/null) || kind=""
    case "$kind" in
        function|builtin)
            "$@" </dev/null
            return $?
            ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

# warp-reg.sh 在缺 xxd/python3 时会先向 stdout 打印安装提示; 从首个 JSON 起点开始保留。
_warp_trim_reg_output() {   # <outfile>
    local out="${1:-}" tmp
    [ -n "$out" ] && [ -f "$out" ] || return 1
    tmp="$out.trim"
    awk 'seen || /^[[:space:]]*\{/ { seen=1; print }' "$out" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$out" || {
        rm -f "$tmp"
        return 1
    }
}

# warp-reg.sh: 优先本机命令; 本机失败或不存在时取 GitHub 脚本再执行。
_warp_fetch_warp_reg() {
    local out="${1:-}" script rc=0 local_failed=0
    [ -n "$out" ] || { _WARP_REASON="未指定输出文件"; return 1; }
    _WARP_REASON=""
    if command -v warp-reg >/dev/null 2>&1; then
        _warp_run 30 warp-reg >"$out" 2>/dev/null || { rc=1; local_failed=1; }
    elif command -v warp-reg.sh >/dev/null 2>&1; then
        _warp_run 30 warp-reg.sh >"$out" 2>/dev/null || { rc=1; local_failed=1; }
    fi
    if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
        _warp_trim_reg_output "$out" || { _WARP_REASON="warp-reg 输出无法读取"; return 1; }
        [ -s "$out" ] && return 0
        _WARP_REASON="warp-reg 未返回注册结果"
    elif [ "$local_failed" -eq 1 ]; then
        _WARP_REASON="本机 warp-reg 执行失败"
    fi

    if command -v apk >/dev/null 2>&1; then
        _WARP_REASON="远程 warp-reg.sh 不支持 Alpine apk"
        return 1
    fi
    _WARP_REASON=""
    rc=0
    script=$(mktemp) || { _WARP_REASON="无法创建临时文件"; return 1; }
    if _warp_http_get "$WARP_REG_SCRIPT_URL" "$script" 20; then
        _warp_run 30 bash "$script" >"$out" 2>/dev/null || rc=1
    else
        rc=1
        _WARP_REASON=$(_warp_http_reason "$script") || _WARP_REASON="下载 warp-reg 脚本失败"
    fi
    rm -f "$script"
    if [ "$rc" -ne 0 ]; then
        [ -n "$_WARP_REASON" ] || _WARP_REASON="warp-reg 脚本执行失败"
        [ "$local_failed" -eq 0 ] || _WARP_REASON="本机 warp-reg 执行失败, $_WARP_REASON"
        return 1
    fi
    [ -s "$out" ] || { _WARP_REASON="warp-reg 未返回注册结果"; return 1; }
    _warp_trim_reg_output "$out" || { _WARP_REASON="warp-reg 输出无法读取"; return 1; }
    [ -s "$out" ] || { _WARP_REASON="warp-reg 未返回注册结果"; return 1; }
    return 0
}

# wgcf-cli release 只有 tar.zstd; 缺少 zstd 时按需安装, 解压用 zstd + tar 兼容 busybox tar。
_warp_install_wgcf_cli() {   # <tempdir>
    local dir="${1:-}" machine archive tarfile url
    _WARP_WGCF_TOOL=""
    _WARP_REASON=""
    [ -n "$dir" ] && [ -d "$dir" ] || { _WARP_REASON="wgcf-cli 临时目录不可用"; return 1; }
    case "$(uname -m)" in
        x86_64|amd64) machine="64" ;;
        i386|i686) machine="32" ;;
        aarch64|arm64) machine="arm64-v8a" ;;
        armv7l|armv7) machine="arm32-v7a" ;;
        *) _WARP_REASON="当前架构没有可用的 wgcf-cli"; return 1 ;;
    esac
    if ! command -v zstd >/dev/null 2>&1; then
        command -v _pkg_install >/dev/null 2>&1 || { _WARP_REASON="缺少 zstd, 无法解压 wgcf-cli"; return 1; }
        _pkg_install zstd || { _WARP_REASON="安装 zstd 失败"; return 1; }
    fi
    archive="$dir/wgcf-cli.tar.zstd"
    tarfile="$dir/wgcf-cli.tar"
    url="$WARP_WGCF_URL/wgcf-cli-linux-$machine.tar.zstd"
    _warp_http_get "$url" "$archive" 30 || {
        _WARP_REASON=$(_warp_http_reason "$archive") || _WARP_REASON="下载 wgcf-cli 失败"
        return 1
    }
    zstd -d -q -f "$archive" -o "$tarfile" >/dev/null 2>&1 || { _WARP_REASON="解压 wgcf-cli 失败"; return 1; }
    tar -xf "$tarfile" -C "$dir" >/dev/null 2>&1 || { _WARP_REASON="解压 wgcf-cli 失败"; return 1; }
    [ -f "$dir/wgcf-cli" ] || { _WARP_REASON="wgcf-cli 包内缺少可执行文件"; return 1; }
    chmod +x "$dir/wgcf-cli" || { _WARP_REASON="wgcf-cli 无法执行"; return 1; }
    _WARP_WGCF_TOOL="$dir/wgcf-cli"
}

# wgcf-cli: 在同一临时目录内先取注册 JSON, 再退回 generate --xray 的产物。
# register 把含 WARP 私钥的 wgcf.json 写在当前目录, 所以 register 与 generate 都只在 mktemp 目录内运行,
# 目录随后整体删除: 调用者当前目录不留账号文件, generate 也能读到 register 生成的账号。
# 本机没有该命令时取 GitHub release 临时副本, 不写入系统 PATH。
_warp_fetch_wgcf_cli() {
    local out="${1:-}" dir f tool have_reg=0
    [ -n "$out" ] || { _WARP_REASON="未指定输出文件"; return 1; }
    _WARP_REASON=""
    dir=$(mktemp -d) || { _WARP_REASON="无法创建临时目录"; return 1; }
    tool=$(command -v wgcf-cli 2>/dev/null) || tool=""
    if [ -z "$tool" ]; then
        _info "wgcf-cli 未安装, 下载 GitHub 临时副本"
        _warp_install_wgcf_cli "$dir" || { rm -rf "$dir"; return 1; }
        tool="$_WARP_WGCF_TOOL"
    fi
    [ -n "$tool" ] || { _WARP_REASON="wgcf-cli 不可用"; rm -rf "$dir"; return 1; }
    ( cd "$dir" && _warp_run 60 "$tool" register >"$dir/reg.json" 2>/dev/null ) || :
    if [ -s "$dir/reg.json" ] && jq -e . "$dir/reg.json" >/dev/null 2>&1; then
        cp "$dir/reg.json" "$out" 2>/dev/null || :
        [ -s "$out" ] && have_reg=1
    elif [ -s "$dir/wgcf.json" ] && jq -e . "$dir/wgcf.json" >/dev/null 2>&1; then
        cp "$dir/wgcf.json" "$out" 2>/dev/null || :
        [ -s "$out" ] && have_reg=1
    fi
    if [ "$have_reg" -eq 0 ]; then
        # register 失败或输出不是 JSON 时退回 generate; 同时接住写文件和写 stdout 两种版本。
        ( cd "$dir" && _warp_run 60 "$tool" generate --xray >"$dir/generate.log" 2>/dev/null ) || :
        for f in "$dir/wgcf.xray.json" "$dir/wgcf.json" "$dir"/*.xray.json "$dir/generate.log"; do
            if [ -f "$f" ] && [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
                cp "$f" "$out" 2>/dev/null || :
                break
            fi
        done
    fi
    rm -rf "$dir"
    if [ -s "$out" ] && jq -e . "$out" >/dev/null 2>&1; then
        return 0
    fi
    _WARP_REASON="wgcf-cli 未返回可用配置"
    return 1
}

# 注册 API 直接返回 Xray WireGuard 出站结构。
_warp_fetch_api() {
    local out="${1:-}"
    [ -n "$out" ] || { _WARP_REASON="未指定输出文件"; return 1; }
    _WARP_REASON=""
    if ! _warp_http_get "$WARP_API_URL" "$out" 25; then
        _WARP_REASON=$(_warp_http_reason "$out") || _WARP_REASON="未取得注册 API 响应"
        return 1
    fi
    [ -s "$out" ] || { _WARP_REASON="注册 API 返回空响应"; return 1; }
    return 0
}

_warp_http_json() {   # <method> <url> <bodyfile> <dest> [authfile]
    local method="${1:-}" url="${2:-}" body="${3:-}" dest="${4:-}" auth="${5:-}" code rc
    local -a args
    [ -n "$method" ] && [ -n "$url" ] && [ -f "$body" ] && [ -n "$dest" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    _WARP_HTTP_CODE=""
    args=(
        -sS
        -o "$dest"
        -w '%{http_code}'
        --proto '=https'
        --proto-redir '=https'
        --connect-timeout 8
        --max-time 30
        -X "$method"
        -H 'User-Agent: WARP for Android'
        -H 'CF-Client-Version: a-6.35-4471'
        -H 'Content-Type: application/json; charset=UTF-8'
        -H 'Connection: Keep-Alive'
    )
    [ -n "$auth" ] && args+=(-K "$auth")
    code=$(curl "${args[@]}" --data-binary @"$body" "$url" 2>"$dest.err")
    rc=$?
    _WARP_HTTP_CODE="${code:-000}"
    [ "$rc" -eq 0 ] || return 1
    case "$_WARP_HTTP_CODE" in
        2??) ;;
        *) return 1 ;;
    esac
    [ -s "$dest" ] || return 1
    return 0
}

# 注册一个临时 WireGuard 设备并通过指定账号类型取得账户:
# free 匿名注册; plus 注册后把 license 绑定到该设备; team 注册请求带 team token (JWT)。
# 输出 <dir>/reg.json、wg.priv.b64、wg.pub.b64 和 Bearer auth.conf。
_warp_api_register_wg() {   # <dir> [free|plus|team] [license|team token]
    local dir="${1:-}" account="${2:-free}" secret="${3:-}" tos serial wg_pub auth_post="" id token
    [ -n "$dir" ] && [ -d "$dir" ] || { _WARP_REASON="注册临时目录不可用"; return 1; }
    case "$account" in
        free|plus|team) ;;
        *) _WARP_REASON="未知 WARP 账号类型: $account"; return 1 ;;
    esac
    case "$account" in
        plus) _warp_valid_license "$secret" || { _WARP_REASON="WARP+ license 格式无效"; return 1; } ;;
        team) _warp_valid_team_token "$secret" || { _WARP_REASON="Zero Trust team token 无效"; return 1; } ;;
    esac
    command -v openssl >/dev/null 2>&1 || { _WARP_REASON="openssl 不可用"; return 1; }
    command -v base64 >/dev/null 2>&1 || { _WARP_REASON="base64 不可用"; return 1; }

    if ! openssl genpkey -algorithm X25519 -out "$dir/wg.pem" >/dev/null 2>&1; then
        _WARP_REASON="无法生成 WARP 注册用 WireGuard 密钥"
        return 1
    fi
    wg_pub=$(openssl pkey -in "$dir/wg.pem" -pubout -outform DER 2>/dev/null |
        tail -c 32 | base64 | tr -d '\n')
    openssl pkey -in "$dir/wg.pem" -outform DER 2>/dev/null |
        tail -c 32 | base64 | tr -d '\n' > "$dir/wg.priv.b64"
    if [ -z "$wg_pub" ] || [ ! -s "$dir/wg.priv.b64" ]; then
        _WARP_REASON="无法导出 WARP 注册用 WireGuard 密钥"
        return 1
    fi
    tos=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00") || {
        _WARP_REASON="无法生成注册时间"
        return 1
    }
    serial=$(openssl rand -hex 8 2>/dev/null)
    [ -n "$serial" ] || {
        _WARP_REASON="无法生成设备序列号"
        return 1
    }

    if ! jq -n --arg key "$wg_pub" --arg tos "$tos" --arg serial "$serial" '{
            key: $key,
            install_id: "",
            fcm_token: "",
            tos: $tos,
            model: "PC",
            serial_number: $serial,
            os_version: "",
            key_type: "curve25519",
            tunnel_type: "wireguard",
            locale: "en_US"
        }' > "$dir/reg.body"; then
        _WARP_REASON="无法生成 WARP 注册请求"
        return 1
    fi
    if [ "$account" = "team" ]; then
        printf 'header = "CF-Access-Jwt-Assertion: %s"\n' "$secret" > "$dir/jwt.conf" || {
            _WARP_REASON="无法生成 Zero Trust 授权配置"
            return 1
        }
        chmod 600 "$dir/jwt.conf" 2>/dev/null
        auth_post="$dir/jwt.conf"
    fi
    if ! _warp_http_json POST "$WARP_API_BASE/reg" "$dir/reg.body" "$dir/reg.json" "$auth_post"; then
        _WARP_REASON=$(_warp_http_reason "$dir/reg.json" 2>/dev/null) ||
            _WARP_REASON="Cloudflare WARP 注册请求失败"
        return 1
    fi
    id=$(jq -r '.id // empty' "$dir/reg.json" 2>/dev/null)
    token=$(jq -r '.token // empty' "$dir/reg.json" 2>/dev/null)
    if ! [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || [ -z "$token" ]; then
        _WARP_REASON="Cloudflare WARP 注册响应缺少有效账户信息"
        return 1
    fi
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$dir/auth.conf" || {
        _WARP_REASON="无法生成 WARP 授权配置"
        return 1
    }
    chmod 600 "$dir/auth.conf" 2>/dev/null
    if [ "$account" = "plus" ]; then
        if ! jq -n --arg license "$secret" '{license: $license}' > "$dir/license.body"; then
            _WARP_REASON="无法生成 WARP+ license 请求"
            return 1
        fi
        if ! _warp_http_json PUT "$WARP_API_BASE/reg/$id/account" \
            "$dir/license.body" "$dir/license.json" "$dir/auth.conf"; then
            case "$_WARP_HTTP_CODE" in
                2??) ;;
                *)
                    _WARP_REASON=$(_warp_http_reason "$dir/license.json" 2>/dev/null) ||
                        _WARP_REASON="WARP+ license 绑定失败"
                    return 1
                    ;;
            esac
        fi
    fi
    return 0
}

# MASQUE 注册沿用 usque 的做法: 先注册一个临时 WireGuard 公钥取得账户与 token,
# 再把账户设备密钥替换为 P-256(secp256r1) 并切换到 masque。临时 WireGuard 私钥不保存。
# 输出为 {privateKey, response}; response 是 Cloudflare 的 PATCH /reg/<id> 响应。
_warp_fetch_masque() {   # <outfile> [free|plus|team] [license|team token]
    local out="${1:-}" account="${2:-free}" secret="${3:-}" dir="" id
    _WARP_REASON=""
    [ -n "$out" ] || { _WARP_REASON="未指定输出文件"; return 1; }
    dir=$(mktemp -d "${TMPDIR:-/tmp}/warp-masque.XXXXXX") || {
        _WARP_REASON="无法创建 MASQUE 临时目录"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || {
        _WARP_REASON="无法保护 MASQUE 临时目录"
        rm -rf -- "$dir"
        return 1
    }
    if ! _warp_api_register_wg "$dir" "$account" "$secret"; then
        rm -rf -- "$dir"
        return 1
    fi
    id=$(jq -r '.id // empty' "$dir/reg.json" 2>/dev/null)

    if ! openssl ecparam -name prime256v1 -genkey -noout -out "$dir/ec.pem" >/dev/null 2>&1 ||
        ! openssl ec -in "$dir/ec.pem" -outform DER -out "$dir/ec.der" >/dev/null 2>&1 ||
        ! openssl ec -in "$dir/ec.pem" -pubout -outform DER -out "$dir/ec.pub.der" >/dev/null 2>&1; then
        _WARP_REASON="无法生成 MASQUE P-256 设备密钥"
        rm -rf -- "$dir"
        return 1
    fi
    base64 < "$dir/ec.der" | tr -d '\n' > "$dir/ec.priv.b64"
    base64 < "$dir/ec.pub.der" | tr -d '\n' > "$dir/ec.pub.b64"
    if [ ! -s "$dir/ec.priv.b64" ] || [ ! -s "$dir/ec.pub.b64" ]; then
        _WARP_REASON="无法编码 MASQUE P-256 设备密钥"
        rm -rf -- "$dir"
        return 1
    fi
    if ! jq -n --rawfile key "$dir/ec.pub.b64" '{
            key: $key,
            key_type: "secp256r1",
            tunnel_type: "masque"
        }' > "$dir/enroll.body"; then
        _WARP_REASON="无法生成 MASQUE 设备登记请求"
        rm -rf -- "$dir"
        return 1
    fi
    if ! _warp_http_json PATCH "$WARP_API_BASE/reg/$id" "$dir/enroll.body" "$dir/enroll.json" "$dir/auth.conf"; then
        _WARP_REASON=$(_warp_http_reason "$dir/enroll.json" 2>/dev/null) ||
            _WARP_REASON="Cloudflare MASQUE 设备登记失败"
        rm -rf -- "$dir"
        return 1
    fi
    # warp_enabled 只反映 WireGuard WARP 开关: 匿名免费设备登记 MASQUE 后仍为 false,
    # usque 也不检查该字段。以 PATCH 成功且端点公钥、隧道地址完整为准。
    if ! jq -e '
            ((.config.peers[0].public_key // "") != "")
            and (((.config.interface.addresses.v4 // "") != "")
                 or ((.config.interface.addresses.v6 // "") != ""))
        ' "$dir/enroll.json" >/dev/null 2>&1; then
        _WARP_REASON="Cloudflare MASQUE 登记响应缺少端点或隧道地址"
        rm -rf -- "$dir"
        return 1
    fi
    if ! jq -n --rawfile privateKey "$dir/ec.priv.b64" --slurpfile response "$dir/enroll.json" '{
            privateKey: $privateKey,
            response: $response[0]
        }' > "$dir/result.json"; then
        _WARP_REASON="无法生成 MASQUE 注册结果"
        rm -rf -- "$dir"
        return 1
    fi
    if ! cp "$dir/result.json" "$out" || ! chmod 600 "$out" 2>/dev/null; then
        _WARP_REASON="无法写入 MASQUE 注册结果"
        rm -rf -- "$dir"
        return 1
    fi
    rm -rf -- "$dir"
    return 0
}

# WARP+ / Zero Trust 的 WireGuard 注册; reserved 取 Cloudflare client_id 解码后的前 3 字节。
_warp_fetch_wg_account() {   # <outfile> [plus|team] [license|team token]
    local out="${1:-}" account="${2:-plus}" secret="${3:-}" dir="" private client_b64 reserved
    _WARP_REASON=""
    [ -n "$out" ] || { _WARP_REASON="未指定输出文件"; return 1; }
    case "$account" in
        plus|team) ;;
        *) _WARP_REASON="WireGuard 账号注册不支持: $account"; return 1 ;;
    esac
    dir=$(mktemp -d "${TMPDIR:-/tmp}/warp-account.XXXXXX") || {
        _WARP_REASON="无法创建 WARP 账号临时目录"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || {
        _WARP_REASON="无法保护 WARP 账号临时目录"
        rm -rf -- "$dir"
        return 1
    }
    if ! _warp_api_register_wg "$dir" "$account" "$secret"; then
        rm -rf -- "$dir"
        return 1
    fi
    private=$(cat "$dir/wg.priv.b64" 2>/dev/null)
    client_b64=$(jq -r '.config.client_id // empty' "$dir/reg.json" 2>/dev/null)
    if [ -z "$private" ] || [ -z "$client_b64" ]; then
        _WARP_REASON="Cloudflare WARP 注册响应缺少 WireGuard 密钥信息"
        rm -rf -- "$dir"
        return 1
    fi
    reserved=$(printf '%s' "$client_b64" | base64 -d 2>/dev/null | od -An -tu1 -N3 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) b[++n] = $i } END { if (n != 3) exit 1; printf "%d,%d,%d", b[1], b[2], b[3] }') || {
        _WARP_REASON="无法从 client_id 解析 WireGuard reserved"
        rm -rf -- "$dir"
        return 1
    }
    if ! jq -n --arg privateKey "$private" --arg reserved "$reserved" \
        --slurpfile response "$dir/reg.json" '{
            privateKey: $privateKey,
            reserved: ($reserved | split(",") | map(tonumber)),
            response: $response[0]
        }' > "$dir/result.json"; then
        _WARP_REASON="无法生成 WARP 账号注册结果"
        rm -rf -- "$dir"
        return 1
    fi
    if ! cp "$dir/result.json" "$out" || ! chmod 600 "$out" 2>/dev/null; then
        _WARP_REASON="无法写入 WARP 账号注册结果"
        rm -rf -- "$dir"
        return 1
    fi
    rm -rf -- "$dir"
    return 0
}

# ---------------------------------------------------------------------------
# 归一: 读 <rawfile>, 成功向 stdout 输出内部表示, 失败返回 1 且 stdout 为空。
# ---------------------------------------------------------------------------
# 归一骨架: <rawfile> <jq程序后缀> [MASQUE 端点]; 各入口只差中间的 jq 分支表达式。
_warp_normalize_jq() {   # <rawfile> <jq程序后缀> [masque_server]
    local raw="${1:-}" prog="${2:-}" server="${3:-$WARP_MASQUE_ENDPOINT}" obj
    [ -n "$raw" ] && [ -f "$raw" ] && [ -s "$raw" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    obj=$(jq -c --arg server "$server" --arg sni "$WARP_MASQUE_SERVER_NAME" \
        --argjson port "$WARP_MASQUE_PORT" \
        "$_WARP_NORM_JQ$prog" "$raw" 2>/dev/null) || return 1
    [ -n "$obj" ] || return 1
    _warp_finalize "$obj"
}

_warp_normalize_reg() { _warp_normalize_jq "${1:-}" ' reg2norm'; }

# wgcf-cli 既可能给注册 JSON, 也可能给 generate --xray 的出站: 有出站字段就按出站解析。
_warp_normalize_wgcf() { _warp_normalize_jq "${1:-}" ' (if (wgs) != null then out2norm else reg2norm end)'; }

_warp_normalize_masque() {   # <rawfile> [free|plus|team]
    _warp_normalize_jq "${1:-}" ' masque2norm' "$(_warp_masque_endpoint "${2:-free}")"
}

# API 给的是出站结构; 即使缺 allowedIPs/mtu 也必须重新映射成内部字段, 不拼接来源 JSON。
_warp_normalize_api() { _warp_normalize_jq "${1:-}" ' (if (wgs) != null then out2norm else error("不是 Xray WireGuard 出站结构") end)'; }

_warp_normalize_wg_account() { _warp_normalize_jq "${1:-}" ' wgacct2norm'; }

# ---------------------------------------------------------------------------
# 生成: 从 stdin 读内部表示, 向 stdout 输出单个 Xray outbound。
# noKernelTun 由调用方决定, 缺省 true: LXC/容器里自动探测 TUN 不可靠, 稳定优先。
# ---------------------------------------------------------------------------
# WARP 端点域名同时有 A/AAAA; Xray 默认在解析结果中随机选一个。
# 有 IPv4 默认路由时固定 UseIPv4, 只有 IPv6 默认路由时才用 UseIPv6。
_warp_domain_strategy() {
    if command -v ip >/dev/null 2>&1 &&
        [ -z "$(ip route show default 2>/dev/null)" ] &&
        [ -n "$(ip -6 route show default 2>/dev/null)" ]; then
        printf 'UseIPv6'
    else
        printf 'UseIPv4'
    fi
}

_warp_build_outbound() {   # [true|false, 缺省 true]
    local nk="${1:-true}" norm ds
    case "$nk" in true|false) ;; *) return 1 ;; esac
    norm=$(cat) || return 1
    [ -n "$norm" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    ds=$(_warp_domain_strategy)
    printf '%s' "$norm" | jq -c --argjson nk "$nk" --arg ds "$ds" "$_WARP_NORM_JQ"'
        if .kind == "masque" then
            masquecheck
            | { protocol: "masque",
                tag: "warp",
                settings: {
                  address: .server,
                  port: .port
                },
                streamSettings: {
                  network: "masque",
                  security: "tls",
                  tlsSettings: {
                    serverName: .serverName,
                    alpn: .alpn
                  },
                  masqueSettings: {
                    warp: {
                      privateKey: .privateKey,
                      publicKey: .publicKey,
                      address: .address
                    }
                  }
                } }
        else
            wgcheck
            | { protocol: "wireguard",
                tag: "warp",
                streamSettings: { sockopt: { domainStrategy: $ds } },
                settings: {
                  secretKey: .secretKey,
                  address: .address,
                  reserved: .reserved,
                  peers: [{ publicKey: .publicKey, endpoint: .endpoint, allowedIPs: .allowedIPs }],
                  mtu: .mtu,
                  noKernelTun: $nk
                } }
        end' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 编排: 免费 WireGuard 三种来源按序尝试; WARP+/Zero Trust 直接走账号注册 API。
# 全部失败只在 stderr 说明原因, 不碰配置。
# ---------------------------------------------------------------------------
_warp_obtain() {
    local out="${1:-}" kind="${2:-wireguard}" account="${3:-free}" secret="${4:-}"
    local mode label fetch_fn norm_fn raw norm reason
    [ -n "$out" ] || return 1
    command -v jq >/dev/null 2>&1 || { _error "jq 不可用, 无法解析 WARP 注册结果"; return 1; }
    case "$account" in
        free|plus|team) ;;
        *) _error "未知 WARP 账号类型: $account"; return 1 ;;
    esac
    label=$(_warp_account_label "$account")
    case "$kind" in
        wireguard)
            if [ "$account" != "free" ]; then
                raw=$(mktemp) || { _error "无法创建临时文件"; return 1; }
                norm=""
                reason=""
                _WARP_REASON=""
                if ! _warp_fetch_wg_account "$raw" "$account" "$secret"; then
                    reason="${_WARP_REASON:-未取得 Cloudflare WARP 注册响应}"
                elif ! norm=$(_warp_normalize_wg_account "$raw"); then
                    reason="Cloudflare WARP 响应无法解析"
                fi
                rm -f "$raw"
                if [ -n "$norm" ]; then
                    if printf '%s' "$norm" > "$out"; then
                        return 0
                    fi
                    _error "无法写入注册结果: $out"
                    return 1
                fi
                _error "WireGuard 注册失败 (${label}): ${reason:-未取得注册响应}"
                return 1
            fi
            ;;
        masque)
            raw=$(mktemp) || { _error "无法创建临时文件"; return 1; }
            norm=""
            reason=""
            _WARP_REASON=""
            if ! _warp_fetch_masque "$raw" "$account" "$secret"; then
                reason="${_WARP_REASON:-未取得 Cloudflare MASQUE 注册响应}"
            elif ! norm=$(_warp_normalize_masque "$raw" "$account"); then
                reason="Cloudflare MASQUE 响应无法解析"
            fi
            rm -f "$raw"
            if [ -n "$norm" ]; then
                if printf '%s' "$norm" > "$out"; then
                    return 0
                fi
                _error "无法写入注册结果: $out"
                return 1
            fi
            _error "MASQUE 注册失败 (${label}): ${reason:-未取得注册响应}"
            return 1
            ;;
        *)
            _error "未知 WARP 注册方式: $kind"
            return 1
            ;;
    esac
    for mode in reg wgcf api; do
        case "$mode" in
            reg)  label="warp-reg.sh"; fetch_fn=_warp_fetch_warp_reg; norm_fn=_warp_normalize_reg ;;
            wgcf) label="wgcf-cli";    fetch_fn=_warp_fetch_wgcf_cli;  norm_fn=_warp_normalize_wgcf ;;
            api)  label="注册 API";    fetch_fn=_warp_fetch_api;       norm_fn=_warp_normalize_api ;;
        esac
        raw=$(mktemp) || { _error "无法创建临时文件"; return 1; }
        norm=""
        reason=""
        _WARP_REASON=""
        if ! "$fetch_fn" "$raw"; then
            reason="${_WARP_REASON:-未取得注册响应}"
        elif ! norm=$("$norm_fn" "$raw"); then
            reason="响应无法解析"
        fi
        rm -f "$raw"
        if [ -n "$norm" ]; then
            if printf '%s' "$norm" > "$out"; then
                return 0
            fi
            _error "无法写入注册结果: $out"
            return 1
        fi
        _warn "$label 不可用: ${reason:-未取得注册响应}"
    done
    _error "三种 WARP 注册方式均失败, 配置未修改"
    return 1
}

# ---------------------------------------------------------------------------
# 配置操作: 读取走 _config_jq, 写入走 _mutate_config(备份/提交/verified restart/回滚)。
# ---------------------------------------------------------------------------
_warp_outbound_json() {
    _config_present || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local ob
    ob=$(_config_jq -c '[.outbounds[]? | select((.tag? // "") == "warp")] | first // empty' 2>/dev/null) || return 1
    [ -n "$ob" ] || return 1
    printf '%s' "$ob"
}

_warp_outbound_kind() {
    local ob
    ob=$(_warp_outbound_json) || return 1
    printf '%s' "$ob" | jq -r '.protocol // ""' 2>/dev/null
}

# 单行: present<TAB>kind<TAB>endpoint<TAB>addresses<TAB>mtu
_warp_state_summary() {
    _config_present || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local line
    line=$(_config_jq -r '
        . as $root
        | ([$root.outbounds[]? | select((.tag? // "") == "warp")] | first) as $w
        | if $w == null then ["0", "-", "-", "-", "-"]
          else ($w.protocol // "wireguard") as $p
          | ["1",
                $p,
                (if $p == "masque" then
                    ($w.settings.address // "") as $h
                    | ($w.settings.port // 443) as $port
                    | ((if ($h | test(":")) and (($h | startswith("[")) | not)
                          then "[" + $h + "]" else $h end) + ":" + ($port | tostring))
                 else ($w.settings.peers[0].endpoint // "") end),
                (if $p == "masque" then
                    ([$w.streamSettings.masqueSettings.warp.address[]? | tostring] | join(","))
                 else ([$w.settings.address[]? | tostring] | join(",")) end),
                (if $p == "masque" then "-" else (($w.settings.mtu // "") | tostring) end)]
          end
        | @tsv' 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

# 替换或追加 tag=warp 出站; 已有同 tag 出站原位替换, 其它出站原样保留。
# 重新注册 WireGuard 时沿用现有出站的 noKernelTun 选择, 不让重新注册悄悄重置 TUN 模式。
# 全新注册或从 MASQUE 切回 WireGuard 时用推荐值 true; 已有 WireGuard 只在明确 true 时保持。
_warp_apply() {
    local norm="${1:-}" ob nk=true existing
    [ -n "$norm" ] || return 1
    if existing=$(_warp_outbound_json 2>/dev/null); then
        if [ "$(printf '%s' "$existing" | jq -r '.protocol // ""' 2>/dev/null)" = "wireguard" ]; then
            [ "$(printf '%s' "$existing" | jq -r '.settings.noKernelTun // false' 2>/dev/null)" = "true" ] || nk=false
        fi
    fi
    ob=$(printf '%s' "$norm" | _warp_build_outbound "$nk") || return 1
    [ -n "$ob" ] || return 1
    _config_edit_preflight "管理 WARP" || return 1
    _mutate_config --argjson ob "$ob" '
        . as $root
        | ($root.outbounds // []) as $o
        | (reduce ($o | to_entries[]) as $e ({out: [], done: false};
              if (($e.value | .tag? // "") == "warp")
              then (if .done then . else (.out += [$ob] | .done = true) end)
              else (.out += [$e.value]) end)) as $acc
        | $root
        | .outbounds = (if $acc.done then $acc.out else ($acc.out + [$ob]) end)
    ' || return 1
    return 0
}

# 出站与引用它的分流规则必须在同一次 jq 变更里一起删除, 否则会留下悬空 outboundTag。
_warp_delete() {
    _config_edit_preflight "管理 WARP" || return 1
    _mutate_config '
        . as $root
        | (if ($root.outbounds | type) == "array"
           then .outbounds = ([$root.outbounds[]? | select((.tag? // "") != "warp")])
           else . end)
        | (if ($root.routing | type) == "object"
           then .routing.rules = ([$root.routing.rules[]? | select((.outboundTag? // "") != "warp")])
           else . end)
    ' || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 子菜单: 不调用 _menu_require_tty(只有主菜单调用)。菜单只显示是否存在/endpoint/地址/MTU。
# ---------------------------------------------------------------------------
_warp_ask_account() {   # sets _WARP_ACCOUNT / _WARP_SECRET; 0=ok 1=cancel
    local ans secret
    _WARP_ACCOUNT="free"
    _WARP_SECRET=""
    echo
    echo -e "  ${CYAN}选择 WARP 账号类型${NC}"
    echo -e "  ${GREEN}[1]${NC} 免费 WARP"
    echo -e "  ${GREEN}[2]${NC} WARP+ (license key)"
    echo -e "  ${GREEN}[3]${NC} Zero Trust (team token)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    while true; do
        read -rp "  请选择 [1]: " ans || return 1
        case "${ans:-1}" in
            0) return 1 ;;
            1)
                _WARP_ACCOUNT="free"
                _WARP_SECRET=""
                return 0
                ;;
            2)
                read -rp "  请输入 WARP+ license: " secret || return 1
                secret=$(printf '%s' "$secret" | tr -d '[:space:]')
                if _warp_valid_license "$secret"; then
                    _WARP_ACCOUNT="plus"
                    _WARP_SECRET="$secret"
                    return 0
                fi
                _warn "license 格式应为 xxxxxxxx-xxxxxxxx-xxxxxxxx"
                ;;
            3)
                echo -e "  team token 从 ${CYAN}https://<团队名>.cloudflareaccess.com/warp${NC} 获取 (有效期约 1 分钟)"
                read -rp "  请输入 Zero Trust team token: " secret || return 1
                secret=$(printf '%s' "$secret" | tr -d '[:space:]')
                if _warp_valid_team_token "$secret"; then
                    _WARP_ACCOUNT="team"
                    _WARP_SECRET="$secret"
                    return 0
                fi
                _warn "team token 不能为空, 且不能包含空白、引号或反斜杠"
                ;;
            *) _warn "无效选择" ;;
        esac
    done
}

_warp_register() {   # [wireguard|masque]
    local kind="${1:-}" ans tmp norm account secret label
    if [ -z "$kind" ]; then
        echo
        echo -e "  ${CYAN}选择 WARP 连接方式${NC}"
        echo -e "  ${GREEN}[1]${NC} MASQUE (HTTP/2 over TLS，TCP 443)"
        echo -e "  ${GREEN}[2]${NC} WireGuard (UDP，兼容性好)"
        read -rp "  请选择 [1]: " ans || return 1
        case "${ans:-1}" in
            1) kind="masque" ;;
            2) kind="wireguard" ;;
            *) _info "已取消"; return 0 ;;
        esac
    fi
    case "$kind" in
        wireguard|masque) ;;
        *) _error "未知 WARP 连接方式: $kind"; return 1 ;;
    esac
    if ! _warp_ask_account; then
        _info "已取消"
        return 0
    fi
    account="$_WARP_ACCOUNT"
    secret="$_WARP_SECRET"
    label=$(_warp_account_label "$account")
    _config_edit_preflight "管理 WARP" || return 1
    tmp=$(mktemp) || { _error "无法创建临时文件"; return 1; }
    if ! _warp_obtain "$tmp" "$kind" "$account" "$secret"; then
        rm -f "$tmp"
        _error "WARP 注册失败, 配置未修改"
        return 1
    fi
    norm=$(cat "$tmp")
    rm -f "$tmp"
    [ -n "$norm" ] || { _error "注册结果为空, 配置未修改"; return 1; }
    if ! _warp_apply "$norm"; then
        _error "WARP 出站写入失败(配置已回滚)"
        return 1
    fi
    if [ "$kind" = "masque" ]; then
        _success "WARP MASQUE 出站已写入(tag=warp, 账号: $label), xray 已用新配置重启"
    else
        _success "WARP WireGuard 出站已写入(tag=warp, 账号: $label), xray 已用新配置重启"
    fi
    return 0
}

_warp_delete_prompt() {
    local ans
    _warp_outbound_json >/dev/null || { _info "WARP 出站不存在"; return 0; }
    echo
    echo -e "  ${YELLOW}将同时删除 tag=warp 出站与所有 outboundTag=warp 的分流规则${NC}"
    read -rp "  确认删除 WARP? [y/N]: " ans || return 1
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; return 0 ;;
    esac
    if _warp_delete; then
        _success "WARP 出站与分流规则已删除, xray 已用新配置重启"
        return 0
    fi
    _error "删除失败(配置已回滚)"
    return 1
}

# 内核 TUN 模式: on=强制关闭(noKernelTun=true, 始终 gVisor), auto=让 Xray 自动检测。
# 官方文档: TUN 性能更高, 只有 LXC/Docker 里 TUN 起不来时才需要强制关闭。
_warp_tun_mode() {
    local ob kind
    ob=$(_warp_outbound_json) || return 1
    kind=$(printf '%s' "$ob" | jq -r '.protocol // ""' 2>/dev/null) || return 1
    [ "$kind" = "wireguard" ] || return 1
    if printf '%s' "$ob" | jq -e '.settings.noKernelTun == true' >/dev/null 2>&1; then
        printf 'on'
    else
        printf 'auto'
    fi
}

_warp_set_tun() {   # <on|auto>
    local mode="${1:-}" nk kind
    case "$mode" in on|auto) ;; *) return 1 ;; esac
    _config_edit_preflight "管理 WARP" || return 1
    kind=$(_warp_outbound_kind 2>/dev/null) || { _error "WARP 出站不存在, 无法修改 TUN 模式"; return 1; }
    [ "$kind" = "wireguard" ] || {
        _error "MASQUE 出站不支持内核 TUN 模式"
        return 1
    }
    nk=false
    [ "$mode" = on ] && nk=true
    _mutate_config --argjson nk "$nk" '
        .outbounds = ([.outbounds[]?
            | if (.tag? // "") == "warp"
              then .settings = ((.settings // {}) + {noKernelTun: $nk})
              else . end])
    ' || return 1
    return 0
}

_warp_set_tun_prompt() {
    local cur choice kind
    if ! cur=$(_warp_tun_mode); then
        kind=$(_warp_outbound_kind 2>/dev/null) || {
            _error "WARP 出站不存在"
            return 1
        }
        if [ "$kind" = "masque" ]; then
            _error "MASQUE 出站不支持内核 TUN 模式"
        else
            _error "无法读取 WARP 出站的 TUN 模式"
        fi
        return 1
    fi
    if [ "$cur" = on ]; then
        echo -e "  当前: ${CYAN}强制关闭内核 TUN${NC} (noKernelTun=true, 始终使用 gVisor 用户态网络栈)"
    else
        echo -e "  当前: ${CYAN}自动检测${NC} (noKernelTun=false, 有 CAP_NET_ADMIN 时走内核 TUN)"
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 强制关闭内核 TUN (LXC/容器推荐, 稳定优先)"
    echo -e "  ${GREEN}[2]${NC} 自动检测 (KVM + CAP_NET_ADMIN 时吞吐更好, TUN 起不来则出站不可用)"
    read -rp "  请选择(回车取消): " choice || return 1
    case "$choice" in
        1)
            if _warp_set_tun on; then
                _success "已切换为强制关闭内核 TUN, xray 已用新配置重启"
                return 0
            fi
            _error "切换失败(配置已回滚)"
            return 1
            ;;
        2)
            if _warp_set_tun auto; then
                _success "已切换为自动检测, xray 已用新配置重启"
                return 0
            fi
            _error "切换失败(配置已回滚)"
            return 1
            ;;
        *) _info "已取消"; return 0 ;;
    esac
}

_warp_menu() {
    local choice st present kind endpoint addresses mtu method
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【WARP (Cloudflare WireGuard / MASQUE 出站)】${NC}"
        echo
        present=0
        kind=""
        endpoint=""
        addresses=""
        mtu=""
        if st=$(_warp_state_summary); then
            IFS=$'\t' read -r present kind endpoint addresses mtu <<< "$st"
            if [ "$present" = "1" ]; then
                if [ "$kind" = "masque" ]; then
                    method="MASQUE (HTTP/2)"
                else
                    method="WireGuard"
                fi
                echo -e "  出站:      ${GREEN}已存在${NC} (tag=$WARP_TAG)"
                echo -e "  方式:      ${CYAN}${method}${NC}"
                echo -e "  endpoint:  ${CYAN}${endpoint:-未知}${NC}"
                echo -e "  地址:      ${CYAN}${addresses:-未知}${NC}"
                if [ "$kind" != "masque" ]; then
                    echo -e "  MTU:       ${CYAN}${mtu:-未知}${NC}"
                fi
                if [ "$kind" = "masque" ]; then
                    echo -e "  传输:      ${CYAN}MASQUE CONNECT-IP / HTTP2 over TLS${NC}"
                else
                    case "$(_warp_tun_mode 2>/dev/null)" in
                        on) echo -e "  内核 TUN:  ${CYAN}强制关闭${NC} (始终使用 gVisor)" ;;
                        auto) echo -e "  内核 TUN:  ${CYAN}自动检测${NC} (有权限时走内核 TUN)" ;;
                    esac
                fi
            else
                echo -e "  出站: ${YELLOW}未配置${NC}"
            fi
        else
            _warn "无法读取当前配置(Xray 未安装 / 配置缺失 / jq 不可用)"
        fi
        echo
        echo -e "  ${GREEN}[1]${NC} 注册 / 重新注册 WARP (WireGuard / MASQUE)"
        echo -e "  ${GREEN}[2]${NC} 内核 TUN 模式 (仅 WireGuard)"
        echo -e "  ${GREEN}[3]${NC} 删除 WARP 出站"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            0) return ;;
            1) _warp_register; _press_any_key ;;
            2) _warp_set_tun_prompt; _press_any_key ;;
            3) _warp_delete_prompt; _press_any_key ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}
