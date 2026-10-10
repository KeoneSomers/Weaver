//! Turns a failed remote operation into a next step the UI can offer.
const std = @import("std");
const model = @import("model.zig");

pub const Advice = enum {
    connect_remote,
    publish,
    pull_first,
    diverged,
    sign_in,
    unreachable_remote,
    nothing_to_push,
    unknown,

    pub fn summary(self: Advice) []const u8 {
        return switch (self) {
            .connect_remote => "This repository has no remote yet. Connect one to choose where your commits go.",
            .publish => "This branch isn't linked to a branch on the remote yet. Publish it to create that link.",
            .pull_first => "The remote has commits that aren't on this computer yet. Pull them, then push again.",
            .diverged => "Your branch and the remote have both changed, so a fast-forward pull isn't possible. Merge or rebase from Repository tools.",
            .sign_in => "The remote didn't accept your credentials. Sign in or check your access, then try again.",
            .unreachable_remote => "Weaver couldn't reach the remote. Check its URL and your connection.",
            .nothing_to_push => "There are no commits on this branch yet. Commit your changes first, then push.",
            .unknown => "Git reported a problem. The details are below.",
        };
    }
};

/// Operations whose failure opens a dialog instead of only a status-bar line.
pub fn guided(operation: model.Operation) bool {
    return switch (operation) {
        .push, .publish, .pull, .fetch, .add_remote, .clone => true,
        else => false,
    };
}

/// Classifies Git's own output; `has_remotes` separates a missing remote from a wrong one.
pub fn advise(output: []const u8, has_remotes: bool) Advice {
    if (containsAny(output, &.{ "No configured push destination", "No remote repository specified" })) return .connect_remote;
    if (containsAny(output, &.{ "has no upstream branch", "no tracking information" })) return if (has_remotes) .publish else .connect_remote;
    if (containsAny(output, &.{ "[rejected]", "non-fast-forward", "fetch first" })) return .pull_first;
    if (containsAny(output, &.{ "Not possible to fast-forward", "Diverging branches" })) return .diverged;
    if (containsAny(output, &.{ "Authentication failed", "could not read Username", "could not read Password", "Permission denied", "terminal prompts disabled", "returned error: 403", "returned error: 401" })) return .sign_in;
    if (containsAny(output, &.{"does not match any"})) return .nothing_to_push;
    if (containsAny(output, &.{ "does not appear to be a git repository", "Could not read from remote repository" })) return if (has_remotes) .unreachable_remote else .connect_remote;
    if (containsAny(output, &.{ "not found", "Could not resolve host", "unable to access", "Connection refused", "Connection timed out" })) return .unreachable_remote;
    return .unknown;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.ascii.findIgnoreCase(text, needle) != null) return true;
    return false;
}

/// "origin" when present, otherwise the first configured remote.
pub fn defaultRemote(remotes: []const []const u8) ?[]const u8 {
    for (remotes) |remote| if (std.mem.eql(u8, remote, "origin")) return remote;
    return if (remotes.len > 0) remotes[0] else null;
}

test "failed remote operations map to the next step" {
    try std.testing.expectEqual(Advice.connect_remote, advise("fatal: No configured push destination.\nEither specify the URL from the command-line", false));
    try std.testing.expectEqual(Advice.connect_remote, advise("fatal: 'origin' does not appear to be a git repository", false));
    try std.testing.expectEqual(Advice.unreachable_remote, advise("fatal: 'C:/missing.git' does not appear to be a git repository", true));
    try std.testing.expectEqual(Advice.publish, advise("fatal: The current branch main has no upstream branch.", true));
    try std.testing.expectEqual(Advice.publish, advise("There is no tracking information for the current branch.", true));
    try std.testing.expectEqual(Advice.pull_first, advise(" ! [rejected]        main -> main (fetch first)", true));
    try std.testing.expectEqual(Advice.diverged, advise("fatal: Not possible to fast-forward, aborting.", true));
    try std.testing.expectEqual(Advice.sign_in, advise("remote: Permission to owner/repo.git denied.\nfatal: unable to access 'https://example.invalid/': The requested URL returned error: 403", true));
    try std.testing.expectEqual(Advice.sign_in, advise("git@example.invalid: Permission denied (publickey).\nfatal: Could not read from remote repository.", true));
    try std.testing.expectEqual(Advice.unreachable_remote, advise("remote: Repository not found.", true));
    try std.testing.expectEqual(Advice.nothing_to_push, advise("error: src refspec main does not match any", true));
    try std.testing.expectEqual(Advice.unknown, advise("InvalidRemote: Check the operation and repository settings.", true));
}

test "the default remote prefers origin" {
    try std.testing.expectEqual(@as(?[]const u8, null), defaultRemote(&.{}));
    try std.testing.expectEqualStrings("origin", defaultRemote(&.{ "backup", "origin" }).?);
    try std.testing.expectEqualStrings("backup", defaultRemote(&.{ "backup", "mirror" }).?);
}
