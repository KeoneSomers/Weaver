const std = @import("std");
const model = @import("model.zig");
const process = @import("process.zig");
const git_backend = @import("git.zig");
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    capabilities: model.Capabilities,
    load: *const fn (std.Io, std.mem.Allocator, []const u8) anyerror!model.Snapshot,
    scan: *const fn (std.Io, std.mem.Allocator, []const u8) anyerror!model.Snapshot,
    counts: *const fn (std.Io, std.mem.Allocator, []const u8, []const model.File) anyerror!model.Snapshot,
    preview: *const fn (std.Io, std.mem.Allocator, []const u8, model.File) anyerror!model.Snapshot,
    revision: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!model.Snapshot,
    execute: *const fn (std.Io, std.mem.Allocator, []const u8, model.Request) anyerror!process.Result,
    background_fetch: ?*const fn (std.Io, std.mem.Allocator, []const u8, *const std.process.Environ.Map) anyerror!process.Result = null,
};
const reader = @import("git_reader.zig");
pub const git: Provider = .{ .id = "git", .name = "Git", .capabilities = .{ .staging = true, .branches = true, .remotes = true, .stash = true, .merge = true, .lfs = true }, .load = loadGit, .scan = reader.scan, .counts = reader.counts, .preview = reader.preview, .revision = git_backend.commitFiles, .execute = executeGit, .background_fetch = process.backgroundFetch };
pub const registered = [_]*const Provider{&git};
pub fn byId(id: []const u8) ?*const Provider {
    for (registered) |provider| if (std.mem.eql(u8, provider.id, id)) return provider;
    return null;
}
fn loadGit(io: std.Io, a: std.mem.Allocator, path: []const u8) !model.Snapshot {
    var snapshot = try git_backend.load(a, path);
    errdefer snapshot.deinit();
    try reconcileFilters(io, a, &snapshot);
    for (snapshot.files) |*file| if (!file.stats_available) {
        const stats = try process.git(io, a, snapshot.path, if (file.staged)
            &.{ "diff", "--cached", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--", file.path, file.old_path }
        else
            &.{ "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--", file.path, file.old_path });
        defer stats.deinit(a);
        if (!stats.ok or stats.stdout.len == 0) continue;
        var fields = std.mem.splitScalar(u8, stats.stdout, '\t');
        const added = fields.next() orelse continue;
        const deleted = fields.next() orelse continue;
        if (std.mem.eql(u8, added, "-") or std.mem.eql(u8, deleted, "-")) {
            file.binary = true;
        } else {
            file.additions = std.fmt.parseInt(usize, added, 10) catch continue;
            file.deletions = std.fmt.parseInt(usize, deleted, 10) catch continue;
        }
        file.stats_available = true;
    };
    return snapshot;
}
/// libgit2 does not execute external clean filters. Ask Git to reconcile paths
/// with configured filters, especially hydrated LFS objects, before displaying status.
fn reconcileFilters(io: std.Io, a: std.mem.Allocator, snapshot: *model.Snapshot) !void {
    if (snapshot.files.len == 0) return;
    const arena = snapshot.arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    for (snapshot.files) |file| {
        try input.appendSlice(arena, file.path);
        try input.append(arena, 0);
    }
    const attributes = try process.gitInput(io, a, snapshot.path, &.{ "check-attr", "-z", "--stdin", "filter" }, input.items);
    defer attributes.deinit(a);
    if (!attributes.ok) return error.GitAttributeCheckFailed;
    var filtered: std.StringHashMap(void) = .init(arena);
    var fields = std.mem.splitScalar(u8, attributes.stdout, 0);
    while (fields.next()) |name| {
        if (name.len == 0) break;
        _ = fields.next() orelse break;
        const value = fields.next() orelse break;
        if (!std.mem.eql(u8, value, "unspecified") and !std.mem.eql(u8, value, "unset")) try filtered.put(try arena.dupe(u8, name), {});
    }
    var output: std.ArrayList(model.File) = .empty;
    for (snapshot.files) |file| {
        if (!filtered.contains(file.path) or std.mem.eql(u8, file.status, "Untracked") or std.mem.eql(u8, file.status, "Conflict")) {
            try output.append(arena, file);
            continue;
        }
        const status = try process.git(io, a, snapshot.path, &.{ "status", "--porcelain=v1", "-z", "--", file.path });
        defer status.deinit(a);
        if (!status.ok) return error.GitFilterStatusFailed;
        if (status.stdout.len < 3) continue;
        if (status.stdout[if (file.staged) @as(usize, 0) else 1] == ' ') continue;
        const patch = try process.git(io, a, snapshot.path, if (file.staged) &.{ "diff", "--cached", "--no-ext-diff", "--no-textconv", "--", file.path } else &.{ "diff", "--no-ext-diff", "--no-textconv", "--", file.path });
        defer patch.deinit(a);
        if (!patch.ok) return error.GitFilterDiffFailed;
        var copy = file;
        copy.patch = try arena.dupe(u8, patch.stdout);
        copy.lines = if (std.unicode.utf8ValidateSlice(copy.patch)) try @import("diff.zig").parse(arena, copy.patch) else &.{};
        copy.additions = 0;
        copy.deletions = 0;
        copy.stats_available = true;
        copy.binary = !std.unicode.utf8ValidateSlice(copy.patch) or std.mem.indexOf(u8, copy.patch, "Binary files") != null;
        for (copy.lines) |line| switch (line.kind) {
            .addition => copy.additions += 1,
            .deletion => copy.deletions += 1,
            else => {},
        };
        try output.append(arena, copy);
    }
    snapshot.files = try output.toOwnedSlice(arena);
}

fn executeGit(io: std.Io, a: std.mem.Allocator, path: []const u8, request: model.Request) !process.Result {
    const v = request.value;
    const s = request.second;
    if (request.operation == .resolve_ours or request.operation == .resolve_theirs) {
        const checkout = try process.git(io, a, path, &.{ "checkout", if (request.operation == .resolve_ours) "--ours" else "--theirs", "--", v });
        if (!checkout.ok) return checkout;
        checkout.deinit(a);
        return process.git(io, a, path, &.{ "add", "--", v });
    }
    if (request.operation == .stage_hunk or request.operation == .unstage_hunk) return process.gitInput(io, a, path, if (request.operation == .stage_hunk)
        &.{ "apply", "--cached", "--recount", "--whitespace=nowarn", "-" }
    else
        &.{ "apply", "--cached", "--reverse", "--recount", "--whitespace=nowarn", "-" }, v);
    if (request.operation == .unstage or request.operation == .unstage_all) {
        const head = try process.git(io, a, path, &.{ "rev-parse", "--verify", "HEAD" });
        defer head.deinit(a);
        if (!head.ok) return process.git(io, a, path, if (request.operation == .unstage) &.{ "rm", "--cached", "--force", "--", v } else &.{ "rm", "--cached", "--force", "-r", "--", "." });
    }
    switch (request.operation) {
        .create_branch, .switch_branch, .rename_branch, .delete_branch, .force_delete_branch, .merge, .rebase, .tag, .delete_tag, .cherry_pick, .revert, .add_remote, .set_remote, .remove_remote, .lfs_track, .lfs_untrack, .lfs_lock, .lfs_unlock, .publish => if (!process.validName(v)) return error.InvalidArgument,
        else => {},
    }
    if ((request.operation == .add_remote or request.operation == .set_remote or request.operation == .clone) and !process.validRemote(if (request.operation == .clone) v else s)) return error.InvalidRemote;
    if ((request.operation == .publish or request.operation == .rename_branch or (request.operation == .create_branch and s.len > 0)) and !process.validName(s)) return error.InvalidArgument;
    if (request.operation == .clone and !std.fs.path.isAbsolute(s)) return error.ExpectedAbsoluteCloneDestination;
    const args: []const []const u8 = switch (request.operation) {
        .stage => &.{ "add", "--", v },
        .unstage => if (s.len > 0 and !std.mem.eql(u8, v, s)) &.{ "restore", "--staged", "--", v, s } else &.{ "restore", "--staged", "--", v },
        .stage_all => &.{ "add", "--all" },
        .unstage_all => &.{ "reset", "--mixed" },
        .commit => &.{ "commit", "-m", v },
        .amend => &.{ "commit", "--amend", "-m", v },
        .fetch => &.{ "fetch", "--all", "--prune" },
        .pull => &.{ "pull", "--ff-only" },
        .push => &.{"push"},
        .publish => &.{ "push", "--set-upstream", s, v },
        // An optional start point; without one the branch starts at HEAD.
        .create_branch => if (s.len > 0) &.{ "switch", "-c", v, s } else &.{ "switch", "-c", v },
        .switch_branch => &.{ "switch", "--", v },
        .rename_branch => &.{ "branch", "-m", "--", v, s },
        .delete_branch => &.{ "branch", "-d", "--", v },
        .force_delete_branch => &.{ "branch", "-D", "--", v },
        .merge => &.{ "merge", "--", v },
        .rebase => &.{ "rebase", v },
        .rebase_continue => &.{ "-c", "core.editor=true", "rebase", "--continue" },
        .rebase_abort => &.{ "rebase", "--abort" },
        .merge_abort => &.{ "merge", "--abort" },
        .merge_continue => &.{ "commit", "--no-edit" },
        .cherry_pick_continue => &.{ "-c", "core.editor=true", "cherry-pick", "--continue" },
        .cherry_pick_abort => &.{ "cherry-pick", "--abort" },
        .stash => &.{ "stash", "push", "--include-untracked", "-m", if (v.len == 0) "Weaver stash" else v },
        .stash_pop => &.{ "stash", "pop" },
        .add_remote => &.{ "remote", "add", v, s },
        .set_remote => &.{ "remote", "set-url", v, s },
        .remove_remote => &.{ "remote", "remove", v },
        .tag => &.{ "tag", "--", v },
        .delete_tag => &.{ "tag", "-d", "--", v },
        .revert => &.{ "revert", "--no-edit", v },
        .cherry_pick => &.{ "cherry-pick", v },
        .discard => &.{ "restore", "--worktree", "--", v },
        .initialize => &.{ "init", "--initial-branch=main", "--", path },
        .clone => &.{ "clone", "--", v, s },
        .lfs_install => &.{ "lfs", "install", "--local" },
        .lfs_track => &.{ "lfs", "track", "--", v },
        .lfs_untrack => &.{ "lfs", "untrack", "--", v },
        .lfs_pull => &.{ "lfs", "pull" },
        .lfs_push => &.{ "lfs", "push", "origin", "HEAD" },
        .lfs_status => &.{ "lfs", "status" },
        .lfs_locks => &.{ "lfs", "locks" },
        .lfs_lock => &.{ "lfs", "lock", "--", v },
        .lfs_unlock => &.{ "lfs", "unlock", "--", v },
        .diagnostics => &.{ "version", "--build-options" },
        .refresh, .stage_hunk, .unstage_hunk, .resolve_ours, .resolve_theirs => return error.InvalidOperation,
    };
    if (request.operation == .clone) return process.git(io, a, path, args);
    return process.git(io, a, path, args);
}
