# Contributing to WinAirPlayAudio

Contributions can improve correctness, documentation, tests, and the narrow
classic-RAOP implementation. Read [README.md](README.md), [AGENTS.md](AGENTS.md),
and [the development guide](docs/development.md) first. Human contributors and
coding agents follow the same architecture, driver-safety, evidence, and privacy
requirements.

## Scope and reports

Check [docs/DEFECTS.md](docs/DEFECTS.md) before starting. Reference the relevant
`DEF-xxx` entry in a change or report; keep one report per distinct problem.
When a public repository is available, search its issues and pull requests too.
Substantial architecture changes and new compatibility claims need explicit
agreement on scope and acceptance criteria. The accepted AP2 plan is not
evidence that AP2 has been implemented.

A useful bug report includes:

- Source commit and dirty-tree state, or package version and provenance.
- Windows version/build and architecture, relevant driver/service versions,
  receiver model/firmware/profile, and wired or wireless transport.
- Reproduction steps, expected and actual behavior, frequency, and the last
  known working version when applicable.
- Minimal sanitized logs or a deterministic mock reproduction. State which
  checks ran and their results; label unavailable checks `NOT RUN`.

Do not attach full diagnostic directories, packet captures, raw audio, dumps,
pairing material, passwords, certificates/private keys, or unreviewed logs.
Describe security-sensitive findings through [the private reporting process](SECURITY.md).

## Implement a focused change

Work on a topic branch from `main`. Preserve unrelated local changes.
Keep private captures, investigation notes and machine records under `.local/`.
Compiler output and dependency caches use their existing ignored build paths.
The architecture, ownership and driver-safety rules are in [AGENTS.md](AGENTS.md).

Original contributions outside the separately licensed driver component use
`AGPL-3.0-only`, as described in [README.md](README.md#license) and [LICENSE](LICENSE).
Driver adaptations remain MS-PL. Third-party components retain their original
licenses and required notices.

- Preserve license headers and dependency provenance. An external reference's
  license must permit its intended use; do not copy GPL oracle code into
  distributed product code.
- Add focused regression coverage for behavior or failure-path changes.
  Documentation-only edits normally need link and diff checks rather than
  tests that repeat the text.

For dependency changes, update the intended Cargo declarations and lockfile
together, review the shipping target closure and licenses, and avoid unrelated
upgrades. For version changes, use [the release procedure](docs/releasing.md)
rather than editing version copies independently.

## Validate and request review

Run the affected commands in [development](docs/development.md). At minimum,
code changes require the authoritative `build.ps1 -Test` gate; transport and
lifecycle changes also require process integration. Driver and package changes
require their corresponding builds/contracts. Privileged or hardware tests use
an explicitly prepared recovery-capable test machine.

The pull request or review handoff should state the problem and changed
behavior, related defect IDs, tested commit/tree, executed commands and results,
and remaining risks or `NOT RUN` procedures. Include negative paths and cleanup
evidence where the change affects them. Update `PROGRESS.md`, `VALIDATION.md`,
and `docs/decisions.md` when milestone status, executed evidence or a significant
technical decision changes. Close a defect only when its own acceptance and
closure evidence are satisfied.

Before handoff, inspect the diff and `git status`, verify relative documentation
links, and run `git diff --check`. Public evidence must be sanitized. A passing
mock or build does not establish installed hardware acceptance, and merging a
change does not authorize signing, installation or publication.
