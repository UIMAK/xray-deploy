#!/bin/bash
# =============================================================================
# lib/30-geo.sh — geosite/geoip 自动更新
# 需求 R4: 用户可开/关, 默认关; 数据源 Loyalsoldier/v2ray-rules-dat; 下载失败保留旧 dat。
# R45 更新(2026-09): 自动更新优先走 Xray 内置 geodata 配置(docs/config/geodata.md,
# 核心 ≥ v26.4.25): config.json 的 geodata.cron 定时 + assets 下载, 热重载 + 失败回滚,
# **不再需要系统 cron**。旧核心(< v26.4.25)自动回退到系统 cron 方案(每月 1/4/7/.../31 号
# 03:00 调用 xd geo-update), 兼容存量部署。
# 落点: $ASSET_DIR (/opt/xray-deploy/assets, 经 config env 的 XRAY_LOCATION_ASSET 指向)
# 注意: geodata 的 assets.file 在配置构建时要求文件已存在(infra/conf/geodata.go StatAsset),
# 所以启用内置更新前必须确保 dat 文件已在 assets/ 下(核心安装自带 / [1] 立即更新一次)。
# ============================================================================

GEO_CRON_MARKER="# xray-deploy-geo-update"
GEO_STATE_FILE="$STATE_DIR/geo_cron"
# 内置 geodata 的定时表达式(与旧 cron 同一语义: day-of-month 的 */3 = 每月 1/4/7/.../31 号)
GEO_CRON_EXPR="0 3 */3 * *"

# ---------------------------------------------------------------------------
# 生成 config.json 的 geodata 段(R45)
# 结构依据 docs/config/geodata.md: cron(5 字段标准表达式) + assets[](url 必须 HTTPS,
# file 为资源目录内的文件名)。outbound 省略 → 下载走路由模块(默认规则 github 直连)。
# 注意: 不用 jq -n --arg 也行, 但必须保证输出是合法 JSON(供 --argjson 传参)。
# ---------------------------------------------------------------------------
_geo_geodata_json() {
    jq -n \
        --arg cron "$GEO_CRON_EXPR" \
        --arg u1 "$GEO_BASE/geosite.dat" \
        --arg u2 "$GEO_BASE/geoip.dat" \
        '{cron: $cron, assets: [ {url: $u1, file: "geosite.dat"}, {url: $u2, file: "geoip.dat"} ]}'
}

# ---------------------------------------------------------------------------
# 自动更新状态与机制(R45, 审查修订: 单一 jq 查询源)
# 真相源: config.json 的 .geodata.cron 非空 = 内置更新开启(Xray 定时, 无需系统 cron)。
# 兼容旧机制: config 无 geodata 时回退读 state geo_cron(=on 表示旧 cron 方案仍在跑)。
# _geo_auto_mechanism 输出恒为 builtin|cron|off, 是唯一查询点; _geo_auto_state 复用它,
# 输出恒为 on|off —— 避免两份相同 jq 查询漂移。
# ---------------------------------------------------------------------------
_geo_auto_mechanism() {
    local c=""
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        c=$(jq -r '.geodata.cron // empty' "$CONFIG_FILE" 2>/dev/null)
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
# "该 routing 规则是否引用 geo 数据"的唯一判据(统计与过滤复用同一份, 避免两处漂移)
#
# 依据 Xray-docs-next/docs/config/routing.md 与 Xray-core/app/router/config.go
# 的 BuildCondition: 只有 domain(geosite:/ext:)与三个 IP 类字段 ip / sourceIP(别名
# source)/ localIP(geoip:/ext:)会触发 dat 加载; protocol/port/network/user/attrs/
# process/inboundTag 全是纯内存匹配器, 不吃 geo 内存。
#
# 三个细节不能省:
#   ext:file:tag 等价于 geoip:/geosite:(routing.md), 漏判会让手写 ext: 规则清不掉,
#     用户"照做了却没省内存";
#   ! 反选前缀(routing.md) 同样加载 dat, 故先 ltrimstr("!") 再判前缀;
#   ? 与 // [] 兜底吸收畸形输入(routing 缺失 / routing:null / rules:null /
#     domain 被手写成字符串而非数组), 否则 jq 直接报错中止。
# ---------------------------------------------------------------------------
GEO_RULE_REF_JQ='([(.domain? // [])[]?, (.ip? // [])[]?, (.sourceIP? // [])[]?, (.source? // [])[]?, (.localIP? // [])[]?] | map(select(type=="string")) | map(ltrimstr("!")) | any(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))'

# ---------------------------------------------------------------------------
# 确保 cron 服务在运行并开机自启(语义对齐 systemctl enable --now)。
# 返回 0 仅当"当前启动 + 持久化启用"都成功; 任一失败返回 1, 由调用方决定状态标记。
# ---------------------------------------------------------------------------
_ensure_cron_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || return 1 ;;
        # OpenRC: Alpine 默认 BusyBox cron 为 crond, 也支持 cronie/dcron。
        # 通过 /etc/init.d/ 存在性探测, 不硬编码服务名。
        # 先 start 再 rc-update add: start 失败直接返回(不把 enable 当成功), 
        # enable(add 到 default runlevel)失败同样返回 1 —— 不能只"当前在跑"就当完整成功,
        # 否则重启后 cron 不自启, 项目状态却显示 on(service/config/state 分裂)。
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
        # direct(无 init 系统): 尽力找到并启动 cron 守护(crond=busybox/Vixie, cron=ISC)
        # 判活用 _proc_any_named(pidof 优先 + /proc comm 扫描兜底, 容器内可靠), 不用 pgrep ——
        # 容器内 busybox pgrep -x 会假阴性(H3), 误把已运行的 crond 判为"未运行"
        # 再二次启动, 反而返回失败。
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
        # 兜底: INIT_SYSTEM 为空/未知(探测失败或未来新增 init 类型)时**必须返回 1**。
        # 没有这个分支时, case 无匹配 → 函数隐式返回 case 的退出码 0 → 调用方当作
        # "cron 已就绪", 写入 crontab 并把 state 标成 on, 而实际没有任何守护进程在跑
        # (显示已开启但永不执行的静默失败)。
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 执行一次 Geo 更新。网络下载/体积校验在 core lock 外; live dat 的备份、原子替换、
# 重启验证与回滚在 core lock 内, 与核心事务共享同一互斥边界。
# ---------------------------------------------------------------------------
_geo_update() {
    _ensure_dirs || return 1
    # M26: cron 环境下 _info/_warn 输出到 stdout 会产生噪音邮件, 重定向到日志。
    # 日志目录必须先建好: 否则 exec 重定向失败会丢失后续诊断; 日志问题本身仍降级继续。
    if [ ! -t 0 ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        # exec 是特殊内建, 非交互 shell 的重定向失败可能直接终止 shell; 先探测再重定向。
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
    # 临时目录只承载下载件; 创建失败必须中止, 否则空 tmp 会让下载路径退化到文件系统根目录。
    local tmp
    tmp=$(mktemp -d) || { _error "无法创建 Geo 下载临时目录, 更新中止"; return 1; }
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    _info "[$ts] 开始更新 Geo 数据..."

    # 所有网络等待与下载校验均在锁外。任一下载失败仍保留已有的 best-effort 语义:
    # 可用的另一份会进入锁内提交, 随后按部分失败路径回滚。
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
    _with_core_lock _geo_update_commit_locked "$tmp" "$ts" "$ok" || rc=$?
    rm -rf "$tmp"
    return "$rc"
}

# 仅由 _geo_update 在 _with_core_lock 内调用。下载已完成; 从 pending coretxn 收敛后，
# 才能快照/改写 live dat, 避免 geo updater 与核心切换互相覆盖对方的快照或提交。
_geo_update_commit_locked() {
    local tmp="$1" ts="$2" ok="$3"
    local backed=() f src dest sz incoming incoming_sz
    if ! declare -F _xray_core_txn_recover_locked >/dev/null 2>&1 || \
       ! declare -F _xray_core_txn_pending >/dev/null 2>&1; then
        _error "缺少核心事务恢复/状态检查, 拒绝更新 Geo 数据"
        return 1
    fi
    if ! _xray_core_txn_recover_locked; then
        _error "核心事务尚未收敛, 拒绝更新 Geo 数据"
        return 1
    fi
    if _xray_core_txn_pending; then
        _error "核心事务仍待处理, 拒绝更新 Geo 数据"
        return 1
    fi

    for f in geosite.dat geoip.dat; do
        src="${tmp}/${f}"
        dest="$ASSET_DIR/$f"
        [ -f "$src" ] || continue
        sz=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)
        if [ "$sz" -lt 1024 ]; then
            _warn "$f 下载暂存文件异常(${sz}B), 保留旧文件"
            ok=0
            continue
        fi

        # 下载目录可能与 assets 不同文件系统。先复制到 assets 内的唯一临时文件并校验，
        # 最后的 mv 因而是同文件系统 rename, 不会退化成跨盘 copy/unlink。
        incoming=$(mktemp "$ASSET_DIR/.geo-update.${f}.XXXXXX") || {
            _warn "$f 无法在 assets 创建替换暂存文件, 保留旧文件"
            ok=0
            continue
        }
        if ! cp -f "$src" "$incoming"; then
            _warn "$f 复制到 assets 暂存文件失败, 保留旧文件"
            rm -f "$incoming"
            ok=0
            continue
        fi
        incoming_sz=$(stat -c%s "$incoming" 2>/dev/null || stat -f%z "$incoming" 2>/dev/null || echo 0)
        if [ "$incoming_sz" != "$sz" ] || ! cmp -s "$src" "$incoming" 2>/dev/null; then
            _warn "$f assets 暂存文件校验失败, 保留旧文件"
            rm -f "$incoming"
            ok=0
            continue
        fi

        # 覆盖前备份旧 dat (S9: 运行期校验失败或部分下载失败时可回退)。
        # 备份必须成功且体积一致才允许替换; 否则可能把半截备份当成唯一恢复源。
        if [ -f "$dest" ]; then
            if ! cp -f "$dest" "$dest.bak"; then
                _warn "$f 旧文件备份失败(磁盘空间/IO?), 保留旧文件, 跳过本次替换"
                rm -f "$incoming"
                ok=0
                continue
            fi
            local _osz _bsz
            _osz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo 0)
            _bsz=$(stat -c%s "$dest.bak" 2>/dev/null || stat -f%z "$dest.bak" 2>/dev/null || echo 0)
            if [ "$_osz" -le 0 ] || [ "$_bsz" != "$_osz" ]; then
                _warn "$f 旧文件备份不完整(${_bsz}B != ${_osz}B), 保留旧文件, 跳过本次替换"
                rm -f "$dest.bak" "$incoming"
                ok=0
                continue
            fi
            backed+=("$dest")
        fi
        if ! mv -f "$incoming" "$dest"; then
            _warn "$f 替换失败(磁盘空间/IO/只读?), 保留旧文件, 跳过本次更新"
            rm -f "$incoming"
            ok=0
            continue
        fi
        _success "$f 更新成功 (${sz}B)"
    done

    mkdir -p "$LOG_DIR"
    if [ "$ok" -eq 1 ]; then
        # 低内存机器不跑 xray -test(双份加载 OOM); 仅原本运行时重启验证。
        local need_verify=0
        if [ -x "$XRAY_BIN" ] && [ -f "$CONFIG_FILE" ]; then
            case "$(_manage_xray status 2>/dev/null)" in running) need_verify=1;; esac
        fi
        if [ "$need_verify" -eq 1 ]; then
            if _restart_xray_verified; then
                for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
                echo "[$ts] OK 全部更新成功, xray 重启稳定" >> "$GEO_LOG"
            else
                _warn "新 Geo 数据导致 xray 运行异常, 回退旧 dat"
                # backed[] 不含首次部署时不存在的 dat; 统计真实回退数, 避免误报已恢复。
                local rolled=0
                for dest in "${backed[@]}"; do
                    if [ -f "${dest}.bak" ]; then
                        if mv -f "${dest}.bak" "$dest"; then
                            rolled=$((rolled+1))
                        else
                            _warn "回滚 ${dest} 失败, 请手动检查"
                        fi
                    fi
                done
                local recovered="xray 仍未稳定运行, 需人工介入"
                if _restart_xray_verified; then recovered="xray 已恢复运行"; fi
                if [ "$rolled" -eq 0 ]; then
                    _warn "无旧 dat 可回退(首次安装/assets 曾被清空), 新 dat 仍在 ${ASSET_DIR}"
                    echo "[$ts] FAIL 新 dat 运行期校验失败, 无旧 dat 可回退, ${recovered}" >> "$GEO_LOG"
                else
                    echo "[$ts] FAIL 新 dat 运行期校验失败, 已回退 ${rolled} 个旧 dat, ${recovered}" >> "$GEO_LOG"
                fi
                return 1
            fi
        else
            for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
            echo "[$ts] OK 全部更新成功(xray 未运行, 已跳过重启)" >> "$GEO_LOG"
        fi
        return 0
    fi

    # 部分下载/提交失败: 回退已替换且有旧文件快照的 dat。首次安装无旧文件时沿用既有语义。
    # 统计真实回退数量, 使 cron 日志如实区分“无旧 dat”与“回滚了旧 dat”。
    local rolled=0
    for dest in "${backed[@]}"; do
        if [ -f "${dest}.bak" ]; then
            if mv -f "${dest}.bak" "$dest"; then
                rolled=$((rolled+1))
            else
                _warn "回滚 ${dest} 失败, 请手动检查"
            fi
        fi
    done
    if [ "$rolled" -eq 0 ]; then
        echo "[$ts] PARTIAL 部分失败, 无已替换文件需回退" >> "$GEO_LOG"
    else
        echo "[$ts] PARTIAL 部分失败, 已回退 ${rolled} 个旧 dat" >> "$GEO_LOG"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 开/关自动更新(R45 双路径)
#   新核心(≥ v26.4.25): 写 config.json 的 geodata 段, Xray 内置定时下载+热重载, 无系统 cron。
#   旧核心(< v26.4.25): 回退系统 cron 方案(调用 xd geo-update), 兼容存量部署。
# 用法:_geo_set_auto_update on|off
# ---------------------------------------------------------------------------
_geo_set_auto_update() {
    local action="$1"
    case "$action" in
        on)
            if [ -x "$XRAY_BIN" ] && _xray_version_ge "26.4.25"; then
                # geodata 配置构建时要求 dat 文件已存在(infra/conf/geodata.go StatAsset),
                # 缺失时 xray 会启动失败 —— 必须前置校验, 让用户先 [1] 立即更新一次。
                if [ ! -f "$ASSET_DIR/geosite.dat" ] || [ ! -f "$ASSET_DIR/geoip.dat" ]; then
                    _warn "assets/ 下缺少 geosite.dat 或 geoip.dat, 无法启用 Xray 内置更新"
                    _tip "请先在上层菜单选择 [1] 立即更新一次(或安装核心时会自动放入), 再开启自动更新"
                    return 1
                fi
                local gd
                gd=$(_geo_geodata_json) || { _error "生成 geodata 配置失败"; return 1; }
                if _mutate_config --argjson gd "$gd" '.geodata = $gd'; then
                    # 清理旧 cron 机制(幂等), 旧 state 一并清掉 —— 新机制以 config 为真相。
                    # 两条清理路径失败只告警: 此处 config 已是真相, 残留的 cron 行/state 是
                    # 冗余而非分裂(_geo_auto_mechanism 先读 config)。但必须说出来 —— 静默吞掉
                    # 会让用户以为旧机制已拆干净。
                    _geo_remove_cron_line >/dev/null 2>&1 || \
                        _warn "旧系统 cron 行未能移除, 请手动检查 crontab (${GEO_CRON_MARKER})"
                    _state_set geo_cron "off" 2>/dev/null || \
                        _warn "旧 geo_cron 状态未能清除(内置定时已生效, 不影响功能)"
                    _success "Geo 自动更新已开启 (Xray 内置: $GEO_CRON_EXPR, 热重载, 无需系统 cron)"
                    return 0
                fi
                _error "写入 geodata 配置失败(配置已回滚)"
                return 1
            fi
            # 旧核心: 沿用系统 cron 方案
            _geo_set_auto_update_cron on
            ;;
        off)
            # 先移除 config geodata(若有), 再清旧 cron 行与旧 state —— 两条路径都关干净。
            # 注意顺序与失败处理: config 删除失败时 _mutate_config 已回滚(geodata 仍在),
            # 但**仍要继续清 cron 行/state** —— 否则用户被告知"关闭失败"却留下一份仍在跑的
            # 系统 cron 任务(无人值守地每月执行本脚本), 与"关干净"的承诺相反。
            local has_gd=0 off_failed=0
            if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
                has_gd=$(jq -r 'if (.geodata.cron // "") != "" then 1 else 0 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
            fi
            if [ "$has_gd" = "1" ]; then
                if ! _mutate_config 'del(.geodata)'; then
                    _error "移除 geodata 配置失败(配置已回滚), 继续清理系统 cron 任务"
                    off_failed=1
                fi
            fi
            _geo_remove_cron_line >/dev/null 2>&1 || {
                _warn "系统 cron 行未能移除, 请手动检查 crontab (${GEO_CRON_MARKER})"
                off_failed=1
            }
            _state_set geo_cron "off" 2>/dev/null || _warn "geo_cron 状态写入失败, 状态显示可能不准"
            if [ "$off_failed" -eq 1 ]; then
                return 1
            fi
            _success "Geo 自动更新已关闭"
            ;;
        *) _warn "未知动作: $action"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 旧方案: 系统 cron 定时更新(仅旧核心 < v26.4.25 使用)
# 用法:_geo_set_auto_update_cron on|off
# ---------------------------------------------------------------------------
_geo_set_auto_update_cron() {
    local action="$1"
    # cron 调用本脚本的 geo-update 子命令: xd geo-update
    # */3 在 day-of-month 字段: 每月 1/4/7/.../31 号 03:00 (跨月不连续, 非严格 "每 3 天")
    # M25: cron 环境 PATH 受限时 command -v 可能失败, 硬编码 /usr/local/bin 兜底已足够
    local cmd="$(command -v "$CMD_NAME" 2>/dev/null || echo "/usr/local/bin/$CMD_NAME") geo-update"
    local cron_line="0 3 */3 * * $cmd ${GEO_CRON_MARKER}"

    case "$action" in
        on)
            # 去重 + 写入一次完成。读 crontab 失败时 _crontab_replace 返回 1 且**不改动**
            # 现有 crontab —— 旧的 `(crontab -l; echo) | crontab -` 在读失败时会把用户的
            # 全部定时任务覆盖成只剩我们这一行。
            # 混装旧 lib 时该函数不存在: 写路径必须响亮拒绝(见 _geo_remove_cron_line 的说明)。
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
                _state_set geo_cron "on"
                _warn "已开启 (系统 cron 方案: 当前核心 < v26.4.25, 不支持 Xray 内置 geodata)"
                _tip "更新到 ≥ v26.4.25 后会自动切换到 Xray 内置定时, 无需系统 cron"
                _success "Geo 自动更新已开启 (每月 1/4/7/.../31 号 03:00 执行)"
            else
                # 回滚刚写入的 crontab 行; 回滚失败要暴露, 不能静默
                if ! _geo_remove_cron_line >/dev/null 2>&1; then
                    _warn "crontab 回滚失败, 请手动检查项目定时任务 (${GEO_CRON_MARKER})"
                fi
                _warn "cron 守护进程未能启动, 自动更新已取消"
                _tip "请确保系统中有 cron 守护进程, 安装后重试"
                _state_set geo_cron "off"
            fi
            ;;
        off)
            # 移除失败**不得报成功**(2026-09-22 九轮 OCR #25)。
            # 旧写法忽略 `_geo_remove_cron_line` 的返回码就 `_state_set geo_cron "off"` +
            # `_success "已关闭"` —— 而这与同函数 `on)` 分支**自己**的回滚契约直接相反:
            # 那里在 `_ensure_cron_running` 失败时会先把 cron 行撤掉再置 off, 目的正是维持
            # `state=off ⇔ 项目 cron entry 不存在`。读不到/写不了 crontab 时旧写法会造出
            # "cron 行还在跑 + UI 说已关闭"的分裂, 而 cron 会在无人值守时继续执行本脚本。
            #
            # 处置与 `_geo_set_auto_update` 的 `off)` 分支**刻意不同**: 那里 config 才是真相源,
            # 残留 cron 行只是冗余清理, 失败只告警; 而**旧核心路径上 cron 行就是机制本身**,
            # 移除失败必须 fail 且**不**改 state(保持 on —— 那才是磁盘上的事实)。
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
# 启动自动操作(R45): 存量 geo_cron=on 部署迁移到 Xray 内置 geodata
# 场景: 旧脚本用系统 cron + state geo_cron=on 开启自动更新; 升级脚本后:
#   - 新核心(≥ v26.4.25)且 dat 齐备 → 写入 config geodata 段(不重启, 下次重启生效),
#     移除系统 cron 行与旧 state, 机制切换完成。
#   - 旧核心 → 保持系统 cron 机制不动(旧方案继续工作), 不迁移。
#   - config 已有 geodata.cron(已迁移过) → 仅清理残留 cron 行与旧 state。
# 幂等, 失败静默(启动路径不阻塞), 至多一条 _info。
# ---------------------------------------------------------------------------
_auto_migrate_geo_autoupdate() {
    [ "$(_state_get geo_cron 2>/dev/null)" = "on" ] || return 0
    local has_gd=0
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        has_gd=$(jq -r 'if (.geodata.cron // "") != "" then 1 else 0 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    fi
    if [ "$has_gd" = "1" ]; then
        _geo_remove_cron_line >/dev/null 2>&1
        _state_set geo_cron "off" 2>/dev/null || true
        return 0
    fi
    if [ -x "$XRAY_BIN" ] && _xray_version_ge "26.4.25" \
       && [ -f "$ASSET_DIR/geosite.dat" ] && [ -f "$ASSET_DIR/geoip.dat" ]; then
        local gd content
        gd=$(_geo_geodata_json) || return 0
        content=$(jq --argjson gd "$gd" '.geodata = $gd' "$CONFIG_FILE" 2>/dev/null) || return 0
        [ -n "$content" ] || return 0
        if _atomic_write_json "$CONFIG_FILE" "$content" 2>/dev/null; then
            _geo_remove_cron_line >/dev/null 2>&1
            _state_set geo_cron "off" 2>/dev/null || true
            _info "已迁移 Geo 自动更新到 Xray 内置定时($GEO_CRON_EXPR), 移除系统 cron, 下次重启生效"
        fi
    fi
}

_geo_remove_cron_line() {
    # 混装旧 lib(00-common 是旧版)时该函数不存在 —— 这是**写路径**, 按项目契约必须
    # 响亮拒绝并给出可执行提示, 而不是让 set -u/command-not-found 抛出晦涩错误,
    # 也绝不能退回旧的裸管道写法(读失败会清空用户全部 crontab)。
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 已跳过 crontab 清理"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    # 读失败 → 返回 1 且不改动 crontab(旧实现会清空用户全部定时任务, 详见 00-common 注释)
    _crontab_replace "$GEO_CRON_MARKER"
}

# ---------------------------------------------------------------------------
# 解析下次预计执行时间(回显用)
# 新机制: 读 config geodata.cron 原样显示; 旧机制: 从 crontab 行粗略推算
# ---------------------------------------------------------------------------
_geo_next_run_hint() {
    local c=""
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        c=$(jq -r '.geodata.cron // empty' "$CONFIG_FILE" 2>/dev/null)
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
# 两个写入动作(精简/恢复)共用 00-common 的 _config_edit_preflight
# (日志级别切换也用同一个, 校验口径必须一致 —— 见 R1.11 / R2.8)。
# 额外校验两个 00-common 常量非空: VPS 上存在"lib 部分更新"的混装状态(本模块是新版而
# 00-common 仍是旧版, CLAUDE.md 记录过多次)。裸引用会让 set -u 崩掉整个 TUI, 空值传给
# --argjson 又会产出难懂的 jq 报错; 这里前置判断给出可执行的提示。
# ---------------------------------------------------------------------------
_route_preflight() {
    _config_edit_preflight "修改路由规则" || return 1
    if [ -z "${XRAY_DEFAULT_ROUTING_RULES_JSON:-}" ] || [ -z "${XRAY_PRIVATE_BLOCK_RULE_JSON:-}" ] \
       || [ -z "${XRAY_PRIVATE_BLOCK_RULE_TAG:-}" ]; then
        _error "缺少默认规则常量(lib/00-common.sh 可能是旧版本), 无法修改路由规则"
        _tip "请在运维菜单执行 [检测脚本更新] 完整更新一次后重试"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 统计路由规则: "总数 geo引用数 节点(inboundTag)规则数 私网标记数" 单行输出
# 一次 jq 出四个数字: 低配机上每次 jq 都是一次 fork + 读整份 config, 不值得跑四遍。
# 读不到时输出 "0 0 0 0" 并返回 1(调用方据此显示"无法读取")。
# ---------------------------------------------------------------------------
_route_rules_stats() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ] || ! command -v jq >/dev/null 2>&1; then
        printf '0 0 0 0'
        return 1
    fi
    local out
    out=$(jq -r "
        [.routing.rules[]?] as \$r
        | [
            (\$r | length),
            ([\$r[] | select(${GEO_RULE_REF_JQ})] | length),
            ([\$r[] | select(.inboundTag? != null)] | length),
            ([\$r[] | select((.ruleTag? // null) == \"${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private}\")] | length)
          ] | @tsv" "$CONFIG_FILE" 2>/dev/null) || { printf '0 0 0 0'; return 1; }
    [ -n "$out" ] || { printf '0 0 0 0'; return 1; }
    # @tsv 用制表符分隔, 转成空格便于调用方 read -r 拆分
    printf '%s' "$out" | tr '\t' ' '
    return 0
}

# ---------------------------------------------------------------------------
# 统计 dns 段里的 geo 引用数(domains / expectedIPs / expectIPs)
# 本项目默认 DNS 段不含 geo 引用, 但用户手改过的配置可能有 —— 此时精简 routing
# 并不能完全免除 dat 加载, 必须如实告警, 否则用户会得到"照做了却没省内存"的错误结论。
# ---------------------------------------------------------------------------
_route_dns_geo_count() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ] || ! command -v jq >/dev/null 2>&1; then
        printf '0'
        return 1
    fi
    local n
    n=$(jq -r '
        [.dns?.servers[]? | select(type == "object")
         | (.domains? // [])[]?, (.expectedIPs? // [])[]?, (.expectIPs? // [])[]?]
        | map(select(type == "string")) | map(ltrimstr("!"))
        | map(select(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))
        | length' "$CONFIG_FILE" 2>/dev/null) || { printf '0'; return 1; }
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------------------
# 精简: 删除所有引用 geo 数据的规则, 注入等价的字面量 CIDR 私网 block 规则
#
# 顺序契约(关键): 私网规则必须插在"第一条无 inboundTag 的规则"之前。路由自上而下匹配
# (routing.md), tunnel 模式 Reality 节点的 2 条 inboundTag 规则必须保持在最前 ——
# 若私网 block 抢先命中, tunnel 入站到伪装站的握手流量会被切断(节点直接不可用)。
# 没有任何通用规则时(first 为 null)退化为追加到末尾。
#
# 幂等: 先按 ruleTag 剔除上一次注入的私网规则再重插, 故重复执行结果完全一致。
# 一律用"重建赋值" .routing.rules = [...] 而非 |= map(...): 后者在 routing:null 时
# 抛 "Cannot iterate over null"(jq 1.8.2 实测)。
#
# 两处对非对象规则元素的处理必须分清(手工编辑可能把某条规则写成裸字符串):
#   `(.ruleTag? // null) != "<tag>"` —— 必须带 `// null`。裸 `.ruleTag?` 对字符串元素
#     产出**空**, 于是 select 丢掉该元素, 精简会顺手删掉用户的坏规则(静默改动了我们
#     没被授权动的东西)。`// null` 把"取不到"变成 null, 使该元素被保留。
#   `.value.inboundTag? == null` —— 这里**不**补 `// null` 是刻意的: 空产出使非对象
#     元素不成为插入点, 私网规则因而落在第一条真正的"无 inboundTag 对象规则"之前,
#     顺序契约不受垃圾元素干扰。
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
# 恢复默认规则: 保留现存节点(inboundTag)规则, 其后接 00-common 的默认规则集
# 只保留 inboundTag 规则天然满足"节点规则在前 + 无重复", 且我们注入的私网规则
# (无 inboundTag)会被这一步自然丢弃。
# 显式写回 domainStrategy: 默认规则里的 geoip:cn 依赖 IPIfNonMatch 才能对域名目标生效。
# 已知取舍: 会丢弃用户手工添加的**非节点**自定义规则 —— 调用方必须在确认前明示。
# 注意 `.inboundTag?` 的 `?` 不可省: 手工编辑把某条规则写成非对象(如裸字符串)时,
# 无 `?` 的 `.inboundTag` 会让 jq 以 "Cannot index string with string" 整体失败,
# 于是"恢复默认规则"在最需要它的坏配置上反而不可用。
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
        local total=0 geo=0 node=0 mark=0 stats_ok=1
        local stats; stats=$(_route_rules_stats) || stats_ok=0
        # 2026-09-12 三审(L9): stats 失败时不读 —— read 对空输入会把上面初始化的 0 覆盖成空串,
        # 后续 [ "" -eq 0 ] 会打出 bash "integer expression expected" 噪音(条件恒假, 不致命但困惑)。
        [ "$stats_ok" -eq 1 ] && read -r total geo node mark <<< "$stats"
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
            if [ "$mark" -gt 0 ]; then
                echo -e "  私网防护:   ${GREEN}已注入字面量 CIDR${NC} (${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private})"
            else
                echo -e "  私网防护:   ${CYAN}未注入${NC}"
            fi
            local dnsgeo; dnsgeo=$(_route_dns_geo_count)
            if [ "$dnsgeo" -gt 0 ]; then
                echo
                _warn "dns 段还有 ${dnsgeo} 处 geo 引用, 精简路由规则不足以完全免除 dat 加载"
                _tip "如需彻底省内存, 请手工编辑 ${CONFIG_FILE} 的 dns 段去掉 geosite:/geoip:/ext: 引用"
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
                # 幂等: 已无 geo 引用且私网规则已在, 直接返回, 不触发 8 秒 verified-restart
                if [ "$geo" -eq 0 ] && [ "$mark" -gt 0 ]; then
                    _info "已是精简状态(无 geo 引用 + 私网防护已注入), 无需重复操作"
                    _press_any_key; continue
                fi
                echo
                echo -e "  将执行:"
                echo -e "    ${CYAN}删除${NC} ${geo} 条引用 geo 数据的规则"
                echo -e "    ${CYAN}注入${NC} 1 条字面量 CIDR 私网 block 规则(等价 geoip:private, 不加载 dat)"
                echo -e "    ${CYAN}保留${NC} ${node} 条节点规则(仍在最前) + bittorrent 拦截 + 域名白名单直连"
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
