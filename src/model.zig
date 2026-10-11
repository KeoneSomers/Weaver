//! Provider-neutral values consumed by the UI and extension API.
const std = @import("std");
const diff = @import("diff.zig");
pub const File = struct { path: []const u8, old_path: []const u8 = "", status: []const u8, staged: bool, additions: usize = 0, deletions: usize = 0, patch: []const u8 = "", lines: []diff.Line = &.{}, binary: bool = false, stats_available: bool = true };
pub const Revision = struct { oid: []const u8, summary: []const u8, author: []const u8, time: i64 };
pub const RepositoryState = enum { normal, merging, rebasing, cherry_picking, reverting, bisecting, applying };
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8 = "",
    branch: []const u8 = "No commits yet",
    upstream: []const u8 = "",
    ahead: usize = 0,
    behind: usize = 0,
    state: RepositoryState = .normal,
    files: []File = &.{},
    history: []Revision = &.{},
    branches: [][]const u8 = &.{},
    remotes: [][]const u8 = &.{},
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};
pub const Capabilities = struct { staging: bool = false, branches: bool = false, remotes: bool = false, stash: bool = false, merge: bool = false, lfs: bool = false };
pub const Operation = enum { refresh, stage, unstage, stage_all, unstage_all, commit, amend, fetch, pull, push, publish, create_branch, switch_branch, rename_branch, delete_branch, force_delete_branch, merge, rebase, rebase_continue, rebase_abort, merge_abort, stash, stash_pop, add_remote, set_remote, remove_remote, tag, delete_tag, revert, cherry_pick, discard, initialize, clone, lfs_install, lfs_track, lfs_untrack, lfs_pull, lfs_push, lfs_status, lfs_locks, lfs_lock, lfs_unlock, diagnostics, stage_hunk, unstage_hunk, resolve_ours, resolve_theirs, merge_continue, cherry_pick_continue, cherry_pick_abort };
pub const Request = struct { operation: Operation, value: []const u8 = "", second: []const u8 = "" };
pub fn destructive(op: Operation) bool {
    return switch (op) {
        .discard, .amend, .delete_branch, .force_delete_branch, .delete_tag, .rebase, .rebase_abort, .merge_abort, .remove_remote, .set_remote, .stash_pop, .resolve_ours, .resolve_theirs, .cherry_pick_abort => true,
        else => false,
    };
}
