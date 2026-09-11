#!/bin/bash
# Apply the spinner styling to a built browser/dist.
#
# Branding removal itself now happens at the SOURCE level, not here:
#   - online/configure.ac       APP_NAME default is "" when $host_os=emscripten
#   - online/browser/html/cool.html.m4   branding hidden-input placeholders are
#                                        hardcoded empty for EMSCRIPTENAPP builds;
#                                        the About dialog's <h1> ships empty
#   - online/browser/src/control/Control.NotebookbarWriter.js
#                                        Forum/Online Help/Report an issue/About
#                                        are filtered out of the Help tab when
#                                        window.ThisIsTheEmscriptenApp is true
# All three are scoped to the WASM build only, so a normal Collabora Online
# server build from the same tree is unaffected and keeps real branding.
#
# What THIS script still does is a genuine visual choice, not a branding fix:
# Collabora's runtime-built loading screen (.leaflet-progress-layer, created by
# bundle.js -- there is no static markup for it) is restyled into a plain
# spinner with our own copy. That has no source-level equivalent to edit, so it
# stays a post-build CSS override. Pure CSS, no JavaScript: the host page and
# the engine page stay fully isolated.
#
# Must still run after every Online build: branding.css/branding.js are files
# in dist/, which a build does not otherwise create (the <link>/<script> tags
# for them are in cool.html.m4, expecting a real deployment to supply them).
#
# One "Collabora" occurrence survives inside online.wasm itself -- a baked
# string pool from --with-vendor=Collabora in core's distro config, reachable
# only via the About dialog, which no longer exists in the UI. Fixing that is a
# core rebuild, deferred until something else next touches core.
set -uo pipefail
D=${1:?usage: debrand.sh <browser/dist>}

echo "  applying spinner styling to $D"

: > "$D/branding.js"
cat > "$D/branding.css" <<'CSS'
/* Replace Collabora's splash with a neutral spinner. The splash is built at
   runtime by bundle.js, so it is styled rather than edited. Structure
   (verified in the live DOM):
     .leaflet-progress-layer
       .leaflet-progress-spinner
       .leaflet-progress-label.brand-label   product name (empty from source)
       .leaflet-progress-label               "Initializing..."
       .leaflet-progress                     the 0% bar
   Text is swapped with ::after because CSS cannot rewrite a text node.
   ASCII only: this file has no @charset and would otherwise inherit the
   document encoding and mojibake the ellipsis. */

/* Do NOT reposition this layer: Collabora already places and centres it, and
   forcing position:absolute/inset:0 re-anchors it to a different ancestor and
   clips it off the left edge (confirmed by trying it). Only restyle what is
   inside it. */
.leaflet-progress-layer {
    background: #ffffff;
    border: 0;
    box-shadow: none;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    min-width: 220px;
    padding: 18px 24px;
}

.leaflet-progress-layer .brand-label,
.leaflet-progress-layer .leaflet-progress { display: none !important; }
#integrator-logo, #product-logo, .logo { display: none !important; }

/* LOWASM (do not re-add a spinner rule on .leaflet-progress-spinner): that div
   is not a decorative element to restyle. online/browser/src/layer/marker/ProgressOverlay.js
   creates a real <canvas class="leaflet-progress-spinner-canvas"> INSIDE it,
   and online/browser/src/app/LOUtil.ts's startSpinner() draws an actual rotating arc onto it
   every 30ms (lineWidth 8, strokeStyle "grey" -- already plain grey, no
   vendor colour). A CSS ring was added here once to *replace* that visual;
   instead it stacked as a second ring around the real one ("spinner spinning
   around the spinner", confirmed from a screenshot). The canvas spinner is
   the whole fix here -- nothing to hide, nothing to add. */

/* The compact-menu chrome (Control.Menubar.ts, distinct from the ribbon/
   notebookbar chrome) creates an empty file-type-icon slot: it only sets a
   background image "if (window.logoURL)" -- no fallback -- and logoURL is
   always empty now, so it rendered as a bare focusable 30x30 box. Confirmed
   via DevTools: <a class="document-logo" role="img" aria-label="file type
   icon"></a>, no background-image, no visible content.
   The RIBBON chrome (Control.Notebookbar.js) has a real per-doc-type icon
   fallback and must stay -- it is not this element. The two are otherwise
   identical (both id="document-header", both class="document-logo"), but
   only the ribbon's <a> also carries id="document-logo" on the anchor
   itself, so that is the selector that tells them apart. */
a.document-logo:not(#document-logo) { display: none !important; }

/* Two loading indicators showed simultaneously on first open: the centered
   spinner above (bundle.js toggles .leaflet-progress-layer's visibility) AND
   a separate thin bar under the document title in the toolbar
   (#document-name-input-loading-bar, an indeterminate animated bar --
   menubar.css:22 moveIndicator -- toggled independently). Keep only the
   centered one; #document-name-input-progress-bar is the sibling determinate
   variant of the same slot (menubar.css:54-55 styles both identically) and is
   hidden for the same reason. */
#document-name-input-loading-bar,
#document-name-input-progress-bar,
#mobile-progress-bar { display: none !important; }

/* replace "Initializing..." with our own copy. nowrap stops it breaking
   across two lines inside the narrow container Collabora sizes for it. */
.leaflet-progress-layer .leaflet-progress-label:not(.brand-label) {
    font-size: 0;
    white-space: nowrap;
    width: auto;
    max-width: none;
}
.leaflet-progress-layer .leaflet-progress-label:not(.brand-label)::after {
    content: "Loading the document...";
    font: 14px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif;
    color: #6b7280;
    white-space: nowrap;
}
CSS
cp -f "$D/branding.css" "$D/branding-desktop.css"
cp -f "$D/branding.css" "$D/branding-mobile.css"

echo "  'Collabora' left in cool.html: $(grep -c 'Collabora' "$D/cool.html" || true)   (0 expected -- source-level now)"
