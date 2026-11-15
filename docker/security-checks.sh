#!/bin/bash
# Shell-driven security checks that cannot be expressed in pg_regress
# (they need plzig.zig_path & co., which are settable only in postgresql.conf).
# Runs inside the test container against the running cluster in $PGDATA.
# $PLZIG_TEST_ZIG is the real Zig compiler the cluster is configured with.
set -u
fails=0
pass() { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; fails=$((fails + 1)); }

psqlq() { psql -X -q -At -v VERBOSITY=default "$@" 2>&1; }

reload() {
    pg_ctl -D "$PGDATA" reload >/dev/null
    sleep 0.5
}

set_conf() {   # set_conf <name> <value or empty to remove>; no reload
    sed -i "/^plzig.$1 /d" "$PGDATA/postgresql.conf"
    [ -n "$2" ] && echo "plzig.$1 = '$2'" >> "$PGDATA/postgresql.conf"
    return 0
}

set_zig_path() {
    set_conf zig_path "$1"
    reload
}

# compiler + lib dir for the fake compilers
set_fake() {
    set_conf zig_path "$1"
    set_conf zig_lib_dir "$fakedir/lib"
    reload
}

# back to the real compiler, lib dir auto-detected, no checksum pin
set_real() {
    set_conf zig_path "$PLZIG_TEST_ZIG"
    set_conf zig_lib_dir ""
    set_conf zig_sha256 ""
    reload
}

expect() {   # expect <description> <needle> <sql>
    local out
    out=$(psqlq -c "$3")
    if grep -qF -- "$2" <<<"$out"; then pass "$1"; else fail "$1"; echo "$out" | sed 's/^/         /'; fi
}

compile_sql() {   # a function body that is certainly not cached yet
    echo "CREATE OR REPLACE FUNCTION tc_probe() RETURNS int LANGUAGE plzig AS \$\$ return $((RANDOM * 10000 + RANDOM % 10000)); \$\$;"
}

echo "--- security checks"
fakedir=/tmp/plzig-fake
mkdir -p "$fakedir"
canary=/tmp/plzig-canary
for m in 1 2 3 4 5 7 8 9 10; do
    mkdir -p "$fakedir/m$m"
    gcc -O2 -static -DMODE=$m -DPGDATA="\"$PGDATA\"" -DPGSOCK="\"$PGHOST/.s.PGSQL.5432\"" \
        -DCANARY_DIR="\"$canary\"" -o "$fakedir/m$m/zig" /src/docker/fake/fakezig.c || exit 1
done
# m6: a compiler reporting another version
mkdir -p "$fakedir/m6"
gcc -O2 -static -DMODE=1 -DFAKE_VERSION='"0.16.0"' -DPGDATA="\"$PGDATA\"" -o "$fakedir/m6/zig" /src/docker/fake/fakezig.c || exit 1
mkdir -p "$fakedir/lib/std"
echo "// fake" > "$fakedir/lib/std/std.zig"

# 1-4: the loader's import allowlist (defence in depth behind the validator)
n=0
for case in "1|import from a module other than \"plzig\"" \
            "2|unknown host function" \
            "3|host function signature mismatch" \
            "4|non-function import"; do
    m=${case%%|*}; needle=${case#*|}; n=$((n + 1))
    set_fake "$fakedir/m$m/zig"
    expect "forbidden import rejected ($needle)" "$needle" \
        "CREATE FUNCTION imp_$m() RETURNS int LANGUAGE plzig AS \$\$ return $m$RANDOM; \$\$;"
done

# 8, 9: declarations that would cost WAMR about 1 GB (and seconds of
# uninterruptible CPU) for a few bytes of module, and 10: more initial
# memory than plzig.max_memory can ever allow, are refused before WAMR sees
# the module
for case in "8|a function declares more than 65535 locals" \
            "9|a table declares more than 1048576 elements" \
            "10|a linear memory declares more than 1023 MB"; do
    m=${case%%|*}; needle=${case#*|}
    set_fake "$fakedir/m$m/zig"
    start=$(date +%s%N)
    expect "module refused before loading: $needle" "$needle" \
        "CREATE FUNCTION imp_$m() RETURNS int LANGUAGE plzig AS \$\$ return $m$RANDOM; \$\$;"
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    if [ "$ms" -lt 3000 ]; then pass "... within ${ms} ms"; else fail "mode $m module took ${ms} ms"; fi
done

# 5: what the compiler process can reach
set_fake "$fakedir/m5/zig"
out=$(psqlq <<SQL
CREATE FUNCTION probe() RETURNS int LANGUAGE plzig AS \$\$ return $RANDOM; \$\$;
SELECT 'status: ' || plzig_sandbox_status();
SQL
)
status=$(sed -n 's/^status: //p' <<<"$out")
echo "         sandbox status: $status"
echo "$out" | sed -n 's/^/         /p' | grep -E "open|tcp|udp|unix|socket|signal|ptrace|shmget|setsid|setpgid|symlink|zig lib|compiler|exec|rlimit|env|fds|stdin|privs|seccomp|session|group leader|umask|cwd|HOME|hardlink|move out"
if grep -qF "zig-lib-dir=$fakedir/lib" <<<"$out"; then pass "--zig-lib-dir passed to the compiler"; else fail "--zig-lib-dir passed to the compiler"; fi
if [[ "$status" == "enforced (landlock ABI "*", seccomp"* ]]; then
    # Landlock (filesystem)
    for needle in "open /etc/passwd: Permission denied" \
                  "postgresql.conf: Permission denied" \
                  "planted.wasm: Permission denied" \
                  "open /tmp/planted: Permission denied" \
                  "open src/user.zig: ALLOWED" \
                  "read zig lib: ALLOWED" \
                  "write zig lib: Permission denied" \
                  "write compiler dir: Permission denied" \
                  "read other file near compiler: Permission denied" \
                  "exec /bin/true: Permission denied" \
                  "symlink in build dir: Permission denied"; do
        if grep -qF "$needle" <<<"$out"; then pass "landlock: $needle"; else fail "landlock: $needle"; fi
    done
    # seccomp (and Landlock scoping for the signal); EPERM = Operation not permitted
    for needle in "inet socket: Operation not permitted" \
                  "tcp connect 127.0.0.1:5432: no socket (Operation not permitted)" \
                  "udp socket: Operation not permitted" \
                  "udp send 127.0.0.1:5432: no socket (Operation not permitted)" \
                  "unix socket: Operation not permitted" \
                  "unix connect server socket: no socket (Operation not permitted)" \
                  "signal parent: Operation not permitted" \
                  "ptrace attach parent: Operation not permitted" \
                  "shmget: Operation not permitted" \
                  "setsid in child: Operation not permitted" \
                  "setpgid in child: Operation not permitted" \
                  "signal self: ALLOWED"; do
        if grep -qF "$needle" <<<"$out"; then pass "sandbox: $needle"; else fail "sandbox: $needle"; fi
    done
    # the process state the child was started with, observed from inside:
    # resource limits (plzig.compile_memory_limit = 4GB default, 256 MB per
    # file, no core dumps), a scrubbed environment, only stdin/stdout/stderr
    # open, default signal state, no_new_privs, the seccomp filter, death
    # with the backend, its own session/process group, umask 077, the build
    # directory as working directory and HOME; and Landlock refusing hard
    # links to files outside the sandbox and moving entries out of it
    for needle in "rlimit core: 0/0" \
                  "rlimit fsize: 268435456/268435456" \
                  "rlimit as: 4294967296/4294967296" \
                  "env names: PATH,HOME,ZIG_GLOBAL_CACHE_DIR,ZIG_LOCAL_CACHE_DIR,TMPDIR,LC_ALL,NO_COLOR" \
                  "env PATH=/usr/bin:/bin" \
                  "open fds: 0,1,2" \
                  "stdin: character device" \
                  "blocked signals: 0" \
                  "non-default signal dispositions: 0" \
                  "no_new_privs: 1" \
                  "seccomp mode: 2" \
                  "parent-death signal: 9" \
                  "session leader: yes" \
                  "process group leader: yes" \
                  "umask: 0077" \
                  "cwd: build directory" \
                  "HOME is cwd: yes"; do
        if grep -qF "$needle" <<<"$out"; then pass "child state: $needle"; else fail "child state: $needle"; fi
    done
    if grep -qE "rlimit cpu: ([0-9]+)/\1$" <<<"$out"; then pass "child state: CPU time limited"; else fail "child state: CPU time limited"; fi
    for what in "hardlink to postgresql.conf" "hardlink to pg_control" "move out of the build dir"; do
        if grep -qF "$what: " <<<"$out" && ! grep -qF "$what: ALLOWED" <<<"$out"; then
            pass "landlock: $what refused"
        else
            fail "landlock: $what refused"
        fi
    done
else
    fail "sandbox not enforced ($status)"
fi
abi=$(sed -n 's/.*landlock ABI \([0-9]*\).*/\1/p' <<<"$status")
if [ "${abi:-0}" -ge 10 ]; then
    if [[ "$status" == "enforced (landlock ABI $abi, seccomp)" ]]; then pass "status lists nothing missing at ABI $abi"; else fail "status lists nothing missing at ABI $abi ($status)"; fi
elif [ "${abi:-0}" -ge 6 ]; then
    if grep -qF "missing: Landlock ABI $abi lacks restrictions on" <<<"$status"; then pass "status lists what Landlock ABI $abi lacks"; else fail "status lists what Landlock ABI $abi lacks ($status)"; fi
fi

# 7: the recursive delete never follows symbolic links (compiler leaves traps).
# Without the sandbox, so that the fake compiler can create symbolic links.
rm -rf "$canary"; mkdir -p "$canary"; echo "keep me" > "$canary/canary"
set_conf compiler_sandbox off
set_fake "$fakedir/m7/zig"
out=$(psqlq -c "CREATE FUNCTION traps() RETURNS int LANGUAGE plzig AS \$\$ return $RANDOM; \$\$;")
echo "$out" | grep -E "escape|hardlink|deep" | sed 's/^/         /'
if grep -qF "escape-dir: ALLOWED" <<<"$out" && grep -qF "deep tree: 50 levels" <<<"$out"; then pass "rmtree: traps planted"; else fail "rmtree: traps planted"; echo "$out" | sed 's/^/         /'; fi
left=$(find "$PGDATA/plzig" -maxdepth 1 -name 'pgsql_tmp.build.*' | wc -l)
if [ "$left" -eq 0 ]; then pass "rmtree: build directory with symlinks and a 50-level tree removed"; else fail "rmtree: build directory removed ($left left)"; fi
if [ "$(cat "$canary/canary" 2>/dev/null)" = "keep me" ] && [ -d "$canary" ]; then pass "rmtree: canary outside the build directory intact"; else fail "rmtree: canary outside the build directory intact"; fi
if grep -q "could not remove" <<<"$out"; then fail "rmtree: no warnings"; else pass "rmtree: no warnings"; fi
set_conf compiler_sandbox ""
set_real

# 9: a hostile guest calling the host imports directly (forged pointers,
# lengths, handles and values).  The wrapper compiler makes the SDK's import
# table public; it needs the real compiler, hence no sandbox for this part.
echo "--- hostile guest"
mkdir -p "$fakedir/hostile"
gcc -O2 -static -DREAL_ZIG="\"$PLZIG_TEST_ZIG\"" -o "$fakedir/hostile/zig" /src/docker/fake/hostilezig.c || exit 1
set_conf compiler_sandbox off
set_conf zig_path "$fakedir/hostile/zig"
set_conf zig_lib_dir "$(dirname "$PLZIG_TEST_ZIG")/lib"
reload
cat > /tmp/plzig-hostile.sql <<'SQL'
CREATE OR REPLACE FUNCTION hostile(what int) RETURNS int STRICT LANGUAGE plzig AS $$
    const h = plzig.host;
    const P = plzig.rawPtr;
    const bad: usize = 0x7fff_ff00;           // far beyond the linear memory
    const sql = "SELECT $1::text";
    var slots = [1]plzig.Slot{.{ .val = 0, .len = 0, .is_null = 1 }};
    var vals = [2]plzig.Value{ .{ .val = 1, .len = 0, .kind = 2, .is_null = 0 },
                               .{ .val = 0, .len = 0, .kind = 8, .is_null = 1 } };
    var buf: [256]u8 align(8) = undefined;
    const p2 = try plzig.spi.prepare("SELECT $1::text, $2::text", &.{ .int2, .bytea });
    switch (what) {
        1 => _ = h.spi_execute(P([*]const u8, bad), 10, &slots, 0),
        2 => _ = h.spi_execute(sql.ptr, sql.len, P([*]const plzig.Slot, bad), 1),
        3 => _ = h.spi_execute(sql.ptr, sql.len, &slots, 70000),
        4 => _ = h.spi_execute(sql.ptr, sql.len, &slots, 0xffff_ffff),
        5 => { slots[0] = .{ .val = bad, .len = 5, .is_null = 0 }; _ = h.spi_execute(sql.ptr, sql.len, &slots, 1); },
        6 => { slots[0] = .{ .val = 1 << 40, .len = 5, .is_null = 0 }; _ = h.spi_execute(sql.ptr, sql.len, &slots, 1); },
        7 => { const s = "\xff\xfe"; slots[0] = .{ .val = plzig.addrOf(s), .len = 2, .is_null = 0 }; _ = h.spi_execute(sql.ptr, sql.len, &slots, 1); },
        8 => { const s = "a\x00b"; slots[0] = .{ .val = plzig.addrOf(s), .len = 3, .is_null = 0 }; _ = h.spi_execute(sql.ptr, sql.len, &slots, 1); },
        9 => _ = h.spi_prepare(sql.ptr, sql.len, P([*]const u32, bad), 2),
        10 => _ = h.spi_prepare(sql.ptr, sql.len, P([*]const u32, 8), 100000),
        11 => { const k = [1]u32{9}; _ = h.spi_prepare(sql.ptr, sql.len, &k, 1); },
        12 => { vals[0].val = 40000; _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        13 => { vals[0].val = @bitCast(@as(i64, -40000)); _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        14 => { vals[0].is_null = 7; _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        15 => { vals[0].kind = 99; _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        16 => { vals[1] = .{ .val = plzig.addrOf(&buf), .len = 0xffff_ffff, .kind = 8, .is_null = 0 }; _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        17 => { vals[1] = .{ .val = bad, .len = 16, .kind = 8, .is_null = 0 }; _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        18 => { vals[1] = .{ .val = 1 << 33, .len = 4, .kind = 8, .is_null = 0 }; _ = h.spi_execute_plan(p2.handle, &vals, 2); },
        19 => _ = h.spi_execute_plan(p2.handle, P([*]const plzig.Value, bad), 2),
        20 => _ = h.spi_execute_plan(p2.handle, &vals, 0x7fff_ffff),
        21 => { const pb = try plzig.spi.prepare("SELECT $1", &.{.boolean}); vals[0] = .{ .val = 2, .len = 0, .kind = 1, .is_null = 0 }; _ = h.spi_execute_plan(pb.handle, &vals, 1); },
        22 => { const pf = try plzig.spi.prepare("SELECT $1", &.{.float4}); vals[0] = .{ .val = 1 << 40, .len = 0, .kind = 5, .is_null = 0 }; _ = h.spi_execute_plan(pf.handle, &vals, 1); },
        23 => { const pt = try plzig.spi.prepare("SELECT $1", &.{.text}); const s = "\xc3"; vals[0] = .{ .val = plzig.addrOf(s), .len = 1, .kind = 7, .is_null = 0 }; _ = h.spi_execute_plan(pt.handle, &vals, 1); },
        24, 25, 26, 27, 28 => {
            // spi_cursor_fetch writes the row only if it fits; otherwise
            // the row stays current and only its size is returned
            const q = "SELECT 'abc'::text, 42";
            const c = h.spi_cursor_open(q.ptr, q.len, &slots, 0);
            const r0 = h.spi_cursor_fetch(c, P([*]u8, bad), 0);   // too small: nothing written
            const n: u32 = @truncate(@as(u64, @bitCast(r0)));
            switch (what) {
                24 => _ = h.spi_cursor_fetch(c, P([*]u8, bad), n),
                25 => {
                    // one byte short: still not written, still the same row
                    const r1 = h.spi_cursor_fetch(c, &buf, n - 1);
                    const r2 = h.spi_cursor_fetch(c, &buf, buf.len);
                    const v = plzig.rawPtr(*const [2]plzig.Value, plzig.addrOf(&buf));
                    const t = plzig.rawPtr([*]const u8, @intCast(v[0].val));
                    const r3 = h.spi_cursor_fetch(c, &buf, buf.len);
                    if (r0 == r1 and r1 == r2 and r0 >> 32 == 2 and v[1].val == 42 and
                        std.mem.eql(u8, t[0..v[0].len], "abc") and r3 == -1)
                        plzig.raiseMsg("fetch retry delivered the same row once");
                },
                26 => if (r0 > 0 and n > 0) plzig.raiseMsg("too-small fetch wrote nothing"),
                27 => {
                    // past the end: -1, again and again
                    _ = h.spi_cursor_fetch(c, &buf, buf.len);
                    if (h.spi_cursor_fetch(c, &buf, buf.len) == -1 and h.spi_cursor_fetch(c, &buf, buf.len) == -1)
                        plzig.raiseMsg("fetch past the end is -1");
                },
                28 => _ = h.spi_cursor_fetch(c, P([*]u8, 0xffff_fff8), n),
                else => {},
            }
        },
        29 => _ = h.spi_row_size(0),
        30, 31 => {
            _ = try plzig.spi.execute("SELECT 'x'::text", &.{});
            if (what == 30) _ = h.spi_row_read(0, P([*]u8, bad), 1000) else _ = h.spi_row_read(5, &buf, buf.len);
        },
        32 => { _ = try plzig.spi.execute("SELECT 'x'::text", &.{}); _ = h.spi_value_copy(0, 0, P([*]u8, bad), 10); },
        33 => { h.spi_plan_free(p2.handle); h.spi_plan_free(p2.handle); },
        34 => { const c = h.spi_cursor_open(sql.ptr, 6, &slots, 0); h.spi_cursor_close(c); h.spi_cursor_close(c); },
        35 => { _ = try plzig.spi.execute("SELECT 'x'::text", &.{}); _ = h.spi_colname_copy(0, P([*]u8, bad), 10); },
        36 => h.log(9, sql.ptr, sql.len),
        37 => h.raise(P([*]const u8, bad), 10),
        38 => _ = h.spi_execute(sql.ptr, 0xffff_fff0, &slots, 0),
        39 => _ = h.spi_cursor_open_plan(p2.handle ^ (1 << 20), &vals, 2),
        40 => { const pc = try plzig.spi.prepare("SELECT 1", &.{}); const c = h.spi_cursor_open_plan(pc.handle, &vals, 0);
                _ = h.spi_cursor_fetch(c, &buf, 0); _ = h.spi_cursor_fetch(c ^ 1, &buf, buf.len); },
        41 => { _ = try plzig.spi.execute("SELECT 'x'::text", &.{}); const n: u32 = @intCast(h.spi_row_size(0)); _ = h.spi_row_read(0, &buf, n - 1); },
        42 => h.raise_error(P([*]const u8, bad), 5, sql.ptr, 3, sql.ptr, 0, sql.ptr, 0),
        43 => h.raise_error("23514", 5, P([*]const u8, bad), 10, sql.ptr, 0, sql.ptr, 0),
        44 => h.raise_error("23514", 5, sql.ptr, 3, P([*]const u8, bad), 10, sql.ptr, 0),
        45 => h.raise_error("23514", 5, sql.ptr, 3, sql.ptr, 3, P([*]const u8, plzig.memSize() - 4), 0xffff_ffff),
        46 => h.raise_error("2351423514", 0xffff_ffff, sql.ptr, 3, sql.ptr, 0, sql.ptr, 0),
        47 => h.raise_error("XX000", 5, P([*]const u8, bad), 0xffff_ffff, sql.ptr, 0, sql.ptr, 0),
        48 => { const s = "a\x00b"; h.raise_error("23514", 5, s, 3, sql.ptr, 0, sql.ptr, 0); },
        49 => { const s = "23514"; h.raise_error(s, 5, sql.ptr, sql.len, sql.ptr, 0, sql.ptr, 0); },
        // fixed-width parameters (doc/abi.md, "Range checks"): forged values, lengths, pointers
        50, 51, 52, 53, 54, 55, 56, 57 => {
            const t: plzig.Type = switch (what) { 50, 55 => .interval, 51 => .uuid, 52 => .date, 53 => .oid,
                                                  54 => .timetz, 56 => .time, else => .timestamptz };
            const pf = try plzig.spi.prepare("SELECT $1::text", &.{t});
            vals[0] = switch (what) {
                50 => .{ .val = bad, .len = 16, .kind = 15, .is_null = 0 },
                51 => .{ .val = plzig.addrOf(&buf), .len = 15, .kind = 16, .is_null = 0 },
                52 => .{ .val = 1 << 40, .len = 0, .kind = 10, .is_null = 0 },
                53 => .{ .val = 1 << 33, .len = 0, .kind = 17, .is_null = 0 },
                54 => .{ .val = 0, .len = 0x8000_0000, .kind = 12, .is_null = 0 },
                55 => .{ .val = 1 << 40, .len = 16, .kind = 15, .is_null = 0 },
                56 => .{ .val = 86_400_000_001, .len = 0, .kind = 11, .is_null = 0 },
                else => .{ .val = 9223371331200000000, .len = 0, .kind = 14, .is_null = 0 },
            };
            _ = h.spi_execute_plan(pf.handle, &vals, 1);
        },
        // numeric: numeric_op and parameters with forged operands, lengths, buffers
        58, 59, 60, 61, 62, 63, 64 => {
            const one = "\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01"; // 1
            switch (what) {
                58 => _ = h.numeric_op(1, P([*]const u8, bad), 10, one, one.len, 0, &buf, buf.len),
                59 => _ = h.numeric_op(99, one, one.len, one, one.len, 0, &buf, buf.len),
                60 => _ = h.numeric_op(1, one, one.len, one, one.len, 0, P([*]u8, bad), 256),
                61 => _ = h.numeric_op(9, one, 0xffff_ffff, one, one.len, 0, &buf, buf.len),
                62 => {
                    @memset(&buf, 0xaa);
                    const r = h.numeric_op(1, one, one.len, one, one.len, 0, &buf, 9);
                    if (r == -10 and buf[0] == 0xaa and buf[9] == 0xaa) plzig.raiseMsg("numeric_op: too small, nothing written");
                },
                63, 64 => {
                    const pn = try plzig.spi.prepare("SELECT $1::text", &.{.numeric});
                    vals[0] = .{ .val = if (what == 63) bad else 1 << 40, .len = 10, .kind = 18, .is_null = 0 };
                    _ = h.spi_execute_plan(pn.handle, &vals, 1);
                },
                else => {},
            }
        },
        // tz_convert: forged operation, value, zone pointer/length/bytes
        65 => _ = h.tz_convert(9, 0, sql.ptr, 3),
        66 => _ = h.tz_convert(1, 0, P([*]const u8, bad), 5),
        67 => _ = h.tz_convert(2, 0, sql.ptr, 0xffff_ffff),
        68 => _ = h.tz_convert(1, 0x7fff_ffff_ffff_fffe, sql.ptr, 0),
        69 => { const z = "Europe/\xff"; _ = h.tz_convert(1, 0, z, z.len); },
        else => return 0,
    }
    return 1;
$$;
SQL
out=$(psqlq -f /tmp/plzig-hostile.sql)
if grep -qx "CREATE FUNCTION" <<<"$out" || [ -z "$out" ]; then pass "hostile guest: module with direct host calls loads"; else fail "hostile guest: module with direct host calls loads"; echo "$out" | sed 's/^/         /'; fi
n=0
while IFS='|' read -r what needle; do
    [ -z "$what" ] && continue
    out=$(psqlq -c "SELECT hostile($what);")
    if grep -qF -- "$needle" <<<"$out"; then
        n=$((n + 1))
    else
        fail "hostile guest case $what: expected \"$needle\""; echo "$out" | sed 's/^/         /'
    fi
done <<'CASES'
1|guest passed an invalid memory range
2|guest passed an invalid memory range
3|too many SPI parameters
4|too many SPI parameters
5|guest passed an invalid memory range
6|invalid SPI parameter pointer
7|invalid byte sequence for encoding
8|invalid byte sequence for encoding "UTF8": 0x00
9|guest passed an invalid memory range
10|too many SPI parameters
11|invalid type code 9 for parameter $1
12|value of parameter $1 is out of range for type smallint
13|value of parameter $1 is out of range for type smallint
14|invalid NULL flag in parameter $1
15|parameter $1 of the prepared statement is of type smallint, but a value of kind invalid was passed
16|SPI parameter is too long
17|guest passed an invalid memory range
18|invalid SPI parameter pointer
19|guest passed an invalid memory range
20|the prepared statement has 2 parameter(s), but 2147483647 were passed
21|value of parameter $1 is out of range for type boolean
22|value of parameter $1 is out of range for type real
23|invalid byte sequence for encoding
24|guest passed an invalid memory range
25|fetch retry delivered the same row once
26|too-small fetch wrote nothing
27|fetch past the end is -1
28|guest passed an invalid memory range
29|no SPI result available
30|guest passed an invalid memory range
31|SPI result row 5 is out of range
32|guest passed an invalid memory range
33|invalid prepared statement handle
34|invalid cursor handle
35|guest passed an invalid memory range
36|invalid log level 9
37|guest passed an invalid memory range
38|SQL statement is too long
39|invalid prepared statement handle
40|invalid cursor handle
41|row buffer is too small
42|guest passed an invalid memory range
43|guest passed an invalid memory range
44|guest passed an invalid memory range
45|guest passed an invalid memory range
46|invalid SQLSTATE "2351423514
47|SQLSTATE XX000 cannot be raised by a PL/Zig function
48|invalid byte sequence for encoding "UTF8": 0x00
49|ERROR:  SELECT $1::text
50|guest passed an invalid memory range
51|invalid length 15 of uuid value
52|date out of range
53|OID out of range
54|time zone displacement out of range
55|invalid SPI parameter pointer
56|time out of range
57|timestamp out of range
58|guest passed an invalid memory range
59|invalid numeric operation 99
60|guest passed an invalid memory range
61|invalid length 4294967295 of numeric value
62|numeric_op: too small, nothing written
63|guest passed an invalid memory range
64|invalid SPI parameter pointer
65|invalid time zone operation 9
66|guest passed an invalid memory range
67|time zone name is too long
68|timestamp out of range
69|invalid byte sequence for encoding
0|0
CASES
if [ "$n" -eq 70 ]; then pass "hostile guest: all 69 forged calls end in a clean ERROR"; fi
expect "hostile guest: backend still healthy" "4242" "SELECT 4242;"
if grep -qE "terminated by signal|server process .* was terminated" /tmp/server.log; then fail "hostile guest: no backend crash in the server log"; else pass "hostile guest: no backend crash in the server log"; fi
psqlq -c "DROP FUNCTION hostile(int); SELECT plzig_cache_clear();" >/dev/null

# 9b: forged entry points (doc/abi.md, "Call sequence"): plzig_init reports
# the argument buffer once per instance, plzig_alloc_args gives the block
# for arguments that do not fit it.  The wrapper lets the function choose
# what they return.  Every function returns x + length(t).
echo "--- hostile entry points"
hentry() {   # hentry <name> <zig declarations after the body>
    psqlq -c "CREATE OR REPLACE FUNCTION $1(x int, t text) RETURNS int STRICT LANGUAGE plzig AS \$\$
    return x + @as(i32, @intCast(t.len));
}
var hbuf: [8192]u8 align(8) = undefined;
$2
fn unused() void {
\$\$;"
}
# rejected when the module is loaded (CREATE FUNCTION's trial instantiation)
while IFS='|' read -r name decl; do
    [ -z "$name" ] && continue
    out=$(hentry "$name" "$decl")
    if grep -qF "module rejected: $( [ "$name" = he_trap ] && echo "plzig_init trapped" || echo "invalid argument buffer")" <<<"$out"; then
        pass "hostile entry points: $name rejected at load"
    else
        fail "hostile entry points: $name rejected at load"; echo "$out" | sed 's/^/         /'
    fi
done <<'CASES'
he_cap0|pub fn hostileInit() u64 { return @as(u64, plzig.addrOf(&hbuf)); }
he_cap8|pub fn hostileInit() u64 { return (@as(u64, 8) << 32) | plzig.addrOf(&hbuf); }
he_caphuge|pub fn hostileInit() u64 { return (@as(u64, 2 << 20) << 32) | plzig.addrOf(&hbuf); }
he_beyond|pub fn hostileInit() u64 { return (@as(u64, 4096) << 32) | 0x7fff_ff00; }
he_tail|pub fn hostileInit() u64 { return (@as(u64, 4096) << 32) | (plzig.memSize() - 100); }
he_wrap|pub fn hostileInit() u64 { return (@as(u64, 16) << 32) | 0xffff_fff8; }
he_trap|pub fn hostileInit() u64 { @panic("no"); }
CASES
# accepted: a misaligned buffer is written with byte copies
out=$(hentry he_misaligned "pub fn hostileInit() u64 { return (@as(u64, 4000) << 32) | (plzig.addrOf(&hbuf) + 3); }")
expect "hostile entry points: misaligned argument buffer works" "1236" "SELECT he_misaligned(1000, repeat('x', 236));"
# the block for large arguments
hentry he_alloc0 "pub fn hostileAllocArgs(len: u32) u32 { _ = len; return 0; }" >/dev/null
expect "hostile entry points: plzig_alloc_args failing is out of memory" "out of guest memory for arguments" "SELECT he_alloc0(1, repeat('x', 5000));"
expect "hostile entry points: small arguments do not need plzig_alloc_args" "11" "SELECT he_alloc0(1, repeat('x', 10));"
hentry he_allocbad "pub fn hostileAllocArgs(len: u32) u32 { _ = len; return 0x7fff_ff00; }" >/dev/null
expect "hostile entry points: plzig_alloc_args beyond memory" "guest passed an invalid memory range" "SELECT he_allocbad(1, repeat('x', 5000));"
hentry he_alloctail "pub fn hostileAllocArgs(len: u32) u32 { _ = len; return @intCast(plzig.memSize() - 64); }" >/dev/null
expect "hostile entry points: plzig_alloc_args block running past the end" "guest passed an invalid memory range" "SELECT he_alloctail(1, repeat('x', 5000));"
hentry he_allocodd "pub fn hostileAllocArgs(len: u32) u32 { if (len > hbuf.len - 8) return 0; return @intCast(plzig.addrOf(&hbuf) + 5); }" >/dev/null
expect "hostile entry points: misaligned plzig_alloc_args block works" "5001" "SELECT he_allocodd(1, repeat('x', 5000));"
expect "hostile entry points: backend still healthy" "4242" "SELECT 4242;"
if grep -qE "terminated by signal|server process .* was terminated" /tmp/server.log; then fail "hostile entry points: no backend crash in the server log"; else pass "hostile entry points: no backend crash in the server log"; fi
psqlq -c "DROP FUNCTION IF EXISTS he_misaligned(int, text), he_alloc0(int, text), he_allocbad(int, text), he_alloctail(int, text), he_allocodd(int, text); SELECT plzig_cache_clear();" >/dev/null
set_conf compiler_sandbox ""
set_real

# ---- the external toolchain (plzig.zig_path, zig_lib_dir, zig_sha256) ----
echo "--- toolchain checks"

# a function compiled while the compiler is configured ...
expect "compile with the configured compiler" "CREATE FUNCTION" \
    "CREATE FUNCTION tc_cached() RETURNS int LANGUAGE plzig AS \$\$ return 777; \$\$; SELECT 'CREATE FUNCTION';"

# unset: compiles fail with a hint, cached modules still run, CREATE EXTENSION works
set_zig_path ""
out=$(psqlq -c "$(compile_sql)")
if grep -qF "no Zig compiler is configured" <<<"$out" && grep -qF "HINT:" <<<"$out" &&
   grep -qF "plzig.zig_path" <<<"$out"; then
    pass "unset plzig.zig_path: compile refused with hint"
else
    fail "unset plzig.zig_path: compile refused with hint"; echo "$out" | sed 's/^/         /'
fi
expect "unset plzig.zig_path: cached function still runs (new session)" "777" "SELECT tc_cached();"
expect "unset plzig.zig_path: DO block refused" "no Zig compiler is configured" \
    "DO \$\$ // $RANDOM$RANDOM
\$\$ LANGUAGE plzig;"
psqlq -c "DROP DATABASE IF EXISTS plzig_noconf;" >/dev/null
psqlq -c "CREATE DATABASE plzig_noconf;" >/dev/null
out=$(psqlq -d plzig_noconf -c "CREATE EXTENSION plzig; SELECT 'CREATE EXTENSION';")
if grep -qx "CREATE EXTENSION" <<<"$out"; then pass "unset plzig.zig_path: CREATE EXTENSION succeeds"; else fail "unset plzig.zig_path: CREATE EXTENSION succeeds"; echo "$out" | sed 's/^/         /'; fi
psqlq -c "DROP DATABASE plzig_noconf;" >/dev/null

# relative paths are refused; PATH is never searched
set_zig_path "zig"
expect "relative plzig.zig_path refused" "plzig.zig_path must be an absolute path" "$(compile_sql)"
set_zig_path "/nonexistent/zig"
expect "missing compiler refused" "could not resolve plzig.zig_path" "$(compile_sql)"

# a decoy "zig" first on the server's PATH is never executed
decoy=/tmp/plzig-decoy
mkdir -p "$decoy"; rm -f "$decoy/ran"
printf '#!/bin/sh\ntouch %s/ran\necho 0.17.1\n' "$decoy" > "$decoy/zig"
chmod 755 "$decoy/zig"
PATH="$decoy:$PATH" pg_ctl -D "$PGDATA" -l /tmp/server.log -w restart >/dev/null
pm=$(head -1 "$PGDATA/postmaster.pid")
if tr '\0' '\n' <"/proc/$pm/environ" | grep -q "^PATH=$decoy:"; then pass "decoy: server PATH starts with the decoy directory"; else fail "decoy: server PATH starts with the decoy directory"; fi
set_zig_path ""
psqlq -c "$(compile_sql)" >/dev/null
set_zig_path "zig"
psqlq -c "$(compile_sql)" >/dev/null
set_real
expect "decoy: real compiler used" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
if [ ! -e "$decoy/ran" ]; then pass "decoy zig on PATH never executed"; else fail "decoy zig on PATH never executed"; fi
pg_ctl -D "$PGDATA" -l /tmp/server.log -w restart >/dev/null

# exact version match
set_fake "$fakedir/m6/zig"
out=$(psqlq -c "$(compile_sql)")
if grep -qF 'reports version "0.16.0", but PL/Zig requires exactly 0.17.1' <<<"$out"; then
    pass "compiler with another version refused (both versions in the error)"
else
    fail "compiler with another version refused"; echo "$out" | sed 's/^/         /'
fi

# ownership and modes of the binary, its directory, the lib directory
set_fake "$fakedir/m1/zig"
expect "fake compiler with correct version accepted" "import from a module other than" "$(compile_sql)"
chmod o+w "$fakedir/m1/zig"
expect "compiler writable by others refused" "the Zig compiler is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/m1/zig"; chmod g+w "$fakedir/m1/zig"
expect "compiler writable by group refused" "the Zig compiler is writable by group or others" "$(compile_sql)"
chmod g-w "$fakedir/m1/zig"; chmod o+w "$fakedir/m1"
expect "compiler directory writable by others refused" "the directory containing the Zig compiler is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/m1"; chmod 1777 "$fakedir/m1"
expect "sticky world-writable compiler directory refused" "the directory containing the Zig compiler is writable by group or others" "$(compile_sql)"
chmod 755 "$fakedir/m1"; chmod o+w "$fakedir/lib"
expect "lib directory writable by others refused" "the Zig lib directory is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/lib"
set_fake /opt/plzig-test/badowner/zig
expect "compiler owned by another user refused" "the Zig compiler is not owned by root or by the server user" "$(compile_sql)"
set_fake /opt/plzig-test/baddir/zig
expect "compiler in a directory owned by another user refused" "the directory containing the Zig compiler is not owned by root or by the server user" "$(compile_sql)"
ln -sf "$fakedir/m1/zig" "$fakedir/zig-link"
chmod o+w "$fakedir/m1/zig"
set_fake "$fakedir/zig-link"
expect "symlink resolved: target writable by others refused" "the Zig compiler is writable by group or others" "$(compile_sql)"
chmod o-w "$fakedir/m1/zig"
mkdir -p "$PGDATA/zigbin"; cp "$fakedir/m1/zig" "$PGDATA/zigbin/zig"
set_fake "$PGDATA/zigbin/zig"
expect "compiler inside the data directory refused" "must not be inside or contain the data directory" "$(compile_sql)"
rm -rf "$PGDATA/zigbin"

# lib directory selection
set_conf zig_path "$fakedir/m1/zig"; set_conf zig_lib_dir "lib"; reload
expect "relative plzig.zig_lib_dir refused" "plzig.zig_lib_dir must be an absolute path" "$(compile_sql)"
set_conf zig_lib_dir "$fakedir/m1"; reload
expect "lib dir without std/std.zig refused" "is not a Zig lib directory" "$(compile_sql)"
set_conf zig_lib_dir ""; reload
expect "no lib dir next to the compiler: refused with hint" "could not find the Zig lib directory" "$(compile_sql)"
# FHS layout <prefix>/bin/zig + <prefix>/lib/zig is auto-detected
mkdir -p /tmp/plzig-fhs/bin /tmp/plzig-fhs/lib/zig/std
cp "$fakedir/m5/zig" /tmp/plzig-fhs/bin/zig
echo "// fake" > /tmp/plzig-fhs/lib/zig/std/std.zig
set_zig_path /tmp/plzig-fhs/bin/zig
expect "FHS layout: <dir>/../lib/zig auto-detected" "zig-lib-dir=/tmp/plzig-fhs/lib/zig" "$(compile_sql)"
# a dynamically linked compiler cannot run under Landlock: refused up front
mkdir -p /tmp/plzig-dyn/lib/std
gcc -O2 -DMODE=1 -DPGDATA="\"$PGDATA\"" -o /tmp/plzig-dyn/zig /src/docker/fake/fakezig.c
echo "// fake" > /tmp/plzig-dyn/lib/std/std.zig
set_zig_path /tmp/plzig-dyn/zig
expect "dynamically linked compiler refused under Landlock" "is dynamically linked" "$(compile_sql)"

# checksum pin
set_real
real=$(readlink -f "$PLZIG_TEST_ZIG")
sum=$(sha256sum "$real" | cut -d' ' -f1)
set_conf zig_sha256 "0000000000000000000000000000000000000000000000000000000000000000"; reload
expect "wrong plzig.zig_sha256 refused" "does not match plzig.zig_sha256" "$(compile_sql)"
set_conf zig_sha256 "not-a-digest"; reload
expect "malformed plzig.zig_sha256 refused" "plzig.zig_sha256 is not a SHA-256 digest" "$(compile_sql)"
set_conf zig_sha256 "$sum"; reload
expect "correct plzig.zig_sha256 accepted" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
set_conf zig_sha256 "$(tr a-f A-F <<<"$sum")"; reload
expect "correct plzig.zig_sha256 accepted (upper case)" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
set_real

# only require, try and off are valid for plzig.compiler_sandbox; anything
# else (the old "on", boolean spellings, other case) makes every compile fail
# rather than falling back to some other mode
for v in on true 1 REQUIRE Try; do
    set_conf compiler_sandbox "$v"; reload
    expect "plzig.compiler_sandbox = $v refuses to compile" \
           "invalid value for plzig.compiler_sandbox: \"$v\"" "$(compile_sql)"
done
set_conf compiler_sandbox ""; reload
expect "plzig.compiler_sandbox default is require" "require" "LOAD 'plzig'; SHOW plzig.compiler_sandbox;"

# ---- build directories (pid reuse, stale directories) ----
echo "--- build directories"
# a leftover directory in the current naming scheme whose pid is alive (the
# shell's, standing in for a reused pid), and one in the old scheme
mkdir -p "$PGDATA/plzig/pgsql_tmp.build.$$.1.0123456789abcdef/sub" "$PGDATA/plzig/pgsql_tmp.build.1.1"
echo x > "$PGDATA/plzig/pgsql_tmp.build.$$.1.0123456789abcdef/sub/file"
expect "compile with leftover build directories present" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
left=$(find "$PGDATA/plzig" -maxdepth 1 -name 'pgsql_tmp.build.*' | wc -l)
if [ "$left" -eq 0 ]; then pass "leftover build directories swept (live pid too)"; else fail "leftover build directories swept ($left left)"; fi

# ---- module cache: size limit, LRU eviction, temp files, plzig_cache_clear ----
echo "--- module cache"
cachedir="$PGDATA/plzig/cache"
set_conf cache_size_limit "64MB"; reload
expect "plzig.cache_size_limit set from postgresql.conf" "64MB" "SHOW plzig.cache_size_limit;"
psqlq -c "CREATE OR REPLACE FUNCTION cache_a() RETURNS int LANGUAGE plzig AS \$\$ return 4100 + $RANDOM; \$\$;" >/dev/null
fa=$(ls -t "$cachedir"/*.wasm | head -1)
touch -d '3 days ago' "$fa"
# a cache hit in a new session refreshes the module's time
psqlq -c "SELECT cache_a();" >/dev/null
if [ "$(stat -c %Y "$fa")" -gt "$(date -d '1 hour ago' +%s)" ]; then pass "cache hit refreshes the module's mtime"; else fail "cache hit refreshes the module's mtime"; fi
hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
p1="$cachedir/$(hex).wasm"; p2="$cachedir/$(hex).wasm"; p3="$cachedir/$(hex).wasm"; p4="$cachedir/$(hex).wasm"
# 4 x 25 MB: with up to 14 MB of real modules, exactly the two oldest must go
for f in "$p1" "$p2" "$p3" "$p4"; do truncate -s 25M "$f"; chmod 600 "$f"; done
touch -d '4 days ago' "$p1"; touch -d '2 days ago' "$p2"; touch -d '1 day ago' "$p3"; touch -d '1 hour ago' "$p4"
ptmp="$cachedir/$(hex).wasm.tmp.99999"; echo junk > "$ptmp"
other="$cachedir/not-a-module"; truncate -s 20M "$other"; touch -d '5 days ago' "$other"
plink="$cachedir/$(hex).wasm"; echo "keep me" > "$canary/target"; ln -s "$canary/target" "$plink"; touch -h -d '6 days ago' "$plink"
pdir="$cachedir/$(hex).wasm"; mkdir "$pdir"; touch -d '6 days ago' "$pdir"
expect "compile with an over-full cache" "CREATE FUNCTION" \
    "CREATE OR REPLACE FUNCTION cache_b() RETURNS int LANGUAGE plzig AS \$\$ return 4200 + $RANDOM; \$\$; SELECT 'CREATE FUNCTION';"
if [ ! -e "$p1" ] && [ ! -e "$p2" ] && [ -e "$p3" ] && [ -e "$p4" ]; then pass "LRU eviction removed the two oldest modules only"; else fail "LRU eviction removed the two oldest modules only"; ls -la --time-style=+%F "$cachedir" | sed 's/^/         /'; fi
if [ -e "$fa" ]; then pass "recently used module kept"; else fail "recently used module kept"; fi
if [ ! -e "$ptmp" ]; then pass "stale temp file removed"; else fail "stale temp file removed"; fi
if [ -e "$other" ] && [ -L "$plink" ] && [ -d "$pdir" ] && [ "$(cat "$canary/target")" = "keep me" ]; then
    pass "eviction leaves non-matching names, symlinks and directories alone"
else
    fail "eviction leaves non-matching names, symlinks and directories alone"
fi
total=$(find "$cachedir" -maxdepth 1 -type f -name '*.wasm' -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
if [ "$total" -le $((64 * 1024 * 1024)) ]; then pass "cache within plzig.cache_size_limit ($total bytes)"; else fail "cache within plzig.cache_size_limit ($total bytes)"; fi
out=$(psqlq -c "LOAD 'plzig'" -c "ALTER SYSTEM SET plzig.cache_size_limit = '1TB';")
if grep -qF 'parameter "plzig.cache_size_limit" cannot be changed' <<<"$out"; then pass "ALTER SYSTEM cannot set plzig.cache_size_limit"; else fail "ALTER SYSTEM cannot set plzig.cache_size_limit"; echo "$out" | sed 's/^/         /'; fi
expect "SET cannot set plzig.cache_size_limit" "cannot be changed now" "LOAD 'plzig'; SET plzig.cache_size_limit = '1TB';"
# plzig_cache_clear: removes the cache files (and only those), loaded modules keep running
nmods() { find "$cachedir" -maxdepth 1 -type f -printf '%f\n' | grep -cE '^[0-9a-f]{64}\.wasm$'; }
nmod=$(nmods)
out=$(psqlq <<'SQL'
SELECT cache_a() > 0 AS loaded;
SELECT 'cleared: ' || plzig_cache_clear();
SELECT cache_a() > 0 AS still_runs;
SQL
)
if grep -qx "cleared: $nmod" <<<"$out"; then pass "plzig_cache_clear() returns the number of files removed ($nmod)"; else fail "plzig_cache_clear() returns the number of files removed ($nmod)"; echo "$out" | sed 's/^/         /'; fi
left=$(nmods)
if [ "$left" -eq 0 ] && [ "$(grep -c '^t$' <<<"$out")" -eq 2 ]; then pass "cache empty, loaded function still runs"; else fail "cache empty, loaded function still runs (left=$left)"; fi
if [ -e "$other" ] && [ -L "$plink" ] && [ -d "$pdir" ]; then pass "plzig_cache_clear leaves foreign entries alone"; else fail "plzig_cache_clear leaves foreign entries alone"; fi
expect "after plzig_cache_clear a new session recompiles" "t" "SELECT cache_a() > 0;"
rm -f "$other" "$plink"; rmdir "$pdir"
set_conf cache_size_limit ""; reload

# ---- no data directory paths in messages to unprivileged users ----
echo "--- messages to unprivileged users"
psqlq -c "DROP ROLE IF EXISTS plzig_sec; CREATE ROLE plzig_sec LOGIN; GRANT USAGE ON LANGUAGE plzig TO plzig_sec; GRANT CREATE ON SCHEMA public TO plzig_sec;" >/dev/null
psqlq -c "CREATE OR REPLACE FUNCTION leak_probe() RETURNS int LANGUAGE plzig AS \$\$ return 5150; \$\$;" >/dev/null
lf=$(ls -t "$cachedir"/*.wasm | head -1)
asuser() { PGOPTIONS="-c client_min_messages=log" psql -X -q -At -v VERBOSITY=verbose -U plzig_sec "$@" 2>&1; }
noleak() {   # noleak <description> <needle> <output>
    if ! grep -qF "$2" <<<"$3"; then fail "$1 (expected \"$2\")"; echo "$3" | sed 's/^/         /'
    elif grep -qF "$PGDATA" <<<"$3"; then fail "$1: data directory shown"; echo "$3" | sed 's/^/         /'
    else pass "$1, without the data directory"; fi
}
chmod 0644 "$lf"
noleak "unprivileged: cache file with wrong permissions" "wrong owner or permissions" "$(asuser -c 'SELECT leak_probe();')"
chmod 0600 "$lf"
mv "$lf" "$lf.orig"; ln -s /etc/passwd "$lf"
noleak "unprivileged: symlinked cache file" "could not open file \"plzig/cache/" "$(asuser -c 'SELECT leak_probe();')"
rm -f "$lf"; mv "$lf.orig" "$lf"
chmod 0750 "$PGDATA/plzig"
noleak "unprivileged: plzig directory with group permissions" "has group or other permissions" "$(asuser -c 'SELECT leak_probe();')"
chmod 0700 "$PGDATA/plzig"
noleak "unprivileged: compile error" "undeclared identifier" \
    "$(asuser -c "CREATE FUNCTION leak2() RETURNS int LANGUAGE plzig AS \$\$ return nope$RANDOM; \$\$;")"
noleak "unprivileged: module too large" "the compiled module is too large" \
    "$(asuser -c "CREATE FUNCTION leak3(i int) RETURNS int STRICT LANGUAGE plzig AS \$\$ return @as(i32, big[@intCast(i)]) + $RANDOM; } const big: [3 << 20]u8 = @splat(7); fn unused() void { \$\$;")"
expect "works again after repair" "5150" "SELECT leak_probe();"
psqlq -c "DROP OWNED BY plzig_sec; DROP ROLE plzig_sec;" >/dev/null

# make install puts no Zig files anywhere
dest=/tmp/plzig-destdir
rm -rf "$dest"
if make -s -C /src install DESTDIR="$dest" >/tmp/plzig-install.log 2>&1; then
    files=$(cd "$dest" && find . -type f -o -type l | sort)
    # 6 program/data files plus 4 license files (ours, the notices, and the
    # Apache and Zig-MIT texts for the code linked into the binaries)
    zigfiles=$(grep -E '(^|/)zig$|/zig-[0-9]|/lib/std/|std\.zig$|compiler_rt|/lib/libc/' <<<"$files")
    n=$(wc -l <<<"$files")
    nlic=$(grep -cE '/extension/plzig/(LICENSE|THIRD-PARTY-NOTICES|LICENSES/[^/]+)$' <<<"$files")
    if [ -z "$zigfiles" ] && [ "$n" -eq 10 ] && [ "$nlic" -eq 4 ] && grep -q 'plzig-validate$' <<<"$files"; then
        pass "make install tree contains no Zig files ($n files)"
    else
        fail "make install tree contains no Zig files"; echo "$files" | sed 's/^/         /'
    fi
else
    fail "make install into DESTDIR"; sed 's/^/         /' /tmp/plzig-install.log
fi
rm -rf "$dest"

# PL/Python and PL/Perl are benchmark-only (bench/Dockerfile): never in this
# image, and bench/ is not part of the test image's source tree
# (.dockerignore) nor of the make install tree (checked above: 10 files)
pls=$( { ls "$(pg_config --pkglibdir)" "$(pg_config --sharedir)/extension" 2>/dev/null
         dpkg-query -W -f '${Package}\n' 2>/dev/null; } | grep -Ei 'plpython|plperl|plpy' | sort -u)
if [ -z "$pls" ] && [ ! -e /src/bench ]; then
    pass "no PL/Python or PL/Perl in the test image, no bench/ in its source tree"
else
    fail "no PL/Python or PL/Perl in the test image, no bench/ in its source tree"
    echo "$pls" | sed 's/^/         /'
fi

# 6: on-disk state: private directories and files
perm=$(stat -c '%a %U' "$PGDATA/plzig" "$PGDATA/plzig/cache" "$PGDATA/plzig/pgsql_tmp.zig-cache" | sort -u)
if [ "$perm" = "700 postgres" ]; then pass "plzig directories are 0700"; else fail "plzig directories are 0700 ($perm)"; fi
bad=$(find "$PGDATA/plzig/cache" -type f ! -perm 600 | wc -l)
cnt=$(find "$PGDATA/plzig/cache" -type f -name '*.wasm' | wc -l)
if [ "$bad" -eq 0 ] && [ "$cnt" -gt 0 ]; then pass "cache files are 0600 ($cnt modules)"; else fail "cache files are 0600 (bad=$bad)"; fi

# 7: tampering is refused, not followed
psqlq -c "CREATE FUNCTION tamper() RETURNS int LANGUAGE plzig AS \$\$ return 4242; \$\$;" >/dev/null
f=$(ls -t "$PGDATA"/plzig/cache/*.wasm | head -1)
mv "$f" "$f.orig"; ln -s /etc/passwd "$f"
expect "symlinked cache file is refused" "could not open file" "SELECT tamper();"
rm -f "$f"; mv "$f.orig" "$f"
chmod 0644 "$f"
expect "cache file with wrong permissions is refused" "wrong owner or permissions" "SELECT tamper();"
chmod 0600 "$f"
chmod 0750 "$PGDATA/plzig"
expect "plzig directory with group permissions is refused" "has group or other permissions" "SELECT tamper();"
chmod 0700 "$PGDATA/plzig"
expect "works again after repair" "4242" "SELECT tamper();"

# 7b: entries planted in the plzig directory are refused, not followed
f=$(ls -t "$PGDATA"/plzig/cache/*.wasm | head -1)
mv "$f" "$f.orig"
mkfifo -m 600 "$f"
out=$(timeout 30 psql -X -q -At -c "SELECT tamper();" 2>&1); rc=$?
if [ $rc -ne 124 ] && grep -qF "is not a regular file" <<<"$out"; then pass "FIFO planted as a cache file is refused without blocking"; else fail "FIFO planted as a cache file is refused without blocking (rc $rc)"; echo "$out" | sed 's/^/         /'; fi
rm -f "$f"
# a hard link to another file of the server user (same owner, mode 0600)
# passes the file checks, but is only ever read: the loader rejects it,
# eviction and plzig_cache_clear() unlink the name, never the file
conf_sum=$(sha256sum "$PGDATA/postgresql.conf" | cut -d' ' -f1)
chmod 600 "$PGDATA/postgresql.conf"
ln "$PGDATA/postgresql.conf" "$f"
expect "hard link to postgresql.conf as a cache file is rejected by the loader" "invalid WebAssembly module" "SELECT tamper();"
out=$(psqlq -c "SELECT plzig_cache_clear() > 0;")
if [ ! -e "$f" ] && [ -f "$PGDATA/postgresql.conf" ] && [ "$(sha256sum "$PGDATA/postgresql.conf" | cut -d' ' -f1)" = "$conf_sum" ] &&
   [ "$(stat -c %h "$PGDATA/postgresql.conf")" = 1 ]; then
    pass "plzig_cache_clear() removed the hard link, postgresql.conf intact"
else
    fail "plzig_cache_clear() removed the hard link, postgresql.conf intact"; echo "$out" | sed 's/^/         /'
fi
mv "$f.orig" "$f"
expect "works again after repair" "4242" "SELECT tamper();"
# the compile lock and the Zig cache directory as symbolic links
mkdir -p "$canary"; rm -f "$canary/lock-target"
mv "$PGDATA/plzig/compile.lock" "$PGDATA/plzig/compile.lock.orig"
ln -s "$canary/lock-target" "$PGDATA/plzig/compile.lock"
expect "symlinked compile lock refused" "could not open file \"plzig/compile.lock\"" "$(compile_sql)"
if [ ! -e "$canary/lock-target" ]; then pass "symlinked compile lock not followed"; else fail "symlinked compile lock not followed"; fi
rm -f "$PGDATA/plzig/compile.lock"; mv "$PGDATA/plzig/compile.lock.orig" "$PGDATA/plzig/compile.lock"
mv "$PGDATA/plzig/pgsql_tmp.zig-cache" "$PGDATA/plzig/zig-cache.orig"
mkdir -p "$canary/zigcache"; chmod 700 "$canary/zigcache"
ln -s "$canary/zigcache" "$PGDATA/plzig/pgsql_tmp.zig-cache"
expect "symlinked Zig cache directory refused" "is not a directory (or is a symbolic link)" "$(compile_sql)"
if [ -z "$(ls -A "$canary/zigcache")" ]; then pass "symlinked Zig cache directory not used"; else fail "symlinked Zig cache directory not used"; fi
rm -f "$PGDATA/plzig/pgsql_tmp.zig-cache"; mv "$PGDATA/plzig/zig-cache.orig" "$PGDATA/plzig/pgsql_tmp.zig-cache"
# a file planted where a build directory would go is swept, not followed
ln -s "$canary" "$PGDATA/plzig/pgsql_tmp.build.1.1.0123456789abcdef"
echo "keep me" > "$canary/canary"
expect "compile with a planted build-directory symlink" "CREATE FUNCTION" "$(compile_sql) SELECT 'CREATE FUNCTION';"
if [ ! -L "$PGDATA/plzig/pgsql_tmp.build.1.1.0123456789abcdef" ] && [ "$(cat "$canary/canary")" = "keep me" ]; then
    pass "planted build-directory symlink removed, its target untouched"
else
    fail "planted build-directory symlink removed, its target untouched"
fi
expect "works after the planting tests" "4242" "SELECT tamper();"

# 8: no zombie or leftover compiler processes
z=$(awk '{ if ($3 == "Z") print }' /proc/[0-9]*/stat 2>/dev/null | wc -l)
c=$(for p in /proc/[0-9]*; do readlink "$p/exe" 2>/dev/null; done | grep -cE '/zig$|plzig-validate$')
if [ "$z" -eq 0 ]; then pass "no zombie processes"; else fail "no zombie processes ($z)"; fi
if [ "$c" -eq 0 ]; then pass "no leftover compiler processes"; else fail "no leftover compiler processes ($c)"; fi

echo "--- security checks: $fails failure(s)"
exit $fails
