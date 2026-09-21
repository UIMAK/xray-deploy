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
