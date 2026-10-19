#!/bin/bash
# lib/51-reality-pq.sh — 单次 tls ping 判定组名+证书长度，再本地生成ML-DSA-65。
# 官方 reality.md：X25519MLKEM768 且证书链>3500；服务端seed，客户端verify/pqv。

# 优先 timeout -k(TERM 被忽略时仍能 KILL)；busybox timeout 无 -k 则只能发 TERM；
# 宿主无 timeout 时无界直接执行, 属可接受风险。
_pq_run_bounded() {
    local secs="$1"; shift
    if ! command -v timeout >/dev/null 2>&1; then
        "$@" 2>/dev/null
        return $?
    fi
    # 探测用 5 秒, 避免负载下误判; 被测命令 stderr 静音(调用方只消费 stdout 与返回码)。
    if timeout -k 1 5 true >/dev/null 2>&1; then
        timeout -k 2 "$secs" "$@" 2>/dev/null
        return $?
    fi
    timeout "$secs" "$@" 2>/dev/null
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
                # 同时剥尾部空白(含 CRLF 的 CR), 否则长度/字符集校验会误判为未知。
                val="${val%"${val##*[![:space:]]}"}"
                [ -n "$val" ] && { printf '%s' "$val"; return 0; }
                ;;
        esac
    done <<< "$text"
    return 1
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
    # 同一次 tls ping 同时读取组名和链长；宿主有 timeout 时经 _pq_run_bounded 限时15秒,
    # 无 timeout 时无界执行。返回码非0或输出为空即判未知, 不使用半截stdout。
    # 不在此处吞 stderr: 被测命令的 stderr 由 _pq_run_bounded 内部静音, 本函数只消费 stdout 与返回码。
    ping_out=$(_pq_run_bounded 15 env XRAY_LOCATION_ASSET= "$XRAY_BIN" tls ping "$target") || ping_rc=$?

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

    # mldsa65 是本地命令；宿主有 timeout 时经 _pq_run_bounded 限时, 否则直接执行。
    _info "目标支持后量子(证书长度 ${length} > 3500),生成 ML-DSA-65 密钥对..."
    local mldsa_out mldsa_rc=0
    mldsa_out=$(_pq_run_bounded 15 env XRAY_LOCATION_ASSET= "$XRAY_BIN" mldsa65 2>/dev/null) || mldsa_rc=$?
    if [ "$mldsa_rc" -ne 0 ] || [ -z "$mldsa_out" ]; then
        PQ_REASON="xray mldsa65 生成失败, 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    # 按标签取不同的seed/verify；行序、横幅或缺失输出不能伪造有效密钥。
    local pq_seed pq_verify
    pq_seed=$(_pq_field "$mldsa_out" seed) || pq_seed=""
    pq_verify=$(_pq_field "$mldsa_out" verify) || pq_verify=""

    if [ -z "$pq_seed" ] || [ -z "$pq_verify" ] || [ "$pq_seed" = "$pq_verify" ]; then
        PQ_REASON="解析 mldsa65 输出失败(Seed/Verify 缺失或相同), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    # Sampled Xray v25.9.11/v25.12.8/v26.3.27/v26.7.11/v26.9.9 emit RawURLEncoding: seed=32B, public key=1952B.
    # 43/2603 即该编码的 32B/1952B 长度; 长度或字符集不符一律按未知(rc=2, 保留已有 PQ 配置)。
    local _rawurl_re='^[A-Za-z0-9_-]+$'
    if [ "${#pq_seed}" -ne 43 ] || [ "${#pq_verify}" -ne 2603 ] \
       || ! [[ "$pq_seed" =~ $_rawurl_re ]] || ! [[ "$pq_verify" =~ $_rawurl_re ]]; then
        PQ_REASON="mldsa65 输出格式异常(非预期的 RawURLEncoding 长度/字符集), 无法判定 PQ 能力"
        _warn "$PQ_REASON"
        return 2
    fi
    # 结果经全局传递: 50-nodes/90-menu 在 rc=0 时读取这两个值。
    # shellcheck disable=SC2034
    PQ_SEED=$pq_seed
    # shellcheck disable=SC2034
    PQ_VERIFY=$pq_verify
    _success "后量子签名已启用: mldsa65Seed / mldsa65Verify 已生成"
    return 0
}

# seed仅由50-nodes模板jq注入服务端；客户端verify/pqv由50-nodes导出，不在本模块写配置。
