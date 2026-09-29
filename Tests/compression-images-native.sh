#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${DROPSHELF_COMPRESSION_WORK_DIR:-${TMPDIR:-/tmp}/dropshelf-compression-tools}"
JPEG_PREFIX="${DROPSHELF_JPEG_PREFIX:-$WORK_ROOT/prefix/jpeg}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dropshelf-image-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CXX="${CXX:-clang++}"
EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS:-}"
APP_TOOLS="$ROOT/DropShelf.app/Contents/Resources/CompressionTools"
RESOURCE_TOOLS="$ROOT/Resources/CompressionTools"
IMAGE_VERIFY="${DROPSHELF_IMAGE_VERIFY:-$APP_TOOLS/bin/image-verify}"
JPEGTRAN="${DROPSHELF_JPEGTRAN:-$APP_TOOLS/bin/jpegtran}"
USING_APP_HELPER=0
if [[ -z "${DROPSHELF_IMAGE_VERIFY:-}" && -x "$IMAGE_VERIFY" ]]; then USING_APP_HELPER=1; fi
[[ -x "$IMAGE_VERIFY" ]] || IMAGE_VERIFY="$RESOURCE_TOOLS/bin/image-verify"
[[ -x "$JPEGTRAN" ]] || JPEGTRAN="$RESOURCE_TOOLS/bin/jpegtran"
[[ -x "$IMAGE_VERIFY" ]] || IMAGE_VERIFY="$WORK_ROOT/output/bin/image-verify"
[[ -x "$JPEGTRAN" ]] || JPEGTRAN="$WORK_ROOT/output/bin/jpegtran"
[[ -x "$JPEGTRAN" ]] || JPEGTRAN="$JPEG_PREFIX/bin/jpegtran"

if [[ $USING_APP_HELPER -eq 1 && "${DROPSHELF_VERIFY_IMAGE_SOURCE:-0}" != 1 && -z "$EXTRA_CXXFLAGS" ]]; then
  bash "$ROOT/Tests/check-compression-tools.sh" "$ROOT/DropShelf.app"
fi

if [[ "${DROPSHELF_VERIFY_IMAGE_SOURCE:-0}" == 1 || -n "$EXTRA_CXXFLAGS" ]]; then
  [[ -f "$JPEG_PREFIX/include/jpeglib.h" && -f "$JPEG_PREFIX/lib/libjpeg.a" ]] || {
    echo "Static libjpeg development prefix is unavailable: $JPEG_PREFIX" >&2; exit 1;
  }
  "$CXX" -std=c++17 -O2 $EXTRA_CXXFLAGS -mmacosx-version-min=13.0 -arch arm64 \
    -I"$JPEG_PREFIX/include" "$ROOT/Sources/Compression/ImageVerifier.cpp" \
    "$JPEG_PREFIX/lib/libjpeg.a" -lz -o "$WORK/image-verify"
  IMAGE_VERIFY="$WORK/image-verify"
fi
[[ -x "$IMAGE_VERIFY" ]] || { echo "Bundled image-verify helper is unavailable" >&2; exit 1; }
[[ -x "$JPEGTRAN" ]] || { echo "Bundled jpegtran helper is unavailable" >&2; exit 1; }

mkdir -p "$WORK/fixtures"
cp "$ROOT"/Tests/CompressionImages/Fixtures/*.jpg "$WORK/fixtures/"
"$JPEGTRAN" -copy all -progressive -outfile "$WORK/fixtures/progressive.jpg" "$WORK/fixtures/baseline.jpg"
"$JPEGTRAN" -copy all -optimize -outfile "$WORK/fixtures/baseline-optimized.jpg" "$WORK/fixtures/baseline.jpg"
"$JPEGTRAN" -copy all -optimize -outfile "$WORK/fixtures/gray-optimized.jpg" "$WORK/fixtures/gray.jpg"
"$JPEGTRAN" -copy all -optimize -outfile "$WORK/fixtures/cmyk-optimized.jpg" "$WORK/fixtures/cmyk.jpg"
python3 "$ROOT/Tests/CompressionImages/make_fixtures.py" "$WORK/fixtures" "$WORK/fixtures/baseline.jpg"
"$JPEGTRAN" -copy all -optimize -outfile "$WORK/fixtures/jpeg-metadata-optimized.jpg" "$WORK/fixtures/jpeg-metadata.jpg"

pass_count=0
pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
expect_ok() { local output; output=$("$IMAGE_VERIFY" "$@"); [[ "$output" == *'"ok":true'* ]] || { echo "$output"; return 1; }; }
expect_reject() { local output status; set +e; output=$("$IMAGE_VERIFY" "$@" 2>&1); status=$?; set -e; [[ $status -eq 2 && "$output" == *'"ok":false'* ]] || { echo "status=$status $output"; return 1; }; }
expect_resource_reject() { local output status; set +e; output=$("$IMAGE_VERIFY" "$@" 2>&1); status=$?; set -e; [[ $status -eq 2 && "$output" == *'"ok":false'* && "$output" == *'safety limit'* ]] || { echo "status=$status $output"; return 1; }; }

inspect_jpeg=$("$IMAGE_VERIFY" inspect "$WORK/fixtures/baseline.jpg")
[[ "$inspect_jpeg" == *'"ok":true'* && "$inspect_jpeg" == *'"kind":"jpeg"'* && "$inspect_jpeg" == *'"width":17'* && "$inspect_jpeg" == *'"height":11'* ]]; pass "inspect safe JPEG with dimensions"
inspect_png=$("$IMAGE_VERIFY" inspect "$WORK/fixtures/rgba8.png")
[[ "$inspect_png" == *'"ok":true'* && "$inspect_png" == *'"kind":"png"'* && "$inspect_png" == *'"width":7'* && "$inspect_png" == *'"height":5'* ]]; pass "inspect safe PNG with dimensions"
expect_ok compare "$WORK/fixtures/baseline.jpg" "$WORK/fixtures/baseline-optimized.jpg"; pass "JPEG optimized coefficients match"
expect_ok compare "$WORK/fixtures/baseline.jpg" "$WORK/fixtures/progressive.jpg"; pass "JPEG progressive layout retains coefficients"
expect_ok compare "$WORK/fixtures/gray.jpg" "$WORK/fixtures/gray-optimized.jpg"; pass "JPEG grayscale retains coefficients"
expect_ok compare "$WORK/fixtures/cmyk.jpg" "$WORK/fixtures/cmyk-optimized.jpg"; pass "JPEG CMYK retains coefficients"
expect_ok compare "$WORK/fixtures/jpeg-metadata.jpg" "$WORK/fixtures/jpeg-metadata-optimized.jpg"; pass "JPEG APP and COM metadata remain exact"
expect_reject compare "$WORK/fixtures/baseline.jpg" "$WORK/fixtures/changed.jpg"; pass "JPEG coefficient mutation rejected"
for unsafe in jpeg-mpo jpeg-hdr jpeg-c2pa jpeg-c2pa-fragmented jpeg-trailing jpeg-truncated; do expect_reject inspect "$WORK/fixtures/$unsafe.jpg"; done; pass "JPEG MPO HDR fragmented provenance trailing and malformed streams rejected"
expect_resource_reject inspect "$WORK/fixtures/jpeg-oversized.jpg"; pass "JPEG unsafe coefficient allocation is rejected during header preflight"

expect_ok compare "$WORK/fixtures/rgba8.png" "$WORK/fixtures/rgba8-recompressed.png"; pass "PNG hidden RGB and alpha retained"
expect_ok compare "$WORK/fixtures/rgba8.png" "$WORK/fixtures/rgba8-refiltered.png"; pass "PNG refiltered rows decode to identical samples"
expect_ok compare "$WORK/fixtures/gray1.png" "$WORK/fixtures/gray1-recompressed.png"; pass "PNG packed one-bit samples retained"
expect_ok compare "$WORK/fixtures/rgba16.png" "$WORK/fixtures/rgba16-recompressed.png"; pass "PNG sixteen-bit samples retained"
expect_ok compare "$WORK/fixtures/grayalpha8.png" "$WORK/fixtures/grayalpha8-recompressed.png"; pass "PNG grayscale alpha samples retained"
expect_ok compare "$WORK/fixtures/palette2.png" "$WORK/fixtures/palette2-recompressed.png"; pass "PNG palette and tRNS retained"
expect_ok compare "$WORK/fixtures/adam7.png" "$WORK/fixtures/adam7-recompressed.png"; pass "PNG Adam7 samples retained"
expect_reject compare "$WORK/fixtures/rgba8.png" "$WORK/fixtures/rgba8-pixel-change.png"; pass "PNG pixel mutation rejected"
expect_reject compare "$WORK/fixtures/rgba8.png" "$WORK/fixtures/rgba8-metadata-change.png"; pass "PNG metadata mutation rejected"
for unsafe in apng c2pa hdr unsafe unknown-critical bad-crc; do expect_reject inspect "$WORK/fixtures/$unsafe.png"; done; pass "PNG APNG provenance HDR unsafe chunks and CRC errors rejected"
expect_resource_reject inspect "$WORK/fixtures/huge.png"; pass "PNG cumulative allocation limit fails closed"

RESTORED="$WORK/fixtures/restored.png"
expect_ok restore-png "$WORK/fixtures/rgba8.png" "$WORK/fixtures/rgba8-optimized.png" "$RESTORED"
expect_ok compare "$WORK/fixtures/rgba8.png" "$RESTORED"; pass "PNG restore keeps original metadata and optimized IDAT"
[[ "$(stat -f '%Lp' "$RESTORED")" == 600 ]]; pass "PNG restore creates a private output"
expect_reject restore-png "$WORK/fixtures/rgba8.png" "$WORK/fixtures/rgba8-optimized.png" "$RESTORED"; pass "PNG restore refuses overwrite"
expect_reject inspect "$ROOT/README.md"; pass "unsupported input rejected"

[[ $pass_count -ge 19 ]]
echo "PASS: $pass_count native image verifier checks"
