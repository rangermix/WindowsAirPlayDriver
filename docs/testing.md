# Testing

## Available automated suite

```powershell
.\build.ps1 -UserModeOnly -Configuration Debug
.\build.ps1 -Test
```

`-Test` runs source hygiene, version/release-tooling fixtures, formatting, warnings-denied Clippy and the locked workspace suite, including process tests. Use `-IntegrationTest` alone for a focused run of the three tool-process cases: Digest RAOP sender/receiver interoperability, discovery add/grace/remove, and forced child-timeout cleanup. The RAOP fixture waits for receiver readiness and uses an explicit short sample with an exact frame assertion. Update, address-change, bounded-parser, and interface-specific registry semantics have deterministic in-process coverage. `-Configuration Release` tests optimized binaries. Keep raw records in `.local/diagnostics/`; publish sanitized results in `VALIDATION.md` and update [DEFECTS.md](DEFECTS.md). See [local artifacts](local-artifacts.md).

After the explicit test-machine boot-policy/certificate setup, the guarded
end-to-end local deployment can be launched by double-clicking
`Test-Build-Package-Sign-Install.cmd`. It runs the selected-configuration workspace gate before
delegating build/package, protected signing, destructive clean reinstall,
rollback, and installed postconditions to the existing scripts. Preview its
exact plan without elevation or mutation:

```powershell
.\installer\Invoke-TestBuildPackageSignInstall.ps1 -WhatIf
```

Individual diagnostics:

```powershell
cargo run --locked -p winairplay-tools --bin airplay-discover -- --duration-seconds 15
cargo run --locked -p winairplay-tools --bin endpoint-list -- --json
New-Item -ItemType Directory -Path .\.local\diagnostics -Force | Out-Null
cargo run --locked -p winairplay-tools --bin diagnose -- --output .\.local\diagnostics\diagnostics.json
```

`diagnose` writes the requested file but does not create a missing parent directory.

## Mock discovery

Start the advertiser in one terminal and discovery in another:

```powershell
cargo run --locked -p winairplay-tools --bin mock-bonjour-advertiser -- --name "Mock Living Room"
cargo run --locked -p winairplay-tools --bin airplay-discover -- --duration-seconds 15 --json
```

The manual two-process exercise is best-effort on Windows because same-host daemons sharing UDP 5353 do not reliably receive every multicast packet; stop the installed service first if it owns the competing browser. Use `.\build.ps1 -IntegrationTest` for deterministic custom-port process coverage. That fixture asserts two complete add, grace-start, and final-removal lifecycles for the same identity. Resolution updates, bounded TXT parsing, interface-aware dedupe, canonical identity across hostname/address change, and grace cancellation have separate registry/unit coverage. Live multi-homed removal remains **NOT RUN**; merely seeing a service name is insufficient evidence.

## Mock sender

Start the receiver and then send the deterministic source:

```powershell
cargo run --locked -p winairplay-tools --bin mock-raop-receiver -- `
  --bind 127.0.0.1:5000 --expected-frequency 997 `
  --expected-duration 1 --expected-amplitude 0.25
cargo run --locked -p winairplay-tools --bin airplay-send -- `
  --receiver 127.0.0.1:5000 --frequency 997 --duration 1 --amplitude 0.25
```

The receiver must validate RTSP order/CSeq/session, Digest challenge when enabled, RTP sequence and timestamp progression, decoded/reconstructed frequency, duration, channels and amplitude, explicit mid-session `FLUSH` recovery with an immediate `0x90` restart sync, teardown, injected resend handling, and bounded timeout/reset behavior. Startup must not contain `FLUSH`.

The transport unit suite must also inject `WouldBlock`, `Interrupted`, and
`TimedOut` while sending one already-packetized RTP datagram. It must prove
byte-identical retry, bounded timing/retransmission servicing, a real deadline,
no retry of a partial UDP send, and transactional sequence/timestamp/marker,
pacing, statistics, and retransmission-history updates. Service tests must
distinguish graceful idle closure, which sends a pending partial packet, from
transport-failure abort, which sends no post-failure audio before `TEARDOWN`.

## Driver and virtual endpoint test

Use an isolated, elevated, recovery-ready test machine. Complete the explicit
[signing and installation procedure](build-and-install.md#prepare-and-deploy-on-a-test-machine)
for the exact source/package being accepted; preserve configuration/credentials/
logs you intend to recreate before confirming clean reinstall. Enumerate the
resulting endpoints:

```powershell
& "$env:ProgramFiles\WinAirPlayAudio\endpoint-list.exe" --json
```

Advertise one mock receiver, wait at most the configured creation deadline, and confirm one endpoint with the expected deterministic container. The advertised Bonjour/AirPlay receiver name must appear within the localized MMDevice label; do not require an English `Speakers (...)` wrapper. Change the advertised name and confirm the endpoint is recreated with the same container and the new sanitized name. Advertise a second identity and confirm two distinct containers. Remove one and confirm the other remains.

Run `mock-raop-receiver` on port 7000 and advertise the same address/profile with `mock-bonjour-advertiser`. Read the exact container and private receiver ID with `endpoint-list`, then render through that container:

```powershell
& "$env:ProgramFiles\WinAirPlayAudio\endpoint-tone.exe" `
  --container-id <container-guid> --frequency 997 --duration 3 --amplitude 0.25
```

The service must require the deterministic container before capture. If the optional private receiver property is present it must be canonical and match; an absent property is allowed, while malformed, unreadable, or mismatched values fail closed. Have the mock receiver verify the signal. The driver exposes only a pre-volume/mute tap, so the endpoint-volume/mute product requirement needs a separate control path before this matrix can pass: verify unity, 50%, mute, unmute, and rapid changes at the mock receiver. Do not route by friendly-name matching.

Before involving a receiver, run the installed known-tone loopback acceptance test against the exact product container:

```powershell
$env:WINAIRPLAY_TEST_CONTAINER_ID = '<container-guid>'
cargo test --locked -p winairplay-service --lib `
  wasapi::tests::live_loopback_captures_rendered_tone -- `
  --ignored --exact --nocapture
Remove-Item Env:WINAIRPLAY_TEST_CONTAINER_ID
```

This test renders a local 997 Hz tone to that endpoint, captures from the same endpoint, requires at least half a second of non-silent real frames, and requires normalized correlation of at least 0.50 with the rendered 997 Hz reference. A non-target 440 Hz unit fixture proves the frequency check rejects unrelated non-silence. It does not contact an AirPlay receiver. Historical results belong in [VALIDATION.md](../VALIDATION.md); current-source acceptance must rerun the test.

Force-stop the service:

```powershell
Stop-Process -Name WinAirPlayAudioService -Force
```

Confirm receiver devnodes become non-present, restart the service, re-advertise, and confirm stable container identity without duplicate active endpoints.

Record the installed source/version/signing state locally and verify the exact
[firewall contract](security.md#firewall-and-listeners). The signing/install guide
owns package trust anchors; a test result cannot replace those checks.

## Physical receiver

Record exact model, firmware, `_raop._tcp` TXT record, local interface/address family, transport, codec, encryption, and password mode in `.local/diagnostics/`. Use only reviewed model/profile summaries in public evidence; withhold physical identifiers, addresses, raw TXT records, and unrelated traffic. Then:

```powershell
cargo run --locked -p winairplay-tools --bin airplay-discover -- --duration-seconds 20 --json
cargo run --locked -p winairplay-tools --bin airplay-send -- `
  --receiver <address:rtsp-port> --local-address <discovery-interface-address> `
  --frequency 997 --duration 10 --amplitude 0.25 `
  --input-rate 48000 --input-channels 2 --tier classic --codec pcm `
  --encryption none --pairing none --transport udp --timeout-ms 3000
```

Add `--auth-setup` when an otherwise plaintext-capable AirTunes 366 receiver advertises mixed `et=0,4`. Measure setup/start latency, audible/result latency, reconnect, removal, packet loss/resends, CPU, and working set. Test Ethernet/Wi-Fi, IPv4/IPv6, address change, interface disable, receiver restart, sleep/resume, password challenge, and the Private/Domain/Public firewall matrix. A named profile is supported only after these results are recorded.

For the WLAN backpressure regression, use the installed fixed build on a
trusted Private WLAN and retain the service log in `.local/diagnostics/` from
before playback through idle teardown. Acceptance requires a session to pass the former 47-packet
boundary, remain streaming without `send RTP audio datagram` errors or
reconnect/discard loops, close with `graceful=true`, and preserve the intended
startup content and measured latency. Repeat after switching away from and back
to the endpoint, and while the receiver is initially occupied by another
source.

Do not run the direct sender merely because `_airplay` is present. A fresh `_raop` record must select the supported classic plaintext-PCM/UDP profile and the advertised RTSP port must be reachable. Live Apple TV/Mac records with pairing-required status are intentionally ineligible. An established RTSP/RTP session is not physical-output acceptance. Prove the capture/cable/input path with an independently known analog source before using it as the playback oracle.

## Soak and fault injection

The release soak is at least 60 minutes with mock loss, delayed RTSP, resend bursts, receiver restart, interface change, capture overrun, and service stop. Record initial/final/private working set, queue high-water marks, sequence/timestamp drift, underrun/overrun, resend count, and recovery time. Assert no monotonic memory growth.

Driver Verifier and HLK must run only on a dedicated recovery-capable host. They, the soak, Windows 10, and ARM64 are **NOT RUN** here.
