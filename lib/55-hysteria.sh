#!/bin/bash
# 官方 Hysteria 与 Xray Hy2 分离；binary/config/service/auth/link 不共享实现。
# 单 password 模型；config/server/node 事务保留原运行状态，派生缓存失败只告警。
# 官方配置支持 JSON；没有 check 子命令，必须通过真实启动验证并保留 AVX 一次 fallback。

export HYSTERIA_BIN="$BIN_DIR/hysteria"
export HYSTERIA_CONFIG="$DEPLOY_DIR/hysteria.json"
export HYSTERIA_DATA_DIR="$DEPLOY_DIR/hysteria"
export HYSTERIA_BACKUP_DIR="$DEPLOY_DIR/hysteria/backup"
export HYSTERIA_NODE_META="$DEPLOY_DIR/hysteria/node.json"
export HYSTERIA_SERVER_META="$DEPLOY_DIR/hysteria/server_meta.json"
export HYSTERIA_CERT_DIR="$CERT_DIR/hysteria"
export HYSTERIA_LOG_FILE="$LOG_DIR/hysteria.log"
export HYSTERIA_ACME_DIR="$DEPLOY_DIR/hysteria/acme"
export HYSTERIA_SVC="xray-deploy-hysteria"
export HYSTERIA_PID_FILE="/run/xray-deploy-hysteria.pid"
export HYSTERIA_DL_BASE="https://download.hysteria.network/app"
export HYSTERIA_GH_API="https://api.github.com/repos/HyNetworks/hysteria/releases/latest"

# 确保数据与日志目录权限；direct/OpenRC 可独立于主入口启动。
_hysteria_ensure_dirs() {
    local ok=1 d f
    for d in "$HYSTERIA_DATA_DIR" "$HYSTERIA_BACKUP_DIR" "$HYSTERIA_CERT_DIR" "$HYSTERIA_ACME_DIR" "$LOG_DIR"; do
        mkdir -p "$d" || ok=0
        chmod 700 "$d" 2>/dev/null || ok=0
    done
    for f in "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODE_META"; do
        [ -f "$f" ] && { chmod 600 "$f" 2>/dev/null || ok=0; }
    done
    [ "$ok" -eq 1 ] || { _error "Hysteria 数据目录/权限设置失败(只读文件系统?)"; return 1; }
    return 0
}

_hysteria_installed() {
    [ -x "$HYSTERIA_BIN" ] || return 1
    return 0
}

# 版本直接读 binary；解析规则对齐官方 get.hy2.sh。
_hysteria_current_version() {
    _hysteria_installed || { echo ""; return 0; }
    "$HYSTERIA_BIN" version 2>/dev/null | grep '^Version' | grep -o 'v[.0-9]*' | head -1
}

# 展示缓存冷读时回落 binary；缓存不替代安装判据。
_hysteria_cached_version() {
    local ver
    ver=$(_state_get hysteria_version 2>/dev/null)
    if [ -n "$ver" ]; then
        echo "$ver"
        return 0
    fi
    ver=$(_hysteria_current_version)
    [ -n "$ver" ] && _state_set hysteria_version "$ver" 2>/dev/null
    echo "$ver"
}

# 剥离 app/ 并校验 release tag；下载服务与 GitHub API 共用。
_hysteria_canon_version() {
    local v="${1#app/}"
    [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$v"; return 0; }
    return 1
}

# GET Range 只探最终版本 URL，失败回落 GitHub；避免 HEAD 不兼容及完整下载。
_hysteria_latest_version() {
    local asset final ver
    asset=$(_hysteria_arch_asset) || return 1
    final=$(curl -fsSL -r 0-0 -o /dev/null --max-time 15 -w '%{url_effective}' \
            "${HYSTERIA_DL_BASE}/latest/hysteria-linux-${asset}" 2>/dev/null) || final=""
    ver=$(_hysteria_canon_version "$(printf '%s' "$final" | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -1)")
    if [ -z "$ver" ] && command -v jq >/dev/null 2>&1; then
        ver=$(_hysteria_canon_version "$(curl -fsSL --max-time 15 "$HYSTERIA_GH_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)")
    fi
    [ -n "$ver" ] && echo "$ver"
    return 0
}

# 资产映射对齐 get.hy2.sh；ARMv6/MIPS 不兼容拒绝，补 armv5/riscv64。
_hysteria_arch_asset() {
    local m="${1:-$(uname -m)}"
    case "$m" in
        x86_64|amd64)              echo "amd64" ;;
        i386|i486|i586|i686)       echo "386" ;;
        aarch64|arm64|armv8*)      echo "arm64" ;;
        armv7|armv7l)              echo "arm" ;;
        armv6|armv6l)              return 1 ;;
        armv5*)                    echo "armv5" ;;
        mipsle)                    echo "mipsle" ;;
        mips|mips64|mips64le)      return 1 ;;
        s390x)                     echo "s390x" ;;
        riscv64)                   echo "riscv64" ;;
        loongarch64)               echo "loong64" ;;
        *)                         return 1 ;;
    esac
}

# 只匹配独立 avx 词条；avx2/avx_vnni 不证明 AVX 可用。
_hysteria_cpu_has_avx() {
    [ -r /proc/cpuinfo ] || return 1
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | tr ' ' '\n' | grep -qx avx
}

# amd64 自动优先 AVX；_HY_FORCE_PLAIN 保证 fallback 不递归。
_hysteria_pick_asset() {
    local base
    base=$(_hysteria_arch_asset) || return 1
    if [ "$base" != "amd64" ]; then
        echo "$base"
        return 0
    fi
    if [ -n "${_HY_FORCE_PLAIN:-}" ]; then
        echo "amd64"
        return 0
    fi
    if _hysteria_cpu_has_avx; then
        echo "amd64-avx"
    else
        echo "amd64"
    fi
}

# binary 事务保留旧核心和原运行状态；锁内验证后提交，失败恢复。
_hysteria_install_commit_locked() {
    local tmp="$1" want="$2" asset="$3" was_running=0 backup="" old_ver="" old_asset="" state now_ver
    state=$(_hysteria_runtime_state) || { rm -f "$tmp"; return 1; }
    if _hysteria_installed; then
        backup=$(mktemp "$BIN_DIR/.hysteria.rollback.XXXXXX") \
            || { rm -f "$tmp"; _error "回滚备份文件创建失败, 已中止"; return 1; }
        if ! cp -p "$HYSTERIA_BIN" "$backup" || ! cmp -s "$HYSTERIA_BIN" "$backup"; then
            rm -f "$tmp" "$backup"
            _error "旧核心备份失败, 已中止"
            return 1
        fi
        old_ver=$(_hysteria_current_version)
        old_asset=$(_state_get hysteria_asset 2>/dev/null)
        if [ "$state" = "running" ]; then
            was_running=1
            _hysteria_stop_and_verify || {
                rm -f "$tmp" "$backup"
                _error "停止服务失败(进程或 supervisor 状态未收敛), 已中止升级"
                return 1
            }
        fi
        if ! mv -f "$tmp" "$HYSTERIA_BIN"; then
            rm -f "$tmp"
            [ "$was_running" -eq 1 ] && _manage_hysteria start >/dev/null 2>&1
            rm -f "$backup"
            _error "核心替换失败, 旧核心未变动"
            return 1
        fi
    else
        if [ "$state" != "stopped" ]; then
            rm -f "$tmp"
            _error "服务不是已确认 stopped, 拒绝首次发布 Hysteria 核心"
            return 1
        fi
        if ! mv -f "$tmp" "$HYSTERIA_BIN"; then
            rm -f "$tmp"
            _error "核心安装失败"
            return 1
        fi
        chmod 755 "$HYSTERIA_BIN" 2>/dev/null
    fi
    _state_set hysteria_version "$want" || _warn "版本记录写入失败(不影响运行)"
    _state_set hysteria_asset "$asset" || _warn "资产记录写入失败(不影响运行, AVX 兜底将按 CPU 弱推断)"
    if [ "$was_running" -eq 1 ]; then
        if _hysteria_restart_verified; then
            _success "官方 Hysteria2 核心已升级: ${want}"
        elif _hysteria_avx_runtime_retry "$want" "$asset"; then
            [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
            return 0
        else
            _error "升级后启动失败, 回滚旧核心..."
            if [ -n "$backup" ] && [ -s "$backup" ] && mv -f "$backup" "$HYSTERIA_BIN" 2>/dev/null; then
                now_ver=$(_hysteria_current_version)
                if _hysteria_restart_verified; then
                    if [ -n "$old_ver" ] && [ "$now_ver" != "$old_ver" ]; then
                        _error "已恢复运行但版本不符(期望 ${old_ver}, 实际 ${now_ver:-未知}), 请人工核对 $HYSTERIA_BIN"
                    else
                        _warn "已回滚旧核心并恢复运行(${now_ver:-未知})"
                    fi
                else
                    _error "旧核心文件已恢复, 但服务仍无法恢复运行"
                fi
                _state_set hysteria_version "$old_ver" 2>/dev/null || true
                _state_set hysteria_asset "$old_asset" 2>/dev/null || true
            else
                _error "核心回滚失败; 保留备份供人工恢复: ${backup:-缺失}"
                _tip "请核对 $HYSTERIA_BIN 与服务状态, 不要删除回滚备份"
            fi
            return 1
        fi
    else
        _success "官方 Hysteria2 核心已安装: ${want}"
    fi
    [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
    return 0
}

# 下载只做非空、执行自检及版本匹配；AVX 自检失败仅重试普通 amd64。
_hysteria_download_install() {
    local want="$1" asset url tmp ver
    [ -n "$want" ] || { _error "未指定目标版本"; return 1; }
    asset=$(_hysteria_pick_asset) || { _error "不支持的 CPU 架构: $(uname -m)"; return 1; }
    if [ "$want" = "latest" ]; then
        _info "探测官方最新版本..."
        want=$(_hysteria_latest_version)
        [ -n "$want" ] || { _error "无法获取最新版本(网络受限?), 可改用指定版本安装"; return 1; }
    fi
    want=$(_hysteria_canon_version "$want") || { _error "版本号格式应为 v2.x.x: $1"; return 1; }
    url="${HYSTERIA_DL_BASE}/${want}/hysteria-linux-${asset}"
    _info "下载 ${url}"
    mkdir -p "$BIN_DIR" || return 1
    tmp=$(mktemp "$BIN_DIR/hysteria.dl.XXXXXX") || { _error "临时文件创建失败"; return 1; }
    if ! _http_download "$url" "$tmp" 120; then
        rm -f "$tmp"
        _error "下载失败(网络受限?), 当前安装未变动"
        return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; _error "下载内容为空, 当前安装未变动"; return 1; }
    chmod 755 "$tmp" 2>/dev/null
    ver=$("$tmp" version 2>/dev/null | grep '^Version' | grep -o 'v[.0-9]*' | head -1)
    if [ "$ver" != "$want" ]; then
        rm -f "$tmp"
        if [ "$asset" = "amd64-avx" ] && [ -z "${_HY_FORCE_PLAIN:-}" ]; then
            _warn "AVX 版无法在本机执行(可执行自检未通过), 自动改用普通 amd64 重试"
            _HY_FORCE_PLAIN=1 _hysteria_download_install "$want"
            return $?
        fi
        _error "下载内容校验失败(期望 ${want}, 实际 ${ver:-无法执行}), 已放弃替换"
        return 1
    fi
    if ! _with_config_lock _hysteria_install_commit_locked "$tmp" "$want" "$asset"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# 真实启动失败时仅一次普通 amd64 重试；version 自检不覆盖 AVX 热路径。
_hysteria_avx_runtime_retry() {
    local want="$1" asset="$2"
    [ -n "$want" ] || return 1
    [ -z "${_HY_FORCE_PLAIN:-}" ] || return 1
    if [ -z "$asset" ]; then
        local base
        base=$(_hysteria_arch_asset 2>/dev/null) || return 1
        [ "$base" = "amd64" ] || return 1
        _hysteria_cpu_has_avx || return 1
        asset="amd64-avx"
        _warn "资产记录缺失(state/hysteria_asset), 按 CPU 能力保守判定当前为 AVX 变体"
    fi
    [ "$asset" = "amd64-avx" ] || return 1
    _warn "AVX 版核心启动失败(自检通过但运行期不兼容), 自动改用普通 amd64 重装并重试启动(仅一次)"
    _HY_FORCE_PLAIN=1 _hysteria_download_install "$want" \
        || { _warn "普通 amd64 安装失败, 继续回滚旧核心"; return 1; }
    if _hysteria_restart_verified; then
        _success "已自动改用普通 amd64 核心并启动成功: ${want}"
        return 0
    fi
    _warn "普通 amd64 亦无法启动(问题不在 AVX 变体), 继续回滚旧核心"
    _tip "两次启动均失败通常另有原因(TLS 证书/端口占用/配置错误), 请查看服务日志定位"
    return 1
}

_hysteria_core_menu() {
    local choice cur latest
    cur=$(_hysteria_cached_version 2>/dev/null)
    echo; echo -e "  ${CYAN}【官方核心管理】${NC}"
    if [ -n "$cur" ]; then
        echo -e "  当前版本: ${GREEN}${cur}${NC}  (binary: $HYSTERIA_BIN)"
    else
        echo -e "  当前版本: ${RED}未安装${NC}"
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 安装/更新到最新版"
    echo -e "  ${GREEN}[2]${NC} 安装指定版本 (v2.x.x)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    echo
    read -rp "  请选择: " choice || return 0
    case "$choice" in
        1) _hysteria_download_install latest ;;
        2)
            read -rp "  输入版本号 (如 v2.12.2): " latest
            [ -z "$latest" ] && { _info "已取消"; return 0; }
            _hysteria_download_install "$latest"
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

_hysteria_openrc_status_unknown() {
    local anchor comm
    anchor=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE" 2>/dev/null)
    if [ -z "$anchor" ]; then
        { [ -e "$HYSTERIA_PID_FILE" ] || [ -L "$HYSTERIA_PID_FILE" ]; } && return 0
        return 1
    fi
    [ -d "/proc/$anchor" ] || return 1
    comm=$(cat "/proc/$anchor/comm" 2>/dev/null)
    case "$comm" in
        supervise-daemo*)
            _proc_named_under "$anchor" hysteria && return 1
            _hysteria_proc_tree_has_bin "$anchor" && return 1
            return 0
            ;;
        "") return 0 ;;
    esac
    return 1
}

# 三后端均验证真实进程；systemd 必须 active/running 且 MainPID 非零。
_hysteria_is_running() {
    local anchor="" load="" active=""
    case "$INIT_SYSTEM" in
        systemd)
            load=$(systemctl show -p LoadState --value "$HYSTERIA_SVC" 2>/dev/null)
            case "$load" in
                not-found) return 1 ;;
                "")
                    systemctl is-active --quiet "$HYSTERIA_SVC" 2>/dev/null || return 1
                    ;;
                *)
                    active=$(systemctl show -p ActiveState --value "$HYSTERIA_SVC" 2>/dev/null)
                    if [ -n "$active" ]; then
                        [ "$active" = "active" ] || return 1
                        [ "$(systemctl show -p SubState --value "$HYSTERIA_SVC" 2>/dev/null)" = "running" ] || return 1
                        anchor=$(systemctl show -p MainPID --value "$HYSTERIA_SVC" 2>/dev/null)
                        [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
                        [ "$anchor" != "0" ] || return 1
                        _proc_named_under "$anchor" hysteria && return 0
                        return 1
                    fi
                    systemctl is-active --quiet "$HYSTERIA_SVC" 2>/dev/null || return 1
                    anchor=$(systemctl show -p MainPID --value "$HYSTERIA_SVC" 2>/dev/null)
                    if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ]; then
                        _proc_named_under "$anchor" hysteria && return 0
                    fi
                    ;;
            esac
            ;;
        direct)
            if [ -n "$(_xd_pidfile_starttime "$HYSTERIA_PID_FILE")" ]; then
                _xd_pidfile_identity_ok "$HYSTERIA_PID_FILE" || return 1
            fi
            anchor=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE" 2>/dev/null)
            _hysteria_pid_is_ours "${anchor:-}" && return 0
            ;;
        openrc)
            anchor=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE" 2>/dev/null)
            if [ -z "$anchor" ] && { [ -e "$HYSTERIA_PID_FILE" ] || [ -L "$HYSTERIA_PID_FILE" ]; }; then
                return 0
            fi
            if [ -n "$anchor" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" hysteria && return 0
                case "$(cat "/proc/$anchor/comm" 2>/dev/null)" in
                    supervise-daemo*|"") return 0 ;;
                esac
            fi
            ;;
    esac
    _proc_any_named hysteria "$HYSTERIA_BIN"
}

# PID 必须归属 HYSTERIA_BIN；同名外部进程不可接管或误杀。
_hysteria_pid_is_ours() {
    local pid="${1:-}" exe want
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    [ -n "$exe" ] || return 1
    exe="${exe% (deleted)}"
    [ "$exe" = "$HYSTERIA_BIN" ] && return 0
    want=$(readlink -f "$HYSTERIA_BIN" 2>/dev/null) || return 1
    [ -n "$want" ] && [ "$exe" = "$want" ]
}

# OpenRC supervisor 需验证子进程 exe；pidfile 本身不证明核心运行。
_hysteria_proc_tree_has_bin() {
    local anchor="$1" p c cur i
    local depth=4   # 见上方契约说明: 实现假设, 超出即返回 1(fail-closed)
    [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
    [ "$anchor" != "0" ] || return 1
    if declare -F _proc_exe_is_strict >/dev/null 2>&1; then
        _proc_exe_is_strict "$anchor" "$HYSTERIA_BIN" && return 0
    else
        _warn "lib 版本过旧(00-common 缺 _proc_exe_is_strict), 无法确认进程归属, 跳过"
        return 1
    fi
    for p in /proc/[0-9]*; do
        c="${p#/proc/}"
        cur="$c"
        i=0
        while [ "$i" -lt "$depth" ]; do
            cur=$(_proc_ppid "$cur") || break
            if [ "$cur" = "$anchor" ]; then
                _proc_exe_is_strict "$c" "$HYSTERIA_BIN" && return 0
                break
            fi
            if [ "$cur" = "1" ] || [ "$cur" = "0" ]; then break; fi
            i=$((i+1))
        done
    done
    return 1
}

_manage_hysteria() {
    local action="$1"
    local CORE_LOCK_FD="${CORE_LOCK_FD:-9}"
    local DEPLOY_INSTALL_LOCK_FD="${DEPLOY_INSTALL_LOCK_FD:-9}"
    local XD_CORE_LEGACY_FLOCK_FD="${XD_CORE_LEGACY_FLOCK_FD:-9}"
    local XD_INSTALL_LEGACY_FLOCK_FD="${XD_INSTALL_LEGACY_FLOCK_FD:-9}"
    local XD_CORE_LEGACY1_FLOCK_FD="${XD_CORE_LEGACY1_FLOCK_FD:-9}"
    local XD_INSTALL_LEGACY1_FLOCK_FD="${XD_INSTALL_LEGACY1_FLOCK_FD:-9}"
    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start)
                    systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
                    systemctl start "$HYSTERIA_SVC" 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                stop)    systemctl stop "$HYSTERIA_SVC" 2>/dev/null 9>&- ;;
                restart)
                    systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
                    systemctl restart "$HYSTERIA_SVC" 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        openrc)
            case "$action" in
                start)
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1 9>&-
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                stop)
                    rc-service "$HYSTERIA_SVC" stop 2>/dev/null 9>&-
                    _hysteria_kill_stale_supervisor ;;
                restart)
                    rc-service "$HYSTERIA_SVC" stop 2>/dev/null 9>&-
                    _hysteria_kill_stale_supervisor
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1 9>&-
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                status)
                    if _hysteria_openrc_status_unknown; then echo "unknown"
                    elif _hysteria_is_running; then echo "running"
                    else echo "stopped"; fi
                    ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    local dpid0 dpid1
                    dpid0=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE")
                    if _xd_pidfile_identity_ok "$HYSTERIA_PID_FILE" && _hysteria_pid_is_ours "${dpid0:-}"; then
                        echo "running"
                    else
                        rm -f "$HYSTERIA_PID_FILE"
                        (
                            cd "$HYSTERIA_DATA_DIR" 2>/dev/null || cd /
                            exec nohup "$HYSTERIA_BIN" server -c "$HYSTERIA_CONFIG" --disable-update-check \
                                >>"$HYSTERIA_LOG_FILE" 2>&1 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&-
                        ) &
                        _xd_pidfile_write "$HYSTERIA_PID_FILE" "$!"
                        sleep 1
                        dpid1=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE")
                        if [ -z "$dpid1" ] || ! _hysteria_pid_is_ours "$dpid1"; then
                            _warn "Hysteria 启动失败, 进程已退出(查看 $HYSTERIA_LOG_FILE)"
                            rm -f "$HYSTERIA_PID_FILE"
                            return 1
                        fi
                    fi
                    ;;
                stop)
                    if [ -f "$HYSTERIA_PID_FILE" ]; then
                        local dpid _hy_st
                        dpid=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE")
                        _hy_st=$(_xd_pidfile_starttime "$HYSTERIA_PID_FILE")
                        if [ -n "$dpid" ] && _xd_pidfile_identity_ok "$HYSTERIA_PID_FILE" \
                           && _hysteria_pid_is_ours "$dpid"; then
                            _xd_kill_pid_graceful "$dpid" 5 "$_hy_st"
                        fi
                    fi
                    rm -f "$HYSTERIA_PID_FILE"
                    ;;
                restart) _manage_hysteria stop; sleep 2; _manage_hysteria start ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
    esac
}

# 运行状态区分 running/stopped/unknown；事务不可猜测 unknown。
_hysteria_runtime_state() {
    local state
    state=$(_manage_hysteria status 2>/dev/null)
    case "$state" in
        running|stopped) printf '%s' "$state" ;;
        *) _error "官方 Hysteria 服务状态未知(${state:-无状态}), 拒绝假定 stopped"; return 1 ;;
    esac
}

# 清理归属明确的遗留 supervisor；恢复前需消除自动重拉。
_hysteria_kill_stale_supervisor() {
    local a c st
    a=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE")
    if [ -z "$a" ]; then
        if [ -e "$HYSTERIA_PID_FILE" ] || [ -L "$HYSTERIA_PID_FILE" ]; then
            _warn "OpenRC pidfile 存在但无法解析, 保留证据并拒绝判定 stopped: $HYSTERIA_PID_FILE"
            return 1
        fi
        return 0
    fi
    if [ ! -d "/proc/$a" ]; then
        rm -f "$HYSTERIA_PID_FILE" && [ ! -e "$HYSTERIA_PID_FILE" ] && [ ! -L "$HYSTERIA_PID_FILE" ] || {
            _warn "无法清理已退出 supervisor 的 pidfile, 保留现场: $HYSTERIA_PID_FILE"
            return 1
        }
        return 0
    fi
    c=$(cat "/proc/$a/comm" 2>/dev/null)
    case "$c" in
        supervise-daemo*)
            if ! _hysteria_proc_tree_has_bin "$a"; then
                _warn "无法确认 pidfile 中 supervisor(pid=$a) 属于本项目; 保留 pidfile, 不报告 stopped"
                return 1
            fi
            st=$(_proc_starttime "$a") || st=""
            _xd_kill_pid_graceful "$a" 5 "$st" || {
                _warn "无法确认 supervisor(pid=$a) 已退出, 保留 pidfile"
                return 1
            }
            if [ -d "/proc/$a" ]; then
                current_st=$(_proc_starttime "$a" 2>/dev/null) || current_st=""
                if [ -z "$st" ] || [ -z "$current_st" ] || [ "$current_st" = "$st" ]; then
                    _warn "supervisor(pid=$a) 仍存活或身份无法确认, 保留 pidfile"
                    return 1
                fi
            fi
            ;;
        "")
            _warn "无法读取 pidfile 进程(pid=$a) 的 comm, 保留证据并拒绝判定 stopped"
            return 1
            ;;
        *)
            ;;
    esac
    rm -f "$HYSTERIA_PID_FILE" && [ ! -e "$HYSTERIA_PID_FILE" ] && [ ! -L "$HYSTERIA_PID_FILE" ] || {
        _warn "无法移除过期 OpenRC pidfile: $HYSTERIA_PID_FILE"
        return 1
    }
    return 0
}

# 重启后验证核心存活；官方无 check/validate 子命令。
_hysteria_restart_verified() {
    _manage_hysteria restart 2>/dev/null
    if [ "$(_manage_hysteria status 2>/dev/null)" != "running" ]; then
        _manage_hysteria start 2>/dev/null
    fi
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        [ "$(_manage_hysteria status 2>/dev/null)" = "running" ] || return 1
    done
    return 0
}

# 恢复捕获的 running/stopped 状态；失败必须显式报告。
_hysteria_recover_to_state() {
    local want="${1:-}"
    case "$want" in
        running) _hysteria_restart_verified ;;
        stopped) _hysteria_stop_and_verify >/dev/null 2>&1 ;;
        *)
            _error "未知的原运行状态 '${want}', 无法安全恢复; 请人工确认服务状态"
            return 1
            ;;
    esac
}

# 连续三次 running 才通过临时启动；瞬时进程存在不代表配置稳定。
_hysteria_validate_transient() {
    _manage_hysteria start 2>/dev/null
    local i streak=0 stable=0
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        if [ "$(_manage_hysteria status 2>/dev/null)" = "running" ]; then
            streak=$((streak + 1))
            if [ "$streak" -ge 3 ]; then stable=1; break; fi
        else
            streak=0
        fi
    done
    if [ "$stable" -ne 1 ]; then
        if ! _hysteria_stop_and_verify >/dev/null 2>&1; then
            _error "瞬态验证未通过, 且无法确认服务已停止"
        fi
        return 1
    fi
    if ! _hysteria_stop_and_verify >/dev/null 2>&1; then
        _error "瞬态验证后服务未能确认停止, 运行状态已被改变或未知(原为 stopped)"
        _tip "请人工检查并停止: ${HYSTERIA_BIN} / $( [ "$INIT_SYSTEM" = systemd ] && echo "systemctl stop ${HYSTERIA_SVC}" || echo "rc-service ${HYSTERIA_SVC} stop" )"
        return 1
    fi
    return 0
}

# WorkingDirectory 固定数据目录；ACL 相对下载与三后端保持一致。
_hysteria_create_systemd_service() {
    local nofile_line=""
    local _nf; _nf=$(_safe_nofile)
    [ -n "$_nf" ] && nofile_line="LimitNOFILE=$_nf"
    cat > "/etc/systemd/system/${HYSTERIA_SVC}.service" <<EOF
[Unit]
Description=Hysteria2 Official Server (xray-deploy)
Wants=network-online.target
After=network-online.target nss-lookup.target
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=simple
WorkingDirectory=${HYSTERIA_DATA_DIR}
NoNewPrivileges=true
ExecStart=${HYSTERIA_BIN} server -c ${HYSTERIA_CONFIG} --disable-update-check
Restart=on-failure
RestartSec=3
${nofile_line}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/${HYSTERIA_SVC}.service" 2>/dev/null || true
    if ! systemctl daemon-reload 2>/dev/null; then
        _error "systemd daemon-reload 失败"
        return 1
    fi
    if ! systemctl enable "$HYSTERIA_SVC" 2>/dev/null; then
        _warn "service 定义已创建, 但开机自启设置失败(可手动: systemctl enable ${HYSTERIA_SVC})"
    fi
    return 0
}

# OpenRC 不抬升容器 ulimit/capabilities；避免 exec 前 EPERM。
_hysteria_create_openrc_service() {
    cat > "/etc/init.d/${HYSTERIA_SVC}" <<EOF
#!/sbin/openrc-run

name="Hysteria2 Official Server (xray-deploy)"
description="Official Hysteria2 QUIC proxy server (HyNetworks/hysteria)"

supervisor=supervise-daemon
respawn_delay=5

pidfile="${HYSTERIA_PID_FILE}"
output_log="${HYSTERIA_LOG_FILE}"
error_log="${HYSTERIA_LOG_FILE}"

directory="${HYSTERIA_DATA_DIR}"

command="${HYSTERIA_BIN}"
command_args="server -c ${HYSTERIA_CONFIG} --disable-update-check"
required_files="${HYSTERIA_CONFIG}"

depend() {
    need net
    want dns
    after firewall
}
EOF
    chmod +x "/etc/init.d/${HYSTERIA_SVC}" || return 1
    if ! rc-update add "$HYSTERIA_SVC" default 2>/dev/null; then
        _warn "service 定义已创建, 但开机自启设置失败(可手动: rc-update add ${HYSTERIA_SVC} default)"
    fi
    if [ -d /etc/logrotate.d ] && [ ! -f /etc/logrotate.d/xd-hysteria ]; then
        printf '%s\n' "${HYSTERIA_LOG_FILE} {" "    weekly" "    rotate 4" "    compress" \
            "    missingok" "    copytruncate" "}" > /etc/logrotate.d/xd-hysteria 2>/dev/null || true
    fi
    return 0
}

# 透传 backend 创建结果；创建失败不能误报成启动失败。
_hysteria_create_service() {
    case "$INIT_SYSTEM" in
        systemd) _hysteria_create_systemd_service ;;
        openrc)  _hysteria_create_openrc_service ;;
        direct)
            _warn "未检测到 systemd/openrc, 跳过 service 创建(可手动: ${HYSTERIA_BIN} server -c ${HYSTERIA_CONFIG})"
            return 0
            ;;
        *)
            _error "未知的 init backend: ${INIT_SYSTEM:-未设置}, 无法创建 Hysteria service"
            return 1
            ;;
    esac
}

# 先确认核心、非空配置与 jq 可用；真实官方校验仍依赖启动。
_hysteria_config_preflight() {
    local what="${1:-修改 Hysteria 配置}"
    if ! _hysteria_installed; then
        _error "官方核心未安装, 无法${what}"
        return 1
    fi
    if [ ! -f "$HYSTERIA_CONFIG" ] || [ ! -s "$HYSTERIA_CONFIG" ]; then
        _error "Hysteria 配置不存在或为空, 无法${what}: $HYSTERIA_CONFIG"
        return 1
    fi
    _require_jq "$what"
}

# 备份必须非空且能解析为对象；lastbak 用于配置恢复，历史备份最多保留十份。
_hysteria_backup_config() {
    [ -f "$HYSTERIA_CONFIG" ] && [ -s "$HYSTERIA_CONFIG" ] || {
        _error "配置不存在或为空, 无法创建回滚备份"
        return 1
    }
    mkdir -p "$HYSTERIA_BACKUP_DIR" || return 1
    local tmp old i=0
    tmp=$(mktemp "${HYSTERIA_BACKUP_DIR}/hysteria.json.bak.XXXXXX") || return 1
    cp -f "$HYSTERIA_CONFIG" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1 || {
        rm -f "$tmp"
        _error "配置备份缺失、为空或不可解析, 备份失败"
        return 1
    }
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    local last_tmp
    last_tmp=$(mktemp "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp -f "$HYSTERIA_CONFIG" "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    [ -s "$last_tmp" ] && jq -e 'type == "object"' "$last_tmp" >/dev/null 2>&1 || {
        rm -f "$tmp" "$last_tmp"
        _error "回滚备份缺失、为空或不可解析, 备份失败"
        return 1
    }
    chmod 600 "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    mv -f "$last_tmp" "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    for old in $(ls -1t "$HYSTERIA_BACKUP_DIR" 2>/dev/null | grep '^hysteria.json.bak.'); do
        i=$((i+1))
        [ "$i" -gt 10 ] && rm -f "${HYSTERIA_BACKUP_DIR}/${old}"
    done
    return 0
}

_hysteria_restore_config() {
    [ -f "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak" ] || return 1
    [ -s "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak" ] \
      && jq -e 'type == "object"' "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak" >/dev/null 2>&1 || {
        _error "回滚备份缺失、为空或不可解析, 无法回滚(${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak)"
        return 1
    }
    local content
    content=$(cat "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak" 2>/dev/null) || { _error "读取备份失败"; return 1; }
    if ! _atomic_write_json "$HYSTERIA_CONFIG" "$content"; then
        _error "配置回滚失败($HYSTERIA_CONFIG)"
        return 1
    fi
    return 0
}

# 事务公共序言: 记录原运行态并建立回滚备份(环境校验由各事务自己先做); 结果见 _HY_TXN_WAS_RUNNING。
_hysteria_txn_prologue() {
    _HY_TXN_WAS_RUNNING=$(_hysteria_runtime_state) || return 1
    if ! _hysteria_backup_config; then
        _error "配置备份失败, 中止操作"
        return 1
    fi
    return 0
}

# 应用 jq 过滤器并原子发布 config; 失败保留旧配置。
_hysteria_config_apply_filter() {
    local filter="$1"; shift
    local tmp
    tmp=$(mktemp "${HYSTERIA_CONFIG}.XXXXXX") || { _error "无法创建临时配置"; return 1; }
    if ! jq "$@" "$filter" "$HYSTERIA_CONFIG" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        local jq_err; jq_err=$(jq "$@" "$filter" "$HYSTERIA_CONFIG" 2>&1 >/dev/null | head -3)
        _error "jq 处理失败: ${jq_err:-未知错误}"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; _error "生成的配置为空"; return 1
    fi
    if ! mv -f "$tmp" "$HYSTERIA_CONFIG"; then
        rm -f "$tmp"
        _error "配置替换失败, 保留旧配置"
        return 1
    fi
    return 0
}

# 仅变更目标字段并原子发布；启动失败恢复配置和 was_running。
_hysteria_config_txn_locked() {
    _hysteria_config_preflight || return 1
    _hysteria_txn_prologue || return 1
    local was_running="$_HY_TXN_WAS_RUNNING"
    _hysteria_config_apply_filter "${!#}" "${@:1:$#-1}" || return 1
    if [ "$was_running" = "running" ]; then
        if ! _hysteria_restart_verified; then
            _error "hysteria 启动失败, 回滚配置"
            if ! _hysteria_restore_config; then
                _error "配置回滚失败, 已进入降级状态(config 可能为新内容)"
                _tip "请人工核对: $HYSTERIA_CONFIG(旧内容见 ${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak)"
                return 1
            fi
            if _hysteria_restart_verified; then
                _warn "已回滚到旧配置并重启"
            else
                _error "降级: 配置已回滚, 但服务未能恢复运行(原状态 running); 请人工检查"
                _tip "核对: $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    else
        if ! _hysteria_validate_transient; then
            _error "hysteria 配置验证失败(瞬态启动), 回滚配置"
            if ! _hysteria_restore_config; then
                _error "配置回滚失败, 已进入降级状态(config 可能为新内容)"
                _tip "请人工核对: $HYSTERIA_CONFIG(旧内容见 ${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak)"
                return 1
            fi
            if _hysteria_validate_transient; then
                _warn "已回滚配置(原状态 stopped 保持)"
            else
                _error "降级: 配置已回滚, 但原运行状态(stopped)恢复验证失败; 请人工检查服务状态"
                _tip "核对: $HYSTERIA_CONFIG / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    fi
    return 0
}

_hysteria_config_txn() {
    _with_config_lock _hysteria_config_txn_locked "$@"
}

# config/server_meta 同一事务提交；TLS 等跨文件参数必须一致。
_hysteria_server_txn_locked() {
    _hysteria_config_preflight || return 1
    [ "$#" -ge 2 ] || { _error "server_txn 参数不足(config_filter, meta_filter)"; return 1; }
    local config_filter="$1" meta_filter="$2"; shift 2
    _hysteria_txn_prologue || return 1
    local was_running="$_HY_TXN_WAS_RUNNING"
    _hysteria_config_apply_filter "$config_filter" "${@}" || return 1
    local meta_bak="" meta_had=0 meta_created=0
    if [ "$meta_filter" != "-" ]; then
        if [ -f "$HYSTERIA_SERVER_META" ]; then
            meta_had=1
            meta_bak=$(mktemp "${HYSTERIA_SERVER_META}.bak.XXXXXX") || {
                _hysteria_server_txn_rollback_after_change "$was_running" 0 0 "" "无法创建元数据备份"
                return 1
            }
            if ! cp -p "$HYSTERIA_SERVER_META" "$meta_bak" \
               || ! cmp -s "$HYSTERIA_SERVER_META" "$meta_bak"; then
                rm -f "$meta_bak"
                _hysteria_server_txn_rollback_after_change "$was_running" 0 0 "" "元数据备份失败"
                return 1
            fi
            if ! chmod 600 "$meta_bak" 2>/dev/null; then
                rm -f "$meta_bak"
                _hysteria_server_txn_rollback_after_change "$was_running" 0 0 "" "元数据备份权限设置失败"
                return 1
            fi
        fi
        if [ ! -f "$HYSTERIA_SERVER_META" ]; then
            meta_created=1
            if ! _atomic_write_json "$HYSTERIA_SERVER_META" '{}'; then
                _hysteria_server_txn_rollback_after_change "$was_running" 0 1 "" "server_meta 初始化失败"
                return 1
            fi
        fi
        local newmeta
        if ! newmeta=$(jq "${@}" "$meta_filter" "$HYSTERIA_SERVER_META" 2>/dev/null) || [ -z "$newmeta" ]; then
            _hysteria_server_txn_rollback_after_change "$was_running" "$meta_had" "$meta_created" "$meta_bak" \
                "server_meta 变换失败"
            return 1
        fi
        if ! _atomic_write_json "$HYSTERIA_SERVER_META" "$newmeta"; then
            _hysteria_server_txn_rollback_after_change "$was_running" "$meta_had" "$meta_created" "$meta_bak" \
                "server_meta 提交失败"
            return 1
        fi
    fi
    if [ "$was_running" = "running" ]; then
        if ! _hysteria_restart_verified; then
            _error "hysteria 启动失败, 回滚配置与元数据"
            local cfg_ok=0
            _hysteria_restore_config && cfg_ok=1
            local meta_ok=0
            _hysteria_server_txn_rollback "$meta_had" "$meta_created" "$meta_bak" && meta_ok=1
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ]; then
                _error "回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败)), 已进入降级状态"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $HYSTERIA_SERVER_META"
                return 1
            fi
            if _hysteria_restart_verified; then
                _warn "已回滚到旧配置并重启"
            else
                _error "降级: 配置与元数据已回滚, 但服务未能恢复运行(原状态 running); 请人工检查"
                _tip "核对: $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    else
        if ! _hysteria_validate_transient; then
            _error "hysteria 配置验证失败(瞬态启动), 回滚配置与元数据"
            local cfg_ok=0
            _hysteria_restore_config && cfg_ok=1
            local meta_ok=0
            _hysteria_server_txn_rollback "$meta_had" "$meta_created" "$meta_bak" && meta_ok=1
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ]; then
                _error "回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败)), 已进入降级状态"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $HYSTERIA_SERVER_META"
                return 1
            fi
            if _hysteria_validate_transient; then
                _warn "已回滚配置与元数据(原状态 stopped 保持)"
            else
                _error "降级: 配置与元数据已回滚, 但原运行状态(stopped)恢复验证失败; 请人工检查"
                _tip "核对: $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    fi
    [ -n "$meta_bak" ] && { rm -f "$meta_bak" 2>/dev/null || _warn "临时备份清理失败: $meta_bak"; }
    return 0
}

# 恢复权威文件并汇总错误；不可静默丢弃恢复失败。
_hysteria_server_txn_rollback() {
    local meta_had="$1" meta_created="$2" meta_bak="$3" mc rc=0
    if [ "$meta_had" -eq 1 ]; then
        if [ -z "$meta_bak" ] || [ ! -f "$meta_bak" ] || [ ! -s "$meta_bak" ] \
           || ! jq -e 'type == "object"' "$meta_bak" >/dev/null 2>&1; then
            _warn "server_meta 回滚备份缺失或不可用, 保留现场并请人工核对 $HYSTERIA_SERVER_META"
            rc=1
        elif ! mc=$(cat "$meta_bak" 2>/dev/null) || [ -z "$mc" ] \
             || ! _atomic_write_json "$HYSTERIA_SERVER_META" "$mc"; then
            _warn "server_meta 回滚失败, 保留备份 $meta_bak 并请人工核对 $HYSTERIA_SERVER_META"
            rc=1
        fi
    elif [ "$meta_created" -eq 1 ]; then
        if rm -f "$HYSTERIA_SERVER_META"; then rc=0; else _warn "server_meta 删除失败, 请人工核对"; rc=1; fi
    fi
    if [ "$rc" -eq 0 ] && [ -n "$meta_bak" ]; then
        rm -f "$meta_bak" 2>/dev/null || _warn "临时备份清理失败: $meta_bak"
    fi
    return "$rc"
}

_hysteria_server_txn_rollback_after_change() {
    local was_running="$1" meta_had="$2" meta_created="$3" meta_bak="$4" reason="$5"
    local cfg_ok=0 meta_ok=0 state_ok=0
    _hysteria_restore_config && cfg_ok=1
    _hysteria_server_txn_rollback "$meta_had" "$meta_created" "$meta_bak" && meta_ok=1
    _hysteria_recover_to_state "$was_running" && state_ok=1
    if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ] || [ "$state_ok" -ne 1 ]; then
        _error "${reason}后回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败) service=$([ "$state_ok" -eq 1 ] && echo 已恢复 || echo 失败))"
        _tip "请人工核对: $HYSTERIA_CONFIG 与 $HYSTERIA_SERVER_META; 回滚备份如有保留请勿删除"
    else
        _error "${reason}, 已回滚配置与元数据"
    fi
    return 1
}

_hysteria_node_txn() {
    _with_config_lock _hysteria_node_txn_txn_wrapper "$@"
}

_hysteria_node_txn_txn_wrapper() {
    [ "$#" -ge 4 ] || { _error "node_txn 参数不足(config_filter, meta_file, op, content)"; return 1; }
    local n=$#
    local content="${!n}"
    local m=$((n-1))
    local op="${!m}"
    local m2=$((n-2))
    local meta_file="${!m2}"
    local m3=$((n-3))
    local config_filter="${!m3}"
    local jq_args=("${@:1:$((n-4))}")
    if [ "${#jq_args[@]}" -gt 0 ]; then
        _hysteria_node_txn_locked "$config_filter" "$meta_file" "$op" "$content" "${jq_args[@]}"
    else
        _hysteria_node_txn_locked "$config_filter" "$meta_file" "$op" "$content"
    fi
}

# auth/node 同一事务提交；clash 为派生缓存，失败不回滚权威状态。
_hysteria_node_txn_locked() {
    local config_filter="$1" meta_file="$2" meta_op="$3" meta_content="${4:-}"; shift 4
    _hysteria_config_preflight || return 1
    _hysteria_txn_prologue || return 1
    local was_running="$_HY_TXN_WAS_RUNNING"
    local meta_had=0 meta_bak="" node_name=""
    if [ "$meta_op" = "delete" ] && [ -f "$meta_file" ]; then
        node_name=$(jq -r '.name // empty' "$meta_file" 2>/dev/null)
    fi
    if [ -f "$meta_file" ]; then
        meta_had=1
        meta_bak=$(mktemp "${meta_file}.bak.XXXXXX") || { _error "无法备份节点元数据"; return 1; }
        if ! cp -p "$meta_file" "$meta_bak" \
           || ! cmp -s "$meta_file" "$meta_bak" \
           || ! chmod 600 "$meta_bak" 2>/dev/null; then
            rm -f "$meta_bak"
            _error "无法完整备份节点元数据"
            return 1
        fi
    fi
    _hysteria_config_apply_filter "$config_filter" "${@}" || return 1
    _hysteria_node_txn_meta_rollback() {
        local rc=0 mc
        if [ "$meta_had" -eq 1 ]; then
            if [ -z "$meta_bak" ] || [ ! -f "$meta_bak" ] || [ ! -s "$meta_bak" ] \
               || ! jq -e 'type == "object"' "$meta_bak" >/dev/null 2>&1; then
                _warn "节点元数据回滚备份缺失或不可用, 保留当前文件并请人工核对: $meta_file (备份: ${meta_bak:-缺失})"
                return 1
            fi
            if ! mc=$(cat "$meta_bak" 2>/dev/null) || [ -z "$mc" ] \
               || ! _atomic_write_json "$meta_file" "$mc"; then
                _warn "节点元数据回滚失败, 保留备份 $meta_bak 并请人工核对 $meta_file"
                return 1
            fi
            _hysteria_sync_clash "$meta_file" || true
        else
            if rm -f "$meta_file"; then
                if [ -n "$node_name" ]; then
                    _hysteria_remove_clash_by_name "$node_name" || true
                fi
            else
                _warn "节点元数据删除失败, 请人工核对 $meta_file"
                rc=1
            fi
        fi
        return "$rc"
    }
    if [ "$meta_op" = "create" ]; then
        if ! _atomic_write_json "$meta_file" "$meta_content"; then
            _error "节点元数据写入失败, 回滚配置与节点状态"
            local cfg_ok=0 meta_ok=0 state_ok=0
            _hysteria_restore_config && cfg_ok=1
            _hysteria_node_txn_meta_rollback && meta_ok=1
            _hysteria_recover_to_state "$was_running" && state_ok=1
            if [ "$meta_ok" -eq 1 ] && [ -n "$meta_bak" ]; then
                rm -f "$meta_bak" 2>/dev/null || _warn "节点回滚备份清理失败: $meta_bak"
            fi
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ] || [ "$state_ok" -ne 1 ]; then
                _error "节点元数据失败后回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败) service=$([ "$state_ok" -eq 1 ] && echo 已恢复 || echo 失败))"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $meta_file; 保留的回滚备份请勿删除: ${meta_bak:-无}"
            else
                _error "节点元数据写入失败, 已回滚配置与节点状态"
            fi
            return 1
        fi
    elif [ "$meta_op" = "delete" ]; then
        if ! rm -f "$meta_file"; then
            _error "节点元数据删除失败(权限/只读?), 回滚配置与节点状态"
            local cfg_ok=0 meta_ok=0 state_ok=0
            _hysteria_restore_config && cfg_ok=1
            _hysteria_node_txn_meta_rollback && meta_ok=1
            _hysteria_recover_to_state "$was_running" && state_ok=1
            if [ "$meta_ok" -eq 1 ] && [ -n "$meta_bak" ]; then
                rm -f "$meta_bak" 2>/dev/null || _warn "节点回滚备份清理失败: $meta_bak"
            fi
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ] || [ "$state_ok" -ne 1 ]; then
                _error "节点元数据删除失败后回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败) service=$([ "$state_ok" -eq 1 ] && echo 已恢复 || echo 失败))"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $meta_file; 保留的回滚备份请勿删除: ${meta_bak:-无}"
            else
                _error "节点元数据删除失败, 已回滚配置与节点状态"
            fi
            return 1
        fi
    fi
    if [ "$was_running" = "running" ]; then
        if ! _hysteria_restart_verified; then
            _error "hysteria 启动失败, 回滚配置与节点状态"
            local cfg_ok=0
            _hysteria_restore_config && cfg_ok=1
            local meta_ok=0
            _hysteria_node_txn_meta_rollback && meta_ok=1
            if [ "$meta_ok" -eq 1 ] && [ -n "$meta_bak" ]; then
                rm -f "$meta_bak" 2>/dev/null || _warn "节点回滚备份清理失败: $meta_bak"
            fi
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ]; then
                _error "回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败)), 已进入降级状态"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $meta_file; 保留的回滚备份请勿删除: ${meta_bak:-无}"
                return 1
            fi
            if _hysteria_restart_verified; then
                _warn "已回滚并重启"
            else
                _error "降级: 配置与节点元数据已回滚, 但服务未能恢复运行(原状态 running); 请人工检查"
                _tip "核对: $HYSTERIA_CONFIG / $meta_file / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    else
        if ! _hysteria_validate_transient; then
            _error "hysteria 配置验证失败(瞬态启动), 回滚配置与节点状态"
            local cfg_ok=0
            _hysteria_restore_config && cfg_ok=1
            local meta_ok=0
            _hysteria_node_txn_meta_rollback && meta_ok=1
            if [ "$meta_ok" -eq 1 ] && [ -n "$meta_bak" ]; then
                rm -f "$meta_bak" 2>/dev/null || _warn "节点回滚备份清理失败: $meta_bak"
            fi
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ]; then
                _error "回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败)), 已进入降级状态"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $meta_file; 保留的回滚备份请勿删除: ${meta_bak:-无}"
                return 1
            fi
            if _hysteria_validate_transient; then
                _warn "已回滚配置与节点元数据(原状态 stopped 保持)"
            else
                _error "降级: 配置与节点元数据已回滚, 但原运行状态(stopped)恢复验证失败; 请人工检查"
                _tip "核对: $HYSTERIA_CONFIG / $meta_file / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    fi
    rm -f "$meta_bak" 2>/dev/null
    if [ "$meta_op" = "delete" ]; then
        if [ -n "$node_name" ]; then
            _hysteria_remove_clash_by_name "$node_name" || true
        fi
    else
        _hysteria_sync_clash "$meta_file" || true
    fi
    [ -n "$meta_bak" ] && { rm -f "$meta_bak" 2>/dev/null || _warn "临时备份清理失败: $meta_bak"; }
    return 0
}

_hysteria_server_txn_txn_wrapper() {
    [ "$#" -ge 2 ] || { _error "server_txn 参数不足"; return 1; }
    local meta_filter="${!#}"
    local config_filter="${@: -2:1}"
    local jq_args=("${@:1:$#-2}")
    if [ "${#jq_args[@]}" -gt 0 ]; then
        _hysteria_server_txn_locked "$config_filter" "$meta_filter" "${jq_args[@]}"
    else
        _hysteria_server_txn_locked "$config_filter" "$meta_filter"
    fi
}

# TLS 证书对与配置共同验证；失败保留原证书及运行状态。
_hysteria_tls_server_txn_locked() {
    [ "$#" -ge 3 ] || { _error "TLS transaction 参数不足"; return 1; }
    local stage="$1" rc=0 was_running pair_ok=0 state_ok=0
    was_running=$(_hysteria_runtime_state) || return 1
    shift
    if ! _hysteria_tls_pair_begin "$stage"; then
        _hysteria_tls_pair_finish no "$stage" || true
        return 1
    fi
    _hysteria_server_txn_txn_wrapper "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        _hysteria_tls_pair_finish yes "$stage" || return 1
        return 0
    fi
    _hysteria_tls_pair_finish no "$stage" && pair_ok=1
    if [ "$pair_ok" -eq 1 ]; then
        _hysteria_recover_to_state "$was_running" && state_ok=1
    fi
    if [ "$pair_ok" -ne 1 ] || [ "$state_ok" -ne 1 ]; then
        _error "TLS 事务回滚未完成(pair=$([ "$pair_ok" -eq 1 ] && echo 已还原 || echo 失败) service=$([ "$state_ok" -eq 1 ] && echo 已恢复 || echo 失败)), 已保留恢复现场"
        return 1
    fi
    return "$rc"
}

_hysteria_tls_server_txn() {
    _with_config_lock _hysteria_tls_server_txn_locked "$@"
}

# 非空配置存在与可接管分离；外来 auth 不得被 bootstrap 覆盖。
_hysteria_config_exists() {
    [ -f "$HYSTERIA_CONFIG" ] && [ -s "$HYSTERIA_CONFIG" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e . "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

# 只接管非空 auth.password；userpass/http/command 与单凭据契约不符。
_hysteria_auth_ok() {
    _hysteria_config_exists || return 1
    jq -e '(.auth.type == "password") and (.auth.password | type == "string") and ((.auth.password | length) > 0)' "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

_hysteria_server_initialized() {
    _hysteria_auth_ok
}

_hysteria_config_password() {
    _hysteria_config_exists || return 0
    jq -r 'if .auth.type == "password" then (.auth.password // "") else "" end' "$HYSTERIA_CONFIG" 2>/dev/null
}

_hysteria_node_file_present() {
    [ -f "$HYSTERIA_NODE_META" ] && [ -s "$HYSTERIA_NODE_META" ]
}

# 节点需 auth/name/link_addr 非空字符串；损坏元数据不能锁死添加入口。
_hysteria_node_exists() {
    _hysteria_node_file_present || return 1
    command -v jq >/dev/null 2>&1 || return 1
    if jq -e '
        (.auth      | type == "string") and ((.auth      | length) > 0) and
        (.name      | type == "string") and ((.name      | length) > 0) and
        (.link_addr | type == "string") and ((.link_addr | length) > 0)
    ' "$HYSTERIA_NODE_META" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

_hysteria_node_broken() {
    _hysteria_node_file_present || return 1
    _hysteria_node_exists && return 1
    return 0
}

_hysteria_gate() {
    _hysteria_server_initialized && return 0
    if _hysteria_config_exists; then
        if jq -e '.auth.type == "password"' "$HYSTERIA_CONFIG" >/dev/null 2>&1; then
            _error "Hysteria 配置的 auth.password 为空(不完整状态): $HYSTERIA_CONFIG"
            _tip "空密码无法启动(官方 binary 会 FATAL: empty auth password); 请删除该配置后重新初始化"
        else
            _error "检测到现有 Hysteria 官方配置($HYSTERIA_CONFIG), 其 auth 不是本 Manager 管理的 password 模式"
            _tip "为防止覆盖现有配置, 菜单操作不可用; 如需接管请自行备份并把 auth 段改为 {type: password, password: ...}, 或删除该配置后重新初始化"
        fi
    else
        _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"
    fi
    return 1
}

# 证书对先暂存旧文件；任一步失败必须能恢复。
_hysteria_tls_pair_begin() {
    local stage="$1" src dst snap had_cert=0 had_key=0
    HYSTERIA_TLS_SNAPSHOT_DIR=""
    HYSTERIA_TLS_HAD_CERT=0
    HYSTERIA_TLS_HAD_KEY=0
    HYSTERIA_TLS_PUBLISHED=0
    [ -n "$stage" ] || return 0
    [ -s "$stage/cert.pem" ] && [ -s "$stage/key.pem" ] || {
        _error "暂存自签证书或私钥缺失/为空"
        return 1
    }
    mkdir -p "$HYSTERIA_CERT_DIR" || return 1
    snap=$(mktemp -d "${HYSTERIA_CERT_DIR}/.tls-snapshot.XXXXXX") || return 1
    HYSTERIA_TLS_SNAPSHOT_DIR="$snap"
    for src in cert key; do
        case "$src" in
            cert) dst="$HYSTERIA_CERT_DIR/cert.pem" ;;
            key)  dst="$HYSTERIA_CERT_DIR/key.pem" ;;
        esac
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            [ -f "$dst" ] && [ -s "$dst" ] || { _error "现有 TLS 文件不可用, 中止替换: $dst"; return 1; }
            cp -p "$dst" "$snap/$src.pem" 2>/dev/null \
                && cmp -s "$dst" "$snap/$src.pem" || { _error "TLS 回滚快照失败: $dst"; return 1; }
            [ "$src" = cert ] && had_cert=1 || had_key=1
        fi
    done
    HYSTERIA_TLS_HAD_CERT=$had_cert
    HYSTERIA_TLS_HAD_KEY=$had_key
    chmod 600 "$stage/key.pem" 2>/dev/null || { _error "无法保护暂存 TLS 私钥"; return 1; }
    mv -f "$stage/cert.pem" "$HYSTERIA_CERT_DIR/cert.pem" || { _error "TLS 证书发布失败"; return 1; }
    HYSTERIA_TLS_PUBLISHED=1
    mv -f "$stage/key.pem" "$HYSTERIA_CERT_DIR/key.pem" || { _error "TLS 私钥发布失败"; return 1; }
    return 0
}

# 逐个恢复原证书状态；保留无法恢复的备份供人工处理。
_hysteria_tls_pair_restore() {
    local dst src had tmp rc=0
    [ -n "${HYSTERIA_TLS_SNAPSHOT_DIR:-}" ] || return 0
    for src in cert key; do
        case "$src" in
            cert) dst="$HYSTERIA_CERT_DIR/cert.pem"; had="$HYSTERIA_TLS_HAD_CERT" ;;
            key)  dst="$HYSTERIA_CERT_DIR/key.pem"; had="$HYSTERIA_TLS_HAD_KEY" ;;
        esac
        if [ "$had" -eq 1 ]; then
            [ -s "$HYSTERIA_TLS_SNAPSHOT_DIR/$src.pem" ] || { rc=1; continue; }
            tmp=$(mktemp "${dst}.restore.XXXXXX") || { rc=1; continue; }
            if cp -p "$HYSTERIA_TLS_SNAPSHOT_DIR/$src.pem" "$tmp" 2>/dev/null \
               && cmp -s "$HYSTERIA_TLS_SNAPSHOT_DIR/$src.pem" "$tmp" \
               && mv -f "$tmp" "$dst"; then
                :
            else
                rm -f "$tmp"
                rc=1
            fi
        else
            rm -f "$dst" 2>/dev/null || rc=1
            { [ ! -e "$dst" ] && [ ! -L "$dst" ]; } || rc=1
        fi
    done
    return "$rc"
}

_hysteria_tls_pair_finish() {
    local commit="$1" stage="${2:-}" snap="${HYSTERIA_TLS_SNAPSHOT_DIR:-}"
    if [ "$commit" = "yes" ]; then
        [ -z "$snap" ] || rm -rf "$snap" 2>/dev/null || _warn "TLS 旧文件快照清理失败, 请人工清理: $snap"
        [ -z "$stage" ] || rm -rf "$stage" 2>/dev/null || _warn "TLS 暂存目录清理失败: $stage"
        return 0
    fi
    if [ "${HYSTERIA_TLS_PUBLISHED:-0}" -ne 1 ]; then
        [ -z "$snap" ] || rm -rf "$snap" 2>/dev/null || _warn "TLS 准备快照清理失败: $snap"
        [ -z "$stage" ] || rm -rf "$stage" 2>/dev/null || _warn "TLS 暂存目录清理失败: $stage"
        return 0
    fi
    if _hysteria_tls_pair_restore; then
        [ -z "$snap" ] || rm -rf "$snap" 2>/dev/null || _warn "TLS 回滚快照清理失败: $snap"
        [ -z "$stage" ] || rm -rf "$stage" 2>/dev/null || _warn "TLS 暂存目录清理失败: $stage"
        return 0
    fi
    _error "TLS 文件回滚失败; 已保留快照与暂存现场, 请人工核对: ${snap:-无快照} ${stage:-}"
    return 1
}

_hysteria_meta_get() {
    local key="$1" val=""
    [ -f "$HYSTERIA_SERVER_META" ] && val=$(jq -r --arg k "$key" '.[$k] // empty' "$HYSTERIA_SERVER_META" 2>/dev/null)
    printf '%s' "$val"
}

# manager 元数据独立于官方 config；只写自有字段并保持原子性。
_hysteria_meta_set() {
    local key="$1" val="$2" cur
    mkdir -p "$HYSTERIA_DATA_DIR" || return 1
    if [ -f "$HYSTERIA_SERVER_META" ]; then
        _meta_update "$HYSTERIA_SERVER_META" '.[$k]=$v' --arg k "$key" --arg v "$val"
    else
        _atomic_write_json "$HYSTERIA_SERVER_META" "$(jq -n --arg k "$key" --arg v "$val" '{($k): $v}')"
    fi
}

# TLS 向导只重问错误字段，EOF 退出；空 SNI 使用客户端连接主机名。
_hysteria_prompt_tls() {
    HY_TLS_STAGE_DIR=""
    local choice cert_file key_file acme_domains acme_email host
    local arr first acme_bad acme_first why ans2
    local -a doms
    local d
    echo; echo -e "  ${CYAN}【TLS 设置】${NC}"
    echo -e "  ${GREEN}[1]${NC} 自签证书 (官方 hysteria cert 生成, 客户端 insecure)"
    echo -e "  ${GREEN}[2]${NC} 使用已有证书 (证书+私钥路径)"
    echo -e "  ${GREEN}[3]${NC} ACME 自动证书 (本向导用 HTTP/TLS 质询; DNS 质询请手工编辑 hysteria.json)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    while true; do
        read -rp "  请选择: " choice || return 1
        case "${choice:-0}" in
            0|1|2|3) break ;;
            *) _error "无效选择: ${choice}(可选 0-3)" ;;
        esac
    done
    case "${choice:-0}" in
        0) return 1 ;;
        1)
            _hysteria_installed || { _error "官方核心未安装, 无法生成自签证书"; return 1; }
            mkdir -p "$HYSTERIA_CERT_DIR" || return 1
            while true; do
                read -rp "  证书域名/SAN (回车默认 example.com): " host || return 1
                host=${host:-example.com}
                why=$(_hysteria_domain_reason "$host")
                [ -z "$why" ] && break
                _error "$why"
            done
            HY_TLS_STAGE_DIR=$(mktemp -d "${HYSTERIA_CERT_DIR}/.tls-stage.XXXXXX") || {
                _error "无法创建自签 TLS 暂存目录"
                return 1
            }
            if ! "$HYSTERIA_BIN" cert --host "$host" \
                 --cert "$HY_TLS_STAGE_DIR/cert.pem" --key "$HY_TLS_STAGE_DIR/key.pem" \
                 --overwrite >/dev/null 2>&1; then
                rm -rf "$HY_TLS_STAGE_DIR"
                HY_TLS_STAGE_DIR=""
                _error "证书生成失败(hysteria cert)"
                return 1
            fi
            if [ ! -s "$HY_TLS_STAGE_DIR/cert.pem" ] || [ ! -s "$HY_TLS_STAGE_DIR/key.pem" ] \
               || ! chmod 600 "$HY_TLS_STAGE_DIR/key.pem" 2>/dev/null; then
                rm -rf "$HY_TLS_STAGE_DIR"
                HY_TLS_STAGE_DIR=""
                _error "自签 TLS 证书或私钥不可用, 已放弃"
                return 1
            fi
            HY_TLS_JSON=$(jq -n --arg c "$HYSTERIA_CERT_DIR/cert.pem" --arg k "$HYSTERIA_CERT_DIR/key.pem" \
                '{tls: {cert: $c, key: $k, sniGuard: "disable"}}')
            HY_TLS_MODE="selfsigned"; HY_TLS_SNI="$host"; HY_TLS_PIN=""
            return 0
            ;;
        2)
            while true; do
                read -rp "  cert 文件路径: " cert_file || return 1
                _validate_json_text "$cert_file" || { _error "cert 路径含非法字符(双引号/反斜杠/换行/制表符或 {{)"; continue; }
                break
            done
            while true; do
                read -rp "  key  文件路径: " key_file || return 1
                _validate_json_text "$key_file" || { _error "key 路径含非法字符(双引号/反斜杠/换行/制表符或 {{)"; continue; }
                break
            done
            while [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; do
                _error "证书文件不存在: cert=${cert_file} key=${key_file}"
                read -rp "  重新输入 cert 路径 (回车保持当前): " ans2 || return 1
                [ -n "$ans2" ] && cert_file="$ans2"
                read -rp "  重新输入 key  路径 (回车保持当前): " ans2 || return 1
                [ -n "$ans2" ] && key_file="$ans2"
            done
            while true; do
                read -rp "  客户端 SNI (回车使用客户端连接主机名): " host || return 1
                [ -z "$host" ] && break
                why=$(_hysteria_domain_reason "$host")
                [ -z "$why" ] && break
                _error "$why"
            done
            HY_TLS_JSON=$(jq -n --arg c "$cert_file" --arg k "$key_file" '{tls: {cert: $c, key: $k}}')
            HY_TLS_MODE="custom"; HY_TLS_SNI="$host"; HY_TLS_PIN=""
            return 0
            ;;
        3)
            while true; do
                read -rp "  ACME 域名(多个用逗号分隔): " acme_domains || return 1
                arr="["; first=1; acme_bad=""; acme_first=""
                IFS=',' read -ra doms <<< "$acme_domains"
                for d in "${doms[@]}"; do
                    d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
                    [ -z "$d" ] && continue
                    if ! _validate_domain "$d"; then
                        acme_bad="$d"
                        break
                    fi
                    [ -n "$acme_first" ] || acme_first="$d"
                    [ "$first" -eq 1 ] && first=0 || arr="${arr},"
                    arr="${arr}\"$d\""
                done
                if [ -n "$acme_bad" ]; then
                    _error "域名格式非法: ${acme_bad}(仅字母/数字/连字符, 点分段)"
                    continue
                fi
                arr="${arr}]"
                [ "$arr" = "[]" ] || break
                _error "至少需要一个有效域名"
            done
            while true; do
                read -rp "  邮箱: " acme_email || return 1
                [ -n "$acme_email" ] && break
                _error "邮箱不能为空(ACME 注册与到期通知需要, 如 admin@example.com)"
            done
            if _config_present && command -v jq >/dev/null 2>&1; then
                if _config_jq -e '[.inbounds[]?.port] | index(80) or index(443)' >/dev/null 2>&1; then
                    _warn "Xray 已占用 80/443 端口, ACME 质询会失败(除非 NAT 转发到本机其他实现)"
                fi
            fi
            _warn "HTTP/TLS 质询需要 80/443 可达(NAT VPS 通常不满足); DNS 质询不依赖 80/443, 请手工在 hysteria.json 的 acme 段配置 type: dns"
            HY_TLS_JSON=$(jq -n --argjson d "$arr" --arg e "$acme_email" --arg dir "$HYSTERIA_ACME_DIR" \
                '{acme: {domains: $d, email: $e, dir: $dir}}')
            HY_TLS_MODE="acme"; HY_TLS_SNI="${acme_first}"; HY_TLS_PIN=""
            return 0
            ;;
        *) _warn "无效选择"; return 1 ;;
    esac
}

_hysteria_tls_desc() {
    local mode; mode=$(_hysteria_meta_get tls_mode)
    case "$mode" in
        selfsigned) echo "自签($(_hysteria_meta_get sni))" ;;
        custom)     echo "已有证书($(_hysteria_meta_get sni))" ;;
        acme)       echo "ACME($(_hysteria_meta_get sni))" ;;
        *)          echo "未知" ;;
    esac
}

# 本管理器仅解析单端口/单连续范围；官方 app/v2.13.0 resolveServerListenAddr 支持多段。
_hysteria_listen_port_part() {
    local listen="$1" part
    part="${listen##*:}"
    case "$part" in
        "") return 1 ;;
        *[!0-9-]*) return 1 ;;
    esac
    printf '%s' "$part"
}

# 覆盖所有 UDP 入站能力并兼容旧字段；官方跳跃重定向会劫持范围内 UDP。
_hysteria_xray_udp_port_ranges() {
    _config_present && command -v jq >/dev/null 2>&1 || return 0
    local s e
    while IFS=: read -r s e; do
        [[ "$s" =~ ^[0-9]+$ && "$e" =~ ^[0-9]+$ ]] || continue
        printf '%s:%s\n' "$s" "$e"
    done < <(_config_jq -r '
        .inbounds[]? | select(.port != null)
        | select(
            (.protocol // "") == "hysteria"
            or ((.protocol // "") == "wireguard")
            or ((.streamSettings.network // "") == "mkcp")
            or ((.streamSettings.network // "") == "quic")
            or ((.protocol // "") == "socks" and ((.settings.udp // false) == true))
            or (((.protocol // "") == "dokodemo-door" or (.protocol // "") == "tunnel")
                and (((.settings.allowedNetwork // .settings.network // "tcp") | tostring) | test("udp")))
            or ((.protocol // "") == "shadowsocks"
                and (((.settings.network // "tcp") | tostring) | test("udp")))
          )
        | (.port | tostring) | split(",")[]
        | if test("^[0-9]+-[0-9]+$") then sub("-"; ":")
          elif test("^[0-9]+$") then "\(.):\(.)"
          else empty end
    ' 2>/dev/null)
}

# 只读检查跳跃冲突；官方 binary 自建/清理规则，不混用 Xray DNAT。
_hysteria_check_hop_conflicts() {
    local lo="$1" hi="$2" exclude="${3:-}" p
    [[ "$lo" =~ ^[0-9]+$ ]] && [[ "$hi" =~ ^[0-9]+$ ]] || return 1
    local hit="" udp_snapshot=""
    if command -v ss >/dev/null 2>&1; then
        udp_snapshot=$(ss -lun 2>/dev/null)
    elif command -v netstat >/dev/null 2>&1; then
        udp_snapshot=$(netstat -lnu 2>/dev/null)
    fi
    while read -r p; do
        [ -n "$p" ] || continue
        [ -n "$exclude" ] && [ "$p" = "$exclude" ] && continue
        [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ] && hit="$hit $p"
    done <<< "$(printf '%s\n' "$udp_snapshot" | awk 'NR > 1 {print $4}' | grep -oE '[0-9]+$' | sort -un)"
    [ -n "$hit" ] && { _error "以下端口已被本机监听, 与跳跃范围冲突:$hit"; return 1; }
    if _config_present && command -v jq >/dev/null 2>&1; then
        while IFS=: read -r p_start p_end; do
            [ -n "$p_start" ] || continue
            if [ "$p_start" -le "$hi" ] && [ "$p_end" -ge "$lo" ]; then
                _error "Xray 入站端口范围 ${p_start}-${p_end} 在跳跃范围内, 会造成端口冲突"
                return 1
            fi
        done < <(_hysteria_xray_udp_port_ranges)
    fi
    local f ranges tok s e
    local tok_arr=()
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        ranges=$(_read_hop_ranges "$f")
        [ -n "$ranges" ] || continue
        read -ra tok_arr <<< "$ranges"
        for tok in "${tok_arr[@]}"; do
            s="${tok%%:*}"; e="${tok##*:}"
            [[ "$s" =~ ^[0-9]+$ ]] && [[ "$e" =~ ^[0-9]+$ ]] || continue
            if [ "$s" -le "$hi" ] && [ "$e" -ge "$lo" ]; then
                _error "与 Xray Hy2 节点($(basename "$f" .json))的跳跃范围 ${tok} 相交"
                return 1
            fi
        done
    done
    return 0
}

_hysteria_mimic_enabled() {
    [ -f "$HYSTERIA_CONFIG" ] || return 1
    jq -e '(.mimic.enabled // false) == true' "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

_hysteria_listen_display() {
    local part
    part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null) || { echo "未知"; return; }
    case "$part" in
        *-*) echo "${part%-*}-${part#*-} (端口跳跃)" ;;
        *)   echo "$part" ;;
    esac
}

_hysteria_config_get() {
    local key="$1"
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$HYSTERIA_CONFIG" 2>/dev/null
}

# share_link 现场派生而不回写；避免服务器修改后缓存凭据漂移。
_hysteria_node_link() {
    local meta="${1:-$HYSTERIA_NODE_META}" link
    [ -f "$meta" ] || return 1
    link=$(_hysteria_build_link "$meta") || return 1
    [ -n "$link" ] || return 1
    printf '%s' "$link"
}

# URI 语义缺口不阻断节点操作；clash 是可重建缓存。
_hysteria_rebuild_all_links() {
    local gap
    gap=$(_hysteria_obfs_uri_gap)
    if [ -n "$gap" ]; then
        _warn "分享链接不可生成: ${gap} (clash/mihomo 条目不受影响, 仍会同步)"
    fi
    [ -f "$HYSTERIA_NODE_META" ] || return 0
    if [ -z "$gap" ] && ! _hysteria_node_link "$HYSTERIA_NODE_META" >/dev/null; then
        _warn "分享链接派生失败(节点元数据缺字段?)"
    fi
    _hysteria_sync_clash "$HYSTERIA_NODE_META" || return 1
    return 0
}

_hysteria_port_menu() {
    local choice part lo hi cur_first
    _hysteria_gate || { _press_any_key; return; }
    cur_first=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null)
    cur_first=${cur_first%%-*}   # 跳跃范围下监听的只是首端口
    while true; do
        clear
        echo; echo -e "  ${CYAN}【端口 / 端口跳跃】${NC}"
        echo -e "  当前: ${CYAN}$(_hysteria_listen_display)${NC}"
        echo -e "  ${YELLOW}官方机制: 端口跳跃 = listen 写端口范围, binary 监听首端口并自动重定向其余端口,${NC}"
        echo -e "  ${YELLOW}停止服务时自动清理防火墙规则(与 Xray Hy2 的 iptables 方案相互独立)${NC}"
        echo -e "  ${YELLOW}提示: 手工在 hysteria.json 扩展的高级字段(mimic/ech 等)需满足官方运行要求${NC}"
        echo -e "  ${YELLOW}(如 mimic 需 mimic 程序+内核模块+root); 其中 mimic 与端口跳跃互斥, 本菜单会拒绝该组合${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 修改监听端口"
        echo -e "  ${GREEN}[2]${NC} 启用/修改端口跳跃 (单段连续范围)"
        echo -e "  ${GREEN}[3]${NC} 禁用端口跳跃 (回到单端口)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1)
                read -rp "  新监听端口 (回车取消): " part
                [ -z "$part" ] && { _press_any_key; continue; }
                _validate_port "$part" || { _warn "无效端口(1-65535)"; _press_any_key; continue; }
                _hysteria_check_hop_conflicts "$part" "$part" "$cur_first" || { _press_any_key; continue; }
                if ! _hysteria_config_txn --arg l ":${part}" '.listen = $l'; then
                    _error "端口修改失败"
                else
                    cur_first=$part
                    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败, 可用 [查看节点] 核对"
                    _success "监听端口已修改为 $part"
                fi
                _press_any_key
                ;;
            2)
                read -rp "  跳跃范围 (如 20000-50000, 回车取消): " part
                [ -z "$part" ] && { _press_any_key; continue; }
                [[ "$part" == *","* ]] && { _warn "本管理器仅支持单段连续范围(官方 listen 支持多段)"; _press_any_key; continue; }
                local parsed
                parsed=$(_parse_hop_ranges "$part") || { _press_any_key; continue; }
                lo="${parsed%%:*}"; hi="${parsed##*:}"
                [ "$lo" = "$hi" ] && { _warn "跳跃范围至少两个端口(单端口无需跳跃)"; _press_any_key; continue; }
                if _hysteria_mimic_enabled; then
                    _error "当前配置已启用 mimic, 官方不允许 mimic 与端口跳跃同时启用(Hysteria 会拒绝启动)"
                    _tip "请先关闭 mimic(手工编辑 hysteria.json 的 mimic.enabled)后再启用端口跳跃"
                    _press_any_key; continue
                fi
                _hysteria_check_hop_conflicts "$lo" "$hi" "$cur_first" || { _press_any_key; continue; }
                if ! _hysteria_config_txn --arg l ":${lo}-${hi}" '.listen = $l'; then
                    _error "端口跳跃设置失败"
                else
                    cur_first=$lo
                    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
                    _success "端口跳跃已启用: ${lo}-${hi} (监听 ${lo}, 其余端口自动重定向)"
                    _tip "NAT VPS 请确认宿主已转发该范围 UDP 端口"
                fi
                _press_any_key
                ;;
            3)
                read -rp "  新单端口 (回车取消): " part
                [ -z "$part" ] && { _press_any_key; continue; }
                _validate_port "$part" || { _warn "无效端口"; _press_any_key; continue; }
                _hysteria_check_hop_conflicts "$part" "$part" "$cur_first" || { _press_any_key; continue; }
                if ! _hysteria_config_txn --arg l ":${part}" '.listen = $l'; then
                    _error "修改失败"
                else
                    cur_first=$part
                    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
                    _success "已回到单端口: $part"
                fi
                _press_any_key
                ;;
            0) return 0 ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}

_hysteria_tls_menu() {
    _hysteria_gate || { _press_any_key; return; }
    echo; echo -e "  当前 TLS: ${CYAN}$(_hysteria_tls_desc)${NC}"
    if ! _hysteria_prompt_tls; then
        _info "已取消"
        _press_any_key
        return 0
    fi
    local tls_stage="${HY_TLS_STAGE_DIR:-}"
    if ! _hysteria_tls_server_txn "$tls_stage" --argjson blk "$HY_TLS_JSON" \
         --arg m "$HY_TLS_MODE" --arg s "$HY_TLS_SNI" --arg p "$HY_TLS_PIN" \
         '. + $blk | if $blk | has("tls") then del(.acme) else del(.tls) end' \
         '.tls_mode=$m | .sni=$s | .pin=$p'; then
        [ -n "$tls_stage" ] && [ -d "$tls_stage" ] && _warn "TLS 暂存现场已保留: $tls_stage"
        _error "TLS 设置失败"
        _press_any_key
        return 0
    fi
    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
    _success "TLS 已切换: $(_hysteria_tls_desc)"
    [ "$HY_TLS_MODE" = "selfsigned" ] && _tip "自签证书: 客户端使用 insecure=1, 不验证证书身份"
    [ "$HY_TLS_MODE" = "acme" ] && _tip "ACME 模式: 客户端无需 insecure; 证书由官方核心自动续期"
    _press_any_key
    return 0
}

# gecko 尺寸仅从 gecko 来源继承；salamander 残留字段不应改变切换行为。
_hysteria_obfs_menu() {
    local choice pw pw2 cur_type cur_min cur_max
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【混淆 obfs (salamander / gecko)】${NC}"
    cur_type=$(_hysteria_obfs_get type)
    if [ -n "$cur_type" ]; then
        echo -e "  当前状态: ${GREEN}已启用${NC} (类型: ${CYAN}${cur_type}${NC})"
    else
        echo -e "  当前状态: ${RED}未启用${NC}"
    fi
    echo -e "  ${YELLOW}启用后服务端不再兼容标准 QUIC/HTTP3 连接(官方文档), 客户端必须带相同类型与密码${NC}"
    if [ "$cur_type" = "gecko" ]; then
        case "$(_hysteria_gecko_size_state)" in
            custom)
                echo -e "  ${YELLOW}注意: 当前 gecko 使用自定义分片尺寸($(_hysteria_gecko_size_desc)), 官方 URI 无法携带,${NC}"
                echo -e "  ${YELLOW}分享链接将不生成(避免给出语义不完整的链接); clash/mihomo 条目会带该值${NC}"
                ;;
            invalid)
                echo -e "  ${RED}警告: 当前 gecko 分片尺寸非法($(_hysteria_gecko_size_desc)) ——${NC}"
                echo -e "  ${RED}官方要求 min>=1、max>=min 且 max<=2048, 服务端会拒绝启动, 请修正 hysteria.json${NC}"
                ;;
        esac
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 启用/更换 salamander 混淆密码"
    echo -e "  ${GREEN}[2]${NC} 启用/更换 gecko 混淆密码"
    echo -e "  ${GREEN}[3]${NC} 禁用混淆"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice || return 0
    case "$choice" in
        1|2)
            local otype; [ "$choice" = "2" ] && otype="gecko" || otype="salamander"
            pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " pw2
            pw=${pw2:-$pw}
            _validate_json_text "$pw" || { _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{)"; _press_any_key; return 0; }
            if [ "$otype" = "gecko" ] && [ "$cur_type" = "gecko" ]; then
                cur_min=$(_hysteria_obfs_get min); cur_max=$(_hysteria_obfs_get max)
            else
                cur_min=""; cur_max=""
            fi
            if ! _hysteria_config_txn --arg t "$otype" --arg p "$pw" --arg min "$cur_min" --arg max "$cur_max" \
                 '.obfs = {type: $t}
                          | .obfs[$t] = ({password: $p}
                              + (if $min != "" then {minPacketSize: ($min | tonumber)} else {} end)
                              + (if $max != "" then {maxPacketSize: ($max | tonumber)} else {} end))'; then
                _error "混淆设置失败"
            else
                _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
                _success "混淆已启用 (类型: ${otype})"
            fi
            ;;
        3)
            if ! _hysteria_config_txn 'del(.obfs)'; then
                _error "混淆禁用失败"
            else
                _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
                _success "混淆已禁用"
            fi
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

# 只管理 bandwidth.up/down；disableLossCompensation 与其它手填字段必须保留。
_hysteria_bandwidth_menu() {
    local choice up down cur_up cur_down
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【带宽限制】${NC}"
    echo -e "  ${YELLOW}官方语义: 服务器带宽 = 每客户端收发限速, 仅对 Brutal 拥塞控制生效(BBR/ Reno 不受限);${NC}"
    echo -e "  ${YELLOW}服务器 up=客户端下载方向, down=客户端上传方向; 留空 = 不限${NC}"
    cur_up=$(_hysteria_config_get 'bandwidth.up'); [ "$cur_up" = "null" ] && cur_up=""
    cur_down=$(_hysteria_config_get 'bandwidth.down'); [ "$cur_down" = "null" ] && cur_down=""
    echo -e "  当前: up=${CYAN}${cur_up:-不限}${NC}  down=${CYAN}${cur_down:-不限}${NC}"
    echo
    echo -e "  ${GREEN}[1]${NC} 设置限速"
    echo -e "  ${GREEN}[2]${NC} 清除限速"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice || return 0
    case "$choice" in
        1)
            read -rp "  up (如 100 mbps / 1g, 回车保持): " up
            read -rp "  down (如 100 mbps / 1g, 回车保持): " down
            up=$(_normalize_bandwidth "${up:-$cur_up}")
            down=$(_normalize_bandwidth "${down:-$cur_down}")
            if ! _hysteria_config_txn --arg up "$up" --arg down "$down" \
                 '(if $up != "" then .bandwidth.up = $up else del(.bandwidth.up) end)
                    | (if $down != "" then .bandwidth.down = $down else del(.bandwidth.down) end)
                    | if .bandwidth == {} then del(.bandwidth) else . end'; then
                _error "带宽设置失败"
            else
                _hysteria_rebuild_all_links || _warn "带宽已更新, 但 clash 派生条目同步失败"
                _success "带宽已更新: up=${up:-不限} down=${down:-不限}"
            fi
            ;;
        2)
            if ! _hysteria_config_txn 'del(.bandwidth.up, .bandwidth.down) | if .bandwidth == {} then del(.bandwidth) else . end'; then
                _error "清除失败"
            else
                _hysteria_rebuild_all_links || _warn "带宽限制已清除, 但 clash 派生条目同步失败"
                _success "带宽限制已清除"
            fi
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

# 读取 type/bbrProfile；Full-Server-Config 规定仅非 Brutal 方向生效。
_hysteria_congestion_get() {
    local key="$1"
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    case "$key" in
        type)    _hysteria_config_get 'congestion.type' ;;
        profile) _hysteria_config_get 'congestion.bbrProfile' ;;
    esac
}

_hysteria_congestion_desc() {
    local t p
    t=$(_hysteria_congestion_get type)
    p=$(_hysteria_congestion_get profile)
    case "$t" in
        ""|null) echo "bbr/standard (官方默认, 未写入配置)" ;;
        reno)    echo "reno" ;;
        bbr)     echo "bbr/${p:-standard}" ;;
        *)       echo "${t}(非官方枚举)" ;;
    esac
}

_hysteria_congestion_menu() {
    local choice t p cur_t cur_p
    _hysteria_gate || { _press_any_key; return; }
    cur_t=$(_hysteria_congestion_get type)
    cur_p=$(_hysteria_congestion_get profile)
    while true; do
        clear
        echo; echo -e "  ${CYAN}【拥塞控制 congestion】${NC}"
        echo -e "  ${YELLOW}官方语义: 只有该方向**未使用 Brutal** 时才生效(Brutal 方向由带宽决定, 见 [10]);${NC}"
        echo -e "  ${YELLOW}congestion 是每一端各自的本地配置, 不会通过协议协商${NC}"
        echo -e "  当前: ${CYAN}$(_hysteria_congestion_desc)${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} bbr (Google BBR v1, 官方默认)"
        echo -e "  ${GREEN}[2]${NC} reno (New Reno)"
        echo -e "  ${GREEN}[3]${NC} 恢复官方默认 (删除 congestion 段 = bbr/standard)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1)
                read -rp "  BBR 预设 [1] standard [2] conservative [3] aggressive (回车 standard): " p
                case "$p" in
                    2) p="conservative" ;;
                    3) p="aggressive" ;;
                    *) p="standard" ;;
                esac
                if ! _hysteria_config_txn --arg pr "$p" \
                     '.congestion = {type: "bbr", bbrProfile: $pr}'; then
                    _error "拥塞控制设置失败"
                else
                    cur_t="bbr"; cur_p="$p"
                    _success "拥塞控制已设为 bbr/${p}"
                fi
                _press_any_key
                ;;
            2)
                if ! _hysteria_config_txn '.congestion = {type: "reno"}'; then
                    _error "拥塞控制设置失败"
                else
                    cur_t="reno"; cur_p=""
                    _success "拥塞控制已设为 reno"
                fi
                _press_any_key
                ;;
            3)
                if ! _hysteria_config_txn 'del(.congestion)'; then
                    _error "恢复默认失败"
                else
                    cur_t=""; cur_p=""
                    _success "已恢复官方默认(bbr/standard)"
                fi
                _press_any_key
                ;;
            0) return 0 ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}

_hysteria_masquerade_menu() {
    local choice url content
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【伪装站 masquerade】${NC}"
    echo -e "  ${YELLOW}整段缺省时官方对全部 HTTP 请求返回 404(官方默认); 伪装可降低被主动探测风险${NC}"
    echo
    echo -e "  ${GREEN}[1]${NC} 默认 404 (移除伪装段)"
    echo -e "  ${GREEN}[2]${NC} 反向代理到网站 (proxy)"
    echo -e "  ${GREEN}[3]${NC} 返回固定字符串 (string)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice || return 0
    case "$choice" in
        1)
            if ! _hysteria_config_txn 'del(.masquerade)'; then
                _error "设置失败"
            else
                _success "已恢复官方默认 404"
            fi
            ;;
        2)
            read -rp "  目标网站 URL (如 https://news.ycombinator.com): " url
            [ -z "$url" ] && { _info "已取消"; _press_any_key; return 0; }
            _validate_json_text "$url" || { _error "URL 含非法字符"; _press_any_key; return 0; }
            [[ "$url" == https://* || "$url" == http://* ]] || { _error "URL 须以 http(s):// 开头"; _press_any_key; return 0; }
            if ! _hysteria_config_txn --arg u "$url" \
                 '.masquerade = {type: "proxy", proxy: {url: $u, rewriteHost: true}}'; then
                _error "设置失败"
            else
                _success "伪装已指向 $url"
            fi
            ;;
        3)
            read -rp "  返回内容: " content
            [ -z "$content" ] && { _info "已取消"; _press_any_key; return 0; }
            _validate_json_text "$content" || { _error "内容含非法字符"; _press_any_key; return 0; }
            if ! _hysteria_config_txn --arg c "$content" \
                 '.masquerade = {type: "string", string: {content: $c, statusCode: 200}}'; then
                _error "设置失败"
            else
                _success "伪装字符串已设置"
            fi
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

# plain 归一为空，gecko 数值零归一默认；app/v2.13.0 extras/obfs/gecko.go。
_hysteria_obfs_get() {
    local key="$1"
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    jq -r --arg k "$key" '
        (.obfs // {}) as $o
        | ($o.type // "") as $t
        | if $t == "" then ""
          elif $k == "type"     then (if $t == "plain" then "" else $t end)
          elif $k == "password" then ($o[$t].password // "")
          elif $k == "min"      then (($o[$t].minPacketSize // "") | if . == 0 then 512 else . end | tostring)
          elif $k == "max"      then (($o[$t].maxPacketSize // "") | if . == 0 then 1200 else . end | tostring)
          else "" end' "$HYSTERIA_CONFIG" 2>/dev/null
}

# 先将数值零归一 512/1200 再校验整数与范围；官方 WrapPacketConnGecko 同序。
_hysteria_gecko_size_get() {
    [ -f "$HYSTERIA_CONFIG" ] || { [ "$1" = "state" ] && echo "none"; return 0; }
    jq -r --arg k "$1" '
        (type) as $rt
        | if $rt != "object" then
            (if $k == "state" then "invalid"
             elif $k == "desc" then "顶层配置不是 JSON 对象(实际 \($rt))"
             else "Hysteria 配置无法解析: 顶层不是 JSON 对象(官方配置要求 object)" end)
          else
        (if .obfs == null then {} else .obfs end) as $o
        | if ($o | type) != "object" then
            (if $k == "state" then "invalid"
             elif $k == "desc" then "obfs 段不是对象(实际 \($o | type))"
             else "gecko 混淆配置无法解析: obfs 段不是对象(官方 schema 要求 type 选择器对象)" end)
          elif ($o.type // "") != "gecko" then
            (if $k == "state" then "none" else "" end)
          else
            (if ($o | has("gecko")) then $o.gecko else {} end) as $g
            | if ($g != null and ($g | type) != "object") then
                (if $k == "state" then "invalid"
                 elif $k == "desc" then "gecko 子段不是对象(实际 \($g | type))"
                 else "gecko 混淆配置无法解析: gecko 子段不是对象" end)
              else
                (if $g == null then {} else $g end) as $gg
                | (if ($gg | has("minPacketSize")) then (if $gg.minPacketSize == 0 then 512 else $gg.minPacketSize end) else 512 end) as $mn
                | (if ($gg | has("maxPacketSize")) then (if $gg.maxPacketSize == 0 then 1200 else $gg.maxPacketSize end) else 1200 end) as $mx
                | (if ($mn | type) != "number" then "type"
                   elif ($mx | type) != "number" then "type"
                   elif (($mn | floor) != $mn or ($mx | floor) != $mx) then "frac"
                   elif ($mn < 1 or $mx < 1 or $mn > $mx or $mx > 2048) then "range"
                   elif ($mn == 512 and $mx == 1200) then "default"
                   else "custom" end) as $st
                | (if ($mn | type) == "number" then ($mn | tostring) else ($mn | tojson) end) as $mns
                | (if ($mx | type) == "number" then ($mx | tostring) else ($mx | tojson) end) as $mxs
                | if $k == "state" then
                    (if $st == "default" or $st == "custom" then $st else "invalid" end)
                  elif $k == "desc" then "min=\($mns) max=\($mxs)"
                  else
                    if $st == "type" then
                      "gecko 分片尺寸类型错误(min=\($mns) max=\($mxs)): 官方为 Go int 字段, 服务端会拒绝启动"
                    elif $st == "frac" then
                      "gecko 分片尺寸必须为整数(min=\($mns) max=\($mxs)): 官方字段是 Go int, 分数值会被拒绝启动"
                    elif $st == "range" then
                      "gecko 分片尺寸越界(min=\($mns) max=\($mxs)): 官方要求 min>=1、max>=min 且 max<=2048, 服务端会拒绝启动"
                    elif $st == "custom" then
                      "gecko 使用自定义分片尺寸(min=\($mns) max=\($mxs)), 官方 URI 无对应参数"
                    else "" end
                  end
              end
          end
        end' "$HYSTERIA_CONFIG" 2>/dev/null
}
_hysteria_gecko_size_state() {
    local s
    s=$(_hysteria_gecko_size_get state)
    [ -n "$s" ] && { printf '%s' "$s"; return 0; }
    echo "invalid"
}
_hysteria_gecko_size_desc() {
    _hysteria_gecko_size_get desc
}

# URI-Scheme 无 gecko 尺寸字段；自定义/非法尺寸拒绝 URI，合法自定义可导出 YAML。
_hysteria_obfs_uri_gap() {
    local o_type
    o_type=$(_hysteria_obfs_get type)
    case "$o_type" in
        ""|salamander|gecko) ;;
        *)
            printf 'obfs 类型 "%s" 不受支持(官方 server 接受 plain/salamander/gecko, 本 Manager 只生成后两种), 官方 binary 会拒绝启动' "$o_type"
            return 0
            ;;
    esac
    _hysteria_gecko_size_get why
    return 0
}

# 元数据与 listen 必须可表达；URI 语义缺口由 _hysteria_obfs_uri_gap 单独判定。
_hysteria_link_preflight() {
    local meta="$1" auth name link_addr port_part
    [ -f "$meta" ] || { _error "节点元数据文件不存在: $meta"; return 1; }
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    link_addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    [ -n "$auth" ] && [ -n "$name" ] && [ -n "$link_addr" ] || {
        _error "节点元数据缺少必要字段(auth/name/link_addr), 无法构建链接"
        return 1
    }
    port_part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)") || {
        _error "无法解析 hysteria.json 的 listen: $(_hysteria_config_get listen)"
        return 1
    }
    printf '%s' "$port_part"
}

# 链接只含官方 URI-Scheme 字段；非等价或无有效 pin 时拒绝导出。
_hysteria_build_link() {
    local meta="$1" auth name link_addr port_part gap
    port_part=$(_hysteria_link_preflight "$meta") || return 1
    gap=$(_hysteria_obfs_uri_gap)
    if [ -n "$gap" ]; then
        _warn "分享链接不可生成: ${gap}"
        return 1
    fi
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    link_addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    local link_ip="$link_addr"
    [[ "$link_addr" == *":"* && "$link_addr" != *"["* ]] && link_ip="[${link_addr}]"
    local tls_mode sni params=""
    tls_mode=$(_hysteria_meta_get tls_mode)
    sni=$(_hysteria_meta_get sni)
    if [ "$tls_mode" = "selfsigned" ]; then
        params="insecure=1"
    fi
    [ -n "$sni" ] && params="${params}${params:+&}sni=$(_url_encode "$sni")"
    local o_type o_pw
    o_type=$(_hysteria_obfs_get type)
    if [ -n "$o_type" ]; then
        o_pw=$(_hysteria_obfs_get password)
        params="${params}${params:+&}obfs=$(_url_encode "$o_type")&obfs-password=$(_url_encode "$o_pw")"
    fi
    local link="hysteria2://$(_url_encode "$auth")@${link_ip}:${port_part}/"
    [ -n "$params" ] && link="${link}?${params}"
    link="${link}#$(_url_encode "$name")"
    printf '%s' "$link"
}

_hysteria_print_link() {
    local meta="${1:-$HYSTERIA_NODE_META}" label="${2:-分享链接}" gap link
    gap=$(_hysteria_obfs_uri_gap)
    if [ -n "$gap" ]; then
        _warn "${label}不可生成: ${gap}"
        if [ "$(_hysteria_gecko_size_state)" = "invalid" ]; then
            _tip "该尺寸下服务端根本无法启动, 请先按官方约束修正 $HYSTERIA_CONFIG 的 gecko 分片尺寸"
        else
            _tip "官方 URI 无法表达 gecko 分片尺寸; 请使用 clash/mihomo 配置(可完整表达), 或在客户端手工设置相同尺寸"
        fi
        return 1
    fi
    link=$(_hysteria_build_link "$meta") || { _error "${label}派生失败(服务器配置不完整?)"; return 1; }
    [ -n "$link" ] || { _error "${label}派生失败(结果为空)"; return 1; }
    echo -e "  ${CYAN}${label}:${NC} ${link}"
    return 0
}

# 非法尺寸拒绝 YAML，合法自定义尺寸完整透出；server up/down 对应 client down/up。
_hysteria_clash_line() {
    local meta="${1:-$HYSTERIA_NODE_META}" name addr auth
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] && [ -n "$addr" ] && [ -n "$auth" ] || {
        _error "节点元数据缺少必要字段(name/link_addr/auth), 无法生成 clash 条目"
        return 1
    }
    if [ "$(_hysteria_gecko_size_state)" = "invalid" ]; then
        _error "检测到非法 gecko 分片尺寸($(_hysteria_gecko_size_desc)): 官方要求 min>=1、max>=min 且 max<=2048; 请先修正 $HYSTERIA_CONFIG"
        return 1
    fi
    local o_type o_pw o_min o_max
    o_type=$(_hysteria_obfs_get type)
    if [ -n "$o_type" ]; then
        case "$o_type" in
            salamander|gecko) ;;
            *)
                _error "obfs 类型 \"$o_type\" 不受支持(官方接受 plain/salamander/gecko), 已拒绝生成 clash 条目; 请修正 $HYSTERIA_CONFIG"
                return 1
                ;;
        esac
    fi
    local port_part
    port_part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)") || return 1
    local line="- {name: \"$(_yaml_dq "$name")\", type: hysteria2, server: \"$(_yaml_dq "$addr")\", port: ${port_part%%-*}, password: \"$(_yaml_dq "$auth")\""
    local sni; sni=$(_hysteria_meta_get sni)
    [ -n "$sni" ] && line="${line}, sni: \"$(_yaml_dq "$sni")\""
    if [ "$(_hysteria_meta_get tls_mode)" = "selfsigned" ]; then
        line="${line}, skip-cert-verify: true"
    fi
    if [ -n "$o_type" ]; then
        o_pw=$(_hysteria_obfs_get password)
        line="${line}, obfs: ${o_type}, obfs-password: \"$(_yaml_dq "$o_pw")\""
        o_min=$(_hysteria_obfs_get min)
        o_max=$(_hysteria_obfs_get max)
        [ -n "$o_min" ] && line="${line}, obfs-min-packet-size: ${o_min}"
        [ -n "$o_max" ] && line="${line}, obfs-max-packet-size: ${o_max}"
    fi
    local server_up server_down
    server_up=$(jq -r '.bandwidth.up // empty' "$HYSTERIA_CONFIG" 2>/dev/null)
    server_down=$(jq -r '.bandwidth.down // empty' "$HYSTERIA_CONFIG" 2>/dev/null)
    [ -n "$server_up" ] && line="${line}, down: \"$(_yaml_dq "$server_up")\""
    [ -n "$server_down" ] && line="${line}, up: \"$(_yaml_dq "$server_down")\""
    case "$port_part" in
        *-*) line="${line}, ports: \"${port_part}\"" ;;
    esac
    printf '%s}' "$line"
}

# 共享 clash.yaml 读改写必须持 config lock；避免 Xray/官方节点相互覆盖。
_hysteria_sync_clash() {
    _with_config_lock _hysteria_sync_clash_locked "$@"
}

_hysteria_sync_clash_locked() {
    local meta="$1" old_name="${2:-}" line name
    line=$(_hysteria_clash_line "$meta") || { _warn "clash 条目生成失败, 可手工编辑 ${CLASH_YAML}"; return 1; }
    name=$(jq -r '.name // empty' "$meta")
    [ -n "$name" ] || return 1
    if [ -n "$old_name" ] && [ "$old_name" != "$name" ]; then
        _remove_node_from_yaml_by_name "$old_name" 2>/dev/null || true
    fi
    if [ -f "$CLASH_YAML" ] && grep -qF "name: \"$(_yaml_dq "$name")\"" "$CLASH_YAML" 2>/dev/null; then
        _replace_node_in_yaml "$line" "$name" \
            || { _warn "clash 条目替换失败(clash 为可再生派生缓存, 节点本体不受影响), 可手工编辑 ${CLASH_YAML}"; return 1; }
    else
        _add_node_to_yaml "$line" "$name" \
            || { _warn "clash 条目追加失败(clash 为可再生派生缓存, 节点本体不受影响), 可手工编辑 ${CLASH_YAML}"; return 1; }
    fi
    return 0
}

_hysteria_remove_clash_by_name() {
    local name="$1"
    [ -n "$name" ] || return 0
    _remove_node_from_yaml_by_name "$name" 2>/dev/null \
        || { _warn "clash 条目删除失败(clash 为可再生派生缓存, 节点本体不受影响), 可手工编辑 ${CLASH_YAML}"; return 1; }
    return 0
}

# 按共享节点名称判断冲突；只排除当前官方节点。
_hysteria_name_taken() {
    local name="$1" n f
    if [ -f "$HYSTERIA_NODE_META" ]; then
        n=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null) || n=""
        [ -n "$n" ] && [ "$n" = "$name" ] && return 0
    fi
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$(jq -r '.name // empty' "$f" 2>/dev/null) || n=""
        [ -n "$n" ] && [ "$n" = "$name" ] && return 0
    done
    if [ -f "$CLASH_YAML" ] && grep -qF "name: \"$(_yaml_dq "$name")\"" "$CLASH_YAML" 2>/dev/null; then
        return 0
    fi
    return 1
}

_hysteria_autofill_name() {
    local base="$1" cand="$1" i=2
    while _hysteria_name_taken "$cand"; do
        cand="${base}-${i}"
        i=$((i+1))
    done
    printf '%s' "$cand"
}

_hysteria_default_name() {
    local part
    part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null) || part=""
    part=${part%%-*}
    if [ -n "$part" ]; then
        printf 'HY2-%s' "$part"
    else
        printf 'HY2'
    fi
}

# 提交前从向导 listen 派生默认名；此时配置可能尚不存在。
_hysteria_default_name_for_listen() {
    local listen="$1" part
    part=$(_hysteria_listen_port_part "$listen" 2>/dev/null) || part=""
    part=${part%%-*}
    if [ -n "$part" ]; then
        printf 'HY2-%s' "$part"
    else
        printf 'HY2'
    fi
}

# 非法输入只重问当前字段，EOF 返回失败；不得悄悄修正或重置已确认值。
_hysteria_ask_value_reason() {
    local prompt="$1" reply_var="$2" allow_empty="$3" reason_fn="$4" val="" why
    while true; do
        read -rp "$prompt" val || return 1
        if [ -z "$val" ]; then
            if [ "$allow_empty" = "1" ]; then
                printf -v "$reply_var" '%s' ""
                return 0
            fi
            _error "不能为空"
            continue
        fi
        why=$("$reason_fn" "$val" 2>/dev/null) || why="取值非法"
        [ -z "$why" ] || { _error "$why"; continue; }
        printf -v "$reply_var" '%s' "$val"
        return 0
    done
}

# 本管理器维持单连续范围；官方多段 listen 不在本管理器范围。
_hysteria_hop_reason() {
    local hop="$1" parsed lo hi st en
    [ -n "$hop" ] || { printf '%s' ""; return; }
    case "$hop" in
        *","*) printf '%s' "本管理器仅支持单段连续范围(官方 listen 支持多段)(如 20000-50000), 不接受逗号分隔的多段"; return ;;
    esac
    hop=$(printf '%s' "$hop" | tr -d ' ')
    [ -n "$hop" ] || { printf '%s' ""; return; }
    case "$hop" in
        *","*) printf '%s' "本管理器仅支持单段连续范围(官方 listen 支持多段)(如 20000-50000), 不接受逗号分隔的多段"; return ;;
    esac
    st="${hop%%-*}"; en="${hop##*-}"
    if [ "$st" = "$hop" ]; then
        printf '%s' "跳跃范围需要写成 起始-结束(如 20000-50000); 只填了单个端口 ${hop} —— 单端口不构成跳跃, 直接留空即可"
        return
    fi
    if ! _validate_port "$st" || ! _validate_port "$en"; then
        printf '%s' "端口非法或越界(须为 1-65535): ${hop}"
        return
    fi
    if [ "$st" -gt "$en" ]; then
        printf '%s' "起始端口大于结束端口: ${st} > ${en}(请写成 小-大, 如 ${en}-${st})"
        return
    fi
    if [ "$st" -eq "$en" ]; then
        printf '%s' "跳跃范围至少需要两个端口(${st}-${en} 只有一个端口, 不构成跳跃; 请留空表示不启用)"

        return
    fi
    parsed=$(_parse_hop_ranges "$hop" 2>/dev/null) || { printf '%s' "范围格式非法: ${hop}"; return; }
    lo="${parsed%%:*}"; hi="${parsed##*:}"
    [ -n "$lo" ] && [ -n "$hi" ] || { printf '%s' "范围解析失败, 请写成 起始-结束(如 20000-50000)"; return; }
    printf '%s' ""
}

_hysteria_domain_reason() {
    local d="$1"
    [ -n "$d" ] || { printf '%s' "域名不能为空"; return; }
    _validate_domain "$d" && { printf '%s' ""; return; }
    printf '%s' "域名格式非法(仅字母/数字/连字符, 点分段): ${d}"
}

# StringToBps 只认整数与官方单位；core/server/config.go 允许零，非零须 >=65536 字节/秒。
_hysteria_bandwidth_reason() {
    local v="$1" num unit lunit bps
    [ -n "$v" ] || { printf '%s' ""; return; }
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ -n "$v" ] || { printf '%s' ""; return; }
    case "$v" in
        *[!0-9A-Za-z[:space:]]*) printf '%s' "带宽只能由数字+单位组成(如 100 mbps / 1g); 不支持小数与其它字符"; return ;;
    esac
    num="${v%%[!0-9]*}"
    unit="${v#"$num"}"
    unit="${unit#"${unit%%[![:space:]]*}"}"; unit="${unit%"${unit##*[![:space:]]}"}"
    [ -n "$num" ] || { printf '%s' "带宽缺少数值(如 100 mbps); 纯单位不可用"; return; }
    lunit=$(printf '%s' "$unit" | tr 'A-Z' 'a-z')
    case "$lunit" in
        b|bps|k|kb|kbps|m|mb|mbps|g|gb|gbps|t|tb|tbps) ;;
        "") printf '%s' "带宽缺少单位(官方会报 invalid format); 请写成 100 mbps / 100m 这类形式"; return ;;
        *) printf '%s' "不支持的单位: ${unit}(官方仅认 b/kb/mb/gb/tb 及其 bps 形式)"; return ;;
    esac
    case "$lunit" in
        b|bps) bps=$((num / 8)) ;;
        k|kb|kbps) bps=$((num * 1000 / 8)) ;;
        m|mb|mbps) bps=$((num * 1000000 / 8)) ;;
        g|gb|gbps) bps=$((num * 1000000000 / 8)) ;;
        t|tb|tbps) bps=$((num * 1000000000000 / 8)) ;;
    esac
    if [ "$bps" -ne 0 ] && [ "$bps" -lt 65536 ]; then
        printf '%s' "带宽过小(官方要求 >= 65536 字节/秒, 约 524 kbps); 请填 1 mbps 以上或留空表示不限速"
        return
    fi
    printf '%s' ""
}

# bootstrap 前快照已有 manager 文件；空 stdout 表示原来不存在。
_hysteria_snapshot_file() {
    local file="$1" snap
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
    [ -f "$file" ] && [ ! -L "$file" ] || { _error "初始化目标不是普通文件, 拒绝覆盖: $file"; return 1; }
    snap=$(mktemp "${file}.bootstrap.XXXXXX") || return 1
    if ! cp -p "$file" "$snap" 2>/dev/null || ! cmp -s "$file" "$snap" \
       || ! chmod 600 "$snap" 2>/dev/null; then
        rm -f "$snap"
        _error "初始化回滚快照失败: $file"
        return 1
    fi
    printf '%s' "$snap"
}

_hysteria_restore_snapshot_file() {
    local file="$1" snap="$2" tmp
    if [ -n "$snap" ]; then
        [ -f "$snap" ] || { _error "必需的初始化回滚备份缺失: $snap"; return 1; }
        tmp=$(mktemp "${file}.restore.XXXXXX") || return 1
        if ! cp -p "$snap" "$tmp" 2>/dev/null || ! cmp -s "$snap" "$tmp" \
           || ! mv -f "$tmp" "$file" || ! cmp -s "$snap" "$file"; then
            rm -f "$tmp"
            _error "初始化回滚失败, 保留备份 $snap (目标: $file)"
            return 1
        fi
        return 0
    fi
    rm -f "$file" 2>/dev/null && [ ! -e "$file" ] && [ ! -L "$file" ] || {
        _error "初始化回滚无法移除新建文件: $file"
        return 1
    }
}

# 锁内复核再初始化；失败恢复原文件、证书及三后端原状态。
_hysteria_bootstrap_locked() {
    local config_json="$1" server_meta_json="$2" node_meta_json="$3" stage="$4"
    local server_bak="" node_bak="" tmp_meta="" was_running
    _hysteria_ensure_dirs || return 1
    if [ -e "$HYSTERIA_CONFIG" ] || [ -L "$HYSTERIA_CONFIG" ]; then
        _error "锁内复核发现 Hysteria 配置已存在, 中止 bootstrap, 不覆盖现有配置"
        return 1
    fi
    was_running=$(_hysteria_runtime_state) || return 1
    if [ "$was_running" != "stopped" ]; then
        _error "锁内复核发现官方 Hysteria 仍在运行但配置缺失, 拒绝覆盖运行状态; 请先人工核对服务"
        return 1
    fi
    local node_name
    node_name=$(jq -r '.name // empty' <<< "$node_meta_json" 2>/dev/null) || node_name=""
    [ -n "$node_name" ] || { _error "初始化节点名称无效"; return 1; }
    if _hysteria_name_taken "$node_name"; then
        _error "锁内复核发现名称已存在于共享 Clash 空间: $node_name"
        return 1
    fi
    server_bak=$(_hysteria_snapshot_file "$HYSTERIA_SERVER_META") || return 1
    node_bak=$(_hysteria_snapshot_file "$HYSTERIA_NODE_META") || {
        [ -z "$server_bak" ] || rm -f "$server_bak"
        return 1
    }
    if ! _hysteria_tls_pair_begin "$stage"; then
        _hysteria_tls_pair_finish no "$stage" || _error "TLS 快照/回滚未收敛, 请人工核对"
        [ -z "$server_bak" ] || rm -f "$server_bak"
        [ -z "$node_bak" ] || rm -f "$node_bak"
        return 1
    fi
    _hysteria_bootstrap_rollback() {
        local reason="$1" cfg_ok=0 server_ok=0 node_ok=0 tls_ok=0
        [ -z "$tmp_meta" ] || rm -f "$tmp_meta"
        _hysteria_restore_snapshot_file "$HYSTERIA_CONFIG" "" && cfg_ok=1
        _hysteria_restore_snapshot_file "$HYSTERIA_SERVER_META" "$server_bak" && server_ok=1
        _hysteria_restore_snapshot_file "$HYSTERIA_NODE_META" "$node_bak" && node_ok=1
        if [ -n "$stage" ]; then
            _hysteria_tls_pair_finish no "$stage" && tls_ok=1
        else
            tls_ok=1
        fi
        if [ "$cfg_ok" -eq 1 ] && [ "$server_ok" -eq 1 ] && [ "$node_ok" -eq 1 ] && [ "$tls_ok" -eq 1 ]; then
            [ -z "$server_bak" ] || rm -f "$server_bak" 2>/dev/null || _warn "初始化快照清理失败: $server_bak"
            [ -z "$node_bak" ] || rm -f "$node_bak" 2>/dev/null || _warn "初始化快照清理失败: $node_bak"
            if [ "$reason" = "配置写入失败" ]; then
                _error "配置写入失败, 已取消初始化"
            else
                _error "$reason, 初始化文件已回滚"
            fi
        else
            _error "$reason, 初始化回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) server_meta=$([ "$server_ok" -eq 1 ] && echo 已还原 || echo 失败) node_meta=$([ "$node_ok" -eq 1 ] && echo 已还原 || echo 失败) TLS=$([ "$tls_ok" -eq 1 ] && echo 已还原 || echo 失败))"
            _tip "请人工核对 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META; 保留的快照请勿删除: ${server_bak:-无} ${node_bak:-无} ${HYSTERIA_TLS_SNAPSHOT_DIR:-}"
        fi
        return 1
    }
    if ! _atomic_write_json "$HYSTERIA_CONFIG" "$config_json"; then
        _hysteria_bootstrap_rollback "配置写入失败"
        return 1
    fi
    if ! _atomic_write_json "$HYSTERIA_SERVER_META" "$server_meta_json"; then
        _hysteria_bootstrap_rollback "服务器元数据写入失败"
        return 1
    fi
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || {
        _hysteria_bootstrap_rollback "临时节点元数据创建失败"
        return 1
    }
    if ! _atomic_write_json "$tmp_meta" "$node_meta_json" \
       || ! _hysteria_link_preflight "$tmp_meta" >/dev/null; then
        _hysteria_bootstrap_rollback "节点元数据预检失败"
        return 1
    fi
    if ! _atomic_write_json "$HYSTERIA_NODE_META" "$node_meta_json"; then
        _hysteria_bootstrap_rollback "节点元数据写入失败"
        return 1
    fi
    rm -f "$tmp_meta"; tmp_meta=""
    if ! _hysteria_create_service; then
        _error "service 创建失败(daemon-reload/权限?), 回滚初始化"
        if ! _hysteria_cleanup_service_units; then
            _error "service 定义清理失败, 保留配置/元数据/TLS快照供人工恢复"
            _tip "请人工清理 service 后核对 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META; 快照: ${server_bak:-无} ${node_bak:-无} ${HYSTERIA_TLS_SNAPSHOT_DIR:-}"
            return 1
        fi
        rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
        _hysteria_bootstrap_rollback "service 创建失败"
        return 1
    fi
    if [ "$INIT_SYSTEM" != "direct" ]; then
        if ! _hysteria_restart_verified \
           && ! _hysteria_avx_runtime_retry "$(_hysteria_cached_version)" "$(_state_get hysteria_asset 2>/dev/null)"; then
            _error "Hysteria 服务启动失败, 回滚初始化"
            if ! _hysteria_stop_and_verify; then
                _error "服务未能确认停止, 保留配置/元数据/TLS及回滚快照, 拒绝删除现场"
                _tip "请人工核对 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META; 快照: ${server_bak:-无} ${node_bak:-无} ${HYSTERIA_TLS_SNAPSHOT_DIR:-}"
                return 1
            fi
            if ! _hysteria_cleanup_service_units; then
                _error "service 定义清理失败, 保留配置/元数据/TLS及回滚快照供人工恢复"
                _tip "请人工核对 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META; 快照: ${server_bak:-无} ${node_bak:-无} ${HYSTERIA_TLS_SNAPSHOT_DIR:-}"
                return 1
            fi
            rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
            _hysteria_bootstrap_rollback "服务启动失败"
            return 1
        fi
    else
        if ! _manage_hysteria start; then
            if ! _hysteria_avx_runtime_retry "$(_hysteria_cached_version)" "$(_state_get hysteria_asset 2>/dev/null)"; then
                _error "Hysteria 启动失败, 回滚初始化"
                if ! _hysteria_stop_and_verify; then
                    _error "服务未能确认停止, 保留配置/元数据/TLS及回滚快照, 拒绝删除现场"
                    _tip "请人工核对 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META; 快照: ${server_bak:-无} ${node_bak:-无} ${HYSTERIA_TLS_SNAPSHOT_DIR:-}"
                    return 1
                fi
                _hysteria_bootstrap_rollback "服务启动失败"
                return 1
            fi
        fi
    fi
    if [ -n "$stage" ]; then _hysteria_tls_pair_finish yes "$stage" || return 1; fi
    [ -z "$server_bak" ] || rm -f "$server_bak" 2>/dev/null || _warn "初始化快照清理失败: $server_bak"
    [ -z "$node_bak" ] || rm -f "$node_bak" 2>/dev/null || _warn "初始化快照清理失败: $node_bak"
    _hysteria_sync_clash "$HYSTERIA_NODE_META" || true
    return 0
}

# 外来配置不接管；向导错误仅重问本字段，提交走锁内事务。
_hysteria_bootstrap() {
    local port hop parsed lo hi listen tls_json tls_mode tls_sni tls_pin
    local obfs_pw="" obfs_type="" masq_url="" up="" down="" addr
    local auth name def_name cc_type cc_profile
    local why ans
    echo; echo -e "  ${CYAN}=== 初始化官方 Hysteria2 服务器 ===${NC}"
    _tip "官方架构: 单服务单密码; 以下为服务器级设置, 认证密码即客户端唯一凭据"

    if _hysteria_config_exists && ! _hysteria_server_initialized; then
        _error "检测到现有 Hysteria 官方配置($HYSTERIA_CONFIG), 其 auth 不是本 Manager 管理的 password 模式"
        _tip "为防止覆盖现有配置, 已取消初始化; 如需接管请自行备份并手工转换 auth 段, 或确认无用后删除该配置再重试"
        return 1
    fi

    if ! _hysteria_installed; then
        local ans
        read -rp "  官方核心未安装, 立即下载安装最新版? [Y/n]: " ans
        case "$ans" in
            n|N) _info "已取消初始化"; return 1 ;;
        esac
        _hysteria_download_install latest || return 1
    fi

    local def_port
    def_port=$(_gen_random_port)
    while true; do
        read -rp "  监听端口 (回车随机生成): " port || return 1
        if [ -z "$port" ]; then
            port="$def_port"
            _info "已随机分配监听端口: ${port}"
        fi
        _validate_port "$port" || { _warn "无效端口(1-65535)"; continue; }
        _hysteria_check_hop_conflicts "$port" "$port" || { def_port=$(_gen_random_port); continue; }
        break
    done
    while true; do
        read -rp "  端口跳跃范围 (如 20000-50000, 回车不启用): " hop || return 1
        [ -z "$hop" ] && break
        why=$(_hysteria_hop_reason "$hop")
        [ -z "$why" ] || { _error "$why"; continue; }
        hop=$(printf '%s' "$hop" | tr -d ' ')
        parsed=$(_parse_hop_ranges "$hop" 2>/dev/null) || { _error "范围解析失败: $hop"; continue; }
        lo="${parsed%%:*}"; hi="${parsed##*:}"
        if _hysteria_mimic_enabled; then
            _error "配置已启用 mimic, 官方不允许 mimic 与端口跳跃同时启用(请先关闭 hysteria.json 的 mimic.enabled, 或留空不启用跳跃)"
            continue
        fi
        if [ "$lo" -le "$port" ] && [ "$port" -le "$hi" ]; then
            break
        fi
        _warn "官方机制下监听端口=范围首端口(${lo}), 输入的 $port 将被范围取代"
        read -rp "  使用范围 ${lo}-${hi} (监听 ${lo})? [y/N]: " ans || return 1
        case "$ans" in
            y|Y) port="$lo"; break ;;
            *) _error "已放弃该范围, 请重新输入跳跃范围(留空 = 不启用跳跃)"; continue ;;
        esac
    done
    if [ -n "$hop" ]; then
        while ! _hysteria_check_hop_conflicts "$lo" "$hi"; do
            read -rp "  端口跳跃范围 (回车不启用跳跃): " hop || return 1
            [ -z "$hop" ] && { hop=""; break; }
            why=$(_hysteria_hop_reason "$hop")
            [ -z "$why" ] || { _error "$why"; continue; }
            hop=$(printf '%s' "$hop" | tr -d ' ')
            parsed=$(_parse_hop_ranges "$hop" 2>/dev/null) || { _error "范围解析失败: $hop"; continue; }
            lo="${parsed%%:*}"; hi="${parsed##*:}"
        done
        if [ -n "$hop" ]; then
            listen=":${lo}-${hi}"
        else
            listen=":${port}"
        fi
    else
        listen=":${port}"
    fi

    if ! _hysteria_prompt_tls; then _info "已取消"; return 1; fi
    tls_json="$HY_TLS_JSON"; tls_mode="$HY_TLS_MODE"; tls_sni="$HY_TLS_SNI"; tls_pin="$HY_TLS_PIN"

    local ans2=""
    while true; do
        read -rp "  启用混淆? [1] salamander [2] gecko [3] 不启用 (回车不启用): " ans2 || return 1
        case "$ans2" in
            1|y|Y) obfs_type="salamander"; break ;;
            2) obfs_type="gecko"; break ;;
            3|n|N|"") obfs_type=""; break ;;
            *) _error "无效选择: ${ans2}(可选 1/2/3, 回车或 n 表示不启用)" ;;
        esac
    done
    if [ -n "$obfs_type" ]; then
        obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
        while true; do
            read -rp "  混淆密码 (回车随机): " ans2 || return 1
            [ -n "$ans2" ] && obfs_pw="$ans2"
            _validate_json_text "$obfs_pw" && break
            _error "混淆密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"
            obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
        done
    fi

    _hysteria_ask_value_reason "  上行限速 (如 100 mbps / 1g, 回车不限): " up 1 _hysteria_bandwidth_reason || return 1
    _hysteria_ask_value_reason "  下行限速 (如 100 mbps / 1g, 回车不限): " down 1 _hysteria_bandwidth_reason || return 1
    up=$(_normalize_bandwidth "$up"); down=$(_normalize_bandwidth "$down")

    echo -e "  拥塞控制 (非 Brutal 方向生效; 回车用官方默认 bbr/standard):"
    while true; do
        read -rp "  类型 [1] bbr [2] reno (回车 bbr): " cc_type || return 1
        case "$cc_type" in
            ""|1) cc_type="bbr"; break ;;
            2) cc_type="reno"; break ;;
            *) _error "无效选择: ${cc_type}(可选 1/2, 回车用官方默认 bbr)" ;;
        esac
    done
    cc_profile=""
    if [ "$cc_type" = "bbr" ]; then
        while true; do
            read -rp "  BBR 预设 [1] standard [2] conservative [3] aggressive (回车 standard): " cc_profile || return 1
            case "$cc_profile" in
                ""|1) cc_profile="standard"; break ;;
                2) cc_profile="conservative"; break ;;
                3) cc_profile="aggressive"; break ;;
                *) _error "无效选择: ${cc_profile}(可选 1-3, 回车用官方默认 standard)" ;;
            esac
        done
    fi

    while true; do
        read -rp "  伪装站 URL (必须包含 http:// 或 https://; 如 https://example.com, 回车用官方默认 404): " masq_url || return 1
        [ -z "$masq_url" ] && break
        if ! _validate_json_text "$masq_url"; then
            _error "URL 含非法字符(双引号/反斜杠/换行/制表符或 {{)"
            continue
        fi
        case "$masq_url" in
            https://*|http://*) break ;;
            *) _error "URL 须以 http:// 或 https:// 开头(不能只填 example.com); 如 https://example.com" ;;
        esac
    done

    addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址, 已取消初始化"; return 1; }

    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    while true; do
        read -rp "  认证密码 (回车随机): " ans2 || return 1
        [ -n "$ans2" ] && auth="$ans2"
        _validate_json_text "$auth" && break
        _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"
        auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    done
    def_name=$(_hysteria_default_name_for_listen "$listen")
    while true; do
        read -rp "  节点名称 (回车默认 ${def_name}): " ans2 || return 1
        name=${ans2:-$def_name}
        if ! _validate_json_text "$name"; then
            _error "名称含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"
            continue
        fi
        if _hysteria_name_taken "$name"; then
            if [ "$name" = "$def_name" ]; then
                name=$(_hysteria_autofill_name "$def_name")
                _tip "默认名已被占用, 自动命名为 ${name}"
                break
            fi
            _error "节点名称已存在: ${name}(请换一个名字)"
            continue
        fi
        break
    done

    local config_json
    config_json=$(jq -n \
        --arg listen "$listen" --argjson tlsblk "$tls_json" \
        --arg obfspw "$obfs_pw" --arg obfstype "$obfs_type" \
        --arg up "$up" --arg down "$down" --arg masqurl "$masq_url" \
        --arg p "$auth" \
        --arg cctype "$cc_type" --arg ccprofile "$cc_profile" \
        '{listen: $listen}
         + $tlsblk
         + {auth: {type: "password", password: $p}}
         + (if $obfspw != "" then
              {obfs: ({type: $obfstype} | .[$obfstype] = {password: $obfspw})}
            else {} end)
         + (if ($up != "" or $down != "") then
              {bandwidth: ((if $up != "" then {up: $up} else {} end)
                           + (if $down != "" then {down: $down} else {} end))}
            else {} end)
         + (if $cctype == "reno" then {congestion: {type: "reno"}}
            elif $cctype == "bbr" and $ccprofile != "standard" then
              {congestion: {type: "bbr", bbrProfile: $ccprofile}}
            else {} end)
         + (if $masqurl != "" then
              {masquerade: {type: "proxy", proxy: {url: $masqurl, rewriteHost: true}}}
            else {} end)') || { _error "配置组装失败"; return 1; }
    jq -e '.auth.type == "password" and (.auth.password | length) > 0' <<< "$config_json" >/dev/null || {
        _error "配置组装异常(auth.password 为空), 已中止"
        return 1
    }
    local server_meta_json node_meta_json stage="${HY_TLS_STAGE_DIR:-}"
    server_meta_json=$(jq -n --arg a "$addr" --arg m "$tls_mode" --arg s "$tls_sni" \
        --arg p "$tls_pin" --arg c "$(date '+%Y-%m-%d')" \
        '{link_addr:$a, tls_mode:$m, sni:$s, pin:$p, created:$c}') || {
        _error "服务器元数据组装失败"
        return 1
    }
    node_meta_json=$(jq -n --arg a "$auth" --arg n "$name" --arg addr "$addr" \
        --arg created "$(date '+%Y-%m-%d')" \
        '{auth:$a,name:$n,link_addr:$addr,created:$created}') || {
        _error "节点元数据组装失败"
        return 1
    }
    if ! _with_config_lock _hysteria_bootstrap_locked "$config_json" "$server_meta_json" "$node_meta_json" "$stage"; then
        [ -z "$stage" ] || [ ! -d "$stage" ] || _warn "自签 TLS 暂存现场保留供核对: $stage"
        return 1
    fi
    _success "官方 Hysteria2 服务器已初始化: $(_hysteria_listen_display), TLS=$(_hysteria_tls_desc)"
    _hysteria_print_link "$HYSTERIA_NODE_META" || true
    return 0
}

# 接管已有 password 配置只建元数据；不改变用户正在使用的认证。
_hysteria_adopt_node_locked() {
    local meta_json="$1" auth="$2" addr="$3" addr_need_save="$4" repair_broken="$5" tmp_meta node_name
    _hysteria_gate || return 1
    _hysteria_server_initialized || { _error "锁内复核发现服务器不再处于可接管状态, 请重试"; return 1; }
    if _hysteria_node_exists; then
        _error "锁内复核发现节点已被其他会话接管, 未覆盖现有元数据"
        return 1
    fi
    if _hysteria_node_file_present; then
        if [ "$repair_broken" != "1" ] || ! _hysteria_node_broken; then
            _error "锁内复核发现节点元数据状态已变化, 未覆盖: $HYSTERIA_NODE_META"
            return 1
        fi
    fi
    if [ "$(_hysteria_config_password)" != "$auth" ]; then
        _error "锁内复核发现服务器认证密码已变化, 取消接管以免写入过期凭据"
        return 1
    fi
    node_name=$(jq -r '.name // empty' <<< "$meta_json" 2>/dev/null) || node_name=""
    [ -n "$node_name" ] || { _error "节点名称无效"; return 1; }
    if _hysteria_name_taken "$node_name"; then
        _error "锁内复核发现名称已占用共享 Clash 空间: $node_name"
        return 1
    fi
    if [ "$addr_need_save" -eq 1 ] && [ -n "$(_hysteria_meta_get link_addr)" ]; then
        _error "连接地址已被其他会话更新, 拒绝提交过期节点地址; 请重试"
        return 1
    fi
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || {
        _error "临时节点元数据创建失败, 节点未创建"
        return 1
    }
    if ! _atomic_write_json "$tmp_meta" "$meta_json" \
       || ! _hysteria_link_preflight "$tmp_meta" >/dev/null; then
        rm -f "$tmp_meta"
        _error "锁内分享链接预检失败, 节点未创建"
        return 1
    fi
    rm -f "$tmp_meta"
    if ! _atomic_write_json "$HYSTERIA_NODE_META" "$meta_json"; then
        _error "节点元数据写入失败, 节点未创建"
        return 1
    fi
    if [ "$addr_need_save" -eq 1 ]; then
        _hysteria_meta_set link_addr "$addr" \
            || _warn "连接地址未同步到 server_meta(节点已创建, 连接地址已保存在节点元数据中, 不影响链接与 clash 条目)"
    fi
    _hysteria_sync_clash "$HYSTERIA_NODE_META" || _warn "clash 条目同步失败(可手工编辑 ${CLASH_YAML})"
}

_hysteria_add_node() {
    local auth name meta_json addr repair_broken=0
    _hysteria_ensure_dirs || return 1
    if ! _hysteria_server_initialized; then
        _hysteria_bootstrap
        return $?
    fi
    echo; echo -e "  ${CYAN}=== 添加 Hysteria2 (官方) 节点 ===${NC}"
    if _hysteria_node_exists; then
        _warn "官方 password 模式只支持**一个**认证密码, 服务器已有节点(认证凭据已存在)"
        _tip "如需更换认证密码请用 [5] 修改节点密码; 如需多套独立凭据请分别部署多台服务器"
        _press_any_key
        return 0
    fi
    if _hysteria_node_broken; then
        _warn "节点元数据已损坏(无法解析或缺少必要字段): $HYSTERIA_NODE_META"
        _tip "重建不会改动服务器认证密码, 只重写 Manager 侧的节点记录/链接/clash 条目"
        local ans_repair
        read -rp "  删除损坏的节点元数据并重建? [y/N]: " ans_repair
        case "$ans_repair" in
            y|Y) ;;
            *) _info "已取消(损坏文件保留, 可手工核对后重试)"; _press_any_key; return 0 ;;
        esac
        repair_broken=1
        _info "确认后将在锁内以新节点元数据原子替换损坏记录"
    fi
    auth=$(_hysteria_config_password)
    if [ -z "$auth" ]; then
        _error "无法读取 hysteria.json 的认证密码, 已取消(请检查 $HYSTERIA_CONFIG 的 auth 段)"
        _press_any_key
        return 1
    fi
    _tip "服务器已有认证凭据(手工部署或此前删除过节点记录), 将按现有密码重建节点"
    _tip "认证密码保持不变(不会使已分发的链接失效)"
    local def_name
    def_name=$(_hysteria_default_name)
    read -rp "  节点名称 (回车默认 ${def_name}): " name
    name=${name:-$def_name}
    _validate_json_text "$name" || { _error "名称含非法字符"; _press_any_key; return 1; }
    if _hysteria_name_taken "$name"; then
        [ "$name" = "$def_name" ] || { _error "节点名称已存在: ${name}"; _press_any_key; return 1; }
        name=$(_hysteria_autofill_name "$def_name")
        _tip "默认名已被占用, 自动命名为 ${name}"
    fi
    local addr_need_save=0
    addr=$(_hysteria_meta_get link_addr)
    if [ -z "$addr" ]; then
        addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址, 已取消"; _press_any_key; return 1; }
        addr_need_save=1
    else
        _info "沿用已有客户端连接地址: ${addr}"
    fi
    meta_json=$(jq -n --arg a "$auth" --arg n "$name" --arg ad "$addr" \
        --arg created "$(date '+%Y-%m-%d')" \
        '{auth:$a,name:$n,link_addr:$ad,created:$created}') || {
        _error "节点元数据组装失败"
        _press_any_key
        return 1
    }
    if ! _with_config_lock _hysteria_adopt_node_locked \
        "$meta_json" "$auth" "$addr" "$addr_need_save" "$repair_broken"; then
        _press_any_key
        return 1
    fi
    _success "节点 [${name}] 已接管(认证密码沿用服务器现有值)"
    _hysteria_print_link "$HYSTERIA_NODE_META" || true
    _press_any_key
    return 0
}

_hysteria_view_nodes() {
    clear
    echo; echo -e "  ${CYAN}【Hysteria2 (官方) 节点】${NC}"
    if ! _hysteria_gate; then
        _press_any_key
        return 0
    fi
    echo -e "  服务器: $(_hysteria_listen_display)  TLS: $(_hysteria_tls_desc)  状态: $(_manage_hysteria status 2>/dev/null)"
    local gap; gap=$(_hysteria_obfs_uri_gap)
    if [ -n "$gap" ]; then
        _warn "分享链接不可生成: ${gap}"
        echo -e "  ${YELLOW}clash/mihomo 配置可完整表达该尺寸; 手工客户端请自行设置相同分片尺寸${NC}"
    fi
    echo
    if _hysteria_node_broken; then
        _error "节点元数据已损坏(无法解析或缺少必要字段): $HYSTERIA_NODE_META"
        _tip "请用 [2] 添加节点 删除损坏记录并按服务器现有密码重建(认证密码不变)"
        _press_any_key
        return 0
    fi
    if ! _hysteria_node_exists; then
        if _hysteria_server_initialized; then
            _warn "Manager 侧暂无节点记录, 但服务器已有认证凭据(手工部署或此前只清除了记录)"
            _tip "用 [2] 添加节点 可按现有密码重建记录(认证密码不变)"
        else
            _warn "暂无节点(请用 [2] 添加节点 初始化)"
        fi
        _press_any_key
        return 0
    fi
    local name auth link
    name=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null)
    echo -e "  ${GREEN}[1]${NC} ${name}"
    echo -e "      认证密码: ${CYAN}$(jq -r '.auth // empty' "$HYSTERIA_NODE_META" 2>/dev/null)${NC}"
    if [ -n "$gap" ]; then
        echo -e "      ${YELLOW}(分享链接不可生成, 见上方说明)${NC}"
        _press_any_key
        return 0
    fi
    link=$(_hysteria_node_link "$HYSTERIA_NODE_META") || link=""
    if [ -n "$link" ]; then
        echo -e "      ${link}"
    else
        _warn "分享链接派生失败(节点元数据缺字段? 请用 [2] 重新初始化或核对 $HYSTERIA_NODE_META)"
    fi
    _press_any_key
    return 0
}

# 停服→删 config→删 node→清 unit/clash；删 config 失败须保留 unit 以恢复原状态。
_hysteria_delete_node_locked() {
    local name="" was_running
    _hysteria_gate || return 1
    if ! _hysteria_config_exists; then
        _error "锁内复核发现服务器配置已不存在, 不执行删除"
        return 1
    fi
    if _hysteria_node_file_present; then
        if _hysteria_node_exists; then
            name=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null)
        else
            _warn "节点元数据已损坏(无法解析或缺少必要字段), 读不到节点名"
        fi
    fi
    [ -n "$name" ] || _warn "无法确定原节点名称, 未能自动清理 clash 派生条目(如需清理请手工编辑 ${CLASH_YAML})"
    was_running=$(_hysteria_runtime_state) || return 1
    if ! _hysteria_stop_and_verify; then
        _error "服务未能停止或 supervisor 状态未知(进程/证据未清除), 已中止(配置未删除)"
        _tip "请先解决服务状态后重试; hysteria.json 与 OpenRC pidfile 均已保留"
        return 1
    fi
    if ! rm -f "$HYSTERIA_CONFIG" || [ -e "$HYSTERIA_CONFIG" ] || [ -L "$HYSTERIA_CONFIG" ]; then
        _error "服务器配置删除失败(权限/只读?), 已中止"
        _tip "请人工核对: $HYSTERIA_CONFIG"
        _hysteria_recover_to_state "$was_running" || _warn "原运行状态恢复失败, 请人工检查服务状态"
        return 1
    fi
    if ! rm -f "$HYSTERIA_NODE_META"; then
        _warn "节点记录删除失败(权限/只读?): $HYSTERIA_NODE_META"
        _tip "服务器配置已删除; 下次用 [2] 添加节点 会重新初始化服务器并重新生成节点记录"
        _tip "如需立即清除该残留记录, 可手工删除: $HYSTERIA_NODE_META"
    fi
    _hysteria_cleanup_service_units \
        || _warn "service 定义清理失败(配置已删除, 服务已停止): 残留 unit 可能在下次开机尝试启动并失败, 请按上方提示人工清理"
    [ -n "$name" ] && { _hysteria_remove_clash_by_name "$name" || true; }
    _success "服务器配置已删除, 服务已停止(核心 binary 保留)"
}

_hysteria_delete_node() {
    local name="" ans
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【删除 Hysteria2 (官方) 服务器配置】${NC}"
    if ! _hysteria_config_exists; then
        _warn "暂无服务器配置(未初始化)"
        _press_any_key
        return
    fi
    if _hysteria_node_file_present; then
        if _hysteria_node_exists; then
            name=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null)
        else
            _warn "节点元数据已损坏(无法解析或缺少必要字段), 读不到节点名"
        fi
    fi
    [ -n "$name" ] || _warn "无法确定原节点名称, 未能自动清理 clash 派生条目(如需清理请手工编辑 ${CLASH_YAML})"
    echo -e "  服务器: $(_hysteria_listen_display)  TLS: $(_hysteria_tls_desc)  状态: $(_manage_hysteria status 2>/dev/null)"
    if [ -n "$name" ]; then
        echo -e "  节点: ${GREEN}${name}${NC}"
    else
        echo -e "  节点: ${YELLOW}(Manager 侧无节点记录, 仅删除服务器配置)${NC}"
    fi
    echo -e "  ${YELLOW}将停止 Hysteria 服务并删除服务器配置(${HYSTERIA_CONFIG})${NC}"
    echo -e "  ${YELLOW}所有已分发的分享链接/客户端配置会立即失效${NC}"
    echo -e "  ${CYAN}核心 binary 与 server_meta/证书保留; 之后可用 [2] 添加节点 重新初始化${NC}"
    echo -e "  ${YELLOW}如需连核心一并移除请用 [14] 卸载 Hysteria${NC}"
    read -rp "  确认删除服务器配置并停止服务? [y/N]: " ans || return 0
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; _press_any_key; return ;;
    esac
    if ! _with_config_lock _hysteria_delete_node_locked; then
        _press_any_key
        return 1
    fi
    _press_any_key
    return 0
}

_hysteria_change_password() {
    local auth auth2 name meta_json
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【修改节点密码】${NC}"
    if ! _hysteria_node_exists; then
        if _hysteria_node_broken; then
            _error "节点元数据已损坏(无法解析或缺少必要字段), 无法改密码"
            _tip "请用 [2] 添加节点 删除损坏记录并重建(认证密码不变)"
        else
            _warn "暂无节点(请用 [2] 添加节点 初始化)"
        fi
        _press_any_key
        return
    fi
    name=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null)
    echo -e "  节点: ${GREEN}${name}${NC}"
    echo -e "  ${YELLOW}改密码会让所有已分发的分享链接/客户端配置立即失效, 需重新分发${NC}"
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  新密码 (回车随机): " auth2
    auth=${auth2:-$auth}
    _validate_json_text "$auth" || { _error "密码含非法字符"; _press_any_key; return; }
    local tmp_meta
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || { _error "临时文件创建失败"; _press_any_key; return; }
    if ! jq --arg p "$auth" '.auth=$p | del(.share_link)' "$HYSTERIA_NODE_META" > "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta"; _error "元数据构建失败"; _press_any_key; return
    fi
    if ! _hysteria_link_preflight "$tmp_meta" >/dev/null; then
        rm -f "$tmp_meta"; _error "分享链接预检失败(服务器配置不完整?), 未修改"; _press_any_key; return
    fi
    meta_json=$(cat "$tmp_meta") || { rm -f "$tmp_meta"; _error "元数据读取失败"; _press_any_key; return; }
    rm -f "$tmp_meta"
    if ! _hysteria_node_txn --arg p "$auth" \
        '.auth = {type: "password", password: $p}' "$HYSTERIA_NODE_META" create "$meta_json"; then
        _error "密码修改失败"
        _press_any_key
        return
    fi
    _success "密码已修改"
    _hysteria_print_link "$HYSTERIA_NODE_META" "新分享链接" || true
    _press_any_key
    return 0
}

_hysteria_service_menu() {
    local choice
    clear
    echo; echo -e "  ${CYAN}【服务管理】${NC}"
    local svc_state; svc_state=$(_manage_hysteria status 2>/dev/null)
    case "$svc_state" in
        running) echo -e "  状态: ${GREEN}运行中${NC}  (init: ${INIT_SYSTEM})" ;;
        stopped) echo -e "  状态: ${RED}已停止${NC}  (init: ${INIT_SYSTEM})" ;;
        *) echo -e "  状态: ${YELLOW}未知(保留服务证据)${NC}  (init: ${INIT_SYSTEM})" ;;
    esac
    echo
    echo -e "  ${GREEN}[1]${NC} 启动"
    echo -e "  ${GREEN}[2]${NC} 停止"
    echo -e "  ${GREEN}[3]${NC} 重启"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice || return 0
    case "$choice" in
        1) _manage_hysteria start && _success "已启动" || _error "启动失败(查看日志)" ;;
        2) _manage_hysteria stop && _success "已停止" ;;
        3)
            if _hysteria_restart_verified; then
                _success "已重启并稳定运行"
            else
                _error "重启后未稳定运行, 请查看日志"
            fi
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

_hysteria_view_log() {
    clear
    echo; echo -e "  ${CYAN}【Hysteria2 (官方) 日志】${NC}"
    case "$INIT_SYSTEM" in
        systemd) journalctl -u "$HYSTERIA_SVC" --no-pager -n 30 2>/dev/null || _warn "journal 不可用" ;;
        *)
            if [ -f "$HYSTERIA_LOG_FILE" ]; then
                tail -n 30 "$HYSTERIA_LOG_FILE"
            else
                _warn "暂无日志文件: $HYSTERIA_LOG_FILE"
            fi
            ;;
    esac
    _press_any_key
    return 0
}

# 停止需终态、MainPID=0 且无归属进程；不可使用 !is_running 猜测。
_hysteria_stopped_state() {
    case "$INIT_SYSTEM" in
        systemd)
            local active mainpid
            active=$(systemctl show -p ActiveState --value "$HYSTERIA_SVC" 2>/dev/null)
            case "$active" in
                inactive|failed) ;;
                *) return 1 ;;
            esac
            mainpid=$(systemctl show -p MainPID --value "$HYSTERIA_SVC" 2>/dev/null)
            [ "$mainpid" = "0" ] || return 1
            _proc_any_named hysteria "$HYSTERIA_BIN" && return 1
            return 0
            ;;
        openrc)
            { [ ! -e "$HYSTERIA_PID_FILE" ] && [ ! -L "$HYSTERIA_PID_FILE" ]; } || return 1
            _proc_any_named hysteria "$HYSTERIA_BIN" && return 1
            return 0
            ;;
        direct)
            _proc_any_named hysteria "$HYSTERIA_BIN" && return 1
            return 0
            ;;
    esac
}

# 强杀后再次 stop 再复验终态；Restart=on-failure 可能自动重拉。
_hysteria_stop_and_verify() {
    _manage_hysteria stop 2>/dev/null
    local i p exe
    for i in 1 2 3 4 5 6 7 8; do
        _hysteria_stopped_state && return 0
        sleep 1
    done
    _warn "服务停止后仍处于运行/过渡态, 按 exe 归属强制终止..."
    for p in /proc/[0-9]*; do
        exe=$(readlink "${p}/exe" 2>/dev/null) || continue
        case "$exe" in
            "$HYSTERIA_BIN"|"$HYSTERIA_BIN (deleted)")
                kill -9 "${p##*/}" 2>/dev/null
                ;;
        esac
    done
    sleep 1
    _manage_hysteria stop 2>/dev/null
    for i in 1 2 3 4 5; do
        _hysteria_stopped_state && return 0
        sleep 1
    done
    return 1
}

# 清理后验证 unit 与开机注册均消失；文件不存在不代表注册关系解除。
_hysteria_cleanup_service_units() {
    local ok=1
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable "$HYSTERIA_SVC" 2>/dev/null
            rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service"
            systemctl daemon-reload 2>/dev/null
            systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
            [ "$(systemctl show -p LoadState --value "$HYSTERIA_SVC" 2>/dev/null)" = "not-found" ] && ok=0
            local en
            en=$(systemctl is-enabled "$HYSTERIA_SVC" 2>/dev/null)
            case "$en" in
                ""|disabled|masked|masked-runtime|static|not-found) ;;
                *)
                    ok=1
                    _error "systemd unit ${HYSTERIA_SVC} 仍处于启用形态(is-enabled=${en})"
                    _tip "请人工执行: systemctl disable ${HYSTERIA_SVC}"
                    ;;
            esac
            local lnk
            lnk=$(find /etc/systemd/system /run/systemd/system /usr/lib/systemd/system \
                       -type l -name "${HYSTERIA_SVC}.service" 2>/dev/null)
            if [ -n "$lnk" ]; then
                ok=1
                _error "systemd unit ${HYSTERIA_SVC} 仍有残留符号链接(enable 关系未解除)"
                _tip "请人工清理: ${lnk}"
            fi
            [ "$ok" -eq 0 ] || _tip "请人工核对: systemctl status ${HYSTERIA_SVC}; systemctl is-enabled ${HYSTERIA_SVC}"
            ;;
        openrc)
            rc-update del "$HYSTERIA_SVC" default 2>/dev/null
            rm -f "/etc/init.d/${HYSTERIA_SVC}"
            [ ! -e "/etc/init.d/${HYSTERIA_SVC}" ] && ok=0
            if rc-update show default 2>/dev/null | grep -qE "(^|[[:space:]])${HYSTERIA_SVC}([[:space:]]|$)"; then
                ok=1
                _error "openrc 服务 ${HYSTERIA_SVC} 仍在 default runlevel 注册中(rc-update del 未生效)"
                _tip "请人工执行: rc-update del ${HYSTERIA_SVC} default"
            fi
            [ "$ok" -eq 0 ] || _tip "请人工核对: ls -l /etc/init.d/${HYSTERIA_SVC}; rc-update show"
            ;;
        *)
            ok=0 ;;
    esac
    rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
    return "$ok"
}

_hysteria_uninstall() {
    local ans
    _hysteria_installed || [ -f "/etc/systemd/system/${HYSTERIA_SVC}.service" ] || [ -f "/etc/init.d/${HYSTERIA_SVC}" ] \
        || { _warn "官方 Hysteria2 未安装"; _press_any_key; return 0; }
    echo; read -rp "  确认卸载官方 Hysteria2(删除核心/配置/全部节点数据, 不可恢复)? [y/N]: " ans
    case "$ans" in
        y|Y) _with_config_lock _hysteria_uninstall_locked ;;
        *) _info "已取消"; _press_any_key; return 0 ;;
    esac
}

# service 清理失败保留文件；避免 enabled unit 指向已删 binary/config。
_hysteria_uninstall_locked() {
    local f name
    _hysteria_installed || [ -f "/etc/systemd/system/${HYSTERIA_SVC}.service" ] || [ -f "/etc/init.d/${HYSTERIA_SVC}" ] \
        || { _warn "官方 Hysteria2 已被其他会话移除"; return 0; }
    _hysteria_stop_and_verify || { _error "hysteria 进程未退出, 已中止卸载以避免孤儿进程(文件未删除), 请手动停止后重试"; _press_any_key; return 1; }
    if ! _hysteria_cleanup_service_units; then
        _error "service 定义清理失败, 已中止卸载(核心/配置/数据均保留)"
        _tip "请按上方提示人工清理 service 后重试卸载"
        _press_any_key
        return 1
    fi
    case "$INIT_SYSTEM" in
        systemd) ;; openrc) ;; esac
    if [ -f "$HYSTERIA_CONFIG" ]; then
        local part
        part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null)
        case "$part" in
            *-*) _warn "该配置启用了端口跳跃: 若服务曾被强制杀死, 请人工核查 nft/iptables 是否残留重定向规则" ;;
        esac
    fi
    if [ -f "$HYSTERIA_NODE_META" ]; then
        name=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null)
        [ -n "$name" ] && _hysteria_remove_clash_by_name "$name"
    fi
    rm -f "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODE_META" "$HYSTERIA_LOG_FILE" /etc/logrotate.d/xd-hysteria
    rm -rf "$HYSTERIA_DATA_DIR" "$HYSTERIA_CERT_DIR"
    rm -f "$STATE_DIR/hysteria_version" "$STATE_DIR/hysteria_variant"
    _success "官方 Hysteria2 已卸载"
    return 0
}

# 仅清理废弃的手选变体键并提示；变体已改为 CPU 自动选择。
_hysteria_purge_legacy_variant_state() {
    [ -f "$STATE_DIR/hysteria_variant" ] || return 0
    rm -f "$STATE_DIR/hysteria_variant" \
        && _warn "已移除废弃记录 state/hysteria_variant: AVX 变体现在按 CPU 能力自动选择(支持即优先使用)"
}

# 停服及 service 清理成功才允许整站卸载；避免文件删除后遗留进程。
_hysteria_cleanup_before_uninstall() {
    _hysteria_stop_and_verify || return 1
    _hysteria_cleanup_service_units || return 1
    rm -f "$HYSTERIA_PID_FILE" 2>/dev/null
    return 0
}

# 菜单 read 遇 EOF 直接返回；混合版本清理保持幂等。
_hysteria_menu() {
    local choice
    _hysteria_ensure_dirs || { _press_any_key; return 0; }
    declare -F _hysteria_purge_legacy_variant_state >/dev/null 2>&1 && _hysteria_purge_legacy_variant_state
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【Hysteria2 管理 — 官方核心 (HyNetworks/hysteria)】${NC}"
        local cur st ncount=0 f
        cur=$(_hysteria_cached_version 2>/dev/null)
        if [ -n "$cur" ]; then
            st=$(_manage_hysteria status 2>/dev/null)
            if [ "$st" = "running" ]; then
                echo -e "  核心: ${GREEN}${cur}${NC}  状态: ${GREEN}● 运行中${NC}  (Xray Hy2 在主菜单 [Xray Hy2 管理], 两者独立)"
            else
                echo -e "  核心: ${GREEN}${cur}${NC}  状态: ${RED}○ 已停止${NC}  (Xray Hy2 在主菜单 [Xray Hy2 管理], 两者独立)"
            fi
        else
            echo -e "  核心: ${RED}未安装${NC}"
        fi
        local ncount=0
        [ -f "$HYSTERIA_NODE_META" ] && ncount=1
        echo -e "  节点: ${CYAN}${ncount}${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 安装/更新官方核心"
        echo -e "  ${GREEN}[2]${NC} 添加节点"
        echo -e "  ${GREEN}[3]${NC} 查看节点"
        echo -e "  ${GREEN}[4]${NC} 删除节点/停止服务器"
        echo -e "  ${GREEN}[5]${NC} 修改节点密码"
        echo -e "  ${GREEN}[6]${NC} 服务管理"
        echo -e "  ${GREEN}[7]${NC} 端口 / 端口跳跃"
        echo -e "  ${GREEN}[8]${NC} TLS 设置"
        echo -e "  ${GREEN}[9]${NC} 混淆 obfs"
        echo -e "  ${GREEN}[10]${NC} 带宽限制"
        echo -e "  ${GREEN}[11]${NC} 拥塞控制"
        echo -e "  ${GREEN}[12]${NC} 伪装站 masquerade"
        echo -e "  ${GREEN}[13]${NC} 查看日志"
        echo -e "  ${GREEN}[14]${NC} 卸载 Hysteria"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1) _hysteria_core_menu ;;
            2) _hysteria_add_node ;;
            3) _hysteria_view_nodes ;;
            4) _hysteria_delete_node ;;
            5) _hysteria_change_password ;;
            6) _hysteria_service_menu ;;
            7) _hysteria_port_menu ;;
            8) _hysteria_tls_menu ;;
            9) _hysteria_obfs_menu ;;
            10) _hysteria_bandwidth_menu ;;
            11) _hysteria_congestion_menu ;;
            12) _hysteria_masquerade_menu ;;
            13) _hysteria_view_log ;;
            14) _hysteria_uninstall ;;
            0) return 0 ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}
