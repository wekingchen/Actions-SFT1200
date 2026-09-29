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
# 翻墙组件尽量保持更新：使用 helloworld 当前 shadowsocks-libev，
# 覆盖 18.06 packages 中的旧 3.1.3，同时保留 ss-local/ss-redir/config 完整包接口。
rm -rf feeds/packages/net/shadowsocks-libev
cp -a feeds/helloworld/shadowsocks-libev feeds/packages/net/
cp -r feeds/packages2/lang/rust feeds/packages/lang
cp -r feeds/PWpackages/xray-core feeds/packages2/net
cp -r feeds/PWpackages/v2ray-geodata feeds/packages2/net
cp -r feeds/PWpackages/sing-box feeds/packages2/net
cp -r feeds/PWpackages/chinadns-ng feeds/packages2/net
cp -r feeds/PWpackages/dns2socks feeds/packages2/net
cp -r feeds/helloworld/dns2tcp feeds/packages2/net
cp -r feeds/PWpackages/microsocks feeds/packages2/net

# OpenWrt 18.06 的 Build/Configure/Default 只在 configure 具有可执行权限时才会执行。
# 当前 Passwall shadowsocksr-libev/src/configure 在 Git 中是 100644，导致 configure 被静默跳过，
# 最终构建目录没有生成 Makefile。先补执行权限，让后续 autoreconf/configure 正常落地。
chmod +x feeds/PWpackages/shadowsocksr-libev/src/configure

# luci-app-passwall 回退到最后能编译的版本
rm -rf feeds/luci2/applications/luci-app-passwall
rm -rf feeds/PWluci/luci-app-passwall
wget https://github.com/Openwrt-Passwall/openwrt-passwall/archive/af831669039648788499961dd088cfad53eca1ae.zip -O openwrt-passwall.zip
unzip openwrt-passwall.zip
cp -r openwrt-passwall-af831669039648788499961dd088cfad53eca1ae/luci-app-passwall feeds/luci2/applications/
cp -r openwrt-passwall-af831669039648788499961dd088cfad53eca1ae/luci-app-passwall feeds/PWluci/
rm -rf openwrt-passwall.zip openwrt-passwall-af831669039648788499961dd088cfad53eca1ae

# OpenWrt 18.06 的 LuCI 本身就是 Lua 运行时，不需要现代 luci-compat/luci-lua-runtime。
# Passwall 在老 LuCI 上不需要 luci-compat，去掉显式依赖。
for pw in \
  feeds/luci2/applications/luci-app-passwall/Makefile \
  feeds/PWluci/luci-app-passwall/Makefile; do
  sed -i 's/+luci-compat//g' "$pw"
done

# 新版 luci2/luci.mk 会给所有 luasrc 包自动追加 luci-lua-runtime。
# 这会让 luci-lib-ipkg 等旧 Lua 包被迫依赖 ucode；18.06 应继续使用原生 Lua LuCI。
python3 - <<'PY'
from pathlib import Path

p = Path("feeds/luci2/luci.mk")
s = p.read_text()
block = """ifneq ($(wildcard ${CURDIR}/luasrc/*),)
 ifneq ($(filter-out luci-lib-base luci-lua-runtime,$(PKG_NAME)),)
  LUCI_DEPENDS += +luci-lua-runtime
 endif
endif

"""
if block in s:
    s = s.replace(block, "", 1)
else:
    print("luci2/luci.mk runtime auto-dependency block already absent")
p.write_text(s)
PY

for sym in luci-compat luci-lua-runtime luci-lib-base ucode-mod-lua; do
  sed -i "/^CONFIG_PACKAGE_${sym}=y$/d; /^# CONFIG_PACKAGE_${sym} is not set$/d" .config
  echo "# CONFIG_PACKAGE_${sym} is not set" >> .config
done

# packages2 的现代 miniupnpd-iptables/nftables 与 18.06 的传统 miniupnpd 冲突。
rm -rf feeds/packages2/net/miniupnpd-iptables feeds/packages2/net/miniupnpd-nftables
rm -rf package/feeds/packages2/miniupnpd-iptables package/feeds/packages2/miniupnpd-nftables

# 用 OpenWrt 18.06 官方 miniupnpd 做稳定兜底，保留 UPnP/NAT-PMP/PCP 功能。
MINIUPNPD_1806_COMMIT=0171d18e051a0afdc5bc52b9e7913518b2e2a2a0
rm -rf /tmp/packages-18.06.tar.gz "/tmp/packages-${MINIUPNPD_1806_COMMIT}"
wget -q "https://github.com/openwrt/packages/archive/${MINIUPNPD_1806_COMMIT}.tar.gz" -O /tmp/packages-18.06.tar.gz
tar -xzf /tmp/packages-18.06.tar.gz -C /tmp
rm -rf feeds/gl_feed_common/miniupnpd
cp -a "/tmp/packages-${MINIUPNPD_1806_COMMIT}/net/miniupnpd" feeds/gl_feed_common/
rm -rf /tmp/packages-18.06.tar.gz "/tmp/packages-${MINIUPNPD_1806_COMMIT}"

# naiveproxy: GL-SFT1200 的 ARCH_PACKAGES=mips_siflower，上游没有这个预编译名。
# 映射到 klzgrad release 中实际存在的 mipsel_24kc-static 资产。
sed -i '/else ifeq (\$(ARCH_PREBUILT),mips_siflower)/,+1 d' \
feeds/PWpackages/naiveproxy/Makefile
sed -i '/^[[:space:]]*ARCH_PREBUILT:=riscv64[[:space:]]*$/a\
else ifeq ($(ARCH_PREBUILT),mips_siflower)\
  ARCH_PREBUILT:=mipsel_24kc-static' \
feeds/PWpackages/naiveproxy/Makefile

# OpenWrt 18.06 的 download.pl 不接受 PKG_HASH:=dummy。
# 必须在 BuildPackage 展开前，把 mipsel_24kc-static 的 SHA256 插入上游 hash 条件树。
python3 - <<'PY'
from pathlib import Path

p = Path("feeds/PWpackages/naiveproxy/Makefile")
s = p.read_text()
sha256 = "6a6a5294cf5063dbb89192c909dcd4068dd7a4309b3a7dcb0e187442cb2fc291"
needle = "else\n  PKG_HASH:=dummy\nendif"
replacement = (
    "else ifeq ($(ARCH_PREBUILT),mipsel_24kc-static)\n"
    f"  PKG_HASH:={sha256}\n"
    "else\n"
    "  PKG_HASH:=dummy\n"
    "endif"
)

if "ifeq ($(ARCH_PREBUILT),mipsel_24kc-static)\n  PKG_HASH:=" not in s:
    if needle not in s:
        raise SystemExit("naiveproxy hash fallback block not found")
    s = s.replace(needle, replacement, 1)

p.write_text(s)
PY

# 解包统一使用 $(PKG_SOURCE)，避免文件名逻辑漂移。
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

# haproxy去掉QUIC支持
sed -i 's/^[[:space:]]*ADDON+=USE_QUIC=1/# &/' feeds/gl_feed_1806/haproxy/Makefile

# 修改golang源码以编译xray26.9.9+版本
rm -rf feeds/gl_feed_common/golang
git clone https://github.com/sbwml/packages_lang_golang -b 27.x feeds/gl_feed_common/golang
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

# diy-part2 修改了 feed 包内容和依赖关系，必须重新刷新 feed 链接与 Kconfig。
# 否则 .config 会保持旧依赖图，出现源码已在但 IPK 未被纳入构建的情况。
./scripts/feeds install -f -p packages shadowsocks-libev
./scripts/feeds install -f -p gl_feed_common miniupnpd

for sym in shadowsocks-libev-config miniupnpd; do
  sed -i "/^CONFIG_PACKAGE_${sym}=y$/d; /^# CONFIG_PACKAGE_${sym} is not set$/d" .config
  echo "CONFIG_PACKAGE_${sym}=y" >> .config
done

make defconfig

echo "=== SFT1200 dependency sync check ==="
grep -E '^CONFIG_PACKAGE_(shadowsocks-libev-config|shadowsocks-libev-ss-local|shadowsocks-libev-ss-redir|miniupnpd)=y$' .config || true
echo "===================================="

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
