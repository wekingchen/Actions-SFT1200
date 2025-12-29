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

rm -rf feeds/packages2/net/xray-core
rm -rf feeds/packages2/net/v2ray-geodata
rm -rf feeds/packages2/net/sing-box
rm -rf feeds/packages2/net/chinadns-ng
rm -rf feeds/packages2/net/dns2socks
rm -rf feeds/packages2/net/dns2tcp
rm -rf feeds/packages2/net/microsocks
rm -rf feeds/packages/net/shadowsocks-libev
cp -r feeds/packages2/lang/rust feeds/packages/lang
cp -r feeds/PWpackages/xray-core feeds/packages2/net
cp -r feeds/PWpackages/v2ray-geodata feeds/packages2/net
cp -r feeds/PWpackages/sing-box feeds/packages2/net
cp -r feeds/PWpackages/chinadns-ng feeds/packages2/net
cp -r feeds/PWpackages/dns2socks feeds/packages2/net
cp -r feeds/helloworld/dns2tcp feeds/packages2/net
cp -r feeds/PWpackages/microsocks feeds/packages2/net
cp -r feeds/PWpackages/shadowsocks-libev feeds/packages/net

# 回滚microsocks源码到能最后编译成功的版本
wget https://github.com/xiaorouji/openwrt-passwall-packages/archive/9feb8ca7dbc14f281fdbc7f8044839f6c2bf56ec.zip
unzip 9feb8ca7dbc14f281fdbc7f8044839f6c2bf56ec.zip
rm -rf feeds/packages2/net/microsocks
cp -r openwrt-passwall-packages-9feb8ca7dbc14f281fdbc7f8044839f6c2bf56ec/microsocks feeds/packages2/net
rm -rf 9feb8ca7dbc14f281fdbc7f8044839f6c2bf56ec.zip openwrt-passwall-packages-9feb8ca7dbc14f281fdbc7f8044839f6c2bf56ec

# 修改naiveproxy编译源码以支持mips_siflower
# 1) 先删除（如果有）之前误插入的 mips_siflower 映射两行，避免重复
sed -i '/else ifeq (\$(ARCH_PREBUILT),mips_siflower)/,+1 d' \
feeds/PWpackages/naiveproxy/Makefile

# 2) 把 mips_siflower -> mipsel_24kc-static 正确插到 “ARCH_PREBUILT:=riscv64” 这一行之后
#    （注意：锚点是赋值行，而不是 “riscv64_riscv64)” 的条件行）
sed -i '/^[[:space:]]*ARCH_PREBUILT:=riscv64[[:space:]]*$/a\
else ifeq ($(ARCH_PREBUILT),mips_siflower)\
  ARCH_PREBUILT:=mipsel_24kc-static' \
feeds/PWpackages/naiveproxy/Makefile

# 3) 修复并收尾 PKG_HASH 分支
sed -i '/^else ifeq (\$(ARCH_PREBUILT),x86_64)/,/^endif/ c\
else ifeq ($(ARCH_PREBUILT),x86_64)\n  PKG_HASH:=5681e13c833757cfb5769755fd93d1906c47448af190585067bde9de590bdb2e\nelse ifeq ($(ARCH_PREBUILT),mipsel_24kc-static)\n  PKG_HASH:=0ca95c162104c327f3f34be3f291445b098c44c5e7763206c13730e7974d7a34\nelse\n  PKG_HASH:=dummy\nendif' \
feeds/PWpackages/naiveproxy/Makefile

# 4) （推荐）让解包动作使用 $(PKG_SOURCE)，避免文件名不同步
sed -i 's|-xJf $(DL_DIR)/naiveproxy-v$(PKG_VERSION)-$(PKG_RELEASE)-openwrt-$(ARCH_PREBUILT).tar.xz|-xJf $(DL_DIR)/$(PKG_SOURCE)|' \
feeds/PWpackages/naiveproxy/Makefile

rm -rf feeds/packages/devel/diffutils
rm -rf feeds/packages/utils/jq
rm -rf feeds/gl_feed_common/zerotier
rm -rf feeds/gl_feed_1806/haproxy
cp -r feeds/packages2/devel/diffutils feeds/packages/devel
cp -r feeds/packages2/utils/jq feeds/packages/utils
cp -r feeds/packages2/net/zerotier feeds/gl_feed_common
cp -r feeds/packages2/net/haproxy feeds/gl_feed_1806

# haproxy修改依赖支持到lua5.4
sed -i -E \
  -e 's/\+liblua5\.3/\+liblua5\.4/g' \
  -e 's/LUA_LIB_NAME="?lua5\.3"?/LUA_LIB_NAME="lua5.4"/g' \
  -e 's|/include/lua5\.3|/include/lua5.4|g' \
  feeds/gl_feed_1806/haproxy/Makefile

# 修改golang源码以编译xray1.8.8+版本
rm -rf feeds/gl_feed_common/golang
git clone https://github.com/sbwml/packages_lang_golang -b 25.x feeds/gl_feed_common/golang
sed -i '/-linkmode external \\/d' feeds/gl_feed_common/golang/golang-package.mk

# 增加阿里云盘WebDAV 及其 LuCI
set -euo pipefail
rm -rf feeds/packages2/multimedia/aliyundrive-webdav feeds/luci2/applications/luci-app-aliyundrive-webdav
git clone --depth=1 https://github.com/messense/aliyundrive-webdav.git aliyundrive-webdav
cp -a aliyundrive-webdav/openwrt/aliyundrive-webdav feeds/packages2/multimedia
cp -a aliyundrive-webdav/openwrt/luci-app-aliyundrive-webdav feeds/luci2/applications
rm -rf aliyundrive-webdav

git clone https://github.com/coolsnowwolf/lede.git
cp -r lede/tools/ninja tools
cp -r lede/package/lean/adbyby package
rm -rf lede

git clone https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome

rm -rf package/libs/openssl
rm -rf package/libs/ustream-ssl
wget 'https://github.com/wekingchen/Actions-SFT1200/raw/main/libs.zip' --no-check-certificate && unzip -o libs.zip && rm -f libs.zip
wget https://github.com/wekingchen/Actions-SFT1200/raw/main/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe -P dl/

# 修复 host ncurses 静态库 relocation 错误
sed -i '/^PKG_BUILD_DEPENDS:=ncurses\/host/a HOST_CFLAGS += -fPIC' package/libs/ncurses/Makefile

# 清理老的 hostpkg ncurses —— 用内置目标更安全，且不存在也不会失败
make package/ncurses/host/clean || true

# 强制只用动态库 —— 目录不存在时直接跳过，避免 find 报错
if [ -d staging_dir/hostpkg/lib ]; then
  find staging_dir/hostpkg/lib -type f -name 'libncurses.a' -delete || true
  find staging_dir/hostpkg/lib -type f -name 'libpanel.a'   -delete || true
fi

# 运行时库搜索路径（LD_LIBRARY_PATH 可能为空，给默认值）
export LD_LIBRARY_PATH="staging_dir/hostpkg/lib:${LD_LIBRARY_PATH:-}"
