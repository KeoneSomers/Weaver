const std = @import("std");
const libgit2 = @import("build/libgit2.zig");
const nfd = @import("build/nfd.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const git2 = libgit2.module(b, target, optimize);
    const dialogs = nfd.module(b, target, optimize);
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Release version") orelse "0.1.0");
    options.addOption([]const u8, "oauth_client_id", b.option([]const u8, "oauth-client-id", "Public GitHub OAuth client ID") orelse "");
    options.addOption([]const u8, "update_public_key", b.option([]const u8, "update-public-key", "Ed25519 public key (hex)") orelse "");
    const picker_probe = b.addExecutable(.{ .name = "weaver-picker-probe", .root_module = b.createModule(.{ .root_source_file = b.path("src/picker_probe.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    picker_probe.root_module.addImport("nfd", dialogs);
    b.step("picker-probe", "Build the native picker verification tool").dependOn(&b.addInstallArtifact(picker_probe, .{}).step);
    const example = b.addExecutable(.{ .name = "weaver-repository-audit", .root_module = b.createModule(.{ .root_source_file = b.path("src/extension_example.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    b.step("extension-example", "Build an installable Zig command extension").dependOn(&b.addInstallArtifact(example, .{}).step);
    if (target.result.os.tag == .windows) {
        const installer = b.addExecutable(.{ .name = "weaver-setup", .root_module = b.createModule(.{
            .root_source_file = b.path("src/installer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        installer.root_module.addOptions("options", options);
        installer.root_module.addObjectFile(b.path("assets/weaver.res"));
        b.step("bootstrap", "Build the stable signed Windows bootstrap installer").dependOn(&b.addInstallArtifact(installer, .{}).step);
    }
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    tests.root_module.addOptions("options", options);
    tests.root_module.addImport("toolbar_icon_font", b.createModule(.{ .root_source_file = b.path("assets/lucide.ttf") }));
    tests.root_module.addImport("git2", git2);
    // credentials.zig stores the GitHub token in the macOS keychain.
    if (target.result.os.tag == .macos) tests.root_module.linkFramework("Security", .{});
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Test Git, diffs, security and persistence").dependOn(&run_tests.step);
    const headless = b.addExecutable(.{ .name = "weaver-check", .root_module = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    headless.root_module.addOptions("options", options);
    headless.root_module.addImport("git2", git2);
    if (target.result.os.tag == .macos) headless.root_module.linkFramework("Security", .{});
    b.step("check", "Build the headless Git inspector").dependOn(&b.addInstallArtifact(headless, .{}).step);
    if (b.option(bool, "headless", "Build only backend tests and tools") orelse false) return;
    const knots = b.lazyDependency("knots", .{ .target = target, .optimize = optimize }) orelse return;
    const ui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ui", .module = knots.module("ui") }},
    }) });
    b.step("test-ui", "Test hover and context-menu pointer routing").dependOn(&b.addRunArtifact(ui_tests).step);
    const exe = b.addExecutable(.{ .name = "weaver", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    exe.root_module.addImport("knots", knots.module("knots"));
    if (b.option(bool, "dwarf", "Use DWARF debug information on Windows") orelse false) exe.root_module.dwarf_format = .@"32";
    exe.root_module.addImport("ui", knots.module("ui"));
    exe.root_module.addOptions("options", options);
    exe.root_module.addImport("mono_font", b.createModule(.{ .root_source_file = b.path("assets/JetBrainsMono.ttf") }));
    exe.root_module.addImport("file_icon_font", b.createModule(.{ .root_source_file = b.path("assets/devicon.ttf") }));
    exe.root_module.addImport("toolbar_icon_font", b.createModule(.{ .root_source_file = b.path("assets/lucide.ttf") }));
    exe.root_module.addImport("brand_badge_svg", b.createModule(.{ .root_source_file = b.path("assets/weaver-badge.svg") }));
    exe.root_module.addImport("git2", git2);
    exe.root_module.addImport("nfd", dialogs);
    if (target.result.os.tag == .macos) exe.root_module.linkFramework("Security", .{});
    b.installArtifact(exe);
    b.installFile("assets/OFL.txt", "licenses/JetBrainsMono.txt");
    b.installFile("assets/Devicon-LICENSE.txt", "licenses/Devicon.txt");
    b.installFile("assets/Lucide-LICENSE.txt", "licenses/Lucide.txt");
    b.installFile("assets/Knots-LICENSE.txt", "licenses/KnotsUI.txt");
    b.getInstallStep().dependOn(&b.addInstallFile(libgit2.license(b), "licenses/libgit2.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(nfd.license(b), "licenses/NativeFileDialog.txt").step);
    b.installFile("THIRD_PARTY_NOTICES.md", "licenses/THIRD_PARTY_NOTICES.md");
    if (target.result.os.tag == .windows) {
        exe.root_module.addObjectFile(b.path("assets/weaver.res"));
        // A GUI subsystem binary opens no console window; main.zig reattaches
        // to the launching terminal so diagnostics still reach it.
        exe.subsystem = .windows;
    }
    const run = b.addRunArtifact(exe);
    if (target.result.os.tag == .linux) {
        b.installFile("packaging/linux/weaver.desktop", "share/applications/weaver.desktop");
        b.installDirectory(.{ .source_dir = b.path("assets/icons/hicolor"), .install_dir = .prefix, .install_subdir = "share/icons/hicolor" });
    }
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Weaver").dependOn(&run.step);
}
