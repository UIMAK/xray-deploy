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
    # 短后缀展开: 1g→1 gbps, 10m→10 mbps (较新 Xray 可能拒绝裸短后缀, M10)
    elif [[ "$v" =~ ^[0-9]+g$ ]]; then
        echo "${v%g} gbps"
    elif [[ "$v" =~ ^[0-9]+m$ ]]; then
        echo "${v%m} mbps"
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

# 精确匹配 --to-destination :<port>(边界: 后随空白或行尾, R18), 避免 :443 误匹配 :4430/:44300 等其他节点规则
# 用法: 过滤 stdin 中的 iptables -S 行; 与 dport 的 "dport X " / "dport X$" 同风格
_hy2_match_target() {
    local port="$1"
    grep -e "--to-destination :${port} " -e "--to-destination :${port}\$"
}

# R38(P1)/R39(P1): 本机是否"**有证据表明**不存在任何 xray-deploy 端口跳跃规则"。
# 用于给 _node_protocol_safe 的 fail-closed 提供一个可证伪的逃生口。
# R39 收紧: 必须真的**看过** runtime, 才能说"没有规则"。
#   "iptables 不可用 + 持久化文件不存在" 只是"我没有观察能力", 不等于"内核里没有规则":
#   曾启用过 hop、规则已进内核、没装 iptables-persistent(无 rules.v4)、之后 iptables
#   二进制被卸载 —— 此时规则仍在内核中转发流量, 而旧实现会返回 0(=已证明无规则),
#   于是删除节点后留下无法追溯 dport 的孤儿 DNAT(metadata 也已被删)。
# 证据来源(必须至少有一个可用的观察通道):
#   a) iptables -S 成功 -> 最权威, 直接看 runtime;
#   b) iptables 不可用但内核 x_tables 从未装载过 nat 表 -> /proc/net/ip_tables_names
#      不含 "nat"(文件不存在同样说明 x_tables 未被使用) => 内核里不可能有 nat 规则;
#   c) 上面能确认无 runtime 规则后, 再看持久化文件(它们会在重启时被重新加载)。
# 任一通道都无法确认 => 返回 1(UNKNOWN, 按不安全处理), 由调用方拒绝并给出人工路径。
# 返回: 0 = 有证据表明无 hop 规则; 1 = 有规则, 或无观察能力(UNKNOWN)
_hy2_no_hop_rules_at_all() {
    local q f runtime_clean=0
    if command -v iptables >/dev/null 2>&1; then
        q=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 1
        printf '%s\n' "$q" | grep -q "xray-deploy-hy2-hop" && return 1
        # IPv6 侧为 best-effort: 命令存在但查询失败时无法确认, 保守判 UNKNOWN
        if command -v ip6tables >/dev/null 2>&1; then
            q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || return 1
            printf '%s\n' "$q" | grep -q "xray-deploy-hy2-hop" && return 1
        fi
        runtime_clean=1
    else
        # 无 iptables: 唯一可靠的替代证据是"内核 nat 表从未被使用过"。
        # /proc/net/ip_tables_names 列出当前已注册的 iptables 表; 不含 nat(或文件不存在,
        # 即 x_tables 未装载)时, 内核里不可能存在 nat PREROUTING 规则。
        # 注意 nftables 后端(nft) 不体现在该文件里, 因此若 nft 存在而 iptables 不存在,
        # 一律判 UNKNOWN —— 本项目只用 iptables 写规则, 但用户环境可能已迁移到 nft。
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
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f" ] || continue
        grep -q "xray-deploy-hy2-hop" "$f" 2>/dev/null && return 1
    done
    return 0
}

# 为多个范围添加 DNAT 规则(R16 幂等 + R17 跨节点冲突拒绝 + R19 -S 查询失败守卫):
#   - 同 dport 且同目标端口已存在  -> 跳过(幂等, rollback/重试安全)
#   - 同 dport 但目标端口不同      -> 拒绝(该范围已被其他节点占用, 避免两个 DNAT 规则并存)
# R19: 每次调用只执行一次 iptables -S(整个 range 循环复用同一快照, 事务内一致视图),
#      且 -S 失败显式 return 1——绝不把"查不到规则"当成"无冲突"而继续 ADD(与 remove 同标准)。
# R35(P1): stdout 输出"本次事务实际新增的 range"(每行一个, 即 CREATED 集合)。幂等跳过的
#      既有规则绝不输出——调用方据此精确回滚本事务副作用, 而非按请求全量 remove(否则会误删
#      事务开始前已存在的同 dport+同目标规则)。无需该输出的调用方应显式 >/dev/null。
# R36(P2): CREATED 集合只表达"IPv4 侧副作用"。IPv6 为 best-effort(R14), 独立于 IPv4 检查/
#      补建——即使 IPv4 已存在(幂等跳过)也继续尝试 IPv6, 避免"IPv6 曾失败就永久不再重试";
#      IPv6 不进 CREATED、不参与 rollback ownership(移除仍靠 IPv4 幂等 skip 保护)。
# 返回: 0 全部成功; 1 任一范围冲突/查询失败/添加失败
_hy2_add_hop_rules() {
    # 注意(R28, 设计边界): hop ownership 由 (dport, 目标端口) 构成, 记录在 iptables + 节点
    # metadata(hop_ranges); 若节点 metadata 因外部事件丢失, 无法从 config 恢复 hop ownership,
    # 不会自动清理对应 DNAT。这是已知限制(见 R25/R26 Known limitation), 非本函数可解。
    local hy2_port="$1"; shift
    local range q v6ok="" v6q=""
    if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
        _error "无法读取 PREROUTING 规则(iptables -S 失败), 中止添加"
        return 1
    fi
    # R36(P2): IPv6 快照一次获取并复用。v6ok 标记 ip6tables 命令可用(空表也须进入补建分支);
    # 查询失败仅警告, IPv6 跳跃规则整体跳过(仅 IPv4 生效)。v6q 为空表示"无既有 IPv6 规则"。
    if command -v ip6tables >/dev/null 2>&1; then
        v6ok=1
        v6q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || {
            _warn "无法读取 IPv6 PREROUTING 规则, 本次仅维护 IPv4 跳跃规则(best-effort)"
            v6q=""
        }
    fi
    for range in "$@"; do
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
            echo "$range"
        fi
        # R36(P2): IPv6 独立补建——即使 IPv4 已存在也检查/添加, 保证 best-effort 可重试
        if [ -n "$v6ok" ]; then
            local v6d
            v6d=$(printf '%s\n' "$v6q" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$")
            if [ -n "$v6d" ]; then
                if ! echo "$v6d" | _hy2_match_target "$hy2_port" | grep -q .; then
                    _warn "IPv6 端口范围 ${range} 已被其他规则占用(目标端口不同), 未添加 IPv6 跳跃规则"
                fi
            else
                ip6tables -t nat -A PREROUTING -p udp --dport "${range}" \
                    -m comment --comment "xray-deploy-hy2-hop" \
                    -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || \
                    _warn "IPv6 Hysteria2 跳跃规则添加失败(${range}, 可能缺少 IPv6 NAT 支持)"
            fi
        fi
    done
}

# 删除多个范围的 DNAT 规则(先查 iptables -S 找实际 rule spec 再 -D, 确保精准删除)
# R17: 同时匹配 comment + dport + 目标端口, 保证跨节点隔离——不同节点即使 hop dport 重叠,
#      删除本节点(目标端口 X)绝不误删他节点(目标端口 Y)的同 dport 规则。
# R18: 目标端口用 _hy2_match_target 精确边界匹配; -S 查询失败显式报错, 不把"查不到"当"已删干净"。
# 返回: 0 全部 IPv4 范围删除干净; 1 有 IPv4 残留或查询失败(调用方应中止事务/显式提示; IPv6 为 best-effort 只警告)
_hy2_remove_hop_rules() {
    local hy2_port="$1"; shift
    local range remain_any=0
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
        # 删除后核验(R15): 重新查询当前状态(不能用删除前的 q), 若该范围仍残留则显式提示并置失败标记
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
        if command -v ip6tables >/dev/null 2>&1; then
            local q6 specs6
            if ! q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
                _warn "无法读取 IPv6 PREROUTING 规则, 跳过 IPv6 跳跃规则删除核验"
                continue
            fi
            specs6=$(printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$" \
                    | _hy2_match_target "$hy2_port" | sed 's/^-A/-D/')
            while IFS= read -r line; do
                [ -n "$line" ] && ip6tables -t nat $line 2>/dev/null || true
            done <<< "$specs6"
            if ! q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
                _warn "无法读取 IPv6 PREROUTING 规则核验, 跳过 IPv6 残留判断"
                continue
            fi
            remain=$(printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$" \
                    | _hy2_match_target "$hy2_port")
            [ -n "$remain" ] && _warn "IPv6 范围 ${range} 的跳跃规则删除后仍残留, 请手动检查"
        fi
    done
    return "$remain_any"
}

# 持久化 iptables 规则。R37(P1): IPv4 为 authoritative——save 失败返回 1(告知调用方
# "重启后 IPv4 规则可能丢失", 事务必须回滚且不提交 metadata); IPv6 为 best-effort(R14)——save
# 失败仅 _warn, 不决定事务成败。若把 IPv6 persistence 也设为 fatal, 而 IPv6 新增规则不在
# CREATED/rollback ownership 内, 事务将因 IPv6 persist 失败而失败却无法回滚 IPv6 side effect。
# 注意 ok 用 0=成功/1=失败(与 bash 退出码一致, 不要用 1=成功 + return "$ok" 的颠倒写法, R14)
# 直接写采用 save -> tmp -> mv(R15): 避免 shell 先 truncate 目标文件再执行 save, save 失败把已有持久化规则清空
_hy2_persist_iptables() {
    # R34(P1): 事务需要持久化时, 缺少 iptables-save 不是"无事发生"而是失败——
    # 否则 metadata 提交 hop=enabled, 重启后 runtime DNAT 全丢, 直接违反
    # "runtime/metadata 不分裂"原则。_ensure_iptables 只保证 iptables 存在,
    # 不保证 iptables-save, 故必须在此显式 fail-closed。正常 enable/disable/
    # retarget/delete 的事务都会因 rc1 回滚 runtime 且不提交 metadata; reset
    # 路径由调用方保持 best-effort + warn。
    if ! command -v iptables-save >/dev/null 2>&1; then
        _error "iptables-save 不可用, 无法安全持久化端口跳跃规则(重启后规则会丢失)"
        return 1
    fi
    local ok=0 fam v4tmp v6tmp
    fam=$(_detect_os_family)
    case "$fam" in
        debian)
            mkdir -p /etc/iptables 2>/dev/null || ok=1
            v4tmp="/etc/iptables/rules.v4.tmp.$$"
            if iptables-save > "$v4tmp" 2>/dev/null; then
                mv -f "$v4tmp" /etc/iptables/rules.v4 2>/dev/null || { rm -f "$v4tmp"; ok=1; }
            else
                rm -f "$v4tmp"; ok=1
            fi
            if command -v ip6tables-save >/dev/null 2>&1; then
                v6tmp="/etc/iptables/rules.v6.tmp.$$"
                if ip6tables-save > "$v6tmp" 2>/dev/null; then
                    mv -f "$v6tmp" /etc/iptables/rules.v6 2>/dev/null || { rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
                else
                    rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                fi
            fi
            ;;
        alpine)
            if [ -x /etc/init.d/iptables ]; then
                # init.d save 由服务脚本自行管理其持久化文件, 无法原子化, 仅检查返回
                /etc/init.d/iptables save >/dev/null 2>&1 || ok=1
                # R34(P2): ip6 侧先确认 init.d 脚本存在; 不存在但 ip6tables-save 可用时
                # 回退到直接原子写(与无 init.d 分支一致), 避免调用不存在的脚本 rc127 误报失败
                if [ -x /etc/init.d/ip6tables ]; then
                    /etc/init.d/ip6tables save >/dev/null 2>&1 || _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                elif command -v ip6tables-save >/dev/null 2>&1; then
                    mkdir -p /etc/iptables 2>/dev/null || _warn "无法创建 /etc/iptables, IPv6 规则持久化失败(best-effort)"
                    v6tmp="/etc/iptables/rules.v6.tmp.$$"
                    if ip6tables-save > "$v6tmp" 2>/dev/null; then
                        mv -f "$v6tmp" /etc/iptables/rules.v6 2>/dev/null || { rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
                    else
                        rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                    fi
                fi
            else
                mkdir -p /etc/iptables 2>/dev/null || ok=1
                v4tmp="/etc/iptables/rules.v4.tmp.$$"
                if iptables-save > "$v4tmp" 2>/dev/null; then
                    mv -f "$v4tmp" /etc/iptables/rules.v4 2>/dev/null || { rm -f "$v4tmp"; ok=1; }
                else
                    rm -f "$v4tmp"; ok=1
                fi
                if command -v ip6tables-save >/dev/null 2>&1; then
                    v6tmp="/etc/iptables/rules.v6.tmp.$$"
                    if ip6tables-save > "$v6tmp" 2>/dev/null; then
                        mv -f "$v6tmp" /etc/iptables/rules.v6 2>/dev/null || { rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
                    else
                        rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                    fi
                fi
            fi
            ;;
        *)
            mkdir -p /etc/iptables 2>/dev/null || ok=1
            v4tmp="/etc/iptables/rules.v4.tmp.$$"
            if iptables-save > "$v4tmp" 2>/dev/null; then
                mv -f "$v4tmp" /etc/iptables/rules.v4 2>/dev/null || { rm -f "$v4tmp"; ok=1; }
            else
                rm -f "$v4tmp"; ok=1
            fi
            ;;
    esac
    return "$ok"
}

# ---------------------------------------------------------------------------
# Hysteria2 端口跳跃事务(R15): runtime iptables 修改 + 持久化 + 节点 metadata 必须整体成功,
# 任一步失败回滚已发生的变更, 保证 iptables 与 metadata 不永久分叉。
# 调用方先纯内存生成 newmeta(完整新 metadata, 含 share_link; 失败则不进入事务)。
# 用法: _hy2_hop_txn <add|remove> <meta> <newmeta> <port> <range...>
# 返回: 0 全部成功提交; 1 任一步失败(已回滚 runtime 并重新持久化)
# ---------------------------------------------------------------------------
_hy2_hop_txn() {
    local op="$1" meta="$2" newmeta="$3" port="$4"; shift 4
    # 1+2. runtime 修改 + 原子持久化(失败自动回滚 runtime)
    if ! _hy2_hop_apply "$op" "$port" "$@"; then
        return 1
    fi
    # 3. 原子提交 metadata(_atomic_write_json 失败时目标文件原样, 无需恢复 metadata)
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "节点 metadata 提交失败, 回滚运行时规则..."
        _hy2_hop_reverse "$op" "$port" "$@" || _error "回滚运行时规则失败, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# runtime 修改 + 原子持久化; 持久化失败则回滚 runtime 并重新持久化, 返回 1
_hy2_hop_apply() {
    local op="$1" port="$2"; shift 2
    local created rc
    if [ "$op" = add ]; then
        # IPv4 添加失败时可能有部分 range 已加入, 先回滚再返回。
        # R35(P1): created 只含本事务实际新增的 range(_hy2_add_hop_rules 输出, 幂等跳过的
        # 既有规则不在内); 回滚只删 created, 绝不误删事务开始前已存在的同目标规则。
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
            # R35(P1): 只回滚本事务新增的 created; remove 分支则恢复全部(本事务删除的都是本次副作用)
            # shellcheck disable=SC2086
            _hy2_hop_reverse add "$port" $created || _error "回滚运行时规则失败, 请手动检查 iptables"
        else
            _hy2_hop_reverse remove "$port" "$@" || _error "回滚运行时规则失败, 请手动检查 iptables"
        fi
        return 1
    fi
    return 0
}

# 反向操作: add 的回滚 = remove; remove 的回滚 = add(幂等)。
# 返回 0=回滚成功; 1=回滚过程中仍有失败(runtime 或持久化), 调用方必须显式报告, 不能当作"已恢复原状"
_hy2_hop_reverse() {
    local op="$1" port="$2"; shift 2
    local ok=0
    if [ "$op" = add ]; then
        _hy2_remove_hop_rules "$port" "$@" || ok=1
    else
        # R35(P1): 恢复操作不需要 CREATED 集合输出(add 的 stdout 仅由 _hy2_hop_apply/retarget
        # 按需捕获), 显式丢弃, 避免裸行泄漏到终端
        _hy2_add_hop_rules "$port" "$@" >/dev/null || ok=1
    fi
    _hy2_persist_iptables || ok=1
    return "$ok"
}

# 删除节点前的端口跳跃清理事务(R17): remove + 原子持久化; 任一步失败都恢复 runtime 已删规则并返回 1。
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
    # R18: persist 失败必须回滚已删除的 runtime 规则, 否则出现 metadata=enabled 而 runtime=disabled 的分裂
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚已删除的运行时规则..."
        _hy2_hop_reverse remove "$port" "$@" || _error "回滚失败, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# 批量 teardown(多选/全部删除)。
# R38(P1): 语义由"任一失败 → 整批取消"改为"逐项判定 → 坏项排除、其余照删"。
#   原写法让一个损坏 metadata 就让"全部删除/多选删除"完全不可用(且报错文案是
#   "端口跳跃规则清理失败", 与真实原因不符), 属拒绝服务。
#   现在: 无法安全 teardown 的 tag 记入 _HY2_HOP_SKIP, 调用方必须把它们从删除集合里剔除;
#   已成功 teardown 的 tag 记入 _HY2_HOP_TD, 供 config 提交失败时整体回滚。
#   每个失败项在 _hy2_hop_teardown 内部已自行恢复 runtime, 因此无需整批回滚。
# 返回: 0 = 至少可以继续(调用方按 _HY2_HOP_SKIP 缩小集合); 1 = 全部被排除, 无事可做
_HY2_HOP_TD=()
_HY2_HOP_SKIP=()
_hy2_hop_teardown_all() {
    # R18: 每个事务从空开始, 避免上一次批量删除的 tag 跨事务残留
    _HY2_HOP_TD=()
    _HY2_HOP_SKIP=()
    local tag total=0
    for tag in "$@"; do
        total=$((total+1))
        local proto hop_port ranges
        # R30(P1): metadata 损坏/缺 protocol 不能当作"非 HY2"跳过 teardown, 否则节点随后
        # 正常从 config 删除, hop DNAT 永久残留。_node_protocol_safe 在"确定本机无 hop 规则"
        # 时会放行(见 R38), 无法确认时才拒绝。
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
        # R31(P1): metadata.port 必须与 config 真实监听端口一致——否则 teardown 用错误目标
        # 端口找不到(或误删)DNAT 规则, 留下 :<真实端口> 的孤儿规则。
        # 仅当 config 存在该 inbound 时强制(真实删除流 inbound 必在 config; config 已无该
        # inbound 说明已是孤儿/外部删除, metadata.port 仍是当初 add 用的正确清理目标)。
        local cfg_port
        cfg_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$cfg_port" ] && [ "$cfg_port" != "$hop_port" ]; then
            _error "节点元数据端口($hop_port)与 config 监听端口($cfg_port)不一致, 无法安全删除: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        # R31(P1): hop 范围字段存在但无法解析 → 拒绝删除该项(不当作"无 hop"跳过 teardown)
        _hy2_hop_meta_ok "$tag" || {
            _HY2_HOP_SKIP+=("$tag")
            continue
        }
        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        [ -n "$ranges" ] || continue
        # R33(P1): 存在 hop 规则但 iptables 不可用 → 无法安全删除(fail-closed; 与单删一致)
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

# R38(P1): 从待删列表里剔除 _HY2_HOP_SKIP 中的 tag, 结果写入全局 _HY2_DEL_KEEP。
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

# 恢复 _hy2_hop_teardown_all 已 teardown 的节点(幂等 add + 持久化), 用于 config 提交失败时的整体回滚
# R18: 恢复失败的 tag 保留在 _HY2_HOP_TD 中(ROLLBACK_FAILED 状态), 只有全部恢复成功才清空,
#      避免"已经报错但状态容器被清空、无法再重试"的问题
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
        # R17: 首步 remove 也可能"部分成功"(几个范围删掉、一个残留), 必须先恢复已删范围再中止,
        #      否则 runtime 处于"旧端口规则删了一半"的中间态, 与 metadata 分叉
        _warn "旧端口规则删除不干净, 恢复已删除的规则..."
        local rok=0
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "旧端口规则恢复失败, 请手动检查 iptables"
        return 1
    fi
    # R35(P1): created_new 只含本事务实际新增的 newport 规则(add 输出; 幂等跳过的既有
    # 规则不在内), 后续失败回滚只清理 created_new, 绝不误删 retarget 前已存在的同目标规则
    local created_new rc
    created_new=$(_hy2_add_hop_rules "$newport" "$@"); rc=$?
    if [ "$rc" != 0 ]; then
        _error "新端口跳跃规则添加失败, 恢复旧规则..."
        # 先清理本事务实际新增的新端口规则(created_new), 再恢复旧端口规则(幂等 add 不会重复);
        # 三步都尽力执行并聚合结果
        local rok=0
        # shellcheck disable=SC2086
        _hy2_remove_hop_rules "$newport" $created_new 2>/dev/null || rok=1
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "端口回滚不完整, 请手动检查 iptables"
        return 1
    fi
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚到旧端口规则..."
        local rok=0
        # shellcheck disable=SC2086
        _hy2_remove_hop_rules "$newport" $created_new 2>/dev/null || rok=1
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "端口回滚不完整, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# 在内存中生成完整新 metadata: 传入 hop 字段变换后的 hopmeta 内容, 重建分享链接(读临时文件, 因为
# _rebuild_hy2_link 从文件读), 输出 newmeta(hop 字段 + 新 share_link)。失败返回 1(未落地任何文件)。
_hy2_gen_newmeta() {
    local meta="$1" hopmeta="$2" tmp_meta newlink
    tmp_meta=$(mktemp "${meta}.hop.XXXXXX") || return 1
    printf '%s' "$hopmeta" > "$tmp_meta" || { rm -f "$tmp_meta"; return 1; }
    newlink=$(_rebuild_hy2_link "$tmp_meta")
    rm -f "$tmp_meta"
    [ -n "$newlink" ] || return 1
    jq --arg l "$newlink" '.share_link=$l' <<< "$hopmeta"
}

# 在内存生成端口修改后的完整新 metadata(port + name + share_link), 不落地真实 meta 文件(R16)。
# 供 _hy2_port_txn 使用: 事务内只做一次 _atomic_write_json 提交整份新 metadata, 消除两段式写窗口。
# 失败返回 1(输出为空); 调用方通过 $(...) 捕获, 未落地任何文件。
_hy2_gen_port_newmeta() {
    local meta="$1" newport="$2" oldport tmpm newlink name newname
    oldport=$(jq -r '.port' "$meta")
    [ -n "$oldport" ] || return 1
    tmpm=$(mktemp "${meta}.port.XXXXXX") || return 1
    jq --argjson p "$newport" '.port=$p' "$meta" > "$tmpm" || { rm -f "$tmpm"; return 1; }
    newlink=$(_rebuild_hy2_link "$tmpm")
    rm -f "$tmpm"
    [ -n "$newlink" ] || return 1
    name=$(jq -r '.name' "$meta")
    newname="${name//${oldport}/${newport}}"
    jq --argjson p "$newport" --arg n "$newname" --arg l "$newlink" \
       '.port=$p | .name=$n | .share_link=$l' "$meta"
}

# 端口修改统一事务(R16): 用于 hy2+hop 节点。调用方已用 _hy2_gen_port_newmeta 在内存生成完整 newmeta。
# 提交顺序: runtime iptables old→new + 原子持久化(最常见失败点, 失败干净中止、config/metadata 未动)
#         → 原子提交 metadata → 提交 config(_mutate_config 自带重启校验与失败回滚)。
# 后两步失败回滚已提交步骤, 保证 config/metadata/iptables 三方一致(全部回到旧端口或全部新端口)。
# 返回: 0 全部成功; 1 失败(已尽力回滚到旧端口并提示)
_hy2_port_txn() {
    local tag="$1" meta="$2" oldport="$3" newport="$4" newmeta="$5"; shift 5
    local ranges="$*" orig
    orig=$(cat "$meta" 2>/dev/null) || return 1
    # 1. runtime iptables old→new + 原子持久化
    # shellcheck disable=SC2086
    if ! _hy2_hop_retarget "$oldport" "$newport" $ranges; then
        return 1
    fi
    # 2. 原子提交 metadata(失败回滚 iptables, config 未动)
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 回滚 iptables 到旧端口..."
        # shellcheck disable=SC2086
        _hy2_hop_retarget "$newport" "$oldport" $ranges || _error "iptables 回滚失败, 请手动检查"
        return 1
    fi
    # 3. 提交 config(_mutate_config 失败会自行恢复旧 config 并重启回旧端口)
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口配置提交失败, 回滚 metadata + iptables 到旧端口..."
        _atomic_write_json "$meta" "$orig" || _error "元数据回滚失败, 请手动检查"
        # shellcheck disable=SC2086
        _hy2_hop_retarget "$newport" "$oldport" $ranges || _error "iptables 回滚失败, 请手动检查"
        return 1
    fi
    return 0
}

# _modify_port 的 hy2+hop 分支(R16): 内存生成完整新 metadata -> _hy2_port_txn 统一提交;
# 返回 0=成功, 1=失败(已回滚到旧端口)
_modify_port_hop() {
    local tag="$1" meta="$2" oldport="$3" newport="$4"; shift 4
    local ranges="$*" newmeta display
    display=$(_read_hop_ranges_display "$meta")
    newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport") || { _error "生成新元数据失败"; return 1; }
    _info "检测到端口跳跃规则, 正在统一事务更新(config/metadata/iptables)..."
    # shellcheck disable=SC2086
    if ! _hy2_port_txn "$tag" "$meta" "$oldport" "$newport" "$newmeta" $ranges; then
        _warn "端口修改未完成, 已回滚到旧端口(config/metadata/iptables 保持一致)"
        _warn "请检查 iptables 环境后重试"
        return 1
    fi
    _tip "端口跳跃规则已更新: ${display} → ${newport}"
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

# R31/R32(P1,P2): HY2 删除/改端口前校验 hop metadata 可解析。区分"无 hop"与"metadata 损坏":
# 所有 hop 字段缺失 → 无 hop(正常, 返回 0); 任一 hop 字段存在但内容不是合法 range
# (纯数字 / 数字:数字) → 损坏(返回 1, 调用方必须中止操作)。R32(P2): 逐字段独立校验
# (hop_ranges / udp_hop_ports / hop_start+hop_end), 不用 // 把它们当互斥字段——否则
# hop_ranges="" 而 udp_hop_ports=坏数据会被漏过。正常 metadata 由启用时写入、禁用时 del,
# 字段存在即必有合法内容, 因此空串/坏值一律判损坏。
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
            # R33(P2): 字段存在但无任何有效 token(",," 等 → 只剩空白) → 损坏, 不当作"无 hop"
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
        # R33(P2): 旧格式键存在即须 hs/he 均为非空数字且 1-65535、start<=end
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

# 清理所有节点的端口跳跃 iptables 规则
_hy2_cleanup_all_hops() {
    [ -d "$NODES_DIR" ] || return 0
    if ! command -v iptables >/dev/null 2>&1; then
        # R33(P2): iptables 不可用时不阻塞 reset, 但存在 hop metadata 时必须显式提示——
        # 否则 metadata 随 reset 删除后, DNAT 可能残留且无法追溯
        if grep -lq 'hop_ranges\|udp_hop_ports' "$NODES_DIR"/*.json 2>/dev/null; then
            _warn "iptables 不可用, 无法验证/清理端口跳跃规则(存在 hop metadata), 请手动检查 iptables -t nat -S PREROUTING"
        fi
        return 0
    fi
    local found=0 residual=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local port ranges
        port=$(jq -r '.port' "$f" 2>/dev/null)
        ranges=$(_read_hop_ranges "$f")
        if [ -n "$ranges" ] && [ -n "$port" ]; then
            # R17: 全量重置场景 metadata 整体丢弃, 清理为 best-effort; 但残留必须显式报告, 不静默
            # shellcheck disable=SC2086
            _hy2_remove_hop_rules "$port" $ranges || residual=1
            found=1
        fi
    done
    if [ "$found" -eq 1 ]; then
        _hy2_persist_iptables || _warn "iptables 规则持久化失败, 重启后可能丢失"
    fi
    [ "$residual" -eq 0 ] || _warn "部分端口跳跃规则清理后仍有残留, 请手动检查 iptables -t nat -S PREROUTING"
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

# 检查端口是否已存在于 config.json
_check_port_in_config() {
    local port="$1"
    # 入口校验: port 必须为数字 (M15: --argjson 对非数字行为未定义)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$CONFIG_FILE" >/dev/null 2>&1
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
    : "${R_FLOW:=}" "${R_DECRYPTION:=none}" "${R_NETWORK:=}"

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
    if ! _backup_config; then
        _error "配置备份失败,中止操作"
        return 1
    fi
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || { _error "无法创建临时配置"; return 1; }
    # 获取最后一个参数(用户 filter), 其余是 jq 选项
    local user_filter="${!#}"
    # 应用 filter 后, 按官方字段顺序重排顶层字段(字段列表定义在 00-common XRAY_TOP_FIELDS_JSON)
    local reorder="| . as \$c | (${XRAY_TOP_FIELDS_JSON}) as \$known | (reduce \$known[] as \$k ({}; .[\$k] = \$c[\$k]) | with_entries(select(.value != null))) as \$ordered | (\$c | to_entries | map(select(.key as \$k | \$known | index(\$k) | not)) | from_entries) as \$extra | \$ordered + \$extra"
    local combined="${user_filter} ${reorder}"
    # 构建参数列表: 去掉最后一个(filter), 追加合并后的 filter
    local args=("${@:1:$#-1}" "${combined}")
    if ! jq "${args[@]}" "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; _error "jq 处理失败"; return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; _error "生成的配置为空"; return 1
    fi
    # R23: mv 失败必须显式中止 — 否则旧 config 仍在, _restart_xray_verified 用旧配置重启成功,
    # 会被误判为"新配置已提交"(静默假成功)。mv 失败时旧 config 未动, 直接 return 1。
    if ! mv -f "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        _error "配置替换失败, 保留旧配置"
        return 1
    fi
    # 低内存 VPS: 不再预跑 xray -test —— 它会与运行中的实例同时加载两份二进制+geo, 触发 OOM。
    # 改为重启后校验服务是否稳定在运行态; 坏配置/被 OOM 都会导致启动失败并回滚旧配置。
    if ! _restart_xray_verified; then
        _error "xray 启动失败,回滚配置"
        if ! _restore_config; then
            _error "回滚失败(config.json.lastbak 不存在或恢复出错),未尝试重启"
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
       '.inbounds += [$tb, $rb] | .routing.rules = [
            {inboundTag: [$tg], domain: [$dom], outboundTag: "direct"},
            {inboundTag: [$tg], outboundTag: "block"}] + .routing.rules' || return 1
}

# ---------------------------------------------------------------------------
# 保存节点元数据(每节点独立文件)
# 用法:_save_node_meta <tag> <json_object>
# ---------------------------------------------------------------------------
_save_node_meta() {
    local tag="$1" json="$2"
    # R21: 严格失败语义 — metadata 是节点身份的一部分(config 已提交而 json 缺失会让节点
    # 退化为 orphan, 破坏 tag/config/metadata 一致性)。用公共原子写 helper,
    # 失败显式返回 1, 不再静默吞掉。
    mkdir -p "$NODES_DIR" || { _error "无法创建节点元数据目录: $NODES_DIR"; return 1; }
    if ! _atomic_write_json "$NODES_DIR/${tag}.json" "$json"; then
        return 1
    fi
    # umask 077 下通常已是 600; chmod 失败属非致命加固项, 提示即可(不阻断写入成功)
    chmod 600 "$NODES_DIR/${tag}.json" 2>/dev/null || _warn "节点元数据权限设置失败(不影响功能): $tag"
    return 0
}

# R20: 节点名称唯一性校验。Clash/Mihomo 代理名必须唯一(重复名会导致配置无效);
# 同时本项目 clash.yaml 按 name 删除(YAML 单行 flow 条目), name 唯一才能保证删除精确、
# 不会误删同名节点。tag 是文件级稳定身份, name 是显示名——唯一性约束使二者在该场景一致。
# R38(P1): 不可读的 metadata 不再整体 fail —— 原写法让"任意一个损坏文件"永久阻断
# 所有新建节点(即使新名字与任何现存节点都不冲突), 这是拒绝服务而非安全。
# 现改为: 损坏文件跳过并告警(它的 name 未知, 无法参与比较), 只有"确实读到同名"才拒绝。
# R39(P2) 语义声明 —— **唯一性在存在损坏 metadata 时降级为 best-effort**:
#   损坏文件里可能恰好存着同名节点, 本函数无从得知, 因此不能声称"name 全局唯一"。
#   影响面: clash.yaml 按 name 删除时可能同时删掉两条同名条目(clash.yaml 属可再生的
#   派生导出, 权威身份始终是 tag/nodes/<tag>.json), 不会影响 config.json 与节点本体。
#   取舍理由: "一个坏文件让所有新建失败" 的代价远大于 "极小概率的派生缓存重名"。
#   调用方若需要严格唯一, 必须先修复/移除损坏的 metadata(本函数已把数量告知用户)。
# 返回: 0 唯一(或无法确认); 1 确实已存在(调用方应中止创建)
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
        # R23: 损坏/不可读 metadata 显式告警, 不静默丢 tunnel_tag(否则 tunnel 成永久孤儿)
        if [ $? -ne 0 ]; then
            _warn "节点元数据不可读, 无法读取 tunnel_tag: $f"
            continue
        fi
        [ -n "$ttag" ] && echo "$ttag"
    done
}

# ---------------------------------------------------------------------------
# R38(P1): 判断某个 inbound tag 是否由脚本管理(即 _known_tags 认它)。
# 受管 = 存在 nodes/<tag>.json, 或被某份 metadata 的 tunnel_tag 引用。
# 用于 orphan 清理的关联扩展闸门: 孤儿清理绝不能顺带删掉受管节点的入站。
# 返回: 0 受管; 1 未跟踪(可作为孤儿删除)
# ---------------------------------------------------------------------------
_tag_is_managed() {
    local tag="$1" f ttag
    [ -n "$tag" ] || return 1
    [ -f "$NODES_DIR/${tag}.json" ] && return 0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        ttag=$(jq -r '.tunnel_tag // empty' "$f" 2>/dev/null) || continue
        [ -n "$ttag" ] && [ "$ttag" = "$tag" ] && return 0
    done
    return 1
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

        # 原子写 config(静默补 tag 不应触发 _mutate_config 的重启; 失败跳过该入站, 下次启动再试)
        local newcfg
        newcfg=$(jq --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].tag = $t' "$CONFIG_FILE") || continue
        _atomic_write_json "$CONFIG_FILE" "$newcfg" || continue
        tagged=$((tagged+1))
    done <<< "$(jq -c '.[]' <<< "$inbounds_info" 2>/dev/null)"

    [ "$tagged" -gt 0 ] && _info "已自动给 ${tagged} 个无 tag 入站分配标识"
    return 0
}

# ---------------------------------------------------------------------------
# R23/R26: 由 Reality 主入站唯一关联其 tunnel 入站 tag。关联键必须唯一:
# 多个 Reality 节点可共用同一 SNI(默认 www.amd.com), SNI/rewriteAddress 不唯一。
# 主键: realitySettings.target = "127.0.0.1:<tunnel_port>" 与 tunnel 入站 .port 一一对应。
# 兜底(target 缺失, 旧版/手工配置): tunnel tag = "Tunnel-<sni>-<tport>-<reality_port>",
# 末段是本节点 port(端口唯一), 按 tag 后缀匹配, 同样无 SNI 歧义。
# 用法: tag=$(_find_reality_tunnel_tag <reality_tag>); 非 Reality 或无 tunnel 输出空。
# 返回码三态(R28): 0=唯一关联(stdout=tunnel_tag) 1=无关联(stdout 空) 2=歧义(stdout 空, 禁止 fallback)
# ---------------------------------------------------------------------------
_find_reality_tunnel_tag() {
    local tag="$1" proto
    proto=$(_detect_inbound_protocol "$tag")
    case "$proto" in vless-tcp-reality-vision|vless-xhttp-reality) ;; *) return 1 ;; esac
    local target tport n ttag=""
    target=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.target // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$target" ]; then
        # 主键: realitySettings.target = "127.0.0.1:<tunnel_port>" 与 tunnel .port 一一对应。
        # R28(P1): target 有效时命中数 != 1 一律禁止 legacy fallback——
        # 歧义(>1)返回 2 由调用方拒绝, 无匹配(=0)视为无关联返回 1, 均不再用 tag 后缀重绑。
        tport="${target##*:}"
        [[ "$tport" =~ ^[0-9]+$ ]] || return 1
        n=$(jq -r --argjson p "$tport" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p)] | length' "$CONFIG_FILE" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        if [ "$n" -eq 1 ]; then
            ttag=$(jq -r --argjson p "$tport" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p) | .tag][0]' "$CONFIG_FILE" 2>/dev/null)
            printf '%s' "$ttag"
            return 0
        fi
        [ "$n" -gt 1 ] && return 2
        return 1
    fi
    # target 缺失(旧版/手工配置) → legacy tag 后缀 fallback, 同样 count==1 才绑定
    local pport
    pport=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ "$pport" =~ ^[0-9]+$ ]] || return 1
    n=$(jq -r --arg sfx "-${pport}" '[.inbounds[] | select(.protocol == "tunnel") | select(.tag | endswith($sfx))] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    if [ "$n" -eq 1 ]; then
        ttag=$(jq -r --arg sfx "-${pport}" '[.inbounds[] | select(.protocol == "tunnel") | select(.tag | endswith($sfx)) | .tag][0]' "$CONFIG_FILE" 2>/dev/null)
        printf '%s' "$ttag"
        return 0
    fi
    [ "$n" -gt 1 ] && return 2
    return 1
}

# ---------------------------------------------------------------------------
# R30(P1): fail-closed 读取节点 protocol——metadata 损坏/缺失 protocol 时不能当"非 HY2"
# 跳过 hop teardown, 否则删节点后留下孤儿 DNAT。
# R38(P1): 但纯 fail-closed 没有逃生口——一个损坏文件会让该节点永远删不掉。这里补一个
# 可证伪的放行条件: 若能确认"本机根本不存在任何 xray-deploy hop 规则", 就不可能泄漏
# DNAT, 按非 HY2 处理是安全的。无法确认(iptables 缺失 / -S 失败)时仍然拒绝, 并给出
# 明确的人工处置路径, 而不是笼统报错。
# 输出: protocol 字符串(放行时可能是 unknown); 返回 0 允许继续, 1 拒绝
# ---------------------------------------------------------------------------
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

# R30(P1): 判断 tunnel 入站的 port 是否被多个 tunnel 共用(ownership 歧义)。
# 返回 0=歧义(>1), 1=唯一或无法判定。反向展开 parent Reality 前必须确认 port 唯一,
# 否则删 parent Reality + 一个 tunnel 会留下同 port 兄弟 tunnel(半套)。
_tunnel_port_ambiguous() {
    local tag="$1" port n
    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    n=$(jq -r --argjson p "$port" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p)] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -gt 1 ]
}

# ---------------------------------------------------------------------------
# R27(P1): 反向关联——由 tunnel 入站找 parent Reality 主入站 tag。
# 关联键: tunnel .port == realitySettings.target 的端口(一一对应, 非 SNI)。
# 异常配置下可能命中多个 Reality(共用同一 tunnel), 一并输出(每行一个),
# 供 orphan remove 扩展删除集合; 无匹配输出空。
# R38(BLOCKER): `.a // "" == $t` 里 jq 的 // 优先级低于 ==, 会被解析成
#   `.a // ("" == $t)` => `.a // false`, $target 根本不参与比较, 于是"任何带
#   realitySettings.target 的 vless 入站"全部命中 —— 删一个孤儿 tunnel 会把 config
#   里所有 Reality 入站一并删掉(metadata 仍在 => 幽灵节点)。必须显式加括号。
# ---------------------------------------------------------------------------
_find_reality_for_tunnel_tag() {
    local tag="$1" proto tport target
    proto=$(_detect_inbound_protocol "$tag")
    [ "$proto" = "tunnel" ] || return 0
    tport=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ "$tport" =~ ^[0-9]+$ ]] || return 0
    target="127.0.0.1:${tport}"
    jq -r --arg target "$target" \
        '[.inbounds[] | select(.protocol == "vless") | select((.streamSettings.realitySettings.target // "") == $target) | .tag][]' \
        "$CONFIG_FILE" 2>/dev/null
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

    # R26: name 采用 tag, 必须保持 R20 的 name 唯一不变量——若现有节点已用该名, 拒绝采纳
    if ! _ensure_unique_name "$tag"; then
        return 1
    fi

    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // 0' "$CONFIG_FILE" 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    listen=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen // "::"' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$listen" ] && listen="::"

    local uuid=""
    uuid=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.clients[0].id // empty' "$CONFIG_FILE" 2>/dev/null)
    local sni=""
    sni=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE" 2>/dev/null)

    # R23: Reality 多 inbound — 重建 tunnel_tag(唯一关联键, 见 _find_reality_tunnel_tag)。
    # R28(P1): 关联歧义(rc2)必须拒绝采纳——否则 tunnel_tag="" 会把坏配置"合法化",
    # 后续删除泄漏 tunnel; 无关联(rc1)可正常采纳(tunnel 保持孤儿), 唯一(rc0)写入 tunnel_tag。
    local ttag="" trc=1
    if [ "$proto" = "vless-tcp-reality-vision" ] || [ "$proto" = "vless-xhttp-reality" ]; then
        ttag=$(_find_reality_tunnel_tag "$tag"); trc=$?
        if [ "$trc" = "2" ]; then
            _error "Reality tunnel 关联存在歧义(多个 tunnel 命中同端口), 拒绝采纳: $tag"
            return 1
        fi
    fi

    local link="#${tag} (${suffix})"
    if ! _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg proto "$proto" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg sni "$sni" --arg link "$link" \
        --arg ttag "$ttag" \
        '{tag:$tag,name:$tag,protocol:$proto,port:$port,listen:$listen,uuid:$uuid,sni:$sni,tunnel_tag:$ttag,link_addr:$listen,share_link:$link}')"; then
        _warn "采纳失败: 元数据写入失败($tag)"
        return 1
    fi
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

    # R26/R27: orphan remove 双向扩展关联结构, 避免留下半套:
    # 选 Reality → 关联 tunnel(唯一键 target port);
    # 选 Tunnel   → 反向找 parent Reality(target 端口匹配, 非 SNI)——否则
    # 只删 tunnel 会留下指向已删 tunnel 的死 Reality 入站。
    # 关联健壮性见 _find_reality_tunnel_tag(0=唯一 1=无关联 2=歧义)。
    # R29(P1): 不再以"用户原始选择"为删除集合——先逐个验证关联, 只把可安全删除的项
    # 放入 safe set: unique→tag+tunnel, none→tag, ambiguous→排除该 tag(否则删主
    # Reality 会留下 tunnel+routing 半套)。多选中歧义项被排除, 合法项仍删除。
    # R38(P1): 扩展项必须是"未跟踪入站"——本函数只清理孤儿, 绝不能因为关联扩展就删掉
    # 受管节点(有 nodes/<tag>.json)的入站: 那会留下"metadata+clash.yaml 在、inbound 没了"
    # 的反向半套, 且用户看到的是"成功"。命中受管扩展项时整项排除, 引导用户走 [删除节点]。
    local safe=() excluded=() managed=()
    local tag ttag trc rtags rt
    for tag in "${tags[@]}"; do
        ttag=$(_find_reality_tunnel_tag "$tag"); trc=$?
        if [ "$trc" = "2" ]; then
            excluded+=("$tag")
            continue
        fi
        # R30(P1): Tunnel ownership gate —— 必须在 safe+= 之前判定; 多 tunnel 同 port 时
        # ownership 不成立, 排除该项(否则删 parent Reality + 一个 tunnel 留下同 port 兄弟)
        if [ "$(_detect_inbound_protocol "$tag")" = "tunnel" ] && _tunnel_port_ambiguous "$tag"; then
            excluded+=("$tag")
            continue
        fi
        # R38(P1): 先把本项的完整删除集合算出来并逐个检查"是否受管", 任一受管则整项不删
        local group=("$tag") mgr=""
        [ "$trc" = "0" ] && [ -n "$ttag" ] && group+=("$ttag")
        rtags=$(_find_reality_for_tunnel_tag "$tag")
        # R38(P1): 必须逐行读——tag 可含空格(伪装域名曾无字符校验, tunnel_tag 由 SNI 拼成),
        # 无引号 $rtags 会按 IFS 分词并做 glob 展开, 把真实 tag 切碎 => jq 删不到 => 半套
        while IFS= read -r rt; do
            [ -n "$rt" ] && group+=("$rt")
        done <<< "$rtags"
        for rt in "${group[@]}"; do
            if _tag_is_managed "$rt"; then
                mgr="$rt"
                break
            fi
        done
        if [ -n "$mgr" ]; then
            managed+=("${tag} → ${mgr}")
            continue
        fi
        safe+=("${group[@]}")
    done
    if [ ${#excluded[@]} -gt 0 ]; then
        _warn "以下 orphan 因 Reality↔tunnel 关联歧义被取消删除(请人工核对 config): ${excluded[*]}"
    fi
    if [ ${#managed[@]} -gt 0 ]; then
        _warn "以下 orphan 的关联入站属于脚本管理的节点, 已取消删除(避免删掉受管节点): ${managed[*]}"
        _tip "如需删除这些节点请使用 [删除节点], 它会同时清理 config/元数据/Clash 配置"
    fi
    if [ ${#safe[@]} -eq 0 ]; then
        _error "没有可安全删除的入站"
        return 1
    fi
    # 去重(双向扩展可能重复命中同一 tag)
    local uniq=() t u found
    for t in "${safe[@]}"; do
        found=0
        for u in "${uniq[@]}"; do
            [ "$u" = "$t" ] && { found=1; break; }
        done
        [ "$found" = 0 ] && uniq+=("$t")
    done
    safe=("${uniq[@]}")

    local tags_json
    if ! tags_json=$(printf '%s\n' "${safe[@]}" | jq -R . | jq -c -s .); then
        _error "生成移除集合失败"
        return 1
    fi

    local filter='.inbounds |= map(select(.tag as $t | ($rm | index($t)) | not))
                 | .routing.rules |= map(select(.inboundTag == null
                       or ([.inboundTag[]? | . as $it | ($rm | index($it)) == null] | all)))'

    if _mutate_config --argjson rm "$tags_json" "$filter"; then
        _success "已移除 ${#safe[@]} 个入站"
    else
        _error "移除失败, 已回滚"
    fi
}

# ---------------------------------------------------------------------------
# 采纳孤儿入站: 从 config.json 推断元数据, 创建 nodes/*.json
# ---------------------------------------------------------------------------
_adopt_orphan_inbounds() {
    local tags=("$@")
    local adopted=0 failed=0
    for tag in "${tags[@]}"; do
        if _adopt_single_inbound "$tag" "adopted"; then
            adopted=$((adopted+1))
            _info "已采纳: $tag"
        else
            failed=$((failed+1))
        fi
    done
    # R23: 部分失败必须如实报告, 不能整体假装成功; 返回码反映是否全部成功
    [ "$failed" -eq 0 ] || _warn "有 ${failed} 个入站采纳失败"
    if [ "$adopted" -eq 0 ]; then
        _error "未采纳任何入站"
        return 1
    fi
    _success "已采纳 ${adopted} 个入站(分享链接需手动重建)"
    _tip "采纳的节点缺少完整参数, 建议使用 [查看节点] 确认, 或删后重建"
    [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 添加节点:协议分发
# PROTOCOLS 的 name 字段已含对齐空格, 直接打印
# ---------------------------------------------------------------------------
_add_node() {
    clear
    [ -x "$XRAY_BIN" ] || { _error "Xray 未安装,请先在 [8] 安装/更新或切换 Xray 核心(稳定/预览)"; _press_any_key; return 1; }
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
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1))
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

# ---------------------------------------------------------------------------
# 协议1: VLESS+TCP+Reality+Vision (Tunnel 模式, 防偷跑)
# ---------------------------------------------------------------------------
_add_vless_tcp_reality_vision() {
    echo -e "\n  ${CYAN}=== VLESS+TCP+Reality+Vision (Tunnel 模式) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}
    # R38(P1): SNI 会被拼进 tunnel inbound tag, 含空格/引号会破坏按 tag 的关联匹配
    _validate_domain "$sni" || { _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $sni"; return 1; }

    local tunnel_port=$(_gen_random_port)
    _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)

    local default_name="Reality-Vision-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-reality-vision-${port}"
    # R39(P2): tag 长度封顶(见 _gen_tunnel_tag), 避免最长合法 SNI 拼出 270+ 字符的 tag
    local tunnel_tag; tunnel_tag=$(_gen_tunnel_tag "$sni" "$tunnel_port" "$port")
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
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=raw&headerType=none&flow=xtls-rprx-vision&sni=${sni}&fp=firefox&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    # R38(P1): 用户可控字段(节点名/地址)必须过 _yaml_dq 并放进双引号——裸插入时一个 " 就
    # 让整份 clash.yaml 不可解析(不只该节点), 且该脏行事后无法从界面清除
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, uuid: $uuid, flow: xtls-rprx-vision, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID}, \"client-fingerprint\": firefox, network: tcp}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-tcp-reality-vision" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg pqv "$pq_verify" --arg link "$link" \
        --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,mldsa65_verify:$pqv,share_link:$link,tunnel_tag:$ttag,tunnel_port:$tport}')
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): 必须在 metadata 成功之后再写 clash.yaml —— 否则 metadata 写失败时 YAML 条目
    # 已落地而 nodes/<tag>.json 不存在, _remove_node_from_yaml_by_tag 读不到 name,
    # 该条目再也无法通过任何界面清除。
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
    # R38(P1): SNI 会被拼进 tunnel inbound tag, 含空格/引号会破坏按 tag 的关联匹配
    _validate_domain "$sni" || { _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $sni"; return 1; }

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
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-reality-xhttp-${port}"
    # R39(P2): tag 长度封顶(见 _gen_tunnel_tag)
    local tunnel_tag; tunnel_tag=$(_gen_tunnel_tag "$sni" "$tunnel_port" "$port")
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
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=xhttp&mode=auto&sni=${sni}&fp=firefox&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}&path=$(_url_encode "$path")"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, uuid: $uuid, network: xhttp, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID}, \"client-fingerprint\": firefox, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\"}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-reality" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg path "$path" --arg pqv "$pq_verify" --arg link "$link" \
        --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,path:$path,mldsa65_verify:$pqv,share_link:$link,tunnel_tag:$ttag,tunnel_port:$tport}')
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML(见 _add_vless_tcp_reality_vision 同处注释)
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
# 参数 $1: 认证类型 (x25519 | mlkem768), 默认 x25519
# 输出全局: VLESS_ENC_DECRYPTION / VLESS_ENC_ENCRYPTION
# 新版 xray vlessenc 输出双模式(Authentication: section), awk 按 section 定位
# 旧版输出(无 Authentication: 行): jq 优先, grep+sed 兜底
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
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_vless_enc_keys "$AUTH_TYPE" || return 1

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
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, uuid: $uuid, encryption: \"$(_yaml_dq "$VLESS_ENC_ENCRYPTION")\", network: tcp, tls: false${clash_flow}}"

    if ! _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-enc" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg flow "$flow" --arg auth "$AUTH_TYPE" \
        --arg dec "$VLESS_ENC_DECRYPTION" --arg enc "$VLESS_ENC_ENCRYPTION" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,flow:$flow,auth:$auth,decryption:$dec,encryption:$enc,share_link:$link}')"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
    # R38(P1): Host 会进 inbound 模板与 clash 条目; 含空格/引号会破坏模板渲染与 YAML
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

    local default_name="XHTTP-CDN-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || return 1

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-xhttp-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-xhttp-cdn)") || return 1
    _commit_inbound "$inbound" || return 1

    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    local link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=${host}&fp=firefox&alpn=h2&insecure=0&allowInsecure=0&type=xhttp&mode=auto&host=${host}&path=$(_url_encode "$path")#$(_url_encode "$name")"
    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$preferred_addr")\", port: $preferred_port, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": firefox, network: xhttp, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\", host: \"$(_yaml_dq "$host")\"}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-cdn" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg host "$host" --arg path "$path" \
        --arg preferred_addr "$preferred_addr" --argjson preferred_port "$preferred_port" \
        --arg sni "$host" --arg fp "firefox" --arg alpn "h2" \
        --arg insecure "0" --arg allowInsecure "0" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$preferred_addr,uuid:$uuid,host:$host,path:$path,preferred_addr:$preferred_addr,preferred_port:$preferred_port,sni:$sni,fp:$fp,alpn:$alpn,insecure:$insecure,allowInsecure:$allowInsecure,share_link:$link}')
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
    # R38(P1): Host 会进 inbound 模板与 clash 条目; 含空格/引号会破坏模板渲染与 YAML
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

    local default_name="WS-CDN-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || return 1

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-ws-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-ws-cdn)") || return 1
    _commit_inbound "$inbound" || return 1

    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    local link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=${host}&fp=firefox&insecure=0&allowInsecure=0&type=ws&host=${host}&path=$(_url_encode "${path}?ed=2560")#$(_url_encode "$name")"
    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$preferred_addr")\", port: $preferred_port, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": firefox, network: ws, \"ws-opts\": {path: \"$(_yaml_dq "$path")\", headers: {Host: \"$(_yaml_dq "$host")\"}}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-ws-cdn" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg host "$host" --arg path "$path" \
        --arg preferred_addr "$preferred_addr" --argjson preferred_port "$preferred_port" \
        --arg sni "$host" --arg fp "firefox" \
        --arg insecure "0" --arg allowInsecure "0" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$preferred_addr,uuid:$uuid,host:$host,path:$path,preferred_addr:$preferred_addr,preferred_port:$preferred_port,sni:$sni,fp:$fp,insecure:$insecure,allowInsecure:$allowInsecure,share_link:$link}')
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
    _ensure_unique_name "$name" || return 1

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

    local clash="- {name: \"$(_yaml_dq "$name")\", type: ss, server: \"$(_yaml_dq "$addr")\", port: $port, cipher: $method, password: \"$(_yaml_dq "$password")\"}"

    if ! _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "shadowsocks" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg method "$method" --arg password "$password" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,method:$method,password:$password,share_link:$link}')"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
        # xray tls cert 的 --file 是"路径前缀", 实际产出 <前缀>.crt / <前缀>.key。
        # 因此前缀必须落在 cert_dir 内部(传目录本身会在其父目录生成 <目录名>.crt/.key)。
        XRAY_LOCATION_ASSET= "$XRAY_BIN" tls cert --domain build.nvidia.com \
            --file "${cert_dir}/cert" 2>/dev/null
        [ -f "${cert_dir}/cert.crt" ] && mv -f "${cert_dir}/cert.crt" "$CERT_FILE_PATH"
        [ -f "${cert_dir}/cert.key" ] && mv -f "${cert_dir}/cert.key" "$KEY_FILE_PATH"
        # 清理历史错误写法可能残留在父目录的 <tag>.crt/.key
        rm -f "${CERT_DIR}/${tag}.crt" "${CERT_DIR}/${tag}.key" 2>/dev/null
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
    _ensure_unique_name "$name" || return 1

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
    # 密码/SNI 均 URL 编码(自定义密码可能含 @:/?# 等保留字符)
    local enc_auth enc_sni
    enc_auth=$(_url_encode "$auth"); enc_sni=$(_url_encode "$sni")
    local link="hy2://${enc_auth}@${link_ip}:${port}/?sni=${enc_sni}"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1&allowInsecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
    link="${link}#$(_url_encode "$name")"

    # clash yaml
    local clash_insecure=""
    [ "$self_signed" = "true" ] && clash_insecure=", skip-cert-verify: true"
    local clash="- {name: \"$(_yaml_dq "$name")\", type: hysteria2, server: \"$(_yaml_dq "$addr")\", port: $port, password: \"$(_yaml_dq "$auth")\", sni: \"$(_yaml_dq "$sni")\", \"congestion-control\": $congestion${clash_insecure}}"

    # 元数据
    if ! _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "hysteria2" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg auth "$auth" --arg sni "$sni" --arg congestion "$congestion" \
        --arg brutalUp "$brutal_up" --arg brutalDown "$brutal_down" \
        --arg link "$link" --argjson ss "$self_signed" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,auth:$auth,sni:$sni,congestion:$congestion,brutal_up:$brutalUp,brutal_down:$brutalDown,self_signed:$ss,share_link:$link}')"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

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
# R38(M10): 必填字段用 // empty 读取并显式判空 —— 原写法对"被采纳的节点"(metadata 只有
# tag/protocol/port/listen/uuid/sni/link_addr/share_link, 没有 auth/congestion)会产出
# hy2://null@[::]:5000/?sni=&congestion=null#... 这种字面量 null 的坏链接; 它非空,
# 于是通过上层 `[ -n "$newlink" ]` 校验被写进 metadata, 覆盖掉原链接且不可恢复。
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
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link="hy2://$(_url_encode "$auth")@${link_ip}:${port}/?sni=$(_url_encode "$sni")"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1&allowInsecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
    # 端口跳跃端口(如果已配置, 统一通过 _read_hop_ranges_display 读取, M9)
    local hop_ports
    hop_ports=$(_read_hop_ranges_display "$meta" 2>/dev/null)
    [ -n "$hop_ports" ] && link="${link}&mport=$(_url_encode "$hop_ports")"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 vless:// reality 分享链接(从元数据读参数)
# 用法:_rebuild_reality_link <meta_file> [new_sni]  不传 new_sni 则用 meta 里的 sni
# R38(M10): 与 _rebuild_hy2_link 同因 —— 必填字段缺失时必须失败, 不能产出含 null 的坏链接
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
            link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=raw&headerType=none&flow=xtls-rprx-vision&sni=${sni}&fp=firefox&pbk=$(_url_encode "$pk")&sid=${sid}"
            ;;
        vless-xhttp-reality)
            link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=xhttp&mode=auto&sni=${sni}&fp=firefox&pbk=$(_url_encode "$pk")&sid=${sid}&path=$(_url_encode "$path")"
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
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_encoded}&security=none&type=raw"
    [ -n "$flow" ] && link="${link}&flow=${flow}"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 CDN 节点分享链接(从元数据读参数)
# 用法:_rebuild_cdn_link <meta_file>
_rebuild_cdn_link() {
    local meta="$1"
    local uuid host path name proto preferred_addr preferred_port sni fp alpn insecure allowInsecure
    uuid=$(jq -r '.uuid' "$meta")
    host=$(jq -r '.host' "$meta")
    path=$(jq -r '.path // empty' "$meta")
    name=$(jq -r '.name' "$meta")
    proto=$(jq -r '.protocol' "$meta")
    preferred_addr=$(jq -r '.preferred_addr // .host' "$meta")
    preferred_port=$(jq -r '.preferred_port // "443"' "$meta")
    sni=$(jq -r '.sni // .host' "$meta")
    fp=$(jq -r '.fp // "firefox"' "$meta")
    alpn=$(jq -r '.alpn // "h2"' "$meta")
    insecure=$(jq -r '.insecure // "0"' "$meta")
    allowInsecure=$(jq -r '.allowInsecure // "0"' "$meta")
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
            link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=${sni}&fp=${fp}&alpn=${alpn}&insecure=${insecure}&allowInsecure=${allowInsecure}&type=xhttp&mode=auto&host=${host}&path=$(_url_encode "$path")"
            ;;
        vless-ws-cdn)
            link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=${sni}&fp=${fp}&insecure=${insecure}&allowInsecure=${allowInsecure}&type=ws&host=${host}&path=$(_url_encode "${path}?ed=2560")"
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
    printf "  %-3s %-20s %-26s %-7s %-10s %-16s %-18s\n" "#" "名称" "协议" "端口" "认证" "监听" "链接地址"
    echo "  --------------------------------------------------------------------------------------------------"
    local i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name proto port auth listen addr
        name=$(jq -r '.name' "$f" 2>/dev/null)
        proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        port=$(jq -r '.port' "$f" 2>/dev/null)
        auth=$(jq -r '.auth // "—"' "$f" 2>/dev/null)
        listen=$(jq -r '.listen' "$f" 2>/dev/null)
        addr=$(jq -r '.link_addr' "$f" 2>/dev/null)
        printf "  %-3s %-20s %-26s %-7s %-10s %-16s %-18s\n" "[$i]" "${name}" "${proto}" "${port}" "${auth}" "${listen}" "${addr}"
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
            local name link auth
            name=$(jq -r '.name' "$f"); link=$(jq -r '.share_link' "$f")
            auth=$(jq -r '.auth // "—"' "$f" 2>/dev/null)
            echo
            echo -e "  ${CYAN}【${name}】${NC}"
            [ "$auth" != "—" ] && echo -e "  认证算法: ${auth}"
            echo -e "  ${GREEN}${link}${NC}"
            local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
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
        # R17: 先清理所有端口跳跃 iptables 规则(teardown 事务)
        # R33(P1): 无条件调用 teardown_all——iptables 不可用但存在 hop 规则时由其内部 fail-closed
        # (不能因 command -v iptables 为假就跳过, 否则删 config/metadata 后留下孤儿 DNAT)
        # R38(P1): teardown_all 现在逐项判定, 无法安全清理的节点进 _HY2_HOP_SKIP 并被保留,
        # 不再因一个损坏节点让"全部删除"整体不可用。
        if ! _hy2_hop_teardown_all "${tags[@]}"; then
            _error "所有节点都无法安全清理端口跳跃规则, 已取消删除(节点未动)"
            _press_any_key; return
        fi
        _hy2_filter_skipped "${tags[@]}"
        local del_all=("${_HY2_DEL_KEEP[@]}")
        if [ ${#del_all[@]} -eq 0 ]; then
            _error "没有可安全删除的节点"
            _press_any_key; return
        fi
        # 无排除项: 沿用原语义(清空 inbounds, 连手工添加的入站一并清掉)
        # 有排除项: 只删可安全删除的 tag(含其 tunnel_tag), 保留被排除节点的入站
        local all_filter='.inbounds = [] | .routing.rules |= map(select(.inboundTag == null or (.inboundTag | type) == "array" and (.inboundTag | length) == 0))'
        local all_ok=0
        if [ ${#_HY2_HOP_SKIP[@]} -eq 0 ]; then
            _mutate_config "$all_filter" && all_ok=1
        else
            local keep_tags=() kt ktt
            for kt in "${del_all[@]}"; do
                keep_tags+=("$kt")
                ktt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${kt}.json" 2>/dev/null)
                [ -n "$ktt" ] && keep_tags+=("$ktt")
            done
            local rm_json
            rm_json=$(printf '%s\n' "${keep_tags[@]}" | jq -R . | jq -c -s .) || rm_json=""
            if [ -z "$rm_json" ]; then
                _error "生成移除集合失败"
                _hy2_hop_restore_after_teardown
                _press_any_key; return
            fi
            _mutate_config --argjson rm "$rm_json" \
                '.inbounds |= map(select(.tag as $t | ($rm | index($t)) | not))
                 | .routing.rules |= map(select(.inboundTag == null
                       or ([.inboundTag[]? | . as $it | ($rm | index($it)) == null] | all)))' && all_ok=1
        fi
        if [ "$all_ok" -eq 1 ]; then
            for tag in "${del_all[@]}"; do
                # R38(P1): 先删 metadata 再删 YAML 会读不到 name; 但 YAML 删除失败不阻断,
                # 顺序仍是"先 YAML(读 json 的 name) 后 json"
                _remove_node_from_yaml_by_tag "$tag" || \
                    _warn "Clash YAML 同步删除失败($tag), 可手工编辑 ${CLASH_YAML} 清除该行"
                rm -f "$NODES_DIR/${tag}.json"
            done
            # R18: 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
            _HY2_HOP_TD=()
            # 仅在"确实全删干净"时才截断 clash.yaml; 有保留节点时不能清空
            if [ ${#_HY2_HOP_SKIP[@]} -eq 0 ] && [ -f "$CLASH_YAML" ]; then
                printf 'proxies:\n' > "$CLASH_YAML"
            fi
            _success "已删除 ${#del_all[@]} 个节点"
        else
            # config 提交失败(已回滚): 恢复已 teardown 的 hop 规则
            _hy2_hop_restore_after_teardown
            _error "删除失败, 已回滚"
        fi
        _press_any_key; return
    fi

    # 多选删除:逗号分隔(如 1,3,5)
    if [[ "$choice" == *","* ]]; then
        IFS=',' read -ra nums <<< "$choice"
        local del_tags=()
        for n in "${nums[@]}"; do
            n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            local di=$((n-1)); local dt="${tags[$di]:-}"
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

        # R17: 先清理端口跳跃 iptables 规则(teardown 事务)
        # R33(P1): 无条件调用 teardown_all——iptables 不可用但存在 hop 规则时由其内部 fail-closed
        # R38(P1): 逐项判定, 无法安全清理的节点被排除而不是整批取消; 删除集合(含 tunnel_tag)
        # 必须在 teardown 之后按剩余项重算, 否则会把被排除节点的入站一起删掉。
        if ! _hy2_hop_teardown_all "${del_tags[@]}"; then
            _error "所选节点都无法安全清理端口跳跃规则, 已取消删除(节点未动)"
            _press_any_key; return
        fi
        _hy2_filter_skipped "${del_tags[@]}"
        del_tags=("${_HY2_DEL_KEEP[@]}")
        if [ ${#del_tags[@]} -eq 0 ]; then
            _error "没有可安全删除的节点"
            _press_any_key; return
        fi
        local del_ttags=()
        for dt in "${del_tags[@]}"; do
            local dtt; dtt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${dt}.json" 2>/dev/null)
            [ -n "$dtt" ] && del_ttags+=("$dtt")
        done

        local tun_json='[]'
        [ ${#del_ttags[@]} -gt 0 ] && tun_json=$(printf '%s\n' "${del_ttags[@]}" | jq -R . | jq -s .)
        local all_json; all_json=$(printf '%s\n' "${del_tags[@]}" "${del_ttags[@]}" | jq -R . | jq -s .)

        local jq_multi='.inbounds |= map(select(.tag as $t | $all_tags | index($t) | not))'
        if [ ${#del_ttags[@]} -gt 0 ]; then
            jq_multi="$jq_multi | .routing.rules |= map(select(.inboundTag == null or (.inboundTag as $it | $tun_tags | index($it) | not)))"
        fi

        if _mutate_config --argjson all_tags "$all_json" --argjson tun_tags "$tun_json" "$jq_multi"; then
            # R19: 消费 YAML 删除返回值, 失败则累计并显式告警(不静默; clash.yaml 属派生导出)
            local yaml_fail=0
            for dt in "${del_tags[@]}"; do
                # R18: 先删 YAML(需读 json 的 name)再删 json, 否则幽灵节点残留在 clash.yaml
                _remove_node_from_yaml_by_tag "$dt" || yaml_fail=1
                rm -f "$NODES_DIR/${dt}.json"
            done
            # R38(P1): 不再指向不存在的"重新生成 Clash 配置"功能, 给出真实可执行的路径
            [ "$yaml_fail" -eq 1 ] && \
                _warn "部分节点 Clash YAML 同步删除失败, 已从 Xray 删除; 可手工编辑 ${CLASH_YAML} 删除对应行"
            # R18: 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
            _HY2_HOP_TD=()
            _success "已删除 ${#del_tags[@]} 个节点"
        else
            # config 提交失败(已回滚): 恢复已 teardown 的 hop 规则
            _hy2_hop_restore_after_teardown
            _error "删除失败, 已回滚"
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
    # R17: 先清理端口跳跃规则(teardown 事务; 失败则取消删除, 节点整体保持原状)
    # R30(P1): fail-closed——metadata 损坏/缺 protocol 不能当"非 HY2"跳过 teardown,
    # 否则删节点后 hop DNAT 永久残留(孤儿防火墙规则)
    local proto hop_port ranges=""
    if ! proto=$(_node_protocol_safe "$tag"); then
        _press_any_key; return
    fi
    if [ "$proto" = "hysteria2" ]; then
        # R31(P1): hop 范围字段存在但无法解析 → 拒绝删除(不当作"无 hop"跳过 teardown)
        _hy2_hop_meta_ok "$tag" || { _press_any_key; return; }
        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        if [ -n "$ranges" ]; then
            # R33(P1): 存在 hop 规则但 iptables 不可用 → 无法安全删除(否则删 config/metadata
            # 留孤儿 DNAT, 且 metadata 已删后无法追溯 dport 归属)
            if ! command -v iptables >/dev/null 2>&1; then
                _error "节点存在端口跳跃规则, 但 iptables 不可用, 无法安全删除: $tag"
                _press_any_key; return
            fi
            if ! hop_port=$(jq -r '.port // empty' "$NODES_DIR/${tag}.json" 2>/dev/null); then
                _error "节点元数据损坏, 无法确认端口: $tag"
                _press_any_key; return
            fi
            [[ "$hop_port" =~ ^[0-9]+$ ]] || {
                _error "节点元数据损坏(端口无效): $tag"
                _press_any_key; return
            }
            # R31(P1): metadata.port 必须与 config 真实监听端口一致——否则 teardown 用错误目标
            # 端口找不到(或误删)DNAT 规则, 留下 :<真实端口> 的孤儿规则。
            # 仅当 config 存在该 inbound 时强制(真实删除流 inbound 必在 config; config 已无该
            # inbound 说明已是孤儿/外部删除, metadata.port 仍是当初 add 用的正确清理目标)。
            local cfg_port
            cfg_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
            if [ -n "$cfg_port" ] && [ "$cfg_port" != "$hop_port" ]; then
                _error "节点元数据端口($hop_port)与 config 监听端口($cfg_port)不一致, 无法安全删除: $tag"
                _press_any_key; return
            fi
            _info "清理端口跳跃规则..."
            # shellcheck disable=SC2086
            if ! _hy2_hop_teardown "$hop_port" $ranges; then
                _error "端口跳跃规则清理失败, 已取消删除(节点未动)"
                _press_any_key; return
            fi
        fi
    fi
    if _mutate_config --arg t "$tag" --arg tg "$tunnel_tag" "$jq_filter"; then
        # R18: 先删 YAML(需读 json 的 name)再删 json, 否则幽灵节点残留在 clash.yaml
        # R19: 消费 YAML 删除返回值——失败不静默(权威删除已完成, clash.yaml 属派生导出)
        # R38(P1): 不再指向不存在的"重新生成 Clash 配置"功能, 给出真实可执行的处置路径
        if ! _remove_node_from_yaml_by_tag "$tag"; then
            _warn "Clash YAML 同步删除失败($tag), 节点已从 Xray 删除; 可手工编辑 ${CLASH_YAML} 删除对应行"
        fi
        rm -f "$NODES_DIR/${tag}.json"
        # R18: 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
        _HY2_HOP_TD=()
        _success "节点已删除"
    else
        # config 提交失败(已回滚): 恢复已清理的 hop 规则
        # R38(P1): 原写法 `[ -n "$ranges" ] && A || _error` 在 ranges 为空时(任何非 hy2 /
        # 无 hop 的节点)必然执行 _error, 于是删除普通 VLESS 节点失败时会额外报一条
        # "恢复端口跳跃规则失败, 请手动检查 iptables" —— 用户会去翻根本不存在的规则。
        if [ -n "$ranges" ]; then
            # shellcheck disable=SC2086
            _hy2_hop_reverse remove "$hop_port" $ranges 2>/dev/null || \
                _error "恢复端口跳跃规则失败, 请手动检查 iptables"
        fi
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

    # 更新元数据 + 链接(端口出现在链接里)
    local meta="$NODES_DIR/${tag}.json"
    local oldport; oldport=$(jq -r '.port' "$meta")
    local proto; proto=$(jq -r '.protocol' "$meta" 2>/dev/null)

    # R41: 端口未变化时直接返回, 避免无意义重启; 也防止 Reality 分支对同名元数据文件 mv(同文件错误)
    [ "$newport" = "$oldport" ] && { _info "端口未变化"; _press_any_key; return; }

    # hy2 + 端口跳跃: 走统一端口事务(_hy2_port_txn), 避免 config/metadata 先提交、iptables 后失败
    # 造成 config/metadata/iptables 三方分叉(R16); 任一步失败回滚到旧端口
    # R38(P1): 原写法 `[ "$proto" = hysteria2 ] && command -v iptables` 为假就整块跳过 →
    # 落到普通 _mutate_config 只改监听端口, 而 metadata 的 hop_ranges 仍在、已持久化到
    # /etc/iptables 的 DNAT 仍指旧端口 → 跳跃客户端全挂且界面看不出。现与删除路径对齐:
    # 先判 hop 是否启用, 启用则要求 iptables 可用, 否则 fail-closed 拒绝改端口。
    if [ "$proto" = "hysteria2" ]; then
        # R32(P1): 与删除语义一致——hop metadata 存在但无法解析时 fail-closed, 不能把
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

    # ----------------------------------------------------------------------
    # Reality 节点分支(R41): 端口变更必须同步更新主 tag(含端口)、tunnel tag、
    # 路由规则 inboundTag 引用与元数据。主 tag 即元数据文件名, 一并重命名,
    # 否则 tag/config/metadata 三方不一致(删除/域名切换等按 tag 定位的操作全错)。
    # 更新模型与 _reality_domain_menu 一致: jq 重命名 tag + 重写路由规则。
    # R41(P1): 事务模型对齐 _hy2_port_txn —— 内存生成完整新 metadata → 提交
    # metadata → 最后提交 config; 任一步失败回滚已提交步骤(config 由 _mutate_config
    # 自带回滚), 保证 config/metadata 全部回到旧端口或全部新端口。
    # ----------------------------------------------------------------------
    if [ "$proto" = "vless-tcp-reality-vision" ] || [ "$proto" = "vless-xhttp-reality" ]; then
        # 旧版/手动创建节点可能缺 tunnel_tag —— 从 config 关联推导(R26/R28)。
        # R41(P1): fail-closed —— 推导失败(rc=1)或歧义(rc=2)一律拒绝改端口, 否则
        # 只改主 tag 而 tunnel/路由未改, 重新制造 R41 要消灭的不一致。
        local tunnel_tag tunnel_port sni trc
        tunnel_tag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null)
        tunnel_port=$(jq -r '.tunnel_port // empty' "$meta" 2>/dev/null)
        sni=$(jq -r '.sni // empty' "$meta" 2>/dev/null)
        if [ -z "$tunnel_tag" ]; then
            tunnel_tag=$(_find_reality_tunnel_tag "$tag"); trc=$?
            if [ "$trc" != "0" ]; then
                _error "无法唯一关联 Reality tunnel (rc=${trc}), 无法安全修改端口: $tag"
                _tip "请检查 config.json 的 realitySettings.target 与 tunnel 入站, 或删除后重建节点"
                _press_any_key; return 1
            fi
        fi

        # 主 tag 前缀(xd-reality-vision / xd-reality-xhttp) + 新端口
        local new_tag="${tag%-*}-${newport}"
        # 新 tunnel tag: 仅替换末段 reality 端口(Tunnel-<sni>-<tport>-<port>);
        # 保持 SNI 段原样(含旧版无长度封顶产生的超长 SNI 段, 不做二次截断)
        local new_tunnel_tag=""
        if [ -n "$tunnel_tag" ]; then
            new_tunnel_tag="${tunnel_tag%-*}-${newport}"
        fi

        # R41(P2): 新 tag 冲突检查 —— 目标元数据文件已存在说明该端口/标签被其他节点占用,
        # mv 会静默覆盖。不依赖 _input_port 的上游间接保证, 这里显式校验。
        if [ -e "$NODES_DIR/${new_tag}.json" ]; then
            _error "目标标签 ${new_tag} 已存在(端口 ${newport} 可能已被其他节点使用), 请换一个端口"
            _press_any_key; return 1
        fi

        # 在内存生成完整新 metadata(port/tag/tunnel_tag/name/share_link), 未落地任何文件。
        # _rebuild_reality_link 从文件读, 故用临时文件承载"新 port + 新 name"再重建,
        # 使链接 #fragment 也同步为新名(与 _hy2_gen_port_newmeta 同思路)。
        local tmpm newmeta newlink old_name new_name
        tmpm=$(mktemp "${meta}.port.XXXXXX") || { _error "创建临时文件失败"; _press_any_key; return 1; }
        old_name=$(jq -r '.name' "$meta")
        new_name="${old_name//${oldport}/${newport}}"
        if ! jq --argjson p "$newport" --arg nt "$new_tag" --arg ntg "$new_tunnel_tag" \
            --arg nn "$new_name" \
            '.port=$p | .tag=$nt | (if $ntg != "" then .tunnel_tag=$ntg else . end) | .name=$nn' \
            "$meta" > "$tmpm"; then
            rm -f "$tmpm"; _error "生成元数据失败"; _press_any_key; return 1
        fi
        if ! newlink=$(_rebuild_reality_link "$tmpm") || [ -z "$newlink" ]; then
            rm -f "$tmpm"
            _warn "分享链接重建失败(元数据缺少必要字段), 端口未修改"
            _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
            _press_any_key; return 1
        fi
        if ! newmeta=$(jq --arg l "$newlink" '.share_link=$l' "$tmpm") || [ -z "$newmeta" ]; then
            rm -f "$tmpm"; _error "生成元数据失败"; _press_any_key; return 1
        fi
        rm -f "$tmpm"

        # ---- 统一事务(对齐 _hy2_port_txn): 快照原 metadata → 重命名+提交 metadata → 提交 config ----
        local orig
        orig=$(cat "$meta" 2>/dev/null) || { _error "读取元数据失败"; _press_any_key; return 1; }

        # 1. 主 tag 即元数据文件名 —— 先重命名(config 未动, 失败干净中止)
        if ! mv "$NODES_DIR/${tag}.json" "$NODES_DIR/${new_tag}.json"; then
            _error "节点元数据文件重命名失败(${tag}.json → ${new_tag}.json), 未做任何修改"
            _press_any_key; return 1
        fi
        meta="$NODES_DIR/${new_tag}.json"

        # 2. 原子提交新 metadata; 失败时反向 mv 恢复文件名(此时新文件仍是原内容), config 未动
        if ! _atomic_write_json "$meta" "$newmeta"; then
            _error "端口元数据提交失败, 恢复原文件名..."
            mv -f "$NODES_DIR/${new_tag}.json" "$NODES_DIR/${tag}.json" 2>/dev/null || \
                _error "元数据文件名恢复失败, 请手动检查 ${NODES_DIR}"
            _press_any_key; return 1
        fi

        # 3. 最后提交 config(改端口 + 重命名主 tag + tunnel tag + 路由规则引用)。
        #    _mutate_config 失败会自行恢复旧 config 并重启回旧端口; 这里同步回滚 metadata。
        local jq_filter
        jq_filter='(.inbounds[] | select(.tag == $t) | .tag) = $new_t
| (.inbounds[] | select(.tag == $new_t) | .port) = $p'
        if [ -n "$tunnel_tag" ]; then
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
            rm -f "$NODES_DIR/${new_tag}.json" 2>/dev/null
            _atomic_write_json "$NODES_DIR/${tag}.json" "$orig" || \
                _error "元数据回滚失败, 请手动检查 ${NODES_DIR}/${tag}.json"
            _press_any_key; return 1
        fi

        _success "端口已改为 ${newport}(标签与 tunnel 标签已同步更新)"
        _press_any_key
        return
    fi

    # 非 hop 路径: 原流程(config -> metadata)
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口修改失败, 已回滚"; _press_any_key; return 1
    fi

    # 先更新端口到元数据(rebuild 函数需要读新端口); 原子写(R15)
    local port_meta
    port_meta=$(jq --argjson p "$newport" '.port=$p' "$meta") || { _error "生成元数据失败"; _press_any_key; return 1; }
    if ! _atomic_write_json "$meta" "$port_meta"; then
        _error "端口元数据写入失败"; _press_any_key; return 1
    fi

    # 按协议重建分享链接(避免裸字符串替换误伤其他字段, S4)
    # R38(M10): 消费 rebuild 的返回码 —— 被采纳的节点缺少 auth/public_key 等字段, 重建会失败;
    # 此时必须保留原 share_link(config 端口已改, 链接需用户手动重建), 不能写入坏链接。
    local newlink rebuild_rc=0
    case "$proto" in
        hysteria2) newlink=$(_rebuild_hy2_link "$meta") || rebuild_rc=1 ;;
        vless-tcp-reality-vision|vless-xhttp-reality) newlink=$(_rebuild_reality_link "$meta") || rebuild_rc=1 ;;
        vless-enc) newlink=$(_rebuild_vless_enc_link "$meta") || rebuild_rc=1 ;;
        vless-xhttp-cdn|vless-ws-cdn) newlink=$(_rebuild_cdn_link "$meta") || rebuild_rc=1 ;;
        *)
            # 其他协议: @ 锚定分割确保只替换 host:port 段(不误伤 path/sni/name)
            local oldlink; oldlink=$(jq -r '.share_link' "$meta")
            local before_at="${oldlink%%@*}"
            local after_at="${oldlink#*@}"
            local host_part
            if [[ "$after_at" == "["* ]]; then
                host_part="${after_at%%]*}]"
            else
                host_part="${after_at%%[:/?#]*}"
            fi
            if [[ "$host_part" == "["* ]]; then
                local tail_offset=$((${#host_part} + ${#oldport} + 1))
                newlink="${before_at}@${host_part}:${newport}${after_at:$tail_offset}"
            else
                newlink="${before_at}@${host_part}:${newport}${after_at#${host_part}:${oldport}}"
            fi
            ;;
    esac

    # R38(M10): 重建失败或结果为空 -> 只提示, 不覆盖原 share_link
    if [ "$rebuild_rc" -ne 0 ] || [ -z "$newlink" ]; then
        _warn "分享链接重建失败(元数据缺少必要字段), 端口已改为 ${newport} 但分享链接未更新"
        _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
        _press_any_key
        return 1
    fi

    # 同步更新节点名称(名称通常包含端口号) + 分享链接; 原子写(R15)
    local old_name new_name meta2
    old_name=$(jq -r '.name' "$meta")
    new_name="${old_name//${oldport}/${newport}}"
    if [ "$new_name" != "$old_name" ]; then
        meta2=$(jq --arg l "$newlink" --arg n "$new_name" '.share_link=$l | .name=$n' "$meta") || { _error "生成元数据失败"; _press_any_key; return 1; }
    else
        meta2=$(jq --arg l "$newlink" '.share_link=$l' "$meta") || { _error "生成元数据失败"; _press_any_key; return 1; }
    fi
    if ! _atomic_write_json "$meta" "$meta2"; then
        _error "分享链接元数据写入失败"; _press_any_key; return 1
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
    # CDN 协议强制填域名(M12: CDN 节点填公网 IP 会导致直连失效)
    case "$proto" in *-cdn)
        echo -e "  ${YELLOW}该节点为 CDN 协议, 必须使用 CDN 域名${NC}"
        echo -e "  当前链接服务器地址: ${oldaddr}"
        read -rp "  请输入 CDN 域名: " newaddr
        [[ "$newaddr" == *"."* ]] || { _warn "CDN 节点须填域名, 而非 IP"; _press_any_key; return; }
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

    _meta_update "$meta" '.listen=$l | .link_addr=$a | .share_link=$link' \
        --arg l "$newlisten" --arg a "$newaddr" --arg link "$newlink" || { _error "监听元数据写入失败"; _press_any_key; return 1; }

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
    # R22: name 由调用方显式传入, 不再从整行反解析 — 避免 YAML 转义/特殊字符
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
    # R19: mktemp 失败显式报错
    if ! tmp=$(mktemp); then
        _error "无法创建临时 Clash YAML 文件"
        return 1
    fi
    # 固定字符串匹配 name: "name" 含闭合引号(避免子串误删/正则转义)
    # R38(P1): 匹配串必须与写入侧同样过 _yaml_dq —— 写入的是转义后的形态(如 HK\"1),
    # 用原始 name 去匹配会永远找不到, 导致"写得进去却删不掉"的永久残留条目。
    # 含换行的 name 无法用行匹配删除(条目本身也不该跨行), 由 _yaml_dq 转成 \n 后即为单行。
    local key; key=$(_yaml_dq "$name")
    grep -vF "name: \"${key}\"" "$CLASH_YAML" > "$tmp" 2>/dev/null
    grc=$?
    # grep rc: 0=有选中行(已写入) 1=无选中行(节点不在, 合法) 2=读取/写入错误
    if [ "$grc" -ge 2 ]; then
        rm -f "$tmp"
        _error "Clash YAML 读取/过滤失败(grep rc=$grc)"
        return 1
    fi
    # R19: 过滤结果为空(最后一个节点被删)时保留 proxies: 头, 避免 YAML 变成空文件
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
    # R19: 读不到 name(如 json 已被删/损坏)视为删除失败, 由调用方决定取消或显式告警
    [ -z "$name" ] && return 1
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
                # 事务(R15): 生成新 metadata(删 hop 字段, 链接不再含 &mport=) ->
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
        # 事务(R15): 生成新 metadata(hop 字段 + 含 &mport= 的分享链接) ->
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
