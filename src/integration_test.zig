const std = @import("std");
const git = @import("git.zig");
const provider = @import("provider.zig").git;
const process = @import("process.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const diff = @import("diff.zig");
test "local folder discovery detects repositories and preserves existing remotes" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    // The fixture is inside Weaver's repo: a plain folder must not inherit it.
    try std.testing.expectEqual(@as(?git.Discovery, null), try git.discover(alloc, root));
    const missing = try std.fs.path.join(alloc, &.{ root, "missing" });
    try std.testing.expectEqual(@as(?git.Discovery, null), try git.discover(alloc, missing));
    try command(root, &.{ "init", "--initial-branch=main" });
    const local = (try git.discover(alloc, root)).?;
    try std.testing.expect(@import("config.zig").equalPath(local.path, root));
    try std.testing.expectEqual(@as(usize, 0), local.remotes.len);
    try temp.dir.createDirPath(io, "new-project");
    const nested = try std.fs.path.join(alloc, &.{ root, "new-project" });
    try std.testing.expectEqual(@as(?git.Discovery, null), try git.discover(alloc, nested));
    try command(root, &.{ "remote", "add", "upstream", "https://example.invalid/upstream.git" });
    try command(root, &.{ "remote", "add", "origin", "git@example.invalid:owner/project.git" });
    const before = try temp.dir.readFileAlloc(io, ".git/config", alloc, .limited(65536));
    const detected = (try git.discover(alloc, root)).?;
    try std.testing.expectEqual(@as(usize, 2), detected.remotes.len);
    try std.testing.expectEqualStrings("origin", detected.remotes[0]);
    try std.testing.expectEqualStrings("upstream", detected.remotes[1]);
    try std.testing.expectEqualStrings("https://example.invalid/owner/project", (try git.repositoryWebUrl(alloc, root)).?);
    var snapshot = try provider.scan(io, a, detected.path);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.remotes.len);
    const after = try temp.dir.readFileAlloc(io, ".git/config", alloc, .limited(65536));
    try std.testing.expectEqualStrings(before, after);
    // A local origin must not hide an upstream that can be opened in a browser.
    try command(root, &.{ "remote", "set-url", "origin", root });
    try std.testing.expectEqualStrings("https://example.invalid/upstream", (try git.repositoryWebUrl(alloc, root)).?);
    try command(root, &.{ "remote", "set-url", "origin", "git@example.invalid:owner/project.git" });
    // A .git file, rather than a .git directory, must still open automatically.
    const worktree = try std.fs.path.join(alloc, &.{ root, "café worktree" });
    try command(root, &.{ "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=.git/hooks", "commit", "--allow-empty", "-m", "Worktree fixture" });
    try command(root, &.{ "worktree", "add", "-b", "linked", worktree });
    const linked = (try git.discover(alloc, worktree)).?;
    try std.testing.expect(@import("config.zig").equalPath(linked.path, worktree));
    try std.testing.expectEqual(@as(usize, 2), linked.remotes.len);
    const bare = try std.fs.path.join(alloc, &.{ root, "bare.git" });
    try command(root, &.{ "init", "--bare", bare });
    try std.testing.expectError(error.BareRepository, git.discover(alloc, bare));
}

test "progressive reads list changes without patches then load counts and only the selected preview" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    try temp.dir.writeFile(io, .{ .sub_path = "café file.txt", .data = "old\n" });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "Progressive fixture" });
    try temp.dir.writeFile(io, .{ .sub_path = "café file.txt", .data = "staged\n" });
    try command(path, &.{ "add", "--all" });
    try temp.dir.writeFile(io, .{ .sub_path = "café file.txt", .data = "working\nextra\n" });
    try temp.dir.createDirPath(io, "nested");
    // Many new files must not cause status to retain their content or parsed diffs.
    for (0..256) |i| {
        const name = try std.fmt.allocPrint(a, "nested/new-{d}.txt", .{i});
        defer a.free(name);
        try temp.dir.writeFile(io, .{ .sub_path = name, .data = "new\nmissing newline" });
    }
    try temp.dir.writeFile(io, .{ .sub_path = "binary.dat", .data = "a\x00b" });
    var scan = try provider.scan(io, a, path);
    defer scan.deinit();
    try std.testing.expectEqual(@as(usize, 259), scan.files.len);
    for (scan.files) |file| {
        try std.testing.expectEqual(@as(usize, 0), file.patch.len);
        try std.testing.expectEqual(@as(usize, 0), file.lines.len);
        try std.testing.expect(!file.stats_available);
    }
    var counts = try provider.counts(io, a, path, scan.files);
    defer counts.deinit();
    for (counts.files) |file| {
        try std.testing.expect(file.stats_available);
        try std.testing.expectEqual(@as(usize, 0), file.patch.len);
        if (std.mem.eql(u8, file.path, "café file.txt")) {
            try std.testing.expectEqual(@as(usize, if (file.staged) 1 else 2), file.additions);
            try std.testing.expectEqual(@as(usize, 1), file.deletions);
            var selected = try provider.preview(io, a, path, file);
            defer selected.deinit();
            try std.testing.expectEqual(@as(usize, 1), selected.files.len);
            try std.testing.expect(std.mem.indexOf(u8, selected.files[0].patch, if (file.staged) "+staged" else "+working") != null);
        } else if (std.mem.eql(u8, file.path, "binary.dat")) {
            try std.testing.expect(file.binary);
        } else try std.testing.expectEqual(@as(usize, 2), file.additions);
    }
}
fn command(path: []const u8, args: []const []const u8) !void {
    const result = try process.git(io, a, path, args);
    defer result.deinit(a);
    if (!result.ok) {
        std.debug.print("Git failed: {s}\n", .{result.stderr});
        return error.GitCommandFailed;
    }
}

test "background fetch updates ahead and behind without touching working files" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const remote = try std.fs.path.join(alloc, &.{ root, "remote.git" });
    const local = try std.fs.path.join(alloc, &.{ root, "local" });
    const publisher = try std.fs.path.join(alloc, &.{ root, "publisher" });
    try command(root, &.{ "init", "--bare", "--initial-branch=main", remote });
    try command(root, &.{ "clone", "--", remote, publisher });
    try command(publisher, &.{ "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=.git/hooks", "commit", "--allow-empty", "-m", "Base" });
    try command(publisher, &.{ "push", "--set-upstream", "origin", "main" });
    try command(root, &.{ "clone", "--", remote, local });
    try command(local, &.{ "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=.git/hooks", "commit", "--allow-empty", "-m", "Outgoing" });
    try command(publisher, &.{ "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=.git/hooks", "commit", "--allow-empty", "-m", "Incoming" });
    try command(publisher, &.{"push"});
    try temp.dir.writeFile(io, .{ .sub_path = "local/notes.txt", .data = "Keep this uncommitted file.\n" });
    var before = try provider.scan(io, a, local);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.ahead);
    try std.testing.expectEqual(@as(usize, 0), before.behind);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    // PATH lookup still uses the parent's PATH when the override has no PATH.
    const result = try provider.background_fetch.?(io, a, local, &environment);
    defer result.deinit(a);
    try std.testing.expect(result.ok);
    var after = try provider.scan(io, a, local);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.ahead);
    try std.testing.expectEqual(@as(usize, 1), after.behind);
    try std.testing.expectEqualStrings(before.history[0].oid, after.history[0].oid);
    const notes = try temp.dir.readFileAlloc(io, "local/notes.txt", alloc, .limited(1024));
    try std.testing.expectEqualStrings("Keep this uncommitted file.\n", notes);
    try command(local, &.{ "remote", "set-url", "origin", try std.fs.path.join(alloc, &.{ root, "missing.git" }) });
    const failed = try provider.background_fetch.?(io, a, local, &environment);
    defer failed.deinit(a);
    try std.testing.expect(!failed.ok);
}

fn awaitWatch(watcher: *@import("repository_watch.zig").Watcher) !void {
    for (0..100) |_| {
        if (try watcher.poll()) return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.MissingRepositoryNotification;
}

test "native watch detects nested edits, same-status content, deletion and external worktree refs" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(root, &.{ "init", "--initial-branch=main" });
    var watcher: @import("repository_watch.zig").Watcher = .{};
    defer watcher.deinit(a);
    try watcher.reset(a, root);
    try std.testing.expect(watcher.native);
    try std.testing.expect(!try watcher.poll());
    const epoch: std.atomic.Value(u64) = .init(0);
    var wait = try io.concurrent(@import("repository_watch.zig").Watcher.wait, .{ &watcher, io, &epoch, @as(u64, 0) });
    defer _ = wait.cancel(io);
    try temp.dir.createDirPath(io, "nested/café");
    try temp.dir.writeFile(io, .{ .sub_path = "nested/café/file.txt", .data = "before\n" });
    try std.testing.expectEqual(@import("repository_watch.zig").Signal.changed, wait.await(io));
    // Drain the rest of the burst, then prove Git's read does not feed the watch.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    _ = try watcher.poll();
    var before = try provider.scan(io, a, root);
    defer before.deinit();
    var old_preview = try provider.preview(io, a, root, before.files[0]);
    defer old_preview.deinit();
    try std.testing.expect(!try watcher.poll());
    try temp.dir.writeFile(io, .{ .sub_path = "nested/café/file.txt", .data = "after\n" });
    try awaitWatch(&watcher);
    var after = try provider.scan(io, a, root);
    defer after.deinit();
    var new_preview = try provider.preview(io, a, root, after.files[0]);
    defer new_preview.deinit();
    try std.testing.expect(@import("refresh.zig").sameList(before.files, after.files));
    try std.testing.expect(!@import("refresh.zig").samePreview(old_preview.files[0], new_preview.files[0]));
    try temp.dir.rename("nested/café/file.txt", temp.dir, "nested/café/renamed.txt", io);
    try awaitWatch(&watcher);
    try temp.dir.deleteFile(io, "nested/café/renamed.txt");
    try awaitWatch(&watcher);
    try command(root, &.{ "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=.git/hooks", "commit", "--allow-empty", "-m", "Watch fixture" });
    const linked = try std.fs.path.join(a, &.{ root, "linked" });
    defer a.free(linked);
    try command(root, &.{ "worktree", "add", "-b", "linked", linked });
    try watcher.reset(a, linked);
    try std.testing.expect(watcher.native);
    try std.testing.expect(!try watcher.poll());
    // Nothing in the linked working directory changes when the common refs do.
    try command(root, &.{ "branch", "external-branch" });
    try awaitWatch(&watcher);
    // Index updates live in the per-worktree Git directory, outside its root.
    const file = try std.fs.path.join(a, &.{ linked, "new.txt" });
    defer a.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "new\n" });
    try awaitWatch(&watcher);
    try command(linked, &.{ "add", "new.txt" });
    try awaitWatch(&watcher);
    var cancelled = try io.concurrent(@import("repository_watch.zig").Watcher.wait, .{ &watcher, io, &epoch, @as(u64, 0) });
    try std.testing.expectEqual(@import("repository_watch.zig").Signal.cancelled, cancelled.cancel(io));
}

test "selected preview bounds metadata for files with many tiny lines" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    const bytes = try a.alloc(u8, 54002);
    defer a.free(bytes);
    for (0..27001) |i| @memcpy(bytes[i * 2 ..][0..2], "x\n");
    try temp.dir.writeFile(io, .{ .sub_path = "tiny-lines.txt", .data = bytes });
    var selected = try provider.preview(io, a, path, .{ .path = "tiny-lines.txt", .status = "Untracked", .staged = false });
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 0), selected.files[0].lines.len);
    try std.testing.expect(!selected.files[0].stats_available);
    try std.testing.expect(std.mem.indexOf(u8, selected.files[0].patch, "25,000 lines") != null);
}

test "large tracked files retain accurate statistics when text previews are bounded" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    const bytes = try a.alloc(u8, 2 * 1024 * 1024 + 16);
    defer a.free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[0..4], "old\n");
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = bytes });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "Large fixture" });
    @memcpy(bytes[0..4], "new\n");
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = bytes });
    var snapshot = try provider.load(io, a, path);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.files.len);
    const file = snapshot.files[0];
    try std.testing.expect(file.stats_available);
    try std.testing.expectEqual(@as(usize, 1), file.additions);
    try std.testing.expectEqual(@as(usize, 1), file.deletions);
    try std.testing.expectEqual(@as(usize, 0), file.lines.len);
    var fast = try provider.scan(io, a, path);
    defer fast.deinit();
    var counts = try provider.counts(io, a, path, fast.files);
    defer counts.deinit();
    try std.testing.expectEqual(@as(usize, 1), counts.files[0].additions);
    try std.testing.expectEqual(@as(usize, 1), counts.files[0].deletions);
}

test "new-file patches preserve Unicode paths, spaces and missing final newlines" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    const name = "new café file.txt";
    const source = "first line\nno final newline";
    try temp.dir.writeFile(io, .{ .sub_path = name, .data = source });
    const patch = try diff.newFilePatch(a, name, source);
    defer a.free(patch);
    const stage = try provider.execute(io, a, path, .{ .operation = .stage_hunk, .value = patch });
    defer stage.deinit(a);
    if (!stage.ok) std.debug.print("Patch failed: {s}\n", .{stage.stderr});
    try std.testing.expect(stage.ok);
    const index_path = try std.fmt.allocPrint(a, ":{s}", .{name});
    defer a.free(index_path);
    const content = try process.git(io, a, path, &.{ "show", index_path });
    defer content.deinit(a);
    try std.testing.expectEqualStrings(source, content.stdout);
}

test "rename detection and unstaging preserve both old and new path identities" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    try temp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "Original content\n" });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "Rename fixture" });
    try temp.dir.rename("old.txt", temp.dir, "new.txt", io);
    try command(path, &.{ "add", "--all" });
    var renamed = try provider.load(io, a, path);
    defer renamed.deinit();
    try std.testing.expectEqual(@as(usize, 1), renamed.files.len);
    const file = renamed.files[0];
    try std.testing.expectEqualStrings("Renamed", file.status);
    try std.testing.expectEqualStrings("old.txt", file.old_path);
    try std.testing.expectEqualStrings("new.txt", file.path);
    var fast = try provider.scan(io, a, path);
    defer fast.deinit();
    try std.testing.expectEqual(@as(usize, 1), fast.files.len);
    try std.testing.expectEqualStrings("old.txt", fast.files[0].old_path);
    var selected = try provider.preview(io, a, path, fast.files[0]);
    defer selected.deinit();
    try std.testing.expect(std.mem.indexOf(u8, selected.files[0].patch, "rename from old.txt") != null);
    var stats = try provider.counts(io, a, path, fast.files);
    defer stats.deinit();
    try std.testing.expectEqual(@as(usize, 0), stats.files[0].additions);
    try std.testing.expectEqual(@as(usize, 0), stats.files[0].deletions);
    const unstage = try provider.execute(io, a, path, .{ .operation = .unstage, .value = file.path, .second = file.old_path });
    defer unstage.deinit(a);
    try std.testing.expect(unstage.ok);
    var after = try provider.load(io, a, path);
    defer after.deinit();
    for (after.files) |changed| try std.testing.expect(!changed.staged);
}

test "partial staging and reverse staging preserve other hunks and working files" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    const initial = "old first\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nold last\n";
    const changed = "new first\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nnew last\n";
    try temp.dir.writeFile(io, .{ .sub_path = "hunks.txt", .data = initial });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "Hunk fixture" });
    try temp.dir.writeFile(io, .{ .sub_path = "hunks.txt", .data = changed });
    var before = try provider.load(io, a, path);
    defer before.deinit();
    const selected = try diff.hunk(a, before.files[0].patch, 0);
    defer a.free(selected);
    const stage = try provider.execute(io, a, path, .{ .operation = .stage_hunk, .value = selected });
    defer stage.deinit(a);
    try std.testing.expect(stage.ok);
    const index = try process.git(io, a, path, &.{ "show", ":hunks.txt" });
    defer index.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, index.stdout, "new first"));
    try std.testing.expect(std.mem.endsWith(u8, index.stdout, "old last\n"));
    const unstage = try provider.execute(io, a, path, .{ .operation = .unstage_hunk, .value = selected });
    defer unstage.deinit(a);
    try std.testing.expect(unstage.ok);
    const restored = try process.git(io, a, path, &.{ "show", ":hunks.txt" });
    defer restored.deinit(a);
    try std.testing.expectEqualStrings(initial, restored.stdout);
    const disk = try temp.dir.readFileAlloc(io, "hunks.txt", a, .limited(4096));
    defer a.free(disk);
    try std.testing.expectEqualStrings(changed, disk);
}

test "branches are created from a start point, renamed, and deleted only by force when unmerged" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    try temp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "Base" });
    try command(path, &.{ "switch", "-c", "feature" });
    try temp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "feature\n" });
    try command(path, &.{ "commit", "-am", "Feature" });
    try command(path, &.{ "switch", "main" });
    const requests = [_]struct { @import("model.zig").Request, bool }{
        // Starts at feature rather than at the checked-out main.
        .{ .{ .operation = .create_branch, .value = "from-feature", .second = "feature" }, true },
        .{ .{ .operation = .rename_branch, .value = "feature", .second = "renamed" }, true },
        .{ .{ .operation = .rename_branch, .value = "renamed", .second = "main" }, false },
        .{ .{ .operation = .rename_branch, .value = "renamed", .second = "--force" }, false },
        .{ .{ .operation = .switch_branch, .value = "main" }, true },
        .{ .{ .operation = .delete_branch, .value = "from-feature" }, false },
        .{ .{ .operation = .force_delete_branch, .value = "from-feature" }, true },
    };
    for (requests) |entry| {
        const result = provider.execute(io, a, path, entry[0]) catch |err| {
            try std.testing.expect(!entry[1] and err == error.InvalidArgument);
            continue;
        };
        defer result.deinit(a);
        try std.testing.expectEqual(entry[1], result.ok);
        if (entry[0].operation == .create_branch) {
            const disk = try temp.dir.readFileAlloc(io, "file.txt", a, .limited(4096));
            defer a.free(disk);
            try std.testing.expectEqualStrings("feature\n", disk);
        }
    }
    var snapshot = try provider.load(io, a, path);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("main", snapshot.branch);
    try std.testing.expectEqual(@as(usize, 2), snapshot.branches.len);
    for (snapshot.branches) |branch| try std.testing.expect(std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "renamed"));
}

test "merge conflicts remain visible and choosing a side stages only the resolved file" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try temp.dir.realPath(io, &buffer)];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    try temp.dir.writeFile(io, .{ .sub_path = "conflict.txt", .data = "base\n" });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "Base" });
    try command(path, &.{ "switch", "-c", "feature" });
    try temp.dir.writeFile(io, .{ .sub_path = "conflict.txt", .data = "feature\n" });
    try command(path, &.{ "commit", "-am", "Feature" });
    try command(path, &.{ "switch", "main" });
    try temp.dir.writeFile(io, .{ .sub_path = "conflict.txt", .data = "main\n" });
    try command(path, &.{ "commit", "-am", "Main" });
    const merge = try provider.execute(io, a, path, .{ .operation = .merge, .value = "feature" });
    defer merge.deinit(a);
    try std.testing.expect(!merge.ok);
    {
        var conflicted = try provider.load(io, a, path);
        defer conflicted.deinit();
        try std.testing.expectEqual(@import("model.zig").RepositoryState.merging, conflicted.state);
        try std.testing.expectEqual(@as(usize, 1), conflicted.files.len);
        try std.testing.expectEqualStrings("Conflict", conflicted.files[0].status);
        var fast = try provider.scan(io, a, path);
        defer fast.deinit();
        try std.testing.expectEqual(@as(usize, 1), fast.files.len);
        try std.testing.expectEqualStrings("Conflict", fast.files[0].status);
        var selected = try provider.preview(io, a, path, fast.files[0]);
        defer selected.deinit();
        try std.testing.expect(std.mem.indexOf(u8, selected.files[0].patch, "<<<<<<<") != null);
    }
    const resolved = try provider.execute(io, a, path, .{ .operation = .resolve_theirs, .value = "conflict.txt" });
    defer resolved.deinit(a);
    try std.testing.expect(resolved.ok);
    const disk = try temp.dir.readFileAlloc(io, "conflict.txt", a, .limited(4096));
    defer a.free(disk);
    try std.testing.expectEqualStrings("feature\n", disk);
    const finish = try provider.execute(io, a, path, .{ .operation = .merge_continue });
    defer finish.deinit(a);
    try std.testing.expect(finish.ok);
    var clean = try provider.load(io, a, path);
    defer clean.deinit();
    try std.testing.expectEqual(@import("model.zig").RepositoryState.normal, clean.state);
    try std.testing.expectEqual(@as(usize, 0), clean.files.len);
}
test "native snapshots distinguish staged and unstaged content, nested untracked files, history and unborn unstage" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = try temp.dir.realPath(io, &buffer);
    const path = buffer[0..size];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    try temp.dir.writeFile(io, .{ .sub_path = "example.zig", .data = "const a = 1;\n" });
    {
        const r = try provider.execute(io, a, path, .{ .operation = .stage, .value = "example.zig" });
        defer r.deinit(a);
        try std.testing.expect(r.ok);
    }
    {
        const r = try provider.execute(io, a, path, .{ .operation = .unstage, .value = "example.zig" });
        defer r.deinit(a);
        try std.testing.expect(r.ok);
    }
    try command(path, &.{ "add", "--", "example.zig" });
    try command(path, &.{ "commit", "-m", "Initial" });
    try temp.dir.writeFile(io, .{ .sub_path = "example.zig", .data = "const a = 2;\n" });
    try command(path, &.{ "add", "--", "example.zig" });
    try temp.dir.writeFile(io, .{ .sub_path = "example.zig", .data = "const a = 3;\n" });
    try temp.dir.createDirPath(io, "nested");
    try temp.dir.writeFile(io, .{ .sub_path = "nested/new.txt", .data = "New\n" });
    var snapshot = try git.load(a, path);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("main", snapshot.branch);
    try std.testing.expectEqual(@as(usize, 1), snapshot.history.len);
    try std.testing.expectEqual(@as(usize, 3), snapshot.files.len);
    var staged = false;
    var unstaged = false;
    var untracked = false;
    for (snapshot.files) |f| {
        if (std.mem.eql(u8, f.path, "example.zig")) {
            if (f.staged) {
                staged = true;
                try std.testing.expect(std.mem.indexOf(u8, f.patch, "const a = 2;") != null);
            } else {
                unstaged = true;
                try std.testing.expect(std.mem.indexOf(u8, f.patch, "const a = 3;") != null);
            }
            try std.testing.expectEqual(@as(usize, 1), f.additions);
            try std.testing.expectEqual(@as(usize, 1), f.deletions);
        }
        if (std.mem.eql(u8, f.path, "nested/new.txt")) untracked = true;
    }
    try std.testing.expect(staged and unstaged and untracked);
    var revision = try git.commitFiles(a, path, snapshot.history[0].oid);
    defer revision.deinit();
    try std.testing.expectEqual(@as(usize, 1), revision.files.len);
    try std.testing.expectEqual(@as(usize, 1), revision.files[0].additions);
}
test "hydrated LFS objects stay clean and staging produces pointers" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = try temp.dir.realPath(io, &buffer);
    const path = buffer[0..size];
    try command(path, &.{ "init", "--initial-branch=main" });
    try command(path, &.{ "config", "user.name", "Weaver Test" });
    try command(path, &.{ "config", "user.email", "test@example.invalid" });
    try command(path, &.{ "config", "commit.gpgsign", "false" });
    try command(path, &.{ "config", "core.autocrlf", "false" });
    try command(path, &.{ "config", "core.hooksPath", ".git/hooks" });
    try command(path, &.{ "lfs", "install", "--local" });
    try command(path, &.{ "lfs", "track", "*.dat" });
    try temp.dir.writeFile(io, .{ .sub_path = "asset.dat", .data = "first LFS content\n" });
    try command(path, &.{ "add", "--all" });
    try command(path, &.{ "commit", "-m", "LFS fixture" });
    const pointer = try process.git(io, a, path, &.{ "show", ":asset.dat" });
    defer pointer.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, pointer.stdout, "version https://git-lfs.github.com/spec/v1"));
    {
        var clean = try provider.load(io, a, path);
        defer clean.deinit();
        try std.testing.expectEqual(@as(usize, 0), clean.files.len);
        var fast = try provider.scan(io, a, path);
        defer fast.deinit();
        try std.testing.expectEqual(@as(usize, 0), fast.files.len);
    }
    try temp.dir.writeFile(io, .{ .sub_path = "asset.dat", .data = "changed LFS content\n" });
    {
        var changed = try provider.load(io, a, path);
        defer changed.deinit();
        try std.testing.expectEqual(@as(usize, 1), changed.files.len);
        try std.testing.expect(std.mem.indexOf(u8, changed.files[0].patch, "oid sha256:") != null);
        var fast = try provider.scan(io, a, path);
        defer fast.deinit();
        var selected = try provider.preview(io, a, path, fast.files[0]);
        defer selected.deinit();
        try std.testing.expect(std.mem.indexOf(u8, selected.files[0].patch, "oid sha256:") != null);
        var stats = try provider.counts(io, a, path, fast.files);
        defer stats.deinit();
        try std.testing.expectEqual(changed.files[0].additions, stats.files[0].additions);
        try std.testing.expectEqual(changed.files[0].deletions, stats.files[0].deletions);
    }
    {
        const r = try provider.execute(io, a, path, .{ .operation = .stage, .value = "asset.dat" });
        defer r.deinit(a);
        try std.testing.expect(r.ok);
    }
    {
        var staged = try provider.load(io, a, path);
        defer staged.deinit();
        try std.testing.expectEqual(@as(usize, 1), staged.files.len);
        try std.testing.expect(staged.files[0].staged);
    }
}

test "commits without an upstream count as unpushed until a remote branch has them" {
    try git.init();
    defer git.shutdown();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try temp.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const remote = try std.fs.path.join(alloc, &.{ root, "remote.git" });
    const local = try std.fs.path.join(alloc, &.{ root, "local" });
    const identity = [_][]const u8{ "-c", "user.name=Weaver Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=.git/hooks", "commit", "--allow-empty", "-m" };
    try command(root, &.{ "init", "--initial-branch=main", local });
    {
        var unborn = try provider.scan(io, a, local);
        defer unborn.deinit();
        try std.testing.expectEqual(@as(usize, 0), unborn.ahead);
    }
    try command(local, &(identity ++ .{"First"}));
    try command(local, &(identity ++ .{"Second"}));
    {
        var offline = try provider.scan(io, a, local);
        defer offline.deinit();
        try std.testing.expectEqual(@as(usize, 0), offline.remotes.len);
        try std.testing.expectEqualStrings("", offline.upstream);
        try std.testing.expectEqual(@as(usize, 2), offline.ahead);
    }
    // Plain push without a destination is what the toolbar used to run.
    {
        const r = try provider.execute(io, a, local, .{ .operation = .push });
        defer r.deinit(a);
        try std.testing.expect(!r.ok);
        try std.testing.expectEqual(@import("guidance.zig").Advice.connect_remote, @import("guidance.zig").advise(r.stderr, false));
    }
    try command(root, &.{ "init", "--bare", "--initial-branch=main", remote });
    {
        const r = try provider.execute(io, a, local, .{ .operation = .add_remote, .value = "origin", .second = remote });
        defer r.deinit(a);
        try std.testing.expect(r.ok);
    }
    {
        const r = try provider.execute(io, a, local, .{ .operation = .publish, .value = "main", .second = "origin" });
        defer r.deinit(a);
        try std.testing.expect(r.ok);
    }
    try command(local, &.{ "switch", "-c", "feature" });
    try command(local, &(identity ++ .{"Third"}));
    var published = try provider.scan(io, a, local);
    defer published.deinit();
    try std.testing.expectEqualStrings("", published.upstream);
    try std.testing.expectEqual(@as(usize, 1), published.ahead);
}
