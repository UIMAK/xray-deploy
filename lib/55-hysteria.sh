#!/bin/bash
# =============================================================================
# lib/55-hysteria.sh — Official Hysteria2 Manager(官方 Hysteria2 服务端管理)
# 与 Xray Hy2(lib/50-nodes.sh 的 hysteria2 协议)是完全独立的两个实现:
# Xray Hy2     = Xray-core 实现的 hysteria2 协议, _hy2_* 函数族, config.json 模型
# Official Hy2 = HyNetworks/hysteria 官方 binary(旧组织名 apernet 已 301), _hysteria_* 函数族
# 两者不得共享配置模型/binary/版本管理/服务/认证与链接生成逻辑。
#
# 关键事实(官方文档 + get.hy2.sh + 2.12.2 实测, 2026-09-13):
# - 官方配置完整支持 JSON(与 YAML 同构), 故 hysteria.json 全部 jq 生成/变更
# - 无 check/validate 子命令, 坏配置 = 启动 FATAL exit 1 ⇒ 只能靠 verified-restart 失败回滚
# - 端口跳跃是官方内置(listen 写 ":<min>-<max>"), 本模块**绝不自己写防火墙规则**
#   (与 Xray Hy2 的 iptables DNAT 是两条路); 只支持单段连续区间
# - 完整性校验 = 官方 hashes.txt SHA256(fail-closed) + 可执行自检 + 版本匹配三层
# - 混淆 obfs 官方有两种 salamander / gecko; gecko 的尺寸是**配置文件字段**, 官方 URI-Scheme
#   没有尺寸参数 ⇒ gecko 非默认尺寸时**拒绝生成链接**(判据唯一入口 _hysteria_obfs_uri_gap),
#   clash 条目有独立字段可完整表达
# - AVX 变体自动选择, 但必须有装机后**真实启动验证**兜底(version 自检不覆盖热路径 AVX 指令)
# - 架构映射以官方 get.hy2.sh 为基准并**更严格**: armv6/mips(BE)/mips64 明确拒绝; 补 armv5*/riscv64
# - **认证模型 = 单一认证密码(auth.type: password), 不是 userpass**(0.16.19 用户实测):
#   官方 userpass 的认证串是 `username:password`, 而 Xray/sing-box 只提交单一字符串, 用户必须
#   手填 `user:pass` 才能连 —— 互操作硬约束, 不是偏好。代价(用户已确认): 不再支持多用户,
#   一个 auth 段 = 一个密码, 节点 = 服务器的唯一凭据。本模块从未发布过 userpass 版本, 故
#   **不做任何迁移**; 检测到非 password 的 auth 一律按"外来配置"拒绝接管。
# - [4] 删除节点 = 删除服务器配置并停止服务(0.16.20, 用户要求, 动机省内存): 配置即节点。
#   固定顺序 停服 → 删 hysteria.json → 删 node.json → 清 service/logrotate → 清 clash 派生
#   条目; **删配置必须早于清 unit**(否则删配置失败时 unit 已消失、原运行状态无法恢复);
#   核心 binary / server_meta / 自签证书保留([2] 可重新初始化复用), 彻底移除走 [14] 卸载。
# =============================================================================

# ---------------------------------------------------------------------------
# 常量(官方 Hysteria2 专属, 与 XRAY_*/CF_* 平行)
# ---------------------------------------------------------------------------
export HYSTERIA_BIN="$BIN_DIR/hysteria"
export HYSTERIA_CONFIG="$DEPLOY_DIR/hysteria.json"
export HYSTERIA_DATA_DIR="$DEPLOY_DIR/hysteria"
export HYSTERIA_BACKUP_DIR="$DEPLOY_DIR/hysteria/backup"
# 唯一节点元数据(单密码模型: 一台服务器只有一个认证凭据 → 一份节点元数据)
export HYSTERIA_NODE_META="$DEPLOY_DIR/hysteria/node.json"
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
# 官方仓库已改名 HyNetworks/hysteria(旧名 301 重定向, 不再依赖)
export HYSTERIA_GH_API="https://api.github.com/repos/HyNetworks/hysteria/releases/latest"

# ---------------------------------------------------------------------------
# 数据目录(启动时由 _hysteria_menu 调用, 幂等; 对齐 _ensure_dirs 的权限口径)
# ---------------------------------------------------------------------------
_hysteria_ensure_dirs() {
    local ok=1 d f
    # LOG_DIR 一并确保: openrc output_log / direct 重定向都写 $LOG_DIR/hysteria.log,
    # 而模块可能被非 xd 主入口调用(cron/直接 source), 不能假设 _ensure_dirs 已跑过。
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

# 版本号 canonicalize: 官方 release tag 形态为 app/v2.12.2, GitHub API fallback 会拿到
# app/ 前缀; 统一在此剥离并校验 v2.x.x 格式
_hysteria_canon_version() {
    local v="${1#app/}"
    [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$v"; return 0; }
    return 1
}

# 从官方 hashes.txt(格式 "<sha256>  build/<asset>")提取指定资产的 SHA256。
# 精确锚定行尾防前缀误匹配(amd64 vs amd64-avx)。fail-closed: 0 条=无此资产、
# >1 条=校验文件异常(正常官方文件唯一) —— 都拒绝, 不取 tail。
_hysteria_expected_sha256() {
    local f="$1" name="$2" count sha
    [ -s "$f" ] || return 1
    count=$(grep -c " build/${name}\$" "$f" 2>/dev/null)
    [ "$count" = 1 ] || return 1
    sha=$(grep " build/${name}\$" "$f" | awk '{print $1}')
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$sha"
}

# 最新版本: 官方下载服务的 302 终点 URL 携带版本段(/app/latest/<asset> → /app/v2.12.2/<asset>);
# 失败回落 GitHub API latest(仓库改名后 API 会 301, 必须 -L 跟随; tag 形态 app/v2.x.x,
# 经 canonicalize)。两个通道都失败 → 输出空, 调用方显式处理。
_hysteria_latest_version() {
    local asset final ver
    asset=$(_hysteria_arch_asset) || return 1
    # 用 GET(只取最终 URL)而非 HEAD —— 部分 CDN/代理/缓存层对 HEAD 返 405 而 GET 正常。
    # 加 `-r 0-0`(Range: 只取第 1 字节): 不加时 curl 会把**整个 23MB binary** 拉完, 弱机/
    # 慢 CDN 上 15s 超时后只剩 API 兜底(实测因此误判过一次"重装失败")。官方 CDN 支持 Range;
    # 服务器忽略 Range 则退化旧行为, 不会更差。
    final=$(curl -fsSL -r 0-0 -o /dev/null --max-time 15 -w '%{url_effective}' \
            "${HYSTERIA_DL_BASE}/latest/hysteria-linux-${asset}" 2>/dev/null) || final=""
    ver=$(_hysteria_canon_version "$(printf '%s' "$final" | grep -o 'v[0-9]*\.[0-9]*\.[0-9]*' | head -1)")
    if [ -z "$ver" ] && command -v jq >/dev/null 2>&1; then
        ver=$(_hysteria_canon_version "$(curl -fsSL --max-time 15 "$HYSTERIA_GH_API" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)")
    fi
    [ -n "$ver" ] && echo "$ver"
    return 0
}

# ---------------------------------------------------------------------------
# 架构映射(uname -m → 官方资产名; 基准 = 官方 get.hy2.sh 映射表)
# 差异: armv5*/riscv64 取官方资产表(get.hy2.sh 漏列); armv6(官方 linux/arm 是 GOARM=7
# 构建, ARMv6 会 SIGILL)与 mips(BE)/mips64/mips64le 因 ABI 不兼容明确拒绝 ——
# uname 名相似 ≠ ABI 兼容, 无法可靠判定就拒绝并提示, 不猜。mipsle(含软浮点 mipsle-sf)不受影响。
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
        # armv6 明确拒绝: 官方 linux/arm 资产是 GOARM=7 构建, ARMv6 会 SIGILL;
        # 官方 release 无独立 armv6 平台, 不猜映射
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

# CPU 是否支持 AVX(amd64 AVX 变体的唯一判据)。`tr` 拆词 + `grep -qx` 整行匹配,
# 而非 `grep -qw avx`: busybox 的 -w 在部分构建不生效(实测把 avx2/avx_vnni 也算进来),
# 而 -qx 语义由 POSIX 明确, 与实现无关; 方向也安全: 只认真正的 avx 词条。
_hysteria_cpu_has_avx() {
    [ -r /proc/cpuinfo ] || return 1
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | tr ' ' '\n' | grep -qx avx
}

# 结合 CPU 能力给出最终资产名: x86_64 且 cpuinfo 有 avx → amd64-avx(**优先**), 否则 amd64。
# **变体不再由用户选择** —— 旧版手动开关与 state/hysteria_variant 已移除, 纯自动检测;
# 官方文档与实测 release 均提供该资产。自动选择必须自带兜底: cpuinfo 有 avx 但指令实际
# 不可执行时, 下载后可执行自检会失败, _hysteria_download_install 以 _HY_FORCE_PLAIN=1
# 重试普通 amd64 —— 没有这条自愈路径用户会被永久锁在"装不上"。
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

# ---------------------------------------------------------------------------
# binary 安装/升级事务:
# 解析资产 → 下载临时文件(同目录, 供原子 mv) → 官方 hashes.txt SHA256 校验 + 可执行自检
# + 版本匹配(三层, 见下) → 备份旧 binary → 停服 → 原子替换 → 启动 → verified → commit;
# 任一步失败恢复旧 binary 并重启旧版。配置与节点不受影响(官方 binary 更新不改配置语义)。
# 用法: _hysteria_download_install <version|latest>
# ---------------------------------------------------------------------------
_hysteria_download_install() {
    local want="$1" asset url tmp ver was_running=0 backup="" old_ver="" old_asset=""
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
    # 官方 hashes.txt 与 binary 同目录发布(2026-09-13 实证): SHA256 校验 fail-closed。
    # 拿不到官方校验和 = 不可信任下载内容 —— 自检+版本匹配只能证明"能执行且报对版本",
    # 无法证明"就是官方发布的那个 binary"。
    local h_file expected sha
    h_file=$(mktemp "$BIN_DIR/hashes.txt.XXXXXX") || { rm -f "$tmp"; _error "临时文件创建失败"; return 1; }
    if ! _http_download "${HYSTERIA_DL_BASE}/${want}/hashes.txt" "$h_file" 60 || [ ! -s "$h_file" ]; then
        rm -f "$h_file" "$tmp"
        _error "无法获取官方 hashes.txt 校验文件, 不能确认下载内容与官方发布一致, 已中止(当前安装未变动)"
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
        # 自愈兜底: 选了 AVX 版但本机执行不了(cpuinfo 假阳性/容器屏蔽)→ 自动改用普通
        # amd64 重试一次(_HY_FORCE_PLAIN 前缀赋值只作用于该次调用; 手动开关已移除,
        # 没有这条路径用户会永久卡在"每次安装都失败")。普通版再失败就是真失败。
        if [ "$asset" = "amd64-avx" ] && [ -z "${_HY_FORCE_PLAIN:-}" ]; then
            _warn "AVX 版无法在本机执行(可执行自检未通过), 自动改用普通 amd64 重试"
            _HY_FORCE_PLAIN=1 _hysteria_download_install "$want"
            return $?
        fi
        _error "下载内容校验失败(期望 ${want}, 实际 ${ver:-无法执行}), 已放弃替换"
        return 1
    fi
    if _hysteria_installed; then
        # 备份名必须**每次调用唯一**: 运行期 AVX 兜底会在本函数内嵌套再调一次, 固定名
        # ".hysteria.rollback.$$" 会被内层覆盖并在内层收尾时删除 —— 外层回滚就失去旧
        # binary(嵌套同 PID, $$ 不区分层级)。
        backup=$(mktemp "$BIN_DIR/.hysteria.rollback.XXXXXX") \
            || { rm -f "$tmp"; _error "回滚备份文件创建失败, 已中止"; return 1; }
        cp -p "$HYSTERIA_BIN" "$backup" || { rm -f "$tmp" "$backup"; _error "旧核心备份失败, 已中止"; return 1; }
        # 记录旧版本/旧资产, 回滚后据此校验"确实恢复到了旧版本"而不只是"服务在跑"
        old_ver=$(_hysteria_current_version)
        old_asset=$(_state_get hysteria_asset 2>/dev/null)
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
    # 记录**实际安装的资产名**(观察值, 不是用户配置): 运行期 AVX 兜底据此判断当前 binary
    # 是不是 AVX 变体 —— 不能靠 CPU 能力反推(自检兜底可能已把变体换成普通版)。写失败只降级
    # 不阻断: 兜底侧对缺失记录有第二来源(CPU 弱推断, 见 _hysteria_avx_runtime_retry)。
    _state_set hysteria_asset "$asset" || _warn "资产记录写入失败(不影响运行, AVX 兜底将按 CPU 弱推断)"
    if [ "$was_running" -eq 1 ]; then
        if _hysteria_restart_verified; then
            _success "官方 Hysteria2 核心已升级: ${want}"
        else
            # 自检只跑 `version` 子命令, 不覆盖热路径 AVX 指令。装的是 AVX 变体且启动
            # 失败时, 先换普通 amd64 重装重试, 再考虑回滚旧核心。
            if _hysteria_avx_runtime_retry "$want" "$asset"; then
                [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
                return 0
            fi
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
            _state_set hysteria_asset "$old_asset" 2>/dev/null || true
            [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
            return 1
        fi
    else
        _success "官方 Hysteria2 核心已安装: ${want}"
    fi
    [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# AVX 运行期兜底:
# 下载阶段的自检只执行 `hysteria version` —— 证明"这个 binary 能在本机执行", 但
# **不覆盖服务热路径**里的 AVX 指令。cpuinfo 报 avx 而实际不可执行(容器屏蔽、虚拟化暴露
# 不完整、异构迁移)时会出现"自检通过 → 装机 → 启动 SIGILL"。此时把已装的 AVX 变体换成
# 普通 amd64 重装并重试启动一次, 与自检兜底合成完整生命周期。
# 仅当**当前实际装的确实是 AVX 变体**才动手(据 state/hysteria_asset 判断, 不用 CPU 反推);
# _HY_FORCE_PLAIN 保证只重试一次(内层不再递归兜底)。
# 用法: _hysteria_avx_runtime_retry <version> <asset>; 返回 0 = 已换普通版且启动成功
# ---------------------------------------------------------------------------
_hysteria_avx_runtime_retry() {
    local want="$1" asset="$2"
    [ -n "$want" ] || return 1
    [ -z "${_HY_FORCE_PLAIN:-}" ] || return 1
    # 第二来源: state/hysteria_asset 只是观察值, 可能缺失或写入失败; `hysteria version`
    # 不区分 avx 变体(实测 v2.12.2 输出 Architecture: amd64), 也不值得为它下载 hashes.txt
    # 比对 SHA256(兜底触发频率极低)。改用与 _hysteria_pick_asset 同口径的保守弱推断:
    # amd64 + CPU 报 avx → 当初装的极可能就是 AVX 变体, 宁可多做一次兜底尝试
    # (若当初装的其实是普通版, 重装普通版同样能启动, 只多一次下载)。
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
    # 内层调用时服务不在运行(启动刚失败) → 它只替换 binary, 不重启; 重启与验证由这里做
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
    # AVX 变体不提供手动切换: 变体由 CPU 能力自动决定(见 _hysteria_pick_asset), 具体下载的
    # 资产名会在安装时的"下载 <url>"一行里体现(含 -avx 后缀)。
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

# ---------------------------------------------------------------------------
# 服务层(binary 与 service backend 解耦: systemd / openrc / direct 三分支,
# 运行的核心始终是 $HYSTERIA_BIN。Alpine 不因官方安装脚本要求 systemd 而被排除)
# ---------------------------------------------------------------------------

_hysteria_is_running() {
    # 结构复刻 _xray_is_running 的三分支判活(该函数是项目加固最重的函数, 不参数化共用,
    # 避免"为了 DRY 动它"引入回归):
    # systemd: 必须 ActiveState=active 且 SubState=running 且 MainPID 非 0 —— 只认"service
    # 真正在跑", 不回退全机扫描(否则宿主上别人的 hysteria 会被当成我们的服务)
    # openrc : pidfile 是 supervise-daemon 父进程, 需回溯 ppid 链找业务子进程
    # direct : pidfile 即业务进程
    # 兜底  : 全机扫描, 只认 exe 指向 $HYSTERIA_BIN 的进程
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
                    # 判活语义从"进程存在"提升为"service 真正 active/running"。只看
                    # MainPID != 0 会把 activating(auto-restart 等待期)/deactivating 也算成
                    # running —— 配置启动后 8~10s 才崩的场景下, 旧的 8 次全 running 轮询可能
                    # 整体落在该窗口内而误判成功并提交。加 ActiveState/SubState 后
                    # activating/deactivating/failed/auto-restart 自然全部排除。
                    #
                    # 进入本分支说明 `--value` **可用** —— 上面的 LoadState 就是用它读到的
                    # (systemd >= 230)。不支持的机器会落到 load="" 分支, **不会**走到这里,
                    # 故不再为它加额外分支(否则会出现"注释声称兼容、实际永不执行"的误导)。
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
                    # ActiveState 读不到(理论上不可达: 能读到 LoadState 就说明 --value 可用)。
                    # 用 is-active 精确判定, 再**尽量**用 MainPID 定位本单元进程树; 但
                    # MainPID 读不到时绝不判 stopped —— 交给函数末尾的全机 binary 归属扫描兜底
                    # (MainPID 可读时仍走更严格的本单元进程树校验, 不因兜底而降级)。
                    systemctl is-active --quiet "$HYSTERIA_SVC" 2>/dev/null || return 1
                    anchor=$(systemctl show -p MainPID --value "$HYSTERIA_SVC" 2>/dev/null)
                    if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ]; then
                        _proc_named_under "$anchor" hysteria && return 0
                    fi
                    ;;
            esac
            ;;
        direct)
            # direct 的 pidfile 由本脚本写, 可能带 starttime 身份(见 00-common `_xd_pidfile_*`)。
            # **有身份记录时身份就是权威**: 记录在而当前化身不符(已退出/被复用)直接判 stopped,
            # 不再由全机扫描兜底 —— 否则 `_hysteria_restart_verified` 会把坏配置下的假 running
            # 当成成功。
            if [ -n "$(_xd_pidfile_starttime "$HYSTERIA_PID_FILE")" ]; then
                _xd_pidfile_identity_ok "$HYSTERIA_PID_FILE" || return 1
            fi
            # exe 归属校验(P1-2): 只看 comm 会把陈旧 pidfile 指向的他方 hysteria 误认成本项目服务
            anchor=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE" 2>/dev/null)
            _hysteria_pid_is_ours "${anchor:-}" && return 0
            ;;
        openrc)
            # openrc: pidfile 是 supervise-daemon 父进程(其 exe 不是 hysteria), 不能用 exe
            # 直接校验 anchor, 需沿 ppid 链回溯业务子进程(与 _xray_is_running 同口径)
            anchor=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE" 2>/dev/null)
            if [ -n "$anchor" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" hysteria && return 0
            fi
            ;;
    esac
    _proc_any_named hysteria "$HYSTERIA_BIN"
}

# direct backend 的 PID 归属判定: 只看 comm=="hysteria" 太宽 —— PID reuse / 陈旧 pidfile
# 场景下, 别的 hysteria(系统包 / 用户自建)会被误认成本项目的服务, 甚至被 kill。统一到
# 卸载路径的同一口径: pid 数字合法 + /proc/<pid>/exe(含 "(deleted)" 形态, 经 readlink -f 归一)
# == $HYSTERIA_BIN。
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

# 判断以 anchor 为根(含自身)的进程树里是否存在 exe == $HYSTERIA_BIN 的进程。
# 用于 openrc supervisor 归属校验: supervisor 自身 exe 是 supervise-daemon, 需向下找业务子进程。
#
# **深度 4 是实现假设, 不是通用保证**。契约:
#   - rc=0: 在 anchor 向下 ≤4 层内找到 exe 完全等于 $HYSTERIA_BIN 的进程 ⇒ 确认归属;
#   - rc=1: **未确认归属** —— 包括"确实不是我们的"与"是我们的但层级 >4 / 读不到 exe";
#     两种故意不区分: 调用方只关心"能否证明是我们的", 证明不了就不动手。
# 失败方向 = fail-closed(宁可漏杀也不误杀他方服务): 调用方走"不杀 + 告警"分支, 由人工处理;
# 绝不会因为"看不清"而 kill 一个可能属于他方的 supervisor。深度 4 的依据: 本项目 openrc
# 是 `supervise-daemon → hysteria` 一层拓扑; 未来若改成多层 wrapper 需同步调大此值。
_hysteria_proc_tree_has_bin() {
    local anchor="$1" p c cur i
    local depth=4   # 见上方契约说明: 实现假设, 超出即返回 1(fail-closed)
    [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
    [ "$anchor" != "0" ] || return 1
    # **必须用严格版**: 本函数契约是 fail-closed, 而 _proc_exe_is 在读不到 /proc/<pid>/exe
    # 时**放行**(那是为判活设计的语义)。用宽松版会让"看不清"被当成"确认归属", 于是去 kill
    # 一个可能属于他方的 supervisor。混装旧 lib(00-common 是旧版)时严格版不存在: 按项目
    # 惯例用 declare -F 守卫, 此时**拒绝**(fail-closed, 与契约一致)。
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
    # fd9 关闭(9>&-): 本函数可能在 _with_config_lock 的锁子 shell 内被调用(config 事务),
    # openrc 的 supervise-daemon / direct 模式的 nohup 会继承全部打开 fd —— 守护进程
    # 持有 fd9 = flock 永远被持有, 后续所有配置事务 15s 超时失败(2026-09-13 Alpine 实测;
    # systemd 不继承业务 fd 故 Ubuntu 无感)。
    #
    # **写法必须是 local V="${V:-9}" + {V}>&-**: bash 不把 `${V:-9}>&-` 当重定向, 展开出来的
    # 数字会变成**位置参数**传给被调命令(实测 `systemctl start xray 10`), 锁 fd 也照旧被继承。
    # 变量归一成数字后 `{V}>&-` 才是真正只作用于该命令的重定向(详见 20-xray-core.sh 同名注释)。
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
                    # 高频 stop/start(事务/瞬态验证循环)会触发 systemd 启动限流
                    # "start-limit-hit", 之后 start 一律被拒 → 服务再也起不来。启动前清掉
                    # 限流计数(对未受限的 unit 是幂等 no-op), 与项目 xray 侧同口径。
                    systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
                    # start/restart 会派生守护进程: 一并关掉本项目可能持有的全部锁 fd
                    # (config 锁 fd9 + 核心/安装主锁 + 跨版本协调的旧版锁); 少关一把 = 锁不释放。
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
                # supervise-daemon respawn 耗尽进入 crashed 态后 start/restart 会被拒;
                # 仅在确认无真实业务进程时 zap 复位(与 _manage_xray openrc 分支同口径)
                start)
                    _hysteria_is_running || rc-service "$HYSTERIA_SVC" zap >/dev/null 2>&1 9>&-
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
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
                    rc-service "$HYSTERIA_SVC" start 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                status)  if _hysteria_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    local dpid0 dpid1
                    dpid0=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE")
                    # 归属用 exe 校验(不只看 comm), 且 pidfile 记录的**身份**(PID+启动时 starttime)
                    # 必须仍然成立; 陈旧 pidfile 指向他方 hysteria、或 PID 被复用(即使复用者也是
                    # hysteria)时判为 stale → 清 pidfile 并正常启动, 绝不误认 running。
                    if _xd_pidfile_identity_ok "$HYSTERIA_PID_FILE" && _hysteria_pid_is_ours "${dpid0:-}"; then
                        echo "running"
                    else
                        rm -f "$HYSTERIA_PID_FILE"
                        # 与 systemd WorkingDirectory/openrc directory 语义统一;
                        # 子壳层 exec 使 $! 即 hysteria 进程 pid(no-hup 承接同一 pid)
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
                        # 身份链闭合: 复核过的 starttime 必须传进 kill helper, 否则 helper
                        # 自己重读 starttime, 两次读取之间 PID 可能被复用。exe 归属只作附加收窄。
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

# openrc 状态机与 supervise-daemon 脱同步清理(2026-09-13 Alpine 实测): 子进程 FATAL 后
# supervisor 进入 respawn-wait 仍存活, openrc 却标 service stopped; 此后 start 被
# "already running" 拒绝, 服务永远起不来。stop 后若 pidfile 仍指向存活的 supervise-daemo
# (busybox comm 截断 15 字符), 显式 kill。
# 归属安全: 不能只看 comm —— pidfile 陈旧且 PID 被**别的** openrc supervisor 复用时, 只看
# 名字会误杀他方。openrc pidfile 是 supervisor 父进程(exe 不是 hysteria), 无法像 direct
# 那样直接比 exe; 改为校验**其进程树里确实存在 exe == $HYSTERIA_BIN 的进程**, 确属本项目才动手。
_hysteria_kill_stale_supervisor() {
    local a c st
    # openrc 的 pidfile 由 supervise-daemon 写(纯 PID); 用统一解析器取第一字段, 兼容 direct
    # 的 "PID starttime" 形态。
    a=$(_xd_pidfile_pid "$HYSTERIA_PID_FILE")
    [ -n "$a" ] || return 0
    [ -d "/proc/$a" ] || { rm -f "$HYSTERIA_PID_FILE"; return 0; }
    c=$(cat "/proc/$a/comm" 2>/dev/null)
    case "$c" in
        supervise-daemo*)
            if _hysteria_proc_tree_has_bin "$a"; then
                # openrc 不记录 starttime(纯 PID pidfile), 故在属主复核**之后立刻**抓一次身份
                # 传入 helper, 把"复核→kill"窗口压到最小; 抓不到时 helper 退化为自读(已声明残余)。
                st=$(_proc_starttime "$a") || st=""
                _xd_kill_pid_graceful "$a" 5 "$st"
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
    # 未知/空状态不得默认为 stopped(unknown/failed/not-found 被当成 stopped 会掩盖真实异常),
    # 只接受两个明确值。
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
    local i streak=0 stable=0
    # 必须**连续 3 次**采样均为 running 才算启动成功。单次命中不足以证明"配置可用": 坏配置下
    # systemd 单元(Restart=on-failure / RestartSec=3)处于崩溃重启循环, ActiveState=activating
    # 而 MainPID 在每次重启尝试的瞬间非零, 1s 采样会撞上该窗口误报 running(2026-09-14 坏 tls
    # 实测)。一次误判会让坏配置被**提交**(而非回滚), 服务随即崩溃循环, 后续操作级联失败。
    # 连续 3 次命中要求进程在 3 个采样点都存活(崩溃循环无法满足), 正常配置只多花 ~2s。
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
        *)
            _error "未知的 init backend: ${INIT_SYSTEM:-未设置}, 无法创建 Hysteria service"
            return 1
            ;;
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
# 服务级统一事务: hysteria.json(官方配置) + server_meta.json(manager 元数据)必须整体提交
# —— 先 config 后 meta 的两段式会在"config 已提交而 meta 写失败"时漂移(服务新 TLS / 链接旧 TLS)。
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
    # --- 至此 config 已变更: 之后任何失败都必须恢复 config + meta 并按**原运行状态**收尾 ---
    # (早期回滚路径直接 restart, 忽略 was_running, 会把用户原本 stopped 的服务异常启动;
    #  统一走 _hysteria_recover_to_state)
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
            # 无论 config 回滚成败都必须继续回滚 meta 并给出降级状态 —— 原写法在 restore
            # 失败时提前 return, 留下 config/meta 不一致且无人工指引。
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

# server_meta 侧回滚(meta_had=1 还原备份; meta_created=1 删除新建)。
# **返回真实状态**: 0=已还原到原状, 1=未能还原 —— 调用方据此判定是否进入 degraded state
# (原实现无条件 return 0, 无法区分"回滚完成"与"回滚失败但已告警")。
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
# 节点级统一事务: **config.auth.password + 节点元数据文件**原子提交(含 verified-restart /
# 瞬态验证与失败双回滚), 消除"config 已提交而节点元数据写失败"的两阶段漂移。
# **clash.yaml 是可再生的派生缓存, 不纳入事务** —— 阶段 4 同步失败仅告警, 不回滚节点本体
# (与 Xray 侧 _sync_node_clash 同口径)。链接/元数据内容在事务前预构建。
# 单密码模型下节点元数据只有一份($HYSTERIA_NODE_META), 但通用形态保留
# (create/delete + 任意 config filter), 改密码与未来扩展都走同一条路径。
# 用法: _hysteria_node_txn [--arg/--argjson ...] <config_filter> <meta_file> <op> <content>
# op = create: 原子写入 meta_file(存在则覆盖; 回滚还原旧文件或删除新建)
#      delete: 删除 meta_file(fail-closed; 回滚还原)
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
    # 节点侧回滚 helper(meta 还原/删除 + clash 派生同步)。返回真实状态:
    # 0=已还原; 1=未能还原(调用方据此判 degraded, 不再假定"回滚完成")
    _hysteria_node_txn_meta_rollback() {
        local rc=0
        if [ "$meta_had" -eq 1 ] && [ -s "$meta_bak" ]; then
            local mc
            mc=$(cat "$meta_bak" 2>/dev/null)
            if [ -n "$mc" ] && _atomic_write_json "$meta_file" "$mc"; then
                # clash 是**可再生派生缓存**: 同步失败不回滚权威状态, 也不把"元数据已还原"
                # 升级成 degraded(_hysteria_sync_clash 内部已 _warn 说明手工修法)
                _hysteria_sync_clash "$meta_file" || true
            else
                _warn "节点元数据回滚失败, 请人工核对 $meta_file"
                rc=1
            fi
        else
            if rm -f "$meta_file"; then
                if [ -n "$node_name" ]; then
                    # 同上: 派生缓存失败不回滚权威状态(helper 内部已告警)
                    _hysteria_remove_clash_by_name "$node_name" || true
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
    # --- 阶段 4: clash 派生(可再生缓存, 失败不回滚本体; helper 内部已告警) ---
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

# 服务器是否已完成初始化(配置存在 + jq 可解析 + auth 段就绪)。三态判定:
# 官方 auth.type 有 password/userpass/http/command 四种, 绝不能把"存在但非本 Manager 模型"
# 的合法官方配置当成未初始化而 bootstrap 覆盖。
_hysteria_config_exists() {
    [ -f "$HYSTERIA_CONFIG" ] && [ -s "$HYSTERIA_CONFIG" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e . "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

# 本 Manager 认定的**可管理**认证状态。官方 binary 实测(2.12.2): 缺 auth 段/type 为空
# → FATAL "empty auth type"; password 为空串 → FATAL "empty auth password"。
# 模型是**单密码**(见文件头): 只有 password 且密码非空才算就绪; 不接受 userpass/http/command
# (前者是被本模型取代的多用户形态, 从未随本模块发布, 无需迁移; 后两者依赖外部后端, 不该接管)。
#
# **契约边界**: 本判据只证明"auth 段可用且是本模型", **不证明服务能启动** —— 官方无
# validate/check 子命令, 坏配置(listen 冲突、TLS 路径错等)只能由真实启动结果判断, 那是
# `_hysteria_restart_verified` / `_hysteria_validate_transient` 的职责。函数名沿用
# `server_initialized`(全模块+测试套件的稳定契约), 但**不得**据此断言"服务在运行"。
_hysteria_auth_ok() {
    _hysteria_config_exists || return 1
    jq -e '(.auth.type == "password") and (.auth.password | type == "string") and ((.auth.password | length) > 0)' "$HYSTERIA_CONFIG" >/dev/null 2>&1
}

# 别名(全模块既有调用点): 语义完全同 _hysteria_auth_ok, 见上方的契约边界说明。
_hysteria_server_initialized() {
    _hysteria_auth_ok
}

# 读取 hysteria.json 的认证密码(只读; 不存在/非 password 模式输出空)
_hysteria_config_password() {
    _hysteria_config_exists || return 0
    jq -r 'if .auth.type == "password" then (.auth.password // "") else "" end' "$HYSTERIA_CONFIG" 2>/dev/null
}

# **Manager 是否已接管这台服务器** —— 与 _hysteria_server_initialized 是两个判断:
#   _hysteria_server_initialized = 配置可运行(config.json 有 password)
#   本函数                        = **Manager 侧有可用节点元数据**
# 必须分开: 单密码模型下"有凭据"不等于"本 Manager 管过它" —— 用户可能手工部署过
# Official Hysteria 再装上本脚本, 此时 config 有 password 但 node.json 不存在。用
# initialized 去挡"添加节点"会造成**状态死结**(删了 node.json 就再也加不回来), 用本函数
# 才正确: 没有 node.json ⇒ 走接管流程重建元数据。
#
# **"存在"与"可用"必须分开判**: 旧实现只判 `-f && -s`, 于是半截/损坏的 node.json(JSON
# 语法错、缺 auth/name/link_addr)也被当成"已有节点" → [2] 不给重建, [5] 改密码 jq 失败,
# [4] 取不到 name —— 人为制造出**第二个死结**。
# 契约: _hysteria_node_exists = 文件存在且**结构可用**(下游可直接 jq 取值);
# 只判"文件在不在"的场景(如卸载清 clash)用 _hysteria_node_file_present。
_hysteria_node_file_present() {
    [ -f "$HYSTERIA_NODE_META" ] && [ -s "$HYSTERIA_NODE_META" ]
}

# 返回值**归一化为 0/1** —— jq 对非法 JSON 会返回 2/5 等非 1 码, 直接透出会让调用方/断言
# 看到"意料外的错误码"; 布尔契约必须只有两种取值。
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

# 节点元数据是否**存在但损坏**(供菜单给出可操作的恢复指引: 提示并允许 [2] 重建)
_hysteria_node_broken() {
    _hysteria_node_file_present || return 1
    _hysteria_node_exists && return 1
    return 0
}

# 菜单操作闸门: initialized → 放行; 配置存在但 auth 段不可运行/非本模型 → 明确
# "不接管/状态不完整"; 无配置 → 提示初始化路径。返回 1 时调用方中止操作。
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
    # arr/first/doms/d 原为 ACME 分支内的 local; 现该分支被重问循环包裹, 循环体内不能声明
    # (每次迭代重新 local 会遮蔽外层, 且 do 块里的 local 在部分 shell 下语义不一致),
    # 故统一提升到函数级声明 —— 与 why/ans2 同口径。
    local choice cert_file key_file acme_domains acme_email host pin cn=""
    local arr first acme_bad acme_first why ans2
    local -a doms
    local d
    echo; echo -e "  ${CYAN}【TLS 设置】${NC}"
    echo -e "  ${GREEN}[1]${NC} 自签证书 (官方 hysteria cert 生成, 客户端 insecure+pinSHA256)"
    echo -e "  ${GREEN}[2]${NC} 使用已有证书 (证书+私钥路径)"
    echo -e "  ${GREEN}[3]${NC} ACME 自动证书 (本向导用 HTTP/TLS 质询; DNS 质询请手工编辑 hysteria.json)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    # 无效选择属可恢复输入 ⇒ 重问(不再 return 1 中止整段向导; 取消仍走 0)。
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
            # 域名格式非法属**可恢复的输入错误** ⇒ 原地重问本字段(要求 3), 不再中止整段
            # 向导。证书**生成失败**是环境类错误(二进制/权限), 仍 return 1。
            while true; do
                read -rp "  证书域名/SAN (回车默认 example.com): " host || return 1
                host=${host:-example.com}
                why=$(_hysteria_domain_reason "$host")
                [ -z "$why" ] && break
                _error "$why"
            done
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
            # 路径含非法字符 / 文件不存在都是**可恢复的输入错误** ⇒ 原地重问(要求 3),
            # 不再中止整段向导。证书内容本身不在此校验(交给核心启动时判定)。
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
            if command -v openssl >/dev/null 2>&1; then
                cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's/\/.*//')
            fi
            # SNI 可留空(核心按证书自身的 SAN 匹配); 非空则必须格式合法, 否则原地重问
            while true; do
                read -rp "  客户端 SNI (回车默认 ${cn:-需手动填}): " host || return 1
                host=${host:-$cn}
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
            # 域名列表/邮箱的格式问题都是**可恢复的输入错误** ⇒ 原地重问本字段(要求 3),
            # 不再中止整段向导。域名列表整体重问(逐条重问难以表达"第几条错了")。
            while true; do
                read -rp "  ACME 域名(多个用逗号分隔): " acme_domains || return 1
                arr="["; first=1; acme_bad=""; acme_first=""
                # IFS 只作用于这一次 read(项目规约: local IFS 会残留整个函数)
                IFS=',' read -ra doms <<< "$acme_domains"
                for d in "${doms[@]}"; do
                    # 只 trim **首尾**空白(逗号分隔的常见书写: "a.com, b.com")。
                    # 绝不能用 tr -d ' ' 删掉**全部**空格: 那会把 "foo bar.example.com" 静默
                    # 变成 "foobar.example.com" 并通过校验 —— 用户以为申请的是 A, 实际拿到 B,
                    # 且 A/B 会一路写进 acme.domains / acme_first / HY_TLS_SNI。
                    # 内部空白必须留给 _validate_domain 判非法并重问(本文件的核心契约:
                    # 绝不自动修正用户输入)。
                    d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
                    [ -z "$d" ] && continue
                    if ! _validate_domain "$d"; then
                        acme_bad="$d"
                        break
                    fi
                    # 第一个**通过校验**的域名记下来, 供 SNI 使用 —— 必须是规范化后的值,
                    # 不能事后从 $acme_domains 截取(那会带前导空格/空串, 见下)。
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
            # HTTP 质询要占 80/TLS-ALPN 占 443: 与 Xray 同机时大概率冲突, 提前讲清
            if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
                if jq -e '[.inbounds[]?.port] | index(80) or index(443)' "$CONFIG_FILE" >/dev/null 2>&1; then
                    _warn "Xray 已占用 80/443 端口, ACME 质询会失败(除非 NAT 转发到本机其他实现)"
                fi
            fi
            _warn "HTTP/TLS 质询需要 80/443 可达(NAT VPS 通常不满足); DNS 质询不依赖 80/443, 请手工在 hysteria.json 的 acme 段配置 type: dns"
            HY_TLS_JSON=$(jq -n --argjson d "$arr" --arg e "$acme_email" --arg dir "$HYSTERIA_ACME_DIR" \
                '{acme: {domains: $d, email: $e, dir: $dir}}')
            # SNI 必须取**已规范化并通过校验的第一个域名**, 不能从原始输入里截取:
            #   " foo.example.com,bar…"  => 原写法会带上前导空格;
            #   ",foo.example.com"       => 原写法得到空串(loop 会跳过空元素, 但截取不会)。
            # $doms 是上面 loop 实际写入 acme.domains 的同一份数组, 故用它才是"事实"。
            HY_TLS_MODE="acme"; HY_TLS_SNI="${acme_first}"; HY_TLS_PIN=""
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

# 重建分享链接(端口/TLS/obfs 等服务器级变更后调用)并同步 clash
# 分享链接 = 纯派生值(评审第八轮 P1-1/P1-2 方案 A): 由 hysteria.json(服务器级) +
# server_meta.json + 节点元数据实时计算, **不再作为持久 canonical state 写回节点元数据**。
# 理由: share_link 本质是 "server state + node state" 的表示形式, 持久化会引入第 4 份需要
# 同步的状态 —— 服务器级变更(TLS/端口/obfs)后若写回失败, 用户会看到旧链接而操作仍报成功;
# 节点创建时若预构建失败, 又会把空链接固化。改为动态派生后两个问题一并消失。
# 单密码模型下只有一份节点元数据, 故函数名保留(调用点语义不变)但只处理一个节点。
# 用法: link=$(_hysteria_node_link [meta_file]); 缺省用 $HYSTERIA_NODE_META; 失败输出空串并返回 1
_hysteria_node_link() {
    local meta="${1:-$HYSTERIA_NODE_META}" link
    [ -f "$meta" ] || return 1
    link=$(_hysteria_build_link "$meta") || return 1
    [ -n "$link" ] || return 1
    printf '%s' "$link"
}

# 服务器级变更(端口/TLS/obfs/带宽)后的统一收尾: 同步唯一节点的 clash 条目。
# 保留原函数名作为调用点契约(旧调用点语义不变: 返回非 0 = 派生失败, 调用方告警)。
_hysteria_rebuild_all_links() {
    local gap
    # 语义缺口(gecko 自定义尺寸)是**服务器级**的: 链接派生不出来, 但这不是节点元数据的问题。
    gap=$(_hysteria_obfs_uri_gap)
    if [ -n "$gap" ]; then
        _warn "分享链接不可生成: ${gap} (clash/mihomo 条目不受影响, 仍会同步)"
    fi
    [ -f "$HYSTERIA_NODE_META" ] || return 0
    # 校验派生链接可用(缺字段/坏配置时告警, 但不写回)
    if [ -z "$gap" ] && ! _hysteria_node_link "$HYSTERIA_NODE_META" >/dev/null; then
        _warn "分享链接派生失败(节点元数据缺字段?)"
    fi
    _hysteria_sync_clash "$HYSTERIA_NODE_META" || return 1
    return 0
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
    local choice pw pw2 cur_type cur_min cur_max
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【混淆 obfs (salamander / gecko)】${NC}"
    # 类型从配置实际读取(旧实现固定打印 salamander, gecko 配置下显示与实际不符)
    cur_type=$(_hysteria_obfs_get type)
    if [ -n "$cur_type" ]; then
        echo -e "  当前状态: ${GREEN}已启用${NC} (类型: ${CYAN}${cur_type}${NC})"
    else
        echo -e "  当前状态: ${RED}未启用${NC}"
    fi
    echo -e "  ${YELLOW}启用后服务端不再兼容标准 QUIC/HTTP3 连接(官方文档), 客户端必须带相同类型与密码${NC}"
    # gecko 分片尺寸: 官方 URI 只有 obfs / obfs-password, **没有**尺寸参数 —— 非默认尺寸时
    # 链接拒绝生成(见 _hysteria_obfs_uri_gap); 非法尺寸连服务都起不来。此处如实回显。
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
            # 分片尺寸是 **gecko 专有字段**(官方 Full-Server-Config: gecko 段才有
            # minPacketSize/maxPacketSize)。继承条件必须**同时**满足"切到 gecko"与
            # "当前本来就是 gecko"(P3-1, 十五轮评审): 旧实现只判前者, 于是 current=
            # salamander 时会把 salamander 子段里遗留的同名字段(对 salamander 毫无意义,
            # 可能是手工粘贴残留)重新解释成 gecko 参数, 凭空改变服务端行为。
            # 非 gecko 来源一律回到官方默认(不写这两个字段)。
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
                # 不断言"已写入分享链接": gecko 自定义尺寸下链接是**不生成**的(P1)
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

# 读取 hysteria.json 的 congestion 段; $1 = type|profile, 未配置时输出空串。
# 官方 Full-Server-Config "拥塞控制": congestion.type ∈ {bbr, reno}(默认 bbr),
# bbrProfile ∈ {standard, conservative, aggressive}(仅 type=bbr 时生效, 默认 standard)。
# **只有该方向未使用 Brutal 时才生效** —— 故菜单必须如实说明它与带宽的关系。
_hysteria_congestion_get() {
    local key="$1"
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    case "$key" in
        type)    _hysteria_config_get 'congestion.type' ;;
        profile) _hysteria_config_get 'congestion.bbrProfile' ;;
    esac
}

# 拥塞控制展示摘要(唯一入口, 菜单与列表共用)
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

# [11] 拥塞控制: 选择控制器类型与 BBR 预设(官方 congestion 段)。
# 与原脚本的设计语言一致(枚举菜单 + 回车默认), 但字段口径严格按官方文档 ——
# 这里**不是** Xray 的 congestionControl/brutal 开关, 而是官方 binary 的本地控制器。
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

# ---------------------------------------------------------------------------
# 官方混淆 obfs 读取(链接与 clash 共用的唯一入口)
# ---------------------------------------------------------------------------

# 读取 hysteria.json 的 obfs 段; $1 = type|password|min|max, 未启用时输出空串。
# 官方只定义 salamander 与 gecko 两种**混淆**实现(Full-Server-Config "混淆" 一节), 但此处
# **按类型名泛化**: 类型原样透出, 密码取同名子段的 password —— 官方 URI 的
# `obfs` / `obfs-password` 本就是泛化参数(URI-Scheme.md), 将来官方再加第三种实现时
# 链接不会静默丢参数。参数用"字段名"而非拼串, 避免密码含分隔符时的解析歧义。
# **plain 归一化**(十七轮评审 P2): 官方 server 的 wrapObfs(app/cmd/server.go)实际接受
# `""` 与 `"plain"`(两者都是**不做混淆**, 直接原样透传), 故 type=plain 在读取层就归一为
# 空串 —— 链接/clash/菜单天然按"未启用混淆"处理(客户端无 obfs 连接即正确), 而不是把
# `obfs=plain` 这种客户端不认的参数写进链接、把未知类型写进 clash。
# 反面教训(0.16.12 及以前): 实现只认 .obfs.salamander.password —— 用户按官方文档把类型
# 改成 gecko 后, 分享链接与 clash 条目**一个混淆参数都不写**, 客户端按无混淆连接而服务端
# 要求混淆 → 必然连不上, 且界面没有任何提示。实机对照(真实客户端, 2026-09-14):
# 服务端 gecko + 本模块条目 → mihomo 连不上(HTTP 000); 手工补上 obfs 参数 → HTTP 200。
_hysteria_obfs_get() {
    local key="$1"
    [ -f "$HYSTERIA_CONFIG" ] || return 0
    jq -r --arg k "$key" '
        (.obfs // {}) as $o
        | ($o.type // "") as $t
        | if $t == "" then ""
          elif $k == "type"     then (if $t == "plain" then "" else $t end)
          elif $k == "password" then ($o[$t].password // "")
          elif $k == "min"      then (($o[$t].minPacketSize // "") | tostring)
          elif $k == "max"      then (($o[$t].maxPacketSize // "") | tostring)
          else "" end' "$HYSTERIA_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# gecko 分片尺寸的语义判定(唯一入口, 0.16.15; 0.16.16 加固结构校验)
# 官方 Full-Server-Config「混淆」一节: gecko 子段有 minPacketSize(默认 512)/
# maxPacketSize(默认 1200), 且 **maxPacketSize 必须 >= minPacketSize 且 <= 2048**。
# 未写的字段按官方默认补全后再判定 —— 显式写 512/1200 与省略等价, 不该算"自定义"。
# 四种状态是**产品行为**的分界, 不是校验洁癖:
#   none    当前 obfs 不是 gecko(尺寸字段不适用)
#   default 有效尺寸 == 官方默认 512/1200 → 与官方默认语义一致, 链接可生成
#   custom  有效尺寸偏离官方默认 → 官方 URI **没有**尺寸参数(只有 obfs/obfs-password),
#           生成出来的链接会让客户端按默认尺寸连自定义尺寸的服务端 = 语义不等价
#   invalid 越界(非数字 / min<1 / max<min / max>2048)或**结构非法** → 官方 binary 直接拒绝启动
#
# 0.16.16(十六轮评审 P1/P2): state/desc/why 由**同一次 jq 解析**产出 —— 旧实现是两个
# 独立 jq, 且 has() 直接作用于未经类型检查的子段: gecko 为字符串/数组时 has() 抛错、
# stderr 被吞 → 状态输出**空串**, 调用方既非 custom 也非 invalid → URI 照常生成;
# minPacketSize:null 会被 `// 512` 静默当默认值(state 判 invalid 而 desc 显示 512,
# 自相矛盾)。现在全部结构检查前置(type 先于 has), 非法结构明确归 invalid。
# 已知取舍(有意): `.obfs.gecko` 为 **null/缺失** 时按"未写尺寸"处理(= default) ——
# 尺寸语义上空对象就是官方默认; 密码缺失是另一维度, 由 build_link/clash 的
# fail-closed(密码为空拒绝生成)兜住, 不混进本状态机。
# ---------------------------------------------------------------------------
# 用法: _hysteria_gecko_size_get <state|desc|why>
#   state = none|default|custom|invalid(解析失败也归 invalid, fail-closed)
#   desc  = "min=X max=Y"(非法值原样 tojson 展示, 不再冒充默认值)
#   why   = 空串(无缺口)或完整原因文本(供 _hysteria_obfs_uri_gap 原样透出)
_hysteria_gecko_size_get() {
    [ -f "$HYSTERIA_CONFIG" ] || { [ "$1" = "state" ] && echo "none"; return 0; }
    jq -r --arg k "$1" '
        (type) as $rt
        | if $rt != "object" then
            # 顶层就不是一个 JSON 对象(手工把 hysteria.json 写成 null/[]/"foo"): 统一 invalid,
            # 不给 null 开"等价于无 obfs"的口子 —— 与 fail-closed 口径一致(十七轮评审 P3)
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
                | (if ($gg | has("minPacketSize")) then $gg.minPacketSize else 512 end) as $mn
                | (if ($gg | has("maxPacketSize")) then $gg.maxPacketSize else 1200 end) as $mx
                # 官方 schema 是 Go int(app/cmd/server.go: MinPacketSize/MaxPacketSize int),
                # JSON number 里的分数(512.5)会被 Go 反序列化拒绝 —— 必须单独判,
                # 不能靠 `type == "number"`(512.5 也是 number)。512.0 数值上 == 512, 合法。
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
# jq 自身失败(配置损坏/被并发改写)时宁可误报 invalid 也不静默放行 —— 上面的表达式
# 对一切输入都应产出结果, 走到这里说明解析层出了问题
_hysteria_gecko_size_state() {
    local s
    s=$(_hysteria_gecko_size_get state)
    [ -n "$s" ] && { printf '%s' "$s"; return 0; }
    echo "invalid"
}
_hysteria_gecko_size_desc() {
    _hysteria_gecko_size_get desc
}

# 分享 URI 能否**完整表达**当前 obfs 配置(P1, 十五轮评审; 0.16.16 扩大覆盖)。
# 官方 URI-Scheme 只有 obfs / obfs-password 两个混淆参数, **没有** gecko 分片尺寸参数
# (minPacketSize/maxPacketSize 只是 hysteria.json 的配置字段)。所以 gecko 用非默认尺寸时,
# 生成出来的 URI "看起来完全正常"却让客户端按官方默认(512/1200)去连服务端 —— 用户会复制
# 转发这条链接, 参数却不一致, 且界面无从察觉。本函数是该判断的唯一入口:
#   stdout 非空 = 不可完整表达的原因(原样展示给用户); 空 = 可完整表达
# 0.16.16(十六轮评审 P2)新增类型校验; 0.16.17 修正事实表述: 官方 server 的 wrapObfs
# 实际接受 ""/"plain"/"salamander"/"gecko"(plain = 无混淆, 读取层已归一为空), Manager
# 创建流程只会产生 salamander/gecko —— 两者都成立, 但"官方枚举只有两种"是错的。
# 白名单不列 plain(十八轮评审 P3): plain 在读取层已归一为空串, 永远不会作为值到达这里;
# "" 分支同时覆盖"未启用混淆"与"type=plain", 列 plain 反而是与数据流脱节的死分支。
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

# ---------------------------------------------------------------------------
# 分享链接(官方 URI scheme)与 clash 条目
# ---------------------------------------------------------------------------

# 分享链接的**前置校验**: 节点元数据完整性 + 服务器 listen 可解析。
# 与"URI 能否完整表达 obfs 配置"是两件不同的事, 必须分开:
#   - 缺字段/坏 listen = 元数据或服务器配置不完整 → 调用方**必须中止**节点操作;
#   - gecko 自定义尺寸 = 链接表达不了(语义缺口) → 只影响链接的**呈现**,
#     **不得**阻断节点增删改(否则手改过尺寸的用户连加节点都做不到)。
# 成功: stdout=<port_part>(如 443 / 20000-50000); 失败: 返回 1 且已打印原因
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

# 构建官方 hysteria2:// 链接。服务器级参数(listen/tls/obfs)读 hysteria.json,
# 节点级参数(auth/name/link_addr)读节点元数据 —— 官方 URI 无 congestion/up/down
# 等客户端参数(官方文档明示 "parameters should never include ... bandwidth values")。
# **userinfo 只有一个 auth 段**(单密码模型): 官方 URI-Scheme 明确 "认证凭据应放在
# auth 段", 仅当服务端用 userpass 时才写成 `username:password`。本 Manager 用
# auth.type=password, 故此处**只写密码** —— 这也正是 Xray/sing-box 能直接使用的原因。
# 实测对照(2.12.2): `hysteria share` 对 password 服务端产出 `hysteria2://<pass>@host:port/`,
# 对 userpass 服务端产出 `hysteria2://<user>:<pass>@host:port/`。
# **语义缺口时拒绝生成**(P1, 十五轮评审): gecko 自定义/非法分片尺寸无法写进官方 URI,
# 此时返回 1 且不输出任何 URI —— 宁可让 UI 明确说"链接不可生成", 也不产出一条
# "看着正常、语义不等价"的链接(见 _hysteria_obfs_uri_gap)。
# 用法: _hysteria_build_link <meta_file>; 失败返回 1
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
    # 混淆: 类型与密码都按官方 URI 的泛化参数写(obfs / obfs-password), 不写死 salamander。
    # gecko 尺寸的语义缺口已在上方统一拦截, 故这里不需要(也不允许)再判断一次。
    local o_type o_pw
    o_type=$(_hysteria_obfs_get type)
    if [ -n "$o_type" ]; then
        o_pw=$(_hysteria_obfs_get password)
        params="${params}${params:+&}obfs=$(_url_encode "$o_type")&obfs-password=$(_url_encode "$o_pw")"
    fi
    # 官方多端口格式直接写在 port 段(443 或 20000-50000), 无 mport 参数
    local link="hysteria2://$(_url_encode "$auth")@${link_ip}:${port_part}/"
    [ -n "$params" ] && link="${link}?${params}"
    link="${link}#$(_url_encode "$name")"
    printf '%s' "$link"
}

# 分享链接的**呈现**入口(所有展示点的唯一入口, 0.16.15 P1)。
# 存在的理由: 缺口必须由"链接生成"这一层统一处理, 而不是靠每个展示点各自记得检查 ——
# 漏掉任何一处都会重新产出"看起来正常"的不完整链接。$2 是标签(分享链接/新分享链接)。
# 返回 0 = 已打印 URI; 1 = 未打印(已给出原因), 调用方不得再自行打印 URI
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

# clash.yaml(mihomo) 条目。字段依据 = mihomo 源码 adapter/outbound/hysteria2.go 的
# Hysteria2Option 解码器(2026-09-13 核验): 认证字段只有 `password`(无 auth/username)。
# **单密码模型下 password 就是认证密码本身**(不再有 user:pass 拼接 —— 那是官方
# userpass 的语义, 客户端不认, 见文件头); `ports` 启用跳跃并忽略 port(port 保留作
# 旧版 mihomo 的兜底)。
_hysteria_clash_line() {
    local meta="${1:-$HYSTERIA_NODE_META}" name addr auth
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    auth=$(jq -r '.auth // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] && [ -n "$addr" ] && [ -n "$auth" ] || {
        _error "节点元数据缺少必要字段(name/link_addr/auth), 无法生成 clash 条目"
        return 1
    }
    # 非法 gecko 尺寸(P2-2, 十五轮评审): 官方 binary 会拒绝启动, 不把明显无效的值写进
    # 派生缓存。只拦 invalid —— **custom 尺寸合法且可表达**(mihomo 有独立字段), 照常透出。
    if [ "$(_hysteria_gecko_size_state)" = "invalid" ]; then
        _error "检测到非法 gecko 分片尺寸($(_hysteria_gecko_size_desc)): 官方要求 min>=1、max>=min 且 max<=2048; 请先修正 $HYSTERIA_CONFIG"
        return 1
    fi
    # obfs.type 白名单(P2, 十六轮评审; 0.16.17 修正口径): type 原样拼进单行 YAML(无引号),
    # 异常字符串会产出 malformed YAML —— 枚举按枚举校验, 白名单比 escaping 更正确。
    # 官方 server 的 wrapObfs 接受 ""/"plain"/"salamander"/"gecko"; ""与"plain"(无混淆)
    # 在读取层已归一为空串(见 _hysteria_obfs_get), 因此 plain **不会**到达这里 ——
    # 白名单不列 plain(十八轮评审 P3), 与数据流一致, 不留死分支。
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
    [ "$(_hysteria_meta_get tls_mode)" = "selfsigned" ] && line="${line}, skip-cert-verify: true"
    if [ -n "$o_type" ]; then
        o_pw=$(_hysteria_obfs_get password)
        line="${line}, obfs: ${o_type}, obfs-password: \"$(_yaml_dq "$o_pw")\""
        # gecko 的分片尺寸: mihomo 有独立字段(obfs-min-packet-size / obfs-max-packet-size),
        # 仅在服务端显式写了尺寸时透出 —— 未写即两端都用官方默认(512/1200)。
        o_min=$(_hysteria_obfs_get min)
        o_max=$(_hysteria_obfs_get max)
        [ -n "$o_min" ] && line="${line}, obfs-min-packet-size: ${o_min}"
        [ -n "$o_max" ] && line="${line}, obfs-max-packet-size: ${o_max}"
    fi
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
        # 返回值契约: clash 是**可再生派生缓存**, 同步失败不回滚核心事务(节点本体不受影响),
        # 但必须如实返回 1 让上层知道"派生缓存已过期"(原实现 || _warn 后 return 0, 调用方的
        # `|| fail=1` 永远不会触发, 失败被静默吞掉)。告警文本由本函数统一给出 —— 有调用点
        # 是 `|| true`(事务回滚路径)不会再补告警, 消息放这里才不会漏。
        _replace_node_in_yaml "$line" "$name" \
            || { _warn "clash 条目替换失败(clash 为可再生派生缓存, 节点本体不受影响), 可手工编辑 ${CLASH_YAML}"; return 1; }
    else
        _add_node_to_yaml "$line" "$name" \
            || { _warn "clash 条目追加失败(clash 为可再生派生缓存, 节点本体不受影响), 可手工编辑 ${CLASH_YAML}"; return 1; }
    fi
    return 0
}

# 从 clash.yaml 移除节点条目(派生缓存)。同样如实返回状态: 失败返回 1 并在此告警,
# 不静默吞错 —— 否则"删除节点成功"但订阅里仍残留幽灵条目, 无人知晓。
_hysteria_remove_clash_by_name() {
    local name="$1"
    [ -n "$name" ] || return 0
    _remove_node_from_yaml_by_name "$name" 2>/dev/null \
        || { _warn "clash 条目删除失败(clash 为可再生派生缓存, 节点本体不受影响), 可手工编辑 ${CLASH_YAML}"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# 节点(单密码模型)生命周期
# ---------------------------------------------------------------------------
# 本 Manager 的模型 = 官方 `auth.type: password`(单认证密码), 见文件头说明。
# 节点元数据 = $HYSTERIA_NODE_META(单文件), 字段: auth/name/link_addr/created。
# **没有"用户名"这一维**: 官方 password 模式不接受用户名, 客户端(Xray/sing-box/mihomo)
# 只需填认证密码 —— 这正是用户要求"只要认证密码"的原因。

# 节点显示名是否已被占用(clash.yaml 按 name 删除/替换, 重名会串条目; 与 Xray 侧
# _ensure_unique_name 同一约束, 作用域是 hysteria 自己的节点元数据)
_hysteria_name_taken() {
    local name="$1" n
    [ -f "$HYSTERIA_NODE_META" ] || return 1
    n=$(jq -r '.name // empty' "$HYSTERIA_NODE_META" 2>/dev/null) || return 1
    [ -n "$n" ] && [ "$n" = "$name" ] && return 0
    return 1
}

# 默认名已被占用时自动追加序号(基名-2 → 基名-3...); 返回可用名。
# 序号必须基于**原始基名**递增: 旧实现原地改写 base, 于是第三个节点会得到
# "基名-2-3" 这种叠加后缀(实测), 而不是 "基名-3"。
_hysteria_autofill_name() {
    local base="$1" cand="$1" i=2
    while _hysteria_name_taken "$cand"; do
        cand="${base}-${i}"
        i=$((i+1))
    done
    printf '%s' "$cand"
}

# 默认节点名 = 协议+端口(用户要求: 与原脚本的命名规则一致; "HY2官方" 是自作多情的名字)。
# Xray 侧同协议默认名形如 "HY2-<port>"(50-nodes), 这里沿用同一形态;
# 跳跃范围下端口取**范围首端口**(与 listen 实际监听端口一致, 不会变成 "HY2-20000-50000")。
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

# 在**提交前**预演默认名: bootstrap 里 listen 由本向导决定, 尚未写进配置(配置可能还不存在),
# 故不能用 _hysteria_default_name 去读配置。$1 = 本向导将要写入的 listen(如 ":443" 或
# ":20000-50000"); 跳跃范围取首端口, 与提交后的 _hysteria_default_name 结果一致。
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

# ---------------------------------------------------------------------------
# 向导输入的"只重问当前字段"
#
# 问题: 官方 Hy2 添加节点向导里, 任何**可恢复的用户输入错误**(URL 少 scheme、域名格式非法、
# 跳跃范围写错、名称重名…)都是 `_error …; return 1` —— 一路冒泡出 _hysteria_bootstrap,
# 于是用户被扔回【Hysteria2 管理 — 官方核心】主菜单, 前面 10 项输入全部作废。一个字符打错
# 的代价是整段重来。
#
# 契约(硬要求, 不是风格偏好):
#   (1) 只重问**当前字段**, 已确认的其它字段一概不动(不重算随机密码/端口/证书);
#   (2) **绝不吞错**: 不把 example.com 悄悄补成 https://example.com, 不把非法值当默认值,
#       必须回显原因再问。自动纠错会让用户以为配置就是他填的那样;
#   (3) EOF(read 失败)一律返回 1: 无输入可读时继续循环 = 无限空转(项目已有 140k 行/秒的
#       实测事故); 调用方据此中止并走既有回滚;
#   (4) 空值是否合法由各字段自己的判据决定, 不在此统一兜默认(空 != 默认值)。
#
# helper 经由**全局变量**回传(变量名由调用方给出): read 循环必须能回传原样输入, 而
# 命令替换会吞掉末尾换行, 故不用 $(...) 返回。
# ---------------------------------------------------------------------------

# 取校验函数的"原因"文本(校验函数输出原因; 无输出时给一句兜底, 避免"失败"却不说为什么)
_hysteria_ask_why() {
    local fn="$1" val="$2" why=""
    why=$("$fn" "$val" 2>/dev/null) || why=""
    [ -n "$why" ] || why="取值非法"
    printf '%s' "$why"
}

# 用法: _hysteria_ask_value <提示> <reply变量名> <允许空值 0|1> <校验函数名>
# 校验函数接收候选值, 返回 0 表示合法; 非 0 时其 stdout 作为原因回显。
_hysteria_ask_value() {
    local prompt="$1" reply_var="$2" allow_empty="$3" validator="$4" val="" why
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
        if "$validator" "$val"; then
            printf -v "$reply_var" '%s' "$val"
            return 0
        fi
        why=$(_hysteria_ask_why "$validator" "$val")
        _error "$why"
    done
}

# 同上, 但校验函数是"值 -> 原因文本"(空串 = 合法), 与 Xray 侧 _hy2_masq_*_invalid 同口径:
# 校验逻辑可被单测直接断言原因文本, 不必从退出码反推。
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

# 枚举问答: 输入必须落在白名单内, 否则重问 —— 取代 `*) _warn "无效选择, 按默认处理"`
# 这种"吞掉非法输入并替用户做决定"的写法(用户明确反对: 非法输入不得被静默当作默认值)。
# 用法: _hysteria_ask_choice <提示> <reply变量名> <默认值, 可为空> <"合法值1 合法值2 …">
#   空输入 → 默认值(默认值为空串时表示"空也合法", 直接回传空串)。
_hysteria_ask_choice() {
    local prompt="$1" reply_var="$2" default="$3" allowed="$4" val="" ok a
    while true; do
        read -rp "$prompt" val || return 1
        if [ -z "$val" ]; then
            printf -v "$reply_var" '%s' "$default"
            return 0
        fi
        ok=""
        for a in $allowed; do
            [ "$val" = "$a" ] && { ok=1; break; }
        done
        [ -n "$ok" ] && { printf -v "$reply_var" '%s' "$val"; return 0; }
        _error "无效选择: ${val}(可选: ${allowed// /, })"
    done
}

# 跳跃范围校验(值 -> 原因)。只表达"官方 listen 能接受的单段连续范围":
# 官方 listen 写的是一个范围(如 :20000-50000), 不支持逗号分隔多段 —— 多段是 Xray 侧
# iptables 端口跳跃的方案, 两者不可混用。
_hysteria_hop_reason() {
    local hop="$1" parsed lo hi st en
    [ -n "$hop" ] || { printf '%s' ""; return; }
    case "$hop" in
        *","*) printf '%s' "官方 listen 仅支持单段连续范围(如 20000-50000), 不接受逗号分隔的多段"; return ;;
    esac
    # 先自己拆一次: 把"起始 > 结束"与"端口越界"判成各自具体的原因, 而不是一律"格式非法"
    # (_parse_hop_ranges 把两者都归成一个非零返回码, 直接透传会让用户不知道要改哪里)。
    # _parse_hop_ranges 内部会把空格去掉(tr -d ' '), 这里对齐后再判: 否则 " 20000 - 30000 "
    # 会被前置判成"端口非法", 而实际解析器是接受的(不一致会把合法输入挡在门外)。
    hop=$(printf '%s' "$hop" | tr -d ' ')
    [ -n "$hop" ] || { printf '%s' ""; return; }
    case "$hop" in
        *","*) printf '%s' "官方 listen 仅支持单段连续范围(如 20000-50000), 不接受逗号分隔的多段"; return ;;
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

# 域名校验(值 -> 原因), 供自签证书域名/ACME 域名的重问循环使用。
_hysteria_domain_reason() {
    local d="$1"
    [ -n "$d" ] || { printf '%s' "域名不能为空"; return; }
    _validate_domain "$d" && { printf '%s' ""; return; }
    printf '%s' "域名格式非法(仅字母/数字/连字符, 点分段): ${d}"
}

# 官方带宽值校验(值 -> 原因)。依据 [Hysteria 官方源码] app/internal/utils/bpsconv.go 的
# StringToBps: 数字 + 单位, 单位只认 b/bps/k/kb/kbps/m/mb/mbps/g/gb/gbps/t/tb/tbps
# (大小写不敏感、允许空格、**不允许小数**), 且 core/server/config.go 要求非得 0 时
# >= 65536 字节/秒。
# **为什么必须在这里挡**: 带宽写错不会在向导里报错, 而是写入配置后由官方 binary 在**启动**时
# 拒绝, 触发 bootstrap 的整段回滚 —— 用户看到的是一次"莫名其妙全部作废"。提前挡下并说清原因,
# 才是把"可恢复的用户输入错误"留在原地重问。
_hysteria_bandwidth_reason() {
    local v="$1" num unit lunit bps
    [ -n "$v" ] || { printf '%s' ""; return; }
    # 官方 StringToBps 先 TrimSpace 再解析, 这里对齐 —— 否则 " 5m" 会被判成"缺少数值",
    # 而官方其实接受(从文档复制粘贴带空格是常见情形)。
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ -n "$v" ] || { printf '%s' ""; return; }
    case "$v" in
        *[!0-9A-Za-z[:space:]]*) printf '%s' "带宽只能由数字+单位组成(如 100 mbps / 1g); 不支持小数与其它字符"; return ;;
    esac
    num="${v%%[!0-9]*}"
    unit="${v#"$num"}"
    # 官方是 `unit := strings.TrimSpace(s[spl:])` —— **只去首尾**空白, 不删内部空白。
    # 原写法 ${unit// /} 会删掉所有空格, 于是 "100 m bps" 被拼成 "100mbps" 判为合法,
    # 而官方会把它当作不支持的 unit 拒掉 —— 正是本校验器要提前挡下的那类输入
    # (放行后在 hysteria.json 里才会被 binary 于启动时拒绝, 触发整段回滚)。
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
    if [ "$bps" -lt 65536 ]; then
        printf '%s' "带宽过小(官方要求 >= 65536 字节/秒, 约 524 kbps); 请填 1 mbps 以上或留空表示不限速"
        return
    fi
    printf '%s' ""
}

# 服务器初始化向导(bootstrap): 仅由 [添加节点] 在未初始化时触发, 单一入口避免双路径漂移。
# 实测约束(2.12.2): 官方 binary 对缺 auth 段 / 空密码 FATAL
# ("empty auth type" / "empty auth password"), 因此**认证密码必须与配置同时落地**
# ——本向导包含唯一认证密码的创建, 成功返回后服务器即可用。
# 失败回滚已发生的步骤并返回 1。
_hysteria_bootstrap() {
    local port hop parsed lo hi listen tls_json tls_mode tls_sni tls_pin
    local obfs_pw="" obfs_type="" masq_url="" up="" down="" addr
    local auth name def_name cc_type cc_profile
    # 重问循环里使用的中间变量(why = 校验原因, ans = 各种 y/N 与重填输入)
    local why ans
    echo; echo -e "  ${CYAN}=== 初始化官方 Hysteria2 服务器 ===${NC}"
    _tip "官方架构: 单服务单密码; 以下为服务器级设置, 认证密码即客户端唯一凭据"

    # 0) 前置保护: 存在非本 Manager 管理的官方配置(auth 非 password 模式)时绝不 bootstrap
    # —— bootstrap 会整体重写配置文件, 静默覆盖用户已有的合法配置是不可接受的
    if _hysteria_config_exists && ! _hysteria_server_initialized; then
        _error "检测到现有 Hysteria 官方配置($HYSTERIA_CONFIG), 其 auth 不是本 Manager 管理的 password 模式"
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
    # 设计语言对齐原脚本(xray_manager/singbox.sh): 提示写"(回车随机生成)", 用户回车后
    # 用 _info 回显**实际分配的端口**, 而不是把候选值塞进提示里(用户明确要求"回车后显示
    # 随机的端口是多少")。
    local def_port
    def_port=$(_gen_random_port)
    while true; do
        # EOF 必须中止: 否则 stdin 耗尽时 $port 为空, 会被下面的空值分支当成"用户回车",
        # 静默分配一个随机端口并继续向导 —— 与本文件其它循环的 EOF 契约不一致。
        read -rp "  监听端口 (回车随机生成): " port || return 1
        if [ -z "$port" ]; then
            port="$def_port"
            _info "已随机分配监听端口: ${port}"
        fi
        _validate_port "$port" || { _warn "无效端口(1-65535)"; continue; }
        _check_port_occupied "$port" udp && { _warn "端口 $port 已被占用, 换一个"; def_port=$(_gen_random_port); continue; }
        _check_port_in_config "$port" && { _warn "端口 $port 已被 Xray 节点使用, 换一个"; def_port=$(_gen_random_port); continue; }
        break
    done
    # 跳跃范围: 用户输入错误(格式/顺序/多段)属**可恢复**错误 —— 原地重问本字段, 不再
    # return 1 把用户扔回主菜单(要求 3)。mimic 冲突与端口冲突不是输入格式问题, 但同样
    # "改一下就能过", 故也留在本字段循环里重问; 真正的环境类失败(核心下载/写配置/启动)
    # 仍然 return 1 走既有回滚。
    while true; do
        read -rp "  端口跳跃范围 (如 20000-50000, 回车不启用): " hop || return 1
        [ -z "$hop" ] && break
        why=$(_hysteria_hop_reason "$hop")
        [ -z "$why" ] || { _error "$why"; continue; }
        hop=$(printf '%s' "$hop" | tr -d ' ')
        parsed=$(_parse_hop_ranges "$hop" 2>/dev/null) || { _error "范围解析失败: $hop"; continue; }
        lo="${parsed%%:*}"; hi="${parsed##*:}"
        # 官方禁止 mimic + 端口跳跃组合(启动即拒绝)。这是配置冲突而非格式错误,
        # 用户改不了本字段使其通过 —— 但可以重填一个不启用跳跃的空值, 故仍在循环内。
        if _hysteria_mimic_enabled; then
            _error "配置已启用 mimic, 官方不允许 mimic 与端口跳跃同时启用(请先关闭 hysteria.json 的 mimic.enabled, 或留空不启用跳跃)"
            continue
        fi
        if [ "$lo" -le "$port" ] && [ "$port" -le "$hi" ]; then
            break
        fi
        # 官方机制: 范围首端口即监听端口; 允许把监听端口并进范围首端
        _warn "官方机制下监听端口=范围首端口(${lo}), 输入的 $port 将被范围取代"
        read -rp "  使用范围 ${lo}-${hi} (监听 ${lo})? [y/N]: " ans || return 1
        case "$ans" in
            y|Y) port="$lo"; break ;;
            *) _error "已放弃该范围, 请重新输入跳跃范围(留空 = 不启用跳跃)"; continue ;;
        esac
    done
    if [ -n "$hop" ]; then
        # 与本机监听/Xray 入站端口冲突: 属"换个范围就能过", 故回到范围字段重问
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

    # 2) TLS
    if ! _hysteria_prompt_tls; then _info "已取消"; return 1; fi
    tls_json="$HY_TLS_JSON"; tls_mode="$HY_TLS_MODE"; tls_sni="$HY_TLS_SNI"; tls_pin="$HY_TLS_PIN"

    # 3) obfs(可选)。单次提问决定"是否启用 + 类型", 不新增提示行 —— 既有的自动化
    # 输入序列(端口/跳跃/TLS/证书域名/本项/…)长度不变。
    # 提示文案(用户要求): 去掉提问行里那段冗长的 gecko 括注(实验性/旧客户端不支持),
    # 版本兼容性说明改在 [9] 混淆菜单里给出(用户主动进入, 有空间讲清代价);
    # 补 [3] 显式"不启用", 回车 = 不启用(默认项与用户预期一致)。
    local ans2=""
    # 非法输入**不再静默按"不启用"处理**(要求 4): 那会让用户以为开了混淆而实际没开,
    # 客户端按混淆连、服务端不要求混淆 —— 又一处"界面与事实不符"。改为回显原因后重问。
    # 允许值含 y/Y(旧脚本语义 = salamander), 空值 = 不启用(默认项)。
    while true; do
        read -rp "  启用混淆? [1] salamander [2] gecko [3] 不启用 (回车不启用): " ans2 || return 1
        case "$ans2" in
            # y/Y 与 n/N 是历史语义(y = salamander, n = 不启用), 也是用户对"要不要开"
            # 的自然回答 —— 它们**明确**表达了意图, 不属于"被吞掉的非法输入", 故保留;
            # 真正无法理解的值(如 "abc"/"9")才重问, 不再一律当"不启用"。
            1|y|Y) obfs_type="salamander"; break ;;
            2) obfs_type="gecko"; break ;;
            3|n|N|"") obfs_type=""; break ;;
            *) _error "无效选择: ${ans2}(可选 1/2/3, 回车或 n 表示不启用)" ;;
        esac
    done
    if [ -n "$obfs_type" ]; then
        # 随机密码在**用户确认前**生成一次即可; 密码字段重问不重新生成(要求 5:
        # 已确认的随机值不得因另一个字段出错而被换掉)。
        obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
        while true; do
            read -rp "  混淆密码 (回车随机): " ans2 || return 1
            [ -n "$ans2" ] && obfs_pw="$ans2"
            _validate_json_text "$obfs_pw" && break
            _error "混淆密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"
            obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
        done
    fi

    # 4) 带宽(可选, 仅限速语义)
    # 带宽写错的后果是"配置写入后启动被官方 binary 拒绝 → 整段回滚", 故在输入侧就用
    # 官方 bpsconv.go 的语法 + config.go 的下限校验挡下, 并原地重问(要求 3/4)。
    _hysteria_ask_value_reason "  上行限速 (如 100 mbps / 1g, 回车不限): " up 1 _hysteria_bandwidth_reason || return 1
    _hysteria_ask_value_reason "  下行限速 (如 100 mbps / 1g, 回车不限): " down 1 _hysteria_bandwidth_reason || return 1
    up=$(_normalize_bandwidth "$up"); down=$(_normalize_bandwidth "$down")

    # 4.5) 拥塞控制(可选, 官方 congestion 段)。只有该方向未使用 Brutal 时才生效
    # (官方文档: "只有在该方向没有使用 Brutal 时才会生效") —— 即带宽为空/未启用 Brutal 时
    # 才是真正生效的控制器选择, 故此处如实提示。
    # 回车 = 官方默认(bbr/standard), 此时**不写** congestion 段(与官方缺省等价)。
    echo -e "  拥塞控制 (非 Brutal 方向生效; 回车用官方默认 bbr/standard):"
    # 非法输入不再落进 case 的 *) 分支被静默当成默认值(要求 4): "填错了"与"选了默认"
    # 是两件事, 前者必须重问。回车才是官方默认(bbr/standard)。
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

    # 5) 伪装(可选, 默认官方 404)
    # 提示必须写明"必须包含 http(s)://"(用户实测: 只写"伪装站 URL"时大家都填 example.com,
    # 然后被校验拦下 —— 提示本身没把要求说清)。回车语义保持官方默认 404 不变。
    # 格式错误一律原地重问本字段, 不 return 1 丢弃整段向导(要求 2/3); 且**不做任何自动
    # 补全**(绝不把 example.com 悄悄补成 https://example.com, 要求 4)。
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

    # 6) 客户端连接地址(与其他协议共用同一问法/兜底)
    addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址, 已取消初始化"; return 1; }

    # 6.5) 认证密码(单密码模型: 官方 password 模式只需一个密码, **没有用户名**)
    # 用户明确要求: 不提示用户名 —— userpass 的 "用户名:密码" 客户端(Xray/sing-box)不认,
    # 手填 user:pass 才能连上, 这正是"都不支持连接"的根因(见文件头)。
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    # 密码含非法字符属可恢复输入错误 ⇒ 重问本字段; 随机值只在用户确认前生成一次,
    # 重问不重新掷(否则"改一下再试"会把已看过的密码换掉)。
    while true; do
        read -rp "  认证密码 (回车随机): " ans2 || return 1
        [ -n "$ans2" ] && auth="$ans2"
        _validate_json_text "$auth" && break
        _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"
        auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    done
    # 节点名 = 协议+端口(与原脚本命名规则一致), 端口取 listen 实际端口(跳跃下为首端口)
    def_name=$(_hysteria_default_name_for_listen "$listen")
    # 名称非法/重名都是**可恢复的用户输入错误**: 原地重问本字段(要求 3), 不再把用户
    # 扔回主菜单。注意保留既有语义 —— 回车用默认名, 且默认名被占时自动补序号。
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

    # 7) 组装官方配置并落地(失败即中止, 未触碰服务)
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
    # 防御: 空密码会 FATAL(实测), 组装结果必须含非空 password
    jq -e '.auth.type == "password" and (.auth.password | length) > 0' <<< "$config_json" >/dev/null || {
        _error "配置组装异常(auth.password 为空), 已中止"
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

    # 7.5) 节点元数据 + 分享链接: 必须在**启动服务之前**落地 ——
    # 否则 service 已 running 而节点元数据缺失时, Hysteria 侧凭据可用但 Manager
    # 完全看不到该节点(幽灵节点), 且此处失败不回滚会让初始化停在半成品状态。
    # 链接构建须喂真实临时文件 —— <(process substitution) 的 fd 带 CLOEXEC,
    # 函数内部 $(jq ...) 子进程打不开 /dev/fd/63(实测), 与 _hy2_gen_newmeta 同款模式。
    # 链接派生失败必须中止初始化(不得固化空链接); share_link 不再持久化(动态派生)。
    # 0.16.15 起预检只查完整性(元数据字段 + listen 可解析), 不再把"URI 表达不了 gecko
    # 自定义尺寸"当作初始化失败 —— 那是**呈现**缺口, 不该阻断服务器初始化。
    local meta_json tmp_meta
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || {
        _error "临时节点元数据创建失败, 回滚初始化"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    }
    if ! jq -n --arg a "$auth" --arg n "$name" --arg addr "$addr" \
         '{auth:$a,name:$n,link_addr:$addr}' > "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta"
        _error "临时节点元数据构建失败, 回滚初始化"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    fi
    if ! _hysteria_link_preflight "$tmp_meta" >/dev/null; then
        rm -f "$tmp_meta"
        _error "分享链接预检失败, 回滚初始化"
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META"
        return 1
    fi
    rm -f "$tmp_meta"
    meta_json=$(jq -n --arg a "$auth" --arg n "$name" \
        --arg addr "$addr" --arg created "$(date '+%Y-%m-%d')" \
        '{auth:$a,name:$n,link_addr:$addr,created:$created}')
    if ! _atomic_write_json "$HYSTERIA_NODE_META" "$meta_json"; then
        _error "节点元数据写入失败, 回滚初始化(配置/元数据)"
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
            _tip "请人工清理 service 后, 删除 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META"
            return 1
        fi
        rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODE_META"
        rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
        return 1
    fi
    if [ "$INIT_SYSTEM" != "direct" ]; then
        if ! _hysteria_restart_verified; then
            # P2-1(十五轮评审): 装机后的**真实启动**失败也可能是 AVX 变体在本机不可执行
            # (下载自检只跑 `version`)。先自动换普通 amd64 重装重试一次, 再谈回滚 ——
            # 否则"cpuinfo 报 avx 但热路径 SIGILL"会让用户在初始化阶段被永久挡住。
            if ! _hysteria_avx_runtime_retry "$(_hysteria_cached_version)" "$(_state_get hysteria_asset 2>/dev/null)"; then
                _error "Hysteria 服务启动失败, 回滚初始化(配置/服务)..."
                _hysteria_stop_and_verify >/dev/null 2>&1 || _warn "停止服务时仍有残留进程, 请人工核对"
                if ! _hysteria_cleanup_service_units; then
                    _error "service 定义清理失败, 已保留配置与元数据以便人工恢复(不删除)"
                    _tip "请人工清理 service 后, 删除 $HYSTERIA_CONFIG / $HYSTERIA_SERVER_META / $HYSTERIA_NODE_META"
                    return 1
                fi
                rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODE_META"
                rm -f /etc/logrotate.d/xd-hysteria 2>/dev/null
                _warn "初始化已回滚"
                return 1
            fi
        fi
    else
        # direct 模式无 service: 启动并做 1s 存活检查
        if ! _manage_hysteria start; then
            if ! _hysteria_avx_runtime_retry "$(_hysteria_cached_version)" "$(_state_get hysteria_asset 2>/dev/null)"; then
                rm -f "$HYSTERIA_CONFIG" "$HYSTERIA_SERVER_META" "$HYSTERIA_NODE_META"
                _error "启动失败, 已回滚配置"
                return 1
            fi
        fi
    fi

    # 9) clash 派生缓存(可再生; 失败仅告警, 不影响节点本体 —— helper 内部已 _warn)
    _hysteria_sync_clash "$HYSTERIA_NODE_META" || true
    _success "官方 Hysteria2 服务器已初始化: $(_hysteria_listen_display), TLS=$(_hysteria_tls_desc)"
    _hysteria_print_link "$HYSTERIA_NODE_META" || true
    return 0
}

# [2] 添加节点: 单密码模型下"添加节点"= 初始化服务器并创建唯一凭据。
# 已初始化时**不能**再加节点(官方 password 模式一个 auth 段只有一个密码), 如实告知
# 并指向改密码/卸载重建 —— 绝不静默覆盖现有密码(那会让所有已分发链接失效)。
# [2] 添加节点。单密码模型下只有三种情形, 必须**分别处理**(旧实现只判
# `_hysteria_server_initialized`, 于是"删了 node.json 但配置仍有密码"会形成死结:
# 既提示"已有节点"不给重建, 又无法再初始化 —— 见 _hysteria_node_exists 注释)。
#   1) 配置可运行 + node.json 存在 → 已有节点, 指向 [5] 改密码
#   2) 配置可运行 + node.json 缺失 → **接管**: 用配置里现成的认证密码重建节点元数据
#      (绝不改动认证段 —— 凭据是用户已经在用的, 换掉会让已分发的链接全部失效)
#   3) 配置不可运行/不存在 → bootstrap 新建(含认证密码)
_hysteria_add_node() {
    local auth name meta_json addr
    _hysteria_ensure_dirs || return 1
    if ! _hysteria_server_initialized; then
        # bootstrap 含认证密码创建(官方 binary 拒绝空密码, 不可先建空服务器)
        _hysteria_bootstrap
        return $?
    fi
    echo; echo -e "  ${CYAN}=== 添加 Hysteria2 (官方) 节点 ===${NC}"
    # 情形 1: 本 Manager 已接管(有**可用**节点元数据)
    if _hysteria_node_exists; then
        _warn "官方 password 模式只支持**一个**认证密码, 服务器已有节点(认证凭据已存在)"
        _tip "如需更换认证密码请用 [5] 修改节点密码; 如需多套独立凭据请分别部署多台服务器"
        _press_any_key
        return 0
    fi
    # 情形 1.5: 元数据存在但**损坏**(半截 JSON / 缺字段)—— 不能让损坏文件把 [2] 挡在
    # "已有节点"上, 否则 [5]/[4] 又都在 jq 上失败, 形成第二个死结(外部复审 P2)。
    # 确认后删除损坏文件, 继续走接管路径重建。
    if _hysteria_node_broken; then
        _warn "节点元数据已损坏(无法解析或缺少必要字段): $HYSTERIA_NODE_META"
        _tip "重建不会改动服务器认证密码, 只重写 Manager 侧的节点记录/链接/clash 条目"
        local ans_repair
        read -rp "  删除损坏的节点元数据并重建? [y/N]: " ans_repair
        case "$ans_repair" in
            y|Y) ;;
            *) _info "已取消(损坏文件保留, 可手工核对后重试)"; _press_any_key; return 0 ;;
        esac
        if ! rm -f "$HYSTERIA_NODE_META"; then
            _error "损坏的节点元数据删除失败(权限/只读?), 已取消"
            _press_any_key
            return 1
        fi
        _info "已移除损坏的节点元数据, 继续重建"
    fi
    # 情形 2: 服务器已有认证凭据但 Manager 侧无节点记录(手工部署过 / 删过节点记录)。
    # **接管**: 复用现成密码重建元数据, 不改 hysteria.json 的认证段。
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
    # 客户端连接地址: 优先沿用 server_meta 里已有的(接管场景多半已有), 无则询问。
    # **先只记在内存, 不在 node.json 落盘前持久化**(外部复审 P2): 旧实现在询问后立刻
    # _hysteria_meta_set, 若随后的 node.json 写入失败, 就留下"server_meta 已改 / node.json
    # 仍无"的半成品接管 —— 下次 [2] 会静默复用那个残留地址。改为**节点元数据先落盘,
    # 成功后才回写 server_meta**: 失败时 server_meta 原样, 无部分状态。
    local addr_need_save=0
    addr=$(_hysteria_meta_get link_addr)
    if [ -z "$addr" ]; then
        addr=$(_ask_link_addr) || { _error "未获取到客户端连接地址, 已取消"; _press_any_key; return 1; }
        addr_need_save=1
    else
        _info "沿用已有客户端连接地址: ${addr}"
    fi
    # 预检(元数据完整性 + listen 可解析), 失败不得固化半成品节点
    local tmp_meta
    tmp_meta=$(mktemp "${HYSTERIA_DATA_DIR}/.tmpmeta.XXXXXX") || {
        _error "临时节点元数据创建失败, 节点未创建"
        _press_any_key
        return 1
    }
    if ! jq -n --arg a "$auth" --arg n "$name" --arg ad "$addr" \
         '{auth:$a,name:$n,link_addr:$ad}' > "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta"
        _error "临时节点元数据构建失败, 节点未创建"
        _press_any_key
        return 1
    fi
    if ! _hysteria_link_preflight "$tmp_meta" >/dev/null; then
        rm -f "$tmp_meta"
        _error "分享链接预检失败, 节点未创建"
        _tip "请先确认 hysteria.json 的 listen/tls 等服务器级字段完整"
        _press_any_key
        return 1
    fi
    rm -f "$tmp_meta"
    meta_json=$(jq -n --arg a "$auth" --arg n "$name" --arg ad "$addr" \
        --arg created "$(date '+%Y-%m-%d')" \
        '{auth:$a,name:$n,link_addr:$ad,created:$created}')
    # 节点元数据是 Manager 侧权威状态, 与 config 无关 → 直接原子写(无需 config 事务:
    # 本路径**不改 hysteria.json**, 没有需要回滚的配置变更)
    if ! _atomic_write_json "$HYSTERIA_NODE_META" "$meta_json"; then
        _error "节点元数据写入失败, 节点未创建(server_meta 未改动, 无部分状态)"
        _press_any_key
        return 1
    fi
    # 节点元数据已落地后才回写 server_meta(顺序不可交换, 见上)。
    # 失败文案必须准确(外部复审 P2): 此时 node.json **已含** link_addr, 而
    # `_hysteria_node_exists` 已为真 → 下次 [2] 走"已有节点"分支, **不会再询问地址**。
    # 所以不能说"下次会重新询问"; 该字段在本路径也只是缓存 —— 链接/clash 一律从
    # node.json 读 link_addr, server_meta.link_addr 全项目仅此一处消费(接管时复用)。
    if [ "$addr_need_save" -eq 1 ]; then
        _hysteria_meta_set link_addr "$addr" \
            || _warn "连接地址未同步到 server_meta(节点已创建, 连接地址已保存在节点元数据中, 不影响链接与 clash 条目)"
    fi
    _hysteria_sync_clash "$HYSTERIA_NODE_META" || _warn "clash 条目同步失败(可手工编辑 ${CLASH_YAML})"
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
    # 语义缺口(gecko 自定义/非法尺寸)是服务器级的: 在列表顶部说明一次。
    # **绝不能**在这种情况下回退显示旧的持久化 share_link —— 那正是
    # "看着正常、语义不等价"的链接(0.16.15 P1)。
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
        # 区分两种"没有节点": 服务器根本没配 vs 配了但 Manager 侧无记录
        # (后者是"只清除了节点记录"的中间态, 必须明确指路 [2] 重建, 否则用户会以为要卸载重装)
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
    # share_link 动态派生(不持久化): 派生失败时如实报告, 不回退显示旧值
    link=$(_hysteria_node_link "$HYSTERIA_NODE_META") || link=""
    if [ -n "$link" ]; then
        echo -e "      ${link}"
    else
        _warn "分享链接派生失败(节点元数据缺字段? 请用 [2] 重新初始化或核对 $HYSTERIA_NODE_META)"
    fi
    _press_any_key
    return 0
}

# [4] 删除节点 —— 0.16.20 语义变更: 删除**服务器配置**并停止服务(用户要求, 2026-09-15)
#
# 旧实现只删 Manager 侧的节点记录(hysteria/node.json), 配置与服务原样保留 —— 但官方 Hysteria
# 里"配置即节点", 服务在跑就一直占用内存/端口。改为: 停止服务 + 删除服务器配置(hysteria.json)
# + 删除节点记录 + 清理派生缓存, 以真正释放资源(低配 NAT VPS 的主要动机: 省内存/省消耗)。
#
# **保留**: 核心 binary(下载耗时, 与"删配置"无关)、server_meta.json(link_addr/TLS 选择是
# Manager 侧缓存, 重新初始化时可复用)、自签证书(下次初始化可继续用同一证书路径)。
# **一并清理**: service 定义(systemd unit / openrc init)与 logrotate 片段。
# **顺序不可交换**: 停服 → 删配置(用户目的) → 删记录 → 清 unit → 清 clash。
#   - 删配置必须早于清 unit: 否则一旦删配置失败, unit 已消失 → 原运行状态再也无法恢复
#     (没有 unit 可重启, [2] 又因"配置可运行"只提示改密码 ⇒ 用户被卡住)。反过来 unit 清理
#     失败时配置已删、服务已停(用户目的已达成), 残留 unit 只影响下次开机且会被下次 [2]
#     重新写入覆盖(自愈), 故只告警不中止 —— 与 [14] 卸载的"清理失败保留现场"口径一致。
#   - 任何"配置删除之前"的中止(停服失败)都不改变运行状态; 删配置失败则恢复原运行状态。
_hysteria_delete_node() {
    local name="" ans was_running
    _hysteria_gate || { _press_any_key; return; }
    clear
    echo; echo -e "  ${CYAN}【删除 Hysteria2 (官方) 服务器配置】${NC}"
    if ! _hysteria_config_exists; then
        _warn "暂无服务器配置(未初始化)"
        _press_any_key
        return
    fi
    # 节点名(clash 条目按 name 删除): 记录缺失/损坏时如实说明, 但不影响删除动作本身 ——
    # 本操作删的是服务器配置, 记录只是顺带清掉的 Manager 侧缓存。
    # **读不到名字时不得静默跳过 clash 清理**(外部复审): clash.yaml 是按 name 删除的,
    # 没有名字就删不掉, 而用户会以为"删除节点"已把订阅条目一并清掉 —— 留下幽灵条目。
    # 故显式告警 + 指路手工清理, 而不是无声略过。
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
    read -rp "  确认删除服务器配置并停止服务? [y/N]: " ans
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; _press_any_key; return ;;
    esac
    # 保留(本函数刻意不删): $HYSTERIA_SERVER_META(Manager 侧缓存: link_addr/TLS 选择) /
    # 核心 binary / 自签证书 —— 重新初始化可复用, 无需重新下载或重签; 彻底移除走 [14] 卸载。
    was_running=$(_manage_hysteria status 2>/dev/null)
    # 1) 先停服: 内存立即释放; 且保证没有进程继续持有即将删除的配置。
    #    失败说明进程仍在(运行状态未变), 故无需"恢复"—— 直接中止。
    if ! _hysteria_stop_and_verify; then
        _error "服务未能停止(进程未退出), 已中止(配置未删除)"
        _tip "请先停止服务(菜单 [6] 服务管理)后重试"
        _press_any_key
        return 1
    fi
    # 2) 删服务器配置(用户目的)。**必须先于 service 定义清理**(见上方顺序契约):
    #    失败 ⇒ 中止并恢复原运行状态(此时 unit 仍在, 重启有效)。
    if ! rm -f "$HYSTERIA_CONFIG"; then
        _error "服务器配置删除失败(权限/只读?), 已中止"
        _tip "请人工核对: $HYSTERIA_CONFIG"
        _hysteria_recover_to_state "$was_running" || _warn "原运行状态恢复失败, 请人工检查服务状态"
        _press_any_key
        return 1
    fi
    # 3) 节点记录(Manager 侧缓存): 失败仅告警。**文案必须与真实控制流一致**(外部复审):
    #    配置已删 ⇒ _hysteria_server_initialized 为假 ⇒ 下次 [2] 走的是 **bootstrap
    #    重新初始化**(而 bootstrap 会整份重写 node.json), 不是"接管时覆盖"。故如实说明
    #    "重新初始化并重新生成记录", 并补一条手工删除路径。
    if ! rm -f "$HYSTERIA_NODE_META"; then
        _warn "节点记录删除失败(权限/只读?): $HYSTERIA_NODE_META"
        _tip "服务器配置已删除; 下次用 [2] 添加节点 会重新初始化服务器并重新生成节点记录"
        _tip "如需立即清除该残留记录, 可手工删除: $HYSTERIA_NODE_META"
    fi
    # 4) 清 service 定义 + logrotate 片段: 配置已删、服务已停(用户目的已达成), 失败只告警 ——
    #    残留 unit 仅影响下次开机(缺配置启动失败, 且被 systemd 启动限流自行停下), 且下次
    #    [2] 重新初始化时会重写该 unit(自愈)。这里**不**回滚配置删除(回滚等于丢掉用户要的结果)。
    _hysteria_cleanup_service_units \
        || _warn "service 定义清理失败(配置已删除, 服务已停止): 残留 unit 可能在下次开机尝试启动并失败, 请按上方提示人工清理"
    # 5) 派生缓存(clash 条目): 可再生, 失败仅告警(helper 内部已给出人工修法)
    [ -n "$name" ] && { _hysteria_remove_clash_by_name "$name" || true; }
    _success "服务器配置已删除, 服务已停止(核心 binary 保留)"
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
    # 节点级统一事务: auth.password(config) + 节点元数据(auth) 原子提交/回滚;
    # 链接动态派生 → 天然使用新密码。先预检元数据/服务器配置完整性。
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
    # 呈现走统一入口: 缺口时明确说"不可生成", 不给语义不完整的 URI
    _hysteria_print_link "$HYSTERIA_NODE_META" "新分享链接" || true
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

# ---------------------------------------------------------------------------
# 停止状态判定(0.16.20 外部复审 P1; 与 _hysteria_is_running 是两个不同的问题)
# ---------------------------------------------------------------------------
# **为什么不能拿 !_hysteria_is_running 当"已停止"**: _hysteria_is_running 的契约是
# "service 此刻真正在跑(ActiveState=active 且 SubState=running 且 MainPID≠0)"。
# 于是 activating / auto-restart / deactivating / failed **全都返回 1** —— 它们既不是
# "在跑", 也**不是"已停止"**, 而是"过渡态"。单元是 Restart=on-failure/RestartSec=3,
# 崩溃重启循环里 systemd 把 SERVICE_AUTO_RESTART 映射为 UNIT_ACTIVATING, 因此
# `_hysteria_is_running || return 0` 会在 auto-restart 等待期**立即**判"已停止" ——
# 调用方随即删掉配置, 而 systemd 3 秒后照样拉起 → "配置已删 / unit 仍在"(实测竞态)。
#
# 本判据要求**终态**: systemd 必须明确停在 inactive/failed, 且 MainPID=0, 且全机扫描
# 确认没有本项目的 hysteria 进程(exe 归属)。读不到 unit 信息时**绝不判"已停止"**
# (fail-closed) —— 交给 _hysteria_stop_and_verify 的 exe 强杀 + 复验兜底, 而不是靠
# "读不到 ⇒ 大概停了"赌一把。
#   rc 0 = 确认处于停止终态; rc 1 = 仍在运行/过渡态/读不到(调用方必须继续收敛)
_hysteria_stopped_state() {
    case "$INIT_SYSTEM" in
        systemd)
            local active mainpid
            active=$(systemctl show -p ActiveState --value "$HYSTERIA_SVC" 2>/dev/null)
            case "$active" in
                # 只有明确终态算"已停止"; active/activating/deactivating/reloading/空串都不算
                inactive|failed) ;;
                *) return 1 ;;
            esac
            mainpid=$(systemctl show -p MainPID --value "$HYSTERIA_SVC" 2>/dev/null)
            [ "$mainpid" = "0" ] || return 1
            _proc_any_named hysteria "$HYSTERIA_BIN" && return 1
            return 0
            ;;
        *)
            # openrc/direct: pidfile 已由 _manage_hysteria stop 清理; 用 exe 归属确认无进程
            _proc_any_named hysteria "$HYSTERIA_BIN" && return 1
            return 0
            ;;
    esac
}

# 卸载/删除/升级前的停止确认(): stop 后轮询确认业务进程真正退出;
# 仍存活时按 exe 归属(readlink /proc/*/exe == $HYSTERIA_BIN, 含 "(deleted)" 就地替换
# 形态)强制终止 —— exe 校验保证绝不误杀同名的他方进程; 再不退则返回 1 交人工处理,
# 调用方必须拒绝继续删除文件, 避免"文件已删/进程仍在"的孤儿进程。
#
# **契约 = "到达停止终态", 不是"某一刻没有进程"(0.16.20 外部复审 P1)。**
# 判定必须走 _hysteria_stopped_state(要求 systemd 明确 inactive/failed), **不得**用
# `!_hysteria_is_running` —— 后者把 activating/auto-restart 也当"已停止", 会在崩溃重启
# 循环里提前放行(见该函数注释)。强杀绕过 init 系统后必须**再 stop 一次**(Restart=
# on-failure 的单元可能因退出码重新拉起), 然后才复验; 全程不成功返回 1。
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
    # 强杀是绕过 init 系统的动作: Restart=on-failure 的单元可能因该进程的退出码而重新拉起,
    # 故必须**再 stop 一次**, 然后才复验终态(顺序不可交换)。
    _manage_hysteria stop 2>/dev/null
    for i in 1 2 3 4 5; do
        _hysteria_stopped_state && return 0
        sleep 1
    done
    return 1
}

# service 定义清理 + 最终状态验证: 原回滚路径的 disable/rm/daemon-reload
# 全是 best-effort, 失败会让"unit 残留 + config 已删"的半残状态静默通过。这里逐步执行并
# 复核 unit 确实消失(systemd 用 LoadState=not-found, openrc 用文件不存在), 残留时大声告警
# 并给出人工命令 —— 属"明确降级"而非静默成功。返回 0=已清理干净; 1=仍有残留(已告警)。
#
# **"unit 文件不存在" ≠ "注册关系已解除"(0.16.20 外部复审 P2)。** systemd 的 enable 本质是
# 在 `<target>.wants/` 下建符号链接, disable 才是删链接 —— 若 disable 失败而 rm unit 成功,
# LoadState 照样是 not-found, 却留下 dangling 的 wants 链接(systemd 自己用 is-enabled 才能
# 回答"是否仍被启用")。故 systemd 侧补验 is-enabled 不得为 enabled, 并扫掉指向本 unit 的
# 残留符号链接; openrc 侧同理补验 runlevel 注册已解除(rc-update show), 不能只看 init 脚本文件。
_hysteria_cleanup_service_units() {
    local ok=1
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable "$HYSTERIA_SVC" 2>/dev/null
            rm -f "/etc/systemd/system/${HYSTERIA_SVC}.service"
            systemctl daemon-reload 2>/dev/null
            systemctl reset-failed "$HYSTERIA_SVC" 2>/dev/null
            # 1) unit 本身必须已不可被 systemd 识别
            [ "$(systemctl show -p LoadState --value "$HYSTERIA_SVC" 2>/dev/null)" = "not-found" ] && ok=0
            # 2) 不得仍处于任何"被启用"形态(disable 失败的典型残局)。
            #    is-enabled 不止输出 enabled —— 还有 enabled-runtime / alias / linked /
            #    indirect 等; 只比 `= "enabled"` 会漏掉 enabled-runtime/alias 这类仍会被拉起的
            #    形态。本项目 unit 带 [Install] WantedBy=multi-user.target, 正常只有 enabled,
            #    但把"非 enabled 就安全"写死是错的 —— 改为**否定白名单**: 只有明确表示
            #    "未启用"的取值才算安全, 其余(含未来新增状态)一律按"仍被启用"处理(fail-closed)。
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
            # 3) 不得残留指向本 unit 的符号链接(enable 的 .wants/.requires 链接)。
            #    搜索路径覆盖 systemd 的 unit 搜索位置 —— /etc/systemd/system 是 enable 的落点,
            #    /run/systemd/system 与 /usr/lib/systemd/system 亦可能被植入链接(项目 unit 只写
            #    /etc, 但残留可能出现在任一搜索路径上)。
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
            # 1) init 脚本必须已删除
            [ ! -e "/etc/init.d/${HYSTERIA_SVC}" ] && ok=0
            # 2) runlevel 注册必须已解除(rc-update del 失败的残局: 文件没了但注册还在)
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
    # clash.yaml 派生条目(在数据目录删除前取名字)。单密码模型: 只有一份节点元数据。
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

# 兼容清理(一次性): 旧版用 state/hysteria_variant 记录"用户手动选择的变体"(配套已删除的
# [4] 菜单项)。变体现由 CPU 能力自动决定, 该键已无意义 —— 残留会让后来者误以为它仍生效。
# 若用户曾显式选过 plain, 本次起会改用 AVX, 属**行为变更**, 故必须说出来而不是静默忽略
# (删除用 rm -f 而非写空串: 空值会留下 0 字节 state 文件, 仍是个"存在的键")。
_hysteria_purge_legacy_variant_state() {
    [ -f "$STATE_DIR/hysteria_variant" ] || return 0
    rm -f "$STATE_DIR/hysteria_variant" \
        && _warn "已移除废弃记录 state/hysteria_variant: AVX 变体现在按 CPU 能力自动选择(支持即优先使用)"
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
    # 进入菜单时的一次性幂等清理(declare -F 守卫, 与主菜单对混合版本安装的惯例一致)
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
                echo -e "  核心: ${GREEN}${cur}${NC}  状态: ${GREEN}● 运行中${NC}  (Xray Hy2 在菜单 [6], 两者独立)"
            else
                echo -e "  核心: ${GREEN}${cur}${NC}  状态: ${RED}○ 已停止${NC}  (Xray Hy2 在菜单 [6], 两者独立)"
            fi
        else
            echo -e "  核心: ${RED}未安装${NC}"
        fi
        # 节点 = 服务器唯一认证凭据(单密码模型): 有元数据即 1, 否则 0。
        # 端口/跳跃属于服务器级设置, 单值 "监听: <port>" 表达不了跳跃范围的全貌(客户端实际
        # 用的是整个范围, 真实 listening socket 只是范围首端口), 故端口现况在
        # [7] 端口/端口跳跃 里按范围显示, 并已写入分享链接。
        local ncount=0
        [ -f "$HYSTERIA_NODE_META" ] && ncount=1
        echo -e "  节点: ${CYAN}${ncount}${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 安装/更新官方核心"
        echo -e "  ${GREEN}[2]${NC} 添加节点"
        echo -e "  ${GREEN}[3]${NC} 查看节点"
        # 标签必须与实际语义一致(外部复审): 该项已不只是"删 Manager 记录", 而是
        # 停服 + 删服务器配置 + 清 unit/记录/派生条目, 故补上"停止服务"以免误导。
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
            # [2] 不得再追加 _press_any_key: _hysteria_add_node 的每条返回路径都已自带一次
            # (含 bootstrap/接管/取消), 再追加会让用户连按两次回车(实机发现)。与 [3]/[4]/[5]
            # 同口径 —— 菜单只负责调用, 暂停由被调函数自己收尾。
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
