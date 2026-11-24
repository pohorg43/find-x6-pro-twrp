#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-device/oplus/sm8550}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -f "$REPO_ROOT/ci/twrp-spec.env" ]; then
    source "$REPO_ROOT/ci/twrp-spec.env"
fi

echo "=== Validating Device Tree in $TARGET_DIR ==="

# 1. Structure check
for required_file in "BoardConfig.mk" "device.mk" "AndroidProducts.mk" "recovery.fstab" "libinit/libinit_oplus_sm8550.cpp"; do
    if [ ! -f "$TARGET_DIR/$required_file" ]; then
        echo "ERROR: Required file $required_file not found in $TARGET_DIR" >&2
        exit 1
    fi
    echo "✓ Found $required_file"
done

# 2. Partition size check
BC="$TARGET_DIR/BoardConfig.mk"
PART_SIZE_LINE=$(grep "BOARD_RECOVERYIMAGE_PARTITION_SIZE" "$BC" | tr -d ' ' || true)
if [[ "$PART_SIZE_LINE" != *"104857600"* && "$PART_SIZE_LINE" != *"0x6400000"* ]]; then
    echo "ERROR: Invalid recovery partition size in BoardConfig.mk: $PART_SIZE_LINE (expected 104857600)" >&2
    exit 1
fi
echo "✓ Recovery partition size validated: 104857600 bytes"

# 3. Touchscreen modules check
for mod in synaptics_tcm2.ko panel_event_notifier.ko olc.ko oplus_bsp_tp_custom.ko oplus_bsp_tp_comon.ko; do
    if ! grep -q "$mod" "$BC"; then
        echo "ERROR: Required touch module $mod missing from BoardConfig.mk" >&2
        exit 1
    fi
    echo "✓ Touch module registered: $mod"
done

# 4. Header parameters check
if ! grep -q -- "--os_version 13.0.0" "$BC" || ! grep -q -- "--os_patch_level 2025-11" "$BC"; then
    echo "ERROR: OS version / patch level mismatch in BoardConfig.mk (expected 13.0.0 / 2025-11)" >&2
    exit 1
fi
echo "✓ OS version 13.0.0 and patch level 2025-11 validated"

# 5. Remote manifest accessibility check
MANIFEST_URL="${REF_MANIFEST_A16:-https://github.com/TWRP-Test/platform_manifest_twrp_aosp}"
MANIFEST_BRANCH="${REF_MANIFEST_BRANCH:-twrp-16.0}"
echo "Checking remote manifest: $MANIFEST_URL ($MANIFEST_BRANCH)..."
git ls-remote --exit-code "$MANIFEST_URL" "refs/heads/$MANIFEST_BRANCH" >/dev/null
echo "✓ Manifest branch $MANIFEST_BRANCH exists and is reachable!"

echo "=== All device validations PASSED ==="
