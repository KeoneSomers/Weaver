//! Stable Windows bootstrap: authenticates the release manifest and archive before
//! invoking the versioned, signed installer. Rebuild only when its trust key changes.
const std = @import("std");
const updater = @import("updater.zig");
const process = @import("process.zig");
const options = @import("options");
pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .windows) return error.WindowsBootstrapOnly;
    const a = init.arena.allocator();
    const manifest = try updater.check(init.io, a, options.release_repo, options.update_public_key, "0.0.0");
    var selected: ?updater.Asset = null;
    for (manifest.assets) |asset| if (std.mem.eql(u8, asset.platform, "windows-x86_64")) {
        selected = asset;
        break;
    };
    const asset = selected orelse return error.NoWindowsRelease;
    const temp = init.environ_map.get("TEMP") orelse return error.NoTemporaryDirectory;
    const directory = try std.fs.path.join(a, &.{ temp, "Weaver", manifest.version });
    const downloaded = try updater.download(init.io, a, asset, directory);
    if (!std.mem.endsWith(u8, downloaded, ".exe")) return error.ExpectedWindowsInstaller;
    const r = try process.run(init.io, init.gpa, &.{ downloaded, "/SP-" }, null, null);
    defer r.deinit(init.gpa);
    if (!r.ok) return error.InstallerFailed;
}
