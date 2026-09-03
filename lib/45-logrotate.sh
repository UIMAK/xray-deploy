#!/bin/bash
# =============================================================================
# lib/45-logrotate.sh — Xray 日志轮换管理
# 安装 Xray 时自动配置 logrotate(默认: daily / 保留7份 / compress)
# 菜单可开关/调频/调份数/调压缩
# copytruncate 硬编码开启(Xray 不响应 SIGHUP 重开日志)
# =============================================================================

# logrotate 配置文件路径
export LOGROTATE_CONF="/etc/logrotate.d/xray-deploy"

# 「因日志级别切到 none 而自动禁用 logrotate」的联动标记(state 键名)
# 它记录的是**因果**, 不是用户偏好: 无法从 config.json 或 logrotate 配置反推
# "这次禁用是谁干的"。因此 _logrotate_init_state 绝不写它, 只有 _loglevel_menu 置/清。
# 作用: 从 none 切回有日志的级别时, 仅当该标记存在才自动重新启用 logrotate ——
# 用户自己手动禁用的 logrotate 不会被凭空打开。
LOGROTATE_AUTO_OFF_KEY="logrotate_off_by_loglevel"

# 读取联动标记(仅 "on" 视为置位)
_logrotate_auto_off_get() {
    _state_get "$LOGROTATE_AUTO_OFF_KEY" 2>/dev/null
}

# 清除联动标记。直接删文件(而非写空串)避免留下 0 字节 state 文件;
# rm -f 对不存在的文件返回 0, 故只在真的删不掉时告警 —— 不用 `|| true` 静默吞掉。
_logrotate_auto_off_clear() {
    rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY" 2>/dev/null
    if [ -e "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY" ]; then
        _warn "联动标记清除失败, 请手动删除 $STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 确保 logrotate 包已安装(幂等:已安装则跳过)
# ---------------------------------------------------------------------------
_logrotate_ensure_package() {
    command -v logrotate >/dev/null 2>&1 && return 0
    _info "安装 logrotate..."
    _pkg_install logrotate || {
        _warn "logrotate 安装失败, 日志轮换不可用"
        return 1
    }
    mkdir -p /etc/logrotate.d
    return 0
}

# ---------------------------------------------------------------------------
# 初始化 state(仅在 state 不存在时写默认值)
# 4 个键要么全写成、要么视为未初始化: 只写成一半会让后续 _logrotate_write_config
# 取到"部分默认 + 部分缺失", 而缺失键各自回落到函数内的硬编码默认 —— 表现为
# 状态页显示的参数与实际配置文件不一致。故任一失败即清掉已写的键, 下次启动重试。
# **logrotate_enabled 必须最后写**: 它是本函数的哨兵键(上面的 -f 判断读它)。
# 若先写它而后续键失败, 哨兵已存在, 初始化就永远不会重试。不要调换顺序。
# ---------------------------------------------------------------------------
_logrotate_init_state() {
    if [ ! -f "$STATE_DIR/logrotate_enabled" ]; then
        if _state_set logrotate_frequency "daily" \
           && _state_set logrotate_retention "7" \
           && _state_set logrotate_compress "on" \
           && _state_set logrotate_enabled "on"; then
            return 0
        fi
        _warn "logrotate 默认状态写入失败, 已回退(下次启动会重试)"
        rm -f "$STATE_DIR"/logrotate_enabled "$STATE_DIR"/logrotate_frequency \
              "$STATE_DIR"/logrotate_retention "$STATE_DIR"/logrotate_compress 2>/dev/null
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 读取 logrotate 启用状态。**所有调用点必须走这里, 不要各自写 `|| echo <某默认>`。**
# 复审 P2 的根因就是同一个 key 在不同位置有三种兜底解释(`on` / `off` / `未配置`),
# 于是"state 缺失"这一种情形被同一份代码读成互相矛盾的结论。
#
# 缺失一律解释为 "unset"(而非 on/off): 未初始化与用户显式关闭是两件事,
# 前者应触发初始化/告警, 后者应被尊重。调用方按需自行判断这三种取值。
# ---------------------------------------------------------------------------
_logrotate_enabled_state() {
    local v
    v=$(_state_get logrotate_enabled 2>/dev/null) || v=""
    case "$v" in
        on|off) printf '%s' "$v" ;;
        *)      printf 'unset' ;;
    esac
}

# ---------------------------------------------------------------------------
# 从 state 生成并写入 /etc/logrotate.d/xray-deploy
# 返回 0 仅当配置文件确实写成; 任一步失败返回 1 并清掉半截文件。
#
# 为什么不用 _atomic_write_json 那样的 "tmp -> mv" 原子替换:
#   tmp 必须与目标同目录才能保证 rename 原子, 而 /etc/logrotate.d 是 logrotate 的
#   include 目录 —— 遗留的 xray-deploy.XXXXXX 会被一并解析, 与正式文件形成
#   "duplicate log entry for .../access.log" 错误, 导致我们的日志**永久**不再轮换
#   (临时文件后缀不在 logrotate 的 tabooext 白名单里)。跨目录 mv 又不是原子操作。
#   而这里非原子的真实代价极小: logrotate 每天跑一次, 撞上毫秒级半写窗口时只是本次
#   跳过并报错, 下次即恢复; 与 config.json 半截会让 xray 起不来完全不是一个量级。
#   故取"直写 + 失败即删半截文件 + 严格传播失败", 不引入 include 目录里的临时文件。
#
# 渲染与写入分离(复审 4): 配置内容由 _logrotate_render_config 产出, 写入与
# "是否已同步"判定复用同一份渲染 —— 否则比对逻辑会与生成逻辑各自演化
# (同一项目里 GEO_RULE_REF_JQ 用同一判据供统计与过滤复用, 同一个道理)。
# ---------------------------------------------------------------------------

# 渲染应有的配置内容到 stdout(参数校验与生成的唯一来源)
_logrotate_render_config() {
    local freq ret comp
    freq=$(_state_get logrotate_frequency 2>/dev/null || echo "daily")
    ret=$(_state_get logrotate_retention 2>/dev/null || echo "7")
    comp=$(_state_get logrotate_compress 2>/dev/null || echo "on")

    # 验证 freq 值
    case "$freq" in
        daily|weekly|monthly) ;;
        *) freq="daily" ;;
    esac

    # 验证 ret 为数字 1-30
    : "${ret:=7}"
    [[ "$ret" =~ ^[0-9]+$ ]] || ret=7
    [ "$ret" -lt 1 ] && ret=1
    [ "$ret" -gt 30 ] && ret=30

    local compress_line="compress"
    [ "$comp" = "off" ] && compress_line="nocompress"

    cat <<EOF
# xray-deploy logrotate — managed by xd menu, do not edit manually
$LOG_DIR/access.log $LOG_DIR/error.log {
    $freq
    rotate $ret
    $compress_line
    copytruncate
    missingok
    notifempty
}
EOF
}

# ---------------------------------------------------------------------------
# 磁盘上的配置是否与 state 期望一致。
# 返回 0 = 已同步; 1 = 未同步(文件缺失 / 内容不同 / 读不出来)。
#
# 为什么需要它(复审 4 的 P2): 参数类变更(频率/份数/压缩)只能"先记账后落地"
# (_logrotate_render_config 从 state 读值), 故文件写失败会留下"state 新、文件旧"。
# 若菜单的"同值即跳过"只比 state, 用户拿到"配置文件更新失败"后**再选同一个值**会被
# 直接跳过, 永远不再重写 —— 除非绕道改成别的值再改回来。那就不是"可恢复的暂时分裂",
# 而是正常 UI 路径无法恢复。**同值跳过必须以"文件也已同步"为前提。**
#
# 注意: state 是"期望", 文件是"事实"。任何"无需操作"的判断都必须同时看这两侧。
# ---------------------------------------------------------------------------
_logrotate_config_in_sync() {
    [ -f "$LOGROTATE_CONF" ] || return 1
    local want got
    want=$(_logrotate_render_config) || return 1
    got=$(cat "$LOGROTATE_CONF" 2>/dev/null) || return 1
    [ "$want" = "$got" ]
}

_logrotate_write_config() {
    local content
    content=$(_logrotate_render_config) || {
        _error "生成 logrotate 配置内容失败"
        return 1
    }
    if ! mkdir -p /etc/logrotate.d; then
        _error "无法创建 /etc/logrotate.d, logrotate 配置未写入"
        return 1
    fi
    # 重定向失败(只读 fs / 磁盘满 / 目录缺失)必须显式判定 —— 裸 `cat > f` 之后若紧跟
    # `chmod ... || true`, 函数返回码会被洗成 0, 调用方据此把 state 置为"已启用"却没有
    # 配置文件, 形成 state/实际分裂(2026-09-03 PR #27 复审 P1)。
    if ! printf '%s\n' "$content" > "$LOGROTATE_CONF"; then
        _error "写入 logrotate 配置失败(只读文件系统/磁盘空间?): $LOGROTATE_CONF"
        rm -f "$LOGROTATE_CONF" 2>/dev/null
        return 1
    fi
    # 磁盘满时写入可能返回 0 却只落地 0 字节; 空配置对 logrotate 无意义, 视为失败
    if [ ! -s "$LOGROTATE_CONF" ]; then
        _error "logrotate 配置内容为空(磁盘空间?), 已删除: $LOGROTATE_CONF"
        rm -f "$LOGROTATE_CONF" 2>/dev/null
        return 1
    fi
    # R38(M14): umask 077 会让配置生成为 0600; logrotate 读它时不受影响(root 运行),
    # 但系统集成文件按惯例给 644, 避免与其他工具/审计脚本产生困惑。
    # 权限不对不影响 logrotate 工作(它以 root 读), 故只告警不判失败 —— 文件已经写成,
    # 因权限而回滚会把"轮换已生效"这个用户真正要的结果丢掉。
    chmod 644 "$LOGROTATE_CONF" 2>/dev/null || \
        _warn "logrotate 配置权限设置失败(不影响轮换): $LOGROTATE_CONF"
    return 0
}

# ---------------------------------------------------------------------------
# 删除 logrotate 配置文件
# 返回 0 仅当文件确实不存在了。rm -f 对"本来就没有"返回 0(幂等), 但只读 /etc、
# chattr +i、fs 错误时会真失败 —— 那时必须让调用方知道, 否则 state 会被置为
# "已禁用"而 logrotate 仍在轮换。
# ---------------------------------------------------------------------------
_logrotate_remove_config() {
    rm -f "$LOGROTATE_CONF" 2>/dev/null
    if [ -e "$LOGROTATE_CONF" ]; then
        _error "无法删除 logrotate 配置(只读文件系统/文件被锁定?): $LOGROTATE_CONF"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 启用 / 禁用 logrotate —— 三条路径(手动开关 / loglevel=none 自动禁用 /
# 切出 none 自动恢复)统一走这两个函数, 不再各自拼 _state_set + rm + cat。
#
# **返回码是三态, 因为"哪一步失败"决定调用方该做什么(复审 3 的 P2):**
#   0 = 文件动作成功 + state 记账成功
#   1 = **文件动作失败** —— 真实世界未改变(禁用时轮换仍在跑 / 启用时轮换未生效)
#   2 = **文件动作成功, 仅 state 记账失败** —— 真实世界已改变, 只是记录没写上
# 旧式 `if ! _logrotate_disable` 的调用点不受影响(任何非零仍算失败), 但需要区分
# 因果的调用点必须捕获具体 rc。
#
# 为什么不用调用方 `[ -e "$LOGROTATE_CONF" ]` 反推(复审建议的最小改法):
#   那是让每个调用点各自重新观察一次文件系统去猜"上一步为什么失败"。本函数有 2 个
#   调用点, 都得写同一份推断; 将来若多一个步骤, 推断会静默失效。这正是上一轮刚修掉的
#   "同一条件在各调用点各自解释"反模式(见 _logrotate_enabled_state 的注释)。
#   让函数**报告**原因, 而不是让调用方**猜**原因。代价只是多一个返回码常量。
#
# 顺序规则: **先做真实世界的动作, 再记账**(与 _geo_set_auto_update 一致:
# 先写 crontab 行, 最后才 _state_set)。理由是两种失败残局的代价不对称 ——
#   启用时若先置 state 再写文件, 写失败会留下"state=on 但没有配置文件":
#     用户以为日志在轮换, 实际磁盘会被撑满(这正是本功能要防的事)。
#   禁用时若先置 state 再删文件, 删失败会留下"state=off 但文件仍在":
#     logrotate 继续轮换而 UI 说已停 —— PR #27 复审 P1 指出的分裂。
# 反过来(动作先、记账后)失败时只是"显示滞后但实际行为符合用户意图", 且必定伴随告警。
#
# 与 _geo_set_auto_update 的差异: 那里 state 写失败会回滚 crontab 行, 因为遗留的
# cron entry 会**无人值守地执行本脚本**(重启服务等副作用)。这里遗留的只是一份
# logrotate 配置, 行为恰是用户刚刚要求的、也是安装时默认就会写的, 危害等级低得多;
# 为了 state 文件整洁而删掉用户要的轮换是坏交易。故不回滚, 只显式告警。
# ---------------------------------------------------------------------------
_logrotate_enable() {
    _logrotate_ensure_package || return 1
    _logrotate_write_config || return 1
    if ! _state_set logrotate_enabled "on"; then
        _warn "logrotate 配置已写入并生效, 但状态持久化失败(状态显示可能不准)"
        _tip "请重试本操作, 或检查 $STATE_DIR 是否可写"
        return 2
    fi
    return 0
}

_logrotate_disable() {
    _logrotate_remove_config || return 1
    if ! _state_set logrotate_enabled "off"; then
        _warn "logrotate 配置已移除(轮换已停), 但状态持久化失败(状态显示可能不准)"
        _tip "请重试本操作, 或检查 $STATE_DIR 是否可写"
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 首次安装/切换后自动配置(幂等)
# 返回 0 是"安装流程不因日志轮换而中断"的刻意设计(缺包/写失败只告警);
# 但写失败必须留下痕迹, 不能静默 —— 否则用户以为轮换已就绪而磁盘被慢慢撑满。
#
# **必须消费 _logrotate_init_state 的返回值(复审 P2)。** 否则:
#   init_state 半写失败 → 回退删掉全部 4 个键(含 enabled) → 这里读不到 enabled
#   → 旧代码 `|| echo "on"` 兜底成 on → 照样写出配置文件
#   ⇒ 残局是"logrotate 实际在轮换, 但 state 里没有 enabled 键", 而菜单侧把缺失
#     读成 off, 于是 UI 显示「启用 logrotate」而它其实已在工作。
# state 初始化失败时绝不能靠兜底默认继续写配置: 那等于用一个猜出来的值去做持久化动作。
# ---------------------------------------------------------------------------
_logrotate_setup() {
    _logrotate_ensure_package || return 0
    if ! _logrotate_init_state; then
        _warn "logrotate 状态初始化失败, 本次跳过配置写入(下次启动会重试)"
        return 0
    fi
    if [ "$(_logrotate_enabled_state)" = "on" ]; then
        _logrotate_write_config || _warn "logrotate 配置写入失败, 日志轮换未生效(可在菜单 [日志轮换] 重试)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 卸载时清理
# ---------------------------------------------------------------------------
_logrotate_cleanup() {
    _logrotate_remove_config || _warn "卸载时未能删除 logrotate 配置, 请手动检查 $LOGROTATE_CONF"
    rm -f "$STATE_DIR"/logrotate_enabled
    rm -f "$STATE_DIR"/logrotate_frequency
    rm -f "$STATE_DIR"/logrotate_retention
    rm -f "$STATE_DIR"/logrotate_compress
    # 联动标记必须一并清理: 残留标记会让卸载重装后的首次日志级别切换凭空打开 logrotate
    rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
}

# ---------------------------------------------------------------------------
# 打印当前配置摘要
# ---------------------------------------------------------------------------
_logrotate_status() {
    local enabled freq ret comp
    enabled=$(_logrotate_enabled_state)
    freq=$(_state_get logrotate_frequency 2>/dev/null || echo "daily")
    ret=$(_state_get logrotate_retention 2>/dev/null || echo "7")
    comp=$(_state_get logrotate_compress 2>/dev/null || echo "on")

    local freq_label
    case "$freq" in
        daily)   freq_label="每天" ;;
        weekly)  freq_label="每周" ;;
        monthly) freq_label="每月" ;;
        *)       freq_label="$freq" ;;
    esac

    # 状态行要能区分三种情形。尤其 "unset + 文件存在" 必须显式点出来:
    # 那正是复审 P2 的残局(实际在轮换但 state 里没有记录), 静默显示"未配置"
    # 会让用户以为轮换没开而不去处理。
    case "$enabled" in
        on)  echo -e "  状态: ${GREEN}on${NC}" ;;
        off) echo -e "  状态: ${RED}off${NC}" ;;
        *)
            if [ -f "$LOGROTATE_CONF" ]; then
                echo -e "  状态: ${YELLOW}未记录(但轮换配置已存在, 实际生效中)${NC}"
            else
                echo -e "  状态: ${YELLOW}未配置${NC}"
            fi
            ;;
    esac
    # 日志级别真相源是 config.json 的 log.loglevel(不另存 state, 避免第二份真相)。
    # declare -F 探测: 混装版本(20-xray-core 是旧版)时不显示该行, 而不是显示错误值。
    if declare -F _xray_loglevel_get >/dev/null 2>&1; then
        local lv; lv=$(_xray_loglevel_get 2>/dev/null)
        [ -n "$lv" ] || lv="warning"
        if [ "$lv" = "none" ]; then
            echo -e "  日志级别: ${YELLOW}${lv}${NC} (access/error 均不写入)"
        else
            echo -e "  日志级别: ${CYAN}${lv}${NC}"
        fi
    fi
    if [ "$(_logrotate_auto_off_get)" = "on" ]; then
        echo -e "  ${SKYBLUE}(logrotate 因日志级别 none 被自动禁用, 切回其它级别会自动恢复)${NC}"
    fi
    echo -e "  频率: ${CYAN}${freq_label}${NC}"
    echo -e "  保留: ${CYAN}${ret}${NC} 份"
    local comp_label="是"
    [ "$comp" = "off" ] && comp_label="否"
    echo -e "  压缩: ${CYAN}${comp_label}${NC}"

    # 状态页必须区分"期望"与"事实": state 是期望, /etc/logrotate.d 里的文件才是
    # logrotate 实际执行的参数。参数写失败会留下"state 新、文件旧", 若这里只回显 state,
    # 用户看到的是自己想要的值而非真实生效的值(复审 4)。
    if [ "$enabled" = "on" ] && [ -f "$LOGROTATE_CONF" ] && ! _logrotate_config_in_sync; then
        echo -e "  ${YELLOW}⚠ 上面的参数尚未同步到 ${LOGROTATE_CONF}, logrotate 仍按旧参数执行${NC}"
        echo -e "  ${SKYBLUE}(在 [2]/[3]/[4] 里再选一次同样的值即可重试写入)${NC}"
    fi

    if [ "$enabled" = "on" ] && [ -f "$LOGROTATE_CONF" ]; then
        local log_sz1 log_sz2
        log_sz1=$(du -sh "$LOG_DIR/access.log" 2>/dev/null | cut -f1)
        log_sz2=$(du -sh "$LOG_DIR/error.log" 2>/dev/null | cut -f1)
        [ -n "$log_sz1" ] && echo -e "  access.log: ${CYAN}${log_sz1}${NC}"
        [ -n "$log_sz2" ] && echo -e "  error.log:  ${CYAN}${log_sz2}${NC}"
    fi
}

# ---------------------------------------------------------------------------
# 日志级别切换(log.loglevel) + logrotate 联动
#
# 真相源: config.json 的 .log.loglevel(读写都经 _xray_loglevel_get / _mutate_config),
# **不新增 loglevel state 键** —— 项目有 service/config/state 三方分裂的历史教训。
#
# 提交顺序不可交换(config 先, logrotate 后):
#   _mutate_config 具备"备份 → 提交 → verified-restart → 失败回滚"的完整事务能力,
#   而 logrotate 侧(state + /etc/logrotate.d 文件)没有回滚。把不可回滚的一侧放到
#   可回滚一侧之后, config 提交失败时系统停在"配置已回滚 + logrotate 完全未动"的
#   一致状态, 不会出现"日志级别没变但轮换被关掉"的状态分裂。
#
# none 的真实语义: Xray-core/infra/conf/log.go 的 none 分支同时把 ErrorLogType 与
# AccessLogType 置为 None —— access 与 error 两个文件都停止写入(比 docs 表述更强),
# 所以必须在切换前明确告知用户, 并在 [查看日志] 侧给出提示。
# ---------------------------------------------------------------------------
_loglevel_menu() {
    _config_edit_preflight "切换日志级别" || { _press_any_key; return; }
    # 跨模块依赖(20-xray-core)。VPS 上可能是"本模块已更新而 20-xray-core 仍是旧版"的
    # 混装状态 —— 项目约定用 declare -F 探测并优雅降级(CLAUDE.md 跨模块章节)。不加这层,
    # 缺失的 _xray_loglevel_valid 会返回 127 让流程报"无效日志级别: warning", 提示误导。
    if ! declare -F _xray_loglevel_get >/dev/null 2>&1 || ! declare -F _xray_loglevel_valid >/dev/null 2>&1; then
        _error "缺少日志级别读写函数(lib/20-xray-core.sh 可能是旧版本), 无法切换"
        _tip "请在运维菜单执行 [检测脚本更新] 完整更新一次后重试"
        _press_any_key; return
    fi

    local cur; cur=$(_xray_loglevel_get)
    echo
    echo -e "  ${CYAN}【日志级别】${NC}"
    echo -e "  当前级别: ${CYAN}${cur}${NC}"
    echo -e "  ${YELLOW}小内存 VPS 建议 error 或 none: 级别越低写盘越少, debug/info 会快速堆积日志${NC}"
    echo
    echo -e "  ${GREEN}[1]${NC} debug   — 调试信息(含 info 全部内容, 最啰嗦)"
    echo -e "  ${GREEN}[2]${NC} info    — 运行状态信息(含 warning 全部内容)"
    echo -e "  ${GREEN}[3]${NC} warning — 默认级别(含 error 全部内容)"
    echo -e "  ${GREEN}[4]${NC} error   — 仅无法正常运行的问题"
    echo -e "  ${GREEN}[5]${NC} none    — 不记录任何日志(access/error 均停写)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    echo
    read -rp "  请选择: " choice
    local new_lv=""
    case "${choice:-0}" in
        0) _info "已取消"; _press_any_key; return ;;
        1) new_lv="debug" ;;
        2) new_lv="info" ;;
        3) new_lv="warning" ;;
        4) new_lv="error" ;;
        5) new_lv="none" ;;
        *) _warn "无效选择"; _press_any_key; return ;;
    esac
    # 双保险: 上面 case 已限定取值, 这里再过一遍白名单(防后续编辑漏掉某个分支)
    if ! _xray_loglevel_valid "$new_lv"; then
        _warn "无效日志级别: ${new_lv}"; _press_any_key; return
    fi
    if [ "$new_lv" = "$cur" ]; then
        _info "已是 ${new_lv} 级别, 无需切换"
        _press_any_key; return
    fi

    # 三态读法(on/off/unset)。unset 走 else 分支 = 不做联动:
    # state 没有记录时我们无从判断"是不是我们该关的那个", 猜一个默认再去动 logrotate
    # 正是复审 P2 的问题形态。真要处理请走菜单 [1] 手动开关(它会一并接管标记)。
    local enabled; enabled=$(_logrotate_enabled_state)
    local auto_off; auto_off=$(_logrotate_auto_off_get)

    if [ "$new_lv" = "none" ]; then
        echo
        _warn "none 级别下 access.log 与 error.log 都不再写入(Xray 核心行为), [查看日志] 将看不到新内容"
        if [ "$enabled" = "on" ]; then
            _tip "logrotate 将同步禁用(日志不再产生, 轮换已无意义); 切回其它级别时会自动恢复"
        fi
        read -rp "  确认切换为 none? [y/N]: " ans
        case "$ans" in
            y|Y) ;;
            *) _info "已取消"; _press_any_key; return ;;
        esac
    fi

    # ---- 第 1 步: 提交 config(可回滚)。失败即中止, logrotate 一步都不动 ----
    if ! _mutate_config --arg lv "$new_lv" '.log.loglevel = $lv'; then
        _error "日志级别切换失败(配置已回滚), logrotate 状态未变动"
        _press_any_key; return
    fi
    _success "日志级别已切换: ${cur} → ${new_lv}"

    # ---- 第 2 步: logrotate 联动(不可回滚, 故必须在 config 成功之后) ----
    # 严格失败语义: _logrotate_disable/_enable 返回三态(0 全成功 / 1 文件动作失败 /
    # 2 文件动作成功但 state 记账失败)。必须按 rc 分流 —— 两种失败对"联动标记该不该留"
    # 的答案是相反的(复审 3 的 P2):
    #   rc=1(轮换配置仍在, logrotate 实际还在跑) ⇒ 撤标记。留着会让下次切出 none 时
    #     去"恢复"一个从未真正关闭的 logrotate, 一个空操作被报成修复。
    #   rc=2(配置已删, logrotate 实际已停, 只是 state 没记上) ⇒ **保留标记**。它是
    #     "还欠一次恢复"的唯一记录; 若跟 rc=1 一样撤掉, 用户切回 error/warning 时就
    #     不会自动恢复 logrotate, 而 state 可能仍是 on ⇒ 又一种 state/实际分裂。
    if [ "$new_lv" = "none" ]; then
        if [ "$enabled" = "on" ]; then
            # 先置标记再动 logrotate: 标记是"这次禁用是我们做的"的唯一记录, 写不进去就
            # 不该动 logrotate —— 否则关掉了却无从得知该由谁恢复。
            if ! _state_set "$LOGROTATE_AUTO_OFF_KEY" "on"; then
                _warn "联动标记写入失败, 为避免状态不可追溯, 保持 logrotate 启用"
                _tip "如需关闭请在本菜单 [1] 手动禁用"
                _press_any_key; return
            fi
            local drc=0
            _logrotate_disable || drc=$?
            case "$drc" in
                0) _success "logrotate 已同步禁用" ;;
                2)
                    # 轮换确实停了, 仅 state 未写上。标记必须留 —— 否则切回其它级别时
                    # 不会自动恢复, 而 state 可能仍是 on(实际已停), 形成反向分裂。
                    _warn "logrotate 已实际停用, 但状态持久化失败(自动恢复标记已保留)"
                    _tip "请检查 ${STATE_DIR} 是否可写; 切回其它日志级别时会再尝试恢复"
                    ;;
                *)
                    _logrotate_auto_off_clear
                    _warn "logrotate 未能停用(轮换配置仍在), 日志级别已切为 none 但轮换可能继续"
                    _tip "请在本菜单 [1] 手动禁用, 或检查 ${LOGROTATE_CONF} 是否可删"
                    ;;
            esac
        else
            if [ "$enabled" = "off" ]; then
                _info "logrotate 当前已是禁用状态, 无需联动"
            else
                _warn "logrotate 状态未记录, 跳过联动禁用(不猜默认值去改系统状态)"
                _tip "如需关闭请在本菜单 [1] 手动禁用"
            fi
        fi
    elif [ "$auto_off" = "on" ]; then
        # 只恢复"我们自己关掉的那次"; 用户手动禁用时 auto_off 为空, 不会走到这里
        local erc=0
        _logrotate_enable || erc=$?
        case "$erc" in
            0)
                # 仅在完全成功后才清因果标记 —— 提前清掉会让失败后无从重试
                _logrotate_auto_off_clear
                _success "logrotate 已自动恢复启用(此前因日志级别 none 被自动禁用)"
                ;;
            2)
                # 轮换已恢复(配置已写), 只是 state 没记上。标记保留: 下次切换级别会
                # 再跑一遍 enable 把 state 补正, 那时才清标记。
                _warn "logrotate 轮换已恢复, 但状态持久化失败(标记已保留, 下次切换级别会补正)"
                _tip "请检查 ${STATE_DIR} 是否可写"
                ;;
            *)
                _warn "logrotate 未能自动恢复(标记已保留, 下次切换级别会再试)"
                _tip "也可在本菜单 [1] 手动启用"
                ;;
        esac
    fi
    _press_any_key
}

# ---------------------------------------------------------------------------
# 日志轮换管理子菜单
# ---------------------------------------------------------------------------
_logrotate_menu() {
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【日志轮换管理】${NC}"
        echo
        _logrotate_status
        echo
        local enabled
        enabled=$(_logrotate_enabled_state)
        # unset 与 off 在这里可以合并成同一个动作("启用"), 因为菜单是用户主动操作:
        # 无论此前是没记录还是显式关闭, 用户点了启用就该启用, 且 _logrotate_enable
        # 会把 state 一并写正。这与自动联动路径不同 —— 那里必须拒绝对 unset 动手。
        if [ "$enabled" = "on" ]; then
            echo -e "  ${GREEN}[1]${NC} 禁用 logrotate"
        elif [ "$enabled" = "off" ]; then
            echo -e "  ${GREEN}[1]${NC} 启用 logrotate"
        elif [ -f "$LOGROTATE_CONF" ]; then
            # 状态未记录但配置文件在: 提供"修正"入口, 走 enable 把 state 补写成 on
            echo -e "  ${GREEN}[1]${NC} 修正状态记录为「已启用」(轮换配置已存在)"
        else
            echo -e "  ${GREEN}[1]${NC} 启用 logrotate"
        fi
        echo -e "  ${GREEN}[2]${NC} 轮换频率"
        echo -e "  ${GREEN}[3]${NC} 保留份数"
        echo -e "  ${GREEN}[4]${NC} 压缩"
        echo -e "  ${GREEN}[5]${NC} 查看配置文件"
        echo -e "  ${GREEN}[6]${NC} 日志级别 (loglevel, 小内存优化)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice

        case "${choice:-0}" in
            0) return ;;
            1)
                # 开关 toggle —— 与联动路径共用 _logrotate_enable/_disable,
                # 因此"文件动作失败"在这里同样不会被谎报成功(PR #27 复审 P2)。
                # unset 视同 off(即执行启用): 菜单是用户主动操作, enable 会把 state 补正。
                # 同样按三态 rc 分流: rc=2 表示轮换已按用户意图改变、只是 state 没记上,
                # 报"已生效但状态未记录"比笼统报失败准确(后者会让用户误以为动作没做成)。
                local trc=0
                if [ "$enabled" = "on" ]; then
                    _logrotate_disable || trc=$?
                    case "$trc" in
                        0) _success "logrotate 已禁用" ;;
                        2) _warn "logrotate 轮换已停, 但状态记录写入失败(状态显示可能不准)" ;;
                        *) _error "logrotate 禁用失败, 轮换配置仍在生效" ;;
                    esac
                else
                    _logrotate_enable || trc=$?
                    case "$trc" in
                        0) _success "logrotate 已启用" ;;
                        2) _warn "logrotate 轮换已生效, 但状态记录写入失败(状态显示可能不准)" ;;
                        *) _error "logrotate 启用失败, 日志轮换未生效" ;;
                    esac
                fi
                # 手动开关即"用户接管了这个状态": 清掉联动标记, 使日后从 none 切回其它级别
                # 时不再自动改动它(标记的含义是"logrotate_enabled 的上一次变更是我们做的")。
                # 无论上面成功与否都清: 用户已经明确表达过意图, 自动化不该再覆盖它。
                if [ "$(_logrotate_auto_off_get)" = "on" ]; then
                    _logrotate_auto_off_clear
                fi
                _press_any_key
                ;;
            2)
                # 轮换频率
                local cur_freq
                cur_freq=$(_state_get logrotate_frequency 2>/dev/null || echo "daily")
                echo
                echo -e "  当前频率: ${CYAN}${cur_freq}${NC}"
                echo -e "  ${GREEN}[1]${NC} 每天 (daily)"
                echo -e "  ${GREEN}[2]${NC} 每周 (weekly)"
                echo -e "  ${GREEN}[3]${NC} 每月 (monthly)"
                echo -e "  ${GREEN}[0]${NC} 取消"
                echo
                read -rp "  请选择: " freq_choice
                local new_freq=""
                case "${freq_choice:-0}" in
                    0) continue ;;
                    1) new_freq="daily" ;;
                    2) new_freq="weekly" ;;
                    3) new_freq="monthly" ;;
                    *) _warn "无效选择"; _press_any_key; continue ;;
                esac
                # 同值跳过必须以"文件也已同步"为前提(复审 4 的 P2)。只比 state 会让
                # 上一次写失败后的重试路径被锁死: 用户拿到"配置文件更新失败", 再选同一个
                # 值却被"已是 X"直接跳过, 只能绕道改成别的值再改回来才能重写。
                if [ "$new_freq" = "$cur_freq" ]; then
                    if [ "$enabled" = "on" ] && ! _logrotate_config_in_sync; then
                        _warn "状态已是 ${new_freq}, 但 logrotate 配置尚未同步, 将重试写入"
                    else
                        _info "已是 ${new_freq}"; _press_any_key; continue
                    fi
                fi
                # 参数类变更只能"先记账后落地": _logrotate_render_config 是从 state 读值的,
                # 顺序反过来就写不出新值。因此这里的失败残局是"state 新、文件旧",
                # 必须如实报告 —— 报"已更新"会让用户以为新频率已生效(复审 P2 同类)。
                if ! _state_set logrotate_frequency "$new_freq"; then
                    _error "轮换频率写入状态失败, 未做任何变更"
                    _press_any_key; continue
                fi
                if [ "$enabled" = "on" ]; then
                    if _logrotate_write_config; then
                        _success "轮换频率已更新: ${new_freq}"
                    else
                        _error "轮换频率已记录为 ${new_freq}, 但配置文件更新失败, 轮换仍按旧参数执行"
                        _tip "请重试, 或检查 ${LOGROTATE_CONF} 是否可写"
                    fi
                else
                    _success "轮换频率已更新: ${new_freq} (logrotate 当前禁用, 启用后生效)"
                fi
                _press_any_key
                ;;
            3)
                # 保留份数
                local cur_ret
                cur_ret=$(_state_get logrotate_retention 2>/dev/null || echo "7")
                echo
                echo -e "  当前保留份数: ${CYAN}${cur_ret}${NC}"
                read -rp "  请输入保留份数 (1-30, 回车取消): " new_ret
                [ -z "$new_ret" ] && { _info "已取消"; _press_any_key; continue; }
                : "${new_ret:=7}"
                [[ "$new_ret" =~ ^[0-9]+$ ]] || { _warn "请输入有效数字"; _press_any_key; continue; }
                [ "$new_ret" -lt 1 ] && { _warn "最少保留 1 份"; _press_any_key; continue; }
                [ "$new_ret" -gt 30 ] && { _warn "最多保留 30 份"; _press_any_key; continue; }
                # 同上: 同值跳过必须以"文件也已同步"为前提, 否则写失败后无法直接重试
                if [ "$new_ret" = "$cur_ret" ]; then
                    if [ "$enabled" = "on" ] && ! _logrotate_config_in_sync; then
                        _warn "状态已是 ${new_ret} 份, 但 logrotate 配置尚未同步, 将重试写入"
                    else
                        _info "已是 ${new_ret} 份"; _press_any_key; continue
                    fi
                fi
                if ! _state_set logrotate_retention "$new_ret"; then
                    _error "保留份数写入状态失败, 未做任何变更"
                    _press_any_key; continue
                fi
                if [ "$enabled" = "on" ]; then
                    if _logrotate_write_config; then
                        _success "保留份数已更新: ${new_ret}"
                    else
                        _error "保留份数已记录为 ${new_ret}, 但配置文件更新失败, 轮换仍按旧参数执行"
                        _tip "请重试, 或检查 ${LOGROTATE_CONF} 是否可写"
                    fi
                else
                    _success "保留份数已更新: ${new_ret} (logrotate 当前禁用, 启用后生效)"
                fi
                _press_any_key
                ;;
            4)
                # 压缩开关
                local cur_comp
                cur_comp=$(_state_get logrotate_compress 2>/dev/null || echo "on")
                local new_comp
                if [ "$cur_comp" = "on" ]; then
                    new_comp="off"
                else
                    new_comp="on"
                fi
                if ! _state_set logrotate_compress "$new_comp"; then
                    _error "压缩开关写入状态失败, 未做任何变更"
                    _press_any_key; continue
                fi
                local comp_label="是"
                [ "$new_comp" = "off" ] && comp_label="否"
                if [ "$enabled" = "on" ]; then
                    if _logrotate_write_config; then
                        _success "压缩已${comp_label}开启"
                    else
                        _error "压缩已记录为「${comp_label}」, 但配置文件更新失败, 轮换仍按旧参数执行"
                        _tip "请重试, 或检查 ${LOGROTATE_CONF} 是否可写"
                    fi
                else
                    _success "压缩已${comp_label}开启 (logrotate 当前禁用, 启用后生效)"
                fi
                _press_any_key
                ;;
            5)
                # 查看配置文件
                echo
                if [ -f "$LOGROTATE_CONF" ]; then
                    echo -e "  ${CYAN}${LOGROTATE_CONF}:${NC}"
                    echo -e "  ${SKYBLUE}----------------------------------------${NC}"
                    cat "$LOGROTATE_CONF"
                    echo -e "  ${SKYBLUE}----------------------------------------${NC}"
                else
                    _warn "配置文件不存在 (logrotate 已禁用)"
                fi
                _press_any_key
                ;;
            6)
                # 日志级别(含 none 时的 logrotate 联动)
                _loglevel_menu
                ;;
            *)
                _warn "无效选择"
                _press_any_key
                ;;
        esac
    done
}
