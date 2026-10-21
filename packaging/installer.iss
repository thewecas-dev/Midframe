; Inno Setup script; packaging\build.ps1 passes /DAppDir=<build\app>.
#ifndef AppDir
  #error Pass /DAppDir=<path to build\app>
#endif

[Setup]
AppName=Tween
AppVersion=0.2.0
AppPublisher=Tween contributors
AppPublisherURL=https://github.com/REPLACE_ME/tween
DefaultDirName={localappdata}\Tween
SetupIconFile={#AppDir}\icon.ico
UninstallDisplayIcon={app}\icon.ico
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputBaseFilename=Tween-Setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/fast
; The TensorRT runtime is several GB, beyond a single setup file's limit.
DiskSpanning=yes
DiskSliceSize=max

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Tween"; Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\icon.ico"
Name: "{autodesktop}\Tween"; Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\icon.ico"; Tasks: desktopicon

[UninstallDelete]
Type: filesandordirs; Name: "{app}\portable_config\engines"
Type: files; Name: "{app}\portable_config\framegen-last.json"
