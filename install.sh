#!/bin/bash
# =============================================================================
# install.sh — xray-deploy 一键安装/更新入口
# 用法:
#   首次安装: bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh)
#   更新脚本: bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh) --update
#   更新(不启动菜单): bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh) --no-start
# =============================================================================

set -u

# 规范上游 base —— **唯一**的上游字面量来源。
# 派生而非复制, 使镜像只改一处即可(`XRAY_DEPLOY_RAW` 覆盖下载入口)。
REMOTE_BASE_DEFAULT="https://raw.githubusercontent.com/UIMAK/xray-deploy/main"
REMOTE_BASE="${XRAY_DEPLOY_RAW:-$REMOTE_BASE_DEFAULT}"

CMD_NAME="xd"
INSTALL_BIN="/usr/local/bin/${CMD_NAME}"
DEPLOY_DIR="/opt/xray-deploy"
INSTALL_LIB_DIR="$DEPLOY_DIR/lib"
INSTALL_TPL_DIR="$DEPLOY_DIR/templates"

# 整版本原子更新用的路径(见 _install_backup/_install_rollback 上方的设计说明)。
# ROLLBACK_DIR: 本次安装的备份目录, 带 $$ 防并发覆盖。
ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.$$"

# 模块与模板完整列表。
#
# **LIB_MODULES 与 xray-deploy.sh 里的同名变量必须逐字一致** —— 远程安装路径无法从磁盘
# 枚举模块(此时本地根本没有 lib/), 只能靠这份静态清单下载; 而 xray-deploy.sh 靠它 source。
# 两者漂移会造成"install.sh 认为安装完整、运行时却拒绝启动"(或反过来)。
# 漂移由 tests/run-tests.sh 的"两份 LIB_MODULES 必须一致"断言守住, 改一处就会报红。
# tests/ 自 2026-09-27 起随仓库发布, 克隆副本同样能跑该断言(套件只依赖本工作树)。
LIB_MODULES="00-common 10-system 20-xray-core 30-geo 40-cloudflared 45-logrotate 50-nodes 51-reality-pq 55-hysteria 90-menu"
TPL_NAMES="vless-tcp-reality-vision-tunnel vless-xhttp-reality-tunnel vless-tcp-reality-vision-direct vless-xhttp-reality-direct tunnel vless-enc vless-xhttp-cdn vless-ws-cdn shadowsocks hysteria2"

# ---------------------------------------------------------------------------
# root 检测
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] && { echo "[错误] 请以 root 运行"; exit 1; }

# 部署目录含私钥/密码/token, 默认 077 使运行期生成的敏感文件仅 root 可读
umask 077

# ---------------------------------------------------------------------------
# 确保 bash(Alpine 默认 ash)
# ---------------------------------------------------------------------------
ensure_bash() {
    if [ -n "${BASH_VERSION:-}" ]; then return 0; fi
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1 && exec bash "$0" "$@"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq bash >/dev/null 2>&1 && exec bash "$0" "$@"
    fi
    echo "[错误] 无法安装 bash"; exit 1
}
ensure_bash "$@"

# ---------------------------------------------------------------------------
# 基础依赖
# ---------------------------------------------------------------------------
need=()
command -v curl  >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || need+=(curl)
command -v jq    >/dev/null 2>&1 || need+=(jq)
command -v unzip >/dev/null 2>&1 || need+=(unzip)
if [ "${#need[@]}" -gt 0 ]; then
    if command -v apk >/dev/null 2>&1; then apk add --no-cache "${need[@]}" >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null 2>&1
    fi
    for c in "${need[@]}"; do
        command -v "$c" >/dev/null 2>&1 || echo "[警告] 依赖 $c 安装失败, 脚本将尝试继续(菜单启动时会再次尝试安装)"
    done
fi

# ---------------------------------------------------------------------------
# 下载文件(优先 curl, 兜底 wget, 带重试)
# ---------------------------------------------------------------------------
dl() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    # curl 优先
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --retry 2 --max-time 30 "$url" -o "$dest" 2>/dev/null; then
            [ -s "$dest" ] && return 0
        fi
    fi
    # wget 兜底(只用 busybox/GNU 都支持的 -q -T -O; --tries/--timeout 等 GNU 长选项在老版本 busybox 上不保证)
    if command -v wget >/dev/null 2>&1; then
        if wget -q -T 30 -O "$dest" "$url" 2>/dev/null; then
            [ -s "$dest" ] && return 0
        fi
    fi
    rm -f "$dest" 2>/dev/null
    return 1
}

# ---------------------------------------------------------------------------
# 单文件原子落地 + 落地后复核
#
# _install_file: cp 到同目录的临时名, 再 mv 覆盖目标。同目录 rename 是原子的, 因此
# 每个文件只有"完整的旧内容"和"完整的新内容"两种可见状态 —— 目录级 cp 中途失败留下的
# "一半新一半旧"的 lib/ 会让主脚本以 source 失败/怪异报错的形式暴露(见 download_all)。
# 临时名带 $$ 避免并发安装互相覆盖; 任一步失败都清理临时文件, 不留垃圾。
# _verify_installed: 复核每一个 LIB_MODULES/TPL_NAMES 条目都**存在且非空**。cp 返回 0
# 却只落地 0 字节(磁盘满)是真实场景, 只看 cp 退出码看不出来。
# ---------------------------------------------------------------------------
_install_file() { # <src> <dest>
    local src="$1" dest="$2" tmp
    [ -f "$src" ] || { echo "[错误] 暂存文件缺失: $src"; return 1; }
    tmp="${dest}.tmp.$$"
    if ! cp -f "$src" "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        echo "[错误] 文件落地失败: $dest(磁盘空间/权限/IO?)"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null
        echo "[错误] 文件落地为空: $dest(磁盘空间?)"
        return 1
    fi
    if ! mv -f "$tmp" "$dest" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        echo "[错误] 文件替换失败: $dest"
        return 1
    fi
    return 0
}

_verify_installed() {
    local m bad=""
    for m in $LIB_MODULES; do
        [ -s "$INSTALL_LIB_DIR/${m}.sh" ] || bad="$bad lib/${m}.sh"
    done
    for m in $TPL_NAMES; do
        [ -s "$INSTALL_TPL_DIR/${m}.server.jsonc" ] || bad="$bad templates/${m}.server.jsonc"
    done
    [ -s "$DEPLOY_DIR/xray-deploy.sh" ] || bad="$bad xray-deploy.sh"
    if [ -n "$bad" ]; then
        echo "[错误] 安装后复核失败, 以下文件缺失或为空:${bad}"
        echo "       请清理 $DEPLOY_DIR 后重试"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 整版本原子更新(2026-09-21 复审 P1 收口)
#
# 逐文件 tmp→mv 只保证**单个文件**不半截, 不保证**整版本**一致: 10 个 lib + 10 个模板 +
# 主脚本 + VERSION 逐个落地, 中途失败(磁盘满/IO)会留下"一半新一半旧"的部署目录, 而旧代码
# 只看 copy_ok 就报成功。这里把落地升级为四段式:
#
#   1. 备份: 对清单里**每个已存在**的目标先 cp 到 $ROLLBACK_DIR/<relpath>;
#            任一步失败立即 return 1 —— 此时目标一个字节都没动。
#   2. 落地: 逐文件 _install_file(tmp→mv), 失败只置 copy_ok=0, 不中断。
#   3. 复核: _verify_installed(存在且非空)。
#   4. 回滚: 2/3 任一步失败 => 用 $ROLLBACK_DIR 把**全部**目标恢复到第 1 步之前:
#            备份里有 => cp 回去; 备份里没有(本次新建) => rm -f 掉。
#            回滚自身失败 => 如实报"降级状态 + 需人工核对的路径", 返回 1。
#
# 为什么是"备份后整体还原"而不是"失败时逐项重下": 失败时网络/磁盘状态与落地时可能不同
# (且重下可能再次失败); 备份是本机既有的、已验证可读的字节, 是唯一可靠的回滚源。
#
# $ROLLBACK_DIR 位置 = $DEPLOY_DIR/.install-rollback.$$ —— 三个约束:
#   · 同文件系统 => cp 不跨 fs, 不受 /tmp 容量影响;
#   · 以 `.` 开头 => 不被 nodes/*.json、templates/*.jsonc 之类的 glob 命中(本项目无 dotglob);
#   · `$$` 后缀 => 并发安装不互相覆盖; 所有 return 路径前 rm -rf, 入口顺手清理 SIGKILL 残留。
#
# 为什么不做 releases/<version> + current 软链切换: 主程序运行期**就在**目标目录内
# (LIB_DIR="$SCRIPT_DIR/lib"), 换不掉正在执行的脚本自身; 改造入口解析/service ExecStart/
# 卸载路径的触及面远大于收益。本函数已直接满足"部分更新失败不留混合版本"。
# ---------------------------------------------------------------------------
_install_relpaths() {
    local m t
    printf '%s\n' 'xray-deploy.sh' 'VERSION'
    for m in $LIB_MODULES; do printf 'lib/%s.sh\n' "$m"; done
    for t in $TPL_NAMES; do printf 'templates/%s.server.jsonc\n' "$t"; done
}

# ---------------------------------------------------------------------------
# 快照的两条**持久性**原语(2026-09-27 十二轮复审 P2)。
#
# 为什么必须有: `.KEEP` 在**所有** cp 之后才 rename 到位, 所以"cp 到一半掉电"留下的只是
# `.KEEP.tmp.$$`(未标记目录, 会被清理)—— 那条路径本来是安全的。真正的洞在**顺序**上:
# 缺落盘屏障时 rename 可能先于备份文件的数据块到达盘面。掉电后 `.KEEP` 已经存在并声明
# `present lib/x.sh`, 而恢复目录里的 `lib/x.sh` 是零长度/半截 —— 恢复程序只检查"文件存在且
# 不是 symlink", 于是把一个不完整的备份当成有效快照回滚上去。
#
# 两道屏障分工不同, 缺一不可: cmp 管"内容对得上"(cp 中途失败/ENOSPC 都能留下长度不符的
# 文件), fsync 管"顺序对"(备份数据 + 目录项先落盘, `.KEEP` 这条记账才允许出现)。
# rename 原子 ≠ 掉电持久 —— 项目其它事务已按这个标准做, 这里补齐同款。
# ---------------------------------------------------------------------------
_install_backup_identical() {   # <src> <dst>; 逐字节一致返回 0
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2" 2>/dev/null
        return $?
    fi
    # cmp 缺失(裁剪版 busybox)时退回长度比较: 强于"只看存在", 但发现不了等长损坏。
    [ "$(wc -c < "$1" 2>/dev/null)" = "$(wc -c < "$2" 2>/dev/null)" ]
}

# 定向落盘。**不用裸 `sync` 兜底** —— 它把"这条路径没刷成功"伪造成成功, 与 90-menu 的
# `_reset_fsync_strict` 同口径; 两种形式都不支持时返回 1, 由调用方决定降级还是放弃。
_install_fsync() {   # <path>
    [ -e "$1" ] || return 0
    sync "$1" 2>/dev/null && return 0
    sync -f "$1" 2>/dev/null && return 0
    return 1
}

# 屏障失败**只告警一次**并继续: 快照内容已由 cmp 保证, 掉电屏障缺失是"少一层保护",
# 不足以让安装整体失败(那会让不支持定向 sync 的机器永远装不上)。
_install_fsync_or_warn() {   # <path>
    _install_fsync "$1" && return 0
    if [ "${_install_fsync_noted:-0}" -eq 0 ]; then
        echo "[警告] 本机 sync 不支持定向刷新, 恢复快照缺少掉电持久化屏障"
        _install_fsync_noted=1
    fi
    return 0
}

_install_backup() {
    local rel dest bak keep_tmp record_count=0 sums crc bytes
    # **先检查 .KEEP 再动手**(2026-09-22 七轮复审: 这条守卫此前只存在于
    # `_install_cleanup_stale`, 而本函数的调用方在调用前还有一次**无条件**的
    # `rm -rf "$ROLLBACK_DIR"` —— 于是"标记目录永不被自动删"的契约被从旁边绕过)。
    # 实测残局: 上一次安装失败留下的带标记目录, 其后缀若恰好等于**本次**的 `$$`(PID 复用),
    # `_install_cleanup_stale` 会正确地保留它并打印提示, 紧接着调用方的裸 `rm -rf` 把它连
    # `.KEEP` 和更新前的原始文件一起销毁 —— 而提示刚刚让用户去那个目录里找文件。
    # 判据放在**本函数内部**(而不是各调用点)是为了让"备份目标被占用"这件事只有一个判定入口;
    # 返回 2 与"备份失败(1)"区分开, 使调用方能给出各自的处置说明。
    #
    # **这是一条"拒绝继续"的路径, 不是透明处理**: 触发条件很窄(需与**上一次失败运行**的 PID
    # 相撞, 因为目录名带 `$$`), 但一旦命中, 本次安装**拒绝进行**并给出确切的删除命令, 而不是
    # 静默覆盖。方向是刻意选的 —— 另一种做法(照旧 `rm -rf`)会毁掉用户唯一的恢复副本;
    # 代价是处于该状态的用户必须先按提示删掉那个目录才能继续安装。
    # 文档措辞必须是"拒绝并给出确切命令", 不得写成"自动处理/透明兼容"(2026-09-22 与
    # 并行会话核对后确认)。
    if [ -L "$ROLLBACK_DIR" ] || { [ -e "$ROLLBACK_DIR" ] && [ ! -d "$ROLLBACK_DIR" ]; }; then
        echo "[错误] 恢复路径 $ROLLBACK_DIR 不是普通目录, 拒绝使用"
        return 2
    fi
    if [ -e "$ROLLBACK_DIR/.KEEP" ] || [ -L "$ROLLBACK_DIR/.KEEP" ] \
       || [ -e "$ROLLBACK_DIR/.INSTALLING" ] || [ -L "$ROLLBACK_DIR/.INSTALLING" ]; then
        echo "[错误] 恢复目录 $ROLLBACK_DIR 包含已标记快照/事务, 拒绝覆盖"
        echo "       请先核对该恢复目录后再重试"
        return 2
    fi
    # An interruption during backup can leave unmarked stale files. Never reuse them:
    # their old copies could contradict newly recorded `absent` entries.
    if [ -e "$ROLLBACK_DIR" ]; then
        rm -rf "$ROLLBACK_DIR" 2>/dev/null || return 1
        [ ! -e "$ROLLBACK_DIR" ] && [ ! -L "$ROLLBACK_DIR" ] || return 1
    fi
    mkdir -p "$ROLLBACK_DIR" 2>/dev/null || return 1
    keep_tmp="$ROLLBACK_DIR/.KEEP.tmp.$$"
    printf '%s\n' 'xray-install-backup-v2' > "$keep_tmp" 2>/dev/null || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dest="$DEPLOY_DIR/$rel"
        bak="$ROLLBACK_DIR/$rel"
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            mkdir -p "$(dirname "$bak")" 2>/dev/null || return 1
            cp -f "$dest" "$bak" 2>/dev/null || return 1
            [ -f "$bak" ] && [ ! -L "$bak" ] || return 1
            # 内容必须与源**逐字节一致**才允许记账: 只判"文件存在"分不清"cp 只写了一半"
            if ! _install_backup_identical "$dest" "$bak"; then
                echo "[错误] 备份内容与源不一致(cp 未完整落盘?), 拒绝继续: $rel"
                return 1
            fi
            _install_fsync_or_warn "$bak"
            printf 'present %s\n' "$rel" >> "$keep_tmp" 2>/dev/null || return 1
        else
            # A reused, unmarked rollback directory may still contain an old copy for a target
            # that is absent now. Remove that stale copy before committing the presence record.
            if [ -e "$bak" ] || [ -L "$bak" ]; then
                [ -f "$bak" ] && [ ! -L "$bak" ] || return 1
                rm -f "$bak" 2>/dev/null || return 1
                [ ! -e "$bak" ] && [ ! -L "$bak" ] || return 1
            fi
            printf 'absent %s\n' "$rel" >> "$keep_tmp" 2>/dev/null || return 1
        fi
        record_count=$((record_count + 1))
    done <<< "$(_install_relpaths)"
    [ "$record_count" -ge 2 ] || return 1
    sums=$(sed '1d' "$keep_tmp" | cksum) || return 1
    read -r crc bytes _ <<< "$sums"
    [[ "$crc" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || return 1
    printf 'complete %s %s %s\n' "$record_count" "$crc" "$bytes" >> "$keep_tmp" 2>/dev/null || return 1
    # **提交前屏障**: 备份内容(上面逐个刷过)+ 清单文件 + 目录项先落盘, `.KEEP` 这条
    # "提交记录"才允许出现在目录里; rename 之后再刷一次目录, 使"目录里存在 .KEEP ⇒ 它所
    # 声明的备份全部完整"这一条成立(否则掉电后恢复程序会读到半截备份, 见上方说明)。
    _install_fsync_or_warn "$keep_tmp"
    _install_fsync_or_warn "$ROLLBACK_DIR"
    mv -f "$keep_tmp" "$ROLLBACK_DIR/.KEEP" 2>/dev/null || return 1
    _install_fsync_or_warn "$ROLLBACK_DIR"
    _install_snapshot_read_entries "$ROLLBACK_DIR" 0 >/dev/null || {
        echo "[错误] 新建恢复快照校验失败: $ROLLBACK_DIR"
        return 1
    }
    return 0
}

_install_txn_marker() { printf '%s/.INSTALLING' "$ROLLBACK_DIR"; }

_install_snapshot_rel_ok() {
    local rel="$1" base
    case "$rel" in
        xray-deploy.sh|VERSION) return 0 ;;
        lib/*.sh)
            base="${rel#lib/}"
            [[ "$base" =~ ^[A-Za-z0-9_-]+\.sh$ ]] || return 1
            ;;
        templates/*.server.jsonc)
            base="${rel#templates/}"
            [[ "$base" =~ ^[A-Za-z0-9_-]+\.server\.jsonc$ ]] || return 1
            ;;
        *) return 1 ;;
    esac
    return 0
}

_install_snapshot_read_entries() {
    local d="$1" require_marker="${2:-1}" name suffix keep line footer_line marker
    local state rel extra count=0 seen='|' entries='' sums crc bytes
    local declared_count declared_crc declared_bytes saw_entrypoint=0 saw_version=0 trailer=0
    name="${d##*/}"
    case "$name" in .install-rollback.*) suffix="${name#.install-rollback.}" ;; *) return 1 ;; esac
    case "$suffix" in ''|*[!0-9]*) return 1 ;; esac
    [ "$d" = "$DEPLOY_DIR/$name" ] || return 1
    [ -d "$d" ] && [ ! -L "$d" ] || return 1
    marker="$d/.INSTALLING"
    if [ "$require_marker" = 1 ]; then [ -f "$marker" ] && [ ! -L "$marker" ] || return 1; fi
    keep="$d/.KEEP"
    [ -f "$keep" ] && [ ! -L "$keep" ] && [ -s "$keep" ] || return 1
    exec 3< "$keep" || return 1
    IFS= read -r line <&3 || { exec 3<&-; return 1; }
    if [ "$line" != xray-install-backup-v2 ]; then
        exec 3<&-
        echo "[错误] 旧版或未校验的恢复清单不能自动恢复, 保留现场供人工处理: $keep" >&2
        return 1
    fi
    while IFS= read -r line <&3 || [ -n "$line" ]; do
        case "$line" in complete\ *) footer_line="$line"; trailer=1; break ;; esac
        [[ "$line" =~ ^(present|absent)[[:space:]]([^[:space:]]+)$ ]] || { exec 3<&-; return 1; }
        state="${BASH_REMATCH[1]}"; rel="${BASH_REMATCH[2]}"
        _install_snapshot_rel_ok "$rel" || { exec 3<&-; return 1; }
        case "$seen" in *"|$rel|"*) exec 3<&-; return 1 ;; esac
        seen+="$rel|"
        case "$rel" in
            xray-deploy.sh) saw_entrypoint=1 ;;
            VERSION) saw_version=1 ;;
            lib/*)
                [ ! -L "$d/lib" ] && [ ! -L "$DEPLOY_DIR/lib" ] || { exec 3<&-; return 1; }
                ;;
            templates/*)
                [ ! -L "$d/templates" ] && [ ! -L "$DEPLOY_DIR/templates" ] || { exec 3<&-; return 1; }
                ;;
        esac
        case "$state" in
            present) [ -f "$d/$rel" ] && [ ! -L "$d/$rel" ] || { exec 3<&-; return 1; } ;;
            absent) [ ! -e "$d/$rel" ] && [ ! -L "$d/$rel" ] || { exec 3<&-; return 1; } ;;
            *) exec 3<&-; return 1 ;;
        esac
        entries+="$state $rel"$'\n'
        count=$((count + 1))
    done
    [ "$trailer" -eq 1 ] || { exec 3<&-; return 1; }
    if IFS= read -r extra <&3 || [ -n "$extra" ]; then exec 3<&-; return 1; fi
    exec 3<&-
    [ "$count" -ge 2 ] && [ "$saw_entrypoint" -eq 1 ] && [ "$saw_version" -eq 1 ] || return 1
    read -r marker declared_count declared_crc declared_bytes extra <<< "$footer_line"
    [ "$marker" = complete ] && [ -z "${extra:-}" ] || return 1
    [[ "$declared_count" =~ ^[0-9]+$ && "$declared_crc" =~ ^[0-9]+$ && "$declared_bytes" =~ ^[0-9]+$ ]] || return 1
    [ "$declared_count" -eq "$count" ] || return 1
    sums=$(printf '%s' "$entries" | cksum) || return 1
    read -r crc bytes _ <<< "$sums"
    [ "$crc" = "$declared_crc" ] && [ "$bytes" = "$declared_bytes" ] || return 1
    printf '%s' "$entries"
}

_install_snapshot_validate() {
    _install_snapshot_read_entries "$1" 1 >/dev/null
}

_install_finish_transaction() {
    local marker
    marker="$(_install_txn_marker)"
    rm -f "$marker" 2>/dev/null || return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    if ! rm -f "$ROLLBACK_DIR/.KEEP" 2>/dev/null || [ -e "$ROLLBACK_DIR/.KEEP" ] || [ -L "$ROLLBACK_DIR/.KEEP" ]; then
        echo "[警告] 安装事务已收尾, 但恢复目录清理失败, 保留: $ROLLBACK_DIR"
        return 0
    fi
    rm -rf "$ROLLBACK_DIR" 2>/dev/null || true
    return 0
}


_install_recover_interrupted() {
    local d old_rb found=0 marker suffix
    for d in "$DEPLOY_DIR"/.install-rollback.*; do
        [ -e "$d" ] || [ -L "$d" ] || continue
        suffix="${d##*.install-rollback.}"
        case "$suffix" in ''|*[!0-9]*) continue ;; esac
        marker="$d/.INSTALLING"
        [ -e "$marker" ] || [ -L "$marker" ] || continue
        found=1
        if ! _install_snapshot_validate "$d"; then
            echo "[错误] 未完成安装事务的恢复快照无效, 保留现场并中止: $d"
            return 1
        fi
        old_rb="$ROLLBACK_DIR"
        ROLLBACK_DIR="$d"
        echo "[警告] 发现未完成安装事务, 正在恢复更新前文件: $d"
        if _install_rollback && _install_finish_transaction; then
            :
        else
            echo "[错误] 未完成安装事务恢复失败, 保留恢复目录: $d"
            ROLLBACK_DIR="$old_rb"
            return 1
        fi
        ROLLBACK_DIR="$old_rb"
    done
    [ "$found" -eq 0 ] || echo "[信息] 未完成安装事务已恢复"
    return 0
}

_install_abort_signal() {
    local code="$1" marker
    marker="$(_install_txn_marker)"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        if _install_rollback; then
            _install_finish_transaction || echo "[错误] 信号回滚已完成, 但无法清除事务标记; 保留恢复目录: $ROLLBACK_DIR"
        fi
    fi
    exit "$code"
}

_install_rollback() {
    local rel dest bak bad="" state entries line tmp
    entries=$(_install_snapshot_read_entries "$ROLLBACK_DIR" 1) || {
        echo "[错误] 回滚快照无效, 保留现场: $ROLLBACK_DIR"
        return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        IFS=' ' read -r state rel extra <<< "$line"
        [ -n "$state" ] && [ -n "$rel" ] && [ -z "${extra:-}" ] || return 1
        dest="$DEPLOY_DIR/$rel"
        bak="$ROLLBACK_DIR/$rel"
        case "$state" in
            present)
                tmp="${dest}.restore.$$"
                mkdir -p "$(dirname "$dest")" 2>/dev/null || { bad="$bad $rel"; continue; }
                if ! cp -p "$bak" "$tmp" 2>/dev/null || ! cmp -s "$bak" "$tmp" 2>/dev/null \
                   || ! mv -f "$tmp" "$dest" 2>/dev/null; then
                    rm -f "$tmp" 2>/dev/null
                    bad="$bad $rel"
                fi
                ;;
            absent)
                if [ -e "$dest" ] || [ -L "$dest" ]; then
                    rm -f "$dest" 2>/dev/null || bad="$bad $rel"
                fi
                [ ! -e "$dest" ] && [ ! -L "$dest" ] || bad="$bad $rel"
                ;;
            *) return 1 ;;
        esac
    done <<< "$entries"
    if [ -n "$bad" ]; then
        echo "[错误] 回滚未完成, 以下文件可能处于不一致状态:${bad}"
        echo "       请人工核对 $DEPLOY_DIR 或重跑 install.sh --update"
        return 1
    fi
    return 0
}

_install_cleanup_stale() {
    # SIGKILL 残留的回滚目录(SIGKILL 时回滚代码没机会执行): 内容是旧文件的副本, 无害但会堆积。
    #
    # **绝不能删正在并发安装的那个** —— 那个安装的进程还活着, 其 _install_rollback 正要靠这份
    # 备份恢复; 备份被删后, 回滚循环对每个条目都读到"备份里没有", 于是误判成"本次新建"而
    # **删除既有文件**。实测复现: 安装 A 备份完 -> 安装 B 启动调本函数 -> A 落地后失败触发回滚
    # -> 一份健康的 5 文件安装被清成 0 文件(数据全丢)。
    #
    # 判据(顺序即优先级):
    #   1. 目录内有 `.KEEP`(2026-09-21 七轮 P1) => **恢复源, 永不自动删**。
    #      它是上一次安装留下的"更新前字节", 且**没有任何自动事件能证明它不再需要** ——
    #      "目录名里的 PID 已死"恰恰是它的常态(那次安装进程早已退出), 所以不能拿 PID 判它。
    #      实测复现的正是这条: D2 保留的恢复源在下一次安装启动时被删, 而错误提示让用户
    #      去跑那次安装。只有人工处理才清它, 故这里输出提示让受保护目录**可见**。
    #   2. 无标记 + PID 存活 => 跳过(并发安装的备份)。
    #   3. 无标记 + PID 已死 => rm -rf(真正的 SIGKILL 残留)。
    #   4. 后缀非数字 => 跳过(非本函数创建的目录; 与注释一致 —— 旧代码这里缺 `continue`,
    #      控制流落到 rm -rf, 与注释"不动"相反, 属实测发现的注释/行为矛盾)。
    #
    # `kill -0` 这条判据**保留**(不因第 1 条而冗余): 它是"锁被绕过/丢失/旧版脚本"时的
    # fail-safe, 删掉会重新打开上面那条数据丢失路径。
    # 代价是 PID 复用可能让我们**少删**一次(残留多留一会儿, 无害); 反方向才是数据丢失,
    # 所以这个方向是刻意选的。`$$` 只保证路径不互相覆盖, 保护不了被**别人**的清理 glob 扫到。
    local d pid protected=0
    local -a prot_list=()
    for d in "$DEPLOY_DIR"/.install-rollback.*; do
        [ -e "$d" ] || continue
        [ -e "$d/.KEEP" ] && { protected=$((protected+1)); prot_list+=("$d"); continue; }
        pid="${d##*.install-rollback.}"
        case "$pid" in
            ''|*[!0-9]*) continue ;;                          # 无数字后缀: 非本函数创建, 不动
            *) kill -0 "$pid" 2>/dev/null && continue ;;      # 安装进程仍活着 => 并发安装的备份
        esac
        rm -rf "$d" 2>/dev/null || true
    done
    if [ "$protected" -gt 0 ]; then
        # **绝不广告 glob**(2026-09-22 七轮复审 D5): 旧文案让用户删
        # `$DEPLOY_DIR/.install-rollback.*`, 而该 glob 展开后**包含**上面刚跳过的受保护目录 ——
        # 照做的用户会删掉唯一的恢复源(与"错误信息不得指引用户执行销毁恢复源的命令"直接冲突,
        # 且同一段提示上一行称"受保护"、下一行给出会扫掉它的通配符, 自相矛盾)。
        # 改为**逐条列出受保护目录的绝对路径**, 并点明它们是"更新前的原始字节"。
        echo "[提示] 发现 ${protected} 个受保护的恢复目录(上次安装失败或被强杀时保留的更新前文件):"
        printf '         %s\n' "${prot_list[@]}"
        echo "       这些目录**不可自动清理**, 其中保存着更新前的原始文件;"
        echo "       确认已不再需要后, 请按上面的完整路径逐个手动删除(不要用通配符)。"
    fi
}

# ---------------------------------------------------------------------------
# 下载主脚本 + lib + templates 并汇报结果
# ---------------------------------------------------------------------------
download_all() {
    local ok=0 fail=0
    # 下载到临时 staging 目录, 全部成功后再 atomic 复制到目标路径 (S7)
    #
    # mktemp 失败必须**立即中止**: stage 为空串时下面所有路径拼接都会退化成绝对根路径 ——
    # "$stage/xray-deploy.sh" 变成 "/xray-deploy.sh"、"$stage/lib" 变成 "/lib"、
    # "$stage/templates" 变成 "/templates", 于是下载产物被直接写到系统根目录, 且末尾
    # rm -rf "$stage" 变成 rm -rf ""(空操作)让垃圾永久残留。磁盘满/只读/inode 耗尽正是
    # 本 PR 关注的低配 VPS 场景。
    local stage
    stage=$(mktemp -d) || { echo "[错误] 无法创建临时目录(/tmp 写满或只读?), 安装中止"; return 1; }
    local stage_lib="$stage/lib" stage_tpl="$stage/templates"
    mkdir -p "$stage_lib" "$stage_tpl"

    echo "[信息] 下载主脚本..."
    if dl "${REMOTE_BASE}/xray-deploy.sh" "$stage/xray-deploy.sh"; then
        echo "[成功] 主脚本 ✓"
        ok=$((ok+1))
    else
        echo "[错误] 主脚本下载失败"; fail=$((fail+1))
    fi

    if dl "${REMOTE_BASE}/VERSION" "$stage/VERSION"; then
        ok=$((ok+1))
    else
        echo "[警告] VERSION 下载失败"; fail=$((fail+1))
    fi

    echo "[信息] 下载 lib 模块..."
    for f in $LIB_MODULES; do
        if dl "${REMOTE_BASE}/lib/${f}.sh" "$stage_lib/${f}.sh"; then
            ok=$((ok+1))
        else
            echo "[错误] lib/${f}.sh 下载失败"
            fail=$((fail+1))
        fi
    done

    echo "[信息] 下载模板..."
    for t in $TPL_NAMES; do
        if dl "${REMOTE_BASE}/templates/${t}.server.jsonc" "$stage_tpl/${t}.server.jsonc"; then
            ok=$((ok+1))
        else
            echo "[错误] templates/${t}.server.jsonc 下载失败"
            fail=$((fail+1))
        fi
    done

    echo "[信息] 下载完成: 成功 ${ok}, 失败 ${fail}"
    if [ "$fail" -gt 0 ]; then
        rm -rf "$stage"
        echo "[错误] 部分文件下载失败, 已取消更新(现有文件未变动)"
        return 1
    fi

    # 全部成功 → 复制到最终路径。
    #
    # 2026-09-21 复审(P2): 旧写法是 5 条**逐目录** cp(cp -f "$stage_lib"/*.sh "$INSTALL_LIB_DIR/")。
    # 目录级 cp 中途失败(磁盘满/IO)会在目标目录里留下"一半新、一半旧"的 lib/ —— 正是
    # xray-deploy.sh 启动时那条"模块缺失/版本不一致"检查要防的状态, 而旧代码只看 cp 的
    # 退出码就报成功, 用户直到下次 xd 才以怪异报错暴露。
    # 现在逐**文件**落地, 且每个文件都走 tmp → mv: rename 在同一目录内是原子的, 于是每个
    # 模块要么是完整的旧版、要么是完整的新版, 永远不会出现半截文件。
    # (不做目录级 rename 切换: 运行期 manager 自己就在目标目录内。)
    #
    # 2026-09-21 五轮复审(P1): 逐文件原子 ≠ 整版本原子。落地段升级为"备份 → 落地 → 复核 →
    # 失败整体回滚"四段式(见 _install_backup 上方说明), 保证结果只有"全部新"或"全部旧"。
    mkdir -p "$DEPLOY_DIR" "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    # **注意: 这里绝不能无条件 `rm -rf "$ROLLBACK_DIR"`**。它看似只是"清理上次的残留",
    # 但 `$ROLLBACK_DIR` 带 `$$` 后缀, 一旦与上一次安装(已退出)留下的**带 `.KEEP` 的恢复
    # 目录**同名(PID 复用), 这一行就会销毁唯一的恢复源 —— 而 `_install_cleanup_stale`
    # 刚刚才因为 `.KEEP` 特意保留了它。判据统一放在 `_install_backup` 内部(它自己会检查
    # `.KEEP` 并返回 2), 调用点只按返回码分流。
    _bk_rc=0
    _install_backup || _bk_rc=$?
    if [ "$_bk_rc" -eq 2 ]; then
        # 恢复目录被标记占用: 不清理、不继续 —— 把处置权交回用户
        rm -rf "$stage" 2>/dev/null
        return 1
    fi
    if [ "$_bk_rc" -ne 0 ]; then
        rm -rf "$stage" "$ROLLBACK_DIR" 2>/dev/null
        echo "[错误] 备份现有安装失败(磁盘空间/权限?), 未改动任何文件"
        return 1
    fi
    : > "$(_install_txn_marker)" 2>/dev/null || {
        rm -rf "$stage" "$ROLLBACK_DIR" 2>/dev/null
        echo "[错误] 无法写入安装事务标记, 未改动任何文件"
        return 1
    }
    # 标记也必须先落盘: 掉电后若没有它, 一个已经开始的落地过程会被当成"未开始"
    # (`_install_recover_interrupted` 只认带标记的目录), 留下混合版本树。
    _install_fsync_or_warn "$(_install_txn_marker)"
    _install_fsync_or_warn "$ROLLBACK_DIR"
    local copy_ok=1 m
    _install_file "$stage/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh" || copy_ok=0
    chmod +x "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null || copy_ok=0
    _install_file "$stage/VERSION" "$DEPLOY_DIR/VERSION" || copy_ok=0
    for m in $LIB_MODULES; do
        _install_file "$stage_lib/${m}.sh" "$INSTALL_LIB_DIR/${m}.sh" || copy_ok=0
    done
    local t
    for t in $TPL_NAMES; do
        _install_file "$stage_tpl/${t}.server.jsonc" "$INSTALL_TPL_DIR/${t}.server.jsonc" || copy_ok=0
    done
    rm -rf "$stage"
    # 落地或复核任一失败 => 整体回滚到第 1 步之前。回滚失败时 _install_rollback 自己会
    # 点名不一致的文件并返回 1, 这里把两个失败事实都报出来。
    if [ "$copy_ok" -ne 1 ] || ! _verify_installed; then
        echo "[错误] 文件落地/复核失败, 正在回滚到更新前状态..."
        # 回滚失败时**必须保留** $ROLLBACK_DIR —— 它是唯一的恢复源, 里面装的是更新前的
        # 原始字节。删掉它就等于"回滚失败还销毁唯一副本"(项目在 hysteria 证书快照上有同款
        # 明文契约)。成功路径才清理。
        if _install_rollback; then
            _install_finish_transaction || {
                echo "[错误] 回滚完成, 但事务标记无法清除; 保留备份目录: $ROLLBACK_DIR"
                return 1
            }
        else
            echo "[错误] 回滚未完全成功, 已保留备份目录: $ROLLBACK_DIR"
            echo "       请人工从该目录恢复, 或重跑 install.sh --update"
        fi
        return 1
    fi
    _install_finish_transaction || {
        echo "[错误] 更新文件已复核, 但事务标记无法清除; 保留备份目录: $ROLLBACK_DIR"
        return 1
    }
    return 0
}

# Install and verify the primary command entry point. ln can succeed by placing a link inside an
# existing destination directory, which is not the requested /usr/local/bin/xd executable.
_install_xd_link() {
    local bin_dir want got
    bin_dir=$(dirname "$INSTALL_BIN")
    mkdir -p "$bin_dir" || { echo "[错误] 无法创建命令目录: $bin_dir"; return 1; }
    if [ -d "$INSTALL_BIN" ] && [ ! -L "$INSTALL_BIN" ]; then
        echo "[错误] 命令目标是目录, 拒绝创建嵌套链接: $INSTALL_BIN"
        return 1
    fi
    ln -sfn "$DEPLOY_DIR/xray-deploy.sh" "$INSTALL_BIN" || {
        echo "[错误] 创建快捷命令失败: $INSTALL_BIN(权限? /usr/local/bin 只读?)"
        return 1
    }
    if ! chmod +x "$INSTALL_BIN" 2>/dev/null; then
        echo "[错误] 设置快捷命令执行权限失败: $INSTALL_BIN"
        return 1
    fi
    want=$(readlink -f "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null) || want="$DEPLOY_DIR/xray-deploy.sh"
    got=$(readlink -f "$INSTALL_BIN" 2>/dev/null) || got=""
    if [ ! -x "$INSTALL_BIN" ] || [ "$got" != "$want" ]; then
        echo "[错误] 快捷命令链接校验失败: $INSTALL_BIN"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 安装级互斥锁(2026-09-21 建立; 2026-09-22 重做为 flock 优先; 锁根 2026-09-26 固定)
#
# 为什么需要: 备份+整体回滚只在**单个**安装者时成立。两个 install.sh 并发时 A 落地到一半,
# B 的 _install_backup 会把"半新半旧"的树当成"更新前状态"存下来; B 再失败回滚就把它写了回去,
# 且 A 可能已报成功。_install_cleanup_stale 的 kill -0 保护的是备份目录, 不是快照内容。
#
# 取舍(实测): 无内核仲裁时"接管陈旧锁"无法证明安全 —— mkdir + rm -rf 接管 12 轮中 5 轮双持有,
# mv 改名 4 轮, token 目录 2~4 轮(且常有人放弃); **flock 0 轮**。故有 flock 就用 flock
# (进程退出含 SIGKILL 自动释放), 无 flock 退化为 mkdir-only 且**永不自动接管**。
#
# 锁根固定 /var/lock/xray-deploy(标准位置, 通常是 tmpfs, 重启自清; 不污染 /opt), **不读任何
# 环境变量覆盖**(否则两进程可用不同命名空间而互不排斥); 建不出时退 /run/lock, 都失败则返回
# /var/lock 让调用方 fail-closed, **绝不回落到 /opt**。与 00-common 的 `_deploy_lock_root` 同口径。
#
# 已知残局: `exec {fd}>>` 不设 CLOEXEC, 安装进程被 SIGKILL 时在跑的子进程会替它持锁, 并在
# 该子进程退出后释放 —— 通常数十秒, curl --retry 下可能超过一分钟(**不要写"最迟 30s"**)。
# 有意不改成"不继承 fd": bash 无可移植写法, 收益只是缩短该窗口。
# ---------------------------------------------------------------------------
_install_lock_root() {
    # 选锁根并**真正尝试创建**: `/var/lock` 优先, 失败再试同族 tmpfs `/run/lock`
    # (只按权限位判断会在"只读文件系统"上给出假阳性 —— 复审 P2)。两处都建不出时返回
    # /var/lock 路径, 由调用方 fail-closed(绝不回落到 /opt)。
    # **本函数有副作用, 故其求值被推迟到参数校验之后**(见下方 `INSTALL_LOCK_ROOT=`),
    # 一个拼错的开关不该创建任何目录。
    if mkdir -p /var/lock/xray-deploy 2>/dev/null; then printf '%s' "/var/lock/xray-deploy"; return 0; fi
    if mkdir -p /run/lock/xray-deploy 2>/dev/null; then printf '%s' "/run/lock/xray-deploy"; return 0; fi
    printf '%s' "/var/lock/xray-deploy"
}
INSTALL_LOCK_PARENT="${DEPLOY_DIR%/*}"
INSTALL_LOCK_NAME="${DEPLOY_DIR##*/}"
[ -n "$INSTALL_LOCK_PARENT" ] || INSTALL_LOCK_PARENT="/"
# 主锁路径(ROOT/DIR/FILE)与 `_install_lock_root` 的求值被**推迟到参数校验之后** ——
# 该函数会真正尝试创建锁根目录, 而拼错的开关不该创建任何东西(见下方 `INSTALL_LOCK_ROOT=`)。
# 此处只放无副作用的常量。
# **跨版本协调**(2026-09-23 十五轮, 2026-09-26 随锁根迁移到 /var/lock 扩为两层):
#   L1 (0.17.13/0.18.0): 部署父目录下 `.<name>.install.lock[.fd]`
#   L2 (<=0.17.11):      部署目录内 `.install.lock[.fd]`
# 只拿新锁**排斥不了仍在运行的旧版安装**: 旧版只认它自己的路径, 于是 A(旧)与 B(新)会各持
# 一把不同的锁同时落地。故新版在拿到主锁后, 对**已存在**的旧路径再按**同一种手段**取一次锁
# (flock 对 flock / mkdir 对 mkdir), 取不到一律 fail-closed, 绝不删或接管别人的锁。
# **只在旧路径已存在时协调**(存在 ⇔ 旧版进程曾/正在用): 不再凭空重建旧路径 —— 否则全新
# 安装又会在 /opt 留下旧锁文件, 正是本次改动要消除的污染。
# **残局(未闭环)**: 旧版进程若在本安装释放之后才启动, 或在旧路径被删后重建, 新版无从协调。
INSTALL_LEGACY1_LOCK_FILE="${INSTALL_LOCK_PARENT}/.${INSTALL_LOCK_NAME}.install.lock.fd"
INSTALL_LEGACY1_LOCK_DIR="${INSTALL_LOCK_PARENT}/.${INSTALL_LOCK_NAME}.install.lock"
INSTALL_LEGACY_LOCK_FILE="$DEPLOY_DIR/.install.lock.fd"
INSTALL_LEGACY_LOCK_DIR="$DEPLOY_DIR/.install.lock"
INSTALL_LOCK_HELD=0
INSTALL_PRIMARY_MARKER_HELD=0
INSTALL_LOCK_FD=""
INSTALL_LEGACY_LOCK_FD=""
INSTALL_LEGACY_LOCK_DIR_HELD=0
INSTALL_LEGACY1_LOCK_FD=""
INSTALL_LEGACY1_LOCK_DIR_HELD=0

_install_lock_owner_pid() {   # [锁目录]; 输出持有者 PID; 非数字/空/**数值为 0** 一律输出空(视为"无法判定")
    local d="${1:-$INSTALL_LOCK_DIR}" p
    p=$(cat "$d/pid" 2>/dev/null)
    case "$p" in
        ''|*[!0-9]*) printf '%s' '' ;;
        # `kill -0 0` 与 `kill -0 00` 在 GNU 与 busybox 上都返回 0(永远"存活"), 故凡是
        # **数值为 0** 的写法(0 / 00 / 000)都必须归入"无法判定", 不能只特判字面 `0`
        # —— 否则一个零填充的 pidfile 会让锁永久拒绝(实测 13s 后报"另一个安装正在运行(pid 00)")。
        *)           [ "$((10#$p))" -eq 0 ] && { printf '%s' ''; return 0; }
                     printf '%s' "$p" ;;
    esac
}

_install_lock_write_pid() {   # [锁目录]; 同目录 rename 原子写入, 避免半写
    local d="${1:-$INSTALL_LOCK_DIR}" t
    t="$d/.pid.$$"
    printf '%s\n' "$$" > "$t" 2>/dev/null || return 1
    mv -f "$t" "$d/pid" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
    return 0
}

# mkdir 锁的取用(主锁与旧版锁共用同一实现, 避免"同一条件在各调用点各自解释"):
# **永不自动接管** —— 残留锁目录一律拒绝并要求人工清理, 只删本进程自己创建的锁。
_install_lock_mkdir_take() {   # <锁目录> <显示名>; 复用同一实现, 无隐藏全局状态
    local d="$1" label="$2" i pid
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if mkdir "$d" 2>/dev/null; then
            if _install_lock_write_pid "$d"; then return 0; fi
            rm -rf "$d" 2>/dev/null
            echo "[错误] 无法写入${label} $d/pid(磁盘空间/权限?), 安装中止"
            return 1
        fi
        # 路径存在但不是目录 => 明确报错, 不 rm、不等待(等待不会让它变成目录)
        if [ ! -d "$d" ]; then
            echo "[错误] ${label}路径存在但不是目录: $d"
            echo "       请手动处理该路径后重试"
            return 1
        fi
        pid=$(_install_lock_owner_pid "$d")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            [ "$i" -eq 14 ] && {
                echo "[错误] 另一个安装正在运行(pid $pid), 本次中止以免两棵树互相覆盖"
                echo "       若确认该进程已不存在, 请手动删除: $d"
                return 1; }
            sleep 1; continue
        fi
        # 陈旧或无法判定: 本实现**不接管**(见上方实测结论), 但立刻给出可执行的处置办法,
        # 而不是让用户干等 14 秒后才看到同一句话。
        echo "[错误] 检测到无人持有的${label}(pid ${pid:-未知}): $d"
        echo "       该目录可能是上次被强杀(SIGKILL)留下的; 确认无其他安装正在运行后,"
        echo "       请手动删除该目录后重试"
        return 1
    done
    echo "[错误] 等待${label}超时: $d"
    return 1
}

_install_lock_mkdir_release() {   # <锁目录>; 归属校验后才删
    local d="$1" p
    p=$(_install_lock_owner_pid "$d")
    [ "$p" = "$$" ] && rm -rf "$d" 2>/dev/null
    return 0
}

# 与 flock 主锁配对的目录 marker: mkdir 退路先占位再 /proc 复查 flock FD;
# flock 持有者也在进入发布区前占有同一目录, 并以 lock-file inode 见证安全自愈自身 SIGKILL 残留。
_install_primary_marker_take() {  # caller already holds INSTALL_LOCK_FD
    local devino witness owner i
    devino=$(_install_lock_devino "$INSTALL_LOCK_FILE") || devino=""
    [ -n "$devino" ] || { echo "[错误] 无法读取安装 flock 文件标识, 安装中止"; return 1; }
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
            owner="${BASHPID:-$$}"
            if printf '%s\n' "$owner" > "$INSTALL_LOCK_DIR/pid" 2>/dev/null \
               && printf '%s\n' "$devino" > "$INSTALL_LOCK_DIR/.witness" 2>/dev/null \
               && [ "$(cat "$INSTALL_LOCK_DIR/.witness" 2>/dev/null)" = "$devino" ]; then
                INSTALL_PRIMARY_MARKER_HELD=1
                return 0
            fi
            [ "$(cat "$INSTALL_LOCK_DIR/pid" 2>/dev/null)" = "$owner" ] && rm -rf "$INSTALL_LOCK_DIR" 2>/dev/null
            echo "[错误] 无法建立安装锁跨后端见证标记, 安装中止"
            return 1
        fi
        if [ -d "$INSTALL_LOCK_DIR" ] && [ ! -L "$INSTALL_LOCK_DIR" ] \
           && [ -f "$INSTALL_LOCK_DIR/.witness" ] && [ ! -L "$INSTALL_LOCK_DIR/.witness" ]; then
            witness=$(cat "$INSTALL_LOCK_DIR/.witness" 2>/dev/null) || witness=""
            if [ "$witness" = "$devino" ]; then
                if rm -rf "$INSTALL_LOCK_DIR" 2>/dev/null \
                   && [ ! -e "$INSTALL_LOCK_DIR" ] && [ ! -L "$INSTALL_LOCK_DIR" ]; then
                    continue
                fi
                echo "[错误] 无法清理安装锁陈旧 flock 见证, 安装中止"
                return 1
            fi
            echo "[错误] 安装锁见证身份不符, 拒绝接管: $INSTALL_LOCK_DIR"
            return 1
        fi
        sleep 1
    done
    echo "[错误] 等待安装 mkdir 后端互斥超时或发现残留锁: $INSTALL_LOCK_DIR"
    return 1
}

_install_primary_marker_release() {
    [ "${INSTALL_PRIMARY_MARKER_HELD:-0}" = "1" ] || return 0
    local devino owner witness
    owner=$(cat "$INSTALL_LOCK_DIR/pid" 2>/dev/null) || owner=""
    witness=$(cat "$INSTALL_LOCK_DIR/.witness" 2>/dev/null) || witness=""
    devino=$(_install_lock_devino "$INSTALL_LOCK_FILE") || devino=""
    if [ "$owner" != "${BASHPID:-$$}" ] || [ -z "$devino" ] || [ "$witness" != "$devino" ]; then
        echo "[错误] 安装锁见证归属/身份校验失败, 保留: $INSTALL_LOCK_DIR"
        INSTALL_PRIMARY_MARKER_HELD=0
        return 1
    fi
    if ! rm -rf "$INSTALL_LOCK_DIR" 2>/dev/null \
       || [ -e "$INSTALL_LOCK_DIR" ] || [ -L "$INSTALL_LOCK_DIR" ]; then
        echo "[错误] 无法删除安装锁见证: $INSTALL_LOCK_DIR"
        INSTALL_PRIMARY_MARKER_HELD=0
        return 1
    fi
    INSTALL_PRIMARY_MARKER_HELD=0
    return 0
}

# 确认"我们持有的旧版安装锁 fd"仍指向**路径上那个文件**(十六轮 P2-②)。获取顺序是
# "主锁 → mkdir 部署目录 → flock 旧版锁文件"; 旧版卸载者若在中间 `rm -rf` 掉整棵树, 我们
# 打开的锁文件会被解除链接, 之后 flock 成功却落在无目录项的 inode 上, 而新来的旧版进程能在
# 同一路径重建文件并同时加锁。复核失败即拒绝(宁可拒绝, 不做双重放行); fd 目标无法读取时
# 同样拒绝，不能把"无法确认仍指向原路径"当成安全。
_install_lock_inode_ok() {   # <fd> <path>
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

# 见证 inode 身份: 打开的旧锁 fd 必须与 T1 见证 fd 指向同一 inode。只查"fd 是否指向路径上的
# 文件"挡不住"路径存在 → 被删 → 我们新建 inode"的 TOCTOU —— 那时 fd 与路径都是新 inode, 会
# 通过复核, 而 flock 落在旧进程根本不认识的新 inode 上(与 `_xray_legacy_lock_identity_ok` 同源)。
_install_legacy_lock_identity_ok() {   # <fd> <见证fd>; 0 = 同一 inode
    local fd="$1" wfd="$2"
    [ -n "$fd" ] && [ -n "$wfd" ] || return 1
    [ "/proc/self/fd/$fd" -ef "/proc/self/fd/$wfd" ]
}

# 路径的 dev:ino 标识(mkdir 标记的自愈判定)。取不到输出空; 调用方必须 fail-closed。
_install_lock_devino() { stat -c '%d:%i' "$1" 2>/dev/null; }

# 旧版安装器不认识部署目录外的新锁。若旧版已拿到目录内锁并在卸载时删掉整棵树,
# 新版随后重建同名目录/锁路径会得到全新的 inode, 与旧进程手里的已删除 fd 不互斥。
# 在重建旧路径前扫描仍持有已删除部署文件的进程并 fail-closed。该检查只能缩小窗口;
# 旧版的 mkdir 锁在整棵树删除后没有可追踪 fd 时, 仍需等所有旧版进程退出后再重试。
_install_legacy_deleted_tree_active() {   # <deploy_dir>; 0 = 其他进程仍持有已删除树中的 fd
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

# 当前无 flock 时仍要拒绝**另一种旧后端**的活持有者: 旧版可能用 flock 文件,
# 而本进程只能使用 mkdir 退路。0=文件被其他进程打开, 1=确认没有, 2=无法确认。
_install_legacy_flock_active() {
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
        # fd 在扫描期间被并发关闭时无法判定该进程是否持有目标文件 —— 按契约返回
        # "无法确认"(2) 而不是静默跳过; 与 20-xray-core 的 `_xray_legacy_flock_active`
        # 保持同一 fail-closed 语义。判定主力是上面的 find 快路径(一次遍历, 无逐 fd 竞态)。
        target=$(readlink "$p" 2>/dev/null) || return 2
        [ "$target" = "$want" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 旧版锁协调助手(与 20-xray-core 的 `_xray_legacy_lock_name` 同语义)。**仅在调用方确认
# 旧路径已存在时调用**; 它**绝不新建树外的旧 flock 文件(.fd)** —— 那是持久污染(复审 P2)。
#   · 旧 flock 文件存在 → 取同路径 flock(见证/身份复核, 防"存在→被删→新建"TOCTOU);
#     并建同名 `.witness` mkdir 标记挡旧 mkdir 后端 —— **L1(树外)与 L2(树内)都建**,
#     释放时删除, 否则"只检查不占位"会让旧无-flock 进程在检查之后 mkdir 插入(复审四 P1)。
#   · 旧 flock 文件不存在(只有旧 mkdir 目录) → 直接 fail-closed, 不凭空建 .fd(复审 P2)。
# 失败一律 fail-closed; 由调用方负责释放已取得的主锁。
# ---------------------------------------------------------------------------
_install_lock_legacy_flock_take() {   # <file> <dir> <fdvar> <heldvar> <label>
    local lfile="$1" ldir="$2" fdvar="$3" heldvar="$4" label="$5"
    local witness="" devino="" ef=""
    # 旧 mkdir 标记对 L1(树外 /opt/.xray-deploy.*)与 L2(树内)一视同仁地创建: 只检查不占位
    # 留了真实窗口 —— 旧无-flock 进程可在检查之后 `mkdir "$ldir"` 并进入(复审四 P1)。标记
    # 释放时删除, /opt 不留持久产物; **旧 flock 文件(.fd)缺失时仍然绝不新建**(复审 P2, 见下)。
    if [ ! -e "$lfile" ]; then
        # 旧 flock 文件不存在: **绝不为了协调而新建它**(会污染 /opt)。若旧 mkdir 目录存在
        # ⇒ 旧会话仍在, fail-closed; 否则调用方本就不该调用。
        if [ -e "$ldir" ]; then
            echo "[错误] ${label}目录仍存在: $ldir"
            echo "       确认没有旧版会话在运行后, 请人工检查并清理该锁目录后重试"
        fi
        return 1
    fi
    eval "exec {witness}<\"\$lfile\"" 2>/dev/null || witness=""
    if [ -z "$witness" ]; then
        echo "[错误] ${label}文件存在但无法打开见证, 本次安装中止: $lfile"
        return 1
    fi
    if ! eval "exec {${fdvar}}>>\"\$lfile\"" 2>/dev/null; then
        eval "exec ${witness}<&-" 2>/dev/null
        echo "[错误] 无法打开${label}文件 $lfile(权限/只读文件系统?), 本次安装中止"
        return 1
    fi
    eval "ef=\${${fdvar}}"
    if ! _install_legacy_lock_identity_ok "$ef" "$witness"; then
        echo "[错误] ${label}文件在判定后被删除/替换(部署目录正被卸载?), 本次中止"
        eval "exec ${witness}<&-" 2>/dev/null
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    eval "exec ${witness}<&-" 2>/dev/null
    if ! flock -n "$ef" 2>/dev/null; then
        echo "[错误] 旧版安装/卸载仍在运行(持有 $lfile), 本次中止"
        echo "       以免两棵树互相覆盖; 等它退出后重试(内核会在持有进程退出时自动释放)"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    if ! _install_lock_inode_ok "$ef" "$lfile"; then
        echo "[错误] ${label}文件在获取后被替换/删除(部署目录正被卸载?), 本次中止"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    devino=$(_install_lock_devino "$lfile")
    if [ -z "$devino" ]; then
        echo "[错误] 无法读取${label}文件标识(dev:ino), 本次安装中止"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    if [ -e "$ldir" ]; then
        if [ -f "$ldir/.witness" ] && [ "$(cat "$ldir/.witness" 2>/dev/null)" = "$devino" ]; then
            rm -rf "$ldir" 2>/dev/null
        fi
    fi
    if [ -e "$ldir" ]; then
        echo "[错误] ${label}目录仍存在: $ldir"
        echo "       确认没有旧版会话在运行后, 请人工检查并清理该锁目录后重试"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    if ! mkdir "$ldir" 2>/dev/null; then
        echo "[错误] ${label}目录被占用或无法创建: $ldir"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    eval "$heldvar=1"
    if ! printf '%s\n' "$devino" > "$ldir/.witness" 2>/dev/null; then
        rm -rf "$ldir" 2>/dev/null; eval "$heldvar=0"
        echo "[错误] 无法写入${label}见证记录, 本次安装中止"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    if ! printf '%s\n' "$$" > "$ldir/pid" 2>/dev/null; then
        rm -rf "$ldir" 2>/dev/null; eval "$heldvar=0"
        echo "[错误] 无法写入${label}持有者记录, 本次安装中止"
        eval "exec ${ef}>&-" 2>/dev/null; eval "$fdvar=\"\""
        return 1
    fi
    return 0
}

_install_lock_legacy_mkdir_take() {   # <file> <dir> <heldvar> <label>
    local lfile="$1" ldir="$2" heldvar="$3" label="$4" lrc
    # 旧 mkdir 目录对 L1/L2 一视同仁地创建占位(复审四 P1): 只检查不占位会被旧无-flock
    # 进程在检查之后 mkdir 插入。释放时删除(见 _install_lock_mkdir_release)。
    if [ -e "$lfile" ]; then
        if ! declare -F _install_legacy_flock_active >/dev/null 2>&1; then
            echo "[错误] 无法确认${label} flock 是否空闲(缺少检查助手), 本次安装中止"
            return 1
        fi
        _install_legacy_flock_active "$lfile"; lrc=$?
        case "$lrc" in
            0|2)
                echo "[错误] 检测到${label} flock 仍被占用或无法确认, 本次安装中止"
                return 1
                ;;
        esac
    fi
    # 无论路径当前是否存在, 只取锁一次。若旧持有者在等待期间释放, 这次 mkdir 会成功;
    # 不能再立刻第二次取同一目录, 否则会把自己的 pid 当成竞争者并留下未登记锁。
    _install_lock_mkdir_take "$ldir" "$label" || return 1
    eval "$heldvar=1"
    return 0
}

_install_lock_acquire() {
    local lockdir="" lrc
    lockdir=$(dirname "$INSTALL_LOCK_FILE")
    [ -n "$lockdir" ] || lockdir="/"
    mkdir -p "$lockdir" 2>/dev/null || {
        echo "[错误] 无法创建安装锁目录 $lockdir(权限/只读文件系统?), 安装中止"
        return 1
    }
    # ---- 首选: flock(内核持有, 进程退出即释放, 无陈旧锁/无接管竞态) ----
    if command -v flock >/dev/null 2>&1; then
        # **动态分配 fd, 不要写死 9**: `lib/00-common.sh` 的 `_with_config_lock` 用固定 fd 9
        # 占 config 主锁(锁根下 `config.lock`) —— 写死 9 会在同一进程里互相踩掉
        # 对方的锁(fd 被重新赋值即释放原锁), 表现为"锁莫名失效"。`{var}` 形式由 shell
        # 保证分配一个空闲 fd。
        # **组重定向是硬约束(0.18.3)**: `exec` 的无命令形态会把重定向持久化到当前 shell ——
        # 裸写法 `exec {fd}>>file 2>/dev/null` 会让 fd 2 从此指向 /dev/null, 又被末尾
        # `exec "$INSTALL_BIN"` 带进菜单: `read -rp` 的提示符与全部 _info/_error 一并消失,
        # 用户看到"菜单出现但没有 `请选择:`"(这才是该症状的根因; 菜单侧的 stdin 改接见
        # `_menu_require_tty`)。
        { exec {INSTALL_LOCK_FD}>>"$INSTALL_LOCK_FILE"; } 2>/dev/null || {
            INSTALL_LOCK_FD=""
            echo "[错误] 无法打开安装锁文件 $INSTALL_LOCK_FILE(磁盘空间/权限?)"; return 1; }
        if flock -n "$INSTALL_LOCK_FD" 2>/dev/null; then
            INSTALL_LOCK_HELD=1
            printf '%s\n' "$$" >&"$INSTALL_LOCK_FD" 2>/dev/null || true   # 仅供诊断, 权威在 fd
            if ! _install_primary_marker_take; then
                _install_lock_release
                return 1
            fi
            # **(P1, 复审) 先扫已删除部署树上的旧进程**: L2 旧锁文件在部署树内, 旧版卸载执行
            # `rm -rf "$DEPLOY_DIR"` 后路径消失, 但旧进程的 fd/flock 仍在(已删除 inode) ——
            # "路径不存在" **不能** 解释成"没有旧版进程"。该扫描必须在 `mkdir -p "$DEPLOY_DIR"`
            # **之前**做, 否则会为已删除树重新造出一个像样的路径, 两边随后完全看不见彼此。
            # L2 路径存在时改用见证/身份复核(helper 内), 无需扫描。
            if [ ! -e "$INSTALL_LEGACY_LOCK_FILE" ] && [ ! -e "$INSTALL_LEGACY_LOCK_DIR" ]; then
                if _install_legacy_deleted_tree_active "$DEPLOY_DIR"; then
                    echo "[错误] 检测到旧版进程仍持有已删除部署树的文件, 本次安装中止"
                    echo "       请等旧版 install/卸载退出后重试"
                    _install_lock_release
                    return 1
                fi
            fi
            if ! mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
                echo "[错误] 无法创建部署目录 $DEPLOY_DIR, 安装中止"
                _install_lock_release
                return 1
            fi
            # 旧版锁协调(仅对**已存在**的旧路径): L1(0.17.13/0.18.0)、L2(<=0.17.11)。
            # 不存在就跳过; helper **绝不新建树外锁对象**(否则协调动作本身又污染 /opt)。
            if [ -e "$INSTALL_LEGACY1_LOCK_FILE" ] || [ -e "$INSTALL_LEGACY1_LOCK_DIR" ]; then
                _install_lock_legacy_flock_take "$INSTALL_LEGACY1_LOCK_FILE" "$INSTALL_LEGACY1_LOCK_DIR" \
                    INSTALL_LEGACY1_LOCK_FD INSTALL_LEGACY1_LOCK_DIR_HELD "旧版L1安装锁" || {
                    _install_lock_release
                    return 1
                }
            fi
            if [ -e "$INSTALL_LEGACY_LOCK_FILE" ] || [ -e "$INSTALL_LEGACY_LOCK_DIR" ]; then
                _install_lock_legacy_flock_take "$INSTALL_LEGACY_LOCK_FILE" "$INSTALL_LEGACY_LOCK_DIR" \
                    INSTALL_LEGACY_LOCK_FD INSTALL_LEGACY_LOCK_DIR_HELD "旧版安装锁" || {
                    _install_lock_release
                    return 1
                }
            fi
            return 0
        fi
        eval "exec ${INSTALL_LOCK_FD}>&-" 2>/dev/null
        INSTALL_LOCK_FD=""
        echo "[错误] 另一个安装正在运行(或上一次安装的残留锁尚未释放 —— 它会在持有它的子进程"
        echo "       退出后释放, 通常数十秒; 启用 retry 时可能更久)。本次中止以免两棵树互相覆盖"
        return 1
    fi
    # ---- 退路: mkdir-only(无 flock 的裁剪版 busybox), **永不自动接管** ----
    # 主锁取到**之后**才创建部署目录: 旧版锁路径就在该目录内, 必须等目录可写再取第二把。
    _install_lock_mkdir_take "$INSTALL_LOCK_DIR" "安装锁" || return 1
    INSTALL_LOCK_HELD=1
    if ! declare -F _install_legacy_flock_active >/dev/null 2>&1; then
        echo "[错误] 无法确认安装 flock 主锁是否空闲(缺少 /proc 检查助手), 安装中止"
        _install_lock_release
        return 1
    fi
    _install_legacy_flock_active "$INSTALL_LOCK_FILE"; lrc=$?
    case "$lrc" in
        0|2)
            echo "[错误] 安装 flock 主锁被占用或无法确认, 安装中止"
            _install_lock_release
            return 1
            ;;
    esac
    # (P1) 同 flock 分支: L2 路径不存在 ⇒ 先扫已删除部署树, 再创建部署目录。
    if [ ! -e "$INSTALL_LEGACY_LOCK_FILE" ] && [ ! -e "$INSTALL_LEGACY_LOCK_DIR" ]; then
        if _install_legacy_deleted_tree_active "$DEPLOY_DIR"; then
            echo "[错误] 检测到旧版进程仍持有已删除部署树的文件, 本次安装中止"
            echo "       请等旧版 install/卸载退出后重试"
            _install_lock_release
            return 1
        fi
    fi
    if ! mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
        echo "[错误] 无法创建部署目录 $DEPLOY_DIR, 安装中止"
        _install_lock_release
        return 1
    fi
    # 旧版锁协调(仅对**已存在**的旧路径; 无 flock 时按"另一种后端可能存活"检查 + mkdir 封存)。
    # 树外(如 /opt/.xray-deploy.*)只检查不创建(见 helper), 避免协调动作本身污染 /opt。
    if [ -e "$INSTALL_LEGACY1_LOCK_FILE" ] || [ -e "$INSTALL_LEGACY1_LOCK_DIR" ]; then
        _install_lock_legacy_mkdir_take "$INSTALL_LEGACY1_LOCK_FILE" "$INSTALL_LEGACY1_LOCK_DIR" \
            INSTALL_LEGACY1_LOCK_DIR_HELD "旧版L1安装锁" || {
            _install_lock_release
            return 1
        }
    fi
    if [ -e "$INSTALL_LEGACY_LOCK_FILE" ] || [ -e "$INSTALL_LEGACY_LOCK_DIR" ]; then
        _install_lock_legacy_mkdir_take "$INSTALL_LEGACY_LOCK_FILE" "$INSTALL_LEGACY_LOCK_DIR" \
            INSTALL_LEGACY_LOCK_DIR_HELD "旧版安装锁" || {
            _install_lock_release
            return 1
        }
    fi
    return 0
}

_install_lock_release() {
    [ "${INSTALL_LOCK_HELD:-0}" = "1" ] || return 0
    local rc=0
    # 删除旧版 mkdir 见证时必须仍持有配对的 flock 文件锁; 否则新 flock 持有者可在
    # marker 尚在时进入, 随后被本进程误删见证, 让旧 mkdir writer 与它并发。
    if [ "${INSTALL_LEGACY1_LOCK_DIR_HELD:-0}" = "1" ]; then
        _install_lock_mkdir_release "$INSTALL_LEGACY1_LOCK_DIR"
        INSTALL_LEGACY1_LOCK_DIR_HELD=0
    fi
    if [ "${INSTALL_LEGACY_LOCK_DIR_HELD:-0}" = "1" ]; then
        _install_lock_mkdir_release "$INSTALL_LEGACY_LOCK_DIR"
        INSTALL_LEGACY_LOCK_DIR_HELD=0
    fi
    if [ -n "${INSTALL_LEGACY1_LOCK_FD:-}" ]; then
        flock -u "$INSTALL_LEGACY1_LOCK_FD" 2>/dev/null
        eval "exec ${INSTALL_LEGACY1_LOCK_FD}>&-" 2>/dev/null
        INSTALL_LEGACY1_LOCK_FD=""
    fi
    if [ -n "${INSTALL_LEGACY_LOCK_FD:-}" ]; then
        flock -u "$INSTALL_LEGACY_LOCK_FD" 2>/dev/null
        eval "exec ${INSTALL_LEGACY_LOCK_FD}>&-" 2>/dev/null
        INSTALL_LEGACY_LOCK_FD=""
    fi
    if [ "${INSTALL_PRIMARY_MARKER_HELD:-0}" = "1" ]; then
        _install_primary_marker_release || rc=1
    fi
    if [ -n "${INSTALL_LOCK_FD:-}" ]; then
        # flock 路径: 释放由 fd 承担。**不删锁文件** —— 删了会让"路径不存在"与"仍有进程
        # 持有 fd"并存, 造成诊断混乱; 文件留着无副作用, 下次 `exec {var}>>` 复用它。
        flock -u "$INSTALL_LOCK_FD" 2>/dev/null
        eval "exec ${INSTALL_LOCK_FD}>&-" 2>/dev/null
        INSTALL_LOCK_FD=""
    else
        # mkdir 路径: 归属校验后才删 —— 绝不删别人的锁。
        _install_lock_mkdir_release "$INSTALL_LOCK_DIR"
    fi
    INSTALL_LOCK_HELD=0
    return "$rc"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
IS_UPDATE=0
NO_START=0
ALLOW_LOCAL=0
for arg in "$@"; do
    case "$arg" in
        --update)   IS_UPDATE=1; NO_START=1 ;;
        --no-start) NO_START=1 ;;
        --local)    ALLOW_LOCAL=1 ;;   # 仅首次安装有意义; 与 --update 组合在下面显式拒绝
        *)
            # 未知参数必须显式拒绝: 旧实现静默忽略, `--updat` 这类笔误会**执行一次完整
            # 首次安装**(覆盖文件并拉起菜单), 用户以为只是拼错了个开关。
            echo "[错误] 未知参数: $arg"
            echo "       可用: --update | --no-start | --local"
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 参数互斥校验。**必须放在 update 分支之前** —— 那个分支会 download_all 后直接 exit 0,
# 放在它后面等于死代码(实测: `install.sh --update --local` 仍会完整走网络安装且不报错)。
# --update 走"从 GitHub 重下全部文件"的路径, 本地源对它毫无意义; 静默忽略 --local 会让
# 用户以为在用本地源。
# ---------------------------------------------------------------------------
if [ "$IS_UPDATE" -eq 1 ] && [ "$ALLOW_LOCAL" -eq 1 ]; then
    echo "[错误] --update 与 --local 不能同时使用(--update 从网络重下全部文件)"
    echo "       本地源请直接运行: bash install.sh [--no-start]"
    exit 2
fi

# ---------------------------------------------------------------------------
# 锁根与主锁路径。**放在参数校验之后**: `_install_lock_root` 会真正尝试创建 /var/lock
# (退 /run/lock), 而拼错的开关/互斥冲突的开关不该产生任何副作用。
# flock 用的**文件**与 mkdir 退路用的**目录**必须是两个不同路径: 旧版本(以及本版本的
# mkdir 退路)在 `.install.lock` 上放的是**目录**, 而 `exec 9>>` 需要的是文件 —— 复用同一
# 路径会让升级后的第一次安装直接报 "Is a directory" 而**完全无法运行**(实测)。故在锁根下
# 分别用 `install.lock/`(目录)与 `install.lock.fd`(文件)。
# ---------------------------------------------------------------------------
INSTALL_LOCK_ROOT="$(_install_lock_root)"
INSTALL_LOCK_DIR="${INSTALL_LOCK_ROOT}/install.lock"
INSTALL_LOCK_FILE="${INSTALL_LOCK_ROOT}/install.lock.fd"

# ---------------------------------------------------------------------------
# 获取安装锁。位置刻意选在**参数互斥校验之后**(拼错开关不该创建 $DEPLOY_DIR 与锁, 那条路径
# 本应无副作用)且**在 _install_cleanup_stale 之前** —— 清理本身会改动 $DEPLOY_DIR, 放在锁外
# 就重新打开了 D1 那条数据丢失窗口。两个安装分支都从这里往下走, 故只获取一次, 不在分支里各写
# 一份(项目反模式: 同一条件在各调用点各自解释)。
#
# 释放有两条路, **两条都需要**:
#   · `trap ... EXIT` 覆盖所有 `exit N` 分支与 SIGINT/SIGTERM/SIGHUP(实测均触发);
#   · `exec "$INSTALL_BIN"` 之前**显式释放** —— 实测 EXIT trap **不跨 exec 触发**
#     (exec 替换进程映像, bash 没机会跑 trap), 只靠 trap 会让锁泄漏。
# **trap 必须在 acquire 之前安装**(2026-09-22 七轮复审 D3): 旧顺序在"acquire 成功、trap 尚未
# 安装"之间留了一个信号窗口, 此时锁已落盘却无人释放, 而进程继续走到 `exec`, PID 存活 ⇒
# 下一次安装判"另一个安装正在运行"并白等(实测 13s)。`_install_lock_release` 在
# `INSTALL_LOCK_HELD != 1` 时本就 no-op, 故先装 trap 对"acquire 失败"完全安全。
# SIGKILL 两条都覆盖不到 => flock 路径由内核自动释放兜住; mkdir 退路则提示人工清理。
# ---------------------------------------------------------------------------
trap '_install_lock_release' EXIT
trap '_install_abort_signal 130' INT
trap '_install_abort_signal 143' TERM HUP
if ! _install_lock_acquire; then
    exit 1
fi

# Recover any prior publication interrupted after its complete rollback snapshot was created.
if ! _install_recover_interrupted; then
    exit 1
fi

# 清理 SIGKILL 残留的回滚目录(进程被强杀时回滚代码没机会执行, 备份会一直堆积)。
# 放在两个安装分支之前, 使 update 与首次安装都受益。**必须在锁内**执行。
_install_cleanup_stale

# ---------------------------------------------------------------------------
# 更新模式: 强制下载覆盖所有文件
# ---------------------------------------------------------------------------
if [ "$IS_UPDATE" -eq 1 ]; then
    echo "[信息] 正在更新 xray-deploy..."
    mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    if download_all; then
        _install_xd_link || exit 1
        # xray 命令 symlink（检测已有安装不覆盖）
        if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
            ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray
        fi
        # 变量名不能叫 local_ver 之外还带 local 前缀 —— 这里在函数外, 旧写法的
        # \`local local_ver=...\` 会让 bash 打印 "local: can only be used in a function"
        # 到 stderr(不影响功能, 但用户会看到一行莫名其妙的报错)。
        inst_ver=$(cat "$DEPLOY_DIR/VERSION" 2>/dev/null || echo "?")
        echo "[成功] 更新完成 (版本 ${inst_ver})"
    else
        echo "[警告] 部分文件下载失败, 请检查网络后重试"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 首次安装
# ---------------------------------------------------------------------------
echo "[信息] 正在安装 xray-deploy..."
mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"

# 本地开发模式: 需要**显式 --local**(或从 git 工作树运行)才信任同目录的源码。
# 旧实现仅凭"同目录存在 xray-deploy.sh"就拷贝并最终以 root 身份 source 这些文件 ——
# 在不可信工作目录里执行安装脚本(例如 cd 到别人的仓库)会静默安装任意本地 shell 代码。
# 保留"无参数直接 bash install.sh"的开发便利: 有 .git 标记即视为可信工作树。
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LOCAL_TRUSTED=0
[ "$ALLOW_LOCAL" -eq 1 ] && LOCAL_TRUSTED=1
# -e 而非 -d: git worktree/submodule 里的 .git 是一个**文件**(内含 gitdir: 指针),
# 用 -d 会让合法的工作树检出被判为不可信, 静默回落到网络安装。
[ -e "${LOCAL_DIR}/.git" ] && LOCAL_TRUSTED=1
if [ -f "${LOCAL_DIR}/xray-deploy.sh" ] && [ "$LOCAL_TRUSTED" -eq 1 ]; then
    echo "[信息] 检测到本地源, 从本地拷贝"
    # 2026-09-12 三审(M4): 拷贝失败(磁盘满/权限)必须中止 —— 原写法全部 2>/dev/null 吞掉,
    # lib/模板拷贝失败仍报"安装完成", 用户执行 xd 时才会以"source 失败"的形式暴露。
    # 2026-09-21: 本地路径也走逐文件原子落地(tmp→mv), 与远程路径同一口径 ——
    # 目录级 cp 中途失败会留下"一半新一半旧"的 lib/, 主脚本启动时才以 source 失败暴露。
    # 2026-09-21 五轮复审(P1): 与远程路径同样升级为"备份 → 落地 → 复核 → 失败整体回滚"
    # (见 _install_backup 上方说明), 保证本地安装也不留混合版本。
    #
    # 源清单预检放在备份之前: 本地源缺文件时目标目录一个字节都不该动(备份阶段无意义)。
    if [ ! -d "${LOCAL_DIR}/lib" ]; then
        echo "[错误] 本地源缺少 lib/ 目录, 安装中止"; exit 1
    fi
    # 校验**实际拷到哪些模块**: 旧实现只检查 cp 成功, 一个残缺的 lib/(缺几个模块)照样
    # 报"安装完成", 部署目录随即处于缺模块状态, 运行期才以 source 失败暴露。
    local_missing=""
    for m in $LIB_MODULES; do
        [ -f "${LOCAL_DIR}/lib/${m}.sh" ] || local_missing="${local_missing} ${m}.sh"
    done
    if [ -n "$local_missing" ]; then
        echo "[错误] 本地源 lib/ 缺少模块:${local_missing}"; exit 1
    fi
    if [ ! -d "${LOCAL_DIR}/templates" ]; then
        echo "[错误] 本地源缺少 templates/ 目录, 安装中止"; exit 1
    fi
    tpl_missing=""
    for t in $TPL_NAMES; do
        [ -f "${LOCAL_DIR}/templates/${t}.server.jsonc" ] || tpl_missing="${tpl_missing} ${t}.server.jsonc"
    done
    if [ -n "$tpl_missing" ]; then
        echo "[错误] 本地源 templates/ 缺少:${tpl_missing}"; exit 1
    fi
    # VERSION 与 VERSION 之外的清单同口径(**2026-09-22 open-code-review #05**)。
    # 旧写法在拷贝阶段打一句"[警告] 本地源缺少 VERSION, 更新检查将显示未知版本"然后**继续装**,
    # 而该说法有两个错: (1) `_verify_installed` 根本**不检查** VERSION(它只校验 LIB_MODULES /
    # TPL_NAMES / 主脚本), 所以"照装不误"成立; (2) 但部署目录里**上一版的 VERSION 会原样留着**
    # ⇒ 更新检查永远拿旧版本号跟远端比, 结论是"已是最新"而实际装的是新代码 —— 比"显示未知"
    # 危险得多。实测(部署目录预置 0.99.0, 本地源无 VERSION): 安装报成功, VERSION 仍是 0.99.0。
    # 远程路径把 VERSION 下载失败计入 `fail` 并中止(`fail>0` 分支), 本地路径不该对同一文件
    # 放宽 —— 预检统一拒绝, 且**在备份之前**, 目标目录一个字节都不动。
    if [ ! -s "${LOCAL_DIR}/VERSION" ]; then
        echo "[错误] 本地源缺少 VERSION(或为空), 安装中止"
        echo "       更新检查以它为本地真相源, 缺失会让部署目录保留旧版本号"
        exit 1
    fi

    # 与远程路径同口径: **不得**在备份前无条件 `rm -rf "$ROLLBACK_DIR"`(见 download_all
    # 同处的说明)。.KEEP 判定在 `_install_backup` 内部, 返回 2 = 恢复目录被标记占用。
    _bk_rc=0
    _install_backup || _bk_rc=$?
    if [ "$_bk_rc" -eq 2 ]; then
        exit 1
    fi
    if [ "$_bk_rc" -ne 0 ]; then
        rm -rf "$ROLLBACK_DIR" 2>/dev/null
        echo "[错误] 备份现有安装失败(磁盘空间/权限?), 未改动任何文件"; exit 1
    fi
    : > "$(_install_txn_marker)" 2>/dev/null || {
        rm -rf "$ROLLBACK_DIR" 2>/dev/null
        echo "[错误] 无法写入安装事务标记, 未改动任何文件"; exit 1
    }
    # 与远程路径逐字同口径: 标记先落盘, 掉电后恢复程序才认得出"落地已开始"(见远程侧说明)。
    _install_fsync_or_warn "$(_install_txn_marker)"
    _install_fsync_or_warn "$ROLLBACK_DIR"
    local_ok=1
    _install_file "${LOCAL_DIR}/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh" || local_ok=0
    # 与远程路径逐字同口径: 执行位设置失败必须走回滚(远程侧是 `chmod +x ... || copy_ok=0`)。
    # 旧写法 `2>/dev/null || true` 会让"主脚本落地了但不可执行"照样报"安装完成" ——
    # 用户执行 xd 时看到的是许可错误(open-code-review #02/#04; 顺手与本处 #05 同批修)。
    chmod +x "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null || local_ok=0
    # 预检已保证 `${LOCAL_DIR}/VERSION` 存在且非空, 这里不再有 else 分支(#05)。
    _install_file "${LOCAL_DIR}/VERSION" "$DEPLOY_DIR/VERSION" || local_ok=0
    for m in $LIB_MODULES; do
        _install_file "${LOCAL_DIR}/lib/${m}.sh" "$INSTALL_LIB_DIR/${m}.sh" || local_ok=0
    done
    for t in $TPL_NAMES; do
        _install_file "${LOCAL_DIR}/templates/${t}.server.jsonc" "$INSTALL_TPL_DIR/${t}.server.jsonc" || local_ok=0
    done
    if [ "$local_ok" -ne 1 ] || ! _verify_installed; then
        echo "[错误] 本地源落地/复核失败, 正在回滚到更新前状态..."
        # 与远程路径同口径: 回滚失败保留备份目录(唯一恢复源), 成功才清理。
        if _install_rollback; then
            _install_finish_transaction || {
                echo "[错误] 回滚完成, 但事务标记无法清除; 保留备份目录: $ROLLBACK_DIR"
                exit 1
            }
        else
            echo "[错误] 回滚未完全成功, 已保留备份目录: $ROLLBACK_DIR"
            echo "       请人工从该目录恢复, 或重跑 install.sh --update"
        fi
        exit 1
    fi
    _install_finish_transaction || {
        echo "[错误] 本地文件已复核, 但事务标记无法清除; 保留备份目录: $ROLLBACK_DIR"
        exit 1
    }
else
    # 用户**显式**要求本地安装却没有本地源时, 必须硬失败而不是静默拉网络 ——
    # 那正是"以为在用本地源、实际在装网络版"的误导(与上面的 --update/--local 互斥同一动机)。
    if [ "$ALLOW_LOCAL" -eq 1 ] && [ ! -f "${LOCAL_DIR}/xray-deploy.sh" ]; then
        echo "[错误] 已指定 --local, 但本地源不可用(缺少 ${LOCAL_DIR}/xray-deploy.sh)"
        echo "       请在有源码的目录运行, 或去掉 --local 从网络安装"
        exit 1
    fi
    if [ -f "${LOCAL_DIR}/xray-deploy.sh" ] && [ "$LOCAL_TRUSTED" -eq 0 ]; then
        echo "[信息] 检测到本地源但未受信任(无 .git 且未指定 --local), 改为从网络安装"
        echo "       如确实要从本地安装, 请加 --local"
    fi
    if ! download_all; then
        echo "[错误] 关键文件下载失败, 安装中止"
        exit 1
    fi
fi

# 快捷命令与 xray 符号链接。**每一项都必须检查结果**(open-code-review #02):
# 这里是"安装完成"之前的最后两步, 旧写法不看出错就报 `[成功] 安装完成`, 而 `/usr/local/bin/xd`
# 可能根本没建出来 —— 用户拿到一条不存在的命令。注意 xd 的链接是**指向部署目录的符号链接**,
# 它丢了不影响 `bash install.sh` 重跑(重跑即重建), 故这里报错即可, 不回滚已落地的文件。
_install_xd_link || exit 1
# xray 命令 symlink（检测已有安装不覆盖）
if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
    ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray || \
        echo "[警告] 创建 /usr/local/bin/xray 符号链接失败(不影响本部署, 可稍后手动补)"
fi

echo "[成功] xray-deploy 安装完成"
echo "[信息] 输入 ${CMD_NAME} 唤出主菜单"

if [ "$NO_START" -eq 0 ]; then
    # **必须显式释放**: 实测 EXIT trap 不跨 `exec` 触发(exec 替换进程映像, bash 没机会跑 trap),
    # 只靠 trap 会让锁泄漏到下一次安装(而持有者 PID 就是本进程, 只要本进程还在就会被判"存活")。
    _install_lock_release
    exec "$INSTALL_BIN"
fi
