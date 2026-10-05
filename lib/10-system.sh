#!/bin/bash
# lib/10-system.sh — init/OS/架构探测与 apt/apk 依赖安装。

# 探测 systemd / OpenRC / direct。
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

# OS 家族探测；未知返回原 ID。
_detect_os_family() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        # 子 shell 隔离 os-release 变量，防止覆盖调用者全局。
        (
            unset ID ID_LIKE
            . /etc/os-release 2>/dev/null
            # ID 可能缺失；默认展开避免 set -u 在裁剪镜像中提前退出。
            case "${ID:-}" in
                debian|ubuntu) echo "debian" ;;
                alpine)        echo "alpine" ;;
                *)
                    # 衍生版按 ID_LIKE 归类；统一空白/逗号分隔以免漏判。
                    local _like
                    _like=$(printf '%s' "${ID_LIKE:-}" | tr ',\t' '  ')
                    case " ${_like} " in
                        *" debian "*|*" ubuntu "*) echo "debian" ;;
                        *" alpine "*)              echo "alpine" ;;
                        *) echo "${ID:-unknown}" ;;
                    esac
                    ;;
            esac
        )
    else
        echo "unknown"
    fi
}

# 架构映射：amd64 / arm64 / 386。
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

# _pkg_install <pkg1> [pkg2 ...]：统一 apt/apk 安装。
_pkg_install() {
    local fam p
    local -a pkgs=("$@")
    local pkg_label="${pkgs[*]}"
    # 保留 argv 边界并拒绝选项型包名，避免空白/glob 改变包约束。
    for p in "$@"; do
        case "$p" in
            -*) _error "非法包名(不得以 - 开头): $p"; return 1 ;;
        esac
    done
    fam=$(_detect_os_family)
    _info "安装依赖: $pkg_label"
    case "$fam" in
        alpine)
            command -v apk >/dev/null 2>&1 || { _error "apk 不可用, 无法安装: $pkg_label"; return 1; }
            apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1 || {
                _error "apk 安装失败: $pkg_label"
                return 1
            }
            ;;
        debian)
            command -v apt-get >/dev/null 2>&1 || { _error "apt-get 不可用, 无法安装: $pkg_label"; return 1; }
            # 非交互、无 recommends 并等待 apt 锁，避免卡提示和无谓占盘。
            export DEBIAN_FRONTEND=noninteractive
            # update 失败告警但继续 install；timeout 限制坏镜像阻塞。
            if command -v timeout >/dev/null 2>&1; then
                timeout 120 apt-get update -qq >/dev/null 2>&1 || _warn "apt-get update 失败或超时(继续尝试安装)"
            else
                apt-get update -qq >/dev/null 2>&1 || _warn "apt-get update 失败(继续尝试安装)"
            fi
            apt-get -o DPkg::Lock::Timeout=60 install -y -qq --no-install-recommends -- "${pkgs[@]}" >/dev/null 2>&1 || {
                _error "apt 安装失败: $pkg_label (网络/软件源/磁盘空间或 dpkg 被占用?)"
                return 1
            }
            ;;
        *)
            _error "不支持的系统: $fam,请手动安装: $pkg_label"
            return 1
            ;;
    esac
    return 0
}

# 基础依赖逐次探测、只装缺项并装后复核；返回真实成败。
_ensure_base_deps() {
    local c missing=()
    command -v curl   >/dev/null 2>&1 || missing+=(curl)
    command -v wget   >/dev/null 2>&1 || missing+=(wget)
    command -v jq     >/dev/null 2>&1 || missing+=(jq)
    command -v unzip  >/dev/null 2>&1 || missing+=(unzip)
    # tar/cron 通常自带,不强制
    if [ "${#missing[@]}" -gt 0 ]; then
        _pkg_install "${missing[@]}" || return 1
        local still=()
        for c in "${missing[@]}"; do
            command -v "$c" >/dev/null 2>&1 || still+=("$c")
        done
        if [ "${#still[@]}" -gt 0 ]; then
            _error "依赖安装后仍缺失: ${still[*]}"
            return 1
        fi
    fi
    # cron 守护(Alpine 的 busybox crond 通常已有;Debian 有 cron) — best-effort, 失败不阻断
    if ! command -v crontab >/dev/null 2>&1; then
        case "$(_detect_os_family)" in
            alpine) _pkg_install busybox-suid >/dev/null 2>&1 || _warn "crontab 安装失败, 定时任务不可用" ;;
            debian) _pkg_install cron >/dev/null 2>&1 || _warn "crontab 安装失败, 定时任务不可用"
                    # 确保 cron 服务运行
                    systemctl enable --now cron 2>/dev/null || true
                    ;;
        esac
    fi
    return 0
}
