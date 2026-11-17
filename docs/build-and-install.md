# Build and install

The target is Windows 11 x64 24H2+. [Development](development.md) owns toolchain,
bootstrap and build commands. This page owns operator procedures for packaging,
test signing, deployment, removal and recovery. Use a disposable test machine
with recovery access for driver work. Actual privileged/hardware results belong
in [VALIDATION.md](../VALIDATION.md); keep raw records in [`.local/`](local-artifacts.md).

The source preview provides local developer builds. Use only a disposable test
machine with recovery access for installed evaluation. Clean-host installation,
privileged failure recovery and physical playback await acceptance testing. See
the [known limitations](known-limitations.md) before running privileged steps.

## Build the package

From the repository root in PowerShell 7:

```powershell
.\build.ps1 -Package -Configuration Release
```

This builds the fixed x64 driver/service/tools payload under
`driver/out/package/Release/x64` and prints its unsigned-manifest SHA-256.
Licenses, canonical version, portable dependency inventory, source provenance
and payload hashes are included. The [developer release workflow](releasing.md)
can wrap it as an explicitly unsigned preview; a supported distribution needs
the separate production gates below.

## Prepare and deploy on a test machine

Boot-policy changes, certificate trust and installation are explicit elevated
operations. Review BitLocker recovery and Secure Boot policy first. These
scripts never disable Secure Boot or reboot automatically.

Record the manifest hash from the trusted build. If a package crosses an
untrusted boundary, convey that expected hash through an independent trusted
channel; recomputing a hash from the received package is not authentication.

In an elevated PowerShell 7 terminal from the repository root:

```powershell
.\installer\Set-TestSigning.ps1 -Mode Enable `
  -AcknowledgeBootConfigurationChange `
  -AcknowledgeBitLockerRecoveryRisk
# Reboot manually, then return to an elevated PowerShell.

$certificate = .\installer\New-TestCertificate.ps1 `
  -AcknowledgeMachineTrustInstallation

$expectedUnsignedManifestSha256 = '<64-hex SHA-256 from the trusted package build>'
$signed = .\installer\Sign-TestPackage.ps1 `
  -PackageDirectory .\driver\out\package\Release\x64 `
  -CertificateThumbprint $certificate.Thumbprint `
  -ExpectedManifestSha256 $expectedUnsignedManifestSha256

.\installer\Install-Driver.ps1 `
  -PackageDirectory $signed.PackageDirectory `
  -ExpectedSignedManifestSha256 $signed.SignedManifestSha256 `
  -ExpectedSignerThumbprint $certificate.Thumbprint

Get-Service WinAirPlayAudioService
& "$env:ProgramFiles\WinAirPlayAudio\endpoint-list.exe" --json
```

The signer authenticates the unsigned preimage, signs only in protected storage,
regenerates the catalog and returns a final signed-manifest hash. Installation
requires that final hash as a distinct trust anchor; transport it independently
when moving signed output to another machine. Test signatures use `/pa` and
`/pa /c` for signatures/catalog membership. `/kp` remains a production-signing
expectation, not a pass criterion for the dedicated self-signed test root.
Protected snapshot/tool inventory controls are specified in [security](security.md).

## Guarded local launcher

After the test-machine preparation above, the root
`Test-Build-Package-Sign-Install.cmd` requests elevation and one destructive
confirmation, then composes the selected-configuration workspace test, Release package,
protected signing and clean-install scripts. It derives hashes within that
single trusted local invocation; it is not a transported-package acceptance path.

The launcher selects automatically only when exactly one certificate has the
`WinAirPlayAudio driver test signing` identity. The signer still validates its
private key, validity, EKU, self-signing and machine trust. Select explicitly
when necessary:

```powershell
.\Test-Build-Package-Sign-Install.cmd -CertificateThumbprint <40-hex-thumbprint>
```

Preview without elevation or mutation:

```powershell
.\installer\Invoke-TestBuildPackageSignInstall.ps1 -WhatIf
```

The launcher never creates certificate trust, changes boot/network policy,
reboots, or bypasses package/ownership/unload checks.

## Clean reinstall and failure recovery

Install is a destructive clean reinstall: old configuration, DPAPI credentials,
logs, endpoints, services, runtime/state, transaction artifacts and matching
Driver Store packages are removed. Back up anything you intend to recreate
before confirming. A failed fresh installation cleans to verified zero product
state; it does not restore or restart the discarded version.

Before mutation, the installer authenticates a protected input snapshot and
validates exact ownership. After devnode removal it waits up to 30 seconds for
the kernel service to be absent or both `State=Stopped` and `Started=false`.
Failure stops before Driver Store deletion and requires reboot/retry.
`-ForcePackageRemoval` and service-registry edits do not bypass this gate.
The authenticated active snapshot is revalidated after cleanup before install.

Installation creates/verifies only the exact `WinAirPlayAudio.RaopUdpIn`
firewall rule before starting the service. Its program/profile/address scope
and ownership checks are in [security](security.md#firewall-and-listeners).
Do not broaden a rule to work around a failure; inspect with
[troubleshooting](troubleshooting.md).

## Configuration and credentials

Configuration is `%ProgramData%\WinAirPlayAudio\config.json`; bounded logs rotate
between `logs\service.jsonl` and `service.jsonl.1`. The current
`raop_sync_latency_ms` default is 500, with range 250–3,000. This is a sender sync
offset, not guaranteed speaker latency; a larger valid receiver RECORD
`Audio-Latency` takes precedence. Restart the service after intentional config
changes. Windows endpoint volume/mute propagation remains unimplemented.

Store a Digest password from an elevated shell without putting it in argv:

```powershell
$password = Read-Host -AsSecureString
$credential = [Net.NetworkCredential]::new('', $password).Password
$credential | & "$env:ProgramFiles\WinAirPlayAudio\credential-store.exe" `
  --receiver '<canonical-receiver-id>' --password-stdin
Restart-Service WinAirPlayAudioService
Remove-Variable credential
```

The receiver-scoped machine-DPAPI directory grants access only to
Administrators and `SYSTEM`; it does not protect secrets from those identities.

## Remove the product and test-machine trust

A signed developer bundle can include a guided uninstaller:

```powershell
.\Uninstall.cmd -Plan
.\Uninstall.cmd
```

It verifies complete product removal, offers dedicated public certificate-trust
cleanup, then offers test-mode exit. Disable test mode only after confirming no
other test-signed driver needs it and acknowledging boot/BitLocker recovery.
Exit 3010 requires a manual restart. Shared runtimes and private signing keys
remain. It needs no intact packaged binaries and never downloads prerequisites.
See [guided uninstaller options](../installer/README.md#guided-uninstaller) for
unattended use and retained settings.

For direct elevated removal:

```powershell
.\installer\Uninstall-Driver.ps1 -ConfirmRemoval
```

The direct removal script uses the same ownership-validated clean-slate path as reinstall. It
matches exact hardware/provider/original-INF and firewall-rule identities,
checks kernel unload, proves zero product state and fails closed on incomplete
cleanup. `-ForcePackageRemoval` is opt-in and cannot bypass unload. It does not
remove similarly named user/Group Policy rules, signed-package archives,
certificate trust or test-signing boot state.

After all test drivers are removed, clean up trust and boot policy explicitly:

```powershell
.\installer\Remove-TestCertificate.ps1 `
  -CertificateThumbprint $certificate.Thumbprint `
  -ConfirmRemoval
.\installer\Set-TestSigning.ps1 -Mode Disable `
  -AcknowledgeBootConfigurationChange `
  -AcknowledgeBitLockerRecoveryRisk
# Reboot manually.
```

Certificate cleanup removes machine trust but retains the private key in
`LocalMachine\My`. Add `-RemovePrivateKey` only when irreversible key deletion
is intended. Record the actual postconditions locally; the repository does not
assert an operator's current boot/certificate state.

## Production signing

A supported release needs the applicable Microsoft Partner Center submission/
attestation or HLK path, organization signing, timestamping, catalog verification
on a clean Secure Boot/HVCI machine and preserved submitted/final hashes.
The returned catalog may use a different identity from organization-signed
executables:

```powershell
.\installer\Install-Driver.ps1 `
  -PackageDirectory <protected-production-package> `
  -ExpectedSignedManifestSha256 <trusted-final-manifest-sha256> `
  -ExpectedCatalogSignerThumbprint <returned-catalog-thumbprint> `
  -ExpectedExecutableSignerThumbprint <organization-thumbprint>
```

The final manifest hash must come from an independently trusted release channel.
Production credentials/submission and clean-host acceptance remain **NOT RUN**;
consult [the release checklist](release-checklist.md) before distribution.
