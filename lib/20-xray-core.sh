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

    # 停服务 -> 备份旧二进制 -> 替换二进制 -> 校验可执行
    _manage_xray stop >/dev/null 2>&1 || true
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
        else
            # 首次安装且无备份可回滚: 删掉这个不可执行的新二进制, 回到"未安装"的干净状态。
            # 留着它会让调用方的 [ -x "$XRAY_BIN" ] 恢复检查失败、而菜单却把它当成"已安装"
            # (_xray_current_version 读不出东西), 用户面对一个装不上的幽灵核心。
            rm -f "$XRAY_BIN" 2>/dev/null
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
# 核心切换失败时的**统一还原入口**(2026-09-22 九轮 OCR #15)。
#
# 背景: `_xray_download_replace` 在**校验第 2..N 步之前**就把 $XRAY_BIN 换成了新二进制,
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
# 核心切换事务日志 + 崩溃恢复(2026-09-22 十一轮 P1-②)。
#
# 十轮把"函数返回失败"这条路径闭上了(二进制/unit/state 三件套一起回滚), 但**进程被杀**
# 这条路径仍然敞着: 下载完成 → 旧二进制进了 `.bak` → 新二进制已替换 → unit 已重写 →
# SIGKILL / OOM / 掉电。此时没有任何函数会被调用, 机器上留下"新二进制 + 旧备份 + 新 unit"
# 的中间态, 而下次开机**无人判断**这是一次没做完的切换。
#
# 同项目的端口修改 (_port_txn) 早已用"先落 journal → 启动期按事实收敛"处理这一类窗口;
# 本函数把同一模型补到核心切换上:
#   · journal 在**动任何真实状态之前**原子落盘(state/coretxn.json)
#   · 每个关键阶段推进 phase(binary_replaced → service_replaced → restart_verified)
#   · 提交成功才删 journal; 失败回滚完也删
#   · 启动期 `_xray_core_txn_recover` 发现 phase != committed 的 journal 即**回滚**到旧核心
#     (核心切换是"可放弃"的事务: 新核心没验证过就不该留在盘上)
#
# 幂等与 fail-closed: journal 不可解析 / schema 不合法 ⇒ **隔离**(改名 .corrupt)并告警,
# 绝不按猜测动作 —— 与 `_ptx_journal_quarantine` 同策。
# 为啥落在 $STATE_DIR 而不是 $BIN_DIR: 它是账本不是产物, 且 $STATE_DIR 已 chmod 700。
# ---------------------------------------------------------------------------
_xray_core_journal_path() { printf '%s' "$STATE_DIR/coretxn.json"; }

# 写 journal。返回 1 = 未落盘(调用方必须中止, 不能带着"没有账本"继续改真实状态)。
_xray_core_journal_write() {  # <旧版本> <旧通道> <新tag> <channel>
    local old_ver="$1" old_ch="$2" new_tag="$3" new_ch="$4" payload
    mkdir -p "$STATE_DIR" || return 1
    payload=$(jq -n --arg ov "$old_ver" --arg oc "$old_ch" --arg nt "$new_tag" --arg nc "$new_ch" \
        --arg bin "$XRAY_BIN" --arg bak "${XRAY_BIN}.bak" \
        --arg unit "$(_xray_service_unit_path 2>/dev/null || echo '')" \
        --arg sprev "$(_xray_service_prev_path)" \
        '{phase:"snapshot", old_version:$ov, old_channel:$oc, new_tag:$nt, channel:$nc,
          binary:$bin, binary_backup:$bak, unit:$unit, service_prev:$sprev}') || return 1
    _atomic_write_json "$(_xray_core_journal_path)" "$payload"
}

# 推进 phase(其余字段保持不动)。失败只告警: journal 停在更早的 phase 会让恢复走**更保守**的
# "回滚"分支, 而回滚本身是幂等的 —— 宁可多回滚一次, 不可漏回滚。
_xray_core_journal_phase() {
    local ph="$1"
    _meta_update "$(_xray_core_journal_path)" '.phase=$p' --arg p "$ph" 2>/dev/null || \
        _warn "核心事务日志阶段推进失败($ph), 崩溃恢复将按更保守的'回滚'处理"
    return 0
}

_xray_core_journal_drop() {
    rm -f "$(_xray_core_journal_path)" 2>/dev/null
    return 0
}

_xray_core_journal_ok() {  # <journal> —— schema 合法性(只认我们写的形状)
    jq -e '
        (.phase | type == "string") and
        (.phase | test("^(snapshot|binary_replaced|service_replaced|restart_verified|committed)$")) and
        (.old_version | type == "string") and
        (.old_channel | type == "string") and
        (.channel | type == "string") and
        (.binary | type == "string") and (.binary | length > 0) and
        (.binary_backup | type == "string") and (.binary_backup | length > 0) and
        (.unit | type == "string") and
        (.service_prev | type == "string") and (.service_prev | length > 0)
    ' "$1" >/dev/null 2>&1
}

_xray_core_journal_quarantine() {  # <journal> <原因>
    local j="$1" why="$2"
    _warn "核心事务日志不可用($why), 已隔离待人工核对: $j"
    mv -f "$j" "${j}.corrupt" 2>/dev/null || \
        _warn "隔离核心事务日志失败, 请手动检查: $j"
}

# 启动期恢复入口(供 _main_menu 调用)。返回 0 = 无待处理事务或已收敛。
_xray_core_txn_recover() {
    local j; j=$(_xray_core_journal_path)
    [ -f "$j" ] || return 0
    if ! jq -e . "$j" >/dev/null 2>&1; then
        _xray_core_journal_quarantine "$j" "无法解析"
        return 0
    fi
    if ! _xray_core_journal_ok "$j"; then
        _xray_core_journal_quarantine "$j" "schema 不合法(phase/字段形状)"
        return 0
    fi
    local phase old_ver old_ch bak unit sprev
    phase=$(jq -r '.phase' "$j" 2>/dev/null)
    old_ver=$(jq -r '.old_version' "$j" 2>/dev/null)
    old_ch=$(jq -r '.old_channel' "$j" 2>/dev/null)
    bak=$(jq -r '.binary_backup' "$j" 2>/dev/null)
    unit=$(jq -r '.unit' "$j" 2>/dev/null)
    sprev=$(jq -r '.service_prev' "$j" 2>/dev/null)
    # phase=committed 不该留(提交时会删), 但真留着就只是账本残留, 直接清掉
    if [ "$phase" = "committed" ]; then
        rm -f "$j" 2>/dev/null
        return 0
    fi
    _warn "检测到未完成的核心切换事务(阶段: ${phase}), 正在回滚到切换前的状态..."
    # 回滚源只认 journal 自己记的路径, 不读当下环境 —— 账本说什么就恢复什么, 避免
    # "恢复时用的常量"与"当时写入的路径"漂移(与 _port_txn_recover 同一取向)。
    local svc_ok=1
    if [ -f "$bak" ]; then
        if mv -f "$bak" "${bak%.bak}"; then
            chmod +x "${bak%.bak}" 2>/dev/null || \
                _warn "还原后的二进制执行位设置失败: ${bak%.bak}"
            _warn "已还原切换前的二进制"
        else
            _error "二进制还原失败, 请手动处理: ${bak%.bak}(备份仍在 $bak)"
        fi
    else
        _warn "journal 记录的二进制备份已不存在($bak), 跳过二进制还原"
    fi
    # service 快照: 与 _xray_service_restore_prev 同一口径, 但路径取自 journal
    if [ -f "${sprev}.absent" ]; then
        [ -n "$unit" ] && rm -f "$unit" 2>/dev/null
        rm -f "${sprev}.absent" 2>/dev/null
        _warn "已撤销本次切换新建的 service 文件: ${unit:-（无）}"
    elif [ -f "$sprev" ] && [ -n "$unit" ]; then
        # 与正常回滚共用同一个原子替换实现(P2-②): 恢复途中的 ENOSPC/EIO 不得留下半截 unit。
        # 权限/重载口径由 helper 按目标路径自己判定, 恢复路径不再重复一套。
        if _xray_service_restore_file "$sprev" "$unit"; then
            rm -f "$sprev" 2>/dev/null
            _warn "已还原切换前的 service 文件: $unit"
        else
            svc_ok=0
            _error "service 文件还原失败, 请手动核对: $unit(备份: $sprev)"
        fi
    fi
    # state 写回"磁盘上实际那个二进制"的版本/通道
    local recv
    recv=$(_xray_current_version 2>/dev/null)
    [ -n "$recv" ] || recv="$old_ver"
    [ -n "$recv" ] && { _state_set version "$recv" || _warn "状态持久化失败(version)"; }
    if [ -n "$old_ch" ]; then
        _state_set channel "$old_ch" || _warn "状态持久化失败(channel)"
    else
        rm -f "$STATE_DIR/channel" 2>/dev/null
    fi
    # 收敛完成才删 journal; service 没还原成功则保留, 让用户/下次启动还能看到这条线索
    if [ "$svc_ok" -eq 1 ]; then
        rm -f "$j" 2>/dev/null
        _warn "核心切换事务已回滚收敛(恢复到 v${recv:-?})"
    else
        _error "核心切换事务回滚**不完整**: 二进制已还原但 service 未还原"
        _tip "保留事务日志待人工核对: $j(核对后手动删除)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 安装或切换 Xray 核心(R3)
# 用法:_install_or_switch_xray <channel>
#   未安装 -> 安装该通道最新版
#   已安装 -> 切换到该通道最新版(配置与节点不动)
# 并发: 整个切换在 `_with_core_lock` 内(十一轮 P2-③), 嵌套的 `_mutate_config` 会再取 config
# 锁。两把锁的文件不同(`.core.lock` / `.config.lock`), 但**加锁方向恒定**: 永远是
# core → config, 因为只有本函数会先持 core 锁(A/B 两处 config 写者都不取 core 锁),
# 单向的锁序不可能成环 ⇒ 无死锁。两个包装器各自可重入, 不存在自锁。
# ---------------------------------------------------------------------------
_install_or_switch_xray() {
    _with_core_lock _install_or_switch_xray_locked "$@"
}

_install_or_switch_xray_locked() {
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
    # 切换前的通道(state/channel)。回滚到旧二进制时必须还原它, 否则 state 描述的是
    # "新通道 + 旧二进制"这个不存在的组合(见下面失败分支的说明)。
    local prev_channel=""
    prev_channel=$(_state_get channel 2>/dev/null)
    local cur_tag="v${cur}"
    if [ -n "$cur" ] && [ "$cur_tag" = "$tag" ]; then
        _info "当前已是该版本 (v${cur}),仍重新下载替换以确保最新"
    fi

    # 备份配置(切换不动配置,但写前留快照以防万一)。备份失败则中止, 保持"备份→替换→验证→回滚"事务链闭合。
    if ! _backup_config; then
        _error "配置备份失败, 取消核心切换"
        return 1
    fi
    # 事务日志必须在**动任何真实状态之前**落盘(十一轮 P1-②)。放在 service 快照之前:
    # journal 是后面所有步骤的账本, 它的存在本身就是"这次切换没做完"的判据。
    # 落不下去就不动手 —— 带着"没有账本"去改二进制, 崩溃后又回到无人判断的中间态。
    if ! _xray_core_journal_write "${cur:-}" "${prev_channel:-}" "$tag" "$channel"; then
        _error "核心事务日志写入失败(磁盘空间/权限?), 取消本次安装/切换(未做任何改动)"
        return 1
    fi
    # service 文件同样要在**动二进制之前**进事务(十轮 P1-④)。放在这里而不是
    # `_create_xray_service` 之前: 快照失败时盘上还什么都没改, 直接中止即可, 连回滚都不需要;
    # 而 unit 从此刻起到提交为止不会再被别处改动(_init_config_if_empty 只碰 config)。
    if ! _xray_service_snapshot; then
        _error "service 文件快照失败(磁盘空间/权限?), 取消本次安装/切换(未做任何改动)"
        _xray_core_journal_drop
        return 1
    fi
    if ! _xray_download_replace "$tag"; then
        # 这条路径没碰过 unit(二进制都没换), 快照直接作废 —— 快照只对本次事务有效,
        # 残留下来只会成为下次排障时说不清的噪声。
        _xray_service_snapshot_drop
        _xray_core_journal_drop
        # 下载失败:若有旧二进制,尝试恢复服务
        if [ -x "$XRAY_BIN" ]; then
            _warn "切换失败,保留当前二进制 v${cur}"
            _manage_xray start >/dev/null 2>&1 || true
        fi
        return 1
    fi
    # 到这里二进制已换(旧的那个在 .bak)。这是崩溃窗口最危险的一段, 故立刻推进 phase。
    _xray_core_journal_phase "binary_replaced"

    # 确保配置与 service 存在(首次安装)。2026-09-12 三审(M3): 两者失败都显式中止 ——
    # 原写法不检查返回值, 配置初始化失败(jq 缺失/磁盘满)时仍写出指向不存在配置的 unit 并
    # 确保配置与 service 存在(首次安装)。2026-09-12 三审(M3): 两者失败都显式中止 ——
    # 原写法不检查返回值, 配置初始化失败(jq 缺失/磁盘满)时仍写出指向不存在配置的 unit 并
    # 强行重启, 把"配置没建好"伪装成"新核心起不来", 误导排障方向。
    #
    # **失败时不能只 start**(2026-09-22 九轮 OCR #15 修)。`_xray_download_replace` 已经把
    # 二进制**换成新的**并留下 `$XRAY_BIN.bak`(旧的那个), 所以这两条路径上的失败残局是
    # "磁盘上是未提交的新核心 + 一个旧核心备份", 而旧写法只 `_manage_xray start` 就 return:
    #   · 服务其实能起来(新二进制可执行, 只是配置/service 没就绪), 用户看到"运行中";
    #   · 无人消费的 `.bak` 会被**下一次**切换的备份步骤 `cp -f "$XRAY_BIN" "$XRAY_BIN.bak"`
    #     覆盖 —— 旧二进制就此永久丢失, 而 state 里的 version/channel 仍描述旧核心。
    # 实测复现(见 .trellis/tasks/09-22-ocr-fullreview 的 implement.md): 失败后 `$XRAY_BIN`
    # 内容 == 新二进制、`.bak` == 旧二进制; 再走一次备份步骤后 `.bak` 变成新二进制。
    # 现在与下方 `started_ok` 分支**逐字同一形态**地还原: mv 回旧二进制 + chmod + 重启 +
    # 把 version/channel 写回"磁盘上实际那个二进制"。首次安装无 `.bak` 时不还原, 但**保留**
    # 刚落地的新二进制(删掉会把"能跑的机器"变成"完全没核心"), 只如实报告。
    if ! _init_config_if_empty; then
        _error "配置初始化失败, 中止安装/切换"
        _xray_restore_prev_bin "${cur:-}" "${prev_channel:-}"
        # 十一轮 P1-①: 该函数三态, 只有 0 才是"完整还原"。1(无旧核心/二进制没回)与
        # 2(service 没还原)都属回滚不完整 —— 函数内部已打印原因与人工核对点,
        # 这里补一句总括, 避免用户把"中止安装"误读成"已恢复原状"。
        local rrc=$?
        # 11/12 = 回滚不完整(见 _xray_restore_prev_bin 的三态说明)。回滚不完整时**保留**
        # journal: 它记录了备份路径与当时阶段, 是人工核对时的唯一线索(与 _port_txn 的
        # "回滚失败保留 journal 待启动恢复"同一取向)。
        if [ "$rrc" -eq 0 ]; then
            _xray_core_journal_drop
        else
            _tip "回滚未完整完成(journal 已保留), 请按上方提示核对后再重试"
        fi
        return 1
    fi
    if ! _create_xray_service; then
        _error "service 文件创建失败, 中止安装/切换"
        _xray_restore_prev_bin "${cur:-}" "${prev_channel:-}"
        local rrc2=$?
        if [ "$rrc2" -eq 0 ]; then
            _xray_core_journal_drop
        else
            _tip "回滚未完整完成(journal 已保留), 请按上方提示核对后再重试"
        fi
        return 1
    fi
    _xray_core_journal_phase "service_replaced"

    # 重启并确认"稳定运行"而非仅命令返回 0(systemd Type=simple 在进程崩溃前即返回 0)。
    # 不在此处跑 xray -test(低内存 OOM); verified-restart 会完整观察 8s。
    local started_ok=1
    _restart_xray_verified || started_ok=0

    # 记录状态。注意 cur 是"替换前"探测(用于上面的版本提示/回滚文案), 这里 newv 是
    # "替换后"只探测一次(旧代码替换后还连探两次: _state_set 内一次 + newv 一次, 已合并)。
    local newv
    newv=$(_xray_current_version 2>/dev/null)

    if [ "$started_ok" -ne 1 ]; then
        # 新二进制可执行但无法稳定运行(如当前配置与新版本不兼容): 回滚到替换前的旧二进制并重新拉起,
        # 与 config/geo 的失败回滚保持同一事务级别。首次安装无 .bak 时只报错。
        # R38(M1): version 状态必须反映"磁盘上实际的那个二进制"。原实现在这段之前就无条件
        # _state_set version "$newv", 回滚到旧二进制后 state 里仍是新版本, 而菜单
        # (_xray_cached_version)优先读 state, 于是版本显示与现实长期不一致。
        local rolled_back=0
        local svc_back=1
        if [ -f "$XRAY_BIN.bak" ]; then
            if mv -f "$XRAY_BIN.bak" "$XRAY_BIN"; then
                chmod +x "$XRAY_BIN"
                # unit 必须与二进制**同时**回到改动前(十轮 P1-④)。这不是洁癖: unit 里的
                # `Environment=XRAY_LOCATION_ASSET` 按 v26.7.11 门控注入, 新核心写的是"不含注入"
                # 的那一版; 若只回滚二进制, 还原后的旧核心在新的 unit 下找不到 geo dat 起不来 ——
                # 回滚动作本身制造了新的故障。
                # 十一轮 P1-①: 不再 `|| true` —— unit 还原失败必须反映到最终结论里。
                _xray_service_restore_prev || svc_back=0
                _manage_xray restart >/dev/null 2>&1 || _manage_xray start >/dev/null 2>&1 || true
                if [ "$svc_back" -eq 1 ]; then
                    rolled_back=1
                    _xray_core_journal_drop
                    _warn "新核心 v${newv:-?} 未能稳定运行, 已回滚到旧二进制 v${cur:-?}"
                else
                    # 二进制回来了但 service 没回来: 记 rolled_back=0 ⇒ state 按"磁盘上是新二进制"
                    # 的口径没有意义(二进制其实已是旧的), 故这里仍按已回滚记录 version, 但**额外**
                    # 明确告知 service 未还原, 让用户知道要重装一次。
                    rolled_back=1
                    _error "已回滚旧二进制, 但 service 文件未能还原到改动前(回滚不完整)"
                    _tip "请核对 service 与备份 $(_xray_service_prev_path), 或重装一次该通道以按当前核心版本重写它"
                    # journal 保留: 记录着备份路径与阶段, 是人工核对的线索
                fi
            else
                _error "旧二进制回滚失败, 请手动处理 $XRAY_BIN"
                # 二进制没回成功, unit 仍尽力复原到改动前(两个失败互不依赖)
                _xray_service_restore_prev || svc_back=0
                _tip "保留事务日志待人工核对: $(_xray_core_journal_path)"
            fi
        else
            # 首次安装(无 .bak): 与 `_xray_restore_prev_bin` 同一口径 —— 保留已落地的二进制,
            # 也就一并保留刚建好的 unit, 让用户还能用 `systemctl status xray` 排障。
            # 此时没有"改动前状态"可谈, 强行删 unit 只会把可诊断的失败变成不可诊断的。
            _warn "无旧核心可回滚(首次安装), 保留已落地的二进制与 service 文件供排障"
            # 既然 unit 留着, 那条"事务之前没有 unit"的标志就必须一并清掉, 否则它会作为
            # 陈旧状态留在 $BACKUP_DIR 里(下一次事务会先清它, 故只是噪声, 但噪声也会误导排障)。
            _xray_service_snapshot_drop
            # 首次安装失败的"新二进制 + 新 unit"是有意保留的**可用**形态, 不是未完成事务 ——
            # 留着 journal 会让每次启动都报一次"检测到未完成事务"并试图回滚(而它无旧核心可回)。
            _xray_core_journal_drop
        fi
        # 回滚成功 → state 记旧版本; 回滚失败/首次安装 → 磁盘上是新二进制, 记新版本
        local recv
        recv=$(_xray_current_version 2>/dev/null)
        [ -n "$recv" ] || { [ "$rolled_back" -eq 1 ] && recv="$cur" || recv="$newv"; }
        [ -n "$recv" ] && { _state_set version "$recv" || _warn "状态持久化失败(version)"; }
        # channel 与 version 同源: 它也必须描述"磁盘上实际的那个二进制"。原实现在
        # 重启确认**之前**就无条件写入新通道, 于是回滚到旧二进制后 state/channel 仍指向
        # 新通道 —— 与 version 分裂的是同一类问题(菜单 [核心管理] 会显示错误通道)。
        # 只有真正回滚成功才需要还原; 回滚失败/首次安装时磁盘上就是新二进制, 新通道是准确的。
        if [ "$rolled_back" -eq 1 ]; then
            if [ -n "${prev_channel:-}" ]; then
                _state_set channel "$prev_channel" || _warn "状态持久化失败(channel)"
            else
                rm -f "$STATE_DIR/channel" 2>/dev/null
            fi
        else
            _state_set channel "$channel" || _warn "状态持久化失败(channel)"
        fi
        _error "Xray 二进制已替换, 但服务未能稳定运行, 请检查配置"
        return 1
    fi
    # version 与 channel 必须**同进同退**: 只写其一会让 state 描述"新版本+旧通道"这种
    # 不存在的组合(菜单 [核心管理] 会显示与 version 不匹配的通道)。_xray_current_version
    # 读不出东西(二进制能跑但 version 输出无法解析)时, 两个都不写, 保持旧的一致状态。
    #
    # **两次 _state_set 不是原子的**(2026-09-22 九轮 OCR #16)。state 落在磁盘上, 第二次写
    # 完全可能因为 ENOSPC / 只读重挂 / 配额而失败 —— 实测(见 implement.md) 那时的残局是
    # `state/version` 已是**新版本**而 `state/channel` 仍是**旧通道**(或压根不存在),
    # 菜单就长期显示一个磁盘上从没存在过的组合。
    # 处置: **先写 channel(非主键, 失败更不可见), 再写 version(主键)**; channel 失败则
    # 回滚 —— 把 version 也写回改动前的值。两次都成功才算记账成功。
    # 顺序不能反: 先写 version 而 channel 失败时, "已经写好的新版本号"必须被回滚, 而
    # 回滚需要旧值 —— 拿旧值与拿新值一样都要一次读, 但把**主键**放在最后写能让"只成功一次"
    # 的窗口落在 channel 上, 而 channel 的错值只影响一行展示文案, 不会误导版本判断。
    prev_ver=$(_state_get version 2>/dev/null)
    if [ -n "$newv" ]; then
        if ! _state_set channel "$channel"; then
            _warn "状态持久化失败(channel), 本次不记录 version/channel(保持旧的一致状态)"
        elif ! _state_set version "$newv"; then
            # channel 已写入 => 回滚它, 使两键一起停在改动前
            _warn "状态持久化失败(version), 正在回滚 channel 记录"
            if [ -n "$prev_ver" ]; then
                _state_set channel "$prev_channel" 2>/dev/null || \
                    _warn "channel 回滚失败, 状态可能显示旧版本+新通道, 请重跑一次切换"
            else
                rm -f "$STATE_DIR/channel" 2>/dev/null
            fi
        fi
    else
        _warn "无法读取新核心版本, 跳过 version/channel 记录(保持原值以免状态分裂)"
    fi
    # 到这里新核心已被确认"稳定运行"—— 事务到达提交点。先推进 phase 再清理备份:
    # 反过来的顺序会在"phase 还停在 restart_verified 而备份已删"的窗口里让崩溃恢复抓不到
    # 备份, 白白报一次"备份已不存在"(虽然结果无害, 但那是账本与现实不一致)。
    _xray_core_journal_phase "restart_verified"
    # verified 稳定运行后才丢弃旧二进制备份
    rm -f "$XRAY_BIN.bak"
    _xray_service_snapshot_drop
    # 事务真正提交: 账本最后删(它是"未完成"的唯一判据)
    _xray_core_journal_drop
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

_xray_service_prev_path() { printf '%s' "$BACKUP_DIR/xray-service.prev"; }

# ---------------------------------------------------------------------------
# 把快照写回 unit —— **原子替换**(十一轮 P2-②)。
#
# 旧写法 `cp -f "$prev" "$unit"`: 恢复途中 ENOSPC/EIO 会留下**半截生产文件**, cp 虽然报错
# 但残局已经形成 —— 而"恢复失败时生产文件保持原样"才是调用方依赖的前提。改为同目录临时文件
# + 校验 + rename(2): 要么整份替换成功, 要么原文件一字不动。
# 同目录是硬要求(跨 fs 的 mv 会退化成拷贝+unlink, 又回到非原子; 与 20-xray-core 的 staging
# 目录同一课)。umask 077 下临时文件是 0600, 故显式给目标权限。
# 用法: _xray_service_restore_file <快照路径> <目标 unit 路径>
# ---------------------------------------------------------------------------
_xray_service_restore_file() {
    local prev="$1" unit="$2" tmp modestr
    [ -f "$prev" ] || return 1
    case "${INIT_SYSTEM:-}" in
        openrc) modestr=755 ;;
        *)      modestr=644 ;;
    esac
    # 临时文件必须落在目标同目录(/etc/systemd/system 或 /etc/init.d), 且**点号开头** ——
    # 这样两个 init 系统在那一瞬间都不会把它当成一个待加载的 unit/systemd 只认 `.service`
    # 等已知后缀且忽略隐藏文件, OpenRC 扫 /etc/init.d 时同样跳过点开头的条目)。
    # 实测: 点开头且以 .service 结尾的文件不出现在 `systemctl list-unit-files` 里。
    tmp=$(mktemp "$(dirname "$unit")/.$(basename "$unit").tmp.XXXXXX") || return 1
    if ! cat "$prev" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # 落盘内容必须与快照逐字一致 —— 半截写入不得进入 rename
    if ! cmp -s "$prev" "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        _error "service 文件还原时内容不完整(磁盘空间?), 已放弃替换: $unit"
        return 1
    fi
    if ! chmod "$modestr" "$tmp" 2>/dev/null; then
        # 权限设置失败不影响 unit 可用性(root 读取), 但保持与写入侧一致的口径: 只告警
        _warn "service 临时文件权限设置失败(不影响读取): $tmp"
    fi
    # 用 mv -f 覆盖(同目录 ⇒ rename 语义, 原子)
    if ! mv -f "$tmp" "$unit" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    case "${INIT_SYSTEM:-}" in
        systemd)
            # 半截/旧 unit 可能已被 daemon-reload 载入内存, 还原后让它重新读盘(best-effort)
            systemctl daemon-reload 2>/dev/null || \
                _warn "服务配置重载失败(daemon-reload), 请手动执行: systemctl daemon-reload"
            ;;
    esac
    return 0
}

# 重写 unit 之前留快照。返回 1 = 快照没做成功(调用方必须中止事务, 不能带着"无快照"继续)。
_xray_service_snapshot() {
    local unit prev
    unit=$(_xray_service_unit_path) || return 0    # direct 后端: 无 unit 可写, 无需快照
    prev=$(_xray_service_prev_path)
    mkdir -p "$BACKUP_DIR" || return 1
    rm -f "$prev" "${prev}.absent" 2>/dev/null
    if [ ! -e "$unit" ]; then
        # 原本没有 unit: 用一个标志文件记住"本次事务之前它不存在"
        : > "${prev}.absent" || return 1
        return 0
    fi
    cp -f "$unit" "$prev" 2>/dev/null || { rm -f "$prev"; return 1; }
    # 快照必须**逐字等于**原文件(十一轮 P2-①)。只查"非 0 字节"不够: 磁盘满时 cp 可能
    # 返回 0 却只落地前半截, 于是快照非空但损坏 —— 回滚时把这份损坏内容写回生产 unit,
    # 比不回滚更糟(旧核心可能因此起不来)。判据与 30-geo 的 dat 备份同款(比对大小),
    # 这里更进一步直接比内容(cmp -s 在 coreutils/busybox 都有; 项目已有先例)。
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
    if [ -f "${prev}.absent" ]; then
        # 事务之前没有 unit ⇒ 把本次新建的那个删掉, 回到"本来就没有"
        rm -f "$unit" 2>/dev/null
        rm -f "${prev}.absent" 2>/dev/null
        _warn "已撤销本次新建的 service 文件(事务之前不存在): $unit"
        return 0
    fi
    [ -f "$prev" ] || return 0
    if ! _xray_service_restore_file "$prev" "$unit"; then
        _error "service 文件还原失败, 请手动核对: $unit (备份: $prev)"
        return 1
    fi
    rm -f "$prev" 2>/dev/null
    _warn "已还原 service 文件到本次改动前的内容: $unit"
    return 0
}

# 事务成功提交: 丢弃 unit 快照(与 rm -f "$XRAY_BIN.bak" 同一步)
_xray_service_snapshot_drop() {
    local prev; prev=$(_xray_service_prev_path)
    rm -f "$prev" "${prev}.absent" 2>/dev/null
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
