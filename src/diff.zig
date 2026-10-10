const std = @import("std");
pub const Kind = enum { context, addition, deletion, hunk, meta };
pub const Line = struct { text: []const u8, kind: Kind, old: ?usize = null, new: ?usize = null };
pub const Metadata = struct {
    old_oid: []const u8 = "",
    new_oid: []const u8 = "",
    old_mode: []const u8 = "",
    new_mode: []const u8 = "",
    similarity: []const u8 = "",
    dissimilarity: []const u8 = "",
};
/// File headers belong in the UI; keep the original patch intact for copying/staging.
pub fn metadata(patch: []const u8) Metadata {
    var result: Metadata = .{};
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |text| {
        if (std.mem.startsWith(u8, text, "@@ ")) break;
        if (std.mem.startsWith(u8, text, "index ")) {
            var fields = std.mem.tokenizeScalar(u8, text[6..], ' ');
            const ids = fields.next() orelse continue;
            if (std.mem.indexOf(u8, ids, "..")) |separator| {
                result.old_oid = ids[0..separator];
                result.new_oid = ids[separator + 2 ..];
            }
            if (fields.next()) |mode| {
                result.old_mode = mode;
                result.new_mode = mode;
            }
        } else if (std.mem.startsWith(u8, text, "old mode ")) {
            result.old_mode = text[9..];
        } else if (std.mem.startsWith(u8, text, "new mode ")) {
            result.new_mode = text[9..];
        } else if (std.mem.startsWith(u8, text, "new file mode ")) {
            result.new_mode = text[14..];
        } else if (std.mem.startsWith(u8, text, "deleted file mode ")) {
            result.old_mode = text[18..];
        } else if (std.mem.startsWith(u8, text, "similarity index ")) {
            result.similarity = text[17..];
        } else if (std.mem.startsWith(u8, text, "dissimilarity index ")) {
            result.dissimilarity = text[20..];
        }
    }
    return result;
}
pub fn contentLines(lines: []const Line) []const Line {
    for (lines, 0..) |line, i| if (line.kind == .hunk) return lines[i..];
    return &.{};
}
pub fn hunkLabel(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    _ = fields.next();
    const old = try rangeLabel(a, fields.next() orelse "-0,0");
    defer a.free(old);
    const new = try rangeLabel(a, fields.next() orelse "+0,0");
    defer a.free(new);
    const end = std.mem.indexOfPos(u8, text, 3, "@@");
    const context = if (end) |i| std.mem.trim(u8, text[i + 2 ..], " \r") else "";
    return if (context.len > 0) std.fmt.allocPrint(a, "Old lines {s} · New lines {s} · {s}", .{ old, new, context }) else std.fmt.allocPrint(a, "Old lines {s} · New lines {s}", .{ old, new });
}
fn rangeLabel(a: std.mem.Allocator, field: []const u8) ![]u8 {
    if (field.len < 2) return a.dupe(u8, "none");
    var numbers = std.mem.splitScalar(u8, field[1..], ',');
    const start = std.fmt.parseInt(usize, numbers.next() orelse "0", 10) catch 0;
    const count = if (numbers.next()) |value| std.fmt.parseInt(usize, value, 10) catch 0 else 1;
    if (count == 0) return a.dupe(u8, "none");
    return if (count == 1) std.fmt.allocPrint(a, "{d}", .{start}) else std.fmt.allocPrint(a, "{d}–{d}", .{ start, start +| (count - 1) });
}
pub fn newFilePatch(a: std.mem.Allocator, path: []const u8, bytes: []const u8) ![]u8 {
    const old_path = try std.fmt.allocPrint(a, "a/{s}", .{path});
    defer a.free(old_path);
    const new_path = try std.fmt.allocPrint(a, "b/{s}", .{path});
    defer a.free(new_path);
    const old_quoted = try std.json.Stringify.valueAlloc(a, old_path, .{});
    defer a.free(old_quoted);
    const new_quoted = try std.json.Stringify.valueAlloc(a, new_path, .{});
    defer a.free(new_quoted);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try output.writer.print("diff --git {s} {s}\nnew file mode 100644\n--- /dev/null\n+++ {s}\n", .{ old_quoted, new_quoted, new_quoted });
    if (bytes.len > 0) {
        const has_newline = bytes[bytes.len - 1] == '\n';
        const count = std.mem.count(u8, bytes, "\n") + @as(usize, @intFromBool(!has_newline));
        try output.writer.print("@@ -0,0 +1,{d} @@\n", .{count});
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            try output.writer.print("+{s}\n", .{line});
        }
        if (!has_newline) try output.writer.writeAll("\\ No newline at end of file\n");
    }
    return output.toOwnedSlice();
}
pub fn parse(allocator: std.mem.Allocator, patch: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);
    var iter = std.mem.splitScalar(u8, patch, '\n');
    var old: usize = 0;
    var new: usize = 0;
    var in_hunk = false;
    while (iter.next()) |text| {
        if (text.len == 0 and iter.peek() == null) break;
        var line = Line{ .text = text, .kind = .meta };
        if (std.mem.startsWith(u8, text, "@@ ")) {
            var fields = std.mem.tokenizeScalar(u8, text, ' ');
            _ = fields.next();
            old = parseStart(fields.next() orelse "-0");
            new = parseStart(fields.next() orelse "+0");
            line.kind = .hunk;
            in_hunk = true;
        } else if (in_hunk and text.len > 0) switch (text[0]) {
            '+' => {
                line.kind = .addition;
                line.new = new;
                new += 1;
            },
            '-' => {
                line.kind = .deletion;
                line.old = old;
                old += 1;
            },
            ' ' => {
                line.kind = .context;
                line.old = old;
                line.new = new;
                old += 1;
                new += 1;
            },
            else => {},
        };
        try lines.append(allocator, line);
    }
    return lines.toOwnedSlice(allocator);
}
fn parseStart(field: []const u8) usize {
    if (field.len < 2) return 0;
    var numbers = std.mem.splitScalar(u8, field[1..], ',');
    return std.fmt.parseInt(usize, numbers.next() orelse "0", 10) catch 0;
}
pub fn hunk(a: std.mem.Allocator, patch: []const u8, ordinal: usize) ![]const u8 {
    var cursor: usize = 0;
    var first: ?usize = null;
    var start: ?usize = null;
    var end = patch.len;
    var count: usize = 0;
    while (cursor < patch.len) {
        const newline = std.mem.indexOfScalarPos(u8, patch, cursor, '\n') orelse patch.len;
        if (std.mem.startsWith(u8, patch[cursor..newline], "@@ ")) {
            if (first == null) first = cursor;
            if (count == ordinal) start = cursor else if (start != null) {
                end = cursor;
                break;
            }
            count += 1;
        }
        cursor = if (newline < patch.len) newline + 1 else patch.len;
    }
    return std.fmt.allocPrint(a, "{s}{s}", .{ patch[0 .. first orelse return error.NoHunk], patch[start orelse return error.NoHunk .. end] });
}
pub const Pair = struct { left: ?Line, right: ?Line };
pub fn pairs(a: std.mem.Allocator, lines: []const Line) ![]Pair {
    var output: std.ArrayList(Pair) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].kind == .deletion or lines[i].kind == .addition) {
            const start = i;
            while (i < lines.len and lines[i].kind == .deletion) : (i += 1) {}
            const added = i;
            while (i < lines.len and lines[i].kind == .addition) : (i += 1) {}
            const count = @max(added - start, i - added);
            for (0..count) |j| try output.append(a, .{ .left = if (j < added - start) lines[start + j] else null, .right = if (j < i - added) lines[added + j] else null });
        } else {
            try output.append(a, .{ .left = lines[i], .right = lines[i] });
            i += 1;
        }
    }
    return output.toOwnedSlice(a);
}
test "hunk extraction preserves file headers and excludes other hunks" {
    const a = std.testing.allocator;
    const patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n@@ -10 +10 @@\n-old2\n+new2\n";
    const selected = try hunk(a, patch, 1);
    defer a.free(selected);
    try std.testing.expect(std.mem.startsWith(u8, selected, "diff --git a/x b/x\n"));
    try std.testing.expect(std.mem.indexOf(u8, selected, "+new2") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "@@ -1 +1") == null);
}
test "UI metadata filtering preserves hunk ordinals and missing newline notes" {
    const a = std.testing.allocator;
    const patch = "diff --git a/x b/x\nold mode 100644\nnew mode 100755\nindex abc1234..def5678\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file\n@@ -10,2 +20,3 @@ fn example\n same\n-old2\n+new2\n+extra\n";
    const lines = try parse(a, patch);
    defer a.free(lines);
    const details = metadata(patch);
    try std.testing.expectEqualStrings("abc1234", details.old_oid);
    try std.testing.expectEqualStrings("def5678", details.new_oid);
    try std.testing.expectEqualStrings("100644", details.old_mode);
    try std.testing.expectEqualStrings("100755", details.new_mode);
    const visible = contentLines(lines);
    try std.testing.expectEqual(Kind.hunk, visible[0].kind);
    try std.testing.expectEqualStrings("\\ No newline at end of file", visible[3].text);
    const split = try pairs(a, visible);
    defer a.free(split);
    try std.testing.expectEqual(Kind.hunk, split[0].left.?.kind);
    const selected = try hunk(a, patch, 1);
    defer a.free(selected);
    try std.testing.expect(std.mem.startsWith(u8, selected, "diff --git"));
    try std.testing.expect(std.mem.indexOf(u8, selected, "+extra") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "+new\n") == null);
    const title = try hunkLabel(a, visible[4].text);
    defer a.free(title);
    try std.testing.expectEqualStrings("Old lines 10–11 · New lines 20–22 · fn example", title);
}
test "metadata-only changes have no code rows and keep file details" {
    const a = std.testing.allocator;
    const patch = "diff --git a/old b/new\nsimilarity index 100%\nrename from old\nrename to new\nold mode 100644\nnew mode 100755\n";
    const lines = try parse(a, patch);
    defer a.free(lines);
    try std.testing.expectEqual(@as(usize, 0), contentLines(lines).len);
    const details = metadata(patch);
    try std.testing.expectEqualStrings("100%", details.similarity);
    try std.testing.expectEqualStrings("100644", details.old_mode);
    try std.testing.expectEqualStrings("100755", details.new_mode);
    const title = try hunkLabel(a, "@@ -0,0 +1 @@");
    defer a.free(title);
    try std.testing.expectEqualStrings("Old lines none · New lines 1", title);
}
pub const Token = struct { text: []const u8, kind: enum { plain, keyword, string, number, comment } };
/// Git metadata and child-process logs can contain bytes outside UTF-8.
pub fn safeText(a: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(text)) return a.dupe(u8, text);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (length > 0 and i + length <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..length])) {
            try output.appendSlice(a, text[i..][0..length]);
            i += length;
        } else {
            try output.appendSlice(a, "\u{fffd}");
            i += 1;
        }
    }
    return output.toOwnedSlice(a);
}

test "invalid metadata is displayed safely without damaging valid Unicode" {
    const a = std.testing.allocator;
    const text = try safeText(a, "café \xff end");
    defer a.free(text);
    try std.testing.expectEqualStrings("café \u{fffd} end", text);
}
/// Stateless per-line lexer for common source languages. Never executes source.
pub fn tokens(a: std.mem.Allocator, text: []const u8) ![]Token {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var result: std.ArrayList(Token) = .empty;
    errdefer result.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        var kind: @FieldType(Token, "kind") = .plain;
        if ((text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') or text[i] == '#') {
            i = text.len;
            kind = .comment;
        } else if (text[i] == '"' or text[i] == '\'') {
            const quote = text[i];
            i += 1;
            while (i < text.len) {
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 2;
                    continue;
                }
                if (text[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            kind = .string;
        } else if (std.ascii.isDigit(text[i])) {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '.')) : (i += 1) {}
            kind = .number;
        } else if (std.ascii.isAlphabetic(text[i]) or text[i] == '_') {
            i += 1;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
            const word = text[start..i];
            inline for (.{ "pub", "const", "var", "fn", "struct", "enum", "return", "try", "catch", "if", "else", "for", "while", "import", "export", "function", "class", "let", "async", "await", "def", "true", "false", "null", "void", "int", "using", "namespace", "public", "private" }) |keyword| {
                if (std.mem.eql(u8, word, keyword)) kind = .keyword;
            }
        } else {
            i += try std.unicode.utf8ByteSequenceLength(text[i]);
        }
        try result.append(a, .{ .text = text[start..i], .kind = kind });
    }
    return result.toOwnedSlice(a);
}

test "syntax tokens preserve complete Unicode codepoints" {
    const a = std.testing.allocator;
    const source = "const café = 中文 + 🎉;";
    const parts = try tokens(a, source);
    defer a.free(parts);
    var length: usize = 0;
    for (parts) |part| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(part.text));
        length += part.text.len;
    }
    try std.testing.expectEqual(source.len, length);
    try std.testing.expectError(error.InvalidUtf8, tokens(a, "\xff"));
}

test "diff hunk numbers do not count metadata or missing newline markers" {
    const a = std.testing.allocator;
    const lines = try parse(a, "--- a/x\n+++ b/x\n@@ -10,2 +20,2 @@\n old\n-gone\n+new\n\\ No newline at end of file\n");
    defer a.free(lines);
    try std.testing.expectEqual(@as(usize, 7), lines.len);
    try std.testing.expectEqual(@as(?usize, 10), lines[3].old);
    try std.testing.expectEqual(@as(?usize, 21), lines[5].new);
    try std.testing.expectEqual(Kind.meta, lines[6].kind);
}
