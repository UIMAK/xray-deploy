#!/usr/bin/env bash
# 配置目录拆分、恢复与变更回滚回归。
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-common-regressions.XXXXXX") || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
command -v jq >/dev/null 2>&1 || { printf 'FAIL - jq is required\n' >&2; exit 1; }

. "${XRAY_COMMON_TEST_SOURCE:-$ROOT/lib/00-common.sh}"
. "$ROOT/lib/20-xray-core.sh"
. "$ROOT/lib/30-geo.sh"
. "$ROOT/lib/50-nodes.sh"

_fsync_path() { :; }
_deploy_lock_root() { printf '%s' "$TMP/locks"; }
mkdir -p "$TMP/locks"

PASS=0
FAIL=0
check() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf '  ok - %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL - %s\n' "$name"
    fi
}

setup_case() {
    local name="$1"
    DEPLOY_DIR="$TMP/$name"
    CONFIG_DIR="$DEPLOY_DIR/confs"
    BACKUP_DIR="$DEPLOY_DIR/backups"
    ASSET_DIR="$DEPLOY_DIR/assets"
    STATE_DIR="$DEPLOY_DIR/state"
    NODES_DIR="$DEPLOY_DIR/nodes"
    LOG_DIR="$DEPLOY_DIR/logs"
    CERT_DIR="$DEPLOY_DIR/certs"
    BIN_DIR="$DEPLOY_DIR/bin"
    XRAY_BIN="$BIN_DIR/xray"
    rm -rf "${TMP:?}/$name"
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR/confs.lastbak"
    printf '{"version":{"min":"%s","max":""}}' "$XRAY_CORE_MIN_VERSION" > "$CONFIG_DIR/15_version.json"
}

producer_failure() (
    printf '{"log":{"loglevel":"warning"}}' > "$CONFIG_DIR/02_log.json"
    printf '{"inbounds":[]}' > "$CONFIG_DIR/07_inbounds.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/original-log"
    cp "$CONFIG_DIR/07_inbounds.json" "$TMP/original-inbounds"
    jq() {
        if [ "${1:-}" = -j ]; then
            printf 'log\0{"loglevel":"error"}\0'
            return 1
        fi
        command jq "$@"
    }
    ! _config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"error"}}' &&
        cmp -s "$CONFIG_DIR/02_log.json" "$TMP/original-log" &&
        cmp -s "$CONFIG_DIR/07_inbounds.json" "$TMP/original-inbounds"
)
setup_case producer
check 'split producer failure preserves live fragments' producer_failure

partial_commit() (
    printf '{"log":{"loglevel":"warning"}}' > "$CONFIG_DIR/02_log.json"
    printf '{"inbounds":[]}' > "$CONFIG_DIR/07_inbounds.json"
    cp "$CONFIG_DIR/07_inbounds.json" "$TMP/pc-inbounds"
    local n=0
    _atomic_write_json() {
        n=$((n + 1))
        [ "$n" -ge 3 ] && return 1
        mkdir -p "$(dirname "$1")" && printf '%s' "$2" > "$1"
    }
    ! _config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"error"},"inbounds":[{"tag":"x"}]}' &&
        [ "$n" -eq 3 ] &&
        cmp -s "$CONFIG_DIR/07_inbounds.json" "$TMP/pc-inbounds"
)
setup_case partial
check 'partial commit reports failure without replacing untouched fragments' partial_commit

invalid_restore() (
    local content="$1"
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/live-before"
    printf '%s' "$content" > "$BACKUP_DIR/confs.lastbak/02_log.json"
    ! _restore_config >/dev/null 2>&1 &&
        cmp -s "$CONFIG_DIR/02_log.json" "$TMP/live-before"
)
case_no=0
for content in '' '{broken' '[]' '{"log":{}} {"dns":{}}'; do
    case_no=$((case_no + 1))
    setup_case "invalid-$case_no"
    check "invalid backup is rejected: [$content]" invalid_restore "$content"
done

missing_backup_dir() (
    printf '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/missing-live"
    rm -rf "$BACKUP_DIR/confs.lastbak"
    ! _restore_config >/dev/null 2>&1 &&
        cmp -s "$CONFIG_DIR/02_log.json" "$TMP/missing-live"
)
setup_case missing-backup
check 'missing lastbak fails closed' missing_backup_dir

valid_roundtrip() (
    _config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"},"customTop":{"text":"a\nb"},"inbounds":[]}' || return 1
    cp "$CONFIG_DIR"/*.json "$BACKUP_DIR/confs.lastbak/" || return 1
    _config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"debug"},"dns":{"servers":[]}}' || return 1
    _restore_config >/dev/null 2>&1 || return 1
    _config_jq -e '.log.loglevel == "warning" and .customTop.text == "a\nb" and .inbounds == [] and (has("dns") | not)' >/dev/null
)
setup_case roundtrip
check 'valid backup restores fields and removes stale fragments' valid_roundtrip

config_layout_and_init() (
    rm -f "$CONFIG_DIR/15_version.json"
    _config_present && return 1
    _init_config_if_empty >/dev/null 2>&1 || return 1
    _config_jq -e --arg v "$XRAY_CORE_MIN_VERSION" '.version == {min:$v,max:""}' >/dev/null 2>&1 || return 1

    rm -f "$CONFIG_DIR"/*.json
    _init_config_if_empty >/dev/null 2>&1 || return 1
    _config_jq -e --arg v "$XRAY_CORE_MIN_VERSION" '
        .version == {min:$v,max:""}
        and (.inbounds | type == "array")
        and (.outbounds | type == "array")' >/dev/null 2>&1 || return 1

    rm -f "$CONFIG_DIR"/*.json
    printf '%s' '{"log":{"loglevel":"debug"}}' > "$CONFIG_DIR/02_log.json"
    cp "$CONFIG_DIR/02_log.json" "$TMP/init-missing-version"
    _init_config_if_empty >/dev/null 2>&1 || return 1
    cmp -s "$CONFIG_DIR/02_log.json" "$TMP/init-missing-version" || return 1
    [ "$(find "$CONFIG_DIR" -maxdepth 1 -type f | wc -l)" -eq 1 ] || return 1
    _config_write_merged '{"log":{"loglevel":"info"}}' || return 1
    _config_jq -e '.log.loglevel == "info" and (has("version") | not)' >/dev/null 2>&1
)
setup_case init
check 'init writes the current minimum version and leaves existing config usable' config_layout_and_init

version_preserved_by_mutations() (
    mkdir -p "$BACKUP_DIR" "$STATE_DIR" "$ASSET_DIR" "$NODES_DIR"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/fake-xray"
    chmod +x "$TMP/fake-xray"
    XRAY_BIN="$TMP/fake-xray"
    printf 'geo' > "$ASSET_DIR/geosite.dat"
    printf 'geo' > "$ASSET_DIR/geoip.dat"
    _state_set() { :; }
    _with_config_lock() { "$@"; }
    _txn_allow_config_write() { return 0; }
    _backup_config() { return 0; }
    _restart_xray_verified() { return 0; }
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" \
        '{version:{min:$v,max:""},log:{loglevel:"warning"},routing:{rules:[]},inbounds:[],outbounds:[]}')" || return 1
    _dns_apply '.dns = {"servers":["1.1.1.1"]}' || return 1
    _mutate_config '.routing.rules = [{"inboundTag":["node-a"],"outboundTag":"direct"}]' || return 1
    _geo_set_auto_update on || return 1
    _commit_inbound '{"tag":"node-a","protocol":"freedom"}' || return 1
    _config_jq -e --arg v "$XRAY_CORE_MIN_VERSION" '
        .version == {min:$v,max:""}
        and (.geodata.cron | length > 0)
        and any(.inbounds[]?; .tag == "node-a")' >/dev/null 2>&1
)
setup_case mutations
check 'DNS, routing, Geo and node mutations preserve the version fragment' version_preserved_by_mutations

geo_name_checks() {
    _geo_extra_name_has_dat geoip-full.dat &&
        _geo_extra_name_has_dat GEOIP.DAT &&
        ! _geo_extra_name_has_dat geoip-full &&
        _geo_extra_url_gz 'https://example.com/geoip-full.dat.gz?x=1' &&
        ! _geo_extra_url_gz 'https://example.com/geoip-full.dat'
}
setup_case geo-names
check 'custom geodata names require .dat and reject .gz sources' geo_name_checks

geo_source_defaults() {
    [ "$GEO_CRON_EXPR" = "30 4 * * *" ] &&
        case "$GEO_SRC_XTLS_GEOSITE" in
            *"geosite.dat.gz") ;;
            *) return 1 ;;
        esac &&
        case "$GEO_SRC_XTLS_GEOIP" in
            *"geoip-lite.dat.gz") ;;
            *) return 1 ;;
        esac &&
        _geo_url_gz 'https://example.com/geoip-lite.dat.gz' &&
        _geo_url_gz 'https://example.com/geosite.dat.GZ?x=1' &&
        ! _geo_url_gz 'https://example.com/geosite.dat'
}
check 'default Geo source is daily 04:30 with lite .gz assets' geo_source_defaults

route_token_checks() {
    _route_domain_token_valid example.com &&
        _route_domain_token_valid geosite:cn &&
        _route_domain_token_valid 'regexp:^ads\.example$' &&
        _route_domain_token_valid ext:my.dat:cn &&
        ! _route_domain_token_valid geoip:cn &&
        ! _route_domain_token_valid 'https://example.com' &&
        ! _route_domain_token_valid 'a b' &&
        _route_ip_token_valid 10.0.0.0/8 &&
        _route_ip_token_valid 2001:db8::/32 &&
        _route_ip_token_valid geoip:private &&
        ! _route_ip_token_valid 10.0.0.0/33 &&
        ! _route_ip_token_valid 10.0.0.0/ &&
        ! _route_ip_token_valid 2001:db8::/ &&
        ! _route_ip_token_valid 999.1.1.1 &&
        _route_protocol_token_valid http &&
        _route_protocol_token_valid tls &&
        _route_protocol_token_valid quic &&
        _route_protocol_token_valid bittorrent &&
        ! _route_protocol_token_valid ssh &&
        ! _route_protocol_token_valid unknown &&
        ! _route_protocol_token_valid TLS &&
        ! _route_protocol_token_valid 'a/b'
}
check 'route rule tokens reject malformed domain/IP/protocol values' route_token_checks

route_rule_filters() (
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" '{
        version:{min:$v,max:""},
        routing:{rules:[
            {inboundTag:["node-a"],outboundTag:"direct"},
            {domain:["geosite:cn"],outboundTag:"block"}
        ]}}')" || return 1
    local out=""
    out=$(jq --argjson rule '{"domain":["openai.com"],"outboundTag":"direct"}' --arg pos head "$ROUTE_ADD_RULE_JQ" \
        "$CONFIG_DIR/05_routing.json") || return 1
    [ "$(printf '%s' "$out" | jq -r '.routing.rules | length')" = "3" ] || return 1
    [ "$(printf '%s' "$out" | jq -r '.routing.rules[0].inboundTag[0]')" = "node-a" ] || return 1
    [ "$(printf '%s' "$out" | jq -r '.routing.rules[1].domain[0]')" = "openai.com" ] || return 1
    out=$(jq --argjson rule '{"domain":["geosite:cn"],"outboundTag":"block"}' "$ROUTE_DELETE_RULE_JQ" \
        "$CONFIG_DIR/05_routing.json") || return 1
    [ "$(printf '%s' "$out" | jq -r '.routing.rules | length')" = "1" ] || return 1
    ! jq --argjson rule '{"domain":["no-such-rule"],"outboundTag":"block"}' "$ROUTE_DELETE_RULE_JQ" \
        "$CONFIG_DIR/05_routing.json" >/dev/null 2>&1
)
setup_case route-filters
check 'route add inserts after node rules and delete matches by content' route_rule_filters

route_inbound_ownership() (
    mkdir -p "$BIN_DIR"
    printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" --arg u "$ROUTE_USER_RULE_TAG" '{
        version:{min:$v,max:""},
        inbounds:[{tag:"node-a"}],
        outbounds:[{tag:"proxy",protocol:"vless"}],
        routing:{rules:[
            {inboundTag:["node-a"],outboundTag:"direct"},
            {inboundTag:["node-a"],outboundTag:"block",ruleTag:$u}
        ]}}')" || return 1
    local out="$TMP/route-ownership-args"
    _mutate_config() { printf '%s\n' "$*" > "$out"; return 0; }
    # 未标记的节点规则继续拒绝删除。
    rm -f "$out"
    _route_delete_rule_flow >/dev/null 2>&1 <<< $'1\ny\n' && return 1
    [ ! -e "$out" ] || return 1
    # 带用户标记的 inboundTag 规则可删除。
    _route_delete_rule_flow >/dev/null 2>&1 <<< $'2\ny\n' || return 1
    grep -q '"ruleTag":"xd-user-rule"' "$out" || return 1
    # 添加向导给 inboundTag 规则打上同一个用户标记。
    rm -f "$out"
    _route_add_rule_flow >/dev/null 2>&1 <<< $'3\n1\n1\n1\ny\n' || return 1
    grep -q '"inboundTag":\["node-a"\]' "$out" &&
        grep -q '"ruleTag":"xd-user-rule"' "$out"
)
setup_case route-ownership
check 'user inbound rules are tagged and deletable, node rules stay protected' route_inbound_ownership

# 恢复默认保留节点规则; 带用户标记的 inboundTag 规则属于自定义规则, 必须一并丢弃。
route_restore_defaults() (
    mkdir -p "$BIN_DIR"
    printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" --arg u "$ROUTE_USER_RULE_TAG" '{
        version:{min:$v,max:""},
        inbounds:[{tag:"node-a"}],
        routing:{domainStrategy:"AsIs",rules:[
            {inboundTag:["node-a"],outboundTag:"direct"},
            {inboundTag:["node-a"],outboundTag:"block",ruleTag:$u},
            {domain:["custom.example"],outboundTag:"direct"}
        ]}}')" || return 1
    _with_config_lock() { "$@"; }
    _txn_allow_config_write() { return 0; }
    _backup_config() { return 0; }
    _restart_xray_verified() { return 0; }
    _route_restore_default_rules || return 1
    _config_jq -e --arg u "$ROUTE_USER_RULE_TAG" --argjson n "$(printf '%s' "$XRAY_DEFAULT_ROUTING_RULES_JSON" | jq 'length')" '
        (.routing.domainStrategy == "IPIfNonMatch")
        and (([.routing.rules[] | select(.inboundTag? != null)] | length) == 1)
        and (([.routing.rules[] | select((.ruleTag? // "") == $u)] | length) == 0)
        and ((.routing.rules | length) == (1 + $n))' >/dev/null
)
setup_case route-restore
check 'restore defaults drops user inbound rules and keeps node rules' route_restore_defaults

# Xray 的 port/sourcePort 可为数字, network/protocol 可为标量; 列表与删除须能处理。
route_scalar_fields() (
    mkdir -p "$BIN_DIR"
    printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" '{
        version:{min:$v,max:""},
        routing:{domainStrategy:"AsIs",rules:[
            {network:"tcp",outboundTag:"direct"},
            {port:443,outboundTag:"direct"},
            {sourcePort:"1000-2000",outboundTag:"direct"},
            {protocol:"tls",outboundTag:"direct"}
        ]}}')" || return 1
    local view="$TMP/route-scalar-view" captured="$TMP/route-scalar-delete"
    _config_jq -r --arg ut "$ROUTE_USER_RULE_TAG" "$ROUTE_RULE_LIST_JQ" > "$view" || return 1
    grep -q 'network=tcp' "$view" &&
        grep -q 'port=443' "$view" &&
        grep -q 'sourcePort=1000-2000' "$view" &&
        grep -q 'protocol=tls' "$view" || return 1
    _mutate_config() { printf '%s\n' "$*" > "$captured"; return 0; }
    _route_delete_rule_flow >/dev/null 2>&1 <<< $'2\ny\n' || return 1
    grep -q '"port":443' "$captured"
)
setup_case route-scalar
check 'scalar network/port/sourcePort fields render and delete' route_scalar_fields

geo_ext_reference_count() (
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" '{
        version:{min:$v,max:""},
        dns:{servers:[{address:"1.1.1.1",domains:"geosite:google"}],hosts:{"ext:my.dat:cn":"1.2.3.4"}},
        routing:{rules:[
            {domain:["ext:my.dat:cn","geosite:cn"],outboundTag:"block"},
            {ip:"geoip:private",outboundTag:"block"}
        ]}}')" || return 1
    [ "$(_geo_ref_count "ext:my.dat:")" = "2" ] &&
        [ "$(_geo_ref_count "geosite:")" = "2" ] &&
        [ "$(_geo_ref_count "geoip:")" = "1" ]
)
setup_case geo-refs
check 'Geo reference counts cover routing, DNS and hosts' geo_ext_reference_count

# busybox 的 crontab -l 是没有 crontab 文件时输出 can't open ... ENOENT, 不是 no crontab;
# 只有"确实没有"才算空态, 权限错误必须继续 fail-closed。
crontab_empty_state() (
    crontab() {
        case "${1:-}" in
            -l) printf "crontab: can't open 'root': No such file or directory\n" >&2; return 1 ;;
            *) return 0 ;;
        esac
    }
    local out
    out=$(_crontab_read 2>/dev/null) || return 1
    [ -z "$out" ] || return 1
    # crontabs 目录缺失时 busybox 报 can't cd to, 同样属于"确实没有"。
    crontab() {
        printf "crontab: can't cd to /var/spool/cron/crontabs: No such file or directory\n" >&2
        return 1
    }
    out=$(_crontab_read 2>/dev/null) || return 1
    [ -z "$out" ]
)
check 'busybox missing crontab is treated as empty state' crontab_empty_state

crontab_permission_still_fails() (
    crontab() { printf "crontab: can't open 'root': Permission denied\n" >&2; return 1; }
    ! _crontab_read >/dev/null 2>&1 || return 1
    # busybox 在 crontabs 目录不可读时走 can't cd to, 同样不能当空态。
    crontab() { printf "crontab: can't cd to /var/spool/cron/crontabs: Permission denied\n" >&2; return 1; }
    ! _crontab_read >/dev/null 2>&1
)
check 'busybox permission denied still fails closed' crontab_permission_still_fails

# 空 lastbak 必须在调用 jq 前判空: 无匹配 glob 会把 pattern 当片段送去校验, 报错也会指错文件。
restore_empty_lastbak() (
    rm -rf "$BACKUP_DIR/confs.lastbak"
    mkdir -p "$BACKUP_DIR/confs.lastbak"
    rm -f "$TMP/jq-called"
    jq() { : > "$TMP/jq-called"; return 1; }
    _restore_config >/dev/null 2>&1 && return 1
    [ ! -e "$TMP/jq-called" ]
)
setup_case restore-empty
check 'empty lastbak fails before invoking jq on stdin' restore_empty_lastbak

# Xray 的 StringList 同时接受数组与逗号串; 标量 Geo 引用必须计入统计与精简范围。
geo_scalar_reference() (
    _config_write_merged "$(jq -nc --arg v "$XRAY_CORE_MIN_VERSION" '{
        version:{min:$v,max:""},
        dns:{servers:[{address:"1.1.1.1",domains:"geosite:google"}]},
        routing:{rules:[
            {type:"field",domain:"geosite:cn",outboundTag:"block"},
            {type:"field",ip:["geoip:private"],outboundTag:"block"},
            {type:"field",domain:["example.com"],inboundTag:["node-a"],outboundTag:"direct"}
        ]}}')" || return 1
    local stats
    stats=$(_route_rules_stats) || return 1
    [ "$(printf '%s' "$stats" | cut -d' ' -f1)" = "3" ] || return 1
    [ "$(printf '%s' "$stats" | cut -d' ' -f2)" = "2" ] || return 1
    [ "$(printf '%s' "$stats" | cut -d' ' -f3)" = "1" ] || return 1
    [ "$(_route_dns_geo_count)" = "1" ]
)
setup_case geo-scalar
check 'scalar StringList Geo references are counted' geo_scalar_reference

printf 'common regressions passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
