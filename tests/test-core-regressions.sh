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
    . "$ROOT/lib/50-nodes.sh"
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
    _ensure_dirs() { return 0; }
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
    service_templates() {
        local version systemd_unit openrc_unit
        local systemd_definition openrc_definition
        DEPLOY_DIR="$TMP/service-templates"
        BIN_DIR="$DEPLOY_DIR/bin" ASSET_DIR="$DEPLOY_DIR/assets" CONFIG_DIR="$DEPLOY_DIR/confs"
        XRAY_BIN="$BIN_DIR/xray"
        # 模板函数把 service 路径写死在函数体内; 重写函数定义到 scratch,
        # 避免仅替换 cat 时真实重定向已在调用前创建 /etc 文件。
        systemd_definition=$(declare -f _create_xray_systemd_service)
        openrc_definition=$(declare -f _create_xray_openrc_service)
        case "$systemd_definition" in
            *'/etc/systemd/system/xray.service'*) ;;
            *) return 1 ;;
        esac
        case "$openrc_definition" in
            *'/etc/init.d/xray'*) ;;
            *) return 1 ;;
        esac
        INIT_SYSTEM=systemd
        chmod() { return 0; }
        systemctl() { return 0; }
        rc-update() { return 0; }
        for version in 26.7.10 26.7.11; do
            systemd_unit="$TMP/systemd-service-$version"
            openrc_unit="$TMP/openrc-service-$version"
            eval "${systemd_definition//\/etc\/systemd\/system\/xray.service/\$systemd_unit}"
            eval "${openrc_definition//\/etc\/init.d\/xray/\$openrc_unit}"
            _xray_current_version() { printf '%s' "$version"; }
            INIT_SYSTEM=systemd
            _create_xray_systemd_service || return 1
            INIT_SYSTEM=openrc
            _create_xray_openrc_service || return 1
            grep -Fq 'NoNewPrivileges=true' "$systemd_unit" || return 1
            grep -Fq 'RestartPreventExitStatus=23' "$systemd_unit" || return 1
            grep -Fq "ExecStart=$XRAY_BIN run -confdir $CONFIG_DIR" "$systemd_unit" || return 1
            ! grep -Eq '^(User|Group|CapabilityBoundingSet|AmbientCapabilities)=' "$systemd_unit" || return 1
            grep -Fq 'respawn_max=20' "$openrc_unit" || return 1
            grep -Fq 'respawn_period=600' "$openrc_unit" || return 1
            grep -Fq 'no_new_privs=yes' "$openrc_unit" || return 1
            ! grep -Eq '^(capabilities|command_user|extra_commands)=' "$openrc_unit" || return 1
            ! grep -Eq '^(checkconfig|start_pre)\(\)' "$openrc_unit" || return 1
            grep -Fq "command=\"$XRAY_BIN\"" "$openrc_unit" || return 1
            grep -Fq "command_args=\"run -confdir $CONFIG_DIR\"" "$openrc_unit" || return 1
            if [ "$version" = 26.7.10 ]; then
                grep -Fq "Environment=XRAY_LOCATION_ASSET=$ASSET_DIR" "$systemd_unit" || return 1
                grep -Fq "supervise_daemon_args=\"--env XRAY_LOCATION_ASSET=$ASSET_DIR\"" "$openrc_unit" || return 1
            else
                ! grep -Fq 'XRAY_LOCATION_ASSET=' "$systemd_unit" || return 1
                ! grep -Fq 'XRAY_LOCATION_ASSET=' "$openrc_unit" || return 1
            fi
        done
        _xray_current_version() { printf '26.9.8'; }
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
    unknown_geo_schema_rejected() {
        local phase="$1" masked="$2"
        fixture "old-$phase-$masked"
        _xray_core_journal_write 26.9.8 stable geo-update stable '' geo || return 1
        local journal="$STATE_DIR/coretxn.json" stage
        stage=$(jq -r .staging_dir "$journal")
        mkdir "$stage" || return 1
        printf preserved > "$stage/evidence"
        _meta_update "$journal" '.phase = $phase | del(.snapshot_scope)' --arg phase "$phase" || return 1
        cp "$journal" "$DEPLOY_DIR/journal-before"
        _xray_core_txn_recover_locked && return 1
        cmp -s "${journal}.corrupt" "$DEPLOY_DIR/journal-before" && [ -e "$STATE_DIR/coretxn.blocked" ] &&
            [ "$(cat "$stage/evidence")" = preserved ] && old_dat &&
            [ "$(cat "$XRAY_BIN")" = binary-original ] && [ "$RESTARTS" -eq 0 ]
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
            [ "$(cat "$XRAY_BIN")" = binary-original ] &&
            [ "$RUNNING" = false ] && [ "$RESTARTS" -eq 0 ] && [ ! -e "$XRAY_BIN.bak" ]
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
    # starting/stopping 同样是"未停止": 进程可能还没拉起, 不能靠进程扫描兜底。
    stop_openrc_transition_blocks() {
        local st="$1" expect="$2" rc=0
        fixture "stop-openrc-$st"
        INIT_SYSTEM=openrc
        command rm -f "$UNIT"; printf '#!/sbin/openrc-run\n' > "$UNIT"
        rc-service() {
            case "${2:-}" in status) printf ' * status: %s\n' "$st"; return 0 ;; esac
            return 0
        }
        _proc_any_named() { return 1; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        rc=$?
        unset -f rc-service _proc_any_named sleep
        [ "$rc" -eq "$expect" ]
    }
    # systemd 的 state=2 是"查询不可用", 不是"已停止": 修复前会退回 _xray_is_running
    # (systemctl 失败时它也返回 1), 于是把观察不到当成已停止, 破坏性路径继续执行。
    stop_systemd_query_unavailable_blocks() {
        fixture stop-systemd-query
        INIT_SYSTEM=systemd
        _manage_xray() { return 0; }
        systemctl() { return 1; }
        _proc_any_named() { return 1; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        local rc=$?
        unset -f _manage_xray systemctl _proc_any_named sleep
        [ "$rc" -eq 1 ] &&
            grep -Fq '无法确认 Xray 已停止' "$TMP/messages" &&
            grep -Fq 'systemctl status xray' "$TMP/messages"
    }
    # direct 后端没有服务查询, state=2 是常态: pidfile/进程回退必须保留。
    stop_direct_unobservable_falls_back() {
        fixture stop-direct-fallback
        INIT_SYSTEM=direct
        _manage_xray() { return 0; }
        _xray_is_running() { return 1; }
        sleep() { :; }
        eval "$stop_and_verify_definition"
        _xray_stop_and_verify
        local rc=$?
        unset -f _manage_xray _xray_is_running sleep
        [ "$rc" -eq 0 ]
    }
    check 'masked Geo success keeps original mask inode and stopped runtime' masked_success
    check 'dat snapshot scope preserves unrelated binary/service backups and skips their fsync' dat_ownership
    check 'second dat rename failure restores both dat files and running runtime' second_dat_failure
    check 'Geo restart failure restores both dat files and running runtime' restart_failure
    check 'Geo rollback removes dat absent before the transaction' absent_dat_rollback
    check 'failed dat recovery retains journal/source for a successful retry' recovery_retry
    check 'unknown Geo schema rejected with evidence' unknown_geo_schema_rejected snapshotted true
    check 'core snapshot barrier still requires binary backup' core_snapshot_guard
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
    check 'openrc starting status blocks even before a process exists' stop_openrc_transition_blocks starting 1
    check 'openrc stopping status is not taken as stopped' stop_openrc_transition_blocks stopping 1
    check 'systemd query failure never confirms stop' stop_systemd_query_unavailable_blocks
    check 'direct unobservable state falls back to pidfile/process liveness' stop_direct_unobservable_falls_back
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
    check 'service templates adopt standard hardening without changing runtime ownership' service_templates

    # B4: 字段顺序与默认值保持稳定。
    journal_fields_probe() {
        local j="$TMP/field-order.json" fields
        printf '%s\n' '{"binary_backup":"/b","staging_dir":"/s","service_prev":"/sp","geoip_backup":"/gip","geosite_backup":"/gsp","operation":"geo","snapshot_scope":"geo"}' > "$j"
        fields=$(_xray_core_journal_fields "$j") || return 1
        local -a out
        mapfile -t out <<< "$fields"
        [ "${#out[@]}" -eq 7 ] || return 1
        [ "${out[0]}" = /b ] && [ "${out[1]}" = /s ] && [ "${out[2]}" = /sp ] && [ "${out[3]}" = /gip ] && [ "${out[4]}" = /gsp ] && [ "${out[5]}" = geo ] && [ "${out[6]}" = geo ] || return 1
        printf '%s\n' '{"binary_backup":"","staging_dir":"","service_prev":"","geoip_backup":"","geosite_backup":"","operation":"core"}' > "$j"
        fields=$(_xray_core_journal_fields "$j") || return 1
        mapfile -t out <<< "$fields"
        [ "${#out[@]}" -eq 7 ] || return 1
        [ "${out[5]}" = core ] && [ "${out[6]}" = full ]
    }
    check 'journal fields keep order and defaults' journal_fields_probe
    check 'core rollback settles as no-core when snapshot and live binary are both gone' core_binary_lost
    check 'core rollback still blocks when only the binary snapshot is gone' core_binary_backup_lost

    min_version_rejection() (
        local channel="$1" tag="$2" dir="$TMP/min-version-$1"
        rm -rf "$dir"; mkdir -p "$dir"
        eval "_xray_fetch_tag() { printf '%s' \"$tag\" > \"$dir/fetch\"; printf '%s\\n' \"$tag\"; }"
        eval "$(declare -f _xray_version_at_least)"
        _config_layout_supported() { : > "$dir/layout"; return 0; }
        _xray_stage_release() { : > "$dir/stage"; return 0; }
        _with_core_lock() { : > "$dir/lock"; "$@"; }
        _install_or_switch_xray_locked() { : > "$dir/commit"; return 0; }
        _manage_xray() { : > "$dir/service"; return 0; }
        _error() { printf '%s\n' "$*" >&2; }
        local fetch_called=0
        [ -e "$dir/fetch" ] && fetch_called=1
        local out rc=0
        [ "$fetch_called" -eq 0 ] || return 1
        if [ "$channel" = custom ]; then
            out=$(_install_or_switch_xray custom "$tag" 2>&1) || rc=$?
            [ ! -e "$dir/fetch" ] || return 1
        else
            out=$(_install_or_switch_xray "$channel" 2>&1) || rc=$?
            [ "$(cat "$dir/fetch" 2>/dev/null)" = "$tag" ] || { printf 'fetch=%s expected=%s\n' "$(cat "$dir/fetch" 2>/dev/null)" "$tag" >&2; return 1; }
        fi
        [ "$rc" -eq 1 ] || { printf 'rc=%s out=%s\n' "$rc" "$out" >&2; return 1; }
        case "$out" in
            *"仅支持 Xray-core v26.4.25 及以上, 已拒绝: $tag"*) ;;
            *) printf 'unexpected=%s\n' "$out" >&2; return 1 ;;
        esac
        if [ -e "$dir/layout" ] || [ -e "$dir/stage" ] || [ -e "$dir/lock" ] || [ -e "$dir/commit" ] || [ -e "$dir/service" ]; then
            printf 'unexpected side effect in %s\n' "$dir" >&2
            return 1
        fi
    )

    invalid_pidfile_rejected() {
        local dir="$TMP/direct-old-pidfile" pidfile="$TMP/direct-old.pid"
        local definition start_rc=0 stop_rc=0 status
        rm -rf "$dir"; mkdir -p "$dir/confs"
        printf '{"version":{"min":"26.4.25","max":""}}' > "$dir/confs/15_version.json"
        DEPLOY_DIR="$dir" CONFIG_DIR="$dir/confs" STATE_DIR="$dir/state" INIT_SYSTEM=direct
        XRAY_DEPLOY_CORE_LOCK_HELD=1
        # 用存活 PID 模拟"两列记录 + 进程仍在": 必须拒绝接管, 不能清记录后重启。
        printf '%s 123' "$$" > "$pidfile"
        cp "$pidfile" "$TMP/direct-old.pid.before"
        definition=$(declare -f _manage_xray)
        case "$definition" in
            *'/run/xray.pid'*) ;;
            *) return 1 ;;
        esac
        eval "${definition//\/run\/xray.pid/\$pidfile}"
        _proc_any_named() { : > "$TMP/direct-old.scan"; return 1; }
        _proc_exe_is_strict() { : > "$TMP/direct-old.exe"; return 1; }
        _xd_pidfile_write() { : > "$TMP/direct-old.write"; return 0; }
        _manage_xray start >/dev/null 2>&1 || start_rc=$?
        _manage_xray stop >/dev/null 2>&1 || stop_rc=$?
        status=$(_manage_xray status 2>/dev/null) || :
        [ "$start_rc" -ne 0 ] && [ "$stop_rc" -ne 0 ] && [ "$status" = unknown ] &&
            cmp -s "$pidfile" "$TMP/direct-old.pid.before" &&
            [ ! -e "$TMP/direct-old.scan" ] && [ ! -e "$TMP/direct-old.exe" ] &&
            [ ! -e "$TMP/direct-old.write" ]
    }

    # 死 PID 的陈旧记录必须可清除; 否则崩溃后 direct 启动/停止/卸载都会被卡住。
    direct_stale_pidfile_cleaned() (
        local dir="$TMP/direct-stale-pidfile" pidfile="$TMP/direct-stale.pid"
        local definition rc=0
        rm -rf "$dir"; mkdir -p "$dir/confs"
        printf '{"version":{"min":"26.4.25","max":""}}' > "$dir/confs/15_version.json"
        DEPLOY_DIR="$dir" CONFIG_DIR="$dir/confs" STATE_DIR="$dir/state" INIT_SYSTEM=direct
        XRAY_DEPLOY_CORE_LOCK_HELD=1 XRAY_BIN="$dir/xray"
        printf '999999 123 xray\n' > "$pidfile"
        definition=$(declare -f _manage_xray)
        case "$definition" in *'/run/xray.pid'*) ;; *) return 1 ;; esac
        eval "${definition//\/run\/xray.pid/\$pidfile}"
        _proc_any_named() { return 1; }
        _xd_pidfile_write() { return 1; }
        nohup() { return 1; }
        sleep() { :; }
        _manage_xray stop >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 0 ] && [ ! -e "$pidfile" ] || return 1
        printf '999999 123 xray\n' > "$pidfile"
        _manage_xray start >/dev/null 2>&1 || :
        [ ! -e "$pidfile" ]
    )

    # P0: 8s 采样必须建立在真实 restart 之后; 只采样会把"旧进程仍 running"误判为成功。
    restart_verified_restarts_first() (
        local actions="$TMP/restart-actions"
        : > "$actions"
        XRAY_DEPLOY_CORE_LOCK_HELD=1
        eval "$verified_restart_definition"
        _manage_xray() {
            printf '%s\n' "$1" >> "$actions"
            [ "$1" = status ] && printf 'running'
            return 0
        }
        sleep() { :; }
        _restart_xray_verified || return 1
        [ "$(command head -n 1 "$actions")" = restart ]
    )

    # logrotate helper 检查必须早于任何入口删除。
    uninstall_cleanup_contract() {
        local def check_line rm_line
        def=$(declare -f _uninstall_xray_locked)
        check_line=$(printf '%s\n' "$def" | grep -n '_logrotate_cleanup' | head -n 1 | cut -d: -f1)
        rm_line=$(printf '%s\n' "$def" | grep -n 'rm -f /usr/local/bin' | head -n 1 | cut -d: -f1)
        [ -n "$check_line" ] && [ -n "$rm_line" ] && [ "$check_line" -lt "$rm_line" ]
    }

    version_gate_matrix() {
        eval "$(declare -f _xray_version_ge)"
        local dir="$TMP/version-gates" version gecko unix expected_gecko expected_unix
        mkdir -p "$dir"; printf '#!/bin/sh\nexit 0\n' > "$dir/xray"; chmod +x "$dir/xray"
        XRAY_BIN="$dir/xray"
        for version in 26.6.0 26.6.1 26.9.7 26.9.8; do
            _xray_current_version() { printf '%s' "$version"; }
            gecko=0; unix=0
            _hy2_gecko_supported || gecko=$?
            _hy2_masq_unix_supported || unix=$?
            case "$version" in
                26.6.0) expected_gecko=1; expected_unix=1 ;;
                26.6.1) expected_gecko=0; expected_unix=1 ;;
                26.9.7) expected_gecko=0; expected_unix=1 ;;
                26.9.8) expected_gecko=0; expected_unix=0 ;;
            esac
            [ "$gecko" -eq "$expected_gecko" ] && [ "$unix" -eq "$expected_unix" ] || return 1
        done
        _xray_current_version() { printf '26.9.7'; }
        _hy2_masq_known_keys_json | jq -e 'index("xForwarded") | not' >/dev/null || return 1
        _xray_current_version() { printf '26.9.8'; }
        _hy2_masq_known_keys_json | jq -e 'index("xForwarded")' >/dev/null || return 1
        _xray_current_version() { printf '26.9.8'; }
    }

    check 'minimum Xray version rejects before staging' min_version_rejection custom v26.4.24
    check 'invalid direct pidfile is rejected without takeover' invalid_pidfile_rejected
    check 'dead-PID direct pidfile is cleared instead of blocking recovery' direct_stale_pidfile_cleaned
    check 'verified restart actually restarts before sampling' restart_verified_restarts_first
    check 'uninstall checks logrotate helper before deleting entrypoints' uninstall_cleanup_contract
    check '26.6.1 and 26.9.8 gates and masquerade key set' version_gate_matrix
    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
