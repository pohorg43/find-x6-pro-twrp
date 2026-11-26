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

echo "=== Validating Device Tree in $TARGET_DIR (Stage 2 Step D) ==="

# 1. Core + Step C/D structure check
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
    "recovery/root/system/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml" \
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
    "recovery/root/vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-qti.so" \
    "recovery/root/vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl-qti.so" \
    "recovery/root/vendor/lib64/hw/vendor.qti.hardware.qseecom@1.0-impl.so" \
    "recovery/root/vendor/lib64/libboot_control_qti.so" \
    "recovery/root/vendor/lib64/librecovery_updater.so" \
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

validate_vintf_keymint_fragments() {
    local root="$1"
    local mode="$2"
    python3 - "$root" "$mode" <<'PYEOF'
import os, sys
import xml.etree.ElementTree as ET

root_dir, mode = sys.argv[1], sys.argv[2]
required_aidl = {
    ("android.hardware.security.keymint", "IKeyMintDevice/default"),
    ("android.hardware.security.keymint", "IRemotelyProvisionedComponent/default"),
    ("android.hardware.security.sharedsecret", "ISharedSecret/default"),
    ("android.hardware.security.secureclock", "ISecureClock/default"),
}

def check_keymint_fragment(rel_path, expected_type, forbid_target_level):
    fp = os.path.join(root_dir, rel_path)
    if not os.path.isfile(fp):
        raise AssertionError(f"[{mode}] Missing VINTF fragment: {fp}")
    tree = ET.parse(fp)
    manifest = tree.getroot()
    if manifest.tag != "manifest":
        raise AssertionError(f"[{mode}] Invalid root tag in {fp}: {manifest.tag}")
    mtype = manifest.attrib.get("type")
    if mtype != expected_type:
        raise AssertionError(f"[{mode}] {fp}: expected type='{expected_type}', got '{mtype}'")
    if forbid_target_level and "target-level" in manifest.attrib:
        raise AssertionError(f"[{mode}] {fp}: must not specify target-level attribute")
    found_aidl = set()
    for hal in manifest.findall("hal"):
        if hal.attrib.get("format") != "aidl":
            continue
        name_el = hal.find("name")
        if name_el is None or not name_el.text:
            continue
        hal_name = name_el.text.strip()
        for fq in hal.findall("fqname"):
            if fq.text:
                found_aidl.add((hal_name, fq.text.strip()))
    missing = required_aidl - found_aidl
    if missing:
        raise AssertionError(f"[{mode}] {fp}: missing AIDL interfaces: {sorted(missing)}")

check_keymint_fragment("system/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml", "framework", True)
check_keymint_fragment("vendor/etc/vintf/manifest/android.hardware.security.keymint-service-qti.xml", "device", False)

if mode == "ramdisk":
    ks_vintf = os.path.join(root_dir, "system/etc/vintf/manifest/android.system.keystore2-service.xml")
    if not os.path.isfile(ks_vintf):
        raise AssertionError(f"[{mode}] Missing framework keystore2 VINTF fragment: {ks_vintf}")
    ET.parse(ks_vintf)
PYEOF
}

validate_override_spl() {
    local script_path="$1"
    python3 - "$script_path" <<'PYEOF'
import re, sys

fp = sys.argv[1]
src = open(fp, "r", encoding="utf-8").read()

required_markers = [
    ("twrp.storage.ready", "must wait for twrp.storage.ready"),
    ("-t erofs", "must mount with explicit -t erofs"),
    ("ro.build.version.release_or_codename", "must override ro.build.version.release_or_codename"),
]
for needle, msg in required_markers:
    if needle not in src:
        raise AssertionError(f"{fp}: {msg}")

if not re.search(r"^\s*sleep\s+2(\s|$)", src, re.M):
    raise AssertionError(f"{fp}: must keep sleep 2 before starting keystore2")

ks_ready_m = re.search(r"setprop\s+vendor\.twrp\.keystore_ready\s+1", src)
crypto_ready_m = re.search(r"setprop\s+crypto\.ready\s+1", src)
if not ks_ready_m or not crypto_ready_m or ks_ready_m.start() >= crypto_ready_m.start():
    raise AssertionError(f"{fp}: crypto.ready=1 must follow vendor.twrp.keystore_ready=1")

tail = src[ks_ready_m.end():]
pid_cap_m = re.search(r"pidof\s+keystore2", tail)
svc_m1 = re.search(r"init\.svc\.keystore2", tail)
sleep1_m = re.search(r"^\s*sleep\s+1(\s|$)", tail, re.M)
if not pid_cap_m or not svc_m1 or not sleep1_m:
    raise AssertionError(f"{fp}: must wait for keystore2 PID + init.svc.keystore2 and sleep 1 before crypto.ready=1")

after_sleep1 = tail[sleep1_m.end():]
for marker, msg in [
    ("while ", "must stabilize keystore2 PID in a retry loop"),
    ("keystore.crash_count", "must check keystore.crash_count against crash-loop"),
    ("KS_PID=\"$CUR_PID\"", "must accept single clean PID change when init.svc.keystore2=running"),
    ("stopped", "must fail when keystore2 service is stopped or restarting"),
]:
    if marker not in after_sleep1 and marker not in tail:
        raise AssertionError(f"{fp}: {msg}")

pre_crypto = tail[sleep1_m.end():crypto_ready_m.start() - ks_ready_m.end()]
if "pidof" not in pre_crypto or "keystore2" not in pre_crypto or "init.svc.keystore2" not in pre_crypto:
    raise AssertionError(f"{fp}: must re-verify same keystore2 PID and init.svc.keystore2=running after sleep 1 before setting crypto.ready=1")
if not re.search(r'"?\$\{?CUR_PID\}?"?\s*=\s*"?\$\{?KS_PID\}?"?', pre_crypto):
    raise AssertionError(f"{fp}: must verify PID equality after sleep 1 before setting crypto.ready=1")
PYEOF
}

validate_twrp_flags() {
    local flags_path="$1"
    python3 - "$flags_path" <<'PYEOF'
import re, sys

fp = sys.argv[1]
lines = [l.strip() for l in open(fp, "r", encoding="utf-8") if l.strip() and not l.strip().startswith("#")]

entries = {}
for line in lines:
    parts = line.split()
    entries[parts[0]] = line

if "/usbstorage" not in entries:
    raise AssertionError(f"{fp}: missing /usbstorage")

for forbidden in ("/system_ext", "/system_dlkm", "/vendor_dlkm", "/metadata", "/firmware", "/persist", "/misc", "/userdata", "/system", "/vendor", "/product", "/odm"):
    if forbidden in entries:
        raise AssertionError(f"{fp}: must not duplicate recovery.fstab entry {forbidden}")

expected_ab = {
    "/recovery": ("/dev/block/bootdevice/by-name/recovery", 'display="Recovery"'),
    "/boot": ("/dev/block/bootdevice/by-name/boot", 'display="Boot"'),
    "/init_boot": ("/dev/block/bootdevice/by-name/init_boot", 'display="Init Boot"'),
    "/vendor_boot": ("/dev/block/bootdevice/by-name/vendor_boot", 'display="Vendor Boot"'),
    "/dtbo": ("/dev/block/bootdevice/by-name/dtbo", 'display="DTBO"'),
}
for mnt, (dev, disp) in expected_ab.items():
    if mnt not in entries:
        raise AssertionError(f"{fp}: missing A/B partition {mnt}")
    line = entries[mnt]
    for req in ("emmc", dev, disp, "slotselect", "flashimg=1", "backup=1"):
        if req not in line:
            raise AssertionError(f"{fp}: {mnt} missing required field/flag '{req}' -> {line}")

expected_efs = {
    "/efs1": ("/dev/block/bootdevice/by-name/modemst1", 'display="EFS"'),
    "/efs2": ("/dev/block/bootdevice/by-name/modemst2", "subpartitionof=/efs1"),
    "/efsg": ("/dev/block/bootdevice/by-name/fsg", "subpartitionof=/efs1"),
    "/efsc": ("/dev/block/bootdevice/by-name/fsc", "subpartitionof=/efs1"),
}
for mnt, (dev, extra) in expected_efs.items():
    if mnt not in entries:
        raise AssertionError(f"{fp}: missing EFS backup-only partition {mnt}")
    line = entries[mnt]
    for req in ("emmc", dev, "backup=1", extra):
        if req not in line:
            raise AssertionError(f"{fp}: {mnt} missing required backup-only field '{req}' -> {line}")
    for banned in ("flashimg", "wipeingui", "formattable", "slotselect", "storage"):
        if banned in line:
            raise AssertionError(f"{fp}: EFS {mnt} MUST NOT contain '{banned}' -> {line}")
PYEOF
}

validate_vendor_vintf() {
    local ven_vintf="$1"
    python3 - "$ven_vintf" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
fp = sys.argv[1]
root = ET.parse(fp).getroot()
hals = {}
for hal in root.findall("hal"):
    name_el = hal.find("name")
    tr_el = hal.find("transport")
    if name_el is not None and name_el.text:
        hals[name_el.text.strip()] = (
            hal.attrib.get("format"),
            tr_el.text.strip() if tr_el is not None and tr_el.text else None,
            {fq.text.strip() for fq in hal.findall("fqname") if fq.text},
        )
required = {
    "android.hardware.boot": ("hidl", "hwbinder", "@1.2::IBootControl/default"),
    "android.hardware.health": ("hidl", "hwbinder", "@2.1::IHealth/default"),
    "android.hardware.gatekeeper": ("hidl", "hwbinder", "@1.0::IGatekeeper/default"),
    "vendor.qti.hardware.qseecom": ("hidl", "hwbinder", "@1.0::IQSEECom/default"),
}
for name, (fmt, tr, fq) in required.items():
    if name not in hals:
        raise AssertionError(f"{fp}: missing HAL {name}")
    got_fmt, got_tr, got_fqs = hals[name]
    if got_fmt != fmt or got_tr != tr or fq not in got_fqs:
        raise AssertionError(f"{fp}: HAL {name} mismatch: got fmt={got_fmt} tr={got_tr} fqs={sorted(got_fqs)}")
PYEOF
}

validate_ueventd_vendor() {
    local ueventd_path="$1"
    if grep -qE "^\s*subsystem\s+bsg\b" "$ueventd_path"; then
        echo "ERROR: $ueventd_path must NOT declare subsystem bsg (nodes must stay directly in /dev/)!" >&2
        exit 1
    fi
    if grep -qE "^\s*subsystem\s+dma_heap\b" "$ueventd_path"; then
        echo "ERROR: $ueventd_path must NOT duplicate subsystem dma_heap (already in /system/etc/ueventd.rc)!" >&2
        exit 1
    fi
    for rule in \
        "/dev/smcinvoke" \
        "/dev/dma_heap/system" \
        "/dev/dma_heap/qcom,\*" \
        "/dev/ion[[:space:]]" \
        "/dev/0:0:0:49476[[:space:]]" \
        "/dev/0:0:0:4[[:space:]]" \
        "/dev/spss_utils[[:space:]]" \
        "/dev/sp_keymaster[[:space:]]" \
        "/dev/sec_nvm_\*[[:space:]]"; do
        grep -qE "$rule" "$ueventd_path" || { echo "ERROR: Missing ueventd rule '$rule' in $ueventd_path" >&2; exit 1; }
    done
}

# 1b. VINTF XML & twrp.flags validation
SYS_VINTF="$TARGET_DIR/recovery/root/system/etc/vintf/manifest.xml"
VEN_VINTF="$TARGET_DIR/recovery/root/vendor/etc/vintf/manifest.xml"
python3 -c "import xml.etree.ElementTree as ET; ET.parse('$SYS_VINTF'); ET.parse('$VEN_VINTF')"
validate_vintf_keymint_fragments "$TARGET_DIR/recovery/root" "pre-build"
grep -q "android.hidl.manager" "$SYS_VINTF" && grep -q "@1.2::IServiceManager/default" "$SYS_VINTF" || {
    echo "ERROR: android.hidl.manager@1.2::IServiceManager/default missing in system VINTF manifest!" >&2; exit 1;
}
validate_vendor_vintf "$VEN_VINTF"
if [ -e "$TARGET_DIR/recovery/root/vendor/etc/init/android.hardware.boot@1.2-service.rc" ]; then
    echo "ERROR: vendor/etc/init/android.hardware.boot@1.2-service.rc conflicts with /system/etc/init/android.hardware.boot@1.2-service.rc!" >&2; exit 1;
fi
TWRP_FLAGS="$TARGET_DIR/recovery/root/system/etc/twrp.flags"
validate_twrp_flags "$TWRP_FLAGS"
echo "✓ VINTF manifests (hwservicemanager + 4 device HIDL HALs incl. boot@1.2 + KeyMint V2 AIDL framework+device) and Step D twrp.flags validated"

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
grep -qE "^\s*TW_NO_FLASH_CURRENT_TWRP\s*:=\s*true" "$BC" || { echo "ERROR: TW_NO_FLASH_CURRENT_TWRP := true missing in BoardConfig.mk" >&2; exit 1; }
if grep -qw "my_colorospro" "$BC" || grep -qw "my_colorospro" "$TARGET_DIR/recovery.fstab"; then
    echo "ERROR: my_colorospro must be removed from BoardConfig.mk and recovery.fstab!" >&2
    exit 1
fi
grep -qE "^\s*BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES\s*:=\s*true" "$BC" || { echo "ERROR: BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true missing in BoardConfig.mk" >&2; exit 1; }
grep -qE "^\s*BUILD_BROKEN_DUP_RULES\s*:=\s*true" "$BC" || { echo "ERROR: BUILD_BROKEN_DUP_RULES := true missing in BoardConfig.mk" >&2; exit 1; }
grep -q "find-copy-subdir-files" "$TARGET_DIR/device.mk" || { echo "ERROR: device.mk must copy full recovery/root via find-copy-subdir-files" >&2; exit 1; }

INIT_QCOM="$TARGET_DIR/recovery/root/init.recovery.qcom.rc"
grep -q "start boot-hal-1-2" "$INIT_QCOM" || {
    echo "ERROR: init.recovery.qcom.rc must start boot-hal-1-2 in on fs!" >&2
    exit 1
}
python3 - "$INIT_QCOM" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
idx_bcb = src.find("clear-bcb.sh")
idx_bsg = src.find("wait /dev/ufs-bsg0")
idx_boot = src.find("start boot-hal-1-2")
if idx_bcb == -1 or idx_bsg == -1 or idx_boot == -1 or not (idx_bcb < idx_bsg < idx_boot):
    print("ERROR: init.recovery.qcom.rc must run clear-bcb.sh -> wait /dev/ufs-bsg0 -> start boot-hal-1-2 in order", file=sys.stderr)
    sys.exit(1)
PYEOF
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
validate_override_spl "$TARGET_DIR/recovery/root/system/bin/override-spl.sh"
grep -q "/system/bin/override-spl.sh" "$TARGET_DIR/recovery/root/vendor/etc/init/override-spl.rc" || { echo "ERROR: override-spl.rc must execute /system/bin/override-spl.sh" >&2; exit 1; }
validate_ueventd_vendor "$TARGET_DIR/recovery/root/vendor/etc/ueventd.rc"
echo "✓ Step D BoardConfig.mk (no my_colorospro, TW_NO_FLASH_CURRENT_TWRP), recovery.fstab, device.mk, init.recovery.qcom.rc (boot-hal-1-2), clear-bcb.sh, override-spl.sh, and ueventd.rc validated"

# 3b. Verify Step D bootable/recovery + vendor/twrp patches in .github/workflows/build.yml
BUILD_YML="$REPO_ROOT/.github/workflows/build.yml"
[ -f "$BUILD_YML" ] || { echo "ERROR: $BUILD_YML not found!" >&2; exit 1; }
python3 - "$BUILD_YML" <<'PYEOF'
import sys
src = open(sys.argv[1], "r", encoding="utf-8").read()
required_in_yml = [
    ("BoardConfigSoong.mk TW_NO_FLASH_CURRENT_TWRP", "vendor/twrp/config/BoardConfigSoong.mk"),
    ("twrp_flags.go TW_NO_FLASH_CURRENT_TWRP", "bootable/recovery/twrp_flags.go"),
    ("-DTW_NO_FLASH_CURRENT_TWRP", "-DTW_NO_FLASH_CURRENT_TWRP"),
    ("twrp_tools_backend.cpp", "bootable/recovery/gui2/backend/twrp_tools_backend.cpp"),
    ("disable_avb2 = false", "result.disable_avb2 = false;"),
    ("fix_contexts = false", "result.fix_contexts = false;"),
    ("install_kernel = false", "result.install_kernel = false;"),
    ("gui2.cpp", "bootable/recovery/gui2/gui2.cpp"),
    ("tw_auto_disable_avb2 gate", "tools->availability().disable_avb2"),
    ("backup_tab_changed settle", "static void backup_tab_changed"),
    ("restore_tab_changed settle", "static void restore_tab_changed"),
    ("kBackupEncryptTarget scroll settle", "kBackupEncryptTarget"),
    ("page_host.settle()", "page_host.settle();"),
    ("lv_obj_scroll_to_y", "lv_obj_scroll_to_y(main_content, 0, LV_ANIM_OFF)"),
    ("backup_page.cpp", "bootable/recovery/gui2/pages/backup_page.cpp"),
    ("restore_page.cpp", "bootable/recovery/gui2/pages/restore_page.cpp"),
    ("LV_DIR_HOR", "LV_DIR_HOR"),
    ("battery_utils.cpp", "bootable/recovery/recovery_utils/battery_utils.cpp"),
    ("AIDL health single log", "logged_aidl_unavailable"),
]
for label, needle in required_in_yml:
    if needle not in src:
        raise AssertionError(f"{sys.argv[1]}: missing Step D patch marker '{label}' ({needle})")
print("✓ build.yml Step D patches verified (TW_NO_FLASH_CURRENT_TWRP, disable_avb2/install_kernel/fix_contexts/tw_auto_disable_avb2, Backup/Restore scroll + LV_DIR_HOR, battery_utils AIDL spam fix)")
PYEOF

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

# 7. Post-build ramdisk checks (keystore2.rc, framework/vendor VINTF, override-spl.sh, ueventd.rc)
if [ -n "$RAMDISK_ROOT" ]; then
    KS_RC="$RAMDISK_ROOT/system/etc/init/keystore2.rc"
    [ -f "$KS_RC" ] || { echo "ERROR: $KS_RC missing in ramdisk root!" >&2; exit 1; }
    KS_COUNT=$(find "$RAMDISK_ROOT" -name "*keystore2*.rc" | wc -l | tr -d ' ')
    if [ "$KS_COUNT" != "1" ]; then
        echo "ERROR: Expected exactly 1 keystore2*.rc in $RAMDISK_ROOT, found $KS_COUNT!" >&2
        find "$RAMDISK_ROOT" -name "*keystore2*.rc" >&2
        exit 1
    fi
    if grep -qE "^\s*critical\b" "$KS_RC" || grep -qE "^\s*on\s+late-init" "$KS_RC"; then
        echo "ERROR: $KS_RC still contains active critical or on late-init!" >&2
        cat "$KS_RC" >&2
        exit 1
    fi
    grep -qE "^\s*disabled\b" "$KS_RC" || { echo "ERROR: $KS_RC missing disabled flag!" >&2; exit 1; }
    validate_vintf_keymint_fragments "$RAMDISK_ROOT" "ramdisk"
    validate_vendor_vintf "$RAMDISK_ROOT/vendor/etc/vintf/manifest.xml"
    [ -x "$RAMDISK_ROOT/system/bin/android.hardware.boot@1.2-service" ] || { echo "ERROR: system/bin/android.hardware.boot@1.2-service missing in ramdisk!" >&2; exit 1; }
    [ -f "$RAMDISK_ROOT/system/etc/init/android.hardware.boot@1.2-service.rc" ] || { echo "ERROR: system/etc/init/android.hardware.boot@1.2-service.rc missing in ramdisk!" >&2; exit 1; }
    [ ! -e "$RAMDISK_ROOT/vendor/etc/init/android.hardware.boot@1.2-service.rc" ] || { echo "ERROR: conflicting vendor android.hardware.boot@1.2-service.rc found in ramdisk!" >&2; exit 1; }
    validate_twrp_flags "$RAMDISK_ROOT/system/etc/twrp.flags"
    validate_override_spl "$RAMDISK_ROOT/system/bin/override-spl.sh"
    validate_ueventd_vendor "$RAMDISK_ROOT/vendor/etc/ueventd.rc"
    echo "✓ Post-build ramdisk verified (single keystore2.rc disabled/no critical, boot@1.2 service + VINTF + KeyMint/keystore2 XMLs, Step D twrp.flags, override-spl.sh PID loop, ueventd.rc)"
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
    os.path.join(root, "vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-qti.so"),
    os.path.join(root, "vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl-qti.so"),
    os.path.join(root, "vendor/lib64/hw/vendor.qti.hardware.qseecom@1.0-impl.so"),
    os.path.join(root, "vendor/lib64/libboot_control_qti.so"),
    os.path.join(root, "vendor/lib64/librecovery_updater.so"),
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
if strict:
    roots.append(os.path.join(root, "system/bin/android.hardware.boot@1.2-service"))

aosp_system_libs = {
    "android.hardware.boot@1.0.so",
    "android.hardware.boot@1.1.so",
    "android.hardware.boot@1.2.so",
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
