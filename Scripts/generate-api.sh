#!/bin/sh
# Regenerates Packages/ImmichAPI/Sources/ImmichAPI/Generated from api/immich-openapi-specs.json.
# Run after updating the spec; commit the result.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG="$ROOT/Packages/ImmichAPI"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 -I "$PKG/Scripts/prepare-spec.py" "$ROOT/api/immich-openapi-specs.json" "$WORK/openapi.json"

swift run --package-path "$ROOT/Tools" swift-openapi-generator generate \
  --config "$PKG/openapi-generator-config.yaml" \
  --output-directory "$PKG/Sources/ImmichAPI/Generated" \
  "$WORK/openapi.json"

echo "Generated into $PKG/Sources/ImmichAPI/Generated"
