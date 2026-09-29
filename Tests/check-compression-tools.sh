#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/DropShelf.app}"
python3 - "$ROOT" "$APP_PATH" <<'PY'
import hashlib, json, os, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
tools = app / 'Contents/Resources/CompressionTools'
if not tools.is_dir():
    raise SystemExit('Build DropShelf.app before checking bundled compression tools.')
manifest = json.loads((tools / 'manifest.json').read_text())
assert manifest['schemaVersion'] == 1
expected = {'qpdf': '12.4.2', 'jpegtran': '3.2.0', 'oxipng': '10.2.1', 'pdf-verify': '1.0.0', 'image-verify': '1.0.0'}
assert len(manifest['tools']) == len(expected)
assert {item['name'] for item in manifest['tools']} == set(expected)
for item in manifest['tools']:
    name = item['name']
    assert item['path'] == 'bin/' + name and item['version'] == expected[name]
    path = tools / item['path']
    assert path.is_file() and not path.is_symlink() and os.access(path, os.X_OK), name
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], name
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    description = subprocess.check_output(['file', '-b', str(path)], text=True)
    assert 'arm64' in description, (name, description)
    versions = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(path)], text=True)
    minimum = re.search(r'\bminos\s+(\d+(?:\.\d+){0,2})', versions)
    assert minimum, name
    version = tuple(int(part) for part in minimum.group(1).split('.'))
    assert (version + (0, 0))[:3] <= (13, 0, 0), (name, version)
    libraries = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    assert all(line.strip().split(' ')[0].startswith(('/usr/lib/', '/System/Library/')) for line in libraries), (name, libraries)
    if name in ('pdf-verify', 'image-verify'):
        source = root / 'Sources/Compression' / ('PDFVerifier.cpp' if name == 'pdf-verify' else 'ImageVerifier.cpp')
        assert hashlib.sha256(source.read_bytes()).hexdigest() == item['sourceSha256'], name + ' source is newer than its bundled helper'
    print('PASS: bundled ' + name + ' integrity, signing, architecture and compatibility')
license_files = list((tools / 'licenses').glob('*'))
assert len(license_files) >= 4
notice_files = list(tools.glob('*NOTICE*'))
assert notice_files
notices = '\n'.join(path.read_text(errors='replace') for path in notice_files + license_files if path.is_file())
assert 'Independent JPEG Group' in notices
print('PASS: compression engine notices and licenses are bundled')
PY
