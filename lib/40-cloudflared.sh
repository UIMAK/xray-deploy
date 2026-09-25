#!/bin/bash
# =============================================================================
# lib/40-cloudflared.sh — cloudflared 管理
# 需求 R5:
#   - 安装(架构自适应下载) / 卸载(彻底清) / 切换令牌
#   - 安装走官方 `cloudflared service install <token>`, 不写 config.yml(路由在 CF Web 配)
#   - 改参数/令牌 = 直接改 /etc/systemd/system/cloudflared.service 或 /etc/init.d/cloudflared 启动行
#   - 3 项设置: 自动更新 (--autoupdate-freq 24h0m0s / --no-autoupdate)
#               HTTP/2   (--protocol http2 / 不写)
#               协议栈   (--edge-ip-version 4|6|auto / 不写)
#   - cloudflared 是唯一例外, 落官方默认点, 不收口 /opt/xray-deploy
# ============================================================================

# cloudflared 开关状态文件(持久化供手动查看, 运行时从 service 文件解析)
CF_STATE_AUTOUPDATE="$STATE_DIR/cf_autoupdate"     # on|off
CF_STATE_HTTP2="$STATE_DIR/cf_http2"               # on|off
CF_STATE_EDGE_IP="$STATE_DIR/cf_edge_ip"           # off|4|6|auto
CF_STATE_TOKEN="$STATE_DIR/cf_token"               # 安装时的 token

# ---------------------------------------------------------------------------
# 架构 -> cloudflared 下载资产名
# ---------------------------------------------------------------------------
_cf_arch_tag() {
    case "$(_detect_arch)" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        *)     echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装 cloudflared 二进制
# ---------------------------------------------------------------------------
_install_cloudflared_bin() {
    if [ -x "$CF_BIN" ]; then
        _info "cloudflared 已安装: $("$CF_BIN" --version 2>&1 | head -n1)"
        return 0
    fi
    local tag; tag=$(_cf_arch_tag)
    [ -z "$tag" ] && { _error "不支持的架构: $(uname -m)"; return 1; }
    local url="$CF_DL_BASE/cloudflared-linux-${tag}"
    _info "下载 cloudflared <- $url"
    # 先下到同目录临时文件再原子替换, 避免半截文件留在最终路径(L7); curl 优先(H1)
    # R38(P1): chmod/mv 必须检查——mv 失败(分区满/只读/同名目录)时 $CF_BIN 根本不存在,
    # 原实现却因末句 _success 返回 0 而报"安装成功", 且把 cloudflared.tmp.XXXXXX 留在
    # 最终目录旁(正是本 PR 要消除的"半截文件留在最终路径")。与 20-xray-core.sh 的
    # cp/mv/chmod 三步全查保持同一标准。
    local cf_tmp; cf_tmp=$(mktemp "${CF_BIN}.tmp.XXXXXX") || {
        _error "无法创建临时文件: ${CF_BIN}.tmp.XXXXXX(目录不可写/磁盘空间?)"
        return 1
    }
    if ! _http_download "$url" "$cf_tmp" 120; then
        rm -f "$cf_tmp"
        _error "cloudflared 下载失败"; return 1
    fi
    if ! chmod +x "$cf_tmp"; then
        rm -f "$cf_tmp"
        _error "cloudflared 设置执行权限失败"; return 1
    fi
    if ! mv -f "$cf_tmp" "$CF_BIN"; then
        rm -f "$cf_tmp"
        _error "cloudflared 落地失败(磁盘空间/只读/权限?), 未安装"; return 1
    fi
    _success "cloudflared 安装成功"
    return 0
}

# ---------------------------------------------------------------------------
# 从用户粘贴文本提取令牌(纯 bash, 不用 sed/grep -E, 避 busybox 兼容问题)
# cloudflared token 是 base64 JSON 串, 可能含 . - _ =
# 策略: 优先取 "service install" 或 "--token" 后的第一个字段; 兜底 ey 开头串
# ---------------------------------------------------------------------------
_extract_token() {
    local input="$1" token=""
    local arr=()
    read -ra arr <<< "$input"
    local i grab=0
    for ((i=0; i<${#arr[@]}; i++)); do
        local w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then
            # 跳过"纯引号"词: read -ra 只按空白切分、不做引号处理, 于是 CF 网页端的
            # --token " eyXXX" 会被拆成单独一个双引号词与带尾引号的 token 两个词。旧实现会把前者当成
            # token(剥引号后为空), 令牌提取失败并静默落到"整段原始输入当 token"的路径。
            case "$w" in ''|'"'|"'") continue ;; esac
            token="$w"; break
        fi
        case "$w" in
            install)    grab=1 ;;
            --token)    grab=1 ;;
            --token=*)  token="${w#--token=}"; break ;;
        esac
    done
    if [ -z "$token" ]; then
        for w in "${arr[@]}"; do
            case "$w" in
                ey????????????????????*)    token="$w"; break ;;
                \"ey????????????????????*)  token="${w#\"}"; break ;;
                \'ey????????????????????*)  token="${w#\'}"; break ;;
            esac
        done
    fi
    # 只剥一层首尾引号(与 _cf_extract_line_token 同口径)。用户从 CF 网页端粘贴的安装命令
    # 常给 token 加引号; read 不做引号移除, 残留的引号会被写进 service 启动行:
    # systemd 把它当分隔符尚可, 但 OpenRC 的 command_args="..." 会因内层引号提前闭合而
    # 截断整条命令行。结尾的 '=' 是 base64 合法 padding, 只剥引号不动它。
    token="${token%\"}"; token="${token%\'}"
    token="${token#\"}"; token="${token#\'}"
    [ -n "$token" ] && echo "$token"
}

# Tunnel tokens are opaque base64/base64url payloads. Restrict characters before embedding them in
# systemd/OpenRC service files: OpenRC sources its init file as shell, so quotes, substitutions,
# whitespace, or control characters must never be accepted as token data.
_cf_token_valid() {
    local token="${1:-}"
    [[ "$token" == ey* && "$token" =~ ^ey[A-Za-z0-9._/+_-]+={0,2}$ ]]
}

# ---------------------------------------------------------------------------
# 读取当前 service 文件启动行, 解析出 token 与 3 开关状态
# 输出全局: CF_CUR_TOKEN / CF_CUR_AUTOUPDATE / CF_CUR_HTTP2 / CF_CUR_EDGE_IP
#           CF_CUR_AUTOUPDATE_FLAG(启动行是否**显式**写了 autoupdate 标志)
# ---------------------------------------------------------------------------
_read_cf_state() {
    CF_CUR_TOKEN=""; CF_CUR_AUTOUPDATE="off"; CF_CUR_HTTP2="off"; CF_CUR_EDGE_IP="off"; CF_CUR_RAWLINE=""
    # F6: "启动行没有 autoupdate 标志" ≠ "自动更新关闭" —— cloudflared 缺省 autoupdate=on
    # (24h)。flag=no 时菜单按"默认开"显示, 且重建行不再无条件写 --no-autoupdate,
    # 避免对手动安装的 cloudflared 造成用户未要求的静默行为变更。
    CF_CUR_AUTOUPDATE_FLAG="no"
    local svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *)       svcfile="$CF_UNIT_SYSTEMD" ;;
    esac
    [ -f "$svcfile" ] || return 1
    # R39(P1): 只从"真正的启动命令行"收集(见 _cf_is_cmd_line: 排除注释与空行, 认
    # ExecStart=/command_args=/cmd=/command= 前缀或内联了 $CF_BIN 的 SysV start) 块)。
    # 原实现把**整个文件**作为兜底搜索范围, 于是形如
    #     # previous example token: eyAAAA...
    # 的注释会被当成当前 token: 显示给用户是错的, 更糟的是 _cf_toggle 会把它经
    # _cf_build_cmdline 写进 ExecStart —— 用一个注释里的过期 token 覆盖真 token, 隧道直接挂。
    # SysV 内联命令的场景由 _cf_is_cmd_line 的 $CF_BIN 分支覆盖, 不再需要全文件兜底。
    local lines="" ln
    while IFS= read -r ln || [ -n "$ln" ]; do
        if _cf_is_cmd_line "$ln"; then
            lines="$lines
$ln"
        fi
    done < "$svcfile"
    # 诊断输出仍需要完整原文(仅用于 _cf_diagnose 展示, 不参与解析)
    CF_CUR_RAWLINE=$(cat "$svcfile" 2>/dev/null)
    # token: 优先在启动行里找 --token 后字段; 兜底同一批行里的裸 ey 开头串
    # 把多行合成单行(换行换空格), 再 read -ra 按空白分词(read -ra 只读单行)
    local oneline
    oneline=$(printf '%s' "$lines" | tr '\n' ' ')
    local arr=() i grab=0
    read -ra arr <<< "$oneline"
    for ((i=0; i<${#arr[@]}; i++)); do
        local w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then
            CF_CUR_TOKEN="$w"; break
        fi
        case "$w" in
            --token)    grab=1 ;;
            --token=*)  CF_CUR_TOKEN="${w#--token=}"; break ;;
        esac
    done
    if [ -z "$CF_CUR_TOKEN" ]; then
        for w in "${arr[@]}"; do
            case "$w" in ey????????????????????*) CF_CUR_TOKEN="$w"; break ;; esac
        done
    fi
    # 去掉 token 首尾可能粘连的引号(command_args="..." 闭合引号)
    # 注意只剥引号: cloudflared token 是 base64, 末尾 '=' 是合法 padding
    case "$CF_CUR_TOKEN" in
        *\") CF_CUR_TOKEN="${CF_CUR_TOKEN%\"}" ;;
    esac
    case "$CF_CUR_TOKEN" in
        \"*) CF_CUR_TOKEN="${CF_CUR_TOKEN#\"}" ;;
    esac
    # 开关(固定字符串匹配)
    echo "$oneline" | grep -q -- '--no-autoupdate'      && CF_CUR_AUTOUPDATE="off" && CF_CUR_AUTOUPDATE_FLAG="yes"
    echo "$oneline" | grep -q -- '--autoupdate-freq'   && CF_CUR_AUTOUPDATE="on"  && CF_CUR_AUTOUPDATE_FLAG="yes"
    echo "$oneline" | grep -q -- '--protocol http2'    && CF_CUR_HTTP2="on"
    # 协议栈: --edge-ip-version <4|6|auto>; 未写则 off
    if   echo "$oneline" | grep -q -- '--edge-ip-version 4';    then CF_CUR_EDGE_IP="4";
    elif echo "$oneline" | grep -q -- '--edge-ip-version 6';    then CF_CUR_EDGE_IP="6";
    elif echo "$oneline" | grep -q -- '--edge-ip-version auto'; then CF_CUR_EDGE_IP="auto";
    fi
}

# ---------------------------------------------------------------------------
# autoupdate 的**有效**状态(供菜单显示与 _cf_toggle 共用同一判据)。
# cloudflared 缺省 autoupdate=on(24h), 所以"启动行没写任何 autoupdate 标志"意味着
# 实际是开着的 —— CF_CUR_AUTOUPDATE 此时是 off(那是"行里写了 --no-autoupdate"的意思),
# 二者语义不同。显示与切换基线必须都走这里, 否则会出现"菜单显示开、按一下算出 on、
# 写出 24h 后行为不变"的空操作。
# ---------------------------------------------------------------------------
_cf_autoupdate_effective() {
    if [ "${CF_CUR_AUTOUPDATE_FLAG:-no}" = "no" ]; then
        echo "on"
    else
        echo "${CF_CUR_AUTOUPDATE:-off}"
    fi
}

# ---------------------------------------------------------------------------
# 令牌掩码显示(菜单/诊断三处共用)。首 12 + 末 4 的固定切片对短令牌会**重叠**,
# 例如 8 字符令牌渲染成整串加一个省略号 —— 等于把凭据打屏(诊断输出常被直接粘贴到
# issue/群里)。故长度不足掩码窗口时改用固定占位, 不泄漏任何字符。
# ---------------------------------------------------------------------------
_cf_mask_token() {
    local t="$1"
    # 阈值必须 > 16: 长度恰为 16 时 ${t:0:12} 与 ${t: -4} 正好覆盖全部字符(0-11 + 12-15),
    # "掩码"等于把整串原样打出来。留出隐藏区才算掩码, 故要求 >= 20(首12+末4, 中间至少 4 位)。
    if [ "${#t}" -lt 20 ]; then
        printf '%s' '****(过短, 已隐藏)'
    else
        printf '%s...%s' "${t:0:12}" "${t: -4}"
    fi
}

# Redact service lines without assuming quotes are absent. For an unparseable credential-bearing
# line, omit the complete line instead of risking a plaintext token in copy/pasted diagnostics.
_cf_redact_service_line() {
    local line="$1" token masked lower
    if _cf_is_cmd_line "$line"; then
        token=$(_cf_extract_line_token "$line")
        if [ -n "$token" ]; then
            masked=$(_cf_mask_token "$token")
            printf '%s\n' "${line//"$token"/$masked}"
            return 0
        fi
    fi
    lower="${line,,}"
    case "$lower" in
        *token*|*ey????????????????????*) printf '[敏感配置行已隐藏]\n' ;;
        *) printf '%s\n' "$line" ;;
    esac
}

# ---------------------------------------------------------------------------
# 重组 cloudflared 启动命令行(按 3 开关 + token)
# 用法:_cf_build_cmdline <token>
# 读取全局 CF_AUTOUPDATE/CF_HTTP2/CF_EDGE_IP
# ---------------------------------------------------------------------------
_cf_build_cmdline() {
    local token="$1"
    _cf_token_valid "$token" || { _error "拒绝把非法 Token 写入 service 命令行"; return 1; }
    local cmd="$CF_BIN"
    if [ "$CF_AUTOUPDATE" = "on" ]; then
        cmd="$cmd --autoupdate-freq 24h0m0s"
    elif [ "${CF_AUTOUPDATE_FLAG:-yes}" = "yes" ]; then
        # F6: 仅当原启动行确实显式管理该开关(或本脚本首次安装, FLAG 默认 yes)才写
        # --no-autoupdate; 手动安装的无标志行重建后保持 cloudflared 缺省行为不变
        cmd="$cmd --no-autoupdate"
    fi
    cmd="$cmd tunnel"
    [ "$CF_HTTP2" = "on" ] && cmd="$cmd --protocol http2"
    case "$CF_EDGE_IP" in
        4)    cmd="$cmd --edge-ip-version 4" ;;
        6)    cmd="$cmd --edge-ip-version 6" ;;
        auto) cmd="$cmd --edge-ip-version auto" ;;
    esac
    cmd="$cmd run --token $token"
    echo "$cmd"
}

# ---------------------------------------------------------------------------
# 把启动行写回 service 文件(纯 bash 逐行处理, 避 busybox sed -E)
# 用法:_cf_write_service_line <cmdline>          (整行重组)
#       _cf_replace_token_in_service <oldtoken> <newtoken>  (只换 token, 保留原参数)
# ---------------------------------------------------------------------------
# 通用: 逐行读 service 文件, 替换匹配行, 写回(保留原文件权限)
# 兼容缩进: 匹配前先去除行首空白; 未匹配到任何行时返回 1
_svc_replace_line() {
    local svcfile="$1" pattern="$2" newline="$3" tmp found=0
    [ -f "$svcfile" ] || return 1
    # 备份必须真正成功才允许改 service(磁盘满/IO 失败时无 .bak 可恢复)
    _svc_backup "$svcfile" || return 1
    local tmp write_ok=1
    tmp=$(mktemp) || { _error "无法创建临时 service 文件: $svcfile"; return 1; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        local t="${ln#"${ln%%[![:space:]]*}"}"
        case "$t" in
            "$pattern"*) printf '%s\n' "$newline" >> "$tmp" || write_ok=0; found=1 ;;
            *) printf '%s\n' "$ln" >> "$tmp" || write_ok=0 ;;
        esac
    done < "$svcfile"
    if [ "$found" -eq 0 ]; then
        # 未找到目标行: 本次未产生任何修改, 同时清理 .bak 避免留下陈旧回滚点
        rm -f "$tmp" "$svcfile.bak"
        return 1
    fi
    # tmp 构造必须完整成功(磁盘满/IO/配额时 printf 可能写一半), 否则半截文件会被 _svc_commit 提交
    if [ "$write_ok" -ne 1 ]; then
        _error "临时 service 文件写入失败(磁盘空间/IO?), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    _svc_commit "$svcfile" "$tmp"
}

# Backups contain plaintext credentials. The global entry point uses umask 077, but the library
# can also be sourced directly and an existing .bak keeps its old mode when cp truncates it.
_svc_backup() {
    local svcfile="$1" backup="${1}.bak"
    if [ -e "$backup" ] && ! chmod 600 "$backup" 2>/dev/null; then
        _error "无法收紧既有 service 备份权限, 未修改 service: $backup"
        return 1
    fi
    ( umask 077; cp -f "$svcfile" "$backup" ) 2>/dev/null || {
        _error "service 备份失败: $svcfile"
        return 1
    }
    if ! chmod 600 "$backup" 2>/dev/null; then
        rm -f "$backup" 2>/dev/null
        _error "service 备份权限收紧失败, 未修改 service: $backup"
        return 1
    fi
    return 0
}

# 把 tmp 提交为 service 文件内容: cat(而非 mv)保原文件 inode 与权限(openrc init.d 的
# +x 位不能丢; mktemp 是 0600)。写入失败自动从 .bak 恢复并返回 1, 保证"失败可恢复"。
_svc_commit() {
    local svcfile="$1" tmp="$2"
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    if ! cat "$tmp" > "$svcfile"; then
        _error "service 文件写入失败($svcfile), 尝试从备份恢复"
        if [ -f "${svcfile}.bak" ]; then
            if ! cp -f "${svcfile}.bak" "$svcfile" 2>/dev/null; then
                _error "service 文件从备份恢复也失败: $svcfile, 请手动处理"
            fi
        fi
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    # F4: service 行内含明文隧道 token, 写回时收紧权限 —— systemd unit 600(init.d 700
    # 含可执行位)。cloudflared service install 生成的是 644/755(任何本地用户可读 token);
    # xray unit 无密钥可选 644(R38 M14), 这里有密钥必须收口。systemd 会记
    # "marked world-inaccessible" 提示, 属可接受代价。chmod 失败 warn-only:
    # 内容已落地, 因权限回滚会丢掉用户要的结果(与 logrotate chmod 同一取舍)。
    case "$svcfile" in
        /etc/init.d/*)
            if ! chmod 700 "$svcfile" 2>/dev/null; then
                _error "service 执行权限设置失败: $svcfile, 回滚 service 文件"
                _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
                return 1
            fi
            ;;
        *)
            chmod 600 "$svcfile" 2>/dev/null || \
                _warn "service 文件权限收紧失败(token 可能被其他用户读取): $svcfile"
            ;;
    esac
    return 0
}

# 从 .bak 恢复 service 文件(cat 保原文件权限/执行位, 与 _svc_commit 一致)。
# 回滚本身必须检查: 失败显式报错并返回 1, 不静默"假装已回滚"。
_svc_restore() {
    local svcfile="$1"
    [ -f "${svcfile}.bak" ] || { _warn "无 ${svcfile}.bak 可回滚"; return 1; }
    if ! cat "${svcfile}.bak" > "$svcfile"; then
        _error "service 回滚失败: $svcfile, 请手动检查"
        return 1
    fi
    case "$svcfile" in
        /etc/init.d/*)
            if ! chmod 700 "$svcfile" 2>/dev/null; then
                _error "service 回滚后执行权限设置失败: $svcfile"
                return 1
            fi
            ;;
        *)
            chmod 600 "$svcfile" 2>/dev/null || \
                _warn "service 文件权限收紧失败(token 可能被其他用户读取): $svcfile"
            ;;
    esac
    # 恢复成功: .bak 已消费, 立即删除(否则直调 _svc_restore 的路径——_svc_commit chmod 失败、
    # _cf_write_service_line/_cf_replace_token_in_service 的 daemon-reload 失败——都会留下陈旧回滚点)
    rm -f "${svcfile}.bak"
    return 0
}

_cf_write_service_line() {
    local cmd="$1" svcfile
    local token; token=$(_cf_extract_line_token "$cmd")
    _cf_token_valid "$token" || { _error "拒绝写入不安全的 cloudflared Token"; return 1; }
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *) _error "无 init 系统, 无法管理 cloudflared service"; return 1 ;;
    esac
    [ -f "$svcfile" ] || { _error "service 文件不存在: $svcfile"; return 1; }
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        if grep -q '^[[:space:]]*command_args=' "$svcfile" 2>/dev/null; then
            local prefix="$CF_BIN "
            local args="${cmd#$prefix}"
            _svc_replace_line "$svcfile" "command_args=" "command_args=\"$args\"" || return 1
        elif grep -q '^[[:space:]]*cmd=' "$svcfile" 2>/dev/null; then
            _svc_replace_line "$svcfile" "cmd=" "cmd=\"$cmd\"" || return 1
        else
            _error "无法在 $svcfile 中找到 command_args= 或 cmd= 行"
            return 1
        fi
    else
        _svc_replace_line "$svcfile" "ExecStart=" "ExecStart=$cmd" || return 1
        if ! systemctl daemon-reload 2>/dev/null; then
            _error "systemd daemon-reload 失败, 回滚 service 文件"
            _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
            if ! systemctl daemon-reload 2>/dev/null; then
                _error "恢复后的 daemon-reload 也失败: $svcfile"
            fi
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# R39(P1): 判定一行是否为"真正的启动命令行"。只有这些行里的 token 才允许替换。
# 为什么: R38 只加了 `replaced` 标志, 但判据是"整行包含 oldtok"。而 _read_cf_state 的
# token 兜底会在**整个文件**里搜 ey... 串, 所以 oldtok 可能来自一行注释:
#     # previous example token: eyAAAA...
#     ExecStart=... --token eyBBBB...
# 于是替换命中注释行 -> replaced=1 -> 报"令牌已更新", 而 ExecStart 仍是旧 token,
# 重启当然成功, state 却写入新 token => service 与 state 分裂。假成功只是从
# "0 次替换"变成了"1 次替换但改的是注释", 标志本身并不足够。
# 判据: 注释行一律不动; 只认 unit/init 的命令字段前缀, 或内联了 cloudflared 二进制
# 路径的行(SysV 的 start) 块)。
# ---------------------------------------------------------------------------
_cf_is_cmd_line() {
    local t="${1#"${1%%[![:space:]]*}"}"
    case "$t" in
        '#'*|'') return 1 ;;   # 注释与空行绝不修改
    esac
    # R40: systemd 的其他 Exec* 指令一定不是启动命令行, 必须在下面的 $CF_BIN 兜底之前排除。
    # 否则 `ExecStop=/usr/local/bin/cloudflared tunnel cleanup --token <旧>` 这类形态会被
    # 兜底规则当成启动行改写(replaced 计数还会 +1, 掩盖"真启动行没改到"的失败)。
    # 这是严格收窄: 只排除可证明不是 start 的指令, 不会让真正的 ExecStart 漏判。
    case "$t" in
        ExecStartPre=*|ExecStartPost=*|ExecStop=*|ExecStopPost=*|ExecReload=*|ExecCondition=*) return 1 ;;
    esac
    case "$t" in
        ExecStart=*|command_args=*|cmd=*|command=*) return 0 ;;
    esac
    # SysV/OpenRC 的 start) 块可能内联完整命令行, 用二进制路径识别
    case "$t" in
        *"$CF_BIN"*) return 0 ;;
    esac
    return 1
}

# R39(P1): 从一行启动命令里提取现存 token。优先 `--token <v>` / `--token=<v>`,
# 兜底裸 ey... 词; 去掉粘连的闭合引号(command_args="... --token XXX")。
# 输出为空表示该行没有 token(如 openrc 的 command="/usr/local/bin/cloudflared")。
_cf_extract_line_token() {
    local ln="$1" arr=() i w grab=0 tok=""
    read -ra arr <<< "$ln"
    for ((i=0; i<${#arr[@]}; i++)); do
        w="${arr[$i]}"
        if [ "$grab" -eq 1 ]; then tok="$w"; break; fi
        case "$w" in
            --token)   grab=1 ;;
            --token=*) tok="${w#--token=}"; break ;;
        esac
    done
    if [ -z "$tok" ]; then
        for w in "${arr[@]}"; do
            case "$w" in ey????????????????????*) tok="$w"; break ;; esac
        done
    fi
    # 只剥一层首尾引号: cloudflared token 是 base64, 末尾的 '=' 是合法 padding, 不能动
    tok="${tok%\"}"; tok="${tok%\'}"
    tok="${tok#\"}"; tok="${tok#\'}"
    printf '%s' "$tok"
}

# 只替换 service 启动行里的 token, 保留用户原有的其他参数(不破坏手动装的好配置)
# 用纯 bash 字符串替换(不依赖 sed -E 正则)
# R38(P1): 必须跟踪"是否真的替换了至少一处"——原实现只看写 tmp 是否成功, 零替换也返回 0,
#   调用方随后用**旧 token** 重启成功, 于是写入新 token 到 state 并报「令牌已更新」。
# R39(P1): 判据由"整行包含 oldtok"收紧为"在真正的启动命令行上替换掉解析出来的 token"
#   (见 _cf_is_cmd_line / _cf_extract_line_token)。同时替换方式改为只替换 token 子串
#   `${ln//$found/$newtok}` —— 原来的 `read -ra` + 逐词重组会吃掉 openrc
#   `command_args="... --token XXX="` 的闭合引号并把连续空格压成一个, 写出的 init 脚本
#   引号不闭合, source 时报错、服务彻底起不来。
# 参数 oldtok 现在只是提示(命令行上解析到的 token 才是权威), 保留以兼容调用方签名。
_cf_replace_token_in_service() {
    local oldtok="$1" newtok="$2" svcfile
    _cf_token_valid "$newtok" || { _error "拒绝写入不安全的 cloudflared Token"; return 1; }
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *) return 1 ;;
    esac
    [ -f "$svcfile" ] || return 1
    # 备份必须真正成功才允许改 service(失败可恢复)
    _svc_backup "$svcfile" || return 1
    local tmp write_ok=1 replaced=0 ln found
    tmp=$(mktemp) || { _error "无法创建临时 service 文件: $svcfile"; return 1; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        if _cf_is_cmd_line "$ln"; then
            found=$(_cf_extract_line_token "$ln")
            if [ -n "$found" ]; then
                printf '%s\n' "${ln//"$found"/$newtok}" >> "$tmp" || write_ok=0
                replaced=$((replaced+1))
                continue
            fi
        fi
        printf '%s\n' "$ln" >> "$tmp" || write_ok=0
    done < "$svcfile"
    # tmp 构造必须完整成功(磁盘满/IO/配额时 printf 可能写一半), 否则半截文件会被提交
    if [ "$write_ok" -ne 1 ]; then
        _error "临时 service 文件写入失败(磁盘空间/IO?), 保留原文件"
        rm -f "$tmp"
        return 1
    fi
    # R38/R39(P1): 未在任何启动命令行上替换到 token => 必须失败, 否则调用方拿旧 token
    # 重启并宣称"令牌已更新"
    if [ "$replaced" -lt 1 ]; then
        rm -f "$tmp" "${svcfile}.bak"
        _error "未在 $svcfile 的启动命令行中找到可替换的令牌, 令牌未更新"
        _tip "该 service 可能以其他形式提供 token(--token-file / Environment=TUNNEL_TOKEN=),"
        _tip "本脚本不会改写这类形态; 请手动编辑 $svcfile 后重启 cloudflared"
        return 1
    fi
    [ -n "$oldtok" ] && [ "$replaced" -gt 1 ] && \
        _warn "在 $replaced 行启动命令中替换了令牌, 请确认该 service 是否本就有多条启动行"
    _svc_commit "$svcfile" "$tmp" || return 1
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        if ! systemctl daemon-reload 2>/dev/null; then
            _error "systemd daemon-reload 失败, 回滚 service 文件"
            _svc_restore "$svcfile" || _error "回滚失败, 请手动检查 $svcfile"
            if ! systemctl daemon-reload 2>/dev/null; then
                _error "恢复后的 daemon-reload 也失败: $svcfile"
            fi
            return 1
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# R38(P2): 统一的 cloudflared 进程发现。与 _cf_is_running 用同一套判据, 避免
# "判活用 /proc 扫描、杀进程用 pgrep" 两套逻辑不一致: 容器内 busybox pgrep 假阴性时
# _cf_kill_all 会报"已清理"而实际仍有残留, 随后 start 出第二个实例。
# 另: procps 的 ps 无 -e 时只列当前 tty 的进程, cron 下几乎列不出东西, 必须带 -e。
# 输出: 每行一个 PID(可能为空)
# ---------------------------------------------------------------------------
_cf_pids() {
    local p c seen=" "
    # 2026-09-21 复审(P1): pidof 与 /proc 扫描必须**都跑并取并集**。旧写法"pidof 有输出就
    # 直接 return"假定 pidof 的结果是超集 —— 但 busybox 的 pidof 在容器里会**漏报**(H3),
    # 漏掉的恰恰可能是我们自己的残留进程, 于是 _cf_kill_all 第 4 步认为"已清理干净"并返回 0,
    # 把真正活着的孤儿进程留给用户(隧道连接数持续增长)。
    # 两条路径会重复列出同一 PID, 故用 seen 去重(重复项会让"仍有残留"的告警与 others
    # 列表失真)。
    for p in $(pidof cloudflared 2>/dev/null); do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        case "$seen" in *" $p "*) continue ;; esac
        seen="$seen$p "
        printf '%s\n' "$p"
    done
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        case "$seen" in *" $p "*) continue ;; esac
        read -r c 2>/dev/null < "/proc/$p/comm" || continue
        [ "$c" = "cloudflared" ] || continue
        seen="$seen$p "
        printf '%s\n' "$p"
    done
}

# ---------------------------------------------------------------------------
# "可以安全杀掉"的 cloudflared PID: 只认 exe 指向**本 service 实际启动的那个二进制**的进程。
#
# 为什么杀进程不能沿用 _cf_is_running 的全机 comm 判据:
#   判活用全机扫描的代价只是"把别人的隧道算成我们的"(假阳性只影响显示), 而**杀进程**的
#   假阳性是破坏性的 —— 用户机器上可能有另一个与本脚本无关的 cloudflared(别的工具、
#   容器宿主进程), 一次开关切换就把人家 SIGKILL 掉。
# 为什么期望路径取 _cf_service_bin 而不是写死 $CF_BIN:
#   cloudflared 二进制不由本脚本独占(用户可能先用发行版包/自己装过, 本脚本只接管
#   service 文件)。写死 $CF_BIN 会让运行 /usr/bin/cloudflared 的**我们自己的**进程
#   变成"非我所有", 于是杀不掉、启动出第二个实例 —— 正是本函数要防的事。
# exe 读不到时 _proc_exe_is 放行(与既有的 fail-open 约定一致): 那是最后一道清理路径,
# 假阴性会留下我们自己的孤儿进程。
# 本平台对应的 service 文件路径(与 _read_cf_state 同口径)
_cf_unit_path() {
    case "$INIT_SYSTEM" in
        openrc) printf '%s' "$CF_UNIT_OPENRC" ;;
        *)      printf '%s' "$CF_UNIT_SYSTEMD" ;;
    esac
}

# ---------------------------------------------------------------------------
# 包装器的"取参选项"表 + 前置位置参数个数(2026-09-21 七轮复审 P2)。
#
# 为什么需要: 旧实现纯靠"词法外观"判断 —— `-*` 跳过、NAME=value 跳过、纯数字跳过、其余
# 含非数字的词即视为二进制。而包装器的**选项取值**恰好长得像个路径(含非数字、不以 `-` 开头),
# 于是被当成二进制。实测: `env -u FOO /opt/custom/cloudflared` → 返回 `FOO`;
# `setpriv --reuid root ...` → `root`; `timeout --signal TERM 5 ...` → `TERM`;
# `taskset -c 0x1 ...` → `0x1`。期望路径随即变成一个**不存在的词**, `command -v` 失败 =>
# 回退 `$CF_BIN` => 我们自己的实例被判成"别人家"而永不杀 = 静默双实例。
# **更危险的一支**: 当被吞掉的取值本身是**已存在的绝对路径**时(实测 `env -C /tmp` → `/tmp`),
# `command -v /tmp` 成功 => 连 `$CF_BIN` 回退都不触发, 返回一个**确定的错路径**。
#
# 表内容**逐条来自 `--help` 实测**(coreutils 9.x), 不是猜的。两个陷阱项按实测处理:
#   · `env --ignore-signal/--default-signal/--block-signal` 是**可选参数**(`[=<SIG>]`):
#     实测 `env --ignore-signal TERM cmd` 会把 TERM 当成要执行的命令(rc=127), 只有
#     `=TERM` 形态才吃参数 ⇒ **不得**列进表里, 否则会吞掉真二进制。
#   · `taskset -c/--cpu-list` 是 **flag 而非取参选项**: 实测 `taskset --cpu-list=0-3` 报
#     "option '--cpu-list' doesn't allow an argument" ⇒ mask 是**前置位置参数**。
# 只匹配**完整 token**(用 `case " $tbl "` 精确匹配), 因此粘连形态(`-n5`/`-oL`/`-uFOO`/
# `--signal=TERM`)天然不命中、不消费下一个词 —— 它们本就自带取值。
# ---------------------------------------------------------------------------
_cf_opt_takes_value() { # <包装器名> <token> ; 0 = 该 token 的取值是下一个词
    local w="$1" t="$2" tbl=""
    case "$w" in
        env)     tbl='-C --chdir -f --file -u --unset -S --split-string -a --argv0' ;;
        nice)    tbl='-n --adjustment' ;;
        ionice)  tbl='-c --class -n --classdata -p --pid -P --pgid -u --uid' ;;
        setpriv) tbl='--ambient-caps --inh-caps --bounding-set --ruid --euid --rgid --egid --reuid --regid --groups --securebits --pdeathsig --ptracer --selinux-label --apparmor-profile --landlock-access --landlock-rule --seccomp-filter' ;;
        timeout) tbl='-k --kill-after -s --signal' ;;
        chrt)    tbl='-T --sched-runtime -P --sched-period -D --sched-deadline' ;;
        stdbuf)  tbl='-i --input -o --output -e --error' ;;
        exec)    tbl='-a' ;;
        *)       return 1 ;;
    esac
    case " $tbl " in
        *" $t "*) return 0 ;;
    esac
    return 1
}

# 链式包装器下必须按"**已见过的所有**包装器"判定取参选项, 不能只看当前这一个。
#
# 根因(2026-09-22 七轮复审实测): `_wrap` 若只记最新者, 则 `nohup env -C /tmp <bin>` 里
# `-C` 是 env 的取参选项, 但当前包装器是 `nohup`(表里没有 `-C`) => `/tmp` 被当成二进制返回。
# 反之若只记首个, 则 `nohup env -C /tmp <bin>` 里 `_wrap=nohup` 同样漏掉 `-C`。
# 两种"只记一个"都错, 故取并集: 任一已见包装器把该 token 当取参选项, 就消费它的取值。
# 实测(行为级驱动, 68 条用例): 并集版"第三值"(既非真二进制也非 $CF_BIN)为 0,
# 而只记首个/只记最新者各有残留。
_cf_opt_seen_takes_value() { # <已见包装器串> <token>
    local w
    for w in $1; do
        _cf_opt_takes_value "$w" "$2" && return 0
    done
    return 1
}

_cf_wrap_pos_count() { # <包装器名> -> 该包装器在真命令前有几个"前置位置参数"
    case "$1" in
        timeout|chrt|taskset) printf '%s' 1 ;;   # DURATION / PRIORITY / MASK
        *)                    printf '%s' 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# 从一段命令行文本里取出第一个"看起来是二进制"的词; 找不到返回 1。
#
# 四类东西必须跳过, 否则期望路径会指向包装器(或它的选项取值)而不是我们真正的二进制, 于是
# _cf_pids_owned 把我们**自己**的运行实例判成"别人家"而永不杀 —— 静默双实例(本函数族存在的
# 唯一理由):
#   1. 包装器本身: env/nice/ionice/setpriv/timeout/chrt/taskset/busybox/nohup/setsid/stdbuf/exec
#      (发行版生成的单元常写 ExecStart=/usr/bin/env cloudflared ...)
#   2. 包装器的**取参选项的取值**(`env -u FOO` 的 FOO)与**前置位置参数**
#      (`timeout 30` 的 30 / `taskset 0x1` 的 0x1)—— 见上方 _cf_opt_takes_value
#   3. 以 - 开头的选项本身, 或纯数字(nice 的优先级 / timeout 的秒数)
#   4. 环境赋值 NAME=value —— 2026-09-21 复审实测: `/usr/bin/env FOO=bar cloudflared tunnel run`
#      下旧实现返回 FOO=bar(它含非数字, 被判成二进制), 期望路径随即变成 FOO=bar。
# `sh -c '命令串'` 再往命令串里解析一次(限深度): 旧实现返回 /bin/sh, 同样导致双实例。
# 每个词都剥一层成对引号, 这样 command="..." 与 sh -c "..." 两种写法都不必特殊处理。
#
# 结构保持 2026-09-21 之前的形态(包装器白名单 + sh -c 数组切片递归 + NAME=value/纯数字跳过),
# 只在上面**叠加**选项感知, 不做整体重写 —— 实测把本函数重写成"包装器分支吞掉一切"的状态机
# 会让 `env sh -c "exec ..."` / `busybox sh -c "..."` / `nice -n 5 sh -c "..."` 返回 `sh`,
# 而 `command -v sh` 成功 => `$CF_BIN` 回退不触发 => 恰好制造本函数要防的静默双实例。
_cf_first_bin_word() {
    local text="$1" depth="${2:-0}" tok inner
    local -a _w
    read -ra _w <<< "$text"
    local _i _next _wrap="" _seen="" _wantarg=0 _pos=0
    for ((_i=0; _i<${#_w[@]}; _i++)); do
        tok="${_w[$_i]}"
        tok="${tok#\"}"; tok="${tok%\"}"
        tok="${tok#\'}"; tok="${tok%\'}"
        [ -n "$tok" ] || continue
        # 上一轮判定"这个选项的取值是下一个词" => 消费掉它, 不做任何判断
        if [ "$_wantarg" -eq 1 ]; then _wantarg=0; continue; fi
        case "${tok##*/}" in
            env|nice|ionice|setpriv|timeout|chrt|taskset|busybox|nohup|setsid|stdbuf|exec)
                # 链式包装器(`nohup env ...` / `timeout 30 env ...` / `busybox taskset ...`)下:
                #   · `_seen` 累积**每一个**已见包装器 —— 取参选项的判定取并集(见
                #     _cf_opt_seen_takes_value 上方的说明);
                #   · `_wrap` 记**最新**者, `_pos` 随它重算 —— 位置参数属于最近那个包装器
                #     (`timeout 30 env <bin>` 的 30 是 timeout 的, env 没有)。
                # 两者都不可退化为"只记一个": 只记首个会让 `nohup env -C /tmp <bin>` 漏判
                # `-C`(nohup 表里没有) => 返回 /tmp 这个**确定错路径**; 只记最新者会让
                # `nohup env -C /tmp <bin>` 同样漏判(最新者是 env, 但 `-C` 要靠 env 的表 ——
                # 实测该形态两者皆错, 故必须并集)。取 basename 是因为单元里常写绝对路径。
                _wrap="${tok##*/}"
                _seen="$_seen $_wrap"
                _pos=$(_cf_wrap_pos_count "$_wrap")
                continue ;;
            sh|bash|dash|ash|ksh|zsh)
                _next="${_w[$((_i+1))]:-}"
                if [ "$depth" -lt 2 ] && [ "$_next" = "-c" ] && [ -n "${_w[$((_i+2))]:-}" ]; then
                    # 必须取**整段**命令串(数组切片), 不能只取第 _i+2 个词。
                    # 根因: `read -ra` 的 IFS 切分**不感知引号** —— shell 的引号规则只在真正
                    # 解析命令时生效。实测 `sh -c "exec /opt/custom/cloudflared tunnel run"`
                    # 被切成 6 个词: sh | -c | "exec | /opt/custom/cloudflared | tunnel | run,
                    # 只取第 3 个词会拿到未闭合引号的 `"exec`, 递归词法解析失败 =>
                    # _cf_service_bin 回退 $CF_BIN => 我们自己的实例被判成"别人家"而永不杀
                    # = 静默双实例(本函数族存在的唯一理由)。
                    # 切片保留内层引号(实测), 递归里的逐词剥引号逻辑因此照常工作; 从 _i+2 起算
                    # (而非固定 2)使 `env sh -c "..."` 这类前置包装器也能正确定位。
                    # 边界(有意不修): 嵌套转义(`sh -c 'sh -c "..."'`)、变量展开、eval 等仍走
                    # "解析失败 => 回退 $CF_BIN" 的安全分支 —— 这些形态无法用词法解析正确处理,
                    # 而回退路径本身安全(不会把 /bin/sh 或 env 当二进制)。
                    inner="${_w[*]:$((_i+2))}"
                    _cf_first_bin_word "$inner" $((depth+1))
                    return $?
                fi
                printf '%s' "$tok"; return 0 ;;
        esac
        # 选项: 若任一**已见**包装器把它当取参选项, 则它的取值是下一个词。
        # 只在见过包装器之后才判定, 使本改动的影响面严格限于包装器命令行。
        if [ -n "$_seen" ] && [ "${tok#-}" != "$tok" ] && _cf_opt_seen_takes_value "$_seen" "$tok"; then
            # `env -S/--split-string` 的取值**本身就是一条命令串**(与 `sh -c` 同构, 空格分隔的
            # 一个词), 必须递归解析 —— 否则整串被当作"选项取值"吞掉, 函数返回 1,
            # `_cf_service_bin` 回退 `$CF_BIN`(二进制在非默认路径时归属判定即失效)。
            # 实测: 加此分支前 `env -S "<bin> tunnel run"` 返回 $CF_BIN, 加后返回 <bin>。
            case "${tok##*/}" in
                -S|--split-string)
                    if [ "$depth" -lt 2 ] && [ -n "${_w[$((_i+1))]:-}" ]; then
                        inner="${_w[*]:$((_i+1))}"
                        _cf_first_bin_word "$inner" $((depth+1))
                        return $?
                    fi ;;
            esac
            _wantarg=1
            continue
        fi
        case "$tok" in
            -*) continue ;;
        esac
        # 包装器在真命令前的前置位置参数(如 `timeout 30` 的 30)
        if [ "$_pos" -gt 0 ]; then _pos=$((_pos-1)); continue; fi
        case "$tok" in
            [A-Za-z_]*=*) continue ;;   # NAME=value => 环境赋值
            *[!0-9]*) printf '%s' "$tok"; return 0 ;;   # 含非数字 => 这就是二进制
            *) continue ;;                              # 纯数字 => 包装器的参数
        esac
    done
    return 1
}

_cf_service_bin() {
    local svcfile="$1" ln t bin
    [ -f "$svcfile" ] || { printf '%s' "$CF_BIN"; return 0; }
    while IFS= read -r ln || [ -n "$ln" ]; do
        t="${ln#"${ln%%[![:space:]]*}"}"
        case "$t" in
            ExecStart=*|cmd=*|command=*)
                t="${t#*=}"
                # 引号剥离交给 _cf_first_bin_word 逐词处理。**不能**在这里用
                # ${t%%\"*} 截断: 那会在第一个引号处砍掉整段命令串,
                # `sh -c "/usr/local/bin/cloudflared ..."` 于是只剩 `/bin/sh -c `,
                # 期望路径变成 /bin/sh => 静默双实例。
                bin=$(_cf_first_bin_word "$t") || bin=""
                if [ -n "$bin" ]; then
                    # 相对名(如 env cloudflared 里的 cloudflared)必须解析成绝对路径: 调用方
                    # 拿它比对 readlink /proc/<pid>/exe(恒为绝对路径), 裸名永远不匹配, 于是
                    # 我们自己的实例被判成"别人家"而永不杀 => 静默双实例。
                    # **解析不出来就回退 $CF_BIN, 绝不把裸名原样返回** —— 裸名同样永远
                    # 匹配不上 exe, 返回值等于"一个谁也匹配不到的期望路径", 比 CF_BIN 兜底
                    # 更糟(CF_BIN 至少是项目自己的安装点)。契约: 本函数只输出绝对路径或
                    # $CF_BIN。
                    case "$bin" in
                        /*) printf '%s' "$bin" ;;
                        *)  printf '%s' "$(command -v -- "$bin" 2>/dev/null || printf '%s' "$CF_BIN")" ;;
                    esac
                    return 0
                fi
                ;;
        esac
    done < "$svcfile"
    printf '%s' "$CF_BIN"
}

_cf_pids_owned() {
    local want p
    want=$(_cf_service_bin "$(_cf_unit_path)")
    [ -n "$want" ] || want="$CF_BIN"
    # 判据与 _cf_pids 同源(它就是 _cf_pids 加一层 exe 归属过滤), 避免两处各自演化出
    # "哪套扫描更全"的差异。
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        _cf_exe_owned "$p" "$want" && printf '%s\n' "$p"
    done <<< "$(_cf_pids)"
}

# 杀进程专用归属判定: 优先用严格版(读不到 exe => 拒绝)。
# _proc_exe_is 的 fail-open 是给**判活**的(见 00-common 的说明), 直接拿来杀进程会让
# "读不到 exe"时所有同名进程都被判成我们的 —— 限定 exe 的杀进程扫描就退化成它本该取代的
# 全机 comm 扫描, 可能 SIGKILL 掉用户自己装的 cloudflared。
#
# 三态返回码(2026-09-21 复审, 与 55-hysteria.sh 的 `_hysteria_proc_tree_has_bin` 同口径):
#   0 = 确认属于我们(exe 指向期望二进制)      => 可 kill
#   1 = **确认不属于**我们(exe 可读且不同)     => 不 kill, 归"他人"
#   2 = **无法确认**(严格版缺失, 即混装旧 lib) => 不 kill, 归"归属不明" + 告警
#
# 为什么必须是三态而非布尔: 第 4 步的三分类(确认我们的 / 确认他人的 / 归属不明)要求区分
# `1` 与 `2`。若把"无法确认"折进 `1`, 混装旧 lib 时会把**可能属于我们**的进程报成
# "非本脚本管理的 cloudflared 进程(未触碰)" —— 一句我们并不知道真假的断言, 正是该三分类
# 要消灭的错误信息。(项目已有同类先例: `_crontab_has_marker` 的 0/1/2。)
_cf_exe_owned() {
    if declare -F _proc_exe_is_strict >/dev/null 2>&1; then
        _proc_exe_is_strict "$1" "$2"
        return $?
    fi
    # 旧 lib 混装: 严格版不存在。**绝不退回宽松版** —— 那会让归属判定在杀进程路径上失效。
    _warn "lib 版本过旧(00-common 缺 _proc_exe_is_strict), 无法确认进程归属, 跳过"
    return 2
}

# ---------------------------------------------------------------------------
# 强力杀干净所有 cloudflared 进程(防止 PID 残留导致的进程泄漏)
# openrc 的 rc-service stop 经常杀不干净, 必须内核级 kill 兜底
# ---------------------------------------------------------------------------
_cf_kill_all() {
    local pids="" pid i
    # 严格归属判定不可用(混装旧 lib)的标志: 此时我们**无法确认**任何进程的归属,
    # 进程状态未被确认清理, 最终必须 return 1 —— 不能对调用方谎报"已清理干净"。
    local _cf_strict_missing=0

    # 1. 按实际 init 系统走正确的 stop，并等待进程真正退出
    case "$INIT_SYSTEM" in
        systemd)
            systemctl stop cloudflared 2>/dev/null || true
            # 等 systemd 真正把进程杀掉（最多等 15s，避免无限阻塞）
            i=0
            while systemctl is-active --quiet cloudflared 2>/dev/null && [ "$i" -lt 15 ]; do
                sleep 1; i=$((i+1))
            done
            ;;
        openrc)
            rc-service cloudflared stop 2>/dev/null || true
            sleep 2
            ;;
    esac

    # 2. 杀 PID 文件里的残留(PID reuse 防护: 只对**确属我们**的 pidfile PID 发信号)
    #
    # 2026-09-21 复审(P1): 这里的判据原本只有 `comm == cloudflared`, 而 comm 是**进程自报的
    # 名字**, 任何同名程序都能满足 —— 用户自己装的 cloudflared(发行版包)、另一个 x-ui 之类
    # 留下的实例, 只要 PID 被 pidfile 复用就会被我们 SIGTERM 掉。第 3 步(扫描)已经改用
    # exe 限定的 _cf_pids_owned, 唯独这条 pidfile 路径绕过了它, 于是"exe 限定"的防护在
    # 这条路径上形同不存在。实测复现: comm=cloudflared 但 exe=/usr/bin/bash 的进程被本分支
    # 杀掉。
    #
    # 归属判定统一走 _cf_exe_owned(优先严格版: 读不到 exe 一律拒绝), 拿不到确切归属就
    # 只告警、不发信号 —— 杀错一个别人的进程是不可逆的, 而 pidfile 残留最坏只是多告警一次。
    # pidfile 本身仍然照删: 它记录的是"上一次由我们写的 PID", 对调用方没有保留价值。
    local _cf_pf_want
    _cf_pf_want=$(_cf_service_bin "$(_cf_unit_path)")
    [ -n "$_cf_pf_want" ] || _cf_pf_want="$CF_BIN"
    for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
        local _pf_pid; _pf_pid=$(cat "$pf" 2>/dev/null)
        case "$_pf_pid" in
            ''|*[!0-9]*) ;;   # 空/非数字: 不是有效 PID, 只删文件
            *)
                # comm 预筛只是"看起来像"的快速过滤(避免对每个无关 PID 都去读 exe);
                # **决定权在 exe 归属判定**, 不能止步于 comm。
                if [ "$(cat "/proc/$_pf_pid/comm" 2>/dev/null)" = "cloudflared" ]; then
                    # 三态: 0=我们的(可 kill) / 1=确属他人 / 2=归属无法确认(严格版缺失)。
                    # 两种非 0 的处置不同 —— 2 必须与 1 分开报, 否则混装旧 lib 时会把
                    # "可能属于我们"的进程断言成"非本脚本管理的 cloudflared"。
                    local _cf_own_rc=0
                    _cf_exe_owned "$_pf_pid" "$_cf_pf_want" || _cf_own_rc=$?
                    case "$_cf_own_rc" in
                        0) kill "$_pf_pid" 2>/dev/null || true ;;
                        2) _cf_strict_missing=1
                           _warn "pidfile 记录的 PID $_pf_pid 归属无法确认(lib 版本过旧), 未发送信号"
                           _tip "请重跑 install.sh --update 同步模块后重试" ;;
                        *) _warn "pidfile 记录的 PID $_pf_pid 同名但归属无法确认(非本脚本的 cloudflared?), 未发送信号"
                           _tip "若该进程确实属于本服务, 请手动检查后处理" ;;
                    esac
                fi ;;
        esac
        rm -f "$pf" 2>/dev/null
    done

    # 3. 扫残留进程：先 SIGTERM（给 cloudflared 时间向 CF 边缘发送断开信号），等 3s，再 SIGKILL
    # R38(P2): 统一走 _cf_pids 家族, 不再用 pgrep/ps 两套逻辑。
    # 2026-09-20: 这里用 _cf_pids_owned(exe 限定到 $CF_BIN)而不是全机 comm 扫描 ——
    # 判活可以接受"把别人的隧道算成我们的", 杀进程不能(会 SIGKILL 掉用户自己装的
    # cloudflared)。无关的同名进程留给第 4 步只告警, 由用户判断。
    pids=$(_cf_pids_owned)
    if [ -n "$pids" ]; then
        for pid in $pids; do kill -15 "$pid" 2>/dev/null || true; done
        sleep 3
        # 再扫一次，还活着的直接 SIGKILL
        pids=$(_cf_pids_owned)
        for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
        sleep 1
    fi

    # 4. 最终确认
    pids=$(_cf_pids_owned)
    if [ -n "$pids" ]; then
        # R38(P2): 仍然返回 1 把"有残留"这个事实报给调用方, 但调用方语义变了 ——
        # _cf_restart 不再据此跳过 start(见那里的注释)。原先"残留即中止"会让 _cf_restart
        # 在已 stop+TERM+KILL **之后**直接返回而不 start, 一次普通的开关切换就把隧道彻底
        # 打停; 调用方随后 _cf_rollback_service 内部又走 _cf_restart, 同一残留进程导致再次
        # 不 start, 于是永久下线。残留可能是不可中断 IO 的进程。
        _warn "cloudflared 仍有残留进程: $pids"
        _tip "若隧道行为异常, 请手动确认这些进程是否应当存在"
        return 1
    fi
    # 严格归属判定不可用时 _cf_pids_owned 恒为空(它只认 rc=0), 上面这条"无残留"因此是
    # **假的**: 我们根本没能判定任何进程。这里显式复核一次, 并把标志置位以便最终 return 1。
    declare -F _proc_exe_is_strict >/dev/null 2>&1 || _cf_strict_missing=1
    # 有同名的**别人家**进程时只提示不报错: 它不是残留, 更不该被我们杀。
    local p others="" unclear="" _cf_want
    # 期望路径只解析一次: 旧写法在循环里每次都重读 unit 文件(_cf_service_bin 会打开并
    # 逐行扫描 service 文件), 进程多时是无谓的重复 IO。
    _cf_want=$(_cf_service_bin "$(_cf_unit_path)")
    [ -n "$_cf_want" ] || _cf_want="$CF_BIN"
    # 三分类, 不能用宽松的 _proc_exe_is 二分: 它在 exe 读不到时**放行**(fail-open 是判活
    # 语义), 于是"exe 读不到"的进程既不在严格版的残留列表里(严格版拒绝), 又被宽松版算成
    # "我们的", 两边都不提 —— 函数最后报"所有进程已清理"并返回 0, 而真正属于我们的孤儿
    # 进程还活着。这里显式把"归属不明"单列出来告警, 不再静默吞掉。
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        # **判据顺序至关重要**: 必须先直接看 readlink 能否读到 exe, 不能先问宽松版
        # _proc_exe_is —— 它在 exe 读不到时**放行**(fail-open 判活语义), 于是"exe 读不到"
        # 的进程会在第一步就被当成"我们的"而 continue, 下面的 unclear 分支永远走不到
        # (实测: 该分支曾是死代码), 函数最终报"所有进程已清理"并返回 0, 而真正属于我们、
        # 只是 exe 不可读的孤儿进程还活着 —— 正是这段代码要防的事。
        if ! readlink "/proc/$p/exe" >/dev/null 2>&1; then
            unclear="$unclear $p"          # exe 读不到 => 归属无法确认
            continue
        fi
        # exe 可读: 走归属判定(三态)。**必须用 case 区分 1 与 2** —— 旧实现用 `if ...; then
        # continue; fi; others=...`, 把"无法确认"(2, 混装旧 lib)与"确属他人"(1)压成同一
        # 结论, 于是把**可能属于我们**的进程断言成"非本脚本管理的 cloudflared(未触碰)"。
        local _cf_own_rc=0
        _cf_exe_owned "$p" "$_cf_want" || _cf_own_rc=$?
        case "$_cf_own_rc" in
            0) continue ;;                  # 确认是我们的
            2) unclear="$unclear $p"        # 归属无法确认(严格版缺失)
               _cf_strict_missing=1 ;;
            *) others="$others $p" ;;       # exe 可读但不匹配 => 确属他人
        esac
    done <<< "$(_cf_pids)"
    if [ -n "$others" ]; then
        _tip "检测到非本脚本管理的 cloudflared 进程:${others}(未触碰)"
    fi
    if [ -n "$unclear" ]; then
        # 这些进程可能是我们自己的(只是 /proc/<pid>/exe 读不到, 如加固的 /proc 挂载),
        # 不能宣称"已清理干净"。
        _warn "以下 cloudflared 进程归属无法确认(exe 不可读或 lib 版本过旧):${unclear}"
        _tip "它们可能仍属于本服务; 若隧道行为异常, 请手动确认"
    fi
    if [ "$_cf_strict_missing" -eq 1 ]; then
        # 归属判定降级: 进程状态**未被确认清理**, 不能对调用方谎报干净(_cf_restart 的
        # `|| _warn` 与 _uninstall_cloudflared 的 kill_rc 契约都依赖这个返回码的真实性)。
        _warn "lib 版本过旧(00-common 缺 _proc_exe_is_strict), 无法确认 cloudflared 进程归属"
        _tip "请重跑 install.sh --update 同步模块后重试"
        return 1
    fi
    _info "cloudflared 所有进程已清理"
    return 0
}

# 重启 cloudflared service(先杀干净所有, 等 CF 边缘回收旧 session, 再重新 start)
# 返回 start 命令的真实结果; 调用方仍应再做真实 liveness(_cf_is_running)确认
_cf_restart() {
    # R38(P2): 残留进程只告警、不再中止 start —— 见 _cf_kill_all 内的注释:
    # "残留即中止"会让一次普通的开关切换确定性地把隧道打停且无法自动恢复。
    # 双实例风险改由 start 后的 _cf_is_running 与显式告警交给用户判断。
    _cf_kill_all || _warn "cloudflared 停止流程未完全成功(有残留进程), 仍尝试启动"
    sleep 2   # 等 CF 边缘感知旧 connector 断开
    local rc=1
    case "$INIT_SYSTEM" in
        systemd) systemctl start cloudflared 2>/dev/null; rc=$? ;;
        openrc)  rc-service cloudflared start 2>/dev/null; rc=$? ;;
        *) return 1 ;;
    esac
    sleep 3   # 等新进程建立连接后再做后续检测
    return "$rc"
}

# 从 .bak 回滚 service 文件并尽力恢复服务: restore -> (systemd) reload -> restart。
# 供 token/开关/协议栈切换失败时统一使用。严格语义: restore -> (systemd) reload -> restart ->
# liveness, 全部成功才算回滚成功(rc 0); 任一步失败 rc 1——"service 文件恢复"≠"系统回到原状态"。
_cf_rollback_service() {
    local svcfile="$1"
    [ -f "${svcfile}.bak" ] || { _warn "无 ${svcfile}.bak 可回滚"; return 1; }
    if ! _svc_restore "$svcfile"; then
        _warn "回滚失败, 请手动检查 $svcfile"
        return 1
    fi
    if [ "$INIT_SYSTEM" = "systemd" ] && ! systemctl daemon-reload 2>/dev/null; then
        _error "回滚后 systemd daemon-reload 也失败: $svcfile"
        return 1
    fi
    if ! _cf_restart 2>/dev/null; then
        _error "回滚后 cloudflared 重启失败: $svcfile"
        return 1
    fi
    if ! _cf_is_running; then
        _error "回滚后 cloudflared 未运行: $svcfile"
        return 1
    fi
    return 0
}

# 判断 cloudflared 是否在运行(状态栏 + 诊断用)
_cf_is_running() {
    local anchor=""
    case "$INIT_SYSTEM" in
        systemd)
            # R38(M3): 用 MainPID 把判活绑定到本 unit 的主进程, 而不是"机器上有没有叫
            # cloudflared 的进程"。同时避免 is-active 在崩溃循环的 activating 窗口报成功。
            anchor=$(systemctl show -p MainPID --value cloudflared 2>/dev/null)
            if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ]; then
                _proc_named_under "$anchor" cloudflared && return 0
                return 1
            fi
            systemctl is-active --quiet cloudflared 2>/dev/null && _proc_any_named cloudflared
            return $?
            ;;
        *)
            # openrc/sysv/direct: 只认真实 cloudflared 进程, 不信 rc-service 的 started 文本
            # (supervise-daemon 崩溃循环时仍报 started)。优先按 pidfile 回溯进程树确认归属,
            # 拿不到 pidfile 时回退全机 comm 扫描(best-effort, 无法排除他人实例)。
            # R40 说明: 这里**故意**不像 xray 侧那样把兜底扫描限定到 exe==$CF_BIN。cloudflared
            # 二进制不由本脚本独占(用户可能先用发行版包/自己装过, 本脚本只接管 service 文件),
            # 一旦限定路径, 运行中的是 /usr/bin/cloudflared 时判活会恒假 —— 而 _cf_toggle /
            # 令牌切换都以"重启后 _cf_is_running 为真"作为事务成功条件, 假阴性会把本已生效的
            # 改动整体回滚。此处的假阳性(把别人的隧道算成我们的)只影响状态显示, 危害更小。
            local pf
            for pf in /run/cloudflared.pid /var/run/cloudflared.pid; do
                anchor=$(cat "$pf" 2>/dev/null) || continue
                if [[ "$anchor" =~ ^[0-9]+$ ]] && [ "$anchor" != "0" ] && [ -d "/proc/$anchor" ]; then
                    _proc_named_under "$anchor" cloudflared && return 0
                    # 不直接判死: 与 xray 侧 R40 同一条推理 —— pidfile 里的 PID 可能是陈旧
                    # 残留后被其他进程复用(见 _cf_kill_all 的 PID reuse 防护), 也可能因
                    # supervise-daemon→cloudflared 的 ppid 拓扑与预期不符而判不出归属。
                    # 此处假阴性会让 _cf_toggle/令牌切换把"重启后 _cf_is_running 为真"的
                    # 事务成功条件判假, 回滚本已生效的改动。anchor 判不出归属时继续按
                    # 全机 comm 扫描兜底(不限定 exe, 理由见上方 R40 说明)。
                fi
            done
            _proc_any_named cloudflared
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装 cloudflared(含 service install)
# ---------------------------------------------------------------------------
_install_cloudflared() {
    _install_cloudflared_bin || return 1
    echo
    _info "请粘贴 Cloudflare Tunnel Token"
    _tip "支持直接粘贴 CF 网页端给出的任何安装命令(Windows/Debian 均可), 脚本自动提取 ey... 令牌"
    read -rp "  粘贴: " input
    local token; token=$(_extract_token "$input")
    if [ -z "$token" ]; then
        _error "未能从输入中识别 Cloudflare Tunnel Token, 不会把原文写入 service 文件"
        return 1
    fi
    _cf_token_valid "$token" || { _error "Token 格式非法(仅接受 ey 开头的 base64/base64url 字符串)"; return 1; }

    # 默认设置(脚本安装默认: 自动更新 off, HTTP2 on, 协议栈 off)。
    # FLAG=yes: 本脚本管理的启动行显式携带全部管理标志(_cf_build_cmdline 依赖)
    CF_AUTOUPDATE="off"; CF_HTTP2="on"; CF_EDGE_IP="off"; CF_AUTOUPDATE_FLAG="yes"

    _info "调用 cloudflared service install..."
    if ! "$CF_BIN" service install "$token" 2>&1; then
        _error "cloudflared service install 失败"
        return 1
    fi
    # 官方命令生成的 unit 是 644/755, token 任何本地用户可读 —— 落地即收紧(F4);
    # 随后 _cf_write_service_line 的 _svc_commit 会再收一次, 这里覆盖"写入失败中止"的分支。
    case "$INIT_SYSTEM" in
        systemd) chmod 600 "$CF_UNIT_SYSTEMD" 2>/dev/null ;;
        openrc)  chmod 700 "$CF_UNIT_OPENRC" 2>/dev/null ;;
    esac
    # 官方命令生成的 service 行可能不含我们要的参数, 重组覆盖。写入失败必须中止(不写 state,
    # 否则 state 记录的参数与 service 实际内容不一致)。
    local cmdline
    cmdline=$(_cf_build_cmdline "$token") || { _error "无法构造安全的 cloudflared 启动行"; return 1; }
    if ! _cf_write_service_line "$cmdline"; then
        # 安装中止: 清掉 _svc_replace_line 可能留下的预修改快照, 否则它永远不会被消费
        # (_cf_rollback_service 只服务"已安装后的切换", 安装已中止)。
        local ab_svc
        ab_svc=$(_cf_unit_path)
        rm -f "${ab_svc}.bak" 2>/dev/null
        _error "service 配置写入失败, 安装中止"
        return 1
    fi
    # 重启失败同样中止(service 已写好但未启动, 不宣称安装完成)
    if ! _cf_restart; then
        _error "cloudflared 启动失败, 安装中止"
        return 1
    fi
    # 安装事务完成(write+restart 成功): 清理 _cf_write_service_line 留下的预修改快照
    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    rm -f "${svcfile}.bak"
    # 全部成功后持久化状态。F3: cf_token 不再落盘(docs/security-audit.md 修复计划 #4)——
    # 该 state 键全项目无读者(权威来源是 service 启动行, _read_cf_state 随时能解析),
    # 多存一份明文只是纯泄漏面; 卸载清理保留, 以覆盖历史版本遗留的文件。
    mkdir -p "$STATE_DIR"
    _state_set cf_autoupdate "$CF_AUTOUPDATE" || _warn "状态持久化失败(cf_autoupdate)"
    _state_set cf_http2 "$CF_HTTP2" || _warn "状态持久化失败(cf_http2)"
    _state_set cf_edge_ip "$CF_EDGE_IP" || _warn "状态持久化失败(cf_edge_ip)"
    # 验证 service 真正启动 (M5: token 非法时 service install 仍成功, 但服务无法运行;
    # 此时配置/state 已一致, 仅提示用户检查 token, 不把"未运行"误报为安装失败)
    if _cf_is_running; then
        _success "cloudflared 安装完成(已注册服务并开机自启)"
    else
        _warn "cloudflared 已安装但服务未运行, 请检查 token 是否正确"
    fi
    _tip "已默认关闭 cloudflared 自动更新、开启 HTTP2 连接（可在 cloudflared 管理中修改）"
    _tip "隧道路由请在 Cloudflare Web 端配置, 本脚本不写 config.yml"
}

# ---------------------------------------------------------------------------
# 卸载 cloudflared(彻底清)
# ---------------------------------------------------------------------------
_uninstall_cloudflared() {
    # 2026-09-12 三审(L1): /etc/cloudflared 凭据清理必须放在二进制存在性判断之前 ——
    # 用户可能只删了二进制(或二进制损坏不可执行), 此时提前 return 会把 token 留在盘上(RT-3 同源)。
    # 只删 token 文件 + 仅在目录已空时 rmdir —— 手工配置的 config.yml 永不被触碰。
    if [ -f /etc/cloudflared/token ]; then
        rm -f /etc/cloudflared/token
    fi
    rmdir /etc/cloudflared 2>/dev/null || true
    if [ -x "$CF_BIN" ]; then
        _info "卸载 cloudflared..."
        "$CF_BIN" service uninstall 2>/dev/null || true
    else
        _warn "cloudflared 二进制不存在(仅清理残留配置)"
    fi
    # 确保进程彻底死掉再删文件（替换原来的裸 stop）。
    # 2026-09-21 复审(P1): 返回值原本被丢弃 —— _cf_kill_all 在"仍有残留进程"时返回 1,
    # 而本函数随后照样删二进制/unit 并报"已卸载"并返回 0。这直接违反 _uninstall_menu [3] 的
    # 契约(它消费 cf_rc 并据此提示"卸载未完全成功"), 用户会看到"卸载完成"而进程还活着。
    # 实测: 把 _cf_kill_all 打桩成 return 1, 本函数仍返回 0。
    # 残留进程仍必须继续走完文件清理(半途 return 会留下指向已删二进制的孤儿 unit), 但
    # 最终返回值要如实反映"进程没清干净"。
    local kill_rc=0
    _cf_kill_all || kill_rc=$?
    # service 单元/pidfile 的清理**必须无条件执行**: 二进制缺失时提前 return 会留下一份
    # 指向不存在二进制的孤儿 unit(systemd 每次开机都会尝试拉起并失败)。
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable cloudflared 2>/dev/null || true
            rm -f "$CF_UNIT_SYSTEMD" "${CF_UNIT_SYSTEMD}.bak"
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            rc-update del cloudflared default 2>/dev/null || true
            rm -f "$CF_UNIT_OPENRC" "${CF_UNIT_OPENRC}.bak"
            ;;
    esac
    rm -f /run/cloudflared.pid /var/run/cloudflared.pid 2>/dev/null
    rm -f "$CF_BIN"
    rm -f "$CF_STATE_AUTOUPDATE" "$CF_STATE_HTTP2" "$CF_STATE_EDGE_IP" "$CF_STATE_TOKEN" "$STATE_DIR/cf_ipv6"
    if [ "$kill_rc" -ne 0 ]; then
        _error "cloudflared 文件与状态已清除, 但仍有残留进程未能停止"
        _tip "请用 ps 确认 cloudflared 进程并手动结束, 否则它仍占用隧道连接"
        return 1
    fi
    _success "cloudflared 已卸载(二进制/服务/状态已清除)"
}

# ---------------------------------------------------------------------------
# 切换/补录令牌
# 策略: 优先"只替换 token"保留原 service 行其他参数(不破坏手动装的好配置);
#       service 文件不存在时才用 cloudflared service install 注册。
# 绝不在已装状态下重复 service install(会冲突报错)。
# ---------------------------------------------------------------------------
_cf_switch_token() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    if [ -n "$CF_CUR_TOKEN" ]; then
        echo -e "  当前令牌: $(_cf_mask_token "$CF_CUR_TOKEN")"
    else
        _warn "未能从 service 文件读取令牌(可能是手动安装或格式不同)"
    fi
    read -rp "  粘贴新令牌(或 CF 安装命令): " input
    local token; token=$(_extract_token "$input")
    [ -n "$token" ] || { _warn "未能从输入中识别新令牌, 取消"; return 1; }
    _cf_token_valid "$token" || { _error "新 Token 格式非法, 未修改 service"; return 1; }

    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac

    if [ ! -f "$svcfile" ]; then
        # service 文件不存在: 用官方命令注册一次。install 失败必须中止, 不能继续往下走成"假成功"
        _info "service 文件不存在, 调用 cloudflared service install 注册..."
        if ! "$CF_BIN" service install "$token" 2>/dev/null; then
            _error "cloudflared service install 失败"
            return 1
        fi
        # 注册后若文件出现, 再用只换 token 方式确保 token 正确(替换失败同样中止)
        if [ -f "$svcfile" ]; then
            _cf_replace_token_in_service "" "$token" || {
                _error "service install 成功但 token 替换失败"
                return 1
            }
        else
            _error "cloudflared service install 成功但未生成 service 文件: $svcfile"
            return 1
        fi
    else
        # service 文件已存在: 只换 token, 保留原参数(关键: 不破坏手动装的好配置)
        _info "保留原有启动参数, 仅替换令牌..."
        _cf_replace_token_in_service "$CF_CUR_TOKEN" "$token" || {
            _error "替换令牌失败"
            return 1
        }
    fi

    # 重启: 先杀干净所有, 等 CF 边缘回收旧 session。restart 与 liveness 共同构成成功:
    # restart 命令失败即中止(与 _install_cloudflared 同一语义), 避免"重启失败却宣称令牌已更新"。
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚 service 文件..."
        if _cf_rollback_service "$svcfile"; then
            _error "令牌替换后重启失败, 已回滚到原令牌。请检查新令牌是否正确"
        else
            _error "令牌替换后重启失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    local restarted_ok="no"
    # R38(M3): 统一走 _cf_is_running —— 它现在把判活绑定到 unit MainPID / pidfile 进程树,
    # 比裸 is-active 更严(is-active 在崩溃循环的 activating 窗口也会返回 0)
    _cf_is_running && restarted_ok="yes"
    if [ "$restarted_ok" = "no" ]; then
        _warn "重启后服务未运行, 回滚 service 文件..."
        # R38(P1): 回滚结果必须如实反映——原写法在 _cf_rollback_service 返回 1 时仍无条件
        # 打印"已回滚", 与紧邻的"回滚失败"自相矛盾, 而此时 .bak 已被 _svc_restore 消费删除。
        if _cf_rollback_service "$svcfile"; then
            _error "令牌替换后服务异常, 已回滚到原令牌。请检查新令牌是否正确"
        else
            _error "令牌替换后服务异常, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照
    # F3: 不再把新令牌写进 state/cf_token(见 _install_cloudflared 同处注释)
    _success "令牌已更新, cloudflared 已重启(隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# 切换 2 开关(autoupdate|http2): 读取当前状态, 反转目标开关, 用 _cf_build_cmdline 重组整行写回
# (从头重建保证参数顺序: 全局标志 tunnel 连接标志 run --token)
# 协议栈为四选一, 走 _cf_set_edge_ip(见下)
# ---------------------------------------------------------------------------
_cf_toggle() {
    local key="$1"
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    if [ -z "$CF_CUR_TOKEN" ]; then
        _warn "未能读取令牌(可能是手动安装), 请先 [1] 补录令牌后再切换开关"
        return 1
    fi
    _cf_token_valid "$CF_CUR_TOKEN" || { _error "service 中的 Token 格式非法, 请先重新录入令牌"; return 1; }
    local cur
    case "$key" in
        # autoupdate 的"当前值"必须用与菜单显示同一个判据。启动行没写标志时 cloudflared
        # 缺省是开(24h), 菜单据此显示"开"; 若这里改用 CF_CUR_AUTOUPDATE(此时是 off),
        # 按一下会算出 new=on 并写出 `--autoupdate-freq 24h0m0s` —— 行为与显示一致(仍是开),
        # 用户看到的是"按了没反应"。
        autoupdate) cur=$(_cf_autoupdate_effective) ;;
        http2)      cur="${CF_CUR_HTTP2:-on}" ;;
    esac
    local new; [ "$cur" = "on" ] && new="off" || new="on"

    CF_AUTOUPDATE="${CF_CUR_AUTOUPDATE}"; CF_HTTP2="${CF_CUR_HTTP2}"; CF_EDGE_IP="${CF_CUR_EDGE_IP}"
    CF_AUTOUPDATE_FLAG="${CF_CUR_AUTOUPDATE_FLAG:-yes}"
    case "$key" in
        autoupdate)
            CF_AUTOUPDATE="$new"
            # 用户显式切换 autoupdate 本身 => 目标状态必须落成标志(含从"无标志"切到关)
            CF_AUTOUPDATE_FLAG="yes"
            ;;
        http2)      CF_HTTP2="$new" ;;
    esac
    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    local cmdline
    cmdline=$(_cf_build_cmdline "$CF_CUR_TOKEN") || return 1
    _cf_write_service_line "$cmdline" || return 1

    # restart 与 liveness 共同构成成功(与 _cf_switch_token 同一语义), 失败即回滚
    # R38(P1): 回滚消息按真实结果分支, 不再在回滚失败时也宣称"已回滚到原状态"
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "${key} 切换失败, 已回滚到原状态"
        else
            _error "${key} 切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    if ! _cf_is_running; then
        _warn "切换后服务未运行, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "${key} 切换失败, 已回滚到原状态"
        else
            _error "${key} 切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照(.bak 是"最近一次修改前"的瞬态)
    _state_set "cf_$key" "$new" || _warn "状态持久化失败(cf_$key)"
    _success "${key} 已切换为 ${new}(cloudflared 已重启, 隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# 设置协议栈 (--edge-ip-version 4|6|auto|关)
# 四选一: IPv4 / IPv6 / Auto / 关(不写参数, 交 cloudflared 默认)
# ---------------------------------------------------------------------------
_cf_set_edge_ip() {
    [ -x "$CF_BIN" ] || { _warn "cloudflared 未安装, 请先安装"; return 1; }
    _read_cf_state
    if [ -z "$CF_CUR_TOKEN" ]; then
        _warn "未能读取令牌(可能是手动安装), 请先 [1] 补录令牌后再切换协议栈"
        return 1
    fi
    _cf_token_valid "$CF_CUR_TOKEN" || { _error "service 中的 Token 格式非法, 请先重新录入令牌"; return 1; }
    local cur="${CF_CUR_EDGE_IP:-off}"
    echo
    echo -e "  ${CYAN}【切换协议栈】${NC}"
    echo -e "  当前: $(_cf_edge_ip_disp "$cur")"
    echo
    echo -e "  ${GREEN}[1]${NC} IPv4 (--edge-ip-version 4)"
    echo -e "  ${GREEN}[2]${NC} IPv6 (--edge-ip-version 6)"
    echo -e "  ${GREEN}[3]${NC} Auto (--edge-ip-version auto)"
    echo -e "  ${GREEN}[4]${NC} 关   (不写参数, 使用 cloudflared 默认)"
    echo -e "  ${GREEN}[0]${NC} 取消"
    local choice
    read -rp "  请选择: " choice
    local val
    case "$choice" in
        1) val="4" ;;
        2) val="6" ;;
        3) val="auto" ;;
        4) val="off" ;;
        0) return 0 ;;
        *) _warn "无效"; return 1 ;;
    esac
    if [ "$val" = "$cur" ]; then
        _info "协议栈已是 $(_cf_edge_ip_label "$val")，无需切换"
        return 0
    fi

    CF_AUTOUPDATE="${CF_CUR_AUTOUPDATE}"; CF_HTTP2="${CF_CUR_HTTP2}"; CF_EDGE_IP="$val"
    CF_AUTOUPDATE_FLAG="${CF_CUR_AUTOUPDATE_FLAG:-yes}"   # F6: 保留原行对 autoupdate 的管理方式
    local cmdline
    cmdline=$(_cf_build_cmdline "$CF_CUR_TOKEN") || return 1
    _cf_write_service_line "$cmdline" || return 1

    local svcfile
    case "$INIT_SYSTEM" in systemd) svcfile="$CF_UNIT_SYSTEMD" ;; *) svcfile="$CF_UNIT_OPENRC" ;; esac
    # restart 与 liveness 共同构成成功(与 _cf_switch_token 同一语义), 失败即回滚
    # R38(P1): 回滚消息按真实结果分支
    if ! _cf_restart; then
        _warn "重启 cloudflared 失败, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "协议栈切换失败, 已回滚到原状态"
        else
            _error "协议栈切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    if ! _cf_is_running; then
        _warn "切换后服务未运行, 回滚..."
        if _cf_rollback_service "$svcfile"; then
            _error "协议栈切换失败, 已回滚到原状态"
        else
            _error "协议栈切换失败, 且回滚未完成: cloudflared 当前可能未运行, 请手动检查 $svcfile"
        fi
        return 1
    fi
    rm -f "${svcfile}.bak"   # 事务成功, 清理预修改快照
    _state_set cf_edge_ip "$val" || _warn "状态持久化失败(cf_edge_ip)"
    _success "协议栈已切换为 $(_cf_edge_ip_label "$val")(cloudflared 已重启, 隧道短暂中断)"
}

# ---------------------------------------------------------------------------
# cloudflared 子菜单
# ---------------------------------------------------------------------------
_cloudflared_menu() {
    local choice
    while true; do
        clear
        echo
        echo -e "  ${CYAN}【cloudflared 管理】${NC}"
        local installed="no"
        [ -x "$CF_BIN" ] && installed="yes"
        if [ "$installed" = "yes" ]; then
            _read_cf_state
            local tok_disp
            if [ -n "$CF_CUR_TOKEN" ]; then
                tok_disp=$(_cf_mask_token "$CF_CUR_TOKEN")
            else
                tok_disp="${YELLOW}未读取(需补录)${NC}"
            fi
            # F6: 启动行未显式写 autoupdate 标志时, cloudflared 缺省是开启(24h),
            # 状态显示必须反映真实行为而不是"没有标志=关"。判据与 _cf_toggle 共用
            # _cf_autoupdate_effective —— 两处各自解释同一个"缺失"会把切换基线算错。
            local auto_disp auto_suffix=""
            auto_disp=$(_cf_autoupdate_effective)
            if [ "${CF_CUR_AUTOUPDATE_FLAG:-yes}" = "no" ]; then
                auto_suffix="(启动行无标志, 默认开)"
            fi
            echo -e "  状态: ${GREEN}已安装${NC}  令牌: ${tok_disp}"
            echo -e "  自动更新: $(_cf_onoff "$auto_disp")${auto_suffix}  HTTP/2: $(_cf_onoff "${CF_CUR_HTTP2:-on}")  协议栈: $(_cf_edge_ip_disp "${CF_CUR_EDGE_IP:-off}")"
            echo
            if [ -n "$CF_CUR_TOKEN" ]; then
                echo -e "  ${GREEN}[1]${NC} 切换令牌"
            else
                echo -e "  ${GREEN}[1]${NC} 补录令牌(手动安装的 cloudflared)"
                # 管理范围声明: 本脚本只认启动行里的 `--token <值>`, 改写/切换都只针对它。
                # token-file / Environment=TUNNEL_TOKEN 等官方形态无法安全重写(会破坏用户原配置),
                # 故必须显式说明, 不能让用户以为"支持 cloudflared 令牌"就等于支持全部形态。
                echo -e "  ${YELLOW}仅管理启动行中的 --token <值>; --token-file / Environment=TUNNEL_TOKEN 需手动维护${NC}"
            fi
            echo -e "  ${GREEN}[2]${NC} 切换 自动更新 (当前 $(_cf_onoff "$auto_disp"))"
            echo -e "  ${GREEN}[3]${NC} 切换 HTTP/2      (当前 $(_cf_onoff "${CF_CUR_HTTP2:-on}"))"
            echo -e "  ${GREEN}[4]${NC} 切换 协议栈      (当前 $(_cf_edge_ip_disp "${CF_CUR_EDGE_IP:-off}"))"
            echo -e "  ${GREEN}[5]${NC} 重启 cloudflared"
            echo -e "  ${GREEN}[6]${NC} 诊断(查看 service 文件内容)"
            echo -e "  ${GREEN}[9]${NC} 卸载"
        else
            echo -e "  状态: ${RED}未安装${NC}"
            echo
            echo -e "  ${GREEN}[1]${NC} 安装 cloudflared"
        fi
        echo -e "  ${GREEN}[0]${NC} 返回"
        read -rp "  请选择: " choice || return 0
        case "$choice" in
            1) if [ "$installed" = "yes" ]; then _cf_switch_token; else _install_cloudflared; fi ;;
            2) _cf_toggle autoupdate ;;
            3) _cf_toggle http2 ;;
            4) _cf_set_edge_ip ;;
            5) _cf_restart; if _cf_is_running; then _success "已重启"; else _warn "重启后服务未运行, 请检查状态"; fi ;;
            6) _cf_diagnose ;;
            9) _uninstall_cloudflared ;;
            0) return ;;
            *) _warn "无效" ;;
        esac
        _press_any_key
    done
}

# 诊断: 显示 service 文件内容 + 解析结果, 便于排查"读不出 token"
_cf_diagnose() {
    echo
    echo -e "  ${CYAN}【cloudflared 诊断】${NC}"
    local svcfile
    case "$INIT_SYSTEM" in
        systemd) svcfile="$CF_UNIT_SYSTEMD" ;;
        openrc)  svcfile="$CF_UNIT_OPENRC" ;;
        *)       svcfile="$CF_UNIT_SYSTEMD" ;;
    esac
    echo -e "  service 文件: ${svcfile}"
    if [ -f "$svcfile" ]; then
        echo -e "  权限: $(ls -la "$svcfile" | awk '{print $1}')"
        # R39(P2): token 打屏必须掩码 —— 诊断输出常被用户直接粘贴到 issue/群里,
        # 明文 token 等同于隧道凭据泄漏。与菜单里的展示口径一致(首 12 + 末 4)。
        if [ -n "$CF_CUR_TOKEN" ]; then
            echo -e "  解析到的 token: $(_cf_mask_token "$CF_CUR_TOKEN") (长度 ${#CF_CUR_TOKEN})"
        else
            echo -e "  解析到的 token: (空)"
        fi
        echo -e "  解析到的开关: auto=${CF_CUR_AUTOUPDATE} http2=${CF_CUR_HTTP2} 协议栈=${CF_CUR_EDGE_IP}"
        echo
        echo -e "  ${CYAN}--- 文件内容(token 已掩码) ---${NC}"
        # 共享 quote-aware redactor: 无法安全解析的 token 行整个隐藏, 绝不原样放行。
        local dl
        while IFS= read -r dl || [ -n "$dl" ]; do
            _cf_redact_service_line "$dl"
        done < "$svcfile"
        echo -e "  ${CYAN}--- end ---${NC}"
        echo
        _tip "以上 token 已掩码, 可直接反馈给开发者"
    else
        _warn "service 文件不存在"
    fi
}

_cf_onoff() {
    [ "$1" = "on" ] && echo "${GREEN}● 开${NC}" || echo "${RED}○ 关${NC}"
}

# 协议栈显示: 带颜色 (菜单/状态栏)
_cf_edge_ip_disp() {
    case "$1" in
        4)    echo "${GREEN}● IPv4${NC}" ;;
        6)    echo "${GREEN}● IPv6${NC}" ;;
        auto) echo "${GREEN}● Auto${NC}" ;;
        *)    echo "${RED}○ 关${NC}" ;;
    esac
}

# 协议栈纯文本标签(日志/提示用, 不带颜色)
_cf_edge_ip_label() {
    case "$1" in
        4) echo "IPv4" ;;
        6) echo "IPv6" ;;
        auto) echo "Auto" ;;
        *) echo "关" ;;
    esac
}
