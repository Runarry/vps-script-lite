#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export TEST_ROOT
python3 - <<'PY'
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

project = Path(os.environ['TEST_ROOT'])
spec = importlib.util.spec_from_file_location('upstreams', project / 'scripts/offline-build/upstreams.py')
upstreams = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upstreams)
version = (project / 'VERSION').read_text().strip()

def check(condition, message):
    if not condition:
        raise AssertionError(message)

def run(arguments, success=True, env=None):
    result = subprocess.run([str(arg) for arg in arguments], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    check((result.returncode == 0) == success, f'unexpected status {result.returncode}: {arguments}\n{result.stdout}')
    return result

with tempfile.TemporaryDirectory(prefix='vpsctl-offline-build-test-') as temporary:
    root = Path(temporary)
    fixture = root / 'fixture'
    fixture.mkdir()
    mock_bin = root / 'bin'
    mock_bin.mkdir()
    mock = mock_bin / 'curl'
    mock.write_text('''#!/usr/bin/env python3
import hashlib, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['OFFLINE_FIXTURE'])
url = sys.argv[-1]
with (root / 'calls').open('a') as log: log.write(url + '\\n')
if os.environ.get('OFFLINE_FETCH_FAIL'): sys.exit(22)
shutil.copyfile(root / hashlib.sha256(url.encode()).hexdigest(), sys.argv[sys.argv.index('--output') + 1])
''')
    mock.chmod(0o755)
    env = dict(os.environ, PATH=str(mock_bin) + ':' + os.environ['PATH'], OFFLINE_FIXTURE=str(fixture))

    def store(url, contents):
        path = fixture / hashlib.sha256(url.encode()).hexdigest()
        path.write_bytes(contents)
        return path

    release_paths = {}
    for component, repository in upstreams.REPOSITORIES.items():
        assets = []
        sums = []
        tag = 'v1.2.3'
        for arch in ('amd64', 'arm64'):
            name = upstreams.asset_name(component, tag, arch)
            if component == 'lego':
                name = f'lego_{tag}_linux_{arch}.tar.gz'
            binary = f'#!/bin/sh\necho "{component} version 1.2.3"\n'.encode()
            content = io.BytesIO()
            if component == 'xray':
                with zipfile.ZipFile(content, 'w') as archive:
                    archive.writestr('xray', binary)
            elif component in ('sing-box', 'lego'):
                with tarfile.open(fileobj=content, mode='w:gz') as archive:
                    info = tarfile.TarInfo(('release/' if component == 'sing-box' else '') + component)
                    info.size = len(binary)
                    archive.addfile(info, io.BytesIO(binary))
            else:
                content.write(binary)
            payload = content.getvalue()
            digest = hashlib.sha256(payload).hexdigest()
            url = f'https://github.com/{repository}/releases/download/{tag}/{name}'
            store(url, payload)
            asset = {'name': name, 'browser_download_url': url, 'digest': None}
            if component == 'sing-box':
                asset['digest'] = 'sha256:' + digest
            assets.append(asset)
            if component == 'xray':
                checksum_name = name + '.dgst'
                checksum_url = url + '.dgst'
                store(checksum_url, f'SHA2-256= {digest}\n'.encode())
                assets.append({'name': checksum_name, 'browser_download_url': checksum_url})
            sums.append(f'{digest}  {name}\n')
        if component == 'lego':
            name = 'lego_1.2.3_checksums.txt'
            url = f'https://github.com/{repository}/releases/download/{tag}/{name}'
            store(url, ''.join(sums).encode())
            assets.append({'name': name, 'browser_download_url': url})
        release = {'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': assets}
        release_paths[component] = store(f'https://api.github.com/repos/{repository}/releases/latest', json.dumps(release).encode())

    resolver = ['bash', project / 'scripts/resolve-offline-upstreams.sh']
    snapshot = root / 'snapshot'
    run(resolver + [snapshot], env=env)
    calls = (fixture / 'calls').read_text().splitlines()
    check(len([url for url in calls if url.endswith('/releases/latest')]) == 3, 'latest was not resolved exactly once per component')
    check(len(calls) == len(set(calls)), 'shared upstream checksums downloaded more than once')
    for arch in ('amd64', 'arm64'):
        rows = [line.split('\t') for line in (snapshot / arch / 'components.tsv').read_text().splitlines()]
        check(len(rows) == 3 and all(len(row) == 7 for row in rows), 'component TSV contract changed')
        check(all(row[2] == 'v1.2.3' for row in rows), 'actual tags were not persisted')
        check(all(hashlib.sha256((snapshot / arch / row[5]).read_bytes()).hexdigest() == row[4] for row in rows), 'snapshot content differs from manifest')
    run(resolver + [snapshot], success=False, env=env)
    check((fixture / 'calls').read_text().splitlines() == calls, 'existing snapshot triggered new resolution')
    failure = run(resolver + [root / 'download-failure'], success=False,
                  env=dict(env, OFFLINE_FETCH_FAIL='1', GH_TOKEN='fixture-secret-token'))
    check('fixture-secret-token' not in failure.stdout, 'download error disclosed API token')
    check(not (root / 'download-failure').exists(), 'failed download published a snapshot')

    for case in ('missing-arm64', 'prerelease', 'bad-digest', 'wrong-url'):
        metadata = release_paths['sing-box']
        original = metadata.read_bytes()
        data = json.loads(original)
        if case == 'missing-arm64':
            data['assets'] = [asset for asset in data['assets'] if '-arm64.' not in asset['name']]
        elif case == 'prerelease':
            data['prerelease'] = True
        elif case == 'bad-digest':
            data['assets'][0]['digest'] = 'sha256:' + '0' * 64
        else:
            data['assets'][0]['browser_download_url'] = 'https://example.com/substitute.tar.gz'
        metadata.write_text(json.dumps(data))
        run(resolver + [root / case], success=False, env=env)
        check(not (root / case).exists(), f'{case} published an incomplete snapshot')
        metadata.write_bytes(original)
    try:
        upstreams.checksum(('1' * 64 + '  file\n') * 2, 'file')
    except ValueError:
        pass
    else:
        raise AssertionError('duplicate checksum accepted')

    online = root / 'online'
    run(['bash', project / 'scripts/build-release.sh', online])
    helper = ['python3', project / 'scripts/offline-build/package.py']
    package = root / 'package'
    pool = package / 'apt/pool'
    pool.mkdir(parents=True)
    deb = pool / 'fixture_1.0_amd64.deb'
    deb.write_bytes(b'fixture package payload\n')
    digest = hashlib.sha256(deb.read_bytes()).hexdigest()
    (package / 'apt/Packages').write_text(f'Package: fixture\nVersion: 1.0\nArchitecture: amd64\nFilename: pool/{deb.name}\nSHA256: {digest}\n\n')
    uris = root / 'uris.txt'
    uris.write_text(f"'http://deb.debian.org/debian/pool/f/{deb.name}' {deb.name} {deb.stat().st_size} SHA256:{digest}\n")
    run(helper + ['prepare', package, online, snapshot / 'amd64', version, 'debian', '12', 'amd64', uris])
    run(helper + ['smoke', package])
    headers = (package / 'offline-manifest.tsv').read_text().splitlines()
    check(headers[:5] == ['schema_version\t1', f'version\t{version}', 'os\tdebian', 'os_version\t12', 'architecture\tamd64']
          and len(headers) == 6 and headers[5].startswith('built_at\t') and headers[5].endswith('Z'), 'offline manifest contract changed')
    for original in online.iterdir():
        check((package / original.name).read_bytes() == original.read_bytes(), f'online asset was rewritten: {original.name}')
    output = root / 'output'
    output.mkdir()
    run(helper + ['finalize', package, output, version, 'debian', '12', 'amd64'])
    archive_path = next(output.glob('*.tar.gz'))
    with tarfile.open(archive_path) as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        check(all(member.isfile() or member.isdir() for member in members), 'special archive member')
        check(all(not name.startswith(('/', './')) and '..' not in name.split('/') for name in names), 'unsafe archive path')
        check('vpsctl.sh' in names and 'offline-manifest.tsv' in names and 'apt/Packages' in names and 'README.txt' in names, 'extra outer directory or missing files')
        check(b'bash ./vpsctl.sh --offline-dir "$PWD"' in archive.extractfile('README.txt').read(), 'package usage instructions missing')
        checksums = archive.extractfile('SHA256SUMS').read().decode().splitlines()
        checksummed = []
        for line in checksums:
            expected, name = line.split('  ')
            check(hashlib.sha256(archive.extractfile(name).read()).hexdigest() == expected, f'archive checksum failed: {name}')
            checksummed.append(name)
        check(checksummed == sorted(member.name for member in members if member.isfile() and member.name != 'SHA256SUMS'), 'SHA256SUMS inventory incomplete or unsorted')
    run(helper + ['aggregate', output, version], success=False)
    check(not (output / 'vpsctl-offline-SHA256SUMS').exists(), 'partial matrix aggregate published')
    for os_name, os_version in (('debian', '12'), ('debian', '13'), ('ubuntu', '22.04'), ('ubuntu', '24.04')):
        for arch in ('amd64', 'arm64'):
            name = f'vpsctl-offline-{version}-{os_name}-{os_version}-{arch}.tar.gz'
            if not (output / name).exists():
                shutil.copyfile(archive_path, output / name)
    run(helper + ['aggregate', output, version], success=False)
    check(not (output / 'vpsctl-offline-SHA256SUMS').exists(), 'mislabeled matrix aggregate published')
    for os_name, os_version in (('debian', '12'), ('debian', '13'), ('ubuntu', '22.04'), ('ubuntu', '24.04')):
        for arch in ('amd64', 'arm64'):
            (package / 'offline-manifest.tsv').write_text(
                f'schema_version\t1\nversion\t{version}\nos\t{os_name}\nos_version\t{os_version}\narchitecture\t{arch}\n{headers[5]}\n')
            run(helper + ['finalize', package, output, version, os_name, os_version, arch])
    run(helper + ['aggregate', output, version])
    check(len((output / 'vpsctl-offline-SHA256SUMS').read_text().splitlines()) == 8, 'aggregate does not include all eight packages')
    components = package / 'components.tsv'
    original = components.read_bytes()
    components.write_text(components.read_text().replace('v1.2.3', 'v1.2.4'))
    run(helper + ['finalize', package, output, version, 'ubuntu', '24.04', 'arm64'])
    run(helper + ['aggregate', output, version], success=False)
    components.write_bytes(original)
    (package / 'unexpected-link').symlink_to('vpsctl.sh')
    run(helper + ['finalize', package, output, version, 'debian', '12', 'amd64'], success=False)
    (package / 'unexpected-link').unlink()
    mixed = root / 'mixed-release'
    shutil.copytree(online, mixed)
    for offline_archive in output.glob('*.tar.gz'):
        shutil.copyfile(offline_archive, mixed / offline_archive.name)
    (mixed / 'vpsctl-offline-SHA256SUMS').write_text('previous offline aggregate\n')
    run(['bash', project / 'scripts/build-release.sh', mixed])
    check(sorted(path.name for path in mixed.iterdir()) == sorted(path.name for path in online.iterdir()),
          'online rebuild did not replace a mixed release with only online assets')
    invalid = mixed / f'vpsctl-offline-{version}-debian-14-amd64.tar.gz'
    invalid.write_bytes(b'unrelated unsupported artifact\n')
    before = {path.name: path.read_bytes() for path in mixed.iterdir()}
    run(['bash', project / 'scripts/build-release.sh', mixed], success=False)
    check({path.name: path.read_bytes() for path in mixed.iterdir()} == before, 'invalid mixed output changed during rejection')
    binary = package / 'upstream/lego/lego_v1.2.3_linux_amd64.tar.gz'
    binary.write_text('corrupted\n')
    run(helper + ['smoke', package], success=False)
    (online / 'vpsctl.sh').write_text('corrupted\n')
    run(helper + ['online', online, version], success=False)
print('PASS: offline build snapshot, format, checksums and failure boundaries')
PY
