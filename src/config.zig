const std = @import("std");
pub const Theme = enum { dark, graphite, midnight, ocean, forest, plum, nord, light, sand, paper };
pub const TextSize = enum { small, medium, large, extra_large };
pub const DiffFont = enum { mono, sans };
pub const SettingValue = struct { id: []const u8, value: []const u8 };
pub const ExtensionState = struct { id: []const u8, manifest_path: []const u8 = "", enabled: bool = true, settings: []SettingValue = &.{} };
/// `icon` is a Lucide glyph name and `icon_color` a hex color; empty means the default.
pub const Repository = struct { path: []const u8, provider: []const u8 = "git", last_fetched: ?i64 = null, icon: []const u8 = "", icon_color: []const u8 = "" };
pub const Data = struct { version: u32 = 1, repositories: []Repository = &.{}, selected: usize = 0, theme: Theme = .graphite, accent: []const u8 = "#B4A0FF", text_size: TextSize = .medium, diff_font: DiffFont = .mono, diff_font_size: u8 = 11, split_diff: bool = false, oauth_client_id: []const u8 = "", release_repo: []const u8 = "", extensions: []ExtensionState = &.{}, auto_refresh: bool = true, auto_fetch: bool = true, auto_update_check: bool = true, github_login: []const u8 = "" };
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
    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};
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
