#!/bin/bash
# =============================================================================
# lib/50-nodes.sh — 节点管理(7 协议)
# 需求 R6(协议集) + R7(按节点改监听) + R8(Reality 后量子)
# 配置以官方为准(design.md 配置依据表), 模板在 templates/ 下, 占位符 {{...}} 渲染.
# 节点元数据: $NODES_DIR/<tag>.json (按节点独立文件, 便于 R7 单节点改监听)
# ============================================================================

# ---------------------------------------------------------------------------
# 协议清单(R6)
# ---------------------------------------------------------------------------
PROTOCOLS=(
    "vless-tcp-reality-vision|VLESS+TCP+Reality+Vision|reality|direct|Tunnel模式·防偷跑"
    "vless-xhttp-reality|VLESS+XHTTP+Reality|reality|direct|Tunnel模式·防偷跑"
    "vless-enc|VLESS+ENC|enc|direct|内置加密·类似SS·轻量无TLS"
    "vless-xhttp-cdn|VLESS+XHTTP(无TLS)|none|cdn|必须套CDN·禁止直连"
    "vless-ws-cdn|VLESS+WS(无TLS)|none|cdn|必须套CDN·禁止直连"
    "shadowsocks|Shadowsocks|none|direct|"
    "hysteria2|Hysteria2|tls|direct|必须套TLS证书·QUIC"
)

# ---------------------------------------------------------------------------
# 带宽格式化: 纯数字自动补 mbps 单位
# ---------------------------------------------------------------------------
_normalize_bandwidth() {
    local v="$1"
    [ -z "$v" ] && { echo ""; return; }
    # 纯数字 → 补 mbps
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "${v} mbps"
    else
        echo "$v"
    fi
}

# ---------------------------------------------------------------------------
# iptables / 端口跳跃辅助(Hysteria2 端口跳跃用)
# 原理: iptables nat PREROUTING DNAT 把 UDP 端口范围转发到 hy2 监听端口
# 支持格式: "3010-3020" / "3050" / "3010-3020,3050,3100-3110" (逗号分隔混合)
# ---------------------------------------------------------------------------

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

# 为多个范围添加 DNAT 规则
_hy2_add_hop_rules() {
    local hy2_port="$1"; shift
    local range
    for range in "$@"; do
        iptables -t nat -A PREROUTING -p udp --dport "${range}" \
            -m comment --comment "xray-deploy-hy2-hop" \
            -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || return 1
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -A PREROUTING -p udp --dport "${range}" \
                -m comment --comment "xray-deploy-hy2-hop" \
                -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || true
        fi
    done
}

# 删除多个范围的 DNAT 规则
_hy2_remove_hop_rules() {
    local hy2_port="$1"; shift
    local range
    for range in "$@"; do
        iptables -t nat -D PREROUTING -p udp --dport "${range}" \
            -m comment --comment "xray-deploy-hy2-hop" \
            -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || true
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -t nat -D PREROUTING -p udp --dport "${range}" \
                -m comment --comment "xray-deploy-hy2-hop" \
                -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || true
        fi
    done
}

# 持久化 iptables 规则
_hy2_persist_iptables() {
    if command -v iptables-save >/dev/null 2>&1; then
        local fam
        fam=$(_detect_os_family)
        case "$fam" in
            debian)
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
                if command -v ip6tables-save >/dev/null 2>&1; then
                    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
                fi
                ;;
            alpine)
                if [ -x /etc/init.d/iptables ]; then
                    /etc/init.d/iptables save >/dev/null 2>&1 || true
                else
                    mkdir -p /etc/iptables
                    iptables-save > /etc/iptables/rules-save 2>/dev/null
                fi
                ;;
            *)
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null
                ;;
        esac
    fi
}

# 从元数据读取端口跳跃范围(兼容旧格式 hop_start/hop_end)
_read_hop_ranges() {
    local meta="$1"
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

# 列出所有 xray-deploy 端口跳跃规则
_hy2_list_all_hop_rules() {
    command -v iptables >/dev/null 2>&1 || return
    iptables -t nat -S PREROUTING 2>/dev/null | grep "xray-deploy-hy2-hop" || true
}

# 清理所有节点的端口跳跃 iptables 规则
_hy2_cleanup_all_hops() {
    command -v iptables >/dev/null 2>&1 || return 0
    [ -d "$NODES_DIR" ] || return 0
    local found=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local port ranges
        port=$(jq -r '.port' "$f" 2>/dev/null)
        ranges=$(_read_hop_ranges "$f")
        if [ -n "$ranges" ] && [ -n "$port" ]; then
            # shellcheck disable=SC2086
            _hy2_remove_hop_rules "$port" $ranges
            found=1
        fi
    done
    [ "$found" -eq 1 ] && _hy2_persist_iptables
}

# ---------------------------------------------------------------------------
# 通用端口输入(带冲突检测)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 通用端口输入(带冲突检测)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 通用端口输入(带冲突检测)

# ---------------------------------------------------------------------------
# 通用端口输入(带冲突检测)
# ---------------------------------------------------------------------------
# 生成随机端口(20000-65000)
_gen_random_port() {
    local lo hi range r
    lo=20000; hi=65000; range=$((hi-lo+1))
    # /dev/urandom 取 2 字节做随机数(无 Math.random 限制)
    r=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
    [ -z "$r" ] && r=${RANDOM:-12345}
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

# 检查端口是否已存在于 config.json
_check_port_in_config() {
    local port="$1"
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$CONFIG_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Reality 密钥生成(xray x25519)
# 输出全局: REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY / REALITY_SHORT_ID
# ---------------------------------------------------------------------------
_generate_reality_keys() {
    local keypair
    keypair=$("$XRAY_BIN" x25519 2>/dev/null)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk 'NR==1 {print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk 'NR==2 {print $NF}')
    REALITY_SHORT_ID=$(_gen_short_id)
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "Reality 密钥生成失败"
        return 1
    fi
    _info "Reality 密钥已生成 (PrivateKey: ${REALITY_PRIVATE_KEY:0:8}...)"
}

# ---------------------------------------------------------------------------
# 渲染模板:占位符替换 + jq 合法化
# 用法:_render_template <template_file>  (读取全局渲染变量)
# 输出:合法 JSON 到 stdout
# ---------------------------------------------------------------------------
_render_template() {
    local tpl="$1" content
    content=$(cat "$tpl" 2>/dev/null)
    [ -z "$content" ] && { _error "模板读取失败: $tpl"; return 1; }

    # 给所有占位符变量设默认空值(避免 set -u 下 unbound; 各协议函数只设自己需要的)
    : "${R_LISTEN:=}" "${R_PORT:=}" "${R_TAG:=}" "${R_UUID:=}" "${R_TARGET:=}"
    : "${R_SERVER_NAME:=}" "${R_PRIVATE_KEY:=}" "${R_SHORT_ID:=}" "${R_PATH:=}"
    : "${R_HOST:=}" "${R_METHOD:=}" "${R_PASSWORD:=}" "${R_MLDSA65_SEED:=}"
    : "${R_AUTH:=}" "${R_CERT_FILE:=}" "${R_KEY_FILE:=}"
    : "${R_CONGESTION:=}" "${R_BRUTAL_PARAMS_BLOCK:=}"
    : "${R_TUNNEL_PORT:=}" "${R_TUNNEL_TAG:=}"
    : "${R_FLOW:=}" "${R_DECRYPTION:=}" "${R_NETWORK:=}"

    # 模板已是纯 JSON(无注释),无需 sed 去注释

    # 占位符替换(用变量存 pattern, 避免 ${//\{\{...\}\}//} 转义歧义)
    local p
    p="{{LISTEN}}";       content="${content//$p/$R_LISTEN}"
    p="{{PORT}}";         content="${content//$p/$R_PORT}"
    p="{{TAG}}";          content="${content//$p/$R_TAG}"
    p="{{UUID}}";         content="${content//$p/$R_UUID}"
    p="{{TARGET}}";       content="${content//$p/$R_TARGET}"
    p="{{SERVER_NAME}}";  content="${content//$p/$R_SERVER_NAME}"
    p="{{PRIVATE_KEY}}";  content="${content//$p/$R_PRIVATE_KEY}"
    p="{{SHORT_ID}}";     content="${content//$p/$R_SHORT_ID}"
    p="{{PATH}}";         content="${content//$p/$R_PATH}"
    p="{{HOST}}";         content="${content//$p/$R_HOST}"
    p="{{METHOD}}";       content="${content//$p/$R_METHOD}"
    p="{{PASSWORD}}";     content="${content//$p/$R_PASSWORD}"
    p="{{TUNNEL_PORT}}";  content="${content//$p/$R_TUNNEL_PORT}"
    p="{{TUNNEL_TAG}}";   content="${content//$p/$R_TUNNEL_TAG}"
    p="{{FLOW}}";          content="${content//$p/$R_FLOW}"
    p="{{DECRYPTION}}";    content="${content//$p/$R_DECRYPTION}"
    p="{{NETWORK}}";      content="${content//$p/$R_NETWORK}"
    p="{{AUTH}}";         content="${content//$p/$R_AUTH}"
    p="{{CERT_FILE}}";    content="${content//$p/$R_CERT_FILE}"
    p="{{KEY_FILE}}";     content="${content//$p/$R_KEY_FILE}"
    p="{{CONGESTION}}";   content="${content//$p/$R_CONGESTION}"
    # Hysteria2 brutal 参数块(可选: brutal 模式注入, 否则置空)
    p="{{BRUTAL_PARAMS_BLOCK}}"
    if [ -n "$R_BRUTAL_PARAMS_BLOCK" ]; then
        content="${content//$p/$R_BRUTAL_PARAMS_BLOCK}"
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

# ---------------------------------------------------------------------------
# 统一的 config.json 修改流程: backup → jq → test → rollback/restart
# 用法:_mutate_config [--arg/--argjson ...] <jq_filter>
# 参数: jq 选项在前, jq filter 在最后(必须)
# 所有 config 修改应通过此函数, 不再各自实现 backup/test/rollback
# ---------------------------------------------------------------------------
_mutate_config() {
    _backup_config
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    # 获取最后一个参数(用户 filter), 其余是 jq 选项
    local user_filter="${!#}"
    # 应用 filter 后, 按 Xray 官方文档顺序重排顶层字段(单 filter, 不依赖 jq 多 filter 拼接)
    local reorder='| . as $c | {log: $c.log, api: $c.api, dns: $c.dns, routing: $c.routing, policy: $c.policy, inbounds: $c.inbounds, outbounds: $c.outbounds, stats: $c.stats, fakedns: $c.fakedns, metrics: $c.metrics, observatory: $c.observatory, burstObservatory: $c.burstObservatory, geodata: $c.geodata, version: $c.version} | with_entries(select(.value != null))'
    local combined="${user_filter} ${reorder}"
    # 构建参数列表: 去掉最后一个(filter), 追加合并后的 filter
    local args=("${@:1:$#-1}" "${combined}")
    if ! jq "${args[@]}" "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; _error "jq 处理失败"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; _error "生成的配置为空"; return 1
    fi
    mv -f "$tmp" "$CONFIG_FILE"
    if ! _xray_test_config; then
        _error "配置校验失败,回滚"
        _restore_config
        return 1
    fi
    _manage_xray restart 2>/dev/null || _manage_xray start 2>/dev/null
    return 0
}

# 把渲染好的 inbound 加入 config.json
_commit_inbound() {
    local inbound="$1"
    _mutate_config --argjson nb "$inbound" '.inbounds += [$nb]' || return 1
}

# Reality 专用: tunnel + reality inbound + 2 条路由规则
_commit_reality_inbound() {
    local tunnel="$1" reality="$2" tunnel_tag="$3" domain="$4"
    _mutate_config --argjson tb "$tunnel" --argjson rb "$reality" \
       --arg tg "$tunnel_tag" --arg dom "$domain" \
       '.inbounds += [$tb, $rb] | .routing.rules += [
            {inboundTag: [$tg], domain: [$dom], outboundTag: "direct"},
            {inboundTag: [$tg], outboundTag: "block"}]' || return 1
}

# ---------------------------------------------------------------------------
# 保存节点元数据(每节点独立文件)
# 用法:_save_node_meta <tag> <json_object>
# ---------------------------------------------------------------------------
_save_node_meta() {
    local tag="$1" json="$2"
    mkdir -p "$NODES_DIR"
    printf '%s' "$json" | jq . > "$NODES_DIR/${tag}.json" 2>/dev/null || printf '%s' "$json" > "$NODES_DIR/${tag}.json"
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
            read -rp "  客户端连接地址: " addr
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

# ---------------------------------------------------------------------------
# 列出 config.json 中有元数据文件的入站 tag 集合(含 tunnel_tag)
# 输出: 每行一个 tag
# ---------------------------------------------------------------------------
_known_tags() {
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        basename "$f" .json
        local ttag
        ttag=$(jq -r '.tunnel_tag // empty' "$f" 2>/dev/null)
        [ -n "$ttag" ] && echo "$ttag"
    done
}

# ---------------------------------------------------------------------------
# 给 config.json 中无 tag 的入站自动分配 tag
# 有 port: manual-<port> (如 manual-443)
# Unix socket: manual-<socket文件名去后缀> (如 manual-xrxh-socket)
# ---------------------------------------------------------------------------
_auto_tag_tagless_inbounds() {
    [ -f "$CONFIG_FILE" ] || return 0
    # 一次性读取所有入站的 tag/port/listen, 减少 jq 调用
    local inbounds_info
    inbounds_info=$(jq -c '[.inbounds | to_entries[] | {idx: .key, tag: (.value.tag // ""), port: (.value.port // 0), listen: (.value.listen // "")}]' "$CONFIG_FILE" 2>/dev/null) || return 0
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

        local tmp
        tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
        jq --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].tag = $t' "$CONFIG_FILE" > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"
        tagged=$((tagged+1))
    done <<< "$(jq -c '.[]' <<< "$inbounds_info" 2>/dev/null)"

    [ "$tagged" -gt 0 ] && _info "已自动给 ${tagged} 个无 tag 入站分配标识"
    return 0
}

# ---------------------------------------------------------------------------
# 采纳单个入站: 从 config.json 推断元数据, 创建 nodes/*.json
# 返回 0 = 成功, 1 = 跳过(tunnel)
# ---------------------------------------------------------------------------
_adopt_single_inbound() {
    local tag="$1" suffix="${2:-adopted}"
    local proto port listen
    proto=$(_detect_inbound_protocol "$tag")
    [ "$proto" = "tunnel" ] && return 1

    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // 0' "$CONFIG_FILE" 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    listen=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen // "::"' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$listen" ] && listen="::"

    local uuid=""
    uuid=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.clients[0].id // empty' "$CONFIG_FILE" 2>/dev/null)
    local sni=""
    sni=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE" 2>/dev/null)

    local link="#${tag} (${suffix})"
    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg proto "$proto" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg sni "$sni" --arg link "$link" \
        '{tag:$tag,name:$tag,protocol:$proto,port:$port,listen:$listen,uuid:$uuid,sni:$sni,link_addr:"",share_link:$link}')"
    return 0
}

# ---------------------------------------------------------------------------
# 自动采纳孤儿入站: 为无元数据的入站创建 nodes/*.json
# 启动时静默运行, 不询问用户
# ---------------------------------------------------------------------------
_auto_adopt_orphans() {
    [ -f "$CONFIG_FILE" ] || return 0
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"
    local known_list
    known_list=$(_known_tags)

    local tags_json
    tags_json=$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE" 2>/dev/null)
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
# 检测 config.json 中的孤儿入站(手动添加,无元数据)
# 返回 0 = 有孤儿, 1 = 无
# ---------------------------------------------------------------------------
_has_orphan_inbounds() {
    [ -f "$CONFIG_FILE" ] || return 1
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"
    local tags_json
    tags_json=$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE" 2>/dev/null) || return 1
    [ -z "$tags_json" ] && return 1
    [ "$tags_json" = "[]" ] && return 1
    local known_list
    known_list=$(_known_tags)
    local tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if ! grep -qxF "$tag" <<< "$known_list"; then
            return 0
        fi
    done <<< "$(jq -r '.[]' <<< "$tags_json" 2>/dev/null)"
    return 1
}

# ---------------------------------------------------------------------------
# 从 config.json 入站推断协议类型(按 tag)
# ---------------------------------------------------------------------------
_detect_inbound_protocol() {
    local tag="$1"
    local proto security net
    proto=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .protocol' "$CONFIG_FILE" 2>/dev/null)
    [ "$proto" = "tunnel" ] && { echo "tunnel"; return; }
    if [ "$proto" = "vless" ]; then
        security=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.security // "none"' "$CONFIG_FILE" 2>/dev/null)
        net=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.network // "raw"' "$CONFIG_FILE" 2>/dev/null)
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
                dec=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.decryption // empty' "$CONFIG_FILE" 2>/dev/null)
                if [ -n "$dec" ] && [ "$net" = "raw" ]; then
                    echo "vless-enc"
                else
                    echo "vless-$net"
                fi
                ;;
        esac
    elif [ "$proto" = "shadowsocks" ]; then
        echo "shadowsocks"
    elif [ "$proto" = "hysteria2" ]; then
        echo "hysteria2"
    else
        echo "$proto"
    fi
}

# ---------------------------------------------------------------------------
# 同步配置: 检测孤儿入站, 提供清理/采纳选项
# ---------------------------------------------------------------------------
_sync_config_check() {
    clear
    echo
    echo -e "  ${CYAN}【同步配置入站】${NC}"
    echo -e "  扫描 config.json 中未由脚本管理的入站..."
    echo

    [ -f "$CONFIG_FILE" ] || { _warn "config.json 不存在"; _press_any_key; return; }
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"

    # 先自动给无 tag 入站分配 tag(幂等, 已分配的不变)
    _auto_tag_tagless_inbounds

    local tags_json
    tags_json=$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$tags_json" ] || [ "$tags_json" = "[]" ]; then
        _info "config.json 无任何入站"
        _press_any_key; return
    fi

    local known_list
    known_list=$(_known_tags)

    local orphans=()
    local tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if ! grep -qxF "$tag" <<< "$known_list"; then
            orphans+=("$tag")
        fi
    done <<< "$(jq -r '.[]' <<< "$tags_json" 2>/dev/null)"

    if [ ${#orphans[@]} -eq 0 ]; then
        _success "所有入站均由脚本管理, 无需同步"
        _press_any_key; return
    fi

    echo -e "  ${YELLOW}发现 ${#orphans[@]} 个未跟踪入站:${NC}"
    echo
    printf "  %-3s %-30s %-16s %-7s %-8s\n" "#" "Tag" "协议" "端口" "监听"
    echo "  ---------------------------------------------------------------------------"
    local i=1
    for tag in "${orphans[@]}"; do
        local proto port listen
        proto=$(_detect_inbound_protocol "$tag")
        port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // "-"' "$CONFIG_FILE" 2>/dev/null)
        listen=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen // "::"' "$CONFIG_FILE" 2>/dev/null)
        [ ${#tag} -gt 28 ] && tag="${tag:0:25}..."
        printf "  %-3s %-30s %-16s %-7s %-8s\n" "[$i]" "$tag" "$proto" "$port" "$listen"
        i=$((i+1))
    done
    echo
    echo -e "  ${GREEN}[1]${NC} 从 config.json 移除选中入站"
    echo -e "  ${GREEN}[2]${NC} 移除全部未跟踪入站"
    echo -e "  ${GREEN}[3]${NC} 采纳为脚本管理节点(创建元数据)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  请选择: " action

    case "$action" in
        1)
            read -rp "  输入要移除的编号(逗号分隔, 如 1,3,5): " sel
            local to_remove=()
            IFS=',' read -ra nums <<< "$sel"
            for n in "${nums[@]}"; do
                n=$(echo "$n" | tr -d ' ')
                [[ "$n" =~ ^[0-9]+$ ]] || continue
                local idx=$((n-1))
                [ "$idx" -ge 0 ] && [ "$idx" -lt "${#orphans[@]}" ] && to_remove+=("${orphans[$idx]}")
            done
            [ ${#to_remove[@]} -eq 0 ] && { _warn "无有效选择"; _press_any_key; return; }
            _remove_orphan_inbounds "${to_remove[@]}"
            ;;
        2)
            echo -e "  ${RED}确认移除全部 ${#orphans[@]} 个未跟踪入站?${NC}"
            read -rp "  继续? [y/N]: " ans
            case "$ans" in
                y|Y) _remove_orphan_inbounds "${orphans[@]}" ;;
                *) _info "已取消" ;;
            esac
            ;;
        3)
            _adopt_orphan_inbounds "${orphans[@]}"
            ;;
        *)
            _info "已取消"
            ;;
    esac
    _press_any_key
}

# ---------------------------------------------------------------------------
# 从 config.json 移除孤儿入站 + 关联路由规则
# ---------------------------------------------------------------------------
_remove_orphan_inbounds() {
    local tags=("$@")
    [ ${#tags[@]} -eq 0 ] && return 0

    local tags_json
    tags_json=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -c -s .)

    local filter='.inbounds |= map(select(.tag as $t | ($rm | index($t)) | not))
                 | .routing.rules |= map(select(.inboundTag == null
                       or ([.inboundTag[]? | . as $it | ($rm | index($it)) == null] | all)))'

    if _mutate_config --argjson rm "$tags_json" "$filter"; then
        _success "已移除 ${#tags[@]} 个入站"
    else
        _error "移除失败, 已回滚"
    fi
}

# ---------------------------------------------------------------------------
# 采纳孤儿入站: 从 config.json 推断元数据, 创建 nodes/*.json
# ---------------------------------------------------------------------------
_adopt_orphan_inbounds() {
    local tags=("$@")
    local adopted=0
    for tag in "${tags[@]}"; do
        if _adopt_single_inbound "$tag" "adopted"; then
            adopted=$((adopted+1))
            _info "已采纳: $tag"
        fi
    done
    _success "已采纳 ${adopted} 个入站(分享链接需手动重建)"
    _tip "采纳的节点缺少完整参数, 建议使用 [查看节点] 确认, 或删后重建"
}

# ---------------------------------------------------------------------------
# 添加节点:协议分发
# PROTOCOLS 的 name 字段已含对齐空格, 直接打印
# ---------------------------------------------------------------------------
_add_node() {
    clear
    [ -x "$XRAY_BIN" ] || { _error "Xray 未安装,请先在 [6] 安装/切换 Xray 核心"; _press_any_key; return 1; }
    _ensure_dirs
    echo
    echo -e "  ${CYAN}【添加节点 — 选择协议】${NC}"
    echo -e "  ${YELLOW}提示: 标记「必须套CDN」的协议不能直连, 需经 CDN 回源${NC}"
    echo
    local i=1
    for p in "${PROTOCOLS[@]}"; do
        local key name desc
        IFS='|' read -r key name _ _ desc <<< "$p"
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
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1))
    local sel="${PROTOCOLS[$idx]:-}"
    [ -z "$sel" ] && { _warn "无效选择"; _press_any_key; return; }

    local key
    IFS='|' read -r key _ _ _ _ <<< "$sel"
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

# ---------------------------------------------------------------------------
# 协议1: VLESS+TCP+Reality+Vision (Tunnel 模式, 防偷跑)
# ---------------------------------------------------------------------------
_add_vless_tcp_reality_vision() {
    echo -e "\n  ${CYAN}=== VLESS+TCP+Reality+Vision (Tunnel 模式) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}

    local tunnel_port=$(_gen_random_port)
    _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)

    local default_name="Reality-Vision-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    local tag="xd-reality-vision-${port}"
    local tunnel_tag="Tunnel-${sni}-${tunnel_port}-${port}"
    local listen="::"

    # 渲染 tunnel inbound
    R_LISTEN="127.0.0.1" R_PORT="$tunnel_port" R_TAG="$tunnel_tag" R_TARGET="$sni"
    local tunnel_json
    tunnel_json=$(_render_template "$(_tpl_path tunnel)") || return 1

    # 渲染 reality inbound
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
    R_SERVER_NAME="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
    R_SHORT_ID="$REALITY_SHORT_ID" R_TUNNEL_PORT="$tunnel_port" R_MLDSA65_SEED="$pq_seed"
    local reality_json
    reality_json=$(_render_template "$(_tpl_path vless-tcp-reality-vision)") || return 1

    _commit_reality_inbound "$tunnel_json" "$reality_json" "$tunnel_tag" "$sni" || return 1

    local addr; addr=$(_ask_link_addr)
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    local link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=raw&headerType=none&flow=xtls-rprx-vision&sni=${sni}&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local clash="- {name: \"$name\", type: vless, server: $addr, port: $port, uuid: $uuid, flow: xtls-rprx-vision, tls: true, servername: $sni, \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID}, \"client-fingerprint\": chrome, network: tcp}"
    _add_node_to_yaml "$clash"

    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-tcp-reality-vision" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg pqv "$pq_verify" --arg link "$link" \
        --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,mldsa65_verify:$pqv,share_link:$link,tunnel_tag:$ttag,tunnel_port:$tport}')"

    _success "节点 [${name}] 创建成功"
    _tip "Tunnel: ${tunnel_port} → ${sni}:443 | Reality: ${port}"
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议2: VLESS+XHTTP+Reality (Tunnel 模式, 防偷跑)
# ---------------------------------------------------------------------------
_add_vless_xhttp_reality() {
    echo -e "\n  ${CYAN}=== VLESS+XHTTP+Reality (Tunnel 模式) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}

    local tunnel_port=$(_gen_random_port)
    _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)

    local path=$(_gen_rand_path)
    read -rp "  XHTTP path (默认 ${path}): " custom_path
    path=${custom_path:-$path}

    local default_name="Reality-XHTTP-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    local tag="xd-reality-xhttp-${port}"
    local tunnel_tag="Tunnel-${sni}-${tunnel_port}-${port}"
    local listen="::"

    R_LISTEN="127.0.0.1" R_PORT="$tunnel_port" R_TAG="$tunnel_tag" R_TARGET="$sni"
    local tunnel_json
    tunnel_json=$(_render_template "$(_tpl_path tunnel)") || return 1

    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
    R_SERVER_NAME="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
    R_SHORT_ID="$REALITY_SHORT_ID" R_PATH="$path" R_TUNNEL_PORT="$tunnel_port" R_MLDSA65_SEED="$pq_seed"
    local reality_json
    reality_json=$(_render_template "$(_tpl_path vless-xhttp-reality)") || return 1

    _commit_reality_inbound "$tunnel_json" "$reality_json" "$tunnel_tag" "$sni" || return 1

    local addr; addr=$(_ask_link_addr)
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    local link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=xhttp&mode=auto&sni=${sni}&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}&path=$(_url_encode "$path")"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local clash="- {name: \"$name\", type: vless, server: $addr, port: $port, uuid: $uuid, network: xhttp, tls: true, servername: $sni, \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID}, \"client-fingerprint\": chrome, \"xhttp-opts\": {path: \"$path\"}}"
    _add_node_to_yaml "$clash"

    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-reality" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg path "$path" --arg pqv "$pq_verify" --arg link "$link" \
        --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,path:$path,mldsa65_verify:$pqv,share_link:$link,tunnel_tag:$ttag,tunnel_port:$tport}')"

    _success "节点 [${name}] 创建成功"
    _tip "Tunnel: ${tunnel_port} → ${sni}:443 | Reality: ${port}"
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议3: VLESS+ENC (内置加密, 无 TLS, 类似 SS 轻量直连)
# 通过 xray vlessenc 生成 decryption(服务端)/encryption(客户端) 密钥对
# 来源: Xray-docs-next vless.md + PR #5067
# ---------------------------------------------------------------------------

# 生成 VLESS+ENC 密钥对(xray vlessenc)
# 输出全局: VLESS_ENC_DECRYPTION / VLESS_ENC_ENCRYPTION
# 注意: xray vlessenc 输出可能不是纯 JSON(有额外文本), jq 优先, grep 兜底
_generate_vless_enc_keys() {
    local output
    output=$("$XRAY_BIN" vlessenc 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$output" ]; then
        _error "VLESS+ENC 密钥生成失败 (需要较新版本的 Xray 核心)"
        return 1
    fi
    # jq 优先(纯 JSON 场景)
    VLESS_ENC_DECRYPTION=$(echo "$output" | jq -r '.decryption // empty' 2>/dev/null)
    VLESS_ENC_ENCRYPTION=$(echo "$output" | jq -r '.encryption // empty' 2>/dev/null)
    # grep + sed 兜底(输出含额外文本时 jq 会失败)
    if [ -z "$VLESS_ENC_DECRYPTION" ]; then
        VLESS_ENC_DECRYPTION=$(echo "$output" | grep '"decryption"' | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    if [ -z "$VLESS_ENC_ENCRYPTION" ]; then
        VLESS_ENC_ENCRYPTION=$(echo "$output" | grep '"encryption"' | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    if [ -z "$VLESS_ENC_DECRYPTION" ] || [ -z "$VLESS_ENC_ENCRYPTION" ]; then
        _error "VLESS+ENC 密钥解析失败 (xray vlessenc 输出格式异常)"
        return 1
    fi
    _info "VLESS+ENC 密钥已生成 (decryption: ${VLESS_ENC_DECRYPTION:0:30}...)"
}

_add_vless_enc() {
    echo -e "\n  ${CYAN}=== VLESS+ENC (内置加密 · 无 TLS · 类似 SS 轻量直连) ===${NC}"
    local port=$(_input_port tcp)

    # flow 选项(xtls-rprx-vision 可启用 splice 优化)
    echo -e "  流控模式:"
    echo -e "  ${GREEN}[1]${NC} 无 (默认, 通用兼容)"
    echo -e "  ${GREEN}[2]${NC} xtls-rprx-vision (splice 优化, 性能更好)"
    read -rp "  选择 (默认 1): " flow_choice
    local flow=""
    [ "${flow_choice:-1}" = "2" ] && flow="xtls-rprx-vision"

    local default_name="ENC-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_vless_enc_keys || return 1

    local tag="xd-vless-enc-${port}"
    local listen="::"

    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
    R_FLOW="$flow" R_DECRYPTION="$VLESS_ENC_DECRYPTION"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-enc)") || return 1
    _commit_inbound "$inbound" || return 1

    local addr; addr=$(_ask_link_addr)
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"

    # 分享链接: encryption 参数为客户端密钥(URL 编码, 含点号和特殊字符)
    local enc_encoded; enc_encoded=$(_url_encode "$VLESS_ENC_ENCRYPTION")
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_encoded}&security=none&type=raw"
    [ -n "$flow" ] && link="${link}&flow=${flow}"
    link="${link}#$(_url_encode "$name")"

    # clash yaml (Clash Meta / mihomo 格式)
    local clash_flow=""
    [ -n "$flow" ] && clash_flow=", flow: ${flow}"
    local clash="- {name: \"$name\", type: vless, server: $addr, port: $port, uuid: $uuid, network: tcp, tls: false, \"vless-enc-opts\": {encryption: \"$VLESS_ENC_ENCRYPTION\"}${clash_flow}}"
    _add_node_to_yaml "$clash"

    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-enc" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg flow "$flow" \
        --arg dec "$VLESS_ENC_DECRYPTION" --arg enc "$VLESS_ENC_ENCRYPTION" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,flow:$flow,decryption:$dec,encryption:$enc,share_link:$link}')"

    _success "节点 [${name}] 创建成功"
    [ -n "$flow" ] && _tip "已启用 xtls-rprx-vision (splice 优化)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议4: VLESS+XHTTP(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_xhttp_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+XHTTP (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port
    while true; do
        port=$(_input_port tcp)
        # 走 CDN 建议用 CF 支持的 HTTP 端口
        case "$port" in 80|8080|8880|2052|2082|2086|2095|443|2053|2083|2087|2096|8443) break ;; *)
            _warn "无TLS走CDN建议用 CF 支持的端口(80/8080/2052/2086/2095 等),仍可继续"; break ;;
        esac
    done

    local host
    read -rp "  CDN 域名(Host, 你在 CF 绑定的域名): " host
    [ -z "$host" ] && { _warn "CDN 协议必须填域名"; return 1; }
    local path=$(_gen_rand_path)
    read -rp "  XHTTP path (默认 ${path}): " custom_path
    path=${custom_path:-$path}

    local default_name="XHTTP-CDN-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local uuid; uuid=$(_gen_uuid) || return 1
    local tag="xd-xhttp-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-xhttp-cdn)") || return 1
    _commit_inbound "$inbound" || return 1

    # 链接服务器地址 = CDN 域名(必须)
    local link="vless://${uuid}@${host}:${port}?encryption=none&security=none&type=xhttp&mode=auto&host=${host}&path=$(_url_encode "$path")#$(_url_encode "$name")"
    local clash="- {name: \"$name\", type: vless, server: $host, port: $port, uuid: $uuid, network: xhttp, \"xhttp-opts\": {path: \"$path\", host: $host}}"
    _add_node_to_yaml "$clash"

    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-cdn" \
        --argjson port "$port" --arg listen "$listen" --arg host "$host" \
        --arg uuid "$uuid" --arg path "$path" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$host,uuid:$uuid,host:$host,path:$path,share_link:$link}')"

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
    local path=$(_gen_rand_path)
    read -rp "  WS path (默认 ${path}): " custom_path
    path=${custom_path:-$path}

    local default_name="WS-CDN-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local uuid; uuid=$(_gen_uuid) || return 1
    local tag="xd-ws-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-ws-cdn)") || return 1
    _commit_inbound "$inbound" || return 1

    local link="vless://${uuid}@${host}:${port}?encryption=none&security=none&type=ws&host=${host}&path=$(_url_encode "$path")#$(_url_encode "$name")"
    local clash="- {name: \"$name\", type: vless, server: $host, port: $port, uuid: $uuid, network: ws, \"ws-opts\": {path: \"$path\", headers: {Host: $host}}}"
    _add_node_to_yaml "$clash"

    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-ws-cdn" \
        --argjson port "$port" --arg listen "$listen" --arg host "$host" \
        --arg uuid "$uuid" --arg path "$path" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$host,uuid:$uuid,host:$host,path:$path,share_link:$link}')"

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

    local default_name="SS-${method%%-*}-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local tag="xd-ss-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_METHOD="$method" R_PASSWORD="$password" R_NETWORK="$network_val"
    local inbound
    inbound=$(_render_template "$(_tpl_path shadowsocks)") || return 1
    _commit_inbound "$inbound" || return 1

    local addr
    addr=$(_ask_link_addr)
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    # ss 链接: ss://base64(method:password)@host:port#name
    local userinfo="${method}:${password}"
    local b64=$(printf '%s' "$userinfo" | base64 | tr -d '\n')
    local link="ss://${b64}@${link_ip}:${port}#$(_url_encode "$name")"

    local clash="- {name: \"$name\", type: ss, server: $addr, port: $port, cipher: $method, password: \"$password\"}"
    _add_node_to_yaml "$clash"

    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "shadowsocks" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg method "$method" --arg password "$password" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,method:$method,password:$password,share_link:$link}')"

    _success "节点 [${name}] 创建成功"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议7: Hysteria2 (QUIC + TLS证书)
# 模板: templates/hysteria2.server.jsonc
# 来源: Xray-examples/Hysteria2/server.jsonc + Xray-docs-next hysteria.md / finalmask.md
# ---------------------------------------------------------------------------
# 生成 Hysteria2 自签 TLS 证书(EC-256, 10 年)
# 用法:_gen_hy2_cert <tag>  输出: CERT_FILE_PATH / KEY_FILE_PATH 全局变量
_gen_hy2_cert() {
    local tag="$1"
    local cert_dir="$CERT_DIR/$tag"
    mkdir -p "$cert_dir"
    CERT_FILE_PATH="${cert_dir}/cert.pem"
    KEY_FILE_PATH="${cert_dir}/key.pem"
    if [ -f "$CERT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
        _info "已有证书, 复用: $cert_dir"
        return 0
    fi
    _info "生成 TLS 自签证书..."
    if command -v openssl >/dev/null 2>&1; then
        openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE_PATH" 2>/dev/null \
            && openssl req -new -x509 -days 3650 -key "$KEY_FILE_PATH" \
                -out "$CERT_FILE_PATH" -subj "/CN=build.nvidia.com" 2>/dev/null
    elif [ -x "$XRAY_BIN" ]; then
        "$XRAY_BIN" tls cert --domain build.nvidia.com --file "$cert_dir" 2>/dev/null
        # xray tls cert 输出: cert.pem / key.pem(同名)
        [ -f "${cert_dir}/cert.pem" ] && mv -f "${cert_dir}/cert.pem" "$CERT_FILE_PATH"
        [ -f "${cert_dir}/key.pem" ] && mv -f "${cert_dir}/key.pem" "$KEY_FILE_PATH"
    fi
    if [ ! -f "$CERT_FILE_PATH" ] || [ ! -f "$KEY_FILE_PATH" ]; then
        _error "证书生成失败, 需安装 openssl 或使用 xray tls cert"
        return 1
    fi
    _success "TLS 证书已生成: $cert_dir"
}

_add_hysteria2() {
    echo -e "\n  ${CYAN}=== Hysteria2 (QUIC · 可直连 · 需 TLS 证书) ===${NC}"
    local port=$(_input_port udp)

    # TLS 证书: 回车自签, 或输入证书路径
    local tag="xd-hy2-${port}"
    local cert_file="" key_file="" self_signed="false" sni="build.nvidia.com"
    echo -e "  TLS 证书:"
    echo -e "  回车使用自签证书, 或输入证书文件路径"
    read -rp "  cert 路径 (回车自签): " custom_cert
    if [ -n "$custom_cert" ]; then
        read -rp "  key 路径: " custom_key
        if [ ! -f "$custom_cert" ] || [ ! -f "$custom_key" ]; then
            _error "证书文件不存在"; return 1
        fi
        cert_file="$custom_cert"; key_file="$custom_key"
        _info "使用自定义证书: $cert_file"
        # 从证书提取 CN 作为 SNI 建议
        local cert_cn=""
        if command -v openssl >/dev/null 2>&1; then
            cert_cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's/\/.*//')
        fi
        if [ -n "$cert_cn" ]; then
            read -rp "  SNI (默认 ${cert_cn}): " custom_sni
            sni=${custom_sni:-$cert_cn}
        else
            read -rp "  SNI (证书域名): " custom_sni
            sni=${custom_sni:-build.nvidia.com}
        fi
    else
        _gen_hy2_cert "$tag" || return 1
        cert_file="$CERT_FILE_PATH"; key_file="$KEY_FILE_PATH"
        self_signed="true"
    fi

    # 认证密码
    local auth
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  认证密码 (回车随机): " custom_auth
    auth=${custom_auth:-$auth}

    # 拥塞控制
    echo -e "  拥塞控制:"
    echo -e "  ${GREEN}[1]${NC} bbr"
    echo -e "  ${GREEN}[2]${NC} brutal"
    echo -e "  ${GREEN}[3]${NC} force-brutal"
    read -rp "  选择 (默认 1): " cc_choice
    local congestion="bbr"
    local brutal_up="" brutal_down=""
    case "${cc_choice:-1}" in
        2|3)
            [ "${cc_choice}" = "3" ] && congestion="force-brutal" || congestion="brutal"
            echo -e "  ${YELLOW}${congestion} 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
            read -rp "  上传带宽 (服务器→客户端, 回车不限): " brutal_up
            read -rp "  下载带宽 (客户端→服务器, 回车不限): " brutal_down
            brutal_up=$(_normalize_bandwidth "$brutal_up")
            brutal_down=$(_normalize_bandwidth "$brutal_down")
            ;;
    esac

    local default_name="HY2-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}

    local listen="::"

    # 构建 brutal 参数块(brutal / force-brutal 模式有值)
    local brutal_block=""
    if [ "$congestion" = "brutal" ] || [ "$congestion" = "force-brutal" ]; then
        brutal_block=""
        [ -n "$brutal_up" ] && brutal_block="${brutal_block}, \"brutalUp\": \"${brutal_up}\""
        [ -n "$brutal_down" ] && brutal_block="${brutal_block}, \"brutalDown\": \"${brutal_down}\""
    fi

    # 渲染模板
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag"
    R_AUTH="$auth" R_CERT_FILE="$cert_file" R_KEY_FILE="$key_file"
    R_CONGESTION="$congestion" R_BRUTAL_PARAMS_BLOCK="$brutal_block"
    local inbound
    inbound=$(_render_template "$(_tpl_path hysteria2)") || return 1

    _commit_inbound "$inbound" || return 1

    local addr
    addr=$(_ask_link_addr)
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"

    # hy2:// 分享链接(标准格式: hy2://password@host:port/?sni=...&insecure=...&congestion=...)
    local link="hy2://${auth}@${link_ip}:${port}/?sni=${sni}"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1&allowInsecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
    link="${link}#$(_url_encode "$name")"

    # clash yaml
    local clash_insecure=""
    [ "$self_signed" = "true" ] && clash_insecure=", skip-cert-verify: true"
    local clash="- {name: \"$name\", type: hysteria2, server: $addr, port: $port, password: \"$auth\", sni: ${sni}, \"congestion-control\": $congestion${clash_insecure}}"
    _add_node_to_yaml "$clash"

    # 元数据
    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "hysteria2" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg auth "$auth" --arg sni "$sni" --arg congestion "$congestion" \
        --arg brutalUp "$brutal_up" --arg brutalDown "$brutal_down" \
        --arg link "$link" --argjson ss "$self_signed" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,auth:$auth,sni:$sni,congestion:$congestion,brutal_up:$brutalUp,brutal_down:$brutalDown,self_signed:$ss,share_link:$link}')"

    _success "节点 [${name}] 创建成功"
    if [ "$self_signed" = "true" ]; then
        _tip "自签证书, 客户端须手动信任证书 (insecure=1)"
    else
        _tip "使用自定义证书, SNI: ${sni}"
    fi
    echo -e "  ${CYAN}拥塞控制:${NC} ${congestion}"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 分享链接重建(HY2 / Reality 域名切换后更新链接用)
# ---------------------------------------------------------------------------

# 重建 hy2:// 分享链接(从元数据读参数)
# 用法:_rebuild_hy2_link <meta_file>
_rebuild_hy2_link() {
    local meta="$1"
    local auth host port sni congestion brutal_up brutal_down name self_signed
    auth=$(jq -r '.auth' "$meta")
    host=$(jq -r '.link_addr' "$meta")
    port=$(jq -r '.port' "$meta")
    sni=$(jq -r '.sni // "build.nvidia.com"' "$meta")
    congestion=$(jq -r '.congestion' "$meta")
    brutal_up=$(jq -r '.brutal_up // empty' "$meta")
    brutal_down=$(jq -r '.brutal_down // empty' "$meta")
    self_signed=$(jq -r '.self_signed // "false"' "$meta")
    name=$(jq -r '.name' "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link="hy2://${auth}@${link_ip}:${port}/?sni=${sni}"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1&allowInsecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
    # 端口跳跃端口(如果已配置)
    local hop_ports
    hop_ports=$(jq -r '.udp_hop_ports // empty' "$meta" 2>/dev/null)
    [ -n "$hop_ports" ] && link="${link}&mport=$(_url_encode "$hop_ports")"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 vless:// reality 分享链接(从元数据读参数)
# 用法:_rebuild_reality_link <meta_file> [new_sni]  不传 new_sni 则用 meta 里的 sni
_rebuild_reality_link() {
    local meta="$1" new_sni="${2:-}"
    local uuid host port proto sni pk sid pqv name path
    uuid=$(jq -r '.uuid' "$meta")
    host=$(jq -r '.link_addr' "$meta")
    port=$(jq -r '.port' "$meta")
    proto=$(jq -r '.protocol' "$meta")
    sni=$(jq -r '.sni' "$meta")
    [ -n "$new_sni" ] && sni="$new_sni"
    pk=$(jq -r '.public_key' "$meta")
    sid=$(jq -r '.short_id' "$meta")
    pqv=$(jq -r '.mldsa65_verify // empty' "$meta")
    name=$(jq -r '.name' "$meta")
    path=$(jq -r '.path // empty' "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link
    case "$proto" in
        vless-tcp-reality-vision)
            link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=raw&headerType=none&flow=xtls-rprx-vision&sni=${sni}&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}"
            ;;
        vless-xhttp-reality)
            link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=xhttp&mode=auto&sni=${sni}&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}&path=$(_url_encode "$path")"
            ;;
        *) echo ""; return 1 ;;
    esac
    [ -n "$pqv" ] && link="${link}&pqv=${pqv}"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# ---------------------------------------------------------------------------
# 模板路径辅助
# ---------------------------------------------------------------------------
_tpl_path() {
    local key="$1"
    case "$key" in
        vless-tcp-reality-vision) echo "/opt/xray-deploy/templates/vless-tcp-reality-vision-tunnel.server.jsonc" ;;
        vless-xhttp-reality)      echo "/opt/xray-deploy/templates/vless-xhttp-reality-tunnel.server.jsonc" ;;
        tunnel)                   echo "/opt/xray-deploy/templates/tunnel.server.jsonc" ;;
        vless-enc)                echo "/opt/xray-deploy/templates/vless-enc.server.jsonc" ;;
        vless-xhttp-cdn)          echo "/opt/xray-deploy/templates/vless-xhttp-cdn.server.jsonc" ;;
        vless-ws-cdn)             echo "/opt/xray-deploy/templates/vless-ws-cdn.server.jsonc" ;;
        shadowsocks)              echo "/opt/xray-deploy/templates/shadowsocks.server.jsonc" ;;
        hysteria2)                echo "/opt/xray-deploy/templates/hysteria2.server.jsonc" ;;
    esac
}

# ---------------------------------------------------------------------------
# 查看节点(含监听列 R7)
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
    printf "  %-3s %-20s %-26s %-7s %-16s %-18s\n" "#" "名称" "协议" "端口" "监听" "链接地址"
    echo "  ---------------------------------------------------------------------------------------"
    local i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name proto port listen addr
        name=$(jq -r '.name' "$f" 2>/dev/null)
        proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        port=$(jq -r '.port' "$f" 2>/dev/null)
        listen=$(jq -r '.listen' "$f" 2>/dev/null)
        addr=$(jq -r '.link_addr' "$f" 2>/dev/null)
        printf "  %-3s %-20s %-26s %-7s %-16s %-18s\n" "[$i]" "${name}" "${proto}" "${port}" "${listen}" "${addr}"
        i=$((i+1))
    done
    echo
    echo -e "  ${YELLOW}查看某节点分享链接?${NC}"
    read -rp "  输入编号(0 返回): " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice)) n=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$((n+1))
        if [ "$n" -eq "$idx" ]; then
            local name link
            name=$(jq -r '.name' "$f"); link=$(jq -r '.share_link' "$f")
            echo
            echo -e "  ${CYAN}【${name}】${NC}"
            echo -e "  ${GREEN}${link}${NC}"
            local proto=$(jq -r '.protocol' "$f")
            case "$proto" in *cdn*) _warn "此为 CDN 协议, 禁止直连, 须经 Cloudflare 回源" ;; esac
            break
        fi
    done
    _press_any_key
}

# ---------------------------------------------------------------------------
# 删除节点
# ---------------------------------------------------------------------------
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
    echo -e "  ${RED}[a]${NC} ${RED}全部删除${NC}"
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
        _backup_config
        local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
        jq '.inbounds = [] | .routing.rules |= map(select(.inboundTag == null))' "$CONFIG_FILE" > "$tmp" 2>/dev/null
        mv -f "$tmp" "$CONFIG_FILE"
        if _xray_test_config; then
            _manage_xray restart 2>/dev/null || true
            # 清理所有端口跳跃 iptables 规则
            if command -v iptables >/dev/null 2>&1; then
                for tag in "${tags[@]}"; do
                    local proto; proto=$(jq -r '.protocol' "$NODES_DIR/${tag}.json" 2>/dev/null)
                    if [ "$proto" = "hysteria2" ]; then
                        local hop_port ranges
                        hop_port=$(jq -r '.port' "$NODES_DIR/${tag}.json" 2>/dev/null)
                        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
                        if [ -n "$ranges" ]; then
                            # shellcheck disable=SC2086
                            _hy2_remove_hop_rules "$hop_port" $ranges
                        fi
                    fi
                done
                _hy2_persist_iptables
            fi
            for tag in "${tags[@]}"; do
                rm -f "$NODES_DIR/${tag}.json"
                _remove_node_from_yaml_by_tag "$tag"
            done
            # 清空 clash.yaml proxies
            [ -f "$CLASH_YAML" ] && printf 'proxies:\n' > "$CLASH_YAML"
            _success "已删除全部 ${#tags[@]} 个节点"
        else
            _restore_config; _error "配置校验失败,已回滚"
        fi
        _press_any_key; return
    fi

    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    # 读取 tunnel_tag, 一次性删除 tunnel + reality + 路由(原子操作)
    local tunnel_tag
    tunnel_tag=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${tag}.json" 2>/dev/null)
    local jq_filter='.inbounds |= map(select(.tag != $t))'
    if [ -n "$tunnel_tag" ]; then
        jq_filter="$jq_filter | .routing.rules |= map(select(.inboundTag == null or (.inboundTag | index(\$tg)) == null))
            | .inbounds |= map(select(.tag != \$tg))"
    fi
    if _mutate_config --arg t "$tag" --arg tg "$tunnel_tag" "$jq_filter"; then
        # 清理端口跳跃 iptables 规则
        local proto; proto=$(jq -r '.protocol' "$NODES_DIR/${tag}.json" 2>/dev/null)
        if [ "$proto" = "hysteria2" ] && command -v iptables >/dev/null 2>&1; then
            local hop_port ranges
            hop_port=$(jq -r '.port' "$NODES_DIR/${tag}.json" 2>/dev/null)
            ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
            if [ -n "$ranges" ]; then
                # shellcheck disable=SC2086
                _hy2_remove_hop_rules "$hop_port" $ranges
                _hy2_persist_iptables
                _tip "已清理端口跳跃规则"
            fi
        fi
        rm -f "$NODES_DIR/${tag}.json"
        _remove_node_from_yaml_by_tag "$tag"
        _success "节点已删除"
    else
        _error "删除失败, 已回滚"
    fi
    _press_any_key
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
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local newport=$(_input_port)
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口修改失败, 已回滚"; _press_any_key; return 1
    fi

    # 更新元数据 + 链接(端口出现在链接里)
    local meta="$NODES_DIR/${tag}.json"
    local oldlink newlink
    oldlink=$(jq -r '.share_link' "$meta")
    local oldport; oldport=$(jq -r '.port' "$meta")
    newlink="${oldlink/:${oldport}/:${newport}}"
    # 同步更新节点名称(名称通常包含端口号)
    local old_name new_name
    old_name=$(jq -r '.name' "$meta")
    new_name="${old_name//${oldport}/${newport}}"
    if [ "$new_name" != "$old_name" ]; then
        jq --argjson p "$newport" --arg l "$newlink" --arg n "$new_name" \
           '.port=$p | .share_link=$l | .name=$n' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
    else
        jq --argjson p "$newport" --arg l "$newlink" '.port=$p | .share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
    fi
    # 如果是 hy2 节点且有端口跳跃, 更新 iptables DNAT 规则
    local proto; proto=$(jq -r '.protocol' "$meta" 2>/dev/null)
    if [ "$proto" = "hysteria2" ] && command -v iptables >/dev/null 2>&1; then
        local ranges display_ranges
        ranges=$(_read_hop_ranges "$meta")
        display_ranges=$(_read_hop_ranges_display "$meta")
        if [ -n "$ranges" ]; then
            _info "检测到端口跳跃规则, 正在更新..."
            # shellcheck disable=SC2086
            _hy2_remove_hop_rules "$oldport" $ranges
            # shellcheck disable=SC2086
            _hy2_add_hop_rules "$newport" $ranges
            _hy2_persist_iptables
            _tip "端口跳跃规则已更新: ${display_ranges} → ${newport}"
        fi
    fi
    _success "端口已改为 ${newport}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# 更新监听(单节点 R7)
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
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local curlisten; curlisten=$(jq -r '.listen' "$meta")
    echo -e "  当前监听: ${CYAN}${curlisten}${NC}"
    echo -e "  可选: :: (双栈默认) / 0.0.0.0 / 127.0.0.1 (回环, 供 cloudflared/中转回源) / ::1 / 具体 IP"
    local newlisten
    read -rp "  新监听地址: " newlisten
    if ! _validate_listen "$newlisten"; then
        _warn "监听地址不合法"; _press_any_key; return
    fi

    if ! _mutate_config --arg t "$tag" --arg l "$newlisten" \
         '(.inbounds[] | select(.tag == $t) | .listen) = $l'; then
        _error "监听修改失败, 已回滚"; _press_any_key; return
    fi

    # 联动链接服务器地址(R7 确认 A)
    local proto oldaddr newaddr
    proto=$(jq -r '.protocol' "$meta")
    oldaddr=$(jq -r '.link_addr' "$meta")
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
    [ -z "$newaddr" ] && newaddr="$oldaddr"

    # 重写链接里的地址(纯 bash, 不用 sed -E —— busybox 不支持)
    local oldlink newlink
    oldlink=$(jq -r '.share_link' "$meta")
    # 链接形如 proto://uuid@addr:port... 或 ss://b64@addr:port...
    local before_at="${oldlink%%@*}" after_at="${oldlink#*@}"
    # after_at 可能是 addr:port?... 或 [addr]:port?... 或 addr/path?...
    local old_host_part
    if [[ "$after_at" == "["* ]]; then
        # IPv6: [addr]:port
        old_host_part="${after_at%%]*}]"
    else
        # IPv4/域名: addr:port 或 addr/path
        old_host_part="${after_at%%[:/?#]*}"
    fi
    # IPv6 地址加括号
    local new_host="$newaddr"
    if [[ "$newaddr" == *":"* && "$newaddr" != *"["* ]]; then
        new_host="[${newaddr}]"
    fi
    newlink="${before_at}@${new_host}${after_at#"$old_host_part"}"

    jq --arg l "$newlisten" --arg a "$newaddr" --arg link "$newlink" \
       '.listen=$l | .link_addr=$a | .share_link=$link' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"

    _success "监听已更新为 ${newlisten}, 链接地址更新为 ${newaddr}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# clash.yaml 输出辅助(纯文本追加, 不用 jq —— jq 不能解析 yaml)
# 用法:_add_node_to_yaml <yaml_node_line>   (传入的是一行 yaml 节点: - {name: ...})
# ---------------------------------------------------------------------------
CLASH_YAML="$DEPLOY_DIR/clash.yaml"

_add_node_to_yaml() {
    local line="$1"
    mkdir -p "$DEPLOY_DIR"
    if [ ! -f "$CLASH_YAML" ]; then
        printf 'proxies:\n' > "$CLASH_YAML"
    fi
    # 去重: 同名节点先删再追加(BRE, busybox 兼容)
    local name
    name=$(printf '%s' "$line" | sed -n 's/.*name: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/p')
    [ -n "$name" ] && _remove_node_from_yaml_by_name "$name" 2>/dev/null
    printf '  %s\n' "$line" >> "$CLASH_YAML"
}

_remove_node_from_yaml_by_name() {
    local name="$1"
    [ -f "$CLASH_YAML" ] || return
    local tmp; tmp=$(mktemp)
    # 删除以 name 匹配的节点行(BRE, busybox 兼容)
    # 两次 grep -v: 第一次匹配 name 后跟 ,}空格, 第二次匹配行尾
    local escaped_name
    escaped_name=$(printf '%s' "$name" | sed 's/[.[\*^$()+?{|]/\\&/g')
    grep -v "name: *\"\{0,1\}${escaped_name}\"\{0,1\}[,} ]" "$CLASH_YAML" 2>/dev/null \
        | grep -v "name: *\"\{0,1\}${escaped_name}\"\{0,1\} *$" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$CLASH_YAML"
}

_remove_node_from_yaml_by_tag() {
    local tag="$1" name
    name=$(jq -r '.name' "$NODES_DIR/${tag}.json" 2>/dev/null)
    [ -z "$name" ] && return
    _remove_node_from_yaml_by_name "$name"
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
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
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
                # 删除 iptables 规则
                # shellcheck disable=SC2086
                _hy2_remove_hop_rules "$port" $cur_ranges
                _hy2_persist_iptables
                # 清理元数据
                jq 'del(.hop_ranges) | del(.hop_start) | del(.hop_end) | del(.udp_hop_ports)' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
                # 重建分享链接
                local newlink; newlink=$(_rebuild_hy2_link "$meta")
                jq --arg l "$newlink" '.share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
                _success "端口跳跃已禁用"
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
        # 1. 添加 iptables DNAT 规则 (服务端端口转发)
        # shellcheck disable=SC2086
        if ! _hy2_add_hop_rules "$port" $parsed; then
            _error "iptables 规则添加失败, 请检查内核是否支持 nat 模块"
            _press_any_key; return
        fi
        _hy2_persist_iptables
        # 2. 更新元数据
        jq --arg r "$normalized" \
           '.hop_ranges=$r | .udp_hop_ports=$r | del(.hop_start) | del(.hop_end)' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
        # 3. 重建分享链接 (含 &mport=)
        local newlink; newlink=$(_rebuild_hy2_link "$meta")
        jq --arg l "$newlink" '.share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
        _success "端口跳跃已启用: ${normalized} → ${port}"
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
