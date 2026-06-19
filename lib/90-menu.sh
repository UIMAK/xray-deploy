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
        xver=" v$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
        xchannel=$(_state_get channel 2>/dev/null); [ -z "$xchannel" ] && xchannel="?"
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
        if _cf_is_running; then
            cfstatus="${GREEN}● 运行中${NC}"
        else
            cfstatus="${YELLOW}○ 已安装(未运行)${NC}"
        fi
    fi

    # Geo
    local geostate; geostate=$(_state_get geo_cron 2>/dev/null); [ -z "$geostate" ] && geostate="off"
    local geostr
    [ "$geostate" = "on" ] && geostr="${GREEN}● 自动${NC}" || geostr="${RED}○ 手动${NC}"

    echo -e "  系统: ${CYAN}${os_info}${NC}  |  init: ${CYAN}${INIT_SYSTEM}${NC}"
    echo -e "  Xray${CYAN}${xver}${NC} [${xchannel}]: ${xstatus}  |  节点: ${CYAN}${ncount}${NC}"
    echo -e "  cloudflared: ${cfstatus}  |  Geo: ${geostr}"
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
        echo -e "  ${GREEN}[6]${NC} Hysteria2 管理"
        if _has_reality_nodes; then
            echo -e "  ${GREEN}[7]${NC} Reality 域名管理"
        fi
        echo
        echo -e "  ${CYAN}【核心与服务】${NC}"
        local _off=1
        _has_reality_nodes && _off=$((_off+1))
        local _core=$((_off+6))
        local _ops_start=$((_core+3))
        printf "  ${GREEN}[%d]${NC} 安装/更新或切换 Xray 核心(稳定/预览)\n" "$_core"
        printf "  ${GREEN}[%d]${NC} Geo 数据自动更新\n" $((_core+1))
        printf "  ${GREEN}[%d]${NC} cloudflared 管理\n" $((_core+2))
        echo
        echo -e "  ${CYAN}【运维】${NC}"
        printf "  ${GREEN}[%2d]${NC} 检测脚本更新\n" "$_ops_start"
        printf "  ${GREEN}[%2d]${NC} 重启 Xray\n" $((_ops_start+1))
        printf "  ${GREEN}[%2d]${NC} 停止 Xray\n" $((_ops_start+2))
        printf "  ${GREEN}[%2d]${NC} 查看状态\n" $((_ops_start+3))
        printf "  ${GREEN}[%2d]${NC} 查看日志\n" $((_ops_start+4))
        printf "  ${GREEN}[%2d]${NC} 检查配置(xray -test)\n" $((_ops_start+5))
        printf "  ${GREEN}[%2d]${NC} 卸载\n" $((_ops_start+6))
        echo
        echo -e "  ${GREEN}[0]${NC} 退出"
        echo
        read -rp "  请选择: " choice
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
        if [ "$choice" = "7" ] && _has_reality_nodes; then
            _reality_domain_menu; continue
        fi
        # 动态编号: 核心与服务 / 运维
        local _off=1
        _has_reality_nodes && _off=$((_off+1))
        local _core=$((_off+6))
        local _ops_start=$((_core+3))
        if [ "$choice" = "$_core" ]; then
            _xray_core_menu
        elif [ "$choice" = "$((_core+1))" ]; then
            _geo_menu
        elif [ "$choice" = "$((_core+2))" ]; then
            _cloudflared_menu
        elif [ "$choice" = "$_ops_start" ]; then
            _check_script_update
        elif [ "$choice" = "$((_ops_start+1))" ]; then
            _manage_xray restart; _success "已重启"; _press_any_key
        elif [ "$choice" = "$((_ops_start+2))" ]; then
            _manage_xray stop; _success "已停止"; _press_any_key
        elif [ "$choice" = "$((_ops_start+3))" ]; then
            _view_status
        elif [ "$choice" = "$((_ops_start+4))" ]; then
            _view_log
        elif [ "$choice" = "$((_ops_start+5))" ]; then
            _check_config
        elif [ "$choice" = "$((_ops_start+6))" ]; then
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
        echo -e "  版本: v$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')  通道: $(_state_get channel 2>/dev/null)"
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
    _info "运行 xray -test..."
    if XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" -test -config "$CONFIG_FILE"; then
        _success "配置校验通过"
    else
        _error "配置校验失败"
    fi
    _press_any_key
}

# 兜底卸载 cloudflared（当 VPS 上的 lib/40-cloudflared.sh 是旧版、缺少 _uninstall_cloudflared 时用）
_uninstall_cloudflared_fallback() {
    if [ -x /usr/local/bin/cloudflared ]; then
        _info "卸载 cloudflared (fallback)..."
        /usr/local/bin/cloudflared service uninstall 2>/dev/null || true
        pgrep -x cloudflared 2>/dev/null | xargs -r kill -15 2>/dev/null || true
        sleep 2
        pgrep -x cloudflared 2>/dev/null | xargs -r kill -9 2>/dev/null || true
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
        rm -f /opt/xray-deploy/state/cf_*
        _success "cloudflared 已卸载 (fallback)"
    else
        _warn "cloudflared 未安装"
    fi
}

# ---------------------------------------------------------------------------
# 卸载菜单
# ---------------------------------------------------------------------------
_uninstall_menu() {
    clear
    echo
    echo -e "  ${RED}【卸载 / 重置】${NC}"
    echo -e "  ${GREEN}[1]${NC} 重置 config.json 为默认(含 routing 规则, 清空节点)"
    echo -e "  ${GREEN}[2]${NC} 仅卸载 Xray"
    echo -e "  ${GREEN}[3]${NC} 卸载 Xray + cloudflared"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  选择: " choice
    case "$choice" in
        1) _reset_config ;;
        2) _uninstall_xray ;;
        3) _uninstall_xray; if declare -F _uninstall_cloudflared >/dev/null 2>&1; then _uninstall_cloudflared; else _uninstall_cloudflared_fallback; fi ;;
        0) return ;;
        *) _warn "取消" ;;
    esac
    _press_any_key
}

# ---------------------------------------------------------------------------
# 重置 config.json 为默认(含 routing 规则, 清空节点); 保留 Xray 二进制
# ---------------------------------------------------------------------------
_reset_config() {
    echo
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        local ncount; ncount=$(_node_count 2>/dev/null)
        echo -e "  ${YELLOW}当前有 ${ncount} 个节点, 重置将清空所有节点配置${NC}"
        read -rp "  确认清空并重置 config.json? [y/N]: " ans
        case "$ans" in
            y|Y) ;;
            *) _info "已取消"; return ;;
        esac
        _backup_config
    fi
    # 删掉 config 让 _init_config_if_empty 重建
    rm -f "$CONFIG_FILE"
    _init_config_if_empty
    # 清空节点元数据 + clash.yaml
    if [ -d "$NODES_DIR" ]; then
        rm -f "$NODES_DIR"/*.json 2>/dev/null
    fi
    [ -f "$CLASH_YAML" ] && printf 'proxies:\n' > "$CLASH_YAML" 2>/dev/null
    # 重启 xray(若在跑)
    if [ -x "$XRAY_BIN" ]; then
        _xray_test_config 2>/dev/null && _manage_xray restart 2>/dev/null
    fi
    _success "config.json 已重置(含 routing 规则), 节点已清空"
}

# ---------------------------------------------------------------------------
# 检测脚本更新
# 本地版本从 $DEPLOY_DIR/VERSION 文件读取, 远程从 GitHub raw 拉取
# 以后只需改 VERSION 文件, 不用动代码
# ---------------------------------------------------------------------------
SCRIPT_VERSION_URL="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}/VERSION"

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
    remote=$(wget -qO- --timeout=10 "$SCRIPT_VERSION_URL" 2>/dev/null) || remote=""
    if [ -z "$remote" ]; then
        _warn "无法获取远程版本(网络受限或仓库未发布),请手动检查"
        _press_any_key; return
    fi
    remote=$(echo "$remote" | tr -d '[:space:]')
    echo -e "  远程版本: ${CYAN}${remote}${NC}"
    if [ "$remote" = "$local_ver" ]; then
        _success "已是最新版本"
    elif [ -n "$remote" ]; then
        _warn "发现新版本: ${remote}"
        read -rp "  是否立即更新? [y/N]: " ans
        case "$ans" in
            y|Y)
                _info "正在更新脚本..."
                bash <(curl -fsSL "https://raw.githubusercontent.com/UIMAK/xray-deploy/main/install.sh") --update
                _success "脚本已更新, 下次进菜单生效"
                exit 0
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
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【Hysteria2 管理】${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 切换 brutal / bbr 模式"
        echo -e "  ${GREEN}[2]${NC} 调整 brutal 带宽"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice
        case "$choice" in
            1) _hy2_toggle_brutal ;;
            2) _hy2_adjust_bandwidth ;;
            0) return ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Hysteria2: 切换 brutal / bbr
# ---------------------------------------------------------------------------
_hy2_toggle_brutal() {
    clear
    _has_hy2_nodes || { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
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
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_cc; cur_cc=$(jq -r '.congestion' "$meta")
    local new_cc
    if [ "$cur_cc" = "brutal" ]; then
        new_cc="bbr"
        _backup_config
        local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
        jq --arg t "$tag" \
           '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) =
            {congestion: "bbr"}' "$CONFIG_FILE" > "$tmp" 2>/dev/null
        mv -f "$tmp" "$CONFIG_FILE"
        if ! _xray_test_config; then
            _restore_config; _error "配置校验失败, 已回滚"; _press_any_key; return
        fi
        _manage_xray restart 2>/dev/null || true
        jq --arg cc "$new_cc" '.congestion=$cc | .brutal_up="" | .brutal_down=""' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
        local link; link=$(_rebuild_hy2_link "$meta")
        jq --arg l "$link" '.share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
        _success "已切换为 bbr 模式"
    else
        new_cc="brutal"
        echo -e "  ${YELLOW}brutal 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
        local brutal_up="" brutal_down=""
        read -rp "  上传带宽 (回车不限): " brutal_up
        read -rp "  下载带宽 (回车不限): " brutal_down
        _backup_config
        local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
        jq --arg t "$tag" --arg up "$brutal_up" --arg down "$brutal_down" \
           '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) =
            ({congestion: "brutal"}
             + (if $up != "" then {brutalUp: $up} else {} end)
             + (if $down != "" then {brutalDown: $down} else {} end))' \
           "$CONFIG_FILE" > "$tmp" 2>/dev/null
        mv -f "$tmp" "$CONFIG_FILE"
        if ! _xray_test_config; then
            _restore_config; _error "配置校验失败, 已回滚"; _press_any_key; return
        fi
        _manage_xray restart 2>/dev/null || true
        jq --arg cc "$new_cc" --arg up "$brutal_up" --arg down "$brutal_down" \
           '.congestion=$cc | .brutal_up=$up | .brutal_down=$down' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
        local link; link=$(_rebuild_hy2_link "$meta")
        jq --arg l "$link" '.share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
        _success "已切换为 brutal 模式"
        [ -n "$brutal_up" ] && echo -e "  ${CYAN}上传:${NC} ${brutal_up}"
        [ -n "$brutal_down" ] && echo -e "  ${CYAN}下载:${NC} ${brutal_down}"
    fi
    _press_any_key
}

# ---------------------------------------------------------------------------
# Hysteria2: 调整 brutal 带宽(仅 brutal 模式)
# ---------------------------------------------------------------------------
_hy2_adjust_bandwidth() {
    clear
    _has_hy2_nodes || { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
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
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_cc; cur_cc=$(jq -r '.congestion' "$meta")
    if [ "$cur_cc" != "brutal" ]; then
        _warn "该节点当前为 ${cur_cc} 模式, 非 brutal 无需设带宽"
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

    _backup_config
    local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    jq --arg t "$tag" --arg up "$new_up" --arg down "$new_down" \
       '(.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) =
        ({congestion: "brutal"}
         + (if $up != "" then {brutalUp: $up} else {} end)
         + (if $down != "" then {brutalDown: $down} else {} end))' \
       "$CONFIG_FILE" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$CONFIG_FILE"
    if ! _xray_test_config; then
        _restore_config; _error "配置校验失败, 已回滚"; _press_any_key; return
    fi
    _manage_xray restart 2>/dev/null || true
    jq --arg up "$new_up" --arg down "$new_down" '.brutal_up=$up | .brutal_down=$down' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
    local link; link=$(_rebuild_hy2_link "$meta")
    jq --arg l "$link" '.share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
    _success "带宽已更新: 上传=${new_up:-不限}  下载=${new_down:-不限}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# Reality 域名管理(切换 target SNI)
# ---------------------------------------------------------------------------
_reality_domain_menu() {
    clear
    _has_reality_nodes || { _warn "暂无 Reality 节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【Reality 域名管理】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        case "$proto" in *reality*) ;; *) continue ;; esac
        local tag name sni
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); sni=$(jq -r '.sni' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-24s 当前域名: %s\n" "$i" "$name" "$sni"
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Reality 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local cur_sni; cur_sni=$(jq -r '.sni' "$meta")
    echo -e "  当前域名: ${CYAN}${cur_sni}${NC}"
    local new_sni
    read -rp "  新伪装域名 (回车取消): " new_sni
    [ -z "$new_sni" ] && { _info "已取消"; _press_any_key; return; }

    local new_target="${new_sni}:443"

    _backup_config
    local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX")
    jq --arg t "$tag" --arg sni "$new_sni" --arg target "$new_target" \
       '(.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings) |=
        (.target = $target | .serverNames = [$sni])' \
       "$CONFIG_FILE" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$CONFIG_FILE"
    if ! _xray_test_config; then
        _restore_config; _error "配置校验失败, 已回滚"; _press_any_key; return
    fi
    _manage_xray restart 2>/dev/null || true

    # 更新元数据 + 分享链接
    jq --arg sni "$new_sni" '.sni=$sni' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"
    local newlink; newlink=$(_rebuild_reality_link "$meta")
    jq --arg l "$newlink" '.share_link=$l' "$meta" > "$meta.tmp" && mv -f "$meta.tmp" "$meta"

    _success "Reality 域名已切换: ${cur_sni} → ${new_sni}"
    _tip "客户端须更新 SNI 为 ${new_sni} (pbk/sid 不变, 更新分享链接即可)"
    echo -e "  ${CYAN}新分享链接:${NC} ${newlink}"
    _press_any_key
}
