#!/usr/bin/env bash
# lib/35-warp.sh 的离线回归: 归一/生成、获取失败不落盘、分流规则与出站生命周期。
# 全部断言不联网、不启服务: 配置只写进 mktemp 目录, 写入统一由真实 jq 落盘的 _mutate_config 桩完成。
# shellcheck disable=SC2329,SC2034,SC2030,SC2031
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
        content=$(jq -c '. + {version:{min:"26.4.25",max:""}}') || return 1
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

    # 注册 API 的实际响应在 wireguard 前还有 direct/block 出站, 不能只看 outbounds[0]。
    cat > "$FX/api-index2.json" <<'JSON'
{"outbounds": [{"tag": "direct", "protocol": "freedom"},
               {"tag": "block", "protocol": "blackhole", "settings": {}},
               {"tag": "wireguard", "protocol": "wireguard", "settings": {
  "secretKey": "c2VjcmV0LWFwaS0y", "address": ["172.16.0.9/32"], "reserved": [1, 2, 3],
  "peers": [{"publicKey": "cHVibGljLWFwaS0y", "endpoint": "162.159.192.9:2408",
              "allowedIPs": ["0.0.0.0/0", "::/0"]}], "mtu": 1280}}]}
JSON
    # reserved 按官方文档是可选项(长度 3, 默认全 0): 省略时必须补 [0,0,0] 而不是判失败。
    cat > "$FX/reg-no-reserved.json" <<'JSON'
{"private_key": "a2V5LXJlZw==", "public_key": "cHViLXJlZw==",
 "endpoint": {"v4": "162.159.192.7:0"}, "v4": "172.16.0.7"}
JSON
    # 纯 IPv6 注册: 只有一个端点和地址, 端点同样统一走域名。
    cat > "$FX/reg-v6-only.json" <<'JSON'
{"private_key": "a2V5LXY2", "public_key": "cHViLXY2",
 "endpoint": {"v6": "[2606:4700:110:8a36::7]:0"}, "v6": "2606:4700:110:8a36::8"}
JSON
    cat > "$FX/api-no-reserved.json" <<'JSON'
{"outbounds": [{"tag": "warp", "protocol": "wireguard", "settings": {
  "secretKey": "c2VjcmV0LW5vcnN2", "address": ["172.16.0.8/32"],
  "peers": [{"publicKey": "cHVibGljLW5vcnN2", "endpoint": "162.159.192.8:2408"}]}}]}
JSON
    # 每种来源保留一个格式错误代表: 非法 JSON、缺字段。
    printf '{"private_key": ' > "$FX/reg-bad-json.json"
    printf '{"outbounds": [{"settings": {"secretKey": "k"}}]}\n' > "$FX/out-bad-missing.json"

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
    check 'normalize reg: dual-stack endpoint uses Cloudflare domain' eq 'engage.cloudflareclient.com:2408' "$(jq -r .endpoint "$TMP/n-reg.json")"
    check 'normalize reg: v4/v6 addresses get /32 and /128' eq '172.16.0.2/32,2606:4700:110:8a36::2/128' "$(jq -r '.address | join(",")' "$TMP/n-reg.json")"
    check 'normalize reg: reserved_dec passes through' eq '[12,34,56]' "$(jq -c .reserved "$TMP/n-reg.json")"

    check 'normalize wgcf: valid registration fixture yields 7 masked fields' norm_ok _warp_normalize_wgcf "$FX/wgcf-reg.json" "$TMP/n-wgcf.json"
    check 'normalize wgcf: addresses.v4/v6 are mapped and masked' eq '172.16.0.3/32,2606:4700:110:8a36::4/128' "$(jq -r '.address | join(",")' "$TMP/n-wgcf.json")"
    check 'normalize wgcf: dual-stack endpoint uses Cloudflare domain' eq 'engage.cloudflareclient.com:2408' "$(jq -r .endpoint "$TMP/n-wgcf.json")"

    check 'normalize wgcf: generate --xray outbound fixture yields 7 masked fields' norm_ok _warp_normalize_wgcf "$FX/wgcf-xray.json" "$TMP/n-wgcfx.json"
    check 'normalize wgcf: outbound address without mask gains /32' eq '172.16.0.5/32' "$(jq -r '.address | join(",")' "$TMP/n-wgcfx.json")"

    check 'normalize api: outbound fixture yields 7 masked fields' norm_ok _warp_normalize_api "$FX/api.json" "$TMP/n-api.json"
    check 'normalize api: missing allowedIPs defaults to 0.0.0.0/0 and ::/0' eq '["0.0.0.0/0","::/0"]' "$(jq -c .allowedIPs "$TMP/n-api.json")"
    check 'normalize api: missing mtu defaults to 1280' eq '1280' "$(jq -r .mtu "$TMP/n-api.json")"
    check 'normalize api: wireguard outbound after direct/block is found' norm_ok _warp_normalize_api "$FX/api-index2.json" "$TMP/n-api-index2.json"
    check 'normalize api: indexed wireguard settings are used' eq '172.16.0.9/32' "$(jq -r '.address | join(",")' "$TMP/n-api-index2.json")"
    check 'normalize api: outbound without reserved still normalizes' norm_ok _warp_normalize_api "$FX/api-no-reserved.json" "$TMP/n-api-norsv.json"
    check 'normalize reg: registration without reserved_dec still normalizes' norm_ok _warp_normalize_reg "$FX/reg-no-reserved.json" "$TMP/n-reg-norsv.json"
    check 'normalize api: missing reserved defaults to three zero bytes' eq '[0,0,0]' "$(jq -c .reserved "$TMP/n-api-norsv.json")"
    check 'normalize reg: missing reserved_dec defaults to three zero bytes' eq '[0,0,0]' "$(jq -c .reserved "$TMP/n-reg-norsv.json")"
    check 'normalize reg: single-stack v4 endpoint uses Cloudflare domain' eq 'engage.cloudflareclient.com:2408' "$(jq -r .endpoint "$TMP/n-reg-norsv.json")"
    check 'normalize reg: single-stack v6 fixture yields 7 masked fields' norm_ok _warp_normalize_reg "$FX/reg-v6-only.json" "$TMP/n-reg-v6.json"
    check 'normalize reg: single-stack v6 endpoint uses Cloudflare domain' eq 'engage.cloudflareclient.com:2408' "$(jq -r .endpoint "$TMP/n-reg-v6.json")"

    check 'normalize reg rejects malformed JSON with rc=1 and empty stdout' norm_bad _warp_normalize_reg "$FX/reg-bad-json.json"
    check 'normalize api rejects missing fields with rc=1 and empty stdout' norm_bad _warp_normalize_api "$FX/out-bad-missing.json"
    check 'normalize wgcf rejects invalid outbound with rc=1 and empty stdout' norm_bad _warp_normalize_wgcf "$FX/out-bad-missing.json"

    printf '== A. endpoint normalization ==\n'
    check 'endpoint: bare host gains default port' eq 'engage.cloudflareclient.com:2408' "$(_warp_endpoint_norm 'engage.cloudflareclient.com')"
    check 'endpoint: bare IPv6 is bracketed and gains a port' eq '[2606:4700:110:8a36::1]:2408' "$(_warp_endpoint_norm '2606:4700:110:8a36::1')"
    check 'endpoint: host:port is preserved verbatim' eq '162.159.192.1:500' "$(_warp_endpoint_norm '162.159.192.1:500')"
    endpoint_rejects() {
        ! _warp_endpoint_norm '1.2.3.4:abc' >/dev/null 2>&1 &&
            ! _warp_endpoint_norm '162.159.192.1:' >/dev/null 2>&1 &&
            ! _warp_endpoint_norm 'a:b:c' >/dev/null 2>&1
    }
    check 'endpoint: non-IPv6 colon forms are rejected' endpoint_rejects

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
    check 'build: api normalize output becomes a single warp wireguard outbound' build_ok "$TMP/n-api.json"
    check 'build: peers keep publicKey/endpoint/allowedIPs from normalize' eq 'cHVibGljLWFwaQ==|162.159.192.6:2408|0.0.0.0/0,::/0' "$(jq -r '.settings.peers[0] | [.publicKey, .endpoint, (.allowedIPs | join(","))] | join("|")' "$TMP/outbound.json")"
    check 'build: default mtu 1280 is carried into settings' eq '1280' "$(jq -r '.settings.mtu' "$TMP/outbound.json")"

    build_domain_strategy() (
        _warp_domain_strategy() { printf 'UseIPv6'; }
        cat "$TMP/n-api.json" | _warp_build_outbound > "$TMP/outbound-ds.json" 2>/dev/null || return 1
        jq -e '.streamSettings.sockopt.domainStrategy == "UseIPv6"' "$TMP/outbound-ds.json" >/dev/null 2>&1
    )
    check 'build: WARP outbound carries endpoint domain strategy' build_domain_strategy

    domain_strategy_ipv6_only() (
        command() {
            case "${1:-} ${2:-}" in
                "-v ip") return 0 ;;
            esac
            builtin command "$@"
        }
        ip() {
            case "$*" in
                "route show default") return 0 ;;
                "-6 route show default") printf 'default via fe80::1 dev eth0\n' ;;
            esac
        }
        [ "$(_warp_domain_strategy)" = "UseIPv6" ]
    )
    check 'domain strategy: IPv6-only host uses UseIPv6' domain_strategy_ipv6_only

    domain_strategy_dual_stack() (
        command() {
            case "${1:-} ${2:-}" in
                "-v ip") return 0 ;;
            esac
            builtin command "$@"
        }
        ip() {
            case "$*" in
                "route show default") printf 'default via 192.0.2.1 dev eth0\n' ;;
                "-6 route show default") printf 'default via fe80::1 dev eth0\n' ;;
            esac
        }
        [ "$(_warp_domain_strategy)" = "UseIPv4" ]
    )
    check 'domain strategy: dual-stack host uses UseIPv4' domain_strategy_dual_stack

    # -----------------------------------------------------------------------
    # B. 获取失败不污染输出
    # -----------------------------------------------------------------------
    printf '== B. fetch failure does not write output ==\n'
    mkdir -p "$TMP/fakebin" || exit 1
    cat > "$TMP/fakebin/curl" <<'SH'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w) shift 2 ;;
        --*) shift ;;
        *) shift ;;
    esac
done
[ -n "$out" ] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
exit "${FAKE_RC:-0}"
SH
    chmod +x "$TMP/fakebin/curl" || exit 1

    http_curl_2xx() (
        PATH="$TMP/fakebin:$PATH"
        export FAKE_BODY='{"ok":true}' FAKE_CODE=200 FAKE_RC=0
        _warp_http_get 'https://example.test/x' "$TMP/http-200.out" 5 || return 1
        [ "$_WARP_HTTP_CODE" = 200 ] && [ "$(cat "$TMP/http-200.out")" = '{"ok":true}' ]
    )
    check 'http: curl 2xx writes body and status' http_curl_2xx

    http_curl_403() (
        PATH="$TMP/fakebin:$PATH"
        export FAKE_BODY='{"error":"denied"}' FAKE_CODE=403 FAKE_RC=0
        ! _warp_http_get 'https://example.test/x' "$TMP/http-403.out" 5 || return 1
        [ "$_WARP_HTTP_CODE" = 403 ] || return 1
        [ "$(_warp_http_reason "$TMP/http-403.out")" = 'HTTP 403: denied' ]
    )
    check 'http: curl 4xx keeps status and reason' http_curl_403

    http_curl_empty() (
        PATH="$TMP/fakebin:$PATH"
        export FAKE_BODY='' FAKE_CODE=200 FAKE_RC=0
        ! _warp_http_get 'https://example.test/x' "$TMP/http-empty.out" 5
    )
    check 'http: empty 2xx body is rejected' http_curl_empty

    http_curl_fail() (
        PATH="$TMP/fakebin:$PATH"
        export FAKE_BODY='' FAKE_CODE=000 FAKE_RC=1
        ! _warp_http_get 'https://example.test/x' "$TMP/http-fail.out" 5 || return 1
        [ "$_WARP_HTTP_CODE" = 000 ]
    )
    check 'http: curl failure keeps 000 status' http_curl_fail

    http_wget_ok() (
        command() {
            case "${1:-} ${2:-}" in
                "-v curl") return 1 ;;
                "-v wget") return 0 ;;
            esac
            builtin command "$@"
        }
        wget() {
            local out=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -O) out="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            printf '%s' '{"ok":true}' > "$out"
        }
        _warp_http_get 'https://example.test/x' "$TMP/http-wget.out" 5 || return 1
        [ "$_WARP_HTTP_CODE" = 000 ] && [ "$(cat "$TMP/http-wget.out")" = '{"ok":true}' ]
    )
    check 'http: wget fallback writes body' http_wget_ok

    run_timeout_external() (
        command() {
            case "${1:-} ${2:-}" in
                "-v timeout") return 0 ;;
            esac
            builtin command "$@"
        }
        timeout() {
            printf '%s|%s\n' "$1" "$2" > "$TMP/timeout.args"
            shift
            "$@"
        }
        _warp_run 30 sh -c 'exit 0' || return 1
        [ "$(cat "$TMP/timeout.args")" = "30|sh" ]
    )
    check 'run: external command is wrapped by timeout' run_timeout_external

    fetch_all_fail() (
        # 隐藏主机上可能存在的 warp-reg / wgcf-cli, 让三种来源都落到"取不到"的分支。
        command() {
            case "${1:-} ${2:-}" in
                "-v warp-reg"|"-v warp-reg.sh"|"-v wgcf-cli") return 1 ;;
            esac
            builtin command "$@"
        }
        _warp_http_get() { return 1; }
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

    fetch_first_source_ok() (
        warp-reg() { cat "$FX/reg-ok.json"; }
        wgcf-cli() { return 1; }
        _warp_http_get() { return 1; }
        rm -f "$TMP/obtain-ok.out"
        _warp_obtain "$TMP/obtain-ok.out" >/dev/null 2>&1 || return 1
        [ -s "$TMP/obtain-ok.out" ] || return 1
        cat "$TMP/obtain-ok.out" | _warp_build_outbound > "$TMP/obtain-ok.outbound" 2>/dev/null || return 1
        jq -e '(.tag == "warp") and (.protocol == "wireguard") and ((.settings.peers | length) == 1)' \
            "$TMP/obtain-ok.outbound" >/dev/null 2>&1
    )
    check 'fetch: first source succeeding makes _warp_obtain rc=0 with a buildable outfile' fetch_first_source_ok

    fetch_local_fail_remote_ok() (
        command() {
            case "${1:-} ${2:-}" in
                "-v apk") return 1 ;;
            esac
            builtin command "$@"
        }
        warp-reg() { return 1; }
        _warp_http_get() {
            printf '%s\n' "$1" > "$TMP/warp-reg-url"
            printf '#!/bin/sh\necho "WARN: installing"\ncat "%s"\n' "$FX/reg-ok.json" > "$2"
            _WARP_HTTP_CODE=200
        }
        rm -f "$TMP/warp-reg.out" "$TMP/warp-reg-url"
        _warp_fetch_warp_reg "$TMP/warp-reg.out" || return 1
        [ -s "$TMP/warp-reg.out" ] || return 1
        [ "$(cat "$TMP/warp-reg-url")" = "https://raw.githubusercontent.com/chise0713/warp-reg.sh/master/warp-reg.sh" ] || return 1
        jq -e '.endpoint.v4 == "162.159.192.1:0"' "$TMP/warp-reg.out" >/dev/null 2>&1
    )
    check 'fetch: local warp-reg failure falls back to GitHub script' fetch_local_fail_remote_ok

    fetch_alpine_skips_remote() (
        command() {
            case "${1:-} ${2:-}" in
                "-v warp-reg"|"-v warp-reg.sh") return 1 ;;
                "-v apk") return 0 ;;
            esac
            builtin command "$@"
        }
        _warp_http_get() { return 99; }
        rm -f "$TMP/alpine.out"
        _warp_fetch_warp_reg "$TMP/alpine.out" 2>/dev/null
        [ "$?" -eq 1 ] || return 1
        [ ! -s "$TMP/alpine.out" ] || return 1
        [ "$_WARP_REASON" = "远程 warp-reg.sh 不支持 Alpine apk" ]
    )
    check 'fetch: Alpine skips remote warp-reg.sh without downloading' fetch_alpine_skips_remote

    fetch_wgcf_auto_install() (
        command() {
            case "${1:-} ${2:-}" in
                "-v wgcf-cli") return 1 ;;
            esac
            builtin command "$@"
        }
        uname() {
            case "${1:-}" in
                -m) printf '%s\n' x86_64 ;;
                *) builtin uname "$@" ;;
            esac
        }
        zstd() {
            local prev="" out=""
            for arg in "$@"; do
                [ "$prev" = "-o" ] && out="$arg"
                prev="$arg"
            done
            [ -n "$out" ] && : > "$out"
        }
        tar() {
            local prev="" dir=""
            for arg in "$@"; do
                [ "$prev" = "-C" ] && dir="$arg"
                prev="$arg"
            done
            [ -n "$dir" ] || return 1
            {
                printf '#!/bin/sh\ncase "$1" in\n'
                printf 'register) cat "%s" ;;\n' "$FX/wgcf-reg.json"
                printf '*) exit 1 ;;\nesac\n'
            } > "$dir/wgcf-cli" || return 1
            chmod +x "$dir/wgcf-cli"
        }
        _warp_http_get() {
            printf '%s\n' "$1" > "$TMP/wgcf-url"
            : > "$2"
            _WARP_HTTP_CODE=200
        }
        rm -f "$TMP/wgcf-auto.out" "$TMP/wgcf-url"
        _warp_fetch_wgcf_cli "$TMP/wgcf-auto.out" || return 1
        [ "$(cat "$TMP/wgcf-url")" = "https://github.com/ArchiveNetwork/wgcf-cli/releases/download/v0.3.6/wgcf-cli-linux-64.tar.zstd" ] || return 1
        jq -e '.endpoint.v4 == "162.159.192.2"' "$TMP/wgcf-auto.out" >/dev/null 2>&1
    )
    check 'fetch: missing wgcf-cli downloads GitHub release and registers' fetch_wgcf_auto_install

    fetch_wgcf_generate_stdout() (
        local fake_tool="$TMP/fake-wgcf-stdout"
        {
            printf '#!/bin/sh\n'
            printf 'case "$1" in\n'
            printf '  register) exit 1 ;;\n'
            printf '  generate) cat "%s" ;;\n' "$FX/wgcf-xray.json"
            printf '  *) exit 1 ;;\n'
            printf 'esac\n'
        } > "$fake_tool" || return 1
        chmod +x "$fake_tool" || return 1
        command() {
            case "${1:-} ${2:-}" in
                "-v wgcf-cli") printf '%s\n' "$fake_tool"; return 0 ;;
            esac
            builtin command "$@"
        }
        rm -f "$TMP/wgcf-stdout.out" "$TMP/wgcf-stdout.norm"
        _warp_fetch_wgcf_cli "$TMP/wgcf-stdout.out" || return 1
        _warp_normalize_wgcf "$TMP/wgcf-stdout.out" > "$TMP/wgcf-stdout.norm" || return 1
        jq -e '.endpoint == "162.159.192.5:2408"' "$TMP/wgcf-stdout.norm" >/dev/null 2>&1
    )
    check 'fetch: wgcf-cli generate stdout is captured' fetch_wgcf_generate_stdout

    fetch_wgcf_account_file() (
        local fake_tool="$TMP/fake-wgcf-account"
        {
            printf '#!/bin/sh\n'
            printf 'case "$1" in\n'
            printf '  register) cp "%s" wgcf.json ;;\n' "$FX/wgcf-reg.json"
            printf '  generate) exit 1 ;;\n'
            printf '  *) exit 1 ;;\n'
            printf 'esac\n'
        } > "$fake_tool" || return 1
        chmod +x "$fake_tool" || return 1
        command() {
            case "${1:-} ${2:-}" in
                "-v wgcf-cli") printf '%s\n' "$fake_tool"; return 0 ;;
            esac
            builtin command "$@"
        }
        rm -f "$TMP/wgcf-account.out" "$TMP/wgcf-account.norm"
        _warp_fetch_wgcf_cli "$TMP/wgcf-account.out" || return 1
        _warp_normalize_wgcf "$TMP/wgcf-account.out" > "$TMP/wgcf-account.norm" || return 1
        jq -e '.endpoint == "engage.cloudflareclient.com:2408"' "$TMP/wgcf-account.norm" >/dev/null 2>&1
    )
    check 'fetch: wgcf-cli account file is accepted as fallback' fetch_wgcf_account_file

    fetch_api_http_error() (
        _warp_http_get() {
            printf '%s\n' '{"error":"invalid token"}' > "$2"
            _WARP_HTTP_CODE=403
            return 1
        }
        rm -f "$TMP/api-error.out"
        _warp_fetch_api "$TMP/api-error.out" && return 1
        [ "$_WARP_REASON" = "HTTP 403: invalid token" ]
    )
    check 'fetch: API HTTP error keeps status and error body' fetch_api_http_error

    obtain_reports_reason() (
        _warp_fetch_warp_reg() { _WARP_REASON="reg failed"; return 1; }
        _warp_fetch_wgcf_cli() { _WARP_REASON="wgcf failed"; return 1; }
        _warp_fetch_api() { _WARP_REASON="HTTP 403: denied"; return 1; }
        : > "$TMP/messages"
        rm -f "$TMP/obtain-reason.out"
        _warp_obtain "$TMP/obtain-reason.out" >/dev/null 2>&1 && return 1
        grep -q '注册 API 不可用: HTTP 403: denied' "$TMP/messages"
    )
    check 'obtain: per-source failure reason is reported' obtain_reports_reason

    fetch_reg_local_remote_fail() (
        warp-reg() { return 1; }
        _warp_http_get() { return 1; }
        rm -f "$TMP/reg-fail.out"
        _warp_fetch_warp_reg "$TMP/reg-fail.out" && return 1
        [ "$_WARP_REASON" = "本机 warp-reg 执行失败, 下载 warp-reg 脚本失败" ]
    )
    check 'fetch: local and remote warp-reg failures share one reason' fetch_reg_local_remote_fail

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

    # 4) 追加位置: 新规则一律加到 routing.rules 末尾, 既有规则顺序与语义不变; 连续新增仍相邻。
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
    check 'append: existing rules keep their order' eq 'direct|block|block|warp' "$(_config_jq -r '.routing.rules | map(.outboundTag) | join("|")')"
    check 'append: the warp rule lands at the end' eq 'warp' "$(_config_jq -r '.routing.rules[-1].outboundTag')"
    _warp_add_rule domain 'example.net' >/dev/null 2>&1
    check 'append: consecutive warp rules stay adjacent at the end' eq 'block|warp|warp' "$(_config_jq -r '[.routing.rules[2], .routing.rules[3], .routing.rules[4]] | map(.outboundTag) | join("|")')"

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

    # 6) 全角/半角逗号混用: 值列表在函数入口归一, 两个值按序写入同一规则。
    base_cfg | cfg_reset || exit 1
    check 'add rule accepts mixed full/half-width commas' _warp_add_rule domain 'example.com，example.net'
    check 'add rule mixed commas writes both values in order' qe '
        [.routing.rules[]? | select((.outboundTag? // "") == "warp" and (.domain? == ["example.com","example.net"]))] | length == 1'

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
    # 内核 TUN 模式: 缺省强制关闭(gVisor), 可切到自动检测; 重新注册必须沿用已选模式。
    build_default_nk() { printf '%s' "$1" | _warp_build_outbound | jq -e '.settings.noKernelTun == true' >/dev/null 2>&1; }
    build_false_nk() { printf '%s' "$1" | _warp_build_outbound false | jq -e '.settings.noKernelTun == false' >/dev/null 2>&1; }
    check 'tun: build defaults to noKernelTun=true' build_default_nk "$(norm_a)"
    check 'tun: build accepts noKernelTun=false' build_false_nk "$(norm_a)"
    check 'tun: default mode reports on' eq on "$(_warp_tun_mode)"
    check 'tun: switching to auto returns 0' _warp_set_tun auto
    check 'tun: auto writes noKernelTun=false' qe '.outbounds[] | select(.tag == "warp") | .settings.noKernelTun == false'
    check 'tun: mode reports auto after the switch' eq auto "$(_warp_tun_mode)"
    check 'tun: re-register keeps the chosen mode' _warp_apply "$(norm_b)"
    check 'tun: re-register did not reset auto back to true' qe '.outbounds[] | select(.tag == "warp") | .settings.noKernelTun == false'
    check 'tun: switching back to on returns 0' _warp_set_tun on
    check 'tun: on writes noKernelTun=true' qe '.outbounds[] | select(.tag == "warp") | .settings.noKernelTun == true'
    check 'apply: re-apply writes the new secret at the same position' eq 'c2VjcmV0LWI=' "$(_config_jq -r '.outbounds[2].settings.secretKey')"

    check 'set endpoint: returns 0' _warp_set_endpoint '162.159.192.9:2408'
    check 'set endpoint: peers[0].endpoint is replaced' eq '162.159.192.9:2408' "$(_config_jq -r '.outbounds[2].settings.peers[0].endpoint')"
    check 'set endpoint: publicKey and allowedIPs are untouched' eq 'cHVibGljLWtleS1i|0.0.0.0/0,::/0' "$(_config_jq -r '.outbounds[2].settings.peers[0] | [.publicKey, (.allowedIPs | join(","))] | join("|")')"
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

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
