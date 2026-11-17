[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$previousExitVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$hadExitVariable = $null -ne $previousExitVariable
$previousExitCode = if ($hadExitVariable) { $previousExitVariable.Value } else { $null }
$publisher = Join-Path $PSScriptRoot 'Publish-Prerelease.ps1'
$temporaryRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '.local/diagnostics/release-workflow-tests'
$null = [IO.Directory]::CreateDirectory($temporaryRoot)
$testRoot = Join-Path $temporaryRoot ("winairplay-release-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$arguments = @{
    Version = '1.2.3-rc.1'
    Tag = 'v1.2.3-rc.1'
    AssetDirectory = $testRoot
    Repository = 'example/WinAirPlayAudio'
    SourceCommit = ('1' * 40)
    WhatIf = $true
}
$archiveName = 'WinAirPlayAudio-1.2.3-rc.1-windows-x64-unsigned.zip'
$archivePath = Join-Path $testRoot $archiveName
$checksumPath = "$archivePath.sha256"
$cases = 0
$installedGhMock = $false

function Assert-WorkflowCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-CiWorkflowSecurity {
    param([string]$Ci)
    $eventBlock = [regex]::Match($Ci, '(?ms)^on:\r?\n(?<events>.*?)(?=^\S|\z)')
    $events = @([regex]::Matches($eventBlock.Groups['events'].Value, '(?m)^  ([a-z_]+):') |
        ForEach-Object { $_.Groups[1].Value })
    $expectedEvents = @('push', 'pull_request', 'workflow_dispatch')
    Assert-WorkflowCondition ($events.Count -eq $expectedEvents.Count -and
        -not (Compare-Object $events $expectedEvents -CaseSensitive) -and
        $eventBlock.Groups['events'].Value -match '(?m)^    branches: \[main\][ \t]*\r?$') `
        'CI must be limited to main pushes, pull requests and manual dispatch.'
    Assert-WorkflowCondition ($Ci -match '(?m)^permissions:\r?\n  contents: read[ \t]*\r?$' -and
        $Ci -notmatch '(?m)^\s*(?:[\w-]+:\s+write\b|permissions:\s+write-all\b)') `
        'CI requires a read-only token.'
    Assert-WorkflowCondition ($Ci -notmatch '(?i)actions/upload-artifact|gh(?:\.exe)?\s+release|Publish-Prerelease\.ps1|Invoke-TestSignedRelease\.ps1|secrets\.WINAIRPLAY_TEST_') `
        'Source-only CI must not upload binaries, sign with private inputs or publish releases.'
    Assert-WorkflowCondition ($Ci.Contains('build.ps1 -GuiWizards -PreviewWizard') -and
        $Ci.Contains('build.ps1 -Configuration $env:BUILD_CONFIGURATION -Test -UserModeOnly') -and
        $Ci.Contains('scripts\Test-InstallerRelease.ps1') -and
        $Ci.Contains('.github\scripts\Test-GuiSigning.ps1') -and
        $Ci.Contains('build.ps1 -Driver -Configuration Debug') -and
        $Ci.Contains('build.ps1 -Package -Configuration Release') -and
        $Ci.Contains('scripts\New-ReleaseBundle.ps1 -Configuration Release')) `
        'CI must compile harmless previews and run source, native driver, installer release and packaging checks.'
    Assert-WorkflowCondition ($Ci -notmatch '(?i)(?:Set-TestSigning|Install-Driver|Uninstall-Driver|New-TestCertificate|Remove-TestCertificate)\.ps1|\bbcdedit(?:\.exe)?\b|pnputil(?:\.exe)?.*/(?:add-driver|delete-driver|remove-device)') `
        'CI must not install/remove drivers, create machine trust or change boot policy.'
    Assert-WorkflowCondition ($Ci -notmatch '(?im)^\s*(?:&\s+|Start-Process[^\r\n]*)(?:[^\r\n]*-Preview\.exe)') `
        'CI may compile GUI previews but must not launch GUI executables.'
    foreach ($match in [regex]::Matches($Ci, '(?m)^\s*uses:\s*([^\r\n #]+)')) {
        $action = $match.Groups[1].Value
        Assert-WorkflowCondition ($action.StartsWith('./', [StringComparison]::Ordinal) -or
            $action -cmatch '^[^@]+@[0-9a-f]{40}$') 'External workflow actions must remain SHA-pinned.'
    }
}

function Assert-WorkflowRejected {
    param([string]$Ci, [string]$ExpectedMessage)
    $rejected = $false
    try { Assert-CiWorkflowSecurity $Ci }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw "Wrong workflow rejection: $($_.Exception.Message)" }
        $rejected = $true
    }
    Assert-WorkflowCondition $rejected 'An unsafe workflow mutation was not rejected.'
    $script:cases++
}

function Assert-Rejected {
    param([hashtable]$Parameters, [string]$ExpectedMessage)
    try {
        & $publisher @Parameters
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Wrong rejection: $($_.Exception.Message)"
        }
        $script:cases++
        return
    }
    throw "Expected rejection containing '$ExpectedMessage'."
}

try {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $workflowDirectory = Join-Path $repoRoot '.github/workflows'
    $workflows = @(Get-ChildItem -LiteralPath $workflowDirectory -File -Force |
        Where-Object { $_.Extension -in '.yml', '.yaml' })
    Assert-WorkflowCondition ($workflows.Count -eq 1 -and $workflows[0].Name -ceq 'ci.yml') `
        'The source-only repository must contain only the CI workflow.'
    $ciWorkflow = Get-Content -LiteralPath $workflows[0].FullName -Raw
    Assert-CiWorkflowSecurity $ciWorkflow
    $cases++
    Assert-WorkflowRejected ($ciWorkflow.Replace('  pull_request:', '  pull_request_target:')) 'limited to main pushes'
    Assert-WorkflowRejected ($ciWorkflow.Replace('contents: read', 'contents: write')) 'read-only token'
    Assert-WorkflowRejected ($ciWorkflow + "`n# prohibited upload: actions/upload-artifact@v7") 'must not upload'
    Assert-WorkflowRejected ($ciWorkflow + "`n# prohibited publisher: Publish-Prerelease.ps1") 'must not upload'
    Assert-WorkflowRejected ($ciWorkflow + "`n# secret exposure: " + '${{ secrets.WINAIRPLAY_TEST_PFX_PASSWORD }}') 'must not upload'
    Assert-WorkflowRejected ($ciWorkflow + "`n# prohibited action: Set-TestSigning.ps1") 'must not install/remove'
    Assert-WorkflowRejected ($ciWorkflow.Replace('build.ps1 -GuiWizards -PreviewWizard', 'build.ps1 -GuiWizards')) 'harmless previews'
    Assert-WorkflowRejected ($ciWorkflow.Replace('scripts\Test-InstallerRelease.ps1', 'scripts\Test-SkippedInstallerRelease.ps1')) 'installer release'
    Assert-WorkflowRejected ($ciWorkflow.Replace('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', 'actions/checkout@main')) 'SHA-pinned'

    [IO.File]::WriteAllBytes($archivePath, [byte[]](1, 2, 3, 4))
    $digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($checksumPath, "$digest  $archiveName`n")
    & $publisher @arguments
    $cases++

    $invalid = $arguments.Clone()
    $invalid.Version = '1.2.3-01'
    $invalid.Tag = 'v1.2.3-01'
    Assert-Rejected $invalid 'must be SemVer'
    $invalid = $arguments.Clone()
    $invalid.Tag = 'v1.2.4'
    Assert-Rejected $invalid 'tag must equal'
    $invalid = $arguments.Clone()
    $invalid.Repository = 'example/repo;echo'
    Assert-Rejected $invalid 'canonical owner/repository'
    $invalid = $arguments.Clone()
    $invalid.SourceCommit = 'main'
    Assert-Rejected $invalid 'full lowercase Git commit SHA'

    $extraPath = Join-Path $testRoot 'private.log'
    [IO.File]::WriteAllText($extraPath, 'must never be published')
    Assert-Rejected $arguments 'contain exactly'
    Remove-Item -LiteralPath $extraPath

    [IO.File]::WriteAllText($checksumPath, "$digest  ../$archiveName`n")
    Assert-Rejected $arguments 'expected archive basename'
    [IO.File]::WriteAllText($checksumPath, "$digest  $archiveName`n$digest  $archiveName`n")
    Assert-Rejected $arguments 'exactly one digest'
    [IO.File]::WriteAllText($checksumPath, "$('0' * 64)  $archiveName`n")
    Assert-Rejected $arguments 'does not match its SHA-256'
    [IO.File]::WriteAllText($checksumPath, "$digest  $archiveName`n")
    [IO.File]::WriteAllBytes($archivePath, [byte[]]::new(0))
    Assert-Rejected $arguments 'size contract'

    # Exercise publication branches against an in-process mock. This verifies
    # fail-closed remote checks and draft flags without starting gh or network IO.
    [IO.File]::WriteAllBytes($archivePath, [byte[]](1, 2, 3, 4))
    if (Get-Command gh.exe -CommandType Function -ErrorAction SilentlyContinue) {
        throw 'Refusing to replace an existing gh.exe function while testing.'
    }
    $global:WinAirPlayReleaseGhMock = @{
        Commit = ('1' * 40)
        Releases = '[]'
        ApiExit = 0
        ListExit = 0
        CreateExit = 0
        Commands = [Collections.Generic.List[object]]::new()
    }
    function global:gh.exe {
        $commandArguments = @($args)
        $state = $global:WinAirPlayReleaseGhMock
        $state.Commands.Add($commandArguments)
        if ($commandArguments[0] -ceq 'api') {
            $global:LASTEXITCODE = $state.ApiExit
            return $state.Commit
        }
        if ($commandArguments[0] -ceq 'release' -and
            $commandArguments[1] -ceq 'list') {
            $global:LASTEXITCODE = $state.ListExit
            return $state.Releases
        }
        if ($commandArguments[0] -ceq 'release' -and
            $commandArguments[1] -ceq 'create') {
            $global:LASTEXITCODE = $state.CreateExit
            return
        }
        throw 'Unexpected GitHub mock command.'
    }
    $installedGhMock = $true
    $publishArguments = $arguments.Clone()
    $publishArguments.Remove('WhatIf')
    $publishArguments.Confirm = $false
    & $publisher @publishArguments
    $createCalls = @($global:WinAirPlayReleaseGhMock.Commands | Where-Object {
            $_[0] -ceq 'release' -and $_[1] -ceq 'create'
        })
    if ($createCalls.Count -ne 1) { throw 'Expected one mocked draft creation.' }
    foreach ($requiredFlag in @('--draft', '--prerelease', '--latest=false', '--verify-tag')) {
        if ($requiredFlag -cnotin $createCalls[0]) {
            throw "Draft creation omitted $requiredFlag."
        }
    }
    $cases++

    $global:WinAirPlayReleaseGhMock.Commands.Clear()
    $global:WinAirPlayReleaseGhMock.Commit = ('2' * 40)
    Assert-Rejected $publishArguments 'no longer points to the source commit'
    $global:WinAirPlayReleaseGhMock.Commit = ('1' * 40)
    $global:WinAirPlayReleaseGhMock.ApiExit = 1
    Assert-Rejected $publishArguments 'no longer points to the source commit'
    $global:WinAirPlayReleaseGhMock.ApiExit = 0
    $global:WinAirPlayReleaseGhMock.Releases = '[{"tagName":"v1.2.3-rc.1"}]'
    Assert-Rejected $publishArguments 'never overwrites an existing release'
    $global:WinAirPlayReleaseGhMock.Releases = '[]'
    $global:WinAirPlayReleaseGhMock.ListExit = 1
    Assert-Rejected $publishArguments 'Unable to query existing releases'
    if (@($global:WinAirPlayReleaseGhMock.Commands | Where-Object {
                $_[0] -ceq 'release' -and $_[1] -ceq 'create'
            }).Count -ne 0) {
        throw 'A failed remote prerequisite still attempted draft creation.'
    }
    $global:WinAirPlayReleaseGhMock.ListExit = 0
    $global:WinAirPlayReleaseGhMock.CreateExit = 1
    Assert-Rejected $publishArguments 'partial draft before retrying'
    Write-Host "Workflow/publication validation passed $cases cases; no external GitHub command or network call ran."
}
finally {
    if ($hadExitVariable) { $global:LASTEXITCODE = $previousExitCode }
    else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    if ($installedGhMock) {
        Remove-Item -LiteralPath Function:gh.exe -ErrorAction Stop
        Remove-Variable -Name WinAirPlayReleaseGhMock -Scope Global -ErrorAction Stop
        if (Get-Command gh.exe -CommandType Function -ErrorAction SilentlyContinue) {
            throw 'Publication fixture failed to remove its GitHub CLI mock.'
        }
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($resolvedTestRoot),
            $temporaryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)) -or
        [IO.Path]::GetFileName($resolvedTestRoot) -cnotmatch '^winairplay-release-tests-[0-9a-f]{32}$') {
        throw 'Refusing test cleanup outside the exact temporary test directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction Stop
}
