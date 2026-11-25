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

echo "=== Validating Device Tree in $TARGET_DIR (Stage 2 Step C3) ==="

# 1. Core + Step C structure check
for required_file in \
    "BoardConfig.mk" \
    "device.mk" \
    "AndroidProducts.mk" \
    "recovery.fstab" \
    "libinit/libinit_oplus_sm8550.cpp" \
    "recovery/root/init.recovery.qcom.rc" \
    "recovery/root/system/bin/clear-bcb.sh" \
    "recovery/root/system/bin/override-spl.sh" \
    "recovery/root/system/etc/vintf/manifest.xml" \
    "recovery/root/system/etc/twrp.flags" \
    "recovery/root/vendor/etc/ueventd.rc" \
    "recovery/root/vendor/etc/ssg/ta_config.json" \
    "recovery/root/vendor/etc/gpfspath_oem_config.xml" \
    "recovery/root/vendor/etc/vintf/manifest.xml" \
    "recovery/root/vendor/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml" \
    "recovery/root/vendor/etc/init/override-spl.rc" \
    "recovery/root/vendor/etc/init/qseecomd.rc" \
    "recovery/root/vendor/etc/init/ssgtzd.rc" \
    "recovery/root/vendor/etc/init/vendor.qti.hardware.qseecom@1.0-service.rc" \
    "recovery/root/vendor/etc/init/android.hardware.security.keymint-service-qti.rc" \
    "recovery/root/vendor/etc/init/android.hardware.gatekeeper@1.0-service-qti.rc" \
    "recovery/root/vendor/bin/qseecomd" \
    "recovery/root/vendor/bin/ssgtzd" \
    "recovery/root/vendor/bin/hw/android.hardware.security.keymint-service-qti" \
    "recovery/root/vendor/bin/hw/android.hardware.gatekeeper@1.0-service-qti" \
    "recovery/root/vendor/bin/hw/vendor.qti.hardware.qseecom@1.0-service" \
    "recovery/root/vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl-qti.so" \
    "recovery/root/vendor/lib64/hw/vendor.qti.hardware.qseecom@1.0-impl.so" \
    "recovery/root/vendor/lib64/librpmb.so" \
    "recovery/root/vendor/lib64/libgpt.so" \
    "recovery/root/vendor/lib64/libssd.so" \
    "recovery/root/vendor/lib64/libspl.so" \
    "recovery/root/vendor/lib64/libdrmtime.so" \
    "recovery/root/vendor/lib64/libops.so" \
    "recovery/root/vendor/lib64/libqisl.so" \
    "recovery/root/vendor/lib64/libGPreqcancel.so" \
    "recovery/root/vendor/lib64/libGPreqcancel_svc.so" \
    "recovery/root/vendor/lib64/libtime_genoff.so" \
    "recovery/root/vendor/lib64/libdrm.so" \
    "recovery/root/vendor/lib64/libdisplayconfig.qti.so" \
    "recovery/root/vendor/lib64/vendor.display.config@2.0.so" \
    "recovery/root/vendor/lib64/libqtikeymint.so" \
    "recovery/root/system/lib64/android.hardware.security.keymint-V2-ndk.so" \
    "recovery/root/system/lib64/libcurl.so" \
    "recovery/root/system/lib64/libfmq.so"; do
    if [ ! -f "$TARGET_DIR/$required_file" ]; then
        echo "ERROR: Required file $required_file not found in $TARGET_DIR" >&2
        exit 1
    fi
done
[ -x "$TARGET_DIR/recovery/root/system/bin/clear-bcb.sh" ] || { echo "ERROR: clear-bcb.sh is not executable!" >&2; exit 1; }
[ -x "$TARGET_DIR/recovery/root/system/bin/override-spl.sh" ] || { echo "ERROR: override-spl.sh is not executable!" >&2; exit 1; }
echo "✓ Core + Step C structure (clear-bcb.sh, override-spl.sh +0755, VINTF, 6 .rc) validated"

# 1b. VINTF XML & twrp.flags validation
SYS_VINTF="$TARGET_DIR/recovery/root/system/etc/vintf/manifest.xml"
VEN_VINTF="$TARGET_DIR/recovery/root/vendor/etc/vintf/manifest.xml"
python3 -c "import xml.etree.ElementTree as ET; ET.parse('$SYS_VINTF'); ET.parse('$VEN_VINTF'); ET.parse('$TARGET_DIR/recovery/root/vendor/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml')"
grep -q "android.hidl.manager" "$SYS_VINTF" && grep -q "@1.2::IServiceManager/default" "$SYS_VINTF" || {
    echo "ERROR: android.hidl.manager@1.2::IServiceManager/default missing in system VINTF manifest!" >&2; exit 1;
}
if grep -q "android.hardware.boot" "$VEN_VINTF"; then
    echo "ERROR: android.hardware.boot must NOT be in vendor/etc/vintf/manifest.xml (blocks recovery BootControlClient::WaitForService)!" >&2; exit 1;
fi
for hal in android.hardware.health android.hardware.gatekeeper vendor.qti.hardware.qseecom; do
    grep -q "$hal" "$VEN_VINTF" || { echo "ERROR: $hal missing in vendor/etc/vintf/manifest.xml" >&2; exit 1; }
done
TWRP_FLAGS="$TARGET_DIR/recovery/root/system/etc/twrp.flags"
grep -q "/usbstorage" "$TWRP_FLAGS" || { echo "ERROR: /usbstorage missing in twrp.flags" >&2; exit 1; }
if grep -qE "^\s*/(system_ext|system_dlkm|vendor_dlkm|metadata|firmware|persist|boot|recovery)\b" "$TWRP_FLAGS"; then
    echo "ERROR: twrp.flags must not duplicate partitions already defined in recovery.fstab!" >&2
    exit 1
fi
echo "✓ VINTF manifests (hwservicemanager + 3 device HIDL HALs + KeyMint AIDL, no boot HAL) and minimal twrp.flags validated"

# 2. Partition size check
BC="$TARGET_DIR/BoardConfig.mk"
PART_SIZE_LINE=$(grep "BOARD_RECOVERYIMAGE_PARTITION_SIZE" "$BC" | tr -d ' ' || true)
if [[ "$PART_SIZE_LINE" != *"104857600"* && "$PART_SIZE_LINE" != *"0x6400000"* ]]; then
    echo "ERROR: Invalid recovery partition size in BoardConfig.mk: $PART_SIZE_LINE (expected 104857600)" >&2
    exit 1
fi
echo "✓ Recovery partition size validated: 104857600 bytes"

# 3. BoardConfig / device.mk / init.recovery.qcom.rc / ueventd.rc invariants
if grep -qE "^\s*TW_INCLUDE_OMAPI\s*:=\s*true" "$BC"; then
    echo "ERROR: TW_INCLUDE_OMAPI must be disabled (false) for PGEM10" >&2
    exit 1
fi
grep -qE "^\s*TW_INCLUDE_OMAPI\s*:=\s*false" "$BC" || { echo "ERROR: TW_INCLUDE_OMAPI := false missing in BoardConfig.mk" >&2; exit 1; }
grep -qE "^\s*BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES\s*:=\s*true" "$BC" || { echo "ERROR: BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true missing in BoardConfig.mk" >&2; exit 1; }
grep -qE "^\s*BUILD_BROKEN_DUP_RULES\s*:=\s*true" "$BC" || { echo "ERROR: BUILD_BROKEN_DUP_RULES := true missing in BoardConfig.mk" >&2; exit 1; }
grep -q "find-copy-subdir-files" "$TARGET_DIR/device.mk" || { echo "ERROR: device.mk must copy full recovery/root via find-copy-subdir-files" >&2; exit 1; }

INIT_QCOM="$TARGET_DIR/recovery/root/init.recovery.qcom.rc"
if grep -q "boot-hal-1-2" "$INIT_QCOM"; then
    echo "ERROR: init.recovery.qcom.rc must NOT start boot-hal-1-2!" >&2
    exit 1
fi
if grep -q "sys.boot_completed" "$INIT_QCOM"; then
    echo "ERROR: init.recovery.qcom.rc must NOT set sys.boot_completed before /data decrypt!" >&2
    exit 1
fi
if grep -q "rmdir /vendor/firmware_mnt" "$INIT_QCOM"; then
    echo "ERROR: init.recovery.qcom.rc must NOT contain spurious rmdir /vendor/firmware_mnt!" >&2
    exit 1
fi
grep -q "wait /dev/block/bootdevice/by-name/misc 5" "$INIT_QCOM" || { echo "ERROR: wait misc 5 missing in init.recovery.qcom.rc" >&2; exit 1; }
grep -q "exec u:r:recovery:s0 root root -- /system/bin/sh /system/bin/clear-bcb.sh" "$INIT_QCOM" || { echo "ERROR: clear-bcb.sh exec missing in init.recovery.qcom.rc" >&2; exit 1; }
if grep -qE "^\s*umount\s+/vendor" "$INIT_QCOM"; then
    echo "ERROR: init.recovery.qcom.rc must NOT run umount /vendor!" >&2
    exit 1
fi
grep -q "setprop vendor.gatekeeper.disable_spu true" "$INIT_QCOM" || { echo "ERROR: vendor.gatekeeper.disable_spu missing" >&2; exit 1; }
grep -q "setprop vendor.gatekeeper.is_security_level_spu 0" "$INIT_QCOM" || { echo "ERROR: vendor.gatekeeper.is_security_level_spu missing" >&2; exit 1; }
grep -q "on property:vendor.twrp.spl_ready=1" "$INIT_QCOM" || { echo "ERROR: vendor.twrp.spl_ready=1 trigger missing" >&2; exit 1; }
grep -q "on property:vendor.twrp.crypto_hal_ready=1" "$INIT_QCOM" || { echo "ERROR: vendor.twrp.crypto_hal_ready=1 trigger missing" >&2; exit 1; }
grep -q "on property:vendor.twrp.keystore_ready=1" "$INIT_QCOM" || { echo "ERROR: vendor.twrp.keystore_ready=1 trigger missing" >&2; exit 1; }
if grep -q "post-boot-script" "$INIT_QCOM"; then
    echo "ERROR: init.recovery.qcom.rc must NOT define or start post-boot-script!" >&2
    exit 1
fi
for data_dir in "/data/vendor/tzstorage" "/data/vendor/qwes" "/data/vendor/time" "/data/vendor/qtee" "/data/vendor/tui"; do
    grep -q "mkdir $data_dir " "$INIT_QCOM" || { echo "ERROR: mkdir $data_dir missing in init.recovery.qcom.rc" >&2; exit 1; }
done
python3 - "$INIT_QCOM" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
idx_spl = src.find("start override-spl")
idx_bat = src.find("wait /sys/class/power_supply/battery")
if idx_spl == -1 or idx_bat == -1 or idx_spl > idx_bat:
    print("ERROR: start override-spl must come BEFORE wait /sys/class/power_supply/battery in init.recovery.qcom.rc", file=sys.stderr)
    sys.exit(1)
PYEOF
grep -q "bs=128" "$TARGET_DIR/recovery/root/system/bin/clear-bcb.sh" || { echo "ERROR: clear-bcb.sh must zero 128 bytes!" >&2; exit 1; }
OVERRIDE_SH="$TARGET_DIR/recovery/root/system/bin/override-spl.sh"
grep -q "twrp.storage.ready" "$OVERRIDE_SH" || { echo "ERROR: override-spl.sh must wait for twrp.storage.ready!" >&2; exit 1; }
grep -q "\-t erofs" "$OVERRIDE_SH" || { echo "ERROR: override-spl.sh must mount with explicit -t erofs!" >&2; exit 1; }
grep -q "ro.build.version.release_or_codename" "$OVERRIDE_SH" || { echo "ERROR: override-spl.sh must override ro.build.version.release_or_codename!" >&2; exit 1; }
grep -qE "^\s*sleep 2(\s|$)" "$OVERRIDE_SH" || { echo "ERROR: override-spl.sh must keep sleep 2 before starting keystore2!" >&2; exit 1; }
grep -q "/system/bin/override-spl.sh" "$TARGET_DIR/recovery/root/vendor/etc/init/override-spl.rc" || { echo "ERROR: override-spl.rc must execute /system/bin/override-spl.sh" >&2; exit 1; }
UEVENTD_VEN="$TARGET_DIR/recovery/root/vendor/etc/ueventd.rc"
if grep -qE "^\s*subsystem\s+bsg\b" "$UEVENTD_VEN"; then
    echo "ERROR: vendor/etc/ueventd.rc must NOT declare subsystem bsg (nodes must stay directly in /dev/)!" >&2
    exit 1
fi
for rule in \
    "/dev/smcinvoke" \
    "subsystem dma_heap" \
    "/dev/dma_heap/system" \
    "/dev/dma_heap/qcom,\*" \
    "/dev/ion[[:space:]]" \
    "/dev/0:0:0:49476[[:space:]]" \
    "/dev/0:0:0:4[[:space:]]" \
    "/dev/spss_utils[[:space:]]" \
    "/dev/sp_keymaster[[:space:]]" \
    "/dev/sec_nvm_\*[[:space:]]"; do
    grep -qE "$rule" "$UEVENTD_VEN" || { echo "ERROR: Missing ueventd rule '$rule' in vendor/etc/ueventd.rc" >&2; exit 1; }
done
echo "✓ Step C3 BoardConfig.mk, device.mk, init.recovery.qcom.rc, clear-bcb.sh, override-spl.sh, and ueventd.rc validated"

# 4. Module list completeness, exclusions & duplicate check
MOD_LINE=$(grep -E "^\s*TW_LOAD_VENDOR_MODULES\s*:=" "$BC" | head -n1 || true)
[ -n "$MOD_LINE" ] || { echo "ERROR: TW_LOAD_VENDOR_MODULES missing from BoardConfig.mk" >&2; exit 1; }
for mod in \
    qcom_glink.ko rproc_qcom_common.ko qcom_q6v5_pas.ko adsp_loader_dlkm.ko \
    pmic_glink.ko oplus_chg.ko \
    qseecom_proxy.ko smcinvoke_dlkm.ko \
    synaptics_tcm2.ko panel_event_notifier.ko olc.ko oplus_bsp_tp_custom.ko oplus_bsp_tp_comon.ko; do
    if ! grep -qw "$mod" <<<"$MOD_LINE"; then
        echo "ERROR: Required module $mod missing from TW_LOAD_VENDOR_MODULES" >&2
        exit 1
    fi
done
for removed_mod in \
    oplus_chg_v2.ko oplus_chg_symbol.ko ufcs_class.ko dwc3-msm.ko redriver.ko \
    wcd_usbss_i2c.ko ucsi_glink.ko i2c-msm-geni.ko gh_mem_notifier.ko gh_irq_lend.ko; do
    if grep -qw "$removed_mod" <<<"$MOD_LINE"; then
        echo "ERROR: Excluded module $removed_mod still present in TW_LOAD_VENDOR_MODULES" >&2
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

# 7. Post-build keystore2.rc check (must not contain active critical window=0 or on late-init)
if [ -n "$RAMDISK_ROOT" ]; then
    KS_RC="$RAMDISK_ROOT/system/etc/init/keystore2.rc"
    [ -f "$KS_RC" ] || { echo "ERROR: $KS_RC missing in ramdisk root!" >&2; exit 1; }
    if grep -qE "^\s*critical\b" "$KS_RC" || grep -qE "^\s*on\s+late-init" "$KS_RC"; then
        echo "ERROR: $KS_RC still contains active critical or on late-init!" >&2
        cat "$KS_RC" >&2
        exit 1
    fi
    grep -qE "^\s*disabled\b" "$KS_RC" || { echo "ERROR: $KS_RC missing disabled flag!" >&2; exit 1; }
    echo "✓ Post-build keystore2.rc verified (disabled, no critical window=0)"
fi

# 8. ELF DT_NEEDED closure check
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
            for p in range(sh[4], sh[4] + sh[5], 16):
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
    os.path.join(root, "vendor/lib64/hw/vendor.qti.hardware.qseecom@1.0-impl.so"),
    os.path.join(root, "vendor/lib64/libqtikeymint.so"),
    os.path.join(root, "vendor/lib64/librpmb.so"),
    os.path.join(root, "vendor/lib64/libgpt.so"),
    os.path.join(root, "vendor/lib64/libssd.so"),
    os.path.join(root, "vendor/lib64/libspl.so"),
    os.path.join(root, "vendor/lib64/libdrmtime.so"),
    os.path.join(root, "vendor/lib64/libops.so"),
    os.path.join(root, "vendor/lib64/libqisl.so"),
    os.path.join(root, "vendor/lib64/libGPreqcancel.so"),
    os.path.join(root, "vendor/lib64/libGPreqcancel_svc.so"),
    os.path.join(root, "vendor/lib64/libtime_genoff.so"),
    os.path.join(root, "vendor/lib64/libdrm.so"),
    os.path.join(root, "vendor/lib64/libdisplayconfig.qti.so"),
    os.path.join(root, "vendor/lib64/vendor.display.config@2.0.so"),
]

aosp_system_libs = {
    "android.hardware.security.secureclock-V1-ndk.so",
    "android.hardware.security.sharedsecret-V1-ndk.so",
    "android.hidl.allocator@1.0.so",
    "android.hidl.memory@1.0.so",
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
    "libhidlmemory.so",
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
            if strict or found.startswith(os.path.join(root, "vendor")) or soname in ("android.hardware.security.keymint-V2-ndk.so", "libcurl.so", "libfmq.so"):
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

# 9. Remote manifest accessibility check
MANIFEST_URL="${REF_MANIFEST_A16:-https://github.com/TWRP-Test/platform_manifest_twrp_aosp}"
MANIFEST_BRANCH="${REF_MANIFEST_BRANCH:-twrp-16.0}"
echo "Checking remote manifest: $MANIFEST_URL ($MANIFEST_BRANCH)..."
git ls-remote --exit-code "$MANIFEST_URL" "refs/heads/$MANIFEST_BRANCH" >/dev/null
echo "✓ Manifest branch $MANIFEST_BRANCH exists and is reachable!"

# 10. Validate local prune manifest
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
