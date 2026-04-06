const std = @import("std");
const zigimg = @import("zigimg");
const font = @import("font.zig");

const Color = zigimg.color.Rgba32;
const BG_COLOR = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const FG_COLOR = Color{ .r = 0, .g = 255, .b = 65, .a = 255 }; // Hacker Green

pub fn renderDashboardToPng(allocator: std.mem.Allocator, ascii_text: []const u8, out_path: []const u8) !void {
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
    
    const padding = 20;
    const img_width = (max_cols * font.glyph_width) + (padding * 2);
    const img_height = (lines * font.glyph_height) + (padding * 2);

    // 2. Bild erstellen und mit Schwarz füllen
    var img = try zigimg.Image.create(allocator, img_width, img_height, .rgba32);
    defer img.deinit();
    
    for (img.pixels.rgba32) |*pixel| {
        pixel.* = BG_COLOR;
    }

    // 3. Text rendern
    var cursor_x: usize = padding;
    var cursor_y: usize = padding;

    for (ascii_text) |char| {
        if (char == '\n') {
            cursor_x = padding;
            cursor_y += font.glyph_height;
            continue;
        }

        // ASCII Fallback
        const safe_char = if (char < 256) char else '?';
        const glyph = font.vga_8x16[safe_char];

        // Glyph in den Pixelbuffer zeichnen
        var y: usize = 0;
        while (y < font.glyph_height) : (y += 1) {
            const row = glyph[y];
            var x: usize = 0;
            while (x < font.glyph_width) : (x += 1) {
                // Prüfen ob das Bit gesetzt ist (von links nach rechts)
                const is_pixel_set = (row & (@as(u8, 1) << @intCast(7 - x))) != 0;
                if (is_pixel_set) {
                    const px_index = (cursor_y + y) * img_width + (cursor_x + x);
                    img.pixels.rgba32[px_index] = FG_COLOR;
                }
            }
        }
        cursor_x += font.glyph_width;
    }

    // 4. Als PNG speichern
    var write_buffer: [8192]u8 = undefined;
    try img.writeToFilePath(allocator, out_path, &write_buffer, .{ .png = .{} });
}
