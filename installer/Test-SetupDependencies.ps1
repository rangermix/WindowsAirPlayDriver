[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$library = Join-Path $PSScriptRoot 'Setup-Dependencies.ps1'
$passed = [Collections.Generic.List[string]]::new()
function Assert-SetupFixture([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-SetupRejected([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    if (-not $failure -or $failure.Exception.Message -notmatch $Pattern) {
        throw "Expected rejection matching '$Pattern'; received '$failure'."
    }
}

& {
    . $library
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($library,[ref]$tokens,[ref]$errors)
    $function=$ast.Find({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Get-WinAirPlaySetupDependencyStatus'
    },$true)
    $registryCall=$function.Find({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Static -and $node.Member.Extent.Text -ceq 'OpenBaseKey'
    },$true)
    Assert-SetupFixture ($null -ne $registryCall) 'Cannot inject the unavailable VC registry fixture.'
    # Replace only the host registry call with a fault; execute the actual
    # status function to prove recovery never reaches unrelated VC inspection.
    $faultedFunction=$function.Extent.Text.Replace($registryCall.Extent.Text,
        '$(throw ''Fixture VC registry unavailable.'')')
    . ([scriptblock]::Create($faultedFunction))
    $status=Get-WinAirPlaySetupDependencyStatus -PowerShellOnly
    Assert-SetupFixture ($status.PowerShellInstalled -is [bool] -and
        -not $status.VcRuntimeInstalled -and $null -eq $status.VcRuntimeVersion) `
        'PowerShell-only recovery probe returned a VC requirement.'
    Assert-SetupRejected { Get-WinAirPlaySetupDependencyStatus } 'Fixture VC registry unavailable'
    $passed.Add('PowerShell-only recovery survives unavailable VC registry; setup still checks VC')
}

& {
    . $library
    # Use the native Windows PowerShell parser as well as the current parser.
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($library,
        [ref]$tokens, [ref]$errors) | Out-Null
    Assert-SetupFixture ($errors.Count -eq 0) 'Dependency library parse failed.'
    $nativePowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    & $nativePowerShell -NoProfile -NonInteractive -Command `
        "`$tokens=`$null; `$errors=`$null; [Management.Automation.Language.Parser]::ParseFile('$($library.Replace("'", "''"))',[ref]`$tokens,[ref]`$errors) | Out-Null; if (`$errors.Count) { exit 1 }"
    Assert-SetupFixture ($LASTEXITCODE -eq 0) 'Windows PowerShell 5.1 parse failed.'
    $passed.Add('PowerShell 7 and Windows PowerShell 5.1 parsing')

    $status = Get-WinAirPlaySetupDependencyStatus
    Assert-SetupFixture ($status.PowerShellInstalled -is [bool] -and
        $status.VcRuntimeInstalled -is [bool]) 'Read-only dependency status is malformed.'
    $passed.Add('actual read-only dependency status')
    Assert-SetupRejected { Save-WinAirPlaySetupHttpsFile -Uri 'http://example.invalid/a' -Destination 'unused' } 'credential-free HTTPS'
    Assert-SetupRejected { Save-WinAirPlaySetupHttpsFile -Uri 'https://user:secret@example.invalid/a' -Destination 'unused' } 'credential-free HTTPS'
    $passed.Add('HTTP and credential-bearing download rejection before network access')
}

& {
    . $library
    $fixtureParent = Join-Path (Split-Path $PSScriptRoot -Parent) '.local\diagnostics'
    $fixtureRoot = Join-Path $fixtureParent ("setup-dependency-fixtures-" + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $source = Join-Path $fixtureRoot 'offline'
    $download = Join-Path $fixtureRoot 'downloads'
    [void][IO.Directory]::CreateDirectory($source)
    [void][IO.Directory]::CreateDirectory($download)
    try {
        Assert-SetupRejected { Assert-WinAirPlaySetupProtectedDownloadDirectory -Path $download } 'protected DACL|write access|administrator/SYSTEM'
        $passed.Add('unprotected download cache rejection')
        function Assert-WinAirPlaySetupProtectedDownloadDirectory { param($Path) }
        function Assert-WinAirPlaySetupMicrosoftSignature { param($Path) }
        $msiName = "PowerShell-$script:WinAirPlaySetupPowerShellVersion-win-x64.msi"
        [IO.File]::WriteAllBytes((Join-Path $source $msiName), [byte[]]@(1, 2, 3))
        Assert-SetupRejected {
            Get-WinAirPlaySetupPrerequisite -Name PowerShell -DownloadDirectory $download -PrerequisiteDirectory $source
        } 'pinned official release SHA-256'
        Assert-SetupFixture ([IO.File]::Exists((Join-Path $download $msiName))) 'Offline payload was not copied into the download cache.'
        Assert-SetupRejected {
            Get-WinAirPlaySetupPrerequisite -Name PowerShell -DownloadDirectory $download -PrerequisiteDirectory $source
        } 'destination already exists'
        $passed.Add('offline PowerShell hash corruption rejection and no cache overwrite')
        [IO.File]::WriteAllBytes((Join-Path $source 'vc_redist.x64.exe'), [byte[]]@(1, 2, 3))
        Assert-SetupRejected {
            Get-WinAirPlaySetupPrerequisite -Name VcRuntime -DownloadDirectory $download -PrerequisiteDirectory $source
        } 'Microsoft x64 v14 Redistributable'
        $passed.Add('wrong offline VC product rejection')
        Assert-SetupFixture (-not (Test-WinAirPlaySetupX64Binary -Path (Join-Path $source 'vc_redist.x64.exe'))) 'Truncated PE input was accepted.'
        $bytes = New-Object byte[] 128
        $bytes[0] = 0x4D; $bytes[1] = 0x5A; $bytes[0x3C] = 64
        $bytes[64] = 0x50; $bytes[65] = 0x45
        $bytes[68] = 0x4C; $bytes[69] = 0x01
        $pePath = Join-Path $source 'pe.exe'
        [IO.File]::WriteAllBytes($pePath, $bytes)
        Assert-SetupFixture (-not (Test-WinAirPlaySetupX64Binary -Path $pePath)) 'x86 PE input was accepted.'
        $bytes[68] = 0x64; $bytes[69] = 0x86
        [IO.File]::WriteAllBytes($pePath, $bytes)
        Assert-SetupFixture (Test-WinAirPlaySetupX64Binary -Path $pePath) 'x64 PE identity was rejected.'
        $passed.Add('truncated/x86 PE rejection and x64 identity')
    }
    finally {
        $resolvedRoot = [IO.Path]::GetFullPath($fixtureRoot)
        $resolvedParent = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
        if (-not $resolvedRoot.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedRoot) -notmatch '^setup-dependency-fixtures-[0-9a-f]{32}$') {
            throw 'Fixture cleanup path escaped the diagnostic parent.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction Stop
        Assert-SetupFixture (-not (Test-Path -LiteralPath $resolvedRoot)) 'Fixture cleanup left files behind.'
    }
}

& {
    . $library
    $script:fixtureSignatureStatus = 'Valid'
    $script:fixturePublisher = 'Microsoft Corporation'
    function Get-AuthenticodeSignature {
        param($LiteralPath, $ErrorAction)
        $certificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' }
        $certificate | Add-Member ScriptMethod GetNameInfo { param($Type, $Issuer) return $script:fixturePublisher }
        return [pscustomobject]@{ Status = $script:fixtureSignatureStatus; SignerCertificate = $certificate }
    }
    Assert-WinAirPlaySetupMicrosoftSignature -Path 'fixture'
    $script:fixtureSignatureStatus = 'NotSigned'
    Assert-SetupRejected { Assert-WinAirPlaySetupMicrosoftSignature -Path 'fixture' } 'valid Microsoft'
    $script:fixtureSignatureStatus = 'Valid'
    $script:fixturePublisher = 'Another Publisher'
    Assert-SetupRejected { Assert-WinAirPlaySetupMicrosoftSignature -Path 'fixture' } 'valid Microsoft'
    $passed.Add('valid Microsoft signer and unsigned/wrong publisher rejection')
}

& {
    . $library
    $script:fixtureProcessCode = 0
    $script:fixtureWait = $true
    $script:fixtureKilled = $false
    $script:fixtureDisposed = $false
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $ErrorAction)
        Assert-SetupFixture ($WindowStyle -ceq 'Hidden') 'Prerequisite process is not hidden.'
        $process = [pscustomobject]@{ ExitCode = $script:fixtureProcessCode }
        $process | Add-Member ScriptMethod WaitForExit { param($Timeout) return $script:fixtureWait }
        $process | Add-Member ScriptMethod Kill { $script:fixtureKilled = $true }
        $process | Add-Member ScriptMethod Dispose { $script:fixtureDisposed = $true }
        return $process
    }
    foreach ($code in @(0, 3010, 1638)) {
        $script:fixtureProcessCode = $code
        $actual = Invoke-WinAirPlaySetupPrerequisiteProcess -Path 'fixture' -Arguments @('/quiet')
        Assert-SetupFixture ($actual -eq $code -and $script:fixtureDisposed) 'Successful prerequisite exit handling failed.'
    }
    foreach ($code in @(1603, 1641, 1)) {
        $script:fixtureProcessCode = $code
        Assert-SetupRejected { Invoke-WinAirPlaySetupPrerequisiteProcess -Path 'fixture' -Arguments @('/quiet') } "exit code $code"
    }
    $script:fixtureWait = $false
    Assert-SetupRejected { Invoke-WinAirPlaySetupPrerequisiteProcess -Path 'fixture' -Arguments @('/quiet') } '15 minute bound'
    Assert-SetupFixture ($script:fixtureKilled -and $script:fixtureDisposed) 'Timed-out process was not killed/disposed.'
    $passed.Add('0/3010/1638, failure/unexpected restart and timeout/disposal handling')
}

& {
    . $library
    $script:fixtureCalls = [Collections.Generic.List[string]]::new()
    $script:fixtureVc = $false
    $script:fixturePwsh = $false
    $script:fixtureInstallTakesEffect = $true
    $script:fixtureExit = 3010
    function Assert-WinAirPlaySetupDependencyAdministrator { }
    function Assert-WinAirPlaySetupProtectedDownloadDirectory { param($Path) }
    function Get-WinAirPlaySetupDependencyStatus {
        return [pscustomobject]@{ VcRuntimeInstalled = $script:fixtureVc;
            PowerShellInstalled = $script:fixturePwsh; PowerShellPath = 'C:\Program Files\PowerShell\7\pwsh.exe' }
    }
    function Get-WinAirPlaySetupPrerequisite {
        param($Name, $DownloadDirectory, $PrerequisiteDirectory)
        $script:fixtureCalls.Add($Name)
        return $(if ($Name -ceq 'PowerShell') { 'C:\protected\pwsh.msi' } else { 'C:\protected\vc.exe' })
    }
    function Invoke-WinAirPlaySetupPrerequisiteProcess {
        param($Path, $Arguments)
        Assert-SetupFixture ('/norestart' -in $Arguments) 'Prerequisite may reboot automatically.'
        if ($script:fixtureInstallTakesEffect) {
            if ($Path.EndsWith('msiexec.exe')) {
                Assert-SetupFixture ('ENABLE_PSREMOTING=0' -in $Arguments) 'PowerShell install enables remoting.'
                $script:fixturePwsh = $true
            } else { $script:fixtureVc = $true }
        }
        return $script:fixtureExit
    }
    $result = Install-WinAirPlaySetupDependencies -DownloadDirectory 'fixture'
    Assert-SetupFixture ($result.RebootRequired -and
        ($script:fixtureCalls -join ',') -ceq 'VcRuntime,PowerShell') 'Install order or reboot propagation failed.'
    $passed.Add('VC-before-PowerShell install, no remoting/automatic restart, 3010 propagation')
    $script:fixtureCalls.Clear()
    $result = Install-WinAirPlaySetupDependencies -DownloadDirectory 'fixture'
    Assert-SetupFixture (-not $result.RebootRequired -and $script:fixtureCalls.Count -eq 0) 'Installed dependencies were not skipped.'
    $passed.Add('idempotent skip of satisfied dependencies')
    $script:fixtureVc = $false
    $script:fixtureInstallTakesEffect = $false
    foreach ($code in @(0, 1638, 3010)) {
        $script:fixtureExit = $code
        Assert-SetupRejected { Install-WinAirPlaySetupDependencies -DownloadDirectory 'fixture' } 'postcondition is unmet'
    }
    $passed.Add('0/1638/3010 never bypass missing installed runtime postconditions')
}

Remove-Variable -Name fixtureSignatureStatus, fixturePublisher, fixtureProcessCode,
    fixtureWait, fixtureKilled, fixtureDisposed, fixtureCalls, fixtureVc, fixturePwsh,
    fixtureInstallTakesEffect, fixtureExit -Scope Script -ErrorAction SilentlyContinue
Write-Host "PASS: $($passed.Count) setup dependency fixture groups; no prerequisite installed."
$passed | ForEach-Object { Write-Host "  $_" }
