#!/usr/bin/env node
// Move the dialog .ui files out of the eager preload image (soffice.data) and
// into lazily-fetched files, rewriting soffice.data + its metadata in place and
// emitting lo-ui/<path> + lo-ui-manifest.json. main.js registers the manifest
// with FS.createLazyFile. Kept eager: *_online.ui, sfx/ui/*, sidebar*.ui.
//
// Usage: node split-ui.mjs <browser/dist>

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

const dist = process.argv[2];
if (!dist) {
  console.error("usage: split-ui.mjs <browser/dist>");
  process.exit(2);
}

const META = join(dist, "soffice.data.js.metadata");
const DATA = join(dist, "soffice.data");
const UIDIR = join(dist, "lo-ui");

const keepEager = (f) =>
  /\/sfx\/ui\//.test(f) ||
  /\/sidebar[^/]*\.ui$/.test(f) ||
  /\/notebookbar_online\.ui$/.test(f);

const meta = JSON.parse(readFileSync(META, "utf8"));
const blob = readFileSync(DATA);

const lazy = [];
const kept = [];
for (const e of meta.files) {
  if (e.filename.endsWith(".ui") && !keepEager(e.filename)) lazy.push(e);
  else kept.push(e);
}
if (lazy.length === 0) {
  console.log("split-ui: nothing to do (already split?)");
  process.exit(0);
}

// write each lazy .ui as its own static file under lo-ui/
for (const e of lazy) {
  const out = join(UIDIR, e.filename); // filename starts with "/instdir/..."
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, blob.subarray(e.start, e.end));
}
writeFileSync(join(dist, "lo-ui-manifest.json"), JSON.stringify(lazy.map((e) => e.filename)));

// repack soffice.data from the kept ranges only, rewriting offsets
const parts = [];
let cursor = 0;
for (const e of kept) {
  const bytes = blob.subarray(e.start, e.end);
  e.start = cursor;
  e.end = cursor + bytes.length;
  cursor += bytes.length;
  parts.push(bytes);
}
const repacked = Buffer.concat(parts, cursor);
writeFileSync(DATA, repacked);

meta.files = kept;
meta.remote_package_size = repacked.length;
writeFileSync(META, JSON.stringify(meta));

const MB = (n) => (n / 1048576).toFixed(1);
console.log(
  `split-ui: ${lazy.length} .ui -> lo-ui/ (${MB(blob.length - repacked.length)} MB); ` +
    `soffice.data ${MB(blob.length)} -> ${MB(repacked.length)} MB, ${kept.length} files remain`,
);
