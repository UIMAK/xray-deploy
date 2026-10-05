#!/usr/bin/env bash
# Usage: XRAY_TEST_BIN=/path/to/xray bash tests/verify-configs.sh
# Only parses isolated configs; never installs a core or starts a service.
set -euo pipefail
umask 077

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [xray-core-path]\n' "$0" >&2
    exit 2
fi
core_input=${1:-${XRAY_TEST_BIN:-}}
if [ -z "$core_input" ] || [ ! -x "$core_input" ]; then
    printf 'Set XRAY_TEST_BIN or pass an executable Xray core path.\n' >&2
    exit 2
fi
for tool in jq openssl mktemp readlink; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool" >&2; exit 2; }
done
core=$(readlink -f "$core_input")
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
scratch=$(cd -- "$scratch" && pwd -P)
cleanup() {
    local resolved
    resolved=$(cd -- "$scratch" && pwd -P) || return 1
    [ "$resolved" = "$scratch" ] && [ "$resolved" != / ] || return 1
    rm -rf -- "${scratch:?}"
}
trap cleanup EXIT

# Source modules only: the main entry point must never run.
source "$repo/lib/00-common.sh"
source "$repo/lib/20-xray-core.sh"
source "$repo/lib/50-nodes.sh"
DEPLOY_DIR="$scratch/deploy"
BIN_DIR="$DEPLOY_DIR/bin"
ASSET_DIR="$DEPLOY_DIR/assets"
CONFIG_DIR="$DEPLOY_DIR/confs"
LEGACY_CONFIG_FILE="$DEPLOY_DIR/config.json"
NODES_DIR="$DEPLOY_DIR/nodes"
CERT_DIR="$DEPLOY_DIR/certs"
LOG_DIR="$DEPLOY_DIR/logs"
STATE_DIR="$DEPLOY_DIR/state"
BACKUP_DIR="$STATE_DIR/backup"
XRAY_BIN="$core"
XRAY_LOCATION_ASSET="$ASSET_DIR"
GEO_LOG="$LOG_DIR/geo.log"
CF_BIN="$BIN_DIR/cloudflared"
CF_UNIT_SYSTEMD="$DEPLOY_DIR/cloudflared.service"
CF_UNIT_OPENRC="$DEPLOY_DIR/cloudflared.init"
INIT_SYSTEM=direct
_deploy_lock_root() { printf '%s' "$scratch/locks"; }
_create_xray_service() { printf 'create\n' >> "$scratch/service-calls"; }
_manage_xray() {
    case "$1" in
        status) printf 'stopped\n' ;;
        *) printf 'Unexpected service action: %s\n' "$1" >&2; return 1 ;;
    esac
}
_restart_xray_verified() { printf 'Unexpected service restart\n' >&2; return 1; }
mkdir -p "$ASSET_DIR" "$CERT_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR"

version=$("$XRAY_BIN" version)
printf 'CORE: %s\n' "${version%%$'\n'*}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=config-test.invalid \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" > "$scratch/openssl.log" 2>&1

passed=0
failed=0
skipped=0
record() {
    case "$1" in
        PASS) passed=$((passed + 1)) ;;
        FAIL) failed=$((failed + 1)) ;;
        SKIP) skipped=$((skipped + 1)) ;;
    esac
    printf '%s: %s\n' "$1" "$2"
}
assert_field() {
    local json="$1" filter="$2" expected="$3"
    printf '%s' "$json" | jq -e --arg expected "$expected" "($filter) == \$expected" >/dev/null
}
test_confdir() {
    local name="$1" dir="$2" log="$scratch/$1.log" rc=0
    XRAY_LOCATION_ASSET="$ASSET_DIR" XRAY_JSON_STRICT=true \
        "$XRAY_BIN" run -test -confdir "$dir" </dev/null > "$log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && grep -qF 'Configuration OK' "$log"; then
        record PASS "$name (run -test -confdir)"
    else
        record FAIL "$name (core rc=$rc; feature-incompatible cores must not count as passes)"
        tail -n 8 "$log" >&2
    fi
}
check_rendered() {
    local name="$1" inbound="$2" dir="$scratch/$1-confs" config
    config=$(jq -n --argjson inbound "$inbound" \
        '{log:{loglevel:"warning"},inbounds:[$inbound],outbounds:[{protocol:"freedom",tag:"direct"}]}')
    if _config_write_merged "$config" "$dir"; then
        test_confdir "$name" "$dir"
    else
        record FAIL "$name (cannot write confdir)"
    fi
}

# Set the complete render context after sourcing; production defaults must stay unused.
R_LISTEN=127.0.0.1
R_UUID=5783a3e7-e373-51cd-8642-c83782b807c5
R_TARGET=config-test.invalid
R_SERVER_NAME=config-test.invalid
R_PRIVATE_KEY=''
R_SHORT_ID=0123456789abcdef
R_PATH='/config-test?left=1&right=2&ed=2560'
R_HOST=config-test.invalid
R_METHOD=aes-128-gcm
R_PASSWORD='ss-left&ss-right&%s'
R_MLDSA65_SEED=''
R_AUTH='hy2-left&hy2-right&%s'
R_CERT_FILE="$CERT_DIR/cert.pem"
R_KEY_FILE="$CERT_DIR/key.pem"
R_CONGESTION=bbr
R_BRUTAL_PARAMS_BLOCK=''
R_OBFS_MASK_BLOCK=''
R_TUNNEL_PORT=18450
R_TUNNEL_TAG=config-test-tunnel
R_FLOW=''
R_DECRYPTION=none
R_NETWORK=tcp,udp

# Real key material is required by REALITY and ENC (official reality/vless docs).
if keypair=$("$XRAY_BIN" x25519 2> "$scratch/x25519.log"); then
    R_PRIVATE_KEY=$(printf '%s\n' "$keypair" | awk -F': ' '/^Private/ {print $2; exit}')
fi
R_PORT=18445
for template in vless-tcp-reality-vision-direct vless-tcp-reality-vision-tunnel \
                vless-xhttp-reality-direct vless-xhttp-reality-tunnel; do
    R_PORT=$((R_PORT + 1))
    R_TAG="config-test-$template"
    case "$template" in
        *-direct) expected_target="$R_TARGET:443" ;;
        *-tunnel) expected_target="127.0.0.1:$R_TUNNEL_PORT" ;;
    esac
    if [ -n "$R_PRIVATE_KEY" ] && inbound=$(_render_template "$repo/templates/$template.server.jsonc") \
       && assert_field "$inbound" '.streamSettings.realitySettings.target' "$expected_target" \
       && assert_field "$inbound" '.streamSettings.realitySettings.privateKey' "$R_PRIVATE_KEY" \
       && assert_field "$inbound" '.streamSettings.realitySettings.serverNames[0]' "$R_SERVER_NAME" \
       && assert_field "$inbound" '.streamSettings.realitySettings.shortIds[0]' "$R_SHORT_ID"; then
        check_rendered "$template" "$inbound"
    else
        record FAIL "$template (real key generation, render or REALITY fields differ)"
    fi
done

R_PORT=18451
R_TAG=config-test-enc
if ! _xray_version_ge 25.8.31; then
    record SKIP 'vless-enc (requires core >=25.8.31; encryption must not silently fall back to none)'
elif _generate_vless_enc_keys x25519 > "$scratch/vlessenc.log" 2>&1; then
    R_DECRYPTION="$VLESS_ENC_DECRYPTION"
    if inbound=$(_render_template "$repo/templates/vless-enc.server.jsonc") \
       && assert_field "$inbound" '.settings.decryption' "$R_DECRYPTION" \
       && [ "$R_DECRYPTION" != none ]; then
        check_rendered vless-enc "$inbound"
    else
        record FAIL 'vless-enc (real encryption key or render differs)'
    fi
else
    record FAIL 'vless-enc (supported core key generation failed)'
fi
R_DECRYPTION=none

R_PORT=18452
R_TAG=config-test-xhttp
if inbound=$(_render_template "$repo/templates/vless-xhttp-cdn.server.jsonc") \
   && assert_field "$inbound" '.streamSettings.xhttpSettings.path' "$R_PATH" \
   && assert_field "$inbound" '.streamSettings.xhttpSettings.mode' auto; then
    check_rendered xhttp-cdn-path-ampersand "$inbound"
else
    record FAIL 'xhttp-cdn-path-ampersand (rendered path/mode differs or render failed)'
fi

R_PORT="$R_TUNNEL_PORT"
R_TAG="$R_TUNNEL_TAG"
if inbound=$(_render_template "$repo/templates/tunnel.server.jsonc") \
   && assert_field "$inbound" '.settings.address' "$R_TARGET" \
   && assert_field "$inbound" '.settings.rewriteAddress' "$R_TARGET" \
   && printf '%s' "$inbound" | jq -e '.settings | .port == 443 and .rewritePort == 443 and .network == "tcp" and .allowedNetwork == "tcp"' >/dev/null; then
    check_rendered tunnel-dual-field-names "$inbound"
else
    record FAIL 'tunnel-dual-field-names (rendered old/new target fields differ)'
fi

R_PORT=18443
R_TAG=config-test-ws
R_UUID=5783a3e7-e373-51cd-8642-c83782b807c5
R_DECRYPTION=none
R_PATH='/config-test?left=1&right=2&ed=2560'
ws_tpl="$repo/templates/vless-ws-cdn.server.jsonc"
if ws=$(_render_template "$ws_tpl") && assert_field "$ws" '.streamSettings.wsSettings.path' "$R_PATH"; then
    check_rendered ws-path-ampersand "$ws"
else
    record FAIL 'ws-path-ampersand (rendered path differs or render failed)'
    ws=''
fi

R_PORT=18444
R_TAG=config-test-ss
R_METHOD=aes-128-gcm
R_PASSWORD='ss-left&ss-right&%s'
R_NETWORK=tcp,udp
ss_tpl="$repo/templates/shadowsocks.server.jsonc"
if ss=$(_render_template "$ss_tpl") && assert_field "$ss" '.settings.password' "$R_PASSWORD"; then
    check_rendered shadowsocks-password-ampersand "$ss"
else
    record FAIL 'shadowsocks-password-ampersand (rendered password differs or render failed)'
    ss=''
fi

hy_tpl="$repo/templates/hysteria2.server.jsonc"
R_PORT=18445
R_TAG=config-test-hy2
R_AUTH='hy2-left&hy2-right&%s'
R_CERT_FILE="$CERT_DIR/cert.pem"
R_KEY_FILE="$CERT_DIR/key.pem"
R_CONGESTION=bbr
R_BRUTAL_PARAMS_BLOCK=''
R_OBFS_MASK_BLOCK=''
hy=''
for mode in plain salamander gecko brutal; do
    if { [ "$mode" = gecko ] || [ "$mode" = brutal ]; } && ! _xray_version_ge 26.6.1; then
        record SKIP "hy2-$mode-ampersand (packetSize requires core >=26.6.1; old cores silently discard it)"
        continue
    fi
    R_OBFS_MASK_BLOCK=''
    R_CONGESTION=bbr
    R_BRUTAL_PARAMS_BLOCK=''
    obfs_password='obfs-left&obfs-right&%s'
    case "$mode" in
        salamander) R_OBFS_MASK_BLOCK=$(_hy2_obfs_mask_block salamander "$obfs_password" '') ;;
        gecko) R_OBFS_MASK_BLOCK=$(_hy2_obfs_mask_block salamander "$obfs_password" 512-1200) ;;
        brutal)
            R_CONGESTION=brutal
            R_BRUTAL_PARAMS_BLOCK=', "brutalUp": "20 mbps", "brutalDown": "40 mbps"'
            R_OBFS_MASK_BLOCK=$(_hy2_obfs_mask_block salamander "$obfs_password" 512-1200)
            ;;
    esac
    name="hy2-$mode-ampersand"
    if ! inbound=$(_render_template "$hy_tpl") || ! assert_field "$inbound" '.settings.clients[0].auth' "$R_AUTH"; then
        record FAIL "$name (rendered auth differs or render failed)"
        continue
    fi
    if [ "$mode" != plain ] && ! assert_field "$inbound" '.streamSettings.finalmask.udp[0].settings.password' "$obfs_password"; then
        record FAIL "$name (rendered obfs password differs)"
        continue
    fi
    if [ "$mode" = gecko ] || [ "$mode" = brutal ]; then
        assert_field "$inbound" '.streamSettings.finalmask.udp[0].settings.packetSize' 512-1200 || {
            record FAIL "$name (rendered Gecko packetSize differs)"; continue;
        }
    fi
    if [ "$mode" = brutal ]; then
        if ! assert_field "$inbound" '.streamSettings.finalmask.quicParams.brutalUp' '20 mbps' \
           || ! assert_field "$inbound" '.streamSettings.finalmask.quicParams.brutalDown' '40 mbps'; then
            record FAIL "$name (rendered brutal bandwidth differs)"
            continue
        fi
    fi
    check_rendered "$name" "$inbound"
    hy="$inbound"
done

# Core Bandwidth.Bps uses binary units; Build requires >=65536 bytes/s, not docs' 65535 bps.
for rate in 1kbps 0.01mbps 10kbps 65534bps 65535bps 100kbps 524287bps 511.999kbps 0.499999mbps \
            524288bps 512kbps 0.5mbps '.5 MBPS' 524288 '512 kb'; do
    case "$rate" in
        524288bps|512kbps|0.5mbps|'.5 MBPS'|524288|'512 kb') expected=0 ;;
        *) expected=1 ;;
    esac
    validator_rc=0
    _hy2_force_brutal_up_valid "$rate" || validator_rc=$?
    R_CONGESTION=force-brutal
    R_OBFS_MASK_BLOCK=''
    R_BRUTAL_PARAMS_BLOCK=", \"brutalUp\": \"$rate\""
    if ! inbound=$(_render_template "$hy_tpl") \
       || ! assert_field "$inbound" '.streamSettings.finalmask.quicParams.brutalUp' "$rate"; then
        record FAIL "force-brutal [$rate] (render differs)"
        continue
    fi
    dir="$scratch/force-brutal-confs"
    config=$(jq -n --argjson inbound "$inbound" \
        '{inbounds:[$inbound],outbounds:[{protocol:"freedom"}]}')
    if ! _config_write_merged "$config" "$dir"; then
        record FAIL "force-brutal [$rate] (confdir write failed)"
        continue
    fi
    rc=0
    XRAY_LOCATION_ASSET="$ASSET_DIR" XRAY_JSON_STRICT=true \
        "$XRAY_BIN" run -test -confdir "$dir" </dev/null > "$scratch/force-brutal.log" 2>&1 || rc=$?
    if [ "$validator_rc" -eq "$expected" ] && \
       { { [ "$expected" -eq 0 ] && [ "$rc" -eq 0 ] && grep -qF 'Configuration OK' "$scratch/force-brutal.log"; } \
       || { [ "$expected" -eq 1 ] && [ "$rc" -ne 0 ] && grep -qF 'BrutalUp must be at least 65536 bytes per second' "$scratch/force-brutal.log"; }; }; then
        record PASS "force-brutal [$rate] (helper/core agree, expected rc=$expected)"
    else
        record FAIL "force-brutal [$rate] (helper rc=$validator_rc, core rc=$rc, expected=$expected)"
        tail -n 8 "$scratch/force-brutal.log" >&2
    fi
done

for scenario in forceDown ordinaryUp ordinaryDown; do
    case "$scenario" in
        forceDown) R_CONGESTION=force-brutal; field=brutalDown; error_field=BrutalDown ;;
        ordinaryUp) R_CONGESTION=brutal; field=brutalUp; error_field=BrutalUp ;;
        ordinaryDown) R_CONGESTION=brutal; field=brutalDown; error_field=BrutalDown ;;
    esac
    for rate_case in 1kbps 65535bps 524287bps 524288bps 512kbps 0.5mbps 0 '' absent; do
        rate="$rate_case"
        expected=0
        case "$rate_case" in
            1kbps|65535bps|524287bps) expected=1 ;;
            absent) rate='' ;;
        esac
        validator_rc=0
        _hy2_brutal_rate_valid "$rate" || validator_rc=$?
        R_OBFS_MASK_BLOCK=''
        R_BRUTAL_PARAMS_BLOCK=''
        if [ "$scenario" = forceDown ]; then
            R_BRUTAL_PARAMS_BLOCK=', "brutalUp": "80mbps"'
        fi
        if [ "$rate_case" != absent ]; then
            R_BRUTAL_PARAMS_BLOCK+=", \"$field\": \"$rate\""
        fi
        name="$scenario [${rate_case:-empty}]"
        if ! inbound=$(_render_template "$hy_tpl") \
           || ! assert_field "$inbound" '.streamSettings.finalmask.quicParams.congestion' "$R_CONGESTION" \
           || { [ "$scenario" = forceDown ] && ! assert_field "$inbound" '.streamSettings.finalmask.quicParams.brutalUp' 80mbps; }; then
            record FAIL "$name (render differs)"
            continue
        fi
        if [ "$rate_case" = absent ]; then
            if ! printf '%s' "$inbound" | jq -e --arg field "$field" \
                '.streamSettings.finalmask.quicParams | has($field) | not' >/dev/null; then
                record FAIL "$name (field must actually be omitted)"
                continue
            fi
        elif ! assert_field "$inbound" ".streamSettings.finalmask.quicParams.$field" "$rate"; then
            record FAIL "$name (rendered rate differs)"
            continue
        fi
        dir="$scratch/brutal-rate-confs"
        config=$(jq -n --argjson inbound "$inbound" \
            '{inbounds:[$inbound],outbounds:[{protocol:"freedom"}]}')
        if ! _config_write_merged "$config" "$dir"; then
            record FAIL "$name (confdir write failed)"
            continue
        fi
        rc=0
        XRAY_LOCATION_ASSET="$ASSET_DIR" XRAY_JSON_STRICT=true \
            "$XRAY_BIN" run -test -confdir "$dir" </dev/null > "$scratch/brutal-rate.log" 2>&1 || rc=$?
        if [ "$validator_rc" -eq "$expected" ] && \
           { { [ "$expected" -eq 0 ] && [ "$rc" -eq 0 ] && grep -qF 'Configuration OK' "$scratch/brutal-rate.log"; } \
           || { [ "$expected" -eq 1 ] && [ "$rc" -ne 0 ] && grep -qF "$error_field must be at least 65536 bytes per second" "$scratch/brutal-rate.log"; }; }; then
            record PASS "$name (helper/core agree, expected rc=$expected)"
        else
            record FAIL "$name (helper rc=$validator_rc, core rc=$rc, expected=$expected; expected error=$error_field minimum)"
            tail -n 8 "$scratch/brutal-rate.log" >&2
        fi
    done
done

if [ -n "$ws" ] && [ -n "$ss" ] && [ -n "$hy" ]; then
    legacy=$(jq -n --argjson ws "$ws" --argjson ss "$ss" --argjson hy "$hy" \
        --arg asset "$ASSET_DIR" \
        '{env:{XRAY_LOCATION_ASSET:$asset},log:{loglevel:"warning"},routing:{rules:[]},
          inbounds:[$ws,$ss,$hy],outbounds:[{protocol:"freedom",tag:"direct"}]}')
    printf '%s\n' "$legacy" > "$LEGACY_CONFIG_FILE"
    if _config_migrate_legacy && [ ! -e "$LEGACY_CONFIG_FILE" ] && [ -s "${LEGACY_CONFIG_FILE}.bak" ] \
       && [ "$(cat "$scratch/service-calls")" = create ] \
       && [ "$(printf '%s' "$legacy" | jq -cS .)" = "$(_config_merged | jq -cS .)" ]; then
        test_confdir legacy-migration "$CONFIG_DIR"
        if _config_migrate_legacy && [ "$(cat "$scratch/service-calls")" = create ] \
           && [ "$(printf '%s' "$legacy" | jq -cS .)" = "$(_config_merged | jq -cS .)" ]; then
            record PASS 'legacy-migration-idempotent (config and service stub unchanged)'
        else
            record FAIL legacy-migration-idempotent
        fi
    else
        record FAIL 'legacy-migration (rename, semantic preservation or isolated service stub failed)'
    fi
else
    record FAIL 'legacy-migration (missing rendered inbound)'
fi
printf 'RESULT: %s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
