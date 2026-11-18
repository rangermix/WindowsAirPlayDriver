# Defects and readiness tracker

This is the local source-of-truth backlog for defects and release gaps. IDs are
stable and must not be reused. A bug is faulty implemented behavior; release,
validation and documentation gaps are tracked separately. AP2 remains planned,
unsupported work governed by its accepted specification and Stage 0–3 plan.

`OPEN` means acceptance remains incomplete. `IN PROGRESS` identifies active
work; `RESOLVED` requires the implementation, relevant negative-path/cleanup
checks and documentation to be complete with linked evidence. A merge, passing
build, source review or older hardware result alone cannot close a missing
installed acceptance gate. Record unavailable procedures as `NOT RUN`.

The starting evidence is the 2026-10-31 project audit. The table maps its A01–A08
findings to permanent IDs; the records below retain their closure requirements.
Entries were opened from the audit and are updated with executed evidence.
Ongoing preparation is not reported as completed acceptance.

| ID | Type / priority | Summary | Audit | Status |
|---|---|---|---|---|
| DEF-001 | Publication/privacy gap · P1 | Private diagnostics and binary provenance in intended public source/history | A01 | OPEN |
| DEF-002 | Behavior defect · P1 | RTSP trickle reads exceed operation bounds and block cancellation | A02 | OPEN |
| DEF-003 | Product defect · P1 | Windows endpoint volume/mute does not affect outgoing audio | A03 | OPEN |
| DEF-004 | Security/release gap · P1 | Network worker remains combined with privileged device management | A04 | OPEN |
| DEF-005 | Behavior defect · P2 | Oversized UDP datagrams abort a recoverable RAOP session | A05 | OPEN |
| DEF-006 | Packaging defect · P2 | Microsoft-derived driver license omitted from package | A06 | RESOLVED |
| DEF-007 | Delivery/reproducibility gap · P2 | Unsigned signing input is not a complete sanitized binary distribution | A07 | OPEN |
| DEF-008 | Claims/documentation defect · P2 | Auth preflight wording and installed/source documentation drift | A08 | OPEN |
| DEF-009 | Contributor/CI gap · P2 | Public workflow, dependency policy and release/version checks lack accepted baseline | A07 | RESOLVED |
| DEF-010 | Installed validation gap · P1 | Physical output, corrected WLAN, lifecycle, privilege and driver acceptance incomplete | Existing gates | OPEN |
| DEF-011 | Test-harness defect · P2 | RTP accounting regression used a 40 ms RTSP fixture setup timeout | Release CI expansion | RESOLVED |
| DEF-012 | Test-harness defect · P2 | Release sender/mock fixture overran UDP receive capacity and used an inexact frame assertion | Release CI expansion | RESOLVED |
| DEF-013 | Maintenance gap · P2 | Unused scaffolding, duplicate procedural docs/test stages and stale mutable-version assertions | Whole-project cleanup | RESOLVED |
| DEF-014 | CI planning defect · P2 | Read-only deployment planning rejected the Windows Server build host | Whole-project cleanup | RESOLVED |
| DEF-015 | Test-harness defect · P2 | Global GitHub CLI mock survived shared-process release tests | First hosted CI | RESOLVED |
| DEF-016 | Tooling defect · P2 | Concurrent explicit certificate output could overwrite another invocation | Signing review | RESOLVED |
| DEF-017 | Delivery defect · P2 | Archive reader rejected Inf2Cat's lowercase catalog manifest name | First signing probe | RESOLVED |
| DEF-018 | Publication defect · P2 | Published-by-tag lookup could not verify an uploaded draft | First rc1 publication | RESOLVED |
| DEF-019 | Uninstaller defect · P2 | Certificate prompt interpolation failed under strict mode | Guided removal fixtures | RESOLVED |
| DEF-020 | GUI defect · P2 | Requirements progress page recursively re-entered its check | Native wizard preview | RESOLVED |
| DEF-021 | GUI defect · P2 | Completion label clipped recovery/restart instructions | Native wizard preview | RESOLVED |
| DEF-022 | Recovery defect · P2 | Uninstaller unnecessarily inspected the VC runtime | GUI worker review | RESOLVED |
| DEF-023 | CI efficiency gap · P2 | Implicit and explicit Cargo targets repeat optimized compilation | rc.3 hosted build | OPEN |
| DEF-024 | Packaging defect · P2 | Published GUI ZIP exposes the full developer bundle instead of only installer/uninstaller | Release artifact audit | OPEN |
| DEF-025 | Source-hygiene defect · P2 | Source guard admitted raw audio, generated archives and additional local-only inputs | Repository cleanup | RESOLVED |
| DEF-026 | Attribution gap · P2 | Driver version resource replaces the upstream copyright notice | Publication audit | OPEN |
| DEF-027 | Installer security gap · P1 | Elevated PowerShell module lookup includes user-writable locations | Publication audit | OPEN |
| DEF-028 | Branding review gap · P2 | Project name incorporates Apple's AirPlay mark | Publication audit | OPEN |

## DEF-001 — Public source and history privacy

**Status:** OPEN. **Owner:** unassigned. **Blocks:** public source publication.

The legacy development repository contained private diagnostics and cached
binaries. The source-only candidate uses fresh Git metadata. The original
development records are preserved separately.

**Acceptance:** review the final source inventory and commit metadata, retain
third-party provenance, and verify the exact public ref and remote settings
before publishing the initial source commit.
See [the source-only review](../VALIDATION.md#source-only-preparation).

## DEF-002 — Absolute RTSP deadlines and cancellation

**Status:** OPEN. **Owner:** unassigned. **Blocks:** supported binary release.

`shared/src/raop/session.rs` sets socket read/write timeouts, while
`shared/src/raop/rtsp.rs` can keep reading partial headers/bodies without a
total operation deadline. A peer sending bytes before individual timeouts can
retain a worker; `StreamWorker` cancellation then waits in its synchronous join.
The bounded loopback proof used a 200 ms timeout and retained a sender for over
1.3 seconds until the local peer closed. Installed shutdown was source-derived,
not separately exercised.

**Acceptance:** connect, request write, response header/body, authentication
retry, setup and teardown obey explicit total bounds; cancellation interrupts
outstanding network work and workers join within a documented limit. Preserve
valid RTSP parsing, Digest and cleanup behavior.

**Closure evidence:** deterministic slow-header/body and cancellation
regressions, maximum-duration/cleanup assertions, process integration and an
installed stop/restart procedure recorded as PASS or still NOT RUN.

## DEF-003 — Endpoint master-volume and mute

**Status:** OPEN. **Owner:** unassigned. **Blocks:** supported binary release.

The driver exposes pre-volume/mute loopback; the service does not apply endpoint
master-volume/mute, and the sender sets a fixed initial receiver volume. Windows
mute therefore cannot be relied on to silence receiver playback.

**Acceptance:** endpoint master-volume/mute governs transmitted playback exactly
once, with orderly lifecycle/cancellation and no blocking work added to capture
or kernel real-time paths. Preserve the explicitly accepted AP2 control policy.

**Closure evidence:** unity, 50%, mute, unmute and rapid-change tests at the mock
receiver; installed endpoint and physical-receiver acceptance with a proven
audio oracle, plus README/known-limitations updates.

## DEF-004 — Minimum service privileges

**Status:** OPEN. **Owner:** unassigned. **Blocks:** supported binary release.

The installer configures `LocalSystem` for the combined endpoint/streaming
service. Untrusted discovery and RTSP processing share the device broker's
privileges. A narrower viable identity has not been established.

**Acceptance:** test and adopt minimum privileges, or split a minimal privileged
device broker from the network/audio worker through an authenticated, bounded,
versioned interface. Account, ACL, credential and cleanup behavior must match
the selected design; AP2 network/crypto work must satisfy its accepted restricted
worker requirement.

**Closure evidence:** documented identity/API justification, positive and
negative authorization/ACL tests, installed stream and stop/restart acceptance,
and updated threat model. No privilege-escalation exploit is implied by this gap.

## DEF-005 — Recover from oversized UDP messages

**Status:** OPEN. **Owner:** unassigned. **Blocks:** supported binary release.

Timing/setup and control receive paths use 2,048-byte buffers and propagate
Windows `WSAEMSGSIZE` as a fatal receive error. Source-IP validation follows the
receive, so an invalid oversized packet can abort an otherwise recoverable
session. A local API proof showed the next valid datagram can still be read.

**Acceptance:** reject and account for invalid oversized messages without
aborting the session; preserve bounded work, valid timing/resend behavior and
error handling for genuinely terminal socket failures.

**Closure evidence:** Windows regressions send an oversized datagram followed
by valid setup timing/control traffic, prove the session survives, and verify
normal teardown/cleanup. An API-only demonstration is not a session regression.

## DEF-006 — Packaged driver license handoff

**Status:** RESOLVED. **Scope:** license/attribution handoff, not general legal clearance.

The audited unsigned package omitted `driver/LICENSE.microsoft-samples.txt`
while its third-party notice directed recipients to that absent source path.

**Acceptance:** ship the Microsoft license and required retained attribution;
update package production and validation allowlists together, including protected
signing/install contracts; packaged notices point to the shipped location.

**Closure evidence:** fresh complete package, exact manifest and license-content
checks, signer/installer contract checks and reviewed notice links. This record
does not settle all AirPlay legal/MFi distribution questions.

**2026-10-31 closure:** the fresh Release package and real developer archive
include `LICENSE.microsoft-samples.txt`, byte-identical to the source license.
Both exact payload contracts and notice locations were updated. Installer
contracts, package hashes and the real unsigned archive gate passed; other
distribution and installed acceptance gates remain open.

**2026-11-04 AGPL follow-up:** the standalone removal wizard's conditional
`LicenseFile` omitted the project license. Both wizards now embed/display the
root license through the shared template. D-032 changes original non-driver
code to AGPL-3.0-only; the Microsoft driver license, headers and dependency
notices remain intact. Source/build evidence is recorded in VALIDATION;
the next AGPL binary/source handoff remains a separate DEF-007 release gate.

## DEF-007 — Public artifact layout and reproducibility

**Status:** OPEN. **Owner:** unassigned. **Blocks:** public binary release.

The unsigned developer package is signing input. Clean-host delivery and
independent-root reproducibility remain unverified. Build metadata and binaries
must exclude private paths before public distribution.

**Acceptance:** verify exact artifact membership, install/recovery/removal
procedures, licenses, dependency metadata, checksums and signer provenance.
Compare builds under two independent roots. Record expected generated or
signature differences.

**AGPL distribution:** verify accessible Corresponding Source matching the
binary's exact source commit and required build/install inputs before conveying
a binary. Follow the [release guide](releasing.md#license-and-corresponding-source-handoff).
The source-only repository has no active binary release workflow.

## DEF-008 — Accurate claims and current documentation

**Status:** OPEN. **Owner:** unassigned. **Blocks:** accurate public handoff.

The type-1 `/auth-setup` preflight accepts a response length but does not verify
a receiver proof; calling it authenticated receiver identity overstates the
implementation. Driver/readme/installed-source narratives also include older
snapshots that need a clear current summary.

**Acceptance:** describe the implemented preflight accurately, retain the classic
spoofing limitation, and distinguish current source, historical installed builds,
mock results and unexecuted physical tests. Reconcile user guides, developer
guides, version descriptions and reopened release-review items.

**Closure evidence:** source/documentation claim scan, relative-link checks,
final diff review and source/package/installed evidence references with no
unsupported support or authentication claim.

**2026-11-04 cleanup:** archived complete earlier records with verified hashes,
consolidated current validation/progress/decision guidance, and corrected the
stale assertion that runtime provisioning was absent. Provisioning is
implemented; clean-host execution remains NOT RUN. Earlier build/installed
evidence remains explicitly scoped. Remaining authentication/installed claims
and this entry's complete acceptance are still open.

**Source-only preparation:** the README and contributor guides describe source
builds and retain the endpoint mute and physical-acceptance limitations.
The RAOP API comment still describes type-1 preflight as server authentication.
The threat model now describes aggregate RTSP byte bounds and qualified
redaction for opt-in wire tracing.

The README screenshots show endpoint visibility on a prior installation.
See [the image review](../VALIDATION.md#readme-screenshots).

## DEF-009 — Contributor, CI and version/release baseline

**Status:** RESOLVED. **Scope:** contributor/CI/version/test-prerelease baseline;
not production or installed-driver acceptance.

The audit found no accepted contributor/security workflow, CI baseline or
dependency license policy. Independent Cargo/driver version copies and ad hoc
release records also need a defined consistency check.

**Acceptance:** provide contribution, security, development and release guidance;
canonical version updates/checks and changelog; a dependency advisory/license
policy; and Windows CI for applicable format, Clippy, tests, process integration,
version and static contracts. Driver/package jobs require the pinned WDK
environment. CI must separate ordinary checks from privileged hardware/signing
and restrict publication to an explicitly authorized final stage.

**Closure evidence:** fresh local command results, workflow configuration review
and an actual CI run once a remote is configured. Documentation or a workflow
file alone is not proof that hosted CI or publication works.

**Evidence:** the contributor, dependency and version baseline passed local and
hosted checks. The source-only workflow retains Windows Debug/Release,
driver/package and dependency validation. Signing and publication are outside
this workflow.

## DEF-010 — Installed and hardware acceptance

**Status:** OPEN. **Owner:** unassigned. **Blocks:** supported compatibility claim.

Historical local-render and wire/session evidence does not complete physical
output, corrected WLAN, clock/soak or privileged failure acceptance. The previous
analog capture fixture did not establish a usable playback oracle.

**Acceptance:** prove an independent audio oracle, then run named-receiver/
firmware playback, endpoint controls, corrected WLAN startup/reconnect/latency,
network/interface/sleep/restart, clock/CPU/memory/60-minute soak, partial-install
fault cleanup, standalone uninstall and active-stream removal. Complete account/
ACL checks, disposable-host Driver Verifier, applicable HLK and production signing.

**Closure evidence:** exact source/signed/installed manifests, environment and
receiver matrix, commands/procedures, measurements, cleanup and recovery records.
Follow [testing](testing.md), [build and install](build-and-install.md) and
[release checklist](release-checklist.md). Record every unavailable case `NOT RUN`;
do not close this entry from builds or mocks alone.

## DEF-011 — RTSP scheduling bound in an RTP accounting test

**Status:** RESOLVED. **Type:** test-harness defect. **Scope:** no production behavior change.

The new Release gate exposed the RTP send-failure/accounting test timing out
while setting up its local RTSP peer under a shared 40 ms helper deadline.
This test checks transactional RTP state, not RTSP timeout behavior. Its setup
now has a bounded one-second I/O allowance, matching the neighboring recovery
fixture. The dedicated explicit timeout test retains its short deadline.

**Closure evidence:** the affected shared library passed all 143 Release cases
after the test-only change; the final full gates are recorded in VALIDATION.md.
The production absolute-operation deadline gap remains DEF-002.

## DEF-012 — Release process interoperability failure

**Status:** RESOLVED. **Type:** test-harness defect. **Scope:** production transport unchanged.

The unpaced one-second Release burst overran the strict mock's receive buffer;
the receiver rejected a sequence gap, then the sender saw connection-abort error
10053. The intended 4,410-frame assertion also accepted 44,100 by substring.
The fixture now explicitly sends 0.1 seconds, checks exact report fields, waits
for receiver readiness instead of sleeping, captures both child outputs, and
enforces bounded child cleanup. Strict mock validation remains unchanged.

**Acceptance:** a bounded reproducible process fixture with useful failure
output, normal child cleanup and passing Debug/Release process gates. Keep
unrelated transport defects and installed compatibility gates open.

**Closure evidence:** focused Clippy and all three Debug/Release process tests
passed, including an actual forced timeout that kills/reaps the idle loopback
child and joins its output reader. Direct Release reproduction changed from a
sequence-gap failure to both children exiting successfully with exactly 4,410
frames, 13 packets, one retransmission and one timing reply. Full gate results
are in VALIDATION.md; raw before/after evidence remains private under `.local/`.

## DEF-013 — Redundant source and procedural owners

**Status:** RESOLVED. **Scope:** redundant implementations and maintenance surfaces.

The empty integration crate ran no tests, unused shared config/queue and sample
property helpers had no production consumers, and repeated CI/launcher stages
reran process cases already in the workspace suite. Package filename lists and
mutable DriverVer literals could drift from their canonical owners. Historical
reports and overlapping guides repeated current tracker/validation/procedures.

**Closure evidence:** all 145 present project files were reviewed with per-file
dispositions. Unused paths were removed after consumer/registration/metadata
checks; real Cargo targets, active driver interfaces, independent trust checks,
accepted AP2 requirements and the D-020 owner record remain. Debug/Release tests,
focused integration, native builds/package and focused archive/workflow contracts
pass. Unique historical records are preserved privately; see VALIDATION.md.

**2026-11-04 follow-up:** rechecked the 168-file source inventory and consumers
of removal candidates. Retained active Rust dependencies, native projects,
installer/recovery tools and internal signing bundles. Removed 54 unused native
declaration lines and three empty directories; consolidated the duplicate VS
probe and nine-EXE signing list. Twelve complete source/document baselines were
copied and size/SHA-256 verified under ignored `.local/` before editing.
Current full tests, release fixtures and native Debug/Release builds pass;
active AP2 defaults/specifications and unexecuted acceptance remain preserved.

## DEF-014 — Read-only planning on the CI build host

**Status:** RESOLVED. **Scope:** planning only; supported runtime platforms unchanged.

The launcher called strict runtime-OS validation before its read-only `-WhatIf`
return. The Windows Server hosted runner therefore could not perform the dry-run
used by installer contracts, despite never deploying the driver. The guard now
runs immediately after the pure planning return and before admin/elevation or
real work.

**Closure evidence:** a guarded simulated Server fixture performs zero OS queries
or side effects for planning. Its real-action branch performs the OS query and
rejects Server before any admin/elevation/mutation. Installer contracts and full
Debug/Release gates pass. Hosted Debug/Release CI also passes in the rc2
workflow recorded in VALIDATION; runtime platform support is unchanged.

## DEF-015 — GitHub CLI mock cleanup across test scripts

**Status:** RESOLVED. **Scope:** test harness; no product behavior change.

Publication fixtures left a global GitHub CLI mock and native exit status
behind in a shared PowerShell process. Both mock suites now remove their owned
function and restore the caller's previous native exit status. Shared-process
fixtures passed. Real GitHub CLI functions remain protected from mocking.

## DEF-016 — Atomic offline certificate generation

**Status:** RESOLVED. **Scope:** offline certificate output; no machine trust.

Review found that checking an explicit output directory before creating it did
not reserve that directory: concurrent invocations could reuse it, overwrite a
different identity, or remove another invocation's files during rollback.
Generation now writes into its own protected random staging directory and uses
an atomic same-volume directory move that refuses an existing destination.
Rollback removes only that invocation's verified stage.

**Closure evidence:** two real concurrent generator processes targeting one
output produce exactly one winner; the loser leaves the winner's valid PFX
unchanged, all child processes join, staging residue is absent, and private
fixtures are removed. The full 37-case certificate suite passes. The configured
release identity used a fresh GUID destination and was not affected.

## DEF-017 — Windows catalog basename casing in the release envelope

**Status:** RESOLVED. **Scope:** release authentication; no signature-policy change.

Inf2Cat recorded a lowercase manifest basename while the ZIP used the canonical
catalog name. The reader now maps inner Windows basenames through a
case-insensitive canonical-name table and checks case-insensitive uniqueness.
It still verifies the exact case-sensitive ZIP entry and its recorded digest.
Unsigned and signed archive fixtures passed, including alias rejection.

## DEF-018 — Draft release lookup by stable ID

**Status:** RESOLVED. **Scope:** publication; signature and payload gates unchanged.

The release-by-tag REST endpoint could not read an uploaded draft. The publisher
resolves the draft's numeric ID, validates the exact tag, ID, flags and asset
digests, and targets that same ID for publication. Fixtures cover draft-by-tag
failure and unsafe-ID rejection. The source-only CI leaves this tool inactive.

## DEF-019 — Guided uninstaller certificate prompt interpolation

**Status:** RESOLVED. **Scope:** new guided removal orchestration, not installed acceptance.

The first real orchestration fixture reached the optional certificate prompt
and strict mode interpreted the adjacent question mark as part of the variable
name. This threw after product removal and before optional trust/policy cleanup,
including unattended calls where the description was evaluated eagerly.

Delimit the variable as `${certificatePin}` before punctuation. The final
36-case uninstaller suite passes the real orchestration under strict mode,
including successful optional cleanup, attended YES/NO and unattended paths,
failure ordering, signer recovery and exit codes. The full `build.ps1 -Test`
passes. No machine removal, certificate or boot changes occurred; installed
acceptance remains DEF-010 and the VALIDATION `NOT RUN` procedure.

## DEF-020 — GUI requirements page re-entry

**Status:** RESOLVED. **Scope:** native wizard navigation, not installed acceptance.

Hiding the temporary progress page synchronously re-entered the requirements
page. Its page-change handler started another check, recursively repeated the
cycle and terminated the first safe preview. Guard page-entry checks while the
progress operation is busy. A rebuilt native preview now advances through
requirements, consent, review and completion; removal restart/failure previews
also pass. Real transactions remain unexecuted under DEF-010.

## DEF-021 — GUI result label height

**Status:** RESOLVED. **Scope:** visible result/recovery guidance.

Replacing Inno's short default completion text did not enlarge its label, so
later paragraphs were clipped. Explicitly size the wrapped label to the
remaining finish-page height, and wrap the ready summary vertically. Native
preview inspection verifies readable summaries and the complete manual-restart
instruction. Closing the restart preview returned actual process code 3010;
the error preview stayed on Retry and closed with nonzero code 2.

## DEF-022 — PowerShell-only uninstall prerequisite checks

**Status:** RESOLVED. **Scope:** recovery probe behavior, not actual installed removal.

The shared dependency status function checked VC registry/DLL state even though
removal requires only PowerShell. An unrelated VC query failure could prevent
recovery. Add an explicit PowerShell-only query and use it in the removal
bootstrap and GUI removal probe. A faulted VC-query regression now permits
PowerShell-only recovery while default setup still rejects the fault; all 36
uninstaller cases, 19 GUI worker cases, 13 dependency groups and the full test
command pass. Actual inbox PowerShell removal probe also passes without VC
inspection. Installed failure/recovery remains DEF-010.

## DEF-023 — Repeated Cargo target compilation in CI

**Status:** OPEN. **Scope:** build efficiency, not signature/release correctness.

The test/user-mode path uses the implicit native Cargo target, while packaging
uses explicit x64 MSVC. Separate fingerprints can repeat optimized compilation.

**Acceptance:** align command targets and outputs or justify the split. Verify
build/test/package checks and measure compile reuse on a fresh hosted runner.

## DEF-024 — Installer/uninstaller-only release payload

**Status:** OPEN. **Scope:** final user-download ZIP, not internal signing input.

A historical test prerelease included loose developer files alongside the two
wizards. The corrected producer uses the authenticated internal signed bundle to
project the unchanged Setup and Uninstall EXEs into a two-file ZIP. The reader
rejects missing, extra, unsigned or mismatched payloads.

**Acceptance:** verify final names, embedded licenses, hashes, signer provenance
and standalone install/removal on a clean Windows 11 x64 test host. Local
producer and archive fixtures passed. The new end-to-end signed delivery and
standalone installed acceptance are **NOT RUN**.

## DEF-025 — Reject local-only payloads in the source set

**Status:** RESOLVED. **Scope:** source hygiene, not a detected secret leak.

The 2026-11-04 cleanup found no private-payload matches among the 168 present
source files. A synthetic regression nevertheless proved that
`Test-SourceHygiene.ps1` accepted a raw `.wav` capture. Its policy also omitted
generated archives, PKCS#12 containers, environment files, per-user editor
settings, downloaded driver dependencies and installer staging paths.

**Correction:** reject these classes in the intended source set, keep PKCS#12/
PuTTY key files ignored, and exercise both ignored local records and forced
index additions. Compiler outputs and caches remain in their documented
ignored locations; deliberately sanitized fixtures need a separately reviewed
policy exception before introduction.

**Acceptance:** representative forbidden source inputs fail; ordinary source
and ignored `.local/` fixtures pass; force-added local records fail; fixture
cleanup and the full project gate pass.

**2026-11-04 closure:** the synthetic raw-audio regression fails before the
correction and all 17 repository assertions pass afterward. Forbidden source
inputs and force-added local records are rejected; ignored local fixtures pass
and cleanup completes. `build.ps1 -Test` passes formatting, warnings-denied
Clippy, all 216 Rust tests and current source/static/installer contracts.
The shared-process release tooling suite also passes. The present 168-file
source inventory contains no private/generated payload matches; complete
verification records remain private.

No actual key/audio/environment payload was introduced into project source;
all new regression data is synthetic and lives under ignored `.local/`.

## DEF-026 — Microsoft driver resource attribution

**Status:** OPEN. **Remaining gate:** fresh package verification.

The adapted driver resource retained its Microsoft source header but replaced the
pinned sample's 2013 legal copyright string with a generic MS-PL attribution.
The pinned MS-PL §3(C) requires retaining existing notices.

**Acceptance:** restore the upstream copyright notice in the driver version
resource, retain the source header and complete MS-PL text, then inspect the
resource in a fresh Release driver and verify the packaged license.
The restored upstream string and year were verified in the newly built Release
SYS version resource. Fresh full-package verification is **NOT RUN** pending
recorded source provenance.
[Pinned resource](https://raw.githubusercontent.com/microsoft/Windows-driver-samples/2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89/audio/simpleaudiosample/Source/Main/SimpleAudioSample.rc) ·
[Pinned MS-PL](https://raw.githubusercontent.com/microsoft/Windows-driver-samples/2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89/LICENSE).

## DEF-027 — Trusted module lookup during elevated setup and removal

**Status:** OPEN. **Blocks:** public binary delivery.

The GUI worker and setup helper start PowerShell with `-NoProfile`, then resolve
Windows administrative commands from the normal module search path. A read-only
unelevated check confirmed that both PowerShell hosts on the development machine
include a current-user module directory with `-NoProfile`. The same lookup gap
appears in the rc.3 GUI and rc.2 script-based deployment source. Installed and
elevated behavior is **NOT RUN**.

**Acceptance:** constrain module resolution to trusted locations before
administrative command lookup. Verify cmdlet provenance, ensure user-writable
module locations are excluded, and run setup/removal, rollback and recovery
acceptance on a disposable host. See the
[PowerShell module path reference](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath).

## DEF-028 — Public name and trademark attribution

**Status:** OPEN. **Scope:** public branding review.

WinAirPlayAudio incorporates AirPlay, which Apple lists as a registered mark.
Apple's compatibility guidelines describe referential use outside a product
name. The source license review does not settle public branding.

**Acceptance:** record the chosen public name and trademark attribution after
review, then align the repository title, README and any distribution branding.
[Apple trademark list](https://www.apple.com/legal/intellectual-property/trademark/appletmlist.html) ·
[Apple trademark guidelines](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html).
