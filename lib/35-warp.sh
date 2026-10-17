#!/bin/bash
# lib/35-warp.sh — WARP 自动注册、Xray WireGuard 出站与分流规则。
# 注册来源按 warp-reg.sh → wgcf-cli → 注册 API 回退, 全部失败不写配置、不动已有出站。
# 配置唯一事实来源是 confs 里的 Xray 片段: 注册结果与 endpoint 覆盖都保存在 tag=warp 出站里。
# 写入一律走 _mutate_config(定义在 50 模块, 调用时才解析); 见 _warp_apply / _warp_delete。

WARP_TAG="warp"
WARP_DEFAULT_PORT="2408"
WARP_DEFAULT_MTU="1280"
WARP_REG_SCRIPT_URL="https://warp-reg.vercel.app"
WARP_API_URL="https://warp.cloudflare.now.cc/?run=register&format=xray"

# 归一/生成共用的 jq 定义: 内部表示字段名与类型固定, 缺字段或非法 reserved 一律 error 退出
# (error 让 jq 非零退出且不产生输出, 满足"失败时 stdout 为空")。
_WARP_NORM_JQ='
def fld($k): if (type == "object") then (.[$k] // null) else null end;
def arr($v): if ($v | type) == "array" then $v
             elif (($v | type) == "string") and $v != "" then [$v]
             else [] end;
def addrmask: if test("/") then . else (if test(":") then . + "/128" else . + "/32" end) end;
def wgs:
  if (type == "object") and ((.settings | type) == "object") and ((.settings.secretKey | type) == "string") then .settings
  elif (type == "object") and ((.outbounds | type) == "array") and ((.outbounds[0].settings.secretKey | type) == "string") then .outbounds[0].settings
  elif (type == "object") and ((.config | type) == "object") and ((.config.outbounds | type) == "array") and ((.config.outbounds[0].settings.secretKey | type) == "string") then .config.outbounds[0].settings
  elif (type == "object") and ((.data | type) == "object") and ((.data.settings | type) == "object") and ((.data.settings.secretKey | type) == "string") then .data.settings
  elif (type == "object") and ((.data | type) == "object") and ((.data.outbounds | type) == "array") and ((.data.outbounds[0].settings.secretKey | type) == "string") then .data.outbounds[0].settings
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
def reg2norm:
  . as $r
  | {
      secretKey: (($r | fld("private_key")) | if type == "string" then . else "" end),
      address: ([ ($r | fld("v4")), ($r | fld("v6")),
                  ($r | fld("addresses") | fld("v4")), ($r | fld("addresses") | fld("v6")) ]
                | map(select((type == "string") and (. != ""))) | unique | map(addrmask)),
      reserved: (($r | fld("reserved_dec")) | if type == "array" then . else [] end),
      endpoint: (($r | fld("endpoint"))
                 | if type == "object" then (fld("v4") // fld("v6") // "")
                   elif type == "string" then .
                   else "" end),
      publicKey: (($r | fld("public_key")) | if type == "string" then . else "" end),
      allowedIPs: ["0.0.0.0/0", "::/0"],
      mtu: 1280
    }
  | wgcheck;
def out2norm:
  wgs as $s
  | if ($s | type) != "object" then error("不是 Xray WireGuard 出站结构") else . end
  | ($s.peers | if (type == "array") and (length > 0) and ((.[0] | type) == "object") then .[0] else {} end) as $p
  | {
      secretKey: ($s.secretKey | if type == "string" then . else "" end),
      address: (arr($s.address) | map(select((type == "string") and (. != ""))) | map(addrmask)),
      reserved: ($s.reserved | if type == "array" then . else [] end),
      endpoint: ($p.endpoint | if type == "string" then . else "" end),
      publicKey: ($p.publicKey | if type == "string" then . else "" end),
      allowedIPs: (arr($p.allowedIPs) | if length > 0 then . else ["0.0.0.0/0", "::/0"] end),
      mtu: (if ($s.mtu | type) == "number" then $s.mtu else 1280 end)
    }
  | wgcheck;
'

# ---------------------------------------------------------------------------
# endpoint 规范化: v6 必须带方括号, 裸 IP 补默认 2408 端口, 端口 0 视为未指定。
# 用法: ep=$(_warp_endpoint_norm "<来源 endpoint>")   —— 非法返回 1 且无输出
# ---------------------------------------------------------------------------
_warp_endpoint_norm() {
    local ep="${1:-}" host="" port="" p
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
        # 多个冒号且无端口后缀: 裸 IPv6
        [[ "$ep" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
        host="$ep"
    else
        host="$ep"
    fi
    [ -n "$host" ] || return 1
    [[ "$host" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
    if [ -z "$port" ] || [ "$port" = "0" ]; then
        port="$WARP_DEFAULT_PORT"
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

# 归一收尾: endpoint 交给 bash 规范化后回写, 其余字段原样保留。失败不输出任何内容。
_warp_finalize() {   # <候选内部表示 JSON>
    local obj="${1:-}" ep out
    [ -n "$obj" ] || return 1
    ep=$(printf '%s' "$obj" | jq -r '.endpoint // ""' 2>/dev/null) || return 1
    ep=$(_warp_endpoint_norm "$ep") || return 1
    out=$(printf '%s' "$obj" | jq -c --arg ep "$ep" '.endpoint = $ep' 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# 获取: 原始响应只写入 <outfile>, 不写 stdout。成功返回 0, 失败返回 1。
# ---------------------------------------------------------------------------
# warp-reg.sh: 本机有命令就直接跑; 否则按官方 bash -c "$(curl -L ...)" 的方式限时取回脚本再执行。
_warp_fetch_warp_reg() {
    local out="${1:-}" script rc=0
    [ -n "$out" ] || return 1
    if command -v warp-reg >/dev/null 2>&1; then
        warp-reg >"$out" 2>/dev/null || rc=1
    elif command -v warp-reg.sh >/dev/null 2>&1; then
        warp-reg.sh >"$out" 2>/dev/null || rc=1
    else
        script=$(mktemp) || return 1
        if _http_download "$WARP_REG_SCRIPT_URL" "$script" 20; then
            bash "$script" >"$out" 2>/dev/null || rc=1
        else
            rc=1
        fi
        rm -f "$script"
    fi
    [ "$rc" -eq 0 ] && [ -s "$out" ] && return 0
    return 1
}

# wgcf-cli: 在同一临时目录内先取注册 JSON, 再退回 generate --xray 的产物。
# register 把含 WARP 私钥的 wgcf.json 写在当前目录, 所以 register 与 generate 都只在 mktemp 目录内运行,
# 目录随后整体删除: 调用者当前目录不留账号文件, generate 也能读到 register 生成的账号。
# 本机没有该命令直接失败(不自行安装)。
_warp_fetch_wgcf_cli() {
    local out="${1:-}" dir f
    [ -n "$out" ] || return 1
    command -v wgcf-cli >/dev/null 2>&1 || return 1
    dir=$(mktemp -d) || return 1
    ( cd "$dir" && wgcf-cli register >"$dir/reg.json" 2>/dev/null ) || :
    if [ -s "$dir/reg.json" ] && jq -e . "$dir/reg.json" >/dev/null 2>&1; then
        cp "$dir/reg.json" "$out" 2>/dev/null || :
    else
        # register 失败或输出不是 JSON 时退回 generate; 账号文件就在同一个 $dir 里。
        ( cd "$dir" && wgcf-cli generate --xray >/dev/null 2>&1 ) || :
    fi
    for f in "$dir/wgcf.xray.json" "$dir"/*.xray.json; do
        if [ -f "$f" ] && [ -s "$f" ] && jq -e . "$f" >/dev/null 2>&1; then
            cp "$f" "$out" 2>/dev/null || :
            break
        fi
    done
    rm -rf "$dir"
    [ -s "$out" ] && jq -e . "$out" >/dev/null 2>&1 && return 0
    return 1
}

# 注册 API 直接返回 Xray WireGuard 出站结构。
_warp_fetch_api() {
    local out="${1:-}"
    [ -n "$out" ] || return 1
    _http_download "$WARP_API_URL" "$out" 25 || return 1
    [ -s "$out" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 归一: 读 <rawfile>, 成功向 stdout 输出内部表示, 失败返回 1 且 stdout 为空。
# ---------------------------------------------------------------------------
_warp_normalize_reg() {
    local raw="${1:-}" obj
    [ -n "$raw" ] && [ -f "$raw" ] && [ -s "$raw" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    obj=$(jq -c "$_WARP_NORM_JQ"' reg2norm' "$raw" 2>/dev/null) || return 1
    [ -n "$obj" ] || return 1
    _warp_finalize "$obj"
}

_warp_normalize_wgcf() {
    local raw="${1:-}" obj
    [ -n "$raw" ] && [ -f "$raw" ] && [ -s "$raw" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    # wgcf-cli 既可能给注册 JSON, 也可能给 generate --xray 的出站: 有出站字段就按出站解析。
    obj=$(jq -c "$_WARP_NORM_JQ"' (if (wgs) != null then out2norm else reg2norm end)' "$raw" 2>/dev/null) || return 1
    [ -n "$obj" ] || return 1
    _warp_finalize "$obj"
}

_warp_normalize_api() {
    local raw="${1:-}" obj
    [ -n "$raw" ] && [ -f "$raw" ] && [ -s "$raw" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    # API 给的是出站结构; 即使缺 allowedIPs/mtu 也必须重新映射成内部字段, 不拼接来源 JSON。
    obj=$(jq -c "$_WARP_NORM_JQ"' (if (wgs) != null then out2norm else error("不是 Xray WireGuard 出站结构") end)' "$raw" 2>/dev/null) || return 1
    [ -n "$obj" ] || return 1
    _warp_finalize "$obj"
}

# ---------------------------------------------------------------------------
# 生成: 从 stdin 读内部表示, 向 stdout 输出单个 Xray outbound。
# noKernelTun=true 固定: LXC/容器里自动探测 TUN 不可靠。
# ---------------------------------------------------------------------------
_warp_build_outbound() {
    local norm
    norm=$(cat) || return 1
    [ -n "$norm" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    printf '%s' "$norm" | jq -c "$_WARP_NORM_JQ"'
        wgcheck
        | { tag: "warp",
            protocol: "wireguard",
            settings: {
              secretKey: .secretKey,
              address: .address,
              reserved: .reserved,
              peers: [{ publicKey: .publicKey, endpoint: .endpoint, allowedIPs: .allowedIPs }],
              mtu: .mtu,
              noKernelTun: true
            } }' 2>/dev/null
}

# ---------------------------------------------------------------------------
# 编排: 三种来源按序尝试, 第一个成功即写 <outfile> 并返回 0。
# 全部失败只在 stderr 说明原因, 不碰配置。
# ---------------------------------------------------------------------------
_warp_obtain() {
    local out="${1:-}" mode label fetch_fn norm_fn raw norm reason
    [ -n "$out" ] || return 1
    command -v jq >/dev/null 2>&1 || { _error "jq 不可用, 无法解析 WARP 注册结果"; return 1; }
    for mode in reg wgcf api; do
        case "$mode" in
            reg)  label="warp-reg.sh"; fetch_fn=_warp_fetch_warp_reg; norm_fn=_warp_normalize_reg ;;
            wgcf) label="wgcf-cli";    fetch_fn=_warp_fetch_wgcf_cli;  norm_fn=_warp_normalize_wgcf ;;
            api)  label="注册 API";    fetch_fn=_warp_fetch_api;       norm_fn=_warp_normalize_api ;;
        esac
        raw=$(mktemp) || { _error "无法创建临时文件"; return 1; }
        norm=""
        reason=""
        if ! "$fetch_fn" "$raw"; then
            reason="未取得注册响应"
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

# 分流规则判据: 只有 outboundTag=warp 且带 domain 或 ip 的规则才算本模块管理的 WARP 规则。
# 列表、删除与菜单计数共用这一个判据, 避免编号与可删除条目错位。
# 去重只统计 WARP 规则内的值; 其它出站的同名值不参与去重, 否则「让 geoip:cn 或
# 已在直连白名单里的域名走 warp」这类合法覆盖会被静默丢弃。
_WARP_RULE_JQ='
def iswrule: ((.outboundTag? // "") == "warp")
  and (((.["domain"]? // null) != null) or ((.["ip"]? // null) != null));
def wvals($k): [ .[]? | select((.outboundTag? // "") == "warp") | (.[$k]? // null)
                 | (if type == "array" then .[] else . end) | select(type == "string") ];
def newvals($k; $v):
  . as $rules
  | ($rules | wvals($k)) as $have
  | ($v | reduce .[] as $x ([];
      if (($have | index($x)) == null) and (index($x) == null) then . + [$x] else . end));
'

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

# 单行: present<TAB>endpoint<TAB>addresses<TAB>mtu<TAB>ruleCount
_warp_state_summary() {
    _config_present || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local line
    line=$(_config_jq -r "$_WARP_RULE_JQ"'
        . as $root
        | ([$root.outbounds[]? | select((.tag? // "") == "warp")] | first) as $w
        | ([$root.routing.rules[]? | select(iswrule)] | length) as $n
        | if $w == null then ["0", "", "", "", ""]
          else ["1",
                ($w.settings.peers[0].endpoint // ""),
                ([$w.settings.address[]? | tostring] | join(",")),
                (($w.settings.mtu // "") | tostring),
                ($n | tostring)]
          end
        | @tsv' 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

# 替换或追加 tag=warp 出站; 已有同 tag 出站原位替换, 其它出站原样保留。
_warp_apply() {
    local norm="${1:-}" ob
    [ -n "$norm" ] || return 1
    ob=$(printf '%s' "$norm" | _warp_build_outbound) || return 1
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

# 只改 peers[0].endpoint, 其它字段(含分流规则)不动。
_warp_set_endpoint() {
    local ep
    ep=$(_warp_endpoint_norm "${1:-}") || return 1
    _config_edit_preflight "管理 WARP" || return 1
    _warp_outbound_json | jq -e '.settings.peers[0].publicKey' >/dev/null 2>&1 || {
        _error "WARP 出站不存在或缺少 peer, 无法修改 endpoint"
        return 1
    }
    _mutate_config --arg ep "$ep" '
        . as $root
        | .outbounds = ([$root.outbounds[]?
            | if (.tag? // "") == "warp"
              then (if ((.settings.peers // []) | length) > 0
                    then .settings.peers[0].endpoint = $ep
                    else . end)
              else . end])
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

# 插入点: 首条无 inboundTag 的规则之前(tunnel/Reality 的 inboundTag 规则始终在最前),
# 私网防护规则之后; 锚点起连续的 WARP 规则之后接续, 以保持相邻。
# 首个匹配生效: WARP 规则被手工排到普通规则之后时必须插回锚点, 否则新规则永远命中不到。
_warp_add_rule() {   # <domain|ip> <逗号分隔值>
    local kind="${1:-}" csv="${2:-}" v vals_json new
    local -a vals=()
    local ptag="${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private}"
    case "$kind" in domain|ip) ;; *) return 1 ;; esac
    [ -n "$csv" ] || return 1
    local IFS=','
    # 只按逗号切词, 关闭路径名展开: 值里的 * ? [ 不会被当前目录的同名文件替换。
    set -f
    for v in $csv; do
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        [ -n "$v" ] || continue
        vals+=("$v")
    done
    set +f
    [ "${#vals[@]}" -gt 0 ] || return 1
    vals_json=$(jq -n -c --args '$ARGS.positional' -- "${vals[@]}") || return 1
    [ -n "$vals_json" ] || return 1
    _config_edit_preflight "管理 WARP" || return 1
    # 先只读算出真正要写入的值: 全部已存在就不写配置, 避免无意义重启。
    new=$(_config_jq -c --arg k "$kind" --argjson v "$vals_json" "$_WARP_RULE_JQ"' (.routing.rules // []) | newvals($k; $v)' 2>/dev/null) || return 1
    [ -n "$new" ] || return 1
    if [ "$new" = "[]" ]; then
        _info "这些值已存在于 WARP 分流规则中, 未重复写入"
        return 0
    fi
    _mutate_config --arg k "$kind" --argjson v "$new" --arg ptag "$ptag" "$_WARP_RULE_JQ"'
        . as $root
        | ($root.routing.rules // []) as $rules
        | ($rules | newvals($k; $v)) as $new
        | if ($new | length) == 0 then $root
          else
            ([$rules | to_entries[] | select(.value.inboundTag? == null) | .key] | first // ($rules | length)) as $base
            | ([range(0; ($rules | length)) | select((($rules[.] | .ruleTag?) // null) == $ptag)] | first) as $pb
            | (if $pb == null then $base else ([$base, ($pb + 1)] | max) end) as $anchor
            | ([range($anchor; ($rules | length)) | select((($rules[.] | .outboundTag?) // "") != "warp")] | first // ($rules | length)) as $ins
            | $root
            | .routing.rules = ($rules[0:$ins] + [{($k): $new, outboundTag: "warp"}] + $rules[$ins:])
          end' || return 1
    return 0
}

# 每行: 序号<TAB>类型<TAB>值; 无 WARP 规则时返回 0 且无输出。
_warp_rules_list() {
    _config_present || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local out
    out=$(_config_jq -r "$_WARP_RULE_JQ"'
        . as $root
        | [$root.routing.rules[]? | select(iswrule)]
        | to_entries[]
        | .key as $i
        | .value as $r
        | [("domain", "ip") as $t | select(($r[$t]? // null) != null) | $t] as $types
        | [("domain", "ip") as $t | select(($r[$t]? // null) != null)
             | ($r[$t] | if type == "array" then map(tostring) | join(",") else tostring end)] as $vals
        | [ ($i + 1 | tostring), ($types | join("+")), ($vals | join(",")) ]
        | @tsv' 2>/dev/null) || return 1
    [ -n "$out" ] || return 0
    printf '%s\n' "$out"
}

# 序号与 _warp_rules_list 一致(按 outboundTag=warp 规则的出现顺序从 1 开始)。
_warp_delete_rule() {
    local n="${1:-}" total idx
    _config_edit_preflight "管理 WARP" || return 1
    total=$(_config_jq -r "$_WARP_RULE_JQ"' [.routing.rules[]? | select(iswrule)] | length' 2>/dev/null) || return 1
    [[ "$total" =~ ^[0-9]+$ ]] || return 1
    idx=$(_xd_index_from_choice "$n" "$total") || return 1
    _mutate_config --argjson i "$idx" "$_WARP_RULE_JQ"'
        . as $root
        | ($root.routing.rules // []) as $rules
        | ([range(0; ($rules | length)) | select($rules[.] | iswrule)] | .[$i]) as $pos
        | if $pos == null then . else del(.routing.rules[$pos]) end
    ' || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 子菜单: 不调用 _menu_require_tty(只有主菜单调用)。菜单只显示是否存在/endpoint/地址/MTU/规则数。
# ---------------------------------------------------------------------------
_warp_register() {
    local tmp norm
    _config_edit_preflight "管理 WARP" || return 1
    tmp=$(mktemp) || { _error "无法创建临时文件"; return 1; }
    if ! _warp_obtain "$tmp"; then
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
    _success "WARP 出站已写入(tag=warp), xray 已用新配置重启"
    _tip "注册/重新注册不会自动添加分流规则; 需要分流请在 [3] 添加"
    return 0
}

_warp_add_rule_prompt() {
    local kind="" csv
    while true; do
        read -rp "  规则类型 [1=域名(domain) 2=IP(ip)]: " kind || return 1
        case "$kind" in
            1|domain) kind=domain; break ;;
            2|ip)     kind=ip; break ;;
            *) _warn "请输入 1 或 2" ;;
        esac
    done
    echo -e "  多个值用英文逗号分隔, 同类规则里已有的值不会重复写入"
    if [ "$kind" = "domain" ]; then
        echo -e "  例: example.com,geosite:netflix,regexp:^ad\\."
    else
        echo -e "  例: 1.1.1.1,8.8.8.0/24,geoip:cn"
    fi
    while true; do
        read -rp "  请输入: " csv || return 1
        [ -n "$csv" ] || { _warn "输入为空, 请重新输入"; continue; }
        break
    done
    if _warp_add_rule "$kind" "$csv"; then
        _success "已写入 ${kind} 分流规则, xray 已用新配置重启"
        return 0
    fi
    _error "分流规则写入失败(配置已回滚或值非法)"
    return 1
}

_warp_set_endpoint_prompt() {
    local ep
    _warp_outbound_json >/dev/null || { _error "WARP 出站不存在"; return 1; }
    while true; do
        read -rp "  新 endpoint (回车取消): " ep || return 1
        [ -n "$ep" ] || { _info "已取消"; return 0; }
        _warp_endpoint_norm "$ep" >/dev/null && break
        _warn "endpoint 非法(例: 162.159.192.1:2408 或 [2606:4700::1]:2408), 请重新输入"
    done
    if _warp_set_endpoint "$ep"; then
        _success "endpoint 已更新, xray 已用新配置重启"
        return 0
    fi
    _error "endpoint 更新失败(配置已回滚)"
    return 1
}

_warp_delete_rule_prompt() {
    local list total n
    list=$(_warp_rules_list) || { _error "无法读取分流规则"; return 1; }
    [ -n "$list" ] || { _info "暂无 WARP 分流规则"; return 0; }
    printf '%s\n' "$list"
    total=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    while true; do
        read -rp "  请输入要删除的序号(0 取消): " n || return 1
        [ "$n" = "0" ] && { _info "已取消"; return 0; }
        _xd_index_from_choice "$n" "$total" >/dev/null && break
        _warn "序号无效, 请重新输入"
    done
    if _warp_delete_rule "$n"; then
        _success "已删除该条 WARP 分流规则, xray 已用新配置重启"
        return 0
    fi
    _error "删除失败(配置已回滚)"
    return 1
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

_warp_menu() {
    local choice st present endpoint addresses mtu rules
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【WARP (Cloudflare WireGuard 出站)】${NC}"
        echo
        present=0
        endpoint=""
        addresses=""
        mtu=""
        rules=""
        if st=$(_warp_state_summary); then
            IFS=$'\t' read -r present endpoint addresses mtu rules <<< "$st"
            if [ "$present" = "1" ]; then
                echo -e "  出站:      ${GREEN}已存在${NC} (tag=$WARP_TAG)"
                echo -e "  endpoint:  ${CYAN}${endpoint:-未知}${NC}"
                echo -e "  地址:      ${CYAN}${addresses:-未知}${NC}"
                echo -e "  MTU:       ${CYAN}${mtu:-未知}${NC}"
                echo -e "  分流规则:  ${CYAN}${rules:-0}${NC} 条"
            else
                echo -e "  出站:      ${YELLOW}未配置${NC}"
            fi
        else
            _warn "无法读取当前配置(Xray 未安装 / 配置缺失 / jq 不可用)"
        fi
        echo
        echo -e "  ${GREEN}[1]${NC} 注册 / 重新注册 WARP"
        echo -e "  ${GREEN}[2]${NC} 修改 endpoint"
        echo -e "  ${GREEN}[3]${NC} 添加分流规则 (domain / ip)"
        echo -e "  ${GREEN}[4]${NC} 查看分流规则"
        echo -e "  ${GREEN}[5]${NC} 删除分流规则"
        echo -e "  ${GREEN}[6]${NC} 删除 WARP 出站与全部分流规则"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            0) return ;;
            1) _warp_register; _press_any_key ;;
            2) _warp_set_endpoint_prompt; _press_any_key ;;
            3) _warp_add_rule_prompt; _press_any_key ;;
            4) _warp_rules_list || _error "无法读取分流规则"; _press_any_key ;;
            5) _warp_delete_rule_prompt; _press_any_key ;;
            6) _warp_delete_prompt; _press_any_key ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}
