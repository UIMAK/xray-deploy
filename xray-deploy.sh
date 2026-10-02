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
# 旧写法只在 `main()` 里前置了一次, 而 `readlink`/`dirname`(下面两行)跑在它**之前** ——
# 以 root 被调用时(菜单、以及 cron 触发的 `xd geo-update`)调用方 PATH 里的同名命令会在
# 加固生效前先执行。
# 口径与 `main()` 里那行**逐字一致**(前置固定目录, **保留**调用方尾缀):
#   · 前置是必需的 —— 系统目录必须优先于调用方 PATH, 否则可被非 root 写入的目录里的同名
#     curl/jq/systemctl 会劫持 root 操作;
#   · 尾缀**不能删** —— 非标准前缀安装(工具不在这些目录里)会让脚本连 `readlink` 都找不到,
#     而前置已消除上面那条真实劫持路径。两处都保留尾缀是为了两条代码路径行为一致。
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"

# 定位脚本与 lib 目录(支持从 /usr/local/bin 软链运行 + 直接运行两种)
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"

# Capture the inode of the entrypoint this Bash process opened before it waits for the
# installer lock. The pathname alone is insufficient: install.sh replaces that inode.
_bootstrap_entry_open_identity() {
    local fd target
    for fd in /proc/$$/fd/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        target="${target% (deleted)}"
        [ "$target" = "$SELF_PATH" ] || continue
        stat -Lc '%d:%i' "$fd" 2>/dev/null && return 0
    done
    return 1
}
_BOOTSTRAP_ENTRY_ID=$(_bootstrap_entry_open_identity 2>/dev/null || true)

# lib 目录: 优先与本脚本同目录的 lib/, 否则 /opt/xray-deploy/lib(安装后)
LIB_DIR="$SCRIPT_DIR/lib"
[ -d "$LIB_DIR" ] || LIB_DIR="/opt/xray-deploy/lib"

# 模块清单。逐个显式校验存在且可读 —— 旧写法直接 `. "$LIB_DIR/x.sh"`, 缺模块时只会
# 刷出一行 "No such file or directory" 然后**继续往下跑** main(): 一部分函数已定义、
# 一部分没有, 用户看到的是运行中途的怪异报错(或 set -u 崩溃), 而不是"你的安装不完整"。
# **这份清单必须与 install.sh 里的 LIB_MODULES 逐字一致**(漂移由 tests/run-tests.sh 的
# 一致性断言守住)。install.sh 用它在远程安装时逐份下载, 这里用它在运行时逐份 source。
LIB_MODULES="00-common 10-system 20-xray-core 30-geo 40-cloudflared 45-logrotate 50-nodes 51-reality-pq 55-hysteria 90-menu"

# Installer publication lock: wait before module sourcing so a runtime reader cannot combine
# files from different installer generations.
_BOOTSTRAP_LOCK_ROOT="/var/lock/xray-deploy"
if ! mkdir -p "$_BOOTSTRAP_LOCK_ROOT" 2>/dev/null; then
    _BOOTSTRAP_LOCK_ROOT="/run/lock/xray-deploy"
    if ! mkdir -p "$_BOOTSTRAP_LOCK_ROOT" 2>/dev/null; then
        echo "[错误] 无法创建安装/加载互斥锁目录(/var/lock 与 /run/lock 均失败)" >&2
        exit 1
    fi
fi
_BOOTSTRAP_LOCK_FILE="$_BOOTSTRAP_LOCK_ROOT/install.lock.fd"
_BOOTSTRAP_LOCK_DIR="$_BOOTSTRAP_LOCK_ROOT/install.lock"
_BOOTSTRAP_LOCK_FD=""
_BOOTSTRAP_LOCK_MODE=""
_BOOTSTRAP_MARKER_HELD=0

_bootstrap_lock_file_open_status() {  # 0=open, 1=not open, 2=observation unknown
    local want="$1" matches find_rc p pid target
    if command -v find >/dev/null 2>&1; then
        matches=$(find /proc/[0-9]*/fd -type l -lname "$want" -print -quit 2>/dev/null)
        find_rc=$?
        if [ "$find_rc" -eq 0 ]; then
            [ -n "$matches" ] && return 0
            return 1
        fi
    fi
    [ -d /proc ] || return 2
    for p in /proc/[0-9]*/fd/*; do
        pid=${p#/proc/}; pid=${pid%%/*}
        [ "$pid" = "${BASHPID:-$$}" ] && continue
        target=$(readlink "$p" 2>/dev/null) || return 2
        [ "$target" = "$want" ] && return 0
    done
    return 1
}

_bootstrap_flock_marker_take() {  # caller already owns the install flock
    local devino witness owner i
    devino=$(stat -c '%d:%i' "$_BOOTSTRAP_LOCK_FILE" 2>/dev/null) || devino=""
    [ -n "$devino" ] || { echo "[错误] 无法读取安装锁文件标识, 模块加载中止" >&2; return 1; }
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if mkdir "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null; then
            owner="${BASHPID:-$$}"
            if printf '%s\n' "$owner" > "$_BOOTSTRAP_LOCK_DIR/pid" 2>/dev/null \
               && printf '%s\n' "$devino" > "$_BOOTSTRAP_LOCK_DIR/.witness" 2>/dev/null \
               && [ "$(cat "$_BOOTSTRAP_LOCK_DIR/.witness" 2>/dev/null)" = "$devino" ]; then
                return 0
            fi
            [ "$(cat "$_BOOTSTRAP_LOCK_DIR/pid" 2>/dev/null)" = "$owner" ] && rm -rf "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null
            echo "[错误] 无法建立安装锁跨后端见证标记, 模块加载中止" >&2
            return 1
        fi
        if [ -d "$_BOOTSTRAP_LOCK_DIR" ] && [ ! -L "$_BOOTSTRAP_LOCK_DIR" ] \
           && [ -f "$_BOOTSTRAP_LOCK_DIR/.witness" ] && [ ! -L "$_BOOTSTRAP_LOCK_DIR/.witness" ]; then
            witness=$(cat "$_BOOTSTRAP_LOCK_DIR/.witness" 2>/dev/null) || witness=""
            if [ "$witness" = "$devino" ]; then
                if rm -rf "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null \
                   && [ ! -e "$_BOOTSTRAP_LOCK_DIR" ] && [ ! -L "$_BOOTSTRAP_LOCK_DIR" ]; then
                    continue
                fi
                echo "[错误] 无法清理安装锁陈旧 flock 见证, 模块加载中止" >&2
                return 1
            fi
            echo "[错误] 安装锁见证身份不符, 拒绝接管: $_BOOTSTRAP_LOCK_DIR" >&2
            return 1
        fi
        sleep 1
    done
    echo "[错误] 等待安装 mkdir 后端互斥超时或发现残留锁, 模块加载中止" >&2
    return 1
}

_bootstrap_lock_release() {
    local rc=0 owner witness devino
    if [ "${_BOOTSTRAP_MARKER_HELD:-0}" = "1" ]; then
        if [ "$_BOOTSTRAP_LOCK_MODE" = flock ]; then
            owner=$(cat "$_BOOTSTRAP_LOCK_DIR/pid" 2>/dev/null) || owner=""
            witness=$(cat "$_BOOTSTRAP_LOCK_DIR/.witness" 2>/dev/null) || witness=""
            devino=$(stat -c '%d:%i' "$_BOOTSTRAP_LOCK_FILE" 2>/dev/null) || devino=""
            if [ "$owner" = "${BASHPID:-$$}" ] && [ -n "$devino" ] && [ "$witness" = "$devino" ] \
               && rm -rf "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null \
               && [ ! -e "$_BOOTSTRAP_LOCK_DIR" ] && [ ! -L "$_BOOTSTRAP_LOCK_DIR" ]; then
                :
            else
                echo "[错误] 安装锁见证归属/身份校验失败或无法删除, 保留: $_BOOTSTRAP_LOCK_DIR" >&2
                rc=1
            fi
        else
            owner=$(cat "$_BOOTSTRAP_LOCK_DIR/pid" 2>/dev/null) || owner=""
            if [ "$owner" = "${BASHPID:-$$}" ] \
               && rm -f "$_BOOTSTRAP_LOCK_DIR/pid" 2>/dev/null \
               && rmdir "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null; then
                :
            else
                echo "[错误] 安装 mkdir 锁归属校验/释放失败, 保留: $_BOOTSTRAP_LOCK_DIR" >&2
                rc=1
            fi
        fi
        _BOOTSTRAP_MARKER_HELD=0
    fi
    if [ -n "${_BOOTSTRAP_LOCK_FD:-}" ]; then
        flock -u "$_BOOTSTRAP_LOCK_FD" 2>/dev/null || :
        eval "exec ${_BOOTSTRAP_LOCK_FD}>&-" 2>/dev/null || :
        _BOOTSTRAP_LOCK_FD=""
    fi
    return "$rc"
}

if command -v flock >/dev/null 2>&1; then
    { exec {_BOOTSTRAP_LOCK_FD}>>"$_BOOTSTRAP_LOCK_FILE"; } 2>/dev/null || {
        echo "[错误] 无法打开安装锁文件, 模块加载中止" >&2
        exit 1
    }
    _bootstrap_locked=0
    for _bootstrap_i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if flock -n "$_BOOTSTRAP_LOCK_FD" 2>/dev/null; then _bootstrap_locked=1; break; fi
        sleep 1
    done
    if [ "$_bootstrap_locked" -ne 1 ]; then
        echo "[错误] 等待安装发布锁超时, 模块加载中止" >&2
        eval "exec ${_BOOTSTRAP_LOCK_FD}>&-" 2>/dev/null
        exit 1
    fi
    _BOOTSTRAP_LOCK_MODE=flock
    if ! _bootstrap_flock_marker_take; then
        flock -u "$_BOOTSTRAP_LOCK_FD" 2>/dev/null || :
        eval "exec ${_BOOTSTRAP_LOCK_FD}>&-" 2>/dev/null
        _BOOTSTRAP_LOCK_FD=""
        exit 1
    fi
    _BOOTSTRAP_MARKER_HELD=1
else
    if ! mkdir "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null; then
        echo "[错误] 安装发布 mkdir 锁已占用/残留: $_BOOTSTRAP_LOCK_DIR" >&2
        exit 1
    fi
    _BOOTSTRAP_LOCK_MODE=mkdir
    _BOOTSTRAP_MARKER_HELD=1
    if ! printf '%s\n' "${BASHPID:-$$}" > "$_BOOTSTRAP_LOCK_DIR/pid" 2>/dev/null; then
        rmdir "$_BOOTSTRAP_LOCK_DIR" 2>/dev/null || :
        _BOOTSTRAP_MARKER_HELD=0
        echo "[错误] 无法写入安装发布锁持有者记录, 模块加载中止" >&2
        exit 1
    fi
    _bootstrap_lock_file_open_status "$_BOOTSTRAP_LOCK_FILE"; _bootstrap_lrc=$?
    case "$_bootstrap_lrc" in
        0|2)
            echo "[错误] 安装 flock 主锁被占用或无法确认, 模块加载中止" >&2
            _bootstrap_lock_release || :
            exit 1
            ;;
    esac
fi
trap '_bootstrap_lock_release' EXIT

if [ -n "$_BOOTSTRAP_ENTRY_ID" ]; then
    _bootstrap_published_id=$(stat -Lc '%d:%i' "$SELF_PATH" 2>/dev/null) || _bootstrap_published_id=""
    if [ -z "$_bootstrap_published_id" ]; then
        echo "[错误] 无法确认当前发布的入口脚本身份, 拒绝加载模块" >&2
        exit 1
    fi
    if [ "$_bootstrap_published_id" != "$_BOOTSTRAP_ENTRY_ID" ]; then
        # This process opened the previous entrypoint before waiting on the lock. Release its
        # reader lock, then re-exec the currently published generation; that process rechecks too.
        echo "[信息] 等待安装期间入口版本已更新, 重新启动当前版本" >&2
        _bootstrap_lock_release || exit 1
        trap - EXIT
        exec "$SELF_PATH" "$@"
    fi
fi

_DEPLOY_ROOT="$(dirname "$LIB_DIR")"
for _txn_dir in "$_DEPLOY_ROOT"/.install-rollback.*; do
    [ -e "$_txn_dir" ] || [ -L "$_txn_dir" ] || continue
    _txn_name="${_txn_dir##*/}"
    _txn_suffix="${_txn_name#.install-rollback.}"
    case "$_txn_suffix" in ''|*[!0-9]*) continue ;; esac
    _txn_marker="$_txn_dir/.INSTALLING"
    [ -e "$_txn_marker" ] || [ -L "$_txn_marker" ] || continue
    if [ ! -d "$_txn_dir" ] || [ -L "$_txn_dir" ] || [ ! -f "$_txn_marker" ] || [ -L "$_txn_marker" ]; then
        echo "[错误] 安装事务标记或目录类型无效, 模块加载中止: $_txn_marker" >&2
        echo "       请检查恢复目录并重新运行 install.sh --update" >&2
        exit 1
    fi
    echo "[错误] 检测到未完成安装事务: $_txn_marker" >&2
    echo "       请重新运行 install.sh --update, 让它先恢复更新前文件" >&2
    exit 1
done

for _m in $LIB_MODULES; do
    if [ ! -r "$LIB_DIR/${_m}.sh" ]; then
        echo "[错误] 缺少或不可读的模块: $LIB_DIR/${_m}.sh" >&2
        echo "       安装不完整(或 lib 与主脚本版本不一致), 请重新执行 install.sh --update" >&2
        exit 1
    fi
done

unset _DEPLOY_ROOT

# source 公共层(定义所有常量与 DEPLOY_DIR 等)
for _m in $LIB_MODULES; do
    # shellcheck disable=SC1090
    . "$LIB_DIR/${_m}.sh" || {
        echo "[错误] 加载模块失败: $LIB_DIR/${_m}.sh" >&2
        echo "       请运行 install.sh --update 修复不完整或语法错误的安装" >&2
        exit 1
    }
done
unset _m
if ! _bootstrap_lock_release; then
    trap - EXIT
    exit 1
fi
trap - EXIT
unset -f _bootstrap_entry_open_identity _bootstrap_lock_file_open_status _bootstrap_flock_marker_take _bootstrap_lock_release
unset _BOOTSTRAP_ENTRY_ID _bootstrap_published_id
unset _BOOTSTRAP_LOCK_ROOT _BOOTSTRAP_LOCK_FILE _BOOTSTRAP_LOCK_DIR _BOOTSTRAP_LOCK_FD
unset _BOOTSTRAP_LOCK_MODE _BOOTSTRAP_MARKER_HELD _bootstrap_locked _bootstrap_i _bootstrap_lrc

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
    # 旧版单文件 config.json → confs/ 的迁移也在这里兜一次(cron 子命令不经过菜单)。
    if declare -F _config_migrate_legacy >/dev/null 2>&1; then
        _config_migrate_legacy || _warn "旧单文件配置迁移失败, 请从主菜单检查"
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
