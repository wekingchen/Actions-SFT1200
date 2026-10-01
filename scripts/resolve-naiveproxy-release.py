#!/usr/bin/env python3
"""Resolve the official GitHub Release digest for the NaiveProxy asset used by SFT1200."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path


DIGEST_RE = re.compile(r"sha256:([0-9a-fA-F]{64})")
VERSION_RE = re.compile(r"^PKG_VERSION:=(\S+)\s*$", re.MULTILINE)
RELEASE_RE = re.compile(r"^PKG_RELEASE:=(\S+)\s*$", re.MULTILINE)
DOWNLOAD_PREFIX = "https://github.com/klzgrad/naiveproxy/releases/download/"


def parse_makefile(path: Path) -> tuple[str, str]:
    text = path.read_text()
    version_match = VERSION_RE.search(text)
    release_match = RELEASE_RE.search(text)
    if not version_match or not release_match:
        raise SystemExit(f"Unable to read NaiveProxy version/release from {path}")
    return version_match.group(1), release_match.group(1)


def fetch_release(tag: str) -> dict:
    url = f"https://api.github.com/repos/klzgrad/naiveproxy/releases/tags/{tag}"
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Actions-SFT1200-naiveproxy-resolver",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"Unable to read NaiveProxy release metadata for {tag}: HTTP {exc.code}"
        ) from exc
    except urllib.error.URLError as exc:
        raise SystemExit(
            f"Unable to read NaiveProxy release metadata for {tag}: {exc.reason}"
        ) from exc


def resolve(makefile: Path, arch: str) -> dict[str, str]:
    version, release = parse_makefile(makefile)
    tag = f"v{version}-{release}"
    asset = f"naiveproxy-{tag}-openwrt-{arch}.tar.xz"
    metadata = fetch_release(tag)
    matches = [item for item in metadata.get("assets", []) if item.get("name") == asset]

    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one NaiveProxy release asset {asset!r}, found {len(matches)}"
        )

    item = matches[0]
    digest = item.get("digest")
    url = item.get("browser_download_url")

    if not isinstance(digest, str):
        raise SystemExit(f"NaiveProxy asset has no GitHub digest: {asset}")

    digest_match = DIGEST_RE.fullmatch(digest)
    if not digest_match:
        raise SystemExit(f"NaiveProxy asset has unusable digest: {digest!r}")

    if not isinstance(url, str) or not url.startswith(DOWNLOAD_PREFIX):
        raise SystemExit(f"Unexpected NaiveProxy asset URL: {url!r}")

    return {
        "version": version,
        "release": release,
        "asset": asset,
        "sha256": digest_match.group(1).lower(),
        "url": url,
    }


def write_github_output(path: Path, values: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        for key, value in values.items():
            print(f"{key}={value}", file=handle)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--makefile", required=True, type=Path)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()

    values = resolve(args.makefile, args.arch)
    print(
        "NaiveProxy metadata resolved: "
        f"version={values['version']} release={values['release']} "
        f"asset={values['asset']} sha256={values['sha256']}"
    )
    if args.github_output:
        write_github_output(args.github_output, values)
    else:
        json.dump(values, sys.stdout, ensure_ascii=False, indent=2)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
