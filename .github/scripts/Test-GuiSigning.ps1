[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureParent = Join-Path $repository '.local/diagnostics/gui-signing-tests'
$fixtureRoot = Join-Path $fixtureParent ([Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixtureRoot)
$tokens = $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Sign-GuiWizards.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'GUI signing script must parse before fixture execution.' }
$signingFunction = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Invoke-WinAirPlayGuiSigning'
}, $true).Extent.Text
$caseCount = 0

function Assert-GuiFixture([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-GuiSigningFixture([hashtable]$Changes) {
    $options = @{
        BadContext=$false; BadPayload=$false; UnsafeParent=$false; WrongSourceVersion=$false
        OutputExists=$false; Preview=$false; WrongHash=$false; WrongVersion=$false
        PreSigned=$false; WrongSigner=$false; SignFailure=$false; VerifyFailure=$false
        CleanupFailure=$false; BadPe=$false; InvalidCertificate=$false; ExtraFile=$false
        BuildFailure=$false; DescriptionPreview=$false; InvalidSignature=$false; WrongPayloadSource=$false; DirtyPayload=$false
    }
    foreach ($key in $Changes.Keys) { $options[$key] = $Changes[$key] }
    $directory = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
    $guiPath = Join-Path $directory 'installer/gui'
    $null = [IO.Directory]::CreateDirectory($guiPath)
    $null = [IO.Directory]::CreateDirectory((Join-Path $directory 'input'))
    $version = if ($options.WrongSourceVersion) { '9.9.9-rc.1' } else { '1.2.3-rc.1' }
    @{version=$version;driver_revision=4} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $directory 'version.json') -Encoding utf8
    $options | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'fixture-options.json') -Encoding utf8
    [IO.File]::WriteAllText((Join-Path $guiPath 'Build-Wizards.ps1'), @'
[CmdletBinding()]
param($BundleDirectory,$OutputDirectory,$ExpectedSignedManifestSha256,$ExpectedSignerThumbprint,[switch]$NoBootstrap)
if (-not $NoBootstrap) { throw 'Fixture detected compiler bootstrap during protected signing.' }
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$options=Get-Content -LiteralPath (Join-Path $root 'fixture-options.json') -Raw | ConvertFrom-Json
if($options.BuildFailure){throw 'Fixture compiler failure.'}
$files=foreach($action in @('Setup','Uninstall')){
    $name="WinAirPlayAudio-1.2.3-rc.1-$action.exe"
    $path=Join-Path $OutputDirectory $name
    [IO.File]::WriteAllBytes($path,[byte[]](77,90,1,2,3,4))
    [pscustomobject]@{Name=$name;Bytes=6;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;SignatureStatus='NotSigned'}
}
if($options.WrongHash){$files[0].Sha256='0'*64}
if($options.ExtraFile){[IO.File]::WriteAllText((Join-Path $OutputDirectory 'unexpected.txt'),'synthetic')}
[pscustomobject]@{SchemaVersion=1;Version='1.2.3-rc.1';CompilerVersion='7.1.1';PreviewOnly=[bool]$options.Preview;
    PreviewOutcome=$null;PayloadManifestSha256=$ExpectedSignedManifestSha256;SignerThumbprint=$ExpectedSignerThumbprint;
    GeneratedAtUtc=[DateTime]::UtcNow.ToString('o');Files=@($files)} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'wizard-build.json') -Encoding utf8
'@)
    if ($options.OutputExists) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $directory 'output'))
        [IO.File]::WriteAllText((Join-Path $directory 'output/retained.txt'), 'must remain unchanged')
    }
    $module = New-Module -ScriptBlock {
        param($Code, $Directory, $Options)
        $script:Options=$Options
        $script:Events=[Collections.Generic.List[string]]::new()
        $script:Signed=@{}
        $script:Pin='A'*40
        function Assert-WinAirPlayCiSigningContext {
            param($Version,$SourceCommit)
            $script:Events.Add('Context')
            if($script:Options.BadContext){throw 'Fixture non-hosted context.'}
        }
        function Assert-WinAirPlaySigningHost {}
        function Assert-WinAirPlayAdministrator {}
        function Assert-WinAirPlaySetupNoLinks {param($Path)}
        function Assert-WinAirPlayTrustedDirectory {
            param($Path,[switch]$RequireProtectedDacl)
            if($script:Options.UnsafeParent){throw 'Fixture unsafe directory.'}
        }
        function Assert-WinAirPlaySetupInputs {
            param($BundleDirectory,$ExpectedSignedManifestSha256,$ExpectedSignerThumbprint)
            if($script:Options.BadPayload){throw 'Fixture payload authentication failed.'}
            return [pscustomobject]@{SourceCommit=$(if($script:Options.WrongPayloadSource){'2'*40}else{'1'*40});SourceTreeDirty=[bool]$script:Options.DirtyPayload}
        }
        function New-WinAirPlaySecureDirectory {
            param($Path)
            $script:Events.Add('OutputCreated')
            $null=[IO.Directory]::CreateDirectory($Path)
        }
        function Assert-WinAirPlayTreeHasNoReparsePoints {param($Path)}
        function Assert-WinAirPlayRegularFile {param($Path)}
        function Assert-WinAirPlayPeX64 {
            param($Path)
            if($script:Options.BadPe){throw 'Fixture non-x64 PE.'}
        }
        function Get-Item {
            [CmdletBinding()]
            param([string]$LiteralPath)
            if($LiteralPath.StartsWith('Cert:\', [StringComparison]::OrdinalIgnoreCase)){
                $oids=[Security.Cryptography.OidCollection]::new()
                $null=$oids.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
                $eku=[Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($oids,$true)
                $certificate=[pscustomobject]@{HasPrivateKey=(-not $script:Options.InvalidCertificate);Thumbprint=$script:Pin;
                    FriendlyName='WinAirPlayAudio driver test signing';Subject='CN=synthetic';Issuer='CN=synthetic';
                    NotBefore=[DateTime]::UtcNow.AddDays(-1);NotAfter=[DateTime]::UtcNow.AddDays(1);Extensions=@($eku)}
                $certificate | Add-Member ScriptMethod Dispose { $script:Events.Add('CertificateDisposed') }
                return $certificate
            }
            return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
        }
        function Get-WinAirPlayGuiFileVersion {
            param($Path)
            if($script:Options.WrongVersion){return '9.9.9.9'}
            return '1.2.3.4'
        }
        function Get-WinAirPlayGuiDescription {
            param($Path)
            if($script:Options.DescriptionPreview){return 'UI Preview'}
            return 'Synthetic release wizard'
        }
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            $name=[IO.Path]::GetFileName($LiteralPath)
            if($script:Signed.ContainsKey($name) -or $script:Options.PreSigned){
                $pin=if($script:Options.WrongSigner){'B'*40}else{$script:Pin}
                $status=if($script:Options.InvalidSignature){'HashMismatch'}else{'Valid'}
                return [pscustomobject]@{Status=$status;SignerCertificate=[pscustomobject]@{Thumbprint=$pin}}
            }
            return [pscustomobject]@{Status='NotSigned';SignerCertificate=$null}
        }
        function New-WinAirPlaySigningToolSnapshot {
            $script:Events.Add('Snapshot')
            return [pscustomobject]@{SignToolPath='synthetic-signtool';SignToolWorkingDirectory='synthetic';TemporaryDirectory='synthetic';SnapshotDirectory='synthetic-snapshot'}
        }
        function Invoke-WinAirPlayAuthenticatedTool {
            param($FilePath,$WorkingDirectory,$TemporaryDirectory,$ArgumentList)
            $kind=$ArgumentList[0]
            $path=$ArgumentList[-1]
            $script:Events.Add($kind)
            if($kind -ceq 'sign'){
                if($script:Options.SignFailure){throw 'Fixture sign failed.'}
                if('/sm' -notin $ArgumentList -or '/sha1' -notin $ArgumentList -or 'SHA256' -notin $ArgumentList){throw 'Fixture signing flags omitted.'}
                [IO.File]::WriteAllBytes($path,([IO.File]::ReadAllBytes($path)+[byte[]](9,8,7)))
                $script:Signed[[IO.Path]::GetFileName($path)]=$true
            }elseif($kind -ceq 'verify'){
                if('/pa' -notin $ArgumentList){throw 'Fixture verification policy omitted.'}
                if($script:Options.VerifyFailure){throw 'Fixture verification failed.'}
            }else{throw 'Unexpected fixture tool command.'}
        }
        function Remove-WinAirPlaySigningToolSnapshot {
            param($SnapshotDirectory)
            $script:Events.Add('SnapshotRemoved')
            if($script:Options.CleanupFailure){throw 'Fixture tool cleanup failed.'}
        }
        . ([scriptblock]::Create($Code))
        Export-ModuleMember -Function Invoke-WinAirPlayGuiSigning
    } -ArgumentList $signingFunction,$directory,$options
    return [pscustomobject]@{Module=$module;Directory=$directory;Options=$options}
}

function Invoke-GuiSigningCase {
    param([string]$Name,[hashtable]$Changes=@{},[string]$ExpectedError='', [string[]]$Required=@(),[string[]]$Forbidden=@())
    $fixture=New-GuiSigningFixture $Changes
    $parameters=@{RepositoryRoot=$fixture.Directory;BundleDirectory=(Join-Path $fixture.Directory 'input');
        OutputDirectory=(Join-Path $fixture.Directory 'output');Version='1.2.3-rc.1';SourceCommit=('1'*40);
        ExpectedSignedManifestSha256=('C'*64);ExpectedSignerThumbprint=('A'*40)}
    $result=$null;$failure=$null
    try{$result=& $fixture.Module {param($Parameters) Invoke-WinAirPlayGuiSigning @Parameters} $parameters}
    catch{$failure=$_}
    $events=@(& $fixture.Module {$script:Events.ToArray()})
    if($ExpectedError){
        $failureMessage=if($failure){$failure.Exception.Message}else{'none'}
        Assert-GuiFixture ($null -ne $failure -and $failureMessage -match $ExpectedError) "${Name}: wrong/missing error: $failureMessage"
    }else{
        if($failure){throw $failure}
        Assert-GuiFixture ($result.Directory -ceq $parameters.OutputDirectory) 'Successful signing result omitted its directory.'
        $inventoryPath=Join-Path $result.Directory 'wizard-build.json'
        $inventory=Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
        Assert-GuiFixture ($inventory.SourceCommit -ceq ('1'*40) -and $inventory.SigningState -ceq 'test-signed') 'Final GUI inventory lacks source/signing provenance.'
        Assert-GuiFixture ($inventory.Files.Count -eq 2 -and @($events|Where-Object {$_ -ceq 'sign'}).Count -eq 2 -and @($events|Where-Object {$_ -ceq 'verify'}).Count -eq 2) 'Signing/verification must execute for both EXEs.'
        foreach($entry in $inventory.Files){
            $path=Join-Path $result.Directory $entry.Name
            Assert-GuiFixture ($entry.Bytes -eq 9 -and $entry.Sha256 -ceq (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -and $entry.SignatureStatus -ceq 'Valid' -and $entry.SignerThumbprint -ceq ('A'*40)) 'Final GUI inventory does not describe signed bytes and signer.'
        }
        Assert-GuiFixture ($result.ManifestSha256 -ceq (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash) 'Returned GUI manifest anchor does not identify final inventory.'
        Assert-GuiFixture (-not ([IO.File]::ReadAllText($inventoryPath).Contains($fixture.Directory))) 'Portable inventory leaked a local path.'
    }
    foreach($event in $Required){Assert-GuiFixture ($event -cin $events) "${Name}: missing event $event"}
    foreach($event in $Forbidden){Assert-GuiFixture ($event -cnotin $events) "${Name}: forbidden event $event"}
    if('OutputCreated' -cin $events){
        Assert-GuiFixture (('CertificateDisposed' -cin $events) -and
            [Array]::IndexOf([object[]]$events,'CertificateDisposed') -lt [Array]::IndexOf([object[]]$events,'OutputCreated')) 'Managed certificate handle must be disposed before compilation starts.'
    }
    if($fixture.Options.OutputExists){Assert-GuiFixture ((Get-Content -LiteralPath (Join-Path $parameters.OutputDirectory 'retained.txt') -Raw) -ceq 'must remain unchanged') 'Existing output changed.'}
    $script:caseCount++
    Write-Host "PASS: $Name"
}

try {
    Invoke-GuiSigningCase 'both wizards signed, verified and final inventory anchored' -Required CertificateDisposed,Snapshot,sign,verify,SnapshotRemoved
    Invoke-GuiSigningCase 'non-hosted context rejected' @{BadContext=$true} 'non-hosted context' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'payload authentication precedes signing' @{BadPayload=$true} 'payload authentication' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'payload source must match tag' @{WrongPayloadSource=$true} 'exact clean tagged source' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'dirty payload rejected' @{DirtyPayload=$true} 'exact clean tagged source' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'unsafe output parent rejected' @{UnsafeParent=$true} 'unsafe directory' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'existing output preserved' @{OutputExists=$true} 'output already exists' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'source version must match tag' @{WrongSourceVersion=$true} 'source version differs' -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'dedicated private identity required' @{InvalidCertificate=$true} 'dedicated valid test identity' -Required CertificateDisposed -Forbidden OutputCreated,Snapshot,sign
    Invoke-GuiSigningCase 'compiler failure stops signing' @{BuildFailure=$true} 'compiler failure' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'unexpected compiler payload rejected' @{ExtraFile=$true} 'exact two-wizard inventory' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'preview inventory rejected' @{Preview=$true} 'non-preview release build' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'preimage hash mismatch rejected' @{WrongHash=$true} 'unsigned preimage/hash/version' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'pre-existing Authenticode signature rejected' @{PreSigned=$true} 'unsigned preimage/hash/version' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'wrong PE version rejected' @{WrongVersion=$true} 'unsigned preimage/hash/version' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'preview executable description rejected' @{DescriptionPreview=$true} 'unsigned preimage/hash/version' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'non-x64 PE rejected' @{BadPe=$true} 'non-x64 PE' -Forbidden Snapshot,sign
    Invoke-GuiSigningCase 'sign failure cleans authenticated tool snapshot' @{SignFailure=$true} 'sign failed' -Required Snapshot,sign,SnapshotRemoved -Forbidden verify
    Invoke-GuiSigningCase 'verification failure cleans tool snapshot' @{VerifyFailure=$true} 'verification failed' -Required Snapshot,sign,verify,SnapshotRemoved
    Invoke-GuiSigningCase 'unexpected signer rejected after verification' @{WrongSigner=$true} 'signature or version postcondition' -Required Snapshot,sign,verify,SnapshotRemoved
    Invoke-GuiSigningCase 'invalid Authenticode postcondition rejected' @{InvalidSignature=$true} 'signature or version postcondition' -Required Snapshot,sign,verify,SnapshotRemoved
    Invoke-GuiSigningCase 'tool cleanup failure cannot report success' @{CleanupFailure=$true} 'GUI signing-tool cleanup failed' -Required SnapshotRemoved
    Invoke-GuiSigningCase 'primary and tool cleanup failures both reported' @{SignFailure=$true;CleanupFailure=$true} 'sign failed.*GUI signing-tool cleanup failed' -Required SnapshotRemoved
    Write-Host "GUI signing fixtures passed ($caseCount cases). Compiler, PE/signature/certificate and tool operations were mocked; no real signing or machine trust changes occurred."
} finally {
    $full=[IO.Path]::GetFullPath($fixtureRoot)
    if([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetFullPath($fixtureParent) -or
        [IO.Path]::GetFileName($full) -cnotmatch '^[0-9a-f]{32}$') {throw 'Refusing GUI signing fixture cleanup outside its exact root.'}
    foreach($entry in @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Force -Recurse)){
        if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture cleanup refuses a reparse point.'}
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    Assert-GuiFixture (-not (Test-Path -LiteralPath $full)) 'GUI signing fixture cleanup was incomplete.'
}
