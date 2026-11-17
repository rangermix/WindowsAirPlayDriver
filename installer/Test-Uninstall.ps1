[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$fixtureParent = Join-Path $repository '.local/diagnostics/uninstall-tests'
$fixtureRoot = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
$cases = 0

function Assert-UninstallFixture([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-UninstallAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-UninstallFixture ($errors.Count -eq 0) "Uninstaller script does not parse: $Path"
    return $ast
}

function Get-UninstallFunctions([string]$Path) {
    $ast = Get-UninstallAst $Path
    return (@($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst]
    } | ForEach-Object { $_.Extent.Text }) -join "`n")
}

function Remove-UninstallFixtureRoot {
    $full = [IO.Path]::GetFullPath($fixtureRoot)
    if ([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetFullPath($fixtureParent) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Refusing test cleanup outside the exact local fixture scope.'
    }
    if (Test-Path -LiteralPath $full) {
        foreach ($entry in @(Get-Item -LiteralPath $full -Force) +
            @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Refusing to clean a fixture containing reparse points.'
            }
        }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
    Assert-UninstallFixture (-not (Test-Path -LiteralPath $full)) 'Uninstall fixture cleanup was incomplete.'
}

function New-UninstallFixtureModule {
    param([string]$Entry, [hashtable]$Scenario)
    $directory = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
    $installer = Join-Path $directory 'installer'
    $null = [IO.Directory]::CreateDirectory($installer)
    foreach ($name in @('Common.ps1', 'Uninstall.Common.ps1', 'Setup.Common.ps1',
            'Setup-Dependencies.ps1', 'Uninstall.ps1', 'Start-Uninstall.ps1')) {
        [IO.File]::WriteAllText((Join-Path $installer $name), '# Synthetic file; never dot-sourced.')
    }
    [IO.File]::WriteAllText((Join-Path $installer 'Remove-TestCertificate.ps1'), @'
[CmdletBinding(SupportsShouldProcess)]
param($CertificateThumbprint, [switch]$ConfirmRemoval)
Invoke-FixtureCertificateRemoval $CertificateThumbprint
'@)
    [IO.File]::WriteAllText((Join-Path $installer 'Set-TestSigning.ps1'), @'
[CmdletBinding(SupportsShouldProcess)]
param($Mode, [switch]$AcknowledgeBootConfigurationChange, [switch]$AcknowledgeBitLockerRecoveryRisk)
if ($Mode -cne 'Disable' -or -not $AcknowledgeBootConfigurationChange -or -not $AcknowledgeBitLockerRecoveryRisk) {
    throw 'Fixture received an unsafe boot-policy invocation.'
}
Invoke-FixtureBootChange
'@)
    $state = Join-Path $directory 'state'
    $null = [IO.Directory]::CreateDirectory($state)
    if ($Scenario.HasState) {
        [IO.File]::WriteAllText((Join-Path $state 'driver-install.json'), '{}')
    }
    $code = Get-UninstallFunctions (Join-Path $PSScriptRoot 'Uninstall.Common.ps1')
    $code = $code.Replace("'Global\WinAirPlayAudio.Setup'",
        ("'Local\WinAirPlayAudio.Uninstall.Fixture." + [Guid]::NewGuid().ToString('N') + "'"))
    if ($Entry -cne 'Common') {
        $ast = Get-UninstallAst (Join-Path $PSScriptRoot $Entry)
        $statements = @($ast.EndBlock.Statements | Where-Object {
            $_ -isnot [Management.Automation.Language.ExitStatementAst] -and
            $_.Extent.Text -notmatch '^\.\s'
        } | ForEach-Object { $_.Extent.Text })
        $result = '$resultCode'
        $entryCode = '[CmdletBinding(SupportsShouldProcess)]' + "`n" + $ast.ParamBlock.Extent.Text + "`n" +
            '$PSScriptRoot = $script:FixtureInstaller; $PSCommandPath = Join-Path $PSScriptRoot ''' + $Entry + "'`n" +
            ($statements -join "`n") + "`nreturn $result"
        $entryCode = $entryCode.Replace("'Global\WinAirPlayAudio.Setup'",
            ("'Local\WinAirPlayAudio.Uninstall.Fixture." + [Guid]::NewGuid().ToString('N') + "'"))
    } else { $entryCode = $null }
    $setupFunctions = Get-UninstallFunctions (Join-Path $PSScriptRoot 'Setup.Common.ps1')
    $module = New-Module -ScriptBlock {
        param($Helpers, $SetupHelpers, $EntryCode, $Directory, $Options)
        Set-StrictMode -Version Latest
        $script:FixtureDirectory = $Directory
        $script:FixtureInstaller = Join-Path $Directory 'installer'
        $script:PSScriptRoot = $script:FixtureInstaller
        $script:WinAirPlayStateDirectory = Join-Path $Directory 'state'
        $script:WinAirPlayStateFile = Join-Path $script:WinAirPlayStateDirectory 'driver-install.json'
        $script:WinAirPlayInstallDirectory = Join-Path $Directory 'runtime'
        $script:Scenario = $Options
        $script:Events = [Collections.Generic.List[string]]::new()
        . ([scriptblock]::Create($SetupHelpers))
        . ([scriptblock]::Create($Helpers))
        function Assert-WinAirPlaySetupPlatform { $script:Events.Add('Platform') }
        function Assert-WinAirPlayTarget { $script:Events.Add('Platform') }
        function Assert-WinAirPlayAdministrator { $script:Events.Add('Administrator') }
        function Test-WinAirPlaySetupAdministrator { return $script:Scenario.Elevated }
        function Assert-WinAirPlayTrustedDirectory {
            param($Path, [switch]$RequireProtectedDacl)
            $script:Events.Add('ValidateDirectory')
        }
        function Assert-WinAirPlayStateTree { $script:Events.Add('ValidateStateTree') }
        function Assert-WinAirPlayInstallStateRecord {
            param($Path, [switch]$PassThru)
            $script:Events.Add('ReadState')
            if ($script:Scenario.MalformedState) { throw 'Fixture malformed install-state record.' }
            if ($PassThru) {
                return [pscustomobject]@{
                    CatalogSignerThumbprint = $script:Scenario.StateSigner
                    ExecutableSignerThumbprint = $(if ($script:Scenario.SplitSigner) { 'C' * 40 } else { $script:Scenario.StateSigner })
                }
            }
        }
        function Get-WinAirPlayInstallationInventory {
            $script:Events.Add('Inventory')
            return [pscustomobject]@{
                HasInstalledArtifacts = $script:Scenario.ProductPresent
                UserService = $null; KernelService = $null; FirewallRule = $null
                Devices = @(); DriverPackages = @(); RuntimeTransactions = @()
                InstallerSnapshots = @(); RuntimeExists = $false
                StateExists = $script:Scenario.HasState; InstallerRootExists = $false
            }
        }
        function Test-WinAirPlayInstallationPresent { return $script:Scenario.ProductPresent }
        function Enter-WinAirPlayInstallerMutex {
            $script:Events.Add('InstallerMutexEntered')
            return 'synthetic-installer-mutex'
        }
        function Exit-WinAirPlayInstallerMutex {
            param($Mutex)
            $script:Events.Add('InstallerMutexExited')
        }
        function Remove-WinAirPlayInstallation {
            param([switch]$ForcePackageRemoval, [switch]$RemoveToolCaches)
            $script:Events.Add('RemoveProduct')
            if ($ForcePackageRemoval) { $script:Events.Add('ForcePackageRemoval') }
            if ($RemoveToolCaches) { $script:Events.Add('RemoveToolCaches') }
            if ($script:Scenario.RemovalFails) { throw 'Fixture driver remains loaded; cleanup failed.' }
            $script:Scenario.ProductPresent = $false
            if (Test-Path -LiteralPath $script:WinAirPlayStateFile) {
                Remove-Item -LiteralPath $script:WinAirPlayStateFile -Force
            }
        }
        function Assert-WinAirPlayInstallationAbsent {
            param([switch]$RequireToolCachesAbsent)
            $script:Events.Add('VerifyAbsent')
            if ($script:Scenario.AbsentFails) { throw 'Fixture cleanup postcondition failed.' }
        }
        function Get-WinAirPlaySetupBootState {
            $script:Events.Add('ReadBoot')
            return [pscustomobject]@{TestSigningActive=$script:Scenario.ActiveBoot;HvciEnabled=$false}
        }
        function Get-WinAirPlaySetupDependencyStatus {
            $script:Events.Add('ReadDependencies')
            return [pscustomobject]@{
                PowerShellInstalled = -not $script:Scenario.MissingPowerShell
                PowerShellPath = 'fixture-pwsh.exe'; VcRuntimeInstalled = $false
            }
        }
        function Invoke-WinAirPlaySetupHost {
            param($Executable, $Script, $Parameters, [switch]$Elevate)
            $script:Events.Add('InvokeHost')
            if ($Elevate) { $script:Events.Add('Elevate') }
            if ($script:Scenario.HostFails) { throw 'Fixture UAC cancellation.' }
            return $script:Scenario.ChildResult
        }
        function Read-Host {
            param($Prompt)
            $script:Events.Add('Prompt')
            if ($script:Scenario.Responses.Count) { return $script:Scenario.Responses.Dequeue() }
            return 'NO'
        }
        function New-WinAirPlaySetupScratch {
            $script:Events.Add('ScratchCreated')
            $path = Join-Path $script:FixtureDirectory 'scratch'
            $null = [IO.Directory]::CreateDirectory($path)
            return $path
        }
        function New-WinAirPlaySetupProtectedDirectory {
            param($Path)
            $prefix = [IO.Path]::GetFullPath($script:FixtureDirectory).TrimEnd('\') + '\'
            if (-not [IO.Path]::GetFullPath($Path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Fixture directory creation escaped its local scope.'
            }
            $null = [IO.Directory]::CreateDirectory($Path)
            if ($script:Scenario.SnapshotFails) { throw 'Fixture protected snapshot failure.' }
        }
        function Remove-WinAirPlaySetupScratch {
            param($Path)
            $script:Events.Add('ScratchRemoved')
            if ([IO.Path]::GetFullPath($Path) -cne (Join-Path $script:FixtureDirectory 'scratch')) {
                throw 'Fixture scratch cleanup escaped its local scope.'
            }
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
        }
        function Invoke-FixtureCertificateRemoval {
            param($Pin)
            $global:WinAirPlayUninstallFixtureInvocation.Events.Add('RemoveCertificate:' + $Pin)
            if ($global:WinAirPlayUninstallFixtureInvocation.Scenario.CertificateFails) { throw 'Fixture certificate removal failed.' }
        }
        function Invoke-FixtureBootChange {
            $global:WinAirPlayUninstallFixtureInvocation.Events.Add('DisableTestSigning')
            if ($global:WinAirPlayUninstallFixtureInvocation.Scenario.BootFails) { throw 'Fixture boot-policy update failed.' }
        }
        function Invoke-WinAirPlayNative { throw 'Unexpected native host call in isolated uninstaller fixture.' }
        function Start-Process { throw 'Unexpected real process launch in isolated uninstaller fixture.' }
        if ($EntryCode) {
            . ([scriptblock]::Create('function Invoke-UninstallFixtureEntry {' + "`n" + $EntryCode + "`n}"))
        }
        Export-ModuleMember -Function Invoke-WinAirPlayGuidedUninstall, Invoke-UninstallFixtureEntry
    } -ArgumentList $code, $setupFunctions, $entryCode, $directory, $Scenario
    return $module
}

function Invoke-UninstallCase {
    param(
        [string]$Name,
        [string]$Entry = 'Common',
        [hashtable]$Changes = @{},
        [hashtable]$Parameters = @{},
        [int]$ExpectedCode = 0,
        [string]$ExpectedError,
        [string[]]$Required = @(),
        [string[]]$Forbidden = @(),
        [string[]]$Order = @()
    )
    $scenario = @{
        HasState = $true; MalformedState = $false; StateSigner = 'B' * 40
        ProductPresent = $true; RemovalFails = $false; AbsentFails = $false
        CertificateFails = $false; BootFails = $false; ActiveBoot = $true
        Elevated = $true; MissingPowerShell = $false; HostFails = $false
        ChildResult = 0; SplitSigner = $false; SnapshotFails = $false
        Responses = [Collections.Generic.Queue[string]]::new()
    }
    foreach ($key in $Changes.Keys) { $scenario[$key] = $Changes[$key] }
    $module = New-UninstallFixtureModule $Entry $scenario
    try {
        $global:WinAirPlayUninstallFixtureInvocation = & $module {
            [pscustomobject]@{ Events=$script:Events; Scenario=$script:Scenario }
        }
        $arguments = @{ConfirmRemoval=$true;NonInteractive=$true}
        if ($Entry -ceq 'Common') {
            $arguments.ScriptDirectory = & $module { $script:FixtureInstaller }
        }
        foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
        $errorText = $null
        $actual = $null
        try {
            $actual = & $module {
                param($Options, $WhichEntry)
                if ($WhichEntry -ceq 'Common') { Invoke-WinAirPlayGuidedUninstall @Options }
                else { Invoke-UninstallFixtureEntry @Options }
            } $arguments $Entry
        } catch { $errorText = $_.Exception.Message }
        if ($ExpectedError) {
            Assert-UninstallFixture ($null -ne $errorText -and $errorText -like "*$ExpectedError*") `
                "$Name failed for the wrong reason: '$errorText'"
        } else {
            Assert-UninstallFixture ($null -eq $errorText -and $actual -eq $ExpectedCode) `
                "$Name returned '$actual' and error '$errorText'; expected $ExpectedCode."
        }
        $events = @(& $module { $script:Events.ToArray() })
        foreach ($event in $Required) { Assert-UninstallFixture ($event -cin $events) "$Name omitted $event. Events: $($events -join ', ')" }
        foreach ($event in $Forbidden) { Assert-UninstallFixture ($event -cnotin $events) "$Name unexpectedly performed $event." }
        $previous = -1
        foreach ($event in $Order) {
            $index = [Array]::IndexOf($events, $event)
            Assert-UninstallFixture ($index -gt $previous) "$Name reordered $event. Events: $($events -join ', ')"
            $previous = $index
        }
        if ('ScratchCreated' -cin $events) {
            Assert-UninstallFixture ('ScratchRemoved' -cin $events) "$Name omitted scratch cleanup."
        }
        if ('InstallerMutexEntered' -cin $events) {
            Assert-UninstallFixture ('InstallerMutexExited' -cin $events) "$Name omitted installer mutex release."
        }
        $script:cases++
        Write-Host "PASS: $Name"
    } finally {
        Remove-Variable WinAirPlayUninstallFixtureInvocation -Scope Global -ErrorAction SilentlyContinue
        Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
}

try {
    foreach ($name in @('Uninstall.Common.ps1', 'Uninstall.ps1', 'Start-Uninstall.ps1')) {
        $null = Get-UninstallAst (Join-Path $PSScriptRoot $name)
    }
    Invoke-UninstallCase -Name 'default unattended removal retains public trust and boot policy' `
        -Required RemoveProduct,RemoveToolCaches,VerifyAbsent -Forbidden DisableTestSigning,Prompt `
        -Order ReadState,RemoveProduct,VerifyAbsent,InstallerMutexExited
    Invoke-UninstallCase -Name 'already absent product remains idempotent' `
        -Changes @{ProductPresent=$false;HasState=$false} -Required RemoveProduct,VerifyAbsent -Forbidden DisableTestSigning,Prompt
    Invoke-UninstallCase -Name 'core plan avoids elevation, inventory and all mutations' `
        -Parameters @{Plan=$true} -Required ReadBoot -Forbidden Administrator,Inventory,RemoveProduct,ScratchCreated,DisableTestSigning
    Invoke-UninstallCase -Name 'unattended removal requires explicit consent' `
        -Parameters @{ConfirmRemoval=$false} -ExpectedError 'Explicit acknowledgement' -Forbidden RemoveProduct,ScratchCreated,DisableTestSigning
    Invoke-UninstallCase -Name 'force package removal is opt in and forwarded' `
        -Parameters @{ForcePackageRemoval=$true} -Required ForcePackageRemoval,VerifyAbsent
    Invoke-UninstallCase -Name 'cleanup failure prevents certificate and boot changes' `
        -Changes @{RemovalFails=$true} -Parameters @{RemoveTestCertificate=$true;DisableTestSigning=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true} `
        -ExpectedError 'driver remains loaded' -Forbidden VerifyAbsent,DisableTestSigning,('RemoveCertificate:' + ('B' * 40))
    Invoke-UninstallCase -Name 'absence postcondition failure prevents certificate and boot changes' `
        -Changes @{AbsentFails=$true} -Parameters @{RemoveTestCertificate=$true} -ExpectedError 'cleanup postcondition' `
        -Forbidden DisableTestSigning,('RemoveCertificate:' + ('B' * 40))
    Invoke-UninstallCase -Name 'snapshot failure prevents product removal and cleans scratch' `
        -Changes @{SnapshotFails=$true} -ExpectedError 'protected snapshot' -Forbidden RemoveProduct,DisableTestSigning
    Invoke-UninstallCase -Name 'matching installed certificate identity is captured before state deletion' `
        -Parameters @{RemoveTestCertificate=$true;ExpectedSignerThumbprint=('b' * 40)} `
        -Order ReadState,RemoveProduct,VerifyAbsent,('RemoveCertificate:' + ('B' * 40)) -Forbidden DisableTestSigning
    Invoke-UninstallCase -Name 'missing state can use explicitly trusted release signer' `
        -Changes @{HasState=$false} -Parameters @{RemoveTestCertificate=$true;ExpectedSignerThumbprint=('B' * 40)} `
        -Required ('RemoveCertificate:' + ('B' * 40)) -Forbidden ReadState,DisableTestSigning
    Invoke-UninstallCase -Name 'missing certificate identity retains trust after product removal' `
        -Changes @{HasState=$false} -Parameters @{RemoveTestCertificate=$true} -ExpectedError 'no verified matching certificate identity' `
        -Required RemoveProduct,VerifyAbsent -Forbidden DisableTestSigning
    Invoke-UninstallCase -Name 'malformed state permits product removal while retaining trust' `
        -Changes @{MalformedState=$true} -Required RemoveProduct,VerifyAbsent -Forbidden DisableTestSigning,('RemoveCertificate:' + ('B' * 40))
    Invoke-UninstallCase -Name 'mismatched signer cannot remove certificate trust' `
        -Parameters @{RemoveTestCertificate=$true;ExpectedSignerThumbprint=('C' * 40)} -ExpectedError 'no verified matching certificate identity' `
        -Required RemoveProduct,VerifyAbsent -Forbidden DisableTestSigning,('RemoveCertificate:' + ('C' * 40))
    Invoke-UninstallCase -Name 'split signer state cannot infer dedicated test certificate' `
        -Changes @{SplitSigner=$true} -Parameters @{RemoveTestCertificate=$true} -ExpectedError 'no verified matching certificate identity' `
        -Required RemoveProduct,VerifyAbsent -Forbidden DisableTestSigning,('RemoveCertificate:' + ('B' * 40))
    Invoke-UninstallCase -Name 'certificate removal failure prevents boot-policy change' `
        -Changes @{CertificateFails=$true} -Parameters @{RemoveTestCertificate=$true;DisableTestSigning=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true} `
        -ExpectedError 'certificate removal failed' -Forbidden DisableTestSigning
    foreach ($ack in @('AcknowledgeOtherTestDrivers','AcknowledgeBootConfigurationChange','AcknowledgeBitLockerRecoveryRisk')) {
        $arguments = @{DisableTestSigning=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true}
        $arguments[$ack] = $false
        Invoke-UninstallCase -Name "missing unattended $ack fails before removal" -Parameters $arguments `
            -ExpectedError 'acknowledgements' -Forbidden RemoveProduct,ScratchCreated,DisableTestSigning
    }
    foreach ($active in @($true,$false)) {
        Invoke-UninstallCase -Name "explicit exit requests TESTSIGNING off regardless of active boot $active" `
            -Changes @{ActiveBoot=$active} -ExpectedCode 3010 `
            -Parameters @{DisableTestSigning=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true} `
            -Order RemoveProduct,VerifyAbsent,DisableTestSigning,InstallerMutexExited
    }
    Invoke-UninstallCase -Name 'boot-policy failure reports failure after successful product cleanup' `
        -Changes @{BootFails=$true} -Parameters @{DisableTestSigning=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true} `
        -ExpectedError 'boot-policy update failed' -Order RemoveProduct,VerifyAbsent,DisableTestSigning
    $responses = [Collections.Generic.Queue[string]]::new()
    $responses.Enqueue('NO'); $responses.Enqueue('NO')
    Invoke-UninstallCase -Name 'attended user may decline both optional cleanup actions' -Changes @{Responses=$responses} `
        -Parameters @{NonInteractive=$false} -Required RemoveProduct,VerifyAbsent,Prompt -Forbidden DisableTestSigning,('RemoveCertificate:' + ('B' * 40))
    $responses = [Collections.Generic.Queue[string]]::new()
    $responses.Enqueue('YES')
    Invoke-UninstallCase -Name 'attended YES selection exits test mode only after cleanup' -Changes @{Responses=$responses} -ExpectedCode 3010 `
        -Parameters @{NonInteractive=$false;KeepTestCertificate=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true} `
        -Order RemoveProduct,VerifyAbsent,Prompt,DisableTestSigning
    Invoke-UninstallCase -Name 'explicit keep options suppress attended optional prompts' `
        -Parameters @{NonInteractive=$false;KeepTestCertificate=$true;KeepTestSigning=$true} `
        -Required RemoveProduct,VerifyAbsent -Forbidden Prompt,DisableTestSigning,('RemoveCertificate:' + ('B' * 40))
    foreach ($options in @(@{DisableTestSigning=$true;KeepTestSigning=$true},@{RemoveTestCertificate=$true;KeepTestCertificate=$true})) {
        Invoke-UninstallCase -Name ('conflicting options rejected: ' + ($options.Keys -join '/')) -Parameters $options `
            -ExpectedError 'Choose one' -Forbidden RemoveProduct,ScratchCreated,DisableTestSigning
    }
    Invoke-UninstallCase -Name 'invalid signer pin rejected before cleanup' -Parameters @{ExpectedSignerThumbprint='../unsafe'} `
        -ExpectedError '40 hexadecimal' -Forbidden RemoveProduct,ScratchCreated,DisableTestSigning
    Invoke-UninstallCase -Name 'bootstrap plan needs no PowerShell dependency or elevation' -Entry 'Start-Uninstall.ps1' `
        -Parameters @{Plan=$true} -Changes @{MissingPowerShell=$true;Elevated=$false} -Required ReadBoot `
        -Forbidden ReadDependencies,InvokeHost,Elevate,RemoveProduct
    Invoke-UninstallCase -Name 'bootstrap WhatIf is read only' -Entry 'Start-Uninstall.ps1' `
        -Parameters @{WhatIf=$true} -Forbidden ReadDependencies,InvokeHost,Elevate,RemoveProduct
    Invoke-UninstallCase -Name 'bootstrap missing PowerShell fails without downloading prerequisites' -Entry 'Start-Uninstall.ps1' `
        -Changes @{MissingPowerShell=$true} -ExpectedCode 1 -Required ReadDependencies -Forbidden InvokeHost,Elevate,RemoveProduct
    Invoke-UninstallCase -Name 'bootstrap UAC cancellation reports failure' -Entry 'Start-Uninstall.ps1' `
        -Changes @{Elevated=$false;HostFails=$true} -ExpectedCode 1 -Required Elevate -Forbidden RemoveProduct
    foreach ($exitCode in @(0,1,3010)) {
        Invoke-UninstallCase -Name "bootstrap propagates child exit $exitCode" -Entry 'Start-Uninstall.ps1' `
            -Changes @{ChildResult=$exitCode} -ExpectedCode $exitCode -Required InvokeHost -Forbidden Elevate,RemoveProduct
    }
    Invoke-UninstallCase -Name 'core wrapper propagates restart-required result' -Entry 'Uninstall.ps1' -ExpectedCode 3010 `
        -Parameters @{DisableTestSigning=$true;AcknowledgeOtherTestDrivers=$true;AcknowledgeBootConfigurationChange=$true;AcknowledgeBitLockerRecoveryRisk=$true} `
        -Required DisableTestSigning,VerifyAbsent
    Invoke-UninstallCase -Name 'core wrapper converts cleanup failure to exit one' -Entry 'Uninstall.ps1' -ExpectedCode 1 `
        -Changes @{RemovalFails=$true} -Forbidden DisableTestSigning
    Write-Host "Uninstaller fixture tests passed ($cases cases). Product, certificate and boot actions were mocked; no host installation or policy changed."
} finally { Remove-UninstallFixtureRoot }
