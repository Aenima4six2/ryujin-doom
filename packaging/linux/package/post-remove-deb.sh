#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl reset-failed ryujin-doom.service 2>/dev/null || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    for sys_device in /sys/class/hidraw/hidraw*; do
        [ -r "${sys_device}/device/uevent" ] || continue
        grep -q '^HID_ID=.*:00000B05:00001BCB$' \
            "${sys_device}/device/uevent" || continue
        device=/dev/${sys_device##*/}
        setfacl --remove-all "${device}" 2>/dev/null || true
        chown root:root "${device}" 2>/dev/null || true
        chmod 0600 "${device}" 2>/dev/null || true
    done
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=0b05 \
        --attr-match=idProduct=1bcb || true
    udevadm trigger --subsystem-match=hidraw || true
fi
