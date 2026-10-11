const std = @import("std");
const c = @import("git2");
const diff_model = @import("diff.zig");
pub const File = @import("model.zig").File;
pub const History = @import("model.zig").Revision;
pub const Snapshot = @import("model.zig").Snapshot;
pub fn init() !void {
    try check(c.git_libgit2_init());
}
pub fn shutdown() void {
    _ = c.git_libgit2_shutdown();
}
pub fn check(result: c_int) !void {
    if (result < 0) return error.GitFailure;
}
pub fn lastError() []const u8 {
    const e = c.git_error_last();
    return if (e != null and e.*.message != null) std.mem.span(e.*.message) else "Git operation failed";
}
pub fn open(a: std.mem.Allocator, path: []const u8) !*c.git_repository {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, z));
    return repo.?;
}
pub const Discovery = struct { path: []const u8, remotes: [][]const u8 };
/// Prefer origin, then the first remote with a usable web destination.
pub fn repositoryWebUrl(a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const repo = try open(a, path);
    defer c.git_repository_free(repo);
    if (try remoteWebUrl(a, repo, "origin")) |url| return url;
    var names = std.mem.zeroes(c.git_strarray);
    try check(c.git_remote_list(&names, repo));
    defer c.git_strarray_dispose(&names);
    for (strings(names)) |name| {
        if (std.mem.eql(u8, std.mem.span(name), "origin")) continue;
        if (try remoteWebUrl(a, repo, name)) |url| return url;
    }
    return null;
}
fn strings(array: c.git_strarray) []const [*c]u8 {
    return if (array.strings == null) &.{} else array.strings[0..array.count];
}
fn remoteWebUrl(a: std.mem.Allocator, repo: *c.git_repository, name: [*c]const u8) !?[]const u8 {
    var remote: ?*c.git_remote = null;
    const status = c.git_remote_lookup(&remote, repo, name);
    if (status == c.GIT_ENOTFOUND) return null;
    try check(status);
    defer c.git_remote_free(remote);
    const url = c.git_remote_url(remote);
    if (url == null) return null;
    return @import("repository_links.zig").webUrl(a, std.mem.span(url));
}
/// Lightweight discovery, including linked worktrees. The caller
/// owns the returned strings; use an arena for the discovery's lifetime.
pub fn discover(a: std.mem.Allocator, path: []const u8) !?Discovery {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var repo: ?*c.git_repository = null;
    // NO_SEARCH avoids adopting an enclosing repo when adding a new project folder.
    const status = c.git_repository_open_ext(&repo, z, c.GIT_REPOSITORY_OPEN_NO_SEARCH, null);
    if (status == c.GIT_ENOTFOUND) return null; // Offer setup only for non-repositories.
    try check(status);
    defer c.git_repository_free(repo);
    const wd = c.git_repository_workdir(repo);
    if (wd == null) return error.BareRepository;
    return .{ .path = try a.dupe(u8, std.mem.span(wd)), .remotes = try refs(a, repo.?, true) };
}
pub fn load(a: std.mem.Allocator, path: []const u8) !Snapshot {
    return loadMode(a, path, true);
}
/// Repository metadata without scanning or materializing working-tree patches.
pub fn metadata(a: std.mem.Allocator, path: []const u8) !Snapshot {
    return loadMode(a, path, false);
}
fn loadMode(a: std.mem.Allocator, path: []const u8, changes: bool) !Snapshot {
    var snap = Snapshot{ .arena = .init(a) };
    errdefer snap.deinit();
    const arena = snap.arena.allocator();
    const repo = try open(arena, path);
    defer c.git_repository_free(repo);
    const wd = c.git_repository_workdir(repo);
    if (wd == null) return error.BareRepository;
    snap.path = try arena.dupe(u8, std.mem.span(wd));
    snap.state = switch (c.git_repository_state(repo)) {
        c.GIT_REPOSITORY_STATE_MERGE => .merging,
        c.GIT_REPOSITORY_STATE_REVERT, c.GIT_REPOSITORY_STATE_REVERT_SEQUENCE => .reverting,
        c.GIT_REPOSITORY_STATE_CHERRYPICK, c.GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE => .cherry_picking,
        c.GIT_REPOSITORY_STATE_BISECT => .bisecting,
        c.GIT_REPOSITORY_STATE_REBASE, c.GIT_REPOSITORY_STATE_REBASE_INTERACTIVE, c.GIT_REPOSITORY_STATE_REBASE_MERGE => .rebasing,
        c.GIT_REPOSITORY_STATE_APPLY_MAILBOX, c.GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE => .applying,
        else => .normal,
    };
    var head: ?*c.git_reference = null;
    var tree: ?*c.git_tree = null;
    if (c.git_repository_head(&head, repo) == 0) {
        defer c.git_reference_free(head);
        snap.branch = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(head)));
        const oid = c.git_reference_target(head);
        if (oid != null) {
            var commit: ?*c.git_commit = null;
            try check(c.git_commit_lookup(&commit, repo, oid));
            defer c.git_commit_free(commit);
            try check(c.git_commit_tree(&tree, commit));
            var upstream: ?*c.git_reference = null;
            if (c.git_branch_upstream(&upstream, head) == 0) {
                defer c.git_reference_free(upstream);
                snap.upstream = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(upstream)));
                const upstream_oid = c.git_reference_target(upstream);
                if (upstream_oid != null) try check(c.git_graph_ahead_behind(&snap.ahead, &snap.behind, repo, oid, upstream_oid));
            } else snap.ahead = try unpublished(repo);
        }
    }
    defer c.git_tree_free(tree);
    snap.history = try history(arena, repo);
    snap.branches = try refs(arena, repo, false);
    snap.remotes = try refs(arena, repo, true);
    if (!changes) return snap;
    var files: std.ArrayList(File) = .empty;
    var staged: ?*c.git_diff = null;
    try check(c.git_diff_tree_to_index(&staged, repo, tree, null, null));
    defer c.git_diff_free(staged);
    try check(c.git_diff_find_similar(staged, null));
    try appendDiff(arena, staged.?, true, &files);
    var unstaged: ?*c.git_diff = null;
    try check(c.git_diff_index_to_workdir(&unstaged, repo, null, null));
    defer c.git_diff_free(unstaged);
    try check(c.git_diff_find_similar(unstaged, null));
    try appendDiff(arena, unstaged.?, false, &files);
    var ctx = StatusContext{ .a = arena, .files = &files };
    var options: c.git_status_options = undefined;
    try check(c.git_status_options_init(&options, c.GIT_STATUS_OPTIONS_VERSION));
    options.flags = c.GIT_STATUS_OPT_INCLUDE_UNTRACKED | c.GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    try check(c.git_status_foreach_ext(repo, &options, statusCallback, &ctx));
    if (ctx.failed) return error.OutOfMemory;
    snap.files = try files.toOwnedSlice(arena);
    return snap;
}
const StatusContext = struct { a: std.mem.Allocator, files: *std.ArrayList(File), failed: bool = false };
fn statusCallback(path: [*c]const u8, status: c_uint, payload: ?*anyopaque) callconv(.c) c_int {
    const ctx: *StatusContext = @ptrCast(@alignCast(payload.?));
    if (status & (c.GIT_STATUS_WT_NEW | c.GIT_STATUS_CONFLICTED) == 0) return 0;
    ctx.files.append(ctx.a, .{
        .path = ctx.a.dupe(u8, std.mem.span(path)) catch {
            ctx.failed = true;
            return -1;
        },
        .status = if (status & c.GIT_STATUS_CONFLICTED != 0) "Conflict" else "Untracked",
        .staged = false,
    }) catch {
        ctx.failed = true;
        return -1;
    };
    return 0;
}
pub fn appendDiff(a: std.mem.Allocator, d: *c.git_diff, staged: bool, files: *std.ArrayList(File)) !void {
    for (0..c.git_diff_num_deltas(d)) |i| {
        const delta: *const c.git_diff_delta = c.git_diff_get_delta(d, i);
        if (delta.status == c.GIT_DELTA_UNMODIFIED or delta.status == c.GIT_DELTA_CONFLICTED) continue; // Conflicts come from the status callback, once per path.
        var item = File{
            .path = try a.dupe(u8, std.mem.span(if (delta.new_file.path != null) delta.new_file.path else delta.old_file.path)),
            .old_path = if (delta.old_file.path != null) try a.dupe(u8, std.mem.span(delta.old_file.path)) else "",
            .status = switch (delta.status) {
                c.GIT_DELTA_ADDED => "Added",
                c.GIT_DELTA_DELETED => "Deleted",
                c.GIT_DELTA_RENAMED => "Renamed",
                c.GIT_DELTA_COPIED => "Copied",
                else => "Modified",
            },
            .staged = staged,
            .binary = delta.flags & c.GIT_DIFF_FLAG_BINARY != 0,
        };
        // Bound individual previews; never render invalid source bytes as UTF-8.
        if (delta.old_file.size + delta.new_file.size <= 2 * 1024 * 1024) {
            var optional_patch: ?*c.git_patch = null;
            try check(c.git_patch_from_diff(&optional_patch, d, i));
            const patch = optional_patch orelse {
                item.binary = true;
                try files.append(a, item);
                continue;
            };
            item.binary = delta.flags & c.GIT_DIFF_FLAG_BINARY != 0;
            defer c.git_patch_free(patch);
            try check(c.git_patch_line_stats(null, &item.additions, &item.deletions, patch));
            var buf = std.mem.zeroes(c.git_buf);
            defer c.git_buf_dispose(&buf);
            try check(c.git_patch_to_buf(&buf, patch));
            item.patch = try a.dupe(u8, if (buf.ptr != null) buf.ptr[0..buf.size] else "");
            if (std.unicode.utf8ValidateSlice(item.patch)) item.lines = try diff_model.parse(a, item.patch) else item.binary = true;
        } else {
            item.patch = "Large file: preview is limited to 2 MiB. Open the file externally to review it.";
            item.stats_available = false;
        }
        try files.append(a, item);
    }
}
fn refs(a: std.mem.Allocator, repo: *c.git_repository, remotes: bool) ![][]const u8 {
    var array = std.mem.zeroes(c.git_strarray);
    defer c.git_strarray_dispose(&array);
    try check(if (remotes) c.git_remote_list(&array, repo) else c.git_reference_list(&array, repo));
    var values: std.ArrayList([]const u8) = .empty;
    for (strings(array)) |s| {
        const value = std.mem.span(s);
        if (remotes or std.mem.startsWith(u8, value, "refs/heads/")) try values.append(a, try a.dupe(u8, if (remotes) value else value[11..]));
    }
    return values.toOwnedSlice(a);
}
/// Commits on HEAD that no remote-tracking branch has, for a branch without an
/// upstream. Without a remote that is every commit, so local work stays visible.
fn unpublished(repo: *c.git_repository) !usize {
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push_head(walk));
    try check(c.git_revwalk_hide_glob(walk, "refs/remotes/*"));
    var count: usize = 0;
    var oid: c.git_oid = undefined;
    // Bounded like history: this runs on every refresh.
    while (count < 999 and c.git_revwalk_next(&oid, walk) == 0) count += 1;
    return count;
}
fn history(a: std.mem.Allocator, repo: *c.git_repository) ![]History {
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_TIME));
    if (c.git_revwalk_push_head(walk) < 0) return &.{};
    var items: std.ArrayList(History) = .empty;
    var oid: c.git_oid = undefined;
    while (items.items.len < 300 and c.git_revwalk_next(&oid, walk) == 0) {
        var commit: ?*c.git_commit = null;
        try check(c.git_commit_lookup(&commit, repo, &oid));
        defer c.git_commit_free(commit);
        const author: *const c.git_signature = c.git_commit_author(commit);
        const summary = c.git_commit_summary(commit);
        const hex = std.fmt.bytesToHex(oid.id, .lower);
        try items.append(a, .{ .oid = try a.dupe(u8, &hex), .summary = try diff_model.safeText(a, if (summary != null) std.mem.span(summary) else ""), .author = try diff_model.safeText(a, std.mem.span(author.name)), .time = author.when.time });
    }
    return items.toOwnedSlice(a);
}
pub fn commitFiles(a: std.mem.Allocator, path: []const u8, hex: []const u8) !Snapshot {
    var snap = Snapshot{ .arena = .init(a) };
    errdefer snap.deinit();
    const arena = snap.arena.allocator();
    const repo = try open(arena, path);
    defer c.git_repository_free(repo);
    var oid: c.git_oid = undefined;
    _ = try std.fmt.hexToBytes(&oid.id, hex);
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, &oid));
    defer c.git_commit_free(commit);
    var new_tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&new_tree, commit));
    defer c.git_tree_free(new_tree);
    var old_tree: ?*c.git_tree = null;
    if (c.git_commit_parentcount(commit) > 0) {
        var parent: ?*c.git_commit = null;
        try check(c.git_commit_parent(&parent, commit, 0));
        defer c.git_commit_free(parent);
        try check(c.git_commit_tree(&old_tree, parent));
    }
    defer c.git_tree_free(old_tree);
    var d: ?*c.git_diff = null;
    try check(c.git_diff_tree_to_tree(&d, repo, old_tree, new_tree, null));
    defer c.git_diff_free(d);
    try check(c.git_diff_find_similar(d, null));
    var files: std.ArrayList(File) = .empty;
    try appendDiff(arena, d.?, false, &files);
    snap.files = try files.toOwnedSlice(arena);
    return snap;
}
