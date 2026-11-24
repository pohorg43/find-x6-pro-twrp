#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-device/oplus/sm8550}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== Applying overlay and patches to $TARGET_DIR ==="

if [ ! -d "$TARGET_DIR" ]; then
    echo "ERROR: Target device tree directory $TARGET_DIR does not exist!" >&2
    exit 1
fi

# 1. Apply overlay files if any (excluding .gitkeep)
if [ -d "$REPO_ROOT/overlay" ]; then
    echo "Checking for overlay files in $REPO_ROOT/overlay..."
    find "$REPO_ROOT/overlay" -type f ! -name ".gitkeep" | while read -r src_file; do
        rel_path="${src_file#$REPO_ROOT/overlay/}"
        dest_file="$TARGET_DIR/$rel_path"
        echo "Applying overlay: $rel_path -> $dest_file"
        mkdir -p "$(dirname "$dest_file")"
        cp -f "$src_file" "$dest_file"
    done
fi

# 2. Apply patches if any
if [ -d "$REPO_ROOT/patches" ]; then
    echo "Checking for patches in $REPO_ROOT/patches..."
    for patch in "$REPO_ROOT/patches"/*.patch; do
        [ -e "$patch" ] || continue
        echo "Checking patch: $(basename "$patch")..."
        git -C "$TARGET_DIR" apply --check "$patch"
        echo "Applying patch: $(basename "$patch")..."
        git -C "$TARGET_DIR" apply "$patch"
    done
fi

# 3. Check for any rejected patch files (*.rej)
REJ_COUNT=$(find "$TARGET_DIR" -name "*.rej" | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
    echo "ERROR: Found $REJ_COUNT .rej files in $TARGET_DIR!" >&2
    find "$TARGET_DIR" -name "*.rej"
    exit 1
fi
echo "Verified: 0 *.rej files found."

# 4. Validate key patch expectations in BoardConfig.mk
BC="$TARGET_DIR/BoardConfig.mk"
if [ -f "$BC" ]; then
    echo "Validating BoardConfig.mk patch results..."
    grep -q "synaptics_tcm2.ko" "$BC" || { echo "ERROR: synaptics_tcm2.ko missing from BoardConfig.mk" >&2; exit 1; }
    grep -q "panel_event_notifier.ko" "$BC" || { echo "ERROR: panel_event_notifier.ko missing from BoardConfig.mk" >&2; exit 1; }
    grep -qE "PLATFORM_VERSION\s*:=\s*13(\s|$)" "$BC" || { echo "ERROR: PLATFORM_VERSION != 13 in BoardConfig.mk" >&2; exit 1; }
    grep -qE "PLATFORM_SECURITY_PATCH\s*:=\s*2025-11-01" "$BC" || { echo "ERROR: PLATFORM_SECURITY_PATCH != 2025-11-01 in BoardConfig.mk" >&2; exit 1; }
    grep -q "BOARD_BOOT_HEADER_VERSION" "$BC" || { echo "ERROR: BOARD_BOOT_HEADER_VERSION missing in BoardConfig.mk" >&2; exit 1; }
    grep -q "BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE" "$BC" || { echo "ERROR: BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE missing in BoardConfig.mk" >&2; exit 1; }
    
    # Check for NO duplicate --os_version in BOARD_MKBOOTIMG_ARGS
    if grep "BOARD_MKBOOTIMG_ARGS" "$BC" | grep -q -- "--os_version"; then
        echo "ERROR: Redundant --os_version found in BOARD_MKBOOTIMG_ARGS! Should rely cleanly on PLATFORM_VERSION." >&2
        exit 1
    fi
    echo "All BoardConfig.mk patch verifications passed cleanly (no duplicates)!"
fi

echo "=== Overlay and patches applied successfully ==="
