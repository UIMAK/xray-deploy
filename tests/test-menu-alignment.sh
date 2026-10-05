#!/usr/bin/env bash
# Offline behavior of the real Hy2 transaction; finalmask.md: force-brutal.
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
    . "$ROOT/lib/50-nodes.sh"
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
        check "$label: derived file unchanged" eq "$BEFORE_CLASH" "$(cat "$CLASH_YAML")"
    }
    committed() {
        local label="$1" params="$2" meta_filter="$3" expected_config expected_meta
        expected_config=$(jq --arg t "$TAG" --argjson q "$params" '
            (.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) = $q' <<< "$BEFORE_CONFIG")
        expected_meta=$(jq "$meta_filter" <<< "$BEFORE_META")
        check "$label: succeeds" eq "$RC" 0
        check "$label: config then metadata then derived exactly once" eq "$(cat "$TMP/writes")" $'config\nmetadata\nderived'
        check "$label: config contract including unrelated inbound and transport" eq "$expected_config" "$(_config_merged)"
        check "$label: metadata contract including unrelated fields" eq "$expected_meta" "$(jq . "$META")"
    }

    printf '== Hy2 menu transaction official alignment ==\n'
    for invalid_up in '' '0' '0 mbps' '00.000 kbps' 'not-a-rate'; do
        fixture bbr '45 mbps'
        invoke congestion force-brutal "$invalid_up" '80 mbps'
        rejected "force-brutal switch up=[$invalid_up]"
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

    for invalid_up in '0' '0 mbps' '0.000 gbps'; do
        fixture force-brutal '75 mbps'
        invoke bandwidth '' "$invalid_up" '120 mbps'
        rejected "force-brutal bandwidth explicit up=[$invalid_up]"
    done
    for old_up in '' '0' '0 mbps'; do
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

    fixture force-brutal '75 mbps'
    invoke congestion force-brutal '75 mbps' ''
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

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
