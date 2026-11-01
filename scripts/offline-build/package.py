#!/usr/bin/env python3
"""Assemble the offline format without extracting or rewriting online bundles."""
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

TARGETS = (("debian", "12"), ("debian", "13"), ("ubuntu", "22.04"), ("ubuntu", "24.04"))
COMPONENTS = ("xray", "sing-box", "lego")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_path(name):
    require(bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+%~/-]*", name))
            and all(part not in (".", "..", "") for part in name.split("/")), f"unsafe path: {name}")


def plain_tree(root):
    require(root.is_dir() and not root.is_symlink(), f"not a regular directory: {root}")
    for path in root.rglob("*"):
        safe_path(path.relative_to(root).as_posix())
        require(not path.is_symlink() and (path.is_file() or path.is_dir()), f"non-regular input: {path}")


def online_files(root, version):
    plain_tree(root)
    rows = (root / "vpsctl-manifest.tsv").read_text().splitlines()
    require(rows[:3] == ["schema_version\t2", f"version\t{version}",
                         "repository\tRunarry/vps-script-lite"], "online manifest header/version mismatch")
    files = ["vpsctl-manifest.tsv"]
    ids = set()
    for index, row in enumerate(rows[3:]):
        fields = row.split("\t")
        require(len(fields) == 4, "malformed online asset record")
        kind, identifier, name, digest = fields
        require(identifier not in ids, "duplicate online asset")
        ids.add(identifier)
        if index == 0:
            require((kind, identifier, name) == ("asset", "launcher", "vpsctl.sh"), "online launcher is missing")
        else:
            require(kind == "bundle" and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", identifier)
                    and name == f"vpsctl-{identifier}-{version}.tar.gz", "invalid online bundle filename")
        require(bool(re.fullmatch(r"[0-9a-f]{64}", digest)), "invalid online asset digest")
        require(sha256(root / name) == digest, f"online asset digest mismatch: {name}")
        files.append(name)
    require("core" in ids and "launcher" in ids, "online core/launcher is missing")
    return files


def component_rows(root):
    rows = [line.split("\t") for line in (root / "components.tsv").read_text().splitlines()]
    require(len(rows) == len(COMPONENTS), "snapshot must contain exactly three components")
    require([row[1] for row in rows if len(row) == 7] == list(COMPONENTS), "invalid component record/order")
    for kind, identifier, tag, name, digest, relative, url in rows:
        safe_path(relative)
        require(kind == "component" and re.fullmatch(r"v?\d+\.\d+\.\d+(?:\+[A-Za-z0-9.-]+)?", tag)
                and relative == f"upstream/{identifier}/{name}" and "/" not in name
                and re.fullmatch(r"[0-9a-f]{64}", digest) and url.startswith("https://github.com/"),
                f"invalid component metadata: {identifier}")
        require(sha256(root / relative) == digest, f"component digest mismatch: {identifier}")
    return rows


def package_provenance(root, uri_file, arch):
    uris = {}
    for line in uri_file.read_text().splitlines():
        if not line.startswith("'"):
            continue
        fields = shlex.split(line)
        require(len(fields) >= 3 and fields[0].startswith(("http://", "https://")), "invalid APT download URI")
        require(fields[1] not in uris, "duplicate APT download filename")
        uris[fields[1]] = fields[0]
    records = []
    for paragraph in (root / "apt/Packages").read_text().strip().split("\n\n"):
        fields = dict(line.split(": ", 1) for line in paragraph.splitlines() if line and not line[0].isspace() and ": " in line)
        name = fields["Filename"]
        safe_path(name)
        require(name.startswith("pool/") and name.endswith(".deb"), "invalid APT pool path")
        require(fields["Architecture"] in (arch, "all"), "APT package has the wrong architecture")
        require(sha256(root / "apt" / name) == fields["SHA256"], f"APT package digest mismatch: {name}")
        original = uris.pop(Path(name).name, None)
        require(original is not None, f"APT package has no original download URL: {name}")
        records.append("\t".join((fields["Package"], fields["Version"], fields["Architecture"],
                                   fields["SHA256"], name, original)))
    require(records and not uris, "APT download/index inventory differs")
    (root / "apt/packages.tsv").write_text("package\tversion\tarchitecture\tsha256\tpath\turl\n"
                                            + "\n".join(sorted(records)) + "\n")


def write_readme(root, version, os_name, os_version, arch):
    (root / "README.txt").write_text(f"""vpsctl {version} 离线安装包
目标系统：{os_name} {os_version} / {arch}

请在相同系统、版本和架构的 VPS 上使用；需 root、Bash 4.4+、
apt/dpkg、tar/gzip、sha256sum 和 systemd 基础环境。Alpine 不适用。
解压到空目录后，在此目录的 root shell 中校验并安装：

    sha256sum -c SHA256SUMS
    bash ./vpsctl.sh --offline-dir "$PWD"

已有支持离线选项的管理器可从新包的绝对解压目录更新：

    vpsctl --yes self update --offline-dir /absolute/path/to/new-package

旧入口不认识 --offline-dir 时，使用新包里的 vpsctl.sh 安装器。
同版本导入要求在线清单完全一致；跨版本导入更新全部项目 bundle。
安装完成后资源留存在受管 release 的 .offline/ 中，原解压目录可删除。
依赖按功能需要从包内 APT 仓库安装；非交互调用可使用 --install-deps。
资源缺失或损坏会失败，不会回退联网下载；不带 --offline-dir 的
self update 仍使用原有在线更新流程。

包括：全部项目脚本，以及网络设置、nftables、SSH、Fail2ban、
Xray/sing-box、TCPing/iperf3、lego/TLS、Swap 和清理的依赖资产。
components.tsv 记录本次固定的上游实际版本、原始文件名、来源与摘要；
离线调用只能使用包内版本。apt/packages.tsv 记录系统包来源与摘要。
备份、内核、重装和第三方综合测试虽保留入口，其外部依赖未完整覆盖。

离线安装不取消服务自身的联网要求：ACME 申请/续期、DNS 查询、
NTP 时间同步及实际业务通信仍需相应网络服务。
""", encoding="utf-8")


def prepare(root, online, snapshot, version, os_name, os_version, arch, uris):
    require((os_name, os_version) in TARGETS and arch in ("amd64", "arm64"), "unsupported package target")
    plain_tree(snapshot)
    component_rows(snapshot)
    for name in online_files(online, version):
        shutil.copyfile(online / name, root / name)
    shutil.copyfile(snapshot / "components.tsv", root / "components.tsv")
    shutil.copytree(snapshot / "upstream", root / "upstream")
    package_provenance(root, uris, arch)
    built_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    (root / "offline-manifest.tsv").write_text(
        f"schema_version\t1\nversion\t{version}\nos\t{os_name}\nos_version\t{os_version}\n"
        f"architecture\t{arch}\nbuilt_at\t{built_at}\n")
    (root / "vpsctl.sh").chmod(0o755)
    write_readme(root, version, os_name, os_version, arch)


def smoke(root):
    # Run the actual selected upstream programs inside the target OS/CPU image.
    # A release that requires an unavailable ABI/CPU fails this build, never falls back.
    with tempfile.TemporaryDirectory(prefix="vpsctl-offline-smoke-") as temporary:
        for _, identifier, tag, _, _, relative, _ in component_rows(root):
            source = root / relative
            target = Path(temporary) / identifier
            if identifier == "xray":
                with zipfile.ZipFile(source) as archive:
                    members = [member for member in archive.infolist() if member.filename == "xray" and not member.is_dir()]
                    require(len(members) == 1, "Xray archive has no unique xray binary")
                    with archive.open(members[0]) as stream, target.open("wb") as output:
                        shutil.copyfileobj(stream, output)
            else:
                with tarfile.open(source, "r:gz") as archive:
                    members = [member for member in archive if PurePosixPath(member.name).name == identifier and member.isfile()]
                    require(len(members) == 1, f"{identifier} archive has no unique binary")
                    with archive.extractfile(members[0]) as stream, target.open("wb") as output:
                        shutil.copyfileobj(stream, output)
            target.chmod(0o755)
            argument = "version" if identifier in ("xray", "sing-box") else "--version"
            result = subprocess.run([str(target), argument], check=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, timeout=30)
            version = tag.removeprefix("v")
            require(bool(re.search(r"(?<![0-9.])" + re.escape(version) + r"(?![0-9.])", result.stdout)),
                    f"{identifier}: binary version does not match selected release {tag}")
            if identifier in ("xray", "sing-box"):
                config = Path(temporary) / "config.json"
                outbound = {"tag": "direct", "protocol": "freedom"} if identifier == "xray" else {"tag": "direct", "type": "direct"}
                config.write_text(json.dumps({"inbounds": [], "outbounds": [outbound]}))
                command = ["run", "-test", "-config"] if identifier == "xray" else ["check", "-c"]
                subprocess.run([str(target), *command, str(config)], check=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=30)
            print(f"{identifier}: {tag} executes on the selected OS/architecture", flush=True)


def finalize(root, output, version, os_name, os_version, arch):
    plain_tree(root)
    files = sorted(path for path in root.rglob("*") if path.is_file() and path != root / "SHA256SUMS")
    (root / "SHA256SUMS").write_text("".join(f"{sha256(path)}  {path.relative_to(root).as_posix()}\n" for path in files))
    filename = f"vpsctl-offline-{version}-{os_name}-{os_version}-{arch}.tar.gz"
    temporary = output / (filename + ".partial")
    try:
        with temporary.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|") as archive:
                for path in sorted(root.rglob("*")):
                    relative = path.relative_to(root).as_posix()
                    info = archive.gettarinfo(str(path), arcname=relative)
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ""
                    info.mode = 0o755 if path.is_dir() or relative == "vpsctl.sh" else 0o644
                    if path.is_file():
                        with path.open("rb") as stream:
                            archive.addfile(info, stream)
                    else:
                        archive.addfile(info)
        temporary.replace(output / filename)
    finally:
        temporary.unlink(missing_ok=True)


def aggregate(output, version):
    expected = sorted(f"vpsctl-offline-{version}-{os_name}-{os_version}-{arch}.tar.gz"
                      for os_name, os_version in TARGETS for arch in ("amd64", "arm64"))
    actual = sorted(path.name for path in output.glob("vpsctl-offline-*.tar.gz"))
    require(actual == expected, "aggregation requires exactly all eight current-version offline packages")
    online_manifest = None
    tags = None
    components_by_arch = {}
    for name in expected:
        path = output / name
        require(path.is_file() and not path.is_symlink(), f"unsafe release artifact: {name}")
        target = name.removeprefix(f"vpsctl-offline-{version}-").removesuffix(".tar.gz").split("-")
        os_name, os_version, arch = target
        with tarfile.open(path, "r:gz") as archive:
            def read_regular(member_name):
                members = [member for member in archive.getmembers() if member.name == member_name]
                require(len(members) == 1 and members[0].isfile(), f"{name}: missing/duplicate {member_name}")
                require(members[0].size <= 1024 * 1024, f"{name}: oversized {member_name}")
                return archive.extractfile(members[0]).read()
            metadata = read_regular("offline-manifest.tsv").decode().splitlines()
            require(len(metadata) == 6 and metadata[:5] == ["schema_version\t1", f"version\t{version}",
                    f"os\t{os_name}", f"os_version\t{os_version}", f"architecture\t{arch}"]
                    and re.fullmatch(r"built_at\t\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", metadata[5]),
                    f"{name}: archive target metadata does not match filename")
            current_online = read_regular("vpsctl-manifest.tsv")
            require(online_manifest is None or current_online == online_manifest, "matrix contains different online releases")
            online_manifest = current_online
            current_components = read_regular("components.tsv")
            rows = [line.split("\t") for line in current_components.decode().splitlines()]
            require(len(rows) == len(COMPONENTS) and [row[1] for row in rows if len(row) == 7] == list(COMPONENTS),
                    f"{name}: invalid component manifest")
            current_tags = [(row[1], row[2]) for row in rows]
            require(tags is None or current_tags == tags, "matrix contains different upstream release tags")
            tags = current_tags
            require(arch not in components_by_arch or components_by_arch[arch] == current_components,
                    f"matrix contains different {arch} upstream snapshots")
            components_by_arch[arch] = current_components
    temporary = output / ".vpsctl-offline-SHA256SUMS.partial"
    try:
        temporary.write_text("".join(f"{sha256(output / name)}  {name}\n" for name in expected))
        temporary.replace(output / "vpsctl-offline-SHA256SUMS")
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        action, *args = sys.argv[1:]
        if action == "online" and len(args) == 2:
            online_files(Path(args[0]), args[1])
        elif action == "prepare" and len(args) == 8:
            prepare(*[Path(arg) if index in (0, 1, 2, 7) else arg for index, arg in enumerate(args)])
        elif action == "smoke" and len(args) == 1:
            smoke(Path(args[0]))
        elif action == "readme" and len(args) == 5:
            write_readme(Path(args[0]), *args[1:])
        elif action == "finalize" and len(args) == 6:
            finalize(Path(args[0]), Path(args[1]), *args[2:])
        elif action == "aggregate" and len(args) == 2:
            aggregate(Path(args[0]), args[1])
        else:
            raise ValueError("invalid package helper arguments")
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, zipfile.BadZipFile,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"offline package: {error}", file=sys.stderr)
        sys.exit(1)
