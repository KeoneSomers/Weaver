const std = @import("std");
const git = @import("git.zig");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 4 and std.mem.eql(u8, args[1], "--benchmark")) {
        try git.init();
        defer git.shutdown();
        const provider = @import("provider.zig").git;
        var snapshot = if (std.mem.eql(u8, args[2], "eager")) try provider.load(init.io, init.gpa, args[3]) else try provider.scan(init.io, init.gpa, args[3]);
        defer snapshot.deinit();
        var bytes: usize = 0;
        var lines: usize = 0;
        for (snapshot.files) |file| {
            bytes += file.patch.len;
            lines += file.lines.len;
        }
        std.debug.print("mode={s} files={d} retained_patch_bytes={d} parsed_lines={d}\n", .{ args[2], snapshot.files.len, bytes, lines });
        if (std.mem.eql(u8, args[2], "progressive")) {
            var stats = try provider.counts(init.io, init.gpa, snapshot.path, snapshot.files);
            defer stats.deinit();
            if (snapshot.files.len > 0) {
                var selected = try provider.preview(init.io, init.gpa, snapshot.path, snapshot.files[0]);
                defer selected.deinit();
                std.debug.print("counted_files={d} selected_preview_bytes={d}\n", .{ stats.files.len, selected.files[0].patch.len });
            }
        }
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "--extension")) {
        const plugins = @import("plugins.zig");
        var registry = try plugins.Registry.init(init.gpa);
        defer registry.deinit();
        try registry.install(init.io, args[2]);
        const extension = registry.items.items[registry.items.items.len - 1];
        if (extension.manifest.commands.len == 0) return error.NoExtensionCommand;
        const result = try plugins.invoke(init.io, init.gpa, extension.manifest, extension.manifest.commands[0], args[3], "git", extension.settings);
        defer result.deinit(init.gpa);
        try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
        try std.Io.File.stderr().writeStreamingAll(init.io, result.stderr);
        if (!result.ok) return error.ExtensionFailed;
        return;
    }
    if (args.len != 2) return error.ExpectedRepositoryPath;
    try git.init();
    defer git.shutdown();
    var snapshot = try git.load(init.gpa, args[1]);
    defer snapshot.deinit();
    std.debug.print("{s}\nBranch: {s}; changes: {d}; history: {d}; ahead: {d}; behind: {d}\n", .{ snapshot.path, snapshot.branch, snapshot.files.len, snapshot.history.len, snapshot.ahead, snapshot.behind });
    for (snapshot.files) |file| std.debug.print("{s} {s} +{d} -{d}: {s}\n", .{ if (file.staged) "staged" else "unstaged", file.status, file.additions, file.deletions, file.path });
}
