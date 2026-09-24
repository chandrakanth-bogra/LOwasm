#!/usr/bin/env node
// Check that a built payload's filesystem image is self-consistent.
//
// soffice.data is unpacked into MEMFS at startup by the --pre-js loader that
// core generates (soffice.data.js.link) and Online bakes into online.js. That
// loader first creates every directory with FS_createPath, then writes each
// file listed in soffice.data.js.metadata. If the metadata lists a file in a
// directory the loader never creates, the write fails with ErrnoError (ENOENT)
// during startup -- for every document, before loading even begins -- and the
// error carries no path.
//
// This goes wrong when the file list changes (e.g. enabling Impress adds the
// simpress/sdraw/smath config) but the loader is not regenerated: checking
// that every file exists and sizes match does NOT catch it, because the files
// are fine and only the directory table is stale.
//
// Usage: node check-fs-image.mjs <soffice.data.js.metadata> <online.js | soffice.data.js.link>
// Exits 1 if any directory is missing.

import { readFileSync } from "node:fs";

const [metaPath, loaderPath] = process.argv.slice(2);
if (!metaPath || !loaderPath) {
  console.error("usage: check-fs-image.mjs <soffice.data.js.metadata> <online.js | soffice.data.js.link>");
  process.exit(2);
}

const meta = JSON.parse(readFileSync(metaPath, "utf8"));
const loader = readFileSync(loaderPath, "utf8");

// Emitted as: Module['FS_createPath']("/parent", "name", true, true);
// Linking with -sALLOW_MEMORY_GROWTH runs the JS through another pass that
// rewrites the quotes to Module["FS_createPath"], so accept either.
const created = new Set(["/"]);
for (const m of loader.matchAll(/FS_createPath['"]?\]?\(\s*"([^"]*)"\s*,\s*"([^"]*)"/g)) {
  created.add((m[1] === "/" ? "" : m[1]) + "/" + m[2]);
}

const needed = new Set();
for (const f of meta.files) {
  needed.add(f.filename.slice(0, f.filename.lastIndexOf("/")) || "/");
}

const missing = [...needed].filter((d) => !created.has(d)).sort();
console.log(
  `files: ${meta.files.length}  directories needed: ${needed.size}  created by loader: ${created.size}  missing: ${missing.length}`,
);
for (const d of missing) console.log(`  MISSING ${d}`);
process.exit(missing.length ? 1 : 0);
