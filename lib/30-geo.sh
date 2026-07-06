#!/bin/bash
# =============================================================================
# lib/30-geo.sh — geosite/geoip 自动更新
# 需求 R4: 用户可开/关, 默认关; cron 每月 1/4/7/.../31 号 03:00 执行; 下载失败保留旧 dat; 运行期校验失败回退旧 dat; 不要精简版
# 数据源: Loyalsoldier/v2ray-rules-dat releases/latest/download/{geosite,geoip}.dat
# 落点: $ASSET_DIR (/opt/xray-deploy/assets, 即 XRAY_LOCATION_ASSET)
# 注意: cron 表达式 */3 在 day-of-month 字段表示每月 1/4/7/.../31 号, 并非严格的"每 3 天"(跨月不连续)
# ============================================================================

GEO_CRON_MARKER="# xray-deploy-geo-update"
GEO_STATE_FILE="$STATE_DIR/geo_cron"

# ---------------------------------------------------------------------------
# 确保 cron 服务在运行(启用 + 启动)
# ---------------------------------------------------------------------------
_ensure_cron_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true ;;
        openrc)  rc-update add cron default 2>/dev/null; rc-service cron start 2>/dev/null || true ;;
    esac
}

# ---------------------------------------------------------------------------
# 执行一次 Geo 更新(备份旧 dat → 下载覆盖 → xray -test 校验, 失败回退旧 dat)
# ---------------------------------------------------------------------------
_geo_update() {
    _ensure_dirs
    # M26: cron 环境下 _info/_warn 输出到 stdout 会产生噪音邮件, 重定向到日志
    if [ ! -t 0 ]; then
        exec >> "$GEO_LOG" 2>&1
    fi
    local tmp; tmp=$(mktemp -d)
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    _info "[$ts] 开始更新 Geo 数据..."

    local ok=1
    local backed=()  # 已备份的旧 dat 路径, 用于失败回退 (S9)
    for f in geosite.dat geoip.dat; do
        local url="$GEO_BASE/$f" dest="$ASSET_DIR/$f" t="${tmp}/${f}"
        _info "下载 $f <- $url"
        if ! wget -q --timeout=60 -O "$t" "$url" 2>/dev/null; then
            _warn "$f 下载失败, 保留旧文件"
            ok=0; continue
        fi
        # 校验: 非空 + 体积合理(>1KB)
        local sz; sz=$(stat -c%s "$t" 2>/dev/null || stat -f%z "$t" 2>/dev/null || echo 0)
        if [ "$sz" -lt 1024 ]; then
            _warn "$f 体积异常(${sz}B), 保留旧文件"
            ok=0; rm -f "$t"; continue
        fi
        # 覆盖前备份旧 dat (S9: 运行期 -test 校验失败或下载部分失败时可回退)
        [ -f "$dest" ] && { cp -f "$dest" "$dest.bak"; backed+=("$dest"); }
        # 原子替换
        mv -f "$t" "$dest"
        _success "$f 更新成功 (${sz}B)"
    done

    rm -rf "$tmp"

    # 日志 + 校验
    mkdir -p "$LOG_DIR"
    if [ "$ok" -eq 1 ]; then
        echo "[$ts] OK 全部更新成功" >> "$GEO_LOG"
    # 运行期校验: xray -test 确认新 dat 可用, 失败则回退旧 dat (S9)
    if [ -x "$XRAY_BIN" ] && [ -f "$CONFIG_FILE" ]; then
        _maybe_drop_caches
        if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
            _warn "新 dat 导致配置校验失败, 回退旧 dat"
                for dest in "${backed[@]}"; do
                    [ -f "${dest}.bak" ] && mv -f "${dest}.bak" "$dest"
                done
                echo "[$ts] FAIL 运行期校验失败, 已回退旧 dat" >> "$GEO_LOG"
                return 1
            fi
        fi
        # 校验通过, 清理备份 + 重启 xray
        for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
        _manage_xray restart 2>/dev/null || true
        return 0
    else
        # 部分下载失败: 回退已替换的文件, 保持 dat 对一致性
        for dest in "${backed[@]}"; do
            [ -f "${dest}.bak" ] && mv -f "${dest}.bak" "$dest"
        done
        echo "[$ts] PARTIAL 部分失败, 旧 dat 已保留" >> "$GEO_LOG"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 开/关自动更新(crontab 每 3 天)
# 用法:_geo_set_auto_update on|off
# ---------------------------------------------------------------------------
_geo_set_auto_update() {
    local action="$1"
    # cron 调用本脚本的 geo-update 子命令: xd geo-update
    # */3 在 day-of-month 字段: 每月 1/4/7/.../31 号 03:00 (跨月不连续, 非严格 "每 3 天")
    # M25: cron 环境 PATH 受限时 command -v 可能失败, 硬编码 /usr/local/bin 兜底已足够
    local cmd="$(command -v "$CMD_NAME" 2>/dev/null || echo "/usr/local/bin/$CMD_NAME") geo-update"
    local cron_line="0 3 */3 * * $cmd ${GEO_CRON_MARKER}"

    case "$action" in
        on)
            # 先去重: 移除已有 marker 行
            _geo_remove_cron_line >/dev/null 2>&1
            ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab - 2>/dev/null || {
                _error "写入 crontab 失败"; return 1
            }
            # 确保 cron 服务运行
            _ensure_cron_running
            _state_set geo_cron "on"
            _success "Geo 自动更新已开启 (每月 1/4/7/.../31 号 03:00 执行)"
            ;;
        off)
            _geo_remove_cron_line
            _state_set geo_cron "off"
            _success "Geo 自动更新已关闭"
            ;;
    esac
}

_geo_remove_cron_line() {
    crontab -l 2>/dev/null | grep -v "$GEO_CRON_MARKER" | crontab - 2>/dev/null
}

# ---------------------------------------------------------------------------
# 解析下次预计执行时间(从 crontab 行粗略推算, 用于回显)
# ---------------------------------------------------------------------------
_geo_next_run_hint() {
    local line
    line=$(crontab -l 2>/dev/null | grep "$GEO_CRON_MARKER" | head -1)
    if [ -z "$line" ]; then
        echo "未开启"
        return
    fi
    # 形如 0 3 */3 * * —— 每月 1/4/7/.../31 号 03:00 (非严格 "每 3 天", 跨月间隔不固定)
    echo "每月 1/4/7/.../31 号 03:00 (cron: $(echo "$line" | awk '{print $1" "$2" "$3" "$4" "$5}'))"
}

# ---------------------------------------------------------------------------
# Geo 菜单入口
# ---------------------------------------------------------------------------
_geo_menu() {
    clear
    echo
    echo -e "  ${CYAN}【Geo 数据自动更新】${NC}"
    local state; state=$(_state_get geo_cron 2>/dev/null)
    [ -z "$state" ] && state="off"
    if [ "$state" = "on" ]; then
        echo -e "  当前状态: ${GREEN}● 已开启${NC}"
        echo -e "  下次执行: $(_geo_next_run_hint)"
    else
        echo -e "  当前状态: ${RED}○ 已关闭${NC}"
    fi
    echo -e "  数据源: Loyalsoldier/v2ray-rules-dat (完整版)"
    echo -e "  落点: $ASSET_DIR (XRAY_LOCATION_ASSET)"
    echo
    echo -e "  ${GREEN}[1]${NC} 立即更新一次"
    if [ "$state" = "on" ]; then
        echo -e "  ${GREEN}[2]${NC} 关闭自动更新"
    else
        echo -e "  ${GREEN}[2]${NC} 开启自动更新(定期)"
    fi
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1) _geo_update ;;
        2) if [ "$state" = "on" ]; then _geo_set_auto_update off; else _geo_set_auto_update on; fi ;;
        0) return ;;
        *) _warn "无效" ;;
    esac
    _press_any_key
}
