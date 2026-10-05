#!/bin/bash
# lib/51-reality-pq.sh — 单次 tls ping 判定组名+证书长度，再本地生成ML-DSA-65。
# 官方 reality.md：X25519MLKEM768 且证书链>3500；服务端seed，客户端verify/pqv。

# 基础设施失败用文件标志跨命令替换子shell；返回125也可能来自真实命令，不能单独判错。
_pq_infra_flag_file() {
    printf '%s' "${STATE_DIR:-${TMPDIR:-/tmp}}/.xray-deploy-pq-infra.$$"
}
# 进入时清残留(上一次调用的失败不得污染这一次)
_pq_infra_clear() { rm -f "$(_pq_infra_flag_file)" 2>/dev/null; }
# 置位(唯一写入点)
_pq_infra_mark() { : > "$(_pq_infra_flag_file)" 2>/dev/null || true; }
# 调用方判据(唯一读取点)
_pq_infra_failed() { [ -e "$(_pq_infra_flag_file)" ]; }

# _pq_run_bounded <秒> <命令...> 保留stdout/返回码，超时124。
# 优先 timeout -k，缺失/不支持硬杀则后台看门狗；临时文件失败置标志并返回125。
_pq_fallback_stop() {
    local pid="$1" pidfile="$2" use_setsid="$3" child_pgid=""
    if [ "$use_setsid" -eq 1 ]; then
        # setsid --wait may fork under job control; let its wrapper record the real session leader.
        if [ -n "$pidfile" ] && [ ! -s "$pidfile" ] && kill -0 "$pid" 2>/dev/null; then
            sleep 1
        fi
        [ -n "$pidfile" ] && child_pgid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ "$child_pgid" =~ ^[0-9]+$ ]] && [ "$child_pgid" -gt 1 ]; then
            kill -9 -- "-$child_pgid" 2>/dev/null || true
        fi
    elif command -v pkill >/dev/null 2>&1; then
        pkill -9 -P "$pid" 2>/dev/null || true
    fi
    kill -9 "$pid" 2>/dev/null || true
}

_pq_fallback_cleanup() {
    local rc=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [ -n "${_pq_bounded_pid:-}" ]; then
        _pq_fallback_stop "$_pq_bounded_pid" "${_pq_bounded_pidfile:-}" "${_pq_bounded_use_setsid:-0}"
        wait "$_pq_bounded_pid" 2>/dev/null || true
    fi
    [ -n "${_pq_bounded_tmp:-}" ] && rm -f "$_pq_bounded_tmp"
    [ -n "${_pq_bounded_pidfile:-}" ] && rm -f "$_pq_bounded_pidfile"
    exit "$rc"
}

_pq_fallback_signal() { exit "$1"; }

_pq_run_bounded() {
    local secs="$1"; shift
    _pq_infra_clear
    if command -v timeout >/dev/null 2>&1; then
        # 仅使用支持 -k 的timeout；TERM被忽略时仍需KILL，探测用5秒避免负载误判。
        if timeout -k 1 5 true >/dev/null 2>&1; then
            timeout -k 2 "$secs" "$@"
            return $?
        fi
    fi
    # 无timeout或不支持-k走同一硬杀看门狗；不能退回无硬杀timeout。
    (
    local tmp rc use_setsid=0 pidfile="" i=0
    local _pq_bounded_tmp="" _pq_bounded_pidfile="" _pq_bounded_pid="" _pq_bounded_use_setsid=0
    # The fallback runs in this function's subshell so these traps never replace caller traps.
    trap _pq_fallback_cleanup EXIT
    trap '_pq_fallback_signal 129' HUP
    trap '_pq_fallback_signal 130' INT
    trap '_pq_fallback_signal 143' TERM
    # mktemp failure is distinct from a wrapped command failure (125).
    tmp=$(mktemp) || { _pq_infra_mark; _warn "无法创建临时文件(磁盘满/只读?), 无法有界执行"; exit 125; }
    _pq_bounded_tmp=$tmp
    if command -v setsid >/dev/null 2>&1 && setsid --wait true >/dev/null 2>&1; then
        use_setsid=1
        _pq_bounded_use_setsid=1
        pidfile=$(mktemp) || { _pq_infra_mark; _warn "无法创建进程跟踪文件(磁盘满/只读?), 无法有界执行"; exit 125; }
        _pq_bounded_pidfile=$pidfile
        # The wrapper records the actual session leader: setsid --wait can fork under job control.
        { setsid --wait sh -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ "$pidfile" "$@" > "$tmp" 2>/dev/null & _pq_bounded_pid=$!; }
    else
        { "$@" > "$tmp" 2>/dev/null & _pq_bounded_pid=$!; }
    fi
    while kill -0 "$_pq_bounded_pid" 2>/dev/null && [ "$i" -lt "$secs" ]; do
        sleep 1; i=$((i+1))
    done
    if kill -0 "$_pq_bounded_pid" 2>/dev/null; then
        _pq_fallback_stop "$_pq_bounded_pid" "$pidfile" "$use_setsid"
        wait "$_pq_bounded_pid" 2>/dev/null || true
        _pq_bounded_pid=""
        exit 124
    fi
    if wait "$_pq_bounded_pid"; then rc=0; else rc=$?; fi
    _pq_bounded_pid=""
    cat "$tmp" 2>/dev/null
    exit "$rc"
    )
}

# 按大小写不敏感标签取 seed/verify；兼容冒号、空格与等号，缺失返回1。
_pq_field() {
    local text="$1" want="$2" line val
    while IFS= read -r line; do
        # 去掉行首空白后比较标签前缀(大小写不敏感)
        local t="${line#"${line%%[![:space:]]*}"}"
        case "${t,,}" in
            "${want}:"*|"${want} "*|"${want}="*)
                # 依次剥分隔符、空白、分隔符；Seed : xxx 必须只留下值。
                val="${t#*[: =]}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val#[:=]}"
                val="${val#"${val%%[![:space:]]*}"}"
                [ -n "$val" ] && { printf '%s' "$val"; return 0; }
                ;;
        esac
    done <<< "$text"
    return 1
}

_pq_rawurl_decoded_length() {
    local encoded="$1" decoded_len
    decoded_len=$(set -o pipefail; printf '%s=' "$encoded" | tr '_-' '/+' | base64 -d 2>/dev/null | wc -c) || return 1
    decoded_len="${decoded_len//[[:space:]]/}"
    [[ "$decoded_len" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$decoded_len"
}

# _detect_reality_pq <target> 输出 PQ_SEED/PQ_VERIFY/PQ_REASON。
# 返回0已生成、1探测成功且明确不支持、2探测/取键失败未知；2必须保留已有PQ配置。
_detect_reality_pq() {
    local target="$1"
    PQ_SEED=""; PQ_VERIFY=""; PQ_REASON=""

    [ -x "$XRAY_BIN" ] || {
        PQ_REASON="Xray 未安装,无法检测后量子"
        return 2
    }
    [ -z "$target" ] && {
        PQ_REASON="未提供 target 域名"
        return 2
    }

    _info "检测 Reality 后量子兼容性: $target"
    local ping_out ping_rc=0
    # 同一次 tls ping 同时读取组名和链长；网络探测用15秒有界wrapper，失败不使用半截stdout。
    ping_out=$(_pq_run_bounded 15 env XRAY_LOCATION_ASSET= "$XRAY_BIN" tls ping "$target" 2>/dev/null) || ping_rc=$?

    if _pq_infra_failed; then
        # 只查跨子shell标志文件；命令返回125不代表临时文件失败。
        PQ_REASON="无法创建临时文件(磁盘满/只读?), 未能执行 tls ping"
        _warn "$PQ_REASON"        # 调用方按返回码分流(见函数头三态契约), 不读 PQ_REASON
        return 2
    fi
    if [ "$ping_rc" -ne 0 ]; then
        PQ_REASON="xray tls ping 失败(目标不可达/超时/xray 不支持 tls ping), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    if [ -z "$ping_out" ]; then
        PQ_REASON="xray tls ping 无输出(目标不可达或 xray 不支持 tls ping), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi

    if ! echo "$ping_out" | grep -q "X25519MLKEM768"; then
        PQ_REASON="目标域名不支持 X25519MLKEM768,忽略 ML-DSA-65"
        _tip "$PQ_REASON"
        return 1
    fi

    # 只解析证书链长度标签后的首个数字；额外输出列不能改变>3500判定。
    local length
    length=$(echo "$ping_out" | grep "Certificate chain's total length:" \
        | head -1 | sed 's/.*total length:[^0-9]*\([0-9][0-9]*\).*/\1/')
    [[ "$length" =~ ^[0-9]+$ ]] || length=""

    if [ -z "$length" ]; then
        # 缺证书长度属探测未知，不能当明确不支持。
        PQ_REASON="xray tls ping 输出缺少证书链长度, 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    if [ "$length" -le 3500 ]; then
        PQ_REASON="目标域名支持 X25519MLKEM768,但证书长度不足(${length} ≤ 3500),忽略 ML-DSA-65"
        _tip "$PQ_REASON"
        return 1
    fi

    # mldsa65是本地命令；保留有界wrapper以限制进程执行时间。
    _info "目标支持后量子(证书长度 ${length} > 3500),生成 ML-DSA-65 密钥对..."
    local mldsa_out mldsa_rc=0
    mldsa_out=$(_pq_run_bounded 15 env XRAY_LOCATION_ASSET= "$XRAY_BIN" mldsa65 2>/dev/null) || mldsa_rc=$?
    if _pq_infra_failed; then
        # 与tls ping同样只查标志文件，独立于命令返回码。
        PQ_REASON="无法创建临时文件(磁盘满/只读?), 未能执行 mldsa65"
        _warn "$PQ_REASON"
        return 2
    fi
    if [ "$mldsa_rc" -ne 0 ] || [ -z "$mldsa_out" ]; then
        PQ_REASON="xray mldsa65 生成失败, 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    # 按标签取不同的seed/verify；行序、横幅或缺失输出不能伪造有效密钥。
    local pq_seed pq_verify seed_bytes verify_bytes
    pq_seed=$(_pq_field "$mldsa_out" seed) || pq_seed=""
    pq_verify=$(_pq_field "$mldsa_out" verify) || pq_verify=""

    if [ -z "$pq_seed" ] || [ -z "$pq_verify" ] || [ "$pq_seed" = "$pq_verify" ]; then
        PQ_REASON="解析 mldsa65 输出失败(Seed/Verify 缺失或相同), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    # Sampled Xray v25.9.11/v25.12.8/v26.3.27/v26.7.11/v26.9.9 emit RawURLEncoding: seed=32B, public key=1952B.
    local _rawurl_re='^[A-Za-z0-9_-]+$'
    if [ "${#pq_seed}" -ne 43 ] || [ "${#pq_verify}" -ne 2603 ] \
       || ! [[ "$pq_seed" =~ $_rawurl_re ]] || ! [[ "$pq_verify" =~ $_rawurl_re ]]; then
        PQ_REASON="mldsa65 输出格式异常(非预期的 RawURLEncoding 长度/字符集), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    seed_bytes=$(_pq_rawurl_decoded_length "$pq_seed") || seed_bytes=""
    verify_bytes=$(_pq_rawurl_decoded_length "$pq_verify") || verify_bytes=""
    if [ "$seed_bytes" != 32 ] || [ "$verify_bytes" != 1952 ]; then
        PQ_REASON="mldsa65 输出格式异常(Seed/Verify 解码长度不符), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi

    PQ_SEED=$pq_seed
    PQ_VERIFY=$pq_verify
    _success "后量子签名已启用: mldsa65Seed / mldsa65Verify 已生成"
    return 0
}

# seed仅由50-nodes模板jq注入服务端；客户端verify/pqv由50-nodes导出，不在本模块写配置。
