#!/bin/bash
# =============================================================================
# install.sh — xray-deploy 一键安装/更新入口
# 用法:
#   首次安装: bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh)
#   更新脚本: bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh) --update
#   更新(不启动菜单): bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh) --no-start
# =============================================================================

set -u

REMOTE_BASE="${XRAY_DEPLOY_RAW:-https://raw.githubusercontent.com/UIMAK/xray-deploy/main}"

CMD_NAME="xd"
INSTALL_BIN="/usr/local/bin/${CMD_NAME}"
DEPLOY_DIR="/opt/xray-deploy"
INSTALL_LIB_DIR="$DEPLOY_DIR/lib"
INSTALL_TPL_DIR="$DEPLOY_DIR/templates"

# 模块与模板完整列表。
#
# **LIB_MODULES 与 xray-deploy.sh 里的同名变量必须逐字一致** —— 远程安装路径无法从磁盘
# 枚举模块(此时本地根本没有 lib/), 只能靠这份静态清单下载; 而 xray-deploy.sh 靠它 source。
# 两者漂移会造成"install.sh 认为安装完整、运行时却拒绝启动"(或反过来)。
# 漂移由 tests/run-tests.sh 的"两份 LIB_MODULES 必须一致"断言守住, 改一处就会报红。
# 注意: tests/ 按 2026-09-12 决策**不入库**(.gitignore), 所以该断言只在本仓库工作树内可见 ——
# 从 GitHub 克隆的副本没有它, 改这里时请在本仓库内跑一次测试。
LIB_MODULES="00-common 10-system 20-xray-core 30-geo 40-cloudflared 45-logrotate 50-nodes 51-reality-pq 55-hysteria 90-menu"
TPL_NAMES="vless-tcp-reality-vision-tunnel vless-xhttp-reality-tunnel vless-tcp-reality-vision-direct vless-xhttp-reality-direct tunnel vless-enc vless-xhttp-cdn vless-ws-cdn shadowsocks hysteria2"

# ---------------------------------------------------------------------------
# root 检测
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] && { echo "[错误] 请以 root 运行"; exit 1; }

# 部署目录含私钥/密码/token, 默认 077 使运行期生成的敏感文件仅 root 可读
umask 077

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
command -v curl  >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || need+=(curl)
command -v jq    >/dev/null 2>&1 || need+=(jq)
command -v unzip >/dev/null 2>&1 || need+=(unzip)
if [ "${#need[@]}" -gt 0 ]; then
    if command -v apk >/dev/null 2>&1; then apk add --no-cache "${need[@]}" >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null 2>&1
    fi
    for c in "${need[@]}"; do
        command -v "$c" >/dev/null 2>&1 || echo "[警告] 依赖 $c 安装失败, 脚本将尝试继续(菜单启动时会再次尝试安装)"
    done
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
    # wget 兜底(只用 busybox/GNU 都支持的 -q -T -O; --tries/--timeout 等 GNU 长选项在老版本 busybox 上不保证)
    if command -v wget >/dev/null 2>&1; then
        if wget -q -T 30 -O "$dest" "$url" 2>/dev/null; then
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
    # 下载到临时 staging 目录, 全部成功后再 atomic 复制到目标路径 (S7)
    local stage; stage=$(mktemp -d)
    local stage_lib="$stage/lib" stage_tpl="$stage/templates"
    mkdir -p "$stage_lib" "$stage_tpl"

    echo "[信息] 下载主脚本..."
    if dl "${REMOTE_BASE}/xray-deploy.sh" "$stage/xray-deploy.sh"; then
        echo "[成功] 主脚本 ✓"
        ok=$((ok+1))
    else
        echo "[错误] 主脚本下载失败"; fail=$((fail+1))
    fi

    if dl "${REMOTE_BASE}/VERSION" "$stage/VERSION"; then
        ok=$((ok+1))
    else
        echo "[警告] VERSION 下载失败"; fail=$((fail+1))
    fi

    echo "[信息] 下载 lib 模块..."
    for f in $LIB_MODULES; do
        if dl "${REMOTE_BASE}/lib/${f}.sh" "$stage_lib/${f}.sh"; then
            ok=$((ok+1))
        else
            echo "[错误] lib/${f}.sh 下载失败"
            fail=$((fail+1))
        fi
    done

    echo "[信息] 下载模板..."
    for t in $TPL_NAMES; do
        if dl "${REMOTE_BASE}/templates/${t}.server.jsonc" "$stage_tpl/${t}.server.jsonc"; then
            ok=$((ok+1))
        else
            echo "[错误] templates/${t}.server.jsonc 下载失败"
            fail=$((fail+1))
        fi
    done

    echo "[信息] 下载完成: 成功 ${ok}, 失败 ${fail}"
    if [ "$fail" -gt 0 ]; then
        rm -rf "$stage"
        echo "[错误] 部分文件下载失败, 已取消更新(现有文件未变动)"
        return 1
    fi

    # 全部成功 → 复制到最终路径。逐份检查 cp 返回值: 磁盘满/IO 错误时不得只落地一半文件却报成功。
    # (下载已在独立 staging 完成; 此处不做目录级 rename 原子切换, 因运行期 manager 就在目标目录内。)
    mkdir -p "$DEPLOY_DIR" "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    local copy_ok=1
    cp -f "$stage/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh" || copy_ok=0
    chmod +x "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null || copy_ok=0
    cp -f "$stage/VERSION" "$DEPLOY_DIR/VERSION" || copy_ok=0
    cp -f "$stage_lib"/*.sh "$INSTALL_LIB_DIR/" || copy_ok=0
    cp -f "$stage_tpl"/*.jsonc "$INSTALL_TPL_DIR/" || copy_ok=0
    rm -rf "$stage"
    if [ "$copy_ok" -ne 1 ]; then
        echo "[错误] 文件落地失败(磁盘空间/权限/IO?), 目标可能不完整, 请清理后重试"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
IS_UPDATE=0
NO_START=0
ALLOW_LOCAL=0
for arg in "$@"; do
    case "$arg" in
        --update)   IS_UPDATE=1; NO_START=1 ;;
        --no-start) NO_START=1 ;;
        --local)    ALLOW_LOCAL=1 ;;   # 仅首次安装有意义; 与 --update 组合在下面显式拒绝
        *)
            # 未知参数必须显式拒绝: 旧实现静默忽略, `--updat` 这类笔误会**执行一次完整
            # 首次安装**(覆盖文件并拉起菜单), 用户以为只是拼错了个开关。
            echo "[错误] 未知参数: $arg"
            echo "       可用: --update | --no-start | --local"
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 参数互斥校验。**必须放在 update 分支之前** —— 那个分支会 download_all 后直接 exit 0,
# 放在它后面等于死代码(实测: `install.sh --update --local` 仍会完整走网络安装且不报错)。
# --update 走"从 GitHub 重下全部文件"的路径, 本地源对它毫无意义; 静默忽略 --local 会让
# 用户以为在用本地源。
# ---------------------------------------------------------------------------
if [ "$IS_UPDATE" -eq 1 ] && [ "$ALLOW_LOCAL" -eq 1 ]; then
    echo "[错误] --update 与 --local 不能同时使用(--update 从网络重下全部文件)"
    echo "       本地源请直接运行: bash install.sh [--no-start]"
    exit 2
fi

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
        # xray 命令 symlink（检测已有安装不覆盖）
        if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
            ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray
        fi
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

# 本地开发模式: 需要**显式 --local**(或从 git 工作树运行)才信任同目录的源码。
# 旧实现仅凭"同目录存在 xray-deploy.sh"就拷贝并最终以 root 身份 source 这些文件 ——
# 在不可信工作目录里执行安装脚本(例如 cd 到别人的仓库)会静默安装任意本地 shell 代码。
# 保留"无参数直接 bash install.sh"的开发便利: 有 .git 标记即视为可信工作树。
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LOCAL_TRUSTED=0
[ "$ALLOW_LOCAL" -eq 1 ] && LOCAL_TRUSTED=1
# -e 而非 -d: git worktree/submodule 里的 .git 是一个**文件**(内含 gitdir: 指针),
# 用 -d 会让合法的工作树检出被判为不可信, 静默回落到网络安装。
[ -e "${LOCAL_DIR}/.git" ] && LOCAL_TRUSTED=1
if [ -f "${LOCAL_DIR}/xray-deploy.sh" ] && [ "$LOCAL_TRUSTED" -eq 1 ]; then
    echo "[信息] 检测到本地源, 从本地拷贝"
    # 2026-09-12 三审(M4): 拷贝失败(磁盘满/权限)必须中止 —— 原写法全部 2>/dev/null 吞掉,
    # lib/模板拷贝失败仍报"安装完成", 用户执行 xd 时才会以"source 失败"的形式暴露。
    if ! cp -f "${LOCAL_DIR}/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh"; then
        echo "[错误] 本地源拷贝失败: xray-deploy.sh(磁盘空间/权限?)"; exit 1
    fi
    if [ -f "${LOCAL_DIR}/VERSION" ]; then
        cp -f "${LOCAL_DIR}/VERSION" "$DEPLOY_DIR/VERSION" || { echo "[错误] 本地源拷贝失败: VERSION"; exit 1; }
    else
        echo "[警告] 本地源缺少 VERSION, 更新检查将显示未知版本"
    fi
    if [ ! -d "${LOCAL_DIR}/lib" ]; then
        echo "[错误] 本地源缺少 lib/ 目录, 安装中止"; exit 1
    fi
    # 校验**实际拷到哪些模块**: 旧实现只检查 cp 成功, 一个残缺的 lib/(缺几个模块)照样
    # 报"安装完成", 部署目录随即处于缺模块状态, 运行期才以 source 失败暴露。
    local_missing=""
    for m in $LIB_MODULES; do
        [ -f "${LOCAL_DIR}/lib/${m}.sh" ] || local_missing="${local_missing} ${m}.sh"
    done
    if [ -n "$local_missing" ]; then
        echo "[错误] 本地源 lib/ 缺少模块:${local_missing}"; exit 1
    fi
    cp -f "${LOCAL_DIR}"/lib/*.sh "$INSTALL_LIB_DIR/" || { echo "[错误] 本地源拷贝失败: lib/"; exit 1; }
    if [ ! -d "${LOCAL_DIR}/templates" ]; then
        echo "[错误] 本地源缺少 templates/ 目录, 安装中止"; exit 1
    fi
    tpl_missing=""
    for t in $TPL_NAMES; do
        [ -f "${LOCAL_DIR}/templates/${t}.server.jsonc" ] || tpl_missing="${tpl_missing} ${t}.server.jsonc"
    done
    if [ -n "$tpl_missing" ]; then
        echo "[错误] 本地源 templates/ 缺少:${tpl_missing}"; exit 1
    fi
    cp -f "${LOCAL_DIR}"/templates/*.jsonc "$INSTALL_TPL_DIR/" || { echo "[错误] 本地源拷贝失败: templates/"; exit 1; }
else
    # 用户**显式**要求本地安装却没有本地源时, 必须硬失败而不是静默拉网络 ——
    # 那正是"以为在用本地源、实际在装网络版"的误导(与上面的 --update/--local 互斥同一动机)。
    if [ "$ALLOW_LOCAL" -eq 1 ] && [ ! -f "${LOCAL_DIR}/xray-deploy.sh" ]; then
        echo "[错误] 已指定 --local, 但本地源不可用(缺少 ${LOCAL_DIR}/xray-deploy.sh)"
        echo "       请在有源码的目录运行, 或去掉 --local 从网络安装"
        exit 1
    fi
    if [ -f "${LOCAL_DIR}/xray-deploy.sh" ] && [ "$LOCAL_TRUSTED" -eq 0 ]; then
        echo "[信息] 检测到本地源但未受信任(无 .git 且未指定 --local), 改为从网络安装"
        echo "       如确实要从本地安装, 请加 --local"
    fi
    if ! download_all; then
        echo "[错误] 关键文件下载失败, 安装中止"
        exit 1
    fi
fi

ln -sf "$DEPLOY_DIR/xray-deploy.sh" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
# xray 命令 symlink（检测已有安装不覆盖）
if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
    ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray
fi

echo "[成功] xray-deploy 安装完成"
echo "[信息] 输入 ${CMD_NAME} 唤出主菜单"

if [ "$NO_START" -eq 0 ]; then
    exec "$INSTALL_BIN"
fi
