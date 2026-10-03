#!/usr/bin/env bash
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

src="feeds/helloworld/luci-app-ssr-plus/root/etc/init.d/shadowsocksr"
grep -Fq 'local dnsmasq_bin="/usr/sbin/dnsmasq"' "$src" ||
  die "SSR Plus dnsmasq 18.06 检测补丁未生效"
grep -Fq '[ -x /usr/sbin/iptables ]' "$src" ||
  die "SSR Plus iptables 绝对路径检测未生效"
grep -Fq '[ -x /usr/sbin/ipset ]' "$src" ||
  die "SSR Plus ipset 绝对路径检测未生效"
grep -Fq "grep -q -- '--ipset'" "$src" ||
  die "SSR Plus dnsmasq --help 能力探测未生效"
grep -Fq 'dnsmasq能力：' "$src" ||
  die "SSR Plus dnsmasq 能力诊断日志未生效"
grep -Fq '透明代理环境检测：' "$src" ||
  die "SSR Plus 环境诊断日志未生效"
grep -Fq 'runtime.log' "$src" ||
  die "SSR Plus 核心运行日志补丁未生效"
monitor_src="feeds/helloworld/luci-app-ssr-plus/root/usr/bin/ssr-monitor"
grep -Fq 'tcp_port_listening()' "$monitor_src" ||
  die "SSR Plus monitor 端口存活检测未生效"
grep -Fq 'ps_count:' "$monitor_src" ||
  die "SSR Plus monitor 失败诊断未生效"

makefile="feeds/helloworld/luci-app-ssr-plus/Makefile"
! grep -Eq 'iptables-(zz-legacy|mod-socket)' "$makefile" ||
  die "SSR Plus 仍引用现代 OpenWrt iptables 拆包依赖"

mapfile -t ipks < <(find bin -type f -name 'luci-app-ssr-plus_*.ipk' -print | sort)
[ "${#ipks[@]}" -eq 1 ] || die "luci-app-ssr-plus ipk 数量异常：${#ipks[@]}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "${ipks[0]}" -C "$tmp" ./data.tar.gz
tar -xzf "$tmp/data.tar.gz" -C "$tmp"
final_init="$tmp/etc/init.d/shadowsocksr"
[ -f "$final_init" ] || die "最终 SSR Plus ipk 缺少 init 脚本"
grep -Fq 'local dnsmasq_bin="/usr/sbin/dnsmasq"' "$final_init" ||
  die "最终 SSR Plus ipk 未包含 dnsmasq 兼容修复"
grep -Fq "grep -q -- '--ipset'" "$final_init" ||
  die "最终 SSR Plus ipk 未包含 dnsmasq --help 能力探测"
grep -Fq 'dnsmasq能力：' "$final_init" ||
  die "最终 SSR Plus ipk 未包含 dnsmasq 能力诊断日志"
grep -Fq '透明代理环境检测：' "$final_init" ||
  die "最终 SSR Plus ipk 未包含环境诊断日志"
grep -Fq 'runtime.log' "$final_init" ||
  die "最终 SSR Plus ipk 未包含核心运行日志补丁"

final_monitor="$tmp/usr/bin/ssr-monitor"
[ -f "$final_monitor" ] || die "最终 SSR Plus ipk 缺少 ssr-monitor"
grep -Fq 'tcp_port_listening()' "$final_monitor" ||
  die "最终 SSR Plus ipk 未包含 monitor 端口存活检测"
grep -Fq 'ps_count:' "$final_monitor" ||
  die "最终 SSR Plus ipk 未包含 monitor 失败诊断"

mapfile -t dnsmasq_ipks < <(find bin -type f -name 'dnsmasq-full_*.ipk' -print | sort)
[ "${#dnsmasq_ipks[@]}" -eq 1 ] || die "dnsmasq-full ipk 数量异常：${#dnsmasq_ipks[@]}"

dns_tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$dns_tmp"' EXIT
tar -xzf "${dnsmasq_ipks[0]}" -C "$dns_tmp" ./data.tar.gz
tar -xzf "$dns_tmp/data.tar.gz" -C "$dns_tmp"
dns_bin="$dns_tmp/usr/sbin/dnsmasq"
[ -f "$dns_bin" ] || die "dnsmasq-full ipk 缺少 /usr/sbin/dnsmasq"

strings "$dns_bin" | grep -Eq '^(IPv6|no-IPv6).*[[:space:]]ipset([[:space:]]|$)' ||
  die "最终 dnsmasq-full 二进制未编入 ipset 能力"

echo "dnsmasq-full 二进制 ipset 能力检查通过"
echo "SSR Plus iptables 透明代理兼容校验通过"
