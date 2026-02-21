#!/bin/bash
# Renders vpsmon output as a hacker-green PNG image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VPSMON="$SCRIPT_DIR/zig-out/bin/vpsmon"
OUTPUT="${1:-/tmp/vpsmon.png}"

# Get the ASCII output, escape XML special chars for pango
TEXT=$("$VPSMON" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

# Build pango markup
PANGO="<span font='DejaVu Sans Mono 14' foreground='#00FF41'>${TEXT}</span>"

# Render with pango for proper Unicode box-drawing support
convert \
  -background black \
  -density 96 \
  pango:"$PANGO" \
  -bordercolor black \
  -border 24x16 \
  "$OUTPUT"

echo "$OUTPUT"
