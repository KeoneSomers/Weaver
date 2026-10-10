const std = @import("std");
const ui = @import("ui");
const change_context = @import("change_context.zig");
const model = @import("model.zig");

const ChangeMenuActions = struct {
    file: model.File,
    index: usize,
    selected: *?usize,

    pub fn render(self: *const ChangeMenuActions, frame: *ui.Frame) anyerror!void {
        if ((try frame.interact(ui.component.Button{ .key = .str("select-change"), .label = self.file.status, .style = &.{ .height = .fixed(30) } })).clicked)
            self.selected.* = self.index;
    }
};

fn stepChanges(view: *ui.Context, now_ms: i64, raw: ui.input.Input, repository: []const u8, files: []const model.File, selected: *?usize) !void {
    var frame = try view.beginFrame(frameInput(now_ms, raw));
    defer frame.deinit();
    const root = ui.component.Rect{ .key = .str("changes"), .style = &.{ .width = .fixed(320), .height = .fixed(240), .direction = .column } };
    _ = try root.open(&frame);
    for (files, 0..) |file, i| {
        const menu = ui.component.ContextMenu(ChangeMenuActions){ .key = change_context.key(repository, file), .menu = .{ .file = file, .index = i, .selected = selected }, .style = &.{ .width = .fixed(200), .height = .fixed(40) } };
        _ = try menu.open(&frame);
        try frame.e(ui.component.Text{ .key = ui.Key.str("path").indexed(i), .content = file.path, .selectable = false });
        try menu.close(&frame);
    }
    try root.close(&frame);
    _ = try view.endFrame(&frame);
}

test "change menu survives a refreshed and reordered list and acts on the current row" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    const original = [_]model.File{.{ .path = "target.zig", .status = "Modified", .staged = false }};
    const refreshed = [_]model.File{
        .{ .path = "added.zig", .status = "Untracked", .staged = false },
        .{ .path = "target.zig", .status = "Conflict", .staged = false },
    };
    var selected: ?usize = null;
    var active: ?ui.Key = change_context.key("repo", original[0]);
    try stepChanges(&view, 0, .{ .pos = .{ 250, 200 } }, "repo", &original, &selected);
    try stepChanges(&view, 16, rightClick(.{ 50, 20 }), "repo", &original, &selected);
    try std.testing.expect(view.ui.state.get(.context_menu, active.?.hash()).?.open);
    change_context.reconcile(&view.ui.state, &active, "repo", &original, "repo", &refreshed);
    for (0..10) |i| {
        try stepChanges(&view, @intCast(32 + 16 * i), .{ .pos = .{ 60, 30 } }, "repo", &refreshed, &selected);
        try std.testing.expect(view.ui.state.get(.context_menu, active.?.hash()).?.open);
    }
    var click: ui.input.Input = .{ .pos = .{ 60, 30 } };
    click.mouse[@backingInt(ui.input.MouseButton.left)] = .{ .pressed = true, .released = true, .pressed_pos = click.pos, .released_pos = click.pos };
    try stepChanges(&view, 208, click, "repo", &refreshed, &selected);
    try std.testing.expectEqual(@as(?usize, 1), selected);
    try std.testing.expect(!view.ui.state.get(.context_menu, active.?.hash()).?.open);
}

test "change menu closes when its target disappears or changes repository or staged state" {
    const original = [_]model.File{.{ .path = "target.zig", .status = "Modified", .staged = false }};
    const staged = [_]model.File{.{ .path = "target.zig", .status = "Modified", .staged = true }};
    for (0..3) |i| {
        var view = try ui.Context.init(std.testing.allocator, .{});
        defer view.deinit();
        var selected: ?usize = null;
        var active: ?ui.Key = change_context.key("repo", original[0]);
        const menu_key = active.?;
        try stepChanges(&view, 0, .{ .pos = .{ 250, 200 } }, "repo", &original, &selected);
        try stepChanges(&view, 16, rightClick(.{ 50, 20 }), "repo", &original, &selected);
        try std.testing.expect(view.ui.state.get(.context_menu, menu_key.hash()).?.open);
        change_context.reconcile(&view.ui.state, &active, "repo", &original, if (i == 2) "other-repo" else "repo", if (i == 0) &.{} else if (i == 1) &staged else &original);
        try std.testing.expect(active == null);
        try std.testing.expect(!view.ui.state.get(.context_menu, menu_key.hash()).?.open);
    }
}

const MenuActions = struct {
    pub fn render(_: *const MenuActions, frame: *ui.Frame) anyerror!void {
        for (0..2) |i| _ = try frame.interact(ui.component.Button{ .key = ui.Key.str("menu-action").indexed(i), .label = if (i == 0) "First action" else "Second action", .style = &.{ .height = .fixed(30) } });
    }
};

fn frameInput(now_ms: i64, raw: ui.input.Input) ui.input.FrameInput {
    return .{
        .input = raw,
        .now_ms = now_ms,
        .delta_ns = 16 * std.time.ns_per_ms,
        .logical_extent = .{ .width = 320, .height = 240 },
        .physical_extent = .{ .width = 320, .height = 240 },
        .content_scale = 1,
    };
}

fn renderRows(frame: *ui.Frame, clipped: bool, popup_gap: f32) ![2]ui.component.Button.Response {
    const root = ui.component.Rect{ .key = .str("root"), .style = &.{ .width = .fixed(320), .height = .fixed(240), .direction = .column } };
    _ = try root.open(frame);
    const list = ui.component.Rect{ .key = .str("list"), .style = &.{ .width = .fixed(200), .height = .fixed(if (clipped) 40 else 80), .direction = .column, .overflow = .scroll_y } };
    _ = try list.open(frame);
    var responses: [2]ui.component.Button.Response = undefined;
    for (&responses, 0..) |*response, i| {
        const menu = ui.component.ContextMenu(MenuActions){ .key = ui.Key.str("menu").indexed(i), .menu = .{}, .style = &.{ .width = .grow(), .height = .fixed(40) }, .parts = .{ .popup = &.{ .gap = popup_gap } } };
        _ = try menu.open(frame);
        const button = ui.component.Button{ .key = ui.Key.str("row").indexed(i), .style = &.{ .width = .grow(), .height = .fixed(40), .padding = .all(8), .justify = .start } };
        response.* = try button.openResponse(frame);
        const tooltip = ui.component.Tooltip{ .key = ui.Key.str("tooltip").indexed(i), .content = "Full path", .placement = .bottom, .style = &.{ .width = .grow(), .height = .fixed(22) } };
        _ = try tooltip.open(frame);
        try frame.e(ui.component.Text{ .key = ui.Key.str("label").indexed(i), .content = "Path", .selectable = false });
        try tooltip.close(frame);
        try button.close(frame);
        try menu.close(frame);
    }
    try list.close(frame);
    try root.close(frame);
    return responses;
}

fn step(view: *ui.Context, now_ms: i64, raw: ui.input.Input, clipped: bool) ![2]ui.component.Button.Response {
    return stepWithGap(view, now_ms, raw, clipped, 0);
}

fn stepWithGap(view: *ui.Context, now_ms: i64, raw: ui.input.Input, clipped: bool, popup_gap: f32) ![2]ui.component.Button.Response {
    var frame = try view.beginFrame(frameInput(now_ms, raw));
    defer frame.deinit();
    const result = try renderRows(&frame, clipped, popup_gap);
    _ = try view.endFrame(&frame);
    return result;
}

fn rightClick(pos: [2]f64) ui.input.Input {
    var raw: ui.input.Input = .{ .pos = pos };
    // A full click can be delivered in one native event batch.
    raw.mouse[@backingInt(ui.input.MouseButton.right)] = .{ .pressed = true, .released = true, .pressed_pos = pos, .released_pos = pos };
    return raw;
}

test "row hover persists over its tooltip child across stationary frames" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    _ = try step(&view, 0, .{ .pos = .{ 250, 200 } }, false);
    for (0..60) |i| {
        const responses = try step(&view, @intCast(16 * (i + 1)), .{ .pos = .{ 50, 20 } }, false);
        try std.testing.expect(responses[0].hovered);
        try std.testing.expect(!responses[1].hovered);
        try std.testing.expect(view.ui.state.get(.tooltip, ui.Key.str("tooltip").indexed(0).hash()).?.hover_started_ms != null);
    }
    const padding = try step(&view, 1000, .{ .pos = .{ 4, 20 } }, false);
    try std.testing.expect(padding[0].hovered);
    const outside = try step(&view, 1016, .{ .pos = .{ 250, 200 } }, false);
    try std.testing.expect(!outside[0].hovered);
}

test "right click opens on first entry and persists through release and stationary frames" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    const key = ui.Key.str("menu").indexed(0);
    _ = try step(&view, 0, .{ .pos = .{ 250, 200 } }, false);
    _ = try step(&view, 16, rightClick(.{ 50, 20 }), false);
    try std.testing.expect(view.ui.state.get(.context_menu, key.hash()).?.open);
    for (0..10) |i| {
        _ = try step(&view, @intCast(32 + i * 16), .{ .pos = .{ 50, 20 } }, false);
        try std.testing.expect(view.ui.state.get(.context_menu, key.hash()).?.open);
    }
    // The popup covers the next row; it must not open that row's menu.
    _ = try step(&view, 208, rightClick(.{ 60, 50 }), false);
    try std.testing.expect(view.ui.state.get(.context_menu, key.hash()).?.open);
    try std.testing.expect(!view.ui.state.get(.context_menu, ui.Key.str("menu").indexed(1).hash()).?.open);
    _ = try step(&view, 224, .{ .pos = .{ 250, 200 }, .key_events = &.{.{ .key = .escape, .action = .press, .mods = .{} }} }, false);
    try std.testing.expect(!view.ui.state.get(.context_menu, key.hash()).?.open);
}

test "right click respects scroll clipping" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    _ = try step(&view, 0, .{ .pos = .{ 250, 200 } }, true);
    _ = try step(&view, 16, rightClick(.{ 50, 60 }), true);
    try std.testing.expect(!view.ui.state.get(.context_menu, ui.Key.str("menu").indexed(1).hash()).?.open);
    _ = try step(&view, 32, rightClick(.{ 4, 20 }), true);
    try std.testing.expect(view.ui.state.get(.context_menu, ui.Key.str("menu").indexed(0).hash()).?.open);
}

test "menu stays open in gaps and padding and closes on an action" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    const key = ui.Key.str("menu").indexed(0);
    _ = try stepWithGap(&view, 0, .{ .pos = .{ 250, 200 } }, false, 2);
    _ = try stepWithGap(&view, 16, rightClick(.{ 50, 20 }), false, 2);
    _ = try stepWithGap(&view, 32, .{ .pos = .{ 60, 30 } }, false, 2);
    // Leave a gap in this fixture to verify empty-space handling independently
    // of the application's contiguous menu entries.
    for ([_][2]f64{ .{ 60, 55 }, .{ 52, 30 }, .{ 60, 55 } }, 0..) |pos, i| {
        _ = try stepWithGap(&view, @intCast(48 + 16 * i), .{ .pos = pos }, false, 2);
        try std.testing.expect(view.ui.state.get(.context_menu, key.hash()).?.open);
        try std.testing.expectEqual(key.indexed(1).hash(), view.ui.state.hovered);
    }
    var empty_click: ui.input.Input = .{ .pos = .{ 60, 55 } };
    empty_click.mouse[@backingInt(ui.input.MouseButton.left)] = .{ .pressed = true, .released = true, .pressed_pos = empty_click.pos, .released_pos = empty_click.pos };
    _ = try stepWithGap(&view, 96, empty_click, false, 2);
    try std.testing.expect(view.ui.state.get(.context_menu, key.hash()).?.open);
    var action_click = empty_click;
    action_click.pos = .{ 60, 65 };
    action_click.mouse[@backingInt(ui.input.MouseButton.left)].pressed_pos = action_click.pos;
    action_click.mouse[@backingInt(ui.input.MouseButton.left)].released_pos = action_click.pos;
    _ = try stepWithGap(&view, 112, action_click, false, 2);
    try std.testing.expect(!view.ui.state.get(.context_menu, key.hash()).?.open);
}

test "hover crosses contiguous menu entries and project rows without a dead zone" {
    var view = try ui.Context.init(std.testing.allocator, .{});
    defer view.deinit();
    _ = try step(&view, 0, .{ .pos = .{ 250, 200 } }, false);
    for ([_]f64{ 39.5, 40, 40.5 }, 0..) |y, i| {
        const responses = try step(&view, @intCast(16 + 16 * i), .{ .pos = .{ 4, y } }, false);
        try std.testing.expect(responses[if (y < 40) @as(usize, 0) else 1].hovered);
    }
    const key = ui.Key.str("menu").indexed(0);
    _ = try step(&view, 64, rightClick(.{ 50, 20 }), false);
    for ([_]f64{ 53.5, 54, 54.5 }, 0..) |y, i| {
        _ = try step(&view, @intCast(80 + 16 * i), .{ .pos = .{ 60, y } }, false);
        try std.testing.expect(view.ui.state.get(.context_menu, key.hash()).?.open);
        try std.testing.expectEqual(ui.Key.str("menu-action").indexed(if (y < 54) @as(usize, 0) else 1).hash(), view.ui.state.hovered);
    }
}
