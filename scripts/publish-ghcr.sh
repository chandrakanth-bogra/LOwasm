#!/bin/bash
# Publish a built payload to GHCR as a runnable nginx image.
#
#   GHCR_TOKEN=<PAT with write:packages> scripts/publish-ghcr.sh [dist]
#
#   GHCR_OWNER   GitHub owner      (default: parsed from the origin remote)
#   GHCR_IMAGE   image name        (default: lowasm)
#   GHCR_TAG     primary tag       (default: the short HEAD sha)
#   GHCR_LATEST  also tag :latest  (default: 1)
#   GHCR_PUSH    push after build  (default: 1; set 0 to build only)
#
# GHCR stores the payload; it cannot serve it. Registry blobs need a token
# exchange, carry no CORS headers and are tar layers rather than files, so no
# browser can fetch them -- and no GitHub-hosted alternative can either (Pages
# and raw cap files at 100 MB against a 175 MB online.wasm; release assets send
# no Access-Control-Allow-Origin and Content-Disposition: attachment). Pull the
# image and serve it, or copy its files into a web server you already run.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

SERVE_DIST=$(cd "${1:-$DIST}" 2>/dev/null && pwd) || die "no payload directory: ${1:-$DIST}"
[ -f "$SERVE_DIST/online.wasm" ] || die "$SERVE_DIST has no online.wasm -- run scripts/finish.sh first"
[ -f "$SERVE_DIST/lowasm.js" ] || die "$SERVE_DIST predates the host API (no lowasm.js) -- rebuild"

command -v git >/dev/null || die "git is required"
cd "$LOWASM_ROOT"

# Docker may not be reachable directly: a shell started before the user was
# added to the `docker` group has no such membership. sg re-runs the command
# with it, which is why every docker call below goes through docker_run.
if docker info >/dev/null 2>&1; then
  docker_run() { docker "$@"; }
elif id -nG | tr ' ' '\n' | grep -qx docker || getent group docker | grep -q "\b$(id -un)\b"; then
  docker_run() { sg docker -c "docker $(printf '%q ' "$@")"; }
else
  die "cannot reach the docker daemon, and $(id -un) is not in the docker group"
fi

OWNER=${GHCR_OWNER:-$(git remote get-url origin 2>/dev/null |
  sed -E 's#^git@github.com:#https://github.com/#; s#^https://github.com/##; s#/.*##')}
[ -n "$OWNER" ] || die "cannot determine the GitHub owner -- set GHCR_OWNER"
IMAGE=${GHCR_IMAGE:-lowasm}
TAG=${GHCR_TAG:-$(git rev-parse --short HEAD)}
REPO="ghcr.io/$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')/$IMAGE"

# A payload older than HEAD is the one failure mode worth refusing outright: the
# tag would name a commit whose code is not in the image.
head_time=$(git log -1 --format=%ct)
dist_time=$(stat -c %Y "$SERVE_DIST/online.wasm")
if [ "$dist_time" -lt "$head_time" ]; then
  die "$SERVE_DIST/online.wasm is older than HEAD ($(git rev-parse --short HEAD)) -- rebuild before publishing"
fi
[ -z "$(git status --porcelain -- online core scripts tools docker)" ] ||
  echo "WARNING: tracked sources are modified; :$TAG will not match the committed tree"

# The build context is a directory holding the Dockerfile, its nginx config and
# the payload. Three constraints shape how it is assembled:
#
#  - docker refuses a symlink that leaves the context, so dist cannot simply be
#    linked in; it has to be a real directory entry.
#  - this daemon has only the legacy builder (no buildx, no --build-context), so
#    BuildKit named contexts are not available either.
#  - the context therefore lives under $LOWASM_BUILD rather than /tmp: they are
#    different filesystems here, and `cp -al` only hardlinks within one. With
#    hardlinks the ~311 MB payload costs no extra space and no copy time (the
#    daemon still reads the bytes when it tars the context; that is unavoidable).
CTX=$(mktemp -d "$LOWASM_BUILD/ghcr-ctx.XXXXXX") || die "cannot create a build context in $LOWASM_BUILD"
trap 'rm -rf "$CTX"' EXIT
cp "$LOWASM_ROOT/docker/Dockerfile.payload" "$CTX/Dockerfile"
cp "$LOWASM_ROOT/docker/nginx-payload.conf" "$CTX/"
cp -al "$SERVE_DIST" "$CTX/dist" 2>/dev/null || cp -a "$SERVE_DIST" "$CTX/dist" ||
  die "cannot stage $SERVE_DIST into the build context"

echo "=== building $REPO:$TAG from $SERVE_DIST ==="
tags=(-t "$REPO:$TAG")
[ "${GHCR_LATEST:-1}" = 1 ] && tags+=(-t "$REPO:latest")
docker_run build --pull "${tags[@]}" "$CTX" || die "docker build failed"

if [ "${GHCR_PUSH:-1}" != 1 ]; then
  echo "=== built, not pushed (GHCR_PUSH=0) ==="
  docker_run image ls "$REPO"
  exit 0
fi

[ -n "${GHCR_TOKEN:-}" ] || die "GHCR_TOKEN is not set (needs a PAT with write:packages)"
echo "=== logging in to ghcr.io as $OWNER ==="
printf '%s' "$GHCR_TOKEN" | docker_run login ghcr.io -u "$OWNER" --password-stdin ||
  die "docker login failed"

for t in "$TAG" $([ "${GHCR_LATEST:-1}" = 1 ] && echo latest); do
  echo "=== pushing $REPO:$t ==="
  docker_run push "$REPO:$t" || die "push failed for $REPO:$t"
done

cat <<EOF
=== published ===
  $REPO:$TAG
Serve it:
  docker run --rm -p 8080:80 $REPO:$TAG
  open http://127.0.0.1:8080/lowasm-test.html?doc=<name>   # with documents at /docs/
Extract it (init container, CI, or locally):
  id=\$(docker create $REPO:$TAG) && docker cp \$id:/usr/share/nginx/html ./lowasm && docker rm \$id
EOF
