#!/usr/bin/env python3
"""Write an SPDX 2.3 (JSON) software bill of materials for a release
directory (doc/packaging.md "Release artefacts").

    python3 -I packaging/release/sbom.py <release dir> <source tree>

<source tree> is the unpacked source tarball (or the checkout it was made
from); versions, pins and the WAMR commit are read from it
(packaging/versions.sh).  Every *.tar.gz source tarball, *.rpm and *.deb in
<release dir> (recursively) becomes an SPDX package with its SHA-256; the
upstream inputs (WAMR, the official Zig builds) are listed with their pinned
checksums; relationships say what is built from, linked into or depends on
what.  Deterministic: the creation time is SOURCE_DATE_EPOCH (else the source
tree's Makefile mtime) and the document namespace is derived from the
source tarball's checksum.  Writes <release dir>/plzig-<version>.spdx.json.
Standard library only.
"""
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid

PLZIG_LICENSE = "PostgreSQL AND Apache-2.0 WITH LLVM-exception AND MIT"
ZIG_LICENSE = "MIT AND Apache-2.0 WITH LLVM-exception AND NCSA AND Zlib AND BSD-3-Clause"
SUPPLIER = "Organization: PL/Zig maintainers (plzig@invalid)"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def spdx_id(text):
    return "SPDXRef-" + re.sub(r"[^A-Za-z0-9.-]", "-", text)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    reldir, tree = sys.argv[1], sys.argv[2]
    out = subprocess.run(["sh", os.path.join(tree, "packaging", "versions.sh"), tree],
                         check=True, capture_output=True, text=True).stdout
    v = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or os.stat(os.path.join(tree, "Makefile")).st_mtime)
    created = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    files = []
    for root, _, names in os.walk(reldir):
        for n in sorted(names):
            if n.endswith((".tar.gz", ".rpm", ".deb")):
                files.append(os.path.join(root, n))
    files.sort(key=lambda p: os.path.relpath(p, reldir))
    src = [f for f in files if re.match(r"plzig-\d.*\.tar\.gz$", os.path.basename(f))]
    if len(src) != 1:
        sys.exit("sbom.py: expected exactly one plzig-<version>.tar.gz in %s, found %d" % (reldir, len(src)))
    src_sha = sha256(src[0])

    packages, rels = [], []
    src_id = "SPDXRef-plzig-source"
    packages.append({
        "SPDXID": src_id, "name": "plzig", "versionInfo": v["DIST_VERSION"],
        "packageFileName": os.path.basename(src[0]), "supplier": SUPPLIER,
        "downloadLocation": "NOASSERTION", "filesAnalyzed": False,
        "checksums": [{"algorithm": "SHA256", "checksumValue": src_sha}],
        "licenseConcluded": "PostgreSQL", "licenseDeclared": "PostgreSQL",
        "copyrightText": "NOASSERTION", "primaryPackagePurpose": "SOURCE",
        "comment": "PL/Zig source tarball (make dist). SQL extension version %s, "
                   "host/guest ABI version %s, Zig pin %s." % (v["EXT_VERSION"], v["ABI_VERSION"], v["ZIG_VERSION"]),
    })
    wamr_id = "SPDXRef-wamr"
    packages.append({
        "SPDXID": wamr_id, "name": "wasm-micro-runtime", "versionInfo": v["WAMR_VERSION"],
        "packageFileName": "WAMR-%s.tar.gz" % v["WAMR_VERSION"],
        "supplier": "Organization: Bytecode Alliance",
        "downloadLocation": "git+https://github.com/bytecodealliance/wasm-micro-runtime@%s" % v["WAMR_COMMIT"],
        "filesAnalyzed": False,
        "checksums": [{"algorithm": "SHA256", "checksumValue": v["WAMR_TARBALL_SHA256"]}],
        "licenseConcluded": "Apache-2.0 WITH LLVM-exception", "licenseDeclared": "Apache-2.0 WITH LLVM-exception",
        "copyrightText": "NOASSERTION", "primaryPackagePurpose": "LIBRARY",
        "externalRefs": [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                          "referenceLocator": "pkg:github/bytecodealliance/wasm-micro-runtime@WAMR-%s" % v["WAMR_VERSION"]}],
        "comment": "Statically linked into plzig.so (classic interpreter only), with PL/Zig's patch "
                   "third_party/wamr-interrupt.patch; the checksum is the tag's source tarball's.",
    })
    zig_ids = {}
    for arch in ("x86_64", "aarch64"):
        zid = "SPDXRef-zig-%s" % arch
        zig_ids[arch] = zid
        name = "zig-%s-linux-%s.tar.xz" % (arch, v["ZIG_VERSION"])
        packages.append({
            "SPDXID": zid, "name": "zig", "versionInfo": v["ZIG_VERSION"], "packageFileName": name,
            "supplier": "Organization: Zig Software Foundation",
            "downloadLocation": "https://ziglang.org/download/%s/%s" % (v["ZIG_VERSION"], name),
            "filesAnalyzed": False,
            "checksums": [{"algorithm": "SHA256", "checksumValue": v["ZIG_SHA256_" + arch]}],
            "licenseConcluded": ZIG_LICENSE, "licenseDeclared": "MIT",
            "copyrightText": "NOASSERTION", "primaryPackagePurpose": "APPLICATION",
            "comment": "Official Zig build (statically linked; contains LLVM, Clang, LLD, zlib, zstd, musl). "
                       "Builds plzig-validate; repackaged, with lib/ pruned, as plzig-zig-toolchain.",
        })

    toolchain_ids = {}   # (directory, format) -> SPDX ids of toolchain binary packages
    for f in files:
        base = os.path.basename(f)
        if f == src[0] or not base.endswith((".rpm", ".deb")):
            continue
        pid = spdx_id(base)
        is_tc = base.startswith("plzig-zig-toolchain")
        is_srpm = base.endswith(".src.rpm")
        is_debug = "debuginfo" in base or "debugsource" in base or "-dbgsym" in base
        m = re.match(r"(.+?)[-_](\d[^_]*?)(?:[._](?:x86_64|aarch64|amd64|arm64|src|noarch))?\.(?:rpm|deb)$", base)
        pkgname, version = (m.group(1), m.group(2)) if m else (base, "NOASSERTION")
        packages.append({
            "SPDXID": pid, "name": pkgname, "versionInfo": version, "packageFileName": base,
            "supplier": SUPPLIER, "downloadLocation": "NOASSERTION", "filesAnalyzed": False,
            "checksums": [{"algorithm": "SHA256", "checksumValue": sha256(f)}],
            "licenseConcluded": ZIG_LICENSE if is_tc else PLZIG_LICENSE,
            "licenseDeclared": ZIG_LICENSE if is_tc else PLZIG_LICENSE,
            "copyrightText": "NOASSERTION",
            "primaryPackagePurpose": "SOURCE" if is_srpm else ("APPLICATION" if is_tc else "LIBRARY"),
            "comment": os.path.relpath(f, reldir),
        })
        arch = "aarch64" if ("aarch64" in base or "arm64" in base) else "x86_64"
        group = (os.path.dirname(f), os.path.splitext(base)[1])
        if is_tc:
            if not is_srpm:
                toolchain_ids.setdefault(group, []).append(pid)
            for a, zid in zig_ids.items():
                if is_srpm or a == arch:
                    rels.append((pid, "GENERATED_FROM", zid))
        else:
            rels.append((pid, "GENERATED_FROM", src_id))
            if not is_srpm:
                rels.append((zig_ids[arch], "BUILD_TOOL_OF", pid))
            if not is_srpm and not is_debug:
                rels.append((pid, "STATIC_LINK", wamr_id))
                rels.append((pid, "DEPENDS_ON", ("TOOLCHAIN", group)))
    resolved = []
    for a, rel, b in rels:
        if isinstance(b, tuple):
            resolved += [(a, rel, t) for t in toolchain_ids.get(b[1], [])]
        else:
            resolved.append((a, rel, b))

    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "plzig-%s" % v["DIST_VERSION"],
        "documentNamespace": "urn:uuid:%s" % uuid.uuid5(uuid.NAMESPACE_URL, "plzig-sbom:" + src_sha),
        "creationInfo": {"created": created,
                         "creators": ["Tool: plzig-packaging-release-sbom.py", SUPPLIER]},
        "documentDescribes": [p["SPDXID"] for p in packages
                              if p["SPDXID"] not in (wamr_id,) + tuple(zig_ids.values())],
        "packages": packages,
        "relationships": [{"spdxElementId": a, "relationshipType": r, "relatedSpdxElement": b}
                          for a, r, b in resolved],
    }
    path = os.path.join(reldir, "plzig-%s.spdx.json" % v["DIST_VERSION"])
    with open(path, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    print("%s: %d packages, %d relationships" % (path, len(packages), len(resolved)))


if __name__ == "__main__":
    main()
