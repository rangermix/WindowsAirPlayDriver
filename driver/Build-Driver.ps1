[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [string]$NuGetExe,

    [switch]$SkipPackageRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$solution = Join-Path $PSScriptRoot 'WinAirPlayAudio.sln'
$packages = Join-Path $PSScriptRoot 'packages'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Visual Studio Installer vswhere.exe was not found. Install Visual Studio 2026 with Desktop development with C++ and the Windows Driver Kit component first.'
}

$driverKitVisualStudio = (& $vswhere -latest -products * -requires Component.Microsoft.Windows.DriverKit -property installationPath |
    Select-Object -First 1)
if (-not $driverKitVisualStudio) {
    throw @'
No Visual Studio installation with the Windows Driver Kit component was found.
Install Visual Studio 2026 with Desktop development with C++ and "Windows Driver Kit"
(component ID Component.Microsoft.Windows.DriverKit). Restoring the
Microsoft.Windows.WDK.x64 NuGet package supplies headers/libraries only; it
does not install the WindowsKernelModeDriver10.0 MSBuild platform toolset.
'@
}

$msbuild = Join-Path $driverKitVisualStudio 'MSBuild\Current\Bin\amd64\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) {
    throw "MSBuild was not found at the expected path: $msbuild"
}

if (-not $SkipPackageRestore) {
    if (-not $NuGetExe) {
        $NuGetExe = Join-Path (Split-Path $PSScriptRoot -Parent) '.tools\nuget\7.6.0\nuget.exe'
        if (-not (Test-Path -LiteralPath $NuGetExe -PathType Leaf)) {
            $NuGetExe = $null
        }
    }
    if (-not $NuGetExe) {
        $nugetCommand = Get-Command nuget.exe -ErrorAction SilentlyContinue
        if ($nugetCommand) {
            $NuGetExe = $nugetCommand.Source
        }
    }
    if (-not $NuGetExe -or -not (Test-Path -LiteralPath $NuGetExe -PathType Leaf)) {
        throw 'Pinned WDK packages are absent. Run .\build.ps1 -Bootstrap first, or pass -NuGetExe <path-to-nuget.exe>.'
    }

    & $NuGetExe restore (Join-Path $PSScriptRoot 'packages.config') -PackagesDirectory $packages -NonInteractive
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet restore failed with exit code $LASTEXITCODE."
    }
}

$logDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) '.local\diagnostics\build\driver'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logStamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$logSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$logFile = Join-Path $logDirectory ("driver-{0}-x64-{1}-{2}.log" -f $Configuration.ToLowerInvariant(), $logStamp, $logSuffix)

# Rebuild makes the WDK package directory an exact output rather than retaining
# stale files from a prior package/signing run. The native 64-bit MSBuild host
# is required because the pinned x64 WDK tasks load x64 validation helpers.
# FileTracker is unnecessary for a full rebuild and can fail before CL starts
# in restricted Windows process environments. Disable both tracking and the
# multi-tool wrapper so the authoritative command depends only on the explicit
# Rebuild inputs.
#
# A Windows process can contain both PATH and Path entries. MSBuild's CL task
# rejects that inherited environment as a duplicate-key argument. Construct the
# child environment explicitly so it contains exactly one canonical Path entry;
# do not mutate the caller's process environment.
$pathValue = $env:Path
if ([string]::IsNullOrWhiteSpace($pathValue)) {
    throw 'The process Path environment variable is missing or empty.'
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $msbuild
$startInfo.UseShellExecute = $false
$startInfo.WorkingDirectory = $PSScriptRoot
$startInfo.Environment.Clear()
foreach ($entry in [System.Environment]::GetEnvironmentVariables(
        [System.EnvironmentVariableTarget]::Process).GetEnumerator()) {
    if ([string]$entry.Key -ieq 'Path') {
        continue
    }
    $startInfo.Environment[[string]$entry.Key] = [string]$entry.Value
}
$startInfo.Environment['Path'] = $pathValue

foreach ($argument in @(
        $solution,
        '/m',
        '/nodeReuse:false',
        '/t:Rebuild',
        "/p:Configuration=$Configuration",
        '/p:Platform=x64',
        '/p:TrackFileAccess=false',
        '/p:UseMultiToolTask=false',
        '/warnaserror',
        "/flp:logfile=$logFile;verbosity=normal")) {
    [void]$startInfo.ArgumentList.Add($argument)
}

$process = [System.Diagnostics.Process]::Start($startInfo)
if ($null -eq $process) {
    throw "MSBuild could not be started: $msbuild"
}
try {
    $process.WaitForExit()
    $msbuildExitCode = $process.ExitCode
}
finally {
    $process.Dispose()
}

if ($msbuildExitCode -ne 0) {
    throw "Driver build failed with exit code $msbuildExitCode. See $logFile"
}

Write-Host "Driver package build completed: $(Join-Path $PSScriptRoot "out\package\$Configuration\x64")"
