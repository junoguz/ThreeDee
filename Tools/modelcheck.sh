#!/bin/sh
# Builds ThreeDee's platform-independent format core for macOS and round-trips
# the given files through every importer/exporter.
#   Tools/modelcheck.sh part.stp scan.ply mesh.stl
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/threedee-modelcheck"
swiftc -O -o "$BIN" $(find "$ROOT/ThreeDee/Core" -name '*.swift') "$ROOT/Tools/ModelCheck/main.swift"
exec "$BIN" "$@"
