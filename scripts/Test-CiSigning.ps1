[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo '.github/scripts/CiSigning.psm1') -Force
$secretRoot = [IO.Path]::GetFullPath((Join-Path $repo '.local/secrets'))
$fixture = Join-Path $secretRoot ('ci-signing-tests-' + [Guid]::NewGuid().ToString('N'))
$password = ConvertTo-SecureString 'synthetic-signing-fixture-password-914672' -AsPlainText -Force
$wrongPassword = ConvertTo-SecureString 'different-synthetic-fixture-password' -AsPlainText -Force
$cases = 0
$environment = @{}
$pfxBytes = $null
$jobs = @()
$certificates = [Collections.Generic.List[Security.Cryptography.X509Certificates.X509Certificate2]]::new()
function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:cases++
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notmatch $Message) { throw "Wrong rejection: $($_.Exception.Message)" }
        $rejected = $true
    }
    Assert-Condition $rejected "Expected rejection matching $Message."
}
function New-FixtureCertificate {
    param([string]$Eku='1.3.6.1.5.5.7.3.3', [string]$FriendlyName='WinAirPlayAudio driver test signing',
        [int]$KeySize=3072, [int]$StartDays=-1, [int]$EndDays=1, [switch]$InvalidSelfSignature)
    $rsa = [Security.Cryptography.RSA]::Create($KeySize)
    $otherRsa = $raw = $null
    try {
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=WinAirPlayAudio synthetic certificate fixture', $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $oids = [Security.Cryptography.OidCollection]::new()
        $null = $oids.Add([Security.Cryptography.Oid]::new($Eku))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
        if ($InvalidSelfSignature) {
            $otherRsa = [Security.Cryptography.RSA]::Create(3072)
            $generator = [Security.Cryptography.X509Certificates.X509SignatureGenerator]::CreateForRSA(
                $otherRsa, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $raw = $request.Create($request.SubjectName, $generator,
                [DateTimeOffset]::UtcNow.AddDays($StartDays), [DateTimeOffset]::UtcNow.AddDays($EndDays), [byte[]](1,2,3,4,5))
            $result = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($raw, $rsa)
        }
        else {
            $result = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays($StartDays), [DateTimeOffset]::UtcNow.AddDays($EndDays))
        }
        $result.FriendlyName = $FriendlyName
        return $result
    }
    finally {
        if ($raw) { $raw.Dispose() }
        if ($otherRsa) { $otherRsa.Dispose() }
        $rsa.Dispose()
    }
}
function Assert-CertificateRejected {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate, [string]$Message)
    $bytes = $Certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, 'synthetic-signing-fixture-password-914672')
    try {
        Assert-Rejected {
            Get-WinAirPlayCiSigningCertificate -Bytes $bytes -Password $password -ExpectedThumbprint $Certificate.Thumbprint
        } $Message
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}
try {
    foreach ($name in @('GITHUB_ACTIONS','RUNNER_ENVIRONMENT','GITHUB_EVENT_NAME','GITHUB_REF','GITHUB_SHA')) {
        $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:GITHUB_ACTIONS='true'; $env:RUNNER_ENVIRONMENT='github-hosted'; $env:GITHUB_EVENT_NAME='push'
    $env:GITHUB_REF='refs/tags/v1.2.3-rc.1'; $env:GITHUB_SHA='1' * 40
    Assert-WinAirPlayCiSigningContext -Version '1.2.3-rc.1' -SourceCommit ('1' * 40)
    $cases++
    foreach ($entry in @{
        GITHUB_ACTIONS='false'; RUNNER_ENVIRONMENT='self-hosted'; GITHUB_EVENT_NAME='pull_request_target'
        GITHUB_REF='refs/heads/main'; GITHUB_SHA=('2' * 40)
    }.GetEnumerator()) {
        $previous = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        try {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
            Assert-Rejected { Assert-WinAirPlayCiSigningContext -Version '1.2.3-rc.1' -SourceCommit ('1' * 40) } 'hosted tag-push'
        }
        finally { [Environment]::SetEnvironmentVariable($entry.Key, $previous, 'Process') }
    }
    Assert-Rejected { Assert-WinAirPlayCiSigningContext -Version '1.2.3-01' -SourceCommit ('1' * 40) } 'hosted tag-push'
    Assert-Rejected { Assert-WinAirPlayCiSigningContext -Version '1.2.3-rc.1' -SourceCommit 'main' } 'hosted tag-push'
    $generated = & (Join-Path $PSScriptRoot 'New-CiTestCertificate.ps1') -PfxPassword $password -OutputDirectory $fixture
    $pfxBytes = [IO.File]::ReadAllBytes($generated.PfxPath)
    $accepted = Get-WinAirPlayCiSigningCertificate -Bytes $pfxBytes -Password $password -ExpectedThumbprint $generated.Thumbprint
    $certificates.Add($accepted)
    Assert-Condition ($accepted.HasPrivateKey -and $accepted.FriendlyName -ceq 'WinAirPlayAudio driver test signing') 'Offline generated PFX failed identity/private-key roundtrip.'
    Assert-Condition ((Get-Acl -LiteralPath $fixture).AreAccessRulesProtected) 'Offline private-key directory inherits unsafe access.'
    $allowedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($privatePath in @($fixture, $generated.PfxPath, $generated.Base64Path)) {
        $rules = (Get-Acl -LiteralPath $privatePath).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        Assert-Condition (@($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $_.IdentityReference.Value -notin $allowedSids
        }).Count -eq 0) 'Private certificate output grants access outside owner, SYSTEM and Administrators.'
    }
    Assert-Condition ([Linq.Enumerable]::SequenceEqual[byte]($pfxBytes, [Convert]::FromBase64String([IO.File]::ReadAllText($generated.Base64Path)))) 'PFX/base64 files disagree.'
    $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes($generated.PublicCertificatePath))
    $certificates.Add($public)
    Assert-Condition (-not $public.HasPrivateKey -and $public.Thumbprint -ceq $generated.Thumbprint) 'Public DER contains a private key or wrong certificate.'
    foreach ($store in @('My','Root','TrustedPublisher')) {
        Assert-Condition (-not (Test-Path -LiteralPath "Cert:\LocalMachine\$store\$($generated.Thumbprint)")) 'Offline generation/preflight unexpectedly persisted a machine certificate.'
    }
    Assert-Rejected { Get-WinAirPlayCiSigningCertificate -Bytes $pfxBytes -Password $wrongPassword -ExpectedThumbprint $generated.Thumbprint } 'Unable to open'
    Assert-Rejected { Get-WinAirPlayCiSigningCertificate -Bytes $pfxBytes -Password $password -ExpectedThumbprint ('0' * 40) } 'identity, purpose'
    Assert-Rejected { Get-WinAirPlayCiSigningCertificate -Bytes ([byte[]](1,2,3)) -Password $password -ExpectedThumbprint $generated.Thumbprint } 'Unable to open'
    Assert-CertificateRejected -Certificate $public -Message 'identity, purpose'
    $beforeHash = (Get-FileHash -LiteralPath $generated.PfxPath -Algorithm SHA256).Hash
    Assert-Rejected { & (Join-Path $PSScriptRoot 'New-CiTestCertificate.ps1') -PfxPassword $password -OutputDirectory $fixture } 'already exists'
    Assert-Condition ((Get-FileHash -LiteralPath $generated.PfxPath -Algorithm SHA256).Hash -ceq $beforeHash) 'Generation overwrote an existing signing identity.'
    Assert-Rejected { & (Join-Path $PSScriptRoot 'New-CiTestCertificate.ps1') -PfxPassword $password -OutputDirectory (Join-Path $repo '.local/diagnostics/disallowed-key-fixture') } 'beneath this repository'
    foreach ($arguments in @(
        @{StartDays=-3; EndDays=-2}, @{StartDays=1; EndDays=2}, @{Eku='1.3.6.1.5.5.7.3.1'},
        @{FriendlyName='Wrong signing identity'}, @{KeySize=2048}, @{InvalidSelfSignature=$true}
    )) {
        $candidate = New-FixtureCertificate @arguments
        $certificates.Add($candidate)
        Assert-CertificateRejected -Certificate $candidate -Message 'identity, purpose|self-signature'
    }
    $first = New-FixtureCertificate
    $second = New-FixtureCertificate
    $certificates.Add($first); $certificates.Add($second)
    $multiple = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $null = $multiple.Add($first)
    $null = $multiple.Add($second)
    $multipleBytes = $multiple.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
        'synthetic-signing-fixture-password-914672')
    try {
        Assert-Rejected {
            Get-WinAirPlayCiSigningCertificate -Bytes $multipleBytes -Password $password -ExpectedThumbprint $first.Thumbprint
        } 'exactly one certificate'
    }
    finally { [Array]::Clear($multipleBytes, 0, $multipleBytes.Length) }

    $concurrentOutput = Join-Path $fixture 'concurrent-output'
    $helper = Join-Path $PSScriptRoot 'New-CiTestCertificate.ps1'
    $jobs = @(1..2 | ForEach-Object {
        Start-Job -ArgumentList $helper,$concurrentOutput -ScriptBlock {
            param($Helper, $Output)
            $password = ConvertTo-SecureString 'synthetic-signing-fixture-password-914672' -AsPlainText -Force
            try {
                $generated = & $Helper -PfxPassword $password -OutputDirectory $Output
                [pscustomobject]@{ Succeeded=$true; Thumbprint=$generated.Thumbprint; ErrorKind='' }
            }
            catch {
                $expected = $_.Exception.Message -match 'already exists' -or
                    ($_.Exception -is [Management.Automation.MethodInvocationException] -and
                        $_.Exception.InnerException -is [IO.IOException])
                [pscustomobject]@{ Succeeded=$false; Thumbprint=''; ErrorKind=$(if ($expected) { 'output-exists' } else { $_.Exception.Message }) }
            }
            finally { $password.Dispose() }
        }
    })
    $null = $jobs | Wait-Job -Timeout 90
    Assert-Condition (@($jobs | Where-Object State -NE 'Completed').Count -eq 0) 'Concurrent generation jobs failed or exceeded their bound.'
    $concurrent = @($jobs | Receive-Job -ErrorAction Stop)
    $winners = @($concurrent | Where-Object Succeeded)
    $losers = @($concurrent | Where-Object { -not $_.Succeeded })
    Assert-Condition ($winners.Count -eq 1 -and $losers.Count -eq 1 -and $losers[0].ErrorKind -ceq 'output-exists') `
        'Concurrent output publication did not have exactly one preserved winner.'
    $winnerBytes = [IO.File]::ReadAllBytes((Join-Path $concurrentOutput 'test-signing.pfx'))
    try {
        $winner = Get-WinAirPlayCiSigningCertificate -Bytes $winnerBytes -Password $password -ExpectedThumbprint $winners[0].Thumbprint
        $certificates.Add($winner)
        Assert-Condition ($winner.HasPrivateKey) 'Concurrent loser overwrote or deleted the winner private key.'
    }
    finally { [Array]::Clear($winnerBytes, 0, $winnerBytes.Length) }
    Assert-Condition (@(Get-ChildItem -LiteralPath $fixture -Directory -Filter 'ci-test-stage-*').Count -eq 0) `
        'Concurrent failure left private staging output.'
}
finally {
    foreach ($job in $jobs) {
        if ($job.State -in @('Running','NotStarted','Blocked')) { Stop-Job -Job $job -ErrorAction Stop }
        $null = Wait-Job -Job $job -Timeout 10
        if ($job.State -in @('Running','NotStarted','Blocked')) { throw 'Signing fixture child did not stop.' }
        Remove-Job -Job $job -Force -ErrorAction Stop
    }
    foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process') }
    foreach ($certificate in $certificates) { $certificate.Dispose() }
    if ($pfxBytes) { [Array]::Clear($pfxBytes, 0, $pfxBytes.Length) }
    $password.Dispose(); $wrongPassword.Dispose()
    if (Test-Path -LiteralPath $fixture) {
        $full = [IO.Path]::GetFullPath((Get-Item -LiteralPath $fixture -Force).FullName)
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($full), $secretRoot) -or
            [IO.Path]::GetFileName($full) -cnotmatch '^ci-signing-tests-[0-9a-f]{32}$' -or
            ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            @(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object {
                $_.Attributes -band [IO.FileAttributes]::ReparsePoint
            }).Count -ne 0) { throw 'Refusing test cleanup outside the exact private fixture directory.' }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}
Assert-Condition (-not (Test-Path -LiteralPath $fixture)) 'Private signing fixture remains after cleanup.'
Write-Host "CI signing context/certificate checks passed ($cases cases); no trust, signing or installation changes were made."
