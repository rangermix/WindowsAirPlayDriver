# Using WinAirPlayAudio

[Documentation overview](README.md) · [Installation and removal](build-and-install.md)

WinAirPlayAudio gives each eligible receiver a Windows playback device. The
service discovers receivers automatically; there is no separate player window.
This remains an experimental classic AirPlay prototype for controlled testing.

## Receiver compatibility

Use Windows 11 x64, version 24H2 or newer, with a receiver on the same reachable
local network. The receiver must advertise classic RAOP with plaintext stereo
16-bit PCM/L16 at 44.1 kHz over UDP. Receivers that require AirPlay 2, PIN/HAP
pairing, ALAC or encrypted media do not get an output device.

Optional classic Digest passwords are implemented, but password provisioning
uses the protected [credential tooling](security.md#credentials), not a Windows
pairing dialog. The [compatibility guide](airplay-compatibility-and-licensing.md#selected-compatibility-tiers)
owns the exact admission rules. An AirPlay logo, discovery result or visible
endpoint is not a verified model/firmware playback claim.

## Choose an output

1. Complete [test-machine setup](build-and-install.md#prepare-and-deploy-on-a-test-machine),
   turn on the receiver and keep it reachable on your local network.
2. Open **Settings → System → Sound** and find the receiver whose name ends
   in **(AirPlay)**. Select it to route the default Windows output there.
3. Start audio in an application. An app with an explicitly selected output
   may need its own output changed or playback restarted.
4. To return to local playback, select your normal speakers or headphones.

You can also open the taskbar sound output picker: click the speaker area,
then the output selector beside the volume slider and choose the receiver.
The exact controls vary with the Windows version and display language.

## Open the volume mixer from the taskbar

Right-click the taskbar speaker icon and select **Open volume mixer**. Under
**System → Output device**, the same AirPlay receiver appears in the device list.
Selecting it changes the system output. To route just one application, expand
its entry under **Apps** and choose the receiver as that app's output device.
The app must have an audio session to appear in the list.

## Volume, mute and delay

**Use the receiver's own volume and mute controls.** The driver currently
captures audio before Windows endpoint master-volume and mute are applied.
The visible Windows controls therefore cannot be relied on to silence or
adjust remote playback. App routing does not fix this limitation; the open
work is tracked in [DEF-003](DEFECTS.md#def-003--endpoint-master-volume-and-mute).

AirPlay adds buffering and delay. Video lip-sync, gaming latency and
long-duration playback have not passed acceptance. See
[known limitations](known-limitations.md) before relying on the output.

## If the receiver does not appear or play

- Confirm it is powered on, reachable on the same network and supports the
  narrow classic receiver profile above. Unsupported receivers are withheld.
- Check [discovery troubleshooting](troubleshooting.md#discovery-finds-nothing)
  and [missing endpoints](troubleshooting.md#receiver-is-discovered-but-no-endpoint-appears).
- For a visible but silent output, follow
  [audio troubleshooting](troubleshooting.md#audio-is-silent-distorted-or-delayed).
  A visible device does not prove successful network or speaker playback.
- Follow [removal and recovery](build-and-install.md#remove-the-product-and-test-machine-trust) to uninstall.
  Follow the restart instructions for the removal procedure you used.

When reporting a problem, include the source commit, Windows version, receiver
model/firmware and reproduction steps under [Contributing](../CONTRIBUTING.md).
Remove account details, receiver identifiers, network addresses and credentials
from screenshots and logs before sharing.
