//! The title bar Weaver draws in place of the native one, built on the Knots TitleBar.
//! The window must be created with `.decorations = .none`.
const builtin = @import("builtin");
const ui = @import("ui");
const brand_badge = @import("brand_badge.zig");
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const TitleBar = ui.component.TitleBar;

pub const height: f32 = if (builtin.os.tag == .macos) 28 else 32;
const bar = TitleBar{ .key = .str("titlebar"), .style = &.{ .height = .fixed(height), .gap = 0, .padding = .all(0), .background = .bg, .font_size = .sm }, .parts = .{ .button = &.{ .foreground = .dimmed, .hover = &.{ .background = .muted, .foreground = .text, .state_layer = 0 } } } };
const brand = Rect{ .key = .str("titlebar-brand"), .style = &.{ .direction = .row, .@"align" = .center, .gap = 8, .padding = .init(0, 0, 0, 14) } };

/// Opens the bar up to its centre, where the caller draws what the window shows.
pub fn open(ctx: *ui.Frame) !void {
    _ = try bar.open(ctx);
    _ = try brand.open(ctx);
    try brand_badge.render(ctx, 18);
    try ctx.e(Text{ .key = .str("brand"), .content = "weaver", .selectable = false, .style = comptime &.{ .wrap = false, .font_size = .sm, .foreground = .text } });
    try brand.close(ctx);
    // Spans the whole bar so its content sits in the middle of the window, whatever the sides hold.
    const extent = ctx.input().logical_extent;
    const centre = Rect{ .key = .str("titlebar-centre"), .style = &.{ .position = .absolute, .offset = .{ 0, 0 }, .width = .fixed(@floatFromInt(extent.width)), .height = .fixed(height), .direction = .row, .justify = .center, .@"align" = .center, .gap = 6, .overflow = .hidden } };
    _ = try centre.open(ctx);
}

pub fn close(ctx: *ui.Frame) !void {
    try (Rect{ .key = .str("titlebar-centre") }).close(ctx);
    try bar.close(ctx);
}
