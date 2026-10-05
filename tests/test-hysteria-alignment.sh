#!/usr/bin/env bash
# Offline official-Hysteria behavior; service and bootstrap publication are local stubs.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hysteria-alignment.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }
reject() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi; }
contains() { [[ "$2" == *"$1"* ]]; }
. "$ROOT/lib/00-common.sh"
. "$ROOT/lib/50-nodes.sh"
. "$ROOT/lib/55-hysteria.sh"
DEPLOY_DIR="$TMP/deploy" BIN_DIR="$TMP/bin" LOG_DIR="$TMP/log"
HYSTERIA_DATA_DIR="$TMP/hysteria"
HYSTERIA_BACKUP_DIR="$TMP/backups"
HYSTERIA_CONFIG="$TMP/config.json"
HYSTERIA_SERVER_META="$TMP/server.json"
HYSTERIA_NODE_META="$TMP/node.json"
HYSTERIA_CERT_DIR="$TMP/certs"
HYSTERIA_ACME_DIR="$TMP/acme"
CLASH_YAML="$TMP/clash.yaml"
mkdir -p "$DEPLOY_DIR" "$BIN_DIR" "$LOG_DIR" "$HYSTERIA_DATA_DIR" "$HYSTERIA_BACKUP_DIR"
_error() { printf '%s\n' "$*" >&2; }
_warn() { printf '%s\n' "$*" >&2; }
_info() { :; }
_success() { :; }
_tip() { :; }
_press_any_key() { :; }
clear() { :; }
_with_config_lock() { "$@"; }
_hysteria_installed() { return 0; }
_hysteria_runtime_state() { printf stopped; }
_hysteria_validate_transient() { return 0; }
_hysteria_recover_to_state() { return 0; }
_hysteria_rebuild_all_links() { return 0; }
base='{"listen":":443","auth":{"type":"password","password":"pw"},"obfs":{"type":"gecko","gecko":{"password":"shape"}}}'
printf '%s\n' '{"tls_mode":"custom","sni":"","pin":""}' > "$HYSTERIA_SERVER_META"
printf '%s\n' '{"auth":"pw","name":"offline","link_addr":"connect.example.com"}' > "$HYSTERIA_NODE_META"
set_sizes() { jq --argjson sizes "$1" '.obfs.gecko += $sizes' <<< "$base" > "$HYSTERIA_CONFIG"; }

printf '== Gecko defaults and exports ==\n'
for sizes in '{}' '{"minPacketSize":0,"maxPacketSize":0}' '{"minPacketSize":0,"maxPacketSize":1200}' '{"minPacketSize":512,"maxPacketSize":0}'; do
    set_sizes "$sizes"
    eq "Gecko defaults $sizes" default "$(_hysteria_gecko_size_state)"
    eq "Gecko defaults have no URI gap $sizes" '' "$(_hysteria_obfs_uri_gap)"
    check "Gecko default URI exports $sizes" _hysteria_build_link "$HYSTERIA_NODE_META"
done
set_sizes '{"minPacketSize":0,"maxPacketSize":0}'
line=$(_hysteria_clash_line "$HYSTERIA_NODE_META")
check 'zero minimum exports effective YAML 512' contains 'obfs-min-packet-size: 512' "$line"
check 'zero maximum exports effective YAML 1200' contains 'obfs-max-packet-size: 1200' "$line"
eq 'zero desc uses effective defaults' 'min=512 max=1200' "$(_hysteria_gecko_size_desc)"
for sizes in '{"minPacketSize":0,"maxPacketSize":1000}' '{"minPacketSize":256,"maxPacketSize":0}' '{"minPacketSize":256,"maxPacketSize":1024}'; do
    set_sizes "$sizes"
    eq "custom Gecko accepted $sizes" custom "$(_hysteria_gecko_size_state)"
    reject "custom Gecko URI rejected $sizes" _hysteria_build_link "$HYSTERIA_NODE_META"
    check "custom Gecko YAML accepted $sizes" _hysteria_clash_line "$HYSTERIA_NODE_META"
done
for sizes in '{"minPacketSize":"0"}' '{"minPacketSize":null}' '{"minPacketSize":512.5}' '{"minPacketSize":-1}' '{"maxPacketSize":2049}' '{"minPacketSize":0,"maxPacketSize":511}' '{"minPacketSize":1201,"maxPacketSize":0}'; do
    set_sizes "$sizes"
    eq "invalid Gecko rejected $sizes" invalid "$(_hysteria_gecko_size_state)"
    reject "invalid Gecko URI rejected $sizes" _hysteria_build_link "$HYSTERIA_NODE_META"
    reject "invalid Gecko YAML rejected $sizes" _hysteria_clash_line "$HYSTERIA_NODE_META"
done
for shape in '[]' '"bad"'; do
    jq --argjson shape "$shape" '.obfs.gecko = $shape' <<< "$base" > "$HYSTERIA_CONFIG"
    eq "Gecko shape rejected $shape" invalid "$(_hysteria_gecko_size_state)"
done
printf 'not-json\n' > "$HYSTERIA_CONFIG"
eq 'malformed JSON fails closed' invalid "$(_hysteria_gecko_size_state)"

printf '== bandwidth validation and owned leaves ==\n'
for value in '0mbps' '0 bps' '0 TBPS' '524288 bps' '1mbps' ' 1 mbps '; do
    eq "legal official bandwidth [$value]" '' "$(_hysteria_bandwidth_reason "$value")"
done
for value in '524280 bps' '1kbps' '1.5mbps' '100 m bps' '0oops' 'mbps' '100'; do
    check "illegal official bandwidth [$value]" test -n "$(_hysteria_bandwidth_reason "$value")"
done
jq '.bandwidth={up:"10 mbps",down:"20 mbps",disableLossCompensation:true,manual:{value:7}} | .quic={maxIdleTimeout:"30s"}' <<< "$base" > "$HYSTERIA_CONFIG"
_hysteria_bandwidth_menu <<< $'1\n30m\n40m\n' > "$TMP/menu.log" 2>&1
eq 'bandwidth setting changes up' '30 mbps' "$(jq -r '.bandwidth.up' "$HYSTERIA_CONFIG")"
eq 'bandwidth setting changes down' '40 mbps' "$(jq -r '.bandwidth.down' "$HYSTERIA_CONFIG")"
check 'bandwidth setting preserves unowned fields' jq -e '.bandwidth.disableLossCompensation == true and .bandwidth.manual.value == 7 and .quic.maxIdleTimeout == "30s"' "$HYSTERIA_CONFIG"
_hysteria_bandwidth_menu <<< $'1\n\n\n' > "$TMP/menu.log" 2>&1
eq 'blank bandwidth input retains current up' '30 mbps' "$(jq -r '.bandwidth.up' "$HYSTERIA_CONFIG")"
_hysteria_bandwidth_menu <<< $'2\n' > "$TMP/menu.log" 2>&1
check 'bandwidth clear deletes only up/down' jq -e '.bandwidth | has("up") == false and has("down") == false and .disableLossCompensation == true and .manual.value == 7' "$HYSTERIA_CONFIG"

jq '.bandwidth={up:"10 mbps",down:"20 mbps"}' <<< "$base" > "$HYSTERIA_CONFIG"
_hysteria_bandwidth_menu <<< $'2\n' > "$TMP/menu.log" 2>&1
check 'bandwidth clear removes empty object' jq -e 'has("bandwidth") == false' "$HYSTERIA_CONFIG"
jq '.bandwidth={}' <<< "$base" > "$HYSTERIA_CONFIG"
_hysteria_bandwidth_menu <<< $'1\n\n\n' > "$TMP/menu.log" 2>&1
check 'empty bandwidth setting removes empty object' jq -e 'has("bandwidth") == false' "$HYSTERIA_CONFIG"

printf '== failed bandwidth validation restores config ==\n'
(
    jq '.bandwidth={up:"10 mbps",down:"20 mbps",disableLossCompensation:true,manual:{value:7}}' <<< "$base" > "$HYSTERIA_CONFIG"
    cp "$HYSTERIA_CONFIG" "$TMP/before.json"
    _hysteria_runtime_state() { printf running; }
    _hysteria_restart_verified() { printf 'restart\n' >> "$TMP/restarts"; return 1; }
    _hysteria_bandwidth_menu <<< $'1\n30m\n40m\n'
) > "$TMP/rollback.log" 2>&1
eq 'failed running restart rolls back all bandwidth fields' "$(jq -Sc . "$TMP/before.json")" "$(jq -Sc . "$HYSTERIA_CONFIG")"
eq 'running rollback attempts old config restart' 2 "$(wc -l < "$TMP/restarts" | tr -d ' ')"
check 'failed rollback reports degraded service state' grep -q '降级: 配置已回滚, 但服务未能恢复运行' "$TMP/rollback.log"

printf '== SNI and single-range manager ==\n'
printf cert > "$TMP/custom.crt"
printf key > "$TMP/custom.key"
openssl() { printf 'subject=CN = certificate.example.com\n'; }
check 'custom TLS empty SNI accepted' _hysteria_prompt_tls <<< $'2\n'"$TMP/custom.crt"$'\n'"$TMP/custom.key"$'\n\n' > "$TMP/tls.log" 2>&1
eq 'empty SNI never becomes certificate CN/SAN' '' "$HY_TLS_SNI"
check 'custom TLS config retains paths' jq -e --arg c "$TMP/custom.crt" --arg k "$TMP/custom.key" '.tls.cert == $c and .tls.key == $k' <<< "$HY_TLS_JSON"
set_sizes '{}'
uri=$(_hysteria_build_link "$HYSTERIA_NODE_META")
check 'empty SNI URI uses connection host' contains '@connect.example.com:443/' "$uri"
if contains 'sni=' "$uri"; then fail 'empty SNI URI omits override'; else pass 'empty SNI URI omits override'; fi
line=$(_hysteria_clash_line "$HYSTERIA_NODE_META")
if contains ', sni:' "$line"; then fail 'empty SNI YAML omits override'; else pass 'empty SNI YAML omits override'; fi
_hysteria_prompt_tls <<< $'2\n'"$TMP/custom.crt"$'\n'"$TMP/custom.key"$'\nexplicit.example.com\n' > "$TMP/tls.log" 2>&1
eq 'explicit SNI retained' explicit.example.com "$HY_TLS_SNI"
eq 'single range accepted' '' "$(_hysteria_hop_reason '20000-30000')"
reason=$(_hysteria_hop_reason '20000-30000,40000-50000')
check 'multi-range warning identifies manager limitation' contains '本管理器' "$reason"
check 'multi-range warning acknowledges official support' contains '官方 listen 支持多段' "$reason"
reject 'manager listen parser refuses multi-range' _hysteria_listen_port_part ':20000-30000,40000-50000'

printf '== bootstrap zero bandwidth ==\n'
# Exercise the complete input/JSON assembly path without publishing files or starting a service.
(
    HYSTERIA_CONFIG="$TMP/not-yet-created.json"
    _hysteria_installed() { return 0; }
    _gen_random_port() { printf 443; }
    _hysteria_check_hop_conflicts() { return 0; }
    _hysteria_prompt_tls() { HY_TLS_JSON='{"tls":{"cert":"cert","key":"key"}}'; HY_TLS_MODE=custom; HY_TLS_SNI=''; HY_TLS_PIN=''; }
    _ask_link_addr() { printf connect.example.com; }
    _hysteria_name_taken() { return 1; }
    _hysteria_bootstrap_locked() { printf '%s\n' "$1" > "$TMP/bootstrap.json"; }
    _hysteria_print_link() { :; }
    _hysteria_tls_desc() { printf custom; }
    _hysteria_bootstrap <<< $'443\n\n3\n0mbps\n0mbps\n\n\n\npw\noffline\n'
) > "$TMP/bootstrap.log" 2>&1
check 'bootstrap zero bandwidth reaches JSON publication' test -f "$TMP/bootstrap.json"
if [ -f "$TMP/bootstrap.json" ]; then
    check 'bootstrap keeps explicit zero unlimited values' jq -e '.bandwidth.up == "0mbps" and .bandwidth.down == "0mbps" and .auth == {type:"password",password:"pw"}' "$TMP/bootstrap.json"
fi
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
