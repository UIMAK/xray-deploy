#!/bin/bash
# =============================================================================
# lib/45-logrotate.sh — Xray 日志轮换管理
# 安装 Xray 时自动配置 logrotate(默认: daily / 保留7份 / compress)
# 菜单可开关/调频/调份数/调压缩
# copytruncate 硬编码开启(Xray 不响应 SIGHUP 重开日志)
# =============================================================================

# logrotate 配置文件路径
export LOGROTATE_CONF="/etc/logrotate.d/xray-deploy"

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
            *)
                _warn "无效选择"
                _press_any_key
                ;;
        esac
    done
}
