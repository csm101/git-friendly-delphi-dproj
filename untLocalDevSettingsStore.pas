unit untLocalDevSettingsStore;

interface

uses
  System.SysUtils;

const
  CTeamworkLocalSuffix = '.localcfg';
  CLegacyTeamworkLocalSuffix = '.teamowork.local';

type
  TRunParamsMatrixEntry = record
    ConfigurationKey: string;
    ConfigurationName: string;
    PlatformName: string;
    RunParams: string;
  end;

  TRunParamsMatrix = TArray<TRunParamsMatrixEntry>;

function GetTeamworkLocalFileName(const AProjectFileName: string): string;
procedure SaveTeamworkLocalSettings(const AProjectFileName, ACurrentPlatform: string;
  const ARunParamsMatrix: TRunParamsMatrix);
procedure LoadTeamworkLocalSettings(const AProjectFileName: string;
  out ACurrentPlatform: string; out ARunParamsMatrix: TRunParamsMatrix);

implementation

uses
  System.IOUtils,
  System.Variants,
  System.RegularExpressions,
  Xml.XMLIntf,
  Xml.XMLDoc,
  Xml.xmldom,
  Xml.Win.msxmldom;

const
  CRootNodeName = 'LocalDevSettings';
  CCurrentPlatformNodeName = 'CurrentPlatform';
  CRunParamsMatrixNodeName = 'RunParamsMatrix';
  CConfigurationNodeName = 'Configuration';
  CConfigurationKeyAttribute = 'key';
  CConfigurationNameAttribute = 'name';
  CPlatformNodeName = 'Platform';
  CRunParamsNodeName = 'RunParams';
  CPlatformNameAttribute = 'name';

function MatrixEquals(const ALeft, ARight: TRunParamsMatrix): Boolean;
begin
  if Length(ALeft) <> Length(ARight) then
    Exit(False);

  for var i := 0 to High(ALeft) do
  begin
    if not SameText(ALeft[i].ConfigurationKey, ARight[i].ConfigurationKey) then
      Exit(False);
    if not SameText(ALeft[i].ConfigurationName, ARight[i].ConfigurationName) then
      Exit(False);
    if not SameText(ALeft[i].PlatformName, ARight[i].PlatformName) then
      Exit(False);
    if ALeft[i].RunParams <> ARight[i].RunParams then
      Exit(False);
  end;

  Result := True;
end;

function DetectXmlEncodingFromFile(const AFileName: string): string;
begin
  Result := '';
  if not TFile.Exists(AFileName) then
    Exit;

  var Fs := TFile.OpenRead(AFileName);
  try
    var ByteCount := Fs.Size;
    if ByteCount > 4096 then
      ByteCount := 4096;
    if ByteCount <= 0 then
      Exit;

    var Buffer: TBytes;
    SetLength(Buffer, ByteCount);
    if Fs.Read(Buffer, 0, ByteCount) <= 0 then
      Exit;

    var HeadText := TEncoding.ASCII.GetString(Buffer);
    var Match := TRegEx.Match(HeadText, 'encoding\s*=\s*[''\"]([^''\"]+)[''\"]', [roIgnoreCase]);
    if Match.Success then
      Result := Match.Groups[1].Value;
  finally
    Fs.Free;
  end;
end;

function GetChildText(const ANode: IXMLNode; const AChildName: string): string;
begin
  Result := '';
  if not Assigned(ANode) then
    Exit;

  var Child := ANode.ChildNodes.FindNode(AChildName);
  if Assigned(Child) then
    Result := Child.Text;
end;

procedure SetChildText(const ANode: IXMLNode; const AChildName, AValue: string);
begin
  if not Assigned(ANode) then
    Exit;

  var Child := ANode.ChildNodes.FindNode(AChildName);
  if not Assigned(Child) then
    Child := ANode.AddChild(AChildName);
  Child.Text := AValue;
end;

function EnsureRootNode(const ADoc: IXMLDocument): IXMLNode;
begin
  Result := ADoc.DocumentElement;
  if not Assigned(Result) then
  begin
    Result := ADoc.AddChild(CRootNodeName);
    ADoc.DocumentElement := Result;
  end;
end;

function EnsurePlatformNode(const ARunParamsByPlatformNode: IXMLNode;
  const APlatform: string): IXMLNode;
begin
  Result := nil;

  for var i := 0 to ARunParamsByPlatformNode.ChildNodes.Count - 1 do
  begin
    var CandidateNode := ARunParamsByPlatformNode.ChildNodes[i];
    if not SameText(CandidateNode.NodeName, CPlatformNodeName) then
      Continue;
    if not CandidateNode.HasAttribute(CPlatformNameAttribute) then
      Continue;
    if not SameText(VarToStrDef(CandidateNode.Attributes[CPlatformNameAttribute], ''), APlatform) then
      Continue;

    Result := CandidateNode;
    Exit;
  end;

  Result := ARunParamsByPlatformNode.AddChild(CPlatformNodeName);
  Result.Attributes[CPlatformNameAttribute] := APlatform;
end;

function EnsureConfigurationNode(const AMatrixNode: IXMLNode;
  const AConfigurationKey, AConfigurationName: string): IXMLNode;
begin
  Result := nil;

  for var i := 0 to AMatrixNode.ChildNodes.Count - 1 do
  begin
    var CandidateNode := AMatrixNode.ChildNodes[i];
    if not SameText(CandidateNode.NodeName, CConfigurationNodeName) then
      Continue;
    if not SameText(VarToStrDef(CandidateNode.Attributes[CConfigurationKeyAttribute], ''), AConfigurationKey) then
      Continue;
    if not SameText(VarToStrDef(CandidateNode.Attributes[CConfigurationNameAttribute], ''), AConfigurationName) then
      Continue;

    Result := CandidateNode;
    Exit;
  end;

  Result := AMatrixNode.AddChild(CConfigurationNodeName);
  Result.Attributes[CConfigurationKeyAttribute] := AConfigurationKey;
  Result.Attributes[CConfigurationNameAttribute] := AConfigurationName;
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

function CreateEmptySidecarDocument: IXMLDocument;
begin
  Result := NewXMLDocument;
  Result.Options := Result.Options + [doNodeAutoIndent];
  Result.Encoding := 'utf-8';
end;

function LoadSidecarDocument(const ASidecarFileName: string): IXMLDocument;
begin
  var PreviousDomVendor := DefaultDOMVendor;
  DefaultDOMVendor := SMSXML;
  try
    if TFile.Exists(ASidecarFileName) and (TFile.GetSize(ASidecarFileName) > 0) then
    begin
      try
        Result := TXMLDocument.Create(nil);
        Result.ParseOptions := [];
        Result.Options := Result.Options + [doNodeAutoIndent];
        Result.FileName := ASidecarFileName;
        Result.Active := True;
      except
        // Empty/corrupted file: recreate a fresh document without interrupting Save.
        Result := CreateEmptySidecarDocument;
      end;
      Exit;
    end;

    Result := CreateEmptySidecarDocument;
  finally
    DefaultDOMVendor := PreviousDomVendor;
  end;
end;

function ResolveLocalSettingsFileNameForRead(const AProjectFileName: string;
  out ALoadedFromLegacy: Boolean): string; forward;

procedure LoadTeamworkLocalSettingsInternal(const AProjectFileName: string;
  out ACurrentPlatform: string; out ARunParamsMatrix: TRunParamsMatrix;
  out ARecoveredFromCorruption: Boolean; out ALoadedFromLegacy: Boolean);
begin
  ACurrentPlatform := '';
  ARunParamsMatrix := nil;
  ARecoveredFromCorruption := False;
  ALoadedFromLegacy := False;

  var SidecarFileName := ResolveLocalSettingsFileNameForRead(AProjectFileName,
    ALoadedFromLegacy);
  if not TFile.Exists(SidecarFileName) then
    Exit;

  var PreviousDomVendor := DefaultDOMVendor;
  try
    DefaultDOMVendor := SMSXML;
    try
      var ProbeDoc := TXMLDocument.Create(nil);
      ProbeDoc.ParseOptions := [];
      ProbeDoc.FileName := SidecarFileName;
      ProbeDoc.Active := True;
    except
      ARecoveredFromCorruption := True;
    end;
  finally
    DefaultDOMVendor := PreviousDomVendor;
  end;

  var Doc := LoadSidecarDocument(SidecarFileName);
  var Root := Doc.DocumentElement;
  if not Assigned(Root) then
    Exit;

  ACurrentPlatform := GetChildText(Root, CCurrentPlatformNodeName);

  var MatrixNode := Root.ChildNodes.FindNode(CRunParamsMatrixNodeName);
  if not Assigned(MatrixNode) then
    Exit;

  for var i := 0 to MatrixNode.ChildNodes.Count - 1 do
  begin
    var ConfigurationNode := MatrixNode.ChildNodes[i];
    if not SameText(ConfigurationNode.NodeName, CConfigurationNodeName) then
      Continue;

    var ConfigurationKey := VarToStrDef(ConfigurationNode.Attributes[CConfigurationKeyAttribute], '');
    var ConfigurationName := VarToStrDef(ConfigurationNode.Attributes[CConfigurationNameAttribute], '');

    var ConfigurationRunParams := GetChildText(ConfigurationNode, CRunParamsNodeName);
    AddMatrixEntry(ARunParamsMatrix, ConfigurationKey, ConfigurationName, '', ConfigurationRunParams);

    for var j := 0 to ConfigurationNode.ChildNodes.Count - 1 do
    begin
      var PlatformNode := ConfigurationNode.ChildNodes[j];
      if not SameText(PlatformNode.NodeName, CPlatformNodeName) then
        Continue;

      var PlatformName := VarToStrDef(PlatformNode.Attributes[CPlatformNameAttribute], '');
      var PlatformRunParams := GetChildText(PlatformNode, CRunParamsNodeName);
      AddMatrixEntry(ARunParamsMatrix, ConfigurationKey, ConfigurationName,
        PlatformName, PlatformRunParams);
    end;
  end;
end;

function GetTeamworkLocalFileName(const AProjectFileName: string): string;
begin
  Result := AProjectFileName + CTeamworkLocalSuffix;
end;

function GetLegacyTeamworkLocalFileName(const AProjectFileName: string): string;
begin
  Result := AProjectFileName + CLegacyTeamworkLocalSuffix;
end;

function ResolveLocalSettingsFileNameForRead(const AProjectFileName: string;
  out ALoadedFromLegacy: Boolean): string;
begin
  ALoadedFromLegacy := False;

  Result := GetTeamworkLocalFileName(AProjectFileName);
  if TFile.Exists(Result) then
    Exit;

  var LegacyFileName := GetLegacyTeamworkLocalFileName(AProjectFileName);
  if TFile.Exists(LegacyFileName) then
  begin
    ALoadedFromLegacy := True;
    Result := LegacyFileName;
  end;
end;

procedure SaveTeamworkLocalSettings(const AProjectFileName, ACurrentPlatform: string;
  const ARunParamsMatrix: TRunParamsMatrix);
begin
  var SidecarFileName := GetTeamworkLocalFileName(AProjectFileName);

  var ExistingPlatform := '';
  var ExistingMatrix: TRunParamsMatrix := nil;
  var RecoveredFromCorruption := False;
  var LoadedFromLegacy := False;
  LoadTeamworkLocalSettingsInternal(AProjectFileName, ExistingPlatform, ExistingMatrix,
    RecoveredFromCorruption, LoadedFromLegacy);
  if (not RecoveredFromCorruption) and (not LoadedFromLegacy) and
     SameText(ExistingPlatform, ACurrentPlatform) and
     MatrixEquals(ExistingMatrix, ARunParamsMatrix) then
    Exit;

  var Doc := LoadSidecarDocument(SidecarFileName);

  var ExistingEncoding := DetectXmlEncodingFromFile(SidecarFileName);
  if ExistingEncoding <> '' then
    Doc.Encoding := ExistingEncoding;

  var Root := EnsureRootNode(Doc);

  // Remove data written by previous schema versions so output stays clean.
  var LegacyNode := Root.ChildNodes.FindNode('RunParamsByPlatform');
  if Assigned(LegacyNode) then
    Root.ChildNodes.Remove(LegacyNode);

  SetChildText(Root, CCurrentPlatformNodeName, ACurrentPlatform);

  var ExistingMatrixNode := Root.ChildNodes.FindNode(CRunParamsMatrixNodeName);
  if Assigned(ExistingMatrixNode) then
    Root.ChildNodes.Remove(ExistingMatrixNode);

  var MatrixNode := Root.AddChild(CRunParamsMatrixNodeName);
  for var Entry in ARunParamsMatrix do
  begin
    if Entry.RunParams = '' then
      Continue;

    var ConfigurationNode := EnsureConfigurationNode(MatrixNode,
      Entry.ConfigurationKey, Entry.ConfigurationName);
    if Entry.PlatformName = '' then
    begin
      SetChildText(ConfigurationNode, CRunParamsNodeName, Entry.RunParams);
      Continue;
    end;

    var PlatformNode := EnsurePlatformNode(ConfigurationNode, Entry.PlatformName);
    SetChildText(PlatformNode, CRunParamsNodeName, Entry.RunParams);
  end;

  Doc.SaveToFile(SidecarFileName);
end;

procedure LoadTeamworkLocalSettings(const AProjectFileName: string;
  out ACurrentPlatform: string; out ARunParamsMatrix: TRunParamsMatrix);
begin
  var RecoveredFromCorruption := False;
  var LoadedFromLegacy := False;
  LoadTeamworkLocalSettingsInternal(AProjectFileName, ACurrentPlatform,
    ARunParamsMatrix, RecoveredFromCorruption, LoadedFromLegacy);
end;

end.
