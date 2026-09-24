#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <directory> [directory ...]" >&2
    exit 2
fi

failed=0
for root in "$@"; do
    [[ -e "$root" ]] || continue
    while IFS= read -r artifact; do
        [[ -n "$artifact" ]] || continue
        echo "Bundled model artifact is forbidden: $artifact" >&2
        failed=1
    done < <(find "$root" \
        \( -type d \( -iname '*.mlpackage' -o -iname '*.mlmodelc' -o -iname 'weights' \) \
        -o -type f \( -iname '*.mlmodel' -o -iname '*.onnx' -o -iname '*.safetensors' \
        -o -iname '*.tflite' -o -iname '*.pt' -o -iname '*.pth' -o -iname '*.pb' \
        -o -iname '*.bin' \) \) -print)
done

if [[ $failed -ne 0 ]]; then
    echo "Build stopped. Optional model files must remain outside the app and installer." >&2
    exit 1
fi

echo "PASS: no model packages, compiled models, or weight artifacts are bundled"
