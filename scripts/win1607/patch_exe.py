#!/usr/bin/env python3
"""Patch a Bun-compiled cyberstrike.exe so it runs on Windows 10 1607 / Server 2016 (build 14393).

Why: Bun's Windows binaries statically import kernel32!GetThreadDescription (a
Windows 10 1703+ export). On 1607 the loader fails import resolution at load
time -> exit code -1073741511 (0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND) before
any code runs. Bun's only call site is the crash handler (src/crash_handler/
lib.rs), guarded by an S_OK check, so redirecting the import to a stub that
returns a failing HRESULT is safe even if it is ever called.

How: rewrite the import name string IN PLACE inside the exe's import name
table. No RVAs shift, no IAT entries move, file size unchanged. The 2-byte
hint is left as-is (hints are best-effort; the loader falls back to binary
search on mismatch). Duplicate import names in one DLL are legal.

Modes:
  analyze <exe>              dump every (dll, function) import
  check   <exe> [cachedir]   diff imports against real Win10 1607 (14393)
                            export sets fetched from winbindex + Microsoft
                            symbol server; prints what's missing on the box
  patch   <in> <out>         apply REDIRECTS to a copy of the exe and recompute
                            the PE checksum

Usage on a new upstream release: run `check` first; if new missing imports
appear, add them to REDIRECTS (replacement must exist in the same DLL on 14393,
fit in the original string slot, and be safe-if-called), then `patch`.

Requires: python3 + pefile (pip install pefile). Stdlib otherwise.
"""

import gzip
import io
import json
import os
import struct
import sys
import urllib.request

import pefile

# import name -> same-DLL replacement. Constraints (see module docstring):
#   - exists in 14393 kernel32 exports
#   - len(replacement) <= len(original)
#   - safe if actually called
REDIRECTS = {
    # 1703+ export, crash-handler-only call site. GetCurrentThread ignores both
    # args, writes nothing, returns 0xFFFFFFFE (nonzero => failing HRESULT) so
    # Bun's guarded deref skips the thread name.
    "GetThreadDescription": "GetCurrentThread",
}

# Real 1607 system DLLs to diff against (imports map to these on 14393).
# api-ms-win-core-synch-l1-2-0 resolves to kernelbase.
APISET_MAP = {"api-ms-win-core-synch-l1-2-0.dll": "kernelbase"}
GROUND_TRUTH_DLLS = ["kernel32", "ntdll", "shell32", "userenv", "user32", "kernelbase"]

WINBINDEX_URL = ("https://raw.githubusercontent.com/m417z/winbindex/gh-pages/"
                 "data/by_filename_compressed/{}.dll.json.gz")
MSDL_URL = "https://msdl.microsoft.com/download/symbols/{dll}.dll/{key}/{dll}.dll"


def load_imports(path):
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(
        directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]])
    result = {}
    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        dll = entry.dll.decode().lower()
        result[dll] = [i.name.decode() if i.name else "#%d" % i.ordinal
                       for i in entry.imports]
    return result


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "win1607-patch/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def msdl_key(entry):
    # winbindex keys msdl by PE TimeDateStamp (8 uppercase hex) + SizeOfImage
    # (lowercase hex). fileInfo.timestamp/virtualSize carry exactly those.
    fi = entry["fileInfo"]
    return "%08X%x" % (fi["timestamp"], fi["virtualSize"])


def get_14393_exports(cachedir):
    """Download real Win10 1607 (10.0.14393.*) amd64 DLLs and enumerate exports."""
    os.makedirs(cachedir, exist_ok=True)
    exports = {}
    for dll in GROUND_TRUTH_DLLS:
        path = os.path.join(cachedir, dll + ".dll")
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            data = json.loads(gzip.decompress(fetch(WINBINDEX_URL.format(dll))))
            best = None
            for entry in data.values():
                fi = entry.get("fileInfo", {})
                if not fi.get("version", "").startswith("10.0.14393"):
                    continue
                if fi.get("machineType") != 34404:  # amd64
                    continue
                if best is None or fi["version"] > best[0]["version"]:
                    best = (fi,)
            if not best:
                sys.exit("no 14393 amd64 entry found for %s.dll" % dll)
            blob = fetch(MSDL_URL.format(dll=dll, key=msdl_key({"fileInfo": best[0]})))
            with open(path, "wb") as f:
                f.write(blob)
        pe = pefile.PE(path, fast_load=True)
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"]])
        exports[dll] = {s.name.decode() for s in pe.DIRECTORY_ENTRY_EXPORT.symbols
                        if s.name}
    return exports


def check(exe, cachedir):
    imports = load_imports(exe)
    exports = get_14393_exports(cachedir)
    missing = []
    for dll, fns in imports.items():
        target = APISET_MAP.get(dll, dll.replace(".dll", ""))
        if target not in exports:
            print("WARN: no ground-truth export set for %s" % dll)
            continue
        for fn in fns:
            if fn not in exports[target]:
                missing.append((dll, target, fn))
    print("imports checked: %d across %d DLLs" % (
        sum(len(v) for v in imports.values()), len(imports)))
    if not missing:
        print("OK: every import resolves on Windows 10 1607 (14393)")
    else:
        print("MISSING ON 14393: %d" % len(missing))
        for dll, target, fn in missing:
            print("  %s -> %s!%s" % (dll, target, fn))
    return missing


def pe_checksum(data, field_offset):
    # Standard PE checksum: one's-complement 16-bit sum (checksum field zeroed)
    # + file length.
    buf = data[:field_offset] + b"\x00\x00\x00\x00" + data[field_offset + 4:]
    if len(buf) & 1:
        buf += b"\x00"
    s = 0
    for i in range(0, len(buf), 2):
        s += buf[i] | (buf[i + 1] << 8)
        s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (s + len(data)) & 0xFFFFFFFF


def patch(in_path, out_path):
    data = bytearray(open(in_path, "rb").read())
    pe = pefile.PE(data=bytes(data), fast_load=True)
    pe.parse_data_directories(
        directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]])

    cksum_off = pe.DOS_HEADER.e_lfanew + 24 + 64  # PE32+ OptionalHeader.CheckSum
    applied = []

    for entry in pe.DIRECTORY_ENTRY_IMPORT:
        dll = entry.dll.decode().lower()
        # Walk the OriginalFirstThunk (loader's name source); fall back to FT.
        oft = entry.struct.OriginalFirstThunk or entry.struct.FirstThunk
        idx = 0
        while True:
            off = pe.get_offset_from_rva(oft + 8 * idx)
            (thunk,) = struct.unpack_from("<Q", data, off)
            if thunk == 0:
                break
            idx += 1
            if thunk & (1 << 63):  # ordinal import
                continue
            name_off = pe.get_offset_from_rva(thunk & 0x7FFFFFFF)
            # IMAGE_IMPORT_BY_NAME: 2-byte hint, then NUL-terminated name.
            end = data.index(b"\x00", name_off + 2, name_off + 2 + 64)
            name = bytes(data[name_off + 2:end]).decode()
            if name not in REDIRECTS:
                continue
            repl = REDIRECTS[name]
            slot = name_off + 2
            span = len(name) + 1  # original name + NUL, stays in-bounds
            assert len(repl) + 1 <= span, "replacement longer than slot"
            data[slot:slot + span] = repl.encode() + b"\x00" * (span - len(repl))
            applied.append((dll, name, repl, slot))

    if not applied:
        sys.exit("no REDIRECTS matched this exe's imports - nothing to patch")

    struct.pack_into("<I", data, cksum_off, pe_checksum(bytes(data), cksum_off))

    with open(out_path, "wb") as f:
        f.write(data)
    for dll, name, repl, slot in applied:
        print("patched %s!%s -> %s (name slot at file offset 0x%X)" % (dll, name, repl, slot))
    print("PE checksum recomputed; size unchanged: %d bytes" % len(data))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    mode = sys.argv[1]
    if mode == "analyze":
        for dll, fns in load_imports(sys.argv[2]).items():
            for fn in fns:
                print("%s\t%s" % (dll, fn))
    elif mode == "check":
        cache = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "dlls-14393-cache")
        check(sys.argv[2], cache)
    elif mode == "patch" and len(sys.argv) == 4:
        patch(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
