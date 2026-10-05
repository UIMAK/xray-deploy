#!/bin/bash
# lib/90-menu.sh — 主菜单、事务恢复与协议子菜单。

# UTF-8 首字节决定列宽：ASCII/双字节 1、三/四字节 2、续字节 0；LC_ALL=C 固定判定。
_menu_display_width() {
    local s="$1" w=0 b
    for b in $(printf '%s' "$s" | LC_ALL=C od -An -tu1 -v 2>/dev/null); do
        if [ "$b" -ge 224 ]; then w=$((w + 2))
        elif [ "$b" -ge 192 ]; then w=$((w + 1))
        elif [ "$b" -ge 128 ]; then :
        else w=$((w + 1))
        fi
    done
    printf '%s' "$w"
}

# _menu_row 按纯文本显示宽度补齐，不计颜色；避免 printf 字节宽度造成错列。
MENU_COL_WIDTH=22
_menu_row() {
    local lnum="$1" lname="$2" rnum="${3:-}" rname="${4:-}"
    local pad ltxt="" rtxt=""
    pad=$((MENU_COL_WIDTH - $(_menu_display_width "  [${lnum}] ${lname}")))
    [ "$pad" -lt 1 ] && pad=1
    ltxt="  ${GREEN}[${lnum}]${NC} ${lname}"
    [ -n "$rnum" ] && rtxt="${GREEN}[${rnum}]${NC} ${rname}"
    # %b 解释颜色变量的字面转义，%s 会显示原文。
    printf '%b%*s%b\n' "$ltxt" "$pad" "" "$rtxt"
}

# 标题(居中)
_print_logo() {
    local title="Xray 部署管理脚本 (xray-deploy)"
    local display_w
    display_w=$(_menu_display_width "$title")
    local inner=$(( display_w + 8 ))
    [ "$inner" -lt 40 ] && inner=40
    local pad=$(( (inner - display_w) / 2 ))
    local left="" i
    for ((i=0; i<pad; i++)); do left="${left} "; done
    echo -e "  ${CYAN}${left}${title}${NC}"
}

# 状态栏
_print_status_bar() {
    # 系统
    local os_info="未知"
    [ -f /etc/os-release ] && os_info=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 | head -1)
    [ -z "$os_info" ] && os_info=$(uname -s)

    # Xray
    local xver="" xstatus="${RED}○ 未安装${NC}" xchannel=""
    if [ -x "$XRAY_BIN" ]; then
        local ver=""
        ver=$(_xray_cached_version 2>/dev/null)
        [ -n "$ver" ] && xver=" v${ver}"
        # 通道显示先净化再 echo -e，口径同 _print_status_bar，避免终端转义注入。
        xchannel=$(_sanitize_token "$(_state_get channel 2>/dev/null)") || xchannel="?"
        local st; st=$(_manage_xray status 2>/dev/null)
        if [ "$st" = "running" ]; then
            xstatus="${GREEN}● 运行中${NC}"
        else
            xstatus="${RED}○ 已停止${NC}"
        fi
    fi

    # 节点数
    local ncount; ncount=$(_node_count 2>/dev/null); [ -z "$ncount" ] && ncount=0

    # cloudflared
    local cfstatus="${RED}○ 未安装${NC}"
    if [ -x "$CF_BIN" ]; then
        if declare -F _cf_is_running >/dev/null 2>&1 && _cf_is_running; then
            cfstatus="${GREEN}● 运行中${NC}"
        else
            cfstatus="${YELLOW}○ 已安装(未运行)${NC}"
        fi
    fi

    # 官方 Hysteria2(独立于 Xray Hy2; 未安装时不显示, 不占状态栏空间)
    local hyline=""
    if [ -x "$HYSTERIA_BIN" ]; then
        local hver hst=""
        hver=$(_hysteria_cached_version 2>/dev/null)
        if [ "$(_manage_hysteria status 2>/dev/null)" = "running" ]; then
            hst="${GREEN}● 运行中${NC}"
        else
            hst="${RED}○ 已停止${NC}"
        fi
        hyline="  Hysteria2 v${hver#v}: ${hst}"
    fi

    # Geo(真相源: confs/14_geodata.json 的 geodata.cron, 兼容旧 state)
    local geostate; geostate=$(_geo_auto_state 2>/dev/null); [ -z "$geostate" ] && geostate="off"
    local geostr
    [ "$geostate" = "on" ] && geostr="${GREEN}● 自动${NC}" || geostr="${RED}○ 手动${NC}"

    echo -e "  系统: ${CYAN}${os_info}${NC}  |  init: ${CYAN}${INIT_SYSTEM}${NC}"
    echo -e "  Xray${CYAN}${xver}${NC} [${xchannel}]: ${xstatus}  |  节点: ${CYAN}${ncount}${NC}"
    echo -e "  cloudflared: ${cfstatus}  |  Geo: ${geostr}"
    [ -n "$hyline" ] && echo -e "$hyline"
    echo
}

# 节点类型检测(用于条件显示管理菜单)
_has_hy2_nodes() {
    [ -d "$NODES_DIR" ] || return 1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        [ "$(jq -r '.protocol' "$f" 2>/dev/null)" = "hysteria2" ] && return 0
    done
    return 1
}

_has_reality_nodes() {
    [ -d "$NODES_DIR" ] || return 1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        case "$proto" in *reality*) return 0 ;; esac
    done
    return 1
}

# _menu_require_tty 需要控制终端；stdin 非 tty 重挂 /dev/tty，不支持管道菜单输入。
# 组重定向保留 stderr；rc 0=终端可用，1=不可用。
_menu_require_tty() {
    [ -t 0 ] && return 0
    { exec </dev/tty; } 2>/dev/null && return 0
    return 1
}

# 主菜单
_main_menu() {
    # 先取得终端再恢复/迁移，避免交互 EOF；见 _menu_require_tty。
    if ! _menu_require_tty; then
        _error "无法进入交互菜单: 当前输入不是终端且无法打开 /dev/tty"
        _tip "请在交互式终端中运行 xd(或为 stdin 连接一个 tty)"
        exit 1
    fi
    # 启动链：reset → core → legacy → port → tag → adopt → env → geo。
    # reset/core 先分别恢复；任一失败阻塞 legacy 至 geo，legacy/port/tag/adopt 失败停止后续。
    RESET_RECOVERY_FAILED=0
    local reset_rc=0
    if declare -F _reset_config_recover >/dev/null 2>&1; then
        _reset_config_recover || reset_rc=$?
    fi
    if [ "$reset_rc" -ne 0 ]; then
        RESET_RECOVERY_FAILED=1
        _error "reset 事务未收敛(账本/快照已保留): 已跳过启动期维护, 并阻止配置修改类操作; 请处理后重启脚本"
    fi
    # core 恢复先于任何维护写入；运行态未知则停止链。
    CORE_RECOVERY_FAILED=0
    local core_rc=0
    if declare -F _xray_core_txn_recover >/dev/null 2>&1; then
        _xray_core_txn_recover || core_rc=$?
    fi
    if [ "$core_rc" -ne 0 ]; then
        CORE_RECOVERY_FAILED=1
        _error "Xray 核心事务未收敛(账本/恢复源已保留): 已跳过全部启动期 config 维护, 请处理后重启脚本"
    fi
    # legacy/port/tag/adopt 失败置阻塞，防止叠加写入。
    STARTUP_MAINT_BLOCKED=0
    if [ "$RESET_RECOVERY_FAILED" -ne 0 ] || [ "$CORE_RECOVERY_FAILED" -ne 0 ]; then
        STARTUP_MAINT_BLOCKED=1
    fi
    if [ "$STARTUP_MAINT_BLOCKED" -eq 0 ]; then
        # legacy 先于 port 恢复，确保旧部署 confs 的合并视图可读。
        if declare -F _config_migrate_legacy >/dev/null 2>&1; then
            if ! _config_migrate_legacy; then
                STARTUP_MAINT_BLOCKED=1
                _error "旧单文件配置迁移失败: 已停止后续启动维护, 请检查后重启脚本"
            fi
        fi
    fi
    if [ "$STARTUP_MAINT_BLOCKED" -eq 0 ]; then
        # port 恢复先于普通写入；未收敛账本会使写闸门拒绝。
        if declare -F _port_txn_recover >/dev/null 2>&1; then
            if ! _port_txn_recover; then
                STARTUP_MAINT_BLOCKED=1
                _error "端口事务恢复未收敛(未完成项已保留 journal/证据), 已停止后续启动维护"
            fi
        fi
    fi
    if [ "$STARTUP_MAINT_BLOCKED" -eq 0 ]; then
        if ! _auto_tag_tagless_inbounds; then
            STARTUP_MAINT_BLOCKED=1
            _error "启动期自动分配 inbound tag 失败(配置不可解析/写入失败): 已停止后续启动维护"
        fi
    fi
    if [ "$STARTUP_MAINT_BLOCKED" -eq 0 ]; then
        if ! _auto_adopt_orphans; then
            STARTUP_MAINT_BLOCKED=1
            _error "启动期自动采纳孤儿入站失败(配置不可解析/元数据写入失败): 已停止后续启动维护"
        fi
    fi
    if [ "$STARTUP_MAINT_BLOCKED" -eq 0 ]; then
        if declare -F _auto_ensure_config_env >/dev/null 2>&1; then _auto_ensure_config_env; fi
        if declare -F _auto_migrate_geo_autoupdate >/dev/null 2>&1; then _auto_migrate_geo_autoupdate; fi
    fi
    local choice

    while true; do
        clear
        _print_logo
        echo
        _print_status_bar

        echo -e "  ${CYAN}【节点管理】${NC}"
        _menu_row 1 "添加节点"      2 "查看节点"
        _menu_row 3 "删除节点"      4 "修改端口"
        _menu_row 5 "更新监听"      6 "Reality 域名管理"
        echo
        echo -e "  ${CYAN}【协议管理】${NC}"
        _menu_row 7 "Xray Hy2 管理" 8 "Hysteria2 管理"
        _menu_row 9 "cloudflared 管理"
        echo
        echo -e "  ${CYAN}【服务控制】${NC}"
        _menu_row 10 "重启 Xray"    11 "停止 Xray"
        _menu_row 12 "查看状态"     13 "查看日志"
        _menu_row 14 "日志轮换"     15 "定时重启"
        echo
        echo -e "  ${CYAN}【配置与更新】${NC}"
        _menu_row 16 "检查配置"     17 "DNS 设置"
        _menu_row 18 "Geo 自动更新" 19 "检测脚本更新"
        echo
        echo -e "  ${CYAN}【核心管理】${NC}"
        _menu_row 20 "Xray 核心管理" 21 "卸载"
        echo
        echo -e "  ${GREEN}[0]${NC} 退出"
        echo
        read -rp "  请选择: " choice || exit 0
        # 编号固定 1–21 与 0；新增末组追加，分组不改变调度。
        case "$choice" in
            1) _add_node; continue ;;
            2) _view_nodes; continue ;;
            3) _delete_node; continue ;;
            4) _modify_port; continue ;;
            5) _update_listen; continue ;;
            6) _reality_domain_menu; continue ;;
            7) _hy2_manage_menu; continue ;;
            8) _hysteria_menu; continue ;;
            9) _cloudflared_menu; continue ;;
            10) if _restart_xray_verified; then _success "已重启并稳定运行"; else _error "重启后 xray 未稳定运行, 请查看日志"; fi
                _press_any_key ;;
            11) _manage_xray stop; _success "已停止"; _press_any_key ;;
            12) _view_status ;;
            13) _view_log ;;
            14) _logrotate_menu ;;
            15) _timed_restart_menu ;;
            16) _check_config ;;
            17) _dns_menu ;;
            18) _geo_menu ;;
            19) _check_script_update ;;
            20) _xray_core_menu ;;
            21) _uninstall_menu ;;
            0) echo -e "${CYAN}再见${NC}"; exit 0 ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}

# 查看状态
_view_status() {
    clear
    echo
    echo -e "  ${CYAN}【运行状态】${NC}"
    local st; st=$(_manage_xray status 2>/dev/null)
    echo -e "  Xray: $([ "$st" = "running" ] && echo "${GREEN}运行中${NC}" || echo "${RED}已停止${NC}")"
    if [ -x "$XRAY_BIN" ]; then
        local ver="" ch
        ver=$(_xray_cached_version 2>/dev/null)
        [ -z "$ver" ] && ver="未知"
        # 通道显示先净化再 echo -e，口径同 _print_status_bar，避免终端转义注入。
        ch=$(_sanitize_token "$(_state_get channel 2>/dev/null)") || ch="?"
        echo -e "  版本: $([ "$ver" = "未知" ] && echo "$ver" || echo "v${ver}")  通道: ${ch}"
    fi
    echo -e "  节点数: $(_node_count)"
    case "$INIT_SYSTEM" in
        systemd)
            echo
            systemctl status xray --no-pager 2>/dev/null | head -8
            ;;
        openrc)
            echo
            rc-service xray status 2>/dev/null
            ;;
    esac
    _press_any_key
}

# 查看日志
_view_log() {
    clear
    echo
    # loglevel=none 只展示历史；缺 _xray_loglevel_get 时不阻断查看。
    if declare -F _xray_loglevel_get >/dev/null 2>&1 && [ "$(_xray_loglevel_get 2>/dev/null)" = "none" ]; then
        _warn "当前日志级别为 none: access.log 与 error.log 均已停止写入, 以下仅为历史内容"
        # 按菜单名称指路，避免编号依赖。
        _tip "如需恢复记录, 请到主菜单 [日志轮换] → [日志级别] 选择 error/warning 等级别"
        echo
    fi
    local logf="$LOG_DIR/error.log"
    [ -f "$logf" ] || logf="$LOG_DIR/access.log"
    if [ -f "$logf" ]; then
        echo -e "  ${CYAN}最近日志 ($logf):${NC}"
        tail -n 30 "$logf"
    else
        case "$INIT_SYSTEM" in
            systemd) journalctl -u xray --no-pager -n 30 2>/dev/null ;;
            openrc)  _warn "无日志文件, 请检查 $LOG_DIR" ;;
        esac
    fi
    _press_any_key
}

# 检查配置
_check_config() {
    clear
    echo
    if [ ! -x "$XRAY_BIN" ]; then _warn "Xray 未安装"; _press_any_key; return; fi
    if ! _config_present; then _warn "配置文件不存在"; _press_any_key; return; fi
    _info "运行 xray -test..."
    if _xray_test_config; then
        _success "配置校验通过"
    else
        _error "配置校验失败"
    fi
    _press_any_key
}

# cron 字段仅接受 *、N、N-M、*/S、N-M/S 及逗号列表；正步长在此校验，范围交 cron。
_cron_field_valid() {
    local f="$1" x
    [ -n "$f" ] || return 1
    case "$f" in ,*|*,|*,,*) return 1 ;; esac
    local -a _parts
    IFS=',' read -ra _parts <<< "$f"
    for x in "${_parts[@]}"; do
        [[ "$x" =~ ^(\*|[0-9]+)(-[0-9]+)?(/[0-9]+)?$ ]] || return 1
        # 步长必须正数；零步长属结构错误，不交给 cron 延迟拒绝。
        case "$x" in
            */0) return 1 ;;
            */0[0-9]*) return 1 ;;
        esac
    done
    return 0
}

_timed_restart_menu() {
    local choice
    clear
    echo; echo -e "  ${CYAN}【定时重启】${NC}"
    local state; state=$(_state_get timed_restart 2>/dev/null || echo "off")
    if [ "$state" != "off" ] && [ -n "$state" ]; then
        echo -e "  当前状态: ${GREEN}${state}${NC}"
    else
        echo -e "  当前状态: 未启用"
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 每 3 小时重启"
    echo -e "  ${GREEN}[2]${NC} 每 6 小时重启"
    echo -e "  ${GREEN}[3]${NC} 每 12 小时重启"
    echo -e "  ${GREEN}[4]${NC} 自定义 cron 表达式"
    echo -e "  ${GREEN}[5]${NC} 禁用定时重启"
    echo -e "  ${GREEN}[6]${NC} 查看日志"
    echo -e "  ${GREEN}[0]${NC} 返回"
    echo
    read -rp "  请选择: " choice
    local cron_line="" cron_expr=""
    local cmd_path; cmd_path=$(command -v "$CMD_NAME" 2>/dev/null || echo "/usr/local/bin/$CMD_NAME")
    local marker="# xray-deploy-timed-restart"
    case "${choice:-0}" in
        0) return ;;
        1) cron_expr="0 */3 * * *" ;;
        2) cron_expr="0 */6 * * *" ;;
        3) cron_expr="0 */12 * * *" ;;
        4)
            read -rp "  输入 cron 表达式 (如 30 3 * * *): " cron_expr
            [ -z "$cron_expr" ] && { _warn "表达式为空, 取消"; _press_any_key; return; }
            # cron 只验五字段结构和字符集，范围由 cron 解析。
            local -a _ce
            read -ra _ce <<< "$cron_expr"
            if [ "${#_ce[@]}" -ne 5 ]; then
                _warn "cron 表达式须为 5 个字段(分 时 日 月 周), 已取消"
                _press_any_key; return
            fi
            local _cw _bad=""
            for _cw in "${_ce[@]}"; do
                _cron_field_valid "$_cw" || _bad="$_cw"
            done
            if [ -n "$_bad" ]; then
                _warn "cron 字段无效: ${_bad}"
                _tip "每字段形如 * | N | N-M | */S | N-M/S | 逗号列表; 例如 0 */3 * * *"
                _press_any_key; return
            fi
            ;;
        5)
            _timed_restart_disable
            _press_any_key; return
            ;;
        6)
            _timed_restart_view_log
            _press_any_key; return
            ;;
        *) _warn "无效选择"; _press_any_key; return ;;
    esac
    [ -z "$cron_expr" ] && { _press_any_key; return; }
    cron_line="${cron_expr} ${cmd_path} timed-restart ${marker}"
    # 缺 _crontab_replace 拒绝写入，裸管道会将读失败变成清空。
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 无法写入 crontab"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        _press_any_key; return
    fi
    # 先确认 cron 能运行，再写任务。
    local cron_ok=0
    _ensure_cron_running && cron_ok=1
    # _crontab_replace 读失败 rc 1 且不动原任务。
    if ! _crontab_replace "$marker" "$cron_line"; then
        _error "写入 crontab 失败"
        _press_any_key; return
    fi
    mkdir -p "$STATE_DIR"
    if [ "$cron_ok" -eq 1 ]; then
        _state_set timed_restart "$cron_expr"
        _success "定时重启已设置: ${cron_expr}"
    else
        # 启用失败回滚新行；回滚不完整如实报告，不记 off。
        if ! _crontab_replace "$marker"; then
            # 行可能仍在，保留 state；见 _timed_restart_disable。
            _warn "crontab 回滚失败, 请手动检查项目定时任务 (${marker})"
            _tip "state 保持原值不变(未标记为已关闭), 以免与实际 cron 状态不符"
            _warn "cron 守护进程未能启动, 定时重启可能未完全取消"
            _press_any_key; return
        fi
        _warn "cron 守护进程未能启动, 定时重启已取消"
        _tip "请确保系统中有 cron 守护进程, 安装后重试"
        _state_set timed_restart "off"
    fi
    _press_any_key
}

# 禁用定时重启
_timed_restart_disable() {
    local marker="# xray-deploy-timed-restart"
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 无法清理 crontab"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    # _crontab_has_marker 区分存在/缺失/读失败，不能将读失败记为 off。
    local has_rc=0
    if declare -F _crontab_has_marker >/dev/null 2>&1; then
        _crontab_has_marker "$marker" || has_rc=$?
    else
        # 缺三态判据拒绝，不猜 off 或退回裸管道。
        _error "lib 版本过旧(00-common 缺 _crontab_has_marker), 无法确认定时任务状态"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    case "$has_rc" in
        2)
            # 读失败保留 state，不能推断任务已消失。
            _warn "无法读取 crontab, 定时重启任务是否仍在无法确认"
            _tip "state 保持原值不变(未标记为已关闭), 以免与实际 cron 状态不符"
            return 1 ;;
        0)
            # 删除失败立即返回，不把仍在的任务记 off。
            if ! _crontab_replace "$marker"; then
                _warn "定时重启任务未能移除, 请手动检查 crontab (${marker})"
                _tip "state 保持原值不变(未标记为已关闭), 以免与实际 cron 状态不符"
                return 1
            fi
            _success "定时重启已禁用" ;;
        *)
            _info "定时重启未启用" ;;
    esac
    # 只有"cron 行确实不在了"才记账(动作先、记账后)
    _state_set timed_restart "off"
}

# 查看定时重启日志
_timed_restart_view_log() {
    clear
    echo -e "  ${CYAN}【定时重启日志】${NC}"
    if [ -f "$LOG_DIR/timed-restart.log" ]; then
        echo
        tail -20 "$LOG_DIR/timed-restart.log"
    else
        _info "暂无日志"
    fi
}

# 顶层进程 helper：pidof 后补 /proc comm 扫描，避免容器假阴性。
_cf_fb_pids() {
    local pids p c
    pids=$(pidof cloudflared 2>/dev/null | tr ' ' '\n' | grep -e '^[0-9][0-9]*$')
    [ -n "$pids" ] && printf '%s\n' "$pids"
    for p in /proc/[0-9]*; do
        read -r c 2>/dev/null < "$p/comm" || continue
        [ "$c" = "cloudflared" ] && printf '%s\n' "${p#/proc/}"
    done
}

# 混装缺卸载 helper 的 cloudflared 兜底；以文件/进程事实判成功。
_uninstall_cloudflared_fallback() {
    if [ -x /usr/local/bin/cloudflared ]; then
        _info "卸载 cloudflared (fallback)..."
        /usr/local/bin/cloudflared service uninstall 2>/dev/null || true
        local pids
        pids=$(_cf_fb_pids)
        if [ -n "$pids" ]; then
            local pid
            for pid in $pids; do kill -15 "$pid" 2>/dev/null || true; done
            sleep 2
            pids=$(_cf_fb_pids)
            for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
            sleep 1
        fi
        case "$INIT_SYSTEM" in
            systemd)
                systemctl disable cloudflared 2>/dev/null || true
                rm -f /etc/systemd/system/cloudflared.service
                systemctl daemon-reload 2>/dev/null || true ;;
            openrc)
                rc-update del cloudflared default 2>/dev/null || true
                rm -f /etc/init.d/cloudflared ;;
        esac
        rm -f /usr/local/bin/cloudflared
        rm -f "$STATE_DIR"/cf_*
        # 校验 binary 消失且无进程；pidof 漏报由 _top_process_running 兜底。
        if [ -e /usr/local/bin/cloudflared ]; then
            _error "cloudflared 二进制删除失败, 请手动检查 /usr/local/bin/cloudflared"
            return 1
        fi
        # 同样验证文件/进程事实，见 _top_process_running。
        if [ -n "$(_cf_fb_pids)" ]; then
            _warn "cloudflared 文件已删除, 但仍有残留进程, 请手动确认"
            return 1
        fi
        _success "cloudflared 已卸载 (fallback)"
    else
        _warn "cloudflared 未安装"
    fi
}

# 卸载菜单
_uninstall_menu() {
    local choice
    clear
    echo
    echo -e "  ${RED}【卸载 / 重置】${NC}"
    echo -e "  ${GREEN}[1]${NC} 重置配置为默认(含 routing 规则, 清空节点)"
    echo -e "  ${GREEN}[2]${NC} 仅卸载 Xray"
    echo -e "  ${GREEN}[3]${NC} 卸载 Xray + cloudflared"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  选择: " choice
    # 整站卸载不可逆，执行前 y/N 确认。
    case "$choice" in
        1) _reset_config ;;
        2)
            read -rp "  确认卸载 Xray(删除配置/节点/证书/全部数据, 不可恢复)? [y/N]: " ans
            case "$ans" in y|Y) _uninstall_xray ;; *) _info "已取消" ;; esac
            ;;
        3)
            read -rp "  确认卸载 Xray + cloudflared(删除全部数据与隧道, 不可恢复)? [y/N]: " ans
            case "$ans" in
                y|Y)
                    # Xray 卸载 rc 1 报残留；cloudflared 独立，仍执行用户请求。
                    local xray_rc=0
                    _uninstall_xray || xray_rc=$?
                    if [ "$xray_rc" -ne 0 ]; then
                        _error "Xray 卸载未完成(见上方原因), 部署目录可能仍然存在, 请处理后重试"
                    fi
                    # 文件已删但进程仍在可返回 1，必须如实报告。
                    local cf_rc=0
                    if declare -F _uninstall_cloudflared >/dev/null 2>&1; then
                        _uninstall_cloudflared || cf_rc=$?
                    else
                        _uninstall_cloudflared_fallback || cf_rc=$?
                    fi
                    if [ "$cf_rc" -ne 0 ]; then
                        _error "cloudflared 卸载未完全成功(见上方原因), 请手动确认进程与文件已清理"
                    fi
                    ;;
                *) _info "已取消" ;;
            esac
            ;;
        0) return ;;
        *) _warn "取消" ;;
    esac
    _press_any_key
}

# reset 保留核心；backup/hop/config/metadata/restart 整体持 config lock，交互锁外。
_reset_config() {
    echo
    # 删除前确认 jq 重建能力，避免清空后无法生成配置。
    if ! command -v jq >/dev/null 2>&1; then
        _error "jq 不可用, 无法重建默认配置, 已取消重置"
        _tip "请先安装 jq(主菜单启动时也会自动尝试安装), 再执行重置"
        return 1
    fi
    if _config_present; then
        local ncount ans
        ncount=$(_node_count 2>/dev/null)
        echo -e "  ${YELLOW}当前有 ${ncount} 个节点, 重置将清空所有节点配置${NC}"
        read -rp "  确认清空并重置全部配置? [y/N]: " ans
        case "$ans" in
            y|Y) ;;
            *) _info "已取消"; return 0 ;;
        esac
    fi
    # 全站破坏性锁序 install → config → core，防卸载拆掉正在写的部署树。
    if declare -F _with_deploy_install_lock >/dev/null 2>&1; then
        _with_deploy_install_lock _with_config_lock _reset_config_locked
    else
        # 混装旧 lib 的兼容降级: 至少保留原 config 锁保护, 不退回裸执行。
        _with_config_lock _reset_config_locked
    fi
}

# reset：prepared → committed → runtime_verified，仅第三阶段清理。
# prepared 按事务快照回滚；committed 推进运行态不回滚。
# 快照/目录先落盘再 prepared，rename/phase 严格定向落盘。
_reset_journal_path() { printf '%s' "$DEPLOY_DIR/.reset-journal.json"; }
_reset_snapshot_path() { printf '%s' "$DEPLOY_DIR/.reset-snapshot"; }

_reset_fsync_strict() {
    local p="$1"
    [ -n "$p" ] || return 0
    # 定向 sync 失败不退裸 sync；仅 sync -f 可作为定向能力退路。
    if sync "$p" >/dev/null 2>&1; then return 0; fi
    if sync -f "$p" >/dev/null 2>&1; then return 0; fi
    _error "无法确认 reset 持久化屏障: $p"
    return 1
}

_reset_fsync_required() {
    _reset_fsync_strict "$1" || { _error "reset 持久化屏障失败: $1"; return 1; }
}

_reset_fsync_rename() {   # <source> <destination>
    local source="$1" destination="$2" source_dir destination_dir
    source_dir=$(dirname "$source")
    destination_dir=$(dirname "$destination")
    _reset_fsync_required "$destination" || return 1
    _reset_fsync_required "$source_dir" || return 1
    [ "$destination_dir" = "$source_dir" ] || _reset_fsync_required "$destination_dir"
}

_reset_journal_quarantine_exists() {
    local journal="$1" bad
    [ -e "${journal}.corrupt" ] && return 0
    for bad in "${journal}.corrupt."*; do
        [ -e "$bad" ] && return 0
    done
    return 1
}

_reset_journal_quarantine() {   # <journal> <原因>
    local journal="$1" why="$2" bad i=0 sync_failed=0
    bad="${journal}.corrupt"
    while [ -e "$bad" ]; do i=$((i+1)); bad="${journal}.corrupt.${i}"; done
    if mv "$journal" "$bad" 2>/dev/null; then
        _reset_fsync_required "$bad" || sync_failed=1
        _reset_fsync_required "$(dirname "$journal")" || sync_failed=1
        _warn "reset 事务日志${why}, 已隔离为 $bad; 快照保留在 $(_reset_snapshot_path) 供人工检查"
        [ "$sync_failed" -eq 0 ] || _warn "隔离标记持久化屏障失败, 恢复将继续 fail-closed"
    else
        _warn "reset 事务日志${why}且隔离失败, 请人工检查: $journal"
    fi
    return 1
}

# prepared 文件恢复只用事务私有快照；重置前无配置则恢复无配置，见 _reset_config_snapshot_restore。
_reset_config_snapshot_restore() {   # <stage> <nodes_moved> <clash_moved> <had_config>
    local stage="$1" nodes_moved="$2" clash_moved="$3" had_config="$4" ok=0 f content=""
    if [ "$had_config" -eq 1 ]; then
        if ls -1 "$stage/confs"/*.json >/dev/null 2>&1; then
            content=$(cat "$stage/confs"/*.json 2>/dev/null | jq -s 'reduce .[] as $o ({}; reduce ($o | to_entries[]) as $e (.; .[$e.key] = $e.value))') || content=""
            if [ -z "$content" ] || ! _config_write_merged "$content"; then
                _error "配置回滚失败, 请手动从快照副本恢复: $stage/confs"
                ok=1
            else
                for f in "$CONFIG_DIR"/*.json; do
                    [ -f "$f" ] || continue
                    _reset_fsync_required "$f" || ok=1
                done
                _reset_fsync_required "$CONFIG_DIR" || ok=1
            fi
        else
            # 私有副本缺失/空即 UNKNOWN，保留现场，不退共享 lastbak。
            _error "事务快照中的配置副本缺失或为空, 无法确认恢复源; 已保留现场供人工检查: $stage/confs"
            ok=1
        fi
    else
        if ! rm -rf "$CONFIG_DIR" 2>/dev/null || ! _reset_fsync_required "$DEPLOY_DIR"; then ok=1; fi
    fi
    if [ "$nodes_moved" -eq 1 ]; then
        if ! rm -rf "$NODES_DIR" 2>/dev/null; then
            ok=1
        elif ! mv "$stage/nodes" "$NODES_DIR" 2>/dev/null; then
            ok=1
        elif ! _reset_fsync_rename "$stage/nodes" "$NODES_DIR"; then
            ok=1
        fi
    fi
    if [ "$clash_moved" -eq 1 ]; then
        if ! rm -f "$CLASH_YAML" 2>/dev/null; then
            ok=1
        elif ! mv "$stage/clash.yaml" "$CLASH_YAML" 2>/dev/null; then
            ok=1
        elif ! _reset_fsync_rename "$stage/clash.yaml" "$CLASH_YAML"; then
            ok=1
        fi
    fi
    if [ "$ok" -eq 0 ]; then
        if ! rm -rf "$stage" 2>/dev/null || [ -e "$stage" ] || \
           ! _reset_fsync_required "$(dirname "$stage")"; then
            ok=1
        fi
    fi
    return "$ok"
}

# 写 reset 账本(唯一入口): 经 `_atomic_write_json` 落盘(fsync 文件 + 父目录)。
_reset_journal_write() {   # <journal> <snapshot> <phase> <had_json> <specs_json>
    local content
    content=$(jq -nc --arg snap "$2" --arg phase "$3" --argjson had "$4" --argjson specs "$5" \
        '{snapshot:$snap,phase:$phase,had_config:$had,hop_specs:$specs}') || return 1
    _atomic_write_json "$1" "$content" || return 1
    _reset_fsync_required "$1" || return 1
    _reset_fsync_required "$(dirname "$1")"
}

# 回补 journal 里记录的、本次 reset 已删除的端口跳跃规则(只补缺失项, 幂等)。
# reset 失败回滚与启动恢复共用; 无 hop_specs / 助手缺失时如实返回。
_reset_config_replay_hop_specs_locked() {   # <journal>
    local journal="$1" specs=() line
    [ -f "$journal" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && specs+=("$line")
    done <<< "$(jq -r '.hop_specs[]? // empty' "$journal" 2>/dev/null)"
    [ "${#specs[@]}" -gt 0 ] || return 0
    if ! declare -F _hy2_restore_hop_rules_checked >/dev/null 2>&1; then
        _error "缺少 hop 回滚助手, 无法恢复本次删除的端口跳跃规则; 请手动检查 iptables"
        return 1
    fi
    _hy2_restore_hop_rules_checked "${specs[@]}"
}

# 回滚 + 清 journal(仅回滚完整时才清账本); 不完整则保留 journal 与快照供启动期重试。
# 顺序: 先回补 iptables(读取 journal), 再还原文件, 最后删账本。
_reset_config_abort_locked() {   # <stage> <nodes_moved> <clash_moved> <had_config>
    local stage="$1" journal
    journal=$(_reset_journal_path)
    if ! _reset_config_replay_hop_specs_locked "$journal"; then
        _error "reset 回滚不完整(端口跳跃规则未全部恢复), 快照与事务日志保留供下次启动重试: $stage"
        return 1
    fi
    if ! _reset_config_snapshot_restore "$@"; then
        _error "reset 回滚不完整, 快照与事务日志保留供下次启动重试: $stage"
        return 1
    fi
    if ! rm -f "$journal" 2>/dev/null || ! _reset_fsync_required "$(dirname "$journal")"; then
        _warn "reset 事务日志清理未能持久化, 下次启动会自动收敛"
        return 1
    fi
    _warn "已回滚, 重置未生效: 配置与节点数据均保持原样"
    return 0
}

# 运行态收敛后 durable 写 runtime_verified 才清理；写失败保留 committed，清理失败保留 runtime_verified。
_reset_config_commit_finish_locked() {   # <journal> <snapshot> <had_json> <specs_json>
    if ! _reset_journal_write "$1" "$2" "runtime_verified" "$3" "$4"; then
        _warn "运行态已收敛, 但 runtime_verified 账本写入失败; 已保留 committed 账本与快照, 下次启动重试收敛"
        return 1
    fi
    if ! rm -rf "$2" 2>/dev/null || [ -e "$2" ]; then
        _warn "重置已应用且运行态已收敛, 但旧快照清理失败(下次启动会重试): $2"
        return 0
    fi
    if ! _reset_fsync_required "$(dirname "$2")"; then
        _warn "快照删除未能持久化, runtime_verified 账本保留供下次启动重试"
        return 1
    fi
    if ! rm -f "$1" 2>/dev/null; then
        _warn "reset 事务日志清理失败, 下次启动会自动清理"
        return 0
    fi
    if ! _reset_fsync_required "$(dirname "$1")"; then
        _warn "reset 事务日志删除未能持久化, 请重试恢复检查"
        return 1
    fi
    return 0
}

# 恢复同样按 install → config 取锁；无 journal/快照时纯读返回，避免无谓争用。
_reset_config_recover() {
    local journal; journal=$(_reset_journal_path)
    [ -e "$journal" ] || [ -e "$(_reset_snapshot_path)" ] || _reset_journal_quarantine_exists "$journal" || return 0
    if declare -F _with_deploy_install_lock >/dev/null 2>&1; then
        _with_deploy_install_lock _with_config_lock _reset_config_recover_locked
    else
        _with_config_lock _reset_config_recover_locked
    fi
}

_reset_config_recover_locked() {
    local journal snapshot phase had_config nodes_moved=0 clash_moved=0
    journal=$(_reset_journal_path)
    snapshot=$(_reset_snapshot_path)
    if _reset_journal_quarantine_exists "$journal"; then
        _warn "发现已隔离的损坏 reset 事务日志, 保留快照并拒绝启动维护: ${journal}.corrupt*"
        return 1
    fi
    if [ ! -e "$journal" ]; then
        # journal 缺失时快照无恢复权威，只清无账本残留。
        [ -e "$snapshot" ] && rm -rf "$snapshot" 2>/dev/null
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        # 没有 jq 不能把合法 journal 误判成损坏去隔离: 原样保留, 下次带 jq 启动再收敛。
        _warn "jq 不可用, 无法解析 reset 事务日志, 已跳过恢复(现场保留): $journal"
        return 1
    fi
    if ! jq -e . "$journal" >/dev/null 2>&1; then
        _reset_journal_quarantine "$journal" "无法解析"
        return 1
    fi
    phase=$(jq -r '.phase // empty' "$journal" 2>/dev/null)
    if [ "$(jq -r '.snapshot // empty' "$journal" 2>/dev/null)" != "$snapshot" ] || \
       { [ "$phase" != "prepared" ] && [ "$phase" != "committed" ] && [ "$phase" != "runtime_verified" ]; }; then
        _reset_journal_quarantine "$journal" "schema 非法"
        return 1
    fi
    # had_config 必须 boolean，hop_specs 必须 array；非法隔离保留证据，不猜默认值。
    if ! jq -e '(.had_config | type) == "boolean"' "$journal" >/dev/null 2>&1; then
        _reset_journal_quarantine "$journal" "had_config 缺失或非布尔"
        return 1
    fi
    had_config=$(jq -r 'if .had_config then 1 else 0 end' "$journal" 2>/dev/null)
    # hop_specs 为回放参数，仅接受同源双栈 PREROUTING 项，非法隔离保留证据。
    if ! jq -e '((.hop_specs | type) == "array") and all(.hop_specs[]; (type == "string") and test("^[46] -A PREROUTING .*xray-deploy-hy2-hop"))' \
        "$journal" >/dev/null 2>&1; then
        _reset_journal_quarantine "$journal" "hop_specs 缺失/非数组/形状非法"
        return 1
    fi
    if [ "$phase" = "committed" ] || [ "$phase" = "runtime_verified" ]; then
        local had_json2 specs_json2
        had_json2=$(jq -c '.had_config' "$journal" 2>/dev/null) || had_json2="false"
        specs_json2=$(jq -c '.hop_specs // []' "$journal" 2>/dev/null) || specs_json2="[]"
        # committed 先收敛运行态；runtime_verified 才可清理，见 _reset_config_commit_finish_locked。
        if [ "$phase" = "committed" ]; then
            if [ -x "$XRAY_BIN" ]; then
                # 有核心却缺 verified restart 能力即失败，不伪证 runtime_verified。
                if ! declare -F _restart_xray_verified >/dev/null 2>&1; then
                    _error "缺少 _restart_xray_verified, 无法验证 committed reset 的运行态; 账本与快照保留"
                    return 1
                fi
                if ! _restart_xray_verified; then
                    _warn "上次 reset 已提交但运行态未收敛(Xray 重启失败), 账本保留待下次启动重试"
                    return 1
                fi
                _info "上次 reset 的运行态已收敛(已按已提交配置重启)"
            else
                # 显式判定"没有运行态需要收敛"; 绝不靠 helper 缺失来推导这一分支。
                _info "未安装 Xray 核心, 本次 reset 无运行态需要收敛"
            fi
        fi
        # 收敛后写 runtime_verified 再清理; 写入或清理失败都保留账本供下次重试。
        if ! _reset_config_commit_finish_locked "$journal" "$snapshot" "$had_json2" "$specs_json2"; then
            _warn "reset 收尾未完成(runtime_verified 写入失败), 账本与快照保留: $journal"
            return 1
        fi
        [ "$phase" = "runtime_verified" ] && _info "上次 reset 已收敛, 已清理残留快照"
        return 0
    fi
    # (1) 先回补本次 reset 已删除的端口跳跃规则(幂等; 失败保留现场下次重试)。
    if ! _reset_config_replay_hop_specs_locked "$journal"; then
        _warn "上次 reset 崩溃后的回滚不完整(端口跳跃规则), 快照与 journal 保留供重试: $snapshot"
        return 1
    fi
    # 再还原文件；快照已消失不重复恢复，绝不猜 lastbak。
    if [ -d "$snapshot" ]; then
        [ -d "$snapshot/nodes" ] && nodes_moved=1
        [ -f "$snapshot/clash.yaml" ] && clash_moved=1
        if ! _reset_config_snapshot_restore "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"; then
            _warn "上次 reset 崩溃后的回滚不完整, 快照与 journal 保留供重试: $snapshot"
            return 1
        fi
    fi
    if ! rm -f "$journal" 2>/dev/null || ! _reset_fsync_required "$(dirname "$journal")"; then
        _warn "reset journal 清理未能持久化, 下次启动会继续收敛"
        return 1
    fi
    _warn "检测到上次 reset 未提交, 已回滚到重置前的配置与节点"
    return 0
}

_reset_config_locked() {
    local had_config=0 nodes_moved=0 clash_moved=0 snapshot journal had_json
    snapshot=$(_reset_snapshot_path)
    journal=$(_reset_journal_path)
    # 先收敛上一次崩溃的 reset(同锁内); 收敛失败(损坏/schema 非法/回滚不完整)时拒绝开新事务。
    if ! _reset_config_recover_locked; then
        _error "上次 reset 的残局未能收敛, 已取消本次重置(现场保留供人工检查)"
        return 1
    fi
    if _config_present; then
        had_config=1
        # 重置会清空节点；备份失败必须在删除前中止。
        if ! _backup_config; then
            _error "配置备份失败(磁盘空间/IO?), 已取消重置以保护现有数据"
            return 1
        fi
    fi
    if [ "$had_config" -eq 1 ]; then had_json=true; else had_json=false; fi
    # 恢复源与账本先落盘, 再动任何真实状态(包括 iptables): 崩溃时才有据可回滚。
    if [ -e "$snapshot" ] || ! mkdir "$snapshot" 2>/dev/null; then
        _error "无法创建 reset 恢复快照目录, 已取消重置以保护现有数据"
        return 1
    fi
    if ! _reset_fsync_required "$snapshot" || ! _reset_fsync_required "$(dirname "$snapshot")"; then
        _error "reset 恢复快照目录未能持久化, 已取消重置"
        rm -rf "$snapshot" 2>/dev/null
        return 1
    fi
    if [ "$had_config" -eq 1 ]; then
        # config 副本是比 lastbak 更可靠的恢复源(lastbak 会被后续任何配置事务覆盖)。
        if ! mkdir -p "$snapshot/confs" 2>/dev/null || ! cp -f "$CONFIG_DIR"/*.json "$snapshot/confs"/ 2>/dev/null \
           || ! ls -1 "$snapshot/confs"/*.json >/dev/null 2>&1; then
            _error "无法保存重置前的配置快照, 已取消重置以保护现有数据"
            rm -rf "$snapshot" 2>/dev/null
            return 1
        fi
        if ! _reset_fsync_required "$snapshot/confs"; then
            _error "reset 配置快照未能持久化, 已取消重置"
            rm -rf "$snapshot" 2>/dev/null
            return 1
        fi
    fi
    if ! _reset_fsync_required "$snapshot" || ! _reset_fsync_required "$(dirname "$snapshot")"; then
        _error "reset 快照目录内容未能持久化, 已取消重置"
        rm -rf "$snapshot" 2>/dev/null
        return 1
    fi
    # hop 候选先入 journal 再清理；枚举失败拒绝，空数组只表示确认无候选。
    local specs_json="[]" hop_specs="" cand_rc=0
    if declare -F _hy2_hop_cleanup_candidates >/dev/null 2>&1; then
        hop_specs=$(_hy2_hop_cleanup_candidates 2>/dev/null) || cand_rc=$?
        if [ "$cand_rc" -ne 0 ]; then
            _error "无法枚举待清理的端口跳跃规则(恢复源获取失败), 已取消重置以保护 metadata/runtime 一致性"
            rm -rf "$snapshot" 2>/dev/null
            return 1
        fi
        if [ -n "$hop_specs" ]; then
            if ! specs_json=$(printf '%s\n' "$hop_specs" | jq -R -s 'split("\n") | map(select(length > 0)) | unique' 2>/dev/null); then
                _error "无法序列化端口跳跃恢复源, 已取消重置以保护 metadata/runtime 一致性"
                rm -rf "$snapshot" 2>/dev/null
                return 1
            fi
        fi
    elif declare -F _hy2_cleanup_all_hops >/dev/null 2>&1; then
        # 有清理却无候选枚举能力则拒绝，防止无账本删除 hop。
        _error "lib 版本不匹配(缺 hop 恢复源枚举助手), 拒绝在无账本保护下执行端口跳跃清理"
        _tip "请先执行 install.sh --update 同步全部模块, 再重试重置"
        rm -rf "$snapshot" 2>/dev/null
        return 1
    fi
    if ! _reset_journal_write "$journal" "$snapshot" "prepared" "$had_json" "$specs_json"; then
        _error "无法写入 reset 事务日志(磁盘空间/权限?), 已取消重置以保护现有数据"
        rm -rf "$snapshot" 2>/dev/null
        return 1
    fi
    # 先清 hop 再删 config/metadata；失败按 journal 幂等回补，见 _reset_config_abort_locked。
    if declare -F _hy2_cleanup_all_hops >/dev/null 2>&1; then
        if ! _hy2_cleanup_all_hops; then
            _error "端口跳跃规则清理失败, 正在回滚本次重置"
            _reset_config_abort_locked "$snapshot" 0 0 "$had_config"
            return 1
        fi
    fi
    if [ -d "$NODES_DIR" ]; then
        # mv 成功才置 nodes_moved，失败不可恢复不存在的副本。
        if ! mv "$NODES_DIR" "$snapshot/nodes" 2>/dev/null; then
            _error "无法准备节点 metadata 恢复快照, 已取消重置以保护现有数据"
            _reset_config_abort_locked "$snapshot" 0 0 "$had_config"
            return 1
        fi
        nodes_moved=1
        if ! _reset_fsync_rename "$NODES_DIR" "$snapshot/nodes"; then
            _error "节点 metadata 快照移动未能持久化, 正在恢复重置前的快照"
            _reset_config_abort_locked "$snapshot" 1 0 "$had_config"
            return 1
        fi
        if ! mkdir -p "$NODES_DIR" 2>/dev/null; then
            _error "无法重建节点 metadata 目录, 正在恢复重置前的快照"
            _reset_config_abort_locked "$snapshot" 1 0 "$had_config"
            return 1
        fi
        if ! _reset_fsync_required "$NODES_DIR" || ! _reset_fsync_required "$(dirname "$NODES_DIR")"; then
            _error "新建节点 metadata 目录未能持久化, 正在恢复重置前的快照"
            _reset_config_abort_locked "$snapshot" 1 0 "$had_config"
            return 1
        fi
    fi
    if [ -f "$CLASH_YAML" ]; then
        if ! mv "$CLASH_YAML" "$snapshot/clash.yaml" 2>/dev/null; then
            _error "无法准备 clash 恢复快照, 已取消重置以保护现有数据"
            _reset_config_abort_locked "$snapshot" "$nodes_moved" 0 "$had_config"
            return 1
        fi
        clash_moved=1
        if ! _reset_fsync_rename "$CLASH_YAML" "$snapshot/clash.yaml"; then
            _error "clash 恢复快照移动未能持久化, 正在恢复重置前的快照"
            _reset_config_abort_locked "$snapshot" "$nodes_moved" 1 "$had_config"
            return 1
        fi
    fi
    # 清 confs 后重建；失败从事务快照回滚，不完整保留 journal。
    if ! rm -rf "$CONFIG_DIR" 2>/dev/null; then
        _error "无法删除旧配置目录, 已取消重置以保护现有数据"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    if ! _reset_fsync_required "$DEPLOY_DIR"; then
        _error "旧配置目录删除未能持久化, 正在恢复重置前的快照"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    if ! _init_config_if_empty; then
        _error "重建默认配置失败(只读/磁盘空间/jq 异常?), 正在回滚到重置前的配置"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    if ! _reset_fsync_required "$CONFIG_DIR" || ! _reset_fsync_required "$DEPLOY_DIR"; then
        _error "新配置未能持久化, 正在恢复重置前的快照"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    # 配置已确认重建成功; live metadata 目录已经是空目录, clash 重新落地也必须成功。
    if [ "$clash_moved" -eq 1 ] && \
       { ! printf 'proxies:\n' > "$CLASH_YAML" 2>/dev/null || [ ! -s "$CLASH_YAML" ]; }; then
        _error "清空 clash 派生配置失败, 正在回滚重置"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    if [ "$clash_moved" -eq 1 ] && \
       { ! _reset_fsync_required "$CLASH_YAML" || ! _reset_fsync_required "$(dirname "$CLASH_YAML")"; }; then
        _error "空 clash 配置未能持久化, 正在恢复重置前的快照"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    # committed durable 后不回滚；恢复先收敛运行态，再进入清理。
    if ! _reset_journal_write "$journal" "$snapshot" "committed" "$had_json" "$specs_json"; then
        _error "无法确认 reset committed 阶段已持久化; 保留 journal 与快照, 停止后续清理"
        return 1
    fi
    # restart+verified → durable runtime_verified → 清理；失败保留阶段与恢复源。
    if [ -x "$XRAY_BIN" ]; then
        if ! _restart_xray_verified; then
            _warn "重置已提交, 但 Xray 重启未通过验证; 事务日志保留, 下次启动会重试收敛"
            return 1
        fi
        _tip "xray 已使用新配置重启"
    fi
    if ! _reset_config_commit_finish_locked "$journal" "$snapshot" "$had_json" "$specs_json"; then
        # 运行态已收敛但账本未能推进: 保留 committed 账本与快照, 下次启动幂等重试。
        _warn "重置已应用且运行态已收敛, 但事务收尾未完成(runtime_verified 写入失败); 现场已保留"
        return 1
    fi
    _success "配置已重置(含 routing 规则), 节点已清空"
}

# 更新检查读取本地/远端 VERSION；XRAY_DEPLOY_RAW 为用户指定受信源。
# 非空/bash -n 只验证内容/语法，不证明来源；不引入下载哈希/签名机制。
SCRIPT_VERSION_URL="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}/VERSION"

# 外部版本/通道仅接受 [0-9A-Za-z._-]，避免 echo -e 解释转义；非法 rc 1，不剥字符伪造合法值。
_sanitize_token() {
    case "$1" in
        ''|*[!0-9A-Za-z._-]*) return 1 ;;
    esac
    printf '%s' "$1"
}

_check_script_update() {
    clear
    echo
    echo -e "  ${CYAN}【检测脚本更新】${NC}"
    local local_ver
    local_ver=$(cat "$DEPLOY_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')
    [ -z "$local_ver" ] && local_ver="(未知)"
    echo -e "  当前版本: ${CYAN}${local_ver}${NC}"
    _info "正在检查远程版本..."
    local remote
    remote=$(curl -fsSL --max-time 10 "$SCRIPT_VERSION_URL" 2>/dev/null) || \
    remote=$(wget -q -T 10 -O- "$SCRIPT_VERSION_URL" 2>/dev/null) || remote=""
    if [ -z "$remote" ]; then
        _warn "无法获取远程版本(网络受限或仓库未发布),请手动检查"
        _press_any_key; return
    fi
    remote=$(echo "$remote" | tr -d '[:space:]')
    # 外部版本必须整体合法，不能剥字符后误判最新版；见 _sanitize_token。
    if ! remote=$(_sanitize_token "$remote"); then
        _warn "远程版本内容异常(含非预期字符), 已忽略"
        _press_any_key; return
    fi
    echo -e "  远程版本: ${CYAN}${remote}${NC}"
    if [ "$remote" = "$local_ver" ]; then
        _success "已是最新版本"
    elif [ -n "$remote" ]; then
        _warn "发现新版本: ${remote}"
        read -rp "  是否立即更新? [y/N]: " ans
        case "$ans" in
            y|Y)
                _info "正在更新脚本..."
                # 先下载到临时文件并校验非空再执行, 避免网络失败时空脚本 bash 退出 0 谎报成功
                local updater
                updater=$(mktemp) || { _error "临时文件创建失败"; _press_any_key; return; }
                if ! _http_download "${SCRIPT_VERSION_URL%/VERSION}/install.sh" "$updater" 30 || [ ! -s "$updater" ]; then
                    rm -f "$updater"
                    _error "更新脚本下载失败(网络受限?), 当前版本未变动"
                    _press_any_key; return
                fi
                # 执行前 bash -n 只解析不执行，拒绝语法损坏/截断的安装脚本。
                if ! bash -n "$updater" 2>/dev/null; then
                    rm -f "$updater"
                    _error "更新脚本不完整或语法异常(下载被截断?), 当前版本未变动"
                    _press_any_key; return
                fi
                if bash "$updater" --update; then
                    rm -f "$updater"
                    _success "脚本已更新, 下次进菜单生效"
                    exit 0
                else
                    rm -f "$updater"
                    _error "更新失败, 当前版本未变动"
                fi
                ;;
            *) _info "已取消更新" ;;
        esac
    fi
    _press_any_key
}

# Hysteria2 管理子菜单
_hy2_manage_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【Xray Hy2 管理 (Xray-core 实现)】${NC}"
        # 无节点先提示并返回，不进入编辑。
        if ! _has_hy2_nodes; then
            echo -e "  ${YELLOW}暂无 Xray Hy2 节点${NC}"
        fi
        echo
        echo -e "  ${GREEN}[1]${NC} 切换拥塞控制 (bbr/brutal/force-brutal)"
        echo -e "  ${GREEN}[2]${NC} 调整 brutal 带宽"
        echo -e "  ${GREEN}[3]${NC} 端口跳跃 (iptables)"
        echo -e "  ${GREEN}[4]${NC} 查看端口跳跃状态"
        echo -e "  ${GREEN}[5]${NC} 混淆 salamander / gecko (FinalMask.udp)"
        # 标签区分 HTTP masquerade 与链路 FinalMask，二者独立。
        echo -e "  ${GREEN}[6]${NC} HTTP/3 伪装 masquerade (非 Hysteria 请求的 HTTP 页面)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1) _hy2_toggle_brutal ;;
            2) _hy2_adjust_bandwidth ;;
            3) _hy2_toggle_hop ;;
            4) _hy2_view_hop ;;
            5) _hy2_obfs_menu ;;
            6) _hy2_masq_menu ;;
            0) return ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}

# masquerade 为 HTTP 页面，与 FinalMask 链路字节独立；修改先确认真实入站。
# _hy2_select_node 成功输出 tag/失败 rc 1：数字 → 去前导零/限长 → 范围 → 减一。
# 长度门先于算术且用 10#，防回绕/负索引及八进制误选。
_hy2_select_node() {   # <choice> <tag1> [<tag2> ...]
    local c="${1:-}" idx
    shift || return 1
    idx=$(_xd_index_from_choice "$c" "$#") || return 1
    local -a tags=("$@")
    printf '%s' "${tags[$idx]}"
    return 0
}

_hy2_masq_menu() {
    local choice
    clear
    _has_hy2_nodes || { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    # masquerade 要求 v26.3.23，旧核心静默忽略该字段，必须先拒绝。
    if ! _hy2_masq_supported; then
        _error "当前核心不支持 masquerade 页面伪装(需 Xray >= v${_HY2_MASQ_MIN_VER})"
        _tip "旧核心会静默忽略该字段(伪装不生效且无任何报错); 请先升级/切换 Xray 核心"
        _press_any_key; return
    fi
    echo; echo -e "  ${CYAN}【HTTP/3 页面伪装 masquerade】${NC}"
    echo -e "  ${YELLOW}作用: 非 Hysteria 客户端(普通浏览器/扫描器)连上本端口时返回什么 HTTP 页面${NC}"
    echo -e "  ${YELLOW}与 [5] 混淆(FinalMask.udp)是两个独立机制 —— 混淆改链路上的 QUIC 字节, 本项改 HTTP 页面${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local tag name desc
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        desc=$(_hy2_masq_desc "$tag")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 当前: %s\n" "$i" "$name" "${desc:-默认 404 页面}"
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice || return 1
    [ "$choice" = "0" ] && return
    # 编号经 _hy2_select_node 限长/范围校验后再索引。
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; return; }

    # 入站必须真实存在于 config(见文件头注释: 否则 jq 0 命中而菜单报成功)
    _config_jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length > 0' >/dev/null 2>&1 \
        || { _error "配置中找不到该节点的入站(${tag}); 请先同步/修复配置"; _press_any_key; return; }

    while true; do
        local cur_desc
        cur_desc=$(_hy2_masq_desc "$tag")
        echo
        echo -e "  节点 ${CYAN}${tag}${NC} 当前: ${GREEN}${cur_desc:-默认 404 页面}${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 默认 404 (移除伪装段, 官方默认行为)"
        echo -e "  ${GREEN}[2]${NC} 文件伪装 (file: 从本地目录提供静态页面)"
        echo -e "  ${GREEN}[3]${NC} 反向代理到网站 (proxy)"
        echo -e "  ${GREEN}[4]${NC} 固定字符串 / HTML (string)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择: " choice || return 1
        case "${choice:-0}" in
            0) return 0 ;;
            1)
                if ! _hy2_masq_apply "$tag" ""; then
                    _error "恢复默认 404 失败, 已回滚原配置"; _press_any_key; continue
                fi
                _success "已恢复官方默认 404 页面"
                _press_any_key; return 0 ;;
            2) _hy2_masq_set_file "$tag" && return 0 ;;
            3) _hy2_masq_set_proxy "$tag" && return 0 ;;
            4) _hy2_masq_set_string "$tag" && return 0 ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}

# file 必答字段逐项重问，EOF rc 1；保留其它已确认输入。
_hy2_masq_set_file() {
    local tag="$1" dir why payload
    echo
    echo -e "  ${CYAN}文件伪装${NC}: 核心以 ${CYAN}http.FileServer${NC} 从该目录提供静态文件"
    echo -e "  ${YELLOW}请求路径直接映射到目录内文件(如 / → index.html, /a.css → <目录>/a.css)${NC}"
    echo -e "  ${YELLOW}输入 0 可取消${NC}"
    while true; do
        read -rp "  静态文件目录 (绝对路径, 如 /var/www/html): " dir || return 1
        [ "$dir" = "0" ] && { _info "已取消"; return 1; }
        why=$(_hy2_masq_dir_invalid "$dir")
        [ -z "$why" ] && break
        _error "目录非法: ${why}"
    done
    if [ ! -d "$dir" ]; then
        # 警告而非拒绝: 目录可以稍后创建, 且核心只在实际收到请求时才读它。
        _warn "目录当前不存在: ${dir}(请自行创建并放入 index.html, 否则请求会得到 404/403)"
    fi
    payload=$(_hy2_masq_json_file "$dir") || { _error "伪装参数构造失败"; _press_any_key; return 1; }
    if ! _hy2_masq_apply "$tag" "$payload"; then
        _error "文件伪装设置失败, 已回滚原配置"; _press_any_key; return 1
    fi
    _success "已启用文件伪装: ${dir}"
    _tip "请确认 xray 进程对该目录有读权限(建议 chmod 755), 否则请求会返回 403"
    _press_any_key
    return 0
}

# proxy 为扁平 url/rewriteHost/insecure 模型，不照抄官方 Hysteria 嵌套形状。
_hy2_masq_set_proxy() {
    local tag="$1" url why ans rh="true" ins="false" xf="false" payload
    echo
    echo -e "  ${CYAN}反向代理${NC}: 把非 Hysteria 请求转发到目标站点(核心 httputil.ReverseProxy)"
    echo -e "  ${YELLOW}支持 http:// / https:// / unix://绝对路径(Unix socket)${NC}"
    echo -e "  ${YELLOW}输入 0 可取消${NC}"
    while true; do
        read -rp "  目标 URL (如 https://example.com 或 unix:///run/site.sock): " url || return 1
        [ "$url" = "0" ] && { _info "已取消"; return 1; }
        why=$(_hy2_masq_url_invalid "$url")
        [ -z "$why" ] && break
        _error "URL 非法: ${why}"
    done
    # 布尔非法值重问，只有空输入取默认。
    while true; do
        read -rp "  转发时用目标站点的 Host 头? [Y/n]: " ans || return 1
        case "$ans" in
            ""|y|Y) rh="true"; break ;;
            n|N) rh="false"; break ;;
            *) _error "无效输入: ${ans}(请输入 y 或 n, 直接回车 = Y)" ;;
        esac
    done
    if [ "$rh" = "false" ]; then
        _tip "保留原始 Host: 目标站点看到的是你的域名/IP 而非它自己的(虚拟主机可能不匹配)"
    fi
    if [ "${url#https://}" != "$url" ]; then
        while true; do
            read -rp "  跳过目标站点证书校验(insecure)? [y/N]: " ans || return 1
            case "$ans" in
                ""|n|N) ins="false"; break ;;
                y|Y) ins="true"; break ;;
                *) _error "无效输入: ${ans}(请输入 y 或 n, 直接回车 = N)" ;;
            esac
        done
        [ "$ins" = "true" ] && _warn "已跳过目标站点证书校验(仅在自签/证书不匹配时需要)"
    fi
    # xForwarded 仅 >= v26.9.8 支持; 门控通过时才问, 避免让用户选一个会被静默忽略的开关
    if _hy2_masq_unix_supported; then
        while true; do
            read -rp "  回源时补发 X-Forwarded-For/-Proto/-Host? [y/N]: " ans || return 1
            case "$ans" in
                ""|n|N) xf="false"; break ;;
                y|Y) xf="true"; break ;;
                *) _error "无效输入: ${ans}(请输入 y 或 n, 直接回车 = N)" ;;
            esac
        done
        [ "$xf" = "true" ] && _tip "已开启 X-Forwarded-*: 目标站点会看到真实客户端 IP(隐私相关, 仅在确知需要时开启)"
    fi
    payload=$(_hy2_masq_json_proxy "$url" "$rh" "$ins" "$xf") || { _error "伪装参数构造失败"; _press_any_key; return 1; }
    if ! _hy2_masq_apply "$tag" "$payload"; then
        _error "反向代理设置失败, 已回滚原配置"; _press_any_key; return 1
    fi
    _success "已启用反向代理: ${url}"
    _press_any_key
    return 0
}

# string 逐行以单独 . 结束；有内容 EOF 完成，无内容 EOF 取消；headers 可选逐行收集。
_hy2_masq_set_string() {
    local tag="$1" content="" line why sc hdr_json='{}' merged payload nl got_dot
    nl=$'\n'
    echo
    echo -e "  ${CYAN}固定字符串${NC}: 对任意请求返回同一份内容(适合放一段伪装的 HTML)"
    echo -e "  ${YELLOW}逐行输入内容(可多行), 单独一行输入 . 表示结束${NC}"
    while true; do
        content=""; got_dot=0
        while IFS= read -r line; do
            [ "$line" = "." ] && { got_dot=1; break; }
            content="${content}${line}${nl}"
        done
        content="${content%${nl}}"
        [ -n "$content" ] && break
        if [ "$got_dot" -eq 0 ]; then
            _error "未收到任何内容(输入已结束), 已取消本项"
            return 1
        fi
        _error "内容不能为空(至少输入一行, 再用单独一行 . 结束)"
    done
    while true; do
        read -rp "  HTTP 状态码 (3 位, 回车用核心默认 200): " sc || return 1
        why=$(_hy2_masq_status_invalid "$sc")
        [ -z "$why" ] && break
        _error "状态码非法: ${why}"
    done
    echo -e "  ${YELLOW}响应头(可选): 每行一条 名称: 值; 直接回车结束${NC}"
    # 可选 headers 空行/EOF 均结束收集；必答字段 EOF 仍取消。
    while true; do
        read -rp "    响应头 (如 Content-Type: text/html; charset=utf-8): " line || break
        [ -z "$line" ] && break
        if ! merged=$(_hy2_masq_headers_merge "$hdr_json" "$line"); then
            _error "响应头非法: ${merged}"
            continue
        fi
        hdr_json="$merged"
    done
    payload=$(_hy2_masq_json_string "$content" "$sc" "$hdr_json") || { _error "伪装参数构造失败"; _press_any_key; return 1; }
    if ! _hy2_masq_apply "$tag" "$payload"; then
        _error "固定字符串设置失败, 已回滚原配置"; _press_any_key; return 1
    fi
    _success "已启用固定字符串伪装(${#content} 字符, HTTP ${sc:-200})"
    _press_any_key
    return 0
}

# Hysteria2: 切换 brutal / bbr
_hy2_congestion_txn() {
    _with_config_lock _hy2_congestion_txn_locked "$@"
}

_hy2_congestion_txn_locked() {
    local tag="$1" operation="$2" new_cc="$3" up="$4" down="$5"
    local meta="$NODES_DIR/${tag}.json" meta_prev cur_cc config_cc effective_up effective_down
    # metadata 原文与 _mutate_config 写入前的 config 备份都在此 config lock 内取得。
    if [ ! -s "$meta" ] || ! jq -e 'type == "object" and .protocol == "hysteria2"' "$meta" >/dev/null 2>&1; then
        _error "Hy2 元数据已变化或损坏, 拒绝提交: $meta"
        return 1
    fi
    if ! _config_present || ! _config_jq -e --arg t "$tag" \
        '([.inbounds[]? | select(.tag == $t)] as $nodes | ($nodes | length) == 1 and $nodes[0].protocol == "hysteria")' \
        >/dev/null 2>&1; then
        _error "配置中找不到唯一的 Hy2 入站(${tag}), 请先同步/修复配置"
        return 1
    fi
    meta_prev=$(cat "$meta" 2>/dev/null) || meta_prev=""
    [ -n "$meta_prev" ] || { _error "无法快照 Hy2 元数据: $meta"; return 1; }
    cur_cc=$(jq -r '.congestion // empty' "$meta" 2>/dev/null) || cur_cc=""
    config_cc=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams.congestion // empty' 2>/dev/null) || config_cc=""
    case "$operation" in
        congestion)
            case "$new_cc" in bbr|brutal|force-brutal) ;; *) _error "无效拥塞模式: $new_cc"; return 1 ;; esac
            if [ "$new_cc" = "force-brutal" ] && ! _hy2_force_brutal_up_valid "$up"; then
                _error "force-brutal 服务端上传带宽必须非零"
                return 1
            fi
            if [ "$new_cc" = "$cur_cc" ] && [ "$new_cc" = "$config_cc" ]; then
                _info "已是 ${new_cc} 模式, 无需切换"
                return 3
            fi
            if [ "$new_cc" = "bbr" ]; then
                if ! _mutate_config --arg t "$tag" \
                    'if ([.inbounds[]? | select(.tag == $t and .protocol == "hysteria")] | length) != 1 then error("Hy2 inbound changed") else (.inbounds[] | select(.tag == $t and .protocol == "hysteria") | .streamSettings.finalmask.quicParams) = {congestion: "bbr"} end'; then
                    _error "切换失败, config 事务未成功; 请核对上方回滚状态"
                    return 1
                fi
                if ! _meta_update "$meta" '.congestion="bbr" | del(.brutal_up) | del(.brutal_down)'; then
                    _hy2_congestion_rollback "$meta" "$meta_prev"
                    return $?
                fi
            else
                if ! _mutate_config --arg t "$tag" --arg cc "$new_cc" --arg up "$up" --arg down "$down" \
                    'if ([.inbounds[]? | select(.tag == $t and .protocol == "hysteria")] | length) != 1 then error("Hy2 inbound changed") else (.inbounds[] | select(.tag == $t and .protocol == "hysteria") | .streamSettings.finalmask.quicParams) = ({congestion: $cc} + (if $up != "" then {brutalUp: $up} else {} end) + (if $down != "" then {brutalDown: $down} else {} end)) end'; then
                    _error "切换失败, config 事务未成功; 请核对上方回滚状态"
                    return 1
                fi
                if ! _meta_update "$meta" '.congestion=$cc | .brutal_up=$up | .brutal_down=$down' --arg cc "$new_cc" --arg up "$up" --arg down "$down"; then
                    _hy2_congestion_rollback "$meta" "$meta_prev"
                    return $?
                fi
            fi
            ;;
        bandwidth)
            if [ "$cur_cc" != "$config_cc" ]; then
                _error "Hy2 config 与元数据拥塞模式不一致, 拒绝调整带宽: ${config_cc:-未知} / ${cur_cc:-未知}"
                return 1
            fi
            case "$config_cc" in brutal|force-brutal) ;; *) _error "该节点当前为 ${config_cc:-未知} 模式, 非 brutal/force-brutal 无需设带宽"; return 1 ;; esac
            effective_up="$up"
            effective_down="$down"
            [ -n "$effective_up" ] || effective_up=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams.brutalUp // empty' 2>/dev/null)
            [ -n "$effective_down" ] || effective_down=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams.brutalDown // empty' 2>/dev/null)
            if [ "$config_cc" = "force-brutal" ] && ! _hy2_force_brutal_up_valid "$effective_up"; then
                _error "force-brutal 服务端上传带宽必须非零"
                return 1
            fi
            if ! _mutate_config --arg t "$tag" --arg up "$effective_up" --arg down "$effective_down" \
                'if ([.inbounds[]? | select(.tag == $t and .protocol == "hysteria")] | length) != 1 then error("Hy2 inbound changed") else (.inbounds[] | select(.tag == $t and .protocol == "hysteria") | .streamSettings.finalmask.quicParams) |= (. + (if $up != "" then {brutalUp: $up} else {} end) + (if $down != "" then {brutalDown: $down} else {} end)) end'; then
                _error "带宽调整失败, config 事务未成功; 请核对上方回滚状态"
                return 1
            fi
            if ! _meta_update "$meta" '.brutal_up=$up | .brutal_down=$down' --arg up "$effective_up" --arg down "$effective_down"; then
                _hy2_congestion_rollback "$meta" "$meta_prev"
                return $?
            fi
            ;;
        *) _error "未知 Hy2 拥塞事务: $operation"; return 1 ;;
    esac
    _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    return 0
}

_hy2_congestion_rollback() {
    local meta="$1" meta_prev="$2" config_ok=0 meta_ok=0
    if _restore_config && _restart_xray_verified; then
        config_ok=1
    else
        _warn "Hy2 元数据写入失败后, config/runtime 回滚未完整完成"
    fi
    if _atomic_write_json "$meta" "$meta_prev"; then
        meta_ok=1
    else
        _warn "Hy2 元数据回滚失败, 请手动核对: $meta"
    fi
    if [ "$config_ok" -eq 1 ] && [ "$meta_ok" -eq 1 ]; then
        _error "Hy2 更新失败, config 与元数据已完整回滚"
        return 1
    fi
    _error "Hy2 更新失败且回滚不完整, 请手动核对 ${CONFIG_DIR} 与 ${meta}"
    return 2
}

_hy2_toggle_brutal() {
    clear
    _has_hy2_nodes || { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【切换 brutal / bbr】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local tag name cc
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); cc=$(jq -r '.congestion' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 当前: %s\n" "$i" "$name" "$cc"
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    # 编号经 _hy2_select_node 限长/范围校验后再索引。
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_cc; cur_cc=$(jq -r '.congestion' "$meta")
    # 选项模式: 直接选择目标模式
    echo
    echo -e "  当前拥塞控制: ${CYAN}${cur_cc}${NC}"
    echo -e "  ${GREEN}[1]${NC} bbr"
    echo -e "  ${GREEN}[2]${NC} brutal"
    echo -e "  ${GREEN}[3]${NC} force-brutal"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  选择模式: " cc_choice
    local new_cc
    case "${cc_choice:-0}" in
        0) return ;;
        1) new_cc="bbr" ;;
        2) new_cc="brutal" ;;
        3) new_cc="force-brutal" ;;
        *) _warn "无效选择"; _press_any_key; return ;;
    esac
    local brutal_up="" brutal_down="" txn_rc
    if [ "$new_cc" != "bbr" ]; then
        echo -e "  ${YELLOW}${new_cc} 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
        if [ "$new_cc" = "force-brutal" ]; then
            read -rp "  服务端上传带宽 (非零必填): " brutal_up
        else
            read -rp "  服务端上传带宽 (回车不限): " brutal_up
        fi
        read -rp "  下载带宽 (回车不限): " brutal_down
        brutal_up=$(_normalize_bandwidth "$brutal_up")
        brutal_down=$(_normalize_bandwidth "$brutal_down")
    fi
    # Config、metadata 与 _hy2_sync_derived 在事务锁内一起完成。
    _hy2_congestion_txn "$tag" congestion "$new_cc" "$brutal_up" "$brutal_down"
    txn_rc=$?
    case "$txn_rc" in
        0)
            case "$new_cc" in
                bbr) _success "已切换为 bbr 模式" ;;
                brutal)
                    _success "已切换为 brutal 模式"
                    [ -n "$brutal_up" ] && echo -e "  ${CYAN}上传:${NC} ${brutal_up}"
                    [ -n "$brutal_down" ] && echo -e "  ${CYAN}下载:${NC} ${brutal_down}"
                    ;;
                force-brutal)
                    _success "已切换为 force-brutal 模式"
                    _tip "force-brutal: 强制使用 brutalUp 固定发包速率, 无视对端协商"
                    [ -n "$brutal_up" ] && echo -e "  ${CYAN}上传:${NC} ${brutal_up}"
                    [ -n "$brutal_down" ] && echo -e "  ${CYAN}下载:${NC} ${brutal_down}"
                    ;;
            esac
            ;;
        2) _tip "本次 Hy2 更新回滚不完整, 请按上方提示人工核对" ;;
    esac
    _press_any_key
}

# Hysteria2: 调整 brutal 带宽(仅 brutal 模式)
_hy2_adjust_bandwidth() {
    local choice
    clear
    _has_hy2_nodes || { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【调整 brutal 带宽】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local tag name cc up down
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        cc=$(jq -r '.congestion' "$f"); up=$(jq -r '.brutal_up // empty' "$f"); down=$(jq -r '.brutal_down // empty' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s cc=%-6s up=%-12s down=%s\n" "$i" "$name" "$cc" "${up:--}" "${down:--}"
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    # 编号经 _hy2_select_node 限长/范围校验后再索引。
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_cc; cur_cc=$(jq -r '.congestion' "$meta")
    if [ "$cur_cc" != "brutal" ] && [ "$cur_cc" != "force-brutal" ]; then
        _warn "该节点当前为 ${cur_cc} 模式, 非 brutal/force-brutal 无需设带宽"
        _press_any_key; return
    fi
    local cur_up cur_down
    cur_up=$(jq -r '.brutal_up // empty' "$meta"); cur_down=$(jq -r '.brutal_down // empty' "$meta")
    echo -e "  当前: 上传=${CYAN}${cur_up:-不限}${NC}  下载=${CYAN}${cur_down:-不限}${NC}"
    echo -e "  ${YELLOW}格式: 100 mbps / 10m / 1g  (回车保持不变)${NC}"
    local new_up new_down
    read -rp "  新上传带宽: " new_up
    read -rp "  新下载带宽: " new_down
    new_up=$(_normalize_bandwidth "$new_up")
    new_down=$(_normalize_bandwidth "$new_down")

    local txn_rc=0
    # Blank inputs and _hy2_sync_derived are resolved from current state inside the transaction lock.
    _hy2_congestion_txn "$tag" bandwidth "" "$new_up" "$new_down" || txn_rc=$?
    case "$txn_rc" in
        0)
            new_up=$(jq -r '.brutal_up // empty' "$meta" 2>/dev/null)
            new_down=$(jq -r '.brutal_down // empty' "$meta" 2>/dev/null)
            _success "带宽已更新: 上传=${new_up:-不限}  下载=${new_down:-不限}"
            ;;
        2) _tip "本次 Hy2 更新回滚不完整, 请按上方提示人工核对" ;;
        *) _press_any_key; return ;;
    esac
    _press_any_key
}

# FinalMask：salamander + 非空 packetSize 为 Gecko；URI obfs 是独立客户端模型。
# 输入锁外，_hy2_obfs_txn_locked 锁内刷新真实层；失败仅回滚管理层。
_hy2_obfs_txn() {
    _with_config_lock _hy2_obfs_txn_locked "$@"
}

_hy2_obfs_txn_locked() {
    local tag="$1" meta="$2" choice="$3" otype="$4" opw="$5" osize="$6" omask="$7"
    local meta_prev rollback_mask config_ok=0 meta_ok=0
    # 实际混淆层/metadata 快照与 _mutate_config 的 config 备份都受此锁保护。
    if [ ! -s "$meta" ] || ! jq -e 'type == "object" and .protocol == "hysteria2"' "$meta" >/dev/null 2>&1; then
        _error "Hy2 元数据已变化或损坏, 拒绝提交: $meta"
        return 1
    fi
    if ! _config_present || ! _config_jq -e --arg t "$tag" \
        '([.inbounds[]? | select(.tag == $t)] as $nodes | ($nodes | length) == 1 and $nodes[0].protocol == "hysteria")' \
        >/dev/null 2>&1; then
        _error "配置中找不到唯一的 Hy2 入站(${tag}), 请先同步/修复配置"
        return 1
    fi
    meta_prev=$(cat "$meta" 2>/dev/null) || meta_prev=""
    [ -n "$meta_prev" ] || { _error "无法快照 Hy2 元数据: $meta"; return 1; }
    rollback_mask=$(_config_jq -c --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" \
        '[.inbounds[]? | select(.tag == $t and .protocol == "hysteria")] as $nodes
         | if ($nodes | length) != 1 then error("Hy2 inbound changed")
           else ($nodes[0].streamSettings.finalmask.udp // []
                 | map(select(.type == $ourtype and (.settings // {})[$ourmark] == true))) as $ours
                | if ($ours | length) > 1 then error("multiple managed UDP layers") else ($ours[0] // null) end
           end' 2>/dev/null) || {
        _error "无法读取 config 中本脚本实际管理的混淆层, 已取消"
        return 1
    }
    case "$choice" in
        1|2)
            if _hy2_udp_has_foreign_salamander "$tag"; then
                _error "该入站的 finalmask.udp 已存在**非本脚本写入**的 salamander 层;"
                _error "继续启用会叠加成双重混淆(客户端只做一层, 必然连不上)。"
                _tip "请先手工编辑 ${CONFIG_DIR} 移除或改名该层(本脚本写入的层带 settings.xd_managed=true)"
                _tip "若只想关闭本脚本的混淆, 请选 [3](只删本脚本那层, 保留其它层)"
                return 1
            fi
            ;;
        3) ;;
        *) _error "无效混淆选项: $choice"; return 1 ;;
    esac
    if ! _mutate_config --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" --argjson new "$omask" \
        "$XD_UDP_JQ_UPSERT"; then
        _error "混淆 config 事务失败, 请核对上方回滚状态"
        return 1
    fi
    case "$choice" in
        1|2)
            if ! _meta_update "$meta" \
                '.obfs_type=$t | .obfs_password=$p | .obfs_packet_size=(if $s == "" then null else $s end)' \
                --arg t "$otype" --arg p "$opw" --arg s "$osize"; then
                _error "混淆元数据写入失败, 正在回滚实际配置快照"
            else
                _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
                return 0
            fi
            ;;
        3)
            if ! _meta_update "$meta" 'del(.obfs_type) | del(.obfs_password) | del(.obfs_packet_size)'; then
                _error "混淆元数据写入失败, 正在回滚实际配置快照"
            else
                _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
                return 0
            fi
            ;;
    esac
    if _hy2_obfs_rollback "$tag" "$rollback_mask"; then
        config_ok=1
    else
        _warn "混淆配置回滚失败, 请手动核对: $CONFIG_DIR"
    fi
    if _atomic_write_json "$meta" "$meta_prev"; then
        meta_ok=1
    else
        _warn "混淆元数据回滚失败, 请手动核对: $meta"
    fi
    if [ "$config_ok" -eq 1 ] && [ "$meta_ok" -eq 1 ]; then
        _error "混淆事务失败, 配置与元数据已恢复到改动前"
        return 1
    fi
    _error "混淆事务失败且回滚不完整, 请手动核对 ${CONFIG_DIR} 与 ${meta}"
    return 2
}

_hy2_obfs_menu() {
    local choice
    clear
    _has_hy2_nodes || { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【混淆 salamander / gecko (FinalMask.udp)】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local tag name otype osize
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        otype=$(jq -r '.obfs_type // empty' "$f")
        osize=$(_hy2_obfs_size_get "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 当前: %s%s\n" "$i" "$name" "${otype:-未启用}" "${osize:+ (packetSize=${osize})}"
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    # 编号经 _hy2_select_node 限长/范围校验后再索引。
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_type cur_size
    cur_type=$(jq -r '.obfs_type // empty' "$meta")
    cur_size=$(_hy2_obfs_size_get "$meta")
    echo
    if [ -n "$cur_type" ]; then
        echo -e "  当前: ${GREEN}${cur_type}${NC}${cur_size:+ (packetSize=${cur_size})}"
    else
        echo -e "  当前: ${RED}未启用${NC}"
    fi
    echo -e "  ${YELLOW}启用后服务端不再兼容标准 QUIC/HTTP3 连接(Hysteria 官方文档 Full-Server-Config), 客户端必须带相同类型与密码${NC}"
    echo -e "  ${GREEN}[1]${NC} 启用/更换 salamander 混淆"
    echo -e "  ${GREEN}[2]${NC} 启用/更换 gecko"
    echo -e "  ${GREEN}[3]${NC} 关闭混淆"
    echo -e "  ${GREEN}[0]${NC} 返回"
    local obfs_choice
    read -rp "  请选择: " obfs_choice
    local otype="" opw="" osize="" omask="" opw_in=""
    case "${obfs_choice:-0}" in
        0) return ;;
        1|2)
            otype="salamander"
            opw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " opw_in
            opw=${opw_in:-$opw}
            _validate_json_text "$opw" || { _error "混淆密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; _press_any_key; return; }
            if [ "$obfs_choice" = "2" ]; then
                # Gecko 要求 packetSize 能力；不支持拒绝，不替用户降级。
                if ! _hy2_gecko_supported; then
                    _error "当前核心不支持 gecko 分片(packetSize 需核心 >= ${_HY2_GECKO_MIN_VER}); 已取消, 未修改任何配置"
                    _tip "请先升级/切换 Xray 核心, 或改选 [1] 普通 salamander"
                    _press_any_key; return
                fi
                # 空输入写 512-1200（Hysteria 客户端默认）；空尺寸会退化 salamander。
                read -rp "  packetSize (Int32Range, 如 512-1200; 回车用 Hysteria 官方 gecko 默认 512-1200): " osize
                osize="${osize:-512-1200}"
                local size_why; size_why=$(_hy2_obfs_size_invalid "$osize")
                [ -n "$size_why" ] && { _error "packetSize 非法: ${size_why}"; _press_any_key; return; }
                # 规范化(排序 + 去前导零)后回写, 使元数据/clash 与 Xray 看到同一区间
                osize=$(_hy2_obfs_size_canon "$osize") || { _error "packetSize 规范化失败"; _press_any_key; return; }
            fi
            omask=$(_hy2_obfs_mask_block "$otype" "$opw" "$osize") || { _error "混淆参数构造失败"; _press_any_key; return; }
            ;;
        3)
            omask="null"
            ;;
        *) _warn "无效选择"; _press_any_key; return ;;
    esac
    local txn_rc=0
    # `_hy2_obfs_txn_locked` rechecks `_hy2_udp_has_foreign_salamander "$tag"` only for enable; if it refuses, it points users to the safe [3] close action.
    _hy2_obfs_txn "$tag" "$meta" "$obfs_choice" "$otype" "$opw" "$osize" "$omask" || txn_rc=$?
    case "$txn_rc" in
        0)
            if [ "$obfs_choice" = "3" ]; then
                _success "混淆已关闭"
            else
                _success "混淆已启用 (${otype}${osize:+ · packetSize=${osize}})"
            fi
            ;;
        2) _tip "本次混淆回滚不完整, 请按上方提示人工核对" ;;
    esac
    _press_any_key
}

# _hy2_obfs_rollback <tag> <mask_or_empty_or_INVALID> 仅恢复管理层，保留外来层。
# 空值关闭，__INVALID__ 拒绝回滚，不把未知旧态当无混淆。
_hy2_obfs_rollback() {
    local tag="$1" mask="$2"
    if [ "$mask" = "__INVALID__" ]; then
        _error "改动前的混淆元数据无法解析, 未回滚配置(请手工核对 ${CONFIG_DIR})"
        return 1
    fi
    if [ -z "$mask" ]; then
        _mutate_config --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" --argjson new null \
            "$XD_UDP_JQ_UPSERT"
    else
        _mutate_config --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" --argjson new "$mask" \
            "$XD_UDP_JQ_UPSERT"
    fi
}
# _reality_switch_rollback <meta> <metadata 原文>：权威状态失败一起回滚并验证重启。
# 须在域名事务 config lock 内，共享 lastbak 才属于本次事务；派生失败另行报告。
_reality_switch_rollback() {
    local meta="$1" meta_prev="${2:-}" config_ok=0 runtime_ok=0 meta_ok=0
    # _restore_config 的 lastbak 只在同一 config 锁域内属于本次事务。
    if _restore_config; then
        config_ok=1
        if _restart_xray_verified >/dev/null 2>&1; then
            runtime_ok=1
        else
            _warn "配置已还原, 但 xray 未能稳定重启, 请查看状态"
        fi
    else
        _warn "配置回滚失败, 请手动核对: $CONFIG_DIR"
    fi
    if [ -n "$meta_prev" ]; then
        if _atomic_write_json "$meta" "$meta_prev" 2>/dev/null; then
            meta_ok=1
        else
            _warn "元数据还原失败, 请手动核对: $meta"
        fi
    else
        _warn "没有元数据快照可还原, 请手动核对: $meta"
    fi
    if [ "$config_ok" -eq 1 ] && [ "$runtime_ok" -eq 1 ] && [ "$meta_ok" -eq 1 ]; then
        _error "域名切换未完成(后置步骤失败), 配置、运行态与元数据均已还原"
        return 0
    fi
    _error "域名切换失败且回滚不完整, 请手动核对 $CONFIG_DIR 与 $meta"
    _tip "可用备份: $BACKUP_DIR/confs.lastbak"
    return 1
}

# _reality_domain_txn_locked <tag> <meta> <new_sni> <pq_seed> <pq_verify> <allow_missing_tunnel>
# config → metadata → 链接及回滚整体持 config lock；交互/PQ 锁外，状态锁内刷新。
# rc 0=成功，1=失败已回滚，2=回滚不完整，3=权威态已提交仅链接未更新。
# 链接缺字段不回滚一致权威态；成功回读 metadata，避免子 shell 输出污染。
_reality_domain_txn() {
    _with_config_lock _reality_domain_txn_locked "$@"
}

_reality_domain_txn_locked() {
    local tag="$1" meta="$2" new_sni="$3" pq_seed="$4" pq_verify="$5" allow_missing_tunnel="${6:-0}"
    local meta_prev rmode tunnel_tag="" tunnel_port="" node_port="" new_tunnel_tag="" reality_target=""
    if [ ! -s "$meta" ] || ! jq -e 'type == "object" and (.protocol == "vless-tcp-reality-vision" or .protocol == "vless-xhttp-reality")' \
        "$meta" >/dev/null 2>&1; then
        _error "Reality 元数据已变化或损坏, 拒绝提交: $meta"
        return 1
    fi
    if ! _config_jq -e --arg t "$tag" \
        '([.inbounds[]? | select(.tag == $t)] as $nodes | ($nodes | length) == 1 and ($nodes[0].streamSettings.realitySettings | type) == "object")' \
        >/dev/null 2>&1; then
        _error "配置中找不到唯一的 Reality 入站(${tag}), 请先同步/修复配置"
        return 1
    fi
    meta_prev=$(cat "$meta" 2>/dev/null) || meta_prev=""
    [ -n "$meta_prev" ] || { _error "无法快照 Reality 元数据: $meta"; return 1; }
    rmode=$(_reality_node_mode "$tag") || rmode=""
    case "$rmode" in direct|tunnel) ;; *) _error "无法确认 Reality 节点拓扑, 已取消域名切换"; return 1 ;; esac
    if [ "$rmode" = "direct" ]; then
        reality_target="${new_sni}:443"
    else
        tunnel_tag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null) || tunnel_tag=""
        if [ -z "$tunnel_tag" ]; then
            if [ "$allow_missing_tunnel" != "1" ]; then
                _error "Reality 拓扑已变化且缺少 tunnel_tag, 未获得跳过 tunnel 更新的确认; 请重试"
                return 1
            fi
        else
            if ! _config_jq -e --arg t "$tunnel_tag" \
                '([.inbounds[]? | select(.tag == $t)] as $nodes | ($nodes | length) == 1 and $nodes[0].protocol == "tunnel")' \
                >/dev/null 2>&1; then
                _error "Reality 元数据中的 tunnel_tag 不对应唯一 tunnel 入站(${tunnel_tag}), 拒绝切换"
                return 1
            fi
            tunnel_port=$(jq -r '.tunnel_port // empty' "$meta" 2>/dev/null) || tunnel_port=""
            node_port=$(jq -r '.port // empty' "$meta" 2>/dev/null) || node_port=""
            if [[ ! "$tunnel_port" =~ ^[0-9]+$ ]] || [[ ! "$node_port" =~ ^[0-9]+$ ]]; then
                _error "Reality tunnel 端口元数据非法, 拒绝切换"
                return 1
            fi
            new_tunnel_tag=$(_gen_tunnel_tag "$new_sni" "$tunnel_port" "$node_port") || new_tunnel_tag=""
            [ -n "$new_tunnel_tag" ] || { _error "无法生成新 tunnel tag, 已取消域名切换"; return 1; }
            if [ "$new_tunnel_tag" != "$tunnel_tag" ] && \
               _config_jq -e --arg t "$new_tunnel_tag" '[.inbounds[]? | select(.tag == $t)] | length > 0' >/dev/null 2>&1; then
                _error "新 tunnel tag 已被其他入站占用(${new_tunnel_tag}), 拒绝切换"
                return 1
            fi
        fi
    fi
    # config/metadata/verified restart 同锁，交互与 PQ 探测锁外，避免覆盖并发状态。
    if [ -n "$pq_seed" ]; then
        _mutate_config --arg t "$tag" --arg sni "$new_sni" --arg seed "$pq_seed" \
             --arg tg "$tunnel_tag" --arg dom "$new_sni" --arg new_tg "$new_tunnel_tag" \
             --arg newtgt "$reality_target" \
             '(.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings) |=
              (.serverNames = [$sni] | .mldsa65Seed = $seed
               | if $newtgt != "" then .target = $newtgt else . end)
              | if $tg != "" then
                  (.inbounds[] | select(.tag == $tg) | .tag) = $new_tg
                  | (.inbounds[] | select(.tag == $new_tg) | .settings) |=
                      ((if has("rewriteAddress") then .rewriteAddress = $dom else . end)
                       | (if has("address") then .address = $dom else . end))
                  | .routing.rules |= map(
                      (if .inboundTag != null and (.inboundTag | type) == "array"
                       then .inboundTag |= map(if . == $tg then $new_tg else . end)
                       else . end)
                      | if .inboundTag != null and (.inboundTag | type) == "array"
                           and (.inboundTag | index($new_tg)) != null
                           and .domain != null
                        then .domain = [$dom]
                        else . end)
                else . end' || return 1
    else
        _mutate_config --arg t "$tag" --arg sni "$new_sni" \
             --arg tg "$tunnel_tag" --arg dom "$new_sni" --arg new_tg "$new_tunnel_tag" \
             --arg newtgt "$reality_target" \
             '(.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings) |=
              (.serverNames = [$sni] | del(.mldsa65Seed)
               | if $newtgt != "" then .target = $newtgt else . end)
              | if $tg != "" then
                  (.inbounds[] | select(.tag == $tg) | .tag) = $new_tg
                  | (.inbounds[] | select(.tag == $new_tg) | .settings) |=
                      ((if has("rewriteAddress") then .rewriteAddress = $dom else . end)
                       | (if has("address") then .address = $dom else . end))
                  | .routing.rules |= map(
                      (if .inboundTag != null and (.inboundTag | type) == "array"
                       then .inboundTag |= map(if . == $tg then $new_tg else . end)
                       else . end)
                      | if .inboundTag != null and (.inboundTag | type) == "array"
                           and (.inboundTag | index($new_tg)) != null
                           and .domain != null
                        then .domain = [$dom]
                        else . end)
                else . end' || return 1
    fi
    # 同步元数据及 reality_mode，明确节点拓扑。
    if [ -n "$new_tunnel_tag" ]; then
        _meta_update "$meta" '.sni=$sni | .mldsa65_verify=$pqv | .tunnel_tag=$new_tg | .reality_mode=$rm' \
            --arg sni "$new_sni" --arg pqv "$pq_verify" --arg new_tg "$new_tunnel_tag" --arg rm "$rmode" || {
                _reality_switch_rollback "$meta" "$meta_prev" && return 1 || return 2; }
    elif [ "$rmode" = "direct" ]; then
        _meta_update "$meta" '.sni=$sni | .mldsa65_verify=$pqv | del(.tunnel_tag) | del(.tunnel_port) | .reality_mode=$rm' \
            --arg sni "$new_sni" --arg pqv "$pq_verify" --arg rm "$rmode" || {
                _reality_switch_rollback "$meta" "$meta_prev" && return 1 || return 2; }
    else
        _meta_update "$meta" '.sni=$sni | .mldsa65_verify=$pqv | del(.tunnel_tag) | .reality_mode=$rm' \
            --arg sni "$new_sni" --arg pqv "$pq_verify" --arg rm "$rmode" || {
                _reality_switch_rollback "$meta" "$meta_prev" && return 1 || return 2; }
    fi
    # SNI 已提交；链接重建失败返回3，保留旧链接。
    local newlink=""
    if ! newlink=$(_rebuild_reality_link "$meta") || [ -z "$newlink" ]; then
        _warn "域名已切换为 ${new_sni}, 但分享链接重建失败(元数据缺少必要字段), 链接未更新"
        _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
        return 3
    fi
    _meta_update "$meta" '.share_link=$l' --arg l "$newlink" || {
        _reality_switch_rollback "$meta" "$meta_prev" && return 1 || return 2; }
    return 0
}

_reality_domain_menu() {
    local choice
    _has_reality_nodes || { _warn "暂无 Reality 节点"; _press_any_key; return; }
    while true; do
        clear
        echo; echo -e "  ${CYAN}【Reality 域名管理】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        case "$proto" in *reality*) ;; *) continue ;; esac
        local tag name sni
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); sni=$(jq -r '.sni' "$f")
        tags+=("$tag")
        # 显示实际拓扑；域名切换按 direct/tunnel 分别更新目标。
        local mlabel="隧道"
        [ "$(_reality_node_mode "$tag")" = "direct" ] && mlabel="直连"
        printf "  ${GREEN}[%d]${NC} %-24s [%s] 当前域名: %s\n" "$i" "$name" "$mlabel" "$sni"
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Reality 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice || return 0
    [ "$choice" = "0" ] && return
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; continue; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_sni; cur_sni=$(jq -r '.sni' "$meta")
    echo -e "  当前域名: ${CYAN}${cur_sni}${NC}"
    local new_sni
    read -rp "  新伪装域名 (回车取消): " new_sni
    [ -z "$new_sni" ] && { _info "已取消"; _press_any_key; continue; }
    # SNI 同时组成 tunnel tag，先校验域名避免关联失效。
    if ! _validate_domain "$new_sni"; then
        _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $new_sni"
        _press_any_key; continue
    fi

    local new_target="${new_sni}:443"

    # PQ rc 0=支持/1=确认不支持/2=未知；未知取消切换，不移除旧 PQ。
    local pq_seed="" pq_verify="" pq_rc=0
    _detect_reality_pq "$new_target" || pq_rc=$?
    case "$pq_rc" in
        0)
            pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
            _info "新域名支持后量子签名"
            ;;
        1)
            local old_pqv
            old_pqv=$(jq -r '.mldsa65_verify // empty' "$meta" 2>/dev/null)
            [ -n "$old_pqv" ] && _warn "新域名不支持后量子签名, 提交后将移除本节点现有的 PQ 配置"
            ;;
        *)
            _error "后量子兼容性探测失败, 无法判断新域名是否支持 PQ(原因见上方告警)"
            _tip "本次域名切换未执行, 节点配置保持不变; 请确认网络可达后重试"
            _press_any_key
            continue
            ;;
    esac

    # 仅为决定是否需要用户确认而在锁外读取拓扑; 切换事务会在锁内重新读取并校验所有状态。
    local preflight_mode allow_missing_tunnel=0 preflight_tunnel_tag=""
    preflight_mode=$(_reality_node_mode "$tag")
    if [ "$preflight_mode" != "direct" ]; then
        preflight_tunnel_tag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null)
        if [ -z "$preflight_tunnel_tag" ]; then
            _warn "该节点缺少 tunnel_tag 元数据(可能为旧版本创建或手动添加)"
            _warn "域名切换将仅更新 Reality inbound, 不会更新 tunnel inbound 和路由规则"
            read -rp "  继续? [y/N]: " ans
            case "$ans" in y|Y) allow_missing_tunnel=1 ;; *) _info "已取消"; _press_any_key; continue ;; esac
        fi
    fi

    # config、metadata、拓扑与回滚快照均在 config lock 内复核; 提问和后量子网络探测留在锁外。
    _reality_domain_txn "$tag" "$meta" "$new_sni" "$pq_seed" "$pq_verify" "$allow_missing_tunnel"
    local txn_rc=$?
    if [ "$txn_rc" -ne 0 ]; then
        # rc 1/2/3 的具体恢复状态由事务体报告，契约见 _reality_domain_txn_locked。
        [ "$txn_rc" -eq 2 ] && _tip "本次改动未完成, 请按上方提示人工核对后重试"
        _press_any_key; continue
    fi
    # 成功路径: 分享链接即 metadata 里刚原子提交的那一份
    local newlink="" result_mode actual_target
    result_mode=$(_reality_node_mode "$tag")
    newlink=$(jq -r '.share_link // empty' "$meta" 2>/dev/null)
    [ -n "$newlink" ] || _warn "未能读回新分享链接, 请用 [查看节点] 查看: $meta"
    # clash 是派生缓存；同步失败告警，不回滚已一致权威态。
    if ! _sync_node_clash "$meta"; then
        _warn "clash 派生缓存同步失败, 订阅里的条目仍是旧伪装域名"
        _tip "可重新执行一次本操作, 或删除后重建该节点以重建 clash 条目"
    fi

    _success "Reality 域名已切换为: ${new_sni}"
    if [ "$result_mode" = "direct" ]; then
        actual_target=$(_config_jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.target // empty' 2>/dev/null)
        [ -n "$actual_target" ] && _tip "直连模式: realitySettings.target 当前为 ${actual_target}"
    fi
    _tip "客户端须更新 SNI 为 ${new_sni} (pbk/sid 不变)"
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    [ -z "$pq_verify" ] && _warn "新域名不支持后量子, 已移除 pqv 参数"
    echo -e "  ${CYAN}新分享链接:${NC} ${newlink}"
    _press_any_key
    done
}
