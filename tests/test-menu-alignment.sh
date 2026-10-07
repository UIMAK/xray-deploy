#!/usr/bin/env bash
# Offline behavior of real Hy2 transactions, cron scheduling and service menus.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
command -v jq >/dev/null 2>&1 || { printf 'SUMMARY pass=0 fail=1 (jq required)\n'; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-menu-alignment.XXXXXX") || exit 1
cleanup() {
    local resolved
    resolved=$(cd "$TMP" 2>/dev/null && pwd -P) || return
    case "$resolved" in
        */xray-menu-alignment.*) [ "$resolved" = "$TMP" ] && rm -rf -- "$TMP" ;;
    esac
}
trap cleanup EXIT

# Keep every mock in a subshell, including when this test is sourced elsewhere.
(
    . "$ROOT/lib/00-common.sh"
    . "${MENU_ALIGNMENT_NODES_MODULE:-$ROOT/lib/50-nodes.sh}"
    # Override only for a disposable mutated copy, never edit production modules.
    . "${MENU_ALIGNMENT_MENU_MODULE:-$ROOT/lib/90-menu.sh}"

    DEPLOY_DIR="$TMP/deploy"
    CONFIG_DIR="$DEPLOY_DIR/confs"
    LEGACY_CONFIG_FILE="$DEPLOY_DIR/config.json"
    NODES_DIR="$DEPLOY_DIR/nodes"
    BACKUP_DIR="$DEPLOY_DIR/backups"
    STATE_DIR="$DEPLOY_DIR/state"
    CLASH_YAML="$DEPLOY_DIR/clash.yaml"
    mkdir -p "$CONFIG_DIR" "$NODES_DIR" "$BACKUP_DIR" "$STATE_DIR" || exit 1
    TAG=xd-hysteria2-443
    META="$NODES_DIR/$TAG.json"
    PASS=0 FAIL=0
    CONFIG_FAIL=no

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
        printf 'derived\n' >> "$TMP/writes"
        [ "$1" = "$META" ]
    }
    _restart_xray_verified() { printf 'UNEXPECTED restart\n' >> "$TMP/writes"; return 99; }
    _manage_xray() { printf 'UNEXPECTED service\n' >> "$TMP/writes"; return 99; }

    check() {
        local label="$1"
        shift
        if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label"; fi
    }
    eq() { [ "$1" = "$2" ]; }
    fixture() {
        local cc="$1" up="$2" down="${3-90 mbps}"
        CONFIG_FAIL=no
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
        printf 'unchanged derived fixture\n' > "$CLASH_YAML"
        snapshot
    }
    snapshot() {
        cp "$CONFIG_DIR/07_inbounds.json" "$TMP/before-inbounds.json"
        cp "$META" "$TMP/before-meta.json"
        BEFORE_CONFIG=$(_config_merged)
        BEFORE_META=$(cat "$META")
        BEFORE_CLASH=$(cat "$CLASH_YAML")
        : > "$TMP/writes"
        : > "$TMP/messages"
    }
    invoke() {
        RC=0
        _hy2_congestion_txn_locked "$TAG" "$@" > "$TMP/output" 2>&1 || RC=$?
    }
    rejected() {
        local label="$1"
        check "$label: rejects" eq "$RC" 1
        check "$label: rejects before any writer or derived sync" test ! -s "$TMP/writes"
        check "$label: config byte-for-byte unchanged" eq "$BEFORE_CONFIG" "$(_config_merged)"
        check "$label: metadata byte-for-byte unchanged" eq "$BEFORE_META" "$(cat "$META")"
        check "$label: raw config bytes unchanged" cmp -s "$TMP/before-inbounds.json" "$CONFIG_DIR/07_inbounds.json"
        check "$label: raw metadata bytes unchanged" cmp -s "$TMP/before-meta.json" "$META"
        check "$label: reports invalid transaction" test -s "$TMP/messages"
        check "$label: derived file unchanged" eq "$BEFORE_CLASH" "$(cat "$CLASH_YAML")"
    }
    committed() {
        local label="$1" params="$2" meta_filter="$3" expected_config expected_meta
        expected_config=$(jq --arg t "$TAG" --argjson q "$params" '
            (.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) = $q' <<< "$BEFORE_CONFIG")
        expected_meta=$(jq "$meta_filter | if .brutal_up == \"\" then del(.brutal_up) else . end | if .brutal_down == \"\" then del(.brutal_down) else . end" <<< "$BEFORE_META")
        check "$label: succeeds" eq "$RC" 0
        check "$label: config then metadata then derived exactly once" eq "$(cat "$TMP/writes")" $'config\nmetadata\nderived'
        check "$label: config contract including unrelated inbound and transport" eq "$expected_config" "$(_config_merged)"
        check "$label: metadata contract including unrelated fields" eq "$expected_meta" "$(jq . "$META")"
    }

    printf '== Hy2 menu transaction official alignment ==\n'
    for invalid_up in '' '0' '0 mbps' '00.000 kbps' 'not-a-rate' 1kbps 0.01mbps 10kbps 65534bps 65535bps 100kbps 524287bps 511.999kbps 0.499999mbps 1watts; do
        fixture bbr '45 mbps'
        invoke congestion force-brutal "$invalid_up" '80 mbps'
        rejected "force-brutal switch up=[$invalid_up]"
    done

    for valid_up in 524288bps 512kbps 0.5mbps; do
        fixture bbr '45 mbps'
        invoke congestion force-brutal "$valid_up" ''
        committed "force-brutal minimum [$valid_up]" \
            "{\"congestion\":\"force-brutal\",\"brutalUp\":\"$valid_up\"}" \
            ".congestion=\"force-brutal\" | .brutal_up=\"$valid_up\" | .brutal_down=\"\""
    done

    fixture bbr '45 mbps'
    invoke congestion force-brutal '60 mbps' ''
    committed 'nonzero force-brutal switch permits blank down' \
        '{"congestion":"force-brutal","brutalUp":"60 mbps"}' \
        '.congestion="force-brutal" | .brutal_up="60 mbps" | .brutal_down=""'

    fixture bbr '45 mbps'
    invoke congestion force-brutal '0.5 gbps' '0'
    committed 'fractional nonzero force-brutal with unlimited down' \
        '{"congestion":"force-brutal","brutalUp":"0.5 gbps","brutalDown":"0"}' \
        '.congestion="force-brutal" | .brutal_up="0.5 gbps" | .brutal_down="0"'

    fixture bbr '45 mbps'
    invoke congestion brutal '' ''
    committed 'negotiated brutal permits blank bandwidth' \
        '{"congestion":"brutal"}' '.congestion="brutal" | .brutal_up="" | .brutal_down=""'

    fixture bbr '45 mbps'
    invoke congestion brutal '0' '0'
    committed 'negotiated brutal permits unlimited zero' \
        '{"congestion":"brutal","brutalUp":"0","brutalDown":"0"}' \
        '.congestion="brutal" | .brutal_up="0" | .brutal_down="0"'

    for operation in congestion bandwidth; do
        for rate in 1bps 7bps 0.000001mbps 1kbps 65535bps 524287bps not-a-rate 1watts; do
            for target in brutal-up brutal-down force-down; do
                cc=brutal up='75 mbps' down='90 mbps'
                case "$target" in
                    brutal-up) up="$rate" ;;
                    brutal-down) down="$rate" ;;
                    force-down) cc=force-brutal down="$rate" ;;
                esac
                if [ "$operation" = congestion ]; then
                    fixture bbr '45 mbps'
                    invoke congestion "$cc" "$up" "$down"
                else
                    fixture "$cc" '75 mbps'
                    invoke bandwidth '' "$up" "$down"
                fi
                rejected "$operation $target=[$rate]"
            done
        done
        for rate in 524288bps 512kbps 0.5mbps 0 '0 mbps' 00.000kbps ''; do
            for target in brutal-up brutal-down force-down; do
                cc=brutal up='75 mbps' down='90 mbps'
                case "$target" in
                    brutal-up) up="$rate" ;;
                    brutal-down) down="$rate" ;;
                    force-down) cc=force-brutal down="$rate" ;;
                esac
                if [ "$operation" = congestion ]; then
                    fixture bbr '45 mbps'
                    invoke congestion "$cc" "$up" "$down"
                    params=$(jq -nc --arg cc "$cc" --arg up "$up" --arg down "$down" '
                        {congestion: $cc}
                        + (if $up == "" then {} else {brutalUp: $up} end)
                        + (if $down == "" then {} else {brutalDown: $down} end)')
                else
                    if [ -z "$rate" ]; then
                        fixture "$cc" "$up" "$down"
                    else
                        fixture "$cc" '75 mbps'
                    fi
                    invoke bandwidth '' "$up" "$down"
                    params=$(jq -nc --arg cc "$cc" --arg up "$up" --arg down "$down" '
                        {congestion: $cc, debug: true, bbrProfile: "aggressive"}
                        + (if $up == "" then {} else {brutalUp: $up} end)
                        + (if $down == "" then {} else {brutalDown: $down} end)')
                fi
                meta_filter=$(jq -nr --arg cc "$cc" --arg up "$up" --arg down "$down" '
                    ".congestion=" + ($cc | tojson) + " | .brutal_up=" + ($up | tojson)
                    + " | .brutal_down=" + ($down | tojson)')
                committed "$operation $target=[$rate]" "$params" "$meta_filter"
            done
        done
    done

    for rate in 524288bps 512kbps 0.5mbps; do
        fixture force-brutal '75 mbps'
        invoke bandwidth '' "$rate" ''
        committed "force-brutal bandwidth minimum up=[$rate]" \
            "{\"congestion\":\"force-brutal\",\"debug\":true,\"bbrProfile\":\"aggressive\",\"brutalUp\":\"$rate\",\"brutalDown\":\"90 mbps\"}" \
            ".brutal_up=\"$rate\" | .brutal_down=\"90 mbps\""
    done
    for cc in brutal force-brutal; do
        for old_down in 1kbps 65535bps 524287bps not-a-rate; do
            fixture "$cc" '75 mbps' "$old_down"
            jq '.brutal_down="90 mbps"' "$META" > "$TMP/meta-next"
            cat "$TMP/meta-next" > "$META"
            snapshot
            invoke bandwidth '' '100 mbps' ''
            rejected "$cc blank down retains invalid actual config down=[$old_down] despite valid metadata"
        done
    done
    for old_up in 1kbps 65535bps 524287bps not-a-rate; do
        fixture brutal "$old_up"
        jq '.brutal_up="75 mbps"' "$META" > "$TMP/meta-next"
        cat "$TMP/meta-next" > "$META"
        snapshot
        invoke bandwidth '' '' '120 mbps'
        rejected "brutal blank up retains invalid actual config up=[$old_up] despite valid metadata"
    done
    for cc in brutal force-brutal; do
        fixture "$cc" '75 mbps' 1kbps
        invoke bandwidth '' '' 512kbps
        committed "$cc explicit down repairs invalid old config down" \
            "{\"congestion\":\"$cc\",\"debug\":true,\"bbrProfile\":\"aggressive\",\"brutalUp\":\"75 mbps\",\"brutalDown\":\"512kbps\"}" \
            '.brutal_up="75 mbps" | .brutal_down="512kbps"'
    done

    fixture force-brutal '75 mbps'
    jq '.brutal_up="0" | .brutal_down="stale"' "$META" > "$TMP/meta-next"
    cat "$TMP/meta-next" > "$META"
    snapshot
    invoke bandwidth '' '' '120 mbps'
    committed 'blank force-brutal up retains config not stale metadata' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"75 mbps","brutalDown":"120 mbps"}' \
        '.brutal_up="75 mbps" | .brutal_down="120 mbps"'

    fixture force-brutal '75 mbps'
    invoke bandwidth '' '' ''
    committed 'both blank bandwidth inputs preserve config values' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"75 mbps","brutalDown":"90 mbps"}' \
        '.brutal_up="75 mbps" | .brutal_down="90 mbps"'

    fixture force-brutal '75 mbps'
    invoke bandwidth '' '100 mbps' ''
    committed 'force-brutal explicit nonzero up retains blank down' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"100 mbps","brutalDown":"90 mbps"}' \
        '.brutal_up="100 mbps" | .brutal_down="90 mbps"'

    for invalid_up in '0' '0 mbps' '0.000 gbps' 1kbps 524287bps 0.499999mbps; do
        fixture force-brutal '75 mbps'
        invoke bandwidth '' "$invalid_up" '120 mbps'
        rejected "force-brutal bandwidth explicit up=[$invalid_up]"
    done
    for old_up in '' '0' '0 mbps' 1kbps 524287bps; do
        fixture force-brutal "$old_up"
        invoke bandwidth '' '' '120 mbps'
        rejected "force-brutal blank up with invalid effective config up=[$old_up]"
    done
    fixture force-brutal '0'
    jq '.brutal_up="75 mbps"' "$META" > "$TMP/meta-next"
    cat "$TMP/meta-next" > "$META"
    snapshot
    invoke bandwidth '' '' '120 mbps'
    rejected 'blank force-brutal up rejects config zero despite nonzero metadata'

    fixture force-brutal '0'
    invoke bandwidth '' '100 mbps' ''
    committed 'explicit nonzero bandwidth repairs old zero up' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"100 mbps","brutalDown":"90 mbps"}' \
        '.brutal_up="100 mbps" | .brutal_down="90 mbps"'

    fixture brutal '' ''
    invoke bandwidth '' '' ''
    committed 'negotiated brutal bandwidth permits absent up' \
        '{"congestion":"brutal","debug":true,"bbrProfile":"aggressive"}' '.brutal_up="" | .brutal_down=""'

    fixture force-brutal '75 mbps'
    invoke congestion bbr '' ''
    committed 'bbr switch removes config and metadata bandwidth fields' \
        '{"congestion":"bbr"}' '.congestion="bbr" | del(.brutal_up, .brutal_down)'

    fixture force-brutal '75 mbps'
    jq '.congestion="brutal"' "$META" > "$TMP/meta-next"
    cat "$TMP/meta-next" > "$META"
    snapshot
    invoke bandwidth '' '100 mbps' ''
    rejected 'bandwidth rejects config metadata congestion disagreement'

    fixture bbr '45 mbps'
    invoke congestion reno '60 mbps' ''
    rejected 'unsupported menu congestion mode'

    for cc in brutal force-brutal; do
        fixture "$cc" '75 mbps'
        invoke congestion "$cc" '100 mbps' '120 mbps'
        committed "$cc same-mode switch applies both new bandwidths" \
            "{\"congestion\":\"$cc\",\"brutalUp\":\"100 mbps\",\"brutalDown\":\"120 mbps\"}" \
            '.brutal_up="100 mbps" | .brutal_down="120 mbps"'

        fixture "$cc" '75 mbps'
        invoke congestion "$cc" '75 mbps' ''
        committed "$cc same-mode switch clears down on blank input" \
            "{\"congestion\":\"$cc\",\"brutalUp\":\"75 mbps\"}" '.brutal_down=""'

        fixture "$cc" '75 mbps'
        jq '.brutal_up="stale" | .brutal_down="stale"' "$META" > "$TMP/meta-next"
        cat "$TMP/meta-next" > "$META"
        snapshot
        invoke congestion "$cc" '75 mbps' '90 mbps'
        committed "$cc same-mode switch reconciles stale metadata" \
            "{\"congestion\":\"$cc\",\"brutalUp\":\"75 mbps\",\"brutalDown\":\"90 mbps\"}" \
            '.brutal_up="75 mbps" | .brutal_down="90 mbps"'
    done

    fixture bbr '' ''
    invoke congestion bbr '' ''
    check 'already aligned congestion returns existing no-op status' eq "$RC" 3
    check 'already aligned congestion performs no writes or sync' test ! -s "$TMP/writes"
    check 'already aligned congestion preserves config' eq "$BEFORE_CONFIG" "$(_config_merged)"
    check 'already aligned congestion preserves metadata' eq "$BEFORE_META" "$(cat "$META")"

    fixture bbr '45 mbps'
    CONFIG_FAIL=yes
    invoke congestion force-brutal '60 mbps' ''
    check 'config failure returns failure' eq "$RC" 1
    check 'config failure never attempts metadata or derived commit' eq "$(cat "$TMP/writes")" config
    check 'config failure preserves metadata' eq "$BEFORE_META" "$(cat "$META")"
    check 'config failure preserves config' eq "$BEFORE_CONFIG" "$(_config_merged)"

    printf '== Timed restart menu ==\n'
    cron_fixture() {
        printf '%s\n' 'MAILTO=operator@example.test' '15 4 * * * /usr/local/bin/backup' \
            '0 */3 * * * /usr/local/bin/xd timed-restart # xray-deploy-timed-restart' > "$TMP/crontab"
        printf '0 */3 * * *' > "$STATE_DIR/timed_restart"
        cp "$TMP/crontab" "$TMP/before-crontab"
        cp "$STATE_DIR/timed_restart" "$TMP/before-timed-state"
        : > "$TMP/cron-writes"
        : > "$TMP/success"
        : > "$TMP/messages"
    }
    invoke_cron() {
        RC=0
        (
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
            # Only the daemon and command boundary are mocked; helpers read/write scratch.
            _with_config_lock() { "$@"; }
            crontab() {
                case "$1" in
                    -l) cat "$TMP/crontab" ;;
                    -) printf 'write\n' >> "$TMP/cron-writes"
                       [ "$CRON_WRITE_FAIL" = no ] || return 1
                       cat > "$TMP/crontab" ;;
                    *) return 99 ;;
                esac
            }
            CRON_START_RC="$1"
            _ensure_cron_running() { return "$CRON_START_RC"; }
            _timed_restart_menu <<< '2'
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    CMD_NAME=xd
    CRON_WRITE_FAIL=no
    cron_fixture
    invoke_cron 1
    check 'cron startup failure retains menu return status' eq "$RC" 0
    check 'cron startup failure performs no crontab writes' test ! -s "$TMP/cron-writes"
    check 'cron startup failure preserves all original crontab bytes' cmp -s "$TMP/before-crontab" "$TMP/crontab"
    check 'cron startup failure preserves original state bytes' cmp -s "$TMP/before-timed-state" "$STATE_DIR/timed_restart"
    check 'cron startup failure emits no success' test ! -s "$TMP/success"
    check 'cron startup failure reports daemon failure' grep -qF 'cron 守护进程未能启动' "$TMP/messages"

    cron_fixture
    invoke_cron 0
    check 'cron startup success retains menu return status' eq "$RC" 0
    check 'cron startup success writes exactly once' eq "$(cat "$TMP/cron-writes")" write
    check 'cron startup success preserves unrelated tasks and replaces old schedule' \
        eq "$(cat "$TMP/crontab")" $'MAILTO=operator@example.test\n15 4 * * * /usr/local/bin/backup\n0 */6 * * * /usr/local/bin/xd timed-restart # xray-deploy-timed-restart'
    check 'cron startup success updates state' eq "$(_state_get timed_restart)" '0 */6 * * *'
    check 'cron startup success reports new schedule' grep -qF '定时重启已设置: 0 */6 * * *' "$TMP/success"

    cron_fixture
    CRON_WRITE_FAIL=yes
    invoke_cron 0
    check 'cron write failure retains menu return status' eq "$RC" 0
    check 'cron write failure preserves old tasks' cmp -s "$TMP/before-crontab" "$TMP/crontab"
    check 'cron write failure preserves state' cmp -s "$TMP/before-timed-state" "$STATE_DIR/timed_restart"
    check 'cron write failure emits no success' test ! -s "$TMP/success"
    check 'cron write failure reports failure' grep -qF '写入 crontab 失败' "$TMP/messages"

    printf '== Main menu stop result ==\n'
    invoke_stop_menu() {
        : > "$TMP/success"
        : > "$TMP/messages"
        : > "$TMP/service-calls"
        : > "$TMP/press-calls"
        RC=0
        (
            STOP_RC="$1"
            clear() { :; }
            _menu_require_tty() { return 0; }
            _print_logo() { :; }
            _print_status_bar() { :; }
            _menu_row() { :; }
            _press_any_key() { printf 'press\n' >> "$TMP/press-calls"; }
            _success() { printf '%s\n' "$*" >> "$TMP/success"; }
            _reset_config_recover() { return 0; }
            _xray_core_txn_recover() { return 0; }
            _config_migrate_legacy() { return 0; }
            _port_txn_recover() { return 0; }
            _auto_tag_tagless_inbounds() { return 0; }
            _auto_adopt_orphans() { return 0; }
            _auto_ensure_config_env() { return 0; }
            _auto_migrate_geo_autoupdate() { return 0; }
            _manage_xray() { printf '%s\n' "$*" >> "$TMP/service-calls"; return "$STOP_RC"; }
            _main_menu <<< $'11\n0'
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    for stop_rc in 1 2 99; do
        invoke_stop_menu "$stop_rc"
        check "stop rc=$stop_rc: menu exits normally after 0" eq "$RC" 0
        check "stop rc=$stop_rc: dispatches only stop once" eq "$(cat "$TMP/service-calls")" stop
        check "stop rc=$stop_rc: emits no success" test ! -s "$TMP/success"
        check "stop rc=$stop_rc: reports failure" grep -qF '停止 Xray 失败' "$TMP/messages"
        check "stop rc=$stop_rc: still pauses before next selection" eq "$(cat "$TMP/press-calls")" press
    done
    invoke_stop_menu 0
    check 'stop success: menu exits normally after 0' eq "$RC" 0
    check 'stop success: dispatches only stop once' eq "$(cat "$TMP/service-calls")" stop
    check 'stop success: reports stopped' eq "$(cat "$TMP/success")" '已停止'
    check 'stop success: emits no failure' test ! -s "$TMP/messages"
    check 'stop success: still pauses before next selection' eq "$(cat "$TMP/press-calls")" press

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
