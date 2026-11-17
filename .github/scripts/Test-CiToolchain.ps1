[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is a read-only preflight, not an installer. Hosted image references:
# https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-VS2026-Readme.md
# https://learn.microsoft.com/windows-hardware/drivers/install-the-wdk-using-nuget
# build.ps1 -Bootstrap restores this repository's exact SDK/WDK/Rust pins.
if (-not $IsWindows -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'CI builds require native x64 Windows and 64-bit PowerShell 7.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Install PowerShell 7 and run CI from pwsh.exe.'
}
foreach ($command in @('rustup.exe', 'cargo.exe', 'cmake.exe', 'git.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "CI prerequisite is missing: $command. Use the windows-2025-vs2026 hosted image or provision the documented development environment."
    }
}
$cmakeOutput = @(& cmake.exe --version)
if ($LASTEXITCODE -ne 0 -or
    $cmakeOutput.Count -eq 0 -or
    $cmakeOutput[0] -notmatch '^cmake version ([0-9]+)\.') {
    throw 'CMake did not return a recognizable version.'
}
if ([int]$Matches[1] -lt 4) {
    throw 'CMake 4 or newer is required; use the windows-2025-vs2026 hosted image.'
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'vswhere.exe is missing. Install Visual Studio 2026 Desktop C++ and Component.Microsoft.Windows.DriverKit.'
}
$visualStudioJson = & $vswhere -latest -products * -version '[18.0,19.0)' -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Component.Microsoft.Windows.DriverKit -format json
if ($LASTEXITCODE -ne 0) {
    throw 'Visual Studio Installer inventory query failed.'
}
$installations = @($visualStudioJson | ConvertFrom-Json)
if ($installations.Count -ne 1) {
    throw 'Visual Studio 2026 with Desktop C++ and Component.Microsoft.Windows.DriverKit is required. Select windows-2025-vs2026; do not substitute an older WDK.'
}
$visualStudio = $installations[0]
$authoritativeSelections = @(
    @(& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath),
    @(& $vswhere -latest -products * -requires Component.Microsoft.Windows.DriverKit -property installationPath)
)
foreach ($selection in $authoritativeSelections) {
    if (@($selection).Count -ne 1 -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [string]$selection[0],
            [string]$visualStudio.installationPath)) {
        throw 'The default MSBuild/DriverKit selection differs from Visual Studio 2026. Use a hosted image whose latest MSBuild and DriverKit instance are both VS 2026.'
    }
}
$msbuild = Join-Path $visualStudio.installationPath 'MSBuild\Current\Bin\amd64\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) {
    throw 'The required native x64 MSBuild host is absent from Visual Studio 2026.'
}
$platformRoots = Join-Path $visualStudio.installationPath 'MSBuild\Microsoft\VC'
$toolsets = @(Get-ChildItem -LiteralPath $platformRoots -Directory -ErrorAction Stop |
        ForEach-Object {
            Join-Path $_.FullName 'Platforms\x64\PlatformToolsets\WindowsKernelModeDriver10.0'
        } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
if ($toolsets.Count -eq 0) {
    throw 'WindowsKernelModeDriver10.0 is missing. Add Component.Microsoft.Windows.DriverKit in Visual Studio Installer; NuGet restore alone does not install this integration.'
}

$imageOs = [Environment]::GetEnvironmentVariable('ImageOS')
$imageVersion = [Environment]::GetEnvironmentVariable('ImageVersion')
Write-Host "Build-only runner image: $imageOs / $imageVersion"
Write-Host "Visual Studio: $($visualStudio.installationVersion); native x64 MSBuild and WDK toolset found."
Write-Host $cmakeOutput[0]
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host 'The hosted Windows Server build does not establish driver/runtime support on Windows Server or replace Windows 11 hardware validation.'
