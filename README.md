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
