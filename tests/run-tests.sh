#!/usr/bin/env bash
# =============================================================================
# tests/run-tests.sh — xray-deploy 回归测试
# 纯 bash + jq 断言, 不需要 root / 网络 / xray 二进制; 可在任意机器运行。
# 覆盖: 00-common 纯函数(转义/编码/改名/链接改写), 20-xray-core dgst 解析,
#       50-nodes clash 条目重建与同步(F1)、路由精简顺序契约、reality 模式判定,
#       模板占位符渲染 → JSON 合法性。
# 用法: bash tests/run-tests.sh   (退出码 0 = 全部通过)
# =============================================================================
set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILED_NAMES=()

# 独立沙箱: DEPLOY_DIR 指向临时目录, 避免测试触碰真实部署
TMP_ROOT=$(mktemp -d /tmp/xray-deploy-test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

t_pass() { PASS=$((PASS+1)); echo "  ok    - $1"; }
t_fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  FAIL  - $1"; }
assert_eq() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then t_pass "$1"; else t_fail "$1 (expected [$2] got [$3])"; fi
}
assert_contains() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) t_pass "$1" ;; *) t_fail "$1 (missing [$2] in [$3])" ;; esac
}
assert_not_contains() {
    case "$3" in *"$2"*) t_fail "$1 (unexpected [$2] in [$3])" ;; *) t_pass "$1" ;; esac
}

# ---------------------------------------------------------------------------
# 加载被测模块(只定义常量与函数, 无副作用)。00 最先; DEPLOY_DIR 在加载后被覆盖,
# 因此先 source 再改常量(函数体在调用时才展开变量, 与运行期行为一致)。
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/00-common.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/20-xray-core.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/30-geo.sh"
# shellcheck disable=SC1091
. "$TEST_ROOT/lib/50-nodes.sh"

DEPLOY_DIR="$TMP_ROOT/deploy"
CONFIG_FILE="$DEPLOY_DIR/config.json"
NODES_DIR="$DEPLOY_DIR/nodes"
CLASH_YAML="$DEPLOY_DIR/clash.yaml"
mkdir -p "$DEPLOY_DIR" "$NODES_DIR"

echo "== 00-common: _yaml_dq =="
assert_eq "双引号转义" 'a\"b' "$(_yaml_dq 'a"b')"
assert_eq "反斜杠优先转义" 'a\\\"b' "$(_yaml_dq 'a\"b')"
assert_eq "换行转义" 'a\nb' "$(_yaml_dq "$(printf 'a\nb')")"
assert_eq "普通字符不动" 'a{b}:c#d' "$(_yaml_dq 'a{b}:c#d')"

echo "== 00-common: _url_encode =="
assert_eq "保留安全字符" "abc123.~_-" "$(_url_encode 'abc123.~_-')"
assert_eq "冒号斜杠编码" "%3A%2F" "$(_url_encode ':/')"
assert_eq "等号编码(base64 密钥)" "%2B%2F%3D" "$(_url_encode '+/=')"

echo "== 00-common: _normalize_bandwidth =="
assert_eq "纯数字补 mbps" "100 mbps" "$(_normalize_bandwidth 100)"
assert_eq "短后缀 g" "1 gbps" "$(_normalize_bandwidth 1g)"
assert_eq "短后缀 m" "10 mbps" "$(_normalize_bandwidth 10m)"
assert_eq "完整格式原样" "100 mbps" "$(_normalize_bandwidth '100 mbps')"

echo "== 00-common: _rename_node_with_port (F8 回归) =="
assert_eq "标准后缀改名" "HY2-7777" "$(_rename_node_with_port "HY2-5432" 5432 7777)"
assert_eq "名称含端口号子串不误伤" "HY2-54321" "$(_rename_node_with_port "HY2-54321" 5432 7777)"
assert_eq "无后缀匹配保留原名" "My Node" "$(_rename_node_with_port "My Node" 5432 7777)"

echo "== 00-common: _rewrite_link_addr / _rewrite_link_port (F7 回归) =="
assert_eq "IPv4 地址改写保端口" \
    "vless://u@1.2.3.4:443?sni=x#n" \
    "$(_rewrite_link_addr "vless://u@5.6.7.8:443?sni=x#n" "1.2.3.4")"
assert_eq "IPv6 目标自动加括号" \
    "hy2://p@[2001:db8::1]:443/?sni=x" \
    "$(_rewrite_link_addr "hy2://p@5.6.7.8:443/?sni=x" "2001:db8::1")"
assert_eq "IPv6 源解析 host 段" \
    "vless://u@9.9.9.9:443?sni=x" \
    "$(_rewrite_link_addr "vless://u@[2001:db8::1]:443?sni=x" "9.9.9.9")"
assert_eq "无 @ 占位链接输出空(F7)" "" "$(_rewrite_link_addr '#tag (adopted)' '1.2.3.4')"
assert_eq "端口改写(IPv4)" \
    "vless://u@5.6.7.8:9999?sni=x#n" \
    "$(_rewrite_link_port "vless://u@5.6.7.8:443?sni=x#n" 443 9999)"
assert_eq "端口改写(IPv6)" \
    "vless://u@[2001:db8::1]:9999?sni=x" \
    "$(_rewrite_link_port "vless://u@[2001:db8::1]:443?sni=x" 443 9999)"
assert_eq "端口改写对无 @ 占位输出空" "" "$(_rewrite_link_port '#tag (adopted)' 443 9999)"
assert_eq "path 中旧端口子串不受影响(锚定在 @ 后 host:port)" \
    "vless://u@h:9999/?path=keep443here" \
    "$(_rewrite_link_port "vless://u@h:443/?path=keep443here" 443 9999)"

echo "== 20-xray-core: _dgst_sha256_of (F2 回归) =="
cat > "$TMP_ROOT/test.dgst" <<'EOF'
MD5= ee4e2ff74948a9b464624b1cabc44409
SHA1= b55b06e74e89083b9cedfdecf0d68b579cd2af72
SHA2-256= 23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
SHA2-512= e8bc40a0687cac184bbe4b5c1f047e69064ccedc489fb25e208889ae287bbf8736
EOF
assert_eq "解析 SHA2-256 行" \
    "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae" \
    "$(_dgst_sha256_of "$TMP_ROOT/test.dgst")"
printf 'garbage only\n' > "$TMP_ROOT/bad.dgst"
assert_eq "无 sha256 行输出空" "" "$(_dgst_sha256_of "$TMP_ROOT/bad.dgst")"

echo "== 50-nodes: _gen_free_tunnel_port (F9 回归) =="
CONFIG_FILE="$DEPLOY_DIR/config.json"
printf '{"inbounds":[{"tag":"a","port":20000},{"tag":"b","port":20001}]}' > "$CONFIG_FILE"
GEN_OK=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    r=$(_gen_free_tunnel_port 20002)
    case "$r" in
        20000|20001|20002) GEN_OK=0 ;;  # 已在 config / 被排除的端口不得返回
    esac
    [[ "$r" =~ ^[0-9]+$ ]] || GEN_OK=0
done
[ "$GEN_OK" -eq 1 ] && t_pass "排除 config 端口与指定端口" || t_fail "返回了冲突端口"

echo "== 50-nodes: _rebuild_clash_line (F1) =="
printf '{"tag":"xd-hy2-5000","name":"HY2-5000","protocol":"hysteria2","port":5000,"listen":"::","link_addr":"1.2.3.4","auth":"secret","sni":"build.nvidia.com","congestion":"bbr","self_signed":"false","share_link":"x"}' \
    > "$NODES_DIR/xd-hy2-5000.json"
line=$(_rebuild_clash_line "$NODES_DIR/xd-hy2-5000.json")
assert_contains "hy2 条目含端口" "port: 5000" "$line"
assert_contains "hy2 条目含密码" 'password: "secret"' "$line"
# 被采纳节点(缺 auth 等字段)必须失败而不是产出坏行
printf '{"tag":"adopted","name":"adopted","protocol":"hysteria2","port":1,"listen":"::","link_addr":"","share_link":"#adopted"}' \
    > "$NODES_DIR/adopted.json"
out=$(_rebuild_clash_line "$NODES_DIR/adopted.json") && rc=0 || rc=1
assert_eq "缺字段节点 builder 拒绝" "1" "$rc"

# reality builder
printf '{"tag":"xd-reality-vision-443","name":"Reality-443","protocol":"vless-tcp-reality-vision","port":443,"listen":"::","link_addr":"5.6.7.8","uuid":"11111111-2222-3333-4444-555555555555","sni":"www.amd.com","public_key":"PUBKEY","short_id":"abcd1234","share_link":"x"}' \
    > "$NODES_DIR/xd-reality-vision-443.json"
rline=$(_rebuild_clash_line "$NODES_DIR/xd-reality-vision-443.json")
assert_contains "reality 条目含 mlkem768 开关" "support-x25519mlkem768: true" "$rline"
assert_contains "reality 条目含 chrome 指纹" '"client-fingerprint": chrome' "$rline"
assert_contains "reality 条目含 servername" 'servername: "www.amd.com"' "$rline"

echo "== 50-nodes: _sync_node_clash 替换/追加/改名删旧 (F1 回归) =="
printf 'proxies:\n  - {name: "Old-443", type: vless, server: "5.6.7.8", port: 443}\n' > "$CLASH_YAML"
# 现名与 yaml 中条目不同且未传 old_name → 追加(而非静默替换失败)
printf '{"tag":"xd-reality-vision-443","name":"Reality-443","protocol":"vless-tcp-reality-vision","port":443,"listen":"::","link_addr":"5.6.7.8","uuid":"11111111-2222-3333-4444-555555555555","sni":"www.amd.com","public_key":"PUBKEY","short_id":"abcd1234","share_link":"x"}' \
    > "$NODES_DIR/xd-reality-vision-443.json"
_sync_node_clash "$NODES_DIR/xd-reality-vision-443.json"
assert_contains "同步后含新条目" 'name: "Reality-443"' "$(cat "$CLASH_YAML")"
# 改名场景: 传 old_name, 旧行必须被删
printf '{"tag":"xd-reality-vision-443","name":"Reality-9999","protocol":"vless-tcp-reality-vision","port":9999,"listen":"::","link_addr":"5.6.7.8","uuid":"11111111-2222-3333-4444-555555555555","sni":"www.amd.com","public_key":"PUBKEY","short_id":"abcd1234","share_link":"x"}' \
    > "$NODES_DIR/xd-reality-vision-443.json"
_sync_node_clash "$NODES_DIR/xd-reality-vision-443.json" "Reality-443"
YAML_NOW="$(cat "$CLASH_YAML")"
assert_contains "改名后新条目在" 'name: "Reality-9999"' "$YAML_NOW"
assert_not_contains "改名后旧条目已删" 'name: "Reality-443"' "$YAML_NOW"

echo "== 30-geo: 路由精简顺序契约(节点规则保持最前) =="
GEO_RULE_REF_JQ="${GEO_RULE_REF_JQ:-}"
printf '{"routing":{"rules":[{"inboundTag":["tun"],"domain":["x.com"],"outboundTag":"direct"},{"protocol":["bittorrent"],"outboundTag":"block"},{"domain":["geosite:ads"],"outboundTag":"block"},{"ip":["geoip:cn"],"outboundTag":"block"}]}}' > "$CONFIG_FILE"
SLIMMED=$(jq -c --argjson priv '{"ruleTag":"xd-block-private","ip":["127.0.0.0/8"],"outboundTag":"block"}' \
    ".routing.rules = ([.routing.rules[]?
        | select(${GEO_RULE_REF_JQ} | not)
        | select((.ruleTag? // null) != \"xd-block-private\")] as \$k
      | ([\$k | to_entries[] | select(.value.inboundTag? == null) | .key] | first // (\$k | length)) as \$i
      | \$k[0:\$i] + [\$priv] + \$k[\$i:])" "$CONFIG_FILE") || SLIMMED=""
FIRST_TAG=$(printf '%s' "$SLIMMED" | jq -r '.routing.rules[0].inboundTag[0] // empty')
assert_eq "精简后第一条仍是节点规则" "tun" "$FIRST_TAG"
assert_contains "私网规则插在节点规则之后" '"ruleTag":"xd-block-private"' "$SLIMMED"
SLIMMED2=$(printf '%s' "$SLIMMED" | jq -c --argjson priv '{"ruleTag":"xd-block-private","ip":["127.0.0.0/8"],"outboundTag":"block"}' \
    ".routing.rules = ([.routing.rules[]?
        | select(${GEO_RULE_REF_JQ} | not)
        | select((.ruleTag? // null) != \"xd-block-private\")] as \$k
      | ([\$k | to_entries[] | select(.value.inboundTag? == null) | .key] | first // (\$k | length)) as \$i
      | \$k[0:\$i] + [\$priv] + \$k[\$i:])")
assert_eq "精简幂等(重复执行字节一致)" "$SLIMMED" "$SLIMMED2"

echo "== 50-nodes: _reality_node_mode 模式判定 =="
printf '{"inbounds":[{"tag":"rt","protocol":"vless","streamSettings":{"security":"reality","network":"raw","realitySettings":{"target":"127.0.0.1:33333"}}},{"tag":"rd","protocol":"vless","streamSettings":{"security":"reality","network":"raw","realitySettings":{"target":"www.amd.com:443"}}}]}' > "$CONFIG_FILE"
printf '{"tag":"rt","reality_mode":"tunnel"}' > "$NODES_DIR/rt.json"
printf '{"tag":"rd","reality_mode":"direct"}' > "$NODES_DIR/rd.json"
assert_eq "回环 target + tunnel 元数据" "tunnel" "$(_reality_node_mode rt)"
assert_eq "非回环 target + direct 元数据" "direct" "$(_reality_node_mode rd)"
# 元数据与 config 冲突 → 一律保守 tunnel(fail-closed)
printf '{"tag":"rc","reality_mode":"direct"}' > "$NODES_DIR/rc.json"
printf '{"inbounds":[{"tag":"rc","protocol":"vless","streamSettings":{"security":"reality","network":"raw","realitySettings":{"target":"127.0.0.1:33333"}}}]}' > "$CONFIG_FILE"
assert_eq "元数据声明 direct 但 config 回环 → 保守 tunnel" "tunnel" "$(_reality_node_mode rc)"
# 非法 reality_mode 视同缺失(绝不输出第三种模式)
printf '{"tag":"ri","reality_mode":"foobar"}' > "$NODES_DIR/ri.json"
printf '{"inbounds":[{"tag":"ri","protocol":"vless","streamSettings":{"security":"reality","network":"raw","realitySettings":{"target":"www.amd.com:443"}}}]}' > "$CONFIG_FILE"
assert_eq "非法 reality_mode 忽略并按 config 归类" "direct" "$(_reality_node_mode ri)"

echo "== 菜单 EOF 防空转(2026-09-12 实测发现 RT-1) =="
# 修复前: while true 菜单在 stdin EOF 时 read 立即返回空串 → 无限 clear/warn 空转。
# 现契约: 所有 while true 菜单的主 read 必须带 `|| return`(主菜单 `|| exit 0`)。
for f in "$TEST_ROOT"/lib/90-menu.sh "$TEST_ROOT"/lib/40-cloudflared.sh "$TEST_ROOT"/lib/45-logrotate.sh "$TEST_ROOT"/lib/30-geo.sh; do
    # while true 块内的主 read: 要求存在 `read ... choice || return` 或 `|| exit 0`
    if grep -qE 'read -rp "  (请选择|选择节点): " choice \|\| (return|exit 0)' "$f"; then
        t_pass "$(basename "$f"): 菜单主 read 带 EOF 退出"
    else
        t_fail "$(basename "$f"): 菜单主 read 缺 EOF 退出(会无限空转)"
    fi
done
# 行为级验证: EOF 输入下路由菜单必须立即返回(超时 8s 内退出)
if timeout 8 bash -c ". '$TEST_ROOT/lib/00-common.sh'; . '$TEST_ROOT/lib/10-system.sh'; . '$TEST_ROOT/lib/30-geo.sh'; INIT_SYSTEM=direct; CONFIG_FILE=/nonexistent; printf '' | _route_rules_menu" >/dev/null 2>&1; then
    t_pass "EOF 下菜单 8s 内正常返回(无空转)"
else
    t_fail "EOF 下菜单空转或超时"
fi

echo "== templates: 占位符渲染 → JSON 合法 =="
TPL_OK=1
for f in "$TEST_ROOT"/templates/*.jsonc; do
    if ! sed 's/,*[[:space:]]*{{[A-Z_0-9]*_BLOCK}}//g; s/{{[A-Z_0-9]*}}/null/g' "$f" \
        | jq -e . >/dev/null 2>&1; then
        TPL_OK=0
        echo "        模板失败: $f"
    fi
done
[ "$TPL_OK" -eq 1 ] && t_pass "全部模板替换占位符后 JSON 合法" || t_fail "存在非法模板"

echo
echo "============================================"
echo "通过 ${PASS}, 失败 ${FAIL}"
if [ "$FAIL" -gt 0 ]; then
    printf '失败项: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi
exit 0
