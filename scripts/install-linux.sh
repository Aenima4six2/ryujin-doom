#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
install_dir=/opt/ryujin-doom
state_dir=/var/lib/ryujin-doom
service_file=/etc/systemd/system/ryujin-doom.service
rules_file=/etc/udev/rules.d/71-ryujin-doom.rules
wad_id=${RYUJIN_DOOM_WAD:-doom-shareware}

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    command -v sudo >/dev/null 2>&1 || {
        echo "install-linux.sh requires root privileges or sudo" >&2
        exit 1
    }
    sudo_cmd=(sudo)
fi

as_root() {
    "${sudo_cmd[@]}" "$@"
}

install_dependencies() {
    if [[ ${RYUJIN_DOOM_SKIP_DEPS:-0} == 1 ]]; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update
        as_root apt-get install -y build-essential pkg-config libusb-1.0-0-dev git curl patch unzip ca-certificates acl
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y gcc make pkgconf-pkg-config libusb1-devel git curl patch unzip ca-certificates acl
    elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -S --needed --noconfirm base-devel pkgconf libusb git curl patch unzip ca-certificates acl
    elif command -v zypper >/dev/null 2>&1; then
        as_root zypper --non-interactive install gcc make pkg-config libusb-1_0-devel git curl patch unzip ca-certificates acl
    else
        echo "Unsupported package manager; install GCC, make, pkg-config, libusb-1.0 headers, git, curl and patch" >&2
        exit 1
    fi
}

install_dependencies

# This target fetches the pinned doomgeneric source, applies the tracked HUD
# patch, and builds the executable. WAD provisioning is best effort below.
make -C "${repo_dir}" clean
make -C "${repo_dir}" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" all

if ! getent group ryujin-doom >/dev/null; then
    as_root groupadd --system ryujin-doom
fi
if ! getent passwd ryujin-doom >/dev/null; then
    nologin_shell=$(command -v nologin || echo /usr/sbin/nologin)
    as_root useradd --system --gid ryujin-doom --home-dir "${state_dir}" \
        --shell "${nologin_shell}" --comment "Ryujin Doom service" ryujin-doom
fi

as_root systemctl stop ryujin-doom.service 2>/dev/null || true
as_root install -d -o root -g root -m 0755 "${install_dir}"
as_root install -d -o ryujin-doom -g ryujin-doom -m 0750 "${state_dir}"
as_root install -d -o root -g root -m 0755 /usr/local/lib/ryujin-doom /usr/local/share/ryujin-doom
as_root install -o root -g root -m 0755 "${repo_dir}/ryujin-doom" "${install_dir}/ryujin-doom"
as_root install -o root -g root -m 0755 "${repo_dir}/scripts/ryujin-doom-wad" /usr/local/bin/ryujin-doom-wad
as_root install -o root -g root -m 0755 "${repo_dir}/scripts/fetch-wad.sh" /usr/local/lib/ryujin-doom/fetch-wad.sh
as_root install -o root -g root -m 0644 "${repo_dir}/assets/wads.catalog" /usr/local/share/ryujin-doom/wads.catalog
as_root install -o root -g root -m 0644 "${repo_dir}/packaging/linux/README-WAD.txt" /usr/local/share/ryujin-doom/README-WAD.txt
as_root install -o root -g root -m 0644 "${repo_dir}/packaging/linux/ryujin-doom.service" "${service_file}"
as_root install -o root -g root -m 0644 "${repo_dir}/packaging/linux/71-ryujin-doom.rules" "${rules_file}"

as_root udevadm control --reload-rules
as_root udevadm trigger --subsystem-match=usb --attr-match=idVendor=0b05 --attr-match=idProduct=1bcb || true
as_root udevadm trigger --subsystem-match=hidraw || true
as_root udevadm settle || true
as_root systemctl daemon-reload
as_root systemctl enable ryujin-doom.service

if ! as_root test -f "${state_dir}/IWAD.WAD"; then
    echo "Ryujin Doom: attempting to download ${wad_id}..."
    if as_root /usr/local/bin/ryujin-doom-wad install "${wad_id}" || \
       as_root test -f "${state_dir}/IWAD.WAD"; then
        as_root find "${state_dir}/README-WAD.txt" -delete 2>/dev/null || true
    else
        as_root install -o ryujin-doom -g ryujin-doom -m 0644 \
            "${repo_dir}/packaging/linux/README-WAD.txt" \
            "${state_dir}/README-WAD.txt"
        echo "Ryujin Doom installed, but the WAD download failed." >&2
        echo "See ${state_dir}/README-WAD.txt; installation will continue." >&2
    fi
else
    as_root systemctl restart ryujin-doom.service
fi

echo "Ryujin Doom installed and started."
echo "Status:  systemctl status ryujin-doom"
echo "Logs:    journalctl -u ryujin-doom -f"
