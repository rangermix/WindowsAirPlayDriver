; Inno Setup is the UI shell. The existing PowerShell transactions own Windows state.
#ifndef PreviewOnly
  #define PreviewOnly 0
#endif
#ifndef PreviewOutcome
  #define PreviewOutcome 0
#endif
#if Int(PreviewOnly)
  #define PreviewLabel " - UI Preview"
#else
  #define PreviewLabel ""
#endif

[Setup]
AppId=WinAirPlayAudio.{#ActionName}.Wizard
AppName=WinAirPlayAudio {#ActionName}{#PreviewLabel}
AppVersion={#ProductVersion}
AppPublisher=WinAirPlayAudio contributors
VersionInfoVersion={#ProductFileVersion}
VersionInfoDescription=WinAirPlayAudio {#ActionName} wizard{#PreviewLabel}
DefaultDirName={autopf}\WinAirPlayAudio
CreateAppDir=no
Uninstallable=no
CreateUninstallRegKey=no
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.26100
#if Int(PreviewOnly)
PrivilegesRequired=lowest
#else
PrivilegesRequired=admin
#endif
DisableWelcomePage=no
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=no
DisableFinishedPage=no
WizardStyle=modern dynamic windows11
WizardSizePercent=125
CloseApplications=no
RestartApplications=no
AlwaysRestart=no
RestartIfNeededByRun=no
Compression=lzma2
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=WinAirPlayAudio-{#ProductVersion}-{#ActionName}
LicenseFile={#SourceRoot}\LICENSE

[Files]
#if Int(PreviewOnly) == 0
Source: "{#SourceRoot}\installer\Common.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Setup.Common.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Setup-Dependencies.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Set-TestSigning.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Remove-TestCertificate.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\gui\Invoke-WizardAction.ps1"; DestDir: "{tmp}\payload\installer\gui"; Flags: dontcopy
#if WizardInstall
Source: "{#SourceRoot}\installer\Start-Setup.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Setup.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Install-Driver.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
#if Int(PreviewOnly) == 0
Source: "{#BundleRoot}\package\*"; DestDir: "{tmp}\payload\package"; Flags: dontcopy
Source: "{#BundleRoot}\test-signing.cer"; DestDir: "{tmp}\payload"; Flags: dontcopy
#endif
#else
Source: "{#SourceRoot}\installer\Start-Uninstall.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Uninstall.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
Source: "{#SourceRoot}\installer\Uninstall.Common.ps1"; DestDir: "{tmp}\payload\installer"; Flags: dontcopy
#endif
#endif

[Messages]
ExitSetupTitle=Close Wizard
#if WizardInstall
ExitSetupMessage=Close this setup wizard?%n%nAny completed runtime or boot-policy changes will remain. You can run the wizard again to continue setup.
#else
ExitSetupMessage=Close this removal wizard?%n%nAny completed removal steps will remain. You can run the wizard again to finish cleanup.
#endif
#if !WizardInstall
ButtonInstall=&Remove
WizardReady=Ready to Remove
WizardInstalling=Removing
InstallingLabel=Please wait while the selected removal steps finish.
ReadyLabel1=The wizard is ready to remove WinAirPlayAudio.
ReadyLabel2a=Click Remove to continue, or Back to review your choices.
#endif

[Code]
var
  CheckPage, ConsentPage: TWizardPage;
  CheckText: TNewStaticText;
  ProgressPage: TOutputMarqueeProgressWizardPage;
  Details: TNewMemo;
  DependencyConsent, TestModeConsent, BootConsent, RecoveryConsent: TNewCheckBox;
  TrustConsent, RemovalConsent, OtherDriversConsent: TNewCheckBox;
  PayloadReady, ProbeOK, PowerShellReady, VcReady, TestModeActive, SecureBootOn: Boolean;
  Busy, ActionDone: Boolean;
  ActionResult: Integer;
  LastDetails: String;

function AddChoice(const Caption: String; const Top: Integer): TNewCheckBox;
begin
  Result := TNewCheckBox.Create(ConsentPage);
  Result.Parent := ConsentPage.Surface;
  Result.Left := 0;
  Result.Top := ScaleY(Top);
  Result.Width := ConsentPage.SurfaceWidth;
  Result.Height := ScaleY(38);
  Result.Caption := Caption;
  Result.Checked := False;
end;

procedure SetOptionalState(Sender: TObject);
begin
#if WizardInstall
  BootConsent.Enabled := not TestModeActive;
  RecoveryConsent.Enabled := not TestModeActive;
#else
  BootConsent.Enabled := TestModeConsent.Checked;
  RecoveryConsent.Enabled := TestModeConsent.Checked;
  OtherDriversConsent.Enabled := TestModeConsent.Checked;
#endif
end;

procedure EnsurePayload;
begin
  if not PayloadReady then begin
    ExtractTemporaryFiles('{tmp}\payload\*');
    PayloadReady := True;
  end;
end;

procedure ReceiveOutput(const S: String; const Error, FirstLine: Boolean);
var
  Display: String;
begin
  Log(S);
  if Error then begin
    LastDetails := LastDetails + #13#10 + 'Could not read further diagnostic output: ' + S;
    exit;
  end;
  if S = 'POWER_SHELL=1' then PowerShellReady := True;
  if S = 'VC_RUNTIME=1' then VcReady := True;
  if S = 'TEST_MODE=1' then TestModeActive := True;
  if S = 'SECURE_BOOT=1' then SecureBootOn := True;
  Display := S;
  if Pos('PHASE|', S) = 1 then begin
    Display := Copy(S, 7, Length(S));
    ProgressPage.SetText(Display, 'Please keep this window open until the operation finishes.');
  end;
  if Length(LastDetails) < 60000 then LastDetails := LastDetails + Display + #13#10;
  if Details.Lines.Count > 350 then Details.Lines.Delete(0);
  Details.Lines.Add(Display);
end;

#if Int(PreviewOnly) == 0
function Worker(const Action: String; var Code: Integer): Boolean;
var
  Parameters: String;
begin
  EnsurePayload;
  Parameters := '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{tmp}\payload\installer\gui\Invoke-WizardAction.ps1')) +
    ' -Action ' + Action + ' -Mode ' +
#if WizardInstall
    'Install' + ' -ExpectedSignedManifestSha256 {#ExpectedManifest}' +
#else
    'Uninstall' +
#endif
    ' -ExpectedSignerThumbprint {#ExpectedSigner} -BundleDirectory ' + AddQuotes(ExpandConstant('{tmp}\payload'));
  if Action <> 'Probe' then begin
#if WizardInstall
    if DependencyConsent.Checked then Parameters := Parameters + ' -InstallDependencies';
    if TestModeConsent.Checked then Parameters := Parameters + ' -EnableTestSigning';
    if TrustConsent.Checked then Parameters := Parameters + ' -TrustTestCertificate';
    if RemovalConsent.Checked then Parameters := Parameters + ' -AcceptCleanReinstall';
#else
    if RemovalConsent.Checked then Parameters := Parameters + ' -ConfirmRemoval';
    if TrustConsent.Checked then Parameters := Parameters + ' -RemoveTestCertificate';
    if TestModeConsent.Checked then Parameters := Parameters + ' -DisableTestSigning';
    if OtherDriversConsent.Checked then Parameters := Parameters + ' -AcknowledgeOtherTestDrivers';
#endif
    if BootConsent.Checked then Parameters := Parameters + ' -AcknowledgeBootConfigurationChange';
    if RecoveryConsent.Checked then Parameters := Parameters + ' -AcknowledgeBitLockerRecoveryRisk';
  end;
  Result := ExecAndLogOutputWithNativeSysDir(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Parameters,
    ExpandConstant('{tmp}\payload'), SW_SHOWNORMAL, ewWaitUntilTerminated, Code, @ReceiveOutput);
end;
#endif

function RefreshChecks: Boolean;
var
  Code: Integer;
  Summary: String;
begin
  PowerShellReady := False;
  VcReady := False;
  TestModeActive := False;
  SecureBootOn := False;
  LastDetails := '';
  Details.Clear;
  Busy := True;
  ProgressPage.SetText('Checking Windows and runtime requirements', 'This check does not install or change anything.');
  ProgressPage.Show;
  try
#if Int(PreviewOnly)
    PowerShellReady := True;
    VcReady := True;
    TestModeActive := False;
    Result := True;
    Summary := 'UI PREVIEW - example check results. No checks or machine changes will be executed.';
#else
    Result := Worker('Probe', Code) and (Code = 0);
    Summary := 'Windows 11 x64 compatibility and the supplied package have been checked.';
#endif
    if not Result then Summary := 'The requirements check could not finish.' + #13#10 + LastDetails
    else begin
      if PowerShellReady then Summary := Summary + #13#10#13#10 + 'PowerShell runtime: ready'
      else Summary := Summary + #13#10#13#10 + 'PowerShell runtime: missing or needs an update';
#if WizardInstall
      if VcReady then Summary := Summary + #13#10 + 'Visual C++ x64 runtime: ready'
      else Summary := Summary + #13#10 + 'Visual C++ x64 runtime: missing or needs an update';
#endif
      if TestModeActive then Summary := Summary + #13#10 + 'Windows test mode: active'
      else Summary := Summary + #13#10 + 'Windows test mode: inactive in this boot';
#if WizardInstall
      if SecureBootOn and not TestModeActive then begin
        Summary := Summary + #13#10#13#10 + 'Secure Boot blocks test-mode preparation. Review firmware settings and BitLocker recovery access before running setup again.';
        Result := False;
      end;
#else
      if not PowerShellReady then begin
        Summary := Summary + #13#10#13#10 + 'Restore the supported PowerShell runtime before removing the product. This wizard does not install prerequisites.';
        Result := False;
      end;
#endif
    end;
    CheckText.Caption := Summary;
    ProbeOK := Result;
#if WizardInstall
    DependencyConsent.Enabled := not (PowerShellReady and VcReady);
    TestModeConsent.Enabled := not TestModeActive;
#endif
    SetOptionalState(nil);
  finally
    ProgressPage.Hide;
    Busy := False;
  end;
end;

function ConsentsValid: Boolean;
begin
  Result := RemovalConsent.Checked;
#if WizardInstall
  Result := Result and TrustConsent.Checked;
  if not (PowerShellReady and VcReady) then Result := Result and DependencyConsent.Checked;
  if not TestModeActive then Result := Result and TestModeConsent.Checked and BootConsent.Checked and RecoveryConsent.Checked;
#else
  if TestModeConsent.Checked then Result := Result and OtherDriversConsent.Checked and BootConsent.Checked and RecoveryConsent.Checked;
#endif
end;

procedure InitializeWizard;
begin
  ActionResult := -1;
  WizardForm.ReadyMemo.WordWrap := True;
  WizardForm.ReadyMemo.ScrollBars := ssVertical;
  WizardForm.WelcomeLabel1.Caption := 'WinAirPlayAudio {#ActionName}{#PreviewLabel}';
#if WizardInstall
  WizardForm.WelcomeLabel2.Caption := 'Set up the virtual audio driver and service for compatible classic AirPlay receivers.' + #13#10#13#10 +
    'The wizard checks this PC, prepares missing runtimes and guides test-mode setup before installing the verified driver.' + #13#10#13#10 +
    'This is an experimental test-signed build. AirPlay 2 is not supported. Use a test PC with recovery access.';
#else
  WizardForm.WelcomeLabel2.Caption := 'Remove the virtual audio driver, service and their installed data.' + #13#10#13#10 +
    'After verified removal, you may remove public certificate trust and exit Windows test mode.' + #13#10#13#10 +
    'Shared Microsoft runtimes and private signing keys are retained.';
#endif
#if Int(PreviewOnly)
  WizardForm.WelcomeLabel2.Caption := 'UI PREVIEW ONLY. All actions are simulated. No dependencies, driver, files, certificate trust or boot policy will be changed.' + #13#10#13#10 + WizardForm.WelcomeLabel2.Caption;
#endif
#if WizardInstall
  CheckPage := CreateCustomPage(wpLicense, 'Check this PC', 'Review requirements before continuing');
#else
  CheckPage := CreateCustomPage(wpWelcome, 'Check this PC', 'Review requirements before continuing');
#endif
  CheckText := TNewStaticText.Create(CheckPage);
  CheckText.Parent := CheckPage.Surface;
  CheckText.SetBounds(0, 0, CheckPage.SurfaceWidth, CheckPage.SurfaceHeight);
  CheckText.AutoSize := False;
  CheckText.WordWrap := True;
  ConsentPage := CreateCustomPage(CheckPage.ID, 'Review changes', 'Select and acknowledge the changes you approve');
#if WizardInstall
  DependencyConsent := AddChoice('Install or update missing Microsoft PowerShell and Visual C++ runtimes.', 0);
  TestModeConsent := AddChoice('Enable Windows test mode if needed for this test-signed driver.', 40);
  BootConsent := AddChoice('I approve changing the Windows boot entry for test-mode preparation.', 80);
  RecoveryConsent := AddChoice('I have recovery access and my BitLocker recovery key before boot changes.', 120);
  TrustConsent := AddChoice('Trust the verified public test certificate on this PC.', 160);
  RemovalConsent := AddChoice('Clean reinstall: remove old product settings, credentials and logs.', 200);
#else
  RemovalConsent := AddChoice('Permanently remove WinAirPlayAudio and its settings, credentials and logs.', 0);
  TrustConsent := AddChoice('After removal, remove this product''s dedicated public certificate trust.', 40);
  TestModeConsent := AddChoice('After removal, exit Windows test mode. A manual restart will be required.', 80);
  OtherDriversConsent := AddChoice('No other installed test-signed driver still needs Windows test mode.', 120);
  BootConsent := AddChoice('I approve changing the Windows boot entry to disable test mode.', 160);
  RecoveryConsent := AddChoice('I have recovery access and my BitLocker recovery key before boot changes.', 200);
  TestModeConsent.OnClick := @SetOptionalState;
#endif
  ProgressPage := CreateOutputMarqueeProgressPage('Working', 'Applying your selected changes');
  Details := TNewMemo.Create(ProgressPage);
  Details.Parent := ProgressPage.Surface;
  Details.SetBounds(0, ScaleY(88), ProgressPage.SurfaceWidth, ProgressPage.SurfaceHeight - ScaleY(88));
  Details.ReadOnly := True;
  Details.ScrollBars := ssVertical;
  Details.WordWrap := True;
  SetOptionalState(nil);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  { Hiding the progress page re-enters this page synchronously. }
  if (CurPageID = CheckPage.ID) and not Busy then RefreshChecks;
  if CurPageID = wpFinished then begin
    WizardForm.FinishedLabel.AutoSize := False;
    WizardForm.FinishedLabel.WordWrap := True;
    WizardForm.FinishedLabel.Height := WizardForm.FinishedPage.Height - WizardForm.FinishedLabel.Top - ScaleY(12);
    WizardForm.FinishedHeadingLabel.Caption := 'WinAirPlayAudio {#ActionName} complete';
    if ActionResult = 3010 then begin
      WizardForm.FinishedHeadingLabel.Caption := 'Restart Windows manually';
#if WizardInstall
      WizardForm.FinishedLabel.Caption := 'A runtime or test-mode preparation step requires a restart. The driver installation has not completed.' + #13#10#13#10 + 'Save your work, restart Windows, then run this setup wizard again. Nothing will restart automatically.';
#else
      WizardForm.FinishedLabel.Caption := 'Product removal and your selected changes completed. Restart Windows manually to apply the test-mode change. Nothing will restart automatically.';
#endif
    end else begin
#if WizardInstall
      WizardForm.FinishedLabel.Caption := 'The driver package, running service and scoped firewall rule have been verified.' + #13#10#13#10 + 'Use the companion Uninstall wizard when you want to remove the product. Receiver playback still needs separate validation.';
#else
      WizardForm.FinishedLabel.Caption := 'The product is verified removed and your selected cleanup completed. Shared Microsoft runtimes, private keys and retained download archives remain.';
#endif
    end;
#if Int(PreviewOnly)
    WizardForm.FinishedHeadingLabel.Caption := 'UI preview finished';
    WizardForm.FinishedLabel.Caption := 'SIMULATION ONLY - no machine changes occurred.' + #13#10#13#10 + WizardForm.FinishedLabel.Caption;
#endif
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfoInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
#if WizardInstall
  Result := 'Prepare dependencies and test mode as approved, then install the verified driver, service and firewall rule.' + NewLine + NewLine + 'Any prerequisite restart stops before driver installation. Restart manually and rerun the wizard.';
#else
  Result := 'Remove and verify all product components before performing any optional certificate or test-mode cleanup.';
  if TrustConsent.Checked then Result := Result + NewLine + NewLine + 'Remove dedicated public test-certificate trust.';
  if TestModeConsent.Checked then Result := Result + NewLine + NewLine + 'Disable test mode after verified removal. Restart Windows manually afterwards.'
  else Result := Result + NewLine + NewLine + 'Keep Windows test-mode policy unchanged.';
#endif
#if Int(PreviewOnly)
  Result := 'UI PREVIEW - ALL ACTIONS SIMULATED.' + NewLine + NewLine + Result;
#endif
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Launched: Boolean;
begin
  Result := True;
  if (CurPageID = CheckPage.ID) and not ProbeOK then begin
    MsgBox('The requirements check must pass before continuing. Review the check results and run the wizard again after correcting the problem.', mbError, MB_OK);
    Result := False;
  end;
  if (CurPageID = ConsentPage.ID) and not ConsentsValid then begin
    MsgBox('Please explicitly approve each required change. Test-mode changes also require recovery and other-driver acknowledgements when applicable.', mbInformation, MB_OK);
    Result := False;
  end;
  if (CurPageID <> wpReady) or ActionDone then exit;
  LastDetails := '';
  Details.Clear;
  Busy := True;
  ProgressPage.SetText('Applying approved changes', 'Please keep this window open until the operation finishes.');
  ProgressPage.Show;
  ProgressPage.Animate;
  try
    try
#if Int(PreviewOnly)
    ReceiveOutput('UI PREVIEW: checking the example package and selected choices.', False, True);
    ReceiveOutput('UI PREVIEW: all Windows operations are simulated.', False, False);
    ActionResult := {#PreviewOutcome};
    Launched := True;
#else
#if WizardInstall
    Launched := Worker('Install', ActionResult);
#else
    Launched := Worker('Uninstall', ActionResult);
#endif
#endif
    ActionDone := Launched and ((ActionResult = 0) or (ActionResult = 3010));
    except
      LastDetails := LastDetails + #13#10 + GetExceptionMessage;
      ActionDone := False;
    end;
  finally
    ProgressPage.Hide;
    Busy := False;
  end;
  if not ActionDone then begin
    MsgBox('The operation could not complete. Review the diagnostic output below. No successful completion is being reported.' + #13#10#13#10 + Copy(LastDetails, 1, 1400), mbError, MB_OK);
    WizardForm.ReadyMemo.Text := 'Operation failed. Correct the reported problem, then retry or close this wizard.' + #13#10#13#10 + LastDetails;
    WizardForm.NextButton.Caption := '&Retry';
    Result := False;
  end;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if Busy then begin Cancel := False; Confirm := False; end;
end;

function InitializeSetup: Boolean;
begin
  Result := not WizardSilent;
  if not Result then MsgBox('This GUI wizard requires attended review. Use the documented PowerShell entry points for unattended operation.', mbError, MB_OK);
end;

function NeedRestart: Boolean;
begin
  Result := False; { Never request or trigger an automatic reboot. }
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if ActionDone and (ActionResult = 3010) then Result := 3010;
end;
