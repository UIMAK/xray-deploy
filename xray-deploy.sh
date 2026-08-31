#!/bin/bash
# =============================================================================
# xray-deploy.sh — Xray 部署管理脚本(主入口)
# 安装后落 /usr/local/bin/xd, 输入 xd 唤出菜单
# 支持子命令: xd geo-update, xd timed-restart (供 cron 调用)
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

# source 公共层(定义所有常量与 DEPLOY_DIR 等)
# shellcheck source=lib/00-common.sh
. "$LIB_DIR/00-common.sh"
# shellcheck source=lib/10-system.sh
. "$LIB_DIR/10-system.sh"
# shellcheck source=lib/20-xray-core.sh
. "$LIB_DIR/20-xray-core.sh"
# shellcheck source=lib/30-geo.sh
. "$LIB_DIR/30-geo.sh"
# shellcheck source=lib/40-cloudflared.sh
. "$LIB_DIR/40-cloudflared.sh"
# shellcheck source=lib/45-logrotate.sh
. "$LIB_DIR/45-logrotate.sh"
# shellcheck source=lib/50-nodes.sh
. "$LIB_DIR/50-nodes.sh"
# shellcheck source=lib/51-reality-pq.sh
. "$LIB_DIR/51-reality-pq.sh"
# shellcheck source=lib/90-menu.sh
. "$LIB_DIR/90-menu.sh"

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
# 主调度
# ---------------------------------------------------------------------------
main() {
    # cron 环境 PATH 可能受限(Alpine 尤其), 确保 jq/systemctl 等可找到
    export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"
    # 菜单与 cron 子命令都必须 root(写 /opt、重启服务)
    _check_root
    # 子命令: geo-update(cron 调用)
    if [ "${1:-}" = "geo-update" ]; then
        INIT_SYSTEM=$(_detect_init_system)
        _ensure_dirs || { _error "初始化失败: 无法确保安全目录/权限"; exit 1; }
        _geo_update
        exit $?
    fi
    # 子命令: timed-restart(cron 调用)
    if [ "${1:-}" = "timed-restart" ]; then
        INIT_SYSTEM=$(_detect_init_system)
        _ensure_dirs || { _error "初始化失败: 无法确保安全目录/权限"; exit 1; }
        _timed_restart_do
        exit $?
    fi

    _init_runtime
    _main_menu
}

main "$@"
