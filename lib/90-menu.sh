#!/bin/bash
# =============================================================================
# lib/90-menu.sh — 主菜单 + 状态栏
# 串接所有模块, 渲染菜单, 调度用户选择
# ============================================================================

# 标题框(按显示宽度居中, 适配中文双宽)
_print_logo() {
    local title="Xray 部署管理脚本 (xray-deploy)"
    # 计算显示宽度: ASCII 1 列, 非 ASCII(中文等)2 列
    local w=0 i ch
    for ((i=0; i<${#title}; i++)); do
        ch="${title:$i:1}"
        if [[ "$ch" =~ [^[:print:]] || "$ch" == $'\t' ]]; then continue; fi
        # 简单判定: 字节 >= 0x80 视为宽字符(中文/全角)
        local byte
        byte=$(printf '%s' "$ch" | wc -c 2>/dev/null | tr -d ' ')
        if [ "$byte" -gt 1 ]; then w=$((w+2)); else w=$((w+1)); fi
    done
    # 框内宽 = w + 8(留边距); 至少 40
    local inner=$((w+8))
    [ "$inner" -lt 40 ] && inner=40
    local pad=$(( (inner - w) / 2 ))
    local border=""
    for ((i=0; i<inner+2; i++)); do border="${border}═"; done
    # 顶部
    echo -e "  ${CYAN}╔${border}╗${NC}"
    # 内容行: 左 pad 空格 + 标题 + 右补齐
    local left="" rightlen=$(( inner - w - pad ))
    local right=""
    for ((i=0; i<pad; i++)); do left="${left} "; done
    for ((i=0; i<rightlen; i++)); do right="${right} "; done
    echo -e "  ${CYAN}║${NC} ${left}${title}${right} ${CYAN}║${NC}"
    # 底部
    echo -e "  ${CYAN}╚${border}╝${NC}"
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
        echo
        echo -e "  ${CYAN}【核心与服务】${NC}"
        echo -e "  ${GREEN}[6]${NC} 安装/更新或切换 Xray 核心(稳定/预览)"
        echo -e "  ${GREEN}[7]${NC} Geo 数据自动更新"
        echo -e "  ${GREEN}[8]${NC} cloudflared 管理"
        echo
        echo -e "  ${CYAN}【运维】${NC}"
        printf "  ${GREEN}[%2d]${NC} 检测脚本更新\n" 9
        printf "  ${GREEN}[%2d]${NC} 重启 Xray\n" 10
        printf "  ${GREEN}[%2d]${NC} 停止 Xray\n" 11
        printf "  ${GREEN}[%2d]${NC} 查看状态\n" 12
        printf "  ${GREEN}[%2d]${NC} 查看日志\n" 13
        printf "  ${GREEN}[%2d]${NC} 检查配置(xray -test)\n" 14
        printf "  ${GREEN}[%2d]${NC} 卸载\n" 15
        echo
        echo -e "  ${GREEN}[0]${NC} 退出"
        echo
        read -rp "  请选择: " choice
        case "$choice" in
            1)  _add_node ;;
            2)  _view_nodes ;;
            3)  _delete_node ;;
            4)  _modify_port ;;
            5)  _update_listen ;;
            6)  _xray_core_menu ;;
            7)  _geo_menu ;;
            8)  _cloudflared_menu ;;
            9)  _check_script_update ;;
            10) _manage_xray restart; _success "已重启"; _press_any_key ;;
            11) _manage_xray stop; _success "已停止"; _press_any_key ;;
            12) _view_status ;;
            13) _view_log ;;
            14) _check_config ;;
            15) _uninstall_menu ;;
            0)  echo -e "${CYAN}再见${NC}"; exit 0 ;;
            *)  _warn "无效选择"; _press_any_key ;;
        esac
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
        3) _uninstall_xray; _uninstall_cloudflared ;;
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
# 检测脚本更新(问题3)
# 对比本地 SCRIPT_VERSION 与远程 VERSION 文件; 有新版提示重新跑 install.sh
# ---------------------------------------------------------------------------
SCRIPT_VERSION="0.1.0"
SCRIPT_VERSION_URL="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}/VERSION"

_check_script_update() {
    clear
    echo
    echo -e "  ${CYAN}【检测脚本更新】${NC}"
    echo -e "  当前版本: ${CYAN}${SCRIPT_VERSION}${NC}"
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
    if [ "$remote" = "$SCRIPT_VERSION" ]; then
        _success "已是最新版本"
    elif [ -n "$remote" ]; then
        _warn "发现新版本: ${remote}"
        echo -e "  升级方式: 重新运行安装命令"
        echo -e "  ${CYAN}bash <(curl -sL ${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}/install.sh)${NC}"
        echo -e "  ${YELLOW}(升级只替换脚本, 不影响已装的 Xray/节点/cloudflared)${NC}"
    fi
    _press_any_key
}
