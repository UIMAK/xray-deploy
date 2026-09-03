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
            body=$(curl -fsSL --max-time 20 "$XRAY_REPO_API/latest" 2>/dev/null) \
                || body=$(wget -q -T 20 -O- "$XRAY_REPO_API/latest" 2>/dev/null)
            [ -z "$body" ] && return 1
            # 优先 jq; 兜底 BRE grep(busybox 稳)
            tag=$(echo "$body" | jq -r '.tag_name // empty' 2>/dev/null)
            if [ -z "$tag" ] || [ "$tag" = "null" ]; then
                tag=$(echo "$body" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            ;;
        preview)
            body=$(curl -sL --max-time 20 "$XRAY_REPO_API?per_page=30" 2>/dev/null) \
                || body=$(wget -q -T 20 -O- "$XRAY_REPO_API?per_page=30" 2>/dev/null)
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

_xray_cached_version() {
    local ver=""
    ver=$(_state_get version 2>/dev/null)
    if [ -z "$ver" ]; then
        ver=$(_xray_current_version 2>/dev/null)
        [ -n "$ver" ] && _state_set version "$ver" 2>/dev/null || true
    fi
    [ -n "$ver" ] && echo "$ver"
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
    # curl 优先 + 可移植 wget 兜底(原 wget --show-progress 在 busybox 上直接失败)
    if ! _http_download "$dl_url" "$tmp_zip" 120; then
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
    # 覆盖前备份旧二进制(校验失败/运行期不稳定可回滚)。备份必须真正成功才允许替换:
    # 磁盘满/IO 错误导致 cp 失败时, 若继续 mv 会让旧二进制无 .bak 可回滚(与 Geo 备份同一事务原则)。
    if [ -f "$XRAY_BIN" ]; then
        if ! cp -f "$XRAY_BIN" "$XRAY_BIN.bak"; then
            _error "旧二进制备份失败(磁盘空间/IO?), 取消替换, 保留旧版本"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    # 替换必须真正成功: mv 失败(磁盘满/IO/只读)时旧二进制仍在原位, 若放行则后续 "$XRAY_BIN"
    # version 校验通过的是"旧版本", 会被误当成升级成功、甚至删除 .bak。故失败立即中止。
    if ! mv -f "${tmp_dir}/xray" "$XRAY_BIN"; then
        _error "新二进制替换失败(磁盘空间/IO/只读?), 保留旧版本"
        rm -f "$XRAY_BIN.bak" 2>/dev/null   # 旧二进制仍在原位, 无需保留多余备份
        rm -rf "$tmp_dir"
        return 1
    fi
    # 执行位必须真正设置成功, 否则新二进制不可执行, 后续 version 校验/启动都会失败
    if ! chmod +x "$XRAY_BIN" 2>/dev/null; then
        _error "新二进制设置执行权限失败, 回滚旧版本"
        if [ -f "$XRAY_BIN.bak" ]; then
            mv -f "$XRAY_BIN.bak" "$XRAY_BIN" 2>/dev/null
            chmod +x "$XRAY_BIN" 2>/dev/null
        fi
        rm -rf "$tmp_dir"
        return 1
    fi

    # 顺带把 release 自带的 geoip/geosite 放进 assets(若无则跳过;R4 的自动更新会覆盖)
    [ -f "${tmp_dir}/geoip.dat" ]   && cp -f "${tmp_dir}/geoip.dat"   "$ASSET_DIR/" 2>/dev/null || true
    [ -f "${tmp_dir}/geosite.dat" ] && cp -f "${tmp_dir}/geosite.dat" "$ASSET_DIR/" 2>/dev/null || true

    rm -rf "$tmp_dir"

    # 低内存机器: 下载/解压/cp 产生大量页缓存, xray version 前释放以避 OOM
    _maybe_drop_caches

    # 可执行性校验(仅证明二进制能跑, 不代表能稳定承载当前配置)
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        _error "新二进制无法执行,可能架构不匹配"
        # 恢复旧二进制(mv 失败时旧二进制仍原位, 显式提示而非静默)
        if [ -f "$XRAY_BIN.bak" ]; then
            if mv -f "$XRAY_BIN.bak" "$XRAY_BIN"; then
                chmod +x "$XRAY_BIN"
                _info "已回滚到旧二进制"
            else
                _warn "旧二进制回滚失败, 请手动检查 $XRAY_BIN"
            fi
        fi
        return 1
    fi
    # 注意: 此处先不删 $XRAY_BIN.bak —— 二进制 version 成功但可能与当前配置不兼容,
    # 交由调用方 _install_or_switch_xray 在 verified-restart 成功后才删除、失败则回滚。
    # 创建 xray 命令 symlink（检测已有安装不覆盖）
    _ensure_xray_symlink
    return 0
}

# ---------------------------------------------------------------------------
# 定时重启执行体(cron 调用: xd timed-restart)
# 逻辑: 基础文件检查 → restart → 记录日志
# 注意: 低内存机器上 cron 维护路径不预跑 xray -test, 避免额外加载二进制+geo
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
    # 重启后做稳定存活确认(不跑 xray -test, 避免低内存双份加载 OOM), 如实记录成败
    if _restart_xray_verified; then
        echo "[$ts] 已重启并稳定运行" >> "$log_file"
    else
        echo "[$ts] 重启失败: xray 未稳定运行, 请检查配置/日志" >> "$log_file"
        exit 1
    fi
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

    _ensure_dirs || return 1
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

    # 备份配置(切换不动配置,但写前留快照以防万一)。备份失败则中止, 保持"备份→替换→验证→回滚"事务链闭合。
    if ! _backup_config; then
        _error "配置备份失败, 取消核心切换"
        return 1
    fi

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

    # 重启并确认"稳定运行"而非仅命令返回 0(systemd Type=simple 在进程崩溃前即返回 0)。
    # 不在此处跑 xray -test(低内存 OOM); verified-restart 会完整观察 8s。
    local started_ok=1
    _restart_xray_verified || started_ok=0

    # 记录状态。注意 cur 是"替换前"探测(用于上面的版本提示/回滚文案), 这里 newv 是
    # "替换后"只探测一次(旧代码替换后还连探两次: _state_set 内一次 + newv 一次, 已合并)。
    local newv
    newv=$(_xray_current_version 2>/dev/null)
    _state_set channel "$channel" || _warn "状态持久化失败(channel)"

    if [ "$started_ok" -ne 1 ]; then
        # 新二进制可执行但无法稳定运行(如当前配置与新版本不兼容): 回滚到替换前的旧二进制并重新拉起,
        # 与 config/geo 的失败回滚保持同一事务级别。首次安装无 .bak 时只报错。
        # R38(M1): version 状态必须反映"磁盘上实际的那个二进制"。原实现在这段之前就无条件
        # _state_set version "$newv", 回滚到旧二进制后 state 里仍是新版本, 而菜单
        # (_xray_cached_version)优先读 state, 于是版本显示与现实长期不一致。
        local rolled_back=0
        if [ -f "$XRAY_BIN.bak" ]; then
            if mv -f "$XRAY_BIN.bak" "$XRAY_BIN"; then
                chmod +x "$XRAY_BIN"
                _manage_xray restart >/dev/null 2>&1 || _manage_xray start >/dev/null 2>&1 || true
                rolled_back=1
                _warn "新核心 v${newv:-?} 未能稳定运行, 已回滚到旧二进制 v${cur:-?}"
            else
                _error "旧二进制回滚失败, 请手动处理 $XRAY_BIN"
            fi
        fi
        # 回滚成功 → state 记旧版本; 回滚失败/首次安装 → 磁盘上是新二进制, 记新版本
        local recv
        recv=$(_xray_current_version 2>/dev/null)
        [ -n "$recv" ] || { [ "$rolled_back" -eq 1 ] && recv="$cur" || recv="$newv"; }
        [ -n "$recv" ] && { _state_set version "$recv" || _warn "状态持久化失败(version)"; }
        _error "Xray 二进制已替换, 但服务未能稳定运行, 请检查配置"
        return 1
    fi
    if [ -n "$newv" ]; then
        _state_set version "$newv" || _warn "状态持久化失败(version)"
    fi
    # verified 稳定运行后才丢弃旧二进制备份
    rm -f "$XRAY_BIN.bak"
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
    _ensure_dirs || return 1
    # 美化多行格式(便于手动编辑) + routing 规则(bt/广告/私网/CN 走 block)
    # 按 Xray 官方文档顺序排列(log → dns → routing → inbounds → outbounds)
    # routing.rules 先留空占位, 下面由 XRAY_DEFAULT_ROUTING_RULES_JSON 注入 ——
    # 默认规则集是唯一真相(00-common), [9] 路由规则的"恢复默认"复用同一常量, 不允许两处硬编码。
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
        "address": "https+local://dns.quad9.net/dns-query",
        "tag": "dns_quad9"
      },
      {
        "address": "https+local://freedns.controld.com/p0",
        "tag": "dns_controld"
      }
    ],
    "tag": "dns_inbound",
    "useSystemHosts": false
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": []
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
    # 注入默认规则。jq 不可用/失败时不能落地"没有 routing 规则"的半份配置 —— 那会让
    # 首次安装的机器悄悄失去 BT/广告/私网拦截, 故显式失败由调用方处理。
    local content
    content=$(jq --argjson r "$XRAY_DEFAULT_ROUTING_RULES_JSON" '.routing.rules = $r' <<< "$base") || {
        _error "生成默认配置失败(jq 不可用?), 未写入 $CONFIG_FILE"
        return 1
    }
    [ -n "$content" ] || { _error "生成默认配置为空, 未写入 $CONFIG_FILE"; return 1; }
    _atomic_write_json "$CONFIG_FILE" "$content" || return 1
    # jq 输出即 2 空格缩进且 _atomic_write_json 已做 jq 校验, 不再做第二遍 jq 写回
    # (旧的 "jq . > tmp && mv" 路径无错误处理, 失败会静默继续且可能残留 .tmp, R13)
    _info "已初始化空配置: $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# 读取当前日志级别(log.loglevel)
# 真相源只有 config.json —— 不另存 state 键(项目有 service/config/state 分裂的历史教训)。
# 读不到时输出 "warning": 与核心行为一致(infra/conf/log.go 的 default 分支对未识别/缺失
# 值一律按 warning 处理), 且下游 case 分支不会因空串落到"非法值"。
# ---------------------------------------------------------------------------
_xray_loglevel_get() {
    local lv=""
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        lv=$(jq -r '.log.loglevel // empty' "$CONFIG_FILE" 2>/dev/null) || lv=""
    fi
    # 配置里存着非法值(手工编辑)时也回显 warning —— 核心就是这么解释它的
    _xray_loglevel_valid "$lv" || lv="warning"
    printf '%s' "$lv"
}

# 日志级别是否合法(XRAY_LOG_LEVELS 白名单, 定义在 00-common)
# `${XRAY_LOG_LEVELS:-}` 的 `:-` 不可省: 本函数被 _xray_loglevel_get 调用, 而后者又被
# _logrotate_status / _view_log 这类**只读展示**路径调用。VPS 上存在"主脚本已更新但
# 00-common 仍是旧版"的混装状态(CLAUDE.md 记录过多次), 裸引用会让 set -u 在打开菜单
# 时就崩掉 —— 给只读路径引入了新的崩溃点。白名单为空时一律判非法, 回显退化为 warning。
_xray_loglevel_valid() {
    local want="${1:-}" lv
    [ -n "$want" ] || return 1
    for lv in ${XRAY_LOG_LEVELS:-}; do
        [ "$want" = "$lv" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 配置校验:xray -test
# ---------------------------------------------------------------------------
_xray_test_config() {
    [ -x "$XRAY_BIN" ] || return 1
    # 低内存机器: xray -test 加载完整二进制+geo,预先释放页缓存
    _maybe_drop_caches
    # 直接运行,保留完整输出供用户查看
    XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" -test -config "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# 计算可安全抬升的 nofile。目标 65535; 但在受限容器里若当前 hard 上限更低, 把限制
# 抬到上限之上会 EPERM, 导致 systemd/openrc 在 exec 前中止(H2 同类)。
# R38(M2): hard < 65535 时不能输出空串 —— 那样 systemd unit 里就不写 LimitNOFILE,
# 服务会落到 systemd 的 DefaultLimitNOFILE(soft 1024), 比改动前的 65535 低两个数量级,
# 代理进程很容易 "too many open files"。改为"能抬到 65535 就抬, 否则抬到探测到的
# hard 上限", 既不触发 EPERM, 也不会静默降到 1024。
# 已知局限: 这里读的是**管理脚本自己**的 /proc/self/limits; systemd 给服务设的限制来自
# DefaultLimitNOFILE, 且 PID1 通常有 CAP_SYS_RESOURCE 能抬到系统 hard 之上, 因此这个
# 探测对 systemd 只是保守下界。openrc 侧(rc_ulimit 由与本脚本同环境的 supervise-daemon
# 执行)判据是准确的。
# ---------------------------------------------------------------------------
_safe_nofile() {
    local target=65535 hard="" f
    local IFS=$' \t\n'   # 防止上层遗留的自定义 IFS 影响 read 分词
    # 直接读 /proc/self/limits(无 fork): 低配饱和 VPS 上 $(ulimit -Hn) 命令替换可能因
    # fork 失败返回空。行形如 "Max open files  <soft>  <hard>  files"。
    if [ -r /proc/self/limits ]; then
        while read -ra f; do
            if [ "${f[0]} ${f[1]} ${f[2]}" = "Max open files" ]; then hard="${f[4]}"; fi
        done < /proc/self/limits
    else
        hard=$(ulimit -Hn 2>/dev/null)
    fi
    if [ "$hard" = "unlimited" ]; then echo "$target"; return; fi
    if [[ "$hard" =~ ^[0-9]+$ ]]; then
        if [ "$hard" -ge "$target" ]; then
            echo "$target"
        else
            # 数字但 < target: 抬到 hard 上限本身(等于当前上限, 不会 EPERM), 绝不留空
            echo "$hard"
        fi
        return
    fi
    # 读不到/异常: 输出空(不设置, 继承默认), 这是唯一无法判断的情况
}

# ---------------------------------------------------------------------------
# 生成 service 文件(R2:注入 XRAY_LOCATION_ASSET=/opt/xray-deploy/assets)
# ---------------------------------------------------------------------------
_create_xray_systemd_service() {
    local nofile_line=""
    local _nf; _nf=$(_safe_nofile)
    [ -n "$_nf" ] && nofile_line="LimitNOFILE=$_nf"
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (xray-deploy)
Wants=network-online.target
After=network-online.target nss-lookup.target
# 宽松但有限的崩溃熔断: 10 分钟内允许 20 次重启(足够吸收低配机偶发 OOM, 不会像默认
# 10s/5 次那样几次 OOM 就永久停服), 但坏配置导致的紧密崩溃循环到上限后仍会停下,
# 避免无限重启空耗 CPU/日志(与 OpenRC supervise-daemon 有限 respawn 的策略对齐)。
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${ASSET_DIR}
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
${nofile_line}

[Install]
WantedBy=multi-user.target
EOF
    # R38(M14): umask 077 会让 unit 文件生成为 0600, systemd 会记 "marked
    # world-inaccessible" 告警。unit 不含机密(token 在 cloudflared 侧, 且那本就是既有形态),
    # 显式给 644 以符合系统集成惯例。
    chmod 644 /etc/systemd/system/xray.service 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable xray 2>/dev/null
}

_create_xray_openrc_service() {
    local rc_ulimit_line=""
    local _nf; _nf=$(_safe_nofile)
    # 抬到"目标 65535 或当前 hard 上限"(见 _safe_nofile); 只有完全探测不到时才留空
    [ -n "$_nf" ] && rc_ulimit_line="rc_ulimit=\"-n $_nf\""
    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run

name="Xray Daemon"
description="A unified platform for anti-censorship (xray-deploy)"

supervisor=supervise-daemon
respawn_delay=5

pidfile="/run/\${RC_SVCNAME}.pid"
# nofile 抬到 65535, 若当前 hard 上限更低则抬到该上限(见 _safe_nofile); 完全探测不到时此行为空。
# 不要写 -u(nproc), 也不要写超过容器上限的值: 抬升超限会 EPERM, OpenRC 在 exec 前
# 即中止, xray 子进程根本不会启动。
${rc_ulimit_line}
# 不静态设置 capabilities: supervise-daemon 裁剪 bounding set 的 prctl 在受限容器内会
# EPERM 并中止启动; 且 iptables 由管理脚本以 root 执行, xray 进程运行期不需要 NET_ADMIN/RAW。
supervise_daemon_args="--env XRAY_LOCATION_ASSET=${ASSET_DIR}"

command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
required_files="${CONFIG_FILE}"

depend() {
    need net
    want dns ntp-client
    after firewall
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
# 真实判断 xray 业务进程是否存活(跨 systemd/openrc/direct 与容器环境)
# 坑1: openrc supervise-daemon 的 pidfile 记录的是 supervisor 自身 PID, 子进程崩溃循环/
#       放弃重生时 supervisor 仍存活 -> kill -0 pidfile 会假阳性"running"。
# 坑2: 部分 LXC/Podman 容器内 busybox 的 pidof / pgrep -x 按名精确匹配会假阴性
#       (实测连运行中的 sshd 都匹配不到), 只有直接读 /proc/<pid>/comm 可靠。
# R38(M3): 只按 comm 全机扫描还有第三个坑 —— 会把**别的** xray 安装(x-ui/3x-ui 迁移残留、
#       用户手动跑的实例)也算成"我们的服务在跑", 于是本脚本的 unit 起不来也判 running,
#       _restart_xray_verified 恒成功。故判活优先绑定到本 service 的进程树:
#         systemd: MainPID(权威, unit 自己的主进程)
#         openrc : pidfile(supervisor pid) → 回溯 ppid 链找 comm==xray 的子进程
#         direct : 我们自己 nohup 的 pidfile
#       三者都拿不到 anchor 时才回退到全机扫描(见下方 R40 的收紧)。
# R40: 上面的 anchor 判定原本只被 openrc/direct 的 status 使用, systemd 的 status 走的是
#       裸 `systemctl is-active`, 于是"统一真实判活"实际只统一了 2/3 分支。is-active 只回答
#       "unit 处于 active 状态", 不回答"主进程还活着": Type=simple 下 systemd 把 fork 成功
#       即视为 active, 主进程被 OOM/崩溃杀掉后到 systemd 收割 SIGCHLD、把 unit 迁出 active
#       之间存在窗口, 该窗口内 is-active=active 而 MainPID 已是死 pid ——
#       _restart_xray_verified 的 8 次采样正好可能全落在窗口里判成功, 坏配置被当成写入成功。
#       现在三个分支一律走 _xray_is_running。
# R40: 同时收紧两侧的误判方向, 因为"更严"和"更宽"在这里是两种不同的事故:
#   1) systemd 分支不再落到"任何同名进程都算"的全机扫描。unit 已知(LoadState 可读)时
#      MainPID 就是权威, MainPID=0 即 stopped; LoadState=not-found 直接判 stopped
#      (systemd 分支从不自己 nohup 起进程, unit 不存在就不可能有我们的服务在跑);
#      只有 LoadState 读不到(容器内 systemctl 不可用 / systemd <230 无 --value)时才退化为
#      "is-active 且确有本脚本二进制在跑"的双条件。若这里裸回退全机扫描, 宿主上别人的
#      xray(x-ui/3x-ui 残留、手跑实例)会把"我们的 unit 起不来"说成 running —— 比原来更糟。
#   2) openrc/direct 分支在 anchor 判定失败后, 追加一次"限定为本脚本二进制"的扫描再定论。
#      anchor 路径依赖 supervise-daemon→xray 的 ppid 拓扑, 一旦拓扑不符合预期(中间多一层
#      包装、supervisor 重新挂载子进程), 健康服务会被判 stopped, 而 _manage_xray
#      start/restart 正是以 `_xray_is_running 为假` 作为 `rc-service zap` 的前提 ——
#      对活着的服务 zap 会让 OpenRC 记为 stopped 却不杀进程, 随后再起一个实例 → 端口冲突。
#      假阴性在这条路上比假阳性危险, 故补一层按 exe 归属的兜底(见 _proc_exe_is)。
# ---------------------------------------------------------------------------
_xray_is_running() {
    local anchor="" load=""
    case "$INIT_SYSTEM" in
        systemd)
            load=$(systemctl show -p LoadState --value xray 2>/dev/null)
            case "$load" in
                not-found)
                    # unit 不存在 => 本脚本管理的服务不可能在跑(systemd 分支从不 nohup 起进程)
                    return 1 ;;
                "")
                    # systemctl 不可用, 或 systemd < 230 不支持 --value: 退化为
                    # "unit active 且确有我们自己的二进制在跑" 双条件, 比任一单条件都严。
                    systemctl is-active --quiet xray 2>/dev/null || return 1
                    ;;
                *)
                    # unit 已知: MainPID 权威, 不回退全机扫描
                    anchor=$(systemctl show -p MainPID --value xray 2>/dev/null)
                    [[ "$anchor" =~ ^[0-9]+$ ]] || return 1
                    [ "$anchor" != "0" ] || return 1
                    _proc_named_under "$anchor" xray && return 0
                    return 1 ;;
            esac
            ;;
        openrc|direct)
            anchor=$(cat /run/xray.pid 2>/dev/null)
            if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" xray && return 0
                # 不直接判死: 见上方 R40(2), 继续按 exe 归属兜底
            fi
            ;;
    esac
    # 兜底: 全机扫描 comm==xray, 但只承认 exe 指向本脚本自己的二进制的进程,
    # 从而仍能排除宿主上别人的 xray 实例(exe 读不到时放行, 见 _proc_exe_is)。
    _proc_any_named xray "$XRAY_BIN"
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
                # R40: 与 openrc/direct 一致地走 _xray_is_running(绑定到 unit MainPID 的
                # 真实主进程), 不再用裸 is-active —— 后者在主进程已死、systemd 尚未把 unit
                # 迁出 active 的窗口内会报 running(详见 _xray_is_running 注释)。
                status)  if _xray_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
        openrc)
            case "$action" in
                # supervise-daemon 崩溃次数耗尽(respawn-max)后进入 crashed 态, 直接 start/restart
                # 会被拒; 仅在"确无真实 xray 业务进程"时 zap 复位状态机(健康运行时绝不 zap,
                # 否则 OpenRC 误判 stopped 会再起一个实例造成端口冲突)。
                start)
                    _xray_is_running || rc-service xray zap >/dev/null 2>&1
                    rc-service xray start 2>/dev/null ;;
                stop)    rc-service xray stop 2>/dev/null ;;
                restart)
                    _xray_is_running || rc-service xray zap >/dev/null 2>&1
                    rc-service xray restart 2>/dev/null ;;
                status)
                    # 只认真实 xray 业务进程, 不认 supervise-daemon 父进程(否则崩溃循环被误报 running)
                    if _xray_is_running; then echo "running"; else echo "stopped"; fi
                    ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    local dpid0=""
                    [ -f /run/xray.pid ] && dpid0=$(cat /run/xray.pid 2>/dev/null)
                    # PID reuse 防护: pidfile 的 PID 必须 comm 仍是 xray 才算已在运行;
                    # 旧 xray 退出后 PID 若被其他程序复用, 陈旧 pidfile 应清掉再正常启动
                    if [ -n "$dpid0" ] && [ "$(cat /proc/$dpid0/comm 2>/dev/null)" = "xray" ]; then
                        echo "running"
                    else
                        rm -f /run/xray.pid
                        XRAY_LOCATION_ASSET="$ASSET_DIR" nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
                        echo $! > /run/xray.pid
                        sleep 1
                        if [ "$(cat /proc/$(cat /run/xray.pid 2>/dev/null)/comm 2>/dev/null)" != "xray" ]; then
                            _warn "Xray 启动失败,进程已退出"
                            rm -f /run/xray.pid
                            return 1
                        fi
                    fi
                    ;;
                stop)
                    if [ -f /run/xray.pid ]; then
                        local dpid; dpid=$(cat /run/xray.pid 2>/dev/null)
                        # PID reuse 防护: 只对 comm 确为 xray 的 pidfile 进程发信号, 绝不误杀复用该 PID 的其他程序
                        if [ -n "$dpid" ] && [ "$(cat /proc/$dpid/comm 2>/dev/null)" = "xray" ]; then
                            kill "$dpid" 2>/dev/null
                            # 优雅等待最多 5s, 仍不退出再 SIGKILL, 避免端口未释放
                            local k
                            for k in 1 2 3 4 5; do
                                kill -0 "$dpid" 2>/dev/null || break
                                sleep 1
                            done
                            kill -0 "$dpid" 2>/dev/null && kill -9 "$dpid" 2>/dev/null
                        fi
                    fi
                    rm -f /run/xray.pid
                    ;;
                restart) _manage_xray stop; sleep 2; _manage_xray start ;;
                status)  if _xray_is_running; then echo "running"; else echo "stopped"; fi ;;
            esac
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 重启 xray 并确认稳定运行(取代 _mutate_config 的预跑 xray -test)。
# 低内存 VPS 上 xray -test 会与运行中的实例同时加载两份二进制+geo, 触发 OOM;
# 改为重启后做存活确认: 先 sleep 1s 再查, 之后完整观察 8s, 期间任何一次
# 不为 running 都立即判失败。8s > openrc respawn_delay=5, 至少覆盖一个崩溃-重生周期,
# 避免坏配置在启动后短暂 running、随后崩溃却被误判成功。
# 坏配置/被 OOM 进不了持续 running 态 → 返回 1 触发上层回滚。
# ---------------------------------------------------------------------------
_restart_xray_verified() {
    # 服务操作本身必须成功: restart 失败再退而尝试 start; 两者都返回失败则立即判失败,
    # 避免"操作没生效、但恰好旧进程还活着 → 后续 8s 全 running → 假成功"。
    # (restart 偶发非 0 但服务其实已起来时, 后续 start 对 active 单元是幂等成功, 不影响。)
    if ! _manage_xray restart 2>/dev/null; then
        _manage_xray start 2>/dev/null || return 1
    fi
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        [ "$(_manage_xray status 2>/dev/null)" = "running" ] || return 1
    done
    return 0
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
    cur=$(_xray_cached_version 2>/dev/null)
    cur_channel=$(_state_get channel 2>/dev/null)
    [ -z "$cur_channel" ] && cur_channel="未设置"

    echo
    echo -e "  ${CYAN}【Xray 核心管理】${NC}"
    if [ -x "$XRAY_BIN" ] && [ -n "$cur" ]; then
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
