# Installer scripts

These script entry points support source builds and developer bundles. The
[GUI packaging tools](gui/README.md) embed them in native Setup and Uninstall
executables for controlled testing.

Run commands from the repository root. The complete operator procedure is in
[build and install](../docs/build-and-install.md): build/package, explicit
recovery-machine preparation, protected test signing, clean reinstall,
uninstall and separate certificate/boot-policy cleanup.

| Entry point | Responsibility |
|---|---|
| `package.ps1` | Build exact unsigned x64 signing input and its manifest; no elevation or installation. Normally invoke `build.ps1 -Package`. |
| `New-RustLicenseBundle.ps1` | Collect pinned dependency notices for packaging. |
| `Set-TestSigning.ps1`, `New-TestCertificate.ps1` | Explicit elevated boot-policy and machine-trust preparation, each with acknowledgement switches. |
| `Sign-TestPackage.ps1` | Authenticate the operator's unsigned-manifest hash, sign a protected snapshot and return its signed-manifest hash. |
| `Install-Driver.ps1`, `Uninstall-Driver.ps1` | Validate exact ownership and perform clean-slate product installation/removal. Reinstall deletes old config, credentials and logs. |
| `Invoke-TestBuildPackageSignInstall.ps1` | Compose existing authoritative scripts for the root CMD launcher; never creates trust, changes boot policy or reboots. |
| `Uninstall.cmd`, `Start-Uninstall.ps1`, `Uninstall.ps1` | Guided complete removal, followed by optional public trust cleanup and test-mode exit. |
| `Common.ps1` | Shared ownership, signature, snapshot, payload and transaction contracts. |
| `Test-InstallerContract.ps1` | Build-independent contract/fixture checks, also run by `build.ps1 -Test`. |

Host-mutating scripts require explicit elevation/acknowledgement and support
`-WhatIf`. Transported packages require manifest hashes through an independently
trusted channel. See [security](../docs/security.md) for trust boundaries,
[release preparation](../docs/releasing.md) for unsigned signing inputs and
test-signed package preparation, and
[validation](../VALIDATION.md) for executed evidence and remaining privileged gates.

For a test-signed two-file developer ZIP, follow the GUI instructions. The
executables embed their install and recovery scripts. The test machine needs
public certificate trust and test-mode preparation.
Signing alone can execute on a compatible x64 Windows Server
CI host; installation and boot-policy scripts remain workstation-only.

## Guided prebuilt setup

The CLI procedure in this section requires a complete signed internal/developer
bundle with `Setup.cmd`. Authenticate and unblock that
ZIP before extraction. From its root, run its generated launcher (the
authenticated bundle embeds the manifest and signer identities in that launcher):

```powershell
.\Setup.cmd -Plan
.\Setup.cmd
```

Double-clicking the bundle’s `Setup.cmd` starts guided setup. The generic source
launcher prompts for independently trusted identities; it also accepts explicit
`-ExpectedSignedManifestSha256` and `-ExpectedSignerThumbprint` parameters. A source
checkout or unsigned signing-input bundle is insufficient: setup needs the already-signed
`package/` and public `test-signing.cer`. Never derive the expected identities
from unverified received files. The authenticated release ZIP also establishes
trust in the setup scripts; the package hash authenticates the binary payload.

The inbox x64 Windows PowerShell bootstrap checks Windows 11 workstation 24H2+,
native x64 and missing runtimes, requests UAC elevation, and installs required
Microsoft prerequisites after explicit consent. It accepts stable PowerShell
7.6.9 or newer at its canonical system installation and x64 VC++ runtime
14.51.36231.0 or newer. The runtime floor tracks the release compiler; review it
when upgrading MSVC. Rust, Visual Studio, WDK and Bonjour are not required.
Windows supplies the WASAPI, networking and Universal CRT platform components.

PowerShell's [official x64 7.6.9 MSI](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.9)
is SHA-256 pinned. VC++ is downloaded from
[Microsoft's current v14 permalink](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist), then checked for Microsoft Authenticode,
x64 product identity and minimum version. Both downloads require HTTPS and a
valid Microsoft signature before execution from an administrator-only cache.
The installed x64 binaries and versions are rechecked; installer exit alone is
insufficient. Shared runtimes remain installed after product removal or failure.

For offline setup, add `-PrerequisiteDirectory '<absolute folder>'` containing
`PowerShell-7.6.9-win-x64.msi` and `vc_redist.x64.exe` as needed. The same checks
apply to protected copies. An offline folder prevents network fallback.

Setup checks the running kernel's Code Integrity flags for active TESTSIGNING.
If inactive, it requires boot-change/recovery acknowledgements, calls the existing
boot-policy script, and returns **3010 (restart required)**. Restart Windows
manually and rerun the same command. A prerequisite restart also returns 3010;
setup installs no driver in that phase. There is no scheduled auto-resume or
automatic reboot. Secure Boot changes remain manual; HVCI is never disabled.

Once test mode is active, explicit trust and clean-reinstall acknowledgements
permit the pinned public DER in LocalMachine Root/TrustedPublisher, followed by
the existing signed package, Driver Store, service and scoped firewall checks.
On failure, setup attempts removal of only trust it added, and verifies scratch
cleanup. Existing certificate trust remains. Driver-install rollback retains
the existing clean-slate behavior, so a previous installation is not restored.
Boot policy and shared runtime changes are deliberately retained for recovery.

For attended use, answer each prompt. For automation, all relevant consent must
be supplied explicitly; missing consent with `-NonInteractive` fails closed:

```powershell
.\Setup.cmd -NonInteractive -InstallDependencies -EnableTestSigning `
  -AcknowledgeBootConfigurationChange -AcknowledgeBitLockerRecoveryRisk `
  -TrustTestCertificate -AcceptCleanReinstall
```

`-Plan` and `-WhatIf` are read-only, require no elevation, and download nothing.
The generic source launcher with no identities reports identity as unverified.
Exit **0** means
the current phase succeeded; **1** means failure/cancellation; **3010** means a
manual restart and rerun are required. A successful driver install verifies the
service/Driver Store/firewall; it does not prove receiver playback.

After `Uninstall-Driver.ps1 -ConfirmRemoval`, remove this product's public test
trust using `Remove-TestCertificate.ps1 -CertificateThumbprint '<pin>' -ConfirmRemoval`,
then disable TESTSIGNING using `Set-TestSigning.ps1 -Mode Disable
-AcknowledgeBootConfigurationChange -AcknowledgeBitLockerRecoveryRisk` and reboot
manually before restoring firmware policy. Coordinate any other test-signed
drivers before disabling a shared boot setting. Recovery and unexecuted
clean-host acceptance are recorded in the main operator guide.

## Guided uninstaller

From an authenticated extracted bundle, double-click `Uninstall.cmd`, or run:

```powershell
.\Uninstall.cmd -Plan
.\Uninstall.cmd
```

The launcher requests elevation and explicit permanent-removal consent. It
removes the product's service, scoped firewall rule, devices, Driver Store
packages, installed files, configuration, credentials, logs and installer/tool
caches using the existing ownership-validated removal path. It checks kernel
unload and verifies absence before offering any certificate or boot-policy
change. Failed or incomplete removal leaves test mode and certificate trust
unchanged. Do not delete driver services or registry entries manually when
removal reports that a reboot is required; restart and rerun.

After successful removal, it offers removal of the dedicated public test
certificate from LocalMachine Root/TrustedPublisher, then asks whether to exit
Windows test mode. Optional questions default to retaining the current setting.
Disabling test mode requires acknowledging other installed test-signed drivers,
the boot configuration change, and BitLocker recovery access. It returns 3010
after successfully configuring TESTSIGNING off: **restart Windows manually** to
apply the change. It never reboots or changes Secure Boot/HVCI automatically.

Removal works without `package/`, its manifest or `test-signing.cer`, so damaged
payloads do not obstruct recovery. The signed release launcher pins its public
certificate identity; the generic source launcher can derive it from validated
protected install state or accept `-ExpectedSignerThumbprint '<40-hex pin>'`.
Missing, malformed or mismatched identity retains certificate trust; explicitly
requested trust cleanup reports failure if identity cannot be established.
An older bundle cannot silently remove a different installed signer's trust.
Shared Microsoft runtimes, private signing keys and separately retained signed
package archives remain. The supported x64 PowerShell runtime must remain
available until removal finishes; the uninstaller downloads/installs nothing.

For unattended product-only removal, leave the optional settings unchanged:

```powershell
.\Uninstall.cmd -NonInteractive -ConfirmRemoval
```

To remove public trust and also exit test mode, explicitly opt in:

```powershell
.\Uninstall.cmd -NonInteractive -ConfirmRemoval -RemoveTestCertificate `
  -DisableTestSigning -AcknowledgeOtherTestDrivers `
  -AcknowledgeBootConfigurationChange -AcknowledgeBitLockerRecoveryRisk
```

The generated release launcher supplies the signer pin; a generic source
launcher may need `-ExpectedSignerThumbprint`. `-KeepTestCertificate` and
`-KeepTestSigning` skip the respective attended question; each conflicts with
its removal/disable switch. `-ForcePackageRemoval` remains opt-in and does not
bypass ownership or kernel-unload checks. Exit 0 means removal/selected cleanup
completed, 1 means cancellation/failure (possibly after product removal), and
3010 means a manual restart is required. `-Plan`/`-WhatIf` change nothing and
require no elevation. Clean-host installed acceptance remains `NOT RUN` until
separately executed and recorded in VALIDATION.
