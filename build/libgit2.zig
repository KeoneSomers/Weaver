//! libgit2, compiled from the pinned source in build.zig.zon.
//!
//! Weaver reads repository metadata through libgit2 and runs every network
//! operation through the Git executable, so the network transports' optional
//! TLS, SSH and NTLM backends are left out. All other dependencies (zlib,
//! PCRE2, llhttp, xdiff, SHA-1DC) are the copies bundled with libgit2.
const std = @import("std");

/// Returns the `git2` module: translated `git2.h` bindings linked against a
/// static libgit2.
pub fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const src = b.dependency("libgit2", .{});
    const os = target.result.os.tag;

    const features = b.addConfigHeader(.{ .style = .{ .cmake = src.path("src/util/git2_features.h.in") }, .include_path = "git2_features.h" }, .{
        .GIT_THREADS = 1,
        .GIT_USE_NSEC = 1,
        .GIT_ARCH_64 = @as(?u1, if (target.result.ptrBitWidth() == 64) 1 else null),
        .GIT_ARCH_32 = @as(?u1, if (target.result.ptrBitWidth() == 32) 1 else null),
        .GIT_REGEX_BUILTIN = 1,
        .GIT_HTTPPARSER_BUILTIN = 1,
        .GIT_SHA1_COLLISIONDETECT = 1,
        .GIT_SHA256_BUILTIN = 1,
        .GIT_COMPRESSION_BUILTIN = 1,
    });
    switch (os) {
        .windows => features.addValues(.{ .GIT_QSORT_MSC = 1, .GIT_IO_WSAPOLL = 1 }),
        .macos => features.addValues(.{
            .GIT_USE_ICONV = 1,
            .GIT_USE_STAT_MTIMESPEC = 1,
            .GIT_USE_FUTIMENS = 1,
            .GIT_QSORT_BSD = 1,
            // No GIT_RAND_GETENTROPY: macOS declares getentropy only in <sys/random.h>,
            // which libgit2 does not include, so upstream leaves it off here too.
            .GIT_RAND_GETLOADAVG = 1,
            .GIT_IO_POLL = 1,
            .GIT_IO_SELECT = 1,
        }),
        else => features.addValues(.{
            .GIT_USE_STAT_MTIM = 1,
            .GIT_USE_FUTIMENS = 1,
            .GIT_QSORT_GNU = 1,
            .GIT_RAND_GETENTROPY = 1,
            .GIT_RAND_GETLOADAVG = 1,
            .GIT_IO_POLL = 1,
            .GIT_IO_SELECT = 1,
        }),
    }

    const pcre_config = b.addConfigHeader(.{ .style = .{ .cmake = src.path("deps/pcre2/config.h.in") }, .include_path = "config.h" }, .{
        .HAVE_ASSERT_H = 1,
        .HAVE_BUILTIN_MUL_OVERFLOW = 1,
        .HAVE_BUILTIN_UNREACHABLE = 1,
        .HAVE_ATTRIBUTE_UNINITIALIZED = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_DIRENT_H = @as(?u1, if (os == .windows) null else 1),
        .HAVE_UNISTD_H = @as(?u1, if (os == .windows) null else 1),
        .HAVE_WINDOWS_H = @as(?u1, if (os == .windows) 1 else null),
        .SUPPORT_PCRE2_8 = 1,
        .SUPPORT_UNICODE = 1,
        .PCRE2_LINK_SIZE = 2,
        .PCRE2_HEAP_LIMIT = 20000000,
        .PCRE2_MATCH_LIMIT = 10000000,
        .PCRE2_MATCH_LIMIT_DEPTH = .MATCH_LIMIT,
        .PCRE2_MAX_VARLOOKBEHIND = 255,
        .NEWLINE_DEFAULT = 2,
        .PCRE2_PARENS_NEST_LIMIT = 250,
        .PCRE2GREP_BUFSIZE = 20480,
        .PCRE2GREP_MAX_BUFSIZE = 1048576,
    });

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .sanitize_c = .off });
    mod.addConfigHeader(features);
    mod.addConfigHeader(pcre_config);
    for ([_][]const u8{ "include", "src/libgit2", "src/util", "deps/llhttp", "deps/xdiff", "deps/zlib", "deps/pcre2" }) |dir|
        mod.addIncludePath(src.path(dir));

    // libgit2 links the bundled PCRE2 statically; its headers must agree.
    const pcre2_static = [_][]const u8{ "-DPCRE2_STATIC", "-DPCRE2_EXPORT=", "-DPCRE2_EXP_DECL=", "-DPCRE2_EXP_DEFN=" };
    const git_flags: []const []const u8 = switch (os) {
        .windows => &(pcre2_static ++ .{ "-DWIN32", "-D_WIN32_WINNT=0x0600", "-D__USE_MINGW_ANSI_STDIO=1" }),
        else => &(pcre2_static ++ .{"-D_GNU_SOURCE"}),
    };

    mod.addCSourceFiles(.{ .root = src.path("."), .files = &libgit2_sources, .flags = git_flags });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &util_sources, .flags = git_flags });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = if (os == .windows) &util_win32_sources else &util_unix_sources, .flags = git_flags });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &.{ "src/util/hash/builtin.c", "src/util/hash/rfc6234/sha224-256.c" }, .flags = git_flags });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &.{ "src/util/hash/collisiondetect.c", "src/util/hash/sha1dc/sha1.c", "src/util/hash/sha1dc/ubc_check.c" }, .flags = concat(b, git_flags, &.{
        "-DSHA1DC_NO_STANDARD_INCLUDES=1",
        "-DSHA1DC_CUSTOM_INCLUDE_SHA1_C=\"git2_util.h\"",
        "-DSHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C=\"git2_util.h\"",
    }) });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &xdiff_sources, .flags = git_flags });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &llhttp_sources, .flags = &.{} });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &zlib_sources, .flags = concat(b, &.{ "-DNO_VIZ", "-DSTDC", "-DNO_GZIP", "-DHAVE_SYS_TYPES_H", "-DHAVE_STDINT_H", "-DHAVE_STDDEF_H" }, switch (os) {
        .windows => &.{},
        // off64_t and the 64-bit file API variants exist only on Linux.
        .linux => &.{ "-DZ_HAVE_UNISTD_H", "-D_LFS64_LARGEFILE", "-D_LARGEFILE64_SOURCE=1" },
        else => &.{"-DZ_HAVE_UNISTD_H"},
    }) });
    mod.addCSourceFiles(.{ .root = src.path("."), .files = &pcre2_sources, .flags = &(pcre2_static ++ .{ "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8" }) });

    switch (os) {
        .windows => for ([_][]const u8{ "ws2_32", "secur32", "advapi32", "ole32", "rpcrt4" }) |name| mod.linkSystemLibrary(name, .{}),
        .macos => {
            mod.linkSystemLibrary("iconv", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }

    const lib = b.addLibrary(.{ .name = "git2", .linkage = .static, .root_module = mod });

    const header = b.addTranslateC(.{ .root_source_file = src.path("include/git2.h"), .target = target, .optimize = optimize });
    header.addIncludePath(src.path("include"));
    const git2 = header.createModule();
    git2.linkLibrary(lib);
    return git2;
}

fn concat(b: *std.Build, base: []const []const u8, extra: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ base, extra }) catch @panic("OOM");
}

/// The license libgit2 is distributed under, for the installed notices.
pub fn license(b: *std.Build) std.Build.LazyPath {
    return b.dependency("libgit2", .{}).path("COPYING");
}

const libgit2_sources = [_][]const u8{
    "src/libgit2/annotated_commit.c",          "src/libgit2/apply.c",                         "src/libgit2/attr.c",
    "src/libgit2/attrcache.c",                 "src/libgit2/attr_file.c",                     "src/libgit2/blame.c",
    "src/libgit2/blame_git.c",                 "src/libgit2/blob.c",                          "src/libgit2/branch.c",
    "src/libgit2/buf.c",                       "src/libgit2/cache.c",                         "src/libgit2/checkout.c",
    "src/libgit2/cherrypick.c",                "src/libgit2/clone.c",                         "src/libgit2/commit.c",
    "src/libgit2/commit_graph.c",              "src/libgit2/commit_list.c",                   "src/libgit2/config.c",
    "src/libgit2/config_cache.c",              "src/libgit2/config_file.c",                   "src/libgit2/config_list.c",
    "src/libgit2/config_mem.c",                "src/libgit2/config_parse.c",                  "src/libgit2/config_snapshot.c",
    "src/libgit2/crlf.c",                      "src/libgit2/delta.c",                         "src/libgit2/describe.c",
    "src/libgit2/diff.c",                      "src/libgit2/diff_driver.c",                   "src/libgit2/diff_file.c",
    "src/libgit2/diff_generate.c",             "src/libgit2/diff_parse.c",                    "src/libgit2/diff_print.c",
    "src/libgit2/diff_stats.c",                "src/libgit2/diff_tform.c",                    "src/libgit2/diff_xdiff.c",
    "src/libgit2/email.c",                     "src/libgit2/fetch.c",                         "src/libgit2/fetchhead.c",
    "src/libgit2/filter.c",                    "src/libgit2/grafts.c",                        "src/libgit2/graph.c",
    "src/libgit2/hashsig.c",                   "src/libgit2/ident.c",                         "src/libgit2/ignore.c",
    "src/libgit2/index.c",                     "src/libgit2/indexer.c",                       "src/libgit2/index_map.c",
    "src/libgit2/iterator.c",                  "src/libgit2/libgit2.c",                       "src/libgit2/mailmap.c",
    "src/libgit2/merge.c",                     "src/libgit2/merge_driver.c",                  "src/libgit2/merge_file.c",
    "src/libgit2/message.c",                   "src/libgit2/midx.c",                          "src/libgit2/mwindow.c",
    "src/libgit2/notes.c",                     "src/libgit2/object_api.c",                    "src/libgit2/object.c",
    "src/libgit2/odb.c",                       "src/libgit2/odb_loose.c",                     "src/libgit2/odb_mempack.c",
    "src/libgit2/odb_pack.c",                  "src/libgit2/oidarray.c",                      "src/libgit2/oid.c",
    "src/libgit2/pack.c",                      "src/libgit2/pack-objects.c",                  "src/libgit2/parse.c",
    "src/libgit2/patch.c",                     "src/libgit2/patch_generate.c",                "src/libgit2/patch_parse.c",
    "src/libgit2/path.c",                      "src/libgit2/pathspec.c",                      "src/libgit2/proxy.c",
    "src/libgit2/push.c",                      "src/libgit2/reader.c",                        "src/libgit2/rebase.c",
    "src/libgit2/refdb.c",                     "src/libgit2/refdb_fs.c",                      "src/libgit2/reflog.c",
    "src/libgit2/refs.c",                      "src/libgit2/refspec.c",                       "src/libgit2/remote.c",
    "src/libgit2/repository.c",                "src/libgit2/reset.c",                         "src/libgit2/revert.c",
    "src/libgit2/revparse.c",                  "src/libgit2/revwalk.c",                       "src/libgit2/settings.c",
    "src/libgit2/signature.c",                 "src/libgit2/stash.c",                         "src/libgit2/status.c",
    "src/libgit2/strarray.c",                  "src/libgit2/submodule.c",                     "src/libgit2/sysdir.c",
    "src/libgit2/tag.c",                       "src/libgit2/trace.c",                         "src/libgit2/trailer.c",
    "src/libgit2/transaction.c",               "src/libgit2/transport.c",                     "src/libgit2/tree.c",
    "src/libgit2/tree-cache.c",                "src/libgit2/worktree.c",                      "src/libgit2/streams/mbedtls.c",
    "src/libgit2/streams/openssl.c",           "src/libgit2/streams/openssl_dynamic.c",       "src/libgit2/streams/openssl_legacy.c",
    "src/libgit2/streams/registry.c",          "src/libgit2/streams/schannel.c",              "src/libgit2/streams/socket.c",
    "src/libgit2/streams/stransport.c",        "src/libgit2/streams/tls.c",                   "src/libgit2/transports/auth.c",
    "src/libgit2/transports/auth_gssapi.c",    "src/libgit2/transports/auth_ntlmclient.c",    "src/libgit2/transports/auth_sspi.c",
    "src/libgit2/transports/credential.c",     "src/libgit2/transports/credential_helpers.c", "src/libgit2/transports/git.c",
    "src/libgit2/transports/http.c",           "src/libgit2/transports/httpclient.c",         "src/libgit2/transports/httpparser.c",
    "src/libgit2/transports/local.c",          "src/libgit2/transports/smart.c",              "src/libgit2/transports/smart_pkt.c",
    "src/libgit2/transports/smart_protocol.c", "src/libgit2/transports/ssh.c",                "src/libgit2/transports/ssh_exec.c",
    "src/libgit2/transports/ssh_libssh2.c",    "src/libgit2/transports/winhttp.c",
};

const util_sources = [_][]const u8{
    "src/util/allocators/debugalloc.c",      "src/util/allocators/failalloc.c", "src/util/allocators/stdalloc.c",
    "src/util/allocators/win32_leakcheck.c", "src/util/alloc.c",                "src/util/date.c",
    "src/util/errors.c",                     "src/util/filebuf.c",              "src/util/fs_path.c",
    "src/util/futils.c",                     "src/util/hash.c",                 "src/util/net.c",
    "src/util/pool.c",                       "src/util/posix.c",                "src/util/pqueue.c",
    "src/util/rand.c",                       "src/util/regexp.c",               "src/util/runtime.c",
    "src/util/sortedcache.c",                "src/util/str.c",                  "src/util/strlist.c",
    "src/util/thread.c",                     "src/util/tsort.c",                "src/util/utf8.c",
    "src/util/util.c",                       "src/util/varint.c",               "src/util/vector.c",
    "src/util/wildmatch.c",                  "src/util/zstream.c",
};

const util_unix_sources = [_][]const u8{ "src/util/unix/map.c", "src/util/unix/process.c", "src/util/unix/realpath.c" };

const util_win32_sources = [_][]const u8{
    "src/util/win32/dir.c",        "src/util/win32/error.c",         "src/util/win32/map.c",
    "src/util/win32/path_w32.c",   "src/util/win32/posix_w32.c",     "src/util/win32/precompiled.c",
    "src/util/win32/process.c",    "src/util/win32/thread.c",        "src/util/win32/utf-conv.c",
    "src/util/win32/w32_buffer.c", "src/util/win32/w32_leakcheck.c", "src/util/win32/w32_util.c",
};

const llhttp_sources = [_][]const u8{ "deps/llhttp/api.c", "deps/llhttp/http.c", "deps/llhttp/llhttp.c" };

const xdiff_sources = [_][]const u8{
    "deps/xdiff/xdiffi.c",    "deps/xdiff/xemit.c",    "deps/xdiff/xhistogram.c", "deps/xdiff/xmerge.c",
    "deps/xdiff/xpatience.c", "deps/xdiff/xprepare.c", "deps/xdiff/xutils.c",
};

const zlib_sources = [_][]const u8{
    "deps/zlib/adler32.c", "deps/zlib/crc32.c",    "deps/zlib/deflate.c", "deps/zlib/infback.c", "deps/zlib/inffast.c",
    "deps/zlib/inflate.c", "deps/zlib/inftrees.c", "deps/zlib/trees.c",   "deps/zlib/zutil.c",
};

const pcre2_sources = [_][]const u8{
    "deps/pcre2/pcre2_auto_possess.c", "deps/pcre2/pcre2_chartables.c",     "deps/pcre2/pcre2_chkdint.c",
    "deps/pcre2/pcre2_compile.c",      "deps/pcre2/pcre2_compile_cgroup.c", "deps/pcre2/pcre2_compile_class.c",
    "deps/pcre2/pcre2_config.c",       "deps/pcre2/pcre2_context.c",        "deps/pcre2/pcre2_convert.c",
    "deps/pcre2/pcre2_dfa_match.c",    "deps/pcre2/pcre2_error.c",          "deps/pcre2/pcre2_extuni.c",
    "deps/pcre2/pcre2_find_bracket.c", "deps/pcre2/pcre2_maketables.c",     "deps/pcre2/pcre2_match.c",
    "deps/pcre2/pcre2_match_data.c",   "deps/pcre2/pcre2_match_next.c",     "deps/pcre2/pcre2_newline.c",
    "deps/pcre2/pcre2_ord2utf.c",      "deps/pcre2/pcre2_pattern_info.c",   "deps/pcre2/pcre2_script_run.c",
    "deps/pcre2/pcre2_serialize.c",    "deps/pcre2/pcre2_string_utils.c",   "deps/pcre2/pcre2_study.c",
    "deps/pcre2/pcre2_substitute.c",   "deps/pcre2/pcre2_substring.c",      "deps/pcre2/pcre2_tables.c",
    "deps/pcre2/pcre2_ucd.c",          "deps/pcre2/pcre2_valid_utf.c",      "deps/pcre2/pcre2_xclass.c",
};
