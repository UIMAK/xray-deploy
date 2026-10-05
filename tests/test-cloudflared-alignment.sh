#!/bin/bash
# Offline service transactions; mocks never call the host's init system.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d) || exit 1
trap 'case "$TMP" in "${TMPDIR:-/tmp}"/tmp.*) rm -rf "$TMP" ;; esac' EXIT
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
. "$ROOT/lib/40-cloudflared.sh"
CF_BIN="$TMP/cloudflared"
CF_UNIT_SYSTEMD="$TMP/cloudflared.service"
CF_UNIT_OPENRC="$TMP/openrc"
INIT_SYSTEM=systemd
GREEN= RED= YELLOW= NC= CYAN= SKYBLUE=
OLD=$(printf '%s' '{"a":"old-account","t":"old-tunnel","s":"secret"}' | jq -Rr '@base64')
NEW=$(printf '%s' '{"a":"new-account","t":"new-tunnel","s":"secret"}' | jq -Rr '@base64')
export MOCK_ROOT="$TMP" CF_UNIT_SYSTEMD CF_UNIT_OPENRC INIT_SYSTEM
passed=0 failed=0
_info() { :; }
_tip() { :; }
_warn() { printf '%s\n' "$*" >> "$TMP/messages"; }
_error() { printf '%s\n' "$*" >> "$TMP/messages"; }
_success() { printf '%s\n' "$*" >> "$TMP/success"; }
_state_set() { printf '%s' "$2" > "$STATE_DIR/$1"; }
_install_cloudflared_bin() { return 0; }
_cf_restart() {
    local n; n=$(cat "$TMP/restarts"); printf '%s' "$((n+1))" > "$TMP/restarts"
    if [ "$n" = 0 ] && [ "${RESTART_FAIL:-no}" = yes ]; then return 1; fi
    return 0
}
_cf_is_managed_running() { [ "${LIVE:-yes}" = yes ]; }
systemctl() {
    printf '%s\n' "$*" >> "$TMP/systemctl"
    local unit="${!#}" action="$1"
    if [ "$unit" = cloudflared-update.timer ]; then
        case "$action" in
            show) if [ "$(cat "$TMP/timer-present")" = yes ]; then echo loaded; else echo not-found; fi ;;
            is-enabled) [ "$(cat "$TMP/timer-enabled")" = on ] ;;
            is-active) [ "$(cat "$TMP/timer-active")" = on ] ;;
            enable) printf on > "$TMP/timer-enabled"; case "$*" in *--now*) printf on > "$TMP/timer-active" ;; esac ;;
            disable)
                if [ "${TIMER_FAIL:-no}" = yes ] && [ ! -f "$TMP/timer-failed" ]; then touch "$TMP/timer-failed"; return 1; fi
                printf off > "$TMP/timer-enabled"; case "$*" in *--now*) printf off > "$TMP/timer-active" ;; esac ;;
            start) printf on > "$TMP/timer-active" ;;
            stop) printf off > "$TMP/timer-active" ;;
            *) return 1 ;;
        esac
    elif [ "$unit" = cloudflared-update.service ]; then
        [ "$action" = stop ]
    elif [ "$action" = daemon-reload ]; then
        if [ "${RELOAD_FAIL:-no}" = yes ] && [ ! -f "$TMP/reload-failed" ]; then touch "$TMP/reload-failed"; return 1; fi
    else
        printf 'UNEXPECTED host operation: %s\n' "$*" >&2
        return 99
    fi
}
cat > "$CF_BIN" <<'BIN'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_ROOT/install-args"
[ "$1" = service ] && [ "$2" = install ] || exit 9
[ "$3" = --no-update-service ] || exit 8
token="$4"
if [ "$INIT_SYSTEM" = systemd ]; then
    printf '%s' "$token" > "$MOCK_ROOT/token"
    printf 'ExecStart=%s --no-autoupdate tunnel run --token-file %s/token\n' "$0" "$MOCK_ROOT" > "$CF_UNIT_SYSTEMD"
else
    printf 'command="%s"\ncommand_args="--no-autoupdate tunnel run --token %s"\n' "$0" "$token" > "$CF_UNIT_OPENRC"
fi
BIN
chmod +x "$CF_BIN"
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed+1)); else failed=$((failed+1)); printf 'FAIL: %s\n' "$label"; fi
}
eq() { [ "$1" = "$2" ]; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
no_contains() { ! contains "$1" "$2"; }
run() { local expected="$1"; shift; local rc=0; "$@" > "$TMP/output" 2>&1 || rc=$?; check "$* rc=$expected (got $rc)" eq "$rc" "$expected"; }
reset_fixture() {
    INIT_SYSTEM=systemd; LIVE=yes; RESTART_FAIL=no; RELOAD_FAIL=no; TIMER_FAIL=no
    CF_CUR_TOKEN_FILE=""; CF_TOKEN_BACKUP_PATH=""; CF_TIMER_WAS_ENABLED=""; CF_TIMER_WAS_ACTIVE=""
    printf no > "$TMP/timer-present"; printf off > "$TMP/timer-enabled"; printf off > "$TMP/timer-active"
    printf 0 > "$TMP/restarts"; : > "$TMP/systemctl"; : > "$TMP/messages"; : > "$TMP/success"
    rm -f "$TMP/reload-failed" "$TMP/timer-failed" "$CF_UNIT_SYSTEMD" "$CF_UNIT_SYSTEMD.bak" "$CF_UNIT_OPENRC" "$TMP/token" "$TMP/token.bak" "$STATE_DIR/cf_autoupdate" "$STATE_DIR/cf_http2" "$STATE_DIR/cf_edge_ip"
}
inline_fixture() { printf 'ExecStart=%s --no-autoupdate tunnel --protocol http2 run --token %s\n# stale token %s\nExecStop=%s cleanup --token %s\n' "$CF_BIN" "$OLD" "$OLD" "$CF_BIN" "$OLD" > "$CF_UNIT_SYSTEMD"; }
file_fixture() { printf '%s' "$OLD" > "$TMP/token"; printf 'ExecStart=%s --no-autoupdate tunnel --protocol http2 run --token-file %s/token\n' "$CF_BIN" "$TMP" > "$CF_UNIT_SYSTEMD"; }

reset_fixture
inline_fixture
run 0 _read_cf_state
check 'legacy inline read' eq "$CF_CUR_TOKEN" "$OLD"
check 'inline credential format preserved' eq "$CF_CUR_TOKEN_FILE" ''
run 0 _cf_switch_token <<< "$NEW"
check 'inline switch updates launch token' contains "$(cat "$CF_UNIT_SYSTEMD")" "run --token $NEW"
check 'comment token unchanged' contains "$(cat "$CF_UNIT_SYSTEMD")" "# stale token $OLD"
check 'ExecStop token unchanged' contains "$(cat "$CF_UNIT_SYSTEMD")" "cleanup --token $OLD"
check 'successful inline switch consumes backup' test ! -e "$CF_UNIT_SYSTEMD.bak"
check 'no duplicate plaintext state credential' test ! -e "$STATE_DIR/cf_token"

reset_fixture
file_fixture
run 0 _read_cf_state
check 'official token-file reads credential' eq "$CF_CUR_TOKEN" "$OLD"
check 'official credential file path' eq "$CF_CUR_TOKEN_FILE" "$TMP/token"
run 0 _cf_switch_token <<< "$NEW"
check 'token-file switch writes new credential' eq "$(cat "$TMP/token")" "$NEW"
check 'token-file switch preserves launch form' contains "$(cat "$CF_UNIT_SYSTEMD")" "--token-file $TMP/token"
check 'token-file does not migrate inline' no_contains "$(cat "$CF_UNIT_SYSTEMD")" "$NEW"
check 'token-file backup consumed after success' test ! -e "$TMP/token.bak"
check 'token-file mode limited to owner' eq "$(stat -c %a "$TMP/token")" 600
run 0 _cf_toggle http2
check 'toggle preserves token-file launch' contains "$(cat "$CF_UNIT_SYSTEMD")" "--token-file $TMP/token"
check 'HTTP2 off omits protocol option' no_contains "$(cat "$CF_UNIT_SYSTEMD")" --protocol
check 'HTTP2 off means auto in UI' contains "$(_cf_http2_disp off)" 'auto(默认, QUIC 优先)'
check 'IP off means unspecified in UI' contains "$(_cf_edge_ip_label off)" '未指定(默认 auto)'
run 0 _cf_set_edge_ip <<< 2
check 'IPv6 switch writes option before run' contains "$(cat "$CF_UNIT_SYSTEMD")" "--edge-ip-version 6 run --token-file"
run 0 _cf_set_edge_ip <<< 4
check 'IP off does not force edge version' no_contains "$(cat "$CF_UNIT_SYSTEMD")" --edge-ip-version

reset_fixture
file_fixture
run 0 _read_cf_state
before=$(cat "$CF_UNIT_SYSTEMD")
printf '%s\n' "$before" | sed 's/--token-file /--token-file=/' > "$CF_UNIT_SYSTEMD"
run 0 _read_cf_state
check 'inline-equals official token-file path reads' eq "$CF_CUR_TOKEN" "$OLD"
check 'token-file equals value preserved' eq "$CF_CUR_TOKEN_FILE" "$TMP/token"
run 0 _cf_switch_token <<< "$NEW"
check 'token-file equals switch preserves custom syntax' contains "$(cat "$CF_UNIT_SYSTEMD")" "--token-file=$TMP/token"

reset_fixture
file_fixture
chmod() {
    if [ "$2" = "$TMP/token" ] && [ ! -f "$TMP/chmod-failed" ]; then touch "$TMP/chmod-failed"; return 1; fi
    command chmod "$@"
}
run 1 _cf_switch_token <<< "$NEW"
unset -f chmod
check 'token-file permission failure restores old credential' eq "$(cat "$TMP/token")" "$OLD"
check 'token-file permission failure does not restart service' eq "$(cat "$TMP/restarts")" 0

reset_fixture
inline_fixture
run 0 _read_cf_state
check 'service install input skips official service-only update flag' eq "$(_extract_token "$CF_BIN service install --no-update-service $NEW")" "$NEW"

reset_fixture
file_fixture
RESTART_FAIL=yes
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_switch_token <<< "$NEW"
check 'restart failure restores token-file credential' eq "$(cat "$TMP/token")" "$OLD"
check 'restart failure restores service definition' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"
check 'rollback restarts original service' eq "$(cat "$TMP/restarts")" 2
check 'token-file restart failure never claims success' test ! -s "$TMP/success"

reset_fixture
inline_fixture
RELOAD_FAIL=yes
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_switch_token <<< "$NEW"
check 'daemon reload failure restores legacy service' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"
check 'reload failure skips restart' eq "$(cat "$TMP/restarts")" 0

reset_fixture
file_fixture
LIVE=no
run 1 _cf_switch_token <<< "$NEW"
check 'failed liveness restores token-file credential' eq "$(cat "$TMP/token")" "$OLD"
check 'failed rollback liveness reported' contains "$(cat "$TMP/messages")" '回滚未完成'
check 'failed liveness never claims success' test ! -s "$TMP/success"

reset_fixture
inline_fixture
RESTART_FAIL=yes
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_toggle http2
check 'legacy toggle restart failure restores service' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"
check 'failed toggle does not commit state' test ! -e "$STATE_DIR/cf_http2"

reset_fixture
printf 'ExecStart=%s --autoupdate-freq 24h0m0s tunnel --protocol http2 run --token %s\n' "$CF_BIN" "$OLD" > "$CF_UNIT_SYSTEMD"
printf yes > "$TMP/timer-present"
run 0 _cf_toggle http2
check 'HTTP2 toggle does not disable preexisting process updater for inactive timer' contains "$(cat "$CF_UNIT_SYSTEMD")" --autoupdate-freq
run 0 _read_cf_state
check 'HTTP2 toggle preserves effective update state' eq "$(_cf_autoupdate_effective)" on

reset_fixture
printf 'ExecStart=%s tunnel --protocol http2 run --token %s\n' "$CF_BIN" "$OLD" > "$CF_UNIT_SYSTEMD"
run 0 _cf_toggle http2
check 'HTTP2 toggle preserves absent autoupdate flags' no_contains "$(cat "$CF_UNIT_SYSTEMD")" --no-autoupdate
run 0 _read_cf_state
check 'absent autoupdate flags remain default-on' eq "$(_cf_autoupdate_effective)" on

reset_fixture
file_fixture
printf yes > "$TMP/timer-present"; printf on > "$TMP/timer-enabled"; printf on > "$TMP/timer-active"
run 0 _read_cf_state
check 'timer contributes to effective autoupdate even with no-autoupdate' eq "$(_cf_autoupdate_effective)" on
run 0 _cf_toggle autoupdate
check 'OFF disables timer startup' eq "$(cat "$TMP/timer-enabled")" off
check 'OFF stops active timer' eq "$(cat "$TMP/timer-active")" off
check 'OFF stops update worker' contains "$(cat "$TMP/systemctl")" 'stop cloudflared-update.service'
check 'OFF retains process no-autoupdate' contains "$(cat "$CF_UNIT_SYSTEMD")" --no-autoupdate
check 'OFF persists matching state' eq "$(cat "$STATE_DIR/cf_autoupdate")" off
run 0 _read_cf_state
check 'OFF effective state matches actual behavior' eq "$(_cf_autoupdate_effective)" off
run 0 _cf_toggle autoupdate
check 'ON enables timer' eq "$(cat "$TMP/timer-enabled")" on
check 'ON starts timer' eq "$(cat "$TMP/timer-active")" on
check 'timer owns updates rather than double process updater' no_contains "$(cat "$CF_UNIT_SYSTEMD")" --autoupdate-freq

reset_fixture
file_fixture
printf yes > "$TMP/timer-present"; printf on > "$TMP/timer-enabled"; printf on > "$TMP/timer-active"
RESTART_FAIL=yes
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_toggle autoupdate
check 'restart failure restores timer enabled state' eq "$(cat "$TMP/timer-enabled")" on
check 'restart failure restores timer active state' eq "$(cat "$TMP/timer-active")" on
check 'timer restart failure restores original service' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"
check 'timer restart failure leaves state uncommitted' test ! -e "$STATE_DIR/cf_autoupdate"

reset_fixture
file_fixture
printf yes > "$TMP/timer-present"; printf on > "$TMP/timer-enabled"; printf off > "$TMP/timer-active"
TIMER_FAIL=yes
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_toggle autoupdate
check 'timer action failure restores enabled state separately' eq "$(cat "$TMP/timer-enabled")" on
check 'timer action failure retains originally inactive state' eq "$(cat "$TMP/timer-active")" off
check 'timer action failure restores service' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"

reset_fixture
inline_fixture
run 0 _cf_toggle autoupdate
check 'no-timer legacy uses process update frequency' contains "$(cat "$CF_UNIT_SYSTEMD")" --autoupdate-freq
run 0 _read_cf_state
check 'no-timer legacy effective state on' eq "$(_cf_autoupdate_effective)" on
run 0 _cf_toggle autoupdate
check 'no-timer legacy off uses explicit no-autoupdate' contains "$(cat "$CF_UNIT_SYSTEMD")" --no-autoupdate

reset_fixture
run 0 _install_cloudflared <<< "$NEW"
check 'fresh install uses service-level no-update-service' contains "$(cat "$TMP/install-args")" "service install --no-update-service $NEW"
check 'fresh install retains official token-file' contains "$(cat "$CF_UNIT_SYSTEMD")" "run --token-file $TMP/token"
check 'fresh install defaults HTTP2 on' contains "$(cat "$CF_UNIT_SYSTEMD")" '--protocol http2 run'
check 'fresh install autoupdate off state' eq "$(cat "$STATE_DIR/cf_autoupdate")" off

reset_fixture
printf yes > "$TMP/timer-present"; printf on > "$TMP/timer-enabled"; printf on > "$TMP/timer-active"
run 0 _install_cloudflared <<< "$NEW"
check 'fresh install closes existing independent timer' eq "$(cat "$TMP/timer-enabled")" off
check 'fresh install stops existing independent timer' eq "$(cat "$TMP/timer-active")" off

# 安装关闭已有 timer 后的任何失败都须还原 enable/active 两个状态。
for install_failure in timer write restart liveness; do
    reset_fixture
    printf yes > "$TMP/timer-present"; printf on > "$TMP/timer-enabled"; printf on > "$TMP/timer-active"
    case "$install_failure" in
        timer) TIMER_FAIL=yes ;;
        write) RELOAD_FAIL=yes ;;
        restart) RESTART_FAIL=yes ;;
        liveness) LIVE=no ;;
    esac
    run 1 _install_cloudflared <<< "$NEW"
    check "install $install_failure failure restores timer enabled" eq "$(cat "$TMP/timer-enabled")" on
    check "install $install_failure failure restores timer active" eq "$(cat "$TMP/timer-active")" on
    check "install $install_failure failure does not commit autoupdate state" test ! -e "$STATE_DIR/cf_autoupdate"
done

reset_fixture
run 0 _cf_switch_token <<< "$NEW"
check 'registration backfill supports official token-file output' contains "$(cat "$CF_UNIT_SYSTEMD")" '--token-file'
check 'registration backfill writes requested credential' eq "$(cat "$TMP/token")" "$NEW"
check 'registration backfill consumes token backup' test ! -e "$TMP/token.bak"

reset_fixture
file_fixture
printf 'ExecStart=%s --no-autoupdate tunnel --grace-period 60s run --token-file %s/token\n' "$CF_BIN" "$TMP" > "$CF_UNIT_SYSTEMD"
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_toggle http2
check 'custom service toggle refuses lossy rewriting' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"
run 0 _cf_switch_token <<< "$NEW"
check 'custom service token-file switch preserves extra arguments' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"
check 'custom service token-file switch still succeeds' eq "$(cat "$TMP/token")" "$NEW"

reset_fixture
printf 'Environment=TUNNEL_TOKEN=%s\nExecStart=%s tunnel run\n' "$OLD" "$CF_BIN" > "$CF_UNIT_SYSTEMD"
before=$(cat "$CF_UNIT_SYSTEMD")
run 1 _cf_switch_token <<< "$NEW"
check 'unsupported Environment token not migrated' eq "$(cat "$CF_UNIT_SYSTEMD")" "$before"

reset_fixture
INIT_SYSTEM=openrc
printf 'command="%s"\ncommand_args="--no-autoupdate tunnel --protocol http2 run --token %s"\n' "$CF_BIN" "$OLD" > "$CF_UNIT_OPENRC"
run 0 _cf_switch_token <<< "$NEW"
check 'old OpenRC inline credentials supported' contains "$(cat "$CF_UNIT_OPENRC")" "--token $NEW\""
run 0 _cf_toggle http2
check 'OpenRC command_args stays shell-valid' bash -n "$CF_UNIT_OPENRC"
check 'OpenRC HTTP2 off removes protocol only' no_contains "$(cat "$CF_UNIT_OPENRC")" --protocol

printf 'cloudflared alignment: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
