# Windows GUI wizards

These native x64 Windows wizards use [Inno Setup 7](https://jrsoftware.org/isinfo.php)
as the interface and the existing verified PowerShell transactions for product
changes. Inno's [license](https://jrsoftware.org/files/is/license.txt) permits this
use; the compiler's copyright and notices remain intact.

## Use

The generated pair is `WinAirPlayAudio-<version>-Setup.exe` and
`WinAirPlayAudio-<version>-Uninstall.exe`. Keep the companion uninstaller outside
the product's installed directory. Each executable embeds its own required
scripts; removal does not need an intact incoming driver package. These wrappers
do not register themselves in Apps & Features or install a second maintenance
runtime. The existing PowerShell code owns the product's files and lifecycle.

Both wizards embed and display the project's AGPL-3.0-only license. The driver
and third-party components retain their original licenses and notices; Setup's
embedded package includes the MS-PL and locked Rust dependency license texts.

Setup requests administrator access, displays the license and read-only checks,
then asks for explicit approval of dependencies, test-mode preparation, public
certificate trust and clean reinstall. A prerequisite/test-mode restart stops
before driver installation. Save work, restart Windows manually and rerun the
same wizard. Secure Boot and HVCI remain manual operator policy.

The removal wizard requests removal consent. Certificate-trust removal and
test-mode exit are optional and unchecked by default. Test-mode exit requires
other-driver, boot-change and recovery acknowledgements. These optional actions
run only after the backend proves product removal. Shared runtimes and private
keys remain. The interface cannot cancel a transaction midway; failures retain
diagnostics with Retry/Close instead of showing successful completion.

The wizards are attended interfaces. Silent GUI invocation is rejected; use
the [documented CLI options](../README.md) for unattended work. Successful GUI
completion exits 0, a completed phase needing a manual restart exits 3010, and
failure/cancellation uses Inno's nonzero exit codes (for example, 2 when closing
after an error). No GUI action automatically reboots Windows.

Direct developer builds leave the outer wizard EXEs **unsigned**. The packaging
tools validate the complete internal signed bundle and both signed GUI EXEs
against the manifest before assembling a two-EXE user ZIP. Payloads, licenses
and public DER remain embedded. CI validates source builds and packaging.
Prebuilt wizards are unavailable. Clean-host installed acceptance remains open.

## Build

From the source checkout with PowerShell 7, use the authoritative entry point:

```powershell
.\build.ps1 -GuiWizards `
  -SignedBundleDirectory '<authenticated extracted test-signed bundle>' `
  -ExpectedSignedManifestSha256 '<trusted 64-hex signed manifest hash>' `
  -ExpectedSignerThumbprint '<trusted 40-hex public signer pin>' `
  -WizardOutputDirectory '<new ignored local output directory>'
```

The builder validates the complete Release payload, public DER, canonical
version, manifest and signer identities without importing certificate trust.
Read locks protect those input bytes during compilation. It rejects existing
output names, reserves the output directory against concurrent builders, emits
hash/signature inventories and checks output for current private builder paths.
It does not sign, install a driver or change boot policy.

The builder uses a verified portable Inno Setup **7.1.1 x64** compiler beneath
ignored `.tools/`. Its official distribution is SHA-256 pinned and its compiler
components must have valid Pyrsys B.V. signatures and the expected engine
version. The documented portable extraction avoids machine-wide installation,
file associations, shortcuts and uninstall registration. Rust/WDK/Visual Studio
are not needed to wrap an existing signed package. Advanced direct builds may
pass `-CompilerPath` or `-NoBootstrap` to `Build-Wizards.ps1`.

For safe UI testing:

```powershell
.\build.ps1 -GuiWizards -PreviewWizard `
  -WizardOutputDirectory '<new ignored local preview directory>'
.\build.ps1 -GuiWizards -PreviewWizard -WizardPreviewOutcome 3010 `
  -WizardOutputDirectory '<another new ignored local preview directory>'
```

Preview names end in `-Preview.exe`; they show clear simulation labels and run
without elevation. Real helper/payload extraction and worker execution are
excluded at compile time. `-WizardPreviewOutcome 1` simulates failure. These
previews cannot perform installation, removal, certificate or boot operations.
See VALIDATION for executed GUI checks and the `NOT RUN` privileged procedure.
