# Release checklist

Every checked item requires a link or exact record in `VALIDATION.md`.

Current confirmed gaps are in [DEFECTS.md](DEFECTS.md); actual results are in
[VALIDATION.md](../VALIDATION.md). Public source and binary release gates remain
open. This checklist owns the release decision rather than a historical audit.

## Source and dependencies

- [ ] Review the exact public source commit, advertised refs and Git identity metadata. Verify the exact intended public repository and its workflow permissions (DEF-001).
- [ ] Verify the upstream driver resource notice and retained MS-PL text (DEF-026).
- [ ] Verify the first public-source commit with hosted Debug/Release CI.
- [x] Exact Rust, Visual Studio, SDK, WDK, and sample pins are recorded.
- [x] Final-source format, Clippy/warnings, unit, integration, and fault tests pass.
- [x] Locked Windows dependency advisory/license/source policy passes; adapted-driver license/attribution is packaged and verified. This is not broader legal/MFi clearance.
- [ ] Verify sanitized dependency metadata and checksums in the final binary delivery.
- [x] No GPL/unlicensed sender or Apple Bonjour binaries are distributed.
- [x] No secrets, private certificates, raw audio, dumps, or generated logs are packaged.
- [ ] Public artifacts remove or remap absolute builder paths and have a reproducibility check. Local path/privacy gates pass; two-root comparison remains NOT RUN (DEF-007).

## Driver

- [x] Native-x64 Debug and Release driver builds complete with the pinned WDK packages.
- [x] Static analysis and INF verification pass with every warning disposition recorded.
- [ ] Production catalog/clean-host acceptance. Test catalog signatures and INF/SYS membership pass on the fresh CI signing runner using its explicit test root; this is not production `/kp` or installed acceptance.
- [ ] One and two-instance load/render/clock/reset/remove tests pass.
- [ ] Known-tone WASAPI loopback proves actual rendered samples.
- [ ] Endpoint volume/mute behavior passes on the minimum OS.
- [ ] Driver Verifier campaign has no bug check/leak finding.
- [ ] Applicable HLK tests pass or justified exceptions are recorded.
- [x] Independent kernel-safety review has no unresolved high-severity finding.

## Discovery and lifecycle

- [ ] RAOP and AirPlay metadata browsing works on Ethernet/Wi-Fi, IPv4/IPv6.
- [x] Duplicate/multi-interface/address-change/TTL/grace tests pass.
- [x] Malformed/oversized TXT deterministic unit and fault tests pass.
- [ ] A dedicated parser fuzz harness/campaign completes with its corpus and findings archived.
- [ ] One/two receiver endpoints use stable distinct containers.
- [ ] Remove/re-add, interface change, sleep/resume, service restart, and forced kill leave no active stale endpoint.
- [x] Deterministic classifier tests reject unsupported profiles before endpoint creation.
- [ ] Corrected installed service withholds pairing-required/unsupported live advertisements.

## Sender and audio

- [x] Mock validates RTSP order, response bounds, Digest, RTP timestamps/wrap, timing, resend, flush, teardown, timeout/reset/restart.
- [x] Audio conversion matrix passes, including discontinuity and long drift.
- [x] Bounded queue/retry assertions and overrun diagnostics pass.
- [ ] Each claimed physical receiver model/firmware/profile has recorded playback evidence.
- [ ] 60-minute soak shows no monotonic memory growth and records CPU/memory/loss/resend/underrun/overrun.
- [ ] Independent real-time/audio and network-protocol reviews have no high-severity finding. DEF-002 leaves RTSP deadlines/cancellation open; DEF-005 records oversized UDP handling.

## Security and installer

- [ ] Threat model and residual classic-RAOP spoofing risk are current.
- [ ] Parser fuzzing remains to run; timeout, flood, log-injection, and checked-arithmetic evidence is recorded separately.
- [ ] Persistent credentials use Windows-protected storage and are redacted.
- [ ] Service account/privileges are the tested minimum.
- [ ] Verify trusted PowerShell module lookup during elevated installation and removal (DEF-027).
- [ ] Private-profile mDNS and RAOP timing/control pass with only the exact `WinAirPlayAudio.RaopUdpIn` program-scoped inbound-UDP rule (`LocalSubnet`, edge traversal blocked); the rule does not apply on Public or Domain profiles.
- [ ] Fresh install, repeat clean reinstall, partial-install cleanup, and standalone uninstall pass.
- [ ] Present/non-present receiver devnodes, service, driver package, generated config, credentials, and logs all clean up.
- [ ] Fresh install, clean reinstall, failed-install cleanup, and uninstall create, validate, replace, and remove only the exact product firewall rule; no product-rule residue or Windows Event Log source remains.
- [ ] Independent security and installer reviews have no unresolved high-severity finding. DEF-002 is open; current privileged transaction acceptance remains incomplete.

## Claims and handoff

- [ ] README and known limitations match the final executed evidence. Reconcile historical installed/source wording and add the new audit findings.
- [x] AirPlay 2 is not claimed unless its separate full acceptance matrix passes.
- [x] Windows 10/ARM64 are not claimed unless tested.
- [ ] Production signing submission and returned artifacts are archived.
- [ ] Recovery/uninstall procedure is tested by someone other than the author.
- [ ] Final changed-file review is complete for the intended release commit.
