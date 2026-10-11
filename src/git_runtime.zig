//! Machine-level Git health owned by the bundled Git extension, independent of repositories.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");

pub const Manager = enum { manual, windows, winget, brew, apple, apt, dnf, mise, asdf, nix, scoop, chocolatey, macports, conda };
pub fn managerName(manager: Manager) []const u8 {
    return switch (manager) {
        .manual => "Custom or unknown installation",
        .windows => "Git for Windows",
        .winget => "WinGet",
        .brew => "Homebrew",
        .apple => "Apple developer tools",
        .apt => "APT",
        .dnf => "DNF",
        .mise => "mise",
        .asdf => "asdf",
        .nix => "Nix",
        .scoop => "Scoop",
        .chocolatey => "Chocolatey",
        .macports => "MacPorts",
        .conda => "Conda",
    };
}
pub fn guidedManager(manager: Manager) bool {
    return switch (manager) {
        .mise, .asdf, .nix, .scoop, .chocolatey, .macports, .conda => true,
        else => false,
    };
}
pub fn managerInstructions(manager: Manager, os: std.Target.Os.Tag) []const u8 {
    return switch (manager) {
        .mise => "https://mise.jdx.dev/dev-tools/",
        .asdf => "https://asdf-vm.com/manage/versions.html",
        .nix => "https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-profile-upgrade",
        .scoop => "https://github.com/ScoopInstaller/Scoop/wiki/Commands",
        .chocolatey => "https://docs.chocolatey.org/en-us/choco/commands/upgrade/",
        .macports => "https://guide.macports.org/#using.port.upgrade",
        .conda => "https://docs.conda.io/projects/conda/en/latest/user-guide/tasks/manage-pkgs.html",
        else => instructions(os),
    };
}
pub const Presence = enum { missing, installed, unavailable };
pub const Indicator = enum { unavailable, update_available, current, unknown };
pub const InstallScope = enum { unspecified, user, machine };
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    presence: Presence = .unavailable,
    version: []const u8 = "",
    executable: []const u8 = "",
    manager: Manager = .manual,
    manager_executable: []const u8 = "",
    install_scope: InstallScope = .unspecified,
    latest: []const u8 = "",
    update_available: bool = false,
    updates_verified: bool = false,
    check_note: []const u8 = "Update check has not run.",
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
    pub fn indicator(self: *const Snapshot) Indicator {
        if (self.presence != .installed) return .unavailable;
        if (!self.updates_verified) return .unknown;
        return if (self.update_available) .update_available else .current;
    }
    pub fn label(self: *const Snapshot, a: std.mem.Allocator) ![]const u8 {
        return switch (self.presence) {
            .missing => "Git not installed",
            .unavailable => "Git unavailable",
            .installed => std.fmt.allocPrint(a, "Git {s}", .{self.version}),
        };
    }
    pub fn description(self: *const Snapshot) []const u8 {
        if (guidedManager(self.manager)) return "Update Git through the manager shown above, keeping your selected versions, pins and project configuration. Weaver will not replace this installation with a system installer.";
        return switch (self.manager) {
            .windows => if (self.manager_executable.len > 0) "WinGet will update this registered Git for Windows installation through its CLI. Weaver waits for the command, captures its output and checks the installed version. Windows may ask for administrator permission." else "WinGet is unavailable. Use the installation instructions to update this registered Git for Windows installation.",
            .winget => "WinGet will install Git.Git through its CLI. Weaver waits for completion and checks the installed version. Windows may ask for administrator permission.",
            .brew => "Homebrew will refresh its package metadata and install or upgrade only Git and its required dependencies.",
            .apple => if (self.presence == .missing) "Apple's Command Line Tools installer will open. Complete its prompts to install Git and the developer tools." else "Apple supplies this Git with its developer tools. Use Software Update to update those tools, or follow Git's macOS installation instructions for Homebrew or MacPorts.",
            .apt, .dnf => "Your distribution's package manager will install or update Git and required dependencies from your configured repositories. The system will ask for administrator permission.",
            .manual => "Use the installation instructions for your platform or the manager that installed this Git. Weaver cannot safely replace a custom installation automatically.",
            else => unreachable,
        };
    }
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    windows_build: u32 = 0,
    pub fn newer(self: Version, other: Version) bool {
        const left = [_]u32{ self.major, self.minor, self.patch, self.windows_build };
        const right = [_]u32{ other.major, other.minor, other.patch, other.windows_build };
        for (left, right) |l, r| {
            if (l != r) return l > r;
        }
        return false;
    }
};
/// Git output includes vendor suffixes; prereleases never qualify as stable updates.
pub fn version(text: []const u8) ?Version {
    var value = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, value, "git version ")) value = value[12..];
    if (std.mem.startsWith(u8, value, "v")) value = value[1..];
    if (std.mem.indexOf(u8, value, "-rc") != null or std.mem.indexOf(u8, value, ".rc") != null or
        std.mem.indexOf(u8, value, "beta") != null or std.mem.indexOf(u8, value, "alpha") != null or
        std.mem.indexOf(u8, value, "~") != null) return null;
    var pos: usize = 0;
    var numbers: [3]u32 = undefined;
    for (&numbers, 0..) |*number, i| {
        const start = pos;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
        if (pos == start) return null;
        number.* = std.fmt.parseInt(u32, value[start..pos], 10) catch return null;
        if (i < 2) {
            if (pos >= value.len or value[pos] != '.') return null;
            pos += 1;
        }
    }
    var result = Version{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] };
    if (std.mem.startsWith(u8, value[pos..], ".windows.")) {
        pos += 9;
        const start = pos;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
        result.windows_build = std.fmt.parseInt(u32, value[start..pos], 10) catch return null;
    }
    // Only recognized vendor/package suffixes may follow the numeric version.
    if (pos < value.len and value[pos] != ' ' and value[pos] != '-' and value[pos] != '+') return null;
    return result;
}

pub fn instructions(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "https://git-scm.com/install/windows",
        .macos => "https://git-scm.com/install/mac",
        else => "https://git-scm.com/install/linux",
    };
}

fn canonical(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch null;
}
fn findPath(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const file = if (builtin.os.tag == .windows) std.fmt.allocPrint(a, "{s}.exe", .{name}) catch return null else name;
    var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "", if (builtin.os.tag == .windows) ';' else ':');
    while (paths.next()) |raw| {
        const path = std.mem.trim(u8, raw, "\"");
        if (!std.fs.path.isAbsolute(path)) continue;
        const candidate = std.fs.path.join(a, &.{ path, file }) catch return null;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = builtin.os.tag != .windows }) catch continue;
        return candidate;
    }
    return null;
}
fn find(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    // App execution aliases and manager shims must retain their launch path.
    return findPath(io, a, env, name);
}
fn normalized(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const copy = try a.dupe(u8, path);
    for (copy) |*ch| {
        ch.* = std.ascii.toLower(ch.*);
        if (ch.* == '\\') ch.* = '/';
    }
    return std.mem.trimEnd(u8, copy, "/");
}
fn inside(path: []const u8, root: []const u8) bool {
    return root.len > 0 and path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}
/// Inspect both the PATH entry and its symlink target before considering any
/// system installer. Resolving a shim first can hide its owning manager.
pub fn pathManager(a: std.mem.Allocator, path: []const u8, resolved: []const u8, env: *const std.process.Environ.Map) !?Manager {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const paths = [_][]const u8{ try normalized(temporary, path), try normalized(temporary, resolved) };
    for (paths) |p| {
        if (std.mem.indexOf(u8, p, "/mise/shims/") != null or std.mem.indexOf(u8, p, "/mise/installs/git/") != null) return .mise;
        if (std.mem.indexOf(u8, p, "/.asdf/shims/") != null or std.mem.indexOf(u8, p, "/.asdf/installs/git/") != null) return .asdf;
        if (std.mem.startsWith(u8, p, "/nix/store/")) return .nix;
        if (std.mem.indexOf(u8, p, "/scoop/shims/") != null or std.mem.indexOf(u8, p, "/scoop/apps/git/") != null) return .scoop;
        if (std.mem.indexOf(u8, p, "/chocolatey/") != null) return .chocolatey;
        for ([_]struct { key: []const u8, manager: Manager }{
            .{ .key = "MISE_DATA_DIR", .manager = .mise },           .{ .key = "ASDF_DATA_DIR", .manager = .asdf },
            .{ .key = "SCOOP", .manager = .scoop },                  .{ .key = "SCOOP_GLOBAL", .manager = .scoop },
            .{ .key = "ChocolateyInstall", .manager = .chocolatey }, .{ .key = "CONDA_PREFIX", .manager = .conda },
        }) |item| if (env.get(item.key)) |value| {
            const root = try normalized(temporary, value);
            if (!inside(p, root)) continue;
            const relative = p[root.len..];
            if (item.manager == .mise or item.manager == .asdf) {
                if (!std.mem.startsWith(u8, relative, "/shims/") and !std.mem.startsWith(u8, relative, "/installs/git/")) continue;
            }
            return item.manager;
        };
    }
    // An unrecognized shim is still a version selection boundary; do not replace it.
    for (paths) |p| if (std.mem.indexOf(u8, p, "/shims/") != null) return .manual;
    return null;
}
fn probe(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, argv: []const []const u8) ?process.Result {
    return process.probe(io, a, argv, env) catch null;
}
fn textField(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(field) orelse return null;
    return if (v == .string) v.string else null;
}
pub fn windowsRelease(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRelease;
    inline for (.{ "prerelease", "draft" }) |field| {
        const v = parsed.value.object.get(field) orelse return error.InvalidRelease;
        if (v != .bool or v.bool) return error.InvalidRelease;
    }
    const tag = textField(parsed.value, "tag_name") orelse return error.InvalidRelease;
    _ = version(tag) orelse return error.InvalidRelease;
    if (std.mem.indexOf(u8, tag, ".windows.") == null) return error.InvalidRelease;
    return a.dupe(u8, if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag);
}
pub fn brewRelease(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRelease;
    const versions = parsed.value.object.get("versions") orelse return error.InvalidRelease;
    const stable = textField(versions, "stable") orelse return error.InvalidRelease;
    _ = version(stable) orelse return error.InvalidRelease;
    return a.dupe(u8, stable);
}
fn download(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, url: []const u8) ![]const u8 {
    const r = try process.probe(io, a, &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "20", "--connect-timeout", "5", "--max-redirs", "3", "--proto", "=https", "--proto-redir", "=https", "--user-agent", "Weaver-Git-runtime", url }, env);
    defer r.deinit(a);
    if (!r.ok) return error.UpdateCheckFailed;
    return a.dupe(u8, r.stdout);
}
fn windowsScope(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, executable: []const u8) ?InstallScope {
    // Match the registered installation; preserve portable Git, SDKs and private copies.
    for ([_][]const u8{ "HKCU\\SOFTWARE\\GitForWindows", "HKLM\\SOFTWARE\\GitForWindows" }, 0..) |key, key_index| {
        const r = probe(io, a, env, &.{ "reg.exe", "query", key, "/v", "InstallPath" }) orelse continue;
        defer r.deinit(a);
        if (!r.ok) continue;
        var lines = std.mem.splitScalar(u8, r.stdout, '\n');
        while (lines.next()) |line| if (std.mem.indexOf(u8, line, "REG_SZ")) |index| {
            const root = std.mem.trim(u8, line[index + 6 ..], " \t\r");
            if (!std.fs.path.isAbsolute(root)) continue;
            for ([_][]const u8{ "cmd/git.exe", "bin/git.exe", "mingw64/bin/git.exe", "mingw32/bin/git.exe" }) |relative| {
                const candidate = std.fs.path.join(a, &.{ root, relative }) catch return null;
                if (canonical(io, a, candidate)) |owned| if (std.ascii.eqlIgnoreCase(owned, executable)) return if (key_index == 0) .user else .machine;
            }
        };
    }
    return null;
}
pub fn chocolateyPackage(output: []const u8, installed: []const u8) bool {
    const suffix = std.mem.indexOf(u8, installed, ".windows.") orelse return false;
    const base = installed[0..suffix];
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const row = std.mem.trim(u8, line, "\r\n ");
        const separator = std.mem.indexOfScalar(u8, row, '|') orelse continue;
        if (!std.ascii.eqlIgnoreCase(row[0..separator], "git.install")) continue;
        const value = row[separator + 1 ..];
        if (std.mem.eql(u8, value, base)) return true;
        if (std.mem.startsWith(u8, value, base) and value.len > base.len and value[base.len] == '.') {
            _ = std.fmt.parseInt(u32, value[base.len + 1 ..], 10) catch continue;
            return true;
        }
    }
    return false;
}
fn chooseBrew(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, s: *Snapshot, resolved: []const u8) bool {
    var brew = find(io, a, env, "brew");
    if (brew == null and builtin.os.tag == .macos) for ([_][]const u8{ "/opt/homebrew/bin/brew", "/usr/local/bin/brew" }) |path| {
        if (canonical(io, a, path)) |exe| {
            brew = exe;
            break;
        }
    };
    const exe = brew orelse return false;
    if (s.presence == .missing) {
        s.manager = .brew;
        s.manager_executable = exe;
        return true;
    }
    if (probe(io, a, env, &.{ exe, "--prefix", "git" })) |r| {
        defer r.deinit(a);
        if (r.ok) {
            const bin = std.fs.path.join(a, &.{ std.mem.trim(u8, r.stdout, "\r\n "), "bin/git" }) catch return false;
            if (canonical(io, a, bin)) |owned| if (std.mem.eql(u8, owned, resolved)) {
                s.manager = .brew;
                s.manager_executable = exe;
                return true;
            };
        }
    }
    return false;
}
fn chooseManager(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, s: *Snapshot) void {
    const resolved = canonical(io, a, s.executable) orelse s.executable;
    if (s.executable.len > 0) if (pathManager(a, s.executable, resolved, env) catch null) |manager| {
        s.manager = manager;
        return;
    };
    if ((builtin.os.tag == .macos or builtin.os.tag == .linux) and chooseBrew(io, a, env, s, resolved)) return;
    switch (builtin.os.tag) {
        .windows => {
            const scope = if (s.presence == .installed and std.mem.indexOf(u8, s.version, ".windows.") != null) windowsScope(io, a, env, resolved) else null;
            if (scope) |installed_scope| {
                // Chocolatey's Git package normally installs into the same vendor
                // directory. A matching package receipt takes priority over it.
                if (find(io, a, env, "choco")) |exe| if (probe(io, a, env, &.{ exe, "list", "--exact", "git.install", "--limit-output" })) |r| {
                    defer r.deinit(a);
                    if (r.ok and chocolateyPackage(r.stdout, s.version)) {
                        s.manager = .chocolatey;
                        s.manager_executable = exe;
                        return;
                    }
                };
                s.manager = .windows;
                s.manager_executable = find(io, a, env, "winget") orelse "";
                s.install_scope = installed_scope;
            } else if (s.presence == .missing) if (find(io, a, env, "winget")) |exe| {
                s.manager = .winget;
                s.manager_executable = exe;
            };
        },
        .macos => {
            if (std.mem.eql(u8, resolved, "/opt/local/bin/git")) if (canonical(io, a, "/opt/local/bin/port")) |exe| {
                if (probe(io, a, env, &.{ exe, "provides", resolved })) |r| {
                    defer r.deinit(a);
                    if (r.ok and std.mem.indexOf(u8, r.stdout, "provided by: git") != null) {
                        s.manager = .macports;
                        s.manager_executable = exe;
                        return;
                    }
                }
            };
            if (std.mem.eql(u8, resolved, "/usr/bin/git") or std.mem.indexOf(u8, s.version, "Apple Git") != null) s.manager = .apple;
            if (s.presence == .missing) {
                s.manager = .apple;
                s.manager_executable = "/usr/bin/xcode-select";
            }
        },
        .linux => {
            if (find(io, a, env, "apt-get")) |exe| {
                var owned = s.presence == .missing;
                if (!owned) if (probe(io, a, env, &.{ "dpkg-query", "--search", resolved })) |r| {
                    defer r.deinit(a);
                    const expected = std.fmt.allocPrint(a, "git: {s}", .{resolved}) catch return;
                    owned = r.ok and std.mem.eql(u8, std.mem.trim(u8, r.stdout, "\r\n"), expected);
                };
                if (owned) {
                    s.manager = .apt;
                    s.manager_executable = exe;
                    return;
                }
            }
            if (find(io, a, env, "dnf")) |exe| {
                var owned = s.presence == .missing;
                if (!owned) if (probe(io, a, env, &.{ "rpm", "-qf", "--qf", "%{NAME}", resolved })) |r| {
                    defer r.deinit(a);
                    owned = r.ok and (std.mem.eql(u8, r.stdout, "git") or std.mem.eql(u8, r.stdout, "git-core"));
                };
                if (owned) {
                    s.manager = .dnf;
                    s.manager_executable = exe;
                }
            }
        },
        else => {},
    }
}
pub fn aptCandidate(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Candidate: ")) {
            const candidate = trimmed[11..];
            if (candidate.len == 0 or std.mem.eql(u8, candidate, "(none)") or std.mem.indexOfAny(u8, candidate, " \t\r\n") != null) return null;
            return candidate;
        }
    }
    return null;
}
fn packageStable(value: []const u8) bool {
    const without_epoch = if (std.mem.indexOfScalar(u8, value, ':')) |i| value[i + 1 ..] else value;
    return version(without_epoch) != null;
}
fn checkUpdates(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, s: *Snapshot) !void {
    if (guidedManager(s.manager)) {
        s.check_note = "Git updates are controlled by your installation manager, including its selected versions and pins.";
        return;
    }
    if (s.manager == .windows and s.manager_executable.len > 0) {
        const r = try process.probe(io, a, &.{ s.manager_executable, "list", "--id", "Git.Git", "--exact", "--scope", @tagName(s.install_scope), "--source", "winget", "--accept-source-agreements", "--disable-interactivity" }, env);
        defer r.deinit(a);
        if (!r.ok) return error.UpdateCheckFailed;
        const info = wingetGitInfo(r.stdout) orelse return error.UpdateCheckFailed;
        if (info.candidate) |candidate| {
            s.latest = try std.fmt.allocPrint(a, "{d}.{d}.{d}.windows.{d}", .{ candidate.major, candidate.minor, candidate.patch, candidate.windows_build });
            s.update_available = candidate.newer(version(s.version) orelse return error.UnrecognizedVersion);
        }
        s.updates_verified = true;
        s.check_note = if (s.update_available) "A stable Git update is available through WinGet." else "WinGet found no newer Git package for this installation.";
        return;
    }
    if (builtin.os.tag == .windows and std.mem.indexOf(u8, s.version, ".windows.") != null) {
        const bytes = try download(io, a, env, "https://api.github.com/repos/git-for-windows/git/releases/latest");
        s.latest = try windowsRelease(a, bytes);
        const installed = version(s.version) orelse return error.UnrecognizedVersion;
        s.update_available = (version(s.latest) orelse return error.InvalidRelease).newer(installed);
        s.updates_verified = true;
        s.check_note = if (s.update_available) "A stable Git for Windows update is available." else "No newer stable Git for Windows release found.";
        return;
    }
    switch (s.manager) {
        .windows, .brew => {
            if (s.manager == .brew) {
                const pinned = try process.probe(io, a, &.{ s.manager_executable, "list", "--pinned" }, env);
                defer pinned.deinit(a);
                if (!pinned.ok) return error.UpdateCheckFailed;
                var lines = std.mem.splitScalar(u8, pinned.stdout, '\n');
                while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trim(u8, line, "\r "), "git")) {
                    s.check_note = "Git is pinned in Homebrew. Unpin it in Homebrew to enable updates.";
                    return;
                };
            }
            const bytes = try download(io, a, env, if (s.manager == .windows) "https://api.github.com/repos/git-for-windows/git/releases/latest" else "https://formulae.brew.sh/api/formula/git.json");
            s.latest = if (s.manager == .windows) try windowsRelease(a, bytes) else try brewRelease(a, bytes);
            const installed = version(s.version) orelse return error.UnrecognizedVersion;
            s.update_available = (version(s.latest) orelse return error.InvalidRelease).newer(installed);
            s.updates_verified = true;
            s.check_note = if (s.update_available) "A stable Git update is available." else "No newer stable Git release found.";
        },
        .apt => {
            const policy = try process.probe(io, a, &.{ "apt-cache", "policy", "git" }, env);
            defer policy.deinit(a);
            if (!policy.ok) return error.UpdateCheckFailed;
            const candidate = aptCandidate(policy.stdout) orelse return error.UpdateCheckFailed;
            if (!packageStable(candidate)) return error.UnstableCandidate;
            const current = try process.probe(io, a, &.{ "dpkg-query", "--show", "--showformat=${Version}", "git" }, env);
            defer current.deinit(a);
            if (!current.ok) return error.UpdateCheckFailed;
            const comparison = try process.probe(io, a, &.{ "dpkg", "--compare-versions", candidate, "gt", std.mem.trim(u8, current.stdout, "\r\n") }, env);
            defer comparison.deinit(a);
            if (comparison.exit_code != 0 and comparison.exit_code != 1) return error.UpdateCheckFailed;
            s.update_available = comparison.ok;
            s.latest = try a.dupe(u8, candidate);
            s.updates_verified = true;
            s.check_note = if (s.update_available) "A Git update is available in your distribution's package cache." else "No Git update found in the local package cache. Refresh system updates for newer metadata.";
        },
        .dnf => {
            const r = try process.probe(io, a, &.{ s.manager_executable, "--cacheonly", "--quiet", "repoquery", "--upgrades", "--latest-limit=1", "--qf", "%{evr}", "git" }, env);
            defer r.deinit(a);
            if (!r.ok) return error.UpdateCheckFailed;
            const candidate = std.mem.trim(u8, r.stdout, "\r\n ");
            if (candidate.len > 0 and (!packageStable(candidate) or std.mem.indexOfScalar(u8, candidate, '\n') != null)) return error.UnstableCandidate;
            s.update_available = candidate.len > 0;
            s.latest = try a.dupe(u8, candidate);
            s.updates_verified = true;
            s.check_note = if (s.update_available) "A Git update is available in your distribution's package cache." else "No Git update found in the local package cache. Refresh system updates for newer metadata.";
        },
        .apple => s.check_note = "Check Software Update for Apple developer tool updates.",
        else => s.check_note = "Use your installation manager to check for Git updates.",
    }
}
pub fn inspect(io: std.Io, allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, updates: bool) Snapshot {
    var s = Snapshot{ .arena = .init(allocator) };
    const a = s.arena.allocator();
    var env = environment.clone(a) catch return s;
    defer env.deinit();
    env.put("LC_ALL", "C") catch return s;
    env.put("HOMEBREW_NO_AUTO_UPDATE", "1") catch return s;
    if (findPath(io, a, &env, "git")) |exe| {
        s.executable = exe;
        const resolved = canonical(io, a, exe) orelse exe;
        if (pathManager(a, exe, resolved, &env) catch null) |manager| s.manager = manager;
        s.check_note = "Git's version could not be read. Check the selected installation or version manager.";
        // /usr/bin/git on macOS can launch the CLT installation dialog. Probe the
        // developer tools first, so simply starting Weaver never opens an installer.
        if (builtin.os.tag == .macos and std.mem.eql(u8, resolved, "/usr/bin/git")) {
            const tools = probe(io, a, &env, &.{ "xcode-select", "-p" }) orelse return s;
            defer tools.deinit(a);
            if (!tools.ok) {
                s.presence = .missing;
                chooseManager(io, a, &env, &s);
                return s;
            }
        }
        const r = probe(io, a, &env, &.{ exe, "--version" }) orelse return s;
        defer r.deinit(a);
        if (!r.ok or !std.mem.startsWith(u8, r.stdout, "git version ")) return s;
        const value = std.mem.trim(u8, r.stdout[12..], "\r\n ");
        if (value.len > 128 or std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return s;
        s.version = a.dupe(u8, value) catch return s;
        s.presence = .installed;
    } else s.presence = .missing;
    chooseManager(io, a, &env, &s);
    if (s.presence == .installed and updates) {
        checkUpdates(io, a, &env, &s) catch {
            s.update_available = false;
            s.updates_verified = false;
            s.check_note = "Could not check for Git updates. Try again later or use your installation manager.";
        };
    } else s.check_note = if (s.presence == .missing) "Git was not found on Weaver's PATH. After installing Git, restart Weaver if its PATH changed." else "Automatic Git update checks are disabled.";
    return s;
}
pub fn canApply(s: *const Snapshot) bool {
    return (s.presence == .missing or s.update_available) and switch (s.manager) {
        .manual, .mise, .asdf, .nix, .scoop, .chocolatey, .macports, .conda => false,
        .apple => s.presence == .missing,
        .windows => s.manager_executable.len > 0 and s.install_scope != .unspecified,
        else => true,
    };
}
/// Only fixed package IDs and a previously verified owning manager enter this argv.
pub fn applyArguments(a: std.mem.Allocator, s: *const Snapshot) ![]const []const u8 {
    const args: []const []const u8 = switch (s.manager) {
        .windows => &.{ s.manager_executable, "upgrade", "--id", "Git.Git", "--exact", "--scope", @tagName(s.install_scope), "--source", "winget", "--silent", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity" },
        .apple => &.{ s.manager_executable, "--install" },
        .winget => &.{ s.manager_executable, "install", "--id", "Git.Git", "--exact", "--source", "winget", "--silent", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity" },
        .brew => &.{ s.manager_executable, if (s.presence == .missing) "install" else "upgrade", "git" },
        .apt => if (s.presence == .missing) &.{ "pkexec", "--disable-internal-agent", s.manager_executable, "install", "-y", "git" } else &.{ "pkexec", "--disable-internal-agent", s.manager_executable, "install", "--only-upgrade", "-y", "git" },
        .dnf => &.{ "pkexec", "--disable-internal-agent", s.manager_executable, if (s.presence == .missing) "install" else "upgrade", "-y", "git" },
        else => &.{},
    };
    return a.dupe([]const u8, args);
}
pub fn apply(io: std.Io, a: std.mem.Allocator, s: *const Snapshot) !process.Result {
    if (!canApply(s)) return error.NoAutomaticGitInstaller;
    if (s.manager == .windows) {
        // Match the existing package first; an update never falls back to install
        // or bypasses a package-manager pin, checksum, or architecture check.
        var listed = try process.run(io, a, &.{ s.manager_executable, "list", "--id", "Git.Git", "--exact", "--scope", @tagName(s.install_scope), "--source", "winget", "--accept-source-agreements", "--disable-interactivity" }, null, null);
        errdefer listed.deinit(a);
        if (!listed.ok) return listed;
        if (!hasPackageId(listed.stdout, "Git.Git")) {
            listed.ok = false;
            const reason = try a.dupe(u8, "WinGet did not identify this Git installation as Git.Git. No update was started.");
            a.free(listed.stderr);
            listed.stderr = reason;
            return listed;
        }
        listed.deinit(a);
    }
    if (s.manager == .brew) {
        const r = try process.run(io, a, &.{ s.manager_executable, "update" }, null, null);
        if (!r.ok) return r;
        r.deinit(a);
    }
    const args = try applyArguments(a, s);
    defer a.free(args);
    return process.run(io, a, args, null, null);
}
pub fn hasPackageId(output: []const u8, id: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, output, " \t\r\n");
    while (words.next()) |word| if (std.mem.eql(u8, word, id)) return true;
    return false;
}
const WingetInfo = struct { current: Version, candidate: ?Version };
fn wingetVersion(value: []const u8) ?Version {
    var numbers: [4]u32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, value, '.');
    while (parts.next()) |part| {
        if (count >= numbers.len or part.len == 0) return null;
        numbers[count] = std.fmt.parseInt(u32, part, 10) catch return null;
        count += 1;
    }
    if (count < 3) return null;
    return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2], .windows_build = numbers[3] };
}
pub fn wingetGitInfo(output: []const u8) ?WingetInfo {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        while (words.next()) |word| if (std.mem.eql(u8, word, "Git.Git")) {
            const current = wingetVersion(words.next() orelse return null) orelse return null;
            const candidate = if (words.next()) |value| (if (std.mem.eql(u8, value, "winget")) null else wingetVersion(value) orelse return null) else null;
            return .{ .current = current, .candidate = candidate };
        };
    }
    return null;
}
pub const Completion = enum { failed, updated, installed, unchanged, unavailable, handoff };
pub fn completion(before: *const Snapshot, after: *const Snapshot, result: process.Result) Completion {
    // Apple CLT's CLI explicitly hands off to a system-owned installer.
    if (before.manager == .apple and result.ok and after.presence != .installed) return .handoff;
    const reboot_success = (before.manager == .windows or before.manager == .winget) and result.exit_code == 3010;
    if (!result.ok and !reboot_success) return .failed;
    if (after.presence != .installed) return .unavailable;
    if (before.presence == .missing) return .installed;
    const old = version(before.version) orelse return .unchanged;
    const current = version(after.version) orelse return .unchanged;
    return if (current.newer(old)) .updated else .unchanged;
}
pub const Report = struct { failed: bool, message: []const u8, details: []const u8 };
pub fn installationReport(a: std.mem.Allocator, before: *const Snapshot, after: *const Snapshot, result: process.Result) !Report {
    const outcome = completion(before, after, result);
    const message = switch (outcome) {
        .failed => "The Git command failed or was cancelled. Review its exit code and output below.",
        .updated => try std.fmt.allocPrint(a, "Git updated from {s} to {s}. The new version was verified on this computer.", .{ before.version, after.version }),
        .installed => try std.fmt.allocPrint(a, "Git {s} was installed and verified on this computer.", .{after.version}),
        .unchanged => try std.fmt.allocPrint(a, "The command finished, but Git is still {s}. The manager may have skipped the update, or a restart may be needed. Review the output below.", .{after.version}),
        .unavailable => "The command finished, but Git could not be detected. Restart Weaver if your PATH changed, then check again.",
        .handoff => "Apple's developer tools installer opened. Complete its prompts, then check again.",
    };
    const exit = if (result.exit_code) |code| try std.fmt.allocPrint(a, "{d} (0x{x:0>8})", .{ code, code }) else "unavailable (process did not exit normally)";
    const limit = 8192;
    const stdout = result.stdout[result.stdout.len - @min(result.stdout.len, limit) ..];
    const stderr = result.stderr[result.stderr.len - @min(result.stderr.len, limit) ..];
    const output = try cleanOutput(a, try std.fmt.allocPrint(a, "Exit code: {s}\n{s}{s}\n{s}\n", .{ exit, if (stdout.len < result.stdout.len or stderr.len < result.stderr.len) "Earlier output omitted.\n" else "", stdout, stderr }));
    return .{ .failed = outcome == .failed or outcome == .unchanged or outcome == .unavailable, .message = message, .details = output };
}
fn cleanOutput(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        const ch = bytes[index];
        if (ch == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '[') {
            index += 2;
            while (index < bytes.len and (bytes[index] < 0x40 or bytes[index] > 0x7e)) : (index += 1) {}
            continue;
        }
        if (ch == '\r') {
            if (index + 1 == bytes.len or bytes[index + 1] != '\n') try out.append(a, '\n');
        } else if (ch >= 32 or ch == '\n' or ch == '\t') try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}

test "Git vendor versions, Windows rebuilds and stable release filtering" {
    const v = version("git version 2.56.0.windows.2").?;
    try std.testing.expect(v.newer(version("2.56.0.windows.1").?));
    try std.testing.expect(!v.newer(v));
    try std.testing.expect(version("2.57.0-rc1") == null);
    try std.testing.expect(version("2.57.0.rc0") == null);
    try std.testing.expect(version("2.56.0beta1") == null);
    try std.testing.expect(version("invalid") == null);
    try std.testing.expect(version("2.56.0anything") == null);
    try std.testing.expect(version("2.50.1 (Apple Git-155)") != null);
    try std.testing.expect(version("2.43.0-1ubuntu7.3") != null);
}
test "only published stable Windows metadata produces an update" {
    const a = std.testing.allocator;
    const tag = try windowsRelease(a, "{\"tag_name\":\"v2.56.0.windows.2\",\"prerelease\":false,\"draft\":false}");
    defer a.free(tag);
    try std.testing.expectEqualStrings("2.56.0.windows.2", tag);
    try std.testing.expectError(error.InvalidRelease, windowsRelease(a, "{\"tag_name\":\"v2.57.0-rc0.windows.1\",\"prerelease\":false,\"draft\":false}"));
    try std.testing.expectError(error.InvalidRelease, windowsRelease(a, "{\"tag_name\":\"v2.56.0.windows.2\",\"prerelease\":true,\"draft\":false}"));
    try std.testing.expectError(error.InvalidRelease, windowsRelease(a, "{}"));
}
test "Homebrew stable channel and distribution candidates" {
    const a = std.testing.allocator;
    const stable = try brewRelease(a, "{\"versions\":{\"stable\":\"2.56.0\",\"head\":\"HEAD\"}}");
    defer a.free(stable);
    try std.testing.expectEqualStrings("2.56.0", stable);
    try std.testing.expectEqualStrings("1:2.43.0-1ubuntu7.3", aptCandidate("git:\n  Installed: 1:2.43.0-1ubuntu7.2\n  Candidate: 1:2.43.0-1ubuntu7.3\n").?);
    try std.testing.expect(aptCandidate("Candidate: (none)") == null);
    try std.testing.expect(packageStable("1:2.43.0-1ubuntu7.3"));
    try std.testing.expect(!packageStable("1:2.57.0~rc1-1"));
}
test "install and update actions preserve manager ownership and scope" {
    var s = Snapshot{ .arena = .init(std.testing.allocator), .presence = .installed, .manager = .apt, .manager_executable = "/usr/bin/apt-get", .update_available = true };
    defer s.deinit();
    const a = s.arena.allocator();
    try std.testing.expect(canApply(&s));
    try std.testing.expectEqualStrings("--only-upgrade", (try applyArguments(a, &s))[4]);
    s.manager = .manual;
    try std.testing.expect(!canApply(&s));
    try std.testing.expectEqual(@as(usize, 0), (try applyArguments(a, &s)).len);
    s.manager = .apple;
    try std.testing.expect(!canApply(&s));
    s.manager = .brew;
    s.presence = .missing;
    try std.testing.expectEqualStrings("install", (try applyArguments(a, &s))[1]);
    try std.testing.expectEqualStrings("https://git-scm.com/install/mac", instructions(.macos));
    s.manager = .apple;
    try std.testing.expect(canApply(&s));
    try std.testing.expectEqualStrings("--install", (try applyArguments(a, &s))[1]);
}
test "an empty PATH detects missing Git without running an installer" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var s = inspect(std.testing.io, std.testing.allocator, &env, false);
    defer s.deinit();
    try std.testing.expectEqual(Presence.missing, s.presence);
    s.manager = .manual;
    try std.testing.expectError(error.NoAutomaticGitInstaller, apply(std.testing.io, std.testing.allocator, &s));
}
test "version manager paths take priority over resolved system Git and package ownership" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectEqual(Manager.mise, (try pathManager(a, "/home/user/.local/share/mise/shims/git", "/usr/bin/git", &env)).?);
    try std.testing.expectEqual(Manager.asdf, (try pathManager(a, "/home/user/.asdf/shims/git", "/usr/bin/git", &env)).?);
    try std.testing.expectEqual(Manager.nix, (try pathManager(a, "/run/current-system/sw/bin/git", "/nix/store/hash-git-2.56.0/bin/git", &env)).?);
    try std.testing.expectEqual(Manager.scoop, (try pathManager(a, "C:\\Users\\user\\scoop\\shims\\git.exe", "C:\\Program Files\\Git\\cmd\\git.exe", &env)).?);
    try std.testing.expectEqual(Manager.chocolatey, (try pathManager(a, "C:\\ProgramData\\chocolatey\\bin\\git.exe", "C:\\Program Files\\Git\\cmd\\git.exe", &env)).?);
    try env.put("MISE_DATA_DIR", "/custom/tool-store");
    try std.testing.expectEqual(Manager.mise, (try pathManager(a, "/custom/tool-store/installs/git/2.56.0/bin/git", "/usr/bin/git", &env)).?);
    try env.put("CONDA_PREFIX", "/opt/environments/dev");
    try std.testing.expectEqual(Manager.conda, (try pathManager(a, "/opt/environments/dev/bin/git", "/opt/environments/dev/bin/git", &env)).?);
    try std.testing.expect((try pathManager(a, "/opt/environments/developer/bin/git", "/opt/environments/developer/bin/git", &env)) == null);
    try std.testing.expectEqual(Manager.manual, (try pathManager(a, "/custom/manager/shims/git", "/usr/bin/git", &env)).?);
    try std.testing.expect((try pathManager(a, "/usr/bin/git", "/usr/bin/git", &env)) == null);
    var s = Snapshot{ .arena = .init(a), .presence = .installed, .update_available = true };
    defer s.deinit();
    for ([_]Manager{ .mise, .asdf, .nix, .scoop, .chocolatey, .macports, .conda }) |manager| {
        s.manager = manager;
        try std.testing.expect(!canApply(&s));
        try std.testing.expectEqual(@as(usize, 0), (try applyArguments(s.arena.allocator(), &s)).len);
    }
}
test "Chocolatey receipts must match the active vendor Git version" {
    try std.testing.expect(chocolateyPackage("git.install|2.56.0\n", "2.56.0.windows.2"));
    try std.testing.expect(chocolateyPackage("git.install|2.56.0.2\n", "2.56.0.windows.2"));
    try std.testing.expect(!chocolateyPackage("git.install|2.55.0\n", "2.56.0.windows.2"));
    try std.testing.expect(!chocolateyPackage("git.install|2.56.0-beta\n", "2.56.0.windows.2"));
    try std.testing.expect(!chocolateyPackage("other|2.56.0\n", "2.56.0.windows.2"));
}
test "Windows CLI updates target only the existing exact package and never hand off to Git's GUI updater" {
    var s = Snapshot{ .arena = .init(std.testing.allocator), .presence = .installed, .manager = .windows, .version = "2.45.1.windows.1", .manager_executable = "C:\\WinGet\\winget.exe", .install_scope = .machine, .update_available = true };
    defer s.deinit();
    const args = try applyArguments(s.arena.allocator(), &s);
    try std.testing.expect(canApply(&s));
    try std.testing.expectEqualStrings("upgrade", args[1]);
    try std.testing.expectEqualStrings("Git.Git", args[3]);
    try std.testing.expectEqualStrings("--scope", args[5]);
    try std.testing.expectEqualStrings("machine", args[6]);
    for (args) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "install"));
        try std.testing.expect(!std.mem.eql(u8, arg, "update-git-for-windows"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--force"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--include-pinned"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--ignore-security-hash"));
    }
    s.manager_executable = "";
    try std.testing.expect(!canApply(&s));
    try std.testing.expect(hasPackageId("Name  Id  Version\nGit  Git.Git  2.45.1", "Git.Git"));
    try std.testing.expect(!hasPackageId("Git Git.Git.Preview 2.56.0", "Git.Git"));
    const available = wingetGitInfo("Name Id Version Available\r\nGit Git.Git 2.45.1 2.55.0.5\r\n").?;
    try std.testing.expectEqual(@as(u32, 5), available.candidate.?.windows_build);
    try std.testing.expect(available.candidate.?.newer(version("2.45.1.windows.1").?));
    try std.testing.expect(wingetGitInfo("Git Git.Git 2.55.0.5 winget\n").?.candidate == null);
    try std.testing.expect(wingetGitInfo("Git Git.Git Unknown 2.55.0.5\n") == null);
    try std.testing.expect(wingetGitInfo("Git Git.Git 2.55.0.5 2.56.0-rc1\n") == null);
}
test "CLI completion requires an observed install or newer Git, not a successful launch or exit alone" {
    var before = Snapshot{ .arena = .init(std.testing.allocator), .presence = .installed, .manager = .windows, .version = "2.45.1.windows.1" };
    defer before.deinit();
    var after = Snapshot{ .arena = .init(std.testing.allocator), .presence = .installed, .manager = .windows, .version = "2.45.1.windows.1" };
    defer after.deinit();
    var result = process.Result{ .stdout = try std.testing.allocator.dupe(u8, "\x1b[32mInstaller launched\x1b[0m\r\n"), .stderr = try std.testing.allocator.dupe(u8, "Access denied"), .ok = false, .exit_code = 2 };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Completion.failed, completion(&before, &after, result));
    result.ok = true;
    result.exit_code = 0;
    try std.testing.expectEqual(Completion.unchanged, completion(&before, &after, result));
    const report = try installationReport(after.arena.allocator(), &before, &after, result);
    try std.testing.expect(report.failed);
    try std.testing.expect(std.mem.indexOf(u8, report.message, "still 2.45.1.windows.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.details, "Access denied") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, report.details, 0x1b) == null);
    after.version = "2.56.0.windows.2";
    try std.testing.expectEqual(Completion.updated, completion(&before, &after, result));
    result.ok = false;
    result.exit_code = 3010;
    try std.testing.expectEqual(Completion.updated, completion(&before, &after, result));
    before.presence = .missing;
    try std.testing.expectEqual(Completion.installed, completion(&before, &after, result));
    result.ok = true;
    result.exit_code = 0;
    after.presence = .missing;
    try std.testing.expectEqual(Completion.unavailable, completion(&before, &after, result));
}
