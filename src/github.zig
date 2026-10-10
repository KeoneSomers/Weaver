const std = @import("std");
const process = @import("process.zig");
const credentials = @import("credentials.zig");
pub const Device = struct { device_code: []const u8, user_code: []const u8, verification_uri: []const u8, expires_in: u32, interval: u32 };
pub const Repository = struct { full_name: []const u8, clone_url: []const u8, ssh_url: []const u8, private: bool, description: ?[]const u8 = null };
pub fn repositories(io: std.Io, a: std.mem.Allocator) ![]Repository {
    const token = try credentials.get(io, a) orelse return error.SignInToGitHub;
    defer credentials.clear(a, token);
    var all: std.ArrayList(Repository) = .empty;
    // GitHub REST pagination: bounded to 1,000 accessible repositories.
    for (1..11) |page| {
        const url = try std.fmt.allocPrint(a, "https://api.github.com/user/repos?per_page=100&sort=updated&page={d}", .{page});
        const bytes = try request(io, a, url, null, token);
        const repos = (try std.json.parseFromSlice([]Repository, a, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
        try all.appendSlice(a, repos);
        if (repos.len < 100) break;
    }
    return all.toOwnedSlice(a);
}
pub fn request(io: std.Io, a: std.mem.Allocator, url: []const u8, body: ?[]const u8, token: ?[]const u8) ![]u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return error.InsecureURL;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.appendSlice(a, &.{ "curl", "--silent", "--show-error", "--fail-with-body", "--max-time", "45", "--proto", "=https", "--tlsv1.2", "--header", "Accept: application/json", "--header", "User-Agent: Weaver", "--url", url });
    if (body != null and token == null) try args.appendSlice(a, &.{ "--data-binary", "@-" });
    if (token != null) try args.appendSlice(a, &.{ "--config", "-" });
    const config = if (token) |t| try authorizationConfig(a, t, body) else null;
    defer if (config) |data| {
        @memset(data, 0);
        a.free(data);
    };
    const r = try process.run(io, a, args.items, null, config orelse body);
    defer a.free(r.stderr);
    errdefer a.free(r.stdout);
    if (!r.ok) {
        @memset(r.stdout, 0);
        return error.HTTPRequestFailed;
    }
    return r.stdout;
}
fn authorizationConfig(a: std.mem.Allocator, token: []const u8, body: ?[]const u8) ![]u8 {
    if (token.len == 0) return error.InvalidToken;
    for (token) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidToken;
    if (body) |data| {
        const quoted = try std.json.Stringify.valueAlloc(a, data, .{});
        defer a.free(quoted);
        return std.fmt.allocPrint(a, "header = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\ndata-binary = {s}\n", .{ token, quoted });
    }
    return std.fmt.allocPrint(a, "header = \"Authorization: Bearer {s}\"\n", .{token});
}

test "HTTP authorization rejects config injection and preserves authenticated JSON bodies" {
    const a = std.testing.allocator;
    const config = try authorizationConfig(a, "gho_example", "{\"name\":\"repository\"}");
    defer a.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "data-binary = \"{\\\"name\\\":\\\"repository\\\"}\"") != null);
    try std.testing.expectError(error.InvalidToken, authorizationConfig(a, "bad\"\nurl=evil", null));
}
/// Confirm the token's account, then keep it in the OS credential store.
fn remember(io: std.Io, a: std.mem.Allocator, token: []const u8) ![]const u8 {
    const user = try request(io, a, "https://api.github.com/user", null, token);
    defer a.free(user);
    const profile = try std.json.parseFromSlice(std.json.Value, a, user, .{});
    defer profile.deinit();
    const login = profile.value.object.get("login") orelse return error.InvalidGitHubIdentity;
    if (login != .string) return error.InvalidGitHubIdentity;
    const name = try a.dupe(u8, login.string);
    errdefer a.free(name);
    try credentials.put(io, a, token);
    return name;
}
/// Sign in through the Git credential helper configured for github.com, so no
/// OAuth app is needed. Returns the account login.
pub fn signIn(io: std.Io, a: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]const u8 {
    const filled = try process.credentialFill(io, a, environment);
    defer {
        @memset(filled.stdout, 0);
        filled.deinit(a);
    }
    if (!filled.ok) return error.GitCredentialManagerSignInFailed;
    return remember(io, a, credentialPassword(filled.stdout) orelse return error.GitCredentialManagerSignInFailed);
}
fn credentialPassword(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const field = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, field, "password=") and field.len > "password=".len) return field["password=".len..];
    }
    return null;
}
test "credential helper output yields only the password field" {
    try std.testing.expectEqualStrings("gho_example", credentialPassword("protocol=https\r\nhost=github.com\r\nusername=octocat\r\npassword=gho_example\r\n").?);
    try std.testing.expect(credentialPassword("protocol=https\nhost=github.com\nusername=password=x\n") == null);
    try std.testing.expect(credentialPassword("password=\n") == null);
}
pub fn begin(io: std.Io, a: std.mem.Allocator, client: []const u8) !Device {
    if (client.len == 0 or std.mem.indexOfAny(u8, client, "&\n\r") != null) return error.ConfigureOAuthClientID;
    const body = try std.fmt.allocPrint(a, "client_id={s}&scope=repo%20read:user%20workflow", .{client});
    defer a.free(body);
    const data = try request(io, a, "https://github.com/login/device/code", body, null);
    defer a.free(data);
    const parsed = try std.json.parseFromSlice(Device, a, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    // Caller uses an arena so the device response can own its strings together.
    return parsed.value;
}
pub const Poll = union(enum) { pending, slow_down, denied, expired, complete: []const u8 };
pub fn poll(io: std.Io, a: std.mem.Allocator, client: []const u8, device: []const u8) !Poll {
    const body = try std.fmt.allocPrint(a, "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code", .{ client, device });
    defer a.free(body);
    const data = try request(io, a, "https://github.com/login/oauth/access_token", body, null);
    defer {
        @memset(data, 0);
        a.free(data);
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, data, .{});
    defer parsed.deinit();
    if (parsed.value.object.get("access_token")) |token| return .{ .complete = try remember(io, a, token.string) };
    const name = (parsed.value.object.get("error") orelse return error.InvalidOAuthResponse).string;
    if (std.mem.eql(u8, name, "authorization_pending")) return .pending;
    if (std.mem.eql(u8, name, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, name, "access_denied")) return .denied;
    if (std.mem.eql(u8, name, "expired_token")) return .expired;
    return error.GitHubAuthorizationFailed;
}
