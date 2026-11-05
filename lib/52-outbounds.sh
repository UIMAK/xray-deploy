#!/usr/bin/env bash

# 出口分享链接导入：链接解析由 support/outbound_link.py 完成，本模块只保留
# 批量输入、tag 交互和配置提交；解析器只读链接并返回 JSON，不碰配置或服务。

_OB_SUPPORTED_TEXT='Hysteria2/Hy2、VLESS、VMess、Trojan、Shadowsocks、SOCKS'
_OB_MAX_TAG_LENGTH=128
_OB_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/support"

_OB_ERR=''
_OB_INPUTS=()
_OB_PREFETCH=''
_OB_PREFETCH_SET=false
_OB_BATCH='[]'
_OB_COUNT=0
_OB_SKIPPED=0
_OB_DEFAULT_TAGS=()
_OB_PROTOCOLS=()
_OB_SERVERS=()
_OB_PORTS=()
_OB_ACCEPTED_TAGS=()
_OB_TAG_INPUT=''

_outbound_fail() {
    _OB_ERR="$*"
    return 1
}

_outbound_python() {
    command -v python3 2>/dev/null
}

# 一次调用处理整批链接：Python 只返回数据，失败时 stdout 仍是可读的 error JSON。
_outbound_parse_batch() {
    if [ "$#" -eq 0 ]; then
        _outbound_fail "分享链接不能为空"
        return 1
    fi
    local text="$1" arg result rc python error index why
    shift || true
    for arg in "$@"; do text+=$'\n'"$arg"; done

    _OB_BATCH='[]'
    _OB_COUNT=0
    _OB_SKIPPED=0
    _OB_DEFAULT_TAGS=()
    _OB_PROTOCOLS=()
    _OB_SERVERS=()
    _OB_PORTS=()
    _OB_ERR=''

    python=$(_outbound_python) || {
        _outbound_fail "缺少 python3, 无法解析分享链接"
        return 1
    }
    [ -f "$_OB_SUPPORT_DIR/outbound_link.py" ] || {
        _outbound_fail "缺少解析器文件: $_OB_SUPPORT_DIR/outbound_link.py"
        return 1
    }

    result=$(printf '%s' "$text" | "$python" "$_OB_SUPPORT_DIR/outbound_link.py" --batch)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        error=$(printf '%s' "$result" | jq -r '.error // empty' 2>/dev/null) || error=''
        _outbound_fail "${error:-分享链接解析失败}"
        return 1
    fi

    _OB_BATCH=$(printf '%s' "$result" | jq -c '.links') || {
        _outbound_fail "解析结果无效"
        return 1
    }
    _OB_COUNT=$(printf '%s' "$result" | jq -r '.links | length') || {
        _outbound_fail "解析结果无效"
        return 1
    }
    _OB_SKIPPED=$(printf '%s' "$result" | jq -r '.skipped | length') || {
        _outbound_fail "解析结果无效"
        return 1
    }
    mapfile -t _OB_DEFAULT_TAGS < <(printf '%s' "$result" | jq -r '.links[].tag')
    mapfile -t _OB_PROTOCOLS < <(printf '%s' "$result" | jq -r '.links[].protocol')
    mapfile -t _OB_SERVERS < <(printf '%s' "$result" | jq -r '.links[].server')
    mapfile -t _OB_PORTS < <(printf '%s' "$result" | jq -r '.links[].port')

    if [ "$_OB_SKIPPED" -gt 0 ]; then
        while IFS=$'\t' read -r index why; do
            [ -n "$index" ] || continue
            _warn "已跳过第 ${index} 条: ${why}"
        done < <(printf '%s' "$result" | jq -r '.skipped[] | [.index, .error] | @tsv')
        _warn "已跳过 ${_OB_SKIPPED} 条无法解析的链接"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# tag 与提交
# ---------------------------------------------------------------------------

_outbound_tag_valid() {
    local tag="$1"
    [ -n "$tag" ] || { _outbound_fail "出口 tag 不能为空"; return 1; }
    [ "${#tag}" -le "$_OB_MAX_TAG_LENGTH" ] || {
        _outbound_fail "出口 tag 最长 ${_OB_MAX_TAG_LENGTH} 个字符"
        return 1
    }
    case "$tag" in
        */*|*\\*) _outbound_fail "出口 tag 不能包含 / 或 \\"; return 1 ;;
        [[:space:]]*|*[[:space:]]) _outbound_fail "出口 tag 首尾不能有空白"; return 1 ;;
    esac
    if printf '%s' "$tag" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        _outbound_fail "出口 tag 不能包含控制字符"
        return 1
    fi
    case "$tag" in
        direct|block|warp) _outbound_fail "出口 tag 是保留名称: $tag"; return 1 ;;
    esac
}

_outbound_tag_exists() {
    local tag="$1"
    _config_jq -e --arg t "$tag" \
        '[(.inbounds[]?.tag // empty), (.outbounds[]?.tag // empty)] | index($t) != null' \
        >/dev/null 2>&1
}

_outbound_accept_tag() {
    local tag="$1" seen
    _outbound_tag_valid "$tag" || return 1
    if _outbound_tag_exists "$tag"; then
        _outbound_fail "出口 tag 已存在: $tag，请换一个"
        return 1
    fi
    if [ ${#_OB_ACCEPTED_TAGS[@]} -gt 0 ]; then
        for seen in "${_OB_ACCEPTED_TAGS[@]}"; do
            if [ "$seen" = "$tag" ]; then
                _outbound_fail "本次添加的出口 tag 重复: $tag，请换一个"
                return 1
            fi
        done
    fi
}

_outbound_read_link_inputs() {   # <first line>
    local line
    _OB_INPUTS=("$1")
    _OB_PREFETCH=''
    _OB_PREFETCH_SET=false
    while IFS= read -r -t 1 line; do
        line="${line%$'\r'}"
        if [ -n "$line" ]; then
            if [[ "$line" == *"://"* ]]; then
                _OB_INPUTS+=("$line")
            else
                _OB_PREFETCH="$line"
                _OB_PREFETCH_SET=true
                return 0
            fi
        else
            _OB_PREFETCH_SET=true
            return 0
        fi
    done
    return 0
}

_outbound_prompt_tag() {
    local label="$1" default="$2" input
    while :; do
        if [ "$_OB_PREFETCH_SET" = true ]; then
            input="$_OB_PREFETCH"
            _OB_PREFETCH=''
            _OB_PREFETCH_SET=false
            input="${input%$'\r'}"
            [ -n "$input" ] || input="$default"
        elif [ -n "$default" ]; then
            read -e -r -p "  ${label} (默认 ${default}): " input || {
                _warn "输入已结束, 已取消"
                return 1
            }
            input="${input%$'\r'}"
            input="${input:-$default}"
        else
            read -e -r -p "  ${label} (链接没有可用 tag, 必须输入): " input || {
                _warn "输入已结束, 已取消"
                return 1
            }
            input="${input%$'\r'}"
        fi
        if _outbound_accept_tag "$input"; then
            _OB_TAG_INPUT="$input"
            return 0
        fi
        _error "$_OB_ERR"
    done
}

_outbound_commit() {
    local obs="$1"
    printf '%s' "$obs" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || {
        _error "候选出口无效"
        return 1
    }
    _mutate_config --argjson obs "$obs" '
        . as $cfg
        | ($cfg.outbounds // []) as $cur
        | if ($cur | type) != "array" then error("当前配置的 outbounds 不是数组")
          else
            ($obs | map(.tag)) as $new
            | ([ $cfg.inbounds[]?.tag, $cur[]?.tag ] | map(select(. != null))) as $used
            | if ($new | length) != ($new | unique | length) then error("本次出口 tag 重复")
              elif any($new[]; . as $t | $used | index($t) != null) then error("出口 tag 已被占用")
              else .outbounds = ($cur + $obs)
              end
          end
    '
}

_outbound_add_prompt() {
    clear
    echo
    echo -e "  ${CYAN}【添加出口 — 导入分享链接】${NC}"
    _info "支持 ${_OB_SUPPORTED_TEXT}"
    _info "识别后只追加 outbounds，不修改默认路由或现有分流规则"
    _info "一次可粘贴一条或多条链接，也支持 v2rayN 的 Base64 整段"
    [ -x "$XRAY_BIN" ] || {
        _error "Xray 未安装, 请先到主菜单的 [Xray 核心管理] 安装核心"
        return 1
    }
    _config_present || { _error "配置不存在, 请先初始化配置或添加节点"; return 1; }
    _config_jq -e 'type == "object"' >/dev/null 2>&1 || {
        _error "当前配置无法解析, 拒绝添加出口"
        return 1
    }

    local first
    read -e -r -p "  分享链接: " first || { _warn "输入已结束, 已取消"; return 1; }
    first="${first%$'\r'}"
    _outbound_read_link_inputs "$first"
    _outbound_parse_batch "${_OB_INPUTS[@]}" || {
        _OB_PREFETCH=''
        _OB_PREFETCH_SET=false
        _error "$_OB_ERR"
        return 1
    }

    local i count="$_OB_COUNT"
    _info "已识别 ${count} 个出口"
    for ((i = 0; i < count; i++)); do
        _info "[$((i + 1))/${count}] ${_OB_PROTOCOLS[$i]}: ${_OB_SERVERS[$i]}:${_OB_PORTS[$i]}"
    done

    _OB_ACCEPTED_TAGS=()
    local -a tags=()
    local label
    for ((i = 0; i < count; i++)); do
        label='出口 tag'
        [ "$count" -eq 1 ] || label="出口 tag [$((i + 1))/${count}]"
        _outbound_prompt_tag "$label" "${_OB_DEFAULT_TAGS[$i]}" || return 1
        tags+=("$_OB_TAG_INPUT")
        _OB_ACCEPTED_TAGS+=("$_OB_TAG_INPUT")
    done

    local tags_json joined outbounds_json
    tags_json=$(jq -cn '$ARGS.positional' --args "${tags[@]}") || {
        _error "构造出口 tag 列表失败"
        return 1
    }
    outbounds_json=$(jq -cn --argjson batch "$_OB_BATCH" --argjson tags "$tags_json" '
        [range(0; ($batch | length)) as $i | $batch[$i].outbound + {tag:$tags[$i]}]
    ') || { _error "构造出口失败"; return 1; }

    joined=$(printf '%s, ' "${tags[@]}")
    joined="${joined%, }"
    if [ "$count" -eq 1 ]; then
        _info "将添加出口: ${joined}；不会修改默认路由或分流规则"
    else
        _info "将添加 ${count} 个出口: ${joined}；不会修改默认路由或分流规则"
    fi
    local ans
    read -e -r -p "  确认添加? [y/N]: " ans || {
        _warn "输入已结束, 已取消"
        return 1
    }
    ans="${ans%$'\r'}"
    case "$ans" in
        y|Y) ;;
        *) _info "已取消"; return 0 ;;
    esac

    _outbound_commit "$outbounds_json" || {
        _error "出口写入失败, 配置未改变"
        return 1
    }
    if [ "$count" -eq 1 ]; then
        _success "出口已添加: ${joined}；routing 未改变"
    else
        _success "已添加 ${count} 个出口: ${joined}；routing 未改变"
    fi
}
