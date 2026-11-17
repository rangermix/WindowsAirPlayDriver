[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateScript({
            $normalized = $_.Replace(' ', '')
            if ($normalized -match '^[0-9A-Fa-f]{40}$') {
                return $true
            }
            throw 'Certificate thumbprint must contain exactly 40 hexadecimal characters.'
        })]
    [string]$CertificateThumbprint,

    [switch]$Pause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path $PSScriptRoot -Parent
$buildScript = Join-Path $repoRoot 'build.ps1'
$signScript = Join-Path $PSScriptRoot 'Sign-TestPackage.ps1'
$installScript = Join-Path $PSScriptRoot 'Install-Driver.ps1'
$packageDirectory =
    Join-Path $repoRoot "driver\out\package\$Configuration\x64"
$manifestPath = Join-Path $packageDirectory 'package-manifest.json'
$confirmWasSpecified = $PSBoundParameters.ContainsKey('Confirm')
$confirmValue = if ($confirmWasSpecified) {
    [bool]$PSBoundParameters['Confirm']
}
else {
    $false
}

. (Join-Path $PSScriptRoot 'Common.ps1')

function ConvertTo-QuotedProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ElevatedPipeline {
    $pwsh = Get-Command pwsh.exe -ErrorAction Stop
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (ConvertTo-QuotedProcessArgument -Value $PSCommandPath),
        '-Configuration',
        $Configuration
    )
    if ($CertificateThumbprint) {
        $arguments += @('-CertificateThumbprint', $CertificateThumbprint)
    }
    if ($Pause) {
        $arguments += '-Pause'
    }
    if ($confirmWasSpecified) {
        $arguments += if ($confirmValue) {
            '-Confirm:$true'
        }
        else {
            '-Confirm:$false'
        }
    }

    Write-Host 'Requesting administrator access for existing signing and installation scripts...'
    $process = Start-Process `
        -FilePath $pwsh.Source `
        -ArgumentList $arguments `
        -WorkingDirectory $repoRoot `
        -Verb RunAs `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The elevated pipeline failed with exit code $($process.ExitCode)."
    }
}

function Assert-CurrentBootUsesTestSigning {
    $systemStartOptions = Get-ItemPropertyValue `
        -LiteralPath `
        'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control' `
        -Name 'SystemStartOptions' `
        -ErrorAction Stop
    $bootOptions = @($systemStartOptions -split '\s+' |
            Where-Object { $_ })
    if ('TESTSIGNING' -notin $bootOptions) {
        throw @'
Windows TESTSIGNING is not active in the current boot session.
Use the existing installer\Set-TestSigning.ps1 script and reboot manually
before running this workflow.
'@
    }
}

function Resolve-ExistingTestCertificateThumbprint {
    if ($CertificateThumbprint) {
        return $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
    }

    $certificates = @(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\My' |
            Where-Object {
                $_.FriendlyName -ceq
                'WinAirPlayAudio driver test signing'
            })
    if ($certificates.Count -ne 1) {
        $found = @($certificates | ForEach-Object Thumbprint) -join ', '
        throw @"
Expected exactly one existing dedicated WinAirPlayAudio test certificate;
found $($certificates.Count): $found
Use the existing installer\New-TestCertificate.ps1 script when none exists,
or rerun with -CertificateThumbprint when more than one exists.
"@
    }
    return $certificates[0].Thumbprint.Replace(' ', '').ToUpperInvariant()
}

function Invoke-ExistingScript {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host "`n=== $Description ===" -ForegroundColor Cyan
    & $Action
    if (-not $?) {
        throw "Existing script failed: $Description"
    }
}

function Write-PipelinePlan {
    Write-Host @"
WinAirPlayAudio existing-script pipeline
  1. Run build.ps1 -Test -Configuration $Configuration (unit and process fixtures).
  2. Run build.ps1 -Package -Configuration $Configuration.
  3. Pass the fresh manifest hash to Sign-TestPackage.ps1.
  4. Pass the protected signed result to Install-Driver.ps1.
"@
}

function Invoke-Pipeline {
    Write-PipelinePlan

    if ($WhatIfPreference) {
        $null = $PSCmdlet.ShouldProcess(
            "$env:COMPUTERNAME WinAirPlayAudio installation",
            'Run the existing test, package, signing, and install scripts')
        return
    }

    # Planning is read-only on build runners; every real action retains the
    # strict workstation/runtime gate before elevation or machine changes.
    Assert-WinAirPlayTarget
    if (-not (Test-WinAirPlayAdministrator)) {
        Invoke-ElevatedPipeline
        return
    }

    Assert-CurrentBootUsesTestSigning
    $thumbprint = Resolve-ExistingTestCertificateThumbprint

    Write-Warning @'
Install-Driver.ps1 performs a destructive clean reinstall. Back up any existing
WinAirPlayAudio configuration, credentials, and logs before continuing.
'@
    if (-not $PSCmdlet.ShouldProcess(
            "$env:COMPUTERNAME WinAirPlayAudio installation",
            "Run the existing scripts and install the $Configuration package signed by $thumbprint")) {
        Write-Host 'Pipeline cancelled before invoking any build or machine-changing script.'
        return
    }

    Push-Location $repoRoot
    try {
        Invoke-ExistingScript `
            -Description "build.ps1 -Test -Configuration $Configuration" `
            -Action { & $buildScript -Test -Configuration $Configuration }

        Invoke-ExistingScript `
            -Description "build.ps1 -Package -Configuration $Configuration" `
            -Action {
                & $buildScript -Package -Configuration $Configuration
            }

        $unsignedManifestSha256 =
            (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        Write-Host "Fresh unsigned manifest SHA-256: $unsignedManifestSha256"

        Write-Host "`n=== Sign-TestPackage.ps1 ===" -ForegroundColor Cyan
        $signedOutput = @(& $signScript `
                -PackageDirectory $packageDirectory `
                -CertificateThumbprint $thumbprint `
                -ExpectedManifestSha256 $unsignedManifestSha256 `
                -Confirm:$false)
        $signed = @($signedOutput |
                Where-Object {
                    $_.PSObject.Properties.Name -contains
                    'SignedManifestSha256'
                } |
                Select-Object -Last 1)
        if ($signed.Count -ne 1) {
            throw 'Sign-TestPackage.ps1 did not return one signed-package result.'
        }

        Invoke-ExistingScript `
            -Description 'Install-Driver.ps1' `
            -Action {
                & $installScript `
                    -PackageDirectory $signed[0].PackageDirectory `
                    -ExpectedSignedManifestSha256 `
                    $signed[0].SignedManifestSha256 `
                    -ExpectedSignerThumbprint $thumbprint `
                    -Confirm:$false
            }

        Write-Host @"

Existing-script pipeline completed successfully.
Signed package: $($signed[0].PackageDirectory)
Signed manifest SHA-256: $($signed[0].SignedManifestSha256)
"@ -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

$pipelineFailed = $false
try {
    Invoke-Pipeline
}
catch {
    $pipelineFailed = $true
    [Console]::Error.WriteLine(
        "WinAirPlayAudio pipeline failed: $($_.Exception.Message)")
}
finally {
    $pauseHere =
        $Pause -and
        ($WhatIfPreference -or (Test-WinAirPlayAdministrator))
    if ($pauseHere) {
        try {
            $null = Read-Host 'Press Enter to close this window'
        }
        catch {
            [Console]::Error.WriteLine(
                "Could not pause the console: $($_.Exception.Message)")
        }
    }
}

if ($pipelineFailed) {
    exit 1
}
