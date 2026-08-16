#!/bin/bash
# Renders vpsmon output as a hacker-green PNG image.
#
# The binary writes the PNG itself, so this is just a convenience wrapper for
# the default output path. `vpsmon <path>` does the same thing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VPSMON="$SCRIPT_DIR/zig-out/bin/vpsmon"
OUTPUT="${1:-/tmp/vpsmon.png}"

"$VPSMON" "$OUTPUT" > /dev/null

echo "$OUTPUT"
