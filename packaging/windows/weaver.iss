#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\zig-out\bin"
#endif
[Setup]
AppId={{478755BA-E502-43EA-B1BF-244BF8A3AB91}
AppName=Weaver
AppVersion={#AppVersion}
AppPublisher=Weaver
DefaultDirName={localappdata}\Programs\Weaver
DefaultGroupName=Weaver
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=weaver-windows-x86_64-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\assets\weaver.ico
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\weaver.exe
SetupLogging=yes
[Files]
Source: "{#SourceDir}\weaver.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\..\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Weaver"; Filename: "{app}\weaver.exe"; AppUserModelID: "app.weaver.desktop"
[Run]
Filename: "{app}\weaver.exe"; Description: "Launch Weaver"; Flags: nowait postinstall skipifsilent
