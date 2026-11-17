# Versioning and releasing

WinAirPlayAudio is an experimental source preview. CI validates packages in the
runner workspace. Local packaging and test signing are available for development.
[DEFECTS.md](DEFECTS.md) and the [release checklist](release-checklist.md) record
the remaining gates for public binary distribution.

## Version source

[`version.json`](../version.json) is the canonical version record. Its fields
are `schema_version`, `version`, `driver_revision`, and `driver_date`. The
semantic product version uses `MAJOR.MINOR.PATCH`, with optional SemVer
prerelease and `+build` metadata. Build metadata does not change precedence and
cannot alone justify a version update. Cargo workspace packages share it. Windows driver
resources use four numeric fields: the three numeric components plus the
driver revision. A prerelease suffix remains in product/Cargo metadata rather
than the numeric Windows driver version.

Distinct driver packages must have distinct appropriate Windows driver
identities. When a prerelease and its stable successor share the same three
numeric components, increase the driver revision rather than reusing the
prerelease's four-part version for changed driver contents.

The driver revision is package identity, not a fourth SemVer component or proof
of release. Driver dates use ISO `yyyy-MM-dd`; the script renders the INF date.
Select the intended metadata date explicitly rather than stamping it during
each build. User-facing release records use the maintainer's local date; an
intentional UTC driver date can differ. [CHANGELOG.md](../CHANGELOG.md) owns dated
version history. Preserve published tags and artifacts once released.

Check consistency from the repository root:

```powershell
.\scripts\Version.ps1 -Check
```

For an intentional version update, supply all three setter parameters together:

```powershell
# Example only: use the version, revision and driver date selected for the release.
.\scripts\Version.ps1 -Version 0.2.0-beta.1 -DriverRevision 0 -DriverDate 2026-11-01
.\scripts\Version.ps1 -Check -Tag v0.2.0-beta.1
```

Review `version.json`, Cargo workspace/lock versions, and driver INF/project/
resource copies together. Do not edit generated version copies independently.
Keep dependency versions unchanged unless the release intentionally changes
them. `-Check` returns the product version, four-part driver version and date;
an optional `-Tag` must agree with the canonical `v<version>` tag.

During `0.x`, a minor version identifies a material feature or compatibility
change; a patch identifies compatible fixes. A future `1.0.0` requires an
explicitly defined supported contract and completed acceptance. Tags identify
an immutable reviewed source commit. Do not invent or backdate a public release
for historical local test builds.

## Prepare a release candidate

1. Choose the scope and intended claim: experimental source, a developer preview
   bundle, or a supported binary. Check all relevant defect and release gates.
2. Update the canonical version through `scripts/Version.ps1`, prepare the
   changelog, and reconcile README, compatibility, known limitations and exact
   validation evidence. Record which driver revision belongs to the product
   version.
3. Validate the intended clean source set with pinned tools. Run the commands
   in [development](development.md), including Debug/Release user mode, tests,
   integration, affected driver builds, and complete Release packaging. Perform
   dependency advisory/license checks and inspect the generated manifest.
4. Review the staged file list and intended public history. Exclude `.local/`,
   private diagnostics, raw captures/audio, dumps, keys/certificates, local
   inventories, reference checkouts and cached third-party binaries. Ignoring a
   file does not remove its earlier copies from Git history.
5. Verify required licenses, sanitized dependency inventory, checksums and
   signer provenance. A supported binary needs usable install/recovery/uninstall
   procedures. Build in two independent roots and compare outputs according to
   the acceptance plan, documenting expected generated/signature differences.

## License and Corresponding Source handoff

Current original project code outside the driver component is `AGPL-3.0-only`.
The driver component and its adaptations remain MS-PL; dependencies and the
Inno Setup runtime retain their upstream licenses. Preserve their notices and
complete license texts. Packaging copies the project license, MS-PL text and
locked Rust dependency notices into the runtime payload; both GUI wizards
embed and display the project license. Earlier releases keep their supplied
licenses and must not be relabeled by replacing their assets.

Before conveying an AGPL binary, arrange and verify its exact Corresponding
Source handoff under [AGPLv3 sections 1 and 6](https://www.gnu.org/licenses/agpl-3.0.html).
Include the applicable source, locked dependencies and required build/install
scripts, preserving third-party licenses. Use a reviewed, sanitized source
snapshot matching the binary's recorded source commit. A commit hash or a link
to a repository recipients cannot access does not supply that source. Keep
source delivery separate from the two-EXE user ZIP and record the selected
delivery method, recipient access and source/binary match before tagging.

This handoff remains a binary-release gate under DEF-007. Record how recipients
can obtain the matching source and how its contents were verified before any
future binary distribution. Follow the license’s applicable notice and
network-source requirements.

## Developer preview bundle

After an unsigned Release package has been built, prepare a versioned developer
bundle and checksum from a clean reviewed checkout:

```powershell
.\scripts\New-ReleaseBundle.ps1 -Configuration Release
```

The default destination is `target/release`. `-OutputDirectory` chooses another
destination, and `-AllowDirty` permits local preparation from a dirty tree;
dirty-tree output is not a validated tagged release. The script returns the
version, archive path and checksum-file path. Review their manifest, payload and
provenance before any upload.

`build.ps1 -Package` produces unsigned signing input; the developer bundle wraps
that input for an explicit developer handoff. Neither artifact supplies a
supported signed installer. Its description and release notes must identify the
unsigned, experimental scope and outstanding acceptance. Do not present source-
checkout commands as a complete end-user installation experience.

## Test-signed binary preparation

Public binary distribution requires separate approval and release acceptance.
For local test-machine builds, use the
[build, signing and recovery procedures](build-and-install.md).
The current GUI packaging tools validate an authenticated signed internal bundle
and both signed wizard executables. The user ZIP layout contains exactly
`WinAirPlayAudio-<version>-Setup.exe` and
`WinAirPlayAudio-<version>-Uninstall.exe`, with a separate SHA-256 file.
Setup embeds the signed driver, service, supporting scripts, public DER
certificate and licenses. Uninstall embeds its own recovery scripts so it can
run without the incoming package.

Any future hosted signing flow requires isolated signing jobs, protected
tag-only credentials and review of the workflow permissions and cleanup.
Keep private keys and signing inputs out of public workflow runs. Record source
delivery, exact artifact checks, signer and installed acceptance before enabling
binary publication.

### Local verification

```powershell
.\scripts\Test-ReleaseBundle.ps1
.\scripts\Test-ReleaseArchive.ps1
.\scripts\Test-InstallerRelease.ps1
.\scripts\Test-CiSigning.ps1
.\installer\Test-InstallerContract.ps1
.\.github\scripts\Test-ReleaseWorkflow.ps1
.\.github\scripts\Test-Workflows.ps1
```

Local fixtures establish tooling behavior. Record any future hosted signing and
publication evidence in VALIDATION.md, including the source revision, artifact
hashes, signer, cleanup and recipient access. Keep private keys on the signing
side of the handoff.

## Production acceptance

A supported binary claim still needs named receiver/firmware and platform
results, a proven physical-output oracle, working endpoint controls, lifecycle/
failure cleanup, minimum privileges, WLAN/clock/soak and applicable driver/HLK
validation, usable clean-host installation and production signatures. Test signing
and successful CI do not complete those gates. AP2 requires its separate accepted
Stage 0–3 plan. The production Microsoft submission path is not implemented by
the source preview.

Move relevant Unreleased changes into a dated changelog entry when a release
actually completes, and link the immutable release/tag and validation evidence.
Keep unavailable acceptance visible; an experimental label is not a test result.
