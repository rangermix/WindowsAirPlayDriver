[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory)]
    [switch]$ConfirmRemoval,

    [switch]$RemovePrivateKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $ConfirmRemoval) {
    throw 'Certificate cleanup requires the explicit -ConfirmRemoval switch.'
}

Assert-WinAirPlayTarget
Assert-WinAirPlayAdministrator -WhatIfOnly:$WhatIfPreference

$thumbprint = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
if ($thumbprint -cnotmatch '^[0-9A-F]{40}$') {
    throw "Certificate thumbprint must contain exactly 40 hexadecimal characters: '$thumbprint'"
}
$targets = @(
    [pscustomobject]@{ Store = 'Root'; Path = "Cert:\LocalMachine\Root\$thumbprint"; Private = $false },
    [pscustomobject]@{ Store = 'TrustedPublisher'; Path = "Cert:\LocalMachine\TrustedPublisher\$thumbprint"; Private = $false }
)
if ($RemovePrivateKey) {
    $targets += [pscustomobject]@{ Store = 'My'; Path = "Cert:\LocalMachine\My\$thumbprint"; Private = $true }
}

$codeSigningOid = '1.3.6.1.5.5.7.3.3'
foreach ($target in $targets) {
    if (-not (Test-Path -LiteralPath $target.Path -ErrorAction Stop)) {
        continue
    }
    $candidate = Get-Item -LiteralPath $target.Path -ErrorAction Stop
    $hasCodeSigningEku = $candidate.Extensions |
        Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } |
        Where-Object { $_.Value -eq $codeSigningOid }
    if ($candidate.FriendlyName -cne 'WinAirPlayAudio driver test signing' -or
        -not $hasCodeSigningEku) {
        throw "Refusing to remove a certificate that was not created by the WinAirPlayAudio test-signing workflow: $($target.Path)"
    }
}

if (-not $PSCmdlet.ShouldProcess(
        (($targets | ForEach-Object { $_.Path }) -join ', '),
        'Remove WinAirPlayAudio test-certificate trust' +
            $(if ($RemovePrivateKey) { ' and delete its machine private key' } else { '' }))) {
    return
}

$rollbackCertificate = @(@(
    "Cert:\LocalMachine\My\$thumbprint",
    "Cert:\LocalMachine\Root\$thumbprint",
    "Cert:\LocalMachine\TrustedPublisher\$thumbprint"
) | ForEach-Object {
    if (Test-Path -LiteralPath $_ -ErrorAction Stop) {
        Get-Item -LiteralPath $_ -ErrorAction Stop
    }
}) | Select-Object -First 1
$removedTrustStores = [Collections.Generic.List[string]]::new()
$removedPaths = [Collections.Generic.List[string]]::new()

try {
    foreach ($target in $targets) {
        if (Test-Path -LiteralPath $target.Path -ErrorAction Stop) {
            if (-not $target.Private) {
                # Track before the destructive write so a partial/throwing
                # provider operation is still included in trust restoration.
                $removedTrustStores.Add($target.Store)
            }
            if ($target.Private) {
                Remove-Item `
                    -LiteralPath $target.Path `
                    -Force `
                    -DeleteKey `
                    -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $target.Path -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $target.Path -ErrorAction Stop) {
                throw "Certificate remains after removal: $($target.Path)"
            }
            $removedPaths.Add($target.Path)
        }
    }
}
catch {
    $removalFailure = $_
    $rollbackProblems = [Collections.Generic.List[string]]::new()
    if ($rollbackCertificate) {
        foreach ($storeName in @($removedTrustStores | Select-Object -Unique)) {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new(
                $storeName,
                [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
            try {
                $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $store.Add($rollbackCertificate)
            }
            catch {
                $rollbackProblems.Add(
                    "Certificate trust rollback failed for '$storeName': $($_.Exception.Message)")
            }
            finally {
                $store.Close()
            }
            $restoredPath = "Cert:\LocalMachine\$storeName\$thumbprint"
            try {
                if (-not (Test-Path -LiteralPath $restoredPath -ErrorAction Stop)) {
                    throw "Certificate trust was not restored: $restoredPath"
                }
            }
            catch {
                $rollbackProblems.Add(
                    "Certificate trust verification failed for '$storeName': $($_.Exception.Message)")
            }
        }
    }
    elseif ($removedTrustStores.Count -ne 0) {
        $rollbackProblems.Add('Certificate trust was removed, but no exact certificate remained available for rollback.')
    }
    if ($rollbackProblems.Count -ne 0) {
        $detail = $rollbackProblems -join [Environment]::NewLine
        throw [InvalidOperationException]::new(
            "Certificate removal failed and trust rollback was incomplete.$([Environment]::NewLine)$detail",
            $removalFailure.Exception)
    }
    throw $removalFailure
}

foreach ($path in $removedPaths) {
    Write-Host "Removed $path"
}
if (-not $RemovePrivateKey) {
    Write-Host 'The LocalMachine\My certificate/private key was retained. Use -RemovePrivateKey for irreversible key cleanup.'
}
