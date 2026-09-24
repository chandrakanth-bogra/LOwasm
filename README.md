# LOwasm

Office documents in the browser with no server: Collabora Online and LibreOffice
core compiled to WebAssembly and served as static files. COOLWSD, the document kit
and LibreOffice all run as WebAssembly inside the browser tab; the only server is a
static file host.

Verified to render `.docx .odt .xlsx .ods .odp .ppt`. `.pptx` has not been tested. PDF
is not supported in this build.

## Status

| | |
|---|---|
| Rendering Writer, Calc, Impress documents | ✅ verified |
| Branding | blank by design — apply your own at source |
| Warm engine reuse (many documents, one instance) | ⚠️ engine side works (2nd document in ~943 ms); the client-side swap wedges the browser main thread |
| Read-only mode | ❌ documents open editable; saving POSTs back and has no receiver |
| Document input | ✅ host-supplied bytes — `window.lowasm.load(name, bytes)`; the engine performs no HTTP |
| Embedding API | ⚠️ not yet stable (see below) |

Payload: `online.wasm` ~176 MB, `soffice.data` ~103 MB (56 MB with `READER=1`),
~82 MB gzipped. Cold load ~9.6 s, warm reload ~6.4 s, at the default `-O1`.

## Layout

```
online/     Collabora Online      distro/collabora/co-25.04 @ 3847fbc   + our commits
core/       LibreOffice core      distro/collabora/co-25.04 @ e588bf8da + our commits
scripts/    build, post-process and serve
tools/      strip-wasm, reader-trim, split-ui (Node)
```

### Branches

- **`vendor`** — the pristine upstream snapshots, nothing of ours.
- **`main`** — `vendor` plus our commits:

  | Tree | Commit |
  |---|---|
  | online | Fetch server documents from `/cowasm-wopi/wasm/` |
  | online | Guard `UnitKit::get()` on the WASM path |
  | online | Remove branding at the source level |
  | online | Quiet the console; `?loglevel=` override |
  | online | Trim the Help menu and tab |
  | online | Cache the payload in a service worker |
  | online | Warm engine reuse (incomplete) |
  | core | Re-enable Impress/Draw/Math for the Emscripten build |
  | core | Ship the simpress config files presentations need |
  | core | Keep Impress, Draw, Math and canvas at configure time |
  | core | Add `sources.ver` so core builds from a non-git tree |

Upstream history is not in this repository: `vendor` starts from a snapshot.

Omitted from `core/`: `.gitmodules` and its three empty, unused submodules
(`dictionaries`, `helpcontent2`, `translations`), and
`sdext/source/pdfimport/xpdftest/binary_1_out.def` (72 MB of PDF-import test data).

## Requirements

- Linux x86_64 with **Docker**. Everything compiles inside
  `public.ecr.aws/allotropia/libo-builders/wasm`, which provides emsdk.
- **Disk:** ~15 GB free for sources, build trees and LibreOffice's external tarballs.
- **Memory**, set by two link steps rather than by compiling:

  | Step | Peak |
  |---|---|
  | core `soffice.js` link | **> 7.4 GiB** |
  | Online link at `-O1` (default) | ~1.6 GiB |
  | Online link at `-O2` | **~12 GiB** (LTO) |

  16 GB is enough for the default build; use ≥ 32 GB for `-O2`.
  If the machine also runs Kubernetes, stop it before building core: Kubernetes sets
  `oom_score_adj=996` on its pods, so a global OOM kills them before the linker.

## Build

```bash
git clone https://github.com/chandrakanth-bogra/LOwasm.git
cd LOwasm
scripts/build.sh          # setup -> deps -> core -> Online payload
```

Or step by step:

| Step | Does | Time |
|---|---|---|
| `scripts/setup.sh` | fetches Node 20 and the zstd + POCO sources (SHA-256 pinned), pulls the builder image | seconds |
| `scripts/build-deps.sh` | builds zstd and POCO with `-fwasm-exceptions` | minutes |
| `scripts/build-core.sh` | configures (`CPWASM-LOKit`) and builds core; downloads ~90 external tarballs | **hours** |
| `scripts/finish.sh` | builds Online, then blanks placeholders, styles the splash, adds the service worker, checks the filesystem image against its loader, strips debug metadata | minutes |

The payload lands in `build/online/browser/dist/`.

`scripts/build-core.sh --configure-only` and `--reconfigure` are available.
An interrupted core build resumes: `make` is incremental.

### Serve and test

```bash
scripts/serve.sh build/online/browser/dist 18081 /path/to/documents
# open http://127.0.0.1:18081/lowasm-test.html?doc=example.docx
```

Any host must send, on every response:

```
Cross-Origin-Opener-Policy:   same-origin
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Resource-Policy: same-origin
```

The module is threaded, so it needs `SharedArrayBuffer`, which requires cross-origin
isolation. Serve `.wasm` as `application/wasm`, and ship `soffice.data.js.metadata`:
its URL is built at runtime, so it appears nowhere as a literal, and omitting it hangs
startup with no error.

## Configuration

All scripts read `scripts/config.sh`; override with environment variables.

| Variable | Default | Purpose |
|---|---|---|
| `LOWASM_BUILD` | `./build` | build tree root |
| `LOWASM_JOBS` | `nproc` | core parallelism |
| `LOWASM_ONLINE_JOBS` | `3` | Online parallelism |
| `LOWASM_CXXFLAGS` | `-g -O1` | Online compile flags |
| `LOWASM_EXT_SOURCES` | `build/ext_sources` | LibreOffice external tarballs; point at a mirror to skip downloads |
| `LOWASM_CORE_BUILD`, `LOWASM_DEPS`, `LOWASM_NODE` | under `build/` | reuse an existing build or install |
| `LOWASM_EXTRA_MOUNTS` | — | extra directories to mount into the builder |
| `READER=1` (finish.sh) | — | font-subset `soffice.data` for a read-only viewer |

## Making it faster

`-O1` is a memory compromise, not a choice. On a machine with the memory, change one
thing per build and measure each:

1. **Drop `-g`.** It forces *limited* binaryen post-link optimisation, and the DWARF is
   stripped afterwards anyway. Costs no memory.
   `LOWASM_CXXFLAGS="-O1"`
2. **`-O2`.** Smaller binary: less to download and less for V8 to compile.
   `LOWASM_CXXFLAGS="-O2"`
3. **`ASSERTIONS=0`** in `online/wasm/Makefile.am`.
4. **`-Os` versus `-O3`.** Download and compile scale with binary size, so size may
   beat speed on cold load. Measure it.
5. **Brotli** `-q11` plus `brotli_static` when packaging — offline, so free at runtime.

Only Online carries `-O1`; core builds at its own release level, so each of these
costs one Online relink, not a core rebuild.

## Embedding (current, unstable)

| | |
|---|---|
| `window.lowasm.ready` | promise; resolves once the engine is up and waiting |
| `window.lowasm.load(name, bytes, {canWrite})` | write bytes into the Emscripten filesystem and open them; resolves with `{docType, pages}` |
| `window.lowasm.save()` | save; the bytes arrive via the `saved` event |
| `window.lowasm.on(event, cb)` | `ready` \| `loaded` \| `saved` \| `error`; returns an unsubscribe function |
| `window.coolConfig` | configure the engine without query parameters on the host's own URL |
| `lowasm-test.html?doc=<name>` | a host page for testing, serving documents from `/docs/` |
| `window.coolLoadDocument(desc)` | lower-level: open a document already in the filesystem (`file:///docs/x.odt`) |
| `window.coolDocumentLoadFailed(url, status)` | override to handle a document that cannot be opened |
| `?loglevel=information\|debug\|trace` | engine log level for this page load (default `warning`) |

Collabora Online's host postMessage API (`Hide_Menu_Item`, `Hide_Button`, …) works
when the page is embedded in an iframe.

## Updating Collabora

Online and core are released as a pair. **Always move both together**: Online is
written against Collabora core's LibreOfficeKit, and moving one alone means porting
across that API.

```bash
git checkout vendor
rm -rf online core
# export the new upstream commits of the same Collabora release line into online/
# and core/, then drop the omissions listed above
git add -A -f online core
git commit -m "Import Collabora Online and core, <branch> @ <online-sha>, <core-sha>"
git checkout main
git rebase vendor
```

Two traps when exporting:

- **`git archive` honours `export-ignore`.** core's `.gitattributes` marks
  `schema/*/*` as export-ignore, so an archive silently drops the ODF and MathML
  schemas. Check the export against `git ls-tree` of the upstream commit.
- **Add with `-f`.** Upstream force-adds files its own `.gitignore` would exclude.

Expect rebase conflicts in the files our commits touch and Collabora changes often:
`browser/js/global.js`, `browser/src/app/Socket.ts`, `wsd/COOLWSD.cpp`,
`browser/src/control/Control.NotebookbarWriter.js`, `Control.Menubar.ts`,
`configure.ac`, `browser/html/cool.html.m4`. Our hunks are marked `LOWASM:`.

## Things that have cost real time

- **A build reporting success after failing.** Piping a build into `tail` discards its
  exit status. `finish.sh` logs and checks the real one.
- **`wasm/exports` and `cool.html` going stale.** Both are timestamp-gated against
  prerequisites that don't capture what changed; `build-online.sh` deletes both.
- **`services_constructors.list`** only regenerates on a full core `make`, never a
  module-scoped one.
- **`lokit_main_mutex` is not a barrier on WASM.** It is acquired the instant it is
  requested while kit threads keep running.
- **A stale loader directory table.** `online.js` bakes in core's `soffice.data.js.link`,
  which creates every MEMFS directory before any file is written. Change core's file list
  (enabling Impress adds the simpress/sdraw/smath config) without regenerating the loader
  and *every* document dies during startup with a pathless `ErrnoError` (ENOENT) — before
  loading begins. Checking that the files exist does not catch it; only the directory table
  is stale. `finish.sh` now fails the build on this, and `tools/check-fs-image.mjs` names
  the missing directories.
- **Mixing build trees.** Online links against whatever `--with-lo-path` pointed at when it
  was last configured, which is not necessarily the core you just built. This is what the
  stale-loader failure above usually turns out to be. Check
  `grep with-lo-path build/online/config.log`, and confirm the served `soffice.data` is
  byte-identical to `build/core/instdir/program/soffice.data`.
- **A wedged page makes Playwright hang rather than fail.** Race `page.evaluate`
  against a timer.
- **`_docLoaded` flips before a single tile has painted.** Screenshot on that edge and you
  get the UI shell over an empty canvas, which looks like a broken build but is not. Let it
  settle, then measure non-background pixels on the largest canvas.
- **Stack traces:** `finish.sh` keeps `build/online.wasm.unstripped`; serve it in place
  of the stripped `online.wasm` to get a readable trace.

## Licences

Upstream code keeps its own licences: `online/COPYING` (MPL-2.0) and `core/COPYING`,
`core/COPYING.MPL`, `core/COPYING.LGPL`.
