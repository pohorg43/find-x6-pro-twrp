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

# Wait up to 15s (30 x 0.5s) for TWRP UnMount_Main_Partitions() to unmount logical /vendor
v=0
while [ "$v" -lt 30 ]; do
	if ! grep -q " /vendor " /proc/mounts 2>/dev/null; then
		break
	fi
	v=$((v + 1))
	sleep 0.5
done

if grep -q " /vendor " /proc/mounts 2>/dev/null; then
	log "ERROR: /vendor still mounted after 15s, skipping crypto stack to avoid loop."
	exit 1
fi
log "/vendor unmounted cleanly; ramdisk overlay active."

read_prop_from_block() {
	MNT="$1"
	BLK="$2"
	PROP="$3"
	VAL=""

	if [ ! -e "$BLK" ]; then
		return 1
	fi

	mkdir -p "$MNT"
	if ! mount -o ro "$BLK" "$MNT" 2>/dev/null; then
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
	log "Override release to $REL"
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
		setprop vendor.twrp.crypto_ready 1
		log "vendor.twrp.crypto_ready=1 (listeners registered)"
		exit 0
	fi
	i=$((i + 1))
	sleep 0.5
done

log "ERROR: vendor.sys.listeners.registered!=true after 15s ($(getprop vendor.sys.listeners.registered)); NOT starting keymint/gatekeeper to keep YARP alive."
exit 1
