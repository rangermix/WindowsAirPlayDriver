use std::fmt;
use std::io::{self, BufReader};
use std::net::{IpAddr, Ipv6Addr, SocketAddr, SocketAddrV6, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use getrandom::getrandom;
use socket2::{Domain, Protocol, Socket, Type};
use x25519_dalek::{X25519_BASEPOINT_BYTES, x25519};
use zeroize::Zeroize;

use super::digest::{DigestAuthenticator, DigestChallenge};
use super::rtp::{PacketBacklog, RetransmissionRequest, RtpPacketizer, build_retransmission_reply};
use super::rtsp::{read_rtsp_response, write_rtsp_request};
use super::{
    MVP_CHANNELS, MVP_SAMPLE_RATE, RaopClientConfig, RaopError, RtspResponse, map_io_error,
};

const MAX_CONTROL_DATAGRAMS_PER_POLL: usize = 64;
const MAX_RETRANSMISSIONS_PER_REQUEST: u16 = 128;
const MAX_RECEIVER_LATENCY_FRAMES: u32 = MVP_SAMPLE_RATE * 10;
const UDP_SEND_RETRY_INTERVAL: Duration = Duration::from_millis(1);

/// Current lifecycle of one synchronous RAOP connection.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionState {
    /// TCP and UDP sockets exist, but RTSP setup has not started.
    Connected,
    /// ANNOUNCE succeeded.
    Announced,
    /// SETUP succeeded and receiver UDP ports are known.
    Setup,
    /// RECORD succeeded and the receiver is ready for audio.
    Streaming,
    /// TEARDOWN was attempted and resources are being released.
    Closed,
}

impl SessionState {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Connected => "Connected",
            Self::Announced => "Announced",
            Self::Setup => "Setup",
            Self::Streaming => "Streaming",
            Self::Closed => "Closed",
        }
    }
}

/// Observable bounded sender counters.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RaopStats {
    /// Original RTP audio datagrams sent.
    pub audio_packets: u64,
    /// Audio frames sent.
    pub audio_frames: u64,
    /// Valid retransmission requests received.
    pub retransmission_requests: u64,
    /// Retained packets retransmitted.
    pub retransmitted_packets: u64,
    /// Requested packets no longer present in the bounded backlog.
    pub retransmission_misses: u64,
    /// Valid timing requests answered.
    pub timing_responses: u64,
    /// Periodic sync datagrams sent.
    pub sync_packets: u64,
    /// Local capture discontinuities recovered without a remote RTSP flush.
    pub capture_discontinuities: u64,
}

#[derive(Clone, Copy, Debug)]
struct ReceiverUdpPorts {
    audio: u16,
    control: u16,
}

/// A synchronous classic RAOP session.
///
/// Calls intentionally apply backpressure to their caller: at most one partial
/// packet and a fixed retransmission backlog are retained in memory.
pub struct RaopSession {
    config: RaopClientConfig,
    receiver: SocketAddr,
    rtsp: RtspClient,
    state: SessionState,
    session_header: Option<String>,
    audio_socket: UdpSocket,
    control_socket: UdpSocket,
    timing_socket: UdpSocket,
    receiver_ports: Option<ReceiverUdpPorts>,
    packetizer: RtpPacketizer,
    session_id: u32,
    backlog: PacketBacklog,
    pending_samples: Vec<i16>,
    stats: RaopStats,
    pacing_origin: Option<Instant>,
    pacing_frames: u64,
    first_sync: bool,
    last_sync: Option<Instant>,
}

impl fmt::Debug for RaopSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RaopSession")
            .field("config", &self.config)
            .field("receiver", &self.receiver)
            .field("state", &self.state)
            .field("receiver_ports", &self.receiver_ports)
            .field("stats", &self.stats)
            .field("pending_sample_count", &self.pending_samples.len())
            .finish_non_exhaustive()
    }
}

impl Drop for RaopSession {
    fn drop(&mut self) {
        if let Some(session_header) = &mut self.session_header {
            session_header.zeroize();
        }
        self.pending_samples.zeroize();
    }
}

impl RaopSession {
    /// Connects with bounded retries after validating receiver compatibility.
    pub fn connect(receiver: SocketAddr, config: RaopClientConfig) -> Result<Self, RaopError> {
        config.validate()?;
        if config
            .local_bind_ip
            .is_some_and(|local_ip| local_ip.is_ipv4() != receiver.is_ipv4())
        {
            return Err(RaopError::InvalidConfiguration(format!(
                "local_bind_ip and receiver must use the same address family: {:?} and {receiver}",
                config.local_bind_ip
            )));
        }
        let stream = connect_with_retry(receiver, &config)?;
        stream
            .set_read_timeout(Some(config.io_timeout))
            .map_err(|source| map_io_error("set RTSP read timeout", config.io_timeout, source))?;
        stream
            .set_write_timeout(Some(config.io_timeout))
            .map_err(|source| map_io_error("set RTSP write timeout", config.io_timeout, source))?;
        stream.set_nodelay(true).map_err(|source| {
            map_io_error("configure RTSP TCP_NODELAY", config.io_timeout, source)
        })?;

        let local_ip = stream
            .local_addr()
            .map_err(|source| map_io_error("read local RTSP address", config.io_timeout, source))?
            .ip();
        let audio_socket = bind_udp(local_ip, "bind RTP audio socket")?;
        let control_socket = bind_udp(local_ip, "bind RTP control socket")?;
        let timing_socket = bind_udp(local_ip, "bind RTP timing socket")?;
        let mut random = [0_u8; 16];
        getrandom(&mut random).map_err(|error| RaopError::Entropy(error.to_string()))?;
        let initial_sequence = config
            .initial_sequence
            .unwrap_or_else(|| u16::from_ne_bytes([random[0], random[1]]));
        let initial_timestamp = config
            .initial_timestamp
            .unwrap_or_else(|| u32::from_ne_bytes([random[4], random[5], random[6], random[7]]));
        let ssrc = config
            .ssrc
            .unwrap_or_else(|| u32::from_ne_bytes([random[8], random[9], random[10], random[11]]));
        let session_id = u32::from_ne_bytes([random[12], random[13], random[14], random[15]]);
        let uri = format!("rtsp://{local_ip}/{session_id}");
        let client_instance =
            u64::from_ne_bytes(random[0..8].try_into().expect("fixed-size slice"));
        let active_remote = u32::from_ne_bytes(random[8..12].try_into().expect("fixed-size slice"));
        let client_identifier = uuid::Uuid::from_bytes(random).to_string();
        let rtsp = RtspClient::new(
            stream,
            uri,
            &config,
            client_instance,
            active_remote,
            client_identifier,
        )?;
        let pending_capacity = config
            .frames_per_packet
            .checked_mul(usize::from(MVP_CHANNELS))
            .ok_or_else(|| {
                RaopError::InvalidConfiguration("audio packet sample capacity overflow".to_owned())
            })?;

        Ok(Self {
            packetizer: RtpPacketizer::new(initial_sequence, initial_timestamp, ssrc),
            session_id,
            backlog: PacketBacklog::new(config.retransmit_backlog_packets),
            pending_samples: Vec::with_capacity(pending_capacity),
            config,
            receiver,
            rtsp,
            state: SessionState::Connected,
            session_header: None,
            audio_socket,
            control_socket,
            timing_socket,
            receiver_ports: None,
            stats: RaopStats::default(),
            pacing_origin: None,
            pacing_frames: 0,
            first_sync: true,
            last_sync: None,
        })
    }

    /// Performs `ANNOUNCE`, `SETUP`, and `RECORD`.
    #[allow(clippy::too_many_lines)]
    pub fn start(&mut self) -> Result<(), RaopError> {
        self.require_state("start", SessionState::Connected)?;
        if self.config.perform_auth_setup {
            self.perform_auth_setup()?;
        }
        let local_ip = self.rtsp.local_ip();
        let sdp = build_pcm_sdp(self.session_id, local_ip, self.receiver.ip());
        self.rtsp.request(
            "ANNOUNCE",
            &[("Content-Type".to_owned(), "application/sdp".to_owned())],
            sdp.as_bytes(),
        )?;
        self.state = SessionState::Announced;

        let control_port = self
            .control_socket
            .local_addr()
            .map_err(|source| {
                map_io_error(
                    "read RTP control socket address",
                    self.config.io_timeout,
                    source,
                )
            })?
            .port();
        let timing_port = self
            .timing_socket
            .local_addr()
            .map_err(|source| {
                map_io_error(
                    "read RTP timing socket address",
                    self.config.io_timeout,
                    source,
                )
            })?
            .port();
        let setup_headers = [(
            "Transport".to_owned(),
            format!(
                "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port={control_port};timing_port={timing_port}"
            ),
        )];
        let timing_socket = self
            .timing_socket
            .try_clone()
            .map_err(|source| RaopError::Io {
                operation: "clone RAOP setup timing socket",
                source,
            })?;
        let receiver_ip = self.receiver.ip();
        let done = AtomicBool::new(false);
        let (setup, setup_timing_responses) = thread::scope(|scope| {
            let worker = scope.spawn(|| {
                let mut responses = 0_u64;
                let mut buffer = [0_u8; 2_048];
                while !done.load(Ordering::Acquire) {
                    match timing_socket.recv_from(&mut buffer) {
                        Ok((length, source)) => {
                            if source.ip() != receiver_ip {
                                continue;
                            }
                            let Some(response) = build_timing_response(&buffer[..length]) else {
                                continue;
                            };
                            timing_socket.send_to(&response, source).map_err(|source| {
                                RaopError::Io {
                                    operation: "send RAOP setup timing response",
                                    source,
                                }
                            })?;
                            responses = responses.saturating_add(1);
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(1));
                        }
                        Err(source) => {
                            return Err(RaopError::Io {
                                operation: "receive RAOP setup timing request",
                                source,
                            });
                        }
                    }
                }
                Ok(responses)
            });
            let setup = self.rtsp.request("SETUP", &setup_headers, &[]);
            done.store(true, Ordering::Release);
            let timing_result = worker.join().map_err(|_| RaopError::Io {
                operation: "join RAOP setup timing responder",
                source: io::Error::other("timing responder panicked"),
            })?;
            Ok::<_, RaopError>((setup, timing_result?))
        })?;
        self.stats.timing_responses = self
            .stats
            .timing_responses
            .saturating_add(setup_timing_responses);
        let setup = setup?;
        let session = setup
            .header("session")
            .and_then(|value| value.split(';').next())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                RaopError::InvalidTransport("SETUP response omitted Session".to_owned())
            })?
            .to_owned();
        let transport = setup.header("transport").ok_or_else(|| {
            RaopError::InvalidTransport("SETUP response omitted Transport".to_owned())
        })?;
        self.receiver_ports = Some(parse_receiver_ports(transport)?);
        self.session_header = Some(session);
        self.state = SessionState::Setup;

        let session_header = self.session_header_value()?;
        let record = self.rtsp.request(
            "RECORD",
            &[
                ("Session".to_owned(), session_header.clone()),
                ("Range".to_owned(), "npt=0-".to_owned()),
                (
                    "RTP-Info".to_owned(),
                    format!(
                        "seq={};rtptime={}",
                        self.packetizer.next_sequence(),
                        self.packetizer.next_timestamp()
                    ),
                ),
            ],
            &[],
        )?;
        self.config.receiver_latency_frames = effective_receiver_latency(
            self.config.receiver_latency_frames,
            record.header("audio-latency"),
        )?;
        self.rtsp.request(
            "SET_PARAMETER",
            &[
                ("Session".to_owned(), session_header),
                ("Content-Type".to_owned(), "text/parameters".to_owned()),
            ],
            b"volume: -10.000000\r\n",
        )?;
        self.state = SessionState::Streaming;
        Ok(())
    }

    fn perform_auth_setup(&mut self) -> Result<(), RaopError> {
        let mut private_key = [0_u8; 32];
        getrandom(&mut private_key).map_err(|error| RaopError::Entropy(error.to_string()))?;
        let public_key = x25519(private_key, X25519_BASEPOINT_BYTES);
        private_key.zeroize();

        let mut request = [0_u8; 33];
        // Type 1 requests an unencrypted audio session. The exchange
        // authenticates the receiver; it does not encrypt the RTP payload.
        request[0] = 1;
        request[1..].copy_from_slice(&public_key);
        let response = self.rtsp.request_at(
            "POST",
            "/auth-setup",
            &[(
                "Content-Type".to_owned(),
                "application/octet-stream".to_owned(),
            )],
            &request,
        )?;
        if response.body.len() < 40 {
            return Err(RaopError::RtspParse(format!(
                "auth-setup response body is too short: {} bytes",
                response.body.len()
            )));
        }
        Ok(())
    }

    /// Sends any number of interleaved stereo samples with bounded buffering.
    ///
    /// Full packets are sent immediately. Fewer than one packet of samples are
    /// retained until the next call or [`Self::finish_audio`].
    pub fn send_pcm_i16(&mut self, samples: &[i16]) -> Result<(), RaopError> {
        self.require_state("send_pcm_i16", SessionState::Streaming)?;
        if !samples.len().is_multiple_of(usize::from(MVP_CHANNELS)) {
            return Err(RaopError::IncompleteAudioFrame {
                sample_count: samples.len(),
            });
        }
        let packet_samples = self.packet_sample_count()?;
        let mut remaining = samples;

        if !self.pending_samples.is_empty() {
            let needed = packet_samples - self.pending_samples.len();
            let copied = needed.min(remaining.len());
            self.pending_samples.extend_from_slice(&remaining[..copied]);
            remaining = &remaining[copied..];
            if self.pending_samples.len() == packet_samples {
                let packet = std::mem::replace(
                    &mut self.pending_samples,
                    Vec::with_capacity(packet_samples),
                );
                self.send_one_packet(&packet)?;
            }
        }
        while remaining.len() >= packet_samples {
            self.send_one_packet(&remaining[..packet_samples])?;
            remaining = &remaining[packet_samples..];
        }
        self.pending_samples.extend_from_slice(remaining);
        Ok(())
    }

    /// Sends a final partial packet and services bounded control traffic briefly.
    pub fn finish_audio(&mut self) -> Result<(), RaopError> {
        self.require_state("finish_audio", SessionState::Streaming)?;
        if !self.pending_samples.is_empty() {
            let samples = std::mem::take(&mut self.pending_samples);
            self.pending_samples = Vec::with_capacity(self.packet_sample_count()?);
            self.send_one_packet(&samples)?;
        }
        let deadline = Instant::now()
            .checked_add(self.config.post_stream_control_window)
            .unwrap_or_else(Instant::now);
        while Instant::now() < deadline {
            self.service_udp()?;
            thread::sleep(Duration::from_millis(2));
        }
        Ok(())
    }

    /// Discards locally queued audio, clears retransmission history, and sends
    /// a remote FLUSH at the current sequence/timestamp.
    pub fn flush(&mut self) -> Result<(), RaopError> {
        self.require_state("flush", SessionState::Streaming)?;
        self.pending_samples.clear();
        self.backlog.clear();
        self.packetizer.mark_next_packet();
        self.pacing_origin = None;
        self.pacing_frames = 0;
        self.first_sync = true;
        self.last_sync = None;
        self.send_flush_request()
    }

    /// Anchors the first RTP frame to the time its source audio was captured.
    ///
    /// Calling this after a synchronous RTSP startup lets the sender transmit
    /// the captured startup backlog in a bounded burst instead of permanently
    /// adding the setup duration to end-to-end latency.
    pub fn set_media_origin(&mut self, origin: Instant) -> Result<(), RaopError> {
        self.require_state("set_media_origin", SessionState::Streaming)?;
        self.reset_media_timeline(origin)
    }

    /// Recovers a local capture gap without purging the receiver's audio buffer.
    ///
    /// The next RTP packet is marked and preceded by an immediate first-sync
    /// packet. RTSP `FLUSH` remains reserved for an explicit remote stream reset.
    pub fn recover_from_capture_discontinuity(&mut self, origin: Instant) -> Result<(), RaopError> {
        self.require_state(
            "recover_from_capture_discontinuity",
            SessionState::Streaming,
        )?;
        self.discard_pending_capture_audio()?;
        self.packetizer.mark_next_packet();
        self.reset_media_timeline(origin)?;
        self.stats.capture_discontinuities = self.stats.capture_discontinuities.saturating_add(1);
        Ok(())
    }

    /// Drops a partial local RTP packet after capture audio is known to be lost.
    ///
    /// This performs no network I/O. The caller must still recover the media
    /// timeline before sending the first surviving complete packet.
    pub fn discard_pending_capture_audio(&mut self) -> Result<(), RaopError> {
        self.require_state("discard_pending_capture_audio", SessionState::Streaming)?;
        self.pending_samples.clear();
        Ok(())
    }

    /// Sends `TEARDOWN`. Repeated calls after closure are harmless.
    pub fn teardown(&mut self) -> Result<(), RaopError> {
        if self.state == SessionState::Closed {
            return Ok(());
        }
        let result = if let Some(session) = self.session_header.clone() {
            self.rtsp
                .request("TEARDOWN", &[("Session".to_owned(), session)], &[])
                .map(|_| ())
        } else {
            Ok(())
        };
        self.state = SessionState::Closed;
        self.pending_samples.clear();
        self.backlog.clear();
        result
    }

    /// Returns the current session state.
    #[must_use]
    pub const fn state(&self) -> SessionState {
        self.state
    }

    /// Returns current sender counters.
    #[must_use]
    pub const fn stats(&self) -> RaopStats {
        self.stats
    }

    /// Returns the effective sync offset after applying any receiver floor.
    #[must_use]
    pub const fn receiver_latency_frames(&self) -> u32 {
        self.config.receiver_latency_frames
    }

    fn reset_media_timeline(&mut self, origin: Instant) -> Result<(), RaopError> {
        let now = Instant::now();
        if now.checked_duration_since(origin).is_none() {
            return Err(RaopError::InvalidConfiguration(
                "media origin must not be in the future".to_owned(),
            ));
        }
        self.pacing_origin = Some(origin);
        self.pacing_frames = 0;
        self.first_sync = true;
        self.last_sync = None;
        Ok(())
    }

    fn send_flush_request(&mut self) -> Result<(), RaopError> {
        let session = self.session_header_value()?;
        self.rtsp.request(
            "FLUSH",
            &[
                ("Session".to_owned(), session),
                (
                    "RTP-Info".to_owned(),
                    format!(
                        "seq={};rtptime={}",
                        self.packetizer.next_sequence(),
                        self.packetizer.next_timestamp()
                    ),
                ),
            ],
            &[],
        )?;
        Ok(())
    }

    fn send_one_packet(&mut self, samples: &[i16]) -> Result<(), RaopError> {
        self.apply_pacing()?;
        self.send_sync_if_due()?;
        let mut next_packetizer = self.packetizer.clone();
        let packet = next_packetizer.packetize_stereo_i16(samples)?;
        let receiver_ports = self.receiver_ports.ok_or_else(|| {
            RaopError::InvalidTransport("receiver RTP ports are unavailable".to_owned())
        })?;
        let destination = with_port(self.receiver, receiver_ports.audio);
        let receiver_ip = self.receiver.ip();
        let audio_send_timeout = self.audio_send_timeout()?;
        let control_timeout = self.config.io_timeout;
        let bytes_sent = {
            let audio_socket = &self.audio_socket;
            let control_socket = &self.control_socket;
            let timing_socket = &self.timing_socket;
            let backlog = &self.backlog;
            let stats = &mut self.stats;
            send_datagram_with_deadline(
                &packet.bytes,
                "send RTP audio datagram",
                audio_send_timeout,
                |datagram| audio_socket.send_to(datagram, destination),
                || {
                    service_udp_traffic(
                        receiver_ip,
                        control_socket,
                        timing_socket,
                        backlog,
                        control_timeout,
                        stats,
                    )
                },
                Instant::now,
                thread::sleep,
            )?
        };
        debug_assert_eq!(bytes_sent, packet.bytes.len());
        self.packetizer = next_packetizer;
        self.stats.audio_packets = self.stats.audio_packets.saturating_add(1);
        self.stats.audio_frames = self
            .stats
            .audio_frames
            .saturating_add(u64::try_from(packet.frames).unwrap_or(u64::MAX));
        self.pacing_frames = self
            .pacing_frames
            .saturating_add(u64::try_from(packet.frames).unwrap_or(u64::MAX));
        self.backlog.insert(packet);
        self.service_udp()
    }

    fn audio_send_timeout(&self) -> Result<Duration, RaopError> {
        if !self.config.pace_audio {
            return Ok(self.config.io_timeout);
        }
        let origin = self.pacing_origin.ok_or_else(|| {
            RaopError::InvalidConfiguration(
                "paced audio send is missing its media timeline".to_owned(),
            )
        })?;
        remaining_audio_send_timeout(
            self.config.io_timeout,
            origin,
            self.pacing_frames,
            self.config.receiver_latency_frames,
            Instant::now(),
        )
        .ok_or(RaopError::Timeout {
            operation: "send RTP audio datagram",
            timeout: Duration::ZERO,
        })
    }

    fn apply_pacing(&mut self) -> Result<(), RaopError> {
        if !self.config.pace_audio {
            return Ok(());
        }
        if self.pacing_origin.is_none() {
            self.reset_media_timeline(Instant::now())?;
        }
        let origin = self
            .pacing_origin
            .expect("media timeline is initialized above");
        let target = frame_duration(self.pacing_frames);
        if let Some(wait) = target.checked_sub(origin.elapsed()) {
            self.service_udp()?;
            thread::sleep(wait);
        }
        Ok(())
    }

    fn send_sync_if_due(&mut self) -> Result<(), RaopError> {
        let now = Instant::now();
        if self
            .last_sync
            .is_some_and(|last| now.duration_since(last) < Duration::from_secs(1))
        {
            return Ok(());
        }
        let ports = self.receiver_ports.ok_or_else(|| {
            RaopError::InvalidTransport("receiver RTP ports are unavailable".to_owned())
        })?;
        let rtp_time = self.packetizer.next_timestamp();
        let without_latency = rtp_time.wrapping_sub(self.config.receiver_latency_frames);
        let media_time = self.pacing_origin.map_or_else(SystemTime::now, |origin| {
            media_system_time(
                SystemTime::now(),
                origin.elapsed(),
                frame_duration(self.pacing_frames),
            )
        });
        let (ntp_seconds, ntp_fraction) = ntp_at(media_time);
        let mut packet = Vec::with_capacity(20);
        packet.push(if self.first_sync { 0x90 } else { 0x80 });
        packet.push(0xD4);
        packet.extend_from_slice(&7_u16.to_be_bytes());
        packet.extend_from_slice(&without_latency.to_be_bytes());
        packet.extend_from_slice(&ntp_seconds.to_be_bytes());
        packet.extend_from_slice(&ntp_fraction.to_be_bytes());
        packet.extend_from_slice(&rtp_time.to_be_bytes());
        self.control_socket
            .send_to(&packet, with_port(self.receiver, ports.control))
            .map_err(|source| {
                map_io_error("send RAOP sync datagram", self.config.io_timeout, source)
            })?;
        self.first_sync = false;
        self.last_sync = Some(now);
        self.stats.sync_packets = self.stats.sync_packets.saturating_add(1);
        Ok(())
    }

    fn service_udp(&mut self) -> Result<(), RaopError> {
        service_udp_traffic(
            self.receiver.ip(),
            &self.control_socket,
            &self.timing_socket,
            &self.backlog,
            self.config.io_timeout,
            &mut self.stats,
        )
    }

    fn packet_sample_count(&self) -> Result<usize, RaopError> {
        self.config
            .frames_per_packet
            .checked_mul(usize::from(MVP_CHANNELS))
            .ok_or_else(|| {
                RaopError::InvalidConfiguration("audio packet sample count overflow".to_owned())
            })
    }

    fn session_header_value(&self) -> Result<String, RaopError> {
        self.session_header
            .clone()
            .ok_or_else(|| RaopError::InvalidTransport("RTSP Session is unavailable".to_owned()))
    }

    fn require_state(
        &self,
        operation: &'static str,
        required: SessionState,
    ) -> Result<(), RaopError> {
        if self.state == required {
            Ok(())
        } else {
            Err(RaopError::InvalidState {
                operation,
                state: self.state.as_str(),
            })
        }
    }
}

struct RtspClient {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
    uri: String,
    next_cseq: u32,
    limits: super::RtspMessageLimits,
    timeout: Duration,
    username: String,
    password: Option<String>,
    user_agent: String,
    digest: Option<DigestAuthenticator>,
    local_ip: IpAddr,
    client_instance: String,
    active_remote: u32,
    client_identifier: String,
}

impl fmt::Debug for RtspClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RtspClient")
            .field("uri", &self.uri)
            .field("next_cseq", &self.next_cseq)
            .field("limits", &self.limits)
            .field("timeout", &self.timeout)
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| "<redacted>"))
            .field("user_agent", &self.user_agent)
            .field("digest", &self.digest)
            .field("local_ip", &self.local_ip)
            .field("client_instance", &self.client_instance)
            .field("active_remote", &self.active_remote)
            .field("client_identifier", &self.client_identifier)
            .finish_non_exhaustive()
    }
}

impl Drop for RtspClient {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            password.zeroize();
        }
    }
}

impl RtspClient {
    fn new(
        stream: TcpStream,
        uri: String,
        config: &RaopClientConfig,
        client_instance: u64,
        active_remote: u32,
        client_identifier: String,
    ) -> Result<Self, RaopError> {
        let writer = stream
            .try_clone()
            .map_err(|source| map_io_error("clone RTSP stream", config.io_timeout, source))?;
        let local_ip = stream
            .local_addr()
            .map_err(|source| map_io_error("read local RTSP address", config.io_timeout, source))?
            .ip();
        Ok(Self {
            reader: BufReader::new(stream),
            writer,
            uri,
            next_cseq: 1,
            limits: config.message_limits,
            timeout: config.io_timeout,
            username: config.username.clone(),
            password: config.password.clone(),
            user_agent: config.user_agent.clone(),
            digest: None,
            local_ip,
            client_instance: format!("{client_instance:016X}"),
            active_remote,
            client_identifier,
        })
    }

    fn request(
        &mut self,
        method: &str,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Result<RtspResponse, RaopError> {
        let uri = self.uri.clone();
        self.request_at(method, &uri, headers, body)
    }

    fn request_at(
        &mut self,
        method: &str,
        uri: &str,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Result<RtspResponse, RaopError> {
        let response = self.request_once(method, uri, headers, body)?;
        if response.status == 401 {
            if self.digest.is_some() {
                return Err(RaopError::AuthenticationRejected);
            }
            let challenge = response.header("www-authenticate").ok_or_else(|| {
                RaopError::UnsupportedAuthentication(
                    "401 response omitted WWW-Authenticate".to_owned(),
                )
            })?;
            let challenge = DigestChallenge::parse(challenge)?;
            let password = self.password.clone().ok_or(RaopError::PasswordRequired)?;
            self.digest = Some(DigestAuthenticator::new(
                challenge,
                self.username.clone(),
                password,
            )?);
            let authenticated = self.request_once(method, uri, headers, body)?;
            if authenticated.status == 401 {
                return Err(RaopError::AuthenticationRejected);
            }
            return ensure_success(method, authenticated);
        }
        ensure_success(method, response)
    }

    fn request_once(
        &mut self,
        method: &str,
        uri: &str,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Result<RtspResponse, RaopError> {
        let cseq = self.next_cseq;
        self.next_cseq = self.next_cseq.wrapping_add(1).max(1);
        let mut all_headers = Vec::with_capacity(headers.len() + 7);
        all_headers.push(("CSeq".to_owned(), cseq.to_string()));
        all_headers.push(("User-Agent".to_owned(), self.user_agent.clone()));
        all_headers.push(("DACP-ID".to_owned(), self.client_instance.clone()));
        all_headers.push(("Client-Instance".to_owned(), self.client_instance.clone()));
        all_headers.push(("Active-Remote".to_owned(), self.active_remote.to_string()));
        all_headers.push((
            "Client-instance-identifier".to_owned(),
            self.client_identifier.clone(),
        ));
        all_headers.extend_from_slice(headers);
        if let Some(digest) = self.digest.as_mut() {
            all_headers.push((
                "Authorization".to_owned(),
                digest.authorization(method, uri),
            ));
        }
        let diagnostic_headers = all_headers
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str(),
                    if name.eq_ignore_ascii_case("authorization") {
                        "<redacted>"
                    } else {
                        value.as_str()
                    },
                )
            })
            .collect::<Vec<_>>();
        tracing::debug!(
            target: "winairplay_shared::raop::wire",
            direction = "request",
            method,
            uri,
            headers = ?diagnostic_headers,
            body_bytes = body.len(),
            "sending RTSP request"
        );
        write_rtsp_request(&mut self.writer, method, uri, &all_headers, body)
            .map_err(|source| map_io_error("write RTSP request", self.timeout, source))?;
        let response = read_rtsp_response(&mut self.reader, self.limits).map_err(|source| {
            if source.kind() == io::ErrorKind::InvalidData {
                RaopError::RtspParse(source.to_string())
            } else {
                map_io_error("read RTSP response", self.timeout, source)
            }
        })?;
        tracing::debug!(
            target: "winairplay_shared::raop::wire",
            direction = "response",
            method,
            status = response.status,
            reason = %response.reason,
            headers = ?response.headers,
            body_bytes = response.body.len(),
            "received RTSP response"
        );
        let actual_cseq = response.header("cseq").unwrap_or("<missing>");
        if actual_cseq != cseq.to_string() {
            return Err(RaopError::CSeqMismatch {
                method: method.to_owned(),
                expected: cseq,
                actual: actual_cseq.to_owned(),
            });
        }
        Ok(response)
    }

    fn local_ip(&self) -> IpAddr {
        self.local_ip
    }
}

fn ensure_success(method: &str, response: RtspResponse) -> Result<RtspResponse, RaopError> {
    if (200..300).contains(&response.status) {
        Ok(response)
    } else {
        Err(RaopError::RtspRejected {
            method: method.to_owned(),
            status: response.status,
            reason: response.reason,
        })
    }
}

fn connect_with_retry(
    receiver: SocketAddr,
    config: &RaopClientConfig,
) -> Result<TcpStream, RaopError> {
    retry_operation(config.max_connect_attempts, config.retry_delay, || {
        connect_once(receiver, config.local_bind_ip, config.connect_timeout)
    })
    .map_err(|(attempts, error)| RaopError::RetryExhausted {
        attempts,
        last_error: error.to_string(),
    })
}

fn connect_once(
    receiver: SocketAddr,
    local_bind_ip: Option<IpAddr>,
    timeout: Duration,
) -> io::Result<TcpStream> {
    let Some(local_bind_ip) = local_bind_ip else {
        return TcpStream::connect_timeout(&receiver, timeout);
    };
    let socket = Socket::new(
        Domain::for_address(receiver),
        Type::STREAM,
        Some(Protocol::TCP),
    )?;
    let local_scope_id = match (local_bind_ip, receiver) {
        (IpAddr::V6(local), SocketAddr::V6(remote))
            if is_unicast_link_local(local) || is_unicast_link_local(*remote.ip()) =>
        {
            remote.scope_id()
        }
        _ => 0,
    };
    let local = match local_bind_ip {
        IpAddr::V4(address) => SocketAddr::new(IpAddr::V4(address), 0),
        IpAddr::V6(address) => SocketAddr::V6(SocketAddrV6::new(address, 0, 0, local_scope_id)),
    };
    socket.bind(&local.into())?;
    socket.connect_timeout(&receiver.into(), timeout)?;
    Ok(socket.into())
}

const fn is_unicast_link_local(address: Ipv6Addr) -> bool {
    (address.segments()[0] & 0xffc0) == 0xfe80
}

fn retry_operation<T, F>(
    max_attempts: u32,
    delay: Duration,
    mut operation: F,
) -> Result<T, (u32, io::Error)>
where
    F: FnMut() -> io::Result<T>,
{
    let mut last_error = None;
    for attempt in 1..=max_attempts {
        match operation() {
            Ok(value) => return Ok(value),
            Err(error) => last_error = Some(error),
        }
        if attempt < max_attempts {
            thread::sleep(delay);
        }
    }
    Err((
        max_attempts,
        last_error.unwrap_or_else(|| io::Error::other("no connection attempt was made")),
    ))
}

fn bind_udp(local_ip: IpAddr, operation: &'static str) -> Result<UdpSocket, RaopError> {
    let socket = UdpSocket::bind(SocketAddr::new(local_ip, 0))
        .map_err(|source| RaopError::Io { operation, source })?;
    socket
        .set_nonblocking(true)
        .map_err(|source| RaopError::Io {
            operation: "configure UDP socket nonblocking mode",
            source,
        })?;
    Ok(socket)
}

fn remaining_audio_send_timeout(
    configured_timeout: Duration,
    pacing_origin: Instant,
    pacing_frames: u64,
    receiver_latency_frames: u32,
    now: Instant,
) -> Option<Duration> {
    let playout_offset = frame_duration(pacing_frames)
        .saturating_add(frame_duration(u64::from(receiver_latency_frames)));
    let remaining = playout_offset.checked_sub(now.saturating_duration_since(pacing_origin))?;
    (!remaining.is_zero()).then(|| configured_timeout.min(remaining))
}

fn send_datagram_with_deadline<Send, Service, Now, Wait>(
    datagram: &[u8],
    operation: &'static str,
    timeout: Duration,
    mut try_send: Send,
    mut service_udp: Service,
    mut now: Now,
    mut wait: Wait,
) -> Result<usize, RaopError>
where
    Send: FnMut(&[u8]) -> io::Result<usize>,
    Service: FnMut() -> Result<(), RaopError>,
    Now: FnMut() -> Instant,
    Wait: FnMut(Duration),
{
    let started = now();
    let mut retrying = false;
    loop {
        if retrying && now().saturating_duration_since(started) >= timeout {
            return Err(RaopError::Timeout { operation, timeout });
        }
        match try_send(datagram) {
            Ok(bytes_sent) if bytes_sent == datagram.len() => return Ok(bytes_sent),
            Ok(bytes_sent) => {
                return Err(RaopError::Io {
                    operation,
                    source: io::Error::new(
                        io::ErrorKind::WriteZero,
                        format!("sent {bytes_sent} of {} bytes", datagram.len()),
                    ),
                });
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::Interrupted
                        | io::ErrorKind::TimedOut
                ) => {}
            Err(source) => return Err(map_io_error(operation, timeout, source)),
        }

        if now().saturating_duration_since(started) >= timeout {
            return Err(RaopError::Timeout { operation, timeout });
        }
        service_udp()?;
        let elapsed = now().saturating_duration_since(started);
        if elapsed >= timeout {
            return Err(RaopError::Timeout { operation, timeout });
        }
        wait(UDP_SEND_RETRY_INTERVAL.min(timeout.saturating_sub(elapsed)));
        retrying = true;
    }
}

fn service_udp_traffic(
    receiver_ip: IpAddr,
    control_socket: &UdpSocket,
    timing_socket: &UdpSocket,
    backlog: &PacketBacklog,
    timeout: Duration,
    stats: &mut RaopStats,
) -> Result<(), RaopError> {
    let control = receive_available(control_socket)?;
    for (packet, source) in control {
        if source.ip() != receiver_ip || packet.get(1).map(|value| value & 0x7F) != Some(0x55) {
            continue;
        }
        let Ok(request) = RetransmissionRequest::parse(&packet) else {
            continue;
        };
        stats.retransmission_requests = stats.retransmission_requests.saturating_add(1);
        let count = request.packet_count.min(MAX_RETRANSMISSIONS_PER_REQUEST);
        for offset in 0..count {
            let sequence = request.first_missing_sequence.wrapping_add(offset);
            if let Some(original) = backlog.get(sequence) {
                let reply = build_retransmission_reply(original);
                control_socket.send_to(&reply, source).map_err(|error| {
                    map_io_error("send RAOP retransmission datagram", timeout, error)
                })?;
                stats.retransmitted_packets = stats.retransmitted_packets.saturating_add(1);
            } else {
                stats.retransmission_misses = stats.retransmission_misses.saturating_add(1);
            }
        }
    }

    let timing = receive_available(timing_socket)?;
    for (request, source) in timing {
        if source.ip() != receiver_ip {
            continue;
        }
        let Some(response) = build_timing_response(&request) else {
            continue;
        };
        timing_socket
            .send_to(&response, source)
            .map_err(|error| map_io_error("send RAOP timing response", timeout, error))?;
        stats.timing_responses = stats.timing_responses.saturating_add(1);
    }
    Ok(())
}

fn build_timing_response(request: &[u8]) -> Option<[u8; 32]> {
    if request.len() != 32 || request[0] >> 6 != 2 || request[1] & 0x7F != 0x52 {
        return None;
    }
    let (seconds, fraction) = ntp_now();
    let mut response = [0_u8; 32];
    response[0] = request[0];
    response[1] = 0xD3;
    response[2..4].copy_from_slice(&7_u16.to_be_bytes());
    response[8..16].copy_from_slice(&request[24..32]);
    response[16..20].copy_from_slice(&seconds.to_be_bytes());
    response[20..24].copy_from_slice(&fraction.to_be_bytes());
    response[24..28].copy_from_slice(&seconds.to_be_bytes());
    response[28..32].copy_from_slice(&fraction.to_be_bytes());
    Some(response)
}

fn receive_available(socket: &UdpSocket) -> Result<Vec<(Vec<u8>, SocketAddr)>, RaopError> {
    let mut datagrams = Vec::new();
    for _ in 0..MAX_CONTROL_DATAGRAMS_PER_POLL {
        let mut buffer = [0_u8; 2_048];
        match socket.recv_from(&mut buffer) {
            Ok((length, source)) => datagrams.push((buffer[..length].to_vec(), source)),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(source) => {
                return Err(RaopError::Io {
                    operation: "receive RAOP UDP control datagram",
                    source,
                });
            }
        }
    }
    Ok(datagrams)
}

fn build_pcm_sdp(session_id: u32, local_ip: IpAddr, receiver_ip: IpAddr) -> String {
    let origin_family = if local_ip.is_ipv4() { "IP4" } else { "IP6" };
    let connection_family = if receiver_ip.is_ipv4() { "IP4" } else { "IP6" };
    format!(
        "v=0\r\n\
         o=WinAirPlayAudio {session_id} 0 IN {origin_family} {local_ip}\r\n\
         s=WinAirPlayAudio\r\n\
         i=WinAirPlayAudio\r\n\
         c=IN {connection_family} {receiver_ip}\r\n\
         t=0 0\r\n\
         m=audio 0 RTP/AVP 96\r\n\
         a=rtpmap:96 L16/{MVP_SAMPLE_RATE}/{MVP_CHANNELS}\r\n"
    )
}

fn parse_receiver_ports(transport: &str) -> Result<ReceiverUdpPorts, RaopError> {
    let mut fields = transport.split(';');
    let protocol = fields.next().unwrap_or("").trim();
    if !protocol.eq_ignore_ascii_case("RTP/AVP/UDP") {
        return Err(RaopError::InvalidTransport(format!(
            "receiver selected {protocol:?}; expected RTP/AVP/UDP"
        )));
    }
    let mut audio = None;
    let mut control = None;
    let mut timing = None;
    for field in fields {
        let Some((name, value)) = field.trim().split_once('=') else {
            continue;
        };
        let port = value.trim().parse::<u16>().ok().filter(|port| *port != 0);
        match name.trim().to_ascii_lowercase().as_str() {
            "server_port" => audio = port,
            "control_port" => control = port,
            "timing_port" => timing = port,
            _ => {}
        }
    }
    let timing = timing
        .ok_or_else(|| RaopError::InvalidTransport("receiver omitted timing_port".to_owned()))?;
    debug_assert_ne!(timing, 0);
    Ok(ReceiverUdpPorts {
        audio: audio.ok_or_else(|| {
            RaopError::InvalidTransport("receiver omitted server_port".to_owned())
        })?,
        control: control.ok_or_else(|| {
            RaopError::InvalidTransport("receiver omitted control_port".to_owned())
        })?,
    })
}

fn effective_receiver_latency(
    configured_frames: u32,
    advertised: Option<&str>,
) -> Result<u32, RaopError> {
    let Some(advertised) = advertised else {
        return Ok(configured_frames);
    };
    let advertised_frames = advertised.trim().parse::<u32>().map_err(|_| {
        RaopError::InvalidTransport(format!(
            "RECORD response Audio-Latency {advertised:?} is not an unsigned frame count"
        ))
    })?;
    if !(1..=MAX_RECEIVER_LATENCY_FRAMES).contains(&advertised_frames) {
        return Err(RaopError::InvalidTransport(format!(
            "RECORD response Audio-Latency {advertised_frames} is outside 1..={MAX_RECEIVER_LATENCY_FRAMES}"
        )));
    }
    Ok(configured_frames.max(advertised_frames))
}

fn with_port(address: SocketAddr, port: u16) -> SocketAddr {
    match address {
        SocketAddr::V4(mut value) => {
            value.set_port(port);
            SocketAddr::V4(value)
        }
        SocketAddr::V6(mut value) => {
            value.set_port(port);
            SocketAddr::V6(value)
        }
    }
}

fn frame_duration(frames: u64) -> Duration {
    let whole_seconds = frames / u64::from(MVP_SAMPLE_RATE);
    let remaining_frames = frames % u64::from(MVP_SAMPLE_RATE);
    let nanoseconds = remaining_frames * 1_000_000_000 / u64::from(MVP_SAMPLE_RATE);
    Duration::from_secs(whole_seconds).saturating_add(Duration::from_nanos(nanoseconds))
}

fn media_system_time(
    wall_now: SystemTime,
    timeline_elapsed: Duration,
    media_elapsed: Duration,
) -> SystemTime {
    if let Some(lead) = media_elapsed.checked_sub(timeline_elapsed) {
        wall_now.checked_add(lead).unwrap_or(wall_now)
    } else {
        wall_now
            .checked_sub(timeline_elapsed.saturating_sub(media_elapsed))
            .unwrap_or(wall_now)
    }
}

#[allow(clippy::cast_possible_truncation)]
fn ntp_at(time: SystemTime) -> (u32, u32) {
    const NTP_UNIX_EPOCH_OFFSET: u64 = 2_208_988_800;
    let duration = time.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO);
    let seconds = duration.as_secs().wrapping_add(NTP_UNIX_EPOCH_OFFSET) as u32;
    let fraction = ((u64::from(duration.subsec_nanos()) << 32) / 1_000_000_000) as u32;
    (seconds, fraction)
}

fn ntp_now() -> (u32, u32) {
    ntp_at(SystemTime::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::io::Write;
    use std::net::TcpListener;
    use std::sync::{
        Arc,
        atomic::{AtomicU32, Ordering},
    };

    fn one_attempt_config() -> RaopClientConfig {
        let mut config = RaopClientConfig::default();
        config.max_connect_attempts = 1;
        config.connect_timeout = Duration::from_millis(100);
        config.io_timeout = Duration::from_millis(40);
        config.pace_audio = false;
        config
    }

    struct LocalRecoveryPeer {
        address: SocketAddr,
        audio: UdpSocket,
        control: UdpSocket,
        _timing: UdpSocket,
        server: thread::JoinHandle<()>,
    }

    fn local_recovery_peer() -> LocalRecoveryPeer {
        let audio = UdpSocket::bind("127.0.0.1:0").unwrap();
        let control = UdpSocket::bind("127.0.0.1:0").unwrap();
        let timing = UdpSocket::bind("127.0.0.1:0").unwrap();
        control
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        audio
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let transport = format!(
            "RTP/AVP/UDP;unicast;server_port={};control_port={};timing_port={}",
            audio.local_addr().unwrap().port(),
            control.local_addr().unwrap().port(),
            timing.local_addr().unwrap().port()
        );
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for expected_method in [
                "ANNOUNCE",
                "SETUP",
                "RECORD",
                "SET_PARAMETER",
                "FLUSH",
                "TEARDOWN",
            ] {
                let request = super::super::read_rtsp_request(
                    &mut stream,
                    super::super::RtspMessageLimits::default(),
                )
                .unwrap();
                assert_eq!(request.method, expected_method);
                let mut response = RtspResponse::new(200, "OK")
                    .with_header("CSeq", request.header("cseq").unwrap());
                if expected_method == "SETUP" {
                    response = response
                        .with_header("Session", "1")
                        .with_header("Transport", &transport);
                } else if expected_method == "RECORD" {
                    response = response.with_header("Audio-Latency", "44100");
                }
                super::super::write_rtsp_response(&mut stream, &response).unwrap();
            }
        });

        LocalRecoveryPeer {
            address,
            audio,
            control,
            _timing: timing,
            server,
        }
    }

    fn assert_sync_packet(
        control: &UdpSocket,
        expected_first: bool,
        expected_rtp_time: u32,
        latency_frames: u32,
        earliest_wall_time: SystemTime,
        latest_wall_time: SystemTime,
    ) {
        let mut sync = [0_u8; 20];
        control.recv_from(&mut sync).unwrap();
        assert_eq!(sync[0], if expected_first { 0x90 } else { 0x80 });
        assert_eq!(
            u32::from_be_bytes(sync[4..8].try_into().unwrap()),
            expected_rtp_time.wrapping_sub(latency_frames)
        );
        let actual_ntp = (
            u32::from_be_bytes(sync[8..12].try_into().unwrap()),
            u32::from_be_bytes(sync[12..16].try_into().unwrap()),
        );
        let flatten_ntp =
            |(seconds, fraction): (u32, u32)| u64::from(seconds) << 32 | u64::from(fraction);
        let first_bound = flatten_ntp(ntp_at(earliest_wall_time));
        let second_bound = flatten_ntp(ntp_at(latest_wall_time));
        let tolerance = (1_u64 << 32) / 1_000;
        let expected_range = first_bound.min(second_bound).saturating_sub(tolerance)
            ..=first_bound.max(second_bound).saturating_add(tolerance);
        let actual_ntp_flat = flatten_ntp(actual_ntp);
        assert!(
            expected_range.contains(&actual_ntp_flat),
            "sync NTP {actual_ntp:?} ({actual_ntp_flat}) was outside {expected_range:?}"
        );
        assert_eq!(
            u32::from_be_bytes(sync[16..20].try_into().unwrap()),
            expected_rtp_time
        );
    }

    fn receive_audio_datagram(audio: &UdpSocket) -> Vec<u8> {
        let mut packet = vec![0_u8; 2_048];
        let (length, _) = audio.recv_from(&mut packet).unwrap();
        packet.truncate(length);
        packet
    }

    #[test]
    fn pcm_sdp_advertises_sender_origin_and_receiver_connection() {
        let sender = IpAddr::from([192, 0, 2, 10]);
        let receiver = IpAddr::from([192, 0, 2, 20]);
        let sdp = build_pcm_sdp(42, sender, receiver);

        assert!(sdp.contains("o=WinAirPlayAudio 42 0 IN IP4 192.0.2.10\r\n"));
        assert!(sdp.contains("c=IN IP4 192.0.2.20\r\n"));
        assert!(sdp.contains("a=rtpmap:96 L16/44100/2\r\n"));
        assert!(!sdp.contains("AppleLossless"));
        assert!(!sdp.contains("a=fmtp:"));
    }

    #[test]
    fn local_capture_recovery_avoids_rtsp_flush_and_explicit_flush_still_resets() {
        let peer = local_recovery_peer();
        let mut config = one_attempt_config();
        config.io_timeout = Duration::from_secs(1);
        config.receiver_latency_frames = 22_050;
        config.initial_sequence = Some(100);
        config.initial_timestamp = Some(10_000);
        config.ssrc = Some(0x0102_0304);
        config.pace_audio = true;
        let mut session = RaopSession::connect(peer.address, config).unwrap();
        session.start().unwrap();
        assert_eq!(session.receiver_latency_frames(), 44_100);
        let packet_samples =
            vec![0_i16; super::super::DEFAULT_FRAMES_PER_PACKET * usize::from(MVP_CHANNELS)];

        let startup_origin = Instant::now()
            .checked_sub(Duration::from_millis(200))
            .unwrap();
        session.set_media_origin(startup_origin).unwrap();
        let startup_wall_earliest =
            media_system_time(SystemTime::now(), startup_origin.elapsed(), Duration::ZERO);
        session.send_pcm_i16(&packet_samples).unwrap();
        let startup_wall_latest =
            media_system_time(SystemTime::now(), startup_origin.elapsed(), Duration::ZERO);
        assert_sync_packet(
            &peer.control,
            true,
            10_000,
            44_100,
            startup_wall_earliest,
            startup_wall_latest,
        );
        let first_audio = receive_audio_datagram(&peer.audio);
        let first_packet = super::super::parse_rtp_packet(&first_audio).unwrap();
        assert_eq!(session.pacing_origin, Some(startup_origin));
        assert!(frame_duration(session.pacing_frames) < startup_origin.elapsed());
        assert_eq!(first_packet.sequence, 100);
        assert_eq!(first_packet.timestamp, 10_000);
        assert!(first_packet.marker);

        let pre_gap_partial = vec![1_i16; packet_samples.len() / 2];
        session.send_pcm_i16(&pre_gap_partial).unwrap();
        assert_eq!(session.pending_samples, pre_gap_partial);
        assert_eq!(session.stats().audio_packets, 1);
        session.discard_pending_capture_audio().unwrap();
        assert!(session.pending_samples.is_empty());
        session.send_pcm_i16(&pre_gap_partial).unwrap();
        assert_eq!(session.pending_samples, pre_gap_partial);

        let recovery_origin = Instant::now()
            .checked_sub(Duration::from_millis(50))
            .unwrap();
        session
            .recover_from_capture_discontinuity(recovery_origin)
            .unwrap();
        assert!(session.pending_samples.is_empty());
        let recovery_wall_earliest =
            media_system_time(SystemTime::now(), recovery_origin.elapsed(), Duration::ZERO);
        let post_gap_samples = vec![2_i16; packet_samples.len()];
        session.send_pcm_i16(&post_gap_samples).unwrap();
        let recovery_wall_latest =
            media_system_time(SystemTime::now(), recovery_origin.elapsed(), Duration::ZERO);
        assert_eq!(session.pacing_origin, Some(recovery_origin));
        let recovered_timestamp =
            10_000 + u32::try_from(super::super::DEFAULT_FRAMES_PER_PACKET).unwrap();
        assert_sync_packet(
            &peer.control,
            true,
            recovered_timestamp,
            44_100,
            recovery_wall_earliest,
            recovery_wall_latest,
        );
        let recovered_audio = receive_audio_datagram(&peer.audio);
        let recovered_packet = super::super::parse_rtp_packet(&recovered_audio).unwrap();
        assert_eq!(recovered_packet.sequence, 101);
        assert_eq!(recovered_packet.timestamp, recovered_timestamp);
        assert!(recovered_packet.marker);
        assert!(
            recovered_packet
                .payload
                .chunks_exact(size_of::<i16>())
                .all(|sample| sample == 2_i16.to_be_bytes())
        );
        assert_eq!(session.stats().audio_packets, 2);
        assert_eq!(session.stats().capture_discontinuities, 1);

        session.flush().unwrap();
        session.send_pcm_i16(&packet_samples).unwrap();
        let mut restart_sync = [0_u8; 20];
        peer.control.recv_from(&mut restart_sync).unwrap();
        assert_eq!(restart_sync[0], 0x90);
        let mut restarted_audio = [0_u8; 2_048];
        let (restarted_length, _) = peer.audio.recv_from(&mut restarted_audio).unwrap();
        assert!(
            super::super::parse_rtp_packet(&restarted_audio[..restarted_length])
                .unwrap()
                .marker
        );

        session.teardown().unwrap();
        peer.server.join().unwrap();
    }

    #[test]
    fn connection_retry_is_bounded() {
        let attempts = Arc::new(AtomicU32::new(0));
        let observed = Arc::clone(&attempts);
        let result = retry_operation(3, Duration::ZERO, move || {
            let attempt = observed.fetch_add(1, Ordering::SeqCst);
            if attempt < 2 {
                Err(io::Error::new(
                    io::ErrorKind::ConnectionRefused,
                    "not ready",
                ))
            } else {
                Ok(7)
            }
        });
        assert_eq!(result.unwrap(), 7);
        assert_eq!(attempts.load(Ordering::SeqCst), 3);

        let attempts = AtomicU32::new(0);
        let result = retry_operation::<(), _>(2, Duration::ZERO, || {
            attempts.fetch_add(1, Ordering::SeqCst);
            Err(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                "still unavailable",
            ))
        });
        assert_eq!(result.unwrap_err().0, 2);
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn blocked_audio_send_retries_the_same_datagram_and_services_udp() {
        let datagram = b"already packetized RTP";
        let started = Instant::now();
        let elapsed = Cell::new(Duration::ZERO);
        let attempts = Cell::new(0_usize);
        let service_calls = Cell::new(0_usize);
        let waits = Cell::new(0_usize);
        let observed = RefCell::new(Vec::new());

        let sent = send_datagram_with_deadline(
            datagram,
            "test audio send",
            Duration::from_millis(10),
            |candidate| {
                observed.borrow_mut().push(candidate.to_vec());
                let attempt = attempts.get();
                attempts.set(attempt + 1);
                let error_kind = match attempt {
                    0 => Some(io::ErrorKind::WouldBlock),
                    1 => Some(io::ErrorKind::Interrupted),
                    2 => Some(io::ErrorKind::TimedOut),
                    _ => None,
                };
                error_kind.map_or_else(
                    || Ok(candidate.len()),
                    |kind| Err(io::Error::new(kind, "injected retryable send failure")),
                )
            },
            || {
                service_calls.set(service_calls.get() + 1);
                Ok(())
            },
            || started.checked_add(elapsed.get()).unwrap(),
            |duration| {
                waits.set(waits.get() + 1);
                elapsed.set(elapsed.get().saturating_add(duration));
            },
        )
        .unwrap();

        assert_eq!(sent, datagram.len());
        assert_eq!(attempts.get(), 4);
        assert_eq!(service_calls.get(), 3);
        assert_eq!(waits.get(), 3);
        assert_eq!(elapsed.get(), Duration::from_millis(3));
        assert!(
            observed
                .borrow()
                .iter()
                .all(|candidate| candidate == datagram)
        );
    }

    #[test]
    fn blocked_audio_send_times_out_only_when_its_deadline_is_reached() {
        let started = Instant::now();
        let elapsed = Cell::new(Duration::ZERO);
        let attempts = Cell::new(0_usize);
        let service_calls = Cell::new(0_usize);
        let timeout = Duration::from_millis(3);

        let error = send_datagram_with_deadline(
            b"RTP",
            "test audio send",
            timeout,
            |_| {
                attempts.set(attempts.get() + 1);
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "injected transient timeout",
                ))
            },
            || {
                service_calls.set(service_calls.get() + 1);
                Ok(())
            },
            || started.checked_add(elapsed.get()).unwrap(),
            |duration| elapsed.set(elapsed.get().saturating_add(duration)),
        )
        .unwrap_err();

        assert!(matches!(
            error,
            RaopError::Timeout {
                operation: "test audio send",
                timeout: actual
            } if actual == timeout
        ));
        assert_eq!(elapsed.get(), timeout);
        assert_eq!(attempts.get(), 3);
        assert_eq!(service_calls.get(), 3);
    }

    #[test]
    fn partial_audio_datagram_send_is_not_retried() {
        let attempts = Cell::new(0_usize);
        let service_calls = Cell::new(0_usize);
        let error = send_datagram_with_deadline(
            b"RTP",
            "test audio send",
            Duration::from_secs(1),
            |datagram| {
                attempts.set(attempts.get() + 1);
                Ok(datagram.len() - 1)
            },
            || {
                service_calls.set(service_calls.get() + 1);
                Ok(())
            },
            Instant::now,
            thread::sleep,
        )
        .unwrap_err();

        assert!(matches!(
            error,
            RaopError::Io {
                operation: "test audio send",
                source
            } if source.kind() == io::ErrorKind::WriteZero
        ));
        assert_eq!(attempts.get(), 1);
        assert_eq!(service_calls.get(), 0);
    }

    #[test]
    fn startup_audio_retry_budget_is_limited_by_its_playout_deadline() {
        let now = Instant::now();
        let origin = now.checked_sub(Duration::from_millis(474)).unwrap();
        let remaining =
            remaining_audio_send_timeout(Duration::from_secs(3), origin, 16_544, 22_050, now)
                .unwrap();
        let expected = frame_duration(16_544)
            .saturating_add(Duration::from_millis(500))
            .saturating_sub(Duration::from_millis(474));
        assert_eq!(remaining, expected);
        assert!(remaining > Duration::from_millis(400));
        assert!(remaining < Duration::from_millis(402));

        assert_eq!(
            remaining_audio_send_timeout(Duration::from_millis(25), origin, 16_544, 22_050, now,),
            Some(Duration::from_millis(25))
        );
        assert_eq!(
            remaining_audio_send_timeout(Duration::from_secs(3), origin, 0, 11_025, now,),
            None
        );
    }

    #[test]
    fn failed_audio_send_does_not_commit_packetizer_or_audio_counters() {
        let peer = local_recovery_peer();
        let mut config = one_attempt_config();
        // This checks RTP accounting, not RTSP setup scheduling deadlines.
        config.io_timeout = Duration::from_secs(1);
        config.initial_sequence = Some(100);
        config.initial_timestamp = Some(10_000);
        config.ssrc = Some(0x0102_0304);
        let mut session = RaopSession::connect(peer.address, config).unwrap();
        session.start().unwrap();
        let valid_receiver = session.receiver;
        session.receiver = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), valid_receiver.port());
        session.last_sync = Some(Instant::now());
        let packet_samples =
            vec![0_i16; super::super::DEFAULT_FRAMES_PER_PACKET * usize::from(MVP_CHANNELS)];

        let failed_send = session.send_pcm_i16(&packet_samples);
        assert!(
            matches!(
                failed_send,
                Err(RaopError::Io {
                    operation: "send RTP audio datagram",
                    ..
                })
            ),
            "{failed_send:?}"
        );
        assert_eq!(session.packetizer.next_sequence(), 100);
        assert_eq!(session.packetizer.next_timestamp(), 10_000);
        assert_eq!(session.stats().audio_packets, 0);
        assert_eq!(session.stats().audio_frames, 0);
        assert_eq!(session.pacing_frames, 0);
        assert_eq!(session.backlog.len(), 0);

        session.receiver = valid_receiver;
        session.send_pcm_i16(&packet_samples).unwrap();
        let audio = receive_audio_datagram(&peer.audio);
        let packet = super::super::parse_rtp_packet(&audio).unwrap();
        assert_eq!(packet.sequence, 100);
        assert_eq!(packet.timestamp, 10_000);
        assert!(packet.marker);
        assert_eq!(session.stats().audio_packets, 1);
        assert_eq!(session.backlog.len(), 1);

        session.flush().unwrap();
        session.teardown().unwrap();
        peer.server.join().unwrap();
    }

    #[test]
    fn response_timeout_is_explicit() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            super::super::read_rtsp_request(
                &mut stream,
                super::super::RtspMessageLimits::default(),
            )
            .unwrap();
            thread::sleep(Duration::from_millis(120));
        });
        let mut session = RaopSession::connect(address, one_attempt_config()).unwrap();
        assert!(matches!(
            session.start(),
            Err(RaopError::Timeout {
                operation: "read RTSP response",
                ..
            })
        ));
        server.join().unwrap();
    }

    #[test]
    fn connection_reset_is_reported() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            drop(stream);
        });
        let mut session = RaopSession::connect(address, one_attempt_config()).unwrap();
        assert!(matches!(
            session.start(),
            Err(RaopError::Io {
                operation: "write RTSP request" | "read RTSP response",
                ..
            })
        ));
        server.join().unwrap();
    }

    #[test]
    fn invalid_response_is_rejected() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            super::super::read_rtsp_request(
                &mut stream,
                super::super::RtspMessageLimits::default(),
            )
            .unwrap();
            stream
                .write_all(b"not-rtsp\r\nContent-Length: 0\r\n\r\n")
                .unwrap();
            thread::sleep(Duration::from_millis(20));
        });
        let mut session = RaopSession::connect(address, one_attempt_config()).unwrap();
        let result = session.start();
        assert!(matches!(result, Err(RaopError::RtspParse(_))), "{result:?}");
        server.join().unwrap();
    }

    #[test]
    fn transport_parser_requires_all_udp_ports() {
        let parsed = parse_receiver_ports(
            "RTP/AVP/UDP;unicast;server_port=6000;control_port=6001;timing_port=6002",
        )
        .unwrap();
        assert_eq!(parsed.audio, 6000);
        assert_eq!(parsed.control, 6001);
        assert!(parse_receiver_ports("RTP/AVP/TCP;server_port=6000").is_err());
        assert!(parse_receiver_ports("RTP/AVP/UDP;server_port=6000").is_err());
    }

    #[test]
    fn receiver_audio_latency_can_only_raise_the_configured_floor() {
        assert_eq!(effective_receiver_latency(22_050, None).unwrap(), 22_050);
        assert_eq!(
            effective_receiver_latency(22_050, Some("11025")).unwrap(),
            22_050
        );
        assert_eq!(
            effective_receiver_latency(22_050, Some(" 44100 ")).unwrap(),
            44_100
        );
    }

    #[test]
    fn malformed_or_unbounded_receiver_audio_latency_is_rejected() {
        for advertised in ["", "-1", "not-frames", "0", "441001"] {
            let error = effective_receiver_latency(22_050, Some(advertised)).unwrap_err();
            assert!(matches!(error, RaopError::InvalidTransport(_)));
        }
    }

    #[test]
    fn frame_duration_is_exact_at_common_sync_offsets() {
        assert_eq!(frame_duration(11_025), Duration::from_millis(250));
        assert_eq!(frame_duration(22_050), Duration::from_millis(500));
        assert_eq!(frame_duration(44_100), Duration::from_secs(1));
        assert_eq!(frame_duration(44_100 + 4_410), Duration::from_millis(1_100));
    }

    #[test]
    fn media_system_time_tracks_the_current_wall_clock_when_behind_or_ahead() {
        let wall_now = UNIX_EPOCH + Duration::from_secs(1_000);
        assert_eq!(
            media_system_time(
                wall_now,
                Duration::from_millis(600),
                Duration::from_millis(100)
            ),
            wall_now - Duration::from_millis(500)
        );
        assert_eq!(
            media_system_time(
                wall_now,
                Duration::from_millis(100),
                Duration::from_millis(600)
            ),
            wall_now + Duration::from_millis(500)
        );
        assert_eq!(
            media_system_time(wall_now, Duration::from_secs(1), Duration::from_secs(1)),
            wall_now
        );
    }
}
