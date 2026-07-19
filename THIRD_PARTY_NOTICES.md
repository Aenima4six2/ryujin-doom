# Third-party notices

Ryujin Doom is distributed under the GNU General Public License version 3 or, at
your option, any later version. See `LICENSE`.

## Doom and Doomgeneric

The release build fetches Doomgeneric at the commit pinned in `Makefile` and
applies the tracked Ryujin Doom patch. The vendor tree is not stored in this
repository. Doom engine portions are copyright id Software and other listed
contributors and are available under GPL-2.0-or-later. The upstream GPLv2
license is included in binary releases as `DOOM-COPYING.txt`.

Source: <https://github.com/ozkl/doomgeneric>

## liquidctl

The Ryujin protocol implementation was derived from liquidctl's
`asus_ryujin.py` driver and its protocol documentation. That work is copyright
Florian Freudiger and contributors and is available under GPL-3.0-or-later.

Source: <https://github.com/liquidctl/liquidctl>

## Windows release dependencies

Windows releases contain WinSW under the MIT License and statically link:

- libusb 1.0 under LGPL-2.1-or-later;
- HIDAPI under its upstream multi-license terms (used here under GPLv3).

Windows releases also bundle LibreHardwareMonitor 0.9.6 under the Mozilla
Public License 2.0 and use its PawnIO provider to read AMD and Intel CPU
package/control temperature. LibreHardwareMonitor's complete license and
third-party notices are included in the Windows installer and portable
archive; corresponding source is available at:

<https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/tree/v0.9.6>

The complete dependency license notices are included with the Windows installer
and portable archive. Corresponding dependency versions and sources are pinned in
`scripts/build-release.sh`; the Ryujin Doom source needed to rebuild and relink the
application is linked from each release.

## Game data

No WAD or other game-data file is stored in this repository or embedded in a
Ryujin Doom release. The bundled WAD managers can download checksum-pinned Doom
shareware or Freedoom releases after installation. Users can also import an
IWAD they already own. WAD files and download archives are ignored by Git.
