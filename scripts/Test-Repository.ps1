[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testsRoot = [IO.Path]::GetFullPath((Join-Path $root '.local\diagnostics\tests'))
$fixture = Join-Path $testsRoot ('repository-' + [Guid]::NewGuid().ToString('N'))
$assertions = 0
function Assert-Condition {
    param([bool]$Condition, [string]$Description)
    $script:assertions++
    if (-not $Condition) { throw $Description }
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Description)
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-Condition $rejected $Description
}
$originalEncoded = [Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process')
$originalRustflags = [Environment]::GetEnvironmentVariable('RUSTFLAGS', 'Process')
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    & git -C $fixture init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize isolated hygiene fixture.' }
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '/.local/'
    Set-Content -LiteralPath (Join-Path $fixture 'README.md') -Value 'Public fixture'
    & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture
    $privateFile = Join-Path $fixture 'private.pfx'
    Set-Content -LiteralPath $privateFile -Value 'Synthetic non-certificate fixture'
    Assert-Rejected { & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture } 'Unignored sensitive payload must be rejected.'
    Remove-Item -LiteralPath $privateFile
    foreach ($privateCase in @(
        @{Path='capture.wav';Description='Raw audio capture'},
        @{Path='signer.p12';Description='Portable private-certificate container'},
        @{Path='release.zip';Description='Generated release archive'},
        @{Path='.env.local';Description='Environment secrets file'},
        @{Path='.vscode/settings.json';Description='Per-user editor configuration'},
        @{Path='driver/packages/cache.json';Description='Downloaded driver dependency cache'},
        @{Path='installer/staging/payload.json';Description='Generated installer staging'}
    )) {
        $privatePath = Join-Path $fixture $privateCase.Path
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($privatePath))
        [IO.File]::WriteAllText($privatePath, 'Synthetic hygiene fixture; no private data.')
        Assert-Rejected { & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture } `
            "$($privateCase.Description) must remain outside the intended source set."
        Remove-Item -LiteralPath $privatePath
    }
    # Ignored local evidence is permitted, but force-adding it must still fail.
    $ignoredFixture = Join-Path $fixture '.local/secrets/signer.p12'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ignoredFixture))
    [IO.File]::WriteAllText($ignoredFixture, 'Synthetic non-certificate fixture.')
    & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture
    & git -C $fixture add --force -- '.local/secrets/signer.p12'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage ignored local-record fixture.' }
    Assert-Rejected { & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture } `
        'Force-added local records must still be rejected.'
    & git -C $fixture rm --cached --quiet -- '.local/secrets/signer.p12'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot unstage local-record fixture.' }
    Remove-Item -LiteralPath $ignoredFixture
    New-Item -ItemType Directory -Path (Join-Path $fixture '.diagnostics') | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture '.diagnostics\capture.json') -Value '{}'
    Assert-Rejected { & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture } 'A separate diagnostics root must be rejected.'
    Remove-Item -LiteralPath (Join-Path $fixture '.diagnostics\capture.json')
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '# Missing private root protection'
    Assert-Rejected { & (Join-Path $PSScriptRoot 'Test-SourceHygiene.ps1') -RepositoryRoot $fixture } 'A missing .local ignore rule must be rejected.'

    $probeFlags = '--cfg=airplay_environment_probe' + [char]31 + '-Copt-level=0'
    [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', $probeFlags, 'Process')
    [Environment]::SetEnvironmentVariable('RUSTFLAGS', '--cfg untouched_probe', 'Process')
    $null = & (Join-Path $PSScriptRoot 'Invoke-Cargo.ps1') -CargoArguments @('+1.97.1', '--version')
    Assert-Condition ([Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process') -ceq $probeFlags) 'Successful Cargo call must restore existing encoded flags.'
    Assert-Rejected {
        & (Join-Path $PSScriptRoot 'Invoke-Cargo.ps1') -CargoArguments @('+1.97.1', 'winairplay-nonexistent-test-command') 2> (Join-Path $fixture 'expected-cargo-error.log')
    } 'Cargo nonzero exit must be propagated.'
    Assert-Condition ([Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process') -ceq $probeFlags) 'Failed Cargo call must restore existing encoded flags.'
    Assert-Condition ($env:RUSTFLAGS -ceq '--cfg untouched_probe') 'Cargo wrapper must preserve RUSTFLAGS.'
    Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue
    $null = & (Join-Path $PSScriptRoot 'Invoke-Cargo.ps1') -CargoArguments @('+1.97.1', '--version')
    Assert-Condition ($null -eq [Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process')) 'Cargo wrapper must restore an absent encoded flag variable.'
}
finally {
    if ($null -eq $originalEncoded) { Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', $originalEncoded, 'Process') }
    if ($null -eq $originalRustflags) { Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable('RUSTFLAGS', $originalRustflags, 'Process') }
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($testsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing fixture cleanup outside the local diagnostic test root.'
    }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
Assert-Condition (-not (Test-Path -LiteralPath $fixture)) 'Repository fixture cleanup must complete.'
Write-Host "Repository hygiene/environment checks passed ($assertions assertions)."
