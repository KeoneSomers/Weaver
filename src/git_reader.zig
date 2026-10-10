//! Progressive Git reads: status first, batched statistics, one selected preview.
//! Git performs clean/LFS filters; libgit2 supplies repository metadata/history.
const std = @import("std");
const model = @import("model.zig");
const backend = @import("git.zig");
const process = @import("process.zig");
const diff = @import("diff.zig");
const limit = 2 * 1024 * 1024;

pub fn scan(io: std.Io, a: std.mem.Allocator, path: []const u8) !model.Snapshot {
    var result = try backend.metadata(a, path);
    errdefer result.deinit();
    const status = try process.git(io, a, result.path, &.{ "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--renames" });
    defer status.deinit(a);
    if (!status.ok) return error.GitStatusFailed;
    result.files = try parseStatus(result.arena.allocator(), status.stdout);
    return result;
}
fn statusName(code: u8) []const u8 {
    return switch (code) {
        'A' => "Added",
        'D' => "Deleted",
        'R' => "Renamed",
        'C' => "Copied",
        'T' => "Type changed",
        else => "Modified",
    };
}
pub fn parseStatus(a: std.mem.Allocator, bytes: []const u8) ![]model.File {
    var files: std.ArrayList(model.File) = .empty;
    var fields = std.mem.splitScalar(u8, bytes, 0);
    while (fields.next()) |record| {
        if (record.len == 0) continue;
        if (record.len < 4 or record[2] != ' ') return error.InvalidGitStatus;
        const x = record[0];
        const y = record[1];
        const path = try a.dupe(u8, record[3..]);
        const old = if (x == 'R' or x == 'C' or y == 'R' or y == 'C') try a.dupe(u8, fields.next() orelse return error.InvalidGitStatus) else "";
        const conflict = x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D');
        if (conflict or x == '?') {
            try files.append(a, .{ .path = path, .status = if (conflict) "Conflict" else "Untracked", .staged = false, .stats_available = false });
        } else {
            if (x != ' ' and x != '!') try files.append(a, .{ .path = path, .old_path = if (x == 'R' or x == 'C') old else "", .status = statusName(x), .staged = true, .stats_available = false });
            if (y != ' ' and y != '!') try files.append(a, .{ .path = path, .old_path = if (y == 'R' or y == 'C') old else "", .status = statusName(y), .staged = false, .stats_available = false });
        }
    }
    return files.toOwnedSlice(a);
}
fn copyFiles(a: std.mem.Allocator, path: []const u8, files: []const model.File) !model.Snapshot {
    var result = model.Snapshot{ .arena = .init(a) };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    result.path = try arena.dupe(u8, path);
    result.files = try arena.alloc(model.File, files.len);
    for (files, result.files) |file, *copy| copy.* = .{ .path = try arena.dupe(u8, file.path), .old_path = try arena.dupe(u8, file.old_path), .status = try arena.dupe(u8, file.status), .staged = file.staged, .stats_available = false };
    return result;
}
pub fn counts(io: std.Io, a: std.mem.Allocator, path: []const u8, files: []const model.File) !model.Snapshot {
    var result = try copyFiles(a, path, files);
    errdefer result.deinit();
    const arena = result.arena.allocator();
    // Constant process count, including repositories with thousands of LFS paths.
    for ([_]bool{ true, false }) |staged| {
        const stats = try process.git(io, a, path, if (staged)
            &.{ "diff", "--cached", "--numstat", "-z", "--no-ext-diff", "--no-textconv" }
        else
            &.{ "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv" });
        defer stats.deinit(a);
        if (!stats.ok) return error.GitStatisticsFailed;
        try applyNumstat(arena, result.files, stats.stdout, staged);
    }
    for (result.files) |*file| {
        if (std.mem.eql(u8, file.status, "Untracked")) {
            const full = try std.fs.path.join(a, &.{ path, file.path });
            defer a.free(full);
            // Reuse/free each buffer; no full patches or parsed lines are retained.
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(limit)) catch continue;
            defer a.free(bytes);
            file.binary = std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes);
            if (!file.binary) file.additions = std.mem.count(u8, bytes, "\n") + @as(usize, @intFromBool(bytes.len > 0 and bytes[bytes.len - 1] != '\n'));
            file.stats_available = true;
        }
    }
    return result;
}
pub fn applyNumstat(a: std.mem.Allocator, files: []model.File, bytes: []const u8, staged: bool) !void {
    var index: std.StringHashMap(usize) = .init(a);
    defer index.deinit();
    for (files, 0..) |file, i| if (file.staged == staged) try index.put(file.path, i);
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        const first = std.mem.indexOfScalar(u8, record, '\t') orelse return error.InvalidGitStatistics;
        const second = std.mem.indexOfScalarPos(u8, record, first + 1, '\t') orelse return error.InvalidGitStatistics;
        var name = record[second + 1 ..];
        if (name.len == 0) {
            _ = records.next() orelse return error.InvalidGitStatistics; // rename source
            name = records.next() orelse return error.InvalidGitStatistics;
        }
        if (index.get(name)) |i| {
            const file = &files[i];
            file.binary = std.mem.eql(u8, record[0..first], "-");
            if (!file.binary) {
                file.additions = try std.fmt.parseInt(usize, record[0..first], 10);
                file.deletions = try std.fmt.parseInt(usize, record[first + 1 .. second], 10);
            }
            file.stats_available = true;
        }
    }
    // Empty rename/mode changes may be omitted by Git; conflicts stay unknown.
    for (files) |*file| if (file.staged == staged and !std.mem.eql(u8, file.status, "Untracked") and !std.mem.eql(u8, file.status, "Conflict")) {
        file.stats_available = true;
    };
}
pub fn preview(io: std.Io, a: std.mem.Allocator, path: []const u8, file: model.File) !model.Snapshot {
    var result = try copyFiles(a, path, &.{file});
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const output = &result.files[0];
    const untracked = std.mem.eql(u8, file.status, "Untracked");
    const conflict = std.mem.eql(u8, file.status, "Conflict");
    if (untracked or conflict) {
        const full = try std.fs.path.join(arena, &.{ path, file.path });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, arena, .limited(limit)) catch {
            output.patch = "Preview unavailable or larger than 2 MiB.";
            return result;
        };
        output.binary = std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes);
        if (output.binary) return result;
        output.patch = try diff.newFilePatch(arena, file.path, bytes);
        if (conflict) {
            // Show the actual conflict markers; never offer partial staging here.
            output.patch = try std.fmt.allocPrint(arena, "Conflict markers in {s}\n{s}", .{ file.path, bytes });
            return result;
        }
    } else {
        // A single selected path, with both rename identities, respects Git filters.
        const patch = process.git(io, a, path, if (file.staged)
            &.{ "diff", "--cached", "--no-ext-diff", "--no-textconv", "--", file.path, if (file.old_path.len > 0) file.old_path else file.path }
        else
            &.{ "diff", "--no-ext-diff", "--no-textconv", "--", file.path, if (file.old_path.len > 0) file.old_path else file.path }) catch |err| switch (err) {
            error.OutputTooLarge => {
                output.patch = "Large diff: preview is limited to 2 MiB. Open the file externally to review it.";
                return result;
            },
            else => return err,
        };
        defer patch.deinit(a);
        if (!patch.ok) return error.GitPreviewFailed;
        if (patch.stdout.len > limit) {
            output.patch = "Large diff: preview is limited to 2 MiB. Open the file externally to review it.";
            return result;
        }
        output.patch = try arena.dupe(u8, patch.stdout);
    }
    output.binary = !std.unicode.utf8ValidateSlice(output.patch) or std.mem.indexOf(u8, output.patch, "\nBinary files ") != null;
    if (!output.binary) {
        // Line metadata and split/unified caches must also stay bounded for
        // files made up of millions of very short lines.
        if (std.mem.count(u8, output.patch, "\n") > 25000) {
            output.patch = "Large diff: preview is limited to 25,000 lines. Open the file externally to review it.";
            return result;
        }
        output.lines = try diff.parse(arena, output.patch);
        for (output.lines) |line| switch (line.kind) {
            .addition => output.additions += 1,
            .deletion => output.deletions += 1,
            else => {},
        };
        output.stats_available = true;
    }
    return result;
}

test "status and numstat preserve two sides, conflicts, rename and unusual path bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try parseStatus(a, "MM café\tfile.txt\x00R  new\nname.txt\x00old.txt\x00UU conflict.txt\x00?? nested/new.txt\x00");
    try std.testing.expectEqual(@as(usize, 5), files.len);
    try applyNumstat(a, files, "2\t1\tcafé\tfile.txt\x000\t0\t\x00old.txt\x00new\nname.txt\x00", true);
    try applyNumstat(a, files, "3\t2\tcafé\tfile.txt\x00", false);
    try std.testing.expectEqual(@as(usize, 2), files[0].additions);
    try std.testing.expectEqual(@as(usize, 3), files[1].additions);
    try std.testing.expectEqualStrings("old.txt", files[2].old_path);
    try std.testing.expect(files[2].stats_available);
    try std.testing.expect(!files[3].stats_available);
    try std.testing.expect(!files[4].stats_available);
}
