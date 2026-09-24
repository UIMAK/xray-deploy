#!/bin/bash
# =============================================================================
# lib/90-menu.sh — 主菜单 + 状态栏
# 串接所有模块, 渲染菜单, 调度用户选择
# ============================================================================

# 标题(居中)
_print_logo() {
    local title="Xray 部署管理脚本 (xray-deploy)"
    local char_count byte_count cjk_chars display_w
    char_count=$(printf '%s' "$title" | wc -m | tr -d '[:space:]')
    byte_count=$(printf '%s' "$title" | wc -c | tr -d '[:space:]')
    cjk_chars=$(( (byte_count - char_count) / 2 ))
    display_w=$(( char_count + cjk_chars ))
    local inner=$(( display_w + 8 ))
    [ "$inner" -lt 40 ] && inner=40
    local pad=$(( (inner - display_w) / 2 ))
    local left="" i
    for ((i=0; i<pad; i++)); do left="${left} "; done
    echo -e "  ${CYAN}${left}${title}${NC}"
}

# ---------------------------------------------------------------------------
# 状态栏
# ---------------------------------------------------------------------------
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
        # 通道名来自 state 文件(可被本地写坏/篡改), 且会被 echo -e 打屏 —— 先净化,
        # 只保留版本号类安全字符, 避免转义序列注入管理员终端。
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

    # Geo(真相源: config.json 的 geodata.cron, 兼容旧 state)
    local geostate; geostate=$(_geo_auto_state 2>/dev/null); [ -z "$geostate" ] && geostate="off"
    local geostr
    [ "$geostate" = "on" ] && geostr="${GREEN}● 自动${NC}" || geostr="${RED}○ 手动${NC}"

    echo -e "  系统: ${CYAN}${os_info}${NC}  |  init: ${CYAN}${INIT_SYSTEM}${NC}"
    echo -e "  Xray${CYAN}${xver}${NC} [${xchannel}]: ${xstatus}  |  节点: ${CYAN}${ncount}${NC}"
    echo -e "  cloudflared: ${cfstatus}  |  Geo: ${geostr}"
    [ -n "$hyline" ] && echo -e "$hyline"
    echo
}

# ---------------------------------------------------------------------------
# 节点类型检测(用于条件显示管理菜单)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
_main_menu() {
    # 启动时: 收敛中断的 reset + 自动补 tag + 自动采纳孤儿入站 + 恢复中断的端口事务 + 注入 config env(R45) + 迁移 Geo 自动更新(R45) + 格式化配置
    # 各恢复/迁移步骤都用 declare -F 守卫: 混装版本(模块未同步更新)时静默跳过。
    # reset 恢复放在最前: 半截 reset 的 live 状态可能是"config 空/缺 + nodes 空 + 快照藏着
    # 旧 metadata", 先收敛再让 adopt/normalize 基于稳定状态工作。
    if declare -F _reset_config_recover >/dev/null 2>&1; then _reset_config_recover; fi
    _auto_tag_tagless_inbounds
    _auto_adopt_orphans
    # 放在 config 相关操作之前, 使后续步骤看到的都是已收敛的 metadata
    if declare -F _port_txn_recover >/dev/null 2>&1; then _port_txn_recover; fi
    # 核心切换的崩溃恢复(十一轮 P1-②): 进程在"二进制已换 / unit 已重写"之后被杀(断电/OOM/
    # kill -9)时没有任何函数会被调用, 只能靠启动期按 state/coretxn.json 收敛。
    # 放在 config 相关操作之前 —— 它可能重启服务, 先让服务回到已知状态再谈配置。
    if declare -F _xray_core_txn_recover >/dev/null 2>&1; then _xray_core_txn_recover; fi
    if declare -F _auto_ensure_config_env >/dev/null 2>&1; then _auto_ensure_config_env; fi
    if declare -F _auto_migrate_geo_autoupdate >/dev/null 2>&1; then _auto_migrate_geo_autoupdate; fi
    _normalize_config_format
    local choice

    while true; do
        clear
        _print_logo
        echo
        _print_status_bar

        echo -e "  ${CYAN}【节点管理】${NC}"
        echo -e "  ${GREEN}[1]${NC} 添加节点"
        echo -e "  ${GREEN}[2]${NC} 查看节点"
        echo -e "  ${GREEN}[3]${NC} 删除节点"
        echo -e "  ${GREEN}[4]${NC} 修改端口"
        echo -e "  ${GREEN}[5]${NC} 更新监听"
        echo -e "  ${GREEN}[6]${NC} Xray Hy2 管理"
        echo -e "  ${GREEN}[7]${NC} Reality 域名管理"
        echo -e "  ${GREEN}[8]${NC} Hysteria2 管理"
        echo
        echo -e "  ${CYAN}【核心与服务】${NC}"
        local _core=9
        local _ops_start=$((_core+3))
        printf "  ${GREEN}[%d]${NC} 安装/更新或切换 Xray 核心\n" "$_core"
        printf "  ${GREEN}[%d]${NC} Geo 数据自动更新\n" $((_core+1))
        printf "  ${GREEN}[%d]${NC} cloudflared 管理\n" $((_core+2))
        echo
        echo -e "  ${CYAN}【运维】${NC}"
        printf "  ${GREEN}[%2d]${NC} 检测脚本更新\n" "$_ops_start"
        printf "  ${GREEN}[%2d]${NC} 重启 Xray\n" $((_ops_start+1))
        printf "  ${GREEN}[%2d]${NC} 停止 Xray\n" $((_ops_start+2))
        printf "  ${GREEN}[%2d]${NC} 查看状态\n" $((_ops_start+3))
        printf "  ${GREEN}[%2d]${NC} 查看日志\n" $((_ops_start+4))
        printf "  ${GREEN}[%2d]${NC} 日志轮换\n" $((_ops_start+5))
        printf "  ${GREEN}[%2d]${NC} 定时重启\n" $((_ops_start+6))
        printf "  ${GREEN}[%2d]${NC} 检查配置\n" $((_ops_start+7))
        printf "  ${GREEN}[%2d]${NC} 卸载\n" $((_ops_start+8))
        echo
        echo -e "  ${GREEN}[0]${NC} 退出"
        echo
        read -rp "  请选择: " choice || exit 0
        # 节点管理(固定编号 1-5)
        case "$choice" in
            1) _add_node; continue ;;
            2) _view_nodes; continue ;;
            3) _delete_node; continue ;;
            4) _modify_port; continue ;;
            5) _update_listen; continue ;;
        esac
        # 条件管理入口
        if [ "$choice" = "6" ]; then
            _hy2_manage_menu; continue
        fi
        if [ "$choice" = "7" ]; then
            _reality_domain_menu; continue
        fi
        if [ "$choice" = "8" ]; then
            _hysteria_menu; continue
        fi
        # 动态编号: 核心与服务 / 运维
        _ops_start=$((_core+3))
        if [ "$choice" = "$_core" ]; then
            _xray_core_menu
        elif [ "$choice" = "$((_core+1))" ]; then
            _geo_menu
        elif [ "$choice" = "$((_core+2))" ]; then
            _cloudflared_menu
        elif [ "$choice" = "$_ops_start" ]; then
            _check_script_update
        elif [ "$choice" = "$((_ops_start+1))" ]; then
            if _restart_xray_verified; then _success "已重启并稳定运行"; else _error "重启后 xray 未稳定运行, 请查看日志"; fi
            _press_any_key
        elif [ "$choice" = "$((_ops_start+2))" ]; then
            _manage_xray stop; _success "已停止"; _press_any_key
        elif [ "$choice" = "$((_ops_start+3))" ]; then
            _view_status
        elif [ "$choice" = "$((_ops_start+4))" ]; then
            _view_log
        elif [ "$choice" = "$((_ops_start+5))" ]; then
            _logrotate_menu
        elif [ "$choice" = "$((_ops_start+6))" ]; then
            _timed_restart_menu
        elif [ "$choice" = "$((_ops_start+7))" ]; then
            _check_config
        elif [ "$choice" = "$((_ops_start+8))" ]; then
            _uninstall_menu
        elif [ "$choice" = "0" ]; then
            echo -e "${CYAN}再见${NC}"; exit 0
        else
            _warn "无效选择"; _press_any_key
        fi
    done
}

# ---------------------------------------------------------------------------
# 查看状态
# ---------------------------------------------------------------------------
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
        # 通道名来自 state 文件(可被本地写坏/篡改), 且会进 `echo -e` —— **必须与
        # `_print_status_bar` 同一口径净化**(2026-09-22 九轮 OCR #40)。同一个键在两个读点
        # 一处净化一处不净化, 是项目反复踩过的"同一条件各调用点各自解释"形状; 未净化的那个
        # 会把 ANSI/控制序列原样打给管理员终端。
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

# ---------------------------------------------------------------------------
# 查看日志
# ---------------------------------------------------------------------------
_view_log() {
    clear
    echo
    # loglevel=none 时核心同时关闭 access 与 error 两个日志(infra/conf/log.go),
    # 文件不会有新内容 —— 不提示的话用户会以为是脚本坏了。历史内容仍照常展示。
    # declare -F 探测: 混装版本(20-xray-core 是旧版)时静默跳过提示, 不影响看日志本身。
    if declare -F _xray_loglevel_get >/dev/null 2>&1 && [ "$(_xray_loglevel_get 2>/dev/null)" = "none" ]; then
        _warn "当前日志级别为 none: access.log 与 error.log 均已停止写入, 以下仅为历史内容"
        # 按名字而不是编号指路: 运维段编号由 _main_menu 的 _core/_ops_start 动态算出,
        # 写死 [16] 会在编号变动后变成错误提示(50-nodes.sh 的 "[6] 安装 Xray" 就这么过期过)。
        _tip "如需恢复记录, 请到运维菜单的 [日志轮换] → [日志级别] 选择 error/warning 等级别"
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

# ---------------------------------------------------------------------------
# 检查配置
# ---------------------------------------------------------------------------
_check_config() {
    clear
    echo
    if [ ! -x "$XRAY_BIN" ]; then _warn "Xray 未安装"; _press_any_key; return; fi
    if [ ! -f "$CONFIG_FILE" ]; then _warn "配置文件不存在"; _press_any_key; return; fi
    _normalize_config_format
    _info "运行 xray -test..."
    if _xray_test_config; then
        _success "配置校验通过"
    else
        _error "配置校验失败"
    fi
    _press_any_key
}

# ---------------------------------------------------------------------------
# 定时重启 菜单
# ---------------------------------------------------------------------------
# cron 单字段结构校验(比"字符集 + 含数字或 *"严格得多)。
# 旧写法 ^[0-9*,/-]*[0-9*][0-9*,/-]*$ 只保证"含数字或 *", 于是 */ 、1- 、-1 、1--2 、1,2, 这些
# 结构畸形字段照样放行 —— 用户看到"已设置", 直到 cron 运行才报解析错误, 正是该处注释声称
# 要消除的失败形态。现在按 cron 的真实语法逐项校验: 逗号列表的每一项必须是
# * | N | N-M | */S | N-M/S, 且逗号不得出现在首尾或连续出现。
# 只做结构校验, 不硬编码"分 0-59 / 时 0-23"的取值范围 —— 取值范围交给 cron,
# 在这里写死会让合法的自定义表达式被误拒。
_cron_field_valid() {
    local f="$1" x
    [ -n "$f" ] || return 1
    case "$f" in ,*|*,|*,,*) return 1 ;; esac
    local -a _parts
    IFS=',' read -ra _parts <<< "$f"
    for x in "${_parts[@]}"; do
        [[ "$x" =~ ^(\*|[0-9]+)(-[0-9]+)?(/[0-9]+)?$ ]] || return 1
        # 步长为 0 是**结构非法**(cron 直接报解析错误), 不属于"取值范围交给 cron"的范畴:
        # */0 / 0-30/0 都能通过上面的正则, 却让用户看到"已设置"后运行时才失败。
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
            # 2026-09-12 三审(S4): 基本格式校验 —— 5 个字段, 每字段仅数字/*/,/- 字符集。
            # 过松会让坏行被 cron 反复报解析错误; 不校验取值范围是刻意的, 不会误伤 */3 等合法写法。
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
    # 混装旧 lib(00-common 是旧版)时 _crontab_replace 不存在: 这是写路径, 必须响亮拒绝并
    # 给出可执行提示, 绝不能退回旧的裸管道写法(读失败会清空用户全部 crontab)。
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 无法写入 crontab"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        _press_any_key; return
    fi
    # 先确保 cron 服务运行(M20: 无 cron 的全新 Alpine 上先装 cron 再写 crontab)
    local cron_ok=0
    _ensure_cron_running && cron_ok=1
    # 删除旧行 + 写入新行。读 crontab 失败时 _crontab_replace 返回 1 且不改动现有内容 ——
    # 旧的 `(crontab -l; echo) | crontab -` 在读失败时会把用户的全部定时任务覆盖掉。
    if ! _crontab_replace "$marker" "$cron_line"; then
        _error "写入 crontab 失败"
        _press_any_key; return
    fi
    mkdir -p "$STATE_DIR"
    if [ "$cron_ok" -eq 1 ]; then
        _state_set timed_restart "$cron_expr"
        _success "定时重启已设置: ${cron_expr}"
    else
        # 回滚刚写入的 crontab 行, 保证 state=off ⇔ 项目 cron entry 不存在;
        # 回滚失败要暴露, 不能静默。
        if ! _crontab_replace "$marker"; then
            # 回滚失败 => cron 行可能仍在。此时**不能**写 state=off, 否则就是"UI 说已关、
            # cron 还在跑"的分裂状态(与 _timed_restart_disable 同一口径)。
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

# ---------------------------------------------------------------------------
# 禁用定时重启
# ---------------------------------------------------------------------------
_timed_restart_disable() {
    local marker="# xray-deploy-timed-restart"
    if ! declare -F _crontab_replace >/dev/null 2>&1; then
        _error "lib 版本过旧(00-common 缺 _crontab_replace), 无法清理 crontab"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    # 2026-09-21 复审(P1): 这里原本是裸管道 `crontab -l 2>/dev/null | grep -qF "$marker"`,
    # 把"读成功但确实没这行"(该记账)与"crontab -l 读失败"(行可能仍在, 绝不能记账)压成
    # 同一个退出码 1。实测: 令 crontab -l 返回 2 并输出 "cannot open spool: Input/output
    # error", 本函数报"定时重启未启用"并写下 state=off —— cron 行仍在无人值守地重启服务。
    # _crontab_has_marker 就是为这个三态判据而存在的(00-common)。
    local has_rc=0
    if declare -F _crontab_has_marker >/dev/null 2>&1; then
        _crontab_has_marker "$marker" || has_rc=$?
    else
        # 混装旧 lib(00-common 是旧版): 没有三态判据可用。**绝不能退回裸管道** —— 那正是
        # 上面刚修掉的分裂形态。宁可不改 state 并如实告警, 也不猜。
        _error "lib 版本过旧(00-common 缺 _crontab_has_marker), 无法确认定时任务状态"
        _tip "请执行 [检测脚本更新] 更新全部 lib 后重试"
        return 1
    fi
    case "$has_rc" in
        2)
            # 读不到 crontab => 行可能仍在。此时**不能**写 state=off, 否则就是
            # "UI 说已关、cron 还在跑"的分裂状态, 而且下次用户看到"未启用"就不会再处理。
            _warn "无法读取 crontab, 定时重启任务是否仍在无法确认"
            _tip "state 保持原值不变(未标记为已关闭), 以免与实际 cron 状态不符"
            return 1 ;;
        0)
            # 删除失败必须暴露: 否则 state 记成 off 而 cron 行仍在(无人值守地重启服务)。
            # **这里必须提前 return, 不能继续往下写 state=off**。
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

# ---------------------------------------------------------------------------
# 查看定时重启日志
# ---------------------------------------------------------------------------
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

# 兜底卸载专用的进程发现(bash 无函数局部作用域, 嵌套定义会泄漏到全局并每次重定义 ——
# 项目惯例是这类 helper 一律放顶层, 与 40-cloudflared.sh 的 _cf_pids/_cf_pids_owned 一致)。
# **不能只靠 pidof**: 容器内 busybox pidof/pgrep 会假阴性(H3), 漏报时 kill 块被整段跳过、
# 事后校验也判"无残留", 于是进程还活着却报卸载成功。pidof 优先, 再补 /proc/<pid>/comm
# 精确扫描(容器内可靠)。
_cf_fb_pids() {
    local pids p c
    pids=$(pidof cloudflared 2>/dev/null | tr ' ' '\n' | grep -e '^[0-9][0-9]*$')
    [ -n "$pids" ] && printf '%s\n' "$pids"
    for p in /proc/[0-9]*; do
        read -r c 2>/dev/null < "$p/comm" || continue
        [ "$c" = "cloudflared" ] && printf '%s\n' "${p#/proc/}"
    done
}

# 兜底卸载 cloudflared（当 VPS 上的 lib/40-cloudflared.sh 是旧版、缺少 _uninstall_cloudflared 时用）
# 只用于混装旧 lib 的机器, 故不复用 40 的 _cf_kill_all(可能根本不存在)。
# 注意 pgrep 在容器内会假阴性(H3), 因此**成功与否以事后的文件/进程事实为准**,
# 不以命令退出码为准 —— 原实现无条件打印"已卸载", 即便二进制仍在也报成功。
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
        # 事后校验: 二进制必须真的消失, 且没有残留进程(容器内 pidof 可能漏报,
        # 故两者都看; 任一不满足就如实报失败而不是宣称已卸载)
        if [ -e /usr/local/bin/cloudflared ]; then
            _error "cloudflared 二进制删除失败, 请手动检查 /usr/local/bin/cloudflared"
            return 1
        fi
        # 事后校验同样用 /proc 兜底扫描(只信 pidof 会在容器内漏报, 见上)
        if [ -n "$(_cf_fb_pids)" ]; then
            _warn "cloudflared 文件已删除, 但仍有残留进程, 请手动确认"
            return 1
        fi
        _success "cloudflared 已卸载 (fallback)"
    else
        _warn "cloudflared 未安装"
    fi
}

# ---------------------------------------------------------------------------
# 卸载菜单
# ---------------------------------------------------------------------------
_uninstall_menu() {
    local choice
    clear
    echo
    echo -e "  ${RED}【卸载 / 重置】${NC}"
    echo -e "  ${GREEN}[1]${NC} 重置 config.json 为默认(含 routing 规则, 清空节点)"
    echo -e "  ${GREEN}[2]${NC} 仅卸载 Xray"
    echo -e "  ${GREEN}[3]${NC} 卸载 Xray + cloudflared"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  选择: " choice
    # RT-4(2026-09-12 实测): [2]/[3] 是不可逆的整站卸载, 此前无任何确认 —— 单键误触
    # 即全毁, 与本脚本其他破坏性操作(删节点/重置配置)的 y/N 确认惯例不一致。补上。
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
                    # _uninstall_xray 会在官方 Hysteria2 进程停不掉时中途 return 1(文件未删),
                    # 此前返回值被忽略、用户仍看到"卸载完成"。如实报告: 失败时明确告知数据
                    # 可能残留, 但仍继续卸 cloudflared(独立子系统, 用户确实要求两个都卸)。
                    local xray_rc=0
                    _uninstall_xray || xray_rc=$?
                    if [ "$xray_rc" -ne 0 ]; then
                        _error "Xray 卸载未完成(见上方原因), 部署目录可能仍然存在, 请处理后重试"
                    fi
                    # 返回值必须消费: 两个实现都会在"文件已删但进程仍在"时返回 1,
                    # 忽略它会让用户看到"卸载完成"而实际上进程还活着。
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

# ---------------------------------------------------------------------------
# 重置 config.json 为默认(含 routing 规则, 清空节点); 保留 Xray 二进制
# ---------------------------------------------------------------------------
# 破坏性部分必须整体位于 config lock 内: backup、hop 清理、config 替换、metadata 清理和
# restart 之间不能让普通节点事务插入, 否则并发创建的节点会被 reset 在 rm config/nodes 时抹掉。
# 提问留在锁外, 避免用户思考时长期占住配置锁; wrapper 只负责前置检查/确认和取锁。
_reset_config() {
    echo
    # F10: 重建默认配置依赖 jq —— 先删后建, jq 缺失会留下"无 config + xray 起不来"的残局,
    # 必须在删除前确认重建能力
    if ! command -v jq >/dev/null 2>&1; then
        _error "jq 不可用, 无法重建默认配置, 已取消重置"
        _tip "请先安装 jq(主菜单启动时也会自动尝试安装), 再执行重置"
        return 1
    fi
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        local ncount ans
        ncount=$(_node_count 2>/dev/null)
        echo -e "  ${YELLOW}当前有 ${ncount} 个节点, 重置将清空所有节点配置${NC}"
        read -rp "  确认清空并重置 config.json? [y/N]: " ans
        case "$ans" in
            y|Y) ;;
            *) _info "已取消"; return 0 ;;
        esac
    fi
    # 全站破坏性操作遵循 install → config → core 的锁序, 与 uninstall 相同。
    # 仅取 config lock 会让 uninstall 在 install+core 锁内删除部署树, 把 config fd 拆成
    # deleted inode 后继续写 metadata/restart; 外层 install lock 先把两条破坏性路径串起来。
    if declare -F _with_deploy_install_lock >/dev/null 2>&1; then
        _with_deploy_install_lock _with_config_lock _reset_config_locked
    else
        # 混装旧 lib 的兼容降级: 至少保留原 config 锁保护, 不退回裸执行。
        _with_config_lock _reset_config_locked
    fi
}

# ---------------------------------------------------------------------------
# reset 的崩溃恢复(二十轮 P1-3)。
#
# reset 是"备份 → 移走 metadata/clash → 删 config → 重建"的多步事务, 进程被 SIGKILL/OOM/
# 掉电杀死时没有任何函数会被调用。故与 coretxn 同口径: **先把 journal(含 config 副本)
# 落盘, 再动任何真实状态**; 启动期发现未提交的 journal 就回滚到重置前, 已提交的只清理:
#   prepared  -> 已开始移动 metadata/clash, 崩溃必须回滚(config 也回到副本)
#   committed -> 重置后状态已生效, 崩溃只需清理快照与 journal
# 快照目录用**固定名**: reset 全程持有 install+config 锁, 同一时刻只可能有一个 reset 事务。
# journal 经 `_atomic_write_json` 提交(内部 fsync 文件 + 父目录), 掉电不会读到半写 phase。
# ---------------------------------------------------------------------------
_reset_journal_path() { printf '%s' "$DEPLOY_DIR/.reset-journal.json"; }
_reset_snapshot_path() { printf '%s' "$DEPLOY_DIR/.reset-snapshot"; }

_reset_journal_quarantine() {   # <journal> <原因>
    local journal="$1" why="$2" bad i=0
    bad="${journal}.corrupt"
    while [ -e "$bad" ]; do i=$((i+1)); bad="${journal}.corrupt.${i}"; done
    if mv "$journal" "$bad" 2>/dev/null; then
        _warn "reset 事务日志${why}, 已隔离为 $bad; 快照保留在 $(_reset_snapshot_path) 供人工检查"
    else
        _warn "reset 事务日志${why}且隔离失败, 请人工检查: $journal"
    fi
    return 1
}

# 回滚"未提交的 reset"的文件系统侧。config 优先用快照里的副本恢复(不依赖会被后续事务
# 覆盖的 lastbak); 重置前没有 config 时回滚即恢复"无配置"。
_reset_config_snapshot_restore() {   # <stage> <nodes_moved> <clash_moved> <had_config>
    local stage="$1" nodes_moved="$2" clash_moved="$3" had_config="$4" ok=0
    if [ "$had_config" -eq 1 ]; then
        if [ -s "$stage/config.json" ]; then
            if ! _atomic_write_json "$CONFIG_FILE" "$(cat "$stage/config.json" 2>/dev/null)"; then
                _error "配置回滚失败, 请手动从快照副本恢复: $stage/config.json"
                ok=1
            fi
        elif ! _restore_config; then
            _error "配置回滚失败, 请手动从 $BACKUP_DIR/config.json.lastbak 恢复"
            ok=1
        fi
    else
        rm -f "$CONFIG_FILE" 2>/dev/null || ok=1
    fi
    if [ "$nodes_moved" -eq 1 ]; then
        rm -rf "$NODES_DIR" 2>/dev/null || ok=1
        if ! mv "$stage/nodes" "$NODES_DIR" 2>/dev/null; then ok=1; fi
    fi
    if [ "$clash_moved" -eq 1 ]; then
        rm -f "$CLASH_YAML" 2>/dev/null || ok=1
        if ! mv "$stage/clash.yaml" "$CLASH_YAML" 2>/dev/null; then ok=1; fi
    fi
    if [ "$ok" -eq 0 ]; then
        rm -rf "$stage" 2>/dev/null || ok=1
    fi
    return "$ok"
}

# 回滚 + 清 journal(仅回滚完整时才清账本); 不完整则保留 journal 与快照供启动期重试。
_reset_config_abort_locked() {   # <stage> <nodes_moved> <clash_moved> <had_config>
    local stage="$1" journal
    if ! _reset_config_snapshot_restore "$@"; then
        _error "reset 回滚不完整, 快照与事务日志保留供下次启动重试: $stage"
        return 1
    fi
    journal=$(_reset_journal_path)
    rm -f "$journal" 2>/dev/null || _warn "reset 事务日志清理失败, 下次启动会自动收敛"
    _warn "已回滚, 重置未生效: 配置与节点数据均保持原样"
    return 0
}

# 带锁的恢复入口(启动期/菜单调用); `_reset_config_locked` 内部直接调 locked 体。
_reset_config_recover() {
    _with_config_lock _reset_config_recover_locked
}

_reset_config_recover_locked() {
    local journal snapshot phase had_config nodes_moved=0 clash_moved=0
    journal=$(_reset_journal_path)
    snapshot=$(_reset_snapshot_path)
    if [ ! -e "$journal" ]; then
        # journal 是提交顺序里的**最后**一个文件: 没有它, 快照只能是"写 journal 之前"的
        # 残骸或已提交后的清理残留, 两者都无权威可恢复, 直接清掉。
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
       { [ "$phase" != "prepared" ] && [ "$phase" != "committed" ]; }; then
        _reset_journal_quarantine "$journal" "schema 非法"
        return 1
    fi
    had_config=$(jq -r 'if .had_config == true then 1 else 0 end' "$journal" 2>/dev/null)
    case "$had_config" in
        0|1) ;;
        *) _reset_journal_quarantine "$journal" "had_config 非法"; return 1 ;;
    esac
    if [ "$phase" = "committed" ]; then
        if ! rm -rf "$snapshot" 2>/dev/null || [ -e "$snapshot" ]; then
            _warn "reset 已提交, 但快照清理失败(下次启动重试): $snapshot"
            return 1
        fi
        rm -f "$journal" 2>/dev/null || { _warn "reset journal 清理失败: $journal"; return 1; }
        _info "上次 reset 已提交, 已清理残留快照"
        return 0
    fi
    [ -d "$snapshot/nodes" ] && nodes_moved=1
    [ -f "$snapshot/clash.yaml" ] && clash_moved=1
    if ! _reset_config_snapshot_restore "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"; then
        _warn "上次 reset 崩溃后的回滚不完整, 快照与 journal 保留供重试: $snapshot"
        return 1
    fi
    rm -f "$journal" 2>/dev/null || { _warn "reset journal 清理失败: $journal"; return 1; }
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
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        had_config=1
        # 2026-09-12 三审(M1): 重置是清空全部节点数据的破坏性操作, 备份失败(磁盘满/IO 错误)
        # 必须中止 —— 原写法忽略返回值, 备份失败仍 rm config, 用户在无备份情况下丢失全部节点。
        if ! _backup_config; then
            _error "配置备份失败(磁盘空间/IO?), 已取消重置以保护现有数据"
            return 1
        fi
    fi
    if [ "$had_config" -eq 1 ]; then had_json=true; else had_json=false; fi
    # 清理端口跳跃 iptables 规则(必须在删除节点元数据之前, 且在 rm config 前, M22)
    if declare -F _hy2_cleanup_all_hops >/dev/null 2>&1; then
        if ! _hy2_cleanup_all_hops; then
            _error "端口跳跃规则清理失败, 已取消重置(配置与节点数据保留), 请处理后重试"
            return 1
        fi
    fi
    # 恢复源与账本先落盘, 再动任何真实状态: 崩溃时才有据可回滚。
    if [ -e "$snapshot" ] || ! mkdir "$snapshot" 2>/dev/null; then
        _error "无法创建 reset 恢复快照目录, 已取消重置以保护现有数据"
        return 1
    fi
    if [ "$had_config" -eq 1 ]; then
        # config 副本是比 lastbak 更可靠的恢复源(lastbak 会被后续任何配置事务覆盖)。
        if ! cp -f "$CONFIG_FILE" "$snapshot/config.json" 2>/dev/null || [ ! -s "$snapshot/config.json" ]; then
            _error "无法保存重置前的配置快照, 已取消重置以保护现有数据"
            rm -rf "$snapshot" 2>/dev/null
            return 1
        fi
    fi
    if ! _atomic_write_json "$journal" "{\"snapshot\":\"$snapshot\",\"phase\":\"prepared\",\"had_config\":$had_json}"; then
        _error "无法写入 reset 事务日志(磁盘空间/权限?), 已取消重置以保护现有数据"
        rm -rf "$snapshot" 2>/dev/null
        return 1
    fi
    if [ -d "$NODES_DIR" ]; then
        # mv 失败时 NODES_DIR 仍是原件, **绝不能**走恢复路径(那里会 rm -rf 它再去搬
        # 快照里不存在的内容 ⇒ 直接毁掉全部节点元数据)。只有 mv 确认成功才置 nodes_moved。
        if ! mv "$NODES_DIR" "$snapshot/nodes" 2>/dev/null; then
            _error "无法准备节点 metadata 恢复快照, 已取消重置以保护现有数据"
            _reset_config_abort_locked "$snapshot" 0 0 "$had_config"
            return 1
        fi
        nodes_moved=1
        if ! mkdir -p "$NODES_DIR" 2>/dev/null; then
            _error "无法重建节点 metadata 目录, 正在恢复重置前的快照"
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
    fi
    # 删掉 config 让 _init_config_if_empty 重建。
    # **重建失败必须回滚**(2026-09-22 九轮 OCR #41): 不滚会留下"既没有配置、也没有节点
    # 元数据"; 回滚源是快照里的 config 副本与 metadata/clash, 失败时保留 journal 供启动重试。
    if ! rm -f "$CONFIG_FILE" 2>/dev/null; then
        _error "无法删除旧 config.json, 已取消重置以保护现有数据"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    if ! _init_config_if_empty; then
        _error "重建默认配置失败(只读/磁盘空间/jq 异常?), 正在回滚到重置前的配置"
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
    # COMMIT: phase 先 durable 落盘, 之后**绝不再回滚**; 任一步失败都留 committed journal
    # 给启动恢复做 cleanup。
    if ! _atomic_write_json "$journal" "{\"snapshot\":\"$snapshot\",\"phase\":\"committed\",\"had_config\":$had_json}"; then
        _error "重置已应用但提交日志写入失败, 正在回滚"
        _reset_config_abort_locked "$snapshot" "$nodes_moved" "$clash_moved" "$had_config"
        return 1
    fi
    if ! rm -rf "$snapshot" 2>/dev/null || [ -e "$snapshot" ]; then
        _warn "重置已应用, 但旧 metadata/clash 快照清理失败(下次启动会重试): $snapshot"
        return 0
    fi
    rm -f "$journal" 2>/dev/null || _warn "reset 事务日志清理失败, 下次启动会自动清理"
    # 重启 xray(若在跑)
    if [ -x "$XRAY_BIN" ]; then
        if _restart_xray_verified; then
            _tip "xray 已使用新配置重启"
        else
            _warn "配置重置后 xray 重启失败, 请检查状态"
        fi
    fi
    _success "config.json 已重置(含 routing 规则), 节点已清空"
}

# ---------------------------------------------------------------------------
# 检测脚本更新
# 本地版本从 $DEPLOY_DIR/VERSION 文件读取, 远程从 GitHub raw 拉取
# 以后只需改 VERSION 文件, 不用动代码
# 可通过环境变量 XRAY_DEPLOY_RAW 覆盖上游 raw URL（如自建镜像/私有 fork）
#
# **信任模型(必须明示)**: 自更新会把下载到的 install.sh 以 root 执行。当前校验只有
# "非空 + bash -n 语法检查" —— 二者都挡不住**恶意但语法合法**的内容。因此:
#   * `XRAY_DEPLOY_RAW` 指向的源被视为**受信源**(自建镜像/私有 fork 由用户自己负责);
#     该变量来自调用者环境, 若脚本被以被污染的环境拉起, 攻击者可控制下载内容。
#   * 要真正做到来源可信, 需要上游发布**签名或校验和**并与脚本一同验证 —— 本项目尚未
#     建立该发布流程, 故不做"假装校验"的假动作(如只比长度/前缀)。
# 这条注释就是该取舍的显式声明; 引入校验和发布流程前, 不要移除它。
# ---------------------------------------------------------------------------
SCRIPT_VERSION_URL="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}/VERSION"

# ---------------------------------------------------------------------------
# 终端安全显示: 把来自外部(state 文件 / 远端 HTTP 响应)的短字符串限制在安全字符集内。
# 这些值会被 echo -e 直接打屏, 而 echo -e 会解释 ANSI 转义 —— 一个被劫持的响应或被写坏
# 的 state 文件就能向管理员的终端注入转义序列(改标题、伪造输出、清屏)。
# 允许集刻意保守: 版本号/通道名只需 [0-9A-Za-z._-]。
# ---------------------------------------------------------------------------
# 校验 + 净化: 含任何非安全字符时**返回 1**(调用方拒绝该值), 否则原样输出。
# 为什么不能"静默剥掉非法字符": 被劫持/损坏的响应 `v1.2.3<!--x` 会被剥成 `v1.2.3`,
# 看起来完全合法并被当作权威版本号去比对, 从而给出"已是最新"的错误结论。
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
    # 远端响应是外部输入: 必须**整体合法**才接受(既防 ANSI 转义注入终端, 也防
    # "截断后看起来合法"导致的错误"已是最新"结论)。
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
                # R38(M13): 只判非空挡不住"截断但非空"的下载(chunked 传输、劫持插入的 HTML
                # 片段、CDN 部分内容)。install.sh 头部就有 root 检查/依赖安装/mkdir 等副作用,
                # 半截脚本执行到 download_all 定义前断掉会留下不可预期的中间状态。
                # bash -n 只做语法解析、不执行任何命令, 能拦掉绝大多数截断。
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

# ---------------------------------------------------------------------------
# Hysteria2 管理子菜单
# ---------------------------------------------------------------------------
_hy2_manage_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【Xray Hy2 管理 (Xray-core 实现)】${NC}"
        # 暂无节点守卫 (M18: CLAUDE.md 规约 — 无节点时显示警告)
        if ! _has_hy2_nodes; then
            echo -e "  ${YELLOW}暂无 Xray Hy2 节点${NC}"
        fi
        echo
        echo -e "  ${GREEN}[1]${NC} 切换拥塞控制 (bbr/brutal/force-brutal)"
        echo -e "  ${GREEN}[2]${NC} 调整 brutal 带宽"
        echo -e "  ${GREEN}[3]${NC} 端口跳跃 (iptables)"
        echo -e "  ${GREEN}[4]${NC} 查看端口跳跃状态"
        echo -e "  ${GREEN}[5]${NC} 混淆 salamander / gecko (FinalMask.udp)"
        # masquerade 是**另一个机制**(HTTP 页面), 不能与 [5] 的链路混淆混为一谈标为"伪装":
        # 菜单标签必须各自点出所属配置路径, 否则用户会以为 [5] 就是伪装页面的开关。
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

# ---------------------------------------------------------------------------
# [6] HTTP/3 页面伪装 masquerade(hysteriaSettings.masquerade)
#
# **本项与 [5] 混淆(FinalMask.udp)是两个独立机制** —— 菜单文案必须点明, 否则用户会把
# "伪装"理解成混淆的别名(两者都叫"伪装"但改的是完全不同的东西):
#   [5] finalmask.udp → 改变链路上的 QUIC 字节(抗特征识别)
#   [6] masquerade    → 非 Hysteria 客户端连上端口时回什么 HTTP 页面(抗主动探测)
# 用户可以只开其一, 也可以都开。
#
# 节点选择与 [5] 同口径: 多节点时必须先选节点(要求 7 —— 绝不能改错节点), 且提交前校验
# 该入站**真实存在于 config.json**: 元数据在而 config 被手工改过时, jq 会匹配 0 条路径并
# 返回 0, _mutate_config 重启成功却什么都没改, 菜单却报"已设置"。
# ---------------------------------------------------------------------------
# 节点编号解析的唯一入口(成功时 stdout 输出 tag; 失败返回 1)。
#
# **为什么不能只写 `[[ $c =~ ^[0-9]+$ ]]` 然后 `$((c-1))`**:
#   bash 算术是 64 位有符号, 超大十进制会**回绕成负数**, 而数组负索引是合法的 ——
#   实测 choice=18446744073709551615 => idx=-2 => tags[-2] 命中**倒数第二个节点**。
#   即"输入一个看起来完全无效的超大编号"会**改错节点**, 与"绝不能改错节点"直接冲突。
#   该模式在 90-menu 里原有 4 处(本次新增的第 5 处在 masquerade 菜单), 故收口为唯一入口。
#
# 四道闸门, 顺序不可交换:
#   ① 纯数字(任何其它字符直接拒) ② **去前导零后再限长** —— 长度闸门必须先于算术,
#   否则超长数在 `$(( ))` 里已经回绕了 ③ 范围 1..n ④ 最后才做减一。
# 前导零单独处理有两种必要: bash 把 `08`/`09` 当**八进制**会报错(故用 `10#` 显式十进制),
# 且 `0000001` 这类"长但数值很小"的输入不该被长度闸门误杀。
_hy2_select_node() {   # <choice> <tag1> [<tag2> ...]
    local c="${1:-}"
    shift || return 1
    [ -n "$c" ] || return 1
    case "$c" in *[!0-9]*) return 1 ;; esac
    # 去前导零(bash 的 ${var#pattern} 只删最短匹配, 故迭代到无前导零为止)
    while :; do
        case "$c" in 0*) c="${c#0}" ;; *) break ;; esac
    done
    [ -n "$c" ] || return 1
    # 长度闸门: 节点数不可能到 7 位; 必须在任何算术之前
    [ "${#c}" -le 6 ] || return 1
    local total=$#
    [ "$total" -gt 0 ] || return 1
    local n=$((10#$c))
    [ "$n" -ge 1 ] && [ "$n" -le "$total" ] || return 1
    local -a tags=("$@")
    printf '%s' "${tags[$((n-1))]}"
    return 0
}

# ---------------------------------------------------------------------------
_hy2_masq_menu() {
    local choice
    clear
    _has_hy2_nodes || { _warn "暂无 Xray Hy2 节点"; _press_any_key; return; }
    # 版本门控(要求 1 的兼容性硬约束): 核心 < v26.3.23 不认该字段, Go JSON 静默忽略 ⇒
    # 写进去也不生效, 只有被主动探测时才暴露。故在这里就拒绝, 并说清为什么。
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
    # 编号解析收口到唯一入口: 原写法 $((choice-1)) + 负索引会让超大编号选错节点
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; return; }

    # 入站必须真实存在于 config(见文件头注释: 否则 jq 0 命中而菜单报成功)
    jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length > 0' "$CONFIG_FILE" >/dev/null 2>&1 \
        || { _error "config.json 中找不到该节点的入站(${tag}); 请先同步/修复配置"; _press_any_key; return; }

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

# 文件伪装: type=file + dir(核心 http.FileServer(http.Dir(dir)))。
# 每个字段都是"只重问当前字段"的循环(要求 3): 输入非法时已确认的节点选择与其它字段
# 全部保留; EOF(read 失败)一律 return 1 中止, 绝不空转、也不兜默认值。
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

# 反向代理: type=proxy + url / rewriteHost / insecure。
# 这三项都要问, 是因为它们的取值决定了"回源时 Host 头是什么"与"是否校验证书",
# 而这两个语义用户无法从别处推断 —— 与 official Hysteria 侧形状不同, 不能互抄。
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
    # 布尔问题必须与其它枚举同口径: 非法输入**重问**, 不能落进 *) 被静默当默认值
    # (要求 4: 不把非法值当默认值)。空输入才是"取默认"。
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
        [ "$ins" = "true" ] && _warn "已跳过证书校验: 中间人可替换回源内容(仅在自签/证书不匹配时需要)"
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

# 固定字符串: type=string + content / headers / statusCode。
# content 逐行收集(单独一行 "." 结束): 真实伪装页多是多行 HTML, 单行 read 表达不了。
# EOF 语义在这里**有意区分**两种情况(与"必答字段 EOF 即中止"不同):
#   - 已有内容时收到 EOF: 输入完成(与 cat 一致), 提交 —— 丢弃用户刚敲进去的 HTML 更糟;
#   - 没有任何内容时收到 EOF: 中止本项(不写配置)。
# 两种都不会空转。headers 逐行收集(见 _hy2_masq_headers_merge: 不能按逗号切)。
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
    # EOF 语义(与"必答字段 EOF 即中止"不同, 此处**有意**允许 EOF 收尾):
    #   响应头是**可选多行收集器** —— 空行与 EOF 在这里都只表示"不再输入"(空集合法,
    #   headers 本就是可选的), 且此处不存在"丢弃用户已输入内容"的风险。
    #   故 EOF 不再上抛取消: 否则 `printf "200\n" | 菜单` 这类自动化(末行无换行)会被取消。
    #   必答字段(状态码/URL/目录…)仍一律 EOF => return 1, 见 _hysteria_ask_* 与各输入循环。
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

# ---------------------------------------------------------------------------
# Hysteria2: 切换 brutal / bbr
# ---------------------------------------------------------------------------
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
    # 编号解析收口到唯一入口: 原写法 $((choice-1)) + 负索引会让超大编号选错节点
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
    [ "$new_cc" = "$cur_cc" ] && { _info "已是 ${new_cc} 模式, 无需切换"; _press_any_key; return; }

    case "$new_cc" in
        bbr)
            if ! _mutate_config --arg t "$tag" \
                 '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) = {congestion: "bbr"}'; then
                _error "切换失败, 已回滚"; _press_any_key; return
            fi
            _meta_update "$meta" '.congestion=$cc | del(.brutal_up) | del(.brutal_down)' --arg cc "$new_cc" || { _error "元数据写入失败"; _press_any_key; return; }
            _success "已切换为 bbr 模式"
            ;;
        brutal)
            echo -e "  ${YELLOW}brutal 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
            local brutal_up="" brutal_down=""
            read -rp "  上传带宽 (回车不限): " brutal_up
            read -rp "  下载带宽 (回车不限): " brutal_down
            brutal_up=$(_normalize_bandwidth "$brutal_up")
            brutal_down=$(_normalize_bandwidth "$brutal_down")
            if ! _mutate_config --arg t "$tag" --arg up "$brutal_up" --arg down "$brutal_down" \
                 '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) =
                  ({congestion: "brutal"}
                   + (if $up != "" then {brutalUp: $up} else {} end)
                   + (if $down != "" then {brutalDown: $down} else {} end))'; then
                _error "切换失败, 已回滚"; _press_any_key; return
            fi
            _meta_update "$meta" '.congestion=$cc | .brutal_up=$up | .brutal_down=$down' --arg cc "$new_cc" --arg up "$brutal_up" --arg down "$brutal_down" || { _error "元数据写入失败"; _press_any_key; return; }
            _success "已切换为 brutal 模式"
            [ -n "$brutal_up" ] && echo -e "  ${CYAN}上传:${NC} ${brutal_up}"
            [ -n "$brutal_down" ] && echo -e "  ${CYAN}下载:${NC} ${brutal_down}"
            ;;
        force-brutal)
            echo -e "  ${YELLOW}force-brutal 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
            local brutal_up="" brutal_down=""
            read -rp "  上传带宽 (回车不限): " brutal_up
            read -rp "  下载带宽 (回车不限): " brutal_down
            brutal_up=$(_normalize_bandwidth "$brutal_up")
            brutal_down=$(_normalize_bandwidth "$brutal_down")
            if ! _mutate_config --arg t "$tag" --arg up "$brutal_up" --arg down "$brutal_down" \
                 '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) =
                  ({congestion: "force-brutal"}
                   + (if $up != "" then {brutalUp: $up} else {} end)
                   + (if $down != "" then {brutalDown: $down} else {} end))'; then
                _error "切换失败, 已回滚"; _press_any_key; return
            fi
            _meta_update "$meta" '.congestion=$cc | .brutal_up=$up | .brutal_down=$down' --arg cc "$new_cc" --arg up "$brutal_up" --arg down "$brutal_down" || { _error "元数据写入失败"; _press_any_key; return; }
            _success "已切换为 force-brutal 模式"
            _tip "force-brutal: 强制使用 brutalUp 固定发包速率, 无视对端协商"
            [ -n "$brutal_up" ] && echo -e "  ${CYAN}上传:${NC} ${brutal_up}"
            [ -n "$brutal_down" ] && echo -e "  ${CYAN}下载:${NC} ${brutal_down}"
            ;;
    esac
    # 派生状态(链接 + clash)走**唯一入口** _hy2_sync_derived(50-nodes): gecko 节点的链接
    # 无法用官方 hy2 URI 表达, 此时必须清空旧链接并**继续**同步 clash(clash 能完整承载该尺寸),
    # 而不是在此以"重建失败"提前 return —— 那会把旧链接与旧 clash 条目一并留下(stale)。
    _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# Hysteria2: 调整 brutal 带宽(仅 brutal 模式)
# ---------------------------------------------------------------------------
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
    # 编号解析收口到唯一入口: 原写法 $((choice-1)) + 负索引会让超大编号选错节点
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
    new_up=${new_up:-$cur_up}
    read -rp "  新下载带宽: " new_down
    new_down=${new_down:-$cur_down}
    new_up=$(_normalize_bandwidth "$new_up")
    new_down=$(_normalize_bandwidth "$new_down")

    if ! _mutate_config --arg t "$tag" --arg up "$new_up" --arg down "$new_down" \
         '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) |=
          (. + (if $up != "" then {brutalUp: $up} else {} end)
               + (if $down != "" then {brutalDown: $down} else {} end))'; then
        _error "带宽调整失败, 已回滚"; _press_any_key; return
    fi
    _meta_update "$meta" '.brutal_up=$up | .brutal_down=$down' --arg up "$new_up" --arg down "$new_down" || { _error "带宽元数据写入失败"; _press_any_key; return; }
    # 派生状态(链接 + clash)走**唯一入口** _hy2_sync_derived(50-nodes) —— 与拥塞切换同源:
    # 带宽变化会改变 clash 条目的 up/down 字段, gecko 节点则链接不可表达(清空 + 继续同步 clash)。
    _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    _success "带宽已更新: 上传=${new_up:-不限}  下载=${new_down:-不限}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# Hysteria2: 混淆 salamander / gecko (FinalMask.udp)
# 官方依据: Xray-docs-next config/transports/finalmask.md「UDPMask」
#   finalmask.udp = [ {type:"salamander", settings:{password, packetSize}} ]
#   packetSize 为 Int32Range, 非空即启用 Gecko(QUIC 长包头额外分片填充), 上限 2048。
# 注意: 官方文档没有 hysteriaSettings.obfs 字段; 链接侧 obfs/obfs-password 参数名
# 来自 Hysteria 官方 URI-Scheme(Xray 文档未定义 hy2 分享链接)。
# 服务端变更走 _mutate_config(事务 + verified-restart + 回滚); 元数据在 config 提交成功后写,
# 失败时把 config 回滚为**改动前**的混淆形态(不是一律清空), 保持两侧一致
# (顺序与 _hy2_toggle_brutal 一致; 回滚见 _hy2_obfs_rollback)。
# ---------------------------------------------------------------------------
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
    # 编号解析收口到唯一入口: 原写法 $((choice-1)) + 负索引会让超大编号选错节点
    local tag
    tag=$(_hy2_select_node "$choice" "${tags[@]}") || { _warn "无效选择"; _press_any_key; return; }

    # 入站必须真实存在于 config: 元数据在而 config 被手工改过时, 下面的
    # `(.inbounds[] | select(.tag == $t)) |= …` 会匹配 0 条路径 —— jq 返回 0、
    # 配置原样不动, _mutate_config 重启成功并报"已启用", 于是元数据与服务器再次分裂。
    jq -e --arg t "$tag" '[.inbounds[]? | select(.tag == $t)] | length > 0' "$CONFIG_FILE" >/dev/null 2>&1 \
        || { _error "config.json 中找不到该节点的入站(${tag}); 请先同步/修复配置"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_type cur_pw cur_size
    cur_type=$(jq -r '.obfs_type // empty' "$meta")
    cur_pw=$(jq -r '.obfs_password // empty' "$meta")
    cur_size=$(_hy2_obfs_size_get "$meta")
    # 回滚目标 = **改动前**的混淆形态(不是"无混淆"): 元数据写失败时若一律回滚成
    # udp:[], 一个正在用混淆工作的节点会被静默清成无混淆, 而链接/clash 仍写着 obfs
    # ⇒ 所有已分发客户端立刻连不上。cur_type 为空时该表达式自然得到 [], 首次启用不受影响。
    local rollback_mask
    rollback_mask=$(_hy2_obfs_mask_block "$cur_type" "$cur_pw" "$cur_size") || rollback_mask="__INVALID__"
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
            # 启用/更换 的 fail-closed 闸门: 该入站若已有一层**不是我们写的** type=salamander,
            # 追加我们那层会让 Xray 依次套两层 salamander(双重混淆, 客户端只做一层 ⇒ 必然
            # 连不上)。不替用户猜(既不吃掉别人的层, 也不硬套), 交人工处理。
            # **只挡 1|2, 不挡 3**: 关闭只剔除我们自己带标记的那层、保留别人的层, 是完全
            # 安全的操作 —— 在菜单入口无条件拦截会让用户连自己那层都删不掉(实测缺陷)。
            if _hy2_udp_has_foreign_salamander "$tag"; then
                _error "该入站的 finalmask.udp 已存在**非本脚本写入**的 salamander 层;"
                _error "继续启用会叠加成双重混淆(客户端只做一层, 必然连不上)。"
                _tip "请先手工编辑 ${CONFIG_FILE} 移除或改名该层(本脚本写入的层带 settings.xd_managed=true)"
                _tip "若只想关闭本脚本的混淆, 请选 [3](只删本脚本那层, 保留其它层)"
                _press_any_key; return
            fi
            otype="salamander"
            opw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " opw_in
            opw=${opw_in:-$opw}
            _validate_json_text "$opw" || { _error "混淆密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; _press_any_key; return; }
            if [ "$obfs_choice" = "2" ]; then
                # gecko 需要核心支持 packetSize; 旧核心静默忽略该字段 ⇒ 服务端退化成无分片。
                # **不支持时直接拒绝, 不自动降级** —— 用户明确选了 gecko, 替他改成另一种混淆
                # 形态是改变请求(且客户端按 gecko 配、服务端跑 salamander)。版本门控的存在
                # 本身已表明"旧核心无法安全承载 gecko", 故 fail-closed。
                if ! _hy2_gecko_supported; then
                    _error "当前核心不支持 gecko 分片(packetSize 需核心 >= ${_HY2_GECKO_MIN_VER}); 已取消, 未修改任何配置"
                    _tip "请先升级/切换 Xray 核心, 或改选 [1] 普通 salamander"
                    _press_any_key; return
                fi
                # 空输入必须落成显式尺寸: Xray 侧 packetSize 留空 = **不启用 Gecko**
                # (退化成普通 salamander)。所填 512-1200 来自 Hysteria 官方
                # Full-Client-Config 的 gecko 默认值, 不是 Xray 文档里的默认值。
                read -rp "  packetSize (Int32Range, 如 512-1200; 回车用 Hysteria 官方 gecko 默认 512-1200): " osize
                osize="${osize:-512-1200}"
                local size_why; size_why=$(_hy2_obfs_size_invalid "$osize")
                [ -n "$size_why" ] && { _error "packetSize 非法: ${size_why}"; _press_any_key; return; }
                # 规范化(排序 + 去前导零)后回写, 使元数据/clash 与 Xray 看到同一区间
                osize=$(_hy2_obfs_size_canon "$osize") || { _error "packetSize 规范化失败"; _press_any_key; return; }
            fi
            omask=$(_hy2_obfs_mask_block "$otype" "$opw" "$osize") || { _error "混淆参数构造失败"; _press_any_key; return; }
            # 只管理**我们自己那一层**(见 XD_UDP_JQ_UPSERT): 用户/其它工具可能在同一
            # udp 数组里放了别的伪装层(含别人的 salamander 层), 只按 type 匹配会吃掉它们。
            # 归属由我们写入的 settings.xd_managed 标记判定。
            if ! _mutate_config --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" --argjson new "$omask" \
                 "$XD_UDP_JQ_UPSERT"; then
                _error "混淆启用失败, 已回滚"; _press_any_key; return
            fi
            if ! _meta_update "$meta" \
                 '.obfs_type=$t | .obfs_password=$p | .obfs_packet_size=(if $s == "" then null else $s end)' \
                 --arg t "$otype" --arg p "$opw" --arg s "$osize"; then
                # config 已提交而元数据未落地 → 回滚 config(回到**改动前**的形态), 否则链接/clash 与服务器行为不一致
                _hy2_obfs_rollback "$tag" "$rollback_mask" \
                    || _error "元数据写入失败, 且配置回滚失败, 请手工检查 ${CONFIG_FILE}"
                _error "混淆元数据写入失败, 已回滚配置"
                _press_any_key; return
            fi
            _success "混淆已启用 (${otype}${osize:+ · packetSize=${osize}})"
            ;;
        3)
            if ! _mutate_config --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" --argjson new null \
                 "$XD_UDP_JQ_UPSERT"; then
                _error "关闭混淆失败, 已回滚"; _press_any_key; return
            fi
            if ! _meta_update "$meta" 'del(.obfs_type) | del(.obfs_password) | del(.obfs_packet_size)'; then
                _hy2_obfs_rollback "$tag" "$rollback_mask" \
                    || _error "元数据写入失败, 且配置回滚失败, 请手工检查 ${CONFIG_FILE}"
                _error "混淆元数据写入失败, 已回滚配置"
                _press_any_key; return
            fi
            _success "混淆已关闭"
            ;;
        *) _warn "无效选择"; _press_any_key; return ;;
    esac
    # 服务器级变更 → 派生状态(链接 + clash)走**唯一入口** _hy2_sync_derived(50-nodes):
    # 与创建/改端口/拥塞切换/带宽调整同源。链接重建的两种失败在 helper 内区分 ——
    #   (a) gecko(带尺寸) ⇒ 官方 hy2 URI 无法表达: 清空旧链接 + **继续**同步 clash(能完整承载该尺寸);
    #   (b) 元数据缺字段 ⇒ **保留**旧链接, 如实报告, 不做破坏性写入。
    _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    _press_any_key
}

# 把 config 里该节点的**我们那一层** finalmask.udp 回滚为指定形态(见 _hy2_obfs_menu 的回滚路径)。
# $2 = _hy2_obfs_mask_block 的输出; 空 ⇒ 回滚成"无混淆"(只剔除我们那层, 保留其它层),
# 为 __INVALID__ ⇒ 改动前的元数据本身无法解析(畸形), 此时**拒绝动 config**:
# 拿"无混淆"当回滚值会把一个可能在工作的混淆配置静默清掉, 宁可不回滚并如实报告。
# 用法: _hy2_obfs_rollback <tag> <mask_or_empty_or_INVALID>
_hy2_obfs_rollback() {
    local tag="$1" mask="$2"
    if [ "$mask" = "__INVALID__" ]; then
        _error "改动前的混淆元数据无法解析, 未回滚配置(请手工核对 ${CONFIG_FILE})"
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
# ---------------------------------------------------------------------------
# Reality 域名切换的**后置步骤失败回滚**(2026-09-22 九轮 OCR #43)。
#
# `_mutate_config` 提交之后还有三步: metadata 写入 → 分享链接重建 → clash 派生缓存同步。
# 旧写法在这三步失败时只 `_error`/`_warn` + `continue`, 于是残局是
# **config 已是新 SNI, 而 metadata/链接仍是旧的** —— config 是"事实"、metadata 是"声明",
# 两者分裂后, 节点列表/分享链接/改端口/域名切换全都按 metadata 走, 用户看到的是一个
# 与服务器实际行为不符的节点。同项目的 `_port_txn`/`_hy2_port_txn` 对同类窗口都是回滚语义。
#
# 还原源:
#   · config —— `_mutate_config` 在改动前自己调过 `_backup_config`, 故
#     `$BACKUP_DIR/config.json.lastbak` 正是切换前那一份, 直接用 `_restore_config`。
#   · metadata —— 调用方在提交前把原文读进 `_reality_meta_prev`(节点元数据很小, 不必落盘)。
# 还原后必须重新确认服务稳定(`_restart_xray_verified`), 因为它才是我方"新配置可用"的判据。
#
# 参数: <meta 路径> <metadata 原文>
# 调用者: **必须**在 `_reality_domain_txn_locked` 的锁域内(见下面"锁域"一节)。
# ---------------------------------------------------------------------------
_reality_switch_rollback() {
    local meta="$1" meta_prev="${2:-}"
    # 锁域是这里的前提: `_restore_config` 读的是**共享**的 `config.json.lastbak`, 而它由
    # `_backup_config` 在每次 config 写入前覆盖。锁外调用时, 另一会话只要在"`_mutate_config`
    # 返回"与"后置步骤失败"之间改过 config, `lastbak` 就已经不是本次事务前的那一份, 回滚会把
    # 别人**已提交**的改动一起抹掉(十轮 P1-③)。锁域内则保证该快照自始至终属于本次事务。
    if _restore_config; then
        _restart_xray_verified >/dev/null 2>&1 || \
            _warn "配置已还原, 但 xray 未能稳定重启, 请查看状态"
        if [ -n "$meta_prev" ]; then
            _atomic_write_json "$meta" "$meta_prev" 2>/dev/null || \
                _warn "元数据还原失败, 请手动核对: $meta"
        else
            _warn "没有元数据快照可还原, 请手动核对: $meta"
        fi
        _error "域名切换未完成(后置步骤失败), 配置与元数据已还原到切换前"
        return 0
    else
        _error "后置步骤失败, 且配置回滚失败 —— 请手动核对 $CONFIG_FILE 与 $meta"
        _tip "可用备份: $BACKUP_DIR/config.json.lastbak"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Reality 域名切换的**整个提交事务**(2026-09-22 十轮 P1-③)。
#
# 九轮把"后置失败回滚"做出来了, 但回滚源是**共享的** `config.json.lastbak`, 而该文件只在
# `_mutate_config` 内部被锁保护 —— 事务的其余部分(metadata 写入、链接重建、失败回滚)都在
# 锁**外**。于是并发场景: A 的 `_mutate_config` 提交并释放锁 → B 修改 config(覆盖 lastbak)
# → A 的后置步骤失败 → A 用 **B 的快照**回滚, 把 B 已提交的改动静默抹掉(丢失更新)。
# 同文件的 `_reality_port_txn` / `_hy2_port_txn` 早已是"整个事务在锁内"的形态 —— 这条路径
# 漏了同一层保护。
#
# 锁域范围: config 提交 → metadata → 链接重建 → 失败回滚, 全部在 `_with_config_lock` 内。
# **网络步骤(后量子检测)刻意留在锁外** —— 它可能耗时十几秒, 拿它占着全局 config 锁会让
# 并发的另一会话全部撞 15s 锁超时。锁内只有本地文件写入与一次服务重启确认, 与端口事务同量级。
# `_mutate_config` 经 XRAY_DEPLOY_LOCK_HELD 可重入, 不会自锁死(与 _reality_port_txn 同款)。
#
# 参数: <tag> <meta> <new_sni> <pq_seed> <pq_verify> <rmode> <tunnel_tag>
#       <new_tunnel_tag> <reality_target> <meta_prev>
# 返回: 0 = 提交成功;
#       1 = 失败但已完整回滚(原因已打印, 调用方无需再回滚);
#       2 = 失败且回滚不完整(原因与人工核对点已打印);
#       3 = 权威状态已提交, 仅分享链接未更新(见下, **刻意不回滚**)。
#
# 为什么"链接重建失败"不与另外四处后置写失败同待遇: 那一刻 config 与 metadata **都**已经是
# 新 SNI(两者一致), 不一致的只有 metadata 里的 `.share_link` 这个**派生字段**; 而重建失败的
# 根因是元数据本来就缺必填字段(不是本次改动造成的), 回滚并不会把它变好, 只会让这类节点永远
# 切不了域名。九轮把"消费返回值并如实告警"作为这条路径的终态, 本轮回滚只针对**权威状态之间**
# 的分裂, 故保持该口径(行为与改动前逐字一致)。
# 新分享链接不回传: 锁体在**子 shell** 里跑, 变量带不出去, 而 stdout 又会被 direct 后端
# 启动路径的 "running" 污染。成功路径直接回读 metadata 的 `.share_link` —— 它就是本事务
# 刚刚原子写入的那个值, 比另开一条回传通道更少活动部件。
# ---------------------------------------------------------------------------
_reality_domain_txn() {
    _with_config_lock _reality_domain_txn_locked "$@"
}

_reality_domain_txn_locked() {
    local tag="$1" meta="$2" new_sni="$3" pq_seed="$4" pq_verify="$5" rmode="$6" \
          tunnel_tag="$7" new_tunnel_tag="$8" reality_target="$9" meta_prev="${10}"
    # 提交 config。失败时 `_mutate_config` 已自行回滚并重启, metadata 尚未改动 ⇒ 无需额外回滚。
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
    # 更新元数据(R42: 同时回填 reality_mode, 使旧节点元数据自描述)
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
    # R38(M10): 消费 rebuild 返回码 —— SNI 已改, 但链接重建失败时不能写入空/坏链接
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
        # R42: 显示拓扑 —— 直连节点切域名要同时改 target, tunnel 节点要改 tunnel/路由
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
    # R38(P1): 新 SNI 会被拼进新 tunnel tag, 含空格/引号会破坏按 tag 的关联匹配
    if ! _validate_domain "$new_sni"; then
        _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $new_sni"
        _press_any_key; continue
    fi

    local new_target="${new_sni}:443"

    # 后量子检测(新域名可能支持或不支持)
    local pq_seed="" pq_verify=""
    if _detect_reality_pq "$new_target"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
        _info "新域名支持后量子签名"
    fi

    # R42: 模式决定要改哪些字段 —— 直连节点的 target 就是伪装站, 换域名必须连 target 一起改
    # (否则 serverNames 是新域名而 target 仍连旧站, 客户端 SNI 与真实握手对象不一致);
    # tunnel 节点的 target 恒指向本地 tunnel 入站, 只改 tunnel 的转发地址与路由 domain。
    #
    # R44: tunnel 的转发地址**必须同时写两套字段名**(与 templates/tunnel.server.jsonc 同源)。
    # 已发布核心(v24.12.31 → v26.3.27)的 json tag 是 address/port/network, main 分支与
    # Xray-docs-next 改成了 rewriteAddress/rewritePort/allowedNetwork。只写一套会在另一类核心上
    # 被静默忽略 —— 未识别字段不报错, 但 dest.Address 变 nil、dest.Port 变 0, dokodemo 回落到
    # LocalHostIP + 监听端口本身 ⇒ tunnel 自环。这里只改**已存在**的键(`if has(...)`), 避免给
    # 老节点凭空添加它本来没有的字段。
    local rmode; rmode=$(_reality_node_mode "$tag")
    local tunnel_tag="" tunnel_port node_port new_tunnel_tag="" reality_target=""
    if [ "$rmode" = "direct" ]; then
        reality_target="$new_target"
    else
        tunnel_tag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null)
        if [ -z "$tunnel_tag" ]; then
            _warn "该节点缺少 tunnel_tag 元数据(可能为旧版本创建或手动添加)"
            _warn "域名切换将仅更新 Reality inbound, 不会更新 tunnel inbound 和路由规则"
            read -rp "  继续? [y/N]: " ans
            case "$ans" in y|Y) ;; *) _info "已取消"; _press_any_key; continue ;; esac
            new_tunnel_tag=""
        else
            tunnel_port=$(jq -r '.tunnel_port' "$meta")
            node_port=$(jq -r '.port' "$meta")
            # R39(P2): 与创建路径统一走 _gen_tunnel_tag(tag 长度封顶)
            new_tunnel_tag=$(_gen_tunnel_tag "$new_sni" "$tunnel_port" "$node_port")
        fi
    fi
    # 提交前留住 metadata 原文: 后置步骤失败时要连同 config 一起还原(#43)
    local _reality_meta_prev=""
    _reality_meta_prev=$(cat "$meta" 2>/dev/null) || _reality_meta_prev=""

    # config 提交 + metadata + 链接重建 + 失败回滚 —— 一个整体事务, 全程持 config 锁(十轮 P1-③)。
    # 旧写法只有中间那一次 `_mutate_config` 在锁内, 后置步骤失败时的回滚读的是**共享**的
    # lastbak, 可能已被并发会话覆盖 ⇒ 回滚会抹掉别人已提交的改动。
    _reality_domain_txn "$tag" "$meta" "$new_sni" "$pq_seed" "$pq_verify" "$rmode" \
        "$tunnel_tag" "$new_tunnel_tag" "$reality_target" "$_reality_meta_prev"
    local txn_rc=$?
    if [ "$txn_rc" -ne 0 ]; then
        # 1 = 失败但已完整回滚 / 2 = 回滚不完整 / 3 = 权威状态已提交但链接未更新。
        # 三种都由事务体自己打印了原因与后续动作, 这里只补一句"改动未完成"的总括。
        [ "$txn_rc" -eq 2 ] && _tip "本次改动未完成, 请按上方提示人工核对后重试"
        _press_any_key; continue
    fi
    # 成功路径: 分享链接即 metadata 里刚原子提交的那一份
    local newlink=""
    newlink=$(jq -r '.share_link // empty' "$meta" 2>/dev/null)
    [ -n "$newlink" ] || _warn "未能读回新分享链接, 请用 [查看节点] 查看: $meta"
    # F1: servername(域名)变化需同步 clash 派生缓存, 否则订阅仍指向旧伪装域名。
    # **返回值必须消费**(2026-09-22 九轮 OCR #45): clash 是可再生的派生缓存, 失败**不回滚**
    # 权威状态(与 hy2 侧同口径), 但"报成功却仍指向旧域名"必须让用户看见。
    if ! _sync_node_clash "$meta"; then
        _warn "clash 派生缓存同步失败, 订阅里的条目仍是旧伪装域名"
        _tip "可重新执行一次本操作, 或删除后重建该节点以重建 clash 条目"
    fi

    _success "Reality 域名已切换: ${cur_sni} → ${new_sni}"
    if [ "$rmode" = "direct" ]; then
        _tip "直连模式: realitySettings.target 已同步为 ${new_target}"
    fi
    _tip "客户端须更新 SNI 为 ${new_sni} (pbk/sid 不变)"
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    [ -z "$pq_verify" ] && _warn "新域名不支持后量子, 已移除 pqv 参数"
    echo -e "  ${CYAN}新分享链接:${NC} ${newlink}"
    _press_any_key
    done
}
