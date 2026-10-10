const std = @import("std");
const credentials = @import("credentials.zig");
pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    ok: bool,
    pub fn deinit(self: Result, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};
pub fn run(io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, input: ?[]const u8) !Result {
    return runWithEnvironment(io, a, argv, cwd, input, null, 900);
}
fn runWithEnvironment(io: std.Io, a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, input: ?[]const u8, environment: ?*const std.process.Environ.Map, timeout_s: i64) !Result {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = if (cwd) |p| .{ .path = p } else .inherit, .environ_map = environment, .stdin = if (input != null) .pipe else .ignore, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
    defer child.kill(io);
    var input_future: ?std.Io.Future(anyerror!void) = null;
    if (input) |data| {
        input_future = try io.concurrent(writeInput, .{ io, child.stdin.?, data });
        child.stdin = null;
    }
    defer if (input_future) |*future| {
        _ = future.cancel(io) catch {};
    };
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const deadline = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } }).toDeadline(io);
    while (multi.fill(4096, deadline)) |_| {
        if (multi.reader(0).buffered().len > 8 * 1024 * 1024 or multi.reader(1).buffered().len > 8 * 1024 * 1024) return error.OutputTooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi.checkAnyError();
    if (input_future) |*future| try future.await(io);
    const term = try child.wait(io);
    const stdout = try multi.toOwnedSlice(0);
    errdefer a.free(stdout);
    return .{ .stdout = stdout, .stderr = try multi.toOwnedSlice(1), .ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    } };
}
/// Starts a desktop launcher without pipes, so the application it opens cannot
/// hold them and stall the caller. Returns whether the launcher succeeded.
pub fn launch(io: std.Io, argv: []const []const u8) !bool {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true });
    defer child.kill(io);
    return switch (try child.wait(io)) {
        .exited => |code| code == 0,
        else => false,
    };
}
fn writeInput(io: std.Io, file: std.Io.File, bytes: []const u8) anyerror!void {
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
pub fn git(io: std.Io, a: std.mem.Allocator, path: []const u8, args: []const []const u8) !Result {
    return gitInput(io, a, path, args, null);
}
pub fn gitInput(io: std.Io, a: std.mem.Allocator, path: []const u8, args: []const []const u8, input: ?[]const u8) !Result {
    return gitWithEnvironment(io, a, path, args, input, null, 900);
}
pub fn backgroundFetch(io: std.Io, a: std.mem.Allocator, path: []const u8, environment: *const std.process.Environ.Map) !Result {
    var unattended = try environment.clone(a);
    defer unattended.deinit();
    try unattended.put("GIT_TERMINAL_PROMPT", "0");
    try unattended.put("GCM_INTERACTIVE", "never");
    try unattended.put("GIT_ASKPASS", "");
    try unattended.put("SSH_ASKPASS", "");
    // Keep configured helpers, SSH and hooks; fail quietly when credentials
    // are unavailable instead of opening an authentication dialog.
    return gitWithEnvironment(io, a, path, &.{ "-c", "credential.interactive=never", "fetch", "--all", "--prune" }, null, &unattended, 60);
}
/// Ask the Git credential helpers already configured on this computer for a
/// github.com credential. Git Credential Manager opens its own browser sign-in
/// when it has none stored.
pub fn credentialFill(io: std.Io, a: std.mem.Allocator, environment: *const std.process.Environ.Map) !Result {
    var graphical = try environment.clone(a);
    defer graphical.deinit();
    // Weaver has no terminal; only a graphical helper may prompt.
    try graphical.put("GIT_TERMINAL_PROMPT", "0");
    return runWithEnvironment(io, a, &.{ "git", "credential", "fill" }, null, "protocol=https\nhost=github.com\n\n", &graphical, 600);
}
fn gitWithEnvironment(io: std.Io, a: std.mem.Allocator, path: []const u8, args: []const []const u8, input: ?[]const u8, environment: ?*const std.process.Environ.Map, timeout_s: i64) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    const exe = try std.process.executablePathAlloc(io, a);
    defer a.free(exe);
    // Git helper syntax is shell-based; quote only our own executable, never repo content.
    const normalized = try a.dupe(u8, exe);
    defer a.free(normalized);
    for (normalized) |*ch| if (ch.* == '\\') {
        ch.* = '/';
    };
    const quoted = try std.mem.replaceOwned(u8, a, normalized, "'", "'\\''");
    defer a.free(quoted);
    const helper = try std.fmt.allocPrint(a, "credential.helper=!'{s}' --credential-helper", .{quoted});
    defer a.free(helper);
    // Prefer Weaver's signed-in GitHub account, then preserve configured helpers
    // for other hosts (and GitHub when Weaver is signed out).
    const configured = try run(io, a, &.{ "git", "-C", path, "config", "--get-all", "credential.helper" }, null, null);
    defer configured.deinit(a);
    try argv.appendSlice(a, &.{ "git", "--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c", "credential.helper=", "-c", helper });
    var helper_options: std.ArrayList([]u8) = .empty;
    defer {
        for (helper_options.items) |item| a.free(item);
        helper_options.deinit(a);
    }
    var helpers = std.mem.splitScalar(u8, configured.stdout, '\n');
    while (helpers.next()) |line| {
        const value = std.mem.trimEnd(u8, line, "\r");
        if (value.len == 0) continue;
        const option = try std.fmt.allocPrint(a, "credential.helper={s}", .{value});
        try helper_options.append(a, option);
        try argv.appendSlice(a, &.{ "-c", option });
    }
    // A signed-in GitHub account also serves SSH-style GitHub remotes, so they
    // need no SSH key. The repository's configured URL is left unchanged.
    if (credentials.get(io, a) catch null) |token| {
        credentials.clear(a, token);
        try argv.appendSlice(a, &.{ "-c", "url.https://github.com/.insteadOf=git@github.com:", "-c", "url.https://github.com/.insteadOf=ssh://git@github.com/" });
    }
    try argv.appendSlice(a, &.{ "-C", path });
    try argv.appendSlice(a, args);
    return runWithEnvironment(io, a, argv.items, null, input, environment, timeout_s);
}
pub fn validName(value: []const u8) bool {
    return value.len > 0 and value[0] != '-' and std.mem.indexOfAny(u8, value, "\x00\n\r") == null;
}
pub fn validRemote(value: []const u8) bool {
    if (!validName(value) or std.mem.indexOf(u8, value, "::") != null) return false;
    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "ssh://") or std.mem.startsWith(u8, value, "git@") or std.fs.path.isAbsolute(value);
}
test "remote URLs reject helper command execution and option injection" {
    try std.testing.expect(!validRemote("ext::sh -c bad"));
    try std.testing.expect(!validRemote("--upload-pack=bad"));
    try std.testing.expect(validRemote("https://github.com/owner/repo.git"));
    try std.testing.expect(validRemote("git@example.org:owner/repo.git"));
}
