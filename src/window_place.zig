//! Initial window placement, which Knots leaves to the desktop.
const builtin = @import("builtin");

const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MonitorInfo = extern struct { size: u32 = @sizeOf(MonitorInfo), monitor: Rect = undefined, work: Rect = undefined, flags: u32 = 0 };

extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn MonitorFromWindow(*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(*anyopaque, *MonitorInfo) callconv(.winapi) c_int;
extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, u32) callconv(.winapi) c_int;

/// Centres the window in the work area of the monitor it opened on.
/// Wayland places windows itself, and macOS keeps its own default.
pub fn center(window: anytype) void {
    if (builtin.os.tag != .windows) return;
    const hwnd = window.getWindowHandle().windows.hwnd;
    var outer: Rect = undefined;
    var info: MonitorInfo = .{};
    if (GetWindowRect(hwnd, &outer) == 0) return;
    const monitor = MonitorFromWindow(hwnd, 2) orelse return;
    if (GetMonitorInfoW(monitor, &info) == 0) return;
    const x = info.work.left + @divTrunc((info.work.right - info.work.left) - (outer.right - outer.left), 2);
    const y = info.work.top + @divTrunc((info.work.bottom - info.work.top) - (outer.bottom - outer.top), 2);
    // Keep the size and stacking order; only the position changes.
    _ = SetWindowPos(hwnd, null, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);
}
