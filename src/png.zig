//! A PNG encoder built on the standard library alone.
//!
//! Only what this program needs: 8-bit truecolour, no interlacing, filter
//! type 0 on every scanline. That is a fully conformant PNG -- the format
//! allows an encoder to pick any filter per row, and picking "none" every
//! time costs a little size and no correctness.
//!
//! The parts that would otherwise pull in a dependency all live in std:
//! deflate with a zlib wrapper comes from std.compress.flate (which writes
//! the two-byte header and the trailing Adler-32 itself), and the per-chunk
//! checksum from std.hash.crc.

const std = @import("std");
const flate = std.compress.flate;
const Crc32 = std.hash.crc.Crc32;
const Writer = std.Io.Writer;

/// The eight bytes every PNG starts with. The high bit and the CRLF/LF pair
/// exist so that a transfer mangling line endings is detectable.
pub const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const bytes_per_pixel = 3;

const bit_depth = 8;
const color_type_rgb = 2;

/// Encodes `pixels` (RGB, three bytes each, row-major) into a PNG file image.
/// Caller owns the returned bytes.
pub fn encodeRgb(
    gpa: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height * bytes_per_pixel);

    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = bit_depth;
    ihdr[9] = color_type_rgb;
    ihdr[10] = 0; // compression method: deflate, the only one PNG defines
    ihdr[11] = 0; // filter method: the only one PNG defines
    ihdr[12] = 0; // interlace: none
    try writeChunk(w, "IHDR", &ihdr);

    const idat = try deflateScanlines(gpa, pixels, width, height);
    defer gpa.free(idat);
    try writeChunk(w, "IDAT", idat);

    try writeChunk(w, "IEND", &.{});

    return out.toOwnedSlice();
}

/// Encodes and writes the file in one go.
pub fn writeRgbFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pixels: []const u8,
    width: u32,
    height: u32,
) !void {
    const bytes = try encodeRgb(gpa, pixels, width, height);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// length, type, payload, then a CRC-32 over type and payload -- but not over
/// the length, which is why the checksum starts after it.
fn writeChunk(w: *Writer, chunk_type: *const [4]u8, data: []const u8) Writer.Error!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(chunk_type);
    try w.writeAll(data);

    var crc: Crc32 = .init();
    crc.update(chunk_type);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// The IDAT payload: every scanline prefixed with its filter byte, the whole
/// stream deflated inside a zlib container.
fn deflateScanlines(
    gpa: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    // Compress.init asserts the output writer has a buffer of its own, so this
    // cannot start at zero capacity.
    var compressed: Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    errdefer compressed.deinit();

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    // These images are a few hundred kilobytes before compression and get sent
    // over the network, so the slowest setting is still instant and worth it.
    var compress = try flate.Compress.init(&compressed.writer, window, .zlib, .best);
    const cw = &compress.writer;

    const stride = @as(usize, width) * bytes_per_pixel;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        try cw.writeByte(0); // filter type 0: none
        try cw.writeAll(pixels[row * stride ..][0..stride]);
    }
    try compress.finish();

    return compressed.toOwnedSlice();
}

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

const testing = std.testing;

test "encodes the signature and a well-formed IHDR" {
    const pixels = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 }; // 2x2
    const png = try encodeRgb(testing.allocator, &pixels, 2, 2);
    defer testing.allocator.free(png);

    try testing.expectEqualSlices(u8, &signature, png[0..8]);

    // First chunk: length 13, type IHDR.
    try testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, png[8..12], .big));
    try testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[20..24], .big));
    try testing.expectEqual(@as(u8, bit_depth), png[24]);
    try testing.expectEqual(@as(u8, color_type_rgb), png[25]);

    // And it ends with an empty IEND whose CRC is the well-known constant.
    try testing.expectEqualSlices(u8, "IEND", png[png.len - 8 ..][0..4]);
    try testing.expectEqual(@as(u32, 0xAE426082), std.mem.readInt(u32, png[png.len - 4 ..][0..4], .big));
}

test "every chunk carries a checksum that verifies" {
    const pixels = [_]u8{0} ** (4 * 3);
    const png = try encodeRgb(testing.allocator, &pixels, 2, 2);
    defer testing.allocator.free(png);

    var i: usize = signature.len;
    var saw_ihdr = false;
    var saw_idat = false;
    var saw_iend = false;
    while (i < png.len) {
        const len = std.mem.readInt(u32, png[i..][0..4], .big);
        const chunk_type = png[i + 4 ..][0..4];
        const body = png[i + 4 ..][0 .. 4 + len]; // type and payload together
        const stored = std.mem.readInt(u32, png[i + 8 + len ..][0..4], .big);

        try testing.expectEqual(Crc32.hash(body), stored);

        if (std.mem.eql(u8, chunk_type, "IHDR")) saw_ihdr = true;
        if (std.mem.eql(u8, chunk_type, "IDAT")) saw_idat = true;
        if (std.mem.eql(u8, chunk_type, "IEND")) saw_iend = true;

        i += 12 + len; // length + type + payload + crc
    }
    try testing.expect(saw_ihdr and saw_idat and saw_iend);
    try testing.expectEqual(png.len, i); // chunks tile the file exactly
}

test "the image survives a round trip through inflate" {
    const width = 3;
    const height = 2;
    const pixels = [_]u8{
        1,  2,  3,  4,  5,  6,  7,  8,  9,
        10, 11, 12, 13, 14, 15, 16, 17, 18,
    };
    const png = try encodeRgb(testing.allocator, &pixels, width, height);
    defer testing.allocator.free(png);

    // Pull the IDAT payload back out.
    var idat: []const u8 = &.{};
    var i: usize = signature.len;
    while (i < png.len) {
        const len = std.mem.readInt(u32, png[i..][0..4], .big);
        if (std.mem.eql(u8, png[i + 4 ..][0..4], "IDAT")) idat = png[i + 8 ..][0..len];
        i += 12 + len;
    }
    try testing.expect(idat.len > 0);

    var in: std.Io.Reader = .fixed(idat);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .zlib, &window);
    const raw = try decompress.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(raw);

    const stride = width * bytes_per_pixel;
    try testing.expectEqual(@as(usize, height * (stride + 1)), raw.len);
    for (0..height) |row| {
        try testing.expectEqual(@as(u8, 0), raw[row * (stride + 1)]); // filter byte
        try testing.expectEqualSlices(
            u8,
            pixels[row * stride ..][0..stride],
            raw[row * (stride + 1) + 1 ..][0..stride],
        );
    }
}
