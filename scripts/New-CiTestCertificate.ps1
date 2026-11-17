[CmdletBinding()]
param(
    [Parameter(Mandatory)][securestring]$PfxPassword,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Generate the CI test certificate in PowerShell 7 on Windows.'
}
if ($PfxPassword.Length -eq 0) { throw 'The PFX password must not be empty.' }
$repo = Split-Path $PSScriptRoot -Parent
$secretRoot = [IO.Path]::GetFullPath((Join-Path $repo '.local/secrets'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $secretRoot ('ci-test-' + [Guid]::NewGuid().ToString('N')) }
$output = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
if (-not $output.StartsWith($secretRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Certificate output must be beneath this repository .local/secrets directory.'
}
function Assert-NoReparseAncestor([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Certificate output contains an unsafe ancestor.'
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
Assert-NoReparseAncestor $output
if (Test-Path -LiteralPath $output) { throw 'Certificate output already exists; never overwrite a signing identity.' }
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
Assert-NoReparseAncestor ([IO.Path]::GetDirectoryName($output))
$stage = Join-Path ([IO.Path]::GetDirectoryName($output)) ('ci-test-stage-' + [Guid]::NewGuid().ToString('N'))
Assert-NoReparseAncestor $stage
if (Test-Path -LiteralPath $stage) { throw 'Certificate staging path already exists.' }
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($owner)
$inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
foreach ($sid in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,
        [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
        [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
}
$rsa = $certificate = $plainPassword = $pfxBytes = $null
$passwordPointer = [IntPtr]::Zero
$owned = $false
try {
    $owned = $true
    [IO.FileSystemAclExtensions]::CreateDirectory($acl, $stage) | Out-Null
    $actualAcl = Get-Acl -LiteralPath $stage
    if (-not $actualAcl.AreAccessRulesProtected) { throw 'Private-key output ACL is not protected.' }
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=WinAirPlayAudio CI Test', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $oids = [Security.Cryptography.OidCollection]::new()
    $null = $oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids, $true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
        [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
    $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(2))
    $certificate.FriendlyName = 'WinAirPlayAudio driver test signing'
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    $pfxBytes = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $plainPassword)
    $pfxPath = Join-Path $stage 'test-signing.pfx'
    $base64Path = Join-Path $stage 'test-signing.pfx.base64'
    $publicPath = Join-Path $stage 'test-signing.cer'
    [IO.File]::WriteAllBytes($pfxPath, $pfxBytes)
    [IO.File]::WriteAllText($base64Path, [Convert]::ToBase64String($pfxBytes), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($publicPath, $certificate.RawData)
    $result = [pscustomobject]@{
        PfxPath=(Join-Path $output 'test-signing.pfx')
        Base64Path=(Join-Path $output 'test-signing.pfx.base64')
        PublicCertificatePath=(Join-Path $output 'test-signing.cer')
        Thumbprint=$certificate.Thumbprint; ExpiresAtUtc=$certificate.NotAfter.ToUniversalTime().ToString('o')
    }
    Assert-NoReparseAncestor ([IO.Path]::GetDirectoryName($output))
    # Directory.Move is an atomic same-volume publish that refuses an existing
    # destination. Concurrent invocations never share or overwrite key files.
    [IO.Directory]::Move($stage, $output)
    $owned = $false
    $result
}
catch {
    if ($owned -and (Test-Path -LiteralPath $stage)) {
        Assert-NoReparseAncestor $stage
        if (@(Get-ChildItem -LiteralPath $stage -Recurse -Force | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }).Count -ne 0) { throw 'Certificate generation failed; cleanup rejected a reparse point.' }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
    }
    throw
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
    $plainPassword = $null
    if ($pfxBytes) { [Array]::Clear($pfxBytes, 0, $pfxBytes.Length) }
    if ($certificate) { $certificate.Dispose() }
    if ($rsa) { $rsa.Dispose() }
}
