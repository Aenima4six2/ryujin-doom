#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    if [ "${1:-}" = upgrade ]; then
        systemctl stop ryujin-doom.service || true
    else
        systemctl disable --now ryujin-doom.service || true
    fi
fi
