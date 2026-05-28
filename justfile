# Iris repo task runner. See plans/features/demo-sim-runnable.md.
#
# Recipes are demo/dev ergonomics only — no library build steps live here.

# Copy a video file into the booted iOS Simulator's IrisDemo Documents folder,
# so it shows up under the in-app document picker (Files → On My iPhone →
# Iris Demo). The app must already be installed on the booted simulator
# (run it once from Xcode first).
#
#   just sim-add-video ~/Movies/clip.mov
sim-add-video path:
    #!/usr/bin/env bash
    set -euo pipefail

    SRC="{{path}}"
    if [ ! -f "$SRC" ]; then
        echo "error: no such file: $SRC" >&2
        exit 1
    fi

    # The bundle id is per-developer and gitignored — resolve it from the
    # xcconfig rather than hardcoding. The iOS target's Shared.xcconfig does
    # `#include? "Local.xcconfig"` relative to Apps/IrisDemo-iOS/, so that
    # per-target file is authoritative; repo-level Apps/Local.xcconfig is a
    # fallback only (it may hold a stale id the target doesn't actually use).
    XCCONFIG=""
    for candidate in "Apps/IrisDemo-iOS/Local.xcconfig" "Apps/Local.xcconfig"; do
        if [ -f "$candidate" ]; then
            XCCONFIG="$candidate"
            break
        fi
    done
    if [ -z "$XCCONFIG" ]; then
        echo "error: Local.xcconfig not found (looked in Apps/ and Apps/IrisDemo-iOS/)." >&2
        echo "       Copy Apps/Local.xcconfig.template and fill in PRODUCT_BUNDLE_IDENTIFIER." >&2
        exit 1
    fi

    BUNDLE_ID="$(rg -m1 '^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=' "$XCCONFIG" \
        | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')"
    if [ -z "$BUNDLE_ID" ]; then
        echo "error: PRODUCT_BUNDLE_IDENTIFIER not set in $XCCONFIG." >&2
        exit 1
    fi

    # Locate the app's data container on the booted sim. Fails if no sim is
    # booted, or the app isn't installed.
    if ! CONTAINER="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)"; then
        echo "error: couldn't find the app container for '$BUNDLE_ID'." >&2
        echo "       Make sure a simulator is booted AND IrisDemo is installed on it" >&2
        echo "       (run/install the app on the sim once from Xcode first)." >&2
        exit 1
    fi

    DEST="$CONTAINER/Documents"
    mkdir -p "$DEST"
    cp "$SRC" "$DEST/"
    echo "Copied $(basename "$SRC") → $DEST/"
    echo "Open it in the demo via Pick video → Files → On My iPhone → Iris Demo."
