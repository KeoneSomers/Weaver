const std = @import("std");
pub const Theme = enum {
    dark,
    carbon,
    graphite,
    midnight,
    ocean,
    forest,
    plum,
    nord,
    light,
    sand,
    paper,
    /// Settings written before Ultra Dark became Dark still name it.
    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Theme {
        const name = switch (try source.nextAllocMax(a, .alloc_if_needed, options.max_value_len.?)) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };
        if (std.mem.eql(u8, name, "ultra_dark")) return .dark;
        return std.meta.stringToEnum(Theme, name) orelse error.InvalidEnumTag;
    }
};
pub const TextSize = enum { small, medium, large, extra_large };
pub const DiffFont = enum { mono, sans };
pub const SettingValue = struct { id: []const u8, value: []const u8 };
pub const ExtensionState = struct { id: []const u8, manifest_path: []const u8 = "", enabled: bool = true, settings: []SettingValue = &.{} };
/// `icon` is a Lucide glyph name and `icon_color` a hex color; empty means the default.
/// `name` is an alias shown instead of the folder name, and `group` a `Group.id`, 0 when ungrouped.
pub const Repository = struct {
    path: []const u8,
    provider: []const u8 = "git",
    last_fetched: ?i64 = null,
    icon: []const u8 = "",
    icon_color: []const u8 = "",
    name: []const u8 = "",
    group: u32 = 0,
    pub fn label(self: Repository) []const u8 {
        return if (self.name.len > 0) self.name else std.fs.path.basename(std.mem.trimEnd(u8, self.path, "/\\"));
    }
};
/// A virtual folder of workspace entries. Groups are listed in display order.
pub const Group = struct { id: u32, name: []const u8, collapsed: bool = false };
pub const name_bytes_max = 64;
pub const Data = struct { version: u32 = 1, repositories: []Repository = &.{}, groups: []Group = &.{}, selected: usize = 0, theme: Theme = .graphite, accent: []const u8 = "#B4A0FF", text_size: TextSize = .medium, diff_font: DiffFont = .mono, diff_font_size: u8 = 11, split_diff: bool = false, oauth_client_id: []const u8 = "", release_repo: []const u8 = "", extensions: []ExtensionState = &.{}, auto_refresh: bool = true, auto_fetch: bool = true, auto_update_check: bool = true, github_login: []const u8 = "" };
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    data: Data,
    path: []const u8,
    pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
        var self = Config{ .arena = .init(a), .data = .{}, .path = "" };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const root = env.get("WEAVER_CONFIG_HOME") orelse env.get("APPDATA") orelse env.get("XDG_CONFIG_HOME") orelse env.get("HOME") orelse return error.ConfigDirectoryUnavailable;
        self.path = try std.fs.path.join(arena, &.{ root, if (env.get("APPDATA") != null or env.get("XDG_CONFIG_HOME") != null or env.get("WEAVER_CONFIG_HOME") != null) "Weaver" else ".config/Weaver", "settings.json" });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return err,
        };
        self.data = (try std.json.parseFromSlice(Data, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
        if (self.data.version != 1) return error.UnsupportedConfigVersion;
        self.data.diff_font_size = std.math.clamp(self.data.diff_font_size, 11, 15);
        self.data.selected = if (self.data.repositories.len == 0) 0 else @min(self.data.selected, self.data.repositories.len - 1);
        const selected_path = if (self.data.repositories.len > 0) try absolutePath(io, arena, self.data.repositories[self.data.selected].path) else "";
        var unique: std.ArrayList(Repository) = .empty;
        for (self.data.repositories) |repository| {
            const canonical = try absolutePath(io, arena, repository.path);
            var duplicate = false;
            for (unique.items) |existing| if (equalPath(existing.path, canonical) and std.mem.eql(u8, existing.provider, repository.provider)) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                var entry = repository;
                entry.path = canonical;
                try unique.append(arena, entry);
            }
        }
        self.data.repositories = try unique.toOwnedSlice(arena);
        // A hand-edited file can repeat a group or leave an entry pointing at none.
        var groups: usize = 0;
        for (self.data.groups) |group| {
            var valid = group.id != 0;
            for (self.data.groups[0..groups]) |kept| valid = valid and kept.id != group.id;
            if (!valid) continue;
            self.data.groups[groups] = group;
            groups += 1;
        }
        self.data.groups = self.data.groups[0..groups];
        for (self.data.repositories) |*repository| if (self.groupIndex(repository.group) == null) {
            repository.group = 0;
        };
        self.data.selected = 0;
        for (self.data.repositories, 0..) |repository, i| if (equalPath(repository.path, selected_path)) {
            self.data.selected = i;
            break;
        };
        return self;
    }
    pub fn save(self: *Config, io: std.Io) !void {
        const a = self.arena.child_allocator;
        const dir = std.fs.path.dirname(self.path).?;
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const bytes = try std.json.Stringify.valueAlloc(a, self.data, .{ .whitespace = .indent_2 });
        defer a.free(bytes);
        var nonce: [8]u8 = undefined;
        io.random(&nonce);
        const suffix = std.fmt.bytesToHex(nonce, .lower);
        const temp = try std.fmt.allocPrint(a, "{s}.{s}.tmp", .{ self.path, suffix });
        defer a.free(temp);
        const file = try std.Io.Dir.cwd().createFile(io, temp, .{ .exclusive = true });
        errdefer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
        {
            defer file.close(io);
            try file.writeStreamingAll(io, bytes);
            try file.sync(io);
        }
        try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), self.path, io);
    }
    pub fn add(self: *Config, io: std.Io, path: []const u8) !void {
        return self.addProvider(io, path, "git");
    }
    pub fn addProvider(self: *Config, io: std.Io, path: []const u8, provider: []const u8) !void {
        const a = self.arena.allocator();
        const canonical = try absolutePath(io, a, path);
        for (self.data.repositories, 0..) |p, i| if (equalPath(p.path, canonical) and std.mem.eql(u8, p.provider, provider)) {
            self.data.selected = i;
            try self.save(io);
            return;
        };
        const next = try a.alloc(Repository, self.data.repositories.len + 1);
        @memcpy(next[0..self.data.repositories.len], self.data.repositories);
        next[next.len - 1] = .{ .path = canonical, .provider = try a.dupe(u8, provider) };
        self.data.repositories = next;
        self.data.selected = next.len - 1;
        try self.save(io);
    }
    pub fn remove(self: *Config, io: std.Io, index: usize) !void {
        const old = self.data.repositories;
        if (index >= old.len) return;
        const next = try self.arena.allocator().alloc(Repository, old.len - 1);
        @memcpy(next[0..index], old[0..index]);
        @memcpy(next[index..], old[index + 1 ..]);
        self.data.repositories = next;
        self.data.selected = if (next.len == 0) 0 else if (self.data.selected > index) self.data.selected - 1 else @min(self.data.selected, next.len - 1);
        try self.save(io);
    }
    /// Reorders the workspace list; the selection follows its repository.
    pub fn move(self: *Config, io: std.Io, from: usize, to: usize) !void {
        const items = self.data.repositories;
        if (from >= items.len or to >= items.len or from == to) return;
        const moved = items[from];
        const selected = self.data.selected;
        if (from < to) {
            std.mem.copyForwards(Repository, items[from..to], items[from + 1 .. to + 1]);
            if (selected > from and selected <= to) self.data.selected = selected - 1;
        } else {
            std.mem.copyBackwards(Repository, items[to + 1 .. from + 1], items[to..from]);
            if (selected >= to and selected < from) self.data.selected = selected + 1;
        }
        items[to] = moved;
        if (selected == from) self.data.selected = to;
        try self.save(io);
    }
    /// Personalizes a workspace entry; it travels with the entry when the list changes.
    pub fn setIcon(self: *Config, io: std.Io, index: usize, icon: []const u8, color: []const u8) !void {
        if (index >= self.data.repositories.len) return;
        const a = self.arena.allocator();
        const repository = &self.data.repositories[index];
        if (!std.mem.eql(u8, repository.icon, icon)) repository.icon = try a.dupe(u8, icon);
        if (!std.mem.eql(u8, repository.icon_color, color)) repository.icon_color = try a.dupe(u8, color);
        try self.save(io);
    }
    /// Sets the name shown for a workspace entry. An empty name restores the folder name.
    pub fn rename(self: *Config, io: std.Io, index: usize, name: []const u8) !void {
        if (index >= self.data.repositories.len) return;
        self.data.repositories[index].name = try self.arena.allocator().dupe(u8, cleanName(name));
        try self.save(io);
    }
    pub fn groupIndex(self: *const Config, id: u32) ?usize {
        if (id == 0) return null;
        for (self.data.groups, 0..) |group, i| if (group.id == id) return i;
        return null;
    }
    /// Appends an empty group and returns its id.
    pub fn addGroup(self: *Config, io: std.Io, name: []const u8) !u32 {
        const a = self.arena.allocator();
        var id: u32 = 1;
        for (self.data.groups) |group| id = @max(id, group.id +| 1);
        const next = try a.alloc(Group, self.data.groups.len + 1);
        @memcpy(next[0..self.data.groups.len], self.data.groups);
        next[next.len - 1] = .{ .id = id, .name = try a.dupe(u8, cleanName(name)) };
        self.data.groups = next;
        try self.save(io);
        return id;
    }
    pub fn renameGroup(self: *Config, io: std.Io, id: u32, name: []const u8) !void {
        const index = self.groupIndex(id) orelse return;
        self.data.groups[index].name = try self.arena.allocator().dupe(u8, cleanName(name));
        try self.save(io);
    }
    /// Deletes a group; its entries stay in the workspace, ungrouped.
    pub fn removeGroup(self: *Config, io: std.Io, id: u32) !void {
        const index = self.groupIndex(id) orelse return;
        const groups = self.data.groups;
        std.mem.copyForwards(Group, groups[index .. groups.len - 1], groups[index + 1 ..]);
        self.data.groups = groups[0 .. groups.len - 1];
        for (self.data.repositories) |*repository| if (repository.group == id) {
            repository.group = 0;
        };
        try self.save(io);
    }
    pub fn moveGroup(self: *Config, io: std.Io, from: usize, to: usize) !void {
        const items = self.data.groups;
        if (from >= items.len or to >= items.len or from == to) return;
        const moved = items[from];
        if (from < to) std.mem.copyForwards(Group, items[from..to], items[from + 1 .. to + 1]) else std.mem.copyBackwards(Group, items[to + 1 .. from + 1], items[to..from]);
        items[to] = moved;
        try self.save(io);
    }
    /// Places a workspace entry in a group, or outside every group with id 0.
    pub fn setGroup(self: *Config, io: std.Io, index: usize, id: u32) !void {
        if (index >= self.data.repositories.len or (id != 0 and self.groupIndex(id) == null)) return;
        self.data.repositories[index].group = id;
        try self.save(io);
    }
    /// Puts a workspace entry in a group (0 for none), in front of the entry at
    /// `before` or after the group's other entries.
    pub fn place(self: *Config, io: std.Io, index: usize, id: u32, before: ?usize) !void {
        const items = self.data.repositories;
        if (index >= items.len or (id != 0 and self.groupIndex(id) == null)) return;
        if (before) |next| if (next >= items.len or next == index) return;
        items[index].group = id;
        var to = index;
        if (before) |next| {
            to = if (index < next) next - 1 else next;
        } else {
            var last: ?usize = null;
            for (items, 0..) |other, i| if (i != index and other.group == id) {
                last = i;
            };
            if (last) |end| to = if (index < end) end else end + 1;
        }
        // `move` saves unless the entry already sits there.
        if (to == index) try self.save(io) else try self.move(io, index, to);
    }
    pub fn setCollapsed(self: *Config, io: std.Io, id: u32, collapsed: bool) !void {
        const index = self.groupIndex(id) orelse return;
        self.data.groups[index].collapsed = collapsed;
        try self.save(io);
    }
    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};
/// Trims a typed name and cuts it to `name_bytes_max` on a character boundary.
fn cleanName(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len <= name_bytes_max) return trimmed;
    var end: usize = name_bytes_max;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r\n");
}
fn absolutePath(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptyRepositoryPath;
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(a, &.{path});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buffer[0..try std.Io.Dir.cwd().realPath(io, &buffer)];
    return std.fs.path.resolve(a, &.{ cwd, path });
}
pub fn equalPath(one: []const u8, two: []const u8) bool {
    const left = std.mem.trimEnd(u8, one, "/\\");
    const right = std.mem.trimEnd(u8, two, "/\\");
    if (@import("builtin").os.tag != .windows) return std.mem.eql(u8, left, right);
    if (left.len != right.len) return false;
    for (left, right) |l, r| {
        const lc = if (l == '\\') '/' else std.ascii.toLower(l);
        const rc = if (r == '\\') '/' else std.ascii.toLower(r);
        if (lc != rc) return false;
    }
    return true;
}

test "repository path matching respects platform case and separator rules" {
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(equalPath("C:\\Work\\Repo\\", "c:/work/repo"));
    } else {
        try std.testing.expect(!equalPath("/work/Repo", "/work/repo"));
    }
    try std.testing.expect(!equalPath("/work/one", "/work/two"));
}

test "workspace persistence deduplicates paths and restores selection and appearance" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    const repository = try std.fs.path.join(a, &.{ root, "project" });
    defer a.free(repository);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try std.Io.Dir.cwd().realPath(io, &cwd_buffer)];
    const relative = try std.fs.path.relative(a, cwd, &env, cwd, repository);
    defer a.free(relative);
    {
        var config = try Config.init(io, a, &env);
        defer config.deinit();
        try config.add(io, repository);
        try config.add(io, relative);
        try std.testing.expectEqual(@as(usize, 1), config.data.repositories.len);
        // Migrate relative paths written by older previews on the next load.
        config.data.repositories[0].path = relative;
        config.data.theme = .ocean;
        config.data.accent = "#123456";
        config.data.auto_fetch = true;
        config.data.repositories[0].last_fetched = 1234567890;
        try config.save(io);
    }
    var restored = try Config.init(io, a, &env);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.data.repositories.len);
    try std.testing.expectEqual(Theme.ocean, restored.data.theme);
    try std.testing.expectEqualStrings("#123456", restored.data.accent);
    try std.testing.expect(restored.data.auto_fetch);
    try std.testing.expectEqual(@as(?i64, 1234567890), restored.data.repositories[0].last_fetched);
    try std.testing.expectEqualStrings("git", restored.data.repositories[0].provider);
    try std.testing.expect(equalPath(repository, restored.data.repositories[0].path));
}

test "settings saved with the former Ultra Dark theme load as Dark" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    try temp.dir.createDirPath(io, "Weaver");
    try temp.dir.writeFile(io, .{ .sub_path = "Weaver/settings.json", .data = "{\"theme\":\"ultra_dark\"}" });
    var config = try Config.init(io, a, &env);
    defer config.deinit();
    try std.testing.expectEqual(Theme.dark, config.data.theme);
}

test "removing a workspace entry preserves the selected repository when possible" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    var config = try Config.init(io, std.testing.allocator, &env);
    defer config.deinit();
    for ([_][]const u8{ "first", "second", "third", "fourth" }) |name| {
        const path = try std.fs.path.join(config.arena.allocator(), &.{ root, name });
        try config.add(io, path);
    }
    config.data.selected = 1;
    const selected = config.data.repositories[1].path;
    try config.remove(io, 3); // after the selection
    try std.testing.expectEqualStrings(selected, config.data.repositories[config.data.selected].path);
    try config.remove(io, 0); // before the selection
    try std.testing.expectEqualStrings(selected, config.data.repositories[config.data.selected].path);
    try config.remove(io, 0); // selected entry, choose its neighbour
    try std.testing.expectEqual(@as(usize, 0), config.data.selected);
    try std.testing.expectEqual(@as(usize, 1), config.data.repositories.len);
    try config.remove(io, 0); // last entry
    try std.testing.expectEqual(@as(usize, 0), config.data.selected);
    try std.testing.expectEqual(@as(usize, 0), config.data.repositories.len);
}

test "moving a workspace entry reorders the list and keeps the selected repository" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    var config = try Config.init(io, std.testing.allocator, &env);
    defer config.deinit();
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| try config.add(io, try std.fs.path.join(config.arena.allocator(), &.{ root, name }));
    const expectOrder = struct {
        fn check(c: *const Config, comptime order: []const u8, selected: u8) !void {
            for (c.data.repositories, order) |repository, name| try std.testing.expectEqual(name, repository.path[repository.path.len - 1]);
            try std.testing.expectEqual(selected, c.data.repositories[c.data.selected].path[c.data.repositories[c.data.selected].path.len - 1]);
        }
    }.check;
    config.data.selected = 1;
    try config.move(io, 0, 1); // across the selection
    try expectOrder(&config, "bacd", 'b');
    try config.move(io, 0, 3); // the selection itself, to the bottom
    try expectOrder(&config, "acdb", 'b');
    try config.move(io, 2, 0); // to the top, before the selection
    try expectOrder(&config, "dacb", 'b');
    try config.move(io, 3, 1);
    try expectOrder(&config, "dbac", 'b');
    try config.move(io, 2, 2);
    try config.move(io, 0, 4); // out of range
    try expectOrder(&config, "dbac", 'b');
    var restored = try Config.init(io, std.testing.allocator, &env);
    defer restored.deinit();
    try expectOrder(&restored, "dbac", 'b');
}

test "a project icon persists and follows its repository through moves and removals" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    {
        var config = try Config.init(io, std.testing.allocator, &env);
        defer config.deinit();
        for ([_][]const u8{ "a", "b", "c" }) |name| try config.add(io, try std.fs.path.join(config.arena.allocator(), &.{ root, name }));
        try config.setIcon(io, 1, "rocket", "#80B5E8");
        try config.setIcon(io, 7, "star", ""); // out of range
        try config.move(io, 1, 2);
        try config.remove(io, 0);
        try config.add(io, try std.fs.path.join(config.arena.allocator(), &.{ root, "d" }));
        try config.add(io, config.data.repositories[1].path); // already listed
    }
    var restored = try Config.init(io, std.testing.allocator, &env);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 3), restored.data.repositories.len);
    for (restored.data.repositories, "cbd") |repository, name| {
        try std.testing.expectEqual(name, repository.path[repository.path.len - 1]);
        try std.testing.expectEqualStrings(if (name == 'b') "rocket" else "", repository.icon);
        try std.testing.expectEqualStrings(if (name == 'b') "#80B5E8" else "", repository.icon_color);
    }
    try restored.setIcon(io, 1, "", "");
    try std.testing.expectEqualStrings("", restored.data.repositories[1].icon);
}

test "aliases and groups persist and follow their repositories" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    {
        var config = try Config.init(io, std.testing.allocator, &env);
        defer config.deinit();
        for ([_][]const u8{ "a", "b", "c", "d" }) |name| try config.add(io, try std.fs.path.join(config.arena.allocator(), &.{ root, name }));
        try std.testing.expectEqualStrings("b", config.data.repositories[1].label());
        try config.rename(io, 1, "  Backend  ");
        try config.rename(io, 9, "ignored"); // out of range
        try std.testing.expectEqualStrings("Backend", config.data.repositories[1].label());
        const work = try config.addGroup(io, "Work");
        const play = try config.addGroup(io, "Play");
        const spare = try config.addGroup(io, "Spare");
        try config.setGroup(io, 1, work);
        try config.setGroup(io, 2, work);
        try config.setGroup(io, 3, spare);
        try config.setGroup(io, 0, 99); // no such group
        try std.testing.expectEqual(@as(u32, 0), config.data.repositories[0].group);
        try config.renameGroup(io, play, "Side projects");
        try config.setCollapsed(io, work, true);
        try config.moveGroup(io, 0, 2);
        try config.moveGroup(io, 0, 3); // out of range
        try config.removeGroup(io, spare);
        try config.move(io, 1, 3);
        try config.remove(io, 0);
    }
    var restored = try Config.init(io, std.testing.allocator, &env);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.data.groups.len);
    try std.testing.expectEqualStrings("Side projects", restored.data.groups[0].name);
    try std.testing.expectEqualStrings("Work", restored.data.groups[1].name);
    try std.testing.expect(restored.data.groups[1].collapsed and !restored.data.groups[0].collapsed);
    const work = restored.data.groups[1].id;
    for (restored.data.repositories, "cdb") |repository, name| {
        try std.testing.expectEqual(name, repository.path[repository.path.len - 1]);
        try std.testing.expectEqual(if (name == 'd') @as(u32, 0) else work, repository.group);
        try std.testing.expectEqualStrings(if (name == 'b') "Backend" else &.{name}, repository.label());
    }
    try restored.rename(io, 2, "");
    try std.testing.expectEqualStrings("b", restored.data.repositories[2].label());
    // A name is cut on a character boundary, not through one.
    var long: [name_bytes_max + 2]u8 = @splat('x');
    @memcpy(long[name_bytes_max - 1 ..][0..2], "\u{e9}");
    try restored.rename(io, 2, &long);
    try std.testing.expectEqual(@as(usize, name_bytes_max - 1), restored.data.repositories[2].name.len);
}

test "a settings file with broken groups loads with entries ungrouped" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    const one = try std.fs.path.join(a, &.{ root, "one" });
    defer a.free(one);
    const two = try std.fs.path.join(a, &.{ root, "two" });
    defer a.free(two);
    const text = try std.json.Stringify.valueAlloc(a, .{
        .groups = .{ .{ .id = 0, .name = "Zero" }, .{ .id = 4, .name = "Kept" }, .{ .id = 4, .name = "Repeat" } },
        .repositories = .{ .{ .path = one, .group = 4 }, .{ .path = two, .group = 7 } },
    }, .{});
    defer a.free(text);
    try temp.dir.createDirPath(io, "Weaver");
    try temp.dir.writeFile(io, .{ .sub_path = "Weaver/settings.json", .data = text });
    var config = try Config.init(io, a, &env);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 1), config.data.groups.len);
    try std.testing.expectEqualStrings("Kept", config.data.groups[0].name);
    try std.testing.expectEqual(@as(u32, 4), config.data.repositories[0].group);
    try std.testing.expectEqual(@as(u32, 0), config.data.repositories[1].group);
}

test "placing an entry sets its group and its position among that group's entries" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEAVER_CONFIG_HOME", root);
    const expectOrder = struct {
        fn check(c: *const Config, comptime order: []const u8, comptime grouped: []const u8) !void {
            for (c.data.repositories, order) |repository, name| {
                try std.testing.expectEqual(name, repository.path[repository.path.len - 1]);
                try std.testing.expectEqual(std.mem.indexOfScalar(u8, grouped, name) != null, repository.group != 0);
            }
            try std.testing.expectEqual(@as(u8, 'd'), c.data.repositories[c.data.selected].path[c.data.repositories[c.data.selected].path.len - 1]);
        }
    }.check;
    {
        var config = try Config.init(io, std.testing.allocator, &env);
        defer config.deinit();
        for ([_][]const u8{ "a", "b", "c", "d" }) |name| try config.add(io, try std.fs.path.join(config.arena.allocator(), &.{ root, name }));
        const work = try config.addGroup(io, "Work");
        try config.place(io, 0, work, null); // first entry of the group stays put
        try expectOrder(&config, "abcd", "a");
        try config.place(io, 2, work, 0);
        try expectOrder(&config, "cabd", "ca");
        try config.place(io, 3, work, null);
        try expectOrder(&config, "cadb", "cad");
        try config.place(io, 0, 0, null); // out of the group, after the ungrouped entries
        try expectOrder(&config, "adbc", "ad");
        try config.place(io, 1, 9, null); // no such group
        try config.place(io, 1, 0, 1); // in front of itself
        try config.place(io, 1, 0, 7); // out of range
        try expectOrder(&config, "adbc", "ad");
    }
    var restored = try Config.init(io, std.testing.allocator, &env);
    defer restored.deinit();
    try expectOrder(&restored, "adbc", "ad");
}
