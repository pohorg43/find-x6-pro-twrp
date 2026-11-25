#!/system/bin/sh
BCB="/dev/block/bootdevice/by-name/misc"
[ -e "$BCB" ] || BCB="/dev/block/by-name/misc"
[ -e "$BCB" ] || exit 0

MAGIC="$(dd if="$BCB" bs=13 count=1 2>/dev/null | tr -d '\0')"
REC_MAGIC="$(dd if="$BCB" bs=1 skip=64 count=8 2>/dev/null | tr -d '\0')"
if [ "$MAGIC" = "boot-recovery" ] || [ "$REC_MAGIC" = "recovery" ]; then
    if DD_OUT="$(dd if=/dev/zero of="$BCB" bs=128 count=1 conv=notrunc 2>&1)"; then
        sync
        READBACK="$(dd if="$BCB" bs=128 count=1 2>/dev/null | tr -d '\0')"
        if [ -z "$READBACK" ]; then
            echo "clear-bcb: BCB 128B cleared (readback clean)" > /dev/kmsg 2>/dev/null || true
        else
            echo "clear-bcb: WARNING BCB 128B readback non-empty: $READBACK" > /dev/kmsg 2>/dev/null || true
        fi
    else
        echo "clear-bcb: ERROR dd failed: $DD_OUT" > /dev/kmsg 2>/dev/null || true
    fi
fi
