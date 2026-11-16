---
title: PL/Zig
---

# PL/Zig — Zig as a PostgreSQL procedural language

PL/Zig lets you write PostgreSQL functions, procedures and `DO` blocks in
[Zig](https://ziglang.org):

```sql
CREATE FUNCTION add(a int, b int) RETURNS int STRICT LANGUAGE plzig AS $$
    return a + b;
$$;
SELECT add(1, 2);   -- 3
```

The Zig code is not compiled to native code. It is compiled to a
WebAssembly module and run by an interpreter-only WebAssembly runtime
inside the PostgreSQL backend: a function is given its own memory and no
system-call interface, and a module is loaded only if it imports nothing
but the small API PL/Zig provides (logging, errors, queries, prepared
statements, cursors). These are defences with known limits, not
guarantees; the security model lists what they rely on, what was tested
and what remains open.

Supported servers: PostgreSQL 14 to 19 on Linux (x86_64 and aarch64).

- [Source code and documentation](https://github.com/cajnoj/plzig)
- [README: installation, types, examples](https://github.com/cajnoj/plzig#readme)
- [Security model](https://github.com/cajnoj/plzig/blob/master/doc/security.md)
- [Packaging](https://github.com/cajnoj/plzig/blob/master/doc/packaging.md)

PL/Zig is not yet released; the current tree is a development version.
