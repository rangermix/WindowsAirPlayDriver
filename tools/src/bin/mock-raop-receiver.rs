use std::error::Error;
use std::io::{self, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use clap::Parser;
use winairplay_shared::raop::{
    DigestChallenge, MVP_CHANNELS, MVP_SAMPLE_RATE, RtspMessageLimits, RtspRequest, RtspResponse,
    parse_rtp_packet, read_rtsp_request, verify_digest_authorization, write_rtsp_response,
};
use zeroize::Zeroize;

type MockResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

const SESSION_ID: &str = "1";

#[derive(Clone, Parser)]
#[command(
    name = "mock-raop-receiver",
    about = "Validate the narrow classic-RAOP RTSP/RTP sender profile"
)]
struct Args {
    /// RTSP address to listen on. Port zero asks the OS for a free port.
    #[arg(long, default_value = "127.0.0.1:0")]
    bind: SocketAddr,

    /// Require and verify this RTSP Digest password.
    #[arg(long)]
    password: Option<String>,

    /// Expected sine frequency in hertz.
    #[arg(long, default_value_t = 997.0)]
    expected_frequency: f64,

    /// Expected audio duration in seconds.
    #[arg(long, default_value_t = 1.0)]
    expected_duration: f64,

    /// Expected peak amplitude.
    #[arg(long, default_value_t = 0.25)]
    expected_amplitude: f32,

    /// Skip timing and retransmission probes.
    #[arg(long)]
    no_control_probe: bool,

    /// Overall wait timeout in milliseconds.
    #[arg(long, default_value_t = 10_000)]
    timeout_ms: u64,
}

impl Drop for Args {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            password.zeroize();
        }
    }
}

#[derive(Clone)]
struct MockConfig {
    password: Option<String>,
    expected_frequency: f64,
    expected_duration: f64,
    expected_amplitude: f32,
    control_probe: bool,
    timeout: Duration,
}

impl Drop for MockConfig {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            password.zeroize();
        }
    }
}

#[derive(Clone, Debug)]
struct MockReport {
    request_order: Vec<String>,
    audio_frames: usize,
    estimated_frequency: f64,
    peak_amplitude: f32,
    retransmission_verified: bool,
    timing_verified: bool,
}

fn main() -> ExitCode {
    let args = Args::parse();
    match run_main(args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("mock-raop-receiver: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run_main(mut args: Args) -> MockResult<()> {
    validate_expectations(
        args.expected_frequency,
        args.expected_duration,
        args.expected_amplitude,
    )?;
    let listener = TcpListener::bind(args.bind)?;
    println!("mock RAOP receiver listening on {}", listener.local_addr()?);
    io::stdout().flush()?;
    let report = run_mock(
        &listener,
        &MockConfig {
            password: args.password.take(),
            expected_frequency: args.expected_frequency,
            expected_duration: args.expected_duration,
            expected_amplitude: args.expected_amplitude,
            control_probe: !args.no_control_probe,
            timeout: Duration::from_millis(args.timeout_ms),
        },
    )?;
    println!(
        "validated: methods={:?}, frames={}, frequency={:.2} Hz, amplitude={:.4}, retransmission={}, timing={}",
        report.request_order,
        report.audio_frames,
        report.estimated_frequency,
        report.peak_amplitude,
        report.retransmission_verified,
        report.timing_verified
    );
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn run_mock(listener: &TcpListener, config: &MockConfig) -> MockResult<MockReport> {
    validate_expectations(
        config.expected_frequency,
        config.expected_duration,
        config.expected_amplitude,
    )?;
    let deadline = Instant::now()
        .checked_add(config.timeout)
        .ok_or_else(|| invalid_input("mock timeout is too large"))?;
    let bind_ip = listener.local_addr()?.ip();
    let audio_socket = bind_udp(bind_ip)?;
    let control_socket = bind_udp(bind_ip)?;
    let timing_socket = bind_udp(bind_ip)?;
    let (mut rtsp, peer) = accept_until(listener, deadline)?;
    rtsp.set_nonblocking(false)?;
    let remaining = deadline.saturating_duration_since(Instant::now());
    rtsp.set_read_timeout(Some(remaining))?;
    rtsp.set_write_timeout(Some(remaining))?;

    let challenge = DigestChallenge {
        realm: "WinAirPlayAudio mock".to_owned(),
        nonce: "0123456789abcdef0123456789abcdef".to_owned(),
        opaque: Some("mock-opaque".to_owned()),
        qop: Some("auth".to_owned()),
    };
    let limits = RtspMessageLimits::default();
    let mut order = Vec::new();

    let announce = read_expected_request(&mut rtsp, "ANNOUNCE", config, &challenge, true, limits)?;
    validate_announce(&announce)?;
    send_ok(&mut rtsp, &announce, &[])?;
    order.push(announce.method);

    let setup = read_expected_request(&mut rtsp, "SETUP", config, &challenge, false, limits)?;
    let (client_control_port, client_timing_port) = parse_client_ports(&setup)?;
    let transport = format!(
        "RTP/AVP/UDP;unicast;mode=record;server_port={};control_port={};timing_port={}",
        audio_socket.local_addr()?.port(),
        control_socket.local_addr()?.port(),
        timing_socket.local_addr()?.port()
    );
    send_ok(
        &mut rtsp,
        &setup,
        &[("Session", SESSION_ID), ("Transport", &transport)],
    )?;
    order.push(setup.method);

    let record = read_expected_request(&mut rtsp, "RECORD", config, &challenge, false, limits)?;
    require_header(&record, "session", SESSION_ID)?;
    if record.header("rtp-info").is_none() || record.header("range") != Some("npt=0-") {
        return Err(invalid_data("RECORD omitted Range or RTP-Info").into());
    }
    send_ok(&mut rtsp, &record, &[])?;
    order.push(record.method);

    let volume = read_expected_request(
        &mut rtsp,
        "SET_PARAMETER",
        config,
        &challenge,
        false,
        limits,
    )?;
    require_header(&volume, "session", SESSION_ID)?;
    require_header(&volume, "content-type", "text/parameters")?;
    if volume.body != b"volume: -10.000000\r\n" {
        return Err(invalid_data("SET_PARAMETER did not set the initial volume").into());
    }
    send_ok(&mut rtsp, &volume, &[])?;
    order.push(volume.method);

    let expected_frames = duration_frames(config.expected_duration)?;
    let audio_result = receive_audio(
        &audio_socket,
        &control_socket,
        &timing_socket,
        peer.ip(),
        client_control_port,
        client_timing_port,
        expected_frames,
        config.control_probe,
        deadline,
    )?;
    let (estimated_frequency, peak_amplitude) = validate_audio(
        &audio_result.samples,
        config.expected_frequency,
        config.expected_amplitude,
    )?;

    let teardown = read_expected_request(&mut rtsp, "TEARDOWN", config, &challenge, false, limits)?;
    require_header(&teardown, "session", SESSION_ID)?;
    send_ok(&mut rtsp, &teardown, &[])?;
    order.push(teardown.method);

    Ok(MockReport {
        request_order: order,
        audio_frames: audio_result.samples.len() / usize::from(MVP_CHANNELS),
        estimated_frequency,
        peak_amplitude,
        retransmission_verified: audio_result.retransmission_verified,
        timing_verified: audio_result.timing_verified,
    })
}

fn read_expected_request(
    stream: &mut TcpStream,
    expected_method: &str,
    config: &MockConfig,
    challenge: &DigestChallenge,
    allow_initial_challenge: bool,
    limits: RtspMessageLimits,
) -> MockResult<RtspRequest> {
    let mut request = read_rtsp_request(stream, limits)?;
    if let Some(password) = config.password.as_deref() {
        if request.header("authorization").is_none() && allow_initial_challenge {
            let challenge_header = format!(
                "Digest realm=\"{}\", nonce=\"{}\", opaque=\"{}\", qop=\"auth\", algorithm=MD5",
                challenge.realm,
                challenge.nonce,
                challenge.opaque.as_deref().unwrap_or("")
            );
            let response = response_for(&request, 401, "Unauthorized")?
                .with_header("WWW-Authenticate", challenge_header);
            write_rtsp_response(stream, &response)?;
            request = read_rtsp_request(stream, limits)?;
        }
        let authorization = request.header("authorization").ok_or_else(|| {
            invalid_data(format!("{expected_method} omitted Digest Authorization"))
        })?;
        if !verify_digest_authorization(
            authorization,
            challenge,
            password,
            &request.method,
            &request.uri,
        ) {
            return Err(invalid_data(format!(
                "{expected_method} contained invalid Digest Authorization"
            ))
            .into());
        }
    }
    if request.method != expected_method {
        return Err(invalid_data(format!(
            "expected RTSP {expected_method}, got {}",
            request.method
        ))
        .into());
    }
    Ok(request)
}

fn validate_announce(request: &RtspRequest) -> MockResult<()> {
    if request.header("content-type") != Some("application/sdp") {
        return Err(invalid_data("ANNOUNCE omitted application/sdp Content-Type").into());
    }
    let sdp = std::str::from_utf8(&request.body)?;
    if !sdp.contains("a=rtpmap:96 L16/44100/2") {
        return Err(invalid_data("ANNOUNCE did not select stereo 44.1 kHz L16").into());
    }
    if sdp.contains("rsaaeskey") || sdp.contains("aesiv") {
        return Err(invalid_data("ANNOUNCE falsely advertised media encryption").into());
    }
    Ok(())
}

fn parse_client_ports(request: &RtspRequest) -> MockResult<(u16, u16)> {
    let transport = request
        .header("transport")
        .ok_or_else(|| invalid_data("SETUP omitted Transport"))?;
    if !transport
        .split(';')
        .next()
        .is_some_and(|value| value.eq_ignore_ascii_case("RTP/AVP/UDP"))
    {
        return Err(invalid_data("SETUP did not request RTP/AVP/UDP").into());
    }
    let mut control = None;
    let mut timing = None;
    for field in transport.split(';').skip(1) {
        let Some((name, value)) = field.trim().split_once('=') else {
            continue;
        };
        let port = value.parse::<u16>().ok().filter(|port| *port != 0);
        match name.to_ascii_lowercase().as_str() {
            "control_port" => control = port,
            "timing_port" => timing = port,
            _ => {}
        }
    }
    Ok((
        control.ok_or_else(|| invalid_data("SETUP omitted client control_port"))?,
        timing.ok_or_else(|| invalid_data("SETUP omitted client timing_port"))?,
    ))
}

#[derive(Debug)]
struct AudioResult {
    samples: Vec<i16>,
    retransmission_verified: bool,
    timing_verified: bool,
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn receive_audio(
    audio: &UdpSocket,
    control: &UdpSocket,
    timing: &UdpSocket,
    sender_ip: IpAddr,
    sender_control_port: u16,
    sender_timing_port: u16,
    expected_frames: usize,
    control_probe: bool,
    deadline: Instant,
) -> MockResult<AudioResult> {
    let mut samples = Vec::with_capacity(
        expected_frames
            .checked_mul(usize::from(MVP_CHANNELS))
            .ok_or_else(|| invalid_input("expected audio size overflow"))?,
    );
    let mut expected_sequence = None;
    let mut expected_timestamp = None;
    let mut first_packet = None;
    let mut request_sent = false;
    let mut timing_request = [0_u8; 32];
    timing_request[0] = 0x80;
    timing_request[1] = 0xD2;
    timing_request[2..4].copy_from_slice(&7_u16.to_be_bytes());
    timing_request[24..32].copy_from_slice(&0x0102_0304_0506_0708_u64.to_be_bytes());

    while samples.len() / usize::from(MVP_CHANNELS) < expected_frames {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(
                io::Error::new(io::ErrorKind::TimedOut, "timed out waiting for RTP audio").into(),
            );
        }
        audio.set_read_timeout(Some(remaining.min(Duration::from_millis(250))))?;
        let mut bytes = vec![0_u8; 65_536];
        let (length, source) = match audio.recv_from(&mut bytes) {
            Ok(value) => value,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        if source.ip() != sender_ip {
            continue;
        }
        bytes.truncate(length);
        let packet = parse_rtp_packet(&bytes)?;
        if packet.payload_type != 96 {
            return Err(invalid_data("RTP packet has an invalid payload type").into());
        }
        if let Some(sequence) = expected_sequence {
            if packet.sequence != sequence {
                return Err(invalid_data(format!(
                    "RTP sequence discontinuity: expected {sequence}, got {}",
                    packet.sequence
                ))
                .into());
            }
        } else if !packet.marker {
            return Err(invalid_data("first RTP packet omitted marker bit").into());
        }
        if let Some(timestamp) = expected_timestamp
            && packet.timestamp != timestamp
        {
            return Err(invalid_data(format!(
                "RTP timestamp discontinuity: expected {timestamp}, got {}",
                packet.timestamp
            ))
            .into());
        }
        let decoded = decode_l16(packet.payload)?;
        let packet_frames = decoded.len() / 2;
        expected_sequence = Some(packet.sequence.wrapping_add(1));
        expected_timestamp = Some(packet.timestamp.wrapping_add(u32::try_from(packet_frames)?));
        samples.extend_from_slice(&decoded);

        if control_probe && !request_sent {
            first_packet = Some(bytes.clone());
            let mut retransmission = [0_u8; 8];
            retransmission[0] = 0x80;
            retransmission[1] = 0x55;
            retransmission[2..4].copy_from_slice(&1_u16.to_be_bytes());
            retransmission[4..6].copy_from_slice(&packet.sequence.to_be_bytes());
            retransmission[6..8].copy_from_slice(&1_u16.to_be_bytes());
            control.send_to(
                &retransmission,
                SocketAddr::new(sender_ip, sender_control_port),
            )?;
            timing.send_to(
                &timing_request,
                SocketAddr::new(sender_ip, sender_timing_port),
            )?;
            request_sent = true;
        }
    }
    samples.truncate(expected_frames * usize::from(MVP_CHANNELS));

    let retransmission_verified = if control_probe {
        wait_for_retransmission(
            control,
            first_packet.as_deref().expect("probe packet"),
            deadline,
        )?
    } else {
        false
    };
    let timing_verified = if control_probe {
        wait_for_timing(timing, &timing_request, deadline)?
    } else {
        false
    };
    Ok(AudioResult {
        samples,
        retransmission_verified,
        timing_verified,
    })
}

fn decode_l16(payload: &[u8]) -> MockResult<Vec<i16>> {
    if !payload.len().is_multiple_of(2) {
        return Err(invalid_data("L16 payload has a partial sample").into());
    }
    Ok(payload
        .chunks_exact(2)
        .map(|sample| i16::from_be_bytes([sample[0], sample[1]]))
        .collect())
}

fn wait_for_retransmission(
    socket: &UdpSocket,
    original: &[u8],
    deadline: Instant,
) -> MockResult<bool> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for retransmission response",
            )
            .into());
        }
        socket.set_read_timeout(Some(remaining.min(Duration::from_millis(250))))?;
        let mut response = vec![0_u8; 65_536];
        let (length, _) = match socket.recv_from(&mut response) {
            Ok(value) => value,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        response.truncate(length);
        if response.get(1).map(|value| value & 0x7F) != Some(0x56) {
            continue;
        }
        if response.len() != original.len() + 4 || &response[4..] != original {
            return Err(invalid_data("retransmission response did not wrap original RTP").into());
        }
        return Ok(true);
    }
}

fn wait_for_timing(socket: &UdpSocket, request: &[u8; 32], deadline: Instant) -> MockResult<bool> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out waiting for timing response",
            )
            .into());
        }
        socket.set_read_timeout(Some(remaining.min(Duration::from_millis(250))))?;
        let mut response = [0_u8; 32];
        let (length, _) = match socket.recv_from(&mut response) {
            Ok(value) => value,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        if length != 32 || response[1] & 0x7F != 0x53 {
            continue;
        }
        if response[8..16] != request[24..32] {
            return Err(invalid_data("timing response did not echo sender timestamp").into());
        }
        return Ok(true);
    }
}

#[allow(clippy::cast_precision_loss)]
fn validate_audio(
    samples: &[i16],
    expected_frequency: f64,
    expected_amplitude: f32,
) -> MockResult<(f64, f32)> {
    if samples.len() < usize::from(MVP_CHANNELS) * 2 {
        return Err(invalid_data("received audio is too short to validate").into());
    }
    let mut left = Vec::with_capacity(samples.len() / 2);
    let mut peak = 0_i32;
    for frame in samples.chunks_exact(2) {
        if (i32::from(frame[0]) - i32::from(frame[1])).abs() > 1 {
            return Err(invalid_data("received stereo channels differ").into());
        }
        peak = peak.max(i32::from(frame[0]).abs());
        left.push(frame[0]);
    }
    let crossings = left
        .windows(2)
        .filter(|pair| pair[0] <= 0 && pair[1] > 0)
        .count();
    let duration = left.len() as f64 / f64::from(MVP_SAMPLE_RATE);
    let estimated_frequency = crossings as f64 / duration;
    let peak_amplitude = peak as f32 / f32::from(i16::MAX);
    let frequency_tolerance = (1.0 / duration).max(3.0);
    if (estimated_frequency - expected_frequency).abs() > frequency_tolerance {
        return Err(invalid_data(format!(
            "tone frequency {estimated_frequency:.2} Hz differs from expected {expected_frequency:.2} Hz"
        ))
        .into());
    }
    if (peak_amplitude - expected_amplitude).abs() > 0.02 {
        return Err(invalid_data(format!(
            "tone amplitude {peak_amplitude:.4} differs from expected {expected_amplitude:.4}"
        ))
        .into());
    }
    Ok((estimated_frequency, peak_amplitude))
}

fn require_header(request: &RtspRequest, name: &str, expected: &str) -> MockResult<()> {
    let actual = request
        .header(name)
        .ok_or_else(|| invalid_data(format!("{} omitted {name}", request.method)))?;
    if actual != expected {
        return Err(invalid_data(format!(
            "{} {name} was {actual:?}; expected {expected:?}",
            request.method
        ))
        .into());
    }
    Ok(())
}

fn send_ok(
    stream: &mut TcpStream,
    request: &RtspRequest,
    headers: &[(&str, &str)],
) -> MockResult<()> {
    let mut response = response_for(request, 200, "OK")?;
    for (name, value) in headers {
        response = response.with_header(*name, *value);
    }
    write_rtsp_response(stream, &response)?;
    Ok(())
}

fn response_for(request: &RtspRequest, status: u16, reason: &str) -> MockResult<RtspResponse> {
    let cseq = request
        .header("cseq")
        .ok_or_else(|| invalid_data(format!("{} omitted CSeq", request.method)))?;
    Ok(RtspResponse::new(status, reason).with_header("CSeq", cseq))
}

fn bind_udp(ip: IpAddr) -> io::Result<UdpSocket> {
    UdpSocket::bind(SocketAddr::new(ip, 0))
}

fn accept_until(listener: &TcpListener, deadline: Instant) -> io::Result<(TcpStream, SocketAddr)> {
    listener.set_nonblocking(true)?;
    loop {
        match listener.accept() {
            Ok(value) => return Ok(value),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "timed out waiting for RTSP connection",
                    ));
                }
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => return Err(error),
        }
    }
}

fn validate_expectations(frequency: f64, duration: f64, amplitude: f32) -> io::Result<()> {
    if !frequency.is_finite() || frequency <= 0.0 || frequency >= f64::from(MVP_SAMPLE_RATE) / 2.0 {
        return Err(invalid_input("expected frequency must be below Nyquist"));
    }
    if !duration.is_finite() || !(0.01..=60.0).contains(&duration) {
        return Err(invalid_input(
            "expected duration must be finite and between 0.01 and 60 seconds",
        ));
    }
    if !amplitude.is_finite() || !(0.0..=1.0).contains(&amplitude) {
        return Err(invalid_input(
            "expected amplitude must be finite and between 0 and 1",
        ));
    }
    Ok(())
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn duration_frames(duration: f64) -> io::Result<usize> {
    let frames = (duration * f64::from(MVP_SAMPLE_RATE)).round();
    if frames < 1.0 {
        return Err(invalid_input("expected duration frame count is invalid"));
    }
    Ok(frames as usize)
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use winairplay_shared::audio::{AudioConverter, AudioFormat, SineGenerator};
    use winairplay_shared::raop::{RaopClientConfig, RaopSession};

    #[test]
    fn mock_validates_digest_rtsp_audio_timing_and_retransmission() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let mock = thread::spawn(move || {
            run_mock(
                &listener,
                &MockConfig {
                    password: Some("correct horse".to_owned()),
                    expected_frequency: 997.0,
                    expected_duration: 0.1,
                    expected_amplitude: 0.25,
                    control_probe: true,
                    timeout: Duration::from_secs(5),
                },
            )
        });

        let mut session = RaopSession::connect(address, {
            let mut config = RaopClientConfig::default();
            config.password = Some("correct horse".to_owned());
            config.max_connect_attempts = 1;
            config.pace_audio = false;
            config.initial_sequence = Some(u16::MAX - 4);
            config.initial_timestamp = Some(u32::MAX - 1_000);
            config.ssrc = Some(0x0102_0304);
            config.post_stream_control_window = Duration::from_millis(200);
            config
        })
        .unwrap();
        if let Err(sender_error) = session.start() {
            let mock_result = mock.join().unwrap();
            panic!("sender failed: {sender_error}; mock result: {mock_result:?}");
        }
        let input_format = AudioFormat {
            sample_rate: 48_000,
            channels: 1,
        };
        let output_format = AudioFormat {
            sample_rate: MVP_SAMPLE_RATE,
            channels: MVP_CHANNELS,
        };
        let mut generator = SineGenerator::new(input_format, 997.0, 0.25).unwrap();
        let mut converter = AudioConverter::new(input_format, output_format).unwrap();
        let input = generator.render(4_800);
        let output_chunk = converter.process_f32(&input, false).unwrap();
        session.send_pcm_i16(&output_chunk.samples).unwrap();
        let tail = converter.finish().unwrap();
        session.send_pcm_i16(&tail.samples).unwrap();
        session.finish_audio().unwrap();
        session.teardown().unwrap();

        let report = mock.join().unwrap().unwrap();
        assert_eq!(
            report.request_order,
            ["ANNOUNCE", "SETUP", "RECORD", "SET_PARAMETER", "TEARDOWN"]
        );
        assert_eq!(report.audio_frames, 4_410);
        assert!(report.retransmission_verified);
        assert!(report.timing_verified);
        assert_eq!(session.stats().retransmitted_packets, 1);
        assert_eq!(session.stats().timing_responses, 1);
    }

    #[test]
    fn malformed_rtp_is_rejected_cleanly() {
        use winairplay_shared::raop::RaopError;

        assert!(matches!(
            parse_rtp_packet(&[0_u8; 4]),
            Err(RaopError::InvalidRtp(_))
        ));
    }
}
