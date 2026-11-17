//! Discovery-to-endpoint orchestration.

use std::collections::HashMap;
use std::sync::mpsc::{Receiver, RecvTimeoutError, TryRecvError};
use std::time::{Duration, Instant};

use thiserror::Error;
use winairplay_shared::discovery::{
    DiscoveryBrowser, DiscoveryConfig, DiscoveryError, DiscoveryNotification, ReceiverSnapshot,
    RegistryEvent,
};
use winairplay_shared::receiver::ReceiverState;

use crate::config::ServiceConfig;
use crate::credentials::{CredentialError, CredentialStore};
use crate::endpoint::{
    EndpointBackend, EndpointError, EndpointManager, EndpointSpec, WindowsEndpointBackend,
};
use crate::streaming::{StreamRuntimeConfig, StreamTarget, StreamWorker, StreamingError};

const MAX_NOTIFICATIONS_PER_POLL: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EndpointAction {
    Created { receiver_id: String },
    Removed { receiver_id: String },
    PreservedDuringGrace { receiver_id: String },
    NoChange,
}

pub struct ReceiverEndpointCoordinator<B: EndpointBackend> {
    endpoints: EndpointManager<B>,
}

impl<B: EndpointBackend> ReceiverEndpointCoordinator<B> {
    pub fn new(backend: B) -> Self {
        Self {
            endpoints: EndpointManager::new(backend),
        }
    }

    #[cfg(test)]
    pub fn handle(&mut self, change: RegistryEvent) -> Result<EndpointAction, EndpointError> {
        self.handle_with_eligibility(change, false, true)
    }

    #[cfg(test)]
    pub fn handle_with_credentials(
        &mut self,
        change: RegistryEvent,
        credential_available: bool,
    ) -> Result<EndpointAction, EndpointError> {
        self.handle_with_eligibility(change, credential_available, true)
    }

    fn handle_with_eligibility(
        &mut self,
        change: RegistryEvent,
        credential_available: bool,
        stream_eligible: bool,
    ) -> Result<EndpointAction, EndpointError> {
        match change {
            RegistryEvent::Added { receiver }
            | RegistryEvent::Updated { receiver }
            | RegistryEvent::GraceCancelled { receiver } => {
                self.reconcile_receiver(&receiver, credential_available, stream_eligible)
            }
            RegistryEvent::GraceStarted { receiver, .. } => {
                Ok(EndpointAction::PreservedDuringGrace {
                    receiver_id: receiver.identity.to_string(),
                })
            }
            RegistryEvent::Removing { receiver } | RegistryEvent::Removed { receiver } => {
                self.remove_receiver(receiver.identity.as_str())
            }
        }
    }

    pub fn shutdown(&mut self) -> Vec<EndpointError> {
        self.endpoints.shutdown()
    }

    #[must_use]
    pub fn active_receiver_ids(&self) -> Vec<String> {
        let mut receivers = self
            .endpoints
            .active_receiver_ids()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        receivers.sort_unstable();
        receivers
    }

    fn reconcile_receiver(
        &mut self,
        receiver: &ReceiverSnapshot,
        credential_available: bool,
        stream_eligible: bool,
    ) -> Result<EndpointAction, EndpointError> {
        let receiver_id = receiver.identity.as_str();
        let endpoint_allowed = receiver.capability.is_supported()
            && (!receiver.capability.password_required() || credential_available)
            && stream_eligible
            && !matches!(
                receiver.state,
                ReceiverState::OnlineUnsupported
                    | ReceiverState::GraceOffline
                    | ReceiverState::Removing
                    | ReceiverState::Removed
            );
        if endpoint_allowed {
            let specification = EndpointSpec::new(receiver_id, receiver.display_name.as_str())?;
            if self.endpoints.ensure(&specification)? {
                Ok(EndpointAction::Created {
                    receiver_id: receiver_id.to_owned(),
                })
            } else {
                Ok(EndpointAction::NoChange)
            }
        } else {
            self.remove_receiver(receiver_id)
        }
    }

    fn remove_receiver(&mut self, receiver_id: &str) -> Result<EndpointAction, EndpointError> {
        if self.endpoints.remove(receiver_id)? {
            Ok(EndpointAction::Removed {
                receiver_id: receiver_id.to_owned(),
            })
        } else {
            Ok(EndpointAction::NoChange)
        }
    }
}

pub struct ServiceOrchestrator {
    browser: Option<DiscoveryBrowser>,
    notifications: Receiver<DiscoveryNotification>,
    coordinator: ReceiverEndpointCoordinator<WindowsEndpointBackend>,
    streams: HashMap<String, ManagedStream>,
    stream_config: StreamRuntimeConfig,
    credentials: CredentialStore,
    manage_endpoints: bool,
    observed_dropped_notifications: u64,
}

struct ManagedStream {
    target: StreamTarget,
    worker: Option<StreamWorker>,
    retry_delay: Duration,
    next_start: Instant,
    retry_requires_target_change: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct StreamReconciliation {
    credential_available: bool,
    endpoint_eligible: bool,
}

impl StreamReconciliation {
    const fn eligible(credential_available: bool) -> Self {
        Self {
            credential_available,
            endpoint_eligible: true,
        }
    }

    const fn withheld(credential_available: bool) -> Self {
        Self {
            credential_available,
            endpoint_eligible: false,
        }
    }
}

impl ManagedStream {
    fn start(target: StreamTarget, config: StreamRuntimeConfig) -> Result<Self, StreamingError> {
        let worker = StreamWorker::start(target.clone(), config)?;
        Ok(Self {
            target,
            worker: Some(worker),
            retry_delay: config.retry_initial,
            next_start: Instant::now(),
            retry_requires_target_change: false,
        })
    }

    fn should_start(&self, now: Instant) -> bool {
        self.worker.is_none() && !self.retry_requires_target_change && now >= self.next_start
    }
}

impl ServiceOrchestrator {
    pub fn start(config: &ServiceConfig) -> Result<Self, ServiceOrchestratorError> {
        let discovery_config = DiscoveryConfig {
            offline_grace: Duration::from_millis(config.offline_grace_ms),
            query_interval: config.discovery_query_interval(),
            txt_limits: config.txt_limits(),
            ..DiscoveryConfig::default()
        };
        let (browser, notifications) = DiscoveryBrowser::start(discovery_config)?;
        Ok(Self {
            browser: Some(browser),
            notifications,
            coordinator: ReceiverEndpointCoordinator::new(WindowsEndpointBackend::new(
                config.endpoint_create_timeout(),
            )),
            streams: HashMap::new(),
            stream_config: StreamRuntimeConfig::from(config),
            credentials: CredentialStore::default_store()?,
            manage_endpoints: config.manage_endpoints,
            observed_dropped_notifications: 0,
        })
    }

    pub fn poll(&mut self, timeout: Duration) -> Result<(), ServiceOrchestratorError> {
        let first = match self.notifications.recv_timeout(timeout) {
            Ok(notification) => Some(notification),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => {
                return Err(ServiceOrchestratorError::DiscoveryChannelClosed);
            }
        };
        if let Some(notification) = first {
            self.handle_notification(notification)?;
            for _ in 1..MAX_NOTIFICATIONS_PER_POLL {
                match self.notifications.try_recv() {
                    Ok(notification) => self.handle_notification(notification)?,
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        return Err(ServiceOrchestratorError::DiscoveryChannelClosed);
                    }
                }
            }
        }

        let dropped = self
            .browser
            .as_ref()
            .map_or(0, DiscoveryBrowser::dropped_notifications);
        if dropped > self.observed_dropped_notifications {
            let lost = dropped - self.observed_dropped_notifications;
            self.observed_dropped_notifications = dropped;
            return Err(ServiceOrchestratorError::DiscoveryNotificationsDropped(
                lost,
            ));
        }
        self.reconcile_stream_workers()?;
        Ok(())
    }

    pub fn shutdown(mut self) -> Result<(), ServiceOrchestratorError> {
        if let Some(browser) = self.browser.take() {
            browser.stop()?;
        }
        let stream_errors = self.stop_all_streams();
        let endpoint_errors = self.coordinator.shutdown();
        if stream_errors.is_empty() && endpoint_errors.is_empty() {
            Ok(())
        } else {
            Err(ServiceOrchestratorError::Shutdown {
                stream_errors,
                endpoint_errors,
            })
        }
    }

    fn handle_notification(
        &mut self,
        notification: DiscoveryNotification,
    ) -> Result<(), ServiceOrchestratorError> {
        match notification {
            DiscoveryNotification::Registry { change } if self.manage_endpoints => {
                let reconciliation = self.reconcile_stream_for_change(&change)?;
                let action = self.coordinator.handle_with_eligibility(
                    change,
                    reconciliation.credential_available,
                    reconciliation.endpoint_eligible,
                )?;
                tracing::info!(component = "endpoint", ?action);
            }
            DiscoveryNotification::Registry { change } => {
                tracing::info!(
                    component = "discovery",
                    ?change,
                    "observe-only registry change"
                );
            }
            DiscoveryNotification::SearchStarted { service_type } => {
                tracing::info!(component = "discovery", %service_type, "search started");
            }
            DiscoveryNotification::SearchStopped { service_type } => {
                tracing::info!(component = "discovery", %service_type, "search stopped");
            }
            DiscoveryNotification::ServiceFound {
                service_type,
                fullname,
            } => {
                tracing::debug!(component = "discovery", %service_type, %fullname, "service found");
            }
            DiscoveryNotification::Rejected {
                service_type,
                fullname,
                reason,
            } => {
                tracing::warn!(
                    component = "discovery",
                    %service_type,
                    %fullname,
                    %reason,
                    "service rejected"
                );
            }
            DiscoveryNotification::BackendError { operation, reason } => {
                tracing::error!(component = "discovery", %operation, %reason, "backend error");
            }
            DiscoveryNotification::InterfaceChanged { added, address } => {
                tracing::info!(
                    component = "discovery",
                    interface_added = added,
                    %address,
                    "interface address changed"
                );
            }
        }
        Ok(())
    }

    fn reconcile_stream_for_change(
        &mut self,
        change: &RegistryEvent,
    ) -> Result<StreamReconciliation, ServiceOrchestratorError> {
        match change {
            RegistryEvent::Added { receiver }
            | RegistryEvent::Updated { receiver }
            | RegistryEvent::GraceCancelled { receiver } => {
                let password = if receiver.capability.password_required() {
                    match self.credentials.read(receiver.identity.as_str()) {
                        Ok(password) => password,
                        Err(error) => {
                            tracing::error!(
                                component = "credential",
                                receiver_id = %receiver.identity,
                                recoverable = false,
                                %error,
                                "receiver credential is unreadable; withholding only this receiver until its credential changes"
                            );
                            self.remove_stream(receiver.identity.as_str());
                            return Ok(StreamReconciliation::withheld(false));
                        }
                    }
                } else {
                    None
                };
                let credential_available = password.is_some();
                match StreamTarget::from_snapshot_with_password(receiver, password) {
                    Ok(target) => {
                        let endpoint_eligible = self.ensure_stream(target)?;
                        return Ok(if endpoint_eligible {
                            StreamReconciliation::eligible(credential_available)
                        } else {
                            StreamReconciliation::withheld(credential_available)
                        });
                    }
                    Err(StreamingError::CredentialUnavailable(_)) => {
                        tracing::warn!(
                            component = "stream",
                            receiver_id = %receiver.identity,
                            "password-protected receiver withheld until a DPAPI credential is installed"
                        );
                        self.remove_stream(receiver.identity.as_str());
                        return Ok(StreamReconciliation::withheld(credential_available));
                    }
                    Err(
                        StreamingError::UnsupportedReceiver(_)
                        | StreamingError::NoUsableAddress { .. },
                    ) => {
                        self.remove_stream(receiver.identity.as_str());
                        return Ok(StreamReconciliation::withheld(credential_available));
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            RegistryEvent::GraceStarted { .. } => {
                // Preserve both endpoint and active connection during the bounded
                // grace interval. Removal owns the final teardown.
            }
            RegistryEvent::Removing { receiver } | RegistryEvent::Removed { receiver } => {
                self.remove_stream(receiver.identity.as_str());
            }
        }
        Ok(StreamReconciliation::withheld(false))
    }

    fn ensure_stream(&mut self, target: StreamTarget) -> Result<bool, StreamingError> {
        if let Some(stream) = self.streams.get(&target.receiver_id)
            && stream.target == target
        {
            return Ok(!stream.retry_requires_target_change);
        }
        self.remove_stream(&target.receiver_id);
        let receiver_id = target.receiver_id.clone();
        let stream = ManagedStream::start(target, self.stream_config)?;
        self.streams.insert(receiver_id, stream);
        Ok(true)
    }

    fn remove_stream(&mut self, receiver_id: &str) {
        let Some(stream) = self.streams.remove(receiver_id) else {
            return;
        };
        if let Some(worker) = stream.worker
            && let Err(error) = worker.stop()
        {
            tracing::warn!(
                component = "stream",
                %receiver_id,
                operation = "stop",
                %error
            );
        }
    }

    fn reconcile_stream_workers(&mut self) -> Result<(), ServiceOrchestratorError> {
        let now = Instant::now();
        let mut newly_withheld = Vec::new();
        for stream in self.streams.values_mut() {
            if stream
                .worker
                .as_ref()
                .is_some_and(StreamWorker::is_finished)
            {
                let worker = stream.worker.take().expect("finished worker is present");
                if let Err(error) = worker.stop() {
                    if error.retry_requires_target_change() {
                        stream.retry_requires_target_change = true;
                        newly_withheld.push(stream.target.receiver_id.clone());
                        tracing::error!(
                            component = "stream",
                            receiver_id = %stream.target.receiver_id,
                            operation = "worker terminated",
                            recoverable = false,
                            %error,
                            "automatic restart disabled until receiver addresses, profile, or credential changes"
                        );
                        continue;
                    }
                    tracing::warn!(
                        component = "stream",
                        receiver_id = %stream.target.receiver_id,
                        operation = "worker terminated",
                        restart_in_ms = stream.retry_delay.as_millis(),
                        %error
                    );
                }
                stream.next_start = now + stream.retry_delay;
                stream.retry_delay = stream
                    .retry_delay
                    .saturating_mul(2)
                    .min(self.stream_config.retry_max);
            }
            if stream.should_start(now) {
                match StreamWorker::start(stream.target.clone(), self.stream_config) {
                    Ok(worker) => {
                        stream.worker = Some(worker);
                    }
                    Err(error) => {
                        tracing::warn!(
                            component = "stream",
                            receiver_id = %stream.target.receiver_id,
                            operation = "restart",
                            restart_in_ms = stream.retry_delay.as_millis(),
                            %error
                        );
                        stream.next_start = now + stream.retry_delay;
                        stream.retry_delay = stream
                            .retry_delay
                            .saturating_mul(2)
                            .min(self.stream_config.retry_max);
                    }
                }
            }
        }
        for receiver_id in newly_withheld {
            let action = self.coordinator.remove_receiver(&receiver_id)?;
            tracing::info!(
                component = "endpoint",
                %receiver_id,
                ?action,
                "endpoint withheld after permanent RAOP target rejection"
            );
        }
        Ok(())
    }

    fn stop_all_streams(&mut self) -> Vec<StreamingError> {
        self.streams
            .drain()
            .filter_map(|(_, stream)| stream.worker)
            .filter_map(|worker| worker.stop().err())
            .collect()
    }
}

impl Drop for ServiceOrchestrator {
    fn drop(&mut self) {
        if let Some(browser) = self.browser.take()
            && let Err(error) = browser.stop()
        {
            tracing::error!(component = "discovery", operation = "stop", %error);
        }
        for error in self.stop_all_streams() {
            tracing::error!(component = "stream", operation = "shutdown", %error);
        }
        for error in self.coordinator.shutdown() {
            tracing::error!(component = "endpoint", operation = "shutdown", %error);
        }
    }
}

#[derive(Debug, Error)]
pub enum ServiceOrchestratorError {
    #[error(transparent)]
    Discovery(#[from] DiscoveryError),
    #[error(transparent)]
    Endpoint(#[from] EndpointError),
    #[error(transparent)]
    Streaming(#[from] StreamingError),
    #[error(transparent)]
    Credential(#[from] CredentialError),
    #[error("discovery notification channel closed unexpectedly")]
    DiscoveryChannelClosed,
    #[error(
        "discovery dropped {0} notifications; fail closed so endpoint state is reconstructed on restart"
    )]
    DiscoveryNotificationsDropped(u64),
    #[error(
        "service shutdown had stream errors {stream_errors:?} and endpoint errors {endpoint_errors:?}"
    )]
    Shutdown {
        stream_errors: Vec<StreamingError>,
        endpoint_errors: Vec<EndpointError>,
    },
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::fs;
    use std::net::{IpAddr, Ipv4Addr};
    use std::sync::mpsc;

    use winairplay_shared::discovery::{
        DiscoveryObservation, InterfaceKey, ReceiverSnapshot, ServiceKind, TxtLimits,
    };
    use winairplay_shared::receiver::{RaopTransport, ReceiverCapability, ReceiverState};

    use super::*;

    #[derive(Default)]
    struct FakeBackend {
        created: Vec<String>,
        closed: Vec<String>,
    }

    impl EndpointBackend for FakeBackend {
        type Handle = String;

        fn create(&mut self, specification: &EndpointSpec) -> Result<Self::Handle, EndpointError> {
            self.created.push(specification.receiver_id.clone());
            Ok(specification.receiver_id.clone())
        }

        fn close(&mut self, receiver_id: &str, _handle: Self::Handle) -> Result<(), EndpointError> {
            self.closed.push(receiver_id.to_owned());
            Ok(())
        }
    }

    fn snapshot(identity: &str, supported: bool, state: ReceiverState) -> ReceiverSnapshot {
        let fullname = format!("{identity}@Receiver._raop._tcp.local.");
        let observation = DiscoveryObservation::from_parts(
            ServiceKind::Raop,
            &fullname,
            "receiver.local.",
            7_000,
            InterfaceKey {
                index: 5,
                name: "Ethernet".to_owned(),
            },
            [IpAddr::V4(Ipv4Addr::LOCALHOST)],
            [
                ("cn", Some(b"0".to_vec())),
                ("et", Some(b"0".to_vec())),
                ("tp", Some(b"UDP".to_vec())),
            ],
            TxtLimits::default(),
        )
        .unwrap();
        ReceiverSnapshot {
            identity: observation.identity.clone(),
            display_name: "Receiver".to_owned(),
            capability: if supported {
                ReceiverCapability::SupportedClassicRaop {
                    transports: BTreeSet::from([RaopTransport::Udp]),
                    password_required: false,
                }
            } else {
                ReceiverCapability::Unsupported {
                    reason: winairplay_shared::receiver::UnsupportedReason::UnsupportedCodec,
                }
            },
            state,
            observations: vec![observation],
            last_seen_ms: 1,
            grace_deadline_ms: None,
        }
    }

    #[test]
    fn supported_add_creates_one_endpoint_and_update_does_not_duplicate() {
        let mut coordinator = ReceiverEndpointCoordinator::new(FakeBackend::default());
        let receiver = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        assert!(matches!(
            coordinator
                .handle(RegistryEvent::Added {
                    receiver: receiver.clone()
                })
                .unwrap(),
            EndpointAction::Created { .. }
        ));
        assert_eq!(
            coordinator
                .handle(RegistryEvent::Updated { receiver })
                .unwrap(),
            EndpointAction::NoChange
        );
        assert_eq!(coordinator.active_receiver_ids(), ["001122334455"]);
    }

    #[test]
    fn unsupported_receiver_never_creates_endpoint() {
        let mut coordinator = ReceiverEndpointCoordinator::new(FakeBackend::default());
        let action = coordinator
            .handle(RegistryEvent::Added {
                receiver: snapshot("001122334455", false, ReceiverState::OnlineUnsupported),
            })
            .unwrap();
        assert_eq!(action, EndpointAction::NoChange);
        assert!(coordinator.active_receiver_ids().is_empty());
    }

    #[test]
    fn stream_ineligibility_removes_and_keeps_endpoint_withheld() {
        let mut coordinator = ReceiverEndpointCoordinator::new(FakeBackend::default());
        let receiver = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        assert!(matches!(
            coordinator
                .handle_with_eligibility(
                    RegistryEvent::Added {
                        receiver: receiver.clone()
                    },
                    false,
                    true,
                )
                .unwrap(),
            EndpointAction::Created { .. }
        ));
        assert!(matches!(
            coordinator
                .handle_with_eligibility(
                    RegistryEvent::Updated {
                        receiver: receiver.clone()
                    },
                    false,
                    false,
                )
                .unwrap(),
            EndpointAction::Removed { .. }
        ));
        assert_eq!(
            coordinator
                .handle_with_eligibility(RegistryEvent::Updated { receiver }, false, false,)
                .unwrap(),
            EndpointAction::NoChange
        );
        assert!(coordinator.active_receiver_ids().is_empty());
    }

    #[test]
    fn blocked_target_fingerprint_suppresses_identical_reconciliation() {
        let receiver = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        let target = StreamTarget::from_snapshot(&receiver).unwrap();
        let now = Instant::now();
        let stream = ManagedStream {
            target: target.clone(),
            worker: None,
            retry_delay: Duration::from_millis(100),
            next_start: now,
            retry_requires_target_change: true,
        };
        assert!(!stream.should_start(now));

        let config = ServiceConfig::default();
        let (_sender, notifications) = mpsc::channel();
        let mut orchestrator = ServiceOrchestrator {
            browser: None,
            notifications,
            coordinator: ReceiverEndpointCoordinator::new(WindowsEndpointBackend::new(
                config.endpoint_create_timeout(),
            )),
            streams: HashMap::from([(target.receiver_id.clone(), stream)]),
            stream_config: StreamRuntimeConfig::from(&config),
            credentials: CredentialStore::at(std::env::temp_dir()),
            manage_endpoints: true,
            observed_dropped_notifications: 0,
        };
        let reconciliation = orchestrator
            .reconcile_stream_for_change(&RegistryEvent::Updated {
                receiver: receiver.clone(),
            })
            .unwrap();
        assert_eq!(reconciliation, StreamReconciliation::withheld(false));
        assert!(
            orchestrator
                .streams
                .get(receiver.identity.as_str())
                .unwrap()
                .retry_requires_target_change
        );

        let mut address_changed = receiver.clone();
        address_changed.observations[0].addresses =
            BTreeSet::from([IpAddr::V4(Ipv4Addr::new(192, 0, 2, 44))]);
        assert_ne!(
            target,
            StreamTarget::from_snapshot(&address_changed).unwrap()
        );

        let mut profile_changed = receiver;
        profile_changed.capability = ReceiverCapability::SupportedClassicRaop {
            transports: BTreeSet::from([RaopTransport::Udp, RaopTransport::Tcp]),
            password_required: false,
        };
        assert_ne!(
            target,
            StreamTarget::from_snapshot(&profile_changed).unwrap()
        );

        orchestrator.remove_stream(&target.receiver_id);
        assert!(!orchestrator.streams.contains_key(&target.receiver_id));
    }

    #[test]
    fn corrupt_receiver_credential_is_isolated_from_service_orchestration() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "winairplay-coordinator-credential-test-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("001122334455.dpapi"), b"not a DPAPI blob").unwrap();

        let config = ServiceConfig::default();
        let (_sender, notifications) = mpsc::channel();
        let mut orchestrator = ServiceOrchestrator {
            browser: None,
            notifications,
            coordinator: ReceiverEndpointCoordinator::new(WindowsEndpointBackend::new(
                config.endpoint_create_timeout(),
            )),
            streams: HashMap::new(),
            stream_config: StreamRuntimeConfig::from(&config),
            credentials: CredentialStore::at(directory.clone()),
            manage_endpoints: true,
            observed_dropped_notifications: 0,
        };
        let mut receiver = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        receiver.capability = ReceiverCapability::SupportedClassicRaop {
            transports: BTreeSet::from([RaopTransport::Udp]),
            password_required: true,
        };

        orchestrator
            .handle_notification(DiscoveryNotification::Registry {
                change: RegistryEvent::Added { receiver },
            })
            .unwrap();
        assert!(orchestrator.streams.is_empty());
        assert!(orchestrator.coordinator.active_receiver_ids().is_empty());

        drop(orchestrator);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn password_receiver_requires_an_installed_credential_before_endpoint_creation() {
        let mut coordinator = ReceiverEndpointCoordinator::new(FakeBackend::default());
        let mut receiver = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        receiver.capability = ReceiverCapability::SupportedClassicRaop {
            transports: BTreeSet::from([RaopTransport::Udp]),
            password_required: true,
        };
        assert_eq!(
            coordinator
                .handle(RegistryEvent::Added {
                    receiver: receiver.clone(),
                })
                .unwrap(),
            EndpointAction::NoChange
        );
        assert!(coordinator.active_receiver_ids().is_empty());
        assert!(matches!(
            coordinator
                .handle_with_credentials(RegistryEvent::Updated { receiver }, true)
                .unwrap(),
            EndpointAction::Created { .. }
        ));
    }

    #[test]
    fn grace_preserves_then_removing_closes_only_target() {
        let mut coordinator = ReceiverEndpointCoordinator::new(FakeBackend::default());
        let first = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        let second = snapshot("AABBCCDDEEFF", true, ReceiverState::OnlineSupported);
        coordinator
            .handle(RegistryEvent::Added {
                receiver: first.clone(),
            })
            .unwrap();
        coordinator
            .handle(RegistryEvent::Added {
                receiver: second.clone(),
            })
            .unwrap();

        let mut grace = first.clone();
        grace.state = ReceiverState::GraceOffline;
        assert!(matches!(
            coordinator
                .handle(RegistryEvent::GraceStarted {
                    receiver: grace,
                    deadline_ms: 9_000,
                })
                .unwrap(),
            EndpointAction::PreservedDuringGrace { .. }
        ));
        assert_eq!(coordinator.active_receiver_ids().len(), 2);

        let mut removing = first;
        removing.state = ReceiverState::Removing;
        coordinator
            .handle(RegistryEvent::Removing { receiver: removing })
            .unwrap();
        assert_eq!(coordinator.active_receiver_ids(), ["AABBCCDDEEFF"]);
    }

    #[test]
    fn address_update_keeps_same_endpoint_identity() {
        let mut coordinator = ReceiverEndpointCoordinator::new(FakeBackend::default());
        let receiver = snapshot("001122334455", true, ReceiverState::OnlineSupported);
        coordinator
            .handle(RegistryEvent::Added {
                receiver: receiver.clone(),
            })
            .unwrap();
        let mut changed = receiver;
        changed.observations[0].hostname = "new-host.local.".to_owned();
        changed.observations[0].addresses =
            BTreeSet::from([IpAddr::V4(Ipv4Addr::new(192, 0, 2, 44))]);
        assert_eq!(
            coordinator
                .handle(RegistryEvent::Updated { receiver: changed })
                .unwrap(),
            EndpointAction::NoChange
        );
        assert_eq!(coordinator.active_receiver_ids(), ["001122334455"]);
    }
}
