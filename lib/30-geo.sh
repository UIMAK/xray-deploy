#!/bin/bash
# =============================================================================
# lib/30-geo.sh — geosite/geoip 自动更新
# R4: 可开/关, 默认关; 数据源 Loyalsoldier/v2ray-rules-dat; 下载失败保留旧 dat。
# R45: 新核心(≥ v26.4.25)优先走 config geodata 内置定时(docs/config/geodata.md, 热重载
# + 失败回滚, **不再需要系统 cron**); 旧核心回退系统 cron(每月 1/4/7/.../31 号 03:00
# 调 xd geo-update)。落点 $ASSET_DIR(config env 的 XRAY_LOCATION_ASSET 指向)。
# 注意: assets.file 构建时要求已存在(geodata.go StatAsset); 启用前必须确保 dat 在
# assets/ 下(安装自带 / [1] 立即更新一次)。
# DNS 设置: 管理 confs/04_dns.json(dns 模块); 写盘前先用真核心 -test 预检候选配置。
# ============================================================================

GEO_CRON_MARKER="# xray-deploy-geo-update"
GEO_STATE_FILE="$STATE_DIR/geo_cron"
GEO_TRANSITION_KEY="geo_update_transition"
# 内置 geodata 定时表达式(同旧 cron 语义: day-of-month 的 */3 = 每月 1/4/7/.../31 号)
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

# ---------------------------------------------------------------------------
# 生成配置的 geodata 段(R45), 结构见 docs/config/geodata.md: cron(5 字段) +
# assets[](url 必须 HTTPS)。outbound 省略 → 下载走路由模块(默认 github 直连); 输出必须
# 是合法 JSON(供 --argjson)。
# ---------------------------------------------------------------------------
_geo_geodata_json() {
    jq -n \
        --arg cron "$GEO_CRON_EXPR" \
        --arg u1 "$GEO_BASE/geosite.dat" \
        --arg u2 "$GEO_BASE/geoip.dat" \
        '{cron: $cron, assets: [ {url: $u1, file: "geosite.dat"}, {url: $u2, file: "geoip.dat"} ]}'
}

# ---------------------------------------------------------------------------
# 自动更新状态与机制(R45): 真相源配置的 .geodata.cron 非空 = 内置更新开启(Xray
# 定时, 无需系统 cron); 无 geodata 时回退读 state geo_cron(=on 表示旧 cron 方案在跑)。
# _geo_auto_mechanism 输出恒为 builtin|cron|off(唯一查询点), _geo_auto_state 复用后输出
# on|off —— 单一来源, 避免 jq 查询漂移。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# "该 routing 规则是否引用 geo 数据"的唯一判据(统计与过滤复用同一份, 避免漂移)。依据
# docs/config/routing.md 与 router/config.go 的 BuildCondition: 只有 domain(geosite:/
# ext:)与三个 IP 类字段 ip / sourceIP(别名 source)/ localIP(geoip:/ext:)会触发 dat 加载,
# 其余(protocol/port/network/user/attrs/process/inboundTag)纯内存。
#
# 三个细节不能省: ext:file:tag 等价 geoip:/geosite:, 漏判则手写 ext: 规则清不掉;
# ! 反选前缀同样加载 dat, 故先 ltrimstr("!") 再判前缀; ? 与 // [] 兜底吸收畸形输入
# (缺 routing / null / domain 非数组), 否则 jq 报错中止。
# ---------------------------------------------------------------------------
GEO_RULE_REF_JQ='([(.domain? // [])[]?, (.ip? // [])[]?, (.sourceIP? // [])[]?, (.source? // [])[]?, (.localIP? // [])[]?] | map(select(type=="string")) | map(ltrimstr("!")) | any(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))'

# ---------------------------------------------------------------------------
# 确保 cron 服务在运行并开机自启(对齐 systemctl enable --now)。返回 0 仅当"当前启动
# + 持久化启用"都成功, 否则返回 1, 由调用方决定状态标记。
# ---------------------------------------------------------------------------
_ensure_cron_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || return 1 ;;
        # OpenRC: Alpine 默认 BusyBox crond, 也支持 cronie/dcron; 用 /etc/init.d/ 存在性
        # 探测, 不硬编码服务名。先 start 再 rc-update add: 任一失败都返回 1 —— 只"当前在跑"
        # 不算成功, 否则重启后 cron 不自启而状态显示 on(service/config/state 分裂)。
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
        # direct(无 init): 找到并启动 cron 守护(crond=busybox/Vixie, cron=ISC)。判活必须
        # 用 _proc_any_named(容器内可靠), 不用 pgrep —— busybox pgrep -x 会假阴性(H3)。
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
        # 兜底: INIT_SYSTEM 为空/未知时**必须返回 1**。否则 case 无匹配隐式返回 0,
        # 调用方当作"cron 已就绪"写入 crontab 并标 state=on, 而实际无守护进程(静默失败)。
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 执行一次 Geo 更新。网络下载/体积校验在 core lock 外; live dat 的备份、原子替换、
# 重启验证与回滚在 core lock 内, 与核心事务共享互斥边界。
# ---------------------------------------------------------------------------
_geo_update() {
    _ensure_dirs || return 1
    # M26: cron 下 stdout 会变成噪音邮件, 重定向到日志; 日志目录必须先建好, 否则 exec
    # 重定向失败会丢失诊断(日志问题本身降级继续)。
    if [ ! -t 0 ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        # exec 是特殊内建, 非交互 shell 重定向失败会终止 shell; 先探测再重定向。
        if ( : >> "$GEO_LOG" ) 2>/dev/null; then
            exec >> "$GEO_LOG" 2>&1
        else
            _warn "无法写入日志 $GEO_LOG, 本次输出未落盘"
        fi
    fi
    # Cron can fire while a failed user-requested disable is pending. Finish that disable
    # transaction and do not update dat under an explicit off intent.
    if [ "$(_geo_transition_get)" = "off_pending" ]; then
        _info "检测到 Geo 关闭操作待收敛, 本次跳过数据更新"
        _auto_migrate_geo_autoupdate || return 1
        return 0
    fi
    if ! declare -F _with_core_lock >/dev/null 2>&1; then
        _error "缺少核心互斥锁, 拒绝更新 Geo 数据"
        return 1
    fi
    # 临时目录只承载下载件; 创建失败必须中止, 否则空 tmp 会让路径退化到文件系统根。
    local tmp
    tmp=$(mktemp -d) || { _error "无法创建 Geo 下载临时目录, 更新中止"; return 1; }
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    _info "[$ts] 开始更新 Geo 数据..."

    # 网络等待与下载校验均在锁外; 两个 dat 一组提交 —— 任一失败会在锁内 coretxn
    # preflight 拒绝整体变更, 避免新旧 dat 混合提交。
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
        # 校验: 非空且体积至少 1KB。
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

# Called while config lock -> core lock are both held. Keeping cron/state finalization in this
# section ties fallback removal to the runtime convergence established by the same Geo commit.
_geo_update_commit_and_finalize_locked() {
    local tmp="$1" ts="$2" ok="$3"
    _geo_update_commit_locked "$tmp" "$ts" "$ok" || return $?
    _geo_finalize_legacy_cron_locked || true
    return 0
}

# 仅由 _geo_update 在 _with_core_lock 内调用。必须先收敛 pending coretxn 才可快照/改写
# live dat, 避免与核心切换互相覆盖对方的快照或提交。
_geo_update_commit_locked() {
    local tmp="$1" ts="$2" ok="$3"
    if ! declare -F _xray_core_geo_update_locked >/dev/null 2>&1; then
        _error "缺少 coretxn Geo 提交入口, 拒绝修改 live dat"
        return 1
    fi
    _xray_core_geo_update_locked "$tmp" "$ts" "$ok"
}

# 只有成功提交 dat 且完成 runtime 收敛后, 才能移除启动迁移留下的旧 cron 兜底。
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

# ---------------------------------------------------------------------------
# 开/关自动更新(R45 双路径): 新核心(≥ v26.4.25)写 config geodata 段(Xray 内置定时,
# 无系统 cron); 旧核心回退系统 cron(调 xd geo-update)。
# 用法:_geo_set_auto_update on|off
# ---------------------------------------------------------------------------
_geo_set_auto_update() {
    local action="$1"
    case "$action" in
        on)
            if [ -x "$XRAY_BIN" ] && _xray_version_ge "26.4.25"; then
                # geodata 构建要求 dat 已存在(StatAsset), 缺失则核心启动失败 —— 必须前置校验。
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
                    # 手动配置已 verified-restart, 可立即尝试清理旧 cron; 失败时保留 on
                    # 作为兜底与重试证据, 后续成功的 geo-update 会再清理。
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
            # 旧核心: 沿用系统 cron 方案
            _geo_set_auto_update_cron on
            ;;
        off)
            # 先持久化明确的 off 意图。若任一清理步骤失败, 启动重试只能继续关闭, 不能把
            # geo_cron=on 误当成迁移请求而重新写入 geodata。
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

# ---------------------------------------------------------------------------
# 旧方案: 系统 cron 定时更新(仅旧核心 < v26.4.25)
# 用法:_geo_set_auto_update_cron on|off
# ---------------------------------------------------------------------------
_geo_set_auto_update_cron() {
    local action="$1"
    # cron 调本脚本: xd geo-update; */3 在 day-of-month = 每月 1/4/7/.../31 号 03:00
    # (跨月不连续, 非严格"每 3 天")。M25: cron 的 PATH 受限, 硬编码 /usr/local/bin 兜底。
    local cmd="$(command -v "$CMD_NAME" 2>/dev/null || echo "/usr/local/bin/$CMD_NAME") geo-update"
    local cron_line="0 3 */3 * * $cmd ${GEO_CRON_MARKER}"

    case "$action" in
        on)
            if [ "$(_geo_transition_get)" = "off_pending" ]; then
                _geo_transition_clear || { _error "Geo 关闭清理仍未完成, 暂不能重新开启"; return 1; }
            fi
            # 去重 + 写入一次完成。读 crontab 失败时 _crontab_replace 返回 1 且**不改动**
            # 现有 crontab(旧的裸管道会覆盖用户全部定时任务)。
            # 混装旧 lib(函数不存在)时: 写路径必须响亮拒绝(见 _geo_remove_cron_line)。
            if ! declare -F _crontab_replace >/dev/null 2>&1; then
                _error "lib 版本过旧(00-common 缺 _crontab_replace), 无法写入 crontab"
                _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
                return 1
            fi
            if ! _crontab_replace "$GEO_CRON_MARKER" "$cron_line"; then
                _error "写入 crontab 失败"; return 1
            fi
            # 确保 cron 服务运行; 失败时回滚刚写入的 crontab 行, 保证
            # state=off ⇔ 项目 cron entry 不存在, 避免 daemon 恢复后无状态执行。
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
                # 回滚刚写入的行; 失败要暴露, 不能静默
                if ! _geo_remove_cron_line >/dev/null 2>&1; then
                    _warn "crontab 回滚失败, 请手动检查项目定时任务 (${GEO_CRON_MARKER})"
                fi
                _warn "cron 守护进程未能启动, 自动更新已取消"
                _tip "请确保系统中有 cron 守护进程, 安装后重试"
                _state_set geo_cron "off"
                # **必须显式返回非零**: 否则函数以 `_state_set` 的成功状态收尾, 调用方会把
                # "已取消"报成"已开启"(桩化 _ensure_cron_running=1 时旧实现 rc=0)。
                return 1
            fi
            ;;
        off)
            # 移除失败**不得报成功**(九轮 OCR #25): 忽略返回码就置 off + 报"已关闭"会造出
            # "cron 行还在跑 + UI 说已关闭"的分裂, cron 仍在无人值守时执行本脚本。
            # 与 _geo_set_auto_update 的 off) **刻意不同**: 那里 config 是真相源, 残留只
            # 告警; 这里 cron 行就是机制本身, 移除失败必须 fail 且**不**改 state(保持 on)。
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

# ---------------------------------------------------------------------------
# 启动自动操作(R45): 存量 geo_cron=on 迁移到 Xray 内置 geodata。新核心(≥ v26.4.25)且
# dat 齐备时只写 config, 不重启也不移除旧 cron; 旧 cron 是运行中配置的安全兜底, 仅在
# 一次成功的 geo-update 完成 dat 提交/runtime 收敛后清理。off_pending 标记优先, 启动只
# 继续关闭, 绝不把已明确关闭的旧状态误当成迁移请求。
# 迁移的整份 config RMW 持 config lock 与写屏障, 防止覆盖并发节点事务。
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
    # 已写入的 geodata 可能尚未加载进运行中的 Xray. 保留 legacy cron/state; _geo_update
    # 负责在首次成功提交并收敛 runtime 后清理, 而启动迁移本身绝不重启服务。
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
    # 混装旧 lib 时该函数不存在 —— 这是**写路径**, 必须响亮拒绝并给可执行提示, 绝不能退回
    # 旧的裸管道写法(读失败会清空用户全部 crontab)。
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 已跳过 crontab 清理"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    # 读失败 → 返回 1 且不改动 crontab(旧实现会清空用户全部定时任务, 见 00-common)
    _crontab_replace "$GEO_CRON_MARKER"
}

# ---------------------------------------------------------------------------
# 解析下次预计执行时间(回显用): 新机制读 config geodata.cron 原样显示; 旧机制从 crontab
# 行粗略推算。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 路由规则精简(小内存优化) —— 前置条件校验
# 精简/恢复共用 00-common 的 _config_edit_preflight(与日志级别切换同口径 —— R1.11 / R2.8)。
# 额外校验三个 00-common 常量非空: 混装 lib(本模块新、00-common 旧)真实存在, 裸引用会让
# set -u 崩 TUI, 空值传 --argjson 又产生难懂的 jq 错, 故前置给出可执行提示。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 统计路由规则: "总数 geo引用数 节点规则数 私网标记数 混合数" 单行输出
# 一次 jq 出五个数字(每跑一次 jq = 一次 fork + 读整份 config); 读不到时输出
# "0 0 0 0 0" 并返回 1(调用方据此显示"无法读取")。
# ---------------------------------------------------------------------------
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
    # @tsv 用制表符分隔, 转成空格便于调用方 read -r 拆分
    printf '%s' "$out" | tr '\t' ' '
    return 0
}

# `ruleTag` alone is not proof of private-network protection: a hand-edited rule can retain the tag
# while allowing traffic, omitting CIDRs, duplicating the marker, or sitting after a catch-all.
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

# ---------------------------------------------------------------------------
# 统计 dns 段里的 geo 引用数(domains / expectedIPs / expectIPs)。默认 DNS 段不含 geo,
# 但手改过的配置可能有 —— 精简 routing 不足以免除 dat 加载, 必须如实告警。
# ---------------------------------------------------------------------------
_route_dns_geo_count() {
    if ! _config_present || ! command -v jq >/dev/null 2>&1; then
        printf '0'
        return 1
    fi
    local n
    n=$(_config_jq -r '
        [.dns?.servers[]? | select(type == "object")
         | (.domains? // [])[]?, (.expectedIPs? // [])[]?, (.expectIPs? // [])[]?]
        | map(select(type == "string")) | map(ltrimstr("!"))
        | map(select(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))
        | length' 2>/dev/null) || { printf '0'; return 1; }
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------------------
# 精简: 删除所有引用 geo 数据的规则, 注入等价的字面量 CIDR 私网 block 规则
#
# 顺序契约(关键): 私网规则必须插在"第一条无 inboundTag 的规则"之前。路由自上而下匹配
# (routing.md), tunnel 模式 Reality 的 2 条 inboundTag 规则必须保持在最前 —— 若私网
# block 抢先命中, 隧道到伪装站的握手流量会被切断(节点不可用)。无通用规则时追加末尾。
#
# 幂等: 先按 ruleTag 剔除上次注入的私网规则再重插。一律用"重建赋值"
# .routing.rules = [...] 而非 |= map(...): 后者在 routing:null 时抛 "Cannot iterate
# over null"(jq 1.8.2 实测)。
#
# 两处对非对象规则元素(手工可能写成裸字符串)的处理必须分清:
#   `(.ruleTag? // null) != "<tag>"` —— 必须带 `// null`, 否则裸 `.ruleTag?` 对字符串
#     元素产出空, select 丢掉它, 精简会顺手删掉用户的坏规则(未授权改动)。
#   `.value.inboundTag? == null` —— **不**补 `// null` 是刻意的: 空产出使非对象元素不成
#     插入点, 私网规则因而落在第一条真正的"无 inboundTag 对象规则"之前, 顺序契约不受
#     垃圾元素干扰。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 恢复默认规则: 保留现存节点(inboundTag)规则, 其后接 00-common 的默认规则集。只保留
# inboundTag 天然满足"节点规则在前 + 无重复", 注入的私网规则(无 inboundTag)被自然丢弃。
# 显式写回 domainStrategy: 默认规则里的 geoip:cn 依赖 IPIfNonMatch 才对域名目标生效。
# 已知取舍: 丢弃用户手工添加的**非节点**规则 —— 调用方必须在确认前明示。
# `.inboundTag?` 的 `?` 不可省: 规则被写成裸字符串时, 无 `?` 会让 jq 以 "Cannot index
# string with string" 整体失败, "恢复默认规则"反而在最需要时不可用。
# ---------------------------------------------------------------------------
_route_restore_default_rules() {
    _route_preflight || return 1
    _mutate_config --argjson defs "$XRAY_DEFAULT_ROUTING_RULES_JSON" \
        '.routing.domainStrategy = "IPIfNonMatch"
         | .routing.rules = ([.routing.rules[]? | select(.inboundTag? != null)] + $defs)' || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 路由规则子菜单(小内存优化入口, 由 _geo_menu [3] 进入)
# ---------------------------------------------------------------------------
_route_rules_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【路由规则(小内存优化)】${NC}"
        echo
        local total=0 geo=0 node=0 mark=0 mixed=0 stats_ok=1 private_ok=0
        local stats; stats=$(_route_rules_stats) || stats_ok=0
        # (三审 L9) stats 失败时不读 —— read 对空输入会把初始化的 0 覆盖成空串, 后续
        # [ "" -eq 0 ] 打出 "integer expression expected" 噪音(不致命但困惑)。
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
                # 幂等: 仅当规则内容、唯一性、顺序都有效时跳过; 单有 ruleTag 不能证明
                # 私网防护仍然生效。
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

# ---------------------------------------------------------------------------
# Geo 菜单入口
# ---------------------------------------------------------------------------
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

# =============================================================================
# DNS 设置 — 管理 confs/04_dns.json 的 dns 段
#
# 只改 .dns 一个字段, 其余字段原样保留。写盘复用通用事务路径(_mutate_config:
# 备份 → jq → 拆回 confs → 重启校验 → 失败回滚), 但**多一道预检**: 先把候选配置拆进
# 临时目录, 用真核心 `xray -test -confdir` 校验, 通过才写盘 —— 手输地址写错时不会把
# 一份正在工作的配置换成起不来的。
#
# 上游地址按需求存成**普通字符串**(不打 tag), 保持 04_dns.json 可读。默认上游都是
# https+local:// 直连 DoH; 手输的纯 IP 走默认第一条出站(direct), 无需改 routing。
# =============================================================================

# 展示用摘要: 输出 "<上游列表>|<解析策略>"。无 dns 段/解析失败时上游与策略都为空。
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

# 候选配置预检 + 落地。参数与 _config_jq 一致(选项在前, filter 在最后)。
_dns_apply() {
    [ "$#" -ge 1 ] || return 1
    local filter="${!#}" cand content
    local opts=()
    [ "$#" -gt 1 ] && opts=("${@:1:$#-1}")
    _config_edit_preflight "修改 DNS 配置" || return 1
    if [ "${#opts[@]}" -gt 0 ]; then
        content=$(_config_jq "${opts[@]}" "$filter" 2>/dev/null)
    else
        content=$(_config_jq "$filter" 2>/dev/null)
    fi
    [ -n "$content" ] || { _error "生成 DNS 配置失败, 已保留原配置"; return 1; }
    mkdir -p "$STATE_DIR" 2>/dev/null
    cand=$(mktemp -d "${STATE_DIR}/dns-preview.XXXXXX") || { _error "无法创建临时目录, 已保留原配置"; return 1; }
    if ! _config_write_merged "$content" "$cand"; then
        rm -rf "$cand"
        _error "生成候选配置失败, 已保留原配置"
        return 1
    fi
    echo
    _info "先用临时配置运行 xray -test..."
    if ! _xray_test_config_dir "$cand"; then
        rm -rf "$cand"
        _error "配置检查未通过, 已保留原配置"
        return 1
    fi
    rm -rf "$cand"
    if [ "${#opts[@]}" -gt 0 ]; then
        _mutate_config "${opts[@]}" "$filter" || { _error "写入 DNS 配置失败, 已保留原配置"; return 1; }
    else
        _mutate_config "$filter" || { _error "写入 DNS 配置失败, 已保留原配置"; return 1; }
    fi
    return 0
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
    echo -e "  ${GREEN}[3]${NC} https://cloudflare-dns.com/dns-query (Cloudflare DoH)"
    echo -e "  ${GREEN}[4]${NC} https://dns.google/dns-query (Google DoH)"
    echo -e "  ${GREEN}[5]${NC} 手动输入"
    echo -e "  ${GREEN}[0]${NC} 取消"
    local c addr=""
    read -rp "  请选择: " c || return 0
    case "${c:-0}" in
        1) addr="1.1.1.1" ;;
        2) addr="8.8.8.8" ;;
        3) addr="https://cloudflare-dns.com/dns-query" ;;
        4) addr="https://dns.google/dns-query" ;;
        5) read -rp "  请输入 DNS 地址(如 1.1.1.1 或 https://dns.google/dns-query): " addr || return 0 ;;
        0) return 0 ;;
        *) _warn "无效选择"; return 1 ;;
    esac
    addr="${addr//[[:space:]]/}"
    [ -n "$addr" ] || { _warn "地址为空, 已取消"; return 1; }
    _dns_apply --arg a "$addr" '.dns = ((.dns | if type == "object" then . else {} end) + {servers: [$a]})' || return 1
    _success "DNS 上游已更新为: $addr"
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
        echo -e "  ${GREEN}[5]${NC} 查看完整 DNS 配置"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "${choice:-0}" in
            1) _dns_set_servers ;;
            2) _dns_set_strategy ;;
            3) _dns_restore_default ;;
            4) _dns_delete ;;
            5) _dns_view ;;
            0) return ;;
            *) _warn "无效选择" ;;
        esac
        _press_any_key
    done
}

