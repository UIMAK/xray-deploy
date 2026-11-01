#!/bin/bash
# lib/30-geo.sh — Geo 更新、路由精简与 DNS 设置。
# Geo 自动更新默认 OFF, 使用 Xray 内置 geodata。
# 数据源默认 XTLS/Xray-rules-dat, 可切 Loyalsoldier 或自定义链接; 落点 $ASSET_DIR, 下载失败保留旧 dat。
# 内置 assets.file 必须预先存在, 否则核心拒绝启动; 见 _geo_set_auto_update。
# DNS 写入走 _mutate_config 的重启与回滚; 见 _dns_apply。

GEO_CRON_EXPR="0 3 */3 * *"

# 数据源只记预设名, 链接由常量给: 上游改名只改常量, 老机器不留死链。
_geo_source_name() {
    local src=""
    src=$(_state_get geo_source 2>/dev/null) || src=""
    case "$src" in
        xtls|loyal|custom) printf '%s' "$src" ;;
        *) printf '%s' "xtls" ;;
    esac
}

_geo_url_valid() {
    local u="${1:-}"
    case "$u" in
        "https://"?*) ;;
        *) return 1 ;;
    esac
    case "$u" in
        *[[:space:]]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 唯一 URL 映射点; 远端文件名按源不同, 本地落点恒为 geosite.dat / geoip.dat。
_geo_url_for() {
    local src="$1" kind="$2" cgs="${3:-}" cgi="${4:-}"
    case "$src:$kind" in
        xtls:geosite) printf '%s' "$GEO_SRC_XTLS_GEOSITE" ;;
        xtls:*) printf '%s' "$GEO_SRC_XTLS_GEOIP" ;;
        loyal:geosite) printf '%s' "$GEO_SRC_LOYAL_GEOSITE" ;;
        loyal:*) printf '%s' "$GEO_SRC_LOYAL_GEOIP" ;;
        custom:geosite) printf '%s' "$cgs" ;;
        *) printf '%s' "$cgi" ;;
    esac
}

# 当前选择的下载 URL; custom 两条链接缺失/非法时静默回落默认源。
_geo_source_url() {
    local kind="$1" src="" cgs="" cgi=""
    src=$(_geo_source_name)
    if [ "$src" = "custom" ]; then
        cgs=$(_state_get geo_geosite_url 2>/dev/null) || cgs=""
        cgi=$(_state_get geo_geoip_url 2>/dev/null) || cgi=""
        _geo_url_valid "$cgs" || src="xtls"
        _geo_url_valid "$cgi" || src="xtls"
    fi
    _geo_url_for "$src" "$kind" "$cgs" "$cgi"
}

# custom 两条链接都存在且合法才算有效; label 与 assets 回落共用这一判据。
_geo_custom_links_valid() {
    local cgs="" cgi=""
    cgs=$(_state_get geo_geosite_url 2>/dev/null) || cgs=""
    cgi=$(_state_get geo_geoip_url 2>/dev/null) || cgi=""
    _geo_url_valid "$cgs" && _geo_url_valid "$cgi"
}

# 链接无效时 label 必须与菜单实际显示的回落 URL 一致, 不能只写"自定义链接"。
_geo_source_label() {
    case "$(_geo_source_name)" in
        loyal) printf '%s' "Loyalsoldier/v2ray-rules-dat (完整版)" ;;
        custom)
            if _geo_custom_links_valid; then
                printf '%s' "自定义链接"
            else
                printf '%s' "自定义链接(链接无效, 已回落默认)"
            fi
            ;;
        *) printf '%s' "XTLS/Xray-rules-dat (默认)" ;;
    esac
}

# 内置定时生效时 config 的 assets 才是实际下载源; 与当前选择不一致需重新应用。
_geo_builtin_source_drifted() {
    _config_present || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local cron="" urls=""
    cron=$(_config_jq -r '.geodata.cron // ""' 2>/dev/null) || return 1
    [ -n "$cron" ] || return 1
    urls=$(_config_jq -r '.geodata.assets[]?.url // empty' 2>/dev/null) || return 1
    [ -n "$urls" ] || return 1
    case "$urls" in *"$(_geo_source_url geosite)"*) ;; *) return 0 ;; esac
    case "$urls" in *"$(_geo_source_url geoip)"*) ;; *) return 0 ;; esac
    return 1
}

# assets 唯一构造点: 内置两项的本地文件名恒为 geosite.dat / geoip.dat, 远端名随源变化。
# 省略链接时从 state 取 custom 链接; 任一链接非法则整体回落默认源(与 _geo_source_url 同判据)。
# assets 一律 = 两个内置项 + 所有 extras; extras 只存在于 state, 见 _geo_extra_assets_json。
_geo_assets_json() {
    local src="$1" cgs="${2:-}" cgi="${3:-}" extras=""
    if [ "$src" = "custom" ]; then
        [ -n "$cgs" ] || { cgs=$(_state_get geo_geosite_url 2>/dev/null) || cgs=""; }
        [ -n "$cgi" ] || { cgi=$(_state_get geo_geoip_url 2>/dev/null) || cgi=""; }
        if ! _geo_url_valid "$cgs" || ! _geo_url_valid "$cgi"; then
            src="xtls"
            cgs=""
            cgi=""
        fi
    fi
    extras=$(_geo_extra_assets_json) || return 1
    jq -n \
        --arg u1 "$(_geo_url_for "$src" geosite "$cgs" "$cgi")" \
        --arg u2 "$(_geo_url_for "$src" geoip "$cgs" "$cgi")" \
        --argjson extra "$extras" \
        '([{url: $u1, file: "geosite.dat"}, {url: $u2, file: "geoip.dat"}] + $extra)'
}

# 生成 geodata JSON: cron 五字段、assets URL 必须 HTTPS; 供 --argjson 使用。
# 省略 outbound 时下载遵循 Xray 路由, 不等于固定直连。
_geo_geodata_json() {
    local assets
    assets=$(_geo_assets_json "$(_geo_source_name)") || return 1
    jq -n --arg cron "$GEO_CRON_EXPR" --argjson a "$assets" '{cron: $cron, assets: $a}'
}

# 状态只读取配置中的 geodata.cron。
# 输出 builtin|off, _geo_auto_state 映射为 on|off。
_geo_auto_mechanism() {
    local c=""
    if _config_present && command -v jq >/dev/null 2>&1; then
        c=$(_config_jq -r '.geodata.cron // empty' 2>/dev/null)
    fi
    [ -n "$c" ] && { echo "builtin"; return 0; }
    echo "off"
}

_geo_auto_state() {
    local m
    m=$(_geo_auto_mechanism)
    [ "$m" = "off" ] && echo "off" || echo "on"
}

# routing Geo 判据由统计与精简共用, 避免显示与删除范围漂移。
# 覆盖 domain/domains、ip、sourceIP/source、localIP; 别名同样会加载 dat。
# geosite:/geoip:/ext: 均计入, 先去 ! 因反选仍加载数据; ?/[] 容忍畸形字段。
GEO_RULE_REF_JQ='([(.domain? // [])[]?, (.domains? // [])[]?, (.ip? // [])[]?, (.sourceIP? // [])[]?, (.source? // [])[]?, (.localIP? // [])[]?] | map(select(type=="string")) | map(ltrimstr("!")) | any(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))'

# cron 就绪才可记账为 on: systemd/OpenRC 要同时启动并启用, direct 只启动守护。
_ensure_cron_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || return 1 ;;
        # 按 init.d 存在性选择服务; start 与开机启用缺一不可, 避免重启后状态失真。
        openrc)
            local cron_svc=""
            for cron_svc in crond cronie dcron; do
                if [ -x "/etc/init.d/$cron_svc" ]; then
                    rc-service "$cron_svc" start 2>/dev/null || return 1
                    rc-update add "$cron_svc" default 2>/dev/null || return 1
                    return 0
                fi
            done
            return 1
            ;;
        # direct 用 _proc_any_named 判活, 避免容器内 busybox pgrep 的假阴性。
        direct)
            if command -v crond >/dev/null 2>&1; then
                _proc_any_named crond && return 0
                crond 2>/dev/null || return 1
                return 0
            elif command -v cron >/dev/null 2>&1; then
                _proc_any_named cron && return 0
                cron 2>/dev/null || return 1
                return 0
            fi
            return 1
            ;;
        # 未知 init 必须失败, 否则 case 的隐式成功会让调用方误记 cron 已就绪。
        *) return 1 ;;
    esac
}

# 下载与体积校验在锁外; live dat 提交与恢复由 coretxn 负责。
# 提交持 config → core 锁, 防止核心切换或配置写入覆盖恢复源。
_geo_update() {
    _ensure_dirs || return 1
    # 非交互输出落日志, 避免 cron 邮件噪音; 日志不可写时保留终端诊断。
    if [ ! -t 0 ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        # 先探测重定向, 因非交互 shell 的 exec 重定向失败会直接退出。
        if ( : >> "$GEO_LOG" ) 2>/dev/null; then
            exec >> "$GEO_LOG" 2>&1
        else
            _warn "无法写入日志 $GEO_LOG, 本次输出未落盘"
        fi
    fi
    if ! declare -F _with_core_lock >/dev/null 2>&1; then
        _error "缺少核心互斥锁, 拒绝更新 Geo 数据"
        return 1
    fi
    # 临时目录创建失败即停, 空路径不能作为后续下载/清理目标。
    local tmp
    tmp=$(mktemp -d) || { _error "无法创建 Geo 下载临时目录, 更新中止"; return 1; }
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    _info "[$ts] 开始更新 Geo 数据 (数据源: $(_geo_source_label))..."

    # 两个 dat 成组提交; 任一下载失败由锁内 coretxn 拒绝整组, 保留旧数据。
    # 远端文件名随源变化(geoip-full.dat 等), 落点恒为 $tmp/$f。
    local ok=1 f url t sz
    for f in geosite.dat geoip.dat; do
        url=$(_geo_source_url "${f%%.dat}")
        t="${tmp}/${f}"
        _info "下载 $f <- $url"
        if ! _http_download "$url" "$t" 60; then
            _warn "$f 下载失败, 保留旧文件"
            ok=0
            rm -f "$t"
            continue
        fi
        # 至少 1KB, 避免空文件或错误页面覆盖可用 dat。
        sz=$(stat -c%s "$t" 2>/dev/null || stat -f%z "$t" 2>/dev/null || echo 0)
        if [ "$sz" -lt 1024 ]; then
            _warn "$f 体积异常(${sz}B), 保留旧文件"
            ok=0
            rm -f "$t"
        fi
    done

    local rc=0
    _with_config_lock _with_core_lock _geo_update_commit_locked "$tmp" "$ts" "$ok" || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

# 持 config → core 锁提交 Geo 数据。
_geo_update_commit_locked() {
    local tmp="$1" ts="$2" ok="$3"
    if ! declare -F _xray_core_geo_update_locked >/dev/null 2>&1; then
        _error "缺少 coretxn Geo 提交入口, 拒绝修改 live dat"
        return 1
    fi
    _xray_core_geo_update_locked "$tmp" "$ts" "$ok"
}

_geo_set_auto_update() {
    local action="$1" gd
    case "$action" in
        on)
            if [ ! -f "$ASSET_DIR/geosite.dat" ] || [ ! -f "$ASSET_DIR/geoip.dat" ]; then
                _warn "assets/ 下缺少 geosite.dat 或 geoip.dat, 请先立即更新一次"
                return 1
            fi
            gd=$(_geo_geodata_json) || return 1
            _mutate_config --argjson gd "$gd" '.geodata = $gd' || return 1
            _success "Geo 自动更新已开启 (Xray 内置: $GEO_CRON_EXPR, 热重载)"
            ;;
        off)
            _mutate_config 'del(.geodata)' || return 1
            _success "Geo 自动更新已关闭"
            ;;
        *) return 1 ;;
    esac
}

_geo_next_run_hint() {
    local c=""
    if _config_present && command -v jq >/dev/null 2>&1; then
        c=$(_config_jq -r '.geodata.cron // empty' 2>/dev/null)
    fi
    if [ -n "$c" ]; then
        echo "Xray 内置定时: ${c} (每月 1/4/7/.../31 号 03:00, 热重载)"
        return
    fi
    echo "未开启"
}

# 精简/恢复共用 _config_edit_preflight, 并检查共享常量。
# 缺少共享常量时明确拒绝, 避免 set -u 崩菜单或向 --argjson 传空值。
_route_preflight() {
    _config_edit_preflight "修改路由规则" || return 1
    if [ -z "${XRAY_DEFAULT_ROUTING_RULES_JSON:-}" ] || [ -z "${XRAY_PRIVATE_BLOCK_RULE_JSON:-}" ] \
       || [ -z "${XRAY_PRIVATE_BLOCK_RULE_TAG:-}" ]; then
        _error "缺少默认规则常量, 无法修改路由规则"
        _tip "请在主菜单执行 [检测脚本更新] 完整更新一次后重试"
        return 1
    fi
    return 0
}

# 单次 jq 输出“总数 Geo数 节点数 私网标记数 混合数”, 减少整份配置读取。
# 失败输出 0 0 0 0 0 并返回 1, 菜单必须区分不可读与确实无规则。
_route_rules_stats() {
    if ! _config_present || ! command -v jq >/dev/null 2>&1; then
        printf '0 0 0 0 0'
        return 1
    fi
    local out
    out=$(_config_jq -r "
        [.routing.rules[]?] as \$r
        | [
            (\$r | length),
            ([\$r[] | select(${GEO_RULE_REF_JQ})] | length),
            ([\$r[] | select(.inboundTag? != null)] | length),
            ([\$r[] | select((.ruleTag? // null) == \"${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private}\")] | length),
            ([\$r[] | select(.inboundTag? != null and (${GEO_RULE_REF_JQ}))] | length)
          ] | @tsv" 2>/dev/null) || { printf '0 0 0 0 0'; return 1; }
    [ -n "$out" ] || { printf '0 0 0 0 0'; return 1; }
    # 转空格供菜单 read 拆分, 与上面的单行输出契约一致。
    printf '%s' "$out" | tr '\t' ' '
    return 0
}

# ruleTag 不是防护证明: 内容必须等于默认 CIDR 规则、仅一条且在通用规则之前。
# 手改或移到 catch-all 后仍有标记, 不能据此跳过修复。
_route_private_block_valid() {
    [ -n "${XRAY_PRIVATE_BLOCK_RULE_JSON:-}" ] || return 1
    _config_jq -e --arg tag "${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private}" \
        --argjson expected "$XRAY_PRIVATE_BLOCK_RULE_JSON" '
        ([.routing.rules[]?] ) as $r
        | [range(0; ($r|length)) as $i
           | select(($r[$i].ruleTag? // null) == $tag) | $i] as $marks
        | [range(0; ($r|length)) as $i
           | select($r[$i].inboundTag? == null and (($r[$i].ruleTag? // null) != $tag)) | $i] as $generic
        | if ($marks|length) != 1 then false
          else ($r[$marks[0]] == $expected)
               and (($generic|length) == 0 or $marks[0] < $generic[0])
          end
    ' >/dev/null 2>&1
}

# DNS 的 domains、expectedIPs/expectIPs、unexpectedIPs 与 hosts 键也消费 Geo。
# 默认 DNS 无 Geo 引用; 自定义 DNS 可能仍加载 dat, 精简 routing 后必须告警。
_route_dns_geo_count() {
    if ! _config_present || ! command -v jq >/dev/null 2>&1; then
        printf '0'
        return 1
    fi
    local n
    n=$(_config_jq -r '
        [ (.dns?.servers[]? | select(type == "object")
            | (.domains? // [])[]?, (.expectedIPs? // [])[]?, (.expectIPs? // [])[]?, (.unexpectedIPs? // [])[]?),
           ((.dns?.hosts? // {}) | keys[]?) ]
        | map(select(type == "string")) | map(ltrimstr("!"))
        | map(select(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))
        | length' 2>/dev/null) || { printf '0'; return 1; }
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
    return 0
}

# 删除所有 Geo 规则(含 Geo 节点规则), 保留非 Geo 规则并注入字面量 CIDR 私网 block。
# 私网规则插在首条满足 inboundTag? == null 的规则前, 避免抢先拦截 tunnel Reality 握手。
# 按 ruleTag 去旧再重插以保持幂等; 重建 .routing.rules 避免 routing:null 的 map 报错。
# ruleTag? // null 保留非对象元素; inboundTag? 不补 null, 避免标量被误当插入点。
_route_slim_geo_rules() {
    _route_preflight || return 1
    _mutate_config --argjson priv "$XRAY_PRIVATE_BLOCK_RULE_JSON" \
        ".routing.rules = ([.routing.rules[]?
            | select(${GEO_RULE_REF_JQ} | not)
            | select((.ruleTag? // null) != \"${XRAY_PRIVATE_BLOCK_RULE_TAG}\")] as \$k
          | ([\$k | to_entries[] | select(.value.inboundTag? == null) | .key] | first // (\$k | length)) as \$i
          | \$k[0:\$i] + [\$priv] + \$k[\$i:])" || return 1
    return 0
}

# 保留节点规则并接共享默认规则; 其余自定义规则会丢弃, 菜单须在确认前明示。
# 恢复 IPIfNonMatch 让 geoip:cn 对域名目标生效; inboundTag? 容忍非对象元素。
_route_restore_default_rules() {
    _route_preflight || return 1
    _mutate_config --argjson defs "$XRAY_DEFAULT_ROUTING_RULES_JSON" \
        '.routing.domainStrategy = "IPIfNonMatch"
         | .routing.rules = ([.routing.rules[]? | select(.inboundTag? != null)] + $defs)' || return 1
    return 0
}

# _geo_menu [3] 的低内存子菜单; 精简范围和顺序见 _route_slim_geo_rules。
_route_rules_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【路由规则(小内存优化)】${NC}"
        echo
        local total=0 geo=0 node=0 mark=0 mixed=0 stats_ok=1 private_ok=0
        local stats; stats=$(_route_rules_stats) || stats_ok=0
        # 失败时不 read 空结果, 避免把已初始化数字覆盖为空并触发算术诊断。
        [ "$stats_ok" -eq 1 ] && read -r total geo node mark mixed <<< "$stats"
        _route_private_block_valid && private_ok=1
        if [ "$stats_ok" -ne 1 ]; then
            _warn "无法读取当前路由规则(Xray 未安装 / 配置缺失 / jq 不可用)"
        else
            echo -e "  规则总数:   ${CYAN}${total}${NC}"
            if [ "$geo" -gt 0 ]; then
                echo -e "  引用 geo:   ${YELLOW}${geo}${NC} 条 (会加载 geosite.dat / geoip.dat)"
            else
                echo -e "  引用 geo:   ${GREEN}0${NC} 条 (不加载 dat)"
            fi
            echo -e "  节点规则:   ${CYAN}${node}${NC} 条 (tunnel 模式 Reality 的防偷跑规则)"
            if [ "$mixed" -gt 0 ]; then
                _warn "其中 ${mixed} 条节点定向规则也引用 Geo; 精简时会一并删除以停止 dat 加载"
            fi
            if [ "$private_ok" -eq 1 ]; then
                echo -e "  私网防护:   ${GREEN}已注入字面量 CIDR${NC} (${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private})"
            elif [ "$mark" -gt 0 ]; then
                echo -e "  私网防护:   ${RED}规则标记存在但内容、唯一性或顺序无效${NC}"
            else
                echo -e "  私网防护:   ${CYAN}未注入${NC}"
            fi
            local dnsgeo; dnsgeo=$(_route_dns_geo_count)
            if [ "$dnsgeo" -gt 0 ]; then
                echo
                _warn "dns 段还有 ${dnsgeo} 处 geo 引用, 精简路由规则不足以完全免除 dat 加载"
                _tip "如需彻底省内存, 请手工编辑 ${CONFIG_DIR}/04_dns.json 去掉 geosite:/geoip:/ext: 引用"
            fi
        fi
        echo
        echo -e "  ${YELLOW}小内存 VPS 上 geosite.dat + geoip.dat 各约 20MB+, 是 xray 被 OOM 杀掉的主因${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 精简规则(去掉 geo 引用, 保留节点规则与私网防护)"
        echo -e "  ${GREEN}[2]${NC} 恢复默认规则(重新引用 geo 数据)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            0) return ;;
            1)
                _route_preflight || { _press_any_key; continue; }
                # 完整防护有效才跳过重启, 单有 ruleTag 不够; 见 _route_private_block_valid。
                # stats 读取失败时 geo/node/mixed 仍是初值 0: 既不能判"已是精简", 也不能拿 0 去确认删除。
                if [ "$stats_ok" -ne 1 ]; then
                    _warn "无法读取当前路由规则, 无法判断精简范围, 已取消"
                    _press_any_key; continue
                fi
                if [ "$geo" -eq 0 ] && [ "$private_ok" -eq 1 ]; then
                    _info "已是精简状态(无 geo 引用 + 私网防护已注入), 无需重复操作"
                    _press_any_key; continue
                fi
                echo
                echo -e "  将执行:"
                echo -e "    ${CYAN}删除${NC} ${geo} 条引用 geo 数据的规则"
                echo -e "    ${CYAN}注入${NC} 1 条字面量 CIDR 私网 block 规则(等价 geoip:private, 不加载 dat)"
                echo -e "    ${CYAN}保留${NC} $((node - mixed)) 条不引用 Geo 的节点定向规则(仍在最前) + 其它非 Geo 规则"
                [ "$mixed" -gt 0 ] && echo -e "    ${YELLOW}注意${NC} ${mixed} 条同时引用 Geo 的节点定向规则会删除"
                read -rp "  确认精简? [y/N]: " ans
                case "$ans" in
                    y|Y) ;;
                    *) _info "已取消"; _press_any_key; continue ;;
                esac
                if _route_slim_geo_rules; then
                    _success "路由规则已精简, xray 已用新配置重启"
                    _tip "geosite.dat / geoip.dat 不再被加载, 内存占用应明显下降"
                    local gstate; gstate=$(_geo_auto_state 2>/dev/null)
                    if [ "$gstate" = "on" ]; then
                        _tip "当前 Geo 自动更新仍为开启; 已无 geo 规则时它没有实际意义, 可在上一级 [2] 关闭"
                    fi
                else
                    _error "精简失败(配置已回滚)"
                fi
                _press_any_key
                ;;
            2)
                _route_preflight || { _press_any_key; continue; }
                echo
                echo -e "  ${YELLOW}恢复后将重新引用 geosite/geoip 数据, 小内存机器可能再次被 OOM${NC}"
                echo -e "  ${YELLOW}注意: 手工添加的非节点自定义规则会被丢弃(节点规则保留; 配置已自动备份)${NC}"
                read -rp "  确认恢复默认规则? [y/N]: " ans
                case "$ans" in
                    y|Y) ;;
                    *) _info "已取消"; _press_any_key; continue ;;
                esac
                if _route_restore_default_rules; then
                    _success "已恢复默认路由规则(bittorrent / 广告+私网域名 / 私网+CN IP / 域名白名单直连)"
                    _tip "请确认 assets 下 geosite.dat 与 geoip.dat 存在, 否则可在上一级 [1] 立即更新一次"
                else
                    _error "恢复失败(配置已回滚)"
                fi
                _press_any_key
                ;;
            *)
                _warn "无效选择"
                _press_any_key
                ;;
        esac
    done
}

# 切换数据源: 内置定时生效时先改 config(verified restart 后立即生效), 再记 state。
# state 是数据源真相源; 任一步 state 写入失败都回滚本次 config/state, 不报告成功。
_geo_source_state_restore() {
    local source_had="$1" source="$2" geosite_had="$3" geosite="$4" geoip_had="$5" geoip="$6"
    local rc=0
    if [ "$source_had" -eq 1 ]; then
        _state_set geo_source "$source" || rc=1
    else
        rm -f "$STATE_DIR/geo_source" 2>/dev/null || rc=1
    fi
    if [ "$geosite_had" -eq 1 ]; then
        _state_set geo_geosite_url "$geosite" || rc=1
    else
        rm -f "$STATE_DIR/geo_geosite_url" 2>/dev/null || rc=1
    fi
    if [ "$geoip_had" -eq 1 ]; then
        _state_set geo_geoip_url "$geoip" || rc=1
    else
        rm -f "$STATE_DIR/geo_geoip_url" 2>/dev/null || rc=1
    fi
    return "$rc"
}

_geo_apply_source() {
    _with_config_lock _with_config_write_barrier _geo_apply_source_locked "$@"
}

_geo_apply_source_locked() {
    local src="$1" cgs="${2:-}" cgi="${3:-}" assets="" mech
    local source_had=0 old_source="" geosite_had=0 old_geosite="" geoip_had=0 old_geoip=""
    local state_ok=1
    case "$src" in
        xtls|loyal|custom) ;;
        *) _error "未知数据源: $src"; return 1 ;;
    esac
    if [ "$src" = "custom" ]; then
        _geo_url_valid "$cgs" || { _error "geosite 链接无效"; return 1; }
        _geo_url_valid "$cgi" || { _error "geoip 链接无效"; return 1; }
    fi
    # 先读取旧 state；读不到就不能安全回滚，不能继续改 config。
    if [ -e "$STATE_DIR/geo_source" ]; then
        source_had=1
        old_source=$(_state_get geo_source 2>/dev/null) || {
            _error "读取旧 geo_source 状态失败, 已取消数据源切换"
            return 1
        }
    fi
    if [ -e "$STATE_DIR/geo_geosite_url" ]; then
        geosite_had=1
        old_geosite=$(_state_get geo_geosite_url 2>/dev/null) || {
            _error "读取旧 geo_geosite_url 状态失败, 已取消数据源切换"
            return 1
        }
    fi
    if [ -e "$STATE_DIR/geo_geoip_url" ]; then
        geoip_had=1
        old_geoip=$(_state_get geo_geoip_url 2>/dev/null) || {
            _error "读取旧 geo_geoip_url 状态失败, 已取消数据源切换"
            return 1
        }
    fi
    mech=$(_geo_auto_mechanism)
    if [ "$mech" = "builtin" ]; then
        assets=$(_geo_assets_json "$src" "$cgs" "$cgi") || { _error "生成 assets 失败"; return 1; }
        if ! _mutate_config --argjson a "$assets" '.geodata.assets = $a'; then
            _error "写入 geodata.assets 失败(配置已回滚), 数据源未变更"
            return 1
        fi
    fi
    _state_set geo_source "$src" || state_ok=0
    if [ "$src" = "custom" ]; then
        _state_set geo_geosite_url "$cgs" || state_ok=0
        _state_set geo_geoip_url "$cgi" || state_ok=0
    else
        rm -f "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url" 2>/dev/null || state_ok=0
    fi
    if [ "$state_ok" -ne 1 ]; then
        local rollback_ok=1
        if [ "$mech" = "builtin" ]; then
            if ! _restore_config; then
                _error "状态写入失败后, config 回滚失败; 请手动核对 $CONFIG_DIR"
                rollback_ok=0
            elif ! _restart_xray_verified; then
                _error "状态写入失败后, config 已回滚但 Xray 未能稳定运行"
                rollback_ok=0
            fi
        fi
        if ! _geo_source_state_restore "$source_had" "$old_source" "$geosite_had" "$old_geosite" "$geoip_had" "$old_geoip"; then
            _error "状态写入失败且旧 state 未能完整恢复; 请手动核对 $STATE_DIR"
            rollback_ok=0
        fi
        [ "$rollback_ok" -eq 1 ] && _error "数据源状态写入失败, 数据源未变更"
        return 1
    fi
    _success "数据源已切换: $(_geo_source_label)"
    _info "geosite: $(_geo_source_url geosite)"
    _info "geoip:   $(_geo_source_url geoip)"
    # 只换链接不动已落地的 dat: 必须提示再触发一次下载才会真正换源。
    _info "本次只切换下载链接与 state, 本地 dat 仍是旧源数据; 按 [1] 立即更新即可马上换源"
    return 0
}

# 必答字段: 空值或非 https 重问该字段, EOF 取消。
_geo_prompt_url() {
    local label="$1" val=""
    while :; do
        read -rp "  $label: " val || return 1
        if _geo_url_valid "$val"; then
            printf '%s' "$val"
            return 0
        fi
        _warn "请输入 https:// 开头的完整链接(不能含空格)"
    done
}

_geo_set_source() {
    local src="" gs="" gi="" choice=""
    while :; do
        clear
        echo
        echo -e "  ${CYAN}【切换 Geo 数据源】${NC}"
        echo -e "  当前: $(_geo_source_label)"
        echo
        echo -e "  ${GREEN}[1]${NC} XTLS/Xray-rules-dat (官方, 默认)"
        echo -e "  ${GREEN}[2]${NC} Loyalsoldier/v2ray-rules-dat (完整版)"
        echo -e "  ${GREEN}[3]${NC} 自定义 geosite / geoip 链接"
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            1) src="xtls"; break ;;
            2) src="loyal"; break ;;
            3)
                gs=$(_geo_prompt_url "geosite 链接") || return 0
                gi=$(_geo_prompt_url "geoip 链接") || return 0
                src="custom"; break
                ;;
            0) return 0 ;;
            *) _warn "无效"; _press_any_key ;;
        esac
    done
    _geo_apply_source "$src" "$gs" "$gi" || { _press_any_key; return 1; }
    _press_any_key
    return 0
}

# ---------------------------------------------------------------------------
# 自定义 geodata: state/geo_extra_assets 每行 "file<TAB>url" 是唯一真相,
# config 的 .geodata.assets 是派生(两个内置项 + 所有 extras)。
# Xray 要求 assets.file 是资源目录内已存在的普通文件, 所以先下载再写 config。
# ---------------------------------------------------------------------------
_geo_extra_path() {
    printf '%s' "$STATE_DIR/geo_extra_assets"
}

# extras 数组 JSON; 文件不存在或空行视为没有 extras。
_geo_extra_assets_json() {
    local path=""
    path=$(_geo_extra_path)
    if [ ! -f "$path" ]; then
        printf '[]'
        return 0
    fi
    awk -F'\t' 'NF >= 2 && $1 != "" { printf "%s\t%s\n", $1, $2 }' "$path" \
        | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {url: .[1], file: .[0]})'
}

_geo_extra_exists() {
    local target="$1" name="" url=""
    [ -f "$(_geo_extra_path)" ] || return 1
    while IFS=$'\t' read -r name url; do
        [ "$name" = "$target" ] && return 0
    done < "$(_geo_extra_path)"
    return 1
}

# 核心 >= v26.10.29(app/geodata New)要求 assets.file 以 .dat 结尾(EqualFold), 否则拒绝启动。
_geo_extra_name_has_dat() {
    case "${1:-}" in
        *.[dD][aA][tT]) return 0 ;;
        *) return 1 ;;
    esac
}

# 文件名只允许 [A-Za-z0-9._-], 以 .dat 结尾; 不能是 . 或含 .., 不能占用内置两项, 不能与已有条目重名。
_geo_extra_file_valid() {
    local f="${1:-}"
    case "$f" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    case "$f" in
        geosite.dat|geoip.dat) return 1 ;;
        .|*..*) return 1 ;;
    esac
    _geo_extra_name_has_dat "$f" || return 1
    ! _geo_extra_exists "$f"
}

# 默认文件名取链接最后一段, 去掉 ?query 与 #fragment。
_geo_url_basename() {
    local u="$1"
    u="${u%%#*}"
    u="${u%%\?*}"
    printf '%s' "${u##*/}"
}

# 核心只解压自身下载的 .gz; 本管理器按原样落地, 压缩内容会以 .dat 名存成坏数据, 故拒绝。
_geo_extra_url_gz() {
    case "$(_geo_url_basename "${1:-}")" in
        *.[gG][zZ]) return 0 ;;
        *) return 1 ;;
    esac
}

# 重写 state 去掉指定 file 的行; 任一步失败都保留原文件。
_geo_extra_remove_line() {
    local target="$1" path="" tmp=""
    path=$(_geo_extra_path)
    [ -f "$path" ] || return 0
    tmp=$(mktemp "$STATE_DIR/geo_extra_assets.tmp.XXXXXX") || return 1
    if ! awk -F'\t' -v f="$target" '$1 != f' "$path" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# 添加: 先下载落盘(Xray 只认已存在的普通文件), builtin 机制下再写 config, 最后记 state。
# 下载或体积失败时不改 config/state, 同目录 mv 保证资源目录里不留半成品。
_geo_extra_add() {
    local url="" file="" default_name="" tmp="" sz=0 assets=""
    echo
    url=$(_geo_prompt_url "geodata 链接") || return 0
    if _geo_extra_url_gz "$url"; then
        _error "不支持 .gz 链接: 请填未压缩的 .dat 链接(核心只解压自身下载的 .gz, 本管理器按原样落地)"
        return 1
    fi
    default_name=$(_geo_url_basename "$url")
    while :; do
        read -rp "  文件名(直接回车用 ${default_name:-链接末段}): " file || return 0
        [ -n "$file" ] || file="$default_name"
        _geo_extra_file_valid "$file" && break
        if [ -z "$file" ]; then
            _warn "无法从链接推断文件名, 请手动输入"
        elif [ "$file" = "geosite.dat" ] || [ "$file" = "geoip.dat" ]; then
            _warn "geosite.dat / geoip.dat 是内置数据文件, 请换一个文件名"
        elif ! _geo_extra_name_has_dat "$file"; then
            _warn "文件名必须以 .dat 结尾(Xray >= v26.10.29 强制要求, 否则核心拒绝启动)"
        elif _geo_extra_exists "$file"; then
            _warn "文件名已存在: $file (如需替换, 请先在 [2] 删除该条目)"
        else
            _warn "文件名只能包含字母/数字/./_/-, 且不能是 . 或含 / 或 .."
        fi
        file=""
    done
    mkdir -p "$ASSET_DIR" 2>/dev/null || { _error "无法创建资源目录 $ASSET_DIR"; return 1; }
    tmp=$(mktemp "$ASSET_DIR/.geo-extra.XXXXXX") || { _error "无法创建下载临时文件"; return 1; }
    _info "下载 $file <- $url"
    if ! _http_download "$url" "$tmp" 60; then
        rm -f "$tmp"
        _error "下载失败, 已取消(未改动 config/state)"
        return 1
    fi
    # 至少 1KB: 挡住错误页面与空响应, 避免把非 geodata 内容写进 assets。
    sz=$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -lt 1024 ] 2>/dev/null; then
        rm -f "$tmp"
        _error "下载内容体积异常(${sz}B), 已取消(未改动 config/state)"
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null || { rm -f "$tmp"; _error "无法设置 $file 的文件权限"; return 1; }
    if ! _with_core_lock mv -f "$tmp" "$ASSET_DIR/$file"; then
        rm -f "$tmp"
        _error "写入 $ASSET_DIR/$file 失败, 已取消"
        return 1
    fi
    if [ "$(_geo_auto_mechanism)" = "builtin" ]; then
        if ! assets=$(_geo_assets_json "$(_geo_source_name)"); then
            rm -f "$ASSET_DIR/$file"
            _error "生成 assets 失败, 已删除刚下载的文件"
            return 1
        fi
        if ! assets=$(printf '%s' "$assets" | jq --arg f "$file" --arg u "$url" '. + [{url: $u, file: $f}]'); then
            rm -f "$ASSET_DIR/$file"
            _error "生成 assets 失败, 已删除刚下载的文件"
            return 1
        fi
        if ! _mutate_config --argjson a "$assets" '.geodata.assets = $a'; then
            rm -f "$ASSET_DIR/$file"
            _error "写入 geodata.assets 失败(配置已回滚), 已删除刚下载的文件"
            return 1
        fi
    fi
    if ! printf '%s\t%s\n' "$file" "$url" >> "$(_geo_extra_path)"; then
        _warn "文件已下载, 但 state 记录写入失败; 请手工补记或删除 $ASSET_DIR/$file"
        return 1
    fi
    _success "已添加自定义 geodata: $file <- $url"
    return 0
}

# 删除: builtin 机制下先重写 config(失败即中止, state 不动), 再删 state 行与本地文件。
# state 记录的文件名是 . 或含 / 或 .. 时中止, 避免 rm 落到资源目录本身或之外。
_geo_extra_delete() {
    local path="" count=0 i=0 sel="" target="" name="" url="" assets="" mech=""
    path=$(_geo_extra_path)
    if [ ! -s "$path" ]; then
        _warn "还没有自定义 geodata 条目"
        return 0
    fi
    echo
    while IFS=$'\t' read -r name url; do
        [ -n "$name" ] || continue
        count=$((count + 1))
        echo -e "    ${CYAN}[$count]${NC} $name <- $url"
    done < "$path"
    echo
    read -rp "  请选择要删除的编号(0 取消): " sel || return 0
    case "$sel" in
        ''|0) return 0 ;;
        *[!0-9]*) _warn "无效编号"; return 1 ;;
    esac
    # 编号归一交给 _xd_index_from_choice: 去前导零并限长, 防超长数字在 10# 算术里回绕;
    # 它返回零基下标并拒绝 0, 这里 +1 还原菜单的 1 基编号。
    sel=$(_xd_index_from_choice "$sel" "$count") || { _warn "无效编号"; return 1; }
    sel=$((sel + 1))
    while IFS=$'\t' read -r name url; do
        [ -n "$name" ] || continue
        i=$((i + 1))
        [ "$i" -eq "$sel" ] && target="$name"
    done < "$path"
    if [ -z "$target" ]; then
        _warn "无效编号"
        return 1
    fi
    case "$target" in
        */*|*..*|.)
            _error "state 记录的文件名异常($target), 已中止; 请手工检查 $path"
            return 1
            ;;
    esac
    mech=$(_geo_auto_mechanism)
    if [ "$mech" = "builtin" ]; then
        if ! assets=$(_geo_assets_json "$(_geo_source_name)"); then
            _error "生成 assets 失败, 未删除"
            return 1
        fi
        if ! assets=$(printf '%s' "$assets" | jq --arg f "$target" '[.[] | select(.file != $f)]'); then
            _error "生成 assets 失败, 未删除"
            return 1
        fi
        if ! _mutate_config --argjson a "$assets" '.geodata.assets = $a'; then
            _error "写入 geodata.assets 失败(配置已回滚), 未删除"
            return 1
        fi
    fi
    if ! _geo_extra_remove_line "$target"; then
        if [ "$mech" = "builtin" ]; then
            _error "配置已移除 $target, 但 state 记录删除失败; 本地文件仍在, 请手工删除 $path 中对应那一行"
        else
            _error "state 记录删除失败, 配置与本地文件均未改动; 请手工删除 $path 中对应那一行"
        fi
        return 1
    fi
    if ! _with_core_lock rm -f "$ASSET_DIR/$target"; then
        _warn "本地文件删除失败: $ASSET_DIR/$target"
    fi
    _success "已删除自定义 geodata: $target"
    return 0
}

# 子菜单: 先列已有条目; 非内置定时机制要说明这些文件不随定时更新。
_geo_extra_menu() {
    local choice="" mech="" path="" n=0 name="" url=""
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【自定义 geodata】${NC}"
        mech=$(_geo_auto_mechanism)
        path=$(_geo_extra_path)
        n=0
        if [ -s "$path" ]; then
            echo -e "  已有条目:"
            while IFS=$'\t' read -r name url; do
                [ -n "$name" ] || continue
                n=$((n + 1))
                echo -e "    ${CYAN}[$n]${NC} $name <- $url"
            done < "$path"
        else
            echo -e "  已有条目: ${YELLOW}无${NC}"
        fi
        echo
        if [ "$mech" = "builtin" ]; then
            echo -e "  这些文件写在 .geodata.assets, 由 Xray 内置定时下载"
        else
            echo -e "  ${YELLOW}内置 Geo 自动更新关闭时, 这些文件只在添加时下载一次, 不会随定时更新${NC}"
        fi
        echo -e "  落点: $ASSET_DIR"
        echo
        echo -e "  ${GREEN}[1]${NC} 添加"
        echo -e "  ${GREEN}[2]${NC} 删除"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            1) _geo_extra_add ;;
            2) _geo_extra_delete ;;
            0) return ;;
            *) _warn "无效选择" ;;
        esac
        _press_any_key
    done
}

# Geo 菜单复用 _geo_auto_mechanism, 按当前 geodata 配置判断内置更新。
_geo_menu() {
    clear
    echo
    echo -e "  ${CYAN}【Geo 数据自动更新】${NC}"
    local state; state=$(_geo_auto_state)
    local choice=""
    if [ "$state" = "on" ]; then
        echo -e "  当前状态: ${GREEN}● 已开启${NC}"
        echo -e "  下次执行: $(_geo_next_run_hint)"
        echo -e "  更新机制: ${GREEN}Xray 内置定时(热重载)${NC}"
    else
        echo -e "  当前状态: ${RED}○ 已关闭${NC}"
    fi
    echo -e "  数据源: $(_geo_source_label)"
    echo -e "    geosite: $(_geo_source_url geosite)"
    echo -e "    geoip:   $(_geo_source_url geoip)"
    if _geo_builtin_source_drifted; then
        echo -e "  ${YELLOW}注: 内置定时的下载链接仍是旧数据源, 进 [4] 重新应用一次即可同步(会重启核心)${NC}"
    fi
    echo -e "  落点: $ASSET_DIR (config env 的 XRAY_LOCATION_ASSET)"
    echo
    echo -e "  ${GREEN}[1]${NC} 立即更新一次"
    if [ "$state" = "on" ]; then
        echo -e "  ${GREEN}[2]${NC} 关闭自动更新"
    else
        echo -e "  ${GREEN}[2]${NC} 开启自动更新(定期)"
    fi
    echo -e "  ${GREEN}[3]${NC} 路由规则(小内存优化: 精简 geo 引用)"
    echo -e "  ${GREEN}[4]${NC} 切换数据源"
    echo -e "  ${GREEN}[5]${NC} 自定义 geodata(添加/删除)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice || return 0
    case "${choice:-0}" in
        1) _geo_update ;;
        2) if [ "$state" = "on" ]; then _geo_set_auto_update off; else _geo_set_auto_update on; fi ;;
        3) _route_rules_menu; return ;;
        4) _geo_set_source; return ;;
        5) _geo_extra_menu; return ;;
        0) return ;;
        *) _warn "无效" ;;
    esac
    _press_any_key
}

# DNS 设置仅修改 .dns; 写入走 _mutate_config 的重启与回滚。
# 默认 DNS 取 XRAY_DEFAULT_DNS_JSON: https+local:// 是直连 DoH(directDOH), 绕过路由。
# 菜单新选 https:// 是 routedDoH, UDP/IP 上游也经 Xray 路由; 不能据默认出站承诺直连。
# 用户设置保存普通字符串, 不添加 tag, 保持 confs/04_dns.json 可读。

# 将用户输入拆成独立上游; 空白项丢弃, 其它内容原样保留。
_dns_split_servers() {
    local input="$1" item
    DNS_SERVER_VALUES=()
    local -a parts=()
    IFS=',' read -r -a parts <<< "$input"
    for item in "${parts[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [ -n "$item" ] && DNS_SERVER_VALUES+=("$item")
    done
    [ "${#DNS_SERVER_VALUES[@]}" -gt 0 ]
}

# 摘要输出“上游列表|解析策略”; 不可读时返回 1 和空摘要, 不虚构默认值。
_dns_summary() {
    if ! _config_present || ! command -v jq >/dev/null 2>&1; then
        printf '|'
        return 1
    fi
    local out
    out=$(_config_jq -r '
        (.dns | if type == "object" then . else {} end) as $d
        | [($d.servers // [])[]?
           | if type == "string" then .
             elif type == "object" and has("address") then .address
             else empty end] as $s
        | [($s | join(", ")), ($d.queryStrategy // "")] | @tsv' 2>/dev/null)
    [ -n "$out" ] || { printf '|'; return 1; }
    printf '%s' "$out" | tr '\t' '|'
}

# 参数同 _config_jq(filter 最后)。
_dns_apply() {
    [ "$#" -ge 1 ] || return 1
    _config_edit_preflight "修改 DNS 配置" || return 1
    _mutate_config "$@" || { _error "写入 DNS 配置失败"; return 1; }
}

_dns_view() {
    clear
    echo
    echo -e "  ${CYAN}【DNS 配置】${NC}"
    echo -e "  字段 dns, 文件 ${CONFIG_DIR}/04_dns.json"
    echo
    if ! _config_present; then
        _warn "配置不存在"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _warn "jq 不可用, 无法查看"
        return 0
    fi
    _config_jq '.dns // null' 2>/dev/null || _warn "读取 DNS 配置失败"
    return 0
}

_dns_set_servers() {
    _config_edit_preflight "修改 DNS 配置" || return 1
    echo
    echo -e "  ${CYAN}选择上游 DNS 服务器${NC}"
    echo -e "  当前上游: $(_dns_summary | cut -d'|' -f1)"
    echo
    echo -e "  ${GREEN}[1]${NC} 1.1.1.1 (Cloudflare)"
    echo -e "  ${GREEN}[2]${NC} 8.8.8.8 (Google)"
    echo -e "  ${GREEN}[3]${NC} https+local://cloudflare-dns.com/dns-query (Cloudflare DoH 本地模式)"
    echo -e "  ${GREEN}[4]${NC} https+local://dns.google/dns-query (Google DoH 本地模式)"
    echo -e "  ${GREEN}[5]${NC} 手动输入"
    echo -e "  ${GREEN}[0]${NC} 取消"
    local c addr="" local_mode="" manual=0
    read -rp "  请选择: " c || return 0
    case "${c:-0}" in
        1) addr="1.1.1.1" ;;
        2) addr="8.8.8.8" ;;
        3) addr="https+local://cloudflare-dns.com/dns-query" ;;
        4) addr="https+local://dns.google/dns-query" ;;
        5) manual=1; read -rp "  请输入 DNS 地址(可用逗号分隔多个服务器): " addr || return 0 ;;
        0) return 0 ;;
        *) _warn "无效选择"; return 1 ;;
    esac
    _dns_split_servers "$addr" || { _warn "地址为空, 已取消"; return 1; }
    local -a json_servers=() item
    for item in "${DNS_SERVER_VALUES[@]}"; do
        if [ "$manual" -eq 1 ]; then
            case "$item" in
                https://*)
                    read -rp "  检测到 DoH 地址 $item, 是否使用本地模式(https+local://)? [y/N]: " local_mode || return 0
                    case "$local_mode" in
                        y|Y) item="https+local://${item#https://}" ;;
                    esac
                    ;;
                tcp://*)
                    read -rp "  检测到 DNS over TCP 地址 $item, 是否使用本地模式(tcp+local://)? [y/N]: " local_mode || return 0
                    case "$local_mode" in
                        y|Y) item="tcp+local://${item#tcp://}" ;;
                    esac
                    ;;
                quic://*)
                    read -rp "  检测到 DNS over QUIC 地址 $item, 是否使用本地模式(quic+local://)? [y/N]: " local_mode || return 0
                    case "$local_mode" in
                        y|Y) item="quic+local://${item#quic://}" ;;
                    esac
                    ;;
            esac
            local_mode=""
        fi
        json_servers+=("$item")
    done
    local servers_json
    servers_json=$(printf '%s\n' "${json_servers[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') || {
        _error "生成 DNS 上游失败, 已取消"; return 1
    }
    _dns_apply --argjson s "$servers_json" '.dns = ((.dns | if type == "object" then . else {} end) + {servers: $s})' || return 1
    _success "DNS 上游已更新为: $(IFS=', '; printf '%s' "${json_servers[*]}")"
}

_dns_set_parallel() {
    _config_edit_preflight "修改 DNS 配置" || return 1
    echo
    echo -e "  ${CYAN}设置并行查询 enableParallelQuery${NC}"
    local current c value
    current=$(_config_jq -r '.dns.enableParallelQuery // false' 2>/dev/null) || current=false
    echo -e "  当前状态: $current"
    echo -e "  ${GREEN}[1]${NC} 开启"
    echo -e "  ${GREEN}[2]${NC} 关闭"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  请选择: " c || return 0
    case "${c:-0}" in
        1) value=true ;;
        2) value=false ;;
        0) return 0 ;;
        *) _warn "无效选择"; return 1 ;;
    esac
    _dns_apply --argjson v "$value" '.dns = ((.dns | if type == "object" then . else {} end) + {enableParallelQuery: $v})' || return 1
    if [ "$value" = true ]; then
        _success "并行查询已开启"
    else
        _success "并行查询已关闭"
    fi
}

_dns_set_strategy() {
    _config_edit_preflight "修改 DNS 配置" || return 1
    echo
    echo -e "  ${CYAN}选择解析策略 queryStrategy${NC}"
    echo -e "  当前策略: $(_dns_summary | cut -d'|' -f2)"
    echo
    echo -e "  ${GREEN}[1]${NC} UseIP   (IPv4 + IPv6, 默认)"
    echo -e "  ${GREEN}[2]${NC} UseIPv4 (只解析 IPv4)"
    echo -e "  ${GREEN}[3]${NC} UseIPv6 (只解析 IPv6)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    local c s=""
    read -rp "  请选择: " c || return 0
    case "${c:-0}" in
        1) s="UseIP" ;;
        2) s="UseIPv4" ;;
        3) s="UseIPv6" ;;
        0) return 0 ;;
        *) _warn "无效选择"; return 1 ;;
    esac
    _dns_apply --arg s "$s" '.dns = ((.dns | if type == "object" then . else {} end) + {queryStrategy: $s})' || return 1
    _success "解析策略已更新为: $s"
}

_dns_restore_default() {
    _config_edit_preflight "修改 DNS 配置" || return 1
    if [ -z "${XRAY_DEFAULT_DNS_JSON:-}" ]; then
        _error "缺少默认 DNS 常量, 无法恢复默认"
        _tip "请先在主菜单执行 [检测脚本更新] 完整更新一次后重试"
        return 1
    fi
    local ans
    read -rp "  确认恢复默认 DNS(三个 https+local:// DoH 上游)? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; return 0 ;;
    esac
    _dns_apply --argjson d "$XRAY_DEFAULT_DNS_JSON" '.dns = $d' || return 1
    _success "已恢复默认 DNS"
}

_dns_delete() {
    _config_edit_preflight "修改 DNS 配置" || return 1
    local ans
    read -rp "  确认删除 DNS 配置(改用系统默认 DNS)? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; return 0 ;;
    esac
    _dns_apply 'del(.dns)' || return 1
    _success "已删除 DNS 配置(改用系统默认 DNS)"
}

_dns_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【DNS 设置】${NC}"
        local summary servers strategy
        summary=$(_dns_summary)
        servers="${summary%%|*}"
        strategy="${summary##*|}"
        if _config_present && command -v jq >/dev/null 2>&1 && _config_jq -e 'has("dns")' >/dev/null 2>&1; then
            echo -e "  配置状态: ${GREEN}已配置${NC} (${CONFIG_DIR}/04_dns.json)"
        else
            echo -e "  配置状态: ${YELLOW}未配置(用系统默认 DNS)${NC}"
        fi
        echo -e "  当前上游: ${servers:-未设置}"
        echo -e "  解析策略: ${strategy:-未设置}"
        echo
        echo -e "  ${GREEN}[1]${NC} 设置上游 DNS 服务器"
        echo -e "  ${GREEN}[2]${NC} 设置解析策略"
        echo -e "  ${GREEN}[3]${NC} 恢复默认 DNS"
        echo -e "  ${GREEN}[4]${NC} 删除 DNS 配置"
        echo -e "  ${GREEN}[5]${NC} 设置并行查询"
        echo -e "  ${GREEN}[6]${NC} 查看完整 DNS 配置"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            1) _dns_set_servers ;;
            2) _dns_set_strategy ;;
            3) _dns_restore_default ;;
            4) _dns_delete ;;
            5) _dns_set_parallel ;;
            6) _dns_view ;;
            0) return ;;
            *) _warn "无效选择" ;;
        esac
        _press_any_key
    done
}

