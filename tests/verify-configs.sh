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
record() {
    if [ "$1" = PASS ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
    printf '%s: %s\n' "$1" "$2"
}
assert_field() {
    local json="$1" filter="$2" expected="$3"
    printf '%s' "$json" | jq -e --arg expected "$expected" "($filter) == \$expected" >/dev/null
}
# Check the current template, not a copied schema or substituted fixture.
assert_placeholder() {
    local tpl="$1" key="$2" placeholder="$3"
    grep -qF "\"$key\": \"$placeholder\"" "$tpl"
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

R_LISTEN=127.0.0.1
R_PORT=18443
R_TAG=config-test-ws
R_UUID=5783a3e7-e373-51cd-8642-c83782b807c5
R_DECRYPTION=none
R_PATH='/config-test?left=1&right=2&ed=2560'
ws_tpl="$repo/templates/vless-ws-cdn.server.jsonc"
assert_placeholder "$ws_tpl" path '{{PATH}}'
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
assert_placeholder "$ss_tpl" password '{{PASSWORD}}'
if ss=$(_render_template "$ss_tpl") && assert_field "$ss" '.settings.password' "$R_PASSWORD"; then
    check_rendered shadowsocks-password-ampersand "$ss"
else
    record FAIL 'shadowsocks-password-ampersand (rendered password differs or render failed)'
    ss=''
fi

hy_tpl="$repo/templates/hysteria2.server.jsonc"
# Optional JSON blocks mean this template is parsed only after actual rendering.
grep -qF '"auth": "{{AUTH}}"' "$hy_tpl"
grep -qF '"udp": [{{OBFS_MASK_BLOCK}}]' "$hy_tpl"
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
    if ! inbound=$(_render_template "$hy_tpl") || ! assert_field "$inbound" '.settings.users[0].auth' "$R_AUTH"; then
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
        assert_field "$inbound" '.streamSettings.finalmask.quicParams.brutalUp' '20 mbps'
        assert_field "$inbound" '.streamSettings.finalmask.quicParams.brutalDown' '40 mbps'
    fi
    check_rendered "$name" "$inbound"
    hy="$inbound"
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
printf 'RESULT: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
