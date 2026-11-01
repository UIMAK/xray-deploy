#!/usr/bin/env bash
# Offline behavior of real Hy2 transactions, cron scheduling and service menus.
# 桩函数与 fixture 变量由 source 进来的生产模块间接消费。
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || { printf 'SUMMARY pass=0 fail=1\n'; exit 1; }
# 被 source 时不得 exit/覆盖调用方的 EXIT trap; 作为子进程运行(未 source)时才 exit 与装 trap。
_XD_SOURCED=0
[ "${BASH_SOURCE[0]}" != "$0" ] && _XD_SOURCED=1
_XD_TMP_OWNED=0
if [ "$_XD_SOURCED" -eq 0 ]; then
    command -v jq >/dev/null 2>&1 || { printf 'SUMMARY pass=0 fail=1 (jq required)\n'; exit 1; }
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-menu-alignment.XXXXXX") || { printf 'SUMMARY pass=0 fail=1 (mktemp failed)\n'; exit 1; }
    cleanup() {
        # 直接按 $TMP 的模板前缀判定, 不依赖 pwd -P 相等(软链 TMPDIR 下会漏删)。
        case "$TMP" in
            "${TMPDIR:-/tmp}"/xray-menu-alignment.*) rm -rf -- "$TMP" ;;
        esac
    }
    trap cleanup EXIT
else
    # 被 source 时用调用方的 TMP; 缺失则自建临时目录, 由下方子 shell 负责清理,
    # 既不装调用方 EXIT trap, 也不能因 mktemp 失败而让后续路径落到 / 根下。
    if [ -z "${TMP:-}" ]; then
        TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-menu-alignment.XXXXXX") || {
            printf 'SUMMARY pass=0 fail=1 (mktemp failed)\n'
            return 1
        }
        _XD_TMP_OWNED=1
    fi
fi

# Keep every mock in a subshell, including when this test is sourced elsewhere.
(
    # source 模式自建的临时目录由本子 shell 清理, 不改动调用方 EXIT trap。
    [ "${_XD_TMP_OWNED:-0}" -eq 1 ] && trap 'rm -rf -- "$TMP"' EXIT
    . "$ROOT/lib/00-common.sh"
    . "${MENU_ALIGNMENT_NODES_MODULE:-$ROOT/lib/50-nodes.sh}"
    # Override only for a disposable mutated copy, never edit production modules.
    . "${MENU_ALIGNMENT_MENU_MODULE:-$ROOT/lib/90-menu.sh}"

    DEPLOY_DIR="$TMP/deploy"
    CONFIG_DIR="$DEPLOY_DIR/confs"
    NODES_DIR="$DEPLOY_DIR/nodes"
    BACKUP_DIR="$DEPLOY_DIR/backups"
    STATE_DIR="$DEPLOY_DIR/state"
    CLASH_YAML="$DEPLOY_DIR/clash.yaml"
    mkdir -p "$CONFIG_DIR" "$NODES_DIR" "$BACKUP_DIR" "$STATE_DIR" || exit 1
    TAG=xd-hysteria2-443
    META="$NODES_DIR/$TAG.json"
    PASS=0 FAIL=0
    CONFIG_FAIL=no

    _info() { :; }
    _warn() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _error() { printf '%s\n' "$*" >> "$TMP/messages"; }
    _mutate_config() {
        local content
        printf 'config\n' >> "$TMP/writes"
        [ "$CONFIG_FAIL" = no ] || return 1
        content=$(_config_jq "$@") || return 1
        _config_write_merged "$content"
    }
    _meta_update() {
        local meta="$1" filter="$2" content
        shift 2
        printf 'metadata\n' >> "$TMP/writes"
        content=$(jq "$@" "$filter" "$meta") || return 1
        printf '%s\n' "$content" > "$meta"
    }
    _hy2_sync_derived() {
        # 参数必须是本节点的元数据路径; 不符则不写 sentinel 并报错, 让 committed() 的
        # "writes 序列" 与 "messages 为空" 断言暴露出来。
        if [ "$1" != "$META" ]; then
            _error "derived sync called with unexpected path: $1"
            return 1
        fi
        printf 'derived\n' >> "$TMP/writes"
        return 0
    }
    _restart_xray_verified() { printf 'UNEXPECTED restart\n' >> "$TMP/writes"; return 99; }
    _manage_xray() { printf 'UNEXPECTED service\n' >> "$TMP/writes"; return 99; }

    check() {
        local label="$1"
        shift
        if "$@"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$label"; fi
    }
    eq() { [ "$1" = "$2" ]; }
    fixture() {
        local cc="$1" up="$2" down="${3-90 mbps}"
        CONFIG_FAIL=no
        printf '{"version":{"min":"26.4.25","max":""}}' > "$CONFIG_DIR/15_version.json"
        jq -n --arg t "$TAG" --arg cc "$cc" --arg up "$up" --arg down "$down" '
            {inbounds: [
                {tag: $t, protocol: "hysteria", port: 443,
                 settings: {version: 2, users: [{auth: "unchanged-auth", foreign: {keep: true}},
                      {auth: "second-auth"}], foreign: {keep: "settings"}},
                 streamSettings: {network: "hysteria", security: "tls",
                    tlsSettings: {serverName: "example.test"},
                    finalmask: {udp: [{type: "salamander", settings: {password: "keep"}}],
                        quicParams: ({congestion: $cc, debug: true, bbrProfile: "aggressive"}
                            + (if $up == "" then {} else {brutalUp: $up} end)
                            + (if $down == "" then {} else {brutalDown: $down} end))}}},
                {tag: "unrelated", protocol: "shadowsocks", port: 8443}
            ]}' > "$CONFIG_DIR/07_inbounds.json" || exit 1
        jq -n --arg t "$TAG" --arg cc "$cc" --arg up "$up" --arg down "$down" '
            {tag: $t, protocol: "hysteria2", name: "fixture", port: 443,
             auth: "unchanged-auth", share_link: "old-link", custom: {keep: true},
             congestion: $cc, brutal_up: $up, brutal_down: $down}' > "$META" || exit 1
        printf 'unchanged derived fixture\n' > "$CLASH_YAML"
        snapshot
    }
    snapshot() {
        cp "$CONFIG_DIR/07_inbounds.json" "$TMP/before-inbounds.json"
        cp "$META" "$TMP/before-meta.json"
        BEFORE_CONFIG=$(_config_merged)
        BEFORE_META=$(cat "$META")
        BEFORE_CLASH=$(cat "$CLASH_YAML")
        : > "$TMP/writes"
        : > "$TMP/messages"
    }
    invoke() {
        RC=0
        _hy2_congestion_txn_locked "$TAG" "$@" > "$TMP/output" 2>&1 || RC=$?
    }
    rejected() {
        local label="$1"
        check "$label: rejects" eq "$RC" 1
        check "$label: rejects before any writer or derived sync" test ! -s "$TMP/writes"
        check "$label: config byte-for-byte unchanged" eq "$BEFORE_CONFIG" "$(_config_merged)"
        check "$label: metadata byte-for-byte unchanged" eq "$BEFORE_META" "$(cat "$META")"
        check "$label: raw config bytes unchanged" cmp -s "$TMP/before-inbounds.json" "$CONFIG_DIR/07_inbounds.json"
        check "$label: raw metadata bytes unchanged" cmp -s "$TMP/before-meta.json" "$META"
        check "$label: reports invalid transaction" test -s "$TMP/messages"
        check "$label: derived file unchanged" eq "$BEFORE_CLASH" "$(cat "$CLASH_YAML")"
    }
    committed() {
        local label="$1" params="$2" meta_filter="$3" expected_config expected_meta
        expected_config=$(jq --arg t "$TAG" --argjson q "$params" '
            (.inbounds[] | select(.tag == $t) | .streamSettings.finalmask.quicParams) = $q' <<< "$BEFORE_CONFIG")
        expected_meta=$(jq "$meta_filter | if .brutal_up == \"\" then del(.brutal_up) else . end | if .brutal_down == \"\" then del(.brutal_down) else . end" <<< "$BEFORE_META")
        check "$label: succeeds" eq "$RC" 0
        check "$label: config then metadata then derived exactly once" eq "$(cat "$TMP/writes")" $'config\nmetadata\nderived'
        check "$label: no warnings or errors on the committed path" test ! -s "$TMP/messages"
        check "$label: config contract including unrelated inbound and transport" eq "$expected_config" "$(_config_merged)"
        check "$label: metadata contract including unrelated fields" eq "$expected_meta" "$(jq . "$META")"
    }
    # 元数据写入失败必须触发回滚: _restore_config + _restart_xray_verified 回到旧态, 返回 1(完整回滚)。
    # 在子 shell 内覆盖 mock(避免污染后续用例), 结果落盘, 由父层 check 断言(子 shell 内的 check 计数会丢)。
    # _restore_config 桩必须真的恢复事务前字节, 否则"完整回滚"断言会在配置仍被改写的状态下误报通过。
    printf '== Hy2 metadata failure rollback ==\n'
    rb_rc=""; rb_writes=""
    (
        fixture bbr '45 mbps'
        meta_prev=$(cat "$META")
        _meta_update() { printf 'metadata\n' >> "$TMP/writes"; return 1; }
        _restore_config() {
            printf 'restore\n' >> "$TMP/writes"
            cp "$TMP/before-inbounds.json" "$CONFIG_DIR/07_inbounds.json" || return 1
            return 0
        }
        _restart_xray_verified() { printf 'restart\n' >> "$TMP/writes"; return 0; }
        invoke congestion force-brutal '60 mbps' ''
        printf '%s' "$RC" > "$TMP/rb-rc"
        cat "$TMP/writes" > "$TMP/rb-writes"
        printf '%s' "$meta_prev" > "$TMP/rb-meta-prev"
        printf '%s' "$(cat "$META")" > "$TMP/rb-meta-after"
        cp "$CONFIG_DIR/07_inbounds.json" "$TMP/rb-config-after"
    )
    rb_rc=$(cat "$TMP/rb-rc"); rb_writes=$(cat "$TMP/rb-writes")
    check 'metadata write failure: reports complete rollback (rc=1)' eq "$rb_rc" 1
    check 'metadata write failure: restores config then restarts' eq "$rb_writes" $'config\nmetadata\nrestore\nrestart'
    check 'metadata write failure: metadata rolled back to snapshot bytes' eq "$(cat "$TMP/rb-meta-prev")" "$(cat "$TMP/rb-meta-after")"
    check 'metadata write failure: config restored to pre-transaction bytes' cmp -s "$TMP/before-inbounds.json" "$TMP/rb-config-after"

    printf '== Hy2 menu transaction official alignment ==\n'
    for invalid_up in '' '0' '0 mbps' '00.000 kbps' 'not-a-rate' 1kbps 0.01mbps 10kbps 65534bps 65535bps 100kbps 524287bps 511.999kbps 0.499999mbps 1watts; do
        fixture bbr '45 mbps'
        invoke congestion force-brutal "$invalid_up" '80 mbps'
        rejected "force-brutal switch up=[$invalid_up]"
    done

    for valid_up in 524288bps 512kbps 0.5mbps; do
        fixture bbr '45 mbps'
        invoke congestion force-brutal "$valid_up" ''
        committed "force-brutal minimum [$valid_up]" \
            "{\"congestion\":\"force-brutal\",\"brutalUp\":\"$valid_up\"}" \
            ".congestion=\"force-brutal\" | .brutal_up=\"$valid_up\" | .brutal_down=\"\""
    done

    fixture bbr '45 mbps'
    invoke congestion force-brutal '60 mbps' ''
    committed 'nonzero force-brutal switch permits blank down' \
        '{"congestion":"force-brutal","brutalUp":"60 mbps"}' \
        '.congestion="force-brutal" | .brutal_up="60 mbps" | .brutal_down=""'

    fixture bbr '45 mbps'
    invoke congestion force-brutal '0.5 gbps' '0'
    committed 'fractional nonzero force-brutal with unlimited down' \
        '{"congestion":"force-brutal","brutalUp":"0.5 gbps","brutalDown":"0"}' \
        '.congestion="force-brutal" | .brutal_up="0.5 gbps" | .brutal_down="0"'

    fixture bbr '45 mbps'
    invoke congestion brutal '' ''
    committed 'negotiated brutal permits blank bandwidth' \
        '{"congestion":"brutal"}' '.congestion="brutal" | .brutal_up="" | .brutal_down=""'

    fixture bbr '45 mbps'
    invoke congestion brutal '0' '0'
    committed 'negotiated brutal permits unlimited zero' \
        '{"congestion":"brutal","brutalUp":"0","brutalDown":"0"}' \
        '.congestion="brutal" | .brutal_up="0" | .brutal_down="0"'

    for operation in congestion bandwidth; do
        for rate in 1bps 7bps 0.000001mbps 1kbps 65535bps 524287bps not-a-rate 1watts; do
            for target in brutal-up brutal-down force-down; do
                cc=brutal up='75 mbps' down='90 mbps'
                case "$target" in
                    brutal-up) up="$rate" ;;
                    brutal-down) down="$rate" ;;
                    force-down) cc=force-brutal down="$rate" ;;
                esac
                if [ "$operation" = congestion ]; then
                    fixture bbr '45 mbps'
                    invoke congestion "$cc" "$up" "$down"
                else
                    fixture "$cc" '75 mbps'
                    invoke bandwidth '' "$up" "$down"
                fi
                rejected "$operation $target=[$rate]"
            done
        done
        for rate in 524288bps 512kbps 0.5mbps 0 '0 mbps' 00.000kbps ''; do
            for target in brutal-up brutal-down force-down; do
                cc=brutal up='75 mbps' down='90 mbps'
                case "$target" in
                    brutal-up) up="$rate" ;;
                    brutal-down) down="$rate" ;;
                    force-down) cc=force-brutal down="$rate" ;;
                esac
                if [ "$operation" = congestion ]; then
                    fixture bbr '45 mbps'
                    invoke congestion "$cc" "$up" "$down"
                    params=$(jq -nc --arg cc "$cc" --arg up "$up" --arg down "$down" '
                        {congestion: $cc}
                        + (if $up == "" then {} else {brutalUp: $up} end)
                        + (if $down == "" then {} else {brutalDown: $down} end)')
                else
                    if [ -z "$rate" ]; then
                        fixture "$cc" "$up" "$down"
                    else
                        fixture "$cc" '75 mbps'
                    fi
                    invoke bandwidth '' "$up" "$down"
                    params=$(jq -nc --arg cc "$cc" --arg up "$up" --arg down "$down" '
                        {congestion: $cc, debug: true, bbrProfile: "aggressive"}
                        + (if $up == "" then {} else {brutalUp: $up} end)
                        + (if $down == "" then {} else {brutalDown: $down} end)')
                fi
                meta_filter=$(jq -nr --arg cc "$cc" --arg up "$up" --arg down "$down" '
                    ".congestion=" + ($cc | tojson) + " | .brutal_up=" + ($up | tojson)
                    + " | .brutal_down=" + ($down | tojson)')
                committed "$operation $target=[$rate]" "$params" "$meta_filter"
            done
        done
    done

    for rate in 524288bps 512kbps 0.5mbps; do
        fixture force-brutal '75 mbps'
        invoke bandwidth '' "$rate" ''
        committed "force-brutal bandwidth minimum up=[$rate]" \
            "{\"congestion\":\"force-brutal\",\"debug\":true,\"bbrProfile\":\"aggressive\",\"brutalUp\":\"$rate\",\"brutalDown\":\"90 mbps\"}" \
            ".brutal_up=\"$rate\" | .brutal_down=\"90 mbps\""
    done
    for cc in brutal force-brutal; do
        for old_down in 1kbps 65535bps 524287bps not-a-rate; do
            fixture "$cc" '75 mbps' "$old_down"
            jq '.brutal_down="90 mbps"' "$META" > "$TMP/meta-next"
            cat "$TMP/meta-next" > "$META"
            snapshot
            invoke bandwidth '' '100 mbps' ''
            rejected "$cc blank down retains invalid actual config down=[$old_down] despite valid metadata"
        done
    done
    for old_up in 1kbps 65535bps 524287bps not-a-rate; do
        fixture brutal "$old_up"
        jq '.brutal_up="75 mbps"' "$META" > "$TMP/meta-next"
        cat "$TMP/meta-next" > "$META"
        snapshot
        invoke bandwidth '' '' '120 mbps'
        rejected "brutal blank up retains invalid actual config up=[$old_up] despite valid metadata"
    done
    for cc in brutal force-brutal; do
        fixture "$cc" '75 mbps' 1kbps
        invoke bandwidth '' '' 512kbps
        committed "$cc explicit down repairs invalid old config down" \
            "{\"congestion\":\"$cc\",\"debug\":true,\"bbrProfile\":\"aggressive\",\"brutalUp\":\"75 mbps\",\"brutalDown\":\"512kbps\"}" \
            '.brutal_up="75 mbps" | .brutal_down="512kbps"'
    done

    fixture force-brutal '75 mbps'
    jq '.brutal_up="0" | .brutal_down="stale"' "$META" > "$TMP/meta-next"
    cat "$TMP/meta-next" > "$META"
    snapshot
    invoke bandwidth '' '' '120 mbps'
    committed 'blank force-brutal up retains config not stale metadata' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"75 mbps","brutalDown":"120 mbps"}' \
        '.brutal_up="75 mbps" | .brutal_down="120 mbps"'

    fixture force-brutal '75 mbps'
    invoke bandwidth '' '' ''
    committed 'both blank bandwidth inputs preserve config values' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"75 mbps","brutalDown":"90 mbps"}' \
        '.brutal_up="75 mbps" | .brutal_down="90 mbps"'

    fixture force-brutal '75 mbps'
    invoke bandwidth '' '100 mbps' ''
    committed 'force-brutal explicit nonzero up retains blank down' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"100 mbps","brutalDown":"90 mbps"}' \
        '.brutal_up="100 mbps" | .brutal_down="90 mbps"'

    for invalid_up in '0' '0 mbps' '0.000 gbps' 1kbps 524287bps 0.499999mbps; do
        fixture force-brutal '75 mbps'
        invoke bandwidth '' "$invalid_up" '120 mbps'
        rejected "force-brutal bandwidth explicit up=[$invalid_up]"
    done
    for old_up in '' '0' '0 mbps' 1kbps 524287bps; do
        fixture force-brutal "$old_up"
        invoke bandwidth '' '' '120 mbps'
        rejected "force-brutal blank up with invalid effective config up=[$old_up]"
    done
    fixture force-brutal '0'
    jq '.brutal_up="75 mbps"' "$META" > "$TMP/meta-next"
    cat "$TMP/meta-next" > "$META"
    snapshot
    invoke bandwidth '' '' '120 mbps'
    rejected 'blank force-brutal up rejects config zero despite nonzero metadata'

    fixture force-brutal '0'
    invoke bandwidth '' '100 mbps' ''
    committed 'explicit nonzero bandwidth repairs old zero up' \
        '{"congestion":"force-brutal","debug":true,"bbrProfile":"aggressive","brutalUp":"100 mbps","brutalDown":"90 mbps"}' \
        '.brutal_up="100 mbps" | .brutal_down="90 mbps"'

    fixture brutal '' ''
    invoke bandwidth '' '' ''
    committed 'negotiated brutal bandwidth permits absent up' \
        '{"congestion":"brutal","debug":true,"bbrProfile":"aggressive"}' '.brutal_up="" | .brutal_down=""'

    fixture force-brutal '75 mbps'
    invoke congestion bbr '' ''
    committed 'bbr switch removes config and metadata bandwidth fields' \
        '{"congestion":"bbr"}' '.congestion="bbr" | del(.brutal_up, .brutal_down)'

    fixture force-brutal '75 mbps'
    jq '.congestion="brutal"' "$META" > "$TMP/meta-next"
    cat "$TMP/meta-next" > "$META"
    snapshot
    invoke bandwidth '' '100 mbps' ''
    rejected 'bandwidth rejects config metadata congestion disagreement'

    fixture bbr '45 mbps'
    invoke congestion reno '60 mbps' ''
    rejected 'unsupported menu congestion mode'

    for cc in brutal force-brutal; do
        fixture "$cc" '75 mbps'
        invoke congestion "$cc" '100 mbps' '120 mbps'
        committed "$cc same-mode switch applies both new bandwidths" \
            "{\"congestion\":\"$cc\",\"brutalUp\":\"100 mbps\",\"brutalDown\":\"120 mbps\"}" \
            '.brutal_up="100 mbps" | .brutal_down="120 mbps"'

        fixture "$cc" '75 mbps'
        invoke congestion "$cc" '75 mbps' ''
        committed "$cc same-mode switch clears down on blank input" \
            "{\"congestion\":\"$cc\",\"brutalUp\":\"75 mbps\"}" '.brutal_down=""'

        fixture "$cc" '75 mbps'
        jq '.brutal_up="stale" | .brutal_down="stale"' "$META" > "$TMP/meta-next"
        cat "$TMP/meta-next" > "$META"
        snapshot
        invoke congestion "$cc" '75 mbps' '90 mbps'
        committed "$cc same-mode switch reconciles stale metadata" \
            "{\"congestion\":\"$cc\",\"brutalUp\":\"75 mbps\",\"brutalDown\":\"90 mbps\"}" \
            '.brutal_up="75 mbps" | .brutal_down="90 mbps"'
    done

    fixture bbr '' ''
    invoke congestion bbr '' ''
    check 'already aligned congestion returns existing no-op status' eq "$RC" 3
    check 'already aligned congestion performs no writes or sync' test ! -s "$TMP/writes"
    check 'already aligned congestion preserves config' eq "$BEFORE_CONFIG" "$(_config_merged)"
    check 'already aligned congestion preserves metadata' eq "$BEFORE_META" "$(cat "$META")"

    fixture bbr '45 mbps'
    CONFIG_FAIL=yes
    invoke congestion force-brutal '60 mbps' ''
    check 'config failure returns failure' eq "$RC" 1
    check 'config failure never attempts metadata or derived commit' eq "$(cat "$TMP/writes")" config
    check 'config failure preserves metadata' eq "$BEFORE_META" "$(cat "$META")"
    check 'config failure preserves config' eq "$BEFORE_CONFIG" "$(_config_merged)"

    printf '== Timed restart menu ==\n'
    cron_fixture() {
        printf '%s\n' 'MAILTO=operator@example.test' '15 4 * * * /usr/local/bin/backup' \
            '0 */3 * * * /usr/local/bin/xd timed-restart # xray-deploy-timed-restart' > "$TMP/crontab"
        printf '0 */3 * * *' > "$STATE_DIR/timed_restart"
        cp "$TMP/crontab" "$TMP/before-crontab"
        cp "$STATE_DIR/timed_restart" "$TMP/before-timed-state"
        : > "$TMP/cron-writes"
        : > "$TMP/success"
        : > "$TMP/messages"
    }
    invoke_cron() {
        RC=0
        (
            clear() { :; }
            _press_any_key() { :; }
            _tip() { :; }
            _success() { printf '%s\n' "$*" >> "$TMP/success"; }
            command() {
                if [ "${1-}" = -v ] && [ "${2-}" = "$CMD_NAME" ]; then
                    printf '/usr/local/bin/%s\n' "$CMD_NAME"
                else
                    builtin command "$@"
                fi
            }
            # Only the daemon and command boundary are mocked; helpers read/write scratch.
            _with_config_lock() { "$@"; }
            crontab() {
                case "$1" in
                    -l) cat "$TMP/crontab" ;;
                    -) printf 'write\n' >> "$TMP/cron-writes"
                       [ "$CRON_WRITE_FAIL" = no ] || return 1
                       cat > "$TMP/crontab" ;;
                    *) return 99 ;;
                esac
            }
            CRON_START_RC="$1"
            _ensure_cron_running() { return "$CRON_START_RC"; }
            _timed_restart_menu <<< '2'
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    CMD_NAME=xd
    CRON_WRITE_FAIL=no
    cron_fixture
    invoke_cron 1
    check 'cron startup failure retains menu return status' eq "$RC" 0
    check 'cron startup failure performs no crontab writes' test ! -s "$TMP/cron-writes"
    check 'cron startup failure preserves all original crontab bytes' cmp -s "$TMP/before-crontab" "$TMP/crontab"
    check 'cron startup failure preserves original state bytes' cmp -s "$TMP/before-timed-state" "$STATE_DIR/timed_restart"
    check 'cron startup failure emits no success' test ! -s "$TMP/success"
    check 'cron startup failure reports daemon failure' grep -qF 'cron 守护进程未能启动' "$TMP/messages"

    cron_fixture
    invoke_cron 0
    check 'cron startup success retains menu return status' eq "$RC" 0
    check 'cron startup success writes exactly once' eq "$(cat "$TMP/cron-writes")" write
    check 'cron startup success preserves unrelated tasks and replaces old schedule' \
        eq "$(cat "$TMP/crontab")" $'MAILTO=operator@example.test\n15 4 * * * /usr/local/bin/backup\n0 */6 * * * /usr/local/bin/xd timed-restart # xray-deploy-timed-restart'
    check 'cron startup success updates state' eq "$(_state_get timed_restart)" '0 */6 * * *'
    check 'cron startup success reports new schedule' grep -qF '定时重启已设置: 0 */6 * * *' "$TMP/success"

    cron_fixture
    CRON_WRITE_FAIL=yes
    invoke_cron 0
    check 'cron write failure retains menu return status' eq "$RC" 0
    check 'cron write failure preserves old tasks' cmp -s "$TMP/before-crontab" "$TMP/crontab"
    check 'cron write failure preserves state' cmp -s "$TMP/before-timed-state" "$STATE_DIR/timed_restart"
    check 'cron write failure emits no success' test ! -s "$TMP/success"
    check 'cron write failure reports failure' grep -qF '写入 crontab 失败' "$TMP/messages"

    printf '== Main menu stop result ==\n'
    invoke_stop_menu() {
        : > "$TMP/success"
        : > "$TMP/messages"
        : > "$TMP/service-calls"
        : > "$TMP/press-calls"
        RC=0
        (
            STOP_RC="$1"
            clear() { :; }
            _menu_require_tty() { return 0; }
            _print_logo() { :; }
            _print_status_bar() { :; }
            _menu_row() { :; }
            _press_any_key() { printf 'press\n' >> "$TMP/press-calls"; }
            _success() { printf '%s\n' "$*" >> "$TMP/success"; }
            _reset_config_recover() { return 0; }
            _xray_core_txn_recover() { return 0; }
            _port_txn_recover() { return 0; }
            _auto_tag_tagless_inbounds() { return 0; }
            _auto_adopt_orphans() { return 0; }
            _auto_ensure_config_env() { return 0; }
            _manage_xray() { printf '%s\n' "$*" >> "$TMP/service-calls"; return "$STOP_RC"; }
            # 12 = 主菜单的 [停止 Xray]; 编号变更时同步 lib/90-menu.sh 的 case 分支。
            _main_menu <<< $'12\n0'
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    for stop_rc in 1 2 99; do
        invoke_stop_menu "$stop_rc"
        check "stop rc=$stop_rc: menu exits normally after 0" eq "$RC" 0
        check "stop rc=$stop_rc: dispatches only stop once" eq "$(cat "$TMP/service-calls")" stop
        check "stop rc=$stop_rc: emits no success" test ! -s "$TMP/success"
        check "stop rc=$stop_rc: reports failure" grep -qF '停止 Xray 失败' "$TMP/messages"
        check "stop rc=$stop_rc: still pauses before next selection" eq "$(cat "$TMP/press-calls")" press
    done
    invoke_stop_menu 0
    check 'stop success: menu exits normally after 0' eq "$RC" 0
    check 'stop success: dispatches only stop once' eq "$(cat "$TMP/service-calls")" stop
    check 'stop success: reports stopped' eq "$(cat "$TMP/success")" '已停止'
    check 'stop success: emits no failure' test ! -s "$TMP/messages"
    check 'stop success: still pauses before next selection' eq "$(cat "$TMP/press-calls")" press

    printf '== Uninstall menu exit ==\n'
    invoke_uninstall_menu() {
        : > "$TMP/uninstall-actions"
        : > "$TMP/menu-draws"
        RC=0
        (
            clear() { :; }
            _menu_require_tty() { return 0; }
            _print_logo() { printf 'menu\n' >> "$TMP/menu-draws"; }
            _print_status_bar() { :; }
            _menu_row() { :; }
            _reset_config_recover() { return 0; }
            _xray_core_txn_recover() { return 0; }
            _port_txn_recover() { return 0; }
            _auto_tag_tagless_inbounds() { return 0; }
            _auto_adopt_orphans() { return 0; }
            _auto_ensure_config_env() { return 0; }
            _reset_config() { printf 'reset\n' >> "$TMP/uninstall-actions"; }
            _uninstall_xray() { printf 'xray:%s\n' "${1:-all}" >> "$TMP/uninstall-actions"; }
            _uninstall_cloudflared() { printf 'cloudflared\n' >> "$TMP/uninstall-actions"; }
            _main_menu <<< "$1"
        ) > "$TMP/output" 2>&1 || RC=$?
    }
    invoke_uninstall_menu $'22\n4\ny\n\n0'
    check 'full uninstall: exits normally' eq "$RC" 0
    check 'full uninstall: performs both uninstalls' eq "$(cat "$TMP/uninstall-actions")" $'xray:all\ncloudflared'
    check 'full uninstall: prompts to exit' grep -qF '按回车键退出...' "$TMP/output"
    check 'full uninstall: does not prompt to continue' test "$(grep -cF '按回车键继续...' "$TMP/output")" -eq 0
    check 'full uninstall: does not redraw main menu' eq "$(cat "$TMP/menu-draws")" menu

    for uninstall_choice in 1 2 3; do
        case "$uninstall_choice" in
            1) uninstall_input=$'22\n1\n\n0'; uninstall_actions=reset ;;
            2) uninstall_input=$'22\n2\ny\n\n0'; uninstall_actions=xray:keep-panel ;;
            3) uninstall_input=$'22\n3\ny\n\n0'; uninstall_actions=$'xray:keep-panel\ncloudflared' ;;
        esac
        invoke_uninstall_menu "$uninstall_input"
        check "uninstall option $uninstall_choice: exits normally after 0" eq "$RC" 0
        check "uninstall option $uninstall_choice: dispatches requested action" eq "$(cat "$TMP/uninstall-actions")" "$uninstall_actions"
        check "uninstall option $uninstall_choice: prompts to continue" grep -qF '按回车键继续...' "$TMP/output"
        check "uninstall option $uninstall_choice: does not prompt to exit" test "$(grep -cF '按回车键退出...' "$TMP/output")" -eq 0
        check "uninstall option $uninstall_choice: redraws main menu" eq "$(cat "$TMP/menu-draws")" $'menu\nmenu'
    done
    invoke_uninstall_menu $'22\n4\nn\n\n0'
    check 'cancel full uninstall: exits normally after 0' eq "$RC" 0
    check 'cancel full uninstall: performs no uninstall' test ! -s "$TMP/uninstall-actions"
    check 'cancel full uninstall: prompts to continue' grep -qF '按回车键继续...' "$TMP/output"
    check 'cancel full uninstall: does not prompt to exit' test "$(grep -cF '按回车键退出...' "$TMP/output")" -eq 0
    check 'cancel full uninstall: redraws main menu' eq "$(cat "$TMP/menu-draws")" $'menu\nmenu'

    printf '== Main menu numbering ==\n'
    # 显示的编号与 case 分支必须一一对应: 漏改一侧会让该菜单项静默落到无效选择。
    # 退出项 [0] 由 echo 打印、不在 _menu_row 里, 所以只从 case 侧剔除 0。
    menu_body() { awk '/^_main_menu\(\) \{/{p=1} p{print} p&&/^}/{exit}' "${MENU_ALIGNMENT_MENU_MODULE:-$ROOT/lib/90-menu.sh}"; }
    menu_display_nums() { menu_body | grep '^ *_menu_row' | sed 's/"[^"]*"//g' | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' '; }
    menu_case_nums() { menu_body | awk '/case "\$choice" in/{c=1} c&&/^ *[0-9]+\)/{gsub(/[^0-9]/,"",$1); print $1} c&&/^ *esac/{c=0}' | grep -vx 0 | sort -n | uniq | tr '\n' ' '; }
    check 'main menu: displayed numbers are 1..22 without gaps' eq '1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 ' "$(menu_display_nums)"
    check 'main menu: case branches match the displayed numbers' eq "$(menu_display_nums)" "$(menu_case_nums)"
    printf '== reset residual snapshot ==\n'
    # 上一次 reset 已提交(runtime_verified)但清理失败: journal 与快照都残留。
    # 收敛路径本次返回 0 但没清掉残留快照时, 新 reset 不得被永久阻断, 应清理后继续。
    reset_snapshot_cleanup() (
        local dir="$TMP/reset-cleanup"
        DEPLOY_DIR="$dir" CONFIG_DIR="$dir/confs" NODES_DIR="$dir/nodes"
        BACKUP_DIR="$dir/backups" STATE_DIR="$dir/state" CLASH_YAML="$dir/clash.yaml"
        XRAY_BIN="$dir/bin/xray"
        mkdir -p "$CONFIG_DIR" "$NODES_DIR" "$BACKUP_DIR" "$STATE_DIR"
        _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' >/dev/null 2>&1 || return 1
        local snapshot="$dir/.reset-snapshot"
        mkdir -p "$snapshot"
        # 模拟"已收敛但残留未清": 收敛返回 0, 快照仍在。
        _reset_config_recover_locked() { return 0; }
        _backup_config() { return 0; }
        _with_config_lock() { "$@"; }
        _with_deploy_install_lock() { "$@"; }
        _reset_fsync_required() { return 0; }
        _reset_fsync_rename() { return 0; }
        _hy2_hop_cleanup_candidates() { return 0; }
        _hy2_cleanup_all_hops() { return 0; }
        _init_config_if_empty() { _config_write_merged '{"version":{"min":"26.4.25","max":""},"inbounds":[]}' >/dev/null 2>&1; }
        _restart_xray_verified() { return 0; }
        _reset_config_locked >/dev/null 2>&1
        local rc=$?
        # 残留快照被清理并重建; 成功收尾(rc 0)且快照已随提交删除。
        [ "$rc" -eq 0 ] && [ ! -e "$snapshot" ]
    )
    check 'reset proceeds past a residual snapshot and cleans up' reset_snapshot_cleanup

    printf 'SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
)
