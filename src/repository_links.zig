const std = @import("std");

/// Convert a Git transport address into a browser address without credentials.
/// Local paths and custom Git transport helpers have no web destination.
pub fn webUrl(a: std.mem.Allocator, remote: []const u8) !?[]const u8 {
    if (remote.len == 0 or std.mem.indexOfAny(u8, remote, "\x00\r\n\\") != null) return null;
    var uri = if (std.mem.indexOf(u8, remote, "://") != null)
        std.Uri.parse(remote) catch return null
    else blk: {
        // SCP-style SSH remote: user@host:owner/repository.git.
        const at = std.mem.indexOfScalar(u8, remote, '@') orelse return null;
        const colon = std.mem.indexOfScalarPos(u8, remote, at + 1, ':') orelse return null;
        const host = remote[at + 1 .. colon];
        if (host.len == 0 or std.mem.indexOfAny(u8, host, " /?#:@") != null) return null;
        break :blk std.Uri{ .scheme = "ssh", .host = .{ .raw = host }, .path = .{ .raw = remote[colon + 1 ..] } };
    };
    const ssh = std.ascii.eqlIgnoreCase(uri.scheme, "ssh");
    if (!ssh and !std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    const host = uri.host orelse return null;
    if (host.isEmpty()) return null;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    var trimmed = std.mem.trimEnd(u8, path, "/");
    if (std.mem.endsWith(u8, trimmed, ".git")) trimmed = trimmed[0 .. trimmed.len - 4];
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/")) return null;
    const normalized = if (trimmed[0] == '/') trimmed else try std.fmt.allocPrint(a, "/{s}", .{trimmed});
    defer if (trimmed[0] != '/') a.free(normalized);
    uri.path = switch (uri.path) {
        .raw => .{ .raw = normalized },
        .percent_encoded => .{ .percent_encoded = normalized },
    };
    uri.user = null;
    uri.password = null;
    uri.query = null;
    uri.fragment = null;
    if (ssh) {
        uri.scheme = "https";
        uri.port = null;
    }
    return try std.fmt.allocPrint(a, "{f}", .{uri});
}

test "remote browser links support HTTPS and SSH without exposing credentials" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "https://user:token@github.com/team/project.git?token=secret#fragment", "https://github.com/team/project" },
        .{ "git@gitlab.com:team/nested/project.git", "https://gitlab.com/team/nested/project" },
        .{ "ssh://git@example.org:2222/team/project.git", "https://example.org/team/project" },
        .{ "http://example.org:8080/team/project.git/", "http://example.org:8080/team/project" },
        .{ "https://example.org/team/a%20b.git", "https://example.org/team/a%20b" },
        .{ "git@example.org:team/a b.git", "https://example.org/team/a%20b" },
    };
    inline for (cases) |case| {
        const url = (try webUrl(a, case[0])).?;
        defer a.free(url);
        try std.testing.expectEqualStrings(case[1], url);
    }
    for ([_][]const u8{ "", "C:\\work\\repo", "/work/repo", "file:///work/repo", "ext::sh -c bad", "javascript://host/evil", "https://github.com", "git@:repo", "https://host/repo\n" }) |remote|
        try std.testing.expectEqual(null, try webUrl(a, remote));
}
