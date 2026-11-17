use std::error::Error;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use clap::{Parser, ValueEnum};
use hound::{SampleFormat, WavReader};
use winairplay_shared::audio::{AudioConverter, AudioFormat, SineGenerator};
use winairplay_shared::raop::{
    AirPlayTier, MVP_CHANNELS, MVP_SAMPLE_RATE, MediaTransport, PairingRequirement,
    RaopClientConfig, RaopCodec, RaopEncryption, RaopSession, ReceiverProfile,
};
use zeroize::Zeroize;

const SOURCE_CHUNK_FRAMES: usize = 1_024;

#[derive(Parser)]
#[command(
    name = "airplay-send",
    about = "Send a deterministic tone or WAV to the narrow classic-RAOP MVP profile"
)]
struct Args {
    /// Receiver RTSP socket address, for example 192.0.2.10:5000.
    #[arg(long)]
    receiver: SocketAddr,

    /// Bind RTSP and RTP sockets to this local interface address.
    #[arg(long)]
    local_address: Option<IpAddr>,

    /// Perform the MFi-SAP auth-setup preflight required by `AirTunes` 366 speakers.
    #[arg(long)]
    auth_setup: bool,

    /// WAV file to stream. If omitted, a deterministic sine tone is generated.
    #[arg(long)]
    wav: Option<PathBuf>,

    /// Tone frequency in hertz.
    #[arg(long, default_value_t = 997.0)]
    frequency: f64,

    /// Tone duration in seconds.
    #[arg(long, default_value_t = 1.0)]
    duration: f64,

    /// Tone peak amplitude from 0 through 1.
    #[arg(long, default_value_t = 0.25)]
    amplitude: f32,

    /// Generated tone input sample rate; converted continuously to 44.1 kHz.
    #[arg(long, default_value_t = 48_000)]
    input_rate: u32,

    /// Generated tone input channels; mono and stereo are supported.
    #[arg(long, default_value_t = 2)]
    input_channels: u16,

    /// Optional classic RTSP Digest password.
    #[arg(long)]
    password: Option<String>,

    /// Disable real-time packet pacing (intended for the automated mock only).
    #[arg(long)]
    no_pace: bool,

    /// Receiver protocol tier.
    #[arg(long, value_enum, default_value_t = CliTier::Classic)]
    tier: CliTier,

    /// Receiver audio codec.
    #[arg(long, value_enum, default_value_t = CliCodec::Pcm)]
    codec: CliCodec,

    /// Receiver media encryption requirement.
    #[arg(long, value_enum, default_value_t = CliEncryption::None)]
    encryption: CliEncryption,

    /// Receiver protocol pairing requirement (not an RTSP password).
    #[arg(long, value_enum, default_value_t = CliPairing::None)]
    pairing: CliPairing,

    /// Receiver media transport.
    #[arg(long, value_enum, default_value_t = CliTransport::Udp)]
    transport: CliTransport,

    /// RTSP connect/read/write timeout in milliseconds.
    #[arg(long, default_value_t = 3_000)]
    timeout_ms: u64,

    /// Print bounded RTSP request/response diagnostics with credentials redacted.
    #[arg(long)]
    trace_rtsp: bool,
}

impl Drop for Args {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            password.zeroize();
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliTier {
    Classic,
    Airplay2,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliCodec {
    Pcm,
    Alac,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliEncryption {
    None,
    RsaAes,
    MfiSap,
    Fairplay,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliPairing {
    None,
    Legacy,
    HapTransient,
    HapPersistent,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliTransport {
    Udp,
    Tcp,
}

fn main() -> ExitCode {
    let args = Args::parse();
    if args.trace_rtsp
        && let Err(error) = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::DEBUG)
            .with_writer(std::io::stderr)
            .try_init()
    {
        eprintln!("airplay-send: cannot initialize RTSP tracing: {error}");
        return ExitCode::FAILURE;
    }
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("airplay-send: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &Args) -> Result<(), Box<dyn Error>> {
    let timeout = Duration::from_millis(args.timeout_ms);
    let profile = ReceiverProfile {
        tier: match args.tier {
            CliTier::Classic => AirPlayTier::ClassicRaop,
            CliTier::Airplay2 => AirPlayTier::AirPlay2,
        },
        codec: match args.codec {
            CliCodec::Pcm => RaopCodec::PcmL16,
            CliCodec::Alac => RaopCodec::AppleLossless,
        },
        encryption: match args.encryption {
            CliEncryption::None => RaopEncryption::None,
            CliEncryption::RsaAes => RaopEncryption::RsaAes,
            CliEncryption::MfiSap => RaopEncryption::MfiSap,
            CliEncryption::Fairplay => RaopEncryption::FairPlay,
        },
        pairing: match args.pairing {
            CliPairing::None => PairingRequirement::None,
            CliPairing::Legacy => PairingRequirement::Legacy,
            CliPairing::HapTransient => PairingRequirement::HapTransient,
            CliPairing::HapPersistent => PairingRequirement::HapPersistent,
        },
        transport: match args.transport {
            CliTransport::Udp => MediaTransport::Udp,
            CliTransport::Tcp => MediaTransport::Tcp,
        },
    };
    let mut config = RaopClientConfig::default();
    config.profile = profile;
    config.local_bind_ip = args.local_address;
    config.perform_auth_setup = args.auth_setup;
    config.connect_timeout = timeout;
    config.io_timeout = timeout;
    config.password.clone_from(&args.password);
    config.pace_audio = !args.no_pace;
    let mut session = RaopSession::connect(args.receiver, config)?;
    session.start()?;

    let stream_result = if let Some(path) = args.wav.as_deref() {
        stream_wav(path, &mut session)
    } else {
        stream_tone(args, &mut session)
    }
    .and_then(|()| session.finish_audio().map_err(Box::<dyn Error>::from));
    let teardown_result = session.teardown();
    stream_result?;
    teardown_result?;

    let stats = session.stats();
    println!(
        "stream complete: {} frames in {} RTP packets; {} retransmissions; {} timing replies",
        stats.audio_frames,
        stats.audio_packets,
        stats.retransmitted_packets,
        stats.timing_responses
    );
    Ok(())
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn stream_tone(args: &Args, session: &mut RaopSession) -> Result<(), Box<dyn Error>> {
    if !args.duration.is_finite() || !(0.0..=3_600.0).contains(&args.duration) {
        return Err(invalid_input(format!(
            "tone duration must be finite and between 0 and 3600 seconds, got {}",
            args.duration
        ))
        .into());
    }
    let input_format = AudioFormat {
        sample_rate: args.input_rate,
        channels: args.input_channels,
    };
    let output_format = AudioFormat {
        sample_rate: MVP_SAMPLE_RATE,
        channels: MVP_CHANNELS,
    };
    let mut generator = SineGenerator::new(input_format, args.frequency, args.amplitude)?;
    let mut converter = AudioConverter::new(input_format, output_format)?;
    let mut remaining_frames = (args.duration * f64::from(args.input_rate)).round() as usize;
    while remaining_frames != 0 {
        let frames = remaining_frames.min(SOURCE_CHUNK_FRAMES);
        let input = generator.render(frames);
        let output_chunk = converter.process_f32(&input, false)?;
        session.send_pcm_i16(&output_chunk.samples)?;
        remaining_frames -= frames;
    }
    let final_chunk = converter.finish()?;
    session.send_pcm_i16(&final_chunk.samples)?;
    Ok(())
}

fn stream_wav(path: &Path, session: &mut RaopSession) -> Result<(), Box<dyn Error>> {
    decode_wav(path, |samples| {
        session
            .send_pcm_i16(samples)
            .map_err(Box::<dyn Error>::from)
    })
}

#[allow(clippy::cast_possible_truncation)]
fn decode_wav<F>(path: &Path, mut emit: F) -> Result<(), Box<dyn Error>>
where
    F: FnMut(&[i16]) -> Result<(), Box<dyn Error>>,
{
    let mut reader = WavReader::open(path)?;
    let spec = reader.spec();
    let input_format = AudioFormat {
        sample_rate: spec.sample_rate,
        channels: spec.channels,
    };
    let output_format = AudioFormat {
        sample_rate: MVP_SAMPLE_RATE,
        channels: MVP_CHANNELS,
    };
    let mut converter = AudioConverter::new(input_format, output_format)?;
    match spec.sample_format {
        SampleFormat::Float if spec.bits_per_sample == 32 => {
            pump_wav_samples(
                reader.samples::<f32>(),
                spec.channels,
                &mut converter,
                &mut emit,
                |sample| sample,
            )?;
        }
        SampleFormat::Int if (1..=32).contains(&spec.bits_per_sample) => {
            let positive_peak = 2_f64.powi(i32::from(spec.bits_per_sample) - 1) - 1.0;
            pump_wav_samples(
                reader.samples::<i32>(),
                spec.channels,
                &mut converter,
                &mut emit,
                move |sample| {
                    if sample < 0 {
                        (f64::from(sample) / (positive_peak + 1.0)) as f32
                    } else {
                        (f64::from(sample) / positive_peak.max(1.0)) as f32
                    }
                },
            )?;
        }
        _ => {
            return Err(invalid_input(format!(
                "WAV format {:?}/{}-bit is unsupported; expected PCM up to 32-bit or 32-bit float",
                spec.sample_format, spec.bits_per_sample
            ))
            .into());
        }
    }
    let final_chunk = converter.finish()?;
    emit(&final_chunk.samples)?;
    Ok(())
}

fn pump_wav_samples<I, S, F, E>(
    samples: I,
    channels: u16,
    converter: &mut AudioConverter,
    emit: &mut E,
    map_sample: F,
) -> Result<(), Box<dyn Error>>
where
    I: Iterator<Item = Result<S, hound::Error>>,
    F: Fn(S) -> f32,
    E: FnMut(&[i16]) -> Result<(), Box<dyn Error>>,
{
    let chunk_samples = SOURCE_CHUNK_FRAMES
        .checked_mul(usize::from(channels))
        .ok_or_else(|| invalid_input("WAV channel count overflows chunk size"))?;
    let mut input = Vec::with_capacity(chunk_samples);
    for sample in samples {
        input.push(map_sample(sample?));
        if input.len() == chunk_samples {
            let output_chunk = converter.process_f32(&input, false)?;
            emit(&output_chunk.samples)?;
            input.clear();
        }
    }
    if !input.is_empty() {
        let output_chunk = converter.process_f32(&input, false)?;
        emit(&output_chunk.samples)?;
    }
    Ok(())
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::TAU;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use hound::{WavSpec, WavWriter};

    #[test]
    fn unsupported_cli_profile_maps_to_precise_library_error() {
        let profile = ReceiverProfile {
            tier: AirPlayTier::AirPlay2,
            ..ReceiverProfile::default()
        };
        let error = profile.validate().unwrap_err().to_string();
        assert!(error.contains("HAP pair-verify"));
    }

    #[test]
    #[allow(clippy::cast_possible_truncation)]
    fn wav_input_is_decoded_resampled_and_upmixed_deterministically() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "winairplay-audio-{unique}-{}.wav",
            std::process::id()
        ));
        let spec = WavSpec {
            channels: 1,
            sample_rate: 48_000,
            bits_per_sample: 16,
            sample_format: SampleFormat::Int,
        };
        let mut writer = WavWriter::create(&path, spec).unwrap();
        for frame in 0..4_800 {
            let phase = TAU * 997.0 * f64::from(frame) / 48_000.0;
            writer
                .write_sample((phase.sin() * 0.25 * f64::from(i16::MAX)).round() as i16)
                .unwrap();
        }
        writer.finalize().unwrap();

        let mut output = Vec::new();
        decode_wav(&path, |samples| {
            output.extend_from_slice(samples);
            Ok(())
        })
        .unwrap();
        fs::remove_file(&path).unwrap();

        assert_eq!(output.len(), 4_410 * 2);
        assert!(output.chunks_exact(2).all(|frame| frame[0] == frame[1]));
        let crossings = output
            .chunks_exact(2)
            .map(|frame| frame[0])
            .collect::<Vec<_>>()
            .windows(2)
            .filter(|pair| pair[0] <= 0 && pair[1] > 0)
            .count();
        assert!((990..=1_000).contains(&(crossings * 10)));
    }
}
