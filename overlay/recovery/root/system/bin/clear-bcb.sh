#!/system/bin/sh
BCB="/dev/block/bootdevice/by-name/misc"
[ -e "$BCB" ] || BCB="/dev/block/by-name/misc"
[ -e "$BCB" ] || exit 0

CMD="$(dd if="$BCB" bs=32 count=1 2>/dev/null | tr -d '\0\r\n')"
REC_BLOCK="$(dd if="$BCB" bs=64 skip=1 count=4 2>/dev/null | tr -d '\0')"
case "$CMD" in
    boot-fastboot*)
        echo "clear-bcb: BCB command=$CMD detected, skipping early clear for fastbootd" > /dev/kmsg
        exit 0
        ;;
esac
case "$REC_BLOCK" in
    *--fastboot*)
        echo "clear-bcb: BCB --fastboot recovery arg detected, skipping early clear for fastbootd" > /dev/kmsg
        exit 0
        ;;
esac

MAGIC="$(dd if="$BCB" bs=13 count=1 2>/dev/null | tr -d '\0')"
REC_MAGIC="$(dd if="$BCB" bs=1 skip=64 count=8 2>/dev/null | tr -d '\0')"
if [ "$MAGIC" = "boot-recovery" ] || [ "$REC_MAGIC" = "recovery" ]; then
    if DD_OUT="$(dd if=/dev/zero of="$BCB" bs=128 count=1 conv=notrunc 2>&1)"; then
        sync
        AFTER="$(dd if="$BCB" bs=16 count=1 2>/dev/null | tr -d '\0')"
        if [ -z "$AFTER" ]; then
            echo "clear-bcb: cleared $MAGIC/$REC_MAGIC BCB in $BCB (verified empty)" > /dev/kmsg
        else
            echo "clear-bcb: WARN cleared BCB header but readback='$AFTER'" > /dev/kmsg
        fi
    else
        echo "clear-bcb: ERROR failed to clear BCB in $BCB: $DD_OUT" > /dev/kmsg
    fi
fi
