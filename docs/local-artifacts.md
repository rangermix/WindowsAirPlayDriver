# Local development artifacts

Keep private development records beneath the ignored repository-root `.local/`
directory. Public `docs/` contains reusable guidance and reviewed, sanitized
summaries. Consult [DEFECTS.md](DEFECTS.md) before work and update affected defects
with confirmed findings and actual validation results.

| Location | Contents |
|---|---|
| `.local/diagnostics/` | Build/test logs, diagnostic JSON, machine inventories, packet/audio captures, dumps, and other local verification evidence |
| `.local/diagnostics/build/driver/` | Driver build and static-analysis logs |
| `.local/diagnostics/audit-YYYY-MM-DD/` | Evidence for a new dated audit or validation session |
| `.local/diagnostics/manifests/` | File-move inventories and integrity results |
| `.local/notes/` | Personal plans, investigation notes, and temporary analysis scripts |
| `.local/secrets/` | Repository-local sensitive inputs, only when such a copy is necessary |

Do not introduce separate record directories such as `.diagnostics/`,
`artifacts/`, or `target/project-audit-*/`. Use an explicit diagnostic output path:

```powershell
New-Item -ItemType Directory -Path .\.local\diagnostics -Force | Out-Null
cargo run --locked -p winairplay-tools --bin diagnose -- --output .\.local\diagnostics\diagnostics.json
```

Installed service logs, credentials, signing snapshots, and signed test-package
archives retain their documented protected Windows locations. Any development
copies belong in `.local/`. Compiler products (`target/`, `driver/out/`,
`driver/obj/`) and downloaded tool/dependency caches remain in their existing
ignored locations; diagnostic build logs go in `.local/`.

Git ignores `.local/`, but that does not encrypt it or restrict filesystem
access. Keep passwords and private keys out of command lines and logs, use the
existing protected credential/signing mechanisms, and apply appropriate local
access controls to necessary sensitive copies.

Exclude `.local/` and private payloads from package inputs, releases, CI uploads,
and future container or publication contexts. A successful test log or ignored
file is not suitable for publication without review. Publish a minimal summary
that omits usernames, absolute builder paths, host and receiver identifiers,
network addresses, credentials, raw audio, and unrelated traffic. Deliberately
sanitized test fixtures require their own review and provenance.

`scripts/Test-SourceHygiene.ps1` checks the intended source set for private keys,
environment files, raw media/captures, generated archives, editor settings and
dependency/staging outputs. It also rejects ignored local files if force-added
to Git. Keep synthetic regression inputs under `.local/`; introducing a
sanitized published fixture requires an explicit reviewed policy exception.

## Preserve records before reorganizing

Before moving evidence or replacing a document containing unique history:

1. Inventory every source and intended destination with its absolute path,
   byte length and SHA-256 in an ignored manifest beneath `.local/diagnostics/`.
2. Resolve paths beneath the intended workspace; reject reparse points,
   destination collisions and unexpected directory boundaries.
3. Preserve original bytes, then verify every destination's size/hash. For a
   move, also verify original-path absence; for a copy-before-edit, retain both.
4. Check Git-ignore behavior and the intended source/release file sets. Keep
   the manifest private; publish only a reviewed, sanitized summary.

Do not delete evidence or erase Git history during reorganization. A tracked
file can remain in earlier commits after its worktree removal. Any history
rewrite/publication requires its own authorized scope.

Keep old logs in dated subdirectories so new builds cannot overwrite hashed
evidence. Driver builds use a unique UTC timestamp and invocation suffix for
logs under `.local/diagnostics/build/driver/`. Preserve compiler/dependency
caches in their existing ignored locations; they are not disposable audit records.

Useful checks:

```powershell
git check-ignore -- .local/diagnostics/example.json .local/notes/example.md .local/secrets/example.key
git status --short
```

Review the actual pending changes rather than expecting a particular historical
Git status. No `.local/` payload belongs in the source set; never force-add private
evidence to make a review or publication appear complete.
