#!/bin/bash
# =============================================================================
# lib/51-reality-pq.sh — Reality 后量子签名(ML-DSA-65)检测与配置
# 需求 R8:默认自动检测(非可选),学 mack-a/v2ray-agent 的 initRealityMldsa65
# 官方依据:Xray-docs-next/docs/config/transports/reality.md
#   - mldsa65Seed   (服务端,私钥 seed)
#   - mldsa65Verify (客户端,公钥,链接参数 pqv=)
#   - xray tls ping <域名:端口> 输出含 X25519MLKEM768 + 证书总长度 > 3500
#   - xray mldsa65 生成公私钥对
# 参照实现:mack-a/v2ray-agent install.sh L9590-9627
# ============================================================================

# ---------------------------------------------------------------------------
# 检测 target 是否适合启用后量子签名,适合则生成 mldsa65 密钥对
# 用法:_detect_reality_pq <target_domain:port>
# 输出(通过全局变量,供 50-nodes 取用):
#   PQ_SEED   / PQ_VERIFY  —— 满足条件时为密钥对;不满足时为空
#   PQ_REASON —— 不满足时的原因(供回显)
# 返回:0=已启用后量子;1=未启用(回显原因)
# ---------------------------------------------------------------------------
_detect_reality_pq() {
    local target="$1"
    PQ_SEED=""; PQ_VERIFY=""; PQ_REASON=""

    [ -x "$XRAY_BIN" ] || {
        PQ_REASON="Xray 未安装,无法检测后量子"
        return 1
    }
    [ -z "$target" ] && {
        PQ_REASON="未提供 target 域名"
        return 1
    }

    _info "检测 Reality 后量子兼容性: $target"
    local ping_out
    # 两次 ping(mack-a 同款:一次判 X25519MLKEM768,一次取证书长度)
    ping_out=$(XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" tls ping "$target" 2>/dev/null)

    if [ -z "$ping_out" ]; then
        PQ_REASON="xray tls ping 无输出(目标不可达或 xray 不支持 tls ping)"
        _warn "$PQ_REASON"
        return 1
    fi

    if ! echo "$ping_out" | grep -q "X25519MLKEM768"; then
        PQ_REASON="目标域名不支持 X25519MLKEM768,忽略 ML-DSA-65"
        _tip "$PQ_REASON"
        return 1
    fi

    local length
    length=$(echo "$ping_out" | grep "Certificate chain's total length:" | awk '{print $5}' | head -1)
    # 容错:不同版本输出列数可能不同,取最后一个数字
    if [ -z "$length" ] || ! [[ "$length" =~ ^[0-9]+$ ]]; then
        length=$(echo "$ping_out" | grep "Certificate chain's total length:" | grep -oE '[0-9]+' | tail -1)
    fi

    if [ -z "$length" ] || ! [[ "$length" =~ ^[0-9]+$ ]] || [ "$length" -le 3500 ]; then
        PQ_REASON="目标域名支持 X25519MLKEM768,但证书长度不足(${length:-未知} ≤ 3500),忽略 ML-DSA-65"
        _tip "$PQ_REASON"
        return 1
    fi

    # 满足条件:生成 mldsa65 密钥对
    _info "目标支持后量子(证书长度 ${length} > 3500),生成 ML-DSA-65 密钥对..."
    local mldsa_out
    mldsa_out=$("$XRAY_BIN" mldsa65 2>/dev/null)
    if [ -z "$mldsa_out" ]; then
        PQ_REASON="xray mldsa65 生成失败"
        _warn "$PQ_REASON"
        return 1
    fi
    # mack-a: head -1 取 Seed,tail -1 取 Verify(输出形如 "Seed: xxx" / "Verify: yyy")
    PQ_SEED=$(echo "$mldsa_out" | head -1 | awk '{print $2}')
    PQ_VERIFY=$(echo "$mldsa_out" | tail -n 1 | awk '{print $2}')

    if [ -z "$PQ_SEED" ] || [ -z "$PQ_VERIFY" ]; then
        # 兜底:按冒号后取值 (M17: 用 bash 参数扩展替代 sed -E, busybox 兼容)
        local seed_line="${mldsa_out%%$'\n'*}"
        local verify_line="${mldsa_out##*$'\n'}"
        PQ_SEED="${seed_line#*: }"
        PQ_VERIFY="${verify_line#*: }"
    fi

    if [ -z "$PQ_SEED" ] || [ -z "$PQ_VERIFY" ]; then
        PQ_REASON="解析 mldsa65 输出失败"
        _warn "$PQ_REASON"
        return 1
    fi

    _success "后量子签名已启用: mldsa65Seed / mldsa65Verify 已生成"
    return 0
}

# ---------------------------------------------------------------------------
# 给定 realitySettings 对象文本,按后量子检测结果注入 mldsa65Seed
# 由 50-nodes 在渲染模板时调用:若 PQ_SEED 非空,写入服务端 mldsa65Seed
# (客户端 mldsa65Verify 与 pqv= 链接参数由 50-nodes 直接用 PQ_VERIFY)
# ---------------------------------------------------------------------------
# 注:实际注入在 50-nodes 的模板渲染里用 jq 完成,本模块只负责检测产出密钥。
