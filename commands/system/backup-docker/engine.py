#!/usr/bin/env python3
"""Private Docker capture/restore implementation. No third-party Python modules."""
import argparse
import copy
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import time
from urllib.parse import quote


class Failure(Exception):
    def __init__(self, message, code=3):
        super().__init__(message)
        self.code = code


def run(argv, *, data=None, output=None, timeout=None, check=True):
    result = subprocess.run(argv, input=data, stdout=output or subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode:
        # Docker exec may print credentials or application data: do not echo argv/stdout.
        raise Failure(f"{argv[0]} {argv[1] if len(argv) > 1 else ''} 失败: "
                      + result.stderr.decode(errors="replace")[-2000:], 20)
    return result


def docker(*args, **kwargs):
    return run(["docker", *args], **kwargs)


def dj(*args):
    return json.loads(docker(*args).stdout)


def write_json(path, value):
    import tempfile
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, filename = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(filename)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def path_key(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24]


def contains(root, value):
    return value == root or value.startswith(root.rstrip("/") + "/")


def safe_path(value):
    path = Path(value)
    if (not path.is_absolute() or ".." in path.parts or any(ord(char) < 32 for char in value) or
            str(path) in ("/", "/root", "/home", "/etc", "/usr", "/var")):
        raise Failure(f"目标路径过宽或非绝对路径: {value}", 2)
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise Failure(f"路径包含符号链接: {part}")
    return path


CONFIG_FIELDS = set("Hostname Domainname User AttachStdin AttachStdout AttachStderr ExposedPorts Tty OpenStdin StdinOnce Env Cmd Healthcheck ArgsEscaped Image Volumes WorkingDir Entrypoint NetworkDisabled MacAddress OnBuild Labels StopSignal StopTimeout Shell".split())
HOST_FIELDS = set("Binds ContainerIDFile LogConfig NetworkMode PortBindings RestartPolicy AutoRemove VolumeDriver VolumesFrom ConsoleSize Annotations CapAdd CapDrop CgroupnsMode Dns DnsOptions DnsSearch ExtraHosts GroupAdd IpcMode Cgroup Links OomScoreAdj PidMode Privileged PublishAllPorts ReadonlyRootfs SecurityOpt StorageOpt Tmpfs UTSMode UsernsMode ShmSize Sysctls Runtime Isolation CpuShares Memory NanoCpus CgroupParent BlkioWeight BlkioWeightDevice BlkioDeviceReadBps BlkioDeviceWriteBps BlkioDeviceReadIOps BlkioDeviceWriteIOps CpuPeriod CpuQuota CpuRealtimePeriod CpuRealtimeRuntime CpusetCpus CpusetMems Devices DeviceCgroupRules DeviceRequests MemoryReservation MemorySwap MemorySwappiness OomKillDisable PidsLimit Ulimits CpuCount CpuPercent IOMaximumIOps IOMaximumBandwidth MaskedPaths ReadonlyPaths Init Mounts KernelMemory KernelMemoryTCP".split())


def unknown_fields(container):
    missing = []
    for key, allowed in (("Config", CONFIG_FIELDS), ("HostConfig", HOST_FIELDS)):
        for field, value in (container.get(key) or {}).items():
            if field not in allowed and value not in (None, False, "", 0, [], {}):
                missing.append(f"{key}.{field}")
    return missing


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=120)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


class Engine:
    def __init__(self):
        context = dj("context", "inspect")[0]
        endpoint = os.environ.get("DOCKER_HOST") or context["Endpoints"]["docker"]["Host"]
        if not endpoint.startswith("unix://"):
            raise Failure("远端 Docker context/TCP daemon 需要专项适配；本入口只访问本地 unix socket")
        self.endpoint = endpoint[7:]
        self.info = dj("info", "--format", "{{json .}}")
        self.version = dj("version", "--format", "{{json .Server}}")
        self.api_version = self.version["ApiVersion"]

    def api(self, method, path, value=None):
        connection = UnixConnection(self.endpoint)
        body = None if value is None else json.dumps(value).encode()
        connection.request(method, "/v" + self.api_version + path, body,
                           {"Content-Type": "application/json"})
        response = connection.getresponse()
        raw = response.read()
        connection.close()
        result = json.loads(raw) if raw else {}
        if response.status >= 400:
            raise Failure(f"Docker API {method} {path.split('?')[0]}: {result.get('message', response.status)}", 20)
        return result

    def capabilities(self):
        gaps = []
        security = " ".join(self.info.get("SecurityOptions", []))
        if "rootless" in security or "userns" in security:
            gaps.append("rootless/userns-remap 的 UID/GID 映射尚未适配")
        if self.info.get("OSType") != "linux":
            gaps.append("仅支持 Linux Docker Engine")
        if self.info.get("Swarm", {}).get("LocalNodeState") == "active":
            gaps.append("Swarm 需要 secret/config/service 专项适配")
        daemons = []
        for proc in Path("/proc").glob("[0-9]*/comm"):
            try:
                if proc.read_text().strip() == "dockerd":
                    daemons.append(str(proc.parent.name))
            except OSError:
                pass
        if len(daemons) > 1:
            gaps.append("检测到多个 Docker daemon；跨 daemon 共享写入者需要专项协调")
        return gaps


def inspect_all():
    ids = docker("ps", "-aq", "--no-trunc").stdout.decode().split()
    return dj("inspect", *ids) if ids else []


def select_containers(containers, options):
    names, projects, labels = (options.get(k, []) for k in ("containers", "projects", "labels"))
    def selected(c):
        attrs = c["Config"].get("Labels") or {}
        return ((not names and not projects and not labels) or
                c["Id"] in names or c["Name"].lstrip("/") in names or
                attrs.get("com.docker.compose.project") in projects or
                any((attrs.get(x.split("=", 1)[0]) == x.split("=", 1)[1] if "=" in x
                     else x in attrs) for x in labels))
    chosen = [c for c in containers if selected(c)]
    for name in names:
        if not any(name in (c["Id"], c["Name"].lstrip("/")) for c in chosen):
            raise Failure(f"找不到指定容器: {name}", 10)
    return chosen


def mount_source(mount):
    return ("volume", mount["Name"]) if mount["Type"] == "volume" else (mount["Type"], mount.get("Source", ""))


def mounted_filesystems():
    mounts = []
    with open("/proc/self/mountinfo", encoding="utf-8") as stream:
        for line in stream:
            fields = line.split()
            split = fields.index("-")
            path = re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), fields[4])
            mounts.append((path, fields[split + 1]))
    return mounts


def dependency_reason(source):
    if any(contains(root, source) for root in ("/proc", "/sys", "/dev", "/run", "/var/run")):
        return "运行时/设备/伪文件系统依赖"
    candidates = [(path, kind) for path, kind in mounted_filesystems() if contains(path, source)]
    if candidates:
        kind = max(candidates, key=lambda item: len(item[0]))[1]
        if kind in ("proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "mqueue", "securityfs", "debugfs", "tracefs"):
            return "运行时伪文件系统依赖: " + kind
    try:
        mode = os.stat(source).st_mode
        import stat
        if stat.S_ISSOCK(mode) or stat.S_ISBLK(mode) or stat.S_ISCHR(mode) or stat.S_ISFIFO(mode):
            return "socket/设备/FIFO 目标依赖"
    except OSError as error:
        raise Failure(f"持久化源无法读取: {source}: {error}") from error
    return ""


def dependencies(container):
    result = []
    hc = container["HostConfig"]
    for key in ("NetworkMode", "PidMode", "IpcMode"):
        if (hc.get(key) or "").startswith("container:"):
            result.append(hc[key].split(":", 1)[1])
    for value in hc.get("VolumesFrom") or []:
        result.append(value.split(":", 1)[0])
    for value in hc.get("Links") or []:
        result.append(value.split(":", 1)[0].lstrip("/"))
    return result


def ordered(containers):
    pending = list(containers)
    result = []
    identities = {x for c in containers for x in (c["Id"], c["Name"].lstrip("/"))}
    while pending:
        done = {x for c in result for x in (c["Id"], c["Name"].lstrip("/"))}
        def compose_dependencies(c):
            labels = c["Config"].get("Labels") or {}
            project = labels.get("com.docker.compose.project")
            services = [value.split(":")[0] for value in labels.get("com.docker.compose.depends_on", "").split(",") if value]
            return [other["Id"] for other in containers if project and
                    (other["Config"].get("Labels") or {}).get("com.docker.compose.project") == project and
                    (other["Config"].get("Labels") or {}).get("com.docker.compose.service") in services]
        ready = [c for c in pending if all(d not in identities or d in done for d in dependencies(c) + compose_dependencies(c))]
        if not ready:
            raise Failure("容器存在循环启动依赖，需要调整计划", 10)
        for c in ready:
            result.append(c)
            pending.remove(c)
    return result


def inventory(engine, plan):
    options = plan.get("options", {})
    all_containers = inspect_all()
    containers = select_containers(all_containers, options)
    if containers:
        sizes = {c["Id"]: c.get("SizeRw", 0) for c in dj("inspect", "--size", *(c["Id"] for c in containers))}
        for c in containers:
            c["SizeRw"] = sizes[c["Id"]]
    resources, gaps = {}, engine.capabilities()
    selected_ids = {c["Id"] for c in containers}
    identities = {x for c in containers for x in (c["Id"], c["Name"].lstrip("/"))}
    for c in containers:
        name = c["Name"].lstrip("/")
        gaps += [f"{name}: 未支持创建字段 {f}" for f in unknown_fields(c)]
        if c["State"].get("Paused") or c["State"].get("Restarting"):
            gaps.append(f"{name}: paused/restarting 状态不能建立正常停止恢复点")
        if c["HostConfig"].get("AutoRemove") and c["State"]["Running"] and options.get("consistency", "stop") == "stop":
            gaps.append(f"{name}: 正在运行的 --rm 容器停止后会自动删除，需要在线适配或先重新部署为持久容器")
        for dep in dependencies(c):
            if dep not in identities:
                gaps.append(f"{name}: 所选范围遗漏容器依赖 {dep}")
        for m in c.get("Mounts", []):
            kind, source = mount_source(m)
            if kind == "tmpfs":
                continue
            if kind not in ("volume", "bind"):
                gaps.append(f"{name}: 未适配挂载类型 {kind}")
                continue
            key = path_key(kind + ":" + source)
            resource = resources.setdefault(key, {"key": key, "type": kind, "source": source,
                                                  "containers": [], "archive": f"data/{key}.tar"})
            resource["containers"].append(c["Id"])
            if kind == "bind":
                resource["dependency"] = dependency_reason(source)
                resource["directory"] = os.path.isdir(source)
                if os.path.realpath(source) != os.path.normpath(source):
                    gaps.append(f"Bind 源包含符号链接，需改用实际源路径以完整归档: {source}")
                parents = [(path, fs) for path, fs in mounted_filesystems() if contains(path, source)]
                children = [(path, fs) for path, fs in mounted_filesystems() if contains(source, path)]
                relevant = children + ([max(parents, key=lambda pair: len(pair[0]))] if parents else [])
                for path, fs in relevant:
                    if fs in ("nfs", "nfs4", "cifs", "smb3", "ceph", "9p", "fuse.sshfs", "fuse.rclone", "glusterfs"):
                        gaps.append(f"Bind {source} 包含外部文件系统 {fs} ({path})，外部写入协调需要专项适配")
                if set((m.get("Mode") or "").split(",")) & {"z", "Z"}:
                    gaps.append(f"{name}: SELinux relabel bind {source} 需目标标签适配")
            else:
                resource["definition"] = dj("volume", "inspect", source)[0]
                definition = resource["definition"]
                if definition["Driver"] != "local" or definition.get("Options"):
                    gaps.append(f"卷 {source}: 外部驱动/NFS/CIFS/自定义 local 选项需专项适配")
    if options.get("include_orphan_volumes"):
        for name in docker("volume", "ls", "-q").stdout.decode().splitlines():
            key = path_key("volume:" + name)
            if key not in resources:
                definition = dj("volume", "inspect", name)[0]
                if definition["Driver"] != "local" or definition.get("Options"):
                    gaps.append(f"孤立卷 {name}: 外部存储未适配")
                resources[key] = {"key": key, "type": "volume", "source": name,
                                  "containers": [], "definition": definition, "archive": f"data/{key}.tar"}
    writers = []
    sources = [r for r in resources.values() if not r.get("dependency")]
    for c in all_containers:
        shares = any((m["Type"] == r["type"] and
                      ((m.get("Name") == r["source"]) if r["type"] == "volume" else
                       (contains(m.get("Source", ""), r["source"]) or contains(r["source"], m.get("Source", "")))))
                     for m in c.get("Mounts", []) for r in sources)
        if c["State"]["Running"] and (c["Id"] in selected_ids or shares):
            writers.append(c)
            if c["HostConfig"].get("AutoRemove") and options.get("consistency", "stop") == "stop":
                gaps.append(f"共享写入者 {c['Name']} 使用 --rm，不能正常停止后保留原容器")
    networks = {}
    for c in containers:
        for name in c.get("NetworkSettings", {}).get("Networks", {}):
            if name not in networks:
                network = dj("network", "inspect", name)[0]
                networks[name] = network
                if network["Driver"] not in ("bridge", "host", "null") or network.get("Scope") != "local":
                    gaps.append(f"网络 {name}: {network['Driver']}/{network.get('Scope')} 需专项适配")
    image_ids = {c["Image"] for c in containers}
    if options.get("include_unused_images"):
        image_ids.update(docker("image", "ls", "-aq", "--no-trunc").stdout.decode().split())
    images = dj("image", "inspect", *sorted(image_ids)) if image_ids else []
    estimated = sum(image.get("Size", 0) for image in images) * 2 + sum(c.get("SizeRw", 0) for c in containers) * 2
    estimation_missing = []
    for resource in resources.values():
        if resource.get("dependency"):
            continue
        path = resource["source"] if resource["type"] == "bind" else resource["definition"].get("Mountpoint", "")
        size = run(["du", "--summarize", "--block-size=1", "--", path], check=False)
        if size.returncode:
            estimation_missing.append(path)
        else:
            estimated += int(size.stdout.split()[0])
    bind_sources = [r["source"] for r in sources if r["type"] == "bind"]
    for resource in sources:
        source = resource["source"] if resource["type"] == "bind" else resource["definition"]["Mountpoint"]
        details = os.stat(source)
        resource["source_identity"] = [details.st_dev, details.st_ino]
    work = os.path.realpath(plan.get("work_dir", "/var/lib/vpsctl/backup/staging"))
    for source in bind_sources:
        if contains(os.path.realpath(source), work):
            gaps.append(f"暂存目录位于备份源内，产生递归归档: {source}")
    return {"schema_version": 1, "engine_id": engine.info.get("ID"), "architecture": engine.info.get("Architecture"),
            "server_version": engine.info.get("ServerVersion"), "data_root": engine.info.get("DockerRootDir"),
            "containers": containers, "writers": ordered(writers), "resources": list(resources.values()),
            "networks": list(networks.values()), "images": images, "gaps": gaps,
            "estimated_staging_bytes": int(estimated * 1.2) + 64 * 1024 * 1024,
            "space_estimation_unavailable": estimation_missing,
            "all_container_ids": sorted(c["Id"] for c in all_containers),
            "coverage": {"tmpfs_and_process_memory": "excluded", "host_writers": options.get("host_services", []),
                         "external_writers_acknowledged": options.get("host_writers_ack", False)},
            "support": "prerequisites-only; real acceptance is environment-specific"}


def public_inventory(inv):
    return {**{k: inv[k] for k in ("schema_version", "engine_id", "architecture", "server_version", "data_root", "gaps", "coverage", "support", "estimated_staging_bytes", "space_estimation_unavailable")},
            "containers": [{"name": c["Name"].lstrip("/"), "id": c["Id"], "running": c["State"]["Running"],
                            "image": c["Image"], "compose_project": (c["Config"].get("Labels") or {}).get("com.docker.compose.project")}
                           for c in inv["containers"]],
            "stop_scope": [c["Name"].lstrip("/") for c in inv["writers"]],
            "resources": [{k: r[k] for k in ("type", "source", "dependency") if k in r} for r in inv["resources"]]}


def verify_tar():
    if b"GNU tar" not in run(["tar", "--version"]).stdout:
        raise Failure("归档需要 GNU tar（ACL/xattr/稀疏文件/数字 UID/GID）")


TAR_CREATE = ["tar", "--create", "--file=-", "--numeric-owner", "--acls", "--xattrs", "--xattrs-include=*", "--sparse"]
TAR_EXTRACT = ["tar", "--extract", "--file=-", "--numeric-owner", "--same-owner", "--same-permissions", "--acls", "--xattrs", "--xattrs-include=*", "--sparse"]


def helper_image(options, install=False):
    reference = options.get("helper_image", "debian:bookworm-slim")
    result = docker("image", "inspect", reference, check=False)
    if result.returncode:
        if not install:
            raise Failure(f"缺少归档辅助镜像 {reference}；使用 --install-deps 允许拉取")
        docker("pull", reference)
        result = docker("image", "inspect", reference)
    image = json.loads(result.stdout)[0]["Id"]
    test = docker("run", "--rm", "--network", "none", "--read-only", "--entrypoint", "tar", image, "--help").stdout
    if not all(x in test for x in (b"--acls", b"--xattrs", b"--sparse", b"--numeric-owner")):
        raise Failure("辅助镜像 tar 不支持所需元数据能力")
    return image


def commit_image(container_id):
    # Commit pauses running containers by default. Docker 29 deprecates --pause
    # and can put its warning on stdout beside the image ID.
    output = docker("commit", container_id).stdout.decode()
    ids = re.findall(r"^sha256:[a-f0-9]{64}$", output, re.M)
    if len(ids) != 1:
        raise Failure("docker commit 未返回唯一镜像 ID", 20)
    return ids[0]


def volume_archive(resource, image, path, extract=False, metadata_only=False):
    flags = TAR_EXTRACT if extract else TAR_CREATE
    mount = f"type=volume,src={resource['source']},dst=/data,volume-nocopy" + ("" if extract else ",readonly")
    # SYS_ADMIN is needed for trusted.* xattrs. This fixed helper sees only the
    # selected volume and has neither the Docker socket nor host directories.
    args = ["run", "--rm", "-i", "--network", "none", "--read-only", "--cap-add", "SYS_ADMIN", "--user", "0:0", "--mount", mount,
            "--entrypoint", "tar", image, *flags[1:], "--directory=/data"]
    if not extract:
        if metadata_only:
            args.append("--no-recursion")
        args.append(".")
    with open(path, "rb" if extract else "wb") as stream:
        if extract:
            result = subprocess.run(["docker", *args], stdin=stream, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise Failure("卷恢复失败: " + result.stderr.decode(errors="replace"), 20)
        else:
            docker(*args, output=stream)


def host_writers(resources):
    sources = [r["source"] if r["type"] == "bind" else r["definition"]["Mountpoint"]
               for r in resources if not r.get("dependency")]
    result = []
    for proc in Path("/proc").glob("[0-9]*"):
        if proc.name == str(os.getpid()):
            continue
        try:
            for fd in (proc / "fd").iterdir():
                target = os.readlink(fd).removesuffix(" (deleted)")
                if not any(contains(source, target) for source in sources):
                    continue
                info = (proc / "fdinfo" / fd.name).read_text()
                flags = re.search(r"^flags:\s+([0-7]+)$", info, re.M)
                if flags and int(flags[1], 8) & 3:
                    result.append({"pid": proc.name, "path": target})
            # Writable mappings remain writers even after their file descriptor is closed.
            for line in (proc / "maps").read_text().splitlines():
                fields = line.split(None, 5)
                if len(fields) == 6 and "w" in fields[1] and any(contains(source, fields[5]) for source in sources):
                    result.append({"pid": proc.name, "path": fields[5]})
        except (OSError, ProcessLookupError):
            pass
    return result


def restore_running(journal_path):
    journal = read_json(journal_path)
    failures = []
    if journal.get("post_hook"):
        try:
            result = run([journal["post_hook"]], timeout=journal.get("stop_timeout", 120), check=False)
        except (OSError, subprocess.TimeoutExpired):
            failures.append("post_hook:" + journal["post_hook"])
        else:
            if result.returncode:
                failures.append("post_hook:" + journal["post_hook"])
    # Starting a stopped original writer is idempotent; the journal is written before stop.
    for unit in journal.get("services", []):
        if run(["systemctl", "start", unit], check=False).returncode:
            failures.append("service:" + unit)
    for cid in journal.get("containers", []):
        if docker("start", cid, check=False).returncode:
            failures.append("container:" + cid)
    journal["resume_failures"] = failures
    journal["resumed"] = not failures
    write_json(journal_path, journal)
    if failures:
        raise Failure("恢复原运行状态失败，请执行 recover-interrupted: " + ", ".join(failures), 30)


def stop_writers(inv, options, journal_path):
    journal = {"schema_version": 1, "engine_id": inv["engine_id"], "containers": [], "services": [], "resumed": False}
    write_json(journal_path, journal)
    for unit in options.get("host_services", []):
        if not re.fullmatch(r"[A-Za-z0-9_.@:-]+\.service", unit):
            raise Failure(f"无效宿主机 service: {unit}", 10)
        if run(["systemctl", "is-active", "--quiet", unit], check=False).returncode == 0:
            journal["services"].append(unit)
            write_json(journal_path, journal)
            run(["systemctl", "stop", unit], timeout=options.get("stop_timeout", 120))
            state = run(["systemctl", "show", "--property=Result,ActiveState,ExecMainCode,ExecMainStatus", unit]).stdout.decode()
            properties = dict(line.split("=", 1) for line in state.splitlines() if "=" in line)
            if (properties.get("Result") != "success" or properties.get("ActiveState") != "inactive" or
                    (properties.get("ExecMainCode") in ("2", "3") and properties.get("ExecMainStatus") == "9")):
                raise Failure(f"{unit}: 停止结果非正常退出，拒绝应用一致备份: {properties}")
    for c in reversed(inv["writers"]):
        command = " ".join(c["Config"].get("Cmd") or []) + " " + c["Config"].get("Image", "")
        if "redis" in command.lower():
            result = docker("exec", c["Id"], "redis-cli", "SAVE")
            if result.stdout.strip() != b"OK":
                raise Failure(f"{c['Name']}: Redis 原生持久化失败；需配置可用认证/专用适配器")
        journal["containers"].insert(0, c["Id"])
        write_json(journal_path, journal)
        docker("stop", "--time", "-1", c["Id"], timeout=options.get("stop_timeout", 120))
        state = dj("inspect", c["Id"])[0]["State"]
        if state["Running"] or state.get("OOMKilled") or state.get("ExitCode") == 137:
            raise Failure(f"{c['Name']}: 未正常停止，拒绝采集应用一致备份")
    active = host_writers(inv["resources"])
    if active:
        raise Failure("数据仍有宿主机写入者，请声明并停止对应服务: " + json.dumps(active, ensure_ascii=False))


def save_compose(inv, payload):
    entries = []
    paths = set()
    for c in inv["containers"]:
        labels = c["Config"].get("Labels") or {}
        if not labels.get("com.docker.compose.project"):
            continue
        work = labels.get("com.docker.compose.project.working_dir", "")
        files = labels.get("com.docker.compose.project.config_files", "").split(",")
        env_files = labels.get("com.docker.compose.project.environment_file", "").split(",")
        entry = {"container": c["Id"], "project": labels["com.docker.compose.project"], "working_dir": work,
                 "files": [], "missing": [], "reconstruction": "explicit Docker API configuration; preserved image mapping"}
        for raw in [*files, *env_files, os.path.join(work, ".env") if work else ""]:
            if not raw:
                continue
            source = raw if os.path.isabs(raw) else os.path.join(work, raw)
            if not os.path.isfile(source):
                entry["missing"].append(source)
                continue
            paths.add(source)
            entry["files"].append(source)
        # Config output is evidence; failure/missing source does not block direct reconstruction.
        if files and files[0] and all(os.path.isfile(f if os.path.isabs(f) else os.path.join(work, f)) for f in files):
            args = ["compose", "--project-directory", work or "."]
            for file in files:
                args += ["-f", file if os.path.isabs(file) else os.path.join(work, file)]
            result = docker(*args, "config", "--format", "json", check=False)
            if result.returncode == 0:
                target = "compose/" + path_key(c["Id"]) + ".json"
                (payload / target).write_bytes(result.stdout)
                entry["resolved"] = target
            else:
                entry["resolved_unavailable"] = True
        entries.append(entry)
    if paths:
        with (payload / "compose/sources.tar").open("wb") as stream:
            run([*TAR_CREATE, "--directory=/", "--", *sorted(x.lstrip("/") for x in paths)], output=stream)
    return entries


def online_path(value):
    if (not isinstance(value, str) or not os.path.isabs(value) or
            ".." in Path(value).parts or any(ord(char) < 32 for char in value)):
        raise Failure(f"在线数据映射需要安全绝对路径: {value}", 10)
    return os.path.normpath(value)


def online_mount_path(resource, mount, path, directory=False):
    """Map a declared container path without following host-side symlinks."""
    try:
        root = Path(online_path(resource["source"] if resource["type"] == "bind"
                                else resource["definition"]["Mountpoint"]))
        destination = Path(online_path(mount["Destination"]))
        local = root / Path(path).relative_to(destination)
        if resource["type"] == "volume" and mount.get("Source") and Path(online_path(mount["Source"])) != root:
            raise Failure(f"卷 {resource['source']} 的实际挂载源与 Mountpoint 不一致，无法安全映射", 10)
        for current in {root, local}:
            details = current.stat()
            if current.resolve(strict=True) != current:
                raise Failure(f"在线数据映射包含符号链接: {current}", 10)
            access = os.R_OK | (os.X_OK if stat.S_ISDIR(details.st_mode) else 0)
            if not os.access(current, access):
                raise Failure(f"在线数据映射无法读取: {current}", 10)
        if directory and not local.is_dir():
            raise Failure(f"数据库数据目录不是目录: {local}", 10)
        return root, local
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise Failure(f"在线数据 {path} 无法安全映射到挂载 {resource.get('source')}: {error}", 10) from error


def online_coverage(resource, root, paths):
    """Inspect only content outside declared exports, never database internals."""
    uncovered = []

    def visit(directory):
        nonempty = False
        with os.scandir(directory) as entries:
            for entry in entries:
                nonempty = True
                if any(contains(str(path), entry.path) for path in paths):
                    continue
                if entry.is_dir(follow_symlinks=False):
                    visit(entry.path)
                else:
                    uncovered.append(entry.path)
                if len(uncovered) >= 5:
                    return
        if not nonempty:
            uncovered.append(str(directory) + "/")

    try:
        if root not in paths:
            visit(root)
    except OSError as error:
        raise Failure(f"在线挂载 {resource['source']} 无法读取覆盖范围: {error}", 10) from error
    if uncovered:
        raise Failure(f"在线挂载 {resource['source']} 包含未覆盖路径 {uncovered}；"
                      "请将业务数据拆为独立挂载、配置完整 capture/restore 应用 hook 或使用 stop 模式", 10)


def online_prepare(inv, options):
    """Resolve native database directories and account for every active writable mount."""
    resolved = []
    coverage = {}
    logical_resources = set()
    for item in options.get("online", []):
        item = copy.deepcopy(item)
        kind, name = item.get("kind"), item.get("container")
        c = next((c for c in inv["containers"] if name in (c["Id"], c["Name"].lstrip("/"))), None)
        if not c or not c["State"]["Running"]:
            raise Failure(f"在线适配器容器未运行或未选中: {name}", 10)
        cid = c["Id"]
        if kind == "postgres":
            user = item.get("user", "postgres")
            source = docker("exec", "--user", item.get("os_user", "postgres"), cid, "psql", "--username", user, "--dbname", "postgres", "--tuples-only", "--no-align", "--command", "SHOW data_directory").stdout.decode().strip()
            data_paths = [source]
        elif kind in ("mysql", "mariadb"):
            defaults = item.get("defaults_file", "")
            if not defaults.startswith("/"):
                raise Failure("MySQL 在线适配器需要容器内 defaults_file 凭据文件", 10)
            binary = "mariadb" if kind == "mariadb" else "mysql"
            source = docker("exec", cid, binary, "--defaults-extra-file=" + defaults, "--batch", "--skip-column-names", "--execute", "SELECT @@datadir").stdout.decode().strip()
            data_paths = [source]
        elif kind == "sqlite":
            source = item.get("path", "")
            if not source.startswith("/") or ".." in Path(source).parts or any(ord(x) < 32 for x in source):
                raise Failure("SQLite 在线适配器需要容器内安全绝对 path", 10)
            data_paths = [source]
        elif kind == "hook":
            if not all(isinstance(item.get(key), list) and item[key] for key in ("capture", "restore", "data_mounts")):
                raise Failure("hook 需要 capture/restore argv 数组和完整 data_mounts 列表", 10)
            if not all(isinstance(x, str) for x in item["capture"] + item["restore"]):
                raise Failure("hook argv 必须由字符串组成", 10)
            data_paths = item["data_mounts"]
        else:
            raise Failure(f"未支持在线适配器: {kind}", 10)
        item["resolved_mounts"] = []
        for path in data_paths:
            path = online_path(path)
            candidates = [m for m in c.get("Mounts", []) if m["Type"] in ("volume", "bind") and contains(online_path(m.get("Destination")), path)]
            if not candidates:
                raise Failure(f"{name}: 在线数据 {path} 必须位于明确持久挂载中；可写层数据库需 stop 模式", 10)
            mount = max(candidates, key=lambda m: len(online_path(m["Destination"])))
            resource = next((r for r in inv["resources"] if mount_source(mount) == (r["type"], r["source"])), None)
            if resource is None:
                raise Failure(f"{name}: 在线数据 {path} 无法匹配持久挂载资源", 10)
            if resource.get("dependency"):
                raise Failure(f"{name}: 数据库位于运行时依赖中: {path}", 10)
            item["resolved_mounts"].append(resource["key"])
            logical_resources.add(resource["key"])
            if kind != "sqlite":
                root, local = online_mount_path(resource, mount, path, directory=kind != "hook")
                entry = coverage.setdefault(resource["key"], {"root": root, "paths": set()})
                entry["paths"].add(local)
            if kind == "sqlite":
                relative = path[len(mount["Destination"]):].lstrip("/")
                if not relative and resource["type"] == "volume":
                    raise Failure("SQLite path 不能指向卷根目录", 10)
                item["relative_path"] = relative
                item["resource_key"] = resource["key"]
                source_root = resource["source"] if resource["type"] == "bind" else resource["definition"]["Mountpoint"]
                local_path = Path(source_root) / relative if relative else Path(source_root)
                details = local_path.stat()
                item["metadata"] = {"uid": details.st_uid, "gid": details.st_gid, "mode": details.st_mode & 0o7777}
                # A SQLite adapter owns its database, WAL and SHM only. Other files must
                # receive their own adapter instead of being silently discarded.
                if os.path.isdir(source_root):
                    allowed = {str(local_path), str(local_path) + "-wal", str(local_path) + "-shm", str(local_path) + "-journal"}
                    others = [str(p) for p in Path(source_root).rglob("*") if not p.is_dir() and str(p) not in allowed]
                    if others:
                        raise Failure(f"SQLite 挂载包含未覆盖文件 {others[:5]}；为其配置完整应用 hook 或 stop 模式")
        item["container_id"] = cid
        resolved.append(item)
    for resource in inv["resources"]:
        if resource["key"] in coverage:
            entry = coverage[resource["key"]]
            online_coverage(resource, entry["root"], entry["paths"])
    covered = {item["container_id"] for item in resolved}
    for c in inv["containers"]:
        if c["State"]["Running"] and c["Id"] not in covered:
            raise Failure(f"{c['Name']}: 在线模式需要原生数据库适配器或明确应用 hook", 10)
    for resource in inv["resources"]:
        if resource.get("dependency"):
            continue
        for c in inv["writers"]:
            writes = any(m.get("RW") and mount_source(m) == (resource["type"], resource["source"]) for m in c.get("Mounts", []))
            if writes and c["Id"] not in covered:
                raise Failure(f"在线数据仍被未适配共享容器写入: {c['Name']}")
            if writes and resource["key"] not in logical_resources and not options.get("pre_hook"):
                raise Failure(f"在线可写挂载 {resource['source']} 没有导出适配器或 pre/post 应用协调 hook")
    for resource in inv["resources"]:
        if resource["key"] in logical_resources:
            resource["logical_only"] = True
    return resolved


def sqlite_archive(inv, item, snapshot, payload):
    """Package a native SQLite snapshot with the original Linux file metadata."""
    import tempfile
    resource = next(r for r in inv["resources"] if r["key"] == item["resource_key"])
    source = Path(resource["source"] if resource["type"] == "bind" else resource["definition"]["Mountpoint"])
    relative = item["relative_path"]
    with tempfile.TemporaryDirectory(prefix=".sqlite-", dir=payload) as temporary:
        tree = Path(temporary)
        entry = source.name if resource["type"] == "bind" else "root"
        root = tree / entry
        target = root / relative if relative else root
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(snapshot, target)
        original = source / relative if relative else source
        shutil.copystat(original, target)
        details = original.stat()
        os.chown(target, details.st_uid, details.st_gid)
        if source.is_dir():
            current = target.parent
            while contains(str(root), str(current)):
                origin = source / current.relative_to(root)
                shutil.copystat(origin, current)
                details = origin.stat()
                os.chown(current, details.st_uid, details.st_gid)
                if current == root:
                    break
                current = current.parent
        destination = payload / resource["archive"]
        with destination.open("wb") as stream:
            run([*TAR_CREATE, "--directory=" + str(root if resource["type"] == "volume" else tree), "--", "." if resource["type"] == "volume" else entry], output=stream)
    resource["native_archive"] = True


def online_exports(inv, options, payload):
    adapters = online_prepare(inv, options)
    covered = set()
    exports = []
    for item in adapters:
        kind, name = item.get("kind"), item.get("container")
        selected = next((c for c in inv["containers"] if name in (c["Id"], c["Name"].lstrip("/"))), None)
        if not selected or not selected["State"]["Running"]:
            raise Failure(f"在线适配器容器未运行或未选中: {name}", 10)
        cid = selected["Id"]
        dest = payload / "online" / (path_key(cid + str(len(exports))) + ".sql")
        record = {"kind": kind, "container": cid, "archive": str(dest.relative_to(payload)), "options": item}
        if kind == "postgres":
            user = item.get("user", "postgres")
            args = ["exec", "--user", item.get("os_user", "postgres"), cid, "pg_dumpall", "--clean", "--if-exists", "--username", user]
            record["version"] = docker("exec", cid, "postgres", "--version").stdout.decode().strip()
        elif kind in ("mysql", "mariadb"):
            defaults = item.get("defaults_file")
            if not defaults or not defaults.startswith("/"):
                raise Failure("MySQL 在线备份必须提供容器内 defaults_file（含权限受限的凭据）", 10)
            binary = "mariadb-dump" if kind == "mariadb" else "mysqldump"
            args = ["exec", cid, binary, "--defaults-extra-file=" + defaults, "--all-databases", "--routines", "--events",
                    "--triggers", "--hex-blob", "--lock-all-tables", "--add-drop-database"]
            record["version"] = docker("exec", cid, binary, "--version").stdout.decode().strip()
        elif kind == "sqlite":
            source = item.get("path", "")
            if not source.startswith("/") or "\n" in source:
                raise Failure("SQLite 在线适配器需要容器内绝对 path", 10)
            # SQLite's native backup API includes committed WAL pages in the backup.
            temporary = "/tmp/vpsctl-backup-" + path_key(str(payload) + cid) + ".sqlite"
            try:
                docker("exec", cid, "sqlite3", "-batch", "-bail", source, ".backup '" + temporary + "'")
                docker("cp", cid + ":" + temporary, str(dest))
            finally:
                docker("exec", cid, "rm", "-f", temporary, check=False)
            record["version"] = docker("exec", cid, "sqlite3", "--version").stdout.decode().strip()
            sqlite_archive(inv, item, dest, payload)
            covered.add(cid)
            exports.append(record)
            continue
        elif kind == "hook":
            capture = item.get("capture", [])
            restore = item.get("restore", [])
            if not capture or not restore or not all(isinstance(x, str) for x in capture + restore):
                raise Failure("hook 必须提供明确 capture/restore argv 数组", 10)
            args = ["exec", cid, *capture]
        else:
            raise Failure(f"未支持在线适配器: {kind}", 10)
        with dest.open("wb") as stream:
            docker(*args, output=stream)
        if not dest.stat().st_size:
            raise Failure(f"在线导出为空: {name}", 20)
        covered.add(cid)
        exports.append(record)
    running = {c["Id"] for c in inv["containers"] if c["State"]["Running"]}
    if running - covered:
        raise Failure("在线模式每个活动容器均须明确原生适配器或应用 hook；不能复制活动数据库目录", 10)
    return exports


def capture(engine, plan, job_dir, payload, job_id, install=False):
    inv = inventory(engine, plan)
    if inv["gaps"]:
        raise Failure("；".join(inv["gaps"]))
    options = plan.get("options", {})
    verify_tar()
    if options.get("pre_hook") or options.get("post_hook"):
        for key in ("pre_hook", "post_hook"):
            path = options.get(key, "")
            if not os.path.isabs(path) or not os.path.isfile(path) or not os.access(path, os.X_OK):
                raise Failure(f"{key} 必须是可执行的绝对脚本路径", 10)
    helper = helper_image(options, install)
    payload, job_dir = Path(payload), Path(job_dir)
    for folder in ("data", "images", "compose", "online"):
        (payload / folder).mkdir(parents=True, mode=0o700, exist_ok=True)
    if inv["space_estimation_unavailable"]:
        raise Failure("无法估算持久数据空间: " + ", ".join(inv["space_estimation_unavailable"]))
    estimate = inv["estimated_staging_bytes"]
    if shutil.disk_usage(payload).free < estimate:
        raise Failure(f"暂存空间不足：估算需要 {estimate} 字节；停服尚未开始")
    journal = job_dir / "docker-running.json"
    write_json(job_dir / "docker-inventory.json", inv)
    temporary_images = []
    mode = options.get("consistency", "stop")
    stopped = False
    hook_started = False
    try:
        if mode == "stop":
            stopped = True
            stop_writers(inv, options, journal)
        elif mode != "online":
            raise Failure("consistency 必须为 stop/online", 10)
        if mode == "online" and options.get("pre_hook"):
            hook_started = True
            write_json(journal, {"schema_version": 1, "engine_id": inv["engine_id"], "containers": [], "services": [],
                                 "post_hook": options["post_hook"], "stop_timeout": options.get("stop_timeout", 120), "resumed": False})
            run([options["pre_hook"]], timeout=options.get("stop_timeout", 120))
        exports = online_exports(inv, options, payload) if mode == "online" else []
        exported_ids = {e["container"] for e in exports}
        image_ids = {c["Image"] for c in inv["containers"]} | {i["Id"] for i in inv["images"]} | {helper}
        for c in inv["containers"]:
            c["original_image_id"] = c["Image"]
            changed = docker("diff", c["Id"]).stdout.strip()
            if mode == "online" and c["State"]["Running"] and changed and c["Id"] not in exported_ids:
                raise Failure(f"{c['Name']}: 在线可写层无一致性适配")
            if changed:
                # Online adapters export databases separately; commit is a filesystem image,
                # never a claim that running database files form an application checkpoint.
                image = commit_image(c["Id"])
                temporary_images.append(image)
                image_ids.add(image)
                c["restore_image_id"] = image
            else:
                c["restore_image_id"] = c["Image"]
        for resource in inv["resources"]:
            if resource.get("dependency"):
                resource.pop("archive", None)
                continue
            if resource.get("native_archive"):
                continue
            if mode == "online" and resource.get("logical_only"):
                # Database engines initialize fresh data; preserve only the mount root's
                # metadata, never copy their active data files into the checkpoint.
                if resource["type"] == "volume":
                    volume_archive(resource, helper, payload / resource["archive"], metadata_only=True)
                elif resource.get("directory"):
                    source = Path(resource["source"])
                    with (payload / resource["archive"]).open("wb") as stream:
                        run([*TAR_CREATE, "--no-recursion", "--directory=" + str(source.parent), "--", source.name], output=stream)
                else:
                    resource.pop("archive", None)
                continue
            target = payload / resource["archive"]
            if resource["type"] == "volume":
                volume_archive(resource, helper, target)
            else:
                source = Path(resource["source"])
                with target.open("wb") as stream:
                    run([*TAR_CREATE, "--directory=" + str(source.parent), "--", source.name], output=stream)
        compose = save_compose(inv, payload)
        for image in sorted(image_ids):
            target = "images/" + path_key(image) + ".tar"
            docker("image", "save", "--output", str(payload / target), image)
        after = inspect_all()
        if sorted(c["Id"] for c in after) != inv["all_container_ids"]:
            raise Failure("采集期间容器清单发生变化，拒绝上传不完整恢复点")
        current = {c["Id"]: c for c in after}
        for c in inv["containers"]:
            other = current[c["Id"]]
            if any(c[k] != other[k] for k in ("Config", "HostConfig", "Mounts", "Image")):
                raise Failure(f"采集期间配置发生变化: {c['Name']}")
        for resource in inv["resources"]:
            if resource.get("dependency"):
                continue
            source = resource["source"] if resource["type"] == "bind" else resource["definition"]["Mountpoint"]
            details = os.stat(source)
            if resource["source_identity"] != [details.st_dev, details.st_ino]:
                raise Failure(f"采集期间挂载/数据源被替换: {source}")
        if mode == "stop" and host_writers(inv["resources"]):
            raise Failure("采集结束前出现新的宿主机写入者，拒绝上传不一致恢复点")
        manifest = {"schema_version": 1, "type": "docker", "plan_id": plan["id"], "job_id": job_id,
                    "source_host": read_json(job_dir / "job.json")["source_host"], "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "consistency": mode, "inventory": inv, "helper_image_id": helper,
                    "image_archives": ["images/" + path_key(i) + ".tar" for i in sorted(image_ids)],
                    "compose": compose, "online_exports": exports, "estimated_bytes": estimate}
        if mode == "online":
            manifest["consistency_scope"] = "Native per-database snapshots; PostgreSQL databases have separate transactions. Cross-application consistency requires the declared pre/post hooks."
        manifest["required_files"] = manifest["image_archives"] + [r["archive"] for r in inv["resources"] if r.get("archive")] + [e["archive"] for e in exports]
        manifest["required_files"] += [str(path.relative_to(payload)) for path in (payload / "recovery").rglob("*") if path.is_file()]
        write_json(payload / "manifest.json", manifest)
    finally:
        resume_error = None
        if (stopped or hook_started) and journal.exists():
            try:
                restore_running(journal)
            except Failure as error:
                resume_error = error
        for image in temporary_images:
            docker("image", "rm", image, check=False)
        if resume_error:
            raise resume_error


def mapping(items):
    result = {}
    for item in items:
        if "=" not in item:
            raise Failure("映射格式为 SOURCE=TARGET", 2)
        key, value = item.split("=", 1)
        if not key or not value or key in result:
            raise Failure("无效或重复映射", 2)
        result[key] = value
    return result


def create_request(container, names, volumes, networks, binds):
    """Map supported inspect fields explicitly; runtime fields never enter create."""
    config = {k: copy.deepcopy(v) for k, v in container["Config"].items() if k in CONFIG_FIELDS}
    host = {k: copy.deepcopy(v) for k, v in container["HostConfig"].items() if k in HOST_FIELDS}
    config["Image"] = container["restore_image_id"]
    # Rebuild mounts from normalized evidence so anonymous/shared volume identity is retained.
    host.pop("Binds", None)
    original_mounts = {m["Target"]: m for m in host.pop("Mounts", [])}
    host["Mounts"] = []
    for m in container.get("Mounts", []):
        if m["Type"] not in ("bind", "volume"):
            continue
        mount = copy.deepcopy(original_mounts.get(m["Destination"], {}))
        mount.update({"Type": m["Type"], "Source": volumes[m["Name"]] if m["Type"] == "volume" else binds.get(m["Source"], m["Source"]),
                      "Target": m["Destination"], "ReadOnly": not m.get("RW", True)})
        if m["Type"] == "volume":
            mount.setdefault("VolumeOptions", {})["NoCopy"] = True
        elif m.get("Propagation"):
            mount.setdefault("BindOptions", {})["Propagation"] = m["Propagation"]
        host["Mounts"].append(mount)
    for key in ("NetworkMode", "PidMode", "IpcMode"):
        value = host.get(key, "")
        if value.startswith("container:"):
            host[key] = "container:" + names.get(value[10:], value[10:])
        elif key == "NetworkMode":
            host[key] = networks.get(value, value)
    if host.get("VolumesFrom"):
        host["VolumesFrom"] = [names.get(v.split(":")[0], v.split(":")[0]) + (":" + v.split(":", 1)[1] if ":" in v else "") for v in host["VolumesFrom"]]
    if host.get("Links"):
        host["Links"] = [names.get(v.split(":")[0].lstrip("/"), v.split(":")[0].lstrip("/")) + ":" + v.split(":", 1)[1].split("/")[-1] for v in host["Links"]]
    endpoints = {}
    if not host.get("NetworkMode", "").startswith("container:"):
        for name, settings in container.get("NetworkSettings", {}).get("Networks", {}).items():
            endpoint = {k: copy.deepcopy(settings[k]) for k in ("IPAMConfig", "Aliases", "Links", "DriverOpts", "GwPriority") if settings.get(k) is not None}
            if name in ("bridge", "host", "none"):
                endpoint.pop("Aliases", None)
            else:
                endpoint["Aliases"] = [names.get(x, x) for x in endpoint.get("Aliases", []) if x not in (container["Id"], container["Id"][:12])]
            endpoints[networks.get(name, name)] = endpoint
    return {**config, "HostConfig": host, "NetworkingConfig": {"EndpointsConfig": endpoints}}


def selected_manifest(payload, selection=None):
    manifest = read_json(Path(payload) / "manifest.json")
    if manifest.get("schema_version") != 1 or manifest.get("type") != "docker":
        raise Failure("不支持的 Docker 快照 schema/type", 10)
    selection = selection or {}
    if not any(selection.values()):
        return manifest
    inv = manifest["inventory"]
    if selection.get("volumes"):
        if selection.get("containers") or selection.get("projects"):
            raise Failure("单卷恢复不能同时选择容器/项目", 2)
        resources = [r for r in inv["resources"] if r["type"] == "volume" and r["source"] in selection["volumes"]]
        if {r["source"] for r in resources} != set(selection["volumes"]):
            raise Failure("选择的卷不在快照中", 10)
        if any(r.get("logical_only") and not r.get("native_archive") for r in resources):
            raise Failure("逻辑数据库导出必须连同数据库容器恢复，不能只还原空数据卷", 10)
        inv["containers"], inv["resources"], inv["networks"] = [], resources, []
        manifest["online_exports"] = []
        return manifest
    chosen = select_containers(inv["containers"], selection)
    if not chosen:
        raise Failure("恢复选择没有匹配任何容器", 10)
    identities = {v for c in chosen for v in (c["Id"], c["Name"].lstrip("/"))}
    for c in chosen:
        if any(dep not in identities for dep in dependencies(c)):
            raise Failure(f"所选容器 {c['Name']} 缺少关联容器，需一并选择", 10)
    resources = [r for r in inv["resources"] if identities.intersection(r["containers"])]
    if any(set(r["containers"]) - identities for r in resources):
        raise Failure("所选容器与快照中的其他容器共享数据；请一并选择所有共享容器，或使用 --volume 单独恢复数据", 10)
    network_names = {name for c in chosen for name in c.get("NetworkSettings", {}).get("Networks", {})}
    inv["containers"], inv["resources"] = chosen, resources
    inv["networks"] = [n for n in inv["networks"] if n["Name"] in network_names]
    manifest["online_exports"] = [e for e in manifest.get("online_exports", []) if e["container"] in identities]
    return manifest


def source_identity(payload, requested_snapshot="", record=False):
    payload = Path(payload)
    manifest = read_json(payload / "manifest.json")
    manifest_hash = hashlib.sha256((payload / "manifest.json").read_bytes()).hexdigest()
    index_hash = hashlib.sha256((payload / ".vpsctl-files.json").read_bytes()).hexdigest()
    content_hash = hashlib.sha256((manifest_hash + ":" + index_hash).encode()).hexdigest()
    receipt = payload.with_name(payload.name + ".docker-source.json")
    identity = {"schema_version": 1, "job_id": manifest["job_id"], "manifest_sha256": manifest_hash,
                "index_sha256": index_hash, "content_sha256": content_hash}
    if record:
        if not re.fullmatch(r"[a-f0-9]{64}", requested_snapshot):
            raise Failure("来源记录需要已解析的完整快照 ID", 10)
        expected = {**identity, "snapshot_id": requested_snapshot}
        if receipt.is_symlink():
            raise Failure("恢复来源记录不能为符号链接", 10)
        if receipt.exists() and read_json(receipt) != expected:
            raise Failure("同级来源记录已存在且不匹配，请使用新的材料下载目录", 10)
        if not receipt.exists():
            write_json(receipt, expected)
    if receipt.exists():
        saved = read_json(receipt)
        if any(saved.get(key) != value for key, value in identity.items()):
            raise Failure("恢复来源记录与材料摘要不一致；请重新取回选定快照", 10)
        snapshot = saved.get("snapshot_id", "")
        if not re.fullmatch(r"[a-f0-9]{64}", snapshot) or not snapshot.startswith(requested_snapshot):
            raise Failure("指定快照与材料的实际来源记录不匹配", 10)
        return {**identity, "kind": "verified-snapshot", "snapshot_id": snapshot, "confirmation": snapshot}
    return {**identity, "kind": "offline-content", "snapshot_id": None, "confirmation": "sha256:" + content_hash}


def restore_plan(engine, payload, prefix, bind_map, selection=None, requested_snapshot=""):
    manifest = selected_manifest(payload, selection)
    identity = source_identity(payload, requested_snapshot)
    inv = manifest["inventory"]
    gaps = engine.capabilities()
    if engine.info.get("Architecture") != inv["architecture"]:
        gaps.append("跨架构恢复需要目标镜像和数据兼容适配")
    names = {key: prefix + c["Name"].lstrip("/") for c in inv["containers"] for key in (c["Id"], c["Name"].lstrip("/"))}
    volumes = {r["source"]: prefix + r["source"] for r in inv["resources"] if r["type"] == "volume"}
    networks = {n["Name"]: n["Name"] if n["Name"] in ("bridge", "host", "none") else prefix + n["Name"] for n in inv["networks"]}
    existing = inspect_all()
    occupied = {c["Name"].lstrip("/") for c in existing}
    conflicts = []
    for c in inv["containers"]:
        name = names[c["Id"]]
        if name in occupied:
            conflicts.append({"type": "container", "target": name})
            current = next(other for other in existing if other["Name"].lstrip("/") == name)
            if current["HostConfig"].get("AutoRemove"):
                gaps.append(f"覆盖目标 {name} 使用 --rm，停止会删除其配置，需先显式迁走该容器")
        gaps.extend(f"{name}: 未支持创建字段 {f}" for f in unknown_fields(c))
        for d in c["HostConfig"].get("Devices") or []:
            if not os.path.exists(d["PathOnHost"]):
                gaps.append("缺少目标设备: " + d["PathOnHost"])
        if c["HostConfig"].get("DeviceRequests"):
            gaps.append(f"{name}: GPU/device requests 需目标运行时专项验收")
        desired = c["HostConfig"].get("PortBindings") or {}
        for other in existing:
            if other["Name"].lstrip("/") == name:
                continue
            for port, bindings in desired.items():
                for bound in bindings or []:
                    for op, obs in (other["HostConfig"].get("PortBindings") or {}).items():
                        if port.split("/")[-1] == op.split("/")[-1] and any(bound.get("HostPort") and bound.get("HostPort") == ob.get("HostPort") for ob in obs or []):
                            gaps.append(f"端口 {bound['HostPort']}/{port.split('/')[-1]} 与现有容器 {other['Name']} 冲突")
        for port, bindings in desired.items():
            protocol = port.split("/")[-1]
            for bound in bindings or []:
                host_port = bound.get("HostPort")
                if not host_port or not host_port.isdigit() or protocol not in ("tcp", "udp"):
                    continue
                owned = any(other["Name"].lstrip("/") == name and any(
                    ob.get("HostPort") == host_port for obs in (other["HostConfig"].get("PortBindings") or {}).values() for ob in obs or []) for other in existing)
                if owned:
                    continue
                address = bound.get("HostIp") or "0.0.0.0"
                try:
                    with socket.socket(socket.AF_INET6 if ":" in address else socket.AF_INET,
                                       socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM) as probe:
                        probe.bind((address, int(host_port)))
                except OSError as error:
                    gaps.append(f"目标宿主端口 {address}:{host_port}/{protocol} 不可用: {error.strerror}")
    existing_volumes = set(docker("volume", "ls", "-q").stdout.decode().splitlines())
    for source, target in volumes.items():
        if target in existing_volumes:
            conflicts.append({"type": "volume", "source": source, "target": target})
            users = [c["Name"] for c in existing if any(m.get("Name") == target for m in c.get("Mounts", [])) and c["Name"].lstrip("/") not in names.values()]
            if users:
                gaps.append(f"卷 {target} 仍被恢复范围之外容器使用: {users}")
    bind_targets = []
    for r in inv["resources"]:
        if r["type"] != "bind":
            continue
        target = bind_map.get(r["source"], r["source"])
        safe_path(target)
        if r.get("dependency"):
            if not os.path.exists(target):
                gaps.append("缺少目标运行时挂载依赖: " + target)
        elif os.path.lexists(target):
            conflicts.append({"type": "bind", "source": r["source"], "target": target})
        if not r.get("dependency"):
            normalized = os.path.normpath(target)
            for previous_source, previous_target in bind_targets:
                if contains(previous_target, normalized) or contains(normalized, previous_target):
                    gaps.append(f"不同 bind 资源目标重叠: {previous_source} -> {previous_target}; {r['source']} -> {normalized}")
            bind_targets.append((r["source"], normalized))
            for other in existing:
                if other["Name"].lstrip("/") in names.values():
                    continue
                for mount in other.get("Mounts", []):
                    if mount["Type"] == "bind" and (contains(normalized, mount["Source"]) or contains(mount["Source"], normalized)):
                        gaps.append(f"Bind 目标 {normalized} 与恢复范围之外容器 {other['Name']} 的 {mount['Source']} 重叠")
    existing_networks = set(docker("network", "ls", "--format", "{{.Name}}").stdout.decode().splitlines())
    for source, target in networks.items():
        if target in existing_networks and target not in ("bridge", "host", "none"):
            conflicts.append({"type": "network", "source": source, "target": target})
            attached = dj("network", "inspect", target)[0].get("Containers") or {}
            if any(cid not in {c["Id"] for c in existing if c["Name"].lstrip("/") in names.values()} for cid in attached):
                gaps.append(f"网络 {target} 有恢复范围之外的容器，不能覆盖")
        elif target not in ("bridge", "host", "none"):
            import ipaddress
            original = next(n for n in inv["networks"] if n["Name"] == source)
            wanted_subnets = [ipaddress.ip_network(config["Subnet"], strict=False) for config in original.get("IPAM", {}).get("Config") or [] if config.get("Subnet")]
            for existing_name in existing_networks:
                current_network = dj("network", "inspect", existing_name)[0]
                for config in current_network.get("IPAM", {}).get("Config") or []:
                    if config.get("Subnet"):
                        current_subnet = ipaddress.ip_network(config["Subnet"], strict=False)
                        if any(wanted.version == current_subnet.version and wanted.overlaps(current_subnet) for wanted in wanted_subnets):
                            gaps.append(f"网络 {target} 子网与现有网络 {existing_name} 重叠；使用空白 daemon 或先迁走冲突网络")
    for archive in manifest["image_archives"] + [r["archive"] for r in inv["resources"] if r.get("archive")]:
        source = Path(payload) / archive
        if not source.is_file() or not contains(str(Path(payload).resolve()), str(source.resolve())):
            gaps.append("缺少或不安全的恢复归档: " + archive)
    for source in bind_map:
        if source not in {r["source"] for r in inv["resources"] if r["type"] == "bind"}:
            gaps.append("绑定映射的源不在快照内: " + source)
    return {"schema_version": 1, "snapshot_job": manifest["job_id"], "source_host": manifest["source_host"],
            "source": identity, "confirmation_snapshot": identity["confirmation"],
            "target_engine": engine.info["ID"], "names": names, "volumes": volumes, "networks": networks,
            "binds": bind_map, "conflicts": conflicts, "gaps": gaps,
            "start": [names[c["Id"]] for c in ordered(inv["containers"]) if c["State"]["Running"]]}


def validate_archive(path):
    with tarfile.open(path, "r:") as archive:
        for member in archive:
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise Failure("归档包含越界文件路径", 10)
            if member.islnk() and (Path(member.linkname).is_absolute() or ".." in Path(member.linkname).parts):
                raise Failure("归档包含越界硬链接", 10)


def import_online(manifest, plan, payload):
    for item in manifest.get("online_exports", []):
        name = plan["names"][item["container"]]
        options = item["options"]
        kind = item["kind"]
        if kind == "sqlite":
            # The native backup was already restored as a volume/bind archive, while
            # the application container was absent and could not modify the database.
            continue
        if kind == "postgres":
            user = options.get("user", "postgres")
            args = ["exec", "-i", "--user", options.get("os_user", "postgres"), name, "psql", "--set=ON_ERROR_STOP=1", "--username", user, "template1"]
            probe_args = ["exec", "--user", options.get("os_user", "postgres"), name, "pg_isready", "--username", user]
        elif kind in ("mysql", "mariadb"):
            args = ["exec", "-i", name, "mariadb" if kind == "mariadb" else "mysql", "--defaults-extra-file=" + options["defaults_file"]]
            probe_args = ["exec", name, "mariadb" if kind == "mariadb" else "mysql", "--defaults-extra-file=" + options["defaults_file"], "--execute", "SELECT 1"]
        else:
            args = ["exec", "-i", name, *options["restore"]]
            probe_args = ["inspect", name]
        # Database engines need a short readiness window after initializing empty storage.
        for attempt in range(30):
            probe = docker(*probe_args, check=False)
            if probe.returncode == 0:
                break
            time.sleep(1)
        else:
            raise Failure(f"数据库未就绪: {name}", 30)
        source = Path(payload) / item["archive"]
        if kind == "postgres":
            # The bootstrap login owns the restore session and cannot be dropped.
            # Keep it, apply its ALTER statements, restore every other role normally.
            import tempfile
            user_forms = {user, '"' + user.replace('"', '""') + '"'}
            with tempfile.TemporaryFile() as filtered:
                with source.open("rb") as stream:
                    for line in stream:
                        text = line.decode(errors="replace").strip()
                        if any(text in (f"DROP ROLE {u};", f"DROP ROLE IF EXISTS {u};", f"CREATE ROLE {u};") for u in user_forms):
                            continue
                        filtered.write(line)
                filtered.seek(0)
                result = subprocess.run(["docker", *args], stdin=filtered, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        else:
            with source.open("rb") as stream:
                result = subprocess.run(["docker", *args], stdin=stream, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise Failure(f"数据库导入失败: {name} ({kind})；材料保留在 {source}", 30)


def restore(engine, args):
    selection = {"containers": args.container, "projects": args.project, "volumes": args.volume}
    plan = restore_plan(engine, args.payload, args.name_prefix, mapping(args.bind_map), selection, args.snapshot)
    if plan["gaps"]:
        raise Failure("；".join(plan["gaps"]))
    if plan["conflicts"]:
        if not args.overwrite or args.confirm_target != plan["target_engine"] or args.confirm_snapshot != plan["confirmation_snapshot"]:
            raise Failure("覆盖须 --overwrite --confirm-target ENGINE_ID --confirm-snapshot PLAN_CONFIRMATION；使用 restore-plan 的 confirmation_snapshot（已验证快照 ID 或离线内容摘要）", 3)
    manifest = selected_manifest(args.payload, selection)
    inv = manifest["inventory"]
    payload = Path(args.payload)
    for r in inv["resources"]:
        if r.get("archive"):
            validate_archive(payload / r["archive"])
    verify_tar()
    changed = False
    stopped_existing = []
    journal_path = payload.parent / ("docker-restore-" + path_key(plan["confirmation_snapshot"] + plan["target_engine"]) + ".json")
    journal = {"schema_version": 1, "source": plan["source"], "target_engine": plan["target_engine"], "existing": [], "stage": "applying"}
    write_json(journal_path, journal)
    try:
        for archive in manifest["image_archives"]:
            docker("image", "load", "--input", str(payload / archive))
        for conflict in plan["conflicts"]:
            if conflict["type"] == "container":
                original = dj("inspect", conflict["target"])[0]
                journal["existing"].append(original)
                write_json(journal_path, journal)
                if original["State"]["Running"]:
                    stopped_existing.append(original["Id"])
                changed = True
                docker("stop", "--time", "-1", conflict["target"], timeout=120)
                state = dj("inspect", conflict["target"])[0]["State"]
                if state["Running"] or state.get("OOMKilled") or state.get("ExitCode") == 137:
                    raise Failure("覆盖目标未正常停止: " + conflict["target"], 30)
                docker("rm", conflict["target"])
        for conflict in plan["conflicts"]:
            kind, target = conflict["type"], conflict["target"]
            if kind == "volume":
                docker("volume", "rm", target)
                changed = True
            elif kind == "network":
                docker("network", "rm", target)
                changed = True
            elif kind == "bind":
                target = safe_path(target)
                # Keep a recoverable sibling copy; never recursively delete host data.
                saved = target.with_name(target.name + ".vpsctl-before-" + path_key(plan["confirmation_snapshot"]))
                if saved.exists():
                    raise Failure(f"原数据保留路径已存在: {saved}")
                target.rename(saved)
                changed = True
        for network in inv["networks"]:
            if network["Name"] in ("bridge", "host", "none"):
                continue
            engine.api("POST", "/networks/create", {k: copy.deepcopy(network[k]) for k in ("Driver", "Internal", "Attachable", "EnableIPv6", "IPAM", "Options", "Labels") if k in network} | {"Name": plan["networks"][network["Name"]]})
            changed = True
        for resource in inv["resources"]:
            if resource["type"] == "volume":
                definition = resource["definition"]
                engine.api("POST", "/volumes/create", {"Name": plan["volumes"][resource["source"]], "Driver": definition["Driver"], "Labels": definition.get("Labels") or {}})
                changed = True
            if not resource.get("archive"):
                if resource["type"] == "bind" and not resource.get("dependency"):
                    target = safe_path(plan["binds"].get(resource["source"], resource["source"]))
                    if resource.get("directory"):
                        target.mkdir(parents=True, mode=0o700)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                        target.touch(mode=0o600)
                continue
            archive = payload / resource["archive"]
            if resource["type"] == "volume":
                volume_archive({**resource, "source": plan["volumes"][resource["source"]]}, manifest["helper_image_id"], archive, True)
            else:
                source = Path(resource["source"])
                target = safe_path(plan["binds"].get(str(source), str(source)))
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                # Extract into private staging then rename: source and target basenames may differ.
                import tempfile
                with tempfile.TemporaryDirectory(prefix=".vpsctl-restore-", dir=target.parent) as temp:
                    with archive.open("rb") as stream:
                        result = subprocess.run([*TAR_EXTRACT, "--directory=" + temp], stdin=stream, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    if result.returncode:
                        raise Failure("Bind 归档恢复失败: " + result.stderr.decode(errors="replace"), 20)
                    (Path(temp) / source.name).rename(target)
            changed = True
        for container in ordered(inv["containers"]):
            request = create_request(container, plan["names"], plan["volumes"], plan["networks"], plan["binds"])
            engine.api("POST", "/containers/create?name=" + quote(plan["names"][container["Id"]], safe=""), request)
            changed = True
        native_names = {plan["names"][item["container"]] for item in manifest.get("online_exports", []) if item["kind"] != "sqlite"}
        for name in plan["start"]:
            if name in native_names:
                docker("start", name)
        import_online(manifest, plan, payload)
        for name in plan["start"]:
            if name not in native_names:
                docker("start", name)
        failures = []
        for name in plan["start"]:
            state = dj("inspect", name)[0]["State"]
            for _ in range(30):
                if state.get("Health", {}).get("Status") != "starting":
                    break
                time.sleep(1)
                state = dj("inspect", name)[0]["State"]
            if not state["Running"] or state.get("Health", {}).get("Status") in ("unhealthy", "starting"):
                failures.append(name)
        if failures:
            raise Failure("恢复后服务检查失败: " + ", ".join(failures), 30)
        journal["stage"] = "complete"
        write_json(journal_path, journal)
        return {"schema_version": 1, "restored": list(dict.fromkeys(plan["names"].values())), "running": plan["start"],
                "source": plan["source"],
                "service_check": "running state and configured Docker healthchecks; application checks remain service-specific"}
    except (Failure, OSError, subprocess.TimeoutExpired) as error:
        journal["stage"] = "partial" if changed else "failed"
        journal["resume_failures"] = []
        for cid in stopped_existing:
            if docker("inspect", cid, check=False).returncode == 0 and docker("start", cid, check=False).returncode:
                journal["resume_failures"].append(cid)
        write_json(journal_path, journal)
        if changed:
            raise Failure(f"恢复部分完成，原容器配置及状态保留于 {journal_path}: " + str(error), 30) from error
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("inspect", "prepare", "capture", "recover", "restore-plan", "restore", "record-source", "configure"))
    parser.add_argument("--plan")
    parser.add_argument("--payload")
    parser.add_argument("--job-dir")
    parser.add_argument("--job-id")
    parser.add_argument("--install-deps", action="store_true")
    parser.add_argument("--name-prefix", default="")
    parser.add_argument("--bind-map", action="append", default=[])
    parser.add_argument("--container", action="append", default=[])
    parser.add_argument("--project", action="append", default=[])
    parser.add_argument("--volume", action="append", default=[])
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--confirm-target", default="")
    parser.add_argument("--confirm-snapshot", default="")
    parser.add_argument("--snapshot", default="")
    args = parser.parse_args()
    os.umask(0o077)
    if args.name_prefix and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.name_prefix):
        raise Failure("无效名称前缀", 2)
    if args.action == "record-source":
        source_identity(args.payload, args.snapshot, record=True)
        return
    engine = Engine()
    if args.action == "recover":
        journal = Path(args.job_dir) / "docker-running.json"
        if read_json(journal)["engine_id"] != engine.info["ID"]:
            raise Failure("中断恢复记录不属于当前 daemon")
        restore_running(journal)
        return
    if args.action in ("inspect", "configure", "prepare"):
        plan = read_json(args.plan) if args.plan else {"options": {}}
        inv = inventory(engine, plan)
        result = public_inventory(inv)
        if args.action == "prepare":
            if inv["gaps"]:
                raise Failure("；".join(inv["gaps"]))
            if plan.get("options", {}).get("consistency") == "online":
                online_prepare(inv, plan["options"])
            verify_tar()
            result["helper_image_id"] = helper_image(plan.get("options", {}), args.install_deps)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.action == "capture":
        capture(engine, read_json(args.plan), args.job_dir, args.payload, args.job_id, args.install_deps)
    elif args.action == "restore-plan":
        print(json.dumps(restore_plan(engine, args.payload, args.name_prefix, mapping(args.bind_map),
                                    {"containers": args.container, "projects": args.project, "volumes": args.volume}, args.snapshot), ensure_ascii=False, indent=2))
    elif args.action == "restore":
        print(json.dumps(restore(engine, args), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise Failure("操作中断", 130)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except Failure as error:
        print("错误: " + str(error), file=sys.stderr)
        sys.exit(error.code)
    except subprocess.TimeoutExpired:
        print("错误: 正常停止超时，未强制杀死服务；本次运行状态已尝试恢复", file=sys.stderr)
        sys.exit(20)
    except (OSError, ValueError, KeyError) as error:
        print("错误: " + str(error), file=sys.stderr)
        sys.exit(20)
