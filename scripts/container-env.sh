# Prelude for every step run inside the builder image. Sourced, never run.
#
# 1. git safe.directory: the image's emsdk checkout is owned by its `builder`
#    user, and emcc's --version handler shells out to `git rev-parse HEAD`
#    there. The image's git (2.34) refuses with "dubious ownership" for any
#    other uid and predates the `safe.directory=*` wildcard, so the exact path
#    is whitelisted into the writable HOME.
# 2. EM_CACHE lives on a bind mount so the compiled sysroot (libc++ etc., in
#    the -pthread -fwasm-exceptions flavour) survives between container runs.
# 3. Node 20 ahead of the image's own. The image ships Node v12, which cannot
#    parse `??`, so Online's browser/ TypeScript build dies in a transitive
#    minimatch with "SyntaxError: Unexpected token '?'". configure substitutes
#    an absolute node path into the makefiles, so this must be on PATH *before*
#    configure runs, not just before make.

source "$LOWASM_ROOT/scripts/config.sh"

export HOME=${HOME:-/tmp}
git config --global --add safe.directory /home/builder/emsdk/emscripten/main 2>/dev/null || true
export EM_CACHE=$EMCACHE
export PATH=$NODE_DIR/bin:$PATH
source /home/builder/emsdk/emsdk_env.sh >/dev/null 2>&1
# emsdk_env.sh prepends its own bundled node; put ours back in front.
export PATH=$NODE_DIR/bin:$PATH
