--
-- testing: unit checks of pure C functions through the plzig_test_*
-- helpers, which exist only in a PLZIG_TESTING=1 build (make
-- installcheck-testing).  They are declared here, never by the extension.
--
\set VERBOSITY terse
CREATE EXTENSION IF NOT EXISTS plzig;
CREATE SCHEMA plzig_testing;
SET search_path = plzig_testing, public;
CREATE FUNCTION valid_identifier(text) RETURNS bool STRICT LANGUAGE C AS 'plzig', 'plzig_test_valid_identifier';
CREATE FUNCTION generate_source(regtype[], text[], regtype, bool, text) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_generate_source';
CREATE FUNCTION generate_inline_source(text) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_generate_inline_source';
CREATE FUNCTION type_map(regtype) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_type_map';
CREATE FUNCTION param_kind_oid(int) RETURNS regtype STRICT LANGUAGE C AS 'plzig', 'plzig_test_param_kind_oid';
CREATE FUNCTION cache_key(bytea) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_cache_key';
CREATE FUNCTION zig_flags() RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_zig_flags';
CREATE FUNCTION display_path(text) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_display_path';
CREATE FUNCTION build_path(text) RETURNS text LANGUAGE C AS 'plzig', 'plzig_test_path';
CREATE FUNCTION format_output(bytea, text, bool) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_format_output';
CREATE FUNCTION cache_file_kind(text) RETURNS int STRICT LANGUAGE C AS 'plzig', 'plzig_test_cache_file_kind';
CREATE FUNCTION sandbox_missing(int, int) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_sandbox_missing';
CREATE FUNCTION replace_all(text, text, text) RETURNS text STRICT LANGUAGE C AS 'plzig', 'plzig_test_replace_all';
CREATE FUNCTION is_sha256_hex(text) RETURNS bool STRICT LANGUAGE C AS 'plzig', 'plzig_test_is_sha256_hex';
CREATE FUNCTION sandbox_mode() RETURNS int STRICT LANGUAGE C AS 'plzig', 'plzig_test_sandbox_mode';

--
-- parameter names
--
SELECT n, valid_identifier(n)
  FROM unnest(ARRAY['a', 'A', '_', '_x9', 'arg1', 'Return', 'return', 'i32',
                    'plzig', 'std', 'call', 'Call', 'plzig_x', 'std2', 'calls',
                    '', '9a', 'a b', 'a-b', 'größe', 'a"b', 'a.b', E'a\tb',
                    repeat('x', 63), repeat('x', 64), repeat('x', 65)]) AS n;

--
-- source generation: one header line, the body verbatim, a closing brace
--
SELECT generate_source('{}', '{}', 'void', false, 'plzig.notice("x", .{});');
SELECT generate_source('{int4,int4}', '{a,b}', 'int4', true, 'return a + b;');
SELECT generate_source('{bool,int2,int4,int8,float4,float8,text,varchar,bpchar,bytea,numeric,jsonb,int4[]}',
                       '{a,b,c,d,e,f,g,h,i,j,k,l,m}', 'text', false, 'return null;');
SELECT generate_source('{date,time,timetz,timestamp,timestamptz,interval,uuid,oid}',
                       '{a,b,c,d,e,f,g,h}', 'timestamptz', false, 'return null;');
-- jsonb: read in place as an argument, JSON text as the result
SELECT generate_source('{jsonb,numeric}', '{j,n}', 'jsonb', true, 'return null;');
SELECT generate_source('{int4,int4,int4}', ARRAY[NULL, 'return', NULL], 'bytea', true, '');
SELECT generate_source('{text}', '{x}', 'numeric', false, E'line 1\n}\nfn helper() void {\n// line 3');
-- a body with a NUL-free but hostile text is still only the function body
SELECT generate_source('{}', '{}', 'int4', true, E'}\nconst x = @import("std");\nfn f() void {');
-- the header never spans lines, whatever the signature
SELECT length(s) - length(replace(s, E'\n', '')) AS newlines
  FROM (SELECT generate_source(array_fill('text'::regtype, ARRAY[100]),
                               (SELECT array_agg('a' || i) FROM generate_series(1, 100) i),
                               'text', false, 'return null;') AS s) q;
SELECT generate_inline_source('plzig.notice("hi", .{});');
SELECT generate_inline_source('');
SET plzig.max_source_size = '1kB';
SELECT length(generate_inline_source(repeat('x', 1024)));
SELECT generate_inline_source(repeat('x', 1025));
RESET plzig.max_source_size;

--
-- type mapping: Zig type, result-column kind, prepared-statement parameter kind
--
SELECT t, type_map(t)
  FROM unnest(ARRAY['void', 'bool', 'int2', 'int4', 'int8', 'float4', 'float8', 'text',
                    'varchar', 'bpchar', 'bytea', 'name', '"char"', 'numeric', 'json',
                    'int4[]', 'text[]', 'oid', 'regclass', 'uuid', 'date', 'time', 'timetz',
                    'timestamp', 'timestamptz', 'interval', 'jsonb']::regtype[]) AS t;
CREATE DOMAIN plzig_testing.d_int AS int;
SELECT type_map('plzig_testing.d_int');
SELECT k, param_kind_oid(k) FROM generate_series(0, 21) k;

--
-- cache key: deterministic, 64 hex digits, sensitive to every byte, and
-- equal to an independent computation from its documented parts
--
SELECT cache_key('abc') = cache_key('abc') AS deterministic,
       cache_key('abc') ~ '^[0-9a-f]{64}$' AS hex,
       cache_key('abc') <> cache_key('abd') AS byte_sensitive,
       cache_key('abc') <> cache_key('abc ') AS length_sensitive,
       cache_key('') <> cache_key('\x00') AS empty_vs_nul;
-- independent computation: SHA-256 over length-prefixed parts (8-byte little
-- endian length, the bytes, a 0 byte): "abi5", the Zig version, the compiler
-- flags, the SDK digest (same construction over plzig.zig and root.zig), the source
-- (the length is the host's uint64, little endian on x86_64 and aarch64)
CREATE FUNCTION plzig_testing.le8(n int8) RETURNS bytea LANGUAGE sql AS $$
  SELECT string_agg(substring(int8send(n) FROM 9 - i FOR 1), ''::bytea ORDER BY i) FROM generate_series(1, 8) i
$$;
CREATE FUNCTION plzig_testing.part(b bytea) RETURNS bytea LANGUAGE sql AS $$
  SELECT plzig_testing.le8(length(b)) || b || '\x00'::bytea
$$;
SELECT setting AS sharedir FROM pg_config WHERE name = 'SHAREDIR' \gset
SELECT encode(sha256(plzig_testing.part(pg_read_binary_file(:'sharedir' || '/plzig/sdk/plzig.zig')) ||
                     plzig_testing.part(pg_read_binary_file(:'sharedir' || '/plzig/sdk/root.zig'))), 'hex') AS sdk \gset
SELECT cache_key('pub fn call() anyerror!void {}') =
       encode(sha256(plzig_testing.part('abi5') ||
                     plzig_testing.part('0.17.1') ||
                     plzig_testing.part(convert_to(zig_flags(), 'UTF8')) ||
                     plzig_testing.part(convert_to(:'sdk', 'UTF8')) ||
                     plzig_testing.part(convert_to('pub fn call() anyerror!void {}', 'UTF8'))), 'hex')
       AS matches_documented_construction;
-- the flags are fixed and contain no user input
SELECT zig_flags();
-- same key in a new session
SELECT cache_key('stable?') AS k1 \gset
\c
SET search_path = plzig_testing, public;
SELECT cache_key('stable?') = :'k1' AS same_in_new_session;

--
-- paths: relative display of data-directory paths, length limit
--
SELECT current_setting('data_directory') AS dd \gset
SELECT display_path(:'dd' || '/plzig/cache/x.wasm') AS inside,
       replace(display_path(:'dd'), :'dd', '<DD>') AS datadir_itself,
       replace(display_path(:'dd' || 'x/plzig'), :'dd', '<DD>') AS sibling,
       display_path('/usr/lib/x') AS outside,
       display_path('relative/path') AS relative;
SELECT build_path(NULL) AS dirs;
SELECT length(build_path(repeat('a', 1023))) AS len_1023;
SELECT build_path(repeat('a', 1024));
SELECT build_path(repeat('a', 5000));

--
-- output sanitising (compiler and validator messages)
--
-- build directory stripped, line numbers mapped to the body, column kept
SELECT format_output(convert_to('/x/build.1/src/user.zig:3:7: error: expected X' || E'\n' ||
                                '/x/build.1/sdk/root.zig:90:19: note: here', 'UTF8'),
                     '/x/build.1', false);
-- line 1 (the header) maps to line 0; a malformed position is left alone
SELECT format_output(convert_to('src/user.zig:1:68: e1' || E'\n' || 'src/user.zig:x:1: e2' || E'\n' ||
                                'src/user.zig:12: e3' || E'\n' || 'src/user.zig:4:9 e4', 'UTF8'),
                     '/b', false);
-- validator output: positions at the start of a line
SELECT format_output(convert_to('3:5: keyword not allowed in PL/Zig ''asm''' || E'\n' ||
                                '1:1: builtin not allowed in PL/Zig ''@embedFile''' || E'\n' || 'x 2:3: y', 'UTF8'),
                     '/b', true);
-- control characters, DEL and NUL become '?', continuation lines are indented,
-- trailing whitespace is trimmed
SELECT format_output('\x61001b5b33316d0a4552524f523a2020666f726765640d07087f0a0a20200a', '/b', false);
-- invalid UTF-8 turns every non-ASCII byte into '?'; valid UTF-8 is kept
SELECT format_output('\x6772c3bc7373652c20ff2c20c3a9', '/b', false) AS invalid,
       format_output(convert_to('grüße, é', 'UTF8'), '/b', false) AS valid;
-- server paths are hidden: data directory, Zig cache, $libdir
SELECT replace(format_output(convert_to(:'dd' || '/plzig/pgsql_tmp.zig-cache/o/x.zig ' || :'dd' || '/global ' ||
                                        :'dd', 'UTF8'), '/b', false), :'dd', '<DD>') AS paths;
SELECT setting AS pkglibdir FROM pg_config WHERE name = 'PKGLIBDIR' \gset
SELECT format_output(convert_to(:'pkglibdir' || '/plzig/plzig-validate: oops', 'UTF8'), '/b', true);
-- empty output, output of only whitespace
SELECT format_output('', '/b', false) = '' AS empty, format_output(convert_to(E' \n\t\n', 'UTF8'), '/b', false) = '' AS blank;
-- a large output (64 kB kept by the spawner) is handled in one piece
SELECT length(format_output(convert_to(repeat('src/user.zig:2:1: x' || E'\n', 3000), 'UTF8'), '/b', false));

SELECT replace_all('aXbXc', 'X', '--'), replace_all('aaa', 'aa', 'b'), replace_all('abc', '', 'z'),
       replace_all('', 'a', 'b'), replace_all('abcabc', 'abc', '');

--
-- cache file names: only exactly our patterns are ever touched
--
SELECT name, cache_file_kind(name)
  FROM unnest(ARRAY[
    repeat('a', 64) || '.wasm',
    repeat('0', 64) || '.wasm',
    repeat('a', 64) || '.wasm.tmp.12345',
    repeat('a', 64) || '.wasm.tmp.1234567890',
    repeat('a', 64) || '.wasm.tmp.12345678901',
    repeat('a', 64) || '.wasm.tmp.',
    repeat('a', 64) || '.wasm.tmp.12x',
    repeat('A', 64) || '.wasm',
    repeat('a', 63) || '.wasm',
    repeat('a', 65) || '.wasm',
    repeat('a', 64) || '.wasm.bak',
    repeat('a', 64) || '.WASM',
    repeat('a', 64),
    repeat('g', 64) || '.wasm',
    'compile.lock', '.', '..', '']) AS name;

--
-- sandbox status texts
--
SELECT abi, sc, sandbox_missing(abi, sc)
  FROM (VALUES (-38, -22), (-1, 0), (0, 1), (1, 0), (3, 0), (5, -38), (6, 0), (8, 0), (9, 0), (10, 0), (10, -1), (12, 1)) v(abi, sc);

SELECT is_sha256_hex(repeat('a', 64)), is_sha256_hex(repeat('F', 64)), is_sha256_hex(repeat('a', 63)),
       is_sha256_hex(repeat('a', 65)), is_sha256_hex(repeat('g', 64)), is_sha256_hex('');
SELECT sandbox_mode() AS mode_require_is_2;

DROP SCHEMA plzig_testing CASCADE;
