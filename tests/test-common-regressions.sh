#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-common-regressions.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
. "${XRAY_COMMON_TEST_SOURCE:-$ROOT/lib/00-common.sh}"
CONFIG_DIR="$TMP/confs"
BACKUP_DIR="$TMP/backups"
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR/confs.lastbak"
_fsync_path() { :; }
PASS=0 FAIL=0
check() {
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  ok - %s\n' "$name";
    else FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$name"; fi
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
check 'split producer failure preserves all live fragments' producer_failure empty
check 'partial split output is not committed on producer failure' producer_failure partial

invalid_restore() (
    local content="$1" rc
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/live-before"
    printf '%s' "$content" > "$BACKUP_DIR/confs.lastbak/02_log.json"
    _restore_config >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/live-before"
)
check 'empty backup fragment cannot clear the live configuration' invalid_restore ''
empty_object_restore() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    printf '{}' > "$BACKUP_DIR/confs.lastbak/02_log.json"
    _restore_config >/dev/null 2>&1 || return 1
    [ ! -e "$CONFIG_DIR/02_log.json" ]
)
check 'empty object backup remains a valid empty restore fragment' empty_object_restore
check 'invalid JSON backup leaves live bytes untouched' invalid_restore '{broken'
check 'non-object backup is rejected' invalid_restore '[]'
check 'multiple documents in one fragment are rejected' invalid_restore '{"log":{}} {"dns":{}}'

mixed_restore() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/mixed-live"
    printf '{"log":{"loglevel":"warning"}}' > "$BACKUP_DIR/confs.lastbak/02_log.json"
    : > "$BACKUP_DIR/confs.lastbak/04_dns.json"
    ! _restore_config >/dev/null 2>&1 && cmp -s "$CONFIG_DIR/02_log.json" "$TMP/mixed-live"
)
check 'valid fragment plus empty fragment rejects the entire restore' mixed_restore

valid_roundtrip() (
    CONFIG_DIR="$TMP/roundtrip/confs"
    BACKUP_DIR="$TMP/roundtrip/backups"
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR/confs.lastbak"
    _config_write_merged '{"log":{"loglevel":"warning"},"customTop":{"text":"a\nb"},"inbounds":[]}' || return 1
    cp "$CONFIG_DIR"/*.json "$BACKUP_DIR/confs.lastbak/" || return 1
    _config_write_merged '{"log":{"loglevel":"debug"},"dns":{"servers":[]}}' || return 1
    _restore_config >/dev/null 2>&1 || return 1
    _config_jq -e '.log.loglevel == "warning" and .customTop.text == "a\nb" and .inbounds == [] and (has("dns") | not)' >/dev/null
)
check 'valid backup restores normal and unknown fields and removes stale files' valid_roundtrip
printf 'common regressions passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
