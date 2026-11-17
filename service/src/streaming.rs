//! Per-receiver WASAPI-to-RAOP streaming worker.

use std::fmt;
use std::net::{IpAddr, SocketAddr, SocketAddrV6};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use getrandom::getrandom;
use mdns_sd::InterfaceId;
use thiserror::Error;
use uuid::Uuid;
use winairplay_shared::audio::{AudioConverter, AudioError, AudioFormat};
use winairplay_shared::discovery::{ReceiverSnapshot, ServiceKind};
use winairplay_shared::raop::{
    MVP_CHANNELS, MVP_SAMPLE_RATE, RaopClientConfig, RaopError, RaopSession,
};
use winairplay_shared::receiver::ReceiverCapability;
use zeroize::Zeroize;

use crate::config::ServiceConfig;
use crate::endpoint::{EndpointError, EndpointSpec};
use crate::wasapi::{
    BoundedCaptureQueue, CaptureError, CaptureFormat, CaptureSampleKind, PacketMetadata,
    RenderEndpoint, WasapiLoopbackCapture, list_render_endpoints,
};

const ENDPOINT_POLL_INTERVAL: Duration = Duration::from_millis(100);
const ENDPOINT_ARRIVAL_TIMEOUT: Duration = Duration::from_secs(20);
const AUDIO_POLL_INTERVAL: Duration = Duration::from_millis(100);
const QPC_HUNDRED_NANOSECONDS_TO_NANOSECONDS: u64 = 100;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RaopFailurePolicy {
    Retry,
    AwaitTargetChange,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SessionCloseMode {
    Graceful,
    Abort,
}

#[derive(Clone, Eq, PartialEq)]
pub struct StreamTarget {
    pub receiver_id: String,
    pub display_name: String,
    pub container_id: Uuid,
    pub destinations: Vec<SocketAddr>,
    local_bind_ips: Vec<Option<IpAddr>>,
    perform_auth_setup: bool,
    pub capability: ReceiverCapability,
    pub password: Option<String>,
}

impl fmt::Debug for StreamTarget {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StreamTarget")
            .field("receiver_id", &self.receiver_id)
            .field("display_name", &self.display_name)
            .field("container_id", &self.container_id)
            .field("destinations", &self.destinations)
            .field("local_bind_ips", &self.local_bind_ips)
            .field("perform_auth_setup", &self.perform_auth_setup)
            .field("capability", &self.capability)
            .field("password_configured", &self.password.is_some())
            .finish()
    }
}

impl Drop for StreamTarget {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            password.zeroize();
        }
    }
}

impl StreamTarget {
    #[cfg(test)]
    pub fn from_snapshot(receiver: &ReceiverSnapshot) -> Result<Self, StreamingError> {
        Self::from_snapshot_with_password(receiver, None)
    }

    pub fn from_snapshot_with_password(
        receiver: &ReceiverSnapshot,
        password: Option<String>,
    ) -> Result<Self, StreamingError> {
        let password_required = match &receiver.capability {
            ReceiverCapability::SupportedClassicRaop {
                password_required, ..
            } => *password_required,
            ReceiverCapability::Unsupported { .. } => {
                return Err(StreamingError::UnsupportedReceiver(
                    receiver.identity.to_string(),
                ));
            }
        };
        let password = if password_required {
            Some(password.ok_or_else(|| {
                StreamingError::CredentialUnavailable(receiver.identity.to_string())
            })?)
        } else {
            None
        };
        let specification =
            EndpointSpec::new(receiver.identity.as_str(), receiver.display_name.as_str())?;
        let routes = select_receiver_routes(receiver);
        let destinations = routes.iter().map(|(remote, _)| *remote).collect::<Vec<_>>();
        let local_bind_ips = routes.iter().map(|(_, local)| *local).collect::<Vec<_>>();
        if destinations.is_empty() {
            return Err(StreamingError::NoUsableAddress {
                receiver_id: receiver.identity.to_string(),
            });
        }
        Ok(Self {
            receiver_id: receiver.identity.to_string(),
            display_name: receiver.display_name.clone(),
            container_id: specification.container_id,
            destinations,
            local_bind_ips,
            perform_auth_setup: receiver.observations.iter().any(|observation| {
                observation.key.service.kind == ServiceKind::Raop
                    && observation
                        .txt
                        .get("et")
                        .and_then(Option::as_deref)
                        .is_some_and(|value| value.split(',').any(|token| token.trim() == "4"))
            }),
            capability: receiver.capability.clone(),
            password,
        })
    }
}

fn select_receiver_routes(receiver: &ReceiverSnapshot) -> Vec<(SocketAddr, Option<IpAddr>)> {
    let mut candidates = receiver
        .observations
        .iter()
        .filter(|observation| observation.key.service.kind == ServiceKind::Raop)
        .flat_map(|observation| {
            observation.addresses.iter().map(move |address| {
                let socket = match address {
                    IpAddr::V4(address) => SocketAddr::new(IpAddr::V4(*address), observation.port),
                    IpAddr::V6(address) => SocketAddr::V6(SocketAddrV6::new(
                        *address,
                        observation.port,
                        0,
                        if address.is_unicast_link_local() {
                            observation.key.interface.index
                        } else {
                            0
                        },
                    )),
                };
                let interface = InterfaceId {
                    index: observation.key.interface.index,
                    name: observation.key.interface.name.clone(),
                };
                let mut local_addresses = interface
                    .get_addrs()
                    .into_iter()
                    .filter(|local| {
                        local.is_ipv4() == address.is_ipv4()
                            && !local.is_unspecified()
                            && !local.is_multicast()
                    })
                    .collect::<Vec<_>>();
                local_addresses.sort_unstable();
                (
                    address_priority(*address),
                    socket,
                    local_addresses.into_iter().next(),
                )
            })
        })
        .collect::<Vec<_>>();
    candidates.sort_unstable_by_key(|(priority, socket, local)| (*priority, *socket, *local));
    candidates.dedup();
    candidates
        .into_iter()
        .map(|(_, socket, local)| (socket, local))
        .collect()
}

const fn address_priority(address: IpAddr) -> u8 {
    match address {
        IpAddr::V4(_) => 0,
        IpAddr::V6(address) if !address.is_unicast_link_local() => 1,
        IpAddr::V6(_) => 2,
    }
}

#[derive(Clone, Copy, Debug)]
pub struct StreamRuntimeConfig {
    pub idle_disconnect: Duration,
    pub retry_initial: Duration,
    pub retry_max: Duration,
    pub capture_queue_packets: usize,
    pub rtsp_max_header_bytes: usize,
    pub raop_sync_latency_frames: u32,
}

impl From<&ServiceConfig> for StreamRuntimeConfig {
    fn from(config: &ServiceConfig) -> Self {
        Self {
            idle_disconnect: Duration::from_millis(config.idle_disconnect_ms),
            retry_initial: Duration::from_millis(config.retry_initial_ms),
            retry_max: Duration::from_millis(config.retry_max_ms),
            capture_queue_packets: config.capture_queue_packets,
            rtsp_max_header_bytes: config.rtsp_max_header_bytes,
            raop_sync_latency_frames: config
                .raop_sync_latency_frames()
                .expect("validated service latency must convert to frames"),
        }
    }
}

pub struct StreamWorker {
    target: StreamTarget,
    cancellation: Arc<AtomicBool>,
    thread: Option<JoinHandle<Result<(), StreamingError>>>,
}

impl StreamWorker {
    pub fn start(
        target: StreamTarget,
        config: StreamRuntimeConfig,
    ) -> Result<Self, StreamingError> {
        let cancellation = Arc::new(AtomicBool::new(false));
        let worker_cancellation = Arc::clone(&cancellation);
        let worker_target = target.clone();
        let receiver_id = target.receiver_id.clone();
        let thread = thread::Builder::new()
            .name(format!("winairplay-stream-{receiver_id}"))
            .spawn(move || run_stream(&worker_target, config, &worker_cancellation))
            .map_err(|source| StreamingError::ThreadStart {
                receiver_id,
                source,
            })?;
        Ok(Self {
            target,
            cancellation,
            thread: Some(thread),
        })
    }

    #[must_use]
    pub fn is_finished(&self) -> bool {
        self.thread.as_ref().is_none_or(JoinHandle::is_finished)
    }

    pub fn stop(mut self) -> Result<(), StreamingError> {
        self.stop_and_join()
    }

    fn stop_and_join(&mut self) -> Result<(), StreamingError> {
        self.cancellation.store(true, Ordering::Release);
        let Some(thread) = self.thread.take() else {
            return Ok(());
        };
        match thread.join() {
            Ok(result) => result,
            Err(_) => Err(StreamingError::ThreadPanicked {
                receiver_id: self.target.receiver_id.clone(),
            }),
        }
    }
}

impl Drop for StreamWorker {
    fn drop(&mut self) {
        if let Err(error) = self.stop_and_join() {
            tracing::error!(
                component = "stream",
                receiver_id = %self.target.receiver_id,
                operation = "stop",
                %error
            );
        }
    }
}

fn run_stream(
    target: &StreamTarget,
    config: StreamRuntimeConfig,
    cancellation: &AtomicBool,
) -> Result<(), StreamingError> {
    let endpoint_wait_started = Instant::now();
    let endpoint_id =
        match wait_for_endpoint(target.container_id, &target.receiver_id, cancellation) {
            Ok(endpoint_id) => endpoint_id,
            Err(StreamingError::Cancelled) => return Ok(()),
            Err(error) => return Err(error),
        };
    if cancellation.load(Ordering::Acquire) {
        return Ok(());
    }
    tracing::info!(
        component = "stream",
        receiver_id = %target.receiver_id,
        endpoint_arrival_ms = endpoint_wait_started.elapsed().as_millis(),
        "mapped audio endpoint became active"
    );
    let capture = WasapiLoopbackCapture::start(&endpoint_id, config.capture_queue_packets)?;
    let format = capture.format();
    let queue = capture.queue();
    tracing::info!(
        component = "capture",
        receiver_id = %target.receiver_id,
        sample_rate = format.sample_rate,
        channels = format.channels,
        bits_per_sample = format.bits_per_sample,
        queue_capacity_packets = queue.capacity(),
        "WASAPI loopback capture started"
    );
    let stream_result = pump_audio(target, config, cancellation, format, &queue);
    tracing::info!(
        component = "capture",
        receiver_id = %target.receiver_id,
        dropped_packets = queue.dropped_packets(),
        "WASAPI loopback capture stopped"
    );
    let capture_result = capture.stop().map_err(StreamingError::from);
    stream_result.and(capture_result)
}

#[derive(Debug, Default)]
struct CaptureTimeline {
    anchor: Option<(u64, Instant)>,
}

impl CaptureTimeline {
    fn captured_at(&mut self, metadata: PacketMetadata, observed_at: Instant) -> Instant {
        if !metadata.qpc_position_is_reliable() {
            return observed_at;
        }
        let Some((anchor_qpc, anchor_instant)) = self.anchor else {
            self.anchor = Some((metadata.qpc_position, observed_at));
            return observed_at;
        };
        let Some(delta_qpc) = metadata.qpc_position.checked_sub(anchor_qpc) else {
            self.anchor = Some((metadata.qpc_position, observed_at));
            return observed_at;
        };
        let Some(delta_nanoseconds) = delta_qpc.checked_mul(QPC_HUNDRED_NANOSECONDS_TO_NANOSECONDS)
        else {
            self.anchor = Some((metadata.qpc_position, observed_at));
            return observed_at;
        };
        let Some(captured_at) = anchor_instant.checked_add(Duration::from_nanos(delta_nanoseconds))
        else {
            self.anchor = Some((metadata.qpc_position, observed_at));
            return observed_at;
        };
        captured_at.min(observed_at)
    }
}

fn media_age_exceeds_latency(origin: Instant, latency_frames: u32) -> bool {
    let latency = Duration::from_secs_f64(f64::from(latency_frames) / f64::from(MVP_SAMPLE_RATE));
    origin.elapsed() >= latency
}

fn discard_stale_capture(
    target: &StreamTarget,
    queue: &BoundedCaptureQueue,
    reported_dropped_packets: &mut u64,
    latency_frames: u32,
    stage: &'static str,
) {
    let discarded = queue.discard_ready_packets();
    *reported_dropped_packets = queue.dropped_packets();
    tracing::warn!(
        component = "capture",
        receiver_id = %target.receiver_id,
        current_packet_discarded = true,
        queued_packets_discarded = discarded,
        latency_frames,
        stage,
        "discarded captured audio that was already older than the RAOP latency budget"
    );
}

fn recover_capture_discontinuity(
    target: &StreamTarget,
    config: StreamRuntimeConfig,
    queue: &BoundedCaptureQueue,
    metadata: PacketMetadata,
    captured_at: Instant,
    session: &mut Option<RaopSession>,
    reported_dropped_packets: &mut u64,
) -> bool {
    let dropped_packets = queue.dropped_packets();
    let newly_reported = dropped_packets.saturating_sub(*reported_dropped_packets);
    *reported_dropped_packets = dropped_packets;
    tracing::warn!(
        component = "capture",
        receiver_id = %target.receiver_id,
        newly_dropped_packets = newly_reported,
        total_dropped_packets = dropped_packets,
        packet_frames = metadata.frames,
        packet_flags = metadata.flags,
        device_position = metadata.device_position,
        qpc_position = metadata.qpc_position,
        "recovering a local capture discontinuity without an RTSP flush"
    );

    let effective_latency = session
        .as_ref()
        .map_or(config.raop_sync_latency_frames, |active| {
            active.receiver_latency_frames()
        });
    if media_age_exceeds_latency(captured_at, effective_latency) {
        if let Some(active) = session
            && let Err(error) = active.discard_pending_capture_audio()
        {
            tracing::warn!(
                component = "raop",
                receiver_id = %target.receiver_id,
                operation = "discard stale partial capture audio",
                %error
            );
            close_session(session, &target.receiver_id, SessionCloseMode::Graceful);
        }
        discard_stale_capture(
            target,
            queue,
            reported_dropped_packets,
            effective_latency,
            "discontinuity",
        );
        return false;
    }

    if let Some(active) = session
        && let Err(error) = active.recover_from_capture_discontinuity(captured_at)
    {
        tracing::warn!(
            component = "raop",
            receiver_id = %target.receiver_id,
            operation = "recover local capture discontinuity",
            %error
        );
        close_session(session, &target.receiver_id, SessionCloseMode::Graceful);
    }
    true
}

fn anchor_new_session(
    target: &StreamTarget,
    queue: &BoundedCaptureQueue,
    captured_at: Instant,
    session: &mut Option<RaopSession>,
    reported_dropped_packets: &mut u64,
) -> bool {
    let active = session
        .as_mut()
        .expect("successful connection publishes a session");
    let effective_latency = active.receiver_latency_frames();
    if media_age_exceeds_latency(captured_at, effective_latency) {
        discard_stale_capture(
            target,
            queue,
            reported_dropped_packets,
            effective_latency,
            "startup",
        );
        return false;
    }
    if let Err(error) = active.set_media_origin(captured_at) {
        tracing::warn!(
            component = "raop",
            receiver_id = %target.receiver_id,
            operation = "anchor startup media timeline",
            %error
        );
        close_session(session, &target.receiver_id, SessionCloseMode::Graceful);
        return false;
    }
    tracing::info!(
        component = "raop",
        receiver_id = %target.receiver_id,
        startup_backlog_ms = captured_at.elapsed().as_millis(),
        effective_sync_latency_frames = effective_latency,
        "anchored RAOP startup pacing to the WASAPI capture timeline"
    );
    true
}

fn pump_audio(
    target: &StreamTarget,
    config: StreamRuntimeConfig,
    cancellation: &AtomicBool,
    format: CaptureFormat,
    queue: &Arc<BoundedCaptureQueue>,
) -> Result<(), StreamingError> {
    let input_format = AudioFormat {
        sample_rate: format.sample_rate,
        channels: format.channels,
    };
    let output_format = AudioFormat {
        sample_rate: MVP_SAMPLE_RATE,
        channels: MVP_CHANNELS,
    };
    let mut converter = AudioConverter::new(input_format, output_format)?;
    let mut session: Option<RaopSession> = None;
    let mut last_non_silent: Option<Instant> = None;
    let mut retry = ConnectionRetryState::new(config.retry_initial);
    let mut capture_timeline = CaptureTimeline::default();
    let mut reported_dropped_packets = 0_u64;

    let result = (|| {
        while !cancellation.load(Ordering::Acquire) {
            match queue.pop_timeout(AUDIO_POLL_INTERVAL) {
                Ok(Some(packet)) => {
                    let metadata = packet.metadata();
                    let observed_at = Instant::now();
                    let captured_at = capture_timeline.captured_at(metadata, observed_at);
                    let samples = decode_capture_packet(format, packet.bytes())?;
                    drop(packet);
                    let non_silent = samples.iter().any(|sample| sample.unsigned_abs() > 1);
                    if non_silent {
                        last_non_silent = Some(observed_at);
                    }
                    let chunk = converter.process_i16(&samples, metadata.forced_discontinuity)?;

                    if chunk.discontinuity
                        && !recover_capture_discontinuity(
                            target,
                            config,
                            queue,
                            metadata,
                            captured_at,
                            &mut session,
                            &mut reported_dropped_packets,
                        )
                    {
                        continue;
                    }

                    let newly_connected =
                        maybe_connect(target, config, non_silent, &mut session, &mut retry)?;
                    if newly_connected
                        && !anchor_new_session(
                            target,
                            queue,
                            captured_at,
                            &mut session,
                            &mut reported_dropped_packets,
                        )
                    {
                        continue;
                    }
                    send_audio(target, config, &chunk.samples, &mut session, &mut retry)?;
                }
                Ok(None) => {}
                Err(CaptureError::QueueClosed(reason)) => {
                    return Err(StreamingError::CaptureClosed {
                        receiver_id: target.receiver_id.clone(),
                        reason,
                    });
                }
                Err(error) => return Err(error.into()),
            }

            if session.is_some()
                && last_non_silent.is_some_and(|last| last.elapsed() >= config.idle_disconnect)
            {
                close_session(
                    &mut session,
                    &target.receiver_id,
                    SessionCloseMode::Graceful,
                );
                last_non_silent = None;
            }
        }
        Ok(())
    })();

    close_session(
        &mut session,
        &target.receiver_id,
        SessionCloseMode::Graceful,
    );
    result
}

struct ConnectionRetryState {
    next_connect: Instant,
    delay: Duration,
    destination_index: usize,
}

impl ConnectionRetryState {
    fn new(initial_delay: Duration) -> Self {
        Self {
            next_connect: Instant::now(),
            delay: initial_delay,
            destination_index: 0,
        }
    }

    fn reset_delay(&mut self, initial_delay: Duration) {
        self.delay = initial_delay;
    }

    fn schedule(&mut self, maximum: Duration, destination_count: usize) {
        self.destination_index = next_destination_index(self.destination_index, destination_count);
        self.next_connect = Instant::now() + jittered_retry_delay(self.delay, maximum);
        self.delay = self.delay.saturating_mul(2).min(maximum);
    }
}

fn maybe_connect(
    target: &StreamTarget,
    config: StreamRuntimeConfig,
    non_silent: bool,
    session: &mut Option<RaopSession>,
    retry: &mut ConnectionRetryState,
) -> Result<bool, StreamingError> {
    if session.is_some() || !non_silent || Instant::now() < retry.next_connect {
        return Ok(false);
    }
    let destination = target
        .destinations
        .get(retry.destination_index)
        .copied()
        .ok_or_else(|| StreamingError::NoUsableAddress {
            receiver_id: target.receiver_id.clone(),
        })?;
    let local_bind_ip = target
        .local_bind_ips
        .get(retry.destination_index)
        .copied()
        .flatten();
    match connect_session(target, destination, local_bind_ip, config) {
        Ok(active) => {
            *session = Some(active);
            retry.reset_delay(config.retry_initial);
            Ok(true)
        }
        Err(error) => match raop_failure_policy(&error) {
            RaopFailurePolicy::Retry => {
                tracing::warn!(
                    component = "raop",
                    receiver_id = %target.receiver_id,
                    operation = "connect/start",
                    %destination,
                    recoverable = true,
                    %error
                );
                retry.schedule(config.retry_max, target.destinations.len());
                Ok(false)
            }
            RaopFailurePolicy::AwaitTargetChange => {
                tracing::error!(
                    component = "raop",
                    receiver_id = %target.receiver_id,
                    operation = "connect/start",
                    %destination,
                    recoverable = false,
                    %error,
                    "RAOP target rejected; retries are disabled until receiver or credential state changes"
                );
                Err(target_rejected(target, error))
            }
        },
    }
}

fn send_audio(
    target: &StreamTarget,
    config: StreamRuntimeConfig,
    samples: &[i16],
    session: &mut Option<RaopSession>,
    retry: &mut ConnectionRetryState,
) -> Result<(), StreamingError> {
    let Some(active) = session else {
        return Ok(());
    };
    let Err(error) = active.send_pcm_i16(samples) else {
        return Ok(());
    };
    let failure_policy = raop_failure_policy(&error);
    match failure_policy {
        RaopFailurePolicy::Retry => tracing::warn!(
            component = "raop",
            receiver_id = %target.receiver_id,
            operation = "send audio",
            recoverable = true,
            %error
        ),
        RaopFailurePolicy::AwaitTargetChange => tracing::error!(
            component = "raop",
            receiver_id = %target.receiver_id,
            operation = "send audio",
            recoverable = false,
            %error
        ),
    }
    close_session(session, &target.receiver_id, SessionCloseMode::Abort);
    match failure_policy {
        RaopFailurePolicy::Retry => {
            retry.schedule(config.retry_max, target.destinations.len());
            Ok(())
        }
        RaopFailurePolicy::AwaitTargetChange => Err(target_rejected(target, error)),
    }
}

fn target_rejected(target: &StreamTarget, source: RaopError) -> StreamingError {
    StreamingError::RaopTargetRejected {
        receiver_id: target.receiver_id.clone(),
        source,
    }
}

const fn next_destination_index(current: usize, destination_count: usize) -> usize {
    if destination_count <= 1 || current + 1 >= destination_count {
        0
    } else {
        current + 1
    }
}

const fn raop_failure_policy(error: &RaopError) -> RaopFailurePolicy {
    match error {
        RaopError::Compatibility(_)
        | RaopError::InvalidConfiguration(_)
        | RaopError::PasswordRequired
        | RaopError::UnsupportedAuthentication(_)
        | RaopError::AuthenticationRejected
        | RaopError::InvalidTransport(_) => RaopFailurePolicy::AwaitTargetChange,
        RaopError::RtspRejected { status, .. } => rtsp_rejection_policy(*status),
        RaopError::Io { .. }
        | RaopError::Timeout { .. }
        | RaopError::RetryExhausted { .. }
        | RaopError::Entropy(_)
        | RaopError::RtspParse(_)
        | RaopError::InvalidRtp(_)
        | RaopError::CSeqMismatch { .. }
        | RaopError::InvalidState { .. }
        | RaopError::IncompleteAudioFrame { .. } => RaopFailurePolicy::Retry,
    }
}

const fn rtsp_rejection_policy(status: u16) -> RaopFailurePolicy {
    match status {
        // Request timeout, rate limiting, and receiver resource pressure can
        // clear without a discovery/profile change.
        408 | 429 | 453 => RaopFailurePolicy::Retry,
        // Other client rejections describe a request, media profile, method,
        // or authorization decision that retrying unchanged cannot repair.
        400..=499 => RaopFailurePolicy::AwaitTargetChange,
        // Server failures and unknown/non-standard status classes remain
        // retryable because the receiver may recover independently.
        _ => RaopFailurePolicy::Retry,
    }
}

fn jittered_retry_delay(base: Duration, maximum: Duration) -> Duration {
    static FALLBACK_SEQUENCE: AtomicU32 = AtomicU32::new(0x9E37_79B9);
    let mut entropy = [0_u8; 4];
    let sample = match getrandom(&mut entropy) {
        Ok(()) => u32::from_ne_bytes(entropy),
        Err(error) => {
            let fallback = FALLBACK_SEQUENCE.fetch_add(0x9E37_79B9, Ordering::Relaxed);
            tracing::warn!(
                error = %error,
                "operating-system retry entropy unavailable; using bounded fallback sequence"
            );
            fallback
        }
    };
    jittered_retry_delay_from_sample(base, maximum, sample)
}

fn jittered_retry_delay_from_sample(base: Duration, maximum: Duration, sample: u32) -> Duration {
    // Uniformly select 80 through 120 percent. Millisecond precision matches
    // the centrally configured retry values and keeps arithmetic bounded.
    let percent = u128::from(80 + sample % 41);
    let millis = base.as_millis().saturating_mul(percent) / 100;
    Duration::from_millis(u64::try_from(millis).unwrap_or(u64::MAX)).min(maximum)
}

fn wait_for_endpoint(
    container_id: Uuid,
    receiver_id: &str,
    cancellation: &AtomicBool,
) -> Result<String, StreamingError> {
    let deadline = Instant::now() + ENDPOINT_ARRIVAL_TIMEOUT;
    loop {
        if cancellation.load(Ordering::Acquire) {
            return Err(StreamingError::Cancelled);
        }
        if let Some(endpoint) = list_render_endpoints()?
            .into_iter()
            .find(|endpoint| endpoint_matches(endpoint, container_id, receiver_id))
        {
            return Ok(endpoint.endpoint_id);
        }
        if Instant::now() >= deadline {
            return Err(StreamingError::EndpointArrivalTimedOut {
                container_id,
                receiver_id: receiver_id.to_owned(),
                timeout: ENDPOINT_ARRIVAL_TIMEOUT,
            });
        }
        thread::sleep(ENDPOINT_POLL_INTERVAL);
    }
}

fn endpoint_matches(endpoint: &RenderEndpoint, container_id: Uuid, receiver_id: &str) -> bool {
    endpoint.container_id == Some(container_id)
        && endpoint
            .receiver_id
            .as_deref()
            .is_none_or(|actual| actual == receiver_id)
}

fn connect_session(
    target: &StreamTarget,
    destination: SocketAddr,
    local_bind_ip: Option<IpAddr>,
    config: StreamRuntimeConfig,
) -> Result<RaopSession, RaopError> {
    let started = Instant::now();
    let mut client = RaopClientConfig::default();
    client.password.clone_from(&target.password);
    client.local_bind_ip = local_bind_ip;
    client.perform_auth_setup = target.perform_auth_setup;
    client.message_limits.max_header_bytes = config.rtsp_max_header_bytes;
    client.retry_delay = config.retry_initial;
    client.receiver_latency_frames = config.raop_sync_latency_frames;
    // The service owns cross-address retry and jitter. A failed socket
    // attempt must rotate to the next scoped discovery candidate instead of
    // retrying one stale address internally.
    client.max_connect_attempts = 1;
    let mut session = RaopSession::connect(destination, client)?;
    if let Err(error) = session.start() {
        if let Err(cleanup_error) = session.teardown() {
            tracing::warn!(
                component = "raop",
                receiver_id = %target.receiver_id,
                %destination,
                operation = "teardown failed startup",
                %cleanup_error
            );
        }
        return Err(error);
    }
    let effective_sync_latency_frames = session.receiver_latency_frames();
    tracing::info!(
        component = "raop",
        receiver_id = %target.receiver_id,
        %destination,
        startup_ms = started.elapsed().as_millis(),
        configured_sync_latency_frames = config.raop_sync_latency_frames,
        effective_sync_latency_frames,
        "RAOP session entered streaming state"
    );
    Ok(session)
}

fn close_session(
    session: &mut Option<RaopSession>,
    receiver_id: &str,
    close_mode: SessionCloseMode,
) {
    let Some(mut active) = session.take() else {
        return;
    };
    if close_mode == SessionCloseMode::Graceful
        && let Err(error) = active.finish_audio()
    {
        tracing::warn!(
            component = "raop",
            %receiver_id,
            operation = "finish audio",
            %error
        );
    }
    let stats = active.stats();
    if let Err(error) = active.teardown() {
        tracing::warn!(
            component = "raop",
            %receiver_id,
            operation = "teardown",
            %error
        );
    }
    tracing::info!(
        component = "raop",
        %receiver_id,
        audio_packets = stats.audio_packets,
        audio_frames = stats.audio_frames,
        retransmission_requests = stats.retransmission_requests,
        retransmitted_packets = stats.retransmitted_packets,
        retransmission_misses = stats.retransmission_misses,
        timing_responses = stats.timing_responses,
        sync_packets = stats.sync_packets,
        capture_discontinuities = stats.capture_discontinuities,
        graceful = close_mode == SessionCloseMode::Graceful,
        "RAOP session closed"
    );
}

fn decode_capture_packet(format: CaptureFormat, bytes: &[u8]) -> Result<Vec<i16>, StreamingError> {
    let bytes_per_sample = match format.sample_kind {
        CaptureSampleKind::SignedPcm16 => 2,
        CaptureSampleKind::Float32 => 4,
    };
    let expected_alignment = usize::from(format.channels)
        .checked_mul(bytes_per_sample)
        .ok_or_else(|| {
            StreamingError::InvalidCapturePacket("frame alignment overflow".to_owned())
        })?;
    if usize::from(format.block_align) != expected_alignment
        || !bytes.len().is_multiple_of(expected_alignment)
    {
        return Err(StreamingError::InvalidCapturePacket(format!(
            "{} bytes with block alignment {} and {} channels",
            bytes.len(),
            format.block_align,
            format.channels
        )));
    }

    match format.sample_kind {
        CaptureSampleKind::SignedPcm16 => Ok(bytes
            .chunks_exact(2)
            .map(|sample| i16::from_le_bytes([sample[0], sample[1]]))
            .collect()),
        CaptureSampleKind::Float32 => Ok(bytes
            .chunks_exact(4)
            .map(|sample| f32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]))
            .map(winairplay_shared::audio::f32_to_i16)
            .collect()),
    }
}

#[derive(Debug, Error)]
pub enum StreamingError {
    #[error(transparent)]
    Endpoint(#[from] EndpointError),
    #[error(transparent)]
    Capture(#[from] CaptureError),
    #[error(transparent)]
    Audio(#[from] AudioError),
    #[error("receiver {0} is not an implemented classic RAOP profile")]
    UnsupportedReceiver(String),
    #[error(
        "receiver {0} requires a password; no Windows-protected service credential is configured"
    )]
    CredentialUnavailable(String),
    #[error("receiver {receiver_id} has no usable resolved RAOP address")]
    NoUsableAddress { receiver_id: String },
    #[error("could not start stream worker for receiver {receiver_id}: {source}")]
    ThreadStart {
        receiver_id: String,
        #[source]
        source: std::io::Error,
    },
    #[error("stream worker panicked for receiver {receiver_id}")]
    ThreadPanicked { receiver_id: String },
    #[error(
        "endpoint for receiver {receiver_id} with container {container_id} did not appear within {timeout:?}"
    )]
    EndpointArrivalTimedOut {
        container_id: Uuid,
        receiver_id: String,
        timeout: Duration,
    },
    #[error("capture endpoint closed for receiver {receiver_id}: {reason}")]
    CaptureClosed { receiver_id: String, reason: String },
    #[error("captured packet is incompatible: {0}")]
    InvalidCapturePacket(String),
    #[error("receiver {receiver_id} rejected the current RAOP target/configuration: {source}")]
    RaopTargetRejected {
        receiver_id: String,
        #[source]
        source: RaopError,
    },
    #[error("stream worker was cancelled before endpoint arrival")]
    Cancelled,
}

impl StreamingError {
    #[must_use]
    pub(crate) const fn retry_requires_target_change(&self) -> bool {
        matches!(self, Self::RaopTargetRejected { .. })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, TcpListener, UdpSocket};

    use winairplay_shared::discovery::{
        DiscoveryObservation, InterfaceKey, ReceiverSnapshot, ServiceKind, TxtLimits,
    };
    use winairplay_shared::identity::ReceiverIdentity;
    use winairplay_shared::raop::{
        RtspMessageLimits, RtspResponse, read_rtsp_request, write_rtsp_response,
    };

    use crate::wasapi::RenderEndpoint;
    use winairplay_shared::receiver::{RaopTransport, ReceiverCapability, ReceiverState};

    use super::*;

    fn select_receiver_socket(receiver: &ReceiverSnapshot) -> Option<SocketAddr> {
        select_receiver_sockets(receiver).into_iter().next()
    }

    fn select_receiver_sockets(receiver: &ReceiverSnapshot) -> Vec<SocketAddr> {
        select_receiver_routes(receiver)
            .into_iter()
            .map(|(remote, _)| remote)
            .collect()
    }

    fn capture_format(sample_kind: CaptureSampleKind) -> CaptureFormat {
        CaptureFormat {
            format_tag: 1,
            channels: 2,
            sample_rate: 48_000,
            bits_per_sample: if sample_kind == CaptureSampleKind::Float32 {
                32
            } else {
                16
            },
            block_align: if sample_kind == CaptureSampleKind::Float32 {
                8
            } else {
                4
            },
            sample_kind,
        }
    }

    #[test]
    fn decodes_little_endian_i16() {
        let samples = decode_capture_packet(
            capture_format(CaptureSampleKind::SignedPcm16),
            &[0x34, 0x12, 0xcc, 0xff],
        )
        .unwrap();
        assert_eq!(samples, [0x1234, -52]);
    }

    #[test]
    fn converts_float_with_clipping() {
        let mut bytes = Vec::new();
        for sample in [-1.5_f32, 0.5, 1.5, f32::NAN] {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        let samples =
            decode_capture_packet(capture_format(CaptureSampleKind::Float32), &bytes).unwrap();
        assert_eq!(samples, [i16::MIN, 16_384, i16::MAX, 0]);
    }

    #[test]
    fn rejects_partial_frames() {
        let error = decode_capture_packet(capture_format(CaptureSampleKind::SignedPcm16), &[0, 1])
            .unwrap_err();
        assert!(matches!(error, StreamingError::InvalidCapturePacket(_)));
    }

    #[test]
    fn capture_timeline_preserves_wasapi_qpc_age_across_a_blocking_operation() {
        let mut timeline = CaptureTimeline::default();
        let observed_anchor = Instant::now();
        let first = timeline.captured_at(
            PacketMetadata {
                qpc_position: 1_000_000,
                ..PacketMetadata::default()
            },
            observed_anchor,
        );
        assert_eq!(first, observed_anchor);

        let observed_after_block = observed_anchor + Duration::from_millis(500);
        let second = timeline.captured_at(
            PacketMetadata {
                qpc_position: 3_000_000,
                ..PacketMetadata::default()
            },
            observed_after_block,
        );
        assert_eq!(second, observed_anchor + Duration::from_millis(200));
    }

    #[test]
    fn capture_timeline_falls_back_for_bad_or_regressed_qpc_positions() {
        use windows::Win32::Media::Audio::AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR;

        let timestamp_error = u32::try_from(AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR.0).unwrap();
        let mut timeline = CaptureTimeline::default();
        let observed_anchor = Instant::now();
        assert_eq!(
            timeline.captured_at(
                PacketMetadata {
                    qpc_position: 2_000_000,
                    ..PacketMetadata::default()
                },
                observed_anchor,
            ),
            observed_anchor
        );

        let unreliable_observation = observed_anchor + Duration::from_millis(400);
        assert_eq!(
            timeline.captured_at(
                PacketMetadata {
                    flags: timestamp_error,
                    qpc_position: 3_000_000,
                    ..PacketMetadata::default()
                },
                unreliable_observation,
            ),
            unreliable_observation
        );

        let regressed_observation = observed_anchor + Duration::from_millis(500);
        assert_eq!(
            timeline.captured_at(
                PacketMetadata {
                    qpc_position: 1_000_000,
                    ..PacketMetadata::default()
                },
                regressed_observation,
            ),
            regressed_observation
        );
        assert_eq!(
            timeline.captured_at(
                PacketMetadata {
                    qpc_position: 1_500_000,
                    ..PacketMetadata::default()
                },
                regressed_observation + Duration::from_millis(100),
            ),
            regressed_observation + Duration::from_millis(50)
        );
    }

    #[test]
    fn stale_media_is_bounded_by_the_effective_sync_latency() {
        let now = Instant::now();
        assert!(!media_age_exceeds_latency(
            now.checked_sub(Duration::from_millis(100)).unwrap(),
            22_050
        ));
        assert!(media_age_exceeds_latency(
            now.checked_sub(Duration::from_millis(600)).unwrap(),
            22_050
        ));
    }

    #[test]
    fn retry_jitter_is_bounded_and_capped() {
        let base = Duration::from_secs(10);
        let maximum = Duration::from_secs(11);
        assert_eq!(
            jittered_retry_delay_from_sample(base, maximum, 0),
            Duration::from_secs(8)
        );
        assert_eq!(jittered_retry_delay_from_sample(base, maximum, 40), maximum);
    }

    #[test]
    fn endpoint_mapping_uses_container_and_validates_present_receiver_identity() {
        let container_id = Uuid::parse_str("e267de4f-408e-4ec5-92eb-2ead2d55b6a6").unwrap();
        let endpoint = RenderEndpoint {
            endpoint_id: "endpoint".to_owned(),
            friendly_name: "Receiver".to_owned(),
            container_id: Some(container_id),
            receiver_id: Some("001122334455".to_owned()),
        };

        assert!(endpoint_matches(&endpoint, container_id, "001122334455"));
        assert!(!endpoint_matches(&endpoint, container_id, "AABBCCDDEEFF"));
    }

    #[test]
    fn endpoint_mapping_accepts_missing_private_receiver_property_with_exact_container() {
        let container_id = Uuid::parse_str("e267de4f-408e-4ec5-92eb-2ead2d55b6a6").unwrap();
        let endpoint = RenderEndpoint {
            endpoint_id: "endpoint".to_owned(),
            friendly_name: "Receiver".to_owned(),
            container_id: Some(container_id),
            receiver_id: None,
        };

        assert!(endpoint_matches(&endpoint, container_id, "001122334455"));
        assert!(!endpoint_matches(
            &endpoint,
            Uuid::parse_str("5d33ef40-5ff1-4d6d-8231-ab73921bf0ed").unwrap(),
            "001122334455"
        ));
    }

    #[test]
    fn endpoint_mapping_rejects_malformed_present_private_receiver_property() {
        let container_id = Uuid::parse_str("e267de4f-408e-4ec5-92eb-2ead2d55b6a6").unwrap();
        let endpoint = RenderEndpoint {
            endpoint_id: "endpoint".to_owned(),
            friendly_name: "receiver".to_owned(),
            container_id: Some(container_id),
            receiver_id: Some("<invalid>".to_owned()),
        };

        assert!(!endpoint_matches(&endpoint, container_id, "001122334455"));
    }

    #[test]
    fn authentication_and_profile_failures_wait_for_target_change() {
        use winairplay_shared::raop::CompatibilityError;

        let permanent = [
            RaopError::Compatibility(CompatibilityError::AirPlay2 {
                first_missing_operation: "pair verify",
            }),
            RaopError::InvalidConfiguration("unsupported local profile".to_owned()),
            RaopError::PasswordRequired,
            RaopError::UnsupportedAuthentication("Basic".to_owned()),
            RaopError::AuthenticationRejected,
            RaopError::InvalidTransport("TCP media only".to_owned()),
        ];
        for error in permanent {
            assert_eq!(
                raop_failure_policy(&error),
                RaopFailurePolicy::AwaitTargetChange,
                "{error}"
            );
        }

        let retryable = [
            RaopError::Timeout {
                operation: "RTSP read",
                timeout: Duration::from_secs(3),
            },
            RaopError::Entropy("test entropy failure".to_owned()),
        ];
        for error in retryable {
            assert_eq!(raop_failure_policy(&error), RaopFailurePolicy::Retry);
        }
    }

    #[test]
    fn permanent_rtsp_client_rejections_wait_for_target_change() {
        for status in [400, 403, 404, 415, 451, 455, 461, 499] {
            let error = RaopError::RtspRejected {
                method: "ANNOUNCE".to_owned(),
                status,
                reason: "rejected".to_owned(),
            };
            assert_eq!(
                raop_failure_policy(&error),
                RaopFailurePolicy::AwaitTargetChange,
                "RTSP status {status} must not be retried unchanged",
            );
        }
    }

    fn mock_streaming_session() -> (Option<RaopSession>, UdpSocket, JoinHandle<()>) {
        let audio = UdpSocket::bind("127.0.0.1:0").unwrap();
        let control = UdpSocket::bind("127.0.0.1:0").unwrap();
        let timing = UdpSocket::bind("127.0.0.1:0").unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let destination = listener.local_addr().unwrap();
        let transport = format!(
            "RTP/AVP/UDP;unicast;server_port={};control_port={};timing_port={}",
            audio.local_addr().unwrap().port(),
            control.local_addr().unwrap().port(),
            timing.local_addr().unwrap().port()
        );
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for expected_method in ["ANNOUNCE", "SETUP", "RECORD", "SET_PARAMETER", "TEARDOWN"] {
                let request = read_rtsp_request(&mut stream, RtspMessageLimits::default()).unwrap();
                assert_eq!(request.method, expected_method);
                let mut response = RtspResponse::new(200, "OK")
                    .with_header("CSeq", request.header("cseq").unwrap());
                if expected_method == "SETUP" {
                    response = response
                        .with_header("Session", "close-mode-test")
                        .with_header("Transport", &transport);
                }
                write_rtsp_response(&mut stream, &response).unwrap();
            }
        });

        let target = StreamTarget {
            receiver_id: "001122334455".to_owned(),
            display_name: "Close mode test".to_owned(),
            container_id: Uuid::nil(),
            destinations: vec![destination],
            local_bind_ips: vec![Some(IpAddr::V4(Ipv4Addr::LOCALHOST))],
            perform_auth_setup: false,
            capability: ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            },
            password: None,
        };
        let config = StreamRuntimeConfig::from(&ServiceConfig::default());
        let session = connect_session(
            &target,
            destination,
            Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
            config,
        )
        .unwrap();
        (Some(session), audio, server)
    }

    #[test]
    fn abort_close_does_not_emit_partial_audio_after_a_send_failure() {
        let (mut session, audio, server) = mock_streaming_session();
        session
            .as_mut()
            .unwrap()
            .send_pcm_i16(&[1_i16, -1_i16])
            .unwrap();

        close_session(&mut session, "001122334455", SessionCloseMode::Abort);

        audio
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let error = audio.recv(&mut [0_u8; 2_048]).unwrap_err();
        assert!(matches!(
            error.kind(),
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
        ));
        assert!(session.is_none());
        server.join().unwrap();
    }

    #[test]
    fn graceful_close_finishes_partial_audio_before_teardown() {
        let (mut session, audio, server) = mock_streaming_session();
        session
            .as_mut()
            .unwrap()
            .send_pcm_i16(&[1_i16, -1_i16])
            .unwrap();

        close_session(&mut session, "001122334455", SessionCloseMode::Graceful);

        audio
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let received = audio.recv(&mut [0_u8; 2_048]).unwrap();
        assert!(received > 12, "expected an RTP audio datagram");
        assert!(session.is_none());
        server.join().unwrap();
    }

    #[test]
    fn malformed_record_latency_is_torn_down_without_hiding_the_start_error() {
        let audio = UdpSocket::bind("127.0.0.1:0").unwrap();
        let control = UdpSocket::bind("127.0.0.1:0").unwrap();
        let timing = UdpSocket::bind("127.0.0.1:0").unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let destination = listener.local_addr().unwrap();
        let transport = format!(
            "RTP/AVP/UDP;unicast;server_port={};control_port={};timing_port={}",
            audio.local_addr().unwrap().port(),
            control.local_addr().unwrap().port(),
            timing.local_addr().unwrap().port()
        );
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for expected_method in ["ANNOUNCE", "SETUP", "RECORD", "TEARDOWN"] {
                let request = read_rtsp_request(&mut stream, RtspMessageLimits::default()).unwrap();
                assert_eq!(request.method, expected_method);
                let mut response = RtspResponse::new(200, "OK")
                    .with_header("CSeq", request.header("cseq").unwrap());
                if expected_method == "SETUP" {
                    response = response
                        .with_header("Session", "cleanup-test")
                        .with_header("Transport", &transport);
                } else if expected_method == "RECORD" {
                    response = response.with_header("Audio-Latency", "invalid");
                }
                write_rtsp_response(&mut stream, &response).unwrap();
            }
        });

        let target = StreamTarget {
            receiver_id: "001122334455".to_owned(),
            display_name: "Cleanup test".to_owned(),
            container_id: Uuid::nil(),
            destinations: vec![destination],
            local_bind_ips: vec![Some(IpAddr::V4(Ipv4Addr::LOCALHOST))],
            perform_auth_setup: false,
            capability: ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            },
            password: None,
        };
        let config = StreamRuntimeConfig::from(&ServiceConfig::default());
        let error = connect_session(
            &target,
            destination,
            Some(IpAddr::V4(Ipv4Addr::LOCALHOST)),
            config,
        )
        .unwrap_err();
        assert!(
            matches!(error, RaopError::InvalidTransport(ref detail) if detail.contains("Audio-Latency"))
        );
        server.join().unwrap();
    }

    #[test]
    fn transient_rtsp_rejections_remain_retryable() {
        for status in [408, 429, 453, 500, 503] {
            let error = RaopError::RtspRejected {
                method: "SETUP".to_owned(),
                status,
                reason: "temporarily unavailable".to_owned(),
            };
            assert_eq!(
                raop_failure_policy(&error),
                RaopFailurePolicy::Retry,
                "RTSP status {status} should remain retryable",
            );
        }
    }

    #[test]
    fn socket_selection_prefers_ipv4_and_scopes_link_local_ipv6() {
        let identity = ReceiverIdentity::parse("001122334455").unwrap();
        let observation = DiscoveryObservation::from_parts(
            ServiceKind::Raop,
            "001122334455@Receiver._raop._tcp.local.",
            "receiver.local.",
            7_000,
            InterfaceKey {
                index: 12,
                name: "Ethernet".to_owned(),
            },
            [
                IpAddr::V6("fe80::1".parse::<Ipv6Addr>().unwrap()),
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, 8)),
            ],
            [
                ("cn", Some(b"0".to_vec())),
                ("et", Some(b"0".to_vec())),
                ("tp", Some(b"UDP".to_vec())),
            ],
            TxtLimits::default(),
        )
        .unwrap();
        let snapshot = ReceiverSnapshot {
            identity,
            display_name: "Receiver".to_owned(),
            capability: ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            },
            state: ReceiverState::OnlineSupported,
            observations: vec![observation],
            last_seen_ms: 0,
            grace_deadline_ms: None,
        };
        assert_eq!(
            select_receiver_socket(&snapshot),
            Some(SocketAddr::new(
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, 8)),
                7_000
            ))
        );
        let candidates = select_receiver_sockets(&snapshot);
        assert_eq!(candidates.len(), 2);
        assert_eq!(
            candidates[0],
            SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 8)), 7_000)
        );
        assert_eq!(
            match candidates[1] {
                SocketAddr::V6(value) => value.scope_id(),
                SocketAddr::V4(_) => 0,
            },
            12
        );

        let mut ipv6_only = snapshot;
        ipv6_only.observations[0].addresses.retain(IpAddr::is_ipv6);
        let selected = select_receiver_socket(&ipv6_only).unwrap();
        assert_eq!(selected.port(), 7_000);
        assert_eq!(
            match selected {
                SocketAddr::V6(value) => value.scope_id(),
                SocketAddr::V4(_) => 0,
            },
            12
        );
    }

    #[test]
    fn connection_failures_rotate_all_candidates_then_wrap() {
        assert_eq!(next_destination_index(0, 3), 1);
        assert_eq!(next_destination_index(1, 3), 2);
        assert_eq!(next_destination_index(2, 3), 0);
        assert_eq!(next_destination_index(0, 1), 0);
    }

    #[test]
    fn retry_deadline_is_based_on_failure_completion_time() {
        let mut retry = ConnectionRetryState::new(Duration::from_millis(100));
        let failure_completed = Instant::now();
        retry.schedule(Duration::from_secs(1), 3);
        assert!(retry.next_connect >= failure_completed + Duration::from_millis(80));
        assert_eq!(retry.destination_index, 1);
        assert_eq!(retry.delay, Duration::from_millis(200));
    }

    #[test]
    fn password_receiver_is_not_given_a_misleading_stream_target() {
        let identity = ReceiverIdentity::parse("001122334455").unwrap();
        let snapshot = ReceiverSnapshot {
            identity,
            display_name: "Protected".to_owned(),
            capability: ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: true,
            },
            state: ReceiverState::OnlineSupported,
            observations: Vec::new(),
            last_seen_ms: 0,
            grace_deadline_ms: None,
        };
        assert!(matches!(
            StreamTarget::from_snapshot(&snapshot),
            Err(StreamingError::CredentialUnavailable(_))
        ));
        let mut with_address = snapshot;
        with_address.observations.push(
            DiscoveryObservation::from_parts(
                ServiceKind::Raop,
                "001122334455@Protected._raop._tcp.local.",
                "protected.local.",
                7_000,
                InterfaceKey {
                    index: 4,
                    name: "Ethernet".to_owned(),
                },
                [IpAddr::V4(Ipv4Addr::LOCALHOST)],
                [
                    ("cn", Some(b"0".to_vec())),
                    ("et", Some(b"0".to_vec())),
                    ("tp", Some(b"UDP".to_vec())),
                    ("pw", Some(b"true".to_vec())),
                ],
                TxtLimits::default(),
            )
            .unwrap(),
        );
        let target =
            StreamTarget::from_snapshot_with_password(&with_address, Some("secret".to_owned()))
                .unwrap();
        assert_eq!(target.password.as_deref(), Some("secret"));
        assert_eq!(
            target.destinations,
            [SocketAddr::from(([127, 0, 0, 1], 7_000))]
        );
        let changed = StreamTarget::from_snapshot_with_password(
            &with_address,
            Some("changed-secret".to_owned()),
        )
        .unwrap();
        assert_ne!(target, changed);
        let debug = format!("{target:?}");
        assert!(debug.contains("password_configured: true"));
        assert!(!debug.contains("secret"));
    }
}
