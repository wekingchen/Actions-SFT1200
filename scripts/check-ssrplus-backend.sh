#!/usr/bin/env bash
#
# 校验 SFT1200 / OpenWrt 18.06 的 SSR Plus iptables 透明代理运行环境。
#
set -Eeuo pipefail

die() {
  echo "错误：$*" >&2
  exit 1
}

required_symbols=(
  PACKAGE_dnsmasq-full
  PACKAGE_dnsmasq_full_ipset
  PACKAGE_ipset
  PACKAGE_iptables
  PACKAGE_iptables-mod-tproxy
  PACKAGE_iptables-mod-iprange
  PACKAGE_iptables-mod-conntrack-extra
  PACKAGE_kmod-ipt-nat
  PACKAGE_kmod-ipt-tproxy
)

for symbol in "${required_symbols[@]}"; do
  grep -Fqx "CONFIG_${symbol}=y" .config ||
    die "缺少 SSR Plus iptables 后端配置：CONFIG_${symbol}=y"
done

ssr_init="feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr"
[ -f "$ssr_init" ] || die "找不到 SSR Plus init 脚本：$ssr_init"
grep -Fq 'dnsmasq -v 2>&1' "$ssr_init" ||
  die "SSR Plus dnsmasq 特性检测兼容补丁未生效"
grep -Fq '透明代理环境检测：' "$ssr_init" ||
  die "SSR Plus 运行环境诊断日志未生效"

grep -Fq 'nf_add,IPT_TPROXY,CONFIG_NETFILTER_XT_MATCH_SOCKET' include/netfilter.mk ||
  die "IPT_TPROXY 未包含 xt_socket"
grep -A24 '^define KernelPackage/ipt-tproxy' package/kernel/linux/modules/netfilter.mk |
  grep -Fq 'CONFIG_NETFILTER_XT_MATCH_SOCKET' ||
  die "kmod-ipt-tproxy 未启用 xt_socket"

find_one_ipk() {
  local pattern="$1"
  local -a found
  mapfile -t found < <(find bin -type f -name "$pattern" -print | sort)
  [ "${#found[@]}" -eq 1 ] || {
    echo "匹配 $pattern 的 ipk 数量异常：${#found[@]}" >&2
    printf '  %s\n' "${found[@]:-}" >&2
    exit 1
  }
  printf '%s\n' "${found[0]}"
}

ipk_has_file() {
  local ipk="$1"
  local pattern="$2"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  tar -xzf "$ipk" -C "$tmp" ./data.tar.gz
  tar -tzf "$tmp/data.tar.gz" | grep -Eq "$pattern" ||
    die "$(basename "$ipk") 缺少文件：$pattern"
  rm -rf "$tmp"
  trap - RETURN
}

ipt_tproxy_ipk="$(find_one_ipk 'iptables-mod-tproxy_*.ipk')"
kmod_tproxy_ipk="$(find_one_ipk 'kmod-ipt-tproxy_*.ipk')"

ipk_has_file "$ipt_tproxy_ipk" '/libxt_TPROXY\.so$'
ipk_has_file "$ipt_tproxy_ipk" '/libxt_socket\.so$'
ipk_has_file "$kmod_tproxy_ipk" '/xt_TPROXY\.ko$'
ipk_has_file "$kmod_tproxy_ipk" '/xt_socket\.ko$'

echo "SSR Plus iptables 透明代理后端校验通过：iptables/ipset/dnsmasq-full + TPROXY/socket 完整"
