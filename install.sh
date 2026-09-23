#!/bin/bash
# =============================================================================
# install.sh — xray-deploy 一键安装/更新入口
# 用法:
#   首次安装: bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh)
#   更新脚本: bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh) --update
#   更新(不启动菜单): bash <(curl -fsSL <raw_url>/install.sh || wget -qO- <raw_url>/install.sh) --no-start
# =============================================================================

set -u

# 规范上游 base —— **唯一**的上游字面量来源(2026-09-22 七轮复审 D8)。
# 旧写法把同一个 URL 写了两遍(L12 与 L14), 只改一处会让 `REMOTE_BASE != REMOTE_BASE_DEFAULT`
# 永久为真 => 钉 commit 的逻辑静默失效(永不钉), 且不报任何错。派生而非复制, 使**镜像**只改
# 一处即可, 固定 URL 也由它派生(见 `_resolve_remote_base`), 不再有第三份硬编码。
#
# **"fork/镜像只改一处"的适用边界(2026-09-22 八轮复审 P2, 必须说清)**:
#   · **镜像**(同一仓库内容、仅换下载入口, 如反代 raw.githubusercontent)⇒ 本默认值**不用改**,
#     只设 `XRAY_DEPLOY_RAW=<镜像基址>` 即可; 那条路径根本不碰 API。
#   · **fork**(不同仓库、有自己的 commit)⇒ 必须设 `XRAY_DEPLOY_RAW=<fork 的 raw 基址>`,
#     **不要**改 `REMOTE_BASE_DEFAULT`。因为取 SHA 的 API 地址由下一行的 `REMOTE_API_COMMIT`
#     决定(当前写死上游 UIMAK), 而钉住的 URL 由 `REMOTE_BASE_DEFAULT` 派生 —— 只改后者会让它
#     取到**上游** SHA 再拼成 `<fork>/<上游sha>`, 22 个 GET 全 404 ⇒ 安装中止。
#     即: **`REMOTE_BASE_DEFAULT` 一旦改动, 必须同步改 `REMOTE_API_COMMIT`**; 这层约束无法由
#     `XRAY_DEPLOY_RAW` 覆盖。仅当二者指向同一仓库时,"只改一处"才成立。
REMOTE_BASE_DEFAULT="https://raw.githubusercontent.com/UIMAK/xray-deploy/main"
REMOTE_BASE="${XRAY_DEPLOY_RAW:-$REMOTE_BASE_DEFAULT}"
REMOTE_API_COMMIT="https://api.github.com/repos/UIMAK/xray-deploy/commits/main"
# 本次下载所用的 commit SHA(未固定时为空)。**必须在此处初始化**: 旧写法在
# `_resolve_remote_base` 内部无条件 `REMOTE_BASE_REF=""`, 从而"顺便"完成了初始化;
# 改成幂等提前返回后这个副作用消失, 而本脚本 `set -u`, 任何裸读 `$REMOTE_BASE_REF`
# (测试、_manifest_write、未来的调用点)都会因 unbound 直接报错(实测)。
REMOTE_BASE_REF=""

CMD_NAME="xd"
INSTALL_BIN="/usr/local/bin/${CMD_NAME}"
DEPLOY_DIR="/opt/xray-deploy"
INSTALL_LIB_DIR="$DEPLOY_DIR/lib"
INSTALL_TPL_DIR="$DEPLOY_DIR/templates"

# 整版本原子更新用的路径(见 _install_backup/_install_rollback 上方的设计说明)。
# MANIFEST: 安装成功后生成的版本一致性清单(每行 `<sha256>  <relpath>`), 由 xray-deploy.sh
#   在 source 之前独立校验(只告警不阻断)。ROLLBACK_DIR: 本次安装的备份目录, 带 $$ 防并发覆盖。
MANIFEST="$DEPLOY_DIR/.manifest"
ROLLBACK_DIR="$DEPLOY_DIR/.install-rollback.$$"

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
# 远端源快照一致: 把 22 个逐个 HTTP 请求固定到**同一个 commit**(2026-09-21 七轮复审 P2)。
#
# 问题: REMOTE_BASE 指向 `.../main`(移动分支 ref), 而主脚本/VERSION/10 lib/10 模板是**各自
# 一次** HTTP GET。若期间恰好有 push, 请求 1..8 可能看到 commit A、9..22 看到 commit B ⇒
# stage 里是**跨 commit 的混合树**。每个 GET 都返回 200, 所以 `fail>0` 的中止逻辑不触发;
# 而 `_manifest_write` 只对**最终落地的字节**做哈希, 无法察觉"这些字节来自不同 commit"。
# 本地落地的事务一致性解决的是"全部新或全部旧", 解决不了"新旧来自不同版本"。
#
# 修法: 下载前先解析 main 的 commit SHA, 全部文件从 `<repo>/<sha>/...` 取。
#
# 三条约束(均由实测得出):
#   · **仅在默认上游时固定**。`XRAY_DEPLOY_RAW` 指向镜像/私有 fork 时**必须原样不动, 且不调
#     api.github.com** —— 镜像没有义务携带上游 sha, 强行固定会让每一次下载 404 并因
#     `fail>0` 中止整个安装(lib/90-menu.sh 也已声明该覆盖是"用户自负责的受信源")。
#   · **fail-open**。GitHub 未认证 API 限额 60/h/IP, 共享出口的 NAT VPS 可能已耗尽;
#     任何一步失败(非 200 / 空 body / 无 jq / 无 curl+wget / sha 形状不对)都**回退到 main**,
#     绝不中止安装 —— 最坏情况只是退回到"逐个请求"的旧行为, 不引入新的失败点。
#   · **必须校验 40 位十六进制**再拼进 URL(防畸形 ref 与注入)。
# 用 `printf`(而非 echo)输出, 因为本函数在 `$(...)` 里被调用, 而 echo 会解释 `-n` 等转义。
#
# **直接改全局变量, 不走命令替换** —— `$(...)` 在子 shell 里执行, 函数里对 REMOTE_BASE_REF
# 的赋值传不回调用方, 于是清单里的 provenance 会静默丢失。故本函数无 stdout 输出。
# ---------------------------------------------------------------------------
_resolve_remote_base() {
    # 已钉住 => 幂等返回(2026-09-22 七轮复审 D9)。
    # 旧写法在开头无条件 `REMOTE_BASE_REF=""`, 而钉住后 `REMOTE_BASE != REMOTE_BASE_DEFAULT`,
    # 第二次调用会在下面的守卫处提前返回 ⇒ BASE 仍钉住而 REF 被清空: 装的是固定 commit,
    # 清单里的 provenance 行却消失。判据必须是"**已钉住**"(REF 非空), 而不是 BASE 是否等于默认。
    if [ -n "${REMOTE_BASE_REF:-}" ]; then return 0; fi
    # 用户覆盖了源 => 不解析, 不调用 API
    if [ -n "${XRAY_DEPLOY_RAW:-}" ] || [ "$REMOTE_BASE" != "$REMOTE_BASE_DEFAULT" ]; then
        return 0
    fi
    local body sha
    if command -v curl >/dev/null 2>&1; then
        body=$(curl -fsSL --max-time 15 "$REMOTE_API_COMMIT" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        body=$(wget -q -T 15 -O- "$REMOTE_API_COMMIT" 2>/dev/null)
    else
        body=""
    fi
    # jq 是首选; 无 jq 时用 BRE grep 兜底(与 20-xray-core 的 _xray_fetch_tag 同一取舍:
    # busybox 上 grep -E 行为不一致, 故只用基础正则)。
    #
    # **只有顶层 `sha` 才是 commit; 嵌套的 `sha`(commit.tree.sha / parents[].sha /
    # files[].sha)不是, 绝不能钉住它们**(2026-09-22 七轮复审 D4 的完整形态)。
    # 两条路径的行为边界必须说清(实测, 不得含糊成"结构上不可能"):
    #   · **jq 路径(真实环境)**: `.sha` 由 jq 按 JSON 结构解析, 只要存在顶层 `sha` 就一定取到
    #     它, 与嵌套 sha 出现在前在后无关 —— 实测 `{"commit":{"tree":{"sha":T}},"sha":S}`
    #     取到 S(正确), 只有嵌套而无顶层时为空(正确)。
    #   · **无 jq 兜底**: 只能词法匹配, 规则是"**压平后第一个键**必须是 `sha`"。故
    #     `{"commit":{"tree":{"sha":T}},"sha":S}`(嵌套在前、顶层在后)会**取不到** ⇒ 回退 main。
    #     这是**保守方向**(退回逐个请求的旧行为, 不引入新的失败点), 不是漏判; 但它的确是
    #     规则不是证明 —— 若将来 GitHub 把顶层 `sha` 移到首位之后, 这条兜底会静默降级为不钉。
    # 旧写法的两个实测缺陷(都据此修掉):
    #   · `grep '"sha"' | head -1 | sed 's/.*"sha".../'` 的 sed **贪婪**且 `head -1` 只选**行**
    #     ⇒ 单行(压缩)响应下锚定行内**最后一个** "sha"。实测真实 GitHub 载荷压行后取到
    #     `files[].sha`, 40 位形状校验照样通过, 22 个 GET 全 404 ⇒ `fail>0` ⇒ 安装中止
    #     (即实际 fail-closed, 与注释声明的 fail-open 相反)。
    #   · 仅"压平后取第一个含 sha 的记录"仍不够: `{"commit":{"tree":{"sha":…}}}` 没有顶层 sha,
    #     而首个含 sha 的记录是 tree 对象 ⇒ 照样钉住一个**不是 commit 的对象**(实测)。
    # 故兜底改为 `sed -n` 只在**载荷首键**位置匹配: `"sha"` 必须出现在压平后的第一行且其前
    # 除 `{` 与空白外没有别的键。非顶层 / 无顶层 sha / 错误体 / 数组一律**无输出** ⇒
    # 走下面的形状校验 ⇒ 回退 main(fail-open)。
    if command -v jq >/dev/null 2>&1; then
        sha=$(printf '%s' "$body" | jq -r '.sha // empty' 2>/dev/null)
    fi
    if [ -z "${sha:-}" ] || [ "$sha" = "null" ]; then
        sha=$(printf '%s' "$body" | tr -d '\n' | tr ',' '\n' | head -1 \
              | sed -n 's/^[[:space:]]*{[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p')
    fi
    # 形状校验: 不是 40 位十六进制一律放弃(绝不把畸形值拼进 URL)。失败即回退 main, 不中止。
    case "${sha:-}" in
        *[!0-9a-fA-F]*|'') return 0 ;;
    esac
    [ "${#sha}" -eq 40 ] || return 0
    REMOTE_BASE_REF="$sha"
    # 固定 URL 由 REMOTE_BASE_DEFAULT **派生**(去掉末尾 ref 段), 不再写第三份字面量 ——
    # 否则改字面量实现的 fork/镜像会被静默改回上游仓库(实测: 三处字面量只改前两处时,
    # 拼出的仍是 UIMAK 仓库; 三处全改则拼出 `UIMAK/xray-deploy/<fork-sha>` ⇒ 全 404)。
    REMOTE_BASE="${REMOTE_BASE_DEFAULT%/*}/$sha"
}

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
# 单文件原子落地 + 落地后复核
#
# _install_file: cp 到同目录的临时名, 再 mv 覆盖目标。同目录 rename 是原子的, 因此
# 每个文件只有"完整的旧内容"和"完整的新内容"两种可见状态 —— 目录级 cp 中途失败留下的
# "一半新一半旧"的 lib/ 会让主脚本以 source 失败/怪异报错的形式暴露(见 download_all)。
# 临时名带 $$ 避免并发安装互相覆盖; 任一步失败都清理临时文件, 不留垃圾。
# _verify_installed: 复核每一个 LIB_MODULES/TPL_NAMES 条目都**存在且非空**。cp 返回 0
# 却只落地 0 字节(磁盘满)是真实场景, 只看 cp 退出码看不出来。
# ---------------------------------------------------------------------------
_install_file() { # <src> <dest>
    local src="$1" dest="$2" tmp
    [ -f "$src" ] || { echo "[错误] 暂存文件缺失: $src"; return 1; }
    tmp="${dest}.tmp.$$"
    if ! cp -f "$src" "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        echo "[错误] 文件落地失败: $dest(磁盘空间/权限/IO?)"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null
        echo "[错误] 文件落地为空: $dest(磁盘空间?)"
        return 1
    fi
    if ! mv -f "$tmp" "$dest" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        echo "[错误] 文件替换失败: $dest"
        return 1
    fi
    return 0
}

_verify_installed() {
    local m bad=""
    for m in $LIB_MODULES; do
        [ -s "$INSTALL_LIB_DIR/${m}.sh" ] || bad="$bad lib/${m}.sh"
    done
    for m in $TPL_NAMES; do
        [ -s "$INSTALL_TPL_DIR/${m}.server.jsonc" ] || bad="$bad templates/${m}.server.jsonc"
    done
    [ -s "$DEPLOY_DIR/xray-deploy.sh" ] || bad="$bad xray-deploy.sh"
    if [ -n "$bad" ]; then
        echo "[错误] 安装后复核失败, 以下文件缺失或为空:${bad}"
        echo "       请清理 $DEPLOY_DIR 后重试"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 整版本原子更新(2026-09-21 复审 P1 收口)
#
# 逐文件 tmp→mv 只保证**单个文件**不半截, 不保证**整版本**一致: 10 个 lib + 10 个模板 +
# 主脚本 + VERSION 逐个落地, 中途失败(磁盘满/IO)会留下"一半新一半旧"的部署目录, 而旧代码
# 只看 copy_ok 就报成功。这里把落地升级为四段式:
#
#   1. 备份: 对清单里**每个已存在**的目标先 cp 到 $ROLLBACK_DIR/<relpath>;
#            任一步失败立即 return 1 —— 此时目标一个字节都没动。
#   2. 落地: 逐文件 _install_file(tmp→mv), 失败只置 copy_ok=0, 不中断。
#   3. 复核: _verify_installed(存在且非空)。
#   4. 回滚: 2/3 任一步失败 => 用 $ROLLBACK_DIR 把**全部**目标恢复到第 1 步之前:
#            备份里有 => cp 回去; 备份里没有(本次新建) => rm -f 掉。
#            回滚自身失败 => 如实报"降级状态 + 需人工核对的路径", 返回 1。
#
# 为什么是"备份后整体还原"而不是"失败时逐项重下": 失败时网络/磁盘状态与落地时可能不同
# (且重下可能再次失败); 备份是本机既有的、已验证可读的字节, 是唯一可靠的回滚源。
#
# $ROLLBACK_DIR 位置 = $DEPLOY_DIR/.install-rollback.$$ —— 三个约束:
#   · 同文件系统 => cp 不跨 fs, 不受 /tmp 容量影响;
#   · 以 `.` 开头 => 不被 nodes/*.json、templates/*.jsonc 之类的 glob 命中(本项目无 dotglob);
#   · `$$` 后缀 => 并发安装不互相覆盖; 所有 return 路径前 rm -rf, 入口顺手清理 SIGKILL 残留。
#
# 为什么不做 releases/<version> + current 软链切换: 主程序运行期**就在**目标目录内
# (LIB_DIR="$SCRIPT_DIR/lib"), 换不掉正在执行的脚本自身; 改造入口解析/service ExecStart/
# 卸载路径的触及面远大于收益。本函数已直接满足"部分更新失败不留混合版本"。
# ---------------------------------------------------------------------------
_manifest_relpaths() {
    local m t
    printf '%s\n' 'xray-deploy.sh' 'VERSION'
    for m in $LIB_MODULES; do printf 'lib/%s.sh\n' "$m"; done
    for t in $TPL_NAMES; do printf 'templates/%s.server.jsonc\n' "$t"; done
}

_install_backup() {
    local rel dest bak
    # **先检查 .KEEP 再动手**(2026-09-22 七轮复审: 这条守卫此前只存在于
    # `_install_cleanup_stale`, 而本函数的调用方在调用前还有一次**无条件**的
    # `rm -rf "$ROLLBACK_DIR"` —— 于是"标记目录永不被自动删"的契约被从旁边绕过)。
    # 实测残局: 上一次安装失败留下的带标记目录, 其后缀若恰好等于**本次**的 `$$`(PID 复用),
    # `_install_cleanup_stale` 会正确地保留它并打印提示, 紧接着调用方的裸 `rm -rf` 把它连
    # `.KEEP` 和更新前的原始文件一起销毁 —— 而提示刚刚让用户去那个目录里找文件。
    # 判据放在**本函数内部**(而不是各调用点)是为了让"备份目标被占用"这件事只有一个判定入口;
    # 返回 2 与"备份失败(1)"区分开, 使调用方能给出各自的处置说明。
    #
    # **这是一条"拒绝继续"的路径, 不是透明处理**: 触发条件很窄(需与**上一次失败运行**的 PID
    # 相撞, 因为目录名带 `$$`), 但一旦命中, 本次安装**拒绝进行**并给出确切的删除命令, 而不是
    # 静默覆盖。方向是刻意选的 —— 另一种做法(照旧 `rm -rf`)会毁掉用户唯一的恢复副本;
    # 代价是处于该状态的用户必须先按提示删掉那个目录才能继续安装。
    # 文档措辞必须是"拒绝并给出确切命令", 不得写成"自动处理/透明兼容"(2026-09-22 与
    # 并行会话核对后确认)。
    if [ -e "$ROLLBACK_DIR/.KEEP" ]; then
        echo "[错误] 恢复目录 $ROLLBACK_DIR 内存在 .KEEP 标记(上次安装保留的更新前文件), 拒绝覆盖"
        echo "       请先确认不再需要其中的文件, 手动删除该目录后重试:"
        echo "         rm -rf \"$ROLLBACK_DIR\""
        return 2
    fi
    # 必须先建目录: 首次安装(目标全不存在)时循环里一次 `mkdir -p` 都不会执行, 目录不存在
    # 则下面的标记写入必然失败 ⇒ 首次安装被误判为"备份失败"而中止(实测踩到)。
    mkdir -p "$ROLLBACK_DIR" 2>/dev/null || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dest="$DEPLOY_DIR/$rel"
        [ -e "$dest" ] || continue          # 本次新建的, 回滚时删掉即可
        bak="$ROLLBACK_DIR/$rel"
        mkdir -p "$(dirname "$bak")" 2>/dev/null || return 1
        cp -f "$dest" "$bak" 2>/dev/null || return 1
    done <<< "$(_manifest_relpaths)"
    # 恢复标记**必须是最后一步**(2026-09-21 七轮复审 P1)。
    #
    # 为什么: `_install_cleanup_stale` 只能靠"目录名里的 PID 是否存活"猜目录的用途, 而
    # **上一次安装进程早已退出** —— 于是本函数保留的恢复源与可丢弃的 SIGKILL 残留对它是
    # 逐字节不可区分的(都是"目录存在 + PID 已死"), 一起被 `rm -rf`。实测复现: 回滚失败保留
    # 的目录在**下一次** `install.sh` 启动时被删, 而错误提示恰好让用户去跑那次安装。
    # 正向标记把"这份备份可能还需要"变成**目录自身携带的事实**, 不再依赖外部线索。
    #
    # 为什么写在**最后**: 不变量必须是"标记存在 ⇔ 备份完整"。若先立标记而备份只完成一半,
    # 后续 `_install_rollback` 会把"备份里没有"的条目当成"本次新建"而 `rm -f` 掉**既有的
    # 健康文件**(见本函数下方 _install_rollback 的分支)。写在最后使该残局不可能出现。
    #
    # 位置也覆盖了 SIGKILL 分支: 本函数在**第一次改动目标文件之前**返回, 因此进程在落地
    # 中途被强杀时标记已经在盘上, 恢复源同样受保护。
    : > "$ROLLBACK_DIR/.KEEP" 2>/dev/null || {
        echo "[错误] 无法写入恢复标记 $ROLLBACK_DIR/.KEEP(磁盘空间/权限?), 未改动任何文件"
        return 1
    }
    return 0
}

_install_rollback() {
    local rel dest bak bad=""
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dest="$DEPLOY_DIR/$rel"
        bak="$ROLLBACK_DIR/$rel"
        if [ -e "$bak" ]; then
            cp -f "$bak" "$dest" 2>/dev/null || bad="$bad $rel"
        else
            # 备份里没有 => 本次新建的, 删掉即回到"未安装"
            [ -e "$dest" ] || continue
            rm -f "$dest" 2>/dev/null || bad="$bad $rel"
        fi
    done <<< "$(_manifest_relpaths)"
    if [ -n "$bad" ]; then
        # 回滚**不提前 return**, 逐项尽力恢复后汇总(见上方设计说明)。失败项必须点名 ——
        # 只说"回滚失败"会让用户不知道该核对哪些文件。
        echo "[错误] 回滚未完成, 以下文件可能处于不一致状态:${bad}"
        echo "       请人工核对 $DEPLOY_DIR 或重跑 install.sh --update"
        return 1
    fi
    return 0
}

_manifest_write() {
    # sha256sum 缺失(极简 busybox)时静默跳过 —— 旧装机(无清单)行为不变, 只少一层保护。
    command -v sha256sum >/dev/null 2>&1 || return 0
    local rel h tmp="$MANIFEST.tmp.$$"
    : > "$tmp" 2>/dev/null || { echo "[警告] 无法写入安装清单: $MANIFEST"; return 1; }
    # provenance: 记录本次下载所用的 commit SHA(若已固定)。
    # **必须是单个无空白 token**: 读取端(xray-deploy.sh)用 `while read -r _mh _mp` 逐行取
    # 两个字段, `[ -n "$_mp" ] || continue` 跳过第二字段为空的行。写成 `# commit <sha>` 会让
    # `_mp="commit"`, 于是对不存在的路径 `commit` 求 sha256 得到空值 ⇒ **假告警**。
    # `#commit=<sha>` 无空白 ⇒ 被现有守卫自然跳过, **旧读者零改动兼容**。
    # 注意: 记录 sha 只提供可追溯性, **不能**检测跨 commit 混合 —— 那靠 _resolve_remote_base。
    if [ -n "${REMOTE_BASE_REF:-}" ]; then
        printf '#commit=%s\n' "$REMOTE_BASE_REF" >> "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    fi
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        h=$(sha256sum "$DEPLOY_DIR/$rel" 2>/dev/null | awk '{print $1}')
        if [ -z "$h" ]; then
            rm -f "$tmp" 2>/dev/null
            echo "[警告] 安装清单生成失败: $rel"
            return 1
        fi
        printf '%s  %s\n' "$h" "$rel" >> "$tmp" || { rm -f "$tmp" 2>/dev/null; return 1; }
    done <<< "$(_manifest_relpaths)"
    mv -f "$tmp" "$MANIFEST" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; echo "[警告] 安装清单落盘失败"; return 1; }
    return 0
}

_install_cleanup_stale() {
    # SIGKILL 残留的回滚目录(SIGKILL 时回滚代码没机会执行): 内容是旧文件的副本, 无害但会堆积。
    #
    # **绝不能删正在并发安装的那个** —— 那个安装的进程还活着, 其 _install_rollback 正要靠这份
    # 备份恢复; 备份被删后, 回滚循环对每个条目都读到"备份里没有", 于是误判成"本次新建"而
    # **删除既有文件**。实测复现: 安装 A 备份完 -> 安装 B 启动调本函数 -> A 落地后失败触发回滚
    # -> 一份健康的 5 文件安装被清成 0 文件(数据全丢)。
    #
    # 判据(顺序即优先级):
    #   1. 目录内有 `.KEEP`(2026-09-21 七轮 P1) => **恢复源, 永不自动删**。
    #      它是上一次安装留下的"更新前字节", 且**没有任何自动事件能证明它不再需要** ——
    #      "目录名里的 PID 已死"恰恰是它的常态(那次安装进程早已退出), 所以不能拿 PID 判它。
    #      实测复现的正是这条: D2 保留的恢复源在下一次安装启动时被删, 而错误提示让用户
    #      去跑那次安装。只有人工处理才清它, 故这里输出提示让受保护目录**可见**。
    #   2. 无标记 + PID 存活 => 跳过(并发安装的备份)。
    #   3. 无标记 + PID 已死 => rm -rf(真正的 SIGKILL 残留)。
    #   4. 后缀非数字 => 跳过(非本函数创建的目录; 与注释一致 —— 旧代码这里缺 `continue`,
    #      控制流落到 rm -rf, 与注释"不动"相反, 属实测发现的注释/行为矛盾)。
    #
    # `kill -0` 这条判据**保留**(不因第 1 条而冗余): 它是"锁被绕过/丢失/旧版脚本"时的
    # fail-safe, 删掉会重新打开上面那条数据丢失路径。
    # 代价是 PID 复用可能让我们**少删**一次(残留多留一会儿, 无害); 反方向才是数据丢失,
    # 所以这个方向是刻意选的。`$$` 只保证路径不互相覆盖, 保护不了被**别人**的清理 glob 扫到。
    local d pid protected=0
    local -a prot_list=()
    for d in "$DEPLOY_DIR"/.install-rollback.*; do
        [ -e "$d" ] || continue
        [ -e "$d/.KEEP" ] && { protected=$((protected+1)); prot_list+=("$d"); continue; }
        pid="${d##*.install-rollback.}"
        case "$pid" in
            ''|*[!0-9]*) continue ;;                          # 无数字后缀: 非本函数创建, 不动
            *) kill -0 "$pid" 2>/dev/null && continue ;;      # 安装进程仍活着 => 并发安装的备份
        esac
        rm -rf "$d" 2>/dev/null || true
    done
    if [ "$protected" -gt 0 ]; then
        # **绝不广告 glob**(2026-09-22 七轮复审 D5): 旧文案让用户删
        # `$DEPLOY_DIR/.install-rollback.*`, 而该 glob 展开后**包含**上面刚跳过的受保护目录 ——
        # 照做的用户会删掉唯一的恢复源(与"错误信息不得指引用户执行销毁恢复源的命令"直接冲突,
        # 且同一段提示上一行称"受保护"、下一行给出会扫掉它的通配符, 自相矛盾)。
        # 改为**逐条列出受保护目录的绝对路径**, 并点明它们是"更新前的原始字节"。
        echo "[提示] 发现 ${protected} 个受保护的恢复目录(上次安装失败或被强杀时保留的更新前文件):"
        printf '         %s\n' "${prot_list[@]}"
        echo "       这些目录**不可自动清理**, 其中保存着更新前的原始文件;"
        echo "       确认已不再需要后, 请按上面的完整路径逐个手动删除(不要用通配符)。"
    fi
}

# ---------------------------------------------------------------------------
# 下载主脚本 + lib + templates 并汇报结果
# ---------------------------------------------------------------------------
download_all() {
    local ok=0 fail=0
    # 先解析远端 base(可能被固定到某个 commit SHA)。**直接改全局变量**: 函数无 stdout,
    # 因为命令替换会在子 shell 里跑, REMOTE_BASE_REF 的赋值传不回来。失败即保持 main, 不中止。
    _resolve_remote_base
    # 下载到临时 staging 目录, 全部成功后再 atomic 复制到目标路径 (S7)
    #
    # mktemp 失败必须**立即中止**: stage 为空串时下面所有路径拼接都会退化成绝对根路径 ——
    # "$stage/xray-deploy.sh" 变成 "/xray-deploy.sh"、"$stage/lib" 变成 "/lib"、
    # "$stage/templates" 变成 "/templates", 于是下载产物被直接写到系统根目录, 且末尾
    # rm -rf "$stage" 变成 rm -rf ""(空操作)让垃圾永久残留。磁盘满/只读/inode 耗尽正是
    # 本 PR 关注的低配 VPS 场景。
    local stage
    stage=$(mktemp -d) || { echo "[错误] 无法创建临时目录(/tmp 写满或只读?), 安装中止"; return 1; }
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

    # 全部成功 → 复制到最终路径。
    #
    # 2026-09-21 复审(P2): 旧写法是 5 条**逐目录** cp(cp -f "$stage_lib"/*.sh "$INSTALL_LIB_DIR/")。
    # 目录级 cp 中途失败(磁盘满/IO)会在目标目录里留下"一半新、一半旧"的 lib/ —— 正是
    # xray-deploy.sh 启动时那条"模块缺失/版本不一致"检查要防的状态, 而旧代码只看 cp 的
    # 退出码就报成功, 用户直到下次 xd 才以怪异报错暴露。
    # 现在逐**文件**落地, 且每个文件都走 tmp → mv: rename 在同一目录内是原子的, 于是每个
    # 模块要么是完整的旧版、要么是完整的新版, 永远不会出现半截文件。
    # (不做目录级 rename 切换: 运行期 manager 自己就在目标目录内。)
    #
    # 2026-09-21 五轮复审(P1): 逐文件原子 ≠ 整版本原子。落地段升级为"备份 → 落地 → 复核 →
    # 失败整体回滚"四段式(见 _install_backup 上方说明), 保证结果只有"全部新"或"全部旧"。
    mkdir -p "$DEPLOY_DIR" "$INSTALL_LIB_DIR" "$INSTALL_TPL_DIR"
    # **注意: 这里绝不能无条件 `rm -rf "$ROLLBACK_DIR"`**。它看似只是"清理上次的残留",
    # 但 `$ROLLBACK_DIR` 带 `$$` 后缀, 一旦与上一次安装(已退出)留下的**带 `.KEEP` 的恢复
    # 目录**同名(PID 复用), 这一行就会销毁唯一的恢复源 —— 而 `_install_cleanup_stale`
    # 刚刚才因为 `.KEEP` 特意保留了它。判据统一放在 `_install_backup` 内部(它自己会检查
    # `.KEEP` 并返回 2), 调用点只按返回码分流。
    _bk_rc=0
    _install_backup || _bk_rc=$?
    if [ "$_bk_rc" -eq 2 ]; then
        # 恢复目录被标记占用: 不清理、不继续 —— 把处置权交回用户
        rm -rf "$stage" 2>/dev/null
        return 1
    fi
    if [ "$_bk_rc" -ne 0 ]; then
        rm -rf "$stage" "$ROLLBACK_DIR" 2>/dev/null
        echo "[错误] 备份现有安装失败(磁盘空间/权限?), 未改动任何文件"
        return 1
    fi
    local copy_ok=1 m
    _install_file "$stage/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh" || copy_ok=0
    chmod +x "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null || copy_ok=0
    _install_file "$stage/VERSION" "$DEPLOY_DIR/VERSION" || copy_ok=0
    for m in $LIB_MODULES; do
        _install_file "$stage_lib/${m}.sh" "$INSTALL_LIB_DIR/${m}.sh" || copy_ok=0
    done
    local t
    for t in $TPL_NAMES; do
        _install_file "$stage_tpl/${t}.server.jsonc" "$INSTALL_TPL_DIR/${t}.server.jsonc" || copy_ok=0
    done
    rm -rf "$stage"
    # 落地或复核任一失败 => 整体回滚到第 1 步之前。回滚失败时 _install_rollback 自己会
    # 点名不一致的文件并返回 1, 这里把两个失败事实都报出来。
    if [ "$copy_ok" -ne 1 ] || ! _verify_installed; then
        echo "[错误] 文件落地/复核失败, 正在回滚到更新前状态..."
        # 回滚失败时**必须保留** $ROLLBACK_DIR —— 它是唯一的恢复源, 里面装的是更新前的
        # 原始字节。删掉它就等于"回滚失败还销毁唯一副本"(项目在 hysteria 证书快照上有同款
        # 明文契约)。成功路径才清理。
        if _install_rollback; then
            rm -rf "$ROLLBACK_DIR" 2>/dev/null
        else
            echo "[错误] 回滚未完全成功, 已保留备份目录: $ROLLBACK_DIR"
            echo "       请人工从该目录恢复, 或重跑 install.sh --update"
        fi
        return 1
    fi
    rm -rf "$ROLLBACK_DIR" 2>/dev/null
    # 清单在**全部落地并复核通过之后**生成; 失败路径不写(与其余文件同一批被回滚覆盖)。
    _manifest_write || true
    return 0
}

# ---------------------------------------------------------------------------
# 安装级互斥锁(2026-09-21 七轮复审 P2; 2026-09-22 七轮复审 D2/D3/D6/D7 重做)
#
# 为什么需要: 备份+整体回滚只在**单个**安装者时成立。两个 `install.sh` 并发时 A 落地到一半,
# B 的 `_install_backup` 会把"半新半旧"的树当成"更新前状态"存下来; B 再失败回滚, 就把这棵
# 混合树写了回去 —— 且 A 可能已经报过成功。
#
# **为什么改为 flock 优先(实测推翻上一轮的 mkdir-only 取舍)**: 上一轮选 mkdir 的理由是
# "flock 缺失时放行等于没锁"。但 mkdir 方案在**陈旧锁接管**上有一个无法用 mkdir 自身消除的
# 竞态: "读 owner → rm -rf → mkdir"三步之间, 另一进程可读到同一陈旧值并同样进入。实测
# (4 进程争抢陈旧锁, 用 flock 保护的计数器判定"是否同时在持"):
#   · 现行 mkdir + rm -rf 接管:   12 轮中 5 轮出现**同时持有**(ownership 被抢 19/25 轮)
#   · 改为 mv 原子改名接管:        12 轮中 4 轮同时持有
#   · 改为独立 token 目录串行化:   12 轮中 2~4 轮同时持有, 且 25 轮中 16 轮有竞争者
#     因等不到 token 而**直接放弃安装**(NOLOCK)
#   · flock:                      12 轮 **0** 次同时持有, 25 轮 0 次持锁数异常
# 结论: 在无内核仲裁的前提下, "接管别人的锁"本身不可证明安全(任何"读-删-建"序列都存在
# 窗口)。flock 由内核持有, 进程退出(**含 SIGKILL**)自动释放 ⇒ 既无陈旧锁, 也无接管竞态。
# 故: **有 flock 就用 flock**; 无 flock 时退化为 mkdir-only 且**永不自动接管** ——
# "不删自己没创建的锁"是唯一可证明安全的行为, 代价是 SIGKILL 残留需人工清理(消息给出路径)。
# 这同时修掉了 D2(TOCTOU 双持有)与 D7(`00`/`000` 这类全零 pid 造成的永久拒绝 ——
# flock 路径根本不读 pid)。
#
# **flock 路径的已知残局(实测, 非假设)**: `exec {fd}>>file` 打开的 fd **会被子进程继承**
# (bash 的 `{var}>` 不设 CLOEXEC), 故若安装进程被 SIGKILL 而此刻恰好有子进程在跑
# (curl/wget/cp…), 那个孤儿会替它继续持锁。实测: 杀父进程后仍拒锁, 杀掉孤儿 `sleep` 后立即可取。
# 影响有界但**不是常数**: 本脚本的子进程都是同步短命的, 故残锁会在那个子进程退出后释放 ——
# 因此上界**由最长命子进程决定, 而不是锁代码里的计时器**。**不要写成"最迟 30s"**(2026-09-22
# 八轮复审指出, 已核对 curl 官方手册原文): `dl` 用的是 `curl --retry 2 --max-time 30`, 而手册对
# `--max-time` 的原文是 "Set the maximum time ... **each transfer**", 并明确 "If you enable
# retrying the transfer (--retry) then **the maximum time counter is reset each time the
# transfer is retried**"。即 `--max-time 30` 是**每次尝试**的上限, 不是整个 `dl` 的上限;
# 加上 `--retry` 的指数退避(首次约 1s, 其后翻倍), 一次 `dl` 可达 **约 91s**
# (30 + 1 + 30 + 2 + 30), 而不是 30s。curl 另有 `--retry-max-time` 才限制重试总时长, 本项目未用。
# 准确表述: **在该子进程退出后立即释放; 通常数十秒, 启用 retry 时可能超过一分钟**。
# 仍是比 mkdir 退路好的地方 —— 后者必须人工 `rm -rf`, 不会自愈。
# 有意不为此改成"不继承 fd": 那要引入 CLOEXEC, bash 无可移植写法, 而收益只是把 30s 缩短到 0。
#
# 锁文件/退路目录放在 `$DEPLOY_DIR` 的父目录, 不随整站卸载而被删。安装锁获取成功后才创建
# `$DEPLOY_DIR`, 并在其下清理/暂存/落地, 使 `_uninstall_xray` 能用同一把稳定锁排斥并发卸载。
# ---------------------------------------------------------------------------
INSTALL_LOCK_PARENT="${DEPLOY_DIR%/*}"
INSTALL_LOCK_NAME="${DEPLOY_DIR##*/}"
[ -n "$INSTALL_LOCK_PARENT" ] || INSTALL_LOCK_PARENT="/"
INSTALL_LOCK_DIR="${INSTALL_LOCK_PARENT}/.${INSTALL_LOCK_NAME}.install.lock"
# flock 用的**文件**与 mkdir 退路用的**目录**必须是两个不同路径: 旧版本(以及本版本的
# mkdir 退路)在 `.install.lock` 上放的是**目录**, 而 `exec 9>>` 需要的是文件 —— 复用同一
# 路径会让升级后的第一次安装直接报 "Is a directory" 而**完全无法运行**(实测)。这两个路径
# 都在部署目录外, 后者是兄弟文件而非锁目录内的文件。
INSTALL_LOCK_FILE="${INSTALL_LOCK_DIR}.fd"
# **跨版本协调**(2026-09-23 十五轮): 0.17.11 与 PR #48 早期 HEAD 的两条锁路径都在
# `$DEPLOY_DIR` **内**(flock 文件 `.install.lock.fd` / mkdir 退路目录 `.install.lock`),
# 而新版主锁已移到目录外 —— 只拿新锁**排斥不了仍在运行的旧版安装**: 旧版只认它自己的路径,
# 于是 A(旧)与 B(新)会各自持一把不同的锁同时落地。故新版在拿到主锁后, 再按**同一种手段**
# 取一次旧版锁: 有 flock 就 flock 旧文件(旧版的 `flock -n` 必然失败), 没有 flock 就把旧
# mkdir 目录也 mkdir 下来(旧版读到活 pid 会等待/拒绝)。取不到一律 fail-closed, 绝不删或
# 接管别人的锁。**残局(未闭环)**: 旧版进程若在本安装释放之后才启动、或在部署目录被删除后
# 重建旧路径, 新版无从协调 —— 旧版只认目录内的路径, 新版不能为一个已卸载的目录保留占位。
INSTALL_LEGACY_LOCK_FILE="$DEPLOY_DIR/.install.lock.fd"
INSTALL_LEGACY_LOCK_DIR="$DEPLOY_DIR/.install.lock"
INSTALL_LOCK_HELD=0
INSTALL_LOCK_FD=""
INSTALL_LEGACY_LOCK_FD=""
INSTALL_LEGACY_LOCK_DIR_HELD=0

_install_lock_owner_pid() {   # [锁目录]; 输出持有者 PID; 非数字/空/**数值为 0** 一律输出空(视为"无法判定")
    local d="${1:-$INSTALL_LOCK_DIR}" p
    p=$(cat "$d/pid" 2>/dev/null)
    case "$p" in
        ''|*[!0-9]*) printf '%s' '' ;;
        # `kill -0 0` 与 `kill -0 00` 在 GNU 与 busybox 上都返回 0(永远"存活"), 故凡是
        # **数值为 0** 的写法(0 / 00 / 000)都必须归入"无法判定", 不能只特判字面 `0`
        # —— 否则一个零填充的 pidfile 会让锁永久拒绝(实测 13s 后报"另一个安装正在运行(pid 00)")。
        *)           [ "$((10#$p))" -eq 0 ] && { printf '%s' ''; return 0; }
                     printf '%s' "$p" ;;
    esac
}

_install_lock_write_pid() {   # [锁目录]; 同目录 rename 原子写入, 避免半写
    local d="${1:-$INSTALL_LOCK_DIR}" t
    t="$d/.pid.$$"
    printf '%s\n' "$$" > "$t" 2>/dev/null || return 1
    mv -f "$t" "$d/pid" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
    return 0
}

# mkdir 锁的取用(主锁与旧版锁共用同一实现, 避免"同一条件在各调用点各自解释"):
# **永不自动接管** —— 残留锁目录一律拒绝并要求人工清理, 只删本进程自己创建的锁。
_install_lock_mkdir_take() {   # <锁目录> <显示名>; 复用同一实现, 无隐藏全局状态
    local d="$1" label="$2" i pid
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        if mkdir "$d" 2>/dev/null; then
            if _install_lock_write_pid "$d"; then return 0; fi
            rm -rf "$d" 2>/dev/null
            echo "[错误] 无法写入${label} $d/pid(磁盘空间/权限?), 安装中止"
            return 1
        fi
        # 路径存在但不是目录 => 明确报错, 不 rm、不等待(等待不会让它变成目录)
        if [ ! -d "$d" ]; then
            echo "[错误] ${label}路径存在但不是目录: $d"
            echo "       请手动处理该路径后重试"
            return 1
        fi
        pid=$(_install_lock_owner_pid "$d")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            [ "$i" -eq 14 ] && {
                echo "[错误] 另一个安装正在运行(pid $pid), 本次中止以免两棵树互相覆盖"
                echo "       若确认该进程已不存在, 请手动删除: $d"
                return 1; }
            sleep 1; continue
        fi
        # 陈旧或无法判定: 本实现**不接管**(见上方实测结论), 但立刻给出可执行的处置办法,
        # 而不是让用户干等 14 秒后才看到同一句话。
        echo "[错误] 检测到无人持有的${label}(pid ${pid:-未知}): $d"
        echo "       该目录可能是上次被强杀(SIGKILL)留下的; 确认无其他安装正在运行后,"
        echo "       请手动删除该目录后重试"
        return 1
    done
    echo "[错误] 等待${label}超时: $d"
    return 1
}

_install_lock_mkdir_release() {   # <锁目录>; 归属校验后才删
    local d="$1" p
    p=$(_install_lock_owner_pid "$d")
    [ "$p" = "$$" ] && rm -rf "$d" 2>/dev/null
    return 0
}

# 确认"我们持有的旧版安装锁 fd"仍指向**路径上那个文件**(十六轮 P2-②)。获取顺序是
# "主锁 → mkdir 部署目录 → flock 旧版锁文件"; 旧版卸载者若在中间 `rm -rf` 掉整棵树, 我们
# 打开的锁文件会被解除链接, 之后 flock 成功却落在无目录项的 inode 上, 而新来的旧版进程能在
# 同一路径重建文件并同时加锁。复核失败即拒绝(宁可拒绝, 不做双重放行); fd 目标无法读取时
# 同样拒绝，不能把"无法确认仍指向原路径"当成安全。
_install_lock_inode_ok() {   # <fd> <path>
    local fd="$1" p="$2" t
    [ -n "$fd" ] && [ -n "$p" ] || return 0
    [ -e "$p" ] || return 1
    t=$(readlink "/proc/self/fd/$fd" 2>/dev/null) || return 1
    case "$t" in
        "$p") return 0 ;;
        *" (deleted)") return 1 ;;
        *) return 1 ;;
    esac
}

# 旧版安装器不认识部署目录外的新锁。若旧版已拿到目录内锁并在卸载时删掉整棵树,
# 新版随后重建同名目录/锁路径会得到全新的 inode, 与旧进程手里的已删除 fd 不互斥。
# 在重建旧路径前扫描仍持有已删除部署文件的进程并 fail-closed。该检查只能缩小窗口;
# 旧版的 mkdir 锁在整棵树删除后没有可追踪 fd 时, 仍需等所有旧版进程退出后再重试。
_install_legacy_deleted_tree_active() {   # <deploy_dir>; 0 = 其他进程仍持有已删除树中的 fd
    local root="${1%/}" p pid target prefix matches find_rc
    [ -n "$root" ] || return 1
    prefix="${root}/"
    if command -v find >/dev/null 2>&1; then
        matches=$(find /proc/[0-9]*/fd -type l -lname "${prefix}* (deleted)" -print -quit 2>/dev/null)
        find_rc=$?
        if [ "$find_rc" -eq 0 ]; then
            [ -n "$matches" ] && return 0
            return 1
        fi
    fi
    for p in /proc/[0-9]*/fd/*; do
        pid=${p#/proc/}; pid=${pid%%/*}
        [ "$pid" = "$$" ] && continue
        target=$(readlink "$p" 2>/dev/null) || continue
        case "$target" in
            "$prefix"*" (deleted)") return 0 ;;
        esac
    done
    return 1
}

_install_lock_acquire() {
    local install_lock_parent="${DEPLOY_DIR%/*}"
    [ -n "$install_lock_parent" ] || install_lock_parent="/"
    mkdir -p "$install_lock_parent" 2>/dev/null || {
        echo "[错误] 无法创建安装锁父目录 $install_lock_parent(权限/只读文件系统?), 安装中止"
        return 1
    }
    # ---- 首选: flock(内核持有, 进程退出即释放, 无陈旧锁/无接管竞态) ----
    if command -v flock >/dev/null 2>&1; then
        # **动态分配 fd, 不要写死 9**: `lib/00-common.sh` 的 `_with_config_lock` 用
        # `exec 9>"$DEPLOY_DIR/.config.lock"` 也占 fd 9 —— 写死 9 会在同一进程里互相踩掉
        # 对方的锁(fd 被重新赋值即释放原锁), 表现为"锁莫名失效"。`{var}` 形式由 shell
        # 保证分配一个空闲 fd。
        exec {INSTALL_LOCK_FD}>>"$INSTALL_LOCK_FILE" 2>/dev/null || {
            INSTALL_LOCK_FD=""
            echo "[错误] 无法打开安装锁文件 $INSTALL_LOCK_FILE(磁盘空间/权限?)"; return 1; }
        if flock -n "$INSTALL_LOCK_FD" 2>/dev/null; then
            INSTALL_LOCK_HELD=1
            printf '%s\n' "$$" >&"$INSTALL_LOCK_FD" 2>/dev/null || true   # 仅供诊断, 权威在 fd
            if ! mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
                echo "[错误] 无法创建部署目录 $DEPLOY_DIR, 安装中止"
                _install_lock_release
                return 1
            fi
            if _install_legacy_deleted_tree_active "$DEPLOY_DIR"; then
                echo "[错误] 检测到旧版进程仍持有已删除部署树的文件, 本次安装中止"
                _install_lock_release
                return 1
            fi
            # 旧版同为 flock 路径(`.install.lock.fd`): 拿不到就说明旧版安装/卸载仍在跑。
            exec {INSTALL_LEGACY_LOCK_FD}>>"$INSTALL_LEGACY_LOCK_FILE" 2>/dev/null || {
                INSTALL_LEGACY_LOCK_FD=""
                echo "[错误] 无法打开旧版安装锁文件 $INSTALL_LEGACY_LOCK_FILE(权限/只读文件系统?), 安装中止"
                _install_lock_release
                return 1; }
            if ! flock -n "$INSTALL_LEGACY_LOCK_FD" 2>/dev/null; then
                echo "[错误] 旧版安装/卸载仍在运行(持有 $INSTALL_LEGACY_LOCK_FILE), 本次中止"
                echo "       以免两棵树互相覆盖; 等它退出后重试(内核会在持有进程退出时自动释放)"
                _install_lock_release
                return 1
            fi
            # 旧版卸载者可能在我们打开锁文件后 `rm -rf` 掉整棵树: 复核 inode 身份(P2-②),
            # 否则我们握着的是已解除链接的 inode, 与"路径上新建文件的旧版进程"会同时放行。
            if ! _install_lock_inode_ok "${INSTALL_LEGACY_LOCK_FD:-}" "$INSTALL_LEGACY_LOCK_FILE"; then
                echo "[错误] 旧版安装锁文件在获取后被替换/删除(部署目录正被卸载?), 本次中止"
                _install_lock_release
                return 1
            fi
            if _install_legacy_deleted_tree_active "$DEPLOY_DIR"; then
                echo "[错误] 检测到旧版进程仍持有已删除部署树的文件, 本次安装中止"
                _install_lock_release
                return 1
            fi
            return 0
        fi
        eval "exec ${INSTALL_LOCK_FD}>&-" 2>/dev/null
        INSTALL_LOCK_FD=""
        echo "[错误] 另一个安装正在运行(或上一次安装的残留锁尚未释放 —— 它会在持有它的子进程"
        echo "       退出后释放, 通常数十秒; 启用 retry 时可能更久)。本次中止以免两棵树互相覆盖"
        return 1
    fi
    # ---- 退路: mkdir-only(无 flock 的裁剪版 busybox), **永不自动接管** ----
    # 主锁取到**之后**才创建部署目录: 旧版锁路径就在该目录内, 必须等目录可写再取第二把。
    _install_lock_mkdir_take "$INSTALL_LOCK_DIR" "安装锁" || return 1
    INSTALL_LOCK_HELD=1
    if ! mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
        echo "[错误] 无法创建部署目录 $DEPLOY_DIR, 安装中止"
        _install_lock_release
        return 1
    fi
    if _install_legacy_deleted_tree_active "$DEPLOY_DIR"; then
        echo "[错误] 检测到旧版进程仍持有已删除部署树的文件, 本次安装中止"
        _install_lock_release
        return 1
    fi
    # 旧版无 flock 时用的是 `$DEPLOY_DIR/.install.lock` 目录锁: 这里同样 mkdir 下来,
    # 旧版读到活 pid 会等待/拒绝; 我们读不到活 pid 时也一律拒绝, 不接管别人的现场。
    _install_lock_mkdir_take "$INSTALL_LEGACY_LOCK_DIR" "旧版安装锁" || {
        _install_lock_release
        return 1
    }
    INSTALL_LEGACY_LOCK_DIR_HELD=1
    return 0
}

_install_lock_release() {
    [ "${INSTALL_LOCK_HELD:-0}" = "1" ] || return 0
    if [ -n "${INSTALL_LOCK_FD:-}" ]; then
        # flock 路径: 释放由 fd 承担。**不删锁文件** —— 删了会让"路径不存在"与"仍有进程
        # 持有 fd"并存, 造成诊断混乱; 文件留着无副作用, 下次 `exec {var}>>` 复用它。
        if [ -n "${INSTALL_LEGACY_LOCK_FD:-}" ]; then
            flock -u "$INSTALL_LEGACY_LOCK_FD" 2>/dev/null
            eval "exec ${INSTALL_LEGACY_LOCK_FD}>&-" 2>/dev/null
            INSTALL_LEGACY_LOCK_FD=""
        fi
        flock -u "$INSTALL_LOCK_FD" 2>/dev/null
        eval "exec ${INSTALL_LOCK_FD}>&-" 2>/dev/null
        INSTALL_LOCK_FD=""
    else
        # mkdir 路径: 归属校验后才删 —— 绝不删别人的锁(旧版锁目录同样)
        if [ "${INSTALL_LEGACY_LOCK_DIR_HELD:-0}" = "1" ]; then
            _install_lock_mkdir_release "$INSTALL_LEGACY_LOCK_DIR"
            INSTALL_LEGACY_LOCK_DIR_HELD=0
        fi
        _install_lock_mkdir_release "$INSTALL_LOCK_DIR"
    fi
    INSTALL_LOCK_HELD=0
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
# 获取安装锁。位置刻意选在**参数互斥校验之后**(拼错开关不该创建 $DEPLOY_DIR 与锁, 那条路径
# 本应无副作用)且**在 _install_cleanup_stale 之前** —— 清理本身会改动 $DEPLOY_DIR, 放在锁外
# 就重新打开了 D1 那条数据丢失窗口。两个安装分支都从这里往下走, 故只获取一次, 不在分支里各写
# 一份(项目反模式: 同一条件在各调用点各自解释)。
#
# 释放有两条路, **两条都需要**:
#   · `trap ... EXIT` 覆盖所有 `exit N` 分支与 SIGINT/SIGTERM/SIGHUP(实测均触发);
#   · `exec "$INSTALL_BIN"` 之前**显式释放** —— 实测 EXIT trap **不跨 exec 触发**
#     (exec 替换进程映像, bash 没机会跑 trap), 只靠 trap 会让锁泄漏。
# **trap 必须在 acquire 之前安装**(2026-09-22 七轮复审 D3): 旧顺序在"acquire 成功、trap 尚未
# 安装"之间留了一个信号窗口, 此时锁已落盘却无人释放, 而进程继续走到 `exec`, PID 存活 ⇒
# 下一次安装判"另一个安装正在运行"并白等(实测 13s)。`_install_lock_release` 在
# `INSTALL_LOCK_HELD != 1` 时本就 no-op, 故先装 trap 对"acquire 失败"完全安全。
# SIGKILL 两条都覆盖不到 => flock 路径由内核自动释放兜住; mkdir 退路则提示人工清理。
# ---------------------------------------------------------------------------
trap '_install_lock_release' EXIT
if ! _install_lock_acquire; then
    exit 1
fi

# 清理 SIGKILL 残留的回滚目录(进程被强杀时回滚代码没机会执行, 备份会一直堆积)。
# 放在两个安装分支之前, 使 update 与首次安装都受益。**必须在锁内**执行。
_install_cleanup_stale

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
        # 变量名不能叫 local_ver 之外还带 local 前缀 —— 这里在函数外, 旧写法的
        # \`local local_ver=...\` 会让 bash 打印 "local: can only be used in a function"
        # 到 stderr(不影响功能, 但用户会看到一行莫名其妙的报错)。
        inst_ver=$(cat "$DEPLOY_DIR/VERSION" 2>/dev/null || echo "?")
        echo "[成功] 更新完成 (版本 ${inst_ver})"
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
    # 2026-09-21: 本地路径也走逐文件原子落地(tmp→mv), 与远程路径同一口径 ——
    # 目录级 cp 中途失败会留下"一半新一半旧"的 lib/, 主脚本启动时才以 source 失败暴露。
    # 2026-09-21 五轮复审(P1): 与远程路径同样升级为"备份 → 落地 → 复核 → 失败整体回滚"
    # (见 _install_backup 上方说明), 保证本地安装也不留混合版本。
    #
    # 源清单预检放在备份之前: 本地源缺文件时目标目录一个字节都不该动(备份阶段无意义)。
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
    # VERSION 与 VERSION 之外的清单同口径(**2026-09-22 open-code-review #05**)。
    # 旧写法在拷贝阶段打一句"[警告] 本地源缺少 VERSION, 更新检查将显示未知版本"然后**继续装**,
    # 而该说法有两个错: (1) `_verify_installed` 根本**不检查** VERSION(它只校验 LIB_MODULES /
    # TPL_NAMES / 主脚本), 所以"照装不误"成立; (2) 但部署目录里**上一版的 VERSION 会原样留着**
    # ⇒ 更新检查永远拿旧版本号跟远端比, 结论是"已是最新"而实际装的是新代码 —— 比"显示未知"
    # 危险得多。实测(部署目录预置 0.99.0, 本地源无 VERSION): 安装报成功, VERSION 仍是 0.99.0。
    # 远程路径把 VERSION 下载失败计入 `fail` 并中止(`fail>0` 分支), 本地路径不该对同一文件
    # 放宽 —— 预检统一拒绝, 且**在备份之前**, 目标目录一个字节都不动。
    if [ ! -s "${LOCAL_DIR}/VERSION" ]; then
        echo "[错误] 本地源缺少 VERSION(或为空), 安装中止"
        echo "       更新检查以它为本地真相源, 缺失会让部署目录保留旧版本号"
        exit 1
    fi

    # 与远程路径同口径: **不得**在备份前无条件 `rm -rf "$ROLLBACK_DIR"`(见 download_all
    # 同处的说明)。.KEEP 判定在 `_install_backup` 内部, 返回 2 = 恢复目录被标记占用。
    _bk_rc=0
    _install_backup || _bk_rc=$?
    if [ "$_bk_rc" -eq 2 ]; then
        exit 1
    fi
    if [ "$_bk_rc" -ne 0 ]; then
        rm -rf "$ROLLBACK_DIR" 2>/dev/null
        echo "[错误] 备份现有安装失败(磁盘空间/权限?), 未改动任何文件"; exit 1
    fi
    local_ok=1
    _install_file "${LOCAL_DIR}/xray-deploy.sh" "$DEPLOY_DIR/xray-deploy.sh" || local_ok=0
    # 与远程路径逐字同口径: 执行位设置失败必须走回滚(远程侧是 `chmod +x ... || copy_ok=0`)。
    # 旧写法 `2>/dev/null || true` 会让"主脚本落地了但不可执行"照样报"安装完成" ——
    # 用户执行 xd 时看到的是许可错误(open-code-review #02/#04; 顺手与本处 #05 同批修)。
    chmod +x "$DEPLOY_DIR/xray-deploy.sh" 2>/dev/null || local_ok=0
    # 预检已保证 `${LOCAL_DIR}/VERSION` 存在且非空, 这里不再有 else 分支(#05)。
    _install_file "${LOCAL_DIR}/VERSION" "$DEPLOY_DIR/VERSION" || local_ok=0
    for m in $LIB_MODULES; do
        _install_file "${LOCAL_DIR}/lib/${m}.sh" "$INSTALL_LIB_DIR/${m}.sh" || local_ok=0
    done
    for t in $TPL_NAMES; do
        _install_file "${LOCAL_DIR}/templates/${t}.server.jsonc" "$INSTALL_TPL_DIR/${t}.server.jsonc" || local_ok=0
    done
    if [ "$local_ok" -ne 1 ] || ! _verify_installed; then
        echo "[错误] 本地源落地/复核失败, 正在回滚到更新前状态..."
        # 与远程路径同口径: 回滚失败保留备份目录(唯一恢复源), 成功才清理。
        if _install_rollback; then
            rm -rf "$ROLLBACK_DIR" 2>/dev/null
        else
            echo "[错误] 回滚未完全成功, 已保留备份目录: $ROLLBACK_DIR"
            echo "       请人工从该目录恢复, 或重跑 install.sh --update"
        fi
        exit 1
    fi
    rm -rf "$ROLLBACK_DIR" 2>/dev/null
    _manifest_write || true
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

# 快捷命令与 xray 符号链接。**每一项都必须检查结果**(open-code-review #02):
# 这里是"安装完成"之前的最后两步, 旧写法不看出错就报 `[成功] 安装完成`, 而 `/usr/local/bin/xd`
# 可能根本没建出来 —— 用户拿到一条不存在的命令。注意 xd 的链接是**指向部署目录的符号链接**,
# 它丢了不影响 `bash install.sh` 重跑(重跑即重建), 故这里报错即可, 不回滚已落地的文件。
if ! ln -sf "$DEPLOY_DIR/xray-deploy.sh" "$INSTALL_BIN"; then
    echo "[错误] 创建快捷命令失败: $INSTALL_BIN(权限? /usr/local/bin 只读?)"
    exit 1
fi
if ! chmod +x "$INSTALL_BIN"; then
    echo "[错误] 设置快捷命令执行权限失败: $INSTALL_BIN"
    exit 1
fi
# xray 命令 symlink（检测已有安装不覆盖）
if [ ! -e /usr/local/bin/xray ] || [ "$(readlink -f /usr/local/bin/xray 2>/dev/null)" = "$DEPLOY_DIR/bin/xray" ]; then
    ln -sf "$DEPLOY_DIR/bin/xray" /usr/local/bin/xray || \
        echo "[警告] 创建 /usr/local/bin/xray 符号链接失败(不影响本部署, 可稍后手动补)"
fi

echo "[成功] xray-deploy 安装完成"
echo "[信息] 输入 ${CMD_NAME} 唤出主菜单"

if [ "$NO_START" -eq 0 ]; then
    # **必须显式释放**: 实测 EXIT trap 不跨 `exec` 触发(exec 替换进程映像, bash 没机会跑 trap),
    # 只靠 trap 会让锁泄漏到下一次安装(而持有者 PID 就是本进程, 只要本进程还在就会被判"存活")。
    _install_lock_release
    exec "$INSTALL_BIN"
fi
