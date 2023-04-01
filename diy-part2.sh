#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

svn co https://github.com/coolsnowwolf/lede/trunk/tools/ninja tools/ninja
svn co https://github.com/coolsnowwolf/lede/trunk/package/lean/adbyby package/adbyby
rm -rf feeds/packages/net/zerotier
svn co https://github.com/coolsnowwolf/packages/trunk/net/zerotier feeds/packages/net/zerotier
rm -rf feeds/packages2/multimedia/aliyundrive-webdav
svn co https://github.com/messense/aliyundrive-webdav/trunk/openwrt/aliyundrive-webdav feeds/packages2/multimedia/aliyundrive-webdav
rm -rf feeds/luci2/applications/luci-app-aliyundrive-webdav
svn co https://github.com/messense/aliyundrive-webdav/trunk/openwrt/luci-app-aliyundrive-webdav feeds/luci2/applications/luci-app-aliyundrive-webdav
rm -rf feeds/packages/lang/golang
rm -rf feeds/packages2/lang/golang
svn co https://github.com/openwrt/packages/branches/openwrt-22.03/lang/golang feeds/packages/lang/golang
svn co https://github.com/openwrt/packages/branches/openwrt-22.03/lang/golang feeds/packages2/lang/golang
rm -rf package/libs/openssl
wget 'https://github.com/201821143044/Actions-SFT1200-OpenWrt/raw/main/myfiles/openssl.zip' --no-check-certificate && unzip -o openssl.zip && rm -f openssl.zip
