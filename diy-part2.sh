#!/usr/bin/env bash
#
# SFT1200 / Siflower OpenWrt 18.06 兼容处理脚本
# 在 feeds update / install 完成后执行。
#
# 维护原则：
#   1. 代理、分流相关组件尽量跟随上游更新。
#   2. OpenWrt 18.06 系统底座以稳定、可编译为第一优先级。
#   3. 不为了编译通过而删功能，优先通过兼容补丁解决新旧依赖差异。
#

set -Eeuo pipefail
IFS=$'\n\t'

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

  # 计算 HASH 前先确认下载内容确实是可解压的 xz 包，避免把错误页写成 HASH。
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

# 将 Siflower 的自定义架构映射到 NaiveProxy 官方发布的 MIPS 静态包。
# 这里只修改架构映射区块，避免影响其他架构。
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

# OpenWrt 18.06 的 download.pl 不接受 PKG_HASH:=dummy。
# 在 BuildPackage 展开前，自动写入当前 Siflower 静态包的真实 SHA256。
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

# 解压文件统一使用 PKG_SOURCE，后续上游调整文件名时不需要再额外同步这里。
text = text.replace(
    "$(DL_DIR)/naiveproxy-v$(PKG_VERSION)-$(PKG_RELEASE)-openwrt-$(ARCH_PREBUILT).tar.xz",
    "$(DL_DIR)/$(PKG_SOURCE)",
)

path.write_text(text)
PY
}


section "Proxy packages"

# 代理核心优先使用 Passwall / helloworld 当前版本，覆盖 packages2 中可能较旧的副本。
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

# SSR Plus 需要新版 Shadowsocks 的完整包接口：
# ss-local / ss-redir / shadowsocks-libev-config。
replace_dir feeds/helloworld/shadowsocks-libev feeds/packages/net/shadowsocks-libev

# 保持较新的 Rust 工具链，以满足现代代理组件的编译要求。
replace_dir feeds/packages2/lang/rust feeds/packages/lang/rust

# Passwall 26.9.x 开始新增 lyaml 硬依赖，而原始 OpenWrt 18.06 packages 没有该包。
# 从 packages2 引入 lyaml，同时去掉只服务现代 macOS Host 的 fakeuname 依赖，
# 保留 Linux GitHub Runner 真正需要的 lua/host + luarocks/host 构建链。
replace_dir feeds/packages2/lang/lyaml feeds/packages/lang/lyaml
python3 - <<'PY'
from pathlib import Path

path = Path("feeds/packages/lang/lyaml/Makefile")
text = path.read_text()

text = text.replace(
    "PKG_BUILD_DEPENDS:=lua/host luarocks/host HOST_OS_MACOS:fakeuname/host",
    "PKG_BUILD_DEPENDS:=lua/host luarocks/host",
)

start = text.find("ifeq ($(CONFIG_HOST_OS_MACOS),y)")
if start >= 0:
    end = text.find("endif\n", start)
    if end < 0:
        raise SystemExit("lyaml macOS compatibility block ending not found")
    text = text[:start] + text[end + len("endif\n"):]

text = text.replace(
    '\t$(if $(CONFIG_HOST_OS_MACOS),PATH=$(FAKEUNAME_PATH):$(TARGET_PATH_PKG)) \\\n',
    "",
)

path.write_text(text)
PY

# OpenWrt 18.06 只有在 ./configure 可执行时才会真正运行 Build/Configure/Default。
chmod +x feeds/PWpackages/shadowsocksr-libev/src/configure

configure_naiveproxy


section "Passwall 与 LuCI 18.06 兼容"

# Passwall UI 直接跟随 PWluci/main 当前版本。
# 同时复制一份到 luci2，保持现有 LuCI 包布局和历史配置兼容。
replace_dir feeds/PWluci/luci-app-passwall feeds/luci2/applications/luci-app-passwall

# OpenWrt 18.06 本身就是 Lua LuCI。
# 新版 luci-compat / luci-lua-runtime / ucode 兼容桥会反向拉入 18.06 不具备的依赖，
# 因此这里只去掉“现代 LuCI 兼容旧 Lua”的桥接层，不删除 Passwall 实际功能。
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

# 新版 luci.mk 会给含 luasrc 的包自动追加 luci-lua-runtime。
# 18.06 应继续使用自身原生 Lua LuCI，所以删除这一段自动依赖。
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


section "OpenWrt 18.06 稳定兼容包"

# packages2 中现代 miniupnpd-iptables / nftables 变种会和 18.06 的旧 Kconfig 冲突。
rm -rf \
  feeds/packages2/net/miniupnpd-iptables \
  feeds/packages2/net/miniupnpd-nftables \
  package/feeds/packages2/miniupnpd-iptables \
  package/feeds/packages2/miniupnpd-nftables

# miniupnpd 固定使用 OpenWrt 18.06 官方实现，并直接放到 package/ 下，
# 避免修改 feed 后还需要重新生成 feed 索引。
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


section "指定软件包更新"

replace_dir feeds/packages2/devel/diffutils feeds/packages/devel/diffutils
replace_dir feeds/packages2/utils/jq        feeds/packages/utils/jq
replace_dir feeds/packages2/net/zerotier    feeds/gl_feed_common/zerotier
replace_dir feeds/packages2/net/haproxy     feeds/gl_feed_1806/haproxy

# HAProxy 使用 Lua 5.4；QUIC 与当前 18.06 底座不兼容，因此关闭。
sed -i -E \
  -e 's/\+liblua5\.3/\+liblua5\.4/g' \
  -e 's/LUA_LIB_NAME="?lua5\.3"?/LUA_LIB_NAME="lua5.4"/g' \
  -e 's|/include/lua5\.3|/include/lua5.4|g' \
  feeds/gl_feed_1806/haproxy/Makefile
sed -i 's/^[[:space:]]*ADDON+=USE_QUIC=1/# &/' feeds/gl_feed_1806/haproxy/Makefile

# 当前 Xray 等现代代理核心需要较新的 Go 工具链。
rm -rf feeds/gl_feed_common/golang
git clone --depth=1 --branch "$GOLANG_BRANCH" \
  https://github.com/sbwml/packages_lang_golang \
  feeds/gl_feed_common/golang
sed -i '/-linkmode external \\/d' feeds/gl_feed_common/golang/golang-package.mk

# Go 默认把 GOCACHE 放在 tmp/go-build，工作流结束后会丢失。
# 改到仓库内固定目录，交给 Actions Cache 跨构建复用。
sed -i 's|$(TMP_DIR)/go-build|$(TOPDIR)/.cache/go-build|g' \
  feeds/gl_feed_common/golang/golang-values.mk


section "附加应用与构建工具"

aliyun_tmp="$(mktemp -d)"
git clone --depth=1 https://github.com/messense/aliyundrive-webdav.git "$aliyun_tmp"
replace_dir "$aliyun_tmp/openwrt/aliyundrive-webdav" feeds/packages2/multimedia/aliyundrive-webdav
replace_dir "$aliyun_tmp/openwrt/luci-app-aliyundrive-webdav" feeds/luci2/applications/luci-app-aliyundrive-webdav
rm -rf "$aliyun_tmp"

# LEDE 这里只需要 ninja 和 adbyby 两个目录，使用 sparse checkout 避免拉完整工作树。
lede_tmp="$(mktemp -d)"
git clone --depth=1 --filter=blob:none --sparse https://github.com/coolsnowwolf/lede.git "$lede_tmp"
git -C "$lede_tmp" sparse-checkout set tools/ninja package/lean/adbyby
replace_dir "$lede_tmp/tools/ninja" tools/ninja
replace_dir "$lede_tmp/package/lean/adbyby" package/adbyby
rm -rf "$lede_tmp"

rm -rf package/luci-app-adguardhome
git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome


section "板级文件与本地兼容库"

# libs.zip 和 board 文件已经随当前 commit checkout 到 GITHUB_WORKSPACE。
# 直接使用本地副本，确保本次构建与当前 commit 完全一致，也避免重复访问 GitHub Raw。
[ -f "${GITHUB_WORKSPACE}/libs.zip" ] || die "找不到本地 libs.zip"
[ -f "${GITHUB_WORKSPACE}/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe" ] ||
  die "找不到本地 board-2.bin"

rm -rf package/libs/openssl package/libs/ustream-ssl
unzip -oq "${GITHUB_WORKSPACE}/libs.zip"

mkdir -p dl
cp -f \
  "${GITHUB_WORKSPACE}/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe" \
  "dl/board-2.bin.ddcec9efd245da9365c474f513a855a55f3ac7fe"


section "OpenWrt 18.06 的 CMake 与 ccache 兼容"

# OpenWrt 18.06 会把 ccache 本身当作 CMAKE_C_COMPILER，再通过
# CMAKE_*_COMPILER_ARG1 传入真正的交叉编译器。当前较新的 CMake 在探测编译器时
# 会丢掉 ARG1，导致 ccache 把 -pipe 等编译参数误当成自身参数。
# 这里改用 CMake 原生 COMPILER_LAUNCHER：CMAKE_*_COMPILER 保留真实交叉编译器，
# ccache 只作为前置 launcher，从而兼容现代 CMake。
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

if "-DCMAKE_C_COMPILER_LAUNCHER=" not in text:
    lines = text.splitlines()
    out = []
    inserted_cxx = False
    inserted_asm = False

    for line in lines:
        out.append(line)

        stripped = line.strip()
        indent = line[:len(line) - len(line.lstrip())]

        if stripped.startswith('-DCMAKE_CXX_COMPILER_ARG1='):
            out.append(
                indent + '-DCMAKE_C_COMPILER_LAUNCHER="$(CMAKE_C_COMPILER_LAUNCHER)" \\'
            )
            out.append(
                indent + '-DCMAKE_CXX_COMPILER_LAUNCHER="$(CMAKE_CXX_COMPILER_LAUNCHER)" \\'
            )
            inserted_cxx = True

        if stripped.startswith('-DCMAKE_ASM_COMPILER_ARG1='):
            out.append(
                indent + '-DCMAKE_ASM_COMPILER_LAUNCHER="$(CMAKE_C_COMPILER_LAUNCHER)" \\'
            )
            inserted_asm = True

    if not inserted_cxx or not inserted_asm:
        raise SystemExit("include/cmake.mk CMake configure argument anchors not found")

    text = "\n".join(out) + "\n"

path.write_text(text)
PY


section "同步最终配置"

# 所有 feed / package 替换完成后，重新安装被替换包的链接并刷新包元数据。
./scripts/feeds install -f -p packages shadowsocks-libev
./scripts/feeds install -f -p packages lyaml

# Passwall UI 追新后，部分旧版 UI 开关已经被上游取消。
# 仍有明确用途且当前可维护的功能包独立保留。
for symbol in \
  PACKAGE_lyaml \
  PACKAGE_coreutils-timeout \
  PACKAGE_shadowsocks-libev-config \
  PACKAGE_shadowsocks-libev-ss-local \
  PACKAGE_shadowsocks-libev-ss-redir \
  PACKAGE_trojan \
  PACKAGE_miniupnpd; do
  config_enable "$symbol"
done

# OpenWrt 18.06 自带 ccache 支持，缓存目录由 GitHub Actions 跨构建保存。
config_enable CCACHE

rm -f tmp/.packageinfo tmp/.packagedeps tmp/.config-package.in
make defconfig

required_symbols=(
  PACKAGE_luci-app-passwall
  PACKAGE_lyaml
  PACKAGE_coreutils-timeout
  PACKAGE_shadowsocks-libev-config
  PACKAGE_shadowsocks-libev-ss-local
  PACKAGE_shadowsocks-libev-ss-redir
  PACKAGE_trojan
  PACKAGE_miniupnpd
  CCACHE
)

for symbol in "${required_symbols[@]}"; do
  grep -q "^CONFIG_${symbol}=y$" .config ||
    die "make defconfig 后关键配置未保留：CONFIG_${symbol}=y"
done

if grep -Rqs '+luci-compat' \
  feeds/PWluci/luci-app-passwall/Makefile \
  feeds/luci2/applications/luci-app-passwall/Makefile; then
  die "Passwall 仍然依赖 luci-compat"
fi

for symbol in \
  PACKAGE_luci-compat \
  PACKAGE_luci-lua-runtime \
  PACKAGE_luci-lib-base \
  PACKAGE_ucode-mod-lua; do
  if grep -Eq "^CONFIG_${symbol}=[ym]$" .config; then
    die "不兼容的现代 LuCI 包又被重新选中：CONFIG_${symbol}"
  fi
done

echo "配置检查通过；ccache 已启用。"


section "Host ncurses 兼容处理"

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

# 将运行时库搜索路径写入 GITHUB_ENV，供后续 Actions 步骤继续使用。
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}" >> "$GITHUB_ENV"
fi

section "diy-part2 执行完成"
