#!/bin/bash
# =============================================================================
# install.sh — xray-deploy 一键安装/更新入口
# 用法:
#   首次安装: bash <(curl -sL <raw_url>/install.sh)
#   更新脚本: bash <(curl -sL <raw_url>/install.sh) --update
#   更新(不启动菜单): bash <(curl -sL <raw_url>/install.sh) --no-start
# =============================================================================

set -u

REMOTE_BASE="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}"

CMD_NAME="xd"
INSTALL_BIN="/usr/local/bin/${CMD_NAME}"
DEPLOY_DIR="/opt/xray-deploy"
INSTALL_LIB_DIR="$DEPLOY_DIR/lib"
INSTALL_TPL_DIR="$DEPLOY_DIR/templates"

# 模块与模板完整列表(新增时同步此处)
LIB_MODULES="00-common 10-system 20-xray-core 30-geo 40-cloudflared 50-nodes 51-reality-pq 90-menu"
TPL_NAMES="vless-tcp-reality-vision-tunnel vless-xhttp-reality-tunnel tunnel vless-xhttp-cdn vless-ws-cdn shadowsocks"

# ---------------------------------------------------------------------------
# root 检测
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] && { echo "[错误] 请以 root 运行"; exit 1; }

# ---------------------------------------------------------------------------
# 确保 bash(Alpine 默认 ash)
# ---------------------------------------------------------------------------
ensure_bash() {
    if [ -n "$BASH_VERSION" ]; then return 0; fi
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash >/dev/null 2>&1 && exec bash "$0" "$@"
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq bash >/dev/null 2>&1 && exec bash "$0" "$@"
    fi
    echo "[错误] 无法安装 bash"; exit 1
}
ensure_bash "$@"

# ---------------------------------------------------------------------------
# 基础依赖
# ---------------------------------------------------------------------------
need=()
command -v curl  >/dev/null 2>&1 || need+=(curl)
command -v wget  >/dev/null 2>&1 || need+=(wget)
command -v jq    >/dev/null 2>&1 || need+=(jq)
command -v unzip >/dev/null 2>&1 || need+=(unzip)
if [ "${#need[@]}" -gt 0 ]; then
    if command -v apk >/dev/null 2>&1; then apk add --no-cache "${need[@]}" >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null 2>&1
    fi
fi

# ---------------------------------------------------------------------------
# 下载文件(优先 curl, 兜底 wget, 带重试)
# ---------------------------------------------------------------------------
dl() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    # curl 优先
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --retry 2 --max-time 30 "$url" -o "$dest" 2>/dev/null; then
            [ -s "$dest" ] && return 0
        fi
    fi
    # wget 兜底
    if command -v wget >/dev/null 2>&1; then
        if wget -q --tries=2 --timeout=30 -O "$dest" "$url" 2>/dev/null; then
            [ -s "$dest" ] && return 0
        fi
    fi
    rm -f "$dest" 2>/dev/null
    return 1
}

# ---------------------------------------------------------------------------
# 下载主脚本 + lib + templates 并汇报结果
# ---------------------------------------------------------------------------
download_all() {
    local ok=0 fail=0

    echo "[信息] 下载主脚本..."
    if dl "${REMOTE_BASE}/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh"; then
        chmod +x "$DEPLOY_DIR/xray-deploy.sh"
        echo "[成功] 主脚本 ✓"
        ok=$((ok+1))
    else
        echo "[错误] 主脚本下载失败"; fail=$((fail+1))
    fi

    if dl "${REMOTE_BASE}/VERSION" "$DEPLOY_DIR/VERSION"; then
        ok=$((ok+1))
    else
        echo "[警告] VERSION 下载失败"; fail=$((fail+1))
    fi

    echo "[信息] 下载 lib 模块..."
    for f in $LIB_MODULES; do
        if dl "${REMOTE_BASE}/lib/${f}.sh" "${INSTALL_LIB_DIR}/${f}.sh"; then
            ok=$((ok+1))
        else
            echo "[错误] lib/${f}.sh 下载失败"
            fail=$((fail+1))
        fi
    done

    echo "[信息] 下载模板..."
    for t in $TPL_NAMES; do
        if dl "${REMOTE_BASE}/templates/${t}.server.jsonc" "${INSTALL_TPL_DIR}/${t}.server.jsonc"; then
            ok=$((ok+1))
        else
            echo "[错误] templates/${t}.server.jsonc 下载失败"
            fail=$((fail+1))
        fi
    done

    echo "[信息] 下载完成: 成功 ${ok}, 失败 ${fail}"
    [ "$fail" -gt 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
IS_UPDATE=0
NO_START=0
for arg in "$@"; do
    case "$arg" in
        --update)   IS_UPDATE=1; NO_START=1 ;;
        --no-start) NO_START=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 更新模式: 强制下载覆盖所有文件
# ---------------------------------------------------------------------------
if [ "$IS_UPDATE" -eq 1 ]; then
    echo "[信息] 正在更新 xray-deploy..."
    mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    if download_all; then
        # 软链
        ln -sf "$DEPLOY_DIR/xray-deploy.sh" "$INSTALL_BIN"
        chmod +x "$INSTALL_BIN"
        local_ver=$(cat "$DEPLOY_DIR/VERSION" 2>/dev/null || echo "?")
        echo "[成功] 更新完成 (版本 ${local_ver})"
    else
        echo "[警告] 部分文件下载失败, 请检查网络后重试"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# 首次安装
# ---------------------------------------------------------------------------
echo "[信息] 正在安装 xray-deploy..."
mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"

# 本地开发模式: 若 install.sh 同目录存在 xray-deploy.sh, 直接从本地拷贝
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "${LOCAL_DIR}/xray-deploy.sh" ]; then
    echo "[信息] 检测到本地源, 从本地拷贝"
    cp -f "${LOCAL_DIR}/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh"
    cp -f "${LOCAL_DIR}/VERSION" "$DEPLOY_DIR/VERSION" 2>/dev/null
    cp -f "${LOCAL_DIR}"/lib/*.sh "$INSTALL_LIB_DIR/" 2>/dev/null
    cp -f "${LOCAL_DIR}"/templates/*.jsonc "$INSTALL_TPL_DIR/" 2>/dev/null
else
    if ! download_all; then
        echo "[错误] 关键文件下载失败, 安装中止"
        exit 1
    fi
fi

ln -sf "$DEPLOY_DIR/xray-deploy.sh" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"

echo "[成功] xray-deploy 安装完成"
echo "[信息] 输入 ${CMD_NAME} 唤出主菜单"

if [ "$NO_START" -eq 0 ]; then
    exec "$INSTALL_BIN"
fi
