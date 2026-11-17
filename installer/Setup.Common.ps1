# Bootstrap helpers intentionally support both Windows PowerShell 5.1 and Core.
Set-StrictMode -Version Latest

function Assert-WinAirPlaySetupPlatform {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitProcess) {
        throw 'Run Setup.cmd on native x64 Windows 11 24H2 or newer.'
    }
    $os = @(Get-CimInstance Win32_OperatingSystem -ErrorAction Stop)
    $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    if ($os.Count -ne 1 -or [uint32]$os[0].ProductType -ne 1 -or
        [int]$os[0].BuildNumber -lt 26100 -or $processors.Count -eq 0 -or
        @($processors | Where-Object { [int]$_.Architecture -ne 9 }).Count) {
        throw 'Setup requires native x64 Windows 11 workstation build 26100 or newer; Server, ARM64 and Windows 10 are unsupported.'
    }
}

function Test-WinAirPlaySetupAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Get-WinAirPlaySetupBootState {
    if (-not ('WinAirPlaySetup.CodeIntegrity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinAirPlaySetup {
    public static class CodeIntegrity {
        [StructLayout(LayoutKind.Sequential)]
        private struct Information { public uint Length; public uint Options; }
        [DllImport("ntdll.dll")]
        private static extern int NtQuerySystemInformation(int informationClass,
            ref Information information, int length, out int returnLength);
        public static uint Read() {
            Information information = new Information { Length = 8 };
            int length;
            int status = NtQuerySystemInformation(103, ref information, 8, out length);
            if (status != 0 || length != 8)
                throw new InvalidOperationException("Cannot query current Code Integrity state: " + status);
            return information.Options;
        }
    }
}
'@
    }
    $options = [WinAirPlaySetup.CodeIntegrity]::Read()
    # Unlike bcdedit output, this describes the running kernel, not next boot.
    return [pscustomobject]@{
        TestSigningActive = [bool]($options -band 0x02)
        HvciEnabled = [bool]($options -band 0x400)
    }
}

function Confirm-WinAirPlaySetupAction {
    param([bool]$Acknowledged, [bool]$NonInteractive, [string]$Description)
    if ($Acknowledged) { return }
    if ($NonInteractive) { throw "Explicit acknowledgement required: $Description" }
    if ((Read-Host "$Description Type YES to continue") -cne 'YES') {
        throw 'Operation cancelled before the requested action.'
    }
}

function Assert-WinAirPlaySetupNoLinks {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Setup refuses a reparse point: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Assert-WinAirPlaySetupProtectedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    Assert-WinAirPlaySetupNoLinks $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw 'Setup scratch path is not a directory.' }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw 'Setup scratch must have an Administrators/SYSTEM owner and a protected DACL.'
    }
    $writes = [int64]([Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership) -bor 0x40000000 -bor 0x10000000
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and
            $rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') -and
            ([int64]$rule.FileSystemRights -band $writes)) {
            throw 'Setup scratch grants write access to an untrusted identity.'
        }
    }
}

function New-WinAirPlaySetupProtectedDirectory {
    param([Parameter(Mandatory)][string]$Path)
    Assert-WinAirPlaySetupNoLinks $Path
    if (Test-Path -LiteralPath $Path) { throw "Setup refuses to replace $Path" }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)),
            'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        (New-Object IO.DirectoryInfo($Path)).Create($acl)
    } else {
        [IO.FileSystemAclExtensions]::CreateDirectory($acl, $Path) | Out-Null
    }
    Assert-WinAirPlaySetupProtectedDirectory $Path
}

function New-WinAirPlaySetupScratch {
    $parent = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WinAirPlayAudioSetup'
    if (Test-Path -LiteralPath $parent) { Assert-WinAirPlaySetupProtectedDirectory $parent }
    else { New-WinAirPlaySetupProtectedDirectory $parent }
    $path = Join-Path $parent ([Guid]::NewGuid().ToString('N'))
    New-WinAirPlaySetupProtectedDirectory $path
    return $path
}

function Remove-WinAirPlaySetupScratch {
    param([Parameter(Mandatory)][string]$Path)
    $parent = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WinAirPlayAudioSetup'
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full) -ine $parent -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Setup cleanup is outside its exact protected scratch scope.'
    }
    Assert-WinAirPlaySetupProtectedDirectory $full
    foreach ($entry in Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Setup cleanup refuses reparse points.' }
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $full) { throw 'Setup scratch cleanup was incomplete.' }
}

function Assert-WinAirPlaySetupInputs {
    param([string]$BundleDirectory, [string]$ExpectedSignedManifestSha256, [string]$ExpectedSignerThumbprint)
    if ($ExpectedSignedManifestSha256 -cnotmatch '^[0-9A-Fa-f]{64}$' -or
        $ExpectedSignerThumbprint -cnotmatch '^[0-9A-Fa-f]{40}$') {
        throw 'Provide the independently trusted 64-hex signed-manifest SHA-256 and 40-hex signer thumbprint.'
    }
    Assert-WinAirPlaySetupNoLinks $BundleDirectory
    $directory = Join-Path $BundleDirectory 'package'
    $manifestPath = Join-Path $directory 'package-manifest.json'
    Assert-WinAirPlaySetupNoLinks $manifestPath
    $manifestFile = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($manifestFile.PSIsContainer -or $manifestFile.Length -gt 1MB -or
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine $ExpectedSignedManifestSha256) {
        throw 'Signed package manifest does not match the independently trusted SHA-256.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($manifest.SchemaVersion -ne 1 -or $manifest.Platform -cne 'x64' -or
        $manifest.HardwareId -cne 'ROOT\WinAirPlayAudio' -or
        $manifest.UserService -cne 'WinAirPlayAudioService' -or
        $manifest.UnsignedManifestSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw 'Setup accepts only a complete already test-signed x64 WinAirPlayAudio package.'
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [int64]$total = 0
    foreach ($entry in @($manifest.Files)) {
        if ([string]$entry.Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
            $entry.Name -ieq 'package-manifest.json' -or -not $seen.Add([string]$entry.Name)) {
            throw 'Package manifest contains an unsafe or duplicate name.'
        }
        $path = Join-Path $directory $entry.Name
        Assert-WinAirPlaySetupNoLinks $path
        $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $total += $file.Length
        if ($file.PSIsContainer -or $total -gt 128MB -or $file.Length -ne $entry.Length -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine ([string]$entry.Sha256)) {
            throw "Package payload integrity check failed: $($entry.Name)"
        }
        if ($file.Extension -in @('.exe', '.sys', '.cat') -and
            ($entry.SignatureStatus -cne 'Valid' -or $entry.SignerThumbprint -ine $ExpectedSignerThumbprint)) {
            throw 'Package must declare every binary signed by the expected test identity.'
        }
    }
    $entries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
    if ($seen.Count -eq 0 -or $seen.Count -gt 32 -or $entries.Count -ne $seen.Count + 1 -or
        @($entries | Where-Object { $_.PSIsContainer -or ($_.Name -ine 'package-manifest.json' -and -not $seen.Contains($_.Name)) }).Count) {
        throw 'Package does not contain exactly its declared regular payload files.'
    }
    $certificatePath = Join-Path $BundleDirectory 'test-signing.cer'
    Assert-WinAirPlaySetupNoLinks $certificatePath
    $certFile = Get-Item -LiteralPath $certificatePath -Force -ErrorAction Stop
    if ($certFile.PSIsContainer -or $certFile.Length -le 0 -or $certFile.Length -gt 64KB) { throw 'Invalid public certificate file.' }
    $bytes = [IO.File]::ReadAllBytes($certificatePath)
    if ([Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($bytes) -ne 'Cert') {
        throw 'Setup accepts only one public DER certificate; PFX/private-key inputs are forbidden.'
    }
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$bytes)
    try {
        $eku = @($cert.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
            ForEach-Object { $_.EnhancedKeyUsages } | Where-Object Value -EQ '1.3.6.1.5.5.7.3.3')
        if ($cert.HasPrivateKey -or $cert.Thumbprint -ine $ExpectedSignerThumbprint -or
            $cert.Subject -cne $cert.Issuer -or $eku.Count -ne 1 -or
            $cert.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
            $cert.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow -or
            [Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($cert.RawData)) {
            throw 'Public test certificate identity, validity, code-signing usage or DER encoding is invalid.'
        }
    } finally { $cert.Dispose() }
    return $manifest
}

function Invoke-WinAirPlaySetupHost {
    param([string]$Executable, [string]$Script, [hashtable]$Parameters, [switch]$Elevate)
    # Encode a literal invocation; never interpolate argument data as executable code.
    $command = '$global:LASTEXITCODE = 0; & ' + "'" + $Script.Replace("'", "''") + "'"
    foreach ($key in @($Parameters.Keys | Sort-Object)) {
        if ($key -cnotmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'Invalid setup parameter name.' }
        $value = $Parameters[$key]
        if ($value -is [bool] -or $value -is [Management.Automation.SwitchParameter]) {
            if ($value) { $command += " -$key" }
        } else { $command += " -$key '" + ([string]$value).Replace("'", "''") + "'" }
    }
    $command += '; $setupSucceeded = $?; if ($global:LASTEXITCODE -ne 0) { exit $global:LASTEXITCODE }; if (-not $setupSucceeded) { exit 1 }; exit 0'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    $start = @{ FilePath = $Executable; ArgumentList = $arguments; Wait = $true; PassThru = $true }
    if ($Elevate) { $start.Verb = 'RunAs' }
    else { $start.NoNewWindow = $true }
    # A foreground console is required for the guided acknowledgements.
    $process = Start-Process @start -ErrorAction Stop
    try { return $process.ExitCode } finally { $process.Dispose() }
}

function Add-WinAirPlaySetupCertificateTrust {
    param(
        [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$AddedStores
    )
    # This label makes new trust removable through Remove-TestCertificate.ps1.
    $Certificate.FriendlyName = 'WinAirPlayAudio driver test signing'
    foreach ($storeName in @('Root', 'TrustedPublisher')) {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
        try {
            $store.Open('ReadWrite')
            $existing = @($store.Certificates | Where-Object Thumbprint -EQ $Certificate.Thumbprint)
            if ($existing.Count -eq 0) {
                # Record ownership before a potentially partially successful write.
                $AddedStores.Add($storeName)
                $store.Add($Certificate)
            }
            $found = @($store.Certificates | Where-Object Thumbprint -EQ $Certificate.Thumbprint)
            if ($found.Count -ne 1 -or
                [Convert]::ToBase64String($found[0].RawData) -cne [Convert]::ToBase64String($Certificate.RawData)) {
                throw "Certificate trust postcondition failed in $storeName."
            }
        } finally { $store.Close() }
    }
}

function Remove-WinAirPlaySetupCertificateTrust {
    param(
        [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StoreNames
    )
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($storeName in $StoreNames) {
        $store = $null
        try {
            if ($storeName -cnotin @('Root', 'TrustedPublisher')) { throw 'Unexpected trust store.' }
            $store = [Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
            $store.Open('ReadWrite')
            $store.Remove($Certificate)
            if (@($store.Certificates | Where-Object Thumbprint -EQ $Certificate.Thumbprint).Count) {
                throw 'New test-certificate trust remains after rollback.'
            }
        } catch { $failures.Add("${storeName}: $($_.Exception.Message)") }
        finally { if ($store) { $store.Close() } }
    }
    if ($failures.Count) { throw "Test-certificate rollback incomplete: $($failures -join '; ')" }
}

function New-WinAirPlaySetupScriptSnapshot {
    param([string]$SourceDirectory, [string]$Destination, [hashtable]$ExpectedHashes,
        [string[]]$FileNames = @('Common.ps1', 'Install-Driver.ps1', 'Set-TestSigning.ps1'))
    New-WinAirPlaySetupProtectedDirectory $Destination
    foreach ($name in $FileNames) {
        if ($name -cnotin @('Common.ps1', 'Install-Driver.ps1', 'Set-TestSigning.ps1', 'Remove-TestCertificate.ps1')) {
            throw 'Unexpected script in the protected installer snapshot.'
        }
        $source = Join-Path $SourceDirectory $name
        Assert-WinAirPlaySetupNoLinks $source
        $target = Join-Path $Destination $name
        Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne $ExpectedHashes[$name]) {
            throw "Setup code changed after preflight: $name. Re-extract the authenticated release."
        }
    }
    return $Destination
}
