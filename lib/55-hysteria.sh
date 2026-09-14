#!/bin/bash
# =============================================================================
# lib/55-hysteria.sh — Official Hysteria2 Manager(官方 Hysteria2 服务端管理)
# 与 Xray Hy2(lib/50-nodes.sh 的 hysteria2 协议)是完全独立的两个实现:
# Xray Hy2        = Xray-core 实现的 hysteria2 协议, _hy2_* 函数族, config.json 模型
# Official Hy2    = Hysteria 官方 binary(HyNetworks/hysteria, 旧组织名已 301 重定向, v2.x), _hysteria_* 函数族
# 两者不得共享配置模型/binary/版本管理/服务/认证与链接生成逻辑。
#
# 事实依据(hysteria-website 官方文档 + get.hy2.sh + 2.12.2 实测, 2026-09-13):
# - 官方配置完整支持 JSON(与 YAML 同构), 故配置文件为 hysteria.json, 全部 jq 生成/变更
# - 无 check/validate 子命令, 坏配置=启动 FATAL exit 1 → 只能靠 verified-restart 失败回滚
# - `hysteria cert` 官方自签工具, 打印 pinSHA256(小写十六进制)
# - 端口跳跃 = listen 写 ":<min>-<max>": binary 监听首端口并自动 nft/iptables 重定向
# 其余端口, 停止时自清 —— 本模块绝不自己写防火墙规则(与 Xray Hy2 的 iptables DNAT 不同)
# - 完整性校验 = 官方 hashes.txt SHA256(fail-closed) + 可执行自检 + 版本匹配三层
# (0.16.1 曾误判"官方无校验和", 0.16.2 实证修正: hashes.txt 与 binary 同目录发布)
# - 架构映射以官方 get.hy2.sh 为基准; armv5*/riscv64 取官方资产表(脚本漏列),
# armv6/mips(BE)/mips64 因 ABI 不兼容明确拒绝(收紧)
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
# 官方仓库组织名已更改为 HyNetworks/hysteria(旧名 301 重定向)
# (2026-09-13 实证: API full_name=HyNetworks/hysteria; 旧路径 301 重定向仍可用但不再依赖)
export HYSTERIA_GH_API="https://api.github.com/repos/HyNetworks/hysteria/releases/latest"

# ---------------------------------------------------------------------------
# 数据目录(启动时由 _hysteria_menu 调用, 幂等; 对齐 _ensure_dirs 的权限口径)
# ---------------------------------------------------------------------------
_hysteria_ensure_dirs() {
    local ok=1 d f
    # LOG_DIR 一并确保: openrc output_log / direct 启动重定向都写 $LOG_DIR/hysteria.log,
    # 而模块可能被非 xd 主入口路径调用(cron/直接 source), 不能假设 _ensure_dirs 已跑过
    for d in "$HYSTERIA_DATA_DIR" "$HYSTERIA_NODES_DIR" "$HYSTERIA_BACKUP_DIR" "$HYSTERIA_CERT_DIR" "$HYSTERIA_ACME_DIR" "$LOG_DIR"; do
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

# 版本号 canonicalize: 官方 GitHub release tag 形态为 app/v2.12.2(2026-09-13 实测),
# GitHub API fallback 会拿到 app/ 前缀; 统一在此剥离并校验 v2.x.x 格式
_hysteria_canon_version() {
    local v="${1#app/}"
    [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$v"; return 0; }
    return 1
}

# 从官方 hashes.txt 提取指定资产的 SHA256(格式 "<sha256>  build/<asset>")。
# 精确锚定行尾防前缀误匹配(amd64 vs amd64-avx)。fail-closed 口径与注释一致:
# 0 条=无此资产、>1 条=校验文件异常(正常官方文件唯一) —— 都拒绝, 不取 tail。
_hysteria_expected_sha256() {
    local f="$1" name="$2" count sha
    [ -s "$f" ] || return 1
    count=$(grep -cE " build/${name}\$" "$f" 2>/dev/null)
    [ "$count" = 1 ] || return 1
    sha=$(grep -E " build/${name}\$" "$f" | awk '{print $1}')
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$sha"
}

# 最新版本: 官方下载服务的 302 终点 URL 携带版本段(/app/latest/<asset> → /app/v2.12.2/<asset>);
# 失败回落 GitHub API latest(注意: 仓库改名后 API 会 301, 必须 -L 跟随; tag 形态 app/v2.x.x,
# 经 canonicalize)。两个通道都失败 → 输出空, 调用方显式处理。
_hysteria_latest_version() {
    local asset final ver
    asset=$(_hysteria_arch_asset) || return 1
    # 用 GET(-o /dev/null, 只取最终 URL)而非 HEAD —— 部分 CDN/代理/缓存层
    # 对 HEAD 返回 405 而 GET 正常, 强依赖 HEAD 是无谓的脆弱点
    final=$(curl -fsSL -o /dev/null --max-time 15 -w '%{url_effective}' \
            "${HYSTERIA_DL_BASE}/latest/hysteria-linux-${asset}" 2>/dev/null) || final=""
    ver=$(_hysteria_canon_version "$(printf '%s' "$final" | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -1)")
    if [ -z "$ver" ] && command -v jq >/dev/null 2>&1; then
        ver=$(_hysteria_canon_version "$(curl -fsSL --max-time 15 "$HYSTERIA_GH_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)")
    fi
    [ -n "$ver" ] && echo "$ver"
    return 0
}

# ---------------------------------------------------------------------------
# 架构映射(uname -m → 官方资产名)
# 基准 = 官方 get.hy2.sh 的映射表; 差异点:
# - armv5* → armv5 官方资产(资产表明确提供; get.hy2.sh 把 armv5tel 映去 arm, 但 armv7
# 二进制在 armv5 CPU 上必然 SIGILL, 资产表优先)
# - riscv64 → riscv64 官方资产(资产表提供, get.hy2.sh 未映射)
# - 收紧口径: mips(BE)/mips64/mips64le 明确拒绝 —— uname 名相似 ≠ ABI 兼容,
# 大端 CPU 跑 mipsle(小端)资产必然失败, 32 位 LE 资产在 64 位用户态也不保证可跑;
# 无法可靠判定就拒绝并提示, 不猜。mipsle(含软浮点设备手选 mipsle-sf)不受影响。
# 返回: stdout=资产名; 非 0 = 不支持的架构
# ---------------------------------------------------------------------------
_hysteria_arch_asset() {
    # 可选参数=架构覆盖(测试用); 缺省 uname -m
    local m="${1:-$(uname -m)}"
    case "$m" in
        x86_64|amd64)              echo "amd64" ;;
        i386|i486|i586|i686)       echo "386" ;;
        aarch64|arm64|armv8*)      echo "arm64" ;;
        armv7|armv7l)              echo "arm" ;;
        # armv6 明确拒绝: 官方 linux/arm 资产是 GOARM=7 构建, 在 ARMv6 CPU 上
        # 会因缺少 v7 指令 SIGILL; 官方 release 无独立 armv6 平台, 不猜映射
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

# CPU 是否支持 AVX(仅用于 amd64 AVX 变体的显式选择提示; 绝不默认选 AVX)
_hysteria_cpu_has_avx() {
    [ -r /proc/cpuinfo ] || return 1
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -qw avx
}

# 结合用户变体偏好(state/hysteria_variant)给出最终资产名。
# 业务层必须**再次**校验 CPU 能力 —— UI 侧检查不足以信任(状态文件可能
# 从别的机器迁移过来, 或 CPU 特性被容器屏蔽), 否则会下载 amd64-avx 在无 AVX 的 CPU 上 SIGILL。
# 最终判据: variant=avx **且** 本机 /proc/cpuinfo 确有 avx, 否则回落普通 amd64。
_hysteria_pick_asset() {
    local base
    base=$(_hysteria_arch_asset) || return 1
    if [ "$base" = "amd64" ] && [ "$(_state_get hysteria_variant 2>/dev/null)" = "avx" ]; then
        if _hysteria_cpu_has_avx; then
            echo "amd64-avx"
        else
            _warn "状态记录为 AVX 变体, 但本机 CPU 无 avx 支持, 已回落到普通 amd64(防 SIGILL)"
            echo "amd64"
        fi
    else
        echo "$base"
    fi
}

# ---------------------------------------------------------------------------
# binary 安装/升级事务:
# 解析资产 → 下载临时文件(同目录, 供原子 mv) → 官方 hashes.txt SHA256 校验 + 可执行自检
# + 版本匹配(三层, 见下) → 备份旧 binary → 停服 → 原子替换 → 启动 → verified → commit;
# 任一步失败恢复旧 binary 并重启旧版。配置与节点不受影响(官方 binary 更新不改配置语义)。
# 用法: _hysteria_download_install <version|latest>
# ---------------------------------------------------------------------------
_hysteria_download_install() {
    local want="$1" asset url tmp ver was_running=0 backup="" old_ver=""
    [ -n "$want" ] || { _error "未指定目标版本"; return 1; }
    asset=$(_hysteria_pick_asset) || { _error "不支持的 CPU 架构: $(uname -m)"; return 1; }
    if [ "$want" = "latest" ]; then
        _info "探测官方最新版本..."
        want=$(_hysteria_latest_version)
        [ -n "$want" ] || { _error "无法获取最新版本(网络受限?), 可改用指定版本安装"; return 1; }
    fi
    # 版本号 canonicalize(评审 0.16.2: GitHub tag 形态 app/v2.x.x, 输入侧统一剥离)
    want=$(_hysteria_canon_version "$want") || { _error "版本号格式应为 v2.x.x: $1"; return 1; }
    url="${HYSTERIA_DL_BASE}/${want}/hysteria-linux-${asset}"
    # 完整性校验前置: sha256sum 不可用则整个下载无意义(fail-closed, 与 xray .dgst 同口径)
    command -v sha256sum >/dev/null 2>&1 || { _error "sha256sum 不可用, 无法验证下载完整性"; return 1; }
    _info "下载 ${url}"
    mkdir -p "$BIN_DIR" || return 1
    tmp=$(mktemp "$BIN_DIR/hysteria.dl.XXXXXX") || { _error "临时文件创建失败"; return 1; }
    if ! _http_download "$url" "$tmp" 120; then
        rm -f "$tmp"
        _error "下载失败(网络受限?), 当前安装未变动"
        return 1
    fi
    # (官方 hashes.txt, 2026-09-13 实证与 binary 同目录发布): SHA256 校验 fail-closed。
    # 拿不到官方校验和 = 不可信任下载内容, 直接中止(自检+版本匹配只能证明"能执行且报对版本",
    # 无法证明"就是官方发布的那个 binary")。hashes.txt 格式: "<sha256>  build/<asset>"。
    local h_file expected sha
    h_file=$(mktemp "$BIN_DIR/hashes.txt.XXXXXX") || { rm -f "$tmp"; _error "临时文件创建失败"; return 1; }
    if ! _http_download "${HYSTERIA_DL_BASE}/${want}/hashes.txt" "$h_file" 60 || [ ! -s "$h_file" ]; then
        rm -f "$h_file" "$tmp"
        _error "无法获取官方 hashes.txt 校验文件, 为防供应链篡改已中止(当前安装未变动)"
        return 1
    fi
    expected=$(_hysteria_expected_sha256 "$h_file" "hysteria-linux-${asset}")
    rm -f "$h_file"
    [ -n "$expected" ] || { rm -f "$tmp"; _error "hashes.txt 中无 hysteria-linux-${asset} 条目, 已中止"; return 1; }
    sha=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    [ "$sha" = "$expected" ] || {
        rm -f "$tmp"
        _error "SHA256 不匹配(期望 ${expected}, 实际 ${sha:-无法计算}), 已放弃替换"
        return 1
    }
    chmod 755 "$tmp" 2>/dev/null
    # 第二层: 可执行自检 + version 子命令输出与目标版本一致(官方解析口径)
    ver=$("$tmp" version 2>/dev/null | grep '^Version' | grep -o 'v[.0-9]*' | head -1)
    if [ "$ver" != "$want" ]; then
        rm -f "$tmp"
        _error "下载内容校验失败(期望 ${want}, 实际 ${ver:-无法执行}), 已放弃替换"
        return 1
    fi
    if _hysteria_installed; then
        backup="$BIN_DIR/.hysteria.rollback.$$"
        cp -p "$HYSTERIA_BIN" "$backup" || { rm -f "$tmp"; _error "旧核心备份失败, 已中止"; return 1; }
        # 记录旧版本, 回滚后据此校验"确实恢复到了旧版本"而不只是"服务在跑"
        old_ver=$(_hysteria_current_version)
        if [ "$(_manage_hysteria status 2>/dev/null)" = "running" ]; then
            was_running=1
            # 升级替换 binary 前统一用 stop_and_verify —— 确认旧进程真正退出
            # (exe 兜底强杀), 避免"旧进程仍持有旧 inode + 新 binary 已就位"的中间态
            _hysteria_stop_and_verify || { _error "停止服务失败(进程未退出), 已中止升级"; rm -f "$backup"; return 1; }
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
                # 恢复后既验证服务运行, 也验证版本确实回到旧版(防备份错/替换错)
                local now_ver=""
                if _hysteria_restart_verified; then
                    now_ver=$(_hysteria_current_version)
                    if [ -n "$old_ver" ] && [ "$now_ver" != "$old_ver" ]; then
                        _error "已恢复运行但版本不符(期望 ${old_ver}, 实际 ${now_ver:-未知}), 请人工核对 $HYSTERIA_BIN"
                    else
                        _warn "已回滚旧核心并恢复运行(${now_ver:-未知})"
                    fi
                else
                    _error "回滚后仍启动失败, 请手动查看日志"
                fi
            else
                _error "回滚失败(备份不可用?), 请手动恢复 ${backup}"
            fi
            _state_set hysteria_version "$old_ver" 2>/dev/null || true
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
    # systemd: unit 已知时 MainPID 权威, MainPID=0 即 stopped, 不回退全机扫描
    # (否则宿主上别人的 hysteria 会被当成我们的服务)
    # openrc : pidfile 是 supervise-daemon 父进程, 需回溯 ppid 链找业务子进程
    # direct : pidfile 即业务进程
    # 兜底  : 全机扫描, 只认 exe 指向 $HYSTERIA_BIN 的进程
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
        direct)
            # direct: pidfile 即业务进程本身 → 必须用 exe 归属校验(P1-2), 只看 comm 会把
            # 陈旧 pidfile 指向的他方 hysteria 误认成本项目服务
            anchor=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
            _hysteria_pid_is_ours "${anchor:-}" && return 0
            ;;
        openrc)
            # openrc: pidfile 是 supervise-daemon 父进程(其 exe 不是 hysteria), 不能用 exe
            # 直接校验 anchor, 需沿 ppid 链回溯业务子进程(与 _xray_is_running 同口径)
            anchor=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
            if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" hysteria && return 0
            fi
            ;;
    esac
    _proc_any_named hysteria "$HYSTERIA_BIN"
}

# direct backend 的 PID 归属判定: 只看 comm=="hysteria" 太宽 ——
# PID reuse / 陈旧 pidfile 场景下, 别的 hysteria(系统包 / 用户自建)会被误认成本项目的服务,
# 甚至被 kill。项目在卸载路径已用 /proc/<pid>/exe 判归属, 这里统一到同一口径:
# pid 数字合法 + /proc/<pid>/exe(含 "(deleted)" 就地替换形态, 经 readlink -f 归一) == $HYSTERIA_BIN
# 返回 0 = 确属本项目的 hysteria 进程; 1 = 不是(含进程不存在)。
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

# 判断以 anchor 为根(含自身)的进程树里是否存在 exe == $HYSTERIA_BIN 的进程(P2-1 第八轮评审)。
# 用于 openrc supervisor 归属校验: supervisor 自身 exe 是 supervise-daemon, 需向下找业务子进程;
# 深度 4 足以覆盖 supervisor→hysteria 拓扑。exe 读不到时按"无法确认"处理(不放行), 因为
# 本函数的用途是"动手杀进程前确认归属", 假阳性会误杀他方服务。
_hysteria_proc_tree_has_bin() {
    local anchor="$1" p c cur i
    [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
    [ "$anchor" != "0" ] || return 1
    _proc_exe_is "$anchor" "$HYSTERIA_BIN" && return 0
    for p in /proc/[0-9]*; do
        c="${p#/proc/}"
        cur="$c"
        i=0
        while [ "$i" -lt 4 ]; do
            cur=$(_proc_ppid "$cur") || break
            if [ "$cur" = "$anchor" ]; then
                _proc_exe_is "$c" "$HYSTERIA_BIN" && return 0
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
    # fd9 关闭(9>&-): 本函数可能在 _with_config_lock 的锁子 shell 内被调用(config 事务),
    # openrc 的 supervise-daemon / direct 模式的 nohup 会继承全部打开 fd —— 守护进程
    # 持有 fd9 = flock 永远被持有, 后续所有配置事务 15s 超时失败(2026-09-13 Alpine 实测;
    # systemd 不继承业务 fd 故 Ubuntu 无感)。对齐 singbox-lite 的锁 fd 泄漏修复。
    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start)
                    # 0.16.7(评审轮实测): 高频 stop/start(事务/瞬态验证循环)会触发 systemd
                    # 启动限流 "start-limit-hit", 之后 start 一律被拒 → 服务再也起不来。
                    # 启动前清掉限流计数(对未受限的 unit 是幂等 no-op), 与项目 xray 侧同口径。
                    systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
                    systemctl start "$HYSTERIA_SVC" 2>/dev/null 9>&- ;;
                stop)    systemctl stop "$HYSTERIA_SVC" 2>/dev/null 9>&- ;;
                restart)
                    systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
                    systemctl restart "$HYSTERIA_SVC" 2>/dev/null 9>&- ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        openrc)
            case "$action" in
                # supervise-daemon respawn 耗尽进入 crashed 态后 start/restart 会被拒;
                # 仅在确认无真实业务进程时 zap 复位(与 _manage_xray openrc 分支同口径)
                start)
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1 9>&-
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null 9>&- ;;
                stop)
                    rc-service "$HYSTERIA_SVC" stop 2>/dev/null 9>&-
                    _hysteria_kill_stale_supervisor ;;
                restart)
                    # 不用 rc-service restart: 子进程 FATAL 后 supervisor 进入 respawn-wait,
                    # openrc 状态机会标 stopped 而 supervisor 仍在 → restart 只跑 start 阶段,
                    # 被 "already running" 拒绝(rc=1)。显式 stop(含孤儿清理)+start 必然全新启动。
                    rc-service "$HYSTERIA_SVC" stop 2>/dev/null 9>&-
                    _hysteria_kill_stale_supervisor
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1 9>&-
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null 9>&- ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    local dpid0
                    [ -f "$HYSTERIA_PID_FILE" ] && dpid0=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
                    # 归属用 exe 校验(不只看 comm); 陈旧 pidfile 指向他方 hysteria 时
                    # 判为 stale → 清 pidfile 并正常启动, 绝不误认 running
                    if _hysteria_pid_is_ours "${dpid0:-}"; then
                        echo "running"
                    else
                        rm -f "$HYSTERIA_PID_FILE"
                        # 与 systemd WorkingDirectory/openrc directory 语义统一;
                        # 子壳层 exec 使 $! 即 hysteria 进程 pid(no-hup 承接同一 pid)
                        (
                            cd "$HYSTERIA_DATA_DIR" 2>/dev/null || cd /
                            exec nohup "$HYSTERIA_BIN" server -c "$HYSTERIA_CONFIG" --disable-update-check \
                                >>"$HYSTERIA_LOG_FILE" 2>&1 9>&-
                        ) &
                        echo $! > "$HYSTERIA_PID_FILE"
                        sleep 1
                        if ! _hysteria_pid_is_ours "$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)"; then
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
                        # 只对本项目自己的 hysteria(exe 归属)发信号, 绝不误杀同名的他方进程
                        if _hysteria_pid_is_ours "$dpid"; then
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

# openrc 状态机与 supervise-daemon 脱同步清理(2026-09-13 Alpine 实测):
# 子进程 FATAL 后 supervisor 进入 respawn-wait(仍存活), openrc 却把服务标记 stopped;
# 此后 start 被 "supervise-daemon: already running" 拒绝, 服务永远起不来。
# stop 后若 pidfile 仍指向存活的 supervise-daemo(busybox comm 截断 15 字符), 显式 kill。
# 归属安全(P2-1 第八轮评审): 不能只看 comm=supervise-daemo* —— pidfile 陈旧且 PID 被**别的**
# openrc 服务的 supervisor 复用时, 只看名字会误杀他方进程。openrc 的 pidfile 是 supervisor
# 父进程(其 exe 不是 hysteria), 无法像 direct 那样直接比 exe; 改为校验**其进程树里确实存在
# exe == $HYSTERIA_BIN 的进程**, 归属确属本项目才动手。
_hysteria_kill_stale_supervisor() {
    local a c k
    a=$(cat "$HYSTERIA_PID_FILE" 2>/dev/null)
    [[ "$a" =~ ^[0-9]+$ ]] || return 0
    [ -d "/proc/$a" ] || { rm -f "$HYSTERIA_PID_FILE"; return 0; }
    c=$(cat "/proc/$a/comm" 2>/dev/null)
    case "$c" in
        supervise-daemo*)
            if _hysteria_proc_tree_has_bin "$a"; then
                kill "$a" 2>/dev/null
                for k in 1 2 3 4 5; do
                    kill -0 "$a" 2>/dev/null || break
                    sleep 1
                done
                kill -0 "$a" 2>/dev/null && kill -9 "$a" 2>/dev/null
            else
                _warn "pidfile 指向的 supervise-daemon(pid=$a) 未管理本项目的 hysteria, 不杀(可能是他方服务)"
            fi
            ;;
    esac
    rm -f "$HYSTERIA_PID_FILE"
    return 0
}

# 重启并确认稳定运行(坏配置=启动即 FATAL, 状态非 running → 触发上层回滚)
# 成败判定一律以 8s 轮询为准, 服务命令 rc 仅决定是否补一次 start —— openrc+
# supervise-daemon 下命令 rc 不可靠(实测: "already running" 被拒时 rc=1 但服务健康;
# 反之 FATAL 崩溃时 rc=0 但服务会死), 按 rc 提前判失败会把健康服务误判为失败。
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

# 回滚收尾: 把服务恢复到事务开始前的运行状态。
# running → 重启并验证; stopped → 确保停止(瞬态启动/异常 supervisor 都可能留下运行态,
# 只"不主动启动"是不够的)。这是所有 rollback/recovery 路径的统一收尾入口。
_hysteria_recover_to_state() {
    local want="${1:-}"
    # 未知/空状态不得默认为 stopped —— 未来某 backend 返回
    # unknown/failed/not-found 时被当成 stopped 会掩盖真实异常。只接受两个明确值。
    case "$want" in
        running) _hysteria_restart_verified ;;
        stopped) _hysteria_stop_and_verify >/dev/null 2>&1 ;;
        *)
            _error "未知的原运行状态 '${want}', 无法安全恢复; 请人工确认服务状态"
            return 1
            ;;
    esac
}

# stopped 状态下的配置验证(): 配置事务不得隐式改变用户运行状态,
# 但官方无 check 子命令 —— 以"瞬态启动 → 8s 验证 → 停回并确认 stopped"替代常驻重启,
# 最终状态仍是 stopped; 若停回失败(异常)大声告警(此时状态已改变, 用户必须知道)。
_hysteria_validate_transient() {
    _manage_hysteria start 2>/dev/null
    local i running=0
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        [ "$(_manage_hysteria status 2>/dev/null)" = "running" ] && { running=1; break; }
    done
    if [ "$running" -ne 1 ]; then
        _manage_hysteria stop 2>/dev/null
        return 1
    fi
    _manage_hysteria stop 2>/dev/null
    for i in 1 2 3 4; do
        sleep 1
        [ "$(_manage_hysteria status 2>/dev/null)" != "running" ] && return 0
    done
    # 停不回去必须**返回失败** —— 原实现 warn 后 return 0, 上层据此判定
    # 事务成功, 而用户原状态 stopped 已被改成 running, 直接违反"不改变运行状态"契约。
    _error "瞬态验证后服务未能停止, 运行状态已被改变(原为 stopped)"
    _tip "请人工检查并停止: ${HYSTERIA_BIN} / $( [ "$INIT_SYSTEM" = systemd ] && echo "systemctl stop ${HYSTERIA_SVC}" || echo "rc-service ${HYSTERIA_SVC} stop" )"
    return 1
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
    # "service 定义已创建" 与 "开机自启已设置" 是两个不同结果, 输出必须区分
    if ! systemctl enable "$HYSTERIA_SVC" 2>/dev/null; then
        _warn "service 定义已创建, 但开机自启设置失败(可手动: systemctl enable ${HYSTERIA_SVC})"
    fi
    return 0
}

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

# 与 systemd WorkingDirectory 语义统一: ACL geo 下载等相对路径行为三后端一致
directory="${HYSTERIA_DATA_DIR}"

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
    # 同 systemd —— 定义创建与开机自启分开报告
    if ! rc-update add "$HYSTERIA_SVC" default 2>/dev/null; then
        _warn "service 定义已创建, 但开机自启设置失败(可手动: rc-update add ${HYSTERIA_SVC} default)"
    fi
    # Alpine 常无 logrotate: 有 /etc/logrotate.d 时 best-effort 写一份防 openrc 日志无限增长
    if [ -d /etc/logrotate.d ] && [ ! -f /etc/logrotate.d/xd-hysteria ]; then
        printf '%s\n' "${HYSTERIA_LOG_FILE} {" "    weekly" "    rotate 4" "    compress" \
            "    missingok" "    copytruncate" "}" > /etc/logrotate.d/xd-hysteria 2>/dev/null || true
    fi
    return 0
}

# 必须把 backend 的创建结果透传给调用方 —— 原实现无条件 return 0,
# "service 创建失败"会被误报成"启动失败", 用户无法定位失败步骤。
_hysteria_create_service() {
    case "$INIT_SYSTEM" in
        systemd) _hysteria_create_systemd_service ;;
        openrc)  _hysteria_create_openrc_service ;;
        direct)
            _warn "未检测到 systemd/openrc, 跳过 service 创建(可手动: ${HYSTERIA_BIN} server -c ${HYSTERIA_CONFIG})"
            return 0
            ;;
        *) return 0 ;;
    esac
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
    # 事务不得隐式改变用户运行状态 —— stopped 时只做瞬态验证
    local was_running; was_running=$(_manage_hysteria status 2>/dev/null)
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
                # 文件回滚成功但运行状态恢复失败 —— 必须明确报降级,
                # 不能只说"回滚后仍启动失败"(用户会以为文件也没回滚)
                _error "降级: 配置已回滚, 但服务未能恢复运行(原状态 running); 请人工检查"
                _tip "核对: $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / 日志 ${HYSTERIA_LOG_FILE}"
            fi
            return 1
        fi
    else
        # 原状态 stopped: 瞬态验证(起→验→停), 不改变运行状态; 失败照样回滚
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
                # 文件已回滚, 但原 stopped 状态的收尾验证失败 —— 明确降级语义
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

# ---------------------------------------------------------------------------
# 服务级统一事务(P1-4): hysteria.json(官方配置) + server_meta.json(manager
# 元数据)必须作为一个整体提交 —— 先 config 后 meta 的两段式会在"config 已提交而 meta
# 写失败"时产生状态漂移(服务是新 TLS / 链接按旧 TLS 重建)。
# 用法: _hysteria_server_txn [--arg/--argjson ...] <config_filter> <meta_filter>
# meta_filter 传 "-" 表示本事务不动 server_meta。
# 契约: 双备份 → config 变更 → meta 变更 → verified-restart → 失败双回滚+重启。
# ---------------------------------------------------------------------------
_hysteria_server_txn_locked() {
    _hysteria_config_preflight || return 1
    [ "$#" -ge 2 ] || { _error "server_txn 参数不足(config_filter, meta_filter)"; return 1; }
    local config_filter="$1" meta_filter="$2"; shift 2
    local was_running; was_running=$(_manage_hysteria status 2>/dev/null)
    if ! _hysteria_backup_config; then
        _error "配置备份失败, 中止操作"
        return 1
    fi
    # --- 阶段 1: config 变更(到此为止的失败 = 一切未变, 直接中止) ---
    local tmp
    tmp=$(mktemp "${HYSTERIA_CONFIG}.XXXXXX") || { _error "无法创建临时配置"; return 1; }
    if ! jq "${@}" "$config_filter" "$HYSTERIA_CONFIG" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        local jq_err; jq_err=$(jq "${@}" "$config_filter" "$HYSTERIA_CONFIG" 2>&1 >/dev/null | head -3)
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
    # --- 至此 config 已变更: 之后任何失败都必须恢复 config + meta 并**按原运行状态**收尾 ---
    # 早期回滚路径原直接 `_hysteria_restart_verified`, 忽略 was_running ——
    # 用户原本 stopped 的服务会被一次失败的事务异常启动。统一走 _hysteria_recover_to_state。
    local meta_bak="" meta_had=0 meta_created=0
    if [ "$meta_filter" != "-" ]; then
        if [ -f "$HYSTERIA_SERVER_META" ]; then
            meta_had=1
            meta_bak=$(mktemp "${HYSTERIA_SERVER_META}.bak.XXXXXX") || {
                _hysteria_restore_config; _hysteria_recover_to_state "$was_running"
                _error "无法创建元数据备份"; return 1
            }
            if ! cp -p "$HYSTERIA_SERVER_META" "$meta_bak"; then
                rm -f "$meta_bak"
                _hysteria_restore_config; _hysteria_recover_to_state "$was_running"
                _error "元数据备份失败"; return 1
            fi
            chmod 600 "$meta_bak" 2>/dev/null
        fi
        if [ ! -f "$HYSTERIA_SERVER_META" ]; then
            # meta 文件不存在(meta_had=0): 尝试以 {} 起步; 该创建本身计入可回滚变更
            if ! _atomic_write_json "$HYSTERIA_SERVER_META" '{}'; then
                _hysteria_restore_config; _hysteria_recover_to_state "$was_running"
                _error "server_meta 初始化失败, 已回滚配置"; return 1
            fi
            meta_created=1
        fi
        local newmeta
        if ! newmeta=$(jq "${@}" "$meta_filter" "$HYSTERIA_SERVER_META" 2>/dev/null) || [ -z "$newmeta" ]; then
            _hysteria_server_txn_rollback "$meta_had" "$meta_created" "$meta_bak"
            _error "server_meta 变换失败, 已回滚配置"
            return 1
        fi
        if ! _atomic_write_json "$HYSTERIA_SERVER_META" "$newmeta"; then
            _hysteria_server_txn_rollback "$meta_had" "$meta_created" "$meta_bak"
            _error "server_meta 提交失败, 已回滚配置"
            return 1
        fi
    fi
    # --- 阶段 2: 按 was_running 提交(stopped 不被隐式启动) ---
    if [ "$was_running" = "running" ]; then
        if ! _hysteria_restart_verified; then
            _error "hysteria 启动失败, 回滚配置与元数据"
            # 无论 config 回滚成败都必须继续回滚 meta 并给出降级状态 ——
            # 原写法在 restore 失败时提前 return, 留下"config 新/meta 新"或"config 未知/meta 新"
            # 的不一致状态且无人工指引, 违反"失败即恢复原状或明确降级"。
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
    # 备份清理失败给出告警(严格事务系统不应静默吞掉清理失败)
    [ -n "$meta_bak" ] && { rm -f "$meta_bak" 2>/dev/null || _warn "临时备份清理失败: $meta_bak"; }
    return 0
}

# server_txn 的 meta 侧回滚(meta_had=1 还原备份; meta_created=1 删除新建; 失败显式报告)
# server_meta 侧回滚。**返回真实状态**: 0=已还原到原状, 1=未能还原。
# 原实现无条件 return 0, 调用方无从区分"回滚完成"与"回滚失败但已告警"; 严格事务 API 必须
# 让调用者能据此判定是否进入 degraded state。
_hysteria_server_txn_rollback() {
    local meta_had="$1" meta_created="$2" meta_bak="$3" mc rc=0
    if [ "$meta_had" -eq 1 ] && [ -s "$meta_bak" ]; then
        mc=$(cat "$meta_bak" 2>/dev/null)
        if [ -n "$mc" ] && _atomic_write_json "$HYSTERIA_SERVER_META" "$mc"; then
            rc=0
        else
            _warn "server_meta 回滚失败, 请人工核对 $HYSTERIA_SERVER_META"
            rc=1
        fi
    elif [ "$meta_created" -eq 1 ]; then
        if rm -f "$HYSTERIA_SERVER_META"; then rc=0; else _warn "server_meta 删除失败, 请人工核对"; rc=1; fi
    fi
    [ -n "$meta_bak" ] && { rm -f "$meta_bak" 2>/dev/null || _warn "临时备份清理失败: $meta_bak"; }
    return "$rc"
}

_hysteria_server_txn() {
    _with_config_lock _hysteria_server_txn_txn_wrapper "$@"
}

# ---------------------------------------------------------------------------
# 节点级统一事务(): **config.auth.userpass + 节点元数据文件**是原子
# 事务(含 verified-restart/瞬态验证与失败双回滚), 消除"config 已提交而节点元数据写失败"
# 的两阶段漂移。**clash.yaml 是可再生的派生缓存, 不纳入事务** —— 阶段 4 同步失败仅告警,
# 不回滚节点本体(与 Xray 侧 _sync_node_clash 同口径; P2-1 0.16.4 修正契约描述)。
# 链接/元数据内容在事务前预构建(链接只依赖服务器级字段+本节点数据)。
# 用法: _hysteria_node_txn [--arg/--argjson ...] <config_filter> <meta_file> <op> <content>
# op = create: 原子写入 meta_file(存在则覆盖; 回滚还原旧文件或删除新建)
# delete: 删除 meta_file(fail-closed; 回滚还原)
# 返回 0 = config+meta 一致提交(clash 同步结果另计); 1 = 已回滚到原状(或显式报告回滚失败)
# ---------------------------------------------------------------------------
_hysteria_node_txn() {
    _with_config_lock _hysteria_node_txn_txn_wrapper "$@"
}

_hysteria_node_txn_txn_wrapper() {
    # 拆参: 尾随 4 个为 config_filter/meta_file/op/content, 其余为 jq 选项(delete 可省 content, 传 "-")
    # 注意: ${!var} 间接展开必须逐行声明 —— 同一条 local 里 m 与 ${!m} 会同时展开(m 未赋值即 invalid)
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

_hysteria_node_txn_locked() {
    local config_filter="$1" meta_file="$2" meta_op="$3" meta_content="${4:-}"; shift 4
    _hysteria_config_preflight || return 1
    local was_running; was_running=$(_manage_hysteria status 2>/dev/null)
    if ! _hysteria_backup_config; then
        _error "配置备份失败, 中止操作"
        return 1
    fi
    # 节点元数据快照(存在性感知)
    local meta_had=0 meta_bak="" node_name=""
    if [ "$meta_op" = "delete" ] && [ -f "$meta_file" ]; then
        node_name=$(jq -r '.name // empty' "$meta_file" 2>/dev/null)
    fi
    if [ -f "$meta_file" ]; then
        meta_had=1
        meta_bak=$(mktemp "${meta_file}.bak.XXXXXX") || { _error "无法备份节点元数据"; return 1; }
        if ! cp -p "$meta_file" "$meta_bak"; then
            rm -f "$meta_bak"
            _error "无法备份节点元数据"
            return 1
        fi
        chmod 600 "$meta_bak" 2>/dev/null
    fi
    # --- 阶段 1: config 变更(此前的失败 = 一切未变) ---
    local tmp
    tmp=$(mktemp "${HYSTERIA_CONFIG}.XXXXXX") || { _error "无法创建临时配置"; return 1; }
    if ! jq "${@}" "$config_filter" "$HYSTERIA_CONFIG" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        local jq_err; jq_err=$(jq "${@}" "$config_filter" "$HYSTERIA_CONFIG" 2>&1 >/dev/null | head -3)
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
    # 节点侧回滚 helper(meta 还原/删除 + clash 派生同步)
    # 节点侧回滚 helper(meta 还原/删除 + clash 派生同步)。返回真实状态:
    # 0=已还原; 1=未能还原(调用方据此判 degraded, 不再假定"回滚完成")
    _hysteria_node_txn_meta_rollback() {
        local rc=0
        if [ "$meta_had" -eq 1 ] && [ -s "$meta_bak" ]; then
            local mc
            mc=$(cat "$meta_bak" 2>/dev/null)
            if [ -n "$mc" ] && _atomic_write_json "$meta_file" "$mc"; then
                _hysteria_sync_clash "$meta_file" 2>/dev/null || true
            else
                _warn "节点元数据回滚失败, 请人工核对 $meta_file"
                rc=1
            fi
        else
            if rm -f "$meta_file"; then
                if [ -n "$node_name" ]; then
                    _hysteria_remove_clash_by_name "$node_name"
                fi
            else
                _warn "节点元数据删除失败, 请人工核对 $meta_file"
                rc=1
            fi
        fi
        return "$rc"
    }
    # --- 阶段 2: 节点元数据变更 ---
    if [ "$meta_op" = "create" ]; then
        if ! _atomic_write_json "$meta_file" "$meta_content"; then
            rm -f "$meta_bak"
            _hysteria_restore_config
            _hysteria_recover_to_state "$was_running"
            _error "节点元数据写入失败, 已回滚配置"
            return 1
        fi
    elif [ "$meta_op" = "delete" ]; then
        # rm 失败必须 fail-closed —— 否则 config 已删用户而 metadata
        # 仍存在(权限/immutable/只读 fs/IO 错误), 事务却报成功, 留下幽灵节点。
        if ! rm -f "$meta_file"; then
            _error "节点元数据删除失败(权限/只读?), 回滚配置"
            _hysteria_restore_config
            _hysteria_recover_to_state "$was_running"
            rm -f "$meta_bak" 2>/dev/null
            return 1
        fi
    fi
    # --- 阶段 3: 按 was_running 提交(语义一致) ---
    if [ "$was_running" = "running" ]; then
        if ! _hysteria_restart_verified; then
            _error "hysteria 启动失败, 回滚配置与节点状态"
            # config 回滚失败也必须继续回滚节点元数据并报降级状态
            local cfg_ok=0
            _hysteria_restore_config && cfg_ok=1
            local meta_ok=0
            _hysteria_node_txn_meta_rollback && meta_ok=1
            rm -f "$meta_bak" 2>/dev/null
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ]; then
                _error "回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败)), 已进入降级状态"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $meta_file"
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
            rm -f "$meta_bak" 2>/dev/null
            if [ "$cfg_ok" -ne 1 ] || [ "$meta_ok" -ne 1 ]; then
                _error "回滚未完成(config=$([ "$cfg_ok" -eq 1 ] && echo 已还原 || echo 失败) meta=$([ "$meta_ok" -eq 1 ] && echo 已还原 || echo 失败)), 已进入降级状态"
                _tip "请人工核对: $HYSTERIA_CONFIG 与 $meta_file"
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
    # --- 阶段 4: clash 派生(可再生缓存, 失败不回滚本体, 仅告警) ---
    if [ "$meta_op" = "delete" ]; then
        [ -n "$node_name" ] && _hysteria_remove_clash_by_name "$node_name"
    else
        _hysteria_sync_clash "$meta_file" || _warn "clash 条目同步失败, 节点本体不受影响, 可手工编辑 ${CLASH_YAML}"
    fi
    [ -n "$meta_bak" ] && { rm -f "$meta_bak" 2>/dev/null || _warn "临时备份清理失败: $meta_bak"; }
    return 0
}

_hysteria_server_txn_txn_wrapper() {
    # 拆参: 最后两个参数是 config/meta filter, 其余为 jq 选项
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

# 服务器是否已完成初始化(配置存在 + jq 可解析 + auth 段就绪)
# 三态判定(P1-3): 官方 auth.type 有 password/userpass/http/command 四种,
# 绝不能把"存在但非 userpass"的合法官方配置当成未初始化而 bootstrap 覆盖。
_hysteria_config_exists() {
    [ -f "$HYSTERIA_CONFIG" ] && [ -s "$HYSTERIA_CONFIG" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e . "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

_hysteria_server_initialized() {
    _hysteria_config_exists || return 1
    # P2-2(第八轮评审): 空 userpass 表不是可运行状态(官方 binary 直接 FATAL), 也不能算已初始化
    # —— 否则手工留下 {"type":"userpass","userpass":{}} 时菜单放行, 但服务起不来且无节点。
    jq -e '.auth.type == "userpass" and (.auth.userpass | type == "object") and ((.auth.userpass | length) > 0)' "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

# 菜单操作闸门: initialized → 放行; 配置存在但 auth 非 userpass 或 userpass 为空 → 明确
# "不接管/状态不完整"; 无配置 → 提示初始化路径。返回 1 时调用方中止操作。
_hysteria_gate() {
    _hysteria_server_initialized && return 0
    if _hysteria_config_exists; then
        if jq -e '.auth.type == "userpass"' "$HYSTERIA_CONFIG" >/dev/null 2>&1; then
            _error "Hysteria 配置的 auth.userpass 表为空(不完整状态): $HYSTERIA_CONFIG"
            _tip "空表无法启动(官方 binary 会 FATAL); 请删除该配置后重新初始化, 或手工补一个用户"
        else
            _error "检测到现有 Hysteria 官方配置($HYSTERIA_CONFIG), 其 auth 不是本 Manager 管理的 userpass 模式"
            _tip "为防止覆盖现有配置, 菜单操作不可用; 如需接管请自行备份并手工把 auth 段转换为 userpass 表, 或删除该配置后重新初始化"
        fi
    else
        _warn "Hysteria 服务器未初始化, 请先通过 [添加节点] 初始化"
    fi
    return 1
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
    echo -e "  ${GREEN}[3]${NC} ACME 自动证书 (本向导用 HTTP/TLS 质询; DNS 质询请手工编辑 hysteria.json)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  请选择: " choice || return 1
    case "${choice:-0}" in
        0) return 1 ;;
        1)
            _hysteria_installed || { _error "官方核心未安装, 无法生成自签证书"; return 1; }
            mkdir -p "$HYSTERIA_CERT_DIR" || return 1
            read -rp "  证书域名/SAN (回车默认 example.com): " host
            host=${host:-example.com}
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
            _warn "HTTP/TLS 质询需要 80/443 可达(NAT VPS 通常不满足); DNS 质询不依赖 80/443, 请手工在 hysteria.json 的 acme 段配置 type: dns"
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
# a) 系统已监听的 UDP 端口落进范围(会被官方 REDIRECT 遮蔽)
# b) Xray config inbound 端口落进范围
# c) Xray Hy2 节点的 iptables 跳跃范围与本范围相交
# 第 3 参 exclude = 当前 hysteria 自身监听的首端口(P2): 改跳跃范围时新
# 范围包含当前端口(如 :443 → :443-50000)是官方语义允许的合法配置 —— restart 后旧
# 监听即释放, 自身端口不算外部冲突。
# 用法: _hysteria_check_hop_conflicts <lo> <hi> [exclude]; 有冲突返回 1(已打印说明)
_hysteria_check_hop_conflicts() {
    local lo="$1" hi="$2" exclude="${3:-}" p
    [[ "$lo" =~ ^[0-9]+$ ]] && [[ "$hi" =~ ^[0-9]+$ ]] || return 1
    local hit=""
    # a) 一次 ss 快照(范围可上万, 逐端口探测太慢); exclude = hysteria 自身端口。
    # 列位: ss 数据行 $4=本机 addr:port, $5=对端(*:*, 无端口) —— 用 $5 是空扫(已修)。
    if command -v ss >/dev/null 2>&1; then
        while read -r p; do
            [ -n "$p" ] || continue
            [ -n "$exclude" ] && [ "$p" = "$exclude" ] && continue
            [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ] && hit="$hit $p"
        done <<< "$(ss -lun 2>/dev/null | awk 'NR > 1 {print $4}' | grep -oE '[0-9]+$' | sort -un)"
    fi
    [ -n "$hit" ] && { _error "以下端口已被本机监听, 与跳跃范围冲突:$hit"; return 1; }
    # b) Xray config 中 **UDP 能力** 的入站端口(P2-3: TCP-only 的 vless/reality/xhttp 等
    # 不与 hysteria 的 UDP 范围冲突 —— TCP 443 与 UDP 443 可共存)。UDP 能力口径:
    # hysteria2(QUIC)/dokodemo-door 原生 UDP; socks 需 settings.udp=true;
    # mKCP/QUIC 传输走 UDP。
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        while read -r p; do
            [ -n "$p" ] || continue
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            if [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ]; then
                _error "Xray 入站端口 $p 在跳跃范围内, 会造成端口冲突"
                return 1
            fi
        done <<< "$(jq -r '
            .inbounds[]? | select(.port != null) |
            select(
                .protocol == "hysteria2" or
                .protocol == "dokodemo-door" or
                (.protocol == "socks" and ((.settings.udp // false) == true)) or
                ((.streamSettings.network // "") == "mkcp") or
                ((.streamSettings.network // "") == "quic")
            ) | .port' "$CONFIG_FILE" 2>/dev/null)"
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

# mimic 是否已启用。官方文档 Mimic.md: "It cannot be combined with
# port hopping... Hysteria rejects such a config at startup" —— Manager 不得主动生成该组合。
_hysteria_mimic_enabled() {
    [ -f "$HYSTERIA_CONFIG" ] || return 1
    jq -e '(.mimic.enabled // false) == true' "$HYSTERIA_CONFIG" >/dev/null 2>&1
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
# 分享链接 = 纯派生值(评审第八轮 P1-1/P1-2 方案 A): 由 hysteria.json(服务器级) +
# server_meta.json + 节点元数据实时计算, **不再作为持久 canonical state 写回 nodes/*.json**。
# 理由: share_link 本质是 "server state + node state" 的表示形式, 持久化会引入第 4 份需要
# 同步的状态 —— 服务器级变更(TLS/端口/obfs)后若写回失败, 用户会看到旧链接而操作仍报成功;
# 节点创建时若预构建失败, 又会把空链接固化。改为动态派生后两个问题一并消失。
# 用法: link=$(_hysteria_node_link <meta_file>); 失败/缺字段时输出空串并返回 1
_hysteria_node_link() {
    local meta="$1" link
    [ -f "$meta" ] || return 1
    link=$(_hysteria_build_link "$meta") || return 1
    [ -n "$link" ] || return 1
    printf '%s' "$link"
}

# 重新同步所有节点的派生数据(clash 条目)。链接无需"重建写回"——它是动态派生的。
# 保留本函数作为服务器级变更后的统一收尾入口(旧调用点语义不变)。
_hysteria_rebuild_all_links() {
    local f fail=0
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        # 校验派生链接可用(缺字段/坏配置时告警, 但不写回)
        if ! _hysteria_node_link "$f" >/dev/null; then
            _warn "分享链接派生失败(元数据缺字段?): $(basename "$f" .json)"
            fail=1
            continue
        fi
        _hysteria_sync_clash "$f" || fail=1
    done
    return "$fail"
}

_hysteria_port_menu() {
    local choice part lo hi new_listen cur_first
    _hysteria_gate || { _press_any_key; return; }
    cur_first=$(_hysteria_listen_port_part "$(_hysteria_config_get listen)" 2>/dev/null)
    cur_first=${cur_first%%-*}   # 跳跃范围下监听的只是首端口
    while true; do
        clear
        echo; echo -e "  ${CYAN}【端口 / 端口跳跃】${NC}"
        echo -e "  当前: ${CYAN}$(_hysteria_listen_display)${NC}"
        echo -e "  ${YELLOW}官方机制: 端口跳跃 = listen 写端口范围, binary 监听首端口并自动重定向其余端口,${NC}"
        echo -e "  ${YELLOW}停止服务时自动清理防火墙规则(与 Xray Hy2 的 iptables 方案相互独立)${NC}"
        # 手工扩展的高级官方字段(如 mimic/ech)不在菜单管理范围内,
        # 但可能与本页操作互斥或依赖特定运行环境, 在此给出提示
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
                # 新端口 == 当前自身监听端口: 未变更, 无需占用检查(自身持有不算冲突)
                if [ "$part" != "$cur_first" ]; then
                    _check_port_occupied "$part" udp && { _warn "端口 $part 已被占用"; _press_any_key; continue; }
                    _check_port_in_config "$part" && { _warn "端口 $part 已被 Xray 节点使用"; _press_any_key; continue; }
                fi
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
                # 官方 listen 只支持单段连续范围(文档形态 :<min>-<max>), 逗号多段未定义 → 拒绝
                [[ "$part" == *","* ]] && { _warn "官方 listen 仅支持单段连续范围"; _press_any_key; continue; }
                local parsed
                parsed=$(_parse_hop_ranges "$part") || { _press_any_key; continue; }
                lo="${parsed%%:*}"; hi="${parsed##*:}"
                [ "$lo" = "$hi" ] && { _warn "跳跃范围至少两个端口(单端口无需跳跃)"; _press_any_key; continue; }
                # 官方禁止 mimic 与端口跳跃同用(Hysteria 启动即拒绝),
                # Manager 不得主动生成该组合
                if _hysteria_mimic_enabled; then
                    _error "当前配置已启用 mimic, 官方不允许 mimic 与端口跳跃同时启用(Hysteria 会拒绝启动)"
                    _tip "请先关闭 mimic(手工编辑 hysteria.json 的 mimic.enabled)后再启用端口跳跃"
                    _press_any_key; continue
                fi
                # exclude=当前自身监听首端口(评审 P2): :443 → :443-50000 是官方允许的合法变更
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
                if [ "$part" != "$cur_first" ]; then
                    _check_port_occupied "$part" udp && { _warn "端口 $part 已被占用"; _press_any_key; continue; }
                fi
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
    # 统一事务(评审 P1-4): 官方配置与 manager 元数据(tls_mode/sni/pin)作为一个整体
    # 提交/回滚, 杜绝"config=新 TLS / server_meta=旧 TLS"的漂移
    if ! _hysteria_server_txn --argjson blk "$HY_TLS_JSON" \
         --arg m "$HY_TLS_MODE" --arg s "$HY_TLS_SNI" --arg p "$HY_TLS_PIN" \
         '. + $blk | if $blk | has("tls") then del(.acme) else del(.tls) end' \
         '.tls_mode=$m | .sni=$s | .pin=$p'; then
        _error "TLS 设置失败"
        _press_any_key
        return 0
    fi
    _hysteria_rebuild_all_links || _warn "部分分享链接重建失败"
    _success "TLS 已切换: $(_hysteria_tls_desc)"
    [ "$HY_TLS_MODE" = "selfsigned" ] && _tip "自签证书: 客户端需 insecure=1 + pinSHA256(已写入链接)"
    [ "$HY_TLS_MODE" = "acme" ] && _tip "ACME 模式: 客户端无需 insecure; 证书由官方核心自动续期"
    _press_any_key
    return 0
}

_hysteria_obfs_menu() {
    local choice pw cur_obfs
    _hysteria_gate || { _press_any_key; return; }
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

# clash.yaml(mihomo) 条目。字段依据 = mihomo 源码 adapter/outbound/hysteria2.go 的
# Hysteria2Option 解码器(2026-09-13 核验): 认证字段只有 `password`(无 auth/username),
# 值为原始协议认证串 —— userpass 服务端填 "user:pass"(按首个冒号切分);
# `ports` 启用跳跃并忽略 port(port 保留作旧版 mihomo 的兜底)。
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
    local line="- {name: \"$(_yaml_dq "$name")\", type: hysteria2, server: \"$(_yaml_dq "$addr")\", port: ${port_part%%-*}, password: \"$(_yaml_dq "$user"):$( _yaml_dq "$auth")\""
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

    # 0) 前置保护: 存在非本 Manager 管理的官方配置(auth != userpass)时绝不 bootstrap
    # —— bootstrap 会整体重写配置文件, 静默覆盖用户已有的合法配置是不可接受的
    if _hysteria_config_exists && ! _hysteria_server_initialized; then
        _error "检测到现有 Hysteria 官方配置($HYSTERIA_CONFIG), 其 auth 不是本 Manager 管理的 userpass 模式"
        _tip "为防止覆盖现有配置, 已取消初始化; 如需接管请自行备份并手工转换 auth 段, 或确认无用后删除该配置再重试"
        return 1
    fi

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
        # 官方禁止 mimic + 端口跳跃组合(启动即拒绝)
        if _hysteria_mimic_enabled; then
            _error "配置已启用 mimic, 官方不允许 mimic 与端口跳跃同时启用"
            _tip "请先关闭 hysteria.json 的 mimic.enabled"
            return 1
        fi
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
    # server_meta 单次原子提交(P2-1): 逐次 _meta_set 会在中途失败时留下半成品元数据
    # (config 已删而 server_meta 残留旧值); 初始化语义下整份构建 + 一次原子写。
    local server_meta_json
    server_meta_json=$(jq -n --arg a "$addr" --arg m "$tls_mode" --arg s "$tls_sni" \
        --arg p "$tls_pin" --arg c "$(date '+%Y-%m-%d')" \
        '{link_addr:$a, tls_mode:$m, sni:$s, pin:$p, created:$c}') || {
        _error "服务器元数据组装失败"; rm -f "$HYSTERIA_CONFIG"; return 1
    }
    if ! _atomic_write_json "$HYSTERIA_SERVER_META" "$server_meta_json"; then
        _error "服务器元数据写入失败"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    fi

    # 7.5) 首位节点元数据 + 分享链接: 必须在**启动服务之前**落地 ——
    # 否则 service 已 running 而 nodes/<user>.json 缺失时, Hysteria 侧用户可用但 Manager
    # 完全看不到该节点(幽灵用户), 且此处失败不回滚会让初始化停在半成品状态。
    # 链接构建须喂真实临时文件 —— <(process substitution) 的 fd 带 CLOEXEC,
    # 函数内部 $(jq ...) 子进程打不开 /dev/fd/63(实测), 与 _hy2_gen_newmeta 同款模式。
    # 链接派生失败必须中止初始化(不得固化空链接); share_link 不再持久化(动态派生)。
    local link meta_json tmp_meta
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || {
        _error "临时节点元数据创建失败, 回滚初始化"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    }
    if ! jq -n --arg u "$user" --arg a "$auth" --arg n "$name" --arg addr "$addr" \
         '{user:$u,auth:$a,name:$n,link_addr:$addr}' > "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta"
        _error "临时节点元数据构建失败, 回滚初始化"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    fi
    if ! link=$(_hysteria_build_link "$tmp_meta") || [ -z "$link" ]; then
        rm -f "$tmp_meta"
        _error "分享链接派生失败, 回滚初始化"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    fi
    rm -f "$tmp_meta"
    meta_json=$(jq -n --arg u "$user" --arg a "$auth" --arg n "$name" \
        --arg addr "$addr" --arg created "$(date '+%Y-%m-%d')" \
        '{user:$u,auth:$a,name:$n,link_addr:$addr,created:$created}')
    if ! _atomic_write_json "$HYSTERIA_NODES_DIR/${user}.json" "$meta_json"; then
        _error "首位节点元数据写入失败, 回滚初始化(配置/元数据)"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    fi

    # 8) 服务(创建结果必须消费: P2-3 —— 创建失败 ≠ 启动失败, 报错要指向真实步骤)
    if ! _hysteria_create_service; then
        _error "service 创建失败(daemon-reload/权限?), 回滚初始化"
        # service 定义未能清理干净时**保留**配置/元数据供人工恢复,
        # 而不是删掉文件留下"unit 残留 + config 缺失"的不可恢复状态
        if ! _hysteria_cleanup_service_units; then
            _error "service 定义清理失败, 已保留配置与元数据以便人工恢复(不删除)"
            _tip "请人工清理 service 后, 删除 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODES_DIR/${user}.json"
            return 1
        fi
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODES_DIR/${user}.json"
        rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
        return 1
    fi
    if [ "$INIT_SYSTEM" != "direct" ]; then
        if ! _hysteria_restart_verified; then
            _error "Hysteria 服务启动失败, 回滚初始化(配置/服务)..."
            _hysteria_stop_and_verify >/dev/null 2>&1 || _warn "停止服务时仍有残留进程, 请人工核对"
            if ! _hysteria_cleanup_service_units; then
                _error "service 定义清理失败, 已保留配置与元数据以便人工恢复(不删除)"
                _tip "请人工清理 service 后, 删除 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODES_DIR/${user}.json"
                return 1
            fi
            rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODES_DIR/${user}.json"
            rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
            _warn "初始化已回滚"
            return 1
        fi
    else
        # direct 模式无 service: 启动并做 1s 存活检查
        if ! _manage_hysteria start; then
            rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODES_DIR/${user}.json"
            _error "启动失败, 已回滚配置"
            return 1
        fi
    fi

    # 9) clash 派生缓存(可再生; 失败仅告警, 不影响节点本体)
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

    # 节点级统一事务: userpass + 节点元数据 整体提交/回滚; clash 为可再生派生缓存。
    # P1-1(第八轮评审): 链接是节点创建结果的一部分, 派生失败必须**中止创建** —— 不得把空
    # 链接固化进节点(用户会"创建成功"却拿不到链接)。链接已改为动态派生, 故此处仅做预检。
    # 链接构建喂 mktemp 临时文件(<(fd) 带 CLOEXEC, 函数内 $(jq) 子进程打不开, 见 bootstrap 同注)
    local tmp_meta link
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || {
        _error "临时节点元数据创建失败, 节点未创建"
        return 1
    }
    if ! jq -n --arg u "$user" --arg a "$auth" --arg n "$name" \
         --arg addr "$(_hysteria_meta_get link_addr)" \
         '{user:$u,auth:$a,name:$n,link_addr:$addr}' > "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta"
        _error "临时节点元数据构建失败, 节点未创建"
        return 1
    fi
    if ! link=$(_hysteria_build_link "$tmp_meta") || [ -z "$link" ]; then
        rm -f "$tmp_meta"
        _error "分享链接派生失败(服务器配置不完整?), 节点未创建"
        _tip "请先确认 hysteria.json 的 listen/tls 等服务器级字段完整"
        return 1
    fi
    rm -f "$tmp_meta"
    # 元数据不再持久化 share_link(动态派生): 只存 node state
    local meta_json
    meta_json=$(jq -n --arg u "$user" --arg a "$auth" --arg n "$name" \
        --arg addr "$(_hysteria_meta_get link_addr)" --arg created "$(date '+%Y-%m-%d')" \
        '{user:$u,auth:$a,name:$n,link_addr:$addr,created:$created}')
    if ! _hysteria_node_txn --arg u "$user" --arg p "$auth" \
        '.auth.userpass[$u] = $p' \
        "$HYSTERIA_NODES_DIR/${user}.json" create "$meta_json"; then
        _error "节点添加失败"
        return 1
    fi
    _success "节点 [${name}] 创建成功"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
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
    echo
    local f n=0
    for f in "$HYSTERIA_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$((n+1))
        local name user link
        name=$(jq -r '.name // empty' "$f" 2>/dev/null)
        user=$(jq -r '.user // empty' "$f" 2>/dev/null)
        # share_link 动态派生(旧节点若残留持久化值, 仅在派生失败时回退显示, 避免信息丢失)
        link=$(_hysteria_node_link "$f") || link=$(jq -r '.share_link // empty' "$f" 2>/dev/null)
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
    _hysteria_gate || { _press_any_key; return; }
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
    # 节点级统一事务(): userpass 删除 + 节点元数据删除 + clash 移除一体提交/回滚
    if ! _hysteria_node_txn --arg u "$user" 'del(.auth.userpass[$u])' \
        "$HYSTERIA_NODES_DIR/${user}.json" delete "-"; then
        _error "删除失败(节点状态保持原状)"
        _press_any_key
        return
    fi
    _success "节点已删除"
    _press_any_key
    return 0
}

_hysteria_change_password() {
    local choice users=() i=1 user name auth
    _hysteria_gate || { _press_any_key; return; }
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
    # 节点级统一事务: 只用新密码更新元数据(auth), 链接动态派生 → 天然使用新密码。
    # 链接先预检(派生失败则中止), 但不再把 link 写回元数据(避免第 4 份需同步的状态)。
    local meta="$HYSTERIA_NODES_DIR/${user}.json" newlink tmp_meta
    [ -f "$meta" ] || { _error "节点元数据不存在($meta), 无法改密码, 请删除后重建"; _press_any_key; return; }
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || { _error "临时文件创建失败"; _press_any_key; return; }
    if ! jq --arg p "$auth" '.auth=$p | del(.share_link)' "$meta" > "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta"; _error "元数据构建失败"; _press_any_key; return
    fi
    if ! newlink=$(_hysteria_build_link "$tmp_meta") || [ -z "$newlink" ]; then
        rm -f "$tmp_meta"; _error "分享链接派生失败(服务器配置不完整?), 未修改"; _press_any_key; return
    fi
    local newmeta
    newmeta=$(cat "$tmp_meta") || { rm -f "$tmp_meta"; _error "元数据读取失败"; _press_any_key; return; }
    rm -f "$tmp_meta"
    if ! _hysteria_node_txn --arg u "$user" --arg p "$auth" \
        '.auth.userpass[$u] = $p' "$meta" create "$newmeta"; then
        _error "密码修改失败"
        _press_any_key
        return
    fi
    _success "密码已修改"
    echo -e "  ${CYAN}新分享链接:${NC} ${newlink}"
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

# 卸载/清理前的停止确认(): stop 后轮询确认业务进程真正退出;
# 仍存活时按 exe 归属(readlink /proc/*/exe == $HYSTERIA_BIN, 含 "(deleted)" 就地替换
# 形态)强制终止 —— exe 校验保证绝不误杀同名的他方进程; 再不退则返回 1 交人工处理,
# 调用方必须拒绝继续删除文件, 避免"文件已删/进程仍在"的孤儿进程。
_hysteria_stop_and_verify() {
    _manage_hysteria stop 2>/dev/null
    local i p exe
    for i in 1 2 3 4 5 6 7 8; do
        _hysteria_is_running || return 0
        sleep 1
    done
    _warn "服务停止后仍有 hysteria 进程存活, 按 exe 归属强制终止..."
    for p in /proc/[0-9]*; do
        exe=$(readlink "${p}/exe" 2>/dev/null) || continue
        case "$exe" in
            "$HYSTERIA_BIN"|"$HYSTERIA_BIN (deleted)")
                kill -9 "${p##*/}" 2>/dev/null
                ;;
        esac
    done
    sleep 1
    _hysteria_is_running || return 0
    return 1
}

# service 定义清理 + 最终状态验证: 原回滚路径的 disable/rm/daemon-reload
# 全是 best-effort, 失败会让"unit 残留 + config 已删"的半残状态静默通过。这里逐步执行并
# 复核 unit 确实消失(systemd 用 LoadState=not-found, openrc 用文件不存在), 残留时大声告警
# 并给出人工命令 —— 属"明确降级"而非静默成功。返回 0=已清理干净; 1=仍有残留(已告警)。
_hysteria_cleanup_service_units() {
    local ok=1
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable "$HYSTERIA_SVC" 2>/dev/null
            rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service"
            systemctl daemon-reload 2>/dev/null
            systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
            [ "$(systemctl show -p LoadState --value "$HYSTERIA_SVC" 2>/dev/null)" = "not-found" ] && ok=0
            [ "$ok" -eq 0 ] || {
                _error "systemd unit ${HYSTERIA_SVC} 清理后仍可被 systemd 识别(残留)"
                _tip "请人工核对: systemctl status ${HYSTERIA_SVC}; ls -l /etc/systemd/system/${HYSTERIA_SVC}.service"
            }
            ;;
        openrc)
            rc-update del "$HYSTERIA_SVC" default 2>/dev/null
            rm -f "/etc/init.d/${HYSTERIA_SVC}"
            [ ! -e "/etc/init.d/${HYSTERIA_SVC}" ] && ok=0
            [ "$ok" -eq 0 ] || {
                _error "openrc init 脚本 ${HYSTERIA_SVC} 未能删除(残留)"
                _tip "请人工核对: ls -l /etc/init.d/${HYSTERIA_SVC}"
            }
            ;;
        *)
            ok=0 ;;
    esac
    rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
    return "$ok"
}

# 独立卸载(菜单 [13]): 停服(确认进程退出) → 删 service → 删派生缓存条目 → 删 binary/配置/数据/证书/日志/state
_hysteria_uninstall() {
    local ans f name
    _hysteria_installed || [ -f "/etc/systemd/system/${HYSTERIA_SVC}.service" ] || [ -f "/etc/init.d/${HYSTERIA_SVC}" ] \
        || { _warn "官方 Hysteria2 未安装"; _press_any_key; return 0; }
    echo; read -rp "  确认卸载官方 Hysteria2(删除核心/配置/全部节点数据, 不可恢复)? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; _press_any_key; return 0 ;;
    esac
    _hysteria_stop_and_verify || { _error "hysteria 进程未退出, 已中止卸载以避免孤儿进程(文件未删除), 请手动停止后重试"; _press_any_key; return 1; }
    # service 定义清理失败必须**中止卸载并保留文件** —— 原写法 warn 后
    # 继续 rm, 会留下"unit 残留 + binary/config 缺失"(unit 仍 enabled 时下次开机尝试启动一个
    # 已不存在的 ExecStart)。与 bootstrap 的"清理失败保留现场"契约统一。
    if ! _hysteria_cleanup_service_units; then
        _error "service 定义清理失败, 已中止卸载(核心/配置/数据均保留)"
        _tip "请按上方提示人工清理 service 后重试卸载"
        _press_any_key
        return 1
    fi
    case "$INIT_SYSTEM" in
        systemd) ;; openrc) ;; esac
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
    # 停止必须确认进程真正退出(exe 兜底强杀), 否则 _uninstall_xray 的
    # rm -rf $DEPLOY_DIR 会留下"文件已删/进程仍在"的孤儿进程; 返回 1 时调用方中止卸载
    _hysteria_stop_and_verify || return 1
    # 清理失败返回 1 → 调用方(_uninstall_xray)中止 rm -rf;
    # 保留文件避免"unit 残留 + 项目目录已删"的不可恢复状态
    _hysteria_cleanup_service_units || return 1
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
        echo -e "  ${CYAN}【Hysteria2 管理 — 官方核心 (HyNetworks/hysteria)】${NC}"
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
