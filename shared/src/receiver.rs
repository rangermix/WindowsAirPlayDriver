//! Deterministic receiver lifecycle state machine.

use std::collections::BTreeSet;
use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Network transports advertised by a classic RAOP receiver.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RaopTransport {
    Udp,
    Tcp,
}

/// Explicit reason why an online receiver cannot receive audio from this build.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UnsupportedReason {
    /// Only the metadata-oriented `_airplay._tcp` service was observed.
    MissingRaopService,
    /// An explicit `AirPlay` 2-only profile was advertised.
    AirPlay2Unsupported,
    /// The receiver requires protocol pairing rather than RTSP Digest authentication.
    PairingRequired,
    /// No media-encryption capability was advertised, so plaintext cannot be selected safely.
    MissingEncryptionAdvertisement,
    /// The receiver only permits classic RSA-wrapped AES media.
    RsaAesEncryptionRequired,
    /// The receiver only permits `MFiSAP` media authentication.
    MfiSapEncryptionRequired,
    /// The receiver only permits FairPlay-protected media.
    FairPlayEncryptionRequired,
    /// The advertised encryption identifiers are unknown to this build.
    UnsupportedEncryption,
    /// No audio codec capability was advertised.
    MissingCodecAdvertisement,
    /// The receiver does not advertise PCM/L16 codec code `0`.
    UnsupportedCodec,
    /// An advertised sample-rate list does not include 44.1 kHz.
    UnsupportedSampleRate,
    /// An advertised sample-size list does not include 16-bit samples.
    UnsupportedSampleSize,
    /// An advertised channel-count list does not include stereo.
    UnsupportedChannelCount,
    /// No RTP media transport was advertised.
    MissingTransportAdvertisement,
    /// The receiver does not advertise UDP media transport.
    UnsupportedTransport,
    /// Required capability fields conflict between advertisements.
    InconsistentAdvertisements,
}

/// Capability decision produced from all observations for one stable receiver.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ReceiverCapability {
    SupportedClassicRaop {
        transports: BTreeSet<RaopTransport>,
        password_required: bool,
    },
    Unsupported {
        reason: UnsupportedReason,
    },
}

impl ReceiverCapability {
    /// Whether the service may create a functional audio endpoint.
    #[must_use]
    pub const fn is_supported(&self) -> bool {
        matches!(self, Self::SupportedClassicRaop { .. })
    }

    /// Whether the advertised classic profile requires an RTSP Digest password.
    #[must_use]
    pub const fn password_required(&self) -> bool {
        matches!(
            self,
            Self::SupportedClassicRaop {
                password_required: true,
                ..
            }
        )
    }
}

/// Externally visible receiver lifecycle state.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReceiverState {
    Discovered,
    Resolving,
    OnlineUnsupported,
    OnlineSupported,
    EndpointCreating,
    EndpointReady,
    Connecting,
    Streaming,
    Recovering,
    GraceOffline,
    Removing,
    Removed,
}

impl fmt::Display for ReceiverState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

/// Input to the pure lifecycle reducer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReceiverSignal {
    BeginResolving,
    CapabilitiesResolved { supported: bool },
    BeginEndpointCreation,
    EndpointCreated,
    BeginConnecting,
    StreamStarted,
    StreamStopped,
    TransportFailed,
    RecoveryReady,
    Lost,
    Reappeared { supported: bool },
    GraceExpired,
    BeginRemoval,
    RemovalCompleted,
    RemovalCompletedUnsupported,
}

/// One deterministic state-machine result.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StateTransition {
    pub from: ReceiverState,
    pub to: ReceiverState,
}

impl StateTransition {
    #[must_use]
    pub const fn changed(self) -> bool {
        self.from as u8 != self.to as u8
    }
}

/// Invalid transitions are programming errors and are never silently ignored.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("receiver transition {signal:?} is invalid from {state:?}")]
pub struct TransitionError {
    pub state: ReceiverState,
    pub signal: ReceiverSignal,
}

/// Small, socket-independent receiver lifecycle reducer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReceiverStateMachine {
    state: ReceiverState,
    state_before_grace: Option<ReceiverState>,
}

impl Default for ReceiverStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl ReceiverStateMachine {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            state: ReceiverState::Discovered,
            state_before_grace: None,
        }
    }

    #[must_use]
    pub const fn state(&self) -> ReceiverState {
        self.state
    }

    /// Applies one signal. Inputs and state completely determine the result.
    pub fn apply(&mut self, signal: ReceiverSignal) -> Result<StateTransition, TransitionError> {
        let from = self.state;
        let to = match signal {
            ReceiverSignal::BeginResolving if from == ReceiverState::Discovered => {
                ReceiverState::Resolving
            }
            ReceiverSignal::CapabilitiesResolved { supported }
                if matches!(
                    from,
                    ReceiverState::Discovered
                        | ReceiverState::Resolving
                        | ReceiverState::OnlineSupported
                        | ReceiverState::OnlineUnsupported
                ) =>
            {
                online_state(supported)
            }
            ReceiverSignal::CapabilitiesResolved { supported } if is_endpoint_state(from) => {
                if supported {
                    from
                } else {
                    ReceiverState::OnlineUnsupported
                }
            }
            ReceiverSignal::BeginEndpointCreation if from == ReceiverState::OnlineSupported => {
                ReceiverState::EndpointCreating
            }
            ReceiverSignal::EndpointCreated if from == ReceiverState::EndpointCreating => {
                ReceiverState::EndpointReady
            }
            ReceiverSignal::BeginConnecting
                if matches!(
                    from,
                    ReceiverState::EndpointReady | ReceiverState::Recovering
                ) =>
            {
                ReceiverState::Connecting
            }
            ReceiverSignal::StreamStarted if from == ReceiverState::Connecting => {
                ReceiverState::Streaming
            }
            ReceiverSignal::StreamStopped
                if matches!(
                    from,
                    ReceiverState::Connecting
                        | ReceiverState::Streaming
                        | ReceiverState::Recovering
                ) =>
            {
                ReceiverState::EndpointReady
            }
            ReceiverSignal::TransportFailed
                if matches!(from, ReceiverState::Connecting | ReceiverState::Streaming) =>
            {
                ReceiverState::Recovering
            }
            ReceiverSignal::RecoveryReady if from == ReceiverState::Recovering => {
                ReceiverState::EndpointReady
            }
            ReceiverSignal::Lost
                if !matches!(
                    from,
                    ReceiverState::GraceOffline | ReceiverState::Removing | ReceiverState::Removed
                ) =>
            {
                self.state_before_grace = Some(from);
                ReceiverState::GraceOffline
            }
            ReceiverSignal::Reappeared { supported } if from == ReceiverState::GraceOffline => {
                restored_state(self.state_before_grace.take(), supported)
            }
            ReceiverSignal::GraceExpired if from == ReceiverState::GraceOffline => {
                self.state_before_grace = None;
                ReceiverState::Removing
            }
            ReceiverSignal::BeginRemoval if from != ReceiverState::Removed => {
                self.state_before_grace = None;
                ReceiverState::Removing
            }
            ReceiverSignal::RemovalCompleted if from == ReceiverState::Removing => {
                ReceiverState::Removed
            }
            ReceiverSignal::RemovalCompletedUnsupported if from == ReceiverState::Removing => {
                ReceiverState::OnlineUnsupported
            }
            _ => {
                return Err(TransitionError {
                    state: from,
                    signal,
                });
            }
        };

        self.state = to;
        Ok(StateTransition { from, to })
    }
}

const fn online_state(supported: bool) -> ReceiverState {
    if supported {
        ReceiverState::OnlineSupported
    } else {
        ReceiverState::OnlineUnsupported
    }
}

const fn is_endpoint_state(state: ReceiverState) -> bool {
    matches!(
        state,
        ReceiverState::EndpointCreating
            | ReceiverState::EndpointReady
            | ReceiverState::Connecting
            | ReceiverState::Streaming
            | ReceiverState::Recovering
    )
}

const fn restored_state(previous: Option<ReceiverState>, supported: bool) -> ReceiverState {
    if !supported {
        return ReceiverState::OnlineUnsupported;
    }

    match previous {
        Some(ReceiverState::EndpointCreating) => ReceiverState::EndpointCreating,
        Some(ReceiverState::EndpointReady) => ReceiverState::EndpointReady,
        Some(ReceiverState::Connecting | ReceiverState::Streaming | ReceiverState::Recovering) => {
            ReceiverState::Recovering
        }
        _ => ReceiverState::OnlineSupported,
    }
}

#[cfg(test)]
mod tests {
    use super::{ReceiverSignal, ReceiverState, ReceiverStateMachine, TransitionError};

    fn apply(machine: &mut ReceiverStateMachine, signal: ReceiverSignal) {
        machine.apply(signal).unwrap();
    }

    #[test]
    fn supported_receiver_reaches_streaming_then_recovers() {
        let mut machine = ReceiverStateMachine::new();
        apply(&mut machine, ReceiverSignal::BeginResolving);
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: true },
        );
        apply(&mut machine, ReceiverSignal::BeginEndpointCreation);
        apply(&mut machine, ReceiverSignal::EndpointCreated);
        apply(&mut machine, ReceiverSignal::BeginConnecting);
        apply(&mut machine, ReceiverSignal::StreamStarted);
        assert_eq!(machine.state(), ReceiverState::Streaming);

        apply(&mut machine, ReceiverSignal::TransportFailed);
        assert_eq!(machine.state(), ReceiverState::Recovering);
        apply(&mut machine, ReceiverSignal::BeginConnecting);
        apply(&mut machine, ReceiverSignal::StreamStarted);
        assert_eq!(machine.state(), ReceiverState::Streaming);
    }

    #[test]
    fn unsupported_receiver_never_enters_endpoint_creation() {
        let mut machine = ReceiverStateMachine::new();
        apply(&mut machine, ReceiverSignal::BeginResolving);
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: false },
        );
        assert_eq!(machine.state(), ReceiverState::OnlineUnsupported);

        let error = machine
            .apply(ReceiverSignal::BeginEndpointCreation)
            .unwrap_err();
        assert_eq!(
            error,
            TransitionError {
                state: ReceiverState::OnlineUnsupported,
                signal: ReceiverSignal::BeginEndpointCreation,
            }
        );
    }

    #[test]
    fn rapid_reappearance_preserves_ready_endpoint() {
        let mut machine = ReceiverStateMachine::new();
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: true },
        );
        apply(&mut machine, ReceiverSignal::BeginEndpointCreation);
        apply(&mut machine, ReceiverSignal::EndpointCreated);
        apply(&mut machine, ReceiverSignal::Lost);
        assert_eq!(machine.state(), ReceiverState::GraceOffline);

        apply(&mut machine, ReceiverSignal::Reappeared { supported: true });
        assert_eq!(machine.state(), ReceiverState::EndpointReady);
    }

    #[test]
    fn streaming_reappearance_requires_transport_recovery() {
        let mut machine = ReceiverStateMachine::new();
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: true },
        );
        apply(&mut machine, ReceiverSignal::BeginEndpointCreation);
        apply(&mut machine, ReceiverSignal::EndpointCreated);
        apply(&mut machine, ReceiverSignal::BeginConnecting);
        apply(&mut machine, ReceiverSignal::StreamStarted);
        apply(&mut machine, ReceiverSignal::Lost);
        apply(&mut machine, ReceiverSignal::Reappeared { supported: true });

        assert_eq!(machine.state(), ReceiverState::Recovering);
    }

    #[test]
    fn grace_expiry_has_explicit_removal_states() {
        let mut machine = ReceiverStateMachine::new();
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: true },
        );
        apply(&mut machine, ReceiverSignal::Lost);
        apply(&mut machine, ReceiverSignal::GraceExpired);
        assert_eq!(machine.state(), ReceiverState::Removing);
        apply(&mut machine, ReceiverSignal::RemovalCompleted);
        assert_eq!(machine.state(), ReceiverState::Removed);
    }

    #[test]
    fn endpoint_removal_can_leave_online_unsupported_metadata() {
        let mut machine = ReceiverStateMachine::new();
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: true },
        );
        apply(&mut machine, ReceiverSignal::Lost);
        apply(&mut machine, ReceiverSignal::GraceExpired);
        apply(&mut machine, ReceiverSignal::RemovalCompletedUnsupported);
        assert_eq!(machine.state(), ReceiverState::OnlineUnsupported);
    }

    #[test]
    fn capability_loss_removes_functional_state() {
        let mut machine = ReceiverStateMachine::new();
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: true },
        );
        apply(&mut machine, ReceiverSignal::BeginEndpointCreation);
        apply(&mut machine, ReceiverSignal::EndpointCreated);
        apply(
            &mut machine,
            ReceiverSignal::CapabilitiesResolved { supported: false },
        );

        assert_eq!(machine.state(), ReceiverState::OnlineUnsupported);
    }
}
