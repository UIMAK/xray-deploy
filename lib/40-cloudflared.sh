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
    # 先下到同目录临时文件再原子替换, 避免半截文件留在最终路径(L7); curl 优先(H1)
    # R38(P1): chmod/mv 必须检查——mv 失败(分区满/只读/同名目录)时 $CF_BIN 根本不存在,
    # 原实现却因末句 _success 返回 0 而报"安装成功", 且把 cloudflared.tmp.XXXXXX 留在
    # 最终目录旁(正是本 PR 要消除的"半截文件留在最终路径")。与 20-xray-core.sh 的
    # cp/mv/chmod 三步全查保持同一标准。
    local cf_tmp; cf_tmp=$(mktemp "${CF_BIN}.tmp.XXXXXX") || {
        _error "无法创建临时文件: ${CF_BIN}.tmp.XXXXXX(目录不可写/磁盘空间?)"
        return 1
    }
    if ! _http_download "$url" "$cf_tmp" 120; then
        rm -f "$cf_tmp"
        _error "cloudflared 下载失败"; return 1
    fi
    if ! chmod +x "$cf_tmp"; then
        rm -f "$cf_tmp"
        _error "cloudflared 设置执行权限失败"; return 1
    fi
    if ! mv -f "$cf_tmp" "$CF_BIN"; then
        rm -f "$cf_tmp"
        _error "cloudflared 落地失败(磁盘空间/只读/权限?), 未安装"; return 1
    fi
    _success "cloudflared 安装成功"
    return 0
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
    # 备份必须真正成功才允许改 service(磁盘满/IO 失败时无 .bak 可恢复)
    cp -f "$svcfile" "${svcfile}.bak" 2>/dev/null || { _error "service 备份失败: $svcfile"; return 1; }
    local tmp write_ok=1
    tmp=$(mktemp) || { _error "无法创建临时 service 文件: $svcfile"; return 1; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        local t="${ln#"${ln%%[![:space:]]*}"}"
        case "$t" in
            "$pattern"*) printf '%s\n' "$newline" >> "$tmp" || write_ok=0; found=1 ;;
            *) printf '%s\n' "$ln" >> "$tmp" || write_ok=0 ;;
        esac
    done < "$svcfile"
    if [ "$found" -eq 0 ]; then
        # 未找到目标行: 本次未产生任何修改, 同时清理 .bak 避免留下陈旧回滚点
        rm -f "$tmp" "$svcfile.bak"
        return 1
    fi
    # tmp 构造必须完整成功(磁盘满/IO/配额时 printf 可能写一半), 否则半截文件会被 _svc_commit 提交
    if [ "$write_ok" -ne 1 ]; then
        _error "临时 service 文件写入失败(磁盘空间/IO?), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    _svc_commit "$svcfile" "$tmp"
}

# 把 tmp 提交为 service 文件内容: cat(而非 mv)保原文件 inode 与权限(openrc init.d 的
# +x 位不能丢; mktemp 是 0600)。写入失败自动从 .bak 恢复并返回 1, 保证"失败可恢复"。
_svc_commit() {
    local svcfile="$1" tmp="$2"
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    if ! cat "$tmp" > "$svcfile"; then
        _error "service 文件写入失败($svcfile), 尝试从备份恢复"
        if [ -f "${svcfile}.bak" ]; then
            if ! cp -f "${svcfile}.bak" "$svcfile" 2>/dev/null; then
                _error "service 文件从备份恢复也失败: $svcfile, 请手动处理"
            fi
        fi
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    # openrc init.d 文件需可执行。chmod 失败时文件已被 cat 改写成新内容, 必须 restore 才能算"提交失败
    # 但内容已回退"(否则调用方收到失败、service 却是新内容, 事务泄漏)。
    case "$svcfile" in
        /etc/init.d/*)
            if ! chmod +x "$svcfile" 2>/dev/null; then
                _error "service 执行权限设置失败: $svcfile, 回滚 service 文件"
                _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
                return 1
            fi
            ;;
    esac
    return 0
}

# 从 .bak 恢复 service 文件(cat 保原文件权限/执行位, 与 _svc_commit 一致)。
# 回滚本身必须检查: 失败显式报错并返回 1, 不静默"假装已回滚"。
_svc_restore() {
    local svcfile="$1"
    [ -f "${svcfile}.bak" ] || { _warn "无 ${svcfile}.bak 可回滚"; return 1; }
    if ! cat "${svcfile}.bak" > "$svcfile"; then
        _error "service 回滚失败: $svcfile, 请手动检查"
        return 1
    fi
    case "$svcfile" in
        /etc/init.d/*)
            if ! chmod +x "$svcfile" 2>/dev/null; then
                _error "service 回滚后执行权限设置失败: $svcfile"
                return 1
            fi
            ;;
    esac
    # 恢复成功: .bak 已消费, 立即删除(否则直调 _svc_restore 的路径——_svc_commit chmod 失败、
    # _cf_write_service_line/_cf_replace_token_in_service 的 daemon-reload 失败——都会留下陈旧回滚点)
    rm -f "${svcfile}.bak"
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
        if ! systemctl daemon-reload 2>/dev/null; then
            _error "systemd daemon-reload 失败, 回滚 service 文件"
            _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
            if ! systemctl daemon-reload 2>/dev/null; then
                _error "恢复后的 daemon-reload 也失败: $svcfile"
            fi
            return 1
        fi
    fi
    return 0
}

# 只替换 service 启动行里的 token, 保留用户原有的其他参数(不破坏手动装的好配置)
# 用纯 bash 字符串替换(不依赖 sed -E 正则)
# R38(P1): 必须跟踪"是否真的替换了至少一处"(replaced)。原实现只看写 tmp 是否成功, 于是
#   (a) oldtok 非空但与文件实际字节不符(手动安装用 Environment=TUNNEL_TOKEN= / --token-file /
#       token 被引号或换行包裹), 或 (b) oldtok 为空且行内没有裸 ey... 词,
#   都会"零替换"却返回 0 —— 调用方随后用**旧 token** 重启, _cf_is_running 自然为真,
#   于是写入新 token 到 state 并报「令牌已更新」。隧道仍挂旧账号, state 与 service 分裂。
#   这正是本 PR 要消除的假成功, 与 _svc_replace_line 的 found 检查保持同一标准。
_cf_replace_token_in_service() {
    local oldtok="$1" newtok="$2" svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *) return 1 ;;
    esac
    [ -f "$svcfile" ] || return 1
    # 备份必须真正成功才允许改 service(失败可恢复)
    cp -f "$svcfile" "${svcfile}.bak" 2>/dev/null || { _error "service 备份失败: $svcfile"; return 1; }
    local tmp write_ok=1 replaced=0
    tmp=$(mktemp) || { _error "无法创建临时 service 文件: $svcfile"; return 1; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        if [ -n "$oldtok" ]; then
            case "$ln" in
                *"$oldtok"*) replaced=1 ;;
            esac
            printf '%s\n' "${ln//"$oldtok"/$newtok}" >> "$tmp" || write_ok=0
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
                replaced=1
                printf '%s\n' "${out# }" >> "$tmp" || write_ok=0
            else
                printf '%s\n' "$ln" >> "$tmp" || write_ok=0
            fi
        fi
    done < "$svcfile"
    # tmp 构造必须完整成功(磁盘满/IO/配额时 printf 可能写一半), 否则半截文件会被提交
    if [ "$write_ok" -ne 1 ]; then
        _error "临时 service 文件写入失败(磁盘空间/IO?), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    # R38(P1): 零替换必须失败——否则调用方会拿旧 token 重启并宣称"令牌已更新"
    if [ "$replaced" -ne 1 ]; then
        rm -f "$tmp" "${svcfile}.bak"
        _error "未在 $svcfile 中找到可替换的令牌, 令牌未更新"
        _tip "该 service 可能由 cloudflared 官方命令以其他形式写入(如 --token-file / Environment=), 请手动编辑 $svcfile 后重启"
        return 1
    fi
    _svc_commit "$svcfile" "$tmp" || return 1
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if ! systemctl daemon-reload 2>/dev/null; then
            _error "systemd daemon-reload 失败, 回滚 service 文件"
            _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
            if ! systemctl daemon-reload 2>/dev/null; then
                _error "恢复后的 daemon-reload 也失败: $svcfile"
            fi
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# R38(P2): 统一的 cloudflared 进程发现。与 _cf_is_running 用同一套判据, 避免
# "判活用 /proc 扫描、杀进程用 pgrep" 两套逻辑不一致: 容器内 busybox pgrep 假阴性时
# _cf_kill_all 会报"已清理"而实际仍有残留, 随后 start 出第二个实例。
# 另: procps 的 ps 无 -e 时只列当前 tty 的进程, cron 下几乎列不出东西, 必须带 -e。
# 输出: 每行一个 PID(可能为空)
# ---------------------------------------------------------------------------
_cf_pids() {
    local pids p c
    pids=$(pidof cloudflared 2>/dev/null | tr ' ' '\n' | grep -e '^[0-9][0-9]*$')
    if [ -n "$pids" ]; then
        printf '%s\n' "$pids"
        return 0
    fi
    for p in /proc/[0-9]*; do
        read -r c 2>/dev/null < "$p/comm" || continue
        [ "$c" = "cloudflared" ] && printf '%s\n' "${p#/proc/}"
    done
}

# ---------------------------------------------------------------------------
# 强力杀干净所有 cloudflared 进程(防止 PID 残留导致的进程泄漏)
# openrc 的 rc-service stop 经常杀不干净, 必须内核级 kill 兜底
# ---------------------------------------------------------------------------
_cf_kill_all() {
    local pids="" pid i

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

    # 2. 杀 PID 文件里的残留(PID reuse 防护: 只对 comm 确为 cloudflared 的 pidfile PID 发信号,
    #    避免 cloudflared 退出后 PID 被其他进程复用而误杀 nginx/sshd 等)
    for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
        local _pf_pid; _pf_pid=$(cat "$pf" 2>/dev/null)
        if [ -n "$_pf_pid" ] && [ "$(cat "/proc/$_pf_pid/comm" 2>/dev/null)" = "cloudflared" ]; then
            kill "$_pf_pid" 2>/dev/null || true
        fi
        rm -f "$pf" 2>/dev/null
    done

    # 3. 扫残留进程：先 SIGTERM（给 cloudflared 时间向 CF 边缘发送断开信号），等 3s，再 SIGKILL
    # R38(P2): 统一走 _cf_pids(与 _cf_is_running 同判据), 不再用 pgrep/ps 两套逻辑
    pids=$(_cf_pids)
    if [ -n "$pids" ]; then
        for pid in $pids; do kill -15 "$pid" 2>/dev/null || true; done
        sleep 3
        # 再扫一次，还活着的直接 SIGKILL
        pids=$(_cf_pids)
        for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
        sleep 1
    fi

    # 4. 最终确认
    pids=$(_cf_pids)
    if [ -n "$pids" ]; then
        # R38(P2): 仍然返回 1 把"有残留"这个事实报给调用方, 但调用方语义变了 ——
        # _cf_restart 不再据此跳过 start(见那里的注释)。原先"残留即中止"会让 _cf_restart
        # 在已 stop+TERM+KILL **之后**直接返回而不 start, 一次普通的开关切换就把隧道彻底
        # 打停; 调用方随后 _cf_rollback_service 内部又走 _cf_restart, 同一残留进程导致再次
        # 不 start, 于是永久下线。残留可能来自不可中断 IO 的进程, 也可能是宿主上与本脚本
        # 无关的另一个 cloudflared(_cf_pids 是全机范围)。
        _warn "cloudflared 仍有残留进程: $pids (可能是宿主上另一个 cloudflared 实例)"
        _tip "若隧道行为异常, 请手动确认这些进程是否应当存在"
        return 1
    fi
    _info "cloudflared 所有进程已清理"
    return 0
}

# 重启 cloudflared service(先杀干净所有, 等 CF 边缘回收旧 session, 再重新 start)
# 返回 start 命令的真实结果; 调用方仍应再做真实 liveness(_cf_is_running)确认
_cf_restart() {
    # R38(P2): 残留进程只告警、不再中止 start —— 见 _cf_kill_all 内的注释:
    # "残留即中止"会让一次普通的开关切换确定性地把隧道打停且无法自动恢复。
    # 双实例风险改由 start 后的 _cf_is_running 与显式告警交给用户判断。
    _cf_kill_all || _warn "cloudflared 停止流程未完全成功(有残留进程), 仍尝试启动"
    sleep 2   # 等 CF 边缘感知旧 connector 断开
    local rc=1
    case "$INIT_SYSTEM" in
        systemd) systemctl start cloudflared 2>/dev/null; rc=$? ;;
        openrc)  rc-service cloudflared start 2>/dev/null; rc=$? ;;
        *) return 1 ;;
    esac
    sleep 3   # 等新进程建立连接后再做后续检测
    return "$rc"
}

# 从 .bak 回滚 service 文件并尽力恢复服务: restore -> (systemd) reload -> restart。
# 供 token/开关/协议栈切换失败时统一使用。严格语义: restore -> (systemd) reload -> restart ->
# liveness, 全部成功才算回滚成功(rc 0); 任一步失败 rc 1——"service 文件恢复"≠"系统回到原状态"。
_cf_rollback_service() {
    local svcfile="$1"
    [ -f "${svcfile}.bak" ] || { _warn "无 ${svcfile}.bak 可回滚"; return 1; }
    if ! _svc_restore "$svcfile"; then
        _warn "回滚失败, 请手动检查 $svcfile"
        return 1
    fi
    if [ "$INIT_SYSTEM" = "systemd" ] && ! systemctl daemon-reload 2>/dev/null; then
        _error "回滚后 systemd daemon-reload 也失败: $svcfile"
        return 1
    fi
    if ! _cf_restart 2>/dev/null; then
        _error "回滚后 cloudflared 重启失败: $svcfile"
        return 1
    fi
    if ! _cf_is_running; then
        _error "回滚后 cloudflared 未运行: $svcfile"
        return 1
    fi
    return 0
}

# 判断 cloudflared 是否在运行(状态栏 + 诊断用)
_cf_is_running() {
    local anchor=""
    case "$INIT_SYSTEM" in
        systemd)
            # R38(M3): 用 MainPID 把判活绑定到本 unit 的主进程, 而不是"机器上有没有叫
            # cloudflared 的进程"。同时避免 is-active 在崩溃循环的 activating 窗口报成功。
            anchor=$(systemctl show -p MainPID --value cloudflared 2>/dev/null)
            if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ]; then
                _proc_named_under "$anchor" cloudflared && return 0
                return 1
            fi
            systemctl is-active --quiet cloudflared 2>/dev/null && _proc_any_named cloudflared
            return $?
            ;;
        *)
            # openrc/sysv/direct: 只认真实 cloudflared 进程, 不信 rc-service 的 started 文本
            # (supervise-daemon 崩溃循环时仍报 started)。优先按 pidfile 回溯进程树确认归属,
            # 拿不到 pidfile 时回退全机 comm 扫描(best-effort, 无法排除他人实例)。
            local pf
            for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
                anchor=$(cat "$pf" 2>/dev/null) || continue
                if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] && [ -d "/proc/$anchor" ]; then
                    _proc_named_under "$anchor" cloudflared && return 0
                    return 1
                fi
            done
            _proc_any_named cloudflared
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
    # 官方命令生成的 service 行可能不含我们要的参数, 重组覆盖。写入失败必须中止(不写 state,
    # 否则 state 记录的参数与 service 实际内容不一致)。
    if ! _cf_write_service_line "$(_cf_build_cmdline "$token")"; then
        _error "service 配置写入失败, 安装中止"
        return 1
    fi
    # 重启失败同样中止(service 已写好但未启动, 不宣称安装完成)
    if ! _cf_restart; then
        _error "cloudflared 启动失败, 安装中止"
        return 1
    fi
    # 安装事务完成(write+restart 成功): 清理 _cf_write_service_line 留下的预修改快照
    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    rm -f "${svcfile}.bak"
    # 全部成功后持久化状态
    mkdir -p "$STATE_DIR"
    _state_set cf_autoupdate "$CF_AUTOUPDATE" || _warn "状态持久化失败(cf_autoupdate)"
    _state_set cf_http2 "$CF_HTTP2" || _warn "状态持久化失败(cf_http2)"
    _state_set cf_edge_ip "$CF_EDGE_IP" || _warn "状态持久化失败(cf_edge_ip)"
    _state_set cf_token "$token" || _warn "状态持久化失败(cf_token)"
    # 验证 service 真正启动 (M5: token 非法时 service install 仍成功, 但服务无法运行;
    # 此时配置/state 已一致, 仅提示用户检查 token, 不把"未运行"误报为安装失败)
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
        # service 文件不存在: 用官方命令注册一次。install 失败必须中止, 不能继续往下走成"假成功"
        _info "service 文件不存在, 调用 cloudflared service install 注册..."
        if ! "$CF_BIN" service install "$token" 2>/dev/null; then
            _error "cloudflared service install 失败"
            return 1
        fi
        # 注册后若文件出现, 再用只换 token 方式确保 token 正确(替换失败同样中止)
        if [ -f "$svcfile" ]; then
            _cf_replace_token_in_service "" "$token" || {
                _error "service install 成功但 token 替换失败"
                return 1
            }
        else
            _error "cloudflared service install 成功但未生成 service 文件: $svcfile"
            return 1
        fi
    else
        # service 文件已存在: 只换 token, 保留原参数(关键: 不破坏手动装的好配置)
        _info "保留原有启动参数, 仅替换令牌..."
        _cf_replace_token_in_service "$CF_CUR_TOKEN" "$token" || {
            _error "替换令牌失败"
            return 1
        }
    fi

    # 重启: 先杀干净所有, 等 CF 边缘回收旧 session。restart 与 liveness 共同构成成功:
    # restart 命令失败即中止(与 _install_cloudflared 同一语义), 避免"重启失败却宣称令牌已更新"。
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚 service 文件..."
        if _cf_rollback_service "$svcfile"; then
            _error "令牌替换后重启失败, 已回滚到原令牌。请检查新令牌是否正确"
        else
            _error "令牌替换后重启失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    local restarted_ok="no"
    # R38(M3): 统一走 _cf_is_running —— 它现在把判活绑定到 unit MainPID / pidfile 进程树,
    # 比裸 is-active 更严(is-active 在崩溃循环的 activating 窗口也会返回 0)
    _cf_is_running && restarted_ok="yes"
    if [ "$restarted_ok" = "no" ]; then
        _warn "重启后服务未运行, 回滚 service 文件..."
        # R38(P1): 回滚结果必须如实反映——原写法在 _cf_rollback_service 返回 1 时仍无条件
        # 打印"已回滚", 与紧邻的"回滚失败"自相矛盾, 而此时 .bak 已被 _svc_restore 消费删除。
        if _cf_rollback_service "$svcfile"; then
            _error "令牌替换后服务异常, 已回滚到原令牌。请检查新令牌是否正确"
        else
            _error "令牌替换后服务异常, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照
    _state_set cf_token "$token" || _warn "状态持久化失败(cf_token)"
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
    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    _cf_write_service_line "$(_cf_build_cmdline "$CF_CUR_TOKEN")" || return 1

    # restart 与 liveness 共同构成成功(与 _cf_switch_token 同一语义), 失败即回滚
    # R38(P1): 回滚消息按真实结果分支, 不再在回滚失败时也宣称"已回滚到原状态"
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "${key} 切换失败, 已回滚到原状态"
        else
            _error "${key} 切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    if ! _cf_is_running; then
        _warn "切换后服务未运行, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "${key} 切换失败, 已回滚到原状态"
        else
            _error "${key} 切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照(.bak 是"最近一次修改前"的瞬态)
    _state_set "cf_$key" "$new" || _warn "状态持久化失败(cf_$key)"
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

    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    # restart 与 liveness 共同构成成功(与 _cf_switch_token 同一语义), 失败即回滚
    # R38(P1): 回滚消息按真实结果分支
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "协议栈切换失败, 已回滚到原状态"
        else
            _error "协议栈切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    if ! _cf_is_running; then
        _warn "切换后服务未运行, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "协议栈切换失败, 已回滚到原状态"
        else
            _error "协议栈切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照
    _state_set cf_edge_ip "$val" || _warn "状态持久化失败(cf_edge_ip)"
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
