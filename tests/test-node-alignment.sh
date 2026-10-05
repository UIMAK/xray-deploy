#!/bin/bash
# Offline node contracts; only temporary fixtures are changed, never host services.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'case "$TMP" in "${TMPDIR:-/tmp}"/tmp.*) rm -rf "$TMP" ;; esac' EXIT
DEPLOY_DIR="$TMP"
. "$ROOT/lib/50-nodes.sh"
. "$ROOT/lib/51-reality-pq.sh"
NODES_DIR="$TMP/nodes" CERT_DIR="$TMP/certs" STATE_DIR="$TMP/state"
mkdir -p "$NODES_DIR" "$CERT_DIR" "$STATE_DIR"
GREEN= RED= YELLOW= NC= CYAN= SKYBLUE=
passed=0 failed=0
check() { local label="$1"; shift; if "$@"; then passed=$((passed+1)); else failed=$((failed+1)); printf 'FAIL: %s\n' "$label"; fi; }
eq() { [ "$1" = "$2" ]; }
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { ! contains "$1" "$2"; }
_info() { :; }; _tip() { :; }; _success() { :; }; _warn() { :; }; _error() { printf '%s\n' "$*" >> "$TMP/errors"; }
_url_encode() { jq -rn --arg v "$1" '$v | @uri'; }
_yaml_dq() { local v; v=$(jq -rn --arg v "$1" '$v | @json'); printf '%s' "${v:1:${#v}-2}"; }
_read_hop_ranges_display() { :; }
_config_jq() { printf call >> "$TMP/preflight"; return 1; }
_ensure_unique_name() { return 0; }
_tpl_path() { printf '%s/templates/%s.server.jsonc' "$ROOT" "$1"; }
_commit_node_txn_locked() { printf '%s' "$2" > "$TMP/inbound.json"; printf '%s' "$3" > "$TMP/committed.json"; }

# Render and execute the real creation transaction; metadata retains server direction.
R_LISTEN=0.0.0.0 R_PORT=443 R_TAG=hy2-test R_AUTH=secret
R_CERT_FILE=/fixture/cert.pem R_KEY_FILE=/fixture/key.pem R_CONGESTION=bbr
_render_template "$ROOT/templates/hysteria2.server.jsonc" > "$TMP/rendered.json"
check 'new settings.clients auth' jq -e '.settings.clients[0].auth == "secret" and (.settings | has("users") | not)' "$TMP/rendered.json"
check 'default masquerade omitted' jq -e '.streamSettings.hysteriaSettings | has("masquerade") | not' "$TMP/rendered.json"
check 'network and version unchanged' jq -e '.streamSettings.network == "hysteria" and .settings.version == 2 and .streamSettings.hysteriaSettings.version == 2' "$TMP/rendered.json"
for up in '' 0 '0 mbps' 00.0mbps bad 1kbps 0.01mbps 10kbps 65534bps 65535bps 100kbps 524287bps 511.999kbps 0.499999mbps 1watts '1 000kbps' '1 k bps'; do
    rc=0
    _commit_hy2_node_txn_locked hy2-test node server 443 0.0.0.0 secret sni false '' force-brutal "$up" '' '' '' '' /fixture/cert.pem /fixture/key.pem || rc=$?
    check "force-brutal rejects [$up] before mutation" eq "$rc" 1
    check "force-brutal [$up] no config preflight" test ! -e "$TMP/preflight"
    check "force-brutal [$up] no committed state" test ! -e "$TMP/committed.json"
done
for up in '100 mbps' 10m 1g '0.5 gbps' 524288 524288b 524288bps 512k 512kb 512kbps 0.5m 0.5mb .5mbps ' 0.5 MBPS ' 1tbps; do
    check "positive force bandwidth [$up]" _hy2_force_brutal_up_valid "$up"
done
rc=0
_commit_hy2_node_txn_locked hy2-test node server 443 0.0.0.0 secret sni false '' force-brutal '80 mbps' '20 mbps' '' '' '' /fixture/cert.pem /fixture/key.pem || rc=$?
check 'valid force transaction succeeds' eq "$rc" 0
check 'new auth survives real transaction' jq -e '.settings.clients[0].auth == "secret"' "$TMP/inbound.json"
check 'server direction preserved in config' jq -e '.streamSettings.finalmask.quicParams | .brutalUp == "80 mbps" and .brutalDown == "20 mbps"' "$TMP/inbound.json"
check 'server direction preserved in metadata' jq -e '.brutal_up == "80 mbps" and .brutal_down == "20 mbps"' "$TMP/committed.json"
link=$(_rebuild_hy2_link "$TMP/committed.json")
line=$(_hy2_clash_line "$TMP/committed.json")
check 'URI client upload is server download' contains "$link" '&up=20%20mbps'
check 'URI client download is server upload' contains "$link" '&down=80%20mbps'
check 'Clash client upload is server download' contains "$line" 'up: "20 mbps"'
check 'Clash client download is server upload' contains "$line" 'down: "80 mbps"'
rc=0
_commit_hy2_node_txn_locked hy2-test node server 443 0.0.0.0 secret sni false '' brutal '' '' '' '' '' /fixture/cert.pem /fixture/key.pem || rc=$?
check 'ordinary brutal empty bandwidth remains accepted' eq "$rc" 0
check 'ordinary brutal empty omits both fields' jq -e '.streamSettings.finalmask.quicParams | has("brutalUp") or has("brutalDown") | not' "$TMP/inbound.json"
link=$(_rebuild_hy2_link "$TMP/committed.json")
line=$(_hy2_clash_line "$TMP/committed.json")
check 'ordinary brutal URI empty omits upload' lacks "$link" '&up='
check 'ordinary brutal Clash empty omits upload' lacks "$line" ', up:'

# Both CDN transports preserve existing Firefox and default absent fp to Chrome.
for proto in vless-xhttp-cdn vless-ws-cdn; do
    jq -n --arg p "$proto" '{protocol:$p,name:"cdn",link_addr:"edge",port:443,uuid:"id",host:"site.example",path:"/path",fp:"firefox"}' > "$TMP/cdn.json"
    link=$(_rebuild_cdn_link "$TMP/cdn.json"); line=$(_rebuild_clash_line "$TMP/cdn.json")
    check "$proto URI preserves Firefox" contains "$link" '&fp=firefox&'
    check "$proto Clash preserves Firefox" contains "$line" '"client-fingerprint": "firefox"'
    jq 'del(.fp)' "$TMP/cdn.json" > "$TMP/default.json"
    link=$(_rebuild_cdn_link "$TMP/default.json"); line=$(_rebuild_clash_line "$TMP/default.json")
    check "$proto URI defaults Chrome" contains "$link" '&fp=chrome&'
    check "$proto Clash defaults Chrome" contains "$line" '"client-fingerprint": "chrome"'
done

# Invoke the real PQ decision using deterministic local command output.
XRAY_BIN="$TMP/xray"
printf '#!/bin/bash\nexit 99\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
seed=$(printf '%043d' 0); seed=${seed//0/A}
verify=$(printf '%02603d' 0); verify=${verify//0/B}; verify="${verify:0:2602}A"
PING_RC=0 CHAIN_LENGTH=3501
_pq_run_bounded() {
    printf '%s\n' "$*" >> "$TMP/probes"
    case "$*" in
        *' tls ping '*) printf "X25519MLKEM768\nCertificate chain's total length: %s\n" "$CHAIN_LENGTH"; return "$PING_RC" ;;
        *' mldsa65') printf 'Verify: %s\nSeed: %s\n' "$verify" "$seed" ;;
        *) return 99 ;;
    esac
}
: > "$TMP/probes"
rc=0; _detect_reality_pq example:443 || rc=$?
check 'PQ supported output accepted' eq "$rc" 0
check 'PQ labelled seed output' eq "$PQ_SEED" "$seed"
check 'PQ labelled verify output' eq "$PQ_VERIFY" "$verify"
ping_count=0 key_count=0
while IFS= read -r command; do
    case "$command" in *' tls ping '*) ping_count=$((ping_count+1)) ;; *' mldsa65') key_count=$((key_count+1)) ;; esac
done < "$TMP/probes"
check 'PQ only one TLS ping' eq "$ping_count" 1
check 'PQ one local key command' eq "$key_count" 1
CHAIN_LENGTH=3500
rc=0; _detect_reality_pq example:443 || rc=$?
check 'PQ chain threshold is strictly greater than 3500' eq "$rc" 1
PING_RC=124
rc=0; _detect_reality_pq example:443 || rc=$?
check 'PQ probe failure unknown not unsupported' eq "$rc" 2
printf 'node-alignment: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
