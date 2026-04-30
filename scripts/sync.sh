#!/bin/bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTON_DIR="$REPO_ROOT/.proton-src"

if [ -n "$1" ]; then
    NEW_TAG="$1"
else
    echo "→ Fetching latest native tag from proton-cachyos..."
    NEW_TAG=$(git ls-remote --tags https://github.com/CachyOS/proton-cachyos.git \
        | grep -o 'cachyos-[^ ]*-native' | sort -V | tail -1)
    if [ -z "$NEW_TAG" ]; then
        echo "✗ Could not determine latest tag. Pass it explicitly: $0 <tag>"
        exit 1
    fi
fi

CURRENT_TAG=$(cat "$REPO_ROOT/CACHYOS_TAG")
if [ "$NEW_TAG" = "$CURRENT_TAG" ] && [ -d "$PROTON_DIR" ]; then
    echo "→ Already on $NEW_TAG, nothing to do."
    exit 0
fi

echo "→ Syncing $CURRENT_TAG → $NEW_TAG"

# Update tag file
echo "$NEW_TAG" > "$REPO_ROOT/CACHYOS_TAG"

# Wipe build dir — shallow clone, easier to re-clone than rebase
if [ -d "$PROTON_DIR" ]; then
    echo "→ Removing old .proton-src (will re-clone)"
    rm -rf "$PROTON_DIR" 2>/dev/null || { chmod -R u+w "$PROTON_DIR" && rm -rf "$PROTON_DIR"; }
fi

echo "→ Fetching sources on new base"
"$REPO_ROOT/scripts/build.sh" --fetch

echo ""
echo "✓ Sync complete: $NEW_TAG"
echo ""
echo "  Next steps:"
echo "    1. Rebase or re-apply your patches (expect conflicts on a new base):"
echo "       ./scripts/build.sh --patch"
echo "    2. Once patches apply cleanly, build:"
echo "       ./scripts/build.sh dist"
