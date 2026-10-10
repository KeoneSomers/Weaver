//! A complete external extension using Weaver's JSON-line API v1.
const std = @import("std");
const process = @import("process.zig");
extern "c" fn getchar() c_int;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    while (input.items.len < 1024 * 1024) {
        const ch = getchar();
        if (ch < 0 or ch == '\n') break;
        try input.append(a, @intCast(ch));
    }
    const request = try std.json.parseFromSlice(std.json.Value, a, input.items, .{});
    const object = request.value.object;
    if ((object.get("api_version") orelse return error.MissingAPIVersion).integer != 1) return error.UnsupportedAPI;
    if (!std.mem.eql(u8, (object.get("method") orelse return error.MissingMethod).string, "command.execute")) return error.UnsupportedMethod;
    if (!std.mem.eql(u8, (object.get("command") orelse return error.MissingCommand).string, "example.audit.run")) return error.UnknownCommand;
    const repository = (object.get("repository") orelse return error.MissingRepository).object;
    if (!std.mem.eql(u8, repository.get("provider").?.string, "git")) return error.UnsupportedProvider;
    const path = repository.get("path").?.string;
    if (!std.fs.path.isAbsolute(path)) return error.ExpectedAbsoluteRepository;
    const result = try process.run(init.io, a, &.{ "git", "--no-pager", "-C", path, "status", "--short", "--branch" }, null, null);
    if (!result.ok) return error.AuditFailed;
    const configuration = object.get("configuration") orelse std.json.Value{ .null = {} };
    const label = if (configuration == .object) if (configuration.object.get("audit.label")) |value| if (value == .string) value.string else "Repository health" else "Repository health" else "Repository health";
    const summary = try std.fmt.allocPrint(a, "{s}\n{s}", .{ label, result.stdout });
    const response = try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .command = "example.audit.run", .summary = summary, .configuration = configuration }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, response);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
