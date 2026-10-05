#!/bin/bash
# install.sh — 安装/更新入口；--no-start 仅安装不进菜单，--update 强制远程更新。

set -u

# 上游 base 只定义一次，镜像/fork 用 XRAY_DEPLOY_RAW 覆盖。
REMOTE_BASE_DEFAULT="https://raw.githubusercontent.com/UIMAK/xray-deploy/main"
REMOTE_BASE="${XRAY_DEPLOY_RAW:-$REMOTE_BASE_DEFAULT}"

CMD_NAME="xd"
INSTALL_BIN="/usr/local/bin/${CMD_NAME}"
DEPLOY_DIR="/opt/xray-deploy"
INSTALL_LIB_DIR="$DEPLOY_DIR/lib"
INSTALL_TPL_DIR="$DEPLOY_DIR/templates"

# 本次整版本备份目录；失败保留恢复源，见 _install_backup/_install_rollback。
ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.$$"

# LIB_MODULES 与运行入口一致，TPL_NAMES 列全模板；避免安装与加载清单漂移。
LIB_MODULES="00-common 10-system 20-xray-core 30-geo 40-cloudflared 45-logrotate 50-nodes 51-reality-pq 55-hysteria 90-menu"
TPL_NAMES="vless-tcp-reality-vision-tunnel vless-xhttp-reality-tunnel vless-tcp-reality-vision-direct vless-xhttp-reality-direct tunnel vless-enc vless-xhttp-cdn vless-ws-cdn shadowsocks hysteria2"

# root 检测
[ "$(id -u)" -ne 0 ] && { echo "[错误] 请以 root 运行"; exit 1; }

# 部署目录含私钥/密码/token, 默认 077 使运行期生成的敏感文件仅 root 可读
umask 077

# 确保 Bash（Alpine 默认 ash）
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

# 基础依赖
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

# 下载：curl 优先，wget 兜底并重试。
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

# 单文件以同目录 tmp → mv 落地；_verify_installed 逐项复核非空，防止半截文件。
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

# 整版本事务：备份 → 逐文件落地 → 复核 → 失败整体回滚。
# _install_relpaths 统一清单；回滚恢复旧文件并删除本次新建文件，不完整时保留源。
_install_relpaths() {
    local m t
    printf '%s\n' 'xray-deploy.sh' 'VERSION'
    for m in $LIB_MODULES; do printf 'lib/%s.sh\n' "$m"; done
    for t in $TPL_NAMES; do printf 'templates/%s.server.jsonc\n' "$t"; done
}

# 快照内容比对与定向落盘分工不同：前者证明字节完整，后者保证 .KEEP 提交顺序。
_install_backup_identical() {   # <src> <dst>; 逐字节一致返回 0
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$1" "$2" 2>/dev/null
        return $?
    fi
    # cmp 缺失(裁剪版 busybox)时退回长度比较: 强于"只看存在", 但发现不了等长损坏。
    [ "$(wc -c < "$1" 2>/dev/null)" = "$(wc -c < "$2" 2>/dev/null)" ]
}

# 只用定向 sync；裸 sync 无法证明目标落盘，见 _reset_fsync_required。
_install_fsync() {   # <path>
    [ -e "$1" ] || return 0
    sync "$1" 2>/dev/null && return 0
    sync -f "$1" 2>/dev/null && return 0
    return 1
}

# 定向落盘能力缺失只告警一次；内容已比对，不因此拒绝安装。
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
    # .KEEP 目录不可复用；返回 2 表示恢复源占用，返回 1 表示备份失败。
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
    # 未标记目录可能含中断备份的旧副本；重建以免与 absent 记录冲突。
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
            # 当前缺失的目标须移除旧副本，避免恢复时与 absent 记录矛盾。
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
    # 先刷备份、清单及目录，再提交 .KEEP 并刷目录；标记只声明完整快照。
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
    # 清理顺序：.KEEP 保留 → live PID 保留 → 非数字后缀保留 → 删除无标记死进程残留。
    # kill -0 仍是锁失效时的保护；PID 复用只会多留备份，不会丢恢复源。
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
        # 逐项显示受保护路径，不建议 glob 删除，以免销毁唯一恢复源。
        echo "[提示] 发现 ${protected} 个受保护的恢复目录(上次安装失败或被强杀时保留的更新前文件):"
        printf '         %s\n' "${prot_list[@]}"
        echo "       这些目录**不可自动清理**, 其中保存着更新前的原始文件;"
        echo "       确认已不再需要后, 请按上面的完整路径逐个手动删除(不要用通配符)。"
    fi
}

# download_all：下载完整 staging 后才发布。
download_all() {
    local ok=0 fail=0
    # mktemp 失败立即中止；空 stage 会把目标拼接到文件系统根。
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

    # 全量取件后执行整版本事务，见 _install_backup。
    mkdir -p "$DEPLOY_DIR" "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    # 不在备份前删除 ROLLBACK_DIR；.KEEP 占用由 _install_backup 统一判定。
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
    # 落地标记先持久化，_install_recover_interrupted 才能识别中断发布。
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
    # 落地/复核失败整体回滚；_install_rollback 报告未恢复路径。
    if [ "$copy_ok" -ne 1 ] || ! _verify_installed; then
        echo "[错误] 文件落地/复核失败, 正在回滚到更新前状态..."
        # 回滚失败保留唯一恢复源；只有成功才清理。
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

# 链接创建后验证 xd 实际目标；ln 成功也可能只是写进已有目录。
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

# 安装锁串行化整版本事务：flock 优先，mkdir 退路永不自动接管。
# 锁根固定 /var/lock/xray-deploy（失败退 /run/lock），不读环境覆盖；子进程可能延续 flock。
_install_lock_root() {
    # 实际创建锁根而非只看权限；调用须在参数校验之后，失败不回落 /opt。
    if mkdir -p /var/lock/xray-deploy 2>/dev/null; then printf '%s' "/var/lock/xray-deploy"; return 0; fi
    if mkdir -p /run/lock/xray-deploy 2>/dev/null; then printf '%s' "/run/lock/xray-deploy"; return 0; fi
    printf '%s' "/var/lock/xray-deploy"
}
INSTALL_LOCK_PARENT="${DEPLOY_DIR%/*}"
INSTALL_LOCK_NAME="${DEPLOY_DIR##*/}"
[ -n "$INSTALL_LOCK_PARENT" ] || INSTALL_LOCK_PARENT="/"
# 参数校验前只初始化无副作用常量。
# 主锁后协调已存在的 L1（部署父目录）/L2（部署树内）旧锁；无法确认则拒绝。
# 不新建旧 .fd；旧进程晚启动/重建旧路径仍是协调边界，见 _install_legacy_lock_name。
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
        # 所有零值 PID 均为未知；kill -0 会把进程组误当持有者存活。
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

# mkdir 锁只删本进程拥有的目录；残留拒绝并交人工处理。
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
        # 陈旧或未知锁立即拒绝，保留目录并给出人工处置路径。
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

# flock/mkdir 共用目录 marker 交叉协调；仅排他 flock + 同 inode 见证可自愈。
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

# 旧锁 FD 必须仍对应路径 inode；路径被卸载重建或不可读时 fail-closed。
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

# 旧锁 FD 还须与先前见证同 inode，防止存在 → 删除 → 重建绕过路径复核。
_install_legacy_lock_identity_ok() {   # <fd> <见证fd>; 0 = 同一 inode
    local fd="$1" wfd="$2"
    [ -n "$fd" ] && [ -n "$wfd" ] || return 1
    [ "/proc/self/fd/$fd" -ef "/proc/self/fd/$wfd" ]
}

# 路径的 dev:ino 标识(mkdir 标记的自愈判定)。取不到输出空; 调用方必须 fail-closed。
_install_lock_devino() { stat -c '%d:%i' "$1" 2>/dev/null; }

# L2 缺失时先扫描已删除部署文件的持有者，再重建路径；无法确认即拒绝。
# 此扫描不能证明无 FD 的旧 mkdir 持有者已退出。
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
        # 扫描中关闭的 FD 跳过；上面的 find 快路径承担删除树检查。
        target=$(readlink "$p" 2>/dev/null) || continue
        case "$target" in
            "$prefix"*" (deleted)") return 0 ;;
        esac
    done
    return 1
}

# 旧 flock 活跃判据：0=被打开，1=确认无持有者，2=未知；mkdir 退路遇未知拒绝。
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
        # 逐 FD 读取失败返回 2，不猜无持有者；与 _xray_legacy_flock_active 同契约。
        target=$(readlink "$p" 2>/dev/null) || return 2
        [ "$target" = "$want" ] && return 0
    done
    return 1
}

# 仅协调已存在旧路径，不创建旧 .fd。
# 同路径 flock + inode 复核 + L1/L2 mkdir 见证，防旧后端在检查后插入；失败由调用方释放主锁。
_install_lock_legacy_flock_take() {   # <file> <dir> <fdvar> <heldvar> <label>
    local lfile="$1" ldir="$2" fdvar="$3" heldvar="$4" label="$5"
    local witness="" devino="" ef=""
    # L1/L2 均占位并在释放时移除；缺旧 .fd 时仍不得新建。
    if [ ! -e "$lfile" ]; then
        # 缺旧 .fd 不补建；已有旧 mkdir 目录直接拒绝。
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
    # L1/L2 占位防旧 mkdir 后端插入，见 _install_lock_mkdir_release。
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
    # 每路径只取锁一次，防止重复获取把自己的 PID 当竞争者并漏登记。
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
    # flock 优先：内核仲裁，最后一个继承 fd 关闭才释放。
    if command -v flock >/dev/null 2>&1; then
        # 动态 FD 避免与 config 锁 fd 9 冲突；exec 其他重定向放组外，避免永久污染 stderr。
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
            # L2 缺失先查删除树持有者再 mkdir；已有路径用见证/身份复核。
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
            # 仅协调已存在的旧路径，见 _install_legacy_lock_name。
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
    # mkdir 退路永不自动接管；主锁后才创建部署树和协调旧锁。
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
    # L2 缺失时先扫描删除树，再建部署目录，顺序与 flock 分支相同。
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
    # 无 flock 时同样协调已有旧锁：检查旧 flock，再占位 mkdir；不补建旧 .fd。
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
    # 持配对 flock 时先删旧 mkdir 见证，防释放交错误删新持有者 marker。
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
        # 关闭 FD 释放 flock，不删除锁文件，避免已打开 inode 与新路径分裂。
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

# 参数解析
IS_UPDATE=0
NO_START=0
ALLOW_LOCAL=0
for arg in "$@"; do
    case "$arg" in
        --update)   IS_UPDATE=1; NO_START=1 ;;
        --no-start) NO_START=1 ;;
        --local)    ALLOW_LOCAL=1 ;;   # 仅首次安装有意义; 与 --update 组合在下面显式拒绝
        *)
            # 未知参数拒绝，避免拼错更新开关意外触发首次安装。
            echo "[错误] 未知参数: $arg"
            echo "       可用: --update | --no-start | --local"
            exit 2
            ;;
    esac
done

# --update 与 --local 互斥须在更新分支前判定，避免本地请求静默走网络。
if [ "$IS_UPDATE" -eq 1 ] && [ "$ALLOW_LOCAL" -eq 1 ]; then
    echo "[错误] --update 与 --local 不能同时使用(--update 从网络重下全部文件)"
    echo "       本地源请直接运行: bash install.sh [--no-start]"
    exit 2
fi

# 参数校验后创建锁根；flock 文件与 mkdir 目录使用不同路径。
INSTALL_LOCK_ROOT="$(_install_lock_root)"
INSTALL_LOCK_DIR="${INSTALL_LOCK_ROOT}/install.lock"
INSTALL_LOCK_FILE="${INSTALL_LOCK_ROOT}/install.lock.fd"

# 参数校验后、清理前取安装锁；取锁前装 trap，exec 菜单前显式释放。
# EXIT trap 不跨 exec；mkdir 的 SIGKILL 残留只交人工处理。
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

# 两分支均在锁内清理无保护的中断备份，见 _install_cleanup_stale。
_install_cleanup_stale

# 更新模式：强制远程下载全部文件。
if [ "$IS_UPDATE" -eq 1 ]; then
    echo "[信息] 正在更新 xray-deploy..."
    mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    if download_all; then
        _install_xd_link || exit 1
        # xray 命令 symlink（检测已有安装不覆盖）
        if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
            ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray
        fi
        # 顶层作用域不使用 local。
        inst_ver=$(cat "$DEPLOY_DIR/VERSION" 2>/dev/null || echo "?")
        echo "[成功] 更新完成 (版本 ${inst_ver})"
    else
        echo "[警告] 部分文件下载失败, 请检查网络后重试"
        exit 1
    fi
    exit 0
fi

# 首次安装
echo "[信息] 正在安装 xray-deploy..."
mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"

# 本地源码须显式 --local 或 git 工作树才采用，避免自动信任任意同目录文件。
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LOCAL_TRUSTED=0
[ "$ALLOW_LOCAL" -eq 1 ] && LOCAL_TRUSTED=1
# .git 可为 worktree/submodule 指针文件，使用 -e 而不是 -d。
[ -e "${LOCAL_DIR}/.git" ] && LOCAL_TRUSTED=1
if [ -f "${LOCAL_DIR}/xray-deploy.sh" ] && [ "$LOCAL_TRUSTED" -eq 1 ]; then
    echo "[信息] 检测到本地源, 从本地拷贝"
    # 本地也走整版本事务；先预检清单，再备份，不完整源不得改目标。
    if [ ! -d "${LOCAL_DIR}/lib" ]; then
        echo "[错误] 本地源缺少 lib/ 目录, 安装中止"; exit 1
    fi
    # 预检实际模块清单，避免复制成功却缺加载模块。
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
    # VERSION 必须非空，且在备份前拒绝缺失，避免旧版本号残留。
    if [ ! -s "${LOCAL_DIR}/VERSION" ]; then
        echo "[错误] 本地源缺少 VERSION(或为空), 安装中止"
        echo "       更新检查以它为本地真相源, 缺失会让部署目录保留旧版本号"
        exit 1
    fi

    # .KEEP 占用由 _install_backup 判定；不在调用前删恢复源。
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
    # 发布标记先持久化，见 download_all。
    _install_fsync_or_warn "$(_install_txn_marker)"
    _install_fsync_or_warn "$ROLLBACK_DIR"
    local_ok=1
    _install_file "${LOCAL_DIR}/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh" || local_ok=0
    # 执行位设置失败纳入整版本回滚，不能谎报可运行。
    chmod +x "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null || local_ok=0
    # VERSION 已通过源清单预检。
    _install_file "${LOCAL_DIR}/VERSION" "$DEPLOY_DIR/VERSION" || local_ok=0
    for m in $LIB_MODULES; do
        _install_file "${LOCAL_DIR}/lib/${m}.sh" "$INSTALL_LIB_DIR/${m}.sh" || local_ok=0
    done
    for t in $TPL_NAMES; do
        _install_file "${LOCAL_DIR}/templates/${t}.server.jsonc" "$INSTALL_TPL_DIR/${t}.server.jsonc" || local_ok=0
    done
    if [ "$local_ok" -ne 1 ] || ! _verify_installed; then
        echo "[错误] 本地源落地/复核失败, 正在回滚到更新前状态..."
        # 回滚失败保留唯一恢复源，见 download_all。
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
    # 显式 --local 缺源须失败，不静默改用远程源。
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

# 快捷链接结果必须验证；失败报错但保留已发布文件，重跑可修复。
_install_xd_link || exit 1
# xray 命令 symlink（检测已有安装不覆盖）
if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
    ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray || \
        echo "[警告] 创建 /usr/local/bin/xray 符号链接失败(不影响本部署, 可稍后手动补)"
fi

echo "[成功] xray-deploy 安装完成"
echo "[信息] 输入 ${CMD_NAME} 唤出主菜单"

if [ "$NO_START" -eq 0 ]; then
    # exec 不触发 EXIT trap，必须显式释放安装锁。
    _install_lock_release
    exec "$INSTALL_BIN"
fi
