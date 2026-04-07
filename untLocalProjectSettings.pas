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
  System.StrUtils,
  System.Variants,
  System.Generics.Collections,
  Winapi.Windows,
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
  CFileIoRetryCount = 5;
  CFileIoRetryDelayMs = 40;
  CFileIoRetryJitterMs = 40;
  CCvsMutexPrefix = 'Local\TeamoworkFriendlyDproj_CVS_';
  CCvsReconcilePollDelayMs = 1000;
  CCvsReconcilePollJitterMs = 500;
  CCvsReconcileMaxAttempts = 600;

// ---------------------------------------------------------------------------
// Forward declarations
// ---------------------------------------------------------------------------

procedure InstallProjectHook(const AProject: IOTAProject); forward;
procedure CaptureProjectSettings(const AProject: IOTAProject;
  out ACurrentPlatform: string; out ARunParamsMatrix: TRunParamsMatrix); forward;
procedure RestoreProjectSettingsFromValues(const AProject: IOTAProject;
  const ACurrentPlatform: string; const ARunParamsMatrix: TRunParamsMatrix); forward;
function RestoreProjectSettingsFromSidecar(const AProject: IOTAProject): Boolean; forward;
procedure RestoreProjectSettingsFromSidecarOnce(const AProject: IOTAProject); forward;
procedure ApplySanitizedSettingsBeforeSave(const AProject: IOTAProject); forward;
procedure QueueRestoreProjectSettingsFromSidecar(const AProjectFileName: string); forward;

var
  GRestoredProjectFiles: TStringList;
  GRetryRandomSeedInitialized: Boolean = False;

procedure DebugLog(const AMessage: string);
begin
  // Temporary diagnostics disabled after root-cause investigation.
end;

function BoolFlag(const AValue: Boolean): string;
begin
  if AValue then
    Result := '1'
  else
    Result := '0';
end;

procedure SleepWithRetryJitter;
begin
  if not GRetryRandomSeedInitialized then
  begin
    Randomize;
    GRetryRandomSeedInitialized := True;
  end;

  var DelayMs := CFileIoRetryDelayMs;
  if CFileIoRetryJitterMs > 0 then
    DelayMs := DelayMs + Random(CFileIoRetryJitterMs + 1);

  TThread.Sleep(DelayMs);
end;

procedure SleepWithCvsReconcileJitter;
begin
  if not GRetryRandomSeedInitialized then
  begin
    Randomize;
    GRetryRandomSeedInitialized := True;
  end;

  var DelayMs := CCvsReconcilePollDelayMs;
  DelayMs := DelayMs + Random(CCvsReconcilePollJitterMs + 1);

  TThread.Sleep(DelayMs);
end;

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

procedure ClearProjectOptionsModifiedState(const AProject: IOTAProject);
begin
  if not Assigned(AProject) then
    Exit;

  var ProjectOptions70: IOTAProjectOptions70;
  if not Supports(AProject.ProjectOptions, IOTAProjectOptions70, ProjectOptions70) then
    Exit;

  try
    ProjectOptions70.SetModifiedState(False);
  except
  end;
end;

procedure SaveProjectModuleSilently(const AProject: IOTAProject);
begin
  if not Assigned(AProject) then
    Exit;

  try
    (AProject as IOTAModule).Save(False, True);
  except
  end;

  ClearProjectOptionsModifiedState(AProject);
end;

function ReadFileRawBytes(const AFileName: string): TBytes;
begin
  Result := nil;
  if not TFile.Exists(AFileName) then
    Exit;

  for var Attempt := 1 to CFileIoRetryCount do
  begin
    try
      Result := TFile.ReadAllBytes(AFileName);
      Exit;
    except
      if Attempt = CFileIoRetryCount then
        Exit;
      SleepWithRetryJitter;
    end;
  end;
end;

function TryGetLastWriteTimeWithRetry(const AFileName: string;
  out ALastWriteTime: TDateTime): Boolean;
begin
  Result := False;
  ALastWriteTime := 0;

  for var Attempt := 1 to CFileIoRetryCount do
  begin
    try
      ALastWriteTime := TFile.GetLastWriteTime(AFileName);
      Exit(True);
    except
      if Attempt = CFileIoRetryCount then
        Exit(False);
      SleepWithRetryJitter;
    end;
  end;
end;

function TryGetLastWriteTimeUtcWithRetry(const AFileName: string;
  out ALastWriteTimeUtc: TDateTime): Boolean;
begin
  Result := False;
  ALastWriteTimeUtc := 0;

  for var Attempt := 1 to CFileIoRetryCount do
  begin
    try
      ALastWriteTimeUtc := TFile.GetLastWriteTimeUtc(AFileName);
      Exit(True);
    except
      if Attempt = CFileIoRetryCount then
        Exit(False);
      SleepWithRetryJitter;
    end;
  end;
end;

function TryReadAllLinesWithRetry(const AFileName: string;
  out ALines: TArray<string>): Boolean;
begin
  Result := False;
  ALines := nil;

  for var Attempt := 1 to CFileIoRetryCount do
  begin
    try
      ALines := TFile.ReadAllLines(AFileName);
      Exit(True);
    except
      if Attempt = CFileIoRetryCount then
        Exit(False);
      SleepWithRetryJitter;
    end;
  end;
end;

function TryWriteAllLinesWithRetry(const AFileName: string;
  const ALines: TArray<string>; const AEncoding: TEncoding): Boolean;
begin
  Result := False;

  for var Attempt := 1 to CFileIoRetryCount do
  begin
    try
      TFile.WriteAllLines(AFileName, ALines, AEncoding);
      Exit(True);
    except
      if Attempt = CFileIoRetryCount then
        Exit(False);
      SleepWithRetryJitter;
    end;
  end;
end;

function BuildCvsMutexName(const AEntriesFileName: string): string;
begin
  var Sanitized := AEntriesFileName.ToLowerInvariant;
  Sanitized := StringReplace(Sanitized, '\', '_', [rfReplaceAll]);
  Sanitized := StringReplace(Sanitized, '/', '_', [rfReplaceAll]);
  Sanitized := StringReplace(Sanitized, ':', '_', [rfReplaceAll]);
  Result := CCvsMutexPrefix + Sanitized;
end;

function TryAcquireCvsMutexWithRetry(const AEntriesFileName: string;
  out AMutexHandle: THandle): Boolean;
begin
  Result := False;
  AMutexHandle := 0;

  var MutexName := BuildCvsMutexName(AEntriesFileName);
  var MutexHandle := CreateMutex(nil, False, PChar(MutexName));
  if MutexHandle = 0 then
  begin
    DebugLog('TryAcquireCvsMutexWithRetry CREATE_FAIL name=' + MutexName +
      ' err=' + IntToStr(GetLastError));
    Exit;
  end;

  for var Attempt := 1 to CFileIoRetryCount do
  begin
    var WaitResult := WaitForSingleObject(MutexHandle, 0);
    if (WaitResult = WAIT_OBJECT_0) or (WaitResult = WAIT_ABANDONED) then
    begin
      AMutexHandle := MutexHandle;
      Exit(True);
    end;

    if Attempt = CFileIoRetryCount then
      Break;

    SleepWithRetryJitter;
  end;

  CloseHandle(MutexHandle);
end;

procedure ReleaseCvsMutex(var AMutexHandle: THandle);
begin
  if AMutexHandle = 0 then
    Exit;

  ReleaseMutex(AMutexHandle);
  CloseHandle(AMutexHandle);
  AMutexHandle := 0;
end;

function IsCvsEntriesLogPresent(const AEntriesFileName: string): Boolean;
begin
  var CvsDirectory := TPath.GetDirectoryName(AEntriesFileName);
  if CvsDirectory = '' then
    Exit(False);

  var EntriesLogFile := TPath.Combine(CvsDirectory, 'Entries.Log');
  Result := TFile.Exists(EntriesLogFile);
end;

function AreByteArraysEqual(const ALeft, ARight: TBytes): Boolean;
begin
  if Length(ALeft) <> Length(ARight) then
    Exit(False);
  if Length(ALeft) = 0 then
    Exit(True);

  Result := CompareMem(@ALeft[0], @ARight[0], Length(ALeft));
end;

{
  CVS legacy support (Concurrent Versions System)

  Why this exists:
    In some legacy environments, Delphi saves a .dproj and our sanitizer later
    restores equivalent content. The final file bytes can match the original,
    but CVS may still mark the file as modified because it compares timestamps
    using administrative metadata stored in CVS/Entries.

  What we do:
    - Before save: read CVS/Entries and capture pre-save file bytes only if CVS
      currently reports the file as clean.
    - After save + sanitize: if bytes are unchanged, update only the timestamp
      field in CVS/Entries for that file.

  What we intentionally do NOT do:
    - No "cvs update" command execution.
    - No download/merge from repository.
    - No .dproj content mutation for this reset path.

  Safety rule:
    If file bytes changed, we keep CVS dirty state untouched.
}

function BuildCvsTimestamp(const ADateTime: TDateTime): string;
const
  CDayNames: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  CMonthNames: array[1..12] of string =
    ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
begin
  var Year: Word := 0;
  var Month: Word := 0;
  var Day: Word := 0;
  DecodeDate(ADateTime, Year, Month, Day);

  var Hour: Word := 0;
  var Minute: Word := 0;
  var Second: Word := 0;
  var Millisecond: Word := 0;
  DecodeTime(ADateTime, Hour, Minute, Second, Millisecond);

  Result := Format('%s %s %2d %.2d:%.2d:%.2d %d',
    [CDayNames[DayOfWeek(ADateTime)], CMonthNames[Month], Day, Hour, Minute, Second, Year]);
end;

function ExtractNextCvsEntrySegment(var AInput: string; out ASegment: string): Boolean;
begin
  ASegment := '';
  var SlashIndex := Pos('/', AInput);
  if SlashIndex <= 0 then
    Exit(False);

  ASegment := Copy(AInput, 1, SlashIndex - 1);
  Delete(AInput, 1, SlashIndex);
  Result := True;
end;

function TryParseCvsEntryLine(const AEntryLine: string;
  out AFileName, ARevision, ATimestamp, AOptions, ATagDate: string): Boolean;
begin
  Result := False;
  AFileName := '';
  ARevision := '';
  ATimestamp := '';
  AOptions := '';
  ATagDate := '';

  if not StartsText('/', AEntryLine) then
    Exit;

  var Rest := Copy(AEntryLine, 2, MaxInt);
  if not ExtractNextCvsEntrySegment(Rest, AFileName) then
    Exit;
  if not ExtractNextCvsEntrySegment(Rest, ARevision) then
    Exit;
  if not ExtractNextCvsEntrySegment(Rest, ATimestamp) then
    Exit;
  if not ExtractNextCvsEntrySegment(Rest, AOptions) then
    Exit;
  ATagDate := Rest;
  Result := AFileName <> '';
end;

function BuildCvsEntryLine(const AFileName, ARevision, ATimestamp,
  AOptions, ATagDate: string): string;
begin
  Result := '/' + AFileName + '/' + ARevision + '/' + ATimestamp + '/' + AOptions + '/' + ATagDate;
end;

function TryFindCvsEntry(const AFileName: string;
  out AEntriesFileName: string; out AEntryLineIndex: Integer;
  out AEntryLine: string): Boolean;
begin
  Result := False;
  AEntriesFileName := '';
  AEntryLineIndex := -1;
  AEntryLine := '';

  var FileDirectory := TPath.GetDirectoryName(AFileName);
  if FileDirectory = '' then
    Exit;

  var EntriesFileName := TPath.Combine(TPath.Combine(FileDirectory, 'CVS'), 'Entries');
  if not TFile.Exists(EntriesFileName) then
    Exit;

  var FileNameOnly := TPath.GetFileName(AFileName);
  if FileNameOnly = '' then
    Exit;

  var EntryPrefix := '/' + FileNameOnly + '/';
  var Entries: TArray<string>;
  if not TryReadAllLinesWithRetry(EntriesFileName, Entries) then
    Exit;

  for var I := 0 to High(Entries) do
  begin
    if SameText(Copy(Entries[I], 1, Length(EntryPrefix)), EntryPrefix) then
    begin
      AEntriesFileName := EntriesFileName;
      AEntryLineIndex := I;
      AEntryLine := Entries[I];
      Exit(True);
    end;
  end;
end;

type
  TCvsPreSaveState = record
    // True only when the file has a valid CVS/Entries row.
    IsApplicable: Boolean;
    // True only when CVS considered the file clean before our save cycle.
    WasUnmodifiedByCvs: Boolean;
    // Raw bytes before save, used to detect real content changes after sanitize.
    PreSaveContent: TBytes;
  end;

function CaptureCvsPreSaveState(const AFileName: string): TCvsPreSaveState;
begin
  DebugLog('CaptureCvsPreSaveState START file=' + AFileName);
  Result.IsApplicable := False;
  Result.WasUnmodifiedByCvs := False;
  Result.PreSaveContent := nil;

  var EntriesFileName := '';
  var EntryLineIndex := -1;
  var EntryLine := '';
  if not TryFindCvsEntry(AFileName, EntriesFileName, EntryLineIndex, EntryLine) then
  begin
    DebugLog('CaptureCvsPreSaveState NO_ENTRY file=' + AFileName);
    Exit;
  end;

  Result.IsApplicable := True;

  var ParsedFileName := '';
  var ParsedRevision := '';
  var ParsedTimestamp := '';
  var ParsedOptions := '';
  var ParsedTagDate := '';
  if not TryParseCvsEntryLine(EntryLine, ParsedFileName, ParsedRevision,
    ParsedTimestamp, ParsedOptions, ParsedTagDate) then
  begin
    DebugLog('CaptureCvsPreSaveState PARSE_FAIL file=' + AFileName);
    Exit;
  end;

  if not TFile.Exists(AFileName) then
  begin
    DebugLog('CaptureCvsPreSaveState FILE_MISSING file=' + AFileName);
    Exit;
  end;

  var CurrentLastWriteTimeUtc: TDateTime;
  if not TryGetLastWriteTimeUtcWithRetry(AFileName, CurrentLastWriteTimeUtc) then
  begin
    DebugLog('CaptureCvsPreSaveState TS_READ_FAIL file=' + AFileName);
    Exit;
  end;

  var CurrentTimestampUtc := BuildCvsTimestamp(CurrentLastWriteTimeUtc);
  // If timestamps differ, CVS was already reporting this file as modified.
  // In that case we never auto-reset CVS administrative state.
  if not SameText(ParsedTimestamp, CurrentTimestampUtc) then
  begin
    DebugLog('CaptureCvsPreSaveState DIRTY file=' + AFileName +
      ' entryTs=' + ParsedTimestamp + ' fileUtcTs=' + CurrentTimestampUtc);
    Exit;
  end;

  Result.WasUnmodifiedByCvs := True;
  Result.PreSaveContent := ReadFileRawBytes(AFileName);
  DebugLog('CaptureCvsPreSaveState CLEAN file=' + AFileName +
    ' bytes=' + IntToStr(Length(Result.PreSaveContent)) +
    ' ts=' + CurrentTimestampUtc);
end;

procedure UpdateCvsEntryTimestampToCurrentFile(const AFileName: string);
begin
  DebugLog('UpdateCvsEntryTimestampToCurrentFile START file=' + AFileName);
  var EntriesFileName := '';
  var EntryLineIndex := -1;
  var EntryLine := '';
  if not TryFindCvsEntry(AFileName, EntriesFileName, EntryLineIndex, EntryLine) then
  begin
    DebugLog('UpdateCvsEntryTimestampToCurrentFile NO_ENTRY file=' + AFileName);
    Exit;
  end;

  var ParsedFileName := '';
  var ParsedRevision := '';
  var ParsedTimestamp := '';
  var ParsedOptions := '';
  var ParsedTagDate := '';
  if not TryParseCvsEntryLine(EntryLine, ParsedFileName, ParsedRevision,
    ParsedTimestamp, ParsedOptions, ParsedTagDate) then
  begin
    DebugLog('UpdateCvsEntryTimestampToCurrentFile PARSE_FAIL file=' + AFileName);
    Exit;
  end;

  if not TFile.Exists(AFileName) then
  begin
    DebugLog('UpdateCvsEntryTimestampToCurrentFile FILE_MISSING file=' + AFileName);
    Exit;
  end;

  var CurrentLastWriteTimeUtc: TDateTime;
  if not TryGetLastWriteTimeUtcWithRetry(AFileName, CurrentLastWriteTimeUtc) then
  begin
    DebugLog('UpdateCvsEntryTimestampToCurrentFile TS_READ_FAIL file=' + AFileName);
    Exit;
  end;

  var NewTimestampUtc := BuildCvsTimestamp(CurrentLastWriteTimeUtc);
  var NewTimestamp := NewTimestampUtc;

  if SameText(ParsedTimestamp, NewTimestamp) then
  begin
    DebugLog('UpdateCvsEntryTimestampToCurrentFile ALREADY_ALIGNED file=' + AFileName +
      ' ts=' + NewTimestamp);
    Exit;
  end;

  // Cooperative lock across concurrent IDE/plugin instances touching CVS admin files.
  var MutexHandle: THandle;
  if not TryAcquireCvsMutexWithRetry(EntriesFileName, MutexHandle) then
  begin
    DebugLog('UpdateCvsEntryTimestampToCurrentFile MUTEX_FAIL file=' + AFileName);
    Exit;
  end;

  try
    // If a real CVS command is active, Entries.Log is usually present; skip.
    if IsCvsEntriesLogPresent(EntriesFileName) then
    begin
      DebugLog('UpdateCvsEntryTimestampToCurrentFile ENTRIES_LOG_PRESENT file=' + AFileName);
      Exit;
    end;

    var Entries: TArray<string>;
    if not TryReadAllLinesWithRetry(EntriesFileName, Entries) then
    begin
      DebugLog('UpdateCvsEntryTimestampToCurrentFile ENTRIES_READ_FAIL file=' + AFileName);
      Exit;
    end;

    if (EntryLineIndex < 0) or (EntryLineIndex > High(Entries)) then
    begin
      DebugLog('UpdateCvsEntryTimestampToCurrentFile INDEX_OUT_OF_RANGE file=' + AFileName);
      Exit;
    end;

    // Mirror what cvs update does when file content is unchanged: align only
    // CVS admin timestamp in Entries, without touching the working file.
    Entries[EntryLineIndex] := BuildCvsEntryLine(ParsedFileName, ParsedRevision,
      NewTimestamp, ParsedOptions, ParsedTagDate);
    if TryWriteAllLinesWithRetry(EntriesFileName, Entries, TEncoding.ASCII) then
      DebugLog('UpdateCvsEntryTimestampToCurrentFile UPDATED file=' + AFileName +
        ' oldTs=' + ParsedTimestamp + ' newTs=' + NewTimestamp)
    else
      DebugLog('UpdateCvsEntryTimestampToCurrentFile ENTRIES_WRITE_FAIL file=' + AFileName);
  finally
    ReleaseCvsMutex(MutexHandle);
  end;
end;

procedure ApplyCvsAdminResetIfEquivalent(const AFileName: string;
  const APreSaveState: TCvsPreSaveState);
begin
  DebugLog('ApplyCvsAdminResetIfEquivalent START file=' + AFileName +
    ' applicable=' + BoolFlag(APreSaveState.IsApplicable) +
    ' clean=' + BoolFlag(APreSaveState.WasUnmodifiedByCvs) +
    ' bytes=' + IntToStr(Length(APreSaveState.PreSaveContent)));
  if not APreSaveState.IsApplicable then
    Exit;
  if not APreSaveState.WasUnmodifiedByCvs then
    Exit;
  if Length(APreSaveState.PreSaveContent) = 0 then
    Exit;

  var PostSaveContent := ReadFileRawBytes(AFileName);
  // If bytes differ, this save produced a real change and CVS state must stay dirty.
  if not AreByteArraysEqual(PostSaveContent, APreSaveState.PreSaveContent) then
  begin
    DebugLog('ApplyCvsAdminResetIfEquivalent CONTENT_DIFF file=' + AFileName +
      ' preBytes=' + IntToStr(Length(APreSaveState.PreSaveContent)) +
      ' postBytes=' + IntToStr(Length(PostSaveContent)));
    Exit;
  end;

  DebugLog('ApplyCvsAdminResetIfEquivalent CONTENT_EQUAL file=' + AFileName);
  UpdateCvsEntryTimestampToCurrentFile(AFileName);
end;

procedure QueueDelayedCvsAdminResetIfEquivalent(const AFileName: string;
  const APreSaveState: TCvsPreSaveState);
begin
  if not APreSaveState.IsApplicable then
    Exit;
  if not APreSaveState.WasUnmodifiedByCvs then
    Exit;
  if Length(APreSaveState.PreSaveContent) = 0 then
    Exit;

  DebugLog('QueueDelayedCvsAdminResetIfEquivalent QUEUED file=' + AFileName);

  TThread.CreateAnonymousThread(
    procedure
    begin
      // Some IDE workflows can keep touching .dproj timestamps for several
      // minutes while a large project group finishes opening.
      // Wait until the timestamp stabilizes (or timeout), then retry reset.
      var LastTimestampUtc: TDateTime := 0;
      var StableSamples := 0;

      for var Attempt := 1 to CCvsReconcileMaxAttempts do
      begin
        var CurrentTimestampUtc: TDateTime;
        if not TryGetLastWriteTimeUtcWithRetry(AFileName, CurrentTimestampUtc) then
          Exit;

        if (LastTimestampUtc > 0) and (CurrentTimestampUtc = LastTimestampUtc) then
          Inc(StableSamples)
        else
          StableSamples := 0;

        LastTimestampUtc := CurrentTimestampUtc;

        if StableSamples >= 2 then
        begin
          DebugLog('QueueDelayedCvsAdminResetIfEquivalent STABLE file=' + AFileName +
            ' attempt=' + IntToStr(Attempt) +
            ' ts=' + BuildCvsTimestamp(CurrentTimestampUtc));
          Break;
        end;

        SleepWithCvsReconcileJitter;
      end;

      ApplyCvsAdminResetIfEquivalent(AFileName, APreSaveState);
    end).Start;
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
        var CurrentPlatform := Project160.CurrentPlatform;
        if not SameText(CurrentPlatform, ACurrentPlatform) then
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
          var CurrentRunParams := ReadRunParamsValue(Configuration);
          if CurrentRunParams <> Entry.RunParams then
            Configuration.Value[sDebugger_RunParams] := Entry.RunParams;
        except
        end;
        Continue;
      end;

      try
        var PlatformConfiguration := Configuration.PlatformConfiguration[Entry.PlatformName];
        if Assigned(PlatformConfiguration) then
        begin
          var CurrentRunParams := ReadRunParamsValue(PlatformConfiguration);
          if CurrentRunParams <> Entry.RunParams then
            PlatformConfiguration.Value[sDebugger_RunParams] := Entry.RunParams;
        end;
      except
      end;
    end
  else if Length(ARunParamsMatrix) > 0 then
    try
      var CurrentRunParams := VarToStrDef(AProject.ProjectOptions.GetOptionValue(sDebugger_RunParams), '');
      if CurrentRunParams <> ARunParamsMatrix[0].RunParams then
        AProject.ProjectOptions.SetOptionValue(sDebugger_RunParams, ARunParamsMatrix[0].RunParams);
    except
    end;

  ClearProjectOptionsModifiedState(AProject);

end;

function RestoreProjectSettingsFromSidecar(const AProject: IOTAProject): Boolean;
begin
  Result := False;

  if not Assigned(AProject) then
    Exit;

  var Platform := '';
  var RunParamsMatrix: TRunParamsMatrix := nil;
  LoadTeamworkLocalSettings((AProject as IOTAModule).FileName, Platform, RunParamsMatrix);
  if (Platform = '') and (Length(RunParamsMatrix) = 0) then
    Exit;

  RestoreProjectSettingsFromValues(AProject, Platform, RunParamsMatrix);
  Result := True;

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

  // Capture BEFORE any plugin-induced save so we can compare against the
  // exact pre-save CVS state.
  var PreLoadCvsState := CaptureCvsPreSaveState(ProjectFileName);
  DebugLog('RestoreProjectSettingsFromSidecarOnce START file=' + ProjectFileName +
    ' preApplicable=' + BoolFlag(PreLoadCvsState.IsApplicable) +
    ' preClean=' + BoolFlag(PreLoadCvsState.WasUnmodifiedByCvs));

  try
    var SettingsRestored := RestoreProjectSettingsFromSidecar(AProject);
    DebugLog('RestoreProjectSettingsFromSidecarOnce RESTORED file=' + ProjectFileName +
      ' restored=' + BoolFlag(SettingsRestored));
    if SettingsRestored then
    begin
      SaveProjectModuleSilently(AProject);
      DebugLog('RestoreProjectSettingsFromSidecarOnce SAVE_SILENT file=' + ProjectFileName);
    end;

    // This covers load-time timestamp touches that do not pass through
    // IOTAProjectNotifier save callbacks.
    QueueDelayedCvsAdminResetIfEquivalent(ProjectFileName, PreLoadCvsState);

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
    FCvsPreSaveState: TCvsPreSaveState;
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
    DebugLog('TProjectSaveHook.AfterSave START file=' + ProjectFileName);
    SanitizeProjectFile(ProjectFileName);
    RestoreProjectSettingsFromValues(FProject, FCapturedPlatform, FCapturedRunParamsMatrix);
    ApplyCvsAdminResetIfEquivalent(ProjectFileName, FCvsPreSaveState);
    QueueDelayedCvsAdminResetIfEquivalent(ProjectFileName, FCvsPreSaveState);
    DebugLog('TProjectSaveHook.AfterSave END file=' + ProjectFileName);
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

  var ProjectFileName := (FProject as IOTAModule).FileName;
  FCvsPreSaveState := CaptureCvsPreSaveState(ProjectFileName);
  DebugLog('TProjectSaveHook.BeforeSave file=' + ProjectFileName +
    ' preApplicable=' + BoolFlag(FCvsPreSaveState.IsApplicable) +
    ' preClean=' + BoolFlag(FCvsPreSaveState.WasUnmodifiedByCvs) +
    ' preBytes=' + IntToStr(Length(FCvsPreSaveState.PreSaveContent)));

  CaptureProjectSettings(FProject, FCapturedPlatform, FCapturedRunParamsMatrix);

  SaveTeamworkLocalSettings(ProjectFileName,
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

  DebugLog('TLocalSettingsStorageNotifier.ProjectLoaded file=' +
    (Project as IOTAModule).FileName);

  // Important: install the project save hook first, then let it queue the
  // restore/save cycle. This guarantees bootstrap saves pass through
  // BeforeSave/AfterSave, including CVS metadata reset logic.
  InstallProjectHook(Project);
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
  if not FileName.EndsWith('.dproj', True) then Exit;

  DebugLog('TIDENotifier.FileNotification code=' + IntToStr(Ord(NotifyCode)) +
    ' file=' + FileName);

  if NotifyCode <> ofnFileOpened then Exit;

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
