#!/usr/bin/env node
// Drop debug metadata from a WebAssembly binary.
//
// online.wasm is built with CXXFLAGS='-g -O1' -- the -g is not wanted, it is a
// consequence of avoiding -O2, whose LTO link peaks at ~12 GiB. That leaves two
// kinds of inert payload in the shipped binary: the DWARF `.debug_*` sections and
// the `name` section (function/local symbol names). Together they are ~81 MB of
// 247 MB raw, ~13 MB of 60 MB gzipped, and nothing at runtime reads either.
//
// Why this rather than `wasm-strip`: wabt parses the module fully, and this binary
// combines threads, -fwasm-exceptions and WASM_BIGINT, so a feature-support gap in
// the tool would fail late and confusingly. Custom sections are ignorable by
// definition, so walking the top-level section table and copying every kept
// section byte-for-byte -- id, length LEB and payload untouched -- cannot alter
// semantics. Non-custom sections are never even inspected.
//
// Keep the unstripped binary: `name` is what turns a browser stack trace into
// readable C++ frames, and it is what made the UnitKit and double-HULLO bugs
// diagnosable at all. Strip for delivery, symbolicate against the original.

import { readFileSync, writeFileSync, statSync } from "node:fs";
import { gzipSync } from "node:zlib";

const SECTION_NAMES = {
  1: "type", 2: "import", 3: "function", 4: "table", 5: "memory",
  6: "global", 7: "export", 8: "start", 9: "elem", 10: "code",
  11: "data", 12: "datacount", 13: "tag",
};

const drop = (name) => name === "name" || name.startsWith(".debug");

/** Read an unsigned LEB128 at `pos`; returns [value, bytesRead]. */
function leb128(buf, pos) {
  let result = 0, shift = 0, read = 0;
  for (;;) {
    const byte = buf[pos + read++];
    if (byte === undefined) throw new Error("truncated LEB128 at " + pos);
    result += (byte & 0x7f) * 2 ** shift;
    if ((byte & 0x80) === 0) return [result, read];
    shift += 7;
  }
}

function stripWasm(buf) {
  if (buf.readUInt32LE(0) !== 0x6d736100) throw new Error("not a wasm module");

  const kept = [buf.subarray(0, 8)]; // magic + version
  const report = [];
  let pos = 8;

  while (pos < buf.length) {
    const sectionStart = pos;
    const id = buf[pos++];
    const [size, sizeLen] = leb128(buf, pos);
    pos += sizeLen;
    const payloadStart = pos;
    const end = payloadStart + size;
    if (end > buf.length) throw new Error(`section ${id} overruns the file`);

    let label = SECTION_NAMES[id] ?? `section#${id}`;
    let dropped = false;
    if (id === 0) {
      const [nameLen, nameLenBytes] = leb128(buf, payloadStart);
      const name = buf
        .subarray(payloadStart + nameLenBytes, payloadStart + nameLenBytes + nameLen)
        .toString("utf8");
      label = `custom:${name}`;
      dropped = drop(name);
    }

    // Copy verbatim, including the id byte and length LEB, so kept sections are
    // bit-identical to the input.
    if (!dropped) kept.push(buf.subarray(sectionStart, end));
    report.push({ label, size, dropped });
    pos = end;
  }

  return { out: Buffer.concat(kept), report };
}

const [input, output] = process.argv.slice(2);
if (!input) {
  console.error("usage: strip-wasm.mjs <input.wasm> [output.wasm]");
  process.exit(2);
}

const buf = readFileSync(input);
const { out, report } = stripWasm(buf);

const MB = 1048576;
for (const { label, size, dropped } of report) {
  if (size < 4096 && !dropped) continue;
  console.log(
    `${dropped ? "DROP" : "keep"}  ${label.padEnd(24)} ${(size / MB).toFixed(2).padStart(8)} MB`,
  );
}

console.log(
  `\nraw   ${(buf.length / MB).toFixed(1)} MB -> ${(out.length / MB).toFixed(1)} MB` +
    `  (-${(100 - (100 * out.length) / buf.length).toFixed(1)}%)`,
);

if (process.env.MEASURE_GZIP === "1") {
  const before = gzipSync(buf, { level: 6 }).length;
  const after = gzipSync(out, { level: 6 }).length;
  console.log(
    `gzip  ${(before / MB).toFixed(1)} MB -> ${(after / MB).toFixed(1)} MB` +
      `  (-${(100 - (100 * after) / before).toFixed(1)}%)`,
  );
}

if (output) {
  writeFileSync(output, out);
  console.log(`\nwrote ${output} (${statSync(output).size} bytes)`);
} else {
  console.log("\nno output path given -- nothing written");
}
