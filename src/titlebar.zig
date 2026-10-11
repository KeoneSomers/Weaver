//! The title bar Weaver draws in place of the native one.
//! Knots has no borderless windows, so each platform is adjusted through its native handle.
const builtin = @import("builtin");
const knots = @import("knots");
const ui = @import("ui");
const icons = @import("icons.zig");
const brand_badge = @import("brand_badge.zig");
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Window = @FieldType(@typeInfo(@FieldType(knots.App, "main_viewport")).pointer.child, "window");

/// macOS keeps its own window buttons, which sit in a bar of this height.
const controls = builtin.os.tag != .macos;
pub const height: f32 = if (controls) 32 else 28;
const control_width: f32 = 46;
const controls_width: f32 = if (controls) 3 * control_width else 0;
/// Width of the brand and of the space kept for the window buttons.
const side: f32 = 170;
const bar = Rect{ .key = .str("titlebar"), .style = &.{ .width = .grow(), .height = .fixed(height), .direction = .row, .@"align" = .center } };
const centre = Rect{ .key = .str("titlebar-centre"), .style = &.{ .width = .grow(), .direction = .row, .justify = .center, .@"align" = .center, .gap = 6, .overflow = .hidden } };
/// Distance from a window edge that resizes an undecorated Wayland window.
const resize_margin: f64 = 6;
const double_click_ms = 400;

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const POINT = extern struct { x: i32, y: i32 };
const TRACKMOUSEEVENT = extern struct { size: u32 = @sizeOf(TRACKMOUSEEVENT), flags: u32, hwnd: *anyopaque, hover_time: u32 = 0 };
const WindowProc = *const fn (*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(*anyopaque, c_int, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(*anyopaque, c_int) callconv(.winapi) isize;
extern "user32" fn CallWindowProcW(WindowProc, *anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn DefWindowProcW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn ShowWindow(*anyopaque, c_int) callconv(.winapi) c_int;
extern "user32" fn IsZoomed(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn ScreenToClient(*anyopaque, *POINT) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(*anyopaque, *RECT) callconv(.winapi) c_int;
extern "user32" fn GetDpiForWindow(*anyopaque) callconv(.winapi) u32;
extern "user32" fn GetSystemMetricsForDpi(c_int, u32) callconv(.winapi) c_int;
extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) c_int;

var knots_proc: WindowProc = undefined;
var tracking_leave = false;
/// Wayland: serial of the latest pointer button, which a move or resize must name.
var press_serial: u32 = 0;
/// Wayland: Knots reads only the fullscreen state, so this follows Weaver's own requests.
var maximized = false;
var last_press_ms: i64 = 0;

/// Removes the native title bar. Call once, after creating the window.
pub fn install(window: *Window) void {
    switch (builtin.os.tag) {
        .windows => {
            const hwnd = window.getWindowHandle().windows.hwnd;
            knots_proc = @ptrFromInt(@as(usize, @bitCast(SetWindowLongPtrW(hwnd, -4, @bitCast(@intFromPtr(&windowProc))))));
            // SWP_FRAMECHANGED: lay the client area out again, now over the caption.
            _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x0037);
        },
        .macos => {
            const ns_window = window.backend.ns_window;
            // NSWindowStyleMaskFullSizeContentView: draw under the title bar, which stays draggable.
            ns_window.msgSend(void, "setStyleMask:", .{ns_window.msgSend(c_ulong, "styleMask", .{}) | (1 << 15)});
            ns_window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
            ns_window.msgSend(void, "setTitleVisibility:", .{@as(c_long, 1)});
        },
        .linux => {
            const state = window.backend.state;
            if (state.decoration) |decoration| decoration.setMode(.client_side);
            // Knots drops button serials, so a second pointer object records them.
            if (state.shared.pointer != null) if (state.shared.seat.?.getPointer()) |pointer| {
                pointer.setListener(*u32, SerialListener(@typeInfo(@TypeOf(pointer)).pointer.child).listen, &press_serial);
            } else |_| {};
            state.surface.commit();
        },
        else => {},
    }
}

fn SerialListener(comptime Pointer: type) type {
    return struct {
        fn listen(_: *Pointer, event: Pointer.Event, serial: *u32) void {
            switch (event) {
                .button => |button| serial.* = button.serial,
                else => {},
            }
        }
    };
}

fn windowProc(hwnd: *anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (msg) {
        // WM_NCCALCSIZE: keep the resize borders and give the caption to the client area.
        0x0083 => if (wparam != 0) {
            const rect: *RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const top = rect.top;
            const result = DefWindowProcW(hwnd, msg, wparam, lparam);
            if (result != 0) return result;
            // A maximized window hangs over the screen edge by its frame.
            rect.top = top + if (IsZoomed(hwnd) != 0) frameHeight(hwnd) else 0;
            return 0;
        },
        // WM_NCHITTEST: the bar drags the window and its top edge resizes it.
        0x0084 => {
            const hit = DefWindowProcW(hwnd, msg, wparam, lparam);
            if (hit != 1) return hit;
            var point = POINT{ .x = @as(i16, @truncate(lparam)), .y = @as(i16, @truncate(lparam >> 16)) };
            var client: RECT = undefined;
            _ = ScreenToClient(hwnd, &point);
            _ = GetClientRect(hwnd, &client);
            const scale = @as(f32, @floatFromInt(GetDpiForWindow(hwnd))) / 96;
            if (IsZoomed(hwnd) == 0 and point.y < frameHeight(hwnd)) return 12; // HTTOP
            if (@as(f32, @floatFromInt(point.y)) < height * scale and @as(f32, @floatFromInt(client.right - point.x)) > controls_width * scale) return 2; // HTCAPTION
            return hit;
        },
        // WM_MOUSEMOVE
        0x0200 => if (!tracking_leave) {
            var track = TRACKMOUSEEVENT{ .flags = 2, .hwnd = hwnd };
            tracking_leave = TrackMouseEvent(&track) != 0;
        },
        // WM_MOUSELEAVE: Knots never hears the pointer go, which would leave a window button lit.
        0x02A3 => {
            tracking_leave = false;
            const owner: ?*Window = @ptrFromInt(@as(usize, @bitCast(GetWindowLongPtrW(hwnd, -21))));
            if (owner) |window| window.setCursorPos(.{ -1, -1 });
        },
        else => {},
    }
    return CallWindowProcW(knots_proc, hwnd, msg, wparam, lparam);
}

fn frameHeight(hwnd: *anyopaque) i32 {
    const dpi = GetDpiForWindow(hwnd);
    return GetSystemMetricsForDpi(33, dpi) + GetSystemMetricsForDpi(92, dpi);
}

fn isMaximized(window: *Window) bool {
    return switch (builtin.os.tag) {
        .windows => IsZoomed(window.getWindowHandle().windows.hwnd) != 0,
        else => maximized,
    };
}

fn minimize(window: *Window) void {
    switch (builtin.os.tag) {
        .windows => _ = ShowWindow(window.getWindowHandle().windows.hwnd, 6),
        .linux => window.backend.state.toplevel.setMinimized(),
        else => {},
    }
}

fn toggleMaximized(window: *Window) void {
    switch (builtin.os.tag) {
        .windows => {
            const hwnd = window.getWindowHandle().windows.hwnd;
            _ = ShowWindow(hwnd, if (IsZoomed(hwnd) != 0) 9 else 3);
        },
        .linux => {
            const toplevel = window.backend.state.toplevel;
            if (maximized) toplevel.unsetMaximized() else toplevel.setMaximized();
            maximized = !maximized;
        },
        else => {},
    }
}

/// Opens the bar up to its centre, where the caller draws what the window shows.
pub fn open(ctx: *ui.Frame) !void {
    _ = try bar.open(ctx);
    // On macOS the brand starts after the window buttons.
    const brand = Rect{ .key = .str("titlebar-brand"), .style = comptime &.{ .width = .fixed(side), .direction = .row, .@"align" = .center, .gap = 8, .padding = .init(0, 0, 0, if (controls) 14 else 78) } };
    _ = try brand.open(ctx);
    try brand_badge.render(ctx, 18);
    try ctx.e(Text{ .key = .str("brand"), .content = "weaver", .selectable = false, .style = comptime &.{ .wrap = false, .font_size = .sm, .foreground = .text } });
    try brand.close(ctx);
    _ = try centre.open(ctx);
}

pub fn close(ctx: *ui.Frame, window: *Window, glyphs: []const icons.Glyph) !void {
    try centre.close(ctx);
    // As wide as the brand, so the centre is the middle of the window.
    const end = Rect{ .key = .str("titlebar-controls"), .style = comptime &.{ .width = .fixed(side), .direction = .row, .justify = .end } };
    _ = try end.open(ctx);
    if (controls) {
        if (try control(ctx, glyphs, "minus", "Minimize", false)) minimize(window);
        if (isMaximized(window)) {
            if (try control(ctx, glyphs, "copy", "Restore", false)) toggleMaximized(window);
        } else if (try control(ctx, glyphs, "square", "Maximize", false)) toggleMaximized(window);
        if (try control(ctx, glyphs, "x", "Close", true)) ctx.requestClose();
    }
    try end.close(ctx);
    try bar.close(ctx);
    if (builtin.os.tag == .linux) pointerActions(ctx, window);
}

fn control(ctx: *ui.Frame, glyphs: []const icons.Glyph, icon: []const u8, name: []const u8, danger: bool) !bool {
    const key = ui.Key.str("titlebar-control").indexed(ui.Key.str(name).hash());
    const b = Button{ .key = key, .style = &.{ .width = .fixed(control_width), .height = .fixed(height), .padding = .all(0), .justify = .center, .@"align" = .center, .radius = .{ .fixed = 0 }, .background = .transparent, .foreground = .dimmed, .hover = &.{ .background = if (danger) .{ .color = ui.Color.rgba(0xC4, 0x2B, 0x1C, 0xFF) } else .muted, .foreground = if (danger) .{ .color = ui.Color.rgba(0xFF, 0xFF, 0xFF, 0xFF) } else .text, .state_layer = 0 }, .active = &.{ .background = .toned, .state_layer = 0 } } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = name });
    if (icons.find(glyphs, icon)) |glyph|
        try ctx.e(Text{ .key = key.indexed(1), .content = glyph.text(), .selectable = false, .style = comptime &.{ .font = "lucide", .font_size = .{ .px = 14 } } });
    try b.close(ctx);
    return response.clicked;
}

/// Wayland leaves moving and resizing an undecorated window to the client.
fn pointerActions(ctx: *ui.Frame, window: *Window) void {
    const state = window.backend.state;
    const seat = state.shared.seat orelse return;
    const input = &ctx.ui().input;
    const pressed = input.mouseButton(.left).pressed;
    const size = window.getSize();
    const x = input.mouse_pos[0];
    const y = input.mouse_pos[1];
    const left = x < resize_margin;
    const right = x >= @as(f64, @floatFromInt(size.width)) - resize_margin;
    const top = y < resize_margin;
    const bottom = y >= @as(f64, @floatFromInt(size.height)) - resize_margin;
    if (!maximized and (left or right or top or bottom)) {
        ctx.ui().requestCursor(if (top or bottom) (if (left == right) .resize_vertical else if (left == top) .resize_diagonal_nw_se else .resize_diagonal_ne_sw) else .resize_horizontal);
        if (!pressed) return;
        state.toplevel.resize(seat, press_serial, if (top) (if (left) .top_left else if (right) .top_right else .top) else if (bottom) (if (left) .bottom_left else if (right) .bottom_right else .bottom) else if (left) .left else .right);
    } else if (pressed and x < @as(f64, @floatFromInt(size.width)) - controls_width and ctx.ui().leftPressed(bar.key.hash(), .within)) {
        const again = input.now_ms - last_press_ms < double_click_ms;
        last_press_ms = if (again) 0 else input.now_ms;
        if (again) toggleMaximized(window) else state.toplevel.move(seat, press_serial);
    } else return;
    // The compositor takes the pointer from here, so the release never arrives.
    window.cancelPointerInput();
}
