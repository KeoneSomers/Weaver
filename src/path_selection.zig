const std = @import("std");
const config = @import("config.zig");

/// Never turn a selection outside the repository into a Git pathspec.
pub fn repositoryRelative(a: std.mem.Allocator, repository: []const u8, selection: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(repository) or !std.fs.path.isAbsolute(selection)) return error.ExpectedAbsolutePath;
    const root = try std.fs.path.resolve(a, &.{repository});
    defer a.free(root);
    const path = try std.fs.path.resolve(a, &.{selection});
    defer a.free(path);
    if (config.equalPath(root, path)) return try a.dupe(u8, ".");
    const windows = @import("builtin").os.tag == .windows;
    const prefix = std.mem.trimEnd(u8, root, if (windows) "/\\" else "/");
    if (path.len <= prefix.len or !config.equalPath(prefix, path[0..prefix.len]) or (path[prefix.len] != '/' and !(windows and path[prefix.len] == '\\'))) return error.FileOutsideRepository;
    const relative = try a.dupe(u8, path[prefix.len + 1 ..]);
    if (@import("builtin").os.tag == .windows) for (relative) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    };
    return relative;
}

/// An existing folder, or the closest existing parent of a file/new destination.
pub fn initialDirectory(io: std.Io, a: std.mem.Allocator, current: []const u8) !?[]u8 {
    if (!std.fs.path.isAbsolute(current)) return null;
    var candidate = current;
    while (candidate.len > 0) {
        var directory = std.Io.Dir.cwd().openDir(io, candidate, .{}) catch {
            const parent = std.fs.path.dirname(candidate) orelse return null;
            if (std.mem.eql(u8, parent, candidate)) return null;
            candidate = parent;
            continue;
        };
        directory.close(io);
        return try a.dupe(u8, candidate);
    }
    return null;
}

test "file selections preserve Unicode and reject repository escapes" {
    const a = std.testing.allocator;
    const root = if (@import("builtin").os.tag == .windows) "C:/work/project" else "/work/project";
    const inside = try std.fs.path.join(a, &.{ root, "src", "café file.zig" });
    defer a.free(inside);
    const relative = try repositoryRelative(a, root, inside);
    defer a.free(relative);
    try std.testing.expectEqualStrings("src/café file.zig", relative);
    const sibling = try std.fmt.allocPrint(a, "{s}-other/file.zig", .{root});
    defer a.free(sibling);
    try std.testing.expectError(error.FileOutsideRepository, repositoryRelative(a, root, sibling));
    const traversal = try std.fs.path.join(a, &.{ root, "..", "outside.txt" });
    defer a.free(traversal);
    try std.testing.expectError(error.FileOutsideRepository, repositoryRelative(a, root, traversal));
    const same = try repositoryRelative(a, root, root);
    defer a.free(same);
    try std.testing.expectEqualStrings(".", same);
}

test "picker starts from the nearest existing parent of a new destination" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    const proposed = try std.fs.path.join(a, &.{ root, "new", "project" });
    defer a.free(proposed);
    const directory = (try initialDirectory(io, a, proposed)).?;
    defer a.free(directory);
    try std.testing.expect(config.equalPath(root, directory));
    try std.testing.expectEqual(@as(?[]u8, null), try initialDirectory(io, a, ""));
}
