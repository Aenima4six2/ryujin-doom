Ryujin Doom was installed, but the installer could not download the default
Doom 1.9 shareware IWAD. The Ryujin Doom service will remain stopped until an
IWAD is available.

Open PowerShell as Administrator and retry the verified download:

    & "$env:ProgramFiles\ryujin-doom\ryujin-doom-wad.ps1" install doom-shareware

To use a commercial Doom IWAD that you already own:

    & "$env:ProgramFiles\ryujin-doom\ryujin-doom-wad.ps1" import "C:\Games\DOOM2.WAD"

The active file is stored at:

    C:\ProgramData\ryujin-doom\IWAD.WAD

Do not place a PWAD add-on there; Ryujin Doom requires a complete IWAD.
