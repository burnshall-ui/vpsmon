const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;

const W = 56; // inner width

const CpuInfo = struct { usage_pct: f64 };
const MemInfo = struct { used_gb: f64, total_gb: f64, pct: f64 };
const DiskInfo = struct { used_gb: f64, total_gb: f64, pct: f64 };
const NetInfo = struct { rx_mb: f64, tx_mb: f64 };
const LoadInfo = struct { one: f64, five: f64, fifteen: f64 };
const UptimeInfo = struct { days: u64, hours: u64, minutes: u64 };
const AiInfo = struct { total: u64, input: u64, output: u64, cache: u64, calls: u64 };
const Process = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    mem_mb: f64 = 0,
};

fn readFile(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    return std.Io.Dir.cwd().readFile(io, path, buf);
}

fn parseKb(line: []const u8) u64 {
    var t = mem.tokenizeScalar(u8, line, ' ');
    _ = t.next();
    return fmt.parseUnsigned(u64, t.next() orelse return 0, 10) catch 0;
}

const CpuTimes = struct { idle: u64, total: u64 };

fn readCpuTimes(io: std.Io) !CpuTimes {
    var buf: [8192]u8 = undefined;
    const data = try readFile(io, "/proc/stat", &buf);
    var lines_iter = mem.splitScalar(u8, data, '\n');
    const first = lines_iter.first();
    if (!mem.startsWith(u8, first, "cpu ")) return error.ParseError;
    var f = mem.tokenizeScalar(u8, first, ' ');
    _ = f.next();
    // user nice system idle iowait irq softirq steal guest guest_nice
    var v: [10]u64 = [_]u64{0} ** 10;
    var i: usize = 0;
    while (f.next()) |s| {
        if (i >= 10) break;
        v[i] = fmt.parseUnsigned(u64, s, 10) catch 0;
        i += 1;
    }
    const idle = v[3] + v[4];
    var total: u64 = 0;
    // guest/guest_nice are already included in user/nice
    for (v[0..@min(i, 8)]) |x| total += x;
    return CpuTimes{ .idle = idle, .total = total };
}

fn getCpu(io: std.Io) !CpuInfo {
    // /proc/stat counters are cumulative since boot; usage needs the
    // delta between two snapshots.
    const a = try readCpuTimes(io);
    io.sleep(.fromMilliseconds(500), .awake) catch {};
    const b = try readCpuTimes(io);
    if (b.total <= a.total) return CpuInfo{ .usage_pct = 0 };
    const dt = b.total - a.total;
    const di = b.idle -| a.idle;
    const busy = if (dt > di) dt - di else 0;
    return CpuInfo{ .usage_pct = @as(f64, @floatFromInt(busy)) / @as(f64, @floatFromInt(dt)) * 100.0 };
}

fn getMem(io: std.Io) !MemInfo {
    var buf: [8192]u8 = undefined;
    const data = try readFile(io, "/proc/meminfo", &buf);
    var tk: u64 = 0;
    var ak: u64 = 0;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (mem.startsWith(u8, l, "MemTotal:")) tk = parseKb(l);
        if (mem.startsWith(u8, l, "MemAvailable:")) ak = parseKb(l);
    }
    const uk = if (tk > ak) tk - ak else 0;
    return MemInfo{
        .used_gb = @as(f64, @floatFromInt(uk)) / 1048576.0,
        .total_gb = @as(f64, @floatFromInt(tk)) / 1048576.0,
        .pct = if (tk > 0) @as(f64, @floatFromInt(uk)) / @as(f64, @floatFromInt(tk)) * 100.0 else 0,
    };
}

const builtin = @import("builtin");

const Statfs = if (builtin.os.tag == .macos) extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
} else extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};
extern "c" fn statfs(path: [*:0]const u8, buf: *Statfs) callconv(.c) c_int;
extern "c" fn getpagesize() callconv(.c) c_int;
extern "c" fn time(tloc: ?*i64) callconv(.c) i64;
extern "c" fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;

fn getDisk() !DiskInfo {
    var s: Statfs = undefined;
    if (statfs("/", &s) != 0) return error.StatfsFailed;
    const bs: u64 = if (builtin.os.tag == .macos) s.f_bsize else @intCast(s.f_frsize);
    const tg = @as(f64, @floatFromInt(s.f_blocks)) * @as(f64, @floatFromInt(bs)) / (1024 * 1024 * 1024);
    const fg = @as(f64, @floatFromInt(s.f_bavail)) * @as(f64, @floatFromInt(bs)) / (1024 * 1024 * 1024);
    return DiskInfo{ .used_gb = tg - fg, .total_gb = tg, .pct = if (tg > 0) (tg - fg) / tg * 100 else 0 };
}

fn getNet(io: std.Io) !NetInfo {
    var buf: [8192]u8 = undefined;
    const data = try readFile(io, "/proc/net/dev", &buf);
    var rx: u64 = 0;
    var tx: u64 = 0;
    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = mem.trim(u8, line, " \t");
        if (mem.startsWith(u8, t, "lo:")) continue;
        const colon = mem.indexOf(u8, t, ":") orelse continue;
        if (colon == 0) continue;
        var f = mem.tokenizeScalar(u8, mem.trim(u8, t[colon + 1 ..], " "), ' ');
        const rs = f.next() orelse continue;
        var sk: usize = 0;
        while (sk < 7) : (sk += 1) _ = f.next();
        const ts = f.next() orelse continue;
        rx += fmt.parseUnsigned(u64, rs, 10) catch 0;
        tx += fmt.parseUnsigned(u64, ts, 10) catch 0;
    }
    return NetInfo{ .rx_mb = @as(f64, @floatFromInt(rx)) / (1024 * 1024), .tx_mb = @as(f64, @floatFromInt(tx)) / (1024 * 1024) };
}

fn getLoad(io: std.Io) !LoadInfo {
    var buf: [256]u8 = undefined;
    const data = try readFile(io, "/proc/loadavg", &buf);
    var f = mem.tokenizeScalar(u8, data, ' ');
    return LoadInfo{
        .one = fmt.parseFloat(f64, f.next() orelse return error.ParseError) catch 0,
        .five = fmt.parseFloat(f64, f.next() orelse return error.ParseError) catch 0,
        .fifteen = fmt.parseFloat(f64, f.next() orelse return error.ParseError) catch 0,
    };
}

fn getUptime(io: std.Io) !UptimeInfo {
    var buf: [256]u8 = undefined;
    const data = try readFile(io, "/proc/uptime", &buf);
    var tok = mem.tokenizeScalar(u8, data, ' ');
    const s_str = tok.next() orelse return error.ParseError;
    const dot = mem.indexOf(u8, s_str, ".") orelse s_str.len;
    const s = fmt.parseUnsigned(u64, s_str[0..dot], 10) catch 0;
    return UptimeInfo{ .days = s / 86400, .hours = (s % 86400) / 3600, .minutes = (s % 3600) / 60 };
}

fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// "2026-08-11T04:58:13.978Z" -> unix epoch seconds
fn parseIsoEpoch(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const y = fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = fmt.parseInt(i64, s[17..19], 10) catch return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

fn jsonU64(obj: []const u8, key: []const u8) u64 {
    var kb: [64]u8 = undefined;
    const pat = fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return 0;
    const idx = mem.indexOf(u8, obj, pat) orelse return 0;
    var p = idx + pat.len;
    while (p < obj.len and obj[p] == ' ') p += 1;
    var e = p;
    while (e < obj.len and obj[e] >= '0' and obj[e] <= '9') e += 1;
    if (e == p) return 0;
    return fmt.parseUnsigned(u64, obj[p..e], 10) catch 0;
}

// Sum model.completed token usage of the last 24h from OpenClaw
// trajectory logs (~/.openclaw/agents/*/sessions/*.trajectory.jsonl).
fn getAi(io: std.Io) AiInfo {
    var info = AiInfo{ .total = 0, .input = 0, .output = 0, .cache = 0, .calls = 0 };
    const alloc = std.heap.page_allocator;
    const cutoff = time(null) - 86400;
    const home = if (getenv("HOME")) |h| mem.span(h) else "/root";
    var pb: [512]u8 = undefined;
    const agents_path = fmt.bufPrint(&pb, "{s}/.openclaw/agents", .{home}) catch return info;
    var agents = std.Io.Dir.openDirAbsolute(io, agents_path, .{ .iterate = true }) catch return info;
    defer agents.close(io);
    var ai = agents.iterate();
    while (ai.next(io) catch null) |agent| {
        if (agent.kind != .directory) continue;
        var sb: [512]u8 = undefined;
        const sess_path = fmt.bufPrint(&sb, "{s}/sessions", .{agent.name}) catch continue;
        var sessions = agents.openDir(io, sess_path, .{ .iterate = true }) catch continue;
        defer sessions.close(io);
        var si = sessions.iterate();
        while (si.next(io) catch null) |ent| {
            if (ent.kind != .file) continue;
            if (!mem.endsWith(u8, ent.name, ".trajectory.jsonl")) continue;
            const st = sessions.statFile(io, ent.name, .{}) catch continue;
            if (@divFloor(st.mtime.nanoseconds, std.time.ns_per_s) < cutoff) continue;
            const data = sessions.readFileAlloc(io, ent.name, alloc, .limited(64 * 1024 * 1024)) catch continue;
            defer alloc.free(data);
            var lines = mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                if (mem.indexOf(u8, line, "\"type\":\"model.completed\"") == null) continue;
                const tsi = mem.indexOf(u8, line, "\"ts\":\"") orelse continue;
                const ts = parseIsoEpoch(line[tsi + 6 ..]) orelse continue;
                if (ts < cutoff) continue;
                const ui = mem.indexOf(u8, line, "\"usage\":{") orelse continue;
                const rest = line[ui + 9 ..];
                const end = mem.indexOfScalar(u8, rest, '}') orelse continue;
                const usage = rest[0..end];
                info.input += jsonU64(usage, "input");
                info.output += jsonU64(usage, "output");
                info.cache += jsonU64(usage, "cacheRead");
                info.total += jsonU64(usage, "total");
                info.calls += 1;
            }
        }
    }
    return info;
}

fn getProcs(io: std.Io, procs: []Process) !usize {
    var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var count: usize = 0;
    var sbuf: [4096]u8 = undefined;
    var cbuf: [256]u8 = undefined;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const is_pid = blk: {
            for (entry.name) |c| if (c < '0' or c > '9') break :blk false;
            break :blk entry.name.len > 0;
        };
        if (!is_pid) continue;

        var pb: [80]u8 = undefined;
        // Skip kernel threads (empty cmdline)
        const cp = fmt.bufPrint(&pb, "/proc/{s}/cmdline", .{entry.name}) catch continue;
        const cd = readFile(io, cp, &cbuf) catch continue;
        if (cd.len == 0) continue;

        const sp = fmt.bufPrint(&pb, "/proc/{s}/stat", .{entry.name}) catch continue;
        const sd = readFile(io, sp, &sbuf) catch continue;
        const op = mem.indexOf(u8, sd, "(") orelse continue;
        const clp = mem.lastIndexOf(u8, sd, ")") orelse continue;
        if (clp <= op or clp + 2 >= sd.len) continue;

        // Get nice name from cmdline
        var name_src = cd;
        // cmdline is null-separated; take first arg
        if (mem.indexOf(u8, cd, &[_]u8{0})) |z| name_src = cd[0..z];
        // Strip path
        if (mem.lastIndexOf(u8, name_src, "/")) |slash| name_src = name_src[slash + 1 ..];

        // Parse RSS from stat
        const after = sd[clp + 2 ..];
        var fields = mem.tokenizeScalar(u8, after, ' ');
        var fi: usize = 0;
        var rss: u64 = 0;
        while (fields.next()) |fv| {
            if (fi == 21) rss = fmt.parseUnsigned(u64, fv, 10) catch 0;
            fi += 1;
        }

        if (count < procs.len) {
            const cl = @min(name_src.len, 127);
            @memcpy(procs[count].name[0..cl], name_src[0..cl]);
            procs[count].name_len = cl;
            procs[count].mem_mb = @as(f64, @floatFromInt(rss)) * @as(f64, @floatFromInt(getpagesize())) / (1024 * 1024);
            count += 1;
        }
    }
    mem.sort(Process, procs[0..count], {}, struct {
        fn lt(_: void, a: Process, b: Process) bool {
            return a.mem_mb > b.mem_mb;
        }
    }.lt);
    return @min(count, 5);
}

// ── Output ────────────────────────────────────────────────

fn fmtTok(buf: []u8, v: u64) []const u8 {
    const f = @as(f64, @floatFromInt(v));
    if (v >= 1_000_000) return fmt.bufPrint(buf, "{d:.1}M", .{f / 1_000_000.0}) catch "?";
    if (v >= 1_000) return fmt.bufPrint(buf, "{d:.1}k", .{f / 1_000.0}) catch "?";
    return fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

fn printBar(w: anytype, pct: f64, width: usize) !void {
    const filled = @as(usize, @intFromFloat(@min(pct, 100.0) / 100.0 * @as(f64, @floatFromInt(width))));
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) try w.writeByte('#') else try w.writeByte('=');
    }
}

fn printPadded(w: anytype, content: []const u8) !void {
    try w.writeAll("| ");
    try w.writeAll(content);
    if (content.len < W) {
        var i: usize = content.len;
        while (i < W) : (i += 1) try w.writeByte(' ');
    }
    try w.writeAll(" |\n");
}

fn printRule(w: anytype, left: u8, fill: u8, right: u8, title: []const u8) !void {
    try w.writeByte(left);
    const total = W + 2;
    if (title.len == 0) {
        var i: usize = 0;
        while (i < total) : (i += 1) try w.writeByte(fill);
    } else {
        const pre = (total - title.len) / 2;
        const post = total - title.len - pre;
        var i: usize = 0;
        while (i < pre) : (i += 1) try w.writeByte(fill);
        try w.writeAll(title);
        i = 0;
        while (i < post) : (i += 1) try w.writeByte(fill);
    }
    try w.writeByte(right);
    try w.writeByte('\n');
}

pub fn gatherAndPrintStats(io: std.Io, w: *std.Io.Writer) !void {
    const cpu = getCpu(io) catch CpuInfo{ .usage_pct = 0 };
    const memory = getMem(io) catch MemInfo{ .used_gb = 0, .total_gb = 0, .pct = 0 };
    const disk = getDisk() catch DiskInfo{ .used_gb = 0, .total_gb = 0, .pct = 0 };
    const net = getNet(io) catch NetInfo{ .rx_mb = 0, .tx_mb = 0 };
    const load = getLoad(io) catch LoadInfo{ .one = 0, .five = 0, .fifteen = 0 };
    const uptime = getUptime(io) catch UptimeInfo{ .days = 0, .hours = 0, .minutes = 0 };
    var procs: [128]Process = undefined;
    for (&procs) |*p| p.* = Process{};
    const top_n = getProcs(io, &procs) catch 0;
    const ai = getAi(io);

    try printRule(w, '+', '-', '+', "[ SYSTEM STATUS ]");
    try w.writeAll("|                                                          |\n");

    // CPU
    {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        const sw = &s;
        try sw.writeAll("  [");
        try printBar(sw, cpu.usage_pct, 16);
        try sw.print("]  CPU  {d:5.1}%", .{cpu.usage_pct});
        try printPadded(w, s.buffered());
    }
    // RAM
    {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        const sw = &s;
        try sw.writeAll("  [");
        try printBar(sw, memory.pct, 16);
        try sw.print("]  RAM  {d:5.1}%  {d:.1}/{d:.0} GB", .{ memory.pct, memory.used_gb, memory.total_gb });
        try printPadded(w, s.buffered());
    }
    // DISK
    {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        const sw = &s;
        try sw.writeAll("  [");
        try printBar(sw, disk.pct, 16);
        try sw.print("]  DISK {d:5.1}%  {d:.0}/{d:.0} GB", .{ disk.pct, disk.used_gb, disk.total_gb });
        try printPadded(w, s.buffered());
    }

    try w.writeAll("|                                                          |\n");

    // NET
    {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        const sw = &s;
        if (net.tx_mb > 1024) {
            try sw.print("  NET   ^ {d:.1} GB    v {d:.1} GB   (total)", .{ net.tx_mb / 1024, net.rx_mb / 1024 });
        } else {
            try sw.print("  NET   ^ {d:.0} MB    v {d:.0} MB   (total)", .{ net.tx_mb, net.rx_mb });
        }
        try printPadded(w, s.buffered());
    }
    // LOAD
    {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        try s.print("  LOAD    {d:.2}   {d:.2}   {d:.2}", .{ load.one, load.five, load.fifteen });
        try printPadded(w, s.buffered());
    }
    // UPTIME
    {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        try s.print("  UPTIME  {d}d {d}h {d}m", .{ uptime.days, uptime.hours, uptime.minutes });
        try printPadded(w, s.buffered());
    }

    try w.writeAll("|                                                          |\n");
    try printRule(w, '+', '-', '+', "[ AI / OPENCLAW ]");
    try w.writeAll("|                                                          |\n");
    if (ai.calls == 0) {
        try printPadded(w, "  no model calls in the last 24h");
    } else {
        var b1: [256]u8 = undefined;
        var s1: std.Io.Writer = .fixed(&b1);
        var t: [32]u8 = undefined;
        try s1.print("  TOKENS  {s} / 24h   ({d} calls)", .{ fmtTok(&t, ai.total), ai.calls });
        try printPadded(w, s1.buffered());
        var b2: [256]u8 = undefined;
        var s2: std.Io.Writer = .fixed(&b2);
        var t1: [32]u8 = undefined;
        var t2: [32]u8 = undefined;
        var t3: [32]u8 = undefined;
        try s2.print("          in {s}   out {s}   cache {s}", .{ fmtTok(&t1, ai.input), fmtTok(&t2, ai.output), fmtTok(&t3, ai.cache) });
        try printPadded(w, s2.buffered());
    }
    try w.writeAll("|                                                          |\n");
    try printRule(w, '+', '-', '+', "[ TOP PROCESSES ]");
    try w.writeAll("|                                                          |\n");

    var pi: usize = 0;
    while (pi < top_n) : (pi += 1) {
        var b: [256]u8 = undefined;
        var s: std.Io.Writer = .fixed(&b);
        const sw = &s;
        const p = procs[pi];
        const name = p.name[0..p.name_len];
        const show_len = @min(name.len, 28);
        try sw.writeAll("  ");
        try sw.writeAll(name[0..show_len]);
        var ni: usize = show_len;
        while (ni < 28) : (ni += 1) try sw.writeByte('.');
        if (p.mem_mb >= 1024) {
            try sw.print(" {d:7.1} GB", .{p.mem_mb / 1024});
        } else {
            try sw.print(" {d:7.0} MB", .{p.mem_mb});
        }
        try printPadded(w, s.buffered());
    }

    try w.writeAll("|                                                          |\n");
    try printRule(w, '+', '-', '+', "");
}

// ──────────────────────────────────────────────
// Tests
//
// Covers the hand-rolled parsers only. Everything else reads /proc or the
// filesystem, which the integration check in CI exercises instead.
// ──────────────────────────────────────────────

const testing = std.testing;

test "parseKb pulls the value out of a /proc/meminfo line" {
    try testing.expectEqual(@as(u64, 16384), parseKb("MemTotal:       16384 kB"));
    try testing.expectEqual(@as(u64, 0), parseKb("MemFree:            0 kB"));
    // Fields are space-separated with variable padding.
    try testing.expectEqual(@as(u64, 987), parseKb("Cached: 987 kB"));
}

test "parseKb returns 0 rather than failing on junk" {
    try testing.expectEqual(@as(u64, 0), parseKb(""));
    try testing.expectEqual(@as(u64, 0), parseKb("MemTotal:"));
    try testing.expectEqual(@as(u64, 0), parseKb("MemTotal: notanumber kB"));
}

test "daysFromCivil matches the proleptic Gregorian calendar" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    try testing.expectEqual(@as(i64, 20676), daysFromCivil(2026, 8, 11));
    // Leap day in a divisible-by-4 year.
    try testing.expectEqual(@as(i64, 19782), daysFromCivil(2024, 2, 29));
    // 1900 was not a leap year, 2000 was — the century rule both ways.
    try testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2) - daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 366), daysFromCivil(2001, 1, 1) - daysFromCivil(2000, 1, 1));
    try testing.expectEqual(@as(i64, 365), daysFromCivil(1901, 1, 1) - daysFromCivil(1900, 1, 1));
}

test "daysFromCivil handles dates before the epoch" {
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try testing.expect(daysFromCivil(1900, 1, 1) < 0);
}

test "parseIsoEpoch reads the timestamps OpenClaw writes" {
    try testing.expectEqual(@as(?i64, 0), parseIsoEpoch("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1786424293), parseIsoEpoch("2026-08-11T04:58:13.978Z"));
    // Milliseconds and the trailing Z are optional — only the first 19 bytes matter.
    try testing.expectEqual(@as(?i64, 1786424293), parseIsoEpoch("2026-08-11T04:58:13"));
}

test "parseIsoEpoch rejects anything it cannot parse" {
    try testing.expectEqual(@as(?i64, null), parseIsoEpoch(""));
    try testing.expectEqual(@as(?i64, null), parseIsoEpoch("2026-08-11"));
    try testing.expectEqual(@as(?i64, null), parseIsoEpoch("not-a-timestamp-at-all"));
}

test "jsonU64 finds a key in a trajectory line" {
    const obj =
        \\{"type":"model.completed","usage":{"input":1234,"output":56,"cache_read":7890}}
    ;
    try testing.expectEqual(@as(u64, 1234), jsonU64(obj, "input"));
    try testing.expectEqual(@as(u64, 56), jsonU64(obj, "output"));
    try testing.expectEqual(@as(u64, 7890), jsonU64(obj, "cache_read"));
}

test "jsonU64 tolerates whitespace after the colon" {
    try testing.expectEqual(@as(u64, 42), jsonU64("{\"n\":   42}", "n"));
}

test "jsonU64 returns 0 for a missing or non-numeric key" {
    const obj =
        \\{"input":1234,"model":"claude-opus-5"}
    ;
    try testing.expectEqual(@as(u64, 0), jsonU64(obj, "absent"));
    // A string value must not be read as a number.
    try testing.expectEqual(@as(u64, 0), jsonU64(obj, "model"));
    try testing.expectEqual(@as(u64, 0), jsonU64("", "input"));
}

test "fmtTok switches unit at the right thresholds" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", fmtTok(&buf, 0));
    try testing.expectEqualStrings("999", fmtTok(&buf, 999));
    try testing.expectEqualStrings("1.0k", fmtTok(&buf, 1_000));
    try testing.expectEqualStrings("999.9k", fmtTok(&buf, 999_949));
    try testing.expectEqualStrings("1.0M", fmtTok(&buf, 1_000_000));
    try testing.expectEqualStrings("12.3M", fmtTok(&buf, 12_345_678));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var out_buf: [16384]u8 = undefined;
    var out_writer: std.Io.Writer = .fixed(&out_buf);
    const w = &out_writer;

    try gatherAndPrintStats(io, w);
    const dashboard = out_writer.buffered();

    var args = init.args.iterate();
    _ = args.next(); // skip exe name

    if (args.next()) |out_path| {
        // PNG Modus
        const renderer = @import("renderer.zig");
        try renderer.renderDashboardToPng(allocator, io, dashboard, out_path);

        // stdout, not stderr: this is the success path, and callers redirecting
        // stdout away expect silence.
        var msg_buf: [512]u8 = undefined;
        var msg: std.Io.Writer = .fixed(&msg_buf);
        try msg.print("Dashboard saved to {s}\n", .{out_path});
        try std.Io.File.stdout().writeStreamingAll(io, msg.buffered());
    } else {
        // Terminal Modus
        try std.Io.File.stdout().writeStreamingAll(io, dashboard);
    }
}
