//! Builds anchored `.gitignore` patterns for a changed path and appends them
//! to the repository's root `.gitignore`.
const std = @import("std");

pub const Scope = enum { file, folder, extension };

/// The part of a repository-relative path that `scope` would ignore, or null
/// when the path has no containing folder or no extension.
pub fn target(path: []const u8, scope: Scope) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    switch (scope) {
        .file => return if (path.len > 0) path else null,
        .folder => return if (slash) |end| if (end > 0) path[0..end] else null else null,
        .extension => {
            const name = if (slash) |end| path[end + 1 ..] else path;
            // A leading dot names a dotfile, not an extension.
            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
            return if (dot > 0 and dot + 1 < name.len) name[dot..] else null;
        },
    }
}

/// Files and folders are anchored to the repository root so the pattern cannot
/// match an unrelated path with the same name elsewhere.
pub fn pattern(a: std.mem.Allocator, path: []const u8, scope: Scope) ![]u8 {
    const value = target(path, scope) orelse return error.NothingToIgnore;
    // A pattern is one line; these cannot be escaped.
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.UnsupportedPath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, if (scope == .extension) '*' else '/');
    for (value, 0..) |c, i| {
        const trailing_space = c == ' ' and i + 1 == value.len and scope != .folder;
        if (c == '\\' or c == '*' or c == '?' or c == '[' or trailing_space) try out.append(a, '\\');
        try out.append(a, c);
    }
    if (scope == .folder) try out.append(a, '/');
    return out.toOwnedSlice(a);
}

/// The new file content, or null when `line` is already listed. Keeps the
/// file's existing line endings.
pub fn appended(a: std.mem.Allocator, existing: []const u8, line: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |current| if (std.mem.eql(u8, std.mem.trimEnd(u8, current, "\r"), line)) return null;
    const eol = if (std.mem.indexOf(u8, existing, "\r\n") != null) "\r\n" else "\n";
    const separator = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else eol;
    return try std.mem.concat(a, u8, &.{ existing, separator, line, eol });
}

/// Returns false when the pattern was already present.
pub fn add(io: std.Io, a: std.mem.Allocator, repository: []const u8, line: []const u8) !bool {
    const file = try std.fs.path.join(a, &.{ repository, ".gitignore" });
    defer a.free(file);
    const existing: []u8 = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try a.alloc(u8, 0),
        else => return err,
    };
    defer a.free(existing);
    const next = try appended(a, existing, line) orelse return false;
    defer a.free(next);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = next });
    return true;
}

test "patterns are anchored, escaped and scoped" {
    const a = std.testing.allocator;
    inline for (.{
        .{ "notes.txt", Scope.file, "/notes.txt" },
        .{ "src/gen/out[1].log", Scope.file, "/src/gen/out\\[1].log" },
        .{ "src/gen/out[1].log", Scope.folder, "/src/gen/" },
        .{ "src/gen/out[1].log", Scope.extension, "*.log" },
        .{ "#draft *.md ", Scope.file, "/#draft \\*.md\\ " },
        .{ "archive.tar.gz", Scope.extension, "*.gz" },
    }) |case| {
        const line = try pattern(a, case[0], case[1]);
        defer a.free(line);
        try std.testing.expectEqualStrings(case[2], line);
    }
    try std.testing.expectError(error.NothingToIgnore, pattern(a, "notes.txt", .folder));
    try std.testing.expectError(error.NothingToIgnore, pattern(a, "config/.env", .extension));
    try std.testing.expectError(error.NothingToIgnore, pattern(a, "Makefile", .extension));
    try std.testing.expectError(error.UnsupportedPath, pattern(a, "bad\nname", .file));
}

test "appending keeps line endings and skips listed patterns" {
    const a = std.testing.allocator;
    inline for (.{
        .{ "", "/a\n" },
        .{ "zig-out/\n", "zig-out/\n/a\n" },
        .{ "zig-out/", "zig-out/\n/a\n" },
        .{ "zig-out/\r\n.zig-cache/", "zig-out/\r\n.zig-cache/\r\n/a\r\n" },
    }) |case| {
        const next = (try appended(a, case[0], "/a")).?;
        defer a.free(next);
        try std.testing.expectEqualStrings(case[1], next);
    }
    try std.testing.expect(try appended(a, "zig-out/\r\n/a\r\n", "/a") == null);
    try std.testing.expect(try appended(a, "/a", "/a") == null);
}

test "adding writes the root .gitignore once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    try std.testing.expect(try add(io, a, root, "*.log"));
    try std.testing.expect(try add(io, a, root, "/build/"));
    try std.testing.expect(!try add(io, a, root, "*.log"));
    const written = try temp.dir.readFileAlloc(io, ".gitignore", a, .limited(1024));
    defer a.free(written);
    try std.testing.expectEqualStrings("*.log\n/build/\n", written);
}
