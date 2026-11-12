; SPDX-License-Identifier: GPL-2.0-or-later
; Compile with ISCC /DPackageDir=<absolute staged package> /DOutputDir=<absolute output>.
#ifndef PackageDir
  #error PackageDir must point to the validated Windows package directory.
#endif
#ifndef OutputDir
  #error OutputDir must be specified.
#endif
#define AppVersion "0.3.7"

[Setup]
AppId=org.barriershare.desktop
AppName=Barrier Share
AppVersion={#AppVersion}
AppPublisher=Barrier Share contributors
AppPublisherURL=https://github.com/sunnylinisme/barrier
AppSupportURL=https://github.com/sunnylinisme/barrier
DefaultDirName={localappdata}\Programs\Barrier Share
DefaultGroupName=Barrier Share
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.18362
AppMutex=Local\BarrierShare.Desktop
SetupMutex=Local\BarrierShare.Setup
CloseApplications=no
RestartApplications=no
WizardStyle=modern
ShowLanguageDialog=auto
OutputDir={#OutputDir}
OutputBaseFilename=BarrierShare-Setup-{#AppVersion}-x64
SetupIconFile={#AddBackslash(SourcePath)}icons\BarrierShare.ico
UninstallDisplayName=Barrier Share
UninstallDisplayIcon={app}\BarrierShare.exe
VersionInfoVersion={#AppVersion}.0
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesetraditional"; MessagesFile: "{#AddBackslash(SourcePath)}installer-languages\ChineseTraditional.isl"

[Messages]
english.SetupAppRunningError=%1 is running.%n%nChoose Exit from its notification-area icon, then click OK to continue, or Cancel to exit Setup.
english.UninstallAppRunningError=%1 is running.%n%nChoose Exit from its notification-area icon, then click OK to continue, or Cancel to exit Uninstall.
chinesetraditional.SetupAppRunningError=偵測到 %1 正在執行。%n%n請從右下角系統匣的圖示選擇「結束」，再按「確定」繼續安裝，或按「取消」離開。
chinesetraditional.UninstallAppRunningError=偵測到 %1 正在執行。%n%n請從右下角系統匣的圖示選擇「結束」，再按「確定」繼續解除安裝，或按「取消」離開。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PackageDir}\BarrierShare.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barriers.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barrierc.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barrier-pair.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\barrier-link.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\GUI-README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\COMMIT.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDir}\licenses\*.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Barrier Share"; Filename: "{app}\BarrierShare.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Barrier Share"; Filename: "{app}\BarrierShare.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\BarrierShare.exe"; Description: "{cm:LaunchProgram,Barrier Share}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent unchecked

; Settings and pairing live in a separate LocalAppData\BarrierShare directory.
; No UninstallDelete entry: uninstall removes only this install's recorded files.
