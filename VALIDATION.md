# Validation record

[DEFECTS.md](docs/DEFECTS.md) owns closure criteria. Original build logs and
historical evidence are retained privately.

## Source-only preparation

This candidate contains source for the experimental classic-RAOP prototype.
See the [release checklist](docs/release-checklist.md) for remaining gates.

- Repository and source checks passed on a fresh, uncommitted Git repository.
  The private originals and their inventory are retained separately. The
  initial snapshot excluded prior logs, captures and generated files.
- Rust formatting, warnings-denied Clippy, 216 Debug workspace tests (two
  ignored) and the Release user-mode build passed. The locked Windows x64
  dependency policy and repository/version/driver contracts passed.
- The native Release driver build passed. Its SYS version resource contains
  the upstream Microsoft copyright notice and year. The source MS-PL text
  matches the previous package's license bytes.
- The source-only CI contract, actionlint, 162 release-tool fixture cases and
  both native GUI preview builds passed. The previews were compiled locally.
- Full unsigned packaging of this candidate and hosted CI are **NOT RUN**.
  Packaging requires a recorded source commit. From a clean committed checkout,
  run the documented Release package command and verify its copied MS-PL text.

## README screenshots

Both README images match the original cropped PNG exports. Visual review
confirmed that receiver names are redacted and account, host and network details
are absent. The PNGs contain only image chunks. The screenshots document
endpoint visibility in Windows Sound and Volume mixer.

## Earlier implementation evidence

- Windows Debug/Release user-mode builds and 216 Rust tests per configuration
  passed on the prior baseline. Native Debug/Release builds, installer fixtures
  and unsigned package/archive checks passed. These are build and mock results.
- Captured Windows output endpoints demonstrated historical endpoint visibility.
  Current physical playback and Windows endpoint mute/volume remain unverified.
- Local signed-payload projection and archive fixtures validated the two-wizard
  layout. Installed delivery, recovery and current release signing remain open.

## Unexecuted acceptance

Every procedure below is **NOT RUN** for the current delivery. Use a disposable
native x64 Windows 11 24H2+ host with recovery access and a known BitLocker
recovery key. Record exact source, signed manifests, OS and receiver/firmware
identities privately, then publish a sanitized result.

### New two-file delivery

Follow [release preparation](docs/releasing.md) in a separately authorized
binary release environment. Use a reviewed commit and distinct version/revision.
Inspect exact Corresponding Source delivery, actual signatures/catalog and
cleanup, final ZIP/checksum, and unchanged signed GUI bytes.

### GUI setup, prerequisites and failure recovery

Authenticate/unblock the ZIP and run `WinAirPlayAudio-<version>-Setup.exe`.
Exercise declined UAC/consent, unsupported host, invalid payload, missing
PowerShell/VC runtimes, offline inputs, runtime failures and Secure Boot refusal.
Verify explicit boot/recovery/trust/clean-reinstall consent and live progress.
For prerequisite/test-mode exit 3010, manually restart and rerun; prove that phase
did not report completed driver installation. Confirm running-kernel TESTSIGNING,
exact public trust, Driver Store package, service, firewall and compatible-receiver
playback. Inject partial installation failure and verify transaction, newly added
trust and protected scratch cleanup; retain preexisting trust and shared runtimes.

For CLI acceptance, use a complete authenticated internal developer bundle with scripts: `Setup.cmd -Plan`, then `Setup.cmd`. Test the
offline/unattended options and acknowledgement failures in the
[installer guide](installer/README.md#guided-prebuilt-setup). The new two-file
user ZIP contains no loose CLI scripts. See [operator procedures](docs/build-and-install.md)
for explicit lower-level certificate cleanup and test-mode disable/restart commands.

### Removal and reboot recovery

Keep `WinAirPlayAudio-<version>-Uninstall.exe` outside the removed runtime.
Exercise active streams, partial installation, damaged/missing incoming package,
repeated removal, declined UAC/removal consent and failure to unload the driver.
For the script path above, run `Uninstall.cmd -Plan`, then `Uninstall.cmd`.
Verify ownership and kernel unload, then absence of service, scoped firewall rule,
product devices/Driver Store packages, runtime, config/credentials/logs and tool caches.
No trust/boot change may follow incomplete product cleanup.

Test default retained test mode and optional public-trust removal only for the
matching dedicated signer; preserve private keys/shared runtimes. Test optional
test-mode exit with all other-driver/boot/recovery acknowledgements, exit 3010,
manual restart and a fresh running-kernel plan. Exercise worker launch/error,
certificate/BCD refusal, concurrent operations, cleanup/retry/logging and pending
BCD changes while the current kernel is normal. Verify independent uninstaller
availability. Never remove unrelated drivers or change shared boot policy without
the operator acknowledgement. [Removal options](installer/README.md#guided-uninstaller)
and [operator recovery](docs/build-and-install.md) own exact commands.

### Hardware, security and platform gates

Current-source live endpoint/physical audio, unity/50%/mute/unmute/rapid-volume
changes, physical-output oracle, latency, corrected installed WLAN, network/
interface/sleep/restart, clock/CPU/memory/60-minute soak, privileged fault cleanup,
legacy upgrade and minimum service identity remain unverified. Parser fuzzing,
independent-root reproducibility, Driver Verifier, HLK, production Microsoft
signing, legal/MFi disposition, AP2, Windows 10 and ARM64 also remain open.

Exact future commands/matrices are in [development](docs/development.md),
[testing](docs/testing.md), [build/install](docs/build-and-install.md),
[releasing](docs/releasing.md), the [release checklist](docs/release-checklist.md)
and the accepted [AP2 plan](docs/airplay2-stage-0-3-plan.md). Safe previews, source
checks and test signatures do not close privileged, hardware or production gates.
