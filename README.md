# xray-deploy

## 📥 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/UIMAK/xray-deploy/main/install.sh || wget -qO- https://raw.githubusercontent.com/UIMAK/xray-deploy/main/install.sh)
```

**快捷命令:`xd`**(安装后输入 `xd` 唤出主菜单)

## ⚠️ 官方 Hysteria2 模块的行为边界(与旧版/官方安装脚本不同, 有意为之)

`[6] Hysteria2 管理`(官方核心)对 CPU 架构采取**比官方 `get.hy2.sh` 更严格**的兼容性策略 —— 这是**有意的 breaking behavior**, 宁可拒绝也不猜:

| `uname -m` | 处理 |
|---|---|
| `x86_64`/`amd64` | `amd64`; CPU(`/proc/cpuinfo`)支持 AVX 时**自动**选用 `amd64-avx` 变体, 不提供手动开关 |
| `i386`/`i486`/`i586`/`i686` | `386` |
| `aarch64`/`arm64`/`armv8*` | `arm64` |
| `armv7`/`armv7l` | `arm` |
| `armv5*` | `armv5` |
| `mipsle` | `mipsle`(小端; 含软浮点设备手选 `mipsle-sf` 不受影响) |
| `s390x` / `riscv64` / `loongarch64` | `s390x` / `riscv64` / `loong64` |
| `armv6`/`armv6l` | **拒绝** —— 官方 `linux/arm` 资产是 GOARM=7 构建, 在 ARMv6 CPU 上必然 SIGILL, 且官方无 armv6 独立构建, 不做映射猜测 |
| `mips`/`mips64`/`mips64le` | **拒绝** —— 大端/64 位 MIPS 与官方 mipsle(小端)资产 ABI 不兼容, 安装能过校验但必然跑不起来 |

其余说明: 官方安装脚本 `get.hy2.sh` 本身不支持 Alpine, 本模块自带的 OpenRC 支持属自有实现; 官方 URI 无法携带 gecko 分片尺寸(minPacketSize/maxPacketSize 是配置字段), 因此 gecko 使用非默认尺寸时**不生成分享链接**(clash/mihomo 配置可完整表达)。

### 认证模型 = 单一认证密码(不是 userpass 多用户)

官方 Hysteria 服务端的 `auth` 段有两种形态: `password`(一个密码)与 `userpass`(用户名→密码映射表)。本模块用 **`auth.type: password`(单密码)**, 理由不是偏好而是**互操作硬约束**:

- 官方 `userpass` 的客户端认证串是 **`用户名:密码`**。Xray 的 hysteria 入站认证字段(`settings.users[].auth`)与 sing-box 的 hysteria2 `password` 都只是"一个字符串", **不会替你拼 `user:pass`** —— 用户必须手填 `user:pass` 才能连上。sing-box 官方文档亦明文: "官方程序支持 userpass…本质上是把 `<username>:<password>` 当实际密码, 而 sing-box 不提供此别名"。
- 单密码下, 分享链接的 userinfo 只有一个 auth 段(`hysteria2://<密码>@host:port/`)、clash/mihomo 的 `password` 就是密码本身, 与 Xray/sing-box 的"认证密码"一一对应, **复制即用**。

代价(已与用户确认): 官方服务端一个 auth 段只能有一个密码, 故本模块**不再支持多用户** —— 一个节点 = 这一台服务器的唯一凭据。旧版 `userpass` 多用户配置会在进入菜单或执行 `[2] 添加节点` 时**一次性迁移**: 取用户名排序后的第一个用户的密码, 其余用户的密码不再生效(会明确告警), 旧 `nodes/` 目录改名保留为 `hysteria/nodes.userpass.bak/` 供人工核对。

> 需要多套独立凭据时, 请分别部署多台服务器(每个实例一套密码)。

`[11] 拥塞控制` 对应官方 `congestion` 段: `type ∈ {bbr, reno}`(默认 bbr)、`bbrProfile ∈ {standard, conservative, aggressive}`(仅 `type: bbr` 时生效)。该段**只在对应方向未使用 Brutal 时生效**; 回车即用官方默认(不写入配置段)。

> 本模块是**官方 Hysteria 二进制**的管理器, 与菜单 `[6]` 的 **Xray Hy2**(Xray-core 的 hysteria2 协议, `_hy2_*`)是两条独立产品线: 不同二进制、不同配置模型、不同服务、不同节点存储。菜单结构对齐了原脚本的设计语言, 但**配置字段口径严格按各自官方文档**, 不可互相照搬。
