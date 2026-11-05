#!/usr/bin/env bash
# Offline state-changing menu behavior: transactions, cron and reset recovery.
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-menu-alignment.XXXXXX") || exit 1
trap 'rm -rf "${TMP:?}"' EXIT

(
    . "$ROOT/lib/00-common.sh"
    . "$ROOT/lib/50-nodes.sh"
    . "$ROOT/lib/90-menu.sh"

    DEPLOY_DIR="$TMP/deploy"
    CONFIG_DIR="$DEPLOY_DIR/confs"
    NODES_DIR="$DEPLOY_DIR/nodes"
    BACKUP_DIR="$DEPLOY_DIR/backups"
    STATE_DIR="$DEPLOY_DIR/state"
    mkdir -p "$CONFIG_DIR" "$NODES_DIR" "$BACKUP_DIR" "$STATE_DIR"
    TAG=xd-hysteria2-443
    META="$NODES_DIR/$TAG.json"
    PASS=0
    FAIL=0
    CONFIG_FAIL=no

    check() {
        local label="$1"
        shift
        if "$@"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s\n' "$label"
        fi
    }
    eq() { [ "$1" = "$2" ]; }
    _info() { :; }
    _warn() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _error() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _mutate_config() {
        local content
        printf 'config\n' >> "$TMP/writes"
        [ "$CONFIG_FAIL" = no ] || return 1
        content=$(_config_jq "$@") || return 1
        _config_write_merged "$content"
    }
    _meta_update() {
        local meta="$1" filter="$2" content
        shift 2
        printf 'metadata\n' >> "$TMP/writes"
        content=$(jq "$@" "$filter" "$meta") || return 1
        printf '%s\n' "$content" > "$meta"
    }
    _hy2_sync_derived() {
        [ "$1" = "$META" ] || return 1
        printf 'derived\n' >> "$TMP/writes"
    }
    _restart_xray_verified() { printf 'restart\n' >> "$TMP/writes"; return 0; }

    fixture() {
        local cc="$1" up="$2" down="${3-90 mbps}"
        CONFIG_FAIL=no
        printf '{"version":{"min":"26.4.25","max":""}}' > "$CONFIG_DIR/15_version.json"
        jq -n --arg t "$TAG" --arg cc "$cc" --arg up "$up" --arg down "$down" '
            {inbounds: [
                {tag: $t, protocol: "hysteria", port: 443,
                 settings: {version: 2, users: [{auth: "unchanged-auth", foreign: {keep: true}},
                      {auth: "second-auth"}], foreign: {keep: "settings"}},
                 streamSettings: {network: "hysteria", security: "tls",
                    tlsSettings: {serverName: "example.test"},
                    finalmask: {udp: [{type: "salamander", settings: {password: "keep"}}],
                        quicParams: ({congestion: $cc, debug: true, bbrProfile: "aggressive"}
                            + (if $up == "" then {} else {brutalUp: $up} end)
                            + (if $down == "" then {} else {brutalDown: $down} end))}}},
                {tag: "unrelated", protocol: "shadowsocks", port: 8443}
            ]}' > "$CONFIG_DIR/07_inbounds.json" || exit 1
        jq -n --arg t "$TAG" --arg cc "$cc" --arg up "$up" --arg down "$down" '
            {tag: $t, protocol: "hysteria2", name: "fixture", port: 443,
             auth: "unchanged-auth", share_link: "old-link", custom: {keep: true},
             congestion: $cc, brutal_up: $up, brutal_down: $down}' > "$META" || exit 1
        cp "$CONFIG_DIR/07_inbounds.json" "$TMP/before-inbounds.json"
        cp "$META" "$TMP/before-meta.json"
        : > "$TMP/writes"
        : > "$TMP/messages"
    }
    invoke() {
        RC=0
        _hy2_congestion_txn_locked "$TAG" "$@" > "$TMP/output" 2>&1 || RC=$?
    }

    fixture bbr '45 mbps'
    invoke congestion force-brutal 1kbps '80 mbps'
    check 'invalid force bandwidth is rejected before writes' eq "$RC" 1
    check 'invalid force bandwidth leaves config and metadata unchanged' \
        bash -c 'test ! -s "$1" && cmp -s "$2" "$3" && cmp -s "$4" "$5"' _ \
        "$TMP/writes" "$TMP/before-inbounds.json" "$CONFIG_DIR/07_inbounds.json" \
        "$TMP/before-meta.json" "$META"

    fixture bbr '45 mbps'
    invoke congestion force-brutal '60 mbps' ''
    check 'valid force bandwidth commits' eq "$RC" 0
    check 'valid force bandwidth updates config and metadata direction' jq -e '
        .inbounds[0].streamSettings.finalmask.quicParams == {congestion:"force-brutal",brutalUp:"60 mbps"}
        and .inbounds[1].port == 8443' "$CONFIG_DIR/07_inbounds.json"
    check 'valid force bandwidth updates metadata after config and derived sync' \
        eq "$(cat "$TMP/writes")" $'config\nmetadata\nderived'
    check 'valid force bandwidth metadata keeps server direction' jq -e '
        .congestion == "force-brutal" and .brutal_up == "60 mbps" and (has("brutal_down") | not)' "$META"

    fixture bbr '45 mbps'
    _meta_update() { printf 'metadata\n' >> "$TMP/writes"; return 1; }
    _restore_config() {
        printf 'restore\n' >> "$TMP/writes"
        cp "$TMP/before-inbounds.json" "$CONFIG_DIR/07_inbounds.json"
    }
    invoke congestion force-brutal '60 mbps' ''
    check 'metadata failure reports complete rollback' eq "$RC" 1
    check 'metadata failure restores config then restarts' \
        eq "$(cat "$TMP/writes")" $'config\nmetadata\nrestore\nrestart'
    check 'metadata failure preserves the old metadata' \
        eq "$(jq -Sc . "$TMP/before-meta.json")" "$(jq -Sc . "$META")"

    printf '== timed restart writes ==\n'
    cron_fixture() {
        printf '%s\n' 'MAILTO=operator@example.test' '15 4 * * * /usr/local/bin/backup' \
            '0 */3 * * * /usr/local/bin/xd timed-restart # xray-deploy-timed-restart' > "$TMP/crontab"
        printf '0 */3 * * *' > "$STATE_DIR/timed_restart"
        cp "$TMP/crontab" "$TMP/before-crontab"
        cp "$STATE_DIR/timed_restart" "$TMP/before-timed-state"
        : > "$TMP/cron-writes"
        : > "$TMP/messages"
        : > "$TMP/success"
    }
    invoke_cron() {
        RC=0
        (
            CRON_START_RC="${1:-0}"
            clear() { :; }
            _press_any_key() { :; }
            _tip() { :; }
            _success() { printf '%s\n' "$*" >> "$TMP/success"; }
            command() {
                if [ "${1-}" = -v ] && [ "${2-}" = "$CMD_NAME" ]; then
                    printf '/usr/local/bin/%s\n' "$CMD_NAME"
                else
                    builtin command "$@"
                fi
            }
            _with_config_lock() { "$@"; }
            _ensure_cron_running() { return "$CRON_START_RC"; }
            crontab() {
                case "$1" in
                    -l) cat "$TMP/crontab" ;;
                    -)
                        printf 'write\n' >> "$TMP/cron-writes"
                        [ "$CRON_WRITE_FAIL" = no ] || return 1
                        cat > "$TMP/crontab"
                        ;;
                    *) return 99 ;;
                esac
            }
            _timed_restart_menu <<< '2'
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    CMD_NAME=xd
    CRON_WRITE_FAIL=no
    cron_fixture
    invoke_cron 0
    check 'timed restart keeps unrelated tasks and updates state' \
        bash -c 'grep -q "^15 4 .*backup$" "$1" && grep -q "^0 \*/6 .*timed-restart" "$1" && [ "$(cat "$2")" = "0 */6 * * *" ]' _ \
        "$TMP/crontab" "$STATE_DIR/timed_restart"

    cron_fixture
    invoke_cron 1
    check 'cron startup failure returns normally' eq "$RC" 0
    check 'cron startup failure performs no crontab writes' test ! -s "$TMP/cron-writes"
    check 'cron startup failure preserves crontab bytes' cmp -s "$TMP/before-crontab" "$TMP/crontab"
    check 'cron startup failure preserves state bytes' cmp -s "$TMP/before-timed-state" "$STATE_DIR/timed_restart"
    check 'cron startup failure reports daemon failure' grep -qF 'cron 守护进程未能启动' "$TMP/messages"

    cron_fixture
    CRON_WRITE_FAIL=yes
    invoke_cron 0
    check 'crontab write failure preserves tasks and state' \
        bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ \
        "$TMP/before-crontab" "$TMP/crontab" "$TMP/before-timed-state" "$STATE_DIR/timed_restart"

    printf '== reset residual snapshot ==\n'
    reset_snapshot_cleanup() (
        local dir="$TMP/reset-cleanup"
        DEPLOY_DIR="$dir" CONFIG_DIR="$dir/confs" NODES_DIR="$dir/nodes"
        BACKUP_DIR="$dir/backups" STATE_DIR="$dir/state"
        XRAY_BIN="$dir/bin/xray"
        mkdir -p "$CONFIG_DIR" "$NODES_DIR" "$BACKUP_DIR" "$STATE_DIR"
        _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' >/dev/null 2>&1 || return 1
        local snapshot="$dir/.reset-snapshot"
        mkdir -p "$snapshot"
        _reset_config_recover_locked() { return 0; }
        _backup_config() { return 0; }
        _with_config_lock() { "$@"; }
        _with_deploy_install_lock() { "$@"; }
        _reset_fsync_required() { return 0; }
        _reset_fsync_rename() { return 0; }
        _hy2_hop_cleanup_candidates() { return 0; }
        _hy2_cleanup_all_hops() { return 0; }
        _init_config_if_empty() { _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' >/dev/null 2>&1; }
        _restart_xray_verified() { return 0; }
        _reset_config_locked >/dev/null 2>&1 || return 1
        [ ! -e "$snapshot" ]
    )
    check 'reset proceeds past a residual snapshot and cleans it' reset_snapshot_cleanup

    invoke_stop_menu() {
        local stop_rc="$1"
        : > "$TMP/success"
        : > "$TMP/messages"
        : > "$TMP/service-calls"
        : > "$TMP/press-calls"
        RC=0
        (
            STOP_RC="$stop_rc"
            clear() { :; }
            _menu_require_tty() { return 0; }
            _print_logo() { :; }
            _print_status_bar() { :; }
            _menu_row() { :; }
            _press_any_key() { printf 'press\n' >> "$TMP/press-calls"; }
            _success() { printf '%s\n' "$*" >> "$TMP/success"; }
            _reset_config_recover() { return 0; }
            _xray_core_txn_recover() { return 0; }
            _port_txn_recover() { return 0; }
            _auto_tag_tagless_inbounds() { return 0; }
            _auto_adopt_orphans() { return 0; }
            _auto_ensure_config_env() { return 0; }
            _manage_xray() { printf '%s\n' "$*" >> "$TMP/service-calls"; return "$STOP_RC"; }
            _main_menu <<< $'13\n0'
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    invoke_stop_menu 1
    check 'stop failure is dispatched once and reported without success' \
        bash -c 'test "$1" = 0 && test "$(cat "$2")" = stop && test ! -s "$3" && grep -qF "停止 Xray 失败" "$4" && test "$(cat "$5")" = press' _ \
        "$RC" "$TMP/service-calls" "$TMP/success" "$TMP/messages" "$TMP/press-calls"
    invoke_stop_menu 0
    check 'stop success reports stopped and still pauses' \
        bash -c 'test "$1" = 0 && test "$(cat "$2")" = stop && test "$(cat "$3")" = 已停止 && test ! -s "$4" && test "$(cat "$5")" = press' _ \
        "$RC" "$TMP/service-calls" "$TMP/success" "$TMP/messages" "$TMP/press-calls"

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
