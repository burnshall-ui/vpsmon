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
const Process = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    mem_mb: f64 = 0,
};

fn readFile(path: []const u8, buf: []u8) ![]u8 {
    const file = try fs.openFileAbsolute(path, .{});
    defer file.close();
    const n = try file.readAll(buf);
    return buf[0..n];
}

fn parseKb(line: []const u8) u64 {
    var t = mem.tokenizeScalar(u8, line, ' ');
    _ = t.next();
    return fmt.parseUnsigned(u64, t.next() orelse return 0, 10) catch 0;
}

fn getCpu() !CpuInfo {
    var buf: [4096]u8 = undefined;
    const data = try readFile("/proc/stat", &buf);
    var lines_iter = mem.splitScalar(u8, data, '\n');
    const first = lines_iter.first();
    if (!mem.startsWith(u8, first, "cpu ")) return error.ParseError;
    var f = mem.tokenizeScalar(u8, first, ' ');
    _ = f.next();
    var v: [10]u64 = [_]u64{0} ** 10;
    var i: usize = 0;
    while (f.next()) |s| {
        if (i >= 10) break;
        v[i] = fmt.parseUnsigned(u64, s, 10) catch 0;
        i += 1;
    }
    const idle = v[3] + v[4];
    var total: u64 = 0;
    for (v[0..i]) |x| total += x;
    if (total == 0) return CpuInfo{ .usage_pct = 0 };
    return CpuInfo{ .usage_pct = @as(f64, @floatFromInt(total - idle)) / @as(f64, @floatFromInt(total)) * 100.0 };
}

fn getMem() !MemInfo {
    var buf: [8192]u8 = undefined;
    const data = try readFile("/proc/meminfo", &buf);
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

const Statfs = extern struct {
    f_type: i64, f_bsize: i64, f_blocks: u64, f_bfree: u64, f_bavail: u64,
    f_files: u64, f_ffree: u64, f_fsid: [2]i32, f_namelen: i64, f_frsize: i64,
    f_flags: i64, f_spare: [4]i64,
};
extern "c" fn statfs(path: [*:0]const u8, buf: *Statfs) callconv(.C) c_int;

fn getDisk() !DiskInfo {
    var s: Statfs = undefined;
    if (statfs("/", &s) != 0) return error.StatfsFailed;
    const bs = @as(u64, @intCast(s.f_frsize));
    const tg = @as(f64, @floatFromInt(s.f_blocks)) * @as(f64, @floatFromInt(bs)) / (1024 * 1024 * 1024);
    const fg = @as(f64, @floatFromInt(s.f_bavail)) * @as(f64, @floatFromInt(bs)) / (1024 * 1024 * 1024);
    return DiskInfo{ .used_gb = tg - fg, .total_gb = tg, .pct = if (tg > 0) (tg - fg) / tg * 100 else 0 };
}

fn getNet() !NetInfo {
    var buf: [8192]u8 = undefined;
    const data = try readFile("/proc/net/dev", &buf);
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

fn getLoad() !LoadInfo {
    var buf: [256]u8 = undefined;
    const data = try readFile("/proc/loadavg", &buf);
    var f = mem.tokenizeScalar(u8, data, ' ');
    return LoadInfo{
        .one = fmt.parseFloat(f64, f.next() orelse return error.ParseError) catch 0,
        .five = fmt.parseFloat(f64, f.next() orelse return error.ParseError) catch 0,
        .fifteen = fmt.parseFloat(f64, f.next() orelse return error.ParseError) catch 0,
    };
}

fn getUptime() !UptimeInfo {
    var buf: [256]u8 = undefined;
    const data = try readFile("/proc/uptime", &buf);
    var tok = mem.tokenizeScalar(u8, data, ' ');
    const s_str = tok.next() orelse return error.ParseError;
    const dot = mem.indexOf(u8, s_str, ".") orelse s_str.len;
    const s = fmt.parseUnsigned(u64, s_str[0..dot], 10) catch 0;
    return UptimeInfo{ .days = s / 86400, .hours = (s % 86400) / 3600, .minutes = (s % 3600) / 60 };
}

fn getProcs(procs: []Process) !usize {
    var dir = fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: usize = 0;
    var sbuf: [4096]u8 = undefined;
    var cbuf: [256]u8 = undefined;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const is_pid = blk: {
            for (entry.name) |c| if (c < '0' or c > '9') break :blk false;
            break :blk entry.name.len > 0;
        };
        if (!is_pid) continue;

        var pb: [80]u8 = undefined;
        // Skip kernel threads (empty cmdline)
        const cp = fmt.bufPrint(&pb, "/proc/{s}/cmdline", .{entry.name}) catch continue;
        const cd = readFile(cp, &cbuf) catch continue;
        if (cd.len == 0) continue;

        const sp = fmt.bufPrint(&pb, "/proc/{s}/stat", .{entry.name}) catch continue;
        const sd = readFile(sp, &sbuf) catch continue;
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
            procs[count].mem_mb = @as(f64, @floatFromInt(rss)) * 4096.0 / (1024 * 1024);
            count += 1;
        }
    }
    mem.sort(Process, procs[0..count], {}, struct {
        fn lt(_: void, a: Process, b: Process) bool { return a.mem_mb > b.mem_mb; }
    }.lt);
    return @min(count, 5);
}

// ── Output ────────────────────────────────────────────────

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

pub fn main() !void {
    const w = std.io.getStdOut().writer();

    const cpu = getCpu() catch CpuInfo{ .usage_pct = 0 };
    const memory = getMem() catch MemInfo{ .used_gb = 0, .total_gb = 0, .pct = 0 };
    const disk = getDisk() catch DiskInfo{ .used_gb = 0, .total_gb = 0, .pct = 0 };
    const net = getNet() catch NetInfo{ .rx_mb = 0, .tx_mb = 0 };
    const load = getLoad() catch LoadInfo{ .one = 0, .five = 0, .fifteen = 0 };
    const uptime = getUptime() catch UptimeInfo{ .days = 0, .hours = 0, .minutes = 0 };
    var procs: [128]Process = undefined;
    for (&procs) |*p| p.* = Process{};
    const top_n = getProcs(&procs) catch 0;

    try printRule(w, '+', '-', '+', "[ SYSTEM STATUS ]");
    try w.writeAll("|                                                          |\n");

    // CPU
    {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const sw = s.writer();
        try sw.writeAll("  [");
        try printBar(sw, cpu.usage_pct, 16);
        try fmt.format(sw, "]  CPU  {d:5.1}%", .{cpu.usage_pct});
        try printPadded(w, s.getWritten());
    }
    // RAM
    {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const sw = s.writer();
        try sw.writeAll("  [");
        try printBar(sw, memory.pct, 16);
        try fmt.format(sw, "]  RAM  {d:5.1}%  {d:.1}/{d:.0} GB", .{ memory.pct, memory.used_gb, memory.total_gb });
        try printPadded(w, s.getWritten());
    }
    // DISK
    {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const sw = s.writer();
        try sw.writeAll("  [");
        try printBar(sw, disk.pct, 16);
        try fmt.format(sw, "]  DISK {d:5.1}%  {d:.0}/{d:.0} GB", .{ disk.pct, disk.used_gb, disk.total_gb });
        try printPadded(w, s.getWritten());
    }

    try w.writeAll("|                                                          |\n");

    // NET
    {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const sw = s.writer();
        if (net.tx_mb > 1024) {
            try fmt.format(sw, "  NET   ^ {d:.1} GB    v {d:.1} GB   (total)", .{ net.tx_mb / 1024, net.rx_mb / 1024 });
        } else {
            try fmt.format(sw, "  NET   ^ {d:.0} MB    v {d:.0} MB   (total)", .{ net.tx_mb, net.rx_mb });
        }
        try printPadded(w, s.getWritten());
    }
    // LOAD
    {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        try fmt.format(s.writer(), "  LOAD    {d:.2}   {d:.2}   {d:.2}", .{ load.one, load.five, load.fifteen });
        try printPadded(w, s.getWritten());
    }
    // UPTIME
    {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        try fmt.format(s.writer(), "  UPTIME  {d}d {d}h {d}m", .{ uptime.days, uptime.hours, uptime.minutes });
        try printPadded(w, s.getWritten());
    }

    try w.writeAll("|                                                          |\n");
    try printRule(w, '+', '-', '+', "[ TOP PROCESSES ]");
    try w.writeAll("|                                                          |\n");

    var pi: usize = 0;
    while (pi < top_n) : (pi += 1) {
        var b: [256]u8 = undefined;
        var s = std.io.fixedBufferStream(&b);
        const sw = s.writer();
        const p = procs[pi];
        const name = p.name[0..p.name_len];
        const show_len = @min(name.len, 28);
        try sw.writeAll("  ");
        try sw.writeAll(name[0..show_len]);
        var ni: usize = show_len;
        while (ni < 28) : (ni += 1) try sw.writeByte('.');
        if (p.mem_mb >= 1024) {
            try fmt.format(sw, " {d:7.1} GB", .{p.mem_mb / 1024});
        } else {
            try fmt.format(sw, " {d:7.0} MB", .{p.mem_mb});
        }
        try printPadded(w, s.getWritten());
    }

    try w.writeAll("|                                                          |\n");
    try printRule(w, '+', '-', '+', "");
}
