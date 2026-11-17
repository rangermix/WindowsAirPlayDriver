# Driver design

## Purpose and boundary

`WinAirPlayAudio.sys` is a minimal PortCls/WaveRT render sink with an internal rendered-mix loopback pin. It lets AudioEndpointBuilder create an ordinary shared-mode Windows render endpoint, consumes/clocks audio written by the audio engine, and exposes only those consumed bytes to the service. Remote network timing never controls its WaveRT clock.

The source is derived from Microsoft Windows Driver Samples `audio/simpleaudiosample` at commit `2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89`, under the Microsoft Public License. Full SysVAD was rejected because it carries substantially more paths and its sample loopback behavior is not suitable as the actual rendered-mix acceptance path.

## PnP model

The INF matches `ROOT\WinAirPlayAudio`. The same package can bind to multiple software devnodes. User mode supplies:

- enumerator `WinAirPlayAudio`;
- stable UUID-derived instance token;
- deterministic receiver container GUID;
- friendly device description and standard `DEVPKEY_Device_FriendlyName`;
- private receiver-identity property `{54B65A8E-7CD3-4F7B-953B-59A21C2E5CDD}`, PID 2;
- private display-name property in the same set, PID 3.

Each device object owns its adapter, topology miniport, and WaveRT miniport. No global singleton contains per-receiver state. A second receiver must not alter the first instance's pin, clock, or property state.

## Audio path

The MVP exposes one system-render pin, one `KSNODETYPE_AUDIO_LOOPBACK` capture pin, and one bridge pin at stereo, signed 16-bit PCM, 48 kHz. The loopback pin is not a microphone or public capture endpoint. Shared-mode applications may render other formats because the Windows audio engine converts to the endpoint mix format.

The render WaveRT cyclic buffer and notification/event behavior follow the sample's PortCls contracts. Render position advances monotonically from the local high-resolution clock while the stream is running, wraps at the cyclic buffer boundary, and stops/reset deterministically. Before advancing the render cursor, the driver copies the exact consumed region into each running loopback ring using bounded wrap-aware chunks. Loopback position and notifications advance only for copied data; no wall-clock capture progress, sample tone, kernel file output, or detached copy path exists. Delayed intervals copy only the newest suffix retained by both rings and mark a discontinuity.

Each render-ring slot carries an exact 64-bit committed-packet tag. Rejected
late/overrun writes invalidate the overwritten slot, delayed-DPC recovery stays
within resident data, and packet counts/notifications advance only at actual
linear packet boundaries. A stream generation, locked snapshot and final
conditional commit prevent concurrent readers or STOP/restart from publishing
stale capture progress. Polling render buffers have no trustworthy producer
commit boundary and are rejected.

The driver intentionally registers no custom network-facing IOCTL and no private kernel/user audio-copy protocol. On Windows 11 24H2 it implements `KSPROPERTY_AUDIOLOOPBACK_TAPPOINT_CAPS`, advertises only `AUDIOLOOPBACK_TAPPOINT_CAPS_PREVOLUMEMUTE`, accepts the matching pin attribute, and rejects a requested post-volume/mute tap. WASAPI shared/event loopback is the supported user-mode path. Loopback is withheld when either mixed `DRMRIGHTS.CopyProtect` or `DRMRIGHTS.DigitalOutputDisable` is set, and the resumed stream is marked discontinuous. If the live known-tone test returns anything other than the actual shared mix, the architecture decision must be reopened; synthetic or idle-generated sample data is never accepted as success.

## Properties and naming

Identity is established by devnode/container properties, not by the friendly string. The service supplies the parent software device's standard `DEVPKEY_Device_FriendlyName` during initial creation; AudioEndpointBuilder uses that value when composing the MMDevice label. Before enabling the audio interface, the driver requires a canonical 12-hex receiver ID and copies the private ID/display metadata to the `KSCATEGORY_AUDIO` interfaces for diagnostics. User mode maps the resulting MMDevice by deterministic `PKEY_Device_ContainerId` and validates the private receiver ID only when it is projected into the endpoint store.

Endpoint IDs remain opaque. Registry paths, endpoint ID formats, and undocumented policy APIs are not used as identity.

## Kernel safety rules

- No networking, DNS-SD, RTSP, RTP, codec, crypto, JSON, configuration, or remote timing.
- No exceptions or RTTI.
- No blocking or pageable operation above its permitted IRQL.
- Validate pin IDs, formats, state transitions, sizes, offsets, and any property request before access.
- Use checked multiplication/addition for frame and buffer calculations.
- Keep allocation out of stream notification/position paths.
- Pair every PortCls, interface, pool, event, and adapter lifetime on failure and removal.
- Enable compiler control-flow protection, SDL checks, Spectre mitigations where supported, and warnings as errors after inherited-sample warnings are resolved.

## Live validation and remaining gates

[VALIDATION.md](../VALIDATION.md) records current build evidence separately from
historical installed results. The [testing guide](testing.md) owns the executable
known-tone, multi-instance, rename, stop/reset/invalidation, service-kill,
sleep/resume, active-removal, uninstall and partial-install procedures.
Endpoint volume/mute, Verifier and HLK acceptance remain open in
[DEFECTS.md](DEFECTS.md); passing source-pattern contracts or a build cannot close
those runtime gates.
