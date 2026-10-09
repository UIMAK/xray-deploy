#!/usr/bin/env bash
# Offline scratch coverage of real core/Geo journals and direct service control.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
command -v jq >/dev/null 2>&1 || { printf 'SUMMARY pass=0 fail=1 (jq required)\n'; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-core-regressions.XXXXXX") || exit 1
cleanup() {
    # 直接按 $TMP 的模板前缀判定, 不依赖 pwd -P 相等(软链 TMPDIR 下会漏删)。
    case "$TMP" in
        "${TMPDIR:-/tmp}"/xray-core-regressions.*) rm -rf -- "$TMP" ;;
    esac
}
trap cleanup EXIT
(
    . "$ROOT/lib/00-common.sh"
    . "${CORE_REGRESSIONS_MODULE:-$ROOT/lib/20-xray-core.sh}"
    # Map the allowlisted unit path to scratch while keeping real schema checks.
    journal_ok_definition=$(declare -f _xray_core_journal_ok)
    eval "${journal_ok_definition//\/etc\/systemd\/system\/xray.service/\$UNIT}"
    verified_restart_definition=$(declare -f _restart_xray_verified)
    PASS=0 FAIL=0
    _info() { :; }
    _success() { :; }
    _warn() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _error() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _tip() { :; }
    _fsync_path() { printf '%s\n' "$1" >> "$TMP/fsync"; }
    _xray_current_version() { printf '26.9.8'; }
    _xray_is_running() { [ "$RUNNING" = true ]; }
    _xray_stop_and_verify() { RUNNING=false; }
    _restart_xray_verified() {
        RESTARTS=$((RESTARTS+1))
        [ "$RESTARTS" -ne "$RESTART_FAIL" ] || return 1
        RUNNING=true
    }
    _xray_service_unit_path() { printf '%s' "$UNIT"; }
    systemctl() {
        printf '%s\n' "$*" >> "$TMP/service-actions"
        case "$1" in daemon-reload) return 0 ;; is-enabled) printf 'disabled\n'; return 1 ;; esac
        return 99
    }
    fixture() {
        DEPLOY_DIR="$TMP/$1" BIN_DIR="$TMP/$1/bin" ASSET_DIR="$TMP/$1/assets"
        STATE_DIR="$TMP/$1/state" BACKUP_DIR="$TMP/$1/backups"
        XRAY_BIN="$BIN_DIR/xray" GEO_LOG="$TMP/$1/geo.log" UNIT="$TMP/$1/xray.service"
        INIT_SYSTEM=systemd XRAY_DEPLOY_CORE_LOCK_HELD=1
        RUNNING=false RESTARTS=0 RESTART_FAIL=0
        mkdir -p "$BIN_DIR" "$ASSET_DIR" "$STATE_DIR" "$BACKUP_DIR" "$DEPLOY_DIR/download"
        printf 'binary-original' > "$XRAY_BIN"
        printf 'old-geoip' > "$ASSET_DIR/geoip.dat"
        printf 'old-geosite' > "$ASSET_DIR/geosite.dat"
        printf '26.9.8' > "$STATE_DIR/version"
        printf 'stable' > "$STATE_DIR/channel"
        printf '%2048s' 'new-geoip' > "$DEPLOY_DIR/download/geoip.dat"
        printf '%2048s' 'new-geosite' > "$DEPLOY_DIR/download/geosite.dat"
        ln -s /dev/null "$UNIT"
        : > "$TMP/fsync"
    }
    check() {
        local label="$1"; shift
        if ( "$@" ); then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label"; fi
    }
    old_dat() {
        [ "$(cat "$ASSET_DIR/geoip.dat")" = old-geoip ] &&
        [ "$(cat "$ASSET_DIR/geosite.dat")" = old-geosite ]
    }
    settled() { [ ! -e "$STATE_DIR/coretxn.json" ] && [ ! -e "$STATE_DIR/coretxn.blocked" ]; }
    update() { _xray_core_geo_update_locked "$DEPLOY_DIR/download" test-time 1; }
    masked_success() {
        fixture mask-success
        local inode; inode=$(stat -c '%i' "$UNIT") || return 1
        update || return 1
        [ -L "$UNIT" ] && [ "$(readlink "$UNIT")" = /dev/null ] &&
        [ "$(stat -c '%i' "$UNIT")" = "$inode" ] &&
        cmp -s "$ASSET_DIR/geoip.dat" "$DEPLOY_DIR/download/geoip.dat" &&
        cmp -s "$ASSET_DIR/geosite.dat" "$DEPLOY_DIR/download/geosite.dat" &&
        [ "$RESTARTS" -eq 0 ] && settled
    }
    dat_ownership() {
        fixture dat-ownership
        printf 'foreign-binary-backup' > "$XRAY_BIN.bak"
        _xray_core_journal_write 26.9.8 stable geo-update stable '' geo || return 1
        local j="$STATE_DIR/coretxn.json" stage prev
        stage=$(jq -r .staging_dir "$j") prev=$(jq -r .service_prev "$j")
        printf 'foreign-service' > "$prev"
        mkdir "$stage" && cp "$DEPLOY_DIR/download/"*.dat "$stage/" || return 1
        _xref_snapshot_geo_dats "$j" && _xray_core_journal_phase snapshotted || return 1
        ! grep -Fxq "$XRAY_BIN.bak" "$TMP/fsync" || return 1
        ! grep -Fxq "$prev" "$TMP/fsync" || return 1
        _xray_core_txn_recover_locked || return 1
        [ "$(cat "$XRAY_BIN.bak")" = foreign-binary-backup ] &&
        [ "$(cat "$prev")" = foreign-service ] && old_dat && settled
    }
    second_dat_failure() {
        fixture second-dat
        RUNNING=true
        mv() {
            case "$1:$2:$3" in -f:"$ASSET_DIR"/.xray-geo-txn.*/geosite.dat:"$ASSET_DIR/geosite.dat") return 1 ;; esac
            command mv "$@"
        }
        update && return 1
        unset -f mv
        unset -f mv
        old_dat && [ "$RUNNING" = true ] && [ "$RESTARTS" -eq 0 ] && settled && [ -L "$UNIT" ]
    }
    restart_failure() {
        fixture restart-failure
        RUNNING=true RESTART_FAIL=1
        update && return 1
        old_dat && [ "$RUNNING" = true ] && [ "$RESTARTS" -eq 2 ] && settled && [ -L "$UNIT" ]
    }
    absent_dat_rollback() {
        fixture absent-dat
        command rm "$ASSET_DIR/geosite.dat"
        RUNNING=true RESTART_FAIL=1
        update && return 1
        [ "$(cat "$ASSET_DIR/geoip.dat")" = old-geoip ] &&
            [ ! -e "$ASSET_DIR/geosite.dat" ] && [ "$RUNNING" = true ] && settled
    }
    recovery_retry() {
        fixture recovery-retry
        RUNNING=true RESTART_FAIL=1
        mv() {
            case "$1:$2:$3" in -f:"$ASSET_DIR"/.geosite.dat.restore.*:"$ASSET_DIR/geosite.dat") return 1 ;; esac
            command mv "$@"
        }
        update && return 1
        [ -f "$STATE_DIR/coretxn.json" ] && [ "$RUNNING" = false ] || return 1
        local bak; bak=$(jq -r .geosite_backup "$STATE_DIR/coretxn.json")
        [ "$(cat "$bak")" = old-geosite ] || return 1
        unset -f mv
        _xray_core_txn_recover_locked && old_dat && [ "$RUNNING" = true ] && settled
    }
    legacy_geo() {
        local phase="$1" masked="$2"
        fixture "legacy-$phase-$masked"
        [ "$masked" = true ] || { command rm "$UNIT"; printf 'old-service' > "$UNIT"; }
        _xray_core_journal_write 26.9.8 stable geo-update stable '' geo || return 1
        local j="$STATE_DIR/coretxn.json" stage
        # Stable old-schema fixture; no snapshot_scope existed in old Geo journals.
        _meta_update "$j" 'del(.snapshot_scope)' || return 1
        stage=$(jq -r .staging_dir "$j")
        mkdir "$stage" && cp "$DEPLOY_DIR/download/"*.dat "$stage/" || return 1
        _xray_service_snapshot && _xray_core_snapshot_binary "$j" && _xref_snapshot_geo_dats "$j" || return 1
        _xray_core_journal_phase snapshotted || return 1
        if [ "$phase" = replacing ]; then
            _xray_core_journal_phase replacing || return 1
            command mv -f "$stage/geoip.dat" "$ASSET_DIR/geoip.dat"
        elif [ "$phase" = committed ]; then
            _xray_core_journal_phase replacing || return 1
            command mv -f "$stage/geoip.dat" "$ASSET_DIR/geoip.dat"
            command mv -f "$stage/geosite.dat" "$ASSET_DIR/geosite.dat"
            _xray_core_journal_phase geo_replaced && _xray_core_journal_phase restart_verified &&
                _xray_core_journal_phase committed || return 1
        fi
        _xray_core_txn_recover_locked || return 1
        if [ "$masked" = true ]; then [ -L "$UNIT" ] && [ "$(readlink "$UNIT")" = /dev/null ] || return 1
        else [ "$(cat "$UNIT")" = old-service ] || return 1; fi
        [ "$phase" != replacing ] || old_dat || return 1
        settled && [ "$(cat "$XRAY_BIN")" = binary-original ]
    }
    core_snapshot_guard() {
        fixture core-snapshot
        INIT_SYSTEM=direct
        _xray_service_unit_path() { return 1; }
        local stage="$BIN_DIR/.xray-dl.fixture"
        mkdir "$stage" && printf new-binary > "$stage/xray" || return 1
        _xray_core_journal_write 26.9.8 stable v26.9.9 stable "$stage" || return 1
        local j="$STATE_DIR/coretxn.json"
        _xref_snapshot_geo_dats "$j" || return 1
        _xray_core_journal_phase snapshotted && return 1
        [ "$(jq -r .phase "$j")" = prepared ] || return 1
        _xray_core_snapshot_binary "$j" && _xray_core_journal_phase snapshotted &&
            _xray_core_txn_recover_locked && settled
    }
    corrupt_scope() {
        fixture corrupt-scope
        _xray_core_journal_write 26.9.8 stable geo-update stable '' geo || return 1
        _meta_update "$STATE_DIR/coretxn.json" '.operation="core"' || return 1
        _xray_core_txn_recover_locked && return 1
        [ -f "$STATE_DIR/coretxn.blocked" ] && [ -f "$STATE_DIR/coretxn.json.corrupt" ] && old_dat && [ -L "$UNIT" ]
    }
    direct_failure() (
        local action="$1" kill_rc="$2" owned="$3"
        fixture "direct-$action-$kill_rc-$owned"
        INIT_SYSTEM=direct
        local pidfile="$DEPLOY_DIR/xray.pid"
        printf '4242 123' > "$pidfile"
        # Map only the hardcoded pidfile/comm reads; no real process is signalled.
        _manage_xray_definition=$(declare -f _manage_xray)
        eval "${_manage_xray_definition//\/run\/xray.pid/$pidfile}"
        _xd_pidfile_pid() { printf '4242'; }
        _xd_pidfile_starttime() { printf '123'; }
        _xd_pidfile_identity_ok() { return 0; }
        _proc_exe_is_strict() { [ "$owned" = yes ]; }
        _xd_kill_pid_graceful() { printf 'kill\n' >> "$DEPLOY_DIR/actions"; return "$kill_rc"; }
        _xd_pid_unchanged() { return 0; }
        cat() { if [ "$1" = /proc/4242/comm ]; then printf xray; else command cat "$@"; fi; }
        nohup() { printf 'start\n' >> "$DEPLOY_DIR/actions"; return 1; }
        _xd_pidfile_write() { printf 'write\n' >> "$DEPLOY_DIR/actions"; }
        sleep() { :; }
        if [ "$action" = verified ]; then
            eval "$verified_restart_definition"
            _restart_xray_verified >/dev/null 2>&1 && return 1
        else _manage_xray "$action" >/dev/null 2>&1 && return 1; fi
        [ "$(command cat "$pidfile" 2>/dev/null)" = '4242 123' ] || return 1
        [ "$owned" = yes ] || [ ! -f "$DEPLOY_DIR/actions" ] || return 1
        ! grep -Eq 'start|write' "$DEPLOY_DIR/actions" 2>/dev/null
    )
    check 'masked Geo success keeps original mask inode and stopped runtime' masked_success
    check 'dat snapshot scope preserves unrelated binary/service backups and skips their fsync' dat_ownership
    check 'second dat rename failure restores both dat files and running runtime' second_dat_failure
    check 'Geo restart failure restores both dat files and running runtime' restart_failure
    check 'Geo rollback removes dat absent before the transaction' absent_dat_rollback
    check 'failed dat recovery retains journal/source for a successful retry' recovery_retry
    check 'legacy snapshotted Geo journal restores moved mask' legacy_geo snapshotted true
    check 'legacy committed Geo journal restores moved mask' legacy_geo committed true
    check 'legacy replacing Geo journal restores dat without rewriting binary/service' legacy_geo replacing false
    check 'core snapshot barrier still requires binary backup' core_snapshot_guard
    check 'legacy Geo regular service snapshot remains compatible' legacy_geo snapshotted false
    check 'core journal cannot weaken recovery to dat-only snapshots' corrupt_scope
    check 'direct stop kill failure preserves pidfile' direct_failure stop 1 yes
    check 'direct restart kill failure never starts' direct_failure restart 1 yes
    check 'direct stop refuses unknown executable ownership' direct_failure stop 0 no
    check 'direct stop confirms exit even when kill reports success' direct_failure stop 0 yes
    check 'verified direct restart rejects unchanged old running instance' direct_failure verified 1 yes
    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
