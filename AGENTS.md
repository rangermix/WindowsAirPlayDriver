# WinAirPlayAudio contributor contract

## Supported development environment

- Windows 11 x64 (24H2 or newer is the first supported target).
- Visual Studio 2026 with Desktop C++ and the matching Windows Driver Kit.
- Windows SDK and WDK `10.0.28000.1839` for the pinned driver sample revision.
- Rust `1.97.1`, installed through `rustup`.
- PowerShell 7 and CMake 4 or newer.

Windows 10 and ARM64 are future validation targets; do not claim support without recorded tests.

## Build and test

```powershell
.\build.ps1 -Bootstrap
.\build.ps1 -Configuration Debug -UserModeOnly
.\build.ps1 -Configuration Release -UserModeOnly
.\build.ps1 -Driver -Configuration Debug
.\build.ps1 -Test
.\build.ps1 -IntegrationTest
.\build.ps1 -Package -Configuration Release
.\build.ps1 -Clean
```

The build script is authoritative. It must diagnose missing dependencies with an actionable command or Visual Studio component name.

## Defect tracking and local records

- Read [docs/DEFECTS.md](docs/DEFECTS.md) before planning, implementation, review, or validation. Add newly confirmed defects and update affected entries with evidence, remaining work, and actual validation results. Keep unresolved and unexecuted work visible.
- Keep public documentation in `docs/` focused on sanitized, reusable project guidance and concise evidence summaries. Personal development plans, investigation notes, raw validation records, diagnostics, captures, dumps, build logs, and local machine inventories belong only beneath the ignored repository-root `.local/` directory. See [docs/local-artifacts.md](docs/local-artifacts.md) for the layout.
- Use `.local/diagnostics/` for diagnostic output and verification evidence, `.local/notes/` for private working records, and `.local/secrets/` for any repository-local sensitive inputs. Do not create another local-record root such as `.diagnostics/`, `artifacts/`, or a directory beneath `target/`.
- Never commit or publish secrets, private keys/certificates, raw audio/network captures, dumps, machine inventories, or unsanitized local records. Exclude `.local/` and these payloads from releases, package inputs, CI uploads, and any future container or publication context. Publish only a reviewed, sanitized summary or deliberately sanitized fixture.
- Automated test-signed prereleases may include only their deliberately exported public DER test certificate, checked against the expected signer pin. Keep its PFX/private key/password in the protected `test-signing` environment and local recovery material beneath `.local/secrets/`. Branch and pull-request jobs must never receive signing secrets; signing must not install the driver or change boot policy.
- Keep installed product logs, protected credentials, and signing storage at their documented Windows runtime locations; place copies collected for development beneath `.local/`. Ordinary compiler outputs and dependency caches remain in their existing ignored build/cache directories.
- Preserve local evidence when reorganizing it: inventory the files, record their source/destination paths, sizes, and SHA-256 values in an ignored manifest, validate workspace-bounded paths, and verify every destination after moving. Do not delete evidence or rewrite Git history implicitly. Ignoring a tracked file does not remove it from Git history.

## Driver safety

- Keep discovery, sockets, codecs, cryptography, and remote timing out of kernel mode.
- Do not add exceptions, RTTI, blocking work, uncontrolled allocation, or third-party runtime libraries to driver real-time paths.
- Validate all external buffers and lengths, use checked arithmetic and SAL, and preserve IRQL contracts.
- Never install or enable test signing implicitly. Installation and boot-configuration changes require an explicit elevated command.
- Run Driver Verifier only on a disposable test machine with recovery access.

## Style

- Run `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets -- -D warnings`.
- Keep parsing separate from sockets, discovery observations separate from lifecycle decisions, and audio conversion separate from transport.
- Use bounded queues, explicit ownership/cancellation, orderly joins, and contextual errors.
- Production code must not contain silent discard paths, detached threads, empty catches, or placeholder success.

## Definition of done

A change is done only when the affected build and tests have executed successfully, negative/error paths are covered, cleanup is verified where possible, and documentation reflects reality. Never claim an unexecuted test passed. Record unavailable privileged, hardware, signing, soak, and platform tests as `NOT RUN`, with the exact future command or procedure.

Update `PROGRESS.md`, `VALIDATION.md`, and `docs/decisions.md` whenever milestone status, executed evidence, or a significant technical decision changes.

