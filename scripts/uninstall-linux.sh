#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || {
        echo "uninstall-linux.sh requires root privileges or sudo" >&2
        exit 1
    }
    sudo_cmd=(sudo)
fi

as_root() {
    "${sudo_cmd[@]}" "$@"
}

as_root systemctl disable --now ryujin-doom.service 2>/dev/null || true
as_root systemctl reset-failed ryujin-doom.service 2>/dev/null || true
as_root find /opt/ryujin-doom -depth -delete 2>/dev/null || true
as_root find /etc/systemd/system/ryujin-doom.service -delete 2>/dev/null || true
as_root find /etc/udev/rules.d/71-ryujin-doom.rules -delete 2>/dev/null || true
as_root find /usr/local/bin/ryujin-doom-wad -delete 2>/dev/null || true
as_root find /usr/local/lib/ryujin-doom -depth -delete 2>/dev/null || true
as_root find /usr/local/share/ryujin-doom -depth -delete 2>/dev/null || true

as_root systemctl daemon-reload
as_root udevadm control --reload-rules
for sys_device in /sys/class/hidraw/hidraw*; do
    [[ -r ${sys_device}/device/uevent ]] || continue
    grep -q '^HID_ID=.*:00000B05:00001BCB$' "${sys_device}/device/uevent" || continue
    device=/dev/${sys_device##*/}
    as_root setfacl --remove-all "${device}" 2>/dev/null || true
    as_root chown root:root "${device}" 2>/dev/null || true
    as_root chmod 0600 "${device}" 2>/dev/null || true
done
as_root udevadm trigger --subsystem-match=usb --attr-match=idVendor=0b05 --attr-match=idProduct=1bcb || true
as_root udevadm trigger --subsystem-match=hidraw || true
as_root udevadm settle || true

if [[ ${1:-} == --purge-data ]]; then
    as_root find /var/lib/ryujin-doom -depth -delete 2>/dev/null || true
    as_root userdel ryujin-doom 2>/dev/null || true
    as_root groupdel ryujin-doom 2>/dev/null || true
    echo "Ryujin Doom and its runtime data were removed."
else
    echo "Ryujin Doom removed; /var/lib/ryujin-doom was preserved."
    echo "Run with --purge-data to remove runtime data and the service account."
fi
