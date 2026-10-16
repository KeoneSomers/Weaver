//! Small sidebar summaries, refreshed only after native invalidation (or fallback).
const std = @import("std");
const git = @import("git.zig");
const process = @import("process.zig");
const config = @import("config.zig");
const Watcher = @import("repository_watch.zig").Watcher;

pub const Status = enum {
    clean,
    dirty,
    outgoing,

    pub fn description(self: Status) []const u8 {
        return switch (self) {
            .clean => "No uncommitted changes or commits to push",
            .dirty => "Uncommitted changes",
            .outgoing => "Commits ready to push",
        };
    }
};
pub const Summary = struct { path: []const u8, status: ?Status, revision: u64 };

pub fn fromSnapshot(snapshot: @import("model.zig").Snapshot) Status {
    if (snapshot.files.len > 0) return .dirty;
    if (snapshot.ahead > 0) for (snapshot.branches) |branch| {
        if (std.mem.eql(u8, branch, snapshot.branch)) return .outgoing;
    };
    return .clean;
}

pub fn read(io: std.Io, a: std.mem.Allocator, path: []const u8) !Status {
    // Git applies the repository's clean/LFS filters and ignore rules. No patches,
    // history or per-file allocations are needed just to decide whether to dot.
    const result = try process.git(io, a, path, &.{ "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--no-renames" });
    defer result.deinit(a);
    if (!result.ok) return error.GitStatusFailed;
    if (result.stdout.len > 0) return .dirty;
    return if (try git.hasOutgoing(a, path)) .outgoing else .clean;
}

const Entry = struct {
    watcher: Watcher = .{},
    status: ?Status = null,
    revision: u64 = 1,
    pending: bool = false,
    quiet_ms: u32 = 0,
    burst_ms: u32 = 0,
    fallback_ms: u32 = 0,
};

/// Owned by one background job at a time. The UI reads only copied summaries.
pub const Monitor = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Monitor, a: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.watcher.deinit(a);
        self.entries.deinit(a);
    }

    pub fn update(self: *Monitor, io: std.Io, a: std.mem.Allocator, output: std.mem.Allocator, paths: []const []const u8, automatic: bool) ![]Summary {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = &self.entries.items[index];
            var keep = false;
            for (paths) |path| if (config.equalPath(entry.watcher.path, path)) {
                keep = true;
                break;
            };
            if (keep) {
                index += 1;
            } else {
                entry.watcher.deinit(a);
                _ = self.entries.swapRemove(index);
            }
        }
        for (paths) |path| {
            var found = false;
            for (self.entries.items) |entry| if (config.equalPath(entry.watcher.path, path)) {
                found = true;
                break;
            };
            if (found) continue;
            var entry: Entry = .{};
            errdefer entry.watcher.deinit(a);
            // Arm before reading, so changes during the first read are covered.
            entry.watcher.reset(a, path) catch {};
            if (entry.watcher.path.len == 0) return error.OutOfMemory;
            entry.status = read(io, a, path) catch null;
            try self.entries.append(a, entry);
        }
        // Notification handles are polled off the UI thread without enumerating
        // files. Debounce bursts like the selected repository's existing watcher.
        for (0..4) |_| {
            try std.Io.sleep(io, .fromMilliseconds(250), .awake);
            for (self.entries.items) |*entry| {
                const changed = entry.watcher.poll() catch blk: {
                    entry.watcher.native = false;
                    break :blk true;
                };
                if (!automatic) continue;
                entry.fallback_ms +|= 250;
                if (changed) {
                    entry.pending = true;
                    entry.quiet_ms = 0;
                } else if (entry.pending) entry.quiet_ms += 250;
                if (entry.pending) entry.burst_ms += 250;
                const fallback = !entry.watcher.native and entry.fallback_ms >= 30000;
                if (fallback or (entry.pending and (entry.quiet_ms >= 750 or entry.burst_ms >= 2000))) {
                    if (!entry.watcher.native) {
                        const path = try a.dupe(u8, entry.watcher.path);
                        defer a.free(path);
                        entry.watcher.reset(a, path) catch {};
                    }
                    entry.status = read(io, a, entry.watcher.path) catch null;
                    entry.revision +%= 1;
                    entry.pending = false;
                    entry.quiet_ms = 0;
                    entry.burst_ms = 0;
                    entry.fallback_ms = 0;
                }
            }
        }
        const summaries = try output.alloc(Summary, self.entries.items.len);
        for (self.entries.items, summaries) |entry, *summary| summary.* = .{ .path = try output.dupe(u8, entry.watcher.path), .status = entry.status, .revision = entry.revision };
        return summaries;
    }
};
