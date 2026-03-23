#!/bin/bash
# Resolve SPM packages and apply patches to dependencies.
# Ensures SourcePackages/checkouts exists before patching.
# Idempotent — safe to call multiple times.
#
# Patch layout: patches/<package-name>/*.patch
# Each subdirectory name must match the checkout directory name under SourcePackages/checkouts/.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKOUTS_DIR="$PROJECT_DIR/SourcePackages/checkouts"

echo "Resolving SPM packages..."
xcodebuild -resolvePackageDependencies \
  -scheme OpenSuperMLX \
  -clonedSourcePackagesDirPath "$PROJECT_DIR/SourcePackages" \
  -quiet

for pkg_dir in "$PROJECT_DIR"/patches/*/; do
    [[ -d "$pkg_dir" ]] || continue
    pkg_name="$(basename "$pkg_dir")"
    checkout_dir="$CHECKOUTS_DIR/$pkg_name"

    if [[ ! -d "$checkout_dir" ]]; then
        echo "⏭️  Skipping $pkg_name (not an SPM checkout)"
        continue
    fi

    echo "Applying patches to $pkg_name..."
    for p in "$pkg_dir"/*.patch; do
        [[ -f "$p" ]] || continue
        if patch --dry-run -N -p1 -d "$checkout_dir" < "$p" >/dev/null 2>&1; then
            echo "  Applying $(basename "$p")..."
            patch -N -p1 -d "$checkout_dir" < "$p"
        else
            echo "  Skipping $(basename "$p") (already applied or N/A)"
        fi
    done
done

echo "✅ SPM packages resolved and patches applied."
