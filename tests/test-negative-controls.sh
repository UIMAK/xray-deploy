#!/usr/bin/env bash
# Isolated negative controls: bypass each new rejection in a subshell and prove
# the production assertion then fails. This file never mutates the shared tree.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-negative-controls.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { printf 'negative controls: 0 passed, 1 failed (jq required)\n'; exit 1; }
. "$ROOT/lib/00-common.sh"
. "$ROOT/lib/20-xray-core.sh"
. "$ROOT/lib/50-nodes.sh"
PASS=0 FAIL=0
check() {
    local label="$1"; shift
    if "$@"; then PASS=$((PASS+1)); printf '  ok - %s\n' "$label"
    else FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$label"; fi
}

layout_guard() {
    local dir="$TMP/layout"
    DEPLOY_DIR="$dir" CONFIG_DIR="$dir/confs"
    rm -rf "$dir"; mkdir -p "$CONFIG_DIR"
    printf '%s' '{"inbounds":[]}' > "$dir/config.json"
    ! _config_layout_supported >/dev/null 2>&1
}
check 'unrecognized layout rejection assertion detects current guard' layout_guard
layout_bypass() (
    _config_layout_supported() { return 0; }
    ! layout_guard
)
check 'unrecognized-layout bypass makes the rejection assertion fail' layout_bypass

pid_guard() {
    local file="$TMP/old.pid"
    printf '%s' '4242 123' > "$file"
    ! _xd_pidfile_record "$file" >/dev/null 2>&1
}
check 'invalid pidfile rejection assertion detects strict identity parser' pid_guard
pid_bypass() (
    _xd_pidfile_record() { command cat "$1"; }
    ! pid_guard
)
check 'pidfile parser downgrade makes the rejection assertion fail' pid_bypass

journal_guard() {
    local journal="$TMP/old-journal.json"
    printf '%s' '{"phase":"prepared","operation":"geo","snapshot_scope":"geo","txn_id":"unknown"}' > "$journal"
    ! _xray_core_journal_ok "$journal" >/dev/null 2>&1
}
check 'unknown journal schema rejection assertion detects current schema' journal_guard
journal_bypass() (
    _xray_core_journal_ok() { return 0; }
    ! journal_guard
)
check 'journal schema acceptance makes the rejection assertion fail' journal_bypass

install_defs() {
    sed -n '/^_install_snapshot_rel_ok()/,/^}/p; /^_install_snapshot_read_entries()/,/^}/p' "$ROOT/install.sh"
}
manifest_guard() {
    local dir="$TMP/.install-rollback.1"
    DEPLOY_DIR="$TMP"
    rm -rf "$dir"; mkdir -p "$dir"
    printf '#!/bin/sh\n' > "$dir/xray-deploy.sh"
    printf '1\n' > "$dir/VERSION"
    printf '%s\n' 'xray-install-backup-v2' 'present xray-deploy.sh' 'present VERSION' 'complete 2 123 456' > "$dir/.KEEP"
    ! _install_snapshot_read_entries "$dir" 0 >/dev/null 2>&1
}
check 'invalid manifest rejection assertion detects exact trailer' manifest_guard
manifest_bypass() (
    local defs definition
    defs=$(install_defs) || return 1
    eval "$defs"
    definition=$(declare -f _install_snapshot_read_entries)
    case "$definition" in *'complete)'*) ;; *) return 1 ;; esac
    definition="${definition/complete)/complete*)}"
    eval "$definition"
    ! manifest_guard
)
check 'manifest compatibility makes the rejection assertion fail' manifest_bypass

min_version_guard() {
    local dir="$TMP/min-version"
    rm -rf "$dir"; mkdir -p "$dir"
    _ensure_dirs() { return 0; }
    _info() { :; }
    _error() { printf '%s\n' "$*" >&2; }
    _xray_fetch_tag() { printf '%s\n' v26.4.24; }
    _config_layout_supported() { : > "$dir/layout"; return 0; }
    _xray_stage_release() { : > "$dir/stage"; printf '%s/stage' "$dir"; }
    _with_core_lock() { : > "$dir/lock"; "$@"; }
    _install_or_switch_xray_locked() { : > "$dir/commit"; return 0; }
    _install_or_switch_xray custom v26.4.24 >/dev/null 2>&1 && return 1
    [ ! -e "$dir/layout" ] && [ ! -e "$dir/stage" ] &&
        [ ! -e "$dir/lock" ] && [ ! -e "$dir/commit" ]
}
check 'minimum-version rejection assertion detects pre-staging refusal' min_version_guard
min_version_bypass() (
    _xray_version_at_least() { return 0; }
    ! min_version_guard
)
check 'minimum-version bypass makes the rejection assertion fail' min_version_bypass

# New fail-closed controls: removing required lock or uninstall helpers must reject work.
barrier_rejection_assertion() {
    local dir="$TMP/barrier"
    rm -rf "$dir"; mkdir -p "$dir"
    _error() { printf '%s\n' "$*" >&2; }
    _with_config_write_barrier touch "$dir/out" 2>/dev/null
    [ $? -ne 0 ] && [ ! -e "$dir/out" ]
}
unset -f _with_core_lock
check 'missing core lock rejects config write barrier' barrier_rejection_assertion
barrier_bypass() (
    _with_core_lock() { "$@"; }
    ! barrier_rejection_assertion
)
check 'restoring core lock makes barrier rejection assertion fail' barrier_bypass

uninstall_helper_rejection_assertion() {
    local dir="$TMP/uninstall"
    rm -rf "$dir"; mkdir -p "$dir"
    DEPLOY_DIR="$dir" XRAY_BIN="$dir/xray" CMD_NAME=xd INIT_SYSTEM=direct
    printf 'keep' > "$dir/state"
    _xray_stop_and_verify() { return 0; }
    _error() { printf '%s\n' "$*" >&2; }
    _tip() { :; }; _warn() { :; }; _success() { :; }
    _uninstall_xray_locked >/dev/null 2>&1
    [ $? -ne 0 ] && [ -f "$dir/state" ]
}
unset -f _hy2_cleanup_all_hops _hysteria_cleanup_before_uninstall _logrotate_cleanup
check 'missing uninstall helpers preserve deploy data' uninstall_helper_rejection_assertion
uninstall_bypass() (
    _hy2_cleanup_all_hops() { return 0; }
    _hysteria_cleanup_before_uninstall() { return 0; }
    _logrotate_cleanup() { return 0; }
    _crontab_replace() { return 0; }
    ! uninstall_helper_rejection_assertion
)
check 'restoring uninstall helpers makes preservation assertion fail' uninstall_bypass

printf 'negative controls: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
