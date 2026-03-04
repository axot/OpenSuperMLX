#!/bin/bash
# Resolve SPM packages and apply patches to mlx-audio-swift.
# Ensures SourcePackages/checkouts exists before patching.
# Idempotent — safe to call multiple times.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_DIR="$PROJECT_DIR/SourcePackages/checkouts/mlx-audio-swift"

echo "Resolving SPM packages..."
xcodebuild -resolvePackageDependencies \
  -scheme OpenSuperMLX \
  -clonedSourcePackagesDirPath "$PROJECT_DIR/SourcePackages" \
  -quiet

if [[ ! -d "$CHECKOUT_DIR" ]]; then
    echo "❌ mlx-audio-swift checkout not found at $CHECKOUT_DIR after resolve"
    exit 1
fi

echo "Applying patches to mlx-audio-swift..."
for p in "$PROJECT_DIR"/patches/*.patch; do
    if [[ -f "$p" ]]; then
        if patch --dry-run -N -p1 -d "$CHECKOUT_DIR" < "$p" >/dev/null 2>&1; then
            echo "  Applying $(basename "$p")..."
            patch -N -p1 -d "$CHECKOUT_DIR" < "$p"
        else
            echo "  Skipping $(basename "$p") (already applied or N/A)"
        fi
    fi
done

echo "✅ SPM packages resolved and patches applied."
