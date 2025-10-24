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
rm -rf feeds/packages2/net/microsocks
rm -rf feeds/packages/net/shadowsocks-libev
cp -r feeds/packages2/lang/rust feeds/packages/lang
cp -r feeds/PWpackages/xray-core feeds/packages2/net
cp -r feeds/PWpackages/v2ray-geodata feeds/packages2/net
cp -r feeds/PWpackages/sing-box feeds/packages2/net
cp -r feeds/PWpackages/chinadns-ng feeds/packages2/net
cp -r feeds/PWpackages/dns2socks feeds/packages2/net
cp -r feeds/PWpackages/microsocks feeds/packages2/net
cp -r feeds/PWpackages/shadowsocks-libev feeds/packages/net

# 修改naiveproxy编译源码以支持mips_siflower
sed -i '/riscv64_riscv64)/a\else ifeq ($(ARCH_PREBUILT),mips_siflower)\n  ARCH_PREBUILT:=mipsel_24kc' feeds/PWpackages/naiveproxy/Makefile

# 将geoview版本固定到0.1.10
sed -i 's/PKG_VERSION:=0.1.11/PKG_VERSION:=0.1.10/' feeds/packages2/net/geoview/Makefile
sed -i 's/PKG_HASH:=a3ad07d3926c329f6990d67e17119f0c9a4ee26e89b0e2f541b27230c2806e94/PKG_HASH:=9221df928df68030893125a60bdf6d8a1fef2b199fa58ed80772cb3c17225fc5/' feeds/packages2/net/geoview/Makefile
sed -i '/PKG_USE_MIPS16:=0/a PKG_BUILD_FLAGS:=no-mips16' feeds/packages2/net/geoview/Makefile

rm -rf feeds/packages/devel/diffutils
rm -rf feeds/packages/utils/jq
rm -rf feeds/packages/net/zerotier
rm -rf feeds/gl_feed_common/zerotier
git clone https://github.com/coolsnowwolf/packages.git
cp -r packages/devel/diffutils feeds/packages/devel
cp -r packages/utils/jq feeds/packages/utils
cp -r packages/net/zerotier feeds/packages/net
cp -r packages/net/zerotier feeds/gl_feed_common
rm -rf packages

# 修改golang源码以编译xray1.8.8+版本
rm -rf feeds/packages/lang/golang
rm -rf feeds/packages2/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 25.x feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 25.x feeds/packages2/lang/golang
sed -i '/-linkmode external \\/d' feeds/packages/lang/golang/golang-package.mk
sed -i '/-linkmode external \\/d' feeds/packages2/lang/golang/golang-package.mk

# 清理旧的 host golang 与缓存
make package/feeds/packages/golang/host/clean V=sc || true
make package/golang/host/clean V=sc || true
rm -rf build_dir/hostpkg/*golang* staging_dir/hostpkg/*go* dl/go*.tar.gz
# 先单独把 golang/host 编好（会用 25.x）
make package/feeds/packages/golang/host/compile V=sc

rm -rf feeds/packages2/multimedia/aliyundrive-webdav
rm -rf feeds/luci2/applications/luci-app-aliyundrive-webdav
git clone https://github.com/messense/aliyundrive-webdav.git
cp -r aliyundrive-webdav/openwrt/aliyundrive-webdav feeds/packages2/multimedia
cp -r aliyundrive-webdav/openwrt/luci-app-aliyundrive-webdav feeds/luci2/applications
rm -rf aliyundrive-webdav

# 拉取最后能编译的shadowsocks-rust
wget https://codeload.github.com/fw876/helloworld/zip/28504024db649b7542347771704abc33c3b1ddc8 -O helloworld.zip
unzip helloworld.zip
rm -rf feeds/helloworld/shadowsocks-rust
cp -r helloworld-28504024db649b7542347771704abc33c3b1ddc8/shadowsocks-rust feeds/helloworld
rm -rf feeds/PWpackages/shadowsocks-rust
cp -r helloworld-28504024db649b7542347771704abc33c3b1ddc8/shadowsocks-rust feeds/PWpackages
rm -rf helloworld.zip helloworld-28504024db649b7542347771704abc33c3b1ddc8

# 拉取最后能编译的shadowsocksr-libev
wget https://codeload.github.com/fw876/helloworld/zip/ea2a48dd6a30450ab84079a0c0a943cab86e29dc -O helloworld.zip
unzip helloworld.zip
rm -rf feeds/helloworld/shadowsocksr-libev
cp -r helloworld-ea2a48dd6a30450ab84079a0c0a943cab86e29dc/shadowsocksr-libev feeds/helloworld
sed -i '/DEPENDS:=+libev +libsodium +libopenssl +libpthread +libpcre +libudns +zlib +libopenssl-legacy/s/ +libopenssl-legacy//' feeds/helloworld/shadowsocksr-libev/Makefile
rm -rf feeds/PWpackages/shadowsocksr-libev
cp -r feeds/helloworld/shadowsocksr-libev feeds/PWpackages
rm -rf helloworld.zip helloworld-ea2a48dd6a30450ab84079a0c0a943cab86e29dc

# 拉取最后能编译的dns2tcp
rm -rf feeds/helloworld/dns2tcp
rm -rf feeds/PWpackages/dns2tcp
git clone https://github.com/sbwml/openwrt_helloworld
cp -r openwrt_helloworld/dns2tcp feeds/helloworld
cp -r openwrt_helloworld/dns2tcp feeds/PWpackages
rm -rf openwrt_helloworld

git clone https://github.com/coolsnowwolf/lede.git
cp -r lede/tools/ninja tools
cp -r lede/package/lean/adbyby package
rm -rf lede

git clone https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome

rm -rf package/libs/openssl
rm -rf package/libs/ustream-ssl
#wget 'https://github.com/201821143044/Actions-GL.iNet-OpenWrt/raw/main/myfiles/openssl.zip' --no-check-certificate && unzip -o openssl.zip && rm -f openssl.zip
wget 'https://github.com/wekingchen/Actions-SFT1200/raw/main/libs.zip' --no-check-certificate && unzip -o libs.zip && rm -f libs.zip
wget https://github.com/wekingchen/Actions-SFT1200/raw/main/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe -P dl/

# 修复 host ncurses 静态库 relocation 错误
sed -i '/^PKG_BUILD_DEPENDS:=ncurses\/host/a HOST_CFLAGS += -fPIC' package/libs/ncurses/Makefile

# 清理老的 hostpkg ncurses
rm -rf build_dir/hostpkg/ncurses*
rm -rf staging_dir/hostpkg/lib/libncurses*

# 强制只用动态库
find staging_dir/hostpkg/lib/ -name "libncurses.a" -delete
find staging_dir/hostpkg/lib/ -name "libpanel.a" -delete

export LD_LIBRARY_PATH="staging_dir/hostpkg/lib:$LD_LIBRARY_PATH"
