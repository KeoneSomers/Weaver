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

pub fn render(frame: *ui.Frame) !void {
    const Canvas = ui.component.Canvas;
    const key = ui.Key.str("brand-mark");
    const measured = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, key.hash());
    if (measured.box.w() == 0) frame.requestRedraw();
    const scale = frame.ui().content_scale;
    const pixel = 1 / scale;
    var commands = artwork.commands;
    const outer = &commands[0].fill_rect;
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
    inner.corner_radius = .all(5.5 - pixel);
    // Two filled rounded rectangles form a continuous one-device-pixel rim.
    // This avoids the faint, uneven coverage of the previous half-pixel stroke.
    try frame.e(Canvas{ .key = key, .commands = &commands, .style = &.{ .width = .fixed(30), .height = .fixed(30) } });
}
