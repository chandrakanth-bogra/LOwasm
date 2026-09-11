#!/bin/bash
# Serve a built payload locally for testing, via nginx in a container.
#
#   serve.sh [dist] [port] [docs-dir]
#     dist      the browser/dist to serve       (default: $DIST)
#     port      host port                       (default: 18081)
#     docs-dir  documents to open               (optional)
#
# Open http://127.0.0.1:<port>/cool.html?WOPISrc=<file in docs-dir>
#
# The engine currently fetches documents from /cowasm-wopi/wasm/<name>, so
# docs-dir is served at that path. (That prefix is due to become
# host-configurable.)
#
# Cross-origin isolation is mandatory: the module is threaded WASM and needs
# SharedArrayBuffer, so COOP/COEP go on every response. .wasm must be
# application/wasm or the browser refuses to stream-compile it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

SERVE_DIST=$(cd "${1:-$DIST}" && pwd) || die "no dist directory"
PORT=${2:-18081}
DOCS=${3:-}
[ -f "$SERVE_DIST/cool.html" ] || die "$SERVE_DIST has no cool.html -- build first"

docs_mount=()
if [ -n "$DOCS" ]; then
  DOCS=$(cd "$DOCS" && pwd) || die "no docs directory: $DOCS"
  docs_mount=(-v "$DOCS:/docs:ro")
fi

CONF=$(mktemp "${TMPDIR:-/tmp}/lowasm-nginx.XXXX.conf")
cat > "$CONF" <<'NGINX'
server {
    listen 80;
    root /usr/share/nginx/html;
    index cool.html;
    # nginx add_header does NOT inherit into a location that sets its own, so
    # every location below repeats COOP/COEP/CORP.
    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Embedder-Policy "require-corp" always;
    add_header Cross-Origin-Resource-Policy "same-origin" always;
    add_header Cache-Control "public, max-age=0, must-revalidate" always;
    etag on;
    location = /cool.html {
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Embedder-Policy "require-corp" always;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
        add_header Cache-Control "no-store" always;
    }
    # The ~260 MB of wasm + filesystem image dominate load; immutable lets a
    # plain reload come from disk cache and V8 reuse its compiled-wasm cache.
    # Not content-hashed here, so hard-reload once after each rebuild.
    location ~ \.(wasm|data)$ {
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Embedder-Policy "require-corp" always;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
    }
    location /cowasm-wopi/wasm/ {
        alias /docs/;
        add_header Cross-Origin-Opener-Policy "same-origin" always;
        add_header Cross-Origin-Embedder-Policy "require-corp" always;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
        add_header Cache-Control "no-store" always;
    }
    gzip on;
    gzip_types application/wasm application/octet-stream text/javascript text/css application/json;
    gzip_min_length 4096;
    types {
        text/html html;
        text/javascript js;
        text/css css;
        application/wasm wasm;
        application/json json;
        image/svg+xml svg;
        image/png png;
        font/woff2 woff2;
    }
    default_type application/octet-stream;
    location / { try_files $uri $uri/ =404; }
}
NGINX

echo "serving $SERVE_DIST on http://127.0.0.1:$PORT"
[ -n "$DOCS" ] && echo "  documents from $DOCS:  http://127.0.0.1:$PORT/cool.html?WOPISrc=<file>"
exec docker run --rm -p "$PORT:80" \
    -v "$SERVE_DIST:/usr/share/nginx/html:ro" \
    "${docs_mount[@]}" \
    -v "$CONF:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine
