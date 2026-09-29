#!/usr/bin/env bash
# xray-deploy focused regression suite.
# This suite intentionally tests observable behavior, not private source layout.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-deploy-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
check_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"; else fail "$name (expected [$expected], got [$actual])"; fi
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Source all modules without running the entry point.
. "$ROOT/lib/00-common.sh"
. "$ROOT/lib/10-system.sh"
. "$ROOT/lib/20-xray-core.sh"
. "$ROOT/lib/30-geo.sh"
. "$ROOT/lib/40-cloudflared.sh"
. "$ROOT/lib/45-logrotate.sh"
. "$ROOT/lib/50-nodes.sh"
. "$ROOT/lib/51-reality-pq.sh"
. "$ROOT/lib/55-hysteria.sh"
. "$ROOT/lib/90-menu.sh"

DEPLOY_DIR="$TMP/deploy"
CONFIG_FILE="$DEPLOY_DIR/config.json"
STATE_DIR="$DEPLOY_DIR/state"
ASSET_DIR="$DEPLOY_DIR/assets"
NODES_DIR="$DEPLOY_DIR/nodes"
CERT_DIR="$DEPLOY_DIR/certs"
BIN_DIR="$DEPLOY_DIR/bin"
LOG_DIR="$DEPLOY_DIR/log"
CLASH_YAML="$DEPLOY_DIR/clash.yaml"
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
mkdir -p "$DEPLOY_DIR" "$STATE_DIR" "$ASSET_DIR" "$NODES_DIR" "$CERT_DIR" "$BIN_DIR" "$LOG_DIR" "$HYSTERIA_DATA_DIR" "$HYSTERIA_BACKUP_DIR" "$HYSTERIA_CERT_DIR"
_deploy_lock_root() { printf '%s' "$TMP/locks"; }
mkdir -p "$TMP/locks"

printf '== focused common behavior ==\n'
check 'valid IPv4 accepted' _validate_listen 192.0.2.10
check 'valid IPv6 accepted' _validate_listen 2001:db8::1
if _validate_listen $'::1\ngarbage'; then fail 'multiline listen rejected'; else pass 'multiline listen rejected'; fi
if _validate_listen 010.0.0.1; then fail 'leading-zero IPv4 rejected'; else pass 'leading-zero IPv4 rejected'; fi
if _validate_port 0; then fail 'invalid port rejected'; else pass 'invalid port rejected'; fi
_xray_current_version() { printf '26.9.9\n'; }
check 'version compare' _xray_version_ge 26.4.25
if _xray_version_ge 26.x.25 >/dev/null 2>&1; then fail 'version rejects malformed value'; else pass 'version rejects malformed value'; fi
check_eq 'version tag canonicalization' v26.9.9 "$(_xray_canon_tag 26.9.9)"

printf '== atomic JSON and locks ==\n'
check 'atomic JSON write' _atomic_write_json "$DEPLOY_DIR/atomic.json" '{"ok":true}'
if _atomic_write_json "$DEPLOY_DIR/bad.json" 'not-json' >/dev/null 2>&1; then fail 'atomic JSON rejects malformed input'; else pass 'atomic JSON rejects malformed input'; fi
check 'config lock body runs' _with_config_lock bash -c 'test -d "$1"' _ "$DEPLOY_DIR"
check 'core lock body runs' _with_core_lock bash -c 'test -d "$1"' _ "$DEPLOY_DIR"

printf '== logrotate and Geo state ==\n'
_state_set logrotate_frequency daily
_state_set logrotate_retention 7
_state_set logrotate_compress on
LOGROTATE_CONF="$TMP/logrotate.conf"
if _logrotate_render_config | grep -q 'rotate 7'; then pass 'logrotate renderer emits rotation count'; else fail 'logrotate renderer emits rotation count'; fi
_state_set logrotate_retention 999999999999999999999999
if _logrotate_render_config | grep -q 'rotate 30'; then pass 'long retention is bounded'; else fail 'long retention is bounded'; fi
LOGROTATE_CONF="$TMP/logrotate-reapply.conf"
_state_set logrotate_enabled on
if _logrotate_enable >/dev/null 2>&1 && grep -q 'rotate 30' "$LOGROTATE_CONF"; then pass 'logrotate reapply repairs enabled config'; else fail 'logrotate reapply repairs enabled config'; fi

GEO_TRANSITION_KEY=geo_transition
_state_set "$GEO_TRANSITION_KEY" off_pending
check_eq 'Geo off marker persists' off_pending "$(_state_get "$GEO_TRANSITION_KEY")"

printf '== cloudflared credential handling ==\n'
TOK1='eyJhIjoiYWFhYWFhYWFhYWFhYWFhYWFhYSJ9'
TOK2='eyJhIjoiYmJiYmJiYmJiYmJiYmJiYmJiYmIifQ=='
redacted=$(_cf_redact_service_line "ExecStart=$CF_BIN tunnel run --token $TOK1 --token $TOK2")
if contains "$TOK1" "$redacted" || contains "$TOK2" "$redacted"; then fail 'all repeated tokens are redacted'; else pass 'all repeated tokens are redacted'; fi

printf '== cloudflared command ownership ==\n'
CF_UNIT_SYSTEMD="$TMP/cloudflared.service"
custom_bin="$TMP/custom-cloudflared"
printf '#!/bin/sh\nexit 0\n' > "$custom_bin"; chmod +x "$custom_bin"
printf 'ExecStart=%s tunnel run --token %s\n' "$custom_bin" "$TOK1" > "$CF_UNIT_SYSTEMD"
_read_cf_state
if _cf_managed_flags_only; then fail 'custom cloudflared executable rejected'; else pass 'custom cloudflared executable rejected'; fi
rm -f "$CF_UNIT_SYSTEMD" "$custom_bin"

iptables() {
    case "$*" in
        *' -S '*) printf '%s\n' '-A PREROUTING -p udp -m udp --dport 20000:30000 -m comment --comment xray-deploy-hy2-hop -j DNAT --to-destination :8443' ;;
        *) return 0 ;;
    esac
}
if _hy2_add_hop_rules 9443 25000 >/dev/null 2>&1; then fail 'overlapping IPv4 hop range rejected'; else pass 'overlapping IPv4 hop range rejected'; fi
if (
    iptables() { case "$*" in *' -S '*) return 0 ;; *) return 0 ;; esac; }
    ip6tables() {
        case "$*" in
            *' -S '*) printf '%s\n' '-A PREROUTING -p udp --dport 20000:30000 -m comment --comment xray-deploy-hy2-hop -j DNAT --to-destination :8443' ;;
            *) return 0 ;;
        esac
    }
    _hy2_add_hop_rules 9443 25000 >/dev/null 2>&1
); then fail 'overlapping IPv6 hop range rejected'; else pass 'overlapping IPv6 hop range rejected'; fi
IP6_ADD_MARKER="$TMP/ip6-added"
if (
    iptables() { case "$*" in *' -S '*) return 0 ;; *) return 0 ;; esac; }
    ip6tables() {
        case "$*" in
            *' -S '*) return 1 ;;
            *) : > "$IP6_ADD_MARKER"; return 0 ;;
        esac
    }
    _hy2_add_hop_rules 9443 30001 >/dev/null 2>&1
) && [ ! -e "$IP6_ADD_MARKER" ]; then pass 'failed IPv6 snapshot skips IPv6 add'; else fail 'failed IPv6 snapshot skips IPv6 add'; fi

printf '== cloudflared parser and absent-unit behavior ==\n'
CF_BIN="$TMP/cloudflared-main"
printf '#!/bin/sh\nexit 0\n' > "$CF_BIN"; chmod +x "$CF_BIN"
CF_UNIT_SYSTEMD="$TMP/cloudflared.service"
printf 'ExecStart=%s --no-autoupdate tunnel --protocol http2 run --token %s\n' "$CF_BIN" "$TOK1" > "$CF_UNIT_SYSTEMD"
INIT_SYSTEM=systemd
_read_cf_state
if [ "$CF_CUR_AUTOUPDATE" = off ] && [ "$CF_CUR_HTTP2" = on ] && _cf_managed_flags_only; then
    pass 'managed cloudflared service flags accepted'
else
    fail 'managed cloudflared service flags accepted'
fi
printf 'ExecStart=%s tunnel run "--metrics=127.0.0.1:2000" --token %s\n' "$CF_BIN" "$TOK1" > "$CF_UNIT_SYSTEMD"
_read_cf_state
if _cf_managed_flags_only; then fail 'quoted custom cloudflared flag rejected'; else pass 'quoted custom cloudflared flag rejected'; fi
printf 'ExecStart=%s tunnel run extra-positional --token %s\n' "$CF_BIN" "$TOK1" > "$CF_UNIT_SYSTEMD"
_read_cf_state
if _cf_managed_flags_only; then fail 'extra cloudflared positional rejected'; else pass 'extra cloudflared positional rejected'; fi
rm -f "$CF_UNIT_SYSTEMD" "$CF_BIN"
INIT_SYSTEM=direct
if (
    INIT_SYSTEM=systemd
    CF_BIN="$TMP/cloudflared-uninstall"
    CF_UNIT_SYSTEMD="$TMP/cloudflared-unit"
    CF_UNIT_OPENRC="$TMP/cloudflared-init"
    CF_STATE_AUTOUPDATE="$TMP/cf-auto"; CF_STATE_HTTP2="$TMP/cf-http2"; CF_STATE_EDGE_IP="$TMP/cf-edge"; CF_STATE_TOKEN="$TMP/cf-token"
    printf '#!/bin/sh\nexit 0\n' > "$CF_BIN"; chmod +x "$CF_BIN"
    : > "$CF_UNIT_SYSTEMD"
    systemctl() {
        case "$1" in
            disable|daemon-reload) return 0 ;;
            show) printf 'not-found\n'; return 0 ;;
            is-enabled) printf 'not-found\n' >&2; return 1 ;;
        esac
    }
    _cf_kill_all() { return 0; }
    find() { return 0; }
    _uninstall_cloudflared >/dev/null 2>&1
); then pass 'cloudflared accepts stderr-only missing systemd unit'; else fail 'cloudflared accepts stderr-only missing systemd unit'; fi

printf '{"name":"shared-name"}\n' > "$NODES_DIR/xray.json"
if _hysteria_name_taken shared-name; then pass 'shared Clash name collision rejected'; else fail 'shared Clash name collision rejected'; fi
rm -f "$NODES_DIR/xray.json"
# 十二轮 P1: Xray Hy2 的协议键是 `hysteria`, 旧判据查的却是 Xray 里**不存在**的 "hysteria2"
# ⇒ Hy2 节点落在跳跃范围内时被静默放行(该 UDP 端口随后被官方 REDIRECT 抢走)。
# `.port` 又是 PortList(单端口 / 范围 / 逗号多段) ⇒ 必须按区间相交判定, 不能等值比较。
# NODES_DIR 指向空目录, 使这些断言只检验 config 入站分支(分支 c 另有专测)。
XH_PORT_CONFIG="$TMP/xray-portlist.json"
XH_NODES_EMPTY="$TMP/xh-nodes-empty"
mkdir -p "$XH_NODES_EMPTY"
ss() { printf 'Netid State Local Address:Port Peer Address:Port\n'; }
_xh_hop_conflict() {   # $1=入站 JSON, $2/$3=跳跃范围, $4=exclude; 判为冲突返回 0
    local saved_cfg="$CONFIG_FILE" saved_nodes="$NODES_DIR" rc
    printf '{"inbounds":[%s]}\n' "$1" > "$XH_PORT_CONFIG"
    CONFIG_FILE="$XH_PORT_CONFIG"; NODES_DIR="$XH_NODES_EMPTY"
    _hysteria_check_hop_conflicts "$2" "$3" ${4:+"$4"} >/dev/null 2>&1; rc=$?
    CONFIG_FILE="$saved_cfg"; NODES_DIR="$saved_nodes"
    [ "$rc" -ne 0 ]
}
check 'Xray hysteria PortList overlap rejected' _xh_hop_conflict \
    '{"protocol":"hysteria","port":"30000,31000-32000"}' 31500 31500
check 'Xray hysteria single port inside hop range rejected' _xh_hop_conflict \
    '{"protocol":"hysteria","port":30000}' 20000 40000
check 'Xray hysteria port range overlapping hop range rejected' _xh_hop_conflict \
    '{"protocol":"hysteria","port":"30000-31000"}' 30500 32000
if _xh_hop_conflict '{"protocol":"hysteria","port":443}' 20000 40000; then fail 'Xray hysteria outside hop range allowed'; else pass 'Xray hysteria outside hop range allowed'; fi
if _xh_hop_conflict '{"protocol":"vless","port":31500,"streamSettings":{"network":"raw"}}' 20000 40000; then fail 'TCP-only Reality not flagged as UDP conflict'; else pass 'TCP-only Reality not flagged as UDP conflict'; fi
if _xh_hop_conflict '{"protocol":"tunnel","port":31500,"settings":{"network":"tcp"}}' 20000 40000; then fail 'TCP-only tunnel not flagged as UDP conflict'; else pass 'TCP-only tunnel not flagged as UDP conflict'; fi
check 'UDP-capable dokodemo-door flagged' _xh_hop_conflict \
    '{"protocol":"dokodemo-door","port":31500,"settings":{"network":"tcp,udp"}}' 20000 40000
# 十三轮复审: shadowsocks 缺 `network` 在核心里是 nil ⇒ [TCP]
# (infra/conf/common.go 的 (*NetworkList).Build(): nil 返回 net.Network_TCP), 官方文档
# inbounds/shadowsocks.md 也写"默认 tcp" ⇒ 默认 SS 入站**不监听 UDP**, 不得被误判成冲突。
if _xh_hop_conflict '{"protocol":"shadowsocks","port":31500,"settings":{"method":"aes-256-gcm"}}' 20000 40000; then
    fail 'default-network shadowsocks stays TCP-only'
else
    pass 'default-network shadowsocks stays TCP-only'
fi
check 'shadowsocks network=udp flagged' _xh_hop_conflict \
    '{"protocol":"shadowsocks","port":31500,"settings":{"network":"udp"}}' 20000 40000
check 'shadowsocks network=tcp,udp flagged' _xh_hop_conflict \
    '{"protocol":"shadowsocks","port":31500,"settings":{"network":"tcp,udp"}}' 20000 40000
if _xh_hop_conflict '{"protocol":"shadowsocks","port":31500,"settings":{"network":"tcp"}}' 20000 40000; then fail 'TCP-only shadowsocks not flagged'; else pass 'TCP-only shadowsocks not flagged'; fi
check 'mkcp transport inbound flagged' _xh_hop_conflict \
    '{"protocol":"vless","port":31500,"streamSettings":{"network":"mkcp"}}' 20000 40000
if _xh_hop_conflict '{"protocol":"hysteria","port":443}' 443 50000 443; then fail 'own listen port exempt from hop conflict'; else pass 'own listen port exempt from hop conflict'; fi
CONFIG_FILE="$DEPLOY_DIR/config.json"

SEED=$(head -c 32 /dev/zero | base64 | tr '+/' '-_' | tr -d '=')
VERIFY=$(head -c 1952 /dev/zero | base64 | tr -d '=\n' | tr '+/' '-_')
cat > "$XRAY_BIN" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "tls ping") printf '%s\\n%s\\n' 'X25519MLKEM768' "Certificate chain's total length: 4000" ;;
  "mldsa65 ") printf 'Seed: %s\\nVerify: %s\\n' "$SEED" "$VERIFY" ;;
  *) printf '26.9.9\\n' ;;
esac
EOF
chmod +x "$XRAY_BIN"
_pq_run_bounded() { local _secs="$1"; shift; "$@"; }
if _detect_reality_pq example.test:443 >/dev/null 2>&1 && [ "${#PQ_SEED}" -eq 43 ] && [ "${#PQ_VERIFY}" -eq 2603 ]; then
    pass 'PQ RawURL output accepted'
else
    fail 'PQ RawURL output accepted'
fi
printf '#!/bin/sh\nprintf "Seed: short\\nVerify: short\\n"\n' > "$XRAY_BIN"
chmod +x "$XRAY_BIN"
if _detect_reality_pq example.test:443 >/dev/null 2>&1 || [ -n "${PQ_SEED:-}" ] || [ -n "${PQ_VERIFY:-}" ]; then
    fail 'PQ malformed output rejected and globals cleared'
else
    pass 'PQ malformed output rejected and globals cleared'
fi

# 十二轮 P2: 返回码三态 —— 只有"探测成功且目标客观上不支持"才是 1(调用方可安全移除旧 PQ);
# 探测/取键失败或环境异常必须是 2(结论未知)。原实现把两者压成 1, 于是**一次临时网络超时**
# 就会让域名切换删掉节点上已生效的 mldsa65Seed/mldsa65_verify。
_pq_rc() {   # 输出 _detect_reality_pq 的返回码(0/1/2)
    local rc=0
    _detect_reality_pq example.test:443 >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}
printf '#!/bin/sh\nexit 1\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
check_eq 'PQ tls ping failure is PROBE_FAILED' 2 "$(_pq_rc)"
printf '#!/bin/sh\nprintf "no pq group here\\n"\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
check_eq 'PQ absent group is UNSUPPORTED' 1 "$(_pq_rc)"
cat > "$XRAY_BIN" <<EOF
#!/bin/sh
printf '%s\\n%s\\n' 'X25519MLKEM768' "Certificate chain's total length: 3000"
EOF
chmod +x "$XRAY_BIN"
check_eq 'PQ short certificate is UNSUPPORTED' 1 "$(_pq_rc)"
cat > "$XRAY_BIN" <<EOF
#!/bin/sh
printf '%s\\n' 'X25519MLKEM768'
EOF
chmod +x "$XRAY_BIN"
check_eq 'PQ missing chain length is PROBE_FAILED' 2 "$(_pq_rc)"
cat > "$XRAY_BIN" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "tls ping") printf '%s\\n%s\\n' 'X25519MLKEM768' "Certificate chain's total length: 4000" ;;
  *) exit 3 ;;
esac
EOF
chmod +x "$XRAY_BIN"
check_eq 'PQ key generation failure is PROBE_FAILED' 2 "$(_pq_rc)"

printf '== Reality PQ probe failure must not downgrade a node ==\n'
# 探针驱动真实的 `_reality_domain_menu`: 探测返回 2(PROBE_FAILED)时**不得**调用切换事务
# (原实现的 `if _detect_reality_pq ...; then` 会把失败当成"新域名不支持 PQ"照常提交,
# 事务内 `del(.mldsa65Seed)` 于是抹掉一个原本可用的 PQ 配置)。
XH_PQ_MENU_OUT=$(
    NODES_DIR="$TMP/pq-menu-nodes"
    mkdir -p "$NODES_DIR"
    printf '%s\n' '{"protocol":"vless-tcp-reality-vision","name":"pq-probe","sni":"old.example","mldsa65_verify":"oldverify","port":8443}' > "$NODES_DIR/pq-probe.json"
    XH_TXN_MARKER="$TMP/pq-txn-marker"
    _has_reality_nodes() { return 0; }
    clear() { :; }
    _reality_node_mode() { printf 'direct'; }
    _sync_node_clash() { return 0; }
    _press_any_key() { :; }
    _hy2_select_node() { shift; printf '%s' "${1:-}"; }
    _reality_domain_txn() { printf '%s|%s' "${4:-}" "${5:-}" > "$XH_TXN_MARKER"; return 0; }
    _detect_reality_pq() {
        case "${XH_PQ_RC:-2}" in
            0) PQ_SEED="seed43"; PQ_VERIFY="verify2603"; return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    }
    read() {
        _n=$((_n + 1))
        local v="${!#}"
        case "$_n" in
            1) printf -v "$v" '%s' 1 ;;
            2) printf -v "$v" '%s' new.example ;;
            *) return 1 ;;
        esac
        return 0
    }
    for XH_PQ_RC in 2 1 0; do
        rm -f "$XH_TXN_MARKER"
        _n=0
        _reality_domain_menu >/dev/null 2>&1
        if [ -e "$XH_TXN_MARKER" ]; then
            printf 'rc=%s txn=yes args=%s\n' "$XH_PQ_RC" "$(cat "$XH_TXN_MARKER")"
        else
            printf 'rc=%s txn=no\n' "$XH_PQ_RC"
        fi
    done
)
if contains 'rc=2 txn=no' "$XH_PQ_MENU_OUT"; then
    pass 'PQ probe failure cancels the domain switch'
else
    fail "PQ probe failure cancels the domain switch [$XH_PQ_MENU_OUT]"
fi
if contains 'rc=1 txn=yes args=|' "$XH_PQ_MENU_OUT"; then
    pass 'PQ unsupported switches without PQ keys'
else
    fail "PQ unsupported switches without PQ keys [$XH_PQ_MENU_OUT]"
fi
if contains 'rc=0 txn=yes args=seed43|verify2603' "$XH_PQ_MENU_OUT"; then
    pass 'PQ supported forwards generated keys'
else
    fail "PQ supported forwards generated keys [$XH_PQ_MENU_OUT]"
fi

printf '== guarded lifecycle behavior ==\n'
# Startup migration adds native geodata without dropping the legacy rollback path.
GEO_TRANSITION_KEY=geo_update_transition
_state_set geo_cron on
printf '{"inbounds":[]}\n' > "$CONFIG_FILE"
: > "$ASSET_DIR/geosite.dat"
: > "$ASSET_DIR/geoip.dat"
if _auto_migrate_geo_autoupdate >/dev/null 2>&1 \
   && [ "$(jq -r '.geodata.cron // empty' "$CONFIG_FILE")" = "$GEO_CRON_EXPR" ] \
   && [ "$(_state_get geo_cron)" = on ]; then
    pass 'Geo migration retains legacy fallback state'
else
    fail 'Geo migration retains legacy fallback state'
fi

# Restart must not start a second connector after incomplete process cleanup.
if (
    CF_START_SENTINEL="$TMP/cf-started"
    INIT_SYSTEM=systemd
    _cf_kill_all() { return 1; }
    systemctl() { printf 'start\n' >> "$CF_START_SENTINEL"; }
    sleep() { :; }
    _cf_restart >/dev/null 2>&1 && exit 1
    [ ! -e "$CF_START_SENTINEL" ]
); then
    pass 'cloudflared restart fails closed on cleanup error'
else
    fail 'cloudflared restart fails closed on cleanup error'
fi

# A clean cloudflared start should not pay the old fixed 3-second post-start delay.
if (
    CF_START_SENTINEL="$TMP/cf-fast-start"
    CF_SLEEP_SENTINEL="$TMP/cf-fast-sleeps"
    INIT_SYSTEM=systemd
    _cf_kill_all() { return 0; }
    _cf_is_managed_running() { return 0; }
    systemctl() { [ "$1" = start ] && printf 'start\n' >> "$CF_START_SENTINEL"; }
    sleep() { printf '%s\n' "$1" >> "$CF_SLEEP_SENTINEL"; }
    _cf_restart >/dev/null 2>&1 && [ "$(cat "$CF_START_SENTINEL")" = start ] \
        && [ "$(wc -l < "$CF_SLEEP_SENTINEL")" -eq 1 ] \
        && [ "$(cat "$CF_SLEEP_SENTINEL")" = 2 ]
); then
    pass 'cloudflared clean restart skips fixed post-start delay'
else
    fail 'cloudflared clean restart skips fixed post-start delay'
fi

# The SIGKILL deadline is not a hardcoded number: it must come from the grace period the
# service actually runs with, because a unit may carry `--grace-period 60s` (or
# TUNNEL_GRACE_PERIOD) and SIGKILLing at a constant 35s cuts a still-draining tunnel short --
# the same bug as the original 3s window, only wider.
# The wait is an upper bound: a clean stop returns as soon as the unit is terminal.
if (
    CF_CFG_DEFAULT="$TMP/cf-grace-default.service"
    : > "$CF_CFG_DEFAULT"
    _cf_unit_path() { printf '%s' "$CF_CFG_DEFAULT"; }
    got=$(_cf_grace_wait_seconds)
    [ "$got" -eq "$(( CF_GRACE_DEFAULT + CF_GRACE_MARGIN ))" ]
); then
    pass 'cloudflared stop deadline follows the configured grace period, default 30s'
else
    fail 'cloudflared stop deadline follows the configured grace period, default 30s'
fi

if (
    CF_CFG_SPACED="$TMP/cf-grace-spaced.service"
    CF_CFG_INLINE="$TMP/cf-grace-inline.service"
    CF_CFG_ENV="$TMP/cf-grace-env.service"
    CF_CFG_COMMENT="$TMP/cf-grace-comment.service"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 60s run --token x\n' > "$CF_CFG_SPACED"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period=45s run --token x\n' > "$CF_CFG_INLINE"
    printf '[Service]\nEnvironment="TUNNEL_GRACE_PERIOD=90s"\nExecStart=/usr/local/bin/cloudflared tunnel run --token x\n' > "$CF_CFG_ENV"
    printf '[Service]\n# ExecStart=/usr/local/bin/cloudflared tunnel --grace-period 600s run --token x\nExecStart=/usr/local/bin/cloudflared tunnel run --token x\n' > "$CF_CFG_COMMENT"
    _cf_unit_path() { printf '%s' "$CF_CFG_SPACED"; }
    a=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_CFG_INLINE"; }
    b=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_CFG_ENV"; }
    c=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_CFG_COMMENT"; }
    d=$(_cf_grace_wait_seconds)
    [ "$a" -eq 65 ] && [ "$b" -eq 50 ] && [ "$c" -eq 95 ] \
        && [ "$d" -eq "$(( CF_GRACE_DEFAULT + CF_GRACE_MARGIN ))" ]
); then
    pass 'cloudflared grace deadline reads --grace-period and TUNNEL_GRACE_PERIOD'
else
    fail 'cloudflared grace deadline reads --grace-period and TUNNEL_GRACE_PERIOD'
fi

# systemd applies its own quoting rules to ExecStart= before handing words to the process, so
# `--grace-period "60s"` really means 60s. read -ra does NOT unquote; the literal would arrive
# as `"60s"`, _cf_duration_seconds would reject it and the deadline would silently fall back to
# the 30s default -- the very "configured 60s, killed at 35s" bug this change exists to fix.
# Negative control: stripping quotes only from the whole word (or not at all) breaks the
# inline forms, whose quotes sit *around the value*, not around the argument.
if (
    CF_Q_SPACED="$TMP/cf-grace-q-spaced.service"
    CF_Q_SPACED_S="$TMP/cf-grace-q-spaced-s.service"
    CF_Q_INLINE="$TMP/cf-grace-q-inline.service"
    CF_Q_INLINE_S="$TMP/cf-grace-q-inline-s.service"
    CF_Q_OPENRC="$TMP/cf-grace-q-openrc.conf"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period "60s" run --token x\n' > "$CF_Q_SPACED"
    printf "[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period '60s' run --token x\n" > "$CF_Q_SPACED_S"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period="60s" run --token x\n' > "$CF_Q_INLINE"
    printf "[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period='60s' run --token x\n" > "$CF_Q_INLINE_S"
    printf 'command_args="--grace-period 60s run --token x"\n' > "$CF_Q_OPENRC"
    _cf_unit_path() { printf '%s' "$CF_Q_SPACED"; };   a=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_Q_SPACED_S"; }; b=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_Q_INLINE"; };   c=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_Q_INLINE_S"; }; d=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_Q_OPENRC"; };   e=$(_cf_grace_wait_seconds)
    [ "$a" -eq 65 ] && [ "$b" -eq 65 ] && [ "$c" -eq 65 ] && [ "$d" -eq 65 ] && [ "$e" -eq 65 ]
); then
    pass 'cloudflared grace deadline unquotes systemd and openrc arguments'
else
    fail 'cloudflared grace deadline unquotes systemd and openrc arguments'
fi

# systemd also feeds variables in from EnvironmentFile=, so TUNNEL_GRACE_PERIOD may live in
# /etc/default/cloudflared rather than in the unit. Scanning only the unit text would report
# "not configured" and fall back to the 30s default. A `-` prefix means "missing file is fine".
if (
    CF_EF_UNIT="$TMP/cf-grace-ef.service"
    CF_EF_UNIT_ARGS="$TMP/cf-grace-ef-args.service"
    CF_EF_UNIT_DASH="$TMP/cf-grace-ef-dash.service"
    CF_EF_FILE="$TMP/cf-grace-ef.env"
    printf 'TUNNEL_GRACE_PERIOD=75s\n' > "$CF_EF_FILE"
    printf '[Service]\nEnvironmentFile=%s\nExecStart=/usr/local/bin/cloudflared tunnel run --token x\n' "$CF_EF_FILE" > "$CF_EF_UNIT"
    printf '[Service]\nEnvironmentFile=-%s\nExecStart=/usr/local/bin/cloudflared tunnel run --token x\n' "$CF_EF_FILE.nope" > "$CF_EF_UNIT_DASH"
    printf '[Service]\nEnvironmentFile="%s"\nExecStart=/usr/local/bin/cloudflared tunnel run --token x\n' "$CF_EF_FILE" > "$CF_EF_UNIT_ARGS"
    _cf_unit_path() { printf '%s' "$CF_EF_UNIT"; };      a=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_EF_UNIT_ARGS"; }; b=$(_cf_grace_wait_seconds)
    _cf_unit_path() { printf '%s' "$CF_EF_UNIT_DASH"; }; c=$(_cf_grace_wait_seconds)
    [ "$a" -eq 80 ] && [ "$b" -eq 80 ] && [ "$c" -eq "$(( CF_GRACE_DEFAULT + CF_GRACE_MARGIN ))" ]
); then
    pass 'cloudflared grace deadline follows EnvironmentFile when the unit uses one'
else
    fail 'cloudflared grace deadline follows EnvironmentFile when the unit uses one'
fi

# The unit FILE is not the effective configuration: drop-ins, repeated `Environment=` (later
# wins) and `EnvironmentFile=` (which overrides `Environment=`) all change what the process
# really runs with. Reading the text alone would report 30s while systemd hands the process
# 90s -- i.e. SIGKILLing a still-draining tunnel at 35s, the original bug in a new disguise.
# systemd is the authority, so on systemd we read `systemctl show` and ignore the text.
# Negative control: a text-only implementation reads the unit file below and returns 35.
if (
    INIT_SYSTEM=systemd
    CF_EFF_UNIT="$TMP/cf-eff.service"
    # Deliberately WRONG (stale) text: the effective value comes from the drop-in.
    printf '[Service]\nEnvironment=TUNNEL_GRACE_PERIOD=30s\nExecStart=/usr/local/bin/cloudflared tunnel run --token x\n' > "$CF_EFF_UNIT"
    _cf_unit_path() { printf '%s' "$CF_EFF_UNIT"; }
    systemctl() {
        case "$*" in
            'show -p LoadState --value cloudflared')  printf 'loaded\n' ;;
            'show -p ExecStart --value cloudflared')  printf '{ path=/usr/local/bin/cloudflared ; argv[]=/usr/local/bin/cloudflared tunnel run --token x ; ignore_errors=no ; status=0/0 }\n' ;;
            'show -p EnvironmentFiles --value cloudflared') printf '\n' ;;
            'show -p Environment --value cloudflared') printf 'TUNNEL_GRACE_PERIOD=90s\n' ;;
        esac
        return 0
    }
    [ "$(_cf_grace_wait_seconds)" -eq 95 ]
); then
    pass 'cloudflared grace deadline comes from the systemd effective configuration'
else
    fail 'cloudflared grace deadline comes from the systemd effective configuration'
fi

# systemd resolves the launch line itself: a drop-in that overrides `ExecStart=` replaces the
# main unit's line entirely, and the argv it reports is already unquoted (verified against real
# systemd: a unit line `--grace-period "45s"` is reported as `--grace-period 45s`). The flag
# still outranks the environment variable.
if (
    INIT_SYSTEM=systemd
    CF_EFF2_UNIT="$TMP/cf-eff2.service"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 30s run --token x\n' > "$CF_EFF2_UNIT"
    _cf_unit_path() { printf '%s' "$CF_EFF2_UNIT"; }
    systemctl() {
        case "$*" in
            'show -p LoadState --value cloudflared')  printf 'loaded\n' ;;
            'show -p ExecStart --value cloudflared')  printf '{ path=/usr/local/bin/cloudflared ; argv[]=/usr/local/bin/cloudflared tunnel --grace-period 60s run --token x ; ignore_errors=no ; status=0/0 }\n' ;;
            'show -p EnvironmentFiles --value cloudflared') printf '\n' ;;
            'show -p Environment --value cloudflared') printf 'TUNNEL_GRACE_PERIOD=30s\n' ;;
        esac
        return 0
    }
    [ "$(_cf_grace_wait_seconds)" -eq 65 ]
); then
    pass 'cloudflared grace deadline prefers the systemd-resolved launch line over the environment'
else
    fail 'cloudflared grace deadline prefers the systemd-resolved launch line over the environment'
fi

# Settings from EnvironmentFile= OVERRIDE Environment=, and later files override earlier ones.
# The file list only exists in systemd's view (a drop-in may add it), so the text cannot be
# used to enumerate it. Here the file says 120s while Environment says 30s.
if (
    INIT_SYSTEM=systemd
    CF_EFF3_UNIT="$TMP/cf-eff3.service"
    CF_EFF3_ENV="$TMP/cf-eff3.env"
    : > "$CF_EFF3_UNIT"
    printf '# leading comment\nTUNNEL_GRACE_PERIOD=30s\nTUNNEL_GRACE_PERIOD=120s\n' > "$CF_EFF3_ENV"
    _cf_unit_path() { printf '%s' "$CF_EFF3_UNIT"; }
    systemctl() {
        case "$*" in
            'show -p LoadState --value cloudflared')  printf 'loaded\n' ;;
            'show -p ExecStart --value cloudflared')  printf '{ path=/usr/local/bin/cloudflared ; argv[]=/usr/local/bin/cloudflared tunnel run --token x ; ignore_errors=no ; status=0/0 }\n' ;;
            'show -p EnvironmentFiles --value cloudflared') printf '%s (ignore_errors=no)\n' "$CF_EFF3_ENV" ;;
            'show -p Environment --value cloudflared') printf 'TUNNEL_GRACE_PERIOD=30s\n' ;;
        esac
        return 0
    }
    # 120s (last assignment in the file wins) beats the Environment= 30s -> 125
    [ "$(_cf_grace_wait_seconds)" -eq 125 ]
); then
    pass 'cloudflared grace deadline honours EnvironmentFile precedence and last-assignment-wins'
else
    fail 'cloudflared grace deadline honours EnvironmentFile precedence and last-assignment-wins'
fi

# An unreadable effective configuration must fall back to the unit text, not to the default:
# `systemctl show` failing (container without a bus, old systemctl) is not evidence that the
# user configured nothing.
if (
    INIT_SYSTEM=systemd
    CF_EFF4_UNIT="$TMP/cf-eff4.service"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 80s run --token x\n' > "$CF_EFF4_UNIT"
    _cf_unit_path() { printf '%s' "$CF_EFF4_UNIT"; }
    systemctl() { return 1; }   # no bus
    [ "$(_cf_grace_wait_seconds)" -eq 85 ]
); then
    pass 'cloudflared grace deadline falls back to the unit text when systemd is unreadable'
else
    fail 'cloudflared grace deadline falls back to the unit text when systemd is unreadable'
fi

# Go time.Duration accepts ns/us/µs and the contract here is round-UP-to-seconds, so a
# sub-millisecond value must not collapse to 0s. Bare "0" is a valid Go duration
# (ParseDuration special-cases it) meaning "do not wait for in-flight requests"; unrecognised
# literals still have to be rejected so the caller falls back to the official default.
if (
    [ "$(_cf_duration_seconds 500us)"  -eq 1 ] \
        && [ "$(_cf_duration_seconds 999us)"  -eq 1 ] \
        && [ "$(_cf_duration_seconds 1ns)"    -eq 1 ] \
        && [ "$(_cf_duration_seconds 999ns)"  -eq 1 ] \
        && [ "$(_cf_duration_seconds 1500us)" -eq 1 ] \
        && [ "$(_cf_duration_seconds 1.5s)"   -eq 2 ] \
        && [ "$(_cf_duration_seconds 2s1ns)"  -eq 3 ] \
        && [ "$(_cf_duration_seconds 1m500us)" -eq 61 ] \
        && [ "$(_cf_duration_seconds 0)"      -eq 0 ] \
        && ! _cf_duration_seconds '30' >/dev/null 2>&1
); then
    pass 'cloudflared grace duration parser rounds sub-second units up'
else
    fail 'cloudflared grace duration parser rounds sub-second units up'
fi

# `--grace-period 0` means "shut down without waiting for in-flight requests", so it must be
# parsed as 0 rather than rejected (which would fall back to 30s). The margin stays as the
# SIGTERM->SIGKILL escalation ceiling: the process still has to deregister its connector.
if (
    CF_ZERO_UNIT="$TMP/cf-grace-zero.service"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 0 run --token x\n' > "$CF_ZERO_UNIT"
    _cf_unit_path() { printf '%s' "$CF_ZERO_UNIT"; }
    [ "$(_cf_grace_wait_seconds)" -eq "$CF_GRACE_MARGIN" ]
); then
    pass 'cloudflared grace-period 0 keeps only the escalation margin'
else
    fail 'cloudflared grace-period 0 keeps only the escalation margin'
fi

# A pathological value (e.g. a hand-written `--grace-period 4h`) must not stall a stop for
# hours; systemd's own TimeoutStopSec is the real backstop.
if (
    CF_CFG_HUGE="$TMP/cf-grace-huge.service"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 4h run --token x\n' > "$CF_CFG_HUGE"
    _cf_unit_path() { printf '%s' "$CF_CFG_HUGE"; }
    [ "$(_cf_grace_wait_seconds)" -eq "$(( CF_GRACE_MAX + CF_GRACE_MARGIN ))" ]
); then
    pass 'cloudflared grace deadline is capped for pathological configurations'
else
    fail 'cloudflared grace deadline is capped for pathological configurations'
fi

# Go duration literals must be parsed without bc/GNU date (target hosts may be busybox).
if (
    [ "$(_cf_duration_seconds 30s)"   -eq 30 ]  \
        && [ "$(_cf_duration_seconds 1m30s)" -eq 90 ]  \
        && [ "$(_cf_duration_seconds 2m)"    -eq 120 ] \
        && [ "$(_cf_duration_seconds 500ms)" -eq 1 ]   \
        && [ "$(_cf_duration_seconds 1.5m)"  -eq 90 ]  \
        && ! _cf_duration_seconds 'abc' >/dev/null 2>&1
); then
    pass 'cloudflared grace duration parser handles Go duration literals'
else
    fail 'cloudflared grace duration parser handles Go duration literals'
fi

# systemd stop must be asynchronous, and the wait must key on ActiveState. `is-active`
# reports "deactivating" as stopped, so it cannot answer "has the stop finished".
if (
    INIT_SYSTEM=systemd
    CF_STOP_SENTINEL="$TMP/cf-stop-request"
    rm() { :; }
    _cf_unit_path() { printf '%s' "$TMP/cloudflared-stop.service"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids() { :; }
    _cf_pids_owned() { :; }
    systemctl() {
        printf '%s\n' "$*" >> "$CF_STOP_SENTINEL"
        case "$*" in
            'show -p ActiveState --value cloudflared') printf 'inactive\n' ;;
            'show -p MainPID --value cloudflared')     printf '0\n' ;;
        esac
        return 0
    }
    _cf_kill_all >/dev/null 2>&1
    calls=$(cat "$CF_STOP_SENTINEL" 2>/dev/null)
    # The stop request must be the first *mutating* action and the wait must then key on
    # ActiveState. (Read-only `show` queries may precede it: the grace deadline is now read
    # from systemd's effective configuration before the stop is issued.)
    stop_line=$(grep -n -m1 -- '--no-block stop cloudflared' "$CF_STOP_SENTINEL" | cut -d: -f1)
    active_line=$(grep -n -m1 'show -p ActiveState --value cloudflared' "$CF_STOP_SENTINEL" | cut -d: -f1)
    [ -n "$stop_line" ] && [ -n "$active_line" ] && [ "$stop_line" -lt "$active_line" ] \
        && ! contains 'is-active' "$calls"
); then
    pass 'cloudflared systemd stop is nonblocking and waits on ActiveState'
else
    fail 'cloudflared systemd stop is nonblocking and waits on ActiveState'
fi

# A unit that is still deactivating must be waited out, and the graceful shutdown must not
# be cut short by a signal while it drains. Negative control: an `is-active`-based wait sees
# "deactivating" as stopped, proceeds instantly, and SIGTERMs the still-draining process.
if (
    INIT_SYSTEM=systemd
    CF_POLLS="$TMP/cf-deact-polls"
    CF_SLEEPS="$TMP/cf-deact-sleeps"
    CF_SIGNALS="$TMP/cf-deact-signals"
    : > "$CF_POLLS"
    rm() { :; }
    _cf_unit_path() { printf '%s' "$TMP/cloudflared-deact.service"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids() { :; }
    _cf_pids_owned() {
        printf 'poll\n' >> "$CF_POLLS"
        [ "$(wc -l < "$CF_POLLS")" -le 2 ] && printf '4242\n'
        return 0
    }
    systemctl() {
        case "$*" in
            'show -p ActiveState --value cloudflared')
                if [ "$(wc -l < "$CF_POLLS")" -ge 3 ]; then printf 'inactive\n'; else printf 'deactivating\n'; fi ;;
            'show -p MainPID --value cloudflared')
                if [ "$(wc -l < "$CF_POLLS")" -ge 3 ]; then printf '0\n'; else printf '4242\n'; fi ;;
        esac
        return 0
    }
    kill() { printf '%s\n' "$1" >> "$CF_SIGNALS"; return 0; }
    sleep() { printf '1\n' >> "$CF_SLEEPS"; }
    _cf_kill_all >/dev/null 2>&1
    [ "$(wc -l < "$CF_SLEEPS")" -eq 2 ] && [ ! -s "$CF_SIGNALS" ]
); then
    pass 'cloudflared stop waits through deactivating without signalling'
else
    fail 'cloudflared stop waits through deactivating without signalling'
fi

# SIGKILL is a last resort: it must only fire after the grace period cloudflared was actually
# started with elapsed, and SIGTERM must come first. The unit here carries `--grace-period 60s`,
# so a hardcoded 35s deadline (or the old fixed 3s window) fails this assertion -- the process
# would be SIGKILLed while still draining in-flight tunnel requests.
if (
    INIT_SYSTEM=systemd
    CF_EVENTS="$TMP/cf-grace-events"
    CF_GRACE_UNIT="$TMP/cloudflared-grace.service"
    rm() { :; }
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 60s run --token x\n' > "$CF_GRACE_UNIT"
    _cf_unit_path() { printf '%s' "$CF_GRACE_UNIT"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids() { :; }
    _cf_pids_owned() { printf '4242\n'; }
    systemctl() {
        case "$*" in
            'show -p ActiveState --value cloudflared') printf 'deactivating\n' ;;
            'show -p MainPID --value cloudflared')     printf '4242\n' ;;
        esac
        return 0
    }
    kill() { printf 'kill %s\n' "$1" >> "$CF_EVENTS"; return 0; }
    sleep() { printf 'sleep\n' >> "$CF_EVENTS"; }
    _cf_kill_all >/dev/null 2>&1
    sleeps_before_sigkill=$(awk '/^kill -9$/ { print n; exit } /^sleep$/ { n++ }' "$CF_EVENTS")
    [ -n "$sleeps_before_sigkill" ] \
        && [ "$sleeps_before_sigkill" -ge 65 ] \
        && [ "$(grep -m1 '^kill' "$CF_EVENTS")" = 'kill -15' ]
); then
    pass 'cloudflared SIGKILL only after the configured grace window, SIGTERM first'
else
    fail 'cloudflared SIGKILL only after the configured grace window, SIGTERM first'
fi

# A process disappearing is NOT proof that the unit finished stopping. After SIGKILL the unit
# can still be deactivating (cgroup teardown) and, because cloudflared's own unit is
# `Restart=on-failure`, systemd may already have queued a restart. Declaring "stopped" here
# makes _cf_restart `systemctl start` 2s later race that job. So: stop again, then re-verify.
# Negative control: without the re-stop the sentinel stays empty.
if (
    INIT_SYSTEM=systemd
    CF_REVERIFY_LOG="$TMP/cf-reverify-log"
    CF_REVERIFY_UNIT="$TMP/cloudflared-reverify.service"
    rm() { :; }
    : > "$CF_REVERIFY_LOG"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 5s run --token x\n' > "$CF_REVERIFY_UNIT"
    _cf_unit_path() { printf '%s' "$CF_REVERIFY_UNIT"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids() { :; }
    # Still owned before the SIGKILL, gone afterwards.
    _cf_pids_owned() { grep -q 'kill -9' "$CF_REVERIFY_LOG" || printf '4242\n'; }
    systemctl() {
        printf '%s\n' "$*" >> "$CF_REVERIFY_LOG"
        case "$*" in
            'show -p ActiveState --value cloudflared') printf 'deactivating\n' ;;
            'show -p MainPID --value cloudflared')     printf '4242\n' ;;
        esac
        return 0
    }
    kill() { printf 'kill %s\n' "$1" >> "$CF_REVERIFY_LOG"; return 0; }
    sleep() { :; }
    _cf_kill_all >/dev/null 2>&1
    # order: ... kill -9 ... then a second `--no-block stop cloudflared` after it
    after_kill=$(sed -n '/^kill -9$/,$p' "$CF_REVERIFY_LOG")
    contains '--no-block stop cloudflared' "$after_kill" \
        && contains 'show -p ActiveState --value cloudflared' "$after_kill"
); then
    pass 'cloudflared re-verifies the systemd stop terminal state after SIGKILL'
else
    fail 'cloudflared re-verifies the systemd stop terminal state after SIGKILL'
fi

# ...and if the unit refuses to reach a terminal state within that re-verification window, the
# stop must not silently claim success either.
if (
    INIT_SYSTEM=systemd
    CF_REVERIFY_TIMEOUT="$TMP/cf-reverify-timeout"
    CF_REVERIFY_UNIT2="$TMP/cloudflared-reverify2.service"
    rm() { :; }
    : > "$CF_REVERIFY_TIMEOUT"
    printf '[Service]\nExecStart=/usr/local/bin/cloudflared tunnel --grace-period 5s run --token x\n' > "$CF_REVERIFY_UNIT2"
    _cf_unit_path() { printf '%s' "$CF_REVERIFY_UNIT2"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids() { :; }
    _cf_pids_owned() { grep -q 'kill -9' "$CF_REVERIFY_TIMEOUT" || printf '4242\n'; }
    systemctl() {
        case "$*" in
            'show -p ActiveState --value cloudflared') printf 'deactivating\n' ;;
            'show -p MainPID --value cloudflared')     printf '4242\n' ;;
        esac
        return 0
    }
    kill() { printf 'kill %s\n' "$1" >> "$CF_REVERIFY_TIMEOUT"; return 0; }
    sleep() { printf 's\n' >> "$CF_REVERIFY_TIMEOUT"; }
    _cf_kill_all >/dev/null 2>&1
    # The re-verification wait is bounded (CF_STOP_REVERIFY), not unbounded.
    rewait=$(awk '/^kill -9$/{f=1;next} f&&/^s$/{n++} END{print n+0}' "$CF_REVERIFY_TIMEOUT")
    [ "$rewait" -le "$CF_STOP_REVERIFY" ] && [ "$rewait" -ge 1 ]
); then
    pass 'cloudflared post-SIGKILL verification is bounded'
else
    fail 'cloudflared post-SIGKILL verification is bounded'
fi

# "Cannot read the unit state" is NOT "the unit has stopped". _cf_unit_stopped documents rc 2 as
# "do not conclude anything", so folding 2 into the success branch lets `_cf_kill_all` announce a
# clean stop it never verified -- and _cf_restart would then start a second connector.
# Negative control: restoring `*) return 0` makes this return 0 and the assertion fails.
if (
    INIT_SYSTEM=systemd
    _cf_pids_owned() { :; }
    systemctl() { return 1; }   # bus unavailable / state unreadable
    sleep() { :; }
    _cf_wait_exit 3 >/dev/null 2>&1
    [ "$?" -ne 0 ]
); then
    pass 'cloudflared wait exit treats an unreadable unit state as unverified'
else
    fail 'cloudflared wait exit treats an unreadable unit state as unverified'
fi

# ...and that unverified verdict must reach the caller: with every process gone but the unit
# state unreadable, _cf_kill_all must NOT report success. Otherwise _cf_restart starts a second
# cloudflared and _uninstall_cloudflared deletes the service definition/credentials on the
# strength of a check that never answered.
if (
    INIT_SYSTEM=systemd
    rm() { :; }
    _cf_unit_path() { printf '%s' "$TMP/cloudflared-unreadable.service"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids() { :; }
    _cf_pids_owned() { :; }
    systemctl() { return 1; }
    sleep() { :; }
    _cf_kill_all >/dev/null 2>&1
    [ "$?" -ne 0 ]
); then
    pass 'cloudflared kill-all refuses to claim cleanup when the unit state is unreadable'
else
    fail 'cloudflared kill-all refuses to claim cleanup when the unit state is unreadable'
fi

# The OpenRC stop path must not pay a blind fixed delay either: the owned-process
# cleanup below already confirms that nothing survived the stop request.
if (
    INIT_SYSTEM=openrc
    CF_OPENRC_SLEEPS="$TMP/cf-openrc-sleeps"
    CF_OPENRC_STOPPED="$TMP/cf-openrc-stopped"
    rm() { :; }
    _cf_unit_path() { printf '%s' "$TMP/cloudflared-openrc.conf"; }
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_pids_owned() { :; }
    _cf_pids() { :; }
    rc-service() { printf '%s\n' "$*" >> "$CF_OPENRC_STOPPED"; }
    sleep() { printf '%s\n' "$1" >> "$CF_OPENRC_SLEEPS"; }
    _cf_kill_all >/dev/null 2>&1 \
        && [ "$(cat "$CF_OPENRC_STOPPED")" = 'cloudflared stop' ] \
        && [ ! -s "$CF_OPENRC_SLEEPS" ]
); then
    pass 'cloudflared openrc stop skips fixed wait when already clean'
else
    fail 'cloudflared openrc stop skips fixed wait when already clean'
fi

# A delayed init-system start waits for readiness, not a blind fixed delay.
if (
    CF_SLEEP_SENTINEL="$TMP/cf-delayed-sleeps"
    CF_READY_COUNT="$TMP/cf-ready-count"
    INIT_SYSTEM=systemd
    : > "$CF_READY_COUNT"
    _cf_kill_all() { return 0; }
    _cf_is_managed_running() {
        local n; n=$(wc -l < "$CF_READY_COUNT"); n=$((n+1)); printf '%s\n' "$n" >> "$CF_READY_COUNT"
        [ "$n" -ge 2 ]
    }
    systemctl() { [ "$1" = start ]; }
    sleep() { printf '%s\n' "$1" >> "$CF_SLEEP_SENTINEL"; }
    _cf_restart >/dev/null 2>&1 \
        && [ "$(wc -l < "$CF_SLEEP_SENTINEL")" -eq 2 ] \
        && [ "$(tail -n 1 "$CF_SLEEP_SENTINEL")" = 1 ]
); then
    pass 'cloudflared restart polls delayed service readiness'
else
    fail 'cloudflared restart polls delayed service readiness'
fi

# Without an authoritative liveness helper, stop is not proof of exit.
if (
    XRAY_STOP_SENTINEL="$TMP/xray-stop-called"
    INIT_SYSTEM=direct
    XRAY_DEPLOY_CORE_LOCK_HELD=1
    unset -f _xray_is_running
    _with_core_lock() { "$@"; }
    _manage_xray() { printf 'stop\n' >> "$XRAY_STOP_SENTINEL"; }
    _xray_stop_and_verify >/dev/null 2>&1 && exit 1
    [ ! -e "$XRAY_STOP_SENTINEL" ]
); then
    pass 'Xray destructive stop refuses unverifiable liveness'
else
    fail 'Xray destructive stop refuses unverifiable liveness'
fi

printf '== logrotate state contracts ==\n'
rm -f "$STATE_DIR/logrotate_enabled"
check_eq 'missing logrotate state is unset' unset "$(_logrotate_enabled_state)"
_state_set logrotate_enabled off
check_eq 'explicit logrotate disable is retained' off "$(_logrotate_enabled_state)"
if (
    LOGROTATE_CONF="$TMP/logrotate-disabled.conf"
    : > "$LOGROTATE_CONF"
    _state_set() { return 1; }
    _logrotate_disable >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 2 ] && [ ! -e "$LOGROTATE_CONF" ]
); then
    pass 'logrotate reports state-only disable failure'
else
    fail 'logrotate reports state-only disable failure'
fi


printf '== cross-backend config lock ==\n'
LOCK_ROOT="$TMP/mixed-locks"
mkdir -p "$LOCK_ROOT"
_deploy_lock_root() { printf '%s' "$LOCK_ROOT"; }
LOCK_FILE="$LOCK_ROOT/config.lock"
LOCK_DIR="$LOCK_ROOT/config.lock.d"
{ exec {TEST_LOCK_FD}>>"$LOCK_FILE"; } 2>/dev/null
flock -n "$TEST_LOCK_FD"
if _xray_primary_flock_marker_take "$TEST_LOCK_FD" "$LOCK_FILE" "$LOCK_DIR" 'test config'; then
    if (
        command() { [ "${1:-}" = -v ] && [ "${2:-}" = flock ] && return 1; builtin command "$@"; }
        _with_config_lock :
    ) >/dev/null 2>&1; then
        fail 'mkdir backend excluded by active flock marker'
    else
        pass 'mkdir backend excluded by active flock marker'
    fi
    _xray_primary_flock_marker_release "$LOCK_FILE" "$LOCK_DIR" 'test config'
else
    fail 'flock backend creates exclusion marker'
fi
flock -u "$TEST_LOCK_FD"; eval "exec ${TEST_LOCK_FD}>&-"

printf '== clash derivation runs under the config lock ==\n'
# 十二轮 P2: clash.yaml 是 Xray 节点与官方 Hysteria 节点**共用**的派生文件, 追加/替换/去重
# 都是读-改-写 ⇒ 不进 config lock 就会丢条目。探针把"写"缩短成记录锁状态, 观察写发生时
# 是否持有 flock 后端见证标记 —— 见证目录只在持锁期间存在(`_xray_primary_flock_marker_take`)。
CLASH_PROBE_META="$TMP/clash-probe.json"
CLASH_PROBE_STATE="$TMP/clash-probe-state"
printf '{"name":"lock-probe"}\n' > "$CLASH_PROBE_META"
_clash_lock_probe() {   # $1=标签, 其余=被观察的调用; 输出 "<标签>=<held|free> rc=<rc> leak=<yes|no>"
    local label="$1" rc after
    shift
    CLASH_YAML="$TMP/clash-probe-${label}.yaml"
    printf 'proxies:\n  - {name: "lock-probe", type: vless}\n' > "$CLASH_YAML"
    : > "$CLASH_PROBE_STATE"
    _probe_lock_state() {
        local d
        d="$(_deploy_lock_root)/config.lock.d"
        if [ -f "$d/.witness" ]; then printf 'held'; else printf 'free'; fi
    }
    _rebuild_clash_line() { printf '%s' '- {name: "lock-probe"}'; }
    _hysteria_clash_line() { printf '%s' '- {name: "lock-probe"}'; }
    _replace_node_in_yaml() { _probe_lock_state > "$CLASH_PROBE_STATE"; return 0; }
    _add_node_to_yaml() { _probe_lock_state > "$CLASH_PROBE_STATE"; return 0; }
    "$@" >/dev/null 2>&1; rc=$?
    after=no
    [ -e "$(_deploy_lock_root)/config.lock.d" ] && after=yes
    printf '%s=%s rc=%s leak=%s\n' "$label" "$(cat "$CLASH_PROBE_STATE" 2>/dev/null)" "$rc" "$after"
}
XH_CLASH_PROBE=$(_clash_lock_probe xray _sync_node_clash "$CLASH_PROBE_META")
XH_HY_PROBE=$(_clash_lock_probe hysteria _hysteria_sync_clash "$CLASH_PROBE_META")
# 已持锁时的嵌套调用必须直接执行(经 XRAY_DEPLOY_LOCK_HELD), 不得再等一次锁(那会 14s 后失败)
XH_NESTED_PROBE=$(_clash_lock_probe nested _with_config_lock _sync_node_clash "$CLASH_PROBE_META")
check_eq 'Xray clash write holds the config lock' 'xray=held rc=0 leak=no' "$XH_CLASH_PROBE"
check_eq 'Hysteria clash write holds the config lock' 'hysteria=held rc=0 leak=no' "$XH_HY_PROBE"
check_eq 'nested clash sync is reentrant' 'nested=held rc=0 leak=no' "$XH_NESTED_PROBE"

printf '== interrupted installer recovery ==\n'
_test_extract_install_fn() {
    awk -v fn="$1" '$0 ~ "^" fn "[[:space:]]*[(][)]" {p=1} p{print} p && /^}/{exit}' "$ROOT/install.sh"
}
(
    set -u
    DEPLOY_DIR="$TMP/recovery-deploy"
    ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.4242"
    LIB_MODULES=""; TPL_NAMES=""
    mkdir -p "$DEPLOY_DIR" "$ROLLBACK_DIR"
    eval "$(_test_extract_install_fn _manifest_relpaths)"
    eval "$(_test_extract_install_fn _install_fsync)"
    eval "$(_test_extract_install_fn _install_fsync_or_warn)"
    eval "$(_test_extract_install_fn _install_backup_identical)"
    eval "$(_test_extract_install_fn _install_backup)"
    eval "$(_test_extract_install_fn _install_txn_marker)"
    eval "$(_test_extract_install_fn _install_snapshot_read_entries)"
    eval "$(_test_extract_install_fn _install_snapshot_validate)"
    eval "$(_test_extract_install_fn _install_rollback)"
    eval "$(_test_extract_install_fn _install_finish_transaction)"
    eval "$(_test_extract_install_fn _install_recover_interrupted)"
    printf 'old-version\n' > "$DEPLOY_DIR/VERSION"
    _install_backup >/dev/null 2>&1
    # Recovery must use the snapshot's persisted entries, not a changed current manifest.
    LIB_MODULES="new-module.sh"; TPL_NAMES="new-template"
    : > "$ROLLBACK_DIR/.INSTALLING"
    printf 'mixed-version\n' > "$DEPLOY_DIR/VERSION"
    _install_recover_interrupted >/dev/null 2>&1 || exit 1
    [ "$(cat "$DEPLOY_DIR/VERSION")" = old-version ] || exit 1
    [ ! -e "$ROLLBACK_DIR" ] || exit 1
) && pass 'active installer transaction restores prior snapshot' || fail 'active installer transaction restores prior snapshot'
(
    set -u
    DEPLOY_DIR="$TMP/incomplete-deploy"
    ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.4243"
    LIB_MODULES=""; TPL_NAMES=""
    mkdir -p "$DEPLOY_DIR" "$ROLLBACK_DIR"
    eval "$(_test_extract_install_fn _manifest_relpaths)"
    eval "$(_test_extract_install_fn _install_fsync)"
    eval "$(_test_extract_install_fn _install_fsync_or_warn)"
    eval "$(_test_extract_install_fn _install_backup_identical)"
    eval "$(_test_extract_install_fn _install_backup)"
    eval "$(_test_extract_install_fn _install_txn_marker)"
    eval "$(_test_extract_install_fn _install_snapshot_read_entries)"
    eval "$(_test_extract_install_fn _install_snapshot_validate)"
    eval "$(_test_extract_install_fn _install_rollback)"
    eval "$(_test_extract_install_fn _install_finish_transaction)"
    eval "$(_test_extract_install_fn _install_recover_interrupted)"
    printf 'mixed-version\n' > "$DEPLOY_DIR/VERSION"
    _install_backup >/dev/null 2>&1
    rm -f "$ROLLBACK_DIR/VERSION"
    : > "$ROLLBACK_DIR/.INSTALLING"
    printf 'unexpected partial file\n' > "$DEPLOY_DIR/xray-deploy.sh"
    _install_recover_interrupted >/dev/null 2>&1 && exit 1
    [ -e "$ROLLBACK_DIR/.INSTALLING" ] && [ -e "$ROLLBACK_DIR/.KEEP" ]
) && pass 'incomplete install snapshot stays blocked' || fail 'incomplete install snapshot stays blocked'

(
    set -u
    DEPLOY_DIR="$TMP/empty-snapshot-deploy"
    ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.4244"
    LIB_MODULES=""; TPL_NAMES=""
    mkdir -p "$DEPLOY_DIR" "$ROLLBACK_DIR"
    printf 'live-version\n' > "$DEPLOY_DIR/VERSION"
    eval "$(_test_extract_install_fn _manifest_relpaths)"
    eval "$(_test_extract_install_fn _install_fsync)"
    eval "$(_test_extract_install_fn _install_fsync_or_warn)"
    eval "$(_test_extract_install_fn _install_backup_identical)"
    eval "$(_test_extract_install_fn _install_snapshot_read_entries)"
    eval "$(_test_extract_install_fn _install_snapshot_validate)"
    eval "$(_test_extract_install_fn _install_recover_interrupted)"
    : > "$ROLLBACK_DIR/.INSTALLING"
    : > "$ROLLBACK_DIR/.KEEP"
    _install_recover_interrupted >/dev/null 2>&1 && exit 1
    [ "$(cat "$DEPLOY_DIR/VERSION")" = live-version ]
) && pass 'empty active snapshot fails closed' || fail 'empty active snapshot fails closed'

printf '== installer snapshot durability ==\n'
# 十二轮 P2: `.KEEP` 是快照的**提交记录**, 而 rename 原子 ≠ 掉电持久。两条屏障各自可观测:
#   · cp 之后立刻比对内容 —— 半截备份必须在记账之前就被拒绝;
#   · 备份文件 + 目录项先落盘, `.KEEP` 才允许出现, rename 后目录项再刷一次。
_installer_probe() {   # $1=探针编号(必须纯数字: 快照读取器按目录名后缀校验)
    (
        set -u
        DEPLOY_DIR="$TMP/durable-deploy-$1"
        ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.4242$1"
        LIB_MODULES=""; TPL_NAMES=""
        mkdir -p "$DEPLOY_DIR"
        printf 'old-version\n' > "$DEPLOY_DIR/VERSION"
        printf 'old-entry\n' > "$DEPLOY_DIR/xray-deploy.sh"
        eval "$(_test_extract_install_fn _manifest_relpaths)"
        eval "$(_test_extract_install_fn _install_fsync)"
        eval "$(_test_extract_install_fn _install_fsync_or_warn)"
        eval "$(_test_extract_install_fn _install_backup_identical)"
        eval "$(_test_extract_install_fn _install_snapshot_rel_ok)"
        eval "$(_test_extract_install_fn _install_snapshot_read_entries)"
        eval "$(_test_extract_install_fn _install_backup)"
        case "$1" in
            1)
                # cp "成功"但只写了半截内容 ⇒ 必须在写 present 记录之前被拒
                cp() { printf 'half\n' > "${@: -1}"; return 0; }
                _install_backup >/dev/null 2>&1 && exit 1
                [ ! -e "$ROLLBACK_DIR/.KEEP" ] || exit 1
                ;;
            2)
                SYNC_LOG="$TMP/durable-sync.log"; : > "$SYNC_LOG"
                sync() {
                    if [ -e "$ROLLBACK_DIR/.KEEP" ]; then
                        printf 'post:%s\n' "${1:-}" >> "$SYNC_LOG"
                    else
                        printf 'pre:%s\n' "${1:-}" >> "$SYNC_LOG"
                    fi
                    return 0
                }
                _install_backup >/dev/null 2>&1 || exit 1
                grep -qx "pre:${ROLLBACK_DIR}/xray-deploy.sh" "$SYNC_LOG" || exit 1
                grep -qx "pre:${ROLLBACK_DIR}/VERSION" "$SYNC_LOG" || exit 1
                grep -qx "pre:${ROLLBACK_DIR}" "$SYNC_LOG" || exit 1
                grep -qx "post:${ROLLBACK_DIR}" "$SYNC_LOG" || exit 1
                ;;
            3)
                sync() { return 1; }
                out=$(_install_backup 2>&1) || exit 1
                [ "$(printf '%s\n' "$out" | grep -c '不支持定向刷新')" -eq 1 ] || exit 1
                ;;
            *) exit 1 ;;
        esac
        exit 0
    )
}
if _installer_probe 1; then pass 'incomplete backup copy is rejected before commit'; else fail 'incomplete backup copy is rejected before commit'; fi
if _installer_probe 2; then pass 'snapshot fsync barriers bracket the .KEEP rename'; else fail 'snapshot fsync barriers bracket the .KEEP rename'; fi
if _installer_probe 3; then pass 'missing targeted fsync degrades with one warning'; else fail 'missing targeted fsync degrades with one warning'; fi

GEO_TRANSITION_KEY=geo_transition
_state_set "$GEO_TRANSITION_KEY" off_pending
GEO_SKIP_MARKER="$TMP/geo-download-called"
(
    _ensure_dirs() { return 0; }
    _auto_migrate_geo_autoupdate() { : > "$GEO_SKIP_MARKER"; return 0; }
    _http_download() { return 91; }
    _geo_update
) >/dev/null 2>&1
if [ -e "$GEO_SKIP_MARKER" ]; then pass 'Geo off_pending skips legacy update'; else fail 'Geo off_pending skips legacy update'; fi
rm -f "$GEO_SKIP_MARKER"
(
    _geo_transition_clear
    _xray_version_ge() { return 0; }
    _geo_remove_cron_line() { return 0; }
    _state_set geo_cron on
    printf '{"geodata":{"cron":"0 3 */3 * *"}}\n' > "$CONFIG_FILE"
    _geo_finalize_legacy_cron >/dev/null 2>&1
    [ "$(_state_get geo_cron)" = off ]
) && pass 'Geo finalizer retires legacy fallback after update' || fail 'Geo finalizer retires legacy fallback after update'

HYSTERIA_CERT="$TMP/selfsigned.pem"
HYSTERIA_PIN=$(printf '%064d' 7)
printf 'test cert\n' > "$HYSTERIA_CERT"
printf '{"listen":":443","tls":{"cert":"%s"},"bandwidth":{"up":"100 mbps","down":"10 mbps"}}\n' "$HYSTERIA_CERT" > "$HYSTERIA_CONFIG"
printf '{"tls_mode":"selfsigned","sni":"example.test","pin":"%s"}\n' "$HYSTERIA_PIN" > "$HYSTERIA_SERVER_META"
printf '{"auth":"secret","name":"node-a","link_addr":"198.51.100.7","protocol":"hysteria2"}\n' > "$HYSTERIA_NODE_META"
_hysteria_cert_pin() { [ -r "$1" ] || return 1; printf '%s' "$HYSTERIA_PIN"; }
uri=$(_hysteria_build_link "$HYSTERIA_NODE_META" 2>/dev/null)
if contains "pinSHA256=$HYSTERIA_PIN" "$uri"; then pass 'self-signed URI contains verified pin'; else fail 'self-signed URI contains verified pin'; fi
line=$(_hysteria_clash_line "$HYSTERIA_NODE_META" 2>/dev/null)
if contains "fingerprint: \"$HYSTERIA_PIN\"" "$line"; then pass 'Mihomo self-signed entry contains fingerprint'; else fail 'Mihomo self-signed entry contains fingerprint'; fi
if contains 'down: "100 mbps"' "$line" && contains 'up: "10 mbps"' "$line"; then pass 'server bandwidth maps to client directions'; else fail 'server bandwidth maps to client directions'; fi
BAD_HYSTERIA_PIN=$(printf '%064d' 8)
printf '{"tls_mode":"selfsigned","sni":"example.test","pin":"%s"}\n' "$BAD_HYSTERIA_PIN" > "$HYSTERIA_SERVER_META"
if _hysteria_build_link "$HYSTERIA_NODE_META" >/dev/null 2>&1; then fail 'mismatched self-signed pin blocks URI'; else pass 'mismatched self-signed pin blocks URI'; fi

printf '== Hysteria terminal stop and reset quarantine ==\n'
if (
    INIT_SYSTEM=systemd
    _hysteria_started=0
    _manage_hysteria() {
        case "$1" in
            start|stop) return 0 ;;
            status) _hysteria_started=$((_hysteria_started + 1)); if [ "$_hysteria_started" -le 3 ]; then printf 'running'; else printf 'activating'; fi ;;
        esac
    }
    _hysteria_stop_and_verify() { : > "$TMP/hysteria-stop-verified"; return 1; }
    _hysteria_validate_transient >/dev/null 2>&1 && exit 1
    [ -e "$TMP/hysteria-stop-verified" ]
); then pass 'transient Hysteria validation uses terminal stop verifier'; else fail 'transient Hysteria validation uses terminal stop verifier'; fi
printf 'corrupt journal' > "$DEPLOY_DIR/.reset-journal.json.corrupt"
printf 'snapshot' > "$DEPLOY_DIR/.reset-snapshot-sentinel"
if _reset_config_recover_locked >/dev/null 2>&1; then fail 'reset quarantine stays fail-closed'; else pass 'reset quarantine stays fail-closed'; fi
[ -e "$DEPLOY_DIR/.reset-snapshot-sentinel" ] || fail 'reset quarantine preserves snapshot'
if (
    sync() { return 1; }
    _reset_fsync_strict "$TMP/reset-artifact" >/dev/null 2>&1
); then fail 'reset strict fsync rejects targeted flush failure'; else pass 'reset strict fsync rejects targeted flush failure'; fi

if (
    INIT_SYSTEM=systemd
    CF_BIN="$TMP/cloudflared-installed"
    CF_UNIT_SYSTEMD="$TMP/cloudflared.service"
    CF_UNIT_OPENRC="$TMP/cloudflared.init"
    CF_STATE_AUTOUPDATE="$STATE_DIR/cf-autoupdate"
    CF_STATE_HTTP2="$STATE_DIR/cf-http2"
    CF_STATE_EDGE_IP="$STATE_DIR/cf-edge-ip"
    CF_STATE_TOKEN="$STATE_DIR/cf-token"
    : > "$CF_BIN"; : > "$CF_UNIT_SYSTEMD"
    _cf_kill_all() { return 1; }
    _uninstall_cloudflared >/dev/null 2>&1 && exit 1
    [ -f "$CF_BIN" ] && [ -f "$CF_UNIT_SYSTEMD" ]
); then pass 'cloudflared uninstall preserves service on unresolved cleanup'; else fail 'cloudflared uninstall preserves service on unresolved cleanup'; fi
if (
    CF_BIN="$TMP/cloudflared-dir"
    mkdir -p "$CF_BIN"
    _error() { :; }
    if _install_cloudflared_bin >/dev/null 2>&1; then exit 1; fi
    [ -d "$CF_BIN" ]
); then pass 'cloudflared directory target rejected'; else fail 'cloudflared directory target rejected'; fi
if (
    LOGROTATE_CONF="$TMP/logrotate-repair.conf"
    _state_set logrotate_enabled on
    _logrotate_ensure_package() { return 0; }
    _logrotate_enable >/dev/null 2>&1 && grep -q 'rotate 30' "$LOGROTATE_CONF"
); then pass 'logrotate enabled state repairs missing config'; else fail 'logrotate enabled state repairs missing config'; fi

printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
