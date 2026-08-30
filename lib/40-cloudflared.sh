#!/bin/bash
# =============================================================================
# lib/40-cloudflared.sh — cloudflared 管理
# 需求 R5:
#   - 安装(架构自适应下载) / 卸载(彻底清) / 切换令牌
#   - 安装走官方 `cloudflared service install <token>`, 不写 config.yml(路由在 CF Web 配)
#   - 改参数/令牌 = 直接改 /etc/systemd/system/cloudflared.service 或 /etc/init.d/cloudflared 启动行
#   - 3 项设置: 自动更新 (--autoupdate-freq 24h0m0s / --no-autoupdate)
#               HTTP/2   (--protocol http2 / 不写)
#               协议栈   (--edge-ip-version 4|6|auto / 不写)
#   - cloudflared 是唯一例外, 落官方默认点, 不收口 /opt/xray-deploy
# ============================================================================

# cloudflared 开关状态文件(持久化供手动查看, 运行时从 service 文件解析)
CF_STATE_AUTOUPDATE="$STATE_DIR/cf_autoupdate"     # on|off
CF_STATE_HTTP2="$STATE_DIR/cf_http2"               # on|off
CF_STATE_EDGE_IP="$STATE_DIR/cf_edge_ip"           # off|4|6|auto
CF_STATE_TOKEN="$STATE_DIR/cf_token"               # 安装时的 token

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
# 输出全局: CF_CUR_TOKEN / CF_CUR_AUTOUPDATE / CF_CUR_HTTP2 / CF_CUR_EDGE_IP
# ---------------------------------------------------------------------------
_read_cf_state() {
    CF_CUR_TOKEN=""; CF_CUR_AUTOUPDATE="off"; CF_CUR_HTTP2="off"; CF_CUR_EDGE_IP="off"; CF_CUR_RAWLINE=""
    local svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *)       svcfile="$CF_UNIT_SYSTEMD" ;;
    esac
    [ -f "$svcfile" ] || return 1
    # 收集所有可能的启动行(先去行首空白, 兼容缩进)
    local lines="" ln
    while IFS= read -r ln || [ -n "$ln" ]; do
        local t="${ln#"${ln%%[![:space:]]*}"}"
        case "$t" in
            command_args=*|command=*|supervise_daemon_args=*|ExecStart=*|start\)|cmd=*)
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
    # 协议栈: --edge-ip-version <4|6|auto>; 未写则 off
    if   echo "$oneline" | grep -q -- '--edge-ip-version 4';    then CF_CUR_EDGE_IP="4";
    elif echo "$oneline" | grep -q -- '--edge-ip-version 6';    then CF_CUR_EDGE_IP="6";
    elif echo "$oneline" | grep -q -- '--edge-ip-version auto'; then CF_CUR_EDGE_IP="auto";
    fi
}

# ---------------------------------------------------------------------------
# 重组 cloudflared 启动命令行(按 3 开关 + token)
# 用法:_cf_build_cmdline <token>
# 读取全局 CF_AUTOUPDATE/CF_HTTP2/CF_EDGE_IP
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
    case "$CF_EDGE_IP" in
        4)    cmd="$cmd --edge-ip-version 4" ;;
        6)    cmd="$cmd --edge-ip-version 6" ;;
        auto) cmd="$cmd --edge-ip-version auto" ;;
    esac
    cmd="$cmd run --token $token"
    echo "$cmd"
}

# ---------------------------------------------------------------------------
# 把启动行写回 service 文件(纯 bash 逐行处理, 避 busybox sed -E)
# 用法:_cf_write_service_line <cmdline>          (整行重组)
#       _cf_replace_token_in_service <oldtoken> <newtoken>  (只换 token, 保留原参数)
# ---------------------------------------------------------------------------
# 通用: 逐行读 service 文件, 替换匹配行, 写回(保留原文件权限)
# 兼容缩进: 匹配前先去除行首空白; 未匹配到任何行时返回 1
_svc_replace_line() {
    local svcfile="$1" pattern="$2" newline="$3" tmp found=0
    [ -f "$svcfile" ] || return 1
    cp -f "$svcfile" "${svcfile}.bak"
    tmp=$(mktemp)
    while IFS= read -r ln || [ -n "$ln" ]; do
        local t="${ln#"${ln%%[![:space:]]*}"}"
        case "$t" in
            "$pattern"*) printf '%s\n' "$newline" >> "$tmp"; found=1 ;;
            *) printf '%s\n' "$ln" >> "$tmp" ;;
        esac
    done < "$svcfile"
    if [ "$found" -eq 0 ]; then
        rm -f "$tmp"
        return 1
    fi
    # 用 cat 保内容 + 原文件保留(避免 mktemp 无执行位的问题): 先覆盖内容, 再恢复权限
    [ -s "$tmp" ] && cat "$tmp" > "$svcfile"
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
        if grep -q '^[[:space:]]*command_args=' "$svcfile" 2>/dev/null; then
            local prefix="$CF_BIN "
            local args="${cmd#$prefix}"
            _svc_replace_line "$svcfile" "command_args=" "command_args=\"$args\"" || return 1
        elif grep -q '^[[:space:]]*cmd=' "$svcfile" 2>/dev/null; then
            _svc_replace_line "$svcfile" "cmd=" "cmd=\"$cmd\"" || return 1
        else
            _error "无法在 $svcfile 中找到 command_args= 或 cmd= 行"
            return 1
        fi
    else
        _svc_replace_line "$svcfile" "ExecStart=" "ExecStart=$cmd" || return 1
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
    [ -s "$tmp" ] && cat "$tmp" > "$svcfile"
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

    # 默认设置(脚本安装默认: 自动更新 off, HTTP2 on, 协议栈 off)
    CF_AUTOUPDATE="off"; CF_HTTP2="on"; CF_EDGE_IP="off"

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
    _state_set cf_edge_ip "$CF_EDGE_IP"
    _state_set cf_token "$token"
    # 验证 service 真正启动 (M5: token 非法时 service install 仍成功, 但服务无法运行)
    if _cf_is_running; then
        _success "cloudflared 安装完成(已注册服务并开机自启)"
    else
        _warn "cloudflared 已安装但服务未运行, 请检查 token 是否正确"
    fi
    _tip "已默认关闭 cloudflared 自动更新、开启 HTTP2 连接（可在 cloudflared 管理中修改）"
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
    rm -f "$CF_STATE_AUTOUPDATE" "$CF_STATE_HTTP2" "$CF_STATE_EDGE_IP" "$CF_STATE_TOKEN" "$STATE_DIR/cf_ipv6"
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
        openrc)  _cf_is_running && restarted_ok="yes" ;;
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
# 切换 2 开关(autoupdate|http2): 读取当前状态, 反转目标开关, 用 _cf_build_cmdline 重组整行写回
# (从头重建保证参数顺序: 全局标志 tunnel 连接标志 run --token)
# 协议栈为四选一, 走 _cf_set_edge_ip(见下)
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
    esac
    local new; [ "$cur" = "on" ] && new="off" || new="on"

    CF_AUTOUPDATE="${CF_CUR_AUTOUPDATE}"; CF_HTTP2="${CF_CUR_HTTP2}"; CF_EDGE_IP="${CF_CUR_EDGE_IP}"
    case "$key" in
        autoupdate) CF_AUTOUPDATE="$new" ;;
        http2)      CF_HTTP2="$new" ;;
    esac
    _cf_write_service_line "$(_cf_build_cmdline "$CF_CUR_TOKEN")" || return 1

    _cf_restart
    if ! _cf_is_running; then
        _warn "切换后服务未运行, 回滚..."
        local svcfile
        case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
        if [ -f "${svcfile}.bak" ]; then
            cat "${svcfile}.bak" > "$svcfile"
            case "$svcfile" in /etc/init.d/*) chmod +x "$svcfile" 2>/dev/null ;; esac
            [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload 2>/dev/null
            _cf_restart
        fi
        _error "${key} 切换失败, 已回滚到原状态"
        return 1
    fi
    _state_set "cf_$key" "$new"
    _success "${key} 已切换为 ${new}(cloudflared 已重启, 隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# 设置协议栈 (--edge-ip-version 4|6|auto|关)
# 四选一: IPv4 / IPv6 / Auto / 关(不写参数, 交 cloudflared 默认)
# ---------------------------------------------------------------------------
_cf_set_edge_ip() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    if [ -z "$CF_CUR_TOKEN" ]; then
        _warn "未能读取令牌(可能是手动安装), 请先 [1] 补录令牌后再切换协议栈"
        return 1
    fi
    local cur="${CF_CUR_EDGE_IP:-off}"
    echo
    echo -e "  ${CYAN}【切换协议栈】${NC}"
    echo -e "  当前: $(_cf_edge_ip_disp "$cur")"
    echo
    echo -e "  ${GREEN}[1]${NC} IPv4 (--edge-ip-version 4)"
    echo -e "  ${GREEN}[2]${NC} IPv6 (--edge-ip-version 6)"
    echo -e "  ${GREEN}[3]${NC} Auto (--edge-ip-version auto)"
    echo -e "  ${GREEN}[4]${NC} 关   (不写参数, 使用 cloudflared 默认)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    local choice
    read -rp "  请选择: " choice
    local val
    case "$choice" in
        1) val="4" ;;
        2) val="6" ;;
        3) val="auto" ;;
        4) val="off" ;;
        0) return 0 ;;
        *) _warn "无效"; return 1 ;;
    esac
    if [ "$val" = "$cur" ]; then
        _info "协议栈已是 $(_cf_edge_ip_label "$val")，无需切换"
        return 0
    fi

    CF_AUTOUPDATE="${CF_CUR_AUTOUPDATE}"; CF_HTTP2="${CF_CUR_HTTP2}"; CF_EDGE_IP="$val"
    _cf_write_service_line "$(_cf_build_cmdline "$CF_CUR_TOKEN")" || return 1

    _cf_restart
    if ! _cf_is_running; then
        _warn "切换后服务未运行, 回滚..."
        local svcfile
        case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
        if [ -f "${svcfile}.bak" ]; then
            cat "${svcfile}.bak" > "$svcfile"
            case "$svcfile" in /etc/init.d/*) chmod +x "$svcfile" 2>/dev/null ;; esac
            [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload 2>/dev/null
            _cf_restart
        fi
        _error "协议栈切换失败, 已回滚到原状态"
        return 1
    fi
    _state_set cf_edge_ip "$val"
    _success "协议栈已切换为 $(_cf_edge_ip_label "$val")(cloudflared 已重启, 隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# cloudflared 子菜单
# ---------------------------------------------------------------------------
_cloudflared_menu() {
    local choice
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
            echo -e "  自动更新: $(_cf_onoff "${CF_CUR_AUTOUPDATE:-on}")  HTTP/2: $(_cf_onoff "${CF_CUR_HTTP2:-on}")  协议栈: $(_cf_edge_ip_disp "${CF_CUR_EDGE_IP:-off}")"
            echo
            if [ -n "$CF_CUR_TOKEN" ]; then
                echo -e "  ${GREEN}[1]${NC} 切换令牌"
            else
                echo -e "  ${GREEN}[1]${NC} 补录令牌(手动安装的 cloudflared)"
            fi
            echo -e "  ${GREEN}[2]${NC} 切换 自动更新 (当前 $(_cf_onoff "${CF_CUR_AUTOUPDATE:-on}"))"
            echo -e "  ${GREEN}[3]${NC} 切换 HTTP/2      (当前 $(_cf_onoff "${CF_CUR_HTTP2:-on}"))"
            echo -e "  ${GREEN}[4]${NC} 切换 协议栈      (当前 $(_cf_edge_ip_disp "${CF_CUR_EDGE_IP:-off}"))"
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
            1) if [ "$installed" = "yes" ]; then _cf_switch_token; else _install_cloudflared; fi ;;
            2) _cf_toggle autoupdate ;;
            3) _cf_toggle http2 ;;
            4) _cf_set_edge_ip ;;
            5) _cf_restart; if _cf_is_running; then _success "已重启"; else _warn "重启后服务未运行, 请检查状态"; fi ;;
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
        echo -e "  解析到的开关: auto=${CF_CUR_AUTOUPDATE} http2=${CF_CUR_HTTP2} 协议栈=${CF_CUR_EDGE_IP}"
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

# 协议栈显示: 带颜色 (菜单/状态栏)
_cf_edge_ip_disp() {
    case "$1" in
        4)    echo "${GREEN}● IPv4${NC}" ;;
        6)    echo "${GREEN}● IPv6${NC}" ;;
        auto) echo "${GREEN}● Auto${NC}" ;;
        *)    echo "${RED}○ 关${NC}" ;;
    esac
}

# 协议栈纯文本标签(日志/提示用, 不带颜色)
_cf_edge_ip_label() {
    case "$1" in
        4) echo "IPv4" ;;
        6) echo "IPv6" ;;
        auto) echo "Auto" ;;
        *) echo "关" ;;
    esac
}
