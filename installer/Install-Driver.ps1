[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$PackageDirectory,

    [Parameter(Mandatory)]
    [string]$ExpectedSignedManifestSha256,

    [string]$ExpectedSignerThumbprint,

    [string]$ExpectedCatalogSignerThumbprint,

    [string]$ExpectedExecutableSignerThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-WinAirPlayTarget
$expectedSignedManifestHash =
    $ExpectedSignedManifestSha256.Replace(' ', '').ToUpperInvariant()
if ($expectedSignedManifestHash -cnotmatch '^[0-9A-F]{64}$') {
    throw "Expected signed manifest hash must contain exactly 64 hexadecimal characters: '$expectedSignedManifestHash'"
}

$usingLegacySigner = -not [string]::IsNullOrWhiteSpace(
    $ExpectedSignerThumbprint)
$usingSplitSigners =
    -not [string]::IsNullOrWhiteSpace($ExpectedCatalogSignerThumbprint) -or
    -not [string]::IsNullOrWhiteSpace($ExpectedExecutableSignerThumbprint)
if ($usingLegacySigner -and $usingSplitSigners) {
    throw 'Use either -ExpectedSignerThumbprint or both split signer parameters, not both forms.'
}
if ($usingLegacySigner) {
    $ExpectedCatalogSignerThumbprint = $ExpectedSignerThumbprint
    $ExpectedExecutableSignerThumbprint = $ExpectedSignerThumbprint
}
elseif ([string]::IsNullOrWhiteSpace($ExpectedCatalogSignerThumbprint) -or
    [string]::IsNullOrWhiteSpace($ExpectedExecutableSignerThumbprint)) {
    throw 'Specify -ExpectedSignerThumbprint for test signing, or both -ExpectedCatalogSignerThumbprint and -ExpectedExecutableSignerThumbprint for production.'
}

$sourcePackageDirectory =
    (Resolve-Path -LiteralPath $PackageDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $sourcePackageDirectory -PathType Container)) {
    throw "Package source is not a directory: $sourcePackageDirectory"
}
Assert-WinAirPlayAdministrator -WhatIfOnly:$WhatIfPreference

if (-not $PSCmdlet.ShouldProcess(
        "$sourcePackageDirectory on $env:COMPUTERNAME",
        "Validate signed manifest $expectedSignedManifestHash, permanently remove any existing WinAirPlayAudio installation including configuration/credentials/logs, verify a clean machine state, then install and start the supplied package")) {
    return
}

$installerMutex = Enter-WinAirPlayInstallerMutex
$packageSnapshot = $null
$machineMutationStarted = $false
try {
    $installationDetected = Test-WinAirPlayInstallationPresent
    $packageSnapshot =
        New-WinAirPlayPackageSnapshot -SourceDirectory $sourcePackageDirectory

    $actualSignedManifestHash = (Get-FileHash `
            -LiteralPath (Join-Path $packageSnapshot 'package-manifest.json') `
            -Algorithm SHA256 `
            -ErrorAction Stop).Hash
    if ($actualSignedManifestHash -cne $expectedSignedManifestHash) {
        throw "Signed package manifest hash '$actualSignedManifestHash' does not match the independently trusted hash '$expectedSignedManifestHash'."
    }
    $package = Resolve-WinAirPlayPackage -PackageDirectory $packageSnapshot
    Assert-WinAirPlayPackageSignature `
        -Package $package `
        -ExpectedCatalogSignerThumbprint $ExpectedCatalogSignerThumbprint `
        -ExpectedExecutableSignerThumbprint $ExpectedExecutableSignerThumbprint
    $packageInfIdentity = Get-WinAirPlayInfIdentity -InfPath $package.Inf

    if ($installationDetected) {
        Write-Host 'Existing WinAirPlayAudio artifacts detected; performing a verified full uninstall before installation.'
    }
    $machineMutationStarted = $true
    Remove-WinAirPlayInstallation `
        -PreserveInstallerSnapshot $packageSnapshot
    Assert-WinAirPlayInstallationAbsent `
        -PreserveInstallerSnapshot $packageSnapshot

    # The uninstall must not be able to change the authenticated input that it
    # preserved. Revalidate the protected snapshot before staging any driver.
    $postCleanupManifestHash = (Get-FileHash `
            -LiteralPath (Join-Path $packageSnapshot 'package-manifest.json') `
            -Algorithm SHA256 `
            -ErrorAction Stop).Hash
    if ($postCleanupManifestHash -cne $expectedSignedManifestHash) {
        throw 'The protected signed package changed during existing-install cleanup.'
    }
    $package = Resolve-WinAirPlayPackage -PackageDirectory $packageSnapshot
    Assert-WinAirPlayPackageSignature `
        -Package $package `
        -ExpectedCatalogSignerThumbprint $ExpectedCatalogSignerThumbprint `
        -ExpectedExecutableSignerThumbprint $ExpectedExecutableSignerThumbprint
    $packageInfIdentity = Get-WinAirPlayInfIdentity -InfPath $package.Inf

    $pnputil = Join-Path $script:WinAirPlaySystemDirectory 'pnputil.exe'
    $sc = Join-Path $script:WinAirPlaySystemDirectory 'sc.exe'
    $icacls = Join-Path $script:WinAirPlaySystemDirectory 'icacls.exe'
    $installedService = Join-Path `
        $script:WinAirPlayInstallDirectory `
        $script:WinAirPlayServiceExecutable
    $configurationPath =
        Join-Path $script:WinAirPlayStateDirectory 'config.json'
    $credentialDirectory =
        Join-Path $script:WinAirPlayStateDirectory 'credentials'
    $transactionId = [Guid]::NewGuid().ToString('N')
    $installStaging =
        "$($script:WinAirPlayInstallDirectory).staging-$transactionId"
    $stateFileStaging =
        "$($script:WinAirPlayStateFile).staging-$transactionId"

    $output = Invoke-WinAirPlayNative `
        -FilePath $pnputil `
        -ArgumentList @('/add-driver', $package.Inf, '/install')
    $output | ForEach-Object { Write-Host $_ }

    $stagedPackages = @(Get-WinAirPlayDriverPackages)
    $matchingPackages = @($stagedPackages | Where-Object {
            Test-WinAirPlayStagedPackageMatches `
                -Driver $_ `
                -Package $package `
                -InfIdentity $packageInfIdentity
        })
    if ($stagedPackages.Count -ne 1 -or $matchingPackages.Count -ne 1) {
        throw 'PnPUtil did not leave exactly one Driver Store package matching the signed INF/SYS/catalog bytes and DriverVer.'
    }
    $matchingPublishedNames =
        @($matchingPackages | ForEach-Object PublishedName)

    New-WinAirPlaySecureDirectory `
        -Path $script:WinAirPlayStateDirectory `
        -UsersReadExecute
    Copy-Item `
        -LiteralPath (Join-Path $package.Directory 'config.example.json') `
        -Destination $configurationPath
    New-WinAirPlaySecureDirectory -Path $credentialDirectory
    Invoke-WinAirPlayNative -FilePath $icacls -ArgumentList @(
        $script:WinAirPlayStateDirectory,
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        '*S-1-5-32-545:(OI)(CI)RX'
    ) | ForEach-Object { Write-Host $_ }
    Invoke-WinAirPlayNative -FilePath $icacls -ArgumentList @(
        $credentialDirectory,
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F'
    ) | ForEach-Object { Write-Host $_ }

    New-WinAirPlaySecureDirectory -Path $installStaging -UsersReadExecute
    foreach ($name in @(Get-WinAirPlayRuntimeFileNames)) {
        $source = Join-Path $package.Directory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Complete package is missing runtime file: $source"
        }
        Copy-Item `
            -LiteralPath $source `
            -Destination (Join-Path $installStaging $name)
    }
    Invoke-WinAirPlayNative -FilePath $icacls -ArgumentList @(
        $installStaging,
        '/inheritance:r',
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F',
        '*S-1-5-32-544:(OI)(CI)F',
        '*S-1-5-32-545:(OI)(CI)RX'
    ) | ForEach-Object { Write-Host $_ }
    Assert-WinAirPlayRuntimePayload `
        -RuntimeDirectory $installStaging `
        -ExpectedManifestSha256 $expectedSignedManifestHash
    Move-Item `
        -LiteralPath $installStaging `
        -Destination $script:WinAirPlayInstallDirectory
    Assert-WinAirPlayRuntimePayload `
        -RuntimeDirectory $script:WinAirPlayInstallDirectory `
        -ExpectedManifestSha256 $expectedSignedManifestHash

    if (Get-WinAirPlayUserService) {
        throw 'The WinAirPlayAudio user service reappeared after verified cleanup.'
    }
    $quotedService = '"' + $installedService + '"'
    Invoke-WinAirPlayNative -FilePath $sc -ArgumentList @(
        'create', $script:WinAirPlayUserServiceName,
        'binPath=', $quotedService,
        'start=', 'auto',
        'obj=', 'LocalSystem',
        'DisplayName=', 'WinAirPlayAudio Receiver Service'
    ) | ForEach-Object { Write-Host $_ }
    Invoke-WinAirPlayNative -FilePath $sc -ArgumentList @(
        'failure', $script:WinAirPlayUserServiceName,
        'reset=', '86400',
        'actions=', 'restart/5000/restart/30000'
    ) | ForEach-Object { Write-Host $_ }
    Invoke-WinAirPlayNative -FilePath $sc -ArgumentList @(
        'failureflag', $script:WinAirPlayUserServiceName, '1'
    ) | ForEach-Object { Write-Host $_ }
    Invoke-WinAirPlayNative -FilePath $sc -ArgumentList @(
        'description', $script:WinAirPlayUserServiceName,
        'Discovers compatible RAOP receivers and owns their virtual audio endpoints.'
    ) | ForEach-Object { Write-Host $_ }

    $firewallRule = New-WinAirPlayFirewallRule `
        -ExpectedExecutablePath $installedService

    Start-Service -Name $script:WinAirPlayUserServiceName -ErrorAction Stop
    $startedService =
        Get-Service -Name $script:WinAirPlayUserServiceName -ErrorAction Stop
    try {
        $startedService.WaitForStatus(
            'Running',
            [TimeSpan]::FromSeconds(30))
        Start-Sleep -Seconds 2
        $startedService.Refresh()
        if ($startedService.Status -ne 'Running') {
            throw 'The service reported Running but did not remain running through the startup health window.'
        }
    }
    finally {
        $startedService.Dispose()
    }

    $runningServiceInfo = Get-WinAirPlayUserService
    if (-not $runningServiceInfo -or
        $runningServiceInfo.State -ne 'Running' -or
        -not (Test-WinAirPlayServiceDefinition `
                -Service $runningServiceInfo `
                -ExpectedExecutablePath $installedService)) {
        throw 'The fresh user service is not running with the expected LocalSystem executable definition.'
    }
    Assert-WinAirPlayFirewallRuleDefinition `
        -Rule $firewallRule `
        -ExpectedExecutablePath $installedService
    Assert-WinAirPlayDevicesUsePackages `
        -PublishedNames $matchingPublishedNames

    $stateRecord = [pscustomobject]@{
        SchemaVersion = 1
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        SourceInf =
            Join-Path $sourcePackageDirectory $script:WinAirPlayDriverInfName
        PublishedNames = @($matchingPublishedNames)
        PackageManifestSha256 = $expectedSignedManifestHash
        CatalogSignerThumbprint =
            $ExpectedCatalogSignerThumbprint.Replace(
                ' ',
                '').ToUpperInvariant()
        ExecutableSignerThumbprint =
            $ExpectedExecutableSignerThumbprint.Replace(
                ' ',
                '').ToUpperInvariant()
        ServicePath = $installedService
    } | ConvertTo-Json -Depth 3
    $stateRecord |
        Set-Content -LiteralPath $stateFileStaging -Encoding UTF8
    Assert-WinAirPlayInstallStateRecord -Path $stateFileStaging
    if (Test-Path -LiteralPath $script:WinAirPlayStateFile) {
        throw 'Install-state destination reappeared after verified cleanup.'
    }
    Move-Item `
        -LiteralPath $stateFileStaging `
        -Destination $script:WinAirPlayStateFile
    $committedState = Assert-WinAirPlayInstallStateRecord `
        -Path $script:WinAirPlayStateFile `
        -PassThru
    if ([string]$committedState.PackageManifestSha256 -cne
        $expectedSignedManifestHash) {
        throw 'Committed install state does not contain the signed package manifest hash.'
    }
    Assert-WinAirPlayStateTree

    Assert-WinAirPlayRuntimePayload `
        -RuntimeDirectory $script:WinAirPlayInstallDirectory `
        -ExpectedManifestSha256 $expectedSignedManifestHash
    $finalPackages = @(Get-WinAirPlayDriverPackages)
    if ($finalPackages.Count -ne 1 -or
        -not (Test-WinAirPlayStagedPackageMatches `
                -Driver $finalPackages[0] `
                -Package $package `
                -InfIdentity $packageInfIdentity)) {
        throw 'Final Driver Store postcondition does not contain exactly the signed package.'
    }
    if (@(Get-WinAirPlayRuntimeTransactionDirectories).Count -ne 0) {
        throw 'Fresh installation left a runtime transaction directory.'
    }
    Assert-WinAirPlayDevicesUsePackages `
        -PublishedNames $matchingPublishedNames
    $finalServiceInfo = Get-WinAirPlayUserService
    if (-not $finalServiceInfo -or
        $finalServiceInfo.State -ne 'Running' -or
        -not (Test-WinAirPlayServiceDefinition `
                -Service $finalServiceInfo `
                -ExpectedExecutablePath $installedService)) {
        throw 'Final service postcondition is not Running with the expected LocalSystem executable definition.'
    }
    $finalFirewallRule = Get-WinAirPlayFirewallRule
    if (-not $finalFirewallRule) {
        throw 'Final Windows Firewall postcondition is missing the RAOP UDP rule.'
    }
    Assert-WinAirPlayFirewallRuleDefinition `
        -Rule $finalFirewallRule `
        -ExpectedExecutablePath $installedService

    Write-Host 'WinAirPlayAudio driver, user service, and scoped RAOP UDP firewall rule are installed.'
    Write-Host "Configuration: $configurationPath"
}
catch {
    $installFailure = $_
    if ($machineMutationStarted -and $packageSnapshot) {
        try {
            if (Test-Path -LiteralPath $packageSnapshot -PathType Container) {
                Remove-WinAirPlayInstallation `
                    -PreserveInstallerSnapshot $packageSnapshot
                Assert-WinAirPlayInstallationAbsent `
                    -PreserveInstallerSnapshot $packageSnapshot
            }
            else {
                Remove-WinAirPlayInstallation
                Assert-WinAirPlayInstallationAbsent
            }
            Write-Warning 'Install failed; any previous installation was not restored, and all partial new installation artifacts were removed.'
        }
        catch {
            $cleanupFailure = $_
            throw [InvalidOperationException]::new(
                "Install failed: $($installFailure.Exception.Message)$([Environment]::NewLine)Clean rollback was incomplete; the user service was not restarted.$([Environment]::NewLine)$($cleanupFailure.Exception.Message)",
                $installFailure.Exception)
        }
    }
    throw $installFailure
}
finally {
    if ($packageSnapshot) {
        try {
            Remove-WinAirPlayPackageSnapshot `
                -SnapshotDirectory $packageSnapshot
        }
        catch {
            Write-Warning "Protected package snapshot cleanup failed: $($_.Exception.Message)"
        }
    }
    Exit-WinAirPlayInstallerMutex -Mutex $installerMutex
}
