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
readonly LEGACY_LUCI_COMMIT="548670c9f699689b26e33ed6a300c3717d72a2b6"
readonly LEGACY_PACKAGES_1806_COMMIT="a1213c7a2011a2916fb357462a51082ffe9fa2c4"
readonly GOLANG_BRANCH="27.x"
readonly NAIVEPROXY_ARCH="mipsel_24kc-static"
readonly UPSTREAM_RECORD=".sft1200-upstreams.env"

section() {
  printf '\n========== %s ==========\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# diy-part1 已创建追溯文件并记录直接追踪 LEDE master 的 meson.mk SHA256。
# 这里保留该记录并继续追加 diy-part2 的动态上游 commit。
[ -s "$UPSTREAM_RECORD" ] ||
  die "Missing upstream trace record from diy-part1: $UPSTREAM_RECORD"
grep -Eq '^upstream_meson_mk_sha256=[0-9a-f]{64}$' "$UPSTREAM_RECORD" ||
  die "Invalid or missing upstream_meson_mk_sha256 in $UPSTREAM_RECORD"

record_upstream() {
  local key="$1"
  local repo_dir="$2"
  local commit

  [ -d "$repo_dir/.git" ] || die "Upstream repository not found: $repo_dir"
  commit="$(git -C "$repo_dir" rev-parse HEAD)"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
    die "Invalid upstream commit for $key: $commit"

  sed -i "/^${key}=/d" "$UPSTREAM_RECORD"
  printf '%s=%s\n' "$key" "$commit" >> "$UPSTREAM_RECORD"
  echo "上游快照：$key=$commit"
}

record_fixed_upstream() {
  local key="$1"
  local commit="$2"

  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] ||
    die "Invalid fixed upstream commit for $key: $commit"

  sed -i "/^${key}=/d" "$UPSTREAM_RECORD"
  printf '%s=%s\n' "$key" "$commit" >> "$UPSTREAM_RECORD"
  echo "固定上游快照：$key=$commit"
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
  local version release tag asset url archive sha256 expected_sha actual_sha meta_asset
  local meta_version meta_release

  [ -f "$makefile" ] || die "NaiveProxy Makefile not found: $makefile"

  version="$(sed -n 's/^PKG_VERSION:=//p' "$makefile" | head -n1 | tr -d '[:space:]')"
  release="$(sed -n 's/^PKG_RELEASE:=//p' "$makefile" | head -n1 | tr -d '[:space:]')"

  [ -n "$version" ] || die "Unable to read NaiveProxy PKG_VERSION"
  [ -n "$release" ] || die "Unable to read NaiveProxy PKG_RELEASE"

  tag="v${version}-${release}"
  asset="naiveproxy-${tag}-openwrt-${NAIVEPROXY_ARCH}.tar.xz"
  archive="dl/${asset}"

  # GitHub Release API 查询已经在只读 Preflight job 中完成。
  # build job 不持有 GitHub token，只消费经过校验的公开 Release 元数据。
  meta_version="${NAIVEPROXY_META_VERSION:-}"
  meta_release="${NAIVEPROXY_META_RELEASE:-}"
  meta_asset="${NAIVEPROXY_META_ASSET:-}"
  expected_sha="${NAIVEPROXY_META_SHA256:-}"
  url="${NAIVEPROXY_META_URL:-}"

  [ "$meta_version" = "$version" ] ||
    die "NaiveProxy metadata version mismatch: feed=$version metadata=${meta_version:-missing}"
  [ "$meta_release" = "$release" ] ||
    die "NaiveProxy metadata release mismatch: feed=$release metadata=${meta_release:-missing}"
  [ "$meta_asset" = "$asset" ] ||
    die "NaiveProxy metadata asset mismatch: expected=$asset metadata=${meta_asset:-missing}"
  [ "${#expected_sha}" -eq 64 ] ||
    die "NaiveProxy official digest has invalid length: ${expected_sha:-missing}"
  case "$expected_sha" in
    *[!0-9a-f]*)
      die "NaiveProxy official digest is not lowercase SHA256: $expected_sha"
      ;;
  esac
  [ "$url" = "https://github.com/klzgrad/naiveproxy/releases/download/${tag}/${asset}" ] ||
    die "Unexpected NaiveProxy asset URL: ${url:-missing}"

  echo "NaiveProxy: version=${version}, release=${release}, arch=${NAIVEPROXY_ARCH}"
  echo "使用 Preflight 校验的 GitHub Release digest：$expected_sha"

  if [ -s "$archive" ]; then
    actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
    if [ "$actual_sha" = "$expected_sha" ]; then
      echo "Reuse verified NaiveProxy cache: $archive"
    else
      echo "Cached NaiveProxy digest mismatch; redownloading: $archive"
      rm -f "$archive"
    fi
  fi

  if [ ! -s "$archive" ]; then
    download_cached "$url" "$archive"
  fi

  actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
  if [ "$actual_sha" != "$expected_sha" ]; then
    rm -f "$archive"
    die "NaiveProxy SHA256 mismatch: expected=$expected_sha actual=$actual_sha"
  fi

  if ! tar -tJf "$archive" >/dev/null 2>&1; then
    rm -f "$archive"
    die "Invalid NaiveProxy release archive: $asset"
  fi

  sha256="$expected_sha"
  echo "NaiveProxy SHA256 verified by GitHub Release digest: $sha256"

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

  cat > .sft1200-naiveproxy.env <<EOF
naiveproxy_version=${version}
naiveproxy_release=${release}
naiveproxy_arch=${NAIVEPROXY_ARCH}
naiveproxy_asset=${asset}
naiveproxy_sha256=${sha256}
naiveproxy_digest_source=github-release-api
EOF
}


section "代理组件"

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

old_dep = "PKG_BUILD_DEPENDS:=lua/host luarocks/host HOST_OS_MACOS:fakeuname/host"
new_dep = "PKG_BUILD_DEPENDS:=lua/host luarocks/host"

if old_dep in text:
    text = text.replace(old_dep, new_dep, 1)
elif new_dep not in text:
    raise SystemExit("lyaml host build dependency block not found")

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


section "SSR Plus iptables 透明代理兼容"

# fw876/helloworld 当前版本同时兼容 fw4/nftables 与 fw3/iptables，但其新版
# iptables 依赖按现代 OpenWrt 拆包：iptables-zz-legacy、iptables-mod-socket。
# Siflower 18.06 使用 legacy iptables，socket match 已属于 iptables-mod-tproxy /
# kmod-ipt-tproxy，不存在上述两个独立包，因此移除这两个无效 select。
ssr_makefile="feeds/helloworld/luci-app-ssr-plus/Makefile"
sed -i \
  -e '/select PACKAGE_iptables-zz-legacy/d' \
  -e '/select PACKAGE_iptables-mod-socket/d' \
  "$ssr_makefile"

# LuCI/procd 调用旧版 init 脚本时不要依赖外部 PATH；直接识别 18.06 固定位置。
# dnsmasq -v 同时收集 stdout/stderr，避免 ipset 编译特性被误判为不存在。
python3 - <<'PY'
from pathlib import Path

path = Path("feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr")
text = path.read_text()

old = '''check_run_environment() {
	local prefer_nft="$(uci_get_by_type global prefer_nft 1)"
	local dnsmasq_info=$(dnsmasq -v 2>/dev/null)
	local dnsmasq_ver=$(echo "$dnsmasq_info" | sed -n '1s/.*version \\([0-9.]*\\).*/\\1/p')

	DNSMASQ_IPSET=0; [[ "$dnsmasq_info" == *" ipset"* ]] && DNSMASQ_IPSET=1
	DNSMASQ_NFTSET=0; [[ "$dnsmasq_info" == *" nftset"* ]] && DNSMASQ_NFTSET=1
	HAS_IPT=0; { command -v iptables-legacy || command -v iptables; } >/dev/null && HAS_IPT=1
	HAS_IPSET=$(command -v ipset >/dev/null && echo 1 || echo 0)
	HAS_FW4=$(command -v fw4 >/dev/null && echo 1 || echo 0)
	HAS_NFT=$(command -v nft >/dev/null && echo 1 || echo 0)
'''

new = '''check_run_environment() {
	local prefer_nft="$(uci_get_by_type global prefer_nft 1)"
	local dnsmasq_bin="/usr/sbin/dnsmasq"
	[ -x "$dnsmasq_bin" ] || dnsmasq_bin="$(command -v dnsmasq 2>/dev/null)"
	local dnsmasq_info=""
	local dnsmasq_help=""
	local dnsmasq_ver=""
	local dnsmasq_features=""

	if [ -n "$dnsmasq_bin" ] && [ -x "$dnsmasq_bin" ]; then
		dnsmasq_info="$("$dnsmasq_bin" -v 2>&1)"
		dnsmasq_help="$("$dnsmasq_bin" --help 2>&1)"
		dnsmasq_ver=$(printf '%s\\n' "$dnsmasq_info" | sed -n '1s/.*version \\([0-9.]*\\).*/\\1/p')
		dnsmasq_features=$(printf '%s\\n' "$dnsmasq_info" | sed -n 's/^Compile time options:[[:space:]]*//p' | head -n1)
	fi

	DNSMASQ_IPSET=0
	if printf '%s\\n' "$dnsmasq_help" | grep -q -- '--ipset'; then
		DNSMASQ_IPSET=1
	elif printf '%s\\n' "$dnsmasq_info" | grep -Eq '(^|[[:space:]])ipset([[:space:]]|$)'; then
		DNSMASQ_IPSET=1
	fi

	DNSMASQ_NFTSET=0
	if printf '%s\\n' "$dnsmasq_help" | grep -q -- '--nftset'; then
		DNSMASQ_NFTSET=1
	elif printf '%s\\n' "$dnsmasq_info" | grep -Eq '(^|[[:space:]])nftset([[:space:]]|$)'; then
		DNSMASQ_NFTSET=1
	fi

	HAS_IPT=0
	if [ -x /usr/sbin/iptables-legacy ] || [ -x /usr/sbin/iptables ] || \
	   command -v iptables-legacy >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then
		HAS_IPT=1
	fi

	HAS_IPSET=0
	if [ -x /usr/sbin/ipset ] || command -v ipset >/dev/null 2>&1; then
		HAS_IPSET=1
	fi

	HAS_FW4=$(command -v fw4 >/dev/null 2>&1 && echo 1 || echo 0)
	HAS_NFT=$(command -v nft >/dev/null 2>&1 && echo 1 || echo 0)

	[ -n "$dnsmasq_ver" ] || dnsmasq_ver="unknown"
	[ -n "$dnsmasq_features" ] || dnsmasq_features="unknown"
	echolog "dnsmasq能力：bin:${dnsmasq_bin:-missing}/version:$dnsmasq_ver/options:$dnsmasq_features"
	echolog "透明代理环境检测：has_ipt:$HAS_IPT/has_ipset:$HAS_IPSET/dnsmasq_ipset:$DNSMASQ_IPSET/has_fw4:$HAS_FW4/has_nft:$HAS_NFT/dnsmasq_nftset:$DNSMASQ_NFTSET"
'''

if old not in text:
    if new not in text:
        raise SystemExit("SSR Plus check_run_environment anchor not found")
else:
    text = text.replace(old, new, 1)

# 18.06 的 tproxy 包已包含 socket match，运行时依赖检查不要再要求现代独立包。
text = text.replace(
    'dep_list="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange iptables-mod-conntrack-extra kmod-ipt-nat"',
    'dep_list="iptables-mod-tproxy iptables-mod-iprange iptables-mod-conntrack-extra kmod-ipt-nat"',
)

# 5) 18.06 上的 BusyBox ps 即使开启 -w，按配置文件名匹配 redir 进程仍可能不稳定。
#    同时保留关键核心 stderr，并让 monitor 以 TCP 监听端口作为第二重存活依据。
ln_old = '''	ulimit -n 1000000
	${file_func:-echolog "  - ${ln_name}"} "$@" >/dev/null 2>&1 &
}'''
ln_new = '''	ulimit -n 1000000
	case "$ln_name" in
		v2ray|naive|ss-redir|ssr-redir|trojan|hysteria|tuic-client|shadow-tls)
			local runtime_log="$TMP_PATH/${ln_name}.runtime.log"
			: >"$runtime_log"
			${file_func:-echolog "  - ${ln_name}"} "$@" >>"$runtime_log" 2>&1 &
			;;
		*)
			${file_func:-echolog "  - ${ln_name}"} "$@" >/dev/null 2>&1 &
			;;
	esac
}'''
if ln_old in text:
    text = text.replace(ln_old, ln_new, 1)
elif ln_new not in text:
    raise SystemExit("SSR Plus ln_start_bin logging anchor not found")
path.write_text(text)

monitor = Path("feeds/helloworld/luci-app-ssr-plus/root/usr/bin/ssr-monitor")
mtext = monitor.read_text()

monitor_vars = '''GLOBAL_SERVER=$(uci_get_by_type global global_server)
server=$(uci_get_by_name $GLOBAL_SERVER server)'''
monitor_vars_new = '''GLOBAL_SERVER=$(uci_get_by_type global global_server)
TCP_REDIR_PORT=$(uci_get_by_name "$GLOBAL_SERVER" local_port 1234)

tcp_port_listening() {
	local port="$1"
	local hex
	case "$port" in
		''|*[!0-9]*) return 1 ;;
	esac
	hex=$(printf '%04X' "$port" 2>/dev/null) || return 1
	awk -v suffix=":$hex" '
		$2 ~ (suffix "$") && $4 == "0A" { found=1 }
		END { exit(found ? 0 : 1) }
	' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

dump_redir_runtime_log() {
	local log
	for log in "$TMP_PATH"/*.runtime.log; do
		[ -s "$log" ] || continue
		echolog "redir 核心日志：$(basename "$log")"
		tail -n 8 "$log" 2>/dev/null | while IFS= read -r line; do
			echolog "  $line"
		done
	done
}

server=$(uci_get_by_name $GLOBAL_SERVER server)'''
if monitor_vars in mtext:
    mtext = mtext.replace(monitor_vars, monitor_vars_new, 1)
elif "tcp_port_listening()" not in mtext:
    raise SystemExit("ssr-monitor variable anchor not found")

redir_old = '''		icount=$(busybox ps -w | grep ssr-retcp | grep -v grep | wc -l)
		if [ "$icount" == 0 ]; then
			logger -t "$NAME" "ssrplus redir tcp error.restart!"
			echolog "ssrplus redir tcp error.restart!"
			/etc/init.d/shadowsocksr restart
			exit 0
		fi'''
redir_new = '''		icount=$(busybox ps -w | grep ssr-retcp | grep -v grep | wc -l)
		listen_count=0
		tcp_port_listening "$TCP_REDIR_PORT" && listen_count=1

		if [ "$icount" -eq 0 ] && [ "$listen_count" -eq 1 ]; then
			echolog "redir tcp监控：ps未匹配，但端口$TCP_REDIR_PORT正常监听，保持运行。"
		elif [ "$icount" -eq 0 ] && [ "$listen_count" -eq 0 ]; then
			logger -t "$NAME" "ssrplus redir tcp error.restart!"
			echolog "ssrplus redir tcp error.restart! (ps_count:$icount/listen:$listen_count/port:$TCP_REDIR_PORT)"
			dump_redir_runtime_log
			/etc/init.d/shadowsocksr restart
			exit 0
		fi'''
if redir_old in mtext:
    mtext = mtext.replace(redir_old, redir_new, 1)
elif 'redir tcp监控：ps未匹配' not in mtext:
    raise SystemExit("ssr-monitor redir tcp anchor not found")

monitor.write_text(mtext)

# 6) SFT1200 / OpenWrt 18.06 是 fw3/iptables 平台。
#    上游默认 prefer_nft=1 会造成每次启动先报 nftables 不完整再回退。
client_lua = Path("feeds/helloworld/luci-app-ssr-plus/luasrc/model/cbi/shadowsocksr/client.lua")
ctext = client_lua.read_text()
needle = '''o = s:option(ListValue, "prefer_nft", translate("Prefer firewall tools"))
o.default = "1"
o:value("0", "Iptables")
o:value("1", "Nftables")'''
replacement = '''o = s:option(ListValue, "prefer_nft", translate("Prefer firewall tools"))
o.default = "0"
o:value("0", "Iptables")
o:value("1", "Nftables")'''
if needle in ctext:
    ctext = ctext.replace(needle, replacement, 1)
elif replacement not in ctext:
    raise SystemExit("SSR Plus prefer_nft UI anchor not found")
client_lua.write_text(ctext)

default_cfg = Path("feeds/helloworld/luci-app-ssr-plus/root/usr/share/shadowsocksr/shadowsocksr.config")
cfgtext = default_cfg.read_text()
cfgtext = cfgtext.replace("option prefer_nft '1'", "option prefer_nft '0'")
default_cfg.write_text(cfgtext)

# 当 UCI 项不存在时也默认 iptables；已有用户明确选择仍然尊重。
text = text.replace(
    'local prefer_nft="$(uci_get_by_type global prefer_nft 1)"',
    'local prefer_nft="$(uci_get_by_type global prefer_nft 0)"',
)

# 7) Xray 在真正启动前先使用官方 -test 校验配置。
#    新版核心若拒绝旧式公网 VLESS 明文节点，直接打印原因并停止，
#    不再先显示 Started 再由 monitor 每 30 秒循环重启。
v2ray_old = '''	v2ray)
		gen_config_file $GLOBAL_SERVER $type 1 $tcp_port $socks_port
		ln_start_bin $(first_type xray v2ray) v2ray run -c $tcp_config_file
		echolog "Main node:$($(first_type xray v2ray) version | head -1) Started!"
		;;'''
v2ray_new = '''	v2ray)
		gen_config_file $GLOBAL_SERVER $type 1 $tcp_port $socks_port
		local core_bin="$(first_type xray v2ray)"
		if [ "$(basename "$core_bin")" = "xray" ]; then
			local xray_check
			xray_check="$("$core_bin" run -test -c "$tcp_config_file" 2>&1)"
			local xray_rc=$?
			if [ "$xray_rc" -ne 0 ]; then
				echolog "Xray 配置校验失败，主节点未启动："
				printf '%s\n' "$xray_check" | tail -n 10 | while IFS= read -r line; do
					echolog "  $line"
				done
				echolog "-----------end------------"
				_exit 2
			fi
		fi
		ln_start_bin "$core_bin" v2ray run -c "$tcp_config_file"
		echolog "Main node:$("$core_bin" version | head -1) Started!"
		;;'''
if v2ray_old in text:
    text = text.replace(v2ray_old, v2ray_new, 1)
elif 'Xray 配置校验失败，主节点未启动' not in text:
    raise SystemExit("SSR Plus v2ray start anchor not found")

assert 'prefer_nft 0' in text
assert 'Xray 配置校验失败，主节点未启动' in text
assert 'o.default = "0"' in client_lua.read_text()
assert "option prefer_nft '0'" in default_cfg.read_text()
assert "runtime.log" in text
assert "tcp_port_listening()" in monitor.read_text()
assert "ps_count:" in monitor.read_text()

path.write_text(text)
PY

grep -Fq 'local dnsmasq_bin="/usr/sbin/dnsmasq"'   feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus dnsmasq 18.06 兼容检测未生效"
grep -Fq 'dnsmasq能力：' feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus dnsmasq 能力诊断日志未生效"
grep -Fq "grep -q -- '--ipset'" feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus dnsmasq --help 能力探测未生效"
grep -Fq '透明代理环境检测：' feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus 运行环境诊断日志未生效"
grep -Fq 'runtime.log' feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus 核心运行日志补丁未生效"
grep -Fq 'tcp_port_listening()' feeds/helloworld/luci-app-ssr-plus/root/usr/bin/ssr-monitor ||
  die "SSR Plus monitor 端口存活检测未生效"
grep -Fq 'ps_count:' feeds/helloworld/luci-app-ssr-plus/root/usr/bin/ssr-monitor ||
  die "SSR Plus monitor 失败诊断未生效"
grep -Fq 'uci_get_by_type global prefer_nft 0' feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus SFT1200 默认 iptables 未生效"
grep -Fq 'Xray 配置校验失败，主节点未启动' feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr ||
  die "SSR Plus Xray 启动前配置校验未生效"
grep -Fq 'o.default = "0"' feeds/helloworld/luci-app-ssr-plus/luasrc/model/cbi/shadowsocksr/client.lua ||
  die "SSR Plus LuCI 默认 firewall 未切换为 iptables"
if grep -Eq 'iptables-(zz-legacy|mod-socket)' "$ssr_makefile"; then
  die "SSR Plus 仍残留现代 OpenWrt iptables 拆包依赖"
fi


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

grep -q 'liblua5\.4' feeds/gl_feed_1806/haproxy/Makefile ||
  die "HAProxy Lua 5.4 兼容修改未生效"
if grep -Eq '^[[:space:]]*ADDON\+=USE_QUIC=1' feeds/gl_feed_1806/haproxy/Makefile; then
  die "HAProxy QUIC 仍处于启用状态"
fi

# 当前 Xray 等现代代理核心需要较新的 Go 工具链。
rm -rf feeds/gl_feed_common/golang
git clone --depth=1 --branch "$GOLANG_BRANCH" \
  https://github.com/sbwml/packages_lang_golang \
  feeds/gl_feed_common/golang
record_upstream upstream_golang_commit feeds/gl_feed_common/golang
sed -i '/-linkmode external \\/d' feeds/gl_feed_common/golang/golang-package.mk

# Go 默认把 GOCACHE 放在 tmp/go-build，工作流结束后会丢失。
# 改到仓库内固定目录，交给 Actions Cache 跨构建复用。
sed -i 's|$(TMP_DIR)/go-build|$(TOPDIR)/.cache/go-build|g' \
  feeds/gl_feed_common/golang/golang-values.mk

grep -Fq '$(TOPDIR)/.cache/go-build' feeds/gl_feed_common/golang/golang-values.mk ||
  die "Go GOCACHE 路径修改未生效"


section "恢复旧版 LuCI 功能"

# #786 之前的基准配置依赖这些 Lua LuCI 前端。它们已不再由当前固定的 luci2
# 快照完整提供，因此单独固定兼容源码并放入 package/；这些包本身仍是 Lua LuCI，
# 统一接回系统原生 feeds/luci/luci.mk，避免现代 luci-compat / luci-lua-runtime 依赖。
legacy_luci_archive="dl/coolsnowwolf-luci-${LEGACY_LUCI_COMMIT}.tar.gz"
legacy_luci_tmp="$(mktemp -d)"
download_cached \
  "https://github.com/coolsnowwolf/luci/archive/${LEGACY_LUCI_COMMIT}.tar.gz" \
  "$legacy_luci_archive"
tar -C "$legacy_luci_tmp" -xzf "$legacy_luci_archive"
legacy_luci_src="$(find "$legacy_luci_tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$legacy_luci_src" ] || die "旧版 LuCI 源码解压失败"

for app in luci-app-zerotier luci-app-autoreboot; do
  replace_dir "$legacy_luci_src/applications/$app" "package/$app"

  # 这两个历史快照使用 zh_Hans 目录；18.06 的 LuCI/Kconfig 使用 zh-cn。
  if [ -d "package/$app/po/zh_Hans" ]; then
    rm -rf "package/$app/po/zh-cn"
    mv "package/$app/po/zh_Hans" "package/$app/po/zh-cn"
  fi

  sed -i '/luci\.mk$/c\include $(TOPDIR)/feeds/luci/luci.mk' "package/$app/Makefile"
done
rm -rf "$legacy_luci_tmp"
record_fixed_upstream upstream_legacy_luci_commit "$LEGACY_LUCI_COMMIT"

legacy_packages_archive="dl/openwrt-packages-18.06-${LEGACY_PACKAGES_1806_COMMIT}.tar.gz"
legacy_packages_tmp="$(mktemp -d)"
download_cached \
  "https://github.com/Aibx/OpenWRT-Packages/archive/${LEGACY_PACKAGES_1806_COMMIT}.tar.gz" \
  "$legacy_packages_archive"
tar -C "$legacy_packages_tmp" -xzf "$legacy_packages_archive"
legacy_packages_src="$(find "$legacy_packages_tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$legacy_packages_src" ] || die "OpenWrt 18.06 兼容包源码解压失败"

replace_dir "$legacy_packages_src/luci-app-adbyby-plus" package/luci-app-adbyby-plus
replace_dir "$legacy_packages_src/luci-theme-argon-mod" package/luci-theme-argon-mod
rm -rf "$legacy_packages_tmp"

for makefile in \
  package/luci-app-adbyby-plus/Makefile \
  package/luci-theme-argon-mod/Makefile; do
  sed -i '/luci\.mk$/c\include $(TOPDIR)/feeds/luci/luci.mk' "$makefile"
done
record_fixed_upstream upstream_legacy_packages_1806_commit "$LEGACY_PACKAGES_1806_COMMIT"


section "附加应用与构建工具"

aliyun_tmp="$(mktemp -d)"
git clone --depth=1 https://github.com/messense/aliyundrive-webdav.git "$aliyun_tmp"
record_upstream upstream_aliyundrive_webdav_commit "$aliyun_tmp"
replace_dir "$aliyun_tmp/openwrt/aliyundrive-webdav" feeds/packages2/multimedia/aliyundrive-webdav
replace_dir "$aliyun_tmp/openwrt/luci-app-aliyundrive-webdav" package/luci-app-aliyundrive-webdav
rm -rf package/luci-app-aliyundrive-webdav/po/zh_Hans
sed -i '/luci\.mk$/c\include $(TOPDIR)/feeds/luci/luci.mk' \
  package/luci-app-aliyundrive-webdav/Makefile
rm -rf "$aliyun_tmp"

# LEDE 这里只需要 ninja 和 adbyby 两个目录，使用 sparse checkout 避免拉完整工作树。
lede_tmp="$(mktemp -d)"
git clone --depth=1 --filter=blob:none --sparse https://github.com/coolsnowwolf/lede.git "$lede_tmp"
record_upstream upstream_lede_commit "$lede_tmp"
git -C "$lede_tmp" sparse-checkout set tools/ninja package/lean/adbyby
replace_dir "$lede_tmp/tools/ninja" tools/ninja
replace_dir "$lede_tmp/package/lean/adbyby" package/adbyby
rm -rf "$lede_tmp"

rm -rf package/luci-app-adguardhome
git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome.git package/luci-app-adguardhome
record_upstream upstream_luci_app_adguardhome_commit package/luci-app-adguardhome


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
  PACKAGE_miniupnpd \
  PACKAGE_zerotier \
  PACKAGE_luci-app-zerotier \
  PACKAGE_luci-i18n-zerotier-zh-cn \
  PACKAGE_aliyundrive-webdav \
  PACKAGE_luci-app-aliyundrive-webdav \
  PACKAGE_luci-i18n-aliyundrive-webdav-zh-cn \
  PACKAGE_adbyby \
  PACKAGE_luci-app-adbyby-plus \
  PACKAGE_luci-i18n-adbyby-plus-zh-cn \
  PACKAGE_luci-app-autoreboot \
  PACKAGE_luci-i18n-autoreboot-zh-cn \
  PACKAGE_luci-theme-argon-mod \
  PACKAGE_dnsmasq-full \
  PACKAGE_dnsmasq_full_ipset \
  PACKAGE_ipset \
  PACKAGE_iptables \
  PACKAGE_iptables-mod-tproxy \
  PACKAGE_iptables-mod-iprange \
  PACKAGE_iptables-mod-conntrack-extra \
  PACKAGE_kmod-ipt-nat \
  PACKAGE_kmod-ipt-tproxy; do
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
  PACKAGE_zerotier
  PACKAGE_luci-app-zerotier
  PACKAGE_luci-i18n-zerotier-zh-cn
  PACKAGE_aliyundrive-webdav
  PACKAGE_luci-app-aliyundrive-webdav
  PACKAGE_luci-i18n-aliyundrive-webdav-zh-cn
  PACKAGE_adbyby
  PACKAGE_luci-app-adbyby-plus
  PACKAGE_luci-i18n-adbyby-plus-zh-cn
  PACKAGE_luci-app-autoreboot
  PACKAGE_luci-i18n-autoreboot-zh-cn
  PACKAGE_luci-theme-argon-mod
  PACKAGE_dnsmasq-full
  PACKAGE_dnsmasq_full_ipset
  PACKAGE_ipset
  PACKAGE_iptables
  PACKAGE_iptables-mod-tproxy
  PACKAGE_iptables-mod-iprange
  PACKAGE_iptables-mod-conntrack-extra
  PACKAGE_kmod-ipt-nat
  PACKAGE_kmod-ipt-tproxy
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


section "主机端 ncurses 兼容处理"

if ! grep -q '^HOST_CFLAGS += -fPIC$' package/libs/ncurses/Makefile; then
  sed -i '/^PKG_BUILD_DEPENDS:=ncurses\/host/a HOST_CFLAGS += -fPIC' \
    package/libs/ncurses/Makefile
fi

grep -q '^HOST_CFLAGS += -fPIC$' package/libs/ncurses/Makefile ||
  die "ncurses Host PIC 兼容修改未生效"

make package/ncurses/host/clean || true

if [ -d staging_dir/hostpkg/lib ]; then
  find staging_dir/hostpkg/lib -type f -name 'libncurses.a' -delete || true
  find staging_dir/hostpkg/lib -type f -name 'libpanel.a' -delete || true
fi

# 上游追溯文件必须完整，避免成功构建却缺少关键动态来源的 commit。
for upstream_key in \
  upstream_meson_mk_sha256 \
  upstream_golang_commit \
  upstream_legacy_luci_commit \
  upstream_legacy_packages_1806_commit \
  upstream_aliyundrive_webdav_commit \
  upstream_lede_commit \
  upstream_luci_app_adguardhome_commit; do
  if [ "$upstream_key" = "upstream_meson_mk_sha256" ]; then
    grep -Eq "^${upstream_key}=[0-9a-f]{64}$" "$UPSTREAM_RECORD" ||
      die "Missing upstream trace record: $upstream_key"
  else
    grep -Eq "^${upstream_key}=[0-9a-f]{40}$" "$UPSTREAM_RECORD" ||
      die "Missing upstream trace record: $upstream_key"
  fi
done

echo "动态上游快照："
cat "$UPSTREAM_RECORD"

# hostpkg 的运行时库路径只应提供给后续真正执行编译的 make 进程。
# 不在这里 export，也不写入 GITHUB_ENV，避免污染后续 Actions 宿主程序。
section "diy-part2 执行完成"
