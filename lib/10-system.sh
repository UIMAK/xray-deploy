#!/bin/bash
# =============================================================================
# lib/10-system.sh — 系统适配层
# init 系统探测(systemd/openrc) / 包管理(apt/apk) / bash 依赖(Alpine)
# ============================================================================

# ---------------------------------------------------------------------------
# 探测 init 系统:systemd / openrc / direct(兜底)
# ---------------------------------------------------------------------------
_detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        echo "systemd"
    elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ] && [ -d /run/openrc ]; then
        echo "openrc"
    elif command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        # 部分 Alpine/容器:有 rc-service 但无 /run/openrc,仍按 openrc 处理
        echo "openrc"
    else
        echo "direct"
    fi
}

# ---------------------------------------------------------------------------
# 探测系统类型(debian/ubuntu/alpine/其他)
# ---------------------------------------------------------------------------
_detect_os_family() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release 2>/dev/null
        case "$ID" in
            debian|ubuntu) echo "debian" ;;
            alpine)        echo "alpine" ;;
            *)             echo "${ID:-unknown}" ;;
        esac
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# 探测架构(amd64 / arm64 / 386)
# ---------------------------------------------------------------------------
_detect_arch() {
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        i386|i686)     echo "386" ;;
        *)             echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 包安装(统一 apt/apk 分支)
# 用法:_pkg_install <pkg1> [pkg2 ...]
# ---------------------------------------------------------------------------
_pkg_install() {
    local fam pkgs="$*"
    fam=$(_detect_os_family)
    _info "安装依赖: $pkgs"
    case "$fam" in
        alpine)
            apk add --no-cache $pkgs >/dev/null 2>&1 || {
                _error "apk 安装失败: $pkgs"
                return 1
            }
            ;;
        debian)
            # DEBIAN_FRONTEND=noninteractive 防交互卡住(时区/服务重启提示)
            # --no-install-recommends 省空间(小机器友好)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq --no-install-recommends $pkgs >/dev/null 2>&1 || {
                _error "apt 安装失败: $pkgs"
                return 1
            }
            ;;
        *)
            _error "不支持的系统: $fam,请手动安装: $pkgs"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 检查并安装基础依赖(jq curl wget unzip)
# 首次进菜单时调用
# ---------------------------------------------------------------------------
_ensure_base_deps() {
    local missing=()
    command -v curl   >/dev/null 2>&1 || missing+=(curl)
    command -v wget   >/dev/null 2>&1 || missing+=(wget)
    command -v jq     >/dev/null 2>&1 || missing+=(jq)
    command -v unzip  >/dev/null 2>&1 || missing+=(unzip)
    # tar/cron 通常自带,不强制
    if [ "${#missing[@]}" -gt 0 ]; then
        _pkg_install "${missing[@]}" || return 1
    fi
    # cron 守护(Alpine 的 busybox crond 通常已有;Debian 有 cron)
    if ! command -v crontab >/dev/null 2>&1; then
        case "$(_detect_os_family)" in
            alpine) _pkg_install busybox-suid >/dev/null 2>&1 ;;
            debian) _pkg_install cron >/dev/null 2>&1
                    # 确保 cron 服务运行
                    systemctl enable --now cron 2>/dev/null || true
                    ;;
        esac
    fi
    return 0
}
