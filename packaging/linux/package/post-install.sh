#!/bin/sh
set -e

if ! getent group ryujin-doom >/dev/null; then
    groupadd --system ryujin-doom
fi
if ! getent passwd ryujin-doom >/dev/null; then
    nologin_shell=$(command -v nologin || printf '%s' /usr/sbin/nologin)
    useradd --system --gid ryujin-doom --home-dir /var/lib/ryujin-doom \
        --shell "${nologin_shell}" --comment "Ryujin Doom service" ryujin-doom
fi

install -d -o ryujin-doom -g ryujin-doom -m 0750 /var/lib/ryujin-doom

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=0b05 \
        --attr-match=idProduct=1bcb || true
    udevadm trigger --subsystem-match=hidraw || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable ryujin-doom.service
    if [ -f /var/lib/ryujin-doom/IWAD.WAD ]; then
        systemctl restart ryujin-doom.service
    fi
fi

if [ ! -f /var/lib/ryujin-doom/IWAD.WAD ]; then
    echo "Ryujin Doom: attempting to download Doom 1.9 shareware..."
    if /usr/bin/ryujin-doom-wad install doom-shareware || \
       [ -f /var/lib/ryujin-doom/IWAD.WAD ]; then
        rm -f /var/lib/ryujin-doom/README-WAD.txt
    else
        install -o ryujin-doom -g ryujin-doom -m 0644 \
            /usr/share/ryujin-doom/README-WAD.txt \
            /var/lib/ryujin-doom/README-WAD.txt || true
        echo "Ryujin Doom: WAD download failed; installation will continue." >&2
        echo "See /var/lib/ryujin-doom/README-WAD.txt for recovery steps." >&2
    fi
fi
