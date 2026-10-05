#!/bin/bash

export LOGROTATE_CONF="/etc/logrotate.d/xray-deploy"

# 标记仅记录因 none 自动关闭的因果；手动接管清除，自动恢复成功才消费。
LOGROTATE_AUTO_OFF_KEY="logrotate_off_by_loglevel"

_logrotate_auto_off_get() {
    _state_get "$LOGROTATE_AUTO_OFF_KEY" 2>/dev/null
}

_logrotate_auto_off_clear() {
    rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY" 2>/dev/null
    if [ -e "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY" ]; then
        _warn "联动标记清除失败, 请手动删除 $STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
        return 1
    fi
    return 0
}

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

# 四键完整初始化，enabled 最后写；哨兵提前写会阻止失败后的重试。
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

# 统一读取为 on/off/unset；缺失记录不能猜成用户偏好。
_logrotate_enabled_state() {
    local v
    v=$(_state_get logrotate_enabled 2>/dev/null) || v=""
    case "$v" in
        on|off) printf '%s' "$v" ;;
        *)      printf 'unset' ;;
    esac
}

# 直写前保存旧内容，回读一致才成功；避免 include 目录临时配置与半截文件停摆。
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
    local prev="" had_prev=0
    if [ -f "$LOGROTATE_CONF" ]; then
        if ! prev=$(cat "$LOGROTATE_CONF" 2>/dev/null); then
            _error "无法读取现有 logrotate 配置, 为免破坏它已取消本次修改: $LOGROTATE_CONF"
            return 1
        fi
        had_prev=1
    fi
    if ! printf '%s\n' "$content" > "$LOGROTATE_CONF"; then
        _error "写入 logrotate 配置失败(只读文件系统/磁盘空间?): $LOGROTATE_CONF"
        _logrotate_restore_prev "$prev" "$had_prev"
        return 1
    fi
    local landed
    landed=$(cat "$LOGROTATE_CONF" 2>/dev/null)
    if [ "$landed" != "$content" ]; then
        _error "logrotate 配置写入不完整(磁盘空间?), 正在还原上一版配置"
        _logrotate_restore_prev "$prev" "$had_prev"
        return 1
    fi
    chmod 644 "$LOGROTATE_CONF" 2>/dev/null || \
        _warn "logrotate 配置权限设置失败(不影响轮换): $LOGROTATE_CONF"
    return 0
}

_logrotate_restore_prev() {
    local prev="$1" had_prev="$2"
    if [ "$had_prev" != "1" ]; then
        rm -f "$LOGROTATE_CONF" 2>/dev/null
        return 0
    fi
    if printf '%s\n' "$prev" > "$LOGROTATE_CONF" 2>/dev/null; then
        _warn "已还原上一版 logrotate 配置(参数变更未生效, 轮换仍按旧参数执行)"
        chmod 644 "$LOGROTATE_CONF" 2>/dev/null || true
        return 0
    fi
    _error "还原上一版 logrotate 配置失败: $LOGROTATE_CONF 可能不可用, 请手动检查"
    return 1
}

_logrotate_retention_digits() {
    local ret="$1"
    [[ "$ret" =~ ^0*([0-9]+)$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# 默认 daily/7/compress 且固定 copytruncate；Xray 不响应 SIGHUP 重开日志。
_logrotate_render_config() {
    local freq ret comp
    freq=$(_state_get logrotate_frequency 2>/dev/null || echo "daily")
    ret=$(_state_get logrotate_retention 2>/dev/null || echo "7")
    comp=$(_state_get logrotate_compress 2>/dev/null || echo "on")

    case "$freq" in
        daily|weekly|monthly) ;;
        *) freq="daily" ;;
    esac

    : "${ret:=7}"
    ret=$(_logrotate_retention_digits "$ret") || ret=7
    if [ "${#ret}" -gt 2 ]; then
        ret=30
    else
        ret=$((10#$ret))
        [ "$ret" -lt 1 ] && ret=1
        [ "$ret" -gt 30 ] && ret=30
    fi

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

# 同值跳过须同时匹配实际配置；否则写失败后无法重试。
_logrotate_config_in_sync() {
    [ -f "$LOGROTATE_CONF" ] || return 1
    local want got
    want=$(_logrotate_render_config) || return 1
    got=$(cat "$LOGROTATE_CONF" 2>/dev/null) || return 1
    [ "$want" = "$got" ]
}

_logrotate_remove_config() {
    rm -f "$LOGROTATE_CONF" 2>/dev/null
    if [ -e "$LOGROTATE_CONF" ]; then
        _error "无法删除 logrotate 配置(只读文件系统/文件被锁定?): $LOGROTATE_CONF"
        return 1
    fi
    return 0
}

# 先改配置再记账；rc 0=全部成功、1=文件失败、2=仅记账失败。
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

# 状态初始化失败不写配置；默认猜测会造成状态与实际分裂。
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

_logrotate_cleanup() {
    _logrotate_remove_config || _warn "卸载时未能删除 logrotate 配置, 请手动检查 $LOGROTATE_CONF"
    rm -f "$STATE_DIR"/logrotate_enabled
    rm -f "$STATE_DIR"/logrotate_frequency
    rm -f "$STATE_DIR"/logrotate_retention
    rm -f "$STATE_DIR"/logrotate_compress
    rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
}

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

    case "$enabled" in
        on)
            if [ -f "$LOGROTATE_CONF" ]; then
                echo -e "  状态: ${GREEN}on${NC}"
            else
                echo -e "  状态: ${YELLOW}on${NC} (${RED}但配置文件 ${LOGROTATE_CONF} 不存在, 轮换实际未生效${NC})"
                echo -e "  ${SKYBLUE}(在 [1] 里重新启用即可重写配置)${NC}"
            fi
            ;;
        off)
            if [ -f "$LOGROTATE_CONF" ]; then
                echo -e "  状态: ${RED}off${NC} (${YELLOW}但轮换配置仍存在, 实际生效中${NC})"
                echo -e "  ${SKYBLUE}(状态记录与实际不一致: 按一次 [1] 即可把记录修正为「已启用」与现状一致)${NC}"
            else
                echo -e "  状态: ${RED}off${NC}"
            fi
            ;;
        *)
            if [ -f "$LOGROTATE_CONF" ]; then
                echo -e "  状态: ${YELLOW}未记录(但轮换配置已存在, 实际生效中)${NC}"
            else
                echo -e "  状态: ${YELLOW}未配置${NC}"
            fi
            ;;
    esac
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

    if [ "$enabled" = "on" ] && { [ ! -f "$LOGROTATE_CONF" ] || ! _logrotate_config_in_sync; }; then
        echo -e "  ${YELLOW}⚠ 当前保存设置尚未完整写入 ${LOGROTATE_CONF}, logrotate 可能未按预期执行${NC}"
        echo -e "  ${SKYBLUE}(选择 [7] 重新应用当前保存设置即可重试)${NC}"
    fi

    if [ "$enabled" = "on" ] && [ -f "$LOGROTATE_CONF" ]; then
        local log_sz1 log_sz2
        log_sz1=$(du -sh "$LOG_DIR/access.log" 2>/dev/null | cut -f1)
        log_sz2=$(du -sh "$LOG_DIR/error.log" 2>/dev/null | cut -f1)
        [ -n "$log_sz1" ] && echo -e "  access.log: ${CYAN}${log_sz1}${NC}"
        [ -n "$log_sz2" ] && echo -e "  error.log:  ${CYAN}${log_sz2}${NC}"
    fi
}

# 先提交 confs/02_log.json 再联动轮换；none 同时停写 access/error（infra/conf/log.go）。
_loglevel_menu() {
    _config_edit_preflight "切换日志级别" || { _press_any_key; return; }
    if ! declare -F _xray_loglevel_get >/dev/null 2>&1 || ! declare -F _xray_loglevel_valid >/dev/null 2>&1; then
        _error "缺少日志级别读写函数(lib/20-xray-core.sh 可能是旧版本), 无法切换"
        _tip "请在主菜单执行 [检测脚本更新] 完整更新一次后重试"
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
    if ! _xray_loglevel_valid "$new_lv"; then
        _warn "无效日志级别: ${new_lv}"; _press_any_key; return
    fi
    if [ "$new_lv" = "$cur" ]; then
        _info "已是 ${new_lv} 级别, 无需切换"
        _press_any_key; return
    fi

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

    if ! _mutate_config --arg lv "$new_lv" '.log.loglevel = $lv'; then
        _error "日志级别切换失败(配置已回滚), logrotate 状态未变动"
        _press_any_key; return
    fi
    _success "日志级别已切换: ${cur} → ${new_lv}"

    if [ "$new_lv" = "none" ]; then
        if [ "$enabled" = "on" ]; then
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
        local erc=0
        _logrotate_enable || erc=$?
        case "$erc" in
            0)
                _logrotate_auto_off_clear
                _success "logrotate 已自动恢复启用(此前因日志级别 none 被自动禁用)"
                ;;
            2)
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
        if [ "$enabled" = "on" ] && [ -f "$LOGROTATE_CONF" ]; then
            echo -e "  ${GREEN}[1]${NC} 禁用 logrotate"
        elif [ "$enabled" = "on" ]; then
            echo -e "  ${GREEN}[1]${NC} 修复配置文件并重新应用已启用状态"
        elif [ "$enabled" = "off" ]; then
            echo -e "  ${GREEN}[1]${NC} 启用 logrotate"
        elif [ -f "$LOGROTATE_CONF" ]; then
            echo -e "  ${GREEN}[1]${NC} 修正状态记录为「已启用」(轮换配置已存在)"
        else
            echo -e "  ${GREEN}[1]${NC} 启用 logrotate"
        fi
        echo -e "  ${GREEN}[2]${NC} 轮换频率"
        echo -e "  ${GREEN}[3]${NC} 保留份数"
        echo -e "  ${GREEN}[4]${NC} 压缩"
        echo -e "  ${GREEN}[5]${NC} 查看配置文件"
        echo -e "  ${GREEN}[6]${NC} 日志级别 (loglevel, 小内存优化)"
        echo -e "  ${GREEN}[7]${NC} 重新应用当前保存设置"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0

        case "${choice:-0}" in
            0) return ;;
            1)
                local trc=0
                if [ "$enabled" = "on" ] && [ -f "$LOGROTATE_CONF" ]; then
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
                if [ "$(_logrotate_auto_off_get)" = "on" ]; then
                    _logrotate_auto_off_clear
                fi
                _press_any_key
                ;;
            2)
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
                if [ "$new_freq" = "$cur_freq" ]; then
                    if [ "$enabled" = "on" ] && ! _logrotate_config_in_sync; then
                        _warn "状态已是 ${new_freq}, 但 logrotate 配置尚未同步, 将重试写入"
                    else
                        _info "已是 ${new_freq}"; _press_any_key; continue
                    fi
                fi
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
                local cur_ret
                cur_ret=$(_state_get logrotate_retention 2>/dev/null || echo "7")
                echo
                echo -e "  当前保留份数: ${CYAN}${cur_ret}${NC}"
                read -rp "  请输入保留份数 (1-30, 回车取消): " new_ret
                [ -z "$new_ret" ] && { _info "已取消"; _press_any_key; continue; }
                : "${new_ret:=7}"
                local ret_digits
                ret_digits=$(_logrotate_retention_digits "$new_ret") || { _warn "请输入有效数字"; _press_any_key; continue; }
                [ "${#ret_digits}" -gt 2 ] && { _warn "最多保留 30 份"; _press_any_key; continue; }
                new_ret=$((10#$ret_digits))
                [ "$new_ret" -lt 1 ] && { _warn "最少保留 1 份"; _press_any_key; continue; }
                [ "$new_ret" -gt 30 ] && { _warn "最多保留 30 份"; _press_any_key; continue; }
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
                        _tip "选择 [7] 重新应用当前保存设置重试, 或检查 ${LOGROTATE_CONF} 是否可写"
                    fi
                else
                    _success "压缩已${comp_label}开启 (logrotate 当前禁用, 启用后生效)"
                fi
                _press_any_key
                ;;
            5)
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
                _loglevel_menu
                ;;
            7)
                if [ "$enabled" = "on" ]; then
                    local rrc=0
                    _logrotate_enable || rrc=$?
                    case "$rrc" in
                        0) _success "已重新应用当前保存的 logrotate 设置" ;;
                        2) _warn "设置已应用, 但状态持久化失败" ;;
                        *)
                            _error "重新应用设置失败, logrotate 配置未更新"
                            _tip "请检查 ${LOGROTATE_CONF} 是否可写后重试 [7]"
                            ;;
                    esac
                else
                    _warn "logrotate 当前未记录为启用, 未写入配置; 按 [1] 可主动启用"
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
