# Development

Read [AGENTS.md](../AGENTS.md) for the contributor contract and
[CONTRIBUTING.md](../CONTRIBUTING.md) for scope, review and evidence requirements.
`build.ps1` is the authoritative entry point for builds and checks.

The [architecture guide](architecture.md#component-flow) maps `driver/`,
`service/`, `shared/`, `tools/` and `installer/` to their responsibilities.
Use the [documentation overview](README.md) to find design and operator guides.

## Prerequisites

- Windows 11 x64, version 24H2 or newer.
- Visual Studio 2026 with **Desktop development with C++** and the matching
  **Windows Driver Kit** component (`Component.Microsoft.Windows.DriverKit`).
- Pinned Windows SDK/WDK packages `10.0.28000.1839` for the driver sample.
- Rust `1.97.1`, installed with `rustup`, including rustfmt and Clippy.
- PowerShell 7 and CMake 4 or newer.

User-mode work requires the MSVC build tools but does not install or load a
driver. The full driver build also needs Visual Studio's WDK integration;
restoring SDK/WDK NuGet packages alone does not install that component.
Windows 10 and ARM64 are future validation targets.

## Build and check

Run from the repository root in PowerShell 7:

```powershell
.\build.ps1 -Bootstrap
.\build.ps1 -UserModeOnly -Configuration Debug
.\build.ps1 -UserModeOnly -Configuration Release
.\build.ps1 -Test
.\build.ps1 -IntegrationTest
.\scripts\Version.ps1 -Check
```

`-Bootstrap` restores the pinned toolchain and dependencies. It does not install
a driver or change boot policy. `-Test` includes repository/version/release
fixtures, formatting, warnings-denied Clippy, all locked Rust workspace tests
and driver/installer contracts. Workspace tests include all process integration
cases, so combining `-Test -IntegrationTest` does not repeat them.
Two installed-endpoint tests require explicit live setup and remain ignored in
an ordinary test run. `-IntegrationTest` alone runs the mock sender/discovery,
child cleanup and console-service process tests without the full unit suite.
Neither result establishes physical-receiver or installed-driver acceptance.

The style checks can also be run directly:

```powershell
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
```

For affected driver/package work:

```powershell
.\build.ps1 -Driver -Configuration Debug
.\build.ps1 -Driver -Configuration Release
.\build.ps1 -Package -Configuration Release
```

Packaging produces unsigned signing input under
`driver/out/package/Release/x64`; it is not an installed or supported release.
Use [build and install](build-and-install.md) for explicit test signing and
deployment, and [testing](testing.md) for the ordered hardware matrices.
Do not enable test signing, install certificates, replace an installed driver
or run Driver Verifier as a side effect of routine validation.

## Useful boundaries

Discovery observations and capability classification live in `shared/`.
The service owns software-device handles and capture/transport workers. Kernel
code handles only local WaveRT audio and device lifetime. Keep parsing separate
from socket work, and preserve bounded data movement and cancellation across
these boundaries. The [architecture](architecture.md),
[audio pipeline](audio-pipeline.md), and [driver design](driver-design.md)
describe their contracts.

Process fixtures live under `tools/tests/` and `service/tests/`; most protocol
and failure-path tests live alongside their owning Rust modules. Static
PowerShell driver contracts check selected source requirements and do not
execute kernel IRQL or PnP behavior.

## Continuous integration

`.github/workflows/ci.yml` checks pull requests, pushes to `main` and manual
runs with read-only repository permissions. The Debug and Release jobs run
the authoritative test/user-mode build actions and native driver builds.
Release CI builds the complete unsigned package and verifies the bounded
developer archive inside the runner workspace. CI makes no binary uploads
and has no signing credentials or release jobs.

The explicit runner is `windows-2025-vs2026`; the
[GitHub image inventory](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-VS2026-Readme.md)
and `.github/scripts/Test-CiToolchain.ps1` describe/check its VS2026, native x64
MSBuild and WDK integration. Bootstrap restores the exact Rust/SDK/WDK pins.
As [Microsoft documents](https://learn.microsoft.com/windows-hardware/drivers/install-the-wdk-using-nuget),
NuGet headers/libraries do not replace Visual Studio's driver integration.
Image/compiler versions are recorded by the job; Windows Server build execution
does not establish runtime or hardware support.

The Release job installs `cargo-deny 0.20.2` into runner temporary storage and
checks advisories, licenses and sources against `deny.toml`, recording the
current RustSec revision. The tooling job runs checksum-pinned `actionlint
1.7.12`. Run the policy and workflow checks locally with:

```powershell
cargo deny --locked --target x86_64-pc-windows-msvc --config deny.toml check advisories licenses sources
.\.github\scripts\Test-Workflows.ps1
.\.github\scripts\Test-ReleaseWorkflow.ps1
```

See [releasing](releasing.md) for local package verification and future binary
release requirements.

## Try discovery without installing a driver

After installing the development prerequisites, run from the repository root
in PowerShell 7:

```powershell
.\build.ps1 -Bootstrap
cargo run --locked -p winairplay-tools --bin airplay-discover -- --duration-seconds 15
```

This prints discovered receiver capabilities without installing a driver,
changing boot policy or starting the installed service. Discovery alone is not
a compatibility or playback test. Keep raw receiver/network records under
ignored `.local/`; publish only reviewed, sanitized summaries.

## Local evidence and handoff

Use ignored `.local/` directories for captures, dumps, local notes, copied
reference repositories, certificates and machine-specific logs. Generated
compiler/package output belongs in its existing ignored build directories.
Only publish reviewed, sanitized summaries or synthetic fixtures; do not commit
entire evidence directories or third-party symbol caches.

Record the source commit/tree, command, configuration, result and cleanup for
executed checks. Use `NOT RUN` with the future command/procedure when hardware,
privilege, signing or time prevents a required check. Update the relevant
[defect](DEFECTS.md) and `PROGRESS.md`, `VALIDATION.md`, and `docs/decisions.md`
when their status or evidence changes. Keep accepted AP2 decisions intact unless
a later owner decision changes the scope.
