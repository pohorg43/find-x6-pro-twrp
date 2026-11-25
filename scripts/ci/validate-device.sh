#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-device/oplus/sm8550}"
RAMDISK_ROOT=""
shift || true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ramdisk-root)
            RAMDISK_ROOT="${2:-}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -f "$REPO_ROOT/ci/twrp-spec.env" ]; then
    source "$REPO_ROOT/ci/twrp-spec.env"
fi

echo "=== Validating Device Tree in $TARGET_DIR ==="

# 1. Core structure check
for required_file in \
    "BoardConfig.mk" \
    "device.mk" \
    "AndroidProducts.mk" \
    "recovery.fstab" \
    "libinit/libinit_oplus_sm8550.cpp" \
    "recovery/root/init.recovery.qcom.rc" \
    "recovery/root/vendor/bin/override-spl.sh" \
    "recovery/root/vendor/bin/qseecomd" \
    "recovery/root/vendor/bin/ssgtzd" \
    "recovery/root/vendor/bin/hw/android.hardware.security.keymint-service-qti" \
    "recovery/root/vendor/bin/hw/android.hardware.gatekeeper@1.0-service-qti" \
    "recovery/root/vendor/bin/hw/vendor.qti.hardware.qseecom@1.0-service" \
    "recovery/root/vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl-qti.so" \
    "recovery/root/vendor/lib64/libqtikeymint.so" \
    "recovery/root/system/lib64/android.hardware.security.keymint-V2-ndk.so" \
    "recovery/root/vendor/etc/ueventd.rc" \
    "recovery/root/vendor/etc/ssg/ta_config.json" \
    "recovery/root/vendor/etc/gpfspath_oem_config.xml" \
    "recovery/root/vendor/etc/vintf/manifest.xml" \
    "recovery/root/vendor/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml" \
    "recovery/root/system/etc/vintf/manifest.xml" \
    "recovery/root/system/etc/twrp.flags"; do
    if [ ! -f "$TARGET_DIR/$required_file" ]; then
        echo "ERROR: Required file $required_file not found in $TARGET_DIR" >&2
        exit 1
    fi
done
echo "✓ Core + Stage 2 structure validated"

# 2. Partition size check
BC="$TARGET_DIR/BoardConfig.mk"
PART_SIZE_LINE=$(grep "BOARD_RECOVERYIMAGE_PARTITION_SIZE" "$BC" | tr -d ' ' || true)
if [[ "$PART_SIZE_LINE" != *"104857600"* && "$PART_SIZE_LINE" != *"0x6400000"* ]]; then
    echo "ERROR: Invalid recovery partition size in BoardConfig.mk: $PART_SIZE_LINE (expected 104857600)" >&2
    exit 1
fi
echo "✓ Recovery partition size validated: 104857600 bytes"

# 3. Stage 2 BoardConfig / device.mk invariants
if grep -qE "^\s*TW_INCLUDE_OMAPI\s*:=\s*true" "$BC"; then
    echo "ERROR: TW_INCLUDE_OMAPI must be disabled (false) for PGEM10" >&2
    exit 1
fi
grep -qE "^\s*TW_INCLUDE_OMAPI\s*:=\s*false" "$BC" || { echo "ERROR: TW_INCLUDE_OMAPI := false missing in BoardConfig.mk" >&2; exit 1; }
grep -q "libcurl.so" "$BC" && grep -q "libfmq.so" "$BC" || { echo "ERROR: libcurl.so / libfmq.so missing from RECOVERY_LIBRARY_SOURCE_FILES" >&2; exit 1; }
grep -q "find-copy-subdir-files" "$TARGET_DIR/device.mk" || { echo "ERROR: device.mk must copy full recovery/root via find-copy-subdir-files" >&2; exit 1; }
echo "✓ Stage 2 BoardConfig.mk (OMAPI disabled, libcurl/libfmq) & device.mk subtree copy validated"

# 4. Module list completeness & duplicate check
MOD_LINE=$(grep -E "^\s*TW_LOAD_VENDOR_MODULES\s*:=" "$BC" | head -n1 || true)
[ -n "$MOD_LINE" ] || { echo "ERROR: TW_LOAD_VENDOR_MODULES missing from BoardConfig.mk" >&2; exit 1; }
for mod in \
    qcom_glink.ko rproc_qcom_common.ko qcom_q6v5_pas.ko adsp_loader_dlkm.ko \
    pmic_glink.ko oplus_chg.ko oplus_chg_v2.ko oplus_chg_symbol.ko \
    qseecom_proxy.ko smcinvoke_dlkm.ko \
    synaptics_tcm2.ko panel_event_notifier.ko olc.ko oplus_bsp_tp_custom.ko oplus_bsp_tp_comon.ko; do
    if ! grep -qw "$mod" <<<"$MOD_LINE"; then
        echo "ERROR: Required Stage 2 module $mod missing from TW_LOAD_VENDOR_MODULES" >&2
        exit 1
    fi
done
python3 - "$MOD_LINE" <<'PYEOF'
import re, sys
mods = re.findall(r'[A-Za-z0-9_.-]+\.ko', sys.argv[1])
dups = sorted({m for m in mods if mods.count(m) > 1})
if dups:
    print(f"ERROR: Duplicate modules in TW_LOAD_VENDOR_MODULES: {dups}", file=sys.stderr)
    sys.exit(1)
print(f"✓ TW_LOAD_VENDOR_MODULES validated ({len(mods)} unique modules)")
PYEOF

# 5. Header parameters check
if ! grep -qE "PLATFORM_VERSION\s*:=\s*13(\s|$)" "$BC" || ! grep -qE "PLATFORM_SECURITY_PATCH\s*:=\s*2025-11-01" "$BC"; then
    echo "ERROR: PLATFORM_VERSION / PLATFORM_SECURITY_PATCH mismatch in BoardConfig.mk (expected 13 / 2025-11-01)" >&2
    exit 1
fi
echo "✓ Canonical header config validated: PLATFORM_VERSION=13 and PLATFORM_SECURITY_PATCH=2025-11-01"

# 6. Overlay size hygiene check
if [ -d "$REPO_ROOT/overlay/recovery/root" ]; then
    python3 - "$REPO_ROOT/overlay/recovery/root" <<'PYEOF'
import os, sys
root = sys.argv[1]
total = 0
for dirpath, _, filenames in os.walk(root):
    for fn in filenames:
        fp = os.path.join(dirpath, fn)
        sz = os.path.getsize(fp)
        total += sz
        if fn.endswith(".img"):
            print(f"ERROR: Forbidden .img file in overlay: {fp}", file=sys.stderr)
            sys.exit(1)
        if sz > 10 * 1024 * 1024:
            print(f"ERROR: File exceeds 10 MiB limit: {fp} ({sz} bytes)", file=sys.stderr)
            sys.exit(1)
if total > 35 * 1024 * 1024:
    print(f"ERROR: Overlay size {total} exceeds 35 MiB limit", file=sys.stderr)
    sys.exit(1)
print(f"✓ Overlay size hygiene validated ({total / (1024*1024):.2f} MiB <= 35 MiB)")
PYEOF
fi

# 7. ELF DT_NEEDED closure check (pre-build overlay or post-build full ramdisk)
ELF_ROOT="${RAMDISK_ROOT:-$TARGET_DIR/recovery/root}"
STRICT_MODE=$([ -n "$RAMDISK_ROOT" ] && echo "1" || echo "0")
python3 - "$ELF_ROOT" "$STRICT_MODE" <<'PYEOF'
import os, struct, sys

root = sys.argv[1]
strict = sys.argv[2] == "1"

def parse_needed(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise RuntimeError(f"Not an ELF64 LE file: {path}")
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, _ = struct.unpack_from("<HHH", data, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    res = []
    for sh in sections:
        if sh[1] == 6:  # SHT_DYNAMIC
            str_sh = sections[sh[6]]
            strtab = data[str_sh[4]:str_sh[4] + str_sh[5]]
            for p in range(sh[3], sh[3] + sh[4], 16):
                d_tag, d_val = struct.unpack_from("<qQ", data, p)
                if d_tag == 0:
                    break
                if d_tag == 1:  # DT_NEEDED
                    end = strtab.find(b"\x00", d_val)
                    if end != -1:
                        res.append(strtab[d_val:end].decode("utf-8", errors="replace"))
    return res

roots = [
    os.path.join(root, "vendor/bin/hw/android.hardware.security.keymint-service-qti"),
    os.path.join(root, "vendor/bin/hw/android.hardware.gatekeeper@1.0-service-qti"),
    os.path.join(root, "vendor/bin/hw/vendor.qti.hardware.qseecom@1.0-service"),
    os.path.join(root, "vendor/bin/qseecomd"),
    os.path.join(root, "vendor/bin/ssgtzd"),
    os.path.join(root, "vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl-qti.so"),
    os.path.join(root, "vendor/lib64/libqtikeymint.so"),
]

# Standard system/TWRP libraries built by AOSP when validating overlay pre-build
aosp_system_libs = {
    "android.hardware.security.secureclock-V1-ndk.so",
    "android.hardware.security.sharedsecret-V1-ndk.so",
    "android.system.suspend-V1-ndk.so",
    "libandroidicu.so",
    "libbase.so",
    "libbinder.so",
    "libbinder_ndk.so",
    "libc++.so",
    "libc.so",
    "libcrypto.so",
    "libcurl.so",
    "libcutils.so",
    "libdl.so",
    "libdmabufheap.so",
    "libfmq.so",
    "libhardware.so",
    "libhardware_legacy.so",
    "libhidlbase.so",
    "libicui18n.so",
    "libicuuc.so",
    "libion.so",
    "libjsoncpp.so",
    "liblog.so",
    "libm.so",
    "libnetutils.so",
    "libssl.so",
    "libutils.so",
    "libxml2.so",
    "libz.so",
}

search_dirs = [
    os.path.join(root, "vendor/lib64"),
    os.path.join(root, "vendor/lib64/hw"),
    os.path.join(root, "system/lib64"),
    os.path.join(root, "system/lib64/bootstrap"),
]

queue = list(roots)
visited = set()
missing = []

while queue:
    fp = queue.pop(0)
    if fp in visited:
        continue
    if not os.path.exists(fp):
        missing.append(("ROOT_MISSING", fp))
        continue
    visited.add(fp)
    for soname in parse_needed(fp):
        found = None
        for d in search_dirs:
            cand = os.path.join(d, soname)
            if os.path.exists(cand):
                found = cand
                break
        if found:
            if strict or found.startswith(os.path.join(root, "vendor")) or soname == "android.hardware.security.keymint-V2-ndk.so":
                queue.append(found)
        else:
            if not strict and soname in aosp_system_libs:
                continue
            missing.append((os.path.relpath(fp, root), soname))

if missing:
    for holder, dep in missing:
        print(f"ERROR: Unresolved DT_NEEDED for {holder}: {dep}", file=sys.stderr)
    sys.exit(1)

mode_label = "strict ramdisk closure" if strict else "pre-build overlay + AOSP target closure"
print(f"✓ ELF DT_NEEDED closure passed ({len(visited)} ELFs checked, {mode_label})")
PYEOF

if [ -n "$RAMDISK_ROOT" ]; then
    echo "=== Skipping remote manifest check in post-build ramdisk verification ==="
    exit 0
fi

# 8. Remote manifest accessibility check
MANIFEST_URL="${REF_MANIFEST_A16:-https://github.com/TWRP-Test/platform_manifest_twrp_aosp}"
MANIFEST_BRANCH="${REF_MANIFEST_BRANCH:-twrp-16.0}"
echo "Checking remote manifest: $MANIFEST_URL ($MANIFEST_BRANCH)..."
git ls-remote --exit-code "$MANIFEST_URL" "refs/heads/$MANIFEST_BRANCH" >/dev/null
echo "✓ Manifest branch $MANIFEST_BRANCH exists and is reachable!"

# 9. Validate local prune manifest
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
