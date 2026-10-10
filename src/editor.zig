const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");

const ShellExecuteInfo = extern struct {
    size: u32 = @sizeOf(ShellExecuteInfo),
    mask: u32,
    window: ?*anyopaque = null,
    verb: ?[*:0]const u16 = null,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16 = null,
    directory: ?[*:0]const u16 = null,
    show: c_int = 1, // SW_SHOWNORMAL
    instance: ?*anyopaque = null,
    id_list: ?*anyopaque = null,
    class: ?[*:0]const u16 = null,
    class_key: ?*anyopaque = null,
    hot_key: u32 = 0,
    monitor: ?*anyopaque = null,
    process: ?*anyopaque = null,
};
extern "shell32" fn ShellExecuteExW(*ShellExecuteInfo) callconv(.winapi) c_int;

/// Opens a file in the text editor the operating system has registered for
/// plain text. The file's own type is never consulted, so a repository script
/// or executable is edited instead of run.
pub fn open(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
            defer a.free(wide);
            // SEE_MASK_CLASSNAME | SEE_MASK_FLAG_NO_UI: launch as if the file were a .txt.
            var info = ShellExecuteInfo{ .mask = 0x1 | 0x400, .file = wide, .class = std.unicode.utf8ToUtf16LeStringLiteral(".txt") };
            if (ShellExecuteExW(&info) == 0) return error.NoTextEditor;
        },
        .macos => if (!try process.launch(io, &.{ "open", "-t", path })) return error.NoTextEditor,
        else => {
            const query = try process.run(io, a, &.{ "xdg-mime", "query", "default", "text/plain" }, null, null);
            defer query.deinit(a);
            const entry = std.mem.trim(u8, query.stdout, " \r\n");
            if (!query.ok or entry.len == 0) return error.NoTextEditor;
            if (!try process.launch(io, &.{ "gtk-launch", entry, path })) return error.NoTextEditor;
        },
    }
}
