// Generated from assets/weaver-badge.svg by scripts/generate-badge.py.
const ui = @import("ui");
pub const source_sha256 = [32]u8{ 96, 10, 143, 251, 110, 233, 184, 97, 167, 107, 79, 26, 1, 248, 49, 48, 150, 199, 182, 103, 107, 145, 105, 32, 252, 28, 62, 219, 196, 186, 75, 88 };
pub const commands = [_]ui.component.Canvas.DrawCmd{
    .{ .fill_rect = .{ .x = 1.0, .y = 1.0, .w = 28.0, .h = 28.0, .corner_radius = .all(5.5), .color = (ui.Color.hex("#484850") catch unreachable).value } },
    .{ .fill_rect = .{ .x = 2.0, .y = 2.0, .w = 26.0, .h = 26.0, .corner_radius = .all(4.5), .color = (ui.Color.hex("#000000") catch unreachable).value } },
    .{ .fill_convex_polygon = .{ .points = &.{ .{ 8.7, 18.9 }, .{ 13.8, 14.8 }, .{ 13.8, 17.4 }, .{ 8.7, 21.3 } }, .color = (ui.Color.hex("#85888F") catch unreachable).value } },
    .{ .fill_convex_polygon = .{ .points = &.{ .{ 16.2, 18.9 }, .{ 21.3, 14.8 }, .{ 21.3, 17.4 }, .{ 16.2, 21.3 } }, .color = (ui.Color.hex("#85888F") catch unreachable).value } },
    .{ .fill_rect = .{ .x = 6.3, .y = 7.8, .w = 2.5, .h = 14.4, .corner_radius = .all(0.3), .color = (ui.Color.hex("#FFFFFF") catch unreachable).value } },
    .{ .fill_rect = .{ .x = 13.8, .y = 7.8, .w = 2.5, .h = 14.4, .corner_radius = .all(0.3), .color = (ui.Color.hex("#FFFFFF") catch unreachable).value } },
    .{ .fill_rect = .{ .x = 21.3, .y = 7.8, .w = 2.5, .h = 14.4, .corner_radius = .all(0.3), .color = (ui.Color.hex("#FFFFFF") catch unreachable).value } },
};
