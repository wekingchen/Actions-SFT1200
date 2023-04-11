#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#

wget https://github.com/coolsnowwolf/lede/raw/master/include/meson.mk  -P ./include/
wget https://github.com/coolsnowwolf/lede/raw/master/include/openssl-engine.mk  -P ./include/

# Uncomment a feed source
sed -i "/helloworld/d" "feeds.conf.default"

# Add a feed source
echo "src-git helloworld https://github.com/fw876/helloworld.git" >> "feeds.conf.default"
echo "src-git gl https://github.com/gl-inet/gl-feeds.git;18.06" >> "feeds.conf.default"
echo "src-git luci2 https://github.com/coolsnowwolf/luci" >> "feeds.conf.default"
echo "src-git packages2 https://github.com/coolsnowwolf/packages" >> "feeds.conf.default"
echo "src-git PWpackages https://github.com/xiaorouji/openwrt-passwall.git;packages" >> "feeds.conf.default"
echo "src-git PWluci https://github.com/xiaorouji/openwrt-passwall.git;luci" >> "feeds.conf.default"

./scripts/feeds clean
