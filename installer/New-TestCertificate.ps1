[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Subject = 'CN=WinAirPlayAudio Driver Test',

    [ValidateRange(1, 5)]
    [int]$ValidYears = 2,

    [Parameter(Mandatory)]
    [switch]$AcknowledgeMachineTrustInstallation,

    [string]$PfxOutputPath,

    [securestring]$PfxPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $AcknowledgeMachineTrustInstallation) {
    throw 'Creating the test certificate requires -AcknowledgeMachineTrustInstallation.'
}
if ($PfxOutputPath -and -not $PfxPassword) {
    throw '-PfxPassword is required when -PfxOutputPath is supplied.'
}

Assert-WinAirPlayTarget
Assert-WinAirPlayAdministrator -WhatIfOnly:$WhatIfPreference

if (-not $PSCmdlet.ShouldProcess(
        'LocalMachine certificate stores My, Root, and TrustedPublisher',
        "Create and trust test code-signing certificate '$Subject'")) {
    return
}

$certificate = $null
$addedStores = [Collections.Generic.List[string]]::new()
$fullPfxPath = $null
$pfxCreatedByInvocation = $false

try {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $Subject `
        -FriendlyName 'WinAirPlayAudio driver test signing' `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -HashAlgorithm SHA256 `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -KeyExportPolicy Exportable `
        -KeySpec Signature `
        -NotAfter ([DateTime]::UtcNow.AddYears($ValidYears))

    foreach ($storeName in @('Root', 'TrustedPublisher')) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new(
            $storeName,
            [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            # Record the target before Add so a partial/throwing store write is
            # still included in fail-closed rollback.
            $addedStores.Add($storeName)
            $store.Add($certificate)
        }
        finally {
            $store.Close()
        }
    }

    if ($PfxOutputPath) {
        $fullPfxPath = [IO.Path]::GetFullPath($PfxOutputPath)
        $parent = Split-Path -Parent $fullPfxPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "PFX output directory does not exist: $parent"
        }
        if (Test-Path -LiteralPath $fullPfxPath -ErrorAction Stop) {
            throw "Refusing to overwrite an existing PFX path; choose a new output path: $fullPfxPath"
        }
        # Export can leave a partial file when it throws. Mark ownership before
        # the write; an existing destination was rejected above.
        $pfxCreatedByInvocation = $true

        Export-PfxCertificate `
            -Cert $certificate `
            -FilePath $fullPfxPath `
            -Password $PfxPassword | Out-Null
    }

    Write-Host "Created and trusted test certificate: $($certificate.Thumbprint)"
    Write-Warning 'This certificate is for test-mode machines only. Remove it after development.'
    $certificate
}
catch {
    $creationFailure = $_
    $rollbackProblems = [Collections.Generic.List[string]]::new()
    if ($pfxCreatedByInvocation -and $fullPfxPath) {
        try {
            if (Test-Path -LiteralPath $fullPfxPath -ErrorAction Stop) {
                Remove-Item -LiteralPath $fullPfxPath -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $fullPfxPath -ErrorAction Stop) {
                throw "PFX output remains after rollback: $fullPfxPath"
            }
        }
        catch {
            $rollbackProblems.Add("PFX rollback failed: $($_.Exception.Message)")
        }
    }
    if ($certificate) {
        $rollbackStores = @($addedStores) + @('My') | Select-Object -Unique
        foreach ($storeName in $rollbackStores) {
            $path = "Cert:\LocalMachine\$storeName\$($certificate.Thumbprint)"
            try {
                if (Test-Path -LiteralPath $path -ErrorAction Stop) {
                    if ($storeName -eq 'My') {
                        Remove-Item `
                            -LiteralPath $path `
                            -Force `
                            -DeleteKey `
                            -ErrorAction Stop
                    }
                    else {
                        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                    }
                }
                if (Test-Path -LiteralPath $path -ErrorAction Stop) {
                    throw "Certificate remains after rollback: $path"
                }
            }
            catch {
                $rollbackProblems.Add(
                    "Certificate-store rollback failed for '$path': $($_.Exception.Message)")
            }
        }
    }
    if ($rollbackProblems.Count -ne 0) {
        $detail = $rollbackProblems -join [Environment]::NewLine
        throw [InvalidOperationException]::new(
            "Certificate creation failed and rollback was incomplete.$([Environment]::NewLine)$detail",
            $creationFailure.Exception)
    }
    throw $creationFailure
}
