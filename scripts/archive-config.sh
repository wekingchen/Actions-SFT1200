#!/usr/bin/env bash
#
# SFT1200 构建配置留档工具
#
# 用法：
#   scripts/archive-config.sh <仓库基线.config> <最终.config> <输出目录>
#
# 该脚本不会修改仓库配置，只负责把一次成功构建的真实配置整理成可复核记录。
#

set -Eeuo pipefail
IFS=$'\n\t'

baseline="${1:-}"
final_config="${2:-}"
record_dir="${3:-}"

[ -n "$baseline" ] && [ -n "$final_config" ] && [ -n "$record_dir" ] || {
  echo "用法：$0 <仓库基线.config> <最终.config> <输出目录>" >&2
  exit 2
}

[ -s "$baseline" ] || { echo "ERROR: 仓库配置基线不存在：$baseline" >&2; exit 1; }
[ -s "$final_config" ] || { echo "ERROR: 最终配置不存在：$final_config" >&2; exit 1; }

source_root="$(cd "$(dirname "$final_config")" && pwd)"
rm -rf "$record_dir"
mkdir -p "$record_dir"

cp "$baseline" "$record_dir/repository.config"
cp "$final_config" "$record_dir/final.config"

# OpenWrt diffconfig 只保留相对默认值真正有意义的配置，适合人工复核和迁移。
if [ -x "$source_root/scripts/diffconfig.sh" ]; then
  if ! (
    cd "$source_root"
    ./scripts/diffconfig.sh
  ) > "$record_dir/diffconfig.txt"; then
    echo "# diffconfig.sh 执行失败，请以 final.config 为准。" > "$record_dir/diffconfig.txt"
  fi
else
  echo "# 当前源码树没有 scripts/diffconfig.sh，请以 final.config 为准。" > "$record_dir/diffconfig.txt"
fi

# 按 CONFIG symbol 比较基线与最终配置，忽略纯排序变化。
python3 - "$record_dir/repository.config" "$record_dir/final.config" \
  "$record_dir/config-changes.diff" "$record_dir/config-stats.env" <<'PY'
from pathlib import Path
import sys

baseline_path, final_path, diff_path, stats_path = map(Path, sys.argv[1:])

def parse_config(path):
    result = {}
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("CONFIG_") and "=" in line:
            key = line.split("=", 1)[0]
            result[key] = line
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            key = line[len("# "):-len(" is not set")]
            result[key] = line
    return result

baseline = parse_config(baseline_path)
final = parse_config(final_path)

changed = sorted(k for k in baseline.keys() & final.keys() if baseline[k] != final[k])
added = sorted(final.keys() - baseline.keys())
removed = sorted(baseline.keys() - final.keys())

out = [
    "# SFT1200 repository.config -> final.config",
    "# 按 CONFIG symbol 比较；忽略文件中的纯排序变化。",
    f"# changed={len(changed)} added={len(added)} removed={len(removed)}",
    "",
]

for key in changed:
    out.extend([f"- {baseline[key]}", f"+ {final[key]}", ""])
for key in added:
    out.extend([f"+ {final[key]}", ""])
for key in removed:
    out.extend([f"- {baseline[key]}", ""])

diff_path.write_text("\n".join(out).rstrip() + "\n")
stats_path.write_text(
    f"CONFIG_CHANGED={len(changed)}\n"
    f"CONFIG_ADDED={len(added)}\n"
    f"CONFIG_REMOVED={len(removed)}\n"
)
PY

final_sha="$(sha256sum "$record_dir/final.config" | awk '{print $1}')"
profile="$(
  sed -n 's/^CONFIG_TARGET_siflower_sf19a28_fullmask_\(.*\)=y$/\1/p' \
    "$record_dir/final.config" |
  head -n1
)"

cat > "$record_dir/build-info.txt" <<EOF
repository=${GITHUB_REPOSITORY:-local}
source_commit=${GITHUB_SHA:-local}
workflow_run=${GITHUB_RUN_NUMBER:-local}
workflow_run_id=${GITHUB_RUN_ID:-local}
workflow_attempt=${GITHUB_RUN_ATTEMPT:-local}
profile=${profile:-unknown}
feed_fingerprint=${FEED_FINGERPRINT:-unknown}
pwpackages_commit=${PWPACKAGES_COMMIT:-unknown}
build_cache_fingerprint=${BUILD_CACHE_FINGERPRINT:-unknown}
final_config_sha256=${final_sha}
EOF

naiveproxy_metadata="$source_root/.sft1200-naiveproxy.env"
if [ -s "$naiveproxy_metadata" ]; then
  cat "$naiveproxy_metadata" >> "$record_dir/build-info.txt"
else
  echo "naiveproxy_metadata=missing" >> "$record_dir/build-info.txt"
fi

upstream_metadata="$source_root/.sft1200-upstreams.env"
if [ -s "$upstream_metadata" ]; then
  cat "$upstream_metadata" >> "$record_dir/build-info.txt"
else
  echo "upstream_metadata=missing" >> "$record_dir/build-info.txt"
fi

echo "generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$record_dir/build-info.txt"

cat > "$record_dir/README.txt" <<'EOF'
SFT1200 构建配置留档

repository.config
  本次构建开始时仓库中的 .config 基线。它代表长期维护意图，不会由 CI 自动回写。

final.config
  diy-part2.sh 与 make defconfig 完成后的真实最终 .config；这是本次固件实际使用的配置。

diffconfig.txt
  OpenWrt scripts/diffconfig.sh 输出，只保留相对默认配置真正有意义的选择。
  人工判断是否需要更新仓库 .config 时，优先查看这个文件。

config-changes.diff
  repository.config 与 final.config 按 CONFIG symbol 比较后的语义差异；忽略纯排序变化。

build-info.txt
  记录源码 commit、Actions run、profile、feeds/build cache 指纹、PWpackages 构建快照、diy-part2 动态上游 commit、最终 .config SHA256，以及 NaiveProxy 实际版本、资产名和经 GitHub Release digest 验证的 SHA256。

  排查“仓库没改但构建/功能突然变化”时，优先比较两次 build-info.txt 中：
    source_commit
    pwpackages_commit
    upstream_golang_commit
    upstream_aliyundrive_webdav_commit
    upstream_lede_commit              # 同时对应当前引入的 ninja / adbyby
    upstream_luci_app_adguardhome_commit
    feed_fingerprint
    naiveproxy_version / naiveproxy_release / naiveproxy_asset / naiveproxy_sha256
    final_config_sha256

  建议判断顺序：
    1. source_commit 是否变化；
    2. PWpackages 和四个 upstream commit 是否变化；
    3. feed_fingerprint / NaiveProxy / final_config_sha256 是否变化；
    4. 都没变化时，再检查 Actions Runner、下载、缓存或工具链环境差异。

  这些 commit 仅用于追溯，不代表长期锁版本；后续构建仍按仓库既定追新策略获取最新上游。

config-stats.env
  配置差异数量，供 CI 汇总使用。

如何把成功构建提升为新的仓库配置基线：
  1. 先查看 config-changes.diff，确认变化是预期的。
  2. 再查看 diffconfig.txt，确认关键功能选择正确。
  3. 确认无误后，才把 final.config 复制为仓库根目录 .config 并提交。
  4. 不要因为 CI 成功就自动回写 .config；上游 Kconfig 的临时默认变化不一定应该永久保留。
EOF

# shellcheck disable=SC1090
source "$record_dir/config-stats.env"

echo "最终 .config SHA256: $final_sha"
echo "配置差异：changed=$CONFIG_CHANGED added=$CONFIG_ADDED removed=$CONFIG_REMOVED"
echo "配置差异前 120 行："
sed -n '1,120p' "$record_dir/config-changes.diff"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### SFT1200 最终配置留档"
    echo
    echo "- 最终配置 SHA256：\`$final_sha\`"
    echo "- 与仓库基线相比：**changed=$CONFIG_CHANGED / added=$CONFIG_ADDED / removed=$CONFIG_REMOVED**"
    echo "- 完整文件见本次运行的 \`OpenWrt_config_record...\` Artifact；Release 也会附带同一组文件。"
    echo
    echo "<details><summary>配置差异前 80 行</summary>"
    echo
    echo '```diff'
    sed -n '1,80p' "$record_dir/config-changes.diff"
    echo '```'
    echo "</details>"
  } >> "$GITHUB_STEP_SUMMARY"
fi
