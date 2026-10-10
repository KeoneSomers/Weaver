//! Interactive native-dialog smoke tool: picker-probe <folder|file|manifest> [initial directory].
const std = @import("std");
const picker = @import("file_picker.zig");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const kind = if (args.len > 1) std.meta.stringToEnum(picker.Kind, args[1]) orelse return error.InvalidPickerKind else .folder;
    const selected = try picker.pick(init.gpa, .{ .kind = kind, .directory = if (args.len > 2) args[2] else null, .title = "Weaver picker verification" });
    if (selected) |path| {
        defer init.gpa.free(path);
        std.debug.print("Selected: {s}\n", .{path});
    } else std.debug.print("Cancelled\n", .{});
}
