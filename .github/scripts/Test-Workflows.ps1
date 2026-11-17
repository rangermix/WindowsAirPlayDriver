[CmdletBinding()]
param(
    [string]$ToolDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'This portable actionlint check requires native x64 Windows.'
}
if ([string]::IsNullOrWhiteSpace($ToolDirectory)) {
    if ($env:RUNNER_TEMP) {
        $ToolDirectory = Join-Path $env:RUNNER_TEMP 'winairplay-actionlint-1.7.12'
    }
    else {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $ToolDirectory = Join-Path $repoRoot '.local\tools\actionlint\1.7.12'
    }
}
New-Item -ItemType Directory -Path $ToolDirectory -Force | Out-Null
$archive = Join-Path $ToolDirectory 'actionlint_1.7.12_windows_amd64.zip'
$expectedHash = '6E7241B51E6817EA6A047693D8E6FED13B31819C9A0DD6C5A726E1592D22F6E9'
# SHA-256 verified against the upstream release asset digest:
# https://github.com/rhysd/actionlint/releases/tag/v1.7.12
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    Invoke-WebRequest -Uri 'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_windows_amd64.zip' -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $expectedHash) {
    throw "Portable actionlint archive hash mismatch. Remove only '$archive' and retry."
}
# Re-extract the verified archive so a previously modified executable is never
# accepted merely because a verified ZIP is cached beside it.
Expand-Archive -LiteralPath $archive -DestinationPath $ToolDirectory -Force
$executable = Join-Path $ToolDirectory 'actionlint.exe'
$workflowRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'workflows'
& $executable -version
if ($LASTEXITCODE -ne 0) { throw 'Portable actionlint could not start.' }
& $executable (Join-Path $workflowRoot 'ci.yml')
if ($LASTEXITCODE -ne 0) { throw 'actionlint reported workflow errors.' }
Write-Host 'Workflow syntax, contexts, dependencies, action inputs, and runner labels passed actionlint 1.7.12.'
