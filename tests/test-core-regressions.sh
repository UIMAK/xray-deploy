#!/usr/bin/env bash
# Offline scratch coverage of real core/Geo journals and direct service control.
# 桩函数与 fixture 变量由 source 进来的生产模块间接消费。
# shellcheck disable=SC2329,SC2034
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
    # 必须确认替换真的发生: 否则 eval 的是未修改函数, 会以真实系统路径运行却仍报 PASS。
    journal_ok_definition=$(declare -f _xray_core_journal_ok)
    [ -n "$journal_ok_definition" ] || { printf 'SUMMARY pass=0 fail=1 (declare -f failed)\n'; exit 1; }
    case "$journal_ok_definition" in
        *'/etc/systemd/system/xray.service'*)
            eval "${journal_ok_definition//\/etc\/systemd\/system\/xray.service/\$UNIT}" ;;
        *) printf 'SUMMARY pass=0 fail=1 (unit path literal changed; fix the rewrite)\n'; exit 1 ;;
    esac
    verified_restart_definition=$(declare -f _restart_xray_verified)
    # _xray_stop_and_verify 在下方被整体桩掉(事务用例直接改 RUNNING), 停止判据用例
    # 需要真实实现, 所以先留存定义, 用例内再 eval 回来。
    stop_and_verify_definition=$(declare -f _xray_stop_and_verify)
    [ -n "$stop_and_verify_definition" ] ||
        { printf 'SUMMARY pass=0 fail=1 (declare -f _xray_stop_and_verify failed)\n'; exit 1; }
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
        # messages/service-actions 跨用例累积: 每个 fixture 重建, 使断言只反映当前用例。
        : > "$TMP/messages"
        : > "$TMP/service-actions"
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
        [ "$RESTARTS" -eq 0 ] && settled &&
        # masked/已停服务成功路径不得触碰 systemctl start/restart, 也不得记录错误。
        ! grep -Eq 'start|restart' "$TMP/service-actions" 2>/dev/null &&
        [ ! -s "$TMP/messages" ]
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
    # 旧 binary 快照与 live binary 同时消失 = 当前无核心, 事务必须继续回滚而不是永久阻塞。
    core_binary_lost() {
        fixture core-binary-lost
        RUNNING=true
        local stage="$BIN_DIR/.xray-dl.recovery-lost" j
        _xray_core_journal_write 26.9.8 stable v26.10.17 preview "$stage" core || return 1
        j="$STATE_DIR/coretxn.json"
        _xray_core_snapshot_binary "$j" && _xray_service_snapshot && _xref_snapshot_geo_dats "$j" || return 1
        mkdir -p "$stage" || return 1
        _xray_core_journal_phase snapshotted && _xray_core_journal_phase replacing || return 1
        command rm -f "$XRAY_BIN" "$XRAY_BIN.bak"
        _xray_core_txn_recover_locked || return 1
        [ ! -e "$XRAY_BIN" ] && [ "$RUNNING" = false ] && [ "$RESTARTS" -eq 0 ] && old_dat && settled
    }
    # live binary 仍在而快照丢失来源不明: 保持阻塞, journal 与现场全部保留。
    core_binary_backup_lost() {
        fixture core-bak-lost
        RUNNING=true
        local stage="$BIN_DIR/.xray-dl.backup-lost" j
        _xray_core_journal_write 26.9.8 stable v26.10.17 preview "$stage" core || return 1
        j="$STATE_DIR/coretxn.json"
        _xray_core_snapshot_binary "$j" && _xray_service_snapshot && _xref_snapshot_geo_dats "$j" || return 1
        mkdir -p "$stage" || return 1
        _xray_core_journal_phase snapshotted && _xray_core_journal_phase replacing || return 1
        command rm -f "$XRAY_BIN.bak"
        _xray_core_txn_recover_locked && return 1
        [ "$(jq -r .phase "$j")" = replacing ] &&
            [ "$(cat "$XRAY_BIN")" = binary-original ] && [ "$RESTARTS" -eq 0 ]
    }
    # Geo full 账本同一规则: 两个 binary 都不存在时不阻塞 dat 回滚。
    legacy_geo_binary_lost() {
        fixture legacy-geo-binary-lost
        command rm "$UNIT"; printf 'old-service' > "$UNIT"
        _xray_core_journal_write 26.9.8 stable geo-update stable '' geo || return 1
        local j="$STATE_DIR/coretxn.json" stage
        _meta_update "$j" 'del(.snapshot_scope)' || return 1
        stage=$(jq -r .staging_dir "$j")
        mkdir "$stage" && cp "$DEPLOY_DIR/download/"*.dat "$stage/" || return 1
        _xray_service_snapshot && _xray_core_snapshot_binary "$j" && _xref_snapshot_geo_dats "$j" || return 1
        _xray_core_journal_phase snapshotted && _xray_core_journal_phase replacing || return 1
        command mv -f "$stage/geoip.dat" "$ASSET_DIR/geoip.dat"
        command rm -f "$XRAY_BIN" "$XRAY_BIN.bak"
        _xray_core_txn_recover_locked || return 1
        old_dat && settled && [ ! -e "$XRAY_BIN" ]
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
        # 替换必须命中, 否则 eval 未修改函数会 rm -f 宿主真实的 /run/xray.pid。
        _manage_xray_definition=$(declare -f _manage_xray)
        [ -n "$_manage_xray_definition" ] || return 1
        case "$_manage_xray_definition" in
            *'/run/xray.pid'*) ;;
            *) return 1 ;;
        esac
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
    # 停止判据用例: 用真实 _xray_stop_and_verify(上方被桩掉) + openrc 后端,
    # 按两台故障机的实测返回码复刻形状; rc-service/_proc_any_named/sleep 全部桩掉。
    stop_missing_openrc_service() {
        fixture stop-missing-openrc
        INIT_SYSTEM=openrc
        command rm -f "$UNIT"
        rc-service() { return 1; }
        _proc_any_named() { return 1; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        local rc=$?
        unset -f rc-service _proc_any_named sleep
        [ "$rc" -eq 0 ]
    }
    stop_openrc_stop_rc_nonzero() {
        fixture stop-openrc-rc-nonzero
        INIT_SYSTEM=openrc
        command rm -f "$UNIT"; printf '#!/sbin/openrc-run\n' > "$UNIT"
        rc-service() {
            case "${2:-}" in status) printf ' * status: stopped\n'; return 3 ;; esac
            return 1
        }
        _proc_any_named() { return 1; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        local rc=$?
        unset -f rc-service _proc_any_named sleep
        [ "$rc" -eq 0 ]
    }
    stop_openrc_running_blocks() {
        fixture stop-openrc-running
        INIT_SYSTEM=openrc
        command rm -f "$UNIT"; printf '#!/sbin/openrc-run\n' > "$UNIT"
        rc-service() {
            case "${2:-}" in status) printf ' * status: started\n'; return 0 ;; esac
            return 0
        }
        _proc_any_named() { return 0; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        local rc=$?
        unset -f rc-service _proc_any_named sleep
        [ "$rc" -eq 1 ] &&
            grep -Fq '无法确认 Xray 已停止' "$TMP/messages" &&
            grep -Fq 'rc-service xray status' "$TMP/messages"
    }
    # status 文本是独立证据: 进程扫描没命中也不能把 started 判成已停止。
    stop_openrc_status_started_no_scan() {
        fixture stop-openrc-started-noscan
        INIT_SYSTEM=openrc
        command rm -f "$UNIT"; printf '#!/sbin/openrc-run\n' > "$UNIT"
        rc-service() {
            case "${2:-}" in status) printf ' * status: started\n'; return 0 ;; esac
            return 0
        }
        _proc_any_named() { return 1; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        local rc=$?
        unset -f rc-service _proc_any_named sleep
        [ "$rc" -eq 1 ] && grep -Fq 'rc-service xray status' "$TMP/messages"
    }
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
    check 'openrc stop treats a missing init script as already stopped' stop_missing_openrc_service
    check 'openrc stop rc=1 with stopped status and no process confirms stop' stop_openrc_stop_rc_nonzero
    check 'openrc stop blocks on started status while an owned process runs' stop_openrc_running_blocks
    check 'openrc stopped state keeps started status authoritative over process scan' stop_openrc_status_started_no_scan
    # Low1: journal 字段读取失败不能被进程替换吞掉。
    journal_rc_probe() {
        local saved rc1=0 rc2=0
        saved=$(declare -f _xray_core_journal_fields)
        _xray_core_journal_fields() { printf '%s\n' '' '' '' '' '' core full; return 1; }
        local j="$TMP/rc-journal.json"
        printf '%s\n' '{"phase":"prepared","service_masked":false}' > "$j"
        _xray_core_snapshots_fsync "$j" || rc1=$?
        _xray_core_cleanup_sources "$j" || rc2=$?
        eval "$saved"
        [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ]
    }
    check 'journal field read failure aborts snapshot and cleanup' journal_rc_probe

    # B4: 字段顺序与默认值保持稳定。
    journal_fields_probe() {
        local j="$TMP/field-order.json" fields
        printf '%s\n' '{"binary_backup":"/b","staging_dir":"/s","service_prev":"/sp","geoip_backup":"/gip","geosite_backup":"/gsp","operation":"geo","snapshot_scope":"geo"}' > "$j"
        fields=$(_xray_core_journal_fields "$j") || return 1
        local -a out
        mapfile -t out <<< "$fields"
        [ "${#out[@]}" -eq 7 ] || return 1
        [ "${out[0]}" = /b ] && [ "${out[1]}" = /s ] && [ "${out[2]}" = /sp ] && [ "${out[3]}" = /gip ] && [ "${out[4]}" = /gsp ] && [ "${out[5]}" = geo ] && [ "${out[6]}" = geo ] || return 1
        printf '%s\n' '{"binary_backup":"","staging_dir":"","service_prev":"","geoip_backup":"","geosite_backup":""}' > "$j"
        fields=$(_xray_core_journal_fields "$j") || return 1
        mapfile -t out <<< "$fields"
        [ "${#out[@]}" -eq 7 ] || return 1
        [ "${out[5]}" = core ] && [ "${out[6]}" = full ]
    }
    check 'journal fields keep order and defaults' journal_fields_probe
    check 'core rollback settles as no-core when snapshot and live binary are both gone' core_binary_lost
    check 'core rollback still blocks when only the binary snapshot is gone' core_binary_backup_lost
    check 'legacy Geo rollback settles as no-core when both binaries are gone' legacy_geo_binary_lost

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
