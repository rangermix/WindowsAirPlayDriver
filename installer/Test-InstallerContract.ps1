[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$failures = [Collections.Generic.List[string]]::new()

foreach ($scriptFile in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in $errors) {
        $failures.Add("$($scriptFile.Name): $($parseError.Message)")
    }
}

$common = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Common.ps1') -Raw
$install = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-Driver.ps1') -Raw
$uninstall = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-Driver.ps1') -Raw
$package = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package.ps1') -Raw
$testSigning = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-TestSigning.ps1') -Raw
$signPackage = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Sign-TestPackage.ps1') -Raw
$newCertificate = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-TestCertificate.ps1') -Raw
$removeCertificate = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Remove-TestCertificate.ps1') -Raw
$oneClickPath =
    Join-Path $PSScriptRoot 'Invoke-TestBuildPackageSignInstall.ps1'
$oneClick = Get-Content -LiteralPath $oneClickPath -Raw
$oneClickLauncherPath =
    Join-Path $repoRoot 'Test-Build-Package-Sign-Install.cmd'
$oneClickLauncher = Get-Content -LiteralPath $oneClickLauncherPath -Raw
$runtime = Get-Content -LiteralPath (Join-Path $repoRoot 'service\src\runtime.rs') -Raw
. (Join-Path $PSScriptRoot 'Common.ps1')

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

$cleanupFunction = [regex]::Match(
    $common,
    '(?ms)^function Remove-WinAirPlayInstallation \{.*?(?=^function Get-WinAirPlayDirectoryInventory \{)').Value
$absenceFunction = [regex]::Match(
    $common,
    '(?ms)^function Assert-WinAirPlayInstallationAbsent \{.*?(?=^function Remove-WinAirPlayInstallerSnapshots \{)').Value
$snapshotCleanupFunction = [regex]::Match(
    $common,
    '(?ms)^function Remove-WinAirPlayInstallerSnapshots \{.*?(?=^function New-WinAirPlayPackageSnapshot \{)').Value
$installCatch = [regex]::Match(
    $install,
    '(?ms)^catch \{.*?(?=^finally \{)').Value
$uninstallCatch = [regex]::Match(
    $uninstall,
    '(?ms)^catch \{.*?(?=^finally \{)').Value

$manifestValidationIndex = $install.IndexOf('$actualSignedManifestHash =')
$signatureValidationIndex = $install.IndexOf(
    'Assert-WinAirPlayPackageSignature')
$cleanupCallIndex = $install.IndexOf('Remove-WinAirPlayInstallation')
$absenceCallIndex = $install.IndexOf('Assert-WinAirPlayInstallationAbsent')
$postCleanupManifestIndex = $install.IndexOf('$postCleanupManifestHash =')
$secondSignatureValidationIndex = if ($signatureValidationIndex -ge 0) {
    $install.IndexOf(
        'Assert-WinAirPlayPackageSignature',
        $signatureValidationIndex + 1)
}
else {
    -1
}
$addDriverIndex = $install.IndexOf("'/add-driver'")
$rollbackCleanupIndex = if ($cleanupCallIndex -ge 0) {
    $install.IndexOf('Remove-WinAirPlayInstallation', $cleanupCallIndex + 1)
}
else {
    -1
}
$rollbackAbsenceIndex = if ($absenceCallIndex -ge 0) {
    $install.IndexOf(
        'Assert-WinAirPlayInstallationAbsent',
        $absenceCallIndex + 1)
}
else {
    -1
}

Assert-Contract ($common -match "WinAirPlayUserServiceName = 'WinAirPlayAudioService'") `
    'Installer user-service name is missing or changed.'
Assert-Contract ($runtime -match 'SERVICE_NAME: &str = "WinAirPlayAudioService"') `
    'Rust SCM dispatcher name does not match the installer.'
Assert-Contract ($runtime -notmatch 'SERVICE_NAME: &str = "WinAirPlayAudio"') `
    'User service collides with the kernel service name.'
Assert-Contract ($package -match "Common\.ps1" -and
    $package -match '\$expectedPackageNames = @\(Get-WinAirPlayPackageFileNames\)' -and
    $package -match '\$runtimeNames = @\(Get-WinAirPlayRuntimeFileNames\)' -and
    $package -match '\$userModeNames = @\(\$runtimeNames \| Where-Object' -and
    'WinAirPlayAudioService.exe' -cin @(Get-WinAirPlayRuntimeFileNames)) `
    'Package generation does not consume the shared exact payload contract and service executable.'
Assert-Contract ($package -match 'cargo-metadata\.json') `
    'Package script omits the locked dependency inventory.'
Assert-Contract ($package -match "--target',[\r\n\s]+'x86_64-pc-windows-msvc'" -and
    $package -match 'target\\x86_64-pc-windows-msvc\\\$cargoProfile' -and
    $common -match 'function Assert-WinAirPlayPeX64' -and
    $common -match '0x8664' -and
    $common -match "Platform -cne 'x64'") `
    'Package build or validation can mix non-x64 user-mode binaries with the x64 driver.'
Assert-Contract ($package -match 'New-RustLicenseBundle\.ps1' -and
    $common -match 'RUST-DEPENDENCY-LICENSES\.txt' -and
    $install -match 'Get-WinAirPlayRuntimeFileNames') `
    'Package and install do not carry locked dependency license texts.'
Assert-Contract ($package -match 'expectedPackageNames' -and
    $package -match 'unexpectedEntries' -and
    $package -match 'missingPayloads' -and
    $package -match 'finalEntries') `
    'Package generation does not reject stale or missing output entries.'
Assert-Contract ($package -match "repoRoot 'LICENSE'") `
    'Package script omits the project license.'
Assert-Contract ($common -match "'LICENSE'") `
    'Package validation does not require the project license.'
Assert-Contract ($install -match 'Get-WinAirPlayRuntimeFileNames') `
    'Install script does not deploy the project license.'
Assert-Contract ($package -match "driver\\LICENSE\.microsoft-samples\.txt" -and
    'LICENSE.microsoft-samples.txt' -cin @(Get-WinAirPlayRuntimeFileNames) -and
    'LICENSE.microsoft-samples.txt' -cin @(Get-WinAirPlayPackageFileNames) -and
    (Get-Content -LiteralPath (Join-Path $repoRoot 'driver\LICENSE.microsoft-samples.txt') -Raw) -match
        'The Microsoft Public License \(MS-PL\)') `
    'The adapted-driver MS-PL license is absent from the exact package/runtime payload.'
Assert-Contract ($package -match "repoRoot 'version\.json'" -and
    'version.json' -cin @(Get-WinAirPlayRuntimeFileNames) -and
    'version.json' -cin @(Get-WinAirPlayPackageFileNames) -and
    $package.IndexOf("'scripts\Version.ps1'") -ge 0 -and
    $package.IndexOf("'scripts\Version.ps1'") -lt $package.IndexOf('-CargoArguments $cargoArguments') -and
    $package -match "'scripts\\Version\.ps1'\) -Check") `
    'Packaging does not gate on canonical version consistency and carry version.json.'
Assert-Contract ($package -match 'function Get-WinAirPlayPackageSourceState' -and
    $package -match 'SourceCommit = \$buildSourceState\.SourceCommit' -and
    $package -match 'SourceTreeDirty = \[bool\]' -and
    $package -match '\$buildSourceState\.SourceTreeDirty -or' -and
    $package -match '\$finalSourceState\.SourceTreeDirty -or' -and
    $package -match '\$finalSourceState\.SourceCommit -cne \$buildSourceState\.SourceCommit') `
    'Package manifest does not preserve initial source commit and dirty/change evidence across its build.'
Assert-Contract ($package -match '\.local\\diagnostics\\package' -and
    $package -match '-MetadataPath \$rawMetadataPath' -and
    $package.IndexOf('-MetadataPath $rawMetadataPath') -lt
        $package.LastIndexOf('ConvertTo-WinAirPlayPublicCargoMetadata -Metadata') -and
    $package -match 'Set-Content -LiteralPath \$sbomPath') `
    'Packaging does not keep raw Cargo metadata local until license collection, then publish a portable inventory.'
Assert-Contract ($install -match "'obj=', 'LocalSystem'") `
    'Install script does not configure an explicit service account.'
Assert-Contract (
    [regex]::Matches($install, "'start=',\s*'auto'").Count -eq 1
) 'Install script does not configure immediate automatic service discovery at boot.'
Assert-Contract ($install -match 'failureflag[\s\S]{0,100}WinAirPlayUserServiceName[\s\S]{0,50}''1''') `
    'Install script does not enable recovery for non-crash service failures.'
Assert-Contract (
    $common -match "WinAirPlayFirewallRuleName = 'WinAirPlayAudio\.RaopUdpIn'" -and
    $common -match 'function Get-WinAirPlayFirewallRule' -and
    $common -match 'function Test-WinAirPlayFirewallRuleOwnership' -and
    $common -match 'function Test-WinAirPlayFirewallRuleDefinition' -and
    $common -match 'function New-WinAirPlayFirewallRule' -and
    $common -match 'function Remove-WinAirPlayFirewallRule' -and
    $common -match '-PolicyStore PersistentStore' -and
    $common -match '-Direction Inbound' -and
    $common -match '-Action Allow' -and
    $common -match '-Profile Private' -and
    $common -match '-Protocol UDP' -and
    $common -match '-RemoteAddress LocalSubnet' -and
    $common -match '-EdgeTraversalPolicy Block' -and
    $common -match 'Get-NetFirewallApplicationFilter' -and
    $common -match 'Get-NetFirewallPortFilter' -and
    $common -match 'Get-NetFirewallAddressFilter' -and
    $install -match 'New-WinAirPlayFirewallRule[\s\S]{0,120}-ExpectedExecutablePath \$installedService' -and
    $install -match 'Final Windows Firewall postcondition is missing the RAOP UDP rule' -and
    $cleanupFunction -match 'Assert-WinAirPlayFirewallRuleOwnership' -and
    $cleanupFunction -match 'Remove-WinAirPlayFirewallRule'
) 'Installer does not own an exact Private/LocalSubnet/program-scoped inbound UDP rule for RAOP timing.'
Assert-Contract ($install -match 'package-manifest\.json') `
    'Install script does not deploy its verified manifest.'
Assert-Contract ($common -match 'ProviderName[^\r\n]*WinAirPlayAudio') `
    'Package validation does not require the exact INF provider.'
Assert-Contract ($common -match 'ExpectedCatalogSignerThumbprint' -and
    $common -match 'ExpectedExecutableSignerThumbprint') `
    'Installer cannot validate production catalog and executable signers independently.'
Assert-Contract ($common.Contains('^[0-9A-F]{40}$')) `
    'Installer does not shape-check certificate thumbprints.'
Assert-Contract (-not [string]::IsNullOrWhiteSpace($cleanupFunction) -and
    $install -match 'Remove-WinAirPlayInstallation[\s\S]{0,120}-PreserveInstallerSnapshot \$packageSnapshot' -and
    $uninstall -match 'Remove-WinAirPlayInstallation[\s\S]{0,160}-RemoveToolCaches' -and
    $cleanupFunction -match 'Get-WinAirPlayInstallationInventory' -and
    $cleanupFunction -match '''delete'', \$script:WinAirPlayUserServiceName' -and
    $cleanupFunction -match '''/remove-device''' -and
    $cleanupFunction -match '''/delete-driver''' -and
    $cleanupFunction -match 'WinAirPlayInstallDirectory' -and
    $cleanupFunction -match 'Get-WinAirPlayRuntimeTransactionDirectories' -and
    $cleanupFunction -match 'WinAirPlayStateDirectory' -and
    $cleanupFunction -match 'Remove-WinAirPlayInstallerSnapshots' -and
    $cleanupFunction -match 'Assert-WinAirPlayInstallationAbsent') `
    'Install and uninstall do not share one complete, postcondition-checked cleanup implementation.'
$removeDeviceIndex = $cleanupFunction.IndexOf("'/remove-device'")
$devicePostconditionIndex = $cleanupFunction.IndexOf(
    'PnP removal left $($remainingDevices.Count) matching WinAirPlayAudio devnode(s).')
$kernelUnloadGateIndex = $cleanupFunction.IndexOf('$kernelUnloadDeadline')
$deleteDriverIndex = $cleanupFunction.IndexOf("'/delete-driver'")
Assert-Contract ($removeDeviceIndex -ge 0 -and
    $devicePostconditionIndex -gt $removeDeviceIndex -and
    $kernelUnloadGateIndex -gt $devicePostconditionIndex -and
    $deleteDriverIndex -gt $kernelUnloadGateIndex -and
    $cleanupFunction -match 'Get-WinAirPlayKernelService' -and
    $cleanupFunction -match 'Test-WinAirPlayKernelServiceStopped' -and
    $common -match '(?s)function Get-WinAirPlayKernelService.*?-ErrorAction Stop' -and
    $cleanupFunction -match 'Reboot is required; Driver Store packages were not changed') `
    'Cleanup can mutate the Driver Store before proving that PnP unloaded the kernel driver.'
Assert-Contract (Test-WinAirPlayKernelServiceStopped -Service $null) `
    'An absent kernel-service record is not accepted as unloaded.'
Assert-Contract (Test-WinAirPlayKernelServiceStopped -Service (
        [pscustomobject]@{ State = 'Stopped'; Started = $false }
    )) 'A fully stopped kernel service is not accepted as unloaded.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ State = 'Running'; Started = $true }
        ))) 'A running kernel service is accepted as unloaded.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ State = 'Stopped'; Started = $true }
        ))) 'A started kernel service with contradictory State is accepted as unloaded.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ State = 'Start Pending'; Started = $false }
        ))) 'A transitional kernel service is accepted as unloaded.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ State = 'Stopped'; Started = $null }
        ))) 'An unknown Started value is accepted as unloaded.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ State = 'Stopped'; Started = 'false' }
        ))) 'A string Started value is accepted as a trusted Boolean unload state.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ State = 'Stopped' }
        ))) 'A kernel-service record missing Started is accepted as unloaded.'
Assert-Contract (-not (Test-WinAirPlayKernelServiceStopped -Service (
            [pscustomobject]@{ Started = $false }
        ))) 'A kernel-service record missing State is accepted as unloaded.'
Assert-Contract ($install -match 'New-WinAirPlayPackageSnapshot' -and
    $install -match 'Resolve-WinAirPlayPackage -PackageDirectory \$packageSnapshot') `
    'Install does not consume a protected post-copy package snapshot.'
Assert-Contract ($install -match 'ExpectedSignedManifestSha256' -and
    $install -match 'actualSignedManifestHash' -and
    $install -match 'independently trusted hash' -and
    $manifestValidationIndex -ge 0 -and
    $signatureValidationIndex -gt $manifestValidationIndex -and
    $cleanupCallIndex -gt $signatureValidationIndex -and
    $install -match 'PackageManifestSha256 = \$expectedSignedManifestHash' -and
    $common -match 'PackageManifestSha256') `
    'Install can clean the machine before authenticating the protected signed package.'
Assert-Contract ($common -match 'Get-WinAirPlayPackageFileNames' -and
    $common -match 'maximumFileBytes' -and
    $common -match 'maximumPackageBytes' -and
    $common -match 'FileMode\]::CreateNew' -and
    $common -match '\$snapshotOwned = \$true[\s\S]{0,120}New-WinAirPlaySecureDirectory -Path \$snapshot' -and
    $common -match '\$rootOwned = \$true[\s\S]{0,160}New-WinAirPlaySecureDirectory -Path \$script:WinAirPlayInstallerStagingRoot') `
    'Protected package snapshots do not enforce an exact file set and bounded streaming copy.'
Assert-Contract ($signPackage -match 'ExpectedManifestSha256' -and
    $signPackage -match 'actualManifestHash' -and
    $signPackage -match 'UnsignedManifestSha256') `
    'Test signing has no operator-trusted unsigned-package preimage anchor.'
Assert-Contract ($signPackage -match 'signedManifestHash' -and
    $signPackage -match 'publishedManifestHash' -and
    $signPackage -match 'SignedManifestSha256 = \$signedManifestHash') `
    'Test signing does not return and revalidate an independently distributable final-manifest trust anchor.'
Assert-Contract ($signPackage -match "FriendlyName -cne 'WinAirPlayAudio driver test signing'" -and
    $signPackage -match 'certificate\.Subject -cne \$certificate\.Issuer') `
    'Test signing can consume an arbitrary production code-signing certificate.'
$oneClickTestIndex =
    $oneClick.IndexOf('& $buildScript -Test -Configuration $Configuration')
$oneClickPackageIndex =
    $oneClick.IndexOf(
        '& $buildScript -Package -Configuration $Configuration')
$oneClickSignIndex =
    $oneClick.IndexOf('& $signScript')
$oneClickInstallIndex =
    $oneClick.IndexOf('& $installScript')
Assert-Contract (
    $oneClickTestIndex -ge 0 -and
    $oneClickPackageIndex -gt $oneClickTestIndex -and
    $oneClick -notmatch 'SkipIntegrationTests|& \$buildScript -IntegrationTest' -and
    $oneClickSignIndex -gt $oneClickPackageIndex -and
    $oneClickInstallIndex -gt $oneClickSignIndex
) 'One-click deployment does not preserve the configured workspace test, package, sign and install ordering without duplicate test stages.'
Assert-Contract (
    $oneClick -match '\[CmdletBinding\(SupportsShouldProcess, ConfirmImpact = ''High''\)\]' -and
    $oneClick -match 'Install-Driver\.ps1 performs a destructive clean reinstall' -and
    $oneClick -match 'Assert-CurrentBootUsesTestSigning' -and
    $oneClick -match 'SystemStartOptions' -and
    $oneClick -match '''TESTSIGNING'' -notin \$bootOptions' -and
    $oneClick -match 'Resolve-ExistingTestCertificateThumbprint' -and
    $oneClick -match 'Expected exactly one existing dedicated WinAirPlayAudio test certificate' -and
    $oneClick -notmatch 'New-TestCertificate\.ps1[\s\S]{0,120}&' -and
    $oneClick -notmatch 'Set-TestSigning\.ps1[\s\S]{0,120}&'
) 'One-click deployment can mutate boot/certificate trust or proceed without explicit destructive safeguards.'
Assert-Contract (
    $oneClick -match '\. \(Join-Path \$PSScriptRoot ''Common\.ps1''\)' -and
    $oneClick -match 'Assert-WinAirPlayTarget' -and
    $oneClick -match 'Test-WinAirPlayAdministrator' -and
    $oneClick -notmatch 'Assert-WinAirPlayPackageSignature|Remove-WinAirPlayInstallation|Get-Service|endpoint-list\.exe'
) 'One-click deployment duplicates validation/install behavior instead of delegating to existing scripts.'
Assert-Contract (
    $oneClick -match 'ExpectedManifestSha256 \$unsignedManifestSha256' -and
    $oneClick -match 'ExpectedSignedManifestSha256' -and
    $oneClick -match 'ExpectedSignerThumbprint \$thumbprint' -and
    [regex]::Matches($oneClick, '-Confirm:\$false').Count -ge 2
) 'One-click deployment does not carry the fresh manifest hashes/signing identity through one confirmed pipeline.'
Assert-Contract (
    $oneClickLauncher -match '(?i)pwsh\.exe' -and
    $oneClickLauncher -match 'Invoke-TestBuildPackageSignInstall\.ps1' -and
    $oneClickLauncher -match '-Pause'
) 'The root double-click launcher does not invoke the guarded PowerShell pipeline.'
$oneClickWhatIfOutput = @(
    & $oneClickPath -Configuration Release -WhatIf 6>&1 |
        ForEach-Object { $_.ToString() }
)
Assert-Contract ($? -and
    $oneClickWhatIfOutput -match 'existing-script pipeline' -and
    $oneClickWhatIfOutput -match '1\. Run build\.ps1 -Test -Configuration Release' -and
    $oneClickWhatIfOutput -notmatch 'Requesting administrator access|-IntegrationTest') `
    'One-click -WhatIf planning failed or attempted elevation.'
$invalidThumbprintRejected = $false
try {
    $null = & $oneClickPath `
        -Configuration Release `
        -CertificateThumbprint 'not-a-thumbprint' `
        -WhatIf 6>&1
}
catch {
    $invalidThumbprintRejected = $true
}
Assert-Contract $invalidThumbprintRejected `
    'One-click planning accepts a malformed certificate thumbprint.'

# Execute only the actual pipeline/plan function bodies with guarded dependencies;
# never execute the launcher's top-level exit handler or a privileged action.
$serverPlanResult = & {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $Configuration = 'Release'
    $fixture = [pscustomobject]@{ CimQueries=0; SideEffects=0 }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $oneClickPath, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Write-PipelinePlan', 'Invoke-Pipeline')) {
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $name
        }, $false)
        if ($null -eq $definition) { throw "Missing pipeline fixture function: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName)
        $fixture.CimQueries++
        if ($ClassName -cne 'Win32_OperatingSystem') {
            throw "Unexpected fixture CIM query: $ClassName"
        }
        return [pscustomobject]@{ ProductType=3 }
    }
    function Test-WinAirPlayAdministrator {
        $fixture.SideEffects++
        throw 'Runtime validation must precede elevation checks.'
    }
    function Invoke-ElevatedPipeline {
        $fixture.SideEffects++
        throw 'Fixture blocked an elevation side effect.'
    }
    $WhatIfPreference = $true
    $plan = @(Invoke-Pipeline 6>&1 | ForEach-Object { $_.ToString() })
    $planningQueries = $fixture.CimQueries
    $WhatIfPreference = $false
    $rejected = $false
    try { Invoke-Pipeline | Out-Null }
    catch { $rejected = $_.Exception.Message -match 'Windows Server is not validated' }
    [pscustomobject]@{
        Plan = $plan
        PlanningQueries = $planningQueries
        RuntimeQueries = $fixture.CimQueries
        ActualRejected = $rejected
        SideEffects = $fixture.SideEffects
    }
}
Assert-Contract ($serverPlanResult.Plan -match 'existing-script pipeline' -and
    $serverPlanResult.PlanningQueries -eq 0 -and
    $serverPlanResult.RuntimeQueries -eq 1 -and
    $serverPlanResult.ActualRejected -and
    $serverPlanResult.SideEffects -eq 0) `
    'Server build-runner planning is blocked, or real deployment bypasses the strict runtime gate before elevation.'
$signingHostResult = & {
    $script:hostQueries = 0
    function Get-CimInstance {
        $script:hostQueries++
        return [pscustomobject]@{ ProductType = 3 }
    }
    Assert-WinAirPlaySigningHost
    $signingQueries = $script:hostQueries
    $rejected = $false
    try { Assert-WinAirPlayTarget }
    catch { $rejected = $_.Exception.Message -match 'Windows Server is not validated' }
    [pscustomobject]@{ SigningQueries=$signingQueries; InstallQueries=$script:hostQueries; Rejected=$rejected }
}
Assert-Contract ($signingHostResult.SigningQueries -eq 0 -and
    $signingHostResult.InstallQueries -eq 1 -and $signingHostResult.Rejected -and
    $signPackage -match '(?m)^Assert-WinAirPlaySigningHost$' -and
    $install -match '(?m)^Assert-WinAirPlayTarget$' -and
    $uninstall -match '(?m)^Assert-WinAirPlayTarget$' -and
    $testSigning -match '(?m)^Assert-WinAirPlayTarget$') `
    'Signing-host acceptance weakened the workstation-only installation or boot-policy boundary.'
Assert-Contract ($signPackage.Contains(
        "-ArgumentList @('verify', '/v', '/pa', `$package.Sys)") -and
    $signPackage.Contains(
        "-ArgumentList @('verify', '/v', '/pa', `$package.Cat)") -and
    $signPackage.Contains("'verify', '/v', '/pa', '/c'") -and
    $signPackage -match '\$package\.Cat, \$catalogMember' -and
    $signPackage -match 'foreach \(\$catalogMember in @\(\$package\.Inf, \$package\.Sys\)\)' -and
    $signPackage -notmatch "'verify', '/v', '/kp'") `
    'Test-signed driver verification does not use the documented Authenticode/PnP policy and catalog membership checks.'
Assert-Contract ($newCertificate -notmatch 'Remove-Item[\s\S]{0,100}ErrorAction SilentlyContinue' -and
    $newCertificate -match 'Certificate creation failed and rollback was incomplete' -and
    $newCertificate -match 'Certificate remains after rollback' -and
    $newCertificate -match 'DeleteKey' -and
    $newCertificate -match 'Refusing to overwrite an existing PFX path') `
    'Test-certificate creation can hide incomplete machine-trust rollback.'
Assert-Contract ($removeCertificate -notmatch 'Get-Item[\s\S]{0,100}ErrorAction SilentlyContinue' -and
    $removeCertificate -match 'Certificate removal failed and trust rollback was incomplete' -and
    $removeCertificate -match 'Certificate trust was not restored' -and
    $removeCertificate -match 'DeleteKey') `
    'Test-certificate removal can hide incomplete trust removal or rollback.'
Assert-Contract ($cleanupCallIndex -ge 0 -and
    $absenceCallIndex -gt $cleanupCallIndex -and
    $postCleanupManifestIndex -gt $absenceCallIndex -and
    $secondSignatureValidationIndex -gt $postCleanupManifestIndex -and
    $addDriverIndex -gt $secondSignatureValidationIndex -and
    $install -match 'Remove-WinAirPlayInstallation[\s\S]{0,120}-PreserveInstallerSnapshot \$packageSnapshot' -and
    $install -match 'Assert-WinAirPlayInstallationAbsent[\s\S]{0,120}-PreserveInstallerSnapshot \$packageSnapshot') `
    'Install does not prove full cleanup and re-authenticate the exact preserved package before /add-driver.'
Assert-Contract (-not [string]::IsNullOrWhiteSpace($snapshotCleanupFunction) -and
    $snapshotCleanupFunction -match '\[IO\.Path\]::GetFullPath\(\$PreserveSnapshot\)' -and
    $snapshotCleanupFunction -match '\[IO\.Path\]::GetDirectoryName\(\$preserved\)' -and
    $snapshotCleanupFunction -match '\[IO\.Path\]::GetFileName\(\$preserved\) -cnotmatch ''\^\[0-9a-f\]\{32\}\$''' -and
    $snapshotCleanupFunction -match '\$snapshots[\s\S]{0,600}\.Count -ne 1' -and
    $snapshotCleanupFunction -match 'Installer snapshot cleanup did not preserve exactly the active snapshot') `
    'Shared cleanup does not preserve exactly one canonical active installer snapshot.'
Assert-Contract (-not [string]::IsNullOrWhiteSpace($absenceFunction) -and
    $absenceFunction -match '\$inventory\.UserService' -and
    $absenceFunction -match '\$inventory\.KernelService' -and
    $absenceFunction -match '\$inventory\.FirewallRule' -and
    $absenceFunction -match '\$inventory\.Devices\.Count -ne 0' -and
    $absenceFunction -match '\$inventory\.DriverPackages\.Count -ne 0' -and
    $absenceFunction -match '\$inventory\.RuntimeExists' -and
    $absenceFunction -match '\$inventory\.StateExists' -and
    $absenceFunction -match '\$inventory\.RuntimeTransactions\.Count -ne 0' -and
    $absenceFunction -match '\$inventory\.InstallerSnapshots' -and
    $absenceFunction -match 'WinAirPlayAudio cleanup is incomplete') `
    'The clean-state postcondition does not reject every installed artifact class.'
Assert-Contract (-not [string]::IsNullOrWhiteSpace($installCatch) -and
    $installCatch -match '\$machineMutationStarted -and \$packageSnapshot' -and
    $rollbackCleanupIndex -gt $addDriverIndex -and
    $rollbackAbsenceIndex -gt $rollbackCleanupIndex -and
    $installCatch -match 'Remove-WinAirPlayInstallation[\s\S]{0,180}Assert-WinAirPlayInstallationAbsent' -and
    $installCatch -match 'previous installation was not restored' -and
    $installCatch -match 'Clean rollback was incomplete; the user service was not restarted') `
    'A fresh-install failure does not converge through shared cleanup to the verified clean state.'
Assert-Contract ([regex]::Matches($install, 'Start-Service').Count -eq 1 -and
    $install.IndexOf('Start-Service') -lt $install.IndexOf('catch {') -and
    $installCatch -notmatch 'Start-Service|''start'',\s*\$script:WinAirPlayUserServiceName' -and
    $uninstall -notmatch 'Start-Service|''start'',\s*\$script:WinAirPlayUserServiceName' -and
    $cleanupFunction -notmatch 'Start-Service|''start'',\s*\$script:WinAirPlayUserServiceName' -and
    $uninstallCatch -match 'intentionally not restarted') `
    'Cleanup or install rollback can restart an old user service.'
Assert-Contract ($install -notmatch (
        'Resolve-WinAirPlayInterruptedTransactions|' +
        'Invoke-WinAirPlayAtomicFileReplace|' +
        '\[IO\.File\]::Replace\(|File\.Replace\(|' +
        'Get-WinAirPlayRuntimeRecoveryPlan|' +
        'stateFileBackup|installBackup|deviceBindingsBefore|' +
        'rollbackProvenSafeToRestart|RestoreRollback|preimage')) `
    'Install still contains mixed-version restore, File.Replace, or preimage rollback logic.'
Assert-Contract ($common -match 'function Assert-WinAirPlayRuntimePayload' -and
    $common -match 'Installed runtime payload hash mismatch' -and
    [regex]::Matches($install, 'Assert-WinAirPlayRuntimePayload').Count -ge 3) `
    'Fresh installation does not authenticate staged, published, and final runtime payloads.'
Assert-Contract ($common -match 'function Get-WinAirPlayUserService' -and
    $common -match 'Win32_Service' -and
    $common -match 'ErrorAction Stop' -and
    $install -notmatch 'Get-(CimInstance|Service)[\s\S]{0,120}ErrorAction SilentlyContinue' -and
    $uninstall -notmatch 'Get-(CimInstance|Service)[\s\S]{0,120}ErrorAction SilentlyContinue') `
    'SCM discovery or absence checks can fail open.'
Assert-Contract ($common -match 'driverQueryErrors' -and
    $common -match '\$driverQueryErrors\.Count -ne 0' -and
    $common -match 'failed query can never be interpreted as an empty Driver Store') `
    'Driver Store discovery can treat a non-terminating DISM error as an empty result.'
Assert-Contract ($common -match 'function Test-WinAirPlayServiceDefinition' -and
    $cleanupFunction -match 'Test-WinAirPlayServiceDefinition' -and
    $cleanupFunction -match 'Refusing cleanup because the existing service account or executable path is not owned by WinAirPlayAudio' -and
    $cleanupFunction.IndexOf('Get-WinAirPlayInstallationInventory') -lt
        $cleanupFunction.IndexOf('Stop-Service')) `
    'Shared cleanup does not validate service ownership before destructive SCM actions.'
Assert-Contract (
    $cleanupFunction.IndexOf('Assert-WinAirPlayFirewallRuleOwnership') -gt
        $cleanupFunction.IndexOf('Get-WinAirPlayInstallationInventory') -and
    $cleanupFunction.IndexOf('Assert-WinAirPlayFirewallRuleOwnership') -lt
        $cleanupFunction.IndexOf('Stop-Service') -and
    $cleanupFunction.IndexOf('Remove-WinAirPlayFirewallRule') -gt
        $cleanupFunction.IndexOf('Stop-Service')
) 'Shared cleanup does not validate the exact firewall rule before mutation and remove it after stopping the service.'
Assert-Contract ($common -match 'Get-PnpDeviceProperty[\s\S]{0,120}-ErrorAction Stop' -and
    $common -notmatch "KeyName 'DEVPKEY_Device_HardwareIds'[\s\S]{0,80}ErrorAction SilentlyContinue") `
    'PnP hardware-ID discovery can hide a property-query failure.'
Assert-Contract ($testSigning.IndexOf('if (-not $AcknowledgeBitLockerRecoveryRisk)') -ge 0 -and
    $testSigning.IndexOf('if (-not $AcknowledgeBitLockerRecoveryRisk)') -lt
        $testSigning.IndexOf('Get-Command Get-BitLockerVolume')) `
    'TESTSIGNING can reach BitLocker probing or BCD mutation without explicit recovery-risk acknowledgement.'
Assert-Contract ($install -match 'Enter-WinAirPlayInstallerMutex' -and
    $uninstall -match 'Enter-WinAirPlayInstallerMutex') `
    'Install and uninstall are not serialized by the shared machine-wide mutex.'
Assert-Contract ($common -match 'GetFolderPath' -and
    $common -match 'WinAirPlaySystemDirectory' -and
    $common -notmatch '\$env:(ProgramData|ProgramFiles|windir|SystemDrive)') `
    'Installer roots or native tools still trust mutable inherited environment paths.'
Assert-Contract ($common -match 'Is64BitOperatingSystem' -and
    $common -match 'Is64BitProcess' -and
    $common -match 'OSArchitecture' -and
    $common -match 'ProcessArchitecture' -and
    $common -match 'Architecture\]::X64' -and
    $common -match '64-bit PowerShell 7' -and
    $common -match 'Win32_OperatingSystem' -and
    $common -match 'ProductType') `
    'Privileged tooling can run under WoW64 and diverge across trusted filesystem views.'
Assert-Contract ($common -match 'New-WinAirPlaySecureDirectory' -and
    $common -match 'SetOwner\(\$administrators\)' -and
    $common -match 'Assert-WinAirPlayStateTree') `
    'Installer does not atomically secure and validate its privileged directory trees.'
Assert-Contract ($common -match 'Directory remains after recursive removal') `
    'Scoped directory cleanup does not enforce final absence.'
Assert-Contract ($common -notmatch '\$writeRights[\s\S]{0,300}FileSystemRights\]::FullControl' -and
    $common -notmatch '\$writeRights[\s\S]{0,300}FileSystemRights\]::Modify' -and
    $common -match '0x40000000' -and
    $common -match '0x10000000') `
    'Directory trust validation incorrectly classifies read-only access as write-capable.'
Assert-Contract ($common -notmatch 'Get-Command \$Name' -and
    $common -match 'WinAirPlayPinnedKitPackageVersion' -and
    $common -match 'Microsoft\.Windows\.WDK\.x64' -and
    $common -match 'Inf2CatPath' -and
    $common -match 'PinnedKitToolVersion\)\\x86' -and
    $common -match 'Microsoft\.Windows\.SDK\.CPP' -and
    $common -match 'SignToolPath' -and
    $common -match 'PinnedKitToolVersion\)\\x64' -and
    $common -match '1E8266FBECB18A50B42DDD05A6D4767EA8E5E22A2E834E4334631FC3A7DC1DBE' -and
    $common -match '84AD4A35AC716CF38868B584A7271D5A16DD0B79E125D438F206A32955AC4BD9' -and
    $common -match 'FileShare\]::Read' -and
    $common -match 'Environment\.Clear\(\)' -and
    $common -match 'function Invoke-WinAirPlayAuthenticatedTool' -and
    $signPackage -match 'New-WinAirPlaySigningToolSnapshot' -and
    $signPackage -match 'Invoke-WinAirPlayAuthenticatedTool' -and
    $signPackage -notmatch 'Resolve-WinAirPlayKitTool') `
    'Elevated signing does not authenticate the complete pinned SDK/WDK runtime in protected storage.'
Assert-Contract ($signPackage -match '\$outputOwned = \$true[\s\S]{0,120}New-WinAirPlaySecureDirectory -Path \$outputDirectory' -and
    $signPackage -match 'Test signing failed and rollback was incomplete') `
    'Test signing does not own partial output creation or report incomplete rollback.'
Assert-Contract ($uninstall -match 'Remove-WinAirPlayInstallation[\s\S]{0,160}-RemoveToolCaches' -and
    $cleanupFunction -match '\$RemoveToolCaches' -and
    $cleanupFunction -match 'Remove-WinAirPlaySigningToolSnapshots -RemoveRoot') `
    'Uninstall does not remove protected signing-tool snapshots.'
Assert-Contract ($install -match 'Test-WinAirPlayStagedPackageMatches' -and
    $install -match 'Assert-WinAirPlayDevicesUsePackages') `
    'Install does not prove the exact staged driver package and existing devnode binding.'
Assert-Contract (-not (Test-WinAirPlayFileSystemRightsWriteCapable `
        -Rights ([int64][Security.AccessControl.FileSystemRights]::ReadAndExecute))) `
    'Read-and-execute access is incorrectly rejected as write-capable.'
Assert-Contract (Test-WinAirPlayFileSystemRightsWriteCapable `
        -Rights ([int64][Security.AccessControl.FileSystemRights]::Write)) `
    'Specific file-system write access is not rejected.'
Assert-Contract (Test-WinAirPlayFileSystemRightsWriteCapable -Rights 0x40000000) `
    'GENERIC_WRITE access is not rejected.'
Assert-Contract (Test-WinAirPlayFileSystemRightsWriteCapable -Rights 0x10000000) `
    'GENERIC_ALL access is not rejected.'

function Invoke-InstallerContractFirewallValidation {
    param(
        [string]$Program =
            'C:\Program Files\WinAirPlayAudio\WinAirPlayAudioService.exe',
        [string]$Profile = 'Private',
        [string]$Enabled = 'True',
        [string]$RemoteAddress = 'LocalSubnet'
    )

    $rule = [pscustomobject]@{
        Name = $script:WinAirPlayFirewallRuleName
        DisplayName = $script:WinAirPlayFirewallRuleDisplayName
        Group = $script:WinAirPlayFirewallRuleGroup
        Description = $script:WinAirPlayFirewallRuleDescription
        PolicyStoreSourceType = 'Local'
        Enabled = $Enabled
        Direction = 'Inbound'
        Action = 'Allow'
        Profile = $Profile
        EdgeTraversalPolicy = 'Block'
    }
    & {
        param($FixtureRule, $FixtureProgram, $FixtureRemoteAddress)

        function Get-NetFirewallApplicationFilter {
            process { [pscustomobject]@{ Program = $FixtureProgram } }
        }
        function Get-NetFirewallPortFilter {
            process {
                [pscustomobject]@{
                    Protocol = 'UDP'
                    LocalPort = 'Any'
                    RemotePort = 'Any'
                }
            }
        }
        function Get-NetFirewallAddressFilter {
            process {
                [pscustomobject]@{
                    LocalAddress = 'Any'
                    RemoteAddress = $FixtureRemoteAddress
                }
            }
        }
        function Get-NetFirewallInterfaceTypeFilter {
            process { [pscustomobject]@{ InterfaceType = 'Any' } }
        }
        function Get-NetFirewallServiceFilter {
            process { [pscustomobject]@{ Service = 'Any' } }
        }

        $expectedProgram =
            'C:\Program Files\WinAirPlayAudio\WinAirPlayAudioService.exe'
        [pscustomobject]@{
            Owned = Test-WinAirPlayFirewallRuleOwnership `
                -Rule $FixtureRule `
                -ExpectedExecutablePath $expectedProgram
            DefinitionValid = Test-WinAirPlayFirewallRuleDefinition `
                -Rule $FixtureRule `
                -ExpectedExecutablePath $expectedProgram
        }
    } $rule $Program $RemoteAddress
}

$validFirewall = Invoke-InstallerContractFirewallValidation
Assert-Contract ($validFirewall.Owned -and $validFirewall.DefinitionValid) `
    'Exact program-scoped Private/LocalSubnet UDP firewall fixture was rejected.'
foreach ($invalidFirewall in @(
        [pscustomobject]@{
            Name = 'Public profile'
            Result = Invoke-InstallerContractFirewallValidation -Profile Public
            MustRemainOwned = $true
        },
        [pscustomobject]@{
            Name = 'remote Any'
            Result = Invoke-InstallerContractFirewallValidation -RemoteAddress Any
            MustRemainOwned = $true
        },
        [pscustomobject]@{
            Name = 'disabled'
            Result = Invoke-InstallerContractFirewallValidation -Enabled False
            MustRemainOwned = $true
        },
        [pscustomobject]@{
            Name = 'different program'
            Result = Invoke-InstallerContractFirewallValidation `
                -Program 'C:\Windows\System32\not-owned.exe'
            MustRemainOwned = $false
        })) {
    Assert-Contract (-not $invalidFirewall.Result.DefinitionValid -and
        $invalidFirewall.Result.Owned -eq
            $invalidFirewall.MustRemainOwned) `
        "Firewall ownership/definition validation mishandled $($invalidFirewall.Name)."
}

$runtimePayloadTestRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "WinAirPlayAudio-runtime-payload-$([Guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($runtimePayloadTestRoot) | Out-Null
    $runtimeFixtureNames = @(Get-WinAirPlayRuntimeFileNames)
    $manifestFixtureEntries = [Collections.Generic.List[object]]::new()
    foreach ($name in @(Get-WinAirPlayPackageFileNames |
            Where-Object { $_ -cne 'package-manifest.json' })) {
        if ($name -in $runtimeFixtureNames) {
            $fixturePath = Join-Path $runtimePayloadTestRoot $name
            [IO.File]::WriteAllText($fixturePath, "fixture:$name")
            $fixtureHash = (Get-FileHash `
                    -LiteralPath $fixturePath `
                    -Algorithm SHA256).Hash
        }
        else {
            $fixtureHash = ('0' * 64) -join ''
        }
        $manifestFixtureEntries.Add([pscustomobject]@{
                Name = $name
                Sha256 = $fixtureHash
            })
    }
    $manifestFixture = [pscustomobject]@{
        SchemaVersion = 1
        Configuration = 'Debug'
        Platform = 'x64'
        HardwareId = 'ROOT\WinAirPlayAudio'
        UserService = 'WinAirPlayAudioService'
        Files = @($manifestFixtureEntries)
    } | ConvertTo-Json -Depth 5
    $manifestFixturePath = Join-Path `
        $runtimePayloadTestRoot `
        'package-manifest.json'
    [IO.File]::WriteAllText($manifestFixturePath, $manifestFixture)
    $manifestFixtureHash = (Get-FileHash `
            -LiteralPath $manifestFixturePath `
            -Algorithm SHA256).Hash

    & {
        param($RuntimeDirectory, $ExpectedHash)
        function Assert-WinAirPlayTrustedDirectory {
            param(
                [string]$Path,
                [switch]$RequireProtectedDacl
            )
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Runtime fixture is not a regular directory: $Path"
            }
        }
        Assert-WinAirPlayRuntimePayload `
            -RuntimeDirectory $RuntimeDirectory `
            -ExpectedManifestSha256 $ExpectedHash
    } $runtimePayloadTestRoot $manifestFixtureHash

    [IO.File]::AppendAllText(
        (Join-Path $runtimePayloadTestRoot $script:WinAirPlayServiceExecutable),
        'tampered')
    $tamperedRuntimeRejected = $false
    try {
        & {
            param($RuntimeDirectory, $ExpectedHash)
            function Assert-WinAirPlayTrustedDirectory {
                param(
                    [string]$Path,
                    [switch]$RequireProtectedDacl
                )
            }
            Assert-WinAirPlayRuntimePayload `
                -RuntimeDirectory $RuntimeDirectory `
                -ExpectedManifestSha256 $ExpectedHash
        } $runtimePayloadTestRoot $manifestFixtureHash
    }
    catch {
        $tamperedRuntimeRejected = $true
    }
    Assert-Contract $tamperedRuntimeRejected `
        'Runtime payload validation accepted bytes that do not match the authenticated manifest.'
}
catch {
    $failures.Add("Runtime payload authentication behavior failed: $($_.Exception.Message)")
}
finally {
    if (Test-Path -LiteralPath $runtimePayloadTestRoot) {
        [IO.Directory]::Delete($runtimePayloadTestRoot, $true)
    }
}

$snapshotPreservationTestRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "WinAirPlayAudio-snapshot-preservation-$([Guid]::NewGuid().ToString('N'))"
$originalInstallerStagingRoot = $script:WinAirPlayInstallerStagingRoot
try {
    $script:WinAirPlayInstallerStagingRoot = $snapshotPreservationTestRoot
    [IO.Directory]::CreateDirectory($snapshotPreservationTestRoot) | Out-Null
    $activeSnapshot = Join-Path $snapshotPreservationTestRoot (('a' * 32) -join '')
    $staleSnapshot = Join-Path $snapshotPreservationTestRoot (('b' * 32) -join '')
    [IO.Directory]::CreateDirectory($activeSnapshot) | Out-Null
    [IO.Directory]::CreateDirectory($staleSnapshot) | Out-Null
    $activeMarker = Join-Path $activeSnapshot 'package-manifest.json'
    [IO.File]::WriteAllText($activeMarker, '{"active":true}')
    [IO.File]::WriteAllText(
        (Join-Path $staleSnapshot 'package-manifest.json'),
        '{"active":false}')
    $activeMarkerHash = (Get-FileHash `
            -LiteralPath $activeMarker `
            -Algorithm SHA256).Hash

    & {
        param($Snapshot)

        function Assert-WinAirPlayTrustedDirectory {
            param(
                [string]$Path,
                [switch]$RequireProtectedDacl
            )
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Snapshot fixture is not a regular directory: $Path"
            }
        }

        Remove-WinAirPlayInstallerSnapshots -PreserveSnapshot $Snapshot
    } $activeSnapshot

    $remainingSnapshots = @(Get-ChildItem `
            -LiteralPath $snapshotPreservationTestRoot `
            -Force `
            -ErrorAction Stop)
    Assert-Contract ($remainingSnapshots.Count -eq 1 -and
        [StringComparer]::OrdinalIgnoreCase.Equals(
            $remainingSnapshots[0].FullName,
            $activeSnapshot)) `
        'Snapshot cleanup did not preserve exactly the active package snapshot.'
    Assert-Contract ((Get-FileHash `
                -LiteralPath $activeMarker `
                -Algorithm SHA256).Hash -ceq $activeMarkerHash) `
        'Snapshot cleanup changed the authenticated active package bytes.'

    $preservedInventory = [pscustomobject]@{
        UserService = $null
        KernelService = $null
        FirewallRule = $null
        Devices = @()
        DriverPackages = @()
        RuntimeTransactions = @()
        InstallerSnapshots = @(
            [pscustomobject]@{ FullName = $activeSnapshot }
        )
        RuntimeExists = $false
        StateExists = $false
        InstallerRootExists = $true
    }
    & {
        param($Inventory, $Snapshot)

        function Get-WinAirPlayInstallationInventory {
            return $Inventory
        }

        Assert-WinAirPlayInstallationAbsent `
            -PreserveInstallerSnapshot $Snapshot
    } $preservedInventory $activeSnapshot

    $extraSnapshotInventory = $preservedInventory.PSObject.Copy()
    $extraSnapshotInventory.InstallerSnapshots = @(
        [pscustomobject]@{ FullName = $activeSnapshot },
        [pscustomobject]@{
            FullName = Join-Path `
                $snapshotPreservationTestRoot `
                (('c' * 32) -join '')
        }
    )
    $extraSnapshotRejected = $false
    try {
        & {
            param($Inventory, $Snapshot)

            function Get-WinAirPlayInstallationInventory {
                return $Inventory
            }

            Assert-WinAirPlayInstallationAbsent `
                -PreserveInstallerSnapshot $Snapshot
        } $extraSnapshotInventory $activeSnapshot
    }
    catch {
        $extraSnapshotRejected = $true
    }
    Assert-Contract $extraSnapshotRejected `
        'Clean-state validation accepted snapshots in addition to the exact active package.'
}
catch {
    $failures.Add("Active package-snapshot preservation behavior failed: $($_.Exception.Message)")
}
finally {
    $script:WinAirPlayInstallerStagingRoot = $originalInstallerStagingRoot
    if (Test-Path -LiteralPath $snapshotPreservationTestRoot) {
        [IO.Directory]::Delete($snapshotPreservationTestRoot, $true)
    }
}

function New-InstallerContractCleanInventory {
    [pscustomobject]@{
        UserService = $null
        KernelService = $null
        FirewallRule = $null
        Devices = @()
        DriverPackages = @()
        RuntimeTransactions = @()
        InstallerSnapshots = @()
        RuntimeExists = $false
        StateExists = $false
        InstallerRootExists = $false
    }
}

try {
    $cleanInventory = New-InstallerContractCleanInventory
    & {
        param($Inventory)

        function Get-WinAirPlayInstallationInventory {
            return $Inventory
        }

        Assert-WinAirPlayInstallationAbsent
    } $cleanInventory

    $dirtyInventories = [Collections.Generic.List[object]]::new()
    foreach ($case in @(
            [pscustomobject]@{
                Name = 'user service'
                Property = 'UserService'
                Value = [pscustomobject]@{ Name = 'WinAirPlayAudioService' }
            },
            [pscustomobject]@{
                Name = 'kernel service'
                Property = 'KernelService'
                Value = [pscustomobject]@{ Name = 'WinAirPlayAudio' }
            },
            [pscustomobject]@{
                Name = 'Windows Firewall rule'
                Property = 'FirewallRule'
                Value = [pscustomobject]@{ Name = 'WinAirPlayAudio.RaopUdpIn' }
            },
            [pscustomobject]@{
                Name = 'devnode'
                Property = 'Devices'
                Value = @([pscustomobject]@{ InstanceId = 'SWD\WinAirPlayAudio\WAPA_A' })
            },
            [pscustomobject]@{
                Name = 'Driver Store package'
                Property = 'DriverPackages'
                Value = @([pscustomobject]@{ PublishedName = 'oem10.inf' })
            },
            [pscustomobject]@{
                Name = 'runtime transaction'
                Property = 'RuntimeTransactions'
                Value = @([pscustomobject]@{ FullName = 'fixture-runtime-transaction' })
            },
            [pscustomobject]@{
                Name = 'runtime directory'
                Property = 'RuntimeExists'
                Value = $true
            },
            [pscustomobject]@{
                Name = 'state directory'
                Property = 'StateExists'
                Value = $true
            },
            [pscustomobject]@{
                Name = 'installer snapshot root'
                Property = 'InstallerRootExists'
                Value = $true
            })) {
        $dirtyInventory = (New-InstallerContractCleanInventory).PSObject.Copy()
        $dirtyInventory.($case.Property) = $case.Value
        $dirtyInventories.Add([pscustomobject]@{
                Name = $case.Name
                Inventory = $dirtyInventory
            })
    }

    foreach ($case in $dirtyInventories) {
        $residueRejected = $false
        try {
            & {
                param($Inventory)

                function Get-WinAirPlayInstallationInventory {
                    return $Inventory
                }

                Assert-WinAirPlayInstallationAbsent
            } $case.Inventory
        }
        catch {
            $residueRejected = $true
        }
        Assert-Contract $residueRejected `
            "Clean-state validation accepted remaining $($case.Name)."
    }
}
catch {
    $failures.Add("Installation-absence postcondition behavior failed: $($_.Exception.Message)")
}

# Load only the pure inventory conversion function; never execute package builds.
$inventoryTokens = $null
$inventoryErrors = $null
$packageAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'package.ps1'),
    [ref]$inventoryTokens,
    [ref]$inventoryErrors)
$inventoryFunctions = @($packageAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'ConvertTo-WinAirPlayPublicCargoMetadata'
    }, $true))
Assert-Contract ($inventoryFunctions.Count -eq 1) `
    'Packaging must define exactly one pure public Cargo-inventory converter.'
if ($inventoryFunctions.Count -eq 1) {
    try {
        . ([scriptblock]::Create($inventoryFunctions[0].Extent.Text))
        $inventoryFixtureJson = @'
{
  "version": 1,
  "workspace_root": "C:\\Builder Alice\\repo",
  "target_directory": "C:\\Builder Alice\\repo\\target",
  "packages": [
    {
      "id": "path+file:///C:/Builder%20Alice/repo/service#winairplay-service@0.1.0",
      "name": "winairplay-service", "version": "0.1.0", "source": null,
      "license": "MIT", "manifest_path": "C:\\Builder Alice\\repo\\service\\Cargo.toml",
      "metadata": { "private_path": "C:\\Builder Alice\\private" },
      "targets": [ { "src_path": "C:\\Builder Alice\\repo\\service\\src\\main.rs" } ]
    },
    {
      "id": "registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229",
      "name": "serde", "version": "1.0.229",
      "source": "registry+https://github.com/rust-lang/crates.io-index",
      "license": "MIT OR Apache-2.0",
      "manifest_path": "C:\\Builder Alice\\.cargo\\registry\\src\\serde-1.0.229\\Cargo.toml"
    }
  ],
  "workspace_members": [ "path+file:///C:/Builder%20Alice/repo/service#winairplay-service@0.1.0" ],
  "resolve": {
    "root": null,
    "nodes": [
      {
        "id": "path+file:///C:/Builder%20Alice/repo/service#winairplay-service@0.1.0",
        "dependencies": [ "registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229" ],
        "deps": [ {
          "name": "serde", "pkg": "registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229",
          "dep_kinds": [ { "kind": null, "target": "cfg(windows)" } ]
        } ],
        "features": [ "default" ]
      },
      {
        "id": "registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229",
        "dependencies": [], "deps": [], "features": [ "std", "derive" ]
      }
    ]
  }
}
'@
        $inventoryFixture = $inventoryFixtureJson | ConvertFrom-Json -Depth 100
        $publicInventory = ConvertTo-WinAirPlayPublicCargoMetadata -Metadata $inventoryFixture
        $publicInventoryJson = $publicInventory | ConvertTo-Json -Depth 100 -Compress
        Assert-Contract ($publicInventoryJson -notmatch
            'Builder|\.cargo|file:///|manifest_path|src_path|target_directory|workspace_root|private_path') `
            'Published Cargo inventory leaks local build/registry paths or arbitrary private metadata.'
        Assert-Contract ($publicInventory.packages.Count -eq 2 -and
            $publicInventory.workspace_members.Count -eq 1 -and
            $publicInventory.workspace_members[0] -ceq 'workspace+winairplay-service@0.1.0') `
            'Published Cargo inventory lost package coordinates or stable workspace identifiers.'
        $serviceInventoryNode = @($publicInventory.resolve.nodes |
            Where-Object id -CEQ 'workspace+winairplay-service@0.1.0')[0]
        Assert-Contract ($serviceInventoryNode.dependencies.Count -eq 1 -and
            $serviceInventoryNode.deps[0].pkg -ceq
                'registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229' -and
            $serviceInventoryNode.deps[0].dep_kinds[0].target -ceq 'cfg(windows)' -and
            $serviceInventoryNode.features[0] -ceq 'default') `
            'Published Cargo inventory lost resolved dependency edges, target conditions, or enabled features.'
        $otherRootFixture = $inventoryFixtureJson.Replace('Builder Alice', 'Other Builder').Replace(
            'Builder%20Alice', 'Other%20Builder') | ConvertFrom-Json -Depth 100
        $otherRootInventoryJson = ConvertTo-WinAirPlayPublicCargoMetadata -Metadata $otherRootFixture |
            ConvertTo-Json -Depth 100 -Compress
        Assert-Contract ($publicInventoryJson -ceq $otherRootInventoryJson) `
            'Portable Cargo inventory changes when only the builder/registry root changes.'

        foreach ($invalidInventory in @(
                'unknown graph reference', 'local file source',
                'credential-bearing source', 'duplicate coordinates')) {
            $invalidFixture = $inventoryFixtureJson | ConvertFrom-Json -Depth 100
            switch ($invalidInventory) {
                'unknown graph reference' { $invalidFixture.resolve.nodes[0].dependencies = @('missing') }
                'local file source' { $invalidFixture.packages[1].source = 'git+file:///C:/Builder/private' }
                'credential-bearing source' {
                    $invalidFixture.packages[1].source = 'git+https://user:fixture-secret@example.invalid/source'
                }
                'duplicate coordinates' {
                    $duplicatePackage = $invalidFixture.packages[0].PSObject.Copy()
                    $duplicatePackage.id = 'different-local-id'
                    $invalidFixture.packages += $duplicatePackage
                }
            }
            $invalidInventoryRejected = $false
            try {
                $null = ConvertTo-WinAirPlayPublicCargoMetadata -Metadata $invalidFixture
            }
            catch {
                $invalidInventoryRejected = $true
            }
            Assert-Contract $invalidInventoryRejected `
                "Published Cargo inventory accepted $invalidInventory."
        }
    }
    catch {
        $failures.Add("Portable Cargo inventory behavior failed: $($_.Exception.Message)")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "$($failures.Count) installer contract check(s) failed."
}

Write-Host 'WinAirPlayAudio installer contract checks passed.'
