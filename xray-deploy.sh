#!/bin/bash
# =============================================================================
# xray-deploy.sh — Xray 部署管理脚本(主入口)
# 安装后落 /usr/local/bin/xd, 输入 xd 唤出菜单
# 支持子命令: xd geo-update, xd timed-restart (供 cron 调用)
#   geo-update 仅旧核心(< v26.4.25)的系统 cron 方案使用; 新核心走 config 的 geodata 内置定时
# =============================================================================

set -u

# 部署目录含私钥/密码/隧道 token, 默认 077 使新建文件仅 root 可读(可执行位由 chmod +x 单独授予)
umask 077

# PATH 加固必须在**本脚本的第一个外部命令之前**(2026-09-22 open-code-review #46)。
# 旧写法只在 `main()` 里前置了一次, 而 `readlink`/`dirname`(下面两行)与 manifest 段的
# `sha256sum`/`awk` 都跑在它**之前** —— 以 root 被调用时(菜单、以及 cron 触发的
# `xd geo-update`)调用方 PATH 里的同名命令会在加固生效前先执行。
# 口径与 `main()` 里那行**逐字一致**(前置固定目录, **保留**调用方尾缀):
#   · 前置是必需的 —— 系统目录必须优先于调用方 PATH, 否则可被非 root 写入的目录里的同名
#     curl/jq/systemctl 会劫持 root 操作;
#   · 尾缀**不能删** —— 非标准前缀安装(工具不在这些目录里)会让脚本连 `readlink` 都找不到,
#     而前置已消除上面那条真实劫持路径。两处都保留尾缀是为了两条代码路径行为一致。
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"

# 定位脚本与 lib 目录(支持从 /usr/local/bin 软链运行 + 直接运行两种)
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"

# lib 目录: 优先与本脚本同目录的 lib/, 否则 /opt/xray-deploy/lib(安装后)
LIB_DIR="$SCRIPT_DIR/lib"
[ -d "$LIB_DIR" ] || LIB_DIR="/opt/xray-deploy/lib"

# 模块清单。逐个显式校验存在且可读 —— 旧写法直接 `. "$LIB_DIR/x.sh"`, 缺模块时只会
# 刷出一行 "No such file or directory" 然后**继续往下跑** main(): 一部分函数已定义、
# 一部分没有, 用户看到的是运行中途的怪异报错(或 set -u 崩溃), 而不是"你的安装不完整"。
# **这份清单必须与 install.sh 里的 LIB_MODULES 逐字一致**(漂移由 tests/run-tests.sh 的
# 一致性断言守住)。install.sh 用它在远程安装时逐份下载, 这里用它在运行时逐份 source。
LIB_MODULES="00-common 10-system 20-xray-core 30-geo 40-cloudflared 45-logrotate 50-nodes 51-reality-pq 55-hysteria 90-menu"
for _m in $LIB_MODULES; do
    if [ ! -r "$LIB_DIR/${_m}.sh" ]; then
        echo "[错误] 缺少或不可读的模块: $LIB_DIR/${_m}.sh" >&2
        echo "       安装不完整(或 lib 与主脚本版本不一致), 请重新执行 install.sh --update" >&2
        exit 1
    fi
done

# 安装清单一致性校验(2026-09-21 五轮复审 P1 收尾)。
# 逐文件原子 + 安装器整体回滚覆盖"安装中途失败", 但覆盖不了**进程被 SIGKILL**(回滚代码没机会
# 执行) —— 此时磁盘上就是混合版本, 而上面那条检查只看"存在且可读", 会放行。
# 安装成功后由 install.sh 生成 <部署根>/.manifest(每行 `<sha256>  <relpath>`), 这里独立校验。
#
# 三条硬约束:
#   · **不得调用任何 lib 函数** —— 要校验的正是 lib 是否可信, 用 lib 函数去校验是循环论证;
#     因此只用 POSIX 工具 + sha256sum。也**不能**用 $DEPLOY_DIR: 它由 00-common 定义, 而本段
#     必须跑在 source 之前(那时它还是未定义, set -u 会直接中止脚本)。
#   · **只告警不阻断**: 手工热修一个 lib 文件会让 hash 不匹配, 据此 exit 1 等于把用户锁在门外。
#     项目取向是"数据安全 fail-closed, 可用性 fail-open"(同 _proc_exe_is 的注释推理)。
#   · `.manifest` 缺失(旧装机)/ sha256sum 缺失 => 静默跳过, 行为与今天一致。
# 部署根与 LIB_DIR 同源(上面刚解析): 用 SCRIPT_DIR/lib 则根为 SCRIPT_DIR, 用
# /opt/xray-deploy/lib 则根为 /opt/xray-deploy —— 与 install.sh 写入清单的位置一致。
_DEPLOY_ROOT="$(dirname "$LIB_DIR")"
if [ -f "$_DEPLOY_ROOT/.manifest" ] && command -v sha256sum >/dev/null 2>&1; then
    _manifest_bad=""
    while read -r _mh _mp; do
        [ -n "$_mh" ] || continue
        [ -n "$_mp" ] || continue
        # 清单解析必须**健壮**(2026-09-22 open-code-review #47)。旧写法把任何非空的两字段
        # 行都当成合法条目, 实测两个后果:
        #   · `deadbeef…  ../../etc/hostname` 会让校验去读**部署根之外**的文件 ——
        #     用形如 `/tmp/xxx` 的路径会被判为 path traversal 而拒绝(与审查项同源);
        #   · 非 64 位 hex 的"哈希"永远不匹配, 于是**每一条**都报"不一致", 把真正的
        #     不一致淹没在噪声里(实测 4 行畸形清单报出 3 条假项, 只有 1 条是真的)。
        # **只告警不阻断的口径不变**(见上方第 2 条硬约束): 这里只决定"要不要去读这个路径",
        # 违规条目记一条"格式错误"就够, 绝不 exit。
        case "$_mp" in
            /*|..|../*|*/../*|*/..) _manifest_bad="$_manifest_bad [不安全路径:$_mp]"; continue ;;
        esac
        case "$_mh" in
            *[!0-9a-f]*) _manifest_bad="$_manifest_bad [格式错误:$_mp]"; continue ;;
        esac
        [ "${#_mh}" -eq 64 ] || { _manifest_bad="$_manifest_bad [格式错误:$_mp]"; continue; }
        _mgot=$(sha256sum "$_DEPLOY_ROOT/$_mp" 2>/dev/null | awk '{print $1}')
        [ "$_mgot" = "$_mh" ] || _manifest_bad="$_manifest_bad $_mp"
    done < "$_DEPLOY_ROOT/.manifest"
    if [ -n "$_manifest_bad" ]; then
        echo "[警告] 以下模块与安装清单不一致(可能安装中断或被手工修改):${_manifest_bad}" >&2
        echo "       建议重跑 install.sh --update 同步全部模块" >&2
    fi
    unset _manifest_bad _mh _mp _mgot
fi
unset _DEPLOY_ROOT

# source 公共层(定义所有常量与 DEPLOY_DIR 等)
for _m in $LIB_MODULES; do
    # shellcheck disable=SC1090
    . "$LIB_DIR/${_m}.sh"
done
unset _m

# ---------------------------------------------------------------------------
# 初始化(每次启动轻量探测, 仅缺依赖时安装)
# ---------------------------------------------------------------------------
_init_runtime() {
    _check_root
    INIT_SYSTEM=$(_detect_init_system)
    _ensure_dirs || { _error "初始化失败: 无法确保安全目录/权限"; exit 1; }
    if ! _ensure_base_deps; then
        _warn "基础依赖安装失败, 部分功能可能不可用, 请检查网络或包管理"
    fi
}

# ---------------------------------------------------------------------------
# cron 子命令共用的初始化。
# 旧实现两个 cron 分支各自只做"探测 init + _ensure_dirs", 跳过了 _ensure_base_deps ——
# 而 _geo_update/_timed_restart_do 依赖 curl/wget/jq: 最小 cron 环境(Alpine/busybox)
# 下缺依赖不会补装, 子命令只以晦涩错误失败。三个入口现在走同一套初始化。
# 输出重定向: cron 下 stdout 会进邮件, 依赖安装的常规输出属噪音。
# ---------------------------------------------------------------------------
_cron_init() {
    _check_root
    INIT_SYSTEM=$(_detect_init_system)
    _ensure_dirs || { _error "初始化失败: 无法确保安全目录/权限"; exit 1; }
    # 依赖安装失败必须留下痕迹: 静默 `|| true` 会让随后的 _geo_update/_timed_restart_do
    # 以"curl/jq 找不到"这类晦涩错误失败, cron 日志里看不出真正原因。
    # 成功路径的常规输出仍然吞掉; 失败时留下告警(cron 会写进邮件/日志)。
    if ! _ensure_base_deps >/dev/null 2>&1; then
        _warn "基础依赖安装失败, 部分功能可能不可用(cron 子命令可能失败)"
    fi
}

# ---------------------------------------------------------------------------
# 主调度
# ---------------------------------------------------------------------------
main() {
    # cron 环境 PATH 可能受限(Alpine 尤其), 确保 jq/systemctl 等可找到。
    # **前置**(不是追加): 本脚本以 root 运行, 系统目录必须优先于调用方 PATH —— 否则
    # 一个可被非 root 写入的 PATH 目录里的同名 curl/jq/systemctl 会劫持 root 操作。
    export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"
    # 菜单与 cron 子命令都必须 root(写 /opt、重启服务)
    _check_root
    # 子命令: geo-update(cron 调用)
    if [ "${1:-}" = "geo-update" ]; then
        [ "$#" -eq 1 ] || { _error "geo-update 不接受额外参数: $*"; exit 2; }
        _cron_init
        _geo_update
        exit $?
    fi
    # 子命令: timed-restart(cron 调用)
    if [ "${1:-}" = "timed-restart" ]; then
        [ "$#" -eq 1 ] || { _error "timed-restart 不接受额外参数: $*"; exit 2; }
        _cron_init
        _timed_restart_do
        exit $?
    fi
    # 未知子命令必须显式拒绝: 旧实现静默落进交互菜单 —— cron 里拼错子命令会让脚本挂在
    # 等待 stdin 的菜单上(读 EOF 后空转), 而不是报错退出。
    if [ "$#" -gt 0 ]; then
        _error "未知参数: $*"
        echo "       用法: xd [geo-update|timed-restart]  (无参数进入菜单)"
        exit 2
    fi

    _init_runtime
    _main_menu
}

main "$@"
