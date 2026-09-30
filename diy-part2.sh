#!/usr/bin/env bash
#
# SFT1200 / Siflower OpenWrt 18.06 compatibility layer
# Runs after feeds have been updated and installed.
#
# Maintenance policy:
#   1. Keep proxy/bypass components reasonably current.
#   2. Keep the OpenWrt 18.06 base conservative and buildable.
#   3. Preserve existing features; prefer compatibility shims over removal.
#

set -Eeuo pipefail
IFS=$'\n\t'

readonly PASSWALL_COMMIT="af831669039648788499961dd088cfad53eca1ae"
readonly MINIUPNPD_1806_COMMIT="0171d18e051a0afdc5bc52b9e7913518b2e2a2a0"
readonly GOLANG_BRANCH="27.x"
readonly NAIVEPROXY_ARCH="mipsel_24kc-static"

section() {
  printf '\n========== %s ==========\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

replace_dir() {
  local src="$1"
  local dst="$2"

  [ -d "$src" ] || die "Source directory not found: $src"
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
}

download_cached() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.part"

  mkdir -p "$(dirname "$dest")"

  if [ -s "$dest" ]; then
    echo "Reuse cached: $dest"
    return 0
  fi

  rm -f "$tmp"
  curl -fL --retry 4 --retry-delay 2 --connect-timeout 20 "$url" -o "$tmp"
  mv "$tmp" "$dest"
}

config_enable() {
  local symbol="$1"

  sed -i \
    -e "/^CONFIG_${symbol}=[ym]$/d" \
    -e "/^# CONFIG_${symbol} is not set$/d" \
    .config
  echo "CONFIG_${symbol}=y" >> .config
}

config_disable() {
  local symbol="$1"

  sed -i \
    -e "/^CONFIG_${symbol}=[ym]$/d" \
    -e "/^# CONFIG_${symbol} is not set$/d" \
    .config
  echo "# CONFIG_${symbol} is not set" >> .config
}

configure_naiveproxy() {
  local makefile="feeds/PWpackages/naiveproxy/Makefile"
  local version release tag asset url archive sha256

  [ -f "$makefile" ] || die "NaiveProxy Makefile not found: $makefile"

  version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile" | head -n1 | tr -d '[:space:]')"
  release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile" | head -n1 | tr -d '[:space:]')"

  [ -n "$version" ] || die "Unable to read NaiveProxy PKG_VERSION"
  [ -n "$release" ] || die "Unable to read NaiveProxy PKG_RELEASE"

  tag="v${version}-${release}"
  asset="naiveproxy-${tag}-openwrt-${NAIVEPROXY_ARCH}.tar.xz"
  url="https://github.com/klzgrad/naiveproxy/releases/download/${tag}/${asset}"
  archive="dl/${asset}"

  echo "NaiveProxy: version=${version}, release=${release}, arch=${NAIVEPROXY_ARCH}"
  download_cached "$url" "$archive"

  # Reject HTML/error pages or corrupted cache entries before calculating the hash.
  if ! tar -tJf "$archive" >/dev/null 2>&1; then
    rm -f "$archive"
    die "Invalid NaiveProxy release archive: $asset"
  fi

  sha256="$(sha256sum "$archive" | awk '{print $1}')"
  echo "NaiveProxy SHA256: $sha256"

  python3 - "$makefile" "$NAIVEPROXY_ARCH" "$sha256" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
arch = sys.argv[2]
sha256 = sys.argv[3]
text = path.read_text()

# Map the Siflower package architecture to the static MIPS asset published by
# NaiveProxy. Work on the architecture mapping block only.
arch_start = text.find("ARCH_PREBUILT:=$(ARCH_PACKAGES)")
arch_end = text.find("\nendif\n\nPKG_SOURCE:=", arch_start)
if arch_start < 0 or arch_end < 0:
    raise SystemExit("NaiveProxy architecture mapping block not found")

arch_block = text[arch_start:arch_end + len("\nendif")]
arch_block = re.sub(
    r"\nelse ifeq \(\$\(ARCH_PREBUILT\),mips_siflower\)\n\s*ARCH_PREBUILT:=[^\n]+",
    "",
    arch_block,
)

if "mips_siflower" not in arch_block:
    if not arch_block.endswith("\nendif"):
        raise SystemExit("Unexpected NaiveProxy architecture block ending")
    arch_block = (
        arch_block[:-len("\nendif")]
        + f"\nelse ifeq ($(ARCH_PREBUILT),mips_siflower)\n  ARCH_PREBUILT:={arch}\nendif"
    )

text = text[:arch_start] + arch_block + text[arch_end + len("\nendif"):]

# OpenWrt 18.06 download.pl does not accept PKG_HASH:=dummy. Inject or refresh
# the hash for the static Siflower-compatible asset before BuildPackage expands.
hash_start = text.find("ifeq ($(ARCH_PREBUILT),", text.find("PKG_SOURCE_URL:="))
hash_end = text.find("\nendif\n\nPKG_LICENSE", hash_start)
if hash_start < 0 or hash_end < 0:
    raise SystemExit("NaiveProxy hash block not found")

hash_block = text[hash_start:hash_end + len("\nendif")]
branch_re = re.compile(
    rf"(else ifeq \(\$\(ARCH_PREBUILT\),{re.escape(arch)}\)\n\s*PKG_HASH:=)[0-9a-fA-F]+"
)

if branch_re.search(hash_block):
    hash_block = branch_re.sub(rf"\g<1>{sha256}", hash_block, count=1)
else:
    fallback = "else\n  PKG_HASH:=dummy\nendif"
    if fallback not in hash_block:
        raise SystemExit("NaiveProxy fallback hash block not found")
    hash_block = hash_block.replace(
        fallback,
        (
            f"else ifeq ($(ARCH_PREBUILT),{arch})\n"
            f"  PKG_HASH:={sha256}\n"
            "else\n"
            "  PKG_HASH:=dummy\n"
            "endif"
        ),
        1,
    )

text = text[:hash_start] + hash_block + text[hash_end + len("\nendif"):]

# Keep extraction tied to PKG_SOURCE so future filename changes stay consistent.
text = text.replace(
    "$(DL_DIR)/naiveproxy-v$(PKG_VERSION)-$(PKG_RELEASE)-openwrt-$(ARCH_PREBUILT).tar.xz",
    "$(DL_DIR)/$(PKG_SOURCE)",
)

path.write_text(text)
PY
}


section "Proxy packages"

# Prefer current proxy engines from Passwall/helloworld over stale copies in the
# generic packages feed.
for pkg in xray-core v2ray-geodata sing-box chinadns-ng dns2socks dns2tcp microsocks; do
  rm -rf "feeds/packages2/net/${pkg}"
done

replace_dir feeds/PWpackages/xray-core       feeds/packages2/net/xray-core
replace_dir feeds/PWpackages/v2ray-geodata   feeds/packages2/net/v2ray-geodata
replace_dir feeds/PWpackages/sing-box         feeds/packages2/net/sing-box
replace_dir feeds/PWpackages/chinadns-ng      feeds/packages2/net/chinadns-ng
replace_dir feeds/PWpackages/dns2socks        feeds/packages2/net/dns2socks
replace_dir feeds/helloworld/dns2tcp          feeds/packages2/net/dns2tcp
replace_dir feeds/PWpackages/microsocks       feeds/packages2/net/microsocks

# Keep the newer Shadowsocks package interface required by SSR Plus
# (ss-local/ss-redir plus shadowsocks-libev-config).
replace_dir feeds/helloworld/shadowsocks-libev feeds/packages/net/shadowsocks-libev

# Keep Rust current enough for modern proxy packages.
replace_dir feeds/packages2/lang/rust feeds/packages/lang/rust

# OpenWrt 18.06 only runs Build/Configure/Default when ./configure is executable.
chmod +x feeds/PWpackages/shadowsocksr-libev/src/configure

configure_naiveproxy


section "Passwall and LuCI 18.06 compatibility"

# Passwall UI/controller is pinned to the last revision verified on this 18.06
# tree; proxy engines above continue to track current feeds.
passwall_zip="dl/openwrt-passwall-${PASSWALL_COMMIT}.zip"
passwall_tmp="$(mktemp -d)"
download_cached \
  "https://github.com/Openwrt-Passwall/openwrt-passwall/archive/${PASSWALL_COMMIT}.zip" \
  "$passwall_zip"
unzip -q "$passwall_zip" -d "$passwall_tmp"

passwall_src="${passwall_tmp}/openwrt-passwall-${PASSWALL_COMMIT}/luci-app-passwall"
replace_dir "$passwall_src" feeds/luci2/applications/luci-app-passwall
replace_dir "$passwall_src" feeds/PWluci/luci-app-passwall
rm -rf "$passwall_tmp"

# OpenWrt 18.06 is already a Lua-based LuCI tree. Modern compatibility bridge
# packages (luci-compat/luci-lua-runtime/ucode) create invalid dependencies here.
for pw in \
  feeds/luci2/applications/luci-app-passwall/Makefile \
  feeds/PWluci/luci-app-passwall/Makefile; do
  sed -i 's/+luci-compat//g' "$pw"
done

find feeds/luci2 -type f -name Makefile -print0 | xargs -0 -r sed -i \
  -e 's/+luci-compat//g' \
  -e 's/+luci-lua-runtime//g' \
  -e 's/+luci-lib-base//g' \
  -e 's/+ucode-mod-lua//g'

python3 - <<'PY'
from pathlib import Path

path = Path("feeds/luci2/luci.mk")
text = path.read_text()
block = """ifneq ($(wildcard ${CURDIR}/luasrc/*),)
 ifneq ($(filter-out luci-lib-base luci-lua-runtime,$(PKG_NAME)),)
  LUCI_DEPENDS += +luci-lua-runtime
 endif
endif

"""
if block in text:
    text = text.replace(block, "", 1)
path.write_text(text)
PY

rm -rf \
  feeds/luci2/modules/luci-compat \
  feeds/luci2/modules/luci-lua-runtime \
  feeds/luci2/libs/luci-lib-base \
  feeds/luci2/contrib/package/ucode-mod-lua \
  package/feeds/luci2/luci-compat \
  package/feeds/luci2/luci-lua-runtime \
  package/feeds/luci2/luci-lib-base \
  package/feeds/luci2/ucode-mod-lua

for symbol in \
  PACKAGE_luci-compat \
  PACKAGE_luci-lua-runtime \
  PACKAGE_luci-lib-base \
  PACKAGE_ucode-mod-lua; do
  config_disable "$symbol"
done


section "Stable OpenWrt 18.06 compatibility packages"

# Modern miniupnpd-iptables/nftables variants conflict with the old Kconfig.
rm -rf \
  feeds/packages2/net/miniupnpd-iptables \
  feeds/packages2/net/miniupnpd-nftables \
  package/feeds/packages2/miniupnpd-iptables \
  package/feeds/packages2/miniupnpd-nftables

# Keep the official OpenWrt 18.06 implementation and install it directly under
# package/ so feed index regeneration is not required.
miniupnpd_archive="dl/openwrt-packages-${MINIUPNPD_1806_COMMIT}.tar.gz"
miniupnpd_tmp="$(mktemp -d)"
download_cached \
  "https://github.com/openwrt/packages/archive/${MINIUPNPD_1806_COMMIT}.tar.gz" \
  "$miniupnpd_archive"
tar -xzf "$miniupnpd_archive" -C "$miniupnpd_tmp"

rm -rf \
  feeds/gl_feed_common/miniupnpd \
  package/feeds/gl_feed_common/miniupnpd \
  package/miniupnpd
replace_dir \
  "${miniupnpd_tmp}/packages-${MINIUPNPD_1806_COMMIT}/net/miniupnpd" \
  package/miniupnpd
rm -rf "$miniupnpd_tmp"


section "Selected package refreshes"

replace_dir feeds/packages2/devel/diffutils feeds/packages/devel/diffutils
replace_dir feeds/packages2/utils/jq        feeds/packages/utils/jq
replace_dir feeds/packages2/net/zerotier    feeds/gl_feed_common/zerotier
replace_dir feeds/packages2/net/haproxy     feeds/gl_feed_1806/haproxy

# HAProxy: use Lua 5.4 and disable QUIC on this old base.
sed -i -E \
  -e 's/\+liblua5\.3/\+liblua5\.4/g' \
  -e 's/LUA_LIB_NAME="?lua5\.3"?/LUA_LIB_NAME="lua5.4"/g' \
  -e 's|/include/lua5\.3|/include/lua5.4|g' \
  feeds/gl_feed_1806/haproxy/Makefile
sed -i 's/^[[:space:]]*ADDON+=USE_QUIC=1/# &/' feeds/gl_feed_1806/haproxy/Makefile

# Modern Go toolchain required by current Xray.
rm -rf feeds/gl_feed_common/golang
git clone --depth=1 --branch "$GOLANG_BRANCH" \
  https://github.com/sbwml/packages_lang_golang \
  feeds/gl_feed_common/golang
sed -i '/-linkmode external \\/d' feeds/gl_feed_common/golang/golang-package.mk


section "Additional applications and build tools"

aliyun_tmp="$(mktemp -d)"
git clone --depth=1 https://github.com/messense/aliyundrive-webdav.git "$aliyun_tmp"
replace_dir "$aliyun_tmp/openwrt/aliyundrive-webdav" feeds/packages2/multimedia/aliyundrive-webdav
replace_dir "$aliyun_tmp/openwrt/luci-app-aliyundrive-webdav" feeds/luci2/applications/luci-app-aliyundrive-webdav
rm -rf "$aliyun_tmp"

# We only need two directories from LEDE; sparse checkout avoids cloning the
# entire repository history and working tree.
lede_tmp="$(mktemp -d)"
git clone --depth=1 --filter=blob:none --sparse https://github.com/coolsnowwolf/lede.git "$lede_tmp"
git -C "$lede_tmp" sparse-checkout set tools/ninja package/lean/adbyby
replace_dir "$lede_tmp/tools/ninja" tools/ninja
replace_dir "$lede_tmp/package/lean/adbyby" package/adbyby
rm -rf "$lede_tmp"

rm -rf package/luci-app-adguardhome
git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome


section "Board files and local compatibility libraries"

rm -rf package/libs/openssl package/libs/ustream-ssl
libs_tmp="$(mktemp)"
curl -fL --retry 4 --retry-delay 2 \
  "https://github.com/wekingchen/Actions-SFT1200/raw/main/libs.zip" \
  -o "$libs_tmp"
unzip -oq "$libs_tmp"
rm -f "$libs_tmp"

download_cached \
  "https://github.com/wekingchen/Actions-SFT1200/raw/main/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe" \
  "dl/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe"


section "OpenWrt 18.06 CMake + ccache compatibility"

# OpenWrt 18.06 passes ccache itself as CMAKE_C_COMPILER and relies on
# CMAKE_*_COMPILER_ARG1 for the real cross compiler. With the newer CMake
# available on the current build host this breaks compiler checks (ccache sees
# flags such as -pipe as its own arguments). Use CMake's compiler launcher
# support instead: keep the real compiler in CMAKE_*_COMPILER and place ccache
# in front of it with CMAKE_*_COMPILER_LAUNCHER.
python3 - <<'PY'
from pathlib import Path

path = Path("include/cmake.mk")
text = path.read_text()

old = """ifeq ($(CONFIG_CCACHE),)
 CMAKE_C_COMPILER:=$(call cmake_tool,$(TARGET_CC))
 CMAKE_CXX_COMPILER:=$(call cmake_tool,$(TARGET_CXX))
 CMAKE_C_COMPILER_ARG1:=
 CMAKE_CXX_COMPILER_ARG1:=
else
  CCACHE:=$(STAGING_DIR_HOST)/bin/ccache
  CMAKE_C_COMPILER:=$(CCACHE)
  CMAKE_C_COMPILER_ARG1:=$(TARGET_CC_NOCACHE)
  CMAKE_CXX_COMPILER:=$(CCACHE)
  CMAKE_CXX_COMPILER_ARG1:=$(TARGET_CXX_NOCACHE)
endif
"""

new = """ifeq ($(CONFIG_CCACHE),)
 CMAKE_C_COMPILER:=$(call cmake_tool,$(TARGET_CC))
 CMAKE_CXX_COMPILER:=$(call cmake_tool,$(TARGET_CXX))
 CMAKE_C_COMPILER_ARG1:=
 CMAKE_CXX_COMPILER_ARG1:=
 CMAKE_C_COMPILER_LAUNCHER:=
 CMAKE_CXX_COMPILER_LAUNCHER:=
else
  CCACHE:=$(STAGING_DIR_HOST)/bin/ccache
  CMAKE_C_COMPILER:=$(call cmake_tool,$(TARGET_CC_NOCACHE))
  CMAKE_CXX_COMPILER:=$(call cmake_tool,$(TARGET_CXX_NOCACHE))
  CMAKE_C_COMPILER_ARG1:=
  CMAKE_CXX_COMPILER_ARG1:=
  CMAKE_C_COMPILER_LAUNCHER:=$(CCACHE)
  CMAKE_CXX_COMPILER_LAUNCHER:=$(CCACHE)
endif
"""

if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("include/cmake.mk ccache compiler block not found")

old_args = """			-DCMAKE_CXX_COMPILER_ARG1="$(CMAKE_CXX_COMPILER_ARG1)" \
			-DCMAKE_ASM_COMPILER="$(CMAKE_C_COMPILER)" \
			-DCMAKE_ASM_COMPILER_ARG1="$(CMAKE_C_COMPILER_ARG1)" \
"""

new_args = """			-DCMAKE_CXX_COMPILER_ARG1="$(CMAKE_CXX_COMPILER_ARG1)" \
			-DCMAKE_C_COMPILER_LAUNCHER="$(CMAKE_C_COMPILER_LAUNCHER)" \
			-DCMAKE_CXX_COMPILER_LAUNCHER="$(CMAKE_CXX_COMPILER_LAUNCHER)" \
			-DCMAKE_ASM_COMPILER="$(CMAKE_C_COMPILER)" \
			-DCMAKE_ASM_COMPILER_ARG1="$(CMAKE_C_COMPILER_ARG1)" \
			-DCMAKE_ASM_COMPILER_LAUNCHER="$(CMAKE_C_COMPILER_LAUNCHER)" \
"""

if old_args in text:
    text = text.replace(old_args, new_args, 1)
elif "CMAKE_C_COMPILER_LAUNCHER" not in text[text.find("define Build/Configure/Default"):]:
    raise SystemExit("include/cmake.mk CMake argument block not found")

path.write_text(text)
PY


section "Synchronize configuration"

# Reinstall the replaced package link and refresh package metadata after all
# feed/package overrides.
./scripts/feeds install -f -p packages shadowsocks-libev

config_enable PACKAGE_shadowsocks-libev-config
config_enable PACKAGE_miniupnpd

# OpenWrt 18.06 has native ccache integration. Cache directories are persisted
# by the GitHub Actions workflow.
config_enable CCACHE

rm -f tmp/.packageinfo tmp/.packagedeps tmp/.config-package.in
make defconfig

required_symbols=(
  PACKAGE_shadowsocks-libev-config
  PACKAGE_shadowsocks-libev-ss-local
  PACKAGE_shadowsocks-libev-ss-redir
  PACKAGE_miniupnpd
  CCACHE
)

for symbol in "${required_symbols[@]}"; do
  grep -q "^CONFIG_${symbol}=y$" .config ||
    die "Required config was not retained by defconfig: CONFIG_${symbol}=y"
done

if grep -Rqs '+luci-compat' \
  feeds/PWluci/luci-app-passwall/Makefile \
  feeds/luci2/applications/luci-app-passwall/Makefile; then
  die "Passwall still depends on luci-compat"
fi

for symbol in \
  PACKAGE_luci-compat \
  PACKAGE_luci-lua-runtime \
  PACKAGE_luci-lib-base \
  PACKAGE_ucode-mod-lua; do
  if grep -Eq "^CONFIG_${symbol}=[ym]$" .config; then
    die "Incompatible modern LuCI package was re-selected: CONFIG_${symbol}"
  fi
done

echo "Configuration checks passed; ccache enabled."


section "Host ncurses workaround"

if ! grep -q '^HOST_CFLAGS += -fPIC$' package/libs/ncurses/Makefile; then
  sed -i '/^PKG_BUILD_DEPENDS:=ncurses\/host/a HOST_CFLAGS += -fPIC' \
    package/libs/ncurses/Makefile
fi

make package/ncurses/host/clean || true

if [ -d staging_dir/hostpkg/lib ]; then
  find staging_dir/hostpkg/lib -type f -name 'libncurses.a' -delete || true
  find staging_dir/hostpkg/lib -type f -name 'libpanel.a' -delete || true
fi

hostpkg_lib="$PWD/staging_dir/hostpkg/lib"
export LD_LIBRARY_PATH="${hostpkg_lib}:${LD_LIBRARY_PATH:-}"

# Persist the intended runtime library path into later GitHub Actions steps.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >> "$GITHUB_ENV"
fi

section "diy-part2 complete"
