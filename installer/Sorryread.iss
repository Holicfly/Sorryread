#ifndef AppVersion
  #define AppVersion "1.1.11"
#endif

#define AppName "素若阅读"
#define AppPublisher "Sorryread"
#define AppExeName "素若阅读.exe"
#define AppDirectoryName "Sorryread"
#define WebView2Bootstrapper "MicrosoftEdgeWebView2Setup.exe"
#ifndef PublishDir
  #define PublishDir "..\publish\Sorryread"
#endif

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
chinesesimplified.DeleteUserDataPrompt=是否同时删除此安装目录的阅读记录、书库、设置、WebView2 数据和 TXT 导出？%n%n数据目录：%n%1%n%n默认选择“否”保留数据。旧 LOCALAPPDATA 目录或迁移失败留下的源数据不会被卸载程序删除。
chinesesimplified.DeleteUserDataFailed=未能完全删除用户数据，请稍后手动检查：%n%1

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:AdditionalTasks}"

[Dirs]
Name: "{app}\Data"; Permissions: users-modify; Flags: uninsneveruninstall

[Files]
Source: "Migrate-UserData.ps1"; Flags: dontcopy noencryption
Source: "cache\{#WebView2Bootstrapper}"; Flags: dontcopy noencryption
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "Data,Data\*,.Data-migration-*,Data.migration-*.txt"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"; IconFilename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\app.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "运行 {#AppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
const
  WebView2ClientKey = 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  ReaderMutexName = 'ReadAI-Desktop-Reader-8B6A0E5D';
  ErrorAlreadyExists = 183;
  ReparsePointAttribute = $400;

var
  DeleteUserDataOnUninstall: Boolean;
  MigrationMutex: THandle;
  MigrationStarted, MigrationCompleted: Boolean;
  MigrationSourceDirectory, MigrationInstallDirectory: String;

function CreateMigrationMutex(Attributes: THandle; InitialOwner: Integer; Name: String): THandle;
  external 'CreateMutexW@kernel32.dll stdcall setuponly';
function CloseMigrationHandle(Handle: THandle): Integer;
  external 'CloseHandle@kernel32.dll stdcall setuponly';
function MigrationLastError: Cardinal;
  external 'GetLastError@kernel32.dll stdcall setuponly';
procedure ClearMigrationLastError(ErrorCode: Cardinal);
  external 'SetLastError@kernel32.dll stdcall setuponly';
function DataFileAttributes(Name: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall';

procedure ReleaseMigrationGuard;
begin
  if MigrationMutex <> 0 then begin
    CloseMigrationHandle(MigrationMutex);
    MigrationMutex := 0;
  end;
end;

function AcquireMigrationGuard: Boolean;
var
  ErrorCode: Cardinal;
begin
  Result := MigrationMutex <> 0;
  if Result then Exit;
  ClearMigrationLastError(0);
  { Setup 已完成启动时的 AppMutex 检查；此句柄阻止复制期间重新启动阅读程序。 }
  MigrationMutex := CreateMigrationMutex(0, 0, ReaderMutexName);
  ErrorCode := MigrationLastError;
  Result := (MigrationMutex <> 0) and (ErrorCode <> ErrorAlreadyExists);
  if not Result then ReleaseMigrationGuard;
end;

function RunDataMigration(Mode: String; var ResultCode: Integer; var Detail: String): Boolean;
var
  Parameters, ResultPath: String;
  Lines: TArrayOfString;
  Index: Integer;
begin
  Detail := '';
  ResultCode := -1;
  ResultPath := ExpandConstant('{tmp}\data-migration-result.txt');
  DeleteFile(ResultPath);
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
    AddQuotes(ExpandConstant('{tmp}\Migrate-UserData.ps1')) + ' -Mode ' + Mode +
    ' -SourceDirectory ' + AddQuotes(MigrationSourceDirectory) +
    ' -InstallDirectory ' + AddQuotes(AddBackslash(MigrationInstallDirectory) + '.') +
    ' -StateFile ' + AddQuotes(ExpandConstant('{tmp}\data-migration-state.json')) +
    ' -ResultFile ' + AddQuotes(ResultPath);
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if LoadStringsFromFile(ResultPath, Lines) then
    for Index := 0 to GetArrayLength(Lines) - 1 do
      Detail := Detail + Lines[Index] + #13#10;
  if Detail = '' then Detail := '迁移助手未返回详细信息，退出代码：' + IntToStr(ResultCode);
  Log(Mode + ': ' + Detail);
end;

function RollbackDataMigration: String;
var
  Code: Integer;
  Detail: String;
begin
  Result := '';
  if not MigrationStarted or MigrationCompleted then Exit;
  if not RunDataMigration('Rollback', Code, Detail) or (Code <> 0) then
    Result := '数据回退未完成，已保留源目录和可能存在的副本，请勿手动删除。' + #13#10 + Detail
  else
    MigrationStarted := False;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine + MemoTasksInfo + NewLine + NewLine +
    '用户数据：' + ExpandConstant('{app}\Data') + NewLine +
    '检测的旧目录（安装器运行账户）：' + ExpandConstant('{localappdata}\Sorryread') + NewLine +
    '目标 Data 已有内容时跳过迁移，不覆盖。安装成功前保留完整旧目录。';
end;

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

function EnsureWebViewRuntime(var NeedsRestart: Boolean): String;
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

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  Detail, RollbackDetail: String;
begin
  Result := EnsureWebViewRuntime(NeedsRestart);
  if Result <> '' then Exit;
  if not AcquireMigrationGuard then begin
    Result := '请从托盘退出素若阅读，并关闭残留的阅读窗口后重试；尚未移动数据。';
    Exit;
  end;
  Result := RollbackDataMigration;
  if Result <> '' then begin
    ReleaseMigrationGuard;
    Exit;
  end;
  MigrationSourceDirectory := ExpandConstant('{localappdata}\Sorryread');
  MigrationInstallDirectory := ExpandConstant('{app}');
  ExtractTemporaryFile('Migrate-UserData.ps1');
  MigrationStarted := True;
  WizardForm.StatusLabel.Caption := '正在准备 Data 权限并复制、核对旧数据，请稍候…';
  if not RunDataMigration('Prepare', Code, Detail) or (Code <> 0) then begin
    RollbackDetail := RollbackDataMigration;
    Result := '数据迁移准备失败，安装尚未开始。请关闭应用或占用文件的进程后重试。' + #13#10 +
      Detail + #13#10 + RollbackDetail;
    ReleaseMigrationGuard;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
  Detail: String;
begin
  if CurStep <> ssPostInstall then Exit;
  if not RunDataMigration('Commit', Code, Detail) or ((Code <> 0) and (Code <> 2)) then
    RaiseException('数据迁移未完成，已保留旧目录。' + #13#10 + Detail);
  MigrationCompleted := True;
  if Code = 2 then
    MsgBox('Data 副本完整，但旧目录或迁移标记因文件占用等原因未能完全移除。' + #13#10 +
      '已按保留源数据方式完成安装，请勿直接删除未经确认的数据。' + #13#10 + Detail,
      mbInformation, MB_OK);
  ReleaseMigrationGuard;
end;

procedure DeinitializeSetup;
var
  Detail: String;
begin
  Detail := RollbackDataMigration;
  ReleaseMigrationGuard;
  if Detail <> '' then MsgBox(Detail, mbError, MB_OK);
end;

function HasUnsafeDataLink(Path: String; Depth: Integer): Boolean;
var
  Entry: TFindRec;
begin
  Result := True;
  if (Depth > 256) or ((DataFileAttributes(Path) and ReparsePointAttribute) <> 0) then Exit;
  Result := False;
  if FindFirst(AddBackslash(Path) + '*', Entry) then begin
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then begin
          if ((Entry.Attributes and ReparsePointAttribute) <> 0) or
            (((Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
              HasUnsafeDataLink(AddBackslash(Path) + Entry.Name, Depth + 1)) then begin
            Result := True;
            Exit;
          end;
        end;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
end;

function InitializeUninstall: Boolean;
begin
  DeleteUserDataOnUninstall := False;
  if not UninstallSilent then
  begin
    DeleteUserDataOnUninstall :=
      MsgBox(
        FmtMessage(CustomMessage('DeleteUserDataPrompt'), [ExpandConstant('{app}\Data')]),
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

  UserDataDirectory := ExpandConstant('{app}\Data');
  if DirExists(UserDataDirectory) and
    (((DataFileAttributes(ExpandConstant('{app}')) and ReparsePointAttribute) <> 0) or
      HasUnsafeDataLink(UserDataDirectory, 0)) then begin
    MsgBox('Data 含目录链接或不可安全遍历的路径，已保留数据，请手动检查：' + #13#10 +
      UserDataDirectory, mbError, MB_OK);
    Exit;
  end;
  if DirExists(UserDataDirectory) and
     (not DelTree(UserDataDirectory, True, True, True)) then
  begin
    MsgBox(
      FmtMessage(CustomMessage('DeleteUserDataFailed'), [UserDataDirectory]),
      mbError,
      MB_OK);
  end;
end;
