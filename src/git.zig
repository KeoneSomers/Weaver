const std = @import("std");
const c = @import("libgit2.zig");
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
    return if (c.git_error_last()) |e| if (e.message) |m| std.mem.span(m) else "Git operation failed" else "Git operation failed";
}
pub fn open(a: std.mem.Allocator, path: []const u8) !*c.Repository {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var repo: *c.Repository = undefined;
    try check(c.git_repository_open(&repo, z));
    return repo;
}
pub const Discovery = struct { path: []const u8, remotes: [][]const u8 };
/// Prefer origin, then the first remote with a usable web destination.
pub fn repositoryWebUrl(a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const repo = try open(a, path);
    defer c.git_repository_free(repo);
    if (try remoteWebUrl(a, repo, "origin")) |url| return url;
    var names: c.Strarray = .{};
    try check(c.git_remote_list(&names, repo));
    defer c.git_strarray_dispose(&names);
    if (names.strings) |strings| for (strings[0..names.count]) |name| {
        if (std.mem.eql(u8, std.mem.span(name), "origin")) continue;
        if (try remoteWebUrl(a, repo, name)) |url| return url;
    };
    return null;
}
fn remoteWebUrl(a: std.mem.Allocator, repo: *c.Repository, name: [*:0]const u8) !?[]const u8 {
    var remote: *c.Remote = undefined;
    const status = c.git_remote_lookup(&remote, repo, name);
    if (status == -3) return null;
    try check(status);
    defer c.git_remote_free(remote);
    const url = c.git_remote_url(remote) orelse return null;
    return @import("repository_links.zig").webUrl(a, std.mem.span(url));
}
/// Lightweight discovery, including linked worktrees. The caller
/// owns the returned strings; use an arena for the discovery's lifetime.
pub fn discover(a: std.mem.Allocator, path: []const u8) !?Discovery {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    var repo: *c.Repository = undefined;
    // NO_SEARCH avoids adopting an enclosing repo when adding a new project folder.
    const status = c.git_repository_open_ext(&repo, z, 1, null);
    if (status == -3) return null; // GIT_ENOTFOUND: offer setup only for non-repositories.
    try check(status);
    defer c.git_repository_free(repo);
    const wd = c.git_repository_workdir(repo) orelse return error.BareRepository;
    return .{ .path = try a.dupe(u8, std.mem.span(wd)), .remotes = try refs(a, repo, true) };
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
    const wd = c.git_repository_workdir(repo) orelse return error.BareRepository;
    snap.path = try arena.dupe(u8, std.mem.span(wd));
    snap.state = switch (c.git_repository_state(repo)) {
        1 => .merging,
        2, 3 => .reverting,
        4, 5 => .cherry_picking,
        6 => .bisecting,
        7, 8, 9 => .rebasing,
        10, 11 => .applying,
        else => .normal,
    };
    var head: *c.Reference = undefined;
    var tree: ?*c.Tree = null;
    if (c.git_repository_head(&head, repo) == 0) {
        defer c.git_reference_free(head);
        snap.branch = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(head)));
        if (c.git_reference_target(head)) |oid| {
            var commit: *c.Commit = undefined;
            try check(c.git_commit_lookup(&commit, repo, oid));
            defer c.git_commit_free(commit);
            var t: *c.Tree = undefined;
            try check(c.git_commit_tree(&t, commit));
            tree = t;
            var upstream: *c.Reference = undefined;
            if (c.git_branch_upstream(&upstream, head) == 0) {
                defer c.git_reference_free(upstream);
                snap.upstream = try arena.dupe(u8, std.mem.span(c.git_reference_shorthand(upstream)));
                if (c.git_reference_target(upstream)) |upstream_oid| try check(c.git_graph_ahead_behind(&snap.ahead, &snap.behind, repo, oid, upstream_oid));
            } else snap.ahead = try unpublished(repo);
        }
    }
    defer if (tree) |t| c.git_tree_free(t);
    snap.history = try history(arena, repo);
    snap.branches = try refs(arena, repo, false);
    snap.remotes = try refs(arena, repo, true);
    if (!changes) return snap;
    var files: std.ArrayList(File) = .empty;
    var staged: *c.Diff = undefined;
    try check(c.git_diff_tree_to_index(&staged, repo, tree, null, null));
    defer c.git_diff_free(staged);
    try check(c.git_diff_find_similar(staged, null));
    try appendDiff(arena, staged, true, &files);
    var unstaged: *c.Diff = undefined;
    try check(c.git_diff_index_to_workdir(&unstaged, repo, null, null));
    defer c.git_diff_free(unstaged);
    try check(c.git_diff_find_similar(unstaged, null));
    try appendDiff(arena, unstaged, false, &files);
    var ctx = StatusContext{ .a = arena, .files = &files };
    try check(c.git_status_foreach_ext(repo, &.{}, statusCallback, &ctx));
    if (ctx.failed) return error.OutOfMemory;
    snap.files = try files.toOwnedSlice(arena);
    return snap;
}
const StatusContext = struct { a: std.mem.Allocator, files: *std.ArrayList(File), failed: bool = false };
fn statusCallback(path: [*:0]const u8, status: c_uint, payload: ?*anyopaque) callconv(.c) c_int {
    const ctx: *StatusContext = @ptrCast(@alignCast(payload.?));
    if (status & (128 | 32768) == 0) return 0;
    ctx.files.append(ctx.a, .{
        .path = ctx.a.dupe(u8, std.mem.span(path)) catch {
            ctx.failed = true;
            return -1;
        },
        .status = if (status & 32768 != 0) "Conflict" else "Untracked",
        .staged = false,
    }) catch {
        ctx.failed = true;
        return -1;
    };
    return 0;
}
pub fn appendDiff(a: std.mem.Allocator, d: *c.Diff, staged: bool, files: *std.ArrayList(File)) !void {
    for (0..c.git_diff_num_deltas(d)) |i| {
        const delta = c.git_diff_get_delta(d, i).?;
        if (delta.status == 0 or delta.status == 10) continue; // Conflicts come from the status callback, once per path.
        var item = File{
            .path = try a.dupe(u8, std.mem.span(delta.new_file.path orelse delta.old_file.path.?)),
            .old_path = if (delta.old_file.path) |p| try a.dupe(u8, std.mem.span(p)) else "",
            .status = switch (delta.status) {
                1 => "Added",
                2 => "Deleted",
                4 => "Renamed",
                5 => "Copied",
                10 => "Conflict",
                else => "Modified",
            },
            .staged = staged,
            .binary = delta.flags & 1 != 0,
        };
        // Bound individual previews; never render invalid source bytes as UTF-8.
        if (delta.old_file.size + delta.new_file.size <= 2 * 1024 * 1024) {
            var optional_patch: ?*c.Patch = null;
            try check(c.git_patch_from_diff(&optional_patch, d, i));
            const patch = optional_patch orelse {
                item.binary = true;
                try files.append(a, item);
                continue;
            };
            item.binary = delta.flags & 1 != 0;
            defer c.git_patch_free(patch);
            try check(c.git_patch_line_stats(null, &item.additions, &item.deletions, patch));
            var buf: c.Buffer = .{};
            defer c.git_buf_dispose(&buf);
            try check(c.git_patch_to_buf(&buf, patch));
            item.patch = try a.dupe(u8, if (buf.ptr) |p| p[0..buf.size] else "");
            if (std.unicode.utf8ValidateSlice(item.patch)) item.lines = try diff_model.parse(a, item.patch) else item.binary = true;
        } else {
            item.patch = "Large file: preview is limited to 2 MiB. Open the file externally to review it.";
            item.stats_available = false;
        }
        try files.append(a, item);
    }
}
fn refs(a: std.mem.Allocator, repo: *c.Repository, remotes: bool) ![][]const u8 {
    var array: c.Strarray = .{};
    defer c.git_strarray_dispose(&array);
    try check(if (remotes) c.git_remote_list(&array, repo) else c.git_reference_list(&array, repo));
    var values: std.ArrayList([]const u8) = .empty;
    if (array.strings) |strings| for (strings[0..array.count]) |s| {
        const value = std.mem.span(s);
        if (remotes or std.mem.startsWith(u8, value, "refs/heads/")) try values.append(a, try a.dupe(u8, if (remotes) value else value[11..]));
    };
    return values.toOwnedSlice(a);
}
/// Commits on HEAD that no remote-tracking branch has, for a branch without an
/// upstream. Without a remote that is every commit, so local work stays visible.
fn unpublished(repo: *c.Repository) !usize {
    var walk: *c.Revwalk = undefined;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push_head(walk));
    try check(c.git_revwalk_hide_glob(walk, "refs/remotes/*"));
    var count: usize = 0;
    var oid: c.Oid = undefined;
    // Bounded like history: this runs on every refresh.
    while (count < 999 and c.git_revwalk_next(&oid, walk) == 0) count += 1;
    return count;
}
fn history(a: std.mem.Allocator, repo: *c.Repository) ![]History {
    var walk: *c.Revwalk = undefined;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_sorting(walk, 1 | 2));
    if (c.git_revwalk_push_head(walk) < 0) return &.{};
    var items: std.ArrayList(History) = .empty;
    var oid: c.Oid = undefined;
    while (items.items.len < 300 and c.git_revwalk_next(&oid, walk) == 0) {
        var commit: *c.Commit = undefined;
        try check(c.git_commit_lookup(&commit, repo, &oid));
        defer c.git_commit_free(commit);
        const author = c.git_commit_author(commit);
        const hex = std.fmt.bytesToHex(oid.id, .lower);
        try items.append(a, .{ .oid = try a.dupe(u8, &hex), .summary = try diff_model.safeText(a, if (c.git_commit_summary(commit)) |s| std.mem.span(s) else ""), .author = try diff_model.safeText(a, std.mem.span(author.name)), .time = author.when.time });
    }
    return items.toOwnedSlice(a);
}
pub fn commitFiles(a: std.mem.Allocator, path: []const u8, hex: []const u8) !Snapshot {
    var snap = Snapshot{ .arena = .init(a) };
    errdefer snap.deinit();
    const arena = snap.arena.allocator();
    const repo = try open(arena, path);
    defer c.git_repository_free(repo);
    var oid: c.Oid = undefined;
    _ = try std.fmt.hexToBytes(&oid.id, hex);
    var commit: *c.Commit = undefined;
    try check(c.git_commit_lookup(&commit, repo, &oid));
    defer c.git_commit_free(commit);
    var new_tree: *c.Tree = undefined;
    try check(c.git_commit_tree(&new_tree, commit));
    defer c.git_tree_free(new_tree);
    var old_tree: ?*c.Tree = null;
    if (c.git_commit_parentcount(commit) > 0) {
        var parent: *c.Commit = undefined;
        try check(c.git_commit_parent(&parent, commit, 0));
        defer c.git_commit_free(parent);
        var t: *c.Tree = undefined;
        try check(c.git_commit_tree(&t, parent));
        old_tree = t;
    }
    defer if (old_tree) |t| c.git_tree_free(t);
    var d: *c.Diff = undefined;
    try check(c.git_diff_tree_to_tree(&d, repo, old_tree, new_tree, null));
    defer c.git_diff_free(d);
    try check(c.git_diff_find_similar(d, null));
    var files: std.ArrayList(File) = .empty;
    try appendDiff(arena, d, false, &files);
    snap.files = try files.toOwnedSlice(arena);
    return snap;
}
