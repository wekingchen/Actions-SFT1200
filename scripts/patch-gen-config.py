#!/usr/bin/env python3
"""Patch upstream scripts/gen_config.py for the SFT1200/OpenWrt 18.06 build.

The upstream generator installs feeds inside setup_feeds(profile) and only then
calls generate_config(profile). These compatibility removals therefore must run
between those two calls; doing them in the workflow before gen_config.py starts
would be too early because package/feeds and feeds are not populated yet.
"""

from pathlib import Path

TARGET = Path("scripts/gen_config.py")
MARKER = "Compatibility hook for GL-SFT1200"
NEEDLE = "    generate_config(profile)\n"

HOOK = r'''    # Compatibility hook for GL-SFT1200 / Siflower OpenWrt 18.06.
    call('find package/feeds feeds -path "*dnsmasq/Makefile" -type f -print0 2>/dev/null | xargs -0 -r sed -i "s/+PACKAGE_dnsmasq_full_nftset:nftables-json//g"', shell=True)
    call('find package/feeds feeds -maxdepth 5 -type d -name "samba4" -prune -exec rm -rf {} + 2>/dev/null || true', shell=True)
    call('find package/feeds feeds -maxdepth 5 -type d \\( '
    '-name "python3-cryptodome" -o '
    '-name "python3-influxdb" -o '
    '-name "python3-requests" -o '
    '-name "python3-aiohttp" -o '
    '-name "python3-aiohttp-cors" -o '
    '-name "python3-attrs" -o '
    '-name "python3-sentry-sdk" -o '
    '-name "python3-certifi" -o '
    '-name "python3-dateutil" -o '
    '-name "python3-dns" -o '
    '-name "python3-idna" -o '
    '-name "python3-yarl" -o '
    '-name "python3-pytz" -o '
    '-name "python3-six" -o '
    '-name "python3-jsonpath-ng" -o '
    '-name "python3-ply" '
    '\\) -prune -exec rm -rf {} + 2>/dev/null || true', shell=True)
    generate_config(profile)
'''


def main() -> None:
    if not TARGET.is_file():
        raise SystemExit(f"gen_config.py not found: {TARGET}")

    text = TARGET.read_text()

    if MARKER in text:
        print("scripts/gen_config.py already patched")
        return

    if NEEDLE not in text:
        raise SystemExit(
            "generate_config(profile) not found in scripts/gen_config.py; "
            "upstream layout may have changed"
        )

    TARGET.write_text(text.replace(NEEDLE, HOOK, 1))
    print("Patched scripts/gen_config.py for SFT1200/OpenWrt 18.06")


if __name__ == "__main__":
    main()
