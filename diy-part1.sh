#!/usr/bin/env bash
#
# SFT1200 / Siflower OpenWrt 18.06 feeds 更新前处理
#

set -Eeuo pipefail

# 18.06 原树缺少现代 meson 构建规则，补入 LEDE 当前版本。
# 使用 raw 地址并拒绝 HTML 错误页，避免把网页误当成 Makefile。
curl -fsSL \
  https://raw.githubusercontent.com/coolsnowwolf/lede/master/include/meson.mk \
  -o ./include/meson.mk

[ -s ./include/meson.mk ] || {
  echo "ERROR: include/meson.mk 下载为空" >&2
  exit 1
}
if grep -qiE '<!DOCTYPE html|<html[ >]' ./include/meson.mk; then
  echo "ERROR: include/meson.mk 下载结果是 HTML，不是 Makefile" >&2
  exit 1
fi

# meson.mk 直接追踪 LEDE master 的单文件内容，无法用仓库 commit 精确表示。
# 记录实际参与本轮构建的文件 SHA256，后续由 diy-part2 继续追加其他动态上游。
meson_sha256="$(sha256sum ./include/meson.mk | awk '{print $1}')"
[[ "$meson_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "ERROR: include/meson.mk SHA256 无效：$meson_sha256" >&2
  exit 1
}
printf 'upstream_meson_mk_sha256=%s\n' "$meson_sha256" > .sft1200-upstreams.env
echo "上游快照：upstream_meson_mk_sha256=$meson_sha256"

# 旧的 openssl-engine.mk 下载地址现在返回 HTML，而且当前完整构建并未使用该文件，
# 因此不再注入这个失效文件。

# 删除默认 helloworld，改用下面显式指定的源。
sed -i "/helloworld/d" "feeds.conf.default"

# 增加本项目需要的 feeds。
echo "src-git gl https://github.com/gl-inet/gl-feeds.git;18.06" >> "feeds.conf.default"
echo "src-git luci2 https://github.com/coolsnowwolf/luci.git^9253314349c17ebdb593a77457582f779da4b862" >> "feeds.conf.default"
echo "src-git packages2 https://github.com/coolsnowwolf/packages" >> "feeds.conf.default"
echo "src-git PWpackages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main" >> "feeds.conf.default"
echo "src-git PWluci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main" >> "feeds.conf.default"
echo "src-git helloworld https://github.com/fw876/helloworld.git;master" >> "feeds.conf.default"

./scripts/feeds clean
