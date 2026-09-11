#!/usr/bin/env node
// Drop all but a core font set from a built browser/dist, rewriting soffice.data
// + its metadata in place. LibreOffice substitutes missing fonts freely, so this
// is safe; documents in scripts outside the core set render with a fallback.
// (Dropping .ui files was tried and abandoned -- LOK builds its whole chrome
//  from .ui widget templates at doc load, so it's not dialog-only.)
//
// Usage: node reader-trim.mjs <browser/dist>

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dist = process.argv[2];
if (!dist) {
  console.error("usage: reader-trim.mjs <browser/dist>");
  process.exit(2);
}

const FONTS = new Set([
  "LiberationSans-Regular.ttf", "LiberationSans-Bold.ttf",
  "LiberationSans-Italic.ttf", "LiberationSans-BoldItalic.ttf",
  "LiberationSerif-Regular.ttf", "LiberationSerif-Bold.ttf",
  "LiberationSerif-Italic.ttf", "LiberationSerif-BoldItalic.ttf",
  "LiberationMono-Regular.ttf", "LiberationMono-Bold.ttf",
  "LiberationMono-Italic.ttf", "LiberationMono-BoldItalic.ttf",
  "Carlito-Regular.ttf", "Carlito-Bold.ttf",
  "Carlito-Italic.ttf", "Carlito-BoldItalic.ttf",
  "Caladea-Regular.ttf", "Caladea-Bold.ttf",
  "Caladea-Italic.ttf", "Caladea-BoldItalic.ttf",
  "DejaVuSans.ttf", "DejaVuSans-Bold.ttf",
  "DejaVuSerif.ttf", "DejaVuSerif-Bold.ttf", "DejaVuSansMono.ttf",
  "DejaVuMathTeXGyre.ttf",
  "NotoSans-Regular.ttf", "NotoSans-Bold.ttf",
  "NotoSerif-Regular.ttf", "NotoSerif-Bold.ttf",
  "opens___.ttf",
]);

const drop = (f) => /\.(ttf|otf|ttc)$/i.test(f) && !FONTS.has(f.split("/").pop());

const META = join(dist, "soffice.data.js.metadata");
const DATA = join(dist, "soffice.data");
const meta = JSON.parse(readFileSync(META, "utf8"));
const blob = readFileSync(DATA);

const kept = [];
const parts = [];
let cursor = 0, droppedBytes = 0, droppedFonts = 0;
for (const e of meta.files) {
  if (drop(e.filename)) {
    droppedBytes += e.end - e.start;
    droppedFonts++;
    continue;
  }
  const bytes = blob.subarray(e.start, e.end);
  e.start = cursor;
  e.end = cursor + bytes.length;
  cursor += bytes.length;
  parts.push(bytes);
  kept.push(e);
}
if (droppedFonts === 0) {
  console.log("reader-trim: nothing to drop (already trimmed?)");
  process.exit(0);
}
const repacked = Buffer.concat(parts, cursor);
writeFileSync(DATA, repacked);
meta.files = kept;
meta.remote_package_size = repacked.length;
writeFileSync(META, JSON.stringify(meta));

const MB = (n) => (n / 1048576).toFixed(1);
console.log(
  `reader-trim: dropped ${droppedFonts} fonts (${MB(droppedBytes)} MB); ` +
    `soffice.data ${MB(blob.length)} -> ${MB(repacked.length)} MB, ${kept.length} files`,
);
