unit untLocalProjectSettings;

{
  Redirects two volatile per-developer settings to a dedicated sidecar file so
  they are never committed to version control, eliminating daily merge conflicts.

  Settings intercepted
  --------------------
  1. Debugger_RunParams  (Project > Options > Debugger > Parameters)
  2. Active build platform  (Win32 / Win64 / …)

  How it works (pure ToolsAPI, no DDetours)
  -----------------------------------------
  [A] IOTAProjectFileStorageNotifier (global singleton)
        • ProjectLoaded : restores settings from the sidecar when the
          project is opened.

  [B] IOTAProjectNotifier (one instance per open project)
        • BeforeSave : captures local settings and writes sidecar, then clears
          volatile values in memory before IDE persistence.
        • AfterSave : sanitizes the just-written .dproj file and restores
          local settings in memory.

  [C] IOTAIDENotifier (global singleton)
        • FileNotification / ofnFileOpened on *.dproj files → installs [B].

  Lifecycle
  ---------
  • Register installs [A] and [C] and hooks any projects already open.
  • finalization unregisters [A] and [C] and removes all [B] hooks.
}

interface

procedure Register;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Variants,
  System.Generics.Collections,
  Xml.XMLDoc,
  Xml.xmldom,
  Xml.Win.msxmldom,
  Xml.XMLIntf,
  ToolsAPI,
  CommonOptionStrs,
  untDprojSanitizer,
  untLocalDevSettingsStore;

const
  CLocalSectionName  = 'LocalDevSettings';

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------

procedure InstallProjectHook(const AProject: IOTAProject); forward;
procedure CaptureProjectSettings(const AProject: IOTAProject;
  out ACurrentPlatform: string; out ARunParamsMatrix: TRunParamsMatrix); forward;
procedure RestoreProjectSettingsFromValues(const AProject: IOTAProject;
  const ACurrentPlatform: string; const ARunParamsMatrix: TRunParamsMatrix); forward;
procedure RestoreProjectSettingsFromSidecarOnce(const AProject: IOTAProject); forward;
procedure RestoreProjectSettingsFromSidecar(const AProject: IOTAProject); forward;
procedure ApplySanitizedSettingsBeforeSave(const AProject: IOTAProject); forward;
procedure QueueRestoreProjectSettingsFromSidecar(const AProjectFileName: string); forward;

var
  GRestoredProjectFiles: TStringList;

procedure AddMatrixEntry(var ARunParamsMatrix: TRunParamsMatrix;
  const AConfigurationKey, AConfigurationName, APlatformName, ARunParams: string);
begin
  var NewIndex := Length(ARunParamsMatrix);
  SetLength(ARunParamsMatrix, NewIndex + 1);
  ARunParamsMatrix[NewIndex].ConfigurationKey := AConfigurationKey;
  ARunParamsMatrix[NewIndex].ConfigurationName := AConfigurationName;
  ARunParamsMatrix[NewIndex].PlatformName := APlatformName;
  ARunParamsMatrix[NewIndex].RunParams := ARunParams;
end;

function ReadRunParamsValue(const ABuildConfiguration: IOTABuildConfiguration): string;
begin
  Result := '';
  if not Assigned(ABuildConfiguration) then
    Exit;
  try
    Result := ABuildConfiguration.Value[sDebugger_RunParams];
  except
    Result := '';
  end;
end;

function FindBuildConfiguration(const AOptionsConfigurations: IOTAProjectOptionsConfigurations;
  const AConfigurationKey, AConfigurationName: string): IOTABuildConfiguration;
begin
  Result := nil;
  if not Assigned(AOptionsConfigurations) then
    Exit;

  if AConfigurationKey <> '' then
    for var i := 0 to AOptionsConfigurations.ConfigurationCount - 1 do
    begin
      var CandidateConfiguration := AOptionsConfigurations.Configurations[i];
      if not Assigned(CandidateConfiguration) then
        Continue;
      if SameText(CandidateConfiguration.Key, AConfigurationKey) then
        Exit(CandidateConfiguration);
    end;

  if AConfigurationName <> '' then
    for var i := 0 to AOptionsConfigurations.ConfigurationCount - 1 do
    begin
      var CandidateConfiguration := AOptionsConfigurations.Configurations[i];
      if not Assigned(CandidateConfiguration) then
        Continue;
      if SameText(CandidateConfiguration.Name, AConfigurationName) then
        Exit(CandidateConfiguration);
    end;
end;

procedure CaptureProjectSettings(const AProject: IOTAProject;
  out ACurrentPlatform: string; out ARunParamsMatrix: TRunParamsMatrix);
begin
  if not Assigned(AProject) then
    Exit;

  ACurrentPlatform := '';
  ARunParamsMatrix := nil;

  var OptionsConfigurations: IOTAProjectOptionsConfigurations;
  if Supports(AProject.ProjectOptions, IOTAProjectOptionsConfigurations, OptionsConfigurations) then
    for var i := 0 to OptionsConfigurations.ConfigurationCount - 1 do
    begin
      var Configuration := OptionsConfigurations.Configurations[i];
      if not Assigned(Configuration) then
        Continue;

      var ConfigurationRunParams := ReadRunParamsValue(Configuration);
      if ConfigurationRunParams <> '' then
        AddMatrixEntry(ARunParamsMatrix, Configuration.Key, Configuration.Name,
          '', ConfigurationRunParams);

      for var PlatformName in Configuration.Platforms do
      begin
        var PlatformConfiguration := Configuration.PlatformConfiguration[PlatformName];
        if not Assigned(PlatformConfiguration) then
          Continue;
        var PlatformRunParams := ReadRunParamsValue(PlatformConfiguration);
        if PlatformRunParams = '' then
          Continue;
        AddMatrixEntry(ARunParamsMatrix, Configuration.Key, Configuration.Name,
          PlatformName, PlatformRunParams);
      end;
    end;

  if Length(ARunParamsMatrix) = 0 then
  begin
    var RunParams := '';
    try
      RunParams := VarToStrDef(AProject.ProjectOptions.GetOptionValue(sDebugger_RunParams), '');
    except
      RunParams := '';
    end;
    if RunParams <> '' then
      AddMatrixEntry(ARunParamsMatrix, '', '', '', RunParams);
  end;

  if Supports(AProject, IOTAProject160) then
  begin
    var Project160 := AProject as IOTAProject160;
    try
      ACurrentPlatform := Project160.CurrentPlatform;
    except
      ACurrentPlatform := '';
    end;
  end;
end;

procedure RestoreProjectSettingsFromValues(const AProject: IOTAProject;
  const ACurrentPlatform: string; const ARunParamsMatrix: TRunParamsMatrix);
begin
  if not Assigned(AProject) then
    Exit;

  if ACurrentPlatform <> '' then
    if Supports(AProject, IOTAProject160) then
    begin
      var Project160 := AProject as IOTAProject160;
      try
        Project160.SetPlatform(ACurrentPlatform);
      except
      end;
    end;

  var OptionsConfigurations: IOTAProjectOptionsConfigurations;
  if Supports(AProject.ProjectOptions, IOTAProjectOptionsConfigurations, OptionsConfigurations) then
    for var Entry in ARunParamsMatrix do
    begin
      var Configuration := FindBuildConfiguration(OptionsConfigurations,
        Entry.ConfigurationKey, Entry.ConfigurationName);
      if not Assigned(Configuration) then
        Continue;

      if Entry.PlatformName = '' then
      begin
        try
          Configuration.Value[sDebugger_RunParams] := Entry.RunParams;
        except
        end;
        Continue;
      end;

      try
        var PlatformConfiguration := Configuration.PlatformConfiguration[Entry.PlatformName];
        if Assigned(PlatformConfiguration) then
          PlatformConfiguration.Value[sDebugger_RunParams] := Entry.RunParams;
      except
      end;
    end
  else if Length(ARunParamsMatrix) > 0 then
    try
      AProject.ProjectOptions.SetOptionValue(sDebugger_RunParams, ARunParamsMatrix[0].RunParams);
    except
    end;

end;

procedure RestoreProjectSettingsFromSidecar(const AProject: IOTAProject);
begin
  if not Assigned(AProject) then
    Exit;

  var Platform := '';
  var RunParamsMatrix: TRunParamsMatrix := nil;
  LoadTeamworkLocalSettings((AProject as IOTAModule).FileName, Platform, RunParamsMatrix);
  RestoreProjectSettingsFromValues(AProject, Platform, RunParamsMatrix);

end;

procedure RestoreProjectSettingsFromSidecarOnce(const AProject: IOTAProject);
begin
  if not Assigned(AProject) then
    Exit;

  var ProjectFileName := (AProject as IOTAModule).FileName;
  if ProjectFileName = '' then
    Exit;

  if GRestoredProjectFiles.IndexOf(ProjectFileName) >= 0 then
    Exit;

  try
    RestoreProjectSettingsFromSidecar(AProject);
    GRestoredProjectFiles.Add(ProjectFileName);
  except
  end;
end;

procedure ClearRunParamsValue(const ABuildConfiguration: IOTABuildConfiguration);
begin
  if not Assigned(ABuildConfiguration) then
    Exit;
  try
    ABuildConfiguration.Value[sDebugger_RunParams] := '';
  except
  end;
end;

procedure ApplySanitizedSettingsBeforeSave(const AProject: IOTAProject);
begin
  if not Assigned(AProject) then
    Exit;

  var OptionsConfigurations: IOTAProjectOptionsConfigurations;
  if Supports(AProject.ProjectOptions, IOTAProjectOptionsConfigurations, OptionsConfigurations) then
    for var i := 0 to OptionsConfigurations.ConfigurationCount - 1 do
    begin
      var Configuration := OptionsConfigurations.Configurations[i];
      if not Assigned(Configuration) then
        Continue;

      ClearRunParamsValue(Configuration);
      for var PlatformName in Configuration.Platforms do
      begin
        var PlatformConfiguration := Configuration.PlatformConfiguration[PlatformName];
        ClearRunParamsValue(PlatformConfiguration);
      end;
    end;

  try
    AProject.ProjectOptions.SetOptionValue(sDebugger_RunParams, '');
  except
  end;
end;

procedure QueueRestoreProjectSettingsFromSidecar(const AProjectFileName: string);
begin
  if AProjectFileName = '' then
    Exit;

  TThread.Queue(nil,
    procedure
    begin
      var ModuleServices: IOTAModuleServices;
      if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
        Exit;

      var Module := ModuleServices.FindModule(AProjectFileName);
      var Project: IOTAProject;
      if not Supports(Module, IOTAProject, Project) then
        Exit;

      RestoreProjectSettingsFromSidecarOnce(Project);
    end);
end;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

type
  TProjectHookEntry = record
    Project:     IOTAProject;
    NotifierIdx: Integer;
  end;

var
  GFileStorageNotifierIdx: Integer = -1;
  GIDENotifierIdx:         Integer = -1;
  GInstalledHooks:         TList<TProjectHookEntry>;

// ===========================================================================
// [B] TProjectSaveHook — one instance per open project
//     Installed on IOTAModule (the project) via AddNotifier.
//     AfterSave triggers the .dproj sanitization.
// ===========================================================================

type
  TProjectSaveHook = class(TInterfacedObject,
    IOTANotifier, IOTAModuleNotifier, IOTAProjectNotifier)
  private
    FProject: IOTAProject;
    FNotifierIdx: Integer;
    FCapturedPlatform: string;
    FCapturedRunParamsMatrix: TRunParamsMatrix;
  public
    constructor Create(const AProject: IOTAProject);
    // IOTANotifier
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
    // IOTAModuleNotifier
    function CheckOverwrite: Boolean;
    procedure ModuleRenamed(const NewName: string); overload;
    // IOTAProjectNotifier
    procedure ModuleAdded(const AFileName: string);
    procedure ModuleRemoved(const AFileName: string);
    procedure ModuleRenamed(const AOldFileName, ANewFileName: string); overload;
  end;

constructor TProjectSaveHook.Create(const AProject: IOTAProject);
var
  Entry: TProjectHookEntry;
begin
  inherited Create;
  FProject     := AProject;
  FNotifierIdx := (AProject as IOTAModule).AddNotifier(Self);
  Entry.Project     := AProject;
  Entry.NotifierIdx := FNotifierIdx;
  GInstalledHooks.Add(Entry);
end;

procedure TProjectSaveHook.AfterSave;
begin
  if Assigned(FProject) then
  begin
    var ProjectFileName := (FProject as IOTAModule).FileName;
    SanitizeProjectFile(ProjectFileName);
    RestoreProjectSettingsFromValues(FProject, FCapturedPlatform, FCapturedRunParamsMatrix);
  end;
end;

procedure TProjectSaveHook.Destroyed;
var
  I: Integer;
begin
  // The project is being destroyed — remove our entry from the global list
  // so finalization does not attempt a dangling RemoveNotifier call.
  for I := GInstalledHooks.Count - 1 downto 0 do
    if GInstalledHooks[I].Project = FProject then
    begin
      GInstalledHooks.Delete(I);
      Break;
    end;
  FProject := nil;
end;

procedure TProjectSaveHook.BeforeSave;
begin
  if not Assigned(FProject) then
    Exit;

  CaptureProjectSettings(FProject, FCapturedPlatform, FCapturedRunParamsMatrix);

  SaveTeamworkLocalSettings((FProject as IOTAModule).FileName,
    FCapturedPlatform, FCapturedRunParamsMatrix);

  ApplySanitizedSettingsBeforeSave(FProject);
end;
procedure TProjectSaveHook.Modified;   begin end;

function TProjectSaveHook.CheckOverwrite: Boolean;
begin
  Result := True;
end;

procedure TProjectSaveHook.ModuleRenamed(const NewName: string);             begin end;
procedure TProjectSaveHook.ModuleAdded(const AFileName: string);             begin end;
procedure TProjectSaveHook.ModuleRemoved(const AFileName: string);           begin end;
procedure TProjectSaveHook.ModuleRenamed(const AOldFileName,
  ANewFileName: string);                                                      begin end;

// ===========================================================================
// [A] TLocalSettingsStorageNotifier — global singleton
//     Registered with IOTAProjectFileStorage.
//     Persists RunParams and Platform in/from .dproj.local.
// ===========================================================================

type
  TLocalSettingsStorageNotifier = class(TInterfacedObject,
    IOTAProjectFileStorageNotifier)
  public
    // IOTAProjectFileStorageNotifier
    function GetName: string;
    property Name: string read GetName;
    procedure CreatingProject(const ProjectOrGroup: IOTAModule);
    procedure ProjectLoaded(const ProjectOrGroup: IOTAModule;
      const Node: IXMLNode);
    procedure ProjectSaving(const ProjectOrGroup: IOTAModule;
      const Node: IXMLNode);
    procedure ProjectClosing(const ProjectOrGroup: IOTAModule);
  end;

function TLocalSettingsStorageNotifier.GetName: string;
begin
  Result := CLocalSectionName;
end;

procedure TLocalSettingsStorageNotifier.CreatingProject(
  const ProjectOrGroup: IOTAModule);
begin
  // No-op: settings are persisted in a dedicated sidecar file.
end;

procedure TLocalSettingsStorageNotifier.ProjectSaving(
  const ProjectOrGroup: IOTAModule; const Node: IXMLNode);
begin
  // Persistence is handled by the project save hook to avoid duplicate work.
end;

procedure TLocalSettingsStorageNotifier.ProjectLoaded(
  const ProjectOrGroup: IOTAModule; const Node: IXMLNode);
begin
  var Project: IOTAProject;
  if not Supports(ProjectOrGroup, IOTAProject, Project) then
    Exit;

  RestoreProjectSettingsFromSidecarOnce(Project);
end;

procedure TLocalSettingsStorageNotifier.ProjectClosing(
  const ProjectOrGroup: IOTAModule);
begin
  var Project: IOTAProject;
  if not Supports(ProjectOrGroup, IOTAProject, Project) then
    Exit;

  var ProjectFileName := (Project as IOTAModule).FileName;
  if ProjectFileName = '' then
    Exit;

  var Index := GRestoredProjectFiles.IndexOf(ProjectFileName);
  if Index >= 0 then
    GRestoredProjectFiles.Delete(Index);
end;

// ===========================================================================
// [C] TIDENotifier — global singleton
//     Watches for newly opened .dproj files and installs a TProjectSaveHook.
// ===========================================================================

type
  TIDENotifier = class(TInterfacedObject,
    IOTANotifier, IOTAIDENotifier)
  public
    // IOTANotifier
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
    // IOTAIDENotifier
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject;
      var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

procedure TIDENotifier.FileNotification(NotifyCode: TOTAFileNotification;
  const FileName: string; var Cancel: Boolean);
var
  MS:     IOTAModuleServices;
  Module: IOTAModule;
  Project: IOTAProject;
begin
  if NotifyCode <> ofnFileOpened then Exit;
  if not FileName.EndsWith('.dproj', True) then Exit;

  if not Supports(BorlandIDEServices, IOTAModuleServices, MS) then Exit;
  Module := MS.FindModule(FileName);
  if not Supports(Module, IOTAProject, Project) then Exit;

  InstallProjectHook(Project);
end;

procedure TIDENotifier.AfterSave;  begin end;
procedure TIDENotifier.BeforeSave; begin end;
procedure TIDENotifier.Destroyed;  begin end;
procedure TIDENotifier.Modified;   begin end;
procedure TIDENotifier.BeforeCompile(const Project: IOTAProject;
  var Cancel: Boolean);             begin end;
procedure TIDENotifier.AfterCompile(Succeeded: Boolean); begin end;

// ===========================================================================
// InstallProjectHook
// ===========================================================================

procedure InstallProjectHook(const AProject: IOTAProject);
var
  ProjectFileName: string;
  Entry: TProjectHookEntry;
begin
  ProjectFileName := (AProject as IOTAModule).FileName;
  for Entry in GInstalledHooks do
    if SameFileName(Entry.Project.FileName, ProjectFileName) then Exit; // already installed

  TProjectSaveHook.Create(AProject); // registers itself in GInstalledHooks
  QueueRestoreProjectSettingsFromSidecar(ProjectFileName);
end;

// ===========================================================================
// Register / finalization
// ===========================================================================

procedure Register;
var
  Services:    IOTAServices;
  FS:          IOTAProjectFileStorage;
  MS:          IOTAModuleServices;
  I:           Integer;
  Module:      IOTAModule;
  Project:     IOTAProject;
begin
  // [A] Register the file-storage notifier (reads/writes .dproj.local)
  if Supports(BorlandIDEServices, IOTAProjectFileStorage, FS) then
    GFileStorageNotifierIdx := FS.AddNotifier(TLocalSettingsStorageNotifier.Create);

  // [C] Register the IDE notifier (watches for newly opened projects)
  if Supports(BorlandIDEServices, IOTAServices, Services) then
    GIDENotifierIdx := Services.AddNotifier(TIDENotifier.Create);

  // Install per-project hooks on every project that is already open
  if Supports(BorlandIDEServices, IOTAModuleServices, MS) then
    for I := 0 to MS.ModuleCount - 1 do
    begin
      Module := MS.Modules[I];
      if Supports(Module, IOTAProject, Project) then
        InstallProjectHook(Project);
    end;
end;

initialization
  GInstalledHooks := TList<TProjectHookEntry>.Create;
  GRestoredProjectFiles := TStringList.Create;
  GRestoredProjectFiles.CaseSensitive := False;
  GRestoredProjectFiles.Sorted := True;
  GRestoredProjectFiles.Duplicates := dupIgnore;

finalization
  // Remove per-project hooks for projects still open
  var FS: IOTAProjectFileStorage;
  var MS: IOTAModuleServices;
  var Services: IOTAServices;

  while GInstalledHooks.Count > 0 do
  begin
    var Entry := GInstalledHooks[GInstalledHooks.Count - 1];
    GInstalledHooks.Delete(GInstalledHooks.Count - 1);
    try
      (Entry.Project as IOTAModule).RemoveNotifier(Entry.NotifierIdx);
    except
    end;
  end;
  GInstalledHooks.Free;
  GInstalledHooks := nil;

  GRestoredProjectFiles.Free;
  GRestoredProjectFiles := nil;

  // Unregister the file-storage notifier
  if (GFileStorageNotifierIdx >= 0) and
     Supports(BorlandIDEServices, IOTAProjectFileStorage, FS) then
  begin
    FS.RemoveNotifier(GFileStorageNotifierIdx);
    GFileStorageNotifierIdx := -1;
  end;

  // Unregister the IDE notifier
  if (GIDENotifierIdx >= 0) and
     Supports(BorlandIDEServices, IOTAServices, Services) then
  begin
    Services.RemoveNotifier(GIDENotifierIdx);
    GIDENotifierIdx := -1;
  end;

end.
