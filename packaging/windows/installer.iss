#ifndef AppVersion
  #error AppVersion is required
#endif

[Setup]
AppId=arknights_story_player
AppName=方舟档案室
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\ArknightsStoryPlayer
DefaultGroupName=方舟档案室
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=arknights_story_player-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\arknights_story_player.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\方舟档案室"; Filename: "{app}\arknights_story_player.exe"

[Run]
Filename: "{app}\arknights_story_player.exe"; Description: "启动方舟档案室"; Flags: nowait postinstall skipifsilent
