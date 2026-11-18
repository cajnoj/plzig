# Generator for the host/guest ABI definitions (abi/plzig-abi.table, whose
# header describes the format).  POSIX awk; run by abi/gen-abi.sh:
#
#   awk -v table=<table> -v mode=c -f gen-abi.awk              > plzig_abi.h
#   awk -v table=<table> -v mode=zig -f gen-abi.awk plzig.zig  > new plzig.zig
#       (the file with every "// @plzig-abi begin <what>" ... "// @plzig-abi
#       end" region replaced by the generated text, indented like its marker)
#   awk -v table=<table> -v mode=doc -f gen-abi.awk abi.md
#       (prints what is wrong in doc/abi.md: a missing row per import with
#       its signature string, or per export with its signature; the number
#       of imports; a row in the import or export table for a name the
#       table does not have; exit status 1 if anything)
#
# Any malformed record, unknown region, missing or repeated region is an
# error (message on stderr, exit status 2).

function die(msg) {
    print "gen-abi: " msg > "/dev/stderr"
    failed = 2
    exit 2
}

function tdie(msg) { die(table ":" tline ": " msg) }

function is_int(t) { return t ~ /^[ui](16|32|64)$/ }

function check_name(n, what) {
    if (n !~ /^[a-z_][a-z0-9_]*$/) tdie("bad " what " name '" n "'")
}

# --- the table -------------------------------------------------------------

# the parameters f[4..nf] of import or export record n into pn[n, p] and
# pt[n, p]; returns their number.  ref(T) only for exports.
function read_params(f, nf, n, pn, pt, isexport,    i, p, np, nm, ty) {
    np = 0
    for (i = 4; i <= nf; i++) {
        p = index(f[i], ":")
        if (p == 0) tdie("parameter '" f[i] "' has no type")
        nm = substr(f[i], 1, p - 1); ty = substr(f[i], p + 1)
        check_name(nm, "parameter")
        if (!is_int(ty) && ty !~ /^(in|out)\((u8|u32|Slot|Value)\)$/ &&
            !(isexport && ty ~ /^ref\((u8|u32|Slot|Value)\)$/)) tdie("bad parameter type '" ty "'")
        if (ty == "u16" || ty == "i16") tdie("16-bit parameters do not exist in wasm")
        np++
        pn[n, np] = nm; pt[n, np] = ty
    }
    return np
}

function read_table(    line, desc, i, nf, f, p, nm, ty) {
    nstruct = 0; nkind = 0; nenum = 0; nimport = 0; nexport = 0; version = ""
    cur = ""                    # "struct" or "enum" inside a block
    while ((getline line < table) > 0) {
        tline++
        if (line ~ /^[ \t]*(#|$)/) continue
        desc = ""
        i = index(line, " -- ")
        if (i > 0) {
            desc = substr(line, i + 4)
            line = substr(line, 1, i - 1)
            sub(/^[ \t]+/, "", desc); sub(/[ \t]+$/, "", desc)
            if (index(desc, "*/") > 0) tdie("\"*/\" in a description (it becomes a C comment)")
        }
        nf = split(line, f, /[ \t]+/)
        if (f[1] == "") { for (i = 1; i < nf; i++) f[i] = f[i + 1]; nf-- }
        if (f[1] == "version") {
            if (nf != 2 || f[2] !~ /^[1-9][0-9]*$/ || version != "") tdie("bad version record")
            version = f[2]
        } else if (f[1] == "struct") {
            if ((nf != 3 && !(nf == 4 && f[4] == "priv")) || cur != "") tdie("bad struct record")
            nstruct++; s_zig[nstruct] = f[2]; s_c[nstruct] = f[3]; s_desc[nstruct] = desc
            s_pub[nstruct] = (nf == 3)
            s_nfield[nstruct] = 0; cur = "struct"
        } else if (f[1] == "field") {
            if (nf != 3 || cur != "struct" || f[3] !~ /^u(16|32|64)$/) tdie("bad field record")
            check_name(f[2], "field")
            p = ++s_nfield[nstruct]
            sf_name[nstruct, p] = f[2]; sf_type[nstruct, p] = f[3]; sf_desc[nstruct, p] = desc
        } else if (f[1] == "enum" || f[1] == "consts") {
            if (f[1] == "enum" && (nf != 7 || f[5] != "u32")) tdie("bad enum record")
            if (f[1] == "consts" && (nf != 6 || f[5] !~ /^u(16|32)$/)) tdie("bad consts record")
            if (cur != "" || (f[3] != "pub" && f[3] != "priv")) tdie("bad " f[1] " record")
            check_name(f[2], f[1] " key")
            for (i = 1; i <= nenum; i++)
                if (e_region[i] == f[1] " " f[2]) tdie(f[1] " " f[2] " twice")
            nenum++; e_key[nenum] = f[2]; e_pub[nenum] = (f[3] == "pub"); e_zig[nenum] = f[4]
            e_tag[nenum] = f[5]; e_cprefix[nenum] = f[6]; e_cmax[nenum] = (f[1] == "enum" ? f[7] : "-")
            e_desc[nenum] = desc; e_const[nenum] = (f[1] == "consts"); e_region[nenum] = f[1] " " f[2]
            e_nval[nenum] = 0; cur = "enum"
        } else if (f[1] == "value") {
            if (nf != 4 || cur != "enum" || f[2] !~ /^[0-9]+$/) tdie("bad value record")
            check_name(f[4], "value")
            p = ++e_nval[nenum]
            ev_code[nenum, p] = f[2]; ev_c[nenum, p] = f[3]; ev_zig[nenum, p] = f[4]; ev_desc[nenum, p] = desc
        } else if (f[1] == "end") {
            if (nf != 1 || cur == "") tdie("end without a block")
            cur = ""
        } else if (f[1] == "kind") {
            if (nf != 5 || cur != "" || f[2] !~ /^[0-9]+$/ || (f[5] != "-" && f[5] != "K" && f[5] != "KT")) tdie("bad kind record")
            if (f[2] + 0 != nkind) tdie("kind codes must be 0, 1, 2, ... in order")
            check_name(f[4], "kind")
            nkind++; k_code[nkind] = f[2]; k_c[nkind] = f[3]; k_zig[nkind] = f[4]; k_set[nkind] = f[5]
            k_desc[nkind] = desc
        } else if (f[1] == "typedoc") {
            if (nf != 2 || desc == "" || f[2] !~ /^[0-9]+$/ || f[2] + 0 >= nkind) tdie("bad typedoc record (after its kind)")
            k_tdesc[f[2] + 1] = desc
        } else if (f[1] == "import") {
            if (nf < 3 || cur != "") tdie("bad import record")
            check_name(f[2], "import")
            if (f[3] != "void" && !is_int(f[3])) tdie("bad return type '" f[3] "'")
            nimport++; i_name[nimport] = f[2]; i_ret[nimport] = f[3]; i_desc[nimport] = desc
            i_np[nimport] = read_params(f, nf, nimport, ip_name, ip_type, 0)
        } else if (f[1] == "export") {
            if (nf < 3 || cur != "") tdie("bad export record")
            check_name(f[2], "export")
            if (!is_int(f[3])) tdie("bad export return type '" f[3] "' (one result)")
            nexport++; x_name[nexport] = f[2]; x_ret[nexport] = f[3]; x_desc[nexport] = desc
            x_np[nexport] = read_params(f, nf, nexport, xp_name, xp_type, 1)
            if (x_np[nexport] > 4) tdie("more than 4 parameters (src/plzig_runtime.c, plzig_lookup)")
        } else {
            tdie("unknown record '" f[1] "'")
        }
    }
    close(table)
    if (tline == 0) die("cannot read " table)
    if (cur != "") tdie("block not closed")
    if (version == "") die(table ": no version")
    for (i = 1; i <= nimport; i++)
        for (p = 1; p < i; p++)
            if (i_name[i] == i_name[p]) die(table ": import " i_name[i] " twice")
    for (i = 1; i <= nexport; i++)
        for (p = 1; p < i; p++)
            if (x_name[i] == x_name[p]) die(table ": export " x_name[i] " twice")
}

# --- helpers -----------------------------------------------------------------

# the words of text as comment lines of at most width columns, each starting
# with prefix, joined by "\n"
function wrap(text, prefix, width,    w, n, i, out, cur) {
    n = split(text, w, / +/)
    out = ""; cur = ""
    for (i = 1; i <= n; i++) {
        if (cur != "" && length(prefix cur " " w[i]) > width) {
            out = out (out == "" ? "" : "\n") prefix cur; cur = w[i]
        } else cur = (cur == "" ? w[i] : cur " " w[i])
    }
    if (cur != "") out = out (out == "" ? "" : "\n") prefix cur
    return out
}

function c_type(t) {
    if (t ~ /^(in|out|ref)\(/) return "uint32"
    if (t == "void") return "void"
    return (substr(t, 1, 1) == "u" ? "uint" : "int") substr(t, 2)
}

function zig_type(t,    inner) {
    if (t ~ /^in\(/) { inner = substr(t, 4, length(t) - 4); return "[*]const " inner }
    if (t ~ /^out\(/) { inner = substr(t, 5, length(t) - 5); return "[*]" inner }
    if (t ~ /^ref\(/) { inner = substr(t, 5, length(t) - 5); return "*" inner }
    return t
}

function wasm_char(t) { return (t ~ /64$/) ? "I" : "i" }

function size_of(t) { return substr(t, 2) / 8 }

function signature(i,    p, sig) {
    sig = "("
    for (p = 1; p <= i_np[i]; p++) sig = sig wasm_char(ip_type[i, p])
    sig = sig ")"
    if (i_ret[i] != "void") sig = sig wasm_char(i_ret[i])
    return sig
}

# an export's WAMR-style signature string, and as doc/abi.md writes it
function x_signature(i,    p, sig) {
    sig = "("
    for (p = 1; p <= x_np[i]; p++) sig = sig wasm_char(xp_type[i, p])
    return sig ")" wasm_char(x_ret[i])
}

function wasm_type(t) { return (t ~ /64$/) ? "i64" : "i32" }

function x_docsig(i,    p, sig) {
    sig = "("
    for (p = 1; p <= x_np[i]; p++) sig = sig (p > 1 ? ", " : "") xp_name[i, p] ": " wasm_type(xp_type[i, p])
    return sig ") -> " wasm_type(x_ret[i])
}

# struct layout: offsets by natural alignment; s_size[s] the total size
function layout(s,    p, off, sz, al) {
    off = 0; al = 1
    for (p = 1; p <= s_nfield[s]; p++) {
        sz = size_of(sf_type[s, p])
        if (off % sz) off += sz - off % sz
        sf_off[s, p] = off
        off += sz
        if (sz > al) al = sz
    }
    if (off % al) off += al - off % al
    s_size[s] = off
}

# text padded with tabs (4 columns wide) to column col, or with one blank if
# it already reaches it
function c_tabs(text, col,    n, i, c, t) {
    n = 0
    for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (c == "\t") n = n - n % 4 + 4; else n++
    }
    t = text
    if (n >= col) return t " "
    while (n < col) { t = t "\t"; n = n - n % 4 + 4 }
    return t
}

# --- C header ------------------------------------------------------------------

function gen_c(    s, p, k, e, i, line, params, maxcode) {
    print "/*-------------------------------------------------------------------------"
    print " *"
    print " * plzig_abi.h"
    print " *\t  PL/Zig host/guest ABI definitions shared with the guest SDK."
    print " *"
    print " * GENERATED from abi/plzig-abi.table by abi/gen-abi.sh: do not edit."
    print " * Edit the table and run `make abi`; `make check-abi` (part of every"
    print " * build) fails while this file is not what the table generates.  The"
    print " * same table generates the marked regions of zig/sdk/plzig.zig."
    print " *"
    print " *-------------------------------------------------------------------------"
    print " */"
    print "#ifndef PLZIG_ABI_H"
    print "#define PLZIG_ABI_H"
    print ""
    print "/* host/guest ABI version (doc/abi.md), independent of the release version */"
    print "#define PLZIG_ABI_VERSION\t\t" version
    for (s = 1; s <= nstruct; s++) {
        layout(s)
        print ""
        if (s_desc[s] != "") {
            print "/*"
            print wrap(s_desc[s], " * ", 77)
            print " */"
        }
        print "typedef struct " s_c[s]
        print "{"
        for (p = 1; p <= s_nfield[s]; p++) {
            line = c_tabs("\t" c_type(sf_type[s, p]), 16) sf_name[s, p] ";"
            if (sf_desc[s, p] != "") line = c_tabs(line, 32) "/* " sf_desc[s, p] " */"
            print line
        }
        print "} " s_c[s] ";"
        print "StaticAssertDecl(sizeof(" s_c[s] ") == " s_size[s] ", \"" s_c[s] ": size\");"
        for (p = 1; p <= s_nfield[s]; p++)
            print "StaticAssertDecl(offsetof(" s_c[s] ", " sf_name[s, p] ") == " sf_off[s, p] ", \"" s_c[s] "." sf_name[s, p] ": offset\");"
    }
    print ""
    print "/*"
    print " * Value kinds (doc/abi.md, \"Kinds\"): the kind of a result column is"
    print " * derived by the host from the tuple descriptor; the kind of a"
    print " * prepared-statement parameter is chosen by the guest at prepare time and"
    print " * mapped to a fixed type OID by the host."
    print " */"
    maxcode = 0
    for (k = 1; k <= nkind; k++) {
        line = c_tabs("#define PLZIG_KIND_" k_c[k], 32) k_code[k]
        if (k_desc[k] != "") line = c_tabs(line, 36) "/* " k_desc[k] " */"
        print line
        if (k_code[k] + 0 > maxcode) maxcode = k_code[k] + 0
    }
    print c_tabs("#define PLZIG_KIND_MAX", 32) maxcode
    for (e = 1; e <= nenum; e++) {
        print ""
        if (e_desc[e] != "" && length("/* " e_desc[e] " */") <= 79) print "/* " e_desc[e] " */"
        else if (e_desc[e] != "") { print "/*"; print wrap(e_desc[e], " * ", 77); print " */" }
        maxcode = 0
        for (p = 1; p <= e_nval[e]; p++) {
            line = c_tabs("#define " e_cprefix[e] ev_c[e, p], 32) ev_code[e, p]
            if (ev_desc[e, p] != "") line = c_tabs(line, 36) "/* " ev_desc[e, p] " */"
            print line
            if (ev_code[e, p] + 0 > maxcode) maxcode = ev_code[e, p] + 0
        }
        if (e_cmax[e] != "-") print c_tabs("#define " e_cmax[e], 32) maxcode
    }
    print ""
    print "/*"
    print " * The host imports (module \"plzig\", doc/abi.md \"Host imports\"), in the"
    print " * order of the registration table, as an X macro:"
    print " *"
    print " *   X(name, WAMR signature string, C return type, (C parameter list))"
    print " *"
    print " * The parameter list is that of the native function WAMR calls (its first"
    print " * parameter is the exec env; every guest pointer is a uint32).  Only code"
    print " * that includes wasm_export.h can expand it."
    print " */"
    print c_tabs("#define PLZIG_HOST_IMPORT_COUNT", 32) nimport
    print "#define PLZIG_HOST_IMPORTS(X) \\"
    for (i = 1; i <= nimport; i++) {
        params = "wasm_exec_env_t env"
        for (p = 1; p <= i_np[i]; p++) params = params ", " c_type(ip_type[i, p]) " " ip_name[i, p]
        print "\tX(" i_name[i] ", \"" signature(i) "\", " c_type(i_ret[i]) ", (" params "))" (i < nimport ? " \\" : "")
    }
    print ""
    print "/*"
    print " * The guest exports (doc/abi.md \"Guest exports\"): the WAMR-style signature"
    print " * string of each (the parameter and result types the host requires when"
    print " * it looks the export up), and the list, in the order of the linker's"
    print " * --export flags, as an X macro: X(name, signature string)"
    print " */"
    for (i = 1; i <= nexport; i++) {
        line = c_tabs("#define PLZIG_EXPORT_SIG_" x_name[i], 44) "\"" x_signature(i) "\""
        if (x_desc[i] != "") line = c_tabs(line, 56) "/* " x_desc[i] " */"
        print line
    }
    print c_tabs("#define PLZIG_GUEST_EXPORT_COUNT", 32) nexport
    print "#define PLZIG_GUEST_EXPORTS(X) \\"
    for (i = 1; i <= nexport; i++)
        print "\tX(" x_name[i] ", PLZIG_EXPORT_SIG_" x_name[i] ")" (i < nexport ? " \\" : "")
    print ""
    print "#endif\t\t\t\t\t\t\t/* PLZIG_ABI_H */"
}

# --- Zig regions -------------------------------------------------------------

function zdoc(text) { if (text != "") emit(wrap(text, "/// ", 80)) }

# collect generated lines (in region-relative indentation)
function emit(text,    n, i, l) {
    if (text == "") { out[++nout] = ""; return }
    n = split(text, l, "\n")
    for (i = 1; i <= n; i++) out[++nout] = l[i]
}

function zig_region(what,    s, p, k, e, i, line, params, sep, found) {
    nout = 0
    if (what == "version") {
        zdoc("ABI version implemented by this SDK. Checked by the host at load time.")
        emit("pub const abi_version: u32 = " version ";")
    } else if (what == "imports") {
        emit("const host = struct {")
        for (i = 1; i <= nimport; i++) {
            params = ""
            for (p = 1; p <= i_np[i]; p++) params = params (p > 1 ? ", " : "") ip_name[i, p] ": " zig_type(ip_type[i, p])
            emit("    extern \"plzig\" fn " i_name[i] "(" params ") " zig_type(i_ret[i]) ";")
        }
        emit("};")
    } else if (what == "import-types") {
        zdoc("The host imports' function types.  The native unit tests' stand-in host (zig/sdk/test_env.zig) must declare every import with exactly this type: checked when the SDK is compiled by `zig test`.")
        emit("const host_import_types = .{")
        for (i = 1; i <= nimport; i++) {
            params = ""
            for (p = 1; p <= i_np[i]; p++) params = params (p > 1 ? ", " : "") zig_type(ip_type[i, p])
            emit("    .{ \"" i_name[i] "\", fn (" params ") " zig_type(i_ret[i]) " },")
        }
        emit("};")
        emit("comptime {")
        emit("    if (@import(\"builtin\").is_test) {")
        emit("        for (host_import_types) |t| {")
        emit("            if (@TypeOf(@field(host, t[0])) != t[1])")
        emit("                @compileError(\"host import \" ++ t[0] ++ \": the stand-in's type is not the one of abi/plzig-abi.table\");")
        emit("        }")
        emit("    }")
        emit("}")
    } else if (what == "structs") {
        for (s = 1; s <= nstruct; s++) {
            layout(s)
            if (s > 1) emit("")
            zdoc(s_desc[s])
            emit((s_pub[s] ? "pub " : "") "const " s_zig[s] " = extern struct {")
            for (p = 1; p <= s_nfield[s]; p++) {
                if (sf_desc[s, p] != "") emit(wrap(sf_desc[s, p], "    /// ", 80))
                emit("    " sf_name[s, p] ": " sf_type[s, p] ",")
            }
            emit("")
            emit("    comptime {")
            line = "@sizeOf(" s_zig[s] ") != " s_size[s]
            for (p = 1; p <= s_nfield[s]; p++) line = line " or @offsetOf(" s_zig[s] ", \"" sf_name[s, p] "\") != " sf_off[s, p]
            emit("        if (" line ")")
            emit("            @compileError(\"" s_zig[s] ": layout differs from abi/plzig-abi.table\");")
            emit("    }")
            emit("};")
        }
    } else if (what == "kinds") {
        zdoc("Kind of a result column, derived by the host from the column's type.")
        emit("pub const Kind = enum(u16) {")
        for (k = 1; k <= nkind; k++) {
            if (k_set[k] !~ /K/) continue
            if (k_desc[k] != "") emit(wrap(k_desc[k], "    /// ", 80))
            emit("    " k_zig[k] " = " k_code[k] ",")
        }
        emit("    _,")
        emit("};")
        emit("")
        zdoc("Parameter types of prepared statements.")
        emit("pub const Type = enum(u32) {")
        for (k = 1; k <= nkind; k++) {
            if (k_set[k] !~ /T/) continue
            if (k_tdesc[k] != "") emit(wrap(k_tdesc[k], "    /// ", 80))
            emit("    " k_zig[k] " = " k_code[k] ",")
        }
        emit("    /// other values are rejected by the host")
        emit("    _,")
        emit("};")
    } else if (what ~ /^(enum|consts) /) {
        found = 0
        for (e = 1; e <= nenum; e++) if (e_region[e] == what) found = e
        if (!found) return 0
        e = found
        zdoc(e_desc[e])
        emit((e_pub[e] ? "pub " : "") "const " e_zig[e] " = " (e_const[e] ? "struct" : "enum(" e_tag[e] ")") " {")
        for (p = 1; p <= e_nval[e]; p++) {
            if (ev_desc[e, p] != "") emit(wrap(ev_desc[e, p], "    /// ", 80))
            if (e_const[e]) emit("    pub const " ev_zig[e, p] ": " e_tag[e] " = " ev_code[e, p] ";")
            else emit("    " ev_zig[e, p] " = " ev_code[e, p] ",")
        }
        emit("};")
    } else if (what == "exports") {
        zdoc("The guest exports (zig/sdk/root.zig, which checks at compile time that its entry points have exactly these types; the host builds the linker's --export flags and its lookups from the same table).")
        emit("pub const guest_export_types = .{")
        for (i = 1; i <= nexport; i++) {
            params = ""
            for (p = 1; p <= x_np[i]; p++) params = params (p > 1 ? ", " : "") zig_type(xp_type[i, p])
            emit("    .{ \"" x_name[i] "\", fn (" params ") callconv(.c) " zig_type(x_ret[i]) " },")
        }
        emit("};")
    } else return 0
    return 1
}

# --- doc/abi.md --------------------------------------------------------------

# The rows of the import table ("## Host imports") and of the export table
# ("## Guest exports"): a table row whose second cell is a signature.  Each
# import and export needs its row; a row for a name the table does not have
# is an error too.
function doc_line(line,    i, n, nm, known) {
    if (line ~ /^## /) section = line
    for (i = 1; i <= nimport; i++)
        if (index(line, "| `" i_name[i] "(") == 1 && index(line, " | `" signature(i) "` | ") > 0)
            doc_row[i] = 1
    for (i = 1; i <= nexport; i++)
        if (index(line, "| `" x_name[i] "` | `" x_docsig(i) "` | ") == 1)
            doc_xrow[i] = 1
    if (index(line, nimport " imports, the complete list") > 0) doc_count = 1
    if (index(section, "## Host imports") == 1 && line ~ /^\| `[^`]*` \| `\([iIfF]*\)[iIfF]?` \|/) {
        nm = substr(line, 4); sub(/[(`].*$/, "", nm)
        known = 0
        for (i = 1; i <= nimport; i++) if (i_name[i] == nm) known = 1
        if (!known) doc_extra[++ndoc_extra] = FNR ": a row for \"" nm "\", which is not an import of the table"
    }
    if (index(section, "## Guest exports") == 1 && line ~ /^\| `[^`]*` \| `\(/) {
        nm = substr(line, 4); sub(/[(`].*$/, "", nm)
        known = 0
        for (i = 1; i <= nexport; i++) if (x_name[i] == nm) known = 1
        if (!known) doc_extra[++ndoc_extra] = FNR ": a row for \"" nm "\", which is not an export of the table"
    }
}

# --- main --------------------------------------------------------------------

BEGIN {
    if (table == "") die("usage: awk -v table=<file> -v mode=c|zig|doc -f gen-abi.awk [file]")
    read_table()
    if (mode == "c") { gen_c(); exit 0 }
    if (mode != "zig" && mode != "doc") die("unknown mode '" mode "'")
    want["version"] = 1; want["imports"] = 1; want["import-types"] = 1
    want["structs"] = 1; want["kinds"] = 1; want["exports"] = 1
    for (e = 1; e <= nenum; e++) want[e_region[e]] = 1
    inregion = 0
}

mode == "doc" { doc_line($0); next }

# mode zig
inregion {
    if ($0 ~ /^[ \t]*\/\/ @plzig-abi end[ \t]*$/) {
        inregion = 0
        print $0
    } else if ($0 ~ /\/\/ @plzig-abi /) die(FILENAME ":" FNR ": marker inside the region begun at line " rstart)
    next
}
/\/\/ @plzig-abi / {
    if ($0 ~ /\/\/ @plzig-abi end/) die(FILENAME ":" FNR ": region end without a begin")
    if ($0 !~ /^[ \t]*\/\/ @plzig-abi begin [a-z_ -]+( -- .*)?$/) die(FILENAME ":" FNR ": malformed marker")
    indent = $0; sub(/\/\/.*$/, "", indent)
    what = $0; sub(/^[ \t]*\/\/ @plzig-abi begin /, "", what); sub(/ -- .*$/, "", what); sub(/[ \t]+$/, "", what)
    if (!(what in want)) die(FILENAME ":" FNR ": unknown region '" what "'")
    if (what in done) die(FILENAME ":" FNR ": region '" what "' twice")
    done[what] = 1
    if (!zig_region(what)) die("no generator for region '" what "'")
    print indent "// @plzig-abi begin " what " -- generated from abi/plzig-abi.table (make abi), do not edit"
    for (i = 1; i <= nout; i++) print (out[i] == "" ? "" : indent out[i])
    inregion = 1; rstart = FNR
    next
}
{ print }

END {
    if (failed) exit failed
    if (mode == "zig") {
        if (inregion) die(FILENAME ": region begun at line " rstart " is not closed")
        for (w in want) if (!(w in done)) die(FILENAME ": region '" w "' is missing")
    }
    if (mode == "doc") {
        bad = 0
        for (i = 1; i <= nimport; i++)
            if (!doc_row[i]) {
                print "doc/abi.md: no row \"| `" i_name[i] "(...)` | `" signature(i) "` | ...\" in the import table"
                bad = 1
            }
        for (i = 1; i <= nexport; i++)
            if (!doc_xrow[i]) {
                print "doc/abi.md: no row \"| `" x_name[i] "` | `" x_docsig(i) "` | ...\" in the export table"
                bad = 1
            }
        if (!doc_count) { print "doc/abi.md: does not say \"" nimport " imports, the complete list\""; bad = 1 }
        for (i = 1; i <= ndoc_extra; i++) { print "doc/abi.md:" doc_extra[i]; bad = 1 }
        exit bad
    }
}
