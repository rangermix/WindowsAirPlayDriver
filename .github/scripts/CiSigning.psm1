Set-StrictMode -Version Latest

function Assert-WinAirPlayCiSigningContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$SourceCommit)
    $numeric = '(?:0|[1-9][0-9]*)'
    $identifier = '(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    $semver = "^$numeric\.$numeric\.$numeric(?:-$identifier(?:\.$identifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
    if ($Version.Length -gt 128 -or $Version -cnotmatch $semver -or $SourceCommit -cnotmatch '^[0-9a-f]{40}$' -or
        $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
        $env:GITHUB_EVENT_NAME -cne 'push' -or $env:GITHUB_REF -cne "refs/tags/v$Version" -or
        $env:GITHUB_SHA -cne $SourceCommit) {
        throw 'Signing requires the exact hosted tag-push context and canonical source/version.'
    }
}

function Get-WinAirPlayCiSigningCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$ExpectedThumbprint
    )
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt 1MB -or $Password.Length -eq 0 -or
        $ExpectedThumbprint -cnotmatch '^[0-9A-F]{40}$') {
        throw 'Signing PFX requires bounded bytes, a password and an uppercase certificate pin.'
    }
    $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $rsa = $null
    $passwordPointer = [IntPtr]::Zero
    $plainPassword = $null
    $accepted = $false
    try {
        try {
            $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
            $collection.Import($Bytes, $plainPassword, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        }
        catch { throw [InvalidOperationException]::new('Unable to open the supplied signing PFX.', $_.Exception) }
        if ($collection.Count -ne 1) { throw 'Signing PFX must contain exactly one certificate.' }
        $certificate = $collection[0]
        $now = [DateTime]::UtcNow
        $eku = @($certificate.Extensions | Where-Object {
            $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
        } | ForEach-Object { $_.EnhancedKeyUsages } | Where-Object Value -CEQ '1.3.6.1.5.5.7.3.3')
        if (-not $certificate.HasPrivateKey -or $certificate.Thumbprint -cne $ExpectedThumbprint -or
            $certificate.FriendlyName -cne 'WinAirPlayAudio driver test signing' -or $eku.Count -ne 1 -or
            $certificate.NotBefore.ToUniversalTime() -gt $now -or $certificate.NotAfter.ToUniversalTime() -le $now -or
            [Convert]::ToHexString($certificate.SubjectName.RawData) -cne [Convert]::ToHexString($certificate.IssuerName.RawData)) {
            throw 'Signing PFX identity, purpose, private key or validity failed verification.'
        }
        $reader = [System.Formats.Asn1.AsnReader]::new([ReadOnlyMemory[byte]]::new($certificate.RawData),
            [System.Formats.Asn1.AsnEncodingRules]::DER)
        $sequence = $reader.ReadSequence()
        $tbs = $sequence.ReadEncodedValue().ToArray()
        $algorithm = $sequence.ReadSequence()
        $oid = $algorithm.ReadObjectIdentifier()
        if ($algorithm.HasData) { $algorithm.ReadNull() }
        $algorithm.ThrowIfNotEmpty()
        $unused = 0
        $signature = $sequence.ReadBitString([ref]$unused)
        $sequence.ThrowIfNotEmpty()
        $reader.ThrowIfNotEmpty()
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        if ($oid -cne '1.2.840.113549.1.1.11' -or $unused -ne 0 -or $null -eq $rsa -or $rsa.KeySize -lt 3072 -or
            -not $rsa.VerifyData($tbs, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)) {
            throw 'Signing PFX requires a valid RSA/SHA-256 self-signature and a key of at least 3072 bits.'
        }
        $accepted = $true
        return $certificate
    }
    finally {
        if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
        $plainPassword = $null
        if ($rsa) { $rsa.Dispose() }
        if (-not $accepted) { foreach ($certificate in $collection) { $certificate.Dispose() } }
    }
}

Export-ModuleMember -Function Assert-WinAirPlayCiSigningContext, Get-WinAirPlayCiSigningCertificate
