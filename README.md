<h1 align="center">v p s m o n</h1>

<p align="center">
  <strong>Zero-dependency VPS monitor that reports as an image, not a wall of text</strong><br/>
  <em>Reads <code>/proc</code> directly, renders hacker-green on black, ships it to your chat.</em>
</p>

<p align="center">
  <a href="https://github.com/burnshall-ui/vpsmon/actions/workflows/ci.yml"><img src="https://github.com/burnshall-ui/vpsmon/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/Zig-0.16-F7A41D?logo=zig&logoColor=white" alt="Zig 0.16" />
  <img src="https://img.shields.io/badge/Linux-%2Fproc-FCC624?logo=linux&logoColor=black" alt="Linux /proc" />
  <img src="https://img.shields.io/badge/Telegram-Bot%20API-26A5E4?logo=telegram&logoColor=white" alt="Telegram Bot API" />
  <img src="https://img.shields.io/badge/output-PNG-00FF41" alt="PNG output" />
  <img src="https://img.shields.io/badge/dependencies-none-00FF41" alt="No dependencies" />
  <img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" />
</p>

---

![screenshot](assets/screenshot.png)

A fast, zero-dependency VPS system monitor written in **Zig**. Reads metrics directly from `/proc/` and renders a hacker-style ASCII dashboard.

**The main purpose of this tool is to send a visual image of your system status instead of a plain text message.** It generates a PNG image with green-on-black terminal aesthetics — perfect for Telegram, WhatsApp, or Discord bot integrations.

## Features

- **CPU** usage with visual bar (sampled over a 500 ms window)
- **RAM** usage (used / total)
- **Disk** usage (used / total)
- **Network** traffic (total RX/TX)
- **Load** average (1/5/15 min)
- **Uptime** (days, hours, minutes)
- **Top 5 processes** by memory usage (user-space only, no kernel threads)
- **AI token usage** — last-24h [OpenClaw](https://openclaw.ai) token consumption (input / output / cache, model calls)
- **PNG rendering** built in — hacker green (`#00FF41`) on black, no external tool
- **Telegram integration** — one-command render + send via Bot API

## Requirements

- [Zig](https://ziglang.org/download/) >= 0.16.0

That is the whole list. The PNG encoder and the bitmap font are part of the
program, so rendering needs no image library, no font installed on the system,
and no `convert` on the box you deploy to.

## Build

```bash
git clone https://github.com/burnshall-ui/vpsmon.git
cd vpsmon

# Debug build
zig build

# Optimized release build
zig build -Doptimize=ReleaseFast

# Run directly
zig build run
```

The binary is at `zig-out/bin/vpsmon` (statically linked; ~0.5 MB after `strip`).

### Install to PATH

```bash
strip zig-out/bin/vpsmon
cp zig-out/bin/vpsmon ~/.local/bin/
```

## Tests

```bash
zig build test --summary all   # unit tests
zig fmt --check .              # formatting
```

The tests cover the hand-rolled parsers — `/proc/meminfo` fields, the civil-date
conversion, ISO timestamp parsing, the minimal JSON scraper, and the token
formatter's unit thresholds. Everything else reads `/proc`, which CI checks by
running the binary and asserting the dashboard still contains every section.

## Usage

### Terminal output
```bash
vpsmon
```

```
+--------------------[ SYSTEM STATUS ]---------------------+
|                                                          |
|   [####============]  CPU   25.3%                        |
|   [######==========]  RAM   38.1%  8.8/23 GB             |
|   [######==========]  DISK  39.8%  46/115 GB             |
|                                                          |
|   NET   ^ 2.9 GB    v 14.3 GB   (total)                  |
|   LOAD    0.76   0.63   0.51                             |
|   UPTIME  7d 9h 6m                                       |
|                                                          |
+--------------------[ AI / OPENCLAW ]---------------------+
|                                                          |
|   TOKENS  5.1M / 24h   (20 calls)                        |
|           in 1.9M   out 58.3k   cache 3.0M               |
|                                                          |
+--------------------[ TOP PROCESSES ]---------------------+
|                                                          |
|   openclaw-gateway............     394 MB                |
|   next-server (v16.1.6).......     174 MB                |
|   node........................      83 MB                |
|   python3.....................      42 MB                 |
|   redis-server................      12 MB                |
|                                                          |
+----------------------------------------------------------+
```

### Render as PNG

Pass an output path and the dashboard is written as a PNG instead of printed:

```bash
vpsmon /tmp/vpsmon.png
```

`./render.sh [path]` does the same and defaults the path to `/tmp/vpsmon.png`.

### Send via Telegram
```bash
# 1. Copy and configure
cp send_status.sh.example send_status.sh
# Edit send_status.sh — set BOT_TOKEN and CHAT_ID

# 2. Run
./send_status.sh
```

## OpenClaw Integration

vpsmon ships with an [OpenClaw](https://openclaw.ai) skill definition. To use it:

1. Copy `SKILL.md` to your OpenClaw workspace skills directory:
   ```bash
   mkdir -p ~/.openclaw/workspace/skills/vpsmon
   cp SKILL.md ~/.openclaw/workspace/skills/vpsmon/SKILL.md
   ```

2. Add exec approval for your agent:
   ```bash
   openclaw approvals allowlist add --agent main "/path/to/vpsmon/send_status.sh"
   ```

3. Add to your agent's `SOUL.md`:
   ```markdown
   ## VPS-Monitoring (vpsmon)
   When the user asks about system status, run `/path/to/vpsmon/send_status.sh`.
   Respond with "SYSTEM STATUS" only — the script sends the image via Telegram.
   ```

4. Restart the gateway and ask your agent: *"How's the server doing?"*

## Project Structure

```
vpsmon/
├── src/
│   ├── main.zig           # Core monitor — reads /proc/, outputs ASCII + tests
│   ├── renderer.zig       # Draws the dashboard into an RGB pixel buffer
│   ├── font.zig           # Embedded VGA 8x16 bitmap font
│   └── png.zig            # PNG encoder built on std + tests
├── render.sh              # Convenience wrapper around `vpsmon <path>`
├── send_status.sh.example # Template: render + send via Telegram
├── SKILL.md               # OpenClaw agent skill definition
├── assets/
│   └── screenshot.png     # Example output
├── .github/workflows/
│   └── ci.yml             # fmt check, build, tests, smoke test
├── build.zig              # Zig build configuration
├── build.zig.zon          # Zig package manifest
├── LICENSE                # MIT
└── README.md
```

## How it works

vpsmon reads Linux system metrics directly from the `/proc` filesystem:

| Metric | Source |
|--------|--------|
| CPU | `/proc/stat` |
| Memory | `/proc/meminfo` |
| Disk | `statfs("/")` |
| Network | `/proc/net/dev` |
| Load | `/proc/loadavg` |
| Uptime | `/proc/uptime` |
| Processes | `/proc/[pid]/stat` + `/proc/[pid]/cmdline` |
| AI tokens | `~/.openclaw/agents/*/sessions/*.trajectory.jsonl` |

CPU usage is computed from the delta of two `/proc/stat` snapshots taken 500 ms apart (the raw counters are cumulative since boot).

The AI section sums the `model.completed` events of the last 24 hours from OpenClaw's trajectory logs. If no OpenClaw installation is present, the section shows "no model calls in the last 24h".

### The image

The same ASCII the terminal gets is drawn glyph by glyph into an RGB buffer
using an embedded VGA 8x16 bitmap font, then encoded as a PNG by `src/png.zig`.

That encoder leans entirely on the standard library. `std.compress.flate`
handles deflate and, with its zlib container, writes the two-byte header and the
trailing Adler-32 checksum — the genuinely hard part of the format.
`std.hash.crc` supplies the per-chunk CRC. What is left is the container itself:
signature, `IHDR`, `IDAT`, `IEND`, and a filter byte in front of each scanline.

The output is 8-bit truecolour, no interlacing, filter type 0 on every row.
Choosing no filter is conformant — PNG lets an encoder pick per row — and costs
nothing here, because deflate already collapses the repeated border rows: a
dashboard compresses to under 1% of its raw size.

Since the dashboard is pure ASCII, only bytes 0x00–0xFF of the font are ever
needed; there is no UTF-8 shaping, and no font has to be installed.

## License

MIT
