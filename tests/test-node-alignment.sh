#!/bin/bash
# Offline node contracts; only temporary fixtures are changed, never host services.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'case "$TMP" in "${TMPDIR:-/tmp}"/tmp.*) rm -rf "$TMP" ;; esac' EXIT
(
. "$ROOT/lib/00-common.sh"
DEPLOY_DIR="$TMP"
CONFIG_DIR="$TMP/confs" BACKUP_DIR="$TMP/state/backup"
. "${NODE_ALIGNMENT_NODES_MODULE:-$ROOT/lib/50-nodes.sh}"
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
actual_config_jq=$(declare -f _config_jq)
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

# Exercise both directions through creation, with an existing byte snapshot to protect.
creation_fixture() {
    printf '{"existing":"config"}\n' > "$TMP/inbound.json"
    printf '{"existing":"metadata"}\n' > "$TMP/committed.json"
    cp "$TMP/inbound.json" "$TMP/before-inbound.json"
    cp "$TMP/committed.json" "$TMP/before-committed.json"
    : > "$TMP/preflight"
    : > "$TMP/errors"
}
creation_invoke() {
    rc=0
    _commit_hy2_node_txn_locked hy2-test node server 443 0.0.0.0 secret sni false '' "$1" "$2" "$3" '' '' '' /fixture/cert.pem /fixture/key.pem || rc=$?
}
creation_rejected() {
    local label="$1"
    check "$label rejects" eq "$rc" 1
    check "$label rejects before config preflight" test ! -s "$TMP/preflight"
    check "$label preserves config bytes" cmp -s "$TMP/before-inbound.json" "$TMP/inbound.json"
    check "$label preserves metadata bytes" cmp -s "$TMP/before-committed.json" "$TMP/committed.json"
    check "$label reports invalid rate" test -s "$TMP/errors"
}
creation_committed() {
    local label="$1" cc="$2" up="$3" down="$4"
    check "$label succeeds" eq "$rc" 0
    check "$label config direction and empty omission" jq -e --arg cc "$cc" --arg up "$up" --arg down "$down" '
        .streamSettings.finalmask.quicParams == ({congestion: $cc}
            + (if $up == "" then {} else {brutalUp: $up} end)
            + (if $down == "" then {} else {brutalDown: $down} end))' "$TMP/inbound.json"
    check "$label metadata direction" jq -e --arg cc "$cc" --arg up "$up" --arg down "$down" '
        .congestion == $cc and .brutal_up == $up and .brutal_down == $down' "$TMP/committed.json"
}
for rate in 1bps 7bps 0.000001mbps 1kbps 65535bps 524287bps not-a-rate 1watts; do
    for target in brutal-up brutal-down force-down; do
        cc=brutal up='80 mbps' down='20 mbps'
        case "$target" in
            brutal-up) up="$rate" ;;
            brutal-down) down="$rate" ;;
            force-down) cc=force-brutal down="$rate" ;;
        esac
        creation_fixture
        creation_invoke "$cc" "$up" "$down"
        creation_rejected "creation $target=[$rate]"
    done
done
for rate in 524288bps 512kbps 0.5mbps 0 '0 mbps' 00.000kbps ''; do
    check "shared rate accepts [$rate]" _hy2_brutal_rate_valid "$rate"
    for target in brutal-up brutal-down force-down; do
        cc=brutal up='80 mbps' down='20 mbps'
        case "$target" in
            brutal-up) up="$rate" ;;
            brutal-down) down="$rate" ;;
            force-down) cc=force-brutal down="$rate" ;;
        esac
        creation_fixture
        creation_invoke "$cc" "$up" "$down"
        creation_committed "creation $target=[$rate]" "$cc" "$up" "$down"
    done
done
for rate in 1bps 7bps 0.000001mbps 1kbps 65535bps 524287bps not-a-rate 1watts; do
    rc=0; _hy2_brutal_rate_valid "$rate" || rc=$?
    check "shared rate rejects [$rate]" eq "$rc" 1
done
for rate in 524288bps 512kbps 0.5mbps; do
    creation_fixture
    creation_invoke force-brutal "$rate" ''
    creation_committed "creation force-up=[$rate]" force-brutal "$rate" ''
done

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

# Real port transactions and recovery run against confdir/metadata fixtures; no host locks/services.
eval "$actual_config_jq"
_with_config_lock() { "$@"; }
_restart_xray_verified() { return 0; }
_warn() { printf '%s\n' "$*" >> "$TMP/warnings"; }
reality_fixture() {
    local dir="$1" shared="$2" addr_key="$3" peer_host="${4:-127.0.0.1}"
    DEPLOY_DIR="$TMP/$dir" CONFIG_DIR="$TMP/$dir/confs" NODES_DIR="$TMP/$dir/nodes"
    BACKUP_DIR="$TMP/$dir/backup" CLASH_YAML="$TMP/$dir/clash.yaml"
    mkdir -p "$CONFIG_DIR" "$NODES_DIR"
    jq -n --arg key "$addr_key" --arg peer "$peer_host:10443" --argjson shared "$shared" '
        {inbounds:[
            {tag:"xd-reality-vision-443",protocol:"vless",port:443,
             streamSettings:{network:"raw",security:"reality",realitySettings:{target:"127.0.0.1:10443",serverNames:["site.example"]}}},
            {tag:"tunnel-site-10443-443",protocol:"tunnel",listen:"127.0.0.1",port:10443,
             settings:{($key):"site.example",rewritePort:443,allowedNetwork:"tcp"}}
        ] + (if $shared then [{tag:"xd-reality-xhttp-9443",protocol:"vless",port:9443,
             streamSettings:{network:"xhttp",security:"reality",realitySettings:{target:$peer,serverNames:["site.example"]}}}] else [] end),
         routing:{rules:[{type:"field",inboundTag:["tunnel-site-10443-443"],domain:["full:site.example"],outboundTag:"direct"}]}}
    ' > "$DEPLOY_DIR/config-before.json"
    _config_write_merged "$(cat "$DEPLOY_DIR/config-before.json")" || return 1
    for tag in xd-reality-vision-443 xd-reality-xhttp-9443; do
        [ "$shared" = true ] || [ "$tag" = xd-reality-vision-443 ] || continue
        local port="${tag##*-}" proto=vless-tcp-reality-vision
        [ "$port" = 9443 ] && proto=vless-xhttp-reality
        jq -n --arg tag "$tag" --argjson p "$port" --arg proto "$proto" '
            {tag:$tag,protocol:$proto,port:$p,name:("Reality-"+($p|tostring)),reality_mode:"tunnel",
             tunnel_tag:"tunnel-site-10443-443",tunnel_port:10443,sni:"site.example",uuid:"id",
             link_addr:"edge.example",public_key:"key",short_id:"abcd",path:"/path",share_link:"old"}
        ' > "$NODES_DIR/$tag.json"
    done
}
for addr_key in address rewriteAddress; do
    for peer_host in 127.0.0.1 '[::1]' localhost 127.0.0.2; do
        label="shared $addr_key $peer_host"
        reality_fixture "shared-$addr_key-$peer_host" true "$addr_key" "$peer_host" || exit 1
        cp "$NODES_DIR/xd-reality-xhttp-9443.json" "$DEPLOY_DIR/peer-before.json"
        rc=0; _reality_port_txn xd-reality-vision-443 "$NODES_DIR/xd-reality-vision-443.json" 443 8443 || rc=$?
        check "$label A port transaction succeeds" eq "$rc" 0
        check "$label A metadata keeps tunnel identity" jq -e '.tag == "xd-reality-vision-8443" and .port == 8443 and .tunnel_tag == "tunnel-site-10443-443" and .tunnel_port == 10443 and (.share_link | contains(":8443?"))' "$NODES_DIR/xd-reality-vision-8443.json"
        check "$label peer metadata bytes unchanged" cmp -s "$DEPLOY_DIR/peer-before.json" "$NODES_DIR/xd-reality-xhttp-9443.json"
        _config_merged > "$DEPLOY_DIR/config-after.json"
        check "$label only A config tag/port changes" jq -e --slurpfile before "$DEPLOY_DIR/config-before.json" 'del(.inbounds[0].tag,.inbounds[0].port) == ($before[0] | del(.inbounds[0].tag,.inbounds[0].port)) and .inbounds[0].tag == "xd-reality-vision-8443" and .inbounds[0].port == 8443' "$DEPLOY_DIR/config-after.json"
        check "$label no completed journal remains" test ! -e "$NODES_DIR/xd-reality-vision-443.json.porttxn"
        rc=0; _reality_port_txn xd-reality-xhttp-9443 "$NODES_DIR/xd-reality-xhttp-9443.json" 9443 10444 || rc=$?
        check "$label B remains manageable" eq "$rc" 0
        check "$label B metadata keeps tunnel identity" jq -e '.port == 10444 and .tunnel_tag == "tunnel-site-10443-443"' "$NODES_DIR/xd-reality-xhttp-10444.json"
        check "$label B change leaves A port intact" _config_jq -e '[.inbounds[] | select(.tag == "xd-reality-vision-8443" and .port == 8443)] | length == 1'
    done
    reality_fixture "single-$addr_key" false "$addr_key" || exit 1
    rc=0; _reality_port_txn xd-reality-vision-443 "$NODES_DIR/xd-reality-vision-443.json" 443 8443 || rc=$?
    check "single $addr_key transaction succeeds" eq "$rc" 0
    check "single $addr_key tunnel still renamed" jq -e '.tunnel_tag == "tunnel-site-10443-8443"' "$NODES_DIR/xd-reality-vision-8443.json"
    check "single $addr_key route follows renamed tunnel" _config_jq -e '.routing.rules[0].inboundTag == ["tunnel-site-10443-8443"]'
    check "single $addr_key address/port untouched" _config_jq -e --arg key "$addr_key" '.inbounds[1] | .tag == "tunnel-site-10443-8443" and .port == 10443 and .settings[$key] == "site.example" and .settings.rewritePort == 443'
done

# Interrupt after metadata commit, and after config commit, using the actual journal writer.
for committed in false true; do
    reality_fixture "recover-$committed" true rewriteAddress || exit 1
    orig=$(cat "$NODES_DIR/xd-reality-vision-443.json")
    next=$(jq '.tag="xd-reality-vision-8443" | .port=8443 | .name="Reality-8443"' <<< "$orig")
    _port_txn_journal_write "$NODES_DIR/xd-reality-vision-443.json" "$NODES_DIR/xd-reality-vision-8443.json" reality 443 8443 '' "$orig" "$next" || exit 1
    _atomic_write_json "$NODES_DIR/xd-reality-vision-8443.json" "$next" || exit 1
    rm "$NODES_DIR/xd-reality-vision-443.json"
    if [ "$committed" = true ]; then
        _mutate_config '(.inbounds[0].tag)="xd-reality-vision-8443" | .inbounds[0].port=8443' || exit 1
        expected="$NODES_DIR/xd-reality-vision-8443.json" expected_port=8443
    else
        expected="$NODES_DIR/xd-reality-vision-443.json" expected_port=443
    fi
    rc=0; _port_txn_recover || rc=$?
    check "shared recovery committed=$committed succeeds" eq "$rc" 0
    check "shared recovery committed=$committed metadata reconciles" jq -e --argjson p "$expected_port" '.port == $p and .tunnel_tag == "tunnel-site-10443-443"' "$expected"
    check "shared recovery committed=$committed journal cleaned" test ! -e "$NODES_DIR/xd-reality-vision-443.json.porttxn"
    check "shared recovery committed=$committed preserves tunnel" _config_jq -e '.inbounds[1].tag == "tunnel-site-10443-443" and .routing.rules[0].inboundTag == ["tunnel-site-10443-443"] and .inbounds[2].port == 9443'
done

# Missing congestion makes the real URI builder fail while the real Clash builder still succeeds.
DEPLOY_DIR="$TMP/derived" CLASH_YAML="$TMP/derived/clash.yaml"
mkdir -p "$DEPLOY_DIR"
hy2_derived_fixture() {
    jq -n '{tag:"hy2-test",protocol:"hysteria2",name:"hy2-new",auth:"secret",link_addr:"edge.example",port:443,sni:"site.example",congestion:"bbr",share_link:"old-link"}' > "$DEPLOY_DIR/meta.json"
    printf 'proxies:\n  - {name: "hy2-old", type: hysteria2, server: "old", port: 443}\n' > "$CLASH_YAML"
    : > "$TMP/warnings"
}
hy2_derived_fixture
_meta_update "$DEPLOY_DIR/meta.json" 'del(.congestion)' || exit 1
rc=0; _hy2_sync_derived "$DEPLOY_DIR/meta.json" hy2-old || rc=$?
check 'Hy2 URI failure with Clash success returns nonzero' eq "$rc" 1
check 'Hy2 URI failure preserves old link' jq -e '.share_link == "old-link"' "$DEPLOY_DIR/meta.json"
check 'Hy2 URI failure still updates Clash' grep -qF 'name: "hy2-new"' "$CLASH_YAML"
check 'Hy2 URI failure removes old Clash name' lacks "$(cat "$CLASH_YAML")" 'name: "hy2-old"'
check 'Hy2 URI failure reports link warning' grep -qF '分享链接重建失败' "$TMP/warnings"
hy2_derived_fixture
_meta_update "$DEPLOY_DIR/meta.json" '.obfs_type="salamander" | .obfs_password="obfs" | .obfs_packet_size="800-1000"' || exit 1
rc=0; _hy2_sync_derived "$DEPLOY_DIR/meta.json" hy2-old || rc=$?
check 'Hy2 custom Gecko unexpressible succeeds' eq "$rc" 0
check 'Hy2 custom Gecko clears old link' jq -e '.share_link == ""' "$DEPLOY_DIR/meta.json"
check 'Hy2 custom Gecko still exports full Clash dimensions' contains "$(cat "$CLASH_YAML")" 'obfs: gecko, obfs-password: "obfs", obfs-min-packet-size: 800, obfs-max-packet-size: 1000'
hy2_derived_fixture
rc=0; _hy2_sync_derived "$DEPLOY_DIR/meta.json" hy2-old || rc=$?
check 'Hy2 normal derived sync succeeds' eq "$rc" 0
check 'Hy2 normal derived sync rebuilds link' jq -e '.share_link | startswith("hy2://") and contains("@edge.example:443/")' "$DEPLOY_DIR/meta.json"
check 'Hy2 normal derived sync updates Clash' grep -qF 'name: "hy2-new"' "$CLASH_YAML"
check 'Hy2 normal derived sync removes old name' lacks "$(cat "$CLASH_YAML")" 'name: "hy2-old"'

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
# 自签证书生成 rc=2(生成器回滚不完整): 必须保留快照并把 2 上报, 不得静默降级成 1 或删掉旧证书副本。
_hy2_cert_reusable() { return 1; }
_gen_hy2_cert() { return 2; }
# 前面的用例把 DEPLOY_DIR/NODES_DIR 指向了别的 fixture 目录, 这里一并复位,
# 否则"未写节点文件"的断言会落在前一个 fixture 的目录上, 恒真。
DEPLOY_DIR="$TMP" CERT_DIR="$TMP/certs" NODES_DIR="$TMP/nodes"
mkdir -p "$NODES_DIR"
mkdir -p "$CERT_DIR/hy2-cert-rc2"
printf 'old-cert\n' > "$CERT_DIR/hy2-cert-rc2/cert.pem"
printf 'old-key\n' > "$CERT_DIR/hy2-cert-rc2/key.pem"
rm -rf "$TMP"/hy2cert.bak.*
rc=0
_commit_hy2_node_txn_locked hy2-cert-rc2 node server 443 0.0.0.0 secret sni true example.com '' '' '' '' '' '' /fixture/cert.pem /fixture/key.pem || rc=$?
check 'self-signed cert rc=2 is reported as 2' eq "$rc" 2
check 'self-signed cert rc=2 keeps a snapshot' bash -c 'compgen -G "$1/hy2cert.bak.*" >/dev/null' _ "$TMP"
check 'self-signed cert rc=2 snapshot holds the old cert' bash -c 'grep -qx "old-cert" "$1"/hy2cert.bak.*/cert.pem' _ "$TMP"
check 'self-signed cert rc=2 wrote no node file' test ! -e "$NODES_DIR/hy2-cert-rc2.json"

printf 'node-alignment: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
)
