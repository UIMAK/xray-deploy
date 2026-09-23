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
            # 兜底(无 jq): 记住"最近一次出现的 tag_name", 遇到 "prerelease": true 就输出它。
            # 旧的 `grep -B5` 把窗口写死成 5 行 —— 一旦 API 在 tag_name 与 prerelease 之间
            # 多插几个字段(或改成紧凑输出), 就会取到隔壁 release 的 tag 或取不到, 用户被装上
            # 错误版本却毫无提示。按"最近一个 tag_name"取值只依赖对象内的字段先后(GitHub 的
            # 稳定顺序), 不依赖行距。
            if [ -z "$tag" ] || [ "$tag" = "null" ]; then
                # 先按对象边界把每个 release 拆到独立行, 否则紧凑单行 JSON 会被当成一行:
                # 贪婪的 sub(/.*"tag_name".../) 只保留**最后一个** tag_name, 于是第一个
                # prerelease:true 会拿到错误(但非空)的 tag, 通过末尾的 [ -n ] 守卫, 静默装错版本。
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
# 当前已安装版本(R3 回显用)
# ---------------------------------------------------------------------------
_xray_current_version() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# 版本门控: 当前已安装核心是否 >= 最低要求。用法: _xray_version_ge "26.7.11"
# 背景(R44): docs 描述 main 分支, 领先于已发布核心 —— config 新字段(env/geodata 等)在旧
# 核心上被 Go JSON 静默忽略, 按 docs 无脑写入会让功能"静默失效"。故新特性落地前必须对照
# 目标发布版本, 这里用纯数字三段比较(version 输出形如 26.9.9), 不用 sort -V(busybox 兼容性)。
# 未安装/版本读不到 → 返回 1(不满足), 调用方回退到保守行为。
# ---------------------------------------------------------------------------
_xray_version_ge() {
    local min="$1" cur i x y
    cur=$(_xray_current_version 2>/dev/null)
    [ -n "$cur" ] || return 1
    # 两侧都可能带 "v" 前缀(如 XRAY_VERSION 常量的 "v26.6.1" 形态)。不剥掉时 "v26" 会落进
    # 下面的非数字分支被当成 0, 比较退化成**恒真** —— 实测: 26.2.6 也被判为 >= v26.6.1,
    # 于是门控形同虚设, 旧核心照旧接收它不认识的字段(Go JSON 静默忽略 = 静默失效)。
    # 这是本函数唯一存在的意义, 故在入口统一剥前缀, 使带不带 v 都按同一语义比较。
    cur="${cur#v}"; cur="${cur#V}"
    min="${min#v}"; min="${min#V}"
    local -a a b
    IFS='.' read -ra a <<< "$cur"
    IFS='.' read -ra b <<< "$min"
    for i in 0 1 2; do
        x="${a[$i]:-0}"; y="${b[$i]:-0}"
        [[ "$x" =~ ^[0-9]+$ ]] || x=0
        [[ "$y" =~ ^[0-9]+$ ]] || y=0
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

# ---------------------------------------------------------------------------
# 下载完整性校验(2026-09-12 审查 F2, 对齐官方 Xray-install install-release.sh
# L442-459 的 .dgst 方案; singbox-lite xray_manager 同款)。
# Xray release 的 <url>.dgst 为多行文本, 形如 "SHA2-256= <hex>"(实测), 
# _dgst_sha256_of 取 sha+256 行最后一个字段并只留 hex, 供单测。
# 校验失败/解析异常/sha256sum 缺失一律 fail-closed —— 宁可中止升级, 不落地
# 未校验的二进制(docs/security-audit.md 曾认定".dgst 不可行", 系误判, 已纠正)。
# ---------------------------------------------------------------------------

# 从 .dgst 文本文件解析 SHA256(hex, 64 位); 解析不出输出空串
_dgst_sha256_of() {
    awk 'tolower($0) ~ /sha/ && /256/ {print tolower($NF); exit}' "$1" 2>/dev/null \
        | tr -cd '0-9a-f'
}

# 校验已下载的 zip 与其官方 .dgst; 通过返回 0, 任何异常返回 1(调用方中止替换)
_xray_verify_sha256() {
    local zip="$1" url="$2" dgst want got
    dgst="${zip}.dgst"
    if ! _http_download "${url}.dgst" "$dgst" 30; then
        _error "下载校验文件失败(${url}.dgst), 取消替换(不使用未校验的二进制)"
        return 1
    fi
    want=$(_dgst_sha256_of "$dgst")
    rm -f "$dgst"
    if [ "${#want}" -ne 64 ]; then
        _error "校验文件中未解析到 SHA256(格式异常?), 取消替换"
        return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        _error "sha256sum 不可用, 无法校验下载完整性, 取消替换"
        return 1
    fi
    got=$(sha256sum "$zip" 2>/dev/null | awk '{print tolower($1)}')
    if [ "$got" != "$want" ]; then
        _error "SHA256 校验失败(下载损坏或被篡改?), 取消替换"
        return 1
    fi
    return 0
}

# 阶段一(十二轮 P2-③): **只做取件, 不碰任何共享状态** —— 下载/校验/解压全部落在自己独有的
# staging 目录里, 因此**不需要核心锁**。锁只包住第二阶段(_xray_commit_staged), 于是
# "另一个会话在下载 40s"不会把本会话拖成 15s 锁超时。
# 成功时把 staging 目录路径打到 stdout(调用方持有它直到提交或放弃)。
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
    # 临时目录必须与目标二进制**同一文件系统**(2026-09-22 十轮 P1-②)。默认的 /tmp 常与
    # /opt 分属不同挂载, 而跨文件系统的 `mv` 会退化成"拷贝 + unlink": 中途 ENOSPC/IO 错误时
    # 目标已被**截断**, 下面那句"mv 失败 ⇒ 旧二进制仍在原位 ⇒ .bak 可以删"的前提就不成立,
    # 于是唯一的旧核心备份被删掉、盘上留半截新二进制。实测(写限额触发 ENOSPC): 跨 fs 的
    # `mv` 把 8MB 目标截成 2048B 后才报错, 源文件仍在 —— 即失败后**新旧都不可用**。
    # 放进 $BIN_DIR 后 mv 走 rename(2): 失败时旧文件要么原样、要么已完整替换, 无中间态。
    # 不自动清理历史残留目录: 并发会话正在下载的 staging 与 SIGKILL 残留无法区分,
    # 误删会让对方的替换凭空失败(install.sh 的 .install-rollback 同款取舍, 见 CLAUDE.md)。
    # mktemp -d 失败必须中止 —— 与 30-geo.sh 的 Geo 更新同款: tmp_dir="" 会让
    # tmp_zip="/xray.zip" 落到系统根目录, 且后续 [ ! -f "/xray" ] / mv -f "/xray" "$XRAY_BIN"
    # 可能把根目录下恰好同名的文件当成新核心搬走。磁盘满/只读/inode 耗尽正是本 PR 关注的场景。
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
    # 完整性校验(F2): 先验 SHA256 再解压, 坏包不进入替换事务
    if ! _xray_verify_sha256 "$tmp_zip" "$dl_url"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null; then
        _error "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi
    # 立即删除 zip 文件(低内存 VPS 上, 多余的 20MB 无论是占 tmpfs 还是占磁盘都该立刻还回去)
    rm -f "$tmp_zip"
    if [ ! -f "${tmp_dir}/xray" ]; then
        _error "压缩包内未找到 xray 二进制"
        rm -rf "$tmp_dir"
        return 1
    fi

    # 取件阶段到此为止 —— 共享状态(二进制/服务/geo dat)一律留到第二阶段的锁内处理。
    # geo dat 从 staging 里就位, 由第二阶段带快照地提交(P2-②)。
    printf '%s' "$tmp_dir"
    return 0
}

# 阶段二(锁内): 用 staging 里的产物**提交**这次替换。所有共享状态改动都在这里。
# 返回 0 = 二进制已就位(还没验证服务); 1 = 失败(调用方按既有回滚路径处理)。
# 用法: _xray_commit_staged <staging目录>
# 返回三态(十四轮协议): **调用方必须消费返回码**, 不得把所有非 0 都当成"没动过":
#   0 = replacing 阶段的 mutation batch 完成(binary/geo 已就位, 尚未验证服务)
#   1 = staging 不可用, 或 phase barrier 明确仍停在 snapshotted; 未 stop/未触碰生产文件
#   3 = replacing 已 durable, 后续 mutation 可能部分发生; caller 必须运行 journal recovery
# 从 replacing 到恢复完成前, journal 与 snapshots 均不得由调用方直接丢弃。
# Commit helper is entered only after all recovery sources are snapshotted.
# Return contract (caller must consume): 0=mutation stage completed; 1=journal confirms no mutation
# started; 3=mutation may have begun or phase durability is uncertain, so journal recovery is mandatory.
_xray_commit_staged() {  # <staging_dir> -- 0=mutation batch complete; 1=mutation never started; 3=recovery required
    local tmp_dir="$1" j binbak pre gd tmp phase
    [ -d "$tmp_dir" ] && [ -f "${tmp_dir}/xray" ] || {
        _error "staging 目录不可用: ${tmp_dir:-（空）}"; return 1; }
    j=$(_xray_core_journal_path)
    # **Phase barrier**(十四轮 P1-①): replacing 在第一条真实 mutation(包括 stop)之前 durable 落盘。
    # 若写入/回读失败, 重新读 journal 区分确定未推进(1)与落盘状态不明(3); 两条路径都尚未 stop。
    if ! _xray_core_journal_phase "replacing"; then
        phase=$(jq -r '.phase // empty' "$j" 2>/dev/null) || phase=""
        [ "$phase" = snapshotted ] && return 1
        return 3
    fi
    # 从此 phase 起任何失败都 return 3, 外层只能交给 journal recovery, 不得 drop 账本/快照。
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

    # geo assets 是同一事务的真实状态; snapshotted phase 之前已为每个 dat 建好唯一快照。
    # live 文件用同目录 temp + cmp + rename, 任何失败统一 return 3 交给 rollback。
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
# geo dat 的事务侧恢复(十四轮协议): rollback 始终从 journal 指向的事务唯一快照重放;
# 删除快照统一由 _xray_core_cleanup_sources 执行, 并在删 journal 前检查所有残留。
# ---------------------------------------------------------------------------
_xref_snapshot_geo_dats() {  # <journal> -- unique transaction paths are recorded in the journal
    local j="$1" gd src bak pre hash
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
            _xray_core_journal_set_hash "$j" "${gd}_sha256" "$bak" || return 1
        else
            ! _xray_core_path_present "$src" || { _error "$gd.dat 在快照阶段被外部创建: $src"; return 1; }
            ! _xray_core_path_present "$bak" || { _error "$gd.dat 唯一快照路径已存在: $bak"; return 1; }
            hash=$(jq -r --arg g "$gd" '.[$g + "_sha256"] // empty' "$j" 2>/dev/null) || return 1
            [ -z "$hash" ] || { _error "$gd.dat 原先不存在但 journal 却记录了快照 hash"; return 1; }
        fi
    done
    return 0
}

_xref_restore_geo_dats() {  # <journal> -- retain snapshot sources until rolled_back phase is durable
    local j="$1" gd src bak pre expected got failed=0
    for gd in geoip geosite; do
        src="$ASSET_DIR/${gd}.dat"
        pre=$(jq -r --arg g "$gd" '.[$g + "_preexisted"]' "$j" 2>/dev/null) || { failed=1; continue; }
        bak=$(jq -r --arg g "$gd" '.[$g + "_backup"]' "$j" 2>/dev/null) || { failed=1; continue; }
        expected=$(jq -r --arg g "$gd" '.[$g + "_sha256"]' "$j" 2>/dev/null) || { failed=1; continue; }
        if [ "$pre" = true ]; then
            if [ ! -f "$bak" ] || [ -L "$bak" ]; then
                _error "$gd.dat 恢复源丢失或不是普通文件: $bak"
                failed=1
            else
                got=$(_xray_core_sha256_file "$bak") || got=""
                if [ -z "$got" ] || [ "$got" != "$expected" ]; then
                    _error "$gd.dat 恢复源 hash 不符/不可读, 拒绝写回并保留现场: $bak"
                    failed=1
                elif ! _xray_restore_file_atomic "$bak" "$src" 644; then
                    _error "$gd.dat 原子恢复失败: $src (源保留: $bak)"
                    failed=1
                elif ! cmp -s "$bak" "$src" 2>/dev/null; then
                    _error "$gd.dat 恢复后校验不一致: $src"
                    failed=1
                fi
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
# 核心切换失败时的**统一还原入口**(2026-09-22 九轮 OCR #15)。
#
# 背景: `_xray_commit_staged` 在**校验第 2..N 步之前**就把 $XRAY_BIN 换成了新二进制,
# 旧的那个只存在于 `$XRAY_BIN.bak`。于是"替换之后、提交之前"的任何一步失败(配置初始化 /
# service 文件生成 / 稳定运行确认)都必须把三者一起还原:
#   1. `$XRAY_BIN.bak` → `$XRAY_BIN`(磁盘上是旧核心)
#   2. service 文件写回替换前的那一份(十轮 P1-④) —— 否则"旧核心 + 半截/多余注入的 unit"
#      仍是坏组合: 例如旧核心需要 `Environment=XRAY_LOCATION_ASSET`, 而被写坏的新 unit 没有,
#      还原了二进制也起不来
#   3. 重启(尽力; 失败只告警 —— 此时正确性优先于可用性)
#   4. state 的 version/channel 写回**替换前**的值, 描述"磁盘上实际那个二进制"
#
# 为什么做成函数而不是在三处各写一遍: 三段的判据必须逐字一致(有无 `.bak`、要不要重启、
# state 写什么), 而项目里"同一条件在各调用点各自解释"已被反复证明会漂移(见 _rename_node_*
# 与 _reality_node_mode 的取舍)。差异部分由参数表达: `$3=binary_kept` 表示"无 .bak 可还原,
# 新二进制保留在盘上", 此时 state 记新版本是**准确的**。
#
# 用法: _xray_restore_prev_bin <旧版本号> <旧通道> [binary_kept]
#   返回 0 = **完整**还原到旧核心(二进制 + service 都回到改动前);
#        1 = 无 .bak(新二进制保留), 或二进制本身没还原成功;
#        2 = 二进制已还原但 **service 没能还原**(见下, 是刻意区分的第三态)。
#
# **为什么 service 状态必须进返回码(2026-09-22 十一轮 P1-①)**: 旧写法三处都写
# `_xray_service_restore_prev || true`, 于是"unit 还原失败"被吞掉后照样 restart、照样写
# 旧 version/channel、照样 `return 0` —— 调用方据此认为回滚成功, 而盘上可能是
# "旧二进制 + 新/损坏 unit"。这不是显示问题: unit 里的 `Environment=XRAY_LOCATION_ASSET`
# 按核心版本门控注入, 旧核心配错 unit 会直接起不来(geo dat 找不到)。
# 判据因此改为: **两侧都还原成功才算 0**。
# ---------------------------------------------------------------------------
_xray_restore_prev_bin() {
    local cur="$1" prev_channel="${2:-}" binary_kept="${3:-}"
    local svc_ok=1
    # geo dat 与二进制同属"核心运行依赖", 回滚时一并换回(P2-②)。放在最前: 它不依赖其它
    # 步骤的结论, 失败只影响 disk 判据(下面按 svc_ok 汇总)。
    if declare -F _xref_restore_geo_dats >/dev/null 2>&1; then
        _xref_restore_geo_dats || svc_ok=0
    fi
    if [ ! -f "$XRAY_BIN.bak" ]; then
        # 首次安装: 没有旧二进制可回。**不删**刚落地的新二进制 —— 用户可能仍可用它,
        # 删掉只会把"核心能跑但 service 没建好"变成"完全没核心"。
        _warn "无旧核心备份可还原, 保留已落地的二进制 v${cur:-?}(service/config 可能未就绪)"
        # unit 是**独立于二进制**的一侧: 即使没有旧二进制可回, 本次新建/写坏的 unit 也必须
        # 复原到事务前的状态, 否则"没有核心 + 半截 unit"比现状更难恢复(P1-④)。
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
        _warn "还原旧核心后服务未能拉起, 请手动检查: xd 菜单 [核心管理]"
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
        _tip "临时可用: xd 菜单 [核心管理] 重装一次该通道, 会按当前核心版本重写 service"
        return 2
    fi
    _warn "已还原到旧核心 v${recv:-?}"
    return 0
}

# ---------------------------------------------------------------------------
# 核心切换的**互斥锁**(2026-09-22 十一轮 P2-③)。
#
# config 修改 / Reality 事务 / Hy2 端口事务都在 `_with_config_lock` 里, 唯独核心切换没有
# 任何互斥: 两个 `xd` 会话同时切核心时会并发操作同一组文件 —— `$XRAY_BIN` + `.bak` +
# unit 快照(`xray-service.prev`, 路径固定!) + state/version+channel。单次事务各自的
# 内部一致性都对, 但两次事务之间会互相覆盖彼此的**快照**, 于是回滚用的可能不是自己那份源。
# TUI 是单管理员的, 所以这属于并发边界而非高频路径(定 P2), 但既然其它三个事务都有锁,
# 这里缺一把就是"同一契约在一条路径上没落实"。
#
# 与 config 锁的关系: 两把**独立的**锁(`.core.lock` / `.config.lock`)。嵌套时加锁方向恒定
# (core → config): 只有本模块会先持 core 锁再进 config 事务, 而 config 侧的写者都不取
# core 锁 ⇒ 单向锁序不成环, 无死锁。两个包装器各自可重入, 故不自锁。
#
# 锁 fd 必须动态分配并**在派生服务进程时关闭**(`{fd}>&-`): 写死 fd 会与 _with_config_lock
# 的 fd 9 相撞(install.sh 实测过这类相撞会静默释放锁); 不关闭则被 supervise-daemon/nohup
# 起的 xray 进程继承 —— 守护进程不退, 锁永不释放, 后续所有切换白等 15s 超时。
# 实测: `sleep 30 {fd}>&- &` 后父进程退出, 锁立即免费; 不关闭则被子进程持有。
# 因此 `_manage_xray` 派生守护进程时用 `${CORE_LOCK_FD:-9}>&-` 一并关闭: 未持锁时它退化为
# 关掉那个同样没在用的 fd 9(实测 no-op 且 rc=0), 持锁时则精确关掉锁 fd。
# ---------------------------------------------------------------------------
export CORE_LOCK_FD=9      # 未持锁时的默认值: 9 在本模块只用于关闭服务进程继承的 fd
_with_core_lock() {
    local lockf="$DEPLOY_DIR/.core.lock"
    # 已是持锁状态(嵌套调用) ⇒ 直接跑, 不再重复加锁
    if [ "${XRAY_DEPLOY_CORE_LOCK_HELD:-0}" = "1" ]; then
        "$@"     # 与 _with_config_lock 同一降级口径: 无 flock 时放行(已声明, 非静默吞错)
        return $?
    fi
    if ! command -v flock >/dev/null 2>&1; then
        "$@"
        return $?
    fi
    mkdir -p "$DEPLOY_DIR" 2>/dev/null
    if ! eval "exec {CORE_LOCK_FD}>>\"\$lockf\""; then
        _error "无法创建核心锁文件 $lockf(目录不可写?), 放弃本次操作"
        return 1
    fi
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        flock -n "$CORE_LOCK_FD" 2>/dev/null && break
        sleep 1
    done
    if ! flock -n "$CORE_LOCK_FD" 2>/dev/null; then
        _error "等待核心锁超时(15s), 可能有其他 xd 会话正在切换核心"
        # 超时路径同样要关掉刚打开的 fd: 菜单是长驻循环, 漏掉会让每次失败都泄漏一个 fd,
        # 最终撞上 ulimit 后连 _state_set 的 mktemp 都开始失败。
        eval "exec ${CORE_LOCK_FD}>&-" 2>/dev/null
        return 1
    fi
    # 子 shell 内执行: 使 CORE_LOCK_FD 与 HELD 标记的作用域跟着这次加锁一起消失,
    # 调用方不必手工回滚环境(与 _with_config_lock 同款做法)。
    (
        XRAY_DEPLOY_CORE_LOCK_HELD=1
        export XRAY_DEPLOY_CORE_LOCK_HELD
        "$@"
    )
    local rc=$?
    eval "exec ${CORE_LOCK_FD}>&-" 2>/dev/null
    return $rc
}

# ---------------------------------------------------------------------------
# 核心切换事务的**状态机 + 崩溃恢复**(2026-09-22 十二轮; 十一轮建立, 本轮补齐两次闭环)。
#
# 为什么要有账本: 函数返回失败这条路径可以靠 `|| 回滚` 覆盖, 但**进程被杀**(SIGKILL / OOM /
# 掉电)时没有任何函数会被调用, 盘上留"新二进制 + 旧 .bak + 新 unit"而下次开机无人判断。
# 同项目的 `_port_txn` 早已用"先落 journal → 启动期按事实收敛"处理这类窗口。
#
# 阶段转移(**单向, 只允许向后推进**):
#   prepared → snapshotted → binary_replaced → service_replaced → restart_verified
#            → committed → (cleanup) → 删账本
#
# **每个 phase 只能有一种现实解释**(十三轮 P1-①, 这是协议层的要求):
#   prepared     = 账本已建, 恢复源**未**就绪。真实状态从未被触碰
#                  ⇒ 崩溃后只清理中间产物, 绝不回滚(快照可能半截, 不能当恢复源)
#   snapshotted  = 恢复源(binary .bak / unit 快照 / geo 快照)全部就绪, 真实状态仍未动
#                  ⇒ 崩溃后同样只清理(没有需要恢复的东西)
#   binary_replaced / service_replaced / restart_verified
#                = 真实状态已被改动 ⇒ 崩溃后**回滚**
#   committed    = 永不回滚, 只允许 cleanup
#
# 两条闭环各自要成立(十二轮复审指出的正是它们没成立):
#   · **提交闭环**: `committed` 必须先于清理备份落盘。否则"已删 .bak、账本还写着可回滚"的
#     窗口会让恢复无源可回(旧顺序就是这样: 先 rm .bak 再删账本)。
#     落盘 committed 之后**永不再回滚**, 只继续清理 —— 清理中断也只是残留备份, 下次看到
#     committed 就把清理做完。所以"清理"是幂等的、可重复执行的。
#   · **恢复闭环**: 恢复必须把"磁盘 + **运行实例**"一起收敛。只改文件不重启会让
#     "磁盘=旧核心 / 内存里跑着新核心"长期并存(十一轮的实现只改文件)。
#
# 判据三态, 任一为 0 即**不完整**: disk_ok(二进制+service 落盘)、run_ok(服务真的跑起来
# 且版本正确)。不完整时账本**保留**、返回 1, 并拒绝开启新事务(P1-⑤: 否则新事务会覆盖
# 上一次未收敛事务的唯一证据)。
#
# fail-closed: 账本不可解析 / schema 不合法 ⇒ **隔离**(改名 .corrupt)并告警, 绝不按猜测动作
# ——与 `_ptx_journal_quarantine` 同策。账本落 $STATE_DIR(已 chmod 700), 它是账本不是产物。
# ---------------------------------------------------------------------------
_xray_core_journal_path() { printf '%s' "$STATE_DIR/coretxn.json"; }
_xray_core_blocked_path() { printf '%s' "$STATE_DIR/coretxn.blocked"; }
_xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }

_xray_core_sha256_file() {
    local file="$1" hash
    command -v sha256sum >/dev/null 2>&1 || return 1
    hash=$(sha256sum "$file" 2>/dev/null | awk '{print tolower($1)}')
    [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s' "$hash"
}

_xray_core_journal_set_hash() {  # <journal> <hash-field> <snapshot-file>
    local j="$1" key="$2" file="$3" hash
    case "$key" in geoip_sha256|geosite_sha256|service_sha256) ;; *) return 1 ;; esac
    hash=$(_xray_core_sha256_file "$file") || {
        _error "无法计算事务快照 SHA256: $file"
        return 1
    }
    _meta_update "$j" '.[$k]=$h' --arg k "$key" --arg h "$hash" || return 1
    [ "$(jq -r --arg k "$key" '.[$k] // empty' "$j" 2>/dev/null)" = "$hash" ] || {
        _error "事务快照 SHA256 写入回读不一致: $file"
        return 1
    }
    return 0
}

# 写新账本。调用前必须已过 core lock + pending gate。账本写入拒绝覆盖任何旧 journal。
# 参数: <old_version> <old_channel> <new_tag> <channel> <staging_dir>
_xray_core_journal_write() {  # <old_version> <old_channel> <new_tag> <channel> <staging_dir>
    local old_ver="$1" old_ch="$2" new_tag="$3" new_ch="$4" stage="$5"
    local j payload txn_id binary_preexisting runtime_was_running=false old_state_ver old_hash unit sprev
    local geoip_pre geosite_pre service_pre=false
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
    sprev=$(_xray_service_prev_path)
    unit=$(_xray_service_unit_path 2>/dev/null || printf '')
    if [ -n "$unit" ] && _xray_core_path_present "$unit"; then service_pre=true; fi
    geoip_pre=false; geosite_pre=false; old_hash=""
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
    if [ "$binary_preexisting" = true ]; then
        old_hash=$(_xray_core_sha256_file "$XRAY_BIN") || {
            _error "无法计算旧核心 SHA256, 事务中止"; return 1; }
    fi
    [ -f "$ASSET_DIR/geoip.dat" ] && geoip_pre=true
    [ -f "$ASSET_DIR/geosite.dat" ] && geosite_pre=true
    payload=$(jq -n \
        --arg id "$txn_id" --arg ov "$old_ver" --arg osv "$old_state_ver" --arg oc "$old_ch" \
        --arg nt "$new_tag" --arg nc "$new_ch" --arg bin "$XRAY_BIN" --arg bak "${XRAY_BIN}.bak" \
        --arg bh "$old_hash" --arg unit "$unit" --arg sprev "$sprev" --arg stage "$stage" \
        --arg gip "$ASSET_DIR/.geoip.dat.coretxn.${txn_id}.bak" \
        --arg gsp "$ASSET_DIR/.geosite.dat.coretxn.${txn_id}.bak" \
        --arg shash "" --arg ghash "" --arg gshash "" \
        --argjson bp "$binary_preexisting" --argjson runtime "$runtime_was_running" \
        --argjson gipre "$geoip_pre" --argjson gspre "$geosite_pre" --argjson spre "$service_pre" \
        '{phase:"prepared", txn_id:$id, old_version:$ov, old_state_version:$osv, old_channel:$oc,
          new_tag:$nt, channel:$nc, binary:$bin, binary_preexisted:$bp, binary_sha256:$bh,
          runtime_was_running:$runtime, binary_backup:$bak, unit:$unit, service_prev:$sprev, staging_dir:$stage,
          geoip_preexisted:$gipre, geoip_backup:$gip, geoip_sha256:$ghash,
          geosite_preexisted:$gspre, geosite_backup:$gsp, geosite_sha256:$gshash,
          service_preexisted:$spre, service_sha256:$shash}') || return 1
    _atomic_write_json "$j" "$payload"
}

# 最终验证全体恢复源后才能进入 snapshotted。单个 snapshot helper 的 cmp 保证写入当时完整;
# 这里再验证 journal 中已 durable 记录的 hash 与全部 sidecar, 让该 phase 成为可依赖的屏障。
_xray_core_snapshots_ok() {  # <journal>
    local j="$1" bin bak pre hash got gd src unit sprev service_pre service_hash flag want
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    hash=$(jq -r '.binary_sha256' "$j" 2>/dev/null) || return 1
    if [ "$pre" = true ]; then
        [ -f "$bak" ] && [ ! -L "$bak" ] || { _error "binary 恢复源缺失/无效: $bak"; return 1; }
        got=$(_xray_core_sha256_file "$bak") || got=""
        [ -n "$got" ] && [ "$got" = "$hash" ] || { _error "binary 恢复源 hash 不符: $bak"; return 1; }
    else
        ! _xray_core_path_present "$bak" || { _error "首次安装不应存在 binary 恢复源: $bak"; return 1; }
    fi

    for gd in geoip geosite; do
        src="$ASSET_DIR/${gd}.dat"
        pre=$(jq -r --arg g "$gd" '.[$g + "_preexisted"]' "$j" 2>/dev/null) || return 1
        bak=$(jq -r --arg g "$gd" '.[$g + "_backup"]' "$j" 2>/dev/null) || return 1
        hash=$(jq -r --arg g "$gd" '.[$g + "_sha256"]' "$j" 2>/dev/null) || return 1
        if [ "$pre" = true ]; then
            [ -f "$bak" ] && [ ! -L "$bak" ] || { _error "$gd.dat 恢复源缺失/无效: $bak"; return 1; }
            got=$(_xray_core_sha256_file "$bak") || got=""
            [ -n "$got" ] && [ "$got" = "$hash" ] || { _error "$gd.dat 恢复源 hash 不符: $bak"; return 1; }
        else
            ! _xray_core_path_present "$bak" || { _error "原先不存在的 $gd.dat 却有恢复源: $bak"; return 1; }
            [ -z "$hash" ] || return 1
        fi
    done

    unit=$(jq -r '.unit' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    service_pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    service_hash=$(jq -r '.service_sha256' "$j" 2>/dev/null) || return 1
    if [ -n "$unit" ]; then
        flag="${sprev}.enabled"
        [ -f "$flag" ] && [ ! -L "$flag" ] || { _error "service enable snapshot 缺失/无效: $flag"; return 1; }
        want=$(cat "$flag" 2>/dev/null) || return 1
        case "$want" in enabled|disabled) ;; *) _error "service enable snapshot 内容非法: $flag"; return 1 ;; esac
        if [ "$service_pre" = true ]; then
            [ -f "$sprev" ] && [ ! -L "$sprev" ] && \
                ! _xray_core_path_present "${sprev}.absent" || {
                _error "pre-existing service snapshot 缺失/含糊: $sprev"; return 1; }
            got=$(_xray_core_sha256_file "$sprev") || got=""
            [ -n "$got" ] && [ "$got" = "$service_hash" ] || {
                _error "service 恢复源 hash 不符: $sprev"; return 1; }
        else
            _xray_core_path_present "$sprev" && { _error "新 service 不应存在内容快照: $sprev"; return 1; }
            [ -f "${sprev}.absent" ] && [ ! -L "${sprev}.absent" ] || {
                _error "service absent 标记缺失/无效: ${sprev}.absent"; return 1; }
            [ -z "$service_hash" ] || return 1
        fi
    else
        [ "$service_pre" = false ] && [ -z "$service_hash" ] || return 1
    fi

    local stage; stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    [ -d "$stage" ] && [ -f "$stage/xray" ] || { _error "staging source 缺失: $stage"; return 1; }
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
        binary_replaced:service_replaced|service_replaced:restart_verified|\
        restart_verified:committed|replacing:rolled_back|binary_replaced:rolled_back|\
        service_replaced:rolled_back|restart_verified:rolled_back) allowed=1 ;;
    esac
    [ "$allowed" -eq 1 ] || { _error "非法核心事务 phase 转移: ${cur:-?} → $next"; return 1; }
    if [ "$next" = snapshotted ]; then
        _xray_core_journal_ok "$j" && _xray_core_snapshots_ok "$j" || {
            _error "恢复源未完整通过最终校验, 不推进 snapshotted"; return 1; }
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
    return 0
}

# 任意 journal (包括 committed/rolled_back 的 cleanup journal) 都必须先恢复/清理, 不能新开覆盖。
_xray_core_txn_pending() {
    local j; j=$(_xray_core_journal_path)
    _xray_core_path_present "$(_xray_core_blocked_path)" && return 0
    _xray_core_path_present "${j}.corrupt" && return 0
    # 任意 journal 都要先让 recovery 清理(含 committed/rolled_back 的残留 cleanup),
    # 否则新事务可能覆盖旧证据或误认 stale snapshots。
    _xray_core_path_present "$j"
}
_xray_core_journal_ok() {
    local j="$1" id bin binbak pre hash runtime unit sprev stage gip gsp stage_name phase
    local gipre gspre service_pre giphash gsphash service_hash
    jq -e '
      (.phase | type == "string" and test("^(prepared|snapshotted|replacing|binary_replaced|service_replaced|restart_verified|committed|rolled_back)$")) and
      (.txn_id | type == "string" and length > 0 and test("^[A-Za-z0-9._-]+$")) and
      (.old_version | type == "string") and (.old_state_version | type == "string") and
      (.old_channel | type == "string") and (.channel | type == "string") and
      (.new_tag | type == "string" and length > 0) and
      (.binary | type == "string" and length > 0) and
      (.binary_backup | type == "string" and length > 0) and
      (.binary_preexisted | type == "boolean") and (.binary_sha256 | type == "string") and
      (.runtime_was_running | type == "boolean") and
      (.unit | type == "string") and (.service_prev | type == "string" and length > 0) and
      (.staging_dir | type == "string" and length > 0) and
      (.geoip_preexisted | type == "boolean") and (.geoip_backup | type == "string" and length > 0) and
      (.geoip_sha256 | type == "string") and
      (.geosite_preexisted | type == "boolean") and (.geosite_backup | type == "string" and length > 0) and
      (.geosite_sha256 | type == "string") and
      (.service_preexisted | type == "boolean") and (.service_sha256 | type == "string")
    ' "$j" >/dev/null 2>&1 || return 1
    phase=$(jq -r '.phase' "$j" 2>/dev/null) || return 1
    id=$(jq -r '.txn_id' "$j" 2>/dev/null) || return 1
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    binbak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    hash=$(jq -r '.binary_sha256' "$j" 2>/dev/null) || return 1
    runtime=$(jq -r '.runtime_was_running' "$j" 2>/dev/null) || return 1
    unit=$(jq -r '.unit' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    gip=$(jq -r '.geoip_backup' "$j" 2>/dev/null) || return 1
    gsp=$(jq -r '.geosite_backup' "$j" 2>/dev/null) || return 1
    gipre=$(jq -r '.geoip_preexisted' "$j" 2>/dev/null) || return 1
    gspre=$(jq -r '.geosite_preexisted' "$j" 2>/dev/null) || return 1
    service_pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    giphash=$(jq -r '.geoip_sha256' "$j" 2>/dev/null) || return 1
    gsphash=$(jq -r '.geosite_sha256' "$j" 2>/dev/null) || return 1
    service_hash=$(jq -r '.service_sha256' "$j" 2>/dev/null) || return 1

    [ "$bin" = "$XRAY_BIN" ] && [ "$binbak" = "$XRAY_BIN.bak" ] || return 1
    [ "$sprev" = "$BACKUP_DIR/xray-service.$id.prev" ] || return 1
    [ "$gip" = "$ASSET_DIR/.geoip.dat.coretxn.$id.bak" ] || return 1
    [ "$gsp" = "$ASSET_DIR/.geosite.dat.coretxn.$id.bak" ] || return 1
    case "$unit" in
        ""|/etc/systemd/system/xray.service|/etc/init.d/xray) ;;
        *) return 1 ;;
    esac
    if [ -z "$unit" ]; then
        [ "$service_pre" = false ] && [ -z "$service_hash" ] || return 1
    elif [ "$service_pre" = false ]; then
        [ -z "$service_hash" ] || return 1
    fi
    case "$stage" in
        "$BIN_DIR"/.xray-dl.*)
            stage_name=${stage#"$BIN_DIR"/}
            case "$stage_name" in .xray-dl.*) case "$stage_name" in */*) return 1 ;; esac ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    if [ "$pre" = true ]; then
        [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    else
        [ -z "$hash" ] && [ "$runtime" = false ] || return 1
    fi
    for hash in "$giphash" "$gsphash" "$service_hash"; do
        [ -z "$hash" ] || [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    done
    [ "$gipre" = true ] || [ -z "$giphash" ] || return 1
    [ "$gspre" = true ] || [ -z "$gsphash" ] || return 1
    case "$phase" in
        snapshotted|replacing|binary_replaced|service_replaced|restart_verified|committed|rolled_back)
            [ "$gipre" = false ] || [ -n "$giphash" ] || return 1
            [ "$gspre" = false ] || [ -n "$gsphash" ] || return 1
            [ "$service_pre" = false ] || [ -n "$service_hash" ] || return 1
            ;;
    esac
    return 0
}
# snapshot binary/geodata source for this journal. Called only before phase=snapshotted.
_xray_core_snapshot_binary() {  # <journal>
    local j="$1" bin bak pre hash got
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    hash=$(jq -r '.binary_sha256' "$j" 2>/dev/null) || return 1
    if [ "$pre" = true ]; then
        [ -f "$bin" ] || { _error "旧核心在快照前消失: $bin"; return 1; }
        ! _xray_core_path_present "$bak" || { _error "旧核心快照目标已存在, 拒绝覆盖: $bak"; return 1; }
        cp -p "$bin" "$bak" 2>/dev/null || { rm -f "$bak" 2>/dev/null; return 1; }
        got=$(_xray_core_sha256_file "$bak") || got=""
        if ! cmp -s "$bin" "$bak" 2>/dev/null || [ "$got" != "$hash" ]; then
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
    # 绝不能先挪走原件再 best-effort 写标记(十三轮 P1-④)。
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
    local j="$1" binbak stage sprev gip gsp left=0 f
    binbak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    stage=$(jq -r '.staging_dir' "$j" 2>/dev/null) || return 1
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    gip=$(jq -r '.geoip_backup' "$j" 2>/dev/null) || return 1
    gsp=$(jq -r '.geosite_backup' "$j" 2>/dev/null) || return 1
    rm -f "$binbak" "$sprev" "${sprev}.absent" "${sprev}.enabled" "$gip" "$gsp" 2>/dev/null
    [ -n "$stage" ] && rm -rf "$stage" 2>/dev/null
    for f in "$binbak" "$sprev" "${sprev}.absent" "${sprev}.enabled" "$gip" "$gsp"; do
        _xray_core_path_present "$f" && left=1
    done
    [ -z "$stage" ] || ! _xray_core_path_present "$stage" || left=1
    [ "$left" -eq 0 ] || { _error "事务快照清理未完成, 保留账本供重试"; return 1; }
    return 0
}
_xray_core_cleanup_after_commit() {  # <journal>
    local j="$1"
    # committed / rolled_back 都不可逆: 只清理 transaction-owned artifacts; 源/marker/journal
    # 任一残留都返回失败, 保留 terminal journal 让下次启动继续 cleanup。
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
        replacing|binary_replaced|service_replaced|restart_verified) ;;
        *) _xray_core_journal_quarantine "$j" "未知 phase=$phase"; return 1 ;;
    esac
    _xray_core_recover_rollback_locked "$j"
}

# Rollback 从 snapshot source 重放, **不消费 source**(cp→cmp→rename), 直到 rolled_back phase
# durable 才 cleanup。这样每个崩溃点都可重入: phase 还没写成功就从原 snapshot 再做一遍。
_xray_core_recover_rollback_locked() {
    local j="$1" bin bak pre was_running old_ver old_hash got_hash old_state_ver old_ch unit sprev
    local service_pre service_hash service_got run_ok=1 disk_ok=1 state_ok=1
    bin=$(jq -r '.binary' "$j" 2>/dev/null) || return 1
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null) || return 1
    pre=$(jq -r '.binary_preexisted' "$j" 2>/dev/null) || return 1
    was_running=$(jq -r '.runtime_was_running' "$j" 2>/dev/null) || return 1
    old_hash=$(jq -r '.binary_sha256' "$j" 2>/dev/null) || return 1
    old_ver=$(jq -r '.old_version' "$j" 2>/dev/null) || old_ver=""
    old_state_ver=$(jq -r '.old_state_version' "$j" 2>/dev/null) || old_state_ver=""
    old_ch=$(jq -r '.old_channel' "$j" 2>/dev/null) || old_ch=""
    unit=$(jq -r '.unit' "$j" 2>/dev/null) || unit=""
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null) || return 1
    service_pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    service_hash=$(jq -r '.service_sha256' "$j" 2>/dev/null) || return 1

    _warn "检测到未完成的核心切换事务(阶段: $(jq -r '.phase' "$j" 2>/dev/null)), 正在回滚..."
    # 先停并验证: binary 还被当前 Xray mmap/exe 使用时不能覆盖, 且恢复完成后必须按旧 binary 重启。
    if ! _xray_stop_and_verify; then
        _error "恢复前无法确认 Xray 已停止, 暂不改动 binary/service snapshots"
        _tip "事务账本与全部恢复源保留: $j"
        return 1
    fi

    # 1. binary pre-state 由**显式布尔值**描述, 绝不从 old_version 是否为空推断(十三轮 P2-③)。
    if [ "$pre" = true ]; then
        if [ ! -f "$bak" ] || [ -L "$bak" ]; then
            disk_ok=0
            _error "事务旧 binary 恢复源丢失或不是普通文件: $bak"
        else
            got_hash=$(_xray_core_sha256_file "$bak") || got_hash=""
            if [ "$got_hash" != "$old_hash" ]; then
                disk_ok=0
                _error "事务旧 binary 恢复源 hash 不符, 拒绝写回: $bak"
            elif ! _xray_restore_file_atomic "$bak" "$bin" 755; then
                disk_ok=0
                _error "旧 binary 原子还原失败: $bin (恢复源保留: $bak)"
            elif ! cmp -s "$bak" "$bin" 2>/dev/null; then
                disk_ok=0
                _error "旧 binary 还原后内容不一致: $bin"
            else
                _warn "已还原切换前的 binary(snapshot 保留到 rolled_back phase)"
            fi
        fi
    else
        if ! rm -f "$bin" 2>/dev/null || _xray_core_path_present "$bin"; then
            disk_ok=0
            _error "事务前不存在的 binary 无法移除: $bin"
        fi
    fi

    # 2. geo sources 是 transaction-unique 路径, 且 restore 保留 source 以支持 crash replay。
    _xref_restore_geo_dats "$j" || disk_ok=0

    # 3. service: hash 与显式 pre-existence 都由 journal 绑定。快照损坏或两种状态标记
    # 同时存在时拒绝写回/删除, 保留 journal 和恢复源等待人工处理。
    if [ -n "$unit" ]; then
        if [ "$service_pre" = true ]; then
            if [ -f "$sprev" ] && [ ! -L "$sprev" ] && ! _xray_core_path_present "${sprev}.absent"; then
                service_got=$(_xray_core_sha256_file "$sprev") || service_got=""
                if [ "$service_got" != "$service_hash" ]; then
                    disk_ok=0
                    _error "service 恢复源 hash 不符, 拒绝写回并保留现场: $sprev"
                elif ! _xray_service_restore_file "$sprev" "$unit"; then
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
                if ! _xray_service_restore_enable "${sprev}.enabled" keep; then
                    disk_ok=0
                    _error "service 开机自启状态未恢复, journal 与恢复源保留供重试"
                fi
            else
                disk_ok=0
                _error "service 开机自启快照缺失或无效, 保留 journal: ${sprev}.enabled"
            fi
        elif [ -f "${sprev}.absent" ] && [ ! -L "${sprev}.absent" ] && \
             ! _xray_core_path_present "$sprev" && \
             [ -f "${sprev}.enabled" ] && [ ! -L "${sprev}.enabled" ]; then
            # 先移除 enable/link, 再删新 unit; 这样 systemd/OpenRC 仍能解析该服务名。
            # 必须保留 unit, 直到 enable state 确认恢复; 否则失败后的重试可能已无可操作目标。
            if ! _xray_service_restore_enable "${sprev}.enabled" keep; then
                disk_ok=0
                _error "新建 service 的开机自启状态未恢复, 保留 unit 与恢复账本供重试"
            elif ! rm -f "$unit" 2>/dev/null || _xray_core_path_present "$unit"; then
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

    # 5. 只有磁盘+runtime 都已收敛后才恢复展示 state(十三轮 P2-④)。失败现场绝不把当前残缺
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

# ---------------------------------------------------------------------------
# 安装或切换 Xray 核心(R3)
# 用法:_install_or_switch_xray <channel>
#   未安装 -> 安装该通道最新版
#   已安装 -> 切换到该通道最新版(配置与节点不动)
# 并发模型(十二轮 P2-③ 收窄锁域):
#   · 阶段一 `_xray_stage_release` **在锁外** —— 它只写下自己独有的 staging 目录, 不碰任何
#     共享状态, 所以网络等待/下载/解压(可能 40s+)不需要互斥, 也就不会把另一个会话拖成
#     15s 锁超时。
#   · 阶段二 `_xray_commit_staged` **在锁内** —— 快照/账本/替换/重启全部在这里, 与
#     _xray_core_txn_recover 同一把 .core.lock。
# 两把锁(.core.lock / .config.lock)的加锁方向恒定 core → config(只有本模块会先持 core 锁),
# 单向不成环 ⇒ 无死锁; 两个包装器各自可重入, 故不自锁。
# ---------------------------------------------------------------------------
_install_or_switch_xray() {
    local channel="$1" tag staged rc=0
    case "$channel" in
        stable|preview) ;;
        *) _error "未知通道: $channel"; return 1 ;;
    esac
    _ensure_dirs || return 1
    # 在取件**之前**先看一眼门禁: 明知有未收敛事务就不该白下载一遍(几十 MB)。
    # 真正的门禁仍在锁内那一次(两次检查之间可能有另一个会话产生账本)。
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
    tag=$(_xray_fetch_tag "$channel") || {
        _error "无法获取 ${channel} 通道最新版本(网络?)"
        return 1
    }
    _info "${channel} 通道最新版本: ${tag}"
    # ---- 阶段一(锁外): 下载/校验/解压到自有 staging ----
    staged=$(_xray_stage_release "$tag")
    if [ -z "$staged" ] || [ ! -f "${staged}/xray" ]; then
        _error "获取 ${channel} 版本失败(网络/校验/解压?), 未做任何改动"
        [ -n "$staged" ] && rm -rf "$staged" 2>/dev/null
        return 1
    fi
    # ---- 阶段二(锁内): 提交(把 staging 路径与已解析的 tag 交给提交体) ----
    _with_core_lock _install_or_switch_xray_locked "$channel" "$staged" "$tag" || rc=$?
    rm -rf "$staged" 2>/dev/null
    return $rc
}

_install_or_switch_xray_locked() {
    # $1=通道 $2=staging 目录(锁外已下载校验) $3=目标 tag
    local channel="$1" staged="$2" tag="$3" cur="" prev_channel="" newv=""
    case "$channel" in stable|preview) ;; *) _error "未知通道: $channel"; return 1 ;; esac
    _ensure_dirs || return 1

    # 锁内第二道门禁: 锁外取件后可能有别的会话产生/隔离事务账本。
    if _xray_core_txn_pending; then
        _error "存在未完成或 BLOCKED 的核心事务, 已拒绝开始新的切换"
        _tip "请先按提示处理: $(_xray_core_journal_path) / $(_xray_core_blocked_path)"
        return 1
    fi
    cur=$(_xray_current_version 2>/dev/null) || cur=""
    prev_channel=$(_state_get channel 2>/dev/null) || prev_channel=""

    # 配置只读快照(核心切换不改 config, 但保留历史备份)。此动作不属于 core mutation。
    if ! _backup_config; then
        _error "配置备份失败, 取消核心切换"
        return 1
    fi
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

    # version/channel 仍为两个独立 display state; 写失败告警但不反向回滚已验证运行的核心。
    # 恢复路径仅在成功收敛后恢复 old_state_version/old_channel, 不会在失败现场记录当前错误值。
    if [ -n "$newv" ]; then
        if ! _state_set channel "$channel"; then
            _warn "状态持久化失败(channel), 本次核心已运行但 channel 显示可能滞后"
        elif ! _state_set version "$newv"; then
            _warn "状态持久化失败(version), 正在尽力恢复 channel 记录"
            if [ -n "$prev_channel" ]; then
                _state_set channel "$prev_channel" 2>/dev/null || \
                    _warn "channel 恢复失败, 状态显示可能不准"
            else
                rm -f "$STATE_DIR/channel" 2>/dev/null || true
            fi
        fi
    else
        _warn "无法读取新核心版本, 跳过 version/channel 记录"
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
# 仅在 config.json 不存在或为空时写
#
# 并发(F5): 与项目里所有其他 config 写路径一样在 _with_config_lock 内执行 —— 这是
# 一次 read-decide-write(先判空再写), 与并发的 geo 更新/节点事务交叠时会互相覆盖。
# _with_config_lock 经 XRAY_DEPLOY_LOCK_HELD 可重入, 故被 _mutate_config 调用时不会自锁死。
# ---------------------------------------------------------------------------
_init_config_if_empty() {
    _with_config_lock _init_config_if_empty_locked "$@"
}

_init_config_if_empty_locked() {
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        return 0
    fi
    _ensure_dirs || return 1
    # 美化多行格式(便于手动编辑) + routing 规则(bt/广告/私网/CN 走 block)
    # 按 Xray 官方文档顺序排列(env → log → dns → routing → inbounds → outbounds)
    # env 段设置 XRAY_LOCATION_ASSET(docs/config/env.md): 核心 ≥ v26.7.11 在构建模块前
    # 应用该段, geo 文件按此路径加载; 旧核心忽略该字段, 由 service 文件注入同名变量兜底。
    # routing.rules 先留空占位, 下面由 XRAY_DEFAULT_ROUTING_RULES_JSON 注入 ——
    # 默认规则集是唯一真相(00-common), [9] 路由规则的"恢复默认"复用同一常量, 不允许两处硬编码。
    local base='{
  "env": {
    "XRAY_LOCATION_ASSET": "'"$ASSET_DIR"'"
  },
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
# 启动自动操作(R45): 确保 config.json 带 env.XRAY_LOCATION_ASSET
# 背景: 新部署的默认配置已含 env 段(见 _init_config_if_empty), 但存量部署的 config 没有。
# 新核心(≥ v26.7.11)靠该段定位 geo 文件, 若缺失且 service 文件也不再注入, geo 会静默失效;
# 旧核心忽略该字段(service 注入兜底仍在), 提前补上无副作用, 未来切到新核心即可无缝生效。
# 幂等: 仅当 env.XRAY_LOCATION_ASSET 缺失时注入; 用户手改的值不被覆盖。不重启服务
# (与 _normalize_config_format 同级), 只保证磁盘上的 config 自描述, 下次重启生效。
# 失败静默(启动路径不阻塞), 由下次启动重试。
#
# **读-改-写必须在 _with_config_lock 内**(2026-09-22 九轮 OCR #17)。旧写法直接读 config
# 再 `_atomic_write_json` 覆盖 —— 而 `_atomic_write_json` 是 rename 语义, 会把**整份文件**
# 换成它读到的旧快照 + env。若这中间另有写者提交了改动(另一会话的节点操作、cron 的
# geo-update 后重启、或 `_mutate_config` 的事务体), 那些改动会被这份旧快照**静默丢弃**。
# 同文件的 `_init_config_if_empty` 早已是这个 wrapper 形态(见它的 `_locked`), 这里补齐口径。
# ---------------------------------------------------------------------------
_auto_ensure_config_env_locked() {
    [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local need
    # .env 非对象时 `.env.XRAY_LOCATION_ASSET` 会让 jq 报类型错误而整行失败 -> 前置判断
    # 必须先按类型分支(与注入处同一口径), 否则非对象 .env 会在这里提前 return 而无法自愈。
    need=$(jq -r 'if (.env | type) == "object" and ((.env.XRAY_LOCATION_ASSET // "") != "") then 0 else 1 end' "$CONFIG_FILE" 2>/dev/null) || return 0
    [ "$need" = "1" ] || return 0
    local content
    # 审查修订: .env 可能被手改成非对象(字符串/数组), 裸 `(.env // {}) + {...}` 会触发
    # jq 类型错误而静默跳过, 该次启动不自愈。这里显式按类型处理: 非对象一律视为 {} 重建。
    content=$(jq --arg a "$ASSET_DIR" '.env = ((if (.env | type) == "object" then .env else {} end) + {XRAY_LOCATION_ASSET: $a})' "$CONFIG_FILE" 2>/dev/null) || return 0
    [ -n "$content" ] || return 0
    _atomic_write_json "$CONFIG_FILE" "$content" 2>/dev/null || return 0
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
# service 文件(unit)的事务快照 —— 2026-09-22 十轮 P1-①/④。
#
# 为什么 unit 也要进回滚事务: `_create_xray_service` 是在**新二进制已落地之后**重写生产
# unit 的, 而 unit 内容与核心版本相关(env 注入按 v26.7.11 门控)。写坏/写残 unit 之后只还原
# 二进制的"部分回滚"会留下两种残局: "旧核心 + 半截 unit", 或者"旧核心 + 不含 env 注入的
# unit"(后者会让旧核心找不到 geo dat 而起不来)。故与 $XRAY_BIN.bak 对称地留一份 unit 快照:
#   · 原本有 unit ⇒ 存内容, 失败时写回(含 openrc 必需的 +x 位)
#   · 原本没有   ⇒ 存 .absent 标志, 失败时删掉本次新建的那个
# 快照落 $BACKUP_DIR 而不是 /etc: unit 目录里多出的文件没有任何好处, 反而可能被
# daemon-reload 扫到。$BACKUP_DIR 的轮转只清 ^config\.json\.bak\. 前缀, 不会碰它。
# ---------------------------------------------------------------------------
# 当前 init 后端对应的 unit 路径(direct 后端无 unit ⇒ 返回 1)
_xray_service_unit_path() {
    case "${INIT_SYSTEM:-}" in
        systemd) printf '%s' '/etc/systemd/system/xray.service' ;;
        openrc)  printf '%s' '/etc/init.d/xray' ;;
        *) return 1 ;;
    esac
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
_xray_service_snapshot_enable() {  # <unit路径> <标志文件路径>
    local unit="$1" flag="$2" want=""
    want=$(_xray_service_enable_state) || {
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
# 返回 1 = 恢复动作失败(调用方据此判定"回滚不完整")。
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
    local unit prev j pre
    unit=$(_xray_service_unit_path) || return 0    # direct 后端: 无 unit 可写, 无需快照
    j=$(_xray_core_journal_path)
    pre=$(jq -r '.service_preexisted' "$j" 2>/dev/null) || return 1
    prev=$(_xray_service_prev_path)
    mkdir -p "$BACKUP_DIR" || return 1
    if _xray_core_path_present "$prev" || _xray_core_path_present "${prev}.absent" || \
       _xray_core_path_present "${prev}.enabled"; then
        _error "service snapshot 路径已存在, 拒绝覆盖旧恢复源: $prev"
        return 1
    fi
    # service 写入会同时变更 enable 状态; 两个维度都必须在 snapshotted 前可恢复。
    _xray_service_snapshot_enable "$unit" "${prev}.enabled" || return 1
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
    _xray_core_journal_set_hash "$j" service_sha256 "$prev" || return 1
    return 0
}

# 回滚时把 unit 恢复到快照状态(只在快照存在时动手; 无快照 = 本次事务没碰过 unit)。
_xray_service_restore_prev() {
    local unit prev
    unit=$(_xray_service_unit_path) || return 0
    prev=$(_xray_service_prev_path)
    if [ -f "${prev}.absent" ]; then
        # 事务之前没有 unit ⇒ 把本次新建的那个删掉, 回到"本来就没有"
        # **rm 失败必须报出来**(十二轮 P1-③): 旧写法无条件 `return 0`, 于是"旧二进制 +
        # 残留新 unit"被当成恢复成功 —— 而 unit 存不存在恰恰决定旧核心能否找到 geo dat。
        if ! rm -f "$unit" 2>/dev/null; then
            _error "撤销新建 service 文件失败, 请手动删除: $unit"
            return 1
        fi
        rm -f "${prev}.absent" 2>/dev/null || \
            _warn "service 快照标志删除失败(不影响 service 状态): ${prev}.absent"
        # 事务之前连 unit 都不存在 ⇒ 那时也不可能处于"已 enable"的合理状态; 若本次
        # 顺带 enable 了, 撤销它(仅在快照存在时动)。
        # **失败只告警**: 它只影响下次开机的自启策略, 不影响核心本身能否运行; 计入失败会让
        # "启用态恢复失败"永久阻塞收敛 ⇒ 账本永不被删 ⇒ 新切换被门禁永久拒绝。用一个更坏的
        # 失效模式去换一个更轻的差异不划算(与权限设置失败只告警同一取舍)。
        _xray_service_restore_enable "${prev}.enabled" || \
            _warn "service 开机自启状态未能还原(不影响当前运行), 请按上方提示手动执行"
        _warn "已撤销本次新建的 service 文件(事务之前不存在): $unit"
        return 0
    fi
    # 快照缺失 ⇒ **不是"无需恢复"**(十二轮 P1-③)。事务开始时强制做过快照, 所以走到这里
    # 说明证据丢了; 报失败让调用方保留账本/不宣布成功, 而不是静默返回 0 让"新 unit"留在盘上。
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
    rm -f "$prev" "${prev}.absent" "${prev}.enabled" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 生成 service 文件
# R45: XRAY_LOCATION_ASSET 优先走 config.json 的 env 段(docs/config/env.md, 核心 ≥
# v26.7.11 在构建模块前应用该段并替换同名进程变量)。仅当已安装核心 < v26.7.11(不识别
# env 段)时才在 service 文件注入同名环境变量兜底 —— 版本读不到时保守保留注入(旧行为)。
# 注意: _install_or_switch_xray 先替换二进制再调本函数, 这里读到的是"新"核心版本。
# ---------------------------------------------------------------------------
_create_xray_systemd_service() {
    local nofile_line="" env_line=""
    local _nf; _nf=$(_safe_nofile)
    [ -n "$_nf" ] && nofile_line="LimitNOFILE=$_nf"
    if ! _xray_version_ge "26.7.11"; then
        env_line="Environment=XRAY_LOCATION_ASSET=${ASSET_DIR}"
    fi
    # unit 写入必须**检查结果**(2026-09-22 九轮 OCR #18 的 systemd 分支)。旧写法把
    # `cat > 文件` 的返回码丢在地上, 磁盘满/只读/权限异常时会留下**半截或陈旧的 unit**,
    # 而后面的 daemon-reload 可能照样成功 ⇒ 函数返回 0, 调用方据此认定"切换已提交"。
    # 校验方式与 logrotate 同思路: 重定向失败即失败(不必回读比对 —— unit 内容由本函数
    # 现算, 不存在并发写者, 而 systemd 会自己解析语法)。
    # **不改成 mv**: openrc 侧需要 `chmod +x` 后的 init.d 脚本, 而 systemd 侧的 644 由下面
    # 的 chmod 显式给 —— 保留 `cat` 提交是项目已验证的形态(见 CLAUDE.md 的同类取舍)。
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
# 2026-09-12 三审(S1) 最小加固: xray 运行期不需要 exec 任何 setuid/setgid 程序,
# NoNewPrivileges 只是一次 prctl 调用, 不依赖 capability, 在受限容器(LXC/Podman)内同样生效,
# 不会触发 OpenRC capabilities 那类 exec 前 EPERM(H2 同类风险为零)。
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
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
    # R38(M14): umask 077 会让 unit 文件生成为 0600, systemd 会记 "marked
    # world-inaccessible" 告警。unit 不含机密(token 在 cloudflared 侧, 且那本就是既有形态),
    # 显式给 644 以符合系统集成惯例。chmod 失败只告警 —— 权限不影响 systemd 读取(它以 root
    # 读), 为权限回滚会丢掉用户真正要的结果(与 logrotate / cloudflared 同一取舍)。
    chmod 644 /etc/systemd/system/xray.service 2>/dev/null || \
        _warn "service 文件权限设置失败(不影响 systemd 读取): /etc/systemd/system/xray.service"
    # 2026-09-12 三审(M3): 返回值现在被 _install_or_switch_xray 消费 —— daemon-reload 失败
    # 说明 service 文件根本没被 systemd 识别, 必须 fail; enable 失败只影响开机自启, 不中止安装。
    if ! systemctl daemon-reload; then
        _error "systemd daemon-reload 失败"
        return 1
    fi
    systemctl enable xray 2>/dev/null || _warn "xray 开机自启设置失败(可手动: systemctl enable xray)"
    return 0
}

_create_xray_openrc_service() {
    local rc_ulimit_line="" sd_env_line=""
    local _nf; _nf=$(_safe_nofile)
    # 抬到"目标 65535 或当前 hard 上限"(见 _safe_nofile); 只有完全探测不到时才留空
    [ -n "$_nf" ] && rc_ulimit_line="rc_ulimit=\"-n $_nf\""
    # R45: 核心 ≥ v26.7.11 用 config env 段, 不再经 supervise-daemon 注入; 旧核心保留注入兜底
    if ! _xray_version_ge "26.7.11"; then
        sd_env_line="supervise_daemon_args=\"--env XRAY_LOCATION_ASSET=${ASSET_DIR}\""
    fi
    # init 脚本写入必须**检查结果**(2026-09-22 十轮 P1-①)。与 systemd 分支同一形态:
    # 旧写法把 `cat > ... <<EOF` 的返回码丢在地上, 磁盘满/只读/权限异常时原文件已被**截断**,
    # 而随后的 `chmod +x` 与 `rc-update add` 仍可能成功 ⇒ 函数返回 0, 调用方认定"service 就绪",
    # 二进制回滚也不会被触发(它只在函数返回非 0 时发生) ⇒ 残局是"旧二进制 + 损坏的 init 脚本"。
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
command_args="run -c ${CONFIG_FILE}"
required_files="${CONFIG_FILE}"

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
    # enable 失败只影响开机自启, 不中止安装(与 systemd 分支同一口径, 2026-09-12 三审 M3)
    rc-update add xray default 2>/dev/null || _warn "xray 开机自启设置失败(可手动: rc-update add xray default)"
    return 0
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
    # fd9 关闭(9>&-, 2026-09-13 Alpine 实测): 本函数会在 _with_config_lock 的锁子 shell
    # 内被调用(config 事务), openrc supervise-daemon / direct 模式 nohup 会继承打开的 fd ——
    # 守护进程持有 fd9 = flock 永远被持有, 之后所有 _mutate_config 15s 超时静默失败。
    # systemd 不继承业务 fd(Ubuntu 无感), openrc/direct 必须关闭; 对齐 singbox-lite 同类修复。
    case "$INIT_SYSTEM" in
        systemd)
            case "$action" in
                start)   systemctl start xray 2>/dev/null 9>&- ${CORE_LOCK_FD:-9}>&- ;;
                stop)    systemctl stop xray 2>/dev/null 9>&- ${CORE_LOCK_FD:-9}>&- ;;
                restart) systemctl restart xray 2>/dev/null 9>&- ${CORE_LOCK_FD:-9}>&- ;;
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
                    _xray_is_running || rc-service xray zap >/dev/null 2>&1 9>&- ${CORE_LOCK_FD:-9}>&-
                    rc-service xray start 2>/dev/null 9>&- ${CORE_LOCK_FD:-9}>&- ;;
                stop)    rc-service xray stop 2>/dev/null 9>&- ${CORE_LOCK_FD:-9}>&- ;;
                restart)
                    _xray_is_running || rc-service xray zap >/dev/null 2>&1 9>&- ${CORE_LOCK_FD:-9}>&-
                    rc-service xray restart 2>/dev/null 9>&- ${CORE_LOCK_FD:-9}>&- ;;
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
                        XRAY_LOCATION_ASSET="$ASSET_DIR" nohup "$XRAY_BIN" run -c "$CONFIG_FILE" >/dev/null 2>&1 9>&- ${CORE_LOCK_FD:-9}>&- &
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
    # 成败判定以 8s 轮询为准, 服务命令 rc 仅决定是否补一次 start(2026-09-13 Alpine 实测):
    # openrc+supervise-daemon 下 restart/start 的 rc 不可靠 —— 子进程 FATAL 进入
    # respawn-wait 后 openrc 标 stopped 而 supervisor 存活, 随后 start 被
    # "already running" 拒绝(rc=1)但服务实际健康; 反之 FATAL 时 rc=0 但服务会死。
    # 按原实现 rc=1 即提前判失败, 会把健康服务误判为失败并触发不必要的回滚。
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
# 卸载前的"停止并验证"入口(2026-09-22 九轮 OCR #19)。
#
# 与 55-hysteria 的 `_hysteria_stop_and_verify` **同一契约**: 先停, 再**轮询确认进程真的
# 退出**, 只有确认成功才返回 0。为什么不能只 `_manage_xray stop || true`:
#   · `systemctl stop` 返回 0 不等于进程已退出(Type=simple 下 systemd 可能仍在收尾);
#   · 停失败时旧实现照样继续删 unit 与部署目录 —— 残局是"进程仍监听端口 + 二进制/配置已删",
#     用户既停不掉也起不来(实测复现见 implement.md)。
# 判活用 `_xray_is_running`(R40 统一入口), **不用**裸 `systemctl is-active`/`rc-service status`
# —— 那两者在崩溃窗口里都会说谎(见 CLAUDE.md 的"Unified liveness"段)。
# `_xray_is_running` 缺失(混装旧 lib)时按 declare -F 守卫回退为"停一次即认为成功"并告警,
# 绝不因此把卸载卡死。
# ---------------------------------------------------------------------------
_xray_stop_and_verify() {
    if ! declare -F _xray_is_running >/dev/null 2>&1; then
        _warn "lib 版本过旧(缺 _xray_is_running), 无法确认进程是否退出, 仅执行停止"
        _manage_xray stop >/dev/null 2>&1 || true
        return 0
    fi
    _manage_xray stop >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        _xray_is_running || return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# 卸载 Xray(停服务 + 删 service + 删部署目录 + 清快捷命令 + 清 crontab)
# ---------------------------------------------------------------------------
_uninstall_xray() {
    # 停止必须**确认进程真的退出**再动文件(2026-09-22 九轮 OCR #19)。旧写法
    # `_manage_xray stop 2>/dev/null || true` 忽略一切结果 —— 进程还在时照样删 unit 与部署目录,
    # 留下"孤儿进程占着端口 + 没有 unit/配置可管理"的残局(与官方 Hysteria2 侧的
    # `_hysteria_cleanup_before_uninstall` 是同一类保护, 那条早已是这个形态)。
    if ! _xray_stop_and_verify; then
        _error "xray 进程未能停止, 已中止卸载(文件未删除), 请手动处理后重试"
        _tip "可先查看: xd 主菜单 [核心管理] → 服务状态"
        return 1
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
    # 清 crontab 的 geo 自动更新任务 + 定时重启任务。
    # 必须走 _crontab_replace(读失败即中止且不改动), 不能用 `crontab -l | grep -v | crontab -`:
    # 后者在 `crontab -l` 失败时会用空内容覆盖, 把用户**全部**定时任务一起清掉(且 `|| true`
    # 让失败无声无息)。declare -F 守卫兼容混装旧 lib: 旧版没有该函数时**宁可不动** crontab
    # 也不能退回破坏性写法 —— 卸载已删掉我们的文件, 残留的 cron 行只会报"命令不存在"。
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
    # 清理端口跳跃 iptables 规则(必须在删除部署目录之前)
    if declare -F _hy2_cleanup_all_hops >/dev/null 2>&1; then
        _hy2_cleanup_all_hops
    fi
    # 官方 Hysteria2 前置清理(其数据目录随 DEPLOY_DIR 一并删除, 但 service 定义在系统目录,
    # 不先停服删 unit 会留下指向已删 binary 的孤儿服务; declare -F 守卫兼容混装旧版)。
    # 0.16.3: 停止必须确认进程真正退出 —— 仍存活时中止整个卸载(防孤儿进程), 由用户处理。
    if declare -F _hysteria_cleanup_before_uninstall >/dev/null 2>&1; then
        if ! _hysteria_cleanup_before_uninstall; then
            _error "官方 Hysteria2 进程未能停止, 已中止卸载(文件未删除), 请手动处理后重试"
            return 1
        fi
    fi
    # 清理 logrotate 配置
    if declare -F _logrotate_cleanup >/dev/null 2>&1; then
        _logrotate_cleanup
    fi
    # 删部署目录(含 config/nodes/assets/logs/state/lib/templates)
    rm -rf "$DEPLOY_DIR"
    _success "Xray 已卸载干净(/opt/xray-deploy、xd 命令、系统 cron 已清除)"
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
