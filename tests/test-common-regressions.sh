#!/usr/bin/env bash
# 桩函数由 source 进来的生产模块间接调用。
# shellcheck disable=SC2329
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-common-regressions.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
# 依赖缺失必须显式失败: 否则 jq 桩退路会让断言以错误原因"通过"。
command -v jq >/dev/null 2>&1 || { echo 'FAIL - jq is required' >&2; exit 1; }
. "${XRAY_COMMON_TEST_SOURCE:-$ROOT/lib/00-common.sh}"
_fsync_path() { :; }
PASS=0 FAIL=0
check() {
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  ok - %s\n' "$name";
    else FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$name"; fi
}

# 每个用例独立 CONFIG_DIR/BACKUP_DIR, 不共享可变树, 断言与执行顺序解耦。
# 用 $1 作目录名, 每次重建 confs 与 confs.lastbak。
setup_case() {
    local name="$1"
    CONFIG_DIR="$TMP/$name/confs"
    BACKUP_DIR="$TMP/$name/backups"
    rm -rf "${TMP:?}/$name"
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR/confs.lastbak"
}

producer_failure() (
    local mode="$1" rc
    printf '{"log":{"loglevel":"warning"}}' > "$CONFIG_DIR/02_log.json"
    printf '{"inbounds":[]}' > "$CONFIG_DIR/07_inbounds.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/original-log"
    cp "$CONFIG_DIR/07_inbounds.json" "$TMP/original-inbounds"
    jq() {
        if [ "${1:-}" = -j ]; then
            if [ "$mode" = partial ]; then
                printf 'log\0{"loglevel":"error"}\0'
            fi
            return 1
        fi
        command jq "$@"
    }
    _config_write_merged '{"log":{"loglevel":"error"}}' >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/original-log" &&
        cmp -s "$CONFIG_DIR/07_inbounds.json" "$TMP/original-inbounds"
)
setup_case producer_empty
check 'split producer failure preserves all live fragments' producer_failure empty
setup_case producer_partial
check 'partial split output is not committed on producer failure' producer_failure partial

# 真正的"部分提交"窗口: 第一个片段已写, 第二个片段写入失败, 必须整组回滚/保持可预测状态。
partial_commit() (
    printf '{"log":{"loglevel":"warning"}}' > "$CONFIG_DIR/02_log.json"
    printf '{"inbounds":[]}' > "$CONFIG_DIR/07_inbounds.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/pc-log"
    cp "$CONFIG_DIR/07_inbounds.json" "$TMP/pc-inbounds"
    local n=0
    _atomic_write_json() {
        n=$((n+1))
        [ "$n" -ge 2 ] && return 1
        command mkdir -p "$(dirname "$1")" && printf '%s' "$2" > "$1"
    }
    _config_write_merged '{"log":{"loglevel":"error"},"inbounds":[{"tag":"x"}]}' >/dev/null 2>&1
    rc=$?
    # 失败时不得报告成功; 且必须证明失败发生在首个片段已落盘之后(n=2),
    # 否则断言可能因"写入前就失败"而假通过, 没覆盖真正的半提交窗口。
    # 契约: 失败由调用方清理, 这里核对首片段已变为新值、次片段保持原字节。
    [ "$rc" -ne 0 ] && [ "$n" -eq 2 ] &&
        jq -e '.log.loglevel == "error"' "$CONFIG_DIR/02_log.json" >/dev/null 2>&1 &&
        cmp -s "$CONFIG_DIR/07_inbounds.json" "$TMP/pc-inbounds"
)
setup_case partial_commit
check 'partial commit failure is reported as failure' partial_commit

invalid_restore() (
    local content="$1" rc
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/live-before"
    printf '%s' "$content" > "$BACKUP_DIR/confs.lastbak/02_log.json"
    _restore_config >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/live-before"
)
setup_case invalid_empty
check 'empty backup fragment cannot clear the live configuration' invalid_restore ''
setup_case invalid_json
check 'invalid JSON backup leaves live bytes untouched' invalid_restore '{broken'
setup_case invalid_array
check 'non-object backup is rejected' invalid_restore '[]'
setup_case invalid_multi
check 'multiple documents in one fragment are rejected' invalid_restore '{"log":{}} {"dns":{}}'

# 缺失/空 lastbak 必须 fail-closed, 不清空 live 配置。
missing_backup_dir() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/mb-live"
    rm -rf "$BACKUP_DIR/confs.lastbak"
    _restore_config >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/mb-live"
)
setup_case missing_backup
check 'missing lastbak dir fails closed and keeps live bytes' missing_backup_dir
empty_backup_dir() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/eb-live"
    _restore_config >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/eb-live"
)
setup_case empty_backup
check 'zero-fragment lastbak fails closed and keeps live bytes' empty_backup_dir

empty_object_restore() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    printf '{}' > "$BACKUP_DIR/confs.lastbak/02_log.json"
    _restore_config >/dev/null 2>&1 || return 1
    [ ! -e "$CONFIG_DIR/02_log.json" ]
)
setup_case empty_object
check 'empty object backup remains a valid empty restore fragment' empty_object_restore

mixed_restore() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/mixed-live"
    printf '{"log":{"loglevel":"warning"}}' > "$BACKUP_DIR/confs.lastbak/02_log.json"
    : > "$BACKUP_DIR/confs.lastbak/04_dns.json"
    ! _restore_config >/dev/null 2>&1 && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/mixed-live"
)
setup_case mixed
check 'valid fragment plus empty fragment rejects the entire restore' mixed_restore

valid_roundtrip() (
    setup_case roundtrip
    _config_write_merged '{"log":{"loglevel":"warning"},"customTop":{"text":"a\nb"},"inbounds":[]}' || return 1
    cp "$CONFIG_DIR"/*.json "$BACKUP_DIR/confs.lastbak/" || return 1
    _config_write_merged '{"log":{"loglevel":"debug"},"dns":{"servers":[]}}' || return 1
    _restore_config >/dev/null 2>&1 || return 1
    _config_jq -e '.log.loglevel == "warning" and .customTop.text == "a\nb" and .inbounds == [] and (has("dns") | not)' >/dev/null
)
check 'valid backup restores normal and unknown fields and removes stale files' valid_roundtrip

# 保留裁剪是破坏性路径(rm -rf 整个快照目录): 必须证明只裁最旧的, 且不误伤 lastbak/无关同级条目。
# mtime 用 POSIX touch -t 拉开(POSIX 规定, busybox 同样支持), 否则同秒创建的目录在 ls -1dt 里次序不定。
backup_retention() (
    local i d n=0
    printf '{"log":{"loglevel":"warning"}}' > "$CONFIG_DIR/02_log.json"
    for ((i = 1; i <= 13; i++)); do
        d="$BACKUP_DIR/confs.bak.202001$(printf '%02d' "$i")-000000"
        mkdir -p "$d" || return 1
        printf 'sentinel-%s' "$i" > "$d/sentinel"
        touch -t "202001$(printf '%02d' "$i")0000" "$d" || return 1
    done
    # 无关同级条目不在 confs.bak.* 内, 裁剪不得波及。
    printf 'keep' > "$BACKUP_DIR/unrelated.txt"
    _backup_config >/dev/null 2>&1 || return 1
    # 本次新增 1 份 + 原有 13 份 = 14, 裁剪后必须恰好 10 份目录。
    for d in "$BACKUP_DIR"/confs.bak.*; do
        [ -d "$d" ] || continue
        n=$((n + 1))
    done
    [ "$n" -eq 10 ] || return 1
    # 裁掉的必须是 4 份最旧的; 最新一份目录内容完整(不是空壳)。
    for ((i = 1; i <= 4; i++)); do
        [ ! -e "$BACKUP_DIR/confs.bak.202001$(printf '%02d' "$i")-000000" ] || return 1
    done
    [ -s "$BACKUP_DIR/confs.bak.20200113-000000/sentinel" ] &&
        [ -f "$BACKUP_DIR/unrelated.txt" ] &&
        [ -s "$BACKUP_DIR/confs.lastbak/02_log.json" ]
)
setup_case backup_retention
check 'backup retention keeps the newest 10 snapshots and spares siblings' backup_retention
printf 'common regressions passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
