//! Native File Dialog Extended, compiled from the pinned source in build.zig.zon.
//! Linux uses the xdg-desktop-portal backend with Wayland parent windows.
const std = @import("std");

/// Returns the `nfd` module: translated `nfd.h` bindings linked against a
/// static nfd.
pub fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const src = b.dependency("nfd", .{});
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .sanitize_c = .off });
    mod.addIncludePath(src.path("src/include"));
    switch (target.result.os.tag) {
        .windows => {
            mod.addCSourceFile(.{ .file = src.path("src/nfd_win.cpp"), .flags = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti", "-DNFD_OVERRIDE_RECENT_WITH_DEFAULT" } });
            for ([_][]const u8{ "ole32", "shell32", "uuid" }) |name| mod.linkSystemLibrary(name, .{});
        },
        .macos => {
            mod.addCSourceFile(.{ .file = src.path("src/nfd_cocoa.m"), .flags = &.{"-DNFD_MACOS_ALLOWEDCONTENTTYPES=1"} });
            mod.linkFramework("AppKit", .{});
            mod.linkFramework("UniformTypeIdentifiers", .{});
            mod.linkSystemLibrary("objc", .{});
        },
        else => {
            mod.addCSourceFile(.{ .file = src.path("src/nfd_portal.cpp"), .flags = &.{ "-std=c++11", "-fno-exceptions", "-fno-rtti", "-DNFD_PORTAL", "-DNFD_WAYLAND" } });
            const protocols = b.lazyDependency("wayland_protocols", .{}) orelse return mod;
            const xml = protocols.path("unstable/xdg-foreign/xdg-foreign-unstable-v1.xml");
            const header = scan(b, "client-header", xml, "xdg-foreign-unstable-v1.h");
            mod.addIncludePath(header.dirname());
            mod.addCSourceFile(.{ .file = scan(b, "private-code", xml, "xdg-foreign-unstable-v1.c"), .flags = &.{} });
            mod.linkSystemLibrary("dbus-1", .{});
            mod.linkSystemLibrary("wayland-client", .{});
        },
    }
    const lib = b.addLibrary(.{ .name = "nfd", .linkage = .static, .root_module = mod });

    const header = b.addTranslateC(.{ .root_source_file = src.path("src/include/nfd.h"), .target = target, .optimize = optimize });
    const nfd = header.createModule();
    nfd.linkLibrary(lib);
    return nfd;
}

/// The license nfd is distributed under, for the installed notices.
pub fn license(b: *std.Build) std.Build.LazyPath {
    return b.dependency("nfd", .{}).path("LICENSE");
}

fn scan(b: *std.Build, mode: []const u8, xml: std.Build.LazyPath, name: []const u8) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "wayland-scanner", mode });
    run.addFileArg(xml);
    return run.addOutputFileArg(name);
}
