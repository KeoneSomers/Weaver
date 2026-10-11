//! SVG-backed sidebar badge rendered with native KnotsUI vectors.
const std = @import("std");
const ui = @import("ui");
const artwork = @import("brand_badge_svg.zig");

comptime {
    @setEvalBranchQuota(100_000);
    const source = @embedFile("brand_badge_svg");
    // Git's CRLF conversion must not invalidate an otherwise identical SVG.
    var normalized: [source.len]u8 = undefined;
    var length: usize = 0;
    for (source) |byte| {
        if (byte == '\r') continue;
        normalized[length] = byte;
        length += 1;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized[0..length], &digest, .{});
    if (!std.mem.eql(u8, &digest, &artwork.source_sha256))
        @compileError("Badge SVG changed: run python scripts/generate-badge.py and zig fmt src/brand_badge_svg.zig");
}

/// Draws the badge `size` logical pixels square; the artwork is 30.
pub fn render(frame: *ui.Frame, size: f32) !void {
    const Canvas = ui.component.Canvas;
    const key = ui.Key.str("brand-mark");
    const measured = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, key.hash());
    if (measured.box.w() == 0) frame.requestRedraw();
    const scale = frame.ui().content_scale;
    const pixel = 1 / scale;
    const k = size / 30;
    var commands = artwork.commands;
    var points: [commands.len][4][2]f32 = undefined;
    for (&commands, &points) |*command, *scaled| switch (command.*) {
        .fill_rect => |*rect| {
            rect.x *= k;
            rect.y *= k;
            rect.w *= k;
            rect.h *= k;
            rect.corner_radius = .all(0.3 * k);
        },
        .fill_convex_polygon => |*polygon| {
            for (polygon.points, scaled[0..polygon.points.len]) |point, *out| out.* = .{ point[0] * k, point[1] * k };
            polygon.points = scaled[0..polygon.points.len];
        },
        else => {},
    };
    const outer = &commands[0].fill_rect;
    outer.corner_radius = .all(5.5 * k);
    // Snap absolute edges, including a potentially fractional layout origin.
    const right = @round((measured.box.x() + outer.x + outer.w) * scale) / scale - measured.box.x();
    const bottom = @round((measured.box.y() + outer.y + outer.h) * scale) / scale - measured.box.y();
    outer.x = @round((measured.box.x() + outer.x) * scale) / scale - measured.box.x();
    outer.y = @round((measured.box.y() + outer.y) * scale) / scale - measured.box.y();
    outer.w = right - outer.x;
    outer.h = bottom - outer.y;
    const inner = &commands[1].fill_rect;
    inner.x = outer.x + pixel;
    inner.y = outer.y + pixel;
    inner.w = outer.w - 2 * pixel;
    inner.h = outer.h - 2 * pixel;
    inner.corner_radius = .all(5.5 * k - pixel);
    // Two filled rounded rectangles form a continuous one-device-pixel rim.
    // This avoids the faint, uneven coverage of the previous half-pixel stroke.
    try frame.e(Canvas{ .key = key, .commands = &commands, .style = &.{ .width = .fixed(size), .height = .fixed(size) } });
}
