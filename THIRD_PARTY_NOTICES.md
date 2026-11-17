# Third-party notices

The project's AGPL-3.0-only license applies to original WinAirPlayAudio code
outside the separately licensed driver component. It does not replace the
licenses of third-party components or remove their copyright, attribution,
patent or other required notices. Keep their original license texts with
distributions as described below.

This inventory is maintained alongside the committed `Cargo.lock`. Packaging generates a portable `cargo-metadata.json` dependency inventory from `cargo metadata --locked --filter-platform x86_64-pc-windows-msvc`, plus a bounded `RUST-DEPENDENCY-LICENSES.txt` bundle containing the top-level license/notice files, package coordinates, and source-file SHA-256 values for every locked registry dependency in that shipping target closure. The public inventory retains package coordinates, declared licenses, registry/repository sources, enabled features, and the resolved dependency graph. It omits local manifests, registry-cache paths, source paths, build directories, and arbitrary Cargo metadata; workspace package IDs are stable coordinates rather than builder paths. It is a project-specific dependency inventory, not a claim of SPDX or CycloneDX conformance. Unmodified Cargo metadata remains local to the build host for license collection.

## Microsoft Windows Driver Samples

The driver is derived from `microsoft/Windows-driver-samples`, `audio/simpleaudiosample`, pinned to commit `2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89`. The driver component, including WinAirPlayAudio adaptations, remains under the Microsoft Public License and retains its original copyright headers. The complete license is at `driver/LICENSE.microsoft-samples.txt` in source checkouts and `LICENSE.microsoft-samples.txt` beside this notice in packaged distributions and installed runtime files.

## Inno Setup

The Setup and Uninstall executables use the unmodified Inno Setup 7.1.1 runtime.
It retains the upstream [Inno Setup license](https://jrsoftware.org/files/is/license.txt)
and copyright notices; it is not relicensed under AGPL. The pinned compiler is
build tooling, not part of the installed driver/service payload. Each wizard
also embeds and displays the WinAirPlayAudio project license.

## Direct Rust dependencies

Exact versions are owned by `Cargo.toml`/`Cargo.lock`; the generated bundle
includes upstream license files for the full shipping dependency closure.

| Package | License family / purpose |
|---|---|
| `mdns-sd` | MIT OR Apache-2.0; process-local DNS-SD |
| `windows` / `windows-service` | MIT OR Apache-2.0; Windows API and SCM integration |
| `serde` / `serde_json` | MIT OR Apache-2.0; configuration and diagnostics |
| `thiserror` | MIT OR Apache-2.0; contextual errors |
| `tracing` / `tracing-subscriber` | MIT; structured logging |
| `uuid` | Apache-2.0 OR MIT; stable identifiers |
| `clap` / `ctrlc` | MIT OR Apache-2.0; command-line parsing and shutdown |
| `hound` | Apache-2.0; WAV test input |
| `socket2` | MIT OR Apache-2.0; source-bound sockets |
| `x25519-dalek` | BSD-3-Clause; receiver-required preflight key generation |
| `zeroize` | MIT OR Apache-2.0; best-effort password clearing |
| `getrandom`, `md-5`, `hex` | MIT OR Apache-2.0; entropy and Digest protocol primitives |

This summary is not a substitute for upstream license files or legal review.

## Explicitly not redistributed

- Apple `dnssd.dll`, `mDNSResponder.exe`, Bonjour installer, or Apple branding.
- `philippe44/libraop` code, because no distributable license/provenance was established.
- GPL code from OwnTone, AirSend/airplay2-rs, Shairport Sync, or other protocol oracles.
