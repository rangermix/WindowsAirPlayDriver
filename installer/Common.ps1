Set-StrictMode -Version Latest

$script:WinAirPlayProgramData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonApplicationData)
$script:WinAirPlayProgramFiles = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::ProgramFiles)
$script:WinAirPlaySystemDirectory = [Environment]::SystemDirectory
$script:WinAirPlayWindowsDirectory = [IO.Directory]::GetParent(
    $script:WinAirPlaySystemDirectory).FullName
foreach ($trustedRoot in @(
        $script:WinAirPlayProgramData,
        $script:WinAirPlayProgramFiles,
        $script:WinAirPlaySystemDirectory,
        $script:WinAirPlayWindowsDirectory)) {
    if ([string]::IsNullOrWhiteSpace($trustedRoot) -or
        -not [IO.Path]::IsPathFullyQualified($trustedRoot)) {
        throw "Windows did not return a trusted absolute platform path: '$trustedRoot'"
    }
}

$script:WinAirPlayHardwareId = 'ROOT\WinAirPlayAudio'
$script:WinAirPlayProviderName = 'WinAirPlayAudio'
$script:WinAirPlayDriverInfName = 'WinAirPlayAudio.inf'
$script:WinAirPlayKernelServiceName = 'WinAirPlayAudio'
$script:WinAirPlayUserServiceName = 'WinAirPlayAudioService'
$script:WinAirPlayStateDirectory = Join-Path $script:WinAirPlayProgramData 'WinAirPlayAudio'
$script:WinAirPlayStateFile = Join-Path $script:WinAirPlayStateDirectory 'driver-install.json'
$script:WinAirPlayInstallDirectory = Join-Path $script:WinAirPlayProgramFiles 'WinAirPlayAudio'
$script:WinAirPlayServiceExecutable = 'WinAirPlayAudioService.exe'
$script:WinAirPlayFirewallRuleName = 'WinAirPlayAudio.RaopUdpIn'
$script:WinAirPlayFirewallRuleDisplayName = 'WinAirPlayAudio RAOP timing and control'
$script:WinAirPlayFirewallRuleGroup = 'WinAirPlayAudio'
$script:WinAirPlayFirewallRuleDescription =
    'Allows classic RAOP receivers on the private local subnet to reach the service ephemeral UDP timing and control ports.'
$script:WinAirPlayInstallerMutexName = 'Global\WinAirPlayAudio.Installer'
$script:WinAirPlayInstallerStagingRoot = Join-Path $script:WinAirPlayProgramData 'WinAirPlayAudioInstaller'
$script:WinAirPlaySigningToolRoot = Join-Path $script:WinAirPlayProgramData 'WinAirPlayAudioSigningTools'
$script:WinAirPlaySignedPackageRoot = Join-Path $script:WinAirPlayProgramData 'WinAirPlayAudioSignedPackages'
$script:WinAirPlayPinnedKitPackageVersion = '10.0.28000.1839'
$script:WinAirPlayPinnedKitToolVersion = '10.0.28000.0'
$script:WinAirPlayRepositoryRoot = Split-Path $PSScriptRoot -Parent

function Test-WinAirPlayAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WinAirPlayAdministrator {
    param([switch]$WhatIfOnly)

    if ($WhatIfOnly) {
        return
    }
    if (-not (Test-WinAirPlayAdministrator)) {
        throw 'This operation changes Windows driver/PnP state and must run from an elevated PowerShell session.'
    }
}

function Assert-WinAirPlaySigningHost {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'WinAirPlayAudio driver tooling only supports Windows.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'WinAirPlayAudio supports x64 Windows only.'
    }
    if (-not [Environment]::Is64BitProcess -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
            [Runtime.InteropServices.Architecture]::X64 -or
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
            [Runtime.InteropServices.Architecture]::X64) {
        throw 'WinAirPlayAudio privileged tooling requires native x64 Windows and an x64 process. Rerun from 64-bit PowerShell 7 (pwsh.exe); ARM64 and emulated processes are unsupported.'
    }
    if ($PSVersionTable.PSEdition -ne 'Core' -or
        $PSVersionTable.PSVersion.Major -lt 7) {
        throw 'WinAirPlayAudio privileged tooling requires 64-bit PowerShell 7 or newer (pwsh.exe).'
    }

    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 26100) {
        throw "Windows 11 24H2 build 26100 or later is required; detected build $build."
    }
}

function Assert-WinAirPlayTarget {
    Assert-WinAirPlaySigningHost
    $operatingSystems = @(Get-CimInstance `
            -ClassName Win32_OperatingSystem `
            -ErrorAction Stop)
    if ($operatingSystems.Count -ne 1) {
        throw "Expected exactly one Win32_OperatingSystem record; received $($operatingSystems.Count)."
    }
    if ([uint32]$operatingSystems[0].ProductType -ne 1) {
        throw 'WinAirPlayAudio supports Windows 11 workstation editions only; Windows Server is not validated.'
    }

}

function Get-WinAirPlayUserService {
    $services = @(Get-CimInstance `
            -ClassName Win32_Service `
            -Filter "Name='$($script:WinAirPlayUserServiceName)'" `
            -ErrorAction Stop)
    if ($services.Count -gt 1) {
        throw "SCM returned more than one service named '$($script:WinAirPlayUserServiceName)'."
    }
    if ($services.Count -eq 1) {
        return $services[0]
    }
    return $null
}

function Get-WinAirPlayKernelService {
    $services = @(Get-CimInstance `
            -ClassName Win32_SystemDriver `
            -Filter "Name='$($script:WinAirPlayKernelServiceName)'" `
            -ErrorAction Stop)
    if ($services.Count -gt 1) {
        throw "SCM returned more than one kernel service named '$($script:WinAirPlayKernelServiceName)'."
    }
    if ($services.Count -eq 1) {
        return $services[0]
    }
    return $null
}

function Test-WinAirPlayKernelServiceStopped {
    param(
        [AllowNull()]
        [object]$Service
    )

    if ($null -eq $Service) {
        return $true
    }

    $stateProperty = $Service.PSObject.Properties['State']
    $startedProperty = $Service.PSObject.Properties['Started']
    if ($null -eq $stateProperty -or $null -eq $startedProperty) {
        return $false
    }

    return (
        [string]::Equals(
            [string]$stateProperty.Value,
            'Stopped',
            [StringComparison]::OrdinalIgnoreCase) -and
        $startedProperty.Value -is [bool] -and
        $startedProperty.Value -eq $false
    )
}

function Test-WinAirPlayServiceDefinition {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    if ([string]$Service.StartName -notin @('LocalSystem', 'NT AUTHORITY\SYSTEM')) {
        return $false
    }

    $actualPath = ([string]$Service.PathName).Trim()
    if ($actualPath.Length -ge 2 -and
        $actualPath[0] -eq '"' -and
        $actualPath[$actualPath.Length - 1] -eq '"') {
        $actualPath = $actualPath.Substring(1, $actualPath.Length - 2)
    }
    elseif ($actualPath.Contains('"')) {
        return $false
    }

    return [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath($actualPath),
        [IO.Path]::GetFullPath($ExpectedExecutablePath))
}

function Get-WinAirPlayFirewallRule {
    $rules = @(Get-NetFirewallRule `
            -PolicyStore PersistentStore `
            -ErrorAction Stop |
            Where-Object {
                [StringComparer]::OrdinalIgnoreCase.Equals(
                    [string]$_.Name,
                    $script:WinAirPlayFirewallRuleName)
            })
    if ($rules.Count -gt 1) {
        throw "Windows Firewall returned more than one persistent rule named '$($script:WinAirPlayFirewallRuleName)'."
    }
    if ($rules.Count -eq 1) {
        return $rules[0]
    }
    return $null
}

function Test-WinAirPlayFirewallRuleOwnership {
    param(
        [Parameter(Mandatory)]
        [object]$Rule,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    if (-not [StringComparer]::Ordinal.Equals(
            [string]$Rule.Name,
            $script:WinAirPlayFirewallRuleName) -or
        [string]$Rule.PolicyStoreSourceType -cne 'Local') {
        return $false
    }

    $applicationFilters = @($Rule |
            Get-NetFirewallApplicationFilter -ErrorAction Stop)
    if ($applicationFilters.Count -ne 1) {
        return $false
    }
    $actualProgram = [string]$applicationFilters[0].Program
    return (
        -not [string]::IsNullOrWhiteSpace($actualProgram) -and
        [IO.Path]::IsPathFullyQualified($actualProgram) -and
        [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath($actualProgram),
            [IO.Path]::GetFullPath($ExpectedExecutablePath)))
}

function Assert-WinAirPlayFirewallRuleOwnership {
    param(
        [Parameter(Mandatory)]
        [object]$Rule,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    if (-not (Test-WinAirPlayFirewallRuleOwnership `
            -Rule $Rule `
            -ExpectedExecutablePath $ExpectedExecutablePath)) {
        throw "Refusing cleanup because Windows Firewall rule '$($script:WinAirPlayFirewallRuleName)' is not a local rule owned by the exact WinAirPlayAudio service executable."
    }
}

function Test-WinAirPlayFirewallRuleDefinition {
    param(
        [Parameter(Mandatory)]
        [object]$Rule,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    if (-not (Test-WinAirPlayFirewallRuleOwnership `
            -Rule $Rule `
            -ExpectedExecutablePath $ExpectedExecutablePath) -or
        -not [StringComparer]::Ordinal.Equals(
            [string]$Rule.DisplayName,
            $script:WinAirPlayFirewallRuleDisplayName) -or
        -not [StringComparer]::Ordinal.Equals(
            [string]$Rule.Group,
            $script:WinAirPlayFirewallRuleGroup) -or
        -not [StringComparer]::Ordinal.Equals(
            [string]$Rule.Description,
            $script:WinAirPlayFirewallRuleDescription) -or
        [string]$Rule.Enabled -cne 'True' -or
        [string]$Rule.Direction -cne 'Inbound' -or
        [string]$Rule.Action -cne 'Allow' -or
        [string]$Rule.Profile -cne 'Private' -or
        [string]$Rule.EdgeTraversalPolicy -cne 'Block') {
        return $false
    }

    $portFilters = @($Rule |
            Get-NetFirewallPortFilter -ErrorAction Stop)
    $addressFilters = @($Rule |
            Get-NetFirewallAddressFilter -ErrorAction Stop)
    $interfaceFilters = @($Rule |
            Get-NetFirewallInterfaceTypeFilter -ErrorAction Stop)
    $serviceFilters = @($Rule |
            Get-NetFirewallServiceFilter -ErrorAction Stop)
    if ($portFilters.Count -ne 1 -or
        $addressFilters.Count -ne 1 -or
        $interfaceFilters.Count -ne 1 -or
        $serviceFilters.Count -ne 1) {
        return $false
    }

    $port = $portFilters[0]
    $address = $addressFilters[0]
    $interface = $interfaceFilters[0]
    $service = $serviceFilters[0]
    return (
        [string]$port.Protocol -ceq 'UDP' -and
        @($port.LocalPort).Count -eq 1 -and
        [string]@($port.LocalPort)[0] -ceq 'Any' -and
        @($port.RemotePort).Count -eq 1 -and
        [string]@($port.RemotePort)[0] -ceq 'Any' -and
        @($address.LocalAddress).Count -eq 1 -and
        [string]@($address.LocalAddress)[0] -ceq 'Any' -and
        @($address.RemoteAddress).Count -eq 1 -and
        [string]@($address.RemoteAddress)[0] -ceq 'LocalSubnet' -and
        [string]$interface.InterfaceType -ceq 'Any' -and
        [string]$service.Service -ceq 'Any')
}

function Assert-WinAirPlayFirewallRuleDefinition {
    param(
        [Parameter(Mandatory)]
        [object]$Rule,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    if (-not (Test-WinAirPlayFirewallRuleDefinition `
            -Rule $Rule `
            -ExpectedExecutablePath $ExpectedExecutablePath)) {
        throw "Windows Firewall rule '$($script:WinAirPlayFirewallRuleName)' does not match the exact WinAirPlayAudio private-local-subnet UDP definition."
    }
}

function New-WinAirPlayFirewallRule {
    param(
        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    if (Get-WinAirPlayFirewallRule) {
        throw "Windows Firewall rule '$($script:WinAirPlayFirewallRuleName)' reappeared after verified cleanup."
    }
    New-NetFirewallRule `
        -PolicyStore PersistentStore `
        -Name $script:WinAirPlayFirewallRuleName `
        -DisplayName $script:WinAirPlayFirewallRuleDisplayName `
        -Group $script:WinAirPlayFirewallRuleGroup `
        -Description $script:WinAirPlayFirewallRuleDescription `
        -Enabled True `
        -Direction Inbound `
        -Action Allow `
        -Profile Private `
        -Program $ExpectedExecutablePath `
        -Service Any `
        -Protocol UDP `
        -LocalAddress Any `
        -RemoteAddress LocalSubnet `
        -LocalPort Any `
        -RemotePort Any `
        -InterfaceType Any `
        -EdgeTraversalPolicy Block `
        -ErrorAction Stop |
        Out-Null

    $rule = Get-WinAirPlayFirewallRule
    if (-not $rule) {
        throw "Windows Firewall did not persist rule '$($script:WinAirPlayFirewallRuleName)'."
    }
    Assert-WinAirPlayFirewallRuleDefinition `
        -Rule $rule `
        -ExpectedExecutablePath $ExpectedExecutablePath
    return $rule
}

function Remove-WinAirPlayFirewallRule {
    param(
        [Parameter(Mandatory)]
        [object]$Rule,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutablePath
    )

    Assert-WinAirPlayFirewallRuleOwnership `
        -Rule $Rule `
        -ExpectedExecutablePath $ExpectedExecutablePath
    $currentRule = Get-WinAirPlayFirewallRule
    if (-not $currentRule) {
        throw "Windows Firewall rule '$($script:WinAirPlayFirewallRuleName)' disappeared before exact removal."
    }
    Assert-WinAirPlayFirewallRuleOwnership `
        -Rule $currentRule `
        -ExpectedExecutablePath $ExpectedExecutablePath
    $currentRule |
        Remove-NetFirewallRule -ErrorAction Stop
    if (Get-WinAirPlayFirewallRule) {
        throw "Windows Firewall rule '$($script:WinAirPlayFirewallRuleName)' remains after removal."
    }
}

function Invoke-WinAirPlayNative {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $output = @(& $FilePath @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $rendered = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "'$FilePath' failed with exit code $exitCode.$([Environment]::NewLine)$rendered"
    }
    return @($output | ForEach-Object { $_.ToString() })
}

function Enter-WinAirPlayInstallerMutex {
    param(
        [TimeSpan]$Timeout = [TimeSpan]::FromSeconds(30)
    )

    $mutex = $null
    try {
        $mutex = [Threading.Mutex]::new($false, $script:WinAirPlayInstallerMutexName)
        try {
            $acquired = $mutex.WaitOne($Timeout)
        }
        catch [Threading.AbandonedMutexException] {
            # WaitOne grants ownership when it reports an abandoned mutex.
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Another WinAirPlayAudio install or uninstall operation did not finish within $Timeout."
        }
        return $mutex
    }
    catch {
        if ($mutex) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-WinAirPlayInstallerMutex {
    param(
        [Parameter(Mandatory)]
        [Threading.Mutex]$Mutex
    )

    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function New-WinAirPlaySecureDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$UsersReadExecute
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace an existing path while creating a protected directory: $Path"
    }

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($administrators)
    foreach ($identity in @($system, $administrators)) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $identity,
                [Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow))
    }
    if ($UsersReadExecute) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $users,
                [Security.AccessControl.FileSystemRights]::ReadAndExecute,
                $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow))
    }

    [IO.FileSystemAclExtensions]::CreateDirectory($security, $Path) | Out-Null
    Assert-WinAirPlayTrustedDirectory -Path $Path -RequireProtectedDacl
}

function Assert-WinAirPlayTrustedDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$RequireProtectedDacl
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing an unsafe or non-directory path: $($item.FullName)"
    }
    $acl = [IO.FileSystemAclExtensions]::GetAccessControl(
        [IO.DirectoryInfo]$item,
        [Security.AccessControl.AccessControlSections]::Owner -bor
            [Security.AccessControl.AccessControlSections]::Access)
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) {
        throw "Protected directory has an untrusted owner '$owner': $($item.FullName)"
    }
    if ($RequireProtectedDacl -and -not $acl.AreAccessRulesProtected) {
        throw "Protected directory inherits its DACL unexpectedly: $($item.FullName)"
    }

    foreach ($rule in $acl.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin @('S-1-5-18', 'S-1-5-32-544') -and
            (Test-WinAirPlayFileSystemRightsWriteCapable `
                    -Rights ([int64]$rule.FileSystemRights))) {
            throw "Protected directory grants write-capable access to '$($rule.IdentityReference.Value)': $($item.FullName)"
        }
    }
}

function Test-WinAirPlayFileSystemRightsWriteCapable {
    param(
        [Parameter(Mandatory)]
        [int64]$Rights
    )

    $writeRights = ([int64](
        [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        [Security.AccessControl.FileSystemRights]::Delete)) -bor
        [int64]0x40000000 -bor
        [int64]0x10000000
    return ($Rights -band $writeRights) -ne 0
}

function Assert-WinAirPlayRegularFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing an unsafe or non-regular file: $($item.FullName)"
    }
}

function Assert-WinAirPlayInstallStateRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$PassThru
    )

    Assert-WinAirPlayRegularFile -Path $Path
    $stateInfo = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($stateInfo.Length -le 0 -or $stateInfo.Length -gt 1MB) {
        throw "Install-state record has an invalid size: $($stateInfo.FullName)"
    }
    try {
        $record = Get-Content -LiteralPath $stateInfo.FullName -Raw |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Install-state record is not valid JSON: $($stateInfo.FullName)"
    }

    $installedAt = [DateTime]::MinValue
    $expectedServicePath = Join-Path `
        $script:WinAirPlayInstallDirectory `
        $script:WinAirPlayServiceExecutable
    $publishedNames = @($record.PublishedNames)
    if ($record.SchemaVersion -ne 1 -or
        -not [DateTime]::TryParse(
            [string]$record.InstalledAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$installedAt) -or
        [string]::IsNullOrWhiteSpace([string]$record.SourceInf) -or
        $publishedNames.Count -eq 0 -or
        $publishedNames.Count -gt 64 -or
        @($publishedNames | Where-Object {
                [string]$_ -cnotmatch '^oem\d+\.inf$'
            }).Count -ne 0 -or
        [string]$record.PackageManifestSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        [string]$record.CatalogSignerThumbprint -cnotmatch '^[0-9A-F]{40}$' -or
        [string]$record.ExecutableSignerThumbprint -cnotmatch '^[0-9A-F]{40}$' -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath([string]$record.ServicePath),
            [IO.Path]::GetFullPath($expectedServicePath))) {
        throw "Install-state record contract is invalid: $($stateInfo.FullName)"
    }

    if ($PassThru) {
        return $record
    }
}

function Get-WinAirPlayRuntimeManifestSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuntimeDirectory
    )

    $manifestPath = Join-Path $RuntimeDirectory 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }

    Assert-WinAirPlayRegularFile -Path $manifestPath
    $manifestInfo = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if ($manifestInfo.Length -le 0 -or $manifestInfo.Length -gt 1MB) {
        throw "Installed package manifest has an invalid size: $($manifestInfo.FullName)"
    }
    return (Get-FileHash `
            -LiteralPath $manifestInfo.FullName `
            -Algorithm SHA256 `
            -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Get-WinAirPlayRuntimeFileNames {
    return @(
        $script:WinAirPlayServiceExecutable,
        'airplay-discover.exe',
        'airplay-send.exe',
        'endpoint-list.exe',
        'endpoint-tone.exe',
        'diagnose.exe',
        'credential-store.exe',
        'mock-bonjour-advertiser.exe',
        'mock-raop-receiver.exe',
        'config.example.json',
        'LICENSE',
        'LICENSE.microsoft-samples.txt',
        'version.json',
        'THIRD_PARTY_NOTICES.md',
        'README.md',
        'BUILD-AND-INSTALL.md',
        'cargo-metadata.json',
        'RUST-DEPENDENCY-LICENSES.txt',
        'package-manifest.json'
    )
}

function Get-WinAirPlayPackageFileNames {
    return @(
        'WinAirPlayAudio.inf',
        'WinAirPlayAudio.sys',
        'WinAirPlayAudio.cat'
    ) + @(Get-WinAirPlayRuntimeFileNames)
}

function Assert-WinAirPlayRuntimePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuntimeDirectory,

        [Parameter(Mandatory)]
        [string]$ExpectedManifestSha256,

        [switch]$PassThru
    )

    if ($ExpectedManifestSha256 -cnotmatch '^[0-9A-F]{64}$') {
        throw "Expected runtime manifest hash has an invalid shape: '$ExpectedManifestSha256'"
    }
    Assert-WinAirPlayTrustedDirectory `
        -Path $RuntimeDirectory `
        -RequireProtectedDacl
    Assert-WinAirPlayTreeHasNoReparsePoints -Path $RuntimeDirectory

    $expectedRuntimeNames = @(Get-WinAirPlayRuntimeFileNames)
    $runtimeNameSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $expectedRuntimeNames) {
        if (-not $runtimeNameSet.Add($name)) {
            throw "Runtime file contract contains a duplicate name: '$name'"
        }
    }
    $runtimeEntries = @(Get-ChildItem `
            -LiteralPath $RuntimeDirectory `
            -Force `
            -ErrorAction Stop)
    if ($runtimeEntries.Count -ne $runtimeNameSet.Count) {
        throw "Installed runtime does not contain the exact expected file count: $RuntimeDirectory"
    }
    foreach ($entry in $runtimeEntries) {
        if ($entry.PSIsContainer -or -not $runtimeNameSet.Contains($entry.Name)) {
            throw "Installed runtime contains an unexpected entry: $($entry.FullName)"
        }
        Assert-WinAirPlayRegularFile -Path $entry.FullName
    }

    $manifestPath = Join-Path $RuntimeDirectory 'package-manifest.json'
    $manifestHash = Get-WinAirPlayRuntimeManifestSha256 `
        -RuntimeDirectory $RuntimeDirectory
    if (-not [StringComparer]::Ordinal.Equals(
            $manifestHash,
            $ExpectedManifestSha256)) {
        throw "Installed runtime manifest hash does not match authoritative state: $manifestPath"
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Installed runtime manifest is not valid JSON: $manifestPath"
    }
    if ($manifest.SchemaVersion -ne 1 -or
        $manifest.Configuration -notin @('Debug', 'Release') -or
        $manifest.Platform -cne 'x64' -or
        $manifest.HardwareId -cne $script:WinAirPlayHardwareId -or
        $manifest.UserService -cne $script:WinAirPlayUserServiceName) {
        throw "Installed runtime manifest contract is invalid: $manifestPath"
    }

    $manifestEntries = @($manifest.Files)
    $requiredManifestNames = @(Get-WinAirPlayPackageFileNames |
        Where-Object { $_ -cne 'package-manifest.json' })
    if ($manifestEntries.Count -ne $requiredManifestNames.Count) {
        throw "Installed runtime manifest does not contain the exact package payload set: $manifestPath"
    }
    $manifestByName = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($manifestEntry in $manifestEntries) {
        $name = [string]$manifestEntry.Name
        $sha256 = [string]$manifestEntry.Sha256
        if ([string]::IsNullOrWhiteSpace($name) -or
            $name -cne [IO.Path]::GetFileName($name) -or
            $sha256 -cnotmatch '^[0-9A-F]{64}$' -or
            $manifestByName.ContainsKey($name)) {
            throw "Installed runtime manifest contains an unsafe or duplicate entry: '$name'"
        }
        $manifestByName.Add($name, $manifestEntry)
    }
    foreach ($name in $requiredManifestNames) {
        if (-not $manifestByName.ContainsKey($name)) {
            throw "Installed runtime manifest omits required package file '$name'."
        }
    }
    foreach ($name in @($expectedRuntimeNames |
            Where-Object { $_ -cne 'package-manifest.json' })) {
        $runtimePath = Join-Path $RuntimeDirectory $name
        $actualHash = (Get-FileHash `
                -LiteralPath $runtimePath `
                -Algorithm SHA256 `
                -ErrorAction Stop).Hash
        $expectedHash = ([string]$manifestByName[$name].Sha256).ToUpperInvariant()
        if ($actualHash -cne $expectedHash) {
            throw "Installed runtime payload hash mismatch for '$name'."
        }
    }

    if ($PassThru) {
        return $manifestHash
    }
}

function Assert-WinAirPlayTreeHasNoReparsePoints {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Protected tree contains a reparse point: $($item.FullName)"
        }
    }
}

function Assert-WinAirPlayStateTree {
    Assert-WinAirPlayTrustedDirectory `
        -Path $script:WinAirPlayStateDirectory `
        -RequireProtectedDacl

    $allowedFiles = @('config.json', 'driver-install.json')
    $allowedDirectories = @('credentials', 'logs')
    foreach ($item in Get-ChildItem -LiteralPath $script:WinAirPlayStateDirectory -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "State directory contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            if ($item.Name -notin $allowedDirectories) {
                throw "State directory contains an unexpected directory: $($item.FullName)"
            }
            Assert-WinAirPlayTrustedDirectory -Path $item.FullName
            Assert-WinAirPlayTreeHasNoReparsePoints -Path $item.FullName
        }
        elseif ($item.Name -notin $allowedFiles) {
            throw "State directory contains an unexpected file: $($item.FullName)"
        }
    }
}

function Remove-WinAirPlayDirectorySafe {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$AllowedParent,

        [Parameter(Mandatory)]
        [string]$AllowedLeafPattern
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($AllowedParent)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($fullPath),
            $parent) -or
        [IO.Path]::GetFileName($fullPath) -cnotmatch $AllowedLeafPattern) {
        throw "Refusing recursive removal outside the exact allowed scope: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -ErrorAction Stop)) {
        return
    }
    Assert-WinAirPlayTrustedDirectory -Path $fullPath
    Assert-WinAirPlayTreeHasNoReparsePoints -Path $fullPath
    Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $fullPath -ErrorAction Stop) {
        throw "Directory remains after recursive removal: $fullPath"
    }
}

function Get-WinAirPlayRuntimeTransactionDirectories {
    $transactions = @(Get-ChildItem `
            -LiteralPath $script:WinAirPlayProgramFiles `
            -Force `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -cmatch '^WinAirPlayAudio\.(rollback|staging)-[0-9a-f]{32}$'
        })
    foreach ($transaction in $transactions) {
        if (-not $transaction.PSIsContainer) {
            throw "Runtime transaction path is not a directory: $($transaction.FullName)"
        }
        Assert-WinAirPlayTrustedDirectory `
            -Path $transaction.FullName `
            -RequireProtectedDacl
        Assert-WinAirPlayTreeHasNoReparsePoints -Path $transaction.FullName
    }
    return $transactions
}

function Get-WinAirPlayInstallerSnapshotDirectories {
    if (-not (Test-Path -LiteralPath $script:WinAirPlayInstallerStagingRoot)) {
        return @()
    }
    Assert-WinAirPlayTrustedDirectory `
        -Path $script:WinAirPlayInstallerStagingRoot `
        -RequireProtectedDacl
    $snapshots = @(Get-ChildItem `
            -LiteralPath $script:WinAirPlayInstallerStagingRoot `
            -Force `
            -ErrorAction Stop)
    foreach ($snapshot in $snapshots) {
        if (-not $snapshot.PSIsContainer -or
            $snapshot.Name -cnotmatch '^[0-9a-f]{32}$') {
            throw "Installer snapshot root contains an unexpected entry: $($snapshot.FullName)"
        }
        Assert-WinAirPlayTrustedDirectory `
            -Path $snapshot.FullName `
            -RequireProtectedDacl
        Assert-WinAirPlayTreeHasNoReparsePoints -Path $snapshot.FullName
    }
    return $snapshots
}

function Get-WinAirPlayInstallationInventory {
    $userService = Get-WinAirPlayUserService
    $kernelService = Get-WinAirPlayKernelService
    $firewallRule = Get-WinAirPlayFirewallRule
    $devices = @(Get-WinAirPlayDevices)
    $driverPackages = @(Get-WinAirPlayDriverPackages)
    $runtimeTransactions = @(Get-WinAirPlayRuntimeTransactionDirectories)
    $installerSnapshots = @(Get-WinAirPlayInstallerSnapshotDirectories)
    $runtimeExists = Test-Path -LiteralPath $script:WinAirPlayInstallDirectory
    $stateExists = Test-Path -LiteralPath $script:WinAirPlayStateDirectory
    $installerRootExists =
        Test-Path -LiteralPath $script:WinAirPlayInstallerStagingRoot

    [pscustomobject]@{
        UserService = $userService
        KernelService = $kernelService
        FirewallRule = $firewallRule
        Devices = $devices
        DriverPackages = $driverPackages
        RuntimeTransactions = $runtimeTransactions
        InstallerSnapshots = $installerSnapshots
        RuntimeExists = $runtimeExists
        StateExists = $stateExists
        InstallerRootExists = $installerRootExists
        HasInstalledArtifacts = [bool](
            $userService -or
            $kernelService -or
            $firewallRule -or
            $devices.Count -ne 0 -or
            $driverPackages.Count -ne 0 -or
            $runtimeTransactions.Count -ne 0 -or
            $installerRootExists -or
            $runtimeExists -or
            $stateExists)
    }
}

function Test-WinAirPlayInstallationPresent {
    return [bool](Get-WinAirPlayInstallationInventory).HasInstalledArtifacts
}

function Assert-WinAirPlayInstallationAbsent {
    param(
        [string]$PreserveInstallerSnapshot,

        [switch]$RequireToolCachesAbsent
    )

    $inventory = Get-WinAirPlayInstallationInventory
    $problems = [Collections.Generic.List[string]]::new()
    if ($inventory.UserService) {
        $problems.Add("user service '$($script:WinAirPlayUserServiceName)'")
    }
    if ($inventory.KernelService) {
        $problems.Add("kernel service '$($script:WinAirPlayKernelServiceName)'")
    }
    if ($inventory.FirewallRule) {
        $problems.Add("Windows Firewall rule '$($script:WinAirPlayFirewallRuleName)'")
    }
    if ($inventory.Devices.Count -ne 0) {
        $problems.Add("$($inventory.Devices.Count) devnode(s)")
    }
    if ($inventory.DriverPackages.Count -ne 0) {
        $problems.Add("$($inventory.DriverPackages.Count) Driver Store package(s)")
    }
    if ($inventory.RuntimeExists) {
        $problems.Add("runtime '$($script:WinAirPlayInstallDirectory)'")
    }
    if ($inventory.StateExists) {
        $problems.Add("state '$($script:WinAirPlayStateDirectory)'")
    }
    if ($inventory.RuntimeTransactions.Count -ne 0) {
        $problems.Add("$($inventory.RuntimeTransactions.Count) runtime transaction artifact(s)")
    }

    if ([string]::IsNullOrWhiteSpace($PreserveInstallerSnapshot)) {
        if ($inventory.InstallerRootExists) {
            $problems.Add("installer snapshot root '$($script:WinAirPlayInstallerStagingRoot)'")
        }
    }
    else {
        $preserved = [IO.Path]::GetFullPath($PreserveInstallerSnapshot)
        $root = [IO.Path]::GetFullPath($script:WinAirPlayInstallerStagingRoot)
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($preserved),
                $root) -or
            [IO.Path]::GetFileName($preserved) -cnotmatch '^[0-9a-f]{32}$') {
            throw "Preserved installer snapshot is outside the exact snapshot root: $preserved"
        }
        $unexpectedSnapshots = @($inventory.InstallerSnapshots | Where-Object {
                -not [StringComparer]::OrdinalIgnoreCase.Equals(
                    [IO.Path]::GetFullPath($_.FullName),
                    $preserved)
            })
        if (-not (Test-Path -LiteralPath $preserved -PathType Container) -or
            $inventory.InstallerSnapshots.Count -ne 1 -or
            $unexpectedSnapshots.Count -ne 0) {
            $problems.Add('installer snapshots other than the active validated package')
        }
    }

    if ($RequireToolCachesAbsent -and
        (Test-Path -LiteralPath $script:WinAirPlaySigningToolRoot)) {
        $problems.Add("signing-tool cache '$($script:WinAirPlaySigningToolRoot)'")
    }
    if ($problems.Count -ne 0) {
        throw "WinAirPlayAudio cleanup is incomplete; remaining: $($problems -join ', ')."
    }
}

function Remove-WinAirPlayInstallerSnapshots {
    param(
        [switch]$RemoveRoot,

        [string]$PreserveSnapshot
    )

    if (-not (Test-Path -LiteralPath $script:WinAirPlayInstallerStagingRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($PreserveSnapshot)) {
            throw "The installer snapshot selected for preservation does not exist: $PreserveSnapshot"
        }
        return
    }
    if ($RemoveRoot -and -not [string]::IsNullOrWhiteSpace($PreserveSnapshot)) {
        throw 'Cannot remove the installer snapshot root while preserving an active snapshot.'
    }

    $root = [IO.Path]::GetFullPath($script:WinAirPlayInstallerStagingRoot)
    $preserved = $null
    if (-not [string]::IsNullOrWhiteSpace($PreserveSnapshot)) {
        $preserved = [IO.Path]::GetFullPath($PreserveSnapshot)
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($preserved),
                $root) -or
            [IO.Path]::GetFileName($preserved) -cnotmatch '^[0-9a-f]{32}$') {
            throw "Preserved installer snapshot is outside the exact snapshot root: $preserved"
        }
    }

    $snapshots = @(Get-WinAirPlayInstallerSnapshotDirectories)
    if ($preserved -and
        @($snapshots | Where-Object {
                [StringComparer]::OrdinalIgnoreCase.Equals(
                    [IO.Path]::GetFullPath($_.FullName),
                    $preserved)
            }).Count -ne 1) {
        throw "The installer snapshot selected for preservation is missing or ambiguous: $preserved"
    }
    foreach ($snapshot in $snapshots) {
        if ($preserved -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetFullPath($snapshot.FullName),
                $preserved)) {
            continue
        }
        Remove-WinAirPlayDirectorySafe `
            -Path $snapshot.FullName `
            -AllowedParent $script:WinAirPlayInstallerStagingRoot `
            -AllowedLeafPattern '^[0-9a-f]{32}$'
    }

    $remaining = @(Get-WinAirPlayInstallerSnapshotDirectories)
    if ($preserved) {
        if ($remaining.Count -ne 1 -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetFullPath($remaining[0].FullName),
                $preserved)) {
            throw 'Installer snapshot cleanup did not preserve exactly the active snapshot.'
        }
    }
    elseif ($remaining.Count -ne 0) {
        throw 'Installer snapshot root is not empty after cleanup.'
    }
    if ($RemoveRoot) {
        Remove-WinAirPlayDirectorySafe `
            -Path $script:WinAirPlayInstallerStagingRoot `
            -AllowedParent $script:WinAirPlayProgramData `
            -AllowedLeafPattern '^WinAirPlayAudioInstaller$'
    }
}

function New-WinAirPlayPackageSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory
    )

    $source = (Resolve-Path -LiteralPath $SourceDirectory -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Package source is not a directory: $source"
    }

    $expectedNames = @(Get-WinAirPlayPackageFileNames)
    $expectedSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $expectedNames) {
        [void]$expectedSet.Add($name)
    }
    $sourceEntries = @(Get-ChildItem `
            -LiteralPath $source `
            -Force `
            -ErrorAction Stop)
    $actualNames = @($sourceEntries | ForEach-Object Name)
    $unexpectedNames = @($actualNames | Where-Object { -not $expectedSet.Contains($_) })
    $missingNames = @($expectedNames | Where-Object { $_ -notin $actualNames })
    if ($sourceEntries.Count -ne $expectedNames.Count -or
        $unexpectedNames.Count -ne 0 -or
        $missingNames.Count -ne 0 -or
        @($sourceEntries | Where-Object { $_.PSIsContainer }).Count -ne 0) {
        throw "Package source must contain the exact bounded file set. Missing=[$($missingNames -join ', ')]; unexpected=[$($unexpectedNames -join ', ')]."
    }

    [int64]$maximumFileBytes = 32MB
    [int64]$maximumPackageBytes = 128MB
    [int64]$initialPackageBytes = 0
    foreach ($file in $sourceEntries) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package source contains a reparse-point file: $($file.FullName)"
        }
        if ($file.Length -lt 0 -or $file.Length -gt $maximumFileBytes -or
            $initialPackageBytes -gt ($maximumPackageBytes - $file.Length)) {
            throw "Package source exceeds the bounded copy limits at '$($file.Name)'."
        }
        $initialPackageBytes += $file.Length
    }

    $rootOwned = $false
    $root = $null
    $snapshot = $null
    $snapshotOwned = $false
    try {
        if (Test-Path -LiteralPath $script:WinAirPlayInstallerStagingRoot) {
            Remove-WinAirPlayInstallerSnapshots
        }
        else {
            # Track the shared root before ACL creation so a failed
            # postcondition cannot leave a blocking partial directory.
            $rootOwned = $true
            New-WinAirPlaySecureDirectory -Path $script:WinAirPlayInstallerStagingRoot
        }
        $root = Get-Item -LiteralPath $script:WinAirPlayInstallerStagingRoot -Force
        $snapshot = Join-Path $root.FullName ([Guid]::NewGuid().ToString('N'))
        # Mark ownership before creation so a partially created directory is
        # still covered by the rollback path.
        $snapshotOwned = $true
        New-WinAirPlaySecureDirectory -Path $snapshot
        $buffer = [byte[]]::new(1MB)
        [int64]$copiedPackageBytes = 0
        foreach ($file in $sourceEntries) {
            $sourceStream = $null
            $destinationStream = $null
            try {
                $sourceStream = [IO.FileStream]::new(
                    $file.FullName,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read,
                    1MB,
                    [IO.FileOptions]::SequentialScan)
                if ($sourceStream.Length -gt $maximumFileBytes) {
                    throw "Package file grew beyond the bounded copy limit: $($file.FullName)"
                }
                $destinationStream = [IO.FileStream]::new(
                    (Join-Path $snapshot $file.Name),
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::None,
                    1MB,
                    [IO.FileOptions]::WriteThrough)
                [int64]$copiedFileBytes = 0
                while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($copiedFileBytes -gt ($maximumFileBytes - $read) -or
                        $copiedPackageBytes -gt ($maximumPackageBytes - $read)) {
                        throw "Package source exceeded the bounded copy limit while reading '$($file.Name)'."
                    }
                    $destinationStream.Write($buffer, 0, $read)
                    $copiedFileBytes += $read
                    $copiedPackageBytes += $read
                }
                if ($copiedFileBytes -ne $file.Length) {
                    throw "Package source changed during protected snapshot creation: $($file.FullName)"
                }
                $destinationStream.Flush($true)
            }
            finally {
                if ($destinationStream) {
                    $destinationStream.Dispose()
                }
                if ($sourceStream) {
                    $sourceStream.Dispose()
                }
            }
        }
        return $snapshot
    }
    catch {
        $snapshotFailure = $_
        $cleanupProblems = [Collections.Generic.List[string]]::new()
        if ($snapshotOwned -and $snapshot -and
            (Test-Path -LiteralPath $snapshot)) {
            try {
                Remove-WinAirPlayDirectorySafe `
                    -Path $snapshot `
                    -AllowedParent $root.FullName `
                    -AllowedLeafPattern '^[0-9a-f]{32}$'
            }
            catch {
                $cleanupProblems.Add($_.Exception.Message)
            }
        }
        if ($rootOwned -and
            (Test-Path -LiteralPath $script:WinAirPlayInstallerStagingRoot)) {
            try {
                Remove-WinAirPlayDirectorySafe `
                    -Path $script:WinAirPlayInstallerStagingRoot `
                    -AllowedParent $script:WinAirPlayProgramData `
                    -AllowedLeafPattern '^WinAirPlayAudioInstaller$'
            }
            catch {
                $cleanupProblems.Add($_.Exception.Message)
            }
        }
        if ($cleanupProblems.Count -ne 0) {
            throw [InvalidOperationException]::new(
                "Package snapshot creation failed and rollback was incomplete: $($cleanupProblems -join '; ')",
                $snapshotFailure.Exception)
        }
        throw $snapshotFailure
    }
}

function Remove-WinAirPlayPackageSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotDirectory
    )

    $root = [IO.Path]::GetFullPath($script:WinAirPlayInstallerStagingRoot)
    $snapshot = [IO.Path]::GetFullPath($SnapshotDirectory)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($snapshot),
            $root) -or
        [IO.Path]::GetFileName($snapshot) -cnotmatch '^[0-9a-f]{32}$') {
        throw "Refusing to remove a path outside the installer staging root: $snapshot"
    }
    if (Test-Path -LiteralPath $snapshot) {
        Remove-WinAirPlayDirectorySafe `
            -Path $snapshot `
            -AllowedParent $root `
            -AllowedLeafPattern '^[0-9a-f]{32}$'
    }
    if (Test-Path -LiteralPath $root) {
        $remainingSnapshots = @(Get-WinAirPlayInstallerSnapshotDirectories)
        if ($remainingSnapshots.Count -eq 0) {
            Remove-WinAirPlayDirectorySafe `
                -Path $root `
                -AllowedParent $script:WinAirPlayProgramData `
                -AllowedLeafPattern '^WinAirPlayAudioInstaller$'
        }
    }
}

function Assert-WinAirPlayPeX64 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-WinAirPlayRegularFile -Path $Path
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        if ($stream.Length -lt 0x40) {
            throw "PE image is too small: $Path"
        }
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "PE image has no MZ header: $Path"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0x40 -or
            $peOffset -gt ($stream.Length - 6)) {
            throw "PE image has an invalid header offset: $Path"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "PE image has no PE signature: $Path"
        }
        $machine = $reader.ReadUInt16()
        if ($machine -ne 0x8664) {
            throw "PE image is not x64/AMD64 (machine 0x$($machine.ToString('X4'))): $Path"
        }
    }
    finally {
        if ($reader) {
            $reader.Dispose()
            $stream = $null
        }
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Resolve-WinAirPlayPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageDirectory
    )

    $directory = (Resolve-Path -LiteralPath $PackageDirectory -ErrorAction Stop).Path
    $inf = Join-Path $directory $script:WinAirPlayDriverInfName
    $sys = Join-Path $directory 'WinAirPlayAudio.sys'
    $cat = Join-Path $directory 'WinAirPlayAudio.cat'
    $service = Join-Path $directory $script:WinAirPlayServiceExecutable
    $manifestPath = Join-Path $directory 'package-manifest.json'

    foreach ($path in @($inf, $sys, $cat, $service, $manifestPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Package is incomplete; required file is missing: $path"
        }
    }

    $infText = Get-Content -LiteralPath $inf -Raw
    if ($infText -notmatch [regex]::Escape($script:WinAirPlayHardwareId)) {
        throw "INF does not bind the expected hardware ID '$($script:WinAirPlayHardwareId)': $inf"
    }
    if ($infText -notmatch 'AddService\s*=\s*WinAirPlayAudio\b') {
        throw "INF does not declare the expected kernel service '$($script:WinAirPlayKernelServiceName)': $inf"
    }
    if ($infText -notmatch '(?im)^\s*Provider\s*=\s*%ProviderName%\s*$' -or
        $infText -notmatch '(?im)^\s*ProviderName\s*=\s*"WinAirPlayAudio"\s*$') {
        throw "INF does not declare the exact expected provider '$($script:WinAirPlayProviderName)': $inf"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json -ErrorAction Stop
    if ($manifest.SchemaVersion -ne 1 -or
        $manifest.Configuration -notin @('Debug', 'Release') -or
        $manifest.Platform -cne 'x64' -or
        $manifest.HardwareId -cne $script:WinAirPlayHardwareId -or
        $manifest.UserService -cne $script:WinAirPlayUserServiceName) {
        throw "Package manifest contract is invalid: $manifestPath"
    }
    $manifestNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.Files)) {
        if (-not $entry.Name -or
            $entry.Name -ne [IO.Path]::GetFileName($entry.Name) -or
            -not $manifestNames.Add([string]$entry.Name)) {
            throw "Package manifest contains an unsafe or duplicate file name: '$($entry.Name)'"
        }
        $file = Join-Path $directory $entry.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Manifest file is missing from package: $file"
        }
        $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actualHash -cne ([string]$entry.Sha256).ToUpperInvariant()) {
            throw "Package hash mismatch for '$($entry.Name)'."
        }
    }
    $requiredManifestNames = @(Get-WinAirPlayPackageFileNames |
        Where-Object { $_ -cne 'package-manifest.json' })
    if ($manifestNames.Count -ne $requiredManifestNames.Count) {
        throw "Package manifest does not contain the exact payload file set: $manifestPath"
    }
    foreach ($name in $requiredManifestNames) {
        if (-not $manifestNames.Contains($name)) {
            throw "Package manifest does not contain required file '$name'."
        }
    }
    Assert-WinAirPlayPeX64 -Path $sys
    Assert-WinAirPlayPeX64 -Path $service
    foreach ($name in @($requiredManifestNames | Where-Object {
                [IO.Path]::GetExtension($_) -ieq '.exe'
            })) {
        Assert-WinAirPlayPeX64 -Path (Join-Path $directory $name)
    }

    [pscustomobject]@{
        Directory = $directory
        Inf = $inf
        Sys = $sys
        Cat = $cat
        Service = $service
        Manifest = $manifestPath
    }
}

function Assert-WinAirPlayPackageSignature {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Package,

        [Parameter(Mandatory)]
        [string]$ExpectedCatalogSignerThumbprint,

        [Parameter(Mandatory)]
        [string]$ExpectedExecutableSignerThumbprint
    )

    $catalogSignature = Get-AuthenticodeSignature -LiteralPath $Package.Cat
    if ($catalogSignature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "Catalog signature is not valid/trusted (status $($catalogSignature.Status)): $($Package.Cat)"
    }
    if (-not $catalogSignature.SignerCertificate) {
        throw "Catalog has no signer certificate: $($Package.Cat)"
    }

    $expectedCatalog = $ExpectedCatalogSignerThumbprint.Replace(' ', '').ToUpperInvariant()
    $expectedExecutable = $ExpectedExecutableSignerThumbprint.Replace(' ', '').ToUpperInvariant()
    foreach ($thumbprint in @($expectedCatalog, $expectedExecutable)) {
        if ($thumbprint -cnotmatch '^[0-9A-F]{40}$') {
            throw "Signer thumbprint must contain exactly 40 hexadecimal characters: '$thumbprint'"
        }
    }
    $actual = $catalogSignature.SignerCertificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
    if ($actual -ne $expectedCatalog) {
        throw "Catalog signer '$actual' does not match the required thumbprint '$expectedCatalog'."
    }
    foreach ($executable in Get-ChildItem -LiteralPath $Package.Directory -Filter *.exe -File) {
        $signature = Get-AuthenticodeSignature -LiteralPath $executable.FullName
        $executableSigner = if ($signature.SignerCertificate) {
            $signature.SignerCertificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
        } else {
            ''
        }
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
            $executableSigner -ne $expectedExecutable) {
            throw "User-mode binary is not validly signed by '$expectedExecutable': $($executable.FullName)"
        }
    }
}

function Get-WinAirPlayDriverPackages {
    $command = Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue
    if (-not $command) {
        throw 'Get-WindowsDriver is unavailable; install/import the DISM PowerShell module.'
    }

    $driverQueryErrors = @()
    try {
        # Some DISM cmdlet failures remain non-terminating despite
        # -ErrorAction Stop. Capture and reject every error record explicitly
        # so a failed query can never be interpreted as an empty Driver Store.
        $drivers = @(Get-WindowsDriver `
                -Online `
                -All `
                -ErrorAction SilentlyContinue `
                -ErrorVariable +driverQueryErrors)
    }
    catch {
        throw [InvalidOperationException]::new(
            "Driver Store enumeration failed: $($_.Exception.Message)",
            $_.Exception)
    }
    if ($driverQueryErrors.Count -ne 0) {
        $messages = @($driverQueryErrors |
                ForEach-Object { $_.Exception.Message } |
                Sort-Object -Unique)
        throw "Driver Store enumeration failed: $($messages -join '; ')"
    }
    foreach ($driver in $drivers) {
        $originalName = if ($driver.OriginalFileName) {
            Split-Path -Leaf $driver.OriginalFileName
        } else {
            ''
        }

        if ($driver.ProviderName -ieq $script:WinAirPlayProviderName -and
            $originalName -ieq $script:WinAirPlayDriverInfName) {
            [pscustomobject]@{
                PublishedName = $driver.Driver
                OriginalFileName = [string]$driver.OriginalFileName
                ProviderName = $driver.ProviderName
                Date = $driver.Date
                Version = $driver.Version
            }
        }
    }
}

function Get-WinAirPlayInfIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$InfPath
    )

    Assert-WinAirPlayRegularFile -Path $InfPath
    $text = Get-Content -LiteralPath $InfPath -Raw
    $match = [regex]::Match(
        $text,
        '(?im)^\s*DriverVer\s*=\s*(\d{2}/\d{2}/\d{4})\s*,\s*([0-9]+(?:\.[0-9]+){3})\s*$')
    if (-not $match.Success) {
        throw "INF has no exact four-part DriverVer identity: $InfPath"
    }
    [pscustomobject]@{
        Date = [DateTime]::ParseExact(
            $match.Groups[1].Value,
            'MM/dd/yyyy',
            [Globalization.CultureInfo]::InvariantCulture)
        Version = [Version]$match.Groups[2].Value
    }
}

function Test-WinAirPlayStagedPackageMatches {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Driver,

        [Parameter(Mandatory)]
        [pscustomobject]$Package,

        [Parameter(Mandatory)]
        [pscustomobject]$InfIdentity
    )

    if ([Version]$Driver.Version -ne $InfIdentity.Version -or
        ([DateTime]$Driver.Date).Date -ne $InfIdentity.Date.Date) {
        return $false
    }

    $storeRoot = Join-Path $script:WinAirPlaySystemDirectory 'DriverStore\FileRepository'
    $storedInf = [IO.Path]::GetFullPath([string]$Driver.OriginalFileName)
    if (-not $storedInf.StartsWith(
            [IO.Path]::GetFullPath($storeRoot).TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $storedDirectory = [IO.Path]::GetDirectoryName($storedInf)
    $storedSys = Join-Path $storedDirectory 'WinAirPlayAudio.sys'
    $storedCat = Join-Path $storedDirectory 'WinAirPlayAudio.cat'
    foreach ($pair in @(
            @($Package.Inf, $storedInf),
            @($Package.Sys, $storedSys),
            @($Package.Cat, $storedCat))) {
        if (-not (Test-Path -LiteralPath $pair[1] -PathType Leaf)) {
            return $false
        }
        Assert-WinAirPlayRegularFile -Path $pair[1]
        if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
            return $false
        }
    }
    return $true
}

function Assert-WinAirPlayDevicesUsePackages {
    param(
        [Parameter(Mandatory)]
        [string[]]$PublishedNames
    )

    foreach ($device in @(Get-WinAirPlayDevices)) {
        $infProperty = Get-PnpDeviceProperty `
            -InstanceId $device.InstanceId `
            -KeyName 'DEVPKEY_Device_DriverInfPath' `
            -ErrorAction Stop
        if (-not $infProperty -or
            [string]$infProperty.Data -notin $PublishedNames) {
            throw "Device '$($device.InstanceId)' is not bound to the exact staged package."
        }
    }
}

function Get-WinAirPlayDevices {
    $getPnpDevice = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    $getPnpProperty = Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue
    if (-not $getPnpDevice -or -not $getPnpProperty) {
        throw 'The PnpDevice PowerShell module is required to enumerate WinAirPlayAudio devnodes safely.'
    }

    foreach ($device in @(Get-PnpDevice -Class Media -ErrorAction Stop)) {
        $properties = @(Get-PnpDeviceProperty `
                -InstanceId $device.InstanceId `
                -ErrorAction Stop)
        $hardwareIdProperties = @($properties | Where-Object {
                $_.KeyName -eq 'DEVPKEY_Device_HardwareIds'
            })
        if ($hardwareIdProperties.Count -gt 1) {
            throw "PnP returned duplicate hardware-ID properties for '$($device.InstanceId)'."
        }
        if ($hardwareIdProperties.Count -eq 1 -and
            @($hardwareIdProperties[0].Data) -icontains $script:WinAirPlayHardwareId) {
            $device
        }
    }
}

function Remove-WinAirPlayInstallation {
    [CmdletBinding()]
    param(
        [switch]$ForcePackageRemoval,

        [string]$PreserveInstallerSnapshot,

        [switch]$RemoveToolCaches
    )

    $pnputil = Join-Path $script:WinAirPlaySystemDirectory 'pnputil.exe'
    $sc = Join-Path $script:WinAirPlaySystemDirectory 'sc.exe'
    $installedService = Join-Path `
        $script:WinAirPlayInstallDirectory `
        $script:WinAirPlayServiceExecutable

    # Complete every ownership and path check before the first mutation. The
    # installer intentionally does not inspect or reconcile old version data.
    $inventory = Get-WinAirPlayInstallationInventory
    if ($inventory.UserService) {
        if (-not (Test-WinAirPlayServiceDefinition `
                    -Service $inventory.UserService `
                    -ExpectedExecutablePath $installedService)) {
            throw 'Refusing cleanup because the existing service account or executable path is not owned by WinAirPlayAudio.'
        }
        if ($inventory.UserService.State -notin @('Running', 'Stopped')) {
            throw "Refusing cleanup while the user service is in transitional state '$($inventory.UserService.State)'."
        }
    }
    if ($inventory.FirewallRule) {
        Assert-WinAirPlayFirewallRuleOwnership `
            -Rule $inventory.FirewallRule `
            -ExpectedExecutablePath $installedService
    }
    foreach ($driver in $inventory.DriverPackages) {
        if ([string]$driver.PublishedName -notmatch '^oem\d+\.inf$') {
            throw "Refusing to delete an unexpected published INF name: '$($driver.PublishedName)'"
        }
    }
    if ($inventory.RuntimeExists) {
        Assert-WinAirPlayTrustedDirectory `
            -Path $script:WinAirPlayInstallDirectory `
            -RequireProtectedDacl
        Assert-WinAirPlayTreeHasNoReparsePoints `
            -Path $script:WinAirPlayInstallDirectory
    }
    if ($inventory.StateExists) {
        Assert-WinAirPlayTrustedDirectory `
            -Path $script:WinAirPlayStateDirectory `
            -RequireProtectedDacl
        Assert-WinAirPlayTreeHasNoReparsePoints `
            -Path $script:WinAirPlayStateDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($PreserveInstallerSnapshot)) {
        $preserved = [IO.Path]::GetFullPath($PreserveInstallerSnapshot)
        $snapshotRoot = [IO.Path]::GetFullPath(
            $script:WinAirPlayInstallerStagingRoot)
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($preserved),
                $snapshotRoot) -or
            [IO.Path]::GetFileName($preserved) -cnotmatch '^[0-9a-f]{32}$' -or
            -not (Test-Path -LiteralPath $preserved -PathType Container)) {
            throw "The active installer snapshot cannot be preserved safely: $PreserveInstallerSnapshot"
        }
    }
    if ($RemoveToolCaches) {
        # Validate the complete cache shape before stopping or deleting the
        # product service so an unsafe cache cannot cause a partial uninstall.
        $signingToolSnapshots =
            @(Get-WinAirPlaySigningToolSnapshotDirectories)
    }

    $service = if ($inventory.UserService) {
        Get-Service -Name $script:WinAirPlayUserServiceName -ErrorAction Stop
    }
    else {
        $null
    }
    try {
        if ($service -and $service.Status -ne 'Stopped') {
            Stop-Service `
                -Name $script:WinAirPlayUserServiceName `
                -Force `
                -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
    }
    finally {
        if ($service) {
            $service.Dispose()
        }
    }

    if ($inventory.FirewallRule) {
        Remove-WinAirPlayFirewallRule `
            -Rule $inventory.FirewallRule `
            -ExpectedExecutablePath $installedService
    }

    # Delete the endpoint owner before PnP cleanup so it cannot recreate
    # handle-lifetime software devices while the old package is removed.
    if ($inventory.UserService) {
        Invoke-WinAirPlayNative -FilePath $sc -ArgumentList @(
            'delete', $script:WinAirPlayUserServiceName
        ) | ForEach-Object { Write-Host $_ }
        $serviceDeadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $remainingService = Get-WinAirPlayUserService
            if (-not $remainingService) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $serviceDeadline)
        if ($remainingService) {
            throw "SCM still reports $($script:WinAirPlayUserServiceName) after bounded deletion wait."
        }
    }

    foreach ($device in @(Get-WinAirPlayDevices)) {
        Write-Host "Removing devnode $($device.InstanceId)"
        Invoke-WinAirPlayNative `
            -FilePath $pnputil `
            -ArgumentList @('/remove-device', $device.InstanceId, '/subtree') |
            ForEach-Object { Write-Host $_ }
    }
    $deviceDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $remainingDevices = @(Get-WinAirPlayDevices)
        if ($remainingDevices.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deviceDeadline)
    if ($remainingDevices.Count -ne 0) {
        throw "PnP removal left $($remainingDevices.Count) matching WinAirPlayAudio devnode(s)."
    }

    # Deleting a Driver Store package while its kernel service is still loaded
    # makes cleanup state ambiguous and can turn a bounded update into a live
    # driver teardown. Fail closed before changing the Driver Store; a reboot
    # is the only supported continuation when PnP has not completed the unload.
    $kernelUnloadDeadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $loadedKernelService = Get-WinAirPlayKernelService
        $kernelServiceStopped =
            Test-WinAirPlayKernelServiceStopped -Service $loadedKernelService
        if ($kernelServiceStopped) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $kernelUnloadDeadline)
    if (-not $kernelServiceStopped) {
        throw "Kernel driver '$($script:WinAirPlayKernelServiceName)' is still loaded after PnP removal. Reboot is required; Driver Store packages were not changed."
    }

    foreach ($driver in @(Get-WinAirPlayDriverPackages)) {
        if ([string]$driver.PublishedName -notmatch '^oem\d+\.inf$') {
            throw "Refusing to delete an unexpected published INF name: '$($driver.PublishedName)'"
        }
        $arguments = @('/delete-driver', $driver.PublishedName, '/uninstall')
        if ($ForcePackageRemoval) {
            $arguments += '/force'
        }
        Write-Host "Deleting Driver Store package $($driver.PublishedName)"
        Invoke-WinAirPlayNative -FilePath $pnputil -ArgumentList $arguments |
            ForEach-Object { Write-Host $_ }
    }
    $remainingDrivers = @(Get-WinAirPlayDriverPackages)
    if ($remainingDrivers.Count -ne 0) {
        throw "Driver Store removal left $($remainingDrivers.Count) matching WinAirPlayAudio package(s)."
    }
    if (Get-WinAirPlayKernelService) {
        throw "SCM still reports kernel driver '$($script:WinAirPlayKernelServiceName)' after package removal. Do not delete its registry entry manually; reboot if PnPUtil requested one, then retry."
    }

    if (Test-Path -LiteralPath $script:WinAirPlayInstallDirectory) {
        Remove-WinAirPlayDirectorySafe `
            -Path $script:WinAirPlayInstallDirectory `
            -AllowedParent $script:WinAirPlayProgramFiles `
            -AllowedLeafPattern '^WinAirPlayAudio$'
    }
    foreach ($transaction in @(Get-WinAirPlayRuntimeTransactionDirectories)) {
        Remove-WinAirPlayDirectorySafe `
            -Path $transaction.FullName `
            -AllowedParent $script:WinAirPlayProgramFiles `
            -AllowedLeafPattern '^WinAirPlayAudio\.(rollback|staging)-[0-9a-f]{32}$'
    }
    if (Test-Path -LiteralPath $script:WinAirPlayStateDirectory) {
        Remove-WinAirPlayDirectorySafe `
            -Path $script:WinAirPlayStateDirectory `
            -AllowedParent $script:WinAirPlayProgramData `
            -AllowedLeafPattern '^WinAirPlayAudio$'
    }

    if ([string]::IsNullOrWhiteSpace($PreserveInstallerSnapshot)) {
        Remove-WinAirPlayInstallerSnapshots -RemoveRoot
    }
    else {
        Remove-WinAirPlayInstallerSnapshots `
            -PreserveSnapshot $PreserveInstallerSnapshot
    }
    if ($RemoveToolCaches) {
        Remove-WinAirPlaySigningToolSnapshots -RemoveRoot
    }

    Assert-WinAirPlayInstallationAbsent `
        -PreserveInstallerSnapshot $PreserveInstallerSnapshot `
        -RequireToolCachesAbsent:$RemoveToolCaches
}

function Get-WinAirPlayDirectoryInventory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$ExpectedFileCount,

        [Parameter(Mandatory)]
        [int]$ExpectedDirectoryCount
    )

    $directory = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or
        ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Signing-tool inventory is not a regular directory: $($directory.FullName)"
    }
    $entries = @(Get-ChildItem `
            -LiteralPath $directory.FullName `
            -Force `
            -Recurse `
            -ErrorAction Stop)
    $directories = @($entries | Where-Object PSIsContainer)
    $files = @($entries | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -ne $ExpectedFileCount -or
        $directories.Count -ne $ExpectedDirectoryCount -or
        @($entries | Where-Object {
                $_.Attributes -band [IO.FileAttributes]::ReparsePoint
            }).Count -ne 0) {
        throw "Signing-tool runtime '$($directory.FullName)' must contain exactly $ExpectedFileCount regular files and $ExpectedDirectoryCount regular directories."
    }

    $directoryEntries = @($directories |
            ForEach-Object {
                [pscustomobject]@{
                    Entry = $_
                    Relative = [IO.Path]::GetRelativePath(
                        $directory.FullName,
                        $_.FullName).Replace('\', '/')
                }
            } |
            Sort-Object -Property Relative -CaseSensitive)
    $fileEntries = @($files |
            ForEach-Object {
                [pscustomobject]@{
                    Entry = $_
                    Relative = [IO.Path]::GetRelativePath(
                        $directory.FullName,
                        $_.FullName).Replace('\', '/')
                }
            } |
            Sort-Object -Property Relative -CaseSensitive)
    [int64]$maximumFileBytes = 32MB
    [int64]$maximumInventoryBytes = 64MB
    [int64]$totalBytes = 0
    $records = [Collections.Generic.List[string]]::new()
    foreach ($directoryEntry in $directoryEntries) {
        Assert-WinAirPlayTrustedDirectory `
            -Path $directoryEntry.Entry.FullName `
            -RequireProtectedDacl
        $records.Add("D|$($directoryEntry.Relative)")
    }
    foreach ($fileEntry in $fileEntries) {
        $entry = $fileEntry.Entry
        Assert-WinAirPlayRegularFile -Path $entry.FullName
        if ($entry.Length -lt 0 -or
            $entry.Length -gt $maximumFileBytes -or
            $totalBytes -gt ($maximumInventoryBytes - $entry.Length)) {
            throw "Signing-tool runtime exceeds its bounded inventory at '$($entry.Name)'."
        }
        $hash = (Get-FileHash `
                -LiteralPath $entry.FullName `
                -Algorithm SHA256 `
                -ErrorAction Stop).Hash
        $records.Add("F|$($fileEntry.Relative)|$($entry.Length)|$hash")
        $totalBytes += $entry.Length
    }
    $inventoryText = ($records -join "`n") + "`n"
    $inventoryHash = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($inventoryText)))
    return [pscustomobject]@{
        FileCount = $fileEntries.Count
        DirectoryCount = $directoryEntries.Count
        TotalBytes = $totalBytes
        Sha256 = $inventoryHash
    }
}

function Copy-WinAirPlayAuthenticatedToolRuntime {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,

        [Parameter(Mandatory)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory)]
        [int]$ExpectedFileCount,

        [Parameter(Mandatory)]
        [int]$ExpectedDirectoryCount,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9A-Fa-f]{64}$')]
        [string]$ExpectedInventorySha256
    )

    $source = Get-Item -LiteralPath $SourceDirectory -Force -ErrorAction Stop
    if (-not $source.PSIsContainer -or
        ($source.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Pinned signing-tool source is not a regular directory: $($source.FullName)"
    }
    $sourceEntries = @(Get-ChildItem `
            -LiteralPath $source.FullName `
            -Force `
            -Recurse `
            -ErrorAction Stop)
    $sourceDirectories = @($sourceEntries | Where-Object PSIsContainer)
    $sourceFiles = @($sourceEntries | Where-Object { -not $_.PSIsContainer })
    if ($sourceFiles.Count -ne $ExpectedFileCount -or
        $sourceDirectories.Count -ne $ExpectedDirectoryCount -or
        @($sourceEntries | Where-Object {
                $_.Attributes -band [IO.FileAttributes]::ReparsePoint
            }).Count -ne 0) {
        throw "Pinned signing-tool source '$($source.FullName)' must contain exactly $ExpectedFileCount regular files and $ExpectedDirectoryCount regular directories. Rerun '.\build.ps1 -Bootstrap' from a clean source tree."
    }
    $sourceDirectoryEntries = @($sourceDirectories |
            ForEach-Object {
                [pscustomobject]@{
                    Entry = $_
                    Relative = [IO.Path]::GetRelativePath(
                        $source.FullName,
                        $_.FullName).Replace('\', '/')
                }
            } |
            Sort-Object `
                @{ Expression = { ($_.Relative -split '/').Count } },
                @{ Expression = { $_.Relative } } `
                -CaseSensitive)
    $sourceFileEntries = @($sourceFiles |
            ForEach-Object {
                [pscustomobject]@{
                    Entry = $_
                    Relative = [IO.Path]::GetRelativePath(
                        $source.FullName,
                        $_.FullName).Replace('\', '/')
                }
            } |
            Sort-Object -Property Relative -CaseSensitive)

    New-WinAirPlaySecureDirectory -Path $DestinationDirectory
    foreach ($sourceDirectoryEntry in $sourceDirectoryEntries) {
        $destinationSubdirectory = Join-Path `
            $DestinationDirectory `
            $sourceDirectoryEntry.Relative.Replace('/', '\')
        New-WinAirPlaySecureDirectory -Path $destinationSubdirectory
    }
    $buffer = [byte[]]::new(1MB)
    [int64]$maximumFileBytes = 32MB
    [int64]$maximumRuntimeBytes = 64MB
    [int64]$copiedRuntimeBytes = 0
    foreach ($sourceFileEntry in $sourceFileEntries) {
        $sourceEntry = $sourceFileEntry.Entry
        Assert-WinAirPlayRegularFile -Path $sourceEntry.FullName
        $sourceStream = $null
        $destinationStream = $null
        try {
            # FileShare.Read denies replacement, deletion, and mutation while
            # the bytes that will be authenticated are copied.
            $sourceStream = [IO.FileStream]::new(
                $sourceEntry.FullName,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read,
                1MB,
                [IO.FileOptions]::SequentialScan)
            if ($sourceStream.Length -lt 0 -or
                $sourceStream.Length -gt $maximumFileBytes) {
                throw "Pinned signing-tool file exceeds its bounded copy limit: $($sourceEntry.FullName)"
            }
            $destinationStream = [IO.FileStream]::new(
                (Join-Path `
                    $DestinationDirectory `
                    $sourceFileEntry.Relative.Replace('/', '\')),
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None,
                1MB,
                [IO.FileOptions]::WriteThrough)
            [int64]$copiedFileBytes = 0
            while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($copiedFileBytes -gt ($maximumFileBytes - $read) -or
                    $copiedRuntimeBytes -gt ($maximumRuntimeBytes - $read)) {
                    throw "Pinned signing-tool runtime exceeded its bounded copy limit at '$($sourceEntry.Name)'."
                }
                $destinationStream.Write($buffer, 0, $read)
                $copiedFileBytes += $read
                $copiedRuntimeBytes += $read
            }
            if ($copiedFileBytes -ne $sourceStream.Length) {
                throw "Pinned signing-tool source changed during protected copying: $($sourceEntry.FullName)"
            }
            $destinationStream.Flush($true)
        }
        finally {
            if ($destinationStream) {
                $destinationStream.Dispose()
            }
            if ($sourceStream) {
                $sourceStream.Dispose()
            }
        }
    }

    Assert-WinAirPlayTrustedDirectory `
        -Path $DestinationDirectory `
        -RequireProtectedDacl
    $inventory = Get-WinAirPlayDirectoryInventory `
        -Path $DestinationDirectory `
        -ExpectedFileCount $ExpectedFileCount `
        -ExpectedDirectoryCount $ExpectedDirectoryCount
    $expectedHash = $ExpectedInventorySha256.ToUpperInvariant()
    if ($inventory.Sha256 -cne $expectedHash) {
        throw "Pinned signing-tool runtime inventory '$($inventory.Sha256)' does not match trusted inventory '$expectedHash'. The restored SDK/WDK content is not the audited version."
    }
}

function Get-WinAirPlaySigningToolSnapshotDirectories {
    if (-not (Test-Path -LiteralPath $script:WinAirPlaySigningToolRoot)) {
        return @()
    }
    Assert-WinAirPlayTrustedDirectory `
        -Path $script:WinAirPlaySigningToolRoot `
        -RequireProtectedDacl
    $snapshots = @(Get-ChildItem `
            -LiteralPath $script:WinAirPlaySigningToolRoot `
            -Force `
            -ErrorAction Stop)
    foreach ($snapshot in $snapshots) {
        if (-not $snapshot.PSIsContainer -or
            $snapshot.Name -cnotmatch '^[0-9a-f]{32}$') {
            throw "Signing-tool snapshot root contains an unexpected entry: $($snapshot.FullName)"
        }
        Assert-WinAirPlayTrustedDirectory `
            -Path $snapshot.FullName `
            -RequireProtectedDacl
        Assert-WinAirPlayTreeHasNoReparsePoints -Path $snapshot.FullName
    }
    return $snapshots
}

function Remove-WinAirPlaySigningToolSnapshots {
    param([switch]$RemoveRoot)

    if (-not (Test-Path -LiteralPath $script:WinAirPlaySigningToolRoot)) {
        return
    }
    foreach ($snapshot in @(Get-WinAirPlaySigningToolSnapshotDirectories)) {
        Remove-WinAirPlayDirectorySafe `
            -Path $snapshot.FullName `
            -AllowedParent $script:WinAirPlaySigningToolRoot `
            -AllowedLeafPattern '^[0-9a-f]{32}$'
    }
    if (@(Get-ChildItem `
                -LiteralPath $script:WinAirPlaySigningToolRoot `
                -Force `
                -ErrorAction Stop).Count -ne 0) {
        throw 'Signing-tool snapshot root is not empty after cleanup.'
    }
    if ($RemoveRoot) {
        Remove-WinAirPlayDirectorySafe `
            -Path $script:WinAirPlaySigningToolRoot `
            -AllowedParent $script:WinAirPlayProgramData `
            -AllowedLeafPattern '^WinAirPlayAudioSigningTools$'
    }
}

function New-WinAirPlaySigningToolSnapshot {
    $inf2CatSource = Join-Path `
        $script:WinAirPlayRepositoryRoot `
        "driver\packages\Microsoft.Windows.WDK.x64.$($script:WinAirPlayPinnedKitPackageVersion)\c\bin\$($script:WinAirPlayPinnedKitToolVersion)\x86"
    $signToolSource = Join-Path `
        $script:WinAirPlayRepositoryRoot `
        "driver\packages\Microsoft.Windows.SDK.CPP.$($script:WinAirPlayPinnedKitPackageVersion)\c\bin\$($script:WinAirPlayPinnedKitToolVersion)\x64"
    if (-not (Test-Path -LiteralPath $inf2CatSource -PathType Container -ErrorAction Stop) -or
        -not (Test-Path -LiteralPath $signToolSource -PathType Container -ErrorAction Stop)) {
        throw "Pinned SDK/WDK $($script:WinAirPlayPinnedKitPackageVersion) signing tools are missing. Run '.\build.ps1 -Bootstrap' from the repository root."
    }

    $rootOwned = $false
    $root = $null
    $snapshot = $null
    $snapshotOwned = $false
    try {
        if (Test-Path -LiteralPath $script:WinAirPlaySigningToolRoot) {
            Remove-WinAirPlaySigningToolSnapshots
        }
        else {
            $rootOwned = $true
            New-WinAirPlaySecureDirectory -Path $script:WinAirPlaySigningToolRoot
        }
        $root = Get-Item -LiteralPath $script:WinAirPlaySigningToolRoot -Force
        $snapshot = Join-Path $root.FullName ([Guid]::NewGuid().ToString('N'))
        $snapshotOwned = $true
        New-WinAirPlaySecureDirectory -Path $snapshot
        $inf2CatDirectory = Join-Path $snapshot 'inf2cat'
        $signToolDirectory = Join-Path $snapshot 'signtool'
        $temporaryDirectory = Join-Path $snapshot 'temp'
        Copy-WinAirPlayAuthenticatedToolRuntime `
            -SourceDirectory $inf2CatSource `
            -DestinationDirectory $inf2CatDirectory `
            -ExpectedFileCount 7 `
            -ExpectedDirectoryCount 0 `
            -ExpectedInventorySha256 '1E8266FBECB18A50B42DDD05A6D4767EA8E5E22A2E834E4334631FC3A7DC1DBE'
        Copy-WinAirPlayAuthenticatedToolRuntime `
            -SourceDirectory $signToolSource `
            -DestinationDirectory $signToolDirectory `
            -ExpectedFileCount 61 `
            -ExpectedDirectoryCount 4 `
            -ExpectedInventorySha256 '84AD4A35AC716CF38868B584A7271D5A16DD0B79E125D438F206A32955AC4BD9'
        New-WinAirPlaySecureDirectory -Path $temporaryDirectory
        $snapshotEntries = @(Get-ChildItem `
                -LiteralPath $snapshot `
                -Force `
                -ErrorAction Stop)
        if ($snapshotEntries.Count -ne 3 -or
            @($snapshotEntries | Where-Object {
                    -not $_.PSIsContainer -or
                    $_.Name -notin @('inf2cat', 'signtool', 'temp')
                }).Count -ne 0) {
            throw 'Protected signing-tool snapshot has an unexpected runtime layout.'
        }
        return [pscustomobject]@{
            SnapshotDirectory = $snapshot
            Inf2CatPath = Join-Path $inf2CatDirectory 'Inf2Cat.exe'
            Inf2CatWorkingDirectory = $inf2CatDirectory
            SignToolPath = Join-Path $signToolDirectory 'signtool.exe'
            SignToolWorkingDirectory = $signToolDirectory
            TemporaryDirectory = $temporaryDirectory
        }
    }
    catch {
        $snapshotFailure = $_
        $cleanupProblems = [Collections.Generic.List[string]]::new()
        if ($snapshotOwned -and $snapshot -and
            (Test-Path -LiteralPath $snapshot)) {
            try {
                Remove-WinAirPlayDirectorySafe `
                    -Path $snapshot `
                    -AllowedParent $root.FullName `
                    -AllowedLeafPattern '^[0-9a-f]{32}$'
            }
            catch {
                $cleanupProblems.Add($_.Exception.Message)
            }
        }
        if ($rootOwned -and
            (Test-Path -LiteralPath $script:WinAirPlaySigningToolRoot)) {
            try {
                Remove-WinAirPlayDirectorySafe `
                    -Path $script:WinAirPlaySigningToolRoot `
                    -AllowedParent $script:WinAirPlayProgramData `
                    -AllowedLeafPattern '^WinAirPlayAudioSigningTools$'
            }
            catch {
                $cleanupProblems.Add($_.Exception.Message)
            }
        }
        if ($cleanupProblems.Count -ne 0) {
            throw [InvalidOperationException]::new(
                "Signing-tool snapshot creation failed and rollback was incomplete: $($cleanupProblems -join '; ')",
                $snapshotFailure.Exception)
        }
        throw $snapshotFailure
    }
}

function Remove-WinAirPlaySigningToolSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotDirectory
    )

    $root = [IO.Path]::GetFullPath($script:WinAirPlaySigningToolRoot)
    $snapshot = [IO.Path]::GetFullPath($SnapshotDirectory)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($snapshot),
            $root) -or
        [IO.Path]::GetFileName($snapshot) -cnotmatch '^[0-9a-f]{32}$') {
        throw "Refusing to remove a path outside the signing-tool snapshot root: $snapshot"
    }
    if (Test-Path -LiteralPath $snapshot) {
        Remove-WinAirPlayDirectorySafe `
            -Path $snapshot `
            -AllowedParent $root `
            -AllowedLeafPattern '^[0-9a-f]{32}$'
    }
}

function Invoke-WinAirPlayAuthenticatedTool {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$TemporaryDirectory
    )

    $tool = [IO.Path]::GetFullPath($FilePath)
    $working = [IO.Path]::GetFullPath($WorkingDirectory)
    $temporary = [IO.Path]::GetFullPath($TemporaryDirectory)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($tool),
            $working) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($working),
            [IO.Path]::GetDirectoryName($temporary)) -or
        [IO.Path]::GetFileName($temporary) -cne 'temp') {
        throw "Authenticated tool must execute from its protected runtime directory: $tool"
    }
    Assert-WinAirPlayTrustedDirectory -Path $working -RequireProtectedDacl
    Assert-WinAirPlayTrustedDirectory -Path $temporary -RequireProtectedDacl
    Assert-WinAirPlayRegularFile -Path $tool

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $tool
    $startInfo.WorkingDirectory = $working
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    # The protected application/current directories and Windows system roots
    # are the only native DLL search locations exposed to the elevated tool.
    $startInfo.Environment.Clear()
    $startInfo.Environment['PATH'] = (
        $script:WinAirPlaySystemDirectory,
        $script:WinAirPlayWindowsDirectory -join ';')
    $startInfo.Environment['SystemRoot'] = $script:WinAirPlayWindowsDirectory
    $startInfo.Environment['WINDIR'] = $script:WinAirPlayWindowsDirectory
    $startInfo.Environment['ComSpec'] = Join-Path $script:WinAirPlaySystemDirectory 'cmd.exe'
    $startInfo.Environment['OS'] = 'Windows_NT'
    $startInfo.Environment['TEMP'] = $temporary
    $startInfo.Environment['TMP'] = $temporary

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start authenticated signing tool '$tool'."
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $combined = @(
            $standardOutput -split '\r?\n'
            $standardError -split '\r?\n'
        ) | Where-Object { $_.Length -ne 0 }
        if ($process.ExitCode -ne 0) {
            throw "'$tool' failed with exit code $($process.ExitCode).$([Environment]::NewLine)$($combined -join [Environment]::NewLine)"
        }
        return @($combined)
    }
    finally {
        $process.Dispose()
    }
}
