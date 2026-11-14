//! `zig build` front end for the PL/Zig extension build.
//!
//! This file contains no build logic.  The build is the PGXS Makefile (the
//! standard way to build PostgreSQL extensions, and what packagers expect);
//! every step below runs one `make` target, passing this very compiler as
//! ZIG= so that the validator is built with the compiler that runs the build.
//!
//!   zig build                       make all
//!   zig build pg-install            make install      (-Ddestdir=...)
//!   zig build pg-uninstall          make uninstall
//!   zig build test                  make check-zig    (validator + SDK unit tests)
//!   zig build installcheck          make installcheck (needs a running server)
//!   zig build installcheck-isolation
//!   zig build installcheck-testing  (against a -Dtesting=true build)
//!   zig build clean
//!
//! Options: -Dpg-config=PATH  -Dwamr-src=DIR  -Dwerror=true  -Dtesting=true
//!          -Ddestdir=DIR  -Dmake=PROGRAM  -Djobs=N
//!
//! The steps are named pg-install/pg-uninstall because `zig build install`
//! and `uninstall` are Zig's own steps for its install prefix, which this
//! project does not use: files go where pg_config says.

const std = @import("std");
const builtin = @import("builtin");

/// Must equal ZIG_VERSION in the Makefile (which checks the compiler again).
const required_zig = std.SemanticVersion{ .major = 0, .minor = 17, .patch = 1 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq)
        @compileError("PL/Zig must be built with Zig 0.17.1 exactly, this is Zig " ++ builtin.zig_version_string);
}

pub fn build(b: *std.Build) void {
    const pg_config = b.option([]const u8, "pg-config", "pg_config of the target PostgreSQL (default: from PATH)");
    const wamr_src = b.option([]const u8, "wamr-src", "WAMR source tree at the pinned commit (default: fetched by the Makefile)");
    const werror = b.option(bool, "werror", "Treat C compiler warnings as errors") orelse false;
    const testing = b.option(bool, "testing", "Test build with the plzig_test_* helpers; never for a release") orelse false;
    const destdir = b.option([]const u8, "destdir", "Staging directory for pg-install (DESTDIR)");
    const make = b.option([]const u8, "make", "The GNU make program (default: make)") orelse "make";
    const jobs = b.option(u32, "jobs", "Parallel make jobs (default: 1)");

    var common: std.ArrayList([]const u8) = .empty;
    const a = b.allocator;
    common.append(a, make) catch @panic("OOM");
    common.append(a, b.fmt("ZIG={s}", .{b.graph.zig_exe})) catch @panic("OOM");
    if (pg_config) |v| common.append(a, b.fmt("PG_CONFIG={s}", .{v})) catch @panic("OOM");
    if (wamr_src) |v| common.append(a, b.fmt("WAMR_SRC={s}", .{v})) catch @panic("OOM");
    if (werror) common.append(a, "WERROR=1") catch @panic("OOM");
    if (testing) common.append(a, "PLZIG_TESTING=1") catch @panic("OOM");
    if (destdir) |v| common.append(a, b.fmt("DESTDIR={s}", .{v})) catch @panic("OOM");

    const all = makeStep(b, common.items, "all", "Build plzig.so and plzig-validate (make all)", "all", jobs);
    b.default_step = all;

    const install = makeStep(b, common.items, "pg-install", "Install into the PostgreSQL given by pg_config (make install)", "install", null);
    install.dependOn(all);
    _ = makeStep(b, common.items, "pg-uninstall", "Remove the installed files (make uninstall)", "uninstall", null);
    _ = makeStep(b, common.items, "test", "Unit tests of the validator and the SDK (make check-zig)", "check-zig", null);
    _ = makeStep(b, common.items, "installcheck", "Regression tests against a running server (make installcheck)", "installcheck", null);
    _ = makeStep(b, common.items, "installcheck-isolation", "Isolation tests against a running server", "installcheck-isolation", null);
    _ = makeStep(b, common.items, "installcheck-testing", "C unit checks against an installed -Dtesting=true build", "installcheck-testing", null);
    _ = makeStep(b, common.items, "clean", "Remove test output (make clean)", "clean", null);
}

fn makeStep(
    b: *std.Build,
    common: []const []const u8,
    name: []const u8,
    description: []const u8,
    target: []const u8,
    jobs: ?u32,
) *std.Build.Step {
    const run = b.addSystemCommand(common);
    if (jobs) |n| run.addArg(b.fmt("-j{d}", .{n}));
    run.addArg(target);
    run.setCwd(b.path("."));
    // make decides what is out of date; always run it, with its output shown
    run.stdio = .inherit;
    const step = b.step(name, description);
    step.dependOn(&run.step);
    return step;
}
