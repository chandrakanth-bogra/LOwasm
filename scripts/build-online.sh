#!/bin/bash
# Configure and build Collabora Online (co-25.04) for WebAssembly, linked
# against the core build. Produces $ONLINE_BUILD/browser/dist.
#
# Normally run through finish.sh, which also post-processes dist/.
# Runs itself inside the builder image.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
if [ -z "${LOWASM_IN_BUILDER:-}" ]; then
  in_builder "bash '$LOWASM_ROOT/scripts/build-online.sh'"
  exit $?
fi
source "$LOWASM_ROOT/scripts/container-env.sh"

[ -f "$CORE_BUILD/instdir/program/soffice.data" ] \
  || die "core is not built in $CORE_BUILD -- run scripts/build-core.sh first"
[ -d "$DEPS/poco-install/lib" ] && [ -d "$DEPS/zstd-install/lib" ] \
  || die "zstd/POCO not built in $DEPS -- run scripts/build-deps.sh first"

cd "$ONLINE_SRC"
# configure is generated from configure.ac. Regenerate whenever configure.ac is
# newer, otherwise a configure.ac edit silently has no effect: `-x ./configure`
# is already true and autogen.sh never re-runs.
[ -x ./configure ] && [ ./configure -nt ./configure.ac ] || ./autogen.sh

mkdir -p "$ONLINE_BUILD"
cd "$ONLINE_BUILD"
emconfigure "$ONLINE_SRC/configure" \
    --disable-werror \
    --with-lokit-path="$CORE_SRC/include" \
    --with-lo-sourcedir="$CORE_SRC" \
    --with-lo-path="$CORE_BUILD/instdir" \
    --with-lo-builddir="$CORE_BUILD" \
    --with-zstd-includes="$DEPS/zstd-install/include" \
    --with-zstd-libs="$DEPS/zstd-install/lib" \
    --with-poco-includes="$DEPS/poco-install/include" \
    --with-poco-libs="$DEPS/poco-install/lib" \
    --host=wasm32-local-emscripten \
    CXXFLAGS="$LOWASM_CXXFLAGS"

# Two outputs make will not regenerate on its own, both of which have cost real
# time:
#  - cool.html's recipe bakes in $(APP_NAME), but its rule depends only on
#    files, and make tracks mtimes, not variable values -- so a configure.ac
#    change leaves it stale.
#  - wasm/exports is copied from core's exports and then appended to. It is
#    timestamp-gated against a prerequisite that rarely changes, so a newly
#    exported symbol goes silently missing and fails at runtime in ccall.
rm -f "$ONLINE_BUILD/browser/dist/cool.html" "$ONLINE_BUILD/wasm/exports"

emmake make -j"$LOWASM_ONLINE_JOBS" CC=emcc CXX=em++
