# AirPlay compatibility and source references

Candidate assessment: 2026-07-28; AP2 source snapshots refreshed 2026-08-12.
These are dated engineering/provenance observations, not current upstream
maintenance guarantees, Apple certification or legal clearance.

| Candidate | Upstream / maintenance | Sender and protocol | Codec / crypto | Windows fit | License | Decision |
|---|---|---|---|---|---|---|
| `philippe44/libraop` | Active through May 2026 | Classic RAOP sender; UDP audio, timing, resend, Digest | ALAC, OpenSSL RSA/AES | VS2022 project but several native dependencies | No license published; states GPL-derived inspiration | Do not ship or copy. Local interoperability oracle only after provenance review. |
| `postlund/pyatv` | Actively maintained | Mature classic RAOP sender; experimental/basic AP2 | Python crypto/miniaudio stack | Runs on Windows but embeds Python/async runtime | MIT | Primary executable behavioral oracle, not production dependency. |
| PipeWire RAOP sink | Active upstream | Classic sender; UDP/TCP, timing, resend, password | AppleLossless framing, OpenSSL | Deep PipeWire/SPA/POSIX coupling | RAOP source MIT | Primary permissive source-behavior reference; no wholesale integration. |
| PulseAudio RAOP | Mature, slower RAOP work | Classic sender; UDP/TCP, timing/resend/password | ALAC/OpenSSL | Deep libpulse/POSIX coupling | LGPL, combinations vary | Secondary oracle; linking adds obligations without Windows benefit. |
| OwnTone | Actively maintained | Full AirPlay 1 and 2 sender | FFmpeg ALAC, HAP/ChaCha, NTP/PTP | Linux/BSD/macOS server stack | GPL-2.0-or-later | Protocol/hardware oracle only; incompatible with intended distribution model. |
| `lmcgartland/airplay2-rs` / AirSend | Alpha | Classic/AP2 experiments | ALAC, HAP/ChaCha, NTP/PTP | AirSend adds Windows WASAPI | GPL-2.0 | Research only. Local pinned tests included a failing continuous-stream case and incomplete FairPlay path. |
| `akustikrausch/airplay2-sender-cpp` | Active through June 2026 | Working AP2 real-time sender reported on Apple TV 4K, HomePod, and macOS | ALAC, SRP/HAP, Ed/X25519, ChaCha20-Poly1305, encrypted events, NTP | Crypto core builds on MSVC; sender still has Qt/host coupling and no automated tests | Apache-2.0 `src/`, attributed MIT behavior, permissive dependencies | Primary implementation reference only. Do not ship until receiver proof/signature checks fail closed and the sender is independently tested. |
| Apple ALAC | Historical official codec source | Codec only | ALAC | Portable C/C++ | Apache-2.0 | Acceptable codec reference/dependency after isolated build and conformance review. |
| Original WinAirPlayAudio sender | This repository | Classic RAOP only | Minimal audited dependencies | Native Windows Rust | AGPL-3.0-only | Selected, gated by explicit profiles and tests; third-party components retain their licenses. |

Receiver-only projects such as Shairport Sync, UxPlay, shairplay, rairplay, and goplay2 are useful mock/interoperability targets but cannot satisfy the sender requirement.

## Selected compatibility tiers

The initial endpoint is created only for a `_raop._tcp` receiver whose TXT data permits the one implemented profile:

- classic RAOP rather than AirPlay 2;
- codec `cn=0` (raw PCM/L16);
- plaintext media offered through `et=0`; a mixed `et=0,4` advertisement additionally performs the AirTunes 366 type-1 `/auth-setup` preflight;
- transport `tp=UDP`;
- no protocol pairing requirement;
- stereo, signed 16-bit, 44.1 kHz, network-byte-order PCM;
- optional RTSP Digest password, loaded by the service from receiver-scoped DPAPI storage.

The `cn`, `et`, and `tp` choices are required and fail closed when missing. Classic RAOP advertisements may omit `sr`, `ss`, and `ch`; the sender still selects its fixed L16 session parameters. If any of those records is present, it must explicitly include `44100`, `16`, or `2`, respectively. A mixed list is accepted only when it explicitly contains the supported alternative.

Security evidence is aggregated across `_raop` and its companion `_airplay` record before admission. Status bits `0x8` and `0x200` require unsupported pairing; password bit `0x80` is propagated into the Digest credential gate; `0x4` is benign by itself. Key-only, empty, or malformed `pw`, `ap2`, or pairing aliases, malformed status flags, and unsupported `auth` values fail closed. An `et=0,4` receiver remains a plaintext-media profile but requires type-1 `/auth-setup`; encryption-only `et=4` is unsupported. ALAC, RSA-wrapped AES, FairPlay, TCP media, legacy pairing, and HAP pairing are rejected before a network connection.

Required before a classic profile is called real-hardware compatible:

- RTSP request and response interoperation;
- Digest challenge for password-protected receivers;
- the receiver-advertised plaintext PCM/L16 profile selected above;
- UDP media/control/timing behavior;
- sequence/timestamp, latency, timing, sync, resend, flush, and teardown;
- named receiver model and firmware evidence.

Mock success alone is not a physical-receiver compatibility claim.

Keep raw discovery records, physical receiver identifiers, network addresses,
captures, and machine-specific test records beneath `.local/`. Public evidence
uses reviewed model/firmware/profile summaries. See [local artifacts](local-artifacts.md)
and [the defect tracker](DEFECTS.md).

## AirPlay 2 boundary

AirPlay 2 is unsupported. Advertising `_airplay._tcp`, feature bits, or
accepting discovery does not establish support. A bounded single-receiver claim
requires verified HAP/pairing, fail-closed identity authentication, session-key
derivation, encrypted control/events/media, keepalive/feedback, retransmission,
NTP timing, and audio evidence on every named model/firmware. PTP, HomePod,
grouped-device, and multi-room claims require their own additional named
matrices; they are not implied by single-receiver success.

The accepted [single-receiver specification](airplay2-single-receiver-spec.md)
owns protocol/product requirements; the [Stage 0–3 plan](airplay2-stage-0-3-plan.md)
owns sequencing and exit gates. Persistent Apple TV is the first product target;
transient Mac/HomePod paths remain opt-in experimental. Stage 0 remains open.
The historical source checks below establish research inputs, not AP2 progress.

## Project licenses

Copyright (c) 2026 WinAirPlayAudio contributors. Original project code, scripts
and documentation outside the driver component use
[GNU AGPL version 3 only](../LICENSE) (`AGPL-3.0-only`). The Microsoft-derived
driver component, including project adaptations, remains under the
[Microsoft Public License](../driver/LICENSE.microsoft-samples.txt) with its
original notices. Earlier releases retain the licenses supplied with them.

Dependencies and the Inno Setup wizard runtime retain their upstream licenses;
see [third-party notices](../THIRD_PARTY_NOTICES.md). Apple Bonjour binaries and
third-party GPL sender code are not included in the product. The
[release procedure](releasing.md#license-and-corresponding-source-handoff)
requires a reviewed Corresponding Source handoff for AGPL binary releases.
Project licensing does not establish Apple certification, protocol rights or
general distribution clearance.

## Bonjour redistribution

The repository redistributes neither `dnssd.dll`, `mDNSResponder.exe`, nor Apple's installer. Apple's mDNSResponder source is largely Apache-2.0 and `dns_sd.h` uses a permissive notice, but that does not establish current rights to redistribute Apple's Windows binary product or branding. The default process-local `mdns-sd` dependency is MIT/Apache-2.0. An optional backend may interoperate with an already-installed system copy by safely loading the System32 DLL.


## Historical AP2 source checks

These Windows checks predate implementation. No source was imported into the
product, no AP2 pairing or media was attempted, and no AP2 hardware/PTP/multi-room
acceptance is implied. Raw investigation records remain under `.local/`.

| Reference snapshot | Recorded Windows result and boundary |
|---|---|
| `akustikrausch/airplay2-sender-cpp` `8c4034263f1c265d25b3cfb88a090624760ad22a` | The Qt-free `airplay_crypto` target configured/built with VS2026/MSVC. Canonical CMake exposed no full sender or automated test target; authentication behavior required fail-closed redesign. |
| C++ PR snapshot `d4fd7163c87dd04ffd94bdd58f4ff6b270d5e5c8` | Temporary-checkout crypto/sender/CLI and generic transport-loopback checks passed. The review snapshot was `CHANGES_REQUESTED`; it did not test HAP, encrypted RTSP/events/media, ALAC, timing or hardware. |
| `lmcgartland/airplay2-rs` `a7f019fe6246ebd9701201a8a5c31e9a15243956` | Locked workspace compile failed on MSVC because `airplay-audio/src/rtp.rs` uses Unix descriptors/socket constants. |
| Rust fork snapshot `a43e1220dbae7a9080f52027fc59fe04bb3e4bbd` | The unmerged workspace referenced a missing CLI member. Pure-module checks passed only after a temporary workspace edit; transport/mDNS remained POSIX, with no Windows or hardware evidence. |
| `Pabldi08/AirSend` `ee55c8d5d2aa15959bd7e936a73fe9ff7d487758` | The pinned protocol fork, `cap-core`, WASAPI capture and encoding crates passed `cargo check`. Full Tauri workspace checking stopped at the absent unbuilt `ui/dist`; no complete-product pass. |

Dependency selection must be refreshed and reviewed at the exact revision when
implementation begins, following plan S0.4. Source licensing alone does not
establish protocol, patent, trademark, branding or MFi rights. GPL or unlicensed
references are not production dependencies or source/design templates.

Primary research sources:

- Apple [MFi FAQ](https://mfi.apple.com/en/faqs),
  [program overview](https://mfi.apple.com/en/how-it-works),
  [accessory resources](https://developer.apple.com/accessories/),
  [custom audio](https://developer.apple.com/documentation/AVFAudio/playing-custom-audio-with-your-own-player)
  and [AirPlay audio guidance](https://developer.apple.com/videos/play/wwdc2023/10238/).
- C++ sender [source](https://github.com/akustikrausch/airplay2-sender-cpp),
  [roadmap](https://github.com/akustikrausch/airplay2-sender-cpp/blob/main/ROADMAP.md)
  and [security limits](https://github.com/akustikrausch/airplay2-sender-cpp/blob/main/SECURITY.md).
- [Rust sender](https://github.com/lmcgartland/airplay2-rs),
  [AirSend](https://github.com/Pabldi08/AirSend),
  [OwnTone](https://owntone.github.io/owntone-server/) and
  [its releases](https://github.com/owntone/owntone-server/releases),
  [pyatv protocol limits](https://pyatv.dev/documentation/supported_features/),
  [Shairport Sync](https://github.com/mikebrady/shairport-sync) and
  [NQPTP](https://github.com/mikebrady/nqptp).
