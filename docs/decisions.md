# Architecture decisions

These stable IDs record selected policies, their rationale and supersession.
Implementation contracts live in the linked owning guides; executed evidence is
in [VALIDATION.md](../VALIDATION.md), confirmed gaps in [DEFECTS.md](DEFECTS.md),
and historical investigation details under `.local/`. A decision records intent
and constraints; it does not turn an unexecuted hardware gate into a pass.

## D-001 — Driver base

**Selected.** Adapt Microsoft `audio/simpleaudiosample` at
`2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89` into a PortCls/WaveRT render
endpoint with one internal rendered-mix loopback pin, retaining MS-PL notices.

**Why and trade-offs.** Full SysVAD carries unnecessary paths and its simulated
loopback is not an acceptance oracle. ACX from scratch lacked an equally small
suitable base in the reviewed snapshot. PortCls reduces implementation risk but
still requires real-mix, pre-volume/mute and lifetime acceptance. See
[driver design](driver-design.md).

**Reconsider if.** A production-oriented ACX virtual-render base becomes suitable,
PortCls support changes, or the real shared mix cannot be captured correctly.

## D-002 — Discovery implementation

**Selected.** Use in-process `mdns-sd` 0.20.2; never redistribute Apple Bonjour
binaries. Observe installed Bonjour diagnostically without silently selecting a
`dnssd.dll` backend before bounded adapter/parity tests exist.

**Why and trade-offs.** Reviewed Apple Windows sources did not build unchanged,
and source availability did not establish Windows binary/branding redistribution
rights. The selected Rust backend is permissively licensed and exposes scoped
addresses, but direct UDP 5353 coexistence and service-wide removal semantics
need Windows integration testing. [Lifecycle](receiver-state-machine.md) owns
observations/expiry; [compatibility](airplay-compatibility-and-licensing.md) owns
redistribution scope.

**Reconsider if.** Clear supported Bonjour redistribution/build evidence or
backend coexistence/security failures justify a different bounded adapter.

## D-003 — User-mode language

**Selected.** Use pinned Rust for service/shared/tools and WDK C++ for the driver.

**Why and trade-offs.** Native Windows bindings and the selected mDNS backend fit
Rust, while discovery/RTSP are untrusted parsing boundaries. This avoids a
managed runtime and reduces lifetime/parser risk, with a separate Rust supply
chain and possible FFI cost. C++20 throughout and a managed service were rejected.

**Reconsider if.** A required API cannot be safely bound, toolchain policy changes,
or an audited native sender makes another implementation materially safer.

## D-004 — RAOP sender dependency

**Selected.** Implement a narrow original classic sender. Use permitted references
and independent mock/hardware behavior; copy no GPL sender code and fail
explicitly on unsupported profiles.

**Why and trade-offs.** The reviewed candidates were unlicensed/GPL, embedded an
unsuitable runtime, were platform-coupled, or lacked a fail-closed standalone
Windows sender. The dated [source ledger](airplay-compatibility-and-licensing.md)
retains those findings. Original implementation costs interoperability work;
D-016/D-020 govern any future AP2 reuse.

**Reconsider if.** A maintained permissive Windows library satisfies security,
timing, retransmission and password requirements.

## D-005 — Dynamic endpoint lifetime and identity

**Selected.** Hold one default-lifetime `HSWDEVICE` per supported receiver through
online/grace states, with a stable instance token and UUID-v5 container derived
from canonical identity. `PKEY_Device_ContainerId` is authoritative for MMDevice
mapping. A projected private receiver ID is optional, but a present mismatch or
malformed value fails closed. Supply parent `DEVPKEY_Device_FriendlyName` at
creation; never match friendly text or persist opaque endpoint IDs as identity.

**Why and trade-offs.** Software-device completion is asynchronous and privileged;
handle lifetime removes presence on process termination. Non-present devnodes
still need exact uninstall cleanup and live rename/multiple-instance tests.

**Reconsider if.** Independent container mapping fails or device-manager scale
requires grouping. [Driver design](driver-design.md) and
[lifecycle](receiver-state-machine.md) own the detailed contracts.

## D-006 — Audio handoff

**Selected.** Use real producer-committed WaveRT loopback and shared event-driven
WASAPI capture into a preallocated bounded queue. No networking, allocation,
logging or codec initialization occurs in capture drain. The
[driver contract](driver-design.md#audio-path) retains committed-slot tags,
generation/conditional-commit safety, producer-only progress, polling rejection
and both protected-content gates. The [audio contract](audio-pipeline.md) owns
capture format/flags, conversion and queue behavior.

Default `IAudioClient2` properties are intentional: `AudioCategory_Media` caused
`E_INVALIDARG` in the recorded initialization matrix. Use `LOOPBACK |
EVENTCALLBACK`, the endpoint mix format and `AUDCLNT_STREAMOPTIONS_NONE`.
The driver accepts only the required pre-volume/mute tap, so a separate endpoint
control path remains necessary.

**Supersession and trade-offs.** Bounded loss avoids growing latency forever.
The original queue-pressure decision forced remote RTSP `FLUSH`; D-017 replaces
that part with first-survivor marking and local timeline recovery. Explicit
remote reset remains separate. Custom kernel transport and unbounded/direct
callback networking were rejected for reliability/attack-surface cost.

**Reconsider if.** Live capture is synthetic/incorrect or measured copies cannot
meet capture deadlines.

## D-007 — Compatibility claim

**Selected.** Admit only tested classic RAOP profiles. Aggregate security evidence
across `_raop` and companion `_airplay` records; reject AP2-only, FairPlay-only,
PIN/HAP/one-time-paired, malformed-security or unknown profiles before endpoint
creation. Advertising AirPlay metadata is not transport support.

**Why and trade-offs.** Pairing/encrypted control/media and receiver-specific
validation are distinct requirements; many Apple receivers remain unsupported.
The exact classifier contract is in [compatibility](airplay-compatibility-and-licensing.md).

**Reconsider if.** A secure AP2 sender passes its mock/security/named-hardware
matrices under D-016/D-020.

## D-008 — Password credential storage

**Selected.** Use one receiver-scoped machine-DPAPI blob beneath
`%ProgramData%\WinAirPlayAudio\credentials`, with receiver-specific entropy and
Administrators/`SYSTEM`-only access. The credential tool takes stdin and requires
the protected installed directory. Restart the service for immediate credential
reconciliation; direct-sender argv passwords remain isolated-test-only.

**Why and trade-offs.** An interactive user's vault is unavailable to the combined
service. Plain JSON and ordinary-user-readable storage are unacceptable. Local
administrators/`SYSTEM` remain inside the trust boundary; minimum service
privileges remain a release gate.

**Reconsider if.** A restricted worker/vault split or enterprise credential policy
requires another provider. [Security](security.md#credentials) owns redaction
and storage controls.

## D-009 — Active discovery refresh

**Selected.** Keep long-lived primary browsers and bounded auxiliary `_raop`/
`_airplay` pulses, default four seconds and configurable 1–60 seconds. Use one
parser/registry/event budget; age a service only after three complete successful
missed epochs. Failed epochs do not age it, and missing stop acknowledgements
retire the auxiliary daemon. Production stays on UDP 5353; custom-port unicast
fixtures prove repeated add/grace/remove without depending on multicast fan-out.

**Why and trade-offs.** Backend exponential query backoff delayed reconnects, and
Windows same-port multicast delivery was unsuitable for deterministic fixtures.
Extra queries/sockets require coexistence, sleepy-Wi-Fi, VPN and interface tests.
[Lifecycle](receiver-state-machine.md) owns the full observation/timer rules.

**Reconsider if.** A supported bounded requery API or verified single-browser
backend satisfies reconnect and removal semantics.

## D-010 — Installer commit marker and interrupted-runtime recovery

**Superseded by D-011.** The former mixed-version repair/rollback-restart policy
is historical. Verified clean reinstall now owns recovery; old implementation
and failure records remain preserved privately.

## D-011 — Verified clean reinstall

**Selected.** Authenticate a protected signed-package snapshot before mutation.
Under the shared installer mutex, validate exact ownership, remove product
services/firewall/devnodes/Driver Store/runtime/state/config/credentials/logs/
transactions, preserve only the active snapshot and prove zero installed state.
Reauthenticate the snapshot and install fresh. A failed fresh install cleans to
zero; the discarded installation is never restored or restarted. D-015's unload
gate applies before Driver Store mutation.

**Why and trade-offs.** This replaces D-010's ambiguous mixed-version repair.
Every reinstall interrupts playback and deletes wanted configuration/credentials/
logs/endpoint state, so operators must back up and recreate them. Reboot/retry
may be required. Signed archives, certificate trust and boot policy stay outside
product cleanup. [Security](security.md#installer) owns exact trust checks;
[build/install](build-and-install.md) owns commands.

**Reconsider if.** Config preservation becomes a requirement or a platform
transaction can span SCM/PnP/filesystems without reintroducing mixed recovery.

## D-012 — Classic RAOP wire and route contract

**Selected.** For the admitted `cn=0` profile, announce `L16/44100/2` and send
network-byte-order stereo PCM. Bind RTSP and all UDP sockets to the selected
DNS-SD interface/address. Mixed plaintext-capable `et=0,4` requires the type-1
`/auth-setup` preflight; this does not establish cryptographically verified
receiver identity. Setup order is required preflight, `ANNOUNCE`, `SETUP`,
`RECORD`, then volume `SET_PARAMETER`. Never issue startup `FLUSH`; genuine
explicit later flush resets state and sends immediate `0x90` sync before marked
RTP. D-017 supersedes the original 44,100-frame default with a 22,050-frame floor
and separates local loss from remote reset.

**Why and trade-offs.** SDP/payload/profile must agree; ALAC/RSA-AES/FairPlay/TCP
and AP2 are unsupported. Overlapping routes made default source selection
unsafe, and unnecessary flushes purged usable receiver buffers. Explicit binding
requires preserving scoped observations through session creation.

**Reconsider if.** Named profiles need another codec/latency contract or interface
changes require a different safe binding strategy. Detailed pacing is in
[audio pipeline](audio-pipeline.md).

## D-013 — Receiver-initiated RAOP UDP firewall rule

**Selected.** The installer owns local-persistent `WinAirPlayAudio.RaopUdpIn`:
exact installed service program, inbound UDP, Private, remote `LocalSubnet`,
negotiated ephemeral ports, enabled/Allow and blocked edge traversal. Verify
before service start and at final acceptance. Cleanup validates exact name,
local policy source and canonical program ownership, removes only that object
and proves absence. Never open inbound TCP, Public/Domain or unrelated rules.

**Why and trade-offs.** A receiver can initiate timing during `SETUP` before any
outbound UDP flow exists; ordinary reply state did not admit it. Private-network
classification, policy merge and network-profile matrices remain acceptance
requirements. [Security](security.md#firewall-and-listeners) owns the full rule.

**Reconsider if.** Safe outbound priming or a narrower supported firewall API can
scope negotiated ports to the service lifetime.

## D-014 — WaveRT real-time paths do not depend on adapter lifetime

**Selected.** Miniports/streams retain no adapter pointer and make no optional
PortCls ETW calls. Timer, notification, position and teardown use only
stream/miniport-owned state under their existing IRQL/lock contracts.

**Why and trade-offs.** A cleanup bugcheck exposed a stale optional adapter call
from a still-live `DISPATCH_LEVEL` timer. Strong adapter ownership could form a
PortCls cycle; removing unused telemetry removes the dependency. Service logs
remain available. Source/disassembly checks cannot replace active-stream PnP
removal on a recovery host.

**Reconsider if.** Required telemetry can use a separately owned non-cyclic object
with a teardown barrier and verified `DISPATCH_LEVEL` behavior.

## D-015 — Prove kernel unload before Driver Store mutation

**Selected.** After matching devnodes reach zero, wait at most 30 seconds for
kernel service `WinAirPlayAudio` to be absent or both `State=Stopped` and
`Started=false`. Otherwise stop before Driver Store deletion with reboot-required
failure. `/force` cannot bypass the gate; manual service-registry deletion is
unsupported.

**Why and trade-offs.** Command completion does not prove kernel quiescence.
Cleanup may need reboot/retry instead of mutating a potentially live package.

**Reconsider if.** A documented transaction atomically proves PnP quiescence,
module unload and package removal with stronger evidence.

## D-016 — Staged AirPlay 2 sender strategy

**Status.** Accepted implementation direction on 2026-07-28, amended by the owner's
2026-08-12 D-020 defaults. AP2 remains unimplemented/unsupported and Stage 0 open.

**Selected.** Stage user-mode native Rust work: direct single-receiver spike,
then service/store integration, then hardening. Persistent PIN pairing and
approved opt-in transient pairing are separate trust profiles. Require
fail-closed receiver proof/signature checks, encrypted control/events/media,
real-time ALAC, NTP timing, feedback, resend, flush and teardown. Import no GPL
source. Integrate only after the persistent Apple TV direct-sender gate passes;
transient Mac/HomePod paths are experimental and non-blocking under D-020.
PTP/grouping/buffered streams/broad third-party claims are separate future work.
D-020's legal-risk/distribution gates govern internal and public work.

**Why and trade-offs.** Existing capture/queues/interfaces/history/storage seams
are reusable without kernel redesign. [Dated references](airplay-compatibility-and-licensing.md#historical-ap2-source-checks)
show Windows feasibility but no compatible drop-in dependency or project AP2
hardware pass. Original/permitted protocol work, independent security review,
named firmware validation and ongoing unpublished-protocol maintenance are
substantial; transient pairing must not be described as persisted identity proof.

**Reconsider if.** The strict spike cannot sustain 60 minutes on the named
persistent Apple TV without accepting invalid proof, a selected future HomePod
tier requires PTP, legal review rejects distribution, or a maintained permissive
fail-closed Rust sender changes the economics.

The [specification](airplay2-single-receiver-spec.md) owns the normative contract;
the [Stage 0–3 plan](airplay2-stage-0-3-plan.md) owns execution. Its Stage 0 freeze
precedes direct sender/integration/hardening Stages 1/2/3, with possible
separately authorized PTP/multi-room Stage 4. Exact hardware/firmware, objective
audio oracle and recovery-host availability remain deliberately deferred.

## D-017 — Capture-time pacing and local discontinuity recovery

**Selected.** Default to 22,050 frames/500 ms sender sync offset, configurable
`raop_sync_latency_ms=250..3000`; a valid larger RECORD `Audio-Latency` raises the
floor. Anchor pacing/sync to WASAPI QPC capture time, send bounded startup
catch-up and discard audio older than its effective budget. Eviction marks the
first survivor and coalesces losses. Local discontinuity clears the partial
packet, marks next RTP and emits immediate capture-time `0x90` sync without
remote `FLUSH`; reserve explicit flush for a genuine remote reset. This replaces
D-006's flush-on-local-loss policy and D-012's old latency default.

**Why and trade-offs.** Pacing from post-handshake send retained setup backlog;
delayed markers/remote purge magnified capture loss. A 500 ms sync offset is not
speaker latency. Dropping already-stale startup audio can clip a delayed start
but prevents unbounded lag. Physical/audible/soak acceptance and adaptive clock
correction remain open; detailed flags/timeline rules are in
[audio pipeline](audio-pipeline.md).

**Reconsider if.** Named receivers require a larger floor, hardware rejects this
latency, prewarming can avoid clipping without reserving an idle receiver, or
adaptive clock correction provides a stronger continuous timeline.

## D-018 — One guarded local test-deployment entry point

**Selected.** The root CMD launcher invokes the thin PowerShell coordinator for
explicit elevation, already-active TESTSIGNING, unambiguous dedicated-certificate
selection, one encompassing destructive confirmation, selected-configuration
workspace testing, packaging and protected sign/install value passing. Existing
build/signer/installer scripts exclusively own implementation and postconditions.
No separate integration stage repeats tests already in the workspace gate.

**Security and trade-offs.** Never create trust, change boot/Secure Boot/network
policy, reboot or bypass ownership/unload/signature checks. Zero/multiple
certificate candidates fail auto-selection. Fresh local manifest hashes are
valid only within the trusted invocation; transported input still requires
independent-channel hashes. Initial setup/reboot and destructive data loss
remain explicit. Building in the elevated console is less isolated; a future
least-privilege build-to-signer handoff must preserve authentication.

**Reconsider if.** Remote signing, a supported authenticated ordinary-user build
handoff, or a stronger Windows replacement transaction becomes available.

## D-019 — Transactional RTP backpressure within the playout deadline

**Selected.** Retain capture-time startup and nonblocking sockets. Packetize a
clone; retry the identical datagram at one-millisecond intervals for `WouldBlock`,
`Interrupted` or transient `TimedOut`, servicing timing/resends between attempts.
The lesser of I/O timeout and remaining media-timestamp-plus-receiver-latency
budget bounds the send. Commit packetizer/statistics/pacing/history once only
after a full datagram. Partial sends or terminal/expired failure abort without
`finish_audio`; normal idle/cancellation remains graceful.

**Why and trade-offs.** WLAN exposed immediate local send-queue backpressure that
Ethernet masked. Larger buffers are tuning, not correctness; re-packetizing or
ignoring loss corrupts transactional state. Discarding all setup capture was
rejected because it clips program startup and restores unwanted delay. Bounded
waits retain useful audio but must remain responsive to receiver control.
Current-source installed WLAN acceptance remains open.

**Reconsider if.** Playout budgets still fail, receivers need a delivery safety
margin, or an asynchronous worker preserves the same transaction/latency bounds
with better cancellation. [Audio pipeline](audio-pipeline.md) owns the contract.

## D-020 — AirPlay 2 Stage 0 product defaults

**Status.** Accepted by the owner on 2026-08-12. AirPlay 2 remains unimplemented
and unsupported; accepting these defaults does not complete Stage 0.

**Problem.** Freeze the product, trust, identity, privilege, pairing, network,
and distribution defaults required to turn D-016 into an executable Stage 0–3
plan without silently resolving evidence or hardware questions.

**Selected.** O-01 through O-15 are accepted exactly as follows:

| ID | Accepted default |
|---|---|
| O-01 | Persistent-paired Apple TV is the initial release profile; transient Mac/HomePod paths remain experimental. |
| O-02 | Transient admission is explicit opt-in, creates no normal automatic endpoint, and is never fallback from failed pair-verify. |
| O-03 | Named hardware/firmware must be recorded before repeated pair/unpair/forget/re-pair/reboot/soak work. |
| O-04 | Objective audio capture/correlation is required; audible observation is supplemental. |
| O-05 | Endpoint volume/mute applies exactly once outside capture callback, using local per-stream gain unless hardware evidence selects protocol volume. |
| O-06 | Receiver-to-Windows volume is deferred until authenticated event/read-back behavior is proven. |
| O-07 | Use an honest neutral WinAirPlayAudio identity; stop if Apple impersonation is required. |
| O-08 | Preview admission uses an exact model/firmware allowlist. |
| O-09 | The AP2 network/pairing/crypto worker never ships as `LocalSystem`; split a minimal endpoint broker if necessary. |
| O-10 | Prototype reinstall lists affected pairings, requires explicit loss confirmation, and uses remote unpair where possible; preservation needs authenticated migration. |
| O-11 | Configure one AP2 receiver ID, create one AP2 endpoint, and allow one active AP2 session; classic endpoints are unaffected. |
| O-12 | Internal work requires documented legal-risk disposition; public distribution/branding waits for legal/MFi clearance. |
| O-13 | IPv4 is first; IPv6 requires exact-size/PMTU and named hardware evidence. |
| O-14 | Generate a distinct controller ID/key for each persistent receiver. |
| O-15 | The elevated one-shot pairing CLI stops the service, discovers/pairs/verifies/writes/read-backs, then restarts it; no initial pairing IPC. |

**D-016 amendment.** The former Apple TV plus Mac pre-integration gate is
replaced by the persistent Apple TV direct-sender gate. Transient Mac/HomePod
work is experimental and non-blocking unless a later decision changes it.

**Deferred inputs.** At the owner's request, the exact available hardware and
firmware, objective audio oracle, and recovery-ready Windows host are not being
considered yet. They must not be inferred from prior observations. S0.5 and the
related Stage 0 exit conditions remain open, and no pairing, installation,
destructive mutation, or hardware test is authorized by this decision.

**Trade-offs.** The narrow defaults reduce security and compatibility ambiguity
but intentionally exclude transient receivers from the initial release claim,
limit AP2 to one configured receiver and IPv4 first, require re-pairing around
prototype reinstall, and retain substantial privilege, legal, hardware, and
evidence work before release.

**Reconsider if.** Named hardware evidence invalidates the persistent Apple TV
profile, a lawful maintained fail-closed dependency changes the implementation
economics, the restricted-worker design is infeasible, or legal/MFi review
rejects the intended distribution.

## D-021 — Private evidence and public repository boundaries

**Selected 2026-10-31.** Keep private diagnostics, notes, machine records and
sensitive inputs under ignored `.local/`; retain installed state at protected
Windows locations. Public docs contain reusable guidance and sanitized evidence.
Preserve size/SHA-256-verified originals before reorganizing records. Ignoring or
removing present files does not remove history or authorize publication/history
rewriting. [Local artifacts](local-artifacts.md) owns layout and preservation.

**Source-only handoff.** Use a fresh repository initialized outside the
original development tree. Preserve original diagnostic and signing records
privately. Remove personal metadata and private downloads from the public
candidate. Run ordinary build and test CI without binary uploads.

## D-022 — Canonical versions and draft developer delivery

**Selected 2026-10-31.** `version.json` owns SemVer and driver revision/date, with
checked Cargo/lockfile/INF/project/resource copies. Advance identities without
inventing releases or downgrading. Remap compile/PDB paths; emit portable dependency
metadata and exact hashes. Keep binary-package source/dirty provenance separate
from assembly provenance; dirty previews cannot claim clean released provenance.

D-024 supersedes the original unsigned draft-only tag delivery; D-030 owns the
final public layout. Unsigned developer previews remain explicit signing input.
The [release guide](releasing.md) owns commands. Independent-root comparison and
installed/hardware/privilege/legal/production acceptance remain separate gates.

## D-023 — Remove redundant scaffolding and keep one procedural owner

**Selected.** Remove code only after checking consumers, registrations and build
targets; retain dynamic/ABI surfaces and independent trust-boundary validation.
`ServiceConfig` owns service settings, the preallocated WASAPI queue owns capture
handoff, and Cargo discovers conventional targets. Package producers use the
Common.ps1 filename contract; incoming/runtime validators authenticate their own
boundaries. Do not restore unconsumed scaffolding or placeholder success.

Full workspace tests include process cases; combined flags, CI and the deployment
launcher do not repeat them. The standalone integration action targets real tool/
service cases. Version.ps1 owns mutable version checks. Read-only planning may run
on Server build hosts; actual deployment retains supported-OS/elevation gates.
Current guides own procedures, ADRs rationale and DEFECTS/VALIDATION gaps/evidence.
Preserve accepted AP2 requirements and D-020's frozen owner record. See DEF-013/014.

## D-024 — Historical test-signed prerelease workflow

The isolated release tooling authenticates inputs, verifies signatures and
catalog membership, and checks cleanup before handoff. Source-only CI retains
these fixture checks and leaves the tag-triggered signing and publication path
inactive. Any later binary workflow requires review under the
[release guide](releasing.md).

## D-025 — Reuse build outputs within each CI configuration

**Selected 2026-11-04.** Each Debug/Release job runs format/Clippy/tests/user-mode
builds and its matching native driver build; Release then packages through the
authoritative script. This avoids a second cold driver/package runner without
cross-job binary caches or relaxing signing/source/policy/archive checks.

**Limit.** CI uses different implicit/explicit Cargo targets,
causing another optimized compilation. DEF-023 owns target alignment and fresh
compile-reuse evidence. Shared-runner success alone does not prove compile reuse;
[VALIDATION.md](../VALIDATION.md) records executed jobs.

## D-026 — Guided setup for prebuilt test-signed bundles

**Selected 2026-11-04.** Inbox native x64 Windows PowerShell validates independent
manifest/signer identities and requests elevation. Provision missing PowerShell
and VC++ x64 runtimes from protected copies: require the exact official PowerShell
MSI hash, valid Microsoft signatures, VC product/version identity and installed
x64 postconditions. Offline inputs use identical checks; retain shared runtimes.

Gate installation on the running kernel's Code Integrity TESTSIGN flag. Explicit
boot/recovery acknowledgements may prepare test mode, then return 3010 for manual
reboot/rerun before trust/driver work. Never change Secure Boot/HVCI, schedule
elevated resume or reboot automatically. Missing unattended acknowledgements fail.

Trust only the independently pinned public DER and use the clean-slate signed
package/service/firewall transaction. Revalidate protected code/payload copies;
on failure attempt cleanup of every newly added trust store, preserve preexisting
trust and retain shared boot/runtime settings for recovery. An authenticated bundle
anchors script trust and its independent manifest pin anchors payload integrity.
D-028 supersedes the console-only interface; the guarded backend remains shared.
Installed/clean-host acceptance remains DEF-007/010.

## D-027 — Guided removal with optional test-mode exit

**Selected 2026-11-04.** Reuse ownership-validated removal and absence checks for
service, firewall, devices, Driver Store, runtime, config/credentials/logs and tool
caches. Hold setup/installer locks across removal and optional policy cleanup.
Recovery must tolerate damaged/absent incoming packages and partial installations.

Capture the dedicated signer from protected validated install state before its
removal, or use the authenticated launcher's pin when state is absent. Malformed,
mismatched or split identities cannot authorize automatic trust deletion. Public-
trust removal is explicit; preserve private keys and shared Microsoft runtimes.

Only verified product absence permits optional TESTSIGNING-off. Default to retaining
boot policy; require other-driver, boot-change and recovery acknowledgements, then
return 3010 for manual restart. Set off when requested even if the current kernel
is normal: a pending BCD change may enable test mode later. Missing/conflicting
unattended options fail closed. Never reboot or change firmware/HVCI automatically.
Installed removal/reboot/failure acceptance remains DEF-010.

## D-028 — Native Inno Setup GUI wrappers

**Selected 2026-11-04.** Replace D-026's console-only interface with two native
x64 Inno Setup 7.1.1 wizards. The tested PowerShell backend remains the sole owner
of dependency/device/service/firewall/trust/boot changes. Show requirements,
explicit approvals, hidden-worker progress and distinct success/restart/error
results. Disable cancellation only during a backend transaction. Prerequisite
3010 must never report completed driver installation.

Use wrappers without automatic file installation, Apps & Features registration
or a maintenance runtime. The companion uninstaller embeds recovery scripts and
stays outside the removed product runtime. Silent GUI mode is rejected in favor
of explicit CLI automation. No automatic reboot or Secure Boot/HVCI change.

Verify the pinned portable compiler distribution, publisher and engine. Bind real
builds to trusted payload/signer/version identities; hold read locks, reserve output
and reject overwrite/concurrency. Keep portable metadata and distinguish unsigned
direct developer EXEs from D-029's signed releases. Compile-time previews exclude
real payload/worker execution and elevation, simulating 0/1/3010 for safe UI QA.
Installed, DPI/theme, hardware and production gates remain independently open.

## D-029 — Sign GUI wrappers in the protected tag release

**Selected 2026-11-04.** Prepare the pinned compiler before signing secrets are
available. In the isolated tag-only signing job, authenticate/sign the package,
compile from those protected bytes, sign/verify both outer GUI EXEs, and record
portable final hashes/signer/source/payload anchors. Require the GUI pair and
inventory in the authenticated internal bundle. Ordinary branch/PR jobs have no keys.

Clean private keys, temporary trust/PFX and protected scratch before upload,
including failure paths. Use immutable source-only tags and only the deliberately
exported public DER checked against its pin. Signing does not install drivers,
change boot policy or prove clean-host/production acceptance. D-030 supersedes
this decision's original broad ZIP layout. The public-source workflow leaves
signing and publication inactive.

## D-030 — Final release ZIP contains only the GUI pair

**Selected 2026-11-04.** The final user ZIP contains exactly the versioned Setup
and Uninstall EXEs. This supersedes D-029's broad public developer bundle. Setup
embeds its signed package, licenses, scripts and public DER; Uninstall embeds its
own recovery scripts. Keep complete source/package/signing inventories internal;
release notes and checksum metadata may remain outside the ZIP.

Authenticate the full internal bundle, locked original ZIP preimages and actual
GUI signatures/resources before projecting unchanged bytes. Verify the delivered
output; the publisher enforces the exact pair and trusted signing-job hash. Keep
normal/failure cleanup, version/privacy and source/signer binding intact. Ordinary
CI covers malformed inputs and cleanup without signing secrets. DEF-024 owns
delivery acceptance, DEF-010 standalone clean-host operation, and VALIDATION
executed evidence.

## D-031 — Keep active guidance separate from local chronology

**Selected 2026-11-04.** Preserve verified originals before consolidating documents.
Keep active contracts, stable decision/defect IDs, accepted AP2 defaults, concise
executed evidence and every unresolved acceptance procedure public. Keep raw logs,
local inventories and superseded development chronology under ignored `.local/`.

Guides own procedures, decisions own rationale, DEFECTS owns gaps and VALIDATION
owns evidence. Consolidation does not close defects, discard evidence, resume AP2,
rewrite history or publish releases. [Local artifacts](local-artifacts.md) owns the
bounded-path/hash verification procedure; DEF-008/013 retain relevant acceptance.

The root README owns user-facing scope and getting started. The docs index
routes technical guidance and status records. Keep local screenshots and
machine identifiers in private development records.

## D-032 — AGPLv3 for original code, retained component licenses

**Selected 2026-11-04.** License original WinAirPlayAudio code, scripts and
documentation outside the driver component under GNU AGPL version 3 only
(`AGPL-3.0-only`). Keep the complete unmodified GNU license at the repository
root and declare the same SPDX identifier for all three Rust workspace crates.
Scope cargo-deny exceptions to those crates; third-party dependency policy is
unchanged.

Keep the driver component, including project adaptations, under MS-PL. Retain
Microsoft copyright headers, upstream dependency license texts and Inno Setup
notices. The project license does not replace component licenses. The driver
and user-mode binaries remain separate build outputs communicating through
Windows APIs; this decision does not assert blanket license compatibility.

Both GUI wizards embed/display the project license; existing packages retain
the MS-PL and Rust dependency notice handoff. Earlier releases keep their
supplied licenses. Before an AGPL binary release, verify exact Corresponding
Source delivery and recipient access under the
[release procedure](releasing.md#license-and-corresponding-source-handoff).
DEF-007 owns that unexecuted release acceptance; VALIDATION records source,
policy and build evidence without claiming installation or publication.
