//! Native invalidation signals, never a substitute for Git's authoritative status.
const std = @import("std");
const builtin = @import("builtin");
const git = @import("git.zig");
const c = @import("git2");
const windows = std.os.windows;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, windows.DWORD) callconv(.winapi) windows.DWORD;
const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, event: ?windows.HANDLE = null };
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn CreateEventW(?*anyopaque, windows.BOOL, windows.BOOL, ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(windows.HANDLE, *anyopaque, u32, windows.BOOL, u32, ?*u32, *Overlapped, ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetOverlappedResult(windows.HANDLE, *Overlapped, *u32, windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CancelIoEx(windows.HANDLE, *Overlapped) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;

const Entry = struct {
    directory: windows.HANDLE,
    event: windows.HANDLE,
    overlapped: Overlapped,
    buffer: [32768]u8 align(4) = undefined,
    metadata: bool,
    pending: bool = false,
    fn arm(self: *Entry) !void {
        self.overlapped = .{ .event = self.event };
        if (ReadDirectoryChangesW(self.directory, &self.buffer, self.buffer.len, .TRUE, 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x100, null, &self.overlapped, null) == .FALSE) return error.RepositoryWatchUnavailable;
        self.pending = true;
    }
    fn destroy(self: *Entry, a: std.mem.Allocator) void {
        if (self.pending) {
            _ = CancelIoEx(self.directory, &self.overlapped);
            var bytes: u32 = 0;
            _ = GetOverlappedResult(self.directory, &self.overlapped, &bytes, .TRUE);
        }
        _ = CloseHandle(self.directory);
        _ = CloseHandle(self.event);
        a.destroy(self);
    }
};

pub const Signal = enum { cancelled, reconfigure, changed, heartbeat };
pub const Watcher = struct {
    path: []const u8 = "",
    entries: [3]?*Entry = @splat(null),
    allocator: std.mem.Allocator = undefined,
    native: bool = false,

    pub fn deinit(self: *Watcher, a: std.mem.Allocator) void {
        if (builtin.os.tag == .windows) for (self.entries) |entry| {
            if (entry) |e| e.destroy(a);
        };
        a.free(self.path);
        self.* = .{};
    }

    /// Call only between waits. Failure leaves the slower, quiet fallback active.
    pub fn reset(self: *Watcher, a: std.mem.Allocator, path: []const u8) !void {
        self.deinit(a);
        self.path = try a.dupe(u8, path);
        self.allocator = a;
        if (builtin.os.tag != .windows) return;
        const repo = try git.open(a, path);
        defer c.git_repository_free(repo);
        const roots = [_][]const u8{ path, std.mem.span(c.git_repository_path(repo)), std.mem.span(c.git_repository_commondir(repo)) };
        errdefer {
            for (&self.entries) |*entry| if (entry.*) |e| {
                e.destroy(a);
                entry.* = null;
            };
        }
        // Separate Git directories matter for linked worktrees and --separate-git-dir.
        for (roots, 0..) |root, i| {
            var covered = false;
            for (roots[0..i]) |previous| if (contains(previous, root)) {
                covered = true;
                break;
            };
            if (covered) continue;
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, root);
            defer a.free(wide);
            const directory = CreateFileW(wide, 1, 7, null, 3, 0x02000000 | 0x40000000, null);
            if (directory == windows.INVALID_HANDLE_VALUE) return error.RepositoryWatchUnavailable;
            const event = CreateEventW(null, .TRUE, .FALSE, null) orelse {
                _ = CloseHandle(directory);
                return error.RepositoryWatchUnavailable;
            };
            const entry = a.create(Entry) catch |err| {
                _ = CloseHandle(directory);
                _ = CloseHandle(event);
                return err;
            };
            entry.* = .{ .directory = directory, .event = event, .overlapped = .{ .event = event }, .metadata = i != 0 };
            self.entries[i] = entry;
            try entry.arm();
        }
        self.native = true;
    }

    pub fn poll(self: *Watcher) !bool {
        if (builtin.os.tag != .windows or !self.native) return false;
        var changed = false;
        for (self.entries) |entry| if (entry) |e| {
            switch (WaitForSingleObject(e.event, 0)) {
                0 => {
                    var bytes: u32 = 0;
                    const completed = GetOverlappedResult(e.directory, &e.overlapped, &bytes, .FALSE);
                    e.pending = false;
                    // Overflow or a lost batch invalidates conservatively.
                    if (completed == .FALSE or bytes == 0) {
                        changed = true;
                    } else {
                        var offset: usize = 0;
                        while (offset + 12 <= bytes) {
                            const record = e.buffer[offset..bytes];
                            const next = std.mem.readInt(u32, record[0..4], .little);
                            const length = std.mem.readInt(u32, record[8..12], .little);
                            if (length % 2 != 0 or length > record.len - 12) {
                                changed = true;
                                break;
                            }
                            const name = try std.unicode.utf16LeToUtf8Alloc(self.allocator, @alignCast(std.mem.bytesAsSlice(u16, record[12..][0..length])));
                            defer self.allocator.free(name);
                            if (relevant(name, e.metadata)) changed = true;
                            if (next == 0) break;
                            if (next < 12 or next % 4 != 0 or next > record.len) {
                                changed = true;
                                break;
                            }
                            offset += next;
                        }
                    }
                    try e.arm();
                },
                258 => {}, // WAIT_TIMEOUT
                else => return error.RepositoryWatchUnavailable,
            }
        };
        return changed;
    }

    /// Poll notification handles off the UI thread. Sleep remains cancellable at
    /// shutdown. A repository switch wakes within 250ms; no files are enumerated.
    pub fn wait(self: *Watcher, io: std.Io, epoch: *const std.atomic.Value(u64), expected: u64) Signal {
        var elapsed_ms: u32 = 0;
        var quiet_ms: u32 = 0;
        var burst_ms: u32 = 0;
        var dirty = false;
        const timeout_ms: u32 = if (self.path.len == 0) 1000 else 30000;
        while (elapsed_ms < timeout_ms) {
            std.Io.sleep(io, .fromMilliseconds(250), .awake) catch return .cancelled;
            if (epoch.load(.acquire) != expected) return .reconfigure;
            elapsed_ms += 250;
            const changed = self.poll() catch {
                self.native = false;
                return .changed; // Conservative invalidation; subsequent waits fall back.
            };
            if (changed) {
                dirty = true;
                quiet_ms = 0;
            } else if (dirty) quiet_ms += 250;
            if (dirty) {
                burst_ms += 250;
                if (quiet_ms >= 750 or burst_ms >= 2000) return .changed;
            }
        }
        return if (dirty) .changed else .heartbeat;
    }
};

fn relevant(name: []const u8, metadata: bool) bool {
    var path = name;
    if (!metadata) {
        if (path.len < 5 or !std.ascii.eqlIgnoreCase(path[0..4], ".git") or (path[4] != '/' and path[4] != '\\')) return true;
        path = path[5..];
    }
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    var first = components.next() orelse return true;
    if (std.ascii.eqlIgnoreCase(first, "worktrees")) {
        _ = components.next(); // Worktree identifier, which may itself be "logs".
        first = components.next() orelse return true;
    }
    if (std.ascii.eqlIgnoreCase(first, "objects") or std.ascii.eqlIgnoreCase(first, "logs") or
        std.ascii.startsWithIgnoreCase(first, "fsmonitor") or std.ascii.endsWithIgnoreCase(first, ".lock") or
        std.ascii.eqlIgnoreCase(first, "COMMIT_EDITMSG")) return false;
    while (components.next()) |part| {
        if (std.ascii.endsWithIgnoreCase(part, ".lock")) return false;
    }
    return true;
}

test "Git monitor IPC, objects and lock files never feed automatic reads" {
    try std.testing.expect(!relevant(".git\\fsmonitor--daemon.ipc", false));
    try std.testing.expect(!relevant("fsmonitor--daemon.ipc", true));
    try std.testing.expect(!relevant(".git/objects/pack/new.pack", false));
    try std.testing.expect(!relevant(".git/index.lock", false));
    try std.testing.expect(relevant(".git/index", false));
    try std.testing.expect(relevant("worktrees/linked/index", true));
    try std.testing.expect(relevant("refs/heads/main", true));
    try std.testing.expect(relevant("refs/heads/objects/fsmonitor-feature", true));
    try std.testing.expect(!relevant("worktrees/linked/logs/HEAD", true));
    try std.testing.expect(relevant(".gitignore", false));
    try std.testing.expect(relevant("src/objects/file.zig", false));
}

fn contains(parent: []const u8, child: []const u8) bool {
    const root = std.mem.trimEnd(u8, parent, "/\\");
    const path = std.mem.trimEnd(u8, child, "/\\");
    return path.len >= root.len and @import("config.zig").equalPath(root, path[0..root.len]) and
        (path.len == root.len or path[root.len] == '/' or path[root.len] == '\\');
}

test "watch roots preserve directory boundaries and cover nested Git metadata" {
    try std.testing.expect(contains("C:/repo/", "C:/repo/.git/"));
    try std.testing.expect(!contains("C:/repo", "C:/repository/.git"));
    try std.testing.expect(!contains("C:/linked", "C:/main/.git/worktrees/linked"));
}
