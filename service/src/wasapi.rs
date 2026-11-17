//! Event-driven shared-mode WASAPI loopback capture.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use thiserror::Error;
use uuid::Uuid;
use windows::Win32::Devices::FunctionDiscovery::{
    PKEY_Device_ContainerId, PKEY_Device_FriendlyName,
};
use windows::Win32::Foundation::{
    CloseHandle, HANDLE, PROPERTYKEY, WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows::Win32::Media::Audio::{
    AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY, AUDCLNT_BUFFERFLAGS_SILENT,
    AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_EVENTCALLBACK, AUDCLNT_STREAMFLAGS_LOOPBACK, DEVICE_STATE_ACTIVE,
    IAudioCaptureClient, IAudioClient2, IAudioRenderClient, IMMDevice, IMMDeviceEnumerator,
    MMDeviceEnumerator, WAVEFORMATEX, WAVEFORMATEXTENSIBLE, eRender,
};
use windows::Win32::System::Com::{
    CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree,
    CoUninitialize, STGM_READ,
};
use windows::Win32::System::Threading::{
    CreateEventW, INFINITE, SetEvent, WaitForMultipleObjects, WaitForSingleObject,
};
use windows::Win32::System::Variant::{VT_CLSID, VT_EMPTY};
use windows::core::{BSTR, GUID, PCWSTR};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const INVALID_RECEIVER_ID_PROPERTY: &str = "<invalid>";
const WAVE_FORMAT_PCM: u16 = 1;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xfffe;
const PCM_SUBFORMAT: u128 = 0x00000001_0000_0010_8000_00aa00389b71;
const IEEE_FLOAT_SUBFORMAT: u128 = 0x00000003_0000_0010_8000_00aa00389b71;
const RECEIVER_ID_PROPERTY: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0x54b65a8e_7cd3_4f7b_953b_59a21c2e5cdd),
    pid: 2,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaptureSampleKind {
    SignedPcm16,
    Float32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CaptureFormat {
    pub format_tag: u16,
    pub channels: u16,
    pub sample_rate: u32,
    pub bits_per_sample: u16,
    pub block_align: u16,
    pub sample_kind: CaptureSampleKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenderEndpoint {
    pub endpoint_id: String,
    pub friendly_name: String,
    pub container_id: Option<Uuid>,
    pub receiver_id: Option<String>,
}

#[derive(Debug, Error, Clone, Eq, PartialEq)]
pub enum CaptureError {
    #[error("WASAPI {operation} failed: {detail}")]
    Windows {
        operation: &'static str,
        detail: String,
    },
    #[error("WASAPI mix format is invalid: {0}")]
    InvalidFormat(String),
    #[error("WASAPI capture startup timed out after {0:?}")]
    StartupTimedOut(Duration),
    #[error("WASAPI capture thread terminated before reporting startup")]
    StartupChannelClosed,
    #[error("WASAPI capture thread panicked")]
    ThreadPanicked,
    #[error("WASAPI render test parameters are invalid: {0}")]
    InvalidRenderTest(String),
    #[error("no active render endpoint has container ID {0}")]
    EndpointNotFound(Uuid),
    #[error("WASAPI capture queue is closed: {0}")]
    QueueClosed(String),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PacketMetadata {
    pub frames: u32,
    pub flags: u32,
    pub device_position: u64,
    pub qpc_position: u64,
    pub forced_discontinuity: bool,
}

impl PacketMetadata {
    /// Whether WASAPI reported a usable QPC position for this packet.
    #[must_use]
    pub fn qpc_position_is_reliable(self) -> bool {
        let timestamp_error =
            u32::try_from(AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR.0).unwrap_or_default();
        self.qpc_position != 0 && self.flags & timestamp_error == 0
    }
}

fn capture_packet_metadata(
    frames: u32,
    flags: u32,
    device_position: u64,
    qpc_position: u64,
) -> PacketMetadata {
    let data_discontinuity =
        u32::try_from(AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0).unwrap_or_default();
    PacketMetadata {
        frames,
        flags,
        device_position,
        qpc_position,
        forced_discontinuity: flags & data_discontinuity != 0,
    }
}

#[derive(Debug)]
struct AudioSlot {
    bytes: Vec<u8>,
    length: usize,
    metadata: PacketMetadata,
}

impl AudioSlot {
    fn new(max_bytes: usize) -> Self {
        Self {
            bytes: vec![0; max_bytes],
            length: 0,
            metadata: PacketMetadata::default(),
        }
    }
}

#[derive(Debug)]
struct QueueState {
    free: VecDeque<AudioSlot>,
    ready: VecDeque<AudioSlot>,
    closed: Option<String>,
}

impl QueueState {
    fn evict_oldest(&mut self) -> Option<(AudioSlot, bool)> {
        let slot = self.ready.pop_front()?;
        if let Some(next) = self.ready.front_mut() {
            next.metadata.forced_discontinuity = true;
            Some((slot, false))
        } else {
            Some((slot, true))
        }
    }
}

#[derive(Debug)]
pub struct BoundedCaptureQueue {
    state: Mutex<QueueState>,
    available: Condvar,
    slot_count: usize,
    max_packet_bytes: usize,
    dropped_packets: AtomicU64,
    force_discontinuity: AtomicBool,
}

impl BoundedCaptureQueue {
    pub fn new(slot_count: usize, max_packet_bytes: usize) -> Result<Arc<Self>, CaptureError> {
        if slot_count == 0 || max_packet_bytes == 0 {
            return Err(CaptureError::InvalidFormat(
                "queue slots and maximum packet bytes must be non-zero".to_owned(),
            ));
        }
        let mut free = VecDeque::with_capacity(slot_count);
        for _ in 0..slot_count {
            free.push_back(AudioSlot::new(max_packet_bytes));
        }
        Ok(Arc::new(Self {
            state: Mutex::new(QueueState {
                free,
                ready: VecDeque::with_capacity(slot_count),
                closed: None,
            }),
            available: Condvar::new(),
            slot_count,
            max_packet_bytes,
            dropped_packets: AtomicU64::new(0),
            force_discontinuity: AtomicBool::new(false),
        }))
    }

    pub fn dropped_packets(&self) -> u64 {
        self.dropped_packets.load(Ordering::Relaxed)
    }

    pub fn capacity(&self) -> usize {
        self.slot_count
    }

    /// Discards all currently queued packets and marks the next accepted packet
    /// as the first survivor after a gap.
    ///
    /// This is used only when captured audio is already too old to meet the
    /// configured receiver latency budget.
    pub fn discard_ready_packets(&self) -> usize {
        let mut state = lock_recover(&self.state);
        let discarded = state.ready.len();
        while let Some(mut slot) = state.ready.pop_front() {
            slot.length = 0;
            slot.metadata = PacketMetadata::default();
            state.free.push_back(slot);
        }
        self.dropped_packets.fetch_add(
            u64::try_from(discarded).unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
        self.force_discontinuity.store(true, Ordering::Release);
        discarded
    }

    fn push_packet(&self, bytes: Option<&[u8]>, metadata: PacketMetadata) {
        let byte_count = bytes.map_or_else(
            || {
                usize::try_from(metadata.frames)
                    .unwrap_or(usize::MAX)
                    .saturating_mul(self.max_packet_bytes)
            },
            <[u8]>::len,
        );
        if byte_count > self.max_packet_bytes {
            self.record_drop();
            return;
        }

        let Ok(mut state) = self.state.try_lock() else {
            self.record_drop();
            return;
        };
        if state.closed.is_some() {
            return;
        }

        let (mut slot, discontinuity_before_slot) = if let Some(slot) = state.free.pop_front() {
            (slot, false)
        } else if let Some((slot, discontinuity_before_slot)) = state.evict_oldest() {
            self.dropped_packets.fetch_add(1, Ordering::Relaxed);
            (slot, discontinuity_before_slot)
        } else {
            drop(state);
            self.record_drop();
            return;
        };

        match bytes {
            Some(source) => slot.bytes[..source.len()].copy_from_slice(source),
            None => slot.bytes[..byte_count].fill(0),
        }
        slot.length = byte_count;
        let pending_discontinuity = self.force_discontinuity.swap(false, Ordering::AcqRel);
        slot.metadata = PacketMetadata {
            forced_discontinuity: metadata.forced_discontinuity
                || discontinuity_before_slot
                || pending_discontinuity,
            ..metadata
        };
        state.ready.push_back(slot);
        self.available.notify_one();
    }

    fn push_silence(&self, byte_count: usize, metadata: PacketMetadata) {
        if byte_count > self.max_packet_bytes {
            self.record_drop();
            return;
        }
        let Ok(mut state) = self.state.try_lock() else {
            self.record_drop();
            return;
        };
        if state.closed.is_some() {
            return;
        }
        let (mut slot, discontinuity_before_slot) = if let Some(slot) = state.free.pop_front() {
            (slot, false)
        } else if let Some((slot, discontinuity_before_slot)) = state.evict_oldest() {
            self.dropped_packets.fetch_add(1, Ordering::Relaxed);
            (slot, discontinuity_before_slot)
        } else {
            drop(state);
            self.record_drop();
            return;
        };
        slot.bytes[..byte_count].fill(0);
        slot.length = byte_count;
        let pending_discontinuity = self.force_discontinuity.swap(false, Ordering::AcqRel);
        slot.metadata = PacketMetadata {
            forced_discontinuity: metadata.forced_discontinuity
                || discontinuity_before_slot
                || pending_discontinuity,
            ..metadata
        };
        state.ready.push_back(slot);
        self.available.notify_one();
    }

    fn record_drop(&self) {
        self.dropped_packets.fetch_add(1, Ordering::Relaxed);
        self.force_discontinuity.store(true, Ordering::Release);
    }

    pub fn pop_timeout(
        self: &Arc<Self>,
        timeout: Duration,
    ) -> Result<Option<CapturedPacket>, CaptureError> {
        let state = lock_recover(&self.state);
        let (mut state, _) = self
            .available
            .wait_timeout_while(state, timeout, |queue| {
                queue.ready.is_empty() && queue.closed.is_none()
            })
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(slot) = state.ready.pop_front() {
            return Ok(Some(CapturedPacket {
                queue: Arc::clone(self),
                slot: Some(slot),
            }));
        }
        if let Some(reason) = &state.closed {
            return Err(CaptureError::QueueClosed(reason.clone()));
        }
        Ok(None)
    }

    fn close(&self, reason: impl Into<String>) {
        let mut state = lock_recover(&self.state);
        if state.closed.is_none() {
            state.closed = Some(reason.into());
        }
        self.available.notify_all();
    }

    #[cfg(test)]
    fn push_test_packet(&self, bytes: &[u8], metadata: PacketMetadata) {
        self.push_packet(Some(bytes), metadata);
    }
}

#[derive(Debug)]
pub struct CapturedPacket {
    queue: Arc<BoundedCaptureQueue>,
    slot: Option<AudioSlot>,
}

impl CapturedPacket {
    #[must_use]
    pub fn bytes(&self) -> &[u8] {
        let slot = self.slot.as_ref().expect("packet slot exists until drop");
        &slot.bytes[..slot.length]
    }

    #[must_use]
    pub fn metadata(&self) -> PacketMetadata {
        self.slot
            .as_ref()
            .expect("packet slot exists until drop")
            .metadata
    }
}

impl Drop for CapturedPacket {
    fn drop(&mut self) {
        if let Some(slot) = self.slot.take() {
            let mut state = lock_recover(&self.queue.state);
            state.free.push_back(slot);
        }
    }
}

fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

struct OwnedEvent(HANDLE);

impl OwnedEvent {
    fn create() -> Result<Self, CaptureError> {
        // SAFETY: default security, unnamed auto-reset event.
        let handle =
            unsafe { CreateEventW(None, false, false, PCWSTR::null()) }.map_err(|error| {
                CaptureError::Windows {
                    operation: "CreateEventW",
                    detail: error.to_string(),
                }
            })?;
        Ok(Self(handle))
    }

    fn set(&self) -> Result<(), CaptureError> {
        // SAFETY: self owns a live event handle.
        unsafe { SetEvent(self.0) }.map_err(|error| CaptureError::Windows {
            operation: "SetEvent(stop)",
            detail: error.to_string(),
        })
    }
}

impl Drop for OwnedEvent {
    fn drop(&mut self) {
        // SAFETY: the handle was returned by CreateEventW and is closed once.
        if let Err(error) = unsafe { CloseHandle(self.0) } {
            tracing::error!(operation = "CloseHandle(event)", %error);
        }
    }
}

struct ComApartment;

impl ComApartment {
    fn initialize() -> Result<Self, CaptureError> {
        // SAFETY: initializes COM for the current worker thread.
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(|error| CaptureError::Windows {
                operation: "CoInitializeEx(MTA)",
                detail: error.to_string(),
            })?;
        Ok(Self)
    }
}

impl Drop for ComApartment {
    fn drop(&mut self) {
        // SAFETY: paired with successful CoInitializeEx on this thread.
        unsafe { CoUninitialize() };
    }
}

struct MixFormat(*mut WAVEFORMATEX);

impl MixFormat {
    fn get(client: &IAudioClient2) -> Result<Self, CaptureError> {
        // SAFETY: COM interface is valid and returns CoTaskMem-owned format data.
        let pointer = unsafe { client.GetMixFormat() }.map_err(|error| CaptureError::Windows {
            operation: "IAudioClient::GetMixFormat",
            detail: error.to_string(),
        })?;
        if pointer.is_null() {
            return Err(CaptureError::InvalidFormat(
                "GetMixFormat returned a null pointer".to_owned(),
            ));
        }
        Ok(Self(pointer))
    }

    fn as_ptr(&self) -> *const WAVEFORMATEX {
        self.0
    }

    fn format(&self) -> Result<CaptureFormat, CaptureError> {
        // SAFETY: MixFormat owns a non-null WAVEFORMATEX pointer.
        let format = unsafe { &*self.0 };
        let format_tag = format.wFormatTag;
        let channels = format.nChannels;
        let sample_rate = format.nSamplesPerSec;
        let block_align = format.nBlockAlign;
        let bits_per_sample = format.wBitsPerSample;
        let extra_size = format.cbSize;
        if channels == 0 || sample_rate == 0 || block_align == 0 || bits_per_sample == 0 {
            return Err(CaptureError::InvalidFormat(format!(
                "channels={channels}, sample_rate={sample_rate}, block_align={block_align}, bits={bits_per_sample}"
            )));
        }
        let sample_kind = match (format_tag, bits_per_sample) {
            (WAVE_FORMAT_PCM, 16) => CaptureSampleKind::SignedPcm16,
            (WAVE_FORMAT_IEEE_FLOAT, 32) => CaptureSampleKind::Float32,
            (WAVE_FORMAT_EXTENSIBLE, 16 | 32)
                if usize::from(extra_size)
                    >= size_of::<WAVEFORMATEXTENSIBLE>() - size_of::<WAVEFORMATEX>() =>
            {
                let extended = self.0.cast::<WAVEFORMATEXTENSIBLE>();
                // SAFETY: cbSize proves that the extensible fields exist; the
                // packed GUID is copied with an unaligned read.
                let subtype =
                    unsafe { std::ptr::addr_of!((*extended).SubFormat).read_unaligned() }.to_u128();
                match (subtype, bits_per_sample) {
                    (PCM_SUBFORMAT, 16) => CaptureSampleKind::SignedPcm16,
                    (IEEE_FLOAT_SUBFORMAT, 32) => CaptureSampleKind::Float32,
                    _ => {
                        return Err(CaptureError::InvalidFormat(format!(
                            "unsupported extensible subtype {subtype:032x} with {bits_per_sample} bits"
                        )));
                    }
                }
            }
            _ => {
                return Err(CaptureError::InvalidFormat(format!(
                    "unsupported format tag {format_tag} with {bits_per_sample} bits"
                )));
            }
        };
        Ok(CaptureFormat {
            format_tag,
            channels,
            sample_rate,
            bits_per_sample,
            block_align,
            sample_kind,
        })
    }
}

impl Drop for MixFormat {
    fn drop(&mut self) {
        // SAFETY: pointer came from GetMixFormat and uses CoTaskMem.
        unsafe { CoTaskMemFree(Some(self.0.cast())) };
    }
}

pub struct WasapiLoopbackCapture {
    queue: Arc<BoundedCaptureQueue>,
    format: CaptureFormat,
    stop_event: OwnedEvent,
    thread: Option<JoinHandle<Result<(), CaptureError>>>,
}

impl WasapiLoopbackCapture {
    pub fn start(endpoint_id: &str, queue_slots: usize) -> Result<Self, CaptureError> {
        let stop_event = OwnedEvent::create()?;
        let stop_value = stop_event.0.0 as usize;
        let endpoint_id = endpoint_id.to_owned();
        let (startup_sender, startup_receiver) = mpsc::sync_channel(1);

        let thread = thread::Builder::new()
            .name("winairplay-wasapi-loopback".to_owned())
            .spawn(move || {
                capture_thread(
                    &endpoint_id,
                    HANDLE(stop_value as *mut core::ffi::c_void),
                    queue_slots,
                    &startup_sender,
                )
            })
            .map_err(|error| CaptureError::Windows {
                operation: "spawning WASAPI capture thread",
                detail: error.to_string(),
            })?;

        let startup = match startup_receiver.recv_timeout(STARTUP_TIMEOUT) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) => {
                let _ = stop_event.set();
                let _ = thread.join();
                return Err(CaptureError::StartupTimedOut(STARTUP_TIMEOUT));
            }
            Err(RecvTimeoutError::Disconnected) => {
                let _ = thread.join();
                return Err(CaptureError::StartupChannelClosed);
            }
        }?;
        Ok(Self {
            queue: startup.queue,
            format: startup.format,
            stop_event,
            thread: Some(thread),
        })
    }

    #[must_use]
    pub fn queue(&self) -> Arc<BoundedCaptureQueue> {
        Arc::clone(&self.queue)
    }

    #[must_use]
    pub fn format(&self) -> CaptureFormat {
        self.format
    }

    pub fn stop(mut self) -> Result<(), CaptureError> {
        self.stop_and_join()
    }

    fn stop_and_join(&mut self) -> Result<(), CaptureError> {
        self.stop_event.set()?;
        let Some(thread) = self.thread.take() else {
            return Ok(());
        };
        match thread.join() {
            Ok(result) => result,
            Err(_) => Err(CaptureError::ThreadPanicked),
        }
    }
}

impl Drop for WasapiLoopbackCapture {
    fn drop(&mut self) {
        if let Err(error) = self.stop_and_join() {
            tracing::error!(operation = "stopping WASAPI capture", %error);
        }
    }
}

struct CaptureStartup {
    queue: Arc<BoundedCaptureQueue>,
    format: CaptureFormat,
}

struct CaptureQueueCloseGuard {
    queue: Arc<BoundedCaptureQueue>,
}

impl Drop for CaptureQueueCloseGuard {
    fn drop(&mut self) {
        self.queue
            .close("capture thread exited before reporting a final result");
    }
}

fn capture_thread(
    endpoint_id: &str,
    stop_event: HANDLE,
    queue_slots: usize,
    startup: &mpsc::SyncSender<Result<CaptureStartup, CaptureError>>,
) -> Result<(), CaptureError> {
    let result = capture_thread_inner(endpoint_id, stop_event, queue_slots, startup);
    if let Err(error) = &result {
        let _ = startup.try_send(Err(error.clone()));
    }
    result
}

fn capture_thread_inner(
    endpoint_id: &str,
    stop_event: HANDLE,
    queue_slots: usize,
    startup: &mpsc::SyncSender<Result<CaptureStartup, CaptureError>>,
) -> Result<(), CaptureError> {
    let _com = ComApartment::initialize()?;
    // SAFETY: COM is initialized and the CLSID/IID pairing is fixed by the type.
    let enumerator: IMMDeviceEnumerator = unsafe {
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
    }
    .map_err(|error| CaptureError::Windows {
        operation: "CoCreateInstance(MMDeviceEnumerator)",
        detail: error.to_string(),
    })?;
    let endpoint_wide: Vec<u16> = endpoint_id
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: endpoint_wide is NUL-terminated for the call.
    let endpoint =
        unsafe { enumerator.GetDevice(PCWSTR(endpoint_wide.as_ptr())) }.map_err(|error| {
            CaptureError::Windows {
                operation: "IMMDeviceEnumerator::GetDevice",
                detail: error.to_string(),
            }
        })?;
    // SAFETY: the endpoint is active and activation parameters are absent.
    let client: IAudioClient2 =
        unsafe { endpoint.Activate(CLSCTX_ALL, None) }.map_err(|error| CaptureError::Windows {
            operation: "IMMDevice::Activate(IAudioClient2)",
            detail: error.to_string(),
        })?;
    // Do not set a render usage category on a loopback-capture client.
    // AUDCLNT_STREAMOPTIONS_NONE is already the default and selects the
    // driver's pre-volume/mute path. On Windows 11 24H2, setting
    // AudioCategory_Media here makes Initialize reject this otherwise
    // supported loopback stream with E_INVALIDARG.

    let mix = MixFormat::get(&client)?;
    let format = mix.format()?;
    // SAFETY: mix format remains alive until after the client is stopped.
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
            0,
            0,
            mix.as_ptr(),
            None,
        )
    }
    .map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::Initialize(shared loopback event mode)",
        detail: error.to_string(),
    })?;
    // SAFETY: the initialized client exposes a finite shared buffer size.
    let buffer_frames =
        unsafe { client.GetBufferSize() }.map_err(|error| CaptureError::Windows {
            operation: "IAudioClient::GetBufferSize",
            detail: error.to_string(),
        })?;
    let maximum_bytes = usize::try_from(buffer_frames)
        .ok()
        .and_then(|frames| frames.checked_mul(usize::from(format.block_align)))
        .ok_or_else(|| {
            CaptureError::InvalidFormat("audio buffer byte size overflowed usize".to_owned())
        })?;
    let queue = BoundedCaptureQueue::new(queue_slots, maximum_bytes)?;
    let _queue_close_guard = CaptureQueueCloseGuard {
        queue: Arc::clone(&queue),
    };
    let audio_event = OwnedEvent::create()?;
    // SAFETY: audio_event remains alive through Stop.
    unsafe { client.SetEventHandle(audio_event.0) }.map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::SetEventHandle",
        detail: error.to_string(),
    })?;
    // SAFETY: the initialized audio client provides IAudioCaptureClient.
    let capture: IAudioCaptureClient =
        unsafe { client.GetService() }.map_err(|error| CaptureError::Windows {
            operation: "IAudioClient::GetService(IAudioCaptureClient)",
            detail: error.to_string(),
        })?;

    // SAFETY: initialization and event registration have completed.
    unsafe { client.Start() }.map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::Start",
        detail: error.to_string(),
    })?;

    // Do not publish a usable capture until Start has succeeded. After Start,
    // avoid `?` so every path executes the matching Stop operation.
    let run_result = match startup.send(Ok(CaptureStartup {
        queue: Arc::clone(&queue),
        format,
    })) {
        Ok(()) => run_capture_loop(&client, &capture, &queue, audio_event.0, stop_event, format),
        Err(_) => Err(CaptureError::StartupChannelClosed),
    };
    // SAFETY: Start succeeded; Stop is the matching operation.
    let stop_result = unsafe { client.Stop() }.map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::Stop",
        detail: error.to_string(),
    });
    let final_result = run_result.and(stop_result);
    queue.close(match &final_result {
        Ok(()) => "capture stopped".to_owned(),
        Err(error) => error.to_string(),
    });
    final_result
}

fn run_capture_loop(
    _client: &IAudioClient2,
    capture: &IAudioCaptureClient,
    queue: &BoundedCaptureQueue,
    audio_event: HANDLE,
    stop_event: HANDLE,
    format: CaptureFormat,
) -> Result<(), CaptureError> {
    loop {
        // SAFETY: both handles remain open for the loop duration.
        let wait = unsafe { WaitForMultipleObjects(&[audio_event, stop_event], false, INFINITE) };
        if wait == WAIT_OBJECT_0 {
            drain_capture_packets(capture, queue, format)?;
        } else if wait.0 == WAIT_OBJECT_0.0 + 1 {
            return Ok(());
        } else if wait == WAIT_FAILED {
            return Err(CaptureError::Windows {
                operation: "WaitForMultipleObjects",
                detail: std::io::Error::last_os_error().to_string(),
            });
        } else {
            return Err(CaptureError::Windows {
                operation: "WaitForMultipleObjects",
                detail: format!("unexpected wait result {}", wait.0),
            });
        }
    }
}

fn drain_capture_packets(
    capture: &IAudioCaptureClient,
    queue: &BoundedCaptureQueue,
    format: CaptureFormat,
) -> Result<(), CaptureError> {
    loop {
        // SAFETY: capture is valid while the audio client is started.
        let next_frames =
            unsafe { capture.GetNextPacketSize() }.map_err(|error| CaptureError::Windows {
                operation: "IAudioCaptureClient::GetNextPacketSize",
                detail: error.to_string(),
            })?;
        if next_frames == 0 {
            return Ok(());
        }

        let mut data = std::ptr::null_mut();
        let mut frames = 0_u32;
        let mut flags = 0_u32;
        let mut device_position = 0_u64;
        let mut qpc_position = 0_u64;
        // SAFETY: pointers address initialized locals; ReleaseBuffer is paired below.
        unsafe {
            capture.GetBuffer(
                &raw mut data,
                &raw mut frames,
                &raw mut flags,
                Some(&raw mut device_position),
                Some(&raw mut qpc_position),
            )
        }
        .map_err(|error| CaptureError::Windows {
            operation: "IAudioCaptureClient::GetBuffer",
            detail: error.to_string(),
        })?;

        let byte_count = usize::try_from(frames)
            .ok()
            .and_then(|count| count.checked_mul(usize::from(format.block_align)))
            .ok_or_else(|| {
                CaptureError::InvalidFormat("captured packet byte size overflowed usize".to_owned())
            })?;
        let metadata = capture_packet_metadata(frames, flags, device_position, qpc_position);
        let silent = flags & u32::try_from(AUDCLNT_BUFFERFLAGS_SILENT.0).unwrap_or_default() != 0;
        if silent {
            queue.push_silence(byte_count, metadata);
        } else if data.is_null() {
            queue.record_drop();
        } else {
            // SAFETY: WASAPI guarantees byte_count bytes for frames/block alignment
            // until ReleaseBuffer.
            let source = unsafe { std::slice::from_raw_parts(data, byte_count) };
            queue.push_packet(Some(source), metadata);
        }
        // SAFETY: this releases exactly the frame count returned by GetBuffer.
        unsafe { capture.ReleaseBuffer(frames) }.map_err(|error| CaptureError::Windows {
            operation: "IAudioCaptureClient::ReleaseBuffer",
            detail: error.to_string(),
        })?;
    }
}

/// Render a deterministic tone to the active endpoint with the exact container
/// ID. This is an integration-test operation, never a production routing path.
pub fn render_test_tone(
    container_id: Uuid,
    frequency_hz: f64,
    duration: Duration,
    amplitude: f32,
) -> Result<(), CaptureError> {
    if !frequency_hz.is_finite()
        || frequency_hz <= 0.0
        || duration.is_zero()
        || duration > Duration::from_mins(5)
        || !amplitude.is_finite()
        || !(0.0..=1.0).contains(&amplitude)
    {
        return Err(CaptureError::InvalidRenderTest(format!(
            "frequency={frequency_hz}, duration={duration:?}, amplitude={amplitude}"
        )));
    }
    let endpoint_id = list_render_endpoints()?
        .into_iter()
        .find(|endpoint| endpoint.container_id == Some(container_id))
        .map(|endpoint| endpoint.endpoint_id)
        .ok_or(CaptureError::EndpointNotFound(container_id))?;
    render_test_tone_to_endpoint(&endpoint_id, frequency_hz, duration, amplitude)
}

fn render_test_tone_to_endpoint(
    endpoint_id: &str,
    frequency_hz: f64,
    duration: Duration,
    amplitude: f32,
) -> Result<(), CaptureError> {
    let _com = ComApartment::initialize()?;
    // SAFETY: COM is initialized and the class/type pairing is fixed.
    let enumerator: IMMDeviceEnumerator = unsafe {
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
    }
    .map_err(|error| CaptureError::Windows {
        operation: "CoCreateInstance(MMDeviceEnumerator) for render test",
        detail: error.to_string(),
    })?;
    let endpoint_wide: Vec<u16> = endpoint_id
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: endpoint_wide is NUL-terminated for the call.
    let endpoint =
        unsafe { enumerator.GetDevice(PCWSTR(endpoint_wide.as_ptr())) }.map_err(|error| {
            CaptureError::Windows {
                operation: "IMMDeviceEnumerator::GetDevice for render test",
                detail: error.to_string(),
            }
        })?;
    // SAFETY: endpoint is active and activation parameters are absent.
    let client: IAudioClient2 =
        unsafe { endpoint.Activate(CLSCTX_ALL, None) }.map_err(|error| CaptureError::Windows {
            operation: "IMMDevice::Activate(IAudioClient2) for render test",
            detail: error.to_string(),
        })?;
    let mix = MixFormat::get(&client)?;
    let format = mix.format()?;
    if frequency_hz >= f64::from(format.sample_rate) / 2.0 {
        return Err(CaptureError::InvalidRenderTest(format!(
            "frequency {frequency_hz} must be below Nyquist for {} Hz",
            format.sample_rate
        )));
    }
    // SAFETY: mix format remains alive through Stop.
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
            0,
            0,
            mix.as_ptr(),
            None,
        )
    }
    .map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::Initialize render test",
        detail: error.to_string(),
    })?;
    let event = OwnedEvent::create()?;
    // SAFETY: event remains alive through Stop.
    unsafe { client.SetEventHandle(event.0) }.map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::SetEventHandle render test",
        detail: error.to_string(),
    })?;
    // SAFETY: initialized render client provides this service.
    let render: IAudioRenderClient =
        unsafe { client.GetService() }.map_err(|error| CaptureError::Windows {
            operation: "IAudioClient::GetService(IAudioRenderClient)",
            detail: error.to_string(),
        })?;
    let total_frames = u64::try_from(
        duration
            .as_nanos()
            .saturating_mul(u128::from(format.sample_rate))
            / 1_000_000_000,
    )
    .map_err(|_| CaptureError::InvalidRenderTest("frame count overflow".to_owned()))?;
    let buffer_frames =
        unsafe { client.GetBufferSize() }.map_err(|error| CaptureError::Windows {
            operation: "IAudioClient::GetBufferSize render test",
            detail: error.to_string(),
        })?;
    let initial_frames = u32::try_from(total_frames.min(u64::from(buffer_frames)))
        .expect("minimum of u64 and u32 fits u32");
    write_tone_frames(&render, format, 0, initial_frames, frequency_hz, amplitude)?;
    // SAFETY: initialization, event registration, and initial fill completed.
    unsafe { client.Start() }.map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::Start render test",
        detail: error.to_string(),
    })?;

    let render_result = render_remaining_frames(
        &client,
        &render,
        event.0,
        format,
        total_frames,
        u64::from(initial_frames),
        frequency_hz,
        amplitude,
    );
    // SAFETY: Start succeeded and Stop is its matching operation.
    let stop_result = unsafe { client.Stop() }.map_err(|error| CaptureError::Windows {
        operation: "IAudioClient::Stop render test",
        detail: error.to_string(),
    });
    render_result.and(stop_result)
}

#[allow(clippy::too_many_arguments)]
fn render_remaining_frames(
    client: &IAudioClient2,
    render: &IAudioRenderClient,
    event: HANDLE,
    format: CaptureFormat,
    total_frames: u64,
    mut written_frames: u64,
    frequency_hz: f64,
    amplitude: f32,
) -> Result<(), CaptureError> {
    while written_frames < total_frames {
        // SAFETY: event remains valid and timeout is finite.
        let wait = unsafe { WaitForSingleObject(event, 5_000) };
        if wait == WAIT_TIMEOUT {
            return Err(CaptureError::Windows {
                operation: "waiting for render-test audio event",
                detail: "timed out after 5 seconds".to_owned(),
            });
        }
        if wait != WAIT_OBJECT_0 {
            return Err(CaptureError::Windows {
                operation: "waiting for render-test audio event",
                detail: std::io::Error::last_os_error().to_string(),
            });
        }
        // SAFETY: client is initialized and running.
        let padding =
            unsafe { client.GetCurrentPadding() }.map_err(|error| CaptureError::Windows {
                operation: "IAudioClient::GetCurrentPadding render test",
                detail: error.to_string(),
            })?;
        // SAFETY: initialized client reports a stable shared buffer size.
        let buffer_frames =
            unsafe { client.GetBufferSize() }.map_err(|error| CaptureError::Windows {
                operation: "IAudioClient::GetBufferSize render loop",
                detail: error.to_string(),
            })?;
        let available = buffer_frames.saturating_sub(padding);
        let frames = u32::try_from((total_frames - written_frames).min(u64::from(available)))
            .expect("minimum of u64 and u32 fits u32");
        if frames == 0 {
            continue;
        }
        write_tone_frames(
            render,
            format,
            written_frames,
            frames,
            frequency_hz,
            amplitude,
        )?;
        written_frames += u64::from(frames);
    }
    // Wait for the final queued frames to be consumed instead of truncating.
    loop {
        // SAFETY: client remains initialized and running.
        let padding =
            unsafe { client.GetCurrentPadding() }.map_err(|error| CaptureError::Windows {
                operation: "IAudioClient::GetCurrentPadding final drain",
                detail: error.to_string(),
            })?;
        if padding == 0 {
            return Ok(());
        }
        // SAFETY: event remains live and timeout is finite.
        if unsafe { WaitForSingleObject(event, 5_000) } == WAIT_TIMEOUT {
            return Err(CaptureError::Windows {
                operation: "draining render-test audio",
                detail: "timed out after 5 seconds".to_owned(),
            });
        }
    }
}

#[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
fn write_tone_frames(
    render: &IAudioRenderClient,
    format: CaptureFormat,
    start_frame: u64,
    frames: u32,
    frequency_hz: f64,
    amplitude: f32,
) -> Result<(), CaptureError> {
    // SAFETY: frames does not exceed the available initialized render buffer.
    let destination =
        unsafe { render.GetBuffer(frames) }.map_err(|error| CaptureError::Windows {
            operation: "IAudioRenderClient::GetBuffer",
            detail: error.to_string(),
        })?;
    let byte_count = usize::try_from(frames)
        .ok()
        .and_then(|value| value.checked_mul(usize::from(format.block_align)))
        .ok_or_else(|| CaptureError::InvalidRenderTest("render byte count overflow".to_owned()))?;
    // SAFETY: GetBuffer provides frames * block_align writable bytes until ReleaseBuffer.
    let bytes = unsafe { std::slice::from_raw_parts_mut(destination, byte_count) };
    for frame in 0..u64::from(frames) {
        // The public operation is capped at five minutes, so frame indices are
        // far below f64's exact-integer limit even at the maximum accepted rate.
        let phase = std::f64::consts::TAU * frequency_hz * (start_frame + frame) as f64
            / f64::from(format.sample_rate);
        let sample = (phase.sin() * f64::from(amplitude)) as f32;
        for channel in 0..usize::from(format.channels) {
            let sample_index = usize::try_from(frame).unwrap_or(usize::MAX)
                * usize::from(format.channels)
                + channel;
            match format.sample_kind {
                CaptureSampleKind::SignedPcm16 => {
                    let offset = sample_index * 2;
                    bytes[offset..offset + 2].copy_from_slice(
                        &winairplay_shared::audio::f32_to_i16(sample).to_le_bytes(),
                    );
                }
                CaptureSampleKind::Float32 => {
                    let offset = sample_index * 4;
                    bytes[offset..offset + 4].copy_from_slice(&sample.to_le_bytes());
                }
            }
        }
    }
    // SAFETY: the entire requested buffer was initialized.
    unsafe { render.ReleaseBuffer(frames, 0) }.map_err(|error| CaptureError::Windows {
        operation: "IAudioRenderClient::ReleaseBuffer",
        detail: error.to_string(),
    })
}

pub fn list_render_endpoints() -> Result<Vec<RenderEndpoint>, CaptureError> {
    let _com = ComApartment::initialize()?;
    // SAFETY: COM is initialized and the class/type pairing is fixed.
    let enumerator: IMMDeviceEnumerator = unsafe {
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)
    }
    .map_err(|error| CaptureError::Windows {
        operation: "CoCreateInstance(MMDeviceEnumerator)",
        detail: error.to_string(),
    })?;
    // SAFETY: enumerator is a live COM interface.
    let collection = unsafe { enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) }
        .map_err(|error| CaptureError::Windows {
            operation: "IMMDeviceEnumerator::EnumAudioEndpoints",
            detail: error.to_string(),
        })?;
    // SAFETY: collection is a live COM interface.
    let count = unsafe { collection.GetCount() }.map_err(|error| CaptureError::Windows {
        operation: "IMMDeviceCollection::GetCount",
        detail: error.to_string(),
    })?;
    let mut endpoints = Vec::with_capacity(usize::try_from(count).unwrap_or_default());
    for index in 0..count {
        // SAFETY: index is within the reported count.
        let endpoint =
            unsafe { collection.Item(index) }.map_err(|error| CaptureError::Windows {
                operation: "IMMDeviceCollection::Item",
                detail: error.to_string(),
            })?;
        endpoints.push(read_endpoint(&endpoint)?);
    }
    Ok(endpoints)
}

fn read_endpoint(endpoint: &IMMDevice) -> Result<RenderEndpoint, CaptureError> {
    // SAFETY: endpoint is a live COM interface; returned ID uses CoTaskMem.
    let id_pointer = unsafe { endpoint.GetId() }.map_err(|error| CaptureError::Windows {
        operation: "IMMDevice::GetId",
        detail: error.to_string(),
    })?;
    // SAFETY: GetId returns a valid NUL-terminated endpoint identifier.
    let endpoint_id = unsafe { id_pointer.to_string() }.map_err(|error| CaptureError::Windows {
        operation: "decoding endpoint ID",
        detail: error.to_string(),
    })?;
    // SAFETY: ID allocation is documented as CoTaskMem.
    unsafe { CoTaskMemFree(Some(id_pointer.0.cast())) };

    // SAFETY: endpoint is valid and store is opened read-only.
    let store = unsafe { endpoint.OpenPropertyStore(STGM_READ) }.map_err(|error| {
        CaptureError::Windows {
            operation: "IMMDevice::OpenPropertyStore",
            detail: error.to_string(),
        }
    })?;
    // SAFETY: property key is a stable SDK constant.
    let friendly_key = PKEY_Device_FriendlyName;
    let friendly_variant = unsafe { store.GetValue(&raw const friendly_key) }.map_err(|error| {
        CaptureError::Windows {
            operation: "IPropertyStore::GetValue(PKEY_Device_FriendlyName)",
            detail: error.to_string(),
        }
    })?;
    let friendly_name = BSTR::try_from(&friendly_variant)
        .ok()
        .and_then(|value| String::try_from(&value).ok())
        .unwrap_or_else(|| "<unnamed render endpoint>".to_owned());

    // SAFETY: property key is a stable SDK constant.
    let container_key = PKEY_Device_ContainerId;
    let container_variant = unsafe { store.GetValue(&raw const container_key) }.ok();
    let container_id = container_variant
        .as_ref()
        .and_then(property_variant_container_id);
    // The driver copies this private key onto the KS audio interfaces, but
    // AudioEndpointBuilder does not guarantee that arbitrary interface keys
    // are projected into the child IMMDevice property store. Treat it as an
    // optional consistency check; the deterministic container ID is the
    // supported endpoint-to-receiver identity.
    let receiver_key = RECEIVER_ID_PROPERTY;
    let receiver_id = match unsafe { store.GetValue(&raw const receiver_key) } {
        Ok(value) if value.vt() == VT_EMPTY => None,
        Ok(value) => BSTR::try_from(&value)
            .ok()
            .and_then(|value| String::try_from(&value).ok())
            .filter(|value| is_canonical_receiver_id(value))
            .or_else(|| Some(INVALID_RECEIVER_ID_PROPERTY.to_owned())),
        // An unreadable present-or-missing private property cannot be treated
        // as a proven absence. Exact container identity is authoritative only
        // when the optional consistency property is absent (VT_EMPTY).
        Err(_) => Some(INVALID_RECEIVER_ID_PROPERTY.to_owned()),
    };
    Ok(RenderEndpoint {
        endpoint_id,
        friendly_name,
        container_id,
        receiver_id,
    })
}

fn is_canonical_receiver_id(value: &str) -> bool {
    value.len() == 12
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'A'..=b'F').contains(&byte))
}

fn property_variant_container_id(
    value: &windows::Win32::System::Com::StructuredStorage::PROPVARIANT,
) -> Option<Uuid> {
    if value.vt() != VT_CLSID {
        return None;
    }
    // SAFETY: VT_CLSID guarantees the union contains a GUID pointer while value lives.
    let pointer = unsafe { value.Anonymous.Anonymous.Anonymous.puuid };
    if pointer.is_null() {
        None
    } else {
        // SAFETY: pointer validity follows from VT_CLSID and PROPVARIANT ownership.
        Some(Uuid::from_u128(unsafe { (*pointer).to_u128() }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pop_test_packet(queue: &Arc<BoundedCaptureQueue>) -> (Vec<u8>, PacketMetadata) {
        let packet = queue
            .pop_timeout(Duration::from_millis(10))
            .unwrap()
            .unwrap();
        (packet.bytes().to_vec(), packet.metadata())
    }

    #[test]
    fn receiver_interface_identity_requires_canonical_device_id() {
        assert!(is_canonical_receiver_id("0011AABBCCFF"));
        assert!(!is_canonical_receiver_id("00:11:AA:BB:CC:FF"));
        assert!(!is_canonical_receiver_id("0011aabbccff"));
        assert!(!is_canonical_receiver_id("0011AABBCC"));
    }

    #[test]
    fn queue_preserves_packet_and_metadata() {
        let queue = BoundedCaptureQueue::new(2, 16).unwrap();
        queue.push_test_packet(
            &[1, 2, 3, 4],
            PacketMetadata {
                frames: 1,
                device_position: 42,
                ..PacketMetadata::default()
            },
        );
        let packet = queue
            .pop_timeout(Duration::from_millis(10))
            .unwrap()
            .unwrap();
        assert_eq!(packet.bytes(), &[1, 2, 3, 4]);
        assert_eq!(packet.metadata().device_position, 42);
    }

    #[test]
    fn queue_drops_oldest_and_marks_next_consumed_packet() {
        let queue = BoundedCaptureQueue::new(2, 4).unwrap();
        queue.push_test_packet(&[1], PacketMetadata::default());
        queue.push_test_packet(&[2], PacketMetadata::default());
        queue.push_test_packet(&[3], PacketMetadata::default());
        assert_eq!(queue.dropped_packets(), 1);
        let (first_bytes, first_metadata) = pop_test_packet(&queue);
        assert_eq!(first_bytes, [2]);
        assert!(first_metadata.forced_discontinuity);
        let (second_bytes, second_metadata) = pop_test_packet(&queue);
        assert_eq!(second_bytes, [3]);
        assert!(!second_metadata.forced_discontinuity);
    }

    #[test]
    fn repeated_overflow_coalesces_on_earliest_surviving_packet() {
        let queue = BoundedCaptureQueue::new(3, 4).unwrap();
        for value in 1..=5 {
            queue.push_test_packet(&[value], PacketMetadata::default());
        }
        assert_eq!(queue.dropped_packets(), 2);

        for (expected, discontinuity) in [(3, true), (4, false), (5, false)] {
            let (bytes, metadata) = pop_test_packet(&queue);
            assert_eq!(bytes, [expected]);
            assert_eq!(metadata.forced_discontinuity, discontinuity);
        }
    }

    #[test]
    fn producer_side_losses_mark_only_the_next_later_packet() {
        let queue = BoundedCaptureQueue::new(4, 4).unwrap();
        queue.push_test_packet(&[1], PacketMetadata::default());
        queue.push_test_packet(&[2], PacketMetadata::default());
        queue.record_drop();
        queue.record_drop();
        queue.push_test_packet(&[3], PacketMetadata::default());
        assert_eq!(queue.dropped_packets(), 2);

        for (expected, discontinuity) in [(1, false), (2, false), (3, true)] {
            let (bytes, metadata) = pop_test_packet(&queue);
            assert_eq!(bytes, [expected]);
            assert_eq!(metadata.forced_discontinuity, discontinuity);
        }
    }

    #[test]
    fn source_data_discontinuity_survives_but_timestamp_error_is_not_an_audio_gap() {
        use windows::Win32::Media::Audio::AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR;

        let data_discontinuity = u32::try_from(AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0).unwrap();
        let timestamp_error = u32::try_from(AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR.0).unwrap();
        let silent = u32::try_from(AUDCLNT_BUFFERFLAGS_SILENT.0).unwrap();
        let queue = BoundedCaptureQueue::new(2, 4).unwrap();

        queue.record_drop();
        let source_gap = capture_packet_metadata(1, data_discontinuity, 10, 20);
        queue.push_test_packet(&[1], source_gap);
        queue.push_test_packet(&[2], PacketMetadata::default());
        let (_, preserved) = pop_test_packet(&queue);
        assert!(preserved.forced_discontinuity);
        assert_eq!(preserved.flags, data_discontinuity);
        let (_, following) = pop_test_packet(&queue);
        assert!(!following.forced_discontinuity);

        let timestamp_only = capture_packet_metadata(1, timestamp_error, 11, 21);
        queue.push_test_packet(&[3], timestamp_only);
        let (_, timestamp_only) = pop_test_packet(&queue);
        assert!(!timestamp_only.forced_discontinuity);
        assert_eq!(timestamp_only.flags, timestamp_error);

        let silent_source_gap =
            capture_packet_metadata(1, data_discontinuity | timestamp_error | silent, 12, 22);
        queue.push_silence(1, silent_source_gap);
        let (bytes, preserved_silence) = pop_test_packet(&queue);
        assert_eq!(bytes, [0]);
        assert!(preserved_silence.forced_discontinuity);
    }

    #[test]
    fn held_packets_cause_bounded_drop_not_allocation() {
        let queue = BoundedCaptureQueue::new(1, 4).unwrap();
        queue.push_test_packet(&[1], PacketMetadata::default());
        let held = queue
            .pop_timeout(Duration::from_millis(10))
            .unwrap()
            .unwrap();
        queue.push_test_packet(&[2], PacketMetadata::default());
        assert_eq!(queue.dropped_packets(), 1);
        assert!(
            queue
                .pop_timeout(Duration::from_millis(1))
                .unwrap()
                .is_none()
        );
        drop(held);
        queue.push_test_packet(&[3], PacketMetadata::default());
        let recovered = queue
            .pop_timeout(Duration::from_millis(10))
            .unwrap()
            .unwrap();
        assert_eq!(recovered.bytes(), &[3]);
        assert!(recovered.metadata().forced_discontinuity);
    }

    #[test]
    fn stale_queue_discard_recycles_slots_and_marks_the_next_packet() {
        let queue = BoundedCaptureQueue::new(3, 4).unwrap();
        queue.push_test_packet(&[1], PacketMetadata::default());
        queue.push_test_packet(&[2], PacketMetadata::default());
        assert_eq!(queue.discard_ready_packets(), 2);
        assert_eq!(queue.dropped_packets(), 2);
        assert!(
            queue
                .pop_timeout(Duration::from_millis(1))
                .unwrap()
                .is_none()
        );

        queue.push_test_packet(&[3], PacketMetadata::default());
        let (bytes, metadata) = pop_test_packet(&queue);
        assert_eq!(bytes, [3]);
        assert!(metadata.forced_discontinuity);

        queue.push_test_packet(&[4], PacketMetadata::default());
        let (_, following) = pop_test_packet(&queue);
        assert!(!following.forced_discontinuity);
    }

    #[test]
    fn oversized_packet_is_rejected() {
        let queue = BoundedCaptureQueue::new(1, 2).unwrap();
        queue.push_test_packet(&[1, 2, 3], PacketMetadata::default());
        assert_eq!(queue.dropped_packets(), 1);
        assert!(
            queue
                .pop_timeout(Duration::from_millis(1))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn close_wakes_consumer_with_reason() {
        let queue = BoundedCaptureQueue::new(1, 4).unwrap();
        queue.close("device invalidated");
        let error = queue
            .pop_timeout(Duration::from_secs(1))
            .expect_err("closed queue must return error");
        assert_eq!(
            error,
            CaptureError::QueueClosed("device invalidated".to_owned())
        );
    }

    #[test]
    fn capture_thread_guard_closes_a_published_queue_on_early_exit() {
        let queue = BoundedCaptureQueue::new(1, 4).unwrap();
        {
            let _guard = CaptureQueueCloseGuard {
                queue: Arc::clone(&queue),
            };
        }
        assert_eq!(
            queue
                .pop_timeout(Duration::from_millis(1))
                .expect_err("guard drop must close the capture queue"),
            CaptureError::QueueClosed(
                "capture thread exited before reporting a final result".to_owned()
            )
        );
    }

    #[test]
    #[ignore = "requires an installed, active WinAirPlayAudio endpoint"]
    fn live_loopback_initialization_matrix() {
        let container_id = std::env::var("WINAIRPLAY_TEST_CONTAINER_ID")
            .expect("set WINAIRPLAY_TEST_CONTAINER_ID to an installed endpoint container GUID");
        let container_id =
            Uuid::parse_str(&container_id).expect("WINAIRPLAY_TEST_CONTAINER_ID must be a GUID");
        let render_endpoint = list_render_endpoints()
            .unwrap()
            .into_iter()
            .find(|endpoint| endpoint.container_id == Some(container_id))
            .expect("the requested render endpoint must be active");
        let _apartment = ComApartment::initialize().unwrap();
        // SAFETY: MMDeviceEnumerator is an in-process COM class and COM is initialized.
        let enumerator: IMMDeviceEnumerator =
            unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }.unwrap();
        let endpoint_wide: Vec<u16> = render_endpoint
            .endpoint_id
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        // SAFETY: endpoint_wide is NUL-terminated for the call.
        let endpoint = unsafe { enumerator.GetDevice(PCWSTR(endpoint_wide.as_ptr())) }.unwrap();

        let cases = [
            ("timer-default", AUDCLNT_STREAMFLAGS_LOOPBACK, 0),
            (
                "event-default",
                AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                0,
            ),
            ("timer-100ms", AUDCLNT_STREAMFLAGS_LOOPBACK, 1_000_000),
            (
                "event-100ms",
                AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                1_000_000,
            ),
        ];
        for (name, flags, buffer_duration) in cases {
            // SAFETY: endpoint is active and activation parameters are absent.
            let client: IAudioClient2 = unsafe { endpoint.Activate(CLSCTX_ALL, None) }.unwrap();
            let mix = MixFormat::get(&client).unwrap();
            println!("{name} format: {:?}", mix.format().unwrap());
            // SAFETY: each fresh client and its mix format remain valid for this call.
            let result = unsafe {
                client.Initialize(
                    AUDCLNT_SHAREMODE_SHARED,
                    flags,
                    buffer_duration,
                    0,
                    mix.as_ptr(),
                    None,
                )
            };
            println!("{name}: {result:?}");
        }
    }

    #[test]
    #[ignore = "requires an installed, active WinAirPlayAudio endpoint"]
    fn live_loopback_captures_rendered_tone() {
        const EXPECTED_FREQUENCY_HZ: f64 = 997.0;
        let container_id = std::env::var("WINAIRPLAY_TEST_CONTAINER_ID")
            .expect("set WINAIRPLAY_TEST_CONTAINER_ID to an installed endpoint container GUID");
        let container_id =
            Uuid::parse_str(&container_id).expect("WINAIRPLAY_TEST_CONTAINER_ID must be a GUID");
        let endpoint = list_render_endpoints()
            .unwrap()
            .into_iter()
            .find(|endpoint| endpoint.container_id == Some(container_id))
            .expect("the requested render endpoint must be active");
        let capture = WasapiLoopbackCapture::start(&endpoint.endpoint_id, 256)
            .expect("WASAPI loopback must start");
        let format = capture.format();
        let queue = capture.queue();

        std::thread::sleep(Duration::from_millis(100));
        render_test_tone(
            container_id,
            EXPECTED_FREQUENCY_HZ,
            Duration::from_secs(1),
            0.10,
        )
        .expect("rendering the deterministic endpoint tone must succeed");

        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        let mut measurement = ToneMeasurement::new(format, EXPECTED_FREQUENCY_HZ);
        while std::time::Instant::now() < deadline {
            let Some(packet) = queue.pop_timeout(Duration::from_millis(50)).unwrap() else {
                continue;
            };
            measurement.push(packet.bytes());
        }
        capture.stop().expect("WASAPI loopback must stop cleanly");

        assert!(
            measurement.frames >= u64::from(format.sample_rate / 2),
            "captured only {} frames at {} Hz",
            measurement.frames,
            format.sample_rate
        );
        assert!(
            measurement.peak >= 0.01,
            "captured endpoint mix is silent or synthetic-zero data; peak={}",
            measurement.peak
        );
        assert!(
            measurement.normalized_correlation() >= 0.50,
            "captured audio does not correlate with the rendered {EXPECTED_FREQUENCY_HZ} Hz tone; correlation={}, peak={}, frames={}",
            measurement.normalized_correlation(),
            measurement.peak,
            measurement.frames,
        );
    }

    #[test]
    fn tone_measurement_rejects_non_target_audio() {
        let format = CaptureFormat {
            format_tag: WAVE_FORMAT_PCM,
            channels: 2,
            sample_rate: 48_000,
            bits_per_sample: 16,
            block_align: 4,
            sample_kind: CaptureSampleKind::SignedPcm16,
        };
        let sample_rate = u16::try_from(format.sample_rate).expect("test sample rate fits in u16");
        let target = pcm16_stereo_tone(sample_rate, 997.0, 0.25, 48_000);
        let wrong = pcm16_stereo_tone(sample_rate, 440.0, 0.25, 48_000);

        let mut target_measurement = ToneMeasurement::new(format, 997.0);
        target_measurement.push(&target);
        let mut wrong_measurement = ToneMeasurement::new(format, 997.0);
        wrong_measurement.push(&wrong);

        assert!(target_measurement.normalized_correlation() >= 0.99);
        assert!(wrong_measurement.normalized_correlation() <= 0.01);
    }

    struct ToneMeasurement {
        format: CaptureFormat,
        frequency_hz: f64,
        frames: u64,
        frame_position: f64,
        peak: f64,
        energy: f64,
        sine_projection: f64,
        cosine_projection: f64,
    }

    impl ToneMeasurement {
        fn new(format: CaptureFormat, frequency_hz: f64) -> Self {
            Self {
                format,
                frequency_hz,
                frames: 0,
                frame_position: 0.0,
                peak: 0.0,
                energy: 0.0,
                sine_projection: 0.0,
                cosine_projection: 0.0,
            }
        }

        fn push(&mut self, bytes: &[u8]) {
            let frame_bytes = usize::from(self.format.block_align);
            let sample_bytes = match self.format.sample_kind {
                CaptureSampleKind::SignedPcm16 => size_of::<i16>(),
                CaptureSampleKind::Float32 => size_of::<f32>(),
            };
            let channel_bytes = usize::from(self.format.channels) * sample_bytes;
            assert!(
                frame_bytes >= channel_bytes && bytes.len().is_multiple_of(frame_bytes),
                "captured test packet does not contain complete interleaved frames"
            );

            for frame in bytes.chunks_exact(frame_bytes) {
                let sample = (0..usize::from(self.format.channels))
                    .map(|channel| {
                        let offset = channel * sample_bytes;
                        match self.format.sample_kind {
                            CaptureSampleKind::SignedPcm16 => {
                                f64::from(i16::from_le_bytes([frame[offset], frame[offset + 1]]))
                                    / 32_768.0
                            }
                            CaptureSampleKind::Float32 => {
                                let value = f32::from_le_bytes([
                                    frame[offset],
                                    frame[offset + 1],
                                    frame[offset + 2],
                                    frame[offset + 3],
                                ]);
                                if value.is_finite() {
                                    f64::from(value)
                                } else {
                                    0.0
                                }
                            }
                        }
                    })
                    .sum::<f64>()
                    / f64::from(self.format.channels);
                let phase = std::f64::consts::TAU * self.frequency_hz * self.frame_position
                    / f64::from(self.format.sample_rate);
                self.peak = self.peak.max(sample.abs());
                self.energy += sample * sample;
                self.sine_projection += sample * phase.sin();
                self.cosine_projection += sample * phase.cos();
                self.frames += 1;
                self.frame_position += 1.0;
            }
        }

        fn normalized_correlation(&self) -> f64 {
            if self.frames == 0 || self.energy <= f64::EPSILON {
                return 0.0;
            }
            let projection = self.sine_projection.hypot(self.cosine_projection);
            let maximum = (self.energy * self.frame_position / 2.0).sqrt();
            (projection / maximum).min(1.0)
        }
    }

    fn pcm16_stereo_tone(
        sample_rate: u16,
        frequency_hz: f32,
        amplitude: f32,
        frames: u16,
    ) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(usize::from(frames) * 2 * size_of::<i16>());
        for frame in 0..frames {
            let phase =
                std::f32::consts::TAU * frequency_hz * f32::from(frame) / f32::from(sample_rate);
            let sample = winairplay_shared::audio::f32_to_i16(phase.sin() * amplitude);
            for _ in 0..2 {
                bytes.extend_from_slice(&sample.to_le_bytes());
            }
        }
        bytes
    }
}
