# AirPlay 2 single-receiver audio specification

Status: **Accepted v0.1 — O-01 through O-15 accepted on 2026-08-12**  
Specification date: 2026-08-12  
Implementation status: **not implemented and not supported**

This document defines the first bounded AirPlay 2 audio profile for
WinAirPlayAudio. It is an engineering interoperability specification, not an
Apple specification, certification, compatibility claim, or legal opinion.
The dated source evidence and licensing boundary are in
[compatibility and source references](airplay-compatibility-and-licensing.md#historical-ap2-source-checks). The executable work plan
is in [`airplay2-stage-0-3-plan.md`](airplay2-stage-0-3-plan.md), and the
governing decisions are
[D-016](decisions.md#d-016--staged-airplay-2-sender-strategy) and
[D-020](decisions.md#d-020--airplay-2-stage-0-product-defaults).

The words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative. A requirement may be relaxed only by a recorded decision in
`docs/decisions.md`, with the corresponding risk and validation gates updated.

### Requirements index

The identifiers below are stable traceability keys for the implementation plan,
tests, and `VALIDATION.md`. The detailed sections remain normative.

| ID | Requirement area | Detailed sections |
|---|---|---|
| AP2-R01 | Bounded product scope and exclusions | 1–4 |
| AP2-R02 | User-mode architecture and privilege boundary | 5 |
| AP2-R03 | Typed discovery, capability, and admission | 6 |
| AP2-R04 | Persistent/transient trust and honest identity | 7 |
| AP2-R05 | Pairing UX and protected credential lifecycle | 8 |
| AP2-R06 | Explicit protocol state machine | 9 |
| AP2-R07 | Fail-closed cryptography and key/counter separation | 10 |
| AP2-R08 | Bounded parsing, sockets, and untrusted input | 11 |
| AP2-R09 | ALAC, transactional media, protected-inner-packet resend, and pacing | 12 |
| AP2-R10 | NTP timing, encrypted events, and feedback | 13–14 |
| AP2-R11 | Exact-once endpoint volume and mute | 15 |
| AP2-R12 | Least-privilege network and firewall policy | 16 |
| AP2-R13 | Failure classification, recovery, and cancellation | 17 |
| AP2-R14 | Safe diagnostics and privacy | 18 |
| AP2-R15 | Test, evidence, and release gates | 19 |
| AP2-R16 | Owner-approved policy decisions | 20 |

## 1. Product outcome

The first deliverable is one Windows render endpoint streaming its shared-mode
rendered mix to one admitted receiver using the receiver's AirPlay 2 real-time
audio profile.

The implementation:

- **MUST** run discovery, pairing, cryptography, codecs, sockets, timing, and
  receiver policy in user mode;
- **MUST NOT** change the WaveRT kernel data path for AirPlay 2;
- **MUST** preserve the existing classic RAOP path and its compatibility
  claims;
- **MUST** use a native Rust implementation or reviewed permissively licensed
  Rust dependencies that are compatible with the project's distribution;
- **MUST NOT** copy or link GPL protocol implementations into distributed
  artifacts; and
- **MUST** fail closed when receiver authentication, encryption, framing,
  admission, or capability negotiation is incomplete or invalid.

Before all Stage 3 release gates pass, user-facing text **MUST** call the
feature either "experimental AirPlay 2 single-receiver audio" or an equally
bounded term. It **MUST NOT** claim full AirPlay 2 support, certification,
multi-room support, or general receiver compatibility.

## 2. Initial target profile

The release-candidate profile is deliberately narrow:

| Area | Required initial behavior |
|---|---|
| Receiver count | Exactly one receiver per session; no grouping |
| Trust | Persisted HAP pairing with a pinned receiver identity |
| Session | Authenticated encrypted control and event channels |
| Media | Real-time UDP audio with authenticated encryption |
| Codec | Uncompressed ALAC, 44.1 kHz, 16-bit, stereo, 352 frames per packet |
| Timing | NTP-style single-receiver timing; no PTP |
| Recovery | Bounded feedback, resend, flush, reconnect, and teardown |
| Network | IPv4 baseline; IPv6 only after the exact packet/PMTU gate passes |
| Controls | Windows endpoint volume and mute affect the AP2 stream exactly once |
| Platform | Windows 11 x64 24H2 or newer only |

Support is granted to a named receiver model/firmware combination only after
its compatibility row passes the Stage 3 matrix. Similar advertisements,
models, or later firmware are not implicitly supported.

### 2.1 Accepted first receiver policy

The accepted initial product defaults are:

- `AppleTV14,1` on the recorded OS 26.5 profile is the first release-candidate
  target, using persisted pairing and pair-verify.
- `Mac16,10` and HomePod are experimental targets only if they require a
  transient pairing path that cannot pin a unique receiver identity.
- No transient-only receiver is part of the initial release claim; its exact
  trust limitation must remain visible to users who explicitly opt in.

These defaults are Stage 0 decisions, not current support claims.

## 3. Explicit non-goals

The following are outside Stages 0–3:

- multi-room grouping, simultaneous receivers, PTP, group leadership, and
  synchronized join/leave;
- buffered stream type 103, remote media queues, video, mirroring, photos, and
  the broader remote-control ecosystem;
- AAC, AAC-ELD, Opus, compressed ALAC variants, or codec negotiation beyond the
  named uncompressed-ALAC profile;
- FairPlay- or MFiSAP-only receivers unless a lawful, distributable solution is
  separately approved;
- generic third-party receiver support inferred only from DNS-SD flags;
- Windows 10, ARM64, or non-Windows platforms;
- Apple certification, Apple branding, or a claim that this is an official
  AirPlay implementation; and
- moving network or protocol work into the driver.

A receiver that requires any non-goal for correct playback **MUST** be rejected
with an actionable unsupported reason. The implementation **MUST NOT** silently
fall back to classic RAOP or a weaker trust profile.

## 4. Support and evidence vocabulary

Code, diagnostics, documentation, and compatibility records **MUST** distinguish
these states:

| State | Meaning |
|---|---|
| Observed | A DNS-SD advertisement was received on a specific interface |
| Recognized | The advertisement was parsed into a known AP2 capability profile |
| Pairable | The configured trust workflow is applicable to that receiver |
| Paired | A complete pairing exchange succeeded and, where applicable, identity was persisted |
| Stream-validated | The named model/firmware completed the required hardware procedure |
| Release-supported | All Stage 3 product, security, legal, and evidence gates passed |

Observation, recognition, or a successful TCP connection is not proof of audio
compatibility. An endpoint **MUST NOT** be exposed merely because a receiver
advertises `_airplay._tcp` or AP2-related feature bits.

## 5. Architecture and ownership

The existing component boundary remains authoritative:

```text
WaveRT endpoint
    -> endpoint shared-mode WASAPI loopback capture
    -> bounded PCM queue
    -> audio conversion / packet scheduling
    -> selected user-mode sender: Classic RAOP or AP2
    -> exact discovered receiver address and interface
```

### 5.1 Reused boundaries

The implementation **SHOULD** reuse:

- receiver discovery observations and interface scoping;
- stable receiver identity construction;
- endpoint lifecycle and the endpoint shared-mode WASAPI loopback capture path;
- bounded audio queues, capture-time pacing, and discontinuity accounting;
- cancellation, orderly thread joins, diagnostics, and service recovery;
- machine-DPAPI credential storage boundaries; and
- exact program-scoped Private/`LocalSubnet` firewall ownership.

Protocol-specific parsing, cryptography, ALAC framing, media protection, event
handling, and timing **MUST** be separate from the classic RAOP modules.

### 5.2 Session abstraction

Service integration **MUST** select an explicit typed sender profile, not infer
behavior from scattered flags. The boundary must be equivalent to:

```rust
enum SenderProfile {
    ClassicRaop(ClassicProfile),
    AirPlay2(Ap2Profile),
}
```

An AP2 session owner **MUST** own all sockets, channel keys, counters, RTP
sequence state, retransmission ciphertext, and cancellation state for that
session. It **MUST NOT** detach workers or allow two tasks to mutate the same
protocol counter independently.

### 5.3 Privilege boundary

The current combined `LocalSystem` network/device service is a release blocker
independent of protocol correctness. Before Stage 3 exits, either:

1. the service **MUST** run under a narrower account with only the device,
   loopback-capture, credential, and network permissions it needs; or
2. privileged endpoint work **MUST** be split from a restricted network worker
   over authenticated, authorized, versioned, bounded IPC. Firewall mutation
   remains an explicit elevated installer responsibility.

The chosen design and threat analysis **MUST** be recorded in
`docs/decisions.md` and `docs/security.md`.

## 6. Receiver discovery and admission

### 6.1 Observation model

The classifier **MUST** combine companion `_raop._tcp` and `_airplay._tcp`
observations only when their stable receiver identities and observation scope
match. It **MUST** retain:

- interface index and local source address;
- receiver address, port, instance name, and stable identity inputs;
- model, source version, OS/build where advertised;
- features, status flags, pairing flags, password flags, and codec/timing data;
- group, leader, seed, and PTP indicators where advertised; and
- the complete reason why a profile was admitted or rejected.

Conflicting companion records, malformed numbers, impossible flag
combinations, identity collisions, or data that exceeds parser limits **MUST**
fail closed. A credential learned for one canonical receiver **MUST NOT** be
transferred to another canonical receiver, accessory identifier, or long-term
public key. Address, port, interface, and instance changes are legitimate
network-location changes: a new scoped observation may be tried for the same
canonical receiver, but it becomes trusted only after pair-verify proves the
pinned accessory identifier and public key.

### 6.2 Typed capability result

An admitted candidate **MUST** carry a typed AP2 profile containing at least:

- trust profile: `PersistentPinned` or `TransientEncrypted`;
- timing profile: initially `NtpSingleReceiver` only;
- selected address and interface;
- expected pairing and pair-verify behavior;
- media transport, codec, sample format, and packet size;
- event and feedback requirements;
- named compatibility entry and evidence status; and
- any reason the profile remains experimental.

PTP-required, grouped-only, FairPlay-only, MFiSAP-only, unknown-encryption, or
unknown-pairing profiles **MUST** be rejected. Recognition **MUST NOT** create an
endpoint until pairing/admission policy allows it.

Pending O-11, the initial admission policy **MUST** name one configured AP2
canonical receiver ID and create at most one AP2 endpoint and one active AP2
session. Other recognized AP2 receivers remain visible only as withheld with a
`single_receiver_scope` reason. Classic receiver admission is unaffected.

## 7. Trust profiles and receiver identity

### 7.1 `PersistentPinned`

This is the accepted initial release trust profile. It **MUST**:

- complete the PIN-based HAP pair-setup exchange;
- verify the pair-setup M4 server SRP proof before advancing;
- decrypt pair-setup M6; require its exact state/error/TLV schema; and verify
  the accessory identifier, long-term public key, and Ed25519 signature over
  the frozen accessory transcript before any persistent record is eligible to
  commit;
- store the controller identity and the receiver accessory identifier and
  long-term public key only after M6 is authenticated and a fresh pair-verify
  succeeds with the in-memory candidate record;
- run pair-verify on every later connection;
- decrypt pair-verify M2; require its exact state/error/TLV schema; and verify
  accessory-ID equality plus the Ed25519 signature over the exact ephemeral-key
  transcript before sending M3 or enabling encrypted control;
- require the verified receiver identity to equal the persisted identity; and
- abort, require an explicit credential reset, and report a security event if
  the receiver presents another identity.

It **MUST NOT** fall back automatically to transient pairing, unverified setup,
classic RAOP, or a fresh replacement identity.

### 7.2 `TransientEncrypted`

This profile establishes fresh encrypted session material but may not prove a
previously pinned, unique receiver identity. If retained after Stage 0, it:

- **MUST** be experimental and opt-in;
- **MUST** verify every proof available within that exchange;
- **MUST** use fresh ephemeral keys for every connection;
- **MUST NOT** be described as a persistently authenticated receiver;
- **MUST NOT** be selected as fallback from failed pair-verify; and
- **MUST** display the trust limitation before the user enables it.

A fixed/default transient PIN, including the observed compatibility value
`3939`, is public protocol material. It provides no unique receiver
authentication, **MUST NOT** elevate the result to persistent/pinned trust, and
**MUST NOT** be stored or displayed as evidence that the intended receiver was
authenticated.

If the implementation cannot preserve this explicit opt-in boundary and every
listed limitation, the profile is removed and receivers that require it remain
unsupported.

### 7.3 Honest sender identity

WinAirPlayAudio **MUST** generate and persist its own controller identifier and
Ed25519 key pair. The accepted default is a distinct controller identity per
persistent receiver to limit correlation and compromise blast radius. Sharing
one identity would require a later owner decision plus a rotation, revocation,
and migration design. Session UUIDs and ephemeral keys **MUST** be fresh where the
protocol requires them. The sender **MUST NOT** impersonate an Apple model,
Apple software build, Apple-owned identifier, or fabricated Apple device MAC.

If a named receiver refuses an honest, neutral sender identity, implementation
stops at the applicable gate for a product/legal decision. Shipping a dishonest
identity is not an engineering workaround.

## 8. Pairing and credential lifecycle

### 8.1 User workflow

Pairing **MUST** be an explicit administrative action against one exact
observation. The initial command-line workflow is expected to provide:

```text
airplay-pair list
airplay-pair pair --receiver <stable-id> --interface <index> --address <ip:port>
airplay-pair verify --receiver <stable-id> --interface <index> --address <ip:port>
airplay-pair show --receiver <stable-id>
airplay-pair unpair --receiver <stable-id> --interface <index> --address <ip:port>
airplay-pair forget --receiver <stable-id>
```

The PIN **MUST** be read from an interactive console without echo. It **MUST
NOT** appear in command arguments, environment variables, configuration files,
logs, telemetry, or crash reports. Pairing **MUST** show the selected model,
instance, address, and interface before confirmation. Remote pair, verify, and
unpair operations **MUST** require an exact current scoped observation selector
and refuse ambiguous, stale, or mismatched receiver/interface/address inputs.

Under O-15, the initial production transaction is an elevated one-shot action:
stop the service, discover and pair/verify the exact observation, write and
ACL/read-back the machine-DPAPI record, then restart the service even after a
handled failure. Ordinary interactive users **MUST NOT** decrypt or replace
controller keys. There is no initial pairing IPC; tests inject a PIN through a
secret-provider interface, never a process argument. A Stage 1 test identity is
not migrated into production without a separately authenticated migration.

### 8.2 Stored record

The AP2 credential schema **MUST** be versioned and separate from classic RAOP
password records. A persistent record contains only the fields required to
reconstruct trust, including:

- canonical receiver identity;
- receiver accessory identifier and pinned Ed25519 public key;
- controller identifier and private/public long-term identity;
- creation time and schema version; and
- sufficient provenance to detect an observation/credential mismatch.

The compatibility profile/firmware allowlist and last verification timestamp
belong in non-secret admission/telemetry state, not in the cryptographic trust
record. Firmware change alone **MUST NOT** require re-pairing when the pinned
accessory identity remains valid.

Session keys, PINs, SRP intermediates, plaintext audio, counters, and nonces
**MUST NOT** be persisted.

Production records **MUST** be written atomically only after M6 and a fresh
pair-verify complete, protected with machine-scope DPAPI and explicit ACLs, and
zeroized after use where the Rust type permits it. The developer-only Stage 1
tool **MAY** use a distinct current-user-DPAPI, test-only store so process-
restart pair-verify can be tested; it **MUST** use the same bounded record
schema, a separate purpose/directory, and **MUST NOT** be packaged or implicitly
migrated into the production store. `unpair` attempts the authenticated remote
operation before local deletion. If remote unpair fails, the local record
**MUST** be retained so recovery remains possible; only an explicit confirmed
`forget` deletes it and warns that receiver-side cleanup is still required.

If M6 and fresh pair-verify succeed but DPAPI write, ACL, atomic replace, or
read-back fails, the tool **MUST** attempt authenticated remote unpair while the
in-memory controller key is still available. If cleanup also fails, the command
fails and records a safe `orphaned_remote_pairing` status plus exact receiver-
side recovery instructions; it **MUST NOT** report pairing success. Interrupted
pairing **MUST** leave no locally usable partial record.

Process/host loss is handled with a separate two-phase recovery journal. Before
sending the receiver-committing pair-setup M5, the elevated CLI **MUST**
atomically write the bounded candidate controller identity/key and transaction
state under a recovery-only DPAPI purpose and ACL. The service/streaming path
**MUST NOT** load this journal as a credential, and the recovery ACL **SHOULD**
exclude the runtime service SID. After verified M6 it atomically adds the pinned
accessory result; only after a fresh pair-verify may it promote an active record
and remove the journal. On startup/preflight, the elevated CLI
**MUST** reconcile a journal: where verified M6 identity is available it may
fresh-verify and explicitly promote or remotely unpair; otherwise it reports
`orphaned_remote_pairing` and exact manual receiver cleanup. It never silently
treats a recovery journal as a successful pairing.

Any destructive reinstall that will delete AP2 records **MUST** list affected
receiver IDs in preflight and require explicit pairing-loss confirmation.
Authenticated remote unpair is preferred before deletion. If install-failure
cleanup or confirmed `forget` destroys the only local key while the receiver
retains the controller, documentation and diagnostics **MUST** identify the
orphan and the exact receiver-side removal/re-pair procedure.

## 9. Protocol state machine

The implementation **MUST** represent the control flow as an explicit state
machine. The detailed receiver-specific sequence is frozen in Stage 0, but the
required logical states are:

```text
Discovered
  -> Admitted
  -> ControlConnected
  -> first pair: PairSetup -> PairSetupValidated -> PairVerify
     reconnect: PairVerify
  -> ControlEncrypted
  -> ReceiverInfoValidated
  -> SessionConfigured
  -> EventChannelEncrypted
  -> MediaControlReady
  -> MediaConfigured
  -> Streaming
  -> Flushing
  -> Teardown
  -> Closed
```

The sequence **MUST** cover, as applicable, pair-setup/pair-verify,
`GET /info`, session `SETUP`, event-channel connection, stream `SETUP`, volume,
timing/sync, media, feedback/resend, `FLUSH`, and `TEARDOWN`. `RECORD` is
profile-optional: the known real-time Apple TV reference skips it because that
profile does not reply. Stage 0 **MUST** freeze whether each named profile sends
it; the implementation **MUST NOT** probe by trying both orders.

Every transition **MUST** define:

- accepted request/response status, content type, and body schema;
- maximum frame/body size and parsing depth;
- read, write, and whole-step deadline;
- which keys and counters exist and who owns them;
- permitted retry behavior and whether bytes must be identical;
- cancellation and cleanup behavior; and
- terminal error classification.

Unexpected, duplicate, out-of-order, unauthenticated, or downgraded messages
**MUST** be rejected unless the frozen profile explicitly permits them. A
missing proof or signature is a failure, not a warning.

## 10. Cryptographic requirements

The implementation **MUST** use reviewed, actively maintained, permissively
licensed Rust crates for cryptographic primitives. Handwritten implementations
of SRP arithmetic, Ed25519, X25519, HKDF, SHA, ChaCha20-Poly1305, or constant-
time comparison are prohibited unless a separate security decision approves
them.

The AP2 crypto layer **MUST**:

- verify pair-setup M4 server proof, pair-setup M6 accessory identity/signature,
  and pair-verify M2 pinned identity/signature before their state changes;
- bind pair-verify keys to the persisted accessory identity;
- derive independent keys for each protocol channel and direction using the
  exact frozen labels and transcript inputs;
- use independent monotonic nonce/counter state for each key and direction;
- abort before a counter can wrap or a nonce can be reused with different
  plaintext;
- authenticate ciphertext before parsing or acting on plaintext;
- reject truncated tags, invalid tags, invalid public keys, weak/identity
  points, malformed lengths, and trailing authenticated data not allowed by
  the frozen schema;
- generate long-term and ephemeral keys using the operating system's secure
  random source through the selected Rust crates; and
- zeroize PINs, private keys, session keys, proofs, and derived secrets when
  they leave scope where technically possible.

Known-answer tests **MUST** cover every derivation label, transcript, nonce
encoding, encrypted-frame boundary, and pairing state. Negative tests **MUST**
independently mutate the M4 proof; every M6 state/error/identity/key/signature
field; the M2 identity, ephemeral keys, and signature; and each public-key
binding, counter, length, and AEAD tag.

## 11. Bounded parsing and transport

Stage 0 **MUST** freeze explicit constants for all untrusted inputs. At minimum
the implementation requires limits for:

- RTSP start lines, headers, count, and total header bytes;
- RTSP bodies and encrypted-control plaintext chunks;
- TLV item count, per-item length, aggregate length, and duplicate policy;
- binary-plist bytes, depth, object count, string/data length, and integer
  width;
- DNS name/label and compression-loop limits; record, address, and TXT count;
  aggregate response/TXT bytes; TXT key/value and duplicate policy; TTL/cache
  growth; and interface-churn rate;
- event frames and feedback/retransmit datagrams; and
- outstanding requests, queued media, retransmission history, and reconnect
  attempts.

Until wire captures and the named receiver profile justify tighter values, the
existing 32 KiB RTSP-header limit remains the outer control-header ceiling.
No new parser may allocate from an untrusted length before checked arithmetic
and the applicable limit succeed.

All sockets **MUST** have bounded connect, read, write, and shutdown behavior.
DNS-SD addresses **MUST** be connected using the recorded local interface and
source scope. Received UDP packets **MUST** be checked against the negotiated
source, port, session, length, and state before use.

## 12. Audio encoding and media protection

### 12.1 PCM and ALAC

The AP2 media path **MUST** consume the existing normalized PCM stream and
produce 44.1 kHz, signed 16-bit, stereo packets containing 352 frames. The
uncompressed ALAC bitstream writer **MUST** have golden vectors, boundary
tests, channel-order tests, and decode-back comparison against an independent
permissive decoder used only for validation if necessary.

The packetizer **MUST** use checked size arithmetic and reject any negotiated
format that cannot fit the selected path MTU safely. Stage 1 hardware tests
**MUST** assert the exact serialized sizes and exercise do-not-fragment or
equivalent unfragmented-send behavior, including `WSAEMSGSIZE`. The current
reference layout is:

| Datagram | UDP payload | IPv4 packet | IPv6 packet |
|---|---:|---:|---:|
| Original | 1,448 bytes | 1,476 bytes | 1,496 bytes |
| Type-`0xD6` resend wrapper + original | 1,452 bytes | 1,480 bytes | 1,500 bytes |

The reference ALAC size is
`ceil((23 + 352 * 2 * 16 + 3) / 8) = 1,412` bytes; the original then adds 12
bytes RTP, a 16-byte AEAD tag, and an 8-byte explicit nonce. Stage 0 **MUST**
independently confirm the final
implementation's formula and runtime bytes. The resend consumes all of an IPv6
MTU-1500 packet and cannot fit the IPv6 minimum MTU of 1280 without
fragmentation. Therefore IPv4 is the initial baseline. IPv6 is supported only
when PMTU/do-not-fragment evidence proves both original and resend packets fit
on the named path. IPv6 extension headers, lower-MTU VPN/tunnel paths, and any
fragmentation-dependent success remain unsupported. Reducing frame count is a
new media profile requiring separate hardware proof, not an assumed fallback.

### 12.2 Transactional encrypted send

AEAD nonce/counter state is consumed when encryption occurs, not after socket
success, and **MUST NOT** be rolled back. Sequence numbers, timestamps,
statistics, pacing state, and retransmission history commit only with the
success rule frozen for the channel. For each candidate media packet:

1. irrevocably reserve the next permitted nonce/counter, encrypt once, and bind
   that consumed value to one immutable pending ciphertext/datagram;
2. while it is pending, do not encrypt another payload in an implicit counter
   domain; on transient `WouldBlock`, retry only those exact bytes and only
   before their playout deadline;
3. after one complete UDP send, commit its sequence, timestamp, statistics,
   pacing state, and exact ciphertext to bounded history; and
4. on partial send, deadline expiry, or terminal socket error, never roll back
   or reuse the consumed nonce/counter. Close the affected channel/session
   unless the frozen explicit-nonce profile has a hardware-tested rule that
   permits burning the value and continuing.

Encrypted TCP control/event records follow the same nonce rule: a partial write
continues the same immutable record until its bounded deadline. It never
re-encrypts that plaintext under the same counter. Ambiguous or incomplete
delivery closes and rekeys the channel.

Retransmission **MUST** cache the complete original protected RTP datagram. For
the frozen type-`0x55` request profile, the response is the validated four-byte
wrapper beginning `0x80 0xD6`, followed by the cached RTP datagram
byte-for-byte. It **MUST NOT** re-encrypt or modify that inner packet. Source,
destination,
requested span, packet age/count/rate, and session state **MUST** be validated
before responding.

### 12.3 Pacing and discontinuities

Scheduling **MUST** use the existing monotonic capture-time foundation and
must not pace relative to thread wake time. Queue drops or capture gaps **MUST**
set the first surviving packet's discontinuity/marker semantics as defined by
the frozen AP2 profile. Late packets that cannot arrive before their playout
deadline **MUST NOT** be retried indefinitely.

## 13. Timing and synchronization

The initial profile **MUST** use single-receiver NTP-style timing and an
explicit receiver-latency model. It **MUST**:

- correlate monotonic local capture time with protocol timestamps without using
  wall-clock jumps for pacing;
- validate timing packet source, port, size, version, timestamps, and state;
- reject impossible, stale, or replayed timing samples;
- bound filtering, offset adjustment, and drift correction; and
- expose offset, round-trip time, selected receiver latency, and correction
  counters without logging audio or secrets.

A receiver that requires PTP for this media profile **MUST** be classified as
unsupported. Adding PTP or multi-room requires a later specification and gate.

## 14. Event, feedback, and control channels

The reverse event channel **MUST** be authenticated and encrypted before an
event is parsed or acknowledged. The handler **MUST** accept only the methods,
paths, headers, content types, and schemas frozen for the named profile. Unknown
or malformed security-relevant events **MUST** close the applicable session;
benign unsupported metadata events may receive a bounded explicit response if
the profile documents that behavior.

Feedback and retransmission traffic **MUST** be source-validated, state-bound,
rate-limited, and size-limited. A feedback heartbeat is not proof of receiver
identity and **MUST NOT** keep a failed authenticated control session alive.

Every request **MUST** receive an explicit, bounded response or a documented
connection close. Empty catches, silent discards, and unconditional success
responses are prohibited.

## 15. Volume and mute semantics

The current endpoint shared-mode WASAPI loopback observes audio before endpoint
volume and mute are applied. Therefore release support requires an explicit
control path:

- The exact deterministically mapped endpoint's initial master volume and mute
  **MUST** be read before streaming and changes **MUST** be coalesced through a
  bounded, race-safe path outside the WASAPI capture callback.
- Windows endpoint gain and mute **MUST** affect this stream exactly once.
- Pending O-05, the recommended initial mechanism is local per-stream digital
  gain/mute before ALAC encoding, because it does not mutate receiver-global
  state. The gain law, zero/mute behavior, clipping, ramping, and sample
  rounding **MUST** be frozen and tested if selected.
- If hardware evidence selects AP2 protocol volume instead, the receiver's dB
  range, clamp, mute sentinel, session/global ownership, and read-back behavior
  **MUST** be documented and the pre-volume PCM **MUST NOT** also be scaled.
- Reconnect and new-session setup **MUST** apply the current endpoint state
  before unmuted media becomes audible.
- Sender-originated updates and receiver-originated notifications **MUST NOT**
  form a control feedback loop.
- Receiver-to-Windows volume reflection is deferred unless Stage 0 explicitly
  requires it and authenticated event/read-back evidence proves an
  authoritative receiver value.

The mapping and its tests **MUST** be shared across the service and mock
receiver; it may not be hidden in receiver-specific socket code. The unity,
50%, mute, unmute, reconnect, and rapid-change matrix **MUST** pass for both AP2
and every currently claimed classic path. The classic hard-coded startup volume
must be replaced or reconciled under the same exact-once rule before Stage 3
can pass.

## 16. Network and firewall policy

AP2 **MUST** retain the existing least-privilege policy:

- exact executable identity;
- inbound UDP only where the negotiated receiver profile requires it;
- Private profile and `LocalSubnet` remote scope only;
- no Public or Domain profile enablement;
- no broad fixed-port exception when negotiated ephemeral ports suffice;
- explicit IPv4 and, where admitted by the MTU gate, IPv6/interface selection;
- installer ownership, idempotence, read-back verification, and uninstall
  cleanup for every rule.

If Stage 3 splits the network worker from the privileged broker, firewall rules
**MUST** follow the restricted network executable rather than remain attached
to the privileged component. The service **MUST** continue to operate safely
when rule creation is denied and report the exact required administrative fix.
The runtime broker/worker **MUST NOT** receive general firewall-administration
privilege. Public/Domain validation proves refusal and accurate diagnostics; it
does not enable or require playback on those profiles.

## 17. Failure, recovery, and cancellation

Errors **MUST** distinguish trust-terminal, session-security, profile-terminal,
session-terminal, retryable, and rejected-untrusted-input cases:

- M4/M6/M2 proof or signature failure, pinned identity/key mismatch, or an
  attempted security downgrade is trust-terminal: abort and quarantine until
  an explicit administrative forget/re-pair or separately recorded recovery;
- an invalid AEAD tag, counter, or encrypted framing on an established channel
  is session-security-terminal: abort, destroy all session keys, and allow only
  bounded delayed pair-verify with fresh keys; a Stage 0 repeated-failure
  circuit-breaker threshold determines when explicit user recovery is required;
- malformed or wrong-source unauthenticated UDP is rejected and rate-limited
  with metrics; it **MUST NOT** let a spoofed LAN packet permanently quarantine
  a valid receiver;
- unsupported timing, codec, or trust requirements are profile-terminal;
- interrupted sockets and confirmed route/transport failure are
  session-terminal; and
- only explicitly enumerated network conditions may be retried.

Unauthenticated mDNS/address/interface changes **MUST NOT** clear a trust-
terminal quarantine. All allowed reconnects use bounded exponential backoff
with cancellation. No failure may cause automatic pairing, credential
replacement, classic fallback, an orphan endpoint, a detached task, or an
unbounded queue.

Discovery observation loss first follows the existing configured bounded
`GraceOffline` lifecycle (currently an eight-second default); it is not itself
immediate proof that an authenticated transport failed. Grace expiry, confirmed
transport failure, shutdown, service stop, endpoint removal, credential
deletion, and `TEARDOWN` **MUST** converge on one idempotent cleanup path that
cancels workers, joins them, closes sockets, zeroizes session secrets, drains or
drops bounded audio state, and reports completion.

## 18. Observability and privacy

Diagnostics **MUST** make the state machine and failure class visible without
recording protected content. Required fields include:

- receiver stable ID, model/firmware, compatibility-row key, and interface;
- selected trust/timing/media profile and state transition;
- bounded error category and protocol status, excluding secret bodies;
- capture, encode, send, late/drop, feedback, resend, timing, reconnect, and
  teardown counters; and
- credential schema/version and match/mismatch state, never key material.

Logs and support bundles **MUST NOT** include PINs, SRP values, private/public
session material, long-term private keys, Authorization headers, raw decrypted
plists/TLVs containing identifiers, plaintext audio, or media ciphertext.
Packet capture is a developer-only explicit procedure and **MUST** be redacted
or protected as test data.

## 19. Test and release contract

No AP2 support claim is permitted until all applicable evidence is recorded in
`VALIDATION.md`. At minimum the implementation **MUST** provide:

- unit and known-answer tests for wire framing, parsers, ALAC, key derivation,
  nonces, state transitions, volume mapping, and cleanup;
- negative tests for every proof/signature/key/tag/counter/length/state check;
- fuzz targets with retained regression seeds for TLV, binary plist, RTSP,
  encrypted control, events, feedback, and retransmission input;
- a deterministic mock AP2 receiver with fault injection and transcript
  assertions;
- regression tests showing the classic RAOP path is unchanged;
- direct-sender and installed-service tests on every named supported
  model/firmware;
- pair, unpair, forget, re-pair, identity-change, sleep/wake, receiver reboot, service
  restart, network loss, interface change, IPv4, conditional IPv6, MTU,
  packet-loss, and cancellation cases;
- crash/power-loss injection before receiver commit, after receiver commit,
  after M6 validation, after fresh pair-verify, during active-record replace/
  read-back, and before recovery-journal removal;
- at least one uninterrupted 60-minute functional run in Stage 1 and an
  eight-hour installed-service soak in Stage 3 for each release-supported
  receiver profile; and
- dependency, license, advisory, SBOM, secret-handling, firewall, installer,
  privilege-boundary, and legal/MFi review.

Hardware, elevated installation, signing, legal, MFi, soak, Windows 10, ARM64,
PTP, and multi-room checks that have not executed **MUST** be recorded as
**NOT RUN**, with the exact future command or procedure. A mock, source review,
or upstream report may not be reported as a local hardware pass.

## 20. Accepted Stage 0 owner decisions

The owner accepted all canonical defaults on 2026-08-12. D-020 records the
decision. Acceptance fixes product direction but does not complete Stage 0 or
authorize an unsupported compatibility claim.

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

O-01 amends D-016's former Apple TV plus Mac pre-integration gate: the persistent
Apple TV path is the Stage 1 product gate, while transient Mac/HomePod work is
experimental and non-blocking. Owner approval is a product authorization, not
a legal determination.

At the owner's request, three readiness inputs are deliberately deferred and
must not be inferred from earlier observations: the exact available hardware/
firmware and test scheduling, the objective audio oracle, and availability of a
recovery-ready Windows test host. S0.5 and the related Stage 0 exit gates remain
open. No pairing, installation, destructive mutation, or hardware test is
authorized by accepting these defaults alone.
