#!/bin/bash
# Renders vpsmon and sends it directly via Telegram Bot API
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VPSMON="$SCRIPT_DIR/zig-out/bin/vpsmon"
OUTPUT="/tmp/vpsmon_$(date +%s).png"
BOT_TOKEN="8415499875:AAGFKuk5E_SuIDwr3ZK2a6KD0Wk4x6bX3Xc"
CHAT_ID="1050923765"

# 1. Get ASCII output, escape for pango
TEXT=$("$VPSMON" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

# 2. Render to PNG
PANGO="<span font='DejaVu Sans Mono 14' foreground='#00FF41'>${TEXT}</span>"
convert \
  -background black \
  -density 96 \
  pango:"$PANGO" \
  -bordercolor black \
  -border 24x16 \
  "$OUTPUT"

# 3. Send via Telegram Bot API
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
  -F "chat_id=${CHAT_ID}" \
  -F "photo=@${OUTPUT}" \
  \
  -o /dev/null

# 4. Cleanup
rm -f "$OUTPUT"

echo "OK"
