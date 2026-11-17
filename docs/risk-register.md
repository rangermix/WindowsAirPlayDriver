# Risk register

Stable R-01–R-22 identifiers cover product and security hazards, including planned
AP2 work. Their owning contracts and acceptance gates are linked below.
[DEFECTS.md](DEFECTS.md) tracks confirmed defects; [VALIDATION.md](../VALIDATION.md)
records actual results. Historical test snapshots do not establish current-host
or current-source acceptance.

| ID | Hazard | Severity | Control and remaining exit gate |
|---|---|---|---|
| R-01 | Loopback exposes silence or synthetic audio instead of the rendered mix | Critical | [Driver real-sample/DRM contract](driver-design.md); retain correlated-tone regression and complete current-source stress/physical-output acceptance in [testing](testing.md). |
| R-02 | A successful driver build is mistaken for safe installed operation | High | Historical installed checks exist in validation; complete named-OS multi-instance/removal, Verifier and HLK acceptance before a supported binary claim. |
| R-03 | Classic RAOP receivers differ in wire/profile behavior | High | Enforce [capability profiles](airplay-compatibility-and-licensing.md), bounded mocks and named model/firmware tests with a valid physical-output oracle. |
| R-04 | Discovery, pairing or partial AP2 transport is mistaken for compatibility | High | [AP2 specification](airplay2-single-receiver-spec.md) and [stage exits](airplay2-stage-0-3-plan.md) govern claims. AP2 remains unsupported; PTP/multi-room need additional authorization and named group matrices. |
| R-05 | mDNS observations flap, become stale or collapse interface state | High | [Receiver lifecycle](receiver-state-machine.md) owns bounded pulses, leases and grace. Complete Windows reconnect/multi-interface acceptance. |
| R-06 | UDP 5353/installed-Bonjour coexistence differs from deterministic fixtures | Medium | Test native interface/firewall/coexistence behavior before claiming backend parity; keep optional backend loading safe. |
| R-07 | Queue growth or capture-callback blocking destabilizes audio | Critical | Preserve [bounded handoff/pacing/loss recovery](audio-pipeline.md) and complete installed overrun/audible/soak acceptance. |
| R-08 | Service failure leaves stale endpoints | High | Service-owned default-lifetime device handles, startup reconciliation and exact cleanup; verify forced termination/restart without active duplicates. |
| R-09 | Malicious discovery/control input exhausts or exploits parsers/logs | High | [Security limits](security.md) and deterministic negative tests; dedicated parser fuzzing remains open. Known deadline/oversize behavior is tracked in DEF-002/DEF-005. |
| R-10 | A spoofed receiver redirects audio or credentials | High | Classic identity is unauthenticated. Bind to the selected scoped observation, isolate receiver credentials and expose the residual LAN risk. Future pinning requires an explicit trust policy. |
| R-11 | Password/pairing material leaks through storage, argv or logs | High | Use protected receiver-scoped storage and redaction; keep private records under [.local/](local-artifacts.md). AP2 store authority/recovery is governed by its specification. |
| R-12 | Privileged install/signing/cleanup damages the host | Critical | [Explicit operator workflow](build-and-install.md) and [ownership/snapshot controls](security.md); complete isolated-host partial-failure, unload and zero-state cleanup acceptance. |
| R-13 | Friendly names or receiver-to-endpoint mapping become ambiguous | Medium | Container identity and optional projected-property checks in [driver design](driver-design.md); verify fresh/rename/one/two-instance behavior without registry guessing. |
| R-14 | Dependency or tool supply chain changes undermine the build | High | Exact pins/lockfile, manifest/checksum provenance, license/advisory/source policy and [release gates](releasing.md); retain clean-source evidence. |
| R-15 | Independent Windows/receiver clocks accumulate drift | High | Stateful conversion and capture-time sync exist; adaptive correction and installed 60-minute clock/CPU/memory acceptance remain open. |
| R-16 | Windows endpoint mute/volume leaves remote playback unchanged | High | The tap is pre-volume/mute. Implement exactly-once control outside real-time capture and verify receiver unity/50%/mute/unmute/change behavior (DEF-003). |
| R-17 | Undetected builder paths or nonreproducible outputs enter a release | Medium | Local remap/portable-inventory/bundle privacy gates now pass; independent-root comparison and clean-host delivery remain open (DEF-007). |
| R-18 | Receiver-initiated timing is blocked or firewall scope is widened | Critical | Preserve the exact [program/Private/LocalSubnet UDP rule](security.md#firewall-and-listeners); verify Public/Domain and policy-merge matrices without broad exceptions. |
| R-19 | AP2 reverse-engineering, crypto or distribution assumptions drift | Critical | Fail closed, pin source/firmware evidence, independently review/fuzz and preserve provenance; resolve intended distribution/branding/legal/MFi gates in plan S0.4/S3.4. |
| R-20 | AP2 AEAD nonce reuse or oversized media/resend packets breaks security/interoperability | Critical | The normative nonce/ciphertext-retry/resend/MTU invariants are in the AP2 specification; IPv4 first, IPv6 only after exact-size/PMTU/hardware evidence. |
| R-21 | AP2 receiver and local pairing state split after crash or reinstall | Critical | Follow the specified two-phase recovery journal, verified promotion, unpair/forget/orphan reporting and explicit pairing-loss preflight. |
| R-22 | AP2 network/crypto compromise inherits LocalSystem authority | Critical | The [stage plan](airplay2-stage-0-3-plan.md) requires a restricted worker or minimal authenticated endpoint broker before release; installed account/ACL acceptance remains open. |
