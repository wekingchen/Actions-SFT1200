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
- 自动为 Siflower 选择 NaiveProxy 的 `mipsel_24kc-static` 预编译包；由只读 Preflight 解析 GitHub Release 官方 SHA256 digest，并同时记录当时的 `openwrt-passwall-packages` HEAD。build job 在 `feeds update` 后把 `feeds/PWpackages` 固定到同一 commit，再消费对应的版本/资产/digest，避免 Preflight 与 build 两次拉取 main 之间发生版本竞态。若目标 Release 资产没有 GitHub 提供的 SHA256 digest，则构建直接失败，不降级为“下载后自算 hash”。
- 使用较新的 Shadowsocks / Xray / Go / Rust 等代理相关组件。
- 隔离现代 LuCI 的 `luci-compat / luci-lua-runtime / ucode` 依赖，继续使用 18.06 原生 Lua LuCI。
- 固定使用 OpenWrt 18.06 官方 miniupnpd，避免现代 nftables 变种污染旧 Kconfig。
- 修复 OpenWrt 18.06 CMake 与 ccache 在现代构建环境中的兼容问题。
- 保留 ZeroTier、AliyunDrive WebDAV、HAProxy、Adbyby 等现有功能。

## GitHub Actions

### SFT1200 固件编译

手动进入 **Actions → SFT1200 固件编译 → Run workflow** 即可编译。

工作流包含：

- 下载缓存 `dl/`
- C/C++ ccache
- Go `GOCACHE`
- build job 总时长上限为 180 分钟；最近一次明确的冷缓存构建约 98 分钟，保留额外余量用于工具链、Rust/Go、下载和 Runner 波动
- 精简的控制台编译输出
- 编译失败时自动上传完整诊断日志
- 固件 manifest 功能完整性检查
- 成功构建自动生成最终配置留档，并上传 `config-record` Artifact
- 编译成功后上传 `bin` Artifact 与 Release；Release 同时附带配置留档
- build job 仅有 `contents: read`，`actions/checkout` 禁止持久化凭据；feeds、Makefile、`make`、`diy-part2.sh` 等第三方构建代码运行期间没有 GitHub 写令牌。
- Release 附件先由 build job 打包为短期 Artifact，再交给独立 release job；只有 release job 拥有 `contents: write + actions: write`，并使用 Runner 自带 `gh` CLI 发布和清理，不把写令牌交给第三方 Release Action。
- 自动清理旧 Workflow Runs；只有本轮固件成功发布 Release 后，才清理旧 Releases 并保留最近 10 个，失败构建不会占用或挤掉 Release 位置。

### SFT1200 上游更新检查

每 12 小时检查一次：

- `Openwrt-Passwall/openwrt-passwall-packages:main`
- `Openwrt-Passwall/openwrt-passwall:main`
- `fw876/helloworld:master`

任一仓库出现新提交时，通过 GitHub 原生 `repository_dispatch` 触发一次固件构建。

这里的“已处理”语义是**已成功提交构建请求**，不是“固件已经编译成功”：

- 当新的上游组合指纹第一次出现时，update-checker 先触发主构建；只要 `repository_dispatch` 请求成功，就把该组合指纹保存到 Actions Cache。
- 如果随后主构建本身失败，update-checker 不会因为这次失败自动重试同一个组合指纹；通常要等被监控的上游再次产生新提交，形成新的组合指纹后才会再次触发。需要立即重试时，应手动运行主构建工作流。
- 状态使用 Actions Cache 只是轻量去重，不是永久数据库。GitHub 默认会回收长时间未访问的缓存，也会在缓存空间达到限制时按最近访问时间逐出旧条目。
- 当前 update-checker 每 12 小时都会尝试恢复“当前上游组合指纹”的 cache；正常持续运行并命中时，这个状态会持续被访问，因此通常不会单纯因为上游长期不更新而触发“7 天后重复构建”。如果 cache 因容量策略、仓库缓存设置变化或检查任务长期未运行等原因消失，则下一次检查会把当前组合指纹当作新状态，并重新触发一次构建。

这个取舍是有意的：update-checker 负责“上游变化去重并触发”，不负责判断主构建最终是否成功，也不做无限自动重试，避免上游版本暂时不兼容时每 12 小时重复消耗完整编译资源。

## 构建配置留档机制

仓库根目录的 `.config` 是**长期维护基线**，代表我们主动选择并希望长期保留的功能配置。CI 不会在编译成功后自动把最终 `.config` 回写仓库，避免把上游 Kconfig 的临时默认变化、依赖自动展开或无意义排序变化永久固化。

每次构建通过 `make` 和最终 firmware manifest 验收后，工作流会自动调用 `scripts/archive-config.sh` 生成 `config-record`，并同时：

- 上传为本次 Actions 的 `OpenWrt_config_record...` Artifact。
- 附加到本次 GitHub Release，便于以后从最近保留的 Release 直接追溯构建配置。
- 在 Actions `Step summary` 中显示最终 `.config` SHA256、变化数量，以及差异前 80 行。

`config-record` 中包含：

- `repository.config`：本次构建开始时仓库中的 `.config` 基线。
- `final.config`：经过 `diy-part2.sh`、`make defconfig` 后，本次固件真正使用的最终 `.config`。
- `diffconfig.txt`：OpenWrt `scripts/diffconfig.sh` 的输出，只保留相对默认配置真正有意义的选项；人工复核和迁移时优先看它。
- `config-changes.diff`：按 `CONFIG_*` symbol 比较 `repository.config` 与 `final.config` 的语义差异，忽略纯排序变化。
- `build-info.txt`：记录仓库 commit、Actions run、设备 profile、feeds 指纹、PWpackages 构建快照 commit、build cache 指纹、最终 `.config` SHA256，以及 NaiveProxy 实际版本、资产名与经 GitHub Release digest 验证的 SHA256。
- `README.txt`：Artifact 内置使用说明；即使以后只下载到这一份留档，也能知道每个文件的用途。

### 什么时候需要更新仓库 `.config`

正常情况下**不需要**因为一次成功构建就更新仓库 `.config`。只有当 `config-changes.diff` 显示的变化是我们明确希望长期保留的配置策略变化时，才建议提升新的基线：

1. 先查看 `config-changes.diff`，确认新增、删除或改变的配置项都是预期变化。
2. 再查看 `diffconfig.txt`，确认 Passwall、SSR Plus、Xray、Hysteria、NaiveProxy 等关键功能选择仍然正确。
3. 确认无误后，将 `final.config` 复制为仓库根目录 `.config`。
4. 提交 `.config`，并让下一次正式构建重新经过 Preflight、Compile 和 manifest 验收。

不要把 `final.config` 自动回写仓库；成功只说明这一组配置可以构建并通过当前验收，不代表所有由上游自动引入的 Kconfig 变化都应该成为长期维护策略。

### 手工编译时使用同一机制

本地或 SSH 调试完成后也可以生成与 CI 完全相同的留档：

```bash
scripts/archive-config.sh \
  /path/to/Actions-SFT1200/.config \
  /path/to/openwrt/.config \
  /path/to/config-record
```

第一个参数必须是**仓库基线 `.config`**，第二个参数是经过兼容脚本和 `make defconfig` 后的**最终 `.config`**。
## 关键文件

- `.config`：当前 SFT1200 固件功能配置。
- `diy-part1.sh`：feeds 更新前处理。
- `diy-part2.sh`：主要兼容层和软件包替换逻辑。
- `.github/workflows/build-openwrt.yml`：主编译工作流。
- `.github/workflows/update-checker.yml`：Passwall 与 helloworld 上游更新监控。
- `scripts/patch-gen-config.py`：以可审查方式为上游 `scripts/gen_config.py` 注入 SFT1200/OpenWrt 18.06 feeds 兼容钩子。
- `scripts/resolve-naiveproxy-release.py`：在只读 Preflight 中解析 NaiveProxy Release 资产及官方 digest，避免 build job 持有 GitHub token。
- `scripts/archive-config.sh`：成功构建的最终配置留档与差异生成工具。
- `libs.zip`：本仓库维护的 OpenSSL / ustream 兼容文件。
- `board-2.bin.*`：SFT1200 板级文件。

## 说明

这是一个针对老版本 Siflower SDK/OpenWrt 18.06 的长期维护构建仓库。上游 feeds 发生较大结构变化时，即使源码本身没有变化，也可能需要新增兼容补丁。

正式改动建议先在测试分支完整编译验证，再合入 `main`。
