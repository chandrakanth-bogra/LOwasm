# Shared configuration for the LOwasm build scripts. Sourced, never run.
#
# Every path is derived from the checkout or overridable from the environment,
# so nothing depends on a username or a fixed location on disk.
#
#   LOWASM_BUILD         build tree root              (default: <checkout>/build)
#   LOWASM_JOBS          parallelism for core          (default: nproc)
#   LOWASM_ONLINE_JOBS   parallelism for Online        (default: 3)
#   LOWASM_CXXFLAGS      Online CXXFLAGS               (default: -g -O1, see README)
#   LOWASM_IMAGE         builder container image
#   LOWASM_CORE_BUILD, LOWASM_ONLINE_BUILD, LOWASM_DEPS,
#   LOWASM_EXT_SOURCES, LOWASM_NODE, LOWASM_EMCACHE
#                        override individual directories, e.g. to reuse an
#                        existing core build or a local mirror of ext_sources
#   LOWASM_EXTRA_MOUNTS  space-separated extra directories to bind-mount into
#                        the builder, e.g. a source tree an existing core build
#                        symlinks into

LOWASM_ROOT=${LOWASM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
LOWASM_BUILD=${LOWASM_BUILD:-$LOWASM_ROOT/build}
LOWASM_IMAGE=${LOWASM_IMAGE:-public.ecr.aws/allotropia/libo-builders/wasm}
LOWASM_JOBS=${LOWASM_JOBS:-$(nproc)}
# Online's link is the memory-hungry step, not its compile, but -j3 is what the
# verified build used on a 14 GB machine. Raise it on a bigger box.
LOWASM_ONLINE_JOBS=${LOWASM_ONLINE_JOBS:-3}
# -O1, not the upstream -O2 default: the -O2 link runs LTO and peaks at ~12 GiB
# resident versus ~1.6 GiB at -O1 (wasm/README records 12261016maxresident).
# -g forces *limited* binaryen post-link optimisation (wasm/Makefile.am silences
# the warning), and the DWARF is stripped again afterwards by finish.sh -- so on
# a machine with the memory, drop -g and try -O2. One change per build.
LOWASM_CXXFLAGS=${LOWASM_CXXFLAGS:--g -O1}

CORE_SRC=$LOWASM_ROOT/core
ONLINE_SRC=$LOWASM_ROOT/online
CORE_BUILD=${LOWASM_CORE_BUILD:-$LOWASM_BUILD/core}
ONLINE_BUILD=${LOWASM_ONLINE_BUILD:-$LOWASM_BUILD/online}
DEPS=${LOWASM_DEPS:-$LOWASM_BUILD/deps}
EXT_SOURCES=${LOWASM_EXT_SOURCES:-$LOWASM_BUILD/ext_sources}
NODE_DIR=${LOWASM_NODE:-$LOWASM_BUILD/node20}
EMCACHE=${LOWASM_EMCACHE:-$LOWASM_BUILD/emcache}
DIST=$ONLINE_BUILD/browser/dist

die() { echo "ERROR: $*" >&2; exit 1; }

# Run a command inside the builder image.
#
# Every directory the build touches is bind-mounted at its *own* absolute path:
# core's build files embed absolute paths, so they must resolve identically
# inside and outside the container.
in_builder() {
  command -v docker >/dev/null || die "docker is required"
  local mounts=() seen=" " d
  for d in "$LOWASM_ROOT" "$LOWASM_BUILD" "$CORE_BUILD" "$ONLINE_BUILD" "$DEPS" \
           "$EXT_SOURCES" "$NODE_DIR" "$EMCACHE" ${LOWASM_EXTRA_MOUNTS:-}; do
    mkdir -p "$d"
    d=$(cd "$d" && pwd)
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "
    mounts+=(-v "$d:$d")
  done
  docker run --rm --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e CC_FOR_BUILD=gcc-12 -e CXX_FOR_BUILD=g++-12 \
    -e LOWASM_IN_BUILDER=1 \
    -e LOWASM_ROOT="$LOWASM_ROOT" -e LOWASM_BUILD="$LOWASM_BUILD" \
    -e LOWASM_JOBS="$LOWASM_JOBS" -e LOWASM_ONLINE_JOBS="$LOWASM_ONLINE_JOBS" \
    -e LOWASM_CXXFLAGS="$LOWASM_CXXFLAGS" \
    -e LOWASM_CORE_BUILD="$CORE_BUILD" -e LOWASM_ONLINE_BUILD="$ONLINE_BUILD" \
    -e LOWASM_DEPS="$DEPS" -e LOWASM_EXT_SOURCES="$EXT_SOURCES" \
    -e LOWASM_NODE="$NODE_DIR" -e LOWASM_EMCACHE="$EMCACHE" \
    "${mounts[@]}" "$LOWASM_IMAGE" \
    /bin/bash -c "$1"
}
