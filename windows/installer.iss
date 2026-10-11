; Inno Setup script for ListenAndRecord (Windows 10 / 11, x64).
#define AppVersion "2.0.0"

[Setup]
AppId={{6F0C2E6B-6A57-4E61-9A4B-3C1C9C2B7E11}
AppName=ListenAndRecord
AppVersion={#AppVersion}
AppPublisher=ListenAndRecord
DefaultDirName={autopf}\ListenAndRecord
DefaultGroupName=ListenAndRecord
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build
OutputBaseFilename=ListenAndRecord-Setup
SetupIconFile=ListenAndRecord\Assets\AppIcon.ico
UninstallDisplayIcon={app}\ListenAndRecord.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows-publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\ListenAndRecord"; Filename: "{app}\ListenAndRecord.exe"
Name: "{autodesktop}\ListenAndRecord"; Filename: "{app}\ListenAndRecord.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ListenAndRecord.exe"; Description: "{cm:LaunchProgram,ListenAndRecord}"; Flags: nowait postinstall skipifsilent
