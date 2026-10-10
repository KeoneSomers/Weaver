const std = @import("std");

pub const fetch_interval_s = 5 * 60;

pub fn fetchDue(enabled: bool, idle: bool, has_remotes: bool, last_attempt: ?i64, now: i64) bool {
    if (!enabled or !idle or !has_remotes) return false;
    const previous = last_attempt orelse return true;
    // A clock correction should not prevent fetching indefinitely.
    return now < previous or now - previous >= fetch_interval_s;
}

pub fn fetchedLabel(a: std.mem.Allocator, last_fetched: ?i64, now: i64) ![]const u8 {
    const previous = last_fetched orelse return "Last fetched: —";
    const elapsed = @max(0, now - previous);
    if (elapsed < 60) return "Last fetched just now";
    if (elapsed < 3600) return std.fmt.allocPrint(a, "Last fetched {d}m ago", .{@divTrunc(elapsed, 60)});
    if (elapsed < 86400) return std.fmt.allocPrint(a, "Last fetched {d}h ago", .{@divTrunc(elapsed, 3600)});
    return std.fmt.allocPrint(a, "Last fetched {d}d ago", .{@divTrunc(elapsed, 86400)});
}

test "automatic fetch respects opt-in, serialization and retry interval" {
    try std.testing.expect(!fetchDue(false, true, true, null, 0));
    try std.testing.expect(!fetchDue(true, false, true, null, 0));
    try std.testing.expect(!fetchDue(true, true, false, null, 0));
    try std.testing.expect(fetchDue(true, true, true, null, 0));
    try std.testing.expect(!fetchDue(true, true, true, 0, 299));
    try std.testing.expect(fetchDue(true, true, true, 0, 300));
    try std.testing.expect(fetchDue(true, true, true, 300, 299));
}

test "fetch status handles unknown, recent, older and future timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Last fetched: —", try fetchedLabel(a, null, 100));
    try std.testing.expectEqualStrings("Last fetched just now", try fetchedLabel(a, 100, 99));
    try std.testing.expectEqualStrings("Last fetched just now", try fetchedLabel(a, 100, 159));
    try std.testing.expectEqualStrings("Last fetched 1m ago", try fetchedLabel(a, 100, 160));
    try std.testing.expectEqualStrings("Last fetched 1h ago", try fetchedLabel(a, 100, 3700));
    try std.testing.expectEqualStrings("Last fetched 2d ago", try fetchedLabel(a, 100, 172900));
}
