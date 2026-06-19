#!/bin/bash
# =============================================================================
# lib/50-nodes.sh — 节点管理(5 协议)
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
# 输入: "3010-3020,3050,3100-3110"
# 输出: "3010:3020 3050 3100:3110"  (单端口省略冒号, 避免 iptables -D 匹配问题)
# 验证: 端口合法性 + 范围间无重叠
_parse_hop_ranges() {
    local input="$1"
    local result=""
    local entries
    # 用 subshell + IFS 拆分逗号分隔的条目, 避免 IFS 污染整个函数
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
        # 检查与已有范围的重叠
        local i
        for ((i=0; i<${#all_starts[@]}; i++)); do
            if [ "$start" -le "${all_ends[$i]}" ] && [ "$end" -ge "${all_starts[$i]}" ]; then
                _error "范围重叠: $entry 与 ${all_starts[$i]}-${all_ends[$i]}"
                return 1
            fi
        done
        all_starts+=("$start")
        all_ends+=("$end")
        # 单端口用裸端口号, 范围用 start:end(iptables -D 匹配一致性)
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
# 用法: _hy2_add_hop_rules <hy2_port> <range1> [range2 ...]
#   range 格式: "start:end" (单端口也用 start:start)
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
# 用法: _hy2_remove_hop_rules <hy2_port> <range1> [range2 ...]
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
# 输出: "start:end start:end ..." 空格分隔, 无则输出空
_read_hop_ranges() {
    local meta="$1"
    local ranges
    ranges=$(jq -r '.hop_ranges // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        # 新格式: 逗号分隔 → 空格分隔, - 替换为 :
        echo "$ranges" | tr ',' ' ' | tr '-' ':'
        return
    fi
    # 旧格式兼容: hop_start + hop_end
    local hop_s hop_e
    hop_s=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
    hop_e=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
    if [ -n "$hop_s" ] && [ -n "$hop_e" ]; then
        if [ "$hop_s" = "$hop_e" ]; then
            echo "$hop_s"
        else
            echo "${hop_s}:${hop_e}"
        fi
    fi
}

# 从元数据读取端口跳跃范围(人类可读格式)
# 输出: "3010-3020,3050" 或空
_read_hop_ranges_display() {
    local meta="$1"
    local ranges
    ranges=$(jq -r '.hop_ranges // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges"
        return
    fi
    local hop_s hop_e
    hop_s=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
    hop_e=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
    if [ -n "$hop_s" ] && [ -n "$hop_e" ]; then
        if [ "$hop_s" = "$hop_e" ]; then
            echo "$hop_s"
        else
            echo "${hop_s}-${hop_e}"
        fi
    fi
}

# 检查是否已有 xray-deploy 的端口跳跃规则(简单存在性检查)
_hy2_has_any_hop_rules() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -t nat -S PREROUTING 2>/dev/null | grep -q "xray-deploy-hy2-hop"
}

# 列出所有 xray-deploy 端口跳跃规则
_hy2_list_all_hop_rules() {
    command -v iptables >/dev/null 2>&1 || return
    iptables -t nat -S PREROUTING 2>/dev/null | grep "xray-deploy-hy2-hop" || true
}

# 清理所有节点的端口跳跃 iptables 规则(供 _reset_config / _uninstall_xray 调用)
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
    local port="" def
    def=$(_gen_random_port)
    while true; do
        read -rp "  监听端口 (回车随机生成): " port
        port=${port:-$def}
        if ! _validate_port "$port"; then
            _warn "无效端口(1-65535)"; continue
        fi
        if _check_port_occupied "$port"; then
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
# 用法:_mutate_config <jq_filter> [jq_extra_args...]
# 所有 config 修改应通过此函数, 不再各自实现 backup/test/rollback
# ---------------------------------------------------------------------------
_mutate_config() {
    local jq_filter="$1"; shift
    _backup_config
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    if ! jq $jq_filter "$@" "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
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

# 删除 Tunnel inbound + 对应路由规则
_remove_reality_tunnel() {
    local tg="$1"
    [ -z "$tg" ] && return 0
    [ -f "$CONFIG_FILE" ] || return 0
    _mutate_config --arg tg "$tg" \
       '.inbounds |= map(select(.tag != $tg))
        | .routing.rules |= map(select(.inboundTag == null or (.inboundTag | index($tg)) == null))' || return 1
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

# ---------------------------------------------------------------------------
# 读取所有节点 tag 列表
# ---------------------------------------------------------------------------
_list_node_tags() {
    [ -d "$NODES_DIR" ] || return 0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        basename "$f" .json
    done
}

_node_count() {
    local n=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] && n=$((n+1))
    done
    echo "$n"
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
    local idx=$((choice-1))
    local sel="${PROTOCOLS[$idx]:-}"
    [ -z "$sel" ] && { _warn "无效选择"; _press_any_key; return; }

    local key
    IFS='|' read -r key _ _ _ _ <<< "$sel"
    case "$key" in
        vless-tcp-reality-vision) _add_vless_tcp_reality_vision ;;
        vless-xhttp-reality)      _add_vless_xhttp_reality ;;
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
    local port=$(_input_port)

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
    local link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=tcp&headerType=none&flow=xtls-rprx-vision&sni=${sni}&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}"
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
    local port=$(_input_port)

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
    local link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=xhttp&sni=${sni}&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}&path=$(_url_encode "$path")"
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
# 协议3: VLESS+XHTTP(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_xhttp_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+XHTTP (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port
    while true; do
        port=$(_input_port)
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
    local link="vless://${uuid}@${host}:${port}?encryption=none&security=none&type=xhttp&host=${host}&path=$(_url_encode "$path")#$(_url_encode "$name")"
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
# 协议4: VLESS+WS(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_ws_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+WS (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port=$(_input_port)

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
# 协议5: Shadowsocks(3 种加密选择)
# ---------------------------------------------------------------------------
_add_shadowsocks() {
    echo -e "\n  ${CYAN}=== Shadowsocks (可直连) ===${NC}"
    local port=$(_input_port)
    echo -e "  加密方式:"
    echo -e "  ${GREEN}[1]${NC} aes-256-gcm"
    echo -e "  ${GREEN}[2]${NC} chacha20-ietf-poly1305"
    echo -e "  ${GREEN}[3]${NC} 2022-blake3-aes-256-gcm"
    read -rp "  选择 (默认 1): " mc
    local method
    case "${mc:-1}" in
        1) method="aes-256-gcm" ;;
        2) method="chacha20-ietf-poly1305" ;;
        3) method="2022-blake3-aes-256-gcm" ;;
        *) _warn "无效,默认 aes-256-gcm"; method="aes-256-gcm" ;;
    esac
    # 2022 系列密码需 base64 32 字节
    local password
    if [[ "$method" == 2022* ]]; then
        password=$(head -c 32 /dev/urandom | base64 | tr -d '\n=' | head -c 43)
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
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_METHOD="$method" R_PASSWORD="$password"
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
# 协议6: Hysteria2 (QUIC + TLS证书)
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
    local port=$(_input_port)

    # TLS 证书: 回车自签, 或输入证书路径
    local tag="xd-hy2-${port}"
    local cert_file="" key_file="" self_signed="false"
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
    read -rp "  选择 (默认 1): " cc_choice
    local congestion="bbr"
    local brutal_up="" brutal_down=""
    case "${cc_choice:-1}" in
        2)
            congestion="brutal"
            echo -e "  ${YELLOW}brutal 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
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

    # 构建 inbound JSON(条件字段, 用 jq 组装, 比模板灵活)
    local inbound
    inbound=$(jq -n \
        --arg listen "$listen" --argjson port "$port" --arg tag "$tag" \
        --arg auth "$auth" \
        --arg cert "$cert_file" --arg key "$key_file" \
        --arg congestion "$congestion" \
        --arg brutalUp "$brutal_up" --arg brutalDown "$brutal_down" \
        '{
            listen: $listen, port: $port, protocol: "hysteria", tag: $tag,
            settings: { version: 2 },
            streamSettings: {
                network: "hysteria", security: "tls",
                tlsSettings: {
                    alpn: ["h3"],
                    certificates: [{ usage: "encipherment", certificateFile: $cert, keyFile: $key }]
                },
                hysteriaSettings: { version: 2, auth: $auth },
                finalmask: { quicParams: (
                    { congestion: $congestion }
                    + (if $brutalUp != "" then { brutalUp: $brutalUp } else {} end)
                    + (if $brutalDown != "" then { brutalDown: $brutalDown } else {} end)
                ) }
            },
            sniffing: { enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true }
        }') || { _error "inbound JSON 生成失败"; return 1; }

    _commit_inbound "$inbound" || return 1

    local addr
    addr=$(_ask_link_addr)
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"

    # hy2:// 分享链接(标准格式: hy2://password@host:port/?sni=...&insecure=...&congestion=...)
    local link="hy2://${auth}@${link_ip}:${port}/?sni=build.nvidia.com"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
    link="${link}#$(_url_encode "$name")"

    # clash yaml
    local clash_insecure=""
    [ "$self_signed" = "true" ] && clash_insecure=", skip-cert-verify: true"
    local clash="- {name: \"$name\", type: hysteria2, server: $addr, port: $port, password: \"$auth\", sni: build.nvidia.com, \"congestion-control\": $congestion${clash_insecure}}"
    _add_node_to_yaml "$clash"

    # 元数据
    _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "hysteria2" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg auth "$auth" --arg congestion "$congestion" \
        --arg brutalUp "$brutal_up" --arg brutalDown "$brutal_down" \
        --arg link "$link" --argjson ss "$self_signed" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,auth:$auth,congestion:$congestion,brutal_up:$brutalUp,brutal_down:$brutalDown,self_signed:$ss,share_link:$link}')"

    _success "节点 [${name}] 创建成功"
    _tip "SNI 使用自签证书域名 build.nvidia.com, 客户端须手动信任证书"
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
    sni="build.nvidia.com"
    congestion=$(jq -r '.congestion' "$meta")
    brutal_up=$(jq -r '.brutal_up // empty' "$meta")
    brutal_down=$(jq -r '.brutal_down // empty' "$meta")
    self_signed=$(jq -r '.self_signed // "false"' "$meta")
    name=$(jq -r '.name' "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link="hy2://${auth}@${link_ip}:${port}/?sni=${sni}"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
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
            link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=tcp&headerType=none&flow=xtls-rprx-vision&sni=${sni}&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}"
            ;;
        vless-xhttp-reality)
            link="vless://${uuid}@${link_ip}:${port}?encryption=none&security=reality&type=xhttp&sni=${sni}&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}&path=$(_url_encode "$path")"
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
        vless-xhttp-cdn)          echo "/opt/xray-deploy/templates/vless-xhttp-cdn.server.jsonc" ;;
        vless-ws-cdn)             echo "/opt/xray-deploy/templates/vless-ws-cdn.server.jsonc" ;;
        shadowsocks)              echo "/opt/xray-deploy/templates/shadowsocks.server.jsonc" ;;
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
    echo -e "  输入编号(0 返回):"
    read -rp "  " choice
    [ "$choice" = "0" ] && return
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
        jq '.inbounds = [] | .routing.rules = []' "$CONFIG_FILE" > "$tmp" 2>/dev/null
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

    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

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
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

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
    # 如果是 hy2 节点且有端口跳跃, 更新 DNAT 规则
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
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

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

    # 重写链接里的地址
    local oldlink newlink
    oldlink=$(jq -r '.share_link' "$meta")
    # 链接形如 proto://uuid@addr:port... 或 ss://b64@addr:port...
    newlink=$(printf '%s' "$oldlink" | sed -E "s/@[^:/#]+/@${newaddr}/")
    # IPv6 地址加括号
    if [[ "$newaddr" == *":"* && "$newaddr" != *"["* ]]; then
        newlink=$(printf '%s' "$oldlink" | sed -E "s/@[^:/#]+/@[${newaddr}]/")
    fi

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
    # 去重: 同名节点先删再追加
    local name
    name=$(printf '%s' "$line" | sed -nE 's/.*name: *"?([^",}]*)"?.*/\1/p')
    [ -n "$name" ] && _remove_node_from_yaml_by_name "$name" 2>/dev/null
    printf '  %s\n' "$line" >> "$CLASH_YAML"
}

_remove_node_from_yaml_by_name() {
    local name="$1"
    [ -f "$CLASH_YAML" ] || return
    local tmp; tmp=$(mktemp)
    # 删除以 name 匹配的节点行(行内含 name: "<name>" 或 name: <name>)
    grep -vE "name: *\"?$(printf '%s' "$name" | sed 's/[.[\*^$()+?{|]/\\&/g')\"?[,} ]" "$CLASH_YAML" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$CLASH_YAML"
}

_remove_node_from_yaml_by_tag() {
    local tag="$1" name
    name=$(jq -r '.name' "$NODES_DIR/${tag}.json" 2>/dev/null)
    [ -z "$name" ] && return
    _remove_node_from_yaml_by_name "$name"
}

# ---------------------------------------------------------------------------
# Hysteria2 端口跳跃管理
# ---------------------------------------------------------------------------

# 启用/禁用端口跳跃
_hy2_toggle_hop() {
    clear
    _has_hy2_nodes || { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    _ensure_iptables || { _press_any_key; return; }

    echo; echo -e "  ${CYAN}【端口跳跃 — 启用/禁用】${NC}"
    echo -e "  ${YELLOW}通过 iptables DNAT 将 UDP 端口范围转发到 Hysteria2 监听端口${NC}"
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
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

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
                # shellcheck disable=SC2086
                _hy2_remove_hop_rules "$port" $cur_ranges
                _hy2_persist_iptables
                jq 'del(.hop_ranges) | del(.hop_start) | del(.hop_end)' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
                _success "端口跳跃已禁用"
                ;;
            *) _info "已取消" ;;
        esac
    else
        # 未启用 → 设置端口范围
        echo -e "  当前 Hysteria2 端口: ${CYAN}${port}${NC}"
        echo -e "  ${YELLOW}端口范围格式:${NC}"
        echo -e "    单个端口:     ${CYAN}3050${NC}"
        echo -e "    连续范围:     ${CYAN}3010-3020${NC}"
        echo -e "    混合(逗号分隔): ${CYAN}3010-3020,3050,3100-3110${NC}"
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
        # 检查是否已有跳跃规则(提示用户)
        if _hy2_has_any_hop_rules; then
            _warn "已有其他跳跃规则, 请确保端口范围不冲突"
        fi
        # 添加规则
        # shellcheck disable=SC2086
        if _hy2_add_hop_rules "$port" $parsed; then
            _hy2_persist_iptables
            jq --arg r "$normalized" '.hop_ranges=$r | del(.hop_start) | del(.hop_end)' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
            _success "端口跳跃已启用: ${normalized} → ${port}"
            _tip "客户端可连接上述端口范围内的任意端口"
            _tip "请确保防火墙/安全组已放行该 UDP 端口范围"
        else
            _error "iptables 规则添加失败, 请检查内核是否支持 nat 模块"
        fi
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
