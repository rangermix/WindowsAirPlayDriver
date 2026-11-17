# Documentation

WinAirPlayAudio is an experimental Windows virtual audio output for compatible
classic AirPlay 1/RAOP receivers. Start with the [project README](../README.md)
for an overview. AirPlay 2 remains future work. Physical playback acceptance
requires the receiver and test-machine procedures in the testing guide.

## Use WinAirPlayAudio

| Guide | What you will find |
|---|---|
| [Usage](usage.md) | Receiver requirements, choosing an output, app routing and volume/mute behavior |
| [Install, remove and recover](build-and-install.md) | Local packaging, prerequisites, explicit test-mode/trust steps and cleanup |
| [Troubleshooting](troubleshooting.md) | Missing receivers/endpoints, discovery, silent audio and service failures |
| [Known limitations](known-limitations.md) | Unsupported features and current reliability/security gaps |
| [Compatibility and licensing](airplay-compatibility-and-licensing.md) | Exact supported receiver profile, protocol references and component licensing |

Native wizard details live in [GUI setup and removal](../installer/gui/README.md);
advanced script options are in the [installer reference](../installer/README.md).
For reports, see [Contributing](../CONTRIBUTING.md) and
[Security reporting](../SECURITY.md).

## Build and contribute

| Guide | What you will find |
|---|---|
| [Development](development.md) | Pinned toolchain, builds, driver-free discovery, checks and CI |
| [Testing](testing.md) | Mock/integration coverage and installed/hardware acceptance procedures |
| [Releasing](releasing.md) | Versioning, packaging, protected signing, source handoff and publication |
| [Release checklist](release-checklist.md) | Required evidence before declaring a release ready |
| [Local artifacts](local-artifacts.md) | Private evidence storage, sanitization and preservation rules |

[AGENTS.md](../AGENTS.md) is the contributor contract. Read the
[defect tracker](DEFECTS.md) before planning or changing behavior.

## Understand the design

| Guide | What it owns |
|---|---|
| [Architecture](architecture.md) | Component map, audio flow, identity, ownership and privilege boundaries |
| [Driver design](driver-design.md) | Kernel audio endpoint, WaveRT and loopback contracts; see also the [driver reference](../driver/README.md) |
| [Audio pipeline](audio-pipeline.md) | Capture, conversion, pacing, queues and discontinuity recovery |
| [Receiver lifecycle](receiver-state-machine.md) | Discovery observations, stable identity, timers and endpoint lifetime |
| [Security](security.md) | Trust, credentials, firewall scope, privileges and threat boundaries |
| [Decisions](decisions.md) | Selected policies, rationale and superseded choices |
| [Risk register](risk-register.md) | Unresolved engineering, compatibility and distribution risks |

## Status and future work

- [Progress](../PROGRESS.md): current implementation and remaining milestones.
- [Validation](../VALIDATION.md): executed results and explicitly unrun acceptance.
- [Defects](DEFECTS.md): open defects, release gaps and closure requirements.
- [Changelog](../CHANGELOG.md): changes prepared in the source preview.
- [AirPlay 2 specification](airplay2-single-receiver-spec.md) and
  [Stage 0–3 plan](airplay2-stage-0-3-plan.md): accepted requirements and future
  gates, **not implemented AirPlay 2 support**.

Guides own procedures; the defect tracker owns acceptance gaps; validation owns
executed evidence. Raw logs, private plans and original screenshots stay under
ignored `.local/`. Review screenshots for personal and machine identifiers
before sharing.
