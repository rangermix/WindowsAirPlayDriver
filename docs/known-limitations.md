# Known limitations

WinAirPlayAudio remains experimental. The implemented sender supports only the
[classic plaintext PCM/L16 UDP profile](airplay-compatibility-and-licensing.md).
AirPlay 2, ALAC, encrypted classic media, TCP media and pairing are unimplemented;
unsupported advertisements create no endpoint. Windows 10 and ARM64 are not
validated platforms.

## Product and reliability gaps

| Limitation | Tracking |
|---|---|
| The loopback tap is pre-volume/mute. Windows endpoint mute/volume cannot be relied on to silence/control remote playback; use receiver controls. | [DEF-003](DEFECTS.md#def-003--endpoint-master-volume-and-mute) |
| A trickling RTSP response can exceed the intended operation/shutdown bound. | [DEF-002](DEFECTS.md#def-002--absolute-rtsp-deadlines-and-cancellation) |
| Oversized UDP control/timing messages can abort a recoverable Windows session. | [DEF-005](DEFECTS.md#def-005--recover-from-oversized-udp-messages) |
| Network parsing and endpoint management still share `LocalSystem`; minimum privileges are unvalidated. | [DEF-004](DEFECTS.md#def-004--minimum-service-privileges) |
| Fixed-ratio resampling does not adapt to long-run Windows/receiver clock mismatch. Current-source physical playback, corrected WLAN/latency/reconnect and 60-minute soak acceptance remain incomplete. | [DEF-010](DEFECTS.md#def-010--installed-and-hardware-acceptance) |
| Builder-path gates pass locally, but independent-root reproducibility and clean-host delivery are untested. | [DEF-007](DEFECTS.md#def-007--public-artifact-layout-and-reproducibility) |

Shared event-mode capture is the MVP. Polling render buffers, exclusive-mode
application audio and pre-24H2 semantics are unsupported. Protected-content
rights can deliberately withhold loopback; see [driver design](driver-design.md).

Direct UDP 5353/installed-Bonjour coexistence, multi-interface removal,
IPv4/IPv6, Public/Domain firewall profiles, interface changes and sleep/resume
still need the named hardware matrix in [testing](testing.md). Bonjour backend
parity is not implemented or claimed.

Classic discovery has no modern authenticated receiver identity. The type-1
`/auth-setup` preflight does not establish verified identity. Receiver passwords
use protected storage, but the direct sender's test-only `--password` option can
leak through shell history/process listings. Follow [security](security.md) and
[build/install](build-and-install.md) on trusted private networks.

Historical local-render and wire/session success does not establish current
physical compatibility. [VALIDATION.md](../VALIDATION.md) owns executed evidence;
[DEFECTS.md](DEFECTS.md) and the [release checklist](release-checklist.md) own open
acceptance. Machine records and original diagnostics stay in `.local/`.
