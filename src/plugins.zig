//! Protocol v1: manifest contributions + isolated JSON-line executable host.
const std = @import("std");
const model = @import("model.zig");
const process = @import("process.zig");
const config = @import("config.zig");
pub const Permission = enum { repository_read, repository_write, network, process_execution };
pub const Command = struct { id: []const u8, title: []const u8, operation: ?model.Operation = null, arguments: [][]const u8 = &.{} };
pub const Setting = struct { id: []const u8, title: []const u8, description: []const u8 = "", default: []const u8 = "" };
pub const Manifest = struct { api_version: u32 = 1, id: []const u8, name: []const u8, version: []const u8, description: []const u8, publisher: []const u8 = "Weaver", executable: ?[]const u8 = null, permissions: []const Permission = &.{}, commands: []const Command = &.{}, settings: []const Setting = &.{} };
pub const Extension = struct { manifest: Manifest, enabled: bool = true, builtin: bool = true, manifest_path: []const u8 = "", settings: []config.SettingValue = &.{}, inputs: []std.ArrayList(u8) = &.{} };
pub const bundled = [_]Extension{
    .{ .manifest = .{ .id = "weaver.github", .name = "GitHub", .version = "1.0.0", .description = "Device sign-in, secure credentials and repository publishing.", .permissions = &.{ .repository_read, .network } } },
    .{ .manifest = .{ .id = "weaver.lfs", .name = "Git LFS", .version = "1.0.0", .description = "Track large files, transfer objects and manage GitHub LFS locks.", .permissions = &.{ .repository_read, .repository_write, .network }, .commands = &.{
        .{ .id = "lfs.install", .title = "Enable LFS for this repository", .operation = .lfs_install },
        .{ .id = "lfs.status", .title = "LFS status", .operation = .lfs_status },
        .{ .id = "lfs.pull", .title = "Download LFS objects", .operation = .lfs_pull },
        .{ .id = "lfs.push", .title = "Upload LFS objects", .operation = .lfs_push },
        .{ .id = "lfs.locks", .title = "List LFS locks", .operation = .lfs_locks },
    } } },
    .{ .manifest = .{ .id = "weaver.appearance", .name = "Appearance", .version = "1.0.0", .description = "Dark, light and custom palettes with adjustable accents." } },
    .{ .manifest = .{ .id = "weaver.diagnostics", .name = "Repository diagnostics", .version = "1.0.0", .description = "Inspect Git runtime and installation health.", .permissions = &.{.repository_read}, .commands = &.{
        .{ .id = "diagnostics.git", .title = "Git runtime information", .operation = .diagnostics },
    } } },
};
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Extension) = .empty,
    pub fn init(a: std.mem.Allocator) !Registry {
        var self = Registry{ .arena = .init(a) };
        errdefer self.deinit();
        try self.items.appendSlice(self.arena.allocator(), &bundled);
        return self;
    }
    pub fn install(self: *Registry, io: std.Io, path: []const u8) !void {
        const a = self.arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 * 1024));
        const manifest = (try std.json.parseFromSlice(Manifest, a, bytes, .{ .allocate = .alloc_always })).value;
        if (manifest.api_version != 1 or !validId(manifest.id) or manifest.commands.len > 100 or manifest.name.len == 0 or manifest.publisher.len == 0) return error.InvalidExtensionManifest;
        _ = std.SemanticVersion.parse(manifest.version) catch return error.InvalidExtensionManifest;
        for (self.items.items) |item| if (std.mem.eql(u8, item.manifest.id, manifest.id)) return error.DuplicateExtension;
        if (manifest.executable) |exe| if (!std.fs.path.isAbsolute(exe)) return error.ExtensionExecutableMustBeAbsolute;
        if (manifest.commands.len > 0 and manifest.executable == null) return error.NoExtensionExecutable;
        for (manifest.commands, 0..) |command, i| {
            if (!validId(command.id) or command.title.len == 0 or command.operation != null) return error.InvalidExtensionCommand;
            for (manifest.commands[0..i]) |existing| if (std.mem.eql(u8, existing.id, command.id)) return error.DuplicateExtensionCommand;
            for (self.items.items) |existing| for (existing.manifest.commands) |registered_command| {
                if (std.mem.eql(u8, registered_command.id, command.id)) return error.DuplicateExtensionCommand;
            };
        }
        if (manifest.settings.len > 100) return error.InvalidExtensionSettings;
        const values = try a.alloc(config.SettingValue, manifest.settings.len);
        const inputs = try a.alloc(std.ArrayList(u8), manifest.settings.len);
        for (manifest.settings, 0..) |setting, i| {
            if (!validId(setting.id) or setting.title.len == 0 or setting.default.len > 4096) return error.InvalidExtensionSettings;
            for (manifest.settings[0..i]) |existing| if (std.mem.eql(u8, existing.id, setting.id)) return error.DuplicateExtensionSetting;
            values[i] = .{ .id = setting.id, .value = setting.default };
            inputs[i] = .empty;
            try inputs[i].appendSlice(a, setting.default);
        }
        try self.items.append(a, .{ .manifest = manifest, .builtin = false, .enabled = false, .manifest_path = try a.dupe(u8, path), .settings = values, .inputs = inputs });
    }
    pub fn enabled(self: *const Registry, id: []const u8) bool {
        for (self.items.items) |e| if (std.mem.eql(u8, id, e.manifest.id)) return e.enabled;
        return false;
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }
};
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') return false;
    return true;
}
pub fn invoke(io: std.Io, a: std.mem.Allocator, manifest: Manifest, command: Command, repository: []const u8, provider_id: []const u8, settings: []const config.SettingValue) !process.Result {
    const exe = manifest.executable orelse return error.NoExtensionExecutable;
    var configuration: std.json.ObjectMap = .empty;
    defer configuration.deinit(a);
    for (settings) |setting| try configuration.put(a, setting.id, .{ .string = setting.value });
    const message = try std.json.Stringify.valueAlloc(a, .{ .api_version = 1, .method = "command.execute", .command = command.id, .repository = .{ .path = repository, .provider = provider_id }, .arguments = command.arguments, .configuration = std.json.Value{ .object = configuration } }, .{});
    defer a.free(message);
    const input = try std.fmt.allocPrint(a, "{s}\n", .{message});
    defer a.free(input);
    var result = try process.run(io, a, &.{exe}, repository, input);
    errdefer result.deinit(a);
    if (result.ok) {
        const parsed = std.json.parseFromSlice(std.json.Value, a, result.stdout, .{}) catch return result;
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("summary")) |summary| {
            if (summary == .string) {
                const copy = try a.dupe(u8, summary.string);
                a.free(result.stdout);
                result.stdout = copy;
            }
        };
    }
    return result;
}

test "external extensions validate API, executable paths and command identities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    const path = try std.fs.path.join(a, &.{ root, "manifest.json" });
    defer a.free(path);
    const exe = try std.process.executablePathAlloc(io, a);
    defer a.free(exe);
    var registry = try Registry.init(a);
    defer registry.deinit();
    var manifest = Manifest{ .id = "example.audit", .name = "Audit", .publisher = "Example", .version = "1.0.0", .description = "Test", .executable = exe, .commands = &.{.{ .id = "example.audit.run", .title = "Audit" }} };
    {
        const bytes = try std.json.Stringify.valueAlloc(a, manifest, .{});
        defer a.free(bytes);
        try temp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = bytes });
        try registry.install(io, path);
        try std.testing.expect(!registry.items.items[registry.items.items.len - 1].enabled);
        try std.testing.expectError(error.DuplicateExtension, registry.install(io, path));
    }
    manifest.id = "example.other";
    {
        const bytes = try std.json.Stringify.valueAlloc(a, manifest, .{});
        defer a.free(bytes);
        try temp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = bytes });
        try std.testing.expectError(error.DuplicateExtensionCommand, registry.install(io, path));
    }
    manifest.commands = &.{};
    manifest.executable = "relative.exe";
    {
        const bytes = try std.json.Stringify.valueAlloc(a, manifest, .{});
        defer a.free(bytes);
        try temp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = bytes });
        try std.testing.expectError(error.ExtensionExecutableMustBeAbsolute, registry.install(io, path));
    }
    manifest.api_version = 99;
    {
        const bytes = try std.json.Stringify.valueAlloc(a, manifest, .{});
        defer a.free(bytes);
        try temp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = bytes });
        try std.testing.expectError(error.InvalidExtensionManifest, registry.install(io, path));
    }
}
