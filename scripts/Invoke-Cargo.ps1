[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$CargoArguments,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$cargo = (Get-Command cargo.exe -ErrorAction Stop).Source
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$priorFlags = [Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process')
$flags = [Collections.Generic.List[string]]::new()
if ($null -ne $priorFlags) {
    foreach ($flag in $priorFlags.Split([char]31)) {
        if ($flag.Length -gt 0) { $flags.Add($flag) }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($env:RUSTFLAGS)) {
    # Cargo itself documents whitespace splitting for RUSTFLAGS. Preserve its
    # existing interpretation while encoding our path arguments losslessly.
    foreach ($flag in ($env:RUSTFLAGS -split '\s+')) { $flags.Add($flag) }
}
$cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
$rustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path $env:USERPROFILE '.rustup' }
foreach ($mapping in @(
        @{ Root=$root; Replacement='/src/WinAirPlayAudio' },
        @{ Root=[IO.Path]::GetFullPath($cargoHome); Replacement='/cargo' },
        @{ Root=[IO.Path]::GetFullPath($rustupHome); Replacement='/rustup' })) {
    foreach ($prefix in @($mapping.Root, $mapping.Root.Replace('\', '/')) | Select-Object -Unique) {
        $flags.Add("--remap-path-prefix=$prefix=$($mapping.Replacement)")
    }
}
$flags.Add('-Clink-arg=/PDBALTPATH:%_PDB%')
try {
    [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', ($flags -join [char]31), 'Process')
    & $cargo @CargoArguments
    if ($LASTEXITCODE -ne 0) { throw "Cargo failed with exit code $LASTEXITCODE." }
}
finally {
    if ($null -eq $priorFlags) {
        Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', $priorFlags, 'Process')
    }
}
