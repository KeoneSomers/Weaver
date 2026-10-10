//! Native OS dialogs. Call on the UI thread; the returned UTF-8 path is owned by the caller.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("nfd");

pub const Kind = enum { folder, file, manifest };
pub const Parent = struct {
    kind: enum { unset, windows, cocoa, wayland } = .unset,
    handle: ?*anyopaque = null,
    display: ?*anyopaque = null,
};
pub const Options = struct {
    kind: Kind,
    parent: Parent = .{},
    directory: ?[]const u8 = null,
    title: []const u8,
};

pub fn pick(a: std.mem.Allocator, options: Options) !?[]u8 {
    if (c.NFD_Init() != c.NFD_OKAY) return error.NativePickerUnavailable;
    defer c.NFD_Quit();
    if (builtin.os.tag == .linux and options.parent.kind == .wayland) {
        if (c.NFD_SetWaylandDisplay(@ptrCast(options.parent.display)) != c.NFD_OKAY) return error.NativePickerUnavailable;
    }
    defer if (builtin.os.tag == .linux and options.parent.kind == .wayland) {
        _ = c.NFD_SetWaylandDisplay(null);
    };
    const directory = if (options.directory) |value| try a.dupeSentinel(u8, value, 0) else null;
    defer if (directory) |value| a.free(value);
    const title = try a.dupeSentinel(u8, options.title, 0);
    defer a.free(title);
    const parent = c.nfdwindowhandle_t{ .type = switch (options.parent.kind) {
        .unset => c.NFD_WINDOW_HANDLE_TYPE_UNSET,
        .windows => c.NFD_WINDOW_HANDLE_TYPE_WINDOWS,
        .cocoa => c.NFD_WINDOW_HANDLE_TYPE_COCOA,
        .wayland => c.NFD_WINDOW_HANDLE_TYPE_WAYLAND,
    }, .handle = options.parent.handle };
    var selected: [*c]u8 = null;
    const status = if (options.kind == .folder) blk: {
        const args = c.nfdpickfolderu8args_t{ .defaultPath = if (directory) |value| value.ptr else null, .parentWindow = parent, .title = title.ptr, .acceptLabel = null, .cancelLabel = null };
        break :blk c.NFD_PickFolderU8_With(&selected, &args);
    } else blk: {
        const filter = c.nfdu8filteritem_t{ .name = "Extension manifest", .spec = "json" };
        const args = c.nfdopendialogu8args_t{ .filterList = if (options.kind == .manifest) &filter else null, .filterCount = if (options.kind == .manifest) 1 else 0, .defaultPath = if (directory) |value| value.ptr else null, .parentWindow = parent, .title = title.ptr, .acceptLabel = null, .cancelLabel = null };
        break :blk c.NFD_OpenDialogU8_With(&selected, &args);
    };
    switch (status) {
        c.NFD_CANCEL => return null,
        c.NFD_OKAY => {
            if (selected == null) return error.NativePickerInvalidPath;
            defer c.NFD_FreePathU8(selected);
            const value = std.mem.span(selected);
            if (!std.unicode.utf8ValidateSlice(value) or !std.fs.path.isAbsolute(value)) return error.NativePickerInvalidPath;
            return try a.dupe(u8, value);
        },
        else => return error.NativePickerFailed,
    }
}
