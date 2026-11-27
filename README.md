# YARP (Based on TWRP 16) for OPPO Find X6 Pro (PGEM10)

## Compatibility
- **Device:** OPPO Find X6 Pro (`PGEM10`), unlocked bootloader required.
- **OS:** ColorOS 16 (tested on `16.0.1.300`; newer `16.0.5.x` builds should work via automatic OS/SPL detection; ColorOS 15 untested).

## Features
- `/data` decryption (PIN / password).
- Working touchscreen, vibration, MTP, ADB, VOOC charging info, and partition backups (including EFS).
- Working `fastbootd` with touch UI and USB switching *(note: `fastboot oem` commands are unsupported, same as stock)*.
- **Flashlight** control with full 10–100% brightness adjustment.
- **Modules Manager** for Magisk / KernelSU / APatch (enable/disable, delete, or disable all modules).
- Built-in CLI utilities (`sqlite3`, `nano`, `lptools`, `zstd`, `magiskboot`, etc.).

## Removed for Safety
- Hidden in the UI to protect against accidental soft-bricks: **Disable AVB 2.0**, **Install Kernel**, **Fix Contexts**, and **Flash Current YARP**.

## Flashing

### Backup stock recovery first
```sh
su -c 'dd if=/dev/block/by-name/recovery$(getprop ro.boot.slot_suffix) of=/sdcard/Download/stock_recovery.img bs=4194304'
```

### 1. From current TWRP / YARP
`Install` → `Install Image` → choose `recovery.img` → select **Recovery** → swipe to flash.

### 2. Via Root (one-liner)
```sh
su -c 'dd if=/sdcard/Download/recovery.img of=/dev/block/by-name/recovery$(getprop ro.boot.slot_suffix) bs=4194304 conv=fsync && sync'
```

### 3. Via Fastboot (`bootloader` or `fastbootd`)
```sh
fastboot flash recovery recovery.img
```

### Keep recovery after an OTA update (before rebooting)
```sh
su -c 'S=$([ "$(getprop ro.boot.slot_suffix)" = "_a" ] && echo _b || echo _a); dd if=/sdcard/Download/recovery.img of=/dev/block/by-name/recovery${S} bs=4194304 conv=fsync && sync'
```

---

Licensed under [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html).
