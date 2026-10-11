const std = @import("std");
const knots = @import("knots");
const ui = @import("ui");
const model = @import("model.zig");
const git = @import("git.zig");
const providers = @import("provider.zig");
const config_mod = @import("config.zig");
const plugins = @import("plugins.zig");
const github = @import("github.zig");
const updater = @import("updater.zig");
const git_runtime = @import("git_runtime.zig");
const credentials = @import("credentials.zig");
const process = @import("process.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const AppIcon = @import("app_icon.zig");
const brand_badge = @import("brand_badge.zig");
const diff = @import("diff.zig");
const file_picker = @import("file_picker.zig");
const path_selection = @import("path_selection.zig");
const repository_watch = @import("repository_watch.zig");
const refresh = @import("refresh.zig");
const change_context = @import("change_context.zig");
const remote_sync = @import("remote_sync.zig");
const guidance = @import("guidance.zig");
const ignore = @import("ignore.zig");
const editor = @import("editor.zig");
const sidebar_drag = @import("sidebar_drag.zig");
const options = @import("options");
const Self = @This();
const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const file_row_height: f32 = 30;
const nav_height: f32 = 32;
const row_gap: f32 = 2;
/// Distance between the tops of neighbouring sidebar rows.
const row_pitch: f32 = nav_height + row_gap;
const root_padding: f32 = 12;
const menu_row_height: f32 = 30;
const icon_cell: f32 = 38;
const icon_columns = 13;
const menu_popup: ui.Style = .{ .width = .fixed(256), .gap = 0, .padding = .all(5), .radius = .{ .fixed = 10 }, .border_color = .toned };
/// Follows the diff font size; virtual rows read it while rendering.
var diff_row_height: f32 = 22;
const Page = enum { changes, history, operations, github, extensions, settings };
const tool_operations = blk: {
    const all = std.enums.values(model.Operation);
    var count: usize = 0;
    for (all) |op| if (op != .clone and op != .initialize and op != .stage_hunk and op != .unstage_hunk) {
        count += 1;
    };
    var values: [count]model.Operation = undefined;
    var index: usize = 0;
    for (all) |op| if (op != .clone and op != .initialize and op != .stage_hunk and op != .unstage_hunk) {
        values[index] = op;
        index += 1;
    };
    break :blk values;
};
/// A change to the sidebar's order or grouping, by workspace index or group id.
const SidebarEdit = union(enum) {
    move: [2]usize,
    move_group: [2]usize,
    assign: struct { index: usize, group: u32 },
    delete_group: u32,
    toggle_group: u32,
};
const DragPress = struct {
    item: sidebar_drag.Item,
    /// Pointer position inside the row.
    grab: [2]f32,
    width: f32,
};
/// A sidebar row carried by the pointer, then gliding to where it was dropped.
const Drag = struct {
    item: sidebar_drag.Item,
    grab: [2]f32,
    origin: sidebar_drag.Drop,
    drop: sidebar_drag.Drop,
    /// Top-left of the lifted row in the window.
    pos: [2]f32,
    width: f32,
    released: bool = false,
    /// 0 to 1 as the row rises off the list.
    lift: f32 = 0,
    /// 0 to 1 as the row moves in under a group.
    indent: f32,
    /// Height of the strip under the groups that takes an entry out of its group.
    strip: f32,
    /// Height held open at each slot between the remaining rows.
    gaps: []f32,
};
/// What the name dialog edits. A new group can take a workspace entry with it.
const NameTarget = union(enum) { repository: usize, group: u32, new_group: ?usize };
const JobKind = enum { git, open_local, counts, preview, revision, auth_begin, auth_poll, sign_out, update_check, update_download, extension, github_repos };
const Job = struct {
    environment: ?*const std.process.Environ.Map = null,
    quiet: bool = false,
    generation: u64 = 0,
    selection: u64 = 0,
    files: []const model.File = &.{},
    arena: std.heap.ArenaAllocator,
    kind: JobKind,
    path: []const u8,
    request: model.Request,
    provider: *const providers.Provider,
    client: []const u8 = "",
    device: []const u8 = "",
    release_repo: []const u8 = "",
    update_key: []const u8 = "",
    asset: ?updater.Asset = null,
    manifest: ?plugins.Manifest = null,
    command: ?plugins.Command = null,
    settings: []const config_mod.SettingValue = &.{},
    fn deinit(self: *Job, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
const Result = struct {
    operation: model.Operation = .refresh,
    repository_path: []const u8 = "",
    fetched_at: ?i64 = null,
    quiet: bool = false,
    kind: JobKind = .git,
    generation: u64 = 0,
    selection: u64 = 0,
    arena: std.heap.ArenaAllocator,
    message: []const u8 = "",
    signed_out: bool = false,
    failed: bool = false,
    snapshot: ?model.Snapshot = null,
    revision: ?model.Snapshot = null,
    device: ?github.Device = null,
    poll: ?github.Poll = null,
    update: ?updater.Manifest = null,
    downloaded: ?[]const u8 = null,
    repositories: ?[]github.Repository = null,
    setup_path: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        if (self.snapshot) |*s| s.deinit();
        if (self.revision) |*s| s.deinit();
        self.arena.deinit();
    }
};

io: std.Io,
a: std.mem.Allocator,
environment: *const std.process.Environ.Map,
fetch_attempts: std.StringHashMap(i64),
fetch_busy: bool = false,
app: knots.App,
app_icon: AppIcon,
config: config_mod.Config,
registry: plugins.Registry,
provider: *const providers.Provider = &providers.git,
snapshot: ?model.Snapshot = null,
revision: ?model.Snapshot = null,
preview: ?model.Snapshot = null,
generation: u64 = 0,
selection: u64 = 0,
read_busy: bool = false,
counts_busy: bool = false,
preview_busy: bool = false,
background_busy: bool = false,
counts_quiet: bool = false,
preview_quiet: bool = false,
refresh_pending: bool = false,
watcher: repository_watch.Watcher = .{},
watch_epoch: std.atomic.Value(u64) = .init(0),
preview_pending: bool = false,
preview_wait_ns: u64 = 0,
loading_ns: u64 = 0,
loading_path: []const u8 = "",
file_rows: []FileRow = &.{},
cached_filter: []const u8 = "",
file_rows_valid: bool = false,
file_list_reset: bool = true,
diff_rows: []DiffRow = &.{},
split_rows: []diff.Pair = &.{},
diff_rows_valid: bool = false,
page: Page = .changes,
selected_file: usize = 0,
selected_revision: ?usize = null,
split_diff: bool = false,
split_scroll_y: f32 = 0,
busy: bool = false,
active_operation: ?model.Operation = null,
clear_commit_message: bool = false,
picker_open: bool = false,
pending_picker: ?struct { kind: file_picker.Kind, input: *std.ArrayList(u8), repository_relative: bool, title: []const u8 } = null,
notice: []const u8 = "Ready. Add a local repository or clone a remote to begin.",
notice_owned: bool = false,
notice_error: bool = false,
add_open: bool = false,
/// The add dialog was opened for a folder without a repository.
setup_notice: bool = false,
confirm_open: bool = false,
remote_open: bool = false,
/// Push once the remote added from the setup dialog exists.
publish_after_connect: bool = false,
failure_open: bool = false,
failure_operation: model.Operation = .refresh,
failure_text: []const u8 = "",
/// Every glyph of the bundled Lucide font, for project icons.
lucide: []icons.Glyph = &.{},
icon_open: bool = false,
/// Workspace index the icon picker edits.
icon_target: usize = 0,
icon_hover: ?[]const u8 = null,
icon_filter: std.ArrayList(u8) = .empty,
active_context: ?ui.Key = null,
/// Applied after the repository rows are built, so no row is rendered twice.
pending_edit: ?SidebarEdit = null,
/// The row under a held press; it is lifted once the pointer travels.
drag_press: ?DragPress = null,
drag: ?Drag = null,
name_open: bool = false,
name_target: NameTarget = .{ .new_group = null },
name_input: std.ArrayList(u8) = .empty,
/// Put the caret in the name field on the dialog's first frame.
name_focus: bool = false,
pending_request: ?model.Request = null,
pending_extension: ?struct { manifest: plugins.Manifest, command: plugins.Command, settings: []const config_mod.SettingValue } = null,
path_input: std.ArrayList(u8) = .empty,
remote_input: std.ArrayList(u8) = .empty,
commit_input: std.ArrayList(u8) = .empty,
filter_input: std.ArrayList(u8) = .empty,
value_input: std.ArrayList(u8) = .empty,
second_input: std.ArrayList(u8) = .empty,
connect_input: std.ArrayList(u8) = .empty,
extension_path: std.ArrayList(u8) = .empty,
client_input: std.ArrayList(u8) = .empty,
release_input: std.ArrayList(u8) = .empty,
settings_section: SettingsSection = .appearance,
operation_index: u32 = 0,
device: ?github.Device = null,
auth_elapsed_ns: u64 = 0,
auth_poll_ns: u64 = 0,
auth_interval: u32 = 5,
update: ?updater.Manifest = null,
downloaded: ?[]const u8 = null,
github_repositories: []github.Repository = &.{},
capture_path: ?[]const u8 = null,
capture_frames: u32 = 0,
capture_ready_frames: u32 = 0,
capture_delay_ns: u64 = 0,
capture_elapsed_ns: u64 = 0,
capture_requested: bool = false,
update_checked: bool = false,
git_health: ?git_runtime.Snapshot = null,
git_health_busy: bool = false,
git_installing: bool = false,
git_health_open: bool = false,
git_probe_at: i64 = 0,
git_updates_at: i64 = 0,
git_install_report: []const u8 = "",
git_install_failed: bool = false,

pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map) !Self {
    var config = try config_mod.Config.init(io, a, env);
    errdefer config.deinit();
    try AppIcon.prepare();
    var app = try knots.App.init(io, a, .{ .window = .{ .width = 1440, .height = 900, .title = "Weaver" }, .ui = .{ .theme = themes.theme(config.data.theme, config.data.accent, config.data.text_size) } });
    var app_icon: AppIcon = .{};
    errdefer {
        app.deinit();
        app_icon.deinit();
    }
    app_icon = try AppIcon.init(&app.main_viewport.window);
    try app.main_viewport.ui_ctx.ui.font.addFace("mono", @embedFile("mono_font"));
    try app.main_viewport.ui_ctx.ui.font.addFace("devicon", @embedFile("file_icon_font"));
    try app.main_viewport.ui_ctx.ui.font.addFace("lucide", @embedFile("toolbar_icon_font"));
    const lucide = try icons.glyphs(a, @embedFile("toolbar_icon_font"));
    errdefer a.free(lucide);
    var self = Self{ .io = io, .a = a, .environment = env, .fetch_attempts = .init(a), .app = app, .app_icon = app_icon, .config = config, .registry = try plugins.Registry.init(a), .lucide = lucide };
    for (config.data.extensions) |state| {
        if (state.manifest_path.len > 0) self.registry.install(io, state.manifest_path) catch continue;
        for (self.registry.items.items) |*extension| if (std.mem.eql(u8, extension.manifest.id, state.id)) {
            extension.enabled = state.enabled;
            for (extension.settings, 0..) |*setting, i| for (state.settings) |saved| {
                if (std.mem.eql(u8, setting.id, saved.id) and saved.value.len <= 4096) {
                    setting.value = try self.registry.arena.allocator().dupe(u8, saved.value);
                    extension.inputs[i].clearRetainingCapacity();
                    try extension.inputs[i].appendSlice(self.registry.arena.allocator(), saved.value);
                }
            };
        };
    }
    try self.client_input.appendSlice(a, options.oauth_client_id);
    try self.release_input.appendSlice(a, if (config.data.release_repo.len > 0) config.data.release_repo else options.release_repo);
    self.split_diff = config.data.split_diff;
    return self;
}
pub fn deinit(self: *Self) void {
    // App shutdown joins/cancels background tasks before freeing their state.
    self.app.deinit();
    if (self.git_health) |*health| health.deinit();
    self.a.free(self.git_install_report);
    self.app_icon.deinit();
    self.watcher.deinit(self.a);
    if (self.snapshot) |*s| s.deinit();
    if (self.revision) |*s| s.deinit();
    if (self.preview) |*s| s.deinit();
    self.a.free(self.file_rows);
    self.a.free(self.cached_filter);
    self.a.free(self.loading_path);
    self.a.free(self.lucide);
    self.endDrag();
    self.clearDiffRows();
    inline for (.{ "path_input", "remote_input", "commit_input", "filter_input", "value_input", "second_input", "connect_input", "extension_path", "client_input", "release_input", "icon_filter", "name_input" }) |field| @field(self, field).deinit(self.a);
    if (self.notice_owned) self.a.free(self.notice);
    self.a.free(self.failure_text);
    self.registry.deinit();
    var fetch_keys = self.fetch_attempts.keyIterator();
    while (fetch_keys.next()) |key| self.a.free(key.*);
    self.fetch_attempts.deinit();
    self.config.deinit();
}
pub fn start(self: *Self) !void {
    try self.checkGitRuntime(false);
    if (self.path()) |repo_path| {
        if (providers.byId(self.config.data.repositories[self.config.data.selected].provider)) |provider| {
            self.provider = provider;
            try self.launch(.git, repo_path, .{ .operation = .refresh });
        } else self.message("This workspace needs a version-control provider that is not installed.", true);
    }
    if (self.capture_path == null or self.capture_delay_ns > 0) try self.scheduleRefresh();
    try self.app.startWithIdle(frame, idle);
}
fn idle(app: *knots.App) !void {
    const self: *Self = @alignCast(@fieldParentPtr("app", app));
    if (self.pending_picker) |request_value| {
        self.pending_picker = null;
        defer self.picker_open = false;
        try self.showPicker(request_value.kind, request_value.input, request_value.repository_relative, request_value.title);
        app.main_viewport.window.requestFrame();
    }
}
fn scheduleRefresh(self: *Self) !void {
    try self.app.dispatch(self.app.main_viewport.id, refreshWait, .{ self.io, &self.watcher, &self.watch_epoch, self.watch_epoch.load(.acquire) }, refreshTick);
}
fn refreshWait(io: std.Io, watcher: *repository_watch.Watcher, epoch: *const std.atomic.Value(u64), expected: u64) repository_watch.Signal {
    return watcher.wait(io, epoch, expected);
}
fn refreshTick(view: *knots.View, ctx: *ui.Frame, tick: repository_watch.Signal) !void {
    if (tick == .cancelled) return;
    ctx.requestRedraw(); // Also advances relative fetch times while otherwise idle.
    const self = of(view);
    try self.checkGitRuntime(false);
    if (tick == .reconfigure) {
        if (self.snapshot) |snapshot| {
            self.watcher.reset(self.a, snapshot.path) catch {};
            // Covers changes between the initial status read and arming the watch.
            self.refresh_pending = true;
        } else self.watcher.deinit(self.a);
    } else if (tick == .changed or (tick == .heartbeat and !self.watcher.native)) self.refresh_pending = true;
    if (!self.picker_open and self.available() and !self.update_checked and self.config.data.auto_update_check and options.update_public_key.len == 64 and updater.validRepo(self.release_input.items)) {
        self.update_checked = true;
        try self.launchInternal(.update_check, self.config.path, .{ .operation = .refresh }, true);
    }
    try self.scheduleRefresh();
}
fn of(view: *knots.View) *Self {
    return @alignCast(@fieldParentPtr("app", view.app));
}
const GitHealthJob = struct {
    arena: std.heap.ArenaAllocator,
    environment: *const std.process.Environ.Map,
    updates: bool,
    install: ?git_runtime.Snapshot = null,
    fn deinit(self: *GitHealthJob, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
const GitHealthResult = struct {
    snapshot: git_runtime.Snapshot,
    updates: bool,
    installing: bool,
    failed: bool = false,
    message: []const u8 = "",
    details: []const u8 = "",
    pub fn deinit(self: *GitHealthResult) void {
        self.snapshot.deinit();
    }
};
fn gitUpdateChecks(self: *const Self) bool {
    for (self.registry.items.items) |extension| if (std.mem.eql(u8, extension.manifest.id, "weaver.git")) {
        for (extension.settings) |setting| if (std.mem.eql(u8, setting.id, "git.check_updates"))
            return std.ascii.eqlIgnoreCase(std.mem.trim(u8, setting.value, " \t\r\n"), "true");
    };
    return false;
}
fn checkGitRuntime(self: *Self, force: bool) !void {
    if (!self.registry.enabled("weaver.git") or self.git_health_busy) return;
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    if (!force and self.git_probe_at != 0 and now >= self.git_probe_at and now - self.git_probe_at < 300) return;
    // Publish local detection first; an offline release server must not delay the version label.
    try self.launchGitHealth(null, self.git_health != null and self.gitUpdateChecks() and (force or self.git_updates_at == 0 or now < self.git_updates_at or now - self.git_updates_at >= 86400));
    self.git_probe_at = now;
}
fn launchGitHealth(self: *Self, install: ?git_runtime.Snapshot, updates: bool) !void {
    const job = try self.a.create(GitHealthJob);
    job.* = .{ .arena = .init(self.a), .environment = self.environment, .updates = updates };
    errdefer job.deinit(self.a);
    const a = job.arena.allocator();
    if (install) |health| {
        // Copy the action inputs: an unrelated UI frame must never invalidate them.
        var copy = health;
        copy.executable = try a.dupe(u8, health.executable);
        copy.manager_executable = try a.dupe(u8, health.manager_executable);
        copy.version = try a.dupe(u8, health.version);
        job.install = copy;
        self.a.free(self.git_install_report);
        self.git_install_report = "";
        self.git_install_failed = false;
    }
    try self.app.dispatchWithCleanup(self.app.main_viewport.id, gitHealthWork, .{ self.io, self.a, job }, gitHealthDone, GitHealthResult.deinit);
    self.git_health_busy = true;
    self.git_installing = install != null;
}
fn gitHealthWork(io: std.Io, a: std.mem.Allocator, job: *GitHealthJob) GitHealthResult {
    defer job.deinit(a);
    var output: ?process.Result = null;
    defer if (output) |r| r.deinit(a);
    var failure: ?[]const u8 = null;
    if (job.install) |health| {
        // Verify that the same executable/owning manager still supplies Git before
        // changing the computer; custom replacements fail closed.
        var current = git_runtime.inspect(io, a, job.environment, false);
        defer current.deinit();
        if (current.presence != health.presence or current.manager != health.manager or current.install_scope != health.install_scope or
            !std.mem.eql(u8, current.executable, health.executable) or
            !std.mem.eql(u8, current.manager_executable, health.manager_executable))
        {
            failure = "Git's installation changed. Check again before installing or updating.";
        } else output = git_runtime.apply(io, a, &health) catch |err| blk: {
            failure = @errorName(err);
            break :blk null;
        };
    }
    var result = GitHealthResult{ .snapshot = git_runtime.inspect(io, a, job.environment, job.updates), .updates = job.updates, .installing = job.install != null };
    const arena = result.snapshot.arena.allocator();
    if (failure) |reason| {
        result.failed = true;
        result.message = std.fmt.allocPrint(arena, "Git installation could not complete: {s}. Use the installation instructions or your package manager.", .{reason}) catch "Git installation failed.";
    } else if (output) |r| {
        if (git_runtime.installationReport(arena, &job.install.?, &result.snapshot, r)) |report| {
            result.failed = report.failed;
            result.message = report.message;
            result.details = report.details;
        } else |_| {
            result.failed = true;
            result.message = "The Git command finished, but its result could not be recorded. Check the detected version before trying again.";
        }
    }
    return result;
}
fn gitHealthDone(view: *knots.View, ctx: *ui.Frame, value: GitHealthResult) !void {
    const self = of(view);
    var result = value;
    self.git_health_busy = false;
    self.git_installing = false;
    if (!self.registry.enabled("weaver.git")) {
        result.deinit();
        return;
    }
    var transferred = false;
    defer if (!transferred) result.deinit();
    if (!self.gitUpdateChecks()) {
        result.snapshot.update_available = false;
        result.snapshot.updates_verified = false;
        result.snapshot.latest = "";
        if (result.snapshot.presence == .installed) result.snapshot.check_note = "Automatic Git update checks are disabled.";
    }
    if (!result.updates and self.gitUpdateChecks()) if (self.git_health) |old| {
        if (old.presence == result.snapshot.presence and old.manager == result.snapshot.manager and old.install_scope == result.snapshot.install_scope and
            std.mem.eql(u8, old.executable, result.snapshot.executable) and std.mem.eql(u8, old.manager_executable, result.snapshot.manager_executable) and std.mem.eql(u8, old.version, result.snapshot.version))
        {
            const a = result.snapshot.arena.allocator();
            result.snapshot.latest = try a.dupe(u8, old.latest);
            result.snapshot.update_available = old.update_available;
            result.snapshot.updates_verified = old.updates_verified;
            result.snapshot.check_note = try a.dupe(u8, old.check_note);
        } else self.git_updates_at = 0;
    };
    if (self.git_health) |*old| old.deinit();
    self.git_health = result.snapshot;
    transferred = true;
    if (result.updates and result.snapshot.presence == .installed) self.git_updates_at = std.Io.Clock.real.now(self.io).toSeconds();
    if (result.installing) {
        const report = try diff.safeText(self.a, try std.fmt.allocPrint(ctx.arena(), "{s}\n\n{s}", .{ result.message, result.details }));
        self.a.free(self.git_install_report);
        self.git_install_report = report;
        self.git_install_failed = result.failed;
        self.message(result.message, result.failed);
        self.git_health_open = true;
    }
    ctx.requestRedraw();
    if (!result.updates and self.git_updates_at == 0 and result.snapshot.presence == .installed and self.gitUpdateChecks()) try self.checkGitRuntime(true);
}
fn available(self: *Self) bool {
    return !self.busy and !self.picker_open and !self.fetch_busy and !self.git_installing;
}
fn canNavigate(self: *Self) bool {
    return (!self.busy or self.read_busy) and !self.picker_open and !self.git_installing;
}
fn automaticFetch(self: *Self) !void {
    const snapshot = self.snapshot orelse return;
    const p = self.path() orelse return;
    const idle_state = self.available() and !self.background_busy and !self.counts_busy and !self.preview_busy and !self.preview_pending and !self.confirm_open and !self.add_open and config_mod.equalPath(snapshot.path, p);
    const now = std.Io.Clock.real.now(self.io).toSeconds();
    const last_attempt = self.fetch_attempts.get(p) orelse self.config.data.repositories[self.config.data.selected].last_fetched;
    if (remote_sync.fetchDue(self.config.data.auto_fetch, idle_state, self.provider.background_fetch != null and snapshot.remotes.len > 0, last_attempt, now))
        try self.launchInternal(.git, p, .{ .operation = .fetch }, true);
}
fn path(self: *Self) ?[]const u8 {
    if (self.config.data.repositories.len == 0) return null;
    return self.config.data.repositories[self.config.data.selected].path;
}
fn message(self: *Self, text: []const u8, failed: bool) void {
    const copy = diff.safeText(self.a, text[0..@min(text.len, 65536)]) catch return;
    if (self.notice_owned) self.a.free(self.notice);
    self.notice = copy;
    self.notice_owned = true;
    self.notice_error = failed;
}
fn launch(self: *Self, kind: JobKind, path_value: []const u8, req: model.Request) !void {
    return self.launchInternal(kind, path_value, req, false);
}
fn openLocal(self: *Self, path_value: []const u8) !void {
    self.provider = &providers.git;
    self.page = .changes;
    try self.launch(.open_local, path_value, .{ .operation = .refresh });
    self.add_open = false;
}
fn launchInternal(self: *Self, kind: JobKind, path_value: []const u8, req: model.Request, quiet: bool) !void {
    if (!self.available() and !(self.canNavigate() and kind == .git and req.operation == .refresh)) return;
    const background = quiet and kind == .git and (req.operation == .refresh or req.operation == .fetch);
    if (!background and (kind == .git or kind == .open_local or kind == .revision)) {
        self.generation += 1;
        self.selection += 1;
        self.counts_busy = false;
        self.preview_busy = false;
        self.preview_pending = false;
        self.background_busy = false;
    }
    const job = try self.a.create(Job);
    job.* = .{ .arena = .init(self.a), .environment = self.environment, .kind = kind, .path = "", .request = req, .provider = self.provider, .quiet = quiet, .generation = self.generation };
    errdefer job.deinit(self.a);
    const arena = job.arena.allocator();
    job.path = try arena.dupe(u8, path_value);
    if (kind == .git or kind == .open_local) {
        if (self.snapshot == null or !config_mod.equalPath(self.snapshot.?.path, if (req.operation == .clone) req.second else path_value)) self.file_list_reset = true;
        const target = try self.a.dupe(u8, if (req.operation == .clone) req.second else path_value);
        self.a.free(self.loading_path);
        self.loading_path = target;
    }
    job.request.value = try arena.dupe(u8, req.value);
    job.request.second = try arena.dupe(u8, req.second);
    job.client = try arena.dupe(u8, self.client_input.items);
    if (self.device) |d| job.device = try arena.dupe(u8, d.device_code);
    job.release_repo = try arena.dupe(u8, self.release_input.items);
    job.update_key = try arena.dupe(u8, options.update_public_key);
    if (kind == .update_download) if (self.update) |update| {
        for (update.assets) |asset| if (std.mem.eql(u8, asset.platform, updater.platform())) {
            job.asset = asset;
            break;
        };
    };
    if (kind == .extension) if (self.pending_extension) |extension| {
        job.manifest = extension.manifest;
        job.command = extension.command;
        const values = try arena.alloc(config_mod.SettingValue, extension.settings.len);
        for (values, extension.settings) |*copy, setting| copy.* = .{ .id = try arena.dupe(u8, setting.id), .value = try arena.dupe(u8, setting.value) };
        job.settings = values;
    };
    if (kind == .git and req.operation == .fetch) {
        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();
        if (self.fetch_attempts.getPtr(path_value)) |previous| {
            previous.* = timestamp;
        } else {
            const owned_path = try self.a.dupe(u8, path_value);
            errdefer self.a.free(owned_path);
            try self.fetch_attempts.put(owned_path, timestamp);
        }
    }
    try self.app.dispatchWithCleanup(self.app.main_viewport.id, work, .{ self.io, self.a, job }, done, Result.deinit);
    if (background and req.operation == .fetch) {
        self.fetch_busy = true;
    } else if (background) {
        self.background_busy = true;
    } else {
        self.busy = true;
        self.active_operation = if (kind == .git) req.operation else null;
        self.read_busy = (kind == .git or kind == .open_local) and req.operation == .refresh;
        self.loading_ns = 0;
    }
    if (!quiet) self.message(if (self.read_busy) "Scanning repository changes…" else "Working…", false);
}
fn launchRead(self: *Self, kind: JobKind, repo_path: []const u8, files_value: []const model.File, quiet: bool) !void {
    const job = try self.a.create(Job);
    job.* = .{ .arena = .init(self.a), .kind = kind, .path = "", .request = .{ .operation = .refresh }, .provider = self.provider, .quiet = quiet, .generation = self.generation, .selection = self.selection };
    errdefer job.deinit(self.a);
    const a = job.arena.allocator();
    job.path = try a.dupe(u8, repo_path);
    const copies = try a.alloc(model.File, files_value.len);
    for (files_value, copies) |f, *copy| copy.* = .{ .path = try a.dupe(u8, f.path), .old_path = try a.dupe(u8, f.old_path), .status = try a.dupe(u8, f.status), .staged = f.staged };
    job.files = copies;
    try self.app.dispatchWithCleanup(self.app.main_viewport.id, work, .{ self.io, self.a, job }, done, Result.deinit);
    if (kind == .preview) {
        self.preview_busy = true;
        self.preview_quiet = quiet;
    } else {
        self.counts_busy = true;
        self.counts_quiet = quiet;
    }
}
fn clearDiffRows(self: *Self) void {
    self.a.free(self.diff_rows);
    self.a.free(self.split_rows);
    self.diff_rows = &.{};
    self.split_rows = &.{};
    self.diff_rows_valid = false;
}
fn selectFile(self: *Self, index: usize) void {
    self.selected_file = index;
    self.selection += 1;
    self.preview_busy = false;
    self.preview_pending = self.page == .changes;
    self.preview_quiet = false;
    self.preview_wait_ns = 0;
    self.clearDiffRows();
    self.split_scroll_y = 0;
    const state = &self.app.main_viewport.ui_ctx.ui.state;
    for ([_]ui.Key{
        ui.Key.str("diff-scroll").indexed(index).indexed(0),
        ui.Key.str("diff-scroll").indexed(index).indexed(1),
        ui.Key.str("diff-left-column").indexed(index),
        ui.Key.str("diff-right-column").indexed(index),
    }) |key| if (state.get(.scroll, key.hash())) |scroll| {
        scroll.offset = .{ 0, 0 };
    };
    if (self.preview) |*s| s.deinit();
    self.preview = null;
}
fn work(io: std.Io, a: std.mem.Allocator, job: *Job) Result {
    defer job.deinit(a);
    var result = Result{ .arena = .init(a), .quiet = job.quiet, .kind = job.kind, .operation = job.request.operation, .generation = job.generation, .selection = job.selection };
    perform(io, a, job, &result) catch |err| {
        result.failed = true;
        result.message = std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ @errorName(err), if (err == error.GitFailure) @import("git.zig").lastError() else "Check the operation and repository settings." }) catch "Operation failed";
    };
    return result;
}
fn perform(io: std.Io, a: std.mem.Allocator, job: *Job, result: *Result) !void {
    const arena = result.arena.allocator();
    result.repository_path = try arena.dupe(u8, job.path);
    switch (job.kind) {
        .open_local => {
            const detected = try @import("git.zig").discover(arena, job.path) orelse {
                result.setup_path = try arena.dupe(u8, job.path);
                result.message = "No Git repository found. Initialize this folder or choose a source to clone.";
                return;
            };
            result.snapshot = try job.provider.scan(io, a, detected.path);
            result.message = if (detected.remotes.len > 0) "Opened existing repository with its configured remotes." else "Opened existing local repository.";
        },
        .git => {
            if (job.request.operation != .refresh) {
                const r = if (job.quiet and job.request.operation == .fetch)
                    try job.provider.background_fetch.?(io, a, job.path, job.environment.?)
                else
                    try job.provider.execute(io, a, job.path, job.request);
                defer r.deinit(a);
                result.message = try std.fmt.allocPrint(arena, "{s}{s}", .{ r.stdout, r.stderr });
                result.failed = !r.ok;
                if (r.ok and (job.request.operation == .fetch or job.request.operation == .pull)) result.fetched_at = std.Io.Clock.real.now(io).toSeconds();
                if (!r.ok and (job.request.operation == .clone or job.request.operation == .initialize)) return;
            }
            const destination = if (job.request.operation == .clone) job.request.second else job.path;
            result.snapshot = job.provider.scan(io, a, destination) catch |err| {
                // A workspace folder that was moved or lost its repository: offer setup.
                if (job.request.operation != .refresh or job.quiet) return err;
                if ((git.discover(arena, job.path) catch return err) != null) return err;
                result.setup_path = try arena.dupe(u8, job.path);
                result.failed = true;
                result.message = "This folder is not a Git repository any more. Initialize it, clone into it, or remove it from the workspace.";
                return;
            };
            if (result.message.len == 0) result.message = "Repository refreshed.";
        },
        .counts => result.snapshot = try job.provider.counts(io, a, job.path, job.files),
        .preview => result.snapshot = try job.provider.preview(io, a, job.path, job.files[0]),
        .revision => {
            result.revision = try job.provider.revision(a, job.path, job.request.value);
            result.message = "Showing committed changes.";
        },
        .auth_begin => if (job.client.len > 0) {
            result.device = try github.begin(io, arena, job.client);
            result.message = "Enter the displayed code at github.com/login/device.";
        } else {
            // Builds without an OAuth client ID sign in through Git Credential Manager.
            const login = try github.signIn(io, arena, job.environment.?);
            result.poll = .{ .complete = login };
            result.message = try std.fmt.allocPrint(arena, "Signed in to GitHub as {s}.", .{login});
        },
        .auth_poll => {
            result.poll = try github.poll(io, arena, job.client, job.device);
            result.message = switch (result.poll.?) {
                .complete => |login| try std.fmt.allocPrint(arena, "Signed in to GitHub as {s}.", .{login}),
                .pending => "Waiting for GitHub authorization…",
                .slow_down => "GitHub requested a slower polling interval.",
                .denied => "GitHub authorization was declined.",
                .expired => "Sign-in expired. Start again.",
            };
        },
        .sign_out => {
            try credentials.remove(io, a);
            result.signed_out = true;
            result.message = "GitHub credentials removed from this computer.";
        },
        .update_check => {
            result.update = updater.check(io, arena, job.release_repo, job.update_key, options.version) catch |err| switch (err) {
                error.NoNewUpdate => {
                    result.message = "You have the latest version.";
                    return;
                },
                else => return err,
            };
            result.message = "A verified update is available.";
        },
        .update_download => {
            const asset = job.asset orelse return error.NoUpdateForPlatform;
            const dir = try std.fs.path.join(arena, &.{ std.fs.path.dirname(job.path).?, "updates" });
            result.downloaded = try updater.download(io, arena, asset, dir);
            result.message = "Update downloaded and verified. Ready to install.";
        },
        .extension => {
            const r = try plugins.invoke(io, a, job.manifest.?, job.command.?, job.path, job.provider.id, job.settings);
            defer r.deinit(a);
            result.message = try std.fmt.allocPrint(arena, "{s}{s}", .{ r.stdout, r.stderr });
            result.failed = !r.ok;
        },
        .github_repos => {
            result.repositories = try github.repositories(io, arena);
            result.message = "GitHub repositories loaded.";
        },
    }
}
fn done(view: *knots.View, frame_ctx: *ui.Frame, value: Result) !void {
    const self = of(view);
    var result = value;
    defer result.deinit();
    if (result.kind == .git and result.quiet and result.operation == .fetch) self.fetch_busy = false;
    if (result.fetched_at) |timestamp| {
        for (self.config.data.repositories) |*repository| if (config_mod.equalPath(repository.path, result.repository_path)) {
            repository.last_fetched = timestamp;
            try self.config.save(self.io);
            break;
        };
    }
    if ((result.kind == .git or result.kind == .open_local or result.kind == .revision or result.kind == .counts or result.kind == .preview) and result.generation != self.generation) return;
    if (result.kind == .preview or result.kind == .counts) {
        if (result.kind == .preview) {
            if (result.selection != self.selection) return;
            self.preview_busy = false;
            const unchanged = result.quiet and self.preview != null and result.snapshot != null and
                refresh.samePreview(self.preview.?.files[0], result.snapshot.?.files[0]);
            if (!unchanged) {
                self.clearDiffRows();
                if (self.preview) |*s| s.deinit();
                self.preview = result.snapshot;
                result.snapshot = null;
            }
            if (self.preview) |preview_value| if (self.snapshot) |*s| if (self.selected_file < s.files.len) {
                const file = &s.files[self.selected_file];
                const loaded = preview_value.files[0];
                if (loaded.stats_available) {
                    file.additions = loaded.additions;
                    file.deletions = loaded.deletions;
                    file.binary = loaded.binary;
                    file.stats_available = true;
                }
            };
        } else {
            self.counts_busy = false;
            if (result.snapshot) |stats| if (self.snapshot) |*s| {
                // The generation guarantees both arrays describe the same scan.
                if (stats.files.len == s.files.len) for (stats.files, s.files) |counted, *file| {
                    if (counted.stats_available) {
                        file.additions = counted.additions;
                        file.deletions = counted.deletions;
                        file.binary = counted.binary;
                        file.stats_available = true;
                    }
                };
            };
        }
        if (result.failed) self.message(result.message, true);
        frame_ctx.requestRedraw();
        return;
    }
    const background = result.quiet and result.kind == .git;
    if (background) {
        if (result.operation == .refresh) self.background_busy = false;
    } else {
        self.busy = false;
        self.read_busy = false;
        self.active_operation = null;
        if (self.clear_commit_message and result.kind == .git and result.operation == .commit and !result.failed) {
            self.commit_input.clearRetainingCapacity();
            if (frame_ctx.ui().state.get(.text_input, ui.Key.str("commit-message").hash())) |input| {
                input.cursor = 0;
                input.sel_anchor = 0;
            }
        }
        self.clear_commit_message = false;
    }
    if (!result.quiet or result.failed) self.message(result.message, result.failed);
    if (result.setup_path) |folder| {
        self.path_input.clearRetainingCapacity();
        try self.path_input.appendSlice(self.a, folder);
        self.remote_input.clearRetainingCapacity();
        self.add_open = true;
        self.setup_notice = true;
    }
    if (result.failed and result.kind == .git and !result.quiet and guidance.guided(result.operation)) {
        const copy = try diff.safeText(self.a, std.mem.trim(u8, result.message[0..@min(result.message.len, 8192)], " \t\r\n"));
        self.a.free(self.failure_text);
        self.failure_text = copy;
        self.failure_operation = result.operation;
        self.failure_open = true;
    }
    const connected = result.kind == .git and result.operation == .add_remote and !result.failed and self.publish_after_connect;
    if (result.kind == .git and result.operation == .add_remote) self.publish_after_connect = false;
    const a = self.config.arena.allocator();
    if (result.snapshot) |snapshot| {
        if (!config_mod.equalPath(self.watcher.path, snapshot.path)) _ = self.watch_epoch.fetchAdd(1, .release);
        if (background) if (self.snapshot) |previous| {
            var comparable = previous;
            if (result.operation == .fetch) {
                comparable.ahead = snapshot.ahead;
                comparable.behind = snapshot.behind;
            }
            if (refresh.sameList(previous.files, snapshot.files) and refresh.sameMetadata(comparable, snapshot)) {
                self.snapshot.?.ahead = snapshot.ahead;
                self.snapshot.?.behind = snapshot.behind;
                // A status list can be identical after editing an already modified
                // file. Keep the list, but re-read its counts and selected content.
                try self.refreshDetails();
                frame_ctx.requestRedraw();
                return;
            }
        };
        var selected: usize = @min(self.selected_file, if (snapshot.files.len == 0) 0 else snapshot.files.len - 1);
        if (self.snapshot) |previous| if (self.selected_file < previous.files.len) {
            const file = previous.files[self.selected_file];
            for (snapshot.files, 0..) |next, i| if (next.staged == file.staged and std.mem.eql(u8, next.path, file.path)) {
                selected = i;
                break;
            };
        };
        if (background) if (self.snapshot) |previous| try refresh.retainCounts(self.a, previous.files, snapshot.files);
        if (background) {
            self.generation += 1;
            self.counts_busy = false;
            self.preview_busy = false;
        }
        if (self.snapshot) |*s| {
            change_context.reconcile(&frame_ctx.ui().state, &self.active_context, s.path, s.files, snapshot.path, snapshot.files);
            s.deinit();
        }
        self.clearDiffRows();
        self.file_rows_valid = false;
        self.snapshot = snapshot;
        result.snapshot = null;
        if (self.path() == null or !config_mod.equalPath(self.path().?, snapshot.path)) try self.config.addProvider(self.io, snapshot.path, self.provider.id);
        if (result.quiet and self.preview != null and selected < snapshot.files.len and std.mem.eql(u8, self.preview.?.files[0].path, snapshot.files[selected].path) and self.preview.?.files[0].staged == snapshot.files[selected].staged) {
            if (selected != self.selected_file) try self.moveDiffScroll(self.selected_file, selected);
            self.selected_file = selected;
            self.selection += 1;
            self.preview_pending = true;
            self.preview_quiet = true;
            self.preview_wait_ns = 0;
        } else self.selectFile(selected);
        if (self.revision) |*r| r.deinit();
        self.revision = null;
        self.selected_revision = null;
        if (snapshot.files.len > 0) try self.launchRead(.counts, snapshot.path, snapshot.files, background);
    }
    if (result.revision) |revision| {
        self.clearDiffRows();
        if (self.revision) |*s| s.deinit();
        self.revision = revision;
        result.revision = null;
        self.selected_file = 0;
    }
    if (result.device) |d| {
        self.device = .{ .device_code = try a.dupe(u8, d.device_code), .user_code = try a.dupe(u8, d.user_code), .verification_uri = try a.dupe(u8, d.verification_uri), .expires_in = d.expires_in, .interval = d.interval };
        self.auth_elapsed_ns = 0;
        self.auth_poll_ns = 0;
        self.auth_interval = d.interval;
        try openPath(self.io, self.a, "https://github.com/login/device");
    }
    if (result.poll) |poll| switch (poll) {
        .complete => |login| {
            self.device = null;
            self.config.data.github_login = try a.dupe(u8, login);
            try self.config.save(self.io);
        },
        .denied, .expired => self.device = null,
        .slow_down => self.auth_interval += 5,
        .pending => {},
    };
    if (result.signed_out) {
        self.config.data.github_login = "";
        self.github_repositories = &.{};
        try self.config.save(self.io);
    }
    if (result.update) |update| {
        const assets = try a.alloc(updater.Asset, update.assets.len);
        for (update.assets, assets) |asset, *copy| copy.* = .{ .platform = try a.dupe(u8, asset.platform), .url = try a.dupe(u8, asset.url), .sha256 = try a.dupe(u8, asset.sha256), .filename = try a.dupe(u8, asset.filename) };
        self.update = .{ .version = try a.dupe(u8, update.version), .notes = try a.dupe(u8, update.notes), .assets = assets };
        self.message("A verified Weaver update is available in Settings.", false);
    }
    if (result.downloaded) |p| self.downloaded = try a.dupe(u8, p);
    if (result.repositories) |repos| {
        const copies = try a.alloc(github.Repository, repos.len);
        for (repos, copies) |repo, *copy| copy.* = .{ .full_name = try a.dupe(u8, repo.full_name), .clone_url = try a.dupe(u8, repo.clone_url), .ssh_url = try a.dupe(u8, repo.ssh_url), .private = repo.private, .description = if (repo.description) |d| try a.dupe(u8, d) else null };
        self.github_repositories = copies;
    }
    if (connected) if (self.snapshot) |s| try self.launch(.git, s.path, .{ .operation = .publish, .value = s.branch, .second = "origin" });
    frame_ctx.requestRedraw();
}
fn refreshDetails(self: *Self) !void {
    const snapshot = self.snapshot orelse return;
    self.generation += 1;
    self.selection += 1;
    self.counts_busy = false;
    self.preview_busy = false;
    self.preview_pending = self.page == .changes and self.selected_file < snapshot.files.len;
    self.preview_quiet = self.preview != null;
    self.preview_wait_ns = 0;
    if (snapshot.files.len > 0) try self.launchRead(.counts, snapshot.path, snapshot.files, true);
}
fn moveDiffScroll(self: *Self, previous: usize, next: usize) !void {
    const state = &self.app.main_viewport.ui_ctx.ui.state;
    inline for (.{ "diff-scroll", "diff-left-column", "diff-right-column" }) |name| {
        const sides: usize = if (std.mem.eql(u8, name, "diff-scroll")) 2 else 1;
        for (0..sides) |side| {
            const old_key = if (sides == 2) ui.Key.str(name).indexed(previous).indexed(side) else ui.Key.str(name).indexed(previous);
            const new_key = if (sides == 2) ui.Key.str(name).indexed(next).indexed(side) else ui.Key.str(name).indexed(next);
            if (state.get(.scroll, old_key.hash())) |scroll| {
                const offset = scroll.offset;
                (try state.getOrCreate(.scroll, self.a, new_key.hash())).offset = offset;
            }
        }
    }
}
fn request(self: *Self, ctx: *ui.Frame, operation: model.Operation, value: []const u8, second: []const u8) !void {
    if (!self.available()) return;
    const req = model.Request{ .operation = operation, .value = value, .second = second };
    if (model.destructive(operation)) {
        const a = self.config.arena.allocator();
        self.pending_request = .{ .operation = operation, .value = try a.dupe(u8, value), .second = try a.dupe(u8, second) };
        self.confirm_open = true;
    } else if (self.path()) |p| try self.launch(.git, p, req);
    ctx.requestRedraw();
}
/// Toolbar sync actions. Explains a missing remote, branch link or first commit
/// before Git has to fail on it.
fn sync(self: *Self, ctx: *ui.Frame, operation: model.Operation) !void {
    const snapshot = self.snapshot orelse return;
    if (!self.available()) return;
    const remote = guidance.defaultRemote(snapshot.remotes) orelse return self.openRemoteSetup(ctx);
    if (operation == .fetch or snapshot.upstream.len > 0) return self.request(ctx, operation, "", "");
    if (operation == .push and snapshot.history.len > 0) return self.request(ctx, .publish, snapshot.branch, remote);
    self.message(if (snapshot.history.len == 0) "There are no commits on this branch yet. Commit your changes first." else "This branch has not been pushed yet, so there is nothing to pull. Push it first.", false);
    ctx.requestRedraw();
}
fn openRemoteSetup(self: *Self, ctx: *ui.Frame) void {
    self.connect_input.clearRetainingCapacity();
    self.failure_open = false;
    self.remote_open = true;
    ctx.requestRedraw();
}
fn selectRepository(self: *Self, index: usize) !void {
    if (index >= self.config.data.repositories.len or !self.canNavigate()) return;
    const repository = self.config.data.repositories[index];
    self.provider = providers.byId(repository.provider) orelse {
        self.message("Install this repository's version-control provider first.", true);
        return;
    };
    self.config.data.selected = index;
    try self.config.save(self.io);
    self.page = .changes;
    self.selectFile(0);
    if (self.revision) |*s| s.deinit();
    self.revision = null;
    if (self.snapshot) |*s| s.deinit();
    self.snapshot = null;
    try self.launch(.git, repository.path, .{ .operation = .refresh });
}
fn removeRepository(self: *Self, index: usize) !void {
    if (!self.available() or index >= self.config.data.repositories.len) return;
    const selected = index == self.config.data.selected;
    self.icon_open = false;
    self.name_open = false;
    try self.config.remove(self.io, index);
    if (selected) {
        // Discard in-flight scans too, including when removing the last entry.
        // Otherwise a completed quiet refresh can add the repository back.
        self.generation += 1;
        self.counts_busy = false;
        self.preview_busy = false;
        self.background_busy = false;
        self.refresh_pending = false;
        _ = self.watch_epoch.fetchAdd(1, .release);
        self.selectFile(0);
        if (self.revision) |*s| s.deinit();
        self.revision = null;
        if (self.snapshot) |*s| s.deinit();
        self.snapshot = null;
        self.file_rows_valid = false;
        self.file_list_reset = true;
        self.selected_revision = null;
        self.preview_pending = false;
        if (self.path() != null) try self.selectRepository(self.config.data.selected);
    }
    self.message("Repository removed from the workspace. Files remain on disk.", false);
}

const ChangeActions = struct {
    app: *Self,
    index: usize,
    file: model.File,

    pub fn render(self: *const ChangeActions, ctx: *ui.Frame) anyerror!void {
        const app = self.app;
        const f = self.file;
        const ready = app.available() and !app.confirm_open;
        const conflict = std.mem.eql(u8, f.status, "Conflict");
        if (try app.menuAction(ctx, "view", .view, "View diff", true, false)) app.selectFile(self.index);
        if (try app.menuAction(ctx, "stage", if (f.staged) .unstage else .stage, if (f.staged) "Unstage file" else if (conflict) "Stage resolution" else "Stage file", ready, false))
            try app.request(ctx, if (f.staged) .unstage else .stage, f.path, if (std.mem.eql(u8, f.status, "Renamed")) f.old_path else "");
        try menuSeparator(ctx, "copy-group");
        if (try app.menuAction(ctx, "copy-relative", .copy, "Copy relative path", true, false)) try ctx.writeClipboard(f.path);
        const absolute = try std.fs.path.resolve(ctx.arena(), &.{ app.snapshot.?.path, f.path });
        if (try app.menuAction(ctx, "copy-full", .copy_full, "Copy full path", true, false)) try ctx.writeClipboard(absolute);
        // A deleted file has nothing to edit; a nested repository is listed as a folder.
        const editable = !std.mem.eql(u8, f.status, "Deleted") and !std.mem.endsWith(u8, f.path, "/");
        if (try app.menuAction(ctx, "edit", .edit, "Open in text editor", editable, false)) editor.open(app.io, app.a, absolute) catch {
            app.message("Could not open the file in your text editor.", true);
        };
        if (try app.menuAction(ctx, "reveal", .reveal, folderActionLabel(), true, false)) {
            // A deleted file's directory may have disappeared too.
            var folder = std.fs.path.dirname(absolute) orelse app.snapshot.?.path;
            while (!config_mod.equalPath(folder, app.snapshot.?.path)) {
                var dir = std.Io.Dir.cwd().openDir(app.io, folder, .{}) catch {
                    folder = std.fs.path.dirname(folder) orelse app.snapshot.?.path;
                    continue;
                };
                dir.close(app.io);
                break;
            }
            openPath(app.io, app.a, folder) catch {
                app.message("Could not open the containing folder.", true);
            };
        }
        try menuSeparator(ctx, "ignore-group");
        if (try app.menuAction(ctx, "ignore-file", .ignore_file, "Add file to .gitignore", ready and !conflict, false)) try app.ignorePath(ctx, f, .file);
        if (ignore.target(f.path, .folder)) |folder| {
            const title = try std.fmt.allocPrint(ctx.arena(), "Ignore folder {s}/", .{try shortName(ctx.arena(), std.fs.path.basenamePosix(folder))});
            if (try app.menuAction(ctx, "ignore-folder", .ignore_folder, title, ready and !conflict, false)) try app.ignorePath(ctx, f, .folder);
        }
        if (ignore.target(f.path, .extension)) |extension| {
            const title = try std.fmt.allocPrint(ctx.arena(), "Ignore all {s} files", .{try shortName(ctx.arena(), extension)});
            if (try app.menuAction(ctx, "ignore-extension", .ignore_extension, title, ready and !conflict, false)) try app.ignorePath(ctx, f, .extension);
        }
        try menuSeparator(ctx, "discard-group");
        if (try app.menuAction(ctx, "discard", .discard, "Discard changes…", ready and !f.staged and !std.mem.eql(u8, f.status, "Untracked") and !conflict, true))
            try app.request(ctx, .discard, f.path, "");
    }
};

const ProjectActions = struct {
    app: *Self,
    index: usize,

    pub fn render(self: *const ProjectActions, ctx: *ui.Frame) anyerror!void {
        const app = self.app;
        if (self.index >= app.config.data.repositories.len) return;
        const repository = app.config.data.repositories[self.index];
        const ready = app.available() and !app.confirm_open;
        const current = self.index == app.config.data.selected;
        if (try app.menuAction(ctx, "open-project", if (current) .refresh else .open, if (current) "Refresh repository" else "Open repository", ready or (app.read_busy and !app.picker_open), false)) try app.selectRepository(self.index);
        if (try app.menuAction(ctx, "open-folder", .reveal, folderActionLabel(), true, false)) openPath(app.io, app.a, repository.path) catch {
            app.message("Could not open the repository folder.", true);
        };
        const url = if (std.mem.eql(u8, repository.provider, "git")) git.repositoryWebUrl(ctx.arena(), repository.path) catch null else null;
        if (try app.menuAction(ctx, "open-remote", .open_remote, "Open remote in browser", url != null, false)) openPath(app.io, app.a, url.?) catch {
            app.message("Could not open the remote in your browser.", true);
        };
        if (try app.menuAction(ctx, "copy-project-path", .copy, "Copy repository path", true, false)) try ctx.writeClipboard(repository.path);
        if (try app.menuAction(ctx, "change-icon", .icon, "Change icon…", true, false)) app.openIconPicker(self.index);
        if (try app.menuAction(ctx, "rename-project", .rename, "Rename…", true, false)) try app.openNameDialog(.{ .repository = self.index });
        try menuSeparator(ctx, "group-group");
        for (app.config.data.groups) |group| {
            if (group.id == repository.group) continue;
            const title = try std.fmt.allocPrint(ctx.arena(), "Move to {s}", .{try shortName(ctx.arena(), group.name)});
            if (try app.menuAction(ctx, try std.fmt.allocPrint(ctx.arena(), "to-group-{d}", .{group.id}), .to_group, title, true, false)) app.pending_edit = .{ .assign = .{ .index = self.index, .group = group.id } };
        }
        if (try app.menuAction(ctx, "to-new-group", .new_group, "Move to new group…", true, false)) try app.openNameDialog(.{ .new_group = self.index });
        if (repository.group != 0) {
            if (try app.menuAction(ctx, "ungroup", .ungroup, "Remove from group", true, false)) app.pending_edit = .{ .assign = .{ .index = self.index, .group = 0 } };
        }
        try menuSeparator(ctx, "move-group");
        // An entry moves among the entries listed with it: its group, or the ungrouped ones.
        var first = self.index;
        var last = self.index;
        var previous: ?usize = null;
        var next: ?usize = null;
        for (app.config.data.repositories, 0..) |other, i| {
            if (other.group != repository.group) continue;
            first = @min(first, i);
            last = @max(last, i);
            if (i < self.index) previous = i;
            if (i > self.index and next == null) next = i;
        }
        if (try app.menuAction(ctx, "move-up", .move_up, "Move up", previous != null, false)) app.pending_edit = .{ .move = .{ self.index, previous.? } };
        if (try app.menuAction(ctx, "move-down", .move_down, "Move down", next != null, false)) app.pending_edit = .{ .move = .{ self.index, next.? } };
        if (try app.menuAction(ctx, "move-top", .move_top, "Move to top", previous != null, false)) app.pending_edit = .{ .move = .{ self.index, first } };
        if (try app.menuAction(ctx, "move-bottom", .move_bottom, "Move to bottom", next != null, false)) app.pending_edit = .{ .move = .{ self.index, last } };
        try menuSeparator(ctx, "remove-group");
        if (try app.menuAction(ctx, "remove-project", .remove, "Remove from workspace", ready, true)) try app.removeRepository(self.index);
    }
};

const GroupActions = struct {
    app: *Self,
    id: u32,

    pub fn render(self: *const GroupActions, ctx: *ui.Frame) anyerror!void {
        const app = self.app;
        const index = app.config.groupIndex(self.id) orelse return;
        const last = app.config.data.groups.len - 1;
        if (try app.menuAction(ctx, "rename-group", .rename, "Rename…", true, false)) try app.openNameDialog(.{ .group = self.id });
        if (try app.menuAction(ctx, "new-group", .new_group, "New group…", true, false)) try app.openNameDialog(.{ .new_group = null });
        try menuSeparator(ctx, "move-group");
        if (try app.menuAction(ctx, "move-up", .move_up, "Move up", index > 0, false)) app.pending_edit = .{ .move_group = .{ index, index - 1 } };
        if (try app.menuAction(ctx, "move-down", .move_down, "Move down", index < last, false)) app.pending_edit = .{ .move_group = .{ index, index + 1 } };
        if (try app.menuAction(ctx, "move-top", .move_top, "Move to top", index > 0, false)) app.pending_edit = .{ .move_group = .{ index, 0 } };
        if (try app.menuAction(ctx, "move-bottom", .move_bottom, "Move to bottom", index < last, false)) app.pending_edit = .{ .move_group = .{ index, last } };
        try menuSeparator(ctx, "remove-group");
        if (try app.menuAction(ctx, "delete-group", .remove, "Delete group", true, true)) app.pending_edit = .{ .delete_group = self.id };
    }
};

/// Appends a pattern for `file` to the root `.gitignore`, then rescans quietly
/// so the confirmation stays in the status bar.
fn ignorePath(self: *Self, ctx: *ui.Frame, file: model.File, scope: ignore.Scope) !void {
    const repository = (self.snapshot orelse return).path;
    const line = ignore.pattern(ctx.arena(), file.path, scope) catch {
        self.message("This path cannot be written as a .gitignore pattern.", true);
        return;
    };
    const added = ignore.add(self.io, ctx.arena(), repository, line) catch {
        self.message("Could not update .gitignore.", true);
        return;
    };
    // Ignore rules only hide untracked paths.
    const tracked = !std.mem.eql(u8, file.status, "Untracked");
    self.message(try std.fmt.allocPrint(ctx.arena(), "{s}{s}{s}", .{ line, if (added) " added to .gitignore." else " is already in .gitignore.", if (tracked) " Git already tracks this file, so its changes stay listed." else "" }), false);
    if (self.background_busy) self.refresh_pending = true else try self.launchInternal(.git, repository, .{ .operation = .refresh }, true);
    ctx.requestRedraw();
}
/// Keeps a menu label on one line.
fn shortName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const safe = try diff.safeText(a, name);
    if (safe.len <= 22) return safe;
    var end: usize = 20;
    while (end > 0 and (safe[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}…", .{safe[0..end]});
}

fn folderActionLabel() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "Show in File Explorer",
        .macos => "Show in Finder",
        else => "Open folder",
    };
}

fn openContextMenu(self: *Self, ctx: *ui.Frame, menu: anytype) !void {
    _ = try menu.open(ctx);
    const state = ctx.ui().state.get(.context_menu, menu.key.hash()).?;
    // Respect the hit-tested target and scroll clipping, including a popup
    // covering another row. Only one target's menu can be open at a time.
    if (ctx.ui().input.mouseButton(.right).pressed and !ctx.ui().isHoveredWithin(menu.key.hash()) and !ctx.ui().isHoveredWithin(menu.key.indexed(1).hash())) state.open = false;
    if (state.open) {
        if (self.active_context) |previous| if (previous.hash() != menu.key.hash()) {
            if (ctx.ui().state.get(.context_menu, previous.hash())) |old| old.open = false;
        };
        self.active_context = menu.key;
    }
}
fn menuAction(self: *Self, ctx: *ui.Frame, key: []const u8, icon: icons.Menu, title: []const u8, enabled: bool, danger: bool) !bool {
    // Menu keys are scoped to their target, so rows from separate menus never share focus.
    const parent = ctx.ui().layout_ctx.pool.elements.items[ctx.ui().currentSlot()].id;
    const item = ui.Key.str(key).indexed(parent);
    const tint: ui.Color.Input = if (danger) .@"error" else .text;
    const b = Button{ .key = item, .disabled = !enabled, .style = &.{ .width = .grow(), .height = .fixed(menu_row_height), .justify = .start, .@"align" = .center, .padding = .xy(9, 0), .gap = 10, .radius = .{ .fixed = 6 }, .font_size = .sm, .background = .transparent, .foreground = tint, .hover = &.{ .background = .muted, .state_layer = 0 }, .active = &.{ .background = .toned, .state_layer = 0 } } };
    const result = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(result.id, .{ .role = .button, .name = title, .state = .{ .disabled = !enabled } });
    try ctx.e(Text{ .key = item.indexed(1), .content = icon.glyph(), .selectable = false, .style = &.{ .width = .fixed(16), .font = "lucide", .font_size = .{ .px = 15 }, .foreground = if (danger) .@"error" else .dimmed } });
    try ctx.e(Text{ .key = item.indexed(2), .content = title, .selectable = false, .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden } });
    try b.close(ctx);
    if (result.clicked) {
        if (self.active_context) |menu| if (ctx.ui().state.get(.context_menu, menu.hash())) |state| {
            state.open = false;
        };
        self.active_context = null;
        ctx.requestRedraw();
    }
    return result.clicked;
}
/// A hairline between groups of menu rows. It is not a click target.
fn menuSeparator(ctx: *ui.Frame, key: []const u8) !void {
    const parent = ctx.ui().layout_ctx.pool.elements.items[ctx.ui().currentSlot()].id;
    const item = ui.Key.str(key).indexed(parent);
    const inset = Rect{ .key = item, .style = comptime &.{ .width = .grow(), .height = .fixed(9), .padding = .xy(4, 4) } };
    _ = try inset.open(ctx);
    try ctx.e(Rect{ .key = item.indexed(1), .style = comptime &.{ .width = .grow(), .height = .fixed(1), .background = .muted } });
    try inset.close(ctx);
}
fn frame(view: *knots.View, ctx: *ui.Frame) !void {
    const self = of(view);
    if (self.capture_path == null or self.capture_delay_ns > 0) try self.automaticFetch();
    if (self.refresh_pending and !self.background_busy and !self.counts_busy and !self.preview_busy and !self.preview_pending and
        self.config.data.auto_refresh and self.available() and !self.confirm_open and !self.add_open and self.page == .changes and self.snapshot != null)
    {
        if (self.path()) |p| {
            try self.launchInternal(.git, p, .{ .operation = .refresh }, true);
            self.refresh_pending = false;
        }
    }
    // Dispatch from the frame: continuously animated Windows frames can keep
    // the native message batch open and postpone the main-thread idle hook.
    if (self.preview_pending and self.available() and self.page == .changes) {
        self.preview_wait_ns += ctx.input().delta_ns;
        if (self.preview_wait_ns >= 75 * std.time.ns_per_ms) {
            self.preview_pending = false;
            if (self.snapshot) |snapshot| if (self.selected_file < snapshot.files.len) try self.launchRead(.preview, snapshot.path, &.{snapshot.files[self.selected_file]}, self.preview_quiet);
        }
    }
    if (!self.picker_open and (self.busy or self.fetch_busy or (self.counts_busy and !self.counts_quiet) or (self.preview_busy and !self.preview_quiet) or self.preview_pending)) {
        self.loading_ns += ctx.input().delta_ns;
        ctx.requestRedraw();
    }
    const extent = ctx.input().logical_extent;
    const root = Rect{ .key = .str("root"), .style = &.{ .width = .fixed(@floatFromInt(extent.width)), .height = .fixed(@floatFromInt(extent.height)), .direction = .column, .background = .bg, .font_size = .sm, .padding = .all(root_padding), .gap = 8 } };
    _ = try root.open(ctx);
    const body = Rect{ .key = .str("body"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row, .gap = 10 } };
    _ = try body.open(ctx);
    try self.sidebar(ctx);
    const main = Rect{ .key = .str("main"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 10 } };
    _ = try main.open(ctx);
    try self.toolbar(ctx);
    if (self.snapshot) |snapshot| {
        if (snapshot.state != .normal) try self.recovery(ctx, snapshot) else if (self.provider.capabilities.remotes and !self.read_busy and (self.page == .changes or self.page == .history)) try self.nextStep(ctx, snapshot);
    }
    switch (self.page) {
        .changes, .history => try self.worktree(ctx),
        .operations => try self.operations(ctx),
        .github => try self.githubPage(ctx),
        .extensions => try self.extensions(ctx),
        .settings => try self.settings(ctx),
    }
    try main.close(ctx);
    try body.close(ctx);
    const status = Rect{ .key = .str("status"), .style = &.{ .width = .grow(), .height = .fixed(24), .padding = .xy(8, 0), .direction = .row, .gap = 16, .@"align" = .center } };
    _ = try status.open(ctx);
    const activity = if (self.git_installing) "Installing Git…" else if (self.busy) (if (self.read_busy) "Scanning changes…" else "Working…") else if (self.fetch_busy) "Fetching…" else if (self.counts_busy and !self.counts_quiet) "Counting changes…" else if ((self.preview_busy or self.preview_pending) and !self.preview_quiet) "Loading diff…" else "Ready";
    try ctx.ui().setAccessibility(status.key.hash(), .{ .role = .generic, .name = activity });
    try label(ctx, "status-label", activity, .dimmed);
    if (self.snapshot) |snapshot| if (snapshot.remotes.len > 0) {
        const last_fetched = self.config.data.repositories[self.config.data.selected].last_fetched;
        try label(ctx, "last-fetched", try remote_sync.fetchedLabel(ctx.arena(), last_fetched, std.Io.Clock.real.now(self.io).toSeconds()), .dimmed);
    };
    const notice_line = std.mem.sliceTo(std.mem.trim(u8, self.notice, " \t\r\n"), '\n');
    try ctx.e(Text{ .key = .str("notice"), .content = try diff.safeText(ctx.arena(), notice_line), .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden, .foreground = if (self.notice_error) .@"error" else .dimmed, .font_size = .xs } });
    try self.gitStatus(ctx);
    try label(ctx, "version", "Weaver " ++ options.version, .dimmed);
    try status.close(ctx);
    try self.dragGhost(ctx);
    try root.close(ctx);
    try self.dialogs(ctx);
    if (self.available()) {
        for (ctx.droppedPaths()) |p| {
            self.path_input.clearRetainingCapacity();
            try self.path_input.appendSlice(self.a, p);
            self.remote_input.clearRetainingCapacity();
            try self.openLocal(p);
            break;
        }
        if (ctx.ui().input.keyPressed(.f5)) if (self.path()) |p| try self.launch(.git, p, .{ .operation = .refresh });
    }
    if (self.device != null) {
        self.auth_elapsed_ns += ctx.input().delta_ns;
        self.auth_poll_ns += ctx.input().delta_ns;
        if (self.auth_elapsed_ns / std.time.ns_per_s >= self.device.?.expires_in) {
            self.device = null;
            self.message("GitHub sign-in expired.", true);
        } else if (self.available() and self.auth_poll_ns / std.time.ns_per_s >= self.auth_interval) {
            self.auth_poll_ns = 0;
            try self.launch(.auth_poll, "", .{ .operation = .refresh });
        }
        ctx.requestRedraw();
    }
    if (self.capture_path) |capture| {
        self.capture_frames += 1;
        self.capture_elapsed_ns += ctx.input().delta_ns;
        self.capture_ready_frames = if (self.busy or self.preview_busy or self.preview_pending or self.counts_busy) 0 else self.capture_ready_frames + 1;
        if (self.capture_ready_frames > 8 and self.capture_elapsed_ns >= self.capture_delay_ns and !self.capture_requested) {
            try self.app.requestReadback(view.id, self.a);
            self.capture_requested = true;
        }
        if (try self.app.takeReadback(view.id)) |readback_value| {
            var readback = readback_value;
            defer readback.deinit();
            var output: std.Io.Writer.Allocating = .init(self.a);
            defer output.deinit();
            try output.writer.print("P6\n{d} {d}\n255\n", .{ readback.width, readback.height });
            const bgra = readback.format == .bgra8 or readback.format == .bgra8_srgb;
            for (0..readback.height) |y| for (0..readback.width) |x| {
                const offset = y * readback.bytes_per_row + x * 4;
                const rgba = readback.bytes[offset..][0..4];
                const rgb = [3]u8{ rgba[if (bgra) @as(usize, 2) else 0], rgba[1], rgba[if (bgra) @as(usize, 0) else 2] };
                try output.writer.writeAll(&rgb);
            };
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = capture, .data = output.written() });
            ctx.requestClose();
        }
        if (self.capture_elapsed_ns > 60 * std.time.ns_per_s) return error.CaptureTimedOut;
        ctx.requestRedraw();
    }
}
fn sidebar(self: *Self, ctx: *ui.Frame) !void {
    const panel = Rect{ .key = .str("sidebar"), .style = &.{ .width = .fixed(212), .height = .grow(), .direction = .column, .padding = .all(10), .gap = 2, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try panel.open(ctx);
    const brand = Rect{ .key = .str("brand-row"), .style = &.{ .direction = .row, .gap = 10, .@"align" = .center, .padding = .xy(6, 10) } };
    _ = try brand.open(ctx);
    try brand_badge.render(ctx);
    try ctx.e(Text{ .key = .str("brand"), .content = "weaver", .style = &.{ .font_size = .lg, .foreground = .text } });
    try brand.close(ctx);
    try sectionLabel(ctx, "workspace-label", "Workspace");
    inline for (.{ .{ Page.changes, "\u{e86f}  Changes" }, .{ Page.history, "\u{e889}  History" }, .{ Page.operations, "\u{e8d4}  Repository" } }) |entry| {
        if (try nav(ctx, entry[1], self.page == entry[0], self.canNavigate())) {
            self.page = entry[0];
            self.clearDiffRows();
            if (self.page == .changes) self.selectFile(if (self.snapshot) |s| @min(self.selected_file, if (s.files.len == 0) 0 else s.files.len - 1) else 0);
            ctx.requestRedraw();
        }
    }
    try space(ctx, "repo-gap", 10);
    try sectionLabel(ctx, "repos-label", "Repositories");
    const repos = Rect{ .key = .str("repositories"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .overflow = .scroll_y } };
    _ = try repos.open(ctx);
    // The scrolled column: its box places the rows a drag lands between.
    const list = Rect{ .key = .str("repository-rows"), .style = comptime &.{ .width = .grow(), .direction = .column, .gap = row_gap } };
    _ = try list.open(ctx);
    const view = (try ctx.ui().state.getOrCreate(.measured, ctx.ui().allocator, repos.key.hash())).box;
    const base = (try ctx.ui().state.getOrCreate(.measured, ctx.ui().allocator, list.key.hash())).box;
    // Groups come first, each followed by its entries, then the ungrouped entries.
    var rows = try sidebar_drag.entries(ctx.arena(), &self.config.data, if (self.drag) |drag| drag.item else null);
    if (self.drag) |drag| {
        const exists = switch (drag.item) {
            .repository => |index| index < self.config.data.repositories.len,
            .group => |id| self.config.groupIndex(id) != null,
        };
        // The list changed under the drag; put everything back.
        if (!exists or rows.len + 1 != drag.gaps.len) {
            self.endDrag();
            rows = try sidebar_drag.entries(ctx.arena(), &self.config.data, null);
        }
    }
    const landed = if (self.drag) |*drag| self.moveDrag(ctx, drag, rows, .{ view.x(), view.y(), view.w(), view.h() }, .{ base.x(), base.y() }) else false;
    const pointer = ctx.ui().input.mouse_pos;
    const strip_at = sidebar_drag.groupedRows(&self.config.data, rows);
    for (rows, 0..) |entry, row_index| {
        if (self.drag) |*drag| {
            try dragGap(ctx, drag, row_index);
            if (row_index == strip_at) try self.dragStrip(ctx, drag);
        }
        // Where a press on this row would hold it while it is dragged.
        const grab = [2]f32{ @as(f32, @floatCast(pointer[0])) - base.x(), @as(f32, @floatCast(pointer[1])) - base.y() - row_pitch * @as(f32, @floatFromInt(row_index)) };
        switch (entry) {
            .group => |group| {
                const menu = ui.component.ContextMenu(GroupActions){ .key = ui.Key.str("group-context").indexed(group.id), .menu = .{ .app = self, .id = group.id }, .style = &.{ .width = .grow(), .height = .fixed(nav_height) }, .parts = .{ .popup = &menu_popup } };
                try self.openContextMenu(ctx, &menu);
                if (self.pressedRow(ctx, menu.key)) self.drag_press = .{ .item = .{ .group = group.id }, .grab = grab, .width = base.w() };
                if (try groupRow(ctx, group)) self.pending_edit = .{ .toggle_group = group.id };
                try menu.close(ctx);
            },
            .repository => |i| {
                const repository = self.config.data.repositories[i];
                const menu = ui.component.ContextMenu(ProjectActions){ .key = ui.Key.str("project-context").indexed(ui.Key.str(repository.path).hash()), .menu = .{ .app = self, .index = i }, .style = &.{ .width = .grow(), .height = .fixed(nav_height) }, .parts = .{ .popup = &menu_popup } };
                try self.openContextMenu(ctx, &menu);
                if (self.pressedRow(ctx, menu.key)) self.drag_press = .{ .item = .{ .repository = i }, .grab = grab, .width = base.w() };
                if (try self.repositoryRow(ctx, i, repository)) try self.selectRepository(i);
                const old_count = self.config.data.repositories.len;
                try menu.close(ctx);
                // Removal changes the workspace list; rebuild it on the next frame.
                if (self.config.data.repositories.len != old_count) break;
            },
        }
    }
    if (self.drag) |*drag| {
        try dragGap(ctx, drag, rows.len);
        if (rows.len == strip_at) try self.dragStrip(ctx, drag);
    }
    try list.close(ctx);
    try repos.close(ctx);
    if (landed) {
        try self.dropDrag();
        ctx.requestRedraw();
    } else if (self.drag == null) if (self.drag_press) |press| {
        // A press becomes a drag once the pointer has travelled.
        if (!ctx.ui().input.mouseButton(.left).down) self.drag_press = null else if (ctx.ui().state.press_drag) try self.liftDrag(ctx, press);
    };
    if (self.pending_edit) |edit| {
        self.pending_edit = null;
        switch (edit) {
            .move => |move| try self.config.move(self.io, move[0], move[1]),
            .move_group => |move| try self.config.moveGroup(self.io, move[0], move[1]),
            .assign => |assign| {
                try self.config.setGroup(self.io, assign.index, assign.group);
                // Keep the moved entry in view.
                try self.config.setCollapsed(self.io, assign.group, false);
            },
            .delete_group => |id| {
                try self.config.removeGroup(self.io, id);
                self.message("Group deleted. Its repositories stay in the workspace.", false);
            },
            .toggle_group => |id| if (self.config.groupIndex(id)) |index| try self.config.setCollapsed(self.io, id, !self.config.data.groups[index].collapsed),
        }
        ctx.requestRedraw();
    }
    if (try navKey(ctx, .str("add-repo"), "\u{e145}  Add repository", false, self.available())) {
        self.remote_input.clearRetainingCapacity();
        try self.browse(.folder, &self.path_input, false, "Choose a repository folder");
        ctx.requestRedraw();
    }
    if (try navKey(ctx, .str("add-group"), "\u{e2cc}  New group", false, true)) try self.openNameDialog(.{ .new_group = null });
    try ctx.e(Rect{ .key = .str("sidebar-divider"), .style = comptime &.{ .width = .grow(), .height = .fixed(9), .border_width = .edges(0, 0, 1, 0), .border_color = .muted } });
    try space(ctx, "sidebar-divider-gap", 6);
    if (self.registry.enabled("weaver.github")) {
        if (try nav(ctx, "\u{e2bd}  GitHub", self.page == .github, true)) self.page = .github;
    }
    if (try nav(ctx, "\u{e87b}  Extensions", self.page == .extensions, true)) self.page = .extensions;
    if (try nav(ctx, "\u{e8b8}  Settings", self.page == .settings, true)) self.page = .settings;
    try panel.close(ctx);
}
/// Whether this frame's press landed on a sidebar row rather than on its open menu.
fn pressedRow(self: *Self, ctx: *ui.Frame, menu: ui.Key) bool {
    return self.drag == null and ctx.ui().leftPressed(menu.hash(), .within) and !ctx.ui().isHoveredWithin(menu.indexed(1).hash());
}
/// Lifts a pressed row out of the list. The space it leaves starts fully open.
fn liftDrag(self: *Self, ctx: *ui.Frame, press: DragPress) !void {
    const data = &self.config.data;
    const rows = try sidebar_drag.entries(ctx.arena(), data, press.item);
    const home = sidebar_drag.origin(data, rows, press.item);
    const gaps = try self.a.alloc(f32, rows.len + 1);
    @memset(gaps, 0);
    // An entry already under the groups rests where the strip appears.
    if (!home.strip) gaps[home.slot] = row_pitch * @as(f32, @floatFromInt(sidebar_drag.span(data, press.item)));
    const pointer = ctx.ui().input.mouse_pos;
    self.drag = .{ .item = press.item, .grab = press.grab, .origin = home, .drop = home, .pos = .{ @as(f32, @floatCast(pointer[0])) - press.grab[0], @as(f32, @floatCast(pointer[1])) - press.grab[1] }, .width = press.width, .indent = if (home.indent) 1 else 0, .strip = if (home.strip) row_pitch else 0, .gaps = gaps };
    self.drag_press = null;
    ctx.requestRedraw();
}
fn endDrag(self: *Self) void {
    if (self.drag) |drag| self.a.free(drag.gaps);
    self.drag = null;
}
/// Advances the drag by a frame: the lifted row follows the pointer, the gap
/// follows the row, and a released row glides to its gap. True once it is there.
fn moveDrag(self: *Self, ctx: *ui.Frame, drag: *Drag, rows: []const sidebar_drag.Entry, view: [4]f32, base: [2]f32) bool {
    const input = &ctx.ui().input;
    const pointer = [2]f32{ @floatCast(input.mouse_pos[0]), @floatCast(input.mouse_pos[1]) };
    const elapsed_ms = @as(f32, @floatFromInt(@min(ctx.input().delta_ns, 50 * std.time.ns_per_ms))) / std.time.ns_per_ms;
    const step = 1 - @exp(-elapsed_ms / 28);
    if (!drag.released) {
        drag.pos = .{ pointer[0] - drag.grab[0], pointer[1] - drag.grab[1] };
        // Away from the list the row goes back where it came from.
        const reach = 28;
        const over = pointer[0] >= view[0] - reach and pointer[0] <= view[0] + view[2] + reach and pointer[1] >= view[1] - reach and pointer[1] <= view[1] + view[3] + reach;
        const cancelled = input.keyPressed(.escape) or input.focus_lost or input.pointer_cancelled;
        drag.drop = if (over and !cancelled) sidebar_drag.target(&self.config.data, rows, drag.item, (drag.pos[1] + nav_height / 2 - base[1]) / row_pitch, drag.strip / row_pitch) else drag.origin;
        if (cancelled or !input.mouseButton(.left).down) drag.released = true;
    }
    var settled = drag.released;
    if (drag.released) {
        // Ungrouped rows sit below the strip for as long as it is shown.
        const below_strip = drag.item == .repository and !drag.drop.indent and !drag.drop.strip;
        const place = [2]f32{ base[0], base[1] + row_pitch * @as(f32, @floatFromInt(drag.drop.slot)) + if (below_strip) drag.strip else 0 };
        for (&drag.pos, place) |*at, goal| {
            at.* += (goal - at.*) * step;
            if (@abs(goal - at.*) > 0.75) settled = false;
        }
    }
    drag.lift += ((if (drag.released) @as(f32, 0) else 1) - drag.lift) * step;
    drag.indent += ((if (drag.drop.indent) @as(f32, 1) else 0) - drag.indent) * step;
    // A released group makes room for its entries before they reappear.
    const open: f32 = if (drag.released) @floatFromInt(sidebar_drag.span(&self.config.data, drag.item)) else 1;
    for (drag.gaps, 0..) |*gap, slot| {
        const goal = if (slot == drag.drop.slot and !drag.drop.strip) open * row_pitch else 0;
        gap.* += (goal - gap.*) * step;
        if (@abs(goal - gap.*) > 0.75) settled = false;
    }
    // The strip shows for a carried entry and stays for one dropped on it.
    const shown = drag.item == .repository and self.config.data.groups.len > 0 and (!drag.released or drag.drop.strip);
    const strip_goal: f32 = if (shown) row_pitch else 0;
    drag.strip += (strip_goal - drag.strip) * step;
    if (@abs(strip_goal - drag.strip) > 0.75) settled = false;
    ctx.requestRedraw();
    return settled;
}
/// Applies a finished drag to the workspace.
fn dropDrag(self: *Self) !void {
    const drag = self.drag.?;
    defer self.endDrag();
    if (drag.drop.same(drag.origin)) return;
    switch (drag.drop.place) {
        .repository => |place| {
            try self.config.place(self.io, drag.item.repository, place.group, place.before);
            // Show the entry where it was dropped.
            if (self.config.groupIndex(place.group)) |index| if (self.config.data.groups[index].collapsed) try self.config.setCollapsed(self.io, place.group, false);
        },
        .group => |to| try self.config.moveGroup(self.io, self.config.groupIndex(drag.item.group).?, to),
    }
}
/// The space held open at a slot, outlined where the lifted row would land.
fn dragGap(ctx: *ui.Frame, drag: *const Drag, slot: usize) !void {
    // The list's own spacing follows every element.
    const height = drag.gaps[slot] - row_gap;
    if (height < 1) return;
    const key = ui.Key.str("drag-gap").indexed(slot);
    const space_rect = Rect{ .key = key, .style = &.{ .width = .grow(), .height = .fixed(height), .padding = .init(0, 0, 0, 14 * drag.indent), .overflow = .hidden } };
    _ = try space_rect.open(ctx);
    if (slot == drag.drop.slot) try ctx.e(Rect{ .key = key.indexed(1), .style = &.{ .width = .grow(), .height = .fixed(@min(height, nav_height)), .radius = .md, .background = themes.selection(ctx.ui().theme), .border_width = .all(1), .border_color = .accent, .opacity = 0.55 } });
    try space_rect.close(ctx);
}
/// The strip under the groups: an entry dropped on it leaves its group.
fn dragStrip(self: *Self, ctx: *ui.Frame, drag: *const Drag) !void {
    const height = drag.strip - row_gap;
    if (height < 1) return;
    const key = ui.Key.str("drag-strip");
    const space_rect = Rect{ .key = key, .style = &.{ .width = .grow(), .height = .fixed(height), .overflow = .hidden } };
    _ = try space_rect.open(ctx);
    const on = drag.drop.strip;
    const outline = Rect{ .key = key.indexed(1), .style = &.{ .width = .grow(), .height = .fixed(@min(height, nav_height)), .justify = .center, .@"align" = .center, .radius = .md, .background = if (on) themes.selection(ctx.ui().theme) else .transparent, .border_width = .all(1), .border_color = if (on) .accent else .toned } };
    _ = try outline.open(ctx);
    const grouped = drag.item == .repository and self.config.data.repositories[drag.item.repository].group != 0;
    try ctx.e(Text{ .key = key.indexed(2), .content = if (grouped) "Drop here to ungroup" else "Ungrouped", .selectable = false, .style = &.{ .wrap = false, .font_size = .xs, .foreground = .dimmed } });
    try outline.close(ctx);
    try space_rect.close(ctx);
}
/// The lifted row, drawn over the window at the pointer.
fn dragGhost(self: *Self, ctx: *ui.Frame) !void {
    const drag = self.drag orelse return;
    const key = ui.Key.str("drag-ghost");
    const group = drag.item == .group;
    const line = Rect{ .key = key, .style = &.{ .position = .absolute, .offset = .{ drag.pos[0] - root_padding + 4 * drag.lift, drag.pos[1] - root_padding - 2 * drag.lift }, .width = .fixed(drag.width), .height = .fixed(nav_height), .direction = .row, .@"align" = .center, .gap = if (group) 6 else 0, .padding = .init(0, 8, 0, if (group) 10 else 4 + 14 * drag.indent), .radius = .md, .background = .toned, .border_width = .all(1), .border_color = .accent, .foreground = .text, .font_size = .sm, .overflow = .hidden, .opacity = 0.8 + 0.15 * drag.lift } };
    _ = try line.open(ctx);
    switch (drag.item) {
        .group => |id| {
            const entry = self.config.data.groups[self.config.groupIndex(id).?];
            try ctx.e(Text{ .key = key.indexed(1), .content = if (entry.collapsed) icons.group_closed else icons.group_open, .selectable = false, .style = &.{ .width = .fixed(14), .font = "lucide", .font_size = .{ .px = 14 } } });
            try ctx.e(Text{ .key = key.indexed(2), .content = try diff.safeText(ctx.arena(), entry.name), .selectable = false, .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden } });
        },
        .repository => |index| {
            const repository = self.config.data.repositories[index];
            const icon = Rect{ .key = key.indexed(3), .style = comptime &.{ .width = .fixed(26), .height = .fixed(26), .justify = .center, .@"align" = .center } };
            _ = try icon.open(ctx);
            if (icons.find(self.lucide, repository.icon) orelse icons.find(self.lucide, icons.default_project)) |glyph|
                try ctx.e(Text{ .key = key.indexed(1), .content = glyph.text(), .selectable = false, .style = &.{ .font = "lucide", .font_size = .{ .px = 15 }, .foreground = if (projectTint(ctx, repository.icon_color)) |color| .{ .color = color } else null } });
            try icon.close(ctx);
            try ctx.e(Text{ .key = key.indexed(2), .content = try diff.safeText(ctx.arena(), repository.label()), .selectable = false, .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden, .padding = .xy(6, 0) } });
        },
    }
    try line.close(ctx);
}
/// A workspace entry: the icon opens its picker, the name selects the repository.
fn repositoryRow(self: *Self, ctx: *ui.Frame, i: usize, repository: config_mod.Repository) !bool {
    const active = self.config.data.selected == i;
    const name = try diff.safeText(ctx.arena(), repository.label());
    const line = Rect{ .key = ui.Key.str("repository-row").indexed(i), .style = &.{ .width = .grow(), .height = .fixed(nav_height), .direction = .row, .@"align" = .center, .padding = .init(0, 0, 0, if (repository.group != 0) 18 else 4), .radius = .md, .background = if (active) themes.selection(ctx.ui().theme) else .transparent } };
    _ = try line.open(ctx);
    const icon_key = ui.Key.str("repository-icon").indexed(i);
    const icon_button = Button{ .key = icon_key, .style = &.{ .width = .fixed(26), .height = .fixed(26), .padding = .all(0), .radius = .{ .fixed = 6 }, .background = .transparent, .foreground = if (active) .text else .dimmed, .hover = &.{ .background = .toned, .state_layer = 0 }, .active = &.{ .background = .muted, .state_layer = 0 } } };
    const icon_response = try icon_button.openResponse(ctx);
    try ctx.ui().setAccessibility(icon_response.id, .{ .role = .button, .name = try std.fmt.allocPrint(ctx.arena(), "Change icon for {s}", .{name}) });
    if (icons.find(self.lucide, repository.icon) orelse icons.find(self.lucide, icons.default_project)) |glyph|
        try ctx.e(Text{ .key = icon_key.indexed(1), .content = glyph.text(), .selectable = false, .style = &.{ .font = "lucide", .font_size = .{ .px = 15 }, .foreground = if (projectTint(ctx, repository.icon_color)) |color| .{ .color = color } else null } });
    try icon_button.close(ctx);
    if (icon_response.clicked) self.openIconPicker(i);
    const key = ui.Key.str("repository-nav").indexed(i);
    const b = Button{ .key = key, .disabled = !self.canNavigate(), .style = &.{ .width = .grow(), .height = .fixed(nav_height), .justify = .start, .padding = .xy(6, 5), .radius = .md, .font_size = .sm, .background = .transparent, .foreground = if (active) .text else .dimmed } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = name, .state = .{ .disabled = !self.canNavigate() } });
    try truncatedLabel(ctx, key.indexed(10), name);
    try b.close(ctx);
    try line.close(ctx);
    return response.clicked;
}
/// A group heading; clicking it shows or hides the group's entries.
fn groupRow(ctx: *ui.Frame, group: config_mod.Group) !bool {
    const name = try diff.safeText(ctx.arena(), group.name);
    const key = ui.Key.str("group-row").indexed(group.id);
    const b = Button{ .key = key, .style = &.{ .width = .grow(), .height = .fixed(nav_height), .justify = .start, .@"align" = .center, .padding = .xy(10, 5), .gap = 6, .radius = .md, .font_size = .sm, .background = .transparent, .foreground = .dimmed } };
    const response = try b.openResponse(ctx);
    // A button offers assistive tools no expand action, so the name carries the state.
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = if (group.collapsed) try std.fmt.allocPrint(ctx.arena(), "{s}, collapsed", .{name}) else name });
    try ctx.e(Text{ .key = key.indexed(1), .content = if (group.collapsed) icons.group_closed else icons.group_open, .selectable = false, .style = &.{ .width = .fixed(14), .font = "lucide", .font_size = .{ .px = 14 } } });
    try truncatedLabel(ctx, key.indexed(10), name);
    try b.close(ctx);
    return response.clicked;
}
/// The sidebar name of a workspace path, or its folder name when it is not listed.
fn displayName(self: *Self, path_value: []const u8) []const u8 {
    for (self.config.data.repositories) |repository| if (config_mod.equalPath(repository.path, path_value)) return repository.label();
    return std.fs.path.basename(std.mem.trimEnd(u8, path_value, "/\\"));
}
fn openNameDialog(self: *Self, target: NameTarget) !void {
    self.name_input.clearRetainingCapacity();
    switch (target) {
        .repository => |index| try self.name_input.appendSlice(self.a, self.config.data.repositories[index].label()),
        .group => |id| try self.name_input.appendSlice(self.a, self.config.data.groups[self.config.groupIndex(id).?].name),
        .new_group => {},
    }
    self.name_target = target;
    self.name_focus = true;
    self.name_open = true;
}
/// Names a group, or gives a workspace entry an alias. Nothing on disk is renamed.
fn nameDialog(self: *Self, ctx: *ui.Frame) !void {
    const repositories = self.config.data.repositories;
    switch (self.name_target) {
        .repository => |index| if (index >= repositories.len) {
            self.name_open = false;
        },
        .group => |id| if (self.config.groupIndex(id) == null) {
            self.name_open = false;
        },
        .new_group => |member| if (member) |index| if (index >= repositories.len) {
            self.name_open = false;
        },
    }
    if (!self.name_open) return;
    const dialog = ui.component.Dialog{ .key = .str("name-dialog"), .is_open = &self.name_open, .style = &.{ .width = .fixed(460), .gap = 14 } };
    _ = try dialog.open(ctx);
    var placeholder: []const u8 = "Group name";
    switch (self.name_target) {
        .repository => |index| {
            placeholder = std.fs.path.basename(std.mem.trimEnd(u8, repositories[index].path, "/\\"));
            try heading(ctx, "Rename project", "This changes the name shown in Weaver. The folder on disk keeps its name.");
        },
        .group => try heading(ctx, "Rename group", "Choose a new name for this group."),
        .new_group => |member| try heading(ctx, "New group", if (member) |index| try std.fmt.allocPrint(ctx.arena(), "Name the group to move {s} into.", .{repositories[index].label()}) else "Groups are folders in the sidebar for your repositories."),
    }
    const input_key = ui.Key.str("name-input");
    // Read Enter first: the focused field consumes the frame's keys.
    const enter = ctx.ui().focused(input_key.hash()) and (ctx.ui().input.keyPressed(.enter) or ctx.ui().input.keyPressed(.kp_enter));
    try ctx.e(TextInput{ .key = input_key, .buf = &self.name_input, .bytes_max = config_mod.name_bytes_max, .placeholder = try diff.safeText(ctx.arena(), placeholder), .style = &.{ .width = .grow(), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    if (self.name_focus) {
        self.name_focus = false;
        ctx.ui().state.focused = input_key.hash();
        // Select the current name so typing replaces it.
        const edit = try ctx.ui().state.getOrCreate(.text_input, ctx.ui().allocator, input_key.hash());
        edit.sel_anchor = 0;
        edit.cursor = @intCast(self.name_input.items.len);
        ctx.requestRedraw();
    }
    const name = std.mem.trim(u8, self.name_input.items, " \t");
    // An empty project name goes back to the folder name; a group needs one.
    const ready = name.len > 0 or self.name_target == .repository;
    const entered = ready and enter;
    const actions = try row(ctx, "name-actions");
    if (try button(ctx, "name-save", if (self.name_target == .new_group) "Create" else "Save", ready, true) or entered) {
        switch (self.name_target) {
            .repository => |index| try self.config.rename(self.io, index, if (std.mem.eql(u8, name, placeholder)) "" else name),
            .group => |id| try self.config.renameGroup(self.io, id, name),
            .new_group => |member| {
                const id = try self.config.addGroup(self.io, name);
                if (member) |index| try self.config.setGroup(self.io, index, id);
            },
        }
        self.name_open = false;
    }
    if (self.name_target == .repository and repositories[self.name_target.repository].name.len > 0) {
        if (try button(ctx, "name-reset", "Use folder name", true, false)) {
            try self.config.rename(self.io, self.name_target.repository, "");
            self.name_open = false;
        }
    }
    if (try button(ctx, "name-cancel", "Cancel", true, false)) self.name_open = false;
    // Enter closes the dialog without a pointer event to draw the next frame.
    if (!self.name_open) ctx.requestRedraw();
    try actions.close(ctx);
    _ = try dialog.closeResponse(ctx);
}
fn openIconPicker(self: *Self, index: usize) void {
    self.icon_target = index;
    self.icon_filter.clearRetainingCapacity();
    self.icon_open = true;
}
/// A saved project color, darkened on light themes like the file icons.
/// Null for the default or an unreadable value.
fn projectTint(ctx: *ui.Frame, hex: []const u8) ?ui.Color {
    var color = ui.Color.hex(hex) catch return null;
    if (ctx.ui().theme.elevated.value[0] > 0.5) for (0..3) |i| {
        color.value[i] *= 0.55;
    };
    return color;
}
const IconRow = struct {
    app: *Self,
    glyphs: []const *const icons.Glyph,
};
fn renderIconRow(ctx: *ui.Frame, item: IconRow, row_index: usize) !void {
    const self = item.app;
    if (self.icon_target >= self.config.data.repositories.len) return;
    const repository = self.config.data.repositories[self.icon_target];
    const current = if (icons.find(self.lucide, repository.icon) != null) repository.icon else icons.default_project;
    const tint = projectTint(ctx, repository.icon_color);
    const line = Rect{ .key = ui.Key.str("icon-row").indexed(row_index), .style = comptime &.{ .width = .grow(), .height = .fixed(icon_cell), .direction = .row } };
    _ = try line.open(ctx);
    for (item.glyphs) |glyph| {
        const key = ui.Key.str("icon-choice").indexed(ui.Key.str(glyph.name).hash());
        const selected = std.mem.eql(u8, glyph.name, current);
        const b = Button{ .key = key, .style = &.{ .width = .fixed(icon_cell), .height = .fixed(icon_cell), .padding = .all(0), .radius = .{ .fixed = 8 }, .background = if (selected) .muted else .transparent, .border_width = .all(1), .border_color = if (selected) .accent else .transparent, .foreground = if (tint) |color| .{ .color = color } else .text, .hover = &.{ .background = .muted, .state_layer = 0 }, .active = &.{ .background = .toned, .state_layer = 0 } } };
        const response = try b.openResponse(ctx);
        try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = glyph.name });
        try ctx.e(Text{ .key = key.indexed(1), .content = glyph.text(), .selectable = false, .style = &.{ .font = "lucide", .font_size = .{ .px = 18 } } });
        try b.close(ctx);
        if (response.hovered) self.icon_hover = glyph.name;
        if (response.clicked) {
            try self.config.setIcon(self.io, self.icon_target, glyph.name, repository.icon_color);
            ctx.requestRedraw();
        }
    }
    try line.close(ctx);
}
fn swatch(ctx: *ui.Frame, key: ui.Key, name: []const u8, color: ui.Color, selected: bool) !bool {
    const b = Button{ .key = key, .style = &.{ .width = .fixed(28), .height = .fixed(28), .padding = .all(0), .radius = .{ .fixed = 14 }, .background = .transparent, .border_width = .all(2), .border_color = if (selected) .text else .transparent } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .checkbox, .name = name, .state = .{ .checked = selected } });
    try ctx.e(Rect{ .key = key.indexed(1), .style = &.{ .width = .fixed(16), .height = .fixed(16), .radius = .{ .fixed = 8 }, .background = .{ .color = color } } });
    try b.close(ctx);
    return response.clicked;
}
fn iconDialog(self: *Self, ctx: *ui.Frame) !void {
    if (self.icon_target >= self.config.data.repositories.len) self.icon_open = false;
    if (!self.icon_open) return;
    const repository = self.config.data.repositories[self.icon_target];
    const dialog = ui.component.Dialog{ .key = .str("icon-dialog"), .is_open = &self.icon_open, .style = &.{ .width = .fixed(icon_cell * icon_columns + 46), .gap = 14 } };
    _ = try dialog.open(ctx);
    try heading(ctx, "Project icon", try std.fmt.allocPrint(ctx.arena(), "Pick an icon and color for {s}.", .{repository.label()}));
    const colors = try row(ctx, "icon-colors");
    if (try swatch(ctx, .str("icon-color-default"), "Default color", ctx.ui().theme.dimmed, projectTint(ctx, repository.icon_color) == null)) try self.config.setIcon(self.io, self.icon_target, repository.icon, "");
    for (icons.project_colors, 0..) |color, i| {
        if (try swatch(ctx, ui.Key.str("icon-color").indexed(i), color.name, projectTint(ctx, color.hex).?, std.ascii.eqlIgnoreCase(repository.icon_color, color.hex))) try self.config.setIcon(self.io, self.icon_target, repository.icon, color.hex);
    }
    try colors.close(ctx);
    try ctx.e(TextInput{ .key = .str("icon-search"), .buf = &self.icon_filter, .placeholder = "Search icons", .style = &.{ .width = .grow(), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    const query = try ctx.arena().dupe(u8, std.mem.trim(u8, self.icon_filter.items, " "));
    for (query) |*c| c.* = if (c.* == ' ' or c.* == '_') '-' else std.ascii.toLower(c.*);
    var matches: std.ArrayList(*const icons.Glyph) = .empty;
    for (self.lucide) |*glyph| if (std.mem.indexOf(u8, glyph.name, query) != null) try matches.append(ctx.arena(), glyph);
    const rows = try ctx.arena().alloc(IconRow, (matches.items.len + icon_columns - 1) / icon_columns);
    for (rows, 0..) |*entry, i| entry.* = .{ .app = self, .glyphs = matches.items[i * icon_columns .. @min(matches.items.len, (i + 1) * icon_columns)] };
    self.icon_hover = null;
    const grid = Rect{ .key = .str("icon-grid"), .style = comptime &.{ .width = .grow(), .height = .fixed(icon_cell * 8), .direction = .column, .overflow = .scroll_y } };
    _ = try grid.open(ctx);
    if (rows.len == 0) try label(ctx, "icon-none", "No icons match that search.", .dimmed);
    try ctx.e(ui.control.VirtualList(IconRow){ .key = .str("icon-rows"), .items = rows, .row_height = icon_cell, .overscan = 2, .each = renderIconRow });
    try grid.close(ctx);
    const actions = try row(ctx, "icon-actions");
    const chosen = if (icons.find(self.lucide, repository.icon) != null) repository.icon else icons.default_project;
    try ctx.e(Text{ .key = .str("icon-name"), .content = self.icon_hover orelse chosen, .selectable = false, .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden, .foreground = .dimmed, .font_size = .xs } });
    if (try button(ctx, "icon-reset", "Reset", repository.icon.len > 0 or repository.icon_color.len > 0, false)) try self.config.setIcon(self.io, self.icon_target, "", "");
    if (try button(ctx, "icon-done", "Done", true, true)) self.icon_open = false;
    try actions.close(ctx);
    _ = try dialog.closeResponse(ctx);
}
fn toolbar(self: *Self, ctx: *ui.Frame) !void {
    const bar = Rect{ .key = .str("toolbar"), .style = &.{ .width = .grow(), .height = .fixed(60), .direction = .row, .padding = .xy(14, 10), .gap = 8, .@"align" = .center, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try bar.open(ctx);
    const title = Rect{ .key = .str("toolbar-title"), .style = &.{ .width = .grow(), .direction = .column, .gap = 3 } };
    _ = try title.open(ctx);
    try ctx.e(Text{ .key = .str("repo-title"), .content = try diff.safeText(ctx.arena(), if (self.busy and self.loading_path.len > 0) self.displayName(self.loading_path) else if (self.path()) |p| self.displayName(p) else "Your next idea starts here"), .style = &.{ .font_size = .lg } });
    try label(ctx, "branch", if (self.read_busy) "Scanning repository changes…" else if (self.snapshot) |s| try std.fmt.allocPrint(ctx.arena(), "\u{e8d4}  {s}   ·   {s}   ·   {s}", .{ s.branch, self.provider.name, try syncSummary(ctx.arena(), s) }) else "A native home for your repositories", .dimmed);
    try title.close(ctx);
    const ready = self.available() and self.snapshot != null;
    if (self.snapshot) |snapshot| if (self.provider.capabilities.branches and snapshot.branches.len > 0) {
        var initial: ?u32 = null;
        for (snapshot.branches, 0..) |branch, i| if (std.mem.eql(u8, branch, snapshot.branch)) {
            initial = @intCast(i);
            break;
        };
        const branch = try ctx.interact(ui.component.SelectInput([]const u8){ .key = ui.Key.str(snapshot.branch).indexed(107), .values = snapshot.branches, .labels = snapshot.branches, .initial_selected = initial, .placeholder = "Switch branch", .style = &.{ .width = .fixed(160), .radius = .md, .background = .muted, .border_width = .all(0), .font_size = .sm, .padding = .xy(10, 7) } });
        if (branch.selected) |selected| if (ready and !std.mem.eql(u8, selected.value, snapshot.branch)) try self.request(ctx, .switch_branch, selected.value, "");
    };
    const actions = Rect{ .key = .str("toolbar-actions"), .style = &.{ .direction = .row, .gap = 4, .@"align" = .center } };
    _ = try actions.open(ctx);
    if (try toolbarButton(ctx, .refresh, ready, 0, self.active_operation == .refresh)) try self.request(ctx, .refresh, "", "");
    if (self.provider.capabilities.remotes) {
        const behind = if (self.snapshot) |s| s.behind else 0;
        const ahead = if (self.snapshot) |s| s.ahead else 0;
        if (try toolbarButton(ctx, .fetch, ready, 0, self.fetch_busy or self.active_operation == .fetch)) try self.sync(ctx, .fetch);
        if (try toolbarButton(ctx, .pull, ready, behind, self.active_operation == .pull)) try self.sync(ctx, .pull);
        if (try toolbarButton(ctx, .push, ready, ahead, self.active_operation == .push or self.active_operation == .publish)) try self.sync(ctx, .push);
    }
    try actions.close(ctx);
    try bar.close(ctx);
}
/// Where the branch stands against its remote, in words that say whether one exists.
fn syncSummary(a: std.mem.Allocator, s: model.Snapshot) ![]const u8 {
    if (s.upstream.len > 0) return std.fmt.allocPrint(a, "{d} ahead, {d} behind", .{ s.ahead, s.behind });
    const commits = try std.fmt.allocPrint(a, "{d} {s}", .{ s.ahead, if (s.ahead == 1) "commit" else "commits" });
    if (s.remotes.len == 0) return std.fmt.allocPrint(a, "{s} on this computer only, no remote", .{commits});
    return std.fmt.allocPrint(a, "{s} not pushed yet", .{commits});
}
/// A next step for a repository that cannot sync yet.
fn nextStep(self: *Self, ctx: *ui.Frame, snapshot: model.Snapshot) !void {
    const remote = guidance.defaultRemote(snapshot.remotes);
    if (remote != null and (snapshot.upstream.len > 0 or snapshot.history.len == 0)) return;
    const bar = Rect{ .key = .str("next-step"), .style = &.{ .width = .grow(), .padding = .xy(14, 8), .gap = 10, .direction = .row, .@"align" = .center, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try bar.open(ctx);
    const text = if (remote) |name|
        try std.fmt.allocPrint(ctx.arena(), "{s} has not been pushed to {s} yet. Your commits are saved on this computer.", .{ snapshot.branch, name })
    else if (snapshot.history.len == 0)
        "This repository has no remote. Connect one now, or after your first commit."
    else
        "This repository has no remote, so your commits are saved on this computer only. Connect one to back them up and share them.";
    try ctx.e(Text{ .key = .str("next-step-text"), .content = try diff.safeText(ctx.arena(), text), .style = &.{ .width = .grow(), .wrap = true, .foreground = .dimmed, .font_size = .xs } });
    if (remote) |name| {
        if (try self.operationButton(ctx, "next-step-publish", "Publish branch", self.available(), true, .publish)) try self.request(ctx, .publish, snapshot.branch, name);
    } else if (try button(ctx, "next-step-connect", "Connect a remote…", self.available(), true)) self.openRemoteSetup(ctx);
    try bar.close(ctx);
}
fn recovery(self: *Self, ctx: *ui.Frame, snapshot: model.Snapshot) !void {
    const bar = Rect{ .key = .str("recovery"), .style = &.{ .width = .grow(), .padding = .xy(12, 8), .gap = 10, .direction = .row, .@"align" = .center, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try bar.open(ctx);
    var conflicts: usize = 0;
    for (snapshot.files) |file| if (std.mem.eql(u8, file.status, "Conflict")) {
        conflicts += 1;
    };
    try ctx.e(Text{ .key = .str("recovery-status"), .content = try std.fmt.allocPrint(ctx.arena(), "{s} · {d} unresolved files. Stage resolutions before continuing.", .{ @tagName(snapshot.state), conflicts }), .style = &.{ .width = .grow(), .foreground = .warning } });
    const operations_pair: ?struct { model.Operation, model.Operation } = switch (snapshot.state) {
        .merging => .{ .merge_continue, .merge_abort },
        .rebasing => .{ .rebase_continue, .rebase_abort },
        .cherry_picking => .{ .cherry_pick_continue, .cherry_pick_abort },
        else => null,
    };
    if (operations_pair) |pair| {
        if (try self.operationButton(ctx, "recovery-continue", "Continue", self.available() and conflicts == 0, true, pair[0])) try self.request(ctx, pair[0], "", "");
        if (try self.operationButton(ctx, "recovery-abort", "Abort", self.available(), false, pair[1])) try self.request(ctx, pair[1], "", "");
    }
    try bar.close(ctx);
}
fn worktree(self: *Self, ctx: *ui.Frame) !void {
    // While another repository opens, keep the panels in place so the layout does not jump.
    const switching = self.busy and self.loading_path.len > 0 and (self.snapshot == null or !config_mod.equalPath(self.snapshot.?.path, self.loading_path));
    if (self.snapshot == null and !switching) {
        try self.empty(ctx);
        return;
    }
    const live = if (switching) null else self.snapshot;
    const shown_files: []const model.File = if (live) |s| s.files else &.{};
    const body = Rect{ .key = .str("worktree"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .row, .gap = 10 } };
    _ = try body.open(ctx);
    const column = Rect{ .key = .str("changes-column"), .style = &.{ .width = .fixed(308), .height = .grow(), .direction = .column, .gap = 10 } };
    _ = try column.open(ctx);
    const list = Rect{ .key = .str("file-panel"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .padding = .all(10), .gap = 8, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try list.open(ctx);
    if (self.page == .history) {
        const title = try row(ctx, "history-title");
        try ctx.e(Text{ .key = .str("history-heading"), .content = "History", .style = &.{ .width = .grow(), .font_size = .md } });
        try ctx.e(Text{ .key = .str("history-count"), .content = if (live) |s| try std.fmt.allocPrint(ctx.arena(), "{d}", .{s.history.len}) else "…", .style = &.{ .background = .muted, .padding = .xy(8, 3), .radius = .sm, .foreground = .dimmed, .font_size = .xs } });
        try title.close(ctx);
        const history_list = Rect{ .key = .str("history-list"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 2, .overflow = .scroll_y } };
        _ = try history_list.open(ctx);
        const history = if (live) |s| s.history else &.{};
        for (history, 0..) |h, i| {
            const key = ui.Key.str("revision").indexed(i);
            const summary = try diff.safeText(ctx.arena(), h.summary);
            const b = Button{ .key = key, .disabled = self.busy, .style = &.{ .width = .grow(), .direction = .column, .@"align" = .start, .justify = .center, .gap = 3, .padding = .xy(10, 6), .height = .fixed(50), .background = if (self.selected_revision == i) themes.selection(ctx.ui().theme) else .transparent, .foreground = .text, .radius = .md, .overflow = .hidden } };
            const response = try b.openResponse(ctx);
            try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = summary, .state = .{ .disabled = self.busy } });
            try ctx.e(Text{ .key = key.indexed(1), .content = summary, .selectable = false, .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden } });
            const meta = Rect{ .key = key.indexed(2), .style = comptime &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center, .foreground = .dimmed, .font_size = .xs } };
            _ = try meta.open(ctx);
            try ctx.e(Text{ .key = key.indexed(3), .content = h.oid[0..7], .selectable = false, .style = &.{ .font = "mono" } });
            try ctx.e(Text{ .key = key.indexed(4), .content = try diff.safeText(ctx.arena(), h.author), .selectable = false, .style = &.{ .width = .grow(), .wrap = false, .overflow = .hidden } });
            try meta.close(ctx);
            try b.close(ctx);
            if (response.clicked) {
                self.selected_revision = i;
                try self.launch(.revision, self.snapshot.?.path, .{ .operation = .refresh, .value = h.oid });
            }
        }
        try history_list.close(ctx);
    } else {
        const title = try row(ctx, "changes-title");
        try ctx.e(Text{ .key = .str("changes-heading"), .content = "Changes", .style = &.{ .width = .grow(), .font_size = .md } });
        try ctx.e(Text{ .key = .str("changes-count"), .content = if (live != null) try std.fmt.allocPrint(ctx.arena(), "{d}", .{shown_files.len}) else "…", .style = &.{ .background = .muted, .padding = .xy(8, 3), .radius = .sm, .foreground = .dimmed, .font_size = .xs } });
        try title.close(ctx);
        try ctx.e(TextInput{ .key = .str("file-filter"), .buf = &self.filter_input, .placeholder = "Filter files…", .style = &.{ .width = .grow(), .background = .muted, .border_color = .transparent, .radius = .md, .padding = .xy(12, 9) } });
        const actions = try row(ctx, "stage-actions");
        if (try self.operationButton(ctx, "stage-all", "Stage all", self.available(), false, .stage_all)) try self.request(ctx, .stage_all, "", "");
        if (try self.operationButton(ctx, "unstage-all", "Unstage all", self.available(), false, .unstage_all)) try self.request(ctx, .unstage_all, "", "");
        try actions.close(ctx);
        if (live != null) try self.files(ctx, shown_files) else {
            const pending = Rect{ .key = .str("changes-pending"), .style = comptime &.{ .width = .grow(), .height = .grow() } };
            _ = try pending.open(ctx);
            try pending.close(ctx);
        }
    }
    try list.close(ctx);
    if (self.page == .changes) {
        const commit_panel = Rect{ .key = .str("commit-panel"), .style = &.{ .width = .grow(), .direction = .column, .gap = 8, .padding = .all(12), .background = .elevated, .radius = .{ .fixed = 14 } } };
        _ = try commit_panel.open(ctx);
        try label(ctx, "commit-heading", "Commit", .text);
        try ctx.e(TextInput{ .key = .str("commit-message"), .buf = &self.commit_input, .placeholder = "Write a commit summary…", .style = &.{ .width = .grow(), .background = .muted, .border_color = .transparent, .radius = .md, .padding = .xy(12, 10) } });
        var staged_count: usize = 0;
        for (shown_files) |f| if (f.staged) {
            staged_count += 1;
        };
        const committing = self.active_operation == .commit;
        const commit_label = try std.fmt.allocPrint(ctx.arena(), "Commit {d} staged {s}", .{ staged_count, if (staged_count == 1) "file" else "files" });
        const commit_button = Button{ .key = .str("commit"), .label = if (committing) null else commit_label, .disabled = !self.available() or staged_count == 0 or std.mem.trim(u8, self.commit_input.items, " \n\r\t").len == 0, .style = &.{ .width = .grow(), .padding = .xy(12, 10), .gap = 8, .radius = .md, .font_size = .sm, .disabled = &.{ .background = .muted, .foreground = .dimmed, .opacity = 0.65 } } };
        if (committing) {
            try busyButton(ctx, commit_button, commit_label, ctx.ui().theme.dimmed);
        } else if ((try ctx.interact(commit_button)).clicked) {
            try self.request(ctx, .commit, self.commit_input.items, "");
            self.clear_commit_message = self.active_operation == .commit;
        }
        try commit_panel.close(ctx);
    }
    try column.close(ctx);
    const right = Rect{ .key = .str("diff-panel"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .padding = .all(12), .gap = 10, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try right.open(ctx);
    const source_files: []const model.File = if (switching) &.{} else if (self.page == .history) if (self.revision) |r| r.files else &.{} else shown_files;
    if (self.page == .history and source_files.len > 0) {
        const strip = Rect{ .key = .str("revision-files"), .style = &.{ .width = .grow(), .height = .fixed(110), .overflow = .scroll_y, .direction = .column, .gap = 3 } };
        _ = try strip.open(ctx);
        for (source_files, 0..) |f, i| {
            const entry = Button{ .key = ui.Key.str("revision-file-nav").indexed(i), .disabled = !self.available(), .style = &.{ .width = .grow(), .justify = .start, .gap = 10, .padding = .xy(10, 6), .background = if (self.selected_file == i) themes.selection(ctx.ui().theme) else .transparent, .foreground = .text, .radius = .md } };
            const response = try entry.openResponse(ctx);
            try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = try diff.safeText(ctx.arena(), f.path) });
            try fileIcon(ctx, ui.Key.str("revision-file-icon").indexed(i), f.path);
            try ctx.e(Text{ .key = ui.Key.str("revision-file-path").indexed(i), .content = try diff.safeText(ctx.arena(), f.path), .selectable = false, .style = &.{ .width = .grow(), .overflow = .hidden } });
            try entry.close(ctx);
            if (response.clicked) self.selectFile(i);
        }
        try strip.close(ctx);
    }
    if (source_files.len > 0 and self.selected_file < source_files.len) {
        var file = source_files[self.selected_file];
        if (self.page == .changes) {
            if (self.preview) |preview_value| {
                const loaded = preview_value.files[0];
                file.patch = loaded.patch;
                file.lines = loaded.lines;
                file.binary = file.binary or loaded.binary;
            } else file.patch = if (self.preview_pending or self.preview_busy) "Loading diff…" else "Preview unavailable. Select the file again to retry.";
        }
        try self.diffView(ctx, file);
    } else if (switching) {
        try self.opening(ctx);
    } else {
        const blank = Rect{ .key = .str("diff-empty"), .style = comptime &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 8, .justify = .center, .@"align" = .center } };
        _ = try blank.open(ctx);
        try ctx.e(Text{ .key = .str("clean-icon"), .content = if (self.page == .history) "\u{e889}" else "\u{e86c}", .selectable = false, .style = &.{ .font_size = .{ .px = 34 }, .foreground = .toned } });
        try ctx.e(Text{ .key = .str("clean-title"), .content = if (self.page == .history) "Every change has a story" else "A clean working tree", .style = &.{ .font_size = .lg } });
        try label(ctx, "clean-description", if (self.page == .history) "Select a commit to explore its changes." else "Your repository has no pending changes. You’re ready to build.", .dimmed);
        try blank.close(ctx);
    }
    try right.close(ctx);
    try body.close(ctx);
}
fn files(self: *Self, ctx: *ui.Frame, items: []const model.File) !void {
    if (self.file_list_reset) {
        if (ctx.ui().state.get(.scroll, ui.Key.str("changes-list").hash())) |scroll| scroll.offset[1] = 0;
        self.file_list_reset = false;
    }
    if (!self.file_rows_valid or !std.mem.eql(u8, self.cached_filter, self.filter_input.items)) {
        if (!std.mem.eql(u8, self.cached_filter, self.filter_input.items)) if (ctx.ui().state.get(.scroll, ui.Key.str("changes-list").hash())) |scroll| {
            scroll.offset[1] = 0;
        };
        self.a.free(self.file_rows);
        self.file_rows = &.{};
        self.a.free(self.cached_filter);
        self.cached_filter = "";
        self.cached_filter = try self.a.dupe(u8, self.filter_input.items);
        var rows: std.ArrayList(FileRow) = .empty;
        errdefer rows.deinit(self.a);
        for ([_]bool{ true, false }) |staged| {
            const group_index = rows.items.len;
            try rows.append(self.a, .{ .app = self, .entry = .{ .group = .{ .staged = staged, .count = 0 } } });
            var count: usize = 0;
            for (items, 0..) |f, i| {
                if (f.staged != staged) continue;
                if (self.filter_input.items.len > 0 and std.mem.indexOf(u8, f.path, self.filter_input.items) == null) continue;
                try rows.append(self.a, .{ .app = self, .entry = .{ .file = i } });
                count += 1;
            }
            rows.items[group_index].entry.group.count = count;
        }
        self.file_rows = try rows.toOwnedSlice(self.a);
        self.file_rows_valid = true;
    }
    const list = Rect{ .key = .str("changes-list"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .overflow = .scroll_y } };
    _ = try list.open(ctx);
    try ctx.e(ui.control.VirtualList(FileRow){ .key = .str("visible-files"), .items = self.file_rows, .row_height = file_row_height, .overscan = 4, .each = renderFile });
    try list.close(ctx);
}
const FileRow = struct {
    app: *Self,
    entry: union(enum) {
        group: struct { staged: bool, count: usize },
        file: usize,
    },
};
fn opening(self: *Self, ctx: *ui.Frame) !void {
    const panel = Rect{ .key = .str("repository-loading"), .style = comptime &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 8, .justify = .center, .@"align" = .center } };
    const panel_id = try panel.open(ctx);
    try ctx.ui().setAccessibility(panel_id, .{ .role = .generic, .name = if (self.read_busy) "Opening repository…" else "Preparing repository…" });
    try heading(ctx, if (self.read_busy) "Opening repository…" else "Preparing repository…", "Scanning files and changes. Large repositories may take a moment.");
    try label(ctx, "loading-path", try diff.safeText(ctx.arena(), self.loading_path), .dimmed);
    try self.loadingPulse(ctx, "opening-pulse", true);
    try label(ctx, "loading-elapsed", try std.fmt.allocPrint(ctx.arena(), "Elapsed: {d}s{s}", .{ self.loading_ns / std.time.ns_per_s, if (self.read_busy) " · You can switch to another repository while this loads." else "" }), .dimmed);
    try panel.close(ctx);
}
fn renderFile(ctx: *ui.Frame, item: FileRow, row_index: usize) !void {
    const self = item.app;
    const i = switch (item.entry) {
        .file => |index| index,
        .group => |group| {
            const heading_row = Rect{ .key = ui.Key.str("change-group").indexed(row_index), .style = &.{ .width = .grow(), .height = .fixed(file_row_height), .direction = .row, .padding = .xy(8, 4), .@"align" = .center, .gap = 8 } };
            const heading_id = try heading_row.open(ctx);
            const title = if (group.staged) "Staged changes" else "Unstaged changes";
            try ctx.ui().setAccessibility(heading_id, .{ .role = .generic, .name = title });
            try ctx.e(Text{ .key = ui.Key.str("change-group-title").indexed(row_index), .content = title, .selectable = false, .style = &.{ .width = .grow(), .foreground = .dimmed, .font_size = .xs } });
            try ctx.e(Text{ .key = ui.Key.str("change-group-count").indexed(row_index), .content = try std.fmt.allocPrint(ctx.arena(), "{d}", .{group.count}), .selectable = false, .style = &.{ .foreground = .dimmed, .font_size = .xs } });
            try heading_row.close(ctx);
            return;
        },
    };
    const f = self.snapshot.?.files[i];
    const menu = ui.component.ContextMenu(ChangeActions){ .key = change_context.key(self.snapshot.?.path, f), .menu = .{ .app = self, .index = i, .file = f }, .style = &.{ .width = .grow(), .height = .fixed(file_row_height) }, .parts = .{ .popup = &menu_popup } };
    try self.openContextMenu(ctx, &menu);
    const b = Button{ .key = ui.Key.str("file").indexed(i), .disabled = false, .style = &.{ .width = .grow(), .height = .fixed(file_row_height), .padding = .xy(8, 4), .gap = 6, .justify = .start, .background = if (self.selected_file == i) themes.selection(ctx.ui().theme) else .transparent, .foreground = .text, .radius = .md } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = try diff.safeText(ctx.arena(), try std.fmt.allocPrint(ctx.arena(), "{s}, {s}, {s}", .{ f.path, f.status, if (f.staged) "staged" else "unstaged" })) });
    try fileIconSized(ctx, ui.Key.str("file-icon").indexed(i), f.path, 14);
    try truncatedLabel(ctx, ui.Key.str("file-path").indexed(i), try diff.safeText(ctx.arena(), f.path));
    if (f.binary or !f.stats_available) {
        try ctx.e(Text{ .key = ui.Key.str("file-count-state").indexed(i), .content = if (f.binary) "Binary" else if (self.counts_busy) "…" else "—", .selectable = false, .style = &.{ .font_size = .xs, .foreground = .dimmed } });
    } else {
        try ctx.e(Text{ .key = ui.Key.str("file-additions").indexed(i), .content = try std.fmt.allocPrint(ctx.arena(), "+{d}", .{f.additions}), .selectable = false, .style = &.{ .font_size = .xs, .foreground = .success } });
        try ctx.e(Text{ .key = ui.Key.str("file-deletions").indexed(i), .content = try std.fmt.allocPrint(ctx.arena(), "−{d}", .{f.deletions}), .selectable = false, .style = &.{ .font_size = .xs, .foreground = .@"error" } });
    }
    try b.close(ctx);
    if (response.clicked) {
        self.selectFile(i);
        ctx.requestRedraw();
    }
    try menu.close(ctx);
}
fn loadingPulse(self: *Self, ctx: *ui.Frame, key: []const u8, centered: bool) !void {
    const track = Rect{ .key = .str(key), .style = &.{ .width = if (centered) .fit() else .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
    _ = try track.open(ctx);
    const active = (self.loading_ns / (200 * std.time.ns_per_ms)) % 8;
    for (0..8) |i| {
        const dot = Rect{ .key = ui.Key.str(key).indexed(i), .style = &.{ .width = .fixed(18), .height = .fixed(4), .radius = .sm, .background = if (i == active) .accent else .muted } };
        _ = try dot.open(ctx);
        try dot.close(ctx);
    }
    try track.close(ctx);
}
fn diffView(self: *Self, ctx: *ui.Frame, file: model.File) !void {
    if (!self.diff_rows_valid) {
        self.clearDiffRows();
        const content = diff.contentLines(file.lines);
        self.diff_rows = try self.a.alloc(DiffRow, content.len);
        var ordinal: usize = 0;
        for (content, self.diff_rows) |line, *entry| {
            entry.* = .{ .app = self, .file = file, .line = line, .ordinal = ordinal };
            if (line.kind == .hunk) ordinal += 1;
        }
        self.split_rows = try diff.pairs(self.a, content);
        self.diff_rows_valid = true;
    }
    const header = try row(ctx, "diff-header");
    try ctx.ui().setAccessibility(header.key.hash(), .{ .role = .generic, .name = try diff.safeText(ctx.arena(), file.path) });
    try fileIcon(ctx, .str("diff-file-icon"), file.path);
    const title = Rect{ .key = .str("diff-title"), .style = &.{ .width = .grow(), .direction = .column, .gap = 4, .overflow = .hidden } };
    _ = try title.open(ctx);
    try ctx.e(Text{ .key = .str("diff-path"), .content = try diff.safeText(ctx.arena(), std.fs.path.basename(file.path)), .style = &.{ .width = .grow(), .overflow = .hidden, .font_size = .md } });
    try ctx.e(Text{ .key = .str("diff-directory"), .content = try diff.safeText(ctx.arena(), std.fs.path.dirname(file.path) orelse "Repository root"), .style = &.{ .width = .grow(), .overflow = .hidden, .foreground = .dimmed, .font_size = .xs } });
    try title.close(ctx);
    try detailBadge(ctx, "diff-status", file.status, if (std.mem.eql(u8, file.status, "Conflict")) .@"error" else .dimmed);
    if (file.stats_available and !file.binary) {
        try label(ctx, "diff-add", try std.fmt.allocPrint(ctx.arena(), "+{d}", .{file.additions}), .success);
        try label(ctx, "diff-del", try std.fmt.allocPrint(ctx.arena(), "−{d}", .{file.deletions}), .@"error");
    }
    try header.close(ctx);
    try self.diffDetails(ctx, file);
    const actions = try row(ctx, "diff-actions");
    try ctx.e(Text{ .key = .str("diff-state"), .content = if (self.page == .history) "Committed changes" else if (file.staged) "Staged changes" else "Working tree", .style = &.{ .width = .grow(), .foreground = .dimmed, .font_size = .xs } });
    if (try button(ctx, "copy-diff", "Copy patch", file.lines.len > 0, false)) try ctx.writeClipboard(file.patch);
    if (try button(ctx, "diff-layout", if (self.split_diff) "Unified" else "Split", true, false)) {
        self.split_diff = !self.split_diff;
        self.config.data.split_diff = self.split_diff;
        try self.config.save(self.io);
        ctx.requestRedraw();
    }
    if (self.page == .changes) {
        if (std.mem.eql(u8, file.status, "Conflict")) {
            if (try button(ctx, "resolve-ours", "Keep ours", self.available(), false)) try self.request(ctx, .resolve_ours, file.path, "");
            if (try button(ctx, "resolve-theirs", "Keep theirs", self.available(), false)) try self.request(ctx, .resolve_theirs, file.path, "");
        }
        if (try button(ctx, "stage-file", if (file.staged) "Unstage" else "Stage", self.available(), false)) try self.request(ctx, if (file.staged) .unstage else .stage, file.path, if (std.mem.eql(u8, file.status, "Renamed")) file.old_path else "");
        if (try button(ctx, "discard-file", "Discard", self.available() and !file.staged and !std.mem.eql(u8, file.status, "Untracked"), false)) try self.request(ctx, .discard, file.path, "");
    }
    try actions.close(ctx);
    const loading = self.page == .changes and !self.preview_quiet and (self.preview_busy or self.preview_pending);
    const unavailable = file.binary or self.diff_rows.len == 0;
    if (loading and !unavailable) try self.loadingPulse(ctx, "diff-loading-pulse", false);
    diff_row_height = diffRowHeight(ctx, self.config.data.diff_font_size);
    const pane = Rect{ .key = ui.Key.str("diff-scroll").indexed(self.selected_file).indexed(@intFromBool(self.split_diff)), .style = &.{ .width = .grow(), .height = .grow(), .direction = if (self.split_diff) .row else .column, .overflow = if (self.split_diff) .hidden else .scroll, .gap = if (self.split_diff) 10 else 0, .font = diffFont(self.config.data.diff_font), .font_size = .{ .px = @floatFromInt(self.config.data.diff_font_size) }, .padding = .xy(0, 8), .border_width = .edges(1, 0, 0, 0), .border_color = .muted } };
    _ = try pane.open(ctx);
    if (unavailable) {
        const notice = Rect{ .key = .str("diff-notice"), .style = comptime &.{ .width = .grow(), .height = .grow(), .direction = .column, .gap = 8, .justify = .center, .@"align" = .center } };
        _ = try notice.open(ctx);
        if (file.binary) try label(ctx, "binary", "Binary file · text preview unavailable", .dimmed) else try label(ctx, "no-preview", if (file.lines.len > 0) "No line changes · file details shown above." else if (file.patch.len > 0) file.patch else "No text preview available.", .dimmed);
        if (loading) try self.loadingPulse(ctx, "diff-loading-pulse", true);
        try notice.close(ctx);
    } else if (self.split_diff) {
        const left_key = ui.Key.str("diff-left-column").indexed(self.selected_file);
        const right_key = ui.Key.str("diff-right-column").indexed(self.selected_file);
        const left_scroll = try ctx.ui().state.getOrCreate(.scroll, ctx.ui().allocator, left_key.hash());
        const right_scroll = try ctx.ui().state.getOrCreate(.scroll, ctx.ui().allocator, right_key.hash());
        const y = if (@abs(left_scroll.offset[1] - self.split_scroll_y) > 0.01) left_scroll.offset[1] else right_scroll.offset[1];
        left_scroll.offset[1] = y;
        right_scroll.offset[1] = y;
        self.split_scroll_y = y;
        const rows = self.split_rows;
        const left_column = Rect{ .key = left_key, .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .overflow = .scroll } };
        _ = try left_column.open(ctx);
        try ctx.e(ui.control.VirtualList(diff.Pair){ .key = .str("diff-left-pairs"), .items = rows, .row_height = diff_row_height, .overscan = 8, .each = renderLeft });
        try left_column.close(ctx);
        const right_column = Rect{ .key = right_key, .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .overflow = .scroll } };
        _ = try right_column.open(ctx);
        try ctx.e(ui.control.VirtualList(diff.Pair){ .key = .str("diff-right-pairs"), .items = rows, .row_height = diff_row_height, .overscan = 8, .each = renderRight });
        try right_column.close(ctx);
    } else {
        try ctx.e(ui.control.VirtualList(DiffRow){ .key = .str("diff-lines"), .items = self.diff_rows, .row_height = diff_row_height, .overscan = 8, .each = renderDiffRow });
    }
    try pane.close(ctx);
}
fn diffDetails(_: *Self, ctx: *ui.Frame, file: model.File) !void {
    if (file.old_path.len > 0 and !std.mem.eql(u8, file.old_path, file.path)) {
        try ctx.e(Text{ .key = .str("diff-previous-path"), .content = try diff.safeText(ctx.arena(), try std.fmt.allocPrint(ctx.arena(), "{s} {s}", .{ if (std.mem.eql(u8, file.status, "Copied")) "Copied from" else "Renamed from", file.old_path })), .style = &.{ .width = .grow(), .overflow = .hidden, .font_size = .xs, .foreground = .dimmed } });
    }
    const details = diff.metadata(file.patch);
    if (details.old_oid.len == 0 and details.old_mode.len == 0 and details.new_mode.len == 0 and details.similarity.len == 0 and details.dissimilarity.len == 0) return;
    const strip = Rect{ .key = .str("diff-details"), .style = &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center, .overflow = .hidden } };
    _ = try strip.open(ctx);
    if (details.old_mode.len > 0 or details.new_mode.len > 0) {
        const mode = if (std.mem.eql(u8, details.old_mode, details.new_mode))
            try std.fmt.allocPrint(ctx.arena(), "Mode {s}", .{details.new_mode})
        else if (details.old_mode.len == 0)
            try std.fmt.allocPrint(ctx.arena(), "Mode {s}", .{details.new_mode})
        else if (details.new_mode.len == 0)
            try std.fmt.allocPrint(ctx.arena(), "Previous mode {s}", .{details.old_mode})
        else
            try std.fmt.allocPrint(ctx.arena(), "Mode {s} to {s}", .{ details.old_mode, details.new_mode });
        try detailBadge(ctx, "diff-mode", mode, .dimmed);
    }
    if (details.similarity.len > 0) try detailBadge(ctx, "diff-similarity", try std.fmt.allocPrint(ctx.arena(), "Similarity {s}", .{details.similarity}), .dimmed);
    if (details.dissimilarity.len > 0) try detailBadge(ctx, "diff-dissimilarity", try std.fmt.allocPrint(ctx.arena(), "Dissimilarity {s}", .{details.dissimilarity}), .dimmed);
    if (details.old_oid.len > 0) try ctx.e(Text{ .key = .str("diff-objects"), .content = try diff.safeText(ctx.arena(), try std.fmt.allocPrint(ctx.arena(), "Objects {s} to {s}", .{ details.old_oid, details.new_oid })), .style = &.{ .width = .grow(), .overflow = .hidden, .font_size = .xs, .foreground = .dimmed } });
    try strip.close(ctx);
}
fn detailBadge(ctx: *ui.Frame, key: []const u8, content: []const u8, color: ui.Color.Input) !void {
    const badge = Rect{ .key = .str(key), .style = &.{ .padding = .xy(8, 4), .radius = .sm, .background = .muted } };
    _ = try badge.open(ctx);
    try ctx.e(Text{ .key = ui.Key.str(key).indexed(0), .content = try diff.safeText(ctx.arena(), content), .style = &.{ .font_size = .xs, .foreground = color } });
    try badge.close(ctx);
}
// Whole physical pixels, so fractional display scaling leaves no seams between row backgrounds.
fn diffRowHeight(ctx: *ui.Frame, font_size: u8) f32 {
    const scale = ctx.ui().content_scale;
    return @round((@as(f32, @floatFromInt(font_size)) + 11) * scale) / scale;
}
const DiffRow = struct { app: *Self, file: model.File, line: diff.Line, ordinal: usize };
fn renderDiffRow(ctx: *ui.Frame, item: DiffRow, i: usize) !void {
    if (item.line.kind != .hunk or item.app.page != .changes or std.mem.eql(u8, item.file.status, "Untracked") or std.mem.eql(u8, item.file.status, "Conflict") or std.mem.eql(u8, item.file.status, "Renamed")) return renderLine(ctx, item.line, i);
    const bar = Rect{ .key = ui.Key.str("hunk-row").indexed(i), .style = &.{ .width = .grow(), .height = .fixed(diff_row_height), .direction = .row, .@"align" = .center, .gap = 12, .padding = .xy(8, 0), .font = "default", .font_size = .xs, .background = .muted } };
    _ = try bar.open(ctx);
    try ctx.e(Text{ .key = ui.Key.str("hunk-label").indexed(i), .content = try diff.hunkLabel(ctx.arena(), item.line.text), .style = &.{ .foreground = .dimmed, .width = .grow(), .overflow = .hidden } });
    if ((try ctx.interact(Button{ .key = ui.Key.str("hunk-stage").indexed(i), .label = if (item.file.staged) "Unstage hunk" else "Stage hunk", .disabled = !item.app.available() or item.app.preview_busy or item.app.preview_pending, .style = &.{ .height = .fixed(diff_row_height - 4), .padding = .xy(8, 0), .font_size = .xs, .radius = .sm, .background = .toned, .foreground = .text } })).clicked) {
        const patch = try diff.hunk(ctx.arena(), item.file.patch, item.ordinal);
        try item.app.request(ctx, if (item.file.staged) .unstage_hunk else .stage_hunk, patch, "");
    }
    try bar.close(ctx);
}
fn renderLeft(ctx: *ui.Frame, pair: diff.Pair, i: usize) !void {
    try renderHalf(ctx, pair.left, i * 2, true);
}
fn renderRight(ctx: *ui.Frame, pair: diff.Pair, i: usize) !void {
    try renderHalf(ctx, pair.right, i * 2 + 1, false);
}
fn renderHalf(ctx: *ui.Frame, maybe_line: ?diff.Line, i: usize, left: bool) !void {
    const line = maybe_line orelse diff.Line{ .text = "", .kind = .context };
    if (line.kind == .hunk) return renderHunkDivider(ctx, line, i);
    const background: ui.Color.Input = switch (line.kind) {
        .addition => .{ .color = ui.Color.rgba(36, 122, 77, 41) },
        .deletion => .{ .color = ui.Color.rgba(176, 56, 66, 41) },
        else => .transparent,
    };
    const stack = ctx.ui().layout_ctx.stack.items;
    const parent_id = ctx.ui().layout_ctx.pool.get(stack[stack.len - 1]).id;
    const width = if (ctx.ui().state.get(.measured, parent_id)) |measured| measured.width else 0;
    const half = Rect{ .key = ui.Key.str("split-half").indexed(i), .style = &.{ .width = .{ .kind = .fit, .min = width }, .height = .fixed(diff_row_height), .direction = .row, .background = background, .@"align" = .center } };
    _ = try half.open(ctx);
    const number = if (left) line.old else line.new;
    try ctx.e(Text{ .key = ui.Key.str("split-gutter").indexed(i), .content = if (number) |n| try std.fmt.allocPrint(ctx.arena(), "{d}  ", .{n}) else "", .style = &.{ .width = .fixed(46), .foreground = .dimmed }, .selectable = false });
    const content = if (line.text.len > 0 and (line.kind == .context or line.kind == .addition or line.kind == .deletion)) line.text[1..] else line.text;
    if (line.kind == .hunk or line.kind == .meta) {
        try ctx.e(Text{ .key = ui.Key.str("split-meta").indexed(i), .content = content, .style = &.{ .foreground = .dimmed }, .selectable = false });
    } else for (try diff.tokens(ctx.arena(), content), 0..) |token, t| try ctx.e(Text{ .key = ui.Key.str("split-token").indexed(i).indexed(t), .content = token.text, .style = &.{ .foreground = tokenColor(token.kind) }, .selectable = false });
    try half.close(ctx);
}
fn tokenColor(kind: @FieldType(diff.Token, "kind")) ui.Color.Input {
    return switch (kind) {
        .plain => .text,
        .keyword => .accent,
        .string => .success,
        .number => .warning,
        .comment => .dimmed,
    };
}
fn renderLine(ctx: *ui.Frame, line: diff.Line, i: usize) !void {
    if (line.kind == .hunk) return renderHunkDivider(ctx, line, i);
    const theme = ctx.ui().theme;
    var background = theme.elevated;
    if (line.kind == .addition) background = ui.Color.rgba(36, 122, 77, 41);
    if (line.kind == .deletion) background = ui.Color.rgba(176, 56, 66, 41);
    const rect = Rect{ .key = ui.Key.str("diff-line").indexed(i), .style = &.{ .width = .grow(), .height = .fixed(diff_row_height), .direction = .row, .background = .{ .color = background }, .gap = 0, .@"align" = .center } };
    _ = try rect.open(ctx);
    try ctx.e(Text{ .key = ui.Key.str("gutter-old").indexed(i), .content = if (line.old) |n| try std.fmt.allocPrint(ctx.arena(), "{d}", .{n}) else "", .style = &.{ .width = .fixed(40), .foreground = .dimmed }, .selectable = false });
    try ctx.e(Text{ .key = ui.Key.str("gutter-new").indexed(i), .content = if (line.new) |n| try std.fmt.allocPrint(ctx.arena(), "{d}", .{n}) else "", .style = &.{ .width = .fixed(40), .foreground = .dimmed }, .selectable = false });
    if (line.kind == .hunk or line.kind == .meta) try ctx.e(Text{ .key = ui.Key.str("diff-meta").indexed(i), .content = line.text, .style = &.{ .foreground = .dimmed } }) else {
        const tokens = try diff.tokens(ctx.arena(), line.text);
        for (tokens, 0..) |token, t| try ctx.e(Text{ .key = ui.Key.str("diff-token").indexed(i).indexed(t), .content = token.text, .style = &.{ .foreground = switch (token.kind) {
            .plain => .text,
            .keyword => .accent,
            .string => .success,
            .number => .warning,
            .comment => .dimmed,
        } }, .selectable = false });
    }
    try rect.close(ctx);
}
fn renderHunkDivider(ctx: *ui.Frame, line: diff.Line, i: usize) !void {
    const bar = Rect{ .key = ui.Key.str("hunk-divider").indexed(i), .style = &.{ .width = .grow(), .height = .fixed(diff_row_height), .direction = .row, .@"align" = .center, .padding = .xy(8, 0), .font = "default", .background = .muted } };
    _ = try bar.open(ctx);
    try ctx.e(Text{ .key = ui.Key.str("hunk-range").indexed(i), .content = try diff.hunkLabel(ctx.arena(), line.text), .style = &.{ .width = .grow(), .overflow = .hidden, .foreground = .dimmed, .font_size = .xs }, .selectable = false });
    try bar.close(ctx);
}
fn empty(self: *Self, ctx: *ui.Frame) !void {
    const panel = Rect{ .key = .str("welcome"), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .padding = .all(32), .gap = 12, .justify = .center, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try panel.open(ctx);
    try ctx.e(Text{ .key = .str("welcome-title"), .content = "Good work starts\nwith a little clarity.", .style = &.{ .font_size = .xl } });
    try label(ctx, "welcome-copy", "Bring your repositories together. See what changed. Ship with confidence.", .dimmed);
    try label(ctx, "welcome-details", "Add a local folder, drop one here, or clone from GitHub and other remotes.", .dimmed);
    const actions = try row(ctx, "welcome-actions");
    if (try button(ctx, "welcome-add", "Add a local folder…", self.available(), true)) {
        self.remote_input.clearRetainingCapacity();
        try self.browse(.folder, &self.path_input, false, "Choose a repository folder");
    }
    if (try button(ctx, "welcome-clone", "Clone or create…", self.available(), false)) self.add_open = true;
    try actions.close(ctx);
    try panel.close(ctx);
}
fn operations(self: *Self, ctx: *ui.Frame) !void {
    const panel = try pagePanel(ctx, "operations");
    try heading(ctx, "Repository tools", "Branches, remotes, tags, stashes, merges and recovery.");
    if (self.snapshot) |snapshot| {
        const status = try settingGroup(ctx, "repository-status");
        const tracking = if (snapshot.upstream.len > 0) try std.fmt.allocPrint(ctx.arena(), "{s} · tracking {s}", .{ snapshot.branch, snapshot.upstream }) else try std.fmt.allocPrint(ctx.arena(), "{s} · no upstream", .{snapshot.branch});
        const state = try settingRow(ctx, "operation-state", "Current branch", tracking, true, false);
        try ctx.e(Text{ .key = .str("operation-state-badge"), .content = @tagName(snapshot.state), .style = &.{ .background = .muted, .padding = .xy(10, 4), .radius = .sm, .foreground = if (snapshot.state == .normal) .dimmed else .warning, .font_size = .xs } });
        try state.close(ctx);
        const branches = try settingRow(ctx, "branches-row", "Branches", "Select a branch to switch to it.", false, true);
        const branch_list = Rect{ .key = .str("branches"), .style = &.{ .width = .grow(), .height = .fixed(42), .direction = .row, .gap = 8, .overflow = .scroll_x } };
        _ = try branch_list.open(ctx);
        for (snapshot.branches, 0..) |branch, i| if (try buttonKey(ctx, ui.Key.str("branch-tool").indexed(i), branch, self.available(), false)) try self.request(ctx, .switch_branch, branch, "");
        try branch_list.close(ctx);
        try branches.close(ctx);
        const remotes = try settingRow(ctx, "remotes", "Remotes", if (snapshot.remotes.len > 0) try std.mem.join(ctx.arena(), ", ", snapshot.remotes) else "No remotes configured.", false, false);
        try remotes.close(ctx);
        try status.close(ctx);
    }
    const operation_labels = try ctx.arena().alloc([]const u8, tool_operations.len);
    for (tool_operations, operation_labels) |op, *name| {
        const text = try ctx.arena().dupe(u8, @tagName(op));
        std.mem.replaceScalar(u8, text, '_', ' ');
        text[0] = std.ascii.toUpper(text[0]);
        if (std.mem.startsWith(u8, text, "Lfs")) @memcpy(text[0..3], "LFS");
        name.* = text;
    }
    const run = try settingGroup(ctx, "operation-run");
    const form = try settingRow(ctx, "operation-form", "Run an operation", "Pull uses fast-forward only. Branch deletion is safe. Destructive operations ask for confirmation.", true, true);
    const selected = try ctx.interact(ui.component.SelectInput(model.Operation){ .key = .str("operation-select"), .values = &tool_operations, .labels = operation_labels, .initial_selected = self.operation_index, .style = &.{ .width = .fixed(350), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9), .font_size = .sm } });
    if (selected.selected) |s| self.operation_index = s.index;
    const index = @min(self.operation_index, tool_operations.len - 1);
    const op = tool_operations[index];
    try ctx.e(TextInput{ .key = .str("operation-value"), .buf = &self.value_input, .placeholder = "Branch, tag, commit, path, remote name or message", .style = &.{ .width = .fixed(560), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    switch (op) {
        .stage, .unstage, .discard, .resolve_ours, .resolve_theirs, .lfs_lock, .lfs_unlock => {
            const browse_actions = try row(ctx, "operation-browse-actions");
            if (try button(ctx, "browse-operation-file", "Choose file…", self.available() and !self.picker_open and self.path() != null, false)) try self.browse(.file, &self.value_input, true, "Choose a repository file");
            if (op == .stage or op == .unstage or op == .discard) {
                if (try button(ctx, "browse-operation-folder", "Choose folder…", self.available() and !self.picker_open and self.path() != null, false)) try self.browse(.folder, &self.value_input, true, "Choose a repository folder");
            }
            try browse_actions.close(ctx);
        },
        else => {},
    }
    try ctx.e(TextInput{ .key = .str("operation-second"), .buf = &self.second_input, .placeholder = "Remote URL, local remote folder, or remote name for publish", .style = &.{ .width = .fixed(560), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    if (op == .add_remote or op == .set_remote) {
        if (try button(ctx, "browse-local-remote", "Choose local remote folder…", self.available() and !self.picker_open, false)) try self.browse(.folder, &self.second_input, false, "Choose a local remote repository");
    }
    if (try self.operationButton(ctx, "execute-operation", try std.fmt.allocPrint(ctx.arena(), "Run {s}", .{operation_labels[index]}), self.available() and self.path() != null, true, op)) try self.request(ctx, op, self.value_input.items, self.second_input.items);
    try form.close(ctx);
    try run.close(ctx);
    try label(ctx, "operations-help", "Commit uses the configured Git identity, hooks and signing settings. Resolve conflicts in your editor, stage the resolution, then continue.", .dimmed);
    try label(ctx, "operation-log", self.notice, if (self.notice_error) .@"error" else .text);
    try panel.close(ctx);
}
fn gitStatus(self: *Self, ctx: *ui.Frame) !void {
    if (!self.registry.enabled("weaver.git")) return;
    const health = if (self.git_health) |*s| s else null;
    const content = if (health) |s| try s.label(ctx.arena()) else "Git…";
    const indicator = if (health) |s| s.indicator() else .unknown;
    const has_update = indicator == .update_available;
    const git_group = Rect{ .key = .str("git-status-group"), .style = &.{ .height = .fixed(22), .direction = .row, .gap = if (has_update) 6 else 16, .@"align" = .center, .padding = .xy(if (has_update) 4 else 0, 0), .border_width = .all(if (has_update) 1 else 0), .border_color = .toned, .radius = .{ .fixed = 5 } } };
    _ = try git_group.open(ctx);
    const version_group = Rect{ .key = .str("git-status-version-group"), .style = &.{ .direction = .row, .gap = 5, .@"align" = .center } };
    _ = try version_group.open(ctx);
    try ctx.e(Rect{ .key = .str("git-status-dot"), .style = &.{ .width = .fixed(6), .height = .fixed(6), .radius = .{ .fixed = 3 }, .background = switch (indicator) {
        .unavailable => .@"error",
        .update_available => .warning,
        .current => .success,
        .unknown => .dimmed,
    } } });
    const tooltip = ui.component.Tooltip{ .key = .str("git-status-tooltip"), .content = if (health) |s| s.check_note else "Checking installed Git", .placement = .top };
    _ = try tooltip.open(ctx);
    if ((try ctx.interact(Button{ .key = .str("git-status"), .label = try diff.safeText(ctx.arena(), content), .style = &.{ .height = .fixed(20), .padding = .xy(3, 0), .font_size = .xs, .background = .transparent, .foreground = .dimmed, .radius = .sm, .hover = &.{ .background = .muted, .foreground = .text } } })).clicked) self.git_health_open = true;
    try tooltip.close(ctx);
    try version_group.close(ctx);
    if (health) |s| if (s.presence == .missing or s.update_available) {
        const action = if (s.presence == .missing) "Install Git" else "Update available";
        if ((try ctx.interact(Button{ .key = .str("git-status-action"), .label = action, .disabled = self.git_installing, .style = &.{ .height = .fixed(20), .padding = .xy(5, 0), .font_size = .xs, .background = .transparent, .foreground = .dimmed, .radius = .sm, .hover = &.{ .background = .muted, .foreground = .text } } })).clicked) self.git_health_open = true;
    };
    try git_group.close(ctx);
}
fn gitHealthDialog(self: *Self, ctx: *ui.Frame) !void {
    if (!self.git_health_open or !self.registry.enabled("weaver.git")) return;
    const dialog = ui.component.Dialog{ .key = .str("git-health-dialog"), .is_open = &self.git_health_open, .style = &.{ .width = .fixed(600), .gap = 14 } };
    _ = try dialog.open(ctx);
    try heading(ctx, "Git on this computer", "Installation and stable updates");
    if (self.git_health) |*health| {
        try label(ctx, "git-installed-version", try health.label(ctx.arena()), .text);
        if (health.executable.len > 0) try wrapped(ctx, "git-executable", health.executable, .dimmed);
        try label(ctx, "git-installation-manager", try std.fmt.allocPrint(ctx.arena(), "Installation: {s}", .{git_runtime.managerName(health.manager)}), .dimmed);
        if (health.update_available) try label(ctx, "git-latest-version", try std.fmt.allocPrint(ctx.arena(), "Available: {s}", .{health.latest}), .text);
        try wrapped(ctx, "git-check-note", health.check_note, .dimmed);
        try wrapped(ctx, "git-manager-description", health.description(), .dimmed);
        if (git_runtime.canApply(health)) {
            try wrapped(ctx, "git-apply-command", try std.mem.join(ctx.arena(), " ", try git_runtime.applyArguments(ctx.arena(), health)), .dimmed);
            if (try button(ctx, "git-install-update", if (health.presence == .missing) "Install Git" else "Update Git", self.available() and !self.git_health_busy and !self.background_busy and !self.counts_busy and !self.preview_busy, true)) {
                try self.launchGitHealth(health.*, self.gitUpdateChecks());
                self.message("Installing Git…", false);
            }
        }
        if (!git_runtime.canApply(health) and (health.presence == .missing or health.update_available)) {
            if (try button(ctx, "git-manual-install-update", if (health.presence == .missing) "Install Git…" else "Update Git…", !self.git_installing, true))
                try openPath(self.io, self.a, git_runtime.managerInstructions(health.manager, @import("builtin").os.tag));
        }
        if (git_runtime.guidedManager(health.manager)) {
            if (try button(ctx, "git-manage-installation", try std.fmt.allocPrint(ctx.arena(), "Manage Git with {s}…", .{git_runtime.managerName(health.manager)}), !self.git_installing, false))
                try openPath(self.io, self.a, git_runtime.managerInstructions(health.manager, @import("builtin").os.tag));
        }
        if (self.git_installing) try wrapped(ctx, "git-install-progress", "Running the Git installation command. Weaver waits for it to finish, then verifies the installed version. Complete any administrator prompt it opens.", .dimmed);
        if (self.git_install_report.len > 0) {
            try label(ctx, "git-last-command", "Last Git command result", .dimmed);
            const report = Rect{ .key = .str("git-install-output"), .style = &.{ .width = .grow(), .height = .{ .kind = .fit, .max = 180 }, .padding = .xy(12, 10), .radius = .md, .background = .muted, .overflow = .scroll_y } };
            _ = try report.open(ctx);
            try ctx.e(Text{ .key = .str("git-install-result"), .content = self.git_install_report, .style = &.{ .width = .grow(), .wrap = true, .font = "mono", .font_size = .xs, .foreground = if (self.git_install_failed) .@"error" else .dimmed } });
            try report.close(ctx);
        }
    } else try label(ctx, "git-health-loading", "Checking installed Git…", .dimmed);
    const actions = try row(ctx, "git-health-actions");
    if (try button(ctx, "git-check-again", "Check again", !self.git_health_busy, false)) try self.checkGitRuntime(true);
    const manager = if (self.git_health) |health| health.manager else .manual;
    if (try button(ctx, "git-install-instructions", if (git_runtime.guidedManager(manager)) "Manager instructions" else "Installation instructions", !self.git_installing, false)) try openPath(self.io, self.a, git_runtime.managerInstructions(manager, @import("builtin").os.tag));
    if (try button(ctx, "git-health-close", "Close", true, false)) self.git_health_open = false;
    try actions.close(ctx);
    try dialog.close(ctx);
}
fn extensions(self: *Self, ctx: *ui.Frame) !void {
    const panel = try pagePanel(ctx, "extensions");
    try heading(ctx, "Extensions", "Make Weaver your own. Bundled tools and installable extensions.");
    for (self.registry.items.items, 0..) |*extension, i| {
        const card = Rect{ .key = ui.Key.str("extension-card").indexed(i), .style = comptime &.{ .width = .grow(), .padding = .xy(16, 14), .direction = .column, .gap = 10, .border_width = .all(1), .border_color = .muted, .radius = .lg } };
        _ = try card.open(ctx);
        const head = Rect{ .key = ui.Key.str("extension-head").indexed(i), .style = comptime &.{ .width = .grow(), .direction = .row, .gap = 16, .@"align" = .center } };
        _ = try head.open(ctx);
        const text = Rect{ .key = ui.Key.str("extension-text").indexed(i), .style = comptime &.{ .width = .grow(), .direction = .column, .gap = 3 } };
        _ = try text.open(ctx);
        const title = Rect{ .key = ui.Key.str("extension-title-row").indexed(i), .style = comptime &.{ .direction = .row, .gap = 8, .@"align" = .center } };
        _ = try title.open(ctx);
        try ctx.e(Text{ .key = ui.Key.str("extension-title").indexed(i), .content = extension.manifest.name, .style = &.{ .font_size = .sm } });
        try ctx.e(Text{ .key = ui.Key.str("extension-version").indexed(i), .content = try std.fmt.allocPrint(ctx.arena(), "{s} · {s}", .{ extension.manifest.version, extension.manifest.publisher }), .style = &.{ .foreground = .dimmed, .font_size = .xs } });
        try title.close(ctx);
        try ctx.e(Text{ .key = ui.Key.str("extension-description").indexed(i), .content = extension.manifest.description, .style = &.{ .width = .grow(), .wrap = true, .foreground = .dimmed, .font_size = .xs } });
        try text.close(ctx);
        if (try toggle(ctx, ui.Key.str("extension-enable").indexed(i), extension.manifest.name, extension.enabled) and !self.busy and !self.git_installing) {
            extension.enabled = !extension.enabled;
            if (std.mem.eql(u8, extension.manifest.id, "weaver.git")) {
                self.git_probe_at = 0;
                self.git_updates_at = 0;
            }
            try self.saveExtensions();
            ctx.requestRedraw();
        }
        try head.close(ctx);
        if (extension.enabled and std.mem.eql(u8, extension.manifest.id, "weaver.git")) {
            if (try button(ctx, "git-extension-runtime", "Git installation and updates", true, false)) self.git_health_open = true;
        }
        const permission_names = try ctx.arena().alloc([]const u8, extension.manifest.permissions.len);
        for (permission_names, extension.manifest.permissions) |*name, permission| name.* = switch (permission) {
            .repository_read => "Read repositories",
            .repository_write => "Change repositories",
            .network => "Network",
            .process_execution => "Run programs",
        };
        const permissions_text = if (permission_names.len == 0) "No additional access" else try std.mem.join(ctx.arena(), ", ", permission_names);
        try ctx.e(Text{ .key = ui.Key.str("extension-permissions").indexed(i), .content = try std.fmt.allocPrint(ctx.arena(), "Access: {s}{s}", .{ permissions_text, if (extension.builtin) " · bundled" else " · executable extensions run with your user permissions" }), .style = &.{ .foreground = if (extension.builtin) .dimmed else .warning, .font_size = .xs } });
        if (extension.enabled and extension.manifest.commands.len > 0) {
            const commands = Rect{ .key = ui.Key.str("extension-commands").indexed(i), .style = comptime &.{ .width = .grow(), .direction = .row, .gap = 8, .overflow = .hidden } };
            _ = try commands.open(ctx);
            for (extension.manifest.commands, 0..) |command, j| {
                if (try buttonKey(ctx, ui.Key.str("extension-command").indexed(i).indexed(j), command.title, self.available() and self.path() != null, false)) {
                    if (extension.builtin) {
                        if (command.operation) |operation| try self.request(ctx, operation, "", "");
                    } else {
                        self.pending_extension = .{ .manifest = extension.manifest, .command = command, .settings = extension.settings };
                        self.confirm_open = true;
                    }
                }
            }
            try commands.close(ctx);
        }
        if (extension.enabled and extension.manifest.settings.len > 0) {
            for (extension.manifest.settings, 0..) |setting, j| {
                try ctx.e(Text{ .key = ui.Key.str("extension-setting-title").indexed(i).indexed(j), .content = setting.title, .style = &.{ .foreground = .dimmed, .font_size = .xs } });
                try ctx.e(TextInput{ .key = ui.Key.str("extension-setting-input").indexed(i).indexed(j), .buf = &extension.inputs[j], .placeholder = setting.description, .style = &.{ .width = .grow(), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
            }
            if (try buttonKey(ctx, ui.Key.str("extension-settings-save").indexed(i), "Save extension settings", !self.busy and !self.git_installing, false)) {
                for (extension.settings, 0..) |*setting, j| {
                    if (extension.inputs[j].items.len > 4096) {
                        self.message("Extension settings are limited to 4,096 bytes each.", true);
                        continue;
                    }
                    if (std.mem.eql(u8, setting.id, "git.check_updates")) {
                        const value = std.mem.trim(u8, extension.inputs[j].items, " \t\r\n");
                        if (!std.ascii.eqlIgnoreCase(value, "true") and !std.ascii.eqlIgnoreCase(value, "false")) {
                            self.message("Git update checks must be true or false.", true);
                            continue;
                        }
                        self.git_probe_at = 0;
                        self.git_updates_at = 0;
                    }
                    setting.value = try self.registry.arena.allocator().dupe(u8, extension.inputs[j].items);
                }
                try self.saveExtensions();
            }
        }
        try card.close(ctx);
    }
    const install = try settingGroup(ctx, "extension-install");
    const install_row = try settingRow(ctx, "extension-install-row", "Install an extension", "Choose the manifest.json of an extension on this computer.", true, true);
    const manifest_row = try row(ctx, "extension-path-row");
    try ctx.e(TextInput{ .key = .str("extension-path"), .buf = &self.extension_path, .placeholder = "Path to manifest.json", .style = &.{ .width = .fixed(420), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    if (try button(ctx, "browse-extension", "Browse…", self.available() and !self.picker_open, false)) try self.browse(.manifest, &self.extension_path, false, "Choose an extension manifest");
    const install_clicked = try button(ctx, "install-extension", "Install", self.available() and self.extension_path.items.len > 0, true);
    try manifest_row.close(ctx);
    try install_row.close(ctx);
    try install.close(ctx);
    if (install_clicked) {
        if (self.registry.install(self.io, self.extension_path.items)) |_| try self.saveExtensions() else |err| self.message(@errorName(err), true);
    }
    try label(ctx, "extension-command-output", self.notice, if (self.notice_error) .@"error" else .text);
    try panel.close(ctx);
}
const SettingsSection = enum {
    appearance,
    diff,
    sync,
    github,
    updates,
    workspace,

    fn title(self: SettingsSection) []const u8 {
        return switch (self) {
            .appearance => "Appearance",
            .diff => "Diff view",
            .sync => "Sync",
            .github => "GitHub",
            .updates => "Updates",
            .workspace => "Workspace",
        };
    }
    fn summary(self: SettingsSection) []const u8 {
        return switch (self) {
            .appearance => "Theme, accent color and text size.",
            .diff => "How changes are drawn in the diff pane.",
            .sync => "Keep the change list and remotes up to date.",
            .github => "Sign in to browse and clone your repositories.",
            .updates => "Signed releases of Weaver.",
            .workspace => "Repositories and files Weaver keeps on this computer.",
        };
    }
};
fn sectionVisible(self: *Self, section: SettingsSection) bool {
    return switch (section) {
        .appearance => self.registry.enabled("weaver.appearance"),
        .github => self.registry.enabled("weaver.github"),
        else => true,
    };
}
fn settings(self: *Self, ctx: *ui.Frame) !void {
    if (!self.sectionVisible(self.settings_section)) self.settings_section = .diff;
    const panel = Rect{ .key = .str("settings"), .style = comptime &.{ .width = .grow(), .height = .grow(), .direction = .row, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try panel.open(ctx);
    const menu = Rect{ .key = .str("settings-menu"), .style = comptime &.{ .width = .fixed(196), .height = .grow(), .direction = .column, .padding = .all(12), .gap = 2, .border_width = .edges(0, 1, 0, 0), .border_color = .muted } };
    _ = try menu.open(ctx);
    try ctx.e(Text{ .key = .str("settings-title"), .content = "Settings", .style = &.{ .font_size = .lg, .padding = .xy(10, 8) } });
    for (std.enums.values(SettingsSection)) |section| if (self.sectionVisible(section)) {
        if (try navKey(ctx, ui.Key.str("settings-section").indexed(@backingInt(section)), section.title(), self.settings_section == section, true)) self.settings_section = section;
    };
    try menu.close(ctx);
    const section = self.settings_section;
    const body = Rect{ .key = ui.Key.str("settings-body").indexed(@backingInt(section)), .style = comptime &.{ .width = .grow(), .height = .grow(), .direction = .column, .padding = .xy(28, 22), .overflow = .scroll_y } };
    _ = try body.open(ctx);
    const column = Rect{ .key = .str("settings-column"), .style = comptime &.{ .width = .{ .kind = .grow, .max = 760 }, .direction = .column, .gap = 14 } };
    _ = try column.open(ctx);
    try ctx.e(Text{ .key = .str("settings-heading"), .content = section.title(), .style = &.{ .font_size = .lg } });
    try label(ctx, "settings-summary", section.summary(), .dimmed);
    switch (section) {
        .appearance => try self.appearanceSettings(ctx),
        .diff => try self.diffSettings(ctx),
        .sync => try self.syncSettings(ctx),
        .github => try self.githubSettings(ctx),
        .updates => try self.updateSettings(ctx),
        .workspace => try self.workspaceSettings(ctx),
    }
    try column.close(ctx);
    try body.close(ctx);
    try panel.close(ctx);
}
fn applyAppearance(self: *Self, ctx: *ui.Frame) !void {
    ctx.ui().theme = themes.theme(self.config.data.theme, self.config.data.accent, self.config.data.text_size);
    try self.config.save(self.io);
}
fn appearanceSettings(self: *Self, ctx: *ui.Frame) !void {
    const data = &self.config.data;
    const look = try settingGroup(ctx, "appearance-look");
    const theme_row = try settingRow(ctx, "theme", "Theme", "Surface colors for the whole app.", true, true);
    const choices = std.enums.values(config_mod.Theme);
    var first: usize = 0;
    while (first < choices.len) : (first += 5) {
        const cards = Rect{ .key = ui.Key.str("theme-cards").indexed(first), .style = comptime &.{ .direction = .row, .gap = 8 } };
        _ = try cards.open(ctx);
        for (choices[first..@min(first + 5, choices.len)]) |choice| if (try self.themeCard(ctx, choice)) {
            data.theme = choice;
            try self.applyAppearance(ctx);
        };
        try cards.close(ctx);
    }
    try theme_row.close(ctx);
    const accent_row = try settingRow(ctx, "accent", "Accent color", try std.fmt.allocPrint(ctx.arena(), "{s} · highlights, selection and primary buttons.", .{themes.accentName(data.accent)}), false, true);
    const swatches = try row(ctx, "accent-swatches");
    for (themes.accents, 0..) |accent, i| if (try accentSwatch(ctx, i, accent, std.ascii.eqlIgnoreCase(accent.hex, data.accent))) {
        data.accent = accent.hex;
        try self.applyAppearance(ctx);
    };
    try swatches.close(ctx);
    try accent_row.close(ctx);
    try look.close(ctx);
    const text = try settingGroup(ctx, "appearance-text");
    const size_row = try settingRow(ctx, "text-size", "Interface text size", "Scales labels, lists and buttons across the app.", true, false);
    if (try segmented(ctx, "text-size-choice", &.{ "Small", "Default", "Large", "Extra large" }, @backingInt(data.text_size))) |i| {
        data.text_size = @fromBackingInt(@intCast(i));
        try self.applyAppearance(ctx);
    }
    try size_row.close(ctx);
    try text.close(ctx);
}
/// A miniature window drawn in the theme's own colors.
fn themeCard(self: *Self, ctx: *ui.Frame, choice: config_mod.Theme) !bool {
    const key = ui.Key.str("theme-card").indexed(@backingInt(choice));
    const active = self.config.data.theme == choice;
    const preview = themes.theme(choice, self.config.data.accent, .medium);
    const b = Button{ .key = key, .style = &.{ .width = .fixed(128), .direction = .column, .padding = .all(6), .gap = 7, .radius = .lg, .background = .transparent, .foreground = if (active) .text else .dimmed, .border_width = .all(2), .border_color = if (active) .accent else .muted } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .radio, .name = themes.themeName(choice), .state = .{ .checked = active } });
    const window = Rect{ .key = key.indexed(1), .style = &.{ .width = .grow(), .height = .fixed(66), .direction = .row, .padding = .all(7), .gap = 5, .radius = .sm, .background = .{ .color = preview.bg } } };
    _ = try window.open(ctx);
    const side = Rect{ .key = key.indexed(2), .style = &.{ .width = .fixed(30), .height = .grow(), .direction = .column, .padding = .all(5), .gap = 4, .radius = .{ .fixed = 4 }, .background = .{ .color = preview.elevated } } };
    _ = try side.open(ctx);
    try previewBar(ctx, key.indexed(3), 20, preview.primary);
    try previewBar(ctx, key.indexed(4), 16, preview.toned);
    try previewBar(ctx, key.indexed(5), 18, preview.toned);
    try side.close(ctx);
    const main = Rect{ .key = key.indexed(6), .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .padding = .all(6), .gap = 5, .radius = .{ .fixed = 4 }, .background = .{ .color = preview.elevated } } };
    _ = try main.open(ctx);
    try previewBar(ctx, key.indexed(7), 34, preview.text);
    try previewBar(ctx, key.indexed(8), 48, preview.dimmed);
    try previewBar(ctx, key.indexed(9), 26, preview.dimmed);
    try previewBar(ctx, key.indexed(10), 22, preview.primary);
    try main.close(ctx);
    try window.close(ctx);
    try ctx.e(Text{ .key = key.indexed(11), .content = themes.themeName(choice), .selectable = false, .style = &.{ .font_size = .xs } });
    try b.close(ctx);
    return response.clicked and !active;
}
fn previewBar(ctx: *ui.Frame, key: ui.Key, width: f32, color: ui.Color) !void {
    try ctx.e(Rect{ .key = key, .style = &.{ .width = .fixed(width), .height = .fixed(4), .radius = .{ .fixed = 2 }, .background = .{ .color = color } } });
}
fn accentSwatch(ctx: *ui.Frame, i: usize, accent: themes.Accent, active: bool) !bool {
    const key = ui.Key.str("accent-swatch").indexed(i);
    const color = ui.Color.hex(accent.hex) catch unreachable;
    const tooltip = ui.component.Tooltip{ .key = key.indexed(100), .content = accent.name, .placement = .bottom, .style = &.{ .width = .fixed(38), .height = .fixed(38) } };
    _ = try tooltip.open(ctx);
    // The ring sits outside the chip so the selected color keeps its size.
    const b = Button{ .key = key, .style = &.{ .width = .fixed(38), .height = .fixed(38), .padding = .all(0), .radius = .{ .fixed = 13 }, .background = .transparent, .border_width = .all(2), .border_color = if (active) .{ .color = color } else .transparent, .hover = &.{ .background = .muted, .state_layer = 0 } } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .radio, .name = accent.name, .state = .{ .checked = active } });
    const chip = Rect{ .key = key.indexed(1), .style = &.{ .width = .fixed(26), .height = .fixed(26), .radius = .{ .fixed = 9 }, .background = .{ .color = color } } };
    _ = try chip.open(ctx);
    if (active) {
        const ink = ctx.ui().theme.on_primary.value;
        const points = [_][2]f32{ .{ 7.5, 13.5 }, .{ 11.5, 17.5 }, .{ 18.5, 9 } };
        var check: [5]ui.component.Canvas.DrawCmd = undefined;
        for (points, 0..) |point, n| check[n] = .{ .fill_circle = .{ .cx = point[0], .cy = point[1], .radius = 1, .color = ink } };
        check[3] = .{ .line = .{ .from = points[0], .to = points[1], .color = ink, .thickness = 2 } };
        check[4] = .{ .line = .{ .from = points[1], .to = points[2], .color = ink, .thickness = 2 } };
        try ctx.e(ui.component.Canvas{ .key = key.indexed(2), .commands = &check, .style = &.{ .width = .fixed(26), .height = .fixed(26) } });
    }
    try chip.close(ctx);
    try b.close(ctx);
    try tooltip.close(ctx);
    return response.clicked and !active;
}
fn diffFont(font: config_mod.DiffFont) []const u8 {
    return switch (font) {
        .mono => "mono",
        .sans => "default",
    };
}
fn diffSettings(self: *Self, ctx: *ui.Frame) !void {
    const data = &self.config.data;
    const card = try settingGroup(ctx, "diff-options");
    const font_row = try settingRow(ctx, "diff-font", "Font", "Monospace keeps columns aligned; proportional reads more like prose.", true, false);
    if (try segmented(ctx, "diff-font-choice", &.{ "JetBrains Mono", "Roboto" }, @backingInt(data.diff_font))) |i| {
        data.diff_font = @fromBackingInt(@intCast(i));
        try self.config.save(self.io);
    }
    try font_row.close(ctx);
    const size_row = try settingRow(ctx, "diff-size", "Font size", "Line height follows the size you pick.", false, false);
    if (try segmented(ctx, "diff-size-choice", &.{ "11", "12", "13", "14", "15" }, data.diff_font_size - 11)) |i| {
        data.diff_font_size = @intCast(11 + i);
        try self.config.save(self.io);
    }
    try size_row.close(ctx);
    const layout_row = try settingRow(ctx, "diff-layout-default", "Layout", "Unified shows changes inline; split puts before and after side by side.", false, false);
    if (try segmented(ctx, "diff-layout-choice", &.{ "Unified", "Split" }, @intFromBool(data.split_diff))) |i| {
        data.split_diff = i == 1;
        self.split_diff = data.split_diff;
        try self.config.save(self.io);
    }
    try layout_row.close(ctx);
    try card.close(ctx);
    try label(ctx, "diff-preview-label", "PREVIEW", .dimmed);
    diff_row_height = diffRowHeight(ctx, data.diff_font_size);
    const preview = Rect{ .key = .str("diff-preview"), .style = &.{ .width = .grow(), .direction = .column, .padding = .xy(0, 8), .border_width = .all(1), .border_color = .muted, .radius = .lg, .overflow = .hidden, .font = diffFont(data.diff_font), .font_size = .{ .px = @floatFromInt(data.diff_font_size) } } };
    _ = try preview.open(ctx);
    const sample = [_]diff.Line{
        .{ .text = " fn greet(name: []const u8) void {", .kind = .context, .old = 12, .new = 12 },
        .{ .text = "-    print(\"hello {s}\", .{name});", .kind = .deletion, .old = 13 },
        .{ .text = "+    // Greet politely.", .kind = .addition, .new = 13 },
        .{ .text = "+    print(\"Good morning, {s}\", .{name});", .kind = .addition, .new = 14 },
        .{ .text = " }", .kind = .context, .old = 14, .new = 15 },
    };
    for (sample, 0..) |line, i| try renderLine(ctx, line, i);
    try preview.close(ctx);
}
fn syncSettings(self: *Self, ctx: *ui.Frame) !void {
    const data = &self.config.data;
    const card = try settingGroup(ctx, "sync-options");
    const refresh_row = try settingRow(ctx, "auto-refresh-row", "Automatic refresh", "Update the change list when files in the repository change.", true, false);
    if (try toggle(ctx, .str("auto-refresh"), "Automatic refresh", data.auto_refresh)) {
        data.auto_refresh = !data.auto_refresh;
        try self.config.save(self.io);
    }
    try refresh_row.close(ctx);
    const fetch_row = try settingRow(ctx, "auto-fetch-row", "Automatic fetch", "Check the current repository for incoming commits every 5 minutes. You can also fetch manually.", false, false);
    if (try toggle(ctx, .str("auto-fetch"), "Automatic fetch", data.auto_fetch)) {
        data.auto_fetch = !data.auto_fetch;
        try self.config.save(self.io);
    }
    try fetch_row.close(ctx);
    try card.close(ctx);
}
fn githubSettings(self: *Self, ctx: *ui.Frame) !void {
    const login = self.config.data.github_login;
    const card = try settingGroup(ctx, "github-account");
    const account = try settingRow(ctx, "github-status", "Account", if (login.len > 0) try std.fmt.allocPrint(ctx.arena(), "Signed in as {s}", .{login}) else "Not signed in on this computer.", true, false);
    if (login.len > 0) {
        if (try button(ctx, "github-sign-out", "Sign out", self.available(), false)) try self.launch(.sign_out, "", .{ .operation = .refresh });
    } else if (try button(ctx, "github-sign-in", "Sign in with GitHub", self.available() and self.device == null, true)) {
        try self.launch(.auth_begin, "", .{ .operation = .refresh });
        if (self.client_input.items.len == 0) self.message("Finish signing in to GitHub in the window that opens.", false);
    }
    try account.close(ctx);
    if (self.device) |device| {
        const code = try settingRow(ctx, "device-code", try std.fmt.allocPrint(ctx.arena(), "Your code: {s}", .{device.user_code}), "Open https://github.com/login/device in your browser and enter this code.", false, true);
        const code_line = try row(ctx, "device-code-line");
        if (try button(ctx, "copy-code", "Copy sign-in code", true, false)) try ctx.writeClipboard(device.user_code);
        if (try button(ctx, "cancel-sign-in", "Cancel sign-in", self.available(), false)) self.device = null;
        try code_line.close(ctx);
        try code.close(ctx);
    }
    try card.close(ctx);
    try label(ctx, "github-storage", "Sign-in uses Git Credential Manager, included with Git for Windows. Weaver remembers the account in\nWindows Credential Manager, macOS Keychain, or Linux Secret Service. Other hosts use Git credential helpers and your configured SSH client.", .dimmed);
}
fn updateSettings(self: *Self, ctx: *ui.Frame) !void {
    const card = try settingGroup(ctx, "update-options");
    const automatic = try settingRow(ctx, "automatic-updates-row", "Check automatically", "Look for a new signed release when Weaver starts.", true, false);
    if (try toggle(ctx, .str("automatic-updates"), "Check for updates automatically", self.config.data.auto_update_check)) {
        self.config.data.auto_update_check = !self.config.data.auto_update_check;
        try self.config.save(self.io);
    }
    try automatic.close(ctx);
    const source = try settingRow(ctx, "release-repo-row", "Release repository", "The GitHub repository that publishes Weaver releases.", false, true);
    const source_line = try row(ctx, "release-repo-line");
    try ctx.e(TextInput{ .key = .str("release-repo"), .buf = &self.release_input, .placeholder = "owner/weaver", .style = &.{ .width = .fixed(420), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    if (try button(ctx, "check-updates", "Check for updates", self.available(), false)) {
        try self.saveSettings();
        try self.launch(.update_check, self.config.path, .{ .operation = .refresh });
    }
    try source_line.close(ctx);
    try source.close(ctx);
    if (self.update) |update| {
        const pending = try settingRow(ctx, "update-notes", try std.fmt.allocPrint(ctx.arena(), "Version {s} is available", .{update.version}), update.notes, false, false);
        if (try button(ctx, "download-update", "Download verified update", self.available(), true)) try self.launch(.update_download, self.config.path, .{ .operation = .refresh });
        try pending.close(ctx);
    }
    if (self.downloaded) |downloaded| {
        const ready = try settingRow(ctx, "downloaded-update", "Update downloaded", downloaded, false, false);
        if (try button(ctx, "install-update", "Open installer", self.available(), true)) try openPath(self.io, self.a, downloaded);
        try ready.close(ctx);
    }
    try card.close(ctx);
    try label(ctx, "update-key", if (options.update_public_key.len == 64) "Update signatures are checked against this build’s trusted public key." else "Release updates need the public signing key configured at build time.", .dimmed);
}
fn workspaceSettings(self: *Self, ctx: *ui.Frame) !void {
    const card = try settingGroup(ctx, "workspace-options");
    const selected = try settingRow(ctx, "selected-repository", "Selected repository", if (self.path()) |p| try std.fmt.allocPrint(ctx.arena(), "{s}\nRemoving it only forgets it in Weaver; files stay on disk.", .{p}) else "No repository selected.", true, false);
    if (try button(ctx, "remove-repo", "Remove from workspace", self.available() and self.path() != null, false)) try self.removeRepository(self.config.data.selected);
    try selected.close(ctx);
    const file = try settingRow(ctx, "settings-file", "Settings file", self.config.path, false, false);
    if (try button(ctx, "show-settings-file", "Show folder", true, false)) try openPath(self.io, self.a, std.fs.path.dirname(self.config.path).?);
    try file.close(ctx);
    try card.close(ctx);
}
fn settingGroup(ctx: *ui.Frame, key: []const u8) !Rect {
    const rect = Rect{ .key = .str(key), .style = comptime &.{ .width = .grow(), .direction = .column, .border_width = .all(1), .border_color = .muted, .radius = .lg } };
    _ = try rect.open(ctx);
    return rect;
}
/// Opens a titled settings row; the caller adds its control and closes it.
/// Stacked rows place the control under the text instead of beside it.
fn settingRow(ctx: *ui.Frame, key: []const u8, title: []const u8, description: []const u8, comptime first: bool, comptime stacked: bool) !Rect {
    const rect = Rect{ .key = .str(key), .style = comptime &.{ .width = .grow(), .direction = if (stacked) .column else .row, .@"align" = if (stacked) .start else .center, .gap = if (stacked) 12 else 16, .padding = .xy(16, 14), .border_width = .edges(if (first) 0 else 1, 0, 0, 0), .border_color = .muted } };
    _ = try rect.open(ctx);
    const text = Rect{ .key = ui.Key.str(key).indexed(1), .style = comptime &.{ .width = .grow(), .direction = .column, .gap = 3 } };
    _ = try text.open(ctx);
    try ctx.e(Text{ .key = ui.Key.str(key).indexed(2), .content = try diff.safeText(ctx.arena(), title), .style = &.{ .font_size = .sm } });
    if (description.len > 0) try ctx.e(Text{ .key = ui.Key.str(key).indexed(3), .content = try diff.safeText(ctx.arena(), description), .style = &.{ .width = .grow(), .wrap = true, .foreground = .dimmed, .font_size = .xs } });
    try text.close(ctx);
    return rect;
}
fn toggle(ctx: *ui.Frame, key: ui.Key, name: []const u8, on: bool) !bool {
    const b = Button{ .key = key, .style = &.{ .width = .fixed(38), .height = .fixed(22), .padding = .all(3), .justify = if (on) .end else .start, .radius = .{ .fixed = 11 }, .background = if (on) .accent else .toned } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .checkbox, .name = name, .state = .{ .checked = on } });
    try ctx.e(Rect{ .key = key.indexed(1), .style = &.{ .width = .fixed(16), .height = .fixed(16), .radius = .{ .fixed = 8 }, .background = if (on) .on_accent else .text } });
    try b.close(ctx);
    return response.clicked;
}
/// A row of mutually exclusive choices; returns the newly picked index.
fn segmented(ctx: *ui.Frame, key: []const u8, labels: []const []const u8, selected: usize) !?usize {
    const track = Rect{ .key = .str(key), .style = comptime &.{ .direction = .row, .gap = 2, .padding = .all(3), .background = .muted, .radius = .md } };
    _ = try track.open(ctx);
    var picked: ?usize = null;
    for (labels, 0..) |content, i| {
        const active = i == selected;
        if ((try ctx.interact(Button{ .key = ui.Key.str(key).indexed(i + 1), .label = content, .style = &.{ .padding = .xy(12, 5), .font_size = .xs, .radius = .sm, .background = if (active) .elevated else .transparent, .foreground = if (active) .text else .dimmed } })).clicked and !active) picked = i;
    }
    try track.close(ctx);
    return picked;
}
fn saveSettings(self: *Self) !void {
    const a = self.config.arena.allocator();
    self.config.data.oauth_client_id = try a.dupe(u8, self.client_input.items);
    self.config.data.release_repo = try a.dupe(u8, self.release_input.items);
    try self.config.save(self.io);
}
fn saveExtensions(self: *Self) !void {
    const a = self.config.arena.allocator();
    const states = try a.alloc(config_mod.ExtensionState, self.registry.items.items.len);
    for (self.registry.items.items, states) |extension, *state| {
        const settings_values = try a.alloc(config_mod.SettingValue, extension.settings.len);
        for (settings_values, extension.settings) |*copy, setting| copy.* = .{ .id = try a.dupe(u8, setting.id), .value = try a.dupe(u8, setting.value) };
        state.* = .{ .id = try a.dupe(u8, extension.manifest.id), .manifest_path = try a.dupe(u8, extension.manifest_path), .enabled = extension.enabled, .settings = settings_values };
    }
    self.config.data.extensions = states;
    try self.config.save(self.io);
}
fn githubPage(self: *Self, ctx: *ui.Frame) !void {
    const panel = try pagePanel(ctx, "github-page");
    try heading(ctx, "GitHub repositories", "Your public and private repositories, ready to clone over HTTPS or SSH.");
    if (try button(ctx, "load-github-repos", "Load my repositories", self.available(), true)) try self.launch(.github_repos, "", .{ .operation = .refresh });
    for (self.github_repositories, 0..) |repo, i| {
        const card = Rect{ .key = ui.Key.str("github-repo").indexed(i), .style = &.{ .width = .grow(), .direction = .column, .padding = .all(10), .gap = 8, .background = .muted, .radius = .md } };
        _ = try card.open(ctx);
        try ctx.e(Text{ .key = ui.Key.str("github-name").indexed(i), .content = repo.full_name, .style = &.{ .font_size = .md } });
        try ctx.e(Text{ .key = ui.Key.str("github-description").indexed(i), .content = repo.description orelse if (repo.private) "Private repository" else "Public repository", .style = &.{ .foreground = .dimmed, .font_size = .xs } });
        const actions = try row(ctx, try std.fmt.allocPrint(ctx.arena(), "github-actions-{d}", .{i}));
        if (try button(ctx, repo.clone_url, "Clone with HTTPS", self.available(), true)) {
            self.remote_input.clearRetainingCapacity();
            try self.remote_input.appendSlice(self.a, repo.clone_url);
            self.add_open = true;
        }
        if (try button(ctx, repo.ssh_url, "Clone with SSH", self.available(), false)) {
            self.remote_input.clearRetainingCapacity();
            try self.remote_input.appendSlice(self.a, repo.ssh_url);
            self.add_open = true;
        }
        try actions.close(ctx);
        try card.close(ctx);
    }
    try panel.close(ctx);
}
fn dialogs(self: *Self, ctx: *ui.Frame) !void {
    try self.gitHealthDialog(ctx);
    try self.iconDialog(ctx);
    try self.nameDialog(ctx);
    try self.remoteDialog(ctx);
    try self.failureDialog(ctx);
    if (!self.add_open) self.setup_notice = false;
    if (self.add_open) {
        const dialog = ui.component.Dialog{ .key = .str("add-dialog"), .is_open = &self.add_open, .style = &.{ .width = .fixed(600), .gap = 14 } };
        _ = try dialog.open(ctx);
        try heading(ctx, "Add a repository", "Open an existing folder, initialize a new one, or clone a remote.");
        if (self.setup_notice) try wrapped(ctx, "setup-notice", "This folder is not a Git repository yet. Initialize it to start tracking changes here, or enter a URL below to clone into it.", .warning);
        const folder_row = try row(ctx, "add-path-row");
        try ctx.e(TextInput{ .key = .str("add-path"), .buf = &self.path_input, .placeholder = "Choose a local repository folder", .style = &.{ .width = .grow(), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
        if (try button(ctx, "browse-repository", "Browse…", self.available() and !self.picker_open, false)) try self.browse(.folder, &self.path_input, false, if (self.remote_input.items.len > 0) "Choose an empty folder to clone into" else "Choose a repository folder");
        try folder_row.close(ctx);
        const source_row = try row(ctx, "add-source-row");
        try ctx.e(TextInput{ .key = .str("add-url"), .buf = &self.remote_input, .placeholder = "Optional HTTPS/SSH URL or local clone source", .style = &.{ .width = .grow(), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
        if (try button(ctx, "browse-clone-source", "Local source…", self.available() and !self.picker_open, false)) try self.browse(.folder, &self.remote_input, false, "Choose a local repository to clone");
        try source_row.close(ctx);
        if (self.remote_input.items.len > 0) try label(ctx, "clone-folder-help", "For cloning, choose or create an empty folder in the file picker.", .dimmed);
        const actions = try row(ctx, "add-actions");
        const ready = self.available() and std.fs.path.isAbsolute(self.path_input.items);
        if (try button(ctx, "open-repo", "Open folder", ready, !self.setup_notice)) {
            try self.openLocal(self.path_input.items);
        }
        if (try button(ctx, "init-repo", "Initialize", ready, self.setup_notice)) {
            try std.Io.Dir.cwd().createDirPath(self.io, self.path_input.items);
            try self.launch(.git, self.path_input.items, .{ .operation = .initialize });
            self.add_open = false;
        }
        if (try button(ctx, "clone-repo", "Clone", ready and self.remote_input.items.len > 0, false)) {
            const parent = std.fs.path.dirname(self.path_input.items).?;
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
            try self.launch(.git, parent, .{ .operation = .clone, .value = self.remote_input.items, .second = self.path_input.items });
            self.add_open = false;
        }
        if (try button(ctx, "cancel-add", "Cancel", true, false)) self.add_open = false;
        try actions.close(ctx);
        _ = try dialog.closeResponse(ctx);
    }
    if (self.confirm_open) {
        const dialog = ui.component.Dialog{ .key = .str("confirm-dialog"), .is_open = &self.confirm_open, .style = &.{ .width = .fixed(580), .gap = 16 } };
        _ = try dialog.open(ctx);
        try heading(ctx, "Confirm action", "Review the repository and action before continuing.");
        try label(ctx, "confirm-path", self.path() orelse "", .text);
        if (self.pending_request) |req| try label(ctx, "confirm-request", try std.fmt.allocPrint(ctx.arena(), "Action: {s}\nTarget: {s}\nThis may replace local changes or rewrite history. Make sure you have a backup.", .{ @tagName(req.operation), req.value }), .warning);
        if (self.pending_extension) |extension| try label(ctx, "confirm-extension", try std.fmt.allocPrint(ctx.arena(), "Extension: {s}\nExecutable: {s}\nCommand: {s}\nThis executable can access files and network with your user permissions. Only continue if you trust its publisher.", .{ extension.manifest.name, extension.manifest.executable orelse "", extension.command.id }), .warning);
        const actions = try row(ctx, "confirm-actions");
        if (try button(ctx, "confirm-run", "Continue", self.available(), true)) {
            if (self.path()) |p| {
                if (self.pending_request) |req| try self.launch(.git, p, req) else if (self.pending_extension != null) try self.launch(.extension, p, .{ .operation = .refresh });
            }
            self.pending_request = null;
            self.pending_extension = null;
            self.confirm_open = false;
        }
        if (try button(ctx, "confirm-cancel", "Cancel", true, false)) {
            self.pending_request = null;
            self.pending_extension = null;
            self.confirm_open = false;
        }
        try actions.close(ctx);
        _ = try dialog.closeResponse(ctx);
    }
}
/// First-remote setup, opened wherever a sync action finds no remote.
fn remoteDialog(self: *Self, ctx: *ui.Frame) !void {
    const snapshot = self.snapshot orelse {
        self.remote_open = false;
        return;
    };
    if (snapshot.remotes.len > 0) self.remote_open = false;
    if (!self.remote_open) return;
    const dialog = ui.component.Dialog{ .key = .str("remote-dialog"), .is_open = &self.remote_open, .style = &.{ .width = .fixed(600), .gap = 14 } };
    _ = try dialog.open(ctx);
    try heading(ctx, "Connect a remote", "A remote is the online copy of this repository, for example on GitHub. Pushing sends your commits there.");
    const has_commits = snapshot.history.len > 0;
    try label(ctx, "remote-status", if (has_commits)
        try std.fmt.allocPrint(ctx.arena(), "{d} {s} on {s} {s} saved on this computer and ready to push.", .{ snapshot.ahead, if (snapshot.ahead == 1) "commit" else "commits", snapshot.branch, if (snapshot.ahead == 1) "is" else "are" })
    else
        "There are no commits yet. You can connect now and push after your first commit.", .text);
    const url_row = try row(ctx, "remote-url-row");
    try ctx.e(TextInput{ .key = .str("remote-url"), .buf = &self.connect_input, .placeholder = "https://github.com/you/project.git or git@github.com:you/project.git", .style = &.{ .width = .grow(), .radius = .md, .background = .muted, .border_color = .toned, .padding = .xy(12, 9) } });
    if (try button(ctx, "remote-browse", "Local folder…", self.available() and !self.picker_open, false)) try self.browse(.folder, &self.connect_input, false, "Choose a local remote repository");
    try url_row.close(ctx);
    const url = std.mem.trim(u8, self.connect_input.items, " \t\r\n");
    const valid = process.validRemote(url);
    if (url.len > 0 and !valid) {
        try wrapped(ctx, "remote-invalid", "Enter an https://, ssh:// or git@ address, or the full path of a folder.", .warning);
    } else try wrapped(ctx, "remote-help", "No repository online yet? Create an empty one, without a README or license, then paste its address here. It is saved as \"origin\".", .dimmed);
    const actions = try row(ctx, "remote-actions");
    const ready = self.available() and valid;
    var connect = false;
    if (has_commits and try button(ctx, "remote-connect-push", "Connect and push", ready, true)) {
        connect = true;
        self.publish_after_connect = true;
    }
    if (try button(ctx, "remote-connect", "Connect only", ready, !has_commits)) connect = true;
    if (try button(ctx, "remote-create", "Create on GitHub", true, false)) openPath(self.io, self.a, "https://github.com/new") catch {
        self.message("Could not open your browser.", true);
    };
    if (try button(ctx, "remote-cancel", "Cancel", true, false)) self.remote_open = false;
    try actions.close(ctx);
    _ = try dialog.closeResponse(ctx);
    if (connect) {
        self.remote_open = false;
        try self.request(ctx, .add_remote, "origin", url);
    }
}
/// Explains a failed remote operation and offers the step that fixes it.
fn failureDialog(self: *Self, ctx: *ui.Frame) !void {
    if (!self.failure_open) return;
    const op = self.failure_operation;
    const snapshot = self.snapshot;
    const remote = if (snapshot) |s| guidance.defaultRemote(s.remotes) else null;
    const linked = if (snapshot) |s| s.upstream.len > 0 else false;
    const advice = guidance.advise(self.failure_text, remote != null or op == .clone);
    const dialog = ui.component.Dialog{ .key = .str("failure-dialog"), .is_open = &self.failure_open, .style = &.{ .width = .fixed(600), .gap = 14 } };
    _ = try dialog.open(ctx);
    try ctx.e(Text{ .key = .str("failure-title"), .content = switch (op) {
        .pull => "Pull did not finish",
        .fetch => "Fetch did not finish",
        .clone => "Clone did not finish",
        .add_remote => "The remote was not connected",
        else => "Push did not finish",
    }, .style = &.{ .font_size = .lg } });
    try wrapped(ctx, "failure-summary", if (advice == .pull_first and !linked)
        "The remote branch already has commits this branch does not share, often a README added when the repository was created. Connect an empty repository, or merge the remote branch from Repository tools."
    else
        advice.summary(), .dimmed);
    if (op == .push or op == .publish) try label(ctx, "failure-safe", "Your commits are still saved on this computer.", .text);
    if (self.failure_text.len > 0) {
        const output = Rect{ .key = .str("failure-output"), .style = comptime &.{ .width = .grow(), .height = .{ .kind = .fit, .max = 180 }, .padding = .xy(12, 10), .radius = .md, .background = .muted, .overflow = .scroll_y } };
        _ = try output.open(ctx);
        try ctx.e(Text{ .key = .str("failure-text"), .content = self.failure_text, .style = &.{ .width = .grow(), .wrap = true, .font = "mono", .font_size = .xs, .foreground = .dimmed } });
        try output.close(ctx);
    }
    const actions = try row(ctx, "failure-actions");
    const ready = self.available();
    const tools = advice == .diverged or advice == .unreachable_remote or (advice == .pull_first and !linked) or (advice == .connect_remote and remote != null);
    if (op == .clone) {
        if (try button(ctx, "failure-retry", "Edit and try again", ready, true)) {
            self.failure_open = false;
            self.add_open = true;
        }
    } else if (advice == .connect_remote and remote == null) {
        if (try button(ctx, "failure-connect", "Connect a remote…", ready, true)) self.openRemoteSetup(ctx);
    } else if (advice == .publish and remote != null and snapshot.?.history.len > 0) {
        if (try button(ctx, "failure-publish", "Publish branch", ready, true)) {
            self.failure_open = false;
            try self.request(ctx, .publish, snapshot.?.branch, remote.?);
        }
    } else if (advice == .pull_first and linked) {
        if (try button(ctx, "failure-pull", "Pull", ready, true)) {
            self.failure_open = false;
            try self.request(ctx, .pull, "", "");
        }
    } else if (advice == .sign_in and self.sectionVisible(.github)) {
        if (try button(ctx, "failure-sign-in", "Open GitHub settings", true, true)) {
            self.failure_open = false;
            self.page = .settings;
            self.settings_section = .github;
        }
    } else if (tools and try button(ctx, "failure-tools", "Open Repository tools", self.canNavigate(), true)) {
        self.failure_open = false;
        self.page = .operations;
    }
    if (try button(ctx, "failure-close", "Close", true, false)) self.failure_open = false;
    try actions.close(ctx);
    _ = try dialog.closeResponse(ctx);
}
fn browse(self: *Self, kind: file_picker.Kind, input: *std.ArrayList(u8), repository_relative: bool, title: []const u8) !void {
    if (self.busy or self.picker_open) return;
    self.picker_open = true;
    self.pending_picker = .{ .kind = kind, .input = input, .repository_relative = repository_relative, .title = title };
    self.app.main_viewport.window.postEmptyEvent();
}
fn showPicker(self: *Self, kind: file_picker.Kind, input: *std.ArrayList(u8), repository_relative: bool, title: []const u8) !void {
    const handle = self.app.main_viewport.window.getWindowHandle();
    const parent: file_picker.Parent = switch (handle) {
        .windows => |win| .{ .kind = .windows, .handle = win.hwnd },
        .macos => |mac| switch (mac) {
            .ns_window => |window| .{ .kind = .cocoa, .handle = window },
            else => .{},
        },
        .linux => |linux| switch (linux) {
            .wayland => |wayland| .{ .kind = .wayland, .handle = wayland.surface, .display = wayland.display },
            else => .{},
        },
        else => .{},
    };
    const base = self.path() orelse std.fs.path.dirname(self.config.path).?;
    const proposed = if (input.items.len == 0) try self.a.dupe(u8, base) else if (std.fs.path.isAbsolute(input.items)) try self.a.dupe(u8, input.items) else try std.fs.path.join(self.a, &.{ base, input.items });
    defer self.a.free(proposed);
    const directory = try path_selection.initialDirectory(self.io, self.a, proposed);
    defer if (directory) |value| self.a.free(value);
    const selected = file_picker.pick(self.a, .{ .kind = kind, .parent = parent, .directory = directory, .title = title }) catch |err| {
        if (input == &self.path_input) self.add_open = true;
        self.message(if (err == error.NativePickerUnavailable) "The system file picker is unavailable. You can still enter a path manually." else "Unable to open the system file picker. You can still enter a path manually.", true);
        return;
    };
    if (selected) |value| {
        defer self.a.free(value);
        const replacement = if (repository_relative) path_selection.repositoryRelative(self.a, self.path().?, value) catch {
            self.message("Choose a file or folder inside the current repository.", true);
            return;
        } else try self.a.dupe(u8, value);
        defer self.a.free(replacement);
        try input.ensureTotalCapacity(self.a, replacement.len);
        input.clearRetainingCapacity();
        try input.appendSlice(self.a, replacement);
        if (input == &self.path_input and self.remote_input.items.len == 0) {
            // The native modal has closed; background discovery can now start.
            self.picker_open = false;
            try self.openLocal(input.items);
        }
    }
}
fn label(ctx: *ui.Frame, key: []const u8, content: []const u8, color: ui.Color.Input) !void {
    try ctx.e(Text{ .key = .str(key), .content = try diff.safeText(ctx.arena(), content), .style = &.{ .foreground = color, .font_size = .xs } });
}
/// A label that wraps inside its container, for sentences in dialogs.
fn wrapped(ctx: *ui.Frame, key: []const u8, content: []const u8, color: ui.Color.Input) !void {
    try ctx.e(Text{ .key = .str(key), .content = try diff.safeText(ctx.arena(), content), .style = &.{ .width = .grow(), .wrap = true, .foreground = color, .font_size = .xs } });
}
fn sectionLabel(ctx: *ui.Frame, key: []const u8, content: []const u8) !void {
    try ctx.e(Text{ .key = .str(key), .content = content, .selectable = false, .style = &.{ .foreground = .dimmed, .font_size = .xs, .padding = .xy(10, 6) } });
}
fn fileIcon(ctx: *ui.Frame, key: ui.Key, path_value: []const u8) !void {
    return fileIconSized(ctx, key, path_value, 19);
}
fn fileIconSized(ctx: *ui.Frame, key: ui.Key, path_value: []const u8, size: f32) !void {
    const icon = icons.file(path_value);
    var color = ui.Color.hex(icon.color) catch unreachable;
    if (ctx.ui().theme.elevated.value[0] > 0.5) for (0..3) |i| {
        color.value[i] *= 0.4;
    };
    try ctx.e(Text{ .key = key, .content = icon.glyph, .selectable = false, .style = &.{ .width = .fixed(size + 3), .font = icon.font, .foreground = .{ .color = color }, .font_size = .{ .px = size } } });
}
fn button(ctx: *ui.Frame, key: []const u8, content: []const u8, enabled: bool, primary: bool) !bool {
    return buttonKey(ctx, .str(key), content, enabled, primary);
}
fn toolbarButton(ctx: *ui.Frame, icon: icons.Toolbar, enabled: bool, count: usize, working: bool) !bool {
    const key = ui.Key.str(@tagName(icon));
    const primary = count > 0;
    var accent = ctx.ui().theme.primary;
    if (ctx.ui().theme.elevated.value[0] > 0.5) for (0..3) |i| {
        accent.value[i] *= 0.55;
    };
    const primary_foreground: ui.Color.Input = .{ .color = accent };
    const description = if (count == 0) icon.label() else try std.fmt.allocPrint(ctx.arena(), "{s} · {d} {s} to {s}", .{ icon.label(), count, if (count == 1) "commit" else "commits", @tagName(icon) });
    const tooltip = ui.component.Tooltip{ .key = key.indexed(100), .content = description, .placement = .bottom, .style = &.{ .width = .fixed(32), .height = .fixed(32) } };
    _ = try tooltip.open(ctx);
    const b = Button{ .key = key, .disabled = !enabled, .style = &.{ .width = .fixed(32), .height = .fixed(32), .padding = .all(0), .justify = .center, .@"align" = .center, .radius = .{ .fixed = 6 }, .background = if (primary) themes.selection(ctx.ui().theme) else .transparent, .foreground = if (primary) primary_foreground else .dimmed, .hover = &.{ .background = .muted, .foreground = if (primary) primary_foreground else .text, .state_layer = 0 }, .active = &.{ .background = .toned, .state_layer = 0 } } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = description, .state = .{ .disabled = !enabled } });
    if (working) {
        try spinner(ctx, key.indexed(4), 15, if (primary) accent else ctx.ui().theme.dimmed);
    } else try ctx.e(Text{ .key = key.indexed(1), .content = icon.glyph(), .selectable = false, .style = &.{ .font = "lucide", .font_size = .{ .px = 15 } } });
    if (count > 0) {
        const number = try std.fmt.allocPrint(ctx.arena(), "{d}", .{count});
        const width: f32 = @max(16, @as(f32, @floatFromInt(number.len)) * 6 + 6);
        const badge = Rect{ .key = key.indexed(2), .style = &.{ .position = .absolute, .offset = .{ 32 - width * 0.65, -4 }, .width = .fixed(width), .height = .fixed(16), .justify = .center, .@"align" = .center, .radius = .{ .fixed = 4 }, .border_width = .all(1), .border_color = .elevated, .background = .accent, .foreground = .on_accent, .font_size = .{ .px = 10 } } };
        _ = try badge.open(ctx);
        try ctx.e(Text{ .key = key.indexed(3), .content = number, .selectable = false });
        try badge.close(ctx);
    }
    try b.close(ctx);
    try tooltip.close(ctx);
    return response.clicked;
}
/// A text button that shows a spinner beside its label while `operation` runs.
fn operationButton(self: *Self, ctx: *ui.Frame, key: []const u8, content: []const u8, enabled: bool, primary: bool, operation: model.Operation) !bool {
    if (self.active_operation != operation) return button(ctx, key, content, enabled, primary);
    const theme = ctx.ui().theme;
    try busyButton(ctx, .{ .key = .str(key), .disabled = true, .style = &.{ .padding = .xy(12, 8), .gap = 6, .font_size = .xs, .radius = .md, .background = if (primary) .accent else .muted, .foreground = if (primary) .on_accent else .text } }, content, if (primary) theme.on_primary else theme.text);
    return false;
}
fn busyButton(ctx: *ui.Frame, b: Button, content: []const u8, color: ui.Color) !void {
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = content, .state = .{ .disabled = true } });
    try spinner(ctx, b.key.indexed(20), 14, color);
    try ctx.e(Text{ .key = b.key.indexed(21), .content = try diff.safeText(ctx.arena(), content), .selectable = false });
    try b.close(ctx);
}
/// Lucide's loader-circle: a three-quarter ring with round caps, one turn per second.
/// KnotsUI cannot rotate glyphs, so the arc is drawn from overlapping dots.
fn spinner(ctx: *ui.Frame, key: ui.Key, size: f32, color: ui.Color) !void {
    const Canvas = ui.component.Canvas;
    const center = size / 2;
    const radius = size * 0.375;
    const turn = @as(f32, @floatFromInt(@mod(ctx.input().now_ms, 1000))) / 1000.0 * std.math.tau;
    var dots: [48]Canvas.DrawCmd = undefined;
    for (&dots, 0..) |*dot, i| {
        const angle = turn + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dots.len - 1)) * std.math.tau * 0.75;
        dot.* = .{ .fill_circle = .{ .cx = center + @cos(angle) * radius, .cy = center + @sin(angle) * radius, .radius = size / 24.0, .color = color.value } };
    }
    try ctx.e(Canvas{ .key = key, .commands = &dots, .style = &.{ .width = .fixed(size), .height = .fixed(size) } });
    ctx.requestRedraw();
}
fn buttonKey(ctx: *ui.Frame, key: ui.Key, content: []const u8, enabled: bool, primary: bool) !bool {
    return (try ctx.interact(Button{ .key = key, .label = try diff.safeText(ctx.arena(), content), .disabled = !enabled, .style = &.{ .padding = .xy(12, 8), .font_size = .xs, .radius = .md, .background = if (primary) .accent else .muted, .foreground = if (primary) .on_accent else .text } })).clicked;
}
fn nav(ctx: *ui.Frame, content: []const u8, active: bool, enabled: bool) !bool {
    return navKey(ctx, .str(content), content, active, enabled);
}
fn navKey(ctx: *ui.Frame, key: ui.Key, content: []const u8, active: bool, enabled: bool) !bool {
    const b = Button{ .key = key, .disabled = !enabled, .style = &.{ .width = .grow(), .height = .fixed(nav_height), .justify = .start, .padding = .xy(10, 5), .radius = .md, .font_size = .sm, .background = if (active) themes.selection(ctx.ui().theme) else .transparent, .foreground = if (active) .text else .dimmed } };
    const response = try b.openResponse(ctx);
    try ctx.ui().setAccessibility(response.id, .{ .role = .button, .name = content, .state = .{ .disabled = !enabled } });
    try truncatedLabel(ctx, key.indexed(10), content);
    try b.close(ctx);
    return response.clicked;
}
fn truncatedLabel(ctx: *ui.Frame, key: ui.Key, content: []const u8) !void {
    const measured = try ctx.ui().state.getOrCreate(.measured, ctx.ui().allocator, key.hash());
    const width = measured.width;
    // Clip the child inside a growing container, keeping counts outside it.
    const tooltip = ui.component.Tooltip{ .key = key, .content = content, .placement = .bottom, .style = &.{ .width = .grow(), .height = .fixed(22), .direction = .row, .@"align" = .center, .overflow = .hidden, .font_size = .sm }, .parts = .{ .popup = &.{ .width = .{ .kind = .fit, .max = 560 }, .wrap = true } } };
    _ = try tooltip.open(ctx);
    var visible: []const u8 = "";
    if (width > 0) {
        const resolved = ctx.ui().resolveStyle(key.indexed(3).hash(), .{ .base = &.{}, .user = &.{ .font_size = .sm } }, .{}, null);
        const face = try ctx.ui().font.getFace(resolved.content.font);
        const scale = ctx.ui().content_scale;
        const size = resolved.content.font_size * scale;
        const shaped = try face.shape(content, size);
        visible = content;
        if (shaped.width > width * scale) {
            const ellipsis = try face.shape("…", size);
            const limit = @max(0, width * scale - ellipsis.width);
            var end: usize = content.len;
            for (shaped.glyphs) |glyph| if (glyph.x + glyph.advance > limit) {
                end = glyph.cluster;
                break;
            };
            visible = if (width * scale >= ellipsis.width) try std.fmt.allocPrint(ctx.arena(), "{s}…", .{content[0..end]}) else "";
        }
    } else if (measured.height == 0) ctx.requestRedraw();
    try ctx.e(Text{ .key = key.indexed(3), .content = visible, .selectable = false, .style = &.{ .width = .grow(), .wrap = false } });
    if (ctx.ui().input.mouseButton(.right).pressed) if (ctx.ui().state.get(.tooltip, key.hash())) |state| {
        state.hover_dismissed = true;
        state.focus_dismissed = true;
    };
    try tooltip.close(ctx);
}
fn row(ctx: *ui.Frame, key: []const u8) !Rect {
    const rect = Rect{ .key = .str(key), .style = comptime &.{ .width = .grow(), .direction = .row, .gap = 8, .@"align" = .center } };
    _ = try rect.open(ctx);
    return rect;
}
fn pagePanel(ctx: *ui.Frame, key: []const u8) !Rect {
    const rect = Rect{ .key = .str(key), .style = comptime &.{ .width = .grow(), .height = .grow(), .direction = .column, .padding = .xy(28, 22), .gap = 14, .overflow = .scroll_y, .background = .elevated, .radius = .{ .fixed = 14 } } };
    _ = try rect.open(ctx);
    return rect;
}
fn heading(ctx: *ui.Frame, title: []const u8, subtitle: []const u8) !void {
    try ctx.e(Text{ .key = .str(title), .content = title, .style = &.{ .font_size = .lg } });
    try label(ctx, subtitle, subtitle, .dimmed);
}
fn space(ctx: *ui.Frame, key: []const u8, height: f32) !void {
    try ctx.e(ui.component.Spacer{ .key = .str(key), .style = &.{ .height = .fixed(height) } });
}
pub fn openPath(io: std.Io, a: std.mem.Allocator, path_value: []const u8) !void {
    const builtin = @import("builtin");
    const args: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "explorer.exe", path_value },
        .macos => &.{ "open", path_value },
        else => &.{ "xdg-open", path_value },
    };
    const r = try process.run(io, a, args, null, null);
    defer r.deinit(a);
}
