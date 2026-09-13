#!/bin/bash
# =============================================================================
# lib/55-hysteria.sh — Official Hysteria2 Manager(官方 Hysteria2 服务端管理)
# 与 Xray Hy2(lib/50-nodes.sh 的 hysteria2 协议)是完全独立的两个实现:
#   Xray Hy2        = Xray-core 实现的 hysteria2 协议, _hy2_* 函数族, config.json 模型
#   Official Hy2    = Hysteria 官方 binary(apernet/hysteria v2.x), _hysteria_* 函数族
# 两者不得共享配置模型/binary/版本管理/服务/认证与链接生成逻辑。
#
# 事实依据(hysteria-website 官方文档 + get.hy2.sh + 2.12.2 实测, 2026-09-13):
#   - 官方配置完整支持 JSON(与 YAML 同构), 故配置文件为 hysteria.json, 全部 jq 生成/变更
#   - 无 check/validate 子命令, 坏配置=启动 FATAL exit 1 → 只能靠 verified-restart 失败回滚
#   - `hysteria cert` 官方自签工具, 打印 pinSHA256(小写十六进制)
#   - 端口跳跃 = listen 写 ":<min>-<max>": binary 监听首端口并自动 nft/iptables 重定向
#     其余端口, 停止时自清 —— 本模块绝不自己写防火墙规则(与 Xray Hy2 的 iptables DNAT 不同)
#   - 官方下载无校验和文件(.sha256sum 404, get.hy2.sh 也不校验) → 用"可执行自检+版本匹配"兜底
#   - 架构映射以官方 get.hy2.sh 为基准, armv5*/riscv64 取官方资产表(脚本漏列)
# =============================================================================

# ---------------------------------------------------------------------------
# 常量(官方 Hysteria2 专属, 与 XRAY_*/CF_* 平行)
# ---------------------------------------------------------------------------
export HYSTERIA_BIN="$BIN_DIR/hysteria"
export HYSTERIA_CONFIG="$DEPLOY_DIR/hysteria.json"
export HYSTERIA_DATA_DIR="$DEPLOY_DIR/hysteria"
export HYSTERIA_NODES_DIR="$DEPLOY_DIR/hysteria/nodes"
export HYSTERIA_BACKUP_DIR="$DEPLOY_DIR/hysteria/backup"
# manager 自有元数据(link_addr/tls_mode/sni/pin 等)。绝不写进 hysteria.json ——
# 那是官方 binary 的配置文件, 只允许出现官方字段。
export HYSTERIA_SERVER_META="$DEPLOY_DIR/hysteria/server_meta.json"
export HYSTERIA_CERT_DIR="$CERT_DIR/hysteria"
export HYSTERIA_LOG_FILE="$LOG_DIR/hysteria.log"
export HYSTERIA_ACME_DIR="$DEPLOY_DIR/hysteria/acme"
# 服务名与官方安装脚本(hysteria-server.service)刻意不同: 同机共存时互不干扰
export HYSTERIA_SVC="xray-deploy-hysteria"
export HYSTERIA_PID_FILE="/run/xray-deploy-hysteria.pid"
export HYSTERIA_DL_BASE="https://download.hysteria.network/app"
export HYSTERIA_GH_API="https://api.github.com/repos/apernet/hysteria/releases/latest"

# ---------------------------------------------------------------------------
# 数据目录(启动时由 _hysteria_menu 调用, 幂等; 对齐 _ensure_dirs 的权限口径)
# ---------------------------------------------------------------------------
_hysteria_ensure_dirs() {
    local ok=1 d f
    for d in "$HYSTERIA_DATA_DIR" "$HYSTERIA_NODES_DIR" "$HYSTERIA_BACKUP_DIR" "$HYSTERIA_CERT_DIR" "$HYSTERIA_ACME_DIR"; do
        mkdir -p "$d" || ok=0
        chmod 700 "$d" 2>/dev/null || ok=0
    done
    for f in "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] && { chmod 600 "$f" 2>/dev/null || ok=0; }
    done
    [ "$ok" -eq 1 ] || { _error "Hysteria 数据目录/权限设置失败(只读文件系统?)"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# 版本管理(独立于 Xray: hysteria version 解析口径 = 官方 get.hy2.sh)
# ---------------------------------------------------------------------------
_hysteria_installed() {
    [ -x "$HYSTERIA_BIN" ] || return 1
    return 0
}

# 直接解析 binary("Version:\tv2.12.2"), 失败输出空
_hysteria_current_version() {
    _hysteria_installed || { echo ""; return 0; }
    "$HYSTERIA_BIN" version 2>/dev/null | grep '^Version' | grep -o 'v[.0-9]*' | head -1
}

# 展示用缓存版本(state/hysteria_version, 对齐 _xray_cached_version 的冷读回退模式)
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

# 最新版本: 官方下载服务的 302 终点 URL 携带版本段(/app/latest/<asset> → /app/v2.12.2/<asset>);
# 失败回落 GitHub API tag_name。两个通道都失败 → 输出空, 调用方显式处理。
_hysteria_latest_version() {
    local asset final ver
    asset=$(_hysteria_arch_asset) || return 1
    final=$(curl -sIL -o /dev/null --max-time 15 -w '%{url_effective}' \
            "${HYSTERIA_DL_BASE}/latest/hysteria-linux-${asset}" 2>/dev/null) || final=""
    ver=$(printf '%s' "$final" | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -1)
    if [ -z "$ver" ] && command -v jq >/dev/null 2>&1; then
        ver=$(jq -r '.tag_name // empty' <(
            curl -fsSL --max-time 15 "$HYSTERIA_GH_API" 2>/dev/null) 2>/dev/null) || ver=""
    fi
    [ -n "$ver" ] && echo "$ver"
    return 0
}

# ---------------------------------------------------------------------------
# 架构映射(uname -m → 官方资产名)
# 基准 = 官方 get.hy2.sh 的映射表; 差异点:
#   - armv5* → armv5 官方资产(资产表明确提供; get.hy2.sh 把 armv5tel 映去 arm, 但 armv7
#     二进制在 armv5 CPU 上必然 SIGILL, 资产表优先)
#   - riscv64 → riscv64 官方资产(资产表提供, get.hy2.sh 未映射)
#   - mipsle 系统一律 mipsle(软浮点设备可经菜单 [安装核心] 手选 mipsle-sf)
# 返回: stdout=资产名; 非 0 = 不支持的架构
# ---------------------------------------------------------------------------
_hysteria_arch_asset() {
    # 可选参数=架构覆盖(测试用); 缺省 uname -m
    local m="${1:-$(uname -m)}"
    case "$m" in
        x86_64|amd64)              echo "amd64" ;;
        i386|i486|i586|i686)       echo "386" ;;
        aarch64|arm64|armv8*)      echo "arm64" ;;
        armv7|armv7l|armv6|armv6l) echo "arm" ;;
        armv5*)                    echo "armv5" ;;
        mipsle|mips|mips64|mips64le) echo "mipsle" ;;
        s390x)                     echo "s390x" ;;
        riscv64)                   echo "riscv64" ;;
        loongarch64)               echo "loong64" ;;
        *)                         return 1 ;;
    esac
}

# CPU 是否支持 AVX(仅用于 amd64 AVX 变体的显式选择提示; 绝不默认选 AVX)
_hysteria_cpu_has_avx() {
    [ -r /proc/cpuinfo ] || return 1
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -qw avx
}

# 结合用户变体偏好(state/hysteria_variant)给出最终资产名
_hysteria_pick_asset() {
    local base
    base=$(_hysteria_arch_asset) || return 1
    if [ "$base" = "amd64" ] && [ "$(_state_get hysteria_variant 2>/dev/null)" = "avx" ]; then
        echo "amd64-avx"
    else
        echo "$base"
    fi
}

# ---------------------------------------------------------------------------
# binary 安装/升级事务:
#   解析资产 → 下载临时文件(同目录, 供原子 mv) → 可执行自检+版本匹配(无官方校验和的兜底,
#   与官方安装脚本同级) → 备份旧 binary → 停服 → 原子替换 → 启动 → verified → commit;
#   任一步失败恢复旧 binary 并重启旧版。配置与节点不受影响(官方 binary 更新不改配置语义)。
# 用法: _hysteria_download_install <version|latest>
# ---------------------------------------------------------------------------
_hysteria_download_install() {
    local want="$1" asset url tmp ver was_running=0 backup=""
    [ -n "$want" ] || { _error "未指定目标版本"; return 1; }
    asset=$(_hysteria_pick_asset) || { _error "不支持的 CPU 架构: $(uname -m)"; return 1; }
    if [ "$want" = "latest" ]; then
        _info "探测官方最新版本..."
        want=$(_hysteria_latest_version)
        [ -n "$want" ] || { _error "无法获取最新版本(网络受限?), 可改用指定版本安装"; return 1; }
    fi
    [[ "$want" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { _error "版本号格式应为 v2.x.x: $want"; return 1; }
    url="${HYSTERIA_DL_BASE}/${want}/hysteria-linux-${asset}"
    _info "下载 ${url}"
    mkdir -p "$BIN_DIR" || return 1
    tmp=$(mktemp "$BIN_DIR/hysteria.dl.XXXXXX") || { _error "临时文件创建失败"; return 1; }
    if ! _http_download "$url" "$tmp" 120; then
        rm -f "$tmp"
        _error "下载失败(网络受限?), 当前安装未变动"
        return 1
    fi
    chmod 755 "$tmp" 2>/dev/null
    # 无官方校验和(.sha256sum 404): 完整性兜底 = ELF 可执行 + version 子命令输出预期版本
    ver=$("$tmp" version 2>/dev/null | grep '^Version' | grep -o 'v[.0-9]*' | head -1)
    if [ "$ver" != "$want" ]; then
        rm -f "$tmp"
        _error "下载内容校验失败(期望 ${want}, 实际 ${ver:-无法执行}), 已放弃替换"
        return 1
    fi
    if _hysteria_installed; then
        backup="$BIN_DIR/.hysteria.rollback.$$"
        cp -p "$HYSTERIA_BIN" "$backup" || { rm -f "$tmp"; _error "旧核心备份失败, 已中止"; return 1; }
        if [ "$(_manage_hysteria status 2>/dev/null)" = "running" ]; then
            was_running=1
            _manage_hysteria stop || { _error "停止服务失败, 已中止升级"; rm -f "$backup"; return 1; }
        fi
        if ! mv -f "$tmp" "$HYSTERIA_BIN"; then
            rm -f "$tmp"
            [ "$was_running" -eq 1 ] && _manage_hysteria start >/dev/null 2>&1
            [ -n "$backup" ] && rm -f "$backup"
            _error "核心替换失败, 旧核心未变动"
            return 1
        fi
    else
        if ! mv -f "$tmp" "$HYSTERIA_BIN"; then
            rm -f "$tmp"
            _error "核心安装失败"
            return 1
        fi
        chmod 755 "$HYSTERIA_BIN" 2>/dev/null
    fi
    _state_set hysteria_version "$want" || _warn "版本记录写入失败(不影响运行)"
    if [ "$was_running" -eq 1 ]; then
        if _hysteria_restart_verified; then
            _success "官方 Hysteria2 核心已升级: ${want}"
        else
            _error "升级后启动失败, 回滚旧核心..."
            if [ -n "$backup" ] && mv -f "$backup" "$HYSTERIA_BIN" 2>/dev/null; then
                if _hysteria_restart_verified; then
                    _warn "已回滚旧核心并恢复运行"
                else
                    _error "回滚后仍启动失败, 请手动查看日志"
                fi
            else
                _error "回滚失败(备份不可用?), 请手动恢复 ${backup}"
            fi
            [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
            return 1
        fi
    else
        _success "官方 Hysteria2 核心已安装: ${want}"
    fi
    [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
    return 0
}

_hysteria_core_menu() {
    local choice cur latest asset avx_note=""
    cur=$(_hysteria_cached_version 2>/dev/null)
    echo; echo -e "  ${CYAN}【官方核心管理】${NC}"
    if [ -n "$cur" ]; then
        echo -e "  当前版本: ${GREEN}${cur}${NC}  (binary: $HYSTERIA_BIN)"
    else
        echo -e "  当前版本: ${RED}未安装${NC}"
    fi
    local asset avx_note=""
    if asset=$(_hysteria_arch_asset) && [ "$asset" = "amd64" ] && _hysteria_cpu_has_avx; then
        local variant="普通版"
        [ "$(_state_get hysteria_variant 2>/dev/null)" = "avx" ] && variant="AVX"
        avx_note="  [4] 切换 AVX 变体 (当前: ${variant})"
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 安装/更新到最新版"
    echo -e "  ${GREEN}[2]${NC} 安装指定版本 (v2.x.x)"
    [ -n "$avx_note" ] && echo -e "$avx_note"
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
        4)
            if [ "$(_state_get hysteria_variant 2>/dev/null)" = "avx" ]; then
                _state_set hysteria_variant "plain" && _success "已切换为普通版, 请执行 [1] 重新安装生效"
            else
                _state_set hysteria_variant "avx" && _success "已切换为 AVX 变体, 请执行 [1] 重新安装生效"
            fi
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

# ---------------------------------------------------------------------------
# 服务层(binary 与 service backend 解耦: systemd / openrc / direct 三分支,
# 运行的核心始终是 $HYSTERIA_BIN。Alpine 不因官方安装脚本要求 systemd 而被排除)
# ---------------------------------------------------------------------------

_hysteria_is_running() {
    # 结构复刻 _xray_is_running 的三分支判活(该函数是项目加固最重的函数, 不参数化共用,
    # 避免"为了 DRY 动它"引入回归; 本函数独立维护同样的判活口径):
    #   systemd: unit 已知时 MainPID 权威, MainPID=0 即 stopped, 不回退全机扫描
    #            (否则宿主上别人的 hysteria 会被当成我们的服务)
    #   openrc : pidfile 是 supervise-daemon 父进程, 需回溯 ppid 链找业务子进程
    #   direct : pidfile 即业务进程
    #   兜底  : 全机扫描, 只认 exe 指向 $HYSTERIA_BIN 的进程
    local anchor="" load=""
    case "$INIT_SYSTEM" in
        systemd)
            load=$(systemctl show -p LoadState --value "$HYSTERIA_SVC" 2>/dev/null)
            case "$load" in
                not-found) return 1 ;;
                "")
                    systemctl is-active --quiet "$HYSTERIA_SVC" 2>/dev/null || return 1
                    ;;
                *)
                    anchor=$(systemctl show -p MainPID --value "$HYSTERIA_SVC" 2>/dev/null)
                    [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
                    [ "$anchor" != "0" ] || return 1
                    _proc_named_under "$anchor" hysteria && return 0
                    return 1 ;;
            esac
            ;;
        openrc|direct)
            anchor=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
            if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" hysteria && return 0
            fi
            ;;
    esac
    _proc_any_named hysteria "$HYSTERIA_BIN"
}

_manage_hysteria() {
    local action="$1"
    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start)   systemctl start "$HYSTERIA_SVC" 2>/dev/null ;;
                stop)    systemctl stop "$HYSTERIA_SVC" 2>/dev/null ;;
                restart) systemctl restart "$HYSTERIA_SVC" 2>/dev/null ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        openrc)
            case "$action" in
                # supervise-daemon respawn 耗尽进入 crashed 态后 start/restart 会被拒;
                # 仅在确认无真实业务进程时 zap 复位(与 _manage_xray openrc 分支同口径)
                start)
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null ;;
                stop)    rc-service "$HYSTERIA_SVC" stop 2>/dev/null ;;
                restart)
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1
                    rc-service "$HYSTERIA_SVC" restart 2>/dev/null ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    local dpid0
                    [ -f "$HYSTERIA_PID_FILE" ] && dpid0=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
                    if [ -n "${dpid0:-}" ] && [ "$(cat "/proc/$dpid0/comm" 2>/dev/null)" = "hysteria" ]; then
                        echo "running"
                    else
                        rm -f "$HYSTERIA_PID_FILE"
                        nohup "$HYSTERIA_BIN" server -c "$HYSTERIA_CONFIG" --disable-update-check \
                            >>"$HYSTERIA_LOG_FILE" 2>&1 &
                        echo $! > "$HYSTERIA_PID_FILE"
                        sleep 1
                        if [ "$(cat "/proc/$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)/comm" 2>/dev/null)" != "hysteria" ]; then
                            _warn "Hysteria 启动失败, 进程已退出(查看 $HYSTERIA_LOG_FILE)"
                            rm -f "$HYSTERIA_PID_FILE"
                            return 1
                        fi
                    fi
                    ;;
                stop)
                    if [ -f "$HYSTERIA_PID_FILE" ]; then
                        local dpid
                        dpid=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
                        if [ -n "$dpid" ] && [ "$(cat "/proc/$dpid/comm" 2>/dev/null)" = "hysteria" ]; then
                            kill "$dpid" 2>/dev/null
                            local k
                            for k in 1 2 3 4 5; do
                                kill -0 "$dpid" 2>/dev/null || break
                                sleep 1
                            done
                            kill -0 "$dpid" 2>/dev/null && kill -9 "$dpid" 2>/dev/null
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

# 重启并确认稳定运行(坏配置=启动即 FATAL, 状态非 running → 触发上层回滚)
_hysteria_restart_verified() {
    if ! _manage_hysteria restart 2>/dev/null; then
        _manage_hysteria start 2>/dev/null || return 1
    fi
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        [ "$(_manage_hysteria status 2>/dev/null)" = "running" ] || return 1
    done
    return 0
}

_hysteria_create_systemd_service() {
    local nofile_line=""
    local _nf; _nf=$(_safe_nofile)
    [ -n "$_nf" ] && nofile_line="LimitNOFILE=$_nf"
    # WorkingDirectory 指向数据目录: 官方 ACL geoip/geosite 自动下载落工作目录(官方文档),
    # ACME 目录已显式写进配置, 二者都不散落到 / 或 ~ 下
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
    systemctl enable "$HYSTERIA_SVC" 2>/dev/null || _warn "开机自启设置失败(可手动: systemctl enable ${HYSTERIA_SVC})"
    return 0
}

_hysteria_create_openrc_service() {
    cat > "/etc/init.d/${HYSTERIA_SVC}" <<EOF
#!/sbin/openrc-run

name="Hysteria2 Official Server (xray-deploy)"
description="Official Hysteria2 QUIC proxy server (apernet/hysteria)"

supervisor=supervise-daemon
respawn_delay=5

pidfile="${HYSTERIA_PID_FILE}"
output_log="${HYSTERIA_LOG_FILE}"
error_log="${HYSTERIA_LOG_FILE}"

# 不设 rc_ulimit 抬升与 capabilities: 容器内 EPERM 会在 exec 前中止启动(H2 同类教训);
# 端口跳跃需要的 NET_ADMIN 以 root 运行天然满足
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
    rc-update add "$HYSTERIA_SVC" default 2>/dev/null || _warn "开机自启设置失败(可手动: rc-update add ${HYSTERIA_SVC} default)"
    # Alpine 常无 logrotate: 有 /etc/logrotate.d 时 best-effort 写一份防 openrc 日志无限增长
    if [ -d /etc/logrotate.d ] && [ ! -f /etc/logrotate.d/xd-hysteria ]; then
        printf '%s\n' "${HYSTERIA_LOG_FILE} {" "    weekly" "    rotate 4" "    compress" \
            "    missingok" "    copytruncate" "}" > /etc/logrotate.d/xd-hysteria 2>/dev/null || true
    fi
    return 0
}

_hysteria_create_service() {
    case "$INIT_SYSTEM" in
        systemd) _hysteria_create_systemd_service ;;
        openrc)  _hysteria_create_openrc_service ;;
        direct)
            _warn "未检测到 systemd/openrc, 跳过 service 创建(可手动: ${HYSTERIA_BIN} server -c ${HYSTERIA_CONFIG})"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 配置事务: 备份 → jq → 原子写 → verified-restart → 失败回滚(镜像 _mutate_config 契约,
# 但无字段重排 —— 官方配置无顺序约定, 且未知字段一律原样保留, 手工扩展不被破坏)
# 用法: _hysteria_config_txn [--arg/--argjson ...] <jq_filter>
# ---------------------------------------------------------------------------
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
    if ! command -v jq >/dev/null 2>&1; then
        _error "jq 不可用, 无法${what}"
        return 1
    fi
    return 0
}

_hysteria_backup_config() {
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    mkdir -p "$HYSTERIA_BACKUP_DIR" || return 1
    local tmp old i=0
    # busybox/musl mktemp 要求模板以 XXXXXX 结尾, 后缀放在 X 之前
    tmp=$(mktemp "${HYSTERIA_BACKUP_DIR}/hysteria.json.bak.XXXXXX") || return 1
    cp -f "$HYSTERIA_CONFIG" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    local last_tmp
    last_tmp=$(mktemp "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp -f "$HYSTERIA_CONFIG" "$last_tmp" 2>/dev/null || { rm -f "$tmp" "$last_tmp"; return 1; }
    [ -s "$last_tmp" ] || { rm -f "$tmp" "$last_tmp"; _error "配置备份内容为空(磁盘空间?), 备份失败"; return 1; }
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
    [ -s "${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak" ] || {
        _error "备份文件为空, 无法回滚(${HYSTERIA_BACKUP_DIR}/hysteria.json.lastbak)"
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

_hysteria_config_txn_locked() {
    _hysteria_config_preflight || return 1
    if ! _hysteria_backup_config; then
        _error "配置备份失败, 中止操作"
        return 1
    fi
    local tmp
    tmp=$(mktemp "${HYSTERIA_CONFIG}.XXXXXX") || { _error "无法创建临时配置"; return 1; }
    local user_filter="${!#}"
    local args=("${@:1:$#-1}" "$user_filter")
    if ! jq "${args[@]}" "$HYSTERIA_CONFIG" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        local jq_err; jq_err=$(jq "${args[@]}" "$HYSTERIA_CONFIG" 2>&1 >/dev/null | head -3)
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
    if ! _hysteria_restart_verified; then
        _error "hysteria 启动失败, 回滚配置"
        if ! _hysteria_restore_config; then
            _error "回滚失败(lastbak 不存在或恢复出错), 未尝试重启"
            return 1
        fi
        if _hysteria_restart_verified; then
            _warn "已回滚到旧配置并重启"
        else
            _error "回滚后仍启动失败, 请查看日志"
        fi
        return 1
    fi
    return 0
}

_hysteria_config_txn() {
    _with_config_lock _hysteria_config_txn_locked "$@"
}

# 服务器是否已完成初始化(配置存在 + jq 可解析 + auth 段就绪)
_hysteria_server_initialized() {
    [ -f "$HYSTERIA_CONFIG" ] && [ -s "$HYSTERIA_CONFIG" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e '.auth.type == "userpass" and (.auth.userpass | type == "object")' "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

# manager 自有元数据(server_meta.json)读写; 文件不存在时输出空
_hysteria_meta_get() {
    local key="$1" val=""
    [ -f "$HYSTERIA_SERVER_META" ] && val=$(jq -r --arg k "$key" '.[$k] // empty' "$HYSTERIA_SERVER_META" 2>/dev/null)
    printf '%s' "$val"
}

_hysteria_meta_set() {
    local key="$1" val="$2" cur
    mkdir -p "$HYSTERIA_DATA_DIR" || return 1
    if [ -f "$HYSTERIA_SERVER_META" ]; then
        _meta_update "$HYSTERIA_SERVER_META" '.[$k]=$v' --arg k "$key" --arg v "$val"
    else
        _atomic_write_json "$HYSTERIA_SERVER_META" "$(jq -n --arg k "$key" --arg v "$val" '{($k): $v}')"
    fi
}

# ---------------------------------------------------------------------------
# TLS 证书辅助
# ---------------------------------------------------------------------------

# 证书 SHA-256 指纹(小写十六进制, 官方 pinSHA256 格式; 实测 = openssl fingerprint 去冒号小写)
_hysteria_cert_pin() {
    local cert="$1" fp
    command -v openssl >/dev/null 2>&1 || return 1
    fp=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fp=${fp#*=}
    fp=${fp//:/}
    printf '%s' "$fp" | tr 'A-F' 'a-f'
}

# TLS 模式设置(bootstrap 与 [TLS 设置] 共用; 只产出 $1 指定的 jq 片段所需变量, 不落盘)
# 输出全局: HY_TLS_JSON(jq -n 片段字符串) HY_TLS_MODE HY_TLS_SNI HY_TLS_PIN
# 用户取消 → 返回 1
_hysteria_prompt_tls() {
    local choice cert_file key_file acme_domains acme_email host pin cn=""
    echo; echo -e "  ${CYAN}【TLS 设置】${NC}"
    echo -e "  ${GREEN}[1]${NC} 自签证书 (官方 hysteria cert 生成, 客户端 insecure+pinSHA256)"
    echo -e "  ${GREEN}[2]${NC} 使用已有证书 (证书+私钥路径)"
    echo -e "  ${GREEN}[3]${NC} ACME 自动证书 (需 80/443 可达, 与 Xray 抢端口时不可用)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  请选择: " choice || return 1
    case "${choice:-0}" in
        0) return 1 ;;
        1)
            _hysteria_installed || { _error "官方核心未安装, 无法生成自签证书"; return 1; }
            mkdir -p "$HYSTERIA_CERT_DIR" || return 1
            read -rp "  证书域名/SAN (回车默认 www.bing.com): " host
            host=${host:-www.bing.com}
            if ! "$HYSTERIA_BIN" cert --host "$host" \
                 --cert "$HYSTERIA_CERT_DIR/cert.pem" --key "$HYSTERIA_CERT_DIR/key.pem" \
                 --overwrite >/dev/null 2>&1; then
                _error "证书生成失败(hysteria cert)"
                return 1
            fi
            chmod 600 "$HYSTERIA_CERT_DIR/key.pem" 2>/dev/null || true
            pin=$(_hysteria_cert_pin "$HYSTERIA_CERT_DIR/cert.pem") || pin=""
            # 自签场景官方样例口径: sniGuard disable + 客户端 insecure+pin 并用
            HY_TLS_JSON=$(jq -n --arg c "$HYSTERIA_CERT_DIR/cert.pem" --arg k "$HYSTERIA_CERT_DIR/key.pem" \
                '{tls: {cert: $c, key: $k, sniGuard: "disable"}}')
            HY_TLS_MODE="selfsigned"; HY_TLS_SNI="$host"; HY_TLS_PIN="$pin"
            return 0
            ;;
        2)
            read -rp "  cert 文件路径: " cert_file
            read -rp "  key  文件路径: " key_file
            _validate_json_text "$cert_file" || { _error "cert 路径含非法字符"; return 1; }
            _validate_json_text "$key_file" || { _error "key 路径含非法字符"; return 1; }
            [ -f "$cert_file" ] && [ -f "$key_file" ] || { _error "证书文件不存在"; return 1; }
            if command -v openssl >/dev/null 2>&1; then
                cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's/\/.*//')
            fi
            read -rp "  客户端 SNI (回车默认 ${cn:-需手动填}): " host
            host=${host:-$cn}
            HY_TLS_JSON=$(jq -n --arg c "$cert_file" --arg k "$key_file" '{tls: {cert: $c, key: $k}}')
            HY_TLS_MODE="custom"; HY_TLS_SNI="$host"; HY_TLS_PIN=""
            return 0
            ;;
        3)
            read -rp "  ACME 域名(多个用逗号分隔): " acme_domains
            [ -z "$acme_domains" ] && { _warn "域名不能为空"; return 1; }
            read -rp "  邮箱: " acme_email
            [ -z "$acme_email" ] && { _warn "邮箱不能为空"; return 1; }
            local d arr="[" first=1
            local -a doms
            # IFS 只作用于这一次 read(项目规约: local IFS 会残留整个函数)
            IFS=',' read -ra doms <<< "$acme_domains"
            for d in "${doms[@]}"; do
                d=$(printf '%s' "$d" | tr -d ' ')
                [ -z "$d" ] && continue
                _validate_domain "$d" || { _error "域名格式非法: $d"; return 1; }
                [ "$first" -eq 1 ] && first=0 || arr="${arr},"
                arr="${arr}\"$d\""
            done
            arr="${arr}]"
            [ "$arr" = "[]" ] && { _warn "无有效域名"; return 1; }
            # HTTP 质询要占 80/TLS-ALPN 占 443: 与 Xray 同机时大概率冲突, 提前讲清
            if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
                if jq -e '[.inbounds[]?.port] | index(80) or index(443)' "$CONFIG_FILE" >/dev/null 2>&1; then
                    _warn "Xray 已占用 80/443 端口, ACME 质询会失败(除非 NAT 转发到本机其他实现)"
                fi
            fi
            _warn "ACME 需要 80/443 可达(NAT VPS 通常不满足); DNS 质询等高级用法请手工编辑 hysteria.json"
            HY_TLS_JSON=$(jq -n --argjson d "$arr" --arg e "$acme_email" --arg dir "$HYSTERIA_ACME_DIR" \
                '{acme: {domains: $d, email: $e, dir: $dir}}')
            HY_TLS_MODE="acme"; HY_TLS_SNI="${acme_domains%%,*}"; HY_TLS_PIN=""
            return 0
            ;;
        *) _warn "无效选择"; return 1 ;;
    esac
}

# 从 server_meta 读取 TLS 展示摘要
_hysteria_tls_desc() {
    local mode; mode=$(_hysteria_meta_get tls_mode)
    case "$mode" in
        selfsigned) echo "自签($(_hysteria_meta_get sni))" ;;
        custom)     echo "已有证书($(_hysteria_meta_get sni))" ;;
        acme)       echo "ACME($(_hysteria_meta_get sni))" ;;
        *)          echo "未知" ;;
    esac
}

# ---------------------------------------------------------------------------
# 端口/端口跳跃(官方机制: listen 写范围, binary 自管防火墙规则)
# ---------------------------------------------------------------------------

# 解析 listen 值 → 输出 "端口部分"(443 或 20000-50000); 非法输出空
_hysteria_listen_port_part() {
    local listen="$1" part
    part="${listen##*:}"
    case "$part" in
        "") return 1 ;;
        *[!0-9-]*) return 1 ;;
    esac
    printf '%s' "$part"
}

# 端口跳跃范围冲突检查(只检查, 不写防火墙 —— 官方 binary 启动自建/停止自清):
#   a) 系统已监听的 UDP 端口落进范围(会被官方 REDIRECT 遮蔽)
#   b) Xray config inbound 端口落进范围
#   c) Xray Hy2 节点的 iptables 跳跃范围与本范围相交
# 用法: _hysteria_check_hop_conflicts <lo> <hi>; 有冲突返回 1(已打印说明)
_hysteria_check_hop_conflicts() {
    local lo="$1" hi="$2" p
    [[ "$lo" =~ ^[0-9]+$ ]] && [[ "$hi" =~ ^[0-9]+$ ]] || return 1
    local hit=""
    # a) 一次 ss 快照(范围可上万, 逐端口探测太慢)
    if command -v ss >/dev/null 2>&1; then
        while read -r p; do
            [ -n "$p" ] || continue
            [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ] && hit="$hit $p"
        done <<< "$(ss -lun 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | sort -un)"
    fi
    [ -n "$hit" ] && { _error "以下端口已被本机监听, 与跳跃范围冲突:$hit"; return 1; }
    # b) Xray config 端口
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        while read -r p; do
            [ -n "$p" ] || continue
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            if [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ]; then
                _error "Xray 入站端口 $p 在跳跃范围内, 会造成端口冲突"
                return 1
            fi
        done <<< "$(jq -r '[.inbounds[]? | select(.port != null) | .port] | .[]' "$CONFIG_FILE" 2>/dev/null)"
    fi
    # c) Xray Hy2 节点 iptables 跳跃范围(区间相交判定; hop_ranges 形如 "20000-50000,3010")
    local f ranges tok_arr tok s e
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        ranges=$(jq -r '.hop_ranges // empty' "$f" 2>/dev/null)
        [ -n "$ranges" ] || continue
        # IFS 只作用于这一次 read(项目规约: local IFS 会残留整个函数)
        IFS=',' read -ra tok_arr <<< "$ranges"
        for tok in "${tok_arr[@]}"; do
            tok=$(printf '%s' "$tok" | tr -d ' ')
            [[ "$tok" == *"-"* ]] || continue
            s="${tok%%-*}"; e="${tok##*-}"
            [[ "$s" =~ ^[0-9]+$ ]] && [[ "$e" =~ ^[0-9]+$ ]] || continue
            if [ "$s" -le "$hi" ] && [ "$e" -ge "$lo" ]; then
                _error "与 Xray Hy2 节点($(basename "$f" .json))的跳跃范围 ${tok} 相交"
                return 1
            fi
        done
    done
    return 0
}

# 从 listen 推断展示文本
_hysteria_listen_display() {
    local part
    part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null) || { echo "未知"; return; }
    case "$part" in
        *-*) echo "${part%-*}-${part#*-} (端口跳跃)" ;;
        *)   echo "$part" ;;
    esac
}

# 读取 hysteria.json 顶层标量(支持点路径, 如 "bandwidth.up"; 不存在/损坏输出空)
_hysteria_config_get() {
    local key="$1"
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "$HYSTERIA_CONFIG" 2>/dev/null
}

# 重建所有节点分享链接(端口/TLS/obfs 等服务器级变更后调用)并同步 clash
_hysteria_rebuild_all_links() {
    local f link name fail=0
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        if ! link=$(_hysteria_build_link "$f") || [ -z "$link" ]; then
            _warn "分享链接重建失败(元数据缺字段?): $(basename "$f" .json)"
            fail=1
            continue
        fi
        _meta_update "$f" '.share_link=$l' --arg l "$link" || { fail=1; continue; }
        _hysteria_sync_clash "$f" || fail=1
    done
    return "$fail"
}

_hysteria_port_menu() {
    local choice part lo hi new_listen
    _hysteria_server_initialized || { _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"; _press_any_key; return; }
    while true; do
        clear
        echo; echo -e "  ${CYAN}【端口 / 端口跳跃】${NC}"
        echo -e "  当前: ${CYAN}$(_hysteria_listen_display)${NC}"
        echo -e "  ${YELLOW}官方机制: 端口跳跃 = listen 写端口范围, binary 监听首端口并自动重定向其余端口,${NC}"
        echo -e "  ${YELLOW}停止服务时自动清理防火墙规则(与 Xray Hy2 的 iptables 方案相互独立)${NC}"
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
                _check_port_occupied "$part" udp && { _warn "端口 $part 已被占用"; _press_any_key; continue; }
                _check_port_in_config "$part" && { _warn "端口 $part 已被 Xray 节点使用"; _press_any_key; continue; }
                new_listen=":${part}"
                if ! _hysteria_config_txn --arg l "$new_listen" '.listen = $l'; then
                    _error "端口修改失败"
                else
                    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败, 可用 [查看节点] 核对"
                    _success "监听端口已修改为 $part"
                fi
                _press_any_key
                ;;
            2)
                read -rp "  跳跃范围 (如 20000-50000, 回车取消): " part
                [ -z "$part" ] && { _press_any_key; continue; }
                # 官方 listen 只支持单段连续范围(文档形态 :<min>-<max>), 逗号多段未定义 → 拒绝
                [[ "$part" == *","* ]] && { _warn "官方 listen 仅支持单段连续范围"; _press_any_key; continue; }
                local parsed
                parsed=$(_parse_hop_ranges "$part") || { _press_any_key; continue; }
                lo="${parsed%%:*}"; hi="${parsed##*:}"
                [ "$lo" = "$hi" ] && { _warn "跳跃范围至少两个端口(单端口无需跳跃)"; _press_any_key; continue; }
                _hysteria_check_hop_conflicts "$lo" "$hi" || { _press_any_key; continue; }
                if ! _hysteria_config_txn --arg l ":${lo}-${hi}" '.listen = $l'; then
                    _error "端口跳跃设置失败"
                else
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
                _check_port_occupied "$part" udp && { _warn "端口 $part 已被占用"; _press_any_key; continue; }
                if ! _hysteria_config_txn --arg l ":${part}" '.listen = $l'; then
                    _error "修改失败"
                else
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
    _hysteria_server_initialized || { _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"; _press_any_key; return; }
    echo; echo -e "  当前 TLS: ${CYAN}$(_hysteria_tls_desc)${NC}"
    if ! _hysteria_prompt_tls; then
        _info "已取消"
        _press_any_key
        return 0
    fi
    if ! _hysteria_config_txn --argjson blk "$HY_TLS_JSON" \
         '. + $blk | if $blk | has("tls") then del(.acme) else del(.tls) end'; then
        _error "TLS 设置失败"
        _press_any_key
        return 0
    fi
    _hysteria_meta_set tls_mode "$HY_TLS_MODE"
    _hysteria_meta_set sni "$HY_TLS_SNI"
    _hysteria_meta_set pin "$HY_TLS_PIN"
    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
    _success "TLS 已切换: $(_hysteria_tls_desc)"
    [ "$HY_TLS_MODE" = "selfsigned" ] && _tip "自签证书: 客户端需 insecure=1 + pinSHA256(已写入链接)"
    [ "$HY_TLS_MODE" = "acme" ] && _tip "ACME 模式: 客户端无需 insecure; 证书由官方核心自动续期"
    _press_any_key
    return 0
}

_hysteria_obfs_menu() {
    local choice pw cur_obfs
    _hysteria_server_initialized || { _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"; _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【混淆 obfs (salamander)】${NC}"
    cur_obfs=$(_hysteria_config_get 'obfs')
    if [ -n "$cur_obfs" ]; then
        echo -e "  当前状态: ${GREEN}已启用${NC}"
    else
        echo -e "  当前状态: ${RED}未启用${NC}"
    fi
    echo -e "  ${YELLOW}启用后服务端不再兼容标准 QUIC/HTTP3 连接(官方文档), 需客户端带相同混淆参数${NC}"
    echo
    echo -e "  ${GREEN}[1]${NC} 启用/更换混淆密码"
    echo -e "  ${GREEN}[2]${NC} 禁用混淆"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice || return 0
    case "$choice" in
        1)
            pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " pw2
            pw=${pw2:-$pw}
            _validate_json_text "$pw" || { _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{)"; _press_any_key; return 0; }
            if ! _hysteria_config_txn --arg p "$pw" \
                 '.obfs = {type: "salamander", salamander: {password: $p}}'; then
                _error "混淆设置失败"
            else
                _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
                _success "混淆已启用"
            fi
            ;;
        2)
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

_hysteria_bandwidth_menu() {
    local choice up down cur_up cur_down
    _hysteria_server_initialized || { _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"; _press_any_key; return; }
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
                 '.bandwidth = ((if $up != "" then {up: $up} else {} end)
                                + (if $down != "" then {down: $down} else {} end))
                     | if (.bandwidth | length) == 0 then del(.bandwidth) else . end'; then
                _error "带宽设置失败"
            else
                _success "带宽已更新: up=${up:-不限} down=${down:-不限}"
            fi
            ;;
        2)
            if ! _hysteria_config_txn 'del(.bandwidth)'; then
                _error "清除失败"
            else
                _success "带宽限制已清除"
            fi
            ;;
        0) return 0 ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
    return 0
}

_hysteria_masquerade_menu() {
    local choice url content
    _hysteria_server_initialized || { _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"; _press_any_key; return; }
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
            read -rp "  目标网站 URL (如 https://news.ycombinator.com/): " url
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

# ---------------------------------------------------------------------------
# 分享链接(官方 URI scheme)与 clash 条目
# ---------------------------------------------------------------------------

# 构建官方 hysteria2:// 链接。服务器级参数(listen/tls/obfs)读 hysteria.json,
# 节点级参数(user/auth/name/link_addr)读节点元数据 —— 官方 URI 无 congestion/up/down
# 等客户端参数(官方文档明示 "parameters should never include ... bandwidth values")。
# 用法: _hysteria_build_link <meta_file>; 失败返回 1
_hysteria_build_link() {
    local meta="$1" user auth name link_addr
    user=$(jq -r '.user // empty' "$meta" 2>/dev/null)
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    link_addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    [ -n "$user" ] && [ -n "$auth" ] && [ -n "$name" ] && [ -n "$link_addr" ] || {
        _error "节点元数据缺少必要字段(user/auth/name/link_addr), 无法构建链接"
        return 1
    }
    local port_part
    port_part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)") || {
        _error "无法解析 hysteria.json 的 listen: $(_hysteria_config_get listen)"
        return 1
    }
    local link_ip="$link_addr"
    [[ "$link_addr" == *":"* && "$link_addr" != *"["* ]] && link_ip="[${link_addr}]"
    local tls_mode sni pin params=""
    tls_mode=$(_hysteria_meta_get tls_mode)
    sni=$(_hysteria_meta_get sni)
    pin=$(_hysteria_meta_get pin)
    if [ "$tls_mode" = "selfsigned" ]; then
        # 自签: insecure=1 必须配 pinSHA256(官方 MITM 警告); pin 缺失时从证书现算
        if [ -z "$pin" ] && [ -f "$HYSTERIA_CERT_DIR/cert.pem" ]; then
            pin=$(_hysteria_cert_pin "$HYSTERIA_CERT_DIR/cert.pem") || pin=""
        fi
        params="insecure=1"
        [ -n "$pin" ] && params="${params}&pinSHA256=${pin}"
    fi
    [ -n "$sni" ] && params="${params}${params:+&}sni=$(_url_encode "$sni")"
    local obfs_pw
    obfs_pw=$(jq -r '.obfs.salamander.password // empty' "$HYSTERIA_CONFIG" 2>/dev/null)
    [ -n "$obfs_pw" ] && params="${params}${params:+&}obfs=salamander&obfs-password=$(_url_encode "$obfs_pw")"
    # 官方多端口格式直接写在 port 段(443 或 20000-50000), 无 mport 参数
    local link="hysteria2://$(_url_encode "$user"):$(_url_encode "$auth")@${link_ip}:${port_part}/"
    [ -n "$params" ] && link="${link}?${params}"
    link="${link}#$(_url_encode "$name")"
    printf '%s' "$link"
}

# clash.yaml(mihomo) 条目: mihomo hysteria2 的 auth 字段 = 原始认证串(userpass 用 user:pass,
# 即协议口径, 所有客户端一致); ports = 官方多端口格式
_hysteria_clash_line() {
    local meta="$1" name addr user auth
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    user=$(jq -r '.user // empty' "$meta" 2>/dev/null)
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] && [ -n "$addr" ] && [ -n "$user" ] && [ -n "$auth" ] || {
        _error "节点元数据缺少必要字段(name/link_addr/user/auth), 无法生成 clash 条目"
        return 1
    }
    local port_part
    port_part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)") || return 1
    local line="- {name: \"$(_yaml_dq "$name")\", type: hysteria2, server: \"$(_yaml_dq "$addr")\", port: ${port_part%%-*}, auth: \"$(_yaml_dq "$user"):$( _yaml_dq "$auth")\""
    local sni; sni=$(_hysteria_meta_get sni)
    [ -n "$sni" ] && line="${line}, sni: \"$(_yaml_dq "$sni")\""
    [ "$(_hysteria_meta_get tls_mode)" = "selfsigned" ] && line="${line}, skip-cert-verify: true"
    local obfs_pw
    obfs_pw=$(jq -r '.obfs.salamander.password // empty' "$HYSTERIA_CONFIG" 2>/dev/null)
    [ -n "$obfs_pw" ] && line="${line}, obfs: salamander, obfs-password: \"$(_yaml_dq "$obfs_pw")\""
    local up down
    up=$(jq -r '.bandwidth.up // empty' "$HYSTERIA_CONFIG" 2>/dev/null)
    down=$(jq -r '.bandwidth.down // empty' "$HYSTERIA_CONFIG" 2>/dev/null)
    [ -n "$up" ] && line="${line}, up: \"$(_yaml_dq "$up")\""
    [ -n "$down" ] && line="${line}, down: \"$(_yaml_dq "$down")\""
    case "$port_part" in
        *-*) line="${line}, ports: \"${port_part}\"" ;;
    esac
    printf '%s}' "$line"
}

# clash 派生同步(替换或追加); old_name 非空且 != 当前名时先删旧行(改名场景)
_hysteria_sync_clash() {
    local meta="$1" old_name="${2:-}" line name
    line=$(_hysteria_clash_line "$meta") || { _warn "clash 条目生成失败, 可手工编辑 ${CLASH_YAML}"; return 1; }
    name=$(jq -r '.name // empty' "$meta")
    [ -n "$name" ] || return 1
    if [ -n "$old_name" ] && [ "$old_name" != "$name" ]; then
        _remove_node_from_yaml_by_name "$old_name" 2>/dev/null || true
    fi
    if [ -f "$CLASH_YAML" ] && grep -qF "name: \"$(_yaml_dq "$name")\"" "$CLASH_YAML" 2>/dev/null; then
        _replace_node_in_yaml "$line" "$name" || _warn "clash 条目替换失败, 可手工编辑 ${CLASH_YAML}"
    else
        _add_node_to_yaml "$line" "$name" || _warn "clash 条目追加失败, 可手工编辑 ${CLASH_YAML}"
    fi
    return 0
}

_hysteria_remove_clash_by_name() {
    local name="$1"
    [ -n "$name" ] || return 0
    _remove_node_from_yaml_by_name "$name" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 节点(= 官方 auth.userpass 用户)生命周期
# ---------------------------------------------------------------------------

# 节点用户名合法性: username 即元数据文件名 → 白名单字符集(与 _validate_domain 同风格),
# 且不得含 ':'(官方 userpass 按首个冒号切分用户名)
_hysteria_validate_username() {
    local u="$1"
    [ -n "$u" ] || return 1
    [ "${#u}" -le 64 ] || return 1
    [[ "$u" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || return 1
    return 0
}

# 节点显示名是否已被占用(clash.yaml 按 name 删除/替换, 重名会串条目; 与 Xray 侧
# _ensure_unique_name 同一约束, 但作用域是 hysteria 自己的元数据目录)
_hysteria_name_taken() {
    local name="$1" f n
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$(jq -r '.name // empty' "$f" 2>/dev/null) || continue
        [ -n "$n" ] && [ "$n" = "$name" ] && return 0
    done
    return 1
}

# 默认名已被占用时自动追加序号(HY2官方-443-2/-3...); 返回可用名
_hysteria_autofill_name() {
    local base="$1" i=2
    while _hysteria_name_taken "$base"; do
        base="${base}-${i}"
        i=$((i+1))
    done
    printf '%s' "$base"
}

# 服务器初始化向导(bootstrap): 仅由 [添加节点] 在未初始化时触发, 单一入口避免双路径漂移。
# 实测约束(2.12.2): 官方 binary 对空 userpass 表 FATAL("empty auth userpass"),
# 因此**第一个用户必须与配置同时落地**——本向导包含首位用户的创建, 成功返回后节点已可用。
# 失败回滚已发生的步骤并返回 1。
_hysteria_bootstrap() {
    local port hop parsed lo hi listen tls_json tls_mode tls_sni tls_pin
    local obfs_pw="" masq_url="" up="" down="" addr
    local user auth name def_name
    echo; echo -e "  ${CYAN}=== 初始化官方 Hysteria2 服务器 ===${NC}"
    _tip "官方架构: 单服务多用户, 以下为服务器级设置; 每个节点 = 一个认证用户"

    # 0) 核心
    if ! _hysteria_installed; then
        local ans
        read -rp "  官方核心未安装, 立即下载安装最新版? [Y/n]: " ans
        case "$ans" in
            n|N) _info "已取消初始化"; return 1 ;;
        esac
        _hysteria_download_install latest || return 1
    fi

    # 1) 端口 / 端口跳跃
    local def_port
    def_port=$(_gen_random_port)
    while true; do
        read -rp "  监听端口 (回车随机 ${def_port}): " port
        port=${port:-$def_port}
        _validate_port "$port" || { _warn "无效端口(1-65535)"; continue; }
        _check_port_occupied "$port" udp && { _warn "端口 $port 已被占用, 换一个"; def_port=$(_gen_random_port); continue; }
        _check_port_in_config "$port" && { _warn "端口 $port 已被 Xray 节点使用, 换一个"; def_port=$(_gen_random_port); continue; }
        break
    done
    read -rp "  端口跳跃范围 (如 20000-50000, 回车不启用): " hop
    if [ -n "$hop" ]; then
        [[ "$hop" == *","* ]] && { _warn "官方 listen 仅支持单段连续范围"; return 1; }
        parsed=$(_parse_hop_ranges "$hop") || return 1
        lo="${parsed%%:*}"; hi="${parsed##*:}"
        [ "$lo" = "$hi" ] && { _warn "跳跃范围至少两个端口"; return 1; }
        [ "$lo" -le "$port" ] && [ "$port" -le "$hi" ] || {
            # 官方机制: 范围首端口即监听端口; 允许把监听端口并进范围首端
            _warn "官方机制下监听端口=范围首端口(${lo}), 输入的 $port 将被范围取代"
            read -rp "  使用范围 ${lo}-${hi} (监听 ${lo})? [y/N]: " ans
            case "$ans" in y|Y) port="$lo" ;; *) _info "已取消"; return 1 ;; esac
        }
        _hysteria_check_hop_conflicts "$lo" "$hi" || return 1
        listen=":${lo}-${hi}"
    else
        listen=":${port}"
    fi

    # 2) TLS
    if ! _hysteria_prompt_tls; then _info "已取消"; return 1; fi
    tls_json="$HY_TLS_JSON"; tls_mode="$HY_TLS_MODE"; tls_sni="$HY_TLS_SNI"; tls_pin="$HY_TLS_PIN"

    # 3) obfs(可选)
    local ans2=""
    read -rp "  启用 salamander 混淆? [y/N]: " ans2
    case "$ans2" in
        y|Y)
            obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " ans2
            obfs_pw=${ans2:-$obfs_pw}
            _validate_json_text "$obfs_pw" || { _error "混淆密码含非法字符"; return 1; }
            ;;
    esac

    # 4) 带宽(可选, 仅限速语义)
    read -rp "  上行限速 (如 100 mbps, 回车不限): " up
    read -rp "  下行限速 (如 100 mbps, 回车不限): " down
    up=$(_normalize_bandwidth "$up"); down=$(_normalize_bandwidth "$down")

    # 5) 伪装(可选, 默认官方 404)
    read -rp "  伪装站 URL (回车用官方默认 404): " masq_url
    if [ -n "$masq_url" ]; then
        _validate_json_text "$masq_url" || { _error "URL 含非法字符"; return 1; }
        [[ "$masq_url" == https://* || "$masq_url" == http://* ]] || { _error "URL 须以 http(s):// 开头"; return 1; }
    fi

    # 6) 客户端连接地址(与其他协议共用同一问法/兜底)
    addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址, 已取消初始化"; return 1; }

    # 6.5) 首位用户(官方 binary 拒绝空 userpass 表, 必须随配置一起写入)
    while true; do
        user="user$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 6)"
        read -rp "  首位用户名 (回车随机 ${user}): " ans2
        user=${ans2:-$user}
        _hysteria_validate_username "$user" || { _warn "用户名仅限字母/数字/./_/-, 不含冒号, 2-64 位"; continue; }
        [ -f "$HYSTERIA_NODES_DIR/${user}.json" ] && { _warn "用户名已存在"; continue; }
        break
    done
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  认证密码 (回车随机): " ans2
    auth=${ans2:-$auth}
    _validate_json_text "$auth" || { _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{)"; return 1; }
    def_name="HY2官方-${port}"
    read -rp "  节点名称 (回车默认 ${def_name}): " ans2
    name=${ans2:-$def_name}
    _validate_json_text "$name" || { _error "名称含非法字符"; return 1; }
    if _hysteria_name_taken "$name"; then
        [ "$name" = "$def_name" ] || { _error "节点名称已存在: ${name}"; return 1; }
        name=$(_hysteria_autofill_name "$def_name")
        _tip "默认名已被占用, 自动命名为 ${name}"
    fi

    # 7) 组装官方配置并落地(失败即中止, 未触碰服务)
    local config_json
    config_json=$(jq -n \
        --arg listen "$listen" --argjson tlsblk "$tls_json" \
        --arg obfspw "$obfs_pw" --arg up "$up" --arg down "$down" --arg masqurl "$masq_url" \
        --arg u "$user" --arg p "$auth" \
        '{listen: $listen}
         + $tlsblk
         + {auth: {type: "userpass", userpass: {($u): $p}}}
         + (if $obfspw != "" then {obfs: {type: "salamander", salamander: {password: $obfspw}}} else {} end)
         + (if ($up != "" or $down != "") then
              {bandwidth: ((if $up != "" then {up: $up} else {} end)
                           + (if $down != "" then {down: $down} else {} end))}
            else {} end)
         + (if $masqurl != "" then
              {masquerade: {type: "proxy", proxy: {url: $masqurl, rewriteHost: true}}}
            else {} end)') || { _error "配置组装失败"; return 1; }
    # 防御: 空表会 FATAL(实测), 组装结果必须至少含首位用户
    jq -e --arg u "$user" '.auth.userpass[$u] != null' <<< "$config_json" >/dev/null || {
        _error "配置组装异常(userpass 为空), 已中止"
        return 1
    }
    _hysteria_ensure_dirs || return 1
    if ! _atomic_write_json "$HYSTERIA_CONFIG" "$config_json"; then
        _error "配置写入失败, 已取消初始化"
        return 1
    fi
    if ! _hysteria_meta_set link_addr "$addr" || ! _hysteria_meta_set tls_mode "$tls_mode" \
        || ! _hysteria_meta_set sni "$tls_sni" || ! _hysteria_meta_set pin "$tls_pin" \
        || ! _hysteria_meta_set created "$(date '+%Y-%m-%d')" ; then
        _error "服务器元数据写入失败"
        rm -f "$HYSTERIA_CONFIG"
        return 1
    fi

    # 8) 服务
    _hysteria_create_service
    if [ "$INIT_SYSTEM" != "direct" ]; then
        if ! _hysteria_restart_verified; then
            _error "Hysteria 服务启动失败, 回滚初始化(配置/服务)..."
            _manage_hysteria stop 2>/dev/null
            case "$INIT_SYSTEM" in
                systemd)
                    systemctl disable "$HYSTERIA_SVC" 2>/dev/null
                    rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service"
                    systemctl daemon-reload 2>/dev/null ;;
                openrc)
                    rc-update del "$HYSTERIA_SVC" default 2>/dev/null
                    rm -f "/etc/init.d/${HYSTERIA_SVC}" ;;
            esac
            rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
            rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
            _warn "初始化已回滚"
            return 1
        fi
    else
        # direct 模式无 service: 启动并做 1s 存活检查
        if ! _manage_hysteria start; then
            rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
            _error "启动失败, 已回滚配置"
            return 1
        fi
    fi

    # 9) 首位节点元数据 + 分享链接(配置已提交, 元数据失败仅告警)
    # 注意: 链接构建须喂真实临时文件 —— <(process substitution) 的 fd 带 CLOEXEC,
    # 函数内部 $(jq ...) 子进程打不开 /dev/fd/63(实测), 与 _hy2_gen_newmeta 同款模式
    local link meta_json tmp_meta
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || tmp_meta=""
    if [ -n "$tmp_meta" ]; then
        jq -n --arg u "$user" --arg a "$auth" --arg n "$name" --arg addr "$addr" \
            '{user:$u,auth:$a,name:$n,link_addr:$addr}' > "$tmp_meta" 2>/dev/null
        link=$(_hysteria_build_link "$tmp_meta") || link=""
        rm -f "$tmp_meta"
    else
        link=""
    fi
    meta_json=$(jq -n --arg u "$user" --arg a "$auth" --arg n "$name" \
        --arg addr "$addr" --arg link "$link" --arg created "$(date '+%Y-%m-%d')" \
        '{user:$u,auth:$a,name:$n,link_addr:$addr,created:$created,share_link:$link}')
    if ! _atomic_write_json "$HYSTERIA_NODES_DIR/${user}.json" "$meta_json"; then
        _error "节点已加入配置, 但元数据写入失败(${user}); 建议删除该用户后重试"
        return 1
    fi
    _hysteria_sync_clash "$HYSTERIA_NODES_DIR/${user}.json" || true
    _success "官方 Hysteria2 服务器已初始化: $(_hysteria_listen_display), TLS=$(_hysteria_tls_desc)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
    return 0
}

_hysteria_add_node() {
    local user auth name meta_json link
    _hysteria_ensure_dirs || return 1
    if ! _hysteria_server_initialized; then
        # bootstrap 含首位用户创建(官方 binary 拒绝空 userpass 表, 不可先建空服务器)
        _hysteria_bootstrap
        return $?
    fi
    echo; echo -e "  ${CYAN}=== 添加 Hysteria2 (官方) 节点 = 新增认证用户 ===${NC}"
    while true; do
        user="user$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 6)"
        read -rp "  用户名 (回车随机 ${user}): " user2
        user=${user2:-$user}
        _hysteria_validate_username "$user" || { _warn "用户名仅限字母/数字/./_/-, 不含冒号, 2-64 位"; continue; }
        [ -f "$HYSTERIA_NODES_DIR/${user}.json" ] && { _warn "用户名已存在"; continue; }
        break
    done
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  认证密码 (回车随机): " auth2
    auth=${auth2:-$auth}
    _validate_json_text "$auth" || { _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{)"; return 1; }
    local def_name="HY2官方-$( _hysteria_listen_port_part "$(_hysteria_config_get listen)")"
    read -rp "  节点名称 (回车默认 ${def_name}): " name
    name=${name:-$def_name}
    _validate_json_text "$name" || { _error "名称含非法字符"; return 1; }
    if _hysteria_name_taken "$name"; then
        [ "$name" = "$def_name" ] || { _error "节点名称已存在: ${name}"; return 1; }
        name=$(_hysteria_autofill_name "$def_name")
        _tip "默认名已被占用, 自动命名为 ${name}"
    fi

    # 配置事务: userpass 表新增(失败=配置自动回滚, 未提交任何东西)
    if ! _hysteria_config_txn --arg u "$user" --arg p "$auth" '.auth.userpass[$u] = $p'; then
        _error "节点添加失败"
        return 1
    fi
    # 配置已提交 → 元数据/派生缓存: 失败只告警不回滚配置(与 Xray 节点创建同口径)
    # 链接构建喂 mktemp 临时文件(<(fd) 带 CLOEXEC, 函数内 $(jq) 子进程打不开, 见 bootstrap 同注)
    local tmp_meta
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || tmp_meta=""
    link=""
    if [ -n "$tmp_meta" ]; then
        jq -n --arg u "$user" --arg a "$auth" --arg n "$name" \
            --arg addr "$(_hysteria_meta_get link_addr)" \
            '{user:$u,auth:$a,name:$n,link_addr:$addr}' > "$tmp_meta" 2>/dev/null
        link=$(_hysteria_build_link "$tmp_meta") || link=""
        rm -f "$tmp_meta"
    fi
    meta_json=$(jq -n --arg u "$user" --arg a "$auth" --arg n "$name" \
        --arg addr "$(_hysteria_meta_get link_addr)" --arg link "$link" \
        --arg created "$(date '+%Y-%m-%d')" \
        '{user:$u,auth:$a,name:$n,link_addr:$addr,created:$created,share_link:$link}')
    if ! _atomic_write_json "$HYSTERIA_NODES_DIR/${user}.json" "$meta_json"; then
        _error "节点已加入配置, 但元数据写入失败(${user}); 建议删除该用户后重试"
        return 1
    fi
    _hysteria_sync_clash "$HYSTERIA_NODES_DIR/${user}.json" || true
    _success "节点 [${name}] 创建成功"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
    return 0
}

_hysteria_view_nodes() {
    clear
    echo; echo -e "  ${CYAN}【Hysteria2 (官方) 节点】${NC}"
    if ! _hysteria_server_initialized; then
        _warn "服务器未初始化"
        _press_any_key
        return 0
    fi
    echo -e "  服务器: $(_hysteria_listen_display)  TLS: $(_hysteria_tls_desc)  状态: $(_manage_hysteria status 2>/dev/null)"
    echo
    local f n=0
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$((n+1))
        local name user link
        name=$(jq -r '.name // empty' "$f" 2>/dev/null)
        user=$(jq -r '.user // empty' "$f" 2>/dev/null)
        link=$(jq -r '.share_link // empty' "$f" 2>/dev/null)
        echo -e "  ${GREEN}[$n]${NC} ${name}  (用户: ${user})"
        [ -n "$link" ] && echo -e "      ${link}"
    done
    [ "$n" -eq 0 ] && _warn "暂无节点(用户)"
    _press_any_key
    return 0
}

# 列出节点用户名(每行一个)
_hysteria_list_users() {
    local f
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        jq -r '.user // empty' "$f" 2>/dev/null
    done
}

_hysteria_delete_node() {
    local choice users=() i=1 user name
    _hysteria_server_initialized || { _warn "服务器未初始化"; _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【删除 Hysteria2 (官方) 节点】${NC}"
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        name=$(jq -r '.name // empty' "$f" 2>/dev/null)
        users+=("$(jq -r '.user // empty' "$f" 2>/dev/null)")
        printf "  ${GREEN}[%d]${NC} %-24s (用户: %s)\n" "$i" "$name" "${users[${#users[@]}-1]}"
        i=$((i+1))
    done
    [ ${#users[@]} -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice || return 0
    [ "$choice" = "0" ] && return 0
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1))
    user="${users[$idx]:-}"
    [ -z "$user" ] && { _warn "无效选择"; _press_any_key; return; }
    # 官方 binary 对空 userpass 表 FATAL(实测 2.12.2): 最后 1 个用户不可经此删除
    local ucount
    ucount=$(jq -r '[.auth.userpass | keys[]] | length' "$HYSTERIA_CONFIG" 2>/dev/null)
    if [ "$ucount" = "1" ]; then
        _warn "官方 binary 拒绝空认证表, 至少保留 1 个节点(完全移除请用 [卸载 Hysteria])"
        _press_any_key
        return
    fi
    name=$(jq -r '.name // empty' "$HYSTERIA_NODES_DIR/${user}.json" 2>/dev/null)
    read -rp "  确认删除节点 [${name}](用户 ${user})? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; _press_any_key; return ;;
    esac
    if ! _hysteria_config_txn --arg u "$user" 'del(.auth.userpass[$u])'; then
        _error "删除失败(配置未变动)"
        _press_any_key
        return
    fi
    # 配置已提交 → 清元数据 + clash 条目(残留只告警)
    rm -f "$HYSTERIA_NODES_DIR/${user}.json" 2>/dev/null || _warn "元数据删除失败: ${user}.json"
    _hysteria_remove_clash_by_name "$name"
    _success "节点已删除"
    _press_any_key
    return 0
}

_hysteria_change_password() {
    local choice users=() i=1 user name auth
    _hysteria_server_initialized || { _warn "服务器未初始化"; _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【修改节点密码】${NC}"
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        name=$(jq -r '.name // empty' "$f" 2>/dev/null)
        users+=("$(jq -r '.user // empty' "$f" 2>/dev/null)")
        printf "  ${GREEN}[%d]${NC} %-24s (用户: %s)\n" "$i" "$name" "${users[${#users[@]}-1]}"
        i=$((i+1))
    done
    [ ${#users[@]} -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice || return 0
    [ "$choice" = "0" ] && return 0
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1))
    user="${users[$idx]:-}"
    [ -z "$user" ] && { _warn "无效选择"; _press_any_key; return; }
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  新密码 (回车随机): " auth2
    auth=${auth2:-$auth}
    _validate_json_text "$auth" || { _error "密码含非法字符"; _press_any_key; return; }
    if ! _hysteria_config_txn --arg u "$user" --arg p "$auth" '.auth.userpass[$u] = $p'; then
        _error "密码修改失败"
        _press_any_key
        return
    fi
    local meta="$HYSTERIA_NODES_DIR/${user}.json" newlink
    if [ -f "$meta" ]; then
        if ! newlink=$(_hysteria_build_link "$meta") || [ -z "$newlink" ]; then
            _warn "密码已修改, 但分享链接重建失败"
            _press_any_key
            return
        fi
        _meta_update "$meta" '.auth=$p | .share_link=$l' --arg p "$auth" --arg l "$newlink" || { _error "元数据更新失败"; _press_any_key; return; }
        _hysteria_sync_clash "$meta"
        _success "密码已修改"
        echo -e "  ${CYAN}新分享链接:${NC} ${newlink}"
    else
        _warn "密码已修改, 但节点元数据不存在($meta), 链接未更新"
    fi
    _press_any_key
    return 0
}

# ---------------------------------------------------------------------------
# 服务管理 / 日志 / 卸载
# ---------------------------------------------------------------------------
_hysteria_service_menu() {
    local choice
    clear
    echo; echo -e "  ${CYAN}【服务管理】${NC}"
    echo -e "  状态: $([ "$(_manage_hysteria status 2>/dev/null)" = "running" ] && echo "${GREEN}运行中${NC}" || echo "${RED}已停止${NC}")  (init: ${INIT_SYSTEM})"
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

# 独立卸载(菜单 [13]): 停服 → 删 service → 删派生缓存条目 → 删 binary/配置/数据/证书/日志/state
_hysteria_uninstall() {
    local ans f name
    _hysteria_installed || [ -f "/etc/systemd/system/${HYSTERIA_SVC}.service" ] || [ -f "/etc/init.d/${HYSTERIA_SVC}" ] \
        || { _warn "官方 Hysteria2 未安装"; _press_any_key; return 0; }
    echo; read -rp "  确认卸载官方 Hysteria2(删除核心/配置/全部节点数据, 不可恢复)? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; _press_any_key; return 0 ;;
    esac
    _manage_hysteria stop 2>/dev/null
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable "$HYSTERIA_SVC" 2>/dev/null
            rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service"
            systemctl daemon-reload 2>/dev/null
            systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
            ;;
        openrc)
            rc-update del "$HYSTERIA_SVC" default 2>/dev/null
            rm -f "/etc/init.d/${HYSTERIA_SVC}"
            ;;
    esac
    # 官方端口跳跃规则由 binary 启建/停清; 服务被 SIGKILL 过的极端情况可能残留, 提示人工核查
    if [ -f "$HYSTERIA_CONFIG" ]; then
        local part
        part=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null)
        case "$part" in
            *-*) _warn "该配置启用了端口跳跃: 若服务曾被强制杀死, 请人工核查 nft/iptables 是否残留重定向规则" ;;
        esac
    fi
    # clash.yaml 派生条目(在数据目录删除前取名字)
    if [ -d "$HYSTERIA_NODES_DIR" ]; then
        for f in "$HYSTERIA_NODES_DIR"/*.json; do
            [ -f "$f" ] || continue
            name=$(jq -r '.name // empty' "$f" 2>/dev/null)
            _hysteria_remove_clash_by_name "$name"
        done
    fi
    rm -f "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_LOG_FILE" /etc/logrotate.d/xd-hysteria
    rm -rf "$HYSTERIA_DATA_DIR" "$HYSTERIA_CERT_DIR"
    rm -f "$STATE_DIR/hysteria_version" "$STATE_DIR/hysteria_variant"
    _success "官方 Hysteria2 已卸载"
    return 0
}

# Xray 整站卸载(_uninstall_xray 会 rm -rf $DEPLOY_DIR)的前置清理:
# 不停服删 unit 会留下指向已删 binary 的孤儿服务。数据目录随 DEPLOY_DIR 一并消失。
_hysteria_cleanup_before_uninstall() {
    _manage_hysteria stop 2>/dev/null || true
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable "$HYSTERIA_SVC" 2>/dev/null
            rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service"
            systemctl daemon-reload 2>/dev/null
            systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
            ;;
        openrc)
            rc-update del "$HYSTERIA_SVC" default 2>/dev/null
            rm -f "/etc/init.d/${HYSTERIA_SVC}"
            ;;
    esac
    rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
    rm -f "$HYSTERIA_PID_FILE" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 主菜单(RT-1: 所有 while true 菜单主 read 带 || return 0, EOF 时干净退出)
# ---------------------------------------------------------------------------
_hysteria_menu() {
    local choice
    _hysteria_ensure_dirs || { _press_any_key; return 0; }
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【Hysteria2 管理 — 官方核心 (apernet/hysteria)】${NC}"
        local cur st ncount=0 f
        cur=$(_hysteria_cached_version 2>/dev/null)
        if [ -n "$cur" ]; then
            st=$(_manage_hysteria status 2>/dev/null)
            if [ "$st" = "running" ]; then
                echo -e "  核心: ${GREEN}${cur}${NC}  状态: ${GREEN}● 运行中${NC}  (Xray Hy2 在菜单 [6], 两者独立)"
            else
                echo -e "  核心: ${GREEN}${cur}${NC}  状态: ${RED}○ 已停止${NC}  (Xray Hy2 在菜单 [6], 两者独立)"
            fi
        else
            echo -e "  核心: ${RED}未安装${NC}"
        fi
        [ -d "$HYSTERIA_NODES_DIR" ] && { for f in "$HYSTERIA_NODES_DIR"/*.json; do [ -f "$f" ] && ncount=$((ncount+1)); done; }
        echo -e "  节点: ${CYAN}${ncount}${NC}  监听: $(_hysteria_server_initialized && _hysteria_listen_display || echo "未初始化")"
        echo
        echo -e "  ${GREEN}[1]${NC} 安装/更新官方核心"
        echo -e "  ${GREEN}[2]${NC} 添加节点 (=新增认证用户)"
        echo -e "  ${GREEN}[3]${NC} 查看节点"
        echo -e "  ${GREEN}[4]${NC} 删除节点"
        echo -e "  ${GREEN}[5]${NC} 修改节点密码"
        echo -e "  ${GREEN}[6]${NC} 服务管理"
        echo -e "  ${GREEN}[7]${NC} 端口 / 端口跳跃"
        echo -e "  ${GREEN}[8]${NC} TLS 设置"
        echo -e "  ${GREEN}[9]${NC} 混淆 obfs"
        echo -e "  ${GREEN}[10]${NC} 带宽限制"
        echo -e "  ${GREEN}[11]${NC} 伪装站 masquerade"
        echo -e "  ${GREEN}[12]${NC} 查看日志"
        echo -e "  ${GREEN}[13]${NC} 卸载 Hysteria"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1) _hysteria_core_menu ;;
            2) _hysteria_add_node; _press_any_key ;;
            3) _hysteria_view_nodes ;;
            4) _hysteria_delete_node ;;
            5) _hysteria_change_password ;;
            6) _hysteria_service_menu ;;
            7) _hysteria_port_menu ;;
            8) _hysteria_tls_menu ;;
            9) _hysteria_obfs_menu ;;
            10) _hysteria_bandwidth_menu ;;
            11) _hysteria_masquerade_menu ;;
            12) _hysteria_view_log ;;
            13) _hysteria_uninstall ;;
            0) return 0 ;;
            *) _warn "无效选择"; _press_any_key ;;
        esac
    done
}
