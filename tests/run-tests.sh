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
CONFIG_DIR="$DEPLOY_DIR/confs"
LEGACY_CONFIG_FILE="$DEPLOY_DIR/config.json"
BACKUP_DIR="$DEPLOY_DIR/backups"
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

# 一次性迁移: 旧单文件 config.json 拆进 confs 并改名 .bak; 再跑一次是幂等 no-op。
printf '{"log":{"loglevel":"warning"},"inbounds":[]}\n' > "$LEGACY_CONFIG_FILE"
if _config_migrate_legacy >/dev/null 2>&1 \
   && [ -f "$LEGACY_CONFIG_FILE.bak" ] && [ ! -e "$LEGACY_CONFIG_FILE" ] \
   && [ -f "$CONFIG_DIR/02_log.json" ] && [ -f "$CONFIG_DIR/07_inbounds.json" ]; then
    pass 'legacy config migrates into confs'
else
    fail 'legacy config migrates into confs'
fi
_config_migrate_legacy >/dev/null 2>&1
check_eq 'migration is idempotent' 'warning' "$(_config_jq -r '.log.loglevel')"
# 用不到的模块不生成文件: 迁移结果里不该出现空壳的 04_dns.json。
if [ -f "$CONFIG_DIR/04_dns.json" ]; then fail 'unused module files are not created'; else pass 'unused module files are not created'; fi
# 坏掉的旧配置必须被拒绝且不改名(否则用户配置会被一份解析失败的碎片顶掉)。
rm -f "$CONFIG_DIR"/*.json "$LEGACY_CONFIG_FILE.bak"
printf '{"log":\n' > "$LEGACY_CONFIG_FILE"
if _config_migrate_legacy >/dev/null 2>&1; then fail 'unparseable legacy config is rejected'; else pass 'unparseable legacy config is rejected'; fi
if [ -f "$LEGACY_CONFIG_FILE" ] && [ ! -e "$LEGACY_CONFIG_FILE.bak" ]; then pass 'rejected migration leaves the legacy file alone'; else fail 'rejected migration leaves the legacy file alone'; fi
rm -f "$LEGACY_CONFIG_FILE"

# 一个顶层字段一个文件, 文件名固定, 未知字段落 99_ 前缀; 文件内容保留 {"<字段>": <值>} 外壳
# (xray -confdir 按文件合并, 裸值文件会让合并报 "Cannot index object with number")。
_config_write_merged '{"log":{"loglevel":"debug"},"routing":{"rules":[]},"customTop":1}' >/dev/null 2>&1
if [ -f "$CONFIG_DIR/05_routing.json" ] && [ -f "$CONFIG_DIR/99_customTop.json" ]; then
    pass 'top-level field maps to its fixed file name'
else
    fail 'top-level field maps to its fixed file name'
fi
check_eq 'conf file keeps the top-level key wrapper' 'routing' "$(jq -r 'keys[0]' "$CONFIG_DIR/05_routing.json")"
# del(.geodata) 必须真的删掉 14_geodata.json, 否则关掉 Geo 定时后核心仍会加载 geodata 段。
_config_write_merged '{"log":{},"geodata":{"cron":"0 3 */3 * *"}}' >/dev/null 2>&1
[ -f "$CONFIG_DIR/14_geodata.json" ] || fail 'geodata field file is created'
_config_write_merged '{"log":{}}' >/dev/null 2>&1
if [ -e "$CONFIG_DIR/14_geodata.json" ]; then fail 'removed field deletes its file'; else pass 'removed field deletes its file'; fi

# 备份/回滚的单位是整个 confs 目录。
_config_write_merged '{"log":{"loglevel":"warning"}}' >/dev/null 2>&1
_backup_config >/dev/null 2>&1
_config_write_merged '{"log":{"loglevel":"debug"}}' >/dev/null 2>&1
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
_config_write_merged '{"log":{"loglevel":"warning"}}' >/dev/null 2>&1
# DNS 编辑只动 04_dns.json, 其余字段文件原样保留。
# 场景1: 核心预检直接拒绝候选配置 ⇒ 必须保留原配置。_config_edit_preflight 要求 XRAY_BIN
# 可执行, 且 _xray_test_config_dir 要在候选目录上跑真核心; 套件用"可执行空壳 + 恒拒绝"
# 桩来驱动这条拒绝路径(全部限制在子 shell 内, 不泄漏给后续断言)。
_config_write_merged '{"log":{"loglevel":"warning"},"routing":{"rules":[]}}' >/dev/null 2>&1
if (
    : > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
    _xray_test_config_dir() { return 1; }
    _dns_apply --arg a '1.1.1.1' '.dns = ((.dns | if type == "object" then . else {} end) + {servers: [$a]})' >/dev/null 2>&1
); then
    fail 'dns change is refused when the config check cannot pass'
else
    pass 'dns change is refused when the config check cannot pass'
fi
check_eq 'refused dns change keeps the old config' '{}' "$(_config_jq -r '.dns // {}')"
# 场景2: 预检通过后, 变更必须只落在 04_dns.json 上。
_dns_apply_ok() {
    local rc=0
    (
        : > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
        _xray_test_config_dir() { return 0; }
        _dns_apply "$@" >/dev/null 2>&1
    ) || rc=1
    rm -f "$XRAY_BIN"
    return "$rc"
}
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
check_eq 'dns defaults parallel query to true when absent' 'true' "$(_config_jq -r '.dns.enableParallelQuery // true')"
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
    _xray_test_config_dir() { return 0; }
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
_config_write_merged '{"dns":{"servers":[{"unexpectedIPs":["geoip:private","!ext:custom.dat:cn"]}],"hosts":{"geosite:cn":"127.0.0.1","ext:hosts.dat:ads":"127.0.0.1","domain:example.com":"127.0.0.1"}},"routing":{"rules":[]}}'
check_eq 'DNS counts unexpectedIPs and geo hosts keys' '4' "$(_route_dns_geo_count)"
_config_write_merged '{"dns":{"servers":[{"domains":["geosite:cn"],"expectedIPs":["geoip:cn"],"expectIPs":["ext:custom.dat:cn"]}]}}'
check_eq 'DNS retains existing geo field coverage' '3' "$(_route_dns_geo_count)"
_config_write_merged '{"dns":{"hosts":{"!geosite:cn":"127.0.0.1","ext:hosts.dat:ads":"127.0.0.1","domain:example.com":"127.0.0.1"}}}'
check_eq 'DNS hosts keys count even without upstream objects' '2' "$(_route_dns_geo_count)"
_config_write_merged '{"dns":{"hosts":null,"servers":["1.1.1.1"]}}'
check_eq 'DNS missing optional fields consumes no geo data' '0' "$(_route_dns_geo_count)"

printf '== launch contract (confdir + strict JSON) ==\n'
# 启动契约: confdir 与 XRAY_JSON_STRICT 只能通过启动参数/shell 环境传, 不能写进
# config 的 env 段 —— Xray 必须先选定 JSON 解析器才能读配置。这里注入 env 后检查配置里除了
# XRAY_LOCATION_ASSET 没有别的键、且没有任何值指向 confs 目录; 有人"顺手"把严格开关塞进
# env 段时这条会立刻变红。
_config_write_merged '{"log":{},"inbounds":[]}' >/dev/null 2>&1
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
# 只量左段宽度的话, 右格整块丢失时 ${…%%\[2\]*} 会匹配不到而退化成量整行, 宽度仍是 22 ⇒
# 断言假通过。右格存在性必须显式断言。
if contains '[2] 查看节点' "$_menu_row_plain"; then pass 'two-column row keeps the right cell'; else fail 'two-column row keeps the right cell'; fi
check_eq 'two-column row aligns the right cell' 22 "$(_menu_display_width "${_menu_row_plain%%\[2\]*}")"

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

GEO_TRANSITION_KEY=geo_transition
_state_set "$GEO_TRANSITION_KEY" off_pending
check_eq 'Geo off marker persists' off_pending "$(_state_get "$GEO_TRANSITION_KEY")"

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
    _config_write_merged "$(printf '{"inbounds":[%s]}' "$1")" >/dev/null 2>&1
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

printf '== config check and Geo state ==\n'
: > "$ASSET_DIR/geosite.dat"
: > "$ASSET_DIR/geoip.dat"
GEO_TRANSITION_KEY=geo_update_transition
_state_set geo_cron on
# 启用内置 geodata 定时: geodata 段必须落到自己的字段文件里, 旧 cron 兜底状态保留
# (首次成功更新后才 retire, 见 _geo_finalize_legacy_cron)。
_config_write_merged '{"log":{"loglevel":"warning"},"routing":{"rules":[]}}' >/dev/null 2>&1
if _auto_migrate_geo_autoupdate >/dev/null 2>&1 \
   && [ "$(_config_jq -r '.geodata.cron // empty')" = "$GEO_CRON_EXPR" ] \
   && [ -f "$CONFIG_DIR/14_geodata.json" ] \
   && [ "$(_state_get geo_cron)" = on ]; then
    pass 'Geo migration writes the geodata field file'
else
    fail 'Geo migration writes the geodata field file'
fi
# 关闭待清理(off_pending): geodata 字段必须连同 14_geodata.json 一起删掉, 并退休旧 cron。
(
    _crontab_replace() { return 0; }
    _state_set "$GEO_TRANSITION_KEY" off_pending
    _auto_migrate_geo_autoupdate >/dev/null 2>&1 || exit 1
    [ ! -e "$CONFIG_DIR/14_geodata.json" ] || exit 1
    [ "$(_state_get geo_cron)" = off ]
) && pass 'Geo off_pending deletes the geodata field file' || fail 'Geo off_pending deletes the geodata field file'

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
# clash.yaml 是 Xray 节点与官方 Hysteria 节点共用的派生文件, 追加/替换/去重
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
    _config_write_merged '{"geodata":{"cron":"0 3 */3 * *"}}' >/dev/null 2>&1
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

printf '== approved repair regressions ==\n'
if (
    CONFIG_DIR="$TMP/duplicate-confs"
    mkdir -p "$CONFIG_DIR"
    printf '{"inbounds":[{"tag":"one"}]}' > "$CONFIG_DIR/one.json"
    printf '{"inbounds":[{"tag":"two"}]}' > "$CONFIG_DIR/two.json"
    _config_merged >/dev/null 2>&1 && exit 1
    _config_write_merged '{"inbounds":[]}' >/dev/null 2>&1 && exit 1
    [ "$(jq -r '.inbounds[0].tag' "$CONFIG_DIR/one.json")" = one ] &&
        [ "$(jq -r '.inbounds[0].tag' "$CONFIG_DIR/two.json")" = two ]
); then pass 'duplicate top-level fragments refuse read/write without data loss'; else fail 'duplicate top-level fragments refuse read/write without data loss'; fi
if (
    CONFIG_DIR="$TMP/delete-failure-confs"
    _config_write_merged '{"dns":{"servers":["1.1.1.1"]}}' || exit 1
    rm() { [ "${*: -1}" = "$CONFIG_DIR/04_dns.json" ] && return 1; command rm "$@"; }
    _config_write_merged '{}' >/dev/null 2>&1 && exit 1
    [ -f "$CONFIG_DIR/04_dns.json" ]
); then pass 'field deletion failure propagates'; else fail 'field deletion failure propagates'; fi

_test_migration_restore() (
    local failure="$1" state="$2"
    CONFIG_DIR="$TMP/migration-$failure-$state/confs"
    LEGACY_CONFIG_FILE="$TMP/migration-$failure-$state/config.json"
    XRAY_BIN=/bin/true
    local unit="$TMP/migration-$failure-$state/service" attempts=0 current="$state"
    mkdir -p "$CONFIG_DIR"
    printf '{"inbounds":[]}' > "$LEGACY_CONFIG_FILE"
    printf 'legacy-service' > "$unit"
    _xray_service_unit_path() { printf '%s' "$unit"; }
    _xray_service_snapshot_enable() { printf disabled > "$2"; }
    _xray_service_restore_enable() { [ "$failure" != enable ] && [ "$(cat "$1")" = disabled ]; }
    _xray_service_restore_file() { cp "$1" "$2"; }
    _manage_xray() { case "$1" in status) printf '%s' "$current" ;; stop) current=stopped ;; esac; }
    _create_xray_service() { printf confdir-service > "$unit"; [ "$failure" != service ] && [ "$failure" != enable ]; }
    _restart_xray_verified() { attempts=$((attempts+1)); current=running; [ "$failure" = enable ] || [ "$attempts" -gt 1 ]; }
    _config_migrate_legacy >/dev/null 2>&1 && exit 1
    [ -f "$LEGACY_CONFIG_FILE" ] && [ ! -e "$LEGACY_CONFIG_FILE.bak" ] &&
        [ "$(cat "$unit")" = legacy-service ] && ! _config_present &&
        [ "$current" = "$state" ]
)
check 'restart failure restores legacy layout and running state' _test_migration_restore restart running
check 'service creation failure restores legacy layout and stopped state' _test_migration_restore service stopped
check 'enable restoration failure still restarts restored running service' _test_migration_restore enable running
if (
    CONFIG_DIR="$TMP/stopped-migration/confs"
    LEGACY_CONFIG_FILE="$TMP/stopped-migration/config.json"
    XRAY_BIN=/bin/true
    mkdir -p "$CONFIG_DIR"; printf '{"inbounds":[]}' > "$LEGACY_CONFIG_FILE"
    _xray_service_unit_path() { return 1; }
    _manage_xray() { printf stopped; }
    _create_xray_service() { return 0; }
    _restart_xray_verified() { return 1; }
    _config_migrate_legacy >/dev/null 2>&1 && [ -f "$LEGACY_CONFIG_FILE.bak" ]
); then pass 'successful migration leaves stopped service stopped'; else fail 'successful migration leaves stopped service stopped'; fi
if (
    _xray_core_txn_recover_locked() { return 0; }
    _xray_core_txn_pending() { return 1; }
    _config_migrate_legacy() { printf migrated > "$TMP/ordered-migration"; }
    _xray_core_journal_write() { [ -f "$TMP/ordered-migration" ] && printf seen > "$TMP/ordered-journal"; return 1; }
    _install_or_switch_xray_locked stable "$TMP" v26.9.9 >/dev/null 2>&1
    [ -f "$TMP/ordered-journal" ]
); then pass 'migration precedes core journal and service snapshot'; else fail 'migration precedes core journal and service snapshot'; fi

if (
    R_LISTEN=127.0.0.1 R_PORT=12345 R_TAG=test
    R_UUID=11111111-1111-1111-1111-111111111111 R_HOST=example.com R_PATH='/api?a=1&b=2'
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
    _config_write_merged '{"inbounds":[]}' || exit 1
    printf '%s' "$1" > "$NODES_DIR/xh.json"
    ! _hysteria_check_hop_conflicts 40001 40001 >/dev/null 2>&1
)
check 'official single listen rejects Xray singleton hop' _test_xray_hop_conflict '{"hop_ranges":"40001"}'
check 'official single listen rejects Xray range hop' _test_xray_hop_conflict '{"hop_ranges":"40000-40002"}'
check 'official checks legacy udp_hop_ports' _test_xray_hop_conflict '{"udp_hop_ports":"40000-40002"}'
check 'official checks legacy hop_start and hop_end' _test_xray_hop_conflict '{"hop_start":40000,"hop_end":40002}'
if _xh_hop_conflict '{"protocol":"vless","port":443,"streamSettings":{"network":"tcp"}}' 443 443; then fail 'official UDP single port permits same-number TCP inbound'; else pass 'official UDP single port permits same-number TCP inbound'; fi

_test_official_port_menu() (
    local mode="$1" port="$2" udp="$3"
    CONFIG_DIR="$TMP/official-menu-$mode-$port-$udp/confs"
    NODES_DIR="$TMP/official-menu-$mode-$port-$udp/nodes"
    HYSTERIA_CONFIG="$TMP/official-menu-$mode-$port-$udp/hy.json"
    mkdir -p "$NODES_DIR"
    if [ "$udp" = tcp ]; then
        _config_write_merged '{"inbounds":[{"protocol":"vless","port":443,"streamSettings":{"network":"tcp"}}]}' || exit 1
    else
        _config_write_merged '{"inbounds":[]}' || exit 1
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
    CONFIG_DIR="$TMP/first-install/confs"
    LEGACY_CONFIG_FILE="$TMP/first-install/config.json"
    XRAY_BIN="$TMP/first-install/absent-binary"
    mkdir -p "$CONFIG_DIR"; printf '{"inbounds":[]}' > "$LEGACY_CONFIG_FILE"
    _create_xray_service() { exit 1; }
    _config_migrate_legacy >/dev/null 2>&1 && [ -f "$LEGACY_CONFIG_FILE.bak" ] && _config_present
); then pass 'offline legacy migration does not require installed binary'; else fail 'offline legacy migration does not require installed binary'; fi
if (
    CONFIG_DIR="$TMP/broken-duplicate/confs"
    mkdir -p "$CONFIG_DIR"
    printf '{"dns":{}}' > "$CONFIG_DIR/a.json"
    printf '{"dns":{}}' > "$CONFIG_DIR/b.json"
    printf broken > "$CONFIG_DIR/broken.json"
    ! _config_write_merged '{}' >/dev/null 2>&1
); then pass 'malformed fragment cannot bypass duplicate field guard'; else fail 'malformed fragment cannot bypass duplicate field guard'; fi
_test_direct_config_source() (
    local layout="$1"
    CONFIG_DIR="$TMP/direct-$layout/confs"
    LEGACY_CONFIG_FILE="$TMP/direct-$layout/config.json"
    mkdir -p "$CONFIG_DIR"
    printf '{"inbounds":[]}' > "$LEGACY_CONFIG_FILE"
    [ "$layout" != confdir ] || printf '{"inbounds":[]}' > "$CONFIG_DIR/07_inbounds.json"
    INIT_SYSTEM=direct XRAY_DEPLOY_CORE_LOCK_HELD=1
    _xd_pidfile_pid() { printf '%s' "$$"; }
    _xd_pidfile_identity_ok() { return 1; }
    _xd_pidfile_write() { :; }
    sleep() { :; }
    rm() { [ "$1" = -f ] && [ "$2" = /run/xray.pid ]; }
    cat() { if [ "$1" = "/proc/$$/comm" ]; then printf xray; else command cat "$@"; fi; }
    nohup() { printf '%s\n' "$@" > "$TMP/direct-$layout/args"; }
    _manage_xray start >/dev/null 2>&1
    wait
    local expected=-config source="$LEGACY_CONFIG_FILE"
    if [ "$layout" = confdir ]; then expected=-confdir; source="$CONFIG_DIR"; fi
    [ "$(sed -n '3p' "$TMP/direct-$layout/args")" = "$expected" ] &&
        [ "$(sed -n '4p' "$TMP/direct-$layout/args")" = "$source" ]
)
check 'direct restored legacy service starts from existing single file' _test_direct_config_source legacy
check 'direct migrated service prefers nonempty confdir' _test_direct_config_source confdir

# 专属行为套件在独立进程内运行, 不泄漏服务/配置桩到本套件。
for suite in test-node-alignment.sh test-cloudflared-alignment.sh test-hysteria-alignment.sh test-menu-alignment.sh; do
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
