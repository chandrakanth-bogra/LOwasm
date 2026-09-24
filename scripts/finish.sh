#!/bin/bash
# Build Online and turn its browser/dist into a servable payload:
# rebuild -> blank stray placeholders -> neutral splash styling -> service
# worker -> optional font subset -> strip debug metadata.
#
#   READER=1 finish.sh    font-subset soffice.data for a read-only viewer
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

NODE=$NODE_DIR/bin/node
[ -x "$NODE" ] || die "Node 20 not found at $NODE_DIR -- run scripts/setup.sh first"

echo "=== building Online $(date '+%F %T') ==="
# Full output to a log, then check the real exit status. Piping the build
# straight into `tail` discards it ($? is tail's) -- that once let two failed
# builds print DONE and exit 0 while bundle.js silently stayed stale.
mkdir -p "$LOWASM_BUILD"
LOG=$LOWASM_BUILD/build-online.log
"$LOWASM_ROOT/scripts/build-online.sh" >"$LOG" 2>&1
rc=$?
tail -4 "$LOG"
if [ $rc -ne 0 ]; then
  echo "FAILED: build exited $rc -- errors from $LOG:"
  grep -iE "error TS|error:|Error [0-9]+|undefined symbol" "$LOG" | head -20
  exit 1
fi
[ -f "$DIST/online.wasm" ] || die "no online.wasm in $DIST"

echo "=== blanking cool.html placeholders ==="
# coolwsd's FileServer.cpp fills these in at request time; this payload is
# served statically, so that never runs. %ACCESS_TOKEN% and friends matter:
# left literal, main.js folds the text into the fetch URL and every document
# 404s. The other two are cosmetic but blanked while here.
sed -i "s/%ACCESS_TOKEN%//g; s/%ACCESS_TOKEN_TTL%//g; s/%ACCESS_HEADER%//g; \
        s/%NO_AUTH_HEADER%//g; s/%UI_RTL_SETTINGS%//g" "$DIST/cool.html"
echo "  remaining %PLACEHOLDER%: $(grep -oE '%[A-Z_]+%' "$DIST/cool.html" | grep -v BRANDING_CSS | wc -l)  (BRANDING_CSS sits in an HTML comment)"

echo "=== splash styling ==="
"$LOWASM_ROOT/scripts/debrand.sh" "$DIST" || exit 1

cp -f "$ONLINE_SRC/wasm/cool-payload-sw.js" "$DIST/"
# Stamp the cache name with this build. The worker caches online.wasm and friends
# under URLs that never change, so a fixed name serves the previous build's bytes
# for ever -- new JS against an old engine, which fails in confusing ways (an
# assert deep in main(), not an obvious "stale cache" message). The worker's
# activate handler already deletes every cache whose name differs from the
# current one, so bumping the name is all that is needed.
sed -i "s/cool-payload-v1/cool-payload-$(date -u +%Y%m%d%H%M%S)/" "$DIST/cool-payload-sw.js"
# The host-API test page. Not part of the engine, but shipped with it so a built
# payload can be exercised the way a host uses it (see wasm/lowasm-test.html).
cp -f "$ONLINE_SRC/wasm/lowasm-test.html" "$DIST/"

if [ "${READER:-}" = 1 ]; then
  echo "=== font-subsetting soffice.data for a read-only viewer ==="
  # Copy the pristine image first: the browser Makefile's copy is mtime-gated
  # and will not restore a previously trimmed one.
  cp -f "$CORE_BUILD/instdir/program/soffice.data" \
        "$CORE_BUILD/instdir/program/soffice.data.js.metadata" "$DIST/"
  "$NODE" "$LOWASM_ROOT/tools/reader-trim.mjs" "$DIST" || exit 1
fi

echo "=== checking the filesystem image against its loader ==="
# A stale loader (online.js creating fewer directories than soffice.data needs)
# fails every document at startup with a pathless ErrnoError (ENOENT). Checking
# that the files exist does not catch it; this does, and names the directories.
META=$DIST/soffice.data.js.metadata
[ -f "$META" ] || META=$CORE_BUILD/instdir/program/soffice.data.js.metadata
"$NODE" "$LOWASM_ROOT/tools/check-fs-image.mjs" "$META" "$DIST/online.js" || {
  echo "FAILED: online.js does not create every directory soffice.data needs."
  echo "  Regenerate core's filesystem image, then rebuild Online:"
  echo "    rm -rf $CORE_BUILD/workdir/CustomTarget/static/emscripten_fs_image"
  echo "    scripts/build-core.sh && scripts/finish.sh"
  exit 1
}

echo "=== recording the build id ==="
# Which commit produced this payload. publish-ghcr.sh compares this with HEAD:
# comparing mtimes instead cannot tell "built before these commits existed" from
# "built from exactly this tree, then committed" -- and the second is the normal
# order here (build, verify, commit), so a timestamp check refuses valid payloads.
{
  git -C "$LOWASM_ROOT" rev-parse HEAD 2>/dev/null || echo unknown
  [ -n "$(git -C "$LOWASM_ROOT" status --porcelain -- online core scripts tools docker 2>/dev/null)" ] \
    && echo dirty
} > "$DIST/lowasm-build-id"
echo "  $(tr '\n' ' ' < "$DIST/lowasm-build-id")"

echo "=== stripping debug metadata ==="
# The unstripped binary is kept: it is what makes an abort's stack trace
# readable, by serving it in place of the stripped one.
cp -f "$DIST/online.wasm" "$LOWASM_BUILD/online.wasm.unstripped"
"$NODE" "$LOWASM_ROOT/tools/strip-wasm.mjs" \
  "$LOWASM_BUILD/online.wasm.unstripped" "$DIST/online.wasm" | tail -3 || exit 1

echo "=== result ==="
for f in online.wasm soffice.data online.js; do
  [ -f "$DIST/$f" ] && awk -v s="$(stat -c%s "$DIST/$f")" -v f="$f" \
    'BEGIN { printf "  %8.1f MB  %s\n", s/1048576, f }'
done
echo "DONE $(date '+%F %T')  ->  $DIST"
