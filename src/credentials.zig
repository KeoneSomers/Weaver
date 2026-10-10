const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");
const target = "Weaver/github.com";
const Cred = extern struct {
    flags: u32 = 0,
    kind: u32 = 1,
    target: [*:0]const u8 = target,
    comment: ?[*:0]const u8 = null,
    written: [2]u32 = .{ 0, 0 },
    size: u32 = 0,
    blob: ?[*]const u8 = null,
    persist: u32 = 2,
    attribute_count: u32 = 0,
    attributes: ?*anyopaque = null,
    alias: ?[*:0]const u8 = null,
    username: ?[*:0]const u8 = "github",
};
extern "advapi32" fn CredWriteA(*const Cred, u32) callconv(.winapi) c_int;
extern "advapi32" fn CredReadA([*:0]const u8, u32, u32, **Cred) callconv(.winapi) c_int;
extern "advapi32" fn CredDeleteA([*:0]const u8, u32, u32) callconv(.winapi) c_int;
extern "advapi32" fn CredFree(*anyopaque) callconv(.winapi) void;
extern "Security" fn SecKeychainAddGenericPassword(?*anyopaque, u32, [*]const u8, u32, [*]const u8, u32, [*]const u8, ?*?*anyopaque) i32;
extern "Security" fn SecKeychainFindGenericPassword(?*anyopaque, u32, [*]const u8, u32, [*]const u8, ?*u32, ?*?[*]u8, ?*?*anyopaque) i32;
extern "Security" fn SecKeychainItemModifyAttributesAndData(*anyopaque, ?*anyopaque, u32, [*]const u8) i32;
extern "Security" fn SecKeychainItemDelete(*anyopaque) i32;
extern "Security" fn SecKeychainItemFreeContent(?*anyopaque, ?[*]u8) i32;
extern "c" fn CFRelease(*anyopaque) void;
pub fn put(io: std.Io, a: std.mem.Allocator, token: []const u8) !void {
    if (token.len == 0 or token.len > 4096 or std.mem.indexOfAny(u8, token, "\n\r\x00") != null) return error.InvalidToken;
    if (builtin.os.tag == .windows) {
        if (CredWriteA(&.{ .size = @intCast(token.len), .blob = token.ptr }, 0) == 0) return error.CredentialStoreUnavailable;
    } else if (builtin.os.tag == .macos) {
        var item: ?*anyopaque = null;
        if (SecKeychainFindGenericPassword(null, target.len, target, 6, "github", null, null, &item) == 0) {
            defer CFRelease(item.?);
            if (SecKeychainItemModifyAttributesAndData(item.?, null, @intCast(token.len), token.ptr) != 0) return error.CredentialStoreUnavailable;
        } else if (SecKeychainAddGenericPassword(null, target.len, target, 6, "github", @intCast(token.len), token.ptr, null) != 0) return error.CredentialStoreUnavailable;
    } else {
        const result = try process.run(io, a, &.{ "secret-tool", "store", "--label=Weaver GitHub", "service", "Weaver", "host", "github.com" }, null, token);
        defer result.deinit(a);
        if (!result.ok) return error.CredentialStoreUnavailable;
    }
}
pub fn get(io: std.Io, a: std.mem.Allocator) !?[]u8 {
    if (builtin.os.tag == .windows) {
        var cred: *Cred = undefined;
        if (CredReadA(target, 1, 0, &cred) == 0) return null;
        defer CredFree(cred);
        return try a.dupe(u8, if (cred.blob) |b| b[0..cred.size] else "");
    } else if (builtin.os.tag == .macos) {
        var length: u32 = 0;
        var data: ?[*]u8 = null;
        if (SecKeychainFindGenericPassword(null, target.len, target, 6, "github", &length, &data, null) != 0) return null;
        defer _ = SecKeychainItemFreeContent(null, data);
        return try a.dupe(u8, if (data) |d| d[0..length] else "");
    } else {
        const result = try process.run(io, a, &.{ "secret-tool", "lookup", "service", "Weaver", "host", "github.com" }, null, null);
        defer result.deinit(a);
        if (!result.ok) return null;
        return try a.dupe(u8, std.mem.trim(u8, result.stdout, "\r\n"));
    }
}
pub fn remove(io: std.Io, a: std.mem.Allocator) !void {
    if (builtin.os.tag == .windows) {
        _ = CredDeleteA(target, 1, 0);
    } else if (builtin.os.tag == .macos) {
        var item: ?*anyopaque = null;
        if (SecKeychainFindGenericPassword(null, target.len, target, 6, "github", null, null, &item) == 0) {
            defer CFRelease(item.?);
            if (SecKeychainItemDelete(item.?) != 0) return error.CredentialStoreUnavailable;
        }
    } else {
        const r = try process.run(io, a, &.{ "secret-tool", "clear", "service", "Weaver", "host", "github.com" }, null, null);
        defer r.deinit(a);
        if (!r.ok) return error.CredentialStoreUnavailable;
    }
}
pub fn clear(a: std.mem.Allocator, token: []u8) void {
    @memset(token, 0);
    a.free(token);
}
pub fn isGitHubCredential(input: []const u8) bool {
    var host = false;
    var protocol = false;
    var iter = std.mem.splitScalar(u8, input, '\n');
    while (iter.next()) |line| {
        const field = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, field, "host=")) host = std.mem.eql(u8, field, "host=github.com");
        if (std.mem.startsWith(u8, field, "protocol=")) protocol = std.mem.eql(u8, field, "protocol=https");
    }
    return host and protocol;
}
test "GitHub credential is never returned to another host" {
    try std.testing.expect(isGitHubCredential("protocol=https\nhost=github.com\n"));
    try std.testing.expect(!isGitHubCredential("protocol=https\nhost=github.com.evil.test\n"));
    try std.testing.expect(!isGitHubCredential("protocol=http\nhost=github.com\n"));
}
