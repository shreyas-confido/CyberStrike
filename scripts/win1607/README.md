# win1607 compat — hotpatch cyberstrike.exe for Windows 10 1607 / Server 2016

Makes the stock Bun-compiled `cyberstrike.exe` run on Windows 10 1607 / Server
2016 (build 14393, no AVX2 needed via the `-baseline` flavor) without
rebuilding Bun.

## Why (v1.1.16 findings, 2026-09-14)

The stock exe dies at launch with exit `-1073741511`
(`0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND`). Full import diff of all 358
imports against **real 1607 (10.0.14393) system DLLs** fetched from
Microsoft's symbol server (via winbindex) found exactly **one** missing
import:

| DLL | Function | Introduced | Bun call site | Verdict |
|---|---|---|---|---|
| kernel32 | `GetThreadDescription` | Win10 1703 | crash handler only (`src/crash_handler/lib.rs` in oven-sh/bun) | cold path |

Bun's only call site is the crash handler, guarded by an
`HRESULT_CODE(result) == S_OK && *name != 0` check before dereferencing the
out-param. Redirecting the import to `GetCurrentThread` (present since NT,
16 chars ≤ 19) is safe even if called: it ignores both args, writes nothing,
and returns `0xFFFFFFFE` (a failing HRESULT), so Bun's guard skips the
thread name in the (already crashing) report.

Everything else resolves on 14393, including the
`api-ms-win-core-synch-l1-2-0` (WaitOnAddress family → kernelbase, Win8+)
imports. The AVX2 and baseline exes have identical import tables.

## The patch

`patch_exe.py` rewrites the import name string **in place** in the exe's
import name table — no RVAs shift, no IAT entries move, file size unchanged.
20 bytes differ from the stock exe: the name slot (hint untouched) plus the
recomputed PE checksum. Duplicate import names in one DLL are legal, and
hint mismatches are ignored by the loader (binary-search fallback).

## Usage

```sh
pip install pefile

# What is missing on 1607? (fetches/caches real 14393 DLLs first run)
python3 patch_exe.py check  cyberstrike.exe [cachedir]

# List all imports
python3 patch_exe.py analyze cyberstrike.exe

# Patch a copy
python3 patch_exe.py patch   cyberstrike.exe cyberstrike-win1607.exe
```

Then repackage the exe into `cyberstrike-windows-x64-baseline.zip` (flat:
`hackbrowser-worker.js` + `cyberstrike.exe`) with the stock asset name and
upload as a fork release — the install script constructs
`cyberstrike-windows-{arch}[-baseline].zip` URLs by convention.

## On a new upstream release

1. Download the new zips, run `check` on the exe.
2. If still only `GetThreadDescription` → `patch`, repack, release. Done.
3. If **new** missing imports appear, add them to `REDIRECTS` in
   `patch_exe.py`. The replacement must: exist in the same DLL on 14393
   (`check`'s ground-truth sets tell you), fit in the original name slot, and
   be safe if actually called (zero-arg, no writes, failing-HRESULT returns
   are ideal). Verify the call site in oven-sh/bun source first.
4. If a new missing import is on a hot path (startup, spawn, console),
   in-place patching is no longer enough — escalate to rebuilding Bun with a
   lowered Zig Windows floor (see PLAN-cyberstrike-win1607.md, Path B).

The static proof is load-time only: after patching, every import resolves on
14393, which eliminates 0xC0000139. Runtime behavior of any stubbed function
still needs a smoke test on the box (`cyberstrike --version`, then a real
session).
