#include "definitions.h"
#include <limits.h>
#include <ks.h>
#include "endpoints.h"
#include "minwavert.h"
#include "minwavertstream.h"
#define MINWAVERTSTREAM_POOLTAG 'sWAW'
#define MAX_LOOPBACK_ATTRIBUTE_LIST_SIZE 1024

#pragma warning (disable : 4127)

//=============================================================================
#pragma code_seg("PAGE")
static NTSTATUS ValidateLoopbackTapPointAttribute
(
    _In_ PKSDATAFORMAT DataFormat
)
{
    PAGED_CODE();

    if (DataFormat == NULL ||
        (DataFormat->Flags & ~KSDATAFORMAT_ATTRIBUTES) != 0)
    {
        return STATUS_INVALID_PARAMETER;
    }
    if ((DataFormat->Flags & KSDATAFORMAT_ATTRIBUTES) == 0)
    {
        // Legacy/no-option loopback is defined as pre-volume and pre-mute.
        return STATUS_SUCCESS;
    }

    ULONG alignedFormatSize = 0;
    NTSTATUS ntStatus = RtlULongAdd(
        DataFormat->FormatSize,
        FILE_QUAD_ALIGNMENT,
        &alignedFormatSize);
    if (!NT_SUCCESS(ntStatus))
    {
        return ntStatus;
    }
    alignedFormatSize &= ~FILE_QUAD_ALIGNMENT;

    ULONG_PTR attributesAddress = 0;
    ntStatus = RtlULongPtrAdd(
        reinterpret_cast<ULONG_PTR>(DataFormat),
        alignedFormatSize,
        &attributesAddress);
    if (!NT_SUCCESS(ntStatus))
    {
        return ntStatus;
    }

    __try
    {
        const KSMULTIPLE_ITEM* attributes =
            reinterpret_cast<const KSMULTIPLE_ITEM*>(attributesAddress);
        if (attributes->Size < sizeof(KSMULTIPLE_ITEM) ||
            attributes->Size > MAX_LOOPBACK_ATTRIBUTE_LIST_SIZE ||
            attributes->Count >
                (attributes->Size - sizeof(KSMULTIPLE_ITEM)) /
                    sizeof(KSATTRIBUTE))
        {
            return STATUS_INVALID_PARAMETER;
        }

        size_t remaining =
            attributes->Size - sizeof(KSMULTIPLE_ITEM);
        const BYTE* cursor =
            reinterpret_cast<const BYTE*>(attributes + 1);
        BOOLEAN tapPointSeen = FALSE;

        for (ULONG i = 0; i < attributes->Count; ++i)
        {
            if (remaining < sizeof(KSATTRIBUTE))
            {
                return STATUS_INVALID_PARAMETER;
            }

            const KSATTRIBUTE* attribute =
                reinterpret_cast<const KSATTRIBUTE*>(cursor);
            if (attribute->Size < sizeof(KSATTRIBUTE) ||
                attribute->Size > remaining)
            {
                return STATUS_INVALID_PARAMETER;
            }

            if (IsEqualGUIDAligned(
                attribute->Attribute,
                KSATTRIBUTEID_AUDIOLOOPBACK_TAPPOINT))
            {
                if (tapPointSeen ||
                    attribute->Size !=
                        sizeof(KSATTRIBUTE_AUDIOLOOPBACK_TAPPOINT))
                {
                    return STATUS_INVALID_PARAMETER;
                }

                const KSATTRIBUTE_AUDIOLOOPBACK_TAPPOINT* tapPoint =
                    reinterpret_cast<
                        const KSATTRIBUTE_AUDIOLOOPBACK_TAPPOINT*>(
                            attribute);
                if (tapPoint->TapPoint !=
                    AUDIOLOOPBACK_TAPPOINT_PREVOLUMEMUTE)
                {
                    // Post-volume/mute is intentionally not advertised because
                    // this driver has only the pre-volume rendered-mix path.
                    return STATUS_NOT_SUPPORTED;
                }
                tapPointSeen = TRUE;
            }
            else if ((attribute->Flags & KSATTRIBUTE_REQUIRED) != 0)
            {
                return STATUS_NOT_SUPPORTED;
            }

            ULONG consumed = attribute->Size;
            if (remaining != attribute->Size)
            {
                ntStatus = RtlULongAdd(
                    attribute->Size,
                    FILE_QUAD_ALIGNMENT,
                    &consumed);
                if (!NT_SUCCESS(ntStatus))
                {
                    return ntStatus;
                }
                consumed &= ~FILE_QUAD_ALIGNMENT;
                if (consumed > remaining)
                {
                    return STATUS_INVALID_PARAMETER;
                }
            }

            cursor += consumed;
            remaining -= consumed;
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return STATUS_INVALID_PARAMETER;
    }

    return STATUS_SUCCESS;
}

//=============================================================================
// CMiniportWaveRTStream
//=============================================================================

//=============================================================================
#pragma code_seg("PAGE")
CMiniportWaveRTStream::~CMiniportWaveRTStream
( 
    void 
)
/*++

Routine Description:

  Destructor for wavertstream 

Arguments:

Return Value:

  NT status code.

--*/
{
    PAGED_CODE();
    // Withdraw the weak pointer first. StreamClosed takes the miniport stream
    // lock, so any render DPC already copying into this object must finish
    // before teardown continues, and no new copy can enter afterward.
    if (m_pMiniport != NULL && m_bUnregisterStream)
    {
        m_pMiniport->StreamClosed(m_ulPin, this);
        m_bUnregisterStream = FALSE;
    }

    // TimerNotifyRT dereferences the stream, miniport, notification list, and
    // position state. Cancel and join it before releasing any callback-reachable
    // object. ExDeleteTimer(..., Wait=TRUE) also waits for an active callback.
    if (m_pNotificationTimer)
    {
        ExDeleteTimer
        (
            m_pNotificationTimer,
            TRUE,
            TRUE,
            NULL
        );
        m_pNotificationTimer = NULL;
    }
    KeFlushQueuedDpcs();

    // The timer is now joined, so no callback can traverse this list. A stream
    // reaching destruction with registered events must still release every
    // nonpaged entry instead of leaking it.
    while (!IsListEmpty(&m_NotificationList))
    {
        PLIST_ENTRY entry = RemoveHeadList(&m_NotificationList);
        NotificationListEntry* notification =
            CONTAINING_RECORD(entry, NotificationListEntry, ListEntry);
        ExFreePoolWithTag(notification, MINWAVERTSTREAM_POOLTAG);
    }

    if (NULL != m_pMiniport)
    {
        m_pMiniport->Release();
        m_pMiniport = NULL;
    }

    if (m_pTimer)
    {
        ExFreePoolWithTag( m_pTimer, MINWAVERTSTREAM_POOLTAG );
        m_pTimer = NULL;
    }

    if (m_pbMuted)
    {
        ExFreePoolWithTag( m_pbMuted, MINWAVERTSTREAM_POOLTAG );
        m_pbMuted = NULL;
    }

    if (m_plVolumeLevel)
    {
        ExFreePoolWithTag( m_plVolumeLevel, MINWAVERTSTREAM_POOLTAG );
        m_plVolumeLevel = NULL;
    }

    if (m_plPeakMeter)
    {
        ExFreePoolWithTag( m_plPeakMeter, MINWAVERTSTREAM_POOLTAG );
        m_plPeakMeter = NULL;
    }

    if (m_pWfExt)
    {
        ExFreePoolWithTag( m_pWfExt, MINWAVERTSTREAM_POOLTAG );
        m_pWfExt = NULL;
    }
    DPF_ENTER(("[CMiniportWaveRTStream::~CMiniportWaveRTStream]"));
} // ~CMiniportWaveRTStream

NTSTATUS
CMiniportWaveRTStream::Init
( 
    _In_ PCMiniportWaveRT           Miniport_,
    _In_ PPORTWAVERTSTREAM          PortStream_,
    _In_ ULONG                      Pin_,
    _In_ BOOLEAN                    Capture_,
    _In_ PKSDATAFORMAT              DataFormat_,
    _In_ GUID                       SignalProcessingMode
)
/*++

Routine Description:

  Initializes the stream object.

Arguments:

  Miniport_ -

  Pin_ -

  DataFormat -

  SignalProcessingMode - The driver uses the signalProcessingMode to configure
    driver and/or hardware specific signal processing to be applied to this new
    stream.

Return Value:

  NT status code.

--*/
{
    PAGED_CODE();

    PWAVEFORMATEX pWfEx = NULL;
    NTSTATUS ntStatus = STATUS_SUCCESS;

    m_pMiniport = NULL;
    m_ulPin = 0;
    m_bUnregisterStream = FALSE;
    m_bCapture = FALSE;
    m_ulDmaBufferSize = 0;
    m_pDmaBuffer = NULL;
    m_ulNotificationsPerBuffer = 0;
    m_KsState = KSSTATE_STOP;
    m_pTimer = NULL;
    m_pNotificationTimer = NULL;
    m_llPacketCounter = 0;
    m_ullPlayPosition = 0;
    m_ullWritePosition = 0;
    m_ullDmaTimeStamp = 0;
    m_hnsElapsedTimeCarryForward = 0;
    m_ullLastDPCTimeStamp = 0;
    m_ullPerformanceCounterFrequency.QuadPart = 0;
    m_hnsDPCTimeCarryForward = 0;
    m_ulDmaMovementRate = 0;
    m_byteDisplacementCarryForward = 0;
    m_bLfxEnabled = FALSE;
    m_pbMuted = NULL;
    m_plVolumeLevel = NULL;
    m_plPeakMeter = NULL;
    m_pWfExt = NULL;
    m_ullLinearPosition = 0;
    m_ullPresentationPosition = 0;
    m_ulContentId = 0;
    m_ulCurrentWritePosition = 0;
    m_ulLastOsReadPacket = ULONG_MAX;
    m_ulLastOsWritePacket = ULONG_MAX;
    m_llLastNotifiedPacketCounter = 0;
    m_ullStreamGeneration = 0;
    RtlZeroMemory(m_RenderPacketCommits, sizeof(m_RenderPacketCommits));
    m_bRenderGapPending = FALSE;
    m_SignalProcessingMode = SignalProcessingMode;
    m_bEoSReceived = FALSE;
    m_bLastBufferRendered = FALSE;
    m_bDataDiscontinuity = FALSE;

    m_pPortStream = PortStream_;
    InitializeListHead(&m_NotificationList);
    m_ulNotificationIntervalMs = 0;

    // Initialize the spinlock to synchronize position updates
    KeInitializeSpinLock(&m_PositionSpinLock);

    CMiniportWaveRT* miniport =
        reinterpret_cast<CMiniportWaveRT*>(Miniport_);
    if (miniport == NULL ||
        (Capture_ && !miniport->IsLoopbackPin(Pin_)) ||
        (!Capture_ && !miniport->IsSystemRenderPin(Pin_)))
    {
        return STATUS_NOT_SUPPORTED;
    }

    m_pNotificationTimer = ExAllocateTimer(
         TimerNotifyRT,
         this,
         EX_TIMER_HIGH_RESOLUTION
    );
    if (!m_pNotificationTimer)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    if (DataFormat_ == NULL ||
        DataFormat_->FormatSize != sizeof(KSDATAFORMAT_WAVEFORMATEXTENSIBLE))
    {
        return STATUS_INVALID_PARAMETER;
    }

    pWfEx = GetWaveFormatEx(DataFormat_);
    if (NULL == pWfEx ||
        pWfEx->wFormatTag != WAVE_FORMAT_EXTENSIBLE ||
        pWfEx->cbSize != sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX) ||
        pWfEx->nChannels != 2 ||
        pWfEx->nSamplesPerSec != 48000 ||
        pWfEx->nBlockAlign != 4 ||
        pWfEx->wBitsPerSample != 16 ||
        pWfEx->nAvgBytesPerSec != 192000)
    { 
        return STATUS_INVALID_PARAMETER;
    }

    if (Capture_ && miniport->IsLoopbackPin(Pin_))
    {
        ntStatus = ValidateLoopbackTapPointAttribute(DataFormat_);
        if (!NT_SUCCESS(ntStatus))
        {
            return ntStatus;
        }
    }

    m_pMiniport = miniport;
    m_pMiniport->AddRef();
    if (!NT_SUCCESS(ntStatus))
    {
        return ntStatus;
    }
    m_ulPin = Pin_;
    m_bCapture = Capture_;
    // Derive the rate from the independently validated fixed format instead
    // of retaining a caller-controlled denominator.
    m_ulDmaMovementRate = pWfEx->nSamplesPerSec * pWfEx->nBlockAlign;

    m_pWfExt = (PWAVEFORMATEXTENSIBLE)ExAllocatePool2(
        POOL_FLAG_NON_PAGED,
        sizeof(WAVEFORMATEXTENSIBLE),
        MINWAVERTSTREAM_POOLTAG);
    if (m_pWfExt == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlCopyMemory(m_pWfExt, pWfEx, sizeof(WAVEFORMATEXTENSIBLE));

    m_pbMuted = (PBOOL)ExAllocatePool2(POOL_FLAG_NON_PAGED, m_pWfExt->Format.nChannels * sizeof(BOOL), MINWAVERTSTREAM_POOLTAG);
    if (m_pbMuted == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    m_plVolumeLevel = (PLONG)ExAllocatePool2(POOL_FLAG_NON_PAGED, m_pWfExt->Format.nChannels * sizeof(LONG), MINWAVERTSTREAM_POOLTAG);
    if (m_plVolumeLevel == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    m_plPeakMeter = (PLONG)ExAllocatePool2(POOL_FLAG_NON_PAGED, m_pWfExt->Format.nChannels * sizeof(LONG), MINWAVERTSTREAM_POOLTAG);
    if (m_plPeakMeter == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    //
    // Register this stream.
    //
    ntStatus = m_pMiniport->StreamCreated(m_ulPin, this);
    if (NT_SUCCESS(ntStatus))
    {
        m_bUnregisterStream = TRUE;
    }

    return ntStatus;
} // Init

//=============================================================================
#pragma code_seg("PAGE")
STDMETHODIMP_(NTSTATUS)
CMiniportWaveRTStream::NonDelegatingQueryInterface
( 
    _In_ REFIID  Interface,
    _COM_Outptr_ PVOID * Object 
)
/*++

Routine Description:

  QueryInterface

Arguments:

  Interface - GUID

  Object - interface pointer to be returned

Return Value:

  NT status code.

--*/
{
    PAGED_CODE();

    ASSERT(Object);

    if (IsEqualGUIDAligned(Interface, IID_IUnknown))
    {
        *Object = PVOID(PUNKNOWN(PMINIPORTWAVERTSTREAM(this)));
    }
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportWaveRTStream))
    {
        *Object = PVOID(PMINIPORTWAVERTSTREAM(this));
    }
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportWaveRTStreamNotification))
    {
        *Object = PVOID(PMINIPORTWAVERTSTREAMNOTIFICATION(this));
    }
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportWaveRTInputStream) && (this->m_bCapture))
    {
        // This interface is supported only on capture streams
        *Object = PVOID(PMINIPORTWAVERTINPUTSTREAM(this));
    }
    else if (IsEqualGUIDAligned(Interface, IID_IMiniportWaveRTOutputStream) && (!this->m_bCapture))
    {
        // This interface is supported only on host render streams
        *Object = PVOID(PMINIPORTWAVERTOUTPUTSTREAM(this));
    }
    else if (IsEqualGUIDAligned(Interface, IID_IDrmAudioStream))
    {
        *Object = (PVOID)(IDrmAudioStream*)this;
    }
    else
    {
        *Object = NULL;
    }

    if (*Object)
    {
        PUNKNOWN(*Object)->AddRef();
        return STATUS_SUCCESS;
    }

    return STATUS_INVALID_PARAMETER;
} // NonDelegatingQueryInterface

//=============================================================================
#pragma code_seg("PAGE")
NTSTATUS CMiniportWaveRTStream::AllocateBufferWithNotification
(
    _In_    ULONG               NotificationCount_,
    _In_    ULONG               RequestedSize_,
    _Out_   PMDL                *AudioBufferMdl_,
    _Out_   ULONG               *ActualSize_,
    _Out_   ULONG               *OffsetFromFirstPage_,
    _Out_   MEMORY_CACHING_TYPE *CacheType_
)
{
    PAGED_CODE();

    ULONG ulBufferDurationMs = 0;

    if (m_pWfExt == NULL ||
        m_pPortStream == NULL ||
        m_ulDmaMovementRate == 0 ||
        m_pWfExt->Format.nBlockAlign == 0 ||
        (0 == RequestedSize_) ||
        (RequestedSize_ < m_pWfExt->Format.nBlockAlign) ||
        (RequestedSize_ > DMA_BUFFER_SIZE))
    { 
        return STATUS_UNSUCCESSFUL; 
    }
    
    // Capture packet publication is count-generic. Keep render bounded by the
    // fixed commit-tag array that protects the producer/consumer boundary.
    if (NotificationCount_ == 0 ||
        (!m_bCapture &&
            NotificationCount_ > MAX_RENDER_PACKET_SLOTS))
    {
        return STATUS_INVALID_PARAMETER;
    }

    RequestedSize_ -= RequestedSize_ % (m_pWfExt->Format.nBlockAlign);
    if ((RequestedSize_ % NotificationCount_) != 0 ||
        ((RequestedSize_ / NotificationCount_) %
            m_pWfExt->Format.nBlockAlign) != 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    ULONGLONG bufferDurationMs =
        (static_cast<ULONGLONG>(RequestedSize_) * 1000ULL) /
        static_cast<ULONGLONG>(m_ulDmaMovementRate);
    if (bufferDurationMs == 0 ||
        bufferDurationMs > MAXULONG)
    {
        return STATUS_INVALID_PARAMETER;
    }
    ulBufferDurationMs = static_cast<ULONG>(bufferDurationMs);
    ULONG notificationIntervalMs =
        ulBufferDurationMs / NotificationCount_;
    if (!m_bCapture && notificationIntervalMs == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }
    
    PHYSICAL_ADDRESS highAddress;
    highAddress.HighPart = 0;
    highAddress.LowPart = MAXULONG;

    PMDL pBufferMdl = m_pPortStream->AllocatePagesForMdl (highAddress, RequestedSize_);

    if (NULL == pBufferMdl)
    {
        return STATUS_UNSUCCESSFUL;
    }

    // From MSDN: 
    // "Since the Windows audio stack does not support a mechanism to express memory access 
    //  alignment requirements for buffers, audio drivers must select a caching type for mapped
    //  memory buffers that does not impose platform-specific alignment requirements. In other 
    //  words, the caching type used by the audio driver for mapped memory buffers, must not make 
    //  assumptions about the memory alignment requirements for any specific platform.
    //
    //  This method maps the physical memory pages in the MDL into kernel-mode virtual memory. 
    //  Typically, the miniport driver calls this method if it requires software access to the 
    //  scatter-gather list for an audio buffer. In this case, the storage for the scatter-gather 
    //  list must have been allocated by the IPortWaveRTStream::AllocatePagesForMdl or 
    //  IPortWaveRTStream::AllocateContiguousPagesForMdl method. 
    //
    //  A WaveRT miniport driver should not require software access to the audio buffer itself."
    //   
    BYTE* mappedBuffer =
        (BYTE*)m_pPortStream->MapAllocatedPages(pBufferMdl, MmCached);
    if (mappedBuffer == NULL)
    {
        m_pPortStream->FreePagesFromMdl(pBufferMdl);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    // The capture stream never reports these initial bytes as a packet, but
    // clearing them avoids exposing stale nonpaged-pool contents if teardown or
    // a malformed caller reads outside the normal notification contract.
    RtlZeroMemory(mappedBuffer, RequestedSize_);

    AttachDmaBuffer(
        mappedBuffer,
        RequestedSize_,
        NotificationCount_,
        notificationIntervalMs);

    *AudioBufferMdl_ = pBufferMdl;
    *ActualSize_ = RequestedSize_;
    *OffsetFromFirstPage_ = 0;
    *CacheType_ = MmCached;

    return STATUS_SUCCESS;
}

//=============================================================================
#pragma code_seg("PAGE")
VOID CMiniportWaveRTStream::FreeBufferWithNotification
(
    _In_        PMDL    Mdl_,
    _In_        ULONG   Size_
)
{
    UNREFERENCED_PARAMETER(Size_);

    PAGED_CODE();

    // Be defensive if PortCls tears down a buffer without a preceding STOP.
    // No timer callback may retain or update buffer state after this returns.
    if (m_pNotificationTimer != NULL)
    {
        ExCancelTimer(m_pNotificationTimer, NULL);
        KeFlushQueuedDpcs();
    }

    BYTE* mappedBuffer = DetachDmaBuffer();

    if (Mdl_ != NULL)
    {
        if (mappedBuffer != NULL)
        {
            m_pPortStream->UnmapAllocatedPages(mappedBuffer, Mdl_);
        }
        
        m_pPortStream->FreePagesFromMdl(Mdl_);
    }
    
    return;
}

//=============================================================================
#pragma code_seg()
NTSTATUS CMiniportWaveRTStream::RegisterNotificationEvent
(
    _In_ PKEVENT NotificationEvent_
)
{
    if (NotificationEvent_ == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    NotificationListEntry *nleNew = (NotificationListEntry*)ExAllocatePool2( 
        POOL_FLAG_NON_PAGED,
        sizeof(NotificationListEntry),
        MINWAVERTSTREAM_POOLTAG);
    if (NULL == nleNew)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    nleNew->NotificationEvent = NotificationEvent_;

    BOOLEAN duplicate = FALSE;
    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);

    // TimerNotifyRT traverses this list under the same spin lock.
    if (!IsListEmpty(&m_NotificationList))
    {
        PLIST_ENTRY leCurrent = m_NotificationList.Flink;
        while (leCurrent != &m_NotificationList)
        {
            NotificationListEntry* nleCurrent = CONTAINING_RECORD( leCurrent, NotificationListEntry, ListEntry);
            if (nleCurrent->NotificationEvent == NotificationEvent_)
            {
                duplicate = TRUE;
                break;
            }

            leCurrent = leCurrent->Flink;
        }
    }

    if (!duplicate)
    {
        InsertTailList(&m_NotificationList, &(nleNew->ListEntry));
    }
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    if (duplicate)
    {
        ExFreePoolWithTag(nleNew, MINWAVERTSTREAM_POOLTAG);
        return STATUS_OBJECT_NAME_COLLISION;
    }
    
    return STATUS_SUCCESS;
}

//=============================================================================
#pragma code_seg()
NTSTATUS CMiniportWaveRTStream::UnregisterNotificationEvent
(
    _In_ PKEVENT NotificationEvent_
)
{
    if (NotificationEvent_ == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    NotificationListEntry* removed = NULL;
    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    if (!IsListEmpty(&m_NotificationList))
    {
        PLIST_ENTRY leCurrent = m_NotificationList.Flink;
        while (leCurrent != &m_NotificationList)
        {
            NotificationListEntry* nleCurrent = CONTAINING_RECORD( leCurrent, NotificationListEntry, ListEntry);
            if (nleCurrent->NotificationEvent == NotificationEvent_)
            {
                RemoveEntryList(leCurrent);
                removed = nleCurrent;
                break;
            }

            leCurrent = leCurrent->Flink;
        }
    }
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    if (removed == NULL)
    {
        return STATUS_NOT_FOUND;
    }

    ExFreePoolWithTag(removed, MINWAVERTSTREAM_POOLTAG);
    return STATUS_SUCCESS;
}


//=============================================================================
#pragma code_seg("PAGE")
NTSTATUS CMiniportWaveRTStream::GetClockRegister
(
    _Out_ PKSRTAUDIO_HWREGISTER Register_
)
{
    UNREFERENCED_PARAMETER(Register_);

    PAGED_CODE();

    return STATUS_NOT_IMPLEMENTED;
}

//=============================================================================
#pragma code_seg("PAGE")
NTSTATUS CMiniportWaveRTStream::GetPositionRegister
(
    _Out_ PKSRTAUDIO_HWREGISTER Register_
)
{
    UNREFERENCED_PARAMETER(Register_);

    PAGED_CODE();

    return STATUS_NOT_IMPLEMENTED;
}

//=============================================================================
#pragma code_seg("PAGE")
VOID CMiniportWaveRTStream::GetHWLatency
(
    _Out_ PKSRTAUDIO_HWLATENCY  Latency_
)
{
    PAGED_CODE();

    ASSERT(Latency_);

    Latency_->ChipsetDelay = 0;
    Latency_->CodecDelay = 0;
    Latency_->FifoSize = 0;
}

//=============================================================================
#pragma code_seg("PAGE")
VOID CMiniportWaveRTStream::FreeAudioBuffer
(
_In_opt_    PMDL        Mdl_,
_In_        ULONG       Size_
)
{
    UNREFERENCED_PARAMETER(Size_);

    PAGED_CODE();

    // Match the notification-buffer teardown safety if PortCls skips STOP.
    if (m_pNotificationTimer != NULL)
    {
        ExCancelTimer(m_pNotificationTimer, NULL);
        KeFlushQueuedDpcs();
    }

    BYTE* mappedBuffer = DetachDmaBuffer();

    if (Mdl_ != NULL)
    {
        if (mappedBuffer != NULL)
        {
            m_pPortStream->UnmapAllocatedPages(mappedBuffer, Mdl_);
        }

        m_pPortStream->FreePagesFromMdl(Mdl_);
    }

}

//=============================================================================
#pragma code_seg("PAGE")
NTSTATUS CMiniportWaveRTStream::AllocateAudioBuffer
(
_In_    ULONG                   RequestedSize_,
_Out_   PMDL                   *AudioBufferMdl_,
_Out_   ULONG                  *ActualSize_,
_Out_   ULONG                  *OffsetFromFirstPage_,
_Out_   MEMORY_CACHING_TYPE    *CacheType_
)
{
    PAGED_CODE();

    // Rendered-mix publication requires the packet commit information supplied
    // by IMiniportWaveRTOutputStream::SetWritePacket. Legacy polling WaveRT has
    // no equivalent producer-commit callback, so accepting it would let the
    // virtual DMA clock republish stale ring bytes after an underrun.
    if (!m_bCapture)
    {
        return STATUS_NOT_SUPPORTED;
    }

    if (m_pWfExt == NULL ||
        m_pPortStream == NULL ||
        m_pWfExt->Format.nBlockAlign == 0 ||
        (0 == RequestedSize_) ||
        (RequestedSize_ < m_pWfExt->Format.nBlockAlign) ||
        (RequestedSize_ > DMA_BUFFER_SIZE))
    {
        return STATUS_UNSUCCESSFUL;
    }

    RequestedSize_ -= RequestedSize_ % (m_pWfExt->Format.nBlockAlign);

    PHYSICAL_ADDRESS highAddress;
    highAddress.HighPart = 0;
    highAddress.LowPart = MAXULONG;

    PMDL pBufferMdl = m_pPortStream->AllocatePagesForMdl(highAddress, RequestedSize_);

    if (NULL == pBufferMdl)
    {
        return STATUS_UNSUCCESSFUL;
    }

    // From MSDN: 
    // "Since the Windows audio stack does not support a mechanism to express memory access 
    //  alignment requirements for buffers, audio drivers must select a caching type for mapped
    //  memory buffers that does not impose platform-specific alignment requirements. In other 
    //  words, the caching type used by the audio driver for mapped memory buffers, must not make 
    //  assumptions about the memory alignment requirements for any specific platform.
    //
    //  This method maps the physical memory pages in the MDL into kernel-mode virtual memory. 
    //  Typically, the miniport driver calls this method if it requires software access to the 
    //  scatter-gather list for an audio buffer. In this case, the storage for the scatter-gather 
    //  list must have been allocated by the IPortWaveRTStream::AllocatePagesForMdl or 
    //  IPortWaveRTStream::AllocateContiguousPagesForMdl method. 
    //
    //  A WaveRT miniport driver should not require software access to the audio buffer itself."
    //   
    BYTE* mappedBuffer =
        (BYTE*)m_pPortStream->MapAllocatedPages(pBufferMdl, MmCached);
    if (mappedBuffer == NULL)
    {
        m_pPortStream->FreePagesFromMdl(pBufferMdl);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(mappedBuffer, RequestedSize_);

    AttachDmaBuffer(mappedBuffer, RequestedSize_, 0, 0);

    *AudioBufferMdl_ = pBufferMdl;
    *ActualSize_ = RequestedSize_;
    *OffsetFromFirstPage_ = 0;
    *CacheType_ = MmCached;

    return STATUS_SUCCESS;
}

//=============================================================================
#pragma code_seg()
_IRQL_requires_max_(DISPATCH_LEVEL)
VOID CMiniportWaveRTStream::AttachDmaBuffer
(
    _In_ BYTE* Buffer,
    _In_ ULONG BufferSize,
    _In_ ULONG NotificationsPerBuffer,
    _In_ ULONG NotificationIntervalMs
)
{
    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    ASSERT(m_pDmaBuffer == NULL);
    m_pDmaBuffer = Buffer;
    m_ulDmaBufferSize = BufferSize;
    m_ulNotificationsPerBuffer = NotificationsPerBuffer;
    m_ulNotificationIntervalMs = NotificationIntervalMs;
    m_ullStreamGeneration++;
    RtlZeroMemory(m_RenderPacketCommits, sizeof(m_RenderPacketCommits));
    m_bRenderGapPending = FALSE;
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
}

//=============================================================================
#pragma code_seg()
_IRQL_requires_max_(DISPATCH_LEVEL)
_Ret_maybenull_
BYTE* CMiniportWaveRTStream::DetachDmaBuffer()
{
    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    BYTE* buffer = m_pDmaBuffer;
    m_pDmaBuffer = NULL;
    m_ulDmaBufferSize = 0;
    m_ulNotificationsPerBuffer = 0;
    m_ulNotificationIntervalMs = 0;
    m_ullStreamGeneration++;
    RtlZeroMemory(m_RenderPacketCommits, sizeof(m_RenderPacketCommits));
    m_bRenderGapPending = FALSE;
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
    return buffer;
}

//=============================================================================
#pragma code_seg()
NTSTATUS CMiniportWaveRTStream::GetPosition
(
    _Out_   KSAUDIO_POSITION    *Position_
)
{
    NTSTATUS ntStatus;

    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);

    if (m_KsState == KSSTATE_RUN)
    {
        //
        // Get the current time and update position.
        //
        LARGE_INTEGER ilQPC = KeQueryPerformanceCounter(NULL);
        UpdatePosition(ilQPC);
    }

    Position_->PlayOffset = m_ullPlayPosition;
    Position_->WriteOffset = m_ullWritePosition;

    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    ntStatus = STATUS_SUCCESS;
    
    return ntStatus;
}

//=============================================================================
// CMiniportWaveRTStream::GetReadPacket
//
//  Returns information about the next packet for the OS to read.
//
// Return value
//
//  Returns STATUS_DEVICE_NOT_READY if no new packets are available.
//
// IRQL - PASSIVE_LEVEL
//
// Remarks
//  Although called at passive level, this routine is non-paged code because
//  it is called in the streaming path where page faults should be avoided.
//
// ISSUE-2014/10/4 Will this work correctly across pause/play?
#pragma code_seg()
_IRQL_requires_max_(PASSIVE_LEVEL)
NTSTATUS CMiniportWaveRTStream::GetReadPacket
(
    _Out_ ULONG* PacketNumber,
    _Out_ DWORD* Flags,
    _Out_ ULONG64* PerformanceCounterValue,
    _Out_ BOOL* MoreData
)
{
    ULONG availablePacketNumber;
    ULONG droppedPackets;

    if (!m_bCapture ||
        PacketNumber == NULL ||
        Flags == NULL ||
        PerformanceCounterValue == NULL ||
        MoreData == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);

    // Validate and snapshot one coherent capture generation. STOP and buffer
    // replacement increment the generation under this same lock.
    if (m_ulNotificationsPerBuffer == 0)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return STATUS_NOT_SUPPORTED;
    }
    if (m_KsState < KSSTATE_PAUSE ||
        m_pDmaBuffer == NULL ||
        m_ulDmaBufferSize == 0)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return STATUS_INVALID_DEVICE_STATE;
    }

    LONGLONG packetCounter = m_llPacketCounter;
    ULONGLONG ullLinearPosition = m_ullLinearPosition;
    ULONGLONG hnsElapsedTimeCarryForward = m_hnsElapsedTimeCarryForward;
    ULONGLONG ullDmaTimeStamp = m_ullDmaTimeStamp;
    BOOLEAN dataDiscontinuity = m_bDataDiscontinuity;
    ULONG dmaBufferSize = m_ulDmaBufferSize;
    ULONG notificationsPerBuffer = m_ulNotificationsPerBuffer;
    ULONG dmaMovementRate = m_ulDmaMovementRate;
    ULONG lastOsReadPacket = m_ulLastOsReadPacket;
    ULONGLONG streamGeneration = m_ullStreamGeneration;
    LONGLONG qpcFrequencySigned =
        m_ullPerformanceCounterFrequency.QuadPart;

    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    if (packetCounter <= 0)
    {
        return STATUS_DEVICE_NOT_READY;
    }

    // The 0-based number of the last completed packet
    // FUTURE-2014/10/27 Update to allow different numbers of packets per WaveRT buffer
    availablePacketNumber = LODWORD(packetCounter - 1);  // Note this might be ULONG_MAX if called during the first packet

    // If no new packets are available...
    if (availablePacketNumber == lastOsReadPacket)
    {
        return STATUS_DEVICE_NOT_READY;
    }

    // If more than one packet has transferred since the last packet read by
    // the OS, then those were dropped. That is, a glitch occurred.
    droppedPackets = availablePacketNumber - lastOsReadPacket - 1;
    if (droppedPackets > 0)
    {
        // Trace a glitch
    }

    // Compute and return timestamp corresponding to the end of the available packet. In a real hardware
    // driver, the timestamp would be computed in a driver and hardware specific manner. In this sample
    // driver, it is extrapolated from the sample driver's internal simulated position correlation
    // [m_ullLinearPosition @ m_ullDmaTimeStamp] and the sample's internal 64-bit packet counter, subtracting
    // 1 from the packet counter to compute the time at the start of that last completed packet.
    if (notificationsPerBuffer == 0 ||
        dmaMovementRate == 0 ||
        qpcFrequencySigned <= 0)
    {
        return STATUS_INVALID_DEVICE_STATE;
    }

    ULONG packetSize =
        dmaBufferSize / notificationsPerBuffer;
    if (packetSize == 0)
    {
        return STATUS_INVALID_DEVICE_STATE;
    }

    ULONGLONG linearPositionOfAvailablePacket = 0;
    NTSTATUS arithmeticStatus = RtlUInt64Mult(
        static_cast<ULONGLONG>(packetCounter),
        packetSize,
        &linearPositionOfAvailablePacket);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }

    // Need to divide by (1000 * 10000 because m_ulDmaMovementRate is average bytes per sec
    ULONGLONG carryProduct = 0;
    arithmeticStatus = RtlUInt64Mult(
        hnsElapsedTimeCarryForward,
        dmaMovementRate,
        &carryProduct);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }
    ULONGLONG carryForwardBytes = carryProduct / 10000000ULL;

    ULONGLONG positionWithCarry = 0;
    arithmeticStatus = RtlUInt64Add(
        ullLinearPosition,
        carryForwardBytes,
        &positionWithCarry);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }
    ULONGLONG deltaLinearPosition =
        positionWithCarry >= linearPositionOfAvailablePacket
            ? positionWithCarry - linearPositionOfAvailablePacket
            : 0;

    ULONGLONG deltaProduct = 0;
    arithmeticStatus = RtlUInt64Mult(
        deltaLinearPosition,
        10000000ULL,
        &deltaProduct);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }
    ULONGLONG deltaTimeInHns =
        deltaProduct / dmaMovementRate;
    ULONGLONG timeOfAvailablePacketInHns =
        ullDmaTimeStamp >= deltaTimeInHns
            ? ullDmaTimeStamp - deltaTimeInHns
            : 0;

    ULONGLONG qpcFrequency =
        static_cast<ULONGLONG>(qpcFrequencySigned);
    ULONGLONG wholeSeconds =
        timeOfAvailablePacketInHns / 10000000ULL;
    ULONGLONG remainingHns =
        timeOfAvailablePacketInHns % 10000000ULL;
    ULONGLONG wholeQpc = 0;
    ULONGLONG fractionalProduct = 0;
    ULONGLONG timeOfAvailablePacketInQpc = 0;
    arithmeticStatus =
        RtlUInt64Mult(wholeSeconds, qpcFrequency, &wholeQpc);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }
    arithmeticStatus =
        RtlUInt64Mult(
            remainingHns,
            qpcFrequency,
            &fractionalProduct);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }
    arithmeticStatus =
        RtlUInt64Add(
            wholeQpc,
            fractionalProduct / 10000000ULL,
            &timeOfAvailablePacketInQpc);
    if (!NT_SUCCESS(arithmeticStatus))
    {
        return arithmeticStatus;
    }

    // Commit last-read and discontinuity state only if the stream is still the
    // exact generation and packet snapshot used for the result. Otherwise a
    // stale GetReadPacket completing after STOP could poison the next run.
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    if (m_ullStreamGeneration != streamGeneration ||
        m_KsState < KSSTATE_PAUSE ||
        m_ulDmaBufferSize != dmaBufferSize ||
        m_ulNotificationsPerBuffer != notificationsPerBuffer)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return STATUS_INVALID_DEVICE_STATE;
    }
    if (m_llPacketCounter != packetCounter ||
        m_ulLastOsReadPacket != lastOsReadPacket ||
        m_bDataDiscontinuity != dataDiscontinuity)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return STATUS_DEVICE_NOT_READY;
    }

    m_ulLastOsReadPacket = availablePacketNumber;
    if (dataDiscontinuity)
    {
        m_bDataDiscontinuity = FALSE;
    }
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    *PacketNumber = availablePacketNumber;
    *PerformanceCounterValue = timeOfAvailablePacketInQpc;
    *Flags =
        (dataDiscontinuity || droppedPackets != 0)
            ? KSSTREAM_HEADER_OPTIONSF_DATADISCONTINUITY
            : 0;

    // This sample does not internally buffer data so there is never more data
    // than revealed by the results from this routine.
    *MoreData = FALSE;

    return STATUS_SUCCESS;
}

#pragma code_seg()
_IRQL_requires_max_(PASSIVE_LEVEL)
NTSTATUS CMiniportWaveRTStream::SetWritePacket
(
    _In_ ULONG      PacketNumber,
    _In_ DWORD      Flags,
    _In_ ULONG      EosPacketLength
)
{
    UNREFERENCED_PARAMETER(EosPacketLength);
    NTSTATUS ntStatus = STATUS_SUCCESS;

    if (m_bCapture)
    {
        return STATUS_NOT_SUPPORTED;
    }

    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    do
    {
        // Notification mode is mandatory for render because only
        // SetWritePacket supplies an exact producer-commit boundary.
        if (m_ulNotificationsPerBuffer == 0)
        {
            ntStatus = STATUS_NOT_SUPPORTED;
            break;
        }
        if (m_ulNotificationsPerBuffer > MAX_RENDER_PACKET_SLOTS ||
            m_ulDmaBufferSize == 0 ||
            (m_ulDmaBufferSize % m_ulNotificationsPerBuffer) != 0)
        {
            ntStatus = STATUS_INVALID_DEVICE_STATE;
            break;
        }

        ULONG packetIndex =
            PacketNumber % m_ulNotificationsPerBuffer;

        // SetWritePacket is called after the OS has written the shared ring.
        // Clear any older ownership tag for this physical slot before
        // validating the new logical packet. Even a rejected late, overrun, or
        // malformed call may already have overwritten the bytes in that slot.
        m_RenderPacketCommits[packetIndex].Valid = FALSE;

        // End-of-stream is intentionally unsupported, and the DDI requires all
        // undefined flag bits to fail with STATUS_INVALID_PARAMETER.
        if (Flags != 0)
        {
            ntStatus = STATUS_INVALID_PARAMETER;
            break;
        }

        // This function should not be called once EoS has been set.
        if (m_bEoSReceived)
        {
            ntStatus = STATUS_INVALID_DEVICE_STATE;
            break;
        }

        // A 1-based completed-packet count identifies the packet currently
        // consumed. While RUN, the audio engine writes one packet ahead.
        ULONGLONG expectedLogicalPacket =
            static_cast<ULONGLONG>(m_llPacketCounter);
        if (m_KsState == KSSTATE_RUN)
        {
            expectedLogicalPacket++;
        }
        ULONG expectedPacket = LODWORD(expectedLogicalPacket);

        // Preserve the interface's modulo-ULONG late/overrun comparison.
        LONG deltaFromExpectedPacket = PacketNumber - expectedPacket;
        if (deltaFromExpectedPacket < 0)
        {
            ntStatus = STATUS_DATA_LATE_ERROR;
            break;
        }
        if (deltaFromExpectedPacket > 0)
        {
            ntStatus = STATUS_DATA_OVERRUN;
            break;
        }

        ULONG packetSize =
            m_ulDmaBufferSize / m_ulNotificationsPerBuffer;
        if (packetSize == 0)
        {
            ntStatus = STATUS_INVALID_DEVICE_STATE;
            break;
        }
        ULONG ulCurrentWritePosition = packetIndex * packetSize;

        ntStatus = SetCurrentWritePositionInternal(ulCurrentWritePosition);
        if (NT_SUCCESS(ntStatus))
        {
            // Publish the exact logical packet occupying this ring slot only
            // after the audio engine's writes are globally visible. A future
            // packet can never be mistaken for an older missing packet merely
            // because both map to the same circular buffer.
            KeMemoryBarrier();
            m_RenderPacketCommits[packetIndex].PacketNumber =
                expectedLogicalPacket;
            m_RenderPacketCommits[packetIndex].Valid = TRUE;
            m_ulLastOsWritePacket = PacketNumber;
        }
    } while (FALSE);
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    return ntStatus;
}

//=============================================================================
#pragma code_seg()
_IRQL_requires_max_(PASSIVE_LEVEL)
NTSTATUS CMiniportWaveRTStream::GetOutputStreamPresentationPosition
(
    _Out_ KSAUDIO_PRESENTATION_POSITION *pPresentationPosition
)
{
    ASSERT (pPresentationPosition);

    if (m_bCapture)
    {
        return STATUS_NOT_SUPPORTED;
    }
    
    // The call must be from event driven mode
    if(m_ulNotificationsPerBuffer == 0)
    {
        return STATUS_NOT_SUPPORTED;
    }
    
    return GetPresentationPosition(pPresentationPosition);
}

//=============================================================================
#pragma code_seg()
_IRQL_requires_max_(PASSIVE_LEVEL)
NTSTATUS CMiniportWaveRTStream::GetPacketCount
(
    _Out_ ULONG *pPacketCount
)
{
    ASSERT(pPacketCount);

    // The call must be from event driven mode
    if(m_ulNotificationsPerBuffer == 0)
    {
        return STATUS_NOT_SUPPORTED;
    }
    
    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);

    if (m_KsState == KSSTATE_RUN)
    {
        // Get the current time and update simulated position.
        LARGE_INTEGER ilQPC = KeQueryPerformanceCounter(NULL);
        UpdatePosition(ilQPC);
    }

    *pPacketCount = LODWORD(m_llPacketCounter);
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    return STATUS_SUCCESS;
}

//linear and presentation positions
#pragma code_seg()
NTSTATUS CMiniportWaveRTStream::GetPositions(
    _Out_opt_  ULONGLONG* _pullLinearBufferPosition,
    _Out_opt_  ULONGLONG* _pullPresentationPosition,
    _Out_opt_  LARGE_INTEGER* _pliQPCTime
)
{
    DPF_ENTER(("[CMiniportWaveRTStream::GetPositions]"));

    NTSTATUS        ntStatus;
    LARGE_INTEGER   ilQPC;
    KIRQL           oldIrql;

    // Update *_pullLinearBufferPosition with the the number of bytes fetched from waveRT ever since a stream got set into RUN
    // state.
    // Once the stream is set to STOP state, any further read on this call would return zero.

    //
    // Get the current time and update position.
    //
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    ilQPC = KeQueryPerformanceCounter(NULL);
    if (m_KsState == KSSTATE_RUN)
    {
        UpdatePosition(ilQPC);
    }
    if (_pullLinearBufferPosition)
    {
        *_pullLinearBufferPosition = m_ullLinearPosition;
    }
    if (_pullPresentationPosition)
    {
        *_pullPresentationPosition = m_ullPresentationPosition;
    }
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
    if (_pliQPCTime)
    {
        *_pliQPCTime = ilQPC;
    }

    ntStatus = STATUS_SUCCESS;

    return ntStatus;
}

NTSTATUS CMiniportWaveRTStream::GetPresentationPosition(_Out_  KSAUDIO_PRESENTATION_POSITION* _pPresentationPosition)
{
    ASSERT(_pPresentationPosition);
    LARGE_INTEGER timeStamp;

    DPF_ENTER(("[CMiniportWaveRTStream::GetPresentationPosition]"));

    ULONGLONG ullLinearPosition = { 0 };
    ULONGLONG ullPresentationPosition = { 0 };
    NTSTATUS status = STATUS_SUCCESS;

    status = GetPositions(&ullLinearPosition, &ullPresentationPosition, &timeStamp);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    _pPresentationPosition->u64PositionInBlocks = ullPresentationPosition * m_pWfExt->Format.nSamplesPerSec / m_pWfExt->Format.nAvgBytesPerSec;
    _pPresentationPosition->u64QPCPosition = (UINT64)timeStamp.QuadPart;

    return STATUS_SUCCESS;
}

#pragma code_seg()
NTSTATUS CMiniportWaveRTStream::SetCurrentWritePositionInternal(_In_  ULONG _ulCurrentWritePosition)
{
    DPF_ENTER(("[CMiniportWaveRTStream::SetCurrentWritePositionInternal]"));

    ASSERT(m_bEoSReceived == FALSE);

    if (m_bCapture)
    {
        return STATUS_NOT_SUPPORTED;
    }

    if (m_bEoSReceived)
    {
        return STATUS_INVALID_DEVICE_REQUEST;
    }

    if (_ulCurrentWritePosition > m_ulDmaBufferSize)
    {
        return STATUS_INVALID_DEVICE_REQUEST;
    }

    // PortCls can express the end of the circular buffer as BufferSize. Store
    // the equivalent zero offset so every internal ring position remains in
    // the canonical [0, BufferSize) range.
    if (_ulCurrentWritePosition == m_ulDmaBufferSize)
    {
        _ulCurrentWritePosition = 0;
    }

    m_ulCurrentWritePosition = _ulCurrentWritePosition;

    return STATUS_SUCCESS;
}

//=============================================================================
#pragma code_seg()
NTSTATUS CMiniportWaveRTStream::SetState
(
    _In_    KSSTATE State_
)
{
    NTSTATUS        ntStatus        = STATUS_SUCCESS;
    KIRQL oldIrql;
    BOOLEAN statePublished = FALSE;

    if (State_ != KSSTATE_STOP &&
        State_ != KSSTATE_ACQUIRE &&
        State_ != KSSTATE_PAUSE &&
        State_ != KSSTATE_RUN)
    {
        return STATUS_INVALID_PARAMETER;
    }

    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
    KSSTATE previousState = m_KsState;

    // Publish a non-RUN state while holding the same lock used by render-data
    // producers. This closes the capture STOP race in which counters could be
    // reset while CopyRenderData still observed RUN and repopulated the ring.
    // Take one final render-clock sample first so the paused position remains
    // monotonic up to the transition boundary.
    if (previousState == KSSTATE_RUN && State_ != KSSTATE_RUN)
    {
        LARGE_INTEGER transitionQpc = KeQueryPerformanceCounter(NULL);
        UpdatePosition(transitionQpc);
        m_KsState = State_;
        m_llLastNotifiedPacketCounter = m_llPacketCounter;
        statePublished = TRUE;
    }
    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

    // ExTimer remains armed across a direct RUN -> STOP transition unless it
    // is explicitly cancelled. The state is already non-RUN before joining, so
    // neither the timer nor a render producer can mutate reset capture state.
    if (previousState == KSSTATE_RUN &&
        State_ != KSSTATE_RUN &&
        m_pNotificationTimer != NULL)
    {
        ExCancelTimer(m_pNotificationTimer, NULL);
        KeFlushQueuedDpcs();
    }

    // Spew an event for a pin state change request from portcls
    //Event type: eMINIPORT_PIN_STATE
    switch (State_)
    {
        case KSSTATE_STOP:
            if (previousState == KSSTATE_ACQUIRE)
            {
                // Acquire stream resources
            }
            KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
            // Publish STOP before clearing producer-visible ring state.
            m_KsState = KSSTATE_STOP;
            statePublished = TRUE;

            // Reset DMA
            m_ullStreamGeneration++;
            m_llPacketCounter = 0;
            m_llLastNotifiedPacketCounter = 0;
            m_ullPlayPosition = 0;
            m_ullWritePosition = 0;
            m_ullLinearPosition = 0;
            m_ullPresentationPosition = 0;
            
            // Reset OS read/write positions
            m_ulLastOsReadPacket = ULONG_MAX;
            m_ulCurrentWritePosition = 0;
            m_ulLastOsWritePacket = ULONG_MAX;
            RtlZeroMemory(
                m_RenderPacketCommits,
                sizeof(m_RenderPacketCommits));
            m_bRenderGapPending = FALSE;
            m_bEoSReceived = FALSE;
            m_bLastBufferRendered = FALSE;
            m_bDataDiscontinuity = FALSE;
            m_hnsElapsedTimeCarryForward = 0;
            m_hnsDPCTimeCarryForward = 0;
            m_byteDisplacementCarryForward = 0;

            KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

            break;

        case KSSTATE_ACQUIRE:
            if (previousState == KSSTATE_STOP)
            {
                // Acquire stream resources
            }
            break;
            
        case KSSTATE_PAUSE:

            if (previousState > KSSTATE_PAUSE)
            {
                //
                // Run -> Pause
                //

                // Pause DMA
                if (m_ulNotificationIntervalMs > 0)
                {
                    // If pin is transitioning from RUN, save the time since last buffer completion event was sent 
                    // so if the pin goes to RUN state again we can send the buffer completion event at correct time.
                    if (m_ullLastDPCTimeStamp > 0)
                    {
                        LARGE_INTEGER qpc;
                        LARGE_INTEGER qpcFrequency;
                        LONGLONG  hnsCurrentTime;

                        qpc = KeQueryPerformanceCounter(&qpcFrequency);

                        // Convert ticks to 100ns units.
                        hnsCurrentTime = KSCONVERT_PERFORMANCE_TIME(m_ullPerformanceCounterFrequency.QuadPart, qpc);
                        m_hnsDPCTimeCarryForward = hnsCurrentTime - m_ullLastDPCTimeStamp + m_hnsDPCTimeCarryForward;
                    }
                }
            }
            // This call updates the linear buffer and presentation positions.
            GetPositions(NULL, NULL, NULL);
            break;

        case KSSTATE_RUN:
        {
            if (m_ulDmaBufferSize == 0 ||
                m_ulDmaMovementRate == 0 ||
                m_pNotificationTimer == NULL)
            {
                return STATUS_INVALID_DEVICE_STATE;
            }

            // Start DMA
            LARGE_INTEGER ullPerfCounterTemp;
            ullPerfCounterTemp = KeQueryPerformanceCounter(&m_ullPerformanceCounterFrequency);
            LONGLONG startTime =
                KSCONVERT_PERFORMANCE_TIME(
                    m_ullPerformanceCounterFrequency.QuadPart,
                    ullPerfCounterTemp);
            if (startTime < 0)
            {
                return STATUS_INVALID_DEVICE_STATE;
            }

            KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
            m_ullLastDPCTimeStamp =
                m_ullDmaTimeStamp =
                    static_cast<ULONGLONG>(startTime);
            m_llLastNotifiedPacketCounter = m_llPacketCounter;
            m_KsState = KSSTATE_RUN;
            statePublished = TRUE;
            KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);

            if (m_ulNotificationIntervalMs > 0 && !m_bCapture)
            {
                // Set timer for 1 ms. This will cause DPC to run every 1 ms but driver will send out 
                // notification events only after notification interval. This timer is used by Simple Audio Sample to 
                // emulate hardware and send out notification event. Real hardware should not use this
                // timer to fire notification event as it will drain power if the timer is running at 1 msec.
                ExSetTimer
                (
                    m_pNotificationTimer,
                    (-1) * HNSTIME_PER_MILLISECOND,
                    HNSTIME_PER_MILLISECOND, // 1 ms 
                    NULL
                 );

            }

            break;
        }

        default:
            return STATUS_INVALID_PARAMETER;
    }

    if (!statePublished)
    {
        KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);
        m_KsState = State_;
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
    }

    return ntStatus;
}

//=============================================================================
#pragma code_seg("PAGE")
NTSTATUS CMiniportWaveRTStream::SetFormat
(
    _In_    KSDATAFORMAT    *DataFormat_
)
{
    UNREFERENCED_PARAMETER(DataFormat_);

    PAGED_CODE();

    return STATUS_NOT_SUPPORTED;
}

#pragma code_seg()

//=============================================================================
#pragma code_seg()
_IRQL_requires_max_(DISPATCH_LEVEL)
VOID CMiniportWaveRTStream::CopyRenderData
(
    _In_reads_bytes_(SourceBufferSize) const BYTE* SourceBuffer,
    _In_ ULONG                                    SourceBufferSize,
    _In_ ULONG                                    SourceStart,
    _In_ ULONGLONG                                ByteCount,
    _In_ LARGE_INTEGER                            Qpc,
    _In_ BOOLEAN                                  DataDiscontinuity
)
{
    if (SourceBuffer == NULL ||
        SourceBufferSize == 0 ||
        SourceStart >= SourceBufferSize ||
        (ByteCount == 0 && !DataDiscontinuity))
    {
        return;
    }

    KIRQL oldIrql;
    KeAcquireSpinLock(&m_PositionSpinLock, &oldIrql);

    if (!m_bCapture ||
        m_KsState != KSSTATE_RUN ||
        m_pDmaBuffer == NULL ||
        m_ulDmaBufferSize == 0 ||
        m_pWfExt == NULL ||
        m_pWfExt->Format.nBlockAlign == 0)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return;
    }

    if (DataDiscontinuity)
    {
        m_bDataDiscontinuity = TRUE;
    }

    if (ByteCount == 0)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return;
    }

    const ULONG blockAlign = m_pWfExt->Format.nBlockAlign;
    ByteCount -= ByteCount % blockAlign;
    if (ByteCount == 0)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return;
    }

    // A delayed DPC can span more than one ring. Only the newest bytes still
    // resident in both rings are recoverable. Compact the recoverable suffix
    // into the capture ring and advance only by bytes actually copied. Advancing
    // by the missing interval could publish a packet containing stale or
    // initial-zero bytes when the render ring is smaller than a capture packet.
    ULONG recoverableLimit =
        MIN(SourceBufferSize, m_ulDmaBufferSize);
    recoverableLimit -= recoverableLimit % blockAlign;
    ULONG bytesToCopy =
        ByteCount > recoverableLimit
            ? recoverableLimit
            : static_cast<ULONG>(ByteCount);
    if (bytesToCopy == 0)
    {
        KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
        return;
    }

    ULONGLONG skippedBytes = ByteCount - bytesToCopy;
    ULONG sourceOffset = static_cast<ULONG>(
        (static_cast<ULONGLONG>(SourceStart) +
            (skippedBytes % SourceBufferSize)) %
        SourceBufferSize);
    ULONG destinationStart =
        static_cast<ULONG>(m_ullWritePosition);
    ULONG destinationOffset = destinationStart;

    ULONG remaining = bytesToCopy;
    while (remaining != 0)
    {
        ULONG sourceContiguous = SourceBufferSize - sourceOffset;
        ULONG destinationContiguous =
            m_ulDmaBufferSize - destinationOffset;
        ULONG chunk = MIN(
            remaining,
            MIN(sourceContiguous, destinationContiguous));

        RtlCopyMemory(
            m_pDmaBuffer + destinationOffset,
            SourceBuffer + sourceOffset,
            chunk);

        remaining -= chunk;
        sourceOffset = (sourceOffset + chunk) % SourceBufferSize;
        destinationOffset =
            (destinationOffset + chunk) % m_ulDmaBufferSize;
    }
    KeMemoryBarrier();

    if (skippedBytes != 0)
    {
        m_bDataDiscontinuity = TRUE;
    }

    ULONGLONG oldLinearPosition = m_ullLinearPosition;
    ULONGLONG newLinearPosition =
        bytesToCopy > MAXULONGLONG - oldLinearPosition
            ? MAXULONGLONG
            : oldLinearPosition + bytesToCopy;

    ULONGLONG advanceModulo = bytesToCopy % m_ulDmaBufferSize;
    ULONG newPosition = static_cast<ULONG>(
        (static_cast<ULONGLONG>(destinationStart) +
            advanceModulo) %
        m_ulDmaBufferSize);
    m_ullPlayPosition = m_ullWritePosition = newPosition;
    m_ullLinearPosition = newLinearPosition;
    m_ullPresentationPosition =
        bytesToCopy > MAXULONGLONG - m_ullPresentationPosition
            ? MAXULONGLONG
            : m_ullPresentationPosition + bytesToCopy;

    if (m_ullPerformanceCounterFrequency.QuadPart > 0)
    {
        LONGLONG hns =
            KSCONVERT_PERFORMANCE_TIME(
                m_ullPerformanceCounterFrequency.QuadPart,
                Qpc);
        if (hns >= 0)
        {
            m_ullDmaTimeStamp = static_cast<ULONGLONG>(hns);
        }
    }
    m_hnsElapsedTimeCarryForward = 0;

    ULONGLONG completedPackets = 0;
    if (m_ulNotificationsPerBuffer != 0)
    {
        ULONG packetSize =
            m_ulDmaBufferSize / m_ulNotificationsPerBuffer;
        if (packetSize != 0)
        {
            completedPackets =
                (newLinearPosition / packetSize) -
                (oldLinearPosition / packetSize);

            if (completedPackets >
                static_cast<ULONGLONG>(
                    MAXLONGLONG - m_llPacketCounter))
            {
                m_llPacketCounter = MAXLONGLONG;
            }
            else
            {
                m_llPacketCounter +=
                    static_cast<LONGLONG>(completedPackets);
            }
        }
    }

    if (completedPackets != 0 &&
        !IsListEmpty(&m_NotificationList))
    {
        PLIST_ENTRY current = m_NotificationList.Flink;
        while (current != &m_NotificationList)
        {
            NotificationListEntry* notification =
                CONTAINING_RECORD(
                    current,
                    NotificationListEntry,
                    ListEntry);
            KeSetEvent(notification->NotificationEvent, 0, FALSE);
            current = current->Flink;
        }
    }

    KeReleaseSpinLock(&m_PositionSpinLock, oldIrql);
}

//=============================================================================
#pragma code_seg()
VOID CMiniportWaveRTStream::UpdatePosition
(
    _In_ LARGE_INTEGER ilQPC
)
{
    // Loopback capture progress is producer-driven by CopyRenderData. Advancing
    // it from the wall clock would advertise fabricated zero-filled packets
    // whenever no render stream is supplying actual mixed PCM.
    if (m_bCapture)
    {
        return;
    }

    if (m_ulDmaBufferSize == 0 ||
        m_ulDmaMovementRate == 0 ||
        m_ullPerformanceCounterFrequency.QuadPart == 0)
    {
        return;
    }

    // Convert ticks to 100ns units.
    LONGLONG  hnsCurrentTime = KSCONVERT_PERFORMANCE_TIME(m_ullPerformanceCounterFrequency.QuadPart, ilQPC);
    
    // Calculate the time elapsed since the last call to GetPosition() or since the
    // DMA engine started.  Note that the division by 10000 to convert to milliseconds
    // may cause us to lose some of the time, so we will carry the remainder forward 
    // to the next GetPosition() call.
    //
    if (hnsCurrentTime < 0 ||
        static_cast<ULONGLONG>(hnsCurrentTime) < m_ullDmaTimeStamp)
    {
        // QPC should be monotonic. Fail closed if a platform anomaly or stale
        // state would otherwise turn a negative delta into a huge unsigned
        // displacement.
        m_ullDmaTimeStamp =
            hnsCurrentTime < 0 ? 0 : static_cast<ULONGLONG>(hnsCurrentTime);
        m_hnsElapsedTimeCarryForward = 0;
        return;
    }

    ULONGLONG elapsedHns =
        static_cast<ULONGLONG>(hnsCurrentTime) - m_ullDmaTimeStamp +
        static_cast<ULONGLONG>(m_hnsElapsedTimeCarryForward);
    ULONGLONG TimeElapsedInMS = elapsedHns / 10000ULL;
    
    // Carry forward the remainder of this division so we don't fall behind with our position too much.
    //
    m_hnsElapsedTimeCarryForward =
        static_cast<LONGLONG>(elapsedHns % 10000ULL);
    
    // Calculate how many bytes in the DMA buffer would have been processed in the elapsed
    // time.  Note that the division by 1000 to convert to milliseconds may cause us to 
    // lose some bytes, so we will carry the remainder forward to the next GetPosition() call.
    //
    // need to divide by 1000 because m_ulDmaMovementRate is average bytes per sec.

    ULONGLONG byteNumerator = 0;
    if (TimeElapsedInMS >
        (MAXULONGLONG - m_byteDisplacementCarryForward) / m_ulDmaMovementRate)
    {
        byteNumerator = MAXULONGLONG;
    }
    else
    {
        byteNumerator =
            static_cast<ULONGLONG>(m_ulDmaMovementRate) * TimeElapsedInMS +
            m_byteDisplacementCarryForward;
    }
    ULONGLONG ByteDisplacement = byteNumerator / 1000ULL;
    m_byteDisplacementCarryForward =
        static_cast<ULONG>(byteNumerator % 1000ULL);

    ULONG blockAlign =
        m_pWfExt == NULL ? 0 : m_pWfExt->Format.nBlockAlign;
    if (blockAlign == 0)
    {
        return;
    }
    ByteDisplacement -= ByteDisplacement % blockAlign;

    ULONG currentPosition = static_cast<ULONG>(m_ullWritePosition);
    ULONGLONG oldLinearPosition = m_ullLinearPosition;
    if (m_bEoSReceived)
    {
        ULONGLONG remaining = 0;
        if (m_ulCurrentWritePosition >= currentPosition)
        {
            remaining = m_ulCurrentWritePosition - currentPosition;
        }
        else
        {
            remaining =
                static_cast<ULONGLONG>(m_ulDmaBufferSize - currentPosition) +
                m_ulCurrentWritePosition;
        }

        if (ByteDisplacement > remaining)
        {
            ByteDisplacement = remaining;
        }
    }

    BOOLEAN validRenderPacketGeometry =
        m_ulNotificationsPerBuffer != 0 &&
        m_ulNotificationsPerBuffer <= MAX_RENDER_PACKET_SLOTS &&
        (m_ulDmaBufferSize % m_ulNotificationsPerBuffer) == 0;
    ULONG renderPacketSize =
        validRenderPacketGeometry
            ? m_ulDmaBufferSize / m_ulNotificationsPerBuffer
            : 0;
    if (renderPacketSize == 0 ||
        (renderPacketSize % blockAlign) != 0)
    {
        validRenderPacketGeometry = FALSE;
    }

    BOOLEAN linearPositionOverflow =
        ByteDisplacement > MAXULONGLONG - oldLinearPosition;
    ULONGLONG newLinearPosition =
        linearPositionOverflow
            ? MAXULONGLONG
            : oldLinearPosition + ByteDisplacement;

    if (ByteDisplacement != 0)
    {
        if (!validRenderPacketGeometry || linearPositionOverflow)
        {
            // Without exact packet geometry (or after linear-position
            // saturation), no ring byte can be tied safely to a producer
            // commit. Fail closed and carry the gap to the next valid copy.
            RtlZeroMemory(
                m_RenderPacketCommits,
                sizeof(m_RenderPacketCommits));
            m_bRenderGapPending = TRUE;
        }
        else
        {
            // A delayed DPC can span an arbitrarily large conceptual range,
            // but only one circular buffer can still be resident. Walk that
            // bounded suffix (at most two packet slots plus one partial span)
            // and account for the skipped prefix as a discontinuity.
            ULONGLONG rangeCursor = oldLinearPosition;
            ULONGLONG rangeRemaining = ByteDisplacement;
            if (rangeRemaining > m_ulDmaBufferSize)
            {
                ULONGLONG skippedBytes =
                    rangeRemaining - m_ulDmaBufferSize;
                rangeCursor += skippedBytes;
                rangeRemaining = m_ulDmaBufferSize;
                m_bRenderGapPending = TRUE;
            }

            while (rangeRemaining != 0)
            {
                ULONGLONG logicalPacket =
                    rangeCursor / renderPacketSize;
                ULONG offsetInPacket = static_cast<ULONG>(
                    rangeCursor % renderPacketSize);
                ULONG span = static_cast<ULONG>(
                    MIN(
                        rangeRemaining,
                        static_cast<ULONGLONG>(
                            renderPacketSize - offsetInPacket)));
                ULONG packetIndex = static_cast<ULONG>(
                    logicalPacket % m_ulNotificationsPerBuffer);
                RenderPacketCommit* commit =
                    &m_RenderPacketCommits[packetIndex];

                // SetWritePacket publishes this tag only after the OS writes
                // are visible. The spin lock serializes tag replacement and
                // invalidation with this consumer.
                KeMemoryBarrier();
                if (commit->Valid &&
                    commit->PacketNumber == logicalPacket)
                {
                    ULONG sourceStart =
                        packetIndex * renderPacketSize +
                        offsetInPacket;
                    m_pMiniport->CopyRenderDataToLoopback(
                        this,
                        sourceStart,
                        span,
                        ilQPC,
                        m_bRenderGapPending);
                    m_bRenderGapPending = FALSE;

                    if (offsetInPacket + span == renderPacketSize)
                    {
                        commit->Valid = FALSE;
                    }
                }
                else
                {
                    // Do not substitute whatever stale or future packet
                    // happens to occupy the same physical ring slot.
                    m_bRenderGapPending = TRUE;
                }

                rangeCursor += span;
                rangeRemaining -= span;
            }

            // Remove stale tags wholly behind the new hardware cursor. A tag
            // for the partially consumed or next packet remains valid.
            ULONGLONG firstUnconsumedPacket =
                newLinearPosition / renderPacketSize;
            for (ULONG slot = 0;
                 slot < m_ulNotificationsPerBuffer;
                 ++slot)
            {
                if (m_RenderPacketCommits[slot].Valid &&
                    m_RenderPacketCommits[slot].PacketNumber <
                        firstUnconsumedPacket)
                {
                    m_RenderPacketCommits[slot].Valid = FALSE;
                }
            }
        }
    }

    ULONGLONG displacementModulo =
        ByteDisplacement % m_ulDmaBufferSize;
    ULONG newPosition = static_cast<ULONG>(
        (static_cast<ULONGLONG>(currentPosition) +
            displacementModulo) %
        m_ulDmaBufferSize);

    if (m_bEoSReceived &&
        !m_bLastBufferRendered &&
        newPosition == m_ulCurrentWritePosition)
    {
        m_bLastBufferRendered = TRUE;
    }

    m_ullPlayPosition = m_ullWritePosition = newPosition;
    
    // m_ullDmaTimeStamp is updated in both GetPostion and GetLinearPosition calls
    // so m_ullLinearPosition needs to be updated accordingly here
    //
    m_ullLinearPosition = newLinearPosition;

    // GetPacketCount is a 1-based count of whole packets transferred at the
    // nominal hardware rate, including underrun intervals. Derive it from
    // actual linear packet-boundary crossings rather than timer callbacks.
    if (validRenderPacketGeometry)
    {
        ULONGLONG completedPackets =
            (newLinearPosition / renderPacketSize) -
            (oldLinearPosition / renderPacketSize);
        if (completedPackets >
            static_cast<ULONGLONG>(
                MAXLONGLONG - m_llPacketCounter))
        {
            m_llPacketCounter = MAXLONGLONG;
        }
        else
        {
            m_llPacketCounter +=
                static_cast<LONGLONG>(completedPackets);
        }
    }

    if (ByteDisplacement > MAXULONGLONG - m_ullPresentationPosition)
    {
        m_ullPresentationPosition = MAXULONGLONG;
    }
    else
    {
        m_ullPresentationPosition += ByteDisplacement;
    }
    
    // Update the DMA time stamp for the next call to GetPosition()
    //
    m_ullDmaTimeStamp = hnsCurrentTime;
}

//=============================================================================
#pragma code_seg()
STDMETHODIMP_(NTSTATUS) 
CMiniportWaveRTStream::SetContentId
(
    _In_  ULONG                   contentId,
    _In_  PCDRMRIGHTS             drmRights
)
/*++

Routine Description:

  Sets DRM content Id for this stream. Also updates the Mixed content Id.

Arguments:

  contentId - new content id

  drmRights - rights for this stream.

Return Value:

  NT status code.

--*/
{
    DPF_ENTER(("[CMiniportWaveRT::SetContentId]"));

    if (m_pMiniport == NULL || drmRights == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }

    KIRQL oldIrql;
    KeAcquireSpinLock(&m_pMiniport->m_StreamLock, &oldIrql);
    ULONG ulOldContentId = m_ulContentId;
    m_ulContentId = contentId;

    // Close the copy window before the slower DRM aggregation call. The
    // network transport is a digital output, so either restriction must gate
    // loopback immediately.
    if (drmRights->CopyProtect)
    {
        m_pMiniport->m_MixDrmRights.CopyProtect = TRUE;
    }
    if (drmRights->DigitalOutputDisable)
    {
        m_pMiniport->m_MixDrmRights.DigitalOutputDisable = TRUE;
    }
    KeReleaseSpinLock(&m_pMiniport->m_StreamLock, oldIrql);

    //
    // Miniport should create a mixed DrmRights.
    //
    NTSTATUS ntStatus = m_pMiniport->UpdateDrmRights();

    //
    // Restore the prior content ID on failure and fail closed. A later
    // successful rights update or final stream close clears the conservative
    // gate.
    //
    if (!NT_SUCCESS(ntStatus))
    {
        KeAcquireSpinLock(&m_pMiniport->m_StreamLock, &oldIrql);
        m_ulContentId = ulOldContentId;
        m_pMiniport->m_MixDrmRights.CopyProtect = TRUE;
        m_pMiniport->m_MixDrmRights.DigitalOutputDisable = TRUE;
        KeReleaseSpinLock(&m_pMiniport->m_StreamLock, oldIrql);
    }

    //
    // From MSDN:
    //
    // This sample doesn't forward protected content, but if your driver uses 
    // lower layer drivers or a different stack to properly work, please see the 
    // following info from MSDN:
    //
    // "Before allowing protected content to flow through a data path, the system
    // verifies that the data path is secure. To do so, the system authenticates
    // each module in the data path beginning at the upstream end of the data path
    // and moving downstream. As each module is authenticated, that module gives
    // the system information about the next module in the data path so that it
    // can also be authenticated. To be successfully authenticated, a module's 
    // binary file must be signed as DRM-compliant.
    //
    // Two adjacent modules in the data path can communicate with each other in 
    // one of several ways. If the upstream module calls the downstream module 
    // through IoCallDriver, the downstream module is part of a WDM driver. In 
    // this case, the upstream module calls the DrmForwardContentToDeviceObject
    // function to provide the system with the device object representing the 
    // downstream module. (If the two modules communicate through the downstream
    // module's COM interface or content handlers, the upstream module calls 
    // DrmForwardContentToInterface or DrmAddContentHandlers instead.)
    //
    // DrmForwardContentToDeviceObject performs the same function as 
    // PcForwardContentToDeviceObject and IDrmPort2::ForwardContentToDeviceObject." 
    //
    // Other supported DRM DDIs for down-level module validation are: 
    // DrmForwardContentToInterfaces and DrmAddContentHandlers.
    //
    // For more information, see MSDN's DRM Functions and Interfaces.
    //

    return ntStatus;
} // SetContentId

//=============================================================================
#pragma code_seg()
void
TimerNotifyRT
(
    _In_      PEX_TIMER    Timer,
    _In_opt_  PVOID        DeferredContext
)
{
    LARGE_INTEGER qpc;
    LARGE_INTEGER qpcFrequency;
    BOOL bufferCompleted = FALSE;
    LONGLONG hnsCurrentTime = 0;
    ULONGLONG elapsedHns = 0;
    ULONGLONG TimeElapsedInMS = 0;
    ULONGLONG intervalHns = 0;

    UNREFERENCED_PARAMETER(Timer);

    _IRQL_limited_to_(DISPATCH_LEVEL);

    CMiniportWaveRTStream* _this = (CMiniportWaveRTStream*)DeferredContext;
    
    if (NULL == _this)
    {
        return;
    }

    KIRQL oldIrql;
    KeAcquireSpinLock(&_this->m_PositionSpinLock, &oldIrql);

    if (_this->m_KsState != KSSTATE_RUN ||
        _this->m_ulDmaBufferSize == 0 ||
        _this->m_ulDmaMovementRate == 0 ||
        _this->m_ulNotificationIntervalMs == 0)
    {
        goto End;
    }

    qpc = KeQueryPerformanceCounter(&qpcFrequency);

    // Convert ticks to 100ns units.
    hnsCurrentTime = KSCONVERT_PERFORMANCE_TIME(_this->m_ullPerformanceCounterFrequency.QuadPart, qpc);

    // Calculate the time elapsed since the last we ran DPC that matched Notification interval. Note that the division by 10000 
    // to convert to milliseconds may cause us to lose some of the time, so we will carry the remainder forward.

    if (hnsCurrentTime < 0 ||
        static_cast<ULONGLONG>(hnsCurrentTime) <
            _this->m_ullLastDPCTimeStamp)
    {
        _this->m_ullLastDPCTimeStamp =
            hnsCurrentTime < 0 ? 0 : static_cast<ULONGLONG>(hnsCurrentTime);
        _this->m_hnsDPCTimeCarryForward = 0;
        goto End;
    }
    elapsedHns =
        static_cast<ULONGLONG>(hnsCurrentTime) -
            _this->m_ullLastDPCTimeStamp +
        static_cast<ULONGLONG>(_this->m_hnsDPCTimeCarryForward);
    TimeElapsedInMS = elapsedHns / 10000ULL;

    if (TimeElapsedInMS >= _this->m_ulNotificationIntervalMs)
    {
        // Carry forward the time greater than notification interval to adjust time to signal next buffer completion event accordingly.
        intervalHns =
            static_cast<ULONGLONG>(_this->m_ulNotificationIntervalMs) * 10000ULL;
        _this->m_hnsDPCTimeCarryForward =
            static_cast<LONGLONG>(elapsedHns % intervalHns);
        // Save the last time DPC ran at notification interval
        _this->m_ullLastDPCTimeStamp = hnsCurrentTime;
        bufferCompleted = TRUE;
    }

    if (!bufferCompleted && !_this->m_bEoSReceived)
    {
        goto End;
    }

    _this->UpdatePosition(qpc);

    // UpdatePosition derives the packet count from real linear packet
    // boundaries. A timer interval by itself is not proof that a whole packet
    // completed (buffer durations can round to milliseconds).
    bufferCompleted = FALSE;
    if (_this->m_llPacketCounter >
        _this->m_llLastNotifiedPacketCounter)
    {
        _this->m_llLastNotifiedPacketCounter =
            _this->m_llPacketCounter;
        bufferCompleted = TRUE;
    }

    if (!bufferCompleted && !_this->m_bLastBufferRendered)
    {
        goto End;
    }

    // Send buffer completion event if either of the following is true
    // 1. Driver consumed a complete buffer for this stream
    // 2. Driver consumed a partial buffer containing EoS for this stream

    if (!IsListEmpty(&_this->m_NotificationList) && 
        (bufferCompleted || _this->m_bLastBufferRendered))
    {
        PLIST_ENTRY leCurrent = _this->m_NotificationList.Flink;
        while (leCurrent != &_this->m_NotificationList)
        {
            NotificationListEntry* nleCurrent = CONTAINING_RECORD( leCurrent, NotificationListEntry, ListEntry);
            KeSetEvent(nleCurrent->NotificationEvent, 0, 0);

            leCurrent = leCurrent->Flink;
        }
    }

    if (_this->m_bLastBufferRendered)
    {
        ExCancelTimer(_this->m_pNotificationTimer, NULL);
    }

End:
    KeReleaseSpinLock(&_this->m_PositionSpinLock, oldIrql);
    return;
}
//=============================================================================
