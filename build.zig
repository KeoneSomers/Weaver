const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const prefix = b.option([]const u8, "git2-prefix", "libgit2 install prefix") orelse ".tools/git2";
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Release version") orelse "0.1.0");
    options.addOption([]const u8, "oauth_client_id", b.option([]const u8, "oauth-client-id", "Public GitHub OAuth client ID") orelse "");
    options.addOption([]const u8, "release_repo", b.option([]const u8, "release-repo", "GitHub owner/repo") orelse "");
    options.addOption([]const u8, "update_public_key", b.option([]const u8, "update-public-key", "Ed25519 public key (hex)") orelse "");
    const picker_probe = b.addExecutable(.{ .name = "weaver-picker-probe", .root_module = b.createModule(.{ .root_source_file = b.path("src/picker_probe.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    linkDialogs(b, picker_probe.root_module, target.result.os.tag);
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
    linkGit(b, tests.root_module, prefix, target.result.os.tag);
    const run_tests = b.addRunArtifact(tests);
    const search_key = switch (target.result.os.tag) {
        .windows => "PATH",
        .macos => "DYLD_LIBRARY_PATH",
        else => "LD_LIBRARY_PATH",
    };
    const search_dir = b.root.joinString(b.allocator, b.fmt("{s}/{s}", .{ prefix, if (target.result.os.tag == .windows) "bin" else "lib" })) catch @panic("OOM");
    run_tests.setEnvironmentVariable(search_key, b.fmt("{s}{s}{s}", .{ search_dir, if (target.result.os.tag == .windows) ";" else ":", b.graph.environ_map.get(search_key) orelse "" }));
    b.step("test", "Test Git, diffs, security and persistence").dependOn(&run_tests.step);
    const headless = b.addExecutable(.{ .name = "weaver-check", .root_module = b.createModule(.{
        .root_source_file = b.path("src/check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    headless.root_module.addOptions("options", options);
    linkGit(b, headless.root_module, prefix, target.result.os.tag);
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
    linkGit(b, exe.root_module, prefix, target.result.os.tag);
    linkDialogs(b, exe.root_module, target.result.os.tag);
    b.installArtifact(exe);
    b.installFile("assets/OFL.txt", "licenses/JetBrainsMono.txt");
    b.installFile("assets/Devicon-LICENSE.txt", "licenses/Devicon.txt");
    b.installFile("assets/Lucide-LICENSE.txt", "licenses/Lucide.txt");
    b.installFile("assets/Knots-LICENSE.txt", "licenses/KnotsUI.txt");
    b.installFile("assets/libgit2-COPYING.txt", "licenses/libgit2.txt");
    b.installFile("assets/NFD-LICENSE.txt", "licenses/NativeFileDialog.txt");
    b.installFile("THIRD_PARTY_NOTICES.md", "licenses/THIRD_PARTY_NOTICES.md");
    if (target.result.os.tag == .windows) {
        exe.root_module.addObjectFile(b.path("assets/weaver.res"));
        b.installFile(b.fmt("{s}/bin/libgit2.dll", .{prefix}), "bin/libgit2.dll");
    }
    const run = b.addRunArtifact(exe);
    if (target.result.os.tag == .linux) {
        b.installFile("packaging/linux/weaver.desktop", "share/applications/weaver.desktop");
        b.installDirectory(.{ .source_dir = b.path("assets/icons/hicolor"), .install_dir = .prefix, .install_subdir = "share/icons/hicolor" });
    }
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Weaver").dependOn(&run.step);
}

fn linkDialogs(b: *std.Build, module: *std.Build.Module, os: std.Target.Os.Tag) void {
    const header = b.addTranslateC(.{ .root_source_file = b.path("vendor/nfd/src/include/nfd.h"), .target = module.resolved_target.?, .optimize = module.optimize.? });
    module.addImport("nfd", header.createModule());
    module.addIncludePath(b.path("vendor/nfd/src/include"));
    switch (os) {
        .windows => {
            module.addCSourceFile(.{ .file = b.path("vendor/nfd/src/nfd_win.cpp"), .flags = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti", "-DNFD_OVERRIDE_RECENT_WITH_DEFAULT", "-fno-sanitize=undefined" } });
            module.linkSystemLibrary("ole32", .{});
            module.linkSystemLibrary("shell32", .{});
            module.linkSystemLibrary("uuid", .{});
        },
        .macos => {
            module.addCSourceFile(.{ .file = b.path("vendor/nfd/src/nfd_cocoa.m"), .flags = &.{"-DNFD_MACOS_ALLOWEDCONTENTTYPES=1"} });
            module.linkFramework("AppKit", .{});
            module.linkFramework("UniformTypeIdentifiers", .{});
            module.linkSystemLibrary("objc", .{});
        },
        .linux => {
            module.addLibraryPath(b.path(".tools/nfd/lib"));
            module.linkSystemLibrary("nfd", .{});
            module.linkSystemLibrary("dbus-1", .{});
            module.linkSystemLibrary("wayland-client", .{});
        },
        else => {},
    }
}

fn linkGit(b: *std.Build, module: *std.Build.Module, prefix: []const u8, os: std.Target.Os.Tag) void {
    module.addLibraryPath(b.path(b.fmt("{s}/lib", .{prefix})));
    if (os != .windows) module.addRPath(b.path(b.fmt("{s}/lib", .{prefix})));
    module.linkSystemLibrary("git2", .{});
    if (os == .windows) module.linkSystemLibrary("advapi32", .{});
    if (os == .macos) module.linkFramework("Security", .{});
}
