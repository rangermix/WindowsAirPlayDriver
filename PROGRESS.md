# Progress

WinAirPlayAudio is an experimental classic-RAOP source preview.
[README.md](README.md) owns product scope, [DEFECTS.md](docs/DEFECTS.md) tracks
unresolved acceptance, and [VALIDATION.md](VALIDATION.md) records evidence.

## Current implementation

- The [README screenshots](README.md#how-it-looks) show a previously installed
  AirPlay endpoint in Windows Sound and Volume mixer.
- The driver exposes Windows playback endpoints for eligible classic receivers.
  It captures audio before endpoint volume/mute. Use receiver controls to mute
  remote playback during testing.
- Windows CI checks builds, tests and unsigned package assembly within the runner.
  Signing and publication are separate from source-only validation.
- Original user-mode code, scripts and documentation use AGPL-3.0-only.
  The driver component and its adaptations retain MS-PL. Third-party components
  preserve their licenses. A future binary needs an exact Corresponding Source
  handoff.
- Setup and Uninstall wizards reuse the guarded PowerShell backend. Clean-host
  installation, playback, removal and recovery remain unverified.

## Remaining gates

Transport deadlines/cancellation, endpoint volume/mute, UDP recovery, service
privileges, trusted PowerShell module lookup, independent-root reproducibility
and installed/hardware acceptance remain open. Driver Verifier, HLK and
production signing require separate validation.

AirPlay 2 Stage 0 remains open under the accepted specification and Stage 0–3
plan. Windows 10 and ARM64 remain outside the validated platform scope.
