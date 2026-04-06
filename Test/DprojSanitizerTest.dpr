program DprojSanitizerTest;

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
  untDprojSanitizer in '..\untDprojSanitizer.pas';

var
  GPassCount: Integer;
  GFailCount: Integer;

procedure Check(const ATestName: string; const ACondition: Boolean);
begin
  if ACondition then begin
    WriteLn('  PASS: ', ATestName);
    Inc(GPassCount);
  end else begin
    WriteLn('  FAIL: ', ATestName);
    Inc(GFailCount);
  end;
end;

function FindChild(const AParent: IXMLNode; const ALocalName: string): IXMLNode;
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

function FindChildByAttr(const AParent: IXMLNode; const AElemName, AAttrName, AAttrValue: string): IXMLNode;
begin
  Result := nil;
  if not Assigned(AParent) then
    Exit;
  for var I := 0 to AParent.ChildNodes.Count - 1 do
  begin
    var Child := AParent.ChildNodes[I];
    if (Child.NodeType <> ntElement) or not SameText(Child.LocalName, AElemName) then
      Continue;
    if Child.HasAttribute(AAttrName) and SameText(VarToStr(Child.Attributes[AAttrName]), AAttrValue) then
      Exit(Child);
  end;
end;

function CountPlatformChildren(const ANode: IXMLNode): Integer;
begin
  Result := 0;
  if not Assigned(ANode) then
    Exit;
  for var I := 0 to ANode.ChildNodes.Count - 1 do
  begin
    var Child := ANode.ChildNodes[I];
    if (Child.NodeType = ntElement) and SameText(Child.LocalName, 'Platform') then
      Inc(Result);
  end;
end;

function FindProjectRootByPlatform(const ADeployment: IXMLNode;
  const APlatform: string): IXMLNode;
begin
  Result := nil;
  if not Assigned(ADeployment) then
    Exit;
  for var I := 0 to ADeployment.ChildNodes.Count - 1 do
  begin
    var Child := ADeployment.ChildNodes[I];
    if (Child.NodeType <> ntElement) or not SameText(Child.LocalName, 'ProjectRoot') then
      Continue;
    if Child.HasAttribute('Platform') and
       SameText(VarToStr(Child.Attributes['Platform']), APlatform) then
      Exit(Child);
  end;
end;

function NodeExistsAnywhere(const ANode: IXMLNode; const ALocalName: string): Boolean;
begin
  if not Assigned(ANode) then
    Exit(False);
  for var I := 0 to ANode.ChildNodes.Count - 1 do
  begin
    var Child := ANode.ChildNodes[I];
    if Child.NodeType <> ntElement then
      Continue;
    if SameText(Child.LocalName, ALocalName) then
      Exit(True);
    if NodeExistsAnywhere(Child, ALocalName) then
      Exit(True);
  end;
  Result := False;
end;

// ---------------------------------------------------------------------------
// Test sections
// ---------------------------------------------------------------------------

procedure TestPlatformsSection(const ARoot: IXMLNode);
begin
  WriteLn;
  WriteLn('=== Platforms section ===');
  var ProjExt   := FindChild(ARoot, 'ProjectExtensions');
  var BorProj   := FindChild(ProjExt, 'BorlandProject');
  var Platforms := FindChild(BorProj, 'Platforms');
  Check('Platforms node exists', Assigned(Platforms));
  if not Assigned(Platforms) then
    Exit;
  Check('Win32 exists',  Assigned(FindChildByAttr(Platforms, 'Platform', 'value', 'Win32')));
  Check('Win64 exists',  Assigned(FindChildByAttr(Platforms, 'Platform', 'value', 'Win64')));
  Check('Linux64 removed', not Assigned(FindChildByAttr(Platforms, 'Platform', 'value', 'Linux64')));
  Check('Win64x removed',  not Assigned(FindChildByAttr(Platforms, 'Platform', 'value', 'Win64x')));
end;

procedure TestPropertyGroups(const ARoot: IXMLNode);
var
  Win32BaseFound, Win64BaseFound: Boolean;
begin
  WriteLn;
  WriteLn('=== Platform base PropertyGroup ===');
  Win32BaseFound := False;
  Win64BaseFound := False;
  for var I := 0 to ARoot.ChildNodes.Count - 1 do
  begin
    var PG := ARoot.ChildNodes[I];
    if (PG.NodeType <> ntElement) or not SameText(PG.LocalName, 'PropertyGroup') then
      Continue;
    var CondAttr := PG.AttributeNodes.FindNode('Condition');
    if not Assigned(CondAttr) then
      Continue;
    var Cond := VarToStr(CondAttr.NodeValue);
    if Cond.Contains('''$(Platform)''==''Win32''') and Cond.Contains('''$(Base)''==''true''') then
      Win32BaseFound := True;
    if Cond.Contains('''$(Platform)''==''Win64''') and Cond.Contains('''$(Base)''==''true''') then
      Win64BaseFound := True;
  end;
  Check('Win32 base PropertyGroup preserved', Win32BaseFound);
  Check('Win64 base PropertyGroup preserved', Win64BaseFound);
end;

procedure TestExcludedPackages(const ARoot: IXMLNode);
begin
  WriteLn;
  WriteLn('=== Excluded_Packages ===');
  Check('Excluded_Packages node removed', not NodeExistsAnywhere(ARoot, 'Excluded_Packages'));
end;

procedure TestDeployFiles(const ADeployment: IXMLNode);
begin
  WriteLn;
  WriteLn('--- DeployFile ---');
  Check('iossimulator/libcgunwind removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployFile', 'LocalName',
      '$(BDS)\Redist\iossimulator\libcgunwind.1.0.dylib')));
  Check('iossimulator/libpcre removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployFile', 'LocalName',
      '$(BDS)\Redist\iossimulator\libpcre.dylib')));
  Check('osx32/libcgunwind removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployFile', 'LocalName',
      '$(BDS)\Redist\osx32\libcgunwind.1.0.dylib')));
  Check('ProjectOutput Win32 preserved',
    Assigned(FindChildByAttr(ADeployment, 'DeployFile', 'Class', 'ProjectOutput')));
end;

procedure TestDeployClassRemovals(const ADeployment: IXMLNode);
begin
  WriteLn;
  WriteLn('--- DeployClass (removed: unsupported platforms only) ---');
  Check('AndroidFileProvider removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'AndroidFileProvider')));
  Check('AndroidLibnativeArmeabiFile removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'AndroidLibnativeArmeabiFile')));
  Check('ProjectAndroidManifest removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'ProjectAndroidManifest')));
  Check('ProjectiOSDeviceDebug removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'ProjectiOSDeviceDebug')));
  Check('ProjectiOSResource removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'ProjectiOSResource')));
  Check('ProjectOSXResource removed',
    not Assigned(FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'ProjectOSXResource')));
end;

procedure TestDeployClassPruned(const ADeployment: IXMLNode);
begin
  WriteLn;
  WriteLn('--- DeployClass (preserved, unsupported platforms removed) ---');

  var AdditionalDbg := FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'AdditionalDebugSymbols');
  Check('AdditionalDebugSymbols exists', Assigned(AdditionalDbg));
  if Assigned(AdditionalDbg) then begin
    Check('AdditionalDebugSymbols: 1 Platform remains',  CountPlatformChildren(AdditionalDbg) = 1);
    Check('AdditionalDebugSymbols: Win32 exists',      Assigned(FindChildByAttr(AdditionalDbg, 'Platform', 'Name', 'Win32')));
    Check('AdditionalDebugSymbols: OSX32 removed',       not Assigned(FindChildByAttr(AdditionalDbg, 'Platform', 'Name', 'OSX32')));
  end;

  var DebugSym := FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'DebugSymbols');
  Check('DebugSymbols exists', Assigned(DebugSym));
  if Assigned(DebugSym) then begin
    Check('DebugSymbols: 1 Platform remains',      CountPlatformChildren(DebugSym) = 1);
    Check('DebugSymbols: Win32 exists',          Assigned(FindChildByAttr(DebugSym, 'Platform', 'Name', 'Win32')));
    Check('DebugSymbols: iOSSimulator removed',    not Assigned(FindChildByAttr(DebugSym, 'Platform', 'Name', 'iOSSimulator')));
    Check('DebugSymbols: OSX32 removed',           not Assigned(FindChildByAttr(DebugSym, 'Platform', 'Name', 'OSX32')));
  end;

  var DepMod := FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'DependencyModule');
  Check('DependencyModule exists', Assigned(DepMod));
  if Assigned(DepMod) then begin
    Check('DependencyModule: 1 Platform remains', CountPlatformChildren(DepMod) = 1);
    Check('DependencyModule: Win32 exists',     Assigned(FindChildByAttr(DepMod, 'Platform', 'Name', 'Win32')));
    Check('DependencyModule: OSX32 removed',      not Assigned(FindChildByAttr(DepMod, 'Platform', 'Name', 'OSX32')));
  end;

  var UWPManifest := FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'ProjectUWPManifest');
  Check('ProjectUWPManifest exists', Assigned(UWPManifest));
  if Assigned(UWPManifest) then begin
    Check('ProjectUWPManifest: 2 Platforms remain',  CountPlatformChildren(UWPManifest) = 2);
    Check('ProjectUWPManifest: Win32 exists',      Assigned(FindChildByAttr(UWPManifest, 'Platform', 'Name', 'Win32')));
    Check('ProjectUWPManifest: Win64 exists',      Assigned(FindChildByAttr(UWPManifest, 'Platform', 'Name', 'Win64')));
    Check('ProjectUWPManifest: Win64x removed',      not Assigned(FindChildByAttr(UWPManifest, 'Platform', 'Name', 'Win64x')));
  end;

  var Logo150 := FindChildByAttr(ADeployment, 'DeployClass', 'Name', 'UWP_DelphiLogo150');
  Check('UWP_DelphiLogo150 exists', Assigned(Logo150));
  if Assigned(Logo150) then begin
    Check('UWP_DelphiLogo150: 2 Platforms exist', CountPlatformChildren(Logo150) = 2);
    Check('UWP_DelphiLogo150: Win32 exists',      Assigned(FindChildByAttr(Logo150, 'Platform', 'Name', 'Win32')));
    Check('UWP_DelphiLogo150: Win64 exists',      Assigned(FindChildByAttr(Logo150, 'Platform', 'Name', 'Win64')));
  end;
end;

procedure TestProjectRootCleanup(const ADeployment: IXMLNode);
begin
  WriteLn;
  WriteLn('--- ProjectRoot ---');
  Check('ProjectRoot Win32 preserved', Assigned(FindProjectRootByPlatform(ADeployment, 'Win32')));
  Check('ProjectRoot Win64 preserved', Assigned(FindProjectRootByPlatform(ADeployment, 'Win64')));
  Check('ProjectRoot Win64x removed', not Assigned(FindProjectRootByPlatform(ADeployment, 'Win64x')));
  Check('ProjectRoot Android removed', not Assigned(FindProjectRootByPlatform(ADeployment, 'Android')));
  Check('ProjectRoot Android64 removed', not Assigned(FindProjectRootByPlatform(ADeployment, 'Android64')));
  Check('ProjectRoot Linux64 removed', not Assigned(FindProjectRootByPlatform(ADeployment, 'Linux64')));
  Check('ProjectRoot OSX32 removed', not Assigned(FindProjectRootByPlatform(ADeployment, 'OSX32')));
  Check('ProjectRoot iOSDevice64 removed', not Assigned(FindProjectRootByPlatform(ADeployment, 'iOSDevice64')));
end;

procedure TestDeployment(const ARoot: IXMLNode);
begin
  WriteLn;
  WriteLn('=== Deployment section ===');
  var ProjExt    := FindChild(ARoot, 'ProjectExtensions');
  var BorProj    := FindChild(ProjExt, 'BorlandProject');
  var Deployment := FindChild(BorProj, 'Deployment');
  Check('Deployment node exists', Assigned(Deployment));
  if not Assigned(Deployment) then
    Exit;
  TestDeployFiles(Deployment);
  TestDeployClassRemovals(Deployment);
  TestDeployClassPruned(Deployment);
  TestProjectRootCleanup(Deployment);
end;

procedure TestActivePlatform(const ARoot: IXMLNode);
begin
  WriteLn;
  WriteLn('=== Active platform ===');
  const CCondition = #39'$(Platform)'#39'=='#39#39;
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
      if Assigned(CondAttr) and (VarToStr(CondAttr.NodeValue) = CCondition) then
        Check('Active platform = Win32', SameText(Child.Text, 'Win32'));
    end;
  end;
end;

// ---------------------------------------------------------------------------

function LoadAndSanitize(const AFileName: string): IXMLDocument;
var
  SupportedPlatforms: TStringList;
begin
  Result := TXMLDocument.Create(nil);
  Result.ParseOptions := [poPreserveWhiteSpace];
  Result.FileName := AFileName;
  DefaultDOMVendor := SMSXML;
  Result.Active := True;
  SupportedPlatforms := TStringList.Create;
  try
    SupportedPlatforms.CaseSensitive := False;
    CollectSupportedPlatforms(Result.DocumentElement, SupportedPlatforms);
    WriteLn('Supported platforms: ', SupportedPlatforms.CommaText);
    SanitizeDprojDocument(Result, SupportedPlatforms);
    Result.SaveToFile(AFileName);
  finally
    SupportedPlatforms.Free;
  end;
end;

begin
  CoInitialize(nil);
  try
    var OriginalFile := TPath.Combine(ExtractFilePath(ParamStr(0)), 'Original.dproj');
    var WorkFile     := TPath.Combine(TPath.GetTempPath, 'DprojSanitizerTest_Working.dproj');
    TFile.Copy(OriginalFile, WorkFile, True);
    WriteLn('Input:        ', OriginalFile);
    WriteLn('Working copy: ', WorkFile);

    var Doc := LoadAndSanitize(WorkFile);
    var Root := Doc.DocumentElement;

    TestPlatformsSection(Root);
    TestPropertyGroups(Root);
    TestExcludedPackages(Root);
    TestDeployment(Root);
    TestActivePlatform(Root);

    WriteLn;
    WriteLn(Format('=== Result: %d PASS, %d FAIL ===', [GPassCount, GFailCount]));
    if GFailCount > 0 then
      ExitCode := 1;
  except
    on E: Exception do begin
      WriteLn('FATAL ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
  CoUninitialize;
end.
