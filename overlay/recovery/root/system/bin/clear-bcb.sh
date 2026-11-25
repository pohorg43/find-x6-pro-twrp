#!/system/bin/sh
BCB="/dev/block/bootdevice/by-name/misc"
[ -e "$BCB" ] || BCB="/dev/block/by-name/misc"
[ -e "$BCB" ] || exit 0

MAGIC="$(dd if="$BCB" bs=13 count=1 2>/dev/null | tr -d '\0')"
if [ "$MAGIC" = "boot-recovery" ]; then
    dd if=/dev/zero of="$BCB" bs=32 count=1 conv=notrunc 2>/dev/null
    sync
    echo "clear-bcb: boot-recovery cleared" > /dev/kmsg 2>/dev/null || true
fi
