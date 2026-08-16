const std = @import("std");
const font = @import("font.zig");
const png = @import("png.zig");

const Color = [png.bytes_per_pixel]u8;
const BG_COLOR: Color = .{ 0, 0, 0 };
const FG_COLOR: Color = .{ 0, 255, 65 }; // Hacker Green

pub fn renderDashboardToPng(allocator: std.mem.Allocator, io: std.Io, ascii_text: []const u8, out_path: []const u8) !void {
    // 1. Dimensionen berechnen
    var lines: usize = 0;
    var max_cols: usize = 0;
    var current_cols: usize = 0;

    for (ascii_text) |char| {
        if (char == '\n') {
            lines += 1;
            if (current_cols > max_cols) max_cols = current_cols;
            current_cols = 0;
        } else {
            current_cols += 1;
        }
    }
    // A trailing line without its newline still gets drawn below, so it has to
    // count here -- otherwise the buffer comes up one row short and the drawing
    // loop writes past its end.
    if (current_cols > 0) {
        lines += 1;
        if (current_cols > max_cols) max_cols = current_cols;
    }

    const padding = 20;
    const img_width = (max_cols * font.glyph_width) + (padding * 2);
    const img_height = (lines * font.glyph_height) + (padding * 2);

    // 2. Pixelpuffer erstellen und mit Schwarz füllen
    const pixels = try allocator.alloc(u8, img_width * img_height * png.bytes_per_pixel);
    defer allocator.free(pixels);
    fill(pixels, BG_COLOR);

    // 3. Text rendern
    var cursor_x: usize = padding;
    var cursor_y: usize = padding;

    for (ascii_text) |char| {
        if (char == '\n') {
            cursor_x = padding;
            cursor_y += font.glyph_height;
            continue;
        }

        // Die Tabelle hat einen Eintrag pro Byte-Wert, ein Index kann also
        // nicht danebengehen.
        const glyph = font.vga_8x16[char];

        // Glyph in den Pixelbuffer zeichnen
        for (0..font.glyph_height) |y| {
            const row = glyph[y];
            for (0..font.glyph_width) |x| {
                // Prüfen ob das Bit gesetzt ist (von links nach rechts)
                const is_pixel_set = (row & (@as(u8, 1) << @intCast(7 - x))) != 0;
                if (is_pixel_set) {
                    const px_index = (cursor_y + y) * img_width + (cursor_x + x);
                    setPixel(pixels, px_index, FG_COLOR);
                }
            }
        }
        cursor_x += font.glyph_width;
    }

    // 4. Als PNG speichern
    try png.writeRgbFile(
        allocator,
        io,
        out_path,
        pixels,
        @intCast(img_width),
        @intCast(img_height),
    );
}

fn fill(pixels: []u8, color: Color) void {
    for (0..pixels.len / png.bytes_per_pixel) |i| setPixel(pixels, i, color);
}

fn setPixel(pixels: []u8, index: usize, color: Color) void {
    const at = index * png.bytes_per_pixel;
    @memcpy(pixels[at..][0..png.bytes_per_pixel], &color);
}

// ──────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────

const testing = std.testing;

test "a trailing line without a newline stays inside the buffer" {
    // The dashboard always ends in a newline, but nothing enforces that. Text
    // whose last line is unterminated used to size the buffer for one row
    // fewer than it drew, walking off the end -- caught by the bounds check in
    // Debug, silent corruption in ReleaseFast.
    //
    // The pipe matters here: it is the one glyph inked in all sixteen rows, so
    // it reaches the indices past the end. A line of letters alone leaves the
    // bottom rows blank and slips through.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const out = "vpsmon-renderer-test.png";
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};

    try renderDashboardToPng(testing.allocator, io, "an unterminated line ends |", out);
}
