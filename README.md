# Actions-SFT1200

用于 **GL.iNet SFT1200 / Siflower OpenWrt 18.06** 的 GitHub Actions 固件编译仓库。

这个仓库不是追求把 18.06 整体升级到现代 OpenWrt，而是在保留原有硬件支持和功能的前提下，对需要更新的软件做针对性兼容。

## 维护原则

- OpenWrt 18.06 系统底座以稳定、可编译、可刷机为第一优先级。
- Passwall、Xray、NaiveProxy、Shadowsocks、ShadowsocksR、chinadns-ng、dns2socks、microsocks 等代理/分流组件尽量跟随上游更新。
- 不为了编译通过而删除现有功能；遇到新旧依赖冲突优先做兼容处理。
- 非代理系统组件不盲目追新，能稳定工作即可。
- 每次正式构建后检查固件 manifest，关键功能包缺失时即使 make 成功也视为构建失败。

## 当前主要兼容处理

核心逻辑位于 [diy-part2.sh](diy-part2.sh)：

- Passwall UI 与 Passwall packages 跟随上游 main。
- 自动为 Siflower 选择 NaiveProxy 的 `mipsel_24kc-static` 预编译包，并自动下载、计算和写入 SHA256。
- 使用较新的 Shadowsocks / Xray / Go / Rust 等代理相关组件。
- 隔离现代 LuCI 的 `luci-compat / luci-lua-runtime / ucode` 依赖，继续使用 18.06 原生 Lua LuCI。
- 固定使用 OpenWrt 18.06 官方 miniupnpd，避免现代 nftables 变种污染旧 Kconfig。
- 修复 OpenWrt 18.06 CMake 与 ccache 在现代构建环境中的兼容问题。
- 保留 ZeroTier、AliyunDrive WebDAV、HAProxy、Adbyby 等现有功能。

## GitHub Actions

### Build OpenWrt

手动进入 **Actions → Build OpenWrt → Run workflow** 即可编译。

工作流包含：

- 下载缓存 `dl/`
- C/C++ ccache
- Go `GOCACHE`
- 精简的控制台编译输出
- 编译失败时自动上传完整诊断日志
- 固件 manifest 功能完整性检查
- 编译成功后上传 `bin` Artifact 与 Release
- 自动清理旧 Workflow Runs 和旧 Releases

### Update Checker

每 12 小时检查一次：

- `Openwrt-Passwall/openwrt-passwall-packages:main`
- `Openwrt-Passwall/openwrt-passwall:main`

任一仓库出现新提交时，通过 GitHub 原生 `repository_dispatch` 触发一次固件构建。

## 关键文件

- `.config`：当前 SFT1200 固件功能配置。
- `diy-part1.sh`：feeds 更新前处理。
- `diy-part2.sh`：主要兼容层和软件包替换逻辑。
- `.github/workflows/build-openwrt.yml`：主编译工作流。
- `.github/workflows/update-checker.yml`：Passwall 上游更新监控。
- `libs.zip`：本仓库维护的 OpenSSL / ustream 兼容文件。
- `board-2.bin.*`：SFT1200 板级文件。

## 说明

这是一个针对老版本 Siflower SDK/OpenWrt 18.06 的长期维护构建仓库。上游 feeds 发生较大结构变化时，即使源码本身没有变化，也可能需要新增兼容补丁。

正式改动建议先在测试分支完整编译验证，再合入 `main`。
