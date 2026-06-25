#!/bin/bash
# =============================================================================
# xray-deploy.sh — Xray 部署管理脚本(主入口)
# 安装后落 /usr/local/bin/xd, 输入 xd 唤出菜单
# 支持子命令: xd geo-update, xd timed-restart (供 cron 调用)
# =============================================================================

set -u

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
# shellcheck source=lib/50-nodes.sh
. "$LIB_DIR/50-nodes.sh"
# shellcheck source=lib/51-reality-pq.sh
. "$LIB_DIR/51-reality-pq.sh"
# shellcheck source=lib/90-menu.sh
. "$LIB_DIR/90-menu.sh"

# ---------------------------------------------------------------------------
# 初始化(每次启动做轻量探测, 不重复装依赖)
# ---------------------------------------------------------------------------
_init_runtime() {
    _check_root
    INIT_SYSTEM=$(_detect_init_system)
    # 首次安装后标记存在才装依赖, 避免每次进菜单都检测
    if [ ! -f "$STATE_DIR/initialized" ]; then
        _ensure_base_deps 2>/dev/null || true
        _ensure_dirs
        _state_set initialized "1"
    fi
    _ensure_dirs
}

# ---------------------------------------------------------------------------
# 主调度
# ---------------------------------------------------------------------------
main() {
    # 子命令: geo-update(cron 调用)
    if [ "${1:-}" = "geo-update" ]; then
        _ensure_dirs
        _geo_update
        exit $?
    fi
    # 子命令: timed-restart(cron 调用)
    if [ "${1:-}" = "timed-restart" ]; then
        _ensure_dirs
        _timed_restart_do
        exit $?
    fi

    _init_runtime
    _main_menu
}

main "$@"
