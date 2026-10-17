#!/usr/bin/env bash
# lib/35-warp.sh 的离线回归: 归一/生成、获取失败不落盘、分流规则写入与序号、出站生命周期、静态约束。
# 全部断言不联网、不启服务: 配置只写进 mktemp 目录, 写入统一由真实 jq 落盘的 _mutate_config 桩完成。
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || { printf 'SUMMARY pass=0 fail=1\n'; exit 1; }
# 被 source 时不得 exit/覆盖调用方的 EXIT trap; 作为子进程运行(未 source)时才 exit 与装 trap。
_XD_SOURCED=0
[ "${BASH_SOURCE[0]}" != "$0" ] && _XD_SOURCED=1
_XD_TMP_OWNED=0
if [ "$_XD_SOURCED" -eq 0 ]; then
    command -v jq >/dev/null 2>&1 || { printf 'SUMMARY pass=0 fail=1 (jq required)\n'; exit 1; }
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-warp-alignment.XXXXXX") || { printf 'SUMMARY pass=0 fail=1 (mktemp failed)\n'; exit 1; }
    cleanup() {
        # 直接按 $TMP 的模板前缀判定, 不依赖 pwd -P 相等(软链 TMPDIR 下会漏删)。
        case "$TMP" in
            "${TMPDIR:-/tmp}"/xray-warp-alignment.*) rm -rf -- "$TMP" ;;
        esac
    }
    trap cleanup EXIT
else
    # 被 source 时用调用方的 TMP; 缺失则自建临时目录, 由下方子 shell 负责清理。
    if [ -z "${TMP:-}" ]; then
        TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-warp-alignment.XXXXXX") || {
            printf 'SUMMARY pass=0 fail=1 (mktemp failed)\n'
            return 1
        }
        _XD_TMP_OWNED=1
    fi
fi

# 所有桩都留在子 shell 内, 被 source 时不污染调用方。
(
    [ "${_XD_TMP_OWNED:-0}" -eq 1 ] && trap 'rm -rf -- "$TMP"' EXIT
    . "$ROOT/lib/00-common.sh"
    . "$ROOT/lib/35-warp.sh"

    DEPLOY_DIR="$TMP/deploy"
    CONFIG_DIR="$DEPLOY_DIR/confs"
    BACKUP_DIR="$DEPLOY_DIR/backups"
    STATE_DIR="$DEPLOY_DIR/state"
    XRAY_BIN="$TMP/bin/xray"
    FX="$TMP/fx"
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$STATE_DIR" "$TMP/bin" "$FX" || exit 1
    # _config_edit_preflight 要求核心可执行; 这里只放一个立即退出的壳文件, 不会真的启动核心。
    printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN" && chmod +x "$XRAY_BIN" || exit 1
    PASS=0 FAIL=0

    _info() { printf 'info: %s\n' "$*" >> "$TMP/messages"; }
    _warn() { printf 'warn: %s\n' "$*" >> "$TMP/messages"; }
    _error() { printf 'error: %s\n' "$*" >> "$TMP/messages"; }

    check() {
        local label="$1"
        shift
        if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label"; fi
    }
    eq() { [ "$1" = "$2" ]; }
    # 静默 jq -e 断言: 只让 check 看到返回码, 不把配置内容打到终端。
    qe() { _config_jq -e "$1" >/dev/null 2>&1; }

    # 真实落盘的 _mutate_config 桩: 契约是"最后一个是单个 filter, 前面都是 jq 选项",
    # 与 _config_jq 的参数顺序一致, 因此原样转交; 写入仍走生产的 _config_write_merged。
    _mutate_config() {
        local content
        content=$(_config_jq "$@") || return 1
        [ -n "$content" ] || return 1
        _config_write_merged "$content"
    }

    # confs 目录的字节快照(含文件名), 供 cmp 证明"没有发生写入"。
    cfg_snapshot() {
        local f
        : > "$1"
        for f in "$CONFIG_DIR"/*.json; do
            [ -f "$f" ] || continue
            printf '### %s\n' "$(basename "$f")" >> "$1"
            cat "$f" >> "$1"
        done
    }

    # 用 stdin 的完整配置重建 scratch 配置目录(仍按一字段一文件拆分)。
    cfg_reset() {
        local content
        content=$(jq -c .) || return 1
        rm -f "$CONFIG_DIR"/*.json
        _config_write_merged "$content"
    }

    # 默认路由规则(含 block 的 geoip:cn 与 direct 白名单里的 github.com)。
    base_cfg() {
        jq -n -c --argjson rules "$XRAY_DEFAULT_ROUTING_RULES_JSON" '{
            log: {loglevel: "warning"},
            inbounds: [{tag: "xd-vless-443", protocol: "vless", port: 443}],
            outbounds: [
                {tag: "direct", protocol: "freedom"},
                {tag: "block", protocol: "blackhole"}
            ],
            routing: {domainStrategy: "AsIs", rules: $rules}
        }'
    }

    # 内部表示 fixture: 只用于 build/apply, 字段与模块契约一致。
    norm_a() {
        jq -n -c '{secretKey: "c2VjcmV0LWE=", address: ["172.16.0.2/32", "2606:4700:110:8a36::2/128"],
                  reserved: [0, 0, 0], endpoint: "162.159.192.1:2408", publicKey: "cHVibGljLWtleS1h",
                  allowedIPs: ["0.0.0.0/0", "::/0"], mtu: 1280}'
    }
    norm_b() {
        jq -n -c '{secretKey: "c2VjcmV0LWI=", address: ["172.16.0.3/32"], reserved: [1, 2, 3],
                  endpoint: "162.159.192.2:2408", publicKey: "cHVibGljLWtleS1i",
                  allowedIPs: ["0.0.0.0/0", "::/0"], mtu: 1280}'
    }

    # -----------------------------------------------------------------------
    # A. 三种归一 + 生成
    # -----------------------------------------------------------------------
    printf '== A. normalize fixtures ==\n'

    # warp-reg.sh 形态: endpoint.v4/v6、reserved_dec、private_key/public_key、v4/v6。
    cat > "$FX/reg-ok.json" <<'JSON'
{"private_key": "cHJpdmF0ZS1rZXktcmVn", "public_key": "cHVibGljLWtleS1yZWc=",
 "endpoint": {"v4": "162.159.192.1:0", "v6": "[2606:4700:110:8a36::1]:0"},
 "reserved_dec": [12, 34, 56], "v4": "172.16.0.2", "v6": "2606:4700:110:8a36::2"}
JSON
    # wgcf-cli 注册形态: 地址在 addresses.v4/v6, endpoint 是裸主机(需要补默认端口)。
    cat > "$FX/wgcf-reg.json" <<'JSON'
{"private_key": "cHJpdmF0ZS1rZXktd2djZg==", "public_key": "cHVibGljLWtleS13Z2Nm",
 "endpoint": {"v4": "162.159.192.2", "v6": "2606:4700:110:8a36::3"},
 "reserved_dec": [1, 2, 3], "addresses": {"v4": "172.16.0.3", "v6": "2606:4700:110:8a36::4"}}
JSON
    # wgcf-cli generate --xray 出站形态: 地址无掩码, 走 out2norm。
    cat > "$FX/wgcf-xray.json" <<'JSON'
{"outbounds": [{"tag": "warp", "protocol": "wireguard", "settings": {
  "secretKey": "c2VjcmV0LXdnY2YteHJheQ==", "address": ["172.16.0.5"], "reserved": [7, 8, 9],
  "peers": [{"publicKey": "cHVibGljLXdnY2YteHJheQ==", "endpoint": "162.159.192.5:2408",
             "allowedIPs": ["0.0.0.0/0", "::/0"]}], "mtu": 1280}}]}
JSON
    # API 出站形态: 缺 allowedIPs 与 mtu, 归一必须补默认值而不是透传来源 JSON。
    cat > "$FX/api.json" <<'JSON'
{"tag": "warp", "protocol": "wireguard", "settings": {
  "secretKey": "c2VjcmV0LWFwaQ==", "address": ["172.16.0.6/32", "2606:4700:110:8a36::6/128"],
  "reserved": [10, 11, 12],
  "peers": [{"publicKey": "cHVibGljLWFwaQ==", "endpoint": "162.159.192.6:2408"}]}}
JSON

    # 坏 fixture: 注册形态与出站形态各一套, 覆盖 非法 JSON / 缺字段 / reserved 长度 / reserved 越界。
    printf '{"private_key": ' > "$FX/reg-bad-json.json"
    printf '{"private_key": "k"}\n' > "$FX/reg-bad-missing.json"
    printf '{"private_key": "k", "v4": "172.16.0.2", "public_key": "p", "endpoint": "162.159.192.1:2408", "reserved_dec": [1, 2]}\n' > "$FX/reg-bad-reserved2.json"
    printf '{"private_key": "k", "v4": "172.16.0.2", "public_key": "p", "endpoint": "162.159.192.1:2408", "reserved_dec": [1, 2, 300]}\n' > "$FX/reg-bad-reserved300.json"
    printf '{"settings": {' > "$FX/out-bad-json.json"
    printf '{"outbounds": [{"settings": {"secretKey": "k"}}]}\n' > "$FX/out-bad-missing.json"
    printf '{"outbounds": [{"settings": {"secretKey": "k", "address": ["172.16.0.2/32"], "reserved": [1, 2], "peers": [{"publicKey": "p", "endpoint": "162.159.192.1:2408", "allowedIPs": ["0.0.0.0/0"]}], "mtu": 1280}}]}\n' > "$FX/out-bad-reserved2.json"
    printf '{"outbounds": [{"settings": {"secretKey": "k", "address": ["172.16.0.2/32"], "reserved": [1, 2, 300], "peers": [{"publicKey": "p", "endpoint": "162.159.192.1:2408", "allowedIPs": ["0.0.0.0/0"]}], "mtu": 1280}}]}\n' > "$FX/out-bad-reserved300.json"

    # 合法归一: rc=0, 恰好 7 个字段, address 全部带掩码, reserved 长度 3。
    norm_ok() {   # <归一函数> <rawfile> <outfile>
        local rc
        "$1" "$2" > "$3" 2>/dev/null
        rc=$?
        [ "$rc" -eq 0 ] || return 1
        jq -e '
            (length == 7)
            and (keys == ["address", "allowedIPs", "endpoint", "mtu", "publicKey", "reserved", "secretKey"])
            and ((.address | length) > 0)
            and ([.address[] | test("/(32|128)$")] | all)
            and ((.reserved | length) == 3)
        ' "$3" >/dev/null 2>&1
    }
    # 坏归一: rc=1 且 stdout 字节数为 0。
    norm_bad() {   # <归一函数> <rawfile>
        local rc
        "$1" "$2" > "$TMP/norm-bad.out" 2>/dev/null
        rc=$?
        [ "$rc" -eq 1 ] || return 1
        [ ! -s "$TMP/norm-bad.out" ]
    }

    check 'normalize reg: valid warp-reg.sh fixture yields 7 masked fields' norm_ok _warp_normalize_reg "$FX/reg-ok.json" "$TMP/n-reg.json"
    check 'normalize reg: endpoint port 0 becomes 2408' eq '162.159.192.1:2408' "$(jq -r .endpoint "$TMP/n-reg.json")"
    check 'normalize reg: v4/v6 addresses get /32 and /128' eq '172.16.0.2/32,2606:4700:110:8a36::2/128' "$(jq -r '.address | join(",")' "$TMP/n-reg.json")"
    check 'normalize reg: reserved_dec passes through' eq '[12,34,56]' "$(jq -c .reserved "$TMP/n-reg.json")"

    check 'normalize wgcf: valid registration fixture yields 7 masked fields' norm_ok _warp_normalize_wgcf "$FX/wgcf-reg.json" "$TMP/n-wgcf.json"
    check 'normalize wgcf: addresses.v4/v6 are mapped and masked' eq '172.16.0.3/32,2606:4700:110:8a36::4/128' "$(jq -r '.address | join(",")' "$TMP/n-wgcf.json")"
    check 'normalize wgcf: bare host endpoint gains default port' eq '162.159.192.2:2408' "$(jq -r .endpoint "$TMP/n-wgcf.json")"

    check 'normalize wgcf: generate --xray outbound fixture yields 7 masked fields' norm_ok _warp_normalize_wgcf "$FX/wgcf-xray.json" "$TMP/n-wgcfx.json"
    check 'normalize wgcf: outbound address without mask gains /32' eq '172.16.0.5/32' "$(jq -r '.address | join(",")' "$TMP/n-wgcfx.json")"

    check 'normalize api: outbound fixture yields 7 masked fields' norm_ok _warp_normalize_api "$FX/api.json" "$TMP/n-api.json"
    check 'normalize api: missing allowedIPs defaults to 0.0.0.0/0 and ::/0' eq '["0.0.0.0/0","::/0"]' "$(jq -c .allowedIPs "$TMP/n-api.json")"
    check 'normalize api: missing mtu defaults to 1280' eq '1280' "$(jq -r .mtu "$TMP/n-api.json")"

    for bad in reg-bad-json reg-bad-missing reg-bad-reserved2 reg-bad-reserved300; do
        check "normalize reg rejects $bad with rc=1 and empty stdout" norm_bad _warp_normalize_reg "$FX/$bad.json"
        check "normalize wgcf rejects $bad with rc=1 and empty stdout" norm_bad _warp_normalize_wgcf "$FX/$bad.json"
    done
    for bad in out-bad-json out-bad-missing out-bad-reserved2 out-bad-reserved300; do
        check "normalize api rejects $bad with rc=1 and empty stdout" norm_bad _warp_normalize_api "$FX/$bad.json"
        check "normalize wgcf rejects $bad with rc=1 and empty stdout" norm_bad _warp_normalize_wgcf "$FX/$bad.json"
    done

    printf '== A. endpoint normalization ==\n'
    check 'endpoint: port 0 is replaced by 2408' eq '162.159.192.1:2408' "$(_warp_endpoint_norm '162.159.192.1:0')"
    check 'endpoint: bare host gains default port' eq 'engage.cloudflareclient.com:2408' "$(_warp_endpoint_norm 'engage.cloudflareclient.com')"
    check 'endpoint: bare IPv6 is bracketed and gains a port' eq '[2606:4700:110:8a36::1]:2408' "$(_warp_endpoint_norm '2606:4700:110:8a36::1')"
    check 'endpoint: host:port is preserved verbatim' eq '162.159.192.1:500' "$(_warp_endpoint_norm '162.159.192.1:500')"
    check 'endpoint: bracketed IPv6:port is preserved verbatim' eq '[2606:4700::1]:2408' "$(_warp_endpoint_norm '[2606:4700::1]:2408')"

    printf '== A. normalize to build pipeline ==\n'
    build_ok() {   # <归一输出文件>
        cat "$1" | _warp_build_outbound > "$TMP/outbound.json" 2>/dev/null || return 1
        jq -e '
            (.tag == "warp")
            and (.protocol == "wireguard")
            and (.settings.noKernelTun == true)
            and ((.settings.peers | length) == 1)
        ' "$TMP/outbound.json" >/dev/null 2>&1
    }
    check 'build: reg normalize output becomes a single warp wireguard outbound' build_ok "$TMP/n-reg.json"
    check 'build: api normalize output becomes a single warp wireguard outbound' build_ok "$TMP/n-api.json"
    check 'build: peers keep publicKey/endpoint/allowedIPs from normalize' eq 'cHVibGljLWFwaQ==|162.159.192.6:2408|0.0.0.0/0,::/0' "$(jq -r '.settings.peers[0] | [.publicKey, .endpoint, (.allowedIPs | join(","))] | join("|")' "$TMP/outbound.json")"
    check 'build: default mtu 1280 is carried into settings' eq '1280' "$(jq -r '.settings.mtu' "$TMP/outbound.json")"

    # -----------------------------------------------------------------------
    # B. 获取失败不污染输出
    # -----------------------------------------------------------------------
    printf '== B. fetch failure does not write output ==\n'
    fetch_all_fail() (
        # 隐藏主机上可能存在的 warp-reg / wgcf-cli, 让三种来源都落到"取不到"的分支。
        command() {
            case "${1:-} ${2:-}" in
                "-v warp-reg"|"-v warp-reg.sh"|"-v wgcf-cli") return 1 ;;
            esac
            builtin command "$@"
        }
        _http_download() { return 1; }
        local rc ok=0
        for fn in _warp_fetch_warp_reg _warp_fetch_wgcf_cli _warp_fetch_api; do
            "$fn" "$TMP/fetch.out" > "$TMP/fetch.stdout" 2>/dev/null
            rc=$?
            [ "$rc" -eq 1 ] || ok=1
            [ ! -s "$TMP/fetch.stdout" ] || ok=1
        done
        rm -f "$TMP/obtain.out"
        _warp_obtain "$TMP/obtain.out" >/dev/null 2>&1
        [ "$?" -eq 1 ] || ok=1
        [ ! -e "$TMP/obtain.out" ] || ok=1
        return "$ok"
    )
    check 'fetch: download failure leaves rc=1, empty stdout and no outfile' fetch_all_fail

    fetch_empty_response() (
        # 命令存在但什么都不输出: 空响应同样必须判失败, 且不得写出 outfile。
        warp-reg() { return 1; }
        wgcf-cli() { return 1; }
        _http_download() { return 1; }
        _warp_fetch_warp_reg "$TMP/fetch.out" > "$TMP/fetch.stdout" 2>/dev/null || :
        [ ! -s "$TMP/fetch.stdout" ] || return 1
        rm -f "$TMP/obtain.out"
        _warp_obtain "$TMP/obtain.out" >/dev/null 2>&1 || :
        [ ! -e "$TMP/obtain.out" ]
    )
    check 'fetch: empty response is a failure and writes no outfile' fetch_empty_response

    fetch_first_source_ok() (
        warp-reg() { cat "$FX/reg-ok.json"; }
        wgcf-cli() { return 1; }
        _http_download() { return 1; }
        rm -f "$TMP/obtain-ok.out"
        _warp_obtain "$TMP/obtain-ok.out" >/dev/null 2>&1 || return 1
        [ -s "$TMP/obtain-ok.out" ] || return 1
        cat "$TMP/obtain-ok.out" | _warp_build_outbound > "$TMP/obtain-ok.outbound" 2>/dev/null || return 1
        jq -e '(.tag == "warp") and (.protocol == "wireguard") and ((.settings.peers | length) == 1)' \
            "$TMP/obtain-ok.outbound" >/dev/null 2>&1
    )
    check 'fetch: first source succeeding makes _warp_obtain rc=0 with a buildable outfile' fetch_first_source_ok

    # -----------------------------------------------------------------------
    # C. 分流规则(本次修复的回归重点)
    # -----------------------------------------------------------------------
    printf '== C. routing rules ==\n'

    # 1) 默认规则里已有 ip=geoip:cn(block); WARP 规则仍必须真的写进去(旧实现静默返回 0 且不写)。
    base_cfg | cfg_reset || exit 1
    check 'add rule ip geoip:cn returns 0 although geoip:cn is already a block rule' _warp_add_rule ip 'geoip:cn'
    check 'add rule ip geoip:cn actually writes {ip:[geoip:cn],outboundTag:warp}' qe '
        [.routing.rules[]? | select((.outboundTag? // "") == "warp" and (.ip? == ["geoip:cn"]))] | length == 1'
    check 'add rule ip geoip:cn keeps the original block rule untouched' qe '
        [.routing.rules[]? | select((.outboundTag? // "") == "block" and ((.ip? // []) | index("geoip:cn")) != null)] | length == 1'

    # 2) 默认规则里 github.com 已在直连白名单, WARP 规则同样必须新增。
    base_cfg | cfg_reset || exit 1
    check 'add rule domain github.com returns 0 although github.com is already a direct rule' _warp_add_rule domain 'github.com'
    check 'add rule domain github.com actually writes {domain:[github.com],outboundTag:warp}' qe '
        [.routing.rules[]? | select((.outboundTag? // "") == "warp" and (.domain? == ["github.com"]))] | length == 1'

    # 3) 同一值第二次必须 rc=0 且完全不写配置(WARP 规则内部仍要去重)。
    base_cfg | cfg_reset || exit 1
    _warp_add_rule domain 'example.com' >/dev/null 2>&1
    cfg_snapshot "$TMP/c3-before.cfg"
    check 'add rule: duplicate value still returns 0' _warp_add_rule domain 'example.com'
    cfg_snapshot "$TMP/c3-after.cfg"
    check 'add rule: duplicate value leaves config bytes untouched (cmp)' cmp -s "$TMP/c3-before.cfg" "$TMP/c3-after.cfg"
    check 'add rule: duplicate value does not add a second rule' qe '
        [.routing.rules[]? | select((.outboundTag? // "") == "warp" and (.domain? == ["example.com"]))] | length == 1'

    # 4) 插入位置: 私网防护规则(ruleTag)之后、首条普通规则之前; 连续新增的 WARP 规则相邻。
    cfg_reset <<'JSON' || exit 1
{
  "inbounds": [{"tag": "xd-vless-443", "protocol": "vless", "port": 443}],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
  "routing": {"rules": [
    {"inboundTag": ["xd-vless-443"], "outboundTag": "direct"},
    {"ip": ["geoip:private"], "outboundTag": "block", "ruleTag": "xd-block-private"},
    {"domain": ["example.org"], "outboundTag": "block"}
  ]}
}
JSON
    _warp_add_rule ip 'geoip:cn' >/dev/null 2>&1
    check 'insert: warp rule lands right after the private block rule' eq 'block|xd-block-private' "$(_config_jq -r '.routing.rules[1] | [.outboundTag, .ruleTag] | join("|")')"
    check 'insert: warp rule lands before the first ordinary rule' eq 'warp|example.org' "$(_config_jq -r '.routing.rules[2].outboundTag + "|" + (.routing.rules[3].domain[0] // "")')"
    _warp_add_rule domain 'example.net' >/dev/null 2>&1
    check 'insert: consecutive warp rules stay adjacent' eq 'warp|warp|block' "$(_config_jq -r '[.routing.rules[2], .routing.rules[3], .routing.rules[4]] | map(.outboundTag) | join("|")')"
    check 'insert: the second warp rule carries the new domain' eq 'example.net' "$(_config_jq -r '.routing.rules[3].domain[0]')"

    # 5) 列表序号与删除序号同口径: 只有 outboundTag=warp、没有 domain/ip 的裸规则不计入。
    cfg_reset <<'JSON' || exit 1
{
  "inbounds": [{"tag": "xd-vless-443", "protocol": "vless", "port": 443}],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
  "routing": {"rules": [
    {"outboundTag": "warp"},
    {"domain": ["example.com"], "outboundTag": "warp"},
    {"ip": ["geoip:cn"], "outboundTag": "warp"},
    {"domain": ["example.org"], "outboundTag": "block"}
  ]}
}
JSON
    check 'list: a bare outboundTag=warp rule without domain/ip is not listed' eq 2 "$(_warp_rules_list | wc -l | tr -d ' ')"
    check 'list: first listed rule is the first rule carrying domain/ip' eq '1|domain|example.com' "$(_warp_rules_list | sed -n '1p' | tr '\t' '|')"
    check 'delete rule 1: returns 0' _warp_delete_rule 1
    check 'delete rule 1: deletes the first listed rule, not the bare warp rule' qe '
        (.routing.rules | length) == 3
        and (.routing.rules[0] == {"outboundTag": "warp"})
        and (.routing.rules[1].ip == ["geoip:cn"])
        and (.routing.rules[2].domain == ["example.org"])'

    # -----------------------------------------------------------------------
    # D. 出站生命周期
    # -----------------------------------------------------------------------
    printf '== D. outbound lifecycle ==\n'
    base_cfg | cfg_reset || exit 1
    check 'apply: writes the warp outbound after the existing ones' _warp_apply "$(norm_a)"
    check 'apply: outbound order is direct, block, warp' eq 'direct|block|warp' "$(_config_jq -r '.outbounds | map(.tag) | join("|")')"
    check 'apply: warp outbound is a wireguard outbound with noKernelTun' qe '
        (.outbounds[2].tag == "warp") and (.outbounds[2].protocol == "wireguard")
        and (.outbounds[2].settings.noKernelTun == true) and ((.outbounds[2].settings.peers | length) == 1)'
    check 'apply: re-apply replaces the outbound in place' _warp_apply "$(norm_b)"
    check 'apply: re-apply does not append a duplicate' eq 'direct|block|warp' "$(_config_jq -r '.outbounds | map(.tag) | join("|")')"
    check 'apply: re-apply writes the new secret at the same position' eq 'c2VjcmV0LWI=' "$(_config_jq -r '.outbounds[2].settings.secretKey')"

    check 'set endpoint: returns 0' _warp_set_endpoint '162.159.192.9:2408'
    check 'set endpoint: peers[0].endpoint is replaced' eq '162.159.192.9:2408' "$(_config_jq -r '.outbounds[2].settings.peers[0].endpoint')"
    check 'set endpoint: publicKey and allowedIPs are untouched' eq 'cHVibGljLWtleS1i|0.0.0.0/0,::/0' "$(_config_jq -r '.outbounds[2].settings.peers[0] | [.publicKey, (.allowedIPs | join(","))] | join("|")')"
    check 'set endpoint: other outbounds keep their order' eq 'direct|block' "$(_config_jq -r '.outbounds[0:2] | map(.tag) | join("|")')"
    endpoint_rejects() (
        _warp_set_endpoint 'not a valid endpoint!' >/dev/null 2>&1
        [ "$?" -eq 1 ]
    )
    check 'set endpoint: an invalid endpoint is rejected with rc=1' endpoint_rejects

    cfg_reset <<'JSON' || exit 1
{
  "inbounds": [{"tag": "xd-vless-443", "protocol": "vless", "port": 443}],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "warp", "protocol": "wireguard", "settings": {
      "secretKey": "s", "address": ["172.16.0.2/32"], "reserved": [0, 0, 0],
      "peers": [{"publicKey": "p", "endpoint": "162.159.192.1:2408", "allowedIPs": ["0.0.0.0/0", "::/0"]}],
      "mtu": 1280, "noKernelTun": true}},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"rules": [
    {"domain": ["keep.example"], "outboundTag": "direct"},
    {"domain": ["warp.example"], "outboundTag": "warp"},
    {"ip": ["geoip:cn"], "outboundTag": "warp"},
    {"domain": ["example.org"], "outboundTag": "block"}
  ]}
}
JSON
    check 'delete: returns 0' _warp_delete
    check 'delete: removes the warp outbound in the same change' eq 'direct|block' "$(_config_jq -r '.outbounds | map(.tag) | join("|")')"
    check 'delete: removes every outboundTag=warp rule' qe '
        [.routing.rules[]? | select((.outboundTag? // "") == "warp")] | length == 0'
    check 'delete: remaining rules are exactly the non-warp ones' eq '[{"domain":["keep.example"],"outboundTag":"direct"},{"domain":["example.org"],"outboundTag":"block"}]' "$(_config_jq -c '.routing.rules')"

    state_summary_no_warp() (
        base_cfg | cfg_reset || return 1
        local out
        out=$(_warp_state_summary) || return 1
        case "$out" in 0*) return 0 ;; *) return 1 ;; esac
    )
    check 'state summary: no warp outbound reports a line starting with 0 and rc=0' state_summary_no_warp

    state_summary_with_warp() (
        base_cfg | cfg_reset || return 1
        _warp_apply "$(norm_a)" >/dev/null 2>&1 || return 1
        _warp_add_rule domain 'warp.example' >/dev/null 2>&1 || return 1
        local out present endpoint addresses mtu rules
        out=$(_warp_state_summary) || return 1
        IFS=$'\t' read -r present endpoint addresses mtu rules <<< "$out" || return 1
        [ "$present" = 1 ] \
            && [ "$endpoint" = "162.159.192.1:2408" ] \
            && [ "$addresses" = "172.16.0.2/32,2606:4700:110:8a36::2/128" ] \
            && [ "$mtu" = 1280 ] && [ "$rules" = 1 ]
    )
    check 'state summary: present/endpoint/addresses/mtu/ruleCount fields are exact' state_summary_with_warp

    state_summary_no_secret() (
        base_cfg | cfg_reset || return 1
        _warp_apply "$(norm_a)" >/dev/null 2>&1 || return 1
        local out
        out=$(_warp_state_summary) || return 1
        case "$out" in *c2VjcmV0LWE=*|*secretKey*) return 1 ;; esac
        return 0
    )
    check 'state summary: never prints the secret key' state_summary_no_secret

    state_summary_unparsable() (
        CONFIG_DIR="$TMP/badcfg"
        mkdir -p "$CONFIG_DIR" || return 1
        printf '{"routing": \n' > "$CONFIG_DIR/99_routing.json"
        _warp_state_summary >/dev/null 2>&1
        [ "$?" -eq 1 ]
    )
    check 'state summary: unparsable config returns 1' state_summary_unparsable

    outbound_absent() (
        base_cfg | cfg_reset || return 1
        _warp_outbound_json >/dev/null 2>&1
        [ "$?" -eq 1 ]
    )
    check 'outbound json: missing warp outbound returns 1' outbound_absent

    # -----------------------------------------------------------------------
    # E. 静态约束
    # -----------------------------------------------------------------------
    printf '== E. static constraints ==\n'
    no_direct_conf_write() {
        ! grep -Eq '(_config_write_merged|_atomic_write_json)' "$ROOT/lib/35-warp.sh" &&
        ! grep -Eq '>>?[[:space:]]*"\$CONFIG_DIR' "$ROOT/lib/35-warp.sh"
    }
    check 'static: lib/35-warp.sh never writes confs directly' no_direct_conf_write
    check 'static: lib/35-warp.sh writes config only through _mutate_config' grep -q '_mutate_config' "$ROOT/lib/35-warp.sh"

    # 按函数名截取源码(定义行到列首的 }), 只看输出路径, 不含归一/生成里的字段名。
    src_func() {
        awk -v fn="$1" 'index($0, fn "()") == 1 { p = 1 } p { print } p && $0 == "}" { exit }' "$ROOT/lib/35-warp.sh"
    }
    no_secret_in_output_path() {
        local fn
        for fn in _warp_state_summary _warp_rules_list _warp_menu _warp_delete_prompt _warp_set_endpoint_prompt; do
            src_func "$fn" | grep -q 'secretKey' && return 1
        done
        return 0
    }
    check 'static: menu/status output paths never reference secretKey' no_secret_in_output_path

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
