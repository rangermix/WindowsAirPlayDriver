[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',

    [switch] $Bootstrap,
    [switch] $UserModeOnly,
    [switch] $Driver,
    [switch] $Test,
    [switch] $IntegrationTest,
    [switch] $Package,
    [switch] $Clean,
    [switch] $GuiWizards,
    [switch] $PreviewWizard,
    [ValidateSet(0, 1, 3010)][int] $WizardPreviewOutcome = 0,
    [string] $SignedBundleDirectory,
    [string] $ExpectedSignedManifestSha256,
    [string] $ExpectedSignerThumbprint,
    [string] $WizardOutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = $PSScriptRoot
$RustToolchain = '1.97.1'
$NuGetVersion = '7.6.0'
$NuGetSha256 = '751EE5E79481626A428C1241DC7F94BCA2739B32588E669715BC5FB54D8FB8A2'
$DriverProject = Join-Path $RepoRoot 'driver\WinAirPlayAudio.vcxproj'
$DriverBuildScript = Join-Path $RepoRoot 'driver\Build-Driver.ps1'
$InstallerPackageScript = Join-Path $RepoRoot 'installer\package.ps1'

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter()]
        [string[]] $ArgumentList = @()
    )

    Write-Host ('> {0} {1}' -f $FilePath, ($ArgumentList -join ' '))
    if ([IO.Path]::GetFileName($FilePath) -ieq 'cargo.exe') {
        & (Join-Path $RepoRoot 'scripts\Invoke-Cargo.ps1') -CargoArguments $ArgumentList
    }
    else {
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
        }
    }
}

function Find-CommandPath {
    param([Parameter(Mandatory)][string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $candidate = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\amd64\MSBuild.exe' |
            Select-Object -First 1
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return Find-CommandPath -Name 'msbuild.exe'
}

function Assert-Rust {
    $rustup = Find-CommandPath -Name 'rustup.exe'
    $cargo = Find-CommandPath -Name 'cargo.exe'
    if (-not $rustup -or -not $cargo) {
        throw @"
Rustup and Cargo are required.
Install rustup from https://rustup.rs/ and then run:
  rustup toolchain install $RustToolchain --profile minimal --component clippy --component rustfmt
"@
    }
}

function Test-WdkToolset {
    param([Parameter(Mandatory)][string] $MSBuildPath)

    $msbuildRoot = Split-Path (Split-Path (Split-Path (Split-Path $MSBuildPath -Parent) -Parent) -Parent) -Parent
    $vcRoot = Join-Path $msbuildRoot 'Microsoft\VC'
    if (-not (Test-Path -LiteralPath $vcRoot)) {
        return $false
    }

    $driverPlatforms = Get-ChildItem -LiteralPath $vcRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            Join-Path $_.FullName 'Platforms\x64\PlatformToolsets\WindowsKernelModeDriver10.0'
        } |
        Where-Object { Test-Path -LiteralPath $_ }
    return @($driverPlatforms).Count -gt 0
}

function Assert-DriverToolchain {
    $msbuild = Find-MSBuild
    if (-not $msbuild) {
        throw 'MSBuild was not found. Install the Visual Studio Desktop development with C++ workload.'
    }
    if (-not (Test-WdkToolset -MSBuildPath $msbuild)) {
        throw @"
The Visual Studio WindowsKernelModeDriver10.0 platform toolset is missing.
For Visual Studio 2026, install a matching Windows SDK and WDK from:
  https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk
The pinned sample packages use SDK/WDK 10.0.28000.1839. The SDK and WDK build
families must match. Re-open Visual Studio Installer and ensure Desktop
development with C++ and the Windows Driver Kit integration are selected.
NuGet WDK packages alone do not install this MSBuild platform toolset.
"@
    }
    return $msbuild
}

function Get-PinnedNuGet {
    $toolDirectory = Join-Path $RepoRoot ".tools\nuget\$NuGetVersion"
    $nuget = Join-Path $toolDirectory 'nuget.exe'
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null

    if (-not (Test-Path -LiteralPath $nuget -PathType Leaf)) {
        $download = Join-Path $toolDirectory ("nuget-{0}.download" -f [Guid]::NewGuid().ToString('N'))
        try {
            Invoke-WebRequest `
                -Uri "https://dist.nuget.org/win-x86-commandline/v$NuGetVersion/nuget.exe" `
                -OutFile $download `
                -UseBasicParsing
            $actual = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
            if ($actual -ne $NuGetSha256) {
                throw "NuGet $NuGetVersion hash mismatch. Expected $NuGetSha256; observed $actual."
            }
            Move-Item -LiteralPath $download -Destination $nuget
        }
        finally {
            if (Test-Path -LiteralPath $download) {
                Remove-Item -LiteralPath $download -Force
            }
        }
    }

    $installedHash = (Get-FileHash -LiteralPath $nuget -Algorithm SHA256).Hash
    if ($installedHash -ne $NuGetSha256) {
        throw "Cached NuGet $NuGetVersion hash mismatch. Remove $nuget and rerun -Bootstrap."
    }
    return $nuget
}

function Invoke-Bootstrap {
    Assert-Rust
    $rustup = Find-CommandPath -Name 'rustup.exe'
    Invoke-Native -FilePath $rustup -ArgumentList @(
        'toolchain', 'install', $RustToolchain,
        '--profile', 'minimal',
        '--component', 'clippy',
        '--component', 'rustfmt'
    )
    Invoke-Native -FilePath $rustup -ArgumentList @(
        'target', 'add', 'x86_64-pc-windows-msvc',
        '--toolchain', $RustToolchain
    )

    $lockFile = Join-Path $RepoRoot 'Cargo.lock'
    if (-not (Test-Path -LiteralPath $lockFile)) {
        throw 'Cargo.lock is missing. Dependency updates must be generated and reviewed before bootstrap.'
    }

    $cargo = Find-CommandPath -Name 'cargo.exe'
    Invoke-Native -FilePath $cargo -ArgumentList @(
        "+$RustToolchain", 'fetch', '--locked', '--manifest-path',
        (Join-Path $RepoRoot 'Cargo.toml')
    )

    $nuget = Get-PinnedNuGet
    Invoke-Native -FilePath $nuget -ArgumentList @(
        'restore',
        (Join-Path $RepoRoot 'driver\packages.config'),
        '-PackagesDirectory',
        (Join-Path $RepoRoot 'driver\packages'),
        '-NonInteractive'
    )

    $msbuild = Find-MSBuild
    if (-not $msbuild) {
        Write-Warning 'MSBuild is missing; user-mode Rust components can still build.'
    }
    elseif (-not (Test-WdkToolset -MSBuildPath $msbuild)) {
        Write-Warning 'WindowsKernelModeDriver10.0 is missing. Run .\build.ps1 -Driver for exact WDK guidance.'
    }
}

function Invoke-UserModeBuild {
    Assert-Rust
    $cargo = Find-CommandPath -Name 'cargo.exe'
    $arguments = @(
        "+$RustToolchain", 'build', '--workspace', '--locked', '--all-targets'
    )
    if ($Configuration -eq 'Release') {
        $arguments += '--release'
    }
    Invoke-Native -FilePath $cargo -ArgumentList $arguments
}

function Invoke-FormatAndLint {
    Assert-Rust
    $cargo = Find-CommandPath -Name 'cargo.exe'
    Invoke-Native -FilePath $cargo -ArgumentList @(
        "+$RustToolchain", 'fmt', '--all', '--', '--check'
    )
    Invoke-Native -FilePath $cargo -ArgumentList @(
        "+$RustToolchain", 'clippy', '--workspace', '--all-targets', '--locked', '--', '-D', 'warnings'
    )
}

function Invoke-UnitTests {
    Assert-Rust
    & (Join-Path $RepoRoot 'scripts\Test-SourceHygiene.ps1')
    & (Join-Path $RepoRoot 'scripts\Test-Repository.ps1')
    & (Join-Path $RepoRoot 'scripts\Test-Version.ps1')
    & (Join-Path $RepoRoot 'scripts\Test-ReleaseBundle.ps1')
    Invoke-FormatAndLint
    $cargo = Find-CommandPath -Name 'cargo.exe'
    $arguments = @(
        "+$RustToolchain", 'test', '--workspace', '--locked'
    )
    if ($Configuration -eq 'Release') { $arguments += '--release' }
    Invoke-Native -FilePath $cargo -ArgumentList $arguments
    & (Join-Path $RepoRoot 'driver\Test-DriverContract.ps1')
    & (Join-Path $RepoRoot 'installer\Test-InstallerContract.ps1')
    & (Join-Path $RepoRoot 'installer\Test-SetupDependencies.ps1')
    & (Join-Path $RepoRoot 'installer\Test-Setup.ps1')
    & (Join-Path $RepoRoot 'installer\Test-Uninstall.ps1')
    & (Join-Path $RepoRoot 'installer\gui\Test-WizardAction.ps1')
}

function Invoke-IntegrationTests {
    Assert-Rust
    $cargo = Find-CommandPath -Name 'cargo.exe'
    $arguments = @(
        "+$RustToolchain", 'test', '--locked',
        '-p', 'winairplay-tools',
        '--test', 'mock_processes'
    )
    if ($Configuration -eq 'Release') { $arguments += '--release' }
    $arguments += @(
        '--', '--nocapture', '--test-threads=1'
    )
    Invoke-Native -FilePath $cargo -ArgumentList $arguments
    $arguments = @(
        "+$RustToolchain", 'test', '--locked',
        '-p', 'winairplay-service', '--test', 'console_process'
    )
    if ($Configuration -eq 'Release') { $arguments += '--release' }
    $arguments += @('--', '--nocapture')
    Invoke-Native -FilePath $cargo -ArgumentList $arguments
}

function Invoke-DriverBuild {
    if (-not (Test-Path -LiteralPath $DriverProject)) {
        throw "Driver project is missing: $DriverProject"
    }
    $null = Assert-DriverToolchain
    $nuget = Get-PinnedNuGet
    & $DriverBuildScript -Configuration $Configuration -NuGetExe $nuget
}

function Invoke-Clean {
    $cargo = Find-CommandPath -Name 'cargo.exe'
    if ($cargo) {
        Invoke-Native -FilePath $cargo -ArgumentList @(
            "+$RustToolchain", 'clean', '--manifest-path',
            (Join-Path $RepoRoot 'Cargo.toml')
        )
    }

    if (Test-Path -LiteralPath $DriverProject) {
        $msbuild = Find-MSBuild
        if ($msbuild -and (Test-WdkToolset -MSBuildPath $msbuild)) {
            Invoke-Native -FilePath $msbuild -ArgumentList @(
                $DriverProject,
                '/t:Clean',
                "/p:Configuration=$Configuration",
                '/p:Platform=x64'
            )
        }
        else {
            Write-Warning 'Driver clean skipped because the WDK MSBuild toolset is unavailable.'
        }
    }
}

function Invoke-Package {
    if (-not (Test-Path -LiteralPath $InstallerPackageScript)) {
        throw "Packaging script is missing: $InstallerPackageScript"
    }
    & $InstallerPackageScript -Configuration $Configuration
}

Push-Location $RepoRoot
try {
    if ($GuiWizards) {
        if ($Clean -or $Bootstrap -or $Package -or $Test -or $IntegrationTest -or $Driver -or $UserModeOnly) {
            throw 'Run -GuiWizards separately from other build actions.'
        }
        $wizardArguments = @{
            PreviewOnly = [bool]$PreviewWizard
            PreviewOutcome = $WizardPreviewOutcome
        }
        if ($SignedBundleDirectory) { $wizardArguments.BundleDirectory = $SignedBundleDirectory }
        if ($ExpectedSignedManifestSha256) { $wizardArguments.ExpectedSignedManifestSha256 = $ExpectedSignedManifestSha256 }
        if ($ExpectedSignerThumbprint) { $wizardArguments.ExpectedSignerThumbprint = $ExpectedSignerThumbprint }
        if ($WizardOutputDirectory) { $wizardArguments.OutputDirectory = $WizardOutputDirectory }
        & (Join-Path $RepoRoot 'installer\gui\Build-Wizards.ps1') @wizardArguments
        return
    }
    if ($PreviewWizard) { throw '-PreviewWizard requires -GuiWizards.' }
    if ($Clean) {
        Invoke-Clean
        return
    }

    & (Join-Path $RepoRoot 'scripts\Version.ps1') -Check | Out-Null

    if ($Bootstrap) {
        Invoke-Bootstrap
    }

    $explicitAction = $UserModeOnly -or $Driver -or $Test -or $IntegrationTest -or $Package
    if ($Bootstrap -and -not $explicitAction) {
        return
    }

    if ($Package) {
        Invoke-Package
        return
    }

    if ($Test) {
        Invoke-UnitTests
    }
    if ($IntegrationTest -and -not $Test) {
        Invoke-IntegrationTests
    }
    if ($UserModeOnly) {
        Invoke-UserModeBuild
    }
    if ($Driver) {
        Invoke-DriverBuild
    }

    if (-not $explicitAction) {
        Invoke-UserModeBuild
        Invoke-DriverBuild
    }
}
finally {
    Pop-Location
}
