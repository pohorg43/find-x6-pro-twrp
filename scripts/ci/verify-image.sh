#!/usr/bin/env bash
set -euo pipefail

IMAGE_PATH="${1:-out/target/product/sm8550/recovery.img}"
MAX_SIZE=104857600 # 100 MiB

echo "=== Verifying built recovery image: $IMAGE_PATH ==="

if [ ! -f "$IMAGE_PATH" ]; then
    echo "ERROR: Recovery image not found at $IMAGE_PATH!" >&2
    exit 1
fi

ACTUAL_SIZE=$(stat -c%s "$IMAGE_PATH")
echo "Recovery image size: $ACTUAL_SIZE bytes (Max allowed: $MAX_SIZE bytes)"

if [ "$ACTUAL_SIZE" -gt "$MAX_SIZE" ]; then
    echo "ERROR: Recovery image exceeds partition size! ($ACTUAL_SIZE > $MAX_SIZE)" >&2
    exit 1
fi
echo "✓ Size check PASSED: $ACTUAL_SIZE <= $MAX_SIZE bytes"

# Header check via python3
python3 - <<PYEOF
import struct, sys

with open("$IMAGE_PATH", "rb") as f:
    magic = f.read(8)
    if magic != b"ANDROID!":
        print(f"ERROR: Invalid magic: {magic}", file=sys.stderr)
        sys.exit(1)
    
    f.seek(8)
    kernel_size, ramdisk_size, os_version_raw, header_size = struct.unpack("<IIII", f.read(16))
    f.seek(40)
    header_version = struct.unpack("<I", f.read(4))[0]

    os_a = (os_version_raw >> 25) & 0x7F
    os_b = (os_version_raw >> 18) & 0x7F
    os_c = (os_version_raw >> 11) & 0x7F
    patch_year = 2000 + ((os_version_raw >> 4) & 0x7F)
    patch_month = os_version_raw & 0xF

    os_ver_str = f"{os_a}.{os_b}.{os_c}"
    patch_str = f"{patch_year:04d}-{patch_month:02d}"

    print(f"Header Version: {header_version}")
    print(f"Kernel Size: {kernel_size}")
    print(f"Ramdisk Size: {ramdisk_size}")
    print(f"OS Version: {os_ver_str}")
    print(f"OS Patch Level: {patch_str}")

    if header_version != 4:
        print(f"ERROR: Expected header_version 4, got {header_version}", file=sys.stderr)
        sys.exit(1)
    if os_ver_str != "13.0.0":
        print(f"ERROR: Expected OS version 13.0.0, got {os_ver_str}", file=sys.stderr)
        sys.exit(1)
    if patch_str != "2025-11":
        print(f"ERROR: Expected patch level 2025-11, got {patch_str}", file=sys.stderr)
        sys.exit(1)

    print("✓ Header v4 validation PASSED (13.0.0 / 2025-11)!")
PYEOF

echo "=== All recovery image checks PASSED ==="
