#!/usr/bin/env bash
# 安装器 HTTPS 下载约束与 staging 复核回归。
# shellcheck disable=SC2329,SC2034
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/xray-installer-alignment.XXXXXX") || exit 1
trap 'rm -rf "${TMP:?}"' EXIT

PASS=0
FAIL=0
check() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        printf '  ok - %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL - %s\n' "$name"
    fi
}

# install.sh 顶层会做 root 检查并进入安装流程，这里只抽取待测函数。
eval "$(sed -n '/^dl() {/,/^}$/p' "$ROOT/install.sh")"
eval "$(sed -n '/^_validate_stage() {/,/^}$/p' "$ROOT/install.sh")"

LIB_MODULES="00-common 10-system"
TPL_NAMES="tpl"

# 下载器桩：记录参数并把 -o/-O 目标写成非空文件。
mkdir -p "$TMP/bin" || exit 1
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
[ "${CURL_FAIL:-0}" = 1 ] && exit 1
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$out" ] || exit 1
printf 'ok\n' > "$out"
EOF
cat > "$TMP/bin/wget" <<'EOF'
#!/usr/bin/env bash
[ -n "${WGET_LOG:-}" ] && printf '%s\n' "$*" >> "$WGET_LOG"
exit 1
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/wget" || exit 1

PATH="$TMP/bin:$PATH"

# dl: HTTP 入口必须在调用下载器前拒绝。
dl_rejects_http() (
    rm -f "$TMP/curl.log" "$TMP/wget.log" "$TMP/dl-http"
    CURL_LOG="$TMP/curl.log" WGET_LOG="$TMP/wget.log" \
        dl 'http://example.test/file' "$TMP/dl-http" >/dev/null 2>&1 && return 1
    [ ! -e "$TMP/curl.log" ] && [ ! -e "$TMP/wget.log" ] && [ ! -e "$TMP/dl-http" ]
)

# dl: HTTPS 下载使用 curl 的协议约束。
dl_applies_https_flags() (
    rm -f "$TMP/curl.log" "$TMP/dl-https"
    CURL_LOG="$TMP/curl.log" dl 'https://example.test/file' "$TMP/dl-https" >/dev/null 2>&1 || return 1
    [ -s "$TMP/dl-https" ] || return 1
    grep -Fq -- '--proto =https' "$TMP/curl.log" &&
        grep -Fq -- '--proto-redir =https' "$TMP/curl.log" &&
        grep -Fq -- '--connect-timeout 8' "$TMP/curl.log"
)

# dl: curl 存在时失败即结束，不再回退 wget，也不留下半截文件。
dl_does_not_fallback_when_curl_fails() (
    rm -f "$TMP/curl.log" "$TMP/wget.log" "$TMP/dl-fail"
    CURL_LOG="$TMP/curl.log" WGET_LOG="$TMP/wget.log" CURL_FAIL=1 \
        dl 'https://example.test/file' "$TMP/dl-fail" >/dev/null 2>&1 && return 1
    [ -e "$TMP/curl.log" ] && [ ! -e "$TMP/wget.log" ] && [ ! -e "$TMP/dl-fail" ]
)

. "$ROOT/lib/00-common.sh"

# _http_download: 与 dl 保持同一 HTTPS 入口约束。
http_download_rejects_http() (
    rm -f "$TMP/curl.log" "$TMP/wget.log" "$TMP/common-http"
    CURL_LOG="$TMP/curl.log" WGET_LOG="$TMP/wget.log" \
        _http_download 'http://example.test/file' "$TMP/common-http" 5 >/dev/null 2>&1 && return 1
    [ ! -e "$TMP/curl.log" ] && [ ! -e "$TMP/wget.log" ] && [ ! -e "$TMP/common-http" ]
)

# _http_download: HTTPS 下载使用 curl 的协议约束。
http_download_applies_https_flags() (
    rm -f "$TMP/curl.log" "$TMP/common-https"
    CURL_LOG="$TMP/curl.log" _http_download 'https://example.test/file' "$TMP/common-https" 7 >/dev/null 2>&1 || return 1
    [ -s "$TMP/common-https" ] || return 1
    grep -Fq -- '--proto =https' "$TMP/curl.log" &&
        grep -Fq -- '--proto-redir =https' "$TMP/curl.log" &&
        grep -Fq -- '--connect-timeout 8' "$TMP/curl.log" &&
        grep -Fq -- '--max-time 7' "$TMP/curl.log"
)

# _http_download: curl 存在时失败即结束，不再回退 wget。
http_download_does_not_fallback_when_curl_fails() (
    rm -f "$TMP/curl.log" "$TMP/wget.log" "$TMP/common-fail"
    CURL_LOG="$TMP/curl.log" WGET_LOG="$TMP/wget.log" CURL_FAIL=1 \
        _http_download 'https://example.test/file' "$TMP/common-fail" 5 >/dev/null 2>&1 && return 1
    [ -e "$TMP/curl.log" ] && [ ! -e "$TMP/wget.log" ] && [ ! -e "$TMP/common-fail" ]
)

make_stage() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/lib" "$dir/templates" "$dir/support" || return 1
    printf '0.19.8\n' > "$dir/VERSION"
    printf '#!/usr/bin/env bash\ntrue\n' > "$dir/xray-deploy.sh"
    printf '#!/usr/bin/env bash\ntrue\n' > "$dir/lib/00-common.sh"
    printf '#!/usr/bin/env bash\ntrue\n' > "$dir/lib/10-system.sh"
    printf '{}\n' > "$dir/templates/tpl.server.jsonc"
    printf 'print("ok")\n' > "$dir/support/outbound_link.py"
}

stage_accepts_valid_source() (
    make_stage "$TMP/stage-ok" || return 1
    _validate_stage "$TMP/stage-ok" >/dev/null 2>&1
)

stage_rejects_bad_version() (
    make_stage "$TMP/stage-version" || return 1
    printf '0.19\n' > "$TMP/stage-version/VERSION"
    ! _validate_stage "$TMP/stage-version" >/dev/null 2>&1
)

stage_rejects_missing_version() (
    make_stage "$TMP/stage-no-version" || return 1
    rm -f "$TMP/stage-no-version/VERSION"
    ! _validate_stage "$TMP/stage-no-version" >/dev/null 2>&1
)

stage_rejects_missing_template() (
    make_stage "$TMP/stage-no-template" || return 1
    rm -f "$TMP/stage-no-template/templates/tpl.server.jsonc"
    ! _validate_stage "$TMP/stage-no-template" >/dev/null 2>&1
)

stage_rejects_missing_support() (
    make_stage "$TMP/stage-no-support" || return 1
    rm -f "$TMP/stage-no-support/support/outbound_link.py"
    ! _validate_stage "$TMP/stage-no-support" >/dev/null 2>&1
)

stage_rejects_bad_shell() (
    make_stage "$TMP/stage-shell" || return 1
    printf 'if then\n' > "$TMP/stage-shell/lib/10-system.sh"
    ! _validate_stage "$TMP/stage-shell" >/dev/null 2>&1
)

stage_rejects_bad_python() (
    make_stage "$TMP/stage-python" || return 1
    printf 'def broken(\n' > "$TMP/stage-python/support/outbound_link.py"
    ! _validate_stage "$TMP/stage-python" >/dev/null 2>&1
)

stage_rejects_missing_lib() (
    make_stage "$TMP/stage-missing" || return 1
    rm -f "$TMP/stage-missing/lib/10-system.sh"
    ! _validate_stage "$TMP/stage-missing" >/dev/null 2>&1
)

stage_validation_precedes_backup() {
    awk '
        /^download_all\(\)/ { in_download=1 }
        in_download && $0 !~ /^[[:space:]]*#/ && /_validate_stage "\$stage"/ { validate=NR }
        in_download && $0 !~ /^[[:space:]]*#/ && /_install_backup/ { backup=NR; exit }
        END { exit !(validate && backup && validate < backup) }
    ' "$ROOT/install.sh" &&
    awk '
        /^if \[ -f .*LOCAL_DIR.*xray-deploy\.sh/ { in_local=1 }
        in_local && $0 !~ /^[[:space:]]*#/ && /_validate_stage "\$LOCAL_DIR"/ { validate=NR }
        in_local && $0 !~ /^[[:space:]]*#/ && /_install_backup/ { backup=NR; exit }
        END { exit !(validate && backup && validate < backup) }
    ' "$ROOT/install.sh"
}

check 'dl rejects non-HTTPS URL before downloader' dl_rejects_http
check 'dl applies curl HTTPS protocol constraints' dl_applies_https_flags
check 'dl does not fall back to wget when curl fails' dl_does_not_fallback_when_curl_fails
check '_http_download rejects non-HTTPS URL before downloader' http_download_rejects_http
check '_http_download applies curl HTTPS protocol constraints' http_download_applies_https_flags
check '_http_download does not fall back to wget when curl fails' http_download_does_not_fallback_when_curl_fails
check 'staging accepts complete source' stage_accepts_valid_source
check 'staging rejects non-semver VERSION' stage_rejects_bad_version
check 'staging rejects missing VERSION' stage_rejects_missing_version
check 'staging rejects missing template' stage_rejects_missing_template
check 'staging rejects missing support file' stage_rejects_missing_support
check 'staging rejects shell syntax error' stage_rejects_bad_shell
check 'staging rejects Python syntax error' stage_rejects_bad_python
check 'staging rejects missing module' stage_rejects_missing_lib
check 'staging validation precedes backup in remote and local installs' stage_validation_precedes_backup

printf 'installer alignment passed %s, failed %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
