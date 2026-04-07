unit untCvsLegacySupport;

interface

uses
  System.Classes,
  System.SysUtils;

type
  TCvsPreSaveState = record
    // True only when the file has a valid CVS/Entries row.
    IsApplicable: Boolean;
    // True only when CVS considered the file clean before our save cycle.
    WasUnmodifiedByCvs: Boolean;
    // Raw bytes before save, used to detect real content changes after sanitize.
    PreSaveContent: TBytes;
  end;

type
  TCvsReconcileThread = class(TThread)
  private
    FFileName: string;
    FPreSaveState: TCvsPreSaveState;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFileName: string; const APreSaveState: TCvsPreSaveState);
  end;

function CaptureCvsPreSaveState(const AFileName: string): TCvsPreSaveState;
procedure ApplyCvsAdminResetIfEquivalent(const AFileName: string;
  const APreSaveState: TCvsPreSaveState);
procedure QueueDelayedCvsAdminResetIfEquivalent(const AFileName: string;
  const APreSaveState: TCvsPreSaveState);

implementation

uses
  System.IOUtils,
  System.StrUtils,
  Winapi.Windows;

const
  CFileIoRetryCount = 5;
  CFileIoRetryDelayMs = 40;
  CFileIoRetryJitterMs = 40;
  CCvsMutexPrefix = 'Local\TeamoworkFriendlyDproj_CVS_';
  CCvsReconcilePollDelayMs = 1000;
  CCvsReconcilePollJitterMs = 500;
  CCvsReconcileMaxAttempts = 600;

var
  GRetryRandomSeedInitialized: Boolean = False;

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
    Exit;

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

function CaptureCvsPreSaveState(const AFileName: string): TCvsPreSaveState;
begin
  Result.IsApplicable := False;
  Result.WasUnmodifiedByCvs := False;
  Result.PreSaveContent := nil;

  var EntriesFileName := '';
  var EntryLineIndex := -1;
  var EntryLine := '';
  if not TryFindCvsEntry(AFileName, EntriesFileName, EntryLineIndex, EntryLine) then
    Exit;

  Result.IsApplicable := True;

  var ParsedFileName := '';
  var ParsedRevision := '';
  var ParsedTimestamp := '';
  var ParsedOptions := '';
  var ParsedTagDate := '';
  if not TryParseCvsEntryLine(EntryLine, ParsedFileName, ParsedRevision,
    ParsedTimestamp, ParsedOptions, ParsedTagDate) then
    Exit;

  if not TFile.Exists(AFileName) then
    Exit;

  var CurrentLastWriteTimeUtc: TDateTime;
  if not TryGetLastWriteTimeUtcWithRetry(AFileName, CurrentLastWriteTimeUtc) then
    Exit;

  var CurrentTimestampUtc := BuildCvsTimestamp(CurrentLastWriteTimeUtc);
  if not SameText(ParsedTimestamp, CurrentTimestampUtc) then
    Exit;

  Result.WasUnmodifiedByCvs := True;
  Result.PreSaveContent := ReadFileRawBytes(AFileName);
end;

constructor TCvsReconcileThread.Create(const AFileName: string;
  const APreSaveState: TCvsPreSaveState);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FFileName := AFileName;
  FPreSaveState := APreSaveState;
end;

procedure TCvsReconcileThread.Execute;
begin
  var LastTimestampUtc: TDateTime := 0;
  var StableSamples := 0;

  for var Attempt := 1 to CCvsReconcileMaxAttempts do
  begin
    var CurrentTimestampUtc: TDateTime;
    if not TryGetLastWriteTimeUtcWithRetry(FFileName, CurrentTimestampUtc) then
      Exit;

    if (LastTimestampUtc > 0) and (CurrentTimestampUtc = LastTimestampUtc) then
      Inc(StableSamples)
    else
      StableSamples := 0;

    LastTimestampUtc := CurrentTimestampUtc;

    if StableSamples >= 2 then
      Break;

    SleepWithCvsReconcileJitter;
  end;

  ApplyCvsAdminResetIfEquivalent(FFileName, FPreSaveState);
end;

procedure UpdateCvsEntryTimestampToCurrentFile(const AFileName: string);
begin
  var EntriesFileName := '';
  var EntryLineIndex := -1;
  var EntryLine := '';
  if not TryFindCvsEntry(AFileName, EntriesFileName, EntryLineIndex, EntryLine) then
    Exit;

  var ParsedFileName := '';
  var ParsedRevision := '';
  var ParsedTimestamp := '';
  var ParsedOptions := '';
  var ParsedTagDate := '';
  if not TryParseCvsEntryLine(EntryLine, ParsedFileName, ParsedRevision,
    ParsedTimestamp, ParsedOptions, ParsedTagDate) then
    Exit;

  if not TFile.Exists(AFileName) then
    Exit;

  var CurrentLastWriteTimeUtc: TDateTime;
  if not TryGetLastWriteTimeUtcWithRetry(AFileName, CurrentLastWriteTimeUtc) then
    Exit;

  var NewTimestamp := BuildCvsTimestamp(CurrentLastWriteTimeUtc);
  if SameText(ParsedTimestamp, NewTimestamp) then
    Exit;

  var MutexHandle: THandle;
  if not TryAcquireCvsMutexWithRetry(EntriesFileName, MutexHandle) then
    Exit;

  try
    if IsCvsEntriesLogPresent(EntriesFileName) then
      Exit;

    var Entries: TArray<string>;
    if not TryReadAllLinesWithRetry(EntriesFileName, Entries) then
      Exit;

    if (EntryLineIndex < 0) or (EntryLineIndex > High(Entries)) then
      Exit;

    Entries[EntryLineIndex] := BuildCvsEntryLine(ParsedFileName, ParsedRevision,
      NewTimestamp, ParsedOptions, ParsedTagDate);
    TryWriteAllLinesWithRetry(EntriesFileName, Entries, TEncoding.ASCII);
  finally
    ReleaseCvsMutex(MutexHandle);
  end;
end;

procedure ApplyCvsAdminResetIfEquivalent(const AFileName: string;
  const APreSaveState: TCvsPreSaveState);
begin
  if not APreSaveState.IsApplicable then
    Exit;
  if not APreSaveState.WasUnmodifiedByCvs then
    Exit;
  if Length(APreSaveState.PreSaveContent) = 0 then
    Exit;

  var PostSaveContent := ReadFileRawBytes(AFileName);
  if not AreByteArraysEqual(PostSaveContent, APreSaveState.PreSaveContent) then
    Exit;

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

  TCvsReconcileThread.Create(AFileName, APreSaveState);
end;

end.
