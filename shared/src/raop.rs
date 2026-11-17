//! Narrow, synchronous classic RAOP sender implementation.
//!
//! The Milestone 2 profile intentionally supports only unencrypted UDP RTP
//! carrying stereo 16-bit linear PCM. Unsupported ALAC, pairing, encryption,
//! TCP media, and `AirPlay` 2 profiles fail before a network connection is made.

mod digest;
mod rtp;
mod rtsp;
mod session;

use std::fmt;
use std::io;
use std::net::IpAddr;
use std::time::Duration;

use thiserror::Error;
use zeroize::Zeroize;

pub use digest::{DigestChallenge, verify_digest_authorization};
pub use rtp::{
    PacketizedRtp, RetransmissionRequest, RtpPacketView, RtpPacketizer, build_retransmission_reply,
    parse_rtp_packet,
};
pub use rtsp::{
    RtspMessageLimits, RtspRequest, RtspResponse, read_rtsp_request, read_rtsp_response,
    write_rtsp_response,
};
pub use session::{RaopSession, RaopStats, SessionState};

/// Sample rate used by the narrow classic RAOP profile.
pub const MVP_SAMPLE_RATE: u32 = 44_100;
/// Smallest supported classic RAOP sync offset (250 ms at 44.1 kHz).
pub const MIN_SYNC_LATENCY_FRAMES: u32 = MVP_SAMPLE_RATE / 4;
/// Largest sender-configured classic RAOP sync offset (3 seconds at 44.1 kHz).
pub const MAX_SYNC_LATENCY_FRAMES: u32 = MVP_SAMPLE_RATE * 3;
/// Sample size used by the narrow classic RAOP profile.
pub const MVP_BITS_PER_SAMPLE: u16 = 16;
/// Channel count used by the narrow classic RAOP profile.
pub const MVP_CHANNELS: u16 = 2;
/// Nominal packet size used by classic RAOP senders.
pub const DEFAULT_FRAMES_PER_PACKET: usize = 352;

/// `AirPlay` protocol generation selected for a receiver.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AirPlayTier {
    /// Classic `AirPlay` audio / RAOP.
    ClassicRaop,
    /// Modern `AirPlay` 2.
    AirPlay2,
}

/// Audio payload codec selected for the RAOP session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RaopCodec {
    /// Network-byte-order signed 16-bit linear PCM.
    PcmL16,
    /// Apple Lossless Audio Codec.
    AppleLossless,
}

/// Receiver-advertised media encryption requirement.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RaopEncryption {
    /// Receiver accepts an unencrypted media session.
    None,
    /// Classic RSA-wrapped AES media key.
    RsaAes,
    /// `MFi` authentication setup.
    MfiSap,
    /// FairPlay-protected session.
    FairPlay,
}

/// Receiver pairing requirement, distinct from an RTSP Digest password.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingRequirement {
    /// No protocol pairing is required.
    None,
    /// Legacy RAOP pair-verify is required.
    Legacy,
    /// Transient `HomeKit` Accessory Protocol pairing is required.
    HapTransient,
    /// Persisted `HomeKit` Accessory Protocol pairing is required.
    HapPersistent,
}

/// Media transport selected for a RAOP session.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MediaTransport {
    /// Separate UDP audio, control, and timing sockets.
    Udp,
    /// Interleaved RTP over the RTSP TCP connection.
    Tcp,
}

/// Explicit receiver capabilities selected by discovery or the diagnostic CLI.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReceiverProfile {
    /// `AirPlay` protocol generation.
    pub tier: AirPlayTier,
    /// Audio codec.
    pub codec: RaopCodec,
    /// Media encryption.
    pub encryption: RaopEncryption,
    /// Protocol pairing requirement.
    pub pairing: PairingRequirement,
    /// RTP transport.
    pub transport: MediaTransport,
}

impl ReceiverProfile {
    /// Fails at the first protocol operation not implemented by this milestone.
    pub fn validate(self) -> Result<(), CompatibilityError> {
        if self.tier == AirPlayTier::AirPlay2 {
            return Err(CompatibilityError::AirPlay2 {
                first_missing_operation: "HAP pair-verify and authenticated encrypted RTSP event channels",
            });
        }
        if self.pairing != PairingRequirement::None {
            return Err(CompatibilityError::Pairing {
                requirement: self.pairing,
                first_missing_operation: match self.pairing {
                    PairingRequirement::Legacy => "legacy RAOP pair-verify key agreement",
                    PairingRequirement::HapTransient | PairingRequirement::HapPersistent => {
                        "HAP pair-setup/pair-verify key agreement"
                    }
                    PairingRequirement::None => unreachable!(),
                },
            });
        }
        if self.encryption != RaopEncryption::None {
            return Err(CompatibilityError::Encryption {
                encryption: self.encryption,
                first_missing_operation: match self.encryption {
                    RaopEncryption::RsaAes => {
                        "RSA-OAEP wrapping of a random AES media key for rsaaeskey/aesiv SDP"
                    }
                    RaopEncryption::MfiSap => "MFi auth-setup key derivation",
                    RaopEncryption::FairPlay => "FairPlay session-key derivation",
                    RaopEncryption::None => unreachable!(),
                },
            });
        }
        if self.codec != RaopCodec::PcmL16 {
            return Err(CompatibilityError::Codec {
                codec: self.codec,
                first_missing_operation: "standards-conformant ALAC frame encoding",
            });
        }
        if self.transport != MediaTransport::Udp {
            return Err(CompatibilityError::Transport {
                transport: self.transport,
                first_missing_operation: "RTP-over-RTSP TCP framing and flow control",
            });
        }
        Ok(())
    }
}

impl Default for ReceiverProfile {
    fn default() -> Self {
        Self {
            tier: AirPlayTier::ClassicRaop,
            codec: RaopCodec::PcmL16,
            encryption: RaopEncryption::None,
            pairing: PairingRequirement::None,
            transport: MediaTransport::Udp,
        }
    }
}

/// Compatibility errors returned before connecting to an unsupported receiver.
#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum CompatibilityError {
    /// Full `AirPlay` 2 is a later milestone.
    #[error(
        "RAOP compatibility: AirPlay 2 is unsupported; first missing operation: {first_missing_operation}"
    )]
    AirPlay2 {
        /// First required operation absent from this implementation.
        first_missing_operation: &'static str,
    },
    /// Pairing protocols are intentionally not approximated.
    #[error(
        "RAOP compatibility: pairing requirement {requirement:?} is unsupported; first missing operation: {first_missing_operation}"
    )]
    Pairing {
        /// Receiver pairing mode.
        requirement: PairingRequirement,
        /// First required operation absent from this implementation.
        first_missing_operation: &'static str,
    },
    /// Protected media is intentionally not sent without real key establishment.
    #[error(
        "RAOP compatibility: encryption {encryption:?} is unsupported; first missing operation: {first_missing_operation}"
    )]
    Encryption {
        /// Receiver encryption mode.
        encryption: RaopEncryption,
        /// First required operation absent from this implementation.
        first_missing_operation: &'static str,
    },
    /// ALAC is not represented by raw PCM or a placeholder header.
    #[error(
        "RAOP compatibility: codec {codec:?} is unsupported; first missing operation: {first_missing_operation}"
    )]
    Codec {
        /// Receiver codec.
        codec: RaopCodec,
        /// First required operation absent from this implementation.
        first_missing_operation: &'static str,
    },
    /// The selected transport is not implemented.
    #[error(
        "RAOP compatibility: transport {transport:?} is unsupported; first missing operation: {first_missing_operation}"
    )]
    Transport {
        /// Receiver transport.
        transport: MediaTransport,
        /// First required operation absent from this implementation.
        first_missing_operation: &'static str,
    },
}

/// Bounded RTSP and RTP sender configuration.
#[derive(Clone)]
pub struct RaopClientConfig {
    /// Explicitly selected receiver compatibility profile.
    pub profile: ReceiverProfile,
    /// Optional local source address selected from the discovery interface.
    pub local_bind_ip: Option<IpAddr>,
    /// Perform the `AirTunes` 366 MFi-SAP server-authentication preflight.
    pub perform_auth_setup: bool,
    /// Maximum duration of one TCP connection attempt.
    pub connect_timeout: Duration,
    /// Maximum duration of an RTSP read or write.
    pub io_timeout: Duration,
    /// Delay between bounded connection attempts.
    pub retry_delay: Duration,
    /// Maximum number of TCP connection attempts.
    pub max_connect_attempts: u32,
    /// RTSP parser limits.
    pub message_limits: RtspMessageLimits,
    /// Number of audio frames in a normal RTP packet.
    pub frames_per_packet: usize,
    /// Maximum retained packets available for retransmission.
    pub retransmit_backlog_packets: usize,
    /// RTSP Digest username.
    pub username: String,
    /// Optional RTSP Digest password.
    pub password: Option<String>,
    /// User-Agent sent in every RTSP request.
    pub user_agent: String,
    /// Whether audio packets are paced according to their sample timestamps.
    pub pace_audio: bool,
    /// Short window after the last packet for retransmission/timing requests.
    pub post_stream_control_window: Duration,
    /// Sender-configured minimum sync offset, in frames.
    ///
    /// A larger bounded `Audio-Latency` returned by the receiver is honored.
    pub receiver_latency_frames: u32,
    /// Deterministic sequence override used by tests.
    pub initial_sequence: Option<u16>,
    /// Deterministic timestamp override used by tests.
    pub initial_timestamp: Option<u32>,
    /// Deterministic RTP SSRC override used by tests.
    pub ssrc: Option<u32>,
}

impl fmt::Debug for RaopClientConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RaopClientConfig")
            .field("profile", &self.profile)
            .field("local_bind_ip", &self.local_bind_ip)
            .field("perform_auth_setup", &self.perform_auth_setup)
            .field("connect_timeout", &self.connect_timeout)
            .field("io_timeout", &self.io_timeout)
            .field("retry_delay", &self.retry_delay)
            .field("max_connect_attempts", &self.max_connect_attempts)
            .field("message_limits", &self.message_limits)
            .field("frames_per_packet", &self.frames_per_packet)
            .field(
                "retransmit_backlog_packets",
                &self.retransmit_backlog_packets,
            )
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| "<redacted>"))
            .field("user_agent", &self.user_agent)
            .field("pace_audio", &self.pace_audio)
            .field(
                "post_stream_control_window",
                &self.post_stream_control_window,
            )
            .field("receiver_latency_frames", &self.receiver_latency_frames)
            .field("initial_sequence", &self.initial_sequence)
            .field("initial_timestamp", &self.initial_timestamp)
            .field("ssrc", &self.ssrc)
            .finish()
    }
}

impl Drop for RaopClientConfig {
    fn drop(&mut self) {
        if let Some(password) = &mut self.password {
            password.zeroize();
        }
    }
}

impl Default for RaopClientConfig {
    fn default() -> Self {
        Self {
            profile: ReceiverProfile::default(),
            local_bind_ip: None,
            perform_auth_setup: false,
            connect_timeout: Duration::from_secs(3),
            io_timeout: Duration::from_secs(3),
            retry_delay: Duration::from_millis(150),
            max_connect_attempts: 3,
            message_limits: RtspMessageLimits::default(),
            frames_per_packet: DEFAULT_FRAMES_PER_PACKET,
            retransmit_backlog_packets: 512,
            username: "iTunes".to_owned(),
            password: None,
            user_agent: "WinAirPlayAudio/0.1".to_owned(),
            pace_audio: true,
            post_stream_control_window: Duration::from_millis(100),
            receiver_latency_frames: MVP_SAMPLE_RATE,
            initial_sequence: None,
            initial_timestamp: None,
            ssrc: None,
        }
    }
}

impl RaopClientConfig {
    pub(crate) fn validate(&self) -> Result<(), RaopError> {
        self.profile.validate()?;
        if self
            .local_bind_ip
            .is_some_and(|address| address.is_unspecified() || address.is_multicast())
        {
            return Err(RaopError::InvalidConfiguration(
                "local_bind_ip must be a usable unicast address".to_owned(),
            ));
        }
        if self.max_connect_attempts == 0 {
            return Err(RaopError::InvalidConfiguration(
                "max_connect_attempts must be greater than zero".to_owned(),
            ));
        }
        if self.frames_per_packet == 0 || self.frames_per_packet > 4_096 {
            return Err(RaopError::InvalidConfiguration(format!(
                "frames_per_packet {} is outside 1..=4096",
                self.frames_per_packet
            )));
        }
        if self.retransmit_backlog_packets == 0 {
            return Err(RaopError::InvalidConfiguration(
                "retransmit_backlog_packets must be greater than zero".to_owned(),
            ));
        }
        if !(MIN_SYNC_LATENCY_FRAMES..=MAX_SYNC_LATENCY_FRAMES)
            .contains(&self.receiver_latency_frames)
        {
            return Err(RaopError::InvalidConfiguration(format!(
                "receiver_latency_frames {} is outside {}..={}",
                self.receiver_latency_frames, MIN_SYNC_LATENCY_FRAMES, MAX_SYNC_LATENCY_FRAMES
            )));
        }
        self.message_limits.validate()?;
        Ok(())
    }
}

#[cfg(test)]
mod secret_tests {
    use super::*;

    #[test]
    fn client_config_debug_redacts_password() {
        let mut config = RaopClientConfig::default();
        config.password = Some("never-print-this".to_owned());
        let debug = format!("{config:?}");
        assert!(debug.contains("<redacted>"));
        assert!(!debug.contains("never-print-this"));
    }

    #[test]
    fn configured_sync_latency_is_bounded() {
        for frames in [MIN_SYNC_LATENCY_FRAMES, MAX_SYNC_LATENCY_FRAMES] {
            let mut config = RaopClientConfig::default();
            config.receiver_latency_frames = frames;
            config.validate().unwrap();
        }
        for frames in [MIN_SYNC_LATENCY_FRAMES - 1, MAX_SYNC_LATENCY_FRAMES + 1] {
            let mut config = RaopClientConfig::default();
            config.receiver_latency_frames = frames;
            assert!(matches!(
                config.validate(),
                Err(RaopError::InvalidConfiguration(_))
            ));
        }
    }
}

/// Errors returned by the classic RAOP sender.
#[derive(Debug, Error)]
pub enum RaopError {
    /// Selected receiver capabilities exceed the implemented profile.
    #[error(transparent)]
    Compatibility(#[from] CompatibilityError),
    /// A bounded configuration value was invalid.
    #[error("RAOP configuration: {0}")]
    InvalidConfiguration(String),
    /// The operating system could not provide secure session entropy.
    #[error("RAOP secure randomness unavailable: {0}")]
    Entropy(String),
    /// A socket operation failed.
    #[error("RAOP {operation}: {source}")]
    Io {
        /// Operation that failed.
        operation: &'static str,
        /// Underlying operating-system error.
        #[source]
        source: io::Error,
    },
    /// A network operation exceeded its configured deadline.
    #[error("RAOP {operation}: timed out after {timeout:?}")]
    Timeout {
        /// Operation that timed out.
        operation: &'static str,
        /// Configured timeout.
        timeout: Duration,
    },
    /// All bounded connection attempts failed.
    #[error("RAOP connect: exhausted {attempts} attempts; last error: {last_error}")]
    RetryExhausted {
        /// Attempt count.
        attempts: u32,
        /// Last connection failure.
        last_error: String,
    },
    /// A malformed or oversized RTSP message was received.
    #[error("RAOP RTSP parse: {0}")]
    RtspParse(String),
    /// A malformed RTP packet or unsupported RTP header was received.
    #[error("RAOP RTP parse: {0}")]
    InvalidRtp(String),
    /// Receiver returned a non-success RTSP response.
    #[error("RAOP RTSP {method}: receiver returned {status} {reason}")]
    RtspRejected {
        /// Request method.
        method: String,
        /// RTSP status.
        status: u16,
        /// RTSP reason phrase.
        reason: String,
    },
    /// Receiver's `CSeq` did not match the request.
    #[error("RAOP RTSP {method}: expected CSeq {expected}, got {actual}")]
    CSeqMismatch {
        /// Request method.
        method: String,
        /// Sent sequence.
        expected: u32,
        /// Received sequence.
        actual: String,
    },
    /// Receiver requested a password but none was supplied.
    #[error("RAOP RTSP authentication: receiver requires a Digest password")]
    PasswordRequired,
    /// Receiver requested an unsupported HTTP authentication scheme.
    #[error("RAOP RTSP authentication: unsupported challenge: {0}")]
    UnsupportedAuthentication(String),
    /// Supplied credentials were rejected.
    #[error("RAOP RTSP authentication: receiver rejected the supplied Digest credentials")]
    AuthenticationRejected,
    /// A transport response was missing or invalid.
    #[error("RAOP SETUP transport: {0}")]
    InvalidTransport(String),
    /// A session method was used in the wrong state.
    #[error("RAOP session: operation {operation} is invalid in state {state}")]
    InvalidState {
        /// Attempted operation.
        operation: &'static str,
        /// Current state.
        state: &'static str,
    },
    /// Interleaved audio did not contain whole stereo frames.
    #[error("RAOP audio: {sample_count} samples do not contain whole stereo frames")]
    IncompleteAudioFrame {
        /// Interleaved sample count.
        sample_count: usize,
    },
}

pub(crate) fn map_io_error(
    operation: &'static str,
    timeout: Duration,
    source: io::Error,
) -> RaopError {
    if matches!(
        source.kind(),
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
    ) {
        RaopError::Timeout { operation, timeout }
    } else {
        RaopError::Io { operation, source }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsupported_profiles_name_the_first_missing_operation() {
        let profile = ReceiverProfile {
            tier: AirPlayTier::AirPlay2,
            ..ReceiverProfile::default()
        };
        assert!(matches!(
            profile.validate(),
            Err(CompatibilityError::AirPlay2 {
                first_missing_operation: "HAP pair-verify and authenticated encrypted RTSP event channels"
            })
        ));

        let profile = ReceiverProfile {
            codec: RaopCodec::AppleLossless,
            ..ReceiverProfile::default()
        };
        assert!(matches!(
            profile.validate(),
            Err(CompatibilityError::Codec {
                first_missing_operation: "standards-conformant ALAC frame encoding",
                ..
            })
        ));

        let profile = ReceiverProfile {
            encryption: RaopEncryption::RsaAes,
            ..ReceiverProfile::default()
        };
        assert!(matches!(
            profile.validate(),
            Err(CompatibilityError::Encryption {
                first_missing_operation: "RSA-OAEP wrapping of a random AES media key for rsaaeskey/aesiv SDP",
                ..
            })
        ));
    }
}
