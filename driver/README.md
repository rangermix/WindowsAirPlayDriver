# WinAirPlayAudio virtual render driver

This is the Windows 11 x64 24H2+ PortCls/WaveRT driver adapted from Microsoft
[`audio/simpleaudiosample`](https://github.com/microsoft/Windows-driver-samples/tree/2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89/audio/simpleaudiosample)
at `2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89`. Original headers are retained;
[LICENSE.microsoft-samples.txt](LICENSE.microsoft-samples.txt) supplies the MS-PL.
The `driver/` component, including WinAirPlayAudio adaptations and its build
helpers, remains under MS-PL; the repository's AGPL-3.0-only default excludes it.
Windows 10 and ARM64 are not validated targets.

The [driver design](../docs/driver-design.md) defines pins, exact PCM format,
rendered-mix copying, DRM, identity and kernel-lifetime rules. The tap is
pre-volume/mute; a separate product control path is still required for Windows
endpoint controls to affect receiver playback.

## Build from the repository root

Install the prerequisites in [development](../docs/development.md), then run:

```powershell
.\build.ps1 -Bootstrap
.\build.ps1 -Driver -Configuration Debug
.\build.ps1 -Driver -Configuration Release
```

`Build-Driver.ps1` uses native x64 MSBuild. SDK/WDK NuGet packages do not install
the Visual Studio `WindowsKernelModeDriver10.0` integration; the preflight
reports the missing component separately. Outputs are under
`driver/out/package/<Configuration>/x64`; private build logs use
`.local/diagnostics/build/driver/` with unique invocation names.

`version.json` and [version tooling](../docs/releasing.md) own product/driver
version metadata. `WinAirPlayAudio.inx`, `.rc`, `Source/Inc/version.h` and project
copies must stay synchronized.

## Source map

| Location | Purpose |
|---|---|
| `Source/Main/` | Adapter, topology/WaveRT miniports and stream lifetime. |
| `Source/Filters/` | Endpoint pin/format/topology descriptors. |
| `Source/Inc/` | Shared driver interfaces, metadata and generated version header. |
| `Source/Utilities/` | PortCls/KS helpers and local hardware abstraction. |
| `Package/` | Build-only WDK package project; no installation side effect. |

The static contract runs through `build.ps1 -Test` or
`driver/Test-DriverContract.ps1`. Passing source/build checks does not prove
kernel runtime safety. Use [testing](../docs/testing.md) for known-tone,
multiple-instance, removal and recovery procedures, and
[build and install](../docs/build-and-install.md) for explicit deployment.
Current evidence and open hardware/Verifier/HLK gates are in
[VALIDATION.md](../VALIDATION.md) and [DEFECTS.md](../docs/DEFECTS.md).
