--
-- sandbox: lexical policy (validator) and runtime traps
--
-- Everything in the first part must be rejected at CREATE time.
--

-- direct std import and any other import
CREATE FUNCTION s_std() RETURNS int LANGUAGE plzig AS $$
    const s = @import("std");
    _ = s;
    return 1;
$$;
CREATE FUNCTION s_builtin_mod() RETURNS int LANGUAGE plzig AS $$
    const b = @import("builtin");
    _ = b;
    return 1;
$$;
CREATE FUNCTION s_root() RETURNS int LANGUAGE plzig AS $$
    const r = @import("root");
    _ = r;
    return 1;
$$;
CREATE FUNCTION s_file() RETURNS int LANGUAGE plzig AS $$
    const r = @import("../sdk/plzig.zig");
    _ = r;
    return 1;
$$;
CREATE FUNCTION s_escaped() RETURNS int LANGUAGE plzig AS $$
    const r = @import("pl\x7aig");
    _ = r;
    return 1;
$$;
CREATE FUNCTION s_multiline() RETURNS int LANGUAGE plzig AS $$
    const r = @import(
        \\plzig
    );
    _ = r;
    return 1;
$$;

-- denied keywords
CREATE FUNCTION s_extern() RETURNS int LANGUAGE plzig AS $$
    return 1;
}
extern "c" fn system(cmd: [*:0]const u8) c_int;
fn unused() void {
$$;
CREATE FUNCTION s_export() RETURNS int LANGUAGE plzig AS $$
    return 1;
}
export fn plzig_evil() void {
$$;
CREATE FUNCTION s_asm() RETURNS int LANGUAGE plzig AS $$
    asm volatile ("unreachable");
    return 1;
$$;
CREATE FUNCTION s_callconv() RETURNS int LANGUAGE plzig AS $$
    return 1;
}
fn f() callconv(.c) void {
$$;
CREATE FUNCTION s_linksection() RETURNS int LANGUAGE plzig AS $$
    return 1;
}
var x: i32 linksection(".evil") = 0;
fn f() void {
$$;
CREATE FUNCTION s_threadlocal() RETURNS int LANGUAGE plzig AS $$
    return 1;
}
threadlocal var x: i32 = 0;
fn f() void {
$$;
CREATE FUNCTION s_addrspace() RETURNS int LANGUAGE plzig AS $$
    const p: *addrspace(.generic) i32 = undefined;
    _ = p;
    return 1;
$$;
CREATE FUNCTION s_volatile() RETURNS int LANGUAGE plzig AS $$
    var x: i32 = 0;
    const p: *volatile i32 = &x;
    return p.*;
$$;

-- denied builtins
CREATE FUNCTION s_embed() RETURNS text LANGUAGE plzig AS $$
    return @embedFile("/etc/passwd");
$$;
CREATE FUNCTION s_extern_builtin() RETURNS int LANGUAGE plzig AS $$
    const f = @extern(*const fn () callconv(.c) void, .{ .name = "system" });
    _ = f;
    return 1;
$$;
CREATE FUNCTION s_export_builtin() RETURNS int LANGUAGE plzig AS $$
    @export(&s_export_builtin, .{ .name = "x" });
    return 1;
$$;
CREATE FUNCTION s_ptrfromint() RETURNS int LANGUAGE plzig AS $$
    const p: *i32 = @ptrFromInt(0x1000);
    return p.*;
$$;
CREATE FUNCTION s_quota() RETURNS int LANGUAGE plzig AS $$
    @setEvalBranchQuota(1000000000);
    return 1;
$$;
CREATE FUNCTION s_memgrow() RETURNS int LANGUAGE plzig AS $$
    return @intCast(@wasmMemoryGrow(0, 1));
$$;
CREATE FUNCTION s_memsize() RETURNS int LANGUAGE plzig AS $$
    return @intCast(@wasmMemorySize(0));
$$;
CREATE FUNCTION s_safety() RETURNS int LANGUAGE plzig AS $$
    @setRuntimeSafety(false);
    return 1;
$$;
CREATE FUNCTION s_atomic() RETURNS int LANGUAGE plzig AS $$
    var x: i32 = 0;
    return @atomicRmw(i32, &x, .Add, 1, .seq_cst);
$$;
CREATE FUNCTION s_fieldparent() RETURNS int LANGUAGE plzig AS $$
    return @fieldParentPtr("x", undefined);
$$;
CREATE FUNCTION s_ptrcast() RETURNS int LANGUAGE plzig AS $$
    var x: u32 = 1;
    const p: *i32 = @ptrCast(&x);
    return p.*;
$$;
CREATE FUNCTION s_returnaddr() RETURNS bigint LANGUAGE plzig AS $$
    return @intCast(@returnAddress());
$$;
-- several problems are all reported
CREATE FUNCTION s_many() RETURNS int LANGUAGE plzig AS $$
    const a = @import("std");
    const b = @embedFile("x");
    asm volatile ("");
    return 1;
$$;
-- nothing was created
SELECT count(*) FROM pg_proc WHERE proname LIKE 's\_%' AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plzig');

-- a plain compile error is reported with body-relative line numbers
CREATE FUNCTION s_typo() RETURNS int LANGUAGE plzig AS $$
    const x: i32 = 1;
    return x + undefined_name;
$$;

-- curated std: OS-facing parts are simply not there
CREATE FUNCTION s_no_fs() RETURNS int LANGUAGE plzig AS $$
    _ = std.fs;
    return 1;
$$;

\set VERBOSITY terse
--
-- Runtime faults become ordinary errors, and the backend survives each one.
--
CREATE FUNCTION r_overflow(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    return x + 1;
$$;
SELECT r_overflow(2147483647);
SELECT 1 AS alive;

CREATE FUNCTION r_oob(i int) RETURNS int STRICT LANGUAGE plzig AS $$
    const arr = [_]i32{ 10, 20, 30 };
    const idx: usize = @intCast(i);
    return arr[idx];
$$;
SELECT r_oob(1);
SELECT r_oob(3);
SELECT r_oob(-1);
SELECT 1 AS alive;

CREATE FUNCTION r_unreachable() RETURNS int LANGUAGE plzig AS $$
    unreachable;
$$;
SELECT r_unreachable();

CREATE FUNCTION r_trap() RETURNS int LANGUAGE plzig AS $$
    @trap();
$$;
SELECT r_trap();

CREATE FUNCTION r_panic() RETURNS int LANGUAGE plzig AS $$
    @panic("custom panic message");
$$;
SELECT r_panic();

CREATE FUNCTION r_divzero(x int) RETURNS int STRICT LANGUAGE plzig AS $$
    return @divTrunc(100, x);
$$;
SELECT r_divzero(0);

CREATE FUNCTION r_null_unwrap(x int) RETURNS int LANGUAGE plzig AS $$
    return x.? + 1;
$$;
SELECT r_null_unwrap(NULL);

-- deep recursion hits the interpreter stack limit
CREATE FUNCTION r_deep(n int) RETURNS int STRICT LANGUAGE plzig AS $$
    return deep(n);
}
fn deep(n: i32) i32 {
    if (n == 0) return 0;
    return deep(n - 1) + 1;
$$;
SELECT r_deep(100);
SELECT r_deep(100000000);
SELECT 1 AS alive;

-- big stack frames overflow the guest's shadow stack in linear memory
CREATE FUNCTION r_bigstack(n int) RETURNS int STRICT LANGUAGE plzig AS $$
    return big(n);
}
fn big(n: i32) i32 {
    var buf: [4096]u8 = undefined;
    buf[@intCast(@mod(n, 4096))] = @truncate(@as(u32, @bitCast(n)));
    if (n == 0) return buf[0];
    return big(n - 1) + buf[@intCast(@mod(n, 4096))] - buf[@intCast(@mod(n, 4096))];
$$;
SELECT r_bigstack(10);
SELECT r_bigstack(100000);
SELECT 1 AS alive;

-- an instance that trapped is discarded: globals start over
CREATE FUNCTION r_state(fail boolean) RETURNS int STRICT LANGUAGE plzig AS $$
    count += 1;
    if (fail) @panic("boom");
    return count;
}
var count: i32 = 0;
fn unused() void {
$$;
SELECT r_state(false), r_state(false);
SELECT r_state(true);
SELECT r_state(false);
