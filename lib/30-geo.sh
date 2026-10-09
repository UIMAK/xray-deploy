#!/bin/bash
# lib/30-geo.sh — Geo 更新、路由精简与 DNS 设置。
# Geo 自动更新默认 OFF; ≥ v26.4.25 用内置 geodata, 旧核心用系统 cron。
# 数据源 Loyalsoldier/v2ray-rules-dat, 落点 $ASSET_DIR; 下载失败保留旧 dat。
# 内置 assets.file 必须预先存在, 否则核心拒绝启动; 见 _geo_set_auto_update。
# DNS 写入走 _mutate_config 的重启与回滚; 见 _dns_apply。

GEO_CRON_MARKER="# xray-deploy-geo-update"
GEO_TRANSITION_KEY="geo_update_transition"
# day-of-month 的 */3 是每月 1/4/7/.../31 号, 跨月不保证每隔三天。
GEO_CRON_EXPR="0 3 */3 * *"

_geo_transition_get() {
    _state_get "$GEO_TRANSITION_KEY" 2>/dev/null
}

_geo_transition_clear() {
    rm -f "$STATE_DIR/$GEO_TRANSITION_KEY" 2>/dev/null
    if [ -e "$STATE_DIR/$GEO_TRANSITION_KEY" ]; then
        _warn "Geo 关闭待清理标记无法删除: $STATE_DIR/$GEO_TRANSITION_KEY"
        return 1
    fi
    return 0
}

# 生成 geodata JSON: cron 五字段、assets URL 必须 HTTPS; 供 --argjson 使用。
# 省略 outbound 时下载遵循 Xray 路由, 不等于固定直连。
_geo_geodata_json() {
    jq -n \
        --arg cron "$GEO_CRON_EXPR" \
        --arg u1 "$GEO_BASE/geosite.dat" \
        --arg u2 "$GEO_BASE/geoip.dat" \
        '{cron: $cron, assets: [ {url: $u1, file: "geosite.dat"}, {url: $u2, file: "geoip.dat"} ]}'
}

# 状态唯一查询点: 非空 .geodata.cron 优先, 否则读 legacy geo_cron。
# 输出 builtin|cron|off, _geo_auto_state 映射为 on|off, 避免各菜单自行猜状态。
_geo_auto_mechanism() {
    local c=""
    if _config_present && command -v jq >/dev/null 2>&1; then
        c=$(_config_jq -r '.geodata.cron // empty' 2>/dev/null)
    fi
    [ -n "$c" ] && { echo "builtin"; return 0; }
    [ "$(_state_get geo_cron 2>/dev/null)" = "on" ] && { echo "cron"; return 0; }
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
# 提交和旧 cron 清理持 config → core 锁, 防止核心切换或配置写入覆盖恢复源。
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
    # off_pending 优先完成关闭, 防止残留 cron 在明确关闭意图下继续更新 dat。
    if [ "$(_geo_transition_get)" = "off_pending" ]; then
        _info "检测到 Geo 关闭操作待收敛, 本次跳过数据更新"
        _auto_migrate_geo_autoupdate || return 1
        return 0
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
    _info "[$ts] 开始更新 Geo 数据..."

    # 两个 dat 成组提交; 任一下载失败由锁内 coretxn 拒绝整组, 保留旧数据。
    local ok=1 f url t sz
    for f in geosite.dat geoip.dat; do
        url="$GEO_BASE/$f"
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
    _with_config_lock _with_core_lock _geo_update_commit_and_finalize_locked "$tmp" "$ts" "$ok" || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

# 持 config → core 锁完成提交和兜底清理; 同次 runtime 收敛才证明可以移除旧 cron。
_geo_update_commit_and_finalize_locked() {
    local tmp="$1" ts="$2" ok="$3"
    _geo_update_commit_locked "$tmp" "$ts" "$ok" || return $?
    _geo_finalize_legacy_cron_locked || true
    return 0
}

# 锁内交给 _xray_core_geo_update_locked 收敛 pending coretxn 后再快照和改写 dat。
# 恢复未收敛不得覆盖旧恢复源; 本模块不自行重放 binary/service。
_geo_update_commit_locked() {
    local tmp="$1" ts="$2" ok="$3"
    if ! declare -F _xray_core_geo_update_locked >/dev/null 2>&1; then
        _error "缺少 coretxn Geo 提交入口, 拒绝修改 live dat"
        return 1
    fi
    _xray_core_geo_update_locked "$tmp" "$ts" "$ok"
}

# 启动迁移保留旧 cron, 只有 dat 提交和 runtime 收敛成功后才能清理该兜底。
_geo_finalize_legacy_cron() {
    _with_config_lock _with_core_lock _geo_finalize_legacy_cron_locked
}

_geo_finalize_legacy_cron_locked() {
    [ "$(_state_get geo_cron 2>/dev/null)" = "on" ] || return 0
    [ "$(_geo_transition_get)" = "off_pending" ] && return 0
    [ -x "$XRAY_BIN" ] && _xray_version_ge "26.4.25" || return 0
    _config_present && command -v jq >/dev/null 2>&1 || return 0
    [ "$(_config_jq -r 'if (.geodata.cron // "") != "" then 1 else 0 end' 2>/dev/null)" = "1" ] || return 0

    if ! _geo_remove_cron_line; then
        _warn "Geo 数据已更新, 但旧系统 cron 兜底未能移除; 下次成功更新会重试"
        return 1
    fi
    if ! _state_set geo_cron "off"; then
        _warn "旧系统 cron 已移除, 但 geo_cron 状态未能清除; 下次成功更新会重试"
        return 1
    fi
    _info "Geo 更新已成功提交, 已移除旧系统 cron 兜底"
    return 0
}

# _geo_set_auto_update on|off: ≥ v26.4.25 写内置 geodata, 旧核心走系统 cron。
# 关闭先记 off_pending, config 修改失败由 _mutate_config 回滚并留待下次关闭恢复。
_geo_set_auto_update() {
    local action="$1"
    case "$action" in
        on)
            if [ -x "$XRAY_BIN" ] && _xray_version_ge "26.4.25"; then
                # assets.file 构建会检查存在性, 启用前必须齐备; 见本模块头部。
                if [ ! -f "$ASSET_DIR/geosite.dat" ] || [ ! -f "$ASSET_DIR/geoip.dat" ]; then
                    _warn "assets/ 下缺少 geosite.dat 或 geoip.dat, 无法启用 Xray 内置更新"
                    _tip "请先在上层菜单选择 [1] 立即更新一次(或安装核心时会自动放入), 再开启自动更新"
                    return 1
                fi
                if [ "$(_geo_transition_get)" = "off_pending" ]; then
                    _geo_transition_clear || { _error "Geo 关闭清理仍未完成, 暂不能重新开启"; return 1; }
                fi
                local gd
                gd=$(_geo_geodata_json) || { _error "生成 geodata 配置失败"; return 1; }
                if _mutate_config --argjson gd "$gd" '.geodata = $gd'; then
                    # verified-restart 后可清旧 cron; 清理失败保留 on 作为兜底与重试证据。
                    if _geo_remove_cron_line >/dev/null 2>&1; then
                        _state_set geo_cron "off" 2>/dev/null || \
                            _warn "旧 geo_cron 状态未能清除(内置定时已生效, 后续更新会重试)"
                    else
                        _state_set geo_cron "on" 2>/dev/null || \
                            _warn "旧系统 cron 仍可能存在, 且 geo_cron 状态未能保留"
                        _warn "旧系统 cron 行未能移除; 保留为兜底, 下次成功 geo-update 后重试"
                    fi
                    _success "Geo 自动更新已开启 (Xray 内置: $GEO_CRON_EXPR, 热重载)"
                    return 0
                fi
                _error "写入 geodata 配置失败(配置已回滚)"
                return 1
            fi
            # 版本门控未通过只走 cron, 不能假定核心支持 geodata。
            _geo_set_auto_update_cron on
            ;;
        off)
            # 先记录 off 意图, 清理失败后启动恢复只能继续关闭, 不得重新迁移为开启。
            if ! _state_set "$GEO_TRANSITION_KEY" "off_pending"; then
                _error "无法记录 Geo 关闭意图, 未做任何变更"
                return 1
            fi
            local has_geo=0 off_failed=0
            if _config_present; then
                if ! command -v jq >/dev/null 2>&1; then
                    _warn "无法检查 config 中的 geodata, 保留关闭重试标记"
                    off_failed=1
                elif ! has_geo=$(_config_jq -r 'if has("geodata") then 1 else 0 end' 2>/dev/null); then
                    _warn "无法读取 config 中的 geodata, 保留关闭重试标记"
                    off_failed=1
                    has_geo=unknown
                fi
            fi
            if [ "$has_geo" = "1" ] && ! _mutate_config 'del(.geodata)'; then
                _error "移除 geodata 配置失败(配置已回滚), 将在下次启动重试关闭"
                off_failed=1
            fi
            if _geo_remove_cron_line >/dev/null 2>&1; then
                _state_set geo_cron "off" 2>/dev/null || {
                    _warn "系统 cron 已移除, 但 geo_cron 状态写入失败"
                    off_failed=1
                }
            else
                _warn "系统 cron 行未能移除, 请手动检查 crontab (${GEO_CRON_MARKER})"
                _state_set geo_cron "on" 2>/dev/null || \
                    _warn "cron 清理失败且 geo_cron 重试状态无法持久化"
                off_failed=1
            fi
            if [ "$off_failed" -eq 0 ]; then
                _geo_transition_clear || off_failed=1
            fi
            if [ "$off_failed" -eq 1 ]; then
                _tip "关闭清理尚未完成, 后续启动会继续关闭且不会重新启用"
                return 1
            fi
            _success "Geo 自动更新已关闭"
            ;;
        *) _warn "未知动作: $action"; return 1 ;;
    esac
}

# _geo_set_auto_update_cron on|off: 旧核心回退路径, 先改 crontab 再记状态。
_geo_set_auto_update_cron() {
    local action="$1"
    # cron PATH 受限, 用命令绝对路径兜底; 调度语义见 GEO_CRON_EXPR。
    local cmd="$(command -v "$CMD_NAME" 2>/dev/null || echo "/usr/local/bin/$CMD_NAME") geo-update"
    local cron_line="0 3 */3 * * $cmd ${GEO_CRON_MARKER}"

    case "$action" in
        on)
            if [ "$(_geo_transition_get)" = "off_pending" ]; then
                _geo_transition_clear || { _error "Geo 关闭清理仍未完成, 暂不能重新开启"; return 1; }
            fi
            # _crontab_replace 统一去重与写入; 读失败不动原表, 混装缺 helper 时拒绝写。
            if ! declare -F _crontab_replace >/dev/null 2>&1; then
                _error "lib 版本过旧(00-common 缺 _crontab_replace), 无法写入 crontab"
                _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
                return 1
            fi
            if ! _crontab_replace "$GEO_CRON_MARKER" "$cron_line"; then
                _error "写入 crontab 失败"; return 1
            fi
            # 守护与记账失败要撤刚写的行, 避免残留任务日后无状态执行本脚本。
            if _ensure_cron_running; then
                if ! _state_set geo_cron "on"; then
                    if _geo_remove_cron_line >/dev/null 2>&1; then
                        _state_set geo_cron "off" 2>/dev/null || \
                            _warn "cron 行已回滚, 但 geo_cron 状态无法恢复为 off"
                    else
                        _warn "geo_cron 状态写入失败, 且 crontab 回滚失败; 请手动检查 ${GEO_CRON_MARKER}"
                        _state_set geo_cron "on" 2>/dev/null || \
                            _warn "cron 行仍可能存在, 但 geo_cron 重试状态无法持久化"
                    fi
                    _error "Geo 自动更新已取消: geo_cron 状态持久化失败"
                    return 1
                fi
                _warn "已开启 (系统 cron 方案: 当前核心 < v26.4.25, 不支持 Xray 内置 geodata)"
                _tip "更新到 ≥ v26.4.25 后会自动切换到 Xray 内置定时, 无需系统 cron"
                _success "Geo 自动更新已开启 (每月 1/4/7/.../31 号 03:00 执行)"
            else
                # 回滚失败仍须告警, 不能把残留无人值守任务隐藏为已取消。
                if ! _geo_remove_cron_line >/dev/null 2>&1; then
                    _warn "crontab 回滚失败, 请手动检查项目定时任务 (${GEO_CRON_MARKER})"
                fi
                _warn "cron 守护进程未能启动, 自动更新已取消"
                _tip "请确保系统中有 cron 守护进程, 安装后重试"
                _state_set geo_cron "off"
                # 显式失败, 不让最后一次 state 写成功把“已取消”洗成返回 0。
                return 1
            fi
            ;;
        off)
            # cron 行是更新机制本身: 删除失败不改 state, 不能误报已关闭。
            # 通用关闭还处理 config 回滚与 off_pending 恢复; 见 _geo_set_auto_update。
            if ! _geo_remove_cron_line; then
                _error "移除 geo 定时任务失败(crontab 不可读/不可写?), 自动更新仍是开启状态"
                _tip "请手动检查 crontab 中的 ${GEO_CRON_MARKER} 行, 或修复 crontab 权限后重试"
                return 1
            fi
            _state_set geo_cron "off" || _warn "geo_cron 状态写入失败, 状态显示可能不准"
            _success "Geo 自动更新已关闭"
            ;;
    esac
}

# 启动迁移仅在 ≥ v26.4.25 且 dat 齐备时写 geodata, 不重启; 旧 cron 留作运行兜底。
# 首次成功更新后由 _geo_finalize_legacy_cron 清理; off_pending 永远优先继续关闭。
# 整份 config RMW 持 config 锁和写屏障, 避免覆盖并发节点写入或未收敛事务。
_auto_migrate_geo_autoupdate() {
    local transition; transition=$(_geo_transition_get)
    if [ "$transition" != "off_pending" ] && [ "$(_state_get geo_cron 2>/dev/null)" != "on" ]; then
        return 0
    fi
    _config_present || [ "$transition" = "off_pending" ] || return 0
    _with_config_lock _auto_migrate_geo_autoupdate_locked
}
_auto_migrate_geo_autoupdate_locked() {
    local transition; transition=$(_geo_transition_get)
    if [ "$transition" != "off_pending" ] && [ "$(_state_get geo_cron 2>/dev/null)" != "on" ]; then
        return 0
    fi
    _config_present || [ "$transition" = "off_pending" ] || return 0
    _with_config_write_barrier _auto_migrate_geo_autoupdate_write
}

_auto_migrate_geo_autoupdate_write() {
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    local transition has_geo=0 content
    transition=$(_geo_transition_get)
    if _config_present; then
        command -v jq >/dev/null 2>&1 || return 1
        has_geo=$(_config_jq -r 'if has("geodata") then 1 else 0 end' 2>/dev/null) || return 1
    fi

    if [ "$transition" = "off_pending" ]; then
        if [ "$has_geo" = "1" ] && ! _mutate_config 'del(.geodata)'; then
            _warn "Geo 关闭恢复未能提交并验证 Xray 重启, 保留重试标记"
            return 1
        fi
        if ! _geo_remove_cron_line; then
            _warn "Geo 关闭清理仍未完成, 保留重试标记; 不会重新启用"
            return 1
        fi
        if ! _state_set geo_cron "off"; then
            _warn "旧 cron 已移除, 但 geo_cron 状态写入失败; 保留关闭重试标记"
            return 1
        fi
        if _geo_transition_clear; then
            _info "已完成 Geo 自动更新关闭清理"
        fi
        return 0
    fi

    [ "$(_state_get geo_cron 2>/dev/null)" = "on" ] || return 0
    _config_present && command -v jq >/dev/null 2>&1 || return 0
    local has_enabled_gd
    has_enabled_gd=$(_config_jq -r 'if (.geodata.cron // "") != "" then 1 else 0 end' 2>/dev/null) || return 0
    # 配置已写不等于 runtime 已加载; 不重启的迁移必须保留旧 cron, 见函数入口契约。
    [ "$has_enabled_gd" = "1" ] && return 0

    if [ -x "$XRAY_BIN" ] && _xray_version_ge "26.4.25" \
       && [ -f "$ASSET_DIR/geosite.dat" ] && [ -f "$ASSET_DIR/geoip.dat" ]; then
        local gd
        gd=$(_geo_geodata_json) || return 0
        content=$(_config_jq --argjson gd "$gd" '.geodata = $gd' 2>/dev/null) || return 0
        [ -n "$content" ] || return 0
        if _config_write_merged "$content" 2>/dev/null; then
            _info "已写入 Geo 内置定时($GEO_CRON_EXPR); 暂保留旧系统 cron, 首次成功更新后切换"
        fi
    fi
}

_geo_remove_cron_line() {
    # 写路径缺安全 helper 时拒绝操作, 裸管道会在读失败时清空用户 crontab。
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 已跳过 crontab 清理"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    # 读取失败保留原表; 安全替换契约见 _crontab_replace。
    _crontab_replace "$GEO_CRON_MARKER"
}

# 展示调度提示: 优先原样回显 geodata.cron, 旧 cron 仅给默认调度的粗略提示。
_geo_next_run_hint() {
    local c=""
    if _config_present && command -v jq >/dev/null 2>&1; then
        c=$(_config_jq -r '.geodata.cron // empty' 2>/dev/null)
    fi
    if [ -n "$c" ]; then
        echo "Xray 内置定时: ${c} (每月 1/4/7/.../31 号 03:00, 热重载)"
        return
    fi
    local line
    line=$(crontab -l 2>/dev/null | grep "$GEO_CRON_MARKER" | head -1)
    if [ -z "$line" ]; then
        echo "未开启"
        return
    fi
    echo "每月 1/4/7/.../31 号 03:00 (系统 cron)"
}

# 精简/恢复共用 _config_edit_preflight, 并检查共享常量。
# 混装旧 lib 缺常量时明确拒绝, 避免 set -u 崩菜单或向 --argjson 传空值。
_route_preflight() {
    _config_edit_preflight "修改路由规则" || return 1
    if [ -z "${XRAY_DEFAULT_ROUTING_RULES_JSON:-}" ] || [ -z "${XRAY_PRIVATE_BLOCK_RULE_JSON:-}" ] \
       || [ -z "${XRAY_PRIVATE_BLOCK_RULE_TAG:-}" ]; then
        _error "缺少默认规则常量(lib/00-common.sh 可能是旧版本), 无法修改路由规则"
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

# Geo 菜单复用 _geo_auto_mechanism, 不单靠 legacy state 判断内置更新。
_geo_menu() {
    clear
    echo
    echo -e "  ${CYAN}【Geo 数据自动更新】${NC}"
    local state; state=$(_geo_auto_state)
    local mech; mech=$(_geo_auto_mechanism)
    if [ "$state" = "on" ]; then
        echo -e "  当前状态: ${GREEN}● 已开启${NC}"
        echo -e "  下次执行: $(_geo_next_run_hint)"
        if [ "$mech" = "cron" ]; then
            echo -e "  更新机制: ${YELLOW}系统 cron(当前核心 < v26.4.25, 不支持 Xray 内置)${NC}"
        else
            echo -e "  更新机制: ${GREEN}Xray 内置定时(热重载, 无需系统 cron)${NC}"
        fi
    else
        echo -e "  当前状态: ${RED}○ 已关闭${NC}"
    fi
    echo -e "  数据源: Loyalsoldier/v2ray-rules-dat (完整版)"
    echo -e "  落点: $ASSET_DIR (config env 的 XRAY_LOCATION_ASSET)"
    echo
    echo -e "  ${GREEN}[1]${NC} 立即更新一次"
    if [ "$state" = "on" ]; then
        echo -e "  ${GREEN}[2]${NC} 关闭自动更新"
    else
        echo -e "  ${GREEN}[2]${NC} 开启自动更新(定期)"
    fi
    echo -e "  ${GREEN}[3]${NC} 路由规则(小内存优化: 精简 geo 引用)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1) _geo_update ;;
        2) if [ "$state" = "on" ]; then _geo_set_auto_update off; else _geo_set_auto_update on; fi ;;
        3) _route_rules_menu; return ;;
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
        _error "缺少默认 DNS 常量(lib/00-common.sh 可能是旧版本), 无法恢复默认"
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

