#!/bin/bash
# =============================================================================
# lib/20-xray-core.sh — Xray 核心管理
# 双通道(稳定版 stable / 预览版 preview)安装与任意切换 + service 生成
# Xray 核心安装、双通道切换与运行环境管理
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
#   stable: releases/latest; preview: releases 里最新的 prerelease
# jq 解析 release 对象; 无 jq 时按字段边界兜底, curl 失败再用 wget。
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
            body=$(curl -fsSL --max-time 20 "$XRAY_REPO_API?per_page=30" 2>/dev/null) \
                || body=$(wget -q -T 20 -O- "$XRAY_REPO_API?per_page=30" 2>/dev/null)
            [ -z "$body" ] && return 1
            # 优先 jq: 第一个 prerelease==true 的 tag_name
            tag=$(echo "$body" | jq -r '[.[] | select(.prerelease == true)] | .[0].tag_name // empty' 2>/dev/null)
            # 兜底(无 jq): 记住"最近一个 tag_name", 遇到 prerelease:true 即输出 —— 只依赖对象
            # 内字段先后(GitHub 稳定顺序), 不依赖行距(旧 grep -B5 固定窗口会取错版本)。
            if [ -z "$tag" ] || [ "$tag" = "null" ]; then
                # 先按对象边界拆行; 否则紧凑单行 JSON 里贪婪的 sub 只保留最后一个 tag_name。
                tag=$(printf '%s' "$body" | awk '
                    # 先按对象边界把每个 release 拆成独立记录, 再逐记录扫描。
                    # 用 awk 的 gsub+split 而不是 sed: sed 的替换串里带换行在不同实现上
                    # 行为不一致(实测 GNU sed 直接报 unterminated substitution), 且 busybox
                    # 的 sed 也不保证支持这种写法。POSIX awk 的 gsub/split 到处都有。
                    {
                        gsub(/\},\{/, "}\n{")
                        n = split($0, _rec, "\n")
                        for (_i = 1; _i <= n; _i++) {
                            # rec 保留原始记录; 标签抽取必须写到**另一个**变量 —— 就地改写
                            # rec 会把 "prerelease" 文本一起抹掉, 后面的判定就永远不成立
                            # (实测: 取到了 tag 却一个都没输出, 整个兜底静默失效)。
                            rec = _rec[_i]
                            if (rec ~ /"tag_name"[[:space:]]*:/) {
                                tag = rec
                                sub(/.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag)
                                sub(/".*/, "", tag)
                                last = tag
                            }
                            if (rec ~ /"prerelease"[[:space:]]*:[[:space:]]*true/) {
                                print last; exit
                            }
                        }
                    }
                ')
            fi
            ;;
        *) return 1 ;;
    esac
    [ -n "$tag" ] && [ "$tag" != "null" ] && echo "$tag" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 版本号规范化的唯一入口: 接受 v26.3.27 / 26.3.27, 输出 tag "v26.3.27"; 非法输入返回 1。
# Xray release tag 恒为 vMAJOR.MINOR.PATCH, 只认三段数字, 不猜别名/前缀/范围
# (与 _hysteria_canon_version 同口径)。只裁首尾空白, 内部空格如实拒绝。
# ---------------------------------------------------------------------------
_xray_canon_tag() {
    local v="${1:-}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v#v}"; v="${v#V}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf 'v%s' "$v"
}

# ---------------------------------------------------------------------------
# 当前已安装版本
# ---------------------------------------------------------------------------
_xray_current_version() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# 版本门控: 当前核心是否 >= 最低要求。用法: _xray_version_ge "26.7.11"
# docs 领先于已发布核心, config 新字段(env/geodata 等)在旧核心上被 Go JSON 静默忽略
# ⇒ 新特性必须按目标发布版本门控。纯数字三段比较(不用 sort -V, busybox 兼容)。
# 未安装/版本读不到/畸形版本 → 返回 1(fail-closed), 调用方走旧核心路径。
# ---------------------------------------------------------------------------
_xray_version_ge() {
    local min="$1" cur i x y
    cur=$(_xray_current_version 2>/dev/null)
    [ -n "$cur" ] || return 1
    # 两侧都可能带 "v" 前缀, 先剥掉。
    # 版本门控绝不猜畸形输入: 畸形版本 = 未知能力, 调用方必须走旧核心路径。
    cur="${cur#v}"; cur="${cur#V}"
    min="${min#v}"; min="${min#V}"
    [[ "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$min" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local -a a b
    IFS='.' read -ra a <<< "$cur"
    IFS='.' read -ra b <<< "$min"
    for i in 0 1 2; do
        x="${a[$i]:-0}"; y="${b[$i]:-0}"
        [[ "$x" =~ ^[0-9]+$ ]] || return 1
        [[ "$y" =~ ^[0-9]+$ ]] || return 1
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 0
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
# 下载 Xray 二进制到 staging(不缓存旧版; 真正的替换在 _xray_commit_staged)
# 用法: _xray_stage_release <tag>   → stdout = staging 目录(失败时非 0, 无输出)
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

# 阶段一只在自有 staging 取件, 不碰共享状态; 网络等待不持 core lock。
_xray_stage_release() {
    local tag="$1"
    local asset tmp_dir tmp_zip
    asset=$(_xray_arch_asset)
    if [ -z "$asset" ]; then
        _error "不支持的架构: $(uname -m)"
        return 1
    fi

    command -v unzip >/dev/null 2>&1 || _pkg_install unzip || return 1

    local dl_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
    # staging 放在 BIN_DIR 同盘, 保证 mv 使用 rename 而非可能截断目标的跨盘拷贝。
    # 不清理无法区分的并发 staging/SIGKILL 残留; mktemp 失败必须中止, 防止空路径写向根目录。
    mkdir -p "$BIN_DIR" || { _error "无法创建 $BIN_DIR, 核心替换中止"; return 1; }
    tmp_dir=$(mktemp -d "${BIN_DIR}/.xray-dl.XXXXXX") \
        || { _error "无法在 $BIN_DIR 创建临时目录(磁盘满/只读/inode 耗尽?), 核心替换中止"; return 1; }
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
    # 立即删 zip(低内存 VPS: 多余的 20MB 无论占 tmpfs 还是磁盘都尽快还回去)
    rm -f "$tmp_zip"
    if [ ! -f "${tmp_dir}/xray" ]; then
        _error "压缩包内未找到 xray 二进制"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 取件到此为止: 共享状态(二进制/服务/geo dat)一律留到阶段二的锁内处理。
    # geo dat 从 staging 就位, 由阶段二带快照地提交。
    printf '%s' "$tmp_dir"
    return 0
}

# 阶段二(锁内): 用 staging 提交替换。所有共享状态改动都在这里。
# 用法: _xray_commit_staged <staging目录>
# 返回三态(调用方必须消费, 不得把所有非 0 都当成"没动过"):
#   0 = mutation batch 完成(binary/geo 已就位, 尚未验证服务)
#   1 = staging 不可用, 或 phase barrier 明确仍停在 snapshotted; 未 stop/未触碰生产文件
#   3 = replacing 已 durable, mutation 可能部分发生; caller 必须运行 journal recovery
# 从 replacing 到恢复完成前, journal 与 snapshots 均不得由调用方直接丢弃。
_xray_commit_staged() {  # <staging_dir> -- 0=mutation batch complete; 1=mutation never started; 3=recovery required
    local tmp_dir="$1" j binbak pre gd tmp phase
    [ -d "$tmp_dir" ] && [ -f "${tmp_dir}/xray" ] || {
        _error "staging 目录不可用: ${tmp_dir:-（空）}"; return 1; }
    j=$(_xray_core_journal_path)
    # **Phase barrier**: replacing 必须在第一条真实 mutation(含 stop)之前 durable。
    # 写入/回读失败时重读 journal: 确定未推进(1)与落盘状态不明(3); 两条路径都尚未 stop。
    if ! _xray_core_journal_phase "replacing"; then
        phase=$(jq -r '.phase // empty' "$j" 2>/dev/null) || phase=""
        [ "$phase" = snapshotted ] && return 1
        return 3
    fi
    # 从此 phase 起任何失败都 return 3: 外层只能交给 journal recovery, 不得 drop 账本/快照。
    if ! _xray_stop_and_verify; then
        _error "切换前未能确认 Xray 已停止"
        return 3
    fi
    binbak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 3
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 3
    if [ "$pre" = true ] && [ ! -s "$binbak" ]; then
        _error "旧 binary snapshot 缺失/为空, 不允许替换: $binbak"
        return 3
    fi
    if [ "$pre" = false ] && _xray_core_path_present "$XRAY_BIN"; then
        _error "事务前不存在的 binary 在 replacing 前已被外部创建, 停止提交"
        return 3
    fi
    if ! mv -f "${tmp_dir}/xray" "$XRAY_BIN"; then
        _error "新二进制替换失败(磁盘空间/IO/只读?)"
        return 3
    fi
    if ! chmod +x "$XRAY_BIN" 2>/dev/null; then
        _error "新二进制设置执行权限失败"
        return 3
    fi

    # geo dat 是同一事务的真实状态; 快照在 snapshotted 之前已建好。同目录 temp + cmp + rename,
    # 任何失败统一 return 3 交给 rollback。
    for gd in geoip.dat geosite.dat; do
        [ -f "${tmp_dir}/${gd}" ] || continue
        tmp=$(mktemp "${ASSET_DIR}/.${gd}.coretxn-new.XXXXXX") || {
            _error "无法创建 ${gd} 临时文件"; return 3; }
        if ! cp "${tmp_dir}/${gd}" "$tmp" 2>/dev/null || \
           ! cmp -s "${tmp_dir}/${gd}" "$tmp" 2>/dev/null || \
           ! chmod 644 "$tmp" 2>/dev/null || ! mv -f "$tmp" "${ASSET_DIR}/${gd}" 2>/dev/null; then
            rm -f "$tmp" 2>/dev/null
            _error "${gd} 原子替换失败, 交由事务恢复"
            return 3
        fi
    done
    _maybe_drop_caches
    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        _error "新二进制无法执行/版本子命令失败, 交由事务恢复"
        return 3
    fi
    _ensure_xray_symlink
    return 0
}
# ---------------------------------------------------------------------------
# geo dat 的事务侧恢复: rollback 始终从 journal 指向的事务唯一快照重放;
# 快照删除统一由 _xray_core_cleanup_sources 执行(删 journal 前检查全部残留)。
# ---------------------------------------------------------------------------
_xref_snapshot_geo_dats() {  # <journal> -- unique transaction paths are recorded in the journal
    local j="$1" gd src bak pre
    for gd in geoip geosite; do
        src="$ASSET_DIR/${gd}.dat"
        pre=$(jq -r --arg g "$gd" '.[$g + "_preexisted"]' "$j" 2>/dev/null) || return 1
        bak=$(jq -r --arg g "$gd" '.[$g + "_backup"]' "$j" 2>/dev/null) || return 1
        if [ "$pre" = true ]; then
            [ -f "$src" ] && [ ! -L "$src" ] || { _error "$gd.dat 在快照阶段消失或不是普通文件: $src"; return 1; }
            ! _xray_core_path_present "$bak" || { _error "$gd.dat 唯一快照路径已存在, 拒绝覆盖: $bak"; return 1; }
            cp -p "$src" "$bak" 2>/dev/null || { rm -f "$bak" 2>/dev/null; return 1; }
            if ! cmp -s "$src" "$bak" 2>/dev/null; then
                rm -f "$bak" 2>/dev/null
                _error "$gd.dat 快照不完整(磁盘空间/IO?): $bak"
                return 1
            fi
        else
            ! _xray_core_path_present "$src" || { _error "$gd.dat 在快照阶段被外部创建: $src"; return 1; }
            ! _xray_core_path_present "$bak" || { _error "$gd.dat 唯一快照路径已存在: $bak"; return 1; }
        fi
    done
    return 0
}

_xref_restore_geo_dats() {  # <journal> -- retain snapshot sources until rolled_back phase is durable
    local j="$1" gd src bak pre failed=0
    for gd in geoip geosite; do
        src="$ASSET_DIR/${gd}.dat"
        pre=$(jq -r --arg g "$gd" '.[$g + "_preexisted"]' "$j" 2>/dev/null) || { failed=1; continue; }
        bak=$(jq -r --arg g "$gd" '.[$g + "_backup"]' "$j" 2>/dev/null) || { failed=1; continue; }
        if [ "$pre" = true ]; then
            if [ ! -f "$bak" ] || [ -L "$bak" ]; then
                _error "$gd.dat 恢复源丢失或不是普通文件: $bak"
                failed=1
            elif ! _xray_restore_file_atomic "$bak" "$src" 644; then
                _error "$gd.dat 原子恢复失败: $src (源保留: $bak)"
                failed=1
            elif ! cmp -s "$bak" "$src" 2>/dev/null; then
                _error "$gd.dat 恢复后校验不一致: $src"
                failed=1
            fi
        elif _xray_core_path_present "$bak"; then
            _error "事务前不存在的 $gd.dat 却发现恢复快照, 拒绝猜测: $bak"
            failed=1
        elif ! rm -f "$src" 2>/dev/null || _xray_core_path_present "$src"; then
            _error "事务前不存在的 $gd.dat 无法移除: $src"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 定时重启执行体(cron 调用: xd timed-restart)
# 基础文件检查 → restart → 记录日志; 低内存机器不预跑 xray -test(避免双份二进制+geo OOM)
# ---------------------------------------------------------------------------
_timed_restart_do() {
    local log_file="$LOG_DIR/timed-restart.log"
    mkdir -p "$LOG_DIR"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ ! -x "$XRAY_BIN" ]; then
        echo "[$ts] 跳过: Xray 未安装" >> "$log_file"
        exit 0
    fi
    if ! _config_present; then
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
# 核心切换同步还原: binary → service → 尽力重启 → version/channel。
# service 与核心 env 门控相关, 两侧均还原才算成功; 重启失败只告警。
# 用法: _xray_restore_prev_bin <旧版本号> <旧通道> [binary_kept]
# 返回 0=完整还原, 1=无 .bak 或 binary 还原失败, 2=binary 已恢复但 service 未恢复。
# binary_kept 表示新二进制保留, 此时 state 记新版本。
# ---------------------------------------------------------------------------
_xray_restore_prev_bin() {
    local cur="$1" prev_channel="${2:-}" binary_kept="${3:-}"
    local svc_ok=1
    # geo dat 与二进制同属"核心运行依赖", 回滚时一并换回。放在最前: 它不依赖其它
    # 步骤的结论, 失败只影响 disk 判据(下面按 svc_ok 汇总)。
    if declare -F _xref_restore_geo_dats >/dev/null 2>&1; then
        _xref_restore_geo_dats || svc_ok=0
    fi
    if [ ! -f "$XRAY_BIN.bak" ]; then
        # 首次安装: 没有旧二进制可回。**不删**刚落地的新二进制 —— 用户可能仍可用它,
        # 删掉只会把"核心能跑但 service 没建好"变成"完全没核心"。
        _warn "无旧核心备份可还原, 保留已落地的二进制 v${cur:-?}(service/config 可能未就绪)"
        # unit 是**独立于二进制**的一侧: 即使没有旧二进制可回, 本次新建/写坏的 unit 也必须
        # 复原到事务前的状态, 否则"没有核心 + 半截 unit"比现状更难恢复。
        _xray_service_restore_prev || svc_ok=0
        local keepv; keepv=$(_xray_current_version 2>/dev/null)
        [ -n "$keepv" ] && { _state_set version "$keepv" || _warn "状态持久化失败(version)"; }
        return 1
    fi
    if ! mv -f "$XRAY_BIN.bak" "$XRAY_BIN"; then
        _error "旧二进制还原失败, 请手动处理 $XRAY_BIN(备份仍在 $XRAY_BIN.bak)"
        # 二进制没还原成功, 但 unit 仍要尽量复原 —— 两个失败互不依赖, 不做"先回滚谁"的取舍
        _xray_service_restore_prev || svc_ok=0
        [ "$svc_ok" -eq 0 ] && _error "service 文件也未能还原, 请一并手动核对(见上方提示)"
        return 1
    fi
    chmod +x "$XRAY_BIN" 2>/dev/null || _warn "还原后的二进制执行位设置失败: $XRAY_BIN"
    _xray_service_restore_prev || svc_ok=0
    # 服务拉起放在两侧还原之后: service 没还原成功时**仍然要拉**, 失败方向是"尽力恢复可用" ——
    # 但那属于"回滚不完整", 由返回码 2 如实上报, 不再伪装成成功。
    _manage_xray restart >/dev/null 2>&1 || _manage_xray start >/dev/null 2>&1 || \
        _warn "还原旧核心后服务未能拉起, 请手动检查: xd 菜单 [Xray 核心管理]"
    local recv; recv=$(_xray_current_version 2>/dev/null)
    [ -n "$recv" ] || recv="$cur"
    [ -n "$recv" ] && { _state_set version "$recv" || _warn "状态持久化失败(version)"; }
    if [ -n "$prev_channel" ]; then
        _state_set channel "$prev_channel" || _warn "状态持久化失败(channel)"
    else
        # 替换前没有 channel 记录 => 磁盘上也不该有(保持"两键同进退")
        rm -f "$STATE_DIR/channel" 2>/dev/null
    fi
    if [ "$svc_ok" -ne 1 ]; then
        # 二进制回到了旧版, 但 unit 不是改动前那一份 —— 这是**回滚不完整**, 必须让调用方
        # 与用户都看见, 而不是混在"已还原到旧核心"里。
        _error "回滚不完整: 旧二进制已就位, 但 service 文件未能还原到改动前的内容"
        _tip "请核对: $(_xray_service_unit_path 2>/dev/null || echo '(无 service)') 与备份 $(_xray_service_prev_path)"
        _tip "临时可用: xd 菜单 [Xray 核心管理] 重装一次该通道, 会按当前核心版本重写 service"
        return 2
    fi
    _warn "已还原到旧核心 v${recv:-?}"
    return 0
}

# ---------------------------------------------------------------------------
# core lock 串行化 binary/service/Geo 提交与 service control/完整判活; 下载留在锁外。
# 锁根 /var/lock/xray-deploy 在部署树外; 普通事务锁序 install → config → core。
# 核心事务不取 config lock; 卸载/reset 持三层锁直到删除/重建完成。
# flock fd 动态分配并在派生服务时关闭, 防止 fd 冲突与守护进程长期持锁。
# 无 flock 时 core.lock.d mkdir 退路拒绝残留, 不自动接管。
# ---------------------------------------------------------------------------
# CORE_LOCK_FD 未持锁恒为 9; 关闭必须经 _xray_core_lock_fd_reset 复位, 防止关错复用 fd。
# ---------------------------------------------------------------------------
export CORE_LOCK_FD=9      # 未持锁时恒为 9: 只用于关闭服务进程继承的 fd(no-op)
# 关闭核心锁 fd 并把全局复位到 9。**每次关闭都必须调用它**, 否则动态号会残留到下次未持锁的调用。
_xray_core_lock_fd_reset() {
    eval "exec ${CORE_LOCK_FD}>&-" 2>/dev/null
    CORE_LOCK_FD=9
    export CORE_LOCK_FD
    return 0
}

# ---------------------------------------------------------------------------
# 跨版本锁: L2(≤0.17.11)在 DEPLOY_DIR 内, L1(0.17.13/0.18.0)在部署父目录。
# 新主锁在锁根; 取主锁后协调已存在旧路径, 不凭空新建旧 flock 文件。
# 不按当前 flock 可用性猜旧后端: flock/mkdir 两路都检查, 占用或身份未知即 fail-closed。
# flock 见证 inode 后再加锁并复核; 无 flock 时先扫描他人打开的旧文件。
# 旧 mkdir 同名标记占位, 释放时删除; SIGKILL 残留仅在匹配 .witness 时可自愈。
# L2 缺失先扫描删除树; 缺失旧 flock 文件后来新建的窗口仍无法封住, 非跨版本结构性消除。
# ---------------------------------------------------------------------------
_xray_legacy_lock_name() {   # <fd变量名> <mkdir变量名> <flock文件> <mkdir目录> <显示名>
    local fdvar="$1" dirvar="$2" lfile="$3" ldir="$4" label="$5" i owner="" ef lrc locked=0
    local witness="" deploy_dir devino
    # **变量名按锁家族分开**: 卸载要同时持 install 锁与 core 锁, 共用全局会让后取的覆盖先取的,
    # 先取那把 fd 再没人关闭/解锁(锁泄漏到进程退出)。
    eval "$fdvar=\"\""
    eval "$dirvar=\"\""
    # L1/L2 均创建临时 mkdir 标记; witness 自愈与缺失 flock 的边界见 _xray_legacy_lock_name 契约。
    if command -v flock >/dev/null 2>&1; then
        # (T1) 旧 flock 文件不存在 ⇒ **绝不为了"协调"新建它**(否则又把锁文件写回 /opt)。
        # 若旧 mkdir 目录存在 ⇒ 旧会话仍在, fail-closed; 否则调用方本就不该调用。
        if [ ! -e "$lfile" ]; then
            if [ -e "$ldir" ]; then
                _error "旧版${label}目录锁仍存在: $ldir"
                _tip "确认没有旧版会话在运行后, 请人工检查并清理该锁目录后重试"
            fi
            return 1
        fi
        # 旧 flock 文件已存在: 用**见证 fd** 记下它此刻的 inode 身份(只读, 不加锁)。
        eval "exec {witness}<\"\$lfile\"" 2>/dev/null || witness=""
        if [ -z "$witness" ]; then
            _error "旧版${label}文件存在但无法打开见证, 放弃本次操作: $lfile"
            return 1
        fi
        if ! eval "exec {${fdvar}}>>\"\$lfile\""; then
            [ -n "$witness" ] && eval "exec ${witness}<&-" 2>/dev/null
            _error "无法打开旧版${label} $lfile, 放弃本次操作"
            return 1
        fi
        eval "ef=\${${fdvar}}"
        # 打开的 fd 必须仍是 T1 见证的 inode, 拒绝路径删除/重建造成的双重持锁。
        if [ -n "$witness" ]; then
            if ! _xray_legacy_lock_identity_ok "$ef" "$witness"; then
                _error "旧版${label}文件在判定后被删除/替换(部署目录正被卸载?), 拒绝继续: $lfile"
                _tip "等对方结束后重试; 本次不做任何落地"
                eval "exec ${witness}<&-" 2>/dev/null
                eval "exec ${ef}>&-" 2>/dev/null
                eval "$fdvar=\"\""
                return 1
            fi
            eval "exec ${witness}<&-" 2>/dev/null
            witness=""
        fi
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            if flock -n "$ef" 2>/dev/null; then locked=1; break; fi
            sleep 1
        done
        if [ "$locked" -ne 1 ]; then
            _error "旧版${label}仍被占用(15s), 可能仍有旧版会话在操作: $lfile"
            _tip "等旧版会话退出后重试(内核会在持有进程退出时自动释放该锁)"
            eval "exec ${ef}>&-" 2>/dev/null
            eval "$fdvar=\"\""
            return 1
        fi
        # 同名 mkdir 标记排斥旧后端; .witness=flock dev:ino, 只有匹配且持有同一 flock 才可接管。
        devino=$(_xray_devino "$lfile" 2>/dev/null)
        if [ -z "$devino" ]; then
            _error "无法读取旧版${label}文件标识(dev:ino), 放弃本次操作: $lfile"
            eval "exec ${ef}>&-" 2>/dev/null
            eval "$fdvar=\"\""
            return 1
        fi
        if [ -e "$ldir" ]; then
            if [ -f "$ldir/.witness" ] && [ "$(cat "$ldir/.witness" 2>/dev/null)" = "$devino" ]; then
                # 同族进程上次持锁时被强杀留下的标记: 此刻已无人持有该 flock ⇒ 安全清理
                rm -rf "$ldir" 2>/dev/null
            fi
        fi
        if [ -e "$ldir" ]; then
            owner=$(cat "$ldir/pid" 2>/dev/null)
            case "$owner" in
                ''|*[!0-9]*) owner="" ;;
                *) case "$owner" in *[1-9]*) ;; *) owner="" ;; esac ;;
            esac
            _error "旧版${label}目录锁仍存在(pid ${owner:-未知}): $ldir"
            _tip "确认没有旧版会话在运行后, 请人工检查并清理该锁目录后重试"
            flock -u "$ef" 2>/dev/null
            eval "exec ${ef}>&-" 2>/dev/null
            eval "$fdvar=\"\""
            return 1
        fi
        if ! mkdir "$ldir" 2>/dev/null; then
            _error "旧版${label}目录锁被占用或无法创建: $ldir"
            _tip "确认没有旧版会话在运行后, 请人工检查该锁目录后重试"
            flock -u "$ef" 2>/dev/null
            eval "exec ${ef}>&-" 2>/dev/null
            eval "$fdvar=\"\""
            return 1
        fi
        # 先写 .witness 再写 pid: 若恰在此刻被杀, 留下"有 witness 无 pid"的目录仍可被同族进程
        # 安全接管; 反过来只能人工处理。任一步写入失败都滚回去(fail-closed)。
        if ! printf '%s\n' "$devino" > "$ldir/.witness" 2>/dev/null; then
            rm -rf "$ldir" 2>/dev/null
            flock -u "$ef" 2>/dev/null
            eval "exec ${ef}>&-" 2>/dev/null
            eval "$fdvar=\"\""
            _error "无法写入旧版${label}见证记录 $ldir/.witness, 放弃本次操作"
            return 1
        fi
        if ! printf '%s\n' "$$" > "$ldir/pid" 2>/dev/null; then
            rm -rf "$ldir" 2>/dev/null
            flock -u "$ef" 2>/dev/null
            eval "exec ${ef}>&-" 2>/dev/null
            eval "$fdvar=\"\""
            _error "无法写入旧版${label}持有者记录 $ldir/pid, 放弃本次操作"
            return 1
        fi
        eval "$dirvar=\"\$ldir\""
        return 0
    fi
    # 无 flock: 旧版可能走 mkdir 目录锁, 但仍先检查旧 flock 文件是否被某进程打开。
    # 无 flock 时只能阻止已存在的旧 flock 持有者; 同环境旧版也无 flock 时 mkdir 标记提供完整互斥。
    if [ -e "$lfile" ] && ! declare -F _xray_legacy_flock_active >/dev/null 2>&1; then
        _error "无法确认旧版${label} flock 文件是否空闲(缺少检查助手): $lfile"
        return 1
    fi
    if [ -e "$lfile" ] && declare -F _xray_legacy_flock_active >/dev/null 2>&1; then
        _xray_legacy_flock_active "$lfile"; lrc=$?
        case "$lrc" in
            0|2)
                _error "旧版${label}不可确认空闲(旧 flock 文件: $lfile), 放弃本次操作"
                _tip "确认没有旧版会话在运行后, 请人工检查旧锁现场并重试"
                return 1
                ;;
        esac
    fi
    # 旧版 mkdir 目录已存在 ⇒ 活持有者/残留一律拒绝, 绝不删除别人的锁目录(树内外同口径)。
    if [ -e "$ldir" ]; then
        owner=$(cat "$ldir/pid" 2>/dev/null)
        case "$owner" in
            ''|*[!0-9]*) owner="" ;;
            *) case "$owner" in *[1-9]*) ;; *) owner="" ;; esac ;;
        esac
        _error "旧版${label}目录锁仍存在(pid ${owner:-未知}): $ldir"
        _tip "确认没有旧版会话在运行后, 请人工检查并清理该锁目录后重试"
        return 1
    fi
    # 无 flock: 创建旧 mkdir 目录前先跑删除树扫描 —— 与 flock 分支"即将新建 inode"同口径。
    # 删除树扫描根固定 DEPLOY_DIR; L1 在树外, 不得扫描整个部署父目录并误伤其它软件。
    deploy_dir="${DEPLOY_DIR%/}"
    if _xray_legacy_deleted_tree_active "$deploy_dir"; then
        _error "检测到旧版进程仍持有已删除部署树的文件, 拒绝新建旧版${label}目录: $ldir"
        _tip "等旧版会话结束后重试"
        return 1
    fi
    # 无 flock: 旧版走的是 mkdir 目录锁。活持有者/残留一律拒绝, 绝不删除别人的锁目录。
    if ! mkdir "$ldir" 2>/dev/null; then
        _error "旧版${label}不可用: $ldir"
        _tip "确认没有旧版会话在运行后, 请人工检查并清理该锁目录后重试"
        return 1
    fi
    if ! printf '%s\n' "$$" > "$ldir/pid" 2>/dev/null; then
        rm -f "$ldir/pid" 2>/dev/null
        rmdir "$ldir" 2>/dev/null
        _error "无法写入旧版${label}持有者记录 $ldir/pid, 放弃本次操作"
        return 1
    fi
    eval "$dirvar=\"\$ldir\""
    return 0
}

# <path> 被其他进程打开为 fd: 0=有, 1=没有, 2=无法确认。
_xray_legacy_flock_active() {
    local p pid target want="$1" matches find_rc
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
        [ "$pid" = "$$" ] && continue
        target=$(readlink "$p" 2>/dev/null) || return 2
        [ "$target" = "$want" ] && return 0
    done
    return 1
}

# 加锁后复核 fd 与路径 inode, 删除/替换或不可读即 fail-closed, 防止已解除链接的锁双重放行。
_xray_legacy_lock_inode_ok() {   # <fd> <path>; 0 = 我们持有的 fd 仍指向该路径上的文件
    local fd="$1" p="$2" t
    [ -n "$fd" ] && [ -n "$p" ] || return 0
    [ -e "$p" ] || return 1
    t=$(readlink "/proc/self/fd/$fd" 2>/dev/null) || return 1
    case "$t" in
        "$p") return 0 ;;
        *" (deleted)") return 1 ;;
        *) return 1 ;;
    esac
}

# fd 必须与创建动作前打开的 T1 witness 同 inode; 仅 fd 与当前路径相符不够。
# /proc 不可读则无法确认并拒绝。
_xray_legacy_lock_identity_ok() {   # <fd> <见证fd>; 0 = 同一 inode
    local fd="$1" wfd="$2"
    [ -n "$fd" ] && [ -n "$wfd" ] || return 1
    [ "/proc/self/fd/$fd" -ef "/proc/self/fd/$wfd" ]
}

# 路径的 dev:ino 标识(用于 mkdir 标记的自愈判定)。取不到输出空; 调用方必须 fail-closed。
_xray_devino() { stat -c '%d:%i' "$1" 2>/dev/null; }

_xray_legacy_lock_release() {   # <fd变量名> <mkdir变量名>
    local fdvar="$1" dirvar="$2" ef d owner rc=0
    eval "d=\${${dirvar}:-}"
    if [ -n "$d" ]; then
        owner=$(cat "$d/pid" 2>/dev/null) || owner=""
        if [ "$owner" = "$$" ]; then
            # 先删本进程确认持有的旧 mkdir 见证, 再解 flock; 反序会让新 flock 持有者
            # 在旧 marker 尚未释放时误判/接管, 留下跨后端交错窗口。
            if ! rm -rf "$d" 2>/dev/null || [ -e "$d" ] || [ -L "$d" ]; then
                _error "无法移除本进程持有的旧锁见证目录: $d"
                rc=1
            else
                eval "$dirvar=\"\""
            fi
        elif [ -e "$d" ] || [ -L "$d" ]; then
            _error "旧锁见证目录归属不匹配, 保留: $d"
            rc=1
            eval "$dirvar=\"\""
        else
            eval "$dirvar=\"\""
        fi
    fi
    eval "ef=\${${fdvar}:-}"
    if [ -n "$ef" ]; then
        flock -u "$ef" 2>/dev/null
        eval "exec ${ef}>&-" 2>/dev/null
        eval "$fdvar=\"\""
    fi
    return "$rc"
}

# 旧版进程不认识部署目录外的新锁, 可能已持目录内锁并把整棵部署树删掉; 此时在路径上重建同名
# 锁文件不能与旧 fd 互斥。故重建旧锁路径前, 扫描仍指向已删除部署文件的进程, 命中即 fail-closed。
# 该检测只缩小旧版残留窗口, 不构成跨版本竞态的结构性消除。
_xray_legacy_deleted_tree_active() {   # <deploy_dir>; 0 = 其他进程仍持有已删除树中的 fd
    local root="${1%/}" p pid target prefix matches find_rc
    [ -n "$root" ] || return 1
    prefix="${root}/"
    if command -v find >/dev/null 2>&1; then
        matches=$(find /proc/[0-9]*/fd -type l -lname "${prefix}* (deleted)" -print -quit 2>/dev/null)
        find_rc=$?
        if [ "$find_rc" -eq 0 ]; then
            [ -n "$matches" ] && return 0
            return 1
        fi
    fi
    for p in /proc/[0-9]*/fd/*; do
        pid=${p#/proc/}; pid=${pid%%/*}
        [ "$pid" = "$$" ] && continue
        # fd 在扫描期间被并发关闭是常态, 读不到就跳过(不是"发现旧进程")。判定主力是
        # 上面的 `find` 快路径: 它一次遍历完成, 不受这种逐 fd 竞态影响。
        target=$(readlink "$p" 2>/dev/null) || continue
        case "$target" in
            "$prefix"*" (deleted)") return 0 ;;
        esac
    done
    return 1
}

_with_core_lock() {
    local deploy_path="${DEPLOY_DIR%/}" deploy_parent deploy_name lockf fallback_dir
    local legacy_lockf legacy_fallback_dir legacy1_lockf legacy1_fallback_dir i locked=0 rc owner lrc
    local XD_CORE_LEGACY_FLOCK_FD="" XD_CORE_LEGACY_DIR=""
    local XD_CORE_LEGACY1_FLOCK_FD="" XD_CORE_LEGACY1_DIR=""
    case "$deploy_path" in
        /*) ;;
        *) _error "部署目录必须是绝对路径, 无法建立核心锁: $DEPLOY_DIR"; return 1 ;;
    esac
    if [ -z "$deploy_path" ] || [ "$deploy_path" = "/" ]; then
        _error "部署目录路径无效, 无法建立核心锁: $DEPLOY_DIR"
        return 1
    fi
    deploy_parent="${deploy_path%/*}"
    deploy_name="${deploy_path##*/}"
    [ -n "$deploy_parent" ] || deploy_parent="/"
    lockf="$(_deploy_lock_root)/core.lock"
    fallback_dir="$(_deploy_lock_root)/core.lock.d"
    legacy_lockf="$deploy_path/.core.lock"
    legacy_fallback_dir="$deploy_path/.core.lock.d"
    # L1(0.17.13/0.18.0): 旧版把核心锁放在部署父目录下 `.<name>.core.lock`。
    legacy1_lockf="${deploy_parent}/.${deploy_name}.core.lock"
    legacy1_fallback_dir="${legacy1_lockf}.d"
    # 已是持锁状态(嵌套调用) ⇒ 直接跑, 不再重复加锁。
    # 嵌套判定必须在 `$DEPLOY_DIR` 存在性检查**之前**: 卸载主体(持锁中)会 `rm -rf "$DEPLOY_DIR"`,
    # 之后的嵌套调用(收尾/提示)在外层事务锁保护下, 不该因目录已被删除而报错。
    if [ "${XRAY_DEPLOY_CORE_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    if ! mkdir -p "$(dirname "$lockf")" 2>/dev/null; then
        _error "无法创建核心锁目录 $(dirname "$lockf"), 放弃本次操作"
        return 1
    fi

    if command -v flock >/dev/null 2>&1; then
        if ! eval "exec {CORE_LOCK_FD}>>\"\$lockf\""; then
            _error "无法创建核心锁文件 $lockf(目录不可写?), 放弃本次操作"
            return 1
        fi
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            if flock -n "$CORE_LOCK_FD" 2>/dev/null; then locked=1; break; fi
            sleep 1
        done
        if [ "$locked" -ne 1 ]; then
            _error "等待核心锁超时(15s), 可能有其他 xd 会话正在切换核心"
            # 超时路径同样要关掉刚打开的 fd: 菜单是长驻循环, 漏掉会让每次失败泄漏一个 fd,
            # 最终撞上 ulimit。复位全局见 helper。
            _xray_core_lock_fd_reset
            return 1
        fi
        # 主锁后才检查部署存在性; 已卸载则 fail-closed, 不重建部署树。
        if [ ! -d "$deploy_path" ]; then
            _error "部署目录不存在, 放弃本次操作: $deploy_path"
            _xray_core_lock_fd_reset
            return 1
        fi
        # 仅协调已存在 L1/L2 旧路径; L2 缺失补删除树扫描, 见 _xray_legacy_lock_name。
        if [ ! -e "$legacy_lockf" ] && [ ! -e "$legacy_fallback_dir" ]; then
            if _xray_legacy_deleted_tree_active "$deploy_path"; then
                _error "检测到旧版进程仍持有已删除部署树的文件, 放弃本次操作"
                _tip "等旧版会话退出后重试"
                _xray_core_lock_fd_reset
                return 1
            fi
        fi
        if [ -e "$legacy_lockf" ] || [ -e "$legacy_fallback_dir" ]; then
            if ! _xray_legacy_lock_name XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR \
                "$legacy_lockf" "$legacy_fallback_dir" "核心锁"; then
                _xray_core_lock_fd_reset
                return 1
            fi
            # 同 install 锁: 旧版会话/卸载可能在打开后删掉该文件, 复核 inode 身份。
            if ! _xray_legacy_lock_inode_ok "${XD_CORE_LEGACY_FLOCK_FD:-}" "$legacy_lockf"; then
                _error "旧版核心锁文件在获取后被替换/删除: $legacy_lockf"
                _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
                _xray_core_lock_fd_reset
                return 1
            fi
        fi
        if [ -e "$legacy1_lockf" ] || [ -e "$legacy1_fallback_dir" ]; then
            if ! _xray_legacy_lock_name XD_CORE_LEGACY1_FLOCK_FD XD_CORE_LEGACY1_DIR \
                "$legacy1_lockf" "$legacy1_fallback_dir" "旧版L1核心锁"; then
                _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
                _xray_core_lock_fd_reset
                return 1
            fi
            if ! _xray_legacy_lock_inode_ok "${XD_CORE_LEGACY1_FLOCK_FD:-}" "$legacy1_lockf"; then
                _error "旧版L1核心锁文件在获取后被替换/删除: $legacy1_lockf"
                _xray_legacy_lock_release XD_CORE_LEGACY1_FLOCK_FD XD_CORE_LEGACY1_DIR
                _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
                _xray_core_lock_fd_reset
                return 1
            fi
        fi
        if ! _xray_primary_flock_marker_take "$CORE_LOCK_FD" "$lockf" "$fallback_dir" "核心锁"; then
            _xray_legacy_lock_release XD_CORE_LEGACY1_FLOCK_FD XD_CORE_LEGACY1_DIR
            _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
            _xray_core_lock_fd_reset
            return 1
        fi



        # 子 shell 内执行: 使 CORE_LOCK_FD 与 HELD 标记的作用域跟着这次加锁一起消失,
        # 调用方不必手工回滚环境(与 _with_config_lock 同款做法)。
        (
            XRAY_DEPLOY_CORE_LOCK_HELD=1
            export XRAY_DEPLOY_CORE_LOCK_HELD
            "$@"
        )
        rc=$?
        _xray_legacy_lock_release XD_CORE_LEGACY1_FLOCK_FD XD_CORE_LEGACY1_DIR
        _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
        _xray_primary_flock_marker_release "$lockf" "$fallback_dir" "核心锁" || rc=1
        _xray_core_lock_fd_reset
        return "$rc"
    fi

    # 裁剪版 BusyBox 可能没有 flock: 用独立 mkdir 锁目录并**永不自动接管** —— SIGKILL 残留
    # 宁可要求人工确认/清理, 也不能用 read→rm→mkdir 的竞态冒险双重放行。
    if ! mkdir "$fallback_dir" 2>/dev/null; then
        if [ -d "$fallback_dir" ]; then
            _error "核心锁目录已存在(可能有其他会话运行, 或上次被强制终止): $fallback_dir"
        else
            _error "核心锁路径已被非目录对象占用: $fallback_dir"
        fi
        _tip "确认没有核心安装、卸载或服务操作后, 请手动删除锁目录: rm -rf -- '$fallback_dir'"
        return 1
    fi
    if ! printf '%s\n' "$$" > "$fallback_dir/pid" 2>/dev/null; then
        rm -f "$fallback_dir/pid" 2>/dev/null
        rmdir "$fallback_dir" 2>/dev/null
        _error "无法写入核心锁持有者记录 $fallback_dir/pid, 放弃本次操作"
        return 1
    fi
    if ! declare -F _xray_legacy_flock_active >/dev/null 2>&1; then
        _error "无法确认核心 flock 主锁是否空闲(缺少 /proc 检查助手), 放弃本次操作"
        rm -f "$fallback_dir/pid" 2>/dev/null; rmdir "$fallback_dir" 2>/dev/null
        return 1
    fi
    _xray_legacy_flock_active "$lockf"; lrc=$?
    case "$lrc" in
        0|2)
            _error "核心 flock 主锁被占用或无法确认, 放弃本次操作"
            rm -f "$fallback_dir/pid" 2>/dev/null; rmdir "$fallback_dir" 2>/dev/null
            return 1
            ;;
    esac
    # 同 flock 路径: 目录存在性在**锁内**判定(锁外判断会与并发卸载竞态), 锁内不存在则 fail-closed
    # 退出且不重建目录。
    if [ ! -d "$deploy_path" ]; then
        _error "部署目录不存在, 放弃本次操作: $deploy_path"
        rm -f "$fallback_dir/pid" 2>/dev/null
        rmdir "$fallback_dir" 2>/dev/null
        return 1
    fi
    # 旧版锁协调(仅对已存在的旧路径; 不存在则跳过, 不凭空重建旧锁文件); L2 不存在时补删除树扫描。
    if [ ! -e "$legacy_lockf" ] && [ ! -e "$legacy_fallback_dir" ]; then
        if _xray_legacy_deleted_tree_active "$deploy_path"; then
            _error "检测到旧版进程仍持有已删除部署树的文件, 放弃本次操作"
            _tip "等旧版会话退出后重试"
            rm -f "$fallback_dir/pid" 2>/dev/null
            rmdir "$fallback_dir" 2>/dev/null
            return 1
        fi
    fi
    if [ -e "$legacy_lockf" ] || [ -e "$legacy_fallback_dir" ]; then
        if ! _xray_legacy_lock_name XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR \
                "$legacy_lockf" "$legacy_fallback_dir" "核心锁"; then
            rm -f "$fallback_dir/pid" 2>/dev/null
            rmdir "$fallback_dir" 2>/dev/null
            return 1
        fi
    fi
    if [ -e "$legacy1_lockf" ] || [ -e "$legacy1_fallback_dir" ]; then
        if ! _xray_legacy_lock_name XD_CORE_LEGACY1_FLOCK_FD XD_CORE_LEGACY1_DIR \
                "$legacy1_lockf" "$legacy1_fallback_dir" "旧版L1核心锁"; then
            _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
            rm -f "$fallback_dir/pid" 2>/dev/null
            rmdir "$fallback_dir" 2>/dev/null
            return 1
        fi
    fi
    (
        XRAY_DEPLOY_CORE_LOCK_HELD=1
        export XRAY_DEPLOY_CORE_LOCK_HELD
        "$@"
    )
    rc=$?
    _xray_legacy_lock_release XD_CORE_LEGACY1_FLOCK_FD XD_CORE_LEGACY1_DIR
    _xray_legacy_lock_release XD_CORE_LEGACY_FLOCK_FD XD_CORE_LEGACY_DIR
    owner=$(cat "$fallback_dir/pid" 2>/dev/null)
    if [ "$owner" != "$$" ] || ! rm -f "$fallback_dir/pid" 2>/dev/null || ! rmdir "$fallback_dir" 2>/dev/null; then
        _error "核心锁释放失败或所有权记录不匹配, 锁目录保留: $fallback_dir"
        _tip "确认没有核心操作仍在运行后, 请手动检查并清理该锁目录"
        return 1
    fi
    return "$rc"
}

# 与 install.sh 同一部署树外安装锁; 卸载锁序 install → config → core。
# flock/mkdir 与旧路径协调语义须一致, 见 _xray_legacy_lock_name。
_with_deploy_install_lock() {
    local deploy_path="${DEPLOY_DIR%/}" deploy_parent deploy_name lock_dir lock_file
    local legacy_lock_file legacy_lock_dir legacy1_lock_file legacy1_lock_dir
    local DEPLOY_INSTALL_LOCK_FD="" i locked=0 owner tmp rc lrc
    local XD_INSTALL_LEGACY_FLOCK_FD="" XD_INSTALL_LEGACY_DIR=""
    local XD_INSTALL_LEGACY1_FLOCK_FD="" XD_INSTALL_LEGACY1_DIR=""
    case "$deploy_path" in
        /*) ;;
        *) _error "部署目录必须是绝对路径, 无法建立安装锁: $DEPLOY_DIR"; return 1 ;;
    esac
    if [ -z "$deploy_path" ] || [ "$deploy_path" = "/" ]; then
        _error "部署目录路径无效, 无法建立安装锁: $DEPLOY_DIR"
        return 1
    fi
    deploy_parent="${deploy_path%/*}"
    deploy_name="${deploy_path##*/}"
    [ -n "$deploy_parent" ] || deploy_parent="/"
    lock_dir="$(_deploy_lock_root)/install.lock"
    lock_file="$(_deploy_lock_root)/install.lock.fd"
    legacy_lock_file="$deploy_path/.install.lock.fd"
    legacy_lock_dir="$deploy_path/.install.lock"
    legacy1_lock_file="${deploy_parent}/.${deploy_name}.install.lock.fd"
    legacy1_lock_dir="${deploy_parent}/.${deploy_name}.install.lock"
    if [ "${XRAY_DEPLOY_INSTALL_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || {
        _error "无法创建安装锁目录 $(dirname "$lock_file"), 放弃本次卸载"
        return 1
    }
    # 主锁文件在目录外, 竞争者不会被卸载的 `rm -rf` 拆成新旧 inode; 部署目录不在这里创建 ——
    # 旧版锁在目录内, "先拿主锁再建目录再取旧锁"见下面两条分支。

    if command -v flock >/dev/null 2>&1; then
        if ! eval "exec {DEPLOY_INSTALL_LOCK_FD}>>\"\$lock_file\""; then
            _error "无法创建安装锁文件 $lock_file, 放弃本次卸载"
            return 1
        fi
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            if flock -n "$DEPLOY_INSTALL_LOCK_FD" 2>/dev/null; then locked=1; break; fi
            sleep 1
        done
        if [ "$locked" -ne 1 ]; then
            _error "等待部署安装锁超时(15s), 可能有 install.sh 正在更新"
            eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
            return 1
        fi
        if ! _xray_primary_flock_marker_take "$DEPLOY_INSTALL_LOCK_FD" "$lock_file" "$lock_dir" "安装锁"; then
            eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
            return 1
        fi
        # 主锁 → L2 缺失时删除树扫描 → 建部署树 → 旧锁, 防止重建路径掩盖未释放旧 inode。
        if [ ! -e "$legacy_lock_file" ] && [ ! -e "$legacy_lock_dir" ]; then
            if _xray_legacy_deleted_tree_active "$deploy_path"; then
                _error "检测到旧版进程仍持有已删除部署树的文件, 放弃本次操作"
                _tip "等旧版会话退出后重试"
                _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || :
                eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
                return 1
            fi
        fi
        if ! mkdir -p "$deploy_path" 2>/dev/null; then
            _error "无法创建部署目录 $deploy_path, 放弃本次操作"
            _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || :
            eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
            return 1
        fi
        # 同一种手段再取旧版锁(**仅对已存在的旧路径**; 不存在则跳过, 不凭空重建旧锁文件),
        # 否则旧版 install.sh 会与新版各持一把锁同时落地。L2(<=0.17.11 目录内) 与 L1(父目录)。
        if [ -e "$legacy_lock_file" ] || [ -e "$legacy_lock_dir" ]; then
            if ! _xray_legacy_lock_name XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR \
                "$legacy_lock_file" "$legacy_lock_dir" "安装锁"; then
                _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || :
                eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
                return 1
            fi
            # 旧版卸载者可能在打开锁文件后 rm -rf 整棵树并删掉该锁文件 ⇒ 复核 inode 身份,
            # 不一致就拒绝。
            if ! _xray_legacy_lock_inode_ok "${XD_INSTALL_LEGACY_FLOCK_FD:-}" "$legacy_lock_file"; then
                _error "旧版安装锁文件在获取后被替换/删除(部署目录正被卸载?): $legacy_lock_file"
                _tip "等对方结束后重试; 本次不做任何落地"
                _xray_legacy_lock_release XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR
                _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || :
                eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
                return 1
            fi
        fi
        if [ -e "$legacy1_lock_file" ] || [ -e "$legacy1_lock_dir" ]; then
            if ! _xray_legacy_lock_name XD_INSTALL_LEGACY1_FLOCK_FD XD_INSTALL_LEGACY1_DIR \
                "$legacy1_lock_file" "$legacy1_lock_dir" "旧版L1安装锁"; then
                _xray_legacy_lock_release XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR
                _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || :
                eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
                return 1
            fi
            if ! _xray_legacy_lock_inode_ok "${XD_INSTALL_LEGACY1_FLOCK_FD:-}" "$legacy1_lock_file"; then
                _error "旧版L1安装锁文件在获取后被替换/删除(部署目录正被卸载?): $legacy1_lock_file"
                _xray_legacy_lock_release XD_INSTALL_LEGACY1_FLOCK_FD XD_INSTALL_LEGACY1_DIR
                _xray_legacy_lock_release XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR
                _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || :
                eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
                return 1
            fi
        fi
        (
            XRAY_DEPLOY_INSTALL_LOCK_HELD=1
            export XRAY_DEPLOY_INSTALL_LOCK_HELD
            "$@"
        )
        rc=$?
        _xray_legacy_lock_release XD_INSTALL_LEGACY1_FLOCK_FD XD_INSTALL_LEGACY1_DIR
        _xray_legacy_lock_release XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR
        _xray_primary_flock_marker_release "$lock_file" "$lock_dir" "安装锁" || rc=1
        eval "exec ${DEPLOY_INSTALL_LOCK_FD}>&-" 2>/dev/null
        return "$rc"
    fi

    # 与 install.sh 相同: 无 flock 时 mkdir 锁按 PID 有界等待活持有者, 对死锁/未知锁立即
    # fail-closed, **永不自动接管**。SIGKILL 残留需人工确认后清理。
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if mkdir "$lock_dir" 2>/dev/null; then
            tmp="$lock_dir/.pid.$$"
            if ! printf '%s\n' "$$" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$lock_dir/pid" 2>/dev/null; then
                rm -f "$tmp" "$lock_dir/pid" 2>/dev/null
                rmdir "$lock_dir" 2>/dev/null
                _error "无法写入安装锁持有者记录 $lock_dir/pid, 放弃本次卸载"
                return 1
            fi
            if ! declare -F _xray_legacy_flock_active >/dev/null 2>&1; then
                _error "无法确认安装 flock 主锁是否空闲(缺少 /proc 检查助手), 放弃本次卸载"
                rm -f "$lock_dir/pid" 2>/dev/null; rmdir "$lock_dir" 2>/dev/null
                return 1
            fi
            _xray_legacy_flock_active "$lock_file"; lrc=$?
            case "$lrc" in
                0|2)
                    _error "安装 flock 主锁被占用或无法确认, 放弃本次卸载"
                    rm -f "$lock_dir/pid" 2>/dev/null; rmdir "$lock_dir" 2>/dev/null
                    return 1
                    ;;
            esac
            # 旧版锁协调(仅对已存在的旧路径; 不存在则跳过); L2 不存在时补删除树扫描, 再建目录。
            if [ ! -e "$legacy_lock_file" ] && [ ! -e "$legacy_lock_dir" ]; then
                if _xray_legacy_deleted_tree_active "$deploy_path"; then
                    _error "检测到旧版进程仍持有已删除部署树的文件, 放弃本次操作"
                    _tip "等旧版会话退出后重试"
                    rm -f "$lock_dir/pid" 2>/dev/null
                    rmdir "$lock_dir" 2>/dev/null
                    return 1
                fi
            fi
            if ! mkdir -p "$deploy_path" 2>/dev/null; then
                _error "无法创建部署目录 $deploy_path, 放弃本次操作"
                rm -f "$lock_dir/pid" 2>/dev/null
                rmdir "$lock_dir" 2>/dev/null
                return 1
            fi
            if [ -e "$legacy_lock_file" ] || [ -e "$legacy_lock_dir" ]; then
                if ! _xray_legacy_lock_name XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR \
                    "$legacy_lock_file" "$legacy_lock_dir" "安装锁"; then
                    rm -f "$lock_dir/pid" 2>/dev/null
                    rmdir "$lock_dir" 2>/dev/null
                    return 1
                fi
            fi
            if [ -e "$legacy1_lock_file" ] || [ -e "$legacy1_lock_dir" ]; then
                if ! _xray_legacy_lock_name XD_INSTALL_LEGACY1_FLOCK_FD XD_INSTALL_LEGACY1_DIR \
                    "$legacy1_lock_file" "$legacy1_lock_dir" "旧版L1安装锁"; then
                    _xray_legacy_lock_release XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR
                    rm -f "$lock_dir/pid" 2>/dev/null
                    rmdir "$lock_dir" 2>/dev/null
                    return 1
                fi
            fi
            (
                XRAY_DEPLOY_INSTALL_LOCK_HELD=1
                export XRAY_DEPLOY_INSTALL_LOCK_HELD
                "$@"
            )
            rc=$?
            _xray_legacy_lock_release XD_INSTALL_LEGACY1_FLOCK_FD XD_INSTALL_LEGACY1_DIR
            _xray_legacy_lock_release XD_INSTALL_LEGACY_FLOCK_FD XD_INSTALL_LEGACY_DIR
            owner=$(cat "$lock_dir/pid" 2>/dev/null)
            if [ "$owner" != "$$" ] || ! rm -f "$lock_dir/pid" 2>/dev/null || ! rmdir "$lock_dir" 2>/dev/null; then
                _error "安装锁释放失败或所有权记录不匹配, 锁目录保留: $lock_dir"
                _tip "确认没有安装/卸载操作仍在运行后, 请手动检查该锁目录"
                return 1
            fi
            return "$rc"
        fi
        if [ ! -d "$lock_dir" ]; then
            _error "安装锁路径被非目录对象占用: $lock_dir"


            _tip "请手动检查该路径后重试本次卸载"
            return 1
        fi
        owner=$(cat "$lock_dir/pid" 2>/dev/null)
        case "$owner" in
            ''|*[!0-9]*) owner="" ;;
            *) case "$owner" in *[1-9]*) ;; *) owner="" ;; esac ;;
        esac
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
            if [ "$i" -eq 14 ]; then
                _error "另一个 install.sh 正在运行(pid $owner), 本次卸载中止"
                _tip "若确认进程已退出, 请先人工检查并清理: $lock_dir"
                return 1
            fi
            sleep 1
            continue
        fi
        _error "检测到无人持有或无法判定的安装锁: $lock_dir"
        _tip "确认没有 install.sh 正在运行后, 请手动检查并清理该锁目录"
        return 1
    done
    _error "等待部署安装锁超时, 本次卸载中止: $lock_dir"
    return 1
}

# ---------------------------------------------------------------------------
# journal 覆盖 SIGKILL/OOM/掉电后的恢复; 按盘上事实收敛, 不靠同步失败分支。
# 单向 phase:
#   core: prepared → snapshotted → replacing → binary_replaced → service_replaced
#         → restart_verified → committed → cleanup → 删除 journal
#   geo: prepared → snapshotted → replacing → geo_replaced → restart_verified → committed → cleanup
#   rollback: replacing / mutation 后置 phase → rolled_back → cleanup
# prepared/snapshotted: 生产态未触碰, 只清理; replacing: durable mutation barrier, 此后可能部分改动。
# *_replaced/restart_verified: 未 committed 崩溃则回滚; committed/rolled_back 不可逆, 仅幂等 cleanup。
# 终态须先落盘再删恢复源; disk_ok(binary/service/geo)与 run_ok(runtime/版本)均须收敛。
# 不完整返回 1 并保留 journal/恢复源, 禁止新事务; 非法账本隔离 .corrupt 并告警, 不猜动作。
# 账本存 STATE_DIR(700); quarantine 的 BLOCKED 先落盘契约见 _xray_core_journal_quarantine。
# ---------------------------------------------------------------------------
_xray_core_journal_path() { printf '%s' "$STATE_DIR/coretxn.json"; }
_xray_core_blocked_path() { printf '%s' "$STATE_DIR/coretxn.blocked"; }
_xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }

_xray_core_fsync_file_dir() {  # best-effort durability for an artifact and its containing directory
    local p="$1"
    [ -n "$p" ] || return 0
    if _xray_core_path_present "$p"; then _fsync_path "$p" || :; fi
    _fsync_path "$(dirname "$p")" || :
    return 0
}

_xray_core_snapshots_fsync() {  # <journal>; called before phase=snapshotted
    local j="$1" binbak stage sprev gip gsp operation f
    binbak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    gip=$(jq -r '.geoip_backup' "$j" 2>/dev/null) || return 1
    gsp=$(jq -r '.geosite_backup' "$j" 2>/dev/null) || return 1
    operation=$(jq -r '.operation // "core"' "$j" 2>/dev/null) || return 1
    for f in "$binbak" "$sprev" "${sprev}.absent" "${sprev}.enabled" "${sprev}.masked" "$gip" "$gsp"; do
        _xray_core_path_present "$f" && _xray_core_fsync_file_dir "$f"
    done
    case "$operation" in
        core) _xray_core_fsync_file_dir "$stage/xray" ;;
        geo)
            _xray_core_fsync_file_dir "$stage/geoip.dat"
            _xray_core_fsync_file_dir "$stage/geosite.dat"
            ;;
    esac
    _xray_core_fsync_file_dir "$stage"
    return 0
}

_xray_core_production_fsync() {  # <journal>; best effort before terminal phase/cleanup
    local j="$1" operation bin unit
    operation=$(jq -r '.operation // "core"' "$j" 2>/dev/null) || return 1
    case "$operation" in
        core)
            bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
            unit=$(jq -r '.unit // empty' "$j" 2>/dev/null) || unit=""
            _xray_core_fsync_file_dir "$bin"
            _xray_core_fsync_file_dir "$ASSET_DIR/geoip.dat"
            _xray_core_fsync_file_dir "$ASSET_DIR/geosite.dat"
            [ -z "$unit" ] || _xray_core_fsync_file_dir "$unit"
            _xray_core_fsync_file_dir "$STATE_DIR/version"
            _xray_core_fsync_file_dir "$STATE_DIR/channel"
            ;;
        geo)
            _xray_core_fsync_file_dir "$ASSET_DIR/geoip.dat"
            _xray_core_fsync_file_dir "$ASSET_DIR/geosite.dat"
            ;;
        *) return 1 ;;
    esac
    return 0
}


# 写新账本。调用前必须已过 core lock + pending gate。账本写入拒绝覆盖任何旧 journal。
# 参数: <old_version> <old_channel> <new_tag> <channel> <staging_dir>
_xray_core_journal_write() {  # <old_version> <old_channel> <new_tag> <channel> <staging_dir> [core|geo]
    local old_ver="$1" old_ch="$2" new_tag="$3" new_ch="$4" stage="$5" operation="${6:-core}"
    local j payload txn_id binary_preexisting runtime_was_running=false old_state_ver unit sprev
    local geoip_pre geosite_pre service_pre=false service_masked=false
    case "$operation" in core|geo) ;; *) _error "未知核心事务 operation: $operation"; return 1 ;; esac
    j=$(_xray_core_journal_path)
    _xray_core_path_present "$j" && { _error "核心事务账本已存在, 拒绝覆盖: $j"; return 1; }
    _xray_core_path_present "$(_xray_core_blocked_path)" && { _error "核心事务处于 BLOCKED, 拒绝新建账本"; return 1; }
    _xray_core_path_present "${j}.corrupt" && { _error "存在损坏的核心事务账本, 拒绝新建事务: ${j}.corrupt"; return 1; }
    _xray_core_path_present "$XRAY_BIN.bak" && { _error "发现未归属的旧二进制备份, 拒绝覆盖: $XRAY_BIN.bak"; return 1; }
    [ ! -L "$XRAY_BIN" ] || { _error "Xray binary 路径是符号链接, 无法安全快照: $XRAY_BIN"; return 1; }
    [ ! -L "$ASSET_DIR/geoip.dat" ] && [ ! -L "$ASSET_DIR/geosite.dat" ] || {
        _error "geo dat 是符号链接, 无法安全建立事务快照"; return 1; }

    txn_id="$(date +%s).$$.${RANDOM}"
    XRAY_CORE_TXN_ID="$txn_id"; export XRAY_CORE_TXN_ID
    if [ "$operation" = geo ]; then
        stage="$ASSET_DIR/.xray-geo-txn.${txn_id}"
        ! _xray_core_path_present "$stage" || { _error "Geo 事务暂存目录已存在, 拒绝覆盖: $stage"; return 1; }
    fi
    sprev=$(_xray_service_prev_path)
    unit=$(_xray_service_unit_path 2>/dev/null || printf '')
    if [ -n "$unit" ] && _xray_core_path_present "$unit"; then
        # A masked unit is not a valid service snapshot source. The installer
        # records it as an absent unit and removes the stale mask before writing.
        if [ "${INIT_SYSTEM:-}" = systemd ] && _xray_service_is_masked "$unit"; then
            service_masked=true
        else
            service_pre=true
        fi
    fi
    geoip_pre=false; geosite_pre=false
    [ -f "$XRAY_BIN" ] && binary_preexisting=true || binary_preexisting=false
    if ! declare -F _xray_is_running >/dev/null 2>&1; then
        _error "缺少 Xray 进程状态探测, 无法安全记录事务 pre-state"; return 1
    fi
    if _xray_is_running; then runtime_was_running=true; fi
    if [ "$binary_preexisting" = false ] && [ "$runtime_was_running" = true ]; then
        _error "检测到运行中的 Xray 但磁盘 binary 不存在, 当前 pre-state 无法安全回滚"; return 1
    fi
    # 记录 state pre-state 时, 文件存在但读取失败绝不等同于"原本没有 state"。
    # 直接检查 cat 返回码, 避免 _state_get 的管道末端 tr 掩盖上游读取错误。
    if _xray_core_path_present "$STATE_DIR/version"; then
        [ ! -L "$STATE_DIR/version" ] || { _error "version state 是符号链接, 无法安全快照"; return 1; }
        old_state_ver=$(cat "$STATE_DIR/version" 2>/dev/null) || { _error "读取 version state 失败, 核心事务中止"; return 1; }
        old_state_ver=${old_state_ver//$'\n'/}
    else
        old_state_ver=""
    fi
    if _xray_core_path_present "$STATE_DIR/channel"; then
        [ ! -L "$STATE_DIR/channel" ] || { _error "channel state 是符号链接, 无法安全快照"; return 1; }
        old_ch=$(cat "$STATE_DIR/channel" 2>/dev/null) || { _error "读取 channel state 失败, 核心事务中止"; return 1; }
        old_ch=${old_ch//$'\n'/}
    else
        old_ch=""
    fi
    [ -f "$ASSET_DIR/geoip.dat" ] && geoip_pre=true
    [ -f "$ASSET_DIR/geosite.dat" ] && geosite_pre=true
    payload=$(jq -n \
        --arg id "$txn_id" --arg ov "$old_ver" --arg osv "$old_state_ver" --arg oc "$old_ch" \
        --arg nt "$new_tag" --arg nc "$new_ch" --arg bin "$XRAY_BIN" --arg bak "${XRAY_BIN}.bak" \
        --arg unit "$unit" --arg sprev "$sprev" --arg stage "$stage" \
        --arg gip "$ASSET_DIR/.geoip.dat.coretxn.${txn_id}.bak" \
        --arg gsp "$ASSET_DIR/.geosite.dat.coretxn.${txn_id}.bak" \
        --argjson bp "$binary_preexisting" --argjson runtime "$runtime_was_running" \
        --argjson gipre "$geoip_pre" --argjson gspre "$geosite_pre" --argjson spre "$service_pre" \
        --argjson smask "$service_masked" --arg op "$operation" \
        '{phase:"prepared", operation:$op, txn_id:$id, old_version:$ov, old_state_version:$osv, old_channel:$oc,
          new_tag:$nt, channel:$nc, binary:$bin, binary_preexisted:$bp,
          runtime_was_running:$runtime, binary_backup:$bak, unit:$unit, service_prev:$sprev, staging_dir:$stage,
          geoip_preexisted:$gipre, geoip_backup:$gip,
          geosite_preexisted:$gspre, geosite_backup:$gsp,
          service_preexisted:$spre, service_masked:$smask}') || return 1
    _atomic_write_json "$j" "$payload"
}

# 最终验证全体恢复源后才能进入 snapshotted。单个 snapshot helper 的 cmp 保证写入当时完整;
# 这里再验证 journal 引用的全部 sidecar 都在, 让该 phase 成为可依赖的屏障。
#
_xray_core_snapshots_ok() {  # <journal>
    local j="$1" bin bak pre gd src unit sprev service_pre service_masked flag want operation
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    if [ "$pre" = true ]; then
        [ -f "$bak" ] && [ ! -L "$bak" ] || { _error "binary 恢复源缺失/无效: $bak"; return 1; }
    else
        ! _xray_core_path_present "$bak" || { _error "首次安装不应存在 binary 恢复源: $bak"; return 1; }
    fi

    for gd in geoip geosite; do
        src="$ASSET_DIR/${gd}.dat"
        pre=$(jq -r --arg g "$gd" '.[$g + "_preexisted"]' "$j" 2>/dev/null) || return 1
        bak=$(jq -r --arg g "$gd" '.[$g + "_backup"]' "$j" 2>/dev/null) || return 1
        if [ "$pre" = true ]; then
            [ -f "$bak" ] && [ ! -L "$bak" ] || { _error "$gd.dat 恢复源缺失/无效: $bak"; return 1; }
        else
            ! _xray_core_path_present "$bak" || { _error "原先不存在的 $gd.dat 却有恢复源: $bak"; return 1; }
        fi
    done

    unit=$(jq -r '.unit' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    service_pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    service_masked=$(jq -r '.service_masked // false' "$j" 2>/dev/null) || return 1
    if [ -n "$unit" ]; then
        flag="${sprev}.enabled"
        [ -f "$flag" ] && [ ! -L "$flag" ] || { _error "service enable snapshot 缺失/无效: $flag"; return 1; }
        want=$(cat "$flag" 2>/dev/null) || return 1
        case "$want" in enabled|disabled) ;; *) _error "service enable snapshot 内容非法: $flag"; return 1 ;; esac
        if [ "$service_pre" = true ]; then
            [ -f "$sprev" ] && [ ! -L "$sprev" ] && \
                ! _xray_core_path_present "${sprev}.absent" || {
                _error "pre-existing service snapshot 缺失/含糊: $sprev"; return 1; }
            _xray_core_path_present "${sprev}.masked" && {
                _error "pre-existing service 不应存在 mask 恢复源: ${sprev}.masked"; return 1; }
        else
            _xray_core_path_present "$sprev" && { _error "新 service 不应存在内容快照: $sprev"; return 1; }
            [ -f "${sprev}.absent" ] && [ ! -L "${sprev}.absent" ] || {
                _error "service absent 标记缺失/无效: ${sprev}.absent"; return 1; }
            if [ "$service_masked" = true ]; then
                [ -L "${sprev}.masked" ] && [ "$(readlink "${sprev}.masked" 2>/dev/null)" = /dev/null ] || {
                    _error "service mask 恢复源缺失/无效: ${sprev}.masked"; return 1; }
            elif _xray_core_path_present "${sprev}.masked"; then
                _error "非 masked service 不应存在 mask 恢复源: ${sprev}.masked"
                return 1
            fi
        fi
    fi

    local stage f
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    operation=$(jq -r '.operation // "core"' "$j" 2>/dev/null) || operation=core
    # snapshotted 前要求 staging 与全部恢复源存在; _xray_core_journal_ok 只验 schema, 不检查文件系统。
    [ -d "$stage" ] || { _error "staging source 缺失: $stage"; return 1; }
    case "$operation" in
        core)
            [ -f "$stage/xray" ] || { _error "core staging binary 缺失: $stage/xray"; return 1; }
            ;;
        geo)
            for f in geoip geosite; do
                [ -f "$stage/$f.dat" ] && [ ! -L "$stage/$f.dat" ] || { _error "$f.dat Geo staging 缺失"; return 1; }
            done
            ;;
    esac
    return 0
}

# 阶段必须按唯一 transition 表单向推进。失败必须被调用方消费, 不得推进真实状态。
_xray_core_journal_phase() {
    local next="$1" j cur allowed=0
    j=$(_xray_core_journal_path)
    [ -f "$j" ] || { _error "核心事务账本缺失, 无法推进 phase=$next"; return 1; }
    cur=$(jq -r '.phase // empty' "$j" 2>/dev/null) || cur=""
    case "$cur:$next" in
        prepared:snapshotted|snapshotted:replacing|replacing:binary_replaced|\
        replacing:geo_replaced|binary_replaced:service_replaced|service_replaced:restart_verified|\
        geo_replaced:restart_verified|restart_verified:committed|replacing:rolled_back|\
        binary_replaced:rolled_back|service_replaced:rolled_back|geo_replaced:rolled_back|\
        restart_verified:rolled_back) allowed=1 ;;
    esac
    [ "$allowed" -eq 1 ] || { _error "非法核心事务 phase 转移: ${cur:-?} → $next"; return 1; }
    if [ "$next" = snapshotted ]; then
        _xray_core_journal_ok "$j" && _xray_core_snapshots_ok "$j" || {
            _error "恢复源未完整通过最终校验, 不推进 snapshotted"; return 1; }
        _xray_core_snapshots_fsync "$j" || {
            _error "无法枚举 coretxn 恢复源, 不推进 snapshotted"; return 1; }
    elif [ "$next" = committed ] || [ "$next" = rolled_back ]; then
        # Terminal phase means the changed production files are settled before recovery sources may be deleted.
        _xray_core_production_fsync "$j" || {
            _error "无法枚举 coretxn 生产路径, 不推进终态 phase=$next"; return 1; }
    fi
    if ! _meta_update "$j" '.phase=$p' --arg p "$next" 2>/dev/null; then
        _error "核心事务阶段推进失败: ${next}(磁盘空间/IO?), 未继续操作"
        return 1
    fi
    [ "$(jq -r '.phase // empty' "$j" 2>/dev/null)" = "$next" ] || {
        _error "核心事务 phase 回读不一致(期望 $next), 未继续操作"; return 1; }
    return 0
}
_xray_core_journal_drop() {
    local j; j=$(_xray_core_journal_path)
    rm -f "$j" 2>/dev/null || return 1
    ! _xray_core_path_present "$j" || { _error "核心事务账本删除失败, 仍存在: $j"; return 1; }
    _fsync_path "$(dirname "$j")" || :
    return 0
}

# 任意 journal (包括 committed/rolled_back 的 cleanup journal) 都必须先恢复/清理, 不能新开覆盖。
# **调用场景**: 核心事务准入(_install_or_switch_xray / _xray_commit_staged / geo 提交) ——
# 它回答的是"能否开新核心事务", 因此终态但未 cleanup 的账本同样算 pending(防止覆盖证据)。
_xray_core_txn_pending() {
    local j; j=$(_xray_core_journal_path)
    _xray_core_path_present "$(_xray_core_blocked_path)" && return 0
    _xray_core_path_present "${j}.corrupt" && return 0
    # 任意 journal 都要先让 recovery 清理(含 committed/rolled_back 的残留 cleanup),
    # 否则新事务可能覆盖旧证据或误认 stale snapshots。
    _xray_core_path_present "$j"
}

# config 写闸门仅阻塞未收敛核心事务; _xray_core_txn_pending 则把终态 cleanup journal 也算 pending。
# committed/rolled_back 已收敛可写配置; BLOCKED/.corrupt/解析失败/非法或非终态均 fail-closed。
# 此处只判 phase; 完整 schema 校验由 recovery 的 _xray_core_journal_ok 负责, 不复制校验器。
_xray_core_txn_unsettled() {
    local j phase
    j=$(_xray_core_journal_path)
    _xray_core_path_present "$(_xray_core_blocked_path)" && return 0
    _xray_core_path_present "${j}.corrupt" && return 0
    _xray_core_path_present "$j" || return 1
    phase=$(jq -r '.phase // empty' "$j" 2>/dev/null) || return 0
    case "$phase" in
        committed|rolled_back) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 统一 reset/core/port 写闸门: 只看磁盘事实, 未收敛即拒绝普通 config/metadata 写入。
# 调用者持 config lock, 且检查 + 实际写入须在同一 core lock 屏障内(锁序 config → core)。
# reset/port journal 在 config lock 内判; core 非终态判据见 _xray_core_txn_unsettled。
# XD_PORT_TXN_ACTIVE=1 仅豁免当前端口事务自身 journal, 标记限定在事务锁子 shell。
# 返回 0=放行, 1=拒绝且已报原因; 混装缺 helper 按段跳过, 不引入粘滞状态。
# ---------------------------------------------------------------------------
_core_txn_pending_probe() {   # 仅由 _with_core_lock 在锁内调用: 0=无阻塞; 3=未收敛
    _xray_core_txn_unsettled && return 3
    return 0
}

_txn_allow_config_write() {
    # 1) reset 账本(90-menu 定义; 缺 helper 的混装版本跳过)
    if declare -F _reset_journal_path >/dev/null 2>&1 \
       && [ -e "$(_reset_journal_path 2>/dev/null)" ]; then
        _error "存在未收敛的 reset 事务日志, 已拒绝本次配置写入"
        _tip "请重启脚本让 reset 事务先收敛(账本/快照已保留)"
        return 1
    fi
    # 2) 端口事务 journal: 任何 *.porttxn 都是未收敛现场(当前端口事务自己的除外)
    if [ "${XD_PORT_TXN_ACTIVE:-0}" != "1" ]; then
        local _pf
        for _pf in "$NODES_DIR"/*.porttxn; do
            [ -e "$_pf" ] || continue
            _error "存在未收敛的端口事务 journal, 已拒绝本次配置写入: ${_pf##*/}"
            _tip "请重启脚本让启动恢复收敛该 journal 后再操作; 现场(journal)已保留"
            return 1
        done
    fi
    # 3) core 账本: 在 core lock 内判定
    declare -F _core_txn_pending_probe >/dev/null 2>&1 || return 0
    local rc=0
    _with_core_lock _core_txn_pending_probe || rc=$?
    case "$rc" in
        0) return 0 ;;
        3)
            _error "存在未收敛的核心事务(账本/恢复源已保留), 已拒绝本次配置写入"
            _tip "请重启脚本让核心事务先收敛; 收敛前请勿继续修改 config/metadata"
            return 1 ;;
        *)
            _error "无法确认核心事务状态(核心锁不可用?), 已拒绝本次配置写入(fail-closed)"
            return 1 ;;
    esac
}

_xray_core_journal_ok() {
    local j="$1" id bin binbak pre runtime unit sprev stage stage_name phase operation
    local gipre gspre service_pre service_masked gip gsp
    jq -e '
      (.phase | type == "string" and test("^(prepared|snapshotted|replacing|binary_replaced|service_replaced|geo_replaced|restart_verified|committed|rolled_back)$")) and
      ((.operation // "core") | (type == "string" and test("^(core|geo)$"))) and
      (.txn_id | type == "string" and length > 0 and test("^[A-Za-z0-9._-]+$")) and
      (.old_version | type == "string") and (.old_state_version | type == "string") and
      (.old_channel | type == "string") and (.channel | type == "string") and
      (.new_tag | type == "string" and length > 0) and
      (.binary | type == "string" and length > 0) and
      (.binary_backup | type == "string" and length > 0) and
      (.binary_preexisted | type == "boolean") and
      (.runtime_was_running | type == "boolean") and
      (.unit | type == "string") and (.service_prev | type == "string" and length > 0) and
      (.staging_dir | type == "string" and length > 0) and
      (.geoip_preexisted | type == "boolean") and (.geoip_backup | type == "string" and length > 0) and
      (.geosite_preexisted | type == "boolean") and (.geosite_backup | type == "string" and length > 0) and
      (.service_preexisted | type == "boolean") and ((.service_masked // false) | type == "boolean")
    ' "$j" >/dev/null 2>&1 || return 1
    phase=$(jq -r '.phase' "$j" 2>/dev/null) || return 1
    id=$(jq -r '.txn_id' "$j" 2>/dev/null) || return 1
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    binbak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    runtime=$(jq -r '.runtime_was_running' "$j" 2>/dev/null) || return 1
    unit=$(jq -r '.unit' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    operation=$(jq -r '.operation // "core"' "$j" 2>/dev/null) || operation=core
    gip=$(jq -r '.geoip_backup' "$j" 2>/dev/null) || return 1
    gsp=$(jq -r '.geosite_backup' "$j" 2>/dev/null) || return 1
    gipre=$(jq -r '.geoip_preexisted' "$j" 2>/dev/null) || return 1
    gspre=$(jq -r '.geosite_preexisted' "$j" 2>/dev/null) || return 1
    service_pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    service_masked=$(jq -r '.service_masked // false' "$j" 2>/dev/null) || return 1

    [ "$service_masked" = false ] || [ "$service_pre" = false ] || return 1
    [ "$bin" = "$XRAY_BIN" ] && [ "$binbak" = "$XRAY_BIN.bak" ] || return 1
    [ "$sprev" = "$BACKUP_DIR/xray-service.$id.prev" ] || return 1
    [ "$gip" = "$ASSET_DIR/.geoip.dat.coretxn.$id.bak" ] || return 1
    [ "$gsp" = "$ASSET_DIR/.geosite.dat.coretxn.$id.bak" ] || return 1
    case "$unit" in
        ""|/etc/systemd/system/xray.service|/etc/init.d/xray) ;;
        *) return 1 ;;
    esac
    # unit 非空但 service_pre=false 是首次安装的**正常**状态(unit 路径按 init 后端推导,
    # 与文件是否存在无关); 只有 unit 为空(direct 后端)时才不允许 pre=true。
    [ "$service_pre" = false ] || [ -n "$unit" ] || return 1
    case "$operation" in
        core)
            case "$stage" in
                "$BIN_DIR"/.xray-dl.*)
                    stage_name=${stage#"$BIN_DIR"/}
                    case "$stage_name" in .xray-dl.*) case "$stage_name" in */*) return 1 ;; esac ;; *) return 1 ;; esac
                    ;;
                *) return 1 ;;
            esac
            ;;
        geo)
            case "$stage" in
                "$ASSET_DIR"/.xray-geo-txn.*)
                    stage_name=${stage#"$ASSET_DIR"/}
                    case "$stage_name" in .xray-geo-txn.*) case "$stage_name" in */*) return 1 ;; esac ;; *) return 1 ;; esac
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    if [ "$pre" = false ]; then
        [ "$runtime" = false ] || return 1
    fi
    return 0
}
# snapshot binary/geodata source for this journal. Called only before phase=snapshotted.
_xray_core_snapshot_binary() {  # <journal>
    local j="$1" bin bak pre
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    if [ "$pre" = true ]; then
        [ -f "$bin" ] || { _error "旧核心在快照前消失: $bin"; return 1; }
        ! _xray_core_path_present "$bak" || { _error "旧核心快照目标已存在, 拒绝覆盖: $bak"; return 1; }
        cp -p "$bin" "$bak" 2>/dev/null || { rm -f "$bak" 2>/dev/null; return 1; }
        if ! cmp -s "$bin" "$bak" 2>/dev/null; then
            rm -f "$bak" 2>/dev/null
            _error "旧核心快照与原 binary 不一致: $bak"
            return 1
        fi
    else
        ! _xray_core_path_present "$bin" || { _error "binary 在快照阶段被外部创建: $bin"; return 1; }
        ! _xray_core_path_present "$bak" || { _error "首次安装发现遗留 .bak, 拒绝覆盖: $bak"; return 1; }
    fi
    return 0
}

_xray_core_journal_quarantine() {
    local j="$1" why="$2" blocked
    blocked=$(_xray_core_blocked_path)
    # BLOCKED 必须先于 quarantine 成功落盘。若 BLOCKED 写不进去, 原 journal 必须保留且失败返回;
    # 绝不能先挪走原件再 best-effort 写标记。
    if [ -L "$blocked" ] || ! : > "$blocked" 2>/dev/null; then
        _error "无法建立 BLOCKED 标记, 保留原事务账本并拒绝继续: $j"
        return 1
    fi
    _error "核心事务日志不可用($why), 状态未知, 已进入 BLOCKED"
    if ! mv -f "$j" "${j}.corrupt" 2>/dev/null; then
        _error "账本隔离失败(原件仍保留): $j"
        return 1
    fi
    _tip "请人工核对现场后再清除: $blocked ${j}.corrupt"
    return 1
}

# 清理事务资源(除 journal): 任何资源仍存在都返回失败, journal 保留用于下次 retry。
_xray_core_cleanup_sources() {  # <journal>
    local j="$1" binbak stage sprev gip gsp phase service_masked left=0 f
    phase=$(jq -r '.phase' "$j" 2>/dev/null) || return 1
    binbak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    gip=$(jq -r '.geoip_backup' "$j" 2>/dev/null) || return 1
    gsp=$(jq -r '.geosite_backup' "$j" 2>/dev/null) || return 1
    service_masked=$(jq -r '.service_masked // false' "$j" 2>/dev/null) || return 1
    # prepared/snapshotted never crossed the production mutation barrier. Restore
    # the original mask before deleting its source; committed keeps the new service.
    if [ "$service_masked" = true ] && { [ "$phase" = prepared ] || [ "$phase" = snapshotted ]; }; then
        local unit; unit=$(_xray_service_unit_path 2>/dev/null) || unit=""
        [ -n "$unit" ] || return 1
        if _xray_core_path_present "${sprev}.masked"; then
            _xray_service_restore_mask "$unit" "${sprev}.masked" || {
                _error "事务尚未修改生产态, 但原有 systemd mask 无法恢复: $unit"
                return 1
            }
        elif ! _xray_service_is_masked "$unit"; then
            _error "prepared/snapshotted 账本缺少 mask 快照且 live unit 状态不符: $unit"
            return 1
        fi
        systemctl daemon-reload >/dev/null 2>&1 || {
            _error "恢复原有 systemd mask 后 daemon-reload 失败"
            return 1
        }
    fi
    rm -f "$binbak" "$sprev" "${sprev}.absent" "${sprev}.enabled" "${sprev}.masked" "$gip" "$gsp" 2>/dev/null
    [ -n "$stage" ] && rm -rf "$stage" 2>/dev/null
    for f in "$binbak" "$sprev" "${sprev}.absent" "${sprev}.enabled" "${sprev}.masked" "$gip" "$gsp"; do
        _xray_core_path_present "$f" && left=1
        [ -n "$f" ] && _fsync_path "$(dirname "$f")" || :
    done
    [ -z "$stage" ] || ! _xray_core_path_present "$stage" || left=1
    [ -z "$stage" ] || _fsync_path "$(dirname "$stage")" || :
    [ "$left" -eq 0 ] || { _error "事务快照清理未完成, 保留账本供重试"; return 1; }
    return 0
}
_xray_core_cleanup_after_commit() {  # <journal>
    local j="$1"
    # committed / rolled_back 都不可逆: 在删除恢复源前再刷一次生产态, 覆盖旧版本遗留的终态账本。
    _xray_core_production_fsync "$j" || return 1
    # 只清理 transaction-owned artifacts; 源/marker/journal 任一残留都返回失败,
    # 保留 terminal journal 让下次启动继续 cleanup。
    _xray_core_cleanup_sources "$j" || return 1
    _xray_core_journal_drop || return 1
    return 0
}

_xray_core_journal_quarantine_and_block() {
    local j="$1" why="$2"
    _xray_core_journal_quarantine "$j" "$why"
}

_xray_core_txn_recover() { _with_core_lock _xray_core_txn_recover_locked "$@"; }

_xray_core_txn_recover_locked() {
    local j phase
    j=$(_xray_core_journal_path)
    if _xray_core_path_present "$(_xray_core_blocked_path)" || _xray_core_path_present "${j}.corrupt"; then
        _error "核心事务处于 BLOCKED(账本损坏/现场未知), 拒绝自动恢复与新切换"
        _tip "人工核对后清除: $(_xray_core_blocked_path) ${j}.corrupt"
        return 1
    fi
    _xray_core_path_present "$j" || return 0
    if ! jq -e . "$j" >/dev/null 2>&1; then _xray_core_journal_quarantine "$j" "无法解析"; return 1; fi
    if ! _xray_core_journal_ok "$j"; then _xray_core_journal_quarantine "$j" "schema 不合法"; return 1; fi
    phase=$(jq -r '.phase' "$j" 2>/dev/null)

    # committed / rolled_back 都是终态: 永不再回滚, 只重试 cleanup。
    case "$phase" in
        committed|rolled_back)
            _xray_core_cleanup_after_commit "$j" || return 1
            return 0
            ;;
        prepared|snapshotted)
            # phase 语义保证真实状态未动, 只清理中间产物(可能含半截快照), 不碰任何 live 文件。
            _xray_core_cleanup_sources "$j" || return 1
            _xray_core_journal_drop || return 1
            return 0
            ;;
        replacing|binary_replaced|service_replaced|geo_replaced|restart_verified) ;;
        *) _xray_core_journal_quarantine "$j" "未知 phase=$phase"; return 1 ;;
    esac
    _xray_core_recover_rollback_locked "$j"
}

# Rollback 从 snapshot source 重放, **不消费 source**(cp→cmp→rename), 直到 rolled_back phase
# durable 才 cleanup。这样每个崩溃点都可重入: phase 还没写成功就从原 snapshot 再做一遍。
_xray_core_recover_rollback_locked() {
    local j="$1" bin bak pre was_running old_ver old_state_ver old_ch unit sprev
    local service_pre service_masked run_ok=1 disk_ok=1 state_ok=1
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    was_running=$(jq -r '.runtime_was_running' "$j" 2>/dev/null) || return 1
    old_ver=$(jq -r '.old_version' "$j" 2>/dev/null) || old_ver=""
    old_state_ver=$(jq -r '.old_state_version' "$j" 2>/dev/null) || old_state_ver=""
    old_ch=$(jq -r '.old_channel' "$j" 2>/dev/null) || old_ch=""
    unit=$(jq -r '.unit' "$j" 2>/dev/null) || unit=""
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    service_pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    service_masked=$(jq -r '.service_masked // false' "$j" 2>/dev/null) || return 1

    _warn "检测到未完成的核心切换事务(阶段: $(jq -r '.phase' "$j" 2>/dev/null)), 正在回滚..."
    # 先停并验证: binary 还被当前 Xray mmap/exe 使用时不能覆盖, 且恢复完成后必须按旧 binary 重启。
    if ! _xray_stop_and_verify; then
        _error "恢复前无法确认 Xray 已停止, 暂不改动 binary/service snapshots"
        _tip "事务账本与全部恢复源保留: $j"
        return 1
    fi

    # Geo 只改 dat, binary/service 快照只用于验证 pre-state, 不重放未拥有的修改。
    # core 跨 replacing 后重放 binary/service; 缺失/损坏恢复源仍失败并保留 journal。
    local txn_touched_binary=1 txn_touched_service=1
    if [ "$(jq -r '.operation // "core"' "$j" 2>/dev/null)" = geo ]; then
        txn_touched_binary=0; txn_touched_service=0
    fi

    # 1. binary pre-state 由**显式布尔值**描述, 绝不从 old_version 是否为空推断。
    if [ "$txn_touched_binary" -eq 0 ]; then
        # 只验证恢复源可用(缺失/损坏仍要报错并保留 journal), 不写回 live binary。
        if [ "$pre" = true ]; then
            if [ ! -f "$bak" ] || [ -L "$bak" ]; then
                disk_ok=0
                _error "事务旧 binary 恢复源丢失或不是普通文件: $bak"
            fi
            _warn "本次为 Geo 事务且未跨过替换点, binary 按未变更处理(不重放旧快照)"
        fi
    elif [ "$pre" = true ]; then
        if [ ! -f "$bak" ] || [ -L "$bak" ]; then
            disk_ok=0
            _error "事务旧 binary 恢复源丢失或不是普通文件: $bak"
        elif ! _xray_restore_file_atomic "$bak" "$bin" 755; then
            disk_ok=0
            _error "旧 binary 原子还原失败: $bin (恢复源保留: $bak)"
        elif ! cmp -s "$bak" "$bin" 2>/dev/null; then
            disk_ok=0
            _error "旧 binary 还原后内容不一致: $bin"
        else
            _warn "已还原切换前的 binary(snapshot 保留到 rolled_back phase)"
        fi
    else
        if ! rm -f "$bin" 2>/dev/null || _xray_core_path_present "$bin"; then
            disk_ok=0
            _error "事务前不存在的 binary 无法移除: $bin"
        fi
    fi

    # 2. geo sources 是 transaction-unique 路径, 且 restore 保留 source 以支持 crash replay。
    _xref_restore_geo_dats "$j" || disk_ok=0

    # 3. service: 显式 pre-existence 由 journal 绑定。快照损坏或两种状态标记
    # 同时存在时拒绝写回/删除, 保留 journal 和恢复源等待人工处理。
    #    **Geo 事务未跨过替换点时只校验、不写回**(见上方 Geo mutation 范围): 该事务从未创建/改写 unit,
    #    用快照覆盖 live unit 只会把"绕过 core lock 的外部改动"静默回退。
    if [ -n "$unit" ] && [ "$txn_touched_service" -eq 0 ]; then
        if [ "$service_masked" = true ]; then
            if ! _xray_service_restore_mask "$unit" "${sprev}.masked"; then
                disk_ok=0
                _error "原有 systemd mask 无法恢复: $unit"
            else
                systemctl daemon-reload >/dev/null 2>&1 || {
                    disk_ok=0
                    _error "恢复 systemd mask 后 daemon-reload 失败"
                }
            fi
        elif [ "$service_pre" = true ]; then
            if [ -f "$sprev" ] && [ ! -L "$sprev" ] && ! _xray_core_path_present "${sprev}.absent"; then
                _warn "本次为 Geo 事务且未跨过替换点, service 按未变更处理(不重放旧快照)"
            else
                disk_ok=0
                _error "service pre-existing 快照缺失/含糊, 保留 journal: $sprev"
            fi
        fi
    elif [ -n "$unit" ]; then
        if [ "$service_pre" = true ]; then
            if [ -f "$sprev" ] && [ ! -L "$sprev" ] && ! _xray_core_path_present "${sprev}.absent"; then
                if ! _xray_service_restore_file "$sprev" "$unit"; then
                    disk_ok=0
                    _error "service 还原失败: $unit(snapshot 保留: $sprev)"
                elif ! cmp -s "$sprev" "$unit" 2>/dev/null; then
                    disk_ok=0
                    _error "service 还原后内容与 snapshot 不一致: $unit"
                fi
            else
                disk_ok=0
                _error "service pre-existing 快照缺失/含糊, 保留 journal: $sprev"
            fi
            if [ -f "${sprev}.enabled" ] && [ ! -L "${sprev}.enabled" ]; then
                # enable/disable 是下次启动策略, 不是当前 runtime 收敛条件。快照必须存在且可读,
                # 但恢复命令失败沿用同步 rollback 的 warning-only 契约, 不把核心永久卡在 pending。
                _xray_service_restore_enable "${sprev}.enabled" keep || \
                    _warn "service 开机自启状态未恢复(不阻塞核心回滚), 请按上方提示手动处理"
            else
                disk_ok=0
                _error "service 开机自启快照缺失或无效, 保留 journal: ${sprev}.enabled"
            fi
        elif [ "$service_masked" = true ] && [ -L "${sprev}.masked" ] && \
             [ "$(readlink -f "${sprev}.masked" 2>/dev/null)" = /dev/null ]; then
            if ! _xray_service_restore_mask "$unit" "${sprev}.masked"; then
                disk_ok=0
                _error "原有 systemd mask 无法恢复: $unit"
            else
                systemctl daemon-reload >/dev/null 2>&1 || {
                    disk_ok=0
                    _error "恢复 systemd mask 后 daemon-reload 失败"
                }
            fi
        elif [ -f "${sprev}.absent" ] && [ ! -L "${sprev}.absent" ] && \
             ! _xray_core_path_present "$sprev" && \
             [ -f "${sprev}.enabled" ] && [ ! -L "${sprev}.enabled" ]; then
            # enable/link 恢复只影响下次启动策略: 尽力恢复并告警, 但不阻塞 essential rollback。
            # 随后仍必须撤销本次新建的 unit; 文件删除/daemon-reload 失败才保留 journal 重试。
            _xray_service_restore_enable "${sprev}.enabled" keep || \
                _warn "新建 service 的开机自启状态未恢复(不阻塞核心回滚), 继续撤销 unit"
            if ! rm -f "$unit" 2>/dev/null || _xray_core_path_present "$unit"; then
                disk_ok=0
                _error "事务中新建的 service 无法撤销: $unit"
            elif [ "${INIT_SYSTEM:-}" = systemd ] && ! systemctl daemon-reload; then
                disk_ok=0
                _error "新建 service 已删除但 systemd daemon-reload 失败, 保留账本供重试"
            fi
        else
            disk_ok=0
            _error "service snapshot 与 journal pre-existence 不一致或恢复源缺失: $sprev"
        fi
    fi

    if [ "$disk_ok" -ne 1 ]; then
        if _xray_stop_and_verify; then
            _error "核心磁盘状态未能完全还原; 已确认服务停止, journal 与全部恢复源均保留"
        else
            _error "核心磁盘状态未能完全还原, 且无法确认服务已停止; journal 与全部恢复源均保留"
        fi
        _tip "账本: $j"
        return 1
    fi

    # 4. Runtime 必须回到事务前的运行态, 不把用户主动停止的核心意外启动。
    # pre-state 无 binary 时 schema 已保证 was_running=false; 有旧 binary 但原来 stopped 也保持 stopped。
    if [ "$pre" = true ] && [ "$was_running" = true ]; then
        if ! _restart_xray_verified; then
            run_ok=0
            _error "恢复旧核心后服务未能稳定运行"
            _xray_stop_and_verify || _error "回滚后仍无法确认 Xray 已停止"
        else
            local runv; runv=$(_xray_current_version 2>/dev/null) || runv=""
            if [ -n "$old_ver" ] && [ "$runv" != "$old_ver" ]; then
                run_ok=0
                _error "恢复后运行版本不符(期望 ${old_ver}, 实际 ${runv:-unknown})"
                _xray_stop_and_verify >/dev/null 2>&1 || _error "版本不符后无法确认 Xray 已停止"
            else
                _warn "运行实例已收敛到旧 binary(v${runv:-unknown})"
            fi
        fi
    else
        if ! declare -F _xray_is_running >/dev/null 2>&1; then
            run_ok=0
            _error "缺少进程状态探测, 无法确认事务前 stopped 状态已恢复"
        elif _xray_is_running; then
            if ! _xray_stop_and_verify; then
                run_ok=0
                _error "事务前 Xray 未运行, 但恢复后无法确认进程已停止"
            else
                _warn "运行实例已恢复为事务前的 stopped 状态"
            fi
        else
            _warn "运行实例保持事务前的 stopped 状态"
        fi
    fi
    if [ "$run_ok" -ne 1 ]; then
        _error "运行实例未收敛, journal 与恢复源全部保留: $j"
        return 1
    fi

    # 5. 只有磁盘+runtime 都已收敛后才恢复展示 state。失败现场绝不把当前残缺
    # binary 的版本写成"已收敛"。恢复的是 transaction 开始前读到的 state, 不从新现场推断。
    if [ -n "$old_state_ver" ]; then
        if ! _state_set version "$old_state_ver" || [ "$(_state_get version 2>/dev/null)" != "$old_state_ver" ]; then
            _error "恢复旧 version state 失败; journal 与恢复源保留供重试"
            state_ok=0
        fi
    else
        if ! rm -f "$STATE_DIR/version" 2>/dev/null || _xray_core_path_present "$STATE_DIR/version"; then
            _error "清理恢复前不存在的 version state 失败; journal 与恢复源保留供重试"
            state_ok=0
        fi
    fi
    if [ -n "$old_ch" ]; then
        if ! _state_set channel "$old_ch" || [ "$(_state_get channel 2>/dev/null)" != "$old_ch" ]; then
            _error "恢复旧 channel state 失败; journal 与恢复源保留供重试"
            state_ok=0
        fi
    else
        if ! rm -f "$STATE_DIR/channel" 2>/dev/null || _xray_core_path_present "$STATE_DIR/channel"; then
            _error "清理恢复前不存在的 channel state 失败; journal 与恢复源保留供重试"
            state_ok=0
        fi
    fi
    if [ "$state_ok" -ne 1 ]; then
        return 1
    fi

    # 6. rolled_back durable 以后只做 cleanup; 如果 phase 写失败, source 仍完整, 下次可重放。
    if ! _xray_core_journal_phase "rolled_back"; then
        _error "磁盘/runtime 已回滚, 但 rolled_back phase 未落盘; 快照保留待下次重放"
        return 1
    fi
    _xray_core_cleanup_after_commit "$j" || return 1
    _warn "核心事务已完整回滚收敛(磁盘、runtime 与 pre-state 一致)"
    return 0
}
# 统一失败出口: journal phase 决定"只是清理未触碰的 snapshot"还是"回滚已开始的 mutation"。
_xray_core_abort_locked() {  # <用户可读原因>
    local why="$1" rc=0
    _error "$why"
    _xray_core_txn_recover_locked || rc=$?
    if [ "$rc" -eq 0 ]; then
        _warn "本次核心切换已按账本收敛到安全状态"
    else
        _error "核心事务未能收敛, journal 与可用恢复源已保留: $(_xray_core_journal_path)"
    fi
    return 1
}

# Geo 复用 coretxn 锁、transaction-unique 快照与 phase 状态机; 下载在锁外。
# journal 先 durable, stage/snapshots 就绪后才跨 replacing; 只拥有 dat 的 mutation/rollback。
# binary/service 快照用于校验, 不恢复未改动文件; 所有 binary/service 修改仍必须持 core lock。
_xray_core_geo_update_locked() {  # <download_dir> <timestamp> <downloads_ok>
    local download_dir="$1" ts="$2" downloads_ok="$3"
    local j stage old_ver old_channel runtime f src staged dest size
    if ! _xray_core_txn_recover_locked; then
        _error "核心事务尚未收敛, 拒绝提交 Geo 数据"
        return 1
    fi
    if _xray_core_txn_pending; then
        _error "核心事务仍待处理, 拒绝提交 Geo 数据"
        return 1
    fi
    if [ "$downloads_ok" != 1 ]; then
        _warn "Geo 数据未全部下载/校验成功, 不修改 live dat"
        echo "[$ts] PARTIAL 下载不完整, live dat 未修改" >> "$GEO_LOG"
        return 1
    fi
    for f in geoip geosite; do
        src="$download_dir/$f.dat"
        [ -f "$src" ] && [ ! -L "$src" ] || {
            _error "$f.dat 下载暂存缺失或不是普通文件, 不提交 Geo 更新"
            return 1
        }
        size=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo 0)
        [ "$size" -ge 1024 ] || { _error "$f.dat 下载暂存体积异常(${size}B), 不提交 Geo 更新"; return 1; }
    done

    old_ver=$(_xray_current_version 2>/dev/null) || old_ver=""
    old_channel=$(_state_get channel 2>/dev/null) || old_channel=""
    # _xray_core_journal_write 用 operation=geo 分配 ASSET_DIR 下的同盘 staging 路径。
    # journal 先于 mkdir/copy, 因而 prepared 崩溃也能由 recovery 清掉 staging。
    if ! _xray_core_journal_write "$old_ver" "$old_channel" "geo-update" "$old_channel" "" geo; then
        _error "无法建立 Geo coretxn journal, 未修改 live dat"
        return 1
    fi
    j=$(_xray_core_journal_path)
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || stage=""
    [ -n "$stage" ] || { _xray_core_abort_locked "Geo journal 缺少 staging 路径"; return 1; }
    if ! mkdir "$stage" 2>/dev/null; then
        _xray_core_abort_locked "无法创建 Geo transaction staging: $stage"
        return 1
    fi

    # 新 dat 先写入同盘 transaction stage, 并逐字节校验落地副本与下载源一致。
    for f in geoip geosite; do
        src="$download_dir/$f.dat"
        staged="$stage/$f.dat"
        if ! cp -p "$src" "$staged" 2>/dev/null || ! cmp -s "$src" "$staged" 2>/dev/null; then
            _xray_core_abort_locked "$f.dat Geo staging 复制/逐字节校验失败"
            return 1
        fi
    done

    # 恢复 binary/service 与旧 geo 一起纳入事务; 即使本操作只改 dat, recovery 仍能验证完整 pre-state。
    if ! _xray_service_snapshot || ! _xray_core_snapshot_binary "$j" || ! _xref_snapshot_geo_dats "$j"; then
        _xray_core_abort_locked "Geo transaction rollback source 快照失败"
        return 1
    fi
    if ! _xray_core_journal_phase snapshotted; then
        _xray_core_abort_locked "Geo transaction 无法 durable 进入 snapshotted"
        return 1
    fi
    if ! _xray_core_journal_phase replacing; then
        _xray_core_abort_locked "Geo transaction 无法 durable 进入 replacing, live dat 未触碰"
        return 1
    fi

    for f in geoip geosite; do
        staged="$stage/$f.dat"
        dest="$ASSET_DIR/$f.dat"
        if ! mv -f "$staged" "$dest"; then
            _xray_core_abort_locked "$f.dat Geo 原子替换失败"
            return 1
        fi
        [ -f "$dest" ] && [ ! -L "$dest" ] || {
            _xray_core_abort_locked "$f.dat Geo 替换后文件缺失或不是普通文件"; return 1; }
    done
    if ! _xray_core_journal_phase geo_replaced; then
        _xray_core_abort_locked "Geo dat 已替换但无法推进 geo_replaced phase"
        return 1
    fi
    runtime=$(jq -r '.runtime_was_running' "$j" 2>/dev/null) || runtime=false
    if [ "$runtime" = true ] && ! _restart_xray_verified; then
        _xray_core_abort_locked "新 Geo 数据导致 Xray 未能稳定运行, 正在恢复旧 dat"
        return 1
    fi
    if ! _xray_core_journal_phase restart_verified; then
        _xray_core_abort_locked "Geo 已提交但 runtime phase 推进失败"
        return 1
    fi
    if ! _xray_core_journal_phase committed; then
        _xray_core_abort_locked "Geo 已验证但 committed phase 未落盘"
        return 1
    fi
    if ! _xray_core_cleanup_after_commit "$j"; then
        _warn "Geo 数据已提交并验证, 但 transaction cleanup 未完成; journal 保留供下次恢复重试"
    fi
    if [ "$runtime" = true ]; then
        echo "[$ts] OK Geo 更新成功, Xray 重启稳定" >> "$GEO_LOG"
    else
        echo "[$ts] OK Geo 更新成功(xray 未运行, 已跳过重启)" >> "$GEO_LOG"
    fi
    _success "Geo 数据更新成功"
    return 0
}

# ---------------------------------------------------------------------------
# 安装或切换 Xray 核心
# 用法:_install_or_switch_xray <stable|preview|custom> [指定 tag]
#   stable/preview -> 取该通道最新版安装/切换
#   custom         -> 安装/切换到第二个参数指定的 tag(须为规范化的 vX.Y.Z, 见 _xray_canon_tag)
#   未安装 -> 安装; 已安装 -> 切换(配置与节点不动)
# 两阶段: _xray_stage_release 锁外自有取件; _xray_commit_staged 锁内快照/账本/替换/验证。
# 与 recovery 同一稳定 core lock; 配置事务 config → core, 核心事务不取 config lock。
# ---------------------------------------------------------------------------
_install_or_switch_xray() {
    local channel="$1" explicit_tag="${2:-}" tag staged rc=0
    case "$channel" in
        stable|preview) ;;
        custom)
            # 指定版本必须带一个规范化的 tag。这里只做形状校验, 不重复调用 _xray_canon_tag
            # —— 规范化的唯一入口是 _xray_canon_tag, 传未规范化的 26.3.27 应被拒而不是静默接受。
            # 空 tag 会让 _xray_stage_release 去下载 .../download//<asset> 而失败, 故前置拒绝。
            if [[ ! "$explicit_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                _error "指定版本需要一个规范化的 tag(形如 v26.3.27), 收到: ${explicit_tag:-（空）}"
                return 1
            fi
            ;;
        *) _error "未知通道: $channel"; return 1 ;;
    esac
    _ensure_dirs || return 1
    # 同一长驻菜单会话里的上次 committed/rolled_back cleanup 失败也要重试, 不能只等下次 xd 启动。
    # 若是未收敛 mutation, recovery 会回滚; 若 BLOCKED/损坏则仍由 pending gate fail closed。
    if ! _xray_core_txn_recover; then
        _error "核心事务恢复/清理未能完成, 拒绝开始新的切换"
        return 1
    fi
    # 在取件**之前**先看一眼门禁: 明知有未收敛事务就不该白下载一遍(几十 MB)。
    # 真正的门禁仍在锁内那一次(锁外取件期间可能有另一个会话产生账本)。
    if _xray_core_txn_pending; then
        _error "存在未完成的核心切换事务, 已拒绝开始新的切换"
        if [ -f "$(_xray_core_blocked_path)" ]; then
            _tip "事务账本已损坏或状态未知(BLOCKED): 请人工核对现场后删除"
            _tip "  $(_xray_core_blocked_path)  $(_xray_core_journal_path).corrupt"
        else
            _tip "请先按提示处理并删除账本: $(_xray_core_journal_path)"
        fi
        return 1
    fi
    if [ "$channel" = "custom" ]; then
        tag="$explicit_tag"
        _info "指定版本: ${tag}"
    else
        tag=$(_xray_fetch_tag "$channel") || {
            _error "无法获取 ${channel} 通道最新版本(网络?)"
            return 1
        }
        _info "${channel} 通道最新版本: ${tag}"
    fi
    # ---- 阶段一(锁外): 下载/校验/解压到自有 staging ----
    staged=$(_xray_stage_release "$tag")
    if [ -z "$staged" ] || [ ! -f "${staged}/xray" ]; then
        if [ "$channel" = "custom" ]; then
            _error "获取指定版本 ${tag} 失败: 该版本可能不存在, 或网络/校验/解压异常; 未做任何改动"
        else
            _error "获取 ${channel} 版本失败(网络/校验/解压?), 未做任何改动"
        fi
        [ -n "$staged" ] && rm -rf "$staged" 2>/dev/null
        return 1
    fi
    # ---- 阶段二(锁内): 提交(把 staging 路径与已解析的 tag 交给提交体) ----
    _with_core_lock _install_or_switch_xray_locked "$channel" "$staged" "$tag" || rc=$?
    # staging 可无条件回收: recovery 从独立快照重放, 不需要取件内容; cleanup 要求 staging 已不存在。
    rm -rf "$staged" 2>/dev/null
    return $rc
}

_install_or_switch_xray_locked() {
    # $1=通道(stable|preview|custom) $2=staging 目录(锁外已下载校验) $3=目标 tag
    local channel="$1" staged="$2" tag="$3" cur="" prev_channel="" newv=""
    case "$channel" in stable|preview|custom) ;; *) _error "未知通道: $channel"; return 1 ;; esac
    _ensure_dirs || return 1

    # 锁内先重试 terminal cleanup / 收敛中断事务, 再执行第二道门禁。
    if ! _xray_core_txn_recover_locked; then
        _error "核心事务恢复/清理未能完成, 已拒绝新的切换"
        return 1
    fi
    if _xray_core_txn_pending; then
        _error "存在未完成或 BLOCKED 的核心事务, 已拒绝开始新的切换"
        _tip "请先按提示处理: $(_xray_core_journal_path) / $(_xray_core_blocked_path)"
        return 1
    fi
    # 在旧 service 快照前完成布局迁移, 回滚快照始终引用存在的配置路径。
    _config_migrate_legacy || return 1
    cur=$(_xray_current_version 2>/dev/null) || cur=""
    prev_channel=$(_state_get channel 2>/dev/null) || prev_channel=""

    # 账本先落盘; phase=prepared 的唯一含义是"journal 已建, 真实状态未动, snapshots 尚未就绪"。
    if ! _xray_core_journal_write "${cur:-}" "${prev_channel:-}" "$tag" "$channel" "$staged"; then
        _error "核心事务日志写入失败(磁盘空间/权限?), 取消本次安装/切换(未做任何改动)"
        return 1
    fi
    local j; j=$(_xray_core_journal_path)

    # 准备**全部** rollback sources, 在 phase=snapshotted 前绝不 stop/写任何生产文件。
    if ! _xray_service_snapshot || ! _xray_core_snapshot_binary "$j" || ! _xref_snapshot_geo_dats "$j"; then
        # 此时 phase 仍是 prepared(真实状态未动), recovery 只清理部分快照/staging。
        _xray_core_abort_locked "rollback source 快照未能完整建立, 核心切换中止"
        return 1
    fi
    # phase 边界: 所有恢复源完整落盘, 但还没有 stop/rename/copy 到生产路径。
    if ! _xray_core_journal_phase "snapshotted"; then
        _xray_core_abort_locked "无法写入 snapshotted phase, 核心切换中止"
        return 1
    fi

    # commit helper 首先 durable 写 replacing, 然后才有第一次 mutation(_manage stop)。
    # 返回 1=mutation 没开始; 3=replacing 已开始, 必须让 recovery 决定是否完整收敛。
    local crc=0
    _xray_commit_staged "$staged" || crc=$?
    if [ "$crc" -ne 0 ]; then
        _xray_core_abort_locked "核心 binary/geo 替换失败(rc=$crc)"
        return 1
    fi
    if ! _xray_core_journal_phase "binary_replaced"; then
        _xray_core_abort_locked "binary 已替换但 phase 推进失败"
        return 1
    fi

    if ! _init_config_if_empty; then
        _xray_core_abort_locked "配置初始化失败, 中止安装/切换"
        return 1
    fi
    if ! _create_xray_service; then
        _xray_core_abort_locked "service 文件创建失败, 中止安装/切换"
        return 1
    fi
    if ! _xray_core_journal_phase "service_replaced"; then
        _xray_core_abort_locked "service 已替换但 phase 推进失败"
        return 1
    fi

    if ! _restart_xray_verified; then
        _xray_core_abort_locked "新核心未能稳定运行, 正在回滚到切换前状态"
        return 1
    fi
    newv=$(_xray_current_version 2>/dev/null) || newv=""
    if ! _xray_core_journal_phase "restart_verified"; then
        _xray_core_abort_locked "新核心已运行但 phase 推进失败, 未提交"
        return 1
    fi

    # version/channel 是一组 display state, 两份文件不能只提交其中一份。两步之间若有
    # 任一步失败, 账本仍处于 restart_verified, 统一走 recovery: 它会停止新实例、恢复
    # binary/service/runtime, 并按 journal 中的 old_state_version/old_channel 恢复两份旧状态。
    # 不能把已写入一份 state 的现场标成 committed, 否则磁盘核心与显示状态永久分裂。
    if [ -z "$newv" ]; then
        _xray_core_abort_locked "无法读取新核心版本, 拒绝提交 version/channel 状态"
        return 1
    fi
    if ! _state_set channel "$channel" || [ "$(_state_get channel 2>/dev/null)" != "$channel" ]; then
        _xray_core_abort_locked "channel 状态提交失败, 正在回滚核心切换"
        return 1
    fi
    if ! _state_set version "$newv" || [ "$(_state_get version 2>/dev/null)" != "$newv" ]; then
        _xray_core_abort_locked "version 状态提交失败, 正在回滚核心切换"
        return 1
    fi

    # COMMIT: restart 已验证, 只有 committed phase durable 后恢复端才转入 cleanup-only。
    # 若 phase 写失败, 账本仍是 restart_verified, 统一回滚(恢复源都还完整)。
    if ! _xray_core_journal_phase "committed"; then
        _xray_core_abort_locked "核心已稳定运行但 committed phase 未落盘, 正在回滚"
        return 1
    fi
    if ! _xray_core_cleanup_after_commit "$j"; then
        # 已 committed, 绝不回滚; journal 保留, 下次启动只重试 cleanup。
        _warn "核心切换已提交(v${newv:-?}), 但 cleanup 尚未完成; journal 保留供下次启动重试"
    fi
    _success "Xray-core 已切换到 v${newv:-未知} (${channel})"
    _tip "配置与节点保持不变"
    if declare -F _logrotate_setup >/dev/null 2>&1; then _logrotate_setup; fi
    return 0
}

# ---------------------------------------------------------------------------
# 配置文件初始化(空 inbounds + freedom/blackhole + log)
# confs/ 里没有任何非空 JSON 时写
#
# 初始化是 read-decide-write; 普通入口取可重入 config lock, core-held 例外见函数内锁序说明。
# ---------------------------------------------------------------------------
_init_config_if_empty() {
    # 已持 core lock 时直接初始化, 不反向取 config lock; 其它入口走 config → core。
    # _config_present 为真即不写; 空配置初始化不能与已存在配置的普通变更混为同一写路径。
    if [ "${XRAY_DEPLOY_CORE_LOCK_HELD:-0}" = "1" ]; then
        _init_config_if_empty_locked "$@"
        return $?
    fi
    _with_config_lock _init_config_if_empty_locked "$@"
}

_init_config_if_empty_locked() {
    if _config_present; then
        return 0
    fi
    _ensure_dirs || return 1
    # 美化多行格式(便于手动编辑) + dns 段 + routing 规则(bt/广告/私网/CN 走 block)
    # 按 Xray 官方文档顺序排列(env → log → dns → routing → inbounds → outbounds)
    # env 段设置 XRAY_LOCATION_ASSET(docs/config/env.md): 核心 ≥ v26.7.11 在构建模块前
    # 应用该段, geo 文件按此路径加载; 旧核心忽略该字段, 由 service 文件注入同名变量兜底。
    # dns 段与 routing.rules 都先留空占位, 下面由 XRAY_DEFAULT_DNS_JSON /
    # XRAY_DEFAULT_ROUTING_RULES_JSON 注入 —— 两个默认常量是唯一真相(00-common),
    # DNS 菜单的"恢复默认"与路由规则的"恢复默认"复用同一份, 不允许两处硬编码。
    local base='{
  "env": {
    "XRAY_LOCATION_ASSET": "'"$ASSET_DIR"'"
  },
  "log": {
    "loglevel": "warning",
    "access": "'"$LOG_DIR"'/access.log",
    "error": "'"$LOG_DIR"'/error.log"
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
    # 注入默认 DNS 段与默认规则。jq 不可用/失败时不能落地"没有 routing 规则"的半份配置 ——
    # 那会让首次安装的机器悄悄失去 BT/广告/私网拦截, 故显式失败由调用方处理。
    # 两个默认常量都取自 00-common(唯一真相), DNS 菜单的 [恢复默认] 复用同一份。
    local content
    content=$(jq --argjson d "$XRAY_DEFAULT_DNS_JSON" --argjson r "$XRAY_DEFAULT_ROUTING_RULES_JSON" \
        '.dns = $d | .routing.rules = $r' <<< "$base") || {
        _error "生成默认配置失败(jq 不可用?), 未写入 $CONFIG_DIR"
        return 1
    }
    [ -n "$content" ] || { _error "生成默认配置为空, 未写入 $CONFIG_DIR"; return 1; }
    _config_write_merged "$content" || return 1
    # jq 输出即 2 空格缩进且 _atomic_write_json 已做 jq 校验, 不再做第二遍 jq 写回
    # 写入失败须返回非 0, 由调用方恢复或保留失败现场。
    _info "已初始化空配置: $CONFIG_DIR"
}

# ---------------------------------------------------------------------------
# 启动维护: 缺失 env.XRAY_LOCATION_ASSET 才注入, 保留用户值; ≥v26.7.11 读取 env, 旧核心由 service 兜底。
# 仅写磁盘不重启, 下次重启生效; 失败留待下次启动重试。
# 整段 RMW 在 config lock 与 core write barrier 内, 避免覆盖并发配置与绕过恢复闸门。
# ---------------------------------------------------------------------------
_auto_ensure_config_env_locked() {
    # 廉价守卫留在屏障外(空配置/无 jq 的 no-op 不取 core lock)
    _config_present || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # 权威 env 写入整体进 core write barrier, 检查与写入同临界区。
    _with_config_write_barrier _auto_ensure_config_env_write
}

_auto_ensure_config_env_write() {
    if declare -F _txn_allow_config_write >/dev/null 2>&1 \
       && ! _txn_allow_config_write; then
        return 1
    fi
    local need
    # .env 非对象时 `.env.XRAY_LOCATION_ASSET` 会让 jq 报类型错误而整行失败 -> 前置判断
    # 必须先按类型分支(与注入处同一口径), 否则非对象 .env 会在这里提前 return 而无法自愈。
    need=$(_config_jq -r 'if (.env | type) == "object" and ((.env.XRAY_LOCATION_ASSET // "") != "") then 0 else 1 end' 2>/dev/null) || return 0
    [ "$need" = "1" ] || return 0
    local content
    # 非对象 .env 视为 {} 重建, 避免 jq 类型错误使启动维护永久跳过。
    content=$(_config_jq --arg a "$ASSET_DIR" '.env = ((if (.env | type) == "object" then .env else {} end) + {XRAY_LOCATION_ASSET: $a})' 2>/dev/null) || return 0
    [ -n "$content" ] || return 0
    _config_write_merged "$content" 2>/dev/null || return 0
    _info "已注入 config env: XRAY_LOCATION_ASSET=$ASSET_DIR"
}

# 对外入口: 整段读-改-写在同一把配置锁内(与 _init_config_if_empty / _mutate_config 同款
# wrapper + locked 形态)。`_with_config_lock` 经 XRAY_DEPLOY_LOCK_HELD 可重入, 故被
# `_mutate_config` 的事务体间接调用时不会自锁死。
_auto_ensure_config_env() {
    _with_config_lock _auto_ensure_config_env_locked "$@"
}

# ---------------------------------------------------------------------------
# 读取当前日志级别(log.loglevel)
# 真相源只有配置本身 —— 不另存 state 键(项目有 service/config/state 分裂的历史教训)。
# 读不到时输出 "warning": 与核心行为一致(infra/conf/log.go 的 default 分支对未识别/缺失
# 值一律按 warning 处理), 且下游 case 分支不会因空串落到"非法值"。
# ---------------------------------------------------------------------------
_xray_loglevel_get() {
    local lv=""
    if _config_present && command -v jq >/dev/null 2>&1; then
        lv=$(_config_jq -r '.log.loglevel // empty' 2>/dev/null) || lv=""
    fi
    # 配置里存着非法值(手工编辑)时也回显 warning —— 核心就是这么解释它的
    _xray_loglevel_valid "$lv" || lv="warning"
    printf '%s' "$lv"
}

# 日志级别是否合法(XRAY_LOG_LEVELS 白名单, 定义在 00-common)
# 只读展示也可在混装模块下调用; :- 防 set -u 崩溃, 空白名单退化为 warning。
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
    XRAY_LOCATION_ASSET="$ASSET_DIR" XRAY_JSON_STRICT=true "$XRAY_BIN" -test -confdir "$CONFIG_DIR"
}

# 校验**尚未落地**的一份候选配置(confdir 形态)。DNS 菜单用它做"先检查后写"的预检:
# 只有候选能通过 xray -test 才允许写盘, 写盘失败/启动失败也不会把用户留在不可用配置上。
# 候选目录由调用方创建与清理(本项目不做额外清理机制)。
_xray_test_config_dir() {   # <confdir 路径>
    local dir="${1:-}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    [ -x "$XRAY_BIN" ] || return 1
    _maybe_drop_caches
    XRAY_LOCATION_ASSET="$ASSET_DIR" XRAY_JSON_STRICT=true "$XRAY_BIN" -test -confdir "$dir"
}

# ---------------------------------------------------------------------------
# nofile 目标 65535; hard 较低则用 hard, 防止 exec 前 EPERM, 不因受限而省略限制。
# 读管理脚本 /proc/self/limits 对 systemd 是保守下界(PID1 能力/默认值不同), OpenRC 同环境准确。
# 探测失败输出空串以继承默认。
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
# unit 与 env 版本门控相关, 必须与 binary 同时快照/恢复。
# 原有 unit 留内容与执行权限, 原无 unit 留 .absent 以撤销新文件。
# 快照存 BACKUP_DIR, confs 备份轮转不碰它; 具体源由 journal 的 txn_id 绑定。
# ---------------------------------------------------------------------------
# 当前 init 后端对应的 unit 路径(direct 后端无 unit ⇒ 返回 1)
_xray_service_unit_path() {
    case "${INIT_SYSTEM:-}" in
        systemd) printf '%s' '/etc/systemd/system/xray.service' ;;
        openrc)  printf '%s' '/etc/init.d/xray' ;;
        *) return 1 ;;
    esac
}

# systemd mask is a stale, externally managed unit marker, not restorable service
# content. It is handled as an absent unit during reinstall.
_xray_service_is_masked() {
    local unit="$1" target=""
    [ -L "$unit" ] || return 1
    target=$(readlink -f "$unit" 2>/dev/null) || return 1
    [ "$target" = /dev/null ]
}

# Move the exact /dev/null symlink into the transaction-owned snapshot. A rename
# avoids unlinking a concurrently replaced regular unit; verify the moved object
# and fail closed if an external writer won the race.
_xray_service_take_mask_snapshot() {  # <unit> <snapshot symlink>
    local unit="$1" snapshot="$2" unit_dev snapshot_dev
    _xray_service_is_masked "$unit" || return 1
    ! _xray_core_path_present "$snapshot" || return 1
    unit_dev=$(stat -c '%d' "$(dirname "$unit")" 2>/dev/null) || return 1
    snapshot_dev=$(stat -c '%d' "$(dirname "$snapshot")" 2>/dev/null) || return 1
    [ "$unit_dev" = "$snapshot_dev" ] || return 1
    if ! mv -f "$unit" "$snapshot" 2>/dev/null; then
        return 1
    fi
    if [ -L "$snapshot" ] && [ "$(readlink -f "$snapshot" 2>/dev/null)" = /dev/null ]; then
        return 0
    fi
    if ! _xray_core_path_present "$unit"; then
        mv -f "$snapshot" "$unit" 2>/dev/null || :
    fi
    return 1
}

_xray_service_restore_mask() {  # <unit> <snapshot symlink>
    local unit="$1" snapshot="$2" displaced target=""
    displaced="${snapshot}.displaced"
    [ -L "$snapshot" ] && [ "$(readlink -f "$snapshot" 2>/dev/null)" = /dev/null ] || return 1
    if _xray_core_path_present "$unit"; then
        _xray_service_is_masked "$unit" && return 0
        ! _xray_core_path_present "$displaced" || return 1
        # Preserve the current file until the replacement mask is installed.
        # A no-clobber symlink creation makes an external concurrent writer fail
        # closed instead of being overwritten by mv/rm.
        mv -f "$unit" "$displaced" 2>/dev/null || return 1
    fi
    target=$(readlink "$snapshot" 2>/dev/null) || target=/dev/null
    if ! ln -s "$target" "$unit" 2>/dev/null; then
        if ! _xray_core_path_present "$unit"; then
            mv -f "$displaced" "$unit" 2>/dev/null || :
        fi
        return 1
    fi
    if ! _xray_service_is_masked "$unit"; then
        rm -f "$unit" 2>/dev/null
        if ! _xray_core_path_present "$unit"; then
            mv -f "$displaced" "$unit" 2>/dev/null || :
        fi
        return 1
    fi
    [ ! -e "$displaced" ] || rm -f "$displaced" 2>/dev/null || return 1
    return 0
}

_xray_service_prev_path() {
    # 每笔事务唯一快照路径, journal 写入 txn_id 后才调用。没有 txn_id 的旧/测试调用保留 legacy 名。
    printf '%s' "$BACKUP_DIR/xray-service.${XRAY_CORE_TXN_ID:-legacy}.prev"
}

# 查询当前 service 的持久化 enable state。将读取逻辑集中, 使快照与恢复后的
# postcondition 使用同一判定; 不可识别的 systemd 状态必须 fail closed。
_xray_service_enable_state() {
    local output="" st="" unit
    case "${INIT_SYSTEM:-}" in
        systemd)
            command -v systemctl >/dev/null 2>&1 || return 1
            output=$(systemctl is-enabled xray 2>/dev/null) || :
            st=${output##*$'\n'}
            st=${st#"${st%%[![:space:]]*}"}
            st=${st%"${st##*[![:space:]]}"}
            case "$st" in
                enabled|disabled) printf '%s' "$st" ;;
                not-found)
                    unit=$(_xray_service_unit_path 2>/dev/null) || unit=""
                    if [ -n "$unit" ] && ! _xray_core_path_present "$unit"; then
                        printf 'disabled'
                    else
                        return 1
                    fi
                    ;;
                masked)
                    unit=$(_xray_service_unit_path 2>/dev/null) || unit=""
                    if [ -n "$unit" ] && _xray_service_is_masked "$unit"; then
                        # A stale /dev/null mask has no enable link to preserve;
                        # treat it as disabled until the installer replaces it.
                        printf 'disabled'
                    else
                        return 1
                    fi
                    ;;
                *) return 1 ;;
            esac
            ;;
        openrc)
            command -v rc-update >/dev/null 2>&1 || return 1
            output=$(rc-update show default 2>/dev/null) || return 1
            if printf '%s\n' "$output" | grep -qE '(^|[[:space:]])xray([[:space:]]|$)'; then
                printf 'enabled'
            else
                printf 'disabled'
            fi
            ;;
        *) return 0 ;;
    esac
}

# enable 状态会在 service 创建时改变, 因此属于 snapshotted 的必要恢复源。
# 只接受能明确恢复的 enabled/disabled; 查询失败或其它状态必须在 replacing 前中止。
_xray_service_snapshot_enable() {  # <unit路径> <标志文件路径> [已知状态]
    local unit="$1" flag="$2" want="${3:-}"
    [ -n "$want" ] || want=$(_xray_service_enable_state) || {
        _error "无法安全快照 ${INIT_SYSTEM:-未知} 的 xray 开机自启状态, 取消核心事务"
        return 1
    }
    [ -n "$want" ] || return 0
    if ! printf '%s' "$want" > "$flag" 2>/dev/null; then
        rm -f "$flag" 2>/dev/null
        _error "无法持久化 service 开机自启快照: $flag"
        return 1
    fi
    [ "$(cat "$flag" 2>/dev/null)" = "$want" ] || {
        rm -f "$flag" 2>/dev/null
        _error "service 开机自启快照回读不一致: $flag"
        return 1
    }
    return 0
}

# 恢复 enable 状态。只在快照存在时动手(见上: 无快照 = 该维未快照, 不猜)。
# 返回 1 = 自启策略未恢复; 同步 rollback 与 crash recovery 只告警, 不阻塞核心事务收敛。
_xray_service_restore_enable() {  # <标志文件路径> [keep_snapshot]
    local flag="$1" keep="${2:-}" want current action_rc=0
    [ -f "$flag" ] || return 0
    want=$(cat "$flag" 2>/dev/null) || {
        _error "读取 service 自启快照失败: $flag"
        [ "$keep" = keep ] || rm -f "$flag" 2>/dev/null
        return 1
    }
    case "$want" in enabled|disabled) ;; *)
        _error "service 自启快照内容非法, 未执行恢复: $flag"
        [ "$keep" = keep ] || rm -f "$flag" 2>/dev/null
        return 1
        ;;
    esac
    current=$(_xray_service_enable_state) || {
        _error "无法读取当前 service 自启状态, 不执行猜测性恢复"
        return 1
    }
    if [ "$current" != "$want" ]; then
        case "${INIT_SYSTEM:-}:${want}" in
            systemd:enabled)
                systemctl enable xray >/dev/null 2>&1 || action_rc=$? ;;
            systemd:disabled)
                systemctl disable xray >/dev/null 2>&1 || action_rc=$? ;;
            openrc:enabled)
                rc-update add xray default >/dev/null 2>&1 || action_rc=$? ;;
            openrc:disabled)
                rc-update del xray default >/dev/null 2>&1 || action_rc=$? ;;
            *)
                _error "无法在 ${INIT_SYSTEM:-未知} backend 恢复 service 自启状态"
                [ "$keep" = keep ] || rm -f "$flag" 2>/dev/null
                return 1
                ;;
        esac
    fi
    current=$(_xray_service_enable_state) || {
        _error "service 自启状态恢复后不可读取(期望 ${want}, action_rc=${action_rc}), 快照保留: $flag"
        return 1
    }
    if [ "$current" != "$want" ]; then
        _error "service 自启状态未收敛(期望 ${want}, 实际 ${current}, action_rc=${action_rc}), 快照保留: $flag"
        return 1
    fi
    [ "$keep" = keep ] || rm -f "$flag" 2>/dev/null
    _warn "已恢复 service 开机自启状态(${want})"
    return 0
}

# ---------------------------------------------------------------------------
# 同目录原子恢复文件(source snapshot → target)。
# 同目录 temp + cmp + rename: 写失败时生产文件保持原样; source snapshot 保留, 直到 phase rolled_back。
# 用法: _xray_restore_file_atomic <snapshot> <target> <mode>
# ---------------------------------------------------------------------------
_xray_restore_file_atomic() {
    local src="$1" target="$2" mode="$3" tmp
    [ -f "$src" ] && [ ! -L "$src" ] || return 1
    tmp=$(mktemp "$(dirname "$target")/.$(basename "$target").restore.XXXXXX") || return 1
    if ! cat "$src" > "$tmp" 2>/dev/null || ! cmp -s "$src" "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
    if ! mv -f "$tmp" "$target" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

_xray_service_restore_file() {  # <snapshot> <target>
    local prev="$1" unit="$2" mode=644
    [ -f "$prev" ] || return 1
    case "${INIT_SYSTEM:-}" in openrc) mode=755 ;; esac
    if ! _xray_restore_file_atomic "$prev" "$unit" "$mode"; then
        _error "service 文件原子还原失败, 原文件未被主动截断: $unit"
        return 1
    fi
    if [ "${INIT_SYSTEM:-}" = systemd ]; then
        # 磁盘上的 unit 已换回快照, 必须 daemon-reload 成功才算 service 真正恢复。
        if ! systemctl daemon-reload; then
            _error "服务配置重载失败(daemon-reload): systemd 可能仍在使用旧 unit"
            _tip "请手动执行: systemctl daemon-reload"
            return 1
        fi
    fi
    return 0
}

# 重写 unit 之前留快照。返回 1 = 任一恢复源没做成功, 调用方必须中止事务。
_xray_service_snapshot() {
    local unit prev j pre service_masked=false
    unit=$(_xray_service_unit_path) || return 0    # direct 后端: 无 unit 可写, 无需快照
    j=$(_xray_core_journal_path)
    pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    prev=$(_xray_service_prev_path)
    mkdir -p "$BACKUP_DIR" || return 1
    if _xray_core_path_present "$prev" || _xray_core_path_present "${prev}.absent" || \
       _xray_core_path_present "${prev}.enabled" || _xray_core_path_present "${prev}.masked"; then
        _error "service snapshot 路径已存在, 拒绝覆盖旧恢复源: $prev"
        return 1
    fi
    # service 写入会同时变更 enable 状态; 两个维度都必须在 snapshotted 前可恢复。
    if [ "${INIT_SYSTEM:-}" = systemd ] && _xray_service_is_masked "$unit"; then
        service_masked=true
        if ! _xray_service_take_mask_snapshot "$unit" "${prev}.masked"; then
            _error "无法安全快照 stale systemd mask, 拒绝继续: $unit"
            return 1
        fi
        systemctl daemon-reload >/dev/null 2>&1 || {
            _error "移除 stale systemd mask 后 daemon-reload 失败"
            return 1
        }
    fi
    if [ "$service_masked" = true ]; then
        _xray_service_snapshot_enable "$unit" "${prev}.enabled" disabled || return 1
    else
        _xray_service_snapshot_enable "$unit" "${prev}.enabled" || return 1
    fi
    if ! _xray_core_path_present "$unit"; then
        [ "$pre" = false ] || { _error "service 在账本写入后消失, 无法建立旧 unit 快照"; return 1; }
        # systemd not-found / OpenRC 无条目已快照为 disabled, 回滚时可撤销本次 enable。
        : > "${prev}.absent" || return 1
        return 0
    fi
    [ "$pre" = true ] || { _error "service 在账本写入后被外部创建, 拒绝快照"; return 1; }
    if [ -L "$unit" ] || [ ! -f "$unit" ]; then
        _error "service unit 不是普通文件, 无法安全快照: $unit"
        return 1
    fi
    cp -f "$unit" "$prev" 2>/dev/null || { rm -f "$prev"; return 1; }
    if ! cmp -s "$unit" "$prev" 2>/dev/null; then
        rm -f "$prev"
        _error "service 快照与原文件不一致(磁盘空间/IO?), 视为快照失败"
        return 1
    fi
    return 0
}

# 回滚时把 unit 恢复到快照状态(只在快照存在时动手; 无快照 = 本次事务没碰过 unit)。
_xray_service_restore_prev() {
    local unit prev
    unit=$(_xray_service_unit_path) || return 0
    prev=$(_xray_service_prev_path)
    if _xray_core_path_present "${prev}.masked"; then
        if _xray_service_restore_mask "$unit" "${prev}.masked"; then
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            _xray_service_restore_enable "${prev}.enabled" || :
            return 0
        fi
        _error "原有 systemd mask 无法恢复: $unit"
        return 1
    fi
    if [ -f "${prev}.absent" ]; then
        # 事务之前没有 unit ⇒ 把本次新建的那个删掉, 回到"本来就没有"
        # 删除新 unit 失败必须返回失败, 不得把残留 service 报成完整恢复。
        if ! rm -f "$unit" 2>/dev/null; then
            _error "撤销新建 service 文件失败, 请手动删除: $unit"
            return 1
        fi
        rm -f "${prev}.absent" 2>/dev/null || \
            _warn "service 快照标志删除失败(不影响 service 状态): ${prev}.absent"
        # 原无 unit 时撤销本次 enable; 自启恢复失败只告警, 不阻塞当前 runtime 收敛。
        _xray_service_restore_enable "${prev}.enabled" || \
            _warn "service 开机自启状态未能还原(不影响当前运行), 请按上方提示手动执行"
        _warn "已撤销本次新建的 service 文件(事务之前不存在): $unit"
        return 0
    fi
    # 必须存在快照才能恢复; 缺失即失败并保留账本/恢复源, 不猜 pre-state。
    if [ ! -f "$prev" ]; then
        # direct 后端本就没有 unit, 谈不上快照 —— 那种情况由 _xray_service_unit_path 提前返回
        _error "service 快照缺失, 无法确认 service 已回到切换前状态: $prev"
        _tip "请人工核对 service 内容: $unit"
        return 1
    fi
    if ! _xray_service_restore_file "$prev" "$unit"; then
        _error "service 文件还原失败, 请手动核对: $unit (备份: $prev)"
        return 1
    fi
    rm -f "$prev" 2>/dev/null
    _warn "已还原 service 文件到本次改动前的内容: $unit"
    # enable/disable 是独立的下次启动策略维度: 恢复失败只告警, 不把已恢复的 binary+unit
    # rollback 报成失败(否则会因缺 enable 快照而永久 pending, 与协议已确认的取舍冲突)。
    _xray_service_restore_enable "${prev}.enabled" || \
        _warn "service 开机自启状态未还原(不影响当前运行), 请按上方提示手动执行"
    return 0
}

# 事务成功提交: 丢弃 unit 快照(与 rm -f "$XRAY_BIN.bak" 同一步)
_xray_service_snapshot_drop() {
    local prev; prev=$(_xray_service_prev_path)
    rm -f "$prev" "${prev}.absent" "${prev}.enabled" "${prev}.masked" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 生成 service 文件
# XRAY_LOCATION_ASSET 优先走配置的 env 段(docs/config/env.md, 核心 ≥
# v26.7.11 在构建模块前应用该段并替换同名进程变量)。仅当已安装核心 < v26.7.11(不识别
# env 段)时才在 service 文件注入同名环境变量兜底 —— 版本读不到时保守保留注入(旧行为)。
# 注意: _install_or_switch_xray 先替换二进制再调本函数, 这里读到的是"新"核心版本。
# ---------------------------------------------------------------------------
_create_xray_systemd_service() {
    local nofile_line="" env_line="Environment=XRAY_JSON_STRICT=true"
    local _nf; _nf=$(_safe_nofile)
    [ -n "$_nf" ] && nofile_line="LimitNOFILE=$_nf"
    if ! _xray_version_ge "26.7.11"; then
        env_line="Environment=XRAY_LOCATION_ASSET=${ASSET_DIR}
Environment=XRAY_JSON_STRICT=true"
    fi
    # unit 重定向写入失败即失败; 后续 daemon-reload 成功不能代替写入成功。
    # 权限按后端显式设置, 失败语义由同步 rollback 与 journal recovery 消费。
    if ! cat > /etc/systemd/system/xray.service <<EOF
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
${env_line}
# Xray 无需运行期提权，限制子进程获得新权限。
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -confdir ${CONFIG_DIR}
Restart=on-failure
RestartSec=3
${nofile_line}

[Install]
WantedBy=multi-user.target
EOF
    then
        _error "service 文件写入失败(只读文件系统/磁盘空间/权限?): /etc/systemd/system/xray.service"
        return 1
    fi
    # systemd unit 显式 644 防 world-inaccessible 告警; chmod 失败只告警, root 仍可读取。
    chmod 644 /etc/systemd/system/xray.service 2>/dev/null || \
        _warn "service 文件权限设置失败(不影响 systemd 读取): /etc/systemd/system/xray.service"
    # daemon-reload 失败必须中止; enable 失败仅影响自启并告警。
    if ! systemctl daemon-reload; then
        _error "systemd daemon-reload 失败"
        return 1
    fi
    systemctl enable xray 2>/dev/null || _warn "xray 开机自启设置失败(可手动: systemctl enable xray)"
    return 0
}

_create_xray_openrc_service() {
    local rc_ulimit_line="" sd_env_line="export XRAY_JSON_STRICT=true"
    local _nf; _nf=$(_safe_nofile)
    # 抬到"目标 65535 或当前 hard 上限"(见 _safe_nofile); 只有完全探测不到时才留空
    [ -n "$_nf" ] && rc_ulimit_line="rc_ulimit=\"-n $_nf\""
    # 核心 ≥ v26.7.11 用 config env 段, 不再经 supervise-daemon 注入; 旧核心保留注入兜底
    if ! _xray_version_ge "26.7.11"; then
        sd_env_line="supervise_daemon_args=\"--env XRAY_LOCATION_ASSET=${ASSET_DIR}\"
export XRAY_JSON_STRICT=true"
    fi
    # OpenRC init 写入失败必须返回非 0 触发恢复, chmod/enable 成功不能掩盖截断。
    if ! cat > /etc/init.d/xray <<EOF
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
${sd_env_line}

command="${XRAY_BIN}"
command_args="run -confdir ${CONFIG_DIR}"
required_dirs="${CONFIG_DIR}"

depend() {
    need net
    want dns ntp-client
    after firewall
}
EOF
    then
        _error "service 文件写入失败(只读文件系统/磁盘空间/权限?): /etc/init.d/xray"
        return 1
    fi
    chmod +x /etc/init.d/xray || { _error "service 文件执行位设置失败: /etc/init.d/xray"; return 1; }
    # enable 失败只影响开机自启, 不中止安装(与 systemd 分支同一口径)
    rc-update add xray default 2>/dev/null || _warn "xray 开机自启设置失败(可手动: rc-update add xray default)"
    return 0
}

_create_xray_service() {
    case "$INIT_SYSTEM" in
        systemd) _create_xray_systemd_service ;;
        openrc)  _create_xray_openrc_service ;;
        direct)
            # 无 init 系统:不做 service,提示手动运行
            _warn "未检测到 systemd/openrc,跳过 service 创建(可手动: XRAY_LOCATION_ASSET=${ASSET_DIR} XRAY_JSON_STRICT=true ${XRAY_BIN} run -confdir ${CONFIG_DIR})"
            ;;
        *)
            _error "未知的 init backend: ${INIT_SYSTEM:-未设置}, 无法创建 Xray service"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Xray 业务判活: systemd 用 unit LoadState/MainPID; not-found 或已知 unit 的 MainPID=0 即 stopped。
# LoadState 不可读时要求 is-active + 本脚本二进制实例同时成立, 不裸用全机同名扫描。
# OpenRC supervisor 自身存活不算业务存活: pidfile anchor → ppid 子树; direct 用身份 pidfile。
# OpenRC/direct anchor 失效再按 exe 归属扫描, 防假阴性触发 zap/重复启动。
# /proc/comm 兜底避免容器中 pidof 漏报; 归属 fail-open 与 destructive fail-closed 见 _proc_exe_is/_proc_exe_is_strict。
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
        openrc)
            # OpenRC 纯 PID anchor 失效后按 exe 兜底, 防误判停止触发 zap/重复启动。
            anchor=$(_xd_pidfile_pid /run/xray.pid 2>/dev/null)
            if [ -n "$anchor" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" xray && return 0
            fi
            ;;
        direct)
            # direct 有 starttime 时身份为权威; 化身不符直接 stopped, 不得被全机扫描兜底绕过。
            if [ -n "$(_xd_pidfile_starttime /run/xray.pid)" ]; then
                _xd_pidfile_identity_ok /run/xray.pid || return 1
            fi
            anchor=$(_xd_pidfile_pid /run/xray.pid 2>/dev/null)
            if [ -n "$anchor" ] && [ -d "/proc/$anchor" ]; then
                _proc_named_under "$anchor" xray && return 0
            fi
            # 无身份记录(旧版纯 PID pidfile / 文件缺失)时保留既有兜底
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
    # 所有 start/stop/restart 都与核心替换/Geo commit 共用 core.lock。锁持有标志由
    # _with_core_lock 的子 shell 继承, 所以事务内部的嵌套调用直接落到下方实现, 不会自锁。
    # status 是只读观察, 不取锁。缺 flock 时由 _with_core_lock 使用拒绝接管的 mkdir 退路。
    case "$action" in
        start|stop|restart)
            if [ "${XRAY_DEPLOY_CORE_LOCK_HELD:-0}" != 1 ] && \
               declare -F _with_core_lock >/dev/null 2>&1; then
                _with_core_lock _manage_xray "$@"
                return $?
            fi
            ;;
    esac
    # start/restart 派生服务前关闭 config fd9、core/install 主锁与全部 legacy 锁 fd, 防守护进程继承持锁。
    # 使用 local V="${V:-9}" + {V}>&-: 动态 fd 重定向只影响子命令, 父 fd 保留。
    # ${V:-9}>&- 不会把展开值作为 fd, 会多传位置参数且关错描述符; 默认 9 防未持锁/set -u 异常。
    local CORE_LOCK_FD="${CORE_LOCK_FD:-9}"
    local DEPLOY_INSTALL_LOCK_FD="${DEPLOY_INSTALL_LOCK_FD:-9}"
    local XD_CORE_LEGACY_FLOCK_FD="${XD_CORE_LEGACY_FLOCK_FD:-9}"
    local XD_INSTALL_LEGACY_FLOCK_FD="${XD_INSTALL_LEGACY_FLOCK_FD:-9}"
    local XD_CORE_LEGACY1_FLOCK_FD="${XD_CORE_LEGACY1_FLOCK_FD:-9}"
    local XD_INSTALL_LEGACY1_FLOCK_FD="${XD_INSTALL_LEGACY1_FLOCK_FD:-9}"
    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start)   systemctl start xray 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                stop)    systemctl stop xray 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- ;;
                restart) systemctl restart xray 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                # 与 openrc/direct 一致地走 _xray_is_running(绑定到 unit MainPID 的
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
                    _xray_is_running || rc-service xray zap >/dev/null 2>&1 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&-
                    rc-service xray start 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                stop)    rc-service xray stop 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- ;;
                restart)
                    _xray_is_running || rc-service xray zap >/dev/null 2>&1 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&-
                    rc-service xray restart 2>/dev/null 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- ;;
                status)
                    # 只认真实 xray 业务进程, 不认 supervise-daemon 父进程(否则崩溃循环被误报 running)
                    if _xray_is_running; then echo "running"; else echo "stopped"; fi
                    ;;
            esac
            ;;
        direct)
            case "$action" in
                start)
                    local dpid0="" dpid1=""
                    dpid0=$(_xd_pidfile_pid /run/xray.pid)
                    # PID reuse 防护: pidfile 记录的**身份**(PID + 启动时 starttime)必须仍然成立,
                    # 且 comm 仍是 xray, 才算已在运行; 旧 xray 退出后 PID 若被复用(即使复用者也是
                    # xray), 记录的身份对不上, 陈旧 pidfile 应清掉再正常启动。
                    if [ -n "$dpid0" ] && _xd_pidfile_identity_ok /run/xray.pid \
                       && [ "$(cat /proc/$dpid0/comm 2>/dev/null)" = "xray" ]; then
                        echo "running"
                    else
                        rm -f /run/xray.pid
                        local -a config_args=(-confdir "$CONFIG_DIR")
                        if ! _config_present && [ -s "$LEGACY_CONFIG_FILE" ]; then
                            config_args=(-config "$LEGACY_CONFIG_FILE")
                        fi
                        XRAY_LOCATION_ASSET="$ASSET_DIR" XRAY_JSON_STRICT=true nohup "$XRAY_BIN" run "${config_args[@]}" >/dev/null 2>&1 9>&- {CORE_LOCK_FD}>&- {DEPLOY_INSTALL_LOCK_FD}>&- {XD_CORE_LEGACY_FLOCK_FD}>&- {XD_INSTALL_LEGACY_FLOCK_FD}>&- {XD_CORE_LEGACY1_FLOCK_FD}>&- {XD_INSTALL_LEGACY1_FLOCK_FD}>&- &
                        _xd_pidfile_write /run/xray.pid "$!"
                        sleep 1
                        dpid1=$(_xd_pidfile_pid /run/xray.pid)
                        if [ -z "$dpid1" ] || [ "$(cat /proc/$dpid1/comm 2>/dev/null)" != "xray" ]; then
                            _warn "Xray 启动失败,进程已退出"
                            rm -f /run/xray.pid
                            return 1
                        fi
                    fi
                    ;;
                stop)
                    if [ -f /run/xray.pid ]; then
                        local dpid _xray_st
                        dpid=$(_xd_pidfile_pid /run/xray.pid)
                        # 身份链闭合: 复核过的 starttime 必须**传进** kill helper,
                        # 否则 helper 自己重读 starttime, 两次读取之间 PID 仍可能被复用 —— 会出现
                        # "复核的是 A 进程、杀的是 B 进程"。comm 检查只作附加收窄。
                        _xray_st=$(_xd_pidfile_starttime /run/xray.pid)
                        if [ -n "$dpid" ] && _xd_pidfile_identity_ok /run/xray.pid \
                           && [ "$(cat /proc/$dpid/comm 2>/dev/null)" = "xray" ]; then
                            _xd_kill_pid_graceful "$dpid" 5 "$_xray_st"
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
    # restart + 8 秒健康观察作为一个不可穿插的 runtime mutation 临界区。
    if [ "${XRAY_DEPLOY_CORE_LOCK_HELD:-0}" != 1 ] && \
       declare -F _with_core_lock >/dev/null 2>&1; then
        _with_core_lock _restart_xray_verified
        return $?
    fi
    # 成败以 8s 真实判活采样为准; OpenRC 命令 rc 仅决定是否补 start, 不替代业务健康证据。
    _manage_xray restart 2>/dev/null
    if [ "$(_manage_xray status 2>/dev/null)" != "running" ]; then
        _manage_xray start 2>/dev/null
    fi
    local i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        [ "$(_manage_xray status 2>/dev/null)" = "running" ] || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# 卸载先 stop 再轮询正向停止证据, 确认成功才返回 0(同 _hysteria_stop_and_verify)。
# 查询失败/未知不等于停止; 缺 _xray_is_running 时拒绝破坏性操作。
# 日常 status 仍走 _xray_is_running, 破坏性路径用下方更严格 stopped 判据。
# ---------------------------------------------------------------------------
# 破坏性操作必须有正向停止证据; systemd 查询失败/未知不得等同于已停止。
# 返回 0=确认停止, 1=仍运行/过渡, 2=无法观察。
_xray_stopped_state() {
    case "$INIT_SYSTEM" in
        systemd)
            local load active mainpid
            load=$(systemctl show -p LoadState --value xray 2>/dev/null) || return 2
            case "$load" in
                not-found)
                    [ -d /proc ] || return 2
                    _proc_any_named xray "$XRAY_BIN" && return 1
                    return 0
                    ;;
                loaded|masked) ;;
                *) return 2 ;;
            esac
            active=$(systemctl show -p ActiveState --value xray 2>/dev/null) || return 2
            case "$active" in
                inactive|failed) ;;
                *) return 1 ;;
            esac
            mainpid=$(systemctl show -p MainPID --value xray 2>/dev/null) || return 2
            [[ "$mainpid" =~ ^[0-9]+$ ]] || return 2
            [ "$mainpid" = "0" ] && return 0
            return 1
            ;;
        *) return 2 ;;
    esac
}

_xray_stop_and_verify() {
    # stop 与完整 liveness 确认不可被核心 transaction 的 restart 插入。
    if [ "${XRAY_DEPLOY_CORE_LOCK_HELD:-0}" != 1 ] && \
       declare -F _with_core_lock >/dev/null 2>&1; then
        _with_core_lock _xray_stop_and_verify
        return $?
    fi
    if ! declare -F _xray_is_running >/dev/null 2>&1; then
        _error "lib 版本过旧(缺 _xray_is_running), 无法确认 Xray 是否退出, 已中止破坏性操作"
        _tip "请执行 install.sh --update 同步全部模块后重试"
        return 1
    fi
    _manage_xray stop >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if [ "${INIT_SYSTEM:-}" = systemd ]; then
            _xray_stopped_state && return 0
        else
            _xray_is_running || return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# 卸载 Xray(停服务 + 删 service + 删部署目录 + 清快捷命令 + 清 crontab)
# ---------------------------------------------------------------------------
_uninstall_xray() {
    # 外层取 install, 下层 config → core; 稳定锁均在部署树外, 卸载不拆分 inode。
    _with_deploy_install_lock _uninstall_xray_core_locked "$@"
}

_uninstall_xray_core_locked() {
    # 卸载锁序: install(外层) → config → core。reset 也走同一顺序, 因而 rm -rf
    # 不会穿插在 config 事务的 config lock 与 verified restart 之间。
    _with_config_lock _uninstall_xray_config_locked "$@"
}

_uninstall_xray_config_locked() {
    _with_core_lock _uninstall_xray_locked "$@"
}

_uninstall_xray_locked() {
    # 确认进程退出后才删文件; 失败保留管理入口, 见 _xray_stop_and_verify。
    if ! _xray_stop_and_verify; then
        _error "xray 进程未能停止, 已中止卸载(文件未删除), 请手动处理后重试"
        _tip "可先到 xd 主菜单 [查看状态] 确认服务与版本"
        return 1
    fi
    # 清理端口跳跃 iptables 规则必须在任何外部卸载动作之前: 失败时保留部署树和
    # metadata, 同时避免留下已失去管理入口的 DNAT 规则。
    if declare -F _hy2_cleanup_all_hops >/dev/null 2>&1; then
        if ! _hy2_cleanup_all_hops; then
            _error "端口跳跃规则清理失败, 已中止卸载(部署目录与节点元数据保留), 请处理后重试"
            return 1
        fi
    fi
    # 官方 Hysteria2 前置清理可因停止/服务定义失败而中止, 因此必须早于 Xray unit、快捷命令与
    # 二进制 symlink 的删除; 否则 abort 会留下 Hysteria 孤儿服务但已失去管理入口。
    if declare -F _hysteria_cleanup_before_uninstall >/dev/null 2>&1; then
        if ! _hysteria_cleanup_before_uninstall; then
            _error "官方 Hysteria2 清理未完成, 已中止 Xray 卸载(部署数据与 Xray 管理入口保留), 请处理后重试"
            return 1
        fi
    fi
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
    # cron 清理只走 _crontab_replace(见 00-common 读取/返回码契约); 混装缺 helper 宁可保留行。
    if declare -F _crontab_replace >/dev/null 2>&1; then
        # ${VAR:-字面量} 兜底: 30-geo 在加载顺序上晚于本模块, 且混装旧 lib 时该常量可能缺失
        # (set -u 下裸用会崩)。marker 值是稳定契约, 字面量兜底与 30-geo 的常量同源。
        _crontab_replace "${GEO_CRON_MARKER:-# xray-deploy-geo-update}" >/dev/null 2>&1 || \
            _warn "未能移除 geo 定时任务, 请手动检查 crontab"
        _crontab_replace "# xray-deploy-timed-restart" >/dev/null 2>&1 || \
            _warn "未能移除定时重启任务, 请手动检查 crontab"
    else
        _warn "lib 版本过旧(缺 _crontab_replace), 已跳过 crontab 清理, 请手动检查项目定时任务"
    fi
    # 删快捷命令(xd) + xray symlink
    rm -f /usr/local/bin/"$CMD_NAME"
    [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$XRAY_BIN" ] && rm -f /usr/local/bin/xray
    # 清理 logrotate 配置
    if declare -F _logrotate_cleanup >/dev/null 2>&1; then
        _logrotate_cleanup
    fi
    # 删部署目录(含 config/nodes/assets/logs/state/lib/templates)。rm -rf 的 rc 不能吞掉;
    # 部分删除失败时必须报告未完成, 不能把残留安装报成已卸载。
    if ! rm -rf "$DEPLOY_DIR" 2>/dev/null || [ -e "$DEPLOY_DIR" ] || [ -L "$DEPLOY_DIR" ]; then
        _error "部署目录删除失败, 卸载未完成: $DEPLOY_DIR"
        _tip "请检查权限/只读文件系统后重试"
        return 1
    fi
    _success "Xray 已卸载干净(/opt/xray-deploy、xd 命令、系统 cron 已清除)"
}

# ---------------------------------------------------------------------------
# 核心管理菜单入口(安装/更新或切换)
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
        echo -e "  ${YELLOW}已安装 → 切换通道最新版或指定版本(配置与节点不变)${NC}"
    else
        echo -e "  当前版本: ${RED}未安装${NC}"
        echo -e "  ${YELLOW}选择通道或指定版本将安装核心${NC}"
    fi
    echo
    echo -e "  ${GREEN}[1]${NC} 稳定版(stable)"
    echo -e "  ${GREEN}[2]${NC} 预览版(preview)"
    echo -e "  ${GREEN}[3]${NC} 安装指定版本 (X.Y.Z)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    echo
    read -rp "  请选择: " choice
    case "$choice" in
        1) _install_or_switch_xray stable ;;
        2) _install_or_switch_xray preview ;;
        3)
            # 规范化的唯一入口是 _xray_canon_tag: 只接受 vX.Y.Z / X.Y.Z, 其余一律拒绝。
            # 版本存在与否不在菜单预检 —— 与 hy 官方核心管理菜单同口径, 由下载阶段判定;
            # 不存在的 tag 会在取件阶段失败, 不触碰任何生产文件。
            local vraw vtag
            read -rp "  输入版本号 (如 26.3.27 或 v26.3.27): " vraw || return 0
            [ -n "$vraw" ] || { _info "已取消"; return 0; }
            if ! vtag=$(_xray_canon_tag "$vraw"); then
                _error "版本号格式应为 X.Y.Z (如 26.3.27): ${vraw}"
                _press_any_key
                return 0
            fi
            _install_or_switch_xray custom "$vtag"
            ;;
        0) return ;;
        *) _warn "无效选择" ;;
    esac
    _press_any_key
}
