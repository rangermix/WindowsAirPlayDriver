# Security policy

WinAirPlayAudio is experimental and has no supported production release or
guaranteed security-response timeline. Its current Windows 11 x64 target and
known limits are described in [README.md](README.md). The
[threat model](docs/security.md) and [defects tracker](docs/DEFECTS.md) record
the current security and release gaps.

## Reporting a vulnerability

Use the repository host's private vulnerability reporting feature when it is
enabled. If a private reporting route is unavailable, ask the maintainer for a
private channel without posting exploit details, credentials or captures in a
public issue. No dedicated reporting address or response deadline has been
established.

Include the affected commit/version, Windows build and architecture, affected
component, impact, prerequisites, and a minimal reproduction. Prefer a local
mock and synthetic inputs over captured private traffic. Explain whether the
finding requires administrator access, a local unprivileged process, or LAN
access, and whether it affects the kernel, service, installer or receiver.

Keep full captures, dumps, raw audio, passwords, pairing keys, certificates,
private keys, receiver identifiers and machine inventory private. Provide a
sanitized summary first and agree on a private transfer route for necessary
evidence. Store local investigations in ignored `.local/` storage.

Security-related changes need negative tests and an accurate threat-model and
validation update. Public disclosure, a fix commit, and a supported signed
release are separate events; record each accurately.
