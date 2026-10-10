const std = @import("std");
// Devicon v2.17.0, MIT. Codepoints from the pinned devicon.min.css.
// Generic glyphs use KnotsUI's bundled Material icon fallback.
pub const Icon = struct { glyph: []const u8, label: []const u8, color: []const u8, font: ?[]const u8 = "devicon" };

// Lucide Static v0.468.0, ISC. Codepoints from its pinned font/lucide.css.
pub const Toolbar = enum {
    refresh,
    fetch,
    pull,
    push,

    pub fn glyph(self: Toolbar) []const u8 {
        return switch (self) {
            .refresh => "\u{e148}", // refresh-cw
            .fetch => "\u{e08d}", // cloud-download
            .pull => "\u{e459}", // arrow-down-to-line
            .push => "\u{e45e}", // arrow-up-from-line
        };
    }

    pub fn label(self: Toolbar) []const u8 {
        return switch (self) {
            .refresh => "Refresh",
            .fetch => "Fetch",
            .pull => "Pull",
            .push => "Push",
        };
    }
};

/// Leading glyphs for context-menu rows, from the same pinned Lucide font.
pub const Menu = enum {
    view,
    stage,
    unstage,
    copy,
    copy_full,
    edit,
    reveal,
    ignore_file,
    ignore_folder,
    ignore_extension,
    discard,
    open,
    refresh,
    open_remote,
    icon,
    rename,
    new_group,
    to_group,
    ungroup,
    move_up,
    move_down,
    move_top,
    move_bottom,
    remove,

    pub fn glyph(self: Menu) []const u8 {
        return switch (self) {
            .view => "\u{e319}", // file-diff
            .stage => "\u{e140}", // plus
            .unstage => "\u{e11f}", // minus
            .copy => "\u{e0a2}", // copy
            .copy_full => "\u{e224}", // clipboard-copy
            .edit => "\u{e175}", // square-pen
            .reveal => "\u{e246}", // folder-open
            .ignore_file => "\u{e0d1}", // file-x
            .ignore_folder => "\u{e341}", // folder-x
            .ignore_extension => "\u{e1ee}", // asterisk
            .discard => "\u{e2a0}", // undo-2
            .open => "\u{e40e}", // folder-git-2
            .refresh => "\u{e148}", // refresh-cw
            .open_remote => "\u{e0bd}", // external-link
            .icon => "\u{e1dc}", // palette
            .rename => "\u{e1f8}", // pencil
            .new_group => "\u{e0de}", // folder-plus
            .to_group => "\u{e337}", // folder-input
            .ungroup => "\u{e33a}", // folder-output
            .move_up => "\u{e04e}", // arrow-up
            .move_down => "\u{e046}", // arrow-down
            .move_top => "\u{e45f}", // arrow-up-to-line
            .move_bottom => "\u{e459}", // arrow-down-to-line
            .remove => "\u{e18d}", // trash-2
        };
    }
};

const zig = Icon{ .glyph = "\u{ecc3}", .label = "Zig", .color = "#E9B171" };
const git = Icon{ .glyph = "\u{ea2d}", .label = "Git", .color = "#DE967D" };
const docker = Icon{ .glyph = "\u{e9c3}", .label = "Docker", .color = "#7ABCE5" };
const npm = Icon{ .glyph = "\u{edaf}", .label = "npm", .color = "#DF9292" };

pub fn file(path: []const u8) Icon {
    const name = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(name, "build.zig.zon")) return zig;
    if (std.ascii.eqlIgnoreCase(name, "Dockerfile") or std.ascii.startsWithIgnoreCase(name, "Dockerfile.")) return docker;
    if (std.ascii.eqlIgnoreCase(name, "CMakeLists.txt")) return .{ .glyph = "\u{e97a}", .label = "CMake", .color = "#88B8C8" };
    inline for (.{ "package.json", "package-lock.json", ".npmrc" }) |filename| if (std.ascii.eqlIgnoreCase(name, filename)) return npm;
    inline for (.{ ".gitignore", ".gitattributes", ".gitmodules", ".gitkeep" }) |filename| if (std.ascii.eqlIgnoreCase(name, filename)) return git;

    const ext = std.fs.path.extension(name);
    inline for (.{
        .{ ".zig", zig },
        .{ ".ts", Icon{ .glyph = "\u{ec63}", .label = "TypeScript", .color = "#80B5E8" } },
        .{ ".tsx", Icon{ .glyph = "\u{ebbc}", .label = "React TypeScript", .color = "#80CEE0" } },
        .{ ".js", Icon{ .glyph = "\u{ea81}", .label = "JavaScript", .color = "#E6D47A" } },
        .{ ".mjs", Icon{ .glyph = "\u{ea81}", .label = "JavaScript", .color = "#E6D47A" } },
        .{ ".cjs", Icon{ .glyph = "\u{ea81}", .label = "JavaScript", .color = "#E6D47A" } },
        .{ ".jsx", Icon{ .glyph = "\u{ebbc}", .label = "React", .color = "#80CEE0" } },
        .{ ".py", Icon{ .glyph = "\u{eb9c}", .label = "Python", .color = "#91B8D8" } },
        .{ ".rs", Icon{ .glyph = "\u{ebe6}", .label = "Rust", .color = "#DEAB94" } },
        .{ ".cs", Icon{ .glyph = "\u{e9a0}", .label = "C#", .color = "#BA9EDD" } },
        .{ ".c", Icon{ .glyph = "\u{edae}", .label = "C", .color = "#87BFE0" } },
        .{ ".h", Icon{ .glyph = "\u{edae}", .label = "C header", .color = "#87BFE0" } },
        .{ ".cpp", Icon{ .glyph = "\u{e99a}", .label = "C++", .color = "#87BFE0" } },
        .{ ".hpp", Icon{ .glyph = "\u{e99a}", .label = "C++ header", .color = "#87BFE0" } },
        .{ ".json", Icon{ .glyph = "\u{ea94}", .label = "JSON", .color = "#C4BD93" } },
        .{ ".md", Icon{ .glyph = "\u{eadb}", .label = "Markdown", .color = "#9FBACF" } },
        .{ ".yml", Icon{ .glyph = "\u{ecb5}", .label = "YAML", .color = "#DCA3AB" } },
        .{ ".yaml", Icon{ .glyph = "\u{ecb5}", .label = "YAML", .color = "#DCA3AB" } },
        .{ ".css", Icon{ .glyph = "\u{e9a1}", .label = "CSS", .color = "#A5B7EC" } },
        .{ ".html", Icon{ .glyph = "\u{ea67}", .label = "HTML", .color = "#E5A58B" } },
        .{ ".go", Icon{ .glyph = "\u{ea3d}", .label = "Go", .color = "#80C7D5" } },
        .{ ".java", Icon{ .glyph = "\u{ea7f}", .label = "Java", .color = "#DDB17E" } },
        .{ ".rb", Icon{ .glyph = "\u{ebe3}", .label = "Ruby", .color = "#DC969C" } },
        .{ ".swift", Icon{ .glyph = "\u{ec34}", .label = "Swift", .color = "#E7A189" } },
        .{ ".kt", Icon{ .glyph = "\u{eab5}", .label = "Kotlin", .color = "#B6A0E8" } },
        .{ ".php", Icon{ .glyph = "\u{eb68}", .label = "PHP", .color = "#ADB5E2" } },
        .{ ".lua", Icon{ .glyph = "\u{ead3}", .label = "Lua", .color = "#99ACE0" } },
        .{ ".sh", Icon{ .glyph = "\u{ed55}", .label = "Shell", .color = "#A8C3AC" } },
        .{ ".vue", Icon{ .glyph = "\u{ec96}", .label = "Vue", .color = "#8CC8A8" } },
        .{ ".svelte", Icon{ .glyph = "\u{ec30}", .label = "Svelte", .color = "#E6A087" } },
        .{ ".gd", Icon{ .glyph = "\u{ea33}", .label = "GDScript", .color = "#8EB9DD" } },
        .{ ".tscn", Icon{ .glyph = "\u{ea33}", .label = "Godot scene", .color = "#8EB9DD" } },
        .{ ".tres", Icon{ .glyph = "\u{ea33}", .label = "Godot resource", .color = "#8EB9DD" } },
    }) |entry| if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];

    inline for (.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".svg" }) |extension| if (std.ascii.eqlIgnoreCase(ext, extension)) return .{ .glyph = "\u{e3f4}", .label = "Image", .color = "#B6A1DB", .font = null };
    inline for (.{ ".ttf", ".otf", ".woff", ".woff2" }) |extension| if (std.ascii.eqlIgnoreCase(ext, extension)) return .{ .glyph = "\u{e167}", .label = "Font", .color = "#ABB5C9", .font = null };
    inline for (.{ ".toml", ".ini", ".cfg", ".conf" }) |extension| if (std.ascii.eqlIgnoreCase(ext, extension)) return .{ .glyph = "\u{e8b8}", .label = "Configuration", .color = "#C5B398", .font = null };
    return .{ .glyph = "\u{e24d}", .label = "File", .color = "#9DA7B8", .font = null };
}

/// A named glyph from the bundled Lucide font, offered by the project icon picker.
pub const Glyph = struct {
    name: []const u8,
    bytes: [4]u8 = undefined,
    len: u3 = 0,

    pub fn text(self: *const Glyph) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Disclosure glyphs of a sidebar group, from the Lucide font.
pub const group_open = "\u{e071}"; // chevron-down
pub const group_closed = "\u{e073}"; // chevron-right

/// Shown for a project without a chosen icon, or whose icon the font no longer has.
pub const default_project = "folder";

/// Project icon tints. An empty color keeps the sidebar's text color.
pub const project_colors = [_]struct { name: []const u8, hex: []const u8 }{
    .{ .name = "Red", .hex = "#E5898B" },
    .{ .name = "Orange", .hex = "#E8A87C" },
    .{ .name = "Yellow", .hex = "#E6C76E" },
    .{ .name = "Green", .hex = "#8CC8A0" },
    .{ .name = "Teal", .hex = "#7CCFC4" },
    .{ .name = "Blue", .hex = "#80B5E8" },
    .{ .name = "Indigo", .hex = "#9AA5EC" },
    .{ .name = "Purple", .hex = "#B4A0FF" },
    .{ .name = "Pink", .hex = "#E59AC6" },
    .{ .name = "Gray", .hex = "#9DA7B8" },
};

fn readInt(comptime T: type, bytes: []const u8, offset: usize) !T {
    if (offset > bytes.len or bytes.len - offset < @sizeOf(T)) return error.InvalidFont;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}
fn fontTable(font: []const u8, tag: *const [4]u8) ![]const u8 {
    for (0..try readInt(u16, font, 4)) |i| {
        const record = 12 + i * 16;
        if (try readInt(u32, font, record) != std.mem.readInt(u32, tag, .big)) continue;
        const offset = try readInt(u32, font, record + 8);
        const length = try readInt(u32, font, record + 12);
        if (offset > font.len or length > font.len - offset) return error.InvalidFont;
        return font[offset..][0..length];
    }
    return error.InvalidFont;
}
/// Every named glyph of a TrueType icon font, sorted by name. Reading the
/// font's own `post` and `cmap` tables keeps the picker in step with the
/// bundled file. Names point into `font`.
pub fn glyphs(a: std.mem.Allocator, font: []const u8) ![]Glyph {
    const post = try fontTable(font, "post");
    if (try readInt(u32, post, 0) != 0x00020000) return error.InvalidFont;
    const count = try readInt(u16, post, 32);
    // Pascal strings, indexed after the 258 standard Macintosh glyph names.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var at: usize = 34 + @as(usize, count) * 2;
    while (at < post.len) {
        const len = post[at];
        if (post.len - at - 1 < len) return error.InvalidFont;
        try names.append(a, post[at + 1 ..][0..len]);
        at += 1 + @as(usize, len);
    }
    var out: std.ArrayList(Glyph) = .empty;
    errdefer out.deinit(a);
    const cmap = try fontTable(font, "cmap");
    for (0..try readInt(u16, cmap, 2)) |i| {
        const start_of = try readInt(u32, cmap, 8 + i * 8);
        if (start_of > cmap.len) return error.InvalidFont;
        const sub = cmap[start_of..];
        if (try readInt(u16, sub, 0) != 4) continue;
        const segments: usize = try readInt(u16, sub, 6) / 2;
        const starts = 16 + segments * 2;
        const deltas = starts + segments * 2;
        const ranges = deltas + segments * 2;
        for (0..segments) |segment| {
            const last = try readInt(u16, sub, 14 + segment * 2);
            const first = try readInt(u16, sub, starts + segment * 2);
            const delta = try readInt(u16, sub, deltas + segment * 2);
            const range = try readInt(u16, sub, ranges + segment * 2);
            var code: u32 = first;
            while (code <= last and code != 0xFFFF) : (code += 1) {
                var id: u16 = @intCast(code);
                if (range == 0) id +%= delta else {
                    id = try readInt(u16, sub, ranges + segment * 2 + range + (code - first) * 2);
                    if (id != 0) id +%= delta;
                }
                if (id == 0 or id >= count) continue;
                const name = try readInt(u16, post, 34 + @as(usize, id) * 2);
                if (name < 258 or name - 258 >= names.items.len) continue;
                var glyph = Glyph{ .name = names.items[name - 258] };
                glyph.len = std.unicode.utf8Encode(@intCast(code), &glyph.bytes) catch continue;
                try out.append(a, glyph);
            }
        }
        break;
    }
    std.mem.sort(Glyph, out.items, {}, struct {
        fn before(_: void, one: Glyph, two: Glyph) bool {
            return std.mem.lessThan(u8, one.name, two.name);
        }
    }.before);
    // A glyph can be mapped from more than one codepoint.
    var unique: usize = 0;
    for (out.items) |glyph| {
        if (unique > 0 and std.mem.eql(u8, out.items[unique - 1].name, glyph.name)) continue;
        out.items[unique] = glyph;
        unique += 1;
    }
    out.shrinkRetainingCapacity(unique);
    return out.toOwnedSlice(a);
}
/// Looks a glyph up by name in a list sorted by `glyphs`.
pub fn find(list: []const Glyph, name: []const u8) ?*const Glyph {
    var low: usize = 0;
    var high = list.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, list[middle].name, name)) {
            .eq => return &list[middle],
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return null;
}

test "the bundled Lucide font lists its icons by name" {
    const list = try glyphs(std.testing.allocator, @embedFile("toolbar_icon_font"));
    defer std.testing.allocator.free(list);
    try std.testing.expect(list.len > 1000);
    for (list[1..], list[0 .. list.len - 1]) |glyph, previous| try std.testing.expect(std.mem.lessThan(u8, previous.name, glyph.name));
    // The hand-written codepoints above must agree with the font.
    try std.testing.expectEqualStrings("\u{e0dc}", find(list, default_project).?.text());
    try std.testing.expectEqualStrings(Menu.remove.glyph(), find(list, "trash-2").?.text());
    try std.testing.expectEqualStrings(Menu.icon.glyph(), find(list, "palette").?.text());
    try std.testing.expectEqualStrings(Menu.edit.glyph(), find(list, "square-pen").?.text());
    inline for (.{ .{ Menu.rename, "pencil" }, .{ Menu.new_group, "folder-plus" }, .{ Menu.to_group, "folder-input" }, .{ Menu.ungroup, "folder-output" } }) |entry|
        try std.testing.expectEqualStrings(entry[0].glyph(), find(list, entry[1]).?.text());
    inline for (.{ .{ group_open, "chevron-down" }, .{ group_closed, "chevron-right" } }) |entry| try std.testing.expectEqualStrings(entry[0], find(list, entry[1]).?.text());
    try std.testing.expect(find(list, "not-an-icon") == null);
}

test "a truncated font is rejected instead of read out of bounds" {
    const font = @embedFile("toolbar_icon_font");
    for ([_]usize{ 0, 5, 40, 300, font.len / 2 }) |len| {
        if (glyphs(std.testing.allocator, font[0..len])) |list| std.testing.allocator.free(list) else |err| try std.testing.expectEqual(error.InvalidFont, err);
    }
}
