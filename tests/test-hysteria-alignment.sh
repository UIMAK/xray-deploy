#!/usr/bin/env bash
# Offline official-Hysteria behavior; service and bootstrap publication are local stubs.
# 桩函数与 fixture 变量由 source 进来的生产模块间接消费。
# shellcheck disable=SC2329,SC2034
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
    # 自定义尺寸的意义在于 YAML 能表达它: 必须断言实际 min/max 落到 clash 行, 而非只看 rc。
    line=$(_hysteria_clash_line "$HYSTERIA_NODE_META")
    emin=$(jq -r '.obfs.gecko.minPacketSize // 0' "$HYSTERIA_CONFIG")
    emax=$(jq -r '.obfs.gecko.maxPacketSize // 0' "$HYSTERIA_CONFIG")
    [ "$emin" = 0 ] && emin=512
    [ "$emax" = 0 ] && emax=1200
    if contains "obfs-min-packet-size: $emin" "$line" && contains "obfs-max-packet-size: $emax" "$line"; then
        pass "custom Gecko YAML exports sizes $sizes"
    else
        fail "custom Gecko YAML exports sizes $sizes (want min=$emin max=$emax)"
    fi
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
# fail-closed 分支: 无 obfs / 非 gecko / 不支持的 obfs.type 必须按 none 处理, 不得当成可用。
jq 'del(.obfs)' <<< "$base" > "$HYSTERIA_CONFIG"
eq 'missing obfs reports none' none "$(_hysteria_gecko_size_state)"
jq '.obfs={type:"salamander",salamander:{password:"x"}}' <<< "$base" > "$HYSTERIA_CONFIG"
eq 'non-gecko obfs reports none' none "$(_hysteria_gecko_size_state)"
jq '.obfs={type:"unsupported",password:"x"}' <<< "$base" > "$HYSTERIA_CONFIG"
check 'unsupported obfs type reports a URI gap' test -n "$(_hysteria_obfs_uri_gap)"
jq '.obfs={type:"unsupported",password:"x"}' <<< "$base" > "$HYSTERIA_CONFIG"
eq 'unsupported obfs type reports none state' none "$(_hysteria_gecko_size_state)"

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
# choice 2 只取用户输入的 SNI, 从不读证书 CN/SAN; 这里不放 openssl 桩, 避免制造"CN 被读取"的假象。
check 'custom TLS empty SNI accepted' _hysteria_prompt_tls <<< $'2\n'"$TMP/custom.crt"$'\n'"$TMP/custom.key"$'\n\n'
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
printf '== hysteria backup retention ==\n'
# 保留裁剪是破坏性路径(rm 历史备份): 必须证明只裁最旧的, 且不误伤 lastbak/无关同级条目。
# mtime 用 POSIX touch -t 拉开, 否则同秒创建的文件在 ls -1dt 里次序不定。
hysteria_backup_retention() (
    local i f n=0
    # 自带目标文件, 不依赖前面用例对 HYSTERIA_CONFIG 的临时改写。
    HYSTERIA_CONFIG="$TMP/hysteria-retention.json"
    mkdir -p "$HYSTERIA_BACKUP_DIR" || return 1
    rm -rf "${HYSTERIA_BACKUP_DIR:?}"/*
    printf '%s\n' '{"listen":":443","auth":{"type":"password","password":"pw"}}' > "$HYSTERIA_CONFIG" || return 1
    for ((i = 1; i <= 13; i++)); do
        f="$HYSTERIA_BACKUP_DIR/hysteria.json.bak.202001$(printf '%02d' "$i")-000000"
        printf 'sentinel-%s' "$i" > "$f" || return 1
        touch -t "202001$(printf '%02d' "$i")0000" "$f" || return 1
    done
    # 无关同级条目不在 hysteria.json.bak.* 内, 裁剪不得波及。
    printf 'keep' > "$HYSTERIA_BACKUP_DIR/unrelated.txt"
    _hysteria_backup_config >/dev/null 2>&1 || return 1
    # 本次新增 1 份 + 原有 13 份 = 14, 裁剪后必须恰好 10 份。
    for f in "$HYSTERIA_BACKUP_DIR"/hysteria.json.bak.*; do
        [ -f "$f" ] || continue
        n=$((n + 1))
    done
    [ "$n" -eq 10 ] || return 1
    # 裁掉的必须是 4 份最旧的; 最新一份内容完整。
    for ((i = 1; i <= 4; i++)); do
        [ ! -e "$HYSTERIA_BACKUP_DIR/hysteria.json.bak.202001$(printf '%02d' "$i")-000000" ] || return 1
    done
    [ -s "$HYSTERIA_BACKUP_DIR/hysteria.json.bak.20200113-000000" ] &&
        [ -f "$HYSTERIA_BACKUP_DIR/unrelated.txt" ] &&
        [ -s "$HYSTERIA_BACKUP_DIR/hysteria.json.lastbak" ]
)
check 'hysteria backup retention keeps the newest 10 and spares siblings' hysteria_backup_retention
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
