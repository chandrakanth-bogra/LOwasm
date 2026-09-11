#!/bin/bash
# Build zstd and POCO for Emscripten with -fwasm-exceptions.
#
# Why not the builder image's POCO: it is built with the JS-exceptions ABI
# (invoke_* thunks) and cannot link with -fwasm-exceptions. The recipe is
# online/wasm/README.no-container.md's, with Online's own POCO patches.
#
# Runs itself inside the builder image. Needs setup.sh first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
if [ -z "${LOWASM_IN_BUILDER:-}" ]; then
  in_builder "bash '$LOWASM_ROOT/scripts/build-deps.sh'"
  exit $?
fi
source "$LOWASM_ROOT/scripts/container-env.sh"

cd "$DEPS"
[ -f zstd-1.5.2.tar.gz ] && [ -f poco-1.12.4-release.tar.gz ] \
  || die "zstd/POCO sources missing in $DEPS -- run scripts/setup.sh first"

echo "=== zstd ==="
rm -rf zstd-1.5.2 && tar xzf zstd-1.5.2.tar.gz && cd zstd-1.5.2
emmake make -j"$LOWASM_JOBS" CC='emcc -pthread' CXX='em++ -pthread' lib-mt V=1 \
  ZSTD_NO_ASM=1 PREFIX="$DEPS/zstd-install"
(cd lib && emmake make install-static install-includes ZSTD_NO_ASM=1 PREFIX="$DEPS/zstd-install")

cd "$DEPS"
echo "=== POCO ==="
rm -rf poco-poco-1.12.4-release && tar xzf poco-1.12.4-release.tar.gz && cd poco-poco-1.12.4-release
patch -p1 < "$ONLINE_SRC/wasm/poco-1.12.4-emscripten.patch"
mv XML/src/xmlparse.cpp XML/src/xmlparse.c
patch -p0 < "$ONLINE_SRC/wasm/poco-no-special-expat-sauce.diff"
emconfigure ./configure --static --no-samples --no-tests \
  --omit=Crypto,NetSSL_OpenSSL,JWT,Data,Data/SQLite,Data/ODBC,Data/MySQL,Data/PostgreSQL,Zip,PageCompiler,PageCompiler/File2Page,MongoDB,Redis,ActiveRecord,ActiveRecord/Compiler,Prometheus
emmake make -j"$LOWASM_JOBS" CC=emcc CXX=em++ \
  CXXFLAGS="-DPOCO_NO_LINUX_IF_PACKET_H -DPOCO_NO_INOTIFY -pthread -s USE_PTHREADS=1 -fwasm-exceptions"
make install INSTALLDIR="$DEPS/poco-install"

echo "=== deps done ==="
