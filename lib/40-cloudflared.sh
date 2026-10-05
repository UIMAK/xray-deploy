#!/bin/bash

CF_STATE_AUTOUPDATE="$STATE_DIR/cf_autoupdate"     # on|off
CF_STATE_HTTP2="$STATE_DIR/cf_http2"               # on|off
CF_STATE_EDGE_IP="$STATE_DIR/cf_edge_ip"           # off|4|6|auto
CF_STATE_TOKEN="$STATE_DIR/cf_token"               # 仅清理旧版本遗留

CF_GRACE_DEFAULT=30    # 官方 --grace-period 默认值
CF_GRACE_MARGIN=5      # 余量: 不在宽限期到点的同一瞬间强杀
CF_GRACE_MAX=300       # 上限: 防病态配置(cloudflared 自身只接受 <=3 分钟, 4h 只可能是手写错误)
CF_STOP_REVERIFY=5     # 强杀后复验 systemd 停止终态的上界(进程已死, 只剩 unit 事务)

_cf_arch_tag() {
    case "$(_detect_arch)" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        *)     echo "" ;;
    esac
}

_install_cloudflared_bin() {
    if [ -d "$CF_BIN" ]; then
        _error "cloudflared 目标路径是目录, 拒绝安装: $CF_BIN"
        return 1
    fi
    if [ -f "$CF_BIN" ] && [ -x "$CF_BIN" ]; then
        _info "cloudflared 已安装: $("$CF_BIN" --version 2>&1 | head -n1)"
        return 0
    fi
    local tag; tag=$(_cf_arch_tag)
    [ -z "$tag" ] && { _error "不支持的架构: $(uname -m)"; return 1; }
    local url="$CF_DL_BASE/cloudflared-linux-${tag}"
    _info "下载 cloudflared <- $url"
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

_extract_token() {
    local input="$1" token=""
    local arr=()
    read -ra arr <<< "$input"
    local i grab=0
    for ((i=0; i<${#arr[@]}; i++)); do
        local w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then
            case "$w" in ''|'"'|"'"|--no-update-service) continue ;; esac
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
                ey????????????????????*)    token="$w"; break ;;
                \"ey????????????????????*)  token="${w#\"}"; break ;;
                \'ey????????????????????*)  token="${w#\'}"; break ;;
            esac
        done
    fi
    token="${token%\"}"; token="${token%\'}"
    token="${token#\"}"; token="${token#\'}"
    [ -n "$token" ] && echo "$token"
}

# Token 须是标准 Base64 JSON object；与官方 ParseToken 一致，避免把 shell 内容写进 init.d。
_cf_token_valid() {
    local token="${1:-}" decoded
    [[ "$token" == ey* ]] || return 1
    [[ "$token" =~ ^ey[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    (( ${#token} % 4 == 0 )) || return 1
    command -v jq >/dev/null 2>&1 || return 1
    decoded=$(printf '%s' "$token" | jq -Rr '@base64d' 2>/dev/null) || return 1
    [ -n "$decoded" ] || return 1
    printf '%s' "$decoded" | jq -e 'type == "object"' >/dev/null 2>&1
}

# 只解析生效启动行；注释和停止指令不是运行事实。
_read_cf_state() {
    CF_CUR_TOKEN=""; CF_CUR_TOKEN_FILE=""; CF_CUR_AUTOUPDATE="off"; CF_CUR_HTTP2="off"; CF_CUR_EDGE_IP="off"; CF_CUR_RAWLINE=""; CF_CUR_CMDLINE=""
    CF_CUR_AUTOUPDATE_FLAG="no"
    local svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *)       svcfile="$CF_UNIT_SYSTEMD" ;;
    esac
    [ -f "$svcfile" ] || return 1
    local lines="" ln
    while IFS= read -r ln || [ -n "$ln" ]; do
        if _cf_is_cmd_line "$ln"; then
            if [ -n "$lines" ]; then
                lines="$lines
$ln"
            else
                lines="$ln"
            fi
        fi
    done < "$svcfile"
    CF_CUR_CMDLINE="$lines"
    CF_CUR_RAWLINE=$(cat "$svcfile" 2>/dev/null)
    local oneline
    oneline=$(printf '%s' "$lines" | tr '\n' ' ')
    CF_CUR_TOKEN_FILE=$(_cf_extract_token_file "$oneline") || CF_CUR_TOKEN_FILE=""
    if [ -n "$CF_CUR_TOKEN_FILE" ]; then
        CF_CUR_TOKEN=$(cat "$CF_CUR_TOKEN_FILE" 2>/dev/null) || CF_CUR_TOKEN=""
    else
        CF_CUR_TOKEN=$(_cf_extract_line_token "$oneline")
    fi
    echo "$oneline" | grep -q -- '--no-autoupdate'      && CF_CUR_AUTOUPDATE="off" && CF_CUR_AUTOUPDATE_FLAG="yes"
    echo "$oneline" | grep -q -- '--autoupdate-freq'   && CF_CUR_AUTOUPDATE="on"  && CF_CUR_AUTOUPDATE_FLAG="yes"
    echo "$oneline" | grep -q -- '--protocol http2'    && CF_CUR_HTTP2="on"
    if   echo "$oneline" | grep -q -- '--edge-ip-version 4';    then CF_CUR_EDGE_IP="4";
    elif echo "$oneline" | grep -q -- '--edge-ip-version 6';    then CF_CUR_EDGE_IP="6";
    elif echo "$oneline" | grep -q -- '--edge-ip-version auto'; then CF_CUR_EDGE_IP="auto";
    fi
}

# 官方 linux_service.go 使用独立更新 timer；状态与开关必须同时覆盖它和进程标志。
_cf_update_timer_present() {
    [ "$INIT_SYSTEM" = systemd ] || return 1
    local load
    load=$(systemctl show -p LoadState --value cloudflared-update.timer 2>/dev/null) || return 1
    [ "$load" = loaded ]
}

_cf_update_timer_on() {
    _cf_update_timer_present || return 1
    systemctl is-enabled --quiet cloudflared-update.timer 2>/dev/null \
        || systemctl is-active --quiet cloudflared-update.timer 2>/dev/null
}

_cf_update_timer_set() {
    local val="$1"
    _cf_update_timer_present || return 0
    if [ "$val" = on ]; then
        systemctl enable --now cloudflared-update.timer 2>/dev/null
    else
        systemctl disable --now cloudflared-update.timer 2>/dev/null || return 1
        systemctl stop cloudflared-update.service 2>/dev/null || return 1
    fi
}

_cf_update_timer_snapshot() {
    CF_TIMER_WAS_ENABLED=""; CF_TIMER_WAS_ACTIVE=""
    _cf_update_timer_present || return 0
    CF_TIMER_WAS_ENABLED=off; CF_TIMER_WAS_ACTIVE=off
    systemctl is-enabled --quiet cloudflared-update.timer 2>/dev/null && CF_TIMER_WAS_ENABLED=on
    systemctl is-active --quiet cloudflared-update.timer 2>/dev/null && CF_TIMER_WAS_ACTIVE=on
    return 0
}

_cf_update_timer_restore() {
    [ -n "${CF_TIMER_WAS_ENABLED:-}" ] || return 0
    if [ "$CF_TIMER_WAS_ENABLED" = on ]; then systemctl enable cloudflared-update.timer 2>/dev/null || return 1;
    else systemctl disable cloudflared-update.timer 2>/dev/null || return 1; fi
    if [ "$CF_TIMER_WAS_ACTIVE" = on ]; then systemctl start cloudflared-update.timer 2>/dev/null || return 1;
    else systemctl stop cloudflared-update.timer 2>/dev/null || return 1; fi
}

# 仅支持官方的简单绝对路径；不解释 shell 展开或 Environment 令牌。
_cf_extract_token_file() {
    local line="$1" w next=no path="" words=()
    read -ra words <<< "$line"
    for w in "${words[@]}"; do
        w=$(_cf_strip_quotes "$w")
        if [ "$next" = yes ]; then path="$w"; break; fi
        case "$w" in
            --token-file) next=yes ;;
            --token-file=*) path="${w#--token-file=}"; break ;;
        esac
    done
    [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    printf '%s' "$path"
}

_cf_token_backup_clear() {
    if [ -n "${CF_TOKEN_BACKUP_PATH:-}" ]; then
        rm -f "$CF_TOKEN_BACKUP_PATH.bak"
        CF_TOKEN_BACKUP_PATH=""
    fi
}

_cf_autoupdate_effective() {
    if _cf_update_timer_on; then
        echo "on"
    elif [ "${CF_CUR_AUTOUPDATE_FLAG:-no}" = "no" ]; then
        echo "on"
    else
        echo "${CF_CUR_AUTOUPDATE:-off}"
    fi
}

_cf_mask_token() {
    local t="$1"
    if [ "${#t}" -lt 20 ]; then
        printf '%s' '****(过短, 已隐藏)'
    else
        printf '%s...%s' "${t:0:12}" "${t: -4}"
    fi
}

_cf_redact_service_line() {
    local line="$1" token masked lower remaining
    if _cf_is_cmd_line "$line"; then
        token=$(_cf_extract_line_token "$line")
        if [ -n "$token" ]; then
            masked=$(_cf_mask_token "$token")
            remaining="${line//"$token"/}"
            remaining="${remaining/--token/}"
            lower="${remaining,,}"
            case "$lower" in
                *token*|*ey????????????????????*) printf '[敏感配置行已隐藏]\n'; return 0 ;;
            esac
            printf '%s\n' "${line//"$token"/$masked}"
            return 0
        fi
    fi
    lower="${line,,}"
    case "$lower" in
        *token*|*ey????????????????????*) printf '[敏感配置行已隐藏]\n' ;;
        *) printf '%s\n' "$line" ;;
    esac
}

# 连接选项在 run 前、凭据在最后；避免官方 CLI 忽略 token 后的参数。
_cf_build_cmdline() {
    local token="$1"
    _cf_token_valid "$token" || { _error "拒绝把非法 Token 写入 service 命令行"; return 1; }
    local cmd="$CF_BIN"
    if [ "$CF_AUTOUPDATE" = "on" ]; then
        cmd="$cmd --autoupdate-freq 24h0m0s"
    elif [ "${CF_AUTOUPDATE_FLAG:-yes}" = "yes" ]; then
        cmd="$cmd --no-autoupdate"
    fi
    cmd="$cmd tunnel"
    [ "$CF_HTTP2" = "on" ] && cmd="$cmd --protocol http2"
    case "$CF_EDGE_IP" in
        4)    cmd="$cmd --edge-ip-version 4" ;;
        6)    cmd="$cmd --edge-ip-version 6" ;;
        auto) cmd="$cmd --edge-ip-version auto" ;;
    esac
    if [ -n "${CF_CUR_TOKEN_FILE:-}" ]; then
        cmd="$cmd run --token-file $CF_CUR_TOKEN_FILE"
    else
        cmd="$cmd run --token $token"
    fi
    echo "$cmd"
}

_svc_replace_line() {
    local svcfile="$1" pattern="$2" newline="$3" tmp found=0
    [ -f "$svcfile" ] || return 1
    _svc_backup "$svcfile" || return 1
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
        rm -f "$tmp" "$svcfile.bak"
        return 1
    fi
    if [ "$write_ok" -ne 1 ]; then
        _error "临时 service 文件写入失败(磁盘空间/IO?), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    _svc_commit "$svcfile" "$tmp"
}

# 备份必须成功且限为 600；失败时不能失去含凭据的恢复源。
_svc_backup() {
    local svcfile="$1" backup="${1}.bak"
    if [ -e "$backup" ] && ! chmod 600 "$backup" 2>/dev/null; then
        _error "无法收紧既有 service 备份权限, 未修改 service: $backup"
        return 1
    fi
    ( umask 077; cp -f "$svcfile" "$backup" ) 2>/dev/null || {
        _error "service 备份失败: $svcfile"
        return 1
    }
    if ! chmod 600 "$backup" 2>/dev/null; then
        rm -f "$backup" 2>/dev/null
        _error "service 备份权限收紧失败, 未修改 service: $backup"
        return 1
    fi
    return 0
}

# cat 写回以保留 init.d 执行位；失败保留 .bak 供恢复。
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
    case "$svcfile" in
        /etc/init.d/*)
            if ! chmod 700 "$svcfile" 2>/dev/null; then
                _error "service 执行权限设置失败: $svcfile, 回滚 service 文件"
                _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
                return 1
            fi
            ;;
        *)
            chmod 600 "$svcfile" 2>/dev/null || \
                _warn "service 文件权限收紧失败(token 可能被其他用户读取): $svcfile"
            ;;
    esac
    return 0
}

# 恢复成功才消费 .bak；失败必须留下人工修复入口。
_svc_restore() {
    local svcfile="$1"
    [ -f "${svcfile}.bak" ] || { _warn "无 ${svcfile}.bak 可回滚"; return 1; }
    if ! cat "${svcfile}.bak" > "$svcfile"; then
        _error "service 回滚失败: $svcfile, 请手动检查"
        return 1
    fi
    case "$svcfile" in
        /etc/init.d/*)
            if ! chmod 700 "$svcfile" 2>/dev/null; then
                _error "service 回滚后执行权限设置失败: $svcfile"
                return 1
            fi
            ;;
        *)
            chmod 600 "$svcfile" 2>/dev/null || \
                _warn "service 文件权限收紧失败(token 可能被其他用户读取): $svcfile"
            ;;
    esac
    rm -f "${svcfile}.bak"
    return 0
}

_cf_write_service_line() {
    local cmd="$1" svcfile
    local token token_file; token_file=$(_cf_extract_token_file "$cmd") || token_file=""
    if [ -n "$token_file" ]; then token=$(cat "$token_file" 2>/dev/null) || token="";
    else token=$(_cf_extract_line_token "$cmd"); fi
    _cf_token_valid "$token" || { _error "拒绝写入不安全的 cloudflared Token"; return 1; }
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

_cf_is_cmd_line() {
    local t="${1#"${1%%[![:space:]]*}"}"
    case "$t" in
        '#'*|'') return 1 ;;   # 注释与空行绝不修改
    esac
    case "$t" in
        ExecStartPre=*|ExecStartPost=*|ExecStop=*|ExecStopPost=*|ExecReload=*|ExecCondition=*) return 1 ;;
    esac
    case "$t" in
        ExecStart=*|command_args=*|cmd=*|command=*) return 0 ;;
    esac
    case "$t" in
        *"$CF_BIN"*) return 0 ;;
    esac
    return 1
}

_cf_extract_line_token() {
    local ln="$1" arr=() i w grab=0 tok=""
    read -ra arr <<< "$ln"
    for ((i=0; i<${#arr[@]}; i++)); do
        w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then tok="$w"; break; fi
        case "$w" in
            --token)   grab=1 ;;
            --token=*) tok="${w#--token=}"; break ;;
        esac
    done
    if [ -z "$tok" ]; then
        for w in "${arr[@]}"; do
            case "$w" in ey????????????????????*) tok="$w"; break ;; esac
        done
    fi
    tok="${tok%\"}"; tok="${tok%\'}"
    tok="${tok#\"}"; tok="${tok#\'}"
    printf '%s' "$tok"
}

_cf_replace_token_in_service() {
    local oldtok="$1" newtok="$2" svcfile
    _cf_token_valid "$newtok" || { _error "拒绝写入不安全的 cloudflared Token"; return 1; }
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *) return 1 ;;
    esac
    [ -f "$svcfile" ] || return 1
    CF_TOKEN_BACKUP_PATH=""
    local token_file="" ln
    while IFS= read -r ln || [ -n "$ln" ]; do
        _cf_is_cmd_line "$ln" || continue
        token_file=$(_cf_extract_token_file "$ln") && break
    done < "$svcfile"
    if [ -n "$token_file" ]; then
        _svc_backup "$svcfile" || return 1
        _svc_backup "$token_file" || return 1
        CF_TOKEN_BACKUP_PATH="$token_file"
        if ! printf '%s' "$newtok" > "$token_file" || ! chmod 600 "$token_file" \
            || [ "$(cat "$token_file" 2>/dev/null)" != "$newtok" ]; then
            _svc_restore "$token_file" || _error "token 文件恢复失败: $token_file"
            CF_TOKEN_BACKUP_PATH=""
            return 1
        fi
        return 0
    fi
    _svc_backup "$svcfile" || return 1
    local tmp write_ok=1 replaced=0 ln found
    tmp=$(mktemp) || { _error "无法创建临时 service 文件: $svcfile"; return 1; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        if _cf_is_cmd_line "$ln"; then
            found=$(_cf_extract_line_token "$ln")
            if [ -n "$found" ]; then
                printf '%s\n' "${ln//"$found"/$newtok}" >> "$tmp" || write_ok=0
                replaced=$((replaced+1))
                continue
            fi
        fi
        printf '%s\n' "$ln" >> "$tmp" || write_ok=0
    done < "$svcfile"
    if [ "$write_ok" -ne 1 ]; then
        _error "临时 service 文件写入失败(磁盘空间/IO?), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    if [ "$replaced" -lt 1 ]; then
        rm -f "$tmp" "${svcfile}.bak"
        _error "未在 $svcfile 的启动命令行中找到可替换的令牌, 令牌未更新"
        _tip "该 service 可能以其他形式提供 token(Environment=TUNNEL_TOKEN=),"
        _tip "本脚本不会改写这类形态; 请手动编辑 $svcfile 后重启 cloudflared"
        return 1
    fi
    [ -n "$oldtok" ] && [ "$replaced" -gt 1 ] && \
        _warn "在 $replaced 行启动命令中替换了令牌, 请确认该 service 是否本就有多条启动行"
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

_cf_pids() {
    local p c seen=" "
    for p in $(pidof cloudflared 2>/dev/null); do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        case "$seen" in *" $p "*) continue ;; esac
        seen="$seen$p "
        printf '%s\n' "$p"
    done
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        case "$seen" in *" $p "*) continue ;; esac
        read -r c 2>/dev/null < "/proc/$p/comm" || continue
        [ "$c" = "cloudflared" ] || continue
        seen="$seen$p "
        printf '%s\n' "$p"
    done
}

_cf_unit_path() {
    case "$INIT_SYSTEM" in
        openrc) printf '%s' "$CF_UNIT_OPENRC" ;;
        *)      printf '%s' "$CF_UNIT_SYSTEMD" ;;
    esac
}

_cf_opt_takes_value() { # <包装器名> <token> ; 0 = 该 token 的取值是下一个词
    local w="$1" t="$2" tbl=""
    case "$w" in
        env)     tbl='-C --chdir -f --file -u --unset -S --split-string -a --argv0' ;;
        nice)    tbl='-n --adjustment' ;;
        ionice)  tbl='-c --class -n --classdata -p --pid -P --pgid -u --uid' ;;
        setpriv) tbl='--ambient-caps --inh-caps --bounding-set --ruid --euid --rgid --egid --reuid --regid --groups --securebits --pdeathsig --ptracer --selinux-label --apparmor-profile --landlock-access --landlock-rule --seccomp-filter' ;;
        timeout) tbl='-k --kill-after -s --signal' ;;
        chrt)    tbl='-T --sched-runtime -P --sched-period -D --sched-deadline' ;;
        stdbuf)  tbl='-i --input -o --output -e --error' ;;
        exec)    tbl='-a' ;;
        *)       return 1 ;;
    esac
    case " $tbl " in
        *" $t "*) return 0 ;;
    esac
    return 1
}

_cf_opt_seen_takes_value() { # <已见包装器串> <token>
    local w
    for w in $1; do
        _cf_opt_takes_value "$w" "$2" && return 0
    done
    return 1
}

_cf_wrap_pos_count() { # <包装器名> -> 该包装器在真命令前有几个"前置位置参数"
    case "$1" in
        timeout|chrt|taskset) printf '%s' 1 ;;   # DURATION / PRIORITY / MASK
        *)                    printf '%s' 0 ;;
    esac
}

# 包装器取值按已见选项表跳过，命令串用数组切片；不把包装器当归属二进制。
_cf_first_bin_word() {
    local text="$1" depth="${2:-0}" tok inner
    local -a _w
    read -ra _w <<< "$text"
    local _i _next _wrap="" _seen="" _wantarg=0 _pos=0
    for ((_i=0; _i<${#_w[@]}; _i++)); do
        tok="${_w[$_i]}"
        tok="${tok#\"}"; tok="${tok%\"}"
        tok="${tok#\'}"; tok="${tok%\'}"
        [ -n "$tok" ] || continue
        if [ "$_wantarg" -eq 1 ]; then _wantarg=0; continue; fi
        case "${tok##*/}" in
            env|nice|ionice|setpriv|timeout|chrt|taskset|busybox|nohup|setsid|stdbuf|exec)
                _wrap="${tok##*/}"
                _seen="$_seen $_wrap"
                _pos=$(_cf_wrap_pos_count "$_wrap")
                continue ;;
            sh|bash|dash|ash|ksh|zsh)
                _next="${_w[$((_i+1))]:-}"
                if [ "$depth" -lt 2 ] && [ "$_next" = "-c" ] && [ -n "${_w[$((_i+2))]:-}" ]; then
                    inner="${_w[*]:$((_i+2))}"
                    _cf_first_bin_word "$inner" $((depth+1))
                    return $?
                fi
                printf '%s' "$tok"; return 0 ;;
        esac
        if [ -n "$_seen" ] && [ "${tok#-}" != "$tok" ] && _cf_opt_seen_takes_value "$_seen" "$tok"; then
            case "${tok##*/}" in
                -S|--split-string)
                    if [ "$depth" -lt 2 ] && [ -n "${_w[$((_i+1))]:-}" ]; then
                        inner="${_w[*]:$((_i+1))}"
                        _cf_first_bin_word "$inner" $((depth+1))
                        return $?
                    fi ;;
            esac
            _wantarg=1
            continue
        fi
        case "$tok" in
            -*) continue ;;
        esac
        if [ "$_pos" -gt 0 ]; then _pos=$((_pos-1)); continue; fi
        case "$tok" in
            [A-Za-z_]*=*) continue ;;   # NAME=value => 环境赋值
            *[!0-9]*) printf '%s' "$tok"; return 0 ;;   # 含非数字 => 这就是二进制
            *) continue ;;                              # 纯数字 => 包装器的参数
        esac
    done
    return 1
}

_cf_service_bin() {
    local svcfile="$1" ln t bin
    [ -f "$svcfile" ] || { printf '%s' "$CF_BIN"; return 0; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        t="${ln#"${ln%%[![:space:]]*}"}"
        case "$t" in
            ExecStart=*|cmd=*|command=*)
                t="${t#*=}"
                bin=$(_cf_first_bin_word "$t") || bin=""
                if [ -n "$bin" ]; then
                    case "$bin" in
                        /*) printf '%s' "$bin" ;;
                        *)  printf '%s' "$(command -v -- "$bin" 2>/dev/null || printf '%s' "$CF_BIN")" ;;
                    esac
                    return 0
                fi
                ;;
        esac
    done < "$svcfile"
    printf '%s' "$CF_BIN"
}

_cf_pids_owned() {
    local want p
    want=$(_cf_service_bin "$(_cf_unit_path)")
    [ -n "$want" ] || want="$CF_BIN"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        _cf_exe_owned "$p" "$want" && printf '%s\n' "$p"
    done <<< "$(_cf_pids)"
}

# 归属返回 0=本服务、1=他人、2=未知；杀路径不得继承判活的 fail-open。
_cf_exe_owned() {
    if declare -F _proc_exe_is_strict >/dev/null 2>&1; then
        _proc_exe_is_strict "$1" "$2"
        return $?
    fi
    _warn "lib 版本过旧(00-common 缺 _proc_exe_is_strict), 无法确认进程归属, 跳过"
    return 2
}

_cf_strip_quotes() {
    local w="$1"
    while :; do
        case "$w" in \"*|\'*) w="${w#?}" ;; *) break ;; esac
    done
    while :; do
        case "$w" in *\"|*\') w="${w%?}" ;; *) break ;; esac
    done
    printf '%s' "$w"
}

_cf_ltrim() {
    local s="$1"
    printf '%s' "${s#"${s%%[![:space:]]*}"}"
}

_cf_env_file_value() {
    local f="$1" ln v out=""
    [ -f "$f" ] || return 1
    while IFS= read -r ln || [ -n "$ln" ]; do
        ln=$(_cf_ltrim "$ln")
        case "$ln" in '#'*|';'*|'') continue ;; esac
        v="${ln#*TUNNEL_GRACE_PERIOD=}"
        [ "$v" != "$ln" ] || continue
        v="${v%%[[:space:]]*}"
        v=$(_cf_strip_quotes "$v")
        [ -n "$v" ] && out="$v"
    done < "$f"
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    return 1
}

_cf_systemd_grace_raw() {
    local load argv envs efs w v="" efp vf arr=() i
    load=$(systemctl show -p LoadState --value cloudflared 2>/dev/null) || return 2
    [ "$load" = loaded ] || return 2
    argv=$(systemctl show -p ExecStart --value cloudflared 2>/dev/null) || return 2
    case "$argv" in
        *'argv[]='*) argv="${argv#*argv[]=}" ;;
        *) argv="" ;;
    esac
    argv="${argv%%; ignore_errors=*}"
    if [ -n "$argv" ]; then
        arr=(); read -ra arr <<< "$argv"
        for ((i=0; i<${#arr[@]}; i++)); do
            w="${arr[$i]}"
            case "$w" in
                --grace-period=*) v="${w#--grace-period=}" ;;
                --grace-period) [ "$((i+1))" -lt "${#arr[@]}" ] && v="${arr[$((i+1))]}" ;;
            esac
        done
    fi
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    efs=$(systemctl show -p EnvironmentFiles --value cloudflared 2>/dev/null) || efs=""
    while IFS= read -r efp || [ -n "$efp" ]; do
        [ -n "$efp" ] || continue
        efp="${efp% (ignore_errors=*)}"
        case "$efp" in ''|*'*'*|*'?'*|*'['*) continue ;; esac
        if vf=$(_cf_env_file_value "$efp"); then v="$vf"; fi
    done <<< "$efs"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    envs=$(systemctl show -p Environment --value cloudflared 2>/dev/null) || envs=""
    for w in $envs; do
        case "$w" in TUNNEL_GRACE_PERIOD=*) v="${w#TUNNEL_GRACE_PERIOD=}" ;; esac
    done
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# systemd 有效配置优先，读不到才退回文本；宽限期不能按主 unit 猜测。
_cf_grace_config() {
    local svcfile="$1" ln arr=() i w v efpath efv eff rc
    if [ "${INIT_SYSTEM:-}" = systemd ]; then
        eff=$(_cf_systemd_grace_raw); rc=$?
        case "$rc" in
            0) printf '%s' "$eff"; return 0 ;;
            1) return 1 ;;   # systemd 是权威: 它说没配就是没配, 不再回退文本
        esac
    fi
    [ -f "$svcfile" ] || return 1
    while IFS= read -r ln || [ -n "$ln" ]; do
        _cf_is_cmd_line "$ln" || continue
        ln=$(_cf_ltrim "$ln")
        case "$ln" in
            ExecStart=*|command_args=*|cmd=*|command=*) ln="${ln#*=}" ;;
        esac
        arr=(); read -ra arr <<< "$ln"
        for ((i=0; i<${#arr[@]}; i++)); do
            w=$(_cf_strip_quotes "${arr[$i]}")
            case "$w" in
                --grace-period=*) _cf_strip_quotes "${w#--grace-period=}"; return 0 ;;
                --grace-period)
                    if [ "$((i+1))" -lt "${#arr[@]}" ]; then
                        v=$(_cf_strip_quotes "${arr[$((i+1))]}")
                        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
                    fi ;;
            esac
        done
    done < "$svcfile"
    while IFS= read -r ln || [ -n "$ln" ]; do
        ln=$(_cf_ltrim "$ln")
        case "$ln" in '#'*|'') continue ;; esac
        v="${ln#*TUNNEL_GRACE_PERIOD=}"
        [ "$v" != "$ln" ] || continue
        v="${v%%[[:space:]]*}"      # 值到引号/空白为止
        v=$(_cf_strip_quotes "$v")
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done < "$svcfile"
    while IFS= read -r ln || [ -n "$ln" ]; do
        ln=$(_cf_ltrim "$ln")
        case "$ln" in '#'*|'') continue ;; esac
        case "$ln" in EnvironmentFile=*) efpath="${ln#EnvironmentFile=}" ;; *) continue ;; esac
        efpath=$(_cf_strip_quotes "$efpath")
        efpath=$(_cf_ltrim "$efpath")
        efpath="${efpath%"${efpath##*[![:space:]]}"}"
        case "$efpath" in -*) efpath="${efpath#-}" ;; esac
        case "$efpath" in ''|*'*'*|*'?'*|*'['*) continue ;; esac
        if vf=$(_cf_env_file_value "$efpath"); then printf '%s' "$vf"; return 0; fi
    done < "$svcfile"
    return 1
}

# Go duration 按纳秒累加并向上取整；亚秒宽限期不能被当成零。
_cf_duration_seconds() {
    local rest="$1" total_ns=0 int frac unit ns=0 scale div nonzero=0
    [ -n "$rest" ] || return 1
    case "$rest" in 0) printf '0'; return 0 ;; esac
    while [ -n "$rest" ]; do
        [[ "$rest" =~ ^([0-9]+)(\.([0-9]+))?(ns|us|µs|ms|s|m|h)(.*)$ ]] || return 1
        int="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]}"
        unit="${BASH_REMATCH[4]}"; rest="${BASH_REMATCH[5]}"
        [ "${#int}" -le 6 ] || return 1
        case "$unit" in
            ns)    ns=1 ;;
            us|µs) ns=1000 ;;
            ms)    ns=1000000 ;;
            s)     ns=1000000000 ;;
            m)     ns=60000000000 ;;
            h)     ns=3600000000000 ;;
        esac
        case "$int" in *[!0]*) nonzero=1 ;; esac
        total_ns=$(( total_ns + 10#$int * ns ))
        if [ -n "$frac" ]; then
            case "$frac" in *[!0]*) nonzero=1 ;; esac
            scale="${#frac}"
            [ "$scale" -gt 9 ] && { frac="${frac:0:9}"; scale=9; }
            case "$scale" in
                1) div=10 ;; 2) div=100 ;; 3) div=1000 ;; 4) div=10000 ;;
                5) div=100000 ;; 6) div=1000000 ;; 7) div=10000000 ;;
                8) div=100000000 ;; *) div=1000000000 ;;
            esac
            total_ns=$(( total_ns + 10#$frac * ns / div ))
        fi
    done
    [ "$total_ns" -lt 0 ] && return 1
    [ "$total_ns" -eq 0 ] && [ "$nonzero" -eq 1 ] && total_ns=1
    printf '%s' "$(( (total_ns + 999999999) / 1000000000 ))"
}

_cf_grace_wait_seconds() {
    local raw secs
    raw=$(_cf_grace_config "$(_cf_unit_path)") || raw=""
    if [ -n "$raw" ]; then
        if ! secs=$(_cf_duration_seconds "$raw"); then
            _warn "无法解析 service 中的宽限期 '$raw', 按官方默认 ${CF_GRACE_DEFAULT}s 处理"
            secs="$CF_GRACE_DEFAULT"
        fi
    else
        secs="$CF_GRACE_DEFAULT"
    fi
    [ "$secs" -gt "$CF_GRACE_MAX" ] && secs="$CF_GRACE_MAX"
    printf '%s' "$(( secs + CF_GRACE_MARGIN ))"
}

_cf_systemd_span_seconds() {
    local span="$1" tok int frac unit scale div mult total_us=0 nonzero=0
    [ -n "$span" ] || return 1
    for tok in $span; do
        [[ "$tok" =~ ^([0-9]+)(\.([0-9]+))?(us|ms|s|min|h|d|w|month|y)$ ]] || return 1
        int="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]}"; unit="${BASH_REMATCH[4]}"
        [ "${#int}" -le 9 ] || return 1
        case "$unit" in
            us)    mult=1 ;;
            ms)    mult=1000 ;;
            s)     mult=1000000 ;;
            min)   mult=60000000 ;;
            h)     mult=3600000000 ;;
            d)     mult=86400000000 ;;
            w)     mult=604800000000 ;;
            month) mult=2629800000000 ;;
            y)     mult=31557600000000 ;;
        esac
        case "$int" in *[!0]*) nonzero=1 ;; esac
        total_us=$(( total_us + 10#$int * mult ))
        if [ -n "$frac" ]; then
            case "$frac" in *[!0]*) nonzero=1 ;; esac
            scale="${#frac}"
            [ "$scale" -gt 6 ] && { frac="${frac:0:6}"; scale=6; }
            case "$scale" in
                1) div=10 ;; 2) div=100 ;; 3) div=1000 ;;
                4) div=10000 ;; 5) div=100000 ;; *) div=1000000 ;;
            esac
            total_us=$(( total_us + 10#$frac * mult / div ))
        fi
    done
    [ "$total_us" -lt 0 ] && return 1
    [ "$total_us" -eq 0 ] && [ "$nonzero" -eq 1 ] && total_us=1
    printf '%s' "$(( (total_us + 999999) / 1000000 ))"
}

_cf_systemd_stop_timeout_seconds() {
    local span
    span=$(systemctl show -p TimeoutStopUSec --value cloudflared 2>/dev/null) || return 2
    [ -n "$span" ] || return 2
    _cf_systemd_span_seconds "$span" || return 1
}

_cf_check_stop_timeout_covers() {
    local want="$1" have st_rc=0
    [ "${INIT_SYSTEM:-}" = systemd ] || return 0
    _cf_unit_stopped || st_rc=$?
    if [ "$st_rc" -eq 0 ] && [ -z "$(_cf_pids_owned)" ]; then
        return 0
    fi
    have=$(_cf_systemd_stop_timeout_seconds) || return 0
    [ "$have" -ge "$want" ] && return 0
    _warn "systemd 的停止超时(${have}s)短于宽限期 + 余量(${want}s), cloudflared 可能在其宽限期走完前就被 systemd 终止"
    _tip "如需完整等待宽限期, 请提高 unit 的 TimeoutStopSec(当前生效值 ${have}s)"
    _tip "可用 systemctl edit cloudflared 添加 [Service] TimeoutStopSec=<秒数> 后重试"
    return 1
}

# 仅 inactive/failed 且 MainPID=0 算停止；deactivating 和读取失败不是终态。
_cf_unit_stopped() {
    local active mainpid
    active=$(systemctl show -p ActiveState --value cloudflared 2>/dev/null) || return 2
    [ -n "$active" ] || return 2
    case "$active" in
        inactive|failed) ;;
        *) return 1 ;;
    esac
    mainpid=$(systemctl show -p MainPID --value cloudflared 2>/dev/null) || return 2
    [ "$mainpid" = "0" ] || return 1
    return 0
}

# 进程与 unit 都退出才成功；0=停止、1=超时、2=无法观察。
_cf_wait_exit() {
    local max="$1" i=0 rc
    while [ "$i" -lt "$max" ]; do
        if [ -z "$(_cf_pids_owned)" ]; then
            if [ "$INIT_SYSTEM" != systemd ]; then return 0; fi
            _cf_unit_stopped; rc=$?
            case "$rc" in
                0) return 0 ;;   # inactive/failed 且 MainPID=0
                1) ;;            # 过渡态: 继续等
                *) return 2 ;;   # 读不到状态: 不下"已停止"的结论
            esac
        fi
        sleep 1; i=$((i+1))
    done
    return 1
}

# stop → TERM → 实际宽限期 → KILL → 再 stop 复验；未知归属或终态必须失败。
_cf_kill_all() {
    local pids="" pid i rc
    local _cf_strict_missing=0
    local _cf_unit_unreadable=0
    local _cf_grace=""

    case "$INIT_SYSTEM" in
        systemd)
            _cf_grace=$(_cf_grace_wait_seconds)
            _cf_check_stop_timeout_covers "$_cf_grace" || true
            systemctl --no-block stop cloudflared 2>/dev/null || true
            _cf_wait_exit "$_cf_grace"; rc=$?
            case "$rc" in
                0) ;;
                2) _cf_unit_unreadable=1
                   _warn "无法读取 systemd 中 cloudflared 的状态, 本次停止将不宣称已进入停止终态" ;;
                *) _warn "cloudflared 在 ${_cf_grace}s 内未进入停止终态, 转为按进程归属强制清理" ;;
            esac
            ;;
        openrc)
            rc-service cloudflared stop 2>/dev/null || true
            ;;
    esac

    local _cf_pf_want
    _cf_pf_want=$(_cf_service_bin "$(_cf_unit_path)")
    [ -n "$_cf_pf_want" ] || _cf_pf_want="$CF_BIN"
    for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
        local _pf_pid; _pf_pid=$(cat "$pf" 2>/dev/null)
        case "$_pf_pid" in
            ''|*[!0-9]*) ;;   # 空/非数字: 不是有效 PID, 只删文件
            *)
                if [ "$(cat "/proc/$_pf_pid/comm" 2>/dev/null)" = "cloudflared" ]; then
                    local _cf_own_rc=0
                    _cf_exe_owned "$_pf_pid" "$_cf_pf_want" || _cf_own_rc=$?
                    case "$_cf_own_rc" in
                        0) kill "$_pf_pid" 2>/dev/null || true ;;
                        2) _cf_strict_missing=1
                           _warn "pidfile 记录的 PID $_pf_pid 归属无法确认(lib 版本过旧), 未发送信号"
                           _tip "请重跑 install.sh --update 同步模块后重试" ;;
                        *) _warn "pidfile 记录的 PID $_pf_pid 同名但归属无法确认(非本脚本的 cloudflared?), 未发送信号"
                           _tip "若该进程确实属于本服务, 请手动检查后处理" ;;
                    esac
                fi ;;
        esac
        rm -f "$pf" 2>/dev/null
    done

    pids=$(_cf_pids_owned)
    if [ -n "$pids" ]; then
        [ -n "$_cf_grace" ] || _cf_grace=$(_cf_grace_wait_seconds)
        for pid in $pids; do kill -15 "$pid" 2>/dev/null || true; done
        _cf_wait_exit "$_cf_grace"; rc=$?
        if [ "$rc" -eq 2 ]; then
            _cf_unit_unreadable=1
            _warn "无法读取 systemd 中 cloudflared 的状态, 无法确认其已进入停止终态"
        elif [ "$rc" -eq 1 ]; then
            _warn "cloudflared 残留进程在 ${_cf_grace}s 内未退出, 发送 SIGKILL"
            pids=$(_cf_pids_owned)
            for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
            i=0
            while [ "$i" -lt 5 ]; do
                [ -z "$(_cf_pids_owned)" ] && break
                sleep 1; i=$((i+1))
            done
            if [ "$INIT_SYSTEM" = systemd ]; then
                systemctl --no-block stop cloudflared 2>/dev/null || true
                _cf_wait_exit "$CF_STOP_REVERIFY"; rc=$?
                [ "$rc" -eq 0 ] \
                    || _warn "SIGKILL 后 systemd 未在 ${CF_STOP_REVERIFY}s 内进入停止终态"
                [ "$rc" -eq 2 ] && _cf_unit_unreadable=1
            fi
        fi
    fi

    pids=$(_cf_pids_owned)
    if [ -n "$pids" ]; then
        _warn "cloudflared 仍有残留进程: $pids"
        _tip "若隧道行为异常, 请手动确认这些进程是否应当存在"
        return 1
    fi
    declare -F _proc_exe_is_strict >/dev/null 2>&1 || _cf_strict_missing=1
    local p others="" unclear="" _cf_want
    _cf_want=$(_cf_service_bin "$(_cf_unit_path)")
    [ -n "$_cf_want" ] || _cf_want="$CF_BIN"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! readlink "/proc/$p/exe" >/dev/null 2>&1; then
            [ -d "/proc/$p" ] || continue
            unclear="$unclear $p"          # live PID 且 exe 读不到 => 归属无法确认
            continue
        fi
        local _cf_own_rc=0
        _cf_exe_owned "$p" "$_cf_want" || _cf_own_rc=$?
        case "$_cf_own_rc" in
            0) continue ;;                  # 确认是我们的
            2) unclear="$unclear $p"        # 归属无法确认(严格版缺失)
               _cf_strict_missing=1 ;;
            *) others="$others $p" ;;       # exe 可读但不匹配 => 确属他人
        esac
    done <<< "$(_cf_pids)"
    if [ -n "$others" ]; then
        _tip "检测到非本脚本管理的 cloudflared 进程:${others}(未触碰)"
    fi
    if [ -n "$unclear" ]; then
        _warn "以下 cloudflared 进程归属无法确认(exe 不可读或 lib 版本过旧):${unclear}"
        _tip "它们可能仍属于本服务; 若隧道行为异常, 请手动确认"
        return 1
    fi
    if [ "$_cf_strict_missing" -eq 1 ]; then
        _warn "lib 版本过旧(00-common 缺 _proc_exe_is_strict), 无法确认 cloudflared 进程归属"
        _tip "请重跑 install.sh --update 同步模块后重试"
        return 1
    fi
    if [ "$_cf_unit_unreadable" -eq 1 ]; then
        _warn "cloudflared 进程已无, 但无法读取 systemd 状态, 停止终态未获确认"
        _tip "通常是容器内无 systemd 或 systemctl 不可用; 请手动确认服务状态"
        return 1
    fi
    if [ "$INIT_SYSTEM" = systemd ]; then
        local _cf_term_rc=0
        _cf_unit_stopped || _cf_term_rc=$?
        case "$_cf_term_rc" in
            0) ;;
            2) _warn "cloudflared 进程已无, 但停止终态无法复验(systemd 状态读不到)"
               _tip "请手动确认 cloudflared service 状态"
               return 1 ;;
            *) _warn "cloudflared 进程已无, 但 systemd unit 未进入停止终态(inactive/failed 之外)"
               _tip "unit 若长期停在 deactivating, 请检查 ExecStop/ExecStopPost 与 TimeoutStopSec"
               _tip "可用 systemctl status cloudflared 查看当前 ActiveState"
               return 1 ;;
        esac
    fi
    _info "cloudflared 所有进程已清理"
    return 0
}

# 清理成功后保留 2s edge 间隔再启动；防止残留 connector 累积。
_cf_restart() {
    if ! _cf_kill_all; then
        _error "cloudflared 停止流程未完成, 为避免启动第二个实例已取消重启"
        return 1
    fi
    sleep 2   # 保留既有的 edge connector 回收窗口
    local rc=1 i
    case "$INIT_SYSTEM" in
        systemd) systemctl start cloudflared 2>/dev/null; rc=$? ;;
        openrc)  rc-service cloudflared start 2>/dev/null; rc=$? ;;
        *) return 1 ;;
    esac
    [ "$rc" -eq 0 ] || return "$rc"
    for ((i=0; i<6; i++)); do
        _cf_is_managed_running && return 0
        [ "$i" -lt 5 ] && sleep 1
    done
    return 1
}

# 凭据、service、timer 恢复后重启并验证；文件还原不等于服务恢复。
_cf_rollback_service() {
    local svcfile="$1"
    if [ -n "${CF_TOKEN_BACKUP_PATH:-}" ]; then
        _svc_restore "$CF_TOKEN_BACKUP_PATH" || return 1
        CF_TOKEN_BACKUP_PATH=""
    fi
    [ -f "${svcfile}.bak" ] || { _warn "无 ${svcfile}.bak 可回滚"; return 1; }
    if ! _svc_restore "$svcfile"; then
        _warn "回滚失败, 请手动检查 $svcfile"
        return 1
    fi
    if [ "$INIT_SYSTEM" = "systemd" ] && ! systemctl daemon-reload 2>/dev/null; then
        _error "回滚后 systemd daemon-reload 也失败: $svcfile"
        return 1
    fi
    _cf_update_timer_restore || { _error "回滚更新 timer 失败"; return 1; }
    if ! _cf_restart 2>/dev/null; then
        _error "回滚后 cloudflared 重启失败: $svcfile"
        return 1
    fi
    if ! _cf_is_managed_running; then
        _error "回滚后 cloudflared 未运行: $svcfile"
        return 1
    fi
    return 0
}

# 事务成功只认服务进程树；全机同名扫描仅用于状态显示。
_cf_is_managed_running() {
    local anchor pf
    case "$INIT_SYSTEM" in
        systemd)
            anchor=$(systemctl show -p MainPID --value cloudflared 2>/dev/null) || return 1
            [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] || return 1
            _proc_named_under "$anchor" cloudflared
            return $?
            ;;
        *)
            for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
                anchor=$(cat "$pf" 2>/dev/null) || continue
                [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] || continue
                [ -d "/proc/$anchor" ] || continue
                _proc_named_under "$anchor" cloudflared && return 0
            done
            return 1
            ;;
    esac
}
_cf_is_running() {
    local anchor=""
    case "$INIT_SYSTEM" in
        systemd)
            anchor=$(systemctl show -p MainPID --value cloudflared 2>/dev/null)
            if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ]; then
                _proc_named_under "$anchor" cloudflared && return 0
                return 1
            fi
            systemctl is-active --quiet cloudflared 2>/dev/null && _proc_any_named cloudflared
            return $?
            ;;
        *)
            local pf
            for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
                anchor=$(cat "$pf" 2>/dev/null) || continue
                if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] && [ -d "/proc/$anchor" ]; then
                    _proc_named_under "$anchor" cloudflared && return 0
                fi
            done
            _proc_any_named cloudflared
            ;;
    esac
}

_install_cloudflared() {
    _install_cloudflared_bin || return 1
    echo
    _info "请粘贴 Cloudflare Tunnel Token"
    _tip "支持直接粘贴 CF 网页端给出的任何安装命令(Windows/Debian 均可), 脚本自动提取 ey... 令牌"
    read -rp "  粘贴: " input
    local token; token=$(_extract_token "$input")
    if [ -z "$token" ]; then
        _error "未能从输入中识别 Cloudflare Tunnel Token, 不会把原文写入 service 文件"
        return 1
    fi
    _cf_token_valid "$token" || { _error "Token 格式非法(仅接受 ey 开头的标准 Base64 Tunnel Token: 解码后须为合法 JSON)"; return 1; }

    CF_AUTOUPDATE="off"; CF_HTTP2="on"; CF_EDGE_IP="off"; CF_AUTOUPDATE_FLAG="yes"

    _info "调用 cloudflared service install..."
    if ! "$CF_BIN" service install --no-update-service "$token" 2>&1; then
        _error "cloudflared service install 失败"
        return 1
    fi
    case "$INIT_SYSTEM" in
        systemd) chmod 600 "$CF_UNIT_SYSTEMD" 2>/dev/null ;;
        openrc)  chmod 700 "$CF_UNIT_OPENRC" 2>/dev/null ;;
    esac
    _read_cf_state || return 1
    _cf_update_timer_snapshot
    _cf_update_timer_set off || { _cf_update_timer_restore || _warn "更新 timer 状态还原失败"; _error "关闭更新 timer 失败, 安装中止"; return 1; }
    local cmdline
    cmdline=$(_cf_build_cmdline "$token") || { _cf_update_timer_restore || _warn "更新 timer 状态还原失败"; _error "无法构造安全的 cloudflared 启动行"; return 1; }
    if ! _cf_write_service_line "$cmdline"; then
        local ab_svc
        ab_svc=$(_cf_unit_path)
        rm -f "${ab_svc}.bak" 2>/dev/null
        _cf_update_timer_restore || _warn "更新 timer 状态还原失败"
        _error "service 配置写入失败, 安装中止"
        return 1
    fi
    if ! _cf_restart; then
        _cf_update_timer_restore || _warn "更新 timer 状态还原失败"
        _error "cloudflared 启动失败, 安装中止"
        return 1
    fi
    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    if ! _cf_is_managed_running; then
        rm -f "${svcfile}.bak" 2>/dev/null
        _cf_update_timer_restore || _warn "更新 timer 状态还原失败"
        _error "cloudflared service 已写入但启动后未运行, 安装未完成(请检查 token / 查看服务日志)"
        _tip "service 文件已保留以便修复: $svcfile"
        return 1
    fi
    rm -f "${svcfile}.bak"
    mkdir -p "$STATE_DIR"
    _state_set cf_autoupdate "$CF_AUTOUPDATE" || _warn "状态持久化失败(cf_autoupdate)"
    _state_set cf_http2 "$CF_HTTP2" || _warn "状态持久化失败(cf_http2)"
    _state_set cf_edge_ip "$CF_EDGE_IP" || _warn "状态持久化失败(cf_edge_ip)"
    _success "cloudflared 安装完成(已注册服务并开机自启)"
    _tip "已默认关闭 cloudflared 自动更新、开启 HTTP2 连接（可在 cloudflared 管理中修改）"
    _tip "隧道路由请在 Cloudflare Web 端配置, 本脚本不写 config.yml"
}

_uninstall_cloudflared() {
    local kill_rc=0
    _cf_kill_all || kill_rc=$?
    if [ "$kill_rc" -ne 0 ]; then
        _error "cloudflared 停止状态无法确认, 未卸载服务或删除凭据/二进制"
        _tip "服务定义已保留; 修复进程清理后再重试卸载"
        return 1
    fi
    local cleanup_rc=0 service_rc=0 enabled runlevels d link
    if [ -e /etc/cloudflared/token ] || [ -L /etc/cloudflared/token ]; then
        rm -f /etc/cloudflared/token || cleanup_rc=1
    fi
    [ ! -e /etc/cloudflared/token ] && [ ! -L /etc/cloudflared/token ] || cleanup_rc=1
    rmdir /etc/cloudflared 2>/dev/null || true  # Preserve any user-owned config.yml.
    if [ -x "$CF_BIN" ]; then
        _info "卸载 cloudflared..."
        "$CF_BIN" service uninstall 2>/dev/null || service_rc=$?
        [ "$service_rc" -eq 0 ] || _warn "官方 service uninstall 返回失败, 继续核对手工清理结果"
    else
        _warn "cloudflared 二进制不存在(仅清理残留配置)"
    fi
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable cloudflared 2>/dev/null || true
            rm -f "$CF_UNIT_SYSTEMD" "${CF_UNIT_SYSTEMD}.bak" || cleanup_rc=1
            [ ! -e "$CF_UNIT_SYSTEMD" ] && [ ! -L "$CF_UNIT_SYSTEMD" ] \
                && [ ! -e "${CF_UNIT_SYSTEMD}.bak" ] && [ ! -L "${CF_UNIT_SYSTEMD}.bak" ] || cleanup_rc=1
            systemctl daemon-reload 2>/dev/null || cleanup_rc=1
            local load_state
            load_state=$(systemctl show -p LoadState --value cloudflared 2>/dev/null || true)
            if [ "$load_state" = not-found ]; then
                :
            elif [ -n "$load_state" ]; then
                enabled=$(systemctl is-enabled cloudflared 2>/dev/null || true)
                case "$enabled" in
                    disabled|masked|masked-runtime|static|indirect|not-found) ;;
                    *) cleanup_rc=1 ;;
                esac
            else
                _error "无法确认 cloudflared systemd unit 是否已移除"
                cleanup_rc=1
            fi
            if command -v find >/dev/null 2>&1; then
                for d in /etc/systemd/system /run/systemd/system; do
                    [ -d "$d" ] || continue
                    link=$(find "$d" -type l -name cloudflared.service -print -quit 2>/dev/null) || { cleanup_rc=1; continue; }
                    [ -z "$link" ] || cleanup_rc=1
                done
            else
                cleanup_rc=1
            fi
            ;;
        openrc)
            rc-update del cloudflared default 2>/dev/null || true
            rm -f "$CF_UNIT_OPENRC" "${CF_UNIT_OPENRC}.bak" || cleanup_rc=1
            [ ! -e "$CF_UNIT_OPENRC" ] && [ ! -L "$CF_UNIT_OPENRC" \
                ] && [ ! -e "${CF_UNIT_OPENRC}.bak" ] && [ ! -L "${CF_UNIT_OPENRC}.bak" ] || cleanup_rc=1
            runlevels=$(rc-update show 2>/dev/null) || cleanup_rc=1
            case "$runlevels" in *cloudflared*) cleanup_rc=1 ;; esac
            ;;
    esac
    rm -f /run/cloudflared.pid /var/run/cloudflared.pid 2>/dev/null || cleanup_rc=1
    [ ! -e /run/cloudflared.pid ] && [ ! -L /run/cloudflared.pid ] \
        && [ ! -e /var/run/cloudflared.pid ] && [ ! -L /var/run/cloudflared.pid ] || cleanup_rc=1
    rm -f "$CF_BIN" || cleanup_rc=1
    [ ! -e "$CF_BIN" ] && [ ! -L "$CF_BIN" ] || cleanup_rc=1
    rm -f "$CF_STATE_AUTOUPDATE" "$CF_STATE_HTTP2" "$CF_STATE_EDGE_IP" "$CF_STATE_TOKEN" "$STATE_DIR/cf_ipv6" || cleanup_rc=1
    for _cf_state_file in "$CF_STATE_AUTOUPDATE" "$CF_STATE_HTTP2" "$CF_STATE_EDGE_IP" "$CF_STATE_TOKEN" "$STATE_DIR/cf_ipv6"; do
        [ ! -e "$_cf_state_file" ] && [ ! -L "$_cf_state_file" ] || cleanup_rc=1
    done
    if [ "$cleanup_rc" -ne 0 ]; then
        _error "cloudflared 卸载未完全完成, 请检查残留的服务、二进制或状态文件"
        return 1
    fi
    _success "cloudflared 已卸载(二进制/服务/状态已清除)"
}

# 已有 service 只改凭据，缺失才注册；失败恢复旧凭据和服务。
_cf_switch_token() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    _cf_update_timer_snapshot
    if [ -n "$CF_CUR_TOKEN" ]; then
        echo -e "  当前令牌: $(_cf_mask_token "$CF_CUR_TOKEN")"
    else
        _warn "未能从 service 文件读取令牌(可能是手动安装或格式不同)"
    fi
    read -rp "  粘贴新令牌(或 CF 安装命令): " input
    local token; token=$(_extract_token "$input")
    [ -n "$token" ] || { _warn "未能从输入中识别新令牌, 取消"; return 1; }
    _cf_token_valid "$token" || { _error "新 Token 格式非法, 未修改 service"; return 1; }

    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac

    if [ ! -f "$svcfile" ]; then
        _info "service 文件不存在, 调用 cloudflared service install 注册..."
        if ! "$CF_BIN" service install --no-update-service "$token" 2>/dev/null; then
            _error "cloudflared service install 失败"
            return 1
        fi
        if [ -f "$svcfile" ]; then
            _cf_update_timer_set off || { _error "关闭更新 timer 失败"; return 1; }
            _cf_replace_token_in_service "" "$token" || {
                _error "service install 成功但 token 替换失败"
                return 1
            }
        else
            _error "cloudflared service install 成功但未生成 service 文件: $svcfile"
            return 1
        fi
    else
        _info "保留原有启动参数, 仅替换令牌..."
        _cf_replace_token_in_service "$CF_CUR_TOKEN" "$token" || {
            _error "替换令牌失败"
            return 1
        }
    fi

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
    _cf_is_managed_running && restarted_ok="yes"
    if [ "$restarted_ok" = "no" ]; then
        _warn "重启后服务未运行, 回滚 service 文件..."
        if _cf_rollback_service "$svcfile"; then
            _error "令牌替换后服务异常, 已回滚到原令牌。请检查新令牌是否正确"
        else
            _error "令牌替换后服务异常, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照
    _cf_token_backup_clear
    _success "令牌已更新, cloudflared 已重启(隧道短暂中断)"
}

_cf_managed_line_only() {
    local line="$1" expected="$2" first kind="" actual i=0 n
    local _cf_words=()
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
        ExecStart=*|command=*|command_args=*|cmd=*) kind=${line%%=*}; line=${line#*=} ;;
    esac
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
        \"*\") line=${line:1:${#line}-2} ;;
        \'*\') line=${line:1:${#line}-2} ;;
    esac
    case "$line" in *\"*|*\'*) return 1 ;; esac
    read -ra _cf_words <<< "$line"
    n=${#_cf_words[@]}
    [ "$n" -gt 0 ] || return 1
    first="${_cf_words[0]}"
    if [ "$kind" = command ]; then
        [ "$n" -eq 1 ] || return 1
        actual=$(readlink -f "$first" 2>/dev/null || printf '%s' "$first")
        [ "$actual" = "$expected" ]
        return
    fi
    if [ "$kind" != command_args ]; then
        if [ "$first" = "$expected" ]; then
            i=1
        elif [ "$first" != tunnel ]; then
            return 1
        fi
    fi
    if [ "$i" -lt "$n" ]; then
        case "${_cf_words[$i]}" in
            --autoupdate-freq) [ "$((i+1))" -lt "$n" ] || return 1; [ "${_cf_words[$((i+1))]}" = 24h0m0s ] || return 1; i=$((i+2)) ;;
            --no-autoupdate) i=$((i+1)) ;;
        esac
    fi
    [ "$i" -lt "$n" ] && [ "${_cf_words[$i]}" = tunnel ] || return 1
    i=$((i+1))
    if [ "$i" -lt "$n" ] && [ "${_cf_words[$i]}" = --protocol ]; then
        [ "$((i+1))" -lt "$n" ] && [ "${_cf_words[$((i+1))]}" = http2 ] || return 1
        i=$((i+2))
    fi
    if [ "$i" -lt "$n" ] && [ "${_cf_words[$i]}" = --edge-ip-version ]; then
        [ "$((i+1))" -lt "$n" ] && case "${_cf_words[$((i+1))]}" in 4|6|auto) ;; *) return 1 ;; esac
        i=$((i+2))
    fi
    [ "$i" -lt "$n" ] && [ "${_cf_words[$i]}" = run ] || return 1
    i=$((i+1))
    [ "$i" -lt "$n" ] && case "${_cf_words[$i]}" in --token|--token-file) ;; *) return 1 ;; esac
    i=$((i+1))
    [ "$i" -lt "$n" ] || return 1
    i=$((i+1))
    [ "$i" -eq "$n" ] || return 1
}

# 仅重建已托管参数形态；手改服务的额外参数不能被静默丢掉。
_cf_managed_flags_only() {
    local line svc_bin expected_bin actual_bin have_command=no have_args=no have_launch=no
    svc_bin=$(_cf_service_bin "$(_cf_unit_path)" 2>/dev/null) || return 1
    [ -n "$svc_bin" ] || return 1
    expected_bin=$(readlink -f "$CF_BIN" 2>/dev/null || printf '%s' "$CF_BIN")
    actual_bin=$(readlink -f "$svc_bin" 2>/dev/null || printf '%s' "$svc_bin")
    [ "$actual_bin" = "$expected_bin" ] || return 1
    while IFS= read -r line; do
        _cf_managed_line_only "$line" "$expected_bin" || return 1
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            command=*) have_command=yes ;;
            command_args=*) have_args=yes ;;
            *) have_launch=yes ;;
        esac
    done <<< "${CF_CUR_CMDLINE:-}"
    if [ "$have_command" = yes ] || [ "$have_args" = yes ]; then
        [ "$have_command" = yes ] && [ "$have_args" = yes ] || return 1
    fi
    [ "$have_launch" = yes ] || [ "$have_args" = yes ]
}

_cf_toggle() {
    local key="$1"
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    _cf_update_timer_snapshot
    if [ -z "$CF_CUR_TOKEN" ]; then
        _warn "未能读取令牌(可能是手动安装), 请先 [1] 补录令牌后再切换开关"
        return 1
    fi
    _cf_token_valid "$CF_CUR_TOKEN" || { _error "service 中的 Token 格式非法, 请先重新录入令牌"; return 1; }
    _cf_managed_flags_only || {
        _warn "service 启动行含未托管参数, 为避免丢失自定义设置拒绝切换; 请先手动整理启动行"
        return 1
    }
    local cur
    case "$key" in
        autoupdate) cur=$(_cf_autoupdate_effective) ;;
        http2)      cur="${CF_CUR_HTTP2:-on}" ;;
    esac
    local new; [ "$cur" = "on" ] && new="off" || new="on"

    CF_AUTOUPDATE="${CF_CUR_AUTOUPDATE}"; CF_HTTP2="${CF_CUR_HTTP2}"; CF_EDGE_IP="${CF_CUR_EDGE_IP}"
    CF_AUTOUPDATE_FLAG="${CF_CUR_AUTOUPDATE_FLAG:-yes}"
    case "$key" in
        autoupdate)
            CF_AUTOUPDATE="$new"
            _cf_update_timer_present && CF_AUTOUPDATE="off"
            CF_AUTOUPDATE_FLAG="yes"
            ;;
        http2)      CF_HTTP2="$new" ;;
    esac
    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    local cmdline
    cmdline=$(_cf_build_cmdline "$CF_CUR_TOKEN") || return 1
    _cf_write_service_line "$cmdline" || return 1
    if [ "$key" = autoupdate ] && ! _cf_update_timer_set "$new"; then
        _cf_rollback_service "$svcfile" || _error "更新 timer 切换失败且回滚未完成"
        return 1
    fi

    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "${key} 切换失败, 已回滚到原状态"
        else
            _error "${key} 切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    if ! _cf_is_managed_running; then
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

_cf_set_edge_ip() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    _cf_update_timer_snapshot
    if [ -z "$CF_CUR_TOKEN" ]; then
        _warn "未能读取令牌(可能是手动安装), 请先 [1] 补录令牌后再切换协议栈"
        return 1
    fi
    _cf_token_valid "$CF_CUR_TOKEN" || { _error "service 中的 Token 格式非法, 请先重新录入令牌"; return 1; }
    _cf_managed_flags_only || {
        _warn "service 启动行含未托管参数, 为避免丢失自定义设置拒绝切换; 请先手动整理启动行"
        return 1
    }
    local cur="${CF_CUR_EDGE_IP:-off}"
    echo
    echo -e "  ${CYAN}【切换协议栈】${NC}"
    echo -e "  当前: $(_cf_edge_ip_disp "$cur")"
    echo
    echo -e "  ${GREEN}[1]${NC} IPv4 (--edge-ip-version 4)"
    echo -e "  ${GREEN}[2]${NC} IPv6 (--edge-ip-version 6)"
    echo -e "  ${GREEN}[3]${NC} Auto (--edge-ip-version auto)"
    echo -e "  ${GREEN}[4]${NC} 未指定 (不写参数, 默认 auto)"
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
    CF_AUTOUPDATE_FLAG="${CF_CUR_AUTOUPDATE_FLAG:-yes}"
    local cmdline
    cmdline=$(_cf_build_cmdline "$CF_CUR_TOKEN") || return 1
    _cf_write_service_line "$cmdline" || return 1

    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "协议栈切换失败, 已回滚到原状态"
        else
            _error "协议栈切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    if ! _cf_is_managed_running; then
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
                tok_disp=$(_cf_mask_token "$CF_CUR_TOKEN")
            else
                tok_disp="${YELLOW}未读取(需补录)${NC}"
            fi
            local auto_disp auto_suffix=""
            auto_disp=$(_cf_autoupdate_effective)
            if [ "${CF_CUR_AUTOUPDATE_FLAG:-yes}" = "no" ]; then
                auto_suffix="(启动行无标志, 默认开)"
            fi
            echo -e "  状态: ${GREEN}已安装${NC}  令牌: ${tok_disp}"
            echo -e "  自动更新: $(_cf_onoff "$auto_disp")${auto_suffix}  HTTP/2: $(_cf_http2_disp "${CF_CUR_HTTP2:-on}")  协议栈: $(_cf_edge_ip_disp "${CF_CUR_EDGE_IP:-off}")"
            echo
            if [ -n "$CF_CUR_TOKEN" ]; then
                echo -e "  ${GREEN}[1]${NC} 切换令牌"
            else
                echo -e "  ${GREEN}[1]${NC} 补录令牌(手动安装的 cloudflared)"
                echo -e "  ${YELLOW}管理 --token 与 --token-file; Environment=TUNNEL_TOKEN 需手动维护${NC}"
            fi
            echo -e "  ${GREEN}[2]${NC} 切换 自动更新 (当前 $(_cf_onoff "$auto_disp"))"
            echo -e "  ${GREEN}[3]${NC} 切换 HTTP/2      (当前 $(_cf_http2_disp "${CF_CUR_HTTP2:-on}"))"
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
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1) if [ "$installed" = "yes" ]; then _cf_switch_token; else _install_cloudflared; fi ;;
            2) _cf_toggle autoupdate ;;
            3) _cf_toggle http2 ;;
            4) _cf_set_edge_ip ;;
            5)
                if _cf_restart && _cf_is_managed_running; then
                    _success "已重启"
                else
                    _warn "重启失败或重启后服务未运行, 请检查状态"
                fi
                ;;

            6) _cf_diagnose ;;
            9) _uninstall_cloudflared ;;
            0) return ;;
            *) _warn "无效" ;;
        esac
        _press_any_key
    done
}

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
        if [ -n "$CF_CUR_TOKEN" ]; then
            echo -e "  解析到的 token: $(_cf_mask_token "$CF_CUR_TOKEN") (长度 ${#CF_CUR_TOKEN})"
        else
            echo -e "  解析到的 token: (空)"
        fi
        echo -e "  解析到的开关: auto=$(_cf_autoupdate_effective) http2=${CF_CUR_HTTP2} 协议栈=${CF_CUR_EDGE_IP}"
        echo
        echo -e "  ${CYAN}--- 文件内容(token 已掩码) ---${NC}"
        local dl
        while IFS= read -r dl || [ -n "$dl" ]; do
            _cf_redact_service_line "$dl"
        done < "$svcfile"
        echo -e "  ${CYAN}--- end ---${NC}"
        echo
        _tip "以上 token 已掩码, 可直接反馈给开发者"
    else
        _warn "service 文件不存在"
    fi
}

_cf_onoff() {
    [ "$1" = "on" ] && echo "${GREEN}● 开${NC}" || echo "${RED}○ 关${NC}"
}

_cf_edge_ip_disp() {
    case "$1" in
        4)    echo "${GREEN}● IPv4${NC}" ;;
        6)    echo "${GREEN}● IPv6${NC}" ;;
        auto) echo "${GREEN}● Auto${NC}" ;;
        *)    echo "${YELLOW}未指定(默认 auto)${NC}" ;;
    esac
}

_cf_edge_ip_label() {
    case "$1" in
        4) echo "IPv4" ;;
        6) echo "IPv6" ;;
        auto) echo "Auto" ;;
        *) echo "未指定(默认 auto)" ;;
    esac
}

_cf_http2_disp() {
    [ "$1" = on ] && echo "${GREEN}HTTP2${NC}" || echo "${YELLOW}auto(默认, QUIC 优先)${NC}"
}
