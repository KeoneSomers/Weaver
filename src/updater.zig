const std = @import("std");
const builtin = @import("builtin");
const github = @import("github.zig");
const process = @import("process.zig");
pub const Asset = struct { platform: []const u8, url: []const u8, sha256: []const u8, filename: []const u8 };
pub const Manifest = struct { version: []const u8, notes: []const u8, assets: []Asset };
pub const Envelope = struct { payload: []const u8, signature: []const u8 };
pub fn verify(a: std.mem.Allocator, bytes: []const u8, public_key: []const u8, current: []const u8) !Manifest {
    if (public_key.len != 64) return error.UpdatesNotConfigured;
    const envelope = try std.json.parseFromSlice(Envelope, a, bytes, .{ .allocate = .alloc_always });
    if (envelope.value.signature.len != 128) return error.InvalidUpdateSignature;
    var key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, public_key);
    var sig: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sig, envelope.value.signature);
    const ed = std.crypto.sign.Ed25519;
    try ed.Signature.fromBytes(sig).verify(envelope.value.payload, try ed.PublicKey.fromBytes(key));
    const parsed = try std.json.parseFromSlice(Manifest, a, envelope.value.payload, .{ .allocate = .alloc_always });
    const incoming = try std.SemanticVersion.parse(parsed.value.version);
    const installed = try std.SemanticVersion.parse(current);
    if (incoming.order(installed) != .gt or incoming.pre != null) return error.NoNewUpdate;
    for (parsed.value.assets) |asset| {
        if (asset.sha256.len != 64 or !std.mem.startsWith(u8, asset.url, "https://github.com/") or
            asset.filename.len == 0 or std.mem.eql(u8, asset.filename, ".") or std.mem.eql(u8, asset.filename, "..") or
            !std.mem.eql(u8, asset.filename, std.fs.path.basename(asset.filename)) or std.mem.indexOfAny(u8, asset.filename, "\\/:\x00") != null) return error.InvalidUpdateAsset;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, asset.sha256) catch return error.InvalidUpdateAsset;
    }
    return parsed.value;
}
pub fn platform() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows-x86_64",
        .macos => if (builtin.cpu.arch == .aarch64) "macos-aarch64" else "macos-x86_64",
        else => "linux-x86_64",
    };
}
pub fn check(io: std.Io, a: std.mem.Allocator, repo: []const u8, key: []const u8, current: []const u8) !Manifest {
    if (!validRepo(repo) or key.len != 64) return error.UpdatesNotConfigured;
    const url = try std.fmt.allocPrint(a, "https://github.com/{s}/releases/latest/download/weaver-update.json", .{repo});
    defer a.free(url);
    const r = try process.run(io, a, &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--max-redirs", "5", "--max-time", "45", "--proto", "=https", "--proto-redir", "=https", url }, null, null);
    defer r.deinit(a);
    if (!r.ok) return error.UpdateCheckFailed;
    return verify(a, r.stdout, key, current);
}
pub fn download(io: std.Io, a: std.mem.Allocator, asset: Asset, directory: []const u8) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const path = try std.fs.path.join(a, &.{ directory, asset.filename });
    const temporary = try std.fmt.allocPrint(a, "{s}.download", .{path});
    defer a.free(temporary);
    const r = try process.run(io, a, &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--max-redirs", "5", "--max-time", "600", "--proto", "=https", "--proto-redir", "=https", "--output", temporary, asset.url }, null, null);
    defer r.deinit(a);
    if (!r.ok) return error.UpdateDownloadFailed;
    const file = try std.Io.Dir.cwd().openFile(io, temporary, .{});
    defer file.close(io);
    var reader_buffer: [65536]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [65536]u8 = undefined;
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    const digest = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    if (!std.mem.eql(u8, &digest, asset.sha256)) {
        std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        return error.UpdateHashMismatch;
    }
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
    return path;
}
pub fn validRepo(repo: []const u8) bool {
    var parts = std.mem.splitScalar(u8, repo, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    var slash: usize = 0;
    for (repo) |c| {
        if (c == '/') {
            slash += 1;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return slash == 1 and repo.len > 2 and repo[0] != '/' and repo[repo.len - 1] != '/';
}
test "update repositories reject traversal and non HTTPS providers" {
    try std.testing.expect(!validRepo("https://evil.test/a"));
    try std.testing.expect(!validRepo("a/b/c"));
    try std.testing.expect(validRepo("owner/weaver"));
}
test "signed updates reject tampering, wrong keys, downgrades and prereleases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ed = std.crypto.sign.Ed25519;
    const pair = try ed.KeyPair.generateDeterministic(@splat(42));
    const wrong_pair = try ed.KeyPair.generateDeterministic(@splat(43));
    const public = std.fmt.bytesToHex(pair.public_key.toBytes(), .lower);
    const wrong = std.fmt.bytesToHex(wrong_pair.public_key.toBytes(), .lower);
    const payload = "{\"version\":\"1.2.0\",\"notes\":\"test\",\"assets\":[]}";
    const signature = std.fmt.bytesToHex((try pair.sign(payload, null)).toBytes(), .lower);
    const bytes = try std.json.Stringify.valueAlloc(a, Envelope{ .payload = payload, .signature = &signature }, .{});
    try std.testing.expectEqualStrings("1.2.0", (try verify(a, bytes, &public, "1.0.0")).version);
    try std.testing.expectError(error.NoNewUpdate, verify(a, bytes, &public, "2.0.0"));
    if (verify(a, bytes, &wrong, "1.0.0")) |_| return error.InvalidSignatureAccepted else |_| {}
    const changed = try std.json.Stringify.valueAlloc(a, Envelope{ .payload = "{\"version\":\"9.0.0\",\"notes\":\"test\",\"assets\":[]}", .signature = &signature }, .{});
    if (verify(a, changed, &public, "1.0.0")) |_| return error.TamperedUpdateAccepted else |_| {}
}
