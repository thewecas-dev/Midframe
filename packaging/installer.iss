; Inno Setup script; packaging\build.ps1 passes /DAppDir=<build\app>.
#ifndef AppDir
  #error Pass /DAppDir=<path to build\app>
#endif

[Setup]
AppName=FrameGen
AppVersion=0.1.0
DefaultDirName={localappdata}\FrameGen
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputBaseFilename=FrameGen-Setup
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
Name: "{autoprograms}\FrameGen"; Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\mpv.exe"
Name: "{autodesktop}\FrameGen"; Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\mpv.exe"; Tasks: desktopicon

[UninstallDelete]
Type: filesandordirs; Name: "{app}\portable_config\engines"
Type: files; Name: "{app}\portable_config\framegen-last.json"
