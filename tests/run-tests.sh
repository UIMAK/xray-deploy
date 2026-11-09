#!/usr/bin/env bash
# 共享配置与 state 路径的离线回归。
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
if ! TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-deploy-test.XXXXXX"); then
    printf 'FAIL - cannot create temp dir\n' >&2
    exit 1
fi
trap 'rm -rf "${TMP:?}"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
check_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name (expected [$expected], got [$actual])"
    fi
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

. "$ROOT/lib/00-common.sh"
. "$ROOT/lib/10-system.sh"
. "$ROOT/lib/20-xray-core.sh"
. "$ROOT/lib/30-geo.sh"
. "$ROOT/lib/35-warp.sh"
. "$ROOT/lib/40-cloudflared.sh"
. "$ROOT/lib/45-logrotate.sh"
. "$ROOT/lib/50-nodes.sh"
. "$ROOT/lib/51-reality-pq.sh"
. "$ROOT/lib/52-outbounds.sh"
. "$ROOT/lib/55-hysteria.sh"
. "$ROOT/lib/90-menu.sh"

DEPLOY_DIR="$TMP/deploy"
CONFIG_DIR="$DEPLOY_DIR/confs"
BACKUP_DIR="$DEPLOY_DIR/backups"
STATE_DIR="$DEPLOY_DIR/state"
ASSET_DIR="$DEPLOY_DIR/assets"
NODES_DIR="$DEPLOY_DIR/nodes"
CERT_DIR="$DEPLOY_DIR/certs"
BIN_DIR="$DEPLOY_DIR/bin"
LOG_DIR="$DEPLOY_DIR/log"
GEO_LOG="$LOG_DIR/geo-update.log"
XRAY_BIN="$BIN_DIR/xray"
CF_BIN="$TMP/cloudflared"
HYSTERIA_DATA_DIR="$DEPLOY_DIR/hysteria"
HYSTERIA_BACKUP_DIR="$DEPLOY_DIR/hysteria-backups"
HYSTERIA_CERT_DIR="$DEPLOY_DIR/hysteria-certs"
HYSTERIA_CONFIG="$HYSTERIA_DATA_DIR/hysteria.json"
HYSTERIA_SERVER_META="$HYSTERIA_DATA_DIR/server_meta.json"
HYSTERIA_NODE_META="$HYSTERIA_DATA_DIR/node.json"
HYSTERIA_PID_FILE="$TMP/hysteria.pid"
HYSTERIA_SVC="hysteria"
INIT_SYSTEM=direct
mkdir -p "$DEPLOY_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$STATE_DIR" "$ASSET_DIR" \
    "$NODES_DIR" "$CERT_DIR" "$BIN_DIR" "$LOG_DIR" \
    "$HYSTERIA_DATA_DIR" "$HYSTERIA_BACKUP_DIR" "$HYSTERIA_CERT_DIR"
_deploy_lock_root() { printf '%s' "$TMP/locks"; }
mkdir -p "$TMP/locks"
_restart_xray_verified() { return 0; }
_maybe_drop_caches() { :; }

printf '== common validation ==\n'
check 'valid IPv4 accepted' _validate_listen 192.0.2.10
check 'valid IPv6 accepted' _validate_listen 2001:db8::1
if _validate_listen $'::1\ngarbage'; then fail 'multiline listen rejected'; else pass 'multiline listen rejected'; fi
if _validate_port 0; then fail 'invalid port rejected'; else pass 'invalid port rejected'; fi
check 'version compare' _xray_version_at_least 26.10.31 26.6.1
check_eq 'version tag canonicalization' v26.9.9 "$(_xray_canon_tag 26.9.9)"

printf '== config fragments ==\n'
rm -f "$CONFIG_DIR"/*.json
if _config_present; then fail 'empty config dir is not present'; else pass 'empty config dir is not present'; fi
check_eq 'empty config merges to {}' '{}' "$(_config_merged)"
if _config_write_merged 'not-json' >/dev/null 2>&1; then fail 'merge write rejects malformed JSON'; else pass 'merge write rejects malformed JSON'; fi

_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"debug"},"routing":{"rules":[]},"customTop":1}' >/dev/null 2>&1
if [ -f "$CONFIG_DIR/05_routing.json" ] && [ -f "$CONFIG_DIR/99_customTop.json" ]; then
    pass 'top-level fields map to fixed fragment names'
else
    fail 'top-level fields map to fixed fragment names'
fi
check_eq 'fragment keeps its top-level wrapper' routing "$(jq -r 'keys[0]' "$CONFIG_DIR/05_routing.json")"
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{},"geodata":{"cron":"30 4 * * *"}}' >/dev/null 2>&1
[ -f "$CONFIG_DIR/14_geodata.json" ] || fail 'geodata fragment is created'
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{}}' >/dev/null 2>&1
if [ -e "$CONFIG_DIR/14_geodata.json" ]; then fail 'removed field deletes its fragment'; else pass 'removed field deletes its fragment'; fi

_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"}}' >/dev/null 2>&1
_backup_config >/dev/null 2>&1
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"debug"}}' >/dev/null 2>&1
_restore_config >/dev/null 2>&1
check_eq 'backup restores the whole config directory' warning "$(_config_jq -r '.log.loglevel')"
if (
    _txn_allow_config_write() { return 1; }
    _mutate_config '.log.loglevel = "error"' >/dev/null 2>&1
); then fail 'write gate blocks mutations'; else pass 'write gate blocks mutations'; fi
printf '{"log": broken\n' > "$CONFIG_DIR/02_log.json"
if _config_jq -r '.log.loglevel' >/dev/null 2>&1; then
    fail 'unreadable fragments make reads fail visibly'
else
    pass 'unreadable fragments make reads fail visibly'
fi

printf '== DNS writes ==\n'
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"},"routing":{"rules":[]}}' >/dev/null 2>&1
_dns_apply_ok() {
    local rc=0
    (
        printf '#!/usr/bin/env bash\nprintf called > "%s"\nexit 1\n' "$TMP/dns-test-called" > "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        _dns_apply "$@" >/dev/null 2>&1
    ) || rc=1
    rm -f "$XRAY_BIN"
    return "$rc"
}
check 'DNS change skips a duplicate core precheck' _dns_apply_ok --arg a '1.1.1.1' '.dns = {servers: [$a]}'
check 'DNS change never invokes xray test' test ! -e "$TMP/dns-test-called"
if _dns_apply_ok --argjson v broken '.dns = $v'; then fail 'DNS rejects invalid jq arguments'; else pass 'DNS rejects invalid jq arguments'; fi
check_eq 'invalid DNS change keeps the old config' '1.1.1.1' "$(_config_jq -r '.dns.servers[0]')"
if (
    : > "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    _restart_xray_verified() { return 1; }
    _dns_apply '.dns.servers = ["8.8.8.8"]' >/dev/null 2>&1
); then fail 'DNS restart failure is reported'; else pass 'DNS restart failure is reported'; fi
check_eq 'failed DNS restart restores the old config' '1.1.1.1' "$(_config_jq -r '.dns.servers[0]')"
_dns_apply_ok '.dns.queryStrategy = "UseIPv4"' >/dev/null 2>&1
check_eq 'DNS summary reports the query strategy' '1.1.1.1|UseIPv4' "$(_dns_summary)"
_dns_apply_ok 'del(.dns)' >/dev/null 2>&1
if [ -e "$CONFIG_DIR/04_dns.json" ]; then fail 'DNS delete removes the field file'; else pass 'DNS delete removes the field file'; fi

printf '== launch contract ==\n'
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{},"inbounds":[]}' >/dev/null 2>&1
_auto_ensure_config_env_write >/dev/null 2>&1
check_eq 'config env carries only the asset path' 'XRAY_LOCATION_ASSET' "$(_config_jq -r '.env | keys_unsorted | join(",")')"
if _config_jq -e --arg d "$CONFIG_DIR" '((.env // {}) | to_entries | any(.key == "XRAY_JSON_STRICT" or (.value | tostring | contains($d))))' >/dev/null 2>&1; then
    fail 'strict JSON switch and confdir stay out of config env'
else
    pass 'strict JSON switch and confdir stay out of config env'
fi

printf '== atomic writes, locks and cron ==\n'
_atomic_target_dir_probe() (
    local d="$TMP/atomic-target-dir"
    rm -rf "$d"
    mkdir -p "$d/target"
    _atomic_write_json "$d/target" '{"ok":true}' >/dev/null 2>&1 && return 1
    [ -d "$d/target" ] || return 1
    [ -z "$(find "$d/target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
)
_state_target_dir_probe() (
    local d="$TMP/state-target-dir"
    rm -rf "$d"
    mkdir -p "$d/state/item"
    STATE_DIR="$d/state"
    _state_set item value >/dev/null 2>&1 && return 1
    [ -d "$d/state/item" ] || return 1
    [ -z "$(find "$d/state/item" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
)
check 'atomic JSON write' _atomic_write_json "$DEPLOY_DIR/atomic.json" '{"ok":true}'
if _atomic_write_json "$DEPLOY_DIR/bad.json" 'not-json' >/dev/null 2>&1; then fail 'atomic JSON rejects malformed input'; else pass 'atomic JSON rejects malformed input'; fi
check 'config lock executes its body' _with_config_lock bash -c 'test -d "$1"' _ "$DEPLOY_DIR"
check 'core lock executes its body' _with_core_lock bash -c 'test -d "$1"' _ "$DEPLOY_DIR"
check 'atomic JSON rejects a directory target without nesting the temp file' _atomic_target_dir_probe
check 'state write rejects a directory target without nesting the temp file' _state_target_dir_probe
_cron_ok='*/3'
_cron_bad='*/0'
check 'cron field accepts a valid step' _cron_field_valid "$_cron_ok"
if _cron_field_valid "$_cron_bad"; then fail 'cron field rejects a zero step'; else pass 'cron field rejects a zero step'; fi

printf '== logrotate state ==\n'
_state_set logrotate_frequency daily
_state_set logrotate_retention 7
_state_set logrotate_compress on
LOGROTATE_CONF="$TMP/logrotate.conf"
if _logrotate_render_config | grep -q 'rotate 7'; then pass 'logrotate renderer emits rotation count'; else fail 'logrotate renderer emits rotation count'; fi
_state_set logrotate_retention 999999999999999999999999
if _logrotate_render_config | grep -q 'rotate 30'; then pass 'logrotate retention is bounded'; else fail 'logrotate retention is bounded'; fi
_state_set xd_test_state_roundtrip sample-value
check_eq 'state values round-trip' sample-value "$(_state_get xd_test_state_roundtrip)"
rm -f "$STATE_DIR/xd_test_state_roundtrip"
LOGROTATE_CONF="$TMP/lr/xray-deploy"
mkdir -p "$TMP/lr"
_logrotate_write_config >/dev/null 2>&1
if [ "$(cat "$LOGROTATE_CONF")" = "$(_logrotate_render_config)" ] &&
   [ -z "$(find "$TMP/lr" -mindepth 1 -maxdepth 1 ! -name xray-deploy -print -quit)" ]; then
    pass 'logrotate include is complete with no temp residue'
else
    fail 'logrotate include is complete with no temp residue'
fi

printf '== PQ detection ==\n'
printf '#!/bin/sh\nexit 1\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
_pq_rc() {
    local rc=0
    _detect_reality_pq example.test:443 >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}
check_eq 'PQ probe failure is unknown' 2 "$(_pq_rc)"
printf '#!/bin/sh\nprintf "no pq group here\\n"\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
check_eq 'PQ absent group is unsupported' 1 "$(_pq_rc)"
printf '#!/bin/sh\nprintf "X25519MLKEM768\\nCertificate chain'"'"'s total length: 3000\\n"\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
check_eq 'PQ short certificate is unsupported' 1 "$(_pq_rc)"

XH_PQ_MENU_OUT=$(
    NODES_DIR="$TMP/pq-menu-nodes"
    mkdir -p "$NODES_DIR"
    printf '%s\n' '{"protocol":"vless-tcp-reality-vision","name":"pq-probe","sni":"old.example","mldsa65_verify":"oldverify","port":8443}' > "$NODES_DIR/pq-probe.json"
    XH_TXN_MARKER="$TMP/pq-txn-marker"
    _has_reality_nodes() { return 0; }
    clear() { :; }
    _reality_node_mode() { printf direct; }
    _press_any_key() { :; }
    _hy2_select_node() { shift; printf '%s' "${1:-}"; }
    _reality_domain_txn() { printf yes > "$XH_TXN_MARKER"; }
    _detect_reality_pq() { return 2; }
    _reality_domain_menu >/dev/null 2>&1 <<< $'1\nnew.example\n'
    [ ! -e "$XH_TXN_MARKER" ] && printf canceled
)
check_eq 'PQ probe failure cancels the domain switch' canceled "$XH_PQ_MENU_OUT"

printf '== Geo source state ==\n'
GEO_U_XTLS_GEOSITE='https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geosite.dat.gz'
GEO_U_XTLS_GEOIP='https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geoip-lite.dat.gz'
GEO_U_LOYAL_GEOSITE='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
GEO_U_LOYAL_GEOIP='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
rm -f "$STATE_DIR/geo_source" "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
check_eq 'default Geo source is XTLS' xtls "$(_geo_source_name)"
check_eq 'XTLS geoip uses the lite .gz source' "$GEO_U_XTLS_GEOIP" "$(_geo_source_url geoip)"
_state_set geo_source loyal
check_eq 'Loyalsoldier URLs are selected' "$GEO_U_LOYAL_GEOIP" "$(_geo_source_url geoip)"
_state_set geo_source custom
_state_set geo_geosite_url 'https://example.test/gs.dat'
_state_set geo_geoip_url 'https://example.test/gi.dat'
check_eq 'custom Geo URLs are used verbatim' 'https://example.test/gi.dat' "$(_geo_source_url geoip)"

GEO_MUTATE_ARGS="$TMP/geo-mutate-args"
rm -f "$GEO_MUTATE_ARGS"
(
    _geo_auto_mechanism() { printf builtin; }
    _mutate_config() { printf '%s\n' "$@" > "$GEO_MUTATE_ARGS"; }
    _geo_apply_source xtls
) >/dev/null 2>&1
if contains "$GEO_U_XTLS_GEOIP" "$(cat "$GEO_MUTATE_ARGS" 2>/dev/null)" &&
   contains '.geodata.assets = $a' "$(cat "$GEO_MUTATE_ARGS" 2>/dev/null)"; then
    pass 'builtin source switch rewrites only geodata assets'
else
    fail 'builtin source switch rewrites only geodata assets'
fi
check_eq 'builtin source switch records the source' xtls "$(_state_get geo_source)"

if (
    _state_set geo_source loyal
    _geo_auto_mechanism() { printf builtin; }
    _mutate_config() { return 1; }
    _geo_apply_source xtls >/dev/null 2>&1 && exit 1
    [ "$(_geo_source_name)" = loyal ]
); then pass 'source switch failure keeps the previous source'; else fail 'source switch failure keeps the previous source'; fi
if (
    _state_set geo_source loyal
    rm -f "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
    _geo_auto_mechanism() { printf builtin; }
    _mutate_config() { return 0; }
    _geo_apply_source custom 'https://a.test/gs.dat' 'ftp://a.test/gi.dat' >/dev/null 2>&1 && exit 1
    [ "$(_geo_source_name)" = loyal ] && [ ! -e "$STATE_DIR/geo_geosite_url" ]
); then pass 'invalid custom Geo source leaves state unchanged'; else fail 'invalid custom Geo source leaves state unchanged'; fi

printf '== custom geodata ==\n'
GEO_EXTRA_PATH="$STATE_DIR/geo_extra_assets"
GEO_EXTRA_BIG="$TMP/geo-extra-big.dat"
printf '%4096s' '' | tr ' ' x > "$GEO_EXTRA_BIG"
GEO_EXTRA_TOUCHED="$TMP/geo-extra-config-touched"
rm -f "$GEO_EXTRA_PATH" "$GEO_EXTRA_TOUCHED"
if (
    _geo_auto_mechanism() { printf builtin; }
    _with_core_lock() { "$@"; }
    _http_download() { cp "$GEO_EXTRA_BIG" "$2"; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED"; }
    { echo 'https://a.test/my.dat'; echo 'my.dat'; } | _geo_extra_add
) >/dev/null 2>&1; then pass 'custom geodata add completes'; else fail 'custom geodata add completes'; fi
check 'custom geodata add lands the file' test -s "$ASSET_DIR/my.dat"
check_eq 'custom geodata add records state' 'my.dat	https://a.test/my.dat' "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"
check 'custom geodata add updates config' test -e "$GEO_EXTRA_TOUCHED"

GEO_EXTRA_BEFORE=$(cat "$GEO_EXTRA_PATH" 2>/dev/null)
if (
    _geo_auto_mechanism() { printf builtin; }
    _with_core_lock() { "$@"; }
    _http_download() { return 1; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED"; }
    { echo 'https://a.test/fail.dat'; echo 'fail.dat'; } | _geo_extra_add
) >/dev/null 2>&1; then fail 'custom geodata download failure aborts'; else pass 'custom geodata download failure aborts'; fi
check 'failed download leaves no file' test ! -e "$ASSET_DIR/fail.dat"
check_eq 'failed download keeps state' "$GEO_EXTRA_BEFORE" "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"

GEO_DELETE_ARGS="$TMP/geo-delete-args"
if (
    _geo_auto_mechanism() { printf builtin; }
    _with_core_lock() { "$@"; }
    _mutate_config() { printf '%s' "$3" > "$GEO_DELETE_ARGS"; }
    echo 1 | _geo_extra_delete
) >/dev/null 2>&1; then pass 'custom geodata delete completes'; else fail 'custom geodata delete completes'; fi
check 'custom geodata delete removes the file' test ! -e "$ASSET_DIR/my.dat"
check_eq 'custom geodata delete removes the state line' '' "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"
check_eq 'custom geodata delete rewrites assets' 0 "$(jq -r '[.[] | select(.file=="my.dat")] | length' "$GEO_DELETE_ARGS" 2>/dev/null)"

# 规则集仍被 ext: 引用时删除必须中止, 与 sing-box 删除规则集前的引用检查同义。
printf 'my.dat\thttps://a.test/my.dat\n' > "$GEO_EXTRA_PATH"
printf x > "$ASSET_DIR/my.dat"
_config_write_merged '{"routing":{"rules":[{"domain":["ext:my.dat:cn"],"outboundTag":"block"}]}}' >/dev/null 2>&1
if (
    _geo_auto_mechanism() { printf off; }
    _with_core_lock() { "$@"; }
    echo 1 | _geo_extra_delete
) >/dev/null 2>&1; then fail 'referenced ruleset delete aborts'; else pass 'referenced ruleset delete aborts'; fi
check 'referenced ruleset delete keeps the file' test -e "$ASSET_DIR/my.dat"
check_eq 'referenced ruleset delete keeps the state line' 'my.dat	https://a.test/my.dat' "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"
rm -f "$ASSET_DIR/my.dat"

printf 'zeta.dat\thttps://a.test/dl/zeta.dat\n../evil.dat\thttps://a.test/evil.dat\n' > "$GEO_EXTRA_PATH"
printf keep > "$DEPLOY_DIR/evil.dat"
if (
    _geo_auto_mechanism() { printf off; }
    _with_core_lock() { "$@"; }
    echo 2 | _geo_extra_delete
) >/dev/null 2>&1; then fail 'custom geodata delete rejects path traversal'; else pass 'custom geodata delete rejects path traversal'; fi
check 'rejected delete keeps the outside file' test -f "$DEPLOY_DIR/evil.dat"

printf '== child suites ==\n'
for suite in test-node-alignment.sh test-outbound-alignment.sh test-cloudflared-alignment.sh test-hysteria-alignment.sh \
    test-menu-alignment.sh test-warp-alignment.sh test-common-regressions.sh test-core-regressions.sh; do
    if bash "$ROOT/tests/$suite" > "$TMP/$suite.log" 2>&1; then
        tail -n 1 "$TMP/$suite.log"
        pass "suite $suite"
    else
        tail -n 12 "$TMP/$suite.log"
        fail "suite $suite"
    fi
done

printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
