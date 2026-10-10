//! Where a dragged sidebar row lands. Rows sit a fixed pitch apart, so a height
//! in the list maps to a slot between the rows that remain once one is lifted.
const std = @import("std");
const config = @import("config.zig");

pub const Entry = union(enum) { group: config.Group, repository: usize };
/// A workspace index or a group id.
pub const Item = union(enum) { repository: usize, group: u32 };
pub const Place = union(enum) {
    /// `before` is the workspace index the entry lands in front of; null appends to the group.
    repository: struct { group: u32, before: ?usize },
    /// Final index in the group list.
    group: usize,
};
/// `slot` counts the rows above the gap. `indent` draws the gap as a group
/// member. `strip` lands the row on the ungroup strip instead of in a gap.
pub const Drop = struct {
    slot: usize,
    place: Place,
    indent: bool,
    strip: bool = false,
    pub fn same(self: Drop, other: Drop) bool {
        return switch (self.place) {
            .repository => |one| other.place == .repository and one.group == other.place.repository.group and one.before == other.place.repository.before,
            .group => |one| other.place == .group and one == other.place.group,
        };
    }
};

/// Visible rows in display order: each group with its entries, then the
/// ungrouped entries. `lifted` is left out, with its entries if it is a group.
pub fn entries(a: std.mem.Allocator, data: *const config.Data, lifted: ?Item) ![]Entry {
    var rows: std.ArrayList(Entry) = .empty;
    const repository: ?usize = if (lifted) |item| switch (item) {
        .repository => |index| index,
        .group => null,
    } else null;
    for (data.groups) |group| {
        if (lifted) |item| if (item == .group and item.group == group.id) continue;
        try rows.append(a, .{ .group = group });
        if (!group.collapsed) for (data.repositories, 0..) |entry, i| if (entry.group == group.id and i != repository) try rows.append(a, .{ .repository = i });
    }
    for (data.repositories, 0..) |entry, i| if (entry.group == 0 and i != repository) try rows.append(a, .{ .repository = i });
    return rows.toOwnedSlice(a);
}

/// Rows a dropped item occupies: an open group brings its entries along.
pub fn span(data: *const config.Data, item: Item) usize {
    var count: usize = 1;
    switch (item) {
        .repository => {},
        .group => |id| for (data.groups) |group| if (group.id == id and !group.collapsed) for (data.repositories) |entry| {
            if (entry.group == id) count += 1;
        },
    }
    return count;
}

fn groupOf(data: *const config.Data, entry: Entry) u32 {
    return switch (entry) {
        .group => |group| group.id,
        .repository => |index| data.repositories[index].group,
    };
}

/// First entry of a group in workspace order, other than `skip`.
fn firstMember(data: *const config.Data, id: u32, skip: usize) ?usize {
    for (data.repositories, 0..) |entry, i| if (entry.group == id and i != skip) return i;
    return null;
}

fn floorIndex(y: f32) usize {
    return if (y <= 0) 0 else @intFromFloat(@floor(@min(y, 1e6)));
}

/// A group's place in the display order; ungrouped entries come last.
fn rank(data: *const config.Data, id: u32) usize {
    for (data.groups, 0..) |group, i| if (group.id == id) return i;
    return data.groups.len;
}

/// How many of `rows` belong to groups. The ungrouped entries follow them, and
/// while an entry is dragged the ungroup strip sits between the two.
pub fn groupedRows(data: *const config.Data, rows: []const Entry) usize {
    for (rows, 0..) |row, i| if (row == .repository and groupOf(data, row) == 0) return i;
    return rows.len;
}

/// Where `item` sits now. `rows` must come from `entries` with `item` lifted.
pub fn origin(data: *const config.Data, rows: []const Entry, item: Item) Drop {
    switch (item) {
        .repository => |index| {
            const id = data.repositories[index].group;
            const mine = rank(data, id);
            var slot: usize = 0;
            for (rows) |row| {
                const theirs = rank(data, groupOf(data, row));
                const above = switch (row) {
                    .group => theirs <= mine,
                    .repository => |other| theirs < mine or (theirs == mine and other < index),
                };
                if (above) slot += 1;
            }
            var before: ?usize = null;
            for (data.repositories[index + 1 ..], index + 1..) |entry, i| if (entry.group == id) {
                before = i;
                break;
            };
            return .{ .slot = slot, .place = .{ .repository = .{ .group = id, .before = before } }, .indent = id != 0, .strip = id == 0 and data.groups.len > 0 and slot == groupedRows(data, rows) };
        },
        .group => |id| return groupDrop(data, rows, rank(data, id)),
    }
}

/// The gap for a group dropped at `position` among the other groups. Past the
/// last group it opens in front of the ungrouped entries.
fn groupDrop(data: *const config.Data, rows: []const Entry, position: usize) Drop {
    var seen: usize = 0;
    var slot = rows.len;
    for (rows, 0..) |row, i| {
        const header = row == .group;
        if ((header and seen == position) or (!header and groupOf(data, row) == 0)) {
            slot = i;
            break;
        }
        if (header) seen += 1;
    }
    return .{ .slot = slot, .place = .{ .group = @min(position, seen) }, .indent = false };
}

/// Where `item` would land with its centre `y` rows below the top of the
/// list. `rows` must come from `entries` with `item` lifted. `strip` is the
/// height of the ungroup strip in rows, 0 when it is not shown.
pub fn target(data: *const config.Data, rows: []const Entry, item: Item, y: f32, strip: f32) Drop {
    switch (item) {
        .repository => |index| {
            const n = rows.len;
            const end = groupedRows(data, rows);
            // Rows of groups: a gap opens above the row under the centre, and
            // the upper half of the strip still ends the last group.
            if (data.groups.len > 0 and y < @as(f32, @floatFromInt(end)) + 0.5) {
                // An entry cannot sit above the first group.
                const slot = std.math.clamp(floorIndex(y), 1, end);
                const previous = rows[slot - 1];
                const id = groupOf(data, previous);
                const before = if (slot < end and rows[slot] == .repository and groupOf(data, rows[slot]) == id) rows[slot].repository else if (previous == .repository) null else firstMember(data, id, index);
                return .{ .slot = slot, .place = .{ .repository = .{ .group = id, .before = before } }, .indent = true };
            }
            // From the lower half of the strip down the entry is ungrouped.
            const slot = std.math.clamp(floorIndex(y - strip), end, n);
            return .{ .slot = slot, .place = .{ .repository = .{ .group = 0, .before = if (slot < n) rows[slot].repository else null } }, .indent = false, .strip = data.groups.len > 0 and slot == end };
        },
        .group => {
            // Past the middle of a group's rows means after that group.
            var position: usize = 0;
            var start: usize = 0;
            while (start < rows.len and rows[start] == .group) {
                var end = start + 1;
                while (end < rows.len and rows[end] == .repository and groupOf(data, rows[end]) != 0) : (end += 1) {}
                if (y > @as(f32, @floatFromInt(start + end)) / 2) position += 1;
                start = end;
            }
            return groupDrop(data, rows, position);
        },
    }
}

test "a lifted sidebar row maps list heights to drop places" {
    var groups = [_]config.Group{ .{ .id = 1, .name = "A" }, .{ .id = 2, .name = "B", .collapsed = true }, .{ .id = 3, .name = "C" } };
    var repositories = [_]config.Repository{ .{ .path = "a1", .group = 1 }, .{ .path = "a2", .group = 1 }, .{ .path = "b1", .group = 2 }, .{ .path = "u1" }, .{ .path = "u2" } };
    const data = config.Data{ .groups = &groups, .repositories = &repositories };
    const a = std.testing.allocator;
    const all = try entries(a, &data, null);
    defer a.free(all);
    try std.testing.expectEqual(@as(usize, 7), all.len);
    try std.testing.expectEqual(@as(usize, 3), span(&data, .{ .group = 1 }));
    try std.testing.expectEqual(@as(usize, 1), span(&data, .{ .group = 2 }));
    try std.testing.expectEqual(@as(usize, 1), span(&data, .{ .repository = 0 }));

    // Rows left: A, a1, B, C, u1, u2.
    const item = Item{ .repository = 1 };
    const rows = try entries(a, &data, item);
    defer a.free(rows);
    const home = origin(&data, rows, item);
    try std.testing.expectEqual(@as(usize, 2), home.slot);
    try std.testing.expect(home.same(target(&data, rows, item, 2.2, 1)));
    const Case = struct { y: f32, slot: usize, group: u32, before: ?usize };
    for ([_]Case{
        .{ .y = -3, .slot = 1, .group = 1, .before = 0 }, // never above the first group
        .{ .y = 1.5, .slot = 1, .group = 1, .before = 0 },
        .{ .y = 3.4, .slot = 3, .group = 2, .before = 2 }, // into a collapsed group
        .{ .y = 4.2, .slot = 4, .group = 3, .before = null }, // upper half of the strip: the empty last group
        .{ .y = 4.7, .slot = 4, .group = 0, .before = 3 }, // lower half: ungrouped, on the strip
        .{ .y = 5.4, .slot = 4, .group = 0, .before = 3 },
        .{ .y = 6.5, .slot = 5, .group = 0, .before = 4 },
        .{ .y = 40, .slot = 6, .group = 0, .before = null },
    }) |case| {
        const drop = target(&data, rows, item, case.y, 1);
        try std.testing.expectEqual(case.slot, drop.slot);
        try std.testing.expectEqual(case.group, drop.place.repository.group);
        try std.testing.expectEqual(case.before, drop.place.repository.before);
        try std.testing.expectEqual(case.group != 0, drop.indent);
        try std.testing.expectEqual(case.group == 0 and case.slot == 4, drop.strip);
    }

    const loose = Item{ .repository = 3 };
    const without_loose = try entries(a, &data, loose);
    defer a.free(without_loose);
    const loose_home = origin(&data, without_loose, loose);
    try std.testing.expectEqual(@as(usize, 5), loose_home.slot);
    try std.testing.expectEqual(@as(?usize, 4), loose_home.place.repository.before);
    try std.testing.expect(!loose_home.indent and loose_home.strip);
    try std.testing.expect(!home.strip);

    // Rows left: A, a1, a2, C, u1, u2.
    const folder = Item{ .group = 2 };
    const others = try entries(a, &data, folder);
    defer a.free(others);
    const folder_home = origin(&data, others, folder);
    try std.testing.expectEqual(@as(usize, 3), folder_home.slot);
    try std.testing.expectEqual(@as(usize, 1), folder_home.place.group);
    for ([_][3]f32{ .{ 0.5, 0, 0 }, .{ 2, 3, 1 }, .{ 3.8, 4, 2 }, .{ 40, 4, 2 } }) |case| {
        const drop = target(&data, others, folder, case[0], 0);
        try std.testing.expectEqual(@as(usize, @intFromFloat(case[1])), drop.slot);
        try std.testing.expectEqual(@as(usize, @intFromFloat(case[2])), drop.place.group);
    }
}
