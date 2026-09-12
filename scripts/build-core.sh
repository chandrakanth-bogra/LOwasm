#!/bin/bash
# Configure and build LibreOffice core (Collabora co-25.04) for WebAssembly.
#
#   build-core.sh                  configure if needed, then build
#   build-core.sh --configure-only configure and stop
#   build-core.sh --reconfigure    configure again, then build
#
# Configured with Collabora's CPWASM-LOKit distro config. Impress, Draw, Math and
# canvas are kept by core/config_host.mk.in itself (see that commit), so no
# post-configure edit is needed.
#
# MEMORY: the final soffice.js link needs more than 7.4 GiB on its own. If this
# machine also runs a Kubernetes cluster, stop it first -- Kubernetes sets
# oom_score_adj=996 on its pods, so a global OOM kills them before the linker.
# An interrupted link resumes: make is incremental.
#
# Runs itself inside the builder image. LOWASM_JOBS sets the parallelism.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
if [ -z "${LOWASM_IN_BUILDER:-}" ]; then
  in_builder "bash '$LOWASM_ROOT/scripts/build-core.sh' ${1:-}"
  exit $?
fi
source "$LOWASM_ROOT/scripts/container-env.sh"

mode=${1:-}
case "$mode" in ""|--configure-only|--reconfigure) ;; *) die "unknown option: $mode" ;; esac

mkdir -p "$CORE_BUILD" "$EXT_SOURCES"
cd "$CORE_BUILD"

if [ ! -f config_host.mk ] || [ -n "$mode" ]; then
  echo "=== configuring core in $CORE_BUILD ==="
  # autogen.sh run from an out-of-tree build directory symlinks the source in
  # and passes --srcdir; --with-distro expands distro-configs/CPWASM-LOKit.conf.
  "$CORE_SRC/autogen.sh" \
    --with-distro=CPWASM-LOKit \
    --with-external-tar="$EXT_SOURCES" \
    --with-parallelism="$LOWASM_JOBS" \
    --disable-ccache
fi
[ "$mode" = --configure-only ] && { echo "=== configured ==="; exit 0; }

echo "=== building core (parallelism $LOWASM_JOBS) ==="
# PARALLELISM is baked into config_host.mk at configure time, so passing it here
# too is what lets LOWASM_JOBS take effect on an already-configured tree --
# otherwise a 64-core box silently keeps whatever the first configure recorded.
make -r PARALLELISM="$LOWASM_JOBS"
echo "=== core done ==="
