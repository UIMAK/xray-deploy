#!/bin/bash
# =============================================================================
# lib/20-xray-core.sh — Xray 核心管理
# 双通道(稳定版 stable / 预览版 preview)安装与任意切换 + service 生成
# 需求 R2(路径/双系统/env) + R3(双通道切换,不缓存旧版)
# 配置与节点在切换时保持不变。
# ============================================================================

# Xray 官方 release 资产命名(已核对 GitHub API):
#   amd64 -> Xray-linux-64.zip
#   arm64 -> Xray-linux-arm64-v8a.zip
#   386   -> Xray-linux-32.zip
_xray_arch_asset() {
    case "$(_detect_arch)" in
        amd64) echo "Xray-linux-64.zip" ;;
        arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        386)   echo "Xray-linux-32.zip" ;;
        *)     echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 通过 GitHub API 取指定通道最新 release 的 tag
#   stable  : releases/latest(prerelease=false 的最新正式版)
#   preview : releases 列表里 prerelease=true 的最新一个
# 用 jq 解析(避免 busybox grep -E 对扩展正则的兼容问题); curl 失败兜底 wget
# ---------------------------------------------------------------------------
_xray_fetch_tag() {
    local channel="$1" body tag
    case "$channel" in
        stable)
            body=$(curl -sL --max-time 20 "$XRAY_REPO_API/latest" 2>/dev/null) \
                || body=$(wget -qO- --timeout=20 "$XRAY_REPO_API/latest" 2>/dev/null)
            [ -z "$body" ] && return 1
            # 优先 jq; 兜底 BRE grep(busybox 稳)
            tag=$(echo "$body" | jq -r '.tag_name // empty' 2>/dev/null)
            if [ -z "$tag" ] || [ "$tag" = "null" ]; then
                tag=$(echo "$body" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            ;;
        preview)
            body=$(curl -sL --max-time 20 "$XRAY_REPO_API?per_page=30" 2>/dev/null) \
                || body=$(wget -qO- --timeout=20 "$XRAY_REPO_API?per_page=30" 2>/dev/null)
            [ -z "$body" ] && return 1
            # 优先 jq: 第一个 prerelease==true 的 tag_name
            tag=$(echo "$body" | jq -r '[.[] | select(.prerelease == true)] | .[0].tag_name // empty' 2>/dev/null)
            # 兜底: 用 grep 找 prerelease 行, 取对应 tag_name(busybox 友好)
            if [ -z "$tag" ] || [ "$tag" = "null" ]; then
                tag=$(echo "$body" | grep '"prerelease": true' -B5 | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            ;;
        *) return 1 ;;
    esac
    [ -n "$tag" ] && [ "$tag" != "null" ] && echo "$tag" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 当前已安装版本(R3 回显用)
# ---------------------------------------------------------------------------
_xray_current_version() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# 下载并替换 Xray 二进制(不缓存旧版,直接覆盖)
# 用法:_xray_download_replace <tag>
# ---------------------------------------------------------------------------

# 低内存机器(可用内存<384MB)释放页缓存; 内存充足的机器跳过以避免性能损失
_maybe_drop_caches() {
    local avail_kb
    avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$avail_kb" ] && [[ "$avail_kb" =~ ^[0-9]+$ ]] && [ "$avail_kb" -lt 393216 ]; then
        sync 2>/dev/null || true
        { echo 1 > /proc/sys/vm/drop_caches; } 2>/dev/null || true
    fi
    return 0
}

_xray_download_replace() {
    local tag="$1"
    local asset tmp_dir tmp_zip
    asset=$(_xray_arch_asset)
    if [ -z "$asset" ]; then
        _error "不支持的架构: $(uname -m)"
        return 1
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip || return 1

    local dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
    tmp_dir=$(mktemp -d)
    tmp_zip="${tmp_dir}/xray.zip"

    _info "下载 Xray-core ${tag} (${asset})"
    if ! wget -q --show-progress -O "$tmp_zip" "$dl_url" 2>&1; then
        _error "下载失败: $dl_url"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null; then
        _error "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi
    # 立即删除 zip 文件(低内存 VPS 上 tmpfs 中的 20MB zip 是压垮骆驼的最后一根稻草)
    rm -f "$tmp_zip"
    if [ ! -f "${tmp_dir}/xray" ]; then
        _error "压缩包内未找到 xray 二进制"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 停服务 -> 备份旧二进制 -> 替换二进制 -> 校验可执行
    _manage_xray stop >/dev/null 2>&1 || true
    mkdir -p "$BIN_DIR"
    # 覆盖前备份旧二进制(校验失败可回滚, S6)
    [ -f "$XRAY_BIN" ] && cp -f "$XRAY_BIN" "$XRAY_BIN.bak"
    mv -f "${tmp_dir}/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"

    # 顺带把 release 自带的 geoip/geosite 放进 assets(若无则跳过;R4 的自动更新会覆盖)
    [ -f "${tmp_dir}/geoip.dat" ]   && cp -f "${tmp_dir}/geoip.dat"   "$ASSET_DIR/" 2>/dev/null || true
    [ -f "${tmp_dir}/geosite.dat" ] && cp -f "${tmp_dir}/geosite.dat" "$ASSET_DIR/" 2>/dev/null || true

    rm -rf "$tmp_dir"

    # 低内存机器: 下载/解压/cp 产生大量页缓存, xray version 前释放以避 OOM
    _maybe_drop_caches

    # 可执行性校验
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        _error "新二进制无法执行,可能架构不匹配"
        # 恢复旧二进制
        if [ -f "$XRAY_BIN.bak" ]; then
            mv -f "$XRAY_BIN.bak" "$XRAY_BIN"
            chmod +x "$XRAY_BIN"
            _info "已回滚到旧二进制"
        fi
        return 1
    fi
    # 校验通过, 清理备份
    rm -f "$XRAY_BIN.bak"
    # 创建 xray 命令 symlink（检测已有安装不覆盖）
    _ensure_xray_symlink
    return 0
}

# ---------------------------------------------------------------------------
# 定时重启执行体(cron 调用: xd timed-restart)
# 逻辑: xray -test → 通过则 restart → 记录日志
# ---------------------------------------------------------------------------
_timed_restart_do() {
    local log_file="$LOG_DIR/timed-restart.log"
    mkdir -p "$LOG_DIR"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ ! -x "$XRAY_BIN" ]; then
        echo "[$ts] 跳过: Xray 未安装" >> "$log_file"
        exit 0
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[$ts] 跳过: 配置文件不存在" >> "$log_file"
        exit 0
    fi
    if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "[$ts] 跳过: 配置校验失败" >> "$log_file"
        exit 0
    fi
    _manage_xray restart
    echo "[$ts] 已重启" >> "$log_file"
}

# ---------------------------------------------------------------------------
# 确保 xray 命令可用 (symlink $XRAY_BIN → /usr/local/bin/xray)
# ---------------------------------------------------------------------------
_ensure_xray_symlink() {
    local link="/usr/local/bin/xray"
    if [ ! -e "$link" ]; then
        ln -sf "$XRAY_BIN" "$link"
    elif [ "$(readlink -f "$link" 2>/dev/null)" = "$XRAY_BIN" ]; then
        :  # 已是我们的 symlink, 跳过
    else
        _tip "检测到已有 xray 命令 ($(readlink -f "$link" 2>/dev/null || echo "$link")), 跳过 symlink 创建"
    fi
}

# ---------------------------------------------------------------------------
# 安装或切换 Xray 核心(R3)
# 用法:_install_or_switch_xray <channel>
#   未安装 -> 安装该通道最新版
#   已安装 -> 切换到该通道最新版(配置与节点不动)
# ---------------------------------------------------------------------------
_install_or_switch_xray() {
    local channel="$1"
    case "$channel" in
        stable|preview) ;;
        *) _error "未知通道: $channel"; return 1 ;;
    esac

    _ensure_dirs
    local tag
    tag=$(_xray_fetch_tag "$channel") || {
        _error "无法获取 ${channel} 通道最新版本(网络?)"
        return 1
    }
    _info "${channel} 通道最新版本: ${tag}"

    local cur=""
    cur=$(_xray_current_version 2>/dev/null)
    local cur_tag="v${cur}"
    if [ -n "$cur" ] && [ "$cur_tag" = "$tag" ]; then
        _info "当前已是该版本 (v${cur}),仍重新下载替换以确保最新"
    fi

    # 备份配置(切换不动配置,但写前留快照以防万一)
    _backup_config

    if ! _xray_download_replace "$tag"; then
        # 下载失败:若有旧二进制,尝试恢复服务
        if [ -x "$XRAY_BIN" ]; then
            _warn "切换失败,保留当前二进制 v${cur}"
            _manage_xray start >/dev/null 2>&1 || true
        fi
        return 1
    fi

    # 确保配置与 service 存在(首次安装)
    _init_config_if_empty
    _create_xray_service

    # 校验配置后启动
    if [ -f "$CONFIG_FILE" ]; then
        if ! _xray_test_config; then
            _warn "配置校验未通过,服务暂不启动(配置已保留)"
            _restore_config 2>/dev/null
            _xray_test_config && _manage_xray start
        else
            _manage_xray restart
        fi
    else
        _manage_xray start
    fi

    # 记录状态
    _state_set channel "$channel"
    _state_set version "$(_xray_current_version)"

    local newv
    newv=$(_xray_current_version)
    _success "Xray-core 已切换到 v${newv} (${channel})"
    _tip "配置与节点保持不变"

    # 首次安装/切换后自动配置 logrotate(幂等)
    if declare -F _logrotate_setup >/dev/null 2>&1; then
        _logrotate_setup
    fi

    return 0
}

# ---------------------------------------------------------------------------
# 配置文件初始化(空 inbounds + freedom/blackhole + log)
# 仅在 config.json 不存在或为空时写
# ---------------------------------------------------------------------------
_init_config_if_empty() {
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        return 0
    fi
    _ensure_dirs
    # 美化多行格式(便于手动编辑) + routing 规则(bt/广告/私网/CN 走 block)
    # 按 Xray 官方文档顺序排列(log → dns → routing → inbounds → outbounds)
    local base='{
  "log": {
    "loglevel": "warning",
    "access": "'"$LOG_DIR"'/access.log",
    "error": "'"$LOG_DIR"'/error.log"
  },
  "dns": {
    "enableParallelQuery": true,
    "queryStrategy": "UseIP",
    "servers": [
      {
        "address": "https+local://cloudflare-dns.com/dns-query",
        "tag": "dns_cloudflare"
      },
      {
        "address": "https+local://dns11.quad9.net/dns-query",
        "tag": "dns_quad9"
      },
      {
        "address": "https+local://dns.google/dns-query",
        "tag": "dns_google"
      }
    ],
    "tag": "dns_inbound",
    "useSystemHosts": false
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "geosite:category-ads-all",
          "geosite:private"
        ],
        "outboundTag": "block"
      },
      {
        "ip": [
          "geoip:private",
          "geoip:cn"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "pypi.org",
          "unpkg.com",
          "github.com",
          "nodejs.org",
          "kali.download",
          "www.apple.com",
          "deb.debian.org",
          "mail.google.com",
          "pypi.python.org",
          "ssl.gstatic.com",
          "www.gstatic.com",
          "dockerstatic.com",
          "cp.cloudflare.com",
          "fonts.gstatic.com",
          "registry.npmjs.org",
          "archive.debian.org",
          "archive.ubuntu.com",
          "cdnjs.cloudflare.com",
          "security.ubuntu.com",
          "security.debian.org",
          "www.msftconnecttest.com",
          "old-releases.ubuntu.com",
          "raw.githubusercontent.com",
          "objects.githubusercontent.com",
          "geosite:golang",
          "regexp:^(mt|khm)\\d?\\.google\\.com$",
          "regexp:(gstatic|fonts|dl|ajax)\\.google(apis)?\\.com$"
        ],
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}'
    _atomic_write_json "$CONFIG_FILE" "$base" || return 1
    # 再用 jq 美化一遍(确保格式规范)
    if command -v jq >/dev/null 2>&1; then
        jq . "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null && mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
    _info "已初始化空配置: $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# 配置校验:xray -test
# ---------------------------------------------------------------------------
_xray_test_config() {
    [ -x "$XRAY_BIN" ] || return 1
    # 低内存机器: xray -test 加载完整二进制+geo,预先释放页缓存
    _maybe_drop_caches
    # 子shell 抑制 bash 的 "Killed" 信号噪音(OOM 场景)
    ( XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" -test -config "$CONFIG_FILE" ) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 生成 service 文件(R2:注入 XRAY_LOCATION_ASSET=/opt/xray-deploy/assets)
# ---------------------------------------------------------------------------
_create_xray_systemd_service() {
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (xray-deploy)
After=network.target nss-lookup.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${ASSET_DIR}
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray 2>/dev/null
}

_create_xray_openrc_service() {
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run

name="Xray Daemon"
description="A unified platform for anti-censorship (xray-deploy)"

supervisor=supervise-daemon
respawn_delay=5
respawn_max=2
respawn_period=600

pidfile="/run/\${RC_SVCNAME}.pid"
rc_ulimit="-n 1024000 -u 1024000"
capabilities="^cap_net_bind_service,^cap_net_admin,^cap_net_raw"
extra_commands="checkconfig"
supervise_daemon_args="--env XRAY_LOCATION_ASSET=${ASSET_DIR}"

command="${XRAY_BIN}"
command_user="nobody:nobody"
command_args="run -c ${CONFIG_FILE}"
required_files="${CONFIG_FILE}"

depend() {
    need net
    want dns ntp-client
    after firewall
}

checkconfig() {
    ebegin "Checking Xray configuration"
    export XRAY_LOCATION_ASSET="${ASSET_DIR}"
    "${XRAY_BIN}" run -c "${CONFIG_FILE}" -test
    eend \$?
}

start_pre() {
    checkconfig || return 1
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default 2>/dev/null
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_xray_systemd_service ;;
        openrc)  _create_xray_openrc_service ;;
        direct)
            # 无 init 系统:不做 service,提示手动运行
            _warn "未检测到 systemd/openrc,跳过 service 创建(可手动: XRAY_LOCATION_ASSET=${ASSET_DIR} ${XRAY_BIN} run -c ${CONFIG_FILE})"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 服务管理:start/stop/restart/status
# ---------------------------------------------------------------------------
_manage_xray() {
    local action="$1"
    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start)   systemctl start xray 2>/dev/null ;;
                stop)    systemctl stop xray 2>/dev/null ;;
                restart) systemctl restart xray 2>/dev/null ;;
                status)  [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && echo "running" || echo "stopped" ;;
            esac
            ;;
        openrc)
            case "$action" in
                start)   rc-service xray start 2>/dev/null ;;
                stop)    rc-service xray stop 2>/dev/null ;;
                restart) rc-service xray restart 2>/dev/null ;;
                status)  rc-service xray status 2>/dev/null | grep -q started && echo "running" || echo "stopped" ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    if [ -f /run/xray.pid ] && kill -0 "$(cat /run/xray.pid 2>/dev/null)" 2>/dev/null; then
                        echo "running"
                    else
                        XRAY_LOCATION_ASSET="$ASSET_DIR" nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
                        echo $! > /run/xray.pid
                    fi
                    ;;
                stop)    [ -f /run/xray.pid ] && kill "$(cat /run/xray.pid)" 2>/dev/null; rm -f /run/xray.pid ;;
                restart) _manage_xray stop; sleep 1; _manage_xray start ;;
                status)  [ -f /run/xray.pid ] && kill -0 "$(cat /run/xray.pid 2>/dev/null)" 2>/dev/null && echo "running" || echo "stopped" ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 卸载 Xray(停服务 + 删 service + 删部署目录 + 清快捷命令 + 清 crontab)
# ---------------------------------------------------------------------------
_uninstall_xray() {
    _manage_xray stop 2>/dev/null || true
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable xray 2>/dev/null
            rm -f /etc/systemd/system/xray.service
            systemctl daemon-reload 2>/dev/null
            ;;
        openrc)
            rc-update del xray default 2>/dev/null
            rm -f /etc/init.d/xray
            ;;
    esac
    # 清 crontab 的 geo 自动更新任务 + 定时重启任务
    crontab -l 2>/dev/null | grep -v "$GEO_CRON_MARKER" 2>/dev/null | grep -v "# xray-deploy-timed-restart" 2>/dev/null | crontab - 2>/dev/null || true
    # 删快捷命令(xd) + xray symlink
    rm -f /usr/local/bin/"$CMD_NAME"
    [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$XRAY_BIN" ] && rm -f /usr/local/bin/xray
    # 清理端口跳跃 iptables 规则(必须在删除部署目录之前)
    if declare -F _hy2_cleanup_all_hops >/dev/null 2>&1; then
        _hy2_cleanup_all_hops
    fi
    # 清理 logrotate 配置
    if declare -F _logrotate_cleanup >/dev/null 2>&1; then
        _logrotate_cleanup
    fi
    # 删部署目录(含 config/nodes/assets/logs/state/lib/templates)
    rm -rf "$DEPLOY_DIR"
    _success "Xray 已卸载干净(/opt/xray-deploy、xd 命令、geo crontab 已清除)"
}

# ---------------------------------------------------------------------------
# 核心管理菜单入口(R3:安装/更新或切换)
# ---------------------------------------------------------------------------
_xray_core_menu() {
    clear
    local cur="" cur_channel=""
    cur=$(_xray_current_version 2>/dev/null)
    cur_channel=$(_state_get channel 2>/dev/null)
    [ -z "$cur_channel" ] && cur_channel="未设置"

    echo
    echo -e "  ${CYAN}【Xray 核心管理】${NC}"
    if [ -n "$cur" ]; then
        echo -e "  当前版本: ${GREEN}v${cur}${NC}  通道: ${CYAN}${cur_channel}${NC}"
        echo -e "  ${YELLOW}已安装 → 选择通道将切换到该通道最新版(配置与节点不变)${NC}"
    else
        echo -e "  当前版本: ${RED}未安装${NC}"
        echo -e "  ${YELLOW}选择通道将安装该通道最新版${NC}"
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 稳定版(stable)"
    echo -e "  ${GREEN}[2]${NC} 预览版(preview)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    echo
    read -rp "  请选择: " choice
    case "$choice" in
        1) _install_or_switch_xray stable ;;
        2) _install_or_switch_xray preview ;;
        0) return ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
}
