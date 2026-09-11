#!/bin/bash
# Full build from a clean checkout: setup -> deps -> core -> Online payload.
#
# Each step can also be run on its own; all of them read scripts/config.sh.
# Core is by far the longest step (hours) and its final link needs more than
# 7.4 GiB of memory -- see build-core.sh.
set -euo pipefail
S=$(dirname "${BASH_SOURCE[0]}")

"$S/setup.sh"
"$S/build-deps.sh"
"$S/build-core.sh"
"$S/finish.sh"
