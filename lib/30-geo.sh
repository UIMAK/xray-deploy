#!/bin/bash
# =============================================================================
# lib/30-geo.sh — geosite/geoip 自动更新
# 需求 R4: 用户可开/关, 默认关; cron 每月 1/4/7/.../31 号 03:00 执行; 下载失败保留旧 dat; 运行期校验失败回退旧 dat; 不要精简版
# 数据源: Loyalsoldier/v2ray-rules-dat releases/latest/download/{geosite,geoip}.dat
# 落点: $ASSET_DIR (/opt/xray-deploy/assets, 即 XRAY_LOCATION_ASSET)
# 注意: cron 表达式 */3 在 day-of-month 字段表示每月 1/4/7/.../31 号, 并非严格的"每 3 天"(跨月不连续)
# ============================================================================

GEO_CRON_MARKER="# xray-deploy-geo-update"
GEO_STATE_FILE="$STATE_DIR/geo_cron"

# ---------------------------------------------------------------------------
# "该 routing 规则是否引用 geo 数据"的唯一判据(统计与过滤复用同一份, 避免两处漂移)
#
# 依据 Xray-docs-next/docs/config/routing.md 与 Xray-core/app/router/config.go
# 的 BuildCondition: 只有 domain(geosite:/ext:)与三个 IP 类字段 ip / sourceIP(别名
# source)/ localIP(geoip:/ext:)会触发 dat 加载; protocol/port/network/user/attrs/
# process/inboundTag 全是纯内存匹配器, 不吃 geo 内存。
#
# 三个细节不能省:
#   ext:file:tag 等价于 geoip:/geosite:(routing.md), 漏判会让手写 ext: 规则清不掉,
#     用户"照做了却没省内存";
#   ! 反选前缀(routing.md) 同样加载 dat, 故先 ltrimstr("!") 再判前缀;
#   ? 与 // [] 兜底吸收畸形输入(routing 缺失 / routing:null / rules:null /
#     domain 被手写成字符串而非数组), 否则 jq 直接报错中止。
# ---------------------------------------------------------------------------
GEO_RULE_REF_JQ='([(.domain? // [])[]?, (.ip? // [])[]?, (.sourceIP? // [])[]?, (.source? // [])[]?, (.localIP? // [])[]?] | map(select(type=="string")) | map(ltrimstr("!")) | any(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))'

# ---------------------------------------------------------------------------
# 确保 cron 服务在运行并开机自启(语义对齐 systemctl enable --now)。
# 返回 0 仅当"当前启动 + 持久化启用"都成功; 任一失败返回 1, 由调用方决定状态标记。
# ---------------------------------------------------------------------------
_ensure_cron_running() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || return 1 ;;
        # OpenRC: Alpine 默认 BusyBox cron 为 crond, 也支持 cronie/dcron。
        # 通过 /etc/init.d/ 存在性探测, 不硬编码服务名。
        # 先 start 再 rc-update add: start 失败直接返回(不把 enable 当成功), 
        # enable(add 到 default runlevel)失败同样返回 1 —— 不能只"当前在跑"就当完整成功,
        # 否则重启后 cron 不自启, 项目状态却显示 on(service/config/state 分裂)。
        openrc)
            local cron_svc=""
            for cron_svc in crond cronie dcron; do
                if [ -x "/etc/init.d/$cron_svc" ]; then
                    rc-service "$cron_svc" start 2>/dev/null || return 1
                    rc-update add "$cron_svc" default 2>/dev/null || return 1
                    return 0
                fi
            done
            return 1
            ;;
        # direct(无 init 系统): 尽力找到并启动 cron 守护(crond=busybox/Vixie, cron=ISC)
        # 判活用 _proc_any_named(pidof 优先 + /proc comm 扫描兜底, 容器内可靠), 不用 pgrep ——
        # 容器内 busybox pgrep -x 会假阴性(H3), 误把已运行的 crond 判为"未运行"
        # 再二次启动, 反而返回失败。
        direct)
            if command -v crond >/dev/null 2>&1; then
                _proc_any_named crond && return 0
                crond 2>/dev/null || return 1
                return 0
            elif command -v cron >/dev/null 2>&1; then
                _proc_any_named cron && return 0
                cron 2>/dev/null || return 1
                return 0
            fi
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 执行一次 Geo 更新(备份旧 dat → 下载覆盖 → 重启 xray)
# ---------------------------------------------------------------------------
_geo_update() {
    _ensure_dirs || return 1
    # M26: cron 环境下 _info/_warn 输出到 stdout 会产生噪音邮件, 重定向到日志
    if [ ! -t 0 ]; then
        exec >> "$GEO_LOG" 2>&1
    fi
    # R38(M5): mktemp -d 失败必须中止 —— 否则 tmp="" 会让 t="/geosite.dat", 两个 20MB+
    # 的 dat 被下载到根目录, 且末尾 rm -rf "$tmp" 变成 rm -rf "" 空操作, 文件永久残留。
    # /tmp 写满/只读/inode 耗尽正是本 PR 关注的低配 VPS 场景。
    local tmp
    tmp=$(mktemp -d) || { _error "无法创建临时目录(/tmp 写满或只读?), Geo 更新中止"; return 1; }
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    _info "[$ts] 开始更新 Geo 数据..."

    local ok=1
    local backed=()  # 已备份的旧 dat 路径, 用于失败回退 (S9)
    for f in geosite.dat geoip.dat; do
        local url="$GEO_BASE/$f" dest="$ASSET_DIR/$f" t="${tmp}/${f}"
        _info "下载 $f <- $url"
        if ! _http_download "$url" "$t" 60; then
            _warn "$f 下载失败, 保留旧文件"
            ok=0; continue
        fi
        # 校验: 非空 + 体积合理(>1KB)
        local sz; sz=$(stat -c%s "$t" 2>/dev/null || stat -f%z "$t" 2>/dev/null || echo 0)
        if [ "$sz" -lt 1024 ]; then
            _warn "$f 体积异常(${sz}B), 保留旧文件"
            ok=0; rm -f "$t"; continue
        fi
        # 覆盖前备份旧 dat (S9: 运行期校验失败或部分下载失败时可回退)。
        # 备份必须真正成功才允许覆盖: 磁盘满/IO 错误导致 cp 失败时, 若继续 mv 会让旧 dat
        # 无备份可回滚 → 数据集不一致。备份失败则保留旧文件、本次不替换。
        if [ -f "$dest" ]; then
            if ! cp -f "$dest" "$dest.bak"; then
                _warn "$f 旧文件备份失败(磁盘空间/IO?), 保留旧文件, 跳过本次替换"
                ok=0; rm -f "$t"; continue
            fi
            backed+=("$dest")
        fi
        # 原子替换。mv 失败(磁盘满/IO/只读)时旧 dat 仍在原位, 不能报"更新成功"并随后删除 .bak;
        # 置 ok=0 走"部分失败"分支, 由 backed[] 里的 .bak 把旧 dat 还原回来。
        if ! mv -f "$t" "$dest"; then
            _warn "$f 替换失败(磁盘空间/IO/只读?), 保留旧文件, 跳过本次更新"
            ok=0; rm -f "$t"; continue
        fi
        _success "$f 更新成功 (${sz}B)"
    done

    rm -rf "$tmp"

    # 日志 + 校验
    mkdir -p "$LOG_DIR"
    if [ "$ok" -eq 1 ]; then
        # 低内存机器不跑 xray -test(双份加载 OOM); 改为重启后做稳定存活确认。
        # 仅当 xray 已安装且原本在运行/存在配置时才重启验证
        local need_verify=0
        if [ -x "$XRAY_BIN" ] && [ -f "$CONFIG_FILE" ]; then
            case "$(_manage_xray status 2>/dev/null)" in running) need_verify=1;; esac
        fi
        if [ "$need_verify" -eq 1 ]; then
            if _restart_xray_verified; then
                for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
                echo "[$ts] OK 全部更新成功, xray 重启稳定" >> "$GEO_LOG"
            else
                # 新 dat 导致 xray 无法稳定运行: 回退旧 dat 并重新拉起
                # R38(M4): 必须统计"实际回退了几个"——backed[] 只在旧文件存在时才追加, 首次
                # 部署/assets 被清过的机器上它是空数组, 循环一次都不跑, 坏 dat 原样留在盘上,
                # 而日志却写"已回退旧 dat"。cron 每月一次, 这行日志是用户唯一的诊断依据。
                _warn "新 Geo 数据导致 xray 运行异常, 回退旧 dat"
                local rolled=0
                for dest in "${backed[@]}"; do
                    if [ -f "${dest}.bak" ]; then
                        if mv -f "${dest}.bak" "$dest"; then
                            rolled=$((rolled+1))
                        else
                            _warn "回滚 ${dest} 失败, 请手动检查"
                        fi
                    fi
                done
                # R38(M4): 回退后是否救回来了, 是值班时最需要知道的一件事; 不能用
                # `2>/dev/null || true` 把结果一并吞掉
                local recovered="xray 仍未稳定运行, 需人工介入"
                if _restart_xray_verified; then
                    recovered="xray 已恢复运行"
                fi
                if [ "$rolled" -eq 0 ]; then
                    _warn "无旧 dat 可回退(首次安装/assets 曾被清空), 新 dat 仍在 ${ASSET_DIR}"
                    echo "[$ts] FAIL 新 dat 运行期校验失败, 无旧 dat 可回退, ${recovered}" >> "$GEO_LOG"
                else
                    echo "[$ts] FAIL 新 dat 运行期校验失败, 已回退 ${rolled} 个旧 dat, ${recovered}" >> "$GEO_LOG"
                fi
                return 1
            fi
        else
            # xray 未安装/未运行: 无需重启, 清理备份
            for dest in "${backed[@]}"; do rm -f "${dest}.bak" 2>/dev/null; done
            echo "[$ts] OK 全部更新成功(xray 未运行, 已跳过重启)" >> "$GEO_LOG"
        fi
        return 0
    else
        # 部分下载失败: 回退已替换的文件, 保持 dat 对一致性
        # R38(M4): 同样统计实际回退数量, 并区分"有旧文件可回退"与"某份是首次下载"
        local rolled=0
        for dest in "${backed[@]}"; do
            if [ -f "${dest}.bak" ]; then
                if mv -f "${dest}.bak" "$dest"; then
                    rolled=$((rolled+1))
                else
                    _warn "回滚 ${dest} 失败, 请手动检查"
                fi
            fi
        done
        if [ "$rolled" -eq 0 ]; then
            echo "[$ts] PARTIAL 部分失败, 无已替换文件需回退" >> "$GEO_LOG"
        else
            echo "[$ts] PARTIAL 部分失败, 已回退 ${rolled} 个旧 dat" >> "$GEO_LOG"
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 开/关自动更新(crontab 每 3 天)
# 用法:_geo_set_auto_update on|off
# ---------------------------------------------------------------------------
_geo_set_auto_update() {
    local action="$1"
    # cron 调用本脚本的 geo-update 子命令: xd geo-update
    # */3 在 day-of-month 字段: 每月 1/4/7/.../31 号 03:00 (跨月不连续, 非严格 "每 3 天")
    # M25: cron 环境 PATH 受限时 command -v 可能失败, 硬编码 /usr/local/bin 兜底已足够
    local cmd="$(command -v "$CMD_NAME" 2>/dev/null || echo "/usr/local/bin/$CMD_NAME") geo-update"
    local cron_line="0 3 */3 * * $cmd ${GEO_CRON_MARKER}"

    case "$action" in
        on)
            # 先去重: 移除已有 marker 行
            _geo_remove_cron_line >/dev/null 2>&1
            ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab - 2>/dev/null || {
                _error "写入 crontab 失败"; return 1
            }
            # 确保 cron 服务运行; 失败时回滚刚写入的 crontab 行, 保证
            # state=off ⇔ 项目 cron entry 不存在, 避免 daemon 恢复后无状态执行。
            if _ensure_cron_running; then
                _state_set geo_cron "on"
                _success "Geo 自动更新已开启 (每月 1/4/7/.../31 号 03:00 执行)"
            else
                # 回滚刚写入的 crontab 行; 回滚失败要暴露, 不能静默
                if ! _geo_remove_cron_line >/dev/null 2>&1; then
                    _warn "crontab 回滚失败, 请手动检查项目定时任务 (${GEO_CRON_MARKER})"
                fi
                _warn "cron 守护进程未能启动, 自动更新已取消"
                _tip "请确保系统中有 cron 守护进程, 安装后重试"
                _state_set geo_cron "off"
            fi
            ;;
        off)
            _geo_remove_cron_line
            _state_set geo_cron "off"
            _success "Geo 自动更新已关闭"
            ;;
    esac
}

_geo_remove_cron_line() {
    crontab -l 2>/dev/null | grep -v "$GEO_CRON_MARKER" | crontab - 2>/dev/null
}

# ---------------------------------------------------------------------------
# 解析下次预计执行时间(从 crontab 行粗略推算, 用于回显)
# ---------------------------------------------------------------------------
_geo_next_run_hint() {
    local line
    line=$(crontab -l 2>/dev/null | grep "$GEO_CRON_MARKER" | head -1)
    if [ -z "$line" ]; then
        echo "未开启"
        return
    fi
    # 形如 0 3 */3 * * —— 每月 1/4/7/.../31 号 03:00 (非严格 "每 3 天", 跨月间隔不固定)
    echo "每月 1/4/7/.../31 号 03:00 (cron: $(echo "$line" | awk '{print $1" "$2" "$3" "$4" "$5}'))"
}

# ---------------------------------------------------------------------------
# 路由规则精简(小内存优化) —— 前置条件校验
# 两个写入动作(精简/恢复)共用 00-common 的 _config_edit_preflight
# (日志级别切换也用同一个, 校验口径必须一致 —— 见 R1.11 / R2.8)。
# 额外校验两个 00-common 常量非空: VPS 上存在"lib 部分更新"的混装状态(本模块是新版而
# 00-common 仍是旧版, CLAUDE.md 记录过多次)。裸引用会让 set -u 崩掉整个 TUI, 空值传给
# --argjson 又会产出难懂的 jq 报错; 这里前置判断给出可执行的提示。
# ---------------------------------------------------------------------------
_route_preflight() {
    _config_edit_preflight "修改路由规则" || return 1
    if [ -z "${XRAY_DEFAULT_ROUTING_RULES_JSON:-}" ] || [ -z "${XRAY_PRIVATE_BLOCK_RULE_JSON:-}" ] \
       || [ -z "${XRAY_PRIVATE_BLOCK_RULE_TAG:-}" ]; then
        _error "缺少默认规则常量(lib/00-common.sh 可能是旧版本), 无法修改路由规则"
        _tip "请在运维菜单执行 [检测脚本更新] 完整更新一次后重试"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 统计路由规则: "总数 geo引用数 节点(inboundTag)规则数 私网标记数" 单行输出
# 一次 jq 出四个数字: 低配机上每次 jq 都是一次 fork + 读整份 config, 不值得跑四遍。
# 读不到时输出 "0 0 0 0" 并返回 1(调用方据此显示"无法读取")。
# ---------------------------------------------------------------------------
_route_rules_stats() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ] || ! command -v jq >/dev/null 2>&1; then
        printf '0 0 0 0'
        return 1
    fi
    local out
    out=$(jq -r "
        [.routing.rules[]?] as \$r
        | [
            (\$r | length),
            ([\$r[] | select(${GEO_RULE_REF_JQ})] | length),
            ([\$r[] | select(.inboundTag? != null)] | length),
            ([\$r[] | select((.ruleTag? // null) == \"${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private}\")] | length)
          ] | @tsv" "$CONFIG_FILE" 2>/dev/null) || { printf '0 0 0 0'; return 1; }
    [ -n "$out" ] || { printf '0 0 0 0'; return 1; }
    # @tsv 用制表符分隔, 转成空格便于调用方 read -r 拆分
    printf '%s' "$out" | tr '\t' ' '
    return 0
}

# ---------------------------------------------------------------------------
# 统计 dns 段里的 geo 引用数(domains / expectedIPs / expectIPs)
# 本项目默认 DNS 段不含 geo 引用, 但用户手改过的配置可能有 —— 此时精简 routing
# 并不能完全免除 dat 加载, 必须如实告警, 否则用户会得到"照做了却没省内存"的错误结论。
# ---------------------------------------------------------------------------
_route_dns_geo_count() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ] || ! command -v jq >/dev/null 2>&1; then
        printf '0'
        return 1
    fi
    local n
    n=$(jq -r '
        [.dns?.servers[]? | select(type == "object")
         | (.domains? // [])[]?, (.expectedIPs? // [])[]?, (.expectIPs? // [])[]?]
        | map(select(type == "string")) | map(ltrimstr("!"))
        | map(select(startswith("geosite:") or startswith("geoip:") or startswith("ext:")))
        | length' "$CONFIG_FILE" 2>/dev/null) || { printf '0'; return 1; }
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
    return 0
}

# ---------------------------------------------------------------------------
# 精简: 删除所有引用 geo 数据的规则, 注入等价的字面量 CIDR 私网 block 规则
#
# 顺序契约(关键): 私网规则必须插在"第一条无 inboundTag 的规则"之前。路由自上而下匹配
# (routing.md), tunnel 模式 Reality 节点的 2 条 inboundTag 规则必须保持在最前 ——
# 若私网 block 抢先命中, tunnel 入站到伪装站的握手流量会被切断(节点直接不可用)。
# 没有任何通用规则时(first 为 null)退化为追加到末尾。
#
# 幂等: 先按 ruleTag 剔除上一次注入的私网规则再重插, 故重复执行结果完全一致。
# 一律用"重建赋值" .routing.rules = [...] 而非 |= map(...): 后者在 routing:null 时
# 抛 "Cannot iterate over null"(jq 1.8.2 实测)。
#
# 两处对非对象规则元素的处理必须分清(手工编辑可能把某条规则写成裸字符串):
#   `(.ruleTag? // null) != "<tag>"` —— 必须带 `// null`。裸 `.ruleTag?` 对字符串元素
#     产出**空**, 于是 select 丢掉该元素, 精简会顺手删掉用户的坏规则(静默改动了我们
#     没被授权动的东西)。`// null` 把"取不到"变成 null, 使该元素被保留。
#   `.value.inboundTag? == null` —— 这里**不**补 `// null` 是刻意的: 空产出使非对象
#     元素不成为插入点, 私网规则因而落在第一条真正的"无 inboundTag 对象规则"之前,
#     顺序契约不受垃圾元素干扰。
# ---------------------------------------------------------------------------
_route_slim_geo_rules() {
    _route_preflight || return 1
    _mutate_config --argjson priv "$XRAY_PRIVATE_BLOCK_RULE_JSON" \
        ".routing.rules = ([.routing.rules[]?
            | select(${GEO_RULE_REF_JQ} | not)
            | select((.ruleTag? // null) != \"${XRAY_PRIVATE_BLOCK_RULE_TAG}\")] as \$k
          | ([\$k | to_entries[] | select(.value.inboundTag? == null) | .key] | first // (\$k | length)) as \$i
          | \$k[0:\$i] + [\$priv] + \$k[\$i:])" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 恢复默认规则: 保留现存节点(inboundTag)规则, 其后接 00-common 的默认规则集
# 只保留 inboundTag 规则天然满足"节点规则在前 + 无重复", 且我们注入的私网规则
# (无 inboundTag)会被这一步自然丢弃。
# 显式写回 domainStrategy: 默认规则里的 geoip:cn 依赖 IPIfNonMatch 才能对域名目标生效。
# 已知取舍: 会丢弃用户手工添加的**非节点**自定义规则 —— 调用方必须在确认前明示。
# 注意 `.inboundTag?` 的 `?` 不可省: 手工编辑把某条规则写成非对象(如裸字符串)时,
# 无 `?` 的 `.inboundTag` 会让 jq 以 "Cannot index string with string" 整体失败,
# 于是"恢复默认规则"在最需要它的坏配置上反而不可用。
# ---------------------------------------------------------------------------
_route_restore_default_rules() {
    _route_preflight || return 1
    _mutate_config --argjson defs "$XRAY_DEFAULT_ROUTING_RULES_JSON" \
        '.routing.domainStrategy = "IPIfNonMatch"
         | .routing.rules = ([.routing.rules[]? | select(.inboundTag? != null)] + $defs)' || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 路由规则子菜单(小内存优化入口, 由 _geo_menu [3] 进入)
# ---------------------------------------------------------------------------
_route_rules_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【路由规则(小内存优化)】${NC}"
        echo
        local total=0 geo=0 node=0 mark=0 stats_ok=1
        local stats; stats=$(_route_rules_stats) || stats_ok=0
        read -r total geo node mark <<< "$stats"
        if [ "$stats_ok" -ne 1 ]; then
            _warn "无法读取当前路由规则(Xray 未安装 / 配置缺失 / jq 不可用)"
        else
            echo -e "  规则总数:   ${CYAN}${total}${NC}"
            if [ "$geo" -gt 0 ]; then
                echo -e "  引用 geo:   ${YELLOW}${geo}${NC} 条 (会加载 geosite.dat / geoip.dat)"
            else
                echo -e "  引用 geo:   ${GREEN}0${NC} 条 (不加载 dat)"
            fi
            echo -e "  节点规则:   ${CYAN}${node}${NC} 条 (tunnel 模式 Reality 的防偷跑规则)"
            if [ "$mark" -gt 0 ]; then
                echo -e "  私网防护:   ${GREEN}已注入字面量 CIDR${NC} (${XRAY_PRIVATE_BLOCK_RULE_TAG:-xd-block-private})"
            else
                echo -e "  私网防护:   ${CYAN}未注入${NC}"
            fi
            local dnsgeo; dnsgeo=$(_route_dns_geo_count)
            if [ "$dnsgeo" -gt 0 ]; then
                echo
                _warn "dns 段还有 ${dnsgeo} 处 geo 引用, 精简路由规则不足以完全免除 dat 加载"
                _tip "如需彻底省内存, 请手工编辑 ${CONFIG_FILE} 的 dns 段去掉 geosite:/geoip:/ext: 引用"
            fi
        fi
        echo
        echo -e "  ${YELLOW}小内存 VPS 上 geosite.dat + geoip.dat 各约 20MB+, 是 xray 被 OOM 杀掉的主因${NC}"
        echo
        echo -e "  ${GREEN}[1]${NC} 精简规则(去掉 geo 引用, 保留节点规则与私网防护)"
        echo -e "  ${GREEN}[2]${NC} 恢复默认规则(重新引用 geo 数据)"
        echo -e "  ${GREEN}[0]${NC} 返回"
        echo
        read -rp "  请选择: " choice
        case "${choice:-0}" in
            0) return ;;
            1)
                _route_preflight || { _press_any_key; continue; }
                # 幂等: 已无 geo 引用且私网规则已在, 直接返回, 不触发 8 秒 verified-restart
                if [ "$geo" -eq 0 ] && [ "$mark" -gt 0 ]; then
                    _info "已是精简状态(无 geo 引用 + 私网防护已注入), 无需重复操作"
                    _press_any_key; continue
                fi
                echo
                echo -e "  将执行:"
                echo -e "    ${CYAN}删除${NC} ${geo} 条引用 geo 数据的规则"
                echo -e "    ${CYAN}注入${NC} 1 条字面量 CIDR 私网 block 规则(等价 geoip:private, 不加载 dat)"
                echo -e "    ${CYAN}保留${NC} ${node} 条节点规则(仍在最前) + bittorrent 拦截 + 域名白名单直连"
                read -rp "  确认精简? [y/N]: " ans
                case "$ans" in
                    y|Y) ;;
                    *) _info "已取消"; _press_any_key; continue ;;
                esac
                if _route_slim_geo_rules; then
                    _success "路由规则已精简, xray 已用新配置重启"
                    _tip "geosite.dat / geoip.dat 不再被加载, 内存占用应明显下降"
                    local gstate; gstate=$(_state_get geo_cron 2>/dev/null)
                    if [ "$gstate" = "on" ]; then
                        _tip "当前 Geo 自动更新仍为开启; 已无 geo 规则时它没有实际意义, 可在上一级 [2] 关闭"
                    fi
                else
                    _error "精简失败(配置已回滚)"
                fi
                _press_any_key
                ;;
            2)
                _route_preflight || { _press_any_key; continue; }
                echo
                echo -e "  ${YELLOW}恢复后将重新引用 geosite/geoip 数据, 小内存机器可能再次被 OOM${NC}"
                echo -e "  ${YELLOW}注意: 手工添加的非节点自定义规则会被丢弃(节点规则保留; 配置已自动备份)${NC}"
                read -rp "  确认恢复默认规则? [y/N]: " ans
                case "$ans" in
                    y|Y) ;;
                    *) _info "已取消"; _press_any_key; continue ;;
                esac
                if _route_restore_default_rules; then
                    _success "已恢复默认路由规则(bittorrent / 广告+私网域名 / 私网+CN IP / 域名白名单直连)"
                    _tip "请确认 assets 下 geosite.dat 与 geoip.dat 存在, 否则可在上一级 [1] 立即更新一次"
                else
                    _error "恢复失败(配置已回滚)"
                fi
                _press_any_key
                ;;
            *)
                _warn "无效选择"
                _press_any_key
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Geo 菜单入口
# ---------------------------------------------------------------------------
_geo_menu() {
    clear
    echo
    echo -e "  ${CYAN}【Geo 数据自动更新】${NC}"
    local state; state=$(_state_get geo_cron 2>/dev/null)
    [ -z "$state" ] && state="off"
    if [ "$state" = "on" ]; then
        echo -e "  当前状态: ${GREEN}● 已开启${NC}"
        echo -e "  下次执行: $(_geo_next_run_hint)"
    else
        echo -e "  当前状态: ${RED}○ 已关闭${NC}"
    fi
    echo -e "  数据源: Loyalsoldier/v2ray-rules-dat (完整版)"
    echo -e "  落点: $ASSET_DIR (XRAY_LOCATION_ASSET)"
    echo
    echo -e "  ${GREEN}[1]${NC} 立即更新一次"
    if [ "$state" = "on" ]; then
        echo -e "  ${GREEN}[2]${NC} 关闭自动更新"
    else
        echo -e "  ${GREEN}[2]${NC} 开启自动更新(定期)"
    fi
    echo -e "  ${GREEN}[3]${NC} 路由规则(小内存优化: 精简 geo 引用)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  请选择: " choice
    case "$choice" in
        1) _geo_update ;;
        2) if [ "$state" = "on" ]; then _geo_set_auto_update off; else _geo_set_auto_update on; fi ;;
        3) _route_rules_menu; return ;;
        0) return ;;
        *) _warn "无效" ;;
    esac
    _press_any_key
}
