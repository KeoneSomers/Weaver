const std = @import("std");
const ui = @import("ui");
const config = @import("config.zig");
pub const Accent = struct { name: []const u8, hex: []const u8 };
pub const accents = [_]Accent{
    .{ .name = "Lavender", .hex = "#B4A0FF" },
    .{ .name = "Indigo", .hex = "#8C9EFF" },
    .{ .name = "Sky", .hex = "#70B7E8" },
    .{ .name = "Teal", .hex = "#5CC8BE" },
    .{ .name = "Mint", .hex = "#7FD1A0" },
    .{ .name = "Lime", .hex = "#B5D36B" },
    .{ .name = "Amber", .hex = "#E8B95C" },
    .{ .name = "Coral", .hex = "#F0907A" },
    .{ .name = "Rose", .hex = "#F08CA8" },
    .{ .name = "Orchid", .hex = "#D68CE0" },
    .{ .name = "Clay", .hex = "#B07C66" },
    .{ .name = "Slate", .hex = "#94A0B4" },
};
pub fn accentName(hex: []const u8) []const u8 {
    for (accents) |accent| if (std.ascii.eqlIgnoreCase(accent.hex, hex)) return accent.name;
    return "Custom";
}
pub fn themeName(selected: config.Theme) []const u8 {
    return switch (selected) {
        .dark => "Dark",
        .carbon => "Carbon",
        .light => "Light",
        .graphite => "Graphite",
        .midnight => "Midnight",
        .forest => "Forest",
        .plum => "Plum",
        .nord => "Nord",
        .paper => "Paper",
        .ocean => "Ocean",
        .sand => "Sand",
    };
}
pub fn theme(selected: config.Theme, accent: []const u8, text_size: config.TextSize) ui.Theme {
    @setEvalBranchQuota(200_000);
    var value = switch (selected) {
        .dark => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#000000" }, .elevated = .{ .hex = "#0A0A0C" }, .muted = .{ .hex = "#17181B" }, .toned = .{ .hex = "#26272C" }, .dimmed = .{ .hex = "#8A8D97" }, .text = .{ .hex = "#E6E7EA" } }),
        .carbon => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#0C0D0F" }, .elevated = .{ .hex = "#191A1D" }, .muted = .{ .hex = "#27282D" }, .toned = .{ .hex = "#373940" }, .dimmed = .{ .hex = "#9699A3" } }),
        .graphite => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#1B1B1D" }, .elevated = .{ .hex = "#272729" }, .muted = .{ .hex = "#333336" }, .toned = .{ .hex = "#454549" }, .dimmed = .{ .hex = "#A5A5AB" }, .text = .{ .hex = "#E9E9EB" } }),
        .midnight => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#090A15" }, .elevated = .{ .hex = "#131528" }, .muted = .{ .hex = "#1E213D" }, .toned = .{ .hex = "#2D3156" }, .dimmed = .{ .hex = "#9A9EC4" }, .text = .{ .hex = "#E6E7F5" } }),
        .ocean => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#0B121B" }, .elevated = .{ .hex = "#15212E" }, .muted = .{ .hex = "#213143" }, .toned = .{ .hex = "#30465D" }, .dimmed = .{ .hex = "#96A9BC" } }),
        .forest => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#0B110F" }, .elevated = .{ .hex = "#151F1B" }, .muted = .{ .hex = "#202F29" }, .toned = .{ .hex = "#30443B" }, .dimmed = .{ .hex = "#95AEA3" }, .text = .{ .hex = "#E4ECE8" } }),
        .plum => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#130C13" }, .elevated = .{ .hex = "#201620" }, .muted = .{ .hex = "#302231" }, .toned = .{ .hex = "#453147" }, .dimmed = .{ .hex = "#B39EB5" }, .text = .{ .hex = "#EFE6EF" } }),
        .nord => comptime ui.Theme.parseWithBase(ui.Theme.dark, .{ .bg = .{ .hex = "#242933" }, .elevated = .{ .hex = "#2E3440" }, .muted = .{ .hex = "#3B4252" }, .toned = .{ .hex = "#4C566A" }, .dimmed = .{ .hex = "#A9B4C7" }, .text = .{ .hex = "#ECEFF4" } }),
        .light => comptime ui.Theme.parseWithBase(ui.Theme.light, .{ .bg = .{ .hex = "#E9EBEF" }, .muted = .{ .hex = "#F0F1F5" }, .toned = .{ .hex = "#DFE2E9" }, .dimmed = .{ .hex = "#677080" } }),
        .sand => comptime ui.Theme.parseWithBase(ui.Theme.light, .{ .bg = .{ .hex = "#EAE4D9" }, .elevated = .{ .hex = "#FFFCF6" }, .muted = .{ .hex = "#F2ECE2" }, .toned = .{ .hex = "#DDD3C4" }, .dimmed = .{ .hex = "#766A5C" } }),
        .paper => comptime ui.Theme.parseWithBase(ui.Theme.light, .{ .bg = .{ .hex = "#EDEDEA" }, .elevated = .{ .hex = "#FFFFFF" }, .muted = .{ .hex = "#F4F4F1" }, .toned = .{ .hex = "#E2E2DD" }, .dimmed = .{ .hex = "#6C6C66" }, .text = .{ .hex = "#1C1C1A" } }),
    };
    const step: f32 = switch (text_size) {
        .small => -1,
        .medium => 0,
        .large => 1,
        .extra_large => 2,
    };
    value.font_size = .{ 11 + step, 13 + step, 15 + step, 19 + step, 25 + step };
    value.radius = ui.Radius.all(8);
    value.primary = ui.Color.hex(accent) catch value.primary;
    const p = value.primary.value;
    const luminance = p[0] * 0.2126 + p[1] * 0.7152 + p[2] * 0.0722;
    value.on_primary = ui.Color.hex(if (luminance > 0.179) "#111216" else "#FFFFFF") catch unreachable;
    if (value.elevated.value[0] < 0.5) {
        value.success = ui.Color.hex("#8BC7A3") catch unreachable;
        value.@"error" = ui.Color.hex("#E69AA5") catch unreachable;
        value.warning = ui.Color.hex("#DCC08A") catch unreachable;
    }
    value.scrollbar_thickness = 5;
    value.scrollbar_track_color = ui.Color.transparent;
    value.scrollbar_thumb_color = value.toned;
    value.scrollbar_thumb_hover_color = value.dimmed;
    return value;
}

/// Opaque tint keeps selection consistent on both light and dark islands.
pub fn selection(value: ui.Theme) ui.Color.Input {
    var color = value.elevated;
    const tint: f32 = if (value.elevated.value[0] > 0.5) 0.12 else 0.045;
    for (0..3) |i| color.value[i] = value.elevated.value[i] * (1 - tint) + value.primary.value[i] * tint;
    return .{ .color = color };
}
