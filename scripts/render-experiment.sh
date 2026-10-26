#!/bin/bash
# Launch a disposable synthetic-data comparison; Ctrl-C verifies owned app exit.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-}"
EVIDENCE="${2:-}"
if [ -z "$EVIDENCE" ]; then
    echo "Usage: $0 baseline|signals|topology|layers|selection|hosts|panels|viewport|hidden|all /absolute/new/evidence-directory [--website URL ...]" >&2
    exit 2
fi
export VANE_RENDER_EXPERIMENT=1
export VANE_RENDER_SIGNALS=0 VANE_RENDER_TOPOLOGY=0 VANE_RENDER_LAYERS=0
export VANE_RENDER_SELECTION=0 VANE_RENDER_HOST_REUSE=0 VANE_RENDER_PANEL_MOTION=0
export VANE_RENDER_VIEWPORT=0 VANE_RENDER_HIDDEN=0
export VANE_DIAG_SCROLL_TRACE=1
case "$MODE" in
    baseline) export VANE_RENDER_EXPERIMENT=0 ;;
    signals) export VANE_RENDER_SIGNALS=1 ;;
    topology) export VANE_RENDER_TOPOLOGY=1 ;;
    layers) export VANE_RENDER_LAYERS=1 ;;
    selection) export VANE_RENDER_SELECTION=1 ;;
    hosts) export VANE_RENDER_HOST_REUSE=1 ;;
    panels) export VANE_RENDER_PANEL_MOTION=1 ;;
    viewport) export VANE_RENDER_VIEWPORT=1 ;;
    hidden) export VANE_RENDER_HIDDEN=1 ;;
    all)
        export VANE_RENDER_SIGNALS=1 VANE_RENDER_TOPOLOGY=1 VANE_RENDER_LAYERS=1
        export VANE_RENDER_SELECTION=1 VANE_RENDER_HOST_REUSE=1 VANE_RENDER_PANEL_MOTION=1
        export VANE_RENDER_VIEWPORT=1 VANE_RENDER_HIDDEN=1 ;;

    *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
shift 2
if [ "$#" -eq 0 ]; then
    set -- --website "https://en.wikipedia.org/wiki/Swift_(programming_language)" \
        --website "https://github.com/notnaki/vane" \
        --website "https://developer.mozilla.org/en-US/docs/Web/JavaScript"
fi
swift build -c release -j 4
PRODUCTS="$(swift build -c release --show-bin-path)"
exec python3 scripts/ui-responsiveness-fixture.py --binary "$PRODUCTS/vane" --evidence "$EVIDENCE" --large "$@"
