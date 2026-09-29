#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${DROPSHELF_COMPRESSION_WORK_DIR:-${TMPDIR:-/tmp}/dropshelf-compression-tools}"
PREFIX_DIR="$WORK_ROOT/prefix"
RESOURCE_BIN="$ROOT/Resources/CompressionTools/bin"
APP_TOOLS="$ROOT/DropShelf.app/Contents/Resources/CompressionTools"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dropshelf-pdf-native.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

QPDF_CLI="${DROPSHELF_QPDF:-}"
PDF_VERIFY="${DROPSHELF_PDF_VERIFY:-}"
if [[ -z "$QPDF_CLI" && -z "$PDF_VERIFY" && "${DROPSHELF_REBUILD_NATIVE_HELPERS:-0}" != "1" &&
      -x "$APP_TOOLS/bin/qpdf" && -x "$APP_TOOLS/bin/pdf-verify" ]]; then
  if [[ -f "$ROOT/Tests/check-compression-tools.sh" ]]; then
    bash "$ROOT/Tests/check-compression-tools.sh"
  fi
  python3 - "$APP_TOOLS/manifest.json" "$ROOT/Sources/Compression/PDFVerifier.cpp" \
    "$APP_TOOLS/bin/qpdf" "$APP_TOOLS/bin/pdf-verify" <<'PY'
import hashlib, json, pathlib, sys
manifest_path, source_path, qpdf_path, verifier_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text())
tools = {entry["name"]: entry for entry in manifest["tools"]}
assert "qpdf" in tools and "pdf-verify" in tools, "app compression manifest is incomplete"
assert "sourceSha256" in tools["pdf-verify"], "app compression manifest lacks the PDF verifier source hash"
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
assert digest(source_path) == tools["pdf-verify"]["sourceSha256"], "app PDF verifier was built from stale source"
assert digest(qpdf_path) == tools["qpdf"]["sha256"], "app qpdf hash does not match its manifest"
assert digest(verifier_path) == tools["pdf-verify"]["sha256"], "app PDF verifier hash does not match its manifest"
PY
  QPDF_CLI="$APP_TOOLS/bin/qpdf"
  PDF_VERIFY="$APP_TOOLS/bin/pdf-verify"
fi
if [[ -z "$QPDF_CLI" && -x "$RESOURCE_BIN/qpdf" ]]; then
  QPDF_CLI="$RESOURCE_BIN/qpdf"
elif [[ -z "$QPDF_CLI" && -x "$PREFIX_DIR/qpdf/bin/qpdf" ]]; then
  QPDF_CLI="$PREFIX_DIR/qpdf/bin/qpdf"
fi
if [[ -z "$QPDF_CLI" || ! -x "$QPDF_CLI" ]]; then
  echo "Missing bundled qpdf. Run script/build_compression_tools.sh or set DROPSHELF_QPDF." >&2
  exit 1
fi

if [[ -z "$PDF_VERIFY" && "${DROPSHELF_REBUILD_NATIVE_HELPERS:-0}" != "1" && -x "$RESOURCE_BIN/pdf-verify" ]]; then
  PDF_VERIFY="$RESOURCE_BIN/pdf-verify"
fi
if [[ -z "$PDF_VERIFY" ]]; then
  required_static=(
    "$PREFIX_DIR/qpdf/include/qpdf/QPDF.hh"
    "$PREFIX_DIR/qpdf/lib/libqpdf.a"
    "$PREFIX_DIR/zopfli/lib/libzopfli.a"
    "$PREFIX_DIR/jpeg/lib/libjpeg.a"
  )
  for dependency in "${required_static[@]}"; do
    if [[ ! -f "$dependency" ]]; then
      echo "Missing native verifier development dependency: $dependency" >&2
      echo "Run script/build_compression_tools.sh, use the bundled verifier, or set DROPSHELF_PDF_VERIFY." >&2
      exit 1
    fi
  done
  PDF_VERIFY="$WORK/pdf-verify"
  xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -target arm64-apple-macosx13.0 \
    -I"$PREFIX_DIR/qpdf/include" \
    "$ROOT/Sources/Compression/PDFVerifier.cpp" \
    "$PREFIX_DIR/qpdf/lib/libqpdf.a" \
    "$PREFIX_DIR/zopfli/lib/libzopfli.a" \
    "$PREFIX_DIR/jpeg/lib/libjpeg.a" \
    -lz -o "$PDF_VERIFY"
fi
if [[ ! -x "$PDF_VERIFY" ]]; then
  echo "PDF verifier is not executable: $PDF_VERIFY" >&2
  exit 1
fi

/usr/bin/sips -z 32 32 -s format jpeg "$ROOT/Resources/icon.png" --out "$WORK/fixture.jpg" >/dev/null
python3 "$ROOT/Tests/CompressionPDF/generate_fixtures.py" "$WORK/fixtures" "$WORK/fixture.jpg"

"$QPDF_CLI" --preserve-unreferenced --object-streams=generate --recompress-flate --compression-level=9 \
  "$WORK/fixtures/rich.pdf" "$WORK/fixtures/repacked.pdf"
"$QPDF_CLI" --linearize "$WORK/fixtures/linear-source.pdf" "$WORK/fixtures/linearized.pdf"
cp "$WORK/fixtures/linearized.pdf" "$WORK/fixtures/bad-linearized.pdf"
python3 - "$WORK/fixtures/bad-linearized.pdf" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
d = bytearray(p.read_bytes())
m = re.search(rb"/H\s*\[\s*(\d+)\s+(\d+)", d)
assert m
offset = int(m.group(1))
start = d.index(b"stream\n", offset) + len(b"stream\n")
d[start] ^= 0x01
p.write_bytes(d)
PY
"$QPDF_CLI" --preserve-unreferenced --object-streams=generate \
  "$WORK/fixtures/signed.pdf" "$WORK/fixtures/signed-object-stream.pdf"
"$QPDF_CLI" --encrypt secret owner 256 -- "$WORK/fixtures/rich.pdf" "$WORK/fixtures/encrypted.pdf"
"$QPDF_CLI" --preserve-unreferenced "$WORK/fixtures/no-id.pdf" "$WORK/fixtures/no-id-repacked.pdf"
python3 - "$WORK/fixtures/no-id-repacked.pdf" <<'PY'
import pathlib, re, sys
assert re.search(rb"/ID\s*\[\s*<[0-9a-fA-F]+>\s*<[0-9a-fA-F]+>\s*\]", pathlib.Path(sys.argv[1]).read_bytes())
PY

run_ok() {
  local expected="$1"; shift
  local json
  json="$($PDF_VERIFY "$@")"
  python3 - "$expected" "$json" <<'PY'
import json, sys
expected, raw = sys.argv[1], sys.argv[2]
value = json.loads(raw)
assert value.get("ok") is True, value
assert value.get("kind") == "pdf", value
if expected != "none":
    assert value.get("pages") == int(expected), value
PY
}

run_reject() {
  local reason="$1"; shift
  local json status
  set +e
  json="$($PDF_VERIFY "$@")"
  status=$?
  set -e
  test "$status" -eq 2
  python3 - "$reason" "$json" <<'PY'
import json, sys
expected, raw = sys.argv[1], sys.argv[2]
value = json.loads(raw)
assert value.get("ok") is False, value
assert value.get("reason") == expected, value
PY
}

run_ok 1 inspect "$WORK/fixtures/rich.pdf"
run_ok 1 inspect "$WORK/fixtures/repacked.pdf"
run_ok 1 inspect "$WORK/fixtures/linearized.pdf"
run_ok none compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/rich.pdf"
run_ok none compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/repacked.pdf"
run_ok none compare "$WORK/fixtures/linear-source.pdf" "$WORK/fixtures/linearized.pdf"

run_reject signed inspect "$WORK/fixtures/signed.pdf"
run_reject signed inspect "$WORK/fixtures/signed-object-stream.pdf"
run_reject signed inspect "$WORK/fixtures/trailer-signed.pdf"
run_reject encrypted inspect "$WORK/fixtures/encrypted.pdf"
run_reject xfa inspect "$WORK/fixtures/xfa.pdf"
run_reject provenance inspect "$WORK/fixtures/c2pa-relationship.pdf"
run_reject provenance inspect "$WORK/fixtures/c2pa-subtype.pdf"
run_reject unsupported-stream inspect "$WORK/fixtures/external-stream.pdf"
run_reject malformed inspect "$WORK/fixtures/broken.pdf"
run_reject malformed inspect "$WORK/fixtures/bad-content.pdf"
run_reject malformed inspect "$WORK/fixtures/bad-linearized.pdf"
run_reject malformed inspect "$WORK/fixtures/malformed-id.pdf"
run_reject content-mismatch compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/content-mutated.pdf"
run_reject content-mismatch compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/attachment-mutated.pdf"
run_reject content-mismatch compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/metadata-mutated.pdf"
run_reject content-mismatch compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/unused-mutated.pdf"
run_reject content-mismatch compare "$WORK/fixtures/rich.pdf" "$WORK/fixtures/jpeg-mutated.pdf"

cp "$WORK/fixtures/repacked.pdf" "$WORK/fixtures/repacked-first-id.pdf"
cp "$WORK/fixtures/repacked.pdf" "$WORK/fixtures/repacked-second-id.pdf"
python3 - "$WORK/fixtures/repacked-first-id.pdf" "$WORK/fixtures/repacked-second-id.pdf" <<'PY'
import pathlib, re, sys
def mutate(path, element, fill):
    p = pathlib.Path(path)
    d = p.read_bytes()
    match = re.search(rb"/ID\s*\[\s*<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*\]", d)
    assert match, "fixture did not contain a valid trailer ID"
    old = match.group(element)
    new = fill * len(old)
    assert old != new
    start, end = match.span(element)
    d = d[:start] + new + d[end:]
    p.write_bytes(d)

mutate(sys.argv[1], 1, b"1")
mutate(sys.argv[2], 2, b"2")
PY
run_reject content-mismatch compare "$WORK/fixtures/repacked.pdf" "$WORK/fixtures/repacked-first-id.pdf"
run_ok none compare "$WORK/fixtures/repacked.pdf" "$WORK/fixtures/repacked-second-id.pdf"
run_ok none compare "$WORK/fixtures/no-id.pdf" "$WORK/fixtures/no-id-repacked.pdf"

echo "PASS: native strict PDF verifier suite"
