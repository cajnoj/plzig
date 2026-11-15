/* plzig--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION plzig" to load this file. \quit

CREATE FUNCTION plzig_call_handler() RETURNS language_handler
    AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION plzig_inline_handler(internal) RETURNS void
    STRICT AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION plzig_validator(oid) RETURNS void
    STRICT AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE TRUSTED LANGUAGE plzig
    HANDLER plzig_call_handler
    INLINE plzig_inline_handler
    VALIDATOR plzig_validator;

-- Anybody with USAGE can make the server run the Zig compiler on their
-- input, so USAGE is granted deliberately by a DBA, never to PUBLIC.
REVOKE USAGE ON LANGUAGE plzig FROM PUBLIC;

CREATE FUNCTION plzig_sandbox_status() RETURNS text
    STRICT VOLATILE AS 'MODULE_PATHNAME' LANGUAGE C;
REVOKE ALL ON FUNCTION plzig_sandbox_status() FROM PUBLIC;

CREATE FUNCTION plzig_cache_clear() RETURNS bigint
    STRICT VOLATILE AS 'MODULE_PATHNAME' LANGUAGE C;
REVOKE ALL ON FUNCTION plzig_cache_clear() FROM PUBLIC;

-- Compiles every PL/Zig function of the current database (executes none);
-- returns those that fail.  Runs the compiler, so superuser only by default.
CREATE FUNCTION plzig_check_all(
    OUT function regprocedure, OUT sqlstate text, OUT message text, OUT detail text)
    RETURNS SETOF record
    STRICT VOLATILE PARALLEL UNSAFE AS 'MODULE_PATHNAME' LANGUAGE C;
REVOKE ALL ON FUNCTION plzig_check_all() FROM PUBLIC;

COMMENT ON LANGUAGE plzig IS 'PL/Zig procedural language (sandboxed WebAssembly)';
COMMENT ON FUNCTION plzig_call_handler() IS 'PL/Zig call handler';
COMMENT ON FUNCTION plzig_inline_handler(internal) IS 'PL/Zig anonymous code block handler';
COMMENT ON FUNCTION plzig_validator(oid) IS 'PL/Zig function validator';
COMMENT ON FUNCTION plzig_sandbox_status() IS 'How the last PL/Zig compilation in this session was confined';
COMMENT ON FUNCTION plzig_check_all() IS 'Compile every PL/Zig function of the current database without executing any; returns those that fail with their error';
COMMENT ON FUNCTION plzig_cache_clear() IS 'Remove all compiled PL/Zig modules from the cache; returns the number of files removed';
