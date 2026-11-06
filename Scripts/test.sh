#!/bin/sh
# Runs the unit tests of every package that builds on macOS (all except PhotosAppUI).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for package in Core CloudCore ImmichAPI ImmichCloud Persistence Library Backup Sync MediaCache GridGeometry; do
  echo "== $package"
  swift test --package-path "$ROOT/Packages/$package" 2>&1 | grep -E "Test run with|error:|✘|recorded an issue" | grep -v "Generated/"
done
