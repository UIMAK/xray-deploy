#!/bin/bash

export LOGROTATE_CONF="/etc/logrotate.d/xray-deploy"

# 标记仅记录因 none 自动关闭的因果；手动接管清除，自动恢复成功才消费。
LOGROTATE_AUTO_OFF_KEY="logrotate_off_by_loglevel"
# 用户禁用意图标记放在 include 目录下(见 _logrotate_user_off_path), 不用 state 键:
# 它要覆盖 state 存储不可写的场景, 写进同一存储会一起失败。

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

# 用户禁用意图标记: 记录"用户显式禁用, 但 enabled 状态写入失败"。
# 不能放 STATE_DIR —— 该标记要覆盖的正是 state 存储不可写的场景, 写进同一存储会一起失败。
# 改放 logrotate include 目录下被 logrotate 忽略的子目录(与配置同文件系统: 配置删除成功即可写),
# 保证 state 存储不可用时仍留下"用户已禁用"的事实, 避免 setup 复活轮换。
_logrotate_user_off_path() {
    printf '%s/.xray-deploy.tmp.d/disabled' "$(dirname "$LOGROTATE_CONF")"
}

_logrotate_user_off_get() {
    [ -f "$(_logrotate_user_off_path)" ] && printf 'on'
}

_logrotate_user_off_set() {
    local p d
    p=$(_logrotate_user_off_path)
    d=$(dirname "$p")
    mkdir -p "$d" 2>/dev/null || return 1
    : > "$p" 2>/dev/null || return 1
    # 回读确认标记真的落盘(inode 耗尽/目录不可写时 mkdir/写可能静默失败)。
    [ -f "$p" ]
}

_logrotate_user_off_clear() {
    local p
    p=$(_logrotate_user_off_path)
    rm -f "$p" 2>/dev/null
    # 与 _logrotate_auto_off_clear 同口径: 标记仍在即报告失败, 让调用方知道禁用意图未撤销。
    if [ -e "$p" ]; then
        return 1
    fi
    rmdir "$(dirname "$p")" 2>/dev/null || true
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

# 逐键初始化, enabled 作为哨兵最后写; 只补缺失键, 不覆盖仍存活的用户偏好。
# 部分损坏(仅哨兵丢失)时, 保留如 retention=14 的既有值, 不用默认值覆盖。
_logrotate_init_state() {
    [ -f "$STATE_DIR/logrotate_enabled" ] && return 0
    local rc=0
    [ -f "$STATE_DIR/logrotate_frequency" ] || _state_set logrotate_frequency "daily" || rc=1
    [ -f "$STATE_DIR/logrotate_retention" ] || _state_set logrotate_retention "7" || rc=1
    [ -f "$STATE_DIR/logrotate_compress" ]  || _state_set logrotate_compress "on" || rc=1
    if [ "$rc" -ne 0 ]; then
        _warn "logrotate 默认状态写入失败, 下次启动会重试"
        return 1
    fi
    # 哨兵最后写; 失败不删已写入的键(可能是用户偏好), 下次启动凭哨兵缺失重试。
    if ! _state_set logrotate_enabled "on"; then
        _warn "logrotate 默认状态写入失败(enabled 哨兵未落盘), 下次启动会重试"
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

# 有效启用态: 自动关闭标记优先于状态记录; 标记=on 时若配置仍在(上次禁用被中断的残留),
# 轮换实际还在跑, 按"在跑"处理, 状态栏与菜单共用同一口径。
# 用户禁用意图标记=on 且配置已删时同样按 off: 禁用时状态写失败不能让 setup 复活轮换。
_logrotate_effective_enabled() {
    if [ "$(_logrotate_auto_off_get)" = "on" ]; then
        if [ -f "$LOGROTATE_CONF" ]; then printf 'on'; else printf 'off'; fi
        return 0
    fi
    if [ "$(_logrotate_user_off_get)" = "on" ] && [ ! -f "$LOGROTATE_CONF" ]; then
        printf 'off'; return 0
    fi
    _logrotate_enabled_state
}

# 原子写: 在 include 目录下的临时子目录写入(目录不被 logrotate 读取), 回读一致后 rename 覆盖。
# 避免"截断→写入"窗口被并发 logrotate 读到半截配置而整轮失败, 也无需写失败后的还原流程。
_logrotate_write_config() {
    local content
    content=$(_logrotate_render_config) || {
        _error "生成 logrotate 配置内容失败"
        return 1
    }
    local conf_dir
    conf_dir=$(dirname "$LOGROTATE_CONF")
    if ! mkdir -p "$conf_dir"; then
        _error "无法创建 $conf_dir, logrotate 配置未写入"
        return 1
    fi
    # 目标是目录(或指向目录的符号链接)时 mv 会把临时文件搬进目录, 造成"提交成功"假象; 显式拒绝。
    if [ -d "$LOGROTATE_CONF" ]; then
        _error "logrotate 配置路径是目录, 无法写入配置: $LOGROTATE_CONF"
        return 1
    fi
    # 每次调用用唯一临时目录(mktemp): 并发会话各写各删自己的目录, 无共享目录竞态;
    # 子目录不被 logrotate 读取, 提交后删除不留残留。
    local tmp_dir
    if ! tmp_dir=$(mktemp -d "$conf_dir/.xray-deploy.tmp.XXXXXX" 2>/dev/null) || [ -z "$tmp_dir" ]; then
        _error "无法创建 logrotate 临时写入目录: $conf_dir"
        return 1
    fi
    local tmp_file="$tmp_dir/conf"
    if ! printf '%s\n' "$content" > "$tmp_file" 2>/dev/null; then
        _error "写入 logrotate 配置失败(只读文件系统/磁盘空间?): $tmp_file"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi
    local landed
    landed=$(cat "$tmp_file" 2>/dev/null)
    if [ "$landed" != "$content" ]; then
        _error "logrotate 配置写入不完整(磁盘空间?): $tmp_file"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi
    chmod 644 "$tmp_file" 2>/dev/null || true
    # rename 覆盖: 目标要么是旧内容要么是新内容, 不存在半截中间态。
    if ! mv -f "$tmp_file" "$LOGROTATE_CONF" 2>/dev/null; then
        _error "提交 logrotate 配置失败(rename): $LOGROTATE_CONF"
        rm -rf "$tmp_dir" 2>/dev/null
        return 1
    fi
    # 只删除本次调用自建的临时目录(此刻已空), 不触碰他方目录。
    rmdir "$tmp_dir" 2>/dev/null || true
    chmod 644 "$LOGROTATE_CONF" 2>/dev/null || \
        _warn "logrotate 配置权限设置失败(不影响轮换): $LOGROTATE_CONF"
    return 0
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
    # 启用即撤销此前的禁用意图; 残留标记会让配置缺失时被误判为已禁用, 清不掉按记账失败上报。
    if ! _logrotate_user_off_clear; then
        _warn "logrotate 配置已写入并生效, 但旧禁用标记未能清除(配置缺失时可能被误判为已禁用)"
        _tip "请手动删除 $(_logrotate_user_off_path)"
        return 2
    fi
    if ! _state_set logrotate_enabled "on"; then
        _warn "logrotate 配置已写入并生效, 但状态持久化失败(状态显示可能不准)"
        _tip "请重试本操作, 或检查 $STATE_DIR 是否可写"
        return 2
    fi
    return 0
}

_logrotate_disable() {
    # 先记录禁用意图再删配置: 意图写不进(如 inode 耗尽/目录不可写)就不能删,
    # 否则 setup 会凭 enabled=on 复活轮换, 且无任何标记可追溯。
    if ! _logrotate_user_off_set; then
        _error "无法记录 logrotate 禁用意图, 已取消禁用(配置未删除): $(_logrotate_user_off_path)"
        return 1
    fi
    _logrotate_remove_config || return 1
    if ! _state_set logrotate_enabled "off"; then
        _warn "logrotate 配置已移除(轮换已停), 但状态持久化失败(状态显示可能不准)"
        _tip "请重试本操作, 或检查 $STATE_DIR 是否可写"
        return 2
    fi
    _logrotate_user_off_clear
    return 0
}

# 状态初始化失败不写配置；默认猜测会造成状态与实际分裂。
_logrotate_setup() {
    _logrotate_ensure_package || return 0
    if ! _logrotate_init_state; then
        _warn "logrotate 状态初始化失败, 本次跳过配置写入(下次启动会重试)"
        return 0
    fi
    # 有效启用态统一判定: 自动关闭标记或用户禁用意图优先, 否则会把已关闭的轮换重新打开。
    if [ "$(_logrotate_effective_enabled)" = "on" ]; then
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
    _logrotate_user_off_clear
}

_logrotate_status() {
    local enabled freq ret comp
    enabled=$(_logrotate_effective_enabled)
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
    # 仅在实际已停(有效态 off)时才提示"被自动禁用"; 标记残留但配置仍在时轮换仍在跑, 否则自相矛盾。
    if [ "$(_logrotate_auto_off_get)" = "on" ] && [ "$enabled" = "off" ]; then
        echo -e "  ${SKYBLUE}(logrotate 因日志级别 none 被自动禁用, 切回其它级别会自动恢复)${NC}"
    fi
    if [ "$(_logrotate_user_off_get)" = "on" ] && [ "$enabled" = "off" ]; then
        echo -e "  ${SKYBLUE}(此前手动禁用时状态记录写入失败, 已按禁用保留; 选 [1] 会重新启用轮换而非修正该记录)${NC}"
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
    if [ "$new_lv" = "$cur" ]; then
        _info "已是 ${new_lv} 级别, 无需切换"
        _press_any_key; return
    fi

    # 联动禁用按"轮换是否实际在跑"判断: 标记=on 且配置仍在(上次禁用被中断的残留)时按启用处理,
    # 走下面的禁用流程把残留配置收敛掉, 与状态栏/菜单同口径。
    local enabled; enabled=$(_logrotate_effective_enabled)
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
        # 有效启用态统一走 _logrotate_effective_enabled: 标记=on 时不得再写回配置把轮换打开;
        # 但配置仍在(上次禁用被中断的残留)时轮换实际在跑, 必须给出禁用入口, 不能只显示"启用"。
        local enabled
        enabled=$(_logrotate_effective_enabled)
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
                    # 手动禁用即使状态写失败(trc=2)也已删配置: 显式禁用优先于自动成因标记,
                    # 保留标记会让之后切换日志级别时被自动恢复分支重新启用, 反转用户意图。
                    if [ "$trc" -ne 1 ] && [ "$(_logrotate_auto_off_get)" = "on" ]; then
                        _logrotate_auto_off_clear
                    fi
                else
                    _logrotate_enable || trc=$?
                    case "$trc" in
                        0) _success "logrotate 已启用" ;;
                        2) _warn "logrotate 轮换已生效, 但状态记录写入失败(状态显示可能不准)" ;;
                        *) _error "logrotate 启用失败, 日志轮换未生效" ;;
                    esac
                    # 只有启用完全成功(trc=0)才清标记: trc=1 失败、trc=2 状态未持久化时保留标记,
                    # 否则会重新制造"标记=on / enabled=on / 配置已删"的矛盾。
                    if [ "$trc" -eq 0 ] && [ "$(_logrotate_auto_off_get)" = "on" ]; then
                        _logrotate_auto_off_clear
                    fi
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
