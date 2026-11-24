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

# 4. Header parameters check via PLATFORM_VERSION and PLATFORM_SECURITY_PATCH
if ! grep -qE "PLATFORM_VERSION\s*:=\s*13.0.0" "$BC" || ! grep -qE "PLATFORM_SECURITY_PATCH\s*:=\s*2025-11-01" "$BC"; then
    echo "ERROR: PLATFORM_VERSION / PLATFORM_SECURITY_PATCH mismatch in BoardConfig.mk (expected 13.0.0 / 2025-11-01)" >&2
    exit 1
fi
echo "✓ Canonical header config validated: PLATFORM_VERSION=13.0.0 and PLATFORM_SECURITY_PATCH=2025-11-01"

# 5. Remote manifest accessibility check
MANIFEST_URL="${REF_MANIFEST_A16:-https://github.com/TWRP-Test/platform_manifest_twrp_aosp}"
MANIFEST_BRANCH="${REF_MANIFEST_BRANCH:-twrp-16.0}"
echo "Checking remote manifest: $MANIFEST_URL ($MANIFEST_BRANCH)..."
git ls-remote --exit-code "$MANIFEST_URL" "refs/heads/$MANIFEST_BRANCH" >/dev/null
echo "✓ Manifest branch $MANIFEST_BRANCH exists and is reachable!"

# 6. Validate local prune manifest
PRUNE_MANIFEST="$REPO_ROOT/manifests/remove-unneeded.xml"
if [ -f "$PRUNE_MANIFEST" ]; then
    python3 -c "import xml.etree.ElementTree as ET; ET.parse('$PRUNE_MANIFEST')"
    PRUNE_COUNT=$(grep -c "<remove-project" "$PRUNE_MANIFEST")
    echo "✓ manifests/remove-unneeded.xml syntax validated ($PRUNE_COUNT projects pruned)"
else
    echo "ERROR: manifests/remove-unneeded.xml not found!" >&2
    exit 1
fi

echo "=== All device validations PASSED ==="
