unit untDprojSanitizer;

{
  XML sanitizer for Delphi .dproj files.

  Removes volatile per-developer settings that cause recurring merge conflicts
  in teams with heterogeneous IDE setups.

  Performed operations:
   1. Clears <Debugger_RunParams>.
   2. Normalizes <Platform Condition="'$(Platform)'==''"> to the first supported platform.
   3. Removes base <PropertyGroup> nodes for unsupported platforms (only groups with
     '$(Base)'=='true' in Condition; config x platform groups are preserved).
   4. Removes <Platform value="X">False</Platform> nodes from <Platforms>.
   5. Removes the entire <Excluded_Packages> node.
   6. In the <Deployment> section, removes unsupported <Platform Name="X"> nodes from
     each <DeployFile>/<DeployClass>; removes entries left without any supported Platform.
}

interface

uses
  System.Classes,
  Xml.XMLIntf;

// Collects platform names for which <Platform value="X">True</Platform> exists.
// Exposed publicly for testing.
procedure CollectSupportedPlatforms(const ANode: IXMLNode; APlatforms: TStringList);

// Sanitizes a .dproj document already loaded in memory.
// ASupportedPlatforms must contain the project's active platform names.
procedure SanitizeDprojDocument(const ADoc: IXMLDocument;
  const ASupportedPlatforms: TStringList);

// Loads, sanitizes, and saves a .dproj file.
// The platform list is derived from the file's own <Platforms> section.
procedure SanitizeProjectFile(const AFileName: string);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Variants,
  System.RegularExpressions,
  System.Generics.Collections,
  Xml.XMLDoc,
  Xml.xmldom,
  Xml.Win.msxmldom;

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

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

function FindChildByLocalName(const AParent: IXMLNode;
  const ALocalName: string): IXMLNode;
begin
  Result := nil;
  if not Assigned(AParent) then Exit;
  for var I := 0 to AParent.ChildNodes.Count - 1 do
  begin
    var Child := AParent.ChildNodes[I];
    if (Child.NodeType = ntElement) and SameText(Child.LocalName, ALocalName) then
      Exit(Child);
  end;
end;

// Extracts platform name from an MSBuild Condition string such as:
//   ('$(Platform)'=='Linux64' and '$(Base)'=='true') or '$(Base_Linux64)'!=''
function PlatformFromCondition(const ACondition: string): string;
begin
  var Match := TRegEx.Match(ACondition, '''\$\(Platform\)''==''([^'']+)''');
  if Match.Success then
    Result := Match.Groups[1].Value
  else
    Result := '';
end;

// ---------------------------------------------------------------------------
// 1. CollectSupportedPlatforms
// ---------------------------------------------------------------------------

function FindPlatformsNode(const ANode: IXMLNode): IXMLNode;
begin
  Result := nil;
  if not Assigned(ANode) then
    Exit;

  if SameText(ANode.LocalName, 'Platforms') then
    Exit(ANode);

  for var I := 0 to ANode.ChildNodes.Count - 1 do
  begin
    var Child := ANode.ChildNodes[I];
    if Child.NodeType <> ntElement then
      Continue;
    Result := FindPlatformsNode(Child);
    if Assigned(Result) then
      Exit;
  end;
end;

procedure CollectSupportedPlatforms(const ANode: IXMLNode; APlatforms: TStringList);
begin
  var PlatformsNode := FindPlatformsNode(ANode);
  if not Assigned(PlatformsNode) then
    Exit;

  for var I := 0 to PlatformsNode.ChildNodes.Count - 1 do
  begin
    var Child := PlatformsNode.ChildNodes[I];
    if Child.NodeType <> ntElement then
      Continue;
    if SameText(Child.LocalName, 'Platform') and
       Child.HasAttribute('value') and
       SameText(Child.Text, 'True') then
      APlatforms.Add(VarToStr(Child.Attributes['value']));
  end;
end;

// ---------------------------------------------------------------------------
// 2. RemoveUnsupportedPlatformGroups
// ---------------------------------------------------------------------------

// Only PropertyGroup nodes with '$(Base)'=='true' in Condition are platform-base groups.
// Config x platform groups ('$(Cfg_N)'=='true') are never removed.
function IsBasePlatformCondition(const ACondition: string): Boolean;
begin
  if not ACondition.Contains('''$(Base)''==''true''') then
    Exit(False);
  if not ACondition.Contains('''$(Platform)''==''') then
    Exit(False);
  Result := True;
end;

procedure RemoveUnsupportedPlatformGroups(const ARoot: IXMLNode;
  const ASupportedPlatforms: TStringList);
var
  NodesToRemove: TList<IXMLNode>;
begin
  NodesToRemove := TList<IXMLNode>.Create;
  try
    for var I := 0 to ARoot.ChildNodes.Count - 1 do
    begin
      var Child := ARoot.ChildNodes[I];
      if Child.NodeType <> ntElement then Continue;
      if not SameText(Child.LocalName, 'PropertyGroup') then Continue;
      var CondAttr := Child.AttributeNodes.FindNode('Condition');
      if not Assigned(CondAttr) then Continue;
      var Condition := VarToStr(CondAttr.NodeValue);
      if not IsBasePlatformCondition(Condition) then Continue;
      var Platform := PlatformFromCondition(Condition);
      if (Platform <> '') and (ASupportedPlatforms.IndexOf(Platform) < 0) then
        NodesToRemove.Add(Child);
    end;
    for var Node in NodesToRemove do
      ARoot.ChildNodes.Remove(Node);
  finally
    NodesToRemove.Free;
  end;
end;

// ---------------------------------------------------------------------------
// 3. ClearRunParams
// ---------------------------------------------------------------------------

procedure ClearRunParams(const ARoot: IXMLNode);
begin
  for var I := 0 to ARoot.ChildNodes.Count - 1 do
  begin
    var PG := ARoot.ChildNodes[I];
    if PG.NodeType <> ntElement then Continue;
    if not SameText(PG.LocalName, 'PropertyGroup') then Continue;
    for var J := 0 to PG.ChildNodes.Count - 1 do
    begin
      var Child := PG.ChildNodes[J];
      if Child.NodeType <> ntElement then Continue;
      if not SameText(Child.LocalName, 'Debugger_RunParams') then Continue;
      Child.Text := '';
    end;
  end;
end;

// ---------------------------------------------------------------------------
// 4. RemoveExcludedPackages
// ---------------------------------------------------------------------------

procedure RemoveExcludedPackages(const ANode: IXMLNode);
var
  NodesToRemove: TList<IXMLNode>;
begin
  NodesToRemove := TList<IXMLNode>.Create;
  try
    for var I := 0 to ANode.ChildNodes.Count - 1 do
    begin
      var Child := ANode.ChildNodes[I];
      if Child.NodeType <> ntElement then Continue;
      if SameText(Child.LocalName, 'Excluded_Packages') then
        NodesToRemove.Add(Child)
      else if Child.HasChildNodes then
        RemoveExcludedPackages(Child);
    end;
    for var Node in NodesToRemove do
      ANode.ChildNodes.Remove(Node);
  finally
    NodesToRemove.Free;
  end;
end;

// ---------------------------------------------------------------------------
// 5. RemoveFalsePlatformEntries
// ---------------------------------------------------------------------------

procedure RemoveFalsePlatformEntries(const ARoot: IXMLNode);
begin
  for var I := 0 to ARoot.ChildNodes.Count - 1 do
  begin
    var Child := ARoot.ChildNodes[I];
    if Child.NodeType <> ntElement then Continue;
    if SameText(Child.LocalName, 'Platforms') then
    begin
      var NodesToRemove := TList<IXMLNode>.Create;
      try
        for var J := 0 to Child.ChildNodes.Count - 1 do
        begin
          var PlatNode := Child.ChildNodes[J];
          if PlatNode.NodeType <> ntElement then Continue;
          if SameText(PlatNode.LocalName, 'Platform') and
             SameText(PlatNode.Text, 'False') then
            NodesToRemove.Add(PlatNode);
        end;
        for var Node in NodesToRemove do
          Child.ChildNodes.Remove(Node);
      finally
        NodesToRemove.Free;
      end;
    end;
    if Child.HasChildNodes then
      RemoveFalsePlatformEntries(Child);
  end;
end;

// ---------------------------------------------------------------------------
// 6. NormalizeActivePlatform
// ---------------------------------------------------------------------------

procedure NormalizeActivePlatform(const ARoot: IXMLNode;
  const ASupportedPlatforms: TStringList);
const
  CActivePlatformCondition = #39'$(Platform)'#39'=='#39#39;
var
  NewPlatform: string;
begin
  if ASupportedPlatforms.Count > 0 then
    NewPlatform := ASupportedPlatforms[0]
  else
    NewPlatform := 'Win32';

  for var I := 0 to ARoot.ChildNodes.Count - 1 do
  begin
    var PG := ARoot.ChildNodes[I];
    if PG.NodeType <> ntElement then Continue;
    if not SameText(PG.LocalName, 'PropertyGroup') then Continue;
    for var J := 0 to PG.ChildNodes.Count - 1 do
    begin
      var Child := PG.ChildNodes[J];
      if Child.NodeType <> ntElement then Continue;
      if not SameText(Child.LocalName, 'Platform') then Continue;
      var CondAttr := Child.AttributeNodes.FindNode('Condition');
      if Assigned(CondAttr) and (VarToStr(CondAttr.NodeValue) = CActivePlatformCondition) then
        Child.Text := NewPlatform;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// 7. CleanDeploymentSection
// ---------------------------------------------------------------------------

function IsDeployPlatformSupported(const APlatformNode: IXMLNode;
  const ASupportedPlatforms: TStringList): Boolean;
begin
  var NameAttr := APlatformNode.AttributeNodes.FindNode('Name');
  if not Assigned(NameAttr) then
    Exit(True); // node without Name attribute: keep for safety
  Result := ASupportedPlatforms.IndexOf(VarToStr(NameAttr.NodeValue)) >= 0;
end;

procedure RemovePlatformsFromDeployEntry(const AEntry: IXMLNode;
  const ASupportedPlatforms: TStringList);
var
  ToRemove: TList<IXMLNode>;
begin
  ToRemove := TList<IXMLNode>.Create;
  try
    for var I := 0 to AEntry.ChildNodes.Count - 1 do
    begin
      var Child := AEntry.ChildNodes[I];
      if Child.NodeType <> ntElement then Continue;
      if not SameText(Child.LocalName, 'Platform') then Continue;
      if not IsDeployPlatformSupported(Child, ASupportedPlatforms) then
        ToRemove.Add(Child);
    end;
    for var Node in ToRemove do
      AEntry.ChildNodes.Remove(Node);
  finally
    ToRemove.Free;
  end;
end;

function DeployEntryHasSupportedPlatform(const AEntry: IXMLNode;
  const ASupportedPlatforms: TStringList): Boolean;
begin
  for var I := 0 to AEntry.ChildNodes.Count - 1 do
  begin
    var Child := AEntry.ChildNodes[I];
    if Child.NodeType <> ntElement then Continue;
    if not SameText(Child.LocalName, 'Platform') then Continue;
    if IsDeployPlatformSupported(Child, ASupportedPlatforms) then
      Exit(True);
  end;
  Result := False;
end;

function IsProjectRootSupported(const AProjectRootNode: IXMLNode;
  const ASupportedPlatforms: TStringList): Boolean;
begin
  var PlatformAttr := AProjectRootNode.AttributeNodes.FindNode('Platform');
  if not Assigned(PlatformAttr) then
    Exit(True); // node without Platform attribute: keep for safety
  Result := ASupportedPlatforms.IndexOf(VarToStr(PlatformAttr.NodeValue)) >= 0;
end;

// Cleans the .dproj <Deployment> section from unsupported-platform data.
// Walks the known path directly:
//   Project > ProjectExtensions > BorlandProject > Deployment
procedure CleanDeploymentSection(const ADocumentElement: IXMLNode;
  const ASupportedPlatforms: TStringList);
var
  ProjExt, BorlandProj, Deployment: IXMLNode;
  EntriesToRemove: TList<IXMLNode>;
begin
  ProjExt     := FindChildByLocalName(ADocumentElement, 'ProjectExtensions');
  if not Assigned(ProjExt) then Exit;
  BorlandProj := FindChildByLocalName(ProjExt, 'BorlandProject');
  if not Assigned(BorlandProj) then Exit;
  Deployment  := FindChildByLocalName(BorlandProj, 'Deployment');
  if not Assigned(Deployment) then Exit;

  EntriesToRemove := TList<IXMLNode>.Create;
  try
    for var I := 0 to Deployment.ChildNodes.Count - 1 do
    begin
      var Entry := Deployment.ChildNodes[I];
      if Entry.NodeType <> ntElement then Continue;
      if SameText(Entry.LocalName, 'ProjectRoot') then
      begin
        if not IsProjectRootSupported(Entry, ASupportedPlatforms) then
          EntriesToRemove.Add(Entry);
        Continue;
      end;

      if SameText(Entry.LocalName, 'DeployFile') or
         SameText(Entry.LocalName, 'DeployClass') then
      begin
        RemovePlatformsFromDeployEntry(Entry, ASupportedPlatforms);
        if not DeployEntryHasSupportedPlatform(Entry, ASupportedPlatforms) then
          EntriesToRemove.Add(Entry);
      end;
    end;
    for var Node in EntriesToRemove do
      Deployment.ChildNodes.Remove(Node);
  finally
    EntriesToRemove.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

procedure SanitizeDprojDocument(const ADoc: IXMLDocument;
  const ASupportedPlatforms: TStringList);
var
  Root: IXMLNode;
begin
  Root := ADoc.DocumentElement;
  if not Assigned(Root) then Exit;
  if ASupportedPlatforms.Count > 0 then
    RemoveUnsupportedPlatformGroups(Root, ASupportedPlatforms);
  RemoveFalsePlatformEntries(Root);
  RemoveExcludedPackages(Root);
  if ASupportedPlatforms.Count > 0 then
    CleanDeploymentSection(Root, ASupportedPlatforms);
  ClearRunParams(Root);
  NormalizeActivePlatform(Root, ASupportedPlatforms);
end;

procedure SanitizeProjectFile(const AFileName: string);
var
  XMLDoc: IXMLDocument;
  SupportedPlatforms: TStringList;
  OriginalEncoding: string;
  PreviousDomVendor: DOMString;
begin
  if not TFile.Exists(AFileName) then Exit;
  try
    OriginalEncoding := DetectXmlEncodingFromFile(AFileName);
    PreviousDomVendor := DefaultDOMVendor;
    try
      DefaultDOMVendor := SMSXML;
      XMLDoc := TXMLDocument.Create(nil);
      XMLDoc.ParseOptions := [];
      XMLDoc.Options := XMLDoc.Options + [doNodeAutoIndent];
      XMLDoc.FileName := AFileName;
      XMLDoc.Active := True;
      SupportedPlatforms := TStringList.Create;
      try
        SupportedPlatforms.CaseSensitive := False;
        CollectSupportedPlatforms(XMLDoc.DocumentElement, SupportedPlatforms);
        SanitizeDprojDocument(XMLDoc, SupportedPlatforms);
        if OriginalEncoding <> '' then
          XMLDoc.Encoding := OriginalEncoding;
        XMLDoc.SaveToFile(AFileName);
      finally
        SupportedPlatforms.Free;
      end;
    finally
      DefaultDOMVendor := PreviousDomVendor;
    end;
  except
    // Do not let an I/O or XML error crash the IDE.
  end;
end;

end.
