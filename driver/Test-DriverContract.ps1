[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [Collections.Generic.List[string]]::new()

function Assert-TextContains {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -notmatch $Pattern) {
        $script:failures.Add($Message)
    }
}

function Assert-TextExcludes {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match $Pattern) {
        $script:failures.Add($Message)
    }
}

$inf = Join-Path $PSScriptRoot 'WinAirPlayAudio.inx'
$project = Join-Path $PSScriptRoot 'WinAirPlayAudio.vcxproj'
$packageProject = Join-Path $PSScriptRoot 'Package\WinAirPlayAudioPackage.vcxproj'
$wave = Join-Path $PSScriptRoot 'Source\Filters\speakerwavtable.h'
$topology = Join-Path $PSScriptRoot 'Source\Filters\speakertoptable.h'
$pairs = Join-Path $PSScriptRoot 'Source\Filters\minipairs.h'
$common = Join-Path $PSScriptRoot 'Source\Main\common.cpp'
$miniport = Join-Path $PSScriptRoot 'Source\Main\minwavert.cpp'
$miniportHeader = Join-Path $PSScriptRoot 'Source\Main\minwavert.h'
$stream = Join-Path $PSScriptRoot 'Source\Main\minwavertstream.cpp'
$streamHeader = Join-Path $PSScriptRoot 'Source\Main\minwavertstream.h'
$metadata = Join-Path $PSScriptRoot 'Source\Inc\metadata.h'
$buildScript = Join-Path $PSScriptRoot 'Build-Driver.ps1'

Assert-TextContains $inf 'ROOT\\WinAirPlayAudio' 'INF hardware ID ROOT\WinAirPlayAudio is missing.'
Assert-TextExcludes $inf 'KSCATEGORY_CAPTURE|WaveMic|TopologyMic' 'INF exposes a capture/microphone interface.'
Assert-TextContains $inf 'NTamd64\.10\.0\.\.\.26100' 'INF is not restricted to Windows 11 24H2 x64.'
Assert-TextContains $wave 'SPEAKER_HOST_MIN_SAMPLE_RATE\s+48000' 'Render format minimum is not fixed at 48 kHz.'
Assert-TextContains $wave 'SPEAKER_HOST_MAX_SAMPLE_RATE\s+48000' 'Render format maximum is not fixed at 48 kHz.'
Assert-TextContains $wave 'SPEAKER_HOST_MIN_BITS_PER_SAMPLE\s+16' 'Render format minimum is not fixed at 16-bit.'
Assert-TextContains $wave 'SPEAKER_HOST_MAX_CHANNELS\s+2' 'Render format is not stereo.'
Assert-TextContains $wave 'KSPIN_WAVE_RENDER2_SINK_LOOPBACK' 'Wave filter omits the rendered-mix loopback pin.'
Assert-TextContains $wave '&KSNODETYPE_AUDIO_LOOPBACK' 'Loopback pin is not categorized as KSNODETYPE_AUDIO_LOOPBACK.'
Assert-TextContains $wave 'KSPROPSETID_AudioLoopback[\s\S]{0,120}KSPROPERTY_AUDIOLOOPBACK_TAPPOINT_CAPS' 'Windows 11 24H2 loopback tap-point capability is not advertised.'
Assert-TextContains $miniport 'PropertyHandlerAudioLoopbackTappointCaps[\s\S]{0,1800}AUDIOLOOPBACK_TAPPOINT_CAPS_PREVOLUMEMUTE' 'Loopback capability handler does not implement the required pre-volume/mute tap point.'
Assert-TextContains $stream 'ValidateLoopbackTapPointAttribute[\s\S]{0,3000}KSATTRIBUTEID_AUDIOLOOPBACK_TAPPOINT[\s\S]{0,900}AUDIOLOOPBACK_TAPPOINT_PREVOLUMEMUTE' 'Loopback pin creation does not validate the Windows 11 24H2 tap-point attribute.'
Assert-TextExcludes $miniport 'AUDIOLOOPBACK_TAPPOINT_CAPS_POSTVOLUMEMUTE' 'Driver claims an unimplemented post-volume/mute loopback tap point.'
$waveText = Get-Content -LiteralPath $wave -Raw
if ([regex]::Matches($waveText, '&KSNODETYPE_AUDIO_LOOPBACK').Count -ne 1) {
    $failures.Add('Wave filter must expose exactly one rendered-mix loopback pin.')
}
Assert-TextContains $topology '0,\s+// NodeCount; Windows supplies software volume/mute' 'Topology does not opt into Windows software volume.'
Assert-TextExcludes $topology 'KSNODETYPE_VOLUME|KSNODETYPE_MUTE' 'Topology still advertises fake hardware volume/mute.'
Assert-TextContains (Join-Path $PSScriptRoot 'Source\Main\basetopo.cpp') 'PropertyHandlerMuxSource[\s\S]{0,900}return STATUS_NOT_SUPPORTED;' 'Render-only topology retains an active sample mux-property path.'
Assert-TextExcludes $pairs 'g_CaptureEndpoints|MicArray' 'Endpoint table still contains capture endpoints.'
Assert-TextExcludes $common 'm_AdapterInstances|only one instance is allowed' 'Adapter singleton still blocks multiple receivers.'
Assert-TextContains $common 'DEVPKEY_DeviceInterface_FriendlyName' 'Driver does not set a per-instance audio-interface friendly name.'
Assert-TextContains $common 'IoSetDeviceInterfacePropertyData\(\s*AudioSymbolicLinkName,\s*&DEVPKEY_WinAirPlayAudio_ReceiverId' 'Driver does not copy stable receiver identity to the audio interface.'
Assert-TextExcludes $stream 'SaveData|ToneGenerator|GenerateSine|HostCaptureTone' 'Stream still contains sample file-output or tone-generation behavior.'
Assert-TextContains $stream '\(Capture_ && !miniport->IsLoopbackPin\(Pin_\)\)[\s\S]{0,120}return STATUS_NOT_SUPPORTED;' 'Stream accepts capture on a pin other than the rendered-mix loopback pin.'
Assert-TextContains $miniport 'CopyRenderDataToLoopback[\s\S]{0,1800}loopback->CopyRenderData' 'Miniport does not feed actual render bytes to the loopback stream.'
Assert-TextContains $stream 'CMiniportWaveRTStream::CopyRenderData[\s\S]{0,6000}RtlCopyMemory' 'Loopback stream does not copy bounded render-buffer bytes.'
Assert-TextContains $stream 'CMiniportWaveRTStream::AllocateAudioBuffer[\s\S]{0,700}if\s*\(!m_bCapture\)[\s\S]{0,120}return STATUS_NOT_SUPPORTED;' 'Render streams still accept polling buffers even though polling exposes no producer-commit boundary.'
Assert-TextContains $stream 'CMiniportWaveRTStream::AllocateBufferWithNotification[\s\S]{0,1200}NotificationCount_\s*==\s*0\s*\|\|[\s\S]{0,120}\(!m_bCapture\s*&&[\s\S]{0,120}NotificationCount_\s*>\s*MAX_RENDER_PACKET_SLOTS\)' 'Capture notification buffers are still restricted to the render stream''s fixed commit-slot count.'
Assert-TextExcludes $stream 'NotificationCount_\s*!=\s*1\s*&&\s*NotificationCount_\s*!=\s*2' 'Notification buffer allocation still rejects capture counts above two unconditionally.'
Assert-TextContains $stream 'bufferDurationMs\s*>\s*MAXULONG[\s\S]{0,240}notificationIntervalMs\s*=[\s\S]{0,160}if\s*\(!m_bCapture\s*&&\s*notificationIntervalMs\s*==\s*0\)' 'Sub-millisecond notification intervals are still rejected for producer-driven capture streams.'
Assert-TextContains $streamHeader 'typedef struct _RenderPacketCommit[\s\S]{0,160}ULONGLONG\s+PacketNumber;[\s\S]{0,80}BOOLEAN\s+Valid;' 'Render commit tags do not retain an exact 64-bit logical packet identity.'
Assert-TextContains $stream 'CMiniportWaveRTStream::SetWritePacket[\s\S]{0,3200}m_RenderPacketCommits\[packetIndex\]\.Valid\s*=\s*FALSE;[\s\S]{0,500}if\s*\(Flags\s*!=\s*0\)[\s\S]{0,3200}m_RenderPacketCommits\[packetIndex\]\.PacketNumber\s*=\s*expectedLogicalPacket;[\s\S]{0,160}Valid\s*=\s*TRUE;' 'SetWritePacket does not invalidate overwritten slots, reject unsupported flags, and publish an exact commit atomically.'
Assert-TextContains $stream 'rangeRemaining\s*>\s*m_ulDmaBufferSize[\s\S]{0,260}rangeRemaining\s*=\s*m_ulDmaBufferSize;[\s\S]{0,1800}commit->Valid[\s\S]{0,120}commit->PacketNumber\s*==\s*logicalPacket[\s\S]{0,500}CopyRenderDataToLoopback' 'Render consumption is not bounded to the resident ring and keyed to the exact committed logical packet.'
Assert-TextExcludes $stream 'm_ullRenderBytesAvailable' 'Render loopback still relies on a scalar byte credit that can alias stale ring packets after underrun.'
Assert-TextContains $stream 'CMiniportWaveRTStream::GetReadPacket[\s\S]{0,3200}streamGeneration\s*=\s*m_ullStreamGeneration;[\s\S]{0,7000}m_ullStreamGeneration\s*!=\s*streamGeneration[\s\S]{0,900}m_ulLastOsReadPacket\s*=\s*availablePacketNumber;[\s\S]{0,200}m_bDataDiscontinuity\s*=\s*FALSE;' 'Capture packet publication is not guarded against a concurrent STOP or buffer-generation change.'
Assert-TextContains $miniport 'm_LoopbackDataWithheld\s*=\s*TRUE;[\s\S]{0,500}DataDiscontinuity\s*\|\|\s*m_LoopbackDataWithheld[\s\S]{0,700}loopback->CopyRenderData' 'DRM-withheld audio does not mark the first resumed loopback packet as discontinuous.'
Assert-TextContains $stream 'DataFormat_->FormatSize\s*!=\s*sizeof\(KSDATAFORMAT_WAVEFORMATEXTENSIBLE\)' 'Stream does not require the exact caller format before copying it.'
Assert-TextContains $common 'm_ReceiverId' 'Driver common adapter does not retain per-instance receiver identity.'
Assert-TextContains $miniport 'DataFormat->FormatSize\s*!=\s*sizeof\(KSDATAFORMAT_WAVEFORMATEXTENSIBLE\)' 'NewStream follows data before validating the exact base format size.'
Assert-TextContains $miniport 'nAvgBytesPerSec\s*!=\s*pFormat->WaveFormatExt.Format.nAvgBytesPerSec' 'Format validation accepts a caller-controlled average byte rate.'
Assert-TextContains $stream 'ExDeleteTimer[\s\S]{0,500}KeFlushQueuedDpcs\(\)[\s\S]{0,800}m_pMiniport->Release' 'Stream teardown does not join timer callbacks before releasing callback state.'
Assert-TextExcludes $miniportHeader 'm_pAdapterCommon|GetAdapterCommObj' 'WaveRT miniport retains an adapter pointer that can outlive the adapter PnP reference.'
Assert-TextExcludes $stream 'GetAdapterCommObj|WriteEtwEvent|PADAPTERCOMMON' 'A WaveRT stream still calls through the adapter or PortCls ETW helper during teardown.'
Assert-TextExcludes $common 'PPORTCLSETWHELPER|WriteEtwEvent|SetEtwHelper' 'Adapter retains the unused PortCls ETW helper and its teardown reference cycle.'
$timerCallback = [regex]::Match(
    (Get-Content -LiteralPath $stream -Raw),
    '(?s)\bTimerNotifyRT\s*\(.*?\n\}\s*//=============================================================================')
if (-not $timerCallback.Success) {
    $failures.Add('TimerNotifyRT callback could not be isolated for teardown-safety checks.')
}
elseif ($timerCallback.Value -match 'GetAdapterCommObj|WriteEtwEvent|PADAPTERCOMMON') {
    $failures.Add('TimerNotifyRT still calls through the adapter/PortCls interface from DISPATCH_LEVEL.')
}
Assert-TextContains $stream 'previousState\s*==\s*KSSTATE_RUN\s*&&\s*State_\s*!=\s*KSSTATE_RUN[\s\S]{0,300}m_KsState\s*=\s*State_;[\s\S]{0,700}ExCancelTimer[\s\S]{0,150}KeFlushQueuedDpcs' 'A RUN-to-non-RUN transition is not published before the notification callback is joined.'
Assert-TextContains $stream 'case KSSTATE_STOP:[\s\S]{0,500}m_KsState\s*=\s*KSSTATE_STOP;[\s\S]{0,300}m_ullStreamGeneration\+\+;[\s\S]{0,120}m_llPacketCounter\s*=\s*0;' 'STOP resets capture-visible counters without first publishing STOP and invalidating stale packet readers.'
Assert-TextContains $stream 'KeAcquireSpinLock\(&m_PositionSpinLock[\s\S]{0,900}InsertTailList\(&m_NotificationList' 'Notification registration does not synchronize with timer traversal.'
Assert-TextContains $stream 'm_ulDmaBufferSize\s*==\s*0[\s\S]{0,150}m_ulDmaMovementRate\s*==\s*0[\s\S]{0,150}return;' 'Position updates do not fail closed after buffer teardown.'
Assert-TextContains $stream 'm_KsState\s*=\s*KSSTATE_RUN;[\s\S]{0,500}if\s*\(m_ulNotificationIntervalMs\s*>\s*0' 'Legacy polling streams do not enter RUN without a notification timer.'
Assert-TextContains $stream 'ULONGLONG TimeElapsedInMS[\s\S]{0,1200}ULONGLONG ByteDisplacement' 'Position arithmetic can truncate or overflow after a long scheduling stall.'
Assert-TextContains $stream 'completedPackets\s*=\s*\(newLinearPosition\s*/\s*renderPacketSize\)\s*-[\s\S]{0,500}m_llPacketCounter\s*\+=' 'Render packet count is not derived from actual linear packet-boundary crossings.'
Assert-TextContains $stream 'm_llPacketCounter\s*>\s*_this->m_llLastNotifiedPacketCounter[\s\S]{0,240}bufferCompleted\s*=\s*TRUE;' 'Notification events are not gated by a newly completed render packet.'
Assert-TextExcludes $stream 'm_llPacketCounter\+\+' 'Timer callbacks still increment packet count independently of linear packet completion.'
Assert-TextContains $common 'if\s*\(!NT_SUCCESS\(ntStatus\)\)\s*\{\s*goto InstallComplete;' 'Topology installation failure can be overwritten by wave installation.'
Assert-TextContains $common 'NT_SUCCESS\(ntStatus\)\s*&&\s*!NT_SUCCESS\(ntStatus2\)' 'Physical-disconnect cleanup does not preserve the first failure.'
Assert-TextContains $metadata '54B65A8E-7CD3-4F7B-953B-59A21C2E5CDD' 'Custom receiver metadata property-set GUID changed unexpectedly.'
Assert-TextExcludes $project 'savedata\.cpp|tonegenerator\.cpp|micarray' 'Project compiles sample file output, tone generation, or microphone sources.'
Assert-TextContains $project '<TreatWarningAsError>true</TreatWarningAsError>' 'Warnings-as-errors is not enabled.'
Assert-TextContains $project '<SignMode>Off</SignMode>' 'Driver build implicitly creates or applies a test-signing certificate.'
Assert-TextContains $packageProject '<SignMode>Off</SignMode>' 'Package build implicitly creates or applies a test-signing certificate.'
# scripts/Version.ps1 owns mutable INF/project/resource version consistency.
Assert-TextContains $packageProject '<PackageDir>\$\(OutDir\)</PackageDir>' 'WDK package output does not match the documented exact package directory.'
Assert-TextContains $buildScript '/t:Rebuild[\s\S]{0,240}/p:TrackFileAccess=false[\s\S]{0,120}/p:UseMultiToolTask=false' 'Authoritative driver rebuild still depends on restricted-process MSBuild file tracking.'
Assert-TextContains $buildScript 'ProcessStartInfo[\s\S]{0,500}Environment\.Clear\(\)[\s\S]{0,500}-ieq\s+''Path''[\s\S]{0,500}Environment\[''Path''\]' 'Driver build does not normalize duplicate case-variant Path entries in the child MSBuild environment.'
Assert-TextContains $buildScript '/nodeReuse:false' 'Driver build permits a stale MSBuild worker to retain an unnormalized environment.'

$sourceFiles = Get-ChildItem (Join-Path $PSScriptRoot 'Source') -Recurse -File -Include *.cpp,*.h
$includeRoots = @(
    (Join-Path $PSScriptRoot 'Source\Inc'),
    (Join-Path $PSScriptRoot 'Source\Filters'),
    (Join-Path $PSScriptRoot 'Source\Main'),
    (Join-Path $PSScriptRoot 'Source\Utilities')
)
foreach ($source in $sourceFiles) {
    $text = Get-Content -LiteralPath $source.FullName -Raw
    foreach ($match in [regex]::Matches($text, '(?m)^\s*#include\s+"([^"]+)"')) {
        $include = $match.Groups[1].Value
        $local = Join-Path $source.DirectoryName $include
        $resolved = Test-Path -LiteralPath $local -PathType Leaf
        if (-not $resolved) {
            $resolved = $includeRoots |
                ForEach-Object { Join-Path $_ $include } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
        }
        if (-not $resolved) {
            $failures.Add("Unresolved quoted include '$include' in $($source.FullName).")
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "$($failures.Count) driver contract check(s) failed."
}

Write-Host 'WinAirPlayAudio static driver contract checks passed.'
