program DprojSanitizerCli;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Variants,
  Winapi.ActiveX,
  Xml.XMLIntf,
  Xml.XMLDoc,
  Xml.xmldom,
  Xml.Win.msxmldom,
  untDprojSanitizer in '..\..\untDprojSanitizer.pas',
  untLocalDevSettingsStore in '..\..\untLocalDevSettingsStore.pas';

const
  CActivePlatformCondition = #39'$(Platform)'#39'=='#39#39;

function FindChildByLocalName(const AParent: IXMLNode; const ALocalName: string): IXMLNode;
begin
  Result := nil;
  if not Assigned(AParent) then
    Exit;
  for var I := 0 to AParent.ChildNodes.Count - 1 do
  begin
    var Child := AParent.ChildNodes[I];
    if (Child.NodeType = ntElement) and SameText(Child.LocalName, ALocalName) then
      Exit(Child);
  end;
end;

function LoadXmlDocument(const AFileName: string): IXMLDocument;
begin
  DefaultDOMVendor := SMSXML;
  Result := TXMLDocument.Create(nil);
  Result.ParseOptions := [poPreserveWhiteSpace];
  Result.FileName := AFileName;
  Result.Active := True;
end;

function ReadRunParamsFromDproj(const ARoot: IXMLNode): string;
begin
  Result := '';
  for var I := 0 to ARoot.ChildNodes.Count - 1 do
  begin
    var PG := ARoot.ChildNodes[I];
    if (PG.NodeType <> ntElement) or not SameText(PG.LocalName, 'PropertyGroup') then
      Continue;
    for var J := 0 to PG.ChildNodes.Count - 1 do
    begin
      var Child := PG.ChildNodes[J];
      if (Child.NodeType <> ntElement) or not SameText(Child.LocalName, 'Debugger_RunParams') then
        Continue;
      Result := Child.Text;
      if Result <> '' then
        Exit;
    end;
  end;
end;

function ReadActivePlatformFromDproj(const ARoot: IXMLNode): string;
begin
  Result := '';
  for var I := 0 to ARoot.ChildNodes.Count - 1 do
  begin
    var PG := ARoot.ChildNodes[I];
    if (PG.NodeType <> ntElement) or not SameText(PG.LocalName, 'PropertyGroup') then
      Continue;
    for var J := 0 to PG.ChildNodes.Count - 1 do
    begin
      var Child := PG.ChildNodes[J];
      if (Child.NodeType <> ntElement) or not SameText(Child.LocalName, 'Platform') then
        Continue;
      var CondAttr := Child.AttributeNodes.FindNode('Condition');
      if Assigned(CondAttr) and (VarToStr(CondAttr.NodeValue) = CActivePlatformCondition) then
        Exit(Child.Text);
    end;
  end;
end;

procedure UpdateLocalFile(const ADprojFileName, ARunParams, APlatform: string);
begin
  var RunParamsMatrix: TRunParamsMatrix;
  SetLength(RunParamsMatrix, 1);
  RunParamsMatrix[0].ConfigurationKey := '';
  RunParamsMatrix[0].ConfigurationName := '';
  RunParamsMatrix[0].PlatformName := APlatform;
  RunParamsMatrix[0].RunParams := ARunParams;
  SaveTeamworkLocalSettings(ADprojFileName, APlatform, RunParamsMatrix);
end;

procedure PrintUsage;
begin
  WriteLn('Usage: DprojSanitizerCli <file|folder|wildcard> [/s]');
  WriteLn('  /s  Search recursively in subfolders (useful with wildcard/folder input)');
  WriteLn('Examples:');
  WriteLn('  DprojSanitizerCli "C:\Repo\MyProject.dproj"');
  WriteLn('  DprojSanitizerCli "C:\Repo\*.dproj"');
  WriteLn('  DprojSanitizerCli "C:\Repo" /s');
end;

function HasWildcards(const AValue: string): Boolean;
begin
  Result := (Pos('*', AValue) > 0) or (Pos('?', AValue) > 0);
end;

procedure AddDprojFilesFromDirectory(const ADirectory: string;
  const ARecursive: Boolean; AFiles: TStrings);
var
  SearchOption: TSearchOption;
begin
  if ARecursive then
    SearchOption := TSearchOption.soAllDirectories
  else
    SearchOption := TSearchOption.soTopDirectoryOnly;

  for var FileName in TDirectory.GetFiles(ADirectory, '*.dproj', SearchOption) do
    AFiles.Add(FileName);
end;

procedure ResolveInputToFileList(const AInput: string; const ARecursive: Boolean;
  AFiles: TStrings);
begin
  if TFile.Exists(AInput) then
  begin
    if SameText(TPath.GetExtension(AInput), '.dproj') then
      AFiles.Add(ExpandFileName(AInput));
    Exit;
  end;

  if TDirectory.Exists(AInput) then
  begin
    AddDprojFilesFromDirectory(ExpandFileName(AInput), ARecursive, AFiles);
    Exit;
  end;

  if HasWildcards(AInput) then
  begin
    var ExpandedInput := ExpandFileName(AInput);
    var DirectoryPart := ExtractFilePath(ExpandedInput);
    var FileMask := ExtractFileName(ExpandedInput);
    if DirectoryPart = '' then
      DirectoryPart := GetCurrentDir;
    if FileMask = '' then
      FileMask := '*.dproj';
    if TDirectory.Exists(DirectoryPart) then
    begin
      var SearchOption := TSearchOption.soTopDirectoryOnly;
      if ARecursive then
        SearchOption := TSearchOption.soAllDirectories;
      for var FileName in TDirectory.GetFiles(DirectoryPart, FileMask, SearchOption) do
        if SameText(TPath.GetExtension(FileName), '.dproj') then
          AFiles.Add(FileName);
    end;
  end;
end;

function ProcessProjectFile(const ADprojFileName: string): Boolean;
begin
  Result := False;
  try
    var Doc := LoadXmlDocument(ADprojFileName);
    var Root := Doc.DocumentElement;
    var RunParams := ReadRunParamsFromDproj(Root);
    var Platform := ReadActivePlatformFromDproj(Root);
    if Platform = '' then
      Platform := 'Win32';

    SanitizeProjectFile(ADprojFileName);
    UpdateLocalFile(ADprojFileName, RunParams, Platform);

    WriteLn('OK: sanitized ', ADprojFileName);
    WriteLn('OK: updated   ', GetTeamworkLocalFileName(ADprojFileName));
    Result := True;
  except
    on E: Exception do
      WriteLn('ERROR on ', ADprojFileName, ': ', E.ClassName, ': ', E.Message);
  end;
end;

begin
  CoInitialize(nil);
  try
    if ParamCount < 1 then
    begin
      PrintUsage;
      ExitCode := 1;
      Exit;
    end;

    var InputPattern := ParamStr(1);
    var Recursive := False;
    for var I := 2 to ParamCount do
      if SameText(ParamStr(I), '/s') then
        Recursive := True;

    var Files := TStringList.Create;
    try
      Files.CaseSensitive := False;
      Files.Sorted := True;
      Files.Duplicates := dupIgnore;
      ResolveInputToFileList(InputPattern, Recursive, Files);

      if Files.Count = 0 then
      begin
        WriteLn('Error: no .dproj files found for input: ', InputPattern);
        ExitCode := 2;
        Exit;
      end;

      var SuccessCount := 0;
      var ErrorCount := 0;
      for var FileName in Files do
      begin
        if ProcessProjectFile(FileName) then
          Inc(SuccessCount)
        else
          Inc(ErrorCount);
      end;

      WriteLn;
      WriteLn(Format('Completed. Successes: %d, Errors: %d', [SuccessCount, ErrorCount]));
      if ErrorCount > 0 then
        ExitCode := 4;
    finally
      Files.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('Error: ', E.ClassName, ': ', E.Message);
      ExitCode := 10;
    end;
  end;
  CoUninitialize;
end.
