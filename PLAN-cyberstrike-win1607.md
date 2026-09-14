# Plan: Run cyberstrike on Windows 10 1607 / Server 2016 (Citrix box)

Status: **EXECUTED 2026-09-14 — Path A applied.** Recon found exactly one missing import on 14393
(`kernel32!GetThreadDescription`, crash-handler-only call site); patched in-place per
`scripts/win1607/README.md`. Release: `v1.1.16-win1607.1`.

---

## Problem

`cyberstrike.exe` (v1.1.16) installs fine on the old Citrix box (Windows Server 2016 /
Win10 1607, build 14393) but dies at launch:

```
$LASTEXITCODE: -1073741511   (0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND)
```

The binary statically imports a named Windows API function that doesn't exist in 1607's
system DLLs. This is a property of the **Bun runtime** the exe is compiled with — not
cyberstrike's code. Upstream OpenCode is the same Bun compile target and fails
identically. You can't back-port an OS API — but you *can* bring the binary down to
the OS, or interpose a shim.

**We are forking for two reasons:**

1. **Hotpatch + recompile** the binary so it runs on 1607 (no AVX2 → **baseline
   flavor is the mandatory target**).
2. **Own the distribution path.** The box installs/upgrades via the official
   `install.ps1`; the fork must serve an equivalent installer pointing at
   `shreyas-confido/CyberStrike` release assets, preserving every old-box
   accommodation the official one already has (see Installer contract below).

## Confirmed facts (research, 2026-09-14)

| Fact | Detail |
|---|---|
| Repo | `github.com/CyberStrikeus/CyberStrike` — main @ `6a8380c`, latest release **v1.1.16**, AGPL-3.0-only |
| Build | `bun run packages/cyberstrike/script/build.ts` — Bun **1.3.9** (locked), `Bun.build()` with `target: "bun-win32-x64"` → single-file `cyberstrike.exe` |
| Windows assets | `cyberstrike-windows-x64.zip` (AVX2) and `cyberstrike-windows-x64-baseline.zip` (no-AVX2 — **the flavor this box runs**) |
| Bun's Windows floor | **Win10 1809+ for every Bun release.** Windows support debuted at v1.1 already floored at 1809 (bun.com installation docs; oven-sh/bun#24714). "Recompile with a different Bun version" is dead |
| Source Bun-lock | Heavy: `bun:sqlite` (3 files, via `drizzle-orm/bun-sqlite`), `bun:ffi` (win32 console, 1 file), ~454 `Bun.*` occurrences across 80+ files (`Bun.file`, `Bun.spawn`, `Bun.Glob`, `Bun.$`, `Bun.which`, `Bun.CryptoHasher`) |
| Parallel precedent | Claude Code's Bun-compiled binary fails on Server 2016 with exactly this error — `GetThreadDescription` entry point not found in `kernel32` (anthropic-ai/claude-code#50583). `GetThreadDescription` is a 1703-era export, absent in 14393 |
| Box CPU | **No AVX2** → the `-baseline` (no-AVX2) build is the mandatory target flavor |
| Official installer | `install.ps1` (reference copy reviewed at `~/Downloads/install.ps1`) — PS1-only flow, already proven working on the box ("cyberstrike installed successfully") |
| GitHub account | Fork under **shreyas-confido** (verified active in `gh`, `repo`+`workflow` scopes) |
| Clone target | `/Users/shreyas/projects/cyberstrike` (this repo stays untouched) |

## Installer contract (fork must preserve, verbatim behavior)

The reference `install.ps1` does all of the following; our fork's installer must too:

| Behavior | Reference implementation | Why it matters on this box |
|---|---|---|
| Repo pointer | `$Repo = "CyberStrikeus/CyberStrike"` → must become `shreyas-confido/CyberStrike` | Installs/`Get-LatestVersion` hit our fork's releases |
| TLS 1.2 forcing | `[Net.ServicePointManager]::SecurityProtocol = -bor Tls12` before any GitHub call | PS 5.1 on 2016 negotiates TLS 1.0/1.1 by default; GitHub rejects both — without this the version check fails silently |
| Direct-byte download | `Invoke-WebRequest -OutFile` (no curl/wget) | **Server 2016 has no bundled `curl.exe`** (arrived in 1809). Any on-box tooling we write has the same constraint |
| AVX2 detection | `IsProcessorFeaturePresent(40)` via inline C# P/Invoke → falls back to `-baseline` asset | The box's CPU lacks AVX2 — this is the path the box actually takes |
| Asset naming | `cyberstrike-windows-x64-baseline.zip` | Our fork's release assets must keep these exact names or the installer breaks |
| Install layout | `%LOCALAPPDATA%\cyberstrike\cyberstrike.exe` (or `CYBERSTRIKE_INSTALL_DIR`); `hackbrowser-worker.js` → `~/.local/share/cyberstrike/bin` (XDG data dir, matches `Global.Path.bin`) | Runtime locates the worker independent of PATH; must not regress |
| PATH update | Interactive Y/n prompt → `[Environment]::SetEnvironmentVariable("PATH", ..., "User")` | User expects same UX out of the fork |

## Research corrections (important)

Two subagent claims were investigated and **rejected** — do not plan around them:

1. **`GetSystemTimePreciseAsFileTime` is NOT the culprit.** One research pass
   identified it as the missing function, but it's a Windows 8 API and 1607 *postdates*
   Windows 8 — it's present on the box. The claim "1607 predates Windows 8" was simply
   wrong. The likely culprit class is 1703–1809-era kernel32 exports (`GetThreadDescription`
   et al.). The exact missing set is determined by Phase 1 static analysis, not by guessing.
2. **"Node 18+ won't run on Server 2016" is over-inferred.** Node's own `BUILDING.md`
   (v18–v24) lists Server 2016 as officially supported; the cited libuv evidence concerns
   Windows 7 drops and Nano Server breakage. Keeps the Node fallback (Path C) alive —
   a 30-second `node.exe --version` smoke test on the box settles it if we ever get there.

## Why the obvious tricks don't work

| Trick | Verdict |
|---|---|
| DotLocal (`.exe.local`) DLL redirection | ❌ The missing imports come from `kernel32` — a KnownDLL, always loaded from System32; app-local redirection can't touch it |
| VXKex-style compatibility layer | ❌ Windows 7-only by design (VxKex#118); does not support Server 2016 |
| LIEF import-table rebuild | ❌ x64 import rebuild is historically broken (lief-project/LIEF#777) |
| Older Bun / different Bun | ❌ No release has a floor below Win10 1809 |
| Node SEA single-exe | ❌ Requires Node 20+ — viable only if Node itself runs on the box (unverified) |

## The plan

### Phase 1 — Pinpoint the missing imports (~1 hr, no fork yet)

- Download `cyberstrike-windows-x64-baseline.zip` (**primary target — the no-AVX2
  flavor the box runs**) and the AVX2 zip (secondary; patches should apply to both).
- PE import analysis with `pefile`: enumerate every import of the **baseline**
  `cyberstrike.exe`, diff against Win10 1607 (build 14393) export sets (per-API
  Microsoft docs).
- **On-box cross-check (user):** double-click `cyberstrike.exe` in Explorer, capture the
  "procedure entry point **X** could not be located in **Y**.dll" dialog — one-shot
  validation of the static-analysis list.
- **Gate:** how many functions are missing, and are they *cold* (crash reporter, thread
  naming, logging) or *hot* (console, process spawn, timers)? This decides Path A vs B.

### Phase 2 — Fork + clone + reproduce build (shreyas-confido)

- `gh repo fork CyberStrikeus/CyberStrike` → clone to `/Users/shreyas/projects/cyberstrike`.
- Branch: `win1607-compat`.
- Install Bun 1.3.9 locally, reproduce the stock build, verify the exe runs on macOS.
  We don't ship to the box until we can build what we ship.
- **Locate the in-repo installer source.** The docs-served `install.ps1`
  (`irm https://cyberstrike.io/install.ps1 | iex`) must originate in the repo — find it
  (likely repo root or `scripts/`), and fork it alongside the binary patches.
- **Confirm the release workflow** (`.github/workflows/publish.yml` builds + uploads
  the zips): our fork needs to produce a GitHub release with correctly-named assets
  (`cyberstrike-windows-x64-baseline.zip` etc.) that the patched installer can target.

### Phase 3 — Fix, cheapest first (gated by Phase 1)

**Path A — Surgical import-name patch of the stock exe (hours, no recompile).**
0xC0000139 fires at *load-time* import resolution — static imports must resolve even if
never called. If the missing imports are cold-path (likely, per the Claude Code
precedent), overwrite the import-name strings in-place with an existing same-DLL export
of ≤ length (e.g. `GetThreadDescription` (19 chars) → `GetCurrentThread` (16)),
recompute the PE checksum, repackage the **baseline** zip with the stock asset name,
ship. x64-safe: the IAT structure is never touched — this sidesteps the LIEF breakage
entirely. Limitation: if a patched function is actually called at runtime, behavior is
undefined (garbage thread names at worst, crash at worst). Fastest possible win; try
before anything heavy. Note: a patched stock exe can ship as a fork release asset even
without rebuilding — repackage + upload is enough for this path.

**Path B — Patched-Bun rebuild: the real "hotpatch + recompile" (days).**
Bun vendors Zig, and Zig's std *version-gates* newer Windows APIs: when the declared
minimum OS predates an API's introduction, Zig emits a runtime `GetProcAddress` lookup
instead of a static import — the same fix OpenJDK shipped for `GetThreadDescription`
on Server 2016 (JDK-8238649), essentially for free. The hotpatch: find where Bun's
build hardcodes the Win10 1809 floor, lower it to 1607, rebuild Bun for Windows
(cross-compiles from macOS per Bun's build-from-source docs), rebuild `cyberstrike.exe`
with the patched Bun via the fork's build script. The stock `build.ts` already emits
standard + baseline flavors, so the fork's release gets both automatically. Any API
still called unconditionally gets a small explicit compat shim in the Bun/Zig source
(execute on Phase 1 findings). One-time cost per Bun version — cyberstrike pins
1.3.9, so patch once.

**Path C — Node retarget (weeks, last resort).**
Polyfill `Bun.*` globals under Node, swap `bun:sqlite` → `node:sqlite` /
`better-sqlite3`, `bun:ffi` → `koffi`, `drizzle-orm/bun-sqlite` → `drizzle-orm/better-sqlite3`,
bundle with esbuild + portable `node.exe` beside the app. Only if A and B both die.
Bonus risk even then: a modern TUI over a Server 2016 Citrix console is its own
adventure. Gate: `node.exe --version` smoke test on the box first.

### Phase 4 — Ship + verify on the box

**Deliverable is a fork release, not a loose exe:** the patched **baseline** zip
uploaded to a `shreyas-confido/CyberStrike` release with stock asset names, plus the
patched `install.ps1` (`$Repo` → our fork) — so the box installs and future-upgrades
through the same flow it already trusts. On-box test uses the installer, not manual
file drops.

- On-box install: run the fork's `install.ps1` (local copy, or
  `irm https://raw.githubusercontent.com/shreyas-confido/CyberStrike/<branch>/install.ps1 | iex` —
  TLS 1.2 is forced inside the script, so both work on PS 5.1).
- Verify installer behavior on the box: AVX2 fallback message → baseline asset selected,
  PATH update prompt, `hackbrowser-worker.js` placed in the XDG data bin.
- Smoke test: `cyberstrike --version` → check `$LASTEXITCODE` (0), then an
  interactive TUI session through Citrix.
- Iterate until exit code 0 and a usable TUI.
- All patches land as clean, cherry-pickable commits on the fork — one logical change
  per commit, so pulling upstream later stays painless.

## Risks / notes

- **AGPL-3.0 fork:** fine for internal use; source obligations only if we ever distribute
  the patched binary outside the org.
- **Baseline is the box's only flavor:** no-AVX2 CPU means the AVX2 build crashes with
  illegal-instruction faults — a *different* failure than 0xC0000139. Don't conflate
  the two during testing; the installer's `IsProcessorFeaturePresent(40)` check exists
  to route around exactly this.
- **Code signing:** upstream signs via SignPath (`sign-cli.yml`); our fork's assets
  will be unsigned. On an internal Citrix box that's usually fine (SmartScreen may
  prompt once), but expect it.
- **Asset naming is a contract:** the installer constructs
  `cyberstrike-windows-{arch}[-baseline].zip` by convention — if the fork's release
  workflow renames anything, the installer breaks silently.
- **Path A bet:** silently depends on missing imports being cold-path. Phase 1's gate
  exists to catch a hot-path import *before* betting on A.
- **Path B unknowns:** Bun's 1809 floor location in the build config (vs. hardcoded
  assumptions in Bun/Zig source) is unverified until execution; if Zig's version
  gating doesn't cover every missing import, each leftover needs a hand shim.
- **TUI over Citrix:** rendering/input on a 2016 console is a separate risk from the
  runtime compat this plan fixes. Don't conflate failures during Phase 4 testing.

## Decisions needed before execution

1. **Approve plan / reorder paths** (default: A → B → C).
2. **On-box access:** can you run a couple of PowerShell commands on the Citrix box —
   now (capture the entry-point dialog text) and later (run the fork installer +
   smoke tests)?
3. **Clone target confirmation:** `/Users/shreyas/projects/cyberstrike`.
4. **Installer delivery:** local copy on the box vs. served from the fork's default
   branch (raw.githubusercontent URL). Default: both work; local copy first since the
   box already has the official one in Downloads to diff against.

## Sources

- bun.com installation docs (Windows 1809 floor) · oven-sh/bun#24714
- anthropic-ai/claude-code#50583 (Bun binary, `GetThreadDescription`, Server 2016)
- OpenJDK JDK-8238649 (delay-load fix for the same API class)
- lief-project/LIEF#777 (x64 import rebuild broken) · VxKex#118 (Win7-only)
- nodejs `BUILDING.md` v18–v24 (Server 2016 officially supported)
- CyberStrikeus/CyberStrike repo + `packages/cyberstrike/script/build.ts` (Bun 1.3.9, `bun-win32-x64`)
