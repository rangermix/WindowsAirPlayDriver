# Dot-sourceable from native x64 Windows PowerShell 5.1 and PowerShell 7.
# Installing these shared Microsoft prerequisites requires caller consent and
# elevation. This library never elevates, changes boot policy, or restarts.
Set-StrictMode -Version Latest

$script:WinAirPlaySetupPowerShellVersion = [version]'7.6.9'
$script:WinAirPlaySetupPowerShellMsiSha256 =
    '50D33C7494AAF82B987CFD4DE3F232D04F91FDD4C0DEECA8A669CCED3E7CF8F9'
# The VS 2026 MSVC compiler used for this release is 14.51.36231. The runtime
# must be at least as recent as the build tools; review this floor on upgrades.
$script:WinAirPlaySetupVcMinimumVersion = [version]'14.51.36231.0'

function Assert-WinAirPlaySetupRegularPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') {
        throw 'Setup prerequisites require a local absolute drive path.'
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -ne [bool]$Directory) {
        throw "Unexpected prerequisite file/directory type: $full"
    }
    $current = $full
    while ($current) {
        $ancestor = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Prerequisite path contains a reparse point: $current"
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $item
}

function Assert-WinAirPlaySetupProtectedDownloadDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $item = Assert-WinAirPlaySetupRegularPath -Path $Path -Directory
    $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $allowed -or -not $acl.AreAccessRulesProtected) {
        throw 'Prerequisite download directory must have an administrator/SYSTEM owner and protected DACL.'
    }
    $write = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true,
            [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and
            ($rule.FileSystemRights -band $write) -ne 0 -and
            $rule.IdentityReference.Value -notin $allowed) {
            throw 'Prerequisite download directory grants write access to an unprivileged identity.'
        }
    }
}

function Test-WinAirPlaySetupX64Binary {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { return $false }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { return $false }
        $stream.Position = $offset
        return $reader.ReadUInt32() -eq 0x00004550 -and
            $reader.ReadUInt16() -eq 0x8664
    }
    finally { $reader.Dispose() }
}

function Assert-WinAirPlaySetupMicrosoftSignature {
    param([Parameter(Mandatory)][string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status.ToString() -cne 'Valid' -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false) -cne 'Microsoft Corporation' -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw "Prerequisite must have a valid Microsoft Corporation Authenticode signature: $Path"
    }
}

function Get-WinAirPlaySetupDownloadRemainingMilliseconds {
    param([Parameter(Mandatory)][object]$Timer,
        [int]$DeadlineMilliseconds = 180000)
    $remaining = [int64]$DeadlineMilliseconds - [int64]$Timer.ElapsedMilliseconds
    if ($remaining -le 0) {
        throw 'Prerequisite download exceeded its absolute 180 second deadline.'
    }
    return [int]$remaining
}

function Copy-WinAirPlaySetupDownloadStream {
    param([Parameter(Mandatory)][IO.Stream]$InputStream,
        [Parameter(Mandatory)][IO.Stream]$OutputStream,
        [Parameter(Mandatory)][object]$Timer,
        [int]$DeadlineMilliseconds = 180000)
    $buffer = New-Object byte[] 65536
    [int64]$total = 0
    while ($true) {
        $remaining = Get-WinAirPlaySetupDownloadRemainingMilliseconds `
            -Timer $Timer -DeadlineMilliseconds $DeadlineMilliseconds
        if ($InputStream.CanTimeout) { $InputStream.ReadTimeout = $remaining }
        # HttpWebRequest response streams differ between .NET Framework and
        # .NET. Bound the wait even when a stream cannot expose ReadTimeout.
        $read = $InputStream.ReadAsync($buffer, 0, $buffer.Length)
        if (-not $read.Wait($remaining)) {
            throw 'Prerequisite download exceeded its absolute 180 second deadline.'
        }
        $count = $read.GetAwaiter().GetResult()
        $null = Get-WinAirPlaySetupDownloadRemainingMilliseconds `
            -Timer $Timer -DeadlineMilliseconds $DeadlineMilliseconds
        if ($count -eq 0) { return }
        $total += $count
        if ($total -gt 128MB) { throw 'Prerequisite download exceeded 128 MiB.' }
        $OutputStream.Write($buffer, 0, $count)
    }
}

function Save-WinAirPlaySetupHttpsFile {
    param([Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Destination)
    # Follow only HTTPS redirects, cap both declared and streamed bytes, and
    # never overwrite an existing file in the protected download directory.
    $current = $Uri
    $response = $null
    $request = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor
            [Net.SecurityProtocolType]::Tls12
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            if ($current.Scheme -cne 'https' -or $current.UserInfo) {
                throw 'Prerequisite downloads and redirects must use credential-free HTTPS.'
            }
            $request = [Net.HttpWebRequest]::Create($current)
            $request.AllowAutoRedirect = $false
            $remaining = Get-WinAirPlaySetupDownloadRemainingMilliseconds -Timer $timer
            $request.Timeout = $remaining
            $request.ReadWriteTimeout = $remaining
            $request.UserAgent = 'WinAirPlayAudio-Setup/1'
            $responseTask = $request.GetResponseAsync()
            if (-not $responseTask.Wait($remaining)) {
                throw 'Prerequisite download exceeded its absolute 180 second deadline.'
            }
            $response = $responseTask.GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                if ($redirect -eq 5 -or -not $response.Headers['Location']) {
                    throw 'Prerequisite download exceeded its redirect bound.'
                }
                $current = [uri]::new($current, $response.Headers['Location'])
                $response.Close()
                $response = $null
                continue
            }
            if ($status -ne 200 -or $response.ContentLength -gt 128MB) {
                throw 'Prerequisite download has an invalid status or oversized content length.'
            }
            $inputStream = $response.GetResponseStream()
            try {
                $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    Copy-WinAirPlaySetupDownloadStream -InputStream $inputStream `
                        -OutputStream $outputStream -Timer $timer
                }
                finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
            return
        }
    }
    finally {
        if ($request) { $request.Abort() }
        if ($response) { $response.Close() }
        $timer.Stop()
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    }
}

function Get-WinAirPlaySetupDependencyStatus {
    param([switch]$PowerShellOnly)
    $programFiles = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFiles)
    $powerShellPath = Join-Path $programFiles 'PowerShell\7\pwsh.exe'
    $powerShellInstalled = $false
    $powerShellVersion = $null
    if (Test-Path -LiteralPath $powerShellPath -PathType Leaf) {
        $file = Assert-WinAirPlaySetupRegularPath -Path $powerShellPath
        $versionText = $file.VersionInfo.ProductVersion
        # ProductVersion is semver with an optional build SHA. Prereleases do
        # not satisfy this stable runtime gate.
        if ($versionText -match '^([0-9]+\.[0-9]+\.[0-9]+)(?:(?:\+[0-9A-Za-z.+-]+)|(?: SHA: [0-9a-f]+(?:\+[0-9a-f]+)?))?$') {
            $powerShellVersion = [version]$Matches[1]
            if ($powerShellVersion -ge $script:WinAirPlaySetupPowerShellVersion -and
                (Test-WinAirPlaySetupX64Binary -Path $powerShellPath)) {
                Assert-WinAirPlaySetupMicrosoftSignature -Path $powerShellPath
                $powerShellInstalled = $true
            }
        }
    }

    # Recovery does not execute the service and must not depend on a healthy
    # VC registry/DLL installation. Keep the normal setup probe unchanged.
    if ($PowerShellOnly) {
        return [pscustomobject]@{
            PowerShellPath = $(if ($powerShellInstalled) { $powerShellPath } else { $null })
            PowerShellInstalled = $powerShellInstalled
            PowerShellVersion = $powerShellVersion
            VcRuntimeInstalled = $false
            VcRuntimeVersion = $null
        }
    }
    $vcRuntimeInstalled = $false
    $vcVersion = $null
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')
        if ($null -ne $key) {
            try {
                $parsedVersion = $null
                $text = ([string]$key.GetValue('Version', '')).TrimStart('v', 'V')
                if ([version]::TryParse($text, [ref]$parsedVersion)) {
                    $vcVersion = $parsedVersion
                    $vcRuntimeInstalled = $key.GetValue('Installed', 0) -eq 1 -and
                        $vcVersion -ge $script:WinAirPlaySetupVcMinimumVersion
                }
            }
            finally { $key.Dispose() }
        }
    }
    finally { $base.Dispose() }
    if ($vcRuntimeInstalled) {
        foreach ($name in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
            $path = Join-Path ([Environment]::SystemDirectory) $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $vcRuntimeInstalled = $false
                break
            }
            $file = Assert-WinAirPlaySetupRegularPath -Path $path
            $info = $file.VersionInfo
            $version = [version]::new($info.FileMajorPart, $info.FileMinorPart,
                $info.FileBuildPart, $info.FilePrivatePart)
            if ($version -lt $script:WinAirPlaySetupVcMinimumVersion -or
                -not (Test-WinAirPlaySetupX64Binary -Path $path)) {
                $vcRuntimeInstalled = $false
                break
            }
        }
    }
    return [pscustomobject]@{
        PowerShellPath = $(if ($powerShellInstalled) { $powerShellPath } else { $null })
        PowerShellInstalled = $powerShellInstalled
        PowerShellVersion = $powerShellVersion
        VcRuntimeInstalled = $vcRuntimeInstalled
        VcRuntimeVersion = $vcVersion
    }
}

function Get-WinAirPlaySetupPrerequisite {
    param(
        [Parameter(Mandatory)][ValidateSet('PowerShell', 'VcRuntime')][string]$Name,
        [Parameter(Mandatory)][string]$DownloadDirectory,
        [string]$PrerequisiteDirectory
    )
    Assert-WinAirPlaySetupProtectedDownloadDirectory -Path $DownloadDirectory
    $fileName = if ($Name -ceq 'PowerShell') {
        "PowerShell-$($script:WinAirPlaySetupPowerShellVersion)-win-x64.msi"
    } else { 'vc_redist.x64.exe' }
    $destination = Join-Path $DownloadDirectory $fileName
    if (Test-Path -LiteralPath $destination) {
        throw "Prerequisite destination already exists; use a fresh protected download directory: $destination"
    }
    if ($PrerequisiteDirectory) {
        $null = Assert-WinAirPlaySetupRegularPath -Path $PrerequisiteDirectory -Directory
        $source = Assert-WinAirPlaySetupRegularPath -Path (Join-Path $PrerequisiteDirectory $fileName)
        if ($source.Length -le 0 -or $source.Length -gt 128MB) {
            throw 'Offline prerequisite exceeds the bounded input size.'
        }
        # Refuse writers/deleters during the snapshot; execute only the copy
        # below the protected administrator-owned directory.
        $inputStream = [IO.File]::Open($source.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose() }
        }
        finally { $inputStream.Dispose() }
    }
    else {
        $uri = if ($Name -ceq 'PowerShell') {
            "https://github.com/PowerShell/PowerShell/releases/download/v$($script:WinAirPlaySetupPowerShellVersion)/$fileName"
        } else { 'https://aka.ms/vc14/vc_redist.x64.exe' }
        Save-WinAirPlaySetupHttpsFile -Uri $uri -Destination $destination
    }
    $file = Assert-WinAirPlaySetupRegularPath -Path $destination
    if ($file.Length -le 0 -or $file.Length -gt 128MB) {
        throw 'Prerequisite payload exceeds the bounded input size.'
    }
    Assert-WinAirPlaySetupMicrosoftSignature -Path $destination
    if ($Name -ceq 'PowerShell') {
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne
            $script:WinAirPlaySetupPowerShellMsiSha256) {
            throw 'PowerShell x64 MSI does not match the pinned official release SHA-256.'
        }
    }
    else {
        $version = $null
        if ($file.VersionInfo.ProductName -notmatch '^Microsoft Visual C\+\+ (?:v14|2015-2022) Redistributable \(x64\)(?: - [0-9.]+)?$' -or
            $file.VersionInfo.OriginalFilename -ine 'VC_redist.x64.exe' -or
            -not [version]::TryParse($file.VersionInfo.ProductVersion, [ref]$version) -or
            $version -lt $script:WinAirPlaySetupVcMinimumVersion) {
            throw 'VC prerequisite must be the Microsoft x64 v14 Redistributable at or above the release runtime floor.'
        }
    }
    return $destination
}

function Invoke-WinAirPlaySetupPrerequisiteProcess {
    param([Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Arguments)
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments `
        -WindowStyle Hidden -PassThru -ErrorAction Stop
    try {
        if (-not $process.WaitForExit(900000)) {
            $process.Kill()
            throw 'Prerequisite installer exceeded its 15 minute bound; inspect Windows Installer state before retrying.'
        }
        $code = $process.ExitCode
        if ($code -notin @(0, 3010, 1638)) {
            throw "Prerequisite installer failed with exit code $code. No driver installation was attempted."
        }
        return $code
    }
    finally { $process.Dispose() }
}

function Assert-WinAirPlaySetupDependencyAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
        -not [Environment]::Is64BitProcess) {
        throw 'Prerequisite installation requires an elevated native x64 setup process.'
    }
    $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    if ($processors.Count -eq 0 -or
        @($processors | Where-Object { [uint16]$_.Architecture -ne 9 }).Count -ne 0) {
        throw 'Prerequisite installation supports native x64 Windows only; ARM64/emulated hosts are unsupported.'
    }
}

function Install-WinAirPlaySetupDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DownloadDirectory,
        [string]$PrerequisiteDirectory)
    Assert-WinAirPlaySetupDependencyAdministrator
    Assert-WinAirPlaySetupProtectedDownloadDirectory -Path $DownloadDirectory
    $status = Get-WinAirPlaySetupDependencyStatus
    $reboot = $false
    # Install the VC runtime first so the newly installed PowerShell and the
    # service can both load their native dependencies.
    foreach ($name in @('VcRuntime', 'PowerShell')) {
        $present = if ($name -ceq 'VcRuntime') {
            $status.VcRuntimeInstalled
        } else { $status.PowerShellInstalled }
        if ($present) { continue }
        $path = Get-WinAirPlaySetupPrerequisite -Name $name `
            -DownloadDirectory $DownloadDirectory -PrerequisiteDirectory $PrerequisiteDirectory
        Write-Host "Installing Microsoft prerequisite: $name"
        if ($name -ceq 'PowerShell') {
            $code = Invoke-WinAirPlaySetupPrerequisiteProcess `
                -Path (Join-Path ([Environment]::SystemDirectory) 'msiexec.exe') `
                -Arguments @('/i', ('"' + $path + '"'), '/quiet', '/norestart',
                    'ENABLE_PSREMOTING=0', 'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0',
                    'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=0', 'ADD_PATH=1',
                    'USE_MU=1', 'ENABLE_MU=1')
        }
        else {
            $code = Invoke-WinAirPlaySetupPrerequisiteProcess -Path $path `
                -Arguments @('/install', '/quiet', '/norestart')
        }
        if ($code -eq 3010) { $reboot = $true }
        $status = Get-WinAirPlaySetupDependencyStatus
        $satisfied = if ($name -ceq 'VcRuntime') {
            $status.VcRuntimeInstalled
        } else { $status.PowerShellInstalled }
        if (-not $satisfied) {
            throw "Prerequisite $name returned $code but its installed x64 runtime/version postcondition is unmet. Reboot if requested and retry setup."
        }
    }
    return [pscustomobject]@{
        RebootRequired = $reboot
        PowerShellPath = $status.PowerShellPath
    }
}
