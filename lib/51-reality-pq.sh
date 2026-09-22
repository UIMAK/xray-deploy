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

# 有界执行的"基础设施失败"标志(见 _pq_run_bounded 的契约)。
#
# **通道必须是文件, 不能是 shell 变量**(2026-09-22 九轮 OCR #36)。
# 上游调用点写的是 `ping_out=$(_pq_run_bounded ...) || ping_rc=$?` —— 命令替换在**子 shell**
# 里执行, 函数里对 `_PQ_RUN_INFRA` 的赋值随子 shell 一起消失; 调用方读到的永远是模块级
# 那个空串, 于是"基础设施失败"这一支是**死代码**, mktemp 失败会被报成"xray tls ping 失败"
# (排障方向直接跑偏 —— 这正是当初引入该标志要解决的问题, 却因为通道选错而没生效)。
# 现改为**标志文件**: 跨子 shell 可见, 且只有一个写入点、一个读取点、一个清理点。
# 位置优先 `$STATE_DIR`(部署目录, root 拥有), 退化到 `${TMPDIR:-/tmp}`; 名字带 `$$`
# (bash 的子 shell 不改变 `$$`, 故父子同值)。
# **已声明的残局**: 若连一个 0 字节标记都写不下去(满盘/只读), 调用方仍只能拿到 rc=125
# 并报通用文案 —— 此时两个诊断都不准确, 但不会做出错误的状态变更(该分支只影响文案与返回码)。
_pq_infra_flag_file() {
    printf '%s' "${STATE_DIR:-${TMPDIR:-/tmp}}/.xray-deploy-pq-infra.$$"
}
# 进入时清残留(上一次调用的失败不得污染这一次)
_pq_infra_clear() { rm -f "$(_pq_infra_flag_file)" 2>/dev/null; }
# 置位(唯一写入点)
_pq_infra_mark() { : > "$(_pq_infra_flag_file)" 2>/dev/null || true; }
# 调用方判据(唯一读取点)
_pq_infra_failed() { [ -e "$(_pq_infra_flag_file)" ]; }

# ---------------------------------------------------------------------------
# 有界执行: 优先用 coreutils/busybox 的 timeout; 缺失时用"后台 + 看门狗"兜底。
# 为什么不能"没有 timeout 就裸跑": xray tls ping / mldsa65 都无内建超时, 目标网络
# 黑洞时会把整个菜单永久挂起 —— 这正是当初引入 timeout 要消除的危害, 裸跑等于
# 在最需要兜底的机器(裁剪版 busybox)上把危害原样留下。
# 用法:_pq_run_bounded <秒> <命令...>; stdout 同命令, 返回码同命令(超时=124)
#
# **基础设施失败走独立通道, 不靠返回码**(2026-09-21 复审 P3): mktemp 失败时旧实现返回 125
# 让调用方据此报"无法创建临时文件", 但被包裹的命令自身返回 125 时同样命中 —— 一个真实的
# xray 失败会被误报成磁盘问题, 排障方向直接跑偏。改为: 基础设施失败**置标志**
# (并仍返回 125 以示"这不是命令的正常结果"), 调用方**查标志**而不是比 125。
# 每次进入都先清标志, 避免上一次调用的残值污染这一次。
# **标志的载体是文件, 不是 shell 变量**(2026-09-22 九轮 OCR #36): 上游调用点全部写成
# `out=$(_pq_run_bounded ...)`, 命令替换的子 shell 会把变量赋值丢掉 —— 变量形态的标志
# 在真实调用路径上**永远读不到**(详见 _pq_infra_flag_file 上方说明)。
# ---------------------------------------------------------------------------
_pq_run_bounded() {
    local secs="$1"; shift
    _pq_infra_clear
    if command -v timeout >/dev/null 2>&1; then
        # -k <grace>: 先 TERM, grace 秒后 KILL。**没有 -k 时 timeout 并不"有界"** —— 子进程
        # 忽略/延迟处理 TERM 时它会一直等到对方自己退出(实测: 忽略 TERM 的子进程让
        # `timeout 1` 实际耗时 47s), 于是"有界执行"在最需要它的场景下失效。
        # busybox 的 timeout 不支持 -k, 故先探测再用; 不支持则**落到下面的 setsid 看门狗路径**。
        # 探测必须用**宽松**的超时: 0.1s 在负载高的机器上连 `true` 都跑不完, timeout 会
        # 合法地返回 124, 于是我们误判"不支持 -k"并退回无 -k 形式 —— 恰好在最需要它的
        # 机器上丢掉有界保护。这里只问"这个 timeout 认不认 -k", 不问"机器快不快"。
        # **不支持 -k 时不退回"没有硬杀"的 `timeout "$secs"`**(2026-09-22 十轮 P2)。
        # 那样写等于在最需要兜底的机器(BusyBox 版本较旧)上把"有界"降级成"等对方自己退出" ——
        # 而下面基于 setsid + 看门狗的兜底路径本来就为这种情况存在, 且它是真硬杀(-9)。
        # 宁可走一条更啰嗦但确实有界的路, 也不要留一条名义上有界、实际会被忽略 TERM 的子进程
        # 拖到天荒地老的 fast path。
        if timeout -k 1 5 true >/dev/null 2>&1; then
            timeout -k 2 "$secs" "$@"
            return $?
        fi
    fi
    # 走到这里有两种原因: 机器上没有 timeout, 或者有但不支持 -k(旧 busybox)。两条都需要
    # 真硬杀, 故共用下面的看门狗 —— 它的 kill -9 是不依赖 timeout 能力的。
    local tmp rc
    # mktemp 失败必须与"被包裹的命令失败"区分开(125): 否则调用方只会报
    # "xray tls ping 失败", 真正的原因(无法建临时文件)被掩盖, 排障时白绕一圈。
    tmp=$(mktemp) || { _pq_infra_mark; _warn "无法创建临时文件(磁盘满/只读?), 无法有界执行"; return 125; }
    # 放进独立进程组再后台执行: 被包裹的是 env + xray, 若 env 未 exec(部分精简
    # busybox)或命令自身 fork 子进程, 只 kill 直接子进程会留下孙进程继续占用资源。
    # **进程组隔离必须用 setsid --wait。**裸 `setsid cmd &` 不可用** —— setsid 只在自身不是
    # 进程组组长时 exec() 原地替换, 否则 fork 后立即退出, 于是 $! 是一个立刻死亡的 PID:
    # 看门狗 `kill -0 $!` 第一次就失败 → 直接走到 wait → **rc=0 且输出为空**(调用方误报
    # "tls ping 无输出"), 而真正的 xray 成为孤儿继续跑 —— 有界执行彻底失效。
    # 实测: `set -m; setsid sleep 5 & pid=$!` 中 pid 立即死亡。
    # `setsid --wait` 会等待子进程, 其 PID 就是可 wait/kill 的那个, 语义明确。
    # 无 setsid 时直接后台执行(PID 同样明确), 超时用 pkill -P 兜底孙进程。
    local use_setsid=0
    if command -v setsid >/dev/null 2>&1 && setsid --wait true >/dev/null 2>&1; then
        use_setsid=1
    fi
    if [ "$use_setsid" -eq 1 ]; then
        setsid --wait "$@" > "$tmp" 2>/dev/null &
    else
        "$@" > "$tmp" 2>/dev/null &
    fi
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$secs" ]; do
        sleep 1; i=$((i+1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        # 先按进程组整组杀(setsid --wait 时子进程自成一组, pgid == pid); 失败退回单 PID。
        # 最后补一次 pkill -P, 覆盖"命令自己 fork 了孙进程"的情况。
        kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
        if command -v pkill >/dev/null 2>&1; then
            pkill -9 -P "$pid" 2>/dev/null || true
        fi
        wait "$pid" 2>/dev/null || true
        rm -f "$tmp"
        return 124
    fi
    wait "$pid"; rc=$?
    cat "$tmp" 2>/dev/null
    rm -f "$tmp"
    return "$rc"
}

# 从 mldsa65 输出里按标签取值(不按行序)。
# 兼容 "Seed: xxx" / "Seed xxx" / 带缩进与大小写差异; 取不到输出空串。
# 用法:_pq_field <多行文本> seed|verify
_pq_field() {
    local text="$1" want="$2" line val
    while IFS= read -r line; do
        # 去掉行首空白后比较标签前缀(大小写不敏感)
        local t="${line#"${line%%[![:space:]]*}"}"
        case "${t,,}" in
            "${want}:"*|"${want} "*|"${want}="*)
                # 先剥分隔符, 再剥空白, 再剥一次分隔符: "Seed : xxx" 经 ${t#*[: =]}
                # 只吃掉第一个分隔符, 剩下的 ": xxx" 必须继续剥, 否则下游 base64 校验
                # 会拒掉这条本来合法的行(注释与行为必须一致)。
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
    local ping_out ping_rc=0
    # 两次 ping(mack-a 同款:一次判 X25519MLKEM768,一次取证书长度)。
    # 2026-09-12 实测加固: tls ping 无内建超时, 目标网络黑洞时菜单永久挂起 ——
    # 外包 timeout(Debian coreutils / busybox 均有)兜底; 超时按"不可达"处理。
    # 2026-09-20: timeout 缺失时也必须**有界**(旧写法直接裸跑, 正是本加固要消除的挂起),
    # 故统一走 _pq_run_bounded; 退出码也要看 —— 失败时可能仍有半截 stdout, 不能当成可达。
    ping_out=$(_pq_run_bounded 15 env XRAY_LOCATION_ASSET= "$XRAY_BIN" tls ping "$target" 2>/dev/null) || ping_rc=$?

    if _pq_infra_failed; then
        # 判据是**标志**而不是 125: xray 自己返回 125 时同样会命中 rc==125, 那会被误报成
        # 磁盘问题(2026-09-21 复审 P3)。标志由 _pq_run_bounded 只在"有界执行根本没起来"
        # (mktemp 失败)时置位, 与命令自身的返回码无关。
        # **必须查标志文件而不是变量**: 上面那行是命令替换(子 shell), 变量形态的标志读不到
        # (2026-09-22 九轮 OCR #36 —— 旧写法使这一支成为死代码)。
        PQ_REASON="无法创建临时文件(磁盘满/只读?), 未能执行 tls ping"
        _warn "$PQ_REASON"        # 与其它失败分支一致: 两个调用方都只看返回码, 不读 PQ_REASON
        return 1
    fi
    if [ "$ping_rc" -ne 0 ]; then
        PQ_REASON="xray tls ping 失败(目标不可达/超时/xray 不支持 tls ping)"
        _warn "$PQ_REASON"
        return 1
    fi
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

    # 只取标签后的数字: 旧写法先 awk 取固定列($5)再退化成"该行最后一个数字", 输出多一列
    # (版本号/比例等)时会静默用错值, 直接翻转 >3500 的判定。
    local length
    length=$(echo "$ping_out" | grep "Certificate chain's total length:" \
        | head -1 | sed 's/.*total length:[^0-9]*\([0-9][0-9]*\).*/\1/')
    [[ "$length" =~ ^[0-9]+$ ]] || length=""

    if [ -z "$length" ] || [ "$length" -le 3500 ]; then
        PQ_REASON="目标域名支持 X25519MLKEM768,但证书长度不足(${length:-未知} ≤ 3500),忽略 ML-DSA-65"
        _tip "$PQ_REASON"
        return 1
    fi

    # 满足条件:生成 mldsa65 密钥对(同样必须有界: 它也会挂起)
    _info "目标支持后量子(证书长度 ${length} > 3500),生成 ML-DSA-65 密钥对..."
    local mldsa_out mldsa_rc=0
    mldsa_out=$(_pq_run_bounded 15 env XRAY_LOCATION_ASSET= "$XRAY_BIN" mldsa65 2>/dev/null) || mldsa_rc=$?
    if _pq_infra_failed; then
        # 与 tls ping 侧同一口径: 查标志而不是比 125, 且必须经**文件**通道(见 #36)。
        PQ_REASON="无法创建临时文件(磁盘满/只读?), 未能执行 mldsa65"
        _warn "$PQ_REASON"
        return 1
    fi
    if [ "$mldsa_rc" -ne 0 ] || [ -z "$mldsa_out" ]; then
        PQ_REASON="xray mldsa65 生成失败"
        _warn "$PQ_REASON"
        return 1
    fi
    # 按**标签**取值, 不按行序: 旧写法 head -1/tail -1 在输出多一行横幅、少一行、或两行
    # 内容相同时会静默把 Seed/Verify 取成同一个值(实测单行输出即命中), 于是服务端私钥
    # 与客户端验证公钥相同 —— 节点看似创建成功, 后量子签名实际不可用。
    PQ_SEED=$(_pq_field "$mldsa_out" seed)
    PQ_VERIFY=$(_pq_field "$mldsa_out" verify)

    # 形状校验: 二者都必须非空、互不相同, 且是合法 base64(ML-DSA-65 密钥以 base64 呈现)。
    # 只做字符集与最小长度, 不硬编码具体长度 —— 避免核心更换参数时误伤。
    if [ -z "$PQ_SEED" ] || [ -z "$PQ_VERIFY" ] || [ "$PQ_SEED" = "$PQ_VERIFY" ]; then
        PQ_REASON="解析 mldsa65 输出失败(Seed/Verify 缺失或相同)"
        _warn "$PQ_REASON"
        return 1
    fi
    # 同时接受标准与 URL-safe 字母表: 官方 docs 记的是 base64.StdEncoding, 但下游把
    # pqv= 直接拼进分享链接(URL 上下文), 且不同版本/构建可能输出 URL-safe。放宽字母表
    # 只是"不误拒合法密钥"; 形状约束仍由长度与"非空且互不相同"保证。
    local _b64_re='^[A-Za-z0-9+/_-]+={0,2}$'
    if [ "${#PQ_SEED}" -lt 16 ] || [ "${#PQ_VERIFY}" -lt 16 ] \
       || ! [[ "$PQ_SEED" =~ $_b64_re ]] || ! [[ "$PQ_VERIFY" =~ $_b64_re ]]; then
        PQ_REASON="mldsa65 输出格式异常(非合法 base64), 已放弃"
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
