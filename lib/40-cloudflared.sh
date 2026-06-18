#!/bin/bash
# =============================================================================
# lib/40-cloudflared.sh — cloudflared 管理
# 需求 R5:
#   - 安装(架构自适应下载) / 卸载(彻底清) / 切换令牌
#   - 安装走官方 `cloudflared service install <token>`, 不写 config.yml(路由在 CF Web 配)
#   - 改参数/令牌 = 直接改 /etc/systemd/system/cloudflared.service 或 /etc/init.d/cloudflared 启动行
#   - 3 开关: 自动更新(--autoupdate-freq 24h0m0s / --no-autoupdate)
#             HTTP/2  (--protocol http2 / 不写)
#             IPv6栈  (--edge-ip-version 6 / 不写)
#   - cloudflared 是唯一例外, 落官方默认点, 不收口 /opt/xray-deploy
# ============================================================================

# cloudflared 启动行各片段开关(存 state 便于回显与重组)
CF_STATE_AUTOUPDATE="$STATE_DIR/cf_autoupdate"     # on|off
CF_STATE_HTTP2="$STATE_DIR/cf_http2"               # on|off
CF_STATE_IPV6="$STATE_DIR/cf_ipv6"                 # on|off
CF_STATE_TOKEN="$STATE_DIR/cf_token"

# ---------------------------------------------------------------------------
# 架构 -> cloudflared 下载资产名
# ---------------------------------------------------------------------------
_cf_arch_tag() {
    case "$(_detect_arch)" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        *)     echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装 cloudflared 二进制
# ---------------------------------------------------------------------------
_install_cloudflared_bin() {
    if [ -x "$CF_BIN" ]; then
        _info "cloudflared 已安装: $("$CF_BIN" --version 2>&1 | head -n1)"
        return 0
    fi
    local tag; tag=$(_cf_arch_tag)
    [ -z "$tag" ] && { _error "不支持的架构: $(uname -m)"; return 1; }
    local url="$CF_DL_BASE/cloudflared-linux-${tag}"
    _info "下载 cloudflared <- $url"
    if ! wget -q --show-progress -O "$CF_BIN" "$url" 2>&1; then
        _error "cloudflared 下载失败"; return 1
    fi
    chmod +x "$CF_BIN"
    _success "cloudflared 安装成功"
}

# ---------------------------------------------------------------------------
# 从用户粘贴文本提取令牌(纯 bash, 不用 sed/grep -E, 避 busybox 兼容问题)
# cloudflared token 是 base64 JSON 串, 可能含 . - _ =
# 策略: 优先取 "service install" 或 "--token" 后的第一个字段; 兜底 ey 开头串
# ---------------------------------------------------------------------------
_extract_token() {
    local input="$1" token=""
    local arr=()
    read -ra arr <<< "$input"
    local i grab=0
    for ((i=0; i<${#arr[@]}; i++)); do
        local w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then
            token="$w"; break
        fi
        case "$w" in
            install)    grab=1 ;;
            --token)    grab=1 ;;
            --token=*)  token="${w#--token=}"; break ;;
        esac
    done
    if [ -z "$token" ]; then
        for w in "${arr[@]}"; do
            case "$w" in
                ey????????????????????*) token="$w"; break ;;
            esac
        done
    fi
    [ -n "$token" ] && echo "$token"
}

# ---------------------------------------------------------------------------
# 读取当前 service 文件启动行, 解析出 token 与 3 开关状态
# 输出全局: CF_CUR_TOKEN / CF_CUR_AUTOUPDATE / CF_CUR_HTTP2 / CF_CUR_IPV6
# ---------------------------------------------------------------------------
_read_cf_state() {
    CF_CUR_TOKEN=""; CF_CUR_AUTOUPDATE="off"; CF_CUR_HTTP2="off"; CF_CUR_IPV6="off"; CF_CUR_RAWLINE=""
    local svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *)       svcfile="$CF_UNIT_SYSTEMD" ;;
    esac
    [ -f "$svcfile" ] || return 1
    # 收集所有可能的启动行(command_args / command / supervise_daemon_args / ExecStart)
    local lines="" ln
    while IFS= read -r ln || [ -n "$ln" ]; do
        case "$ln" in
            command_args=*|command=*|supervise_daemon_args=*|ExecStart=*|start*)
                lines="$lines
$ln" ;;
        esac
    done < "$svcfile"
    # 也把整个文件作为兜底搜索范围(token 可能在 SysV 脚本的 start 块内联命令里)
    local full; full=$(cat "$svcfile" 2>/dev/null)
    CF_CUR_RAWLINE="$full"
    # token: 优先在启动行里找 --token 后字段; 兜底全文件 ey 开头串
    # 把多行合成单行(换行换空格), 再 read -ra 按空白分词(read -ra 只读单行)
    local search oneline
    search="$lines
$full"
    oneline=$(printf '%s' "$search" | tr '\n' ' ')
    local arr=() i grab=0
    read -ra arr <<< "$oneline"
    for ((i=0; i<${#arr[@]}; i++)); do
        local w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then
            CF_CUR_TOKEN="$w"; break
        fi
        case "$w" in
            --token)    grab=1 ;;
            --token=*)  CF_CUR_TOKEN="${w#--token=}"; break ;;
        esac
    done
    if [ -z "$CF_CUR_TOKEN" ]; then
        for w in "${arr[@]}"; do
            case "$w" in ey????????????????????*) CF_CUR_TOKEN="$w"; break ;; esac
        done
    fi
    # 去掉 token 首尾可能粘连的引号(command_args="..." 闭合引号)
    case "$CF_CUR_TOKEN" in
        *\") CF_CUR_TOKEN="${CF_CUR_TOKEN%\"}" ;;
    esac
    case "$CF_CUR_TOKEN" in
        \"*) CF_CUR_TOKEN="${CF_CUR_TOKEN#\"}" ;;
    esac
    # 开关(固定字符串匹配)
    echo "$oneline" | grep -q -- '--no-autoupdate'      && CF_CUR_AUTOUPDATE="off"
    echo "$oneline" | grep -q -- '--autoupdate-freq'   && CF_CUR_AUTOUPDATE="on"
    echo "$oneline" | grep -q -- '--protocol http2'    && CF_CUR_HTTP2="on"
    echo "$oneline" | grep -q -- '--edge-ip-version 6' && CF_CUR_IPV6="on"
}

# ---------------------------------------------------------------------------
# 重组 cloudflared 启动命令行(按 3 开关 + token)
# 用法:_cf_build_cmdline <token>
# 读取全局 CF_AUTOUPDATE/CF_HTTP2/CF_IPV6
# ---------------------------------------------------------------------------
_cf_build_cmdline() {
    local token="$1"
    local cmd="$CF_BIN"
    if [ "$CF_AUTOUPDATE" = "on" ]; then
        cmd="$cmd --autoupdate-freq 24h0m0s"
    else
        cmd="$cmd --no-autoupdate"
    fi
    cmd="$cmd tunnel"
    [ "$CF_HTTP2" = "on" ] && cmd="$cmd --protocol http2"
    [ "$CF_IPV6" = "on" ]  && cmd="$cmd --edge-ip-version 6"
    cmd="$cmd run --token $token"
    echo "$cmd"
}

# ---------------------------------------------------------------------------
# 把启动行写回 service 文件(纯 bash 逐行处理, 避 busybox sed -E)
# 用法:_cf_write_service_line <cmdline>          (整行重组)
#       _cf_replace_token_in_service <oldtoken> <newtoken>  (只换 token, 保留原参数)
# ---------------------------------------------------------------------------
# 通用: 逐行读 service 文件, 替换匹配行, 写回(保留原文件权限)
_svc_replace_line() {
    local svcfile="$1" pattern="$2" newline="$3" tmp
    [ -f "$svcfile" ] || return 1
    cp -f "$svcfile" "${svcfile}.bak"
    tmp=$(mktemp)
    while IFS= read -r ln || [ -n "$ln" ]; do
        case "$ln" in
            "$pattern"*) printf '%s\n' "$newline" >> "$tmp" ;;
            *) printf '%s\n' "$ln" >> "$tmp" ;;
        esac
    done < "$svcfile"
    # 用 cat 保内容 + 原文件保留(避免 mktemp 无执行位的问题): 先覆盖内容, 再恢复权限
    cat "$tmp" > "$svcfile"
    rm -f "$tmp"
    # openrc init.d 文件需可执行
    case "$svcfile" in /etc/init.d/*) chmod +x "$svcfile" 2>/dev/null ;; esac
    return 0
}

_cf_write_service_line() {
    local cmd="$1" svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *) _error "无 init 系统, 无法管理 cloudflared service"; return 1 ;;
    esac
    [ -f "$svcfile" ] || { _error "service 文件不存在: $svcfile"; return 1; }
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        _svc_replace_line "$svcfile" "command_args=" "command_args=\"$cmd\""
    else
        _svc_replace_line "$svcfile" "ExecStart=" "ExecStart=$cmd"
        systemctl daemon-reload
    fi
    return 0
}

# 只替换 service 启动行里的 token, 保留用户原有的其他参数(不破坏手动装的好配置)
# 用纯 bash 字符串替换(不依赖 sed -E 正则)
_cf_replace_token_in_service() {
    local oldtok="$1" newtok="$2" svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *) return 1 ;;
    esac
    [ -f "$svcfile" ] || return 1
    cp -f "$svcfile" "${svcfile}.bak"
    local tmp; tmp=$(mktemp)
    while IFS= read -r ln || [ -n "$ln" ]; do
        if [ -n "$oldtok" ]; then
            printf '%s\n' "${ln//"$oldtok"/$newtok}" >> "$tmp"
        else
            # oldtok 为空: 在该行里找 ey 开头的 token 字段替换
            local out="" arr=() rep=0
            read -ra arr <<< "$ln"
            local w
            for w in "${arr[@]}"; do
                case "$w" in
                    ey????????????????????*) out="$out $newtok"; rep=1 ;;
                    *) out="$out $w" ;;
                esac
            done
            if [ "$rep" -eq 1 ]; then
                printf '%s\n' "${out# }" >> "$tmp"
            else
                printf '%s\n' "$ln" >> "$tmp"
            fi
        fi
    done < "$svcfile"
    cat "$tmp" > "$svcfile"
    rm -f "$tmp"
    case "$svcfile" in /etc/init.d/*) chmod +x "$svcfile" 2>/dev/null ;; esac
    [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload
    return 0
}

# ---------------------------------------------------------------------------
# 强力杀干净所有 cloudflared 进程(防止 PID 残留导致的进程泄漏)
# openrc 的 rc-service stop 经常杀不干净, 必须内核级 kill 兜底
# ---------------------------------------------------------------------------
_cf_kill_all() {
    local pids="" i

    # 1. 按实际 init 系统走正确的 stop，并等待进程真正退出
    case "$INIT_SYSTEM" in
        systemd)
            systemctl stop cloudflared 2>/dev/null || true
            # 等 systemd 真正把进程杀掉（最多等 15s，避免无限阻塞）
            i=0
            while systemctl is-active --quiet cloudflared 2>/dev/null && [ "$i" -lt 15 ]; do
                sleep 1; i=$((i+1))
            done
            ;;
        openrc)
            rc-service cloudflared stop 2>/dev/null || true
            sleep 2
            ;;
    esac

    # 2. 杀 PID 文件里的残留
    for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
        [ -f "$pf" ] && kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null || true
        rm -f "$pf" 2>/dev/null
    done

    # 3. 扫残留进程：先 SIGTERM（给 cloudflared 时间向 CF 边缘发送断开信号），等 3s，再 SIGKILL
    pids=$(pgrep -x cloudflared 2>/dev/null \
        || ps -o pid,comm 2>/dev/null | awk '/cloudflared/{print $1}')
    if [ -n "$pids" ]; then
        for pid in $pids; do kill -15 "$pid" 2>/dev/null || true; done
        sleep 3
        # 再扫一次，还活着的直接 SIGKILL
        pids=$(pgrep -x cloudflared 2>/dev/null \
            || ps -o pid,comm 2>/dev/null | awk '/cloudflared/{print $1}')
        for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
        sleep 1
    fi

    # 4. 最终确认
    pids=$(pgrep -x cloudflared 2>/dev/null \
        || ps -o pid,comm 2>/dev/null | awk '/cloudflared/{print $1}')
    if [ -n "$pids" ]; then
        _warn "cloudflared 仍有残留进程: $pids"
    else
        _info "cloudflared 所有进程已清理"
    fi
}

# 重启 cloudflared service(先杀干净所有, 等 CF 边缘回收旧 session, 再重新 start)
_cf_restart() {
    _cf_kill_all
    sleep 2   # 等 CF 边缘感知旧 connector 断开
    case "$INIT_SYSTEM" in
        systemd) systemctl start cloudflared 2>/dev/null ;;
        openrc)  rc-service cloudflared start 2>/dev/null ;;
    esac
    sleep 3   # 等新进程建立连接后再做后续检测
}

# 判断 cloudflared 是否在运行(状态栏 + 诊断用)
_cf_is_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet cloudflared 2>/dev/null ;;
        openrc)
            # openrc: 优先 rc-service status, 兜底 pgrep
            rc-service cloudflared status 2>/dev/null | grep -qi 'started\|running' && return 0
            if command -v pgrep >/dev/null 2>&1; then
                pgrep -f cloudflared >/dev/null 2>&1 && return 0
            else
                ps w 2>/dev/null | grep -v grep | grep -q cloudflared && return 0
            fi
            return 1
            ;;
        *)
            ps w 2>/dev/null | grep -v grep | grep -q cloudflared && return 0 || return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装 cloudflared(含 service install)
# ---------------------------------------------------------------------------
_install_cloudflared() {
    _install_cloudflared_bin || return 1
    echo
    _info "请粘贴 Cloudflare Tunnel Token"
    _tip "支持直接粘贴 CF 网页端给出的任何安装命令(Windows/Debian 均可), 脚本自动提取 ey... 令牌"
    read -rp "  粘贴: " input
    local token; token=$(_extract_token "$input")
    if [ -z "$token" ]; then
        _warn "未识别到 ey... 令牌, 将原样使用你输入的内容作为 token"
        token="$input"
    fi
    [ -z "$token" ] && { _error "Token 不能为空"; return 1; }

    # 默认开关(首次安装: 自动更新 on, HTTP2 on, IPv6 off)
    CF_AUTOUPDATE="on"; CF_HTTP2="on"; CF_IPV6="off"

    _info "调用 cloudflared service install..."
    if ! "$CF_BIN" service install "$token" 2>&1; then
        _error "cloudflared service install 失败"
        return 1
    fi
    # 官方命令生成的 service 行可能不含我们要的参数, 重组覆盖
    if _cf_write_service_line "$(_cf_build_cmdline "$token")"; then
        _cf_restart
    fi
    # 持久化状态
    mkdir -p "$STATE_DIR"
    _state_set cf_autoupdate "$CF_AUTOUPDATE"
    _state_set cf_http2 "$CF_HTTP2"
    _state_set cf_ipv6 "$CF_IPV6"
    _state_set cf_token "$token"
    _success "cloudflared 安装完成(已注册服务并开机自启)"
    _tip "隧道路由请在 Cloudflare Web 端配置, 本脚本不写 config.yml"
}

# ---------------------------------------------------------------------------
# 卸载 cloudflared(彻底清)
# ---------------------------------------------------------------------------
_uninstall_cloudflared() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装"; return 0; }
    _info "卸载 cloudflared..."
    "$CF_BIN" service uninstall 2>/dev/null || true
    _cf_kill_all   # 确保进程彻底死掉再删文件（替换原来的裸 stop）
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable cloudflared 2>/dev/null || true
            rm -f "$CF_UNIT_SYSTEMD" "${CF_UNIT_SYSTEMD}.bak"
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            rc-update del cloudflared default 2>/dev/null || true
            rm -f "$CF_UNIT_OPENRC" "${CF_UNIT_OPENRC}.bak"
            ;;
    esac
    rm -f "$CF_BIN"
    rm -f "$CF_STATE_AUTOUPDATE" "$CF_STATE_HTTP2" "$CF_STATE_IPV6" "$CF_STATE_TOKEN"
    _success "cloudflared 已卸载(二进制/服务/状态已清除)"
}

# ---------------------------------------------------------------------------
# 切换/补录令牌
# 策略: 优先"只替换 token"保留原 service 行其他参数(不破坏手动装的好配置);
#       service 文件不存在时才用 cloudflared service install 注册。
# 绝不在已装状态下重复 service install(会冲突报错)。
# ---------------------------------------------------------------------------
_cf_switch_token() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    if [ -n "$CF_CUR_TOKEN" ]; then
        echo -e "  当前令牌: ${CF_CUR_TOKEN:0:12}...${CF_CUR_TOKEN: -4}"
    else
        _warn "未能从 service 文件读取令牌(可能是手动安装或格式不同)"
    fi
    read -rp "  粘贴新令牌(或 CF 安装命令): " input
    local token; token=$(_extract_token "$input")
    [ -z "$token" ] && token="$input"
    [ -z "$token" ] && { _warn "令牌为空, 取消"; return 1; }

    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac

    if [ ! -f "$svcfile" ]; then
        # service 文件不存在: 用官方命令注册一次
        _info "service 文件不存在, 调用 cloudflared service install 注册..."
        "$CF_BIN" service install "$token" 2>/dev/null || true
        # 注册后若文件出现, 再用只换 token 方式确保 token 正确
        if [ -f "$svcfile" ]; then
            _cf_replace_token_in_service "" "$token"
        fi
    else
        # service 文件已存在: 只换 token, 保留原参数(关键: 不破坏手动装的好配置)
        _info "保留原有启动参数, 仅替换令牌..."
        _cf_replace_token_in_service "$CF_CUR_TOKEN" "$token" || {
            _error "替换令牌失败"
            return 1
        }
    fi

    # 重启: 先杀干净所有, 等 CF 边缘回收旧 session, 验证启动
    _cf_restart
    local restarted_ok="no"
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet cloudflared 2>/dev/null && restarted_ok="yes" ;;
        openrc)  rc-service cloudflared status 2>/dev/null | grep -q started && restarted_ok="yes" ;;
    esac
    if [ "$restarted_ok" = "no" ] && [ -f "${svcfile}.bak" ]; then
        _warn "重启后服务未运行, 回滚 service 文件..."
        cat "${svcfile}.bak" > "$svcfile"
        case "$svcfile" in /etc/init.d/*) chmod +x "$svcfile" 2>/dev/null ;; esac
        [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload 2>/dev/null
        _cf_restart
        _error "令牌替换后服务异常, 已回滚。请检查令牌是否正确, 或手动检查 $svcfile"
        return 1
    fi
    _state_set cf_token "$token"
    _success "令牌已更新, cloudflared 已重启(隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# 切换 3 开关: 在原 service 启动行里增/删对应参数片段(不重组整行, 不破坏原结构)
# 用法:_cf_toggle <autoupdate|http2|ipv6>
# ---------------------------------------------------------------------------
_cf_toggle() {
    local key="$1"
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    if [ -z "$CF_CUR_TOKEN" ]; then
        _warn "未能读取令牌(可能是手动安装), 请先 [1] 补录令牌后再切换开关"
        return 1
    fi
    local cur
    case "$key" in
        autoupdate) cur="${CF_CUR_AUTOUPDATE:-on}" ;;
        http2)      cur="${CF_CUR_HTTP2:-on}" ;;
        ipv6)       cur="${CF_CUR_IPV6:-off}" ;;
    esac
    local new; [ "$cur" = "on" ] && new="off" || new="on"

    # 在 service 文件里增/删对应参数片段
    local svcfile add_frag del_frag
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    [ -f "$svcfile" ] || { _error "service 文件不存在: $svcfile"; return 1; }

    case "$key" in
        autoupdate)
            # 开:加 --autoupdate-freq 24h0m0s; 关:删 --autoupdate-freq xxx, 加 --no-autoupdate
            add_frag="--autoupdate-freq 24h0m0s"
            ;;
        http2)
            add_frag="--protocol http2"
            ;;
        ipv6)
            add_frag="--edge-ip-version 6"
            ;;
    esac

    # 备份
    cp -f "$svcfile" "${svcfile}.bak"
    local tmp; tmp=$(mktemp)
    while IFS= read -r ln || [ -n "$ln" ]; do
        # 只处理含 cloudflared 启动参数的行(command_args / command / supervise_daemon_args / ExecStart / start 块内联)
        case "$ln" in
            *tunnel*|--token*)
                local modified="$ln"
                if [ "$new" = "on" ]; then
                    # 加片段(若尚未存在)
                    case "$modified" in
                        *${add_frag}*) ;;  # 已有, 不加
                        *)
                            # 在闭合双引号前插入(若行尾是 "..."); 否则行尾追加
                            case "$modified" in
                                *\") modified="${modified%\"} ${add_frag}\"" ;;
                                *)   modified="${modified} ${add_frag}" ;;
                            esac
                            ;;
                    esac
                else
                    # 关: 删除该片段及其可能的取值
                    case "$key" in
                        autoupdate)
                            modified=$(printf '%s' "$modified" | sed 's/ --autoupdate-freq [^ ]*//g; s/--autoupdate-freq [^ ]* //g')
                            case "$modified" in *--no-autoupdate*) ;; *)
                                # 在闭合引号前插入 --no-autoupdate
                                case "$modified" in
                                    *\") modified="${modified%\"} --no-autoupdate\"" ;;
                                    *)   modified="${modified} --no-autoupdate" ;;
                                esac ;;
                            esac
                            ;;
                        http2)
                            modified=$(printf '%s' "$modified" | sed 's/ --protocol http2//g; s/--protocol http2 //g')
                            ;;
                        ipv6)
                            modified=$(printf '%s' "$modified" | sed 's/ --edge-ip-version 6//g; s/--edge-ip-version 6 //g')
                            ;;
                    esac
                fi
                printf '%s\n' "$modified" >> "$tmp"
                ;;
            *)
                printf '%s\n' "$ln" >> "$tmp"
                ;;
        esac
    done < "$svcfile"
    cat "$tmp" > "$svcfile"
    rm -f "$tmp"
    case "$svcfile" in /etc/init.d/*) chmod +x "$svcfile" 2>/dev/null ;; esac
    [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload 2>/dev/null

    # 重启: 先杀干净所有, 等 CF 边缘回收旧 session, 再 start
    _cf_restart
    _state_set "cf_$key" "$new"
    _success "${key} 已切换为 ${new}(cloudflared 已重启, 隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# cloudflared 子菜单
# ---------------------------------------------------------------------------
_cloudflared_menu() {
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【cloudflared 管理】${NC}"
        local installed="no"
        [ -x "$CF_BIN" ] && installed="yes"
        if [ "$installed" = "yes" ]; then
            _read_cf_state
            local tok_disp
            if [ -n "$CF_CUR_TOKEN" ]; then
                tok_disp="${CF_CUR_TOKEN:0:12}...${CF_CUR_TOKEN: -4}"
            else
                tok_disp="${YELLOW}未读取(需补录)${NC}"
            fi
            echo -e "  状态: ${GREEN}已安装${NC}  令牌: ${tok_disp}"
            echo -e "  自动更新: $(_cf_onoff "${CF_CUR_AUTOUPDATE:-on}")  HTTP/2: $(_cf_onoff "${CF_CUR_HTTP2:-on}")  IPv6栈: $(_cf_onoff "${CF_CUR_IPV6:-off}")"
            echo
            if [ -n "$CF_CUR_TOKEN" ]; then
                echo -e "  ${GREEN}[1]${NC} 切换令牌"
            else
                echo -e "  ${GREEN}[1]${NC} 补录令牌(手动安装的 cloudflared)"
            fi
            echo -e "  ${GREEN}[2]${NC} 切换 自动更新 (当前 $(_cf_onoff "${CF_CUR_AUTOUPDATE:-on}"))"
            echo -e "  ${GREEN}[3]${NC} 切换 HTTP/2      (当前 $(_cf_onoff "${CF_CUR_HTTP2:-on}"))"
            echo -e "  ${GREEN}[4]${NC} 切换 IPv6栈      (当前 $(_cf_onoff "${CF_CUR_IPV6:-off}"))"
            echo -e "  ${GREEN}[5]${NC} 重启 cloudflared"
            echo -e "  ${GREEN}[6]${NC} 诊断(查看 service 文件内容)"
            echo -e "  ${GREEN}[9]${NC} 卸载"
        else
            echo -e "  状态: ${RED}未安装${NC}"
            echo
            echo -e "  ${GREEN}[1]${NC} 安装 cloudflared"
        fi
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择: " choice
        case "$choice" in
            1) [ "$installed" = "yes" ] && _cf_switch_token || _install_cloudflared ;;
            2) _cf_toggle autoupdate ;;
            3) _cf_toggle http2 ;;
            4) _cf_toggle ipv6 ;;
            5) _cf_restart; _success "已重启" ;;
            6) _cf_diagnose ;;
            9) _uninstall_cloudflared ;;
            0) return ;;
            *) _warn "无效" ;;
        esac
        _press_any_key
    done
}

# 诊断: 显示 service 文件内容 + 解析结果, 便于排查"读不出 token"
_cf_diagnose() {
    echo
    echo -e "  ${CYAN}【cloudflared 诊断】${NC}"
    local svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *)       svcfile="$CF_UNIT_SYSTEMD" ;;
    esac
    echo -e "  service 文件: ${svcfile}"
    if [ -f "$svcfile" ]; then
        echo -e "  权限: $(ls -la "$svcfile" | awk '{print $1}')"
        echo -e "  解析到的 token: ${CF_CUR_TOKEN:-(空)}"
        echo -e "  解析到的开关: auto=${CF_CUR_AUTOUPDATE} http2=${CF_CUR_HTTP2} ipv6=${CF_CUR_IPV6}"
        echo
        echo -e "  ${CYAN}--- 文件内容 ---${NC}"
        cat "$svcfile"
        echo -e "  ${CYAN}--- end ---${NC}"
        echo
        _tip "若 token 解析为空但文件里有 ey... 串, 请把以上内容(token 用 xxx 替代)反馈给开发者"
    else
        _warn "service 文件不存在"
    fi
}

_cf_onoff() {
    [ "$1" = "on" ] && echo "${GREEN}● 开${NC}" || echo "${RED}○ 关${NC}"
}
