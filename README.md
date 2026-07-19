# Ryujin Doom

DOOM for the ASUS ROG Ryujin III Extreme cooler's 640x480 LCD
(`0b05:1bcb`). It runs [doomgeneric](https://github.com/ozkl/doomgeneric),
streams its framebuffer to the cooler, and cycles DOOM's title screen and
DEMO1-3 attract-mode demos without an input device.

## Demo

<p align="center">
  <img src="docs/media/ryujin-doom-demo.gif" width="320"
       alt="Ryujin Doom running on the Ryujin III Extreme LCD">
</p>

## Install

Tagged releases provide Debian/Ubuntu `.deb`, Fedora/RHEL `.rpm`, Windows
`setup.exe`, portable Linux `.tar.gz` and Windows `.zip` packages, plus
SHA-256 checksums.

No WAD is bundled. Installers try to download the checksum-verified Doom 1.9
shareware IWAD, but a network failure does not fail installation. They create
`README-WAD.txt` beside the expected WAD. Use the included manager at any time
to install another free game or import an IWAD you own without reinstalling.

Linux:

```sh
ryujin-doom-wad list
sudo ryujin-doom-wad install doom-shareware
sudo ryujin-doom-wad import /path/to/DOOM2.WAD
systemctl status ryujin-doom
journalctl -u ryujin-doom -f
```

The service runs as the dedicated `ryujin-doom` user. The application is under
`/opt/ryujin-doom`, while the active WAD and writable data are under
`/var/lib/ryujin-doom`. A device-specific udev rule grants USB access.

Windows (Administrator PowerShell):

```powershell
& "$env:ProgramFiles\ryujin-doom\ryujin-doom-wad.ps1" list
& "$env:ProgramFiles\ryujin-doom\ryujin-doom-wad.ps1" install doom-shareware
& "$env:ProgramFiles\ryujin-doom\ryujin-doom-wad.ps1" import "C:\Games\DOOM2.WAD"
Get-Service ryujin-doom
```

Windows stores the active WAD and failure instructions under
`%ProgramData%\ryujin-doom`. The service starts automatically once a WAD is
available.

The cooler's HID interface must keep its normal HID driver. Its separate LCD
bulk interface needs a WinUSB-compatible driver; if the installer warns that
none is present, use Zadig on **only the LCD bulk interface**. Replacing the HID
interface driver breaks telemetry. See libusb's
[Windows driver guidance](https://github.com/libusb/libusb/wiki/Windows).
The installer also installs PawnIO and a LibreHardwareMonitor provider for CPU
temperature. Portable `.zip` users must run `PawnIO_setup.exe -install` once
from Administrator PowerShell.

## Build and run

```sh
make                         # fetch pinned doomgeneric and build
make wad                     # fetch the Doom 1.9 shareware IWAD
make wads                    # fetch every verified catalog IWAD
make run                     # run with Doom shareware
make run WAD=freedoom2       # run another catalog IWAD
make dist                    # build all release artifacts under dist/
```

The cooler must be connected. On Linux, liquidctl's udev rule
(`/etc/udev/rules.d/71-liquidctl.rules`) normally grants the logged-in user
access without `sudo`.

The WAD fetcher checks both downloads and extracted WADs against pinned SHA-256
hashes:

```sh
./scripts/fetch-wad.sh list
./scripts/fetch-wad.sh fetch freedoom1
./scripts/fetch-wad.sh fetch freedoom2
```

Catalog entries:

- `doom-shareware` — original Doom 1.9 shareware episode (default)
- `freedoom1` — free/libre Doom-compatible four-episode game
- `freedoom2` — free/libre Doom II-compatible 32-map game

Ordinary PWADs are not included because most still require a corresponding
IWAD. Retail WADs can be supplied with `-iwad /path/to/DOOM.WAD`.

Source-checkout service installers fetch dependencies, apply the tracked HUD
patch, build the application, register the service, and make the same non-fatal
WAD download attempt:

```sh
./scripts/install-linux.sh       # Linux
./scripts/uninstall-linux.sh
```

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install-windows.ps1   # Administrator PowerShell
.\scripts\uninstall-windows.ps1
```

Set `RYUJIN_DOOM_WAD=freedoom2` for the Linux installer, or pass
`-Wad freedoom2` on Windows, to change the initial game.

Useful runtime flags:

- `--no-lcd` — run without USB for headless testing
- `--dump-frames <dir>` — write rendered frames as binary PPM files
- `--fake-stats <liquid>,<pump>,<fan>[,<cpu>]` — inject HUD telemetry
- `--exit-after <frames>` — stop after a fixed number of frames

## Telemetry HUD

The status bar retains its red numerals, leather panels, and Doomguy's
damage-driven face while replacing unused weapon panels with live values:

- `PUMP RPM` — pump speed
- `LIQ C` — rounded liquid temperature
- `FAN RPM` — embedded fan speed
- `CPU C` — CPU package/control temperature

Telemetry refreshes once per second. Linux reads AMD `k10temp`/`zenpower`
(`Tdie`, then compensated `Tctl`) or Intel `coretemp` (`Package id 0`). Windows
uses the bundled LibreHardwareMonitor provider. The CPU field stays blank when
no supported sensor is available.

## Release builds

To reproduce the packages on Linux:

```sh
sudo apt-get install build-essential pkg-config libusb-1.0-0-dev git curl \
  patch zip unzip dpkg-dev rpm gcc-mingw-w64-x86-64 \
  binutils-mingw-w64-x86-64 cmake nsis
make dist VERSION=1.2.3 JOBS=8
```

The builder downloads checksum-pinned libusb, HIDAPI, WinSW, and doomgeneric
sources, then emits all artifacts under `dist/`. It never downloads a WAD.
For a manual native Windows build, use an MSYS2 UCRT64 shell with `gcc`,
`pkgconf`, `libusb`, and `hidapi`, then run:

```sh
make PLATFORM=windows CC=gcc clean all wad
```

## Hardware protocol

The cooler control interface uses 65-byte HID reports prefixed with `0xEC`.
LCD pixels are sent to bulk OUT endpoint `0x02` as a 640x480, top-to-bottom,
left-to-right BGR888 frame (921,600 bytes). The transport accepts RGB888 and
swaps red and blue before upload.

## License and credits

Ryujin Doom is GPL-3.0-or-later; see [LICENSE](LICENSE). Fetched Doom engine
sources are GPL-2.0-or-later, and Ryujin protocol work derived from
[liquidctl](https://github.com/liquidctl/liquidctl) is GPL-3.0-or-later. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and dependency
licenses.

doomgeneric is pinned to commit
`dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`; the build applies
`patches/doomgeneric-ryujin-stats.patch`. Freedoom is BSD-licensed, and
`DOOM1.WAD` is the freely redistributable shareware release.

No WAD, commercial Doom asset, vendor checkout, executable, or installer is
committed. `scripts/check-release-tree.sh` enforces this locally and in CI.
