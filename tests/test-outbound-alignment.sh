#!/usr/bin/env bash
# Offline share-link import contracts; only temporary config fixtures are changed.
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-outbound-alignment.XXXXXX") || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
command -v jq >/dev/null 2>&1 || { printf 'FAIL - jq is required\n' >&2; exit 1; }

# Git Bash 会把传给原生 Windows jq 的 "/" 参数改写成安装路径；仅测试宿主需要隔离。
if command -v cygpath >/dev/null 2>&1; then
    jq() {
        local arg
        local -a args=()
        for arg in "$@"; do
            if [[ "$arg" == /* ]] && [ -f "$arg" ]; then
                args+=("$(cygpath -w "$arg")")
            else
                args+=("$arg")
            fi
        done
        MSYS2_ARG_CONV_EXCL='*' command jq "${args[@]}"
    }
fi

(
    . "$ROOT/lib/00-common.sh"
    DEPLOY_DIR="$TMP/deploy"
    CONFIG_DIR="$DEPLOY_DIR/confs"
    BACKUP_DIR="$DEPLOY_DIR/backups"
    STATE_DIR="$DEPLOY_DIR/state"
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$STATE_DIR"
    . "$ROOT/lib/50-nodes.sh"
    . "$ROOT/lib/52-outbounds.sh"

    _info() { :; }
    _tip() { :; }
    _success() { :; }
    _warn() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _error() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _with_config_lock() { "$@"; }
    _with_config_write_barrier() { "$@"; }
    _txn_allow_config_write() { return 0; }
    _backup_config() { return 0; }
    _restart_xray_verified() { return 0; }

    PASS=0
    FAIL=0
    check() {
        local label="$1"
        shift
        if "$@" >/dev/null 2>&1; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s\n' "$label"
        fi
    }
    eq() { [ "$1" = "$2" ]; }
    hash_file() { sha256sum "$1" | cut -d' ' -f1; }

    write_base_config() {
        _config_write_merged '{
            "version":{"min":"26.4.25","max":""},
            "log":{"loglevel":"warning"},
            "inbounds":[{"tag":"node-a","protocol":"socks","port":1080}],
            "outbounds":[
                {"tag":"direct","protocol":"freedom"},
                {"tag":"block","protocol":"blackhole"},
                {"tag":"warp","protocol":"freedom"}
            ],
            "routing":{
                "domainStrategy":"IPIfNonMatch",
                "rules":[
                    {"type":"field","inboundTag":["node-a"],"outboundTag":"warp"},
                    {"type":"field","network":"tcp,udp","outboundTag":"direct"}
                ]
            }
        }' >/dev/null
    }
    write_base_config || exit 1

    parse_ok() {
        local label="$1" link="$2" filter="$3"
        if ! _outbound_parse_batch "$link"; then
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s (%s)\n' "$label" "$_OB_ERR"
            return 1
        fi
        if ! jq -e "$filter" <<< "$_OB_BATCH" >/dev/null 2>&1; then
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s (JSON assertion)\n' "$label"
            jq -c '.[0].outbound // .[0]' <<< "$_OB_BATCH" 2>/dev/null || true
            return 1
        fi
        PASS=$((PASS + 1))
    }

    parse_fail() {
        local label="$1" link="$2" expected="$3"
        if _outbound_parse_batch "$link" >/dev/null 2>&1; then
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s (unexpected success)\n' "$label"
            return 0
        fi
        case "$_OB_ERR" in
            *"$expected"*) PASS=$((PASS + 1)) ;;
            *)
                FAIL=$((FAIL + 1))
                printf 'FAIL: %s (unexpected error: %s)\n' "$label" "$_OB_ERR"
                ;;
        esac
    }

    UUID=11111111-1111-4111-8111-111111111111
    PBK=$(head -c 32 /dev/zero | base64 | tr -d '=\n' | tr '+/' '-_')
    PQV=$(head -c 1952 /dev/zero | base64 | tr -d '=\n' | tr '+/' '-_')
    PASS_VALUE='p@ss:word'
    PASS_ENC=$(printf '%s' "$PASS_VALUE" | jq -sRr @uri)

    printf '== Reality and transports ==\n'
    link="vless://${UUID}@example.com:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=${PBK}&sid=0123456789abcdef&spx=%2F&pqv=${PQV}#Reality%20Export"
    if _outbound_parse_batch "$link"; then
        check 'Reality full fields' jq -e --arg pqv "$PQV" '
            length == 1 and .[0].tag == "Reality Export"
            and .[0].outbound.settings.address == "example.com"
            and .[0].outbound.settings.flow == "xtls-rprx-vision"
            and .[0].outbound.streamSettings.realitySettings.spiderX == "/"
            and .[0].outbound.streamSettings.realitySettings.mldsa65Verify == $pqv
            and .[0].outbound.streamSettings.realitySettings.fingerprint == "chrome"
            and .[0].outbound.streamSettings.realitySettings.shortId == "0123456789abcdef"
        ' <<< "$_OB_BATCH"
    else
        check 'Reality full fields' false
    fi
    if jq -e --arg pqv "$PQV" '.realitySettings.mldsa65Verify == $pqv' \
        <<< '{"realitySettings":{}}' >/dev/null 2>&1; then
        check 'negative control: pqv assertion rejects omission' false
    else
        check 'negative control: pqv assertion rejects omission' true
    fi

    parse_fail 'Reality WebSocket rejected' \
        "vless://${UUID}@example.com:443?encryption=none&security=reality&type=ws&path=%2Fws&sni=www.example.com&pbk=${PBK}&sid=01#Reality-WS" \
        'Reality 只支持'

    link="vless://${UUID}@example.com:443?encryption=none&security=reality&type=xhttp&mode=auto&path=%2Fapi&host=cdn.example.com&sni=cdn.example.com&fp=chrome&pbk=${PBK}&sid=01#XHTTP-Export"
    parse_ok 'XHTTP transport' "$link" '
        .[0].outbound.streamSettings.network == "xhttp"
        and .[0].outbound.streamSettings.xhttpSettings.path == "/api"
        and .[0].outbound.streamSettings.xhttpSettings.mode == "auto"
        and .[0].outbound.streamSettings.xhttpSettings.host == "cdn.example.com"
    '

    extra='%7B%22xPaddingBytes%22%3A%22100-1000%22%2C%22xPaddingPlacement%22%3A%22query%22%7D'
    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=xhttp&mode=packet-up&path=%2Fapi&host=cdn.example.com&sni=cdn.example.com&extra=${extra}#XHTTP-Extra"
    parse_ok 'XHTTP extra object' "$link" '
        .[0].outbound.streamSettings.xhttpSettings.extra.xPaddingBytes == "100-1000"
        and .[0].outbound.streamSettings.xhttpSettings.extra.xPaddingPlacement == "query"
    '

    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=ws&path=%2Fws&host=cdn.example.com&sni=cdn.example.com&ed=2048#WS-Export"
    parse_ok 'WebSocket ed path' "$link" '
        .[0].outbound.streamSettings.network == "websocket"
        and .[0].outbound.streamSettings.wsSettings.path == "/ws?ed=2048"
        and .[0].outbound.streamSettings.wsSettings.host == "cdn.example.com"
    '

    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=ws&path=%2Fws%3Fed%3D2048&host=cdn.example.com&sni=cdn.example.com&ed=4096#WS-ED-Existing"
    parse_ok 'WebSocket existing ed not duplicated' "$link" '
        .[0].outbound.streamSettings.wsSettings.path == "/ws?ed=2048"
    '

    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=ws&path=%2Fws&host=cdn.example.com&sni=cdn.example.com&ed=2048&earlydataheadername=sec-websocket-protocol#WS-Early-Header"
    parse_ok 'WebSocket earlyDataHeaderName' "$link" '
        .[0].outbound.streamSettings.wsSettings.path == "/ws?ed=2048"
    '

    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=httpupgrade&path=%2Fup&host=cdn.example.com&sni=cdn.example.com#Upgrade-Export"
    parse_ok 'HTTPUpgrade transport' "$link" '
        .[0].outbound.streamSettings.network == "httpupgrade"
        and .[0].outbound.streamSettings.httpupgradeSettings.path == "/up"
        and .[0].outbound.streamSettings.httpupgradeSettings.host == "cdn.example.com"
    '

    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=httpupgrade&path=%2Fup&host=cdn.example.com&sni=cdn.example.com&ed=2048#Upgrade-ED"
    parse_ok 'HTTPUpgrade ed path' "$link" '
        .[0].outbound.streamSettings.httpupgradeSettings.path == "/up?ed=2048"
    '

    link="vless://${UUID}@example.com:443?encryption=none&security=tls&type=grpc&serviceName=mygrpc&mode=multi&authority=grpc.example.com&sni=cdn.example.com#gRPC-Export"
    parse_ok 'gRPC multiMode and authority' "$link" '
        .[0].outbound.streamSettings.network == "grpc"
        and .[0].outbound.streamSettings.grpcSettings.serviceName == "mygrpc"
        and .[0].outbound.streamSettings.grpcSettings.multiMode == true
        and .[0].outbound.streamSettings.grpcSettings.authority == "grpc.example.com"
    '
    parse_fail 'gRPC rejects WS earlyDataHeaderName' \
        "vless://${UUID}@example.com:443?encryption=none&security=tls&type=grpc&serviceName=svc&earlydataheadername=sec-websocket-protocol" \
        '只适用于 WebSocket'
    parse_ok 'IPv6 TLS serverName is bracketed' \
        "vless://${UUID}@[2001:db8::1]:443?encryption=none&security=tls#IPv6-Export" '
        .[0].outbound.settings.address == "2001:db8::1"
        and .[0].outbound.streamSettings.tlsSettings.serverName == "[2001:db8::1]"
    '

    parse_ok 'TLS pinned certificate' \
        "trojan://${PASS_ENC}@example.com:443?security=tls&sni=example.com&pcs=$(printf 'AB%.0s' {1..32})#Pinned" \
        '.[0].outbound.streamSettings.tlsSettings.pinnedPeerCertSha256 == "abababababababababababababababababababababababababababababababab"'
    old_pwd=$PWD
    cd "$TMP" && : > wild.example.com
    parse_ok 'TLS verifyPeerCertByName wildcard preserved' \
        "trojan://${PASS_ENC}@example.com:443?security=tls&sni=example.com&vcn=*.example.com#Wildcard" \
        '.[0].outbound.streamSettings.tlsSettings.verifyPeerCertByName == "*.example.com"'
    cd "$old_pwd" || exit 1
    parse_fail 'allowInsecure without pin rejected' \
        "trojan://${PASS_ENC}@example.com:443?security=tls&sni=example.com&allowInsecure=1" \
        'allowInsecure'
    for alias in short-id spider-x mldsa65-verify; do
        parse_fail "TLS rejects Reality alias ${alias}" \
            "trojan://${PASS_ENC}@example.com:443?security=tls&sni=example.com&${alias}=1" \
            'Reality 参数'
    done
    parse_fail 'Reality pqv length checked' \
        "vless://${UUID}@example.com:443?encryption=none&security=reality&type=tcp&sni=example.com&pbk=${PBK}&pqv=${PQV}AA#bad" \
        'pqv'
    parse_fail 'unknown query rejected' \
        "vless://${UUID}@example.com:443?encryption=none&security=tls&sni=example.com&unknown=1" \
        '暂不支持'
    parse_fail 'XHTTP extra must be object' \
        "vless://${UUID}@example.com:443?encryption=none&security=tls&type=xhttp&sni=example.com&extra=%5B%5D" \
        'extra 必须是 JSON 对象'

    printf '== VMess and legacy protocols ==\n'
    legacy=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy VMess",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"ws",type:"none",host:"cdn.example.com",path:"/vm",
          tls:"tls",sni:"vm.example.com",alpn:"h2,http/1.1",fp:"chrome"}' |
        base64 | tr -d '\n')
    parse_ok 'VMess legacy JSON' "vmess://${legacy}" '
        .[0].tag == "Legacy VMess"
        and .[0].outbound.protocol == "vmess"
        and .[0].outbound.settings.address == "vm.example.com"
        and .[0].outbound.settings.security == "auto"
        and .[0].outbound.streamSettings.network == "websocket"
        and .[0].outbound.streamSettings.wsSettings.path == "/vm"
        and .[0].outbound.streamSettings.tlsSettings.alpn == ["h2","http/1.1"]
    '

    legacy_tls_only=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy TLS",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"ws",type:"none",host:"cdn.example.com",path:"/vm",
          security:"tls",sni:"vm.example.com",fp:"chrome"}' |
        base64 | tr -d '\n')
    parse_ok 'VMess legacy security=tls without tls field' "vmess://${legacy_tls_only}" '
        .[0].outbound.streamSettings.security == "tls"
        and .[0].outbound.streamSettings.tlsSettings.serverName == "vm.example.com"
    '

    legacy_bool_tls=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy bool TLS",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"ws",type:"none",host:"cdn.example.com",path:"/vm",
          tls:true,sni:"vm.example.com"}' |
        base64 | tr -d '\n')
    parse_ok 'VMess legacy boolean tls' "vmess://${legacy_bool_tls}" '
        .[0].outbound.streamSettings.security == "tls"
    '

    legacy_tls_false=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy TLS false",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"ws",type:"none",host:"cdn.example.com",path:"/vm",
          security:"tls",tls:false,sni:"vm.example.com"}' |
        base64 | tr -d '\n')
    parse_fail 'VMess legacy tls=false conflicts with security=tls' "vmess://${legacy_tls_false}" 'tls 与 security 冲突'

    legacy_ed=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy ed",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"ws",type:"none",host:"cdn.example.com",path:"/vm",
          tls:"tls",sni:"vm.example.com",ed:"2048"}' |
        base64 | tr -d '\n')
    parse_ok 'VMess legacy WebSocket ed' "vmess://${legacy_ed}" '
        .[0].outbound.streamSettings.wsSettings.path == "/vm?ed=2048"
    '

    legacy_xhttp=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy XHTTP",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"xhttp",type:"none",host:"cdn.example.com",path:"/xh",
          tls:"tls",sni:"vm.example.com",mode:"auto",
          extra:{xPaddingBytes:"100-1000"}}' |
        base64 | tr -d '\n')
    parse_ok 'VMess legacy XHTTP extra' "vmess://${legacy_xhttp}" '
        .[0].outbound.streamSettings.network == "xhttp"
        and .[0].outbound.streamSettings.xhttpSettings.extra.xPaddingBytes == "100-1000"
    '

    legacy_packet=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy packet",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"tcp",type:"none",tls:"tls",sni:"vm.example.com",packetencoding:"xudp"}' |
        base64 | tr -d '\n')
    parse_fail 'VMess legacy packetencoding rejected' "vmess://${legacy_packet}" 'packetEncoding'

    legacy_ech=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy ech",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"tcp",type:"none",ech:"AEn+DQBF"}' |
        base64 | tr -d '\n')
    parse_fail 'VMess legacy plaintext ECH rejected' "vmess://${legacy_ech}" 'TLS 参数'

    legacy_vcn=$(jq -cn \
        --arg id "$UUID" \
        '{v:"2",ps:"Legacy vcn",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"tcp",type:"none",vcn:"vm.example.com"}' |
        base64 | tr -d '\n')
    parse_fail 'VMess legacy plaintext vcn rejected' "vmess://${legacy_vcn}" 'TLS 参数'

    parse_ok 'VMess standard URL' \
        "vmess://${UUID}@vm.example.com:443?type=grpc&security=tls&scy=auto&serviceName=svc&mode=multi&sni=vm.example.com#VMess-gRPC" \
        '.[0].outbound.settings.security == "auto"
         and .[0].outbound.streamSettings.network == "grpc"
         and .[0].outbound.streamSettings.grpcSettings.serviceName == "svc"
         and .[0].outbound.streamSettings.grpcSettings.multiMode == true'

    vmess_reality="vmess://${UUID}@vm.example.com:443?type=tcp&security=reality&scy=auto&sni=www.example.com&fp=chrome&pbk=${PBK}&sid=01&spx=%2F&pqv=${PQV}#VMess-Reality"
    parse_ok 'VMess Reality full fields' "$vmess_reality" "
        .[0].outbound.settings.security == \"auto\"
        and .[0].outbound.streamSettings.security == \"reality\"
        and .[0].outbound.streamSettings.realitySettings.publicKey == \"$PBK\"
        and .[0].outbound.streamSettings.realitySettings.spiderX == \"/\"
        and (.[0].outbound.streamSettings.realitySettings.mldsa65Verify | length) == 2603
    "
    parse_fail 'VMess Reality WebSocket rejected' \
        "vmess://${UUID}@vm.example.com:443?type=ws&path=%2Fws&security=reality&scy=auto&sni=www.example.com&pbk=${PBK}" \
        'Reality 只支持'

    legacy_reality=$(jq -cn \
        --arg id "$UUID" --arg pbk "$PBK" --arg pqv "$PQV" \
        '{v:"2",ps:"Legacy Reality",add:"vm.example.com",port:"443",id:$id,aid:"0",
          scy:"auto",net:"tcp",type:"none",tls:"reality",sni:"www.example.com",fp:"chrome",
          publicKey:$pbk,shortId:"01",spiderX:"/",mldsa65Verify:$pqv}' |
        base64 | tr -d '\n')
    parse_ok 'VMess legacy Reality aliases' "vmess://${legacy_reality}" "
        .[0].outbound.streamSettings.security == \"reality\"
        and .[0].outbound.streamSettings.realitySettings.publicKey == \"$PBK\"
        and (.[0].outbound.streamSettings.realitySettings.mldsa65Verify | length) == 2603
    "

    ss_cred=$(printf 'aes-128-gcm:%s' "$PASS_VALUE" | base64 | tr -d '=\n')
    parse_ok 'Shadowsocks SIP002' "ss://${ss_cred}@ss.example.com:8388#SS-Export" '
        .[0].outbound.protocol == "shadowsocks"
        and .[0].outbound.settings.method == "aes-128-gcm"
        and .[0].outbound.settings.password == "p@ss:word"
    '
    ss_legacy=$(printf 'chacha20-poly1305:%s@legacy.example.com:8389' "$PASS_VALUE" | base64 | tr -d '=\n')
    parse_ok 'Shadowsocks legacy Base64' "ss://${ss_legacy}#SS-Legacy" '
        .[0].outbound.settings.method == "chacha20-poly1305"
        and .[0].outbound.settings.address == "legacy.example.com"
    '
    parse_fail 'Shadowsocks 2022 key length checked' \
        'ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206c2hvcnQ=@ss.example.com:8388#bad' \
        '2022'

    parse_ok 'SOCKS user/password' "socks5://user:${PASS_ENC}@socks.example.com:1080#SOCKS-Export" '
        .[0].outbound.protocol == "socks"
        and .[0].outbound.settings.user == "user"
        and .[0].outbound.settings.pass == "p@ss:word"
    '
    parse_ok 'Trojan password and SNI' "trojan://${PASS_ENC}@trojan.example.com:443?sni=trojan.example.com#Trojan-Export" '
        .[0].outbound.protocol == "trojan"
        and .[0].outbound.settings.password == "p@ss:word"
        and .[0].outbound.streamSettings.tlsSettings.serverName == "trojan.example.com"
    '
    trojan_reality="trojan://${PASS_ENC}@trojan.example.com:443?security=reality&type=tcp&sni=www.example.com&fp=chrome&pbk=${PBK}&sid=01&spx=%2F&pqv=${PQV}#Trojan-Reality"
    parse_ok 'Trojan Reality full fields' "$trojan_reality" "
        .[0].outbound.protocol == \"trojan\"
        and .[0].outbound.streamSettings.security == \"reality\"
        and .[0].outbound.streamSettings.realitySettings.publicKey == \"$PBK\"
        and .[0].outbound.streamSettings.realitySettings.spiderX == \"/\"
        and (.[0].outbound.streamSettings.realitySettings.mldsa65Verify | length) == 2603
    "
    parse_fail 'Trojan Reality WebSocket rejected' \
        "trojan://${PASS_ENC}@trojan.example.com:443?security=reality&type=ws&path=%2Fws&sni=www.example.com&pbk=${PBK}" \
        'Reality 只支持'

    printf '== Hysteria2 FinalMask ==\n'
    parse_ok 'Hysteria2 obfs/hop/brutal' \
        "hysteria2://$(printf '%s' "$PASS_VALUE" | jq -sRr @uri)@hy.example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=secret&mport=10000-10010&up=100&down=200#Hy2-Export" '
        .[0].outbound.protocol == "hysteria"
        and .[0].outbound.settings.version == 2
        and .[0].outbound.settings.address == "hy.example.com"
        and .[0].outbound.streamSettings.hysteriaSettings.auth == "p@ss:word"
        and .[0].outbound.streamSettings.hysteriaSettings.version == 2
        and .[0].outbound.streamSettings.finalmask.udp[0] == {type:"udphop",settings:{mode:"perconnremote",remotePorts:"10000-10010"}}
        and .[0].outbound.streamSettings.finalmask.udp[1] == {type:"salamander",settings:{password:"secret"}}
        and .[0].outbound.streamSettings.finalmask.quicParams == {congestion:"brutal",brutalUp:"100 mbps",brutalDown:"200 mbps"}
    '
    parse_ok 'Hysteria2 gecko packetSize' \
        "hy2://pass@hy.example.com?sni=hy.example.com&obfs=gecko&obfs-password=secret&minPacketSize=600&maxPacketSize=1400#Hy2-Gecko" '
        .[0].outbound.streamSettings.finalmask.udp[0].type == "salamander"
        and .[0].outbound.streamSettings.finalmask.udp[0].settings.packetSize == "600-1400"
    '
    parse_ok 'Hysteria2 fractional brutal rate' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&up=0.5&down=0.5#Hy2-Half-Mbps' '
        .[0].outbound.streamSettings.finalmask.quicParams == {congestion:"brutal",brutalUp:"0.5 mbps",brutalDown:"0.5 mbps"}
    '
    parse_ok 'Hysteria2 one-way unlimited brutal' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&up=100&down=0#Hy2-One-Way' '
        .[0].outbound.streamSettings.finalmask.quicParams.congestion == "brutal"
        and .[0].outbound.streamSettings.finalmask.quicParams.brutalUp == "100 mbps"
        and (.[0].outbound.streamSettings.finalmask.quicParams | has("brutalDown") | not)
    '
    parse_fail 'Hysteria2 brutal below 512 kbps rejected' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&up=0.4&down=100' \
        '至少 512 kbps'
    parse_fail 'Hysteria2 half bandwidth rejected' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&up=100' \
        '必须同时提供'
    parse_fail 'Hysteria2 fp rejected' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&fp=chrome' \
        '不支持 fp'
    parse_fail 'Hysteria2 mport range checked' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&mport=0-10' \
        'mport 端口'
    parse_ok 'Hysteria2 certificate pin' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&pinSHA256=ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB#Hy2-Pin' \
        '.[0].outbound.streamSettings.tlsSettings.pinnedPeerCertSha256 == "abababababababababababababababababababababababababababababababab"'
    parse_ok 'Hysteria2 udpIdleTimeout zero uses core default' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&udpIdleTimeout=0#Hy2-Idle-Default' \
        '.[0].outbound.streamSettings.hysteriaSettings.version == 2
         and (.[0].outbound.streamSettings.hysteriaSettings | has("udpIdleTimeout") | not)'
    parse_fail 'Hysteria2 udpIdleTimeout one rejected' \
        'hysteria2://pass@hy.example.com:443?sni=hy.example.com&udpIdleTimeout=1' \
        'udpIdleTimeout'

    printf '== batch and tags ==\n'
    l1="socks5://one.example.com:1080#One"
    l2="socks5://two.example.com:1080#Two"
    batch_b64=$(printf '%s\n%s\n' "$l1" "$l2" | base64 | tr -d '\n')
    if _outbound_parse_batch "$batch_b64" && [ "$_OB_COUNT" -eq 2 ]; then
        check 'v2rayN Base64 batch contains two links' true
    else
        check 'v2rayN Base64 batch contains two links' false
    fi
    if _outbound_parse_batch $'\xef\xbb\xbf'"$batch_b64" && [ "$_OB_COUNT" -eq 2 ]; then
        check 'Base64 batch accepts UTF-8 BOM' true
    else
        check 'Base64 batch accepts UTF-8 BOM' false
    fi
    if _outbound_parse_batch "$l1"$'\n'"$l2" && [ "$_OB_COUNT" -eq 2 ]; then
        check 'plain multi-line batch contains two links' true
    else
        check 'plain multi-line batch contains two links' false
    fi
    if _outbound_parse_batch "${l1}${l2}" && [ "$_OB_COUNT" -eq 2 ]; then
        check 'concatenated links split without separator' true
    else
        check 'concatenated links split without separator' false
    fi
    sep_all='socks5://sep1.example.com:1080#Sep1 socks5://sep2.example.com:1080#Sep2
socks5://sep3.example.com:1080#Sep3,socks5://sep4.example.com:1080#Sep4;socks5://sep5.example.com:1080#Sep5，socks5://sep6.example.com:1080#Sep6；socks5://sep7.example.com:1080#Sep7socks5://sep8.example.com:1080#Sep8'
    if _outbound_parse_batch "$sep_all" &&
        [ "$_OB_COUNT" -eq 8 ] &&
        jq -e '[.[].tag] == ["Sep1","Sep2","Sep3","Sep4","Sep5","Sep6","Sep7","Sep8"]' \
            <<< "$_OB_BATCH" >/dev/null 2>&1; then
        check 'space/newline/comma/semicolon/Chinese separators and concatenation' true
    else
        check 'space/newline/comma/semicolon/Chinese separators and concatenation' false
    fi
    batch_mixed="$l1"$'\n'"tuic://bad@example.com:443#Bad"$'\n'"$l2"
    if _outbound_parse_batch "$batch_mixed" &&
        [ "$_OB_COUNT" -eq 2 ] && [ "$_OB_SKIPPED" -eq 1 ] &&
        jq -e '[.[].tag] == ["One","Two"]' <<< "$_OB_BATCH" >/dev/null 2>&1; then
        check 'batch skips invalid links' true
    else
        check 'batch skips invalid links' false
    fi
    if _outbound_parse_batch "tuic://bad.example.com:443#Bad"$'\n'"ssr://bad#Bad2" >/dev/null 2>&1; then
        check 'all-invalid batch rejected' false
    else
        case "$_OB_ERR" in
            *'没有可导入的有效链接'*) check 'all-invalid batch rejected' true ;;
            *) check 'all-invalid batch rejected' false ;;
        esac
    fi
    if _outbound_parse_batch >/dev/null 2>&1; then
        check 'empty batch arguments rejected' false
    elif [ "$_OB_ERR" = '分享链接不能为空' ]; then
        check 'empty batch arguments rejected' true
    else
        check 'empty batch arguments rejected' false
    fi
    if _outbound_read_link_inputs "$l1" < <(
        sleep 0.2
        printf '%s\n' "$l2"
        printf 'Prefetched Tag\n'
        sleep 0.2
    ) && [ "${#_OB_INPUTS[@]}" -eq 2 ] &&
        [ "$_OB_PREFETCH" = 'Prefetched Tag' ] && [ "$_OB_PREFETCH_SET" = true ]; then
        check 'delayed links prefetch non-link input' true
    else
        check 'delayed links prefetch non-link input' false
    fi
    _OB_ACCEPTED_TAGS=()
    if _outbound_prompt_tag '出口 tag' '' </dev/null &&
        [ "$_OB_TAG_INPUT" = 'Prefetched Tag' ]; then
        check 'tag prompt consumes prefetched input' true
    else
        check 'tag prompt consumes prefetched input' false
    fi
    if _outbound_parse_batch "$l1" && _outbound_parse_batch "$l1"; then
        _OB_ACCEPTED_TAGS=()
        _outbound_accept_tag "one" >/dev/null 2>&1
        _OB_ACCEPTED_TAGS+=("one")
        if _outbound_accept_tag "one" >/dev/null 2>&1; then
            check 'duplicate tag in one batch rejected' false
        else
            check 'duplicate tag in one batch rejected' true
        fi
    else
        check 'duplicate tag in one batch rejected' false
    fi
    for tag in direct block warp node-a; do
        if _outbound_accept_tag "$tag" >/dev/null 2>&1; then
            check "tag conflict [${tag}] rejected" false
        else
            check "tag conflict [${tag}] rejected" true
        fi
    done
    _OB_ACCEPTED_TAGS=()
    if _outbound_prompt_tag '出口 tag' '' <<< 'Custom Tag' >/dev/null 2>&1 &&
        [ "$_OB_TAG_INPUT" = 'Custom Tag' ]; then
        check 'custom tag accepted' true
    else
        check 'custom tag accepted' false
    fi
    _OB_ACCEPTED_TAGS=()
    if _outbound_prompt_tag '出口 tag' 'Default Tag' </dev/null >/dev/null 2>&1; then
        check 'EOF cancels tag prompt' false
    else
        check 'EOF cancels tag prompt' true
    fi
    if [ "$(declare -f _outbound_prompt_tag | grep -cF 'read -e -r -p')" -eq 2 ] &&
        [ "$(declare -f _outbound_add_prompt | grep -cF 'read -e -r -p')" -eq 2 ]; then
        check 'outbound prompts enable Readline editing' true
    else
        check 'outbound prompts enable Readline editing' false
    fi

    printf '== config commit ==\n'
    write_base_config
    routing_hash=$(hash_file "$CONFIG_DIR/05_routing.json")
    inbounds_hash=$(hash_file "$CONFIG_DIR/07_inbounds.json")
    if _outbound_parse_batch "$l1"; then
        candidate=$(jq -cn --argjson b "$_OB_BATCH" '[ $b[0].outbound + {tag:"imported-one"} ]')
        if _outbound_commit "$candidate"; then
            check 'commit appends the outbound' jq -e '
                ([.outbounds[] | select(.tag == "imported-one")] | length) == 1
                and ([.outbounds[] | select(.tag == "direct")] | length) == 1
            ' "$CONFIG_DIR/08_outbounds.json"
            check 'commit preserves routing bytes' eq "$routing_hash" "$(hash_file "$CONFIG_DIR/05_routing.json")"
            check 'commit preserves inbounds bytes' eq "$inbounds_hash" "$(hash_file "$CONFIG_DIR/07_inbounds.json")"
        else
            check 'commit appends the outbound' false
            check 'commit preserves routing bytes' false
            check 'commit preserves inbounds bytes' false
        fi
    else
        check 'commit appends the outbound' false
        check 'commit preserves routing bytes' false
        check 'commit preserves inbounds bytes' false
    fi

    write_base_config
    before_hash=$(hash_file "$CONFIG_DIR/08_outbounds.json")
    routing_hash=$(hash_file "$CONFIG_DIR/05_routing.json")
    duplicate='[{"tag":"direct","protocol":"freedom","settings":{}}]'
    if _outbound_commit "$duplicate" >/dev/null 2>&1; then
        check 'commit rejects occupied tag' false
    else
        check 'commit rejects occupied tag' true
    fi
    check 'failed commit preserves outbounds bytes' eq "$before_hash" "$(hash_file "$CONFIG_DIR/08_outbounds.json")"
    check 'failed commit preserves routing bytes' eq "$routing_hash" "$(hash_file "$CONFIG_DIR/05_routing.json")"

    printf 'outbound-alignment: %s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
