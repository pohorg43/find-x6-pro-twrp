#!/system/bin/sh

SCRIPTNAME="override-spl.sh"

log() {
	echo "I:$SCRIPTNAME: $1" > /dev/kmsg 2>/dev/null || true
	echo "I:$SCRIPTNAME: $1" >> /tmp/recovery.log 2>/dev/null || true
}

FASTBOOTD_PROP=$(getprop ro.twrp.fastbootd)
if [ "$FASTBOOTD_PROP" = "1" ]; then
	log "Detected fastbootd (ro.twrp.fastbootd=1), exit script."
	exit 0
fi

SLOT=$(getprop ro.boot.slot_suffix)
if [ -z "$SLOT" ]; then
	log "ERROR: No slot suffix detected, skipping crypto stack to stay in YARP."
	exit 1
fi
log "Slot detected: $SLOT"

# Wait up to 15s (30 x 0.5s) for SetupFstabPartitions() to finish LoadApexImages()
# (which mounts /vendor a second time), unmount /vendor, and set twrp.storage.ready=1.
v=0
while [ "$v" -lt 30 ]; do
	if [ "$(getprop twrp.storage.ready)" = "1" ] && ! grep -q " /vendor " /proc/mounts 2>/dev/null; then
		break
	fi
	v=$((v + 1))
	sleep 0.5
done

if [ "$(getprop twrp.storage.ready)" != "1" ] || grep -q " /vendor " /proc/mounts 2>/dev/null; then
	log "ERROR: storage not ready or /vendor still mounted after 15s (storage=$(getprop twrp.storage.ready)), skipping crypto stack to keep YARP alive."
	exit 1
fi
log "/vendor unmounted cleanly after storage init; ramdisk overlay active."

read_prop_from_block() {
	MNT="$1"
	BLK="$2"
	PROP="$3"
	VAL=""

	if [ ! -e "$BLK" ]; then
		return 1
	fi

	mkdir -p "$MNT"
	if ! mount -t erofs -o ro "$BLK" "$MNT" 2>/dev/null && \
	   ! mount -t ext4 -o ro "$BLK" "$MNT" 2>/dev/null && \
	   ! mount -o ro "$BLK" "$MNT" 2>/dev/null; then
		rmdir "$MNT" 2>/dev/null || true
		return 1
	fi

	for candidate in "$MNT/build.prop" "$MNT/system/build.prop" "$MNT/etc/build.prop"; do
		if [ -f "$candidate" ]; then
			VAL=$(grep -m1 "^${PROP}=" "$candidate" | cut -d'=' -f2- | tr -d '\r')
			[ -n "$VAL" ] && break
		fi
	done

	umount -f -l "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
	rmdir "$MNT" 2>/dev/null || true

	if [ -n "$VAL" ]; then
		printf '%s' "$VAL"
		return 0
	fi
	return 1
}

REL=""
SYS_SPL=""
VEN_SPL=""

# PGEM10 ColorOS 16 stores unified OPPO/Android 16 build.prop on my_manifest
if VAL=$(read_prop_from_block "/tmp/spl_manifest" "/dev/block/mapper/my_manifest${SLOT}" "ro.build.version.release"); then
	REL="$VAL"
fi
if VAL=$(read_prop_from_block "/tmp/spl_manifest" "/dev/block/mapper/my_manifest${SLOT}" "ro.build.version.security_patch"); then
	SYS_SPL="$VAL"
fi
if VAL=$(read_prop_from_block "/tmp/spl_manifest" "/dev/block/mapper/my_manifest${SLOT}" "ro.vendor.build.security_patch"); then
	VEN_SPL="$VAL"
fi

# Fallback against system and vendor dynamic partitions
if [ -z "$REL" ]; then
	REL=$(read_prop_from_block "/tmp/spl_system" "/dev/block/mapper/system${SLOT}" "ro.build.version.release" || true)
fi
if [ -z "$SYS_SPL" ]; then
	SYS_SPL=$(read_prop_from_block "/tmp/spl_system" "/dev/block/mapper/system${SLOT}" "ro.build.version.security_patch" || true)
fi
if [ -z "$VEN_SPL" ]; then
	VEN_SPL=$(read_prop_from_block "/tmp/spl_vendor" "/dev/block/mapper/vendor${SLOT}" "ro.vendor.build.security_patch" || true)
fi

if [ -n "$REL" ]; then
	resetprop ro.build.version.release "$REL"
	resetprop ro.build.version.release_or_codename "$REL"
	resetprop ro.system.build.version.release "$REL"
	log "Override release to $REL (release_or_codename=$REL)"
fi

if [ -n "$SYS_SPL" ]; then
	resetprop ro.build.version.security_patch "$SYS_SPL"
	log "Override ro.build.version.security_patch to $SYS_SPL"
fi

if [ -n "$VEN_SPL" ]; then
	resetprop ro.vendor.build.security_patch "$VEN_SPL"
	log "Override ro.vendor.build.security_patch to $VEN_SPL"
fi

# Start qseecomd now that SPL is overridden and /vendor is ramdisk
setprop vendor.twrp.spl_ready 1
log "vendor.twrp.spl_ready=1, waiting up to 15s for vendor.sys.listeners.registered=true"

i=0
while [ "$i" -lt 30 ]; do
	if [ "$(getprop vendor.sys.listeners.registered)" = "true" ]; then
		log "listeners registered; starting QTI crypto HALs (stage 1)"
		setprop vendor.twrp.crypto_hal_ready 1
		break
	fi
	i=$((i + 1))
	sleep 0.5
done

if [ "$(getprop vendor.sys.listeners.registered)" != "true" ]; then
	log "ERROR: vendor.sys.listeners.registered!=true after 15s ($(getprop vendor.sys.listeners.registered)); NOT starting keymint/gatekeeper to keep YARP alive."
	exit 1
fi

# Wait up to 10s (20 x 0.5s) for vendor.keymint-qti to stay running, then settle 2s before keystore2
k=0
KM_OK=0
while [ "$k" -lt 20 ]; do
	if pidof android.hardware.security.keymint-service-qti >/dev/null 2>&1 && \
	   [ "$(getprop init.svc.vendor.keymint-qti)" = "running" ]; then
		KM_OK=1
		break
	fi
	k=$((k + 1))
	sleep 0.5
done

if [ "$KM_OK" != "1" ]; then
	log "ERROR: vendor.keymint-qti not running after 10s (svc=$(getprop init.svc.vendor.keymint-qti)); NOT starting keystore2."
	exit 1
fi

sleep 2
log "vendor.keymint-qti active; starting keystore2 (stage 2)"
setprop vendor.twrp.keystore_ready 1

# Wait up to 5s (10 x 0.5s) for keystore2 to start, then verify the same PID stays alive for 1s
KS_PID=""
m=0
while [ "$m" -lt 10 ]; do
	CAND_PID=$(pidof keystore2 2>/dev/null || true)
	CAND_PID=${CAND_PID%% *}
	if [ -n "$CAND_PID" ] && \
	   [ "$(getprop init.svc.keystore2)" = "running" ]; then
		KS_PID="$CAND_PID"
		break
	fi
	m=$((m + 1))
	sleep 0.5
done

if [ -z "$KS_PID" ]; then
	log "ERROR: keystore2 not running after 5s (svc=$(getprop init.svc.keystore2)); NOT setting crypto.ready=1"
	exit 1
fi

sleep 1
CUR_PID=$(pidof keystore2 2>/dev/null || true)
CUR_PID=${CUR_PID%% *}
if [ -n "$CUR_PID" ] && [ "$CUR_PID" = "$KS_PID" ] && \
   [ -d "/proc/$KS_PID" ] && \
   [ "$(getprop init.svc.keystore2)" = "running" ]; then
	setprop crypto.ready 1
	setprop vendor.twrp.crypto_ready 1
	log "crypto.ready=1 (keystore2 pid=$KS_PID running cleanly after 1s check)"
	exit 0
fi

log "ERROR: keystore2 crashed or restarted after start (initial_pid=$KS_PID, current_pid=${CUR_PID:-none}, svc=$(getprop init.svc.keystore2)); NOT setting crypto.ready=1"
exit 1
