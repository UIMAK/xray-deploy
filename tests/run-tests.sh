#!/usr/bin/env bash
# xray-deploy focused regression suite.
# This suite intentionally tests observable behavior, not private source layout.
# 桩函数由 source 进来的生产模块间接调用; fixture 变量同样供这些模块消费。
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# mktemp 失败必须立即停: 否则 TMP 为空会让派生路径塌缩到 / 根下并在 root 下创建真实目录。
if ! TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-deploy-test.XXXXXX"); then
    printf 'FAIL - cannot create temp dir; aborting to avoid /-rooted paths\n' >&2
    exit 1
fi
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
. "$ROOT/lib/35-warp.sh"
. "$ROOT/lib/40-cloudflared.sh"
. "$ROOT/lib/45-logrotate.sh"
. "$ROOT/lib/50-nodes.sh"
. "$ROOT/lib/51-reality-pq.sh"
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
CF_LOG="$LOG_DIR/cloudflared.log"
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
mkdir -p "$DEPLOY_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$STATE_DIR" "$ASSET_DIR" "$NODES_DIR" "$CERT_DIR" "$BIN_DIR" "$LOG_DIR" "$HYSTERIA_DATA_DIR" "$HYSTERIA_BACKUP_DIR" "$HYSTERIA_CERT_DIR"
_deploy_lock_root() { printf '%s' "$TMP/locks"; }
mkdir -p "$TMP/locks"
# 测试绝不碰真实服务/页缓存: 重启与 drop_caches 一律短路。
_restart_xray_verified() { return 0; }
_maybe_drop_caches() { :; }

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

printf '== config dir (confs) mechanics ==\n'
# 空 confs 目录必须被判为"没有配置": xray -confdir 遇到空目录会退化成读 STDIN 并以 rc=23
# 失败, 所以 _config_present 是防止把空目录当成有效配置的唯一闸门。
rm -f "$CONFIG_DIR"/*.json 2>/dev/null
if _config_present; then fail 'empty config dir is not present'; else pass 'empty config dir is not present'; fi
check_eq 'empty config dir merges to {}' '{}' "$(_config_merged)"
if _config_write_merged 'not-json' >/dev/null 2>&1; then fail 'merge write rejects malformed JSON'; else pass 'merge write rejects malformed JSON'; fi

printf '{"inbounds":[]}' > "$DEPLOY_DIR/config.json"
if _init_config_if_empty >/dev/null 2>&1; then fail 'unmanaged config.json rejected'; else pass 'unmanaged config.json rejected'; fi
check 'unmanaged config.json preserved' test -f "$DEPLOY_DIR/config.json"
rm -f "$DEPLOY_DIR/config.json"
# 一个顶层字段一个文件, 文件名固定, 未知字段落 99_ 前缀; 文件内容保留 {"<字段>": <值>} 外壳
# (xray -confdir 按文件合并, 裸值文件会让合并报 "Cannot index object with number")。
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"debug"},"routing":{"rules":[]},"customTop":1}' >/dev/null 2>&1
if [ -f "$CONFIG_DIR/05_routing.json" ] && [ -f "$CONFIG_DIR/99_customTop.json" ]; then
    pass 'top-level field maps to its fixed file name'
else
    fail 'top-level field maps to its fixed file name'
fi
check_eq 'conf file keeps the top-level key wrapper' 'routing' "$(jq -r 'keys[0]' "$CONFIG_DIR/05_routing.json")"
# del(.geodata) 必须真的删掉 14_geodata.json, 否则关掉 Geo 定时后核心仍会加载 geodata 段。
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{},"geodata":{"cron":"0 3 */3 * *"}}' >/dev/null 2>&1
[ -f "$CONFIG_DIR/14_geodata.json" ] || fail 'geodata field file is created'
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{}}' >/dev/null 2>&1
if [ -e "$CONFIG_DIR/14_geodata.json" ]; then fail 'removed field deletes its file'; else pass 'removed field deletes its file'; fi

# 备份/回滚的单位是整个 confs 目录。
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"}}' >/dev/null 2>&1
_backup_config >/dev/null 2>&1
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"debug"}}' >/dev/null 2>&1
_restore_config >/dev/null 2>&1
check_eq 'rollback restores the backed-up conf dir' 'warning' "$(_config_jq -r '.log.loglevel')"
# 写入闸门: 事务禁止改配置时, jq 变更必须被拒绝(否则崩溃恢复期间会二次损坏现场)。
if (
    _txn_allow_config_write() { return 1; }
    _mutate_config '.log.loglevel = "error"' >/dev/null 2>&1
); then fail 'config mutation is blocked by the write gate'; else pass 'config mutation is blocked by the write gate'; fi
check_eq 'blocked mutation leaves the config untouched' 'warning' "$(_config_jq -r '.log.loglevel')"
# 合并失败必须对调用方可见。旧写法 `_config_merged | jq ...` 在管道里丢掉合并的退出码, 而
# jq 读到 EOF 会返回 0 且无输出 ⇒ "配置读不出来"被当成"配置里没有", 调用方(如
# _hy2_cert_dir_referenced)会把仍被引用的证书目录判成无引用再 rm -rf。
printf '{"log": broken\n' > "$CONFIG_DIR/02_log.json"
if _config_jq -r '.log.loglevel' >/dev/null 2>&1; then
    fail 'unreadable conf dir makes _config_jq fail visibly'
else
    pass 'unreadable conf dir makes _config_jq fail visibly'
fi
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"}}' >/dev/null 2>&1
# DNS 编辑只动 04_dns.json, 不另跑核心预检。
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"},"routing":{"rules":[]}}' >/dev/null 2>&1
_dns_apply_ok() {
    local rc=0
    (
        printf '#!/usr/bin/env bash\nprintf "called\\n" >> "%s"\nexit 1\n' "$TMP/dns-test-called" > "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        _dns_apply "$@" >/dev/null 2>&1
    ) || rc=1
    rm -f "$XRAY_BIN"
    return "$rc"
}
check 'dns change skips the core precheck' _dns_apply_ok --arg a '1.1.1.1' '.dns = {servers: [$a]}'
check 'dns change never calls xray test' test ! -e "$TMP/dns-test-called"
if _dns_apply_ok --argjson v broken '.dns = $v'; then
    fail 'dns change rejects invalid JSON arguments'
else
    pass 'dns change rejects invalid JSON arguments'
fi
check_eq 'invalid dns change keeps the old config' '1.1.1.1' "$(_config_jq -r '.dns.servers[0]')"
if (
    : > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
    _restart_xray_verified() { return 1; }
    _dns_apply '.dns.servers = ["8.8.8.8"]' >/dev/null 2>&1
); then
    fail 'dns change reports restart failure'
else
    pass 'dns change reports restart failure'
fi
check_eq 'failed dns restart restores the old config' '1.1.1.1' "$(_config_jq -r '.dns.servers[0]')"
_dns_apply_ok --arg a '1.1.1.1' '.dns = ((.dns | if type == "object" then . else {} end) + {servers: [$a]})' >/dev/null 2>&1
check_eq 'dns change creates the dns field file' '1.1.1.1' "$(_config_jq -r '.dns.servers[0]')"
if [ -f "$CONFIG_DIR/04_dns.json" ] && [ -f "$CONFIG_DIR/05_routing.json" ] && [ ! -e "$CONFIG_DIR/14_geodata.json" ]; then
    pass 'dns change touches only the dns field file'
else
    fail 'dns change touches only the dns field file'
fi
check_eq 'dns summary reports the upstream' '1.1.1.1|' "$(_dns_summary)"
_dns_split_servers 'https+local://cloudflare-dns.com/dns-query,https+local://dns.google/dns-query'
check_eq 'dns input splits comma-separated upstreams' '2' "${#DNS_SERVER_VALUES[@]}"
check_eq 'dns input keeps first upstream' 'https+local://cloudflare-dns.com/dns-query' "${DNS_SERVER_VALUES[0]}"
check_eq 'dns input keeps second upstream' 'https+local://dns.google/dns-query' "${DNS_SERVER_VALUES[1]}"
_dns_split_servers 'tcp+local://8.8.8.8:53,quic+local://dns.adguard.com'
check_eq 'dns input accepts TCP local mode' 'tcp+local://8.8.8.8:53' "${DNS_SERVER_VALUES[0]}"
check_eq 'dns input accepts QUIC local mode' 'quic+local://dns.adguard.com' "${DNS_SERVER_VALUES[1]}"
_dns_apply_ok --argjson s '["https+local://cloudflare-dns.com/dns-query","https+local://dns.google/dns-query"]' '.dns.servers = $s' >/dev/null 2>&1
check_eq 'dns stores multiple upstreams as separate servers' '2' "$(_config_jq '.dns.servers | length')"
check_eq 'dns reports Xray parallel query default as disabled when absent' 'false' "$(_config_jq -r '.dns.enableParallelQuery // false')"
_dns_apply_ok --argjson v false '.dns.enableParallelQuery = $v' >/dev/null 2>&1
check_eq 'dns parallel query can be disabled' 'false' "$(_config_jq -r '.dns.enableParallelQuery')"
_dns_apply_ok --argjson v true '.dns.enableParallelQuery = $v' >/dev/null 2>&1
check_eq 'dns parallel query can be enabled' 'true' "$(_config_jq -r '.dns.enableParallelQuery')"
check_eq 'built-in Cloudflare DoH uses local mode' 'https+local://cloudflare-dns.com/dns-query' "$(sed -n 's/.*3) addr=\"\([^\"]*\)\".*/\1/p' "$ROOT/lib/30-geo.sh")"
check_eq 'built-in Google DoH uses local mode' 'https+local://dns.google/dns-query' "$(sed -n 's/.*4) addr=\"\([^\"]*\)\".*/\1/p' "$ROOT/lib/30-geo.sh")"
check 'manual DNS prompts for TCP local mode' grep -Fq 'tcp+local://${item#tcp://}' "$ROOT/lib/30-geo.sh"
check 'manual DNS prompts for DoH local mode' grep -Fq 'https+local://${item#https://}' "$ROOT/lib/30-geo.sh"
check 'manual DNS prompts for QUIC local mode' grep -Fq 'quic+local://${item#quic://}' "$ROOT/lib/30-geo.sh"
# queryStrategy 只有 UseIP/UseIPv4/UseIPv6 三档; 写进去后摘要必须反映出来。
_dns_apply_ok '.dns.queryStrategy = "UseIPv4"' >/dev/null 2>&1
check_eq 'dns summary reports the query strategy' 'https+local://cloudflare-dns.com/dns-query, https+local://dns.google/dns-query|UseIPv4' "$(_dns_summary)"
# 删除 DNS 段必须让 04_dns.json 消失(空文件会让核心加载空 dns 段)。
_dns_apply_ok 'del(.dns)' >/dev/null 2>&1
if [ -e "$CONFIG_DIR/04_dns.json" ]; then fail 'dns delete removes the field file'; else pass 'dns delete removes the field file'; fi
# [恢复默认] 的默认值只来自 lib/00-common.sh 的 XRAY_DEFAULT_DNS_JSON 常量; 常量被改名/删掉
# 时该菜单只会打印"缺少默认 DNS 常量"并退出, 所以必须断言恢复出来的段与常量逐字一致。
if (
    : > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
    # 确认提示从 stdin 读, 直接喂 "y" —— 不能覆盖 read 函数: _config_write_merged 自己也在
    # 用 `read -d ''` 循环拆字段, 覆盖掉会把字段名读成 "y" 而写坏候选文件。
    printf 'y\n' | _dns_restore_default >/dev/null 2>&1
); then pass 'dns restore default runs'; else fail 'dns restore default runs'; fi
check_eq 'dns restore default uses the shared constant' \
    "$(jq -cS . <<<"$XRAY_DEFAULT_DNS_JSON")" "$(_config_jq -cS '.dns')"
rm -f "$XRAY_BIN"

check 'default DNS races equivalent adjacent upstreams' _config_jq -e '
    .dns.enableParallelQuery == true
    and (.dns.servers | length == 3)
    and (.dns.servers | map(del(.address)) | unique | length == 1)
    and (.dns.servers | all(.address | startswith("https+local://")))'
check 'routing domain alias references geo data' jq -e "$GEO_RULE_REF_JQ" <<< '{"domains":["geosite:cn"]}'
check 'routing alias supports inverted external geo references' jq -e "$GEO_RULE_REF_JQ" <<< '{"domains":["!ext:custom.dat:cn"]}'
if jq -e "$GEO_RULE_REF_JQ" <<< '{"domains":["domain:example.com"]}' >/dev/null; then
    fail 'literal routing alias does not consume geo data'
else pass 'literal routing alias does not consume geo data'; fi
_config_write_merged '{"version":{"min":"26.4.25","max":""},"dns":{"servers":[{"unexpectedIPs":["geoip:private","!ext:custom.dat:cn"]}],"hosts":{"geosite:cn":"127.0.0.1","ext:hosts.dat:ads":"127.0.0.1","domain:example.com":"127.0.0.1"}},"routing":{"rules":[]}}'
check_eq 'DNS counts unexpectedIPs and geo hosts keys' '4' "$(_route_dns_geo_count)"
_config_write_merged '{"version":{"min":"26.4.25","max":""},"dns":{"servers":[{"domains":["geosite:cn"],"expectedIPs":["geoip:cn"],"expectIPs":["ext:custom.dat:cn"]}]}}'
check_eq 'DNS retains existing geo field coverage' '3' "$(_route_dns_geo_count)"
_config_write_merged '{"version":{"min":"26.4.25","max":""},"dns":{"hosts":{"!geosite:cn":"127.0.0.1","ext:hosts.dat:ads":"127.0.0.1","domain:example.com":"127.0.0.1"}}}'
check_eq 'DNS hosts keys count even without upstream objects' '2' "$(_route_dns_geo_count)"
_config_write_merged '{"version":{"min":"26.4.25","max":""},"dns":{"hosts":null,"servers":["1.1.1.1"]}}'
check_eq 'DNS missing optional fields consumes no geo data' '0' "$(_route_dns_geo_count)"

printf '== launch contract (confdir + strict JSON) ==\n'
# 启动契约: confdir 与 XRAY_JSON_STRICT 只能通过启动参数/shell 环境传, 不能写进
# config 的 env 段 —— Xray 必须先选定 JSON 解析器才能读配置。这里注入 env 后检查配置里除了
# XRAY_LOCATION_ASSET 没有别的键、且没有任何值指向 confs 目录; 有人"顺手"把严格开关塞进
# env 段时这条会立刻变红。
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{},"inbounds":[]}' >/dev/null 2>&1
_auto_ensure_config_env_write >/dev/null 2>&1
check_eq 'config env carries only XRAY_LOCATION_ASSET' 'XRAY_LOCATION_ASSET' "$(_config_jq -r '.env | keys_unsorted | join(",")')"
check_eq 'config env value points at the asset dir' "$ASSET_DIR" "$(_config_jq -r '.env.XRAY_LOCATION_ASSET')"
if _config_jq -e --arg d "$CONFIG_DIR" \
     '((.env // {}) | to_entries | any(.key == "XRAY_JSON_STRICT" or (.value | tostring | contains($d)))) // false' \
     >/dev/null 2>&1; then
    fail 'strict JSON switch and confdir stay out of the config env block'
else
    pass 'strict JSON switch and confdir stay out of the config env block'
fi

printf '== menu layout ==\n'
# 中文在终端占 2 列, printf 的 %-Ns 按字符数补空格 ⇒ 双栏会错位。宽度必须按字节类判定;
# (字节数-字符数)/2 的旧算法在 2 字节字符个数为奇数时会多算 1 列(如 "a··" 会算成 4)。
check_eq 'ascii width' 3 "$(_menu_display_width abc)"
check_eq 'cjk width' 4 "$(_menu_display_width 中文)"
check_eq 'mixed-width odd count' 3 "$(_menu_display_width 'a··')"
check_eq 'wide dash width' 2 "$(_menu_display_width '—')"
# 用 $'\033' 而不是 GNU sed 的 \x1b: busybox sed 不解释 \x1b, 转义会留在串里让下一条假失败。
_menu_row_plain=$(_menu_row 1 "添加节点" 2 "查看节点" | sed $'s/\033\[[0-9;]*m//g')
# 只量左段宽度的话, 右格整块丢失时 ${…%%\[2\]*} 会匹配不到而退化成量整行, 宽度仍是列宽 ⇒
# 断言假通过。右格存在性必须显式断言。
if contains '[2] 查看节点' "$_menu_row_plain"; then pass 'two-column row keeps the right cell'; else fail 'two-column row keeps the right cell'; fi
check_eq 'two-column row aligns the right cell' 23 "$(_menu_display_width "${_menu_row_plain%%\[2\]*}")"

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

# state 读写往返用命名空间化的测试键, 不借用生产 state marker(否则会污染后续迁移用例)。
_state_set xd_test_state_roundtrip sample-value
check_eq 'state marker persists' sample-value "$(_state_get xd_test_state_roundtrip)"
rm -f "$STATE_DIR/xd_test_state_roundtrip"

printf '{"name":"shared-name"}\n' > "$NODES_DIR/xray.json"
if _hysteria_name_taken shared-name; then pass 'shared Clash name collision rejected'; else fail 'shared Clash name collision rejected'; fi
rm -f "$NODES_DIR/xray.json"
# Xray Hy2 的协议键是 `hysteria`, 与节点元数据中的 "hysteria2" 区分。
# ⇒ Hy2 节点落在跳跃范围内时被静默放行(该 UDP 端口随后被官方 REDIRECT 抢走)。
# `.port` 又是 PortList(单端口 / 范围 / 逗号多段) ⇒ 必须按区间相交判定, 不能等值比较。
# NODES_DIR 指向空目录, 使这些断言只检验 config 入站分支(分支 c 另有专测)。
XH_PORT_CONFS="$TMP/xray-portlist-confs"
XH_NODES_EMPTY="$TMP/xh-nodes-empty"
mkdir -p "$XH_PORT_CONFS" "$XH_NODES_EMPTY"
ss() { printf 'Netid State Local Address:Port Peer Address:Port\n'; }
_xh_hop_conflict() {   # $1=入站 JSON, $2/$3=跳跃范围, $4=exclude; 判为冲突返回 0
    local saved_cfg="$CONFIG_DIR" saved_nodes="$NODES_DIR" rc
    CONFIG_DIR="$XH_PORT_CONFS"; NODES_DIR="$XH_NODES_EMPTY"
    _config_write_merged "$(printf '{"version":{"min":"26.4.25","max":""},"inbounds":[%s]}' "$1")" >/dev/null 2>&1
    _hysteria_check_hop_conflicts "$2" "$3" ${4:+"$4"} >/dev/null 2>&1; rc=$?
    CONFIG_DIR="$saved_cfg"; NODES_DIR="$saved_nodes"
    [ "$rc" -ne 0 ]
}
check 'Xray hysteria PortList overlap rejected' _xh_hop_conflict \
    '{"protocol":"hysteria","port":"30000,31000-32000"}' 31500 31500
check 'Xray hysteria single port inside hop range rejected' _xh_hop_conflict \
    '{"protocol":"hysteria","port":30000}' 20000 40000
check 'Xray WireGuard inbound flagged as UDP conflict' _xh_hop_conflict \
    '{"protocol":"wireguard","port":31500}' 20000 40000
if _xh_hop_conflict '{"protocol":"wireguard","port":443}' 20000 40000; then
    fail 'Xray WireGuard outside hop range allowed'
else
    pass 'Xray WireGuard outside hop range allowed'
fi
check 'own socket exclusion does not exempt Xray WireGuard config port' _xh_hop_conflict \
    '{"protocol":"wireguard","port":31500}' 20000 40000 31500
check 'Xray hysteria port range overlapping hop range rejected' _xh_hop_conflict \
    '{"protocol":"hysteria","port":"30000-31000"}' 30500 32000
if _xh_hop_conflict '{"protocol":"hysteria","port":443}' 20000 40000; then fail 'Xray hysteria outside hop range allowed'; else pass 'Xray hysteria outside hop range allowed'; fi
if _xh_hop_conflict '{"protocol":"vless","port":31500,"streamSettings":{"network":"raw"}}' 20000 40000; then fail 'TCP-only Reality not flagged as UDP conflict'; else pass 'TCP-only Reality not flagged as UDP conflict'; fi
if _xh_hop_conflict '{"protocol":"tunnel","port":31500,"settings":{"network":"tcp"}}' 20000 40000; then fail 'TCP-only tunnel not flagged as UDP conflict'; else pass 'TCP-only tunnel not flagged as UDP conflict'; fi
check 'UDP-capable dokodemo-door flagged' _xh_hop_conflict \
    '{"protocol":"dokodemo-door","port":31500,"settings":{"network":"tcp,udp"}}' 20000 40000
for proto in tunnel dokodemo-door; do
    for network in udp tcp,udp; do
        check "$proto allowedNetwork=$network flagged" _xh_hop_conflict \
            "{\"protocol\":\"$proto\",\"port\":31500,\"settings\":{\"allowedNetwork\":\"$network\"}}" 20000 40000
    done
    for settings in '{"allowedNetwork":"tcp"}' '{}' '{"allowedNetwork":"tcp","network":"udp"}'; do
        if _xh_hop_conflict "{\"protocol\":\"$proto\",\"port\":31500,\"settings\":$settings}" 20000 40000; then
            fail "$proto TCP-only settings=$settings allowed"
        else
            pass "$proto TCP-only settings=$settings allowed"
        fi
    done
    check "$proto allowedNetwork=udp takes precedence over legacy tcp" _xh_hop_conflict \
        "{\"protocol\":\"$proto\",\"port\":31500,\"settings\":{\"allowedNetwork\":\"udp\",\"network\":\"tcp\"}}" 20000 40000
done

_test_udp_snapshot() (
    local backend="$1" lo="$2" hi="$3" exclude="$4" expected="$5" rows="$6" rc=0
    local calls="$TMP/udp-snapshot-calls"
    : > "$calls"
    # 本用例的隔离点: CONFIG_DIR 只在子 shell 内改向, 有意不外泄到外层。
    # shellcheck disable=SC2030
    CONFIG_DIR="$TMP/no-snapshot-config"
    NODES_DIR="$XH_NODES_EMPTY"
    command() {
        if [ "${1:-}" = -v ]; then
            case "${2:-}" in
                ss) [ "$backend" = ss ]; return $? ;;
                netstat) return 0 ;;
            esac
        fi
        builtin command "$@"
    }
    ss() {
        printf 'ss %s\n' "$*" >> "$calls"
        printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n%s\n' "$rows"
    }
    netstat() {
        printf 'netstat %s\n' "$*" >> "$calls"
        printf 'Active Internet connections (only servers)\nProto Recv-Q Send-Q Local Address Foreign Address State\n'
        if [ "$*" = -lnu ]; then
            printf '%s\n' "$rows" | awk '$1 ~ /^udp/'
        else
            printf '%s\n' "$rows"
        fi
    }
    _hysteria_check_hop_conflicts "$lo" "$hi" "$exclude" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq "$expected" ] || return 1
    if [ "$backend" = ss ]; then
        [ "$(cat "$calls")" = 'ss -lun' ]
    else
        [ "$(cat "$calls")" = 'netstat -lnu' ]
    fi
)
check 'netstat fallback rejects IPv4 UDP listener' _test_udp_snapshot netstat 40000 40002 '' 1 'udp 0 0 0.0.0.0:40001 0.0.0.0:*'
check 'netstat fallback rejects IPv6 UDP listener' _test_udp_snapshot netstat 40000 40002 '' 1 'udp6 0 0 :::40001 :::*'
check 'netstat fallback includes lower boundary' _test_udp_snapshot netstat 40000 40002 '' 1 'udp 0 0 127.0.0.1:40000 0.0.0.0:*'
check 'netstat fallback includes upper boundary' _test_udp_snapshot netstat 40000 40002 '' 1 'udp 0 0 127.0.0.1:40002 0.0.0.0:*'
check 'netstat fallback permits UDP outside range' _test_udp_snapshot netstat 40000 40002 '' 0 'udp 0 0 0.0.0.0:40003 0.0.0.0:*'
check 'netstat UDP query permits same-number TCP listener' _test_udp_snapshot netstat 40000 40002 '' 0 'tcp 0 0 0.0.0.0:40001 0.0.0.0:* LISTEN'
check 'netstat fallback excludes own UDP socket' _test_udp_snapshot netstat 40000 40002 40000 0 'udp 0 0 0.0.0.0:40000 0.0.0.0:*'
check 'netstat own exclusion preserves other conflicts' _test_udp_snapshot netstat 40000 40002 40000 1 $'udp 0 0 0.0.0.0:40000 0.0.0.0:*\nudp6 0 0 :::40001 :::*'
check 'ss preferred when both tools exist' _test_udp_snapshot ss 40000 40002 '' 1 'UNCONN 0 0 0.0.0.0:40001 0.0.0.0:*'

# Shadowsocks 缺 `network` 在核心里默认为 TCP。
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
check 'own socket exclusion does not exclude Xray inbound' _xh_hop_conflict '{"protocol":"hysteria","port":443}' 443 50000 443

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

# PQ 返回码三态: 只有探测成功且目标不支持才是 1(调用方可移除旧 PQ);
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
    # 只喂 stdin 而不覆盖 read 内建: 覆盖 read 会污染菜单内其它 read 调用点的变量绑定。
    _xh_menu_case() { _reality_domain_menu >/dev/null 2>&1 <<< $'1\nnew.example\n'; }
    for XH_PQ_RC in 2 1 0; do
        rm -f "$XH_TXN_MARKER"
        XH_PQ_RC="$XH_PQ_RC" _xh_menu_case
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

# A failed stop whose terminal state cannot be verified must remain destructive-failure.
if (
    XRAY_STOP_SENTINEL="$TMP/xray-stop-called"
    INIT_SYSTEM=direct
    XRAY_DEPLOY_CORE_LOCK_HELD=1
    unset -f _xray_is_running
    _manage_xray() { printf 'stop\n' >> "$XRAY_STOP_SENTINEL"; return 1; }
    _xray_stopped_state() { return 2; }
    sleep() { :; }
    _xray_stop_and_verify >/dev/null 2>&1 && exit 1
    [ -e "$XRAY_STOP_SENTINEL" ]
); then
    pass 'Xray destructive stop refuses unverifiable liveness'
else
    fail 'Xray destructive stop refuses unverifiable liveness'
fi

printf '== config check and Geo state ==\n'
: > "$ASSET_DIR/geosite.dat"
: > "$ASSET_DIR/geoip.dat"
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"},"routing":{"rules":[]}}' >/dev/null 2>&1
check 'Geo builtin cron enabled' _geo_set_auto_update on
check_eq 'Geo builtin expression' "$GEO_CRON_EXPR" "$(_config_jq -r '.geodata.cron')"
check 'Geo builtin cron disabled' _geo_set_auto_update off
check 'Geo disable removes geodata fragment' test ! -e "$CONFIG_DIR/14_geodata.json"
printf '== Geo data source selection ==\n'
GEO_U_XTLS_GEOSITE='https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geosite.dat'
GEO_U_XTLS_GEOIP='https://github.com/XTLS/Xray-rules-dat/releases/latest/download/geoip-full.dat'
GEO_U_LOYAL_GEOSITE='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'
GEO_U_LOYAL_GEOIP='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
rm -f "$STATE_DIR/geo_source" "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"

check_eq 'default Geo source is XTLS' xtls "$(_geo_source_name)"
check_eq 'XTLS geosite URL keeps the upstream file name' "$GEO_U_XTLS_GEOSITE" "$(_geo_source_url geosite)"
check_eq 'XTLS geoip URL uses geoip-full.dat' "$GEO_U_XTLS_GEOIP" "$(_geo_source_url geoip)"

_state_set geo_source loyal
check_eq 'Loyalsoldier geosite URL' "$GEO_U_LOYAL_GEOSITE" "$(_geo_source_url geosite)"
check_eq 'Loyalsoldier geoip URL' "$GEO_U_LOYAL_GEOIP" "$(_geo_source_url geoip)"

_state_set geo_source custom
_state_set geo_geosite_url 'https://example.test/gs.dat'
_state_set geo_geoip_url 'https://example.test/gi.dat'
check_eq 'custom geosite URL is used verbatim' 'https://example.test/gs.dat' "$(_geo_source_url geosite)"
check_eq 'custom geoip URL is used verbatim' 'https://example.test/gi.dat' "$(_geo_source_url geoip)"
_state_set geo_geoip_url 'ftp://example.test/gi.dat'
check_eq 'broken custom geoip falls back to the default geosite' "$GEO_U_XTLS_GEOSITE" "$(_geo_source_url geosite)"
check_eq 'broken custom geoip falls back to the default geoip' "$GEO_U_XTLS_GEOIP" "$(_geo_source_url geoip)"
_state_set geo_source bogus
check_eq 'unknown Geo source falls back to the default' xtls "$(_geo_source_name)"
rm -f "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"

_state_set geo_source xtls
GEO_GD=$(_geo_geodata_json)
check_eq 'geodata assets keep fixed local file names' 'geosite.dat geoip.dat' \
    "$(printf '%s' "$GEO_GD" | jq -r '[.assets[].file] | join(" ")')"
check_eq 'geodata geoip asset points at geoip-full.dat' "$GEO_U_XTLS_GEOIP" \
    "$(printf '%s' "$GEO_GD" | jq -r '.assets[1].url')"

# 下载阶段必须"远端全量、落点固定": URL 随源变化, 目标文件名恒为 geosite.dat/geoip.dat。
GEO_DL_XTLS="$TMP/geo-dl-xtls"
(
    _ensure_dirs() { return 0; }
    _with_config_lock() { "$@"; }
    _with_core_lock() { "$@"; }
    _geo_update_commit_locked() { return 0; }
    _http_download() { printf '%s -> %s\n' "$1" "${2##*/}" >> "$GEO_DL_XTLS"; return 91; }
    _geo_update
) >/dev/null 2>&1
check_eq 'download maps the XTLS geosite URL onto geosite.dat' "$GEO_U_XTLS_GEOSITE -> geosite.dat" \
    "$(sed -n '1p' "$GEO_DL_XTLS" 2>/dev/null)"
check_eq 'download maps geoip-full.dat onto geoip.dat' "$GEO_U_XTLS_GEOIP -> geoip.dat" \
    "$(sed -n '2p' "$GEO_DL_XTLS" 2>/dev/null)"

GEO_DL_LOYAL="$TMP/geo-dl-loyal"
(
    _ensure_dirs() { return 0; }
    _with_config_lock() { "$@"; }
    _with_core_lock() { "$@"; }
    _geo_update_commit_locked() { return 0; }
    _http_download() { printf '%s -> %s\n' "$1" "${2##*/}" >> "$GEO_DL_LOYAL"; return 91; }
    _state_set geo_source loyal
    _geo_update
) >/dev/null 2>&1
check_eq 'download maps the Loyalsoldier geosite URL onto geosite.dat' "$GEO_U_LOYAL_GEOSITE -> geosite.dat" \
    "$(sed -n '1p' "$GEO_DL_LOYAL" 2>/dev/null)"
check_eq 'download maps the Loyalsoldier geoip URL onto geoip.dat' "$GEO_U_LOYAL_GEOIP -> geoip.dat" \
    "$(sed -n '2p' "$GEO_DL_LOYAL" 2>/dev/null)"

# 内置定时生效时切换必须改写 config 的 assets; 关闭时只记 state。
GEO_MUTATE_ARGS="$TMP/geo-mutate-args"
rm -f "$GEO_MUTATE_ARGS"
(
    _geo_auto_mechanism() { printf 'builtin'; }
    _mutate_config() { printf '%s\n' "$@" > "$GEO_MUTATE_ARGS"; return 0; }
    _geo_apply_source xtls
) >/dev/null 2>&1
GEO_MUTATE_TEXT=$(cat "$GEO_MUTATE_ARGS" 2>/dev/null)
if contains "$GEO_U_XTLS_GEOIP" "$GEO_MUTATE_TEXT" && contains '.geodata.assets = $a' "$GEO_MUTATE_TEXT"; then
    pass 'builtin switch rewrites the geodata assets only'
else
    fail "builtin switch rewrites the geodata assets only [$GEO_MUTATE_TEXT]"
fi
check_eq 'builtin switch records the source name' xtls "$(_state_get geo_source)"

GEO_MUTATE_MARK="$TMP/geo-mutate-called"
rm -f "$GEO_MUTATE_MARK"
if (
    _geo_auto_mechanism() { printf 'off'; }
    _mutate_config() { : > "$GEO_MUTATE_MARK"; return 0; }
    _geo_apply_source loyal >/dev/null 2>&1
    [ ! -e "$GEO_MUTATE_MARK" ] && [ "$(_state_get geo_source)" = loyal ]
); then
    pass 'cron/off switch records state without touching config'
else
    fail 'cron/off switch records state without touching config'
fi

if (
    _geo_auto_mechanism() { printf 'off'; }
    _geo_apply_source custom 'https://a.test/gs.dat' 'https://a.test/gi.dat' >/dev/null 2>&1 || exit 1
    [ "$(_state_get geo_geosite_url)" = 'https://a.test/gs.dat' ] \
        && [ "$(_state_get geo_geoip_url)" = 'https://a.test/gi.dat' ] \
        && [ "$(_geo_source_url geoip)" = 'https://a.test/gi.dat' ]
); then
    pass 'custom switch stores both links'
else
    fail 'custom switch stores both links'
fi
if (
    _geo_auto_mechanism() { printf 'off'; }
    _geo_apply_source custom 'ftp://a.test/gs.dat' 'https://a.test/gi.dat' >/dev/null 2>&1 && exit 1
    [ "$(_state_get geo_source)" = custom ]
); then
    pass 'custom switch rejects a non-https link'
else
    fail 'custom switch rejects a non-https link'
fi

# 老版本写下的 assets 仍指向旧源: 内置定时生效时必须提示重新应用。
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"},"routing":{"rules":[]},"geodata":{"cron":"0 3 */3 * *","assets":[{"url":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat","file":"geosite.dat"},{"url":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat","file":"geoip.dat"}]}}' >/dev/null 2>&1
_state_set geo_source xtls
if _geo_builtin_source_drifted; then
    pass 'legacy assets are reported as drifted'
else
    fail 'legacy assets are reported as drifted'
fi
_state_set geo_source loyal
if _geo_builtin_source_drifted; then
    fail 'assets matching the selected source are not drifted'
else
    pass 'assets matching the selected source are not drifted'
fi
rm -f "$STATE_DIR/geo_source" "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
_config_write_merged '{"version":{"min":"26.4.25","max":""},"log":{"loglevel":"warning"},"routing":{"rules":[]}}' >/dev/null 2>&1

printf '== Geo data source apply contracts ==\n'
# 回滚契约: config 写入失败时数据源必须保持原值, 不能只改一半 state。
if (
    _state_set geo_source loyal
    _geo_auto_mechanism() { printf 'builtin'; }
    _mutate_config() { return 1; }
    _geo_apply_source xtls >/dev/null 2>&1 && exit 1
    [ "$(_geo_source_name)" = loyal ]
); then
    pass 'builtin switch failure keeps the previous source'
else
    fail 'builtin switch failure keeps the previous source'
fi
# custom 的第二个参数同样要校验: 非法 geoip 链接整体拒绝, 不碰 config 也不写 state。
GEO_BAD_MARK="$TMP/geo-bad-mutate"
rm -f "$GEO_BAD_MARK"
if (
    _state_set geo_source loyal
    rm -f "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
    _geo_auto_mechanism() { printf 'builtin'; }
    _mutate_config() { : > "$GEO_BAD_MARK"; return 0; }
    _geo_apply_source custom 'https://a.test/gs.dat' 'ftp://a.test/gi.dat' >/dev/null 2>&1 && exit 1
    [ "$(_geo_source_name)" = loyal ] && [ ! -e "$GEO_BAD_MARK" ] && [ ! -e "$STATE_DIR/geo_geosite_url" ]
); then
    pass 'custom switch rejects an invalid geoip link without touching config or state'
else
    fail 'custom switch rejects an invalid geoip link without touching config or state'
fi
# 切换只换链接: 必须提示本地 dat 仍是旧源数据, 否则用户会以为已经换源。
GEO_APPLY_HINT="$TMP/geo-apply-hint"
(
    _geo_auto_mechanism() { printf 'off'; }
    _geo_apply_source xtls
) > "$GEO_APPLY_HINT" 2>&1
if contains '本地 dat 仍是旧源数据' "$(cat "$GEO_APPLY_HINT" 2>/dev/null)"; then
    pass 'source switch hints that the local dat still holds the old source'
else
    fail 'source switch hints that the local dat still holds the old source'
fi
# label 必须与实际显示的回落 URL 一致, 不能只写"自定义链接"。
_state_set geo_source custom
rm -f "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
check_eq 'custom label reports the fallback when links are missing' \
    '自定义链接(链接无效, 已回落默认)' "$(_geo_source_label)"
_state_set geo_geosite_url 'https://example.test/gs.dat'
_state_set geo_geoip_url 'ftp://example.test/gi.dat'
check_eq 'custom label reports the fallback for an invalid link' \
    '自定义链接(链接无效, 已回落默认)' "$(_geo_source_label)"
_state_set geo_geoip_url 'https://example.test/gi.dat'
check_eq 'valid custom links keep the plain label' '自定义链接' "$(_geo_source_label)"
# assets 只有一个构造点: 助手与 geodata JSON 必须给出同一份 assets。
_state_set geo_source xtls
rm -f "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
GEO_ASSETS=$(_geo_assets_json xtls)
check_eq 'assets helper keeps the fixed local file names' 'geosite.dat geoip.dat' \
    "$(printf '%s' "$GEO_ASSETS" | jq -r '[.[].file] | join(" ")')"
check_eq 'assets helper maps the geoip URL' "$GEO_U_XTLS_GEOIP" \
    "$(printf '%s' "$GEO_ASSETS" | jq -r '.[1].url')"
check_eq 'geodata json reuses the assets helper' "$(printf '%s' "$GEO_ASSETS" | jq -c '.')" \
    "$(_geo_geodata_json | jq -c '.assets')"
rm -f "$STATE_DIR/geo_source" "$STATE_DIR/geo_geosite_url" "$STATE_DIR/geo_geoip_url"
echo '== Custom geodata assets =='
GEO_EXTRA_PATH="$STATE_DIR/geo_extra_assets"
GEO_EXTRA_BIG="$TMP/geo-extra-big.dat"
printf '%4096s' '' | tr ' ' 'x' > "$GEO_EXTRA_BIG"
GEO_EXTRA_MUTATE="$TMP/geo-extra-mutate"
GEO_EXTRA_FILTER="$TMP/geo-extra-filter"
GEO_EXTRA_TOUCHED="$TMP/geo-extra-config-touched"
rm -f "$GEO_EXTRA_PATH" "$GEO_EXTRA_MUTATE" "$GEO_EXTRA_FILTER" "$GEO_EXTRA_TOUCHED"

# 添加: 先下载落盘(Xray 只认资源目录内已存在的普通文件), builtin 下再写 config, 最后记 state。
if (
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _http_download() { cp "$GEO_EXTRA_BIG" "$2"; return 0; }
    _mutate_config() { printf '%s' "$3" > "$GEO_EXTRA_MUTATE"; printf '%s' "$4" > "$GEO_EXTRA_FILTER"; return 0; }
    { echo 'https://a.test/my.dat'; echo 'my.dat'; } | _geo_extra_add
) >/dev/null 2>&1; then
    pass 'custom geodata add completes under builtin'
else
    fail 'custom geodata add completes under builtin'
fi
check_eq 'custom geodata add records the state line' 'my.dat	https://a.test/my.dat' \
    "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"
check 'custom geodata add lands the dat file' test -s "$ASSET_DIR/my.dat"
check_eq 'custom geodata add rewrites only the assets field' '.geodata.assets = $a' \
    "$(cat "$GEO_EXTRA_FILTER" 2>/dev/null)"
check_eq 'custom geodata add puts the entry into assets' 'my.dat https://a.test/my.dat' \
    "$(jq -r '.[] | select(.file=="my.dat") | .file + " " + .url' "$GEO_EXTRA_MUTATE" 2>/dev/null)"
check_eq 'custom geodata add keeps both builtin assets' 'geosite.dat geoip.dat' \
    "$(jq -r '[.[] | select(.file=="geosite.dat" or .file=="geoip.dat") | .file] | join(" ")' "$GEO_EXTRA_MUTATE" 2>/dev/null)"
check_eq 'geodata json carries the extras' 'my.dat' \
    "$(_geo_geodata_json | jq -r '.assets[] | select(.file=="my.dat") | .file' 2>/dev/null)"

# 回车取链接末段: 去掉 ?query 与 #fragment; cron/off 机制只记 state, 不写 config。
if (
    _geo_auto_mechanism() { printf 'off'; }
    _with_core_lock() { "$@"; }
    _http_download() { cp "$GEO_EXTRA_BIG" "$2"; return 0; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED"; return 0; }
    { echo 'https://a.test/dl/zeta.dat?token=1#frag'; echo ''; } | _geo_extra_add
) >/dev/null 2>&1; then
    pass 'custom geodata add accepts the default file name'
else
    fail 'custom geodata add accepts the default file name'
fi
check 'default file name drops query and fragment' test -s "$ASSET_DIR/zeta.dat"
check_eq 'default file name is recorded in state' 'zeta.dat' \
    "$(awk -F'	' '$1=="zeta.dat"{print $1}' "$GEO_EXTRA_PATH" 2>/dev/null)"
check 'cron/off mechanism adds without touching config' test ! -e "$GEO_EXTRA_TOUCHED"

# 非法输入只重问该字段: 非 https 链接、含 / 或 ..、内置名、重名都不能落 state。
if (
    _geo_auto_mechanism() { printf 'off'; }
    _with_core_lock() { "$@"; }
    _http_download() { cp "$GEO_EXTRA_BIG" "$2"; return 0; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED"; return 0; }
    {
        echo 'ftp://a.test/rs.dat'
        echo 'https://a.test/rs.dat'
        echo '../evil.dat'
        echo '.'
        echo 'geoip.dat'
        echo 'zeta.dat'
        echo 'rs.dat'
    } | _geo_extra_add
) >/dev/null 2>&1; then
    pass 'custom geodata add re-asks invalid input'
else
    fail 'custom geodata add re-asks invalid input'
fi
check_eq 're-asked url keeps the valid link' 'https://a.test/rs.dat' \
    "$(awk -F'	' '$1=="rs.dat"{print $2}' "$GEO_EXTRA_PATH" 2>/dev/null)"
check 'rejected file names never land a file' test ! -e "$DEPLOY_DIR/evil.dat"
check_eq 'rejected file names leave three entries' '3' \
    "$(wc -l < "$GEO_EXTRA_PATH" 2>/dev/null | tr -d ' ')"
if _geo_extra_file_valid '.'; then
    fail 'file name "." is rejected'
else
    pass 'file name "." is rejected'
fi

# 下载失败/体积不足: 不动 config 与 state, 资源目录里也不留半成品。
GEO_EXTRA_BEFORE=$(cat "$GEO_EXTRA_PATH" 2>/dev/null)
if (
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _http_download() { return 1; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED"; return 0; }
    { echo 'https://a.test/fail.dat'; echo 'fail.dat'; } | _geo_extra_add
) >/dev/null 2>&1; then
    fail 'download failure aborts the add'
else
    pass 'download failure aborts the add'
fi
check 'download failure leaves no dat file' test ! -e "$ASSET_DIR/fail.dat"
check 'download failure does not touch config' test ! -e "$GEO_EXTRA_TOUCHED"
check_eq 'download failure keeps the state lines' "$GEO_EXTRA_BEFORE" "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"
check_eq 'download failure leaves no temp file' '0' \
    "$(find "$ASSET_DIR" -maxdepth 1 -name '.geo-extra.*' 2>/dev/null | wc -l | tr -d ' ')"
if (
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _http_download() { printf 'tiny' > "$2"; return 0; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED"; return 0; }
    { echo 'https://a.test/small.dat'; echo 'small.dat'; } | _geo_extra_add
) >/dev/null 2>&1; then
    fail 'a sub-1KB download aborts the add'
else
    pass 'a sub-1KB download aborts the add'
fi
check 'sub-1KB download leaves no dat file' test ! -e "$ASSET_DIR/small.dat"
check 'sub-1KB download does not touch config' test ! -e "$GEO_EXTRA_TOUCHED"
check_eq 'sub-1KB download keeps the state lines' "$GEO_EXTRA_BEFORE" "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"

# assets 写失败: 删除刚下载的文件并中止, state 不动。
if (
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _http_download() { cp "$GEO_EXTRA_BIG" "$2"; return 0; }
    _mutate_config() { return 1; }
    { echo 'https://a.test/cf.dat'; echo 'cf.dat'; } | _geo_extra_add
) >/dev/null 2>&1; then
    fail 'failed assets write rolls the add back'
else
    pass 'failed assets write rolls the add back'
fi
check 'failed assets write removes the downloaded file' test ! -e "$ASSET_DIR/cf.dat"
check_eq 'failed assets write keeps the state lines' "$GEO_EXTRA_BEFORE" "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"

# extras 只交给 Xray 内置定时下载: xd geo-update 仍只取两个内置 dat。
GEO_DL_EXTRA="$TMP/geo-dl-extra"
rm -f "$GEO_DL_EXTRA"
(
    _ensure_dirs() { return 0; }
    _with_config_lock() { "$@"; }
    _with_core_lock() { "$@"; }
    _geo_update_commit_locked() { return 0; }
    _http_download() { echo "$1 -> $(basename "$2")" >> "$GEO_DL_EXTRA"; return 91; }
    _geo_update
) >/dev/null 2>&1
check_eq 'geo update downloads only the two builtin dat files' 'geosite.dat geoip.dat' \
    "$(awk '{print $3}' "$GEO_DL_EXTRA" 2>/dev/null | paste -sd' ' -)"

# 删除: builtin 下先重写不含该项的 assets, 再删 state 行与本地文件。
GEO_EXTRA_DEL="$TMP/geo-extra-del"
rm -f "$GEO_EXTRA_DEL"
if (
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _mutate_config() { printf '%s' "$3" > "$GEO_EXTRA_DEL"; return 0; }
    echo '1' | _geo_extra_delete
) >/dev/null 2>&1; then
    pass 'custom geodata delete completes under builtin'
else
    fail 'custom geodata delete completes under builtin'
fi
GEO_EXTRA_LEFT=$(cat "$GEO_EXTRA_PATH" 2>/dev/null)
check 'custom geodata delete removes the local file' test ! -e "$ASSET_DIR/my.dat"
check_eq 'custom geodata delete drops the state line' 'zeta.dat rs.dat' \
    "$(awk -F'	' '{print $1}' "$GEO_EXTRA_PATH" 2>/dev/null | paste -sd' ' -)"
check_eq 'custom geodata delete rewrites assets without the entry' '0' \
    "$(jq -r '[.[] | select(.file=="my.dat")] | length' "$GEO_EXTRA_DEL" 2>/dev/null)"
check_eq 'custom geodata delete keeps the other extras in assets' 'zeta.dat rs.dat' \
    "$(jq -r '[.[] | select(.file=="zeta.dat" or .file=="rs.dat") | .file] | join(" ")' "$GEO_EXTRA_DEL" 2>/dev/null)"
if (
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _mutate_config() { return 1; }
    echo '1' | _geo_extra_delete
) >/dev/null 2>&1; then
    fail 'failed assets write aborts the delete'
else
    pass 'failed assets write aborts the delete'
fi
check_eq 'failed delete keeps the state lines' "$GEO_EXTRA_LEFT" "$(cat "$GEO_EXTRA_PATH" 2>/dev/null)"
check 'failed delete keeps the local file' test -f "$ASSET_DIR/zeta.dat"

# 删除: cron/off 机制不写 config, 只删 state 行与本地文件。
GEO_EXTRA_TOUCHED2="$TMP/geo-extra-config-touched-2"
rm -f "$GEO_EXTRA_TOUCHED2"
if (
    _geo_auto_mechanism() { printf 'off'; }
    _with_core_lock() { "$@"; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED2"; return 0; }
    echo '2' | _geo_extra_delete
) >/dev/null 2>&1; then
    pass 'cron/off mechanism delete completes'
else
    fail 'cron/off mechanism delete completes'
fi
check 'cron/off mechanism delete skips config' test ! -e "$GEO_EXTRA_TOUCHED2"
check_eq 'cron/off mechanism delete drops the state line' 'zeta.dat' \
    "$(awk -F'	' '{print $1}' "$GEO_EXTRA_PATH" 2>/dev/null | paste -sd' ' -)"
check 'cron/off mechanism delete removes the local file' test ! -e "$ASSET_DIR/rs.dat"

# state 里的文件名越界(含 / 或 ..)时中止删除: 不写 config, 不动 state, 不 rm。
printf 'zeta.dat	https://a.test/dl/zeta.dat\n../evil.dat	https://a.test/evil.dat\n' > "$GEO_EXTRA_PATH"
printf 'keep' > "$DEPLOY_DIR/evil.dat"
GEO_EXTRA_TOUCHED3="$TMP/geo-extra-config-touched-3"
rm -f "$GEO_EXTRA_TOUCHED3"
if (
    _geo_auto_mechanism() { printf 'off'; }
    _with_core_lock() { "$@"; }
    _mutate_config() { : > "$GEO_EXTRA_TOUCHED3"; return 0; }
    echo '2' | _geo_extra_delete
) >/dev/null 2>&1; then
    fail 'delete rejects a file name outside the asset dir'
else
    pass 'delete rejects a file name outside the asset dir'
fi
check_eq 'rejected delete keeps both state lines' 'zeta.dat ../evil.dat' \
    "$(awk -F'	' '{print $1}' "$GEO_EXTRA_PATH" 2>/dev/null | paste -sd' ' -)"
check 'rejected delete leaves the outside file alone' test -f "$DEPLOY_DIR/evil.dat"
check 'rejected delete does not touch config' test ! -e "$GEO_EXTRA_TOUCHED3"
rm -f "$DEPLOY_DIR/evil.dat"
# "." 同样不是普通文件: 删除时同样中止, 不删 state 行。
printf '.\thttps://a.test/dot\n' > "$GEO_EXTRA_PATH"
if (
    _geo_auto_mechanism() { printf 'off'; }
    _with_core_lock() { "$@"; }
    echo '1' | _geo_extra_delete
) >/dev/null 2>&1; then
    fail 'delete rejects the current directory as a file name'
else
    pass 'delete rejects the current directory as a file name'
fi
check_eq 'rejected dot delete keeps the state line' '.' \
    "$(awk -F'\t' '{print $1}' "$GEO_EXTRA_PATH" 2>/dev/null)"
printf 'zeta.dat	https://a.test/dl/zeta.dat\n' > "$GEO_EXTRA_PATH"

# state 行删除失败时, builtin 下的提示必须承认 config 已经改过。
GEO_EXTRA_MSG="$TMP/geo-extra-del-msg"
(
    _geo_auto_mechanism() { printf 'builtin'; }
    _with_core_lock() { "$@"; }
    _mutate_config() { return 0; }
    _geo_extra_remove_line() { return 1; }
    echo '1' | _geo_extra_delete
) > "$GEO_EXTRA_MSG" 2>&1
check 'state write failure message admits the config change' contains '配置已移除 zeta.dat' "$(cat "$GEO_EXTRA_MSG" 2>/dev/null)"

# 菜单: [19] Geo 下有 [5] 入口, 子菜单列出条目并说明非内置机制只下载一次。
GEO_MENU_OUT="$TMP/geo-menu-out"
echo '0' | _geo_menu > "$GEO_MENU_OUT" 2>&1
check 'geo menu offers custom geodata' contains '自定义 geodata' "$(cat "$GEO_MENU_OUT" 2>/dev/null)"
GEO_SUB_OUT="$TMP/geo-sub-out"
(
    _geo_auto_mechanism() { printf 'cron'; }
    echo '0' | _geo_extra_menu
) > "$GEO_SUB_OUT" 2>&1
check 'custom geodata submenu lists the entries' contains 'zeta.dat <- https://a.test/dl/zeta.dat' "$(cat "$GEO_SUB_OUT" 2>/dev/null)"
check 'custom geodata submenu offers add and delete' contains '[2]' "$(cat "$GEO_SUB_OUT" 2>/dev/null)"
check 'custom geodata submenu warns about one-shot downloads' contains '不会随定时更新' "$(cat "$GEO_SUB_OUT" 2>/dev/null)"

rm -f "$GEO_EXTRA_PATH" "$ASSET_DIR/my.dat" "$ASSET_DIR/zeta.dat" "$ASSET_DIR/rs.dat"

printf '== logrotate state contracts ==\n'
rm -f "$STATE_DIR/logrotate_enabled"
check_eq 'missing logrotate state is unset' unset "$(_logrotate_enabled_state)"
_state_set logrotate_enabled off
check_eq 'explicit logrotate disable is retained' off "$(_logrotate_enabled_state)"
if (
    LOGROTATE_CONF="$TMP/lr-disabled/xray-deploy"
    mkdir -p "$TMP/lr-disabled"
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

printf '== logrotate auto-off marker ==\n'
rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
LOGROTATE_CONF="$TMP/lr-marker/xray-deploy"
mkdir -p "$TMP/lr-marker"
rm -f "$(_logrotate_user_off_path)"
_state_set logrotate_enabled on
_state_set "$LOGROTATE_AUTO_OFF_KEY" on
rm -f "$LOGROTATE_CONF"
check_eq 'auto-off marker with no config is effectively off' off "$(_logrotate_effective_enabled)"
: > "$LOGROTATE_CONF"
check_eq 'auto-off marker with leftover config is effectively on' on "$(_logrotate_effective_enabled)"
rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
check_eq 'effective state falls back to the record without the marker' on "$(_logrotate_effective_enabled)"
if (
    _logrotate_ensure_package() { return 0; }
    _logrotate_init_state() { return 0; }
    _logrotate_write_config() { : > "$LOGROTATE_CONF"; }
    _state_set "$LOGROTATE_AUTO_OFF_KEY" on
    rm -f "$LOGROTATE_CONF"
    _logrotate_setup >/dev/null 2>&1
    [ ! -e "$LOGROTATE_CONF" ]
); then
    pass 'auto-off marker keeps setup from rewriting the config'
else
    fail 'auto-off marker keeps setup from rewriting the config'
fi
if (
    _logrotate_ensure_package() { return 0; }
    _logrotate_init_state() { return 0; }
    _logrotate_write_config() { : > "$LOGROTATE_CONF"; }
    rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY" "$LOGROTATE_CONF"
    _logrotate_setup >/dev/null 2>&1
    [ -e "$LOGROTATE_CONF" ]
); then
    pass 'setup rewrites the config when the marker is absent'
else
    fail 'setup rewrites the config when the marker is absent'
fi
rm -f "$LOGROTATE_CONF" "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
_state_set logrotate_enabled off
LOGROTATE_CONF="$TMP/logrotate.conf"

printf '== logrotate user-off intent and atomic write ==\n'
# 禁用时状态写失败必须留下"禁用意图", 否则 setup 会凭 enabled=on 把已删配置的轮换重新打开。
# 关键: 意图标记不能依赖 state 存储 —— 这里让**所有** _state_set 失败(模拟 state 存储不可写),
# 标记仍须落到 include 目录侧, 否则与失败根因同源、必然一起失败。
rm -f "$STATE_DIR/$LOGROTATE_AUTO_OFF_KEY"
LOGROTATE_CONF="$TMP/logrotate-useroff/xray-deploy"
mkdir -p "$TMP/logrotate-useroff"
: > "$LOGROTATE_CONF"
(
    _state_set() { return 1; }
    _logrotate_disable >/dev/null 2>&1
) >/dev/null 2>&1
check_eq 'disable-with-failed-state records user-off intent' on "$(_logrotate_user_off_get)"
check_eq 'user-off intent with no config is effectively off' off "$(_logrotate_effective_enabled)"
# 直接驱动真实 setup: 若 setup 在"标记=on 但 enabled 记录仍为 on"时复活轮换, 会重新写出配置。
# enabled 记录用真实 _state_set 置 on(用户禁用那一步的写失败是模拟的, 但记录本身仍为 on)。
_state_set logrotate_enabled on
rm -f "$LOGROTATE_CONF"
# 桩掉包依赖: 本机无 logrotate 时不得触发真实 apt/apk, 也不得 mkdir 真实 /etc/logrotate.d。
(
    _logrotate_ensure_package() { return 0; }
    _logrotate_setup >/dev/null 2>&1
)
if [ ! -e "$LOGROTATE_CONF" ]; then
    pass 'user-off intent keeps setup from resurrecting rotation'
else
    fail 'user-off intent keeps setup from resurrecting rotation'
fi
# 重新启用必须清除禁用意图。
(
    _logrotate_ensure_package() { return 0; }
    _logrotate_enable >/dev/null 2>&1
)
if [ ! -e "$(_logrotate_user_off_path)" ]; then
    pass 'enable clears user-off intent'
else
    fail 'enable clears user-off intent'
fi
rm -rf "$TMP/logrotate-useroff"

# 部分损坏(仅哨兵丢失)不得覆盖仍存活的用户偏好。
rm -f "$STATE_DIR/logrotate_enabled"
_state_set logrotate_retention 14
_logrotate_init_state >/dev/null 2>&1
check_eq 'init preserves surviving retention preference' 14 "$(_state_get logrotate_retention)"
check_eq 'init still writes the enabled sentinel' on "$(_state_get logrotate_enabled)"

# 原子写: 在 include 根下只出现完整目标文件; 临时写入区不得留在 logrotate 会读取的目录里。
# 关键断言: 提交完成后 include 根里除了目标文件不应有别的条目(旧的非原子实现会直接截断目标文件)。
LOGROTATE_CONF="$TMP/lr-confdir/xray-deploy"
mkdir -p "$TMP/lr-confdir"
if _logrotate_write_config >/dev/null 2>&1 \
   && [ -s "$LOGROTATE_CONF" ] \
   && [ "$(cat "$LOGROTATE_CONF")" = "$(_logrotate_render_config)" ] \
   && [ -z "$(find "$TMP/lr-confdir" -mindepth 1 -maxdepth 1 ! -name xray-deploy -print -quit)" ]; then
    pass 'atomic write leaves a complete include and no temp residue'
else
    fail 'atomic write leaves a complete include and no temp residue'
fi
# 写入路径必须经临时文件再 rename(而非就地截断目标): rename 会换掉目标 inode, 截断不会。
# 这直接区分原子实现与旧的非原子实现, 不依赖渲染失败等间接条件。
printf 'previous-good-include\n' > "$TMP/lr-keep.conf"
_ino_before=$(stat -c '%i' "$TMP/lr-keep.conf")
if LOGROTATE_CONF="$TMP/lr-keep.conf" _logrotate_write_config >/dev/null 2>&1; then
    _ino_after=$(stat -c '%i' "$TMP/lr-keep.conf")
    if [ "$(cat "$TMP/lr-keep.conf")" = "$(_logrotate_render_config)" ] \
       && [ "$_ino_before" != "$_ino_after" ]; then
        pass 'atomic write commits via rename (inode replaced)'
    else
        fail 'atomic write commits via rename (inode replaced)'
    fi
else
    fail 'atomic write commits via rename (inode replaced)'
fi
rm -rf "$TMP/lr-confdir" "$TMP/lr-keep.conf"
# 意图标记自身写入失败(如 inode 耗尽/目录不可写)时不得删除配置:
# 否则 setup 会凭 enabled=on 复活轮换, 且无任何标记可追溯。
LOGROTATE_CONF="$TMP/lr-useroff-fail/xray-deploy"
mkdir -p "$TMP/lr-useroff-fail"
: > "$LOGROTATE_CONF"
(
    _logrotate_user_off_set() { return 1; }
    _logrotate_disable >/dev/null 2>&1
) >/dev/null 2>&1
_drc=$?
if [ "$_drc" -ne 0 ] && [ -e "$LOGROTATE_CONF" ] && [ ! -e "$(_logrotate_user_off_path)" ]; then
    pass 'failed disable-intent write keeps the config'
else
    fail 'failed disable-intent write keeps the config'
fi
rm -rf "$TMP/lr-useroff-fail"

# P2 回归: state 存储不可写时手动禁用会留下 user_off, 而联动标记 auto_off 可能清不掉(同一存储不可写);
# 之后切换日志级别绝不能凭残留 auto_off 自动恢复, 覆盖用户的显式禁用。
LOGROTATE_CONF="$TMP/lr-auto-manual/xray-deploy"
mkdir -p "$TMP/lr-auto-manual"
: > "$LOGROTATE_CONF"
_state_set "$LOGROTATE_AUTO_OFF_KEY" on
_state_set logrotate_enabled on
(
    _state_set() { return 1; }
    _logrotate_disable >/dev/null 2>&1
) >/dev/null 2>&1
if [ "$(_logrotate_user_off_get)" = "on" ] \
   && [ "$(_logrotate_auto_off_get)" = "on" ] \
   && [ ! -e "$LOGROTATE_CONF" ] \
   && [ "$(_logrotate_effective_enabled)" = "off" ]; then
    pass 'manual disable with unwritable state keeps user-off while auto marker stays stuck'
else
    fail 'manual disable with unwritable state keeps user-off while auto marker stays stuck'
fi
if (
    _config_edit_preflight() { return 0; }
    _xray_loglevel_get() { printf 'none'; }
    _xray_loglevel_valid() { return 0; }
    _mutate_config() { return 0; }
    _logrotate_ensure_package() { return 0; }
    _press_any_key() { :; }
    printf '4\n' | _loglevel_menu >/dev/null 2>&1
    [ ! -e "$LOGROTATE_CONF" ] && [ "$(_logrotate_user_off_get)" = "on" ]
); then
    pass 'loglevel switch does not resurrect a manually disabled logrotate'
else
    fail 'loglevel switch does not resurrect a manually disabled logrotate'
fi
rm -rf "$TMP/lr-auto-manual"

# 目标路径是目录时必须显式失败, 不得把临时文件搬进目录后谎报成功。
LOGROTATE_CONF="$TMP/lr-dir-target/xray-deploy"
mkdir -p "$LOGROTATE_CONF"
if ! _logrotate_write_config >/dev/null 2>&1 \
   && [ -d "$LOGROTATE_CONF" ] \
   && [ -z "$(ls -A "$LOGROTATE_CONF")" ]; then
    pass 'directory target is rejected instead of silently accepted'
else
    fail 'directory target is rejected instead of silently accepted'
fi
rm -rf "$TMP/lr-dir-target"
_state_set logrotate_enabled off
LOGROTATE_CONF="$TMP/logrotate.conf"


# clash 探针需要一个测试用锁根: 覆盖 _deploy_lock_root, 避免触碰真实 /var/lock。
LOCK_ROOT="$TMP/mixed-locks"
mkdir -p "$LOCK_ROOT"
_deploy_lock_root() { printf '%s' "$LOCK_ROOT"; }

printf '== clash derivation runs under the config lock ==\n'
# clash.yaml 是 Xray 节点与官方 Hysteria 节点共用的派生文件, 追加/替换/去重
# 都是读-改-写 ⇒ 不进 config lock 就会丢条目。探针把"写"缩短成记录锁状态: 直接对被观察
# 写时刻的 config.lock 试加 flock, 加得上就是没持锁。
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
        local fd
        # 无 flock 的宿主上 flock -n 恒失败 ⇒ 只能报 unknown, 否则断言退化为恒真。
        command -v flock >/dev/null 2>&1 || { printf 'unknown'; return 0; }
        { exec {fd}>>"$(_deploy_lock_root)/config.lock"; } 2>/dev/null || { printf 'unknown'; return 0; }
        if flock -n "$fd" 2>/dev/null; then printf 'free'; else printf 'held'; fi
        eval "exec ${fd}>&-" 2>/dev/null || :
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
# 有 flock 的宿主必须看到 held(真检查); 无 flock 时探针只能报 unknown, 接受但不再当作持锁证据。
_check_lock_probe() {   # <名称> <探针输出>
    case "$2" in
        *"=held rc=0 leak=no"|*"=unknown rc=0 leak=no") pass "$1" ;;
        *) fail "$1 (expected held|unknown, got [$2])" ;;
    esac
}
_check_lock_probe 'Xray clash write holds the config lock' "$XH_CLASH_PROBE"
_check_lock_probe 'Hysteria clash write holds the config lock' "$XH_HY_PROBE"
_check_lock_probe 'nested clash sync is reentrant' "$XH_NESTED_PROBE"



HYSTERIA_CERT="$TMP/selfsigned.pem"
HYSTERIA_PIN=$(printf '%064d' 7)
printf 'test cert\n' > "$HYSTERIA_CERT"
printf '{"listen":":443","tls":{"cert":"%s"},"bandwidth":{"up":"100 mbps","down":"10 mbps"}}\n' "$HYSTERIA_CERT" > "$HYSTERIA_CONFIG"
printf '{"tls_mode":"selfsigned","sni":"example.test","pin":"%s"}\n' "$HYSTERIA_PIN" > "$HYSTERIA_SERVER_META"
printf '{"auth":"secret","name":"node-a","link_addr":"198.51.100.7","protocol":"hysteria2"}\n' > "$HYSTERIA_NODE_META"
uri=$(_hysteria_build_link "$HYSTERIA_NODE_META" 2>/dev/null)
if contains 'insecure=1' "$uri" && contains "pinSHA256=$HYSTERIA_PIN" "$uri"; then pass 'self-signed URI includes official pinSHA256'; else fail 'self-signed URI includes official pinSHA256'; fi
line=$(_hysteria_clash_line "$HYSTERIA_NODE_META" 2>/dev/null)
if contains 'skip-cert-verify: true' "$line" && ! contains 'fingerprint:' "$line"; then pass 'Mihomo self-signed entry skips verification without fingerprint'; else fail 'Mihomo self-signed entry skips verification without fingerprint'; fi
if contains 'down: "100 mbps"' "$line" && contains 'up: "10 mbps"' "$line"; then pass 'server bandwidth maps to client directions'; else fail 'server bandwidth maps to client directions'; fi
printf '{"tls_mode":"selfsigned","sni":"example.test","pin":""}\n' > "$HYSTERIA_SERVER_META"
if _hysteria_build_link "$HYSTERIA_NODE_META" >/dev/null 2>&1; then fail 'missing self-signed pin rejected'; else pass 'missing self-signed pin rejected'; fi
# metadata 未记录 pin 时, 可从已发布证书推导; 证书也不存在时才拒绝。
if command -v openssl >/dev/null 2>&1; then
    mkdir -p "$HYSTERIA_CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/pin-test.key" \
        -out "$HYSTERIA_CERT_DIR/cert.pem" -days 1 -subj '/CN=example.test' >/dev/null 2>&1
    uri=$(_hysteria_build_link "$HYSTERIA_NODE_META" 2>/dev/null)
    if contains 'pinSHA256=' "$uri"; then pass 'self-signed metadata without pin derives it from the published cert'; else fail 'self-signed metadata without pin derives it from the published cert'; fi
    rm -f "$HYSTERIA_CERT_DIR/cert.pem" "$TMP/pin-test.key"
else
    pass 'self-signed pin derivation skipped (openssl unavailable)'
fi

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

printf '== hy2 env reader fallback ==\n'
# 读取器: rc 0 命中并剥离工具补的单个换行, 1 缺失, 2 工具故障(未知)。
# 探测值**以换行结尾**, 才能区分"剥一个换行"与命令替换的"剥全部尾随换行"。
if (
    export _XD_PROBE_TEST=$'v1\nv2\n'
    _hy2_env_from_tool _XD_PROBE_TEST printenv || exit 1
    [ "$_HY2_ENV_VAL" = $'v1\nv2\n' ]
); then pass 'hy2 env reader strips exactly one trailing newline'; else fail 'hy2 env reader strips exactly one trailing newline'; fi
_hy2_env_from_tool _XD_DEFINITELY_UNSET_VAR printenv; _hy2_rc=$?
if [ "$_hy2_rc" -eq 1 ]; then pass 'hy2 env reader reports absent (rc=1) for missing variable'; else fail "hy2 env reader reports absent (rc=1) for missing variable (rc=$_hy2_rc)"; fi
(
    command() { [ "${1:-}" = -v ] && return 1; builtin command "$@"; }
    _hy2_env_get PATH
) >/dev/null 2>&1; _hy2_rc=$?
if [ "$_hy2_rc" -eq 2 ]; then pass 'hy2 env reports unknown (rc=2) when no reader is available'; else fail "hy2 env reports unknown (rc=2) when no reader is available (rc=$_hy2_rc)"; fi

printf '== approved repair regressions ==\n'
# 卸载必须清掉 hysteria_asset, 否则残留键会让后续 AVX 兜底按错误变体弱推断。
if (
    HYSTERIA_BIN="$TMP/hy-uninstall/hysteria"
    HYSTERIA_CONFIG="$TMP/hy-uninstall/config.json"
    HYSTERIA_SERVER_META="$TMP/hy-uninstall/server.json"
    HYSTERIA_NODE_META="$TMP/hy-uninstall/node.json"
    HYSTERIA_LOG_FILE="$TMP/hy-uninstall/hy.log"
    HYSTERIA_DATA_DIR="$TMP/hy-uninstall/data"
    HYSTERIA_CERT_DIR="$TMP/hy-uninstall/certs"
    _lr_conf="$TMP/hy-uninstall/logrotate.d/xd-hysteria"
    _hysteria_logrotate_conf() { printf '%s' "$_lr_conf"; }
    HYSTERIA_SVC="xd-hysteria"
    mkdir -p "$HYSTERIA_DATA_DIR" "$HYSTERIA_CERT_DIR" "$(dirname "$_lr_conf")"
    printf 'bin' > "$HYSTERIA_BIN"
    printf 'lr' > "$_lr_conf"
    _state_set hysteria_version 2.12.2
    _state_set hysteria_variant avx
    _state_set hysteria_asset hysteria-linux-amd64
    _hysteria_installed() { return 0; }
    _hysteria_stop_and_verify() { return 0; }
    _hysteria_cleanup_service_units() { return 0; }
    _hysteria_uninstall_locked >/dev/null 2>&1
    [ ! -e "$STATE_DIR/hysteria_version" ] && [ ! -e "$STATE_DIR/hysteria_variant" ] \
        && [ ! -e "$STATE_DIR/hysteria_asset" ] && [ ! -e "$_lr_conf" ]
); then pass 'uninstall clears hysteria_asset state'; else fail 'uninstall clears hysteria_asset state'; fi
# 端口跳跃解析: 只接受单段 a-b; 多 '-' 必须显式拒绝(旧实现用 cut 静默丢弃多余段)。
if _parse_hop_ranges '20000-30000' >/dev/null 2>&1 \
   && ! _parse_hop_ranges '80-90-100' >/dev/null 2>&1 \
   && ! _parse_hop_ranges '1-2-3-4' >/dev/null 2>&1; then
    pass 'hop range parser rejects multi-dash entries'
else
    fail 'hop range parser rejects multi-dash entries'
fi
if (
    CONFIG_DIR="$TMP/duplicate-confs"
    mkdir -p "$CONFIG_DIR"
    printf '{"inbounds":[{"tag":"one"}]}' > "$CONFIG_DIR/one.json"
    printf '{"inbounds":[{"tag":"two"}]}' > "$CONFIG_DIR/two.json"
    _config_merged >/dev/null 2>&1 && exit 1
    _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' >/dev/null 2>&1 && exit 1
    [ "$(jq -r '.inbounds[0].tag' "$CONFIG_DIR/one.json")" = one ] &&
        [ "$(jq -r '.inbounds[0].tag' "$CONFIG_DIR/two.json")" = two ]
); then pass 'duplicate top-level fragments refuse read/write without data loss'; else fail 'duplicate top-level fragments refuse read/write without data loss'; fi
if (
    CONFIG_DIR="$TMP/delete-failure-confs"
    _config_write_merged '{"version":{"min":"26.4.25","max":""},"dns":{"servers":["1.1.1.1"]}}' || exit 1
    rm() { [ "${*: -1}" = "$CONFIG_DIR/04_dns.json" ] && return 1; command rm "$@"; }
    _config_write_merged '{"version":{"min":"26.4.25","max":""}}' >/dev/null 2>&1 && exit 1
    [ -f "$CONFIG_DIR/04_dns.json" ]
); then pass 'field deletion failure propagates'; else fail 'field deletion failure propagates'; fi

# Third-party uninstallers may leave a systemd mask symlink at the managed unit
# path. Reinstall must recognize that stale mask before snapshotting.
if (
    INIT_SYSTEM=systemd
    MASK_UNIT="$TMP/stale-mask/xray.service"
    mkdir -p "$(dirname "$MASK_UNIT")"
    ln -s /dev/null "$MASK_UNIT"
    _xray_service_unit_path() { printf '%s' "$MASK_UNIT"; }
    _xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }
    _xray_service_is_masked "$MASK_UNIT" && rm -f "$MASK_UNIT" && ! _xray_core_path_present "$MASK_UNIT"
); then pass 'stale systemd mask is recognized as removable'; else fail 'stale systemd mask is recognized as removable'; fi
if (
    INIT_SYSTEM=systemd
    MASK_ROOT="$TMP/stale-mask-snapshot"
    MASK_UNIT="$MASK_ROOT/xray.service"
    MASK_JOURNAL="$MASK_ROOT/coretxn.json"
    BACKUP_DIR="$MASK_ROOT/backups"
    XRAY_CORE_TXN_ID=testtxn; export XRAY_CORE_TXN_ID
    mkdir -p "$BACKUP_DIR"
    ln -s /dev/null "$MASK_UNIT"
    printf '{"service_preexisted":false}' > "$MASK_JOURNAL"
    _xray_core_journal_path() { printf '%s' "$MASK_JOURNAL"; }
    _xray_service_unit_path() { printf '%s' "$MASK_UNIT"; }
    _xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }
    systemctl() {
        case "$1" in
            daemon-reload) return 0 ;;
            is-enabled) printf 'not-found\n'; return 1 ;;
            *) return 0 ;;
        esac
    }
    _xray_service_snapshot
    [ ! -e "$MASK_UNIT" ] && [ ! -L "$MASK_UNIT" ] &&
        [ -L "$BACKUP_DIR/xray-service.testtxn.prev.masked" ] &&
        [ "$(readlink -f "$BACKUP_DIR/xray-service.testtxn.prev.masked")" = /dev/null ] &&
        [ "$(cat "$BACKUP_DIR/xray-service.testtxn.prev.enabled")" = disabled ] &&
        [ -f "$BACKUP_DIR/xray-service.testtxn.prev.absent" ]
); then pass 'stale systemd mask is snapshotted before removal'; else fail 'stale systemd mask is snapshotted before removal'; fi
if (
    INIT_SYSTEM=systemd
    NO_UNIT="$TMP/no-unit"
    _xray_service_unit_path() { printf '%s' "$NO_UNIT"; }
    _xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }
    systemctl() { printf 'Unit xray.service could not be found.\n' >&2; return 1; }
    [ "$(_xray_service_enable_state)" = disabled ]
); then pass 'missing systemd unit snapshots as disabled'; else fail 'missing systemd unit snapshots as disabled'; fi
if (
    INIT_SYSTEM=systemd
    MASK_ROOT="$TMP/stale-mask-cleanup"
    MASK_UNIT="$MASK_ROOT/xray.service"
    MASK_JOURNAL="$MASK_ROOT/coretxn.json"
    BACKUP_DIR="$MASK_ROOT/backups"
    mkdir -p "$BACKUP_DIR"
    ln -s /dev/null "$BACKUP_DIR/xray-service.testtxn.prev.masked"
    printf '{"phase":"prepared","service_masked":true,"binary_backup":"%s/b","staging_dir":"%s/s","service_prev":"%s/xray-service.testtxn.prev","geoip_backup":"%s/g","geosite_backup":"%s/h"}' "$MASK_ROOT" "$MASK_ROOT" "$BACKUP_DIR" "$MASK_ROOT" "$MASK_ROOT" > "$MASK_JOURNAL"
    _xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }
    _xray_core_journal_path() { printf '%s' "$MASK_JOURNAL"; }
    _xray_service_unit_path() { printf '%s' "$MASK_UNIT"; }
    _xray_service_restore_mask() { ln -s /dev/null "$1"; }
    systemctl() { [ "$1" = daemon-reload ]; }
    _xray_core_cleanup_sources "$MASK_JOURNAL" &&
        [ -L "$MASK_UNIT" ] && [ "$(readlink -f "$MASK_UNIT")" = /dev/null ]
); then pass 'prepared cleanup restores stale systemd mask'; else fail 'prepared cleanup restores stale systemd mask'; fi
if (
    INIT_SYSTEM=systemd
    MASK_ROOT="$TMP/stale-mask-restore"
    MASK_UNIT="$MASK_ROOT/xray.service"
    MASK_SNAPSHOT="$MASK_ROOT/xray-service.masked"
    mkdir -p "$MASK_ROOT"
    ln -s /dev/null "$MASK_SNAPSHOT"
    _xray_service_unit_path() { printf '%s' "$MASK_UNIT"; }
    _xray_core_path_present() { [ -e "$1" ] || [ -L "$1" ]; }
    _xray_service_restore_mask "$MASK_UNIT" "$MASK_SNAPSHOT" &&
        [ -L "$MASK_UNIT" ] && [ "$(readlink -f "$MASK_UNIT")" = /dev/null ]
); then pass 'stale systemd mask restores from transaction snapshot'; else fail 'stale systemd mask restores from transaction snapshot'; fi
if (
    R_LISTEN=127.0.0.1 R_PORT=12345 R_TAG=test
    R_UUID=11111111-1111-1111-1111-111111111111 R_PATH='/api?a=1&b=2'
    ws=$(_render_template "$ROOT/templates/vless-ws-cdn.server.jsonc") || exit 1
    [ "$(jq -r '.streamSettings.wsSettings.path' <<< "$ws")" = "$R_PATH" ] || exit 1
    R_METHOD=aes-256-gcm R_PASSWORD='hello&world' R_NETWORK=tcp
    ss_config=$(_render_template "$ROOT/templates/shadowsocks.server.jsonc") || exit 1
    [ "$(jq -r '.settings.password' <<< "$ss_config")" = "$R_PASSWORD" ] || exit 1
    R_AUTH='hello&world' R_CERT_FILE=/cert R_KEY_FILE=/key R_CONGESTION=bbr
    hy=$(_render_template "$ROOT/templates/hysteria2.server.jsonc") || exit 1
    [ "$(jq -r '(.settings.clients // .settings.users)[0].auth' <<< "$hy")" = "$R_AUTH" ]
); then pass 'template path password and auth preserve ampersands'; else fail 'template path password and auth preserve ampersands'; fi

if (
    CF_BIN="$TMP/cloudflared"
    _cf_service_bin() { printf '%s' "$CF_BIN"; }
    _cf_unit_path() { printf '%s' "$TMP/cf-service"; }
    CF_CUR_CMDLINE="command=$CF_BIN"$'\n''command_args="--no-autoupdate tunnel --protocol http2 --edge-ip-version 4 run --token TOKEN"'
    _cf_managed_flags_only || exit 1
    CF_CUR_CMDLINE="${CF_CUR_CMDLINE%\"} --metrics localhost:1234\""
    ! _cf_managed_flags_only
); then pass 'OpenRC managed commands accepted but custom flags rejected'; else fail 'OpenRC managed commands accepted but custom flags rejected'; fi

_test_xray_hop_conflict() (
    CONFIG_DIR="$TMP/xray-hop-check/confs"
    NODES_DIR="$TMP/xray-hop-check/nodes"
    mkdir -p "$NODES_DIR"
    _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' || exit 1
    printf '%s' "$1" > "$NODES_DIR/xh.json"
    ! _hysteria_check_hop_conflicts 40001 40001 >/dev/null 2>&1
)
check 'official single listen rejects Xray singleton hop' _test_xray_hop_conflict '{"hop_ranges":"40001"}'
check 'official single listen rejects Xray range hop' _test_xray_hop_conflict '{"hop_ranges":"40000-40002"}'
if _xh_hop_conflict '{"protocol":"vless","port":443,"streamSettings":{"network":"tcp"}}' 443 443; then fail 'official UDP single port permits same-number TCP inbound'; else pass 'official UDP single port permits same-number TCP inbound'; fi

_test_official_port_menu() (
    local mode="$1" port="$2" udp="$3"
    CONFIG_DIR="$TMP/official-menu-$mode-$port-$udp/confs"
    NODES_DIR="$TMP/official-menu-$mode-$port-$udp/nodes"
    HYSTERIA_CONFIG="$TMP/official-menu-$mode-$port-$udp/hy.json"
    mkdir -p "$NODES_DIR"
    if [ "$udp" = tcp ]; then
        _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[{"protocol":"vless","port":443,"streamSettings":{"network":"tcp"}}]}' || exit 1
    else
        _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' || exit 1
        printf '{"hop_ranges":"40000-40002"}' > "$NODES_DIR/xh.json"
    fi
    printf '{"listen":":8443"}' > "$HYSTERIA_CONFIG"
    local committed=""
    _hysteria_gate() { return 0; }
    clear() { :; }
    _hysteria_config_txn() { committed=yes; }
    _hysteria_rebuild_all_links() { :; }
    _press_any_key() { :; }
    _hysteria_port_menu >/dev/null 2>&1 <<< "$mode"$'\n'"$port"$'\n0'
    if [ "$udp" = tcp ]; then [ "$committed" = yes ]; else [ -z "$committed" ]; fi
)
check 'official change-listen menu rejects DNAT hop overlap' _test_official_port_menu 1 40001 udp
check 'official disable-hop menu rejects DNAT hop overlap' _test_official_port_menu 3 40001 udp
check 'official change-listen menu permits TCP-only same number' _test_official_port_menu 1 443 tcp

if (
    CONFIG_DIR="$TMP/broken-duplicate/confs"
    mkdir -p "$CONFIG_DIR"
    printf '{"dns":{}}' > "$CONFIG_DIR/a.json"
    printf '{"dns":{}}' > "$CONFIG_DIR/b.json"
    printf broken > "$CONFIG_DIR/broken.json"
    ! _config_write_merged '{"version":{"min":"26.4.25","max":""}}' >/dev/null 2>&1
); then pass 'malformed fragment cannot bypass duplicate field guard'; else fail 'malformed fragment cannot bypass duplicate field guard'; fi
# B13c: reset 快照恢复经 JQ_MERGE_OBJECTS 合并配置片段。
_reset_restore_stage="$TMP/reset-restore-stage"
_reset_restore_dir="$TMP/reset-restore-confs"
_test_reset_snapshot_restore() {
    local saved_dir="$CONFIG_DIR" saved_deploy="$DEPLOY_DIR" saved_fsync ok=0 rc=0
    saved_fsync=$(declare -f _reset_fsync_required)
    _reset_fsync_required() { return 0; }
    rm -rf "$_reset_restore_stage" "$_reset_restore_dir"
    mkdir -p "$_reset_restore_stage/confs" "$_reset_restore_dir"
    printf '{"version":{"min":"26.4.25","max":""}}' > "$_reset_restore_stage/confs/15_version.json"
    printf '%s\n' '{"log":{"loglevel":"debug"}}' > "$_reset_restore_stage/confs/02_log.json"
    printf '%s\n' '{"inbounds":[{"tag":"a"}]}' > "$_reset_restore_stage/confs/07_inbounds.json"
    DEPLOY_DIR="$TMP/reset-restore-deploy" CONFIG_DIR="$_reset_restore_dir"
    _reset_config_snapshot_restore "$_reset_restore_stage" 0 0 1 || rc=$?
    [ "$rc" -eq 0 ] || ok=1
    [ "$(jq -r '.log.loglevel' "$_reset_restore_dir/02_log.json" 2>/dev/null)" = debug ] || ok=1
    [ "$(jq -r '.inbounds[0].tag' "$_reset_restore_dir/07_inbounds.json" 2>/dev/null)" = a ] || ok=1
    [ ! -e "$_reset_restore_stage" ] || ok=1
    CONFIG_DIR="$saved_dir" DEPLOY_DIR="$saved_deploy"
    eval "$saved_fsync"
    return "$ok"
}
check 'reset snapshot restore merges conf fragments via shared constant' _test_reset_snapshot_restore

_test_reset_snapshot_missing() {
    local saved_dir="$CONFIG_DIR" saved_deploy="$DEPLOY_DIR" ok=0 rc=0
    local stage="$TMP/reset-restore-missing" dir="$TMP/reset-restore-missing-confs"
    rm -rf "$stage" "$dir"
    mkdir -p "$stage/confs" "$dir"
    DEPLOY_DIR="$TMP/reset-restore-missing-deploy" CONFIG_DIR="$dir"
    _reset_config_snapshot_restore "$stage" 0 0 1 || rc=$?
    [ "$rc" -eq 1 ] || ok=1
    [ -d "$stage" ] || ok=1
    CONFIG_DIR="$saved_dir" DEPLOY_DIR="$saved_deploy"
    return "$ok"
}
check 'reset snapshot restore keeps scene when fragments are missing' _test_reset_snapshot_missing


# B13 guard: 缺少 JQ_MERGE_OBJECTS 时明确拒绝, 不走 unbound variable 通用失败。
_test_reset_restore_mixed_lib() {
    local stage="$TMP/reset-mixed-stage" dir="$TMP/reset-mixed-confs" out ok=0
    rm -rf "$stage" "$dir"
    mkdir -p "$stage/confs" "$dir"
    printf '%s\n' '{"log":{"loglevel":"debug"}}' > "$stage/confs/02_log.json"
    out=$(bash -c '
        set -u
        ROOT="$1"; STAGE="$2"; CONF_DIR="$3"
        _error() { printf "[错误] %s\n" "$*"; }
        _tip() { printf "[提示] %s\n" "$*"; }
        _reset_fsync_required() { return 0; }
        _config_write_merged() { : > "$CONF_DIR/__wrote__"; return 0; }
        source "$ROOT/lib/90-menu.sh"
        _reset_config_snapshot_restore "$STAGE" 0 0 1
        printf "RC=%s\n" "$?"
    ' bash "$ROOT" "$stage" "$dir" 2>&1)
    case "$out" in
        *"缺少合并常量"*) ;;
        *) ok=1 ;;
    esac
    case "$out" in
        *"unbound variable"*) ok=1 ;;
    esac
    case "$out" in
        *"RC=1"*) ;;
        *) ok=1 ;;
    esac
    [ ! -e "$dir/__wrote__" ] || ok=1
    [ -d "$stage" ] || ok=1
    return "$ok"
}
check 'reset snapshot restore rejects mixed-lib without shared constant' _test_reset_restore_mixed_lib
# install.sh 与 lib/00-common.sh 的 _flock_ensure 靠人肉同步, 漂移会让安装器与加载器选到不同锁后端。
if diff -q <(sed -n '/^_flock_ensure()/,/^}/p' "$ROOT/install.sh") \
           <(sed -n '/^_flock_ensure()/,/^}/p' "$ROOT/lib/00-common.sh") >/dev/null 2>&1; then
    pass '_flock_ensure 两份副本一致'
else
    fail '_flock_ensure 副本漂移: install.sh 与 lib/00-common.sh 不一致'
fi
# 专属行为套件在独立进程内运行, 不泄漏服务/配置桩到本套件。
for suite in test-node-alignment.sh test-cloudflared-alignment.sh test-hysteria-alignment.sh test-menu-alignment.sh test-warp-alignment.sh test-common-regressions.sh test-core-regressions.sh; do
    if bash "$ROOT/tests/$suite" > "$TMP/$suite.log" 2>&1; then
        tail -n 1 "$TMP/$suite.log"
        pass "alignment suite $suite"
    else
        tail -n 12 "$TMP/$suite.log"
        fail "alignment suite $suite"
    fi
done
printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
