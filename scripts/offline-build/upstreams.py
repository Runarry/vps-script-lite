#!/usr/bin/env python3
"""Resolve one immutable, verified amd64/arm64 snapshot of current stable releases."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote

REPOSITORIES = {
    "xray": "XTLS/Xray-core",
    "sing-box": "SagerNet/sing-box",
    "lego": "go-acme/lego",
}


def fail(message):
    raise ValueError(message)


def download(url, destination, api=False):
    args = ["curl", "--fail", "--silent", "--show-error", "--location",
            "--proto", "=https", "--proto-redir", "=https", "--retry", "3",
            "--connect-timeout", "20", "--max-time", "600",
            "--header", "User-Agent: vpsctl-offline-build"]
    if api:
        args += ["--header", "Accept: application/vnd.github+json"]
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if token:
            args += ["--header", "Authorization: Bearer " + token]
    result = subprocess.run(args + ["--output", str(destination), url])
    if result.returncode:
        # Do not echo curl's argument vector: API headers may contain GH_TOKEN.
        fail(f"download failed (curl exit {result.returncode}): {url}")


def asset_name(component, tag, arch):
    version = tag.removeprefix("v")
    if component == "xray":
        return "Xray-linux-64.zip" if arch == "amd64" else "Xray-linux-arm64-v8a.zip"
    if component == "sing-box":
        return f"sing-box-{version}-linux-{arch}.tar.gz"
    if component == "lego":
        return f"lego_{version}_linux_{arch}.tar.gz"
    fail(f"unsupported upstream component: {component}")


def release_asset(release, repo, tag, name):
    matches = [asset for asset in release["assets"] if asset.get("name") == name]
    if len(matches) != 1:
        fail(f"{repo} {tag}: required asset missing or ambiguous: {name}")
    asset = matches[0]
    expected = f"https://github.com/{repo}/releases/download/{quote(tag, safe='')}/{quote(name, safe='')}"
    if asset.get("browser_download_url") != expected:
        fail(f"{repo} {tag}: unexpected original asset URL: {name}")
    return asset


def checksum(contents, name, dgst=False):
    matches = []
    for line in contents.splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?" + re.escape(name), line.strip())
        if dgst and not match:
            match = re.fullmatch(r"SHA2?-256\s*=\s*([0-9a-fA-F]{64})", line.strip())
        if match:
            matches.append(match[1].lower())
    if len(matches) != 1:
        fail(f"missing or ambiguous SHA256 checksum for {name}")
    return matches[0]


def resolve(destination):
    if destination.exists() or destination.is_symlink():
        fail(f"snapshot destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".vpsctl-upstreams-", dir=destination.parent) as temporary:
        work = Path(temporary)
        root = work / "snapshot"
        manifests = {arch: [] for arch in ("amd64", "arm64")}
        for component, repo in REPOSITORIES.items():
            release_file = work / f"{component}-release.json"
            # Exactly one latest lookup per component, shared by both architectures.
            download(f"https://api.github.com/repos/{repo}/releases/latest", release_file, api=True)
            release = json.loads(release_file.read_text())
            tag = release.get("tag_name", "")
            if (release.get("draft") is not False or release.get("prerelease") is not False
                    or not re.fullmatch(r"v?\d+\.\d+\.\d+(?:\+[A-Za-z0-9.-]+)?", tag)
                    or not isinstance(release.get("assets"), list)):
                fail(f"{repo}: latest response is not a stable versioned release")
            cached_checksums = {}
            for arch in manifests:
                name = asset_name(component, tag, arch)
                if component == "lego":
                    candidates = {name, f"lego_{tag}_linux_{arch}.tar.gz"}
                    available = [item["name"] for item in release["assets"] if item.get("name") in candidates]
                    if len(available) != 1:
                        fail(f"{repo} {tag}: required {arch} asset missing or ambiguous")
                    name = available[0]
                asset = release_asset(release, repo, tag, name)
                directory = root / arch / "upstream" / component
                directory.mkdir(parents=True)
                shutil.copyfile(release_file, directory / "release.json")
                digest = asset.get("digest")
                if digest is not None and digest != "":
                    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
                        fail(f"{repo} {tag}: invalid asset SHA256 digest: {name}")
                    expected = digest.split(":")[1].lower()
                else:
                    if component == "lego":
                        candidates = {f"lego_{tag}_checksums.txt", f"lego_{tag.removeprefix('v')}_checksums.txt"}
                        available = [item["name"] for item in release["assets"] if item.get("name") in candidates]
                        if len(available) != 1:
                            fail(f"{repo} {tag}: missing or ambiguous checksum asset")
                        checksum_name = available[0]
                    else:
                        checksum_name = name + ".dgst" if component == "xray" else "checksums.txt"
                    if checksum_name not in cached_checksums:
                        checksum_asset = release_asset(release, repo, tag, checksum_name)
                        checksum_file = work / f"{component}-{checksum_name}"
                        download(checksum_asset["browser_download_url"], checksum_file)
                        cached_checksums[checksum_name] = checksum_file
                    checksum_file = cached_checksums[checksum_name]
                    expected = checksum(checksum_file.read_text(), name, component == "xray")
                    shutil.copyfile(checksum_file, directory / checksum_name)
                download(asset["browser_download_url"], directory / name)
                actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
                if actual != expected:
                    fail(f"{repo} {tag}: SHA256 mismatch: {name}")
                manifests[arch].append("\t".join(("component", component, tag, name, actual,
                                                    f"upstream/{component}/{name}", asset["browser_download_url"])))
            print(f"{component}: {tag} (amd64, arm64 verified)", flush=True)
        for arch, rows in manifests.items():
            (root / arch / "components.tsv").write_text("\n".join(rows) + "\n")
        root.rename(destination)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            fail("usage: upstreams.py SNAPSHOT_DIR")
        resolve(Path(sys.argv[1]).absolute())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"resolve-offline-upstreams: {error}", file=sys.stderr)
        sys.exit(1)
