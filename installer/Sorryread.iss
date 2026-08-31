#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "素若阅读"
#define AppPublisher "Sorryread"
#define AppExeName "素若阅读.exe"
#define AppDirectoryName "Sorryread"
#define WebView2Bootstrapper "MicrosoftEdgeWebView2Setup.exe"

[Setup]
AppId={{BFD21086-6F93-45B8-8F94-6B330EA91E92}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppComments=简洁、专注的 Windows 阅读工具
DefaultDirName={autopf}\{#AppDirectoryName}
DefaultGroupName={#AppName}
DisableWelcomePage=no
DisableDirPage=no
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
SetupArchitecture=x64
MinVersion=10.0
OutputDir=output
OutputBaseFilename=Sorryread-Setup-{#AppVersion}-x64
SetupIconFile=..\assets\icons\app.ico
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern dynamic windows11 includetitlebar hidebevels
WizardBackColor=#FAFAFA
WizardBackColorDynamicDark=#202020
WizardImageFile=
WizardImageFileDynamicDark=
WizardSmallImageFile=..\assets\icons\app.png
WizardSmallImageFileDynamicDark=..\assets\icons\app.png
WizardSmallImageBackColor=#FAFAFA
WizardSmallImageBackColorDynamicDark=#202020
WizardSizePercent=110
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no
AppMutex=ReadAI-Desktop-Reader-8B6A0E5D
SetupMutex=Sorryread-Setup-BFD21086-6F93-45B8-8F94-6B330EA91E92
UsePreviousAppDir=yes
DirExistsWarning=no
AllowNetworkDrive=no
AllowUNCPath=no
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} 安装程序
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoCopyright=Copyright (C) 2026 Sorryread

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[CustomMessages]
chinesesimplified.DesktopIcon=创建桌面快捷方式
chinesesimplified.AdditionalTasks=附加选项：
chinesesimplified.InstallingWebView2=正在安装 Microsoft Edge WebView2 Runtime…
chinesesimplified.WebView2LaunchFailed=无法启动 Microsoft Edge WebView2 Runtime 安装程序。
chinesesimplified.WebView2InstallFailed=Microsoft Edge WebView2 Runtime 安装失败，退出代码：%1。请检查网络连接后重试。
chinesesimplified.WebView2NotDetected=Microsoft Edge WebView2 Runtime 安装完成后仍未检测到有效版本，请重新运行安装程序。
chinesesimplified.WebView2RestartRequired=Microsoft Edge WebView2 Runtime 需要重新启动 Windows。请重启后再次运行本安装程序。
chinesesimplified.DeleteUserDataPrompt=是否同时删除当前 Windows 用户的阅读记录、书库、设置、WebView2 数据和 TXT 导出？%n%n选择“否”将保留：%n%LOCALAPPDATA%\Sorryread%n%n为避免误删，默认选择“否”。
chinesesimplified.DeleteUserDataFailed=未能完全删除用户数据，请稍后手动检查：%n%1

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalTasks}"

[Files]
Source: "cache\{#WebView2Bootstrapper}"; Flags: dontcopy noencryption
Source: "..\publish\Sorryread\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"; IconFilename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "运行 {#AppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  WebView2ClientKey = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

var
  DeleteUserDataOnUninstall: Boolean;

function IsValidWebView2Version(const Version: String): Boolean;
begin
  Result := (Version <> '') and (Version <> '0.0.0.0');
end;

function IsWebView2RuntimeInstalled: Boolean;
var
  Version: String;
begin
  Result :=
    (RegQueryStringValue(HKLM32, WebView2ClientKey, 'pv', Version) and IsValidWebView2Version(Version)) or
    (RegQueryStringValue(HKLM64, WebView2ClientKey, 'pv', Version) and IsValidWebView2Version(Version)) or
    (RegQueryStringValue(HKCU, WebView2ClientKey, 'pv', Version) and IsValidWebView2Version(Version)) or
    (RegQueryStringValue(HKCU32, WebView2ClientKey, 'pv', Version) and IsValidWebView2Version(Version)) or
    (RegQueryStringValue(HKCU64, WebView2ClientKey, 'pv', Version) and IsValidWebView2Version(Version));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if IsWebView2RuntimeInstalled then
    Exit;

  WizardForm.StatusLabel.Caption := CustomMessage('InstallingWebView2');
  ExtractTemporaryFile('{#WebView2Bootstrapper}');
  if not Exec(
    ExpandConstant('{tmp}\{#WebView2Bootstrapper}'),
    '/silent /install',
    ExpandConstant('{tmp}'),
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode) then
  begin
    Result := CustomMessage('WebView2LaunchFailed');
    Exit;
  end;

  if ResultCode = 3010 then
  begin
    NeedsRestart := True;
    Result := CustomMessage('WebView2RestartRequired');
    Exit;
  end;
  if ResultCode <> 0 then
  begin
    Result := FmtMessage(CustomMessage('WebView2InstallFailed'), [IntToStr(ResultCode)]);
    Exit;
  end;
  if not IsWebView2RuntimeInstalled then
    Result := CustomMessage('WebView2NotDetected');
end;

function InitializeUninstall: Boolean;
begin
  DeleteUserDataOnUninstall := False;
  if not UninstallSilent then
  begin
    DeleteUserDataOnUninstall :=
      MsgBox(
        CustomMessage('DeleteUserDataPrompt'),
        mbConfirmation,
        MB_YESNO or MB_DEFBUTTON2) = IDYES;
  end;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  UserDataDirectory: String;
begin
  if (CurUninstallStep <> usPostUninstall) or (not DeleteUserDataOnUninstall) then
    Exit;

  UserDataDirectory := ExpandConstant('{localappdata}\Sorryread');
  if DirExists(UserDataDirectory) and
     (not DelTree(UserDataDirectory, True, True, True)) then
  begin
    MsgBox(
      FmtMessage(CustomMessage('DeleteUserDataFailed'), [UserDataDirectory]),
      mbError,
      MB_OK);
  end;
end;
