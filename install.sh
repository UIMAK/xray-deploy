#!/bin/bash
# =============================================================================
# install.sh — xray-deploy 一键安装入口
# 用法: bash <(curl -sL <raw_url>/install.sh)
# 作用: 探测系统 -> 确保 bash -> 拉取主脚本与 lib/、templates/ 到本地 ->
#       安装为 /usr/local/bin/xd 快捷命令 -> 首次进入菜单
# =============================================================================

set -u

# 安装源(发布后改为 GitHub raw 直链; 本地开发时用相对路径)
REMOTE_BASE="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}"

CMD_NAME="xd"
INSTALL_BIN="/usr/local/bin/${CMD_NAME}"
INSTALL_LIB_DIR="/opt/xray-deploy/lib"
INSTALL_TPL_DIR="/opt/xray-deploy/templates"

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

# 基础依赖
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
# 下载文件(优先 curl, 兜底 wget)
# ---------------------------------------------------------------------------
dl() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest" 2>/dev/null && return 0
    fi
    wget -qO "$dest" "$url" 2>/dev/null && return 0
    return 1
}

echo "[信息] 正在安装 xray-deploy..."

# ---------------------------------------------------------------------------
# 拉取主脚本 + lib + templates
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"

# 本地开发模式: 若 install.sh 同目录存在 xray-deploy.sh, 直接从本地拷贝(便于测试)
LOCAL_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -f "${LOCAL_DIR}/xray-deploy.sh" ]; then
    echo "[信息] 检测到本地源, 从本地拷贝"
    cp -f "${LOCAL_DIR}/xray-deploy.sh" "${INSTALL_BIN}.src"
    cp -f "${LOCAL_DIR}"/lib/*.sh "$INSTALL_LIB_DIR/" 2>/dev/null
    cp -f "${LOCAL_DIR}"/templates/*.jsonc "$INSTALL_TPL_DIR/" 2>/dev/null
else
    # 远程拉取
    if ! dl "${REMOTE_BASE}/xray-deploy.sh" "${INSTALL_BIN}.src"; then
        echo "[错误] 下载主脚本失败"; exit 1
    fi
    # lib 模块(固定列表, 加新模块需同步)
    for f in 00-common 10-system 20-xray-core 30-geo 40-cloudflared 50-nodes 51-reality-pq 90-menu; do
        dl "${REMOTE_BASE}/lib/${f}.sh" "${INSTALL_LIB_DIR}/${f}.sh" || echo "[警告] lib/${f}.sh 下载失败"
    done
    # templates: 下载已知列表(新模板同步到此)
    for t in vless-tcp-reality-vision vless-xhttp-reality vless-xhttp-cdn vless-ws-cdn shadowsocks hysteria2; do
        dl "${REMOTE_BASE}/templates/${t}.server.jsonc" "${INSTALL_TPL_DIR}/${t}.server.jsonc" || echo "[警告] templates/${t} 下载失败"
    done
fi

# ---------------------------------------------------------------------------
# 主脚本: xray-deploy.sh 需要 lib/ 与 templates/ 与它同处一个目录树
# 策略: 把主脚本放到 /opt/xray-deploy/(与 lib/ templates/ 同级), /usr/local/bin/xd 软链过去
# ---------------------------------------------------------------------------
mkdir -p /opt/xray-deploy
cp -f "${INSTALL_BIN}.src" /opt/xray-deploy/xray-deploy.sh
chmod +x /opt/xray-deploy/xray-deploy.sh
rm -f "${INSTALL_BIN}.src"

# lib/ templates/ 已在 /opt/xray-deploy/ 下(INSTALL_LIB_DIR/INSTALL_TPL_DIR), 主脚本与它们同根
ln -sf /opt/xray-deploy/xray-deploy.sh "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"

echo "[成功] xray-deploy 安装完成"
echo "[信息] 输入 ${CMD_NAME} 唤出主菜单"

# 首次进入菜单(可选: 用户手动)
if [ "${1:-}" != "--no-start" ]; then
    exec "$INSTALL_BIN"
fi
