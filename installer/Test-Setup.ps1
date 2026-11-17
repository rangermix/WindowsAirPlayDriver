[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$fixtureRoot = Join-Path $repository ('.local/diagnostics/setup-tests/' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
$cases = 0

function Assert-SetupFixture([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-SetupAst([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-SetupFixture ($errors.Count -eq 0) "Setup script does not parse: $Path"
    return $ast
}

function Get-SetupFunction([string]$Path, [string]$Name) {
    $ast = Get-SetupAst $Path
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true)
    Assert-SetupFixture ($null -ne $function) "Required setup helper is absent: $Name"
    return $function.Extent.Text
}

function New-SetupFixtureModule([string]$Entry, [hashtable]$Scenario) {
    # Execute the real entry-point body in an isolated module. Dot-sources are
    # excluded, every host-facing helper is replaced, and exit becomes a result.
    # The only invoked scripts are deliberately synthetic scripts below .local.
    $ast = Get-SetupAst (Join-Path $PSScriptRoot $Entry)
    $statements = @($ast.EndBlock.Statements | Where-Object {
        $_ -isnot [Management.Automation.Language.ExitStatementAst] -and
        $_.Extent.Text -notmatch '^\.\s'
    } | ForEach-Object { $_.Extent.Text })
    $resultVariable = if ($Entry -ceq 'Setup.ps1') { '$code' } else { '$resultCode' }
    $entryText = $ast.ParamBlock.Extent.Text + "`n" +
        '$PSScriptRoot = $script:FixtureInstaller; $PSCommandPath = Join-Path $PSScriptRoot ''' + $Entry + "'`n" +
        ($statements -join "`n") + "`nreturn $resultVariable"
    $entryText = $entryText.Replace("'Global\WinAirPlayAudio.Setup'",
        ("'Local\WinAirPlayAudio.Setup.Fixture." + [Guid]::NewGuid().ToString('N') + "'"))
    $scenarioDirectory = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
    $installerDirectory = Join-Path $scenarioDirectory 'installer'
    $null = [IO.Directory]::CreateDirectory($installerDirectory)
    $null = [IO.Directory]::CreateDirectory((Join-Path $scenarioDirectory 'package'))
    [IO.File]::WriteAllText((Join-Path $scenarioDirectory 'package/fixture.bin'), 'synthetic package')
    [IO.File]::WriteAllText((Join-Path $installerDirectory 'Common.ps1'), '# Synthetic helper: never dot-sourced.')
    [IO.File]::WriteAllBytes((Join-Path $scenarioDirectory 'test-signing.cer'), $script:fixtureCertificate.RawData)
    [IO.File]::WriteAllText((Join-Path $installerDirectory 'Set-TestSigning.ps1'), @'
[CmdletBinding(SupportsShouldProcess)]
param($Mode, [switch]$AcknowledgeBootConfigurationChange, [switch]$AcknowledgeBitLockerRecoveryRisk)
Invoke-FixtureBootChange
'@)
    [IO.File]::WriteAllText((Join-Path $installerDirectory 'Install-Driver.ps1'), @'
[CmdletBinding(SupportsShouldProcess)]
param($PackageDirectory, $ExpectedSignedManifestSha256, $ExpectedSignerThumbprint)
Invoke-FixtureDriverInstall
'@)
    $module = New-Module -ScriptBlock {
        param($Code, $Directory, $Options)
        $script:FixtureInstaller = Join-Path $Directory 'installer'
        $script:FixtureDirectory = $Directory
        $script:Scenario = $Options
        $script:Events = [Collections.Generic.List[string]]::new()
        $script:BootReads = 0
        function Assert-WinAirPlaySetupPlatform { $script:Events.Add('Platform') }
        function Assert-WinAirPlayTarget { $script:Events.Add('Platform') }
        function Assert-WinAirPlayAdministrator { $script:Events.Add('Administrator') }
        function Test-WinAirPlaySetupAdministrator { return $true }
        function Assert-WinAirPlaySetupInputs {
            param($BundleDirectory, $ExpectedSignedManifestSha256, $ExpectedSignerThumbprint)
            $script:Events.Add('Authenticate')
            if ($script:Scenario.BadInput) { throw 'Fixture package authentication failed.' }
        }
        function Resolve-WinAirPlayPackage {
            param($PackageDirectory)
            $script:Events.Add('ResolvePackage')
            return [pscustomobject]@{ Directory = $PackageDirectory }
        }
        function Get-WinAirPlaySetupDependencyStatus {
            return [pscustomobject]@{
                PowerShellInstalled = -not $script:Scenario.MissingDependencies
                VcRuntimeInstalled = -not $script:Scenario.MissingDependencies
                PowerShellPath = 'fixture-pwsh.exe'
            }
        }
        function Get-WinAirPlaySetupBootState {
            $script:Events.Add('ReadBoot')
            $script:BootReads++
            return [pscustomobject]@{
                TestSigningActive = $script:Scenario.ActiveBoot -and
                    -not ($script:Scenario.BootChanges -and $script:BootReads -gt 1)
                HvciEnabled = $false
            }
        }
        function Confirm-WinAirPlaySetupAction {
            param([bool]$Acknowledged, [bool]$NonInteractive, [string]$Description)
            $script:Events.Add('Acknowledge')
            if (-not $Acknowledged) { throw 'Fixture explicit acknowledgement missing.' }
        }
        function New-WinAirPlaySetupScratch {
            $script:Events.Add('ScratchCreated')
            $path = Join-Path $script:FixtureDirectory 'runtime'
            $null = [IO.Directory]::CreateDirectory($path)
            return $path
        }
        function Remove-WinAirPlaySetupScratch {
            param($Path)
            if ([IO.Path]::GetFullPath($Path) -cne (Join-Path $script:FixtureDirectory 'runtime')) {
                throw 'Fixture cleanup escaped its exact local scratch path.'
            }
            $script:Events.Add('ScratchRemoved')
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
        function New-WinAirPlaySecureDirectory {
            param($Path)
            $null = [IO.Directory]::CreateDirectory($Path)
        }
        function New-WinAirPlaySetupScriptSnapshot {
            param($SourceDirectory, $Destination, $ExpectedHashes)
            $script:Events.Add('SnapshotScripts')
            return $script:FixtureInstaller
        }
        function Get-WinAirPlayPackageFileNames { return @('fixture.bin') }
        function Install-WinAirPlaySetupDependencies {
            param($DownloadDirectory, $PrerequisiteDirectory)
            $script:Events.Add('InstallDependencies')
            $script:Scenario.MissingDependencies = $false
            return [pscustomobject]@{ RebootRequired = $script:Scenario.DependencyReboot }
        }
        function Add-WinAirPlaySetupCertificateTrust {
            param($Certificate, $AddedStores)
            $script:Events.Add('TrustCertificate')
            $AddedStores.Add('Root')
            if ($script:Scenario.TrustFails) { throw 'Fixture partial trust failure.' }
            $AddedStores.Add('TrustedPublisher')
        }
        function Remove-WinAirPlaySetupCertificateTrust {
            param($Certificate, $StoreNames)
            $script:Events.Add('RollbackTrust:' + ($StoreNames -join ','))
        }
        function Assert-WinAirPlayPackageSignature {
            param($Package, $ExpectedCatalogSignerThumbprint, $ExpectedExecutableSignerThumbprint)
            $script:Events.Add('CheckSignature')
            if ($script:Scenario.SignatureFails) { throw 'Fixture signature rejected.' }
        }
        function Invoke-FixtureBootChange {
            $global:WinAirPlaySetupFixtureInvocation.Events.Add('ConfigureTestSigning')
            if ($global:WinAirPlaySetupFixtureInvocation.Scenario.SecureBootBlocked) { throw 'Fixture Secure Boot blocks test signing.' }
        }
        function Invoke-FixtureDriverInstall {
            $global:WinAirPlaySetupFixtureInvocation.Events.Add('InstallDriver')
            if ($global:WinAirPlaySetupFixtureInvocation.Scenario.InstallFails) { throw 'Fixture driver installation failure.' }
        }
        function Invoke-WinAirPlaySetupHost {
            param($Executable, $Script, $Parameters, [switch]$Elevate)
            $script:Events.Add('InvokeCore')
            return $script:Scenario.ChildResult
        }
        . ([scriptblock]::Create('function Invoke-SetupFixtureEntry {' + "`n" + $Code + "`n}"))
        Export-ModuleMember -Function Invoke-SetupFixtureEntry
    } -ArgumentList $entryText, $scenarioDirectory, $Scenario
    return $module
}

function Invoke-SetupStateCase {
    param([string]$Name, [string]$Entry = 'Setup.ps1', [hashtable]$Changes = @{},
        [int]$ExpectedCode, [string[]]$Required = @(), [string[]]$Forbidden = @(), [switch]$Plan)
    $scenario = @{
        ActiveBoot = $true; BadInput = $false; MissingDependencies = $false
        BootChanges = $false; TrustFails = $false; SignatureFails = $false
        InstallFails = $false; SecureBootBlocked = $false; DependencyReboot = $false
        ChildResult = 0
    }
    foreach ($key in $Changes.Keys) { $scenario[$key] = $Changes[$key] }
    $module = New-SetupFixtureModule $Entry $scenario
    try {
        $global:WinAirPlaySetupFixtureInvocation = & $module {
            [pscustomobject]@{ Events=$script:Events; Scenario=$script:Scenario }
        }
        $arguments = @{
            ExpectedSignedManifestSha256 = 'A' * 64; ExpectedSignerThumbprint = 'B' * 40
            EnableTestSigning = $true; AcknowledgeBootConfigurationChange = $true
            AcknowledgeBitLockerRecoveryRisk = $true; TrustTestCertificate = $true
            AcceptCleanReinstall = $true; NonInteractive = $true; Plan = [bool]$Plan
        }
        if ($Entry -ceq 'Start-Setup.ps1') { $arguments.InstallDependencies = $true }
        $code = & $module { param($Parameters) Invoke-SetupFixtureEntry @Parameters } $arguments
        $events = @(& $module { $script:Events.ToArray() })
        Assert-SetupFixture ($code -eq $ExpectedCode) "$Name returned '$code', expected $ExpectedCode. Events: $($events -join ', ')"
        foreach ($event in $Required) { Assert-SetupFixture ($event -cin $events) "$Name omitted $event." }
        foreach ($event in $Forbidden) { Assert-SetupFixture ($event -cnotin $events) "$Name unexpectedly performed $event." }
        if ('ScratchCreated' -cin $events) {
            Assert-SetupFixture ('ScratchRemoved' -cin $events) "$Name failed scratch cleanup."
        }
        $script:cases++
        Write-Host "PASS: $Name"
    } finally {
        Remove-Variable WinAirPlaySetupFixtureInvocation -Scope Global -ErrorAction SilentlyContinue
        Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SetupInputCases {
    # These checks use the real input validator and real public certificate
    # parsing. Only synthetic package bytes beneath ignored .local are written.
    foreach ($helper in @('Assert-WinAirPlaySetupNoLinks', 'Assert-WinAirPlaySetupInputs')) {
        . ([scriptblock]::Create((Get-SetupFunction (Join-Path $PSScriptRoot 'Setup.Common.ps1') $helper)))
    }
    foreach ($case in @('valid', 'wrong hash', 'corrupt payload', 'length mismatch', 'duplicate name',
            'traversal name', 'unexpected file', 'wrong certificate pin', 'public-only PFX')) {
        $directory = Join-Path $fixtureRoot ('input-' + [Guid]::NewGuid().ToString('N'))
        $package = Join-Path $directory 'package'
        $null = [IO.Directory]::CreateDirectory($package)
        $payload = Join-Path $package 'fixture.bin'
        $manifestPath = Join-Path $package 'package-manifest.json'
        $certPath = Join-Path $directory 'test-signing.cer'
        [IO.File]::WriteAllText($payload, 'Synthetic setup payload')
        [IO.File]::WriteAllBytes($certPath, $script:fixtureCertificate.RawData)
        $manifest = [pscustomobject]@{
            SchemaVersion=1; Platform='x64'; HardwareId='ROOT\WinAirPlayAudio'
            UserService='WinAirPlayAudioService'; UnsignedManifestSha256=('A' * 64)
            Files=@([pscustomobject]@{
                Name='fixture.bin'; Length=(Get-Item -LiteralPath $payload).Length
                Sha256=(Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
            })
        }
        switch ($case) {
            'length mismatch' { $manifest.Files[0].Length++ }
            'duplicate name' { $manifest.Files += $manifest.Files[0] }
            'traversal name' { $manifest.Files[0].Name='../outside.bin' }
            'unexpected file' { [IO.File]::WriteAllText((Join-Path $package 'unexpected.bin'), 'unexpected') }
            'public-only PFX' {
                $publicOnly = [Security.Cryptography.X509Certificates.X509Certificate2]::new($script:fixtureCertificate.RawData)
                try { [IO.File]::WriteAllBytes($certPath, $publicOnly.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)) }
                finally { $publicOnly.Dispose() }
            }
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $expectedHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        $expectedPin = $script:fixtureCertificate.Thumbprint
        if ($case -ceq 'wrong hash') { $expectedHash = '0' * 64 }
        if ($case -ceq 'wrong certificate pin') { $expectedPin = '0' * 40 }
        if ($case -ceq 'corrupt payload') { [IO.File]::WriteAllText($payload, 'Changed after manifest authentication') }
        $rejected = $false
        try { $null = Assert-WinAirPlaySetupInputs $directory $expectedHash $expectedPin }
        catch { $rejected = $true }
        Assert-SetupFixture ($rejected -eq ($case -cne 'valid')) "Real setup input validator returned an incorrect result for $case."
        $script:cases++
        Write-Host "PASS: real setup inputs - $case"
    }
}

function Invoke-SetupTrustRollbackCase {
    # Preserve the real rollback loop and error aggregation, substituting only
    # its certificate-store constructor. No Windows certificate store is opened.
    $text = Get-SetupFunction (Join-Path $PSScriptRoot 'Setup.Common.ps1') 'Remove-WinAirPlaySetupCertificateTrust'
    $constructor = '[Security.Cryptography.X509Certificates.X509Store]::new($storeName, ''LocalMachine'')'
    Assert-SetupFixture ($text.Contains($constructor)) 'Update the isolated rollback fixture for the store-constructor change.'
    $text = $text.Replace($constructor, '(New-FixtureTrustStore $storeName)')
    Assert-SetupFixture (-not $text.Contains('X509Store')) 'Rollback fixture still contains a real Windows store constructor.'
    $module = New-Module -ScriptBlock {
        param($Helper)
        $script:Attempts = [Collections.Generic.List[string]]::new()
        function New-FixtureTrustStore($Name) {
            $store = [pscustomobject]@{ Name=$Name; Certificates=@() }
            $store | Add-Member ScriptMethod Open { param($Mode) }
            $store | Add-Member ScriptMethod Close { }
            $store | Add-Member ScriptMethod Remove {
                param($Certificate)
                $script:Attempts.Add($this.Name)
                if ($this.Name -ceq 'Root') { throw 'Synthetic Root rollback failure.' }
            }
            return $store
        }
        . ([scriptblock]::Create($Helper))
        Export-ModuleMember -Function Remove-WinAirPlaySetupCertificateTrust
    } -ArgumentList $text
    try {
        $failed = $false
        try {
            & $module {
                param($Certificate)
                Remove-WinAirPlaySetupCertificateTrust -Certificate $Certificate -StoreNames @('Root', 'TrustedPublisher')
            } $script:fixtureCertificate
        } catch { $failed = $_.Exception.Message.Contains('Synthetic Root rollback failure.') }
        $attempts = @(& $module { $script:Attempts.ToArray() })
        Assert-SetupFixture ($failed -and $attempts.Count -eq 2 -and
            $attempts[0] -ceq 'Root' -and $attempts[1] -ceq 'TrustedPublisher') `
            'A failed first trust rollback prevented another owned store from being cleaned or lost its error.'
        $script:cases++
        Write-Host 'PASS: real trust rollback attempts every owned store and reports failure'
    } finally { Remove-Module $module -Force -ErrorAction SilentlyContinue }
}

$rsa = [Security.Cryptography.RSA]::Create(2048)
$script:fixtureCertificate = $null
try {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=WinAirPlayAudio setup fixture', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oids = [Security.Cryptography.OidCollection]::new()
    $null = $oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
    $script:fixtureCertificate = $request.CreateSelfSigned(
        [DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    Invoke-SetupStateCase -Name 'inactive boot configures test signing and stops for manual reboot' -ExpectedCode 3010 `
        -Changes @{ActiveBoot=$false} -Required ConfigureTestSigning -Forbidden TrustCertificate,InstallDriver
    Invoke-SetupStateCase -Name 'Secure Boot refusal prevents trust and driver installation' -ExpectedCode 1 `
        -Changes @{ActiveBoot=$false;SecureBootBlocked=$true} -Required ConfigureTestSigning -Forbidden TrustCertificate,InstallDriver
    Invoke-SetupStateCase -Name 'package authentication failure precedes all mutations' -ExpectedCode 1 `
        -Changes @{BadInput=$true} -Forbidden ConfigureTestSigning,TrustCertificate,InstallDriver,ScratchCreated
    Invoke-SetupStateCase -Name 'missing dependencies prevent core installation' -ExpectedCode 1 `
        -Changes @{MissingDependencies=$true} -Forbidden ConfigureTestSigning,TrustCertificate,InstallDriver
    Invoke-SetupStateCase -Name 'active boot installs and retains successful trust' -ExpectedCode 0 `
        -Required TrustCertificate,CheckSignature,InstallDriver,ScratchRemoved -Forbidden ConfigureTestSigning,'RollbackTrust:Root,TrustedPublisher'
    Invoke-SetupStateCase -Name 'partial certificate trust failure rolls back only owned trust' -ExpectedCode 1 `
        -Changes @{TrustFails=$true} -Required 'RollbackTrust:Root',ScratchRemoved -Forbidden CheckSignature,InstallDriver
    Invoke-SetupStateCase -Name 'signature rejection removes newly added trust and scratch' -ExpectedCode 1 `
        -Changes @{SignatureFails=$true} -Required 'RollbackTrust:Root,TrustedPublisher',ScratchRemoved -Forbidden InstallDriver
    Invoke-SetupStateCase -Name 'current-boot recheck prevents installation after trust' -ExpectedCode 1 `
        -Changes @{BootChanges=$true} -Required CheckSignature,'RollbackTrust:Root,TrustedPublisher' -Forbidden InstallDriver
    Invoke-SetupStateCase -Name 'driver failure removes newly added trust and scratch' -ExpectedCode 1 `
        -Changes @{InstallFails=$true} -Required InstallDriver,'RollbackTrust:Root,TrustedPublisher',ScratchRemoved
    Invoke-SetupStateCase -Name 'core plan does not create scratch, trust or install' -ExpectedCode 0 -Plan `
        -Forbidden ScratchCreated,ConfigureTestSigning,TrustCertificate,InstallDriver
    Invoke-SetupStateCase -Name 'dependency reboot stops bootstrap before core invocation' -Entry Start-Setup.ps1 -ExpectedCode 3010 `
        -Changes @{MissingDependencies=$true;DependencyReboot=$true} -Required InstallDependencies,ScratchRemoved -Forbidden InvokeCore
    Invoke-SetupStateCase -Name 'bootstrap propagates core reboot requirement' -Entry Start-Setup.ps1 -ExpectedCode 3010 `
        -Changes @{ChildResult=3010} -Required InvokeCore -Forbidden InstallDependencies
    Invoke-SetupStateCase -Name 'bootstrap plan never installs dependencies or invokes core' -Entry Start-Setup.ps1 -ExpectedCode 0 -Plan `
        -Changes @{MissingDependencies=$true} -Forbidden InstallDependencies,InvokeCore,ScratchCreated
    Invoke-SetupInputCases
    Invoke-SetupTrustRollbackCase

    # Harmless real subprocesses verify the actual encoded-command host wrapper.
    # They only exit; they cannot install dependencies, touch trust or boot state.
    $hostHelper = Get-SetupFunction (Join-Path $PSScriptRoot 'Setup.Common.ps1') 'Invoke-WinAirPlaySetupHost'
    . ([scriptblock]::Create($hostHelper))
    $hostPath = (Get-Process -Id $PID).Path
    foreach ($expected in @(0, 1, 3010)) {
        $childPath = Join-Path $fixtureRoot "child-exit-$expected.ps1"
        [IO.File]::WriteAllText($childPath, "exit $expected")
        $actual = Invoke-WinAirPlaySetupHost -Executable $hostPath -Script $childPath -Parameters @{}
        Assert-SetupFixture ($actual -eq $expected) "Child exit $expected became $actual."
        $cases++
        Write-Host "PASS: subprocess preserves exit code $expected"
    }
    Write-Host "Setup fixture tests passed ($cases cases). Host-facing actions were mocked; subprocesses only exited. No dependencies, boot policy, machine trust, driver, service or firewall were changed."
} finally {
    if ($script:fixtureCertificate) { $script:fixtureCertificate.Dispose() }
    $rsa.Dispose()
}
