---
name: vpsmon
description: VPS System Monitor — renders CPU, RAM, Disk, Network, Load, Uptime and Top Processes as a hacker-style ASCII dashboard image.
metadata: {"clawdbot":{"emoji":"🖥️","requires":{"bins":["vpsmon","convert"]}}}
---

# vpsmon

VPS monitoring tool written in Zig. Reads system metrics directly from `/proc/` and renders them as a hacker-green ASCII dashboard image.

## Commands

### Send status image via Telegram
```bash
/path/to/vpsmon/send_status.sh
```
Renders the dashboard as a PNG and sends it directly via Telegram Bot API. One command does everything.

### Text output only (no image)
```bash
vpsmon
```

### Render to PNG (no send)
```bash
/path/to/vpsmon/render.sh /tmp/vpsmon.png
```

## When to use

- When the user asks about **system status** ("How's the server?", "VPS status", "System check")
- As part of **cron jobs** for scheduled system reports

## Agent behavior

When the user asks for system status:
1. Run `send_status.sh` — it renders and sends the image automatically
2. Respond with only "SYSTEM STATUS" — no summary, no reasoning, no commentary
