Unicode True
!include "LogicLib.nsh"
!include "x64.nsh"

!ifndef VERSION
  !error "VERSION is required"
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE is required"
!endif
!ifndef RYUJIN_DOOM_EXE
  !error "RYUJIN_DOOM_EXE is required"
!endif
!ifndef LIBUSB_DLL
  !error "LIBUSB_DLL is required"
!endif
!ifndef HIDAPI_DLL
  !error "HIDAPI_DLL is required"
!endif
!ifndef WINSW_EXE
  !error "WINSW_EXE is required"
!endif
!ifndef SERVICE_XML
  !error "SERVICE_XML is required"
!endif
!ifndef COPYING_FILE
  !error "COPYING_FILE is required"
!endif
!ifndef DOOM_COPYING_FILE
  !error "DOOM_COPYING_FILE is required"
!endif
!ifndef NOTICES_FILE
  !error "NOTICES_FILE is required"
!endif
!ifndef LIBUSB_LICENSE
  !error "LIBUSB_LICENSE is required"
!endif
!ifndef HIDAPI_LICENSE
  !error "HIDAPI_LICENSE is required"
!endif
!ifndef HIDAPI_GPL_LICENSE
  !error "HIDAPI_GPL_LICENSE is required"
!endif
!ifndef WINSW_LICENSE
  !error "WINSW_LICENSE is required"
!endif
!ifndef SOURCE_FILE
  !error "SOURCE_FILE is required"
!endif
!ifndef HARDWARE_MONITOR_DIR
  !error "HARDWARE_MONITOR_DIR is required"
!endif
!ifndef PAWNIO_SETUP
  !error "PAWNIO_SETUP is required"
!endif
!ifndef LHM_LICENSE
  !error "LHM_LICENSE is required"
!endif
!ifndef LHM_NOTICES
  !error "LHM_NOTICES is required"
!endif
!ifndef WAD_HELPER
  !error "WAD_HELPER is required"
!endif
!ifndef WAD_CATALOG
  !error "WAD_CATALOG is required"
!endif
!ifndef WAD_README
  !error "WAD_README is required"
!endif
!ifndef STOP_HARDWARE_MONITOR
  !error "STOP_HARDWARE_MONITOR is required"
!endif

Name "Ryujin Doom ${VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\ryujin-doom"
InstallDirRegKey HKLM "Software\ryujin-doom" "InstallDir"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Ryujin Doom"
VIAddVersionKey "FileDescription" "Ryujin Doom Windows Service Installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Ryujin Doom contributors"

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Ryujin Doom service" SEC_MAIN
  SetRegView 64
  SetShellVarContext all

  IfFileExists "$INSTDIR\ryujin-doom-service.exe" 0 service_stopped
    nsExec::ExecToLog '"$INSTDIR\ryujin-doom-service.exe" stop'
    Pop $0
    nsExec::ExecToLog '"$INSTDIR\ryujin-doom-service.exe" uninstall'
    Pop $0

  service_stopped:
  SetOutPath "$INSTDIR"
  File /oname=ryujin-doom.exe "${RYUJIN_DOOM_EXE}"
  File /oname=libusb-1.0.dll "${LIBUSB_DLL}"
  File /oname=libhidapi.dll "${HIDAPI_DLL}"
  File /oname=ryujin-doom-service.exe "${WINSW_EXE}"
  File /oname=ryujin-doom-service.xml "${SERVICE_XML}"
  File /oname=ryujin-doom-wad.ps1 "${WAD_HELPER}"
  File /oname=wads.catalog "${WAD_CATALOG}"
  File /oname=COPYING.txt "${COPYING_FILE}"
  File /oname=DOOM-COPYING.txt "${DOOM_COPYING_FILE}"
  File /oname=THIRD_PARTY_NOTICES.md "${NOTICES_FILE}"
  File /oname=LIBUSB-LGPL-2.1.txt "${LIBUSB_LICENSE}"
  File /oname=HIDAPI-LICENSE.txt "${HIDAPI_LICENSE}"
  File /oname=HIDAPI-GPL-3.0.txt "${HIDAPI_GPL_LICENSE}"
  File /oname=WINSW-MIT.txt "${WINSW_LICENSE}"
  File /oname=LIBREHARDWAREMONITOR-MPL-2.0.txt "${LHM_LICENSE}"
  File /oname=LIBREHARDWAREMONITOR-NOTICES.txt "${LHM_NOTICES}"
  File /oname=PawnIO_setup.exe "${PAWNIO_SETUP}"
  File /oname=stop-hardware-monitor.ps1 "${STOP_HARDWARE_MONITOR}"
  File /oname=SOURCE.txt "${SOURCE_FILE}"
  SetOutPath "$INSTDIR\hardware-monitor"
  File /r "${HARDWARE_MONITOR_DIR}\*.*"
  SetOutPath "$INSTDIR"
  CreateDirectory "$INSTDIR\logs"
  CreateDirectory "$APPDATA\ryujin-doom"

  DetailPrint "Installing the PawnIO hardware telemetry provider..."
  nsExec::ExecToLog '"$INSTDIR\PawnIO_setup.exe" -install'
  Pop $0
  ${If} $0 != 0
    DetailPrint "PawnIO setup returned $0; CPU temperature may be unavailable."
  ${EndIf}

  nsExec::ExecToLog '"$INSTDIR\ryujin-doom-service.exe" install'
  Pop $0
  ${If} $0 != 0
    Abort "Could not register the Ryujin Doom Windows service (exit code $0)."
  ${EndIf}

  IfFileExists "$APPDATA\ryujin-doom\IWAD.WAD" wad_ready 0
    DetailPrint "Attempting to download Doom 1.9 shareware..."
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\ryujin-doom-wad.ps1" install doom-shareware'
    Pop $0
    IfFileExists "$APPDATA\ryujin-doom\IWAD.WAD" wad_ready wad_download_failed

  wad_download_failed:
    SetOutPath "$APPDATA\ryujin-doom"
    File /oname=README-WAD.txt "${WAD_README}"
    SetOutPath "$INSTDIR"
    DetailPrint "The default WAD download failed; installation will continue."
    DetailPrint "See $APPDATA\ryujin-doom\README-WAD.txt for recovery steps."
    Goto wad_attempt_done

  wad_ready:
    Delete "$APPDATA\ryujin-doom\README-WAD.txt"
    DetailPrint "Starting the Ryujin Doom service..."
    nsExec::ExecToLog 'sc.exe config ryujin-doom start= auto'
    Pop $0
    ${If} $0 != 0
      Abort "Could not configure the Ryujin Doom service to start automatically (exit code $0)."
    ${EndIf}
    nsExec::ExecToLog '"$INSTDIR\ryujin-doom-service.exe" start'
    Pop $0
    ${If} $0 != 0
      Abort "Could not start the Ryujin Doom service (exit code $0)."
    ${EndIf}

  wad_attempt_done:
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "Software\ryujin-doom" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom" "DisplayName" "Ryujin Doom"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom" "Publisher" "Ryujin Doom contributors"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom" "NoRepair" 1

  MessageBox MB_ICONINFORMATION|MB_OK "Ryujin Doom was installed and attempted to download Doom 1.9 shareware.$\r$\n$\r$\nTo choose or import another IWAD, run $INSTDIR\ryujin-doom-wad.ps1 from Administrator PowerShell.$\r$\n$\r$\nIf the download failed, see $APPDATA\ryujin-doom\README-WAD.txt.$\r$\n$\r$\nThe LCD bulk interface must use a WinUSB-compatible driver. Do not replace the cooler HID interface driver."
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all
  nsExec::ExecToLog '"$INSTDIR\ryujin-doom-service.exe" stop'
  Pop $0
  nsExec::ExecToLog '"$INSTDIR\ryujin-doom-service.exe" uninstall'
  Pop $0
  DetailPrint "Stopping the CPU temperature provider..."
  nsExec::ExecToLog 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\stop-hardware-monitor.ps1" -InstallDir "$INSTDIR"'
  Pop $0
  ${If} $0 != 0
    Abort "The CPU temperature provider is still running. Close any Ryujin Doom process and try again."
  ${EndIf}
  IfFileExists "$INSTDIR\PawnIO_setup.exe" 0 pawnio_removed
    DetailPrint "Removing the PawnIO hardware telemetry provider..."
    nsExec::ExecToLog '"$INSTDIR\PawnIO_setup.exe" -uninstall'
    Pop $0
  pawnio_removed:

  Delete "$INSTDIR\ryujin-doom.exe"
  Delete "$INSTDIR\libusb-1.0.dll"
  Delete "$INSTDIR\libhidapi.dll"
  Delete "$INSTDIR\ryujin-doom-service.exe"
  Delete "$INSTDIR\ryujin-doom-service.xml"
  Delete "$INSTDIR\ryujin-doom-wad.ps1"
  Delete "$INSTDIR\wads.catalog"
  Delete "$INSTDIR\COPYING.txt"
  Delete "$INSTDIR\DOOM-COPYING.txt"
  Delete "$INSTDIR\THIRD_PARTY_NOTICES.md"
  Delete "$INSTDIR\LIBUSB-LGPL-2.1.txt"
  Delete "$INSTDIR\HIDAPI-LICENSE.txt"
  Delete "$INSTDIR\HIDAPI-GPL-3.0.txt"
  Delete "$INSTDIR\WINSW-MIT.txt"
  Delete "$INSTDIR\LIBREHARDWAREMONITOR-MPL-2.0.txt"
  Delete "$INSTDIR\LIBREHARDWAREMONITOR-NOTICES.txt"
  Delete "$INSTDIR\PawnIO_setup.exe"
  Delete "$INSTDIR\stop-hardware-monitor.ps1"
  Delete "$INSTDIR\SOURCE.txt"
  Delete "$INSTDIR\uninstall.exe"
  RMDir /r "$INSTDIR\hardware-monitor"
  RMDir /r "$INSTDIR\logs"
  RMDir "$INSTDIR"

  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\ryujin-doom"
  DeleteRegKey HKLM "Software\ryujin-doom"
  DetailPrint "WAD data was preserved in $APPDATA\ryujin-doom."
SectionEnd
