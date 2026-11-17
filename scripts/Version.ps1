[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Check')]
    [switch]$Check,

    [Parameter(ParameterSetName = 'Check')]
    [ValidateNotNullOrEmpty()]
    [string]$Tag,

    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [string]$Version,

    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [ValidateRange(0, 65534)]
    [int]$DriverRevision,

    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [string]$DriverDate,

    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Versioning.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Set') {
    $state = Update-ProjectVersion -RepositoryRoot $RepositoryRoot `
        -Version $Version -DriverRevision $DriverRevision -DriverDate $DriverDate
}
else {
    $state = Test-VersionConsistency -RepositoryRoot $RepositoryRoot -Tag $Tag
}

[pscustomobject]@{
    Version = $state.Version
    DriverVersion = $state.DriverVersion
    DriverDate = $state.DriverDate
}
