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
# ---------------------------------------------------------------------------
_logrotate_init_state() {
    if [ ! -f "$STATE_DIR/logrotate_enabled" ]; then
        _state_set logrotate_enabled "on"
        _state_set logrotate_frequency "daily"
        _state_set logrotate_retention "7"
        _state_set logrotate_compress "on"
    fi
}

# ---------------------------------------------------------------------------
# 从 state 生成并写入 /etc/logrotate.d/xray-deploy
# ---------------------------------------------------------------------------
_logrotate_write_config() {
    local enabled freq ret comp
    enabled=$(_state_get logrotate_enabled 2>/dev/null || echo "on")
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

    mkdir -p /etc/logrotate.d
    cat > "$LOGROTATE_CONF" <<EOF
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
    # R38(M14): umask 077 会让配置生成为 0600; logrotate 读它时不受影响(root 运行),
    # 但系统集成文件按惯例给 644, 避免与其他工具/审计脚本产生困惑。
    chmod 644 "$LOGROTATE_CONF" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 删除 logrotate 配置文件
# ---------------------------------------------------------------------------
_logrotate_remove_config() {
    rm -f "$LOGROTATE_CONF"
}

# ---------------------------------------------------------------------------
# 首次安装/切换后自动配置(幂等)
# ---------------------------------------------------------------------------
_logrotate_setup() {
    _logrotate_ensure_package || return 0
    _logrotate_init_state
    local enabled
    enabled=$(_state_get logrotate_enabled 2>/dev/null || echo "on")
    if [ "$enabled" = "on" ]; then
        _logrotate_write_config
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 卸载时清理
# ---------------------------------------------------------------------------
_logrotate_cleanup() {
    _logrotate_remove_config
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
    enabled=$(_state_get logrotate_enabled 2>/dev/null || echo "未配置")
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

    echo -e "  状态: ${GREEN}${enabled}${NC}"
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

    local enabled; enabled=$(_state_get logrotate_enabled 2>/dev/null || echo "off")
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
    if [ "$new_lv" = "none" ]; then
        if [ "$enabled" = "on" ]; then
            # 先置标记再改状态: 标记写失败时不改 logrotate, 避免"关掉了却不知道是谁关的"
            if ! _state_set "$LOGROTATE_AUTO_OFF_KEY" "on"; then
                _warn "联动标记写入失败, 为避免状态不可追溯, 保持 logrotate 启用"
                _tip "如需关闭请在本菜单 [1] 手动禁用"
                _press_any_key; return
            fi
            if _state_set logrotate_enabled "off"; then
                _logrotate_remove_config
                _success "logrotate 已同步禁用"
            else
                _warn "logrotate 状态写入失败, 轮换配置未移除, 请在本菜单 [1] 手动禁用"
                _logrotate_auto_off_clear
            fi
        else
            _info "logrotate 当前已是禁用状态, 无需联动"
        fi
    elif [ "$auto_off" = "on" ]; then
        # 只恢复"我们自己关掉的那次"; 用户手动禁用时 auto_off 为空, 不会走到这里
        if _logrotate_ensure_package; then
            if _state_set logrotate_enabled "on"; then
                _logrotate_write_config
                _logrotate_auto_off_clear
                _success "logrotate 已自动恢复启用(此前因日志级别 none 被自动禁用)"
            else
                _warn "logrotate 状态写入失败, 请在本菜单 [1] 手动启用"
            fi
        else
            _warn "logrotate 包不可用, 未能自动恢复; 请安装后在本菜单 [1] 手动启用"
        fi
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
        enabled=$(_state_get logrotate_enabled 2>/dev/null || echo "off")
        if [ "$enabled" = "on" ]; then
            echo -e "  ${GREEN}[1]${NC} 禁用 logrotate"
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
                # 开关 toggle
                if [ "$enabled" = "on" ]; then
                    _state_set logrotate_enabled "off"
                    _logrotate_remove_config
                    _success "logrotate 已禁用"
                else
                    _logrotate_ensure_package || { _press_any_key; continue; }
                    _state_set logrotate_enabled "on"
                    _logrotate_write_config
                    _success "logrotate 已启用"
                fi
                # 手动开关即"用户接管了这个状态": 清掉联动标记, 使日后从 none 切回其它级别
                # 时不再自动改动它(标记的含义是"logrotate_enabled 的上一次变更是我们做的")
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
                [ "$new_freq" = "$cur_freq" ] && { _info "已是 ${new_freq}"; _press_any_key; continue; }
                _state_set logrotate_frequency "$new_freq"
                if [ "$enabled" = "on" ]; then
                    _logrotate_write_config
                fi
                _success "轮换频率已更新: ${new_freq}"
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
                [ "$new_ret" = "$cur_ret" ] && { _info "已是 ${new_ret} 份"; _press_any_key; continue; }
                _state_set logrotate_retention "$new_ret"
                if [ "$enabled" = "on" ]; then
                    _logrotate_write_config
                fi
                _success "保留份数已更新: ${new_ret}"
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
                _state_set logrotate_compress "$new_comp"
                if [ "$enabled" = "on" ]; then
                    _logrotate_write_config
                fi
                local comp_label="是"
                [ "$new_comp" = "off" ] && comp_label="否"
                _success "压缩已${comp_label}开启"
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
