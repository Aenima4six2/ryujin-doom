Ryujin Doom was installed, but the installer could not download the default
Doom 1.9 shareware IWAD. The Ryujin Doom service will remain stopped until an
IWAD is available.

To retry the verified download:

    sudo ryujin-doom-wad install doom-shareware

To use a commercial Doom IWAD that you already own:

    sudo ryujin-doom-wad import /path/to/DOOM2.WAD

The active file is stored at:

    /var/lib/ryujin-doom/IWAD.WAD

Do not place a PWAD add-on there; Ryujin Doom requires a complete IWAD.
