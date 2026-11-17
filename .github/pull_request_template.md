Describe the concrete problem and resulting behavior.

- Changes:
- Validation actually executed (commands and results):
- Negative/error paths and cleanup verified:
- NOT RUN checks and the exact future command/procedure:
- Documentation updated (`PROGRESS.md`, `VALIDATION.md`, and `docs/decisions.md` when required):

Keep driver installation, test signing, boot changes, and hardware claims explicit.
Do not attach private diagnostics, raw audio/captures/dumps, credentials, pairing
material, certificates/private keys, or identifying machine records. Sanitize
any short evidence excerpts.
