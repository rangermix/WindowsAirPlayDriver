# AirPlay 2 implementation plan — Stages 0–3

Status: **Accepted direction — O-01 through O-15 accepted on 2026-08-12**  
Plan date: 2026-08-12  
Implementation status: **not started**

This plan turns the feasibility decision into gated work for a defensible
single-receiver implementation. The normative contract is
[`airplay2-single-receiver-spec.md`](airplay2-single-receiver-spec.md). The
dated research inputs are retained in
[compatibility and source references](airplay-compatibility-and-licensing.md#historical-ap2-source-checks).
This plan owns the stage numbering and schedule.

Stages 0–3 do not authorize PTP or multi-room work.

## 1. Outcome and schedule

The target is a release-candidate-quality, single-active-receiver AirPlay 2
profile on Windows 11 x64 24H2 or newer. AirPlay 2 work remains user mode; the
WaveRT driver and capture contract remain unchanged.

For one engineer familiar with the repository, the current planning range is:

| Stage | Estimate | Cumulative engineering time |
|---|---:|---:|
| 0. Contract freeze | 3–5 engineer-days | 3–5 days |
| 1. Direct sender | 4–6 engineer-weeks | about 5–7 weeks |
| 2. Product integration | 5–8 engineer-weeks | about 10–15 weeks |
| 3. Release hardening | 4–8 engineer-weeks | about 14–23 weeks |

Legal/MFi response time, hardware procurement, independent security review,
production signing, and scheduling on a recovery-capable test host are outside
the engineering estimate. Stages may finish faster where work streams are
parallelized, but no gate may be skipped.

## 2. Dependency graph

```text
Stage 0: owner decisions + frozen invariants/provisional profile + limits/deps
    |                       |                       |
    v                       v                       v
pairing/crypto/parsers   ALAC/media/timing      independent mock
    \                       |                       /
     +---------------- Stage 1 AP2 session --------+
                            |
                    direct hardware gate
                            |
       +--------------------+--------------------+
       v                    v                    v
 capability/admission   pairing store/CLI   session abstraction
       \                    |                    /
        +------------- Stage 2 integration ------+
                            |
                    installed-service gate
                            |
       +--------------------+--------------------+
       v                    v                    v
 fuzz/security       restricted privilege   hardware/network/soak
       \                    |                    /
        +-------------- Stage 3 release gate ----+
```

Pairing/crypto and media/timing can proceed in parallel after Stage 0. The mock
receiver must be implemented independently enough to detect sender mistakes,
not merely reuse sender parsers and report self-consistency.

## 3. Rules that apply to every stage

Every stage must:

- keep all network, codec, cryptographic, discovery, and remote-timing work out
  of `driver/`;
- preserve classic RAOP behavior and re-run its affected regression suite;
- use bounded queues, explicit ownership/cancellation, finite deadlines, and
  orderly joins;
- add negative/error-path tests with every new parser or state transition;
- run the affected authoritative `build.ps1` commands;
- run `cargo fmt --all -- --check` and warnings-denied Clippy through the
  authoritative build/test path;
- update `PROGRESS.md`, `VALIDATION.md`, and `docs/decisions.md` whenever status,
  evidence, or a significant decision changes;
- update the security, risk, compatibility, testing, limitations, packaging,
  and release documents when their truth changes; and
- record unavailable hardware, privileged, signing, legal, soak, Windows 10,
  ARM64, PTP, and multi-room checks as **NOT RUN**, with an exact future command
  or procedure.

Mock success does not satisfy hardware playback. Direct-sender success does not
satisfy installed-service integration. A pass from another revision or
firmware does not carry forward across material crypto, protocol, installer, or
packaging changes.

## 4. Decision register

The owner accepted all defaults on 2026-08-12; D-020 records them. Acceptance
fixes product direction but does not complete Stage 0 or satisfy its evidence,
dependency, legal, hardware, oracle, or threshold gates.

| ID | Decision | Accepted default |
|---|---|---|
| O-01 | Initial release receiver/trust profile | Persistent-paired Apple TV only; Mac/HomePod transient paths stay experimental |
| O-02 | Transient receiver admission | Explicit opt-in; no normal auto-endpoint and no fallback from failed pair-verify |
| O-03 | Exact test hardware | Record every available model/firmware and authorize repeated pair/unpair/forget/re-pair/reboot/soak |
| O-04 | Audio correctness oracle | Objective capture/correlation required; audible observation is supplemental |
| O-05 | Endpoint volume/mute | Apply exactly once outside capture callback; local per-stream gain unless hardware evidence selects protocol volume |
| O-06 | Receiver-to-Windows volume | Defer until authenticated event/read-back behavior is proven |
| O-07 | Sender identity | Honest neutral WinAirPlayAudio identity; stop if Apple impersonation is required |
| O-08 | Preview firmware policy | Exact model/firmware allowlist through preview |
| O-09 | Stage 3 privilege | AP2 network/pairing/crypto worker never ships as `LocalSystem`; split a minimal endpoint broker if necessary |
| O-10 | Pairing data across reinstall | Prototype reinstall requires listed-record warning/explicit loss confirmation and remote unpair where possible; preservation needs authenticated migration |
| O-11 | Enforceable single-receiver rule | One configured AP2 receiver ID, one AP2 endpoint, and one active AP2 session; classic endpoints unaffected |
| O-12 | Distribution/legal risk | Internal work only after documented legal-risk disposition; public distribution/branding waits for legal/MFi clearance |
| O-13 | Address-family claim | IPv4 first; IPv6 only after exact-size/PMTU and named hardware evidence |
| O-14 | Controller identity scope | Distinct controller ID/key per persistent receiver |
| O-15 | Pairing authority/reconciliation | Elevated one-shot CLI stops service, discovers/pairs/verifies/writes/read-backs, then restarts service; no initial pairing IPC |

O-01 amends D-016's former Apple TV plus Mac pre-integration gate: the
persistent Apple TV path is the product gate, while transient Mac/HomePod work
is experimental and non-blocking. Owner approval is a product authorization,
not a legal determination.

Deferred at the owner's request and not to be considered yet: exact available
hardware/firmware and scheduling, the objective audio oracle, and availability
of a recovery-ready Windows test host. These keep S0.5 and the associated Stage
0 exit conditions open. They must not be inferred from prior discovery or test
history, and no pairing, install, destructive mutation, or hardware test is
authorized by accepting O-01 through O-15 alone.

Stage 0 must also set measurable release thresholds for end-to-end latency,
CPU, working set and growth, queue high-water, clock drift, reconnect time, and
audio correctness. This plan does not invent those thresholds without a valid
hardware oracle and product target.

## 5. Stage 0 — Freeze scope, trust, and contracts

**Goal:** remove security-critical ambiguity before protocol code or pairing
credentials are introduced.

**Estimate:** 3–5 engineer-days, excluding legal response time and hardware
procurement.

### S0.1 Product and trust profile

Owner: project owner + implementer. Depends on: none.

- Apply the accepted O-01 through O-15 decisions to all Stage 0 artifacts.
- Freeze the first named receiver/model/firmware rows and which rows are
  release-supported versus experimental.
- Freeze the two trust profiles, downgrade prohibition, quarantine behavior,
  pairing UX, unpair/forget semantics, and honest sender identity.
- Define exactly when a recognized AP2 receiver is discoverable, pairable,
  endpoint-eligible, experimental, or withheld.
- Record any changed decisions, risks, and user-facing claim language.

Deliverables:

- accepted `docs/airplay2-single-receiver-spec.md`;
- owner-decision entries in `docs/decisions.md`;
- initial named profile rows in the compatibility document; and
- updated `docs/risk-register.md` and `docs/security.md`.

### S0.2 Provisional wire profile and invariant table

Owner: protocol implementer + reviewer. Depends on: S0.1.

- Freeze the cryptographic transcripts, M4/M6/M2 authentication gates,
  derivation labels, nonce/counter rules, media format, and other invariants that
  have independent attributable evidence.
- Record one provisional exact state-by-state sequence for persistent pairing,
  pair-verify, approved transient pairing, encrypted control, event setup,
  session/stream setup, profile-optional `RECORD`, timing, feedback, type-
  `0x55`/`0xD6` resend, flush, volume, and teardown.
- Record request method/path, accepted status/content type, body schema,
  encryption state, key/counter owner, timeout, retry rule, and cleanup for each
  transition.
- Classify every row as `invariant`, `provisional named-profile behavior`, or
  `Stage 1 hardware confirmation`. A Stage 1 divergence stops the sender and
  reopens the row for review; the implementation must not try several orders or
  weaken authentication until one works.
- Attribute every constant/behavior to a permissive reference, public research,
  or sanitized oracle trace. An external oracle capture may be authorized only
  as a bounded Stage 0/1 evidence action after O-03/O-12; fail-open reference
  code can establish message shape but never a security guarantee.
- Define legal final-partial-frame and discontinuity behavior.

Deliverable: provisional `docs/airplay2-wire-profile.md`, created during Stage
0 and promoted to hardware-confirmed only at the Stage 1 gate. It must contain
no PIN, private key, session key, reusable controller identity, or raw
unredacted authorization transcript.

### S0.3 Parser and resource limits

Owner: security reviewer + implementer. Depends on: S0.2.

Freeze constants for:

- TLV total/value/count/duplicate limits;
- binary-plist bytes/depth/object/string/data/collection limits;
- RTSP line/header/count/total/body limits;
- DNS name/compression-loop, record/address/TXT count, aggregate response/TXT,
  TTL/cache, duplicate-key, and interface-churn limits;
- encrypted record, event, feedback, timing, and retransmit limits;
- outstanding requests, sockets, workers, queued events, queued PCM,
  retransmission history, reconnect count, and total session memory; and
- read, write, connect, handshake-step, playout, feedback, teardown, and whole-
  session deadlines.

Every limit must have a normal-boundary and one-over-limit test case. Limits
that affect security or wire compatibility are constants, not user-widenable
configuration.

### S0.4 Dependency, provenance, and legal review

Owner: implementer + license/security reviewer. Depends on: S0.2.

- Evaluate exact Rust crates for SRP-6a, Ed25519, X25519, HKDF-SHA512,
  ChaCha20-Poly1305, binary plist, secure console input, zeroization, and any
  validation-only ALAC decoder.
- Record license, repository/revision, maintenance state, MSVC support, unsafe
  code, transitive tree, advisory state, test vectors, and reason for selection.
- Pin exact compatible versions in `Cargo.lock` only when implementation starts.
- Record the reviewed upstream states rather than consuming mutable branches:
  canonical C++ `8c4034263f1c265d25b3cfb88a090624760ad22a` builds only
  crypto and keeps a Qt/host-coupled sender; PR
  `d4fd7163c87dd04ffd94bdd58f4ff6b270d5e5c8` is open with
  `CHANGES_REQUESTED` and only a generic transport loopback; Rust fork
  `a43e1220dbae7a9080f52027fc59fe04bb3e4bbd` is unmerged, references a
  missing CLI crate, and has no Windows transport/mDNS or hardware evidence.
- No branch is a live dependency. Vendor only reviewed files at exact SHAs with
  file-level origin/modification records where reuse is approved.
- GPL implementations must not be copied, translated, linked, or used as a
  line-by-line/design source. Segregated black-box oracle use requires a
  documented legal disposition. An Apache header does not resolve third-party
  provenance; the ALAC writer provenance in particular requires review.
- Preserve upstream Apache `LICENSE`/`NOTICE`, MIT/zlib notices, and modification
  markings for every reused file.
- Open legal/MFi review for the exact internal/public distribution and naming
  plan. Source-license acceptance is not Apple protocol/trademark/MFi approval.
- Record neutral sender fields and stop if a target requires undocumented Apple
  identity impersonation.

Deliverables: dependency/provenance ledger, proposed notices/SBOM changes, and
legal/MFi gate status. Internal Stage 1 work requires O-12 plus a documented
jurisdiction-appropriate legal-risk disposition; owner approval itself is not
legal clearance. Public distribution, branding, protocol-rights, MFi,
trademark, and patent questions remain Stage 3 blockers until resolved.

### S0.5 Hardware, network, and evidence runbook

Owner: implementer + hardware owner. Depends on: S0.1–S0.3.

- Identify the exact Apple TV, Mac, and any HomePod model/firmware available.
- Define an objective audio oracle, such as HDMI/analogue capture or a trusted
  receiver-side loopback. The currently invalid Line In control path cannot be
  reused as evidence.
- Define repeated pairing, bad PIN, stored reconnect, identity change, receiver
  reboot, sender restart, firewall denial, IPv4, conditional IPv6, MTU, packet loss,
  sleep/wake, interface change, volume/mute, cleanup, and soak procedures.
- Require a physical or correctly bridged same-LAN Windows host; VM NAT or
  generic socket loopback is not an AirPlay 2 result.
- Define evidence metadata: repository revision, package/hash where applicable,
  Windows build, receiver model/firmware, interface/address family, MTU,
  sanitized transcript hash, command, duration, result, and artifact hash.
- Define secret scanning/redaction before any capture or log is retained.

Deliverables: Stage 1/2/3 hardware matrix and exact future procedures for every
item that remains **NOT RUN**.

### S0.6 Baseline and implementation seams

Owner: implementer. Baseline depends on: S0.1. Seam freeze depends on:
S0.2–S0.4.

- Run the unchanged classic user-mode/test baseline on the revision from which
  implementation will branch.
- Freeze the proposed `shared::ap2` module boundary, AP2 session API, typed
  receiver profile, mock boundary, pairing-record schema, and service protocol
  dispatch seam.
- Freeze a distinct current-user-DPAPI, test-only Stage 1 pairing store so
  sender-process restart can prove pair-verify. It uses the production bounded
  schema but a separate purpose/directory, is never packaged, and is never
  implicitly migrated; Stage 2 re-pairs under the final machine/service store
  unless an authenticated migration is separately approved.
- Confirm spike and mock executables are excluded from package manifests.

Baseline commands:

```powershell
.\build.ps1 -Test
.\build.ps1 -Configuration Debug -UserModeOnly
.\build.ps1 -Configuration Release -UserModeOnly
git diff --check
```

### Stage 0 exit gate

Stage 0 passes only when:

- O-01 through O-15 and the release thresholds are resolved;
- no security-critical trust, key, counter, transcript, credential, privilege,
  volume, or parsing behavior is left to implementation guesswork;
- exact Stage 1 hardware and an objective audio oracle are available;
- every untrusted input and worker/queue has a bound and an owner;
- selected dependencies are permissively licensed, pinned in the plan, and
  verified buildable on the supported MSVC/Rust toolchain;
- the classic baseline passes on the implementation revision; and
- a documented legal-risk disposition authorizes the internal prototype without
  presenting owner approval as a legal determination.

Stop if the only working design requires invalid authentication, GPL linkage or
copying, Apple keys/certificates/impersonation, FairPlay material, PTP for the
selected first target, or an unbounded parser/state path.

## 6. Stage 1 — Secure direct native-Rust sender

**Goal:** prove the complete narrow protocol against an independent mock and a
named physical receiver before the service can admit AP2 endpoints.

**Estimate:** 4–6 engineer-weeks.

The Stage 1 tools are developer-only and excluded from installer/package
manifests. AP2 remains disabled in service classification and endpoint creation.

### S1.0 Bounded wire-oracle confirmation

Depends on: S0.2, O-03, and O-12. May run in parallel with pure parser/ALAC
work.

- Confirm only the wire-profile rows marked `Stage 1 hardware confirmation`
  using a trusted independent sender capture or a disposable, exact-SHA harness
  whose receiver mutations were explicitly authorized.
- Record exact model/firmware, route, packet sizes, ordering, optional `RECORD`,
  feedback/resend wrapper, and event behavior with secret-safe transcript
  hashes.
- Treat fail-open reference behavior as message-shape evidence only. It cannot
  establish authentication, identity, or release safety.
- Promote or reopen each provisional row before the dependent session
  transition is implemented. Do not probe a receiver by trying multiple orders
  in production code.

### S1.1 Module and public types

Add an isolated module structure such as:

```text
shared/src/ap2.rs
shared/src/ap2/limits.rs
shared/src/ap2/tlv8.rs
shared/src/ap2/plist.rs
shared/src/ap2/crypto.rs
shared/src/ap2/pairing.rs
shared/src/ap2/framing.rs
shared/src/ap2/alac.rs
shared/src/ap2/rtp.rs
shared/src/ap2/timing.rs
shared/src/ap2/event.rs
shared/src/ap2/session.rs
```

Define typed receiver profile, pairing mode/trust result, pairing record,
session state, statistics, and terminal/retryable error classification. The
pure record type belongs in `shared`; production Windows persistence belongs in
`service`, while the direct tool owns the distinct test-only store.

### S1.2 Pairing, cryptography, and bounded parsers

Implement in dependency order:

1. bounded TLV8, binary plist, RTSP, and encrypted-record parsers;
2. secret-bearing types, CSPRNG generation, and zeroization;
3. persistent SRP pair-setup with mandatory M4 server-proof verification and
   exact M6 state/error/TLV, accessory-ID/LTPK, and signature validation;
4. X25519/Ed25519 pair-verify with exact M2 state/error/TLV, pinned accessory-ID
   equality, ephemeral transcript, and signature validation before M3;
5. approved transient pairing as a distinct weaker trust result;
6. independent encrypted control and event directions/counters; and
7. known-answer and negative vectors for every key label, proof, signature,
   identity binding, tag, length, counter, and state transition.

No missing or invalid authentication value may become a warning. A failed
persistent verify must not select transient or classic behavior.

### S1.3 Media, timing, feedback, and resend

- Implement the frozen 44.1 kHz/16-bit/stereo, 352-frame uncompressed ALAC
  profile with golden and decode-back vectors.
- Reuse the existing normalized PCM/capture-time model; do not adopt an upstream
  linear resampler or cross-thread ring buffer.
- Implement encrypted RTP with exact wire-size assertions.
- Store bounded, immutable final ciphertext/datagrams and playout deadlines.
- Reserve and irrevocably consume a nonce before encrypted bytes reach I/O.
  `WouldBlock` retries only the same immutable bytes; partial/terminal/deadline
  paths never roll back the nonce and close/rekey unless the frozen explicit-
  nonce loss rule permits a burned value.
- Cache the complete protected RTP datagram. For the frozen type-`0x55`
  request, emit the validated four-byte type-`0xD6` wrapper plus the cached
  inner datagram byte-for-byte; never re-encrypt it.
- Implement NTP timing/sync, receiver latency, bounded feedback, retransmission,
  explicit remote flush, local discontinuity recovery, and teardown.
- Assert the reference original/resend UDP payloads of 1,448/1,452 bytes or the
  independently frozen replacements. Prove IPv4 do-not-fragment behavior and
  `WSAEMSGSIZE` handling. IPv6 remains conditional: both the 1,496-byte
  original and 1,500-byte resend IP packets must fit the measured PMTU without
  fragmentation or extension-header overflow.

Pure ALAC encoding and basic timestamp math can run in parallel with S1.2 after
Stage 0. Encrypted media, nonce ownership, and protected resend depend on the
S1.2 crypto/framing core.

### S1.4 Explicit state machine and ownership

Depends on: S1.0–S1.3 for the applicable profile. Implement the states and
transitions from the specification. Control, event,
media, timing, and feedback activity must have explicit socket/key/counter/task
owners. Cancellation closes sockets and joins all workers before secrets and
session state are destroyed. Disconnect/fault injection must exist at every
handshake and stream state.

### S1.5 Direct sender and independent mock

Add developer-only binaries, for example:

```text
tools/src/bin/ap2-send-spike.rs
tools/src/bin/mock-ap2-receiver.rs
```

This package also adds the distinct current-user-DPAPI test store frozen in
S0.6. It must persist the candidate record across process restart, use a test-
only purpose/directory, provide explicit verified cleanup, and never migrate
into the machine/service store. It exercises the same recovery-only journal
states and crash boundaries planned for the production transaction.

The direct tool must select the exact discovery observation/interface, display
model/firmware/trust, prompt for PIN without echo, support reconnect using the
Stage 1 protected record, send a deterministic tone/WAV, set volume/mute, flush,
and tear down. It commits the record only after M6 and a fresh pair-verify,
generates the O-14 controller identity scope, and has no `--pin` or key argument.

The mock must independently act as an accessory and decrypt/decode/assert the
complete session. Fault modes must include invalid proofs/signatures/identity,
bad/truncated/replayed tags, wrong/reused/skipped counters, oversized/deep
inputs, wrong state, dropped event/timing/feedback traffic, delayed/invalid
resend, socket pressure, partial I/O, timeout, and disconnect at every state.

### S1.6 Hardware gate

On the exact Stage 0 host/receiver/oracle:

- record `_raop`/`_airplay` observations and `/info` profile;
- test honest neutral sender identity first;
- run bad PIN, first pair, pair-verify reconnect, sender restart, receiver
  reboot, pinned-key change simulation where safely possible, and explicit
  remove/re-pair;
- verify encrypted control/event/media, timing, feedback, resend, flush,
  volume/mute method under consideration, and teardown;
- run deterministic audio long enough for objective frequency/channel/
  amplitude/drop correlation; and
- run an uninterrupted 60-minute session with resource, queue, timing, resend,
  and cleanup evidence.

Transient Mac/HomePod work is non-blocking only after O-01 is accepted and
D-016 is amended. Until then, D-016's existing Apple TV plus Mac gate remains
controlling.

### Expected Stage 1 commands

These commands become required as the new tests/binaries are added:

```powershell
.\build.ps1 -Test
.\build.ps1 -Configuration Debug -UserModeOnly
.\build.ps1 -Configuration Release -UserModeOnly
git diff --check
```

Package-specific commands may be added for diagnostics only when they name
tests with `--exact`; a substring filter that can match zero tests is not a
gate. `build.ps1 -Test` remains authoritative and already includes process integration.

### Stage 1 exit gate

Stage 1 passes only when:

- independently corrupted M4 proof, every M6 field/signature, M2 identity/
  ephemeral/signature, AEAD tag, counter, frame, and state fail before later
  state or media activity;
- the independent mock validates pairing, encrypted session, decoded audio,
  timing, feedback, type-`0x55` request/type-`0xD6` wrapper and byte-identical
  protected inner packet, flush, volume/mute, and teardown;
- cancellation and every injected failure leave no task, socket, partial record,
  secret, or unbounded state behind;
- the named persistent Apple TV target completes first pairing, verified
  reconnect, objective correct-audio evidence, and 60 minutes continuously;
- IPv4 original/resend packet-size and no-fragment behavior pass; any IPv6
  claim has separate sufficient-PMTU evidence for both packets;
- no secret appears in command lines, logs, crash output, or retained evidence;
- no GPL implementation is copied, translated, linked, or used as a line-by-
  line/design source; approved black-box oracle use remains segregated; and
- all classic regressions pass.

Stage 2 must not start if any authentication is fail-open, the named target
requires PTP or dishonest identity, the resend wrapper/inner-ciphertext contract
is unproven, packet size is unsafe, or the only audio evidence is connection/
packet counts.

## 7. Stage 2 — Product and installed-service integration

**Goal:** make the proven AP2 profile a disabled-by-default, explicitly paired
service transport while preserving the current driver, capture, classic RAOP,
installer, and cleanup contracts.

**Estimate:** 5–8 engineer-weeks.

### S2.1 Capability and admission

Update:

- `shared/src/receiver.rs` with typed AP2 capability and eligibility/withheld
  reasons;
- `shared/src/discovery.rs` to aggregate compatible scoped `_raop` and
  `_airplay` evidence, timing/pairing/group/security flags, model/firmware, and
  profile fingerprint; and
- `shared/src/identity.rs` only where a new typed binding is required, without
  using hostname, address, or friendly name as physical identity.

Recognized AP2 capability and endpoint eligibility must remain separate.
Missing/corrupt credentials, unknown firmware, transient opt-in, quarantine,
PTP requirement, conflicting observations, or unusable scoped routes must
withhold the endpoint with an exact reason.

Under O-11, configuration names one canonical AP2 receiver ID. The coordinator
creates at most one AP2 endpoint and one active AP2 session; other recognized
AP2 receivers remain withheld as `single_receiver_scope`. Classic endpoints
are unaffected.

### S2.2 Versioned pairing store and administrative CLI

Refactor the DPAPI mechanics in `service/src/credentials.rs` into a bounded
private helper and add a distinct AP2 record store, for example
`service/src/pairings.rs`. Add and package `tools/src/bin/airplay-pair.rs`.

The CLI surface matches the specification: `list`, remote `pair`, `verify`,
`unpair`, local `show`, and local `forget`. Every remote operation requires the
canonical receiver plus exact current interface and address, refuses ambiguity,
shows the trust/profile before confirmation, prompts without echo, and verifies
M6 plus a fresh pair-verify before atomic commit.

Under O-15 the elevated one-shot transaction is:

```text
stop service
  -> discover exact observation
  -> pair / verify
  -> write and ACL/read-back machine-DPAPI record
  -> restart service even on a handled failure
```

Ordinary interactive users cannot decrypt or replace controller keys. The
final service SID and Administrators receive only the selected store access.
There is no initial pairing IPC and no PIN crosses a process boundary. Tests
inject the PIN through a secret-provider abstraction, never a CLI argument.
Stage 1 current-user identities are not migrated; production re-pairs under the
final identity unless a separately authenticated migration is approved.

If M6/fresh verify succeeds but local write, ACL, atomic replace, or read-back
fails, use the still-in-memory key for best-effort authenticated remote unpair.
If that also fails, fail the command with `orphaned_remote_pairing` and exact
receiver-side cleanup instructions. Remote `unpair` failure retains the local
record; only explicit confirmed `forget` removes it.

Implement a recovery-only two-phase journal before sending receiver-committing
pair-setup M5. It is DPAPI-protected under a separate purpose/ACL,
contains bounded candidate controller and transaction state, and is never an
active service credential. Atomically add the pinned accessory result after
verified M6; promote to the active record only after a fresh pair-verify, then
remove the journal. CLI startup/preflight reconciles journals by fresh verify
plus explicit promote/remote-unpair where possible, or reports
`orphaned_remote_pairing` with exact manual cleanup when safe verification is
impossible.

Stage 2 must explicitly implement O-10. Destructive reinstall preflight lists
all affected paired receiver IDs, directs the operator through the separately
signed `airplay-pair unpair` workflow, and verifies the local record is gone or
requires explicit pairing-loss confirmation before deleting the only local
key. The installer itself does not implement AP2 pairing/network protocol. It
may not preserve credentials by accident or through an unauthenticated backup.
Any install-failure cleanup that leaves a remote orphan must emit exact manual
receiver cleanup/re-pair instructions.

### S2.3 Protocol-neutral streaming service

Refactor `service/src/streaming.rs` around an explicit session enum such as:

```rust
enum TransportSession {
    Classic(RaopSession),
    AirPlay2(Ap2Session),
}
```

Provide typed connect/start, capture-origin, PCM send, discontinuity, explicit
flush, volume/mute, finish, teardown, statistics, and error-policy operations.
Do not force distinct protocol semantics into a misleading common method.

Extend `service/src/coordinator.rs` to reconcile pairing and profile changes,
quarantine proof/signature/pinned-identity/downgrade failures until explicit
forget/re-pair, and prohibit downgrade. Per-session AEAD/counter/framing failure
closes/destroys keys and follows the bounded fresh pair-verify circuit breaker;
wrong-source unauthenticated UDP is rejected/rate-limited without permanent
quarantine. All AP2 sockets must use an exact current observation/interface;
route/name changes rebind only after the pinned identity verifies.

### S2.4 Endpoint volume/mute

Add a bounded endpoint-control component beside `service/src/wasapi.rs` that:

- observes the exact deterministically mapped endpoint;
- reads initial master volume/mute before streaming;
- receives and coalesces changes outside the capture drain path;
- applies gain/mute exactly once using the O-05 mechanism;
- restores correct state on reconnect/unmute; and
- prevents receiver/sender feedback loops.

The mock and installed matrix must cover unity, exact Windows-reported 50%,
mute, unmute, reconnect while muted, and rapid changes. If AP2 protocol volume
is used, its dB mapping/special mute value and receiver-global effect must be
hardware-validated. The existing classic hard-coded startup volume must be
replaced or reconciled under the same exact-once control. The shared installed
volume matrix is mandatory for both AP2 and every currently claimed classic
path; Stage 3 cannot pass while either is open.

### S2.5 Configuration, diagnostics, and privacy

Add disabled-by-default service settings equivalent to:

```json
{
  "airplay2_enabled": false,
  "airplay2_allow_transient_pairing": false,
  "airplay2_receiver_id": null
}
```

Do not expose parser, crypto, or memory safety limits as configuration.

Diagnostics must report profile/trust/model/firmware/interface, pairing-record
presence/version/match state, safe state transition/failure class, quarantine,
timing, packet, resend, drop, volume, reconnect, and teardown counters. Typed
redaction must prevent encrypted/decrypted secret-bearing headers and bodies
from entering the existing response tracer, logs, or support bundles.

### S2.6 Installer and firewall surface

- Add only the production pairing CLI and required runtime binary/dependencies
  to the exact package, signing, verification, license, and installer manifests.
- Keep Stage 1 spike/mock tools excluded.
- Create and verify any distinct protected pairing directory and ACL.
- Implement O-10 preflight, remote-unpair/explicit-loss decision, orphan
  diagnostics, and exact install/upgrade/uninstall read-back.
- Retain the existing exact program-scoped inbound UDP, Private,
  `LocalSubnet`, negotiated-ephemeral-port policy if Stage 1 evidence says it is
  sufficient. Add no PTP ports and no inbound TCP.
- If the network executable changes in Stage 3, move firewall ownership to that
  exact executable.

The installer remains the only firewall mutator. The runtime diagnoses a
missing/invalid rule but receives no firewall-administration privilege. While
networking, pairing, or key access still runs as `LocalSystem`, the Stage 2
package is internal test-only and not an externally distributable preview.

### S2.7 Integration and installed acceptance

Add deterministic tests for discovery/classification, pairing state, identity
mismatch, no downgrade, scoped routing, session service lifecycle, driver-to-
mock decoded audio, volume/mute, package exactness, firewall read-back, cleanup,
and classic regressions.

Expected source/package commands:

```powershell
.\build.ps1 -Bootstrap
.\build.ps1 -Test
.\build.ps1 -Configuration Debug -UserModeOnly
.\build.ps1 -Configuration Release -UserModeOnly
.\build.ps1 -Driver -Configuration Debug
.\build.ps1 -Package -Configuration Release
.\installer\Test-InstallerContract.ps1
git diff --check
```

On a recovery-capable host, after explicitly confirming destructive credential
and driver state effects:

```powershell
.\installer\Invoke-TestBuildPackageSignInstall.ps1 -Configuration Release
```

If that privileged procedure is not authorized/executed, it remains **NOT
RUN**; source/mock success may not satisfy the installed gate.

### Stage 2 exit gate

Stage 2 passes only when one same-revision package proves:

- an eligible, explicitly enabled, correctly paired named receiver creates
  exactly one stable/correct endpoint;
- missing/corrupt/wrong-version/wrong-receiver records, changed pinned keys,
  invalid authentication, transient-disabled, unknown firmware, PTP-required,
  quarantined, and conflicting profiles create no misleading endpoint;
- installed WaveRT -> WASAPI -> conversion -> ALAC -> AP2 mock produces
  independently decoded correct audio;
- the named physical persistent receiver passes the installed service path;
- initial/change/reconnect/mute/unmute volume semantics pass exactly once;
- service restart, record deletion, explicit unpair/re-pair, failed pairing
  transaction, and uninstall leave no unreported orphan worker, endpoint,
  secret, temp/active record, or firewall residue;
- process/power loss injected before receiver commit, after receiver commit,
  after M6, after fresh verify, during final record replace/read-back, and before
  journal removal either recovers safely or reports the exact remote orphan and
  manual action without exposing an active partial credential;
- the exact firewall and package/signature manifests read back correctly; and
- classic RAOP source and installed regression behavior remains correct.

Stage 2 remains an internal preview. The current combined `LocalSystem` network
service is neither release-acceptable nor externally distributable and must be
resolved in Stage 3.

## 8. Stage 3 — Release hardening

**Goal:** close the privilege, security, network, hardware, lifecycle, supply-
chain, signing, and legal gates required for a truthful limited claim.

**Estimate:** 4–8 engineer-weeks plus external review/scheduling.

### S3.1 Restricted service boundary

First test the complete user-mode service under a restricted service identity
with the minimum endpoint, loopback-capture, protected-store, mDNS, and network
access it needs. It receives no firewall-administration privilege.

If privileged endpoint operations cannot run there, split:

```text
minimal endpoint broker (LocalSystem; no network protocol or secrets)
    <-> authenticated, authorized, versioned, bounded local IPC
restricted audio/network worker (capture, discovery, pairing, crypto, AP2)
```

IPC must use exact service-SID ACLs, client token/process verification, bounded
length-prefixed messages, typed create/remove/query operations, cancellation,
and explicit cleanup. It must carry no arbitrary path/host/port, raw audio,
pairing secret, or reusable handle. Installer service definitions, ACLs,
recovery, signatures, endpoint ownership, and firewall executable identity must
change atomically and be fault-tested.

The elevated installer remains the sole firewall-rule mutator and targets the
exact restricted network executable. The runtime only diagnoses rule state.
The AP2 network/pairing/crypto worker **MUST NOT** run as `LocalSystem` in a
Stage 3 release.

### S3.2 Fuzzing, fault injection, and review

- Run isolated fuzz campaigns for TLV8, binary plist, encrypted-frame
  segmentation, RTSP/event bodies, feedback, timing, RTP, and retransmission.
- Retain minimized non-secret corpora and deterministic regressions for every
  finding; record duration, revision, toolchain, corpus/crash hashes, and result.
- Inject disconnect, replay, reorder, truncation, oversized/deep input, partial
  TCP I/O, UDP pressure, counter exhaustion, credential corruption, service
  stop, and task cancellation at every state.
- Obtain independent review of key separation, pairing identity, proof/signature
  gates, nonce/counter ownership, parser bounds, event ownership, resend wrapper
  plus byte-identical protected inner packet, logging/redaction, store ACLs,
  IPC, and cleanup.
- Block release on any unresolved critical/high security finding.

### S3.3 Hardware, network, lifecycle, and soak matrix

For every claimed model/firmware, record exact profile/trust, address family,
interface/MTU, sanitized transcript hash, build/package hash, Windows build,
procedure, oracle, duration, and metrics.

Minimum cases:

- first pair, stored pair-verify, bad PIN, identity/key change, remove/re-pair;
- receiver busy, reboot, sleep/wake, sender restart, service/worker/broker crash;
- Ethernet/Wi-Fi, IPv4, conditional IPv6, multi-homed selection, address/
  interface change;
- packet loss, reorder, duplication, delay, retransmit burst, event/feedback
  loss, UDP pressure, 1500-byte and lower-MTU/VPN behavior;
- Private playback plus Public/Domain refusal/diagnostics and firewall policy
  merge/denial;
- PC sleep/resume, install, repeat clean reinstall, rollback fault, uninstall;
- initial/rapid/reconnect volume and mute; and
- end-to-end latency, clock drift/correction, queue high-water, audio
  correlation, CPU, private/working set, recovery time, and cleanup.

Run at least eight uninterrupted hours on every release-supported model/
firmware/trust profile. Experimental non-claimed rows require at least 60
minutes when exercised but do not satisfy a release-supported row. No
monotonic resource growth, nonce/counter reuse, unbounded queue, stale endpoint,
reconnect loop, secret residue, or unexplained audio discontinuity is allowed.

Mac/HomePod transient rows remain experimental unless O-01 changes and they
pass their own trust-appropriate matrix. A HomePod that requires PTP remains
unsupported; Stage 3 does not expand into PTP.

### S3.4 Supply chain, signing, legal, and claims

- Run locked dependency advisory/license/source checks.
- Generate and review the SBOM and license/notice bundle.
- Prove no GPL/oracle code, test identity/key, spike/mock executable, or raw
  packet capture is packaged.
- Complete clean-root/reproducibility and path-remapping gates.
- Complete production executable/catalog signing and clean-host verification.
- Obtain legal/MFi disposition for the exact distribution and branding text.
- Update README, compatibility, security, risk, testing, known limitations,
  release checklist, progress, validation, and decisions to match only the
  evidence from the release revision.

Same-revision final source/build/package commands:

```powershell
.\build.ps1 -Test
.\build.ps1 -Configuration Debug -UserModeOnly
.\build.ps1 -Configuration Release -UserModeOnly
.\build.ps1 -Driver -Configuration Debug
.\build.ps1 -Driver -Configuration Release
.\build.ps1 -Package -Configuration Release
.\installer\Invoke-TestBuildPackageSignInstall.ps1 -Configuration Release -WhatIf
git diff --check
```

The actual guarded deployment, production signing/Partner Center path, Driver
Verifier campaign, and applicable HLK run are separate explicit procedures on
the authorized recovery-capable or clean target hosts. Follow
`docs/build-and-install.md` and `docs/testing.md`; if either lacks an exact
procedure at execution time, update it before running. Unexecuted procedures
remain **NOT RUN**.

### Stage 3 release gate

Release is blocked unless:

- no unresolved critical/high security finding exists;
- every authentication path fails closed and no nonce/key/counter reuse exists;
- the network/pairing/crypto worker runs under the accepted restricted boundary;
- all claimed named hardware/firmware, audio, volume/mute, network, lifecycle,
  MTU, drift, and duration gates pass;
- CPU, memory, queue, reconnect, and latency meet the Stage 0 thresholds;
- clean install, failure rollback, uninstall, firewall, credential, IPC, and
  secret cleanup read back correctly;
- package provenance, SBOM, licenses, advisories, reproducibility, and
  production signing pass;
- the existing Driver Verifier and applicable HLK release gates pass on the
  recovery-capable host even though AP2 adds no kernel protocol code; and
- legal/MFi review accepts the actual distribution and public wording.

The allowed claim is bounded to **single-device AirPlay 2 audio** for the exact
named model/firmware/trust/timing rows that passed. “Full AirPlay 2,”
multi-room, PTP, broad third-party compatibility, Windows 10, and ARM64 remain
unsupported.

Any applicable release item still marked **NOT RUN** keeps the release gate
open; planning, upstream reports, compilation, mock traffic, or a different
receiver cannot substitute for the missing result.

## 9. Evidence record template

Each Stage 1–3 validation entry should contain:

| Field | Required content |
|---|---|
| Scope | Requirement/stage/work-package IDs |
| Revision | Exact Git commit and dirty-tree state |
| Build | Package/manifest/executable hashes where applicable |
| Host | Windows edition/build, toolchain, network profile |
| Receiver | Model, firmware/OS, trust/profile, feature fingerprint |
| Network | Interface, IPv4 or conditional IPv6, PMTU, firewall state |
| Procedure | Exact command and ordered manual steps |
| Oracle | Mock assertion, decoded capture, or physical correlation method |
| Duration | Start/end and uninterrupted stream time |
| Metrics | Audio, timing, queue, resend, CPU/memory, recovery, cleanup |
| Result | `PASS`, `FAIL`, or `NOT RUN` only |
| Artifacts | Redacted hashes/paths; secret-scan result |

Evidence containing pairing secrets, traffic keys, private identities, raw
audio, or unredacted authorization frames must not be retained.

## 10. Future Stage 4 boundary

PTP and multi-room require a new specification, threat model, port/firewall
decision, group state machine, multi-receiver scheduler, per-device latency
control, join/leave/leader recovery, and named two-/three-receiver matrix. They
are not follow-on checkboxes inside this plan and are not authorized by approval
of Stages 0–3.
