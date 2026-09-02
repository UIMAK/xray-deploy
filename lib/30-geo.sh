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
        systemd) systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || return 1 ;;
        # OpenRC: Alpine 默认 BusyBox cron 为 crond, 也支持 cronie/dcron。
        # 通过 /etc/init.d/ 存在性探测, 不硬编码服务名。
        openrc)
            local cron_svc=""
            for cron_svc in crond cronie dcron; do
                if [ -x "/etc/init.d/$cron_svc" ]; then
                    rc-update add "$cron_svc" default 2>/dev/null || true
                    rc-service "$cron_svc" start 2>/dev/null || return 1
                    return 0
                fi
            done
            return 1
            ;;
        # direct(无 init 系统): 尽力找到并启动 cron 守护(crond=busybox/Vixie, cron=ISC)
        # 判活用 _proc_any_named(/proc comm 扫描, 容器内可靠), 不用 pgrep ——
        # 容器内 busybox pgrep -x 会假阴性(H3), 误把已运行的 crond 判为"未运行"
        # 再二次启动, 反而返回失败。
        direct)
            if command -v crond >/dev/null 2>&1; then
                _proc_any_named crond && return 0
                crond 2>/dev/null || return 1
                return 0
            elif command -v cron >/dev/null 2>&1; then
                _proc_any_named cron && return 0
                cron 2>/dev/null || return 1
                return 0
            fi
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 执行一次 Geo 更新(备份旧 dat → 下载覆盖 → 重启 xray)
# ---------------------------------------------------------------------------
_geo_update() {
    _ensure_dirs || return 1
    # M26: cron 环境下 _info/_warn 输出到 stdout 会产生噪音邮件, 重定向到日志
    if [ ! -t 0 ]; then
        exec >> "$GEO_LOG" 2>&1
    fi
    # R38(M5): mktemp -d 失败必须中止 —— 否则 tmp="" 会让 t="/geosite.dat", 两个 20MB+
    # 的 dat 被下载到根目录, 且末尾 rm -rf "$tmp" 变成 rm -rf "" 空操作, 文件永久残留。
    # /tmp 写满/只读/inode 耗尽正是本 PR 关注的低配 VPS 场景。
    local tmp
    tmp=$(mktemp -d) || { _error "无法创建临时目录(/tmp 写满或只读?), Geo 更新中止"; return 1; }
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    _info "[$ts] 开始更新 Geo 数据..."

    local ok=1
    local backed=()  # 已备份的旧 dat 路径, 用于失败回退 (S9)
    for f in geosite.dat geoip.dat; do
        local url="$GEO_BASE/$f" dest="$ASSET_DIR/$f" t="${tmp}/${f}"
        _info "下载 $f <- $url"
        if ! _http_download "$url" "$t" 60; then
            _warn "$f 下载失败, 保留旧文件"
            ok=0; continue
        fi
        # 校验: 非空 + 体积合理(>1KB)
        local sz; sz=$(stat -c%s "$t" 2>/dev/null || stat -f%z "$t" 2>/dev/null || echo 0)
        if [ "$sz" -lt 1024 ]; then
            _warn "$f 体积异常(${sz}B), 保留旧文件"
            ok=0; rm -f "$t"; continue
        fi
        # 覆盖前备份旧 dat (S9: 运行期校验失败或部分下载失败时可回退)。
        # 备份必须真正成功才允许覆盖: 磁盘满/IO 错误导致 cp 失败时, 若继续 mv 会让旧 dat
        # 无备份可回滚 → 数据集不一致。备份失败则保留旧文件、本次不替换。
        if [ -f "$dest" ]; then
            if ! cp -f "$dest" "$dest.bak"; then
                _warn "$f 旧文件备份失败(磁盘空间/IO?), 保留旧文件, 跳过本次替换"
                ok=0; rm -f "$t"; continue
            fi
            backed+=("$dest")
        fi
        # 原子替换。mv 失败(磁盘满/IO/只读)时旧 dat 仍在原位, 不能报"更新成功"并随后删除 .bak;
        # 置 ok=0 走"部分失败"分支, 由 backed[] 里的 .bak 把旧 dat 还原回来。
        if ! mv -f "$t" "$dest"; then
            _warn "$f 替换失败(磁盘空间/IO/只读?), 保留旧文件, 跳过本次更新"
            ok=0; rm -f "$t"; continue
        fi
        _success "$f 更新成功 (${sz}B)"
    done

    rm -rf "$tmp"

    # 日志 + 校验
    mkdir -p "$LOG_DIR"
    if [ "$ok" -eq 1 ]; then
        # 低内存机器不跑 xray -test(双份加载 OOM); 改为重启后做稳定存活确认。
        # 仅当 xray 已安装且原本在运行/存在配置时才重启验证
        local need_verify=0
        if [ -x "$XRAY_BIN" ] && [ -f "$CONFIG_FILE" ]; then
            case "$(_manage_xray status 2>/dev/null)" in running) need_verify=1;; esac
        fi
        if [ "$need_verify" -eq 1 ]; then
            if _restart_xray_verified; then
                for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
                echo "[$ts] OK 全部更新成功, xray 重启稳定" >> "$GEO_LOG"
            else
                # 新 dat 导致 xray 无法稳定运行: 回退旧 dat 并重新拉起
                # R38(M4): 必须统计"实际回退了几个"——backed[] 只在旧文件存在时才追加, 首次
                # 部署/assets 被清过的机器上它是空数组, 循环一次都不跑, 坏 dat 原样留在盘上,
                # 而日志却写"已回退旧 dat"。cron 每月一次, 这行日志是用户唯一的诊断依据。
                _warn "新 Geo 数据导致 xray 运行异常, 回退旧 dat"
                local rolled=0
                for dest in "${backed[@]}"; do
                    if [ -f "${dest}.bak" ]; then
                        if mv -f "${dest}.bak" "$dest"; then
                            rolled=$((rolled+1))
                        else
                            _warn "回滚 ${dest} 失败, 请手动检查"
                        fi
                    fi
                done
                # R38(M4): 回退后是否救回来了, 是值班时最需要知道的一件事; 不能用
                # `2>/dev/null || true` 把结果一并吞掉
                local recovered="xray 仍未稳定运行, 需人工介入"
                if _restart_xray_verified; then
                    recovered="xray 已恢复运行"
                fi
                if [ "$rolled" -eq 0 ]; then
                    _warn "无旧 dat 可回退(首次安装/assets 曾被清空), 新 dat 仍在 ${ASSET_DIR}"
                    echo "[$ts] FAIL 新 dat 运行期校验失败, 无旧 dat 可回退, ${recovered}" >> "$GEO_LOG"
                else
                    echo "[$ts] FAIL 新 dat 运行期校验失败, 已回退 ${rolled} 个旧 dat, ${recovered}" >> "$GEO_LOG"
                fi
                return 1
            fi
        else
            # xray 未安装/未运行: 无需重启, 清理备份
            for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
            echo "[$ts] OK 全部更新成功(xray 未运行, 已跳过重启)" >> "$GEO_LOG"
        fi
        return 0
    else
        # 部分下载失败: 回退已替换的文件, 保持 dat 对一致性
        # R38(M4): 同样统计实际回退数量, 并区分"有旧文件可回退"与"某份是首次下载"
        local rolled=0
        for dest in "${backed[@]}"; do
            if [ -f "${dest}.bak" ]; then
                if mv -f "${dest}.bak" "$dest"; then
                    rolled=$((rolled+1))
                else
                    _warn "回滚 ${dest} 失败, 请手动检查"
                fi
            fi
        done
        if [ "$rolled" -eq 0 ]; then
            echo "[$ts] PARTIAL 部分失败, 无已替换文件需回退" >> "$GEO_LOG"
        else
            echo "[$ts] PARTIAL 部分失败, 已回退 ${rolled} 个旧 dat" >> "$GEO_LOG"
        fi
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
            # 确保 cron 服务运行; 即使失败 crontab 也已写入(cron daemon 后续启动后生效)
            if _ensure_cron_running; then
                _state_set geo_cron "on"
                _success "Geo 自动更新已开启 (每月 1/4/7/.../31 号 03:00 执行)"
            else
                _warn "cron 守护进程未能启动, 自动更新已写入 crontab 但当前不会执行"
                _tip "请确保系统中有 cron 守护进程在运行, 或手动启动 crond/cron"
                _state_set geo_cron "off"
            fi
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
