# Architecture

WinAirPlayAudio is an experimental Windows 11 x64 24H2+ classic RAOP sender.
The [compatibility profile](airplay-compatibility-and-licensing.md) defines
which advertisements can create endpoints. AirPlay 2 remains unimplemented;
its accepted [specification](airplay2-single-receiver-spec.md) and
[implementation plan](airplay2-stage-0-3-plan.md) govern separate future work.

## Component flow

```text
LAN mDNS
  -> scoped discovery observations and canonical receiver identity
  -> capability admission and receiver lifecycle
  -> service-owned SwDeviceCreate handle and stable container
  -> PortCls/WaveRT render endpoint and rendered-mix loopback
  -> event-driven WASAPI capture and preallocated bounded queue
  -> conversion/resampling and RAOP packet worker
  -> bounded retransmission history, RTSP control and UDP media/timing
  -> receiver
```

| Area | Owner and detailed contract |
|---|---|
| `shared/` | Discovery parsing/registry, identity, capability classification, conversion and RAOP protocol. [Receiver lifecycle](receiver-state-machine.md) owns observation/expiry rules. |
| `service/` | Native SCM/console lifecycle, software-device handles, container-based endpoint mapping, WASAPI capture and per-receiver workers. [Audio pipeline](audio-pipeline.md) owns capture, conversion, pacing and loss recovery. |
| `driver/` | Local PortCls/WaveRT buffers, clocks, pin/property contracts and PnP lifetime. [Driver design](driver-design.md) owns the kernel boundary. |
| `tools/` | Discovery/direct-sender/endpoint/credential diagnostics and bounded process fixtures. |
| `installer/` | Authenticated package/signing/install/uninstall transactions. [Build and install](build-and-install.md) owns operator procedures; [security](security.md) owns trust controls. |

The kernel contains no discovery, networking, codecs, cryptography, remote timing
or admission policy. User-mode Rust was selected in
[D-003](decisions.md#d-003--user-mode-language); discovery backend selection is
recorded in [D-002](decisions.md#d-002--discovery-implementation).

## Ownership and identity

The service owns every `HSWDEVICE`. Default handle lifetime makes the devices
non-present when the process exits. A canonical advertised receiver ID derives
the stable container GUID; `PKEY_Device_ContainerId` maps the resulting MMDevice.
Friendly names and opaque endpoint strings are never identity keys. A projected
private receiver property is an optional consistency check and fails closed
when malformed or mismatched.

Discovery emits bounded observations and never starts transport or creates
devices directly. Lifecycle reconciliation serializes those decisions. The
current registry snapshot covers discovery state; streaming/recovery state
belongs to workers and structured events.

## Privilege and shutdown

The current endpoint/network service uses `LocalSystem`; minimum privileges
remain [DEF-004](DEFECTS.md#def-004--minimum-service-privileges). Network parsing
is untrusted, and any future broker split must use authenticated, versioned,
bounded IPC. The exact listener/firewall boundary is in [security](security.md).

Cancellation flows through discovery, capture and sender workers; queues close,
workers join, then software-device handles close. The current RTSP per-read
socket timeout cannot interrupt a trickling response, so the intended bounded
shutdown is not yet satisfied: [DEF-002](DEFECTS.md#def-002--absolute-rtsp-deadlines-and-cancellation).
