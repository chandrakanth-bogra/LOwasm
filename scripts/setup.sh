#!/bin/bash
# Fetch the pinned host-side inputs: Node 20, and the zstd + POCO sources.
#
# Every download is checked against a SHA-256 recorded from the build that was
# verified to render, so a changed or truncated file stops here rather than
# failing obscurely hours into a build.
#
# LibreOffice's own ~90 external tarballs are NOT fetched here: core's build
# downloads whatever is missing into $EXT_SOURCES itself. Point
# LOWASM_EXT_SOURCES at an existing mirror to skip that.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

fetch() { # <url> <sha256> <dest>
  local url=$1 sum=$2 dest=$3
  if [ -f "$dest" ] && echo "$sum  $dest" | sha256sum -c --quiet 2>/dev/null; then
    echo "  have $(basename "$dest")"
    return
  fi
  echo "  fetching $url"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL --retry 3 -o "$dest.part" "$url" || die "download failed: $url"
  echo "$sum  $dest.part" | sha256sum -c --quiet \
    || die "checksum mismatch for $url -- refusing to use it"
  mv "$dest.part" "$dest"
}

echo "=== Node 20 ==="
if [ -x "$NODE_DIR/bin/node" ]; then
  echo "  have $("$NODE_DIR/bin/node" --version) at $NODE_DIR"
else
  NODE_TAR=$LOWASM_BUILD/downloads/node-v20.18.1-linux-x64.tar.xz
  fetch https://nodejs.org/dist/v20.18.1/node-v20.18.1-linux-x64.tar.xz \
    c6fa75c841cbffac851678a472f2a5bd612fff8308ef39236190e1f8dbb0e567 "$NODE_TAR"
  mkdir -p "$NODE_DIR"
  tar -xJf "$NODE_TAR" -C "$NODE_DIR" --strip-components=1
  echo "  installed $("$NODE_DIR/bin/node" --version) at $NODE_DIR"
fi

echo "=== zstd + POCO sources ==="
fetch https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz \
  7c42d56fac126929a6a85dbc73ff1db2411d04f104fae9bdea51305663a83fd0 \
  "$DEPS/zstd-1.5.2.tar.gz"
fetch https://github.com/pocoproject/poco/archive/refs/tags/poco-1.12.4-release.tar.gz \
  71ef96c35fced367d6da74da294510ad2c912563f12cd716ab02b6ed10a733ef \
  "$DEPS/poco-1.12.4-release.tar.gz"

echo "=== pulling builder image ==="
docker pull "$LOWASM_IMAGE" >/dev/null && echo "  $LOWASM_IMAGE"

echo "setup done"
