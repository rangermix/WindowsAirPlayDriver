# Security and threat model

## Assets and trust boundaries

Assets are rendered user audio, receiver passwords/future pairing credentials, the privileged service/device boundary, driver integrity, and system availability. LAN advertisements and receiver responses are untrusted. Friendly device names are untrusted display data. Local administrators are outside the protection boundary; ordinary local processes are not.

## Threats and controls

### Malicious mDNS and TXT

Risks: oversized records, duplicate-key ambiguity, invalid UTF-8, identifier collision, address flood, log/control-character injection.

Controls: byte/count limits before allocation, explicit duplicate policy, lossless byte parsing before bounded conversion, normalized stable IDs, checked arithmetic, sanitized endpoint names, structured log fields, and deterministic negative/unit tests. Default registry admission is capped at 64 receivers, 16 supported endpoint slots, 256 known services, 8 services per receiver, 512 total observations, and 32 observations per receiver. The callback/event handoff is capped at 256 entries; informational pressure is coalesced and followed by a full bounded-state resynchronization. Discovery callbacks only enqueue bounded value objects. A dedicated fuzz harness/campaign remains a release gate rather than completed evidence.

### Spoofing and redirection

Classic RAOP/mDNS does not provide a modern authenticated receiver identity. A LAN attacker can advertise a plausible receiver or change DNS/address responses.

Controls: connect only to an address from the selected scoped observation; preserve interface/scope; never transfer credentials between stable identities; surface the unauthenticated-classic-protocol limitation. A future trust-on-first-use pin must be explicit. This risk cannot be claimed eliminated for classic RAOP.

### Malformed RTSP/RTP

Risks: huge headers, conflicting content lengths, response splitting, integer overflow, indefinite reads, resend amplification, packet floods.

Controls: 32 KiB total RTSP header cap, bounded body lengths, strict status/CSeq/session parsing, socket read/write/connect timeouts, checked packet math, fixed retransmission history and rate limits. Outgoing Authorization is redacted in wire traces. Treat arbitrary receiver response headers as private diagnostic output. Per-read timeouts do not impose an absolute response/cancellation deadline (DEF-002), and oversized UDP messages currently propagate a recoverable Windows error as session failure (DEF-005). These [confirmed defects](DEFECTS.md) remain release blockers.

### Audio denial of service

Risks: slow receiver, stalled acknowledgement, reconnect loop, unbounded latency/memory, capture starvation.

Controls: preallocated capture slots, bounded conversion and resend queues, non-blocking capture enqueue, oldest-audio discard plus explicit discontinuity, capped exponential backoff with jitter, idle timeout, and per-receiver cancellation.

### Local privilege and IPC

`SwDeviceCreate` requires elevation. The current installer configures the combined device-management/streaming service as `LocalSystem`. It requests no interactive desktop access, but `LocalSystem` has not been demonstrated to be the minimum viable identity. Testing and adopting a narrower account, or documenting why one cannot satisfy the required Windows APIs, is a release blocker. No general local IPC endpoint is exposed yet. A future split must authenticate clients, authorize operations, version messages, cap message sizes, and reject handle/path injection.

### Kernel attack surface

The driver has no network listener and no custom product IOCTL. PortCls property/pin requests are validated for IDs, formats, lengths, state, and IRQL. Rendered bytes are withheld from loopback when either mixed `DRMRIGHTS.CopyProtect` or `DRMRIGHTS.DigitalOutputDisable` is set, and resumption is marked discontinuous. Driver code uses no exceptions, RTTI, uncontrolled stream-path allocation, or third-party general libraries. Driver Verifier, static analysis, protected-content live tests, and HLK remain mandatory release gates.

### Credentials

Command-line passwords are discouraged because process listings and shell history can expose them. The direct sender retains that option only for isolated tests. The installed `credential-store` reads standard input, binds a machine-DPAPI blob to the canonical receiver ID through additional entropy, writes atomically beneath an Administrators/`SYSTEM`-only directory, and never copies the password into JSON. Local administrators and `SYSTEM` remain inside the trust boundary. Treat service and wire diagnostics as private records until reviewed for sensitive content.

### Firewall and listeners

mDNS uses link-local multicast UDP 5353. Mock tools listen only when explicitly
started and are not production services. Classic RAOP timing/control sockets
bind to the selected local interface and negotiated ephemeral ports. Some
receivers send their first 32-byte timing probe to the client-advertised port
while the RTSP `SETUP` request is still pending, before that local UDP socket
has sent a datagram. Windows Firewall can therefore reject the probe as
unsolicited inbound traffic and prevent the session from reaching `RECORD`.

Installation creates one local persistent Windows Firewall rule named
`WinAirPlayAudio.RaopUdpIn`. It allows inbound UDP only for the exact installed
`WinAirPlayAudioService.exe`, on the `Private` profile, from `LocalSubnet`, with
the rule enabled, action `Allow`, and edge traversal blocked. Local and remote
ports are `Any` only because RAOP negotiates ephemeral timing/control ports; the
rule does not allow TCP and does not apply to `Public` or `Domain` profiles.
The installer verifies the complete rule before starting the service and again
as a final postcondition. Clean reinstall, failed-install cleanup, and
uninstall validate ownership by the exact internal rule name, local policy
source, and canonical service path, remove that one rule, and prove its
absence. They neither match by display name nor remove user- or Group
Policy-owned rules.

### Installer

Driver/service/boot mutations require explicit elevated scripts and serialize
through a machine-wide mutex. [Build and install](build-and-install.md) owns the
operator commands. Privileged roots and OS tools come from trusted Windows
known-folder/system paths. Restored signing/catalog tools execute only after
their complete adjacent runtime inventories have been copied with replacement-
denying handles, hash-pinned in protected storage, and given a constrained DLL
search environment. Writable repository tools are never executed elevated.

Caller packages become Administrators/`SYSTEM`-owned non-reparse snapshots
before parsing/use. Signing authenticates the operator's unsigned-manifest hash,
accepts the exact payload and signs only fixed binaries. Installation separately
authenticates the final signed-manifest hash and independent catalog/executable
signer identities before removing an old installation.

Cleanup preflights exact service/firewall ownership, protected paths and
transaction names, devnodes, and provider/original-INF packages. Collisions,
query failures, untrusted owner/DACL or reparse points fail closed. It then
removes product state, verifies kernel unload before Driver Store mutation and
proves zero installed state. The active authenticated snapshot is revalidated
after cleanup; a failed fresh install cleans to zero and never restarts the
discarded service. Signed archives, certificate trust and boot policy have
separate explicit cleanup.

### Supply chain

Direct dependencies/toolchains are pinned and `Cargo.lock` is committed. Packaging emits a portable dependency inventory, license bundle, exact payload hashes and source provenance; raw path-bearing metadata stays in `.local/`. `deny.toml` controls advisories/licenses/sources. Unsigned archives require actual unsigned binaries; internal test-signed bundles require the pinned certificate and final signed-manifest hash, actual valid signatures, versions, hashes and current-builder path exclusion. Final release packaging authenticates that internal bundle and both GUI signatures before projecting only Setup and Uninstall EXEs into the user ZIP. Publication checks the exact two-member layout and the trusted signing-job archive hash. [Release preparation](releasing.md) owns package verification and the remaining independent-root comparison. Apple Bonjour binaries, unlicensed sender code and GPL sender source are not redistributed.

Source CI builds and validates packages inside the runner workspace. It has no
artifact uploads, signing credentials or release publishing jobs. A future
binary release requires signing isolation, verified cleanup, an exact source
handoff and the installed acceptance tracked in [DEFECTS.md](DEFECTS.md).

## Residual risk

Classic RAOP has no modern authenticated receiver identity, and successful mocks do not establish resistance to an active LAN attacker or physical compatibility. AP2 remains unsupported. [The risk register](risk-register.md) owns proactive hazards; [DEFECTS.md](DEFECTS.md) and [VALIDATION.md](../VALIDATION.md) own confirmed gaps and executed acceptance.
