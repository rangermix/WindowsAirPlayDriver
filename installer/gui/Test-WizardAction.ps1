[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureParent = Join-Path $repository '.local/diagnostics/gui-worker-tests'
$fixtureRoot = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
$worker = Join-Path $PSScriptRoot 'Invoke-WizardAction.ps1'
$cases = 0

function Assert-WizardFixture([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw $Description }
}

function New-WizardFixture([hashtable]$Changes = @{}) {
    $scenario = @{
        Elevated=$true; BadInputs=$false; PowerShell=$true; VcRuntime=$true
        TestMode=$true; SecureBoot=$false; SecureBootUnknown=$false; NoSecureBootCommand=$false
    }
    foreach ($key in $Changes.Keys) { $scenario[$key] = $Changes[$key] }
    $directory = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
    $installer = Join-Path $directory 'installer'
    $null = [IO.Directory]::CreateDirectory($installer)
    Set-Content -LiteralPath (Join-Path $installer 'exit.txt') -Value '0'
    $backend = @'
param(
    $ExpectedSignedManifestSha256, $ExpectedSignerThumbprint,
    [switch]$InstallDependencies, [switch]$EnableTestSigning,
    [switch]$AcknowledgeBootConfigurationChange, [switch]$AcknowledgeBitLockerRecoveryRisk,
    [switch]$TrustTestCertificate, [switch]$AcceptCleanReinstall, [switch]$ConfirmRemoval,
    [switch]$RemoveTestCertificate, [switch]$KeepTestCertificate,
    [switch]$DisableTestSigning, [switch]$KeepTestSigning,
    [switch]$AcknowledgeOtherTestDrivers, [switch]$NonInteractive
)
$PSBoundParameters | Export-Clixml -LiteralPath (Join-Path $PSScriptRoot 'forwarded.clixml')
exit ([int](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'exit.txt')))
'@
    foreach ($name in @('Start-Setup.ps1', 'Start-Uninstall.ps1')) {
        [IO.File]::WriteAllText((Join-Path $installer $name), $backend)
    }
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($worker,[ref]$tokens,[ref]$errors)
    Assert-WizardFixture ($errors.Count -eq 0) 'Wizard worker does not parse.'
    $functions = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst]
    } | ForEach-Object { $_.Extent.Text }) -join "`n"
    $module = New-Module -ScriptBlock {
        param($Functions,$Options)
        $script:Scenario=$Options
        $script:Events=[Collections.Generic.List[string]]::new()
        $script:Status=[Collections.Generic.List[string]]::new()
        . ([scriptblock]::Create($Functions))
        function Write-WinAirPlayWizardStatus { param($Message) $script:Status.Add($Message) }
        function Assert-WinAirPlaySetupPlatform { $script:Events.Add('Platform') }
        function Test-WinAirPlaySetupAdministrator { return $script:Scenario.Elevated }
        function Assert-WinAirPlaySetupNoLinks { param($Path) $script:Events.Add('NoLinks') }
        function Assert-WinAirPlaySetupInputs {
            param($BundleDirectory,$ExpectedSignedManifestSha256,$ExpectedSignerThumbprint)
            $script:Events.Add('Authenticate')
            if ($script:Scenario.BadInputs) { throw 'Fixture package authentication failed.' }
        }
        function Get-WinAirPlaySetupDependencyStatus {
            param([switch]$PowerShellOnly)
            $script:Events.Add('ReadDependencies')
            if ($PowerShellOnly) { $script:Events.Add('PowerShellOnly') }
            return [pscustomobject]@{ PowerShellInstalled=$script:Scenario.PowerShell;
                VcRuntimeInstalled=($script:Scenario.VcRuntime -and -not $PowerShellOnly) }
        }
        function Get-WinAirPlaySetupBootState {
            $script:Events.Add('ReadBoot')
            return [pscustomobject]@{ TestSigningActive=$script:Scenario.TestMode }
        }
        function Get-Command { param($Name,$ErrorAction) if (-not $script:Scenario.NoSecureBootCommand) { return $true } }
        function Confirm-SecureBootUEFI {
            param($ErrorAction)
            if ($script:Scenario.SecureBootUnknown) { throw 'Fixture Secure Boot cannot be queried.' }
            return $script:Scenario.SecureBoot
        }
        Export-ModuleMember -Function Invoke-WinAirPlayWizardAction
    } -ArgumentList $functions,$scenario
    return [pscustomobject]@{ Module=$module; Directory=$directory; Installer=$installer }
}

function Invoke-WizardCase {
    param([string]$Name,[hashtable]$Changes=@{},[hashtable]$Parameters=@{},[int]$Expected=0,[string]$ErrorText,
        [scriptblock]$Assert)
    $fixture=New-WizardFixture $Changes
    try {
        if ($Parameters.ContainsKey('BackendExit')) {
            Set-Content -LiteralPath (Join-Path $fixture.Installer 'exit.txt') -Value $Parameters.BackendExit
            $Parameters.Remove('BackendExit')
        }
        if ($Parameters.ContainsKey('BackendOutput')) {
            foreach ($backendName in @('Start-Setup.ps1', 'Start-Uninstall.ps1')) {
                $text = [IO.File]::ReadAllText((Join-Path $fixture.Installer $backendName))
                $text = $text.Replace('exit ([int]', "Write-Output 'Synthetic backend progress'; exit ([int]")
                [IO.File]::WriteAllText((Join-Path $fixture.Installer $backendName), $text)
            }
            $Parameters.Remove('BackendOutput')
        }
        $arguments=@{ InstallerDirectory=$fixture.Installer; Action='Probe'; Mode='Install';
            ExpectedSignedManifestSha256=('A' * 64); ExpectedSignerThumbprint=('B' * 40) }
        foreach ($key in $Parameters.Keys) { $arguments[$key]=$Parameters[$key] }
        $failure=$null; $actual=$null
        try { $actual = & $fixture.Module { param($Parameters) Invoke-WinAirPlayWizardAction @Parameters } $arguments }
        catch { $failure=$_ }
        if ($ErrorText) {
            Assert-WizardFixture ($failure -and $failure.Exception.Message -match $ErrorText) "$Name did not fail for the expected reason."
        } else {
            if ($failure) { throw $failure }
            Assert-WizardFixture ($actual -is [int] -and $actual -eq $Expected) "$Name returned an incorrect result: $actual"
        }
        $state=& $fixture.Module { [pscustomobject]@{Events=@($script:Events);Status=@($script:Status)} }
        $forwardPath=Join-Path $fixture.Installer 'forwarded.clixml'
        $forwarded=if(Test-Path -LiteralPath $forwardPath){Import-Clixml -LiteralPath $forwardPath}else{$null}
        if($Assert){ & $Assert $state $forwarded }
        $script:cases++
        Write-Host "PASS: $Name"
    } finally { Remove-Module -ModuleInfo $fixture.Module -ErrorAction SilentlyContinue }
}

try {
    Invoke-WizardCase 'install probe authenticates and emits machine state' -Assert {
        param($State,$Forwarded)
        Assert-WizardFixture ($State.Events -contains 'Authenticate' -and $null -eq $Forwarded) 'Probe invoked mutation or skipped input authentication.'
        foreach($line in @('POWER_SHELL=1','VC_RUNTIME=1','TEST_MODE=1','SECURE_BOOT=0')) {
            Assert-WizardFixture ($State.Status -contains $line) "Probe omitted $line"
        }
    }
    Invoke-WizardCase 'uninstall probe ignores damaged package' -Changes @{BadInputs=$true;VcRuntime=$false} `
        -Parameters @{Mode='Uninstall'} -Assert {
            param($State,$Forwarded)
            Assert-WizardFixture ($State.Events -notcontains 'Authenticate' -and $null -eq $Forwarded) 'Removal probe inspected incoming package or mutated state.'
            Assert-WizardFixture ($State.Events -contains 'PowerShellOnly' -and $State.Status -contains 'VC_RUNTIME=0') 'Removal probe still depends on VC runtime inspection.'
        }
    Invoke-WizardCase 'install probe fails on unauthenticated payload' -Changes @{BadInputs=$true} -ErrorText 'authentication failed'
    Invoke-WizardCase 'unknown Secure Boot remains explicit' -Changes @{SecureBootUnknown=$true} -Assert {
        param($State,$Forwarded) Assert-WizardFixture ($State.Status -contains 'SECURE_BOOT=unknown') 'Unavailable firmware state was presented as false.'
    }
    Invoke-WizardCase 'missing firmware cmdlet remains explicit' -Changes @{NoSecureBootCommand=$true} -Assert {
        param($State,$Forwarded) Assert-WizardFixture ($State.Status -contains 'SECURE_BOOT=unknown') 'Absent firmware query was presented as false.'
    }
    Invoke-WizardCase 'missing dependencies and inactive test mode reported' -Changes @{PowerShell=$false;VcRuntime=$false;TestMode=$false;SecureBoot=$true} -Assert {
        param($State,$Forwarded)
        foreach($line in @('POWER_SHELL=0','VC_RUNTIME=0','TEST_MODE=0','SECURE_BOOT=1')) {
            Assert-WizardFixture ($State.Status -contains $line) "Probe omitted $line"
        }
    }
    Invoke-WizardCase 'install forwards only explicitly selected consents' -Parameters @{Action='Install';InstallDependencies=$true;TrustTestCertificate=$true} -Assert {
        param($State,$Forwarded)
        Assert-WizardFixture ($Forwarded.NonInteractive -and $Forwarded.InstallDependencies -and $Forwarded.TrustTestCertificate) 'Selected GUI consent was not forwarded.'
        foreach($flag in @('EnableTestSigning','AcknowledgeBootConfigurationChange','AcknowledgeBitLockerRecoveryRisk','AcceptCleanReinstall')) {
            Assert-WizardFixture (-not $Forwarded[$flag]) "Unselected consent $flag was inferred."
        }
        Assert-WizardFixture (-not $Forwarded.ContainsKey('Pause')) 'GUI backend could prompt to pause.'
    }
    Invoke-WizardCase 'install forwards all explicit boot and reinstall acknowledgements' -Parameters @{
        Action='Install';EnableTestSigning=$true;AcknowledgeBootConfigurationChange=$true;
        AcknowledgeBitLockerRecoveryRisk=$true;AcceptCleanReinstall=$true
    } -Assert {
        param($State,$Forwarded)
        foreach($flag in @('EnableTestSigning','AcknowledgeBootConfigurationChange','AcknowledgeBitLockerRecoveryRisk','AcceptCleanReinstall')) {
            Assert-WizardFixture ([bool]$Forwarded[$flag]) "Selected consent $flag was lost."
        }
    }
    Invoke-WizardCase 'uninstall defaults keep trust and test mode without prompts' -Parameters @{Action='Uninstall';Mode='Uninstall';ConfirmRemoval=$true} -Assert {
        param($State,$Forwarded)
        Assert-WizardFixture ($Forwarded.ConfirmRemoval -and $Forwarded.KeepTestCertificate -and $Forwarded.KeepTestSigning -and $Forwarded.NonInteractive) 'Uninstall keep defaults or noninteractive guard were lost.'
        Assert-WizardFixture (-not $Forwarded.RemoveTestCertificate -and -not $Forwarded.DisableTestSigning) 'Uninstall inferred optional cleanup consent.'
    }
    Invoke-WizardCase 'uninstall explicit cleanup and policy acknowledgements forwarded' -Parameters @{
        Action='Uninstall';Mode='Uninstall';ConfirmRemoval=$true;RemoveTestCertificate=$true;DisableTestSigning=$true;
        AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true;AcknowledgeOtherTestDrivers=$true
    } -Assert {
        param($State,$Forwarded)
        foreach($flag in @('ConfirmRemoval','RemoveTestCertificate','DisableTestSigning','AcknowledgeBootConfigurationChange','AcknowledgeBitLockerRecoveryRisk','AcknowledgeOtherTestDrivers')) {
            Assert-WizardFixture ([bool]$Forwarded[$flag]) "Selected removal consent $flag was lost."
        }
        Assert-WizardFixture (-not $Forwarded.KeepTestCertificate -and -not $Forwarded.KeepTestSigning) 'Selected cleanup conflicts with keep defaults.'
    }
    foreach($code in @(0,1,3010)) {
        Invoke-WizardCase "backend exit $code preserved" -Parameters @{Action='Install';BackendExit=$code} -Expected $code
    }
    Invoke-WizardCase 'backend progress cannot contaminate numeric result' -Parameters @{Action='Install';BackendOutput=$true}
    Invoke-WizardCase 'unexpected backend exit is an error' -Parameters @{Action='Install';BackendExit=1641} -ErrorText 'unexpected exit code'
    Invoke-WizardCase 'mode action mismatch rejected' -Parameters @{Action='Uninstall';Mode='Install'} -ErrorText 'mode does not match'
    Invoke-WizardCase 'mutation requires existing elevation without secondary UAC' -Changes @{Elevated=$false} `
        -Parameters @{Action='Install'} -ErrorText 'administrator access' -Assert {
            param($State,$Forwarded) Assert-WizardFixture ($null -eq $Forwarded) 'Unprivileged GUI invoked backend mutation.'
        }
    Invoke-WizardCase 'nonabsolute bundle paths rejected' -Parameters @{BundleDirectory='relative/payload'} -ErrorText 'fully qualified'
    $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
    $escapedWorker=$worker.Replace("'","''")
    $parseCommand='$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile('''+$escapedWorker+''',[ref]$t,[ref]$e)|Out-Null;if($e.Count){$e;exit 1};exit 0'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parseCommand))
    & $windowsPowerShell -NoLogo -NoProfile -EncodedCommand $encoded
    Assert-WizardFixture ($LASTEXITCODE -eq 0) 'Native inbox PowerShell cannot parse the wizard worker.'
    $cases++
    Write-Host "Wizard worker checks passed ($cases cases); host-facing actions were mocked and synthetic backends only recorded parameters/exited."
} finally {
    $full=[IO.Path]::GetFullPath($fixtureRoot)
    if([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetFullPath($fixtureParent) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') { throw 'Refusing wizard fixture cleanup outside its exact local root.' }
    foreach($entry in @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Force -Recurse)) {
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Wizard fixture cleanup refuses reparse points.'}
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    Assert-WizardFixture (-not(Test-Path -LiteralPath $full)) 'Wizard fixture cleanup was incomplete.'
}
