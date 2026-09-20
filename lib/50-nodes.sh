#!/bin/bash
# =============================================================================
# lib/50-nodes.sh — 节点管理(7 协议)
# 需求 R6(协议集) + R7(按节点改监听) + R8(Reality 后量子)
# 配置以官方为准(design.md 配置依据表), 模板在 templates/ 下, 占位符 {{...}} 渲染.
# 节点元数据: $NODES_DIR/<tag>.json (按节点独立文件, 便于 R7 单节点改监听)
# ============================================================================

# ---------------------------------------------------------------------------
# 协议清单(R6)
# ---------------------------------------------------------------------------
PROTOCOLS=(
    "vless-tcp-reality-vision|VLESS+TCP+Reality+Vision|reality|direct|可选直连/Tunnel(防偷跑)"
    "vless-xhttp-reality|VLESS+XHTTP+Reality|reality|direct|可选直连/Tunnel(防偷跑)"
    "vless-enc|VLESS+ENC|enc|direct|内置加密·类似SS·轻量无TLS"
    "vless-xhttp-cdn|VLESS+XHTTP(无TLS)|none|cdn|必须套CDN·禁止直连"
    "vless-ws-cdn|VLESS+WS(无TLS)|none|cdn|必须套CDN·禁止直连"
    "shadowsocks|Shadowsocks|none|direct|"
    "hysteria2|Hysteria2|tls|direct|必须套TLS证书·QUIC"
)

# ---------------------------------------------------------------------------
# 带宽格式化: 纯数字自动补 mbps 单位
# ---------------------------------------------------------------------------
_normalize_bandwidth() {
    local v="$1"
    [ -z "$v" ] && { echo ""; return; }
    # 纯数字 → 补 mbps
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "${v} mbps"
    # 短后缀展开: 1g→1 gbps, 10m→10 mbps (较新 Xray 可能拒绝裸短后缀, M10)
    elif [[ "$v" =~ ^[0-9]+g$ ]]; then
        echo "${v%g} gbps"
    elif [[ "$v" =~ ^[0-9]+m$ ]]; then
        echo "${v%m} mbps"
    else
        echo "$v"
    fi
}

# ---------------------------------------------------------------------------
# Hysteria2 混淆(FinalMask.udp)辅助
#
# 依据分三层(项目红线: 层与层不得混用, 注释必须点名来源; 用户 2026-09-15 明确接受
# mihomo 官方作为 clash 字段名的第三层依据, 以及"官方源码"作为 Xray 版本门控的依据):
#
# [Xray 官方] config/transports/finalmask.md「UDPMask」/「### salamander」/「#### gecko」:
#   "udp": [ { "type": "", "settings": {} } ]  —— 数组第一个为最内层伪装;
#   type = "salamander" 时 settings = { "password": ..., "packetSize": "512-1200" };
#   **packetSize 不为空则启用 Gecko**(对 QUIC 长包头额外分片填充), 上限不能超过 2048。
#   packetSize 为 Int32Range(development/intro/guide.md): "114" / "114-514" 引号内范围,
#   或独立 int(仅单数字); **From>To 会自动交换**; "" 视为 0。
#   Xray 官方文档**没有** `hysteriaSettings.obfs` 字段 —— 混淆只存在于 finalmask.udp。
#
# [Hysteria 2 官方] developers/URI-Scheme.md + advanced/Full-Client-Config.md:
#   URI scheme `hysteria2` 或 `hy2`; 参数 `obfs`(类型枚举: salamander|gecko)与
#   `obfs-password`; **URI 参数表中没有 gecko 的尺寸参数**(尺寸只存在于客户端配置文件的
#   `obfs.gecko.minPacketSize` / `maxPacketSize`)。
#   Gecko 客户端尺寸: minPacketSize 默认 512, maxPacketSize 默认 1200,
#   **必须 max >= min 且 max <= 2048**。
#
# [mihomo 官方] Meta-Docs config/proxies/hysteria2 + 源码 adapter/outbound/hysteria2.go:
#   proxy 字段名 `obfs` / `obfs-password` / `obfs-min-packet-size` / `obfs-max-packet-size`;
#   源码里尺寸字段**只在 `case ObfsTypeGecko` 分支被读取**(salamander 分支只取密码)。
#
# 尺寸文本的**唯一规范化入口是 _hy2_obfs_size_canon**: 三个消费者(Xray config 的
# packetSize、mihomo 的 obfs-min/max-packet-size、菜单/链接回显)必须看到**同一个**已排序
# 区间。否则 `1500-800` 会在 Xray 侧被自动交换成 800-1500, 而 mihomo 侧照抄成
# min=1500/max=800 —— 违反 Hysteria 官方 max>=min 约束的非法客户端配置。
# ---------------------------------------------------------------------------

# packetSize 文本规范化(唯一入口): 去空格 → 解析 → 排序(Int32Range 语义) → 去前导零 → 规范形式。
# 输出: ""(未填/表示不启用 gecko) 或 "N" / "min-max"(min<=max, 十进制无前导零)。
# 非法返回 1 且**无输出**(调用方必须消费返回码, 不得把空输出当"未启用")。
# 用法: canon=$(_hy2_obfs_size_canon <raw>)
_hy2_obfs_size_canon() {
    local raw="$1" a b
    raw="${raw// /}"                      # 去掉空格, 便于接受 "512 - 1200" 这类写法
    [ -z "$raw" ] && return 0
    if [[ "$raw" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    elif [[ "$raw" =~ ^[0-9]+$ ]]; then
        a="$raw"; b="$raw"
    else
        return 1
    fi
    # 先做长度门限再比较: bash 的 [ 对 >= 2^63 的整数会报 "integer expected" 且返回非零,
    # 不设门限时超大输入会被静默判为"合法"(实测 20 位数字), 直到核心侧 Int32Range 解析
    # 失败才暴露(白等一次 8 秒重启回滚)。10 位门限只是**防 bash 溢出**, 不等于 int32 上界;
    # 真正的范围上界由调用方的 _hy2_obfs_size_invalid(To<=2048)兜住。
    [ "${#a}" -le 10 ] && [ "${#b}" -le 10 ] || return 1
    # 去前导零(十进制字面量规范化): "008" → "8"。Xray 的 Int32Range 按数值解释, 前导零本
    # 无影响; 但同一区间会同时写进 metadata 与外部 YAML(clash), 各解析器对前导零的处理
    # 未必一致 ⇒ 在唯一入口就归一, 让所有下游看到同一字面量。用 10# 强制十进制, 避免
    # bash 把 "008" 当八进制(那会让 008/0010 直接报错)。
    a=$((10#$a)); b=$((10#$b))
    # Int32Range: From>To 自动交换 —— 规范化阶段就交换, 使所有下游看到同一区间
    if [ "$a" -gt "$b" ]; then local t="$a"; a="$b"; b="$t"; fi
    if [ "$a" = "$b" ]; then echo "$a"; else echo "${a}-${b}"; fi
}

# packetSize 合法性判定: 输出 ""(合法/未填) 或人类可读原因。
# 规则: 数字或 "min-max"; 非空启用 gecko 时 To<=2048(Xray 官方 finalmask.md「#### gecko」
# 明文的硬上限)。**From>=1 是本脚本自身的输入限制, 不是两个官方文档写明的统一硬限制** ——
# Xray 的 Int32Range 通用定义允许 ""(视为 0)且未给所有字段规定"不能为 0"; Hysteria 官方
# gecko 段落只写 max>=min 且 max<=2048。0 长度分片无意义, 故脚本层拒绝并如实说明来源。
# 先做形式检查再规范化, 使"格式错"与"数值超范围"给出**不同**的原因
# (canon 对两者都返回 1, 直接透传会把 20 位数字误报成格式错)。
_hy2_obfs_size_invalid() {
    local raw="$1" canon
    raw="${raw// /}"
    [ -z "$raw" ] && return 0
    if ! [[ "$raw" =~ ^[0-9]+$ || "$raw" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo "packetSize 只能是数字或 \"min-max\" 形式"
        return 0
    fi
    canon=$(_hy2_obfs_size_canon "$raw") || { echo "数值超出 Int32Range 可表示范围"; return 0; }
    local a="${canon%%-*}" b="${canon##*-}"
    if [ "$a" -le 0 ]; then
        echo "本脚本要求最小值 >= 1(0 长度分片无意义)"
    elif [ "$b" -gt 2048 ]; then
        echo "最大值不得超过 2048"
    fi
}

# 规范区间的最小值(裸数字, 用于 mihomo obfs-min-packet-size); 未填/非法 → 空。
_hy2_obfs_size_min() {
    local canon; canon=$(_hy2_obfs_size_canon "$1") || return 0
    [ -z "$canon" ] && return 0
    echo "${canon%%-*}"
}

# 规范区间的最大值(裸数字, 用于 mihomo obfs-max-packet-size); 未填/非法 → 空。
_hy2_obfs_size_max() {
    local canon; canon=$(_hy2_obfs_size_canon "$1") || return 0
    [ -z "$canon" ] && return 0
    echo "${canon##*-}"
}

# 读取元数据里的 packetSize 值(规范形式, 用于分享链接/clash/回显); 未设置 → 空
_hy2_obfs_size_get() {
    local meta="$1"
    jq -r '(.obfs_packet_size // "") | tostring' "$meta" 2>/dev/null
}

# --- metadata 的混淆语义(单一模型, 勿在别处另立) -------------------------------
# Xray 侧**没有** type:"gecko": gecko = type:"salamander" + 非空 packetSize
# (官方 finalmask.md: packetSize 非空即启用 Gecko)。因此 metadata 里:
#   obfs_type        = Xray 底层类型, 恒为 "salamander"(**不存 "gecko"**)
#   obfs_packet_size = Gecko 开关: null/空 = 普通 salamander; 非空 = gecko
# 类型枚举(salamander|gecko)是**客户端**侧的概念(Hysteria URI / mihomo), 由
# _hy2_obfs_kind 统一翻译, 调用方不要各自推断。
# ---------------------------------------------------------------------------

# Hysteria 官方 Full-Client-Config 的 gecko 尺寸默认值(minPacketSize 512 / maxPacketSize
# 1200; max>=min 且 max<=2048)。官方 URI 的 obfs 参数没有尺寸字段 ⇒ **URI 的隐含默认
# 就是这两个值**, 故只有恰好等于默认尺寸的 gecko 才能被 obfs=gecko 完整表达。
_HY2_GECKO_DEFAULT_SIZE="512-1200"

# 节点混淆形态(客户端视角): none | salamander | gecko。metadata 语义见上方注释。
# **严格枚举校验**: obfs_type 只认空串或 "salamander"; 其它值(手工改坏的 metadata)一律
# fail-closed 返回 1 且**无输出** —— 把它静默翻译成合法客户端配置会把损坏状态掩盖掉。
# 用法: kind=$(_hy2_obfs_kind <meta_file>) || 按"损坏"处理(拒绝生成, 保留旧值并报告)
_hy2_obfs_kind() {
    local meta="$1" otype
    otype=$(jq -r '.obfs_type // empty' "$meta" 2>/dev/null)
    case "$otype" in
        "")         echo "none"; return 0 ;;
        salamander)
            if [ -n "$(_hy2_obfs_size_get "$meta")" ]; then echo "gecko"; else echo "salamander"; fi
            return 0 ;;
        *)          return 1 ;;   # 未知 obfs_type ⇒ fail-closed
    esac
}

# 尺寸是否恰好等于官方默认(= 可被 obfs=gecko 完整表达); 未填/非法 → 1
_hy2_obfs_size_is_default() {
    local canon
    canon=$(_hy2_obfs_size_canon "$(_hy2_obfs_size_get "$1")") || return 1
    [ "$canon" = "$_HY2_GECKO_DEFAULT_SIZE" ]
}

# 该节点是否**无法用官方 hy2 URI 表达** = gecko + 自定义尺寸。
# 官方 URI 支持 obfs=gecko 但**没有尺寸参数**: 默认 512-1200 可表达; 自定义尺寸会让客户端
# 退回默认值去连非默认服务端(尺寸不一致) ⇒ 不可表达, 改由 clash 承载(它有独立尺寸字段)。
# 注意与"元数据缺字段"是两回事(后者应**保留**旧链接): _rebuild_hy2_link 对两者都返回 1,
# 调用方必须用本函数区分, 否则会误报原因并毁掉一条仍可用的旧链接。
_hy2_link_unexpressible() {
    # 损坏的 obfs_type(_hy2_obfs_kind rc≠0)按"**不是**不可表达"处理 —— 调用方会走
    # "保留旧链接 + 如实报告"分支(保守侧), 而不是清空一条可能仍可用的旧链接。
    [ "$(_hy2_obfs_kind "$1")" = "gecko" ] || return 1
    _hy2_obfs_size_is_default "$1" && return 1
    return 0
}

# ---------------------------------------------------------------------------
# finalmask.udp 的**自作用域**写过滤器(Xray 官方: udp 是数组, 第一个为最内层伪装,
# 因此它可以有多层 —— 我们只拥有自己写的那一层, 不是整个数组)。
# 全项目唯一副本; 90-menu 的启用/关闭/回滚三处都引用它, 不得各自复制(副本会漂移)。
#
#   $XD_UDP_OUR_TYPE     我们写入的层 type(Xray 侧 gecko 也是 type=salamander, 见下)
#   $XD_UDP_OUR_MARKER   我们写入的 settings 里的**归属标记**字段名
#   $XD_UDP_NEW          要写入的层对象(单个, 不是数组); $new == null 表示"剔除我们那层"
#
# **身份判定必须是正向标记, 不能只靠 `type == "salamander"`**: 该 type 是 Xray 的
# 官方伪装类型名, 任何用户/其它工具都可以在同一个 udp 数组里放自己的 salamander 层。
# 只按 type 匹配实际是"管理所有 salamander 层" —— 替换会吃掉别人的层, 关闭会一次删光,
# 与"只管理自己写的那一层"的契约不符。故我们写入的层带一个可自证的归属标记
# (settings.xd_managed = true), 识别与剔除都只认它; 它不影响 Xray(Go 的 json 解码
# 按 struct 字段取用, settings 里的未知键被忽略), 也不改变任何官方字段的语义。
# 兼容: 标记是我们自己上一版写下的层没有 —— 此时退化为"取 settings.password 存在且
# 无其它伪装类型特征的那一层"? 不: 不做模糊推断(会把别人的层误认成自己的),
# 而是**只在找到带标记的层时原位替换, 否则追加一层**; 无标记的旧层按"别人的层"保留。
# ---------------------------------------------------------------------------
XD_UDP_OUR_TYPE="salamander"
XD_UDP_OUR_MARKER="xd_managed"
XD_UDP_JQ_UPSERT='def xd_udp_ours($new): .streamSettings.finalmask.udp = ((.streamSettings.finalmask.udp // []) as $a | ($a | map(.type == $ourtype and (.settings // {})[$ourmark] == true) | index(true)) as $i | if $i == null then (if $new == null then $a else $a + [$new] end) else (if $new == null then $a[0:$i] + $a[$i+1:] else $a[0:$i] + [$new] + $a[$i+1:] end) end); (.inbounds[] | select(.tag == $t)) |= xd_udp_ours($new)'
# 兼容别名: 语义与 UPSERT($new=null) 完全相同 —— 保留独立常量只为调用点可读,
# 但**不得**再各自复制一份过滤逻辑(两份副本会漂移)。
XD_UDP_JQ_DROP="$XD_UDP_JQ_UPSERT"

# 外来 salamander 层探测(只读): 该入站的 finalmask.udp 里是否存在 type=salamander
# 但**没有**我们归属标记的层。存在时不得启用混淆 —— 追加我们那层会让 Xray 依次套两层
# salamander(双重混淆, 客户端只做一层 ⇒ 必然连不上), 而"删掉别人的层"更不可接受。
# 这是 fail-closed: 交给用户人工判断, 而不是替他猜。
# 用法: _hy2_udp_has_foreign_salamander <tag>; rc=0 表示存在
_hy2_udp_has_foreign_salamander() {
    local tag="$1"
    jq -e --arg t "$tag" --arg ourtype "$XD_UDP_OUR_TYPE" --arg ourmark "$XD_UDP_OUR_MARKER" \
        '[.inbounds[]? | select(.tag == $t) | (.streamSettings.finalmask.udp // [])[]
          | select(.type == $ourtype and (.settings // {})[$ourmark] != true)] | length > 0' \
        "$CONFIG_FILE" >/dev/null 2>&1
}

# 从 (type, password, packetSize) 构造 finalmask.udp 数组字面量
# 用法: _hy2_obfs_mask_block <type> <password> <packet_size_raw>
# 输出: 空(未启用) 或 {"type": ..., "settings": {...}}  (可直接放进 [ ])
# 生成的层带**归属标记** settings.xd_managed=true, 使 XD_UDP_JQ_UPSERT/DROP 能精确
# 认出"我们写的那一层"而不是"所有 type=salamander 的层"(见上面过滤器注释)。
# 失败(非法 packetSize)返回 1 —— 调用方必须消费返回码, 绝不能拿空输出当"无混淆"用:
# 回滚/关闭路径上把"解析失败"误当"无混淆"会静默清掉一个正在工作的混淆配置。
_hy2_obfs_mask_block() {
    local otype="$1" opw="$2" osize="$3" canon=""
    [ -z "$otype" ] && return 0
    canon=$(_hy2_obfs_size_canon "$osize") || return 1
    # 单值(如 "2048")与区间在 Int32Range 下等价; 区间时写成字符串, 单值时写裸数字。
    local size_json=""
    [ -n "$canon" ] && { case "$canon" in *-*) size_json="\"$canon\"" ;; *) size_json="$canon" ;; esac; }
    # 格式串必须是字面量: 第三个实参曾同时充当格式串, 一旦 size_json 的正则放宽就是
    # 用户可控的 printf 格式串注入。这里用 %s 逐个拼装, 用户数据永远只当数据。
    printf '%s' "{\"type\": \"${otype}\", \"settings\": {\"password\": \"${opw}\", \"${XD_UDP_OUR_MARKER}\": true${size_json:+, \"packetSize\": ${size_json}}}}"
}

# gecko(非空 packetSize)需要的最小核心版本 —— 版本门控, 与 R44/R45 同口径。
# **依据层级必须分清**: Xray 官方 llms-full.txt / docs **没有任何版本门控表述**
# ("文档未提及, 不能确认"); 下列版本来自**官方源码**逐 tag 核对
# infra/conf/transport_internet.go 的 json tag —— 属"源码事实", 不是"文档依据"。
# 用户 2026-09-15 明确接受"官方源码"作为 Xray 侧的第二依据(与文档依据分开声明)。
#   v26.3.27 / v26.4.13 / v26.4.15 / v26.4.17 / v26.4.25 / v26.5.3 / v26.5.9
#       Salamander{ Password }                                —— 无 packetSize 字段
#   v26.6.1   Salamander{ Password, PacketSize *Int32Range }  —— 非 nil 即 GeckoConfig
#   v26.7.11+ Salamander{ Password, PacketSize Int32Range }   —— 当前形态(To>0 即 Gecko)
# Go 的 encoding/json 静默忽略未识别字段 ⇒ 旧核心会把 packetSize 丢掉、退化成**无分片的
# salamander** 照常启动; 而按客户端 gecko 生成的条目连不上, 且报错发生在客户端一侧,
# 服务端日志干净 —— 典型的静默失效。故启用 gecko 前先做版本门控。
_HY2_GECKO_MIN_VER="v26.6.1"
_hy2_gecko_supported() {
    [ -x "$XRAY_BIN" ] || return 1
    declare -F _xray_version_ge >/dev/null 2>&1 || return 1
    # _xray_version_ge <min>: 内部自取当前版本(纯数字三段比较, busybox 安全);
    # 版本读不到时返回 1 = 不满足, 正好是保守侧。
    _xray_version_ge "$_HY2_GECKO_MIN_VER"
}

# ---------------------------------------------------------------------------
# Hysteria2 HTTP/3 页面伪装(hysteriaSettings.masquerade)
#
# **与 finalmask.udp(salamander/gecko 混淆)是两个独立机制, 互不读写**:
#   finalmask.udp → 改变**链路上的 QUIC 字节**(抗特征识别);
#   masquerade    → 定义"非 Hysteria 客户端连上本端口"时回什么 HTTP 页面(抗主动探测)。
# 两者可同时启用; 本组函数只碰 .streamSettings.hysteriaSettings.masquerade 这一个路径。
#
# **字段是扁平的, 不是按 type 嵌套**: 依据 [Xray 官方源码] infra/conf/transport_method.go
# (v26.7.11 之前为 infra/conf/transport_internet.go)的 Masquerade 结构体逐字段核对 json tag
# (v26.3.23 / v26.3.27 / v26.9.9 三处一致)。**Xray 官方文档(Xray-docs-next 的
# docs/{,en/,ru/}config/transports/hysteria.md)与源码一致, 也是扁平** —— 早期版本的注释曾
# 声称"docs 写的是嵌套", 经 2026-09-20 复核(本地克隆全历史 + 当前上游 raw)确认**不成立**:
# 该文件自 2026-01 引入以来从未出现嵌套形态(全历史 grep `"proxy": {` 为 0 命中)。
#
# **嵌套形态属于另一个项目**: official Hysteria(HyNetworks)的 hysteria.json 才是
# masquerade.file.dir / .proxy.url(见 app/cmd/server_test.yaml), 见 55-hysteria, 那边才是嵌套。
# 两套实现不可互抄 —— 但理由是"两个不同的软件", 而不是"Xray 文档写错了"。
#
# 真机 v26.9.9 双向实测(证明扁平才是 Xray 要的形态):
#     扁平 + url "ftp://bad"  → 启动即失败 "unknown scheme"(核心确实读了 url);
#     嵌套 + url "ftp://bad"  → 正常启动(嵌套对象被 Go JSON 静默忽略 = 伪装静默失效)。
#
# 版本门控**分三段**(逐 tag 核对 infra/conf/transport_method.go 的 Masquerade 结构体 json tag
# 与 transport/internet/hysteria/hub.go 的 scheme 分支。docs 与源码对 masquerade 的**字段形状**
# 是一致的, 但**能力范围**随版本增长, 故门控依据必须是目标 tag 的源码, 不能只看 docs):
#   >= v26.3.23  masquerade 本体(type/dir/url/rewriteHost/insecure/content/headers/statusCode)
#                 —— v26.3.10 及更早无此字段; 该版本**没有 scheme 分支**, 故非 http(s) 的 url
#                 会在**请求时**才失败(不阻断启动)
#   >= v26.9.8   + unix socket(``case "", "unix":`` 走 DialContext)与 xForwarded 字段
#                 —— 两者同 tag 引入(v26.7.28 及更早: 字段 8 个、无 unix 分支)
# 本脚本按"核心支持到什么就开放到什么"分层开放: unix/xForwarded 只在其门控通过时可选,
# 不把支持范围硬编码得过窄(当前核心已支持的形态不该被 UI 阻断)。
_HY2_MASQ_MIN_VER="26.3.23"
_HY2_MASQ_UNIX_MIN_VER="26.9.8"
_hy2_masq_supported() {
    [ -x "$XRAY_BIN" ] || return 1
    declare -F _xray_version_ge >/dev/null 2>&1 || return 1
    _xray_version_ge "$_HY2_MASQ_MIN_VER"
}

# unix socket / xForwarded 的可用性(比 masquerade 本体更晚引入)
_hy2_masq_unix_supported() {
    [ -x "$XRAY_BIN" ] || return 1
    declare -F _xray_version_ge >/dev/null 2>&1 || return 1
    _xray_version_ge "$_HY2_MASQ_UNIX_MIN_VER"
}

# 已知字段全集(与**目标核心版本**的 Masquerade 结构体 json tag 逐字对应)。集合写入以此为准:
# 先整体替换, 再把**非本脚本管理**的未知键原样搬回(用户或将来核心手工加过的字段不被吃掉),
# 同时让上一形态的残留字段(proxy 切到 string 后遗留的 url 等)不再留在配置里 ——
#
# **source 层与 docs 层的字段数不同, 不要混说(2026-09-20 实测)**:
#   Xray-core 源码 `Masquerade` struct: 9 个(含 xForwarded);
#   Xray-docs-next 三语的 `MasqObject`: **8 个, 未列出 xForwarded**(文档尚未跟上源码)。
# 本脚本以**源码**为准(功能由核心决定, 不由文档决定), 故用 9 个。
# 残留不是无害噪声: 切回该形态时它会以旧值复活。
XD_MASQ_KNOWN_KEYS_JSON='["type","dir","url","rewriteHost","xForwarded","insecure","content","headers","statusCode"]'

# **本机核心实际支持**的已知字段表 —— 与常量表**故意不同**。
#
# 为什么必须按版本裁剪(而不是恒用全集): xForwarded 只有 >= v26.9.8 认。若在旧核心上仍把它当
# "已知字段", 那么"集合替换"会拿 payload 里的 xForwarded:false 覆盖掉用户既有配置里的 true
# (在旧核心上 UI 不会问它, 所以 payload 恒为 false)。残局:
#
#   v26.9.9 配好 xForwarded=true
#     -> 用户切回旧核心(项目支持 stable/preview 通道切换, 切核心不动配置)
#     -> 在旧核心上改一次 proxy 的其它参数
#     -> xForwarded 被静默写成 false(永久丢失, 再升核心也不会自己回来)
#
# 这与本脚本"未管理字段原样保留"的承诺冲突。故旧核心上把它**从已知表里剔除**:
# 它就成了 unknown key, 被原样搬回 —— 旧核心不消费它(写了也被 Go 静默忽略),
# 而升级回新核心后用户原来的设置仍在。
XD_MASQ_KNOWN_KEYS_BASE_JSON='["type","dir","url","rewriteHost","insecure","content","headers","statusCode"]'
_hy2_masq_known_keys_json() {
    if _hy2_masq_unix_supported; then
        printf '%s' "$XD_MASQ_KNOWN_KEYS_JSON"
    else
        printf '%s' "$XD_MASQ_KNOWN_KEYS_BASE_JSON"
    fi
}

# 集合写入(唯一入口)。$m = 新 masquerade 对象, $known = 已知字段表。
# 只命中选中 tag 的那一个入站; 路径不存在时 jq 会自动补齐 streamSettings/hysteriaSettings。
XD_MASQ_JQ_SET='(.inbounds[] | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade) |= ($m + (if ((. // {}) | type) == "object" then (. // {}) else {} end | with_entries(select(.key as $k | ($known | index($k)) | not))))'

# 清除伪装段(= 官方默认 404)。用 del 而不是写 {"type":""}: "默认 404"的唯一表示就是
# **该段不存在**(官方 docs: 不填为默认的 404 页面), 少一个形态就少一处"两个值表达同一件事"。
XD_MASQ_JQ_CLEAR='del(.inbounds[] | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade)'

# 去掉首尾空白: read 会保留用户输入的空格, 响应头行 "  Server: x" 不去掉就是非法字段名。
_hy2_masq_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# 读取选中节点的伪装字段。未配置/形态不符(非对象)一律输出空串, 菜单据此显示"默认 404"。
# 用法: _hy2_masq_get <tag> <type|dir|url|rewriteHost|xForwarded|insecure|content|statusCode>
_hy2_masq_get() {
    local tag="$1" field="$2"
    [ -f "$CONFIG_FILE" ] || return 0
    jq -r --arg t "$tag" --arg k "$field" '
        (.inbounds[]? | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade) as $m
        | if ($m | type) != "object" then ""
          else (if $k == "type" then ($m.type // "")
                elif $k == "dir" then ($m.dir // "")
                elif $k == "url" then ($m.url // "")
                elif $k == "content" then ($m.content // "")
                elif $k == "statusCode" then (($m.statusCode // 0) | tostring)
                elif $k == "rewriteHost" then (($m.rewriteHost // false) | tostring)
                elif $k == "insecure" then (($m.insecure // false) | tostring)
                elif $k == "xForwarded" then (($m.xForwarded // false) | tostring)
                else "" end) | tostring
          end' "$CONFIG_FILE" 2>/dev/null
}

# 当前伪装的一句话描述(菜单唯一展示入口; 单次 jq, 避免"同一状态两处各自解释")。
# type 按核心口径**不区分大小写**(hub.go: strings.ToLower(config.MasqType))。
_hy2_masq_desc() {
    local tag="$1"
    [ -f "$CONFIG_FILE" ] || return 0
    jq -r --arg t "$tag" '
        (.inbounds[]? | select(.tag == $t) | .streamSettings.hysteriaSettings.masquerade) as $m
        | if ($m | type) != "object" then "默认 404 页面"
          else
            (($m.type // "") | tostring | ascii_downcase) as $ty
            | if $ty == "" or $ty == "404" then "默认 404 页面"
              elif $ty == "file" then "文件伪装: \($m.dir // "")"
              elif $ty == "proxy" then "反向代理: \($m.url // "")"
                   + (if ($m.rewriteHost // false) then " (改写 Host)" else "" end)
                   + (if ($m.insecure // false) then " (跳过证书校验)" else "" end)
                   + (if ($m.xForwarded // false) then " (X-Forwarded)" else "" end)
              elif $ty == "string" then "固定字符串: \(($m.content // "") | length) 字符, HTTP \(if (($m.statusCode // 0) | tostring) != "0" then (($m.statusCode) | tostring) else "200" end)"
                   + (if (($m.headers // {}) | length) > 0 then ", \((($m.headers) | length) | tostring) 个响应头" else "" end)
              else "未知类型 \($ty) —— 核心会拒绝启动, 请改正或改回默认 404" end
          end' "$CONFIG_FILE" 2>/dev/null
}

# 三个输入校验器: 输出**原因文本**(空串 = 合法), 与 _hy2_obfs_size_invalid 同口径 ——
# 调用方只需判断"非空即非法", 原因原样回显, 不必各自猜原因。
#
# **边界声明(有意为之)**: _hy2_masq_url_invalid 只做**最小结构校验**(scheme / 主机名 /
# unix 绝对路径), **不是完整 URI 语法验证器** —— 不在 shell 里重写 RFC 3986。
# 形如 "https://", "https://?x", "https://a.com:99999", "https://[bad" 之类的输入可能通过本层,
# 由核心的 url.Parse 与 HTTP transport 在真实请求/启动时暴露(有 _mutate_config 的启动回滚兜底)。
# 这样取舍是因为: 手写 parser 的误拒风险高于收益, 且这里只需挡住用户最常犯的错(漏 scheme、
# 打错 scheme、unix 路径写成相对)。
# 注意: 这些值最终经 jq --arg / --argjson 注入 config, JSON 转义由 jq 负责, 故**不**套用
# _validate_json_text: 那会连 HTML 里的 class="x" 引号一起拒绝, 而"固定字符串"伪装恰恰
# 最可能是 HTML。这里只做语义校验。
_hy2_masq_url_invalid() {
    local u="$1" scheme host sock
    [ -n "$u" ] || { printf '%s' "URL 不能为空"; return; }
    case "$u" in
        *[[:space:]]*) printf '%s' "URL 不能含空格/制表符(空格需写成 %20)"; return ;;
    esac
    # 支持范围对齐**目标核心版本**, 依据是 hub.go 的 "proxy" 分支:
    #   http / https          => 普通反代(masquerade 本体自 v26.3.23 起存在)
    #   ""(裸绝对路径) / unix => Unix socket(v26.9.8 起, 核心用 DialContext 连 unix)
    #
    # **版本行为务必分清(早期注释在这里写错过)**: `switch u.Scheme` 是 **v26.9.8 才加入**的。
    # v26.3.23 ~ v26.7.28 的 hub.go **没有** scheme 分支 —— 任何 scheme 都被原样交给
    # http.Transport, 所以非法 scheme 的失败会**推迟到实际代理请求时**, 而不是"启动即失败"。
    # v26.9.8+ 才有 switch 并在 default 返回 "unknown scheme"(启动即失败)。
    # 故这里只放这三类, 不是因为"核心会启动即拒绝", 而是因为**只有这三类是有意义的输入**;
    # 真正决定能否用 unix 的是下面 _hy2_masq_unix_supported 的独立版本门控。
    scheme="${u%%://*}"
    case "$u" in
        http://*|https://*)
            host="${u#*://}"; host="${host%%/*}"
            [ -n "$host" ] || { printf '%s' "URL 缺少主机名(形如 https://example.com)"; return; }
            printf '%s' ""
            return ;;
        unix://*)
            _hy2_masq_unix_supported || { printf '%s' "Unix socket 伪装需要 Xray >= v${_HY2_MASQ_UNIX_MIN_VER}(当前核心不支持, 写入会被静默忽略)"; return; }
            sock="${u#unix://}"
            case "$sock" in
                /*) printf '%s' "" ;;
                *) printf '%s' "unix:// 之后必须是绝对路径(如 unix:///run/site.sock)" ;;
            esac
            return ;;
        /*)
            # 裸绝对路径等价 unix(核心 case "", "unix" 取 u.Path 作 socket 路径)
            _hy2_masq_unix_supported || { printf '%s' "Unix socket 伪装需要 Xray >= v${_HY2_MASQ_UNIX_MIN_VER}(当前核心不支持, 写入会被静默忽略)"; return; }
            printf '%s' ""
            return ;;
    esac
    case "$scheme" in
        "") printf '%s' "URL 缺少 scheme: 请写 http(s)://… 或 unix:///绝对路径"; return ;;
    esac
    printf '%s' "不支持的 scheme ${scheme%%:*}(核心仅认 http / https / unix)"
}

_hy2_masq_dir_invalid() {
    local d="$1"
    [ -n "$d" ] || { printf '%s' "目录不能为空"; return; }
    case "$d" in
        /*) ;;
        *) printf '%s' "请填绝对路径(相对路径会被核心按服务进程的工作目录解析, 结果不可预期)"; return ;;
    esac
    printf '%s' ""
}

_hy2_masq_status_invalid() {
    local s="$1"
    [ -z "$s" ] && { printf '%s' ""; return; }
    [[ "$s" =~ ^[0-9]{3}$ ]] || { printf '%s' "HTTP 状态码必须是 3 位数字(如 200), 留空用 200"; return; }
    [ "$s" -ge 100 ] && [ "$s" -le 599 ] || { printf '%s' "HTTP 状态码须为 100-599(本脚本限制; 越界值核心写响应头时会 panic 并断开连接)"; return; }
    printf '%s' ""
}

# 解析一行 "名称: 值" 并合并进已累积的 headers JSON(参数 1)。
# 成功: 输出**合并后**的 compact JSON; 失败: 输出原因文本并返回 1。
# 用"逐行一条 + 空行结束"而不是逗号分隔: 响应头值本身可以含逗号
# (如 Cache-Control: no-cache, no-store), 按逗号切会把它拆成两条非法头。
_hy2_masq_headers_merge() {
    local h="$1" line="$2" name value
    case "$line" in
        *:*) ;;
        *) printf '%s' "格式应为 名称: 值(缺少冒号)"; return 1 ;;
    esac
    name=$(_hy2_masq_trim "${line%%:*}")
    value=$(_hy2_masq_trim "${line#*:}")
    [ -n "$name" ] || { printf '%s' "响应头名称不能为空"; return 1; }
    case "$name" in
        *[[:space:]]*) printf '%s' "响应头名称不能含空白(名称与冒号之间不要留空格)"; return 1 ;;
        *[![:print:]]*) printf '%s' "响应头名称含不可打印字符"; return 1 ;;
    esac
    jq -nc --argjson h "$h" --arg n "$name" --arg v "$value" '$h + {($n): $v}'
}

# 三个形态的 payload 构造器(唯一入口)。全部用 jq -n --arg 拼装: 值里的引号/反斜杠/
# 百分号由 jq 负责转义, 绝不手工拼串(手拼在 HTML 内容上必然出错)。
# 只写该形态**用得上的**字段: type 之外的字段核心按 switch 分支各取所需, 写上无关字段
# 只会让配置里的"上一形态残留"复活(见 XD_MASQ_JQ_SET 的注释)。
_hy2_masq_json_file() {
    jq -nc --arg d "$1" '{type: "file", dir: $d}'
}

# $2/$3/$4 = rewriteHost / insecure / xForwarded(jq 布尔字面量 true|false)
# xForwarded 只有 >= v26.9.8 的核心认(写入前有门控)。**只在核心支持时才写该键**:
# 旧核心上写 xForwarded:false 会把用户既有的 true 覆盖掉(见 _hy2_masq_known_keys_json 的说明),
# 而该字段在旧核心上本就被 Go 静默忽略 —— 不写它才既不丢数据又不改变行为。
_hy2_masq_json_proxy() {
    local xf="${4:-}"
    if _hy2_masq_unix_supported; then
        jq -nc --arg u "$1" --argjson rh "$2" --argjson ins "$3" --argjson xf "${xf:-false}" \
            '{type: "proxy", url: $u, rewriteHost: $rh, insecure: $ins, xForwarded: $xf}'
    else
        jq -nc --arg u "$1" --argjson rh "$2" --argjson ins "$3" \
            '{type: "proxy", url: $u, rewriteHost: $rh, insecure: $ins}'
    fi
}

# $2 = 状态码字符串(空 = 用核心默认 200); $3 = headers JSON 对象
_hy2_masq_json_string() {
    local c="$1" sc="$2" h=""
    # 不能用 h="${3:-{}}" —— 默认值里的 '}' 会提前结束参数展开, 实参存在时会多出一个 '}'
    # (实测 "{"a":"b"}}"), jq 随即报 invalid JSON。测试套件里已有同款坑的记录。
    h="${3:-}"
    [ -n "$h" ] || h='{}'
    jq -nc --arg c "$c" --arg sc "$sc" --argjson h "$h" \
        '{type: "string", content: $c}
         + (if $sc == "" then {} else {statusCode: ($sc | tonumber)} end)
         + (if ($h | length) == 0 then {} else {headers: $h} end)'
}

# 提交伪装变更。空 payload = 清除(默认 404)。
# 备份 → jq → 原子替换 → verified-restart → 失败还原, 全部复用 _mutate_config 的既有
# 事务机制(要求 6: 不另建第二条提交路径)。伪装是**单入站**属性, 不进 metadata、不影响
# 分享链接与 clash 条目(客户端不关心服务端伪装), 故没有派生状态需要同步 —— 也因此
# 不存在"元数据写失败要回滚 config"的第二阶段。
# 用法: _hy2_masq_apply <tag> <payload_json 或 "">
_hy2_masq_apply() {
    local tag="$1" payload="${2:-}"
    if [ -z "$payload" ]; then
        _mutate_config --arg t "$tag" "$XD_MASQ_JQ_CLEAR"
    else
        # known 表必须按**本机核心能力**取: 旧核心上把 xForwarded 排除在"已知"之外,
        # 它才会作为 unknown key 被原样保留(而不是被 payload 的缺省值覆盖)。
        local known
        known=$(_hy2_masq_known_keys_json)
        _mutate_config --arg t "$tag" --argjson m "$payload" --argjson known "$known" "$XD_MASQ_JQ_SET"
    fi
}

# ---------------------------------------------------------------------------
# iptables / 端口跳跃辅助(Hysteria2 端口跳跃用)
# 原理: iptables nat PREROUTING DNAT 把 UDP 端口范围转发到 hy2 监听端口
# 支持格式: "3010-3020" / "3050" / "3010-3020,3050,3100-3110" (逗号分隔混合)
# ---------------------------------------------------------------------------

# 确保 iptables 已安装(Debian 同时装 iptables-persistent 做开机恢复)
_ensure_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    _info "iptables 未安装, 正在安装..."
    local fam
    fam=$(_detect_os_family)
    case "$fam" in
        debian)
            _pkg_install iptables || return 1
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq --no-install-recommends iptables-persistent >/dev/null 2>&1 || true
            ;;
        *)
            _pkg_install iptables || return 1
            ;;
    esac
    if ! command -v iptables >/dev/null 2>&1; then
        _error "iptables 安装失败, 请手动安装"
        return 1
    fi
    _success "iptables 已安装"
}

# 解析端口范围字符串 → "start:end start:end ..."
_parse_hop_ranges() {
    local input="$1"
    local result=""
    local entries
    IFS=',' read -ra entries <<< "$input"
    local all_starts=() all_ends=()
    local entry
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | tr -d ' ')
        [ -z "$entry" ] && continue
        local start end
        if echo "$entry" | grep -q '-'; then
            start=$(echo "$entry" | cut -d'-' -f1)
            end=$(echo "$entry" | cut -d'-' -f2)
        else
            start="$entry"
            end="$entry"
        fi
        if ! _validate_port "$start" || ! _validate_port "$end"; then
            _error "无效端口: $entry"
            return 1
        fi
        if [ "$start" -gt "$end" ]; then
            _error "起始端口大于结束端口: $entry"
            return 1
        fi
        local i
        for ((i=0; i<${#all_starts[@]}; i++)); do
            if [ "$start" -le "${all_ends[$i]}" ] && [ "$end" -ge "${all_starts[$i]}" ]; then
                _error "范围重叠: $entry 与 ${all_starts[$i]}-${all_ends[$i]}"
                return 1
            fi
        done
        all_starts+=("$start")
        all_ends+=("$end")
        if [ "$start" = "$end" ]; then
            result="${result:+$result }${start}"
        else
            result="${result:+$result }${start}:${end}"
        fi
    done
    [ -z "$result" ] && { _error "无有效端口范围"; return 1; }
    echo "$result"
}

# 精确匹配 --to-destination :<port>(边界: 后随空白或行尾, R18), 避免 :443 误匹配 :4430/:44300 等其他节点规则
# 用法: 过滤 stdin 中的 iptables -S 行; 与 dport 的 "dport X " / "dport X$" 同风格
_hy2_match_target() {
    local port="$1"
    grep -e "--to-destination :${port} " -e "--to-destination :${port}\$"
}

# R38(P1)/R39(P1): 本机是否"**有证据表明**不存在任何 xray-deploy 端口跳跃规则"。
# 用于给 _node_protocol_safe 的 fail-closed 提供一个可证伪的逃生口。
# R39 收紧: 必须真的**看过** runtime, 才能说"没有规则"。
#   "iptables 不可用 + 持久化文件不存在" 只是"我没有观察能力", 不等于"内核里没有规则":
#   曾启用过 hop、规则已进内核、没装 iptables-persistent(无 rules.v4)、之后 iptables
#   二进制被卸载 —— 此时规则仍在内核中转发流量, 而旧实现会返回 0(=已证明无规则),
#   于是删除节点后留下无法追溯 dport 的孤儿 DNAT(metadata 也已被删)。
# 证据来源(必须至少有一个可用的观察通道):
#   a) iptables -S 成功 -> 最权威, 直接看 runtime;
#   b) iptables 不可用但内核 x_tables 从未装载过 nat 表 -> /proc/net/ip_tables_names
#      不含 "nat"(文件不存在同样说明 x_tables 未被使用) => 内核里不可能有 nat 规则;
#   c) 上面能确认无 runtime 规则后, 再看持久化文件(它们会在重启时被重新加载)。
# 任一通道都无法确认 => 返回 1(UNKNOWN, 按不安全处理), 由调用方拒绝并给出人工路径。
# 返回: 0 = 有证据表明无 hop 规则; 1 = 有规则, 或无观察能力(UNKNOWN)
_hy2_no_hop_rules_at_all() {
    local q f runtime_clean=0
    if command -v iptables >/dev/null 2>&1; then
        q=$(iptables -t nat -S PREROUTING 2>/dev/null) || return 1
        printf '%s\n' "$q" | grep -q "xray-deploy-hy2-hop" && return 1
        # IPv6 侧为 best-effort: 命令存在但查询失败时无法确认, 保守判 UNKNOWN
        if command -v ip6tables >/dev/null 2>&1; then
            q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || return 1
            printf '%s\n' "$q" | grep -q "xray-deploy-hy2-hop" && return 1
        fi
        runtime_clean=1
    else
        # 无 iptables: 唯一可靠的替代证据是"内核 nat 表从未被使用过"。
        # /proc/net/ip_tables_names 列出当前已注册的 iptables 表; 不含 nat(或文件不存在,
        # 即 x_tables 未装载)时, 内核里不可能存在 nat PREROUTING 规则。
        # 注意 nftables 后端(nft) 不体现在该文件里, 因此若 nft 存在而 iptables 不存在,
        # 一律判 UNKNOWN —— 本项目只用 iptables 写规则, 但用户环境可能已迁移到 nft。
        if command -v nft >/dev/null 2>&1; then
            _warn "iptables 不可用但检测到 nft, 无法确认是否存在跳跃规则"
            return 1
        fi
        if [ -e /proc/net/ip_tables_names ]; then
            if ! q=$(cat /proc/net/ip_tables_names 2>/dev/null); then
                return 1   # 存在但读不到(权限/容器限制): UNKNOWN
            fi
            printf '%s\n' "$q" | grep -qx "nat" && return 1   # nat 表在用, 但无从查询内容
        fi
        runtime_clean=1
    fi
    [ "$runtime_clean" -eq 1 ] || return 1
    # runtime 已确认无规则; 持久化文件会在重启时重新加载, 同样必须干净
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f" ] || continue
        grep -q "xray-deploy-hy2-hop" "$f" 2>/dev/null && return 1
    done
    return 0
}

# 为多个范围添加 DNAT 规则(R16 幂等 + R17 跨节点冲突拒绝 + R19 -S 查询失败守卫):
#   - 同 dport 且同目标端口已存在  -> 跳过(幂等, rollback/重试安全)
#   - 同 dport 但目标端口不同      -> 拒绝(该范围已被其他节点占用, 避免两个 DNAT 规则并存)
# R19: 每次调用只执行一次 iptables -S(整个 range 循环复用同一快照, 事务内一致视图),
#      且 -S 失败显式 return 1——绝不把"查不到规则"当成"无冲突"而继续 ADD(与 remove 同标准)。
# R35(P1): stdout 输出"本次事务实际新增的 range"(每行一个, 即 CREATED 集合)。幂等跳过的
#      既有规则绝不输出——调用方据此精确回滚本事务副作用, 而非按请求全量 remove(否则会误删
#      事务开始前已存在的同 dport+同目标规则)。无需该输出的调用方应显式 >/dev/null。
# R36(P2): CREATED 集合只表达"IPv4 侧副作用"。IPv6 为 best-effort(R14), 独立于 IPv4 检查/
#      补建——即使 IPv4 已存在(幂等跳过)也继续尝试 IPv6, 避免"IPv6 曾失败就永久不再重试";
#      IPv6 不进 CREATED、不参与 rollback ownership(移除仍靠 IPv4 幂等 skip 保护)。
# 返回: 0 全部成功; 1 任一范围冲突/查询失败/添加失败
_hy2_add_hop_rules() {
    # 注意(R28, 设计边界): hop ownership 由 (dport, 目标端口) 构成, 记录在 iptables + 节点
    # metadata(hop_ranges); 若节点 metadata 因外部事件丢失, 无法从 config 恢复 hop ownership,
    # 不会自动清理对应 DNAT。这是已知限制(见 R25/R26 Known limitation), 非本函数可解。
    local hy2_port="$1"; shift
    local range q v6ok="" v6q=""
    if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
        _error "无法读取 PREROUTING 规则(iptables -S 失败), 中止添加"
        return 1
    fi
    # R36(P2): IPv6 快照一次获取并复用。v6ok 标记 ip6tables 命令可用(空表也须进入补建分支);
    # 查询失败仅警告, IPv6 跳跃规则整体跳过(仅 IPv4 生效)。v6q 为空表示"无既有 IPv6 规则"。
    if command -v ip6tables >/dev/null 2>&1; then
        v6ok=1
        v6q=$(ip6tables -t nat -S PREROUTING 2>/dev/null) || {
            _warn "无法读取 IPv6 PREROUTING 规则, 本次仅维护 IPv4 跳跃规则(best-effort)"
            v6q=""
        }
    fi
    for range in "$@"; do
        local dports
        dports=$(printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" \
                | grep -e "dport ${range} " -e "dport ${range}\$")
        if [ -n "$dports" ]; then
            if echo "$dports" | _hy2_match_target "$hy2_port" | grep -q .; then
                :  # 同 dport 且同目标端口已存在: IPv4 幂等跳过(不输出, 不属于本次 CREATED)
            else
                _error "端口范围 ${range} 已被其他节点占用(目标端口不同), 拒绝添加"
                return 1
            fi
        else
            iptables -t nat -A PREROUTING -p udp --dport "${range}" \
                -m comment --comment "xray-deploy-hy2-hop" \
                -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || return 1
            echo "$range"
        fi
        # R36(P2): IPv6 独立补建——即使 IPv4 已存在也检查/添加, 保证 best-effort 可重试
        if [ -n "$v6ok" ]; then
            local v6d
            v6d=$(printf '%s\n' "$v6q" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$")
            if [ -n "$v6d" ]; then
                if ! echo "$v6d" | _hy2_match_target "$hy2_port" | grep -q .; then
                    _warn "IPv6 端口范围 ${range} 已被其他规则占用(目标端口不同), 未添加 IPv6 跳跃规则"
                fi
            else
                ip6tables -t nat -A PREROUTING -p udp --dport "${range}" \
                    -m comment --comment "xray-deploy-hy2-hop" \
                    -j DNAT --to-destination ":${hy2_port}" 2>/dev/null || \
                    _warn "IPv6 Hysteria2 跳跃规则添加失败(${range}, 可能缺少 IPv6 NAT 支持)"
            fi
        fi
    done
}

# 删除多个范围的 DNAT 规则(先查 iptables -S 找实际 rule spec 再 -D, 确保精准删除)
# R17: 同时匹配 comment + dport + 目标端口, 保证跨节点隔离——不同节点即使 hop dport 重叠,
#      删除本节点(目标端口 X)绝不误删他节点(目标端口 Y)的同 dport 规则。
# R18: 目标端口用 _hy2_match_target 精确边界匹配; -S 查询失败显式报错, 不把"查不到"当"已删干净"。
# 返回: 0 全部 IPv4 范围删除干净; 1 有 IPv4 残留或查询失败(调用方应中止事务/显式提示; IPv6 为 best-effort 只警告)
_hy2_remove_hop_rules() {
    local hy2_port="$1"; shift
    local range remain_any=0
    for range in "$@"; do
        local q specs
        if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
            _error "无法读取 PREROUTING 规则(iptables -S 失败), 中止删除"
            return 1
        fi
        # 精确锚定 dport 值(其后必须是空白或行尾) + 目标端口精确匹配, 避免单端口 443 子串误匹配 4430:4440 等其他节点规则
        specs=$(printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" \
                | grep -e "dport ${range} " -e "dport ${range}\$" \
                | _hy2_match_target "$hy2_port" | sed 's/^-A/-D/')
        local line
        while IFS= read -r line; do
            [ -n "$line" ] && iptables -t nat $line 2>/dev/null || true
        done <<< "$specs"
        # 删除后核验(R15): 重新查询当前状态(不能用删除前的 q), 若该范围仍残留则显式提示并置失败标记
        local remain
        if ! q=$(iptables -t nat -S PREROUTING 2>/dev/null); then
            _error "无法读取 PREROUTING 规则核验(iptables -S 失败)"
            return 1
        fi
        remain=$(printf '%s\n' "$q" | grep "xray-deploy-hy2-hop" \
                | grep -e "dport ${range} " -e "dport ${range}\$" \
                | _hy2_match_target "$hy2_port")
        if [ -n "$remain" ]; then
            _warn "IPv4 范围 ${range} 的跳跃规则删除后仍残留, 请手动检查"
            remain_any=1
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            local q6 specs6
            if ! q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
                _warn "无法读取 IPv6 PREROUTING 规则, 跳过 IPv6 跳跃规则删除核验"
                continue
            fi
            specs6=$(printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$" \
                    | _hy2_match_target "$hy2_port" | sed 's/^-A/-D/')
            while IFS= read -r line; do
                [ -n "$line" ] && ip6tables -t nat $line 2>/dev/null || true
            done <<< "$specs6"
            if ! q6=$(ip6tables -t nat -S PREROUTING 2>/dev/null); then
                _warn "无法读取 IPv6 PREROUTING 规则核验, 跳过 IPv6 残留判断"
                continue
            fi
            remain=$(printf '%s\n' "$q6" | grep "xray-deploy-hy2-hop" \
                    | grep -e "dport ${range} " -e "dport ${range}\$" \
                    | _hy2_match_target "$hy2_port")
            [ -n "$remain" ] && _warn "IPv6 范围 ${range} 的跳跃规则删除后仍残留, 请手动检查"
        fi
    done
    return "$remain_any"
}

# 持久化 iptables 规则。R37(P1): IPv4 为 authoritative——save 失败返回 1(告知调用方
# "重启后 IPv4 规则可能丢失", 事务必须回滚且不提交 metadata); IPv6 为 best-effort(R14)——save
# 失败仅 _warn, 不决定事务成败。若把 IPv6 persistence 也设为 fatal, 而 IPv6 新增规则不在
# CREATED/rollback ownership 内, 事务将因 IPv6 persist 失败而失败却无法回滚 IPv6 side effect。
# 注意 ok 用 0=成功/1=失败(与 bash 退出码一致, 不要用 1=成功 + return "$ok" 的颠倒写法, R14)
# 直接写采用 save -> tmp -> mv(R15): 避免 shell 先 truncate 目标文件再执行 save, save 失败把已有持久化规则清空
_hy2_persist_iptables() {
    # R34(P1): 事务需要持久化时, 缺少 iptables-save 不是"无事发生"而是失败——
    # 否则 metadata 提交 hop=enabled, 重启后 runtime DNAT 全丢, 直接违反
    # "runtime/metadata 不分裂"原则。_ensure_iptables 只保证 iptables 存在,
    # 不保证 iptables-save, 故必须在此显式 fail-closed。正常 enable/disable/
    # retarget/delete 的事务都会因 rc1 回滚 runtime 且不提交 metadata; reset
    # 路径由调用方保持 best-effort + warn。
    if ! command -v iptables-save >/dev/null 2>&1; then
        _error "iptables-save 不可用, 无法安全持久化端口跳跃规则(重启后规则会丢失)"
        return 1
    fi
    local ok=0 fam v4tmp v6tmp
    fam=$(_detect_os_family)
    case "$fam" in
        debian)
            mkdir -p /etc/iptables 2>/dev/null || ok=1
            v4tmp="/etc/iptables/rules.v4.tmp.$$"
            if iptables-save > "$v4tmp" 2>/dev/null; then
                mv -f "$v4tmp" /etc/iptables/rules.v4 2>/dev/null || { rm -f "$v4tmp"; ok=1; }
            else
                rm -f "$v4tmp"; ok=1
            fi
            if command -v ip6tables-save >/dev/null 2>&1; then
                v6tmp="/etc/iptables/rules.v6.tmp.$$"
                if ip6tables-save > "$v6tmp" 2>/dev/null; then
                    mv -f "$v6tmp" /etc/iptables/rules.v6 2>/dev/null || { rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
                else
                    rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                fi
            fi
            ;;
        alpine)
            if [ -x /etc/init.d/iptables ]; then
                # init.d save 由服务脚本自行管理其持久化文件, 无法原子化, 仅检查返回
                /etc/init.d/iptables save >/dev/null 2>&1 || ok=1
                # R34(P2): ip6 侧先确认 init.d 脚本存在; 不存在但 ip6tables-save 可用时
                # 回退到直接原子写(与无 init.d 分支一致), 避免调用不存在的脚本 rc127 误报失败
                if [ -x /etc/init.d/ip6tables ]; then
                    /etc/init.d/ip6tables save >/dev/null 2>&1 || _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                elif command -v ip6tables-save >/dev/null 2>&1; then
                    mkdir -p /etc/iptables 2>/dev/null || _warn "无法创建 /etc/iptables, IPv6 规则持久化失败(best-effort)"
                    v6tmp="/etc/iptables/rules.v6.tmp.$$"
                    if ip6tables-save > "$v6tmp" 2>/dev/null; then
                        mv -f "$v6tmp" /etc/iptables/rules.v6 2>/dev/null || { rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
                    else
                        rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                    fi
                fi
            else
                mkdir -p /etc/iptables 2>/dev/null || ok=1
                v4tmp="/etc/iptables/rules.v4.tmp.$$"
                if iptables-save > "$v4tmp" 2>/dev/null; then
                    mv -f "$v4tmp" /etc/iptables/rules.v4 2>/dev/null || { rm -f "$v4tmp"; ok=1; }
                else
                    rm -f "$v4tmp"; ok=1
                fi
                if command -v ip6tables-save >/dev/null 2>&1; then
                    v6tmp="/etc/iptables/rules.v6.tmp.$$"
                    if ip6tables-save > "$v6tmp" 2>/dev/null; then
                        mv -f "$v6tmp" /etc/iptables/rules.v6 2>/dev/null || { rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"; }
                    else
                        rm -f "$v6tmp"; _warn "IPv6 规则持久化失败(best-effort), 重启后 IPv6 跳跃规则可能丢失"
                    fi
                fi
            fi
            ;;
        *)
            mkdir -p /etc/iptables 2>/dev/null || ok=1
            v4tmp="/etc/iptables/rules.v4.tmp.$$"
            if iptables-save > "$v4tmp" 2>/dev/null; then
                mv -f "$v4tmp" /etc/iptables/rules.v4 2>/dev/null || { rm -f "$v4tmp"; ok=1; }
            else
                rm -f "$v4tmp"; ok=1
            fi
            ;;
    esac
    return "$ok"
}

# ---------------------------------------------------------------------------
# Hysteria2 端口跳跃事务(R15): runtime iptables 修改 + 持久化 + 节点 metadata 必须整体成功,
# 任一步失败回滚已发生的变更, 保证 iptables 与 metadata 不永久分叉。
# 调用方先纯内存生成 newmeta(完整新 metadata, 含 share_link; 失败则不进入事务)。
# 用法: _hy2_hop_txn <add|remove> <meta> <newmeta> <port> <range...>
# 返回: 0 全部成功提交; 1 任一步失败(已回滚 runtime 并重新持久化)
# ---------------------------------------------------------------------------
_hy2_hop_txn() {
    local op="$1" meta="$2" newmeta="$3" port="$4"; shift 4
    # 1+2. runtime 修改 + 原子持久化(失败自动回滚 runtime)
    if ! _hy2_hop_apply "$op" "$port" "$@"; then
        return 1
    fi
    # 3. 原子提交 metadata(_atomic_write_json 失败时目标文件原样, 无需恢复 metadata)
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "节点 metadata 提交失败, 回滚运行时规则..."
        _hy2_hop_reverse "$op" "$port" "$@" || _error "回滚运行时规则失败, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# runtime 修改 + 原子持久化; 持久化失败则回滚 runtime 并重新持久化, 返回 1
_hy2_hop_apply() {
    local op="$1" port="$2"; shift 2
    local created rc
    if [ "$op" = add ]; then
        # IPv4 添加失败时可能有部分 range 已加入, 先回滚再返回。
        # R35(P1): created 只含本事务实际新增的 range(_hy2_add_hop_rules 输出, 幂等跳过的
        # 既有规则不在内); 回滚只删 created, 绝不误删事务开始前已存在的同目标规则。
        created=$(_hy2_add_hop_rules "$port" "$@"); rc=$?
        if [ "$rc" != 0 ]; then
            _warn "跳跃规则添加失败, 回滚本事务实际新增的规则..."
            # shellcheck disable=SC2086
            _hy2_hop_reverse add "$port" $created || _error "回滚已添加的规则失败, 请手动检查 iptables"
            return 1
        fi
    else
        # 删除残留即失败: 不能让"删了一半"的运行时规则与 metadata 分叉;
        # 用幂等 add 恢复已成功删除的范围(残留规则同 dport+同目标端口会被跳过, 不会重复添加)
        _hy2_remove_hop_rules "$port" "$@" || {
            _warn "旧规则删除不干净, 恢复已删除的规则..."
            _hy2_hop_reverse remove "$port" "$@" || _error "恢复已删除的规则失败, 请手动检查 iptables"
            return 1
        }
    fi
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚运行时规则..."
        if [ "$op" = add ]; then
            # R35(P1): 只回滚本事务新增的 created; remove 分支则恢复全部(本事务删除的都是本次副作用)
            # shellcheck disable=SC2086
            _hy2_hop_reverse add "$port" $created || _error "回滚运行时规则失败, 请手动检查 iptables"
        else
            _hy2_hop_reverse remove "$port" "$@" || _error "回滚运行时规则失败, 请手动检查 iptables"
        fi
        return 1
    fi
    return 0
}

# 反向操作: add 的回滚 = remove; remove 的回滚 = add(幂等)。
# 返回 0=回滚成功; 1=回滚过程中仍有失败(runtime 或持久化), 调用方必须显式报告, 不能当作"已恢复原状"
_hy2_hop_reverse() {
    local op="$1" port="$2"; shift 2
    local ok=0
    if [ "$op" = add ]; then
        _hy2_remove_hop_rules "$port" "$@" || ok=1
    else
        # R35(P1): 恢复操作不需要 CREATED 集合输出(add 的 stdout 仅由 _hy2_hop_apply/retarget
        # 按需捕获), 显式丢弃, 避免裸行泄漏到终端
        _hy2_add_hop_rules "$port" "$@" >/dev/null || ok=1
    fi
    _hy2_persist_iptables || ok=1
    return "$ok"
}

# 删除节点前的端口跳跃清理事务(R17): remove + 原子持久化; 任一步失败都恢复 runtime 已删规则并返回 1。
# 调用方必须: teardown 成功才允许删除节点 metadata/config; teardown 失败 -> 取消删除, 节点整体保持原状。
_hy2_hop_teardown() {
    local port="$1"; shift
    if ! _hy2_remove_hop_rules "$port" "$@"; then
        _warn "端口跳跃规则删除不干净, 恢复已删除的规则..."
        local rok=0
        _hy2_add_hop_rules "$port" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables || rok=1
        [ "$rok" = 1 ] && _error "恢复失败, 请手动检查 iptables"
        return 1
    fi
    # R18: persist 失败必须回滚已删除的 runtime 规则, 否则出现 metadata=enabled 而 runtime=disabled 的分裂
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚已删除的运行时规则..."
        _hy2_hop_reverse remove "$port" "$@" || _error "回滚失败, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# 批量 teardown(多选/全部删除)。
# R38(P1): 语义由"任一失败 → 整批取消"改为"逐项判定 → 坏项排除、其余照删"。
#   原写法让一个损坏 metadata 就让"全部删除/多选删除"完全不可用(且报错文案是
#   "端口跳跃规则清理失败", 与真实原因不符), 属拒绝服务。
#   现在: 无法安全 teardown 的 tag 记入 _HY2_HOP_SKIP, 调用方必须把它们从删除集合里剔除;
#   已成功 teardown 的 tag 记入 _HY2_HOP_TD, 供 config 提交失败时整体回滚。
#   每个失败项在 _hy2_hop_teardown 内部已自行恢复 runtime, 因此无需整批回滚。
# 返回: 0 = 至少可以继续(调用方按 _HY2_HOP_SKIP 缩小集合); 1 = 全部被排除, 无事可做
_HY2_HOP_TD=()
_HY2_HOP_SKIP=()
_hy2_hop_teardown_all() {
    # R18: 每个事务从空开始, 避免上一次批量删除的 tag 跨事务残留
    _HY2_HOP_TD=()
    _HY2_HOP_SKIP=()
    local tag total=0
    for tag in "$@"; do
        total=$((total+1))
        local proto hop_port ranges
        # R30(P1): metadata 损坏/缺 protocol 不能当作"非 HY2"跳过 teardown, 否则节点随后
        # 正常从 config 删除, hop DNAT 永久残留。_node_protocol_safe 在"确定本机无 hop 规则"
        # 时会放行(见 R38), 无法确认时才拒绝。
        if ! proto=$(_node_protocol_safe "$tag"); then
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        [ "$proto" = "hysteria2" ] || continue
        if ! hop_port=$(jq -r '.port // empty' "$NODES_DIR/${tag}.json" 2>/dev/null); then
            _error "节点元数据损坏, 无法确认端口: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        [[ "$hop_port" =~ ^[0-9]+$ ]] || {
            _error "节点元数据损坏(端口无效): $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        }
        # R31(P1): metadata.port 必须与 config 真实监听端口一致——否则 teardown 用错误目标
        # 端口找不到(或误删)DNAT 规则, 留下 :<真实端口> 的孤儿规则。
        # 仅当 config 存在该 inbound 时强制(真实删除流 inbound 必在 config; config 已无该
        # inbound 说明已是孤儿/外部删除, metadata.port 仍是当初 add 用的正确清理目标)。
        local cfg_port
        cfg_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$cfg_port" ] && [ "$cfg_port" != "$hop_port" ]; then
            _error "节点元数据端口($hop_port)与 config 监听端口($cfg_port)不一致, 无法安全删除: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        # R31(P1): hop 范围字段存在但无法解析 → 拒绝删除该项(不当作"无 hop"跳过 teardown)
        _hy2_hop_meta_ok "$tag" || {
            _HY2_HOP_SKIP+=("$tag")
            continue
        }
        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        [ -n "$ranges" ] || continue
        # R33(P1): 存在 hop 规则但 iptables 不可用 → 无法安全删除(fail-closed; 与单删一致)
        if ! command -v iptables >/dev/null 2>&1; then
            _error "节点存在端口跳跃规则, 但 iptables 不可用, 无法安全删除: $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        # shellcheck disable=SC2086
        if ! _hy2_hop_teardown "$hop_port" $ranges; then
            _error "端口跳跃规则清理失败, 已跳过该节点(节点未动): $tag"
            _HY2_HOP_SKIP+=("$tag")
            continue
        fi
        _HY2_HOP_TD+=("$tag")
    done
    if [ ${#_HY2_HOP_SKIP[@]} -gt 0 ]; then
        _warn "以下节点无法安全清理端口跳跃规则, 已从本次删除中排除: ${_HY2_HOP_SKIP[*]}"
    fi
    # 无参调用(total=0)视为成功(无事可做, 避免调用方把"没节点"误判成"全部失败");
    # 有参时"全部被排除"才算失败
    [ "$total" -eq 0 ] && return 0
    [ ${#_HY2_HOP_SKIP[@]} -lt "$total" ]
}

# R38(P1): 从待删列表里剔除 _HY2_HOP_SKIP 中的 tag, 结果写入全局 _HY2_DEL_KEEP。
# 用法: _hy2_filter_skipped "${del_tags[@]}"; del_tags=("${_HY2_DEL_KEEP[@]}")
_HY2_DEL_KEEP=()
_hy2_filter_skipped() {
    _HY2_DEL_KEEP=()
    local t s skip
    for t in "$@"; do
        skip=0
        for s in "${_HY2_HOP_SKIP[@]}"; do
            [ "$s" = "$t" ] && { skip=1; break; }
        done
        [ "$skip" -eq 0 ] && _HY2_DEL_KEEP+=("$t")
    done
}

# 恢复 _hy2_hop_teardown_all 已 teardown 的节点(幂等 add + 持久化), 用于 config 提交失败时的整体回滚
# R18: 恢复失败的 tag 保留在 _HY2_HOP_TD 中(ROLLBACK_FAILED 状态), 只有全部恢复成功才清空,
#      避免"已经报错但状态容器被清空、无法再重试"的问题
_hy2_hop_restore_after_teardown() {
    local tag remain=()
    for tag in "${_HY2_HOP_TD[@]}"; do
        local pp rr
        pp=$(jq -r '.port' "$NODES_DIR/${tag}.json" 2>/dev/null)
        rr=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        # shellcheck disable=SC2086
        if ! _hy2_hop_reverse remove "$pp" $rr 2>/dev/null; then
            _error "恢复端口跳跃规则失败: $tag, 请手动检查 iptables"
            remain+=("$tag")
        fi
    done
    _HY2_HOP_TD=("${remain[@]}")
}

# 端口跳跃改目标端口(metadata 不变): remove old + add new + 原子持久化; 失败回滚到旧端口规则
_hy2_hop_retarget() {
    local oldport="$1" newport="$2"; shift 2
    if ! _hy2_remove_hop_rules "$oldport" "$@"; then
        # R17: 首步 remove 也可能"部分成功"(几个范围删掉、一个残留), 必须先恢复已删范围再中止,
        #      否则 runtime 处于"旧端口规则删了一半"的中间态, 与 metadata 分叉
        _warn "旧端口规则删除不干净, 恢复已删除的规则..."
        local rok=0
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "旧端口规则恢复失败, 请手动检查 iptables"
        return 1
    fi
    # R35(P1): created_new 只含本事务实际新增的 newport 规则(add 输出; 幂等跳过的既有
    # 规则不在内), 后续失败回滚只清理 created_new, 绝不误删 retarget 前已存在的同目标规则
    local created_new rc
    created_new=$(_hy2_add_hop_rules "$newport" "$@"); rc=$?
    if [ "$rc" != 0 ]; then
        _error "新端口跳跃规则添加失败, 恢复旧规则..."
        # 先清理本事务实际新增的新端口规则(created_new), 再恢复旧端口规则(幂等 add 不会重复);
        # 三步都尽力执行并聚合结果
        local rok=0
        # shellcheck disable=SC2086
        _hy2_remove_hop_rules "$newport" $created_new 2>/dev/null || rok=1
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "端口回滚不完整, 请手动检查 iptables"
        return 1
    fi
    if ! _hy2_persist_iptables; then
        _warn "iptables 持久化失败, 回滚到旧端口规则..."
        local rok=0
        # shellcheck disable=SC2086
        _hy2_remove_hop_rules "$newport" $created_new 2>/dev/null || rok=1
        _hy2_add_hop_rules "$oldport" "$@" >/dev/null 2>/dev/null || rok=1
        _hy2_persist_iptables 2>/dev/null || rok=1
        [ "$rok" = 1 ] && _error "端口回滚不完整, 请手动检查 iptables"
        return 1
    fi
    return 0
}

# 在内存中生成完整新 metadata: 传入 hop 字段变换后的 hopmeta 内容, 重建分享链接(读临时文件, 因为
# _rebuild_hy2_link 从文件读), 输出 newmeta(hop 字段 + 新 share_link)。失败返回 1(未落地任何文件)。
_hy2_gen_newmeta() {
    local meta="$1" hopmeta="$2" tmp_meta newlink rc
    tmp_meta=$(mktemp "${meta}.hop.XXXXXX") || return 1
    printf '%s' "$hopmeta" > "$tmp_meta" || { rm -f "$tmp_meta"; return 1; }
    newlink=$(_rebuild_hy2_link "$tmp_meta"); rc=$?
    # 两种失败必须区分(同 _hy2_sync_derived): 不可表达(gecko 自定义尺寸) ⇒ 链接**留空**
    # 是正常结果, clash 能完整承载该尺寸; 元数据缺字段 ⇒ 无法安全重建, 拒绝(不写坏链接)。
    if [ "$rc" != 0 ] && ! _hy2_link_unexpressible "$tmp_meta"; then
        rm -f "$tmp_meta"
        return 1
    fi
    rm -f "$tmp_meta"
    jq --arg l "$newlink" '.share_link=$l' <<< "$hopmeta"
}

# 在内存生成端口修改后的完整新 metadata(port + name + share_link), 不落地真实 meta 文件(R16)。
# 供 _hy2_port_txn 使用: 事务内只做一次 _atomic_write_json 提交整份新 metadata, 消除两段式写窗口。
# 失败返回 1(输出为空); 调用方通过 $(...) 捕获, 未落地任何文件。
_hy2_gen_port_newmeta() {
    local meta="$1" newport="$2" oldport tmpm newlink rc name newname
    oldport=$(jq -r '.port' "$meta")
    [ -n "$oldport" ] || return 1
    name=$(jq -r '.name' "$meta")
    # F8: 仅替换 "-<oldport>" 后缀, 全局子串替换会破坏名称中含端口号的其他数字
    newname=$(_rename_node_with_port "$name" "$oldport" "$newport")
    tmpm=$(mktemp "${meta}.port.XXXXXX") || return 1
    # 临时文件必须同时承载**新端口与新名称**: 链接的 #fragment 取 .name, 只改端口会让重建出的
    # 链接停在旧名(实测 hop 改端口后 share_link 尾段仍是旧名, 而非 hop 路径给的是新名 ——
    # 同一操作两条路径两种结果)。与 Reality 分支"临时文件承载新 port + 新 name 再重建"同源。
    jq --argjson p "$newport" --arg n "$newname" '.port=$p | .name=$n' "$meta" > "$tmpm" || { rm -f "$tmpm"; return 1; }
    newlink=$(_rebuild_hy2_link "$tmpm"); rc=$?
    # 同 _hy2_sync_derived: gecko 自定义尺寸 ⇒ 链接留空(正常); 元数据缺字段 ⇒ 拒绝
    if [ "$rc" != 0 ] && ! _hy2_link_unexpressible "$tmpm"; then
        rm -f "$tmpm"
        return 1
    fi
    rm -f "$tmpm"
    jq --argjson p "$newport" --arg n "$newname" --arg l "$newlink" \
       '.port=$p | .name=$n | .share_link=$l' "$meta"
}

# 端口修改统一事务(R16): 用于 hy2+hop 节点。调用方已用 _hy2_gen_port_newmeta 在内存生成完整 newmeta。
# 提交顺序: runtime iptables old→new + 原子持久化(最常见失败点, 失败干净中止、config/metadata 未动)
#         → 原子提交 metadata → 提交 config(_mutate_config 自带重启校验与失败回滚)。
# 后两步失败回滚已提交步骤, 保证 config/metadata/iptables 三方一致(全部回到旧端口或全部新端口)。
# 返回: 0 全部成功; 1 失败(已尽力回滚到旧端口并提示)
# 并发: 整个事务(快照 → journal → iptables → metadata → config → 回滚)在 _with_config_lock
# 内 —— 与 _port_txn / Reality 事务同一锁域。三条路径共用 <old_path>.porttxn, 不锁会让并发
# 会话互相覆盖/删除对方的 journal(进而让崩溃恢复本身失效)。
_hy2_port_txn() {
    _with_config_lock _hy2_port_txn_locked "$@"
}

_hy2_port_txn_locked() {
    local tag="$1" meta="$2" oldport="$3" newport="$4" newmeta="$5"; shift 5
    local ranges="$*" orig journal rok
    journal="${meta}.porttxn"
    orig=$(cat "$meta" 2>/dev/null) || return 1
    # 0. journal: iptables 是本事务第一个被改动的真实状态, journal 必须先于它落盘
    #    (崩溃残局是四元组 config/metadata/runtime DNAT/persisted DNAT, 恢复判据与修法见
    #    _port_txn_recover: config 未提交 ⇒ 回滚 metadata + retarget 回旧端口, 两者皆幂等)
    if ! _port_txn_journal_write "$meta" "$meta" hy2hop "$oldport" "$newport" "$ranges" "$orig" "$newmeta"; then
        _error "端口事务 journal 写入失败, 未做任何修改"
        return 1
    fi
    # 1. runtime iptables old→new + 原子持久化。失败时 retarget 内部已尽力自愈;
    #    **保留 journal** —— 若自愈不完整, 启动期恢复会幂等补齐(retarget 的 add/remove 均带
    #    存在性检查, 重入安全), 比留下无法收敛的残局好。
    # shellcheck disable=SC2086
    if ! _hy2_hop_retarget "$oldport" "$newport" $ranges; then
        return 1
    fi
    # 2. 原子提交 metadata(失败回滚 iptables, config 未动)
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 回滚 iptables 到旧端口..."
        # shellcheck disable=SC2086
        if _hy2_hop_retarget "$newport" "$oldport" $ranges; then
            rm -f "$journal"
        else
            _error "iptables 回滚失败, 保留 journal 待启动恢复: $journal"
        fi
        return 1
    fi
    # 3. 提交 config(_mutate_config 失败会自行恢复旧 config 并重启回旧端口)
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口配置提交失败, 回滚 metadata + iptables 到旧端口..."
        rok=0
        _atomic_write_json "$meta" "$orig" || { _error "元数据回滚失败, 请手动检查"; rok=1; }
        # shellcheck disable=SC2086
        _hy2_hop_retarget "$newport" "$oldport" $ranges || { _error "iptables 回滚失败, 请手动检查"; rok=1; }
        # 两边都回滚干净才删 journal; 任一失败保留它, 启动期恢复幂等收敛
        if [ "$rok" = 0 ]; then
            rm -f "$journal"
        else
            _error "保留 journal 待启动恢复: $journal"
        fi
        return 1
    fi
    rm -f "$journal"
    return 0
}

# _modify_port 的 hy2+hop 分支(R16): 内存生成完整新 metadata -> _hy2_port_txn 统一提交;
# 返回 0=成功, 1=失败(已回滚到旧端口)
_modify_port_hop() {
    local tag="$1" meta="$2" oldport="$3" newport="$4"; shift 4
    local ranges="$*" newmeta display
    display=$(_read_hop_ranges_display "$meta")
    local old_name; old_name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport") || { _error "生成新元数据失败"; return 1; }
    _info "检测到端口跳跃规则, 正在统一事务更新(config/metadata/iptables)..."
    # shellcheck disable=SC2086
    if ! _hy2_port_txn "$tag" "$meta" "$oldport" "$newport" "$newmeta" $ranges; then
        _warn "端口修改未完成, 已回滚到旧端口(config/metadata/iptables 保持一致)"
        _warn "请检查 iptables 环境后重试"
        return 1
    fi
    _tip "端口跳跃规则已更新: ${display} → ${newport}"
    # 派生状态(链接 + clash)走唯一入口, 并传 old_name 删除改名前的 clash 条目
    # (与 _modify_port 非 hop 路径完全同源; hy2 改端口不存在第二份派生逻辑)
    _hy2_sync_derived "$meta" "$old_name" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    return 0
}

# 从元数据读取端口跳跃范围(兼容旧格式 hop_start/hop_end)
_read_hop_ranges() {    local meta="$1"
    # 优先读 hop_ranges (iptables 时代格式)
    local ranges
    ranges=$(jq -r '.hop_ranges // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges" | tr ',' ' ' | tr '-' ':'
        return
    fi
    # 兼容 udp_hop_ports (udpHop 时代格式, 同样可用于 iptables)
    ranges=$(jq -r '.udp_hop_ports // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges" | tr ',' ' ' | tr '-' ':'
        return
    fi
    # 最旧格式兼容
    local hop_s hop_e
    hop_s=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
    hop_e=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
    if [ -n "$hop_s" ] && [ -n "$hop_e" ]; then
        if [ "$hop_s" = "$hop_e" ]; then echo "$hop_s"; else echo "${hop_s}:${hop_e}"; fi
    fi
}

# R31/R32(P1,P2): HY2 删除/改端口前校验 hop metadata 可解析。区分"无 hop"与"metadata 损坏":
# 所有 hop 字段缺失 → 无 hop(正常, 返回 0); 任一 hop 字段存在但内容不是合法 range
# (纯数字 / 数字:数字) → 损坏(返回 1, 调用方必须中止操作)。R32(P2): 逐字段独立校验
# (hop_ranges / udp_hop_ports / hop_start+hop_end), 不用 // 把它们当互斥字段——否则
# hop_ranges="" 而 udp_hop_ports=坏数据会被漏过。正常 metadata 由启用时写入、禁用时 del,
# 字段存在即必有合法内容, 因此空串/坏值一律判损坏。
_hy2_hop_meta_ok() {
    local tag="$1"
    local meta="$NODES_DIR/${tag}.json"
    if ! jq -e . "$meta" >/dev/null 2>&1; then
        _error "节点元数据损坏, 无法安全读取: $tag"
        return 1
    fi
    local f v r hs he s e toks tok
    for f in hop_ranges udp_hop_ports; do
        if jq -e "has(\"$f\")" "$meta" >/dev/null 2>&1; then
            v=$(jq -r ".$f" "$meta" 2>/dev/null)
            if [ -z "$v" ]; then
                _error "节点 hop 字段为空, 无法安全操作: $tag ($f)"
                return 1
            fi
            toks=$(printf '%s' "$v" | tr ',' ' ' | tr '-' ':')
            # R33(P2): 字段存在但无任何有效 token(",," 等 → 只剩空白) → 损坏, 不当作"无 hop"
            local ntok=0
            for tok in $toks; do
                ntok=$((ntok+1))
                if [[ "$tok" =~ ^[0-9]+$ ]]; then
                    if ! { [ "$tok" -ge 1 ] && [ "$tok" -le 65535 ]; }; then
                        _error "节点 hop 端口越界(1-65535), 无法安全操作: $tag ($f=$tok)"
                        return 1
                    fi
                elif [[ "$tok" =~ ^([0-9]+):([0-9]+)$ ]]; then
                    s="${BASH_REMATCH[1]}"; e="${BASH_REMATCH[2]}"
                    if ! { [ "$s" -ge 1 ] && [ "$s" -le 65535 ] && [ "$e" -ge 1 ] && [ "$e" -le 65535 ] && [ "$s" -le "$e" ]; }; then
                        _error "节点 hop 范围非法(start/end 或越界), 无法安全操作: $tag ($f=$tok)"
                        return 1
                    fi
                else
                    _error "节点 hop 范围无法解析, 无法安全操作: $tag ($f=$tok)"
                    return 1
                fi
            done
            [ "$ntok" -gt 0 ] || {
                _error "节点 hop 字段无有效范围, 无法安全操作: $tag ($f=$v)"
                return 1
            }
        fi
    done
    if jq -e 'has("hop_start") or has("hop_end")' "$meta" >/dev/null 2>&1; then
        hs=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
        he=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
        # R33(P2): 旧格式键存在即须 hs/he 均为非空数字且 1-65535、start<=end
        if [ -z "$hs" ] || [ -z "$he" ] || \
           ! [[ "$hs" =~ ^[0-9]+$ ]] || ! [[ "$he" =~ ^[0-9]+$ ]] || \
           [ "$hs" -lt 1 ] || [ "$hs" -gt 65535 ] || \
           [ "$he" -lt 1 ] || [ "$he" -gt 65535 ] || [ "$hs" -gt "$he" ]; then
            _error "节点旧格式 hop 范围非法(数值/边界), 无法安全操作: $tag"
            return 1
        fi
    fi
    return 0
}

# 从元数据读取端口跳跃范围(人类可读格式)
_read_hop_ranges_display() {
    local meta="$1"
    local ranges
    ranges=$(jq -r '.hop_ranges // empty' "$meta" 2>/dev/null)
    [ -z "$ranges" ] && ranges=$(jq -r '.udp_hop_ports // empty' "$meta" 2>/dev/null)
    if [ -n "$ranges" ]; then
        echo "$ranges"
        return
    fi
    local hop_s hop_e
    hop_s=$(jq -r '.hop_start // empty' "$meta" 2>/dev/null)
    hop_e=$(jq -r '.hop_end // empty' "$meta" 2>/dev/null)
    if [ -n "$hop_s" ] && [ -n "$hop_e" ]; then
        if [ "$hop_s" = "$hop_e" ]; then echo "$hop_s"; else echo "${hop_s}-${hop_e}"; fi
    fi
}

# 列出所有 xray-deploy 端口跳跃规则(IPv4 + IPv6)
_hy2_list_all_hop_rules() {
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -S PREROUTING 2>/dev/null | grep "xray-deploy-hy2-hop" || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -S PREROUTING 2>/dev/null | grep "xray-deploy-hy2-hop" || true
    fi
}

# 清理所有节点的端口跳跃 iptables 规则
_hy2_cleanup_all_hops() {
    [ -d "$NODES_DIR" ] || return 0
    if ! command -v iptables >/dev/null 2>&1; then
        # R33(P2): iptables 不可用时不阻塞 reset, 但存在 hop metadata 时必须显式提示——
        # 否则 metadata 随 reset 删除后, DNAT 可能残留且无法追溯
        if grep -lq 'hop_ranges\|udp_hop_ports' "$NODES_DIR"/*.json 2>/dev/null; then
            _warn "iptables 不可用, 无法验证/清理端口跳跃规则(存在 hop metadata), 请手动检查 iptables -t nat -S PREROUTING"
        fi
        return 0
    fi
    local found=0 residual=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local port ranges
        port=$(jq -r '.port' "$f" 2>/dev/null)
        ranges=$(_read_hop_ranges "$f")
        if [ -n "$ranges" ] && [ -n "$port" ]; then
            # R17: 全量重置场景 metadata 整体丢弃, 清理为 best-effort; 但残留必须显式报告, 不静默
            # shellcheck disable=SC2086
            _hy2_remove_hop_rules "$port" $ranges || residual=1
            found=1
        fi
    done
    if [ "$found" -eq 1 ]; then
        _hy2_persist_iptables || _warn "iptables 规则持久化失败, 重启后可能丢失"
    fi
    [ "$residual" -eq 0 ] || _warn "部分端口跳跃规则清理后仍有残留, 请手动检查 iptables -t nat -S PREROUTING"
}

# ---------------------------------------------------------------------------
# 通用端口输入(带冲突检测)
# ---------------------------------------------------------------------------

# 生成随机端口(20000-65000)
_gen_random_port() {
    local lo hi range r
    lo=20000; hi=65000; range=$((hi-lo+1))
    # /dev/urandom 取 2 字节做随机数(无 Math.random 限制)
    r=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
    [ -z "$r" ] && r=${RANDOM:-$(( $$ % 45000 + 20000 ))}
    echo $(( lo + (r % range) ))
}

_input_port() {
    local proto="${1:-}"  # optional: tcp, udp, or empty (both)
    local port="" def
    def=$(_gen_random_port)
    while true; do
        read -rp "  监听端口 (回车随机生成): " port
        port=${port:-$def}
        if ! _validate_port "$port"; then
            _warn "无效端口(1-65535)"; continue
        fi
        if _check_port_occupied "$port" "${proto:-}"; then
            _warn "端口 ${port} 已被占用,换一个"; def=$(_gen_random_port); continue
        fi
        if _check_port_in_config "$port"; then
            _warn "端口 ${port} 已被其他节点使用,换一个"; def=$(_gen_random_port); continue
        fi
        break
    done
    echo "$port"
}

# 为 tunnel inbound(仅监听 127.0.0.1)生成一个排除已知冲突的随机端口(F9)。
# 原 `_gen_random_port` 裸输出: 撞上已占用端口/已在 config 的端口/与 $1 指定端口相同
# 时, verified-restart 会失败回滚, 用户只见"创建失败"。重试 20 次; 极端情况下仍放行
# 随机值, 由 _mutate_config 的 verified-restart 兜底。
# 用法: tport=$(_gen_free_tunnel_port [exclude_port])
_gen_free_tunnel_port() {
    local exclude="${1:-}" i r
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        r=$(_gen_random_port)
        [ -n "$exclude" ] && [ "$r" = "$exclude" ] && continue
        _check_port_occupied "$r" "" && continue
        _check_port_in_config "$r" && continue
        printf '%s' "$r"
        return 0
    done
    printf '%s' "$(_gen_random_port)"
    return 0
}

# 检查端口是否已存在于 config.json
_check_port_in_config() {
    local port="$1"
    # 入口校验: port 必须为数字 (M15: --argjson 对非数字行为未定义)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e --argjson p "$port" '.inbounds[] | select(.port == $p)' "$CONFIG_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Reality 密钥生成(xray x25519)
# 输出全局: REALITY_PRIVATE_KEY / REALITY_PUBLIC_KEY / REALITY_SHORT_ID
# ---------------------------------------------------------------------------
_generate_reality_keys() {
    local keypair
    keypair=$(XRAY_LOCATION_ASSET= "$XRAY_BIN" x25519 2>/dev/null)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk -F': ' '/^Private/ {print $2}')
    REALITY_PUBLIC_KEY=$(echo "$keypair" | awk -F': ' '/PublicKey/ {print $2}')
    REALITY_SHORT_ID=$(_gen_short_id)
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        _error "Reality 密钥生成失败"
        return 1
    fi
    _info "Reality 密钥已生成 (PrivateKey: ${REALITY_PRIVATE_KEY:0:8}...)"
}

# ---------------------------------------------------------------------------
# 渲染模板:占位符替换 + jq 合法化
# 用法:_render_template <template_file>  (读取全局渲染变量)
# 输出:合法 JSON 到 stdout
# ---------------------------------------------------------------------------
_render_template() {
    local tpl="$1" content
    content=$(cat "$tpl" 2>/dev/null)
    [ -z "$content" ] && { _error "模板读取失败: $tpl"; return 1; }

    # 给所有占位符变量设默认空值(避免 set -u 下 unbound; 各协议函数只设自己需要的)
    : "${R_LISTEN:=}" "${R_PORT:=}" "${R_TAG:=}" "${R_UUID:=}" "${R_TARGET:=}"
    : "${R_SERVER_NAME:=}" "${R_PRIVATE_KEY:=}" "${R_SHORT_ID:=}" "${R_PATH:=}"
    : "${R_HOST:=}" "${R_METHOD:=}" "${R_PASSWORD:=}" "${R_MLDSA65_SEED:=}"
    : "${R_AUTH:=}" "${R_CERT_FILE:=}" "${R_KEY_FILE:=}"
    : "${R_CONGESTION:=}" "${R_BRUTAL_PARAMS_BLOCK:=}" "${R_OBFS_MASK_BLOCK:=}"
    : "${R_TUNNEL_PORT:=}" "${R_TUNNEL_TAG:=}"
    : "${R_FLOW:=}" "${R_DECRYPTION:=none}" "${R_NETWORK:=}"

    # 模板已是纯 JSON(无注释),无需 sed 去注释

    # 占位符替换(用变量存 pattern, 避免 ${//\{\{...\}\}//} 转义歧义)
    local p
    p="{{LISTEN}}";       content="${content//$p/$R_LISTEN}"
    p="{{PORT}}";         content="${content//$p/$R_PORT}"
    p="{{TAG}}";          content="${content//$p/$R_TAG}"
    p="{{UUID}}";         content="${content//$p/$R_UUID}"
    p="{{TARGET}}";       content="${content//$p/$R_TARGET}"
    p="{{SERVER_NAME}}";  content="${content//$p/$R_SERVER_NAME}"
    p="{{PRIVATE_KEY}}";  content="${content//$p/$R_PRIVATE_KEY}"
    p="{{SHORT_ID}}";     content="${content//$p/$R_SHORT_ID}"
    p="{{PATH}}";         content="${content//$p/$R_PATH}"
    p="{{HOST}}";         content="${content//$p/$R_HOST}"
    p="{{METHOD}}";       content="${content//$p/$R_METHOD}"
    p="{{PASSWORD}}";     content="${content//$p/$R_PASSWORD}"
    p="{{TUNNEL_PORT}}";  content="${content//$p/$R_TUNNEL_PORT}"
    p="{{TUNNEL_TAG}}";   content="${content//$p/$R_TUNNEL_TAG}"
    p="{{FLOW}}";          content="${content//$p/$R_FLOW}"
    p="{{DECRYPTION}}";    content="${content//$p/$R_DECRYPTION}"
    p="{{NETWORK}}";      content="${content//$p/$R_NETWORK}"
    p="{{AUTH}}";         content="${content//$p/$R_AUTH}"
    p="{{CERT_FILE}}";    content="${content//$p/$R_CERT_FILE}"
    p="{{KEY_FILE}}";     content="${content//$p/$R_KEY_FILE}"
    p="{{CONGESTION}}";   content="${content//$p/$R_CONGESTION}"
    # Hysteria2 brutal 参数块(可选: brutal 模式注入, 否则置空)
    p="{{BRUTAL_PARAMS_BLOCK}}"
    if [ -n "$R_BRUTAL_PARAMS_BLOCK" ]; then
        content="${content//$p/$R_BRUTAL_PARAMS_BLOCK}"
    else
        content="${content//$p/}"
    fi
    # Hysteria2 混淆块(可选: 官方文档 finalmask.udp 数组; 未启用混淆时置空 → "udp": [])
    p="{{OBFS_MASK_BLOCK}}"
    if [ -n "$R_OBFS_MASK_BLOCK" ]; then
        content="${content//$p/$R_OBFS_MASK_BLOCK}"
    else
        content="${content//$p/}"
    fi
    # 后量子 seed 块(可选)
    p="{{MLDSA65_SEED_BLOCK}}"
    if [ -n "$R_MLDSA65_SEED" ]; then
        content="${content//$p/,
            \"mldsa65Seed\": \"$R_MLDSA65_SEED\"}"
    else
        content="${content//$p/}"
    fi

    # jq 合法化 + 美化(每字段单独行, 2 空格缩进)
    echo "$content" | jq . 2>/dev/null || {
        _error "模板渲染后 JSON 不合法"
        return 1
    }
}

# ---------------------------------------------------------------------------
# 统一的 config.json 修改流程: backup → jq → 重排 → verified-restart → 失败回滚
# 用法:_mutate_config [--arg/--argjson ...] <jq_filter>
# 参数: jq 选项在前, jq filter 在最后(必须)
# 所有 config 修改应通过此函数, 不再各自实现 backup/test/rollback。
# 并发防护(F5): 全体修改经 _with_config_lock 串行化, 实际事务体在 _mutate_config_locked。
# ---------------------------------------------------------------------------
_mutate_config() {
    _with_config_lock _mutate_config_locked "$@"
}

_mutate_config_locked() {
    if ! _backup_config; then
        _error "配置备份失败,中止操作"
        return 1
    fi
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || { _error "无法创建临时配置"; return 1; }
    # 获取最后一个参数(用户 filter), 其余是 jq 选项
    local user_filter="${!#}"
    # 应用 filter 后, 按官方字段顺序重排顶层字段(字段列表定义在 00-common XRAY_TOP_FIELDS_JSON)
    local reorder="| . as \$c | (${XRAY_TOP_FIELDS_JSON}) as \$known | (reduce \$known[] as \$k ({}; .[\$k] = \$c[\$k]) | with_entries(select(.value != null))) as \$ordered | (\$c | to_entries | map(select(.key as \$k | \$known | index(\$k) | not)) | from_entries) as \$extra | \$ordered + \$extra"
    local combined="${user_filter} ${reorder}"
    # 构建参数列表: 去掉最后一个(filter), 追加合并后的 filter
    local args=("${@:1:$#-1}" "${combined}")
    if ! jq "${args[@]}" "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        # 2026-09-12 三审: 仅失败路径重放一次拿 jq stderr(正常路径零开销),
        # 否则用户只见一句"jq 处理失败", 无法定位是哪段过滤/哪份手改配置出的问题。
        local jq_err; jq_err=$(jq "${args[@]}" "$CONFIG_FILE" 2>&1 >/dev/null | head -3)
        _error "jq 处理失败: ${jq_err:-未知错误}"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; _error "生成的配置为空"; return 1
    fi
    # R23: mv 失败必须显式中止 — 否则旧 config 仍在, _restart_xray_verified 用旧配置重启成功,
    # 会被误判为"新配置已提交"(静默假成功)。mv 失败时旧 config 未动, 直接 return 1。
    if ! mv -f "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        _error "配置替换失败, 保留旧配置"
        return 1
    fi
    # 低内存 VPS: 不再预跑 xray -test —— 它会与运行中的实例同时加载两份二进制+geo, 触发 OOM。
    # 改为重启后校验服务是否稳定在运行态; 坏配置/被 OOM 都会导致启动失败并回滚旧配置。
    if ! _restart_xray_verified; then
        _error "xray 启动失败,回滚配置"
        if ! _restore_config; then
            _error "回滚失败(config.json.lastbak 不存在或恢复出错),未尝试重启"
            return 1
        fi
        if _restart_xray_verified; then
            _warn "已回滚到旧配置并重启"
        else
            _error "回滚后 xray 仍启动失败,请手动检查"
        fi
        return 1
    fi
    return 0
}

# 把渲染好的 inbound 加入 config.json
_commit_inbound() {
    local inbound="$1"
    _mutate_config --argjson nb "$inbound" '.inbounds += [$nb]' || return 1
}

# Reality 专用: tunnel + reality inbound + 2 条路由规则
_commit_reality_inbound() {
    local tunnel="$1" reality="$2" tunnel_tag="$3" domain="$4"
    _mutate_config --argjson tb "$tunnel" --argjson rb "$reality" \
       --arg tg "$tunnel_tag" --arg dom "$domain" \
       '.inbounds += [$tb, $rb] | .routing.rules = [
            {inboundTag: [$tg], domain: [$dom], outboundTag: "direct"},
            {inboundTag: [$tg], outboundTag: "block"}] + .routing.rules' || return 1
}

# ---------------------------------------------------------------------------
# Reality 部署模式(R42)
# 两种拓扑, 协议键相同(vless-tcp-reality-vision / vless-xhttp-reality):
#   direct — 单个 Reality 入站, realitySettings.target = "<sni>:443" 直指真实伪装站,
#            无 tunnel 入站、无路由规则(官方 Xray-examples 标准形态)。
#   tunnel — 额外一个 protocol:"tunnel" 入站(127.0.0.1:<随机端口> → <sni>:443),
#            Reality target 指向该 tunnel + 2 条路由规则(域名命中 direct, 否则 block),
#            用于防止 target 是 CDN 站时服务器被当作端口转发偷跑流量。
# ---------------------------------------------------------------------------

# 创建时的模式选择(交互)。输出全局 REALITY_MODE; 返回 0=已选定, 1=用户取消。
# 默认(回车)为 direct —— 因此每次进入 direct 都必须回显偷跑风险(默认姿态比 tunnel 松)。
# 注意: 绝不对用户输入做算术(set -u 下 $((abc-1)) 会因引用不存在的变量名而崩溃)。
_prompt_reality_mode() {
    local choice
    REALITY_MODE=""
    while true; do
        echo
        echo -e "  ${CYAN}【Reality 部署模式】${NC}"
        echo -e "  ${GREEN}[1]${NC} 直连模式 (默认) — target 直指伪装站, 仅 1 个入站, 无额外路由"
        echo -e "  ${GREEN}[2]${NC} Tunnel 模式 — 多一个本地 tunnel 入站 + 2 条路由规则, 防偷跑"
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择 (回车=直连): " choice
        case "${choice:-1}" in
            1)
                REALITY_MODE="direct"
                _warn "直连模式: 鉴权失败的流量会被 Reality 直接转发到伪装站"
                _tip "伪装域名若在 CDN 后(如 Cloudflare 站), 可能被扫描后偷跑流量; 建议选非 CDN 的国外站"
                _tip "如需防偷跑请改选 [2] Tunnel 模式"
                return 0
                ;;
            2)
                REALITY_MODE="tunnel"
                _tip "Tunnel 模式会额外占用一个本机随机端口(仅监听 127.0.0.1)"
                return 0
                ;;
            0)
                _info "已取消"
                return 1
                ;;
            *)
                _warn "无效选择"
                ;;
        esac
    done
}

# 判定已存在 Reality 节点的部署模式 —— 全项目唯一入口, 下游(改端口/域名切换/采纳)
# 只允许通过本函数判模式, 不得各自散写推断。
# 用法: mode=$(_reality_node_mode <tag>)   stdout 恒为 "tunnel" 或 "direct", 返回 0。
#
# 判定原则: config 的 realitySettings.target 是实际运行状态, metadata 是声明的身份。
# metadata 只是"提示", 必须与 config 交叉校验; 任何不一致一律回退到保守侧 tunnel
# (tunnel 分支保留 R41 的 fail-closed, direct 分支会跳过 tunnel/路由一致性检查,
# 所以"无法确定"绝不能判成 direct —— 否则 metadata 被外部改坏时改端口会漏改 tunnel)。
#
# 优先级:
#   1. 先读 config realitySettings.target, 归为三类:
#        target 缺失 / 无端口段 / 端口非数字   => unknown(旧版/手工配置, 保守)
#        主机回环                              => tunnel
#        其它主机                              => direct
#   2. metadata reality_mode 必须是 direct|tunnel 之一才参与交叉校验(非法值视同无该字段):
#        direct + config=direct              => direct(一致)
#        direct + config≠direct              => _warn 冲突, 回退 tunnel(fail-closed)
#        tunnel + config∈{tunnel,unknown}    => tunnel(一致/保守)
#        tunnel + config=direct              => _warn 冲突, 回退 tunnel(fail-closed)
#   3. metadata 无(或非法)reality_mode: tunnel_tag 非空 ⇒ tunnel; 否则按第 1 步的 config 归类。
#   4. 都读不到 ⇒ tunnel(保守)。
# 为什么非法值必须忽略而不是原样返回: 本函数契约是 stdout 恒为 "tunnel"|"direct",
# 下游只按这两个值分支; 原样返回 "foobar" 会形成第 3 种模式, 改端口/域名切换/删除/采纳
# 全部行为未定义。
_reality_node_mode() {
    local tag="$1" meta mode ttag target host port cfg_mode
    meta="$NODES_DIR/${tag}.json"

    # 第 1 步: config 归类(实际状态)
    target=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.target // empty' "$CONFIG_FILE" 2>/dev/null) || target=""
    case "$target" in
        *:*) ;;
        *) printf 'tunnel'; return 0 ;;
    esac
    port="${target##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || { printf 'tunnel'; return 0; }
    host="${target%:*}"
    host="${host#[}"
    host="${host%]}"
    if _is_reality_loopback_host "$host"; then
        cfg_mode="tunnel"
    else
        cfg_mode="direct"
    fi

    if [ -f "$meta" ]; then
        mode=$(jq -r '.reality_mode // empty' "$meta" 2>/dev/null) || mode=""
        # 第 2 步: 交叉校验 —— 仅当 metadata 声明合法值; 非法/未知值一律忽略(见上方注释),
        # 落到第 3 步 tunnel_tag / config 判定, 绝不把非法字符串原样返回。
        case "$mode" in
            direct)
                if [ "$cfg_mode" != "direct" ]; then
                    _warn "Reality 节点 $tag: metadata 声明 direct, 但 config target=${target} 非直连, 判定为 tunnel(防绕过)"
                    printf 'tunnel'; return 0
                fi
                printf 'direct'; return 0
                ;;
            tunnel)
                if [ "$cfg_mode" = "direct" ]; then
                    _warn "Reality 节点 $tag: metadata 声明 tunnel, 但 config target=${target} 非回环, 判定为 tunnel(fail-closed)"
                    printf 'tunnel'; return 0
                fi
                printf 'tunnel'; return 0
                ;;
        esac
        # 第 3 步: metadata 无(或非法)reality_mode —— tunnel_tag 非空即 tunnel
        ttag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null) || ttag=""
        [ -n "$ttag" ] && { printf 'tunnel'; return 0; }
    fi

    printf '%s' "$cfg_mode"
    return 0
}

# target 主机是否为回环(tunnel 模式的 target 恒为 127.0.0.0/8:<tunnel_port>)
# R42 复审(P2): 只认 127.0.0.1 会把 127.0.0.2/127.10.x.x 等合法 IPv4 回环误判成 direct,
# 从而绕过 tunnel 分支的 fail-closed。这里把整个 127.0.0.0/8 纳入(带 0-255 段校验),
# 另保留 ::1 / localhost。
_is_reality_loopback_host() {
    case "$1" in
        "127.0.0.1"|"::1"|"localhost") return 0 ;;
    esac
    # 127.0.0.0/8: 127.<a>.<b>.<c>, 每段 0-255。10#$ 强制十进制, 避免 08/09 被当八进制
    if [[ "$1" =~ ^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}"
        if (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 )); then
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 保存节点元数据(每节点独立文件)
# 用法:_save_node_meta <tag> <json_object>
# ---------------------------------------------------------------------------
_save_node_meta() {
    local tag="$1" json="$2"
    # R21: 严格失败语义 — metadata 是节点身份的一部分(config 已提交而 json 缺失会让节点
    # 退化为 orphan, 破坏 tag/config/metadata 一致性)。用公共原子写 helper,
    # 失败显式返回 1, 不再静默吞掉。
    mkdir -p "$NODES_DIR" || { _error "无法创建节点元数据目录: $NODES_DIR"; return 1; }
    if ! _atomic_write_json "$NODES_DIR/${tag}.json" "$json"; then
        return 1
    fi
    # umask 077 下通常已是 600; chmod 失败属非致命加固项, 提示即可(不阻断写入成功)
    chmod 600 "$NODES_DIR/${tag}.json" 2>/dev/null || _warn "节点元数据权限设置失败(不影响功能): $tag"
    return 0
}

# R20: 节点名称唯一性校验。Clash/Mihomo 代理名必须唯一(重复名会导致配置无效);
# 同时本项目 clash.yaml 按 name 删除(YAML 单行 flow 条目), name 唯一才能保证删除精确、
# 不会误删同名节点。tag 是文件级稳定身份, name 是显示名——唯一性约束使二者在该场景一致。
# R38(P1): 不可读的 metadata 不再整体 fail —— 原写法让"任意一个损坏文件"永久阻断
# 所有新建节点(即使新名字与任何现存节点都不冲突), 这是拒绝服务而非安全。
# 现改为: 损坏文件跳过并告警(它的 name 未知, 无法参与比较), 只有"确实读到同名"才拒绝。
# R39(P2) 语义声明 —— **唯一性在存在损坏 metadata 时降级为 best-effort**:
#   损坏文件里可能恰好存着同名节点, 本函数无从得知, 因此不能声称"name 全局唯一"。
#   影响面: clash.yaml 按 name 删除时可能同时删掉两条同名条目(clash.yaml 属可再生的
#   派生导出, 权威身份始终是 tag/nodes/<tag>.json), 不会影响 config.json 与节点本体。
#   取舍理由: "一个坏文件让所有新建失败" 的代价远大于 "极小概率的派生缓存重名"。
#   调用方若需要严格唯一, 必须先修复/移除损坏的 metadata(本函数已把数量告知用户)。
# 返回: 0 唯一(或无法确认); 1 确实已存在(调用方应中止创建)
_ensure_unique_name() {
    local name="$1" f n rc bad=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$(jq -r '.name // empty' "$f" 2>/dev/null)
        rc=$?
        if [ "$rc" -ne 0 ] || [ ! -s "$f" ]; then
            bad=$((bad+1))
            continue
        fi
        [ -n "$n" ] && [ "$n" = "$name" ] && {
            _error "节点名称已存在: ${name}, 请使用不同名称"
            return 1
        }
    done
    [ "$bad" -eq 0 ] || {
        _warn "有 ${bad} 个节点元数据损坏/为空, 已跳过名称查重(唯一性降级为 best-effort)"
        _tip "请人工核对 ${NODES_DIR} 并修复/删除这些文件, 否则可能出现同名节点"
    }
    return 0
}

# ---------------------------------------------------------------------------
# 询问客户端连接地址(直连场景: 默认公网 IP, 取不到则必填)
# 输出地址到 stdout
# ---------------------------------------------------------------------------
_ask_link_addr() {
    local pubip="" hint
    pubip=$(_get_public_ip 2>/dev/null) || true
    if [ -n "$pubip" ]; then
        local addr
        read -rp "  客户端连接地址 (回车用公网IP ${pubip}): " addr
        addr=${addr:-$pubip}
        echo "$addr"
    else
        _warn "未能自动获取公网 IP,请手动填写客户端连接地址(公网IP或域名)"
        while true; do
            local addr
            # RT-1 同类: 管道驱动/会话异常的 EOF 下 read 立即返回且 addr 恒空, 无守卫会死循环刷告警。
            # EOF 即无法再获得输入, 显式 return 1 让调用方按"孤儿入站"惯例中止(5 个调用点均校验)。
            read -rp "  客户端连接地址: " addr || return 1
            [ -n "$addr" ] && { echo "$addr"; return 0; }
            _warn "不能为空"
        done
    fi
}

_node_count() {
    local n=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] && n=$((n+1))
    done
    echo "$n"
}

# ---------------------------------------------------------------------------
# 列出 config.json 中有元数据文件的入站 tag 集合(含 tunnel_tag)
# 输出: 每行一个 tag
# ---------------------------------------------------------------------------
_known_tags() {
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        basename "$f" .json
        local ttag
        ttag=$(jq -r '.tunnel_tag // empty' "$f" 2>/dev/null)
        # R23: 损坏/不可读 metadata 显式告警, 不静默丢 tunnel_tag(否则 tunnel 成永久孤儿)
        if [ $? -ne 0 ]; then
            _warn "节点元数据不可读, 无法读取 tunnel_tag: $f"
            continue
        fi
        [ -n "$ttag" ] && echo "$ttag"
    done
}

# ---------------------------------------------------------------------------
# R38(P1): 判断某个 inbound tag 是否由脚本管理(即 _known_tags 认它)。
# 受管 = 存在 nodes/<tag>.json, 或被某份 metadata 的 tunnel_tag 引用。
# 用于 orphan 清理的关联扩展闸门: 孤儿清理绝不能顺带删掉受管节点的入站。
# 返回: 0 受管; 1 未跟踪(可作为孤儿删除)
# ---------------------------------------------------------------------------
_tag_is_managed() {
    local tag="$1" f ttag
    [ -n "$tag" ] || return 1
    [ -f "$NODES_DIR/${tag}.json" ] && return 0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        ttag=$(jq -r '.tunnel_tag // empty' "$f" 2>/dev/null) || continue
        [ -n "$ttag" ] && [ "$ttag" = "$tag" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 给 config.json 中无 tag 的入站自动分配 tag
# 有 port: manual-<port> (如 manual-443)
# Unix socket: manual-<socket文件名去后缀> (如 manual-xrxh-socket)
# ---------------------------------------------------------------------------
_auto_tag_tagless_inbounds() {
    [ -f "$CONFIG_FILE" ] || return 0
    # 一次性读取所有入站的 tag/port/listen, 减少 jq 调用
    local inbounds_info
    inbounds_info=$(jq -c '[.inbounds | to_entries[] | {idx: .key, tag: (.value.tag // ""), port: (.value.port // 0), listen: (.value.listen // "")}]' "$CONFIG_FILE" 2>/dev/null) || return 0
    [ -z "$inbounds_info" ] || [ "$inbounds_info" = "[]" ] && return 0

    local used_tags
    used_tags=$(jq -r '.[] | select(.tag != "") | .tag' <<< "$inbounds_info" 2>/dev/null)

    local tagged=0
    local entry idx tag port listen new_tag
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        idx=$(jq -r '.idx' <<< "$entry")
        tag=$(jq -r '.tag' <<< "$entry")
        [ -n "$tag" ] && continue  # 已有 tag, 跳过

        port=$(jq -r '.port' <<< "$entry")
        listen=$(jq -r '.listen' <<< "$entry")

        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ] 2>/dev/null; then
            new_tag="manual-${port}"
        elif [ -n "$listen" ]; then
            local sock_name
            sock_name=$(basename "${listen%%,*}" | tr '[:upper:]' '[:lower:]' | sed 's/\.socket$/-socket/' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//')
            [ -z "$sock_name" ] && sock_name="sock-${idx}"
            new_tag="manual-${sock_name}"
        else
            new_tag="manual-${idx}"
        fi

        # 去重: 已存在则追加 -2 -3 ...
        local base="$new_tag" n=2
        while grep -qxF "$new_tag" <<< "$used_tags"; do
            new_tag="${base}-${n}"
            n=$((n+1))
        done
        used_tags="${used_tags}"$'\n'"${new_tag}"

        # 原子写 config(静默补 tag 不应触发 _mutate_config 的重启; 失败跳过该入站, 下次启动再试)
        local newcfg
        newcfg=$(jq --arg t "$new_tag" --argjson i "$idx" '.inbounds[$i].tag = $t' "$CONFIG_FILE") || continue
        _atomic_write_json "$CONFIG_FILE" "$newcfg" || continue
        tagged=$((tagged+1))
    done <<< "$(jq -c '.[]' <<< "$inbounds_info" 2>/dev/null)"

    [ "$tagged" -gt 0 ] && _info "已自动给 ${tagged} 个无 tag 入站分配标识"
    return 0
}

# ---------------------------------------------------------------------------
# R23/R26: 由 Reality 主入站唯一关联其 tunnel 入站 tag。关联键必须唯一:
# 多个 Reality 节点可共用同一 SNI(默认 www.amd.com), SNI/rewriteAddress 不唯一。
# 主键: realitySettings.target = "127.0.0.1:<tunnel_port>" 与 tunnel 入站 .port 一一对应。
# 兜底(target 缺失, 旧版/手工配置): tunnel tag = "Tunnel-<sni>-<tport>-<reality_port>",
# 末段是本节点 port(端口唯一), 按 tag 后缀匹配, 同样无 SNI 歧义。
# 用法: tag=$(_find_reality_tunnel_tag <reality_tag>); 非 Reality 或无 tunnel 输出空。
# 返回码三态(R28): 0=唯一关联(stdout=tunnel_tag) 1=无关联(stdout 空) 2=歧义(stdout 空, 禁止 fallback)
# ---------------------------------------------------------------------------
_find_reality_tunnel_tag() {
    local tag="$1" proto
    proto=$(_detect_inbound_protocol "$tag")
    case "$proto" in vless-tcp-reality-vision|vless-xhttp-reality) ;; *) return 1 ;; esac
    local target tport n ttag=""
    target=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.target // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$target" ]; then
        # R42: 先判 target 主机是否回环 —— 非回环即 direct 模式(target = <sni>:443), 本就无
        # tunnel 可关联, 必须 return 1(无关联)。若继续往下用 tport=443 去数 tunnel 入站,
        # 本机恰有一个监听 443 的 tunnel 入站时会被错误关联: orphan 清理会连带删掉别人的
        # tunnel, 改端口会去改错的 tag。这是严格收紧: 本项目写出的 tunnel 模板 target 恒为
        # 127.0.0.1:<tport>, _reality_domain_menu 的 tunnel 分支也从不改 target, 因此任何
        # 真实 tunnel 节点都不受影响。
        local thost="${target%:*}"
        thost="${thost#[}"
        thost="${thost%]}"
        _is_reality_loopback_host "$thost" || return 1
        # 主键: realitySettings.target = "127.0.0.1:<tunnel_port>" 与 tunnel .port 一一对应。
        # R28(P1): target 有效时命中数 != 1 一律禁止 legacy fallback——
        # 歧义(>1)返回 2 由调用方拒绝, 无匹配(=0)视为无关联返回 1, 均不再用 tag 后缀重绑。
        tport="${target##*:}"
        [[ "$tport" =~ ^[0-9]+$ ]] || return 1
        n=$(jq -r --argjson p "$tport" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p)] | length' "$CONFIG_FILE" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        if [ "$n" -eq 1 ]; then
            ttag=$(jq -r --argjson p "$tport" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p) | .tag][0]' "$CONFIG_FILE" 2>/dev/null)
            printf '%s' "$ttag"
            return 0
        fi
        [ "$n" -gt 1 ] && return 2
        return 1
    fi
    # target 缺失(旧版/手工配置) → legacy tag 后缀 fallback, 同样 count==1 才绑定
    local pport
    pport=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ "$pport" =~ ^[0-9]+$ ]] || return 1
    n=$(jq -r --arg sfx "-${pport}" '[.inbounds[] | select(.protocol == "tunnel") | select(.tag | endswith($sfx))] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    if [ "$n" -eq 1 ]; then
        ttag=$(jq -r --arg sfx "-${pport}" '[.inbounds[] | select(.protocol == "tunnel") | select(.tag | endswith($sfx)) | .tag][0]' "$CONFIG_FILE" 2>/dev/null)
        printf '%s' "$ttag"
        return 0
    fi
    [ "$n" -gt 1 ] && return 2
    return 1
}

# ---------------------------------------------------------------------------
# R30(P1): fail-closed 读取节点 protocol——metadata 损坏/缺失 protocol 时不能当"非 HY2"
# 跳过 hop teardown, 否则删节点后留下孤儿 DNAT。
# R38(P1): 但纯 fail-closed 没有逃生口——一个损坏文件会让该节点永远删不掉。这里补一个
# 可证伪的放行条件: 若能确认"本机根本不存在任何 xray-deploy hop 规则", 就不可能泄漏
# DNAT, 按非 HY2 处理是安全的。无法确认(iptables 缺失 / -S 失败)时仍然拒绝, 并给出
# 明确的人工处置路径, 而不是笼统报错。
# 输出: protocol 字符串(放行时可能是 unknown); 返回 0 允许继续, 1 拒绝
# ---------------------------------------------------------------------------
_node_protocol_safe() {
    local tag="$1" proto meta
    # 注意: 不能写成 `local tag="$1" meta="$NODES_DIR/${tag}.json"` —— bash 会先展开
    # local 的全部参数再执行赋值, 那里的 ${tag} 取到的是调用方作用域的 tag(或空), 不是 $1。
    meta="$NODES_DIR/${tag}.json"
    proto=$(jq -r '.protocol // empty' "$meta" 2>/dev/null) || proto=""
    if [ -n "$proto" ]; then
        printf '%s' "$proto"
        return 0
    fi
    if _hy2_no_hop_rules_at_all; then
        _warn "节点元数据损坏或缺少 protocol, 但本机无任何端口跳跃规则, 按非 HY2 处理: $tag"
        printf '%s' "unknown"
        return 0
    fi
    _error "节点元数据损坏且本机存在端口跳跃规则, 无法确认归属, 拒绝删除: $tag"
    _tip "请核对 iptables -t nat -S PREROUTING 与 ${meta}, 手工清理后重试"
    return 1
}

# R30(P1): 判断 tunnel 入站的 port 是否被多个 tunnel 共用(ownership 歧义)。
# 返回 0=歧义(>1), 1=唯一或无法判定。反向展开 parent Reality 前必须确认 port 唯一,
# 否则删 parent Reality + 一个 tunnel 会留下同 port 兄弟 tunnel(半套)。
_tunnel_port_ambiguous() {
    local tag="$1" port n
    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    n=$(jq -r --argjson p "$port" '[.inbounds[] | select(.protocol == "tunnel") | select(.port == $p)] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    [ "$n" -gt 1 ]
}

# ---------------------------------------------------------------------------
# R27(P1): 反向关联——由 tunnel 入站找 parent Reality 主入站 tag。
# 关联键: tunnel .port == realitySettings.target 的端口(一一对应, 非 SNI)。
# 异常配置下可能命中多个 Reality(共用同一 tunnel), 一并输出(每行一个),
# 供 orphan remove 扩展删除集合; 无匹配输出空。
# R38(BLOCKER): `.a // "" == $t` 里 jq 的 // 优先级低于 ==, 会被解析成
#   `.a // ("" == $t)` => `.a // false`, $target 根本不参与比较, 于是"任何带
#   realitySettings.target 的 vless 入站"全部命中 —— 删一个孤儿 tunnel 会把 config
#   里所有 Reality 入站一并删掉(metadata 仍在 => 幽灵节点)。必须显式加括号。
# ---------------------------------------------------------------------------
_find_reality_for_tunnel_tag() {
    local tag="$1" proto tport target
    proto=$(_detect_inbound_protocol "$tag")
    [ "$proto" = "tunnel" ] || return 0
    tport=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
    [[ "$tport" =~ ^[0-9]+$ ]] || return 0
    target="127.0.0.1:${tport}"
    jq -r --arg target "$target" \
        '[.inbounds[] | select(.protocol == "vless") | select((.streamSettings.realitySettings.target // "") == $target) | .tag][]' \
        "$CONFIG_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 采纳单个入站: 从 config.json 推断元数据, 创建 nodes/*.json
# 返回 0 = 成功, 1 = 跳过(tunnel)
# ---------------------------------------------------------------------------
_adopt_single_inbound() {
    local tag="$1" suffix="${2:-adopted}"
    local proto port listen
    proto=$(_detect_inbound_protocol "$tag")
    [ "$proto" = "tunnel" ] && return 1

    # R26: name 采用 tag, 必须保持 R20 的 name 唯一不变量——若现有节点已用该名, 拒绝采纳
    if ! _ensure_unique_name "$tag"; then
        return 1
    fi

    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // 0' "$CONFIG_FILE" 2>/dev/null)
    [[ "$port" =~ ^[0-9]+$ ]] || port=0
    listen=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen // "::"' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$listen" ] && listen="::"

    local uuid=""
    uuid=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.clients[0].id // empty' "$CONFIG_FILE" 2>/dev/null)
    local sni=""
    sni=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.realitySettings.serverNames[0] // empty' "$CONFIG_FILE" 2>/dev/null)

    # R23: Reality 多 inbound — 重建 tunnel_tag(唯一关联键, 见 _find_reality_tunnel_tag)。
    # R28(P1): 关联歧义(rc2)必须拒绝采纳——否则 tunnel_tag="" 会把坏配置"合法化",
    # 后续删除泄漏 tunnel; 无关联(rc1)可正常采纳(tunnel 保持孤儿), 唯一(rc0)写入 tunnel_tag。
    # R42: 先经唯一入口判模式 —— direct 节点(target 直指伪装站)本就无 tunnel, 不做关联推导,
    # 也不写 tunnel_tag(写空串会误导下游把它当"关联损坏的 tunnel 节点")。
    local ttag="" trc=1 rmode=""
    if [ "$proto" = "vless-tcp-reality-vision" ] || [ "$proto" = "vless-xhttp-reality" ]; then
        rmode=$(_reality_node_mode "$tag")
        if [ "$rmode" = "tunnel" ]; then
            ttag=$(_find_reality_tunnel_tag "$tag"); trc=$?
            if [ "$trc" = "2" ]; then
                _error "Reality tunnel 关联存在歧义(多个 tunnel 命中同端口), 拒绝采纳: $tag"
                return 1
            fi
        fi
    fi

    local link="#${tag} (${suffix})"
    local meta_json
    # R42(P2 复审): 与创建路径一致 —— tunnel_tag 只属于 tunnel 拓扑, direct 节点不得
    # 写 tunnel_tag:"" (空字段会误导下游把它当"关联损坏的 tunnel 节点")。基础对象先不含
    # tunnel_tag, 仅在 tunnel 模式下追加(含 orphan 无关联时为空串的既有语义)。
    meta_json=$(jq -n \
        --arg tag "$tag" --arg proto "$proto" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg sni "$sni" --arg link "$link" \
        '{tag:$tag,name:$tag,protocol:$proto,port:$port,listen:$listen,uuid:$uuid,sni:$sni,link_addr:$listen,share_link:$link}') || {
        _warn "采纳失败: 元数据生成失败($tag)"
        return 1
    }
    if [ "$rmode" = "tunnel" ]; then
        meta_json=$(echo "$meta_json" | jq --arg ttag "$ttag" '. + {tunnel_tag:$ttag}') || {
            _warn "采纳失败: 元数据生成失败($tag)"
            return 1
        }
    fi
    # R42: 仅 Reality 协议带 reality_mode 字段(其它协议无此概念)
    if [ -n "$rmode" ]; then
        meta_json=$(echo "$meta_json" | jq --arg m "$rmode" '. + {reality_mode:$m}') || {
            _warn "采纳失败: 元数据生成失败($tag)"
            return 1
        }
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _warn "采纳失败: 元数据写入失败($tag)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 自动采纳孤儿入站: 为无元数据的入站创建 nodes/*.json
# 启动时静默运行, 不询问用户
# ---------------------------------------------------------------------------
_auto_adopt_orphans() {
    [ -f "$CONFIG_FILE" ] || return 0
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"
    local known_list
    known_list=$(_known_tags)

    local tags_json
    tags_json=$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$tags_json" ] || [ "$tags_json" = "[]" ] && return 0

    local orphans=()
    local tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if ! grep -qxF "$tag" <<< "$known_list"; then
            orphans+=("$tag")
        fi
    done <<< "$(jq -r '.[]' <<< "$tags_json" 2>/dev/null)"

    [ ${#orphans[@]} -eq 0 ] && return 0

    local adopted=0
    for tag in "${orphans[@]}"; do
        if _adopt_single_inbound "$tag" "auto-adopted"; then
            adopted=$((adopted+1))
        fi
    done
    [ "$adopted" -gt 0 ] && _info "已自动采纳 ${adopted} 个手动入站(分享链接需手动重建)"
    return 0
}

# ---------------------------------------------------------------------------
# 检测 config.json 中的孤儿入站(手动添加,无元数据)
# 返回 0 = 有孤儿, 1 = 无
# ---------------------------------------------------------------------------
_has_orphan_inbounds() {
    [ -f "$CONFIG_FILE" ] || return 1
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"
    local tags_json
    tags_json=$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE" 2>/dev/null) || return 1
    [ -z "$tags_json" ] && return 1
    [ "$tags_json" = "[]" ] && return 1
    local known_list
    known_list=$(_known_tags)
    local tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if ! grep -qxF "$tag" <<< "$known_list"; then
            return 0
        fi
    done <<< "$(jq -r '.[]' <<< "$tags_json" 2>/dev/null)"
    return 1
}

# ---------------------------------------------------------------------------
# 从 config.json 入站推断协议类型(按 tag)
# ---------------------------------------------------------------------------
_detect_inbound_protocol() {
    local tag="$1"
    local proto security net
    proto=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .protocol' "$CONFIG_FILE" 2>/dev/null)
    [ "$proto" = "tunnel" ] && { echo "tunnel"; return; }
    if [ "$proto" = "vless" ]; then
        security=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.security // "none"' "$CONFIG_FILE" 2>/dev/null)
        net=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .streamSettings.network // "raw"' "$CONFIG_FILE" 2>/dev/null)
        case "$security" in
            reality)
                case "$net" in
                    xhttp) echo "vless-xhttp-reality" ;;
                    *)     echo "vless-tcp-reality-vision" ;;
                esac ;;
            tls)     echo "vless-tls-$net" ;;
            *)
                # 检测 VLESS+ENC: 有 decryption 字段且 network=raw
                local dec
                dec=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.decryption // empty' "$CONFIG_FILE" 2>/dev/null)
                if [ -n "$dec" ] && [ "$dec" != "none" ] && [ "$net" = "raw" ]; then
                    echo "vless-enc"
                else
                    case "$net" in
                        xhttp)     echo "vless-xhttp-cdn" ;;
                        websocket) echo "vless-ws-cdn" ;;
                        *)         echo "vless-$net" ;;
                    esac
                fi
                ;;
        esac
    elif [ "$proto" = "shadowsocks" ]; then
        echo "shadowsocks"
    elif [ "$proto" = "hysteria" ]; then
        echo "hysteria2"
    else
        echo "$proto"
    fi
}

# ---------------------------------------------------------------------------
# 同步配置: 检测孤儿入站, 提供清理/采纳选项
# ---------------------------------------------------------------------------
_sync_config_check() {
    clear
    echo
    echo -e "  ${CYAN}【同步配置入站】${NC}"
    echo -e "  扫描 config.json 中未由脚本管理的入站..."
    echo

    [ -f "$CONFIG_FILE" ] || { _warn "config.json 不存在"; _press_any_key; return; }
    [ -d "$NODES_DIR" ] || mkdir -p "$NODES_DIR"

    # 先自动给无 tag 入站分配 tag(幂等, 已分配的不变)
    _auto_tag_tagless_inbounds

    local tags_json
    tags_json=$(jq -c '[.inbounds[]?.tag // empty]' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$tags_json" ] || [ "$tags_json" = "[]" ]; then
        _info "config.json 无任何入站"
        _press_any_key; return
    fi

    local known_list
    known_list=$(_known_tags)

    local orphans=()
    local tag
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        if ! grep -qxF "$tag" <<< "$known_list"; then
            orphans+=("$tag")
        fi
    done <<< "$(jq -r '.[]' <<< "$tags_json" 2>/dev/null)"

    if [ ${#orphans[@]} -eq 0 ]; then
        _success "所有入站均由脚本管理, 无需同步"
        _press_any_key; return
    fi

    echo -e "  ${YELLOW}发现 ${#orphans[@]} 个未跟踪入站:${NC}"
    echo
    printf "  %-3s %-30s %-16s %-7s %-8s\n" "#" "Tag" "协议" "端口" "监听"
    echo "  ---------------------------------------------------------------------------"
    local i=1
    for tag in "${orphans[@]}"; do
        local proto port listen
        proto=$(_detect_inbound_protocol "$tag")
        port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // "-"' "$CONFIG_FILE" 2>/dev/null)
        listen=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen // "::"' "$CONFIG_FILE" 2>/dev/null)
        [ ${#tag} -gt 28 ] && tag="${tag:0:25}..."
        printf "  %-3s %-30s %-16s %-7s %-8s\n" "[$i]" "$tag" "$proto" "$port" "$listen"
        i=$((i+1))
    done
    echo
    echo -e "  ${GREEN}[1]${NC} 从 config.json 移除选中入站"
    echo -e "  ${GREEN}[2]${NC} 移除全部未跟踪入站"
    echo -e "  ${GREEN}[3]${NC} 采纳为脚本管理节点(创建元数据)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    read -rp "  请选择: " action

    case "$action" in
        1)
            read -rp "  输入要移除的编号(逗号分隔, 如 1,3,5): " sel
            local to_remove=()
            IFS=',' read -ra nums <<< "$sel"
            for n in "${nums[@]}"; do
                n=$(echo "$n" | tr -d ' ')
                [[ "$n" =~ ^[0-9]+$ ]] || continue
                local idx=$((n-1))
                [ "$idx" -ge 0 ] && [ "$idx" -lt "${#orphans[@]}" ] && to_remove+=("${orphans[$idx]}")
            done
            [ ${#to_remove[@]} -eq 0 ] && { _warn "无有效选择"; _press_any_key; return; }
            _remove_orphan_inbounds "${to_remove[@]}"
            ;;
        2)
            echo -e "  ${RED}确认移除全部 ${#orphans[@]} 个未跟踪入站?${NC}"
            read -rp "  继续? [y/N]: " ans
            case "$ans" in
                y|Y) _remove_orphan_inbounds "${orphans[@]}" ;;
                *) _info "已取消" ;;
            esac
            ;;
        3)
            _adopt_orphan_inbounds "${orphans[@]}"
            ;;
        *)
            _info "已取消"
            ;;
    esac
    _press_any_key
}

# ---------------------------------------------------------------------------
# 从 config.json 移除孤儿入站 + 关联路由规则
# ---------------------------------------------------------------------------
_remove_orphan_inbounds() {
    local tags=("$@")
    [ ${#tags[@]} -eq 0 ] && return 0

    # R26/R27: orphan remove 双向扩展关联结构, 避免留下半套:
    # 选 Reality → 关联 tunnel(唯一键 target port);
    # 选 Tunnel   → 反向找 parent Reality(target 端口匹配, 非 SNI)——否则
    # 只删 tunnel 会留下指向已删 tunnel 的死 Reality 入站。
    # 关联健壮性见 _find_reality_tunnel_tag(0=唯一 1=无关联 2=歧义)。
    # R29(P1): 不再以"用户原始选择"为删除集合——先逐个验证关联, 只把可安全删除的项
    # 放入 safe set: unique→tag+tunnel, none→tag, ambiguous→排除该 tag(否则删主
    # Reality 会留下 tunnel+routing 半套)。多选中歧义项被排除, 合法项仍删除。
    # R38(P1): 扩展项必须是"未跟踪入站"——本函数只清理孤儿, 绝不能因为关联扩展就删掉
    # 受管节点(有 nodes/<tag>.json)的入站: 那会留下"metadata+clash.yaml 在、inbound 没了"
    # 的反向半套, 且用户看到的是"成功"。命中受管扩展项时整项排除, 引导用户走 [删除节点]。
    local safe=() excluded=() managed=()
    local tag ttag trc rtags rt
    for tag in "${tags[@]}"; do
        ttag=$(_find_reality_tunnel_tag "$tag"); trc=$?
        if [ "$trc" = "2" ]; then
            excluded+=("$tag")
            continue
        fi
        # R30(P1): Tunnel ownership gate —— 必须在 safe+= 之前判定; 多 tunnel 同 port 时
        # ownership 不成立, 排除该项(否则删 parent Reality + 一个 tunnel 留下同 port 兄弟)
        if [ "$(_detect_inbound_protocol "$tag")" = "tunnel" ] && _tunnel_port_ambiguous "$tag"; then
            excluded+=("$tag")
            continue
        fi
        # R38(P1): 先把本项的完整删除集合算出来并逐个检查"是否受管", 任一受管则整项不删
        local group=("$tag") mgr=""
        [ "$trc" = "0" ] && [ -n "$ttag" ] && group+=("$ttag")
        rtags=$(_find_reality_for_tunnel_tag "$tag")
        # R38(P1): 必须逐行读——tag 可含空格(伪装域名曾无字符校验, tunnel_tag 由 SNI 拼成),
        # 无引号 $rtags 会按 IFS 分词并做 glob 展开, 把真实 tag 切碎 => jq 删不到 => 半套
        while IFS= read -r rt; do
            [ -n "$rt" ] && group+=("$rt")
        done <<< "$rtags"
        for rt in "${group[@]}"; do
            if _tag_is_managed "$rt"; then
                mgr="$rt"
                break
            fi
        done
        if [ -n "$mgr" ]; then
            managed+=("${tag} → ${mgr}")
            continue
        fi
        safe+=("${group[@]}")
    done
    if [ ${#excluded[@]} -gt 0 ]; then
        _warn "以下 orphan 因 Reality↔tunnel 关联歧义被取消删除(请人工核对 config): ${excluded[*]}"
    fi
    if [ ${#managed[@]} -gt 0 ]; then
        _warn "以下 orphan 的关联入站属于脚本管理的节点, 已取消删除(避免删掉受管节点): ${managed[*]}"
        _tip "如需删除这些节点请使用 [删除节点], 它会同时清理 config/元数据/Clash 配置"
    fi
    if [ ${#safe[@]} -eq 0 ]; then
        _error "没有可安全删除的入站"
        return 1
    fi
    # 去重(双向扩展可能重复命中同一 tag)
    local uniq=() t u found
    for t in "${safe[@]}"; do
        found=0
        for u in "${uniq[@]}"; do
            [ "$u" = "$t" ] && { found=1; break; }
        done
        [ "$found" = 0 ] && uniq+=("$t")
    done
    safe=("${uniq[@]}")

    local tags_json
    if ! tags_json=$(printf '%s\n' "${safe[@]}" | jq -R . | jq -c -s .); then
        _error "生成移除集合失败"
        return 1
    fi

    # 2026-09-12 三审(M2): 规则过滤加 (type != "object") 前置守卫 —— 手工编辑可能把某条
    # 规则写成裸字符串, 旧过滤对其求 .inboundTag 会让 jq 整体报错中止, 于是"移除孤儿入站"
    # 在最需要它的坏配置上反而不可用(4 处同类过滤一并修复)。非对象元素一律保留(不是我们的业务)。
    # 注意 inbounds 段必须用 `as $tg` 先绑定 tag 再 index —— jq 的 index(f) 参数以被索引
    # 数组为输入求值, 直接写 index(.tag // "") 会把 .tag 作用到 $rm 上而报错(实测)。
    local filter='.inbounds |= map(select((type != "object") or ((.tag // "") as $tg | ($rm | index($tg)) == null)))
                 | .routing.rules |= map(select((type != "object") or .inboundTag == null
                       or ([.inboundTag[]? | . as $it | ($rm | index($it)) == null] | all)))'

    if _mutate_config --argjson rm "$tags_json" "$filter"; then
        _success "已移除 ${#safe[@]} 个入站"
    else
        _error "移除失败, 已回滚"
    fi
}

# ---------------------------------------------------------------------------
# 采纳孤儿入站: 从 config.json 推断元数据, 创建 nodes/*.json
# ---------------------------------------------------------------------------
_adopt_orphan_inbounds() {
    local tags=("$@")
    local adopted=0 failed=0
    for tag in "${tags[@]}"; do
        if _adopt_single_inbound "$tag" "adopted"; then
            adopted=$((adopted+1))
            _info "已采纳: $tag"
        else
            failed=$((failed+1))
        fi
    done
    # R23: 部分失败必须如实报告, 不能整体假装成功; 返回码反映是否全部成功
    [ "$failed" -eq 0 ] || _warn "有 ${failed} 个入站采纳失败"
    if [ "$adopted" -eq 0 ]; then
        _error "未采纳任何入站"
        return 1
    fi
    _success "已采纳 ${adopted} 个入站(分享链接需手动重建)"
    _tip "采纳的节点缺少完整参数, 建议使用 [查看节点] 确认, 或删后重建"
    [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 添加节点:协议分发
# PROTOCOLS 的 name 字段已含对齐空格, 直接打印
# ---------------------------------------------------------------------------
_add_node() {
    clear
    # 规约(backend/quality-guidelines「Don't: hardcode a menu number in a message emitted from
    # another module」): 运维/核心区的编号由 _main_menu 按 _core/_ops_start 现算, 写死字面量
    # 只在下一次插入菜单项前正确 —— 这里原本写死 `[8]`, 而 [8] 现已是「Hysteria2 管理」。
    # 只点名目的地, 不写编号。
    [ -x "$XRAY_BIN" ] || { _error "Xray 未安装,请先到主菜单的 [安装/更新或切换 Xray 核心] 安装核心"; _press_any_key; return 1; }
    _ensure_dirs || return 1
    echo
    echo -e "  ${CYAN}【添加节点 — 选择协议】${NC}"
    echo -e "  ${YELLOW}提示: 标记「必须套CDN」的协议不能直连, 需经 CDN 回源${NC}"
    echo
    local i=1
    for p in "${PROTOCOLS[@]}"; do
        local key name tls route desc
        IFS='|' read -r key name tls route desc <<< "$p"
        if [ -n "$desc" ]; then
            printf "  ${GREEN}[%d]${NC} %s   %s\n" "$i" "$name" "$desc"
        else
            printf "  ${GREEN}[%d]${NC} %s\n" "$i" "$name"
        fi
        i=$((i+1))
    done
    echo -e "  ${GREEN}[0]${NC} 返回"
    echo
    read -rp "  请选择协议: " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1))
    local sel="${PROTOCOLS[$idx]:-}"
    [ -z "$sel" ] && { _warn "无效选择"; _press_any_key; return; }

    local key tls route desc
    IFS='|' read -r key name tls route desc <<< "$sel"
    case "$key" in
        vless-tcp-reality-vision) _add_vless_tcp_reality_vision ;;
        vless-xhttp-reality)      _add_vless_xhttp_reality ;;
        vless-enc)                _add_vless_enc ;;
        vless-xhttp-cdn)          _add_vless_xhttp_cdn ;;
        vless-ws-cdn)             _add_vless_ws_cdn ;;
        shadowsocks)              _add_shadowsocks ;;
        hysteria2)                _add_hysteria2 ;;
        *) _warn "未知协议" ;;
    esac
    _press_any_key
}

# ---------------------------------------------------------------------------
# 协议1: VLESS+TCP+Reality+Vision (可选 直连 / Tunnel 模式, 见 _prompt_reality_mode)
# ---------------------------------------------------------------------------
_add_vless_tcp_reality_vision() {
    _prompt_reality_mode || return 1
    local mode="$REALITY_MODE" mode_label="直连模式"
    [ "$mode" = "tunnel" ] && mode_label="Tunnel 模式·防偷跑"
    echo -e "\n  ${CYAN}=== VLESS+TCP+Reality+Vision (${mode_label}) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}
    # R38(P1): SNI 会被拼进 tunnel inbound tag, 含空格/引号会破坏按 tag 的关联匹配
    _validate_domain "$sni" || { _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $sni"; return 1; }

    # R42: 直连模式无 tunnel 入站, 不申请 tunnel 端口
    # F9: 生成放在 Reality 端口输入之后, 以便把用户端口加入排除项
    local tunnel_port=""
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)
    if [ "$mode" = "tunnel" ]; then
        tunnel_port=$(_gen_free_tunnel_port "$port")
        _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    fi

    local default_name="Reality-Vision-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-reality-vision-${port}"
    local tunnel_tag=""
    local listen="::"
    local reality_json

    if [ "$mode" = "tunnel" ]; then
        # R39(P2): tag 长度封顶(见 _gen_tunnel_tag), 避免最长合法 SNI 拼出 270+ 字符的 tag
        tunnel_tag=$(_gen_tunnel_tag "$sni" "$tunnel_port" "$port")
        # 渲染 tunnel inbound
        R_LISTEN="127.0.0.1" R_PORT="$tunnel_port" R_TAG="$tunnel_tag" R_TARGET="$sni"
        local tunnel_json
        tunnel_json=$(_render_template "$(_tpl_path tunnel)") || return 1

        # 渲染 reality inbound (target → 127.0.0.1:<tunnel_port>)
        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_TUNNEL_PORT="$tunnel_port" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-tcp-reality-vision-tunnel)") || return 1

        _commit_reality_inbound "$tunnel_json" "$reality_json" "$tunnel_tag" "$sni" || return 1
    else
        # R42 直连: target = <sni>:443, 只提交 1 个入站, 不写任何路由规则
        # (_commit_reality_inbound 固定插 2 条 tunnel 路由规则, 故此处走 _commit_inbound)
        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_TARGET="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-tcp-reality-vision-direct)") || return 1

        _commit_inbound "$reality_json" || return 1
    fi

    local addr; addr=$(_ask_link_addr) || { _error "节点已加入 Xray 配置, 但未获取到客户端连接地址(输入已结束); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    # 分享链接标准(XTLS VMess/VLESS 提案): type 必须是 tcp(不是 raw)、REALITY 时 fp 不可省略
    # 且默认 chrome、sni 等 URL 字段 Value 一律 encodeURIComponent。
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    # R38(P1): 用户可控字段(节点名/地址)必须过 _yaml_dq 并放进双引号——裸插入时一个 " 就
    # 让整份 clash.yaml 不可解析(不只该节点), 且该脏行事后无法从界面清除
    # clash yaml (mihomo 格式): support-x25519mlkem768 必须显式开启 —— mihomo 默认会在
    # ClientHello 里移除 X25519MLKEM768 组(reality.go BuildRemovedX25519MLKEM768HandshakeState),
    # 新 Xray Reality 服务器按指纹拒绝不含该组的握手(XTLS/Xray-core#6477/#6714);
    # client-fingerprint 用 chrome(新 Reality 服务器要求 chrome 指纹才能协商 MLKEM768)。
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, flow: xtls-rprx-vision, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, network: tcp}"

    # R42: reality_mode 是模式的权威标记(见 _reality_node_mode); 直连节点不写 tunnel_tag/tunnel_port
    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-tcp-reality-vision" \
        --arg mode "$mode" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg pqv "$pq_verify" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,reality_mode:$mode,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,mldsa65_verify:$pqv,share_link:$link}')
    if [ "$mode" = "tunnel" ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
            '. + {tunnel_tag:$ttag,tunnel_port:$tport}')
    fi
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): 必须在 metadata 成功之后再写 clash.yaml —— 否则 metadata 写失败时 YAML 条目
    # 已落地而 nodes/<tag>.json 不存在, _remove_node_from_yaml_by_tag 读不到 name,
    # 该条目再也无法通过任何界面清除。
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

    _success "节点 [${name}] 创建成功"
    if [ "$mode" = "tunnel" ]; then
        _tip "Tunnel: ${tunnel_port} → ${sni}:443 | Reality: ${port}"
    else
        _tip "直连: Reality ${port} → target ${sni}:443 (无 tunnel 入站/路由规则)"
    fi
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议2: VLESS+XHTTP+Reality (可选 直连 / Tunnel 模式, 见 _prompt_reality_mode)
# ---------------------------------------------------------------------------
_add_vless_xhttp_reality() {
    _prompt_reality_mode || return 1
    local mode="$REALITY_MODE" mode_label="直连模式"
    [ "$mode" = "tunnel" ] && mode_label="Tunnel 模式·防偷跑"
    echo -e "\n  ${CYAN}=== VLESS+XHTTP+Reality (${mode_label}) ===${NC}"
    local sni
    read -rp "  伪装域名 (默认 www.amd.com): " sni
    sni=${sni:-www.amd.com}
    # R38(P1): SNI 会被拼进 tunnel inbound tag, 含空格/引号会破坏按 tag 的关联匹配
    _validate_domain "$sni" || { _error "伪装域名格式非法(仅字母/数字/连字符, 点分段): $sni"; return 1; }

    # R42: 直连模式无 tunnel 入站, 不申请 tunnel 端口
    # F9: 生成放在 Reality 端口输入之后, 以便把用户端口加入排除项
    local tunnel_port=""
    echo -e "  ${YELLOW}Reality 监听端口 (客户端连接)${NC}"
    local port=$(_input_port tcp)
    if [ "$mode" = "tunnel" ]; then
        tunnel_port=$(_gen_free_tunnel_port "$port")
        _info "Tunnel 监听端口: ${tunnel_port} (转发到 ${sni}:443)"
    fi

    local path=$(_gen_rand_path)
    read -rp "  XHTTP path (默认 ${path}): " custom_path
    path=${custom_path:-$path}
    # M5: path 直拼 JSON 模板, 含 " \ 换行或 {{ 占位符会让渲染失败/值被二次替换, 输入侧拒绝
    _validate_json_text "$path" || { _error "path 含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="Reality-XHTTP-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_reality_keys || return 1

    local pq_seed="" pq_verify=""
    if _detect_reality_pq "${sni}:443"; then
        pq_seed="$PQ_SEED"; pq_verify="$PQ_VERIFY"
    fi

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-reality-xhttp-${port}"
    local tunnel_tag=""
    local listen="::"
    local reality_json

    if [ "$mode" = "tunnel" ]; then
        # R39(P2): tag 长度封顶(见 _gen_tunnel_tag)
        tunnel_tag=$(_gen_tunnel_tag "$sni" "$tunnel_port" "$port")

        R_LISTEN="127.0.0.1" R_PORT="$tunnel_port" R_TAG="$tunnel_tag" R_TARGET="$sni"
        local tunnel_json
        tunnel_json=$(_render_template "$(_tpl_path tunnel)") || return 1

        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_PATH="$path" R_TUNNEL_PORT="$tunnel_port" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-xhttp-reality-tunnel)") || return 1

        _commit_reality_inbound "$tunnel_json" "$reality_json" "$tunnel_tag" "$sni" || return 1
    else
        # R42 直连: target = <sni>:443, 单入站提交, 无路由规则
        R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
        R_SERVER_NAME="$sni" R_TARGET="$sni" R_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
        R_SHORT_ID="$REALITY_SHORT_ID" R_PATH="$path" R_MLDSA65_SEED="$pq_seed"
        reality_json=$(_render_template "$(_tpl_path vless-xhttp-reality-direct)") || return 1

        _commit_inbound "$reality_json" || return 1
    fi

    local addr; addr=$(_ask_link_addr) || { _error "节点已加入 Xray 配置, 但未获取到客户端连接地址(输入已结束); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=xhttp&mode=auto&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$REALITY_PUBLIC_KEY")&sid=${REALITY_SHORT_ID}&path=$(_url_encode "$path")"
    [ -n "$pq_verify" ] && link="${link}&pqv=${pq_verify}"
    link="${link}#$(_url_encode "$name")"

    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    # clash yaml (mihomo 格式): 见 _add_vless_tcp_reality_vision 同处注释 ——
    # support-x25519mlkem768 必须显式开启, client-fingerprint 用 chrome。
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, network: xhttp, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $REALITY_PUBLIC_KEY, short-id: $REALITY_SHORT_ID, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\"}}"

    # R42: reality_mode 是模式的权威标记(见 _reality_node_mode); 直连节点不写 tunnel_tag/tunnel_port
    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-reality" \
        --arg mode "$mode" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg sni "$sni" --arg pk "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" --arg path "$path" --arg pqv "$pq_verify" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,reality_mode:$mode,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,sni:$sni,public_key:$pk,short_id:$sid,path:$path,mldsa65_verify:$pqv,share_link:$link}')
    if [ "$mode" = "tunnel" ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg ttag "$tunnel_tag" --argjson tport "$tunnel_port" \
            '. + {tunnel_tag:$ttag,tunnel_port:$tport}')
    fi
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML(见 _add_vless_tcp_reality_vision 同处注释)
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

    _success "节点 [${name}] 创建成功"
    if [ "$mode" = "tunnel" ]; then
        _tip "Tunnel: ${tunnel_port} → ${sni}:443 | Reality: ${port}"
    else
        _tip "直连: Reality ${port} → target ${sni}:443 (无 tunnel 入站/路由规则)"
    fi
    [ -n "$pq_verify" ] && _tip "已启用后量子签名 (pqv)"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议3: VLESS+ENC (内置加密, 无 TLS, 类似 SS 轻量直连)
# 通过 xray vlessenc 生成 decryption(服务端)/encryption(客户端) 密钥对
# 来源: Xray-docs-next vless.md + PR #5067
# ---------------------------------------------------------------------------

# 生成 VLESS+ENC 密钥对(xray vlessenc)
# 参数 $1: 认证类型 (x25519 | mlkem768), 默认 x25519
# 输出全局: VLESS_ENC_DECRYPTION / VLESS_ENC_ENCRYPTION
# 新版 xray vlessenc 输出双模式(Authentication: section), awk 按 section 定位
# 旧版输出(无 Authentication: 行): jq 优先, grep+sed 兜底
_generate_vless_enc_keys() {
    local auth_type="${1:-x25519}"
    local output
    output=$(XRAY_LOCATION_ASSET= "$XRAY_BIN" vlessenc 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$output" ]; then
        _error "VLESS+ENC 密钥生成失败 (需要较新版本的 Xray 核心)"
        return 1
    fi

    VLESS_ENC_DECRYPTION=""
    VLESS_ENC_ENCRYPTION=""

    # 检测新版格式: 包含 "Authentication:" section header
    if echo "$output" | grep -q "^Authentication:"; then
        _info "检测到新版 vlessenc 输出, 选择认证: ${auth_type}"
        VLESS_ENC_DECRYPTION=$(echo "$output" | awk -v target="$auth_type" '
            /^Authentication:/ {
                line = tolower($0); gsub(/-/, "", line)
                in_section = (index(line, target) > 0); next
            }
            in_section && /^"decryption":/ {
                sub(/.*"decryption"[[:space:]]*:[[:space:]]*"/, "")
                sub(/".*/, "")
                print
            }
        ' | head -1)
        VLESS_ENC_ENCRYPTION=$(echo "$output" | awk -v target="$auth_type" '
            /^Authentication:/ {
                line = tolower($0); gsub(/-/, "", line)
                in_section = (index(line, target) > 0); next
            }
            in_section && /^"encryption":/ {
                sub(/.*"encryption"[[:space:]]*:[[:space:]]*"/, "")
                sub(/".*/, "")
                print
            }
        ' | head -1)
        # section-aware grep+sed 兜底: awk 窄化到目标 section, 再 grep+sed 提取值
        if [ -z "$VLESS_ENC_DECRYPTION" ] || [ -z "$VLESS_ENC_ENCRYPTION" ]; then
            local section
            section=$(echo "$output" | awk -v target="$auth_type" '
                /^Authentication:/ { line = tolower($0); gsub(/-/, "", line); in_section = (index(line, target) > 0); next }
                in_section { print }
            ')
            if [ -z "$VLESS_ENC_DECRYPTION" ]; then
                VLESS_ENC_DECRYPTION=$(echo "$section" | grep '"decryption"' | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
            fi
            if [ -z "$VLESS_ENC_ENCRYPTION" ]; then
                VLESS_ENC_ENCRYPTION=$(echo "$section" | grep '"encryption"' | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
            fi
        fi
    else
        # 旧版格式回退: jq 优先(纯 JSON 场景)
        VLESS_ENC_DECRYPTION=$(echo "$output" | jq -r '.decryption // empty' 2>/dev/null)
        VLESS_ENC_ENCRYPTION=$(echo "$output" | jq -r '.encryption // empty' 2>/dev/null)
        # grep + sed 兜底(输出含额外文本时 jq 会失败)
        if [ -z "$VLESS_ENC_DECRYPTION" ]; then
            VLESS_ENC_DECRYPTION=$(echo "$output" | grep '"decryption"' | sed -n 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        fi
        if [ -z "$VLESS_ENC_ENCRYPTION" ]; then
            VLESS_ENC_ENCRYPTION=$(echo "$output" | grep '"encryption"' | sed -n 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        fi
    fi

    if [ -z "$VLESS_ENC_DECRYPTION" ] || [ -z "$VLESS_ENC_ENCRYPTION" ]; then
        _error "VLESS+ENC 密钥解析失败 (xray vlessenc 输出格式异常)"
        return 1
    fi
    _info "VLESS+ENC 密钥已生成 (decryption: ${VLESS_ENC_DECRYPTION:0:30}...)"
}

# VLESS 内置加密选项提示(供各 VLESS 变体复用)
# 设置全局变量: ENC_ENABLED, ENC_AUTH, ENC_DECRYPTION, ENC_ENCRYPTION
_prompt_encryption() {
    local choice
    echo ""
    _info "VLESS 内置加密 (encryption):"
    echo "  0) 不启用 (默认)"
    echo "  1) X25519 (经典 ECDH, 兼容性最好)"
    echo "  2) ML-KEM-768 (后量子, 需客户端 PQC 支持)"
    read -rp "  请选择(0-2, 默认 0): " choice
    ENC_ENABLED=0; ENC_AUTH=""; ENC_DECRYPTION=""; ENC_ENCRYPTION=""
    case "${choice:-0}" in
        1)
            if ! _generate_vless_enc_keys x25519; then return 1; fi
            ENC_ENABLED=1; ENC_AUTH="x25519"
            ENC_DECRYPTION="$VLESS_ENC_DECRYPTION"
            ENC_ENCRYPTION="$VLESS_ENC_ENCRYPTION"
            ;;
        2)
            if ! _generate_vless_enc_keys mlkem768; then return 1; fi
            ENC_ENABLED=1; ENC_AUTH="mlkem768"
            ENC_DECRYPTION="$VLESS_ENC_DECRYPTION"
            ENC_ENCRYPTION="$VLESS_ENC_ENCRYPTION"
            ;;
    esac
    return 0
}

_add_vless_enc() {
    echo -e "\n  ${CYAN}=== VLESS+ENC (内置加密 · 无 TLS · 类似 SS 轻量直连) ===${NC}"
    local port=$(_input_port tcp)

    # 认证算法选择
    echo -e "  认证算法:"
    echo -e "  ${GREEN}[1]${NC} X25519 (默认, 兼容性好)"
    echo -e "  ${GREEN}[2]${NC} ML-KEM-768 (Post-Quantum, 抗量子攻击)"
    read -rp "  选择 (默认 1): " auth_choice
    local AUTH_TYPE="x25519"
    [ "${auth_choice:-1}" = "2" ] && AUTH_TYPE="mlkem768"

    # flow 选项(xtls-rprx-vision 可启用 splice 优化)
    echo -e "  流控模式:"
    echo -e "  ${GREEN}[1]${NC} 无 (默认, 通用兼容)"
    echo -e "  ${GREEN}[2]${NC} xtls-rprx-vision (splice 优化, 性能更好)"
    read -rp "  选择 (默认 1): " flow_choice
    local flow=""
    [ "${flow_choice:-1}" = "2" ] && flow="xtls-rprx-vision"

    local default_name="ENC-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || { _error "UUID 生成失败"; return 1; }
    _generate_vless_enc_keys "$AUTH_TYPE" || return 1

    local tag="xd-vless-enc-${port}"
    local listen="::"

    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid"
    R_FLOW="$flow" R_DECRYPTION="$VLESS_ENC_DECRYPTION"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-enc)") || return 1
    _commit_inbound "$inbound" || return 1

    local addr; addr=$(_ask_link_addr) || { _error "节点已加入 Xray 配置, 但未获取到客户端连接地址(输入已结束); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"

    # 分享链接: encryption 参数为客户端密钥(URL 编码, 含点号和特殊字符); type=tcp 符合分享链接标准
    local enc_encoded; enc_encoded=$(_url_encode "$VLESS_ENC_ENCRYPTION")
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_encoded}&security=none&type=tcp"
    [ -n "$flow" ] && link="${link}&flow=${flow}"
    link="${link}#$(_url_encode "$name")"

    # clash yaml (Clash Meta / mihomo 格式)
    local clash_flow=""
    [ -n "$flow" ] && clash_flow=", flow: ${flow}"
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, encryption: \"$(_yaml_dq "$VLESS_ENC_ENCRYPTION")\", network: tcp, tls: false${clash_flow}}"

    if ! _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-enc" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg uuid "$uuid" --arg flow "$flow" --arg auth "$AUTH_TYPE" \
        --arg dec "$VLESS_ENC_DECRYPTION" --arg enc "$VLESS_ENC_ENCRYPTION" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,uuid:$uuid,flow:$flow,auth:$auth,decryption:$dec,encryption:$enc,share_link:$link}')"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

    _success "节点 [${name}] 创建成功"
    [ -n "$flow" ] && _tip "已启用 xtls-rprx-vision (splice 优化)"
    _tip "认证算法: ${AUTH_TYPE}"
    [ "$AUTH_TYPE" = "mlkem768" ] && _tip "ML-KEM-768 需客户端支持 Post-Quantum 加密"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议4: VLESS+XHTTP(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_xhttp_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+XHTTP (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port
    port=$(_input_port tcp)
    # 走 CDN 建议用 CF 支持的 HTTP 端口(仅警告, 不强制)
    case "$port" in 80|8080|8880|2052|2082|2086|2095|443|2053|2083|2087|2096|8443) ;; *)
        _warn "非 CF 推荐端口, 建议使用 80/8080/2052/2086/2095 等, 仍可继续"
        ;;
    esac

    local host
    read -rp "  CDN 域名(Host, 你在 CF 绑定的域名): " host
    [ -z "$host" ] && { _warn "CDN 协议必须填域名"; return 1; }
    # R38(P1): Host 会进 inbound 模板与 clash 条目; 含空格/引号会破坏模板渲染与 YAML
    _validate_domain "$host" || { _error "CDN 域名格式非法(仅字母/数字/连字符, 点分段): $host"; return 1; }

    local preferred_addr
    read -rp "  优选域名/IP(分享链接使用, 默认 ${host}): " preferred_addr
    preferred_addr=${preferred_addr:-$host}

    local preferred_port
    read -rp "  优选端口(默认 443): " preferred_port
    preferred_port=${preferred_port:-443}
    [[ "$preferred_port" =~ ^[0-9]+$ && "$preferred_port" -ge 1 && "$preferred_port" -le 65535 ]] || { _warn "端口无效, 使用默认 443"; preferred_port=443; }

    local path=$(_gen_rand_path)
    read -rp "  XHTTP path (默认 ${path}): " custom_path
    path=${custom_path:-$path}
    # M5: 见 _add_vless_xhttp_reality 同处说明
    _validate_json_text "$path" || { _error "path 含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="XHTTP-CDN-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || return 1

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-xhttp-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-xhttp-cdn)") || return 1
    _commit_inbound "$inbound" || return 1

    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    # 分享链接标准: fp 默认 chrome; 标准无 insecure/allowInsecure 字段(Xray 已移除该配置项),
    # 且本节点经 CF 边缘合法证书, 无需跳过校验; sni/host 必须 encodeURIComponent
    local link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$host")&fp=chrome&alpn=h2&type=xhttp&mode=auto&host=$(_url_encode "$host")&path=$(_url_encode "$path")#$(_url_encode "$name")"
    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$preferred_addr")\", port: $preferred_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": chrome, network: xhttp, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\", host: \"$(_yaml_dq "$host")\"}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-xhttp-cdn" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg host "$host" --arg path "$path" \
        --arg preferred_addr "$preferred_addr" --argjson preferred_port "$preferred_port" \
        --arg sni "$host" --arg fp "chrome" --arg alpn "h2" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$preferred_addr,uuid:$uuid,host:$host,path:$path,preferred_addr:$preferred_addr,preferred_port:$preferred_port,sni:$sni,fp:$fp,alpn:$alpn,share_link:$link}')
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

    _success "节点 [${name}] 创建成功"
    _warn "请确保: CF 已将该域名指向本机并开启小黄云(代理), SSL 模式 Flexible"
    echo -e "  ${CYAN}分享链接(经CDN):${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议5: VLESS+WS(无TLS, 必须套CDN)
# ---------------------------------------------------------------------------
_add_vless_ws_cdn() {
    echo -e "\n  ${CYAN}=== VLESS+WS (无TLS · 必须套 Cloudflare CDN, 禁止直连) ===${NC}"
    echo -e "  ${RED}⚠ 该协议不能直连, 客户端须经 CF CDN 回源到本机${NC}"
    local port=$(_input_port tcp)

    local host
    read -rp "  CDN 域名(Host, 你在 CF 绑定的域名): " host
    [ -z "$host" ] && { _warn "CDN 协议必须填域名"; return 1; }
    # R38(P1): Host 会进 inbound 模板与 clash 条目; 含空格/引号会破坏模板渲染与 YAML
    _validate_domain "$host" || { _error "CDN 域名格式非法(仅字母/数字/连字符, 点分段): $host"; return 1; }

    local preferred_addr
    read -rp "  优选域名/IP(分享链接使用, 默认 ${host}): " preferred_addr
    preferred_addr=${preferred_addr:-$host}

    local preferred_port
    read -rp "  优选端口(默认 443): " preferred_port
    preferred_port=${preferred_port:-443}
    [[ "$preferred_port" =~ ^[0-9]+$ && "$preferred_port" -ge 1 && "$preferred_port" -le 65535 ]] || { _warn "端口无效, 使用默认 443"; preferred_port=443; }

    local path=$(_gen_rand_path)
    read -rp "  WS path (默认 ${path}): " custom_path
    path=${custom_path:-$path}
    # M5: 见 _add_vless_xhttp_reality 同处说明
    _validate_json_text "$path" || { _error "path 含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="WS-CDN-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local uuid; uuid=$(_gen_uuid) || return 1

    # 加密选项
    if ! _prompt_encryption; then return 1; fi
    R_DECRYPTION="${ENC_DECRYPTION:-none}"

    local tag="xd-ws-cdn-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_UUID="$uuid" R_PATH="$path" R_HOST="$host"
    local inbound
    inbound=$(_render_template "$(_tpl_path vless-ws-cdn)") || return 1
    _commit_inbound "$inbound" || return 1

    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local enc_param
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_param=$(_url_encode "$ENC_ENCRYPTION")
    else
        enc_param="none"
    fi
    local link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$host")&fp=chrome&type=ws&host=$(_url_encode "$host")&path=$(_url_encode "${path}?ed=2560")#$(_url_encode "$name")"
    local enc_clash=""
    if [ "$ENC_ENABLED" -eq 1 ]; then
        enc_clash=", encryption: \"$ENC_ENCRYPTION\""
    fi
    local clash="- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$preferred_addr")\", port: $preferred_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": chrome, network: ws, \"ws-opts\": {path: \"$(_yaml_dq "$path")\", headers: {Host: \"$(_yaml_dq "$host")\"}}}"

    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "vless-ws-cdn" \
        --argjson port "$port" --arg listen "$listen" \
        --arg uuid "$uuid" --arg host "$host" --arg path "$path" \
        --arg preferred_addr "$preferred_addr" --argjson preferred_port "$preferred_port" \
        --arg sni "$host" --arg fp "chrome" \
        --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$preferred_addr,uuid:$uuid,host:$host,path:$path,preferred_addr:$preferred_addr,preferred_port:$preferred_port,sni:$sni,fp:$fp,share_link:$link}')
    if [ "$ENC_ENABLED" -eq 1 ]; then
        meta_json=$(echo "$meta_json" | jq \
            --arg auth "$ENC_AUTH" --arg dec "$ENC_DECRYPTION" --arg enc "$ENC_ENCRYPTION" \
            '. + {auth:$auth,decryption:$dec,encryption:$enc}')
    fi
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

    _success "节点 [${name}] 创建成功"
    _warn "请确保: CF 已将该域名指向本机并开启小黄云(代理), SSL 模式 Flexible"
    echo -e "  ${CYAN}分享链接(经CDN):${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议6: Shadowsocks(3 种加密: aes-256-gcm / 2022-blake3-aes-256-gcm / 2022-blake3-chacha20-poly1305)
# ---------------------------------------------------------------------------
_add_shadowsocks() {
    echo -e "\n  ${CYAN}=== Shadowsocks (可直连) ===${NC}"
    # TCP/UDP 协议选择
    echo -e "  监听协议:"
    echo -e "  ${GREEN}[1]${NC} TCP+UDP (默认)"
    echo -e "  ${GREEN}[2]${NC} 仅 TCP"
    echo -e "  ${GREEN}[3]${NC} 仅 UDP"
    read -rp "  选择 (默认 1): " net_choice
    local proto_arg network_val
    case "${net_choice:-1}" in
        1) proto_arg="";   network_val="tcp,udp" ;;
        2) proto_arg="tcp"; network_val="tcp" ;;
        3) proto_arg="udp"; network_val="udp" ;;
        *) _warn "无效,默认 TCP+UDP"; proto_arg=""; network_val="tcp,udp" ;;
    esac
    local port=$(_input_port "$proto_arg")
    echo -e "  加密方式:"
    echo -e "  ${GREEN}[1]${NC} aes-256-gcm"
    echo -e "  ${GREEN}[2]${NC} 2022-blake3-aes-256-gcm"
    echo -e "  ${GREEN}[3]${NC} 2022-blake3-chacha20-poly1305"
    read -rp "  选择 (默认 1): " mc
    local method
    case "${mc:-1}" in
        1) method="aes-256-gcm" ;;
        2) method="2022-blake3-aes-256-gcm" ;;
        3) method="2022-blake3-chacha20-poly1305" ;;
        *) _warn "无效,默认 aes-256-gcm"; method="aes-256-gcm" ;;
    esac
    # 2022 系列密码需标准 base64(32 字节密钥, 带 = 填充, Go base64 解码要求)
    local password
    if [[ "$method" == 2022* ]]; then
        password=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    else
        password=$(head -c 16 /dev/urandom | base64 | tr -d '\n=' | head -c 22)
    fi
    read -rp "  密码 (默认随机): " custom_pw
    password=${custom_pw:-$password}
    # M5: 密码直拼 JSON 模板与 SS 链接, 含 " \ 换行或 {{ 会让渲染失败/值被二次替换
    _validate_json_text "$password" || { _error "密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    local default_name="SS-${method%%-*}-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local tag="xd-ss-${port}"
    local listen="::"
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag" R_METHOD="$method" R_PASSWORD="$password" R_NETWORK="$network_val"
    local inbound
    inbound=$(_render_template "$(_tpl_path shadowsocks)") || return 1
    _commit_inbound "$inbound" || return 1

    local addr
    addr=$(_ask_link_addr) || { _error "节点已加入 Xray 配置, 但未获取到客户端连接地址(输入已结束); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"; return 1; }
    local link_ip="$addr"
    [[ "$addr" == *":"* && "$addr" != *"["* ]] && link_ip="[$addr]"
    # ss 链接(SIP002): userinfo 必须 base64url 无填充 —— 标准 base64 可能含 + / =,
    # 其中 / 会破坏 URL userinfo 段的解析(Go url.Parse 等); 2022-blake3 密码本身含 = + /,
    # 被整体 base64url 编码后 URL 安全, 客户端解码后还原原密码
    local userinfo="${method}:${password}"
    local b64=$(printf '%s' "$userinfo" | base64 | tr -d '\n=' | tr '+/' '-_')
    local link="ss://${b64}@${link_ip}:${port}#$(_url_encode "$name")"

    # mihomo 的 ss `udp` 默认 false(通用字段); 服务端 network 含 udp 才声明,
    # 否则声明了 UDP 也会连不上(与 _input_port 的协议选择一致)
    local clash_udp=""
    [[ "$network_val" == *"udp"* ]] && clash_udp=", udp: true"
    local clash="- {name: \"$(_yaml_dq "$name")\", type: ss, server: \"$(_yaml_dq "$addr")\", port: $port, cipher: $method, password: \"$(_yaml_dq "$password")\"${clash_udp}}"

    if ! _save_node_meta "$tag" "$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "shadowsocks" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg method "$method" --arg password "$password" --arg link "$link" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,method:$method,password:$password,share_link:$link}')"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    # R38(P1): metadata 成功后才写派生 YAML
    _add_node_to_yaml "$clash" "$name" || true  # 派生缓存, 失败内部已 _warn, 不阻断节点创建

    _success "节点 [${name}] 创建成功"
    echo -e "  ${CYAN}分享链接:${NC} ${link}"
}

# ---------------------------------------------------------------------------
# 协议7: Hysteria2 (QUIC + TLS证书)
# 模板: templates/hysteria2.server.jsonc
# 来源: Xray-examples/Hysteria2/server.jsonc + Xray-docs-next hysteria.md / finalmask.md
# ---------------------------------------------------------------------------
# 自签证书 SAN 读取(现代 TLS 只认 SAN, 见 _gen_hy2_cert 注释)
# ---------------------------------------------------------------------------
# 列出证书 SAN 中的 DNS 名(每行一个, 去重); 无 SAN / 无 openssl / 读不到 ⇒ 输出为空
_hy2_cert_san_names() {
    local cert="$1" text=""
    command -v openssl >/dev/null 2>&1 || return 0
    [ -f "$cert" ] || return 0
    # 优先 -ext subjectAltName(OpenSSL 1.1.1+/LibreSSL 3.1+), 不支持时回退整份 -text
    text=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)
    [ -n "$text" ] || text=$(openssl x509 -in "$cert" -noout -text 2>/dev/null)
    printf '%s\n' "$text" | grep -oE 'DNS:[^,[:space:]]+' | sed 's/^DNS://' | sort -u
}

# 证书 SAN 是否精确覆盖给定域名(含则返回 0)
_hy2_cert_san_has() {
    local cert="$1" domain="$2"
    [ -n "$domain" ] || return 1
    _hy2_cert_san_names "$cert" | grep -qxF "$domain"
}

# 证书与其私钥是否属于同一密钥对(cert 公钥 == key 公钥)
# 用于生成后校验: 防止"旧 cert + 新 key"这类错配被当成有效证书对(见 _gen_hy2_cert)。
# 无 openssl 时无从校验 ⇒ 返回 0(放行, 与 _hy2_cert_reusable 的无 openssl 口径一致)。
_hy2_cert_key_match() {
    local cert="$1" key="$2" cpub kpub
    command -v openssl >/dev/null 2>&1 || return 0
    [ -f "$cert" ] && [ -f "$key" ] || return 1
    cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null) || return 1
    kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
    [ -n "$cpub" ] && [ "$cpub" = "$kpub" ]
}

# 删除证书备份文件。删不掉**不算**事务失败(残留 .bak 不影响运行态), 但必须如实报告 ——
# 项目原则: 文件操作失败不得静默吞掉(logrotate 的 `|| true` 洗返回码就是 P1 教训)。
_hy2_cert_bak_rm() {
    local f
    for f in "$@"; do
        [ -n "$f" ] || continue
        rm -f "$f" 2>/dev/null
        [ -e "$f" ] && _warn "证书备份删除失败, 已残留(不影响运行): $f"
    done
    return 0
}

# 把"已校验的临时 cert/key"提交到正式路径; 失败则把正式路径**还原为提交前状态**。
# 用法:_hy2_cert_commit <tmp_cert> <tmp_key> <cert> <key>
# 返回码是三态(调用方必须按码分流, 不能一律当成"已回滚"):
#   0 = 提交成功
#   1 = 提交失败, **已确认**回到提交前状态(备份还原成功且复核通过)
#   2 = 提交失败, **且回滚未完成** —— cert/key 可能不一致, 备份路径已打印, 需人工处理
#
# 为什么需要它: cert 与 key 是两个文件, 文件系统没有"同时原子替换两者"的原语, 因此提交
# 必须是**可回滚的两步**。做法: 先把两个旧文件都备份 → 依次 mv 新 cert / 新 key →
# 提交后校验正式路径确实匹配; 任何一步失败就按备份还原, 使"提交失败"不留下半更新状态
# (只换掉 cert 而 key 仍是旧的, 或反之)。
# **回滚本身也会失败**(权限/只读/IO): 故回滚的每一步都要检查结果, 并复核正式路径确实等于
# 提交前状态; 只有复核通过才敢返回 1 宣称"已回滚", 否则返回 2 并保留备份 —— 绝不能把
# "回滚失败"当成"已回滚"对外谎报一致(实测过该缺陷)。
_hy2_cert_commit() {
    local tmp_cert="$1" tmp_key="$2" cert="$3" key="$4"
    local bak_cert="" bak_key="" rc=1 post_ok=1
    # 备份既有文件(可能不存在 —— 首次生成时), 备份名以 XXXXXX 结尾满足 Alpine musl mktemp
    if [ -f "$cert" ]; then
        bak_cert=$(mktemp "${cert}.bak.XXXXXX") || return 1
        cp -p "$cert" "$bak_cert" 2>/dev/null || { _hy2_cert_bak_rm "$bak_cert"; return 1; }
    fi
    if [ -f "$key" ]; then
        bak_key=$(mktemp "${key}.bak.XXXXXX") || { _hy2_cert_bak_rm "$bak_cert"; return 1; }
        cp -p "$key" "$bak_key" 2>/dev/null || { _hy2_cert_bak_rm "$bak_key" "$bak_cert"; return 1; }
    fi
    # 提交(两步)+ 提交后校验正式路径确为一对匹配的 cert/key(兜底 rename 语义异常/外部干扰)
    if mv -f "$tmp_cert" "$cert" 2>/dev/null && mv -f "$tmp_key" "$key" 2>/dev/null \
       && _hy2_cert_key_match "$cert" "$key"; then
        rc=0
    fi
    if [ "$rc" != 0 ]; then
        # 回滚: 用备份还原; 原本不存在的文件则删除(回到"没有该文件"的提交前状态)。
        # **每一步都必须检查结果** —— 回滚自身也会失败(权限/只读/IO), 不检查就会把
        # "回滚失败"当成"已回滚", 对外谎报状态一致(实测: 回滚失败仍 rc=1 且报"已回滚")。
        # 用**备份内容**还原(cp 而非 mv —— 备份要留到复核之后再删); 原本不存在的文件则删除。
        if [ -n "$bak_cert" ]; then cp -p "$bak_cert" "$cert" 2>/dev/null; else rm -f "$cert" 2>/dev/null; fi
        if [ -n "$bak_key" ]; then cp -p "$bak_key" "$key" 2>/dev/null; else rm -f "$key" 2>/dev/null; fi
        # 回滚**后复核**正式路径是否真的回到了"提交前状态"。判据是**与备份内容一致**
        # (有备份⇒存在且逐字节相同; 无备份⇒不存在), 而**不是**"cert/key 必须 MATCH" ——
        # "回到提交前状态"与"提交前状态本身健康"是两件事: 若旧状态本就是错配
        # (历史遗留, 正是 _hy2_cert_reusable 要识别并自愈的那种), 完整恢复旧状态后
        # cert/key 仍不匹配, 用 MATCH 判会把**成功回滚**误报成"回滚未完成"(实测)。
        # **以复核结果为准**, 而不是累加各步 mv 的返回值 —— 某步 mv 返回非 0 但目标已是
        # 正确内容(如"该文件从未被替换")时状态其实是对的, 按返回值判会误报。
        if [ -n "$bak_cert" ]; then
            if [ -f "$cert" ]; then cmp -s "$bak_cert" "$cert" || post_ok=0; else post_ok=0; fi
        else
            [ ! -e "$cert" ] || post_ok=0
        fi
        if [ -n "$bak_key" ]; then
            if [ -f "$key" ]; then cmp -s "$bak_key" "$key" || post_ok=0; else post_ok=0; fi
        else
            [ ! -e "$key" ] || post_ok=0
        fi
        if [ "$post_ok" = 0 ]; then
            # 回滚不完整: **保留**未被消费的备份(它们可能是旧文件的唯一副本), 报告路径供人工恢复
            _error "证书提交失败, 且回滚未完成; cert/key 可能处于不一致状态, 请人工检查"
            [ -n "$bak_cert" ] && [ -f "$bak_cert" ] && _warn "旧 cert 备份保留在: $bak_cert"
            [ -n "$bak_key" ] && [ -f "$bak_key" ] && _warn "旧 key 备份保留在: $bak_key"
            return 2
        fi
        # 状态已确认回到提交前: 删掉备份(删不掉只告警, 不改返回码)
        _hy2_cert_bak_rm "$bak_cert" "$bak_key"
        return 1
    fi
    _hy2_cert_bak_rm "$bak_cert" "$bak_key"
    return 0
}

# 证书可用于客户端 SNI 的域名
# 用法:_hy2_cert_domain <cert> [preferred]
#   preferred(通常=本次请求域名)在 SAN 中时优先返回它 —— 多 SAN 证书里"取排序后第一个"
#   会挑到与本次输入无关的名字(如 SAN 有 a./z./hy2. 三个时取到 a.)。
#   否则返回第一个 SAN DNS 名; 无 SAN 才回退 CN(兼容手工签发的 CN-only 证书)。
_hy2_cert_domain() {
    local cert="$1" preferred="${2:-}" d=""
    if [ -n "$preferred" ] && _hy2_cert_san_has "$cert" "$preferred"; then
        printf '%s' "$preferred"; return 0
    fi
    d=$(_hy2_cert_san_names "$cert" | head -1)
    if [ -z "$d" ] && command -v openssl >/dev/null 2>&1; then
        d=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's|/.*||')
    fi
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# 生成 Hysteria2 自签 TLS 证书(EC-256, 10 年)
# 用法:_gen_hy2_cert <tag> [domain]  输出: CERT_FILE_PATH / KEY_FILE_PATH 全局变量
# 前置: 调用方应先判 `_hy2_cert_reusable` —— 可复用则直接沿用, 不要调本函数。
# 返回: 0 成功; 1 失败(已回到提交前状态, 或本就未改动); 2 失败且回滚未完成(需人工检查)。
#
# **证书必须带 SAN**: Xray 官方 tls.md 明言「serverName 对应的值必须存在于服务器证书的
# SAN 中」; 只写 CN 的证书在现代 TLS 校验下会被拒(Go crypto/x509 报 "relies on legacy
# Common Name field, use SANs instead"), 使"输入域名"形同虚设。故 openssl 分支显式写入
# subjectAltName + serverAuth EKU —— 与官方 `hysteria cert` 产出的证书同构(实测其带
# DNS SAN + Extended Key Usage: TLS Web Server Authentication + BasicConstraints CA:FALSE)。
#
# 复用语义(唯一判据, 调用方与生成方共用): 已存在证书时**校验其 SAN 是否覆盖本次域名** ——
# 覆盖才复用; 不覆盖则重新生成。否则用户输入新域名却静默沿用旧证书, 是"输入了但没生效"的假成功。
# 无 openssl 时无法读 SAN: 只能复用既有证书, 并如实报告(见 _hy2_cert_domain)。
_hy2_cert_reusable() {
    local cert="$1" key="$2" domain="$3"
    [ -f "$cert" ] && [ -f "$key" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 0   # 读不到 SAN/无法校验, 只能信任既有证书
    # SAN 必须覆盖本次域名, 且 cert/key 必须同属一个密钥对 —— 后者让历史遗留的错配对
    # (旧版本失败路径可能留下)在下一次调用时被判为不可复用, 从而被重新生成(自愈)。
    _hy2_cert_san_has "$cert" "$domain" || return 1
    _hy2_cert_key_match "$cert" "$key" || return 1
    return 0
}

# 用法:_gen_hy2_cert <tag> [domain]  输出: CERT_FILE_PATH / KEY_FILE_PATH 全局变量
_gen_hy2_cert() {
    local tag="$1" domain="${2:-build.nvidia.com}"
    # 证书域名会写进 X.509 CN/SAN, 从输入侧拒绝非法值(仅 LDH 域名, 与 _validate_domain 同口径)
    _validate_domain "$domain" || { _error "证书域名格式非法(仅字母/数字/连字符, 点分段): $domain"; return 1; }
    local cert_dir="$CERT_DIR/$tag"
    mkdir -p "$cert_dir"
    CERT_FILE_PATH="${cert_dir}/cert.pem"
    KEY_FILE_PATH="${cert_dir}/key.pem"
    # 已有证书复用与否, 由调用方按同一判据(_hy2_cert_reusable)先决定 —— 本函数只负责"生成",
    # 不再自行 early-return 复用: 那样调用方无法得知该证书的真实身份(无 openssl 时读不出 SAN),
    # 只能回退到硬编码默认 SNI, 与实际证书脱节。
    _info "生成 TLS 自签证书 (CN=${domain}, SAN=DNS:${domain})..."
    # ---------------------------------------------------------------------
    # **事务式生成**: 先写临时文件, 全部校验通过后才原子替换正式路径。
    # 为什么必须这样: 直接写正式路径时, 若"旧 cert.pem 在 / key.pem 缺失或损坏"(复用判据判
    # 不可复用 ⇒ 进生成分支)且生成中途失败, 会留下 **旧 cert + 新 key** 的错配; 而后续校验
    # 只看证书 SAN, 会把它判成"生成成功", 且下一次 _hy2_cert_reusable 仍返回可复用 ⇒ 持久
    # 坏证书(实测复现: cert 指纹未变、key 已换新、函数却 rc=0 报成功)。
    # 临时文件与目标同目录(rename 才原子), 命名以 XXXXXX 结尾(Alpine musl mktemp 要求)。
    # 失败时删临时文件, **既有证书保持原样**。
    # ---------------------------------------------------------------------
    local tmp_cert tmp_key rc=1
    tmp_cert=$(mktemp "${cert_dir}/.cert.tmp.XXXXXX") || return 1
    tmp_key=$(mktemp "${cert_dir}/.key.tmp.XXXXXX") || { rm -f "$tmp_cert"; return 1; }
    if command -v openssl >/dev/null 2>&1; then
        # SAN 走 openssl.cnf(不用 OpenSSL 专有的命令行扩展参数): Alpine 的 LibreSSL 不认
        # 后者, cnf 方式在 OpenSSL/LibreSSL 两边都可用。
        local cnf
        cnf=$(mktemp "${cert_dir}/openssl.XXXXXX")
        if [ -n "$cnf" ]; then
            cat > "$cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${domain}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${domain}
EOF
            openssl ecparam -genkey -name prime256v1 -out "$tmp_key" 2>/dev/null \
                && openssl req -new -x509 -days 3650 -key "$tmp_key" \
                    -out "$tmp_cert" -config "$cnf" 2>/dev/null
            rm -f "$cnf"
        fi
    fi
    # 2026-09-12 三审(L8): openssl 缺失或执行失败(旧版/被裁剪)时回退 xray tls cert,
    # 而不是"openssl 存在但失败就直接报错"—— 报错文案明明写着"需安装 openssl 或使用 xray tls cert"。
    if { [ ! -s "$tmp_cert" ] || [ ! -s "$tmp_key" ]; } && [ -x "$XRAY_BIN" ]; then
        # xray tls cert 的 --file 是"路径前缀", 实际产出 <前缀>.crt / <前缀>.key。
        # 前缀落在 cert_dir 内部(传目录本身会在其父目录生成 <目录名>.crt/.key), 仍写临时名,
        # 待校验通过后再统一替换 —— 与 openssl 分支同一条提交路径。
        local xpre="${cert_dir}/.xcert.$$"
        XRAY_LOCATION_ASSET= "$XRAY_BIN" tls cert --domain "$domain" --file "$xpre" 2>/dev/null
        [ -s "${xpre}.crt" ] && mv -f "${xpre}.crt" "$tmp_cert"
        [ -s "${xpre}.key" ] && mv -f "${xpre}.key" "$tmp_key"
        rm -f "${xpre}.crt" "${xpre}.key" 2>/dev/null
        # 清理历史错误写法可能残留在父目录的 <tag>.crt/.key
        rm -f "${CERT_DIR}/${tag}.crt" "${CERT_DIR}/${tag}.key" 2>/dev/null
    fi
    if [ -s "$tmp_cert" ] && [ -s "$tmp_key" ]; then
        # 校验 1(有 openssl 时): 证书必须真的带本次域名的 SAN —— 否则静默退回 CN-only,
        #   Xray 的 serverName 校验必失败。无 openssl 走 xray 分支, 其证书自带 SAN, 无从也无需读。
        # 校验 2: cert 与 key 必须同属一个密钥对 —— 这是"旧 cert + 新 key"错配的防线。
        # 两项都过才**提交**; 提交走 _hy2_cert_commit(可回滚的两步 mv), 任一步失败即还原既有文件,
        # 绝不留"新 cert + 旧 key"这类半更新状态。
        if { ! command -v openssl >/dev/null 2>&1 || _hy2_cert_san_has "$tmp_cert" "$domain"; } \
           && _hy2_cert_key_match "$tmp_cert" "$tmp_key"; then
            _hy2_cert_commit "$tmp_cert" "$tmp_key" "$CERT_FILE_PATH" "$KEY_FILE_PATH"
            rc=$?
        fi
    fi
    rm -f "$tmp_cert" "$tmp_key"
    if [ "$rc" = 2 ]; then
        # 提交失败且回滚未完成 —— 具体原因/备份路径已由 _hy2_cert_commit 打印, 此处不重复。
        # 返回 2 而非 1: 让"回滚失败"这一状态在整条调用链上可区分(调用方只判非零, 行为不变)。
        _error "证书提交失败且回滚未完成, 已中止(未继续创建节点)"
        return 2
    fi
    if [ "$rc" != 0 ]; then
        _error "证书生成失败(cert/key 不完整、SAN 不含 ${domain} 或二者不匹配); 既有证书保持原样, 需安装 openssl 或使用 xray tls cert"
        return 1
    fi
    _success "TLS 证书已生成: $cert_dir"
}

# ---------------------------------------------------------------------------
# env 取值链的**硬约束: 值只经全局变量返回, 绝不经过命令替换**。
#
# 为什么: bash 的命令替换会剥掉输出的**所有**结尾换行(GNU Bash 手册 §3.5.4), 内嵌换行才保留。
# Xray 把 xray.location.cert 的值直接 filepath.Join 进证书路径, 所以脚本必须与它逐字节一致 ——
# 只要值经过一次 $(...), "以 1 个/2 个换行结尾"的**合法**值就再也保不住, 脚本观察到的基准会
# 变成另一个目录, 归属/引用判定随之与 Xray 的真实行为脱节(不必然误删, 但判定依据已错)。
# 故本组函数: 结果写入 _HY2_ENV_VAL / _HY2_CERT_ROOT, 读取一律用 NUL 终止的 read -d '',
# 全程不产生命令替换。**不要再把返回值 printf 出去** —— 那等于重新引入一条会被剥尾的通道。
#
# 取值来源(逐字节精确, 按优先级) —— **三者都必须是"当前环境"读取器**:
#   ① printenv  ② env -0  ③ busybox printenv(applet 单独探测)
#      · printenv / busybox printenv 总给值补一个结尾换行 ⇒ 只剥那**一个**(其余尾随换行属于值本身)
#      · env -0 是 NUL 分隔且不补换行, 天然精确
#   ④ 三者都不可用(极简 rootfs): 返回 2(UNKNOWN), 由上层走保守分支。
# **绝不使用 /proc/self/environ**: 按 proc(5) 它是 execve() 时的 *initial environment* ——
#   既不反映启动后新增的变量(未命中 ⇒ 不能判"不存在"), 也不反映启动后的 unset / 重新赋值
#   (**命中 ⇒ 值可能陈旧**: 实测 unset 后它仍返回旧值、改值后它仍返回旧值)。命中与未命中都
#   无法证明"当前"状态, 故它连兜底都不合格 —— 拿它当"当前环境"等于引入陈旧值污染 cert root。
# **绝不回退到 env|awk**: 它按行解析, 值含换行即截断, 会把"无法判定"伪装成"基准已知"。
#   宁可如实上报"无法判定"。
# 返回: 0=存在(值可为空) 1=不存在 2=无法判定
# ---------------------------------------------------------------------------
_HY2_ENV_VAL=""
# 注: 曾经用"流尾追加哨兵记录 + 退出码"把状态编码进环境数据流, 已废弃 ——
# 环境条目的名字空间在内核层面只禁止 `=` 与 NUL(environ(7)), 不要求标识符形式,
# 实测 `env $'\x01任何前缀=X'` 可构造出与哨兵同形的真实条目, 从而伪造通道结束
# (本该取到的值被打成 UNKNOWN)。现在状态与数据各走独立通道, 见 _hy2_env_get 的 ②。
# 从"补结尾换行"的工具(printenv / busybox printenv)取值: 只剥掉工具补的那**一个**换行。
# **单次调用 = 一条数据通道**: 输出(值 + 补的 1 个换行) → NUL → 退出码, 一次读完。
# 退出码语义(GNU/busybox printenv 一致): 0=找到 1=未找到 **其它=工具自身故障 ⇒ UNKNOWN**。
# 切不可把 rc≠0,1 与"变量不存在"混为一谈: printenv 存在但执行失败(ELF 损坏/缺动态 loader/
# 无执行权限 ⇒ 126/127)时若 return 1, 上层会继续猜归一化名乃至 XRAY_BIN 默认目录 —— 与
# fail-closed 相悖。故探测与取值合并成同一条通道, 让 rc 与被读的值同源(三审指出的边界)。
# 用法: _hy2_env_from_tool <name> <cmd...>  → 值写入 _HY2_ENV_VAL; rc 0/1/2(同 _hy2_env_get)
_hy2_env_from_tool() {
    local name="$1"; shift
    local kv="" rcstr=""
    {
        IFS= read -r -d '' kv <&3 || return 2    # 通道里没有分隔符 ⇒ 通道异常, 不猜
        IFS= read -r rcstr <&3     || return 2
    } 3< <( { "$@" "$name" 2>/dev/null; trc=$?; printf '\0'; printf '%s\n' "$trc"; } )
    case "$rcstr" in
        0) _HY2_ENV_VAL=${kv%$'\n'}; return 0 ;;   # 值 = 输出减去工具补的那**一个**换行
        1) return 1 ;;                             # 变量确实不存在
        *) return 2 ;;                             # 工具自身故障 ⇒ 无法判定
    esac
}

_hy2_env_get() {
    local name="$1" kv="" rc=0
    _HY2_ENV_VAL=""
    [ -n "$name" ] || return 1
    # ① printenv(首选: 读**当前**环境 —— 脚本自身 export 的变量同样可见)
    #    rc=2 ⇒ **该读取器自身故障**(不是"不存在"), 换下一个读取器继续; 0/1 才是确定结论。
    if command -v printenv >/dev/null 2>&1; then
        _hy2_env_from_tool "$name" printenv; rc=$?
        [ "$rc" -ne 2 ] && return "$rc"
    fi
    # ② env -0(NUL 分隔、不补换行 ⇒ 天然逐字节精确; 同样是当前环境)。
    #    **状态与数据各走独立通道** —— 退出码绝不编码进环境数据流。
    #    为什么不能把退出码写在流尾: 环境条目的名字空间在内核层面只禁止 `=` 与 NUL(environ(7)),
    #    不要求标识符形式 —— 实测 `env $'\x01<任意前缀>=v'` 会被 env -0 原样输出, 于是**任何**
    #    流内哨兵都能被真实条目伪造(命中被误判成通道结束, 本该取到的值被打成 UNKNOWN)。
    #    做法: env 把整份环境写进一个 0600 临时文件, **先取它自己的退出码**; 只有 rc=0 才说明
    #    这份快照完整, 此时才去读它 —— 数据里不可能混入协议标记。
    #    **读取阶段也必须区分三态**(不能把"读失败"当成"读完没找到"): read -d '' 的返回码
    #      0  = 读到一条完整记录
    #      1  = 读到 EOF; 若变量里**仍有残留数据**, 说明末条缺 NUL = 文件被截断 ⇒ 不能当完整
    #      其它 = 真的读错误(EBADF/EIO 等) ⇒ UNKNOWN
    #    另有"文件打不开"(被删/被换/权限)与"不是普通文件"(如被替换成目录)同样 ⇒ UNKNOWN。
    #    任一路径都不能落到"不存在"。已知残留: 普通文件上的**真实 I/O 错误**与正常 EOF 在
    #    bash 的 read 里同形(都返回 1), 无法再区分 —— 该文件是我们刚写的 0600 临时文件,
    #    这类失败等同于磁盘故障, 不在本函数的可判定范围内。
    #    · mktemp 失败或 env 退出非 0(125/126/127/被信号杀) ⇒ 该读取器不可用 ⇒ 继续降级
    #    · rc=0 且**确认读取正常结束**且未命中 ⇒ 确实不存在(1)
    #    已知取舍(P3, 非阻塞): 整份环境会短暂落盘(0600)。所有分支都立即 rm -f; 仅 SIGKILL
    #    等无法执行清理的极端情形可能残留 —— 换来的收益是"退出码天然不经过数据流"。
    if command -v env >/dev/null 2>&1; then
        local ef="" erc=125 erd=1 efd="" hit="" found=0
        ef=$(mktemp 2>/dev/null) || ef=""
        [ -n "$ef" ] && { env -0 > "$ef" 2>/dev/null; erc=$?; }
        if [ "$erc" -eq 0 ]; then
            erd=0
            # 用 {var}< 取一个高位空闲 fd, 不动调用方可能正在用的 3/4
            if exec {efd}< "$ef" 2>/dev/null; then
                # **exec 成功 ≠ 目标是普通文件**: 目录同样能被成功打开, 而随后的 read 会以
                # rc=1 且 kv 为空失败 —— 与"正常 EOF"完全同形, 无法靠返回码区分(实测)。
                # 故读取前必须校验**已打开对象**的类型。
                # **判定依据必须单一**: 有 /proc 时只信 /proc/self/fd/<n>(它描述的就是那个已
                # 打开的 fd, 免 TOCTOU); 只有**确认 /proc 机制不可用**时才退回路径检查。
                # 切不可写成 `[ -f /proc/self/fd/N ] || [ -f "$ef" ]` —— 那是"任一路径成立即
                # 放行": fd 指向目录、而路径在 exec 之后被换回普通文件时, 后者会让一个指向
                # 目录的 fd 通过校验, read 再以 rc=1/空值失败 ⇒ 重新落回"误报不存在"。
                if [ -d /proc/self/fd ]; then
                    [ -f "/proc/self/fd/$efd" ] || erd=2       # 机制可用 ⇒ 只信 fd
                else
                    [ -f "$ef" ] || erd=2                      # 无 /proc ⇒ 退回路径检查
                fi
                if [ "$erd" -eq 0 ]; then
                    while :; do
                        kv=""                              # 先清空: 使"EOF 后仍有残留"可判定
                        IFS= read -r -d '' kv <&"$efd"; erd=$?
                        [ "$erd" -ne 0 ] && break
                        case "$kv" in
                            "$name="*) hit="${kv#"$name="}"; found=1; break ;;
                        esac
                    done
                fi
                exec {efd}<&-
            else
                erd=2                                       # 打不开 ⇒ 无法确认完整性
            fi
            rm -f "$ef"
            [ "$erd" -gt 1 ] && return 2                    # 读错误 ⇒ UNKNOWN
            [ "$erd" -eq 1 ] && [ -n "$kv" ] && return 2    # 末条缺 NUL(截断) ⇒ UNKNOWN
            if [ "$found" -eq 1 ]; then _HY2_ENV_VAL="$hit"; return 0; fi
            return 1                                        # 读取正常结束且未命中 ⇒ 确实不存在
        fi
        [ -n "$ef" ] && rm -f "$ef"
        # 该读取器不可用 ⇒ 落到 ③(busybox printenv); 全不可用才 UNKNOWN
    fi
    # ③ busybox printenv: `command -v printenv` 失败**不等于** busybox 没有该 applet ——
    #    可能只是 applet 没建 symlink, 故显式走 `busybox printenv`(仍是当前环境)。
    if command -v busybox >/dev/null 2>&1 && busybox printenv >/dev/null 2>&1; then
        _hy2_env_from_tool "$name" busybox printenv; rc=$?
        [ "$rc" -ne 2 ] && return "$rc"
    fi
    # ④ 没有任何"当前环境"读取器 ⇒ 无法判定。**绝不回退到 /proc 或 env|awk**:
    #    /proc 是启动快照(命中可能陈旧), env|awk 按行解析会截断含换行的值 —— 两者都会把
    #    "无法判定"伪装成一个看似合法的基准值, 正是本函数的原始缺陷形态。
    return 2
}

# 单个环境标志名的**最终生效值**: config.env 里**同名 key** 覆盖进程环境(等价于 Xray 在
# 配置加载后对该 key 执行 os.Setenv), 否则用进程环境里的同名变量。
# 覆盖是**按 key 名逐条**发生的, 不是"整个 config.env 优先于进程环境" —— 后者会让 config 的
# 归一化名顶掉进程环境里的 exact 名, 与 Xray 的 NewEnvFlag 查找顺序不一致。
# 存在性按 os.LookupEnv 语义: 变量存在但值为空也算已设置。
# 用法: _hy2_env_final <name>  → 值写入 _HY2_ENV_VAL; rc: 0=存在(值可为空) 1=不存在 2=无法判定
# **不经 stdout 返回**: 出口若走命令替换, 值末尾的换行会被再剥一次(见上方"硬约束")。
# config 的 .env 段是否可用于判定: 缺失 = 合法(无 env 段); 存在但非 object、object 内含非法
# value 类型、键值内容无法被 Unix os.Setenv 应用, 或 config 无法解析 = 配置损坏 ⇒ 无法判定
# 最终环境, 返回 2(UNKNOWN)。Xray 的 EnvConfig 是 map[string]string 且 Config.Build() 会逐个
# os.Setenv, 任一失败配置即构建失败; 此时"未知 ⇒ 禁止 purge"比"回落 shell env 猜一个"安全。
_hy2_cert_env_ok() {
    [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ] || return 0
    local t
    # 四重校验, 缺一不可(JSON 类型 → Go 反序列化 → os.Setenv 可应用, 逐层收窄):
    #  ① 必须用 `has("env")` 显式区分"键不存在"与 `"env": false` —— jq 的 `//` 把 false 也当
    #     空值, `(.env // null)` 会把它折成 null ⇒ 误判"无 env 段", 正是本函数要堵的洞。
    #  ② `.env` 必须是 object(非 object 一律损坏); `null` 例外 —— Go 把 JSON null 反序列化进
    #     `map[string]string` 得 nil map 且不报错, 等价于"无 env 段"。
    #  ③ 每个 value 必须是 string 或 null —— EnvConfig 是 `map[string]string`, 数字/布尔/数组/
    #     对象 value 会让 Go 反序列化失败。null value 合法: Go 对 string 的 null 取其零值 ""。
    #  ④ 键值内容必须是 Unix `os.Setenv` 可接受的: Xray `Config.Build()` 逐个 `os.Setenv(key,
    #     value)`, 任一失败即 `failed to apply environment configuration` 让配置整体构建失败
    #     (main 分支实测)。Go 的 unix 规则: key **非空**且**不含 `=`、不含 NUL**; value 不得含 NUL。
    #     ⇒ 空 key / 含 `=` 的 key / 含 NUL 的 key 或 value 一律按"配置损坏"处理, 否则会拿一个
    #     Xray 实际应用不了的 env 去推 cert root。空 value 合法(等价"设为空串")。
    t=$(jq -r 'if has("env") then
            if .env == null then "null"
            elif (.env | type) != "object" then "invalid"
            elif (.env | all(to_entries[];
                    (.key | (length > 0)
                           and ((contains("\u0000")) | not)
                           and ((contains("=")) | not))
                    and (.value | if . == null then true
                                   elif type == "string" then ((contains("\u0000")) | not)
                                   else false end)
                 )) then "object"
            else "invalid" end
        else "null" end' "$CONFIG_FILE" 2>/dev/null) || return 2
    case "$t" in
        null|object) return 0 ;;
        *) return 2 ;;
    esac
}

_hy2_env_final() {
    local name="$1" kv=""
    _HY2_ENV_VAL=""
    # 配置损坏(.env 类型非法 / config 无法解析)⇒ 未知, 不回落进程环境(返回 2)
    _hy2_cert_env_ok || return 2
    [ -n "$name" ] || return 1
    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ] \
       && jq -e --arg k "$name" '(.env // {}) | has($k)' "$CONFIG_FILE" >/dev/null 2>&1; then
        # jq -j 输出裸字符串且不补结尾换行(jq -r 会补一个), 再用 NUL 终止读取进变量 ⇒ 逐字节精确。
        # 这对"值本身以换行结尾"是必需的: jq -r + 命令替换会把那些换行全部吃掉。
        # 其中值取 // "" —— value 为 null 时 Go 取 string 零值, 即"存在但为空", 与 Xray 一致。
        IFS= read -r -d '' kv < <( { jq -j --arg k "$name" '(.env // {}) | (.[$k] // "")' "$CONFIG_FILE" 2>/dev/null; printf '\0'; } ) || return 2
        _HY2_ENV_VAL="$kv"
        return 0
    fi
    _hy2_env_get "$name"
}

# envflag 取值, 与 Xray 的 NewEnvFlag 一致: 先查 **exact 名**(xray.location.cert), 命中即用;
# 否则查**归一化名**(XRAY_LOCATION_CERT)。两者各自先做"config.env 同名覆盖"。
# 用法: _hy2_envflag_get <exact> <normalized>  → 值留在 _HY2_ENV_VAL; rc: 0/1/2(同 _hy2_env_final)
# **不经 stdout**: 出口若走命令替换, 值末尾的换行会被再剥一次。
_hy2_envflag_get() {
    local exact="$1" norm="$2" rc=0
    _hy2_env_final "$exact"; rc=$?
    [ "$rc" = 2 ] && return 2
    if [ "$rc" = 0 ]; then return 0; fi
    _hy2_env_final "$norm"; rc=$?
    [ "$rc" = 2 ] && return 2
    if [ "$rc" = 0 ]; then return 0; fi
    _HY2_ENV_VAL=""
    return 1
}

# Xray 证书路径的**实际生效**基准(唯一): env 标志 xray.location.cert, 未设置 ⇒ 可执行文件目录。
# 依据 Xray-core common/platform 的
#   ReadCert(): filepath.IsAbs(file) ? ReadFile(file) : ReadFile(platform.GetCertLocation(file))
#   GetCertLocation(): filepath.Join(certPath, file)  —— **不把 certPath 绝对化**
# 因此生效值为**空串或相对路径**时, 最终落点取决于 **Xray 进程自己的 cwd**(我们无从得知) ⇒
# 返回 1(未知), 由上层按"未知"保守处理; 绝不能拿 xd 的 cwd 去凑一个答案。
# **决定删除目标时只准用它**(不能用候选并集)。
_hy2_xray_cert_root() {
    local xb="" rc=0
    _HY2_CERT_ROOT=""
    _hy2_envflag_get "xray.location.cert" "XRAY_LOCATION_CERT"; rc=$?
    if [ "$rc" = 0 ]; then
        case "$_HY2_ENV_VAL" in
            /*) _HY2_CERT_ROOT="$_HY2_ENV_VAL"; return 0 ;;
            *) return 1 ;;      # 空串/相对路径 ⇒ Xray 按自身 cwd 解析, 未知
        esac
    fi
    [ "$rc" = 2 ] && return 1   # 无法判定/配置损坏 ⇒ 未知(禁止据此判定删除目标)
    xb="${XRAY_BIN:-}"
    [ -n "$xb" ] || return 1
    xb=$(dirname "$xb")
    case "$xb" in
        /*) _HY2_CERT_ROOT="$xb"; return 0 ;;
        *) return 1 ;;
    esac
}

# 相对路径的**全部候选**基准(去重): 实际生效基准 + 可执行文件目录。
# **只用于"引用保护"**(命中任一即判"仍被引用", 朝保留侧失败): config.env 仅核心 >= v26.7.11
# 生效, stable 核心会忽略它, 故可执行文件目录必须留作候选。
# **绝不能用它决定删除目标** —— 并集只扩大"保留"的范围, 用它推导"该删哪个目录"会在
# config.env 与进程环境冲突时指向一个 Xray 实际并未使用的目录。
# 用法: _hy2_xray_cert_bases  → 候选基准写入数组 _HY2_BASES(每项一个); 恒返回 0。
# **不经 stdout / 不用换行分隔**: 基准本身可能以换行结尾, 用换行分隔会把它切成两个候选;
# 数组元素之间是天然分隔的, 不依赖任何会被剥尾或按行拆分的通道。
_hy2_xray_cert_bases() {
    local xb="" seen=""
    _HY2_BASES=()
    if _hy2_xray_cert_root; then
        seen="$_HY2_CERT_ROOT"
        [ -n "$seen" ] && _HY2_BASES+=("$seen")
    fi
    xb="${XRAY_BIN:-}"
    if [ -n "$xb" ]; then
        xb=$(dirname "$xb")
        [ "$xb" != "$seen" ] && _HY2_BASES+=("$xb")
    fi
    return 0
}

# 一条引用可能对应的全部绝对路径(去重): 绝对路径只有它自己; 相对路径 = 各候选基准 + ref。
# **仅用于"引用保护"**(命中任一即判"仍被引用"); 删除目标只看生效基准(见 _hy2_xray_cert_root)。
# 用法: _hy2_cert_ref_abspaths <ref>  → 候选写入数组 _HY2_ABSPATHS(恒返回 0, 无候选则空数组);
# ref 为空时返回 1。**不经 stdout 的换行分隔列表** —— 基准可能以换行结尾, 按行读会被拆碎。
_hy2_cert_ref_abspaths() {
    local ref="$1" base
    _HY2_ABSPATHS=()
    [ -n "$ref" ] || return 1
    case "$ref" in
        /*) _HY2_ABSPATHS+=("$ref"); return 0 ;;
    esac
    _hy2_xray_cert_bases
    for base in "${_HY2_BASES[@]}"; do
        [ -n "$base" ] || continue
        _HY2_ABSPATHS+=("$base/$ref")
    done
    return 0
}

# 与工作目录无关的 canonical 解析(统一入口)。
# 为什么不用裸 readlink -f: busybox 的 readlink -f 对**相对**符号链接自 1.35 起有
# workdir 相关的已知缺陷(Bug 16273), 而 Alpine 就是 busybox。做法是先 cd 进目标所在目录,
# 再解析 basename —— 交给 readlink 的永远是"该目录内的名字", 结果与调用方 cwd 无关;
# 用子 shell 保证不改变调用方 cwd。
# 用法: _hy2_realpath <path>  → stdout 真实路径; 无法解析返回 1
_hy2_realpath() {
    local p="$1" dir base out
    [ -n "$p" ] || return 1
    dir=$(dirname "$p"); base=$(basename "$p")
    [ -e "$dir" ] || [ -L "$dir" ] || return 1
    out=$( ( cd "$dir" 2>/dev/null && readlink -f "$base" 2>/dev/null ) ) || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# 路径的**真实身份**是否在 $CERT_DIR 之内(删除/还原这类破坏性动作的前置闸门)。
# 只做词面前缀匹配不够: "certs/tag/../../important" 同样满足 "$CERT_DIR"/*, 而 rm -rf 的
# 落点在 CERT_DIR 之外。故三重校验: ① 词面前缀(且不能就是 CERT_DIR 自身) ② 逐段拒绝 ".."
# ③ 目标存在时用 pwd -P 解析真实路径复核(符号链接指向目录外同样被拒)。
_hy2_cert_path_inside() {
    local p="$1" base real comp
    case "$p" in
        "$CERT_DIR"/?*) ;;
        *) return 1 ;;
    esac
    local IFS='/'
    for comp in $p; do
        [ "$comp" = ".." ] && return 1
    done
    base=$(cd "$CERT_DIR" 2>/dev/null && pwd -P) || return 1
    # 目标不存在(且不是符号链接): 不能直接放行 —— 父目录若是指向 CERT_DIR 之外的符号链接,
    # 目标一旦被创建就落在外面(certs/linkdir -> /outside 下的 new.pem)。故此时解析父目录。
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
        local parent; parent=$(dirname "$p")
        [ -e "$parent" ] || [ -L "$parent" ] || return 0   # 父目录也不存在 ⇒ 无落点可言
        real=$(_hy2_realpath "$parent") || return 1
        # 父目录归约后等于 base ⇒ 目标是 CERT_DIR 的直接子项(其自身已在上面通过词法校验)
        case "$real" in
            "$base"|"$base"/?*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # 必须对**目标自身**做 canonical 解析: 只解析父目录会让"文件本身是指向 CERT_DIR 之外的
    # 符号链接"蒙混过关(certs/tag/cert.pem -> /outside/x.pem), 而后续 cp/rm 会落到目标上。
    real=$(_hy2_realpath "$p") || real=""
    if [ -z "$real" ]; then
        # 无 readlink -f(极老 busybox)或解析失败: 非符号链接才可用"父目录 + 文件名"回退;
        # 符号链接(含悬浮)无法证实落点 ⇒ fail-closed, 拒绝
        if [ ! -L "$p" ]; then
            if [ -d "$p" ]; then
                real=$(cd "$p" 2>/dev/null && pwd -P)
            else
                real=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")
            fi
        fi
        [ -n "$real" ] || return 1
    fi
    case "$real" in
        "$base"/?*) return 0 ;;
        *) return 1 ;;
    esac
}

# 证书 Subject CN(无 openssl / 读不到 ⇒ 空输出)
_hy2_cert_cn() {
    local cert="$1"
    command -v openssl >/dev/null 2>&1 || return 0
    [ -f "$cert" ] || return 0
    openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | sed 's|/.*||'
}

# 可作为客户端 SNI 默认值的**具体** SAN 名(通配符 *.example.com 是匹配规则、不是合法 SNI,
# 故跳过; 证书另有具体 SAN 时仍会命中它)。无可用项返回 1。
_hy2_cert_sni_hint() {
    local cert="$1" n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in \*.*) continue ;; esac
        printf '%s' "$n"; return 0
    done <<< "$(_hy2_cert_san_names "$cert")"
    return 1
}

# 证书快照/回滚: 让"本次重新生成证书"成为**节点创建事务的一部分**。
# 为什么不能只看目录是否存在: 目录已存在(上次删节点时选了保留证书)但域名变了时, _gen_hy2_cert
# 成功后旧 cert/key 已被替换、它自己的备份也已删除 —— 若此后 render/commit 失败, 只"删掉新建
# 目录"的旧实现会因判据为假而完全不动, 留下没有任何节点引用的新证书, 且旧证书不可恢复。
# 快照放 DEPLOY_DIR 下的临时目录(不能放 CERT_DIR 内, 否则自己会污染"目录是否为空"的判据)。
# 用法: _hy2_cert_snapshot <cert> <key>   → stdout 快照目录; 失败返回 1
_hy2_cert_snapshot() {
    local cert="$1" key="$2" dir rc=0
    dir=$(mktemp -d "$DEPLOY_DIR/hy2cert.bak.XXXXXX") || return 1
    if [ -f "$cert" ]; then cp -p "$cert" "$dir/cert.pem" 2>/dev/null || rc=1; fi
    if [ "$rc" = 0 ] && [ -f "$key" ]; then cp -p "$key" "$dir/key.pem" 2>/dev/null || rc=1; fi
    if [ "$rc" != 0 ]; then
        rm -rf "$dir" 2>/dev/null
        [ -e "$dir" ] && _warn "证书快照清理失败, 已残留: $dir"
        return 1
    fi
    printf '%s' "$dir"
}

# 丢弃证书快照(节点创建成功后调用 —— 本次改动已被节点引用, 不再需要回滚点)
# 返回: 0 = 已删除(或本就无快照); 1 = 删除失败, 快照仍在(内含旧私钥副本, 调用方须如实报告)
_hy2_cert_snapshot_drop() {
    local bak="$1"
    [ -n "$bak" ] || return 0
    rm -rf "$bak" 2>/dev/null
    if [ -e "$bak" ]; then
        _warn "证书快照清理失败, 已残留(内含旧私钥副本): $bak"
        return 1
    fi
    return 0
}

# 撤销本次证书改动(仅"配置尚未提交"的失败路径调用 —— 提交成功后节点已引用该证书, 删掉
# 会让节点不可用)。语义: 快照里有 cert/key ⇒ 还原; 没有 ⇒ 本次是新建, 删掉这些文件。
# 用法: _hy2_cert_restore <快照目录> <cert> <key> <证书目录>
# 调用方负责只在"自签且本次真的生成过"时调用; 本函数再用路径闸门兜底。
# **返回码与 _gen_hy2_cert 同一套语义**: 0 = 已完整恢复(快照已消费); 2 = 无法安全恢复
# (快照**保留** + 报路径, 供人工恢复)。绝不能"回滚失败还销毁唯一快照" —— 那会把
# "节点没创建成功 + 新证书留下 + 旧证书唯一副本被删"这个最坏的残局重新造出来。
_hy2_cert_restore() {
    local bak="$1" cert="$2" key="$3" cdir="$4" ok=1
    # cert 与 key **都要**过闸门: 只查 cert 时, key 若是指向目录外的符号链接, 下面的 cp
    # 会跟随它写到外部(路径闸门的契约是"两个目标都在 CERT_DIR 内")
    if ! _hy2_cert_path_inside "$cert" || ! _hy2_cert_path_inside "$key"; then
        _warn "证书回滚跳过(路径不在 ${CERT_DIR} 内或为指向外部的符号链接): $cert / $key"
        _error "证书回滚未完成: 回滚目标不安全; 快照已保留, 请人工恢复"
        [ -n "$bak" ] && _warn "旧证书快照保留在: $bak"
        return 2
    fi
    if [ -n "$bak" ] && [ -f "$bak/cert.pem" ]; then
        cp -p "$bak/cert.pem" "$cert" 2>/dev/null || ok=0
    else
        rm -f "$cert" 2>/dev/null || ok=0
    fi
    if [ -n "$bak" ] && [ -f "$bak/key.pem" ]; then
        cp -p "$bak/key.pem" "$key" 2>/dev/null || ok=0
    else
        rm -f "$key" 2>/dev/null || ok=0
    fi
    if [ "$ok" != 1 ]; then
        _error "证书回滚未完成(cert/key 可能不一致); 快照已保留, 请人工恢复"
        [ -n "$bak" ] && _warn "旧证书快照保留在: $bak"
        return 2
    fi
    # 清掉已空的目录(rmdir 仅在空目录成功 ⇒ 不会误删既有内容; 非空失败即静默保留)
    [ -d "$cdir" ] && rmdir "$cdir" 2>/dev/null
    # 证书已恢复, 但快照删不掉 ⇒ 不能报"完整恢复": 快照里是旧私钥副本, 残留需人工处理
    if ! _hy2_cert_snapshot_drop "$bak"; then
        _warn "证书已恢复, 但快照未清理干净(内含旧私钥副本), 请手工删除: ${bak:-无}"
        return 1
    fi
    return 0
}

# 节点创建失败路径的统一收口(调用方不必各自解释 _hy2_cert_restore 的返回码)。
# 用法: _hy2_cert_rollback <cert_dirty> <bak> <cert> <key> <cert_dir>
# 返回: 0 = 无需回滚, 或证书已完整恢复; 2 = 回滚不完整(快照已保留, 需人工恢复)
_hy2_cert_rollback() {
    local dirty="$1" bak="$2" cert="$3" key="$4" cdir="$5" rc=0
    [ "$dirty" = "true" ] || return 0
    _hy2_cert_restore "$bak" "$cert" "$key" "$cdir"; rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            # 证书已恢复, 只是快照(旧私钥副本)没删掉 —— 不能报"回滚未完成"吓用户
            _warn "证书已恢复; 快照未清理干净(内含旧私钥副本), 请手工删除: ${bak:-无}"
            return 0
            ;;
        *)
            _error "证书回滚未完成, 快照已保留待人工恢复: ${bak:-无}"
            return 2
            ;;
    esac
}
# 节点正在使用的自签证书目录(仅 $CERT_DIR 之内)。返回 1 且无输出 = 该节点不是自签证书,
# 或证书落在 CERT_DIR 之外(自定义证书永不删除)。
# 交叉校验: metadata 声明 `self_signed=true`, config 里该入站的 certificateFile 是事实;
# 事实缺失(入站已被外部删除)时回退按 tag 推导的固定目录 —— 与创建路径同源。
_hy2_self_cert_dir() {
    local tag="$1" refs ref rreal cand cbase
    cand="$CERT_DIR/$tag"
    cbase=$(_hy2_realpath "$CERT_DIR") || cbase="$CERT_DIR"
    # 生效基准无法确定(envflag 为空串/相对路径 ⇒ Xray 按自身 cwd 解析, 我们无从得知)
    # ⇒ 无法判断证书是否真在本节点目录, 归属不明 ⇒ 拒绝 purge(朝保留侧失败)
    # 生效基准无法确定(envflag 缺失/相对/无法判定 ⇒ 落点取决于 Xray 自身 cwd)⇒ 归属不明
    _hy2_xray_cert_root || return 1
    [ "$(jq -r '.self_signed // false' "$NODES_DIR/${tag}.json" 2>/dev/null)" = "true" ] || return 1
    _hy2_cert_path_inside "$cand" || return 1
    # 归属目录**恒为本项目布局 CERT_DIR/<tag>**(由 tag 直接构造, 不受 config 内容影响);
    # config 里的路径只作**交叉校验**, 绝不拿它反推目录再 rm -rf ——
    # 反推会把 "certs/B/link.pem -> certs/A/cert.pem" 之类归属判成 A, 删掉别的节点的证书目录。
    cand=$(_hy2_realpath "$cand") || cand="$CERT_DIR/$tag"
    # 该入站引用的每个 cert/key 都必须 canonicalize 到 cand 之下(多证书/共享目录/外部链接
    # 一律判为"归属不明确" ⇒ 返回 1, 不进入 purge)
    refs=$(jq -r --arg t "$tag" '.inbounds[]? | select(.tag == $t) | .streamSettings.tlsSettings.certificates[]? | (.certificateFile // empty), (.keyFile // empty)' "$CONFIG_FILE" 2>/dev/null) || return 1
    # 引用按候选基准展开, 但**删除目标只由实际生效基准(及本节点目录)决定** —— 并集只扩大
    # "保留"范围, 拿它决定"该删哪个目录"会在 config.env 与进程环境冲突时指向 Xray 实际并未
    # 使用的目录。候选间结论冲突(有的说"是本节点目录", 有的说"材料在 CERT_DIR 之外")⇒ 拒绝。
    local ref aref rreal lex_ours ours foreign unres
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        ours=0; foreign=0; unres=0; idx=0
        _hy2_cert_ref_abspaths "$ref"
        for aref in "${_HY2_ABSPATHS[@]}"; do
            [ -n "$aref" ] || continue
            idx=$((idx + 1))
            # 第一个候选 = 实际生效基准: 只有它能决定"材料是否在 CERT_DIR 之外"(删除目标只看它);
            # 额外候选(可执行文件目录)仅用于**保留**判断(命中本节点目录即可), 不作冲突来源。
            is_eff=0; [ "$idx" = 1 ] && is_eff=1
            lex_ours=0
            case "$aref" in "$cand"/?*) lex_ours=1 ;; esac
            rreal=$(_hy2_realpath "$aref") || rreal=""
            if [ -z "$rreal" ]; then
                # 无法 canonicalize(文件已删除等): 词法兜底
                if [ "$lex_ours" = 1 ]; then ours=1
                elif [ "${aref#"$CERT_DIR"/}" != "$aref" ]; then unres=1
                elif [ "$is_eff" = 1 ]; then foreign=1
                fi
                continue
            fi
            if [ "${rreal#"$cand"/}" != "$rreal" ]; then ours=1          # 落点在本节点目录
            elif [ "${rreal#"$cbase"/}" != "$rreal" ]; then
                # 落点在 CERT_DIR 内但不在本节点目录: 若引用**词法上**在本节点目录内, 那只是
                # "本节点目录内的链接 → CERT_DIR 内别处"(删 cand 只删链接, 安全) ⇒ 算本节点;
                # 否则归属不明 ⇒ 拒绝
                if [ "$lex_ours" = 1 ]; then ours=1; else unres=1; fi
            elif [ "$is_eff" = 1 ]; then foreign=1                             # 材料在 CERT_DIR 之外
            fi
        done
        # 归属成立、材料没落到 CERT_DIR 之外、且无归属不明候选 ⇒ 本节点
        [ "$ours" = 1 ] && [ "$foreign" = 0 ] && [ "$unres" = 0 ] && continue
        # 其余一律拒绝(冲突/归属不明/自定义证书), 朝保留侧失败
        return 1
    done <<< "$refs"
    printf '%s' "$cand"
}

# 证书目录是否仍被 config 里的入站引用(节点删除成功后才调用 ⇒ 命中的都是存活引用)。
# config 里被手工写成 `..` 形式的引用无法安全比较, 一律保守判定为"仍被引用"。
_hy2_cert_dir_referenced() {
    local dir="$1" refs ref
    # certificateFile 与 keyFile **都要扫**: 引用模型是"证书目录是否仍被 config 使用",
    # 而 Xray 的 CertificateObject 是 cert+key 两个文件, 只扫 cert 会漏掉
    # "存活节点 B 的 keyFile 指向 A/key.pem" ⇒ rm -rf A 会删掉 B 正在用的私钥。
    refs=$(jq -r '.inbounds[]? | .streamSettings.tlsSettings.certificates[]? | (.certificateFile // empty), (.keyFile // empty)' "$CONFIG_FILE" 2>/dev/null) || return 0
    [ -n "$refs" ] || return 1
    local dreal cbase_real
    dreal=$(_hy2_realpath "$dir") || dreal=""
    cbase_real=$(_hy2_realpath "$CERT_DIR") || cbase_real="$CERT_DIR"
    if [ -z "$dreal" ]; then
        # 无法 canonicalize 待删目录 ⇒ fail-closed(与 jq 失败同口径): 目录存在就保守保留,
        # 免得"解析失败 ⇒ 退回词法比较 ⇒ 误判无引用 ⇒ 删掉仍在用的证书"
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            _warn "无法解析证书目录真实路径, 保守保留: $dir"
            return 0
        fi
        dreal="$dir"
    fi
    local ref aref rreal in_scope elsewhere
    # 生效基准未知(envflag 为空串/相对路径 ⇒ 落点取决于 Xray 自身 cwd)时, 相对引用的真实
    # 位置无从判定 ⇒ 只要存在**相对**引用就保守视为"可能指向本目录"(朝保留侧失败)
    local root_known=0
    _hy2_xray_cert_root && root_known=1
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        case "$ref" in
            /*) ;;
            *) [ "$root_known" = 0 ] && return 0 ;;
        esac
        # 一条引用可能对应多个绝对路径(生效基准 + 可执行文件目录两个候选), **逐个**解析;
        # 任一命中即视为仍被引用(朝保留侧失败)。
        in_scope=0; elsewhere=0
        _hy2_cert_ref_abspaths "$ref"
        for aref in "${_HY2_ABSPATHS[@]}"; do
            [ -n "$aref" ] || continue
            # ① canonical **先行**(真实路径是事实, 词法只作兜底): 只做词法 $CERT_DIR 过滤会漏掉
            #    "路径表面在外、经符号链接实际落入 CERT_DIR"的活引用
            #    (如 /srv/link-to-certs -> $CERT_DIR), 从而误删仍在用的证书目录。
            rreal=$(_hy2_realpath "$aref") || rreal=""
            if [ -n "$rreal" ]; then
                case "$rreal" in "$dreal"/?*) return 0 ;; esac     # 归约后位于待删目录之下
                # 归约成功即**确定**落点: 不在待删目录之下 ⇒ 该候选与本目录无关(即便它落在
                # CERT_DIR 内的别处, 也只是"指向别处的文件", 与本目录无关)
                elsewhere=1
                continue
            fi
            # ② 无法 canonicalize: 词法兜底 —— 词法就在待删目录下 ⇒ 直接算被引用;
            #    词法在 CERT_DIR 内 ⇒ 记入 in_scope(交由 ③ 保守处理)
            case "$aref" in "$dir"/?*) return 0 ;; esac
            case "$aref" in "$CERT_DIR"/?*) in_scope=1 ;; esac
        done
        # ③ 与本目录无关(不在 CERT_DIR 内, 或已归约到别处)⇒ 下一条
        [ "$in_scope" = 1 ] || continue
        [ "$elsewhere" = 1 ] && continue
        # ④ 确实在 CERT_DIR 内却解析不出落点: 只有"含 .."或"是符号链接"时无从排除它指向本目录,
        #    才保守视为被引用; 否则(普通文件已删除等)判定无关 —— 不做无差别保守, 免得一个
        #    无关目录的残留引用把其它目录的清理永久卡住
        case "$ref" in *".."*) return 0 ;; esac
        [ -L "$ref" ] && return 0
        continue
    done <<< "$refs"
    return 1
}

# 删除节点时询问是否一并删除自签证书(自定义证书不提示、不删除)。结果放入 _HY2_CERT_PURGE,
# 由 _hy2_purge_self_certs 在节点删除**成功后**落地 —— 删除失败(已回滚)时不能动证书。
_HY2_CERT_PURGE=()
_hy2_ask_purge_self_certs() {
    _HY2_CERT_PURGE=()
    local dirs=() t d i dup ans
    for t in "$@"; do
        d=$(_hy2_self_cert_dir "$t") || continue
        dup=0
        i=0
        while [ "$i" -lt "${#dirs[@]}" ]; do
            [ "${dirs[$i]}" = "$d" ] && { dup=1; break; }
            i=$((i+1))
        done
        [ "$dup" = 1 ] && continue
        dirs+=("$d")
    done
    [ "${#dirs[@]}" -gt 0 ] || return 0
    echo -e "  ${CYAN}检测到 ${#dirs[@]} 个节点使用自签证书:${NC}"
    for d in "${dirs[@]}"; do echo "    - $d"; done
    read -rp "  一并删除这些自签证书? [y/N]: " ans
    case "$ans" in
        y|Y) _HY2_CERT_PURGE=("${dirs[@]}") ;;
        *) _info "保留自签证书(仅删除节点)" ;;
    esac
    return 0
}

# 落地删除上一步收集的自签证书目录(仅在节点删除成功后调用)。
# 删除前两道闸: ① 路径真实落在 CERT_DIR 内(_hy2_cert_path_inside: 前缀 + 拒绝 ".." + pwd -P
# 复核符号链接); ② config 里已无存活入站引用它 —— 手工改 config / 采纳孤儿可能让多个入站
# 共用一个证书目录, 直接 rm -rf 会让仍在运行的节点立刻失去证书。
_hy2_purge_self_certs() {
    [ "${#_HY2_CERT_PURGE[@]}" -gt 0 ] || return 0
    local d n=0
    for d in "${_HY2_CERT_PURGE[@]}"; do
        _hy2_cert_path_inside "$d" || { _warn "跳过 ${CERT_DIR} 之外的证书路径: $d"; continue; }
        if _hy2_cert_dir_referenced "$d"; then
            _warn "证书目录仍被其它入站引用, 已保留: $d"
            continue
        fi
        rm -rf "$d" 2>/dev/null
        if [ -e "$d" ]; then _warn "自签证书删除失败, 已残留: $d"; else n=$((n+1)); fi
    done
    [ "$n" -gt 0 ] && _info "已删除 ${n} 个自签证书目录"
    _HY2_CERT_PURGE=()
    return 0
}

_add_hysteria2() {
    echo -e "\n  ${CYAN}=== Hysteria2 (QUIC · 可直连 · 需 TLS 证书) ===${NC}"
    local port=$(_input_port udp)

    # TLS 证书: 回车自签, 或输入证书路径
    local tag="xd-hy2-${port}"
    local cert_file="" key_file="" self_signed="false" sni="" self_domain="" tls_mode=""
    echo -e "  TLS 证书 回车使用自签证书, 或输入证书文件路径"
    read -rp "  cert 路径 (回车自签): " custom_cert
    if [ -n "$custom_cert" ]; then
        read -rp "  key 路径: " custom_key
        # M5: 证书路径直拼 JSON 模板, 先做字符校验再判存在性(报错可理解)
        _validate_json_text "$custom_cert" || { _error "cert 路径含非法字符(双引号/反斜杠/换行/制表符或 {{)"; return 1; }
        _validate_json_text "$custom_key" || { _error "key 路径含非法字符(双引号/反斜杠/换行/制表符或 {{)"; return 1; }
        if [ ! -f "$custom_cert" ] || [ ! -f "$custom_key" ]; then
            _error "证书文件不存在"; return 1
        fi
        cert_file="$custom_cert"; key_file="$custom_key"
        tls_mode="custom"
        _info "使用自定义证书: $cert_file"
        # SNI 默认值只取**可用于现代主机名校验的具体 SAN**, 绝不用硬编码默认值:
        #   - 通配符 SAN(*.example.com)是匹配规则、不是合法 SNI, 不能当默认值(否则会被
        #     域名校验拒绝, 用户必须先撞一次错);
        #   - CN-only 证书在现代校验下无效(Go crypto/x509 忽略 CN, Xray 官方 tls.md 亦要求
        #     serverName 存在于证书 SAN), 同样不给默认值。
        # 两种情形都只告警 + 要求手输, 不替用户猜一个"看起来对"的值。
        local cert_hint="" cert_cn="" sni_in=""
        cert_hint=$(_hy2_cert_sni_hint "$cert_file") || cert_hint=""
        if [ -z "$cert_hint" ]; then
            if [ -n "$(_hy2_cert_san_names "$cert_file")" ]; then
                _warn "证书 SAN 只有通配符; 通配符不能作为客户端 SNI, 请填写一个具体主机名"
            else
                cert_cn=$(_hy2_cert_cn "$cert_file")
                [ -n "$cert_cn" ] && _warn "证书只有 CN(${cert_cn}) 且无 SAN; 现代 TLS 主机名校验忽略 CN, 该证书可能无法通过客户端校验"
            fi
        fi
        # RT-1/M1 同类: EOF(管道驱动/会话异常/stdin 耗尽)下 read 立即返回非 0 且 sni_in 恒空,
        # 无守卫会无限刷"不能为空"(实测 1s 内 14 万+ 行, 进程不退出)。契约与 _ask_link_addr 一致:
        # EOF 即无法再获得输入 ⇒ 显式 return 1 中止(此处尚未生成证书/提交配置, 中止无副作用)。
        # 注意 **不得** 用 ${sni_in:-$cert_hint} 兜底 —— 在 cert_hint 为空的分支里那是恒空值,
        # 兜不出非空输入, 反而会把"EOF 中止"退化成"死循环"。两处 read 都必须带守卫。
        while :; do
            if [ -n "$cert_hint" ]; then
                read -rp "  SNI (默认 ${cert_hint}): " sni_in || return 1
                sni_in=${sni_in:-$cert_hint}
            else
                read -rp "  SNI (证书无可用 SAN, 请手动输入具体主机名): " sni_in || return 1
            fi
            [ "$sni_in" = "0" ] && { _info "已取消"; return 1; }
            if [ -z "$sni_in" ]; then
                _error "无法从证书读取可用 SAN, SNI 不能为空"
                continue
            fi
            if _validate_domain "$sni_in"; then sni="$sni_in"; break; fi
            _error "SNI 格式非法(仅字母/数字/连字符, 点分段): ${sni_in}"
        done
    else
        # 自签证书: 域名会写进证书 CN/SAN, 是客户端 SNI 的唯一来源, 必须可输入(不能写死)
        # —— 与官方 Hysteria2 模块的「证书域名/SAN」口径一致。回车用默认 build.nvidia.com。
        # **生成推迟到提交节点之前**(见下方 tls_mode=selfsigned 分支): 提前生成会让"中途
        # 放弃 / ^C"留下一个没有任何节点引用的证书目录(实测)。
        while :; do
            # RT-1/M1 同类: EOF 下 read 失败、self_domain 为空 ⇒ ${self_domain:-build.nvidia.com}
            # 兜出默认域名并 break —— 不会死循环, 但会在"用户根本没答完"时静默用默认值建节点。
            # 故 EOF 一律显式中止(return 1), 与上方 SNI 循环同契约。
            read -rp "  自签证书域名/SAN (回车默认 build.nvidia.com): " self_domain || return 1
            [ "$self_domain" = "0" ] && { _info "已取消"; return 1; }
            self_domain=${self_domain:-build.nvidia.com}
            _validate_domain "$self_domain" && break
            _error "域名格式非法(仅字母/数字/连字符, 点分段): ${self_domain}"
        done
        tls_mode="selfsigned"; self_signed="true"
    fi

    # 认证密码
    local auth
    auth=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    read -rp "  认证密码 (回车随机): " custom_auth
    auth=${custom_auth:-$auth}
    # M5: 认证串直拼 JSON 模板与 hy2 链接, 校验同 _add_shadowsocks
    _validate_json_text "$auth" || { _error "认证密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }

    # 拥塞控制
    echo -e "  拥塞控制:"
    echo -e "  ${GREEN}[1]${NC} bbr"
    echo -e "  ${GREEN}[2]${NC} brutal"
    echo -e "  ${GREEN}[3]${NC} force-brutal"
    local cc_choice
    read -rp "  选择 (默认 1): " cc_choice
    local congestion="bbr"
    local brutal_up="" brutal_down=""
    case "${cc_choice:-1}" in
        2|3)
            [ "${cc_choice}" = "3" ] && congestion="force-brutal" || congestion="brutal"
            echo -e "  ${YELLOW}${congestion} 模式须填写带宽, 格式: 100 mbps / 10m / 1g${NC}"
            read -rp "  上传带宽 (服务器→客户端, 回车不限): " brutal_up
            read -rp "  下载带宽 (客户端→服务器, 回车不限): " brutal_down
            brutal_up=$(_normalize_bandwidth "$brutal_up")
            brutal_down=$(_normalize_bandwidth "$brutal_down")
            ;;
    esac

    local default_name="HY2-${port}"
    read -rp "  节点名称 (默认 ${default_name}): " name
    name=${name:-$default_name}
    _ensure_unique_name "$name" || return 1

    local listen="::"

    # 混淆(FinalMask.udp) —— 官方文档 finalmask.md「UDPMask」; 默认不启用。
    # 兼容性提示的出处是 Hysteria 官方文档 Full-Server-Config「混淆」(Xray 的
    # finalmask.md 只定义字段, 没有这句兼容性说明), 故按来源点名而不写"官方"。
    local obfs_type="" obfs_pw="" obfs_size="" obfs_mask="" obfs_pw_in="" obfs_choice
    echo -e "  混淆 (FinalMask.udp, 默认关闭):"
    echo -e "  ${GREEN}[1]${NC} 不启用  ${GREEN}[2]${NC} salamander  ${GREEN}[3]${NC} gecko"
    read -rp "  选择 (默认 1): " obfs_choice
    case "${obfs_choice:-1}" in
        2|3)
            obfs_type="salamander"
            obfs_pw=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
            read -rp "  混淆密码 (回车随机): " obfs_pw_in
            obfs_pw=${obfs_pw_in:-$obfs_pw}
            _validate_json_text "$obfs_pw" || { _error "混淆密码含非法字符(双引号/反斜杠/换行/制表符或 {{), 请更换"; return 1; }
            if [ "$obfs_choice" = "3" ]; then
                # gecko 需要核心支持 packetSize(见 _hy2_gecko_supported): 旧核心会静默忽略
                # 该字段、退化成无分片的 salamander, 服务端照常启动而客户端连不上。
                # **不支持时直接拒绝, 不自动降级**: 用户明确选了 gecko, 替他改成一个不同的
                # 混淆形态是改变请求(且客户端会按 gecko 配置而服务端在跑 salamander)。
                # 版本门控的存在本身已表明"旧核心无法安全承载 gecko", 故 fail-closed。
                if ! _hy2_gecko_supported; then
                    _error "当前核心不支持 gecko 分片(packetSize 需核心 >= ${_HY2_GECKO_MIN_VER}); 已取消, 未修改任何配置"
                    _tip "请先升级/切换 Xray 核心(核心版本门控见项目文档), 或改选 [2] 普通 salamander"
                    return 1
                fi
                # gecko: packetSize 非空即启用(Xray 官方 finalmask.md「#### gecko」)。
                # **空输入必须落成显式尺寸**: Xray 侧 packetSize 留空 = 不启用 Gecko
                # (退化成普通 salamander), 所以"回车用默认"只能填**具体值** —— 否则
                # 用户选了 [3] 却得到 salamander。所填 512-1200 来自 Hysteria 官方
                # Full-Client-Config 的 gecko 默认值(minPacketSize 默认 512,
                # maxPacketSize 默认 1200), **不是 Xray 文档里的默认值**。
                read -rp "  packetSize (Int32Range, 如 512-1200; 回车用 Hysteria 官方 gecko 默认 512-1200): " obfs_size
                obfs_size="${obfs_size:-512-1200}"
                local size_why; size_why=$(_hy2_obfs_size_invalid "$obfs_size")
                [ -n "$size_why" ] && { _error "packetSize 非法: ${size_why}"; return 1; }
                # 规范化(排序 + 去前导零)后回写, 使元数据/clash 与 Xray 看到同一区间
                obfs_size=$(_hy2_obfs_size_canon "$obfs_size") || { _error "packetSize 规范化失败"; return 1; }
            fi
            obfs_mask=$(_hy2_obfs_mask_block "$obfs_type" "$obfs_pw" "$obfs_size") || { _error "混淆参数构造失败"; return 1; }
            ;;
    esac

    # 构建 brutal 参数块(brutal / force-brutal 模式有值)
    local brutal_block=""
    if [ "$congestion" = "brutal" ] || [ "$congestion" = "force-brutal" ]; then
        brutal_block=""
        [ -n "$brutal_up" ] && brutal_block="${brutal_block}, \"brutalUp\": \"${brutal_up}\""
        [ -n "$brutal_down" ] && brutal_block="${brutal_block}, \"brutalDown\": \"${brutal_down}\""
    fi

    # ---------------------------------------------------------------------
    # 自签证书: **所有提问结束后、即将提交配置时才真正生成**(0.17.7)。
    # 早先是在 TLS 提问阶段就生成, 于是"生成后 ^C / 中途放弃"会留下一个没有任何节点引用的
    # 证书目录(实测); 提交失败时同样会留下。故: 生成推迟到此, 且**生成本身纳入节点创建
    # 事务** —— 生成前先对既有 cert/key 做快照, render/commit 失败时按快照还原(快照里没有
    # 的说明是本次新建, 删掉), 而不是只看"目录是不是新出现的"。
    # 只看目录会漏掉一类真实残局: 目录已存在(上次删节点选了保留证书)但域名变了 ⇒ 重新生成
    # 已把旧证书替换掉、_gen_hy2_cert 自己的备份也已删除, 此时"删新建目录"判据为假 ⇒ 既不还原
    # 也不清理, 留下无节点引用的新证书且旧证书不可恢复。
    # 既有证书(可复用)与自定义证书不生成 ⇒ 无快照、不进入回滚路径。
    # ---------------------------------------------------------------------
    local cert_bak="" cert_dirty="false" cert_dir_existed="false"
    if [ "$tls_mode" = "selfsigned" ]; then
        cert_file="$CERT_DIR/$tag/cert.pem"; key_file="$CERT_DIR/$tag/key.pem"
        local cert_dir="$CERT_DIR/$tag" genrc=0
        [ -e "$cert_dir" ] && cert_dir_existed="true"
        if _hy2_cert_reusable "$cert_file" "$key_file" "$self_domain"; then
            # 已有证书且(有 openssl 时)SAN 覆盖本次域名 ⇒ 沿用。无 openssl 时无从校验 SAN,
            # 复用但如实报告, 不假装证书身份已与输入域名统一。
            if ! command -v openssl >/dev/null 2>&1; then
                _warn "无 openssl, 无法校验已有证书 SAN; 将复用既有证书(证书身份可能非 ${self_domain})"
                _tip "如需确保证书 SAN 与域名一致, 请安装 openssl 后重新添加该节点"
            fi
            _info "已有证书, 复用: $cert_dir"
        else
            [ -f "$cert_file" ] && [ -f "$key_file" ] && \
                _warn "已有证书不可复用(SAN 不含 ${self_domain}, 或 cert/key 不匹配), 重新生成: $cert_dir"
            cert_bak=$(_hy2_cert_snapshot "$cert_file" "$key_file") || {
                _error "证书快照失败(无法备份既有证书), 已中止, 未生成新证书"; return 1; }
            _gen_hy2_cert "$tag" "$self_domain" || genrc=$?
            if [ "$genrc" != 0 ]; then
                # 生成失败: 证书已是提交前状态(生成器自带回滚), 丢掉快照即可;
                # 目录是本次新建且已空 ⇒ 顺手清掉(rc=2 的备份必须保留, 绝不动)
                if ! _hy2_cert_snapshot_drop "$cert_bak"; then
                    _warn "证书快照未清理干净(内含旧私钥副本), 请手工删除: $cert_bak"
                fi
                [ "$genrc" = 1 ] && [ "$cert_dir_existed" = "false" ] && rmdir "$cert_dir" 2>/dev/null
                return 1
            fi
            cert_dirty="true"
        fi
        # SNI 以**证书实际身份**为准 —— 现代 TLS 认 SAN, 故优先取 SAN 的 DNS 名(与 Xray
        # 官方 tls.md「serverName 需存在于证书 SAN 中」一致), 无 SAN 才回退 CN(兼容手工
        # 签发的 CN-only 证书); 都没有(无 openssl)则回退**本次输入域名** —— 绝不能退回
        # 无关的硬编码默认值(那会让 sni 与实际证书、与用户输入三方脱节)。
        local self_cert_domain
        self_cert_domain=$(_hy2_cert_domain "$cert_file" "$self_domain")
        sni=${self_cert_domain:-$self_domain}
    fi

    # 渲染模板
    R_LISTEN="$listen" R_PORT="$port" R_TAG="$tag"
    R_AUTH="$auth" R_CERT_FILE="$cert_file" R_KEY_FILE="$key_file"
    R_CONGESTION="$congestion" R_BRUTAL_PARAMS_BLOCK="$brutal_block"
    R_OBFS_MASK_BLOCK="$obfs_mask"
    local inbound
    if ! inbound=$(_render_template "$(_tpl_path hysteria2)"); then
        _hy2_cert_rollback "$cert_dirty" "$cert_bak" "$cert_file" "$key_file" "$CERT_DIR/$tag" || return 2
        return 1
    fi

    if ! _commit_inbound "$inbound"; then
        _hy2_cert_rollback "$cert_dirty" "$cert_bak" "$cert_file" "$key_file" "$CERT_DIR/$tag" || return 2
        return 1
    fi
    # 配置已提交(节点已引用该证书) ⇒ 回滚点作废; 删不掉要如实报(快照内含旧私钥副本)
    if [ "$cert_dirty" = "true" ] && ! _hy2_cert_snapshot_drop "$cert_bak"; then
        _warn "证书快照未清理干净(内含旧私钥副本), 请手工删除: $cert_bak"
    fi

    local addr
    addr=$(_ask_link_addr) || { _error "节点已加入 Xray 配置, 但未获取到客户端连接地址(输入已结束); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"; return 1; }

    # ---------------------------------------------------------------------
    # 先落 **canonical metadata**, 再由它派生 link 与 clash —— 与修改路径**同一条**逻辑。
    # 创建路径曾自己内联拼 link(无条件 `&obfs=salamander`), 于是 gecko 节点会被写进一条
    # 无法表达 packetSize 的链接, 而同一节点走菜单修改时 _rebuild_hy2_link 却拒绝生成
    # ⇒ 同一状态两个入口两种结果。现统一为:
    #   metadata(权威) → _rebuild_hy2_link(可表达才生成) / _hy2_clash_line(能完整承载该尺寸)
    # ---------------------------------------------------------------------
    local meta_json
    meta_json=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg proto "hysteria2" \
        --argjson port "$port" --arg listen "$listen" --arg addr "$addr" \
        --arg auth "$auth" --arg sni "$sni" --arg congestion "$congestion" \
        --arg brutalUp "$brutal_up" --arg brutalDown "$brutal_down" \
        --arg obfsType "$obfs_type" --arg obfsPw "$obfs_pw" --arg obfsSize "$obfs_size" \
        --argjson ss "$self_signed" \
        '{tag:$tag,name:$name,protocol:$proto,port:$port,listen:$listen,link_addr:$addr,auth:$auth,sni:$sni,congestion:$congestion,brutal_up:$brutalUp,brutal_down:$brutalDown,obfs_type:$obfsType,obfs_password:$obfsPw,obfs_packet_size:(if $obfsSize == "" then null else $obfsSize end),self_signed:$ss,share_link:""}')
    if ! _save_node_meta "$tag" "$meta_json"; then
        _error "节点已加入 Xray 配置, 但元数据写入失败(${tag}); 将按孤儿入站处理, 建议删除后重建(或使用 [采纳孤儿入站] 补回元数据)"
        return 1
    fi
    local meta="$NODES_DIR/${tag}.json"
    # 派生状态(链接 + clash)走**唯一入口**(clash 步骤是 upsert, 新建节点会追加条目);
    # 失败只告警, **不**回滚已提交的 config/metadata。
    _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
    local link=""
    link=$(jq -r '.share_link // ""' "$meta" 2>/dev/null)

    _success "节点 [${name}] 创建成功"
    if [ "$self_signed" = "true" ]; then
        _tip "自签证书, 客户端须手动信任证书 (insecure=1)"
    else
        _tip "使用自定义证书, SNI: ${sni}"
    fi
    echo -e "  ${CYAN}拥塞控制:${NC} ${congestion}"
    if [ -n "$obfs_type" ]; then
        if [ -n "$obfs_size" ]; then
            echo -e "  ${CYAN}混淆:${NC} gecko (FinalMask.udp) · packetSize=${obfs_size}"
        else
            echo -e "  ${CYAN}混淆:${NC} salamander (FinalMask.udp)"
        fi
    fi
    if [ -n "$link" ]; then
        echo -e "  ${CYAN}分享链接:${NC} ${link}"
    else
        echo -e "  ${YELLOW}分享链接: 无(见上方说明; 客户端配置见 Clash 条目)${NC}"
    fi
}

# ---------------------------------------------------------------------------
# 分享链接重建(HY2 / Reality 域名切换后更新链接用)
# ---------------------------------------------------------------------------

# 重建 hy2:// 分享链接(从元数据读参数)
# 用法:_rebuild_hy2_link <meta_file>
# R38(M10): 必填字段用 // empty 读取并显式判空 —— 原写法对"被采纳的节点"(metadata 只有
# tag/protocol/port/listen/uuid/sni/link_addr/share_link, 没有 auth/congestion)会产出
# hy2://null@[::]:5000/?sni=&congestion=null#... 这种字面量 null 的坏链接; 它非空,
# 于是通过上层 `[ -n "$newlink" ]` 校验被写进 metadata, 覆盖掉原链接且不可恢复。
_rebuild_hy2_link() {
    local meta="$1"
    local auth host port sni congestion brutal_up brutal_down name self_signed
    auth=$(jq -r '.auth // empty' "$meta")
    host=$(jq -r '.link_addr // empty' "$meta")
    port=$(jq -r '.port // empty' "$meta")
    sni=$(jq -r '.sni // "build.nvidia.com"' "$meta")
    congestion=$(jq -r '.congestion // empty' "$meta")
    brutal_up=$(jq -r '.brutal_up // empty' "$meta")
    brutal_down=$(jq -r '.brutal_down // empty' "$meta")
    self_signed=$(jq -r '.self_signed // "false"' "$meta")
    name=$(jq -r '.name // empty' "$meta")
    if [ -z "$auth" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$congestion" ] || [ -z "$name" ]; then
        _error "节点元数据缺少必要字段(auth/link_addr/port/congestion/name), 无法重建分享链接: $meta"
        return 1
    fi
    # 混淆: 客户端参数名与类型枚举见 Hysteria 官方 URI-Scheme(obfs / obfs-password)。
    # 类型必须用**客户端**枚举(obfs=gecko), 不能照抄服务端的 type:"salamander" —— 否则客户端
    # 按无分片连接而服务端在分片, 握手必失败。类型判定统一走 _hy2_obfs_kind。
    local obfs_kind obfs_pw obfs_size
    # 未知 obfs_type = 损坏 metadata ⇒ 拒绝生成(不产出半成品链接)
    obfs_kind=$(_hy2_obfs_kind "$meta") || return 1
    obfs_pw=$(jq -r '.obfs_password // empty' "$meta")
    obfs_size=$(_hy2_obfs_size_get "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link="hy2://$(_url_encode "$auth")@${link_ip}:${port}/?sni=$(_url_encode "$sni")"
    [ "$self_signed" = "true" ] && link="${link}&insecure=1&allowInsecure=1"
    link="${link}&congestion=${congestion}"
    [ -n "$brutal_up" ] && link="${link}&up=$(_url_encode "$brutal_up")"
    [ -n "$brutal_down" ] && link="${link}&down=$(_url_encode "$brutal_down")"
    if [ "$obfs_kind" != "none" ]; then
        # 自定义尺寸无法用 URI 表达 ⇒ 拒绝(默认 512-1200 可表达, 见 _hy2_link_unexpressible)
        [ "$obfs_kind" = "gecko" ] && ! _hy2_obfs_size_is_default "$meta" && return 1
        link="${link}&obfs=${obfs_kind}&obfs-password=$(_url_encode "$obfs_pw")"
    fi
    # 端口跳跃端口(如果已配置, 统一通过 _read_hop_ranges_display 读取, M9)
    local hop_ports
    hop_ports=$(_read_hop_ranges_display "$meta" 2>/dev/null)
    [ -n "$hop_ports" ] && link="${link}&mport=$(_url_encode "$hop_ports")"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# ---------------------------------------------------------------------------
# 从 hy2 节点元数据重建 clash.yaml 条目(mihomo 格式) —— 创建/拥塞切换/带宽调整/
# 端口跳跃切换后的唯一生成入口, 与分享链接重建(_rebuild_hy2_link)同级, 单一来源。
# 字段依据 Meta-Docs(config/proxies/hysteria2)与 mihomo 源码(adapter/outbound/hysteria2.go):
#   - mihomo 无 `congestion-control` 字段(会被解码器静默忽略), brutal 由 up/down 触发
#   - 端口跳跃用 `ports`(mihomo 原生支持, hop-interval 默认 30s), flow 上下文必须加引号
#   - 混淆用 `obfs`/`obfs-password`, gecko 尺寸用 `obfs-min/max-packet-size`(仅 gecko)
# 用法: _hy2_clash_line <meta_file>; stdout 为单行 flow 条目(以 "- {name: ...}" 开头)
# ---------------------------------------------------------------------------
_hy2_clash_line() {
    local meta="$1"
    local name addr port auth sni congestion brutal_up brutal_down self_signed
    name=$(jq -r '.name // empty' "$meta")
    addr=$(jq -r '.link_addr // empty' "$meta")
    port=$(jq -r '.port // empty' "$meta")
    auth=$(jq -r '.auth // empty' "$meta")
    sni=$(jq -r '.sni // "build.nvidia.com"' "$meta")
    congestion=$(jq -r '.congestion // empty' "$meta")
    brutal_up=$(jq -r '.brutal_up // empty' "$meta")
    brutal_down=$(jq -r '.brutal_down // empty' "$meta")
    self_signed=$(jq -r '.self_signed // "false"' "$meta")
    # 混淆字段依据 Meta-Docs(config/proxies/hysteria2): obfs / obfs-password /
    # obfs-min-packet-size / obfs-max-packet-size。mihomo 只在 `obfs: gecko` 分支读取
    # 尺寸字段(case "salamander" 只取密码, 尺寸会被解码器静默忽略), 故 **有尺寸时
    # obfs 必须写 gecko** —— 这正是官方 URI 表达不出来的那部分, clash 条目能完整承载它。
    # 类型与尺寸都取自**客户端视角**(gecko 是客户端枚举; 尺寸仅 gecko 有)
    local obfs_kind obfs_pw obfs_size obfs_min="" obfs_max=""
    # 未知 obfs_type = 损坏 metadata ⇒ 拒绝产出条目(不写"写着 salamander、服务端在分片"的行)
    obfs_kind=$(_hy2_obfs_kind "$meta") || return 1
    obfs_pw=$(jq -r '.obfs_password // empty' "$meta")
    obfs_size=$(_hy2_obfs_size_get "$meta")
    if [ "$obfs_kind" = "gecko" ]; then
        # min/max 必须来自**同一规范化结果**, 与 Xray 侧的 packetSize 同区间: 直接按 "-"
        # 切分会把 1500-800 原样导出成 min=1500/max=800, 而 mihomo 要求 max>=min。
        obfs_min=$(_hy2_obfs_size_min "$obfs_size")
        obfs_max=$(_hy2_obfs_size_max "$obfs_size")
        # 有尺寸却解析不出两端 = 畸形元数据; 宁可拒绝也不产出"写着 salamander、服务端在分片"的条目
        [ -n "$obfs_min" ] && [ -n "$obfs_max" ] || return 1
    fi
    if [ -z "$name" ] || [ -z "$addr" ] || [ -z "$port" ] || [ -z "$auth" ]; then
        _error "节点元数据缺少必要字段(name/link_addr/port/auth), 无法生成 clash 条目: $meta"
        return 1
    fi
    local line="- {name: \"$(_yaml_dq "$name")\", type: hysteria2, server: \"$(_yaml_dq "$addr")\", port: $port, password: \"$(_yaml_dq "$auth")\", sni: \"$(_yaml_dq "$sni")\""
    # brutal/force-brutal: mihomo 以 up/down 触发 brutal 速率控制; 带宽未填则省略(与分享链接一致)
    if [ "$congestion" = "brutal" ] || [ "$congestion" = "force-brutal" ]; then
        [ -n "$brutal_up" ] && line="${line}, up: \"$(_yaml_dq "$brutal_up")\""
        [ -n "$brutal_down" ] && line="${line}, down: \"$(_yaml_dq "$brutal_down")\""
    fi
    # 混淆: mihomo 有独立字段可完整表达(含 gecko 分片尺寸; 官方 hy2 URI 无尺寸参数)
    if [ "$obfs_kind" != "none" ]; then
        line="${line}, obfs: ${obfs_kind}, obfs-password: \"$(_yaml_dq "$obfs_pw")\""
        [ -n "$obfs_min" ] && line="${line}, obfs-min-packet-size: ${obfs_min}"
        [ -n "$obfs_max" ] && line="${line}, obfs-max-packet-size: ${obfs_max}"
    fi
    # 端口跳跃: 引号必须有 —— flow 映射上下文里裸逗号会被解析成字段分隔符
    local hop_ports
    hop_ports=$(_read_hop_ranges_display "$meta" 2>/dev/null)
    [ -n "$hop_ports" ] && line="${line}, ports: \"${hop_ports}\""
    [ "$self_signed" = "true" ] && line="${line}, skip-cert-verify: true"
    printf '%s}' "$line"
}

# ---------------------------------------------------------------------------
# hy2 派生状态(分享链接 + clash 条目)的**唯一同步入口** —— 创建/改端口/混淆/拥塞/带宽/
# 端口跳跃六条路径都只调它, 不得各自再写一份"重建链接 + 同步 clash"(副本必然漂移)。
# 语义:
#   (a) 可表达              → 写回 share_link, 并同步 clash;
#   (b) 不可表达(gecko 自定义尺寸) → 清空 share_link, **继续**同步 clash(clash 能完整承载该尺寸);
#   (c) 元数据缺字段         → **保留**旧 share_link, 如实报告, 不写坏值。
# 两部分失败**分别**告警(share_link 写入 vs clash 同步), 返回码为两者合并(1 = 至少一项失败);
# 二者都是派生状态, 失败**不**回滚已提交的 config/metadata —— 调用方只 _warn, 不当作事务失败。
# 用法: _hy2_sync_derived <meta_file> [old_name]
#   old_name 非空且与现名不同(改端口默认连带改名)时先删旧名条目 —— 与 _sync_node_clash 同口径。
#   _add_node_to_yaml 只按**同名**去重, 管不到旧名, 不删就会在 clash.yaml 留下指向旧端口的幽灵条目。
# ---------------------------------------------------------------------------
_hy2_sync_derived() {
    local meta="$1" old_name="${2:-}" link="" nname="" nline="" lrc=0 crc=0
    # (1) share_link: 派生值, 但写在 metadata 里、是用户直接看到的主输出 —— 失败要单独报。
    if link=$(_rebuild_hy2_link "$meta") && [ -n "$link" ]; then
        _meta_update "$meta" '.share_link=$l' --arg l "$link" || {
            lrc=1
            _error "分享链接写入失败(节点元数据不可写?): $meta"
        }
    elif _hy2_link_unexpressible "$meta"; then
        _meta_update "$meta" '.share_link=""' || {
            lrc=1
            _error "分享链接清空失败(节点元数据不可写?): $meta"
        }
        _warn "当前混淆(gecko 带自定义分片尺寸)无法用官方 hy2 链接表达, 已清空分享链接"
        _tip "官方 URI 的 obfs 只表达类型(salamander/gecko), 没有尺寸参数; 只有默认 512-1200 可表达"
        _tip "请用 Clash 条目(含 obfs-min/max-packet-size)导入客户端"
    else
        _warn "分享链接重建失败(元数据缺少必要字段), 已保留原链接"
    fi
    # (2) clash.yaml: 可再生派生缓存 —— 失败单独报, 且**不**回滚权威状态。
    # 必须 **upsert**(条目在 → 替换; 不在 → 追加), 否则新建节点会静默漏条目。
    nname=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    local key
    if [ -n "$nname" ] && nline=$(_hy2_clash_line "$meta"); then
        # 改名(改端口默认连带改名)时先删旧名条目, 否则旧条目会以"另一个节点"的形态留在
        # clash.yaml 里指向旧端口(幽灵条目)。与 _sync_node_clash 的 old_name 处理同源。
        if [ -n "$old_name" ] && [ "$old_name" != "$nname" ]; then
            _remove_node_from_yaml_by_name "$old_name" 2>/dev/null || {
                crc=1
                _warn "Clash YAML 旧条目删除失败(${old_name}), 可手工编辑 ${CLASH_YAML}"
            }
        fi
        key=$(_yaml_dq "$nname")
        if [ -f "$CLASH_YAML" ] && grep -qF "name: \"${key}\"" "$CLASH_YAML" 2>/dev/null; then
            _replace_node_in_yaml "$nline" "$nname" || {
                crc=1
                _warn "Clash YAML 条目同步失败, 可手工编辑 ${CLASH_YAML}"
            }
        else
            _add_node_to_yaml "$nline" "$nname" || {
                crc=1
                _warn "Clash YAML 条目追加失败, 可手工编辑 ${CLASH_YAML}"
            }
        fi
    else
        crc=1
        _warn "Clash 条目生成失败(元数据不完整), 可手工编辑 ${CLASH_YAML}"
    fi
    # 返回码 = 两部分合并(1 = 至少一部分失败)。**具体哪一部分失败已在上方分别报出** ——
    # 调用方只据此提示"详情见上", 不要再把它们混成一句笼统文案。
    [ "$lrc" -eq 0 ] && [ "$crc" -eq 0 ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 从节点 metadata 重建 clash.yaml 条目 —— 全协议统一入口(2026-09-12 审查 F1)。
# 背景: 此前只有 hy2 有 builder(_hy2_clash_line), 其余协议的条目只存在于创建时刻
# (各 _add_* 内联拼接), 之后改端口/改监听/Reality 域名切换都不会同步 clash.yaml,
# 留下"订阅陈旧 + 删除时幽灵条目"的派生缓存分裂。
# 字段口径与各 _add_* 的内联条目逐字段一致(含 support-x25519mlkem768: true 与
# chrome 指纹 —— 新 Reality 服务器要求, 见 _add_vless_tcp_reality_vision 注释)。
# 失败(被采纳节点缺字段等)返回 1 且无输出, 由 _sync_node_clash 保留旧行并告警。
# 用法: line=$(_rebuild_clash_line <meta_file>)
# ---------------------------------------------------------------------------
_rebuild_clash_line() {
    local meta="$1" proto name addr port uuid enc enc_clash=""
    proto=$(jq -r '.protocol // empty' "$meta" 2>/dev/null)
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    addr=$(jq -r '.link_addr // empty' "$meta" 2>/dev/null)
    port=$(jq -r '.port // empty' "$meta" 2>/dev/null)
    uuid=$(jq -r '.uuid // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] && [ -n "$addr" ] && [ -n "$port" ] || return 1
    enc=$(jq -r '.encryption // "none"' "$meta" 2>/dev/null)
    if [ -n "$enc" ] && [ "$enc" != "none" ]; then
        enc_clash=", encryption: \"$(_yaml_dq "$enc")\""
    fi
    case "$proto" in
        hysteria2)
            _hy2_clash_line "$meta"
            ;;
        vless-tcp-reality-vision)
            local pk sid sni
            pk=$(jq -r '.public_key // empty' "$meta")
            sid=$(jq -r '.short_id // empty' "$meta")
            sni=$(jq -r '.sni // empty' "$meta")
            [ -n "$uuid" ] && [ -n "$pk" ] && [ -n "$sid" ] && [ -n "$sni" ] || return 1
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, flow: xtls-rprx-vision, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $pk, short-id: $sid, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, network: tcp}"
            ;;
        vless-xhttp-reality)
            local pk sid sni path
            pk=$(jq -r '.public_key // empty' "$meta")
            sid=$(jq -r '.short_id // empty' "$meta")
            sni=$(jq -r '.sni // empty' "$meta")
            path=$(jq -r '.path // empty' "$meta")
            [ -n "$uuid" ] && [ -n "$pk" ] && [ -n "$sid" ] && [ -n "$sni" ] && [ -n "$path" ] || return 1
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, network: xhttp, tls: true${enc_clash}, servername: \"$(_yaml_dq "$sni")\", \"reality-opts\": {public-key: $pk, short-id: $sid, support-x25519mlkem768: true}, \"client-fingerprint\": chrome, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\"}}"
            ;;
        vless-enc)
            # enc 节点必有密钥(创建即生成); metadata 缺 encryption 说明是半套元数据, 不重建
            [ -n "$uuid" ] && [ -n "$enc" ] && [ "$enc" != "none" ] || return 1
            local flow fl=""
            flow=$(jq -r '.flow // empty' "$meta")
            [ -n "$flow" ] && fl=", flow: ${flow}"
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$addr")\", port: $port, udp: true, uuid: $uuid, encryption: \"$(_yaml_dq "$enc")\", network: tcp, tls: false${fl}}"
            ;;
        vless-xhttp-cdn|vless-ws-cdn)
            # CDN 条目指向 CDN 入口(preferred_addr/port), 不是 xray 监听端口(R7/M12 口径)
            local pref_addr pref_port host path
            pref_addr=$(jq -r '.preferred_addr // .host // empty' "$meta")
            pref_port=$(jq -r '.preferred_port // "443"' "$meta")
            host=$(jq -r '.host // empty' "$meta")
            path=$(jq -r '.path // empty' "$meta")
            [ -n "$uuid" ] && [ -n "$host" ] && [ -n "$path" ] && [ -n "$pref_addr" ] || return 1
            [[ "$pref_port" =~ ^[0-9]+$ ]] || pref_port=443
            if [ "$proto" = "vless-xhttp-cdn" ]; then
                printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$pref_addr")\", port: $pref_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": chrome, network: xhttp, \"xhttp-opts\": {path: \"$(_yaml_dq "$path")\", host: \"$(_yaml_dq "$host")\"}}"
            else
                printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: vless, server: \"$(_yaml_dq "$pref_addr")\", port: $pref_port, udp: true, uuid: $uuid, tls: true${enc_clash}, servername: \"$(_yaml_dq "$host")\", \"client-fingerprint\": chrome, network: ws, \"ws-opts\": {path: \"$(_yaml_dq "$path")\", headers: {Host: \"$(_yaml_dq "$host")\"}}}"
            fi
            ;;
        shadowsocks)
            # udp 标志的权威来源是 config 的 settings.network(metadata 未存)
            # net 给默认值: metadata 缺 tag 时(手工编辑/损坏)上一行短路, set -u 下读 $net 会崩溃
            local method password net="" udp_clash=""
            method=$(jq -r '.method // empty' "$meta")
            password=$(jq -r '.password // empty' "$meta")
            [ -n "$method" ] && [ -n "$password" ] || return 1
            local tag; tag=$(jq -r '.tag // empty' "$meta" 2>/dev/null)
            [ -n "$tag" ] && net=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .settings.network // "tcp,udp"' "$CONFIG_FILE" 2>/dev/null)
            [[ "$net" == *"udp"* ]] && udp_clash=", udp: true"
            printf '%s' "- {name: \"$(_yaml_dq "$name")\", type: ss, server: \"$(_yaml_dq "$addr")\", port: $port, cipher: $method, password: \"$(_yaml_dq "$password")\"${udp_clash}}"
            ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 把节点 metadata 的当前状态同步进 clash.yaml 派生缓存(F1 的统一入口)。
# 用法: _sync_node_clash <meta_file> [old_name]
#   old_name 非空且与现名不同(改端口会连带改名)时先删旧行, 避免残留幽灵条目。
# best-effort: builder 失败(被采纳节点缺字段)或文件写失败只告警, 不阻断主流程 ——
# clash.yaml 是可再生派生导出, 权威身份始终是 tag/config/metadata。
# ---------------------------------------------------------------------------
_sync_node_clash() {
    local meta="$1" old_name="${2:-}" line name key
    line=$(_rebuild_clash_line "$meta") || {
        _warn "Clash 条目重建失败(元数据缺少必要字段), clash.yaml 未同步: $meta"
        return 0
    }
    name=$(jq -r '.name // empty' "$meta" 2>/dev/null)
    [ -n "$name" ] || return 0
    if [ -n "$old_name" ] && [ "$old_name" != "$name" ]; then
        _remove_node_from_yaml_by_name "$old_name" 2>/dev/null || \
            _warn "Clash YAML 旧条目删除失败(${old_name}), 可手工编辑 ${CLASH_YAML}"
    fi
    key=$(_yaml_dq "$name")
    if [ -f "$CLASH_YAML" ] && grep -qF "name: \"${key}\"" "$CLASH_YAML" 2>/dev/null; then
        _replace_node_in_yaml "$line" "$name" || \
            _warn "Clash YAML 条目同步失败, 可手工编辑 ${CLASH_YAML}"
    else
        _add_node_to_yaml "$line" "$name" || \
            _warn "Clash YAML 条目追加失败, 可手工编辑 ${CLASH_YAML}"
    fi
    return 0
}

# 重建 vless:// reality 分享链接(从元数据读参数)
# 用法:_rebuild_reality_link <meta_file> [new_sni]  不传 new_sni 则用 meta 里的 sni
# R38(M10): 与 _rebuild_hy2_link 同因 —— 必填字段缺失时必须失败, 不能产出含 null 的坏链接
_rebuild_reality_link() {
    local meta="$1" new_sni="${2:-}"
    local uuid host port proto sni pk sid pqv name path
    uuid=$(jq -r '.uuid // empty' "$meta")
    host=$(jq -r '.link_addr // empty' "$meta")
    port=$(jq -r '.port // empty' "$meta")
    proto=$(jq -r '.protocol // empty' "$meta")
    sni=$(jq -r '.sni // empty' "$meta")
    [ -n "$new_sni" ] && sni="$new_sni"
    pk=$(jq -r '.public_key // empty' "$meta")
    sid=$(jq -r '.short_id // empty' "$meta")
    pqv=$(jq -r '.mldsa65_verify // empty' "$meta")
    name=$(jq -r '.name // empty' "$meta")
    path=$(jq -r '.path // empty' "$meta")
    if [ -z "$uuid" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$sni" ] \
       || [ -z "$pk" ] || [ -z "$sid" ] || [ -z "$name" ]; then
        _error "节点元数据缺少必要字段(uuid/link_addr/port/sni/public_key/short_id/name), 无法重建分享链接: $meta"
        return 1
    fi
    local enc; enc=$(jq -r '.encryption // "none"' "$meta")
    local enc_param
    if [ "$enc" != "none" ] && [ -n "$enc" ]; then
        enc_param=$(_url_encode "$enc")
    else
        enc_param="none"
    fi
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local link
    case "$proto" in
        vless-tcp-reality-vision)
            # 分享链接标准: type=tcp(非 raw)、REALITY 必带 fp 且默认 chrome、sni 需转义
            link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=tcp&flow=xtls-rprx-vision&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}"
            ;;
        vless-xhttp-reality)
            link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_param}&security=reality&type=xhttp&mode=auto&sni=$(_url_encode "$sni")&fp=chrome&pbk=$(_url_encode "$pk")&sid=${sid}&path=$(_url_encode "$path")"
            ;;
        *) echo ""; return 1 ;;
    esac
    [ -n "$pqv" ] && link="${link}&pqv=${pqv}"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 vless-enc:// 分享链接(从元数据读参数)
# 用法:_rebuild_vless_enc_link <meta_file>
_rebuild_vless_enc_link() {
    local meta="$1"
    local uuid host port flow enc name
    uuid=$(jq -r '.uuid' "$meta")
    host=$(jq -r '.link_addr' "$meta")
    port=$(jq -r '.port' "$meta")
    flow=$(jq -r '.flow // empty' "$meta")
    enc=$(jq -r '.encryption // "none"' "$meta")
    name=$(jq -r '.name' "$meta")
    local link_ip="$host"
    [[ "$host" == *":"* && "$host" != *"["* ]] && link_ip="[$host]"
    local enc_encoded; enc_encoded=$(_url_encode "$enc")
    local link="vless://${uuid}@${link_ip}:${port}?encryption=${enc_encoded}&security=none&type=tcp"
    [ -n "$flow" ] && link="${link}&flow=${flow}"
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# 重建 CDN 节点分享链接(从元数据读参数)
# 用法:_rebuild_cdn_link <meta_file>
_rebuild_cdn_link() {
    local meta="$1"
    local uuid host path name proto preferred_addr preferred_port sni fp alpn
    uuid=$(jq -r '.uuid' "$meta")
    host=$(jq -r '.host' "$meta")
    path=$(jq -r '.path // empty' "$meta")
    name=$(jq -r '.name' "$meta")
    proto=$(jq -r '.protocol' "$meta")
    preferred_addr=$(jq -r '.preferred_addr // .host' "$meta")
    preferred_port=$(jq -r '.preferred_port // "443"' "$meta")
    sni=$(jq -r '.sni // .host' "$meta")
    # 分享链接标准: fp 省略默认为 chrome; 旧节点 metadata 曾存 firefox(已废弃), 重建时归一
    fp=$(jq -r '.fp // "chrome"' "$meta")
    [ "$fp" = "firefox" ] && fp="chrome"
    alpn=$(jq -r '.alpn // "h2"' "$meta")
    local enc; enc=$(jq -r '.encryption // "none"' "$meta")
    local enc_param
    if [ "$enc" != "none" ] && [ -n "$enc" ]; then
        enc_param=$(_url_encode "$enc")
    else
        enc_param="none"
    fi
    local link_ip="$preferred_addr"
    [[ "$preferred_addr" == *":"* && "$preferred_addr" != *"["* ]] && link_ip="[$preferred_addr]"
    local link
    case "$proto" in
        vless-xhttp-cdn)
            link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$sni")&fp=${fp}&alpn=${alpn}&type=xhttp&mode=auto&host=$(_url_encode "$host")&path=$(_url_encode "$path")"
            ;;
        vless-ws-cdn)
            link="vless://${uuid}@${link_ip}:${preferred_port}?encryption=${enc_param}&security=tls&sni=$(_url_encode "$sni")&fp=${fp}&type=ws&host=$(_url_encode "$host")&path=$(_url_encode "${path}?ed=2560")"
            ;;
        *) echo ""; return 1 ;;
    esac
    link="${link}#$(_url_encode "$name")"
    echo "$link"
}

# ---------------------------------------------------------------------------
# 模板路径辅助
# ---------------------------------------------------------------------------
_tpl_path() {
    local key="$1"
    case "$key" in
        # R42: Reality 有两套模板 —— tunnel 版 target 指向本地 tunnel 入站, direct 版 target
        # 直指伪装站。键名与文件名一一对应, 不保留"裸协议键"别名: 别名会让漏改的调用点
        # 静默拿到 tunnel 模板(直连节点被渲染成 tunnel 形态), 这类错误在配置提交后才暴露。
        vless-tcp-reality-vision-tunnel) echo "/opt/xray-deploy/templates/vless-tcp-reality-vision-tunnel.server.jsonc" ;;
        vless-tcp-reality-vision-direct) echo "/opt/xray-deploy/templates/vless-tcp-reality-vision-direct.server.jsonc" ;;
        vless-xhttp-reality-tunnel)      echo "/opt/xray-deploy/templates/vless-xhttp-reality-tunnel.server.jsonc" ;;
        vless-xhttp-reality-direct)      echo "/opt/xray-deploy/templates/vless-xhttp-reality-direct.server.jsonc" ;;
        tunnel)                   echo "/opt/xray-deploy/templates/tunnel.server.jsonc" ;;
        vless-enc)                echo "/opt/xray-deploy/templates/vless-enc.server.jsonc" ;;
        vless-xhttp-cdn)          echo "/opt/xray-deploy/templates/vless-xhttp-cdn.server.jsonc" ;;
        vless-ws-cdn)             echo "/opt/xray-deploy/templates/vless-ws-cdn.server.jsonc" ;;
        shadowsocks)              echo "/opt/xray-deploy/templates/shadowsocks.server.jsonc" ;;
        hysteria2)                echo "/opt/xray-deploy/templates/hysteria2.server.jsonc" ;;
    esac
}

# ---------------------------------------------------------------------------
# 查看节点(含监听列 R7)
# ---------------------------------------------------------------------------
_view_nodes() {
    clear
    local count
    count=$(_node_count)
    echo
    echo -e "  ${CYAN}【节点列表】${NC} (共 ${count} 个)"
    if [ "$count" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无节点${NC}"
        _press_any_key; return
    fi
    echo
    printf "  %-3s %-20s %-26s %-8s %-7s %-10s %-16s %-18s\n" "#" "名称" "协议" "模式" "端口" "认证" "监听" "链接地址"
    echo "  ----------------------------------------------------------------------------------------------------------"
    local i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local name proto port auth listen addr tag rmode
        tag=$(basename "$f" .json)
        name=$(jq -r '.name' "$f" 2>/dev/null)
        proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        port=$(jq -r '.port' "$f" 2>/dev/null)
        auth=$(jq -r '.auth // "—"' "$f" 2>/dev/null)
        listen=$(jq -r '.listen' "$f" 2>/dev/null)
        addr=$(jq -r '.link_addr' "$f" 2>/dev/null)
        # R42: Reality 两种拓扑共用同一协议键, 列表必须能区分, 否则用户无从判断该节点
        # 是否带 tunnel(直接影响 target 指向与是否存在路由规则)。独立成列而不是拼在
        # 协议名后: printf 的 %-Ns 按字节而非显示宽度补齐, 拼接会让最长协议键
        # (vless-tcp-reality-vision) 正好吃满字段宽度而挤掉后续列。三种取值
        # (直连/隧道/——)字节数一致, 该列对齐不受多字节影响。
        rmode="——"
        case "$proto" in
            vless-tcp-reality-vision|vless-xhttp-reality)
                if [ "$(_reality_node_mode "$tag")" = "direct" ]; then
                    rmode="直连"
                else
                    rmode="隧道"
                fi
                ;;
        esac
        printf "  %-3s %-20s %-26s %-8s %-7s %-10s %-16s %-18s\n" "[$i]" "${name}" "${proto}" "${rmode}" "${port}" "${auth}" "${listen}" "${addr}"
        i=$((i+1))
    done
    echo
    echo -e "  ${YELLOW}查看某节点分享链接?${NC}"
    read -rp "  输入编号(0 返回): " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice)) n=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        n=$((n+1))
        if [ "$n" -eq "$idx" ]; then
            local name link auth
            name=$(jq -r '.name' "$f"); link=$(jq -r '.share_link' "$f")
            auth=$(jq -r '.auth // "—"' "$f" 2>/dev/null)
            echo
            echo -e "  ${CYAN}【${name}】${NC}"
            [ "$auth" != "—" ] && echo -e "  认证算法: ${auth}"
            # 空/缺失链接: 该节点当前混淆形态无法用官方 hy2 URI 表达(gecko 带尺寸), 或元数据被清过。
            # 说明必须打到 **stdout**(与链接同一通道) —— _warn/_tip 写 stderr, 只捕获 stdout 时
            # 用户看到的是"什么都没有", 与修复前打印空行的观感相同。
            if [ -z "$link" ] || [ "$link" = "null" ]; then
                echo -e "  ${YELLOW}该节点当前无可用分享链接${NC}"
                if _hy2_link_unexpressible "$f"; then
                    echo -e "  ${YELLOW}原因: gecko 使用了自定义分片尺寸(官方 hy2 URI 的 obfs 只表达类型, 无尺寸参数)${NC}"
                    echo -e "  ${YELLOW}请改用 clash/mihomo 条目导入(含 obfs-min/max-packet-size), 见 ${CLASH_YAML}${NC}"
                else
                    echo -e "  ${YELLOW}原因: 节点元数据缺少链接所需字段(可删除后重建, 或用 [采纳孤儿入站] 补回)${NC}"
                fi
            else
                echo -e "  ${GREEN}${link}${NC}"
            fi
            local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
            case "$proto" in *cdn*) _warn "此为 CDN 协议, 禁止直连, 须经 Cloudflare 回源" ;; esac
            break
        fi
    done
    _press_any_key
}

# ---------------------------------------------------------------------------
# 删除节点
# ---------------------------------------------------------------------------
_delete_node() {
    clear
    local count; count=$(_node_count)
    [ "$count" -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【删除节点】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local tag name
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %s\n" "$i" "$name"
        i=$((i+1))
    done
    echo -e "  ${RED}[a]${NC} ${RED}全部删除${NC} | 多选: 逗号分隔(如1,3)"
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择: " choice
    [ "$choice" = "0" ] && return

    # 全部删除(y/N 确认)
    if [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
        echo -e "  ${RED}确认删除全部 ${#tags[@]} 个节点? 此操作不可恢复${NC}"
        read -rp "  继续? [y/N]: " ans
        case "$ans" in
            y|Y) ;;
            *) _info "已取消"; _press_any_key; return ;;
        esac
        # R17: 先清理所有端口跳跃 iptables 规则(teardown 事务)
        # R33(P1): 无条件调用 teardown_all——iptables 不可用但存在 hop 规则时由其内部 fail-closed
        # (不能因 command -v iptables 为假就跳过, 否则删 config/metadata 后留下孤儿 DNAT)
        # R38(P1): teardown_all 现在逐项判定, 无法安全清理的节点进 _HY2_HOP_SKIP 并被保留,
        # 不再因一个损坏节点让"全部删除"整体不可用。
        if ! _hy2_hop_teardown_all "${tags[@]}"; then
            _error "所有节点都无法安全清理端口跳跃规则, 已取消删除(节点未动)"
            _press_any_key; return
        fi
        _hy2_filter_skipped "${tags[@]}"
        local del_all=("${_HY2_DEL_KEEP[@]}")
        if [ ${#del_all[@]} -eq 0 ]; then
            _error "没有可安全删除的节点"
            _press_any_key; return
        fi
        # 自签证书: 只对 metadata 声明 self_signed=true 的节点提示(自定义证书不提示、不删除),
        # 且在节点删除**成功后**才落地删除
        _hy2_ask_purge_self_certs "${del_all[@]}"
        # 无排除项: 沿用原语义(清空 inbounds, 连手工添加的入站一并清掉)
        # 有排除项: 只删可安全删除的 tag(含其 tunnel_tag), 保留被排除节点的入站
        # (M2 同口径: 非对象规则元素保留, 避免 jq 整体报错)
        local all_filter='.inbounds = [] | .routing.rules |= map(select((type != "object") or .inboundTag == null or ((.inboundTag | type) == "array" and (.inboundTag | length) == 0)))'
        local all_ok=0
        if [ ${#_HY2_HOP_SKIP[@]} -eq 0 ]; then
            _mutate_config "$all_filter" && all_ok=1
        else
            local keep_tags=() kt ktt
            for kt in "${del_all[@]}"; do
                keep_tags+=("$kt")
                ktt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${kt}.json" 2>/dev/null)
                [ -n "$ktt" ] && keep_tags+=("$ktt")
            done
            local rm_json
            rm_json=$(printf '%s\n' "${keep_tags[@]}" | jq -R . | jq -c -s .) || rm_json=""
            if [ -z "$rm_json" ]; then
                _error "生成移除集合失败"
                _hy2_hop_restore_after_teardown
                _press_any_key; return
            fi
            _mutate_config --argjson rm "$rm_json" \
                '.inbounds |= map(select((type != "object") or ((.tag // "") as $tg | ($rm | index($tg)) == null)))
                 | .routing.rules |= map(select((type != "object") or .inboundTag == null
                       or ([.inboundTag[]? | . as $it | ($rm | index($it)) == null] | all)))' && all_ok=1
        fi
        if [ "$all_ok" -eq 1 ]; then
            for tag in "${del_all[@]}"; do
                # R38(P1): 先删 metadata 再删 YAML 会读不到 name; 但 YAML 删除失败不阻断,
                # 顺序仍是"先 YAML(读 json 的 name) 后 json"
                _remove_node_from_yaml_by_tag "$tag" || \
                    _warn "Clash YAML 同步删除失败($tag), 可手工编辑 ${CLASH_YAML} 清除该行"
                rm -f "$NODES_DIR/${tag}.json"
            done
            # R18: 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
            _HY2_HOP_TD=()
            # 仅在"确实全删干净"时才截断 clash.yaml; 有保留节点时不能清空
            if [ ${#_HY2_HOP_SKIP[@]} -eq 0 ] && [ -f "$CLASH_YAML" ]; then
                printf 'proxies:\n' > "$CLASH_YAML"
            fi
            _success "已删除 ${#del_all[@]} 个节点"
            _hy2_purge_self_certs
        else
            # config 提交失败(已回滚): 恢复已 teardown 的 hop 规则
            _hy2_hop_restore_after_teardown
            _error "删除失败, 已回滚"
        fi
        _press_any_key; return
    fi

    # 多选删除:逗号分隔(如 1,3,5)
    if [[ "$choice" == *","* ]]; then
        IFS=',' read -ra nums <<< "$choice"
        local del_tags=()
        for n in "${nums[@]}"; do
            n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
            [[ "$n" =~ ^[0-9]+$ ]] || continue
            local di=$((n-1)); local dt="${tags[$di]:-}"
            [ -z "$dt" ] && continue
            # 去重
            local dup=0
            for existing in "${del_tags[@]}"; do [ "$existing" = "$dt" ] && { dup=1; break; }; done
            [ "$dup" -eq 1 ] && continue
            del_tags+=("$dt")
        done
        [ ${#del_tags[@]} -eq 0 ] && { _warn "无效选择"; _press_any_key; return; }

        echo -e "  ${RED}确认删除以下 ${#del_tags[@]} 个节点?${NC}"
        for dt in "${del_tags[@]}"; do
            local dn; dn=$(jq -r '.name' "$NODES_DIR/${dt}.json" 2>/dev/null)
            echo "    - $dn"
        done
        read -rp "  继续? [y/N]: " ans
        case "$ans" in y|Y) ;; *) _info "已取消"; _press_any_key; return ;; esac

        # R17: 先清理端口跳跃 iptables 规则(teardown 事务)
        # R33(P1): 无条件调用 teardown_all——iptables 不可用但存在 hop 规则时由其内部 fail-closed
        # R38(P1): 逐项判定, 无法安全清理的节点被排除而不是整批取消; 删除集合(含 tunnel_tag)
        # 必须在 teardown 之后按剩余项重算, 否则会把被排除节点的入站一起删掉。
        if ! _hy2_hop_teardown_all "${del_tags[@]}"; then
            _error "所选节点都无法安全清理端口跳跃规则, 已取消删除(节点未动)"
            _press_any_key; return
        fi
        _hy2_filter_skipped "${del_tags[@]}"
        del_tags=("${_HY2_DEL_KEEP[@]}")
        if [ ${#del_tags[@]} -eq 0 ]; then
            _error "没有可安全删除的节点"
            _press_any_key; return
        fi
        _hy2_ask_purge_self_certs "${del_tags[@]}"
        local del_ttags=()
        for dt in "${del_tags[@]}"; do
            local dtt; dtt=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${dt}.json" 2>/dev/null)
            [ -n "$dtt" ] && del_ttags+=("$dtt")
        done

        local tun_json='[]'
        [ ${#del_ttags[@]} -gt 0 ] && tun_json=$(printf '%s\n' "${del_ttags[@]}" | jq -R . | jq -s .)
        local all_json; all_json=$(printf '%s\n' "${del_tags[@]}" "${del_ttags[@]}" | jq -R . | jq -s .)

        # M2 同口径: type 守卫防止非对象规则/入站元素让 jq 整体报错。
        # tag 同样需 as 绑定后再 index(index 参数以 $all_tags 为输入求值, 见 _remove_orphan_inbounds 注)
        local jq_multi='.inbounds |= map(select((type != "object") or ((.tag // "") as $tg | ($all_tags | index($tg)) == null)))'
        if [ ${#del_ttags[@]} -gt 0 ]; then
            jq_multi="$jq_multi | .routing.rules |= map(select((type != \"object\") or .inboundTag == null or ((.inboundTag as \$it | \$tun_tags | index(\$it)) == null)))"
        fi

        if _mutate_config --argjson all_tags "$all_json" --argjson tun_tags "$tun_json" "$jq_multi"; then
            # R19: 消费 YAML 删除返回值, 失败则累计并显式告警(不静默; clash.yaml 属派生导出)
            local yaml_fail=0
            for dt in "${del_tags[@]}"; do
                # R18: 先删 YAML(需读 json 的 name)再删 json, 否则幽灵节点残留在 clash.yaml
                _remove_node_from_yaml_by_tag "$dt" || yaml_fail=1
                rm -f "$NODES_DIR/${dt}.json"
            done
            # R38(P1): 不再指向不存在的"重新生成 Clash 配置"功能, 给出真实可执行的路径
            [ "$yaml_fail" -eq 1 ] && \
                _warn "部分节点 Clash YAML 同步删除失败, 已从 Xray 删除; 可手工编辑 ${CLASH_YAML} 删除对应行"
            # R18: 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
            _HY2_HOP_TD=()
            _success "已删除 ${#del_tags[@]} 个节点"
            _hy2_purge_self_certs
        else
            # config 提交失败(已回滚): 恢复已 teardown 的 hop 规则
            _hy2_hop_restore_after_teardown
            _error "删除失败, 已回滚"
        fi
        _press_any_key; return
    fi

    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    # 读取 tunnel_tag, 一次性删除 tunnel + reality + 路由(原子操作)
    # M2 同口径: type 守卫防止非对象入站/规则元素让 jq 整体报错(手改 config 时删除被拒绝服务)
    local tunnel_tag
    tunnel_tag=$(jq -r '.tunnel_tag // empty' "$NODES_DIR/${tag}.json" 2>/dev/null)
    local jq_filter='.inbounds |= map(select((type != "object") or ((.tag // "") != $t)))'
    if [ -n "$tunnel_tag" ]; then
        jq_filter="$jq_filter | .routing.rules |= map(select((type != \"object\") or .inboundTag == null or ((.inboundTag | index(\$tg)) == null)))
            | .inbounds |= map(select((type != \"object\") or ((.tag // \"\") != \$tg)))"
    fi
    # R17: 先清理端口跳跃规则(teardown 事务; 失败则取消删除, 节点整体保持原状)
    # R30(P1): fail-closed——metadata 损坏/缺 protocol 不能当"非 HY2"跳过 teardown,
    # 否则删节点后 hop DNAT 永久残留(孤儿防火墙规则)
    local proto hop_port ranges=""
    if ! proto=$(_node_protocol_safe "$tag"); then
        _press_any_key; return
    fi
    if [ "$proto" = "hysteria2" ]; then
        # R31(P1): hop 范围字段存在但无法解析 → 拒绝删除(不当作"无 hop"跳过 teardown)
        _hy2_hop_meta_ok "$tag" || { _press_any_key; return; }
        ranges=$(_read_hop_ranges "$NODES_DIR/${tag}.json")
        if [ -n "$ranges" ]; then
            # R33(P1): 存在 hop 规则但 iptables 不可用 → 无法安全删除(否则删 config/metadata
            # 留孤儿 DNAT, 且 metadata 已删后无法追溯 dport 归属)
            if ! command -v iptables >/dev/null 2>&1; then
                _error "节点存在端口跳跃规则, 但 iptables 不可用, 无法安全删除: $tag"
                _press_any_key; return
            fi
            if ! hop_port=$(jq -r '.port // empty' "$NODES_DIR/${tag}.json" 2>/dev/null); then
                _error "节点元数据损坏, 无法确认端口: $tag"
                _press_any_key; return
            fi
            [[ "$hop_port" =~ ^[0-9]+$ ]] || {
                _error "节点元数据损坏(端口无效): $tag"
                _press_any_key; return
            }
            # R31(P1): metadata.port 必须与 config 真实监听端口一致——否则 teardown 用错误目标
            # 端口找不到(或误删)DNAT 规则, 留下 :<真实端口> 的孤儿规则。
            # 仅当 config 存在该 inbound 时强制(真实删除流 inbound 必在 config; config 已无该
            # inbound 说明已是孤儿/外部删除, metadata.port 仍是当初 add 用的正确清理目标)。
            local cfg_port
            cfg_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port // empty' "$CONFIG_FILE" 2>/dev/null)
            if [ -n "$cfg_port" ] && [ "$cfg_port" != "$hop_port" ]; then
                _error "节点元数据端口($hop_port)与 config 监听端口($cfg_port)不一致, 无法安全删除: $tag"
                _press_any_key; return
            fi
            _info "清理端口跳跃规则..."
            # shellcheck disable=SC2086
            if ! _hy2_hop_teardown "$hop_port" $ranges; then
                _error "端口跳跃规则清理失败, 已取消删除(节点未动)"
                _press_any_key; return
            fi
        fi
    fi
    _hy2_ask_purge_self_certs "$tag"
    if _mutate_config --arg t "$tag" --arg tg "$tunnel_tag" "$jq_filter"; then
        # R18: 先删 YAML(需读 json 的 name)再删 json, 否则幽灵节点残留在 clash.yaml
        # R19: 消费 YAML 删除返回值——失败不静默(权威删除已完成, clash.yaml 属派生导出)
        # R38(P1): 不再指向不存在的"重新生成 Clash 配置"功能, 给出真实可执行的处置路径
        if ! _remove_node_from_yaml_by_tag "$tag"; then
            _warn "Clash YAML 同步删除失败($tag), 节点已从 Xray 删除; 可手工编辑 ${CLASH_YAML} 删除对应行"
        fi
        rm -f "$NODES_DIR/${tag}.json"
        # R18: 删除事务已完整提交, 清空 teardown 记录, 避免跨事务污染
        _HY2_HOP_TD=()
        _success "节点已删除"
        _hy2_purge_self_certs
    else
        # config 提交失败(已回滚): 恢复已清理的 hop 规则
        # R38(P1): 原写法 `[ -n "$ranges" ] && A || _error` 在 ranges 为空时(任何非 hy2 /
        # 无 hop 的节点)必然执行 _error, 于是删除普通 VLESS 节点失败时会额外报一条
        # "恢复端口跳跃规则失败, 请手动检查 iptables" —— 用户会去翻根本不存在的规则。
        if [ -n "$ranges" ]; then
            # shellcheck disable=SC2086
            _hy2_hop_reverse remove "$hop_port" $ranges 2>/dev/null || \
                _error "恢复端口跳跃规则失败, 请手动检查 iptables"
        fi
        _error "删除失败, 已回滚"
    fi
    _press_any_key
}

# 改端口的 Reality 事务(R41)。**整个事务在 _with_config_lock 内** —— 与 _port_txn /
# _hy2_port_txn 同一锁域: Reality 改的是 metadata 文件名 + 内容 + config(tag/port/tunnel
# tag/routing), 且与另两条路径共用 <old_path>.porttxn, 不锁会让并发会话互相覆盖/删除
# 对方的 journal(进而让崩溃恢复本身失效)。
_reality_port_txn() {
    _with_config_lock _reality_port_txn_locked "$@"
}
_reality_port_txn_locked() {
    local tag="$1" meta="$2" oldport="$3" newport="$4"
    # R42: 先经唯一入口判模式。direct 模式无 tunnel/路由需要同步, tunnel_tag 保持空,
    # 下面的事务天然退化为"只处理主入站"(new_tunnel_tag 与 jq 的 tunnel 段都受 -n 保护);
    # 绝不能让 direct 节点走 tunnel 分支的 fail-closed —— 那会把它永久锁成不能改端口。
    local tunnel_tag="" tunnel_port sni trc rmode
    rmode=$(_reality_node_mode "$tag")
    if [ "$rmode" = "tunnel" ]; then
        # 旧版/手动创建节点可能缺 tunnel_tag —— 从 config 关联推导(R26/R28)。
        # R41(P1): fail-closed —— 推导失败(rc=1)或歧义(rc=2)一律拒绝改端口, 否则
        # 只改主 tag 而 tunnel/路由未改, 重新制造 R41 要消灭的不一致。
        tunnel_tag=$(jq -r '.tunnel_tag // empty' "$meta" 2>/dev/null)
        tunnel_port=$(jq -r '.tunnel_port // empty' "$meta" 2>/dev/null)
        sni=$(jq -r '.sni // empty' "$meta" 2>/dev/null)
        if [ -z "$tunnel_tag" ]; then
            tunnel_tag=$(_find_reality_tunnel_tag "$tag"); trc=$?
            if [ "$trc" != "0" ]; then
                _error "无法唯一关联 Reality tunnel (rc=${trc}), 无法安全修改端口: $tag"
                _tip "请检查 config.json 的 realitySettings.target 与 tunnel 入站, 或删除后重建节点"
                return 1
            fi
        else
            # R41: metadata 有 tunnel_tag 也不能盲目信任 —— 外部修改/损坏 metadata 后
            # 可能与 config 不一致。此处验证该 tag 在 config 中真实存在且为 tunnel 入站,
            # 否则 fail-closed(避免 tunnel/路由漏改)。无 tunnel_tag 的节点走上面的
            # _find_reality_tunnel_tag 推导, 推导失败/歧义同样 fail-closed, 绝不进入
            # "仅改端口"的通用路径(R41 的全部 tunnel 模式分支都是 fail-closed)。
            if ! jq -e --arg tg "$tunnel_tag" \
                '[.inbounds[] | select(.tag == $tg and .protocol == "tunnel")] | length > 0' \
                "$CONFIG_FILE" >/dev/null 2>&1; then
                _error "metadata 记录的 tunnel_tag (${tunnel_tag}) 在 config 中不存在, 无法安全修改端口"
                _tip "请检查 config.json 或使用 [采纳孤儿入站] 修复元数据"
                return 1
            fi
        fi
    fi

    # 主 tag 前缀(xd-reality-vision / xd-reality-xhttp) + 新端口
    local new_tag="${tag%-*}-${newport}"
    # 新 tunnel tag: 仅替换末段 reality 端口(Tunnel-<sni>-<tport>-<port>);
    # 保持 SNI 段原样(含旧版无长度封顶产生的超长 SNI 段, 不做二次截断)
    local new_tunnel_tag=""
    if [ -n "$tunnel_tag" ]; then
        new_tunnel_tag="${tunnel_tag%-*}-${newport}"
    fi

    # R41(P2): 新 tag 冲突检查 —— 目标元数据文件已存在说明该端口/标签被其他节点占用,
    # mv 会静默覆盖。不依赖 _input_port 的上游间接保证, 这里显式校验。
    if [ -e "$NODES_DIR/${new_tag}.json" ]; then
        _error "目标标签 ${new_tag} 已存在(端口 ${newport} 可能已被其他节点使用), 请换一个端口"
        return 1
    fi

    # 在内存生成完整新 metadata(port/tag/tunnel_tag/reality_mode/name/share_link), 未落地任何文件。
    # _rebuild_reality_link 从文件读, 故用临时文件承载"新 port + 新 name"再重建,
    # 使链接 #fragment 也同步为新名(与 _hy2_gen_port_newmeta 同思路)。
    local tmpm newmeta newlink old_name new_name
    tmpm=$(mktemp "${meta}.port.XXXXXX") || { _error "创建临时文件失败"; return 1; }
    old_name=$(jq -r '.name' "$meta")
    # F8: 仅替换 "-<oldport>" 后缀, 全局子串替换会破坏名称中含端口号的其他数字
    new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")
    # R42: 顺带回填 reality_mode —— 旧节点(无该字段)改端口后元数据自描述, 不再依赖推导
    if ! jq --argjson p "$newport" --arg nt "$new_tag" --arg ntg "$new_tunnel_tag" \
        --arg nn "$new_name" --arg rm "$rmode" \
        '.port=$p | .tag=$nt | (if $ntg != "" then .tunnel_tag=$ntg else . end) | .name=$nn | .reality_mode=$rm' \
        "$meta" > "$tmpm"; then
        rm -f "$tmpm"; _error "生成元数据失败"; return 1
    fi
    if ! newlink=$(_rebuild_reality_link "$tmpm") || [ -z "$newlink" ]; then
        rm -f "$tmpm"
        _warn "分享链接重建失败(元数据缺少必要字段), 端口未修改"
        _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
        return 1
    fi
    if ! newmeta=$(jq --arg l "$newlink" '.share_link=$l' "$tmpm") || [ -z "$newmeta" ]; then
        rm -f "$tmpm"; _error "生成元数据失败"; return 1
    fi
    rm -f "$tmpm"

    # ---- 统一事务(对齐 _hy2_port_txn): journal → 重命名+提交 metadata → 提交 config ----
    # journal 必须先于 mv 落盘: mv 是第一个被改动的真实状态, 崩溃残局是"文件名已改 /
    # config 未改"甚至"文件名+内容已改 / config 未改"(P1-B), 由 _port_txn_recover 依据
    # config 是否已出现 (new_tag, newport) 判定补完或回滚(回滚 = 反向 mv + 写回 old)。
    local orig journal rrok
    journal="$NODES_DIR/${tag}.json.porttxn"
    orig=$(cat "$meta" 2>/dev/null) || { _error "读取元数据失败"; return 1; }
    if ! _port_txn_journal_write "$NODES_DIR/${tag}.json" "$NODES_DIR/${new_tag}.json" \
            reality "$oldport" "$newport" "" "$orig" "$newmeta"; then
        _error "端口事务 journal 写入失败, 未做任何修改"
        return 1
    fi

    # 1. 主 tag 即元数据文件名 —— 先重命名(config 未动, 失败干净中止)
    if ! mv "$NODES_DIR/${tag}.json" "$NODES_DIR/${new_tag}.json"; then
        _error "节点元数据文件重命名失败(${tag}.json → ${new_tag}.json), 未做任何修改"
        rm -f "$journal"
        return 1
    fi
    meta="$NODES_DIR/${new_tag}.json"

    # 2. 原子提交新 metadata; 失败时反向 mv 恢复文件名(此时新文件仍是原内容), config 未动
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 恢复原文件名..."
        rrok=0
        mv -f "$NODES_DIR/${new_tag}.json" "$NODES_DIR/${tag}.json" 2>/dev/null || \
            { _error "元数据文件名恢复失败, 请手动检查 ${NODES_DIR}"; rrok=1; }
        # 反向 mv 成功才删 journal; 失败保留, 启动期恢复会按"config 未提交"收敛
        if [ "$rrok" = 0 ]; then rm -f "$journal"; else _error "保留 journal 待启动恢复: $journal"; fi
        return 1
    fi

    # 3. 最后提交 config(改端口 + 重命名主 tag + tunnel tag + 路由规则引用)。
    #    _mutate_config 失败会自行恢复旧 config 并重启回旧端口; 这里同步回滚 metadata。
    local jq_filter
    jq_filter='(.inbounds[] | select(.tag == $t) | .tag) = $new_t
| (.inbounds[] | select(.tag == $new_t) | .port) = $p'
    if [ -n "$tunnel_tag" ]; then
        jq_filter="$jq_filter
| (.inbounds[] | select(.tag == \$tg) | .tag) = \$new_tg
| .routing.rules |= map(
    if .inboundTag != null and (.inboundTag | type) == \"array\"
    then .inboundTag |= map(if . == \$tg then \$new_tg else . end)
    else . end)"
    fi
    if ! _mutate_config --arg t "$tag" --arg new_t "$new_tag" --argjson p "$newport" \
         --arg tg "$tunnel_tag" --arg new_tg "$new_tunnel_tag" "$jq_filter"; then
        _error "端口配置提交失败, 回滚元数据到旧文件名与旧内容..."
        rrok=0
        rm -f "$NODES_DIR/${new_tag}.json" 2>/dev/null
        _atomic_write_json "$NODES_DIR/${tag}.json" "$orig" || \
            { _error "元数据回滚失败, 请手动检查 ${NODES_DIR}/${tag}.json"; rrok=1; }
        # 文件名与内容都回到旧态才删 journal; 否则保留, 启动期恢复按"config 未提交"收敛
        if [ "$rrok" = 0 ]; then rm -f "$journal"; else _error "保留 journal 待启动恢复: $journal"; fi
        return 1
    fi
    rm -f "$journal"

    if [ "$rmode" = "tunnel" ]; then
        _success "端口已改为 ${newport}(标签与 tunnel 标签已同步更新)"
    else
        _success "端口已改为 ${newport}(直连模式, 标签已同步更新)"
    fi
    # F1: config/metadata 已一致, 同步 clash 派生缓存(端口与名称都可能已变)
    _sync_node_clash "$meta" "$old_name"
}

# ---------------------------------------------------------------------------
# 非 hop 端口修改的统一事务(与 _hy2_port_txn / Reality 分支同模型)。
# 调用方已在内存生成完整 newmeta(port + name + share_link), 事务内只做两步提交:
#   1. 原子提交 metadata —— 失败干净中止, config 未动;
#   2. 提交 config(_mutate_config 自带 verified-restart 与失败回滚); 失败则回滚 metadata。
# **顺序不可交换**: 先 config 后 metadata 会在 metadata 写失败时留下 "config 新端口 /
# metadata 旧端口" 的分裂(节点列表、链接、删除定位全按 metadata 走, 而服务实际监听新端口)。
#
# **并发**: 整个事务(快照 → journal → metadata → config → 回滚)都在 _with_config_lock
# 内。只锁 _mutate_config 是不够的 —— 失败事务的 "回滚 metadata" 会覆盖另一会话已经
# 提交的新 metadata(lost update), 留下 config=T2 / metadata=旧 的分裂。
# _with_config_lock 经 XRAY_DEPLOY_LOCK_HELD 可重入, 故内部 _mutate_config 不会自锁死。
#
# **崩溃一致性**: 单靠函数返回码只能覆盖"错误返回"路径; 进程在 metadata 已提交、config
# 未提交之间被杀(断电 / OOM / kill -9)时没有任何函数会被调用。故事务前先落一份 journal
# (`<meta>.porttxn`, **非 .json 后缀** —— 节点目录所有扫描都是 *.json 通配, 用 .json
# 后缀会让它被当成一个节点), 启动期由 _port_txn_recover 依据 config 的真实端口决定
# "补完"还是"回滚", 不会永久停在 config 旧 / metadata 新的分裂。
# **三条端口路径同一模型**: port(本函数) / hy2hop(_hy2_port_txn) / reality
# (_reality_port_txn) 都写同一份 journal、都在 _with_config_lock 内、都由 _port_txn_recover
# 收敛(第三参与方 iptables DNAT / tag 重命名由 kind 区分处理)。
# 用法: _port_txn <tag> <meta_file> <newport> <newmeta_json>
# 返回: 0 全部成功; 1 失败(metadata 已回滚到旧内容)
# ---------------------------------------------------------------------------
_port_txn() {
    _with_config_lock _port_txn_locked "$@"
}

# 端口事务 journal 的唯一写入入口(port / hy2hop / reality 三条路径共用, 防止三份 payload 漂移)。
# journal 路径固定 \`${old_path}.porttxn\` —— **必须非 .json 后缀**(节点目录所有扫描都是
# *.json 通配, 用 .json 会被当成一个节点)。payload 自带 old/new 全文与两侧路径, 恢复时不需要
# 再推算, 也不依赖 newmeta 还能重建; tag/newtag 从 old/new 的 .tag 派生(三类 metadata 都带 tag)。
# 返回非 0 ⇒ 调用方必须**立即中止**, 不得继续改动任何真实文件。
_port_txn_journal_write() {  # <old_path> <new_path> <kind> <oldport> <newport> <ranges> <old_json> <new_json>
    local old_path="$1" new_path="$2" kind="$3" oldport="$4" newport="$5" ranges="$6" old_json="$7" new_json="$8"
    local payload
    payload=$(jq -n --arg kind "$kind" --argjson op "$oldport" --argjson np "$newport" \
        --arg opath "$old_path" --arg npath "$new_path" --arg ranges "$ranges" \
        --argjson old "$old_json" --argjson new "$new_json" \
        '{kind:$kind, tag:($old.tag // ""), newtag:($new.tag // ""), oldport:$op, newport:$np,
          old_path:$opath, new_path:$npath, ranges:$ranges, old:$old, new:$new}') || return 1
    _atomic_write_json "${old_path}.porttxn" "$payload"
}

_port_txn_locked() {
    local tag="$1" meta="$2" newport="$3" newmeta="$4" orig oldport journal
    journal="${meta}.porttxn"
    orig=$(cat "$meta" 2>/dev/null) || { _error "读取元数据失败: $meta"; return 1; }
    [ -n "$orig" ] || { _error "元数据为空, 放弃端口修改: $meta"; return 1; }
    oldport=$(jq -r '.port // empty' <<< "$orig" 2>/dev/null)
    # 1. journal: 先于任何真实状态改动落盘
    if ! _port_txn_journal_write "$meta" "$meta" port "$oldport" "$newport" "" "$orig" "$newmeta"; then
        _error "端口事务 journal 写入失败, 未做任何修改"
        return 1
    fi
    # 2. 原子提交 metadata
    if ! _atomic_write_json "$meta" "$newmeta"; then
        _error "端口元数据提交失败, 未做任何修改"
        rm -f "$journal"
        return 1
    fi
    # 3. 提交 config
    if ! _mutate_config --arg t "$tag" --argjson p "$newport" \
         '(.inbounds[] | select(.tag == $t) | .port) = $p'; then
        _error "端口配置提交失败, 回滚元数据到旧端口..."
        # 回滚完整才删 journal; 回滚失败保留它, 让启动期恢复收敛(恢复路径幂等)
        if _atomic_write_json "$meta" "$orig"; then
            rm -f "$journal"
        else
            _error "元数据回滚失败, 保留 journal 待启动恢复: $journal"
        fi
        return 1
    fi
    rm -f "$journal"
    return 0
}

# ---------------------------------------------------------------------------
# iptables 可用性判据(单独成函数, 便于测试注入; 恢复的 hop 修复需要它)
_hy2_hop_available() { command -v iptables >/dev/null 2>&1; }

# 启动期恢复: 处理上次被中断的端口事务(journal 还在 ⇒ 事务没走完)。
# **整个恢复在 _with_config_lock 内** —— 与 _port_txn 同锁域, 否则一个正在执行的端口事务
# 会与启动恢复并发写同一份 metadata(启动 TUI 通常单实例, 但一致性上不能留这个缺口)。
#
# 三类 journal(kind)统一处理, 判据都是 **config 的真实状态**(权威 = 服务实际在跑的配置),
# 不是"猜哪一步失败了":
#   port / hy2hop: config 里该 tag 的端口 == newport            ⇒ config 已提交
#   reality:       config 里已出现 (newtag, newport) 这个入站    ⇒ config 已提交
# 已提交 ⇒ 把 metadata 收敛到 new_path + new 内容; 否则收敛到 old_path + old 内容。
# hy2hop 的 DNAT 在 config 之前就被改到新端口, 故回滚分支必须同步 retarget 回旧端口
# (retarget 的 remove/add 均带存在性检查, 幂等可重入; iptables 不可用时保留 journal 待下次)。
#
# **事务身份校验(P2)**: 收敛前先确认 metadata 当前内容语义上等于 journal 的 old 或 new。
# 若两者都不是, 说明崩溃后 metadata 又被外部改过 —— 此时**不自动处理**(保留 journal 与现场),
# 避免用 journal.new 覆盖用户后来的修改。仅凭 "config 端口 == newport" 不足以证明
# "config 就是本 journal 那次提交产生的"。
#
# **journal 用 .porttxn 后缀而非 .json** —— 节点目录的所有扫描都是 *.json 通配, .json 后缀
# 会让它被当成一个节点参与列表/删除/采纳。
# 幂等、静默(至多一条 _info), 与其它启动自动操作同级。
# ---------------------------------------------------------------------------
# journal 隔离: **绝不删除**(只读 fs / 权限 / I-O 异常时 mv 也会失败 —— 那恰恰是最该保住
# 证据的场景, 保留原文件并告警)。改名后不再被 *.porttxn 扫到 ⇒ 幂等, 不会每次启动反复告警。
# 用法: _ptx_journal_quarantine <journal> <原因>
_ptx_journal_quarantine() {
    local j="$1" why="$2" dest i
    # 不覆盖既有 .corrupt 证据: 依次找第一个空位(.corrupt / .corrupt.1 / … / .corrupt.9)。
    # 恢复在 config 锁内执行, 不存在并发竞争; 全被占满则保留原文件(仍不删)。
    dest=""
    for i in "" .1 .2 .3 .4 .5 .6 .7 .8 .9; do
        [ -e "${j}.corrupt${i}" ] || { dest="${j}.corrupt${i}"; break; }
    done
    if [ -n "$dest" ] && mv -f "$j" "$dest" 2>/dev/null; then
        _warn "端口事务 journal ${why}, 已隔离为 ${dest##*/} 待人工核对: $j"
    else
        _warn "端口事务 journal ${why}, 且隔离失败, 原文件保留待人工核对(未删除): $j"
    fi
}

# journal 的 **schema 校验**(fail-closed): 合法 JSON 不等于合法事务记录。
# 正常 journal 只由 _port_txn_journal_write 生成, 故这里可以严格; 任何不满足者都不得被
# 自动恢复(尤其**未知 kind 绝不能按 port 处理**)。校验: kind 枚举 / 各 kind 的必填字段与
# 取值(端口范围、ranges 语法) / old·new 必须是 object / tag 与 old.tag、newtag 与 new.tag
# 必须一致(否则身份校验与收敛会基于错位的数据)。
# 用法: _ptx_journal_ok <journal>; 0=合法
_ptx_journal_ok() {
    jq -e '
      def port_ok: (type == "number") and (. >= 1) and (. <= 65535) and (. == floor);
      def ranges_ok:
        (type == "string") and (. == "")
        # 分隔符集必须与下面 splits() 及各路径的**实际写入口径**一致: _read_hop_ranges 把
        # metadata 的 hop_ranges 规范化成 "20000:30000 40000:50000"(逗号转空格、连字符转冒号),
        # _hy2_port_txn_locked 再以 ranges="$*" 逐词透传 ⇒ journal 里是**空格**分隔。
        # 原正则只认逗号, 于是多段跳跃节点的 journal 一律判 schema 不合法被隔离, 崩溃恢复
        # 静默失效(config 旧 / metadata 新 / DNAT 新 三方永久分裂)。空格与逗号在此都合法:
        # 逗号是 metadata 的存储形态, 空格是 _read_hop_ranges 的规范形态。
        or ((test("^[0-9]{1,5}(:[0-9]{1,5})?([,[:space:]]+[0-9]{1,5}(:[0-9]{1,5})?)*$"))
            and ([ splits("[,\\s]+") ] | map(select(length > 0)) | length > 0)
            and ([ splits("[,\\s]+") | select(length > 0) |
                   if test(":") then
                     (split(":") | (.[0]|tonumber) >= 1 and (.[0]|tonumber) <= 65535
                                 and (.[1]|tonumber) >= 1 and (.[1]|tonumber) <= 65535
                                 and (.[0]|tonumber) <= (.[1]|tonumber))
                   else ((tonumber) >= 1 and (tonumber) <= 65535) end ] | all));
      (.kind as $k
       | ($k == "port" or $k == "hy2hop" or $k == "reality")
       and (.tag | type == "string" and length > 0)
       and (.newtag | type == "string" and length > 0)
       and (.newport | port_ok)
       and (.oldport | port_ok)
       and (.old | type == "object")
       and (.new | type == "object")
       and (.old.tag == .tag)
       and (.new.tag == .newtag)
       # 四元组必须自洽: 恢复是把整份 old/new 写回 metadata, 若 old.port 与 oldport 打架,
       # 会写出 config.port 与 metadata.port 互相矛盾的残局 ⇒ 一并校验(含取值合法性)。
       and (.old.port | port_ok)
       and (.new.port | port_ok)
       and (.old.port == .oldport)
       and (.new.port == .newport)
       and (.old_path | type == "string" and length > 0)
       and (.new_path | type == "string" and length > 0)
       and (.ranges | ranges_ok)
       and (if $k == "hy2hop" then (.ranges | length > 0) else (.ranges == "") end)
       and (if $k == "reality" then .old_path != .new_path else .old_path == .new_path end))
    ' "$1" >/dev/null 2>&1
}

_port_txn_recover() {
    _with_config_lock _port_txn_recover_locked
}

_port_txn_recover_locked() {
    [ -d "$NODES_DIR" ] || return 0
    local j kind tag newtag oldport newport old_path new_path ranges
    local cfg_tag committed cur_path p cur_canon old_canon new_canon tgt_path tgt_obj
    for j in "$NODES_DIR"/*.porttxn; do
        [ -f "$j" ] || continue
        # 1) 必须是可解析的 JSON
        if ! jq -e . "$j" >/dev/null 2>&1; then
            _ptx_journal_quarantine "$j" "无法解析"
            continue
        fi
        # 2) 必须是**合法事务记录**, 而不仅是合法 JSON: kind 枚举 + 按 kind 的字段/取值/结构校验
        #    (含 tag 与 old/new.tag 的一致性)。缺字段、未知 kind、越界端口、非法 ranges、old/new
        #    非 object —— 一律 fail-closed: 隔离, **不**自动恢复(未知类型绝不当成 port 处理)。
        if ! _ptx_journal_ok "$j"; then
            _ptx_journal_quarantine "$j" "schema 不合法(kind/字段/取值/结构)"
            continue
        fi
        kind=$(jq -r '.kind' "$j" 2>/dev/null)
        tag=$(jq -r '.tag' "$j" 2>/dev/null)
        newtag=$(jq -r '.newtag' "$j" 2>/dev/null)
        oldport=$(jq -r '.oldport' "$j" 2>/dev/null)
        newport=$(jq -r '.newport' "$j" 2>/dev/null)
        old_path=$(jq -r '.old_path' "$j" 2>/dev/null)
        new_path=$(jq -r '.new_path' "$j" 2>/dev/null)
        ranges=$(jq -r '.ranges // ""' "$j" 2>/dev/null)

        # (a) config 侧判据: 本事务的目标状态(tag + 端口)是否已在 config 里
        cfg_tag="$tag"
        [ "$kind" = "reality" ] && cfg_tag="$newtag"
        committed=0
        if [ -f "$CONFIG_FILE" ]; then
            [ "$(jq -r --arg t "$cfg_tag" --argjson p "$newport" \
                '[.inbounds[]? | select(.tag == $t and .port == $p)] | length > 0' \
                "$CONFIG_FILE" 2>/dev/null)" = "true" ] && committed=1
        fi

        # (b) 定位 metadata 当前文件(旧名优先), 并做事务身份校验
        cur_path=""
        for p in "$old_path" "$new_path"; do
            [ -f "$p" ] && { cur_path="$p"; break; }
        done
        if [ -z "$cur_path" ]; then
            # 两个候选路径都没有元数据 —— 说不清的现场, 与其它非法 journal 同策: 隔离而非删除
            _ptx_journal_quarantine "$j" "对应的元数据文件已不存在"
            continue
        fi
        cur_canon=$(jq -S . "$cur_path" 2>/dev/null)
        old_canon=$(jq -S '.old' "$j" 2>/dev/null)
        new_canon=$(jq -S '.new' "$j" 2>/dev/null)
        if [ "$cur_canon" != "$old_canon" ] && [ "$cur_canon" != "$new_canon" ]; then
            _warn "端口事务 journal 残留, 但 metadata 已被外部修改, 不自动处理(请人工核对): $cur_path"
            continue
        fi
        # 事务身份校验(P2): 三条路径的提交顺序都是 **metadata 先、config 后** ⇒
        # "config 已是目标态而 metadata 仍停在 old" 这个组合**不可能由本事务产生**,
        # 只能是外部干预(例如崩溃后有人手工把 config 改成目标端口)。仅凭
        # "config 端口 == newport" 无法证明 config 就是本 journal 那次提交的结果,
        # 故这里按外部干预处理: 不覆盖 metadata, 保留 journal 与现场。
        if [ "$committed" = 1 ] && [ "$cur_canon" = "$old_canon" ]; then
            _warn "端口事务 journal 残留: config 已在目标态而 metadata 仍是旧态(本事务不可能产生), 不自动处理(请人工核对): $cur_path"
            continue
        fi

        # (c) 收敛到目标态: 必要时先改文件名(Reality 的 tag 改名), 再原子写内容
        if [ "$committed" = 1 ]; then tgt_path="$new_path"; tgt_obj=".new"; else tgt_path="$old_path"; tgt_obj=".old"; fi
        if [ "$cur_path" != "$tgt_path" ]; then
            # 目标路径已存在 ⇒ **不是**本事务的正常残局: 需要改名的只有 Reality, 而它的正常残局
            # 里目标(旧名或新名)必然不存在(cur_path 已优先取到存在的那个)。目标却存在, 说明
            # 崩溃后有外部重建/替换 ⇒ 绝不覆盖, 保留 journal 转人工。
            if [ -e "$tgt_path" ]; then
                _warn "端口事务恢复的目标文件已存在(疑似外部重建), 不覆盖, 保留 journal 待人工核对: $tgt_path"
                continue
            fi
            # mv -n: 即便在"检查"与"改名"之间被塞进目标文件也不覆盖(-n 不可用时报错 ⇒ 走失败
            # 分支保留 journal, 仍不丢数据)。改名后源路径消失, 故下面统一对 tgt_path 写内容。
            if ! mv -n "$cur_path" "$tgt_path" 2>/dev/null; then
                _warn "端口事务恢复的元数据重命名失败, 保留 journal: $j"
                continue
            fi
            # mv -n 在"目标已存在"时可能静默不动作却返回 0 ⇒ 事后核验源路径确实消失,
            # 否则视为未生效(有竞态插入), 保留 journal 而不是继续写目标文件
            if [ -e "$cur_path" ]; then
                _warn "端口事务恢复的元数据重命名未生效(目标已存在?), 不覆盖, 保留 journal: $tgt_path"
                continue
            fi
        fi
        if ! _atomic_write_json "$tgt_path" "$(jq "$tgt_obj" "$j" 2>/dev/null)"; then
            _warn "端口事务恢复的元数据写回失败, 保留 journal: $j"
            continue
        fi

        # (d) hy2hop 回滚分支: DNAT 已被改到新端口, 必须一并 retarget 回旧端口
        if [ "$kind" = "hy2hop" ] && [ "$committed" = 0 ] && [ -n "$ranges" ]; then
            if ! _hy2_hop_available; then
                _warn "端口跳跃规则需 iptables 修复, 保留 journal 待下次启动: $j"
                continue
            fi
            # shellcheck disable=SC2086
            if ! _hy2_hop_retarget "$newport" "$oldport" $ranges; then
                _warn "端口跳跃规则回滚失败, 保留 journal: $j"
                continue
            fi
        fi

        rm -f "$j"
        if [ "$committed" = 1 ]; then
            _info "已补完上次中断的端口修改: ${tgt_path##*/} (端口 ${newport})"
        else
            _info "已回滚上次中断的端口修改: ${tgt_path##*/} (config 未提交该事务)"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# 修改端口(沿用思路, 适配新元数据)
# ---------------------------------------------------------------------------
_modify_port() {
    clear
    local count; count=$(_node_count)
    [ "$count" -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【修改端口】${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local tag name port
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); port=$(jq -r '.port' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 当前端口 %s\n" "$i" "$name" "$port"
        i=$((i+1))
    done
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择: " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local newport=$(_input_port)

    # 更新元数据 + 链接(端口出现在链接里)
    local meta="$NODES_DIR/${tag}.json"
    local oldport; oldport=$(jq -r '.port' "$meta")
    local proto; proto=$(jq -r '.protocol' "$meta" 2>/dev/null)

    # R41: 端口未变化时直接返回, 避免无意义重启; 也防止 Reality 分支对同名元数据文件 mv(同文件错误)
    [ "$newport" = "$oldport" ] && { _info "端口未变化"; _press_any_key; return; }

    # hy2 + 端口跳跃: 走统一端口事务(_hy2_port_txn), 避免 config/metadata 先提交、iptables 后失败
    # 造成 config/metadata/iptables 三方分叉(R16); 任一步失败回滚到旧端口
    # R38(P1): 原写法 `[ "$proto" = hysteria2 ] && command -v iptables` 为假就整块跳过 →
    # 落到普通 _mutate_config 只改监听端口, 而 metadata 的 hop_ranges 仍在、已持久化到
    # /etc/iptables 的 DNAT 仍指旧端口 → 跳跃客户端全挂且界面看不出。现与删除路径对齐:
    # 先判 hop 是否启用, 启用则要求 iptables 可用, 否则 fail-closed 拒绝改端口。
    if [ "$proto" = "hysteria2" ]; then
        # R32(P1): 与删除语义一致——hop metadata 存在但无法解析时 fail-closed, 不能把
        # "损坏"当成"没有 hop"走普通 _mutate_config 改监听端口(否则旧 DNAT 残留, hop 失效)
        if ! _hy2_hop_meta_ok "$tag"; then
            _error "节点 hop 元数据损坏, 无法安全修改端口: $tag"
            _press_any_key; return 1
        fi
        local ranges
        ranges=$(_read_hop_ranges "$meta")
        if [ -n "$ranges" ]; then
            if ! command -v iptables >/dev/null 2>&1; then
                _error "节点已启用端口跳跃, 但 iptables 不可用, 无法安全修改端口: $tag"
                _tip "已持久化的 DNAT 仍指向旧端口 ${oldport}; 请安装 iptables 后重试"
                _press_any_key; return 1
            fi
            # shellcheck disable=SC2086
            if _modify_port_hop "$tag" "$meta" "$oldport" "$newport" $ranges; then
                _success "端口已改为 ${newport}(含端口跳跃规则)"
            else
                _warn "端口修改未完成"
            fi
            _press_any_key
            return
        fi
    fi

    # ----------------------------------------------------------------------
    # Reality 节点分支(R41): 端口变更必须同步更新主 tag(含端口)、tunnel tag、
    # 路由规则 inboundTag 引用与元数据。主 tag 即元数据文件名, 一并重命名,
    # 否则 tag/config/metadata 三方不一致(删除/域名切换等按 tag 定位的操作全错)。
    # 更新模型与 _reality_domain_menu 一致: jq 重命名 tag + 重写路由规则。
    # R41(P1): 事务模型对齐 _hy2_port_txn —— 内存生成完整新 metadata → 提交
    # metadata → 最后提交 config; 任一步失败回滚已提交步骤(config 由 _mutate_config
    # 自带回滚), 保证 config/metadata 全部回到旧端口或全部新端口。
    # ----------------------------------------------------------------------
    if [ "$proto" = "vless-tcp-reality-vision" ] || [ "$proto" = "vless-xhttp-reality" ]; then
        if ! _reality_port_txn "$tag" "$meta" "$oldport" "$newport"; then
            _press_any_key; return 1
        fi
        _press_any_key
        return
    fi

    # ----------------------------------------------------------------------
    # 非 hop 路径: 统一端口事务(_port_txn), 与 _hy2_port_txn / Reality 分支同模型。
    # 旧实现是 config → metadata 两段式且无回滚: config 提交成功而 metadata 写失败时
    # 留下 "config 新端口 / metadata 旧端口" 的分裂。现在统一为:
    #   内存生成完整新 metadata(port + name + share_link) → 原子提交 metadata
    #   → 提交 config(_mutate_config 自带 verified-restart 与失败回滚); config 失败回滚 metadata。
    # ----------------------------------------------------------------------
    local old_name new_name newmeta tmpm newlink rebuild_rc=0
    old_name=$(jq -r '.name' "$meta")
    # F8: 仅替换 "-<oldport>" 后缀, 全局子串替换会破坏名称中含端口号的其他数字
    new_name=$(_rename_node_with_port "$old_name" "$oldport" "$newport")

    if [ "$proto" = "hysteria2" ]; then
        # hy2 派生状态(链接 + clash)的唯一入口是 _hy2_sync_derived; 其"可表达→写回 /
        # gecko 自定义尺寸→清空 / 缺字段→拒绝"三态在内存侧的等价实现就是
        # _hy2_gen_port_newmeta(同一份 _hy2_link_unexpressible 判据), 故直接复用它一次生成
        # port + name + share_link 并整体提交。旧写法"先提交端口 → 再单独写 name → 最后同步
        # 派生"是三段式: name 那步失败会直接 return, 连派生同步都不做, 留下"新端口 + 旧链接/
        # 旧 clash"的半完成状态。
        newmeta=$(_hy2_gen_port_newmeta "$meta" "$newport") || {
            _error "生成新元数据失败(元数据缺少必要字段), 端口未修改"
            _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
            _press_any_key; return 1
        }
        if ! _port_txn "$tag" "$meta" "$newport" "$newmeta"; then
            _press_any_key; return 1
        fi
        # 链接已随 metadata 一次提交; 这里补 clash 派生缓存(传 old_name: 改名后必须删掉旧名
        # 条目, 否则 clash.yaml 残留指向旧端口的幽灵条目)
        _hy2_sync_derived "$meta" "$old_name" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
        _success "端口已改为 ${newport}"
        _press_any_key
        return 0
    fi

    # 非 hy2: 同样在内存生成完整新 metadata, 从"承载新端口 + 新名称"的临时文件重建分享链接
    # (链接的 #fragment 取 .name, 与 Reality 分支 / hy2 分支同源), 未落地任何真实文件。
    tmpm=$(mktemp "${meta}.port.XXXXXX") || { _error "创建临时文件失败"; _press_any_key; return 1; }
    if ! jq --argjson p "$newport" --arg n "$new_name" '.port=$p | .name=$n' "$meta" > "$tmpm"; then
        rm -f "$tmpm"; _error "生成元数据失败"; _press_any_key; return 1
    fi
    case "$proto" in
        vless-tcp-reality-vision|vless-xhttp-reality) newlink=$(_rebuild_reality_link "$tmpm") || rebuild_rc=1 ;;
        vless-enc) newlink=$(_rebuild_vless_enc_link "$tmpm") || rebuild_rc=1 ;;
        vless-xhttp-cdn|vless-ws-cdn) newlink=$(_rebuild_cdn_link "$tmpm") || rebuild_rc=1 ;;
        *)
            # 其他协议: @ 锚定分割确保只替换 host:port 段(不误伤 path/sni/name)。
            # F7: 链接不含 @(被采纳节点的 "#tag (adopted)" 占位)时输出空串,
            # 走下方 rebuild_rc=1 分支保留原链接 —— 实测原写法会产出 "...@:新端口..." 垃圾。
            local oldlink; oldlink=$(jq -r '.share_link' "$meta" 2>/dev/null)
            newlink=$(_rewrite_link_port "$oldlink" "$oldport" "$newport")
            [ -n "$newlink" ] || rebuild_rc=1
            ;;
    esac

    # R38(M10): 重建失败或结果为空(被采纳节点缺字段) -> 保留原 share_link, 只报告; 端口与
    # 名称照常提交 —— 事务尚未开始, 不会出现"config 已改而链接没跟上"的中间态。
    if [ "$rebuild_rc" -ne 0 ] || [ -z "$newlink" ]; then
        _warn "分享链接重建失败(元数据缺少必要字段), 分享链接保持旧值"
        _tip "请使用 [查看节点] 核对, 或删除后重建该节点"
        newmeta=$(cat "$tmpm" 2>/dev/null) || newmeta=""
    else
        newmeta=$(jq --arg l "$newlink" '.share_link=$l' "$tmpm") || newmeta=""
    fi
    rm -f "$tmpm"
    [ -n "$newmeta" ] || { _error "生成元数据失败"; _press_any_key; return 1; }

    if ! _port_txn "$tag" "$meta" "$newport" "$newmeta"; then
        _press_any_key; return 1
    fi
    # F1: config/metadata 已一致, 同步 clash 派生缓存(端口与名称都可能已变)
    _sync_node_clash "$meta" "$old_name"
    _success "端口已改为 ${newport}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# 更新监听(单节点 R7)
# ---------------------------------------------------------------------------
_update_listen() {
    clear
    local count; count=$(_node_count)
    [ "$count" -eq 0 ] && { _warn "暂无节点"; _press_any_key; return; }
    echo; echo -e "  ${CYAN}【更新监听 — 单节点】${NC}"
    echo -e "  ${YELLOW}仅修改所选节点的 listen, 其他节点不变${NC}"
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local tag name port listen
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f")
        port=$(jq -r '.port' "$f"); listen=$(jq -r '.listen' "$f")
        tags+=("$tag")
        printf "  ${GREEN}[%d]${NC} %-20s 端口 %-7s 当前监听 %s\n" "$i" "$name" "$port" "$listen"
        i=$((i+1))
    done
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择: " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local curlisten; curlisten=$(jq -r '.listen' "$meta")
    echo -e "  当前监听: ${CYAN}${curlisten}${NC}"
    echo -e "  可选: :: (双栈默认) / 0.0.0.0 / 127.0.0.1 (回环, 供 cloudflared/中转回源) / ::1 / 具体 IP"
    local newlisten
    read -rp "  新监听地址: " newlisten
    if ! _validate_listen "$newlisten"; then
        _warn "监听地址不合法"; _press_any_key; return
    fi

    if ! _mutate_config --arg t "$tag" --arg l "$newlisten" \
         '(.inbounds[] | select(.tag == $t) | .listen) = $l'; then
        _error "监听修改失败, 已回滚"; _press_any_key; return
    fi

    # 联动链接服务器地址(R7 确认 A)
    local proto oldaddr newaddr
    proto=$(jq -r '.protocol' "$meta")
    oldaddr=$(jq -r '.link_addr' "$meta")
    # CDN 协议强制填域名(M12: CDN 节点填公网 IP 会导致直连失效)
    case "$proto" in *-cdn)
        echo -e "  ${YELLOW}该节点为 CDN 协议, 必须使用 CDN 域名${NC}"
        echo -e "  当前链接服务器地址: ${oldaddr}"
        read -rp "  请输入 CDN 域名: " newaddr
        # 2026-09-12 三审(L3): 旧判据 *"."* 连 IPv4 都放行, 与"须填域名"的提示自相矛盾;
        # 改用与创建路径一致的域名格式校验(R38 _validate_domain)。
        _validate_domain "$newaddr" || { _warn "CDN 节点须填域名, 而非 IP"; _press_any_key; return; }
        ;;
    *)
        if _is_listen_loopback "$newlisten"; then
            echo -e "  ${YELLOW}监听已改为回环, 该节点仅本机可达(适合 cloudflared 回源)${NC}"
            echo -e "  当前链接服务器地址: ${oldaddr}"
            read -rp "  请输入新的链接服务器地址(CDN 域名): " newaddr
        else
            echo -e "  监听已改为全监听(${newlisten}), 该节点对外可达"
            local pubip; pubip=$(_get_public_ip)
            read -rp "  请输入链接服务器地址(公网 IP/域名, 默认 ${pubip}): " newaddr
            newaddr=${newaddr:-$pubip}
        fi
        ;;
    esac
    [ -z "$newaddr" ] && newaddr="$oldaddr"

    # 重写链接里的地址(F7/F1: 收口到 _rewrite_link_addr)。
    # 链接不含 @(被采纳节点的 "#tag (adopted)" 占位)时输出空串 —— 此时只更新
    # listen/link_addr, 保留原链接, 实测原写法会产出 "...@:端口..." 垃圾。
    # 2026-09-12 三审(M6): CDN 节点同步更新 preferred_addr —— clash 条目与
    # _rebuild_cdn_link 的权威地址是 preferred_addr, 只改 link_addr 会留下
    # "本次链接已更新、下次端口修改重建时又回退到旧地址"的元数据自相矛盾。
    # 用 has("preferred_addr") 判断, 非 CDN 节点(无该字段)不受影响。
    local oldlink newlink
    oldlink=$(jq -r '.share_link' "$meta" 2>/dev/null)
    newlink=$(_rewrite_link_addr "$oldlink" "$newaddr")
    if [ -n "$newlink" ]; then
        _meta_update "$meta" '.listen=$l | .link_addr=$a
            | (if has("preferred_addr") then .preferred_addr=$a else . end)
            | .share_link=$link' \
            --arg l "$newlisten" --arg a "$newaddr" --arg link "$newlink" || { _error "监听元数据写入失败"; _press_any_key; return 1; }
    else
        _warn "分享链接非标准格式(被采纳节点?), 仅更新监听与链接地址记录"
        _meta_update "$meta" '.listen=$l | .link_addr=$a
            | (if has("preferred_addr") then .preferred_addr=$a else . end)' \
            --arg l "$newlisten" --arg a "$newaddr" || { _error "监听元数据写入失败"; _press_any_key; return 1; }
    fi
    # F1: 监听/链接地址变化需同步 clash 条目的 server 字段
    _sync_node_clash "$meta"

    _success "监听已更新为 ${newlisten}, 链接地址更新为 ${newaddr}"
    _press_any_key
}

# ---------------------------------------------------------------------------
# clash.yaml 输出辅助(纯文本追加, 不用 jq —— jq 不能解析 yaml)
# 用法:_add_node_to_yaml <yaml_node_line>   (传入的是一行 yaml 节点: - {name: ...})
# ---------------------------------------------------------------------------
CLASH_YAML="$DEPLOY_DIR/clash.yaml"

_add_node_to_yaml() {
    local line="$1" name="$2"
    mkdir -p "$DEPLOY_DIR" || return 1
    if [ ! -f "$CLASH_YAML" ]; then
        printf 'proxies:\n' > "$CLASH_YAML" || return 1
    fi
    # R22: name 由调用方显式传入, 不再从整行反解析 — 避免 YAML 转义/特殊字符
    # 导致的"解析 name != 实际 name"(name 已是唯一性约束下的稳定身份)
    if [ -n "$name" ]; then
        _remove_node_from_yaml_by_name "$name" 2>/dev/null || \
            _warn "Clash YAML 去重删除旧同名条目失败(${name}), 继续追加"
    fi
    if ! printf '  %s\n' "$line" >> "$CLASH_YAML"; then
        _warn "Clash YAML 追加失败(节点已创建), 可手工编辑 ${CLASH_YAML} 补齐该行"
        return 1
    fi
    return 0
}

_remove_node_from_yaml_by_name() {
    local name="$1"
    [ -f "$CLASH_YAML" ] || return 0
    local tmp grc=0
    # R19: mktemp 失败显式报错
    if ! tmp=$(mktemp); then
        _error "无法创建临时 Clash YAML 文件"
        return 1
    fi
    # 固定字符串匹配 name: "name" 含闭合引号(避免子串误删/正则转义)
    # R38(P1): 匹配串必须与写入侧同样过 _yaml_dq —— 写入的是转义后的形态(如 HK\"1),
    # 用原始 name 去匹配会永远找不到, 导致"写得进去却删不掉"的永久残留条目。
    # 含换行的 name 无法用行匹配删除(条目本身也不该跨行), 由 _yaml_dq 转成 \n 后即为单行。
    local key; key=$(_yaml_dq "$name")
    grep -vF "name: \"${key}\"" "$CLASH_YAML" > "$tmp" 2>/dev/null
    grc=$?
    # grep rc: 0=有选中行(已写入) 1=无选中行(节点不在, 合法) 2=读取/写入错误
    if [ "$grc" -ge 2 ]; then
        rm -f "$tmp"
        _error "Clash YAML 读取/过滤失败(grep rc=$grc)"
        return 1
    fi
    # R19: 过滤结果为空(最后一个节点被删)时保留 proxies: 头, 避免 YAML 变成空文件
    if [ ! -s "$tmp" ]; then
        if ! printf 'proxies:\n' > "$tmp"; then
            rm -f "$tmp"
            _error "Clash YAML 写入失败"
            return 1
        fi
    fi
    if ! mv -f "$tmp" "$CLASH_YAML"; then
        rm -f "$tmp"
        _error "Clash YAML 替换失败"
        return 1
    fi
    return 0
}

_remove_node_from_yaml_by_tag() {
    local tag="$1" name
    name=$(jq -r '.name' "$NODES_DIR/${tag}.json" 2>/dev/null)
    # R19: 读不到 name(如 json 已被删/损坏)视为删除失败, 由调用方决定取消或显式告警
    [ -z "$name" ] && return 1
    _remove_node_from_yaml_by_name "$name"
}

# 按 name 原位替换 clash.yaml 中某节点的条目(供端口跳跃/拥塞切换等派生字段变化后同步)。
# 匹配串与 _remove_node_from_yaml_by_name 完全一致(name: "KEY" 含闭合引号, KEY 过 _yaml_dq),
# 保证"写得进也换得掉"; 未找到条目 = 该节点不在派生缓存里, 不视为错误。
# 用法: _replace_node_in_yaml <yaml_node_line> <name>
_replace_node_in_yaml() {
    local line="$1" name="$2"
    [ -f "$CLASH_YAML" ] || return 0
    local key tmp
    key=$(_yaml_dq "$name")
    if ! tmp=$(mktemp); then
        _error "无法创建临时 Clash YAML 文件"
        return 1
    fi
    local replaced=0 l
    # || [ -n "$l" ]: read 在 EOF 且末行无结尾换行时返回 1 但 $l 已含该行内容,
    # 缺此守卫会把最后一行留在循环外 —— 替换中间条目时会随 mv 静默丢掉它
    while IFS= read -r l || [ -n "$l" ]; do
        if [ "$replaced" = 0 ] && printf '%s' "$l" | grep -qF "name: \"${key}\""; then
            printf '  %s\n' "$line" >> "$tmp"
            replaced=1
        else
            printf '%s\n' "$l" >> "$tmp"
        fi
    done < "$CLASH_YAML"
    if [ "$replaced" = 0 ]; then
        rm -f "$tmp"
        _warn "Clash YAML 未找到节点 [${name}] 条目, 跳过替换"
        return 0
    fi
    if ! mv -f "$tmp" "$CLASH_YAML"; then
        rm -f "$tmp"
        _error "Clash YAML 替换失败"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Hysteria2 端口跳跃管理 (iptables DNAT)
# ---------------------------------------------------------------------------

# 启用/禁用端口跳跃 (iptables DNAT + 分享链接 mport)
_hy2_toggle_hop() {
    clear
    _has_hy2_nodes || { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    _ensure_iptables || { _press_any_key; return; }

    echo; echo -e "  ${CYAN}【端口跳跃 — 启用/禁用】${NC}"
    echo -e "  ${YELLOW}iptables DNAT 将 UDP 端口范围转发到 Hysteria2 监听端口${NC}"
    echo -e "  ${YELLOW}客户端可连接范围内任意端口, 提高抗封锁能力${NC}"
    echo
    local tags=() i=1
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local tag name port ranges_display
        tag=$(basename "$f" .json); name=$(jq -r '.name' "$f"); port=$(jq -r '.port' "$f")
        ranges_display=$(_read_hop_ranges_display "$f")
        tags+=("$tag")
        if [ -n "$ranges_display" ]; then
            printf "  ${GREEN}[%d]${NC} %-20s 端口 %-7s 跳跃: ${GREEN}%s${NC}\n" "$i" "$name" "$port" "$ranges_display"
        else
            printf "  ${GREEN}[%d]${NC} %-20s 端口 %-7s 跳跃: ${RED}未启用${NC}\n" "$i" "$name" "$port"
        fi
        i=$((i+1))
    done
    [ ${#tags[@]} -eq 0 ] && { _warn "暂无 Hysteria2 节点"; _press_any_key; return; }
    echo -e "  ${GREEN}[0]${NC} 返回"
    read -rp "  选择节点: " choice
    [ "$choice" = "0" ] && return
    [[ "$choice" =~ ^[0-9]+$ ]] || { _warn "无效选择"; _press_any_key; return; }
    local idx=$((choice-1)); local tag="${tags[$idx]:-}"
    [ -z "$tag" ] && { _warn "无效选择"; _press_any_key; return; }

    local meta="$NODES_DIR/${tag}.json"
    local port; port=$(jq -r '.port' "$meta")
    local cur_ranges
    cur_ranges=$(_read_hop_ranges "$meta")
    local cur_display
    cur_display=$(_read_hop_ranges_display "$meta")

    if [ -n "$cur_ranges" ]; then
        # 已启用 → 禁用
        echo -e "  当前端口跳跃: ${GREEN}${cur_display}${NC} → ${port}"
        read -rp "  确认禁用端口跳跃? [y/N]: " ans
        case "$ans" in
            y|Y)
                # 事务(R15): 生成新 metadata(删 hop 字段, 链接不再含 &mport=) ->
                # runtime remove -> 原子持久化 -> 原子提交 metadata; 任一步失败回滚, 不永久分叉
                local hopmeta newmeta
                hopmeta=$(jq 'del(.hop_ranges) | del(.hop_start) | del(.hop_end) | del(.udp_hop_ports)' "$meta") || { _error "生成元数据失败"; _press_any_key; return; }
                newmeta=$(_hy2_gen_newmeta "$meta" "$hopmeta") || { _error "重建分享链接失败"; _press_any_key; return; }
                # shellcheck disable=SC2086
                if ! _hy2_hop_txn remove "$meta" "$newmeta" "$port" $cur_ranges; then
                    _error "端口跳跃禁用失败, 已回滚(iptables/metadata 保持一致)"
                    _press_any_key; return
                fi
                _success "端口跳跃已禁用"
                # 派生状态(链接 + clash)走**唯一入口**(去掉 mport / ports)
                _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
                ;;
            *) _info "已取消" ;;
        esac
    else
        # 未启用 → 设置端口范围
        echo -e "  当前 Hysteria2 端口: ${CYAN}${port}${NC}"
        echo -e "  ${YELLOW}端口范围格式:${NC}"
        echo -e "    单个端口:     ${CYAN}3050${NC}"
        echo -e "    连续范围:     ${CYAN}20000-50000${NC}"
        echo -e "    混合(逗号分隔): ${CYAN}11,13,15-17${NC}"
        echo
        local hop_input
        read -rp "  端口范围: " hop_input
        [ -z "$hop_input" ] && { _info "已取消"; _press_any_key; return; }
        # 解析并验证
        local parsed
        parsed=$(_parse_hop_ranges "$hop_input") || { _press_any_key; return; }
        # 规范化输入(用于存储和显示)
        local normalized=""
        local range
        for range in $parsed; do
            local rs re
            rs=$(echo "$range" | cut -d: -f1)
            re=$(echo "$range" | cut -d: -f2)
            if [ "$rs" = "$re" ]; then
                normalized="${normalized:+$normalized,}$rs"
            else
                normalized="${normalized:+$normalized,}$rs-$re"
            fi
        done
        # 事务(R15): 生成新 metadata(hop 字段 + 含 &mport= 的分享链接) ->
        # runtime add -> 原子持久化 -> 原子提交 metadata; 任一步失败回滚, 不永久分叉
        local hopmeta newmeta
        hopmeta=$(jq --arg r "$normalized" \
                   '.hop_ranges=$r | .udp_hop_ports=$r | del(.hop_start) | del(.hop_end)' "$meta") || { _error "生成元数据失败"; _press_any_key; return; }
        newmeta=$(_hy2_gen_newmeta "$meta" "$hopmeta") || { _error "重建分享链接失败"; _press_any_key; return; }
        # shellcheck disable=SC2086
        if ! _hy2_hop_txn add "$meta" "$newmeta" "$port" $parsed; then
            _error "iptables 规则添加失败或已回滚, 请检查内核是否支持 nat 模块"
            _press_any_key; return
        fi
        _success "端口跳跃已启用: ${normalized} → ${port}"
        # 派生状态(链接 + clash)走**唯一入口**(加入 mport / ports)
        _hy2_sync_derived "$meta" || _warn "派生状态有未完成项(原因见上方告警), 请核对 ${meta} 与 ${CLASH_YAML}"
        _tip "iptables DNAT 已生效, 客户端可连接范围内任意端口"
        _tip "请确保防火墙/安全组已放行该 UDP 端口范围"
    fi
    _press_any_key
}

# 查看端口跳跃状态
_hy2_view_hop() {
    clear
    echo; echo -e "  ${CYAN}【端口跳跃状态】${NC}"
    echo
    local found=0
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        local proto; proto=$(jq -r '.protocol' "$f" 2>/dev/null)
        [ "$proto" = "hysteria2" ] || continue
        local name port ranges_display
        name=$(jq -r '.name' "$f"); port=$(jq -r '.port' "$f")
        ranges_display=$(_read_hop_ranges_display "$f")
        if [ -n "$ranges_display" ]; then
            echo -e "  ${GREEN}●${NC} ${name}: ${CYAN}${ranges_display}${NC} → ${port} (UDP)"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无启用端口跳跃的节点${NC}"
    fi
    echo
    if command -v iptables >/dev/null 2>&1; then
        local rules
        rules=$(_hy2_list_all_hop_rules)
        if [ -n "$rules" ]; then
            echo -e "  ${CYAN}iptables nat 规则:${NC}"
            echo "$rules" | while read -r line; do
                echo -e "  ${GREEN}▸${NC} $line"
            done
        fi
    fi
    _press_any_key
}
