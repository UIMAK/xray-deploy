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
        # shellcheck disable=SC1091
        # R38(M2): 用子 shell 隔离 —— `. /etc/os-release` 会把 ID/NAME/VERSION/PRETTY_NAME
        # 等 20+ 个大写变量注入调用者作用域。当前 4 个调用点都是命令替换(污染限于子 shell),
        # 但函数本身没有任何防护, 一次裸调用就会静默覆盖同名变量。
        (
            . /etc/os-release 2>/dev/null
            # R38(M2): 必须用 ${ID:-} —— 入口有 set -u, 而部分裁剪镜像/自制 rootfs 的
            # os-release 只写 NAME/PRETTY_NAME 而没有 ID=; 裸 "$ID" 会让子 shell 以
            # "ID: unbound variable" 直接退出, 下面 ${ID:-unknown} 的兜底永远到不了,
            # 调用方拿到空串并报"不支持的系统"。
            case "${ID:-}" in
                debian|ubuntu) echo "debian" ;;
                alpine)        echo "alpine" ;;
                *)
                    # 衍生版(Mint/Kali/Raspbian/Devuan/Pop!_OS 等)通过 ID_LIKE 归类
                    # R38(M2): 同时覆盖 alpine 系衍生版(postmarketOS 等), 否则它们会落到
                    # echo "$ID" 而被 _pkg_install 判为"不支持的系统"。
                    # ID_LIKE 的官方格式是空格分隔, 但实际发行版也出现过逗号/制表符分隔
                    # (如 ID_LIKE=debian,ubuntu)。先归一化分隔符, 否则这类衍生版会掉进
                    # 兜底分支被误判为"不支持的系统"。
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
    local fam pkgs="$*" p
    # 选项注入防护: $pkgs 故意不加引号(需要按空白拆成多参数), 于是以 "-" 开头的名字会被
    # apt/apk 当成选项(如 --assume-yes)。调用方目前都传字面量, 但这是公共 helper
    # (50-nodes/20-xray-core/45-logrotate 都在用), 故在入口拒绝。
    for p in "$@"; do
        case "$p" in
            -*) _error "非法包名(不得以 - 开头): $p"; return 1 ;;
        esac
    done
    fam=$(_detect_os_family)
    _info "安装依赖: $pkgs"
    case "$fam" in
        alpine)
            command -v apk >/dev/null 2>&1 || { _error "apk 不可用, 无法安装: $pkgs"; return 1; }
            apk add --no-cache $pkgs >/dev/null 2>&1 || {
                _error "apk 安装失败: $pkgs"
                return 1
            }
            ;;
        debian)
            command -v apt-get >/dev/null 2>&1 || { _error "apt-get 不可用, 无法安装: $pkgs"; return 1; }
            # DEBIAN_FRONTEND=noninteractive 防交互卡住(时区/服务重启提示)
            # --no-install-recommends 省空间(小机器友好)
            # DPkg::Lock::Timeout: 另一个 apt/unattended-upgrades 持锁时等待而非立即失败
            #   (旧行为只报一句无信息的"apt 安装失败"); -- 终止选项解析(双保险)。
            export DEBIAN_FRONTEND=noninteractive
            # update 失败/超时不再被无视: 无网络或源坏时 install 必然失败, 这里先给出原因;
            # 加 timeout 避免挂死的镜像源永久阻塞启动。
            if command -v timeout >/dev/null 2>&1; then
                timeout 120 apt-get update -qq >/dev/null 2>&1 || _warn "apt-get update 失败或超时(继续尝试安装)"
            else
                apt-get update -qq >/dev/null 2>&1 || _warn "apt-get update 失败(继续尝试安装)"
            fi
            apt-get -o DPkg::Lock::Timeout=60 install -y -qq --no-install-recommends -- $pkgs >/dev/null 2>&1 || {
                _error "apt 安装失败: $pkgs (网络/软件源/磁盘空间或 dpkg 被占用?)"
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
# 每次启动轻量探测(command -v), 仅缺依赖时安装; 安装后复核, 返回真实成败
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
