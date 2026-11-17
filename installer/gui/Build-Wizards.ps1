[CmdletBinding()]
param(
    [string]$BundleDirectory,
    [string]$ExpectedSignedManifestSha256,
    [string]$ExpectedSignerThumbprint,
    [string]$OutputDirectory,
    [string]$CompilerPath,
    [switch]$PreviewOnly,
    [ValidateSet(0, 1, 3010)][int]$PreviewOutcome = 0,
    [switch]$NoBootstrap,
    [switch]$PrepareCompilerOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'installer/Setup.Common.ps1')
. (Join-Path $repo 'installer/Setup-Dependencies.ps1')
. (Join-Path $repo 'installer/Common.ps1')

# Official immutable release asset, also published by GitHub's release digest.
# https://github.com/jrsoftware/issrc/releases/tag/is-7_1_1
$compilerVersion = '7.1.1'
$compilerInstallerHash = '8A5A6711C3766A6E5FB74F280BA0E3551E719CE94538D901FDBD1F8F9920B3F0'
$compilerUri = 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe'

function Assert-InnoPublisher {
    param([Parameter(Mandatory)][string]$Path)
    Assert-WinAirPlaySetupNoLinks $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "Inno compiler component must be a regular file: $Path" }
    $signature = Get-AuthenticodeSignature -LiteralPath $item.FullName -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne 'Pyrsys B.V.') {
        throw "Inno compiler component must carry a valid Pyrsys B.V. signature: $Path"
    }
}

function Assert-WizardBinaryPrivacy {
    param([Parameter(Mandatory)][string]$Path)
    $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($Path))
    foreach ($root in @($repo, $env:USERPROFILE, $env:CARGO_HOME, $env:RUSTUP_HOME) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Length -gt 3 } | Sort-Object -Unique) {
        foreach ($form in @($root.Replace('/', '\'), $root.Replace('\', '/')) | Select-Object -Unique) {
            foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
                $needle = [Text.Encoding]::Latin1.GetString($encoding.GetBytes($form))
                if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    throw 'Compiled wizard contains an original builder/profile path.'
                }
            }
        }
    }
}

function Resolve-InnoCompiler {
    if ($CompilerPath) {
        $candidate = (Resolve-Path -LiteralPath $CompilerPath -ErrorAction Stop).Path
        if ([IO.Path]::GetFileName($candidate) -ine 'ISCC.exe') {
            throw '-CompilerPath must name the verified Inno Setup ISCC.exe compiler.'
        }
    } else {
        $tools = Join-Path $repo ".tools/InnoSetup/$compilerVersion-x64"
        $candidate = Join-Path $tools 'portable/ISCC.exe'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            if ($NoBootstrap) {
                throw 'Pinned Inno Setup compiler is absent. Rerun without -NoBootstrap for local portable acquisition, or provide -CompilerPath to Inno Setup 7.1.1 ISCC.exe.'
            }
            Assert-WinAirPlaySetupNoLinks $tools
            $null = [IO.Directory]::CreateDirectory($tools)
            $download = Join-Path $tools "innosetup-$compilerVersion-x64.exe"
            if (-not (Test-Path -LiteralPath $download)) {
                Save-WinAirPlaySetupHttpsFile -Uri $compilerUri -Destination $download
            }
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -cne $compilerInstallerHash) {
                throw 'Downloaded/cached Inno Setup installer does not match the pinned official SHA-256. Preserve the file for investigation and supply a verified compiler.'
            }
            Assert-InnoPublisher $download
            $portable = Split-Path $candidate -Parent
            if (Test-Path -LiteralPath $portable) {
                throw 'An incomplete Inno portable directory already exists. Preserve/inspect it before retrying; build does not erase tool evidence.'
            }
            # Official /PORTABLE=1 disables registration, associations, icons,
            # and Inno's own uninstaller. Only the ignored local tool tree is used.
            $arguments = @('/PORTABLE=1', '/CURRENTUSER', '/VERYSILENT',
                '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', ('/DIR="' + $portable + '"'))
            $process = Start-Process -FilePath $download -ArgumentList $arguments `
                -WindowStyle Hidden -PassThru -ErrorAction Stop
            try {
                if (-not $process.WaitForExit(300000)) {
                    $process.Kill()
                    throw 'Inno portable acquisition exceeded five minutes; inspect the local tool directory before retrying.'
                }
                if ($process.ExitCode -ne 0) { throw "Inno portable acquisition failed with exit code $($process.ExitCode)." }
            } finally { $process.Dispose() }
        }
    }
    # Verify the executable and compiler engines before executing any of them.
    foreach ($file in @('ISCC.exe', 'ISCmplr.dll', 'ISPP.dll')) {
        Assert-InnoPublisher (Join-Path (Split-Path $candidate -Parent) $file)
    }
    $engineVersion = @(& $candidate '--version')
    if ($LASTEXITCODE -ne 0 -or $engineVersion.Count -ne 1 -or
        $engineVersion[0].Trim() -cne $compilerVersion) {
        throw "Inno Setup $compilerVersion is required; the supplied compiler engine reports '$($engineVersion -join ' ')'."
    }
    return $candidate
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    -not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Core' -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64 -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'Wizard builds require native x64 Windows and PowerShell 7.'
}
if ($PrepareCompilerOnly) {
    if ($BundleDirectory -or $OutputDirectory -or $PreviewOnly) {
        throw '-PrepareCompilerOnly cannot be combined with bundle/output/preview build options.'
    }
    return Resolve-InnoCompiler
}
$version = Get-Content -LiteralPath (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json
$productVersion = [string]$version.version
if ($productVersion -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?$') {
    throw 'Canonical product version is invalid.'
}
$fileVersion = ($productVersion -split '[-+]', 2)[0] + '.' + [string]$version.driver_revision
$payloadLocks = [Collections.Generic.List[IDisposable]]::new()
try {
if (-not $PreviewOnly) {
    if (-not $BundleDirectory) { throw 'A real wizard build requires -BundleDirectory pointing to an authenticated test-signed release.' }
    $BundleDirectory = (Resolve-Path -LiteralPath $BundleDirectory -ErrorAction Stop).Path
    $manifest = Assert-WinAirPlaySetupInputs $BundleDirectory $ExpectedSignedManifestSha256 $ExpectedSignerThumbprint
    $null = Resolve-WinAirPlayPackage -PackageDirectory (Join-Path $BundleDirectory 'package')
    # Compiler reads the original signed bytes. Hold read-only handles that
    # deny write/delete, then revalidate under those handles before compiling.
    foreach ($name in @(Get-WinAirPlayPackageFileNames)) {
        $path = Join-Path $BundleDirectory "package/$name"
        Assert-WinAirPlaySetupNoLinks $path
        $payloadLocks.Add([IO.File]::Open($path, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read))
    }
    $payloadLocks.Add([IO.File]::Open((Join-Path $BundleDirectory 'test-signing.cer'),
        [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $null = Assert-WinAirPlaySetupInputs $BundleDirectory $ExpectedSignedManifestSha256 $ExpectedSignerThumbprint
    $packagedVersion = Get-Content -LiteralPath (Join-Path $BundleDirectory 'package/version.json') -Raw | ConvertFrom-Json
    if ([string]$packagedVersion.version -cne $productVersion) {
        throw 'Wizard source and signed payload product versions differ.'
    }
    if ([string]$manifest.Configuration -cne 'Release') { throw 'GUI delivery requires a Release payload.' }
    $ExpectedSignedManifestSha256 = $ExpectedSignedManifestSha256.ToUpperInvariant()
    $ExpectedSignerThumbprint = $ExpectedSignerThumbprint.ToUpperInvariant()
} else {
    # Preview templates exclude real payloads and backend execution at compile
    # time. Placeholder identities are not accepted by the real build branch.
    $BundleDirectory = $repo
    $ExpectedSignedManifestSha256 = '0' * 64
    $ExpectedSignerThumbprint = '0' * 40
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repo ('.local/diagnostics/gui-wizards/build-' + [Guid]::NewGuid().ToString('N'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
Assert-WinAirPlaySetupNoLinks $OutputDirectory
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$lockPath = Join-Path $OutputDirectory '.wizard-build.lock'
Assert-WinAirPlaySetupNoLinks $lockPath
try {
    $outputLock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
} catch {
    throw 'Wizard output directory is already reserved by another build, or contains a stale lock. Choose a fresh output directory; no existing output was changed.'
}
try {
$suffix = if ($PreviewOnly) { '-Preview' } else { '' }
$names = @("WinAirPlayAudio-$productVersion-Setup$suffix", "WinAirPlayAudio-$productVersion-Uninstall$suffix")
foreach ($name in $names) {
    if (Test-Path -LiteralPath (Join-Path $OutputDirectory "$name.exe")) {
        throw "Wizard output already exists; choose a new output directory: $name.exe"
    }
}
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'wizard-build.json')) {
    throw 'Wizard build inventory already exists; choose a fresh output directory.'
}
$compiler = Resolve-InnoCompiler
$defines = @(
    "/DSourceRoot=$repo", "/DBundleRoot=$BundleDirectory", "/DOutputDir=$OutputDirectory",
    "/DProductVersion=$productVersion", "/DProductFileVersion=$fileVersion",
    "/DExpectedManifest=$ExpectedSignedManifestSha256", "/DExpectedSigner=$ExpectedSignerThumbprint",
    "/DPreviewOnly=$([int][bool]$PreviewOnly)", "/DPreviewOutcome=$PreviewOutcome"
)
$outputs = [Collections.Generic.List[object]]::new()
try {
    for ($index = 0; $index -lt 2; $index++) {
        $scriptName = @('Installer.iss', 'Uninstaller.iss')[$index]
        $scriptPath = Join-Path $PSScriptRoot $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Wizard definition is missing: $scriptPath" }
        Assert-WinAirPlaySetupNoLinks $scriptPath
        $arguments = @('/Q', "/O$OutputDirectory", "/F$($names[$index])", '/NI') + $defines + $scriptPath
        & $compiler @arguments
        if ($LASTEXITCODE -ne 0) { throw "Inno compilation failed for $scriptName (exit $LASTEXITCODE)." }
        $path = Join-Path $OutputDirectory ($names[$index] + '.exe')
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($file.Length -le 0) { throw 'Compiler produced an empty wizard.' }
        Assert-WizardBinaryPrivacy $path
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        $outputs.Add([pscustomobject]@{
            Name = $file.Name; Path = $file.FullName; Bytes = $file.Length
            Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            SignatureStatus = $signature.Status.ToString()
        })
    }
} catch {
    # Remove only this invocation's new output names. Compiler/dependency logs
    # and unrelated evidence are retained; no recursive deletion is performed.
    foreach ($name in $names) {
        $path = Join-Path $OutputDirectory ($name + '.exe')
        if (Test-Path -LiteralPath $path) {
            Assert-WinAirPlaySetupNoLinks $path
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
    throw
}
[pscustomobject]@{
    SchemaVersion = 1; Version = $productVersion; CompilerVersion = $compilerVersion
    PreviewOnly = [bool]$PreviewOnly; PreviewOutcome = $(if ($PreviewOnly) { $PreviewOutcome } else { $null })
    PayloadManifestSha256 = $(if ($PreviewOnly) { $null } else { $ExpectedSignedManifestSha256 })
    SignerThumbprint = $(if ($PreviewOnly) { $null } else { $ExpectedSignerThumbprint })
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    # Keep the manifest portable; full local paths are returned to the caller
    # below for navigation, never written into a potentially delivered inventory.
    Files = @($outputs | Select-Object Name, Bytes, Sha256, SignatureStatus)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'wizard-build.json') -Encoding utf8
$outputs | ForEach-Object { $_ }
} finally { $outputLock.Dispose() }
} finally {
    foreach ($handle in $payloadLocks) { $handle.Dispose() }
}
