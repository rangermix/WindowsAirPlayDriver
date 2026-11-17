[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$paths = @(& git -C $root -c core.quotepath=false ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) {
    throw 'Cannot enumerate source files. Run this check inside a Git checkout.'
}
$violations = [Collections.Generic.List[string]]::new()
foreach ($relativePath in $paths) {
    # A pending removal is intentionally absent from the next source tree.
    # Release assembly separately requires a clean committed checkout.
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ($relativePath -match '^(?:\.local|\.diagnostics|artifacts|target|\.tools|\.vs|\.vscode)/' -or
        $relativePath -match '^(?:driver/(?:out|obj|packages)|installer/staging)/' -or
        $relativePath -match '(?i)(?:^|/)\.env(?:\.[^/]+)?$' -or
        $relativePath -match '(?i)\.(?:pcapng?|etl|dmp|wer|pfx|p12|pvk|snk|key|pem|cer|ppk|log|pdb|exe|dll|sys|wav|flac|aiff?|mp3|m4a|aac|opus|ogg|wma|mp4|webm|mkv|mov|avi|zip|7z|rar|tar|tgz|gz|bz2|xz)$') {
        $violations.Add($relativePath)
    }
}
if ($violations.Count -gt 0) {
    throw "Private/generated files are present in the source set. Keep them under .local/ and remove them from the intended public tree: $($violations -join ', ')"
}
$ignored = @(& git -C $root check-ignore '.local/diagnostics/probe.json' '.local/notes/probe.md' '.local/secrets/probe.json')
if ($LASTEXITCODE -ne 0 -or $ignored.Count -ne 3) {
    throw '.local/ diagnostics, notes and secrets must all be ignored by Git.'
}
Write-Host 'Source hygiene passed: no present private/generated payloads in the source set; .local/ is ignored.'
