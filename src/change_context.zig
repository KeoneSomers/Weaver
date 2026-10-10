const ui = @import("ui");
const model = @import("model.zig");

// Scan generations and row indices change during refreshes; target identity does not.
pub fn key(repository: []const u8, file: model.File) ui.Key {
    return ui.Key.str("change-context").indexed(ui.Key.str(repository).hash()).indexed(ui.Key.str(file.path).hash()).indexed(@intFromBool(file.staged));
}

pub fn reconcile(state: *ui.State, active: *?ui.Key, previous_repository: []const u8, previous: []const model.File, repository: []const u8, files: []const model.File) void {
    const current = active.* orelse return;
    // Project menus are independent of the change list.
    for (previous) |file| {
        if (key(previous_repository, file).hash() != current.hash()) continue;
        for (files) |next| if (key(repository, next).hash() == current.hash()) return;
        if (state.get(.context_menu, current.hash())) |menu| menu.open = false;
        active.* = null;
        return;
    }
}
