const std = @import("std");
const model = @import("model.zig");

pub fn sameFile(a: model.File, b: model.File) bool {
    return a.staged == b.staged and std.mem.eql(u8, a.path, b.path) and
        std.mem.eql(u8, a.old_path, b.old_path) and std.mem.eql(u8, a.status, b.status);
}
pub fn sameList(a: []const model.File, b: []const model.File) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!sameFile(left, right)) return false;
    return true;
}
pub fn sameMetadata(a: model.Snapshot, b: model.Snapshot) bool {
    if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.branch, b.branch) or
        !std.mem.eql(u8, a.upstream, b.upstream) or a.ahead != b.ahead or a.behind != b.behind or
        a.state != b.state or a.history.len != b.history.len or a.branches.len != b.branches.len or a.remotes.len != b.remotes.len) return false;
    for (a.history, b.history) |left, right| if (!std.mem.eql(u8, left.oid, right.oid)) return false;
    for (a.branches, b.branches) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    for (a.remotes, b.remotes) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}
pub fn samePreview(a: model.File, b: model.File) bool {
    return sameFile(a, b) and a.binary == b.binary and std.mem.eql(u8, a.patch, b.patch);
}
pub fn retainCounts(allocator: std.mem.Allocator, previous: []const model.File, next: []model.File) !void {
    for ([_]bool{ false, true }) |staged| {
        var by_path: std.StringHashMap(model.File) = .init(allocator);
        defer by_path.deinit();
        for (previous) |file| if (file.staged == staged) try by_path.put(file.path, file);
        for (next) |*file| if (file.staged == staged) {
            if (by_path.get(file.path)) |old| if (sameFile(old, file.*)) {
                file.additions = old.additions;
                file.deletions = old.deletions;
                file.binary = old.binary;
                file.stats_available = old.stats_available;
            };
        };
    }
}

test "unchanged status does not imply unchanged diff content" {
    const before = model.File{ .path = "file.txt", .status = "Modified", .staged = false, .patch = "+before" };
    var after = before;
    after.patch = "+after";
    try std.testing.expect(sameList(&.{before}, &.{after}));
    try std.testing.expect(!samePreview(before, after));
    after = before;
    try std.testing.expect(samePreview(before, after));
    after.staged = true;
    try std.testing.expect(!sameList(&.{before}, &.{after}));
}
