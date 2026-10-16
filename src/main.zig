const std = @import("std");
const git = @import("git.zig");
const App = @import("App.zig");
const credentials = @import("credentials.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
extern "c" fn fflush(?*anyopaque) c_int;
extern "kernel32" fn AttachConsole(process_id: u32) callconv(.winapi) i32;
const attach_parent_process: u32 = 0xFFFFFFFF;
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--credential-helper")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "get")) {
            var input: std.ArrayList(u8) = .empty;
            defer input.deinit(init.gpa);
            while (input.items.len < 65536) {
                const ch = getchar();
                if (ch < 0) break;
                try input.append(init.gpa, @intCast(ch));
            }
            if (credentials.isGitHubCredential(input.items)) if (try credentials.get(init.io, init.gpa)) |token| {
                defer credentials.clear(init.gpa, token);
                for ("username=x-access-token\npassword=") |ch| _ = putchar(ch);
                for (token) |ch| _ = putchar(ch);
                _ = putchar('\n');
                _ = putchar('\n');
            };
        }
        _ = fflush(null);
        return;
    }
    // The Windows build uses the GUI subsystem, so it gets no console of its
    // own. When started from a terminal, borrow that terminal for panics and logs.
    if (@import("builtin").os.tag == .windows) _ = AttachConsole(attach_parent_process);
    try git.init();
    defer git.shutdown();
    var app = try App.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    if (args.len > 2 and (std.mem.eql(u8, args[1], "--capture") or std.mem.eql(u8, args[1], "--capture-live") or std.mem.eql(u8, args[1], "--capture-git"))) {
        app.capture_path = args[2];
        if (std.mem.eql(u8, args[1], "--capture-live") or std.mem.eql(u8, args[1], "--capture-git")) app.capture_delay_ns = 8 * std.time.ns_per_s;
        if (std.mem.eql(u8, args[1], "--capture-git")) app.git_health_open = true;
        if (args.len > 3) try app.config.add(init.io, args[3]);
        if (args.len > 4) app.page = std.meta.stringToEnum(@FieldType(App, "page"), args[4]) orelse return error.UnknownPage;
        if (args.len > 5 and std.mem.eql(u8, args[5], "split")) app.split_diff = true;
        if (args.len > 5 and std.mem.eql(u8, args[5], "add")) app.add_open = true;
        if (args.len > 5 and app.page == .settings) app.settings_section = std.meta.stringToEnum(@FieldType(App, "settings_section"), args[5]) orelse return error.UnknownSection;
    } else if (args.len > 1) try app.config.add(init.io, args[1]);
    try app.start();
}
