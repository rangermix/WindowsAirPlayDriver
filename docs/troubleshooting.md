# Troubleshooting

For choosing a Windows output or routing one app, start with the
[usage guide and screenshots](usage.md). The [documentation overview](README.md)
links to installation, compatibility and current limitations.

## Driver build reports MSB8020

Symptom:

```text
The build tools for WindowsKernelModeDriver10.0 cannot be found.
```

Cause: the Visual Studio WDK platform integration is absent. Restored WDK NuGet packages are not the MSBuild platform toolset.

Fix: install a matching Windows SDK/WDK pair and Visual Studio driver integration from Microsoft's WDK download page, open a fresh terminal, then run:

```powershell
.\build.ps1 -Driver -Configuration Debug
```

## `SwDeviceCreate` is access denied

The API requires administrator access. Confirm the installed service account/privileges and run the exact installer from an elevated PowerShell. Do not weaken ACLs or move endpoint creation into an interactive unelevated process. Use:

```powershell
cargo run --locked -p winairplay-tools --bin diagnose
```

## Receiver is discovered but no endpoint appears

Check the discovery record's compatibility reason first. AP2-only, FairPlay-only, pairing-required, unknown codec/encryption, missing stable identity, or malformed TXT receivers intentionally receive no functional endpoint.

If the profile is supported, inspect:

- service state and recent structured logs;
- driver package staging/signature;
- software-device callback HRESULT and returned devnode ID;
- Device Manager problem code;
- endpoint enumeration by expected container GUID;
- AudioEndpointBuilder service state.

Do not search by friendly-name text or edit MMDevice registry keys.

## Endpoints appear only after running diagnostics

Diagnostics do not create endpoints. Check the service start configuration and timestamps:

```powershell
sc.exe qc WinAirPlayAudioService
sc.exe query WinAirPlayAudioService
Get-Content "$env:ProgramData\WinAirPlayAudio\logs\service.jsonl" -Tail 100
```

Current source requests immediate automatic service start and uses bounded active browse pulses. A receiver must still advertise a compatible `_raop._tcp` service; `_airplay._tcp` alone is withheld. Check the [lifecycle timers](receiver-state-machine.md#timers) rather than inferring endpoint creation from diagnostic-tool timing.

## Every endpoint has the generic WinAirPlayAudio name

The service supplies the parent `DEVPKEY_Device_FriendlyName`; AudioEndpointBuilder
composes the MMDevice label from it. Compare the active driver/source version
and container mapping. If an obsolete generic endpoint remains, use the
[authenticated clean-reinstall procedure](build-and-install.md#clean-reinstall-and-failure-recovery)
to recreate device state. Do not edit MMDevice registry property stores.

## Duplicate endpoint

Collect diagnostics and compare canonical receiver IDs, container GUIDs, service/interface observation keys, and present devnodes. An IP or hostname change must not alter identity. A new resolved snapshot that retains a second interface must preserve that observation; a high-level `ServiceRemoved` event removes the complete named service and relies on grace/re-resolution.

There is no uninstall diagnostic mode. Inspect first with `diagnose` and `endpoint-list`; to preview the scoped uninstall actions, use:

```powershell
.\installer\Uninstall-Driver.ps1 -ConfirmRemoval -WhatIf
```

Do not delete broad audio classes or firewall-rule groups. Actual cleanup
requires the same command without `-WhatIf` and removes only exact
`ROOT\WinAirPlayAudio`/provider/original-INF matches plus the exact locally
owned `WinAirPlayAudio.RaopUdpIn` rule.

## Discovery finds nothing

Confirm the receiver advertises `_raop._tcp.local.`, not only `_airplay._tcp.local.`. Check active interface/profile, VPN/virtual adapters, multicast reachability, UDP 5353 firewall policy, IPv6 scope, and whether installed Bonjour coexists with the process-local backend.

Run:

```powershell
cargo run --locked -p winairplay-tools --bin airplay-discover -- --duration-seconds 30 --json
ipconfig.exe /all
Get-NetFirewallProfile
```

Inspect [receiver lifecycle](receiver-state-machine.md) for query windows,
complete missed epochs and grace deadlines. Discovery-to-endpoint time is a
measured target; a browse pulse is not an arrival guarantee. Inspect the fresh
record's exact profile and advertised RTSP port before diagnosing cache delay.

## `SETUP` times out before `RECORD`

A receiver can send a 32-byte UDP timing probe to the client-advertised
ephemeral `timing_port` while the RTSP `SETUP` request is still pending. If
Windows Firewall rejects that first inbound datagram, authentication and
`ANNOUNCE` can succeed but the session never reaches `RECORD`. The usual
signature is a logged `SETUP` request followed by
`RAOP read RTSP response: timed out after 3s` (or the configured I/O timeout),
with a packet capture showing the receiver's timing probe and no response from
the service.

Inspect the installed rule and active network category without changing either:

```powershell
$rule = Get-NetFirewallRule `
  -PolicyStore PersistentStore `
  -Name 'WinAirPlayAudio.RaopUdpIn' `
  -ErrorAction Stop
$rule | Format-List Name, DisplayName, Enabled, Profile, Direction, Action,
  EdgeTraversalPolicy, PolicyStoreSourceType
$rule | Get-NetFirewallApplicationFilter | Format-List Program
$rule | Get-NetFirewallPortFilter |
  Format-List Protocol, LocalPort, RemotePort
$rule | Get-NetFirewallAddressFilter |
  Format-List LocalAddress, RemoteAddress
$rule | Get-NetFirewallInterfaceTypeFilter | Format-List InterfaceType
$rule | Get-NetFirewallServiceFilter | Format-List Service
Get-NetConnectionProfile |
  Format-Table InterfaceAlias, InterfaceIndex, NetworkCategory, IPv4Connectivity
```

The exact expected definition is:

- name `WinAirPlayAudio.RaopUdpIn`, local policy source, enabled;
- inbound `Allow`, profile `Private`, edge traversal `Block`;
- program `%ProgramFiles%\WinAirPlayAudio\WinAirPlayAudioService.exe`;
- protocol UDP, local and remote ports `Any`;
- local address and interface type `Any`, remote address `LocalSubnet`, service
  `Any`.

The [security contract](security.md#firewall-and-listeners) owns this exact
rule definition. Historical A/B evidence is summarized in
[VALIDATION.md](../VALIDATION.md), separately from physical-output acceptance.

The rule intentionally does not apply when the selected receiver interface is
`Public` or `Domain`. Do not create a broad temporary exception or edit the
rule in place. Reinstall the authenticated package to recreate and verify the
owned rule. If cleanup reports that the exact internal name belongs to another
program, preserve the error and resolve that ownership collision explicitly;
do not remove rules by display-name pattern.

## Sender fails with unsupported profile

The discovery record must name the unsupported capability, including codec, sample rate/size/channels, encryption, pairing/authentication, or transport. Do not override it to send incompatible/raw data. Compare the TXT profile and exact receiver firmware with `docs/airplay-compatibility-and-licensing.md`.

## Audio is silent, distorted, or delayed

Inspect capture format, per-loss discontinuity records, conversion format, RTP
timestamps, configured/effective sync offset, startup backlog, resends, and
idle/reconnect events. Silence reported by WASAPI is deliberately zero-filled.
Current source marks the first queue survivor and recovers the RTP timeline
without RTSP `FLUSH`; stale audio outside the latency budget is discarded
instead of growing delay indefinitely. A `TIMESTAMP_ERROR` alone invalidates
capture-clock placement but is not treated as lost audio.

`raop_sync_latency_ms` is the sender sync offset, not total speaker latency.
The current service default is 500 ms, valid values are 250 through 3,000 ms,
and a larger valid `Audio-Latency` returned by the receiver takes precedence.
AirPlay and receiver hardware add their own buffering. Use 250 ms only as a
named physical experiment; do not describe it as stable until audible and soak
testing passes.

If a pre-fix build repeatedly enters streaming and then reports `send RTP audio
datagram: timed out after 3s` within a few milliseconds—often near 47
1,420-byte packets—the message represents immediate nonblocking UDP
backpressure, not an elapsed three-second wait. The corrected sender retries
the same packet while the socket drains, bounded by the packet's remaining
playout deadline. A sustained fixed-build session must advance beyond that
packet boundary without teardown/reconnect or stale-capture discard loops.

If the log reports repeated capture losses after the startup backlog is near
zero, retain the timestamps and queue counters. Fixed-ratio resampling does not
yet discipline long-run Windows/receiver clock mismatch, so a recurring
long-soak trend remains a separate investigation rather than a reason to
increase the queue and hide latency.

First distinguish three stages in the structured service log:

1. `mapped audio endpoint`;
2. successful WASAPI capture startup/non-silent frames;
3. RTSP/RAOP session activity.

Repeated “endpoint ... did not appear within 20s” errors despite a visible
endpoint indicate an identity-mapping failure. Run the ignored local known-tone
test in [testing](testing.md) against the exact container before investigating
network delivery. It separates actual capture from RAOP session success.

A receiver reaching `RECORD` or receiving packets does not prove audible output.
First prove the physical capture/cable/input oracle with an independent known
source. Current-source physical playback and corrected WLAN acceptance remain
open in [DEF-010](DEFECTS.md#def-010--installed-and-hardware-acceptance).

## Service will not stop

A partial RTSP response can currently retain a worker beyond its intended operation bound; see [DEF-002](DEFECTS.md#def-002--absolute-rtsp-deadlines-and-cancellation). Preserve diagnostics/dumps under `.local/` before forced termination. Verify whether default-lifetime devices become non-present and record stale devnodes before ownership-scoped cleanup. Do not treat a clean build as proof of bounded service shutdown.
