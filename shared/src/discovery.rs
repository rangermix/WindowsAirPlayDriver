//! DNS-SD parsing, interface-aware receiver registry, and mDNS browser.
//!
//! Socket callbacks are converted into bounded, owned observations before they
//! reach the lifecycle registry.  The registry is deliberately independent of
//! wall-clock time: callers pass monotonic milliseconds so grace-period tests
//! are deterministic.

use std::collections::{BTreeMap, BTreeSet};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use mdns_sd::{
    DaemonEvent, DaemonStatus, InterfaceId, ResolvedService, ScopedIp, ServiceDaemon, ServiceEvent,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::identity::{
    IdentityError, ReceiverIdentity, identity_from_airplay, identity_from_raop, service_instance,
};
use crate::raop::{MVP_BITS_PER_SAMPLE, MVP_CHANNELS, MVP_SAMPLE_RATE};
use crate::receiver::{
    RaopTransport, ReceiverCapability, ReceiverSignal, ReceiverState, ReceiverStateMachine,
    TransitionError, UnsupportedReason,
};

pub const RAOP_SERVICE_TYPE: &str = "_raop._tcp.local.";
pub const AIRPLAY_SERVICE_TYPE: &str = "_airplay._tcp.local.";
pub const DEFAULT_MDNS_PORT: u16 = 5_353;
pub const DEFAULT_DISCOVERY_QUERY_INTERVAL: Duration = Duration::from_secs(4);
pub const MIN_DISCOVERY_QUERY_INTERVAL: Duration = Duration::from_secs(1);
pub const MAX_DISCOVERY_QUERY_INTERVAL: Duration = Duration::from_mins(1);

const MAX_DNS_NAME_BYTES: usize = 255;
const MAX_INTERFACE_NAME_BYTES: usize = 128;
const MAX_ADDRESSES_PER_OBSERVATION: usize = 32;
const MAX_DISPLAY_NAME_CHARS: usize = 128;
const MAX_STATUS_FLAGS_HEX_DIGITS: usize = 16;
const STATUS_FLAG_PIN_REQUIRED: u64 = 1 << 3;
const STATUS_FLAG_PASSWORD_REQUIRED: u64 = 1 << 7;
const STATUS_FLAG_ONE_TIME_PAIRING_REQUIRED: u64 = 1 << 9;
const QUERY_PULSE_DURATION: Duration = Duration::from_millis(1_500);
const QUERY_PULSE_STOP_ACK_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_MISSED_QUERY_EPOCHS: u8 = 3;
const DAEMON_COMMAND_RETRY_TIMEOUT: Duration = Duration::from_millis(50);
const DAEMON_COMMAND_RETRY_DELAY: Duration = Duration::from_millis(2);
const DAEMON_SHUTDOWN_TIMEOUT: Duration = Duration::from_millis(500);
const MAX_QUERY_PULSE_DRAIN_EVENTS: usize = 256;

/// DNS-SD service types consumed by `WinAirPlayAudio`.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ServiceKind {
    Raop,
    #[serde(rename = "airplay")]
    AirPlay,
}

impl ServiceKind {
    #[must_use]
    pub const fn service_type(self) -> &'static str {
        match self {
            Self::Raop => RAOP_SERVICE_TYPE,
            Self::AirPlay => AIRPLAY_SERVICE_TYPE,
        }
    }

    pub fn from_service_type(service_type: &str) -> Result<Self, DiscoveryError> {
        if service_type.eq_ignore_ascii_case(RAOP_SERVICE_TYPE) {
            Ok(Self::Raop)
        } else if service_type.eq_ignore_ascii_case(AIRPLAY_SERVICE_TYPE) {
            Ok(Self::AirPlay)
        } else {
            Err(DiscoveryError::UnsupportedServiceType(
                service_type.to_owned(),
            ))
        }
    }
}

/// Case-normalised key for all interface observations of one DNS-SD service.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
pub struct ServiceKey {
    pub kind: ServiceKind,
    pub fullname: String,
}

impl ServiceKey {
    #[must_use]
    pub fn new(kind: ServiceKind, fullname: &str) -> Self {
        Self {
            kind,
            fullname: fullname.to_ascii_lowercase(),
        }
    }
}

/// OS interface scope retained from `mdns-sd`.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
pub struct InterfaceKey {
    pub index: u32,
    pub name: String,
}

impl InterfaceKey {
    #[must_use]
    pub fn unknown() -> Self {
        Self {
            index: 0,
            name: String::new(),
        }
    }
}

impl From<&InterfaceId> for InterfaceKey {
    fn from(value: &InterfaceId) -> Self {
        Self {
            index: value.index,
            name: value.name.clone(),
        }
    }
}

/// Identity of one service observation on one interface.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
pub struct ObservationKey {
    pub service: ServiceKey,
    pub interface: InterfaceKey,
}

/// Parsed TXT properties. Keys are lower-case and values are validated UTF-8.
pub type TxtMap = BTreeMap<String, Option<String>>;

/// Defensive bounds applied before TXT data reaches capability logic or logs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TxtLimits {
    pub max_records: usize,
    pub max_total_bytes: usize,
    pub max_value_bytes: usize,
}

impl Default for TxtLimits {
    fn default() -> Self {
        Self {
            max_records: 64,
            max_total_bytes: 4_096,
            max_value_bytes: 1_024,
        }
    }
}

/// One resolved service/interface observation owned by the registry.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct DiscoveryObservation {
    pub identity: ReceiverIdentity,
    pub key: ObservationKey,
    pub service_fullname: String,
    pub hostname: String,
    pub port: u16,
    pub addresses: BTreeSet<IpAddr>,
    pub txt: TxtMap,
    pub display_name: String,
}

impl DiscoveryObservation {
    /// Constructs and validates a synthetic or backend-independent observation.
    #[allow(clippy::too_many_arguments)]
    pub fn from_parts<I, K, V>(
        kind: ServiceKind,
        fullname: &str,
        hostname: &str,
        port: u16,
        interface: InterfaceKey,
        addresses: I,
        properties: K,
        limits: TxtLimits,
    ) -> Result<Self, DiscoveryError>
    where
        I: IntoIterator<Item = IpAddr>,
        K: IntoIterator<Item = (V, Option<Vec<u8>>)>,
        V: AsRef<str>,
    {
        validate_dns_name("service fullname", fullname)?;
        validate_dns_name("hostname", hostname)?;
        validate_interface(&interface)?;
        if port == 0 {
            return Err(DiscoveryError::InvalidPort);
        }

        let addresses = validated_addresses(addresses)?;
        let txt = parse_txt_properties(properties, limits)?;
        let identity = derive_identity(kind, fullname, &txt)?;
        let display_name = derive_display_name(kind, fullname, &txt);

        Ok(Self {
            identity,
            key: ObservationKey {
                service: ServiceKey::new(kind, fullname),
                interface,
            },
            service_fullname: fullname.to_owned(),
            hostname: hostname.to_ascii_lowercase(),
            port,
            addresses,
            txt,
            display_name,
        })
    }
}

/// Rejects malformed, duplicated, non-textual, or oversized TXT properties.
pub fn parse_txt_properties<I, K>(
    properties: I,
    limits: TxtLimits,
) -> Result<TxtMap, DiscoveryError>
where
    I: IntoIterator<Item = (K, Option<Vec<u8>>)>,
    K: AsRef<str>,
{
    if limits.max_records == 0 || limits.max_total_bytes == 0 || limits.max_value_bytes == 0 {
        return Err(DiscoveryError::InvalidTxtLimits);
    }

    let mut parsed = BTreeMap::new();
    let mut count = 0_usize;
    let mut total_bytes = 0_usize;

    for (key, value) in properties {
        count = count
            .checked_add(1)
            .ok_or(DiscoveryError::TxtTooManyRecords)?;
        if count > limits.max_records {
            return Err(DiscoveryError::TxtTooManyRecords);
        }

        let key = key.as_ref();
        if key.is_empty()
            || key.len() > u8::MAX as usize
            || !key.bytes().all(|byte| (0x20..=0x7e).contains(&byte))
            || key.contains('=')
        {
            return Err(DiscoveryError::InvalidTxtKey(key.to_owned()));
        }
        let canonical_key = key.to_ascii_lowercase();
        if parsed.contains_key(&canonical_key) {
            return Err(DiscoveryError::DuplicateTxtKey(canonical_key));
        }

        let value_length = value.as_ref().map_or(0, Vec::len);
        if value_length > limits.max_value_bytes {
            return Err(DiscoveryError::TxtValueTooLarge {
                key: canonical_key,
                actual: value_length,
                maximum: limits.max_value_bytes,
            });
        }
        let record_length = key
            .len()
            .checked_add(usize::from(value.is_some()))
            .and_then(|size| size.checked_add(value_length))
            .ok_or(DiscoveryError::TxtRecordTooLarge)?;
        if record_length > u8::MAX as usize {
            return Err(DiscoveryError::TxtRecordTooLarge);
        }
        total_bytes = total_bytes
            .checked_add(record_length)
            .ok_or(DiscoveryError::TxtRecordTooLarge)?;
        if total_bytes > limits.max_total_bytes {
            return Err(DiscoveryError::TxtTotalTooLarge {
                actual: total_bytes,
                maximum: limits.max_total_bytes,
            });
        }

        let value = value
            .map(|bytes| {
                let value = String::from_utf8(bytes)
                    .map_err(|_| DiscoveryError::InvalidTxtUtf8(canonical_key.clone()))?;
                if value.chars().any(char::is_control) {
                    return Err(DiscoveryError::InvalidTxtControlCharacter(
                        canonical_key.clone(),
                    ));
                }
                Ok(value)
            })
            .transpose()?;
        parsed.insert(canonical_key, value);
    }

    Ok(parsed)
}

/// Converts one resolved mDNS snapshot into one observation per interface.
pub fn observations_from_resolved(
    resolved: &ResolvedService,
    limits: TxtLimits,
) -> Result<Vec<DiscoveryObservation>, DiscoveryError> {
    let kind = ServiceKind::from_service_type(&resolved.ty_domain)?;
    let properties = resolved
        .get_properties()
        .iter()
        .map(|property| (property.key(), property.val().map(<[u8]>::to_vec)))
        .collect::<Vec<_>>();

    let mut addresses_by_interface: BTreeMap<InterfaceKey, BTreeSet<IpAddr>> = BTreeMap::new();
    for scoped_address in resolved.get_addresses() {
        match scoped_address {
            ScopedIp::V4(ipv4) if ipv4.interface_ids().is_empty() => {
                addresses_by_interface
                    .entry(InterfaceKey::unknown())
                    .or_default()
                    .insert(IpAddr::V4(*ipv4.addr()));
            }
            ScopedIp::V4(ipv4) => {
                for interface in ipv4.interface_ids() {
                    addresses_by_interface
                        .entry(interface.into())
                        .or_default()
                        .insert(IpAddr::V4(*ipv4.addr()));
                }
            }
            ScopedIp::V6(ipv6) => {
                addresses_by_interface
                    .entry(ipv6.scope_id().into())
                    .or_default()
                    .insert(IpAddr::V6(*ipv6.addr()));
            }
            _ => {}
        }
    }

    if addresses_by_interface.is_empty() {
        return Err(DiscoveryError::NoUsableAddresses);
    }

    addresses_by_interface
        .into_iter()
        .map(|(interface, addresses)| {
            DiscoveryObservation::from_parts(
                kind,
                resolved.get_fullname(),
                resolved.get_hostname(),
                resolved.get_port(),
                interface,
                addresses,
                properties.clone(),
                limits,
            )
        })
        .collect()
}

/// Immutable receiver view shared with the service and diagnostic CLI.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ReceiverSnapshot {
    pub identity: ReceiverIdentity,
    pub display_name: String,
    pub capability: ReceiverCapability,
    pub state: ReceiverState,
    pub observations: Vec<DiscoveryObservation>,
    pub last_seen_ms: u64,
    pub grace_deadline_ms: Option<u64>,
}

/// Deterministic output from a registry mutation.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum RegistryEvent {
    Added {
        receiver: ReceiverSnapshot,
    },
    Updated {
        receiver: ReceiverSnapshot,
    },
    GraceStarted {
        receiver: ReceiverSnapshot,
        deadline_ms: u64,
    },
    GraceCancelled {
        receiver: ReceiverSnapshot,
    },
    Removing {
        receiver: ReceiverSnapshot,
    },
    Removed {
        receiver: ReceiverSnapshot,
    },
}

#[derive(Clone, Debug)]
struct ReceiverRecord {
    identity: ReceiverIdentity,
    display_name: String,
    capability: ReceiverCapability,
    machine: ReceiverStateMachine,
    observations: BTreeMap<ObservationKey, DiscoveryObservation>,
    last_seen_ms: u64,
    grace_deadline_ms: Option<u64>,
    grace_recovery_requires_supported: bool,
}

impl ReceiverRecord {
    fn snapshot(&self) -> ReceiverSnapshot {
        ReceiverSnapshot {
            identity: self.identity.clone(),
            display_name: self.display_name.clone(),
            capability: self.capability.clone(),
            state: self.machine.state(),
            observations: self.observations.values().cloned().collect(),
            last_seen_ms: self.last_seen_ms,
            grace_deadline_ms: self.grace_deadline_ms,
        }
    }

    fn recompute(&mut self) {
        self.display_name = self
            .observations
            .values()
            .map(|observation| {
                (
                    observation.key.service.kind != ServiceKind::Raop,
                    observation.display_name.clone(),
                )
            })
            .min()
            .map_or_else(|| "AirPlay Receiver".to_owned(), |(_, name)| name);
        self.capability = classify_observations(self.observations.values());
    }

    fn reserves_supported_slot(&self) -> bool {
        self.capability.is_supported()
            || (self.machine.state() == ReceiverState::GraceOffline
                && self.grace_recovery_requires_supported)
    }
}

/// Hard admission bounds for discovery state retained by the process.
///
/// `max_supported_receivers` is intentionally lower than the general receiver
/// limit because every supported receiver can result in a worker and a
/// software device node. Unsupported advertisements remain observable without
/// being allowed to exhaust those more expensive resources.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RegistryLimits {
    pub max_receivers: usize,
    pub max_supported_receivers: usize,
    pub max_known_services: usize,
    pub max_services_per_receiver: usize,
    pub max_observations: usize,
    pub max_observations_per_receiver: usize,
}

impl Default for RegistryLimits {
    fn default() -> Self {
        Self {
            max_receivers: 64,
            max_supported_receivers: 16,
            max_known_services: 256,
            max_services_per_receiver: 8,
            max_observations: 512,
            max_observations_per_receiver: 32,
        }
    }
}

impl RegistryLimits {
    const fn is_valid(self) -> bool {
        self.max_receivers != 0
            && self.max_supported_receivers != 0
            && self.max_supported_receivers <= self.max_receivers
            && self.max_known_services != 0
            && self.max_services_per_receiver != 0
            && self.max_services_per_receiver <= self.max_known_services
            && self.max_observations != 0
            && self.max_observations_per_receiver != 0
            && self.max_observations_per_receiver <= self.max_observations
            && self.max_services_per_receiver <= self.max_observations_per_receiver
    }
}

#[derive(Clone, Debug)]
struct KnownService {
    identity: ReceiverIdentity,
    quarantine_deadline_ms: Option<u64>,
}

impl KnownService {
    fn protects_identity_at(&self, now_ms: u64) -> bool {
        self.quarantine_deadline_ms
            .is_none_or(|deadline| now_ms < deadline)
    }
}

/// Interface-aware, deduplicating receiver registry.
#[derive(Clone, Debug)]
pub struct ReceiverRegistry {
    grace_ms: u64,
    limits: RegistryLimits,
    receivers: BTreeMap<ReceiverIdentity, ReceiverRecord>,
    known_services: BTreeMap<ServiceKey, KnownService>,
}

impl ReceiverRegistry {
    #[must_use]
    pub fn new(offline_grace: Duration) -> Self {
        Self::with_limits(offline_grace, RegistryLimits::default())
            .expect("default discovery registry limits are valid")
    }

    /// Creates an empty registry with explicit defensive admission bounds.
    pub fn with_limits(
        offline_grace: Duration,
        limits: RegistryLimits,
    ) -> Result<Self, RegistryError> {
        if !limits.is_valid() {
            return Err(RegistryError::InvalidLimits);
        }
        Ok(Self {
            grace_ms: duration_millis(offline_grace),
            limits,
            receivers: BTreeMap::new(),
            known_services: BTreeMap::new(),
        })
    }

    /// Reconstructs a fresh registry in deterministic service/key order.
    pub fn reconstruct(
        offline_grace: Duration,
        observations: impl IntoIterator<Item = DiscoveryObservation>,
        now_ms: u64,
    ) -> Result<Self, RegistryError> {
        Self::reconstruct_with_limits(
            offline_grace,
            RegistryLimits::default(),
            observations,
            now_ms,
        )
    }

    /// Reconstructs a bounded registry in deterministic service/key order.
    pub fn reconstruct_with_limits(
        offline_grace: Duration,
        limits: RegistryLimits,
        observations: impl IntoIterator<Item = DiscoveryObservation>,
        now_ms: u64,
    ) -> Result<Self, RegistryError> {
        if !limits.is_valid() {
            return Err(RegistryError::InvalidLimits);
        }
        let mut grouped: BTreeMap<ServiceKey, BTreeMap<ObservationKey, DiscoveryObservation>> =
            BTreeMap::new();
        let mut supplied_by_service = BTreeMap::<ServiceKey, usize>::new();
        let mut unique_observations = 0_usize;
        for (supplied_observations, observation) in observations.into_iter().enumerate() {
            let service = observation.key.service.clone();
            if supplied_observations >= limits.max_observations {
                return Err(RegistryError::ObservationLimitExceeded {
                    maximum: limits.max_observations,
                });
            }
            if !grouped.contains_key(&service) && grouped.len() >= limits.max_known_services {
                return Err(RegistryError::KnownServiceLimitExceeded {
                    maximum: limits.max_known_services,
                });
            }
            let supplied_for_service = supplied_by_service.entry(service.clone()).or_default();
            if *supplied_for_service >= limits.max_observations_per_receiver {
                return Err(RegistryError::ReceiverObservationLimitExceeded {
                    maximum: limits.max_observations_per_receiver,
                });
            }
            *supplied_for_service += 1;
            let service_observations = grouped.entry(service).or_default();
            if let Some(previous) = service_observations.get(&observation.key) {
                if previous != &observation {
                    return Err(RegistryError::ConflictingDuplicateObservation);
                }
                continue;
            }
            if unique_observations >= limits.max_observations {
                return Err(RegistryError::ObservationLimitExceeded {
                    maximum: limits.max_observations,
                });
            }
            if service_observations.len() >= limits.max_observations_per_receiver {
                return Err(RegistryError::ReceiverObservationLimitExceeded {
                    maximum: limits.max_observations_per_receiver,
                });
            }
            unique_observations += 1;
            service_observations.insert(observation.key.clone(), observation);
        }

        let mut registry = Self::with_limits(offline_grace, limits)?;
        for (service, service_observations) in grouped {
            let _ = registry.replace_service_snapshot(
                service,
                service_observations.into_values(),
                now_ms,
            )?;
        }
        Ok(registry)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.receivers.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.receivers.is_empty()
    }

    #[must_use]
    pub fn get(&self, identity: &ReceiverIdentity) -> Option<ReceiverSnapshot> {
        self.receivers.get(identity).map(ReceiverRecord::snapshot)
    }

    #[must_use]
    pub fn snapshots(&self) -> Vec<ReceiverSnapshot> {
        self.receivers
            .values()
            .map(ReceiverRecord::snapshot)
            .collect()
    }

    /// Atomically replaces every interface observation for a DNS-SD service.
    ///
    /// This is the normal operation for `ServiceResolved`: interfaces omitted
    /// from the latest resolve are removed without disturbing other services
    /// belonging to the same physical receiver.
    #[allow(clippy::needless_pass_by_value)]
    pub fn replace_service_snapshot(
        &mut self,
        service: ServiceKey,
        observations: impl IntoIterator<Item = DiscoveryObservation>,
        now_ms: u64,
    ) -> Result<Vec<RegistryEvent>, RegistryError> {
        let (incoming, incoming_identity) = collect_service_snapshot(
            &service,
            observations,
            self.limits.max_observations_per_receiver,
        )?;
        if incoming.is_empty() {
            return self.remove_service(&service, now_ms);
        }
        let identity = incoming_identity.ok_or(RegistryError::EmptySnapshot)?;

        if self.known_services.get(&service).is_some_and(|existing| {
            existing.protects_identity_at(now_ms) && existing.identity != identity
        }) {
            return Err(RegistryError::ServiceIdentityChanged);
        }
        let existing_identities = self.identities_for_service(&service);
        if existing_identities
            .iter()
            .any(|existing| existing != &identity)
        {
            return Err(RegistryError::ServiceIdentityChanged);
        }

        self.validate_admission(&service, &identity, &incoming, now_ms)?;
        let before = self.get(&identity);
        self.expire_known_services(now_ms);
        self.remove_service_observations_without_lifecycle(&service);
        self.known_services.insert(
            service.clone(),
            KnownService {
                identity: identity.clone(),
                quarantine_deadline_ms: None,
            },
        );

        let is_new = !self.receivers.contains_key(&identity);
        let record = self
            .receivers
            .entry(identity.clone())
            .or_insert_with(|| ReceiverRecord {
                identity: identity.clone(),
                display_name: "AirPlay Receiver".to_owned(),
                capability: ReceiverCapability::Unsupported {
                    reason: UnsupportedReason::MissingRaopService,
                },
                machine: ReceiverStateMachine::new(),
                observations: BTreeMap::new(),
                last_seen_ms: now_ms,
                grace_deadline_ms: None,
                grace_recovery_requires_supported: false,
            });
        for (key, observation) in incoming {
            record.observations.insert(key, observation);
        }
        record.last_seen_ms = now_ms;
        record.recompute();

        let was_gracing = record.machine.state() == ReceiverState::GraceOffline;
        let grace_cancelled = was_gracing
            && (!record.grace_recovery_requires_supported || record.capability.is_supported());
        if is_new {
            record.machine.apply(ReceiverSignal::BeginResolving)?;
            record.machine.apply(ReceiverSignal::CapabilitiesResolved {
                supported: record.capability.is_supported(),
            })?;
        } else if grace_cancelled {
            record.machine.apply(ReceiverSignal::Reappeared {
                supported: record.capability.is_supported(),
            })?;
            record.grace_deadline_ms = None;
            record.grace_recovery_requires_supported = false;
        } else if !was_gracing {
            record.machine.apply(ReceiverSignal::CapabilitiesResolved {
                supported: record.capability.is_supported(),
            })?;
        }

        let after = record.snapshot();
        if is_new {
            Ok(vec![RegistryEvent::Added { receiver: after }])
        } else if grace_cancelled {
            Ok(vec![RegistryEvent::GraceCancelled { receiver: after }])
        } else if before.as_ref() == Some(&after) {
            Ok(Vec::new())
        } else {
            Ok(vec![RegistryEvent::Updated { receiver: after }])
        }
    }

    /// Removes only one interface observation.
    pub fn remove_observation(
        &mut self,
        key: &ObservationKey,
        now_ms: u64,
    ) -> Result<Vec<RegistryEvent>, RegistryError> {
        let identities = self.identities_for_service(&key.service);
        let mut events = Vec::new();
        for identity in identities {
            let before = self.get(&identity);
            let Some(record) = self.receivers.get_mut(&identity) else {
                continue;
            };
            record.observations.remove(key);
            events.extend(update_after_removal(
                record,
                before.as_ref(),
                now_ms,
                self.grace_ms,
            )?);
        }
        if self.identities_for_service(&key.service).is_empty() {
            self.quarantine_service(&key.service, now_ms);
        }
        Ok(events)
    }

    /// Removes all interface observations for a DNS-SD service.
    pub fn remove_service(
        &mut self,
        service: &ServiceKey,
        now_ms: u64,
    ) -> Result<Vec<RegistryEvent>, RegistryError> {
        self.quarantine_service(service, now_ms);
        let identities = self.identities_for_service(service);
        let mut events = Vec::new();
        for identity in identities {
            let before = self.get(&identity);
            let Some(record) = self.receivers.get_mut(&identity) else {
                continue;
            };
            record.observations.retain(|key, _| &key.service != service);
            events.extend(update_after_removal(
                record,
                before.as_ref(),
                now_ms,
                self.grace_ms,
            )?);
        }
        Ok(events)
    }

    /// Expires offline grace periods and completes deterministic registry removal.
    pub fn tick(&mut self, now_ms: u64) -> Result<Vec<RegistryEvent>, RegistryError> {
        self.expire_known_services(now_ms);
        let expired = self
            .receivers
            .iter()
            .filter_map(|(identity, record)| {
                record
                    .grace_deadline_ms
                    .filter(|deadline| now_ms >= *deadline)
                    .map(|_| identity.clone())
            })
            .collect::<Vec<_>>();

        let mut events = Vec::with_capacity(expired.len().saturating_mul(2));
        for identity in expired {
            let Some(record) = self.receivers.get_mut(&identity) else {
                continue;
            };
            record.machine.apply(ReceiverSignal::GraceExpired)?;
            record.grace_deadline_ms = None;
            record.grace_recovery_requires_supported = false;
            events.push(RegistryEvent::Removing {
                receiver: record.snapshot(),
            });
            if record.observations.is_empty() {
                record.machine.apply(ReceiverSignal::RemovalCompleted)?;
                events.push(RegistryEvent::Removed {
                    receiver: record.snapshot(),
                });
                self.receivers.remove(&identity);
                self.known_services
                    .retain(|_, service| service.identity != identity);
            } else {
                record
                    .machine
                    .apply(ReceiverSignal::RemovalCompletedUnsupported)?;
                events.push(RegistryEvent::Updated {
                    receiver: record.snapshot(),
                });
            }
        }
        Ok(events)
    }

    /// Applies service/endpoint/transport lifecycle signals to an existing receiver.
    pub fn transition(
        &mut self,
        identity: &ReceiverIdentity,
        signal: ReceiverSignal,
    ) -> Result<RegistryEvent, RegistryError> {
        let record = self
            .receivers
            .get_mut(identity)
            .ok_or_else(|| RegistryError::ReceiverNotFound(identity.clone()))?;
        record.machine.apply(signal)?;
        Ok(RegistryEvent::Updated {
            receiver: record.snapshot(),
        })
    }

    fn identities_for_service(&self, service: &ServiceKey) -> BTreeSet<ReceiverIdentity> {
        self.receivers
            .iter()
            .filter(|(_, record)| {
                record
                    .observations
                    .keys()
                    .any(|key| &key.service == service)
            })
            .map(|(identity, _)| identity.clone())
            .collect()
    }

    fn active_service_keys(&self) -> BTreeSet<ServiceKey> {
        self.receivers
            .values()
            .flat_map(|record| record.observations.keys())
            .map(|key| key.service.clone())
            .collect()
    }

    fn remove_service_observations_without_lifecycle(&mut self, service: &ServiceKey) {
        for record in self.receivers.values_mut() {
            record.observations.retain(|key, _| &key.service != service);
        }
    }

    fn validate_admission(
        &self,
        service: &ServiceKey,
        identity: &ReceiverIdentity,
        incoming: &BTreeMap<ObservationKey, DiscoveryObservation>,
        now_ms: u64,
    ) -> Result<(), RegistryError> {
        let existing = self.receivers.get(identity);
        let receiver_count = self.receivers.len() + usize::from(existing.is_none());
        if receiver_count > self.limits.max_receivers {
            return Err(RegistryError::ReceiverLimitExceeded {
                maximum: self.limits.max_receivers,
            });
        }

        let existing_service_observations = self
            .receivers
            .values()
            .map(|record| {
                record
                    .observations
                    .keys()
                    .filter(|key| &key.service == service)
                    .count()
            })
            .sum::<usize>();
        let observation_count = self
            .receivers
            .values()
            .map(|record| record.observations.len())
            .sum::<usize>()
            .saturating_sub(existing_service_observations)
            .saturating_add(incoming.len());
        if observation_count > self.limits.max_observations {
            return Err(RegistryError::ObservationLimitExceeded {
                maximum: self.limits.max_observations,
            });
        }

        let receiver_observation_count = existing
            .map_or(0, |record| {
                record
                    .observations
                    .keys()
                    .filter(|key| &key.service != service)
                    .count()
            })
            .saturating_add(incoming.len());
        if receiver_observation_count > self.limits.max_observations_per_receiver {
            return Err(RegistryError::ReceiverObservationLimitExceeded {
                maximum: self.limits.max_observations_per_receiver,
            });
        }

        let receiver_service_count = existing.map_or(0, |record| {
            record
                .observations
                .keys()
                .filter(|key| &key.service != service)
                .map(|key| &key.service)
                .collect::<BTreeSet<_>>()
                .len()
        }) + 1;
        if receiver_service_count > self.limits.max_services_per_receiver {
            return Err(RegistryError::ReceiverServiceLimitExceeded {
                maximum: self.limits.max_services_per_receiver,
            });
        }

        let live_known_services = self
            .known_services
            .values()
            .filter(|known| known.protects_identity_at(now_ms))
            .count();
        let service_is_live = self
            .known_services
            .get(service)
            .is_some_and(|known| known.protects_identity_at(now_ms));
        let known_service_count = live_known_services + usize::from(!service_is_live);
        if known_service_count > self.limits.max_known_services {
            return Err(RegistryError::KnownServiceLimitExceeded {
                maximum: self.limits.max_known_services,
            });
        }

        self.validate_supported_admission(service, existing, incoming)
    }

    fn validate_supported_admission(
        &self,
        service: &ServiceKey,
        existing: Option<&ReceiverRecord>,
        incoming: &BTreeMap<ObservationKey, DiscoveryObservation>,
    ) -> Result<(), RegistryError> {
        let currently_supported = self
            .receivers
            .values()
            .filter(|record| record.reserves_supported_slot())
            .count();
        let target_currently_supported =
            existing.is_some_and(ReceiverRecord::reserves_supported_slot);
        let prospective_capability = classify_observations(
            existing
                .into_iter()
                .flat_map(|record| record.observations.values())
                .filter(|observation| &observation.key.service != service)
                .chain(incoming.values()),
        );
        let target_prospectively_supported = prospective_capability.is_supported()
            || existing.is_some_and(|record| {
                record.machine.state() == ReceiverState::GraceOffline
                    && record.grace_recovery_requires_supported
            });
        let supported_count = currently_supported
            .saturating_sub(usize::from(target_currently_supported))
            .saturating_add(usize::from(target_prospectively_supported));
        if supported_count > self.limits.max_supported_receivers {
            return Err(RegistryError::SupportedReceiverLimitExceeded {
                maximum: self.limits.max_supported_receivers,
            });
        }
        Ok(())
    }

    fn quarantine_service(&mut self, service: &ServiceKey, now_ms: u64) {
        if let Some(known) = self.known_services.get_mut(service) {
            known
                .quarantine_deadline_ms
                .get_or_insert_with(|| now_ms.saturating_add(self.grace_ms));
        }
    }

    fn expire_known_services(&mut self, now_ms: u64) {
        self.known_services.retain(|_, service| {
            service
                .quarantine_deadline_ms
                .is_none_or(|deadline| now_ms < deadline)
        });
    }
}

fn collect_service_snapshot(
    service: &ServiceKey,
    observations: impl IntoIterator<Item = DiscoveryObservation>,
    maximum: usize,
) -> Result<
    (
        BTreeMap<ObservationKey, DiscoveryObservation>,
        Option<ReceiverIdentity>,
    ),
    RegistryError,
> {
    let mut incoming = BTreeMap::new();
    let mut incoming_identity = None;
    for (supplied, observation) in observations.into_iter().enumerate() {
        if supplied >= maximum {
            return Err(RegistryError::ReceiverObservationLimitExceeded { maximum });
        }
        if &observation.key.service != service {
            return Err(RegistryError::MismatchedServiceKey);
        }
        match &incoming_identity {
            Some(identity) if identity != &observation.identity => {
                return Err(RegistryError::InconsistentSnapshotIdentity);
            }
            None => incoming_identity = Some(observation.identity.clone()),
            _ => {}
        }
        if !incoming.contains_key(&observation.key) && incoming.len() >= maximum {
            return Err(RegistryError::ReceiverObservationLimitExceeded { maximum });
        }
        if let Some(previous) = incoming.insert(observation.key.clone(), observation.clone())
            && previous != observation
        {
            return Err(RegistryError::ConflictingDuplicateObservation);
        }
    }
    Ok((incoming, incoming_identity))
}

fn update_after_removal(
    record: &mut ReceiverRecord,
    before: Option<&ReceiverSnapshot>,
    now_ms: u64,
    grace_ms: u64,
) -> Result<Vec<RegistryEvent>, RegistryError> {
    if record.observations.is_empty() {
        if record.machine.state() == ReceiverState::GraceOffline {
            let after = record.snapshot();
            return if before == Some(&after) {
                Ok(Vec::new())
            } else {
                Ok(vec![RegistryEvent::Updated { receiver: after }])
            };
        }
        record.machine.apply(ReceiverSignal::Lost)?;
        let deadline = now_ms.saturating_add(grace_ms);
        record.grace_deadline_ms = Some(deadline);
        record.grace_recovery_requires_supported =
            before.is_some_and(|snapshot| snapshot.capability.is_supported());
        return Ok(vec![RegistryEvent::GraceStarted {
            receiver: record.snapshot(),
            deadline_ms: deadline,
        }]);
    }

    let was_supported = before.is_some_and(|snapshot| snapshot.capability.is_supported());
    record.recompute();
    if was_supported && !record.capability.is_supported() {
        if record.machine.state() != ReceiverState::GraceOffline {
            record.machine.apply(ReceiverSignal::Lost)?;
        }
        let deadline = now_ms.saturating_add(grace_ms);
        record.grace_deadline_ms = Some(deadline);
        record.grace_recovery_requires_supported = true;
        return Ok(vec![RegistryEvent::GraceStarted {
            receiver: record.snapshot(),
            deadline_ms: deadline,
        }]);
    }
    if record.machine.state() == ReceiverState::GraceOffline {
        let after = record.snapshot();
        return if before == Some(&after) {
            Ok(Vec::new())
        } else {
            Ok(vec![RegistryEvent::Updated { receiver: after }])
        };
    }
    record.machine.apply(ReceiverSignal::CapabilitiesResolved {
        supported: record.capability.is_supported(),
    })?;
    let after = record.snapshot();
    if before == Some(&after) {
        Ok(Vec::new())
    } else {
        Ok(vec![RegistryEvent::Updated { receiver: after }])
    }
}

/// Browser-to-consumer message. The channel carrying these is bounded.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(tag = "notification", rename_all = "snake_case")]
pub enum DiscoveryNotification {
    SearchStarted {
        service_type: String,
    },
    SearchStopped {
        service_type: String,
    },
    ServiceFound {
        service_type: String,
        fullname: String,
    },
    Registry {
        change: RegistryEvent,
    },
    Rejected {
        service_type: String,
        fullname: String,
        reason: String,
    },
    BackendError {
        operation: String,
        reason: String,
    },
    InterfaceChanged {
        added: bool,
        address: IpAddr,
    },
}

/// Runtime settings for the real mDNS browser.
#[derive(Clone, Copy, Debug)]
pub struct DiscoveryConfig {
    pub offline_grace: Duration,
    pub query_interval: Duration,
    pub mdns_port: u16,
    pub txt_limits: TxtLimits,
    pub registry_limits: RegistryLimits,
    pub output_capacity: usize,
    pub poll_interval: Duration,
    pub max_events_per_poll: usize,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            offline_grace: Duration::from_secs(8),
            query_interval: DEFAULT_DISCOVERY_QUERY_INTERVAL,
            mdns_port: DEFAULT_MDNS_PORT,
            txt_limits: TxtLimits::default(),
            registry_limits: RegistryLimits::default(),
            output_capacity: 256,
            poll_interval: Duration::from_millis(25),
            max_events_per_poll: 256,
        }
    }
}

fn browser_config_is_valid(config: &DiscoveryConfig) -> bool {
    config.mdns_port != 0
        && config.output_capacity > 0
        && config.max_events_per_poll > 0
        && !config.poll_interval.is_zero()
        && config.poll_interval <= Duration::from_secs(1)
        && (MIN_DISCOVERY_QUERY_INTERVAL..=MAX_DISCOVERY_QUERY_INTERVAL)
            .contains(&config.query_interval)
        && config.registry_limits.is_valid()
}

/// Explicitly cancellable mDNS browser with an owned join handle.
pub struct DiscoveryBrowser {
    cancellation: Arc<AtomicBool>,
    dropped_notifications: Arc<AtomicU64>,
    coalesced_notifications: Arc<AtomicU64>,
    thread: Option<JoinHandle<()>>,
}

impl DiscoveryBrowser {
    /// Starts real browsing for both RAOP and companion `AirPlay` services.
    pub fn start(
        config: DiscoveryConfig,
    ) -> Result<(Self, Receiver<DiscoveryNotification>), DiscoveryError> {
        if !browser_config_is_valid(&config) {
            return Err(DiscoveryError::InvalidBrowserConfig);
        }

        let daemon = ServiceDaemon::new_with_port(config.mdns_port)
            .map_err(|error| DiscoveryError::Backend(error.to_string()))?;
        let raop = match daemon.browse(RAOP_SERVICE_TYPE) {
            Ok(receiver) => receiver,
            Err(error) => {
                let cleanup_errors = cleanup_daemon_after_start_failure(&daemon, &[]);
                return Err(DiscoveryError::Backend(with_cleanup_errors(
                    error.to_string(),
                    &cleanup_errors,
                )));
            }
        };
        let airplay = match daemon.browse(AIRPLAY_SERVICE_TYPE) {
            Ok(receiver) => receiver,
            Err(error) => {
                let cleanup_errors =
                    cleanup_daemon_after_start_failure(&daemon, &[RAOP_SERVICE_TYPE]);
                return Err(DiscoveryError::Backend(with_cleanup_errors(
                    error.to_string(),
                    &cleanup_errors,
                )));
            }
        };
        let monitor = match daemon.monitor() {
            Ok(receiver) => receiver,
            Err(error) => {
                let cleanup_errors = cleanup_daemon_after_start_failure(
                    &daemon,
                    &[RAOP_SERVICE_TYPE, AIRPLAY_SERVICE_TYPE],
                );
                return Err(DiscoveryError::Backend(with_cleanup_errors(
                    error.to_string(),
                    &cleanup_errors,
                )));
            }
        };

        let (sender, receiver) = mpsc::sync_channel(config.output_capacity);
        let cancellation = Arc::new(AtomicBool::new(false));
        let dropped_notifications = Arc::new(AtomicU64::new(0));
        let coalesced_notifications = Arc::new(AtomicU64::new(0));
        let thread_cancellation = Arc::clone(&cancellation);
        let thread_dropped = Arc::clone(&dropped_notifications);
        let thread_coalesced = Arc::clone(&coalesced_notifications);
        let cleanup_daemon = daemon.clone();
        let thread = match thread::Builder::new()
            .name("winairplay-mdns".to_owned())
            .spawn(move || {
                browse_loop(
                    daemon,
                    raop,
                    airplay,
                    monitor,
                    sender,
                    thread_cancellation,
                    thread_dropped,
                    thread_coalesced,
                    config,
                );
            }) {
            Ok(thread) => thread,
            Err(error) => {
                let cleanup_errors = cleanup_daemon_after_start_failure(
                    &cleanup_daemon,
                    &[RAOP_SERVICE_TYPE, AIRPLAY_SERVICE_TYPE],
                );
                return Err(DiscoveryError::ThreadStart(with_cleanup_errors(
                    error.to_string(),
                    &cleanup_errors,
                )));
            }
        };

        Ok((
            Self {
                cancellation,
                dropped_notifications,
                coalesced_notifications,
                thread: Some(thread),
            },
            receiver,
        ))
    }

    /// Requests shutdown without blocking the caller.
    pub fn request_stop(&self) {
        self.cancellation.store(true, Ordering::Release);
    }

    /// Returns unrecoverable registry-state delivery failures.
    ///
    /// Queue pressure alone does not increment this counter: intermediate
    /// state is coalesced and the worker resynchronises to the registry's
    /// latest bounded snapshot once capacity becomes available.
    #[must_use]
    pub fn dropped_notifications(&self) -> u64 {
        self.dropped_notifications.load(Ordering::Acquire)
    }

    /// Returns informational notifications and intermediate registry states
    /// coalesced while the bounded output queue was full.
    #[must_use]
    pub fn coalesced_notifications(&self) -> u64 {
        self.coalesced_notifications.load(Ordering::Acquire)
    }

    /// Requests shutdown and joins the browser thread.
    pub fn stop(mut self) -> Result<(), DiscoveryError> {
        self.request_stop();
        self.join_thread()
    }

    fn join_thread(&mut self) -> Result<(), DiscoveryError> {
        if let Some(handle) = self.thread.take() {
            handle.join().map_err(|_| DiscoveryError::ThreadPanicked)?;
        }
        Ok(())
    }
}

impl Drop for DiscoveryBrowser {
    fn drop(&mut self) {
        self.request_stop();
        let _ = self.join_thread();
    }
}

/// Validation and registry errors.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum DiscoveryError {
    #[error("unsupported DNS-SD service type: {0}")]
    UnsupportedServiceType(String),
    #[error("{field} is empty, contains control characters, or exceeds 255 bytes")]
    InvalidDnsName { field: &'static str },
    #[error("service port must be non-zero")]
    InvalidPort,
    #[error("resolved service has no usable unicast address")]
    NoUsableAddresses,
    #[error("resolved service has more than {MAX_ADDRESSES_PER_OBSERVATION} addresses")]
    TooManyAddresses,
    #[error("invalid interface name or index")]
    InvalidInterface,
    #[error("TXT limits must all be non-zero")]
    InvalidTxtLimits,
    #[error("TXT record count exceeds configured limit")]
    TxtTooManyRecords,
    #[error("invalid TXT key: {0}")]
    InvalidTxtKey(String),
    #[error("duplicate case-insensitive TXT key: {0}")]
    DuplicateTxtKey(String),
    #[error("TXT value for {key} is {actual} bytes; limit is {maximum}")]
    TxtValueTooLarge {
        key: String,
        actual: usize,
        maximum: usize,
    },
    #[error("individual TXT property exceeds the DNS-SD 255-byte limit")]
    TxtRecordTooLarge,
    #[error("TXT properties total {actual} bytes; configured limit is {maximum}")]
    TxtTotalTooLarge { actual: usize, maximum: usize },
    #[error("TXT value for {0} is not UTF-8")]
    InvalidTxtUtf8(String),
    #[error("TXT value for {0} contains a control character")]
    InvalidTxtControlCharacter(String),
    #[error(transparent)]
    Identity(#[from] IdentityError),
    #[error("mDNS backend failed: {0}")]
    Backend(String),
    #[error("invalid discovery browser configuration")]
    InvalidBrowserConfig,
    #[error("could not start discovery thread: {0}")]
    ThreadStart(String),
    #[error("discovery thread panicked")]
    ThreadPanicked,
}

/// Atomic registry operation failures.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RegistryError {
    #[error("registry limits are zero or internally inconsistent")]
    InvalidLimits,
    #[error("resolved observations do not match their snapshot service key")]
    MismatchedServiceKey,
    #[error("resolved snapshot contains more than one stable identity")]
    InconsistentSnapshotIdentity,
    #[error("resolved snapshot contains conflicting observations for one interface")]
    ConflictingDuplicateObservation,
    #[error("resolved service changed its stable identity")]
    ServiceIdentityChanged,
    #[error("resolved snapshot was empty")]
    EmptySnapshot,
    #[error("receiver count exceeds configured limit of {maximum}")]
    ReceiverLimitExceeded { maximum: usize },
    #[error("supported receiver count exceeds worker/device-node limit of {maximum}")]
    SupportedReceiverLimitExceeded { maximum: usize },
    #[error("known service count exceeds configured limit of {maximum}")]
    KnownServiceLimitExceeded { maximum: usize },
    #[error("service count for one receiver exceeds configured limit of {maximum}")]
    ReceiverServiceLimitExceeded { maximum: usize },
    #[error("observation count exceeds configured limit of {maximum}")]
    ObservationLimitExceeded { maximum: usize },
    #[error("observation count for one receiver exceeds configured limit of {maximum}")]
    ReceiverObservationLimitExceeded { maximum: usize },
    #[error("receiver not found: {0}")]
    ReceiverNotFound(ReceiverIdentity),
    #[error(transparent)]
    InvalidTransition(#[from] TransitionError),
}

struct NotificationPublisher {
    sender: SyncSender<DiscoveryNotification>,
    dropped: Arc<AtomicU64>,
    coalesced: Arc<AtomicU64>,
    published: BTreeMap<ReceiverIdentity, ReceiverSnapshot>,
    registry_dirty: bool,
    disconnected: bool,
}

impl NotificationPublisher {
    fn new(
        sender: SyncSender<DiscoveryNotification>,
        dropped: Arc<AtomicU64>,
        coalesced: Arc<AtomicU64>,
    ) -> Self {
        Self {
            sender,
            dropped,
            coalesced,
            published: BTreeMap::new(),
            registry_dirty: false,
            disconnected: false,
        }
    }

    fn publish_informational(&mut self, notification: DiscoveryNotification) {
        if self.disconnected || self.registry_dirty {
            self.mark_coalesced();
            return;
        }
        match self.sender.try_send(notification) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => self.mark_coalesced(),
            Err(TrySendError::Disconnected(_)) => {
                self.disconnected = true;
            }
        }
    }

    fn publish_registry_events(&mut self, events: Vec<RegistryEvent>) {
        for change in events {
            if self.registry_dirty || self.disconnected {
                self.mark_coalesced();
                continue;
            }
            match self.sender.try_send(DiscoveryNotification::Registry {
                change: change.clone(),
            }) {
                Ok(()) => Self::apply_published_change(&mut self.published, &change),
                Err(TrySendError::Full(_)) => {
                    self.registry_dirty = true;
                    self.mark_coalesced();
                }
                Err(TrySendError::Disconnected(_)) => self.record_state_loss(),
            }
        }
    }

    fn reconcile_registry(&mut self, registry: &ReceiverRegistry) {
        if !self.registry_dirty || self.disconnected {
            return;
        }
        let desired = registry
            .snapshots()
            .into_iter()
            .map(|snapshot| (snapshot.identity.clone(), snapshot))
            .collect::<BTreeMap<_, _>>();

        loop {
            let next = self
                .published
                .iter()
                .find(|(identity, _)| !desired.contains_key(*identity))
                .map(|(_, previous)| RegistryEvent::Removed {
                    receiver: removed_snapshot(previous),
                })
                .or_else(|| {
                    desired.iter().find_map(|(identity, receiver)| {
                        let previous = self.published.get(identity);
                        (previous != Some(receiver))
                            .then(|| coalesced_registry_change(previous, receiver))
                    })
                });
            let Some(change) = next else {
                self.registry_dirty = false;
                return;
            };

            match self.sender.try_send(DiscoveryNotification::Registry {
                change: change.clone(),
            }) {
                Ok(()) => Self::apply_published_change(&mut self.published, &change),
                Err(TrySendError::Full(_)) => {
                    self.mark_coalesced();
                    return;
                }
                Err(TrySendError::Disconnected(_)) => {
                    self.record_state_loss();
                    return;
                }
            }
        }
    }

    fn apply_published_change(
        published: &mut BTreeMap<ReceiverIdentity, ReceiverSnapshot>,
        change: &RegistryEvent,
    ) {
        match change {
            RegistryEvent::Added { receiver }
            | RegistryEvent::Updated { receiver }
            | RegistryEvent::GraceStarted { receiver, .. }
            | RegistryEvent::GraceCancelled { receiver }
            | RegistryEvent::Removing { receiver } => {
                published.insert(receiver.identity.clone(), receiver.clone());
            }
            RegistryEvent::Removed { receiver } => {
                published.remove(&receiver.identity);
            }
        }
    }

    fn mark_coalesced(&self) {
        self.coalesced.fetch_add(1, Ordering::Relaxed);
    }

    fn record_state_loss(&mut self) {
        if !self.disconnected {
            self.dropped.fetch_add(1, Ordering::Relaxed);
        }
        self.disconnected = true;
    }
}

fn coalesced_registry_change(
    previous: Option<&ReceiverSnapshot>,
    receiver: &ReceiverSnapshot,
) -> RegistryEvent {
    if previous.is_none() {
        return RegistryEvent::Added {
            receiver: receiver.clone(),
        };
    }
    match receiver.state {
        ReceiverState::GraceOffline => RegistryEvent::GraceStarted {
            receiver: receiver.clone(),
            deadline_ms: receiver.grace_deadline_ms.unwrap_or(receiver.last_seen_ms),
        },
        ReceiverState::Removing => RegistryEvent::Removing {
            receiver: receiver.clone(),
        },
        _ => RegistryEvent::Updated {
            receiver: receiver.clone(),
        },
    }
}

fn removed_snapshot(previous: &ReceiverSnapshot) -> ReceiverSnapshot {
    let mut receiver = previous.clone();
    receiver.state = ReceiverState::Removed;
    receiver.observations.clear();
    receiver.grace_deadline_ms = None;
    receiver
}

struct QueryPulseChannel {
    service_type: &'static str,
    receiver: mdns_sd::Receiver<ServiceEvent>,
    search_started: bool,
    search_stopped: bool,
    closed: bool,
}

impl QueryPulseChannel {
    fn is_finished(&self) -> bool {
        self.search_stopped || self.closed
    }
}

struct QueryPulseChannels {
    channels: Vec<QueryPulseChannel>,
    stop_at: Instant,
    stop_state: QueryPulseStopState,
    epoch_status: QueryPulseEpochStatus,
}

#[derive(Clone, Copy)]
enum QueryPulseStopState {
    Browsing,
    AwaitingAcknowledgement { deadline: Instant },
    ForcedFinished,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum QueryPulseEpochStatus {
    Eligible,
    Failed,
}

impl QueryPulseChannels {
    fn is_finished(&self) -> bool {
        match self.stop_state {
            QueryPulseStopState::Browsing => false,
            QueryPulseStopState::AwaitingAcknowledgement { .. } => {
                self.channels.iter().all(QueryPulseChannel::is_finished)
            }
            QueryPulseStopState::ForcedFinished => true,
        }
    }

    fn is_stop_requested(&self) -> bool {
        !matches!(self.stop_state, QueryPulseStopState::Browsing)
    }

    fn is_successful_epoch(&self) -> bool {
        self.epoch_status == QueryPulseEpochStatus::Eligible
            && self
                .channels
                .iter()
                .all(|channel| channel.search_started && channel.search_stopped)
    }

    fn missing_stop_acknowledgements(&self) -> String {
        self.channels
            .iter()
            .filter(|channel| !channel.is_finished())
            .map(|channel| channel.service_type)
            .collect::<Vec<_>>()
            .join(", ")
    }
}

struct QueryPulseSchedule {
    interval: Duration,
    next_start: Instant,
}

impl QueryPulseSchedule {
    fn new(started: Instant, interval: Duration) -> Self {
        Self {
            interval,
            next_start: started + interval,
        }
    }

    fn is_due(&self, now: Instant) -> bool {
        now >= self.next_start
    }

    fn mark_started(&mut self, now: Instant) {
        // Schedule from the actual pulse time so a delayed worker never emits
        // an unbounded burst of catch-up queries.
        self.next_start = now + self.interval;
    }
}

#[derive(Default)]
struct QueryPulseFreshness {
    seen_since_successful_epoch: BTreeSet<ServiceKey>,
    missed_successful_epochs: BTreeMap<ServiceKey, u8>,
}

impl QueryPulseFreshness {
    fn note_resolved(
        &mut self,
        services: impl IntoIterator<Item = ServiceKey>,
        registry: &ReceiverRegistry,
    ) {
        let active = registry.active_service_keys();
        self.seen_since_successful_epoch
            .retain(|service| active.contains(service));
        self.missed_successful_epochs
            .retain(|service, _| active.contains(service));
        self.seen_since_successful_epoch.extend(
            services
                .into_iter()
                .filter(|service| active.contains(service)),
        );
    }

    fn complete_successful_epoch(
        &mut self,
        registry: &mut ReceiverRegistry,
        publisher: &mut NotificationPublisher,
        now_ms: u64,
    ) {
        let active = registry.active_service_keys();
        self.missed_successful_epochs
            .retain(|service, _| active.contains(service));

        let mut expired = Vec::new();
        for service in active {
            if self.seen_since_successful_epoch.contains(&service) {
                self.missed_successful_epochs.remove(&service);
                continue;
            }
            let misses = self
                .missed_successful_epochs
                .entry(service.clone())
                .or_default();
            *misses = misses.saturating_add(1);
            if *misses >= MAX_MISSED_QUERY_EPOCHS {
                expired.push(service);
            }
        }
        self.seen_since_successful_epoch.clear();

        for service in expired {
            match registry.remove_service(&service, now_ms) {
                Ok(events) => {
                    self.missed_successful_epochs.remove(&service);
                    publisher.publish_registry_events(events);
                }
                Err(error) => {
                    self.missed_successful_epochs
                        .insert(service.clone(), MAX_MISSED_QUERY_EPOCHS);
                    publisher.publish_informational(DiscoveryNotification::BackendError {
                        operation: format!(
                            "expire {} after missed active discovery queries",
                            service.fullname
                        ),
                        reason: error.to_string(),
                    });
                }
            }
        }
    }
}

struct QueryPulseController {
    mdns_port: u16,
    daemon: Option<ServiceDaemon>,
    active: Option<QueryPulseChannels>,
    schedule: QueryPulseSchedule,
    freshness: QueryPulseFreshness,
}

impl QueryPulseController {
    fn new(started: Instant, interval: Duration, mdns_port: u16) -> Self {
        Self {
            mdns_port,
            daemon: None,
            active: None,
            schedule: QueryPulseSchedule::new(started, interval),
            freshness: QueryPulseFreshness::default(),
        }
    }

    fn poll(
        &mut self,
        now: Instant,
        maximum_events: usize,
        publisher: &mut NotificationPublisher,
        registry: &mut ReceiverRegistry,
        started: Instant,
        config: DiscoveryConfig,
    ) -> usize {
        let processed = self.drain_events(maximum_events, publisher, registry, started, config);

        if self
            .active
            .as_ref()
            .is_some_and(|active| !active.is_stop_requested() && now >= active.stop_at)
        {
            self.request_stop(now, publisher);
        }
        self.handle_stop_ack_timeout(now, publisher);

        if self.active.is_none() && self.schedule.is_due(now) {
            self.schedule.mark_started(now);
            self.start_pulse(now, publisher);
        }

        processed
    }

    fn start_pulse(&mut self, now: Instant, publisher: &mut NotificationPublisher) {
        if self.daemon.is_none() {
            match ServiceDaemon::new_with_port(self.mdns_port) {
                Ok(daemon) => self.daemon = Some(daemon),
                Err(error) => {
                    publish_query_pulse_error(
                        publisher,
                        "create active discovery query daemon",
                        error.to_string(),
                    );
                    return;
                }
            }
        }

        let Some(daemon) = self.daemon.as_ref() else {
            return;
        };
        let raop = match daemon.browse(RAOP_SERVICE_TYPE) {
            Ok(receiver) => receiver,
            Err(error) => {
                publish_query_pulse_error(
                    publisher,
                    format!("start active discovery query for {RAOP_SERVICE_TYPE}"),
                    error.to_string(),
                );
                self.retire_daemon(publisher);
                return;
            }
        };
        let airplay = match daemon.browse(AIRPLAY_SERVICE_TYPE) {
            Ok(receiver) => receiver,
            Err(error) => {
                publish_query_pulse_error(
                    publisher,
                    format!("start active discovery query for {AIRPLAY_SERVICE_TYPE}"),
                    error.to_string(),
                );
                self.active = Some(QueryPulseChannels {
                    channels: vec![QueryPulseChannel {
                        service_type: RAOP_SERVICE_TYPE,
                        receiver: raop,
                        search_started: false,
                        search_stopped: false,
                        closed: false,
                    }],
                    stop_at: now,
                    stop_state: QueryPulseStopState::Browsing,
                    epoch_status: QueryPulseEpochStatus::Failed,
                });
                self.request_stop(now, publisher);
                self.retire_daemon(publisher);
                return;
            }
        };

        self.active = Some(QueryPulseChannels {
            channels: vec![
                QueryPulseChannel {
                    service_type: RAOP_SERVICE_TYPE,
                    receiver: raop,
                    search_started: false,
                    search_stopped: false,
                    closed: false,
                },
                QueryPulseChannel {
                    service_type: AIRPLAY_SERVICE_TYPE,
                    receiver: airplay,
                    search_started: false,
                    search_stopped: false,
                    closed: false,
                },
            ],
            stop_at: now + QUERY_PULSE_DURATION,
            stop_state: QueryPulseStopState::Browsing,
            epoch_status: QueryPulseEpochStatus::Eligible,
        });
    }

    fn drain_events(
        &mut self,
        maximum_events: usize,
        publisher: &mut NotificationPublisher,
        registry: &mut ReceiverRegistry,
        started: Instant,
        config: DiscoveryConfig,
    ) -> usize {
        let Some(active) = self.active.as_mut() else {
            return 0;
        };
        let mut processed = 0;
        let mut resolved_services = BTreeSet::new();
        for channel in &mut active.channels {
            if processed >= maximum_events {
                break;
            }
            let result = drain_service_events(
                &channel.receiver,
                publisher,
                registry,
                started,
                config,
                maximum_events - processed,
                ServiceEventAuthority::QueryPulse,
            );
            processed += result.processed;
            channel.search_started |= result.search_started;
            channel.search_stopped |= result.search_stopped;
            channel.closed |= channel.receiver.is_disconnected() && channel.receiver.is_empty();
            resolved_services.extend(result.resolved_services);
        }
        self.freshness.note_resolved(resolved_services, registry);
        processed
    }

    fn note_resolved_services(
        &mut self,
        services: impl IntoIterator<Item = ServiceKey>,
        registry: &ReceiverRegistry,
    ) {
        self.freshness.note_resolved(services, registry);
    }

    fn request_stop(&mut self, now: Instant, publisher: &mut NotificationPublisher) {
        let Some(active) = self.active.as_mut() else {
            return;
        };
        active.stop_state = QueryPulseStopState::AwaitingAcknowledgement {
            deadline: now + QUERY_PULSE_STOP_ACK_TIMEOUT,
        };
        let Some(daemon) = self.daemon.as_ref() else {
            active.epoch_status = QueryPulseEpochStatus::Failed;
            active.stop_state = QueryPulseStopState::ForcedFinished;
            return;
        };
        let mut stop_failed = false;
        for channel in &active.channels {
            if let Err(error) = stop_browse_bounded(daemon, channel.service_type) {
                stop_failed = true;
                publish_query_pulse_error(
                    publisher,
                    format!("stop active discovery query for {}", channel.service_type),
                    error,
                );
            }
        }

        if stop_failed {
            if let Some(active) = self.active.as_mut() {
                active.epoch_status = QueryPulseEpochStatus::Failed;
            }
            self.retire_daemon(publisher);
            if let Some(active) = self.active.as_mut() {
                active.stop_state = QueryPulseStopState::ForcedFinished;
            }
        }
    }

    fn handle_stop_ack_timeout(&mut self, now: Instant, publisher: &mut NotificationPublisher) {
        let missing = self.active.as_ref().and_then(|active| {
            matches!(
                active.stop_state,
                QueryPulseStopState::AwaitingAcknowledgement { deadline }
                    if !active.is_finished() && now >= deadline
            )
            .then(|| active.missing_stop_acknowledgements())
        });
        let Some(missing) = missing else {
            return;
        };

        publish_query_pulse_error(
            publisher,
            "wait for active discovery query stop acknowledgement",
            format!("timed out waiting for: {missing}"),
        );
        if let Some(active) = self.active.as_mut() {
            active.epoch_status = QueryPulseEpochStatus::Failed;
            active.stop_state = QueryPulseStopState::ForcedFinished;
        }
        self.retire_daemon(publisher);
    }

    fn finalize_finished_epoch(
        &mut self,
        registry: &mut ReceiverRegistry,
        publisher: &mut NotificationPublisher,
        now_ms: u64,
    ) {
        let finished = self
            .active
            .as_ref()
            .is_some_and(QueryPulseChannels::is_finished);
        if !finished {
            return;
        }
        let successful = self
            .active
            .take()
            .is_some_and(|active| active.is_successful_epoch());
        if successful {
            self.freshness
                .complete_successful_epoch(registry, publisher, now_ms);
        }
    }

    fn shutdown(
        &mut self,
        publisher: &mut NotificationPublisher,
        registry: &mut ReceiverRegistry,
        started: Instant,
        config: DiscoveryConfig,
    ) {
        self.drain_events(
            MAX_QUERY_PULSE_DRAIN_EVENTS,
            publisher,
            registry,
            started,
            config,
        );
        if self
            .active
            .as_ref()
            .is_some_and(|active| !active.is_stop_requested())
        {
            self.request_stop(Instant::now(), publisher);
        }
        self.retire_daemon(publisher);
        self.drain_events(
            MAX_QUERY_PULSE_DRAIN_EVENTS,
            publisher,
            registry,
            started,
            config,
        );
        self.active = None;
    }

    fn retire_daemon(&mut self, publisher: &mut NotificationPublisher) {
        let Some(daemon) = self.daemon.take() else {
            return;
        };
        if let Err(error) = shutdown_daemon_bounded(&daemon) {
            publish_query_pulse_error(publisher, "shut down active discovery query daemon", error);
        }
    }
}

fn stop_browse_bounded(daemon: &ServiceDaemon, service_type: &str) -> Result<(), String> {
    let deadline = Instant::now() + DAEMON_COMMAND_RETRY_TIMEOUT;
    loop {
        match daemon.stop_browse(service_type) {
            Ok(()) => return Ok(()),
            Err(_) if Instant::now() < deadline => thread::sleep(DAEMON_COMMAND_RETRY_DELAY),
            Err(error) => return Err(error.to_string()),
        }
    }
}

fn shutdown_daemon_bounded(daemon: &ServiceDaemon) -> Result<(), String> {
    let request_deadline = Instant::now() + DAEMON_COMMAND_RETRY_TIMEOUT;
    let status = loop {
        match daemon.shutdown() {
            Ok(status) => break status,
            Err(_) if Instant::now() < request_deadline => {
                thread::sleep(DAEMON_COMMAND_RETRY_DELAY);
            }
            Err(error) => return Err(error.to_string()),
        }
    };

    match status.recv_timeout(DAEMON_SHUTDOWN_TIMEOUT) {
        Ok(DaemonStatus::Shutdown) => Ok(()),
        Ok(status) => Err(format!(
            "daemon reported unexpected shutdown status {status:?}"
        )),
        Err(error) => Err(format!(
            "timed out waiting for daemon shutdown acknowledgement: {error}"
        )),
    }
}

fn cleanup_daemon_after_start_failure(
    daemon: &ServiceDaemon,
    active_service_types: &[&str],
) -> Vec<String> {
    let mut errors = Vec::new();
    for service_type in active_service_types {
        if let Err(error) = stop_browse_bounded(daemon, service_type) {
            errors.push(format!("stop browsing {service_type}: {error}"));
        }
    }
    if let Err(error) = shutdown_daemon_bounded(daemon) {
        errors.push(format!("shut down mDNS daemon: {error}"));
    }
    errors
}

fn with_cleanup_errors(mut reason: String, cleanup_errors: &[String]) -> String {
    if !cleanup_errors.is_empty() {
        reason.push_str("; cleanup also failed: ");
        reason.push_str(&cleanup_errors.join("; "));
    }
    reason
}

fn publish_query_pulse_error(
    publisher: &mut NotificationPublisher,
    operation: impl Into<String>,
    reason: impl Into<String>,
) {
    publisher.publish_informational(DiscoveryNotification::BackendError {
        operation: operation.into(),
        reason: reason.into(),
    });
}

// Every handle is moved here intentionally so the named worker owns and drops
// all backend resources; no discovery thread or daemon is detached.
#[allow(clippy::needless_pass_by_value, clippy::too_many_arguments)]
fn browse_loop(
    daemon: ServiceDaemon,
    raop: mdns_sd::Receiver<ServiceEvent>,
    airplay: mdns_sd::Receiver<ServiceEvent>,
    monitor: mdns_sd::Receiver<DaemonEvent>,
    sender: SyncSender<DiscoveryNotification>,
    cancellation: Arc<AtomicBool>,
    dropped: Arc<AtomicU64>,
    coalesced: Arc<AtomicU64>,
    config: DiscoveryConfig,
) {
    let started = Instant::now();
    let mut registry = ReceiverRegistry::with_limits(config.offline_grace, config.registry_limits)
        .expect("browser validates registry limits before starting its worker");
    let mut publisher = NotificationPublisher::new(sender, dropped, coalesced);
    let mut query_pulse =
        QueryPulseController::new(started, config.query_interval, config.mdns_port);

    while !cancellation.load(Ordering::Acquire) {
        publisher.reconcile_registry(&registry);
        let mut processed = query_pulse.poll(
            Instant::now(),
            config.max_events_per_poll,
            &mut publisher,
            &mut registry,
            started,
            config,
        );
        if processed < config.max_events_per_poll {
            let result = drain_service_events(
                &raop,
                &mut publisher,
                &mut registry,
                started,
                config,
                config.max_events_per_poll - processed,
                ServiceEventAuthority::Primary,
            );
            processed += result.processed;
            query_pulse.note_resolved_services(result.resolved_services, &registry);
        }
        if processed < config.max_events_per_poll {
            let result = drain_service_events(
                &airplay,
                &mut publisher,
                &mut registry,
                started,
                config,
                config.max_events_per_poll - processed,
                ServiceEventAuthority::Primary,
            );
            processed += result.processed;
            query_pulse.note_resolved_services(result.resolved_services, &registry);
        }
        if processed < config.max_events_per_poll {
            let remaining = config.max_events_per_poll - processed;
            drain_daemon_events(&monitor, &mut publisher, remaining);
        }
        query_pulse.finalize_finished_epoch(&mut registry, &mut publisher, elapsed_millis(started));

        match registry.tick(elapsed_millis(started)) {
            Ok(events) => publisher.publish_registry_events(events),
            Err(error) => publisher.publish_informational(DiscoveryNotification::BackendError {
                operation: "expire receiver grace period".to_owned(),
                reason: error.to_string(),
            }),
        }
        publisher.reconcile_registry(&registry);

        thread::sleep(config.poll_interval);
    }

    query_pulse.shutdown(&mut publisher, &mut registry, started, config);
    for service_type in [RAOP_SERVICE_TYPE, AIRPLAY_SERVICE_TYPE] {
        if let Err(error) = stop_browse_bounded(&daemon, service_type) {
            publisher.publish_informational(DiscoveryNotification::BackendError {
                operation: format!("stop browsing {service_type}"),
                reason: error,
            });
        }
    }
    if let Err(error) = shutdown_daemon_bounded(&daemon) {
        publisher.publish_informational(DiscoveryNotification::BackendError {
            operation: "shut down mDNS daemon".to_owned(),
            reason: error,
        });
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ServiceEventAuthority {
    Primary,
    QueryPulse,
}

#[derive(Default)]
struct ServiceEventDrain {
    processed: usize,
    search_started: bool,
    search_stopped: bool,
    resolved_services: BTreeSet<ServiceKey>,
}

fn drain_service_events(
    receiver: &mdns_sd::Receiver<ServiceEvent>,
    publisher: &mut NotificationPublisher,
    registry: &mut ReceiverRegistry,
    started: Instant,
    config: DiscoveryConfig,
    maximum: usize,
    authority: ServiceEventAuthority,
) -> ServiceEventDrain {
    let mut result = ServiceEventDrain::default();
    while result.processed < maximum {
        let Ok(event) = receiver.try_recv() else {
            break;
        };
        result.processed += 1;
        result.search_started |= matches!(&event, ServiceEvent::SearchStarted(_));
        result.search_stopped |= matches!(&event, ServiceEvent::SearchStopped(_));
        if let Some(service) = process_service_event(
            event,
            publisher,
            registry,
            elapsed_millis(started),
            config.txt_limits,
            authority,
        ) {
            result.resolved_services.insert(service);
        }
    }
    result
}

fn process_service_event(
    event: ServiceEvent,
    publisher: &mut NotificationPublisher,
    registry: &mut ReceiverRegistry,
    now_ms: u64,
    limits: TxtLimits,
    authority: ServiceEventAuthority,
) -> Option<ServiceKey> {
    match event {
        ServiceEvent::SearchStarted(service_type) => {
            if authority == ServiceEventAuthority::Primary {
                publisher
                    .publish_informational(DiscoveryNotification::SearchStarted { service_type });
            }
            None
        }
        ServiceEvent::SearchStopped(service_type) => {
            if authority == ServiceEventAuthority::Primary {
                publisher
                    .publish_informational(DiscoveryNotification::SearchStopped { service_type });
            }
            None
        }
        ServiceEvent::ServiceFound(service_type, fullname) => {
            publisher.publish_informational(DiscoveryNotification::ServiceFound {
                service_type,
                fullname,
            });
            None
        }
        ServiceEvent::ServiceResolved(resolved) => {
            let service_type = resolved.ty_domain.clone();
            let fullname = resolved.fullname.clone();
            let parsed = observations_from_resolved(&resolved, limits).and_then(|observations| {
                ServiceKind::from_service_type(&service_type)
                    .map(|kind| (ServiceKey::new(kind, &fullname), observations))
            });
            match parsed {
                Ok((service, observations)) => {
                    match apply_resolved_snapshot(registry, &service, observations, now_ms) {
                        SnapshotApplication::Applied(events) => {
                            publisher.publish_registry_events(events);
                            Some(service)
                        }
                        SnapshotApplication::Rejected {
                            lifecycle_events,
                            error,
                        } => {
                            publisher.publish_registry_events(lifecycle_events);
                            publisher.publish_informational(DiscoveryNotification::Rejected {
                                service_type,
                                fullname,
                                reason: error.to_string(),
                            });
                            None
                        }
                    }
                }
                Err(error) => {
                    publisher.publish_informational(DiscoveryNotification::Rejected {
                        service_type,
                        fullname,
                        reason: error.to_string(),
                    });
                    None
                }
            }
        }
        ServiceEvent::ServiceRemoved(service_type, fullname) => {
            // In the pinned mdns-sd backend, stop_browse clears only the
            // auxiliary daemon's private cache and emits SearchStopped. A
            // ServiceRemoved event is therefore genuine network/TTL evidence,
            // even when it arrives on the query-pulse socket.
            let result = ServiceKind::from_service_type(&service_type)
                .map(|kind| ServiceKey::new(kind, &fullname))
                .and_then(|service| {
                    registry
                        .remove_service(&service, now_ms)
                        .map_err(|error| DiscoveryError::Backend(error.to_string()))
                });
            match result {
                Ok(events) => publisher.publish_registry_events(events),
                Err(error) => {
                    publisher.publish_informational(DiscoveryNotification::Rejected {
                        service_type,
                        fullname,
                        reason: error.to_string(),
                    });
                }
            }
            None
        }
        _ => None,
    }
}

#[derive(Debug)]
enum SnapshotApplication {
    Applied(Vec<RegistryEvent>),
    Rejected {
        lifecycle_events: Vec<RegistryEvent>,
        error: RegistryError,
    },
}

fn apply_resolved_snapshot(
    registry: &mut ReceiverRegistry,
    service: &ServiceKey,
    observations: Vec<DiscoveryObservation>,
    now_ms: u64,
) -> SnapshotApplication {
    match registry.replace_service_snapshot(service.clone(), observations, now_ms) {
        Ok(events) => SnapshotApplication::Applied(events),
        Err(error @ RegistryError::ServiceIdentityChanged) => {
            match registry.remove_service(service, now_ms) {
                Ok(lifecycle_events) => SnapshotApplication::Rejected {
                    lifecycle_events,
                    error,
                },
                Err(cleanup_error) => SnapshotApplication::Rejected {
                    lifecycle_events: Vec::new(),
                    error: cleanup_error,
                },
            }
        }
        Err(error) => SnapshotApplication::Rejected {
            lifecycle_events: Vec::new(),
            error,
        },
    }
}

fn drain_daemon_events(
    receiver: &mdns_sd::Receiver<DaemonEvent>,
    publisher: &mut NotificationPublisher,
    maximum: usize,
) {
    for _ in 0..maximum {
        let Ok(event) = receiver.try_recv() else {
            break;
        };
        match event {
            DaemonEvent::Error(error) => {
                publisher.publish_informational(DiscoveryNotification::BackendError {
                    operation: "mDNS daemon".to_owned(),
                    reason: error.to_string(),
                });
            }
            DaemonEvent::IpAdd(address) => {
                publisher.publish_informational(DiscoveryNotification::InterfaceChanged {
                    added: true,
                    address,
                });
            }
            DaemonEvent::IpDel(address) => {
                publisher.publish_informational(DiscoveryNotification::InterfaceChanged {
                    added: false,
                    address,
                });
            }
            _ => {}
        }
    }
}

fn classify_observations<'a>(
    observations: impl Iterator<Item = &'a DiscoveryObservation>,
) -> ReceiverCapability {
    let observations = observations.collect::<Vec<_>>();
    let raop = observations
        .iter()
        .copied()
        .filter(|observation| observation.key.service.kind == ServiceKind::Raop)
        .map(classify_raop_observation)
        .collect::<Vec<_>>();
    if raop.is_empty() {
        return ReceiverCapability::Unsupported {
            reason: if observations.iter().any(|observation| {
                observation.key.service.kind == ServiceKind::AirPlay
                    && !matches!(advertises_airplay2(&observation.txt), Ok(false))
            }) {
                UnsupportedReason::AirPlay2Unsupported
            } else {
                UnsupportedReason::MissingRaopService
            },
        };
    }

    let mut companion_password_required = false;
    for companion in observations
        .iter()
        .copied()
        .filter(|observation| observation.key.service.kind == ServiceKind::AirPlay)
    {
        let (Ok(status_flags), Ok(pairing_required), Ok(password_required)) = (
            advertised_status_flags(&companion.txt),
            advertised_pairing_requirement(&companion.txt),
            advertised_password_requirement(&companion.txt),
        ) else {
            return ReceiverCapability::Unsupported {
                reason: UnsupportedReason::PairingRequired,
            };
        };
        if status_flags & (STATUS_FLAG_PIN_REQUIRED | STATUS_FLAG_ONE_TIME_PAIRING_REQUIRED) != 0
            || pairing_required
        {
            return ReceiverCapability::Unsupported {
                reason: UnsupportedReason::PairingRequired,
            };
        }
        companion_password_required |=
            password_required || status_flags & STATUS_FLAG_PASSWORD_REQUIRED != 0;
    }

    if raop.iter().any(ReceiverCapability::is_supported)
        && raop.iter().any(|capability| !capability.is_supported())
    {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::InconsistentAdvertisements,
        };
    }

    let mut transports = BTreeSet::new();
    let mut password_required = companion_password_required;
    for capability in &raop {
        if let ReceiverCapability::SupportedClassicRaop {
            transports: advertised,
            password_required: password,
        } = capability
        {
            transports.extend(advertised);
            password_required |= password;
        }
    }
    if !transports.is_empty() {
        return ReceiverCapability::SupportedClassicRaop {
            transports,
            password_required,
        };
    }

    raop.into_iter()
        .min_by_key(|capability| match capability {
            ReceiverCapability::Unsupported { reason } => reason.clone(),
            ReceiverCapability::SupportedClassicRaop { .. } => {
                UnsupportedReason::InconsistentAdvertisements
            }
        })
        .unwrap_or(ReceiverCapability::Unsupported {
            reason: UnsupportedReason::InconsistentAdvertisements,
        })
}

fn classify_raop_observation(observation: &DiscoveryObservation) -> ReceiverCapability {
    if !matches!(advertises_airplay2(&observation.txt), Ok(false)) {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::AirPlay2Unsupported,
        };
    }
    let (Ok(status_flags), Ok(pairing_required), Ok(password_required)) = (
        advertised_status_flags(&observation.txt),
        advertised_pairing_requirement(&observation.txt),
        advertised_password_requirement(&observation.txt),
    ) else {
        // Malformed security metadata prevents us from proving that pairing is
        // not required. Preserve the existing public reason set and fail closed
        // at the first unsupported protocol operation.
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::PairingRequired,
        };
    };
    if status_flags & (STATUS_FLAG_PIN_REQUIRED | STATUS_FLAG_ONE_TIME_PAIRING_REQUIRED) != 0
        || pairing_required
    {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::PairingRequired,
        };
    }

    let Some(encryption) = txt_tokens(&observation.txt, "et") else {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::MissingEncryptionAdvertisement,
        };
    };
    if !encryption.contains("0") && !encryption.contains("NONE") {
        let reason = if encryption.contains("3")
            || encryption.contains("5")
            || encryption.contains("FAIRPLAY")
        {
            UnsupportedReason::FairPlayEncryptionRequired
        } else if encryption.contains("4") || encryption.contains("MFISAP") {
            UnsupportedReason::MfiSapEncryptionRequired
        } else if encryption.contains("1")
            || encryption.contains("RSA")
            || encryption.contains("AES")
            || encryption.contains("RSA-AES")
        {
            UnsupportedReason::RsaAesEncryptionRequired
        } else {
            UnsupportedReason::UnsupportedEncryption
        };
        return ReceiverCapability::Unsupported { reason };
    }

    let Some(codecs) = txt_tokens(&observation.txt, "cn") else {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::MissingCodecAdvertisement,
        };
    };
    if !codecs.contains("0") && !codecs.contains("PCM") && !codecs.contains("L16") {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::UnsupportedCodec,
        };
    }
    if !txt_optional_numeric_choice_contains(&observation.txt, "sr", MVP_SAMPLE_RATE) {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::UnsupportedSampleRate,
        };
    }
    if !txt_optional_numeric_choice_contains(&observation.txt, "ss", u32::from(MVP_BITS_PER_SAMPLE))
    {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::UnsupportedSampleSize,
        };
    }
    if !txt_optional_numeric_choice_contains(&observation.txt, "ch", u32::from(MVP_CHANNELS)) {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::UnsupportedChannelCount,
        };
    }

    let Some(transports) = txt_tokens(&observation.txt, "tp") else {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::MissingTransportAdvertisement,
        };
    };
    if !transports.contains("UDP") {
        return ReceiverCapability::Unsupported {
            reason: UnsupportedReason::UnsupportedTransport,
        };
    }

    ReceiverCapability::SupportedClassicRaop {
        transports: BTreeSet::from([RaopTransport::Udp]),
        password_required: password_required || status_flags & STATUS_FLAG_PASSWORD_REQUIRED != 0,
    }
}

fn advertises_airplay2(txt: &TxtMap) -> Result<bool, ()> {
    let explicit_marker = match txt.get("ap2") {
        None => false,
        Some(Some(value))
            if value.eq_ignore_ascii_case("true")
                || value.eq_ignore_ascii_case("yes")
                || value == "1" =>
        {
            true
        }
        Some(Some(value))
            if value.eq_ignore_ascii_case("false")
                || value.eq_ignore_ascii_case("no")
                || value == "0" =>
        {
            false
        }
        Some(None | Some(_)) => return Err(()),
    };
    Ok(explicit_marker
        || txt
            .get("protocol")
            .and_then(Option::as_deref)
            .is_some_and(|value| {
                value.eq_ignore_ascii_case("airplay2") || value.eq_ignore_ascii_case("airplay 2")
            })
        || txt
            .get("protovers")
            .and_then(Option::as_deref)
            .and_then(|value| value.split('.').next())
            .and_then(|major| major.parse::<u16>().ok())
            .is_some_and(|major| major >= 2))
}

fn advertised_pairing_requirement(txt: &TxtMap) -> Result<bool, ()> {
    let mut required = false;
    for key in ["pairing", "pair", "requirespairing"] {
        let Some(value) = txt.get(key) else {
            continue;
        };
        let Some(value) = value.as_deref() else {
            return Err(());
        };
        if value.is_empty() {
            return Err(());
        }
        required |= !value.eq_ignore_ascii_case("none")
            && !value.eq_ignore_ascii_case("false")
            && value != "0";
    }

    if let Some(value) = txt.get("auth") {
        let Some(value) = value.as_deref() else {
            return Err(());
        };
        if value.is_empty() {
            return Err(());
        }
        required |= !value.eq_ignore_ascii_case("none") && !value.eq_ignore_ascii_case("digest");
    }

    Ok(required)
}

fn advertised_password_requirement(txt: &TxtMap) -> Result<bool, ()> {
    match txt.get("pw") {
        None => Ok(false),
        Some(Some(value))
            if value.eq_ignore_ascii_case("true")
                || value.eq_ignore_ascii_case("yes")
                || value == "1" =>
        {
            Ok(true)
        }
        Some(Some(value))
            if value.eq_ignore_ascii_case("false")
                || value.eq_ignore_ascii_case("no")
                || value == "0" =>
        {
            Ok(false)
        }
        Some(None | Some(_)) => Err(()),
    }
}

fn advertised_status_flags(txt: &TxtMap) -> Result<u64, ()> {
    let mut combined = 0_u64;
    for key in ["sf", "flags"] {
        let Some(value) = txt.get(key) else {
            continue;
        };
        let Some(value) = value.as_deref() else {
            return Err(());
        };
        let value = value.trim();
        let digits = value
            .strip_prefix("0x")
            .or_else(|| value.strip_prefix("0X"))
            .unwrap_or(value);
        if digits.is_empty()
            || digits.len() > MAX_STATUS_FLAGS_HEX_DIGITS
            || !digits.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(());
        }
        combined |= u64::from_str_radix(digits, 16).map_err(|_| ())?;
    }
    Ok(combined)
}

fn txt_tokens(txt: &TxtMap, key: &str) -> Option<BTreeSet<String>> {
    txt.get(key).and_then(Option::as_deref).map(|value| {
        value
            .split(',')
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(str::to_ascii_uppercase)
            .collect()
    })
}

fn txt_optional_numeric_choice_contains(txt: &TxtMap, key: &str, expected: u32) -> bool {
    match txt.get(key) {
        None => true,
        Some(Some(value)) => value
            .split(',')
            .map(str::trim)
            .any(|token| token.parse::<u32>() == Ok(expected)),
        Some(None) => false,
    }
}

fn derive_identity(
    kind: ServiceKind,
    fullname: &str,
    txt: &TxtMap,
) -> Result<ReceiverIdentity, DiscoveryError> {
    Ok(match kind {
        ServiceKind::Raop => identity_from_raop(fullname, txt)?,
        ServiceKind::AirPlay => identity_from_airplay(fullname, txt)?,
    })
}

fn derive_display_name(kind: ServiceKind, fullname: &str, txt: &TxtMap) -> String {
    let advertised = txt
        .get("fn")
        .and_then(Option::as_deref)
        .filter(|name| !name.is_empty());
    let suffix = kind.service_type();
    let instance = service_instance(fullname, suffix)
        .ok()
        .and_then(|instance| match kind {
            ServiceKind::Raop => instance
                .split_once('@')
                .map(|(_, name)| name)
                .or(Some(instance)),
            ServiceKind::AirPlay => Some(instance),
        });
    sanitize_display_name(advertised.or(instance).unwrap_or("AirPlay Receiver"))
}

fn sanitize_display_name(value: &str) -> String {
    let mut output = String::with_capacity(value.len().min(MAX_DISPLAY_NAME_CHARS));
    let mut previous_was_space = false;
    for character in value.chars().take(MAX_DISPLAY_NAME_CHARS) {
        let character = if character.is_control() {
            ' '
        } else {
            character
        };
        if character.is_whitespace() {
            if !previous_was_space {
                output.push(' ');
            }
            previous_was_space = true;
        } else {
            output.push(character);
            previous_was_space = false;
        }
    }
    let output = output.trim();
    if output.is_empty() {
        "AirPlay Receiver".to_owned()
    } else {
        output.to_owned()
    }
}

fn validate_dns_name(field: &'static str, value: &str) -> Result<(), DiscoveryError> {
    if value.is_empty() || value.len() > MAX_DNS_NAME_BYTES || value.chars().any(char::is_control) {
        Err(DiscoveryError::InvalidDnsName { field })
    } else {
        Ok(())
    }
}

fn validate_interface(interface: &InterfaceKey) -> Result<(), DiscoveryError> {
    if interface.name.len() > MAX_INTERFACE_NAME_BYTES
        || interface.name.chars().any(char::is_control)
    {
        Err(DiscoveryError::InvalidInterface)
    } else {
        Ok(())
    }
}

fn validated_addresses(
    addresses: impl IntoIterator<Item = IpAddr>,
) -> Result<BTreeSet<IpAddr>, DiscoveryError> {
    let mut result = BTreeSet::new();
    for address in addresses {
        if is_usable_unicast(address) {
            result.insert(address);
        }
        if result.len() > MAX_ADDRESSES_PER_OBSERVATION {
            return Err(DiscoveryError::TooManyAddresses);
        }
    }
    if result.is_empty() {
        Err(DiscoveryError::NoUsableAddresses)
    } else {
        Ok(result)
    }
}

fn is_usable_unicast(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => {
            !address.is_unspecified() && !address.is_multicast() && address != Ipv4Addr::BROADCAST
        }
        IpAddr::V6(address) => !address.is_unspecified() && !address.is_multicast(),
    }
}

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

fn elapsed_millis(started: Instant) -> u64 {
    duration_millis(started.elapsed())
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    use mdns_sd::{ServiceEvent, ServiceInfo};

    use crate::identity::ReceiverIdentity;
    use crate::receiver::{RaopTransport, ReceiverCapability, ReceiverState, UnsupportedReason};

    use super::{
        DEFAULT_DISCOVERY_QUERY_INTERVAL, DEFAULT_MDNS_PORT, DiscoveryConfig, DiscoveryError,
        DiscoveryNotification, DiscoveryObservation, InterfaceKey, MAX_DISCOVERY_QUERY_INTERVAL,
        MAX_MISSED_QUERY_EPOCHS, MIN_DISCOVERY_QUERY_INTERVAL, NotificationPublisher,
        QUERY_PULSE_DURATION, QUERY_PULSE_STOP_ACK_TIMEOUT, QueryPulseFreshness,
        QueryPulseSchedule, RAOP_SERVICE_TYPE, ReceiverRegistry, RegistryError, RegistryEvent,
        RegistryLimits, ServiceEventAuthority, ServiceKey, ServiceKind, SnapshotApplication,
        TxtLimits, apply_resolved_snapshot, browser_config_is_valid, classify_observations,
        classify_raop_observation, parse_txt_properties, process_service_event,
    };

    fn interface(index: u32, name: &str) -> InterfaceKey {
        InterfaceKey {
            index,
            name: name.to_owned(),
        }
    }

    fn properties(entries: &[(&str, &str)]) -> Vec<(String, Option<Vec<u8>>)> {
        entries
            .iter()
            .map(|(key, value)| ((*key).to_owned(), Some(value.as_bytes().to_vec())))
            .collect()
    }

    fn raop(
        id: &str,
        name: &str,
        hostname: &str,
        interface: InterfaceKey,
        addresses: &[IpAddr],
        properties: &[(&str, &str)],
    ) -> DiscoveryObservation {
        DiscoveryObservation::from_parts(
            ServiceKind::Raop,
            &format!("{id}@{name}._raop._tcp.local."),
            hostname,
            7_000,
            interface,
            addresses.iter().copied(),
            self::properties(properties),
            TxtLimits::default(),
        )
        .unwrap()
    }

    fn airplay(
        id: &str,
        name: &str,
        interface: InterfaceKey,
        address: IpAddr,
    ) -> DiscoveryObservation {
        DiscoveryObservation::from_parts(
            ServiceKind::AirPlay,
            &format!("{name}._airplay._tcp.local."),
            "receiver.local.",
            7_000,
            interface,
            [address],
            self::properties(&[("deviceid", id), ("features", "0x1")]),
            TxtLimits::default(),
        )
        .unwrap()
    }

    fn supported_properties() -> [(&'static str, &'static str); 4] {
        [
            ("cn", "0,1"),
            ("tp", "UDP,TCP"),
            ("et", "0,1"),
            ("pw", "false"),
        ]
    }

    fn capability_with_status_flag(key: &str, value: &str) -> ReceiverCapability {
        let observation = raop(
            "001122334455",
            "Status Flags",
            "status-flags.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &[("cn", "0"), ("tp", "UDP"), ("et", "0"), (key, value)],
        );
        classify_raop_observation(&observation)
    }

    fn capability_with_companion_status_flag(key: &str, value: &str) -> ReceiverCapability {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let raop = raop(
            "001122334455",
            "Status Flags",
            "status-flags.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let mut companion = airplay(
            "00:11:22:33:44:55",
            "Status Flags",
            interface(4, "Ethernet"),
            address,
        );
        companion.txt.insert(key.to_owned(), Some(value.to_owned()));
        classify_observations([&raop, &companion].into_iter())
    }

    fn capability_with_security_property(key: &str, value: Option<&str>) -> ReceiverCapability {
        let mut observation = raop(
            "001122334455",
            "Security Metadata",
            "security-metadata.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &[("cn", "0"), ("tp", "UDP"), ("et", "0")],
        );
        observation
            .txt
            .insert(key.to_owned(), value.map(str::to_owned));
        classify_raop_observation(&observation)
    }

    fn capability_with_companion_security_property(
        key: &str,
        value: Option<&str>,
    ) -> ReceiverCapability {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let raop = raop(
            "001122334455",
            "Security Metadata",
            "security-metadata.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let mut companion = airplay(
            "00:11:22:33:44:55",
            "Security Metadata",
            interface(4, "Ethernet"),
            address,
        );
        companion
            .txt
            .insert(key.to_owned(), value.map(str::to_owned));
        classify_observations([&raop, &companion].into_iter())
    }

    fn registry_limits(
        max_receivers: usize,
        max_supported_receivers: usize,
        max_known_services: usize,
        max_services_per_receiver: usize,
        max_observations: usize,
        max_observations_per_receiver: usize,
    ) -> RegistryLimits {
        RegistryLimits {
            max_receivers,
            max_supported_receivers,
            max_known_services,
            max_services_per_receiver,
            max_observations,
            max_observations_per_receiver,
        }
    }

    #[test]
    fn txt_parser_normalises_keys_and_preserves_flags() {
        let parsed = parse_txt_properties(
            vec![("CN", Some(b"0,1".to_vec())), ("flag", None)],
            TxtLimits::default(),
        )
        .unwrap();
        assert_eq!(parsed.get("cn"), Some(&Some("0,1".to_owned())));
        assert_eq!(parsed.get("flag"), Some(&None));
    }

    #[test]
    fn malformed_and_inconsistent_txt_is_rejected() {
        let invalid_key = parse_txt_properties(
            vec![("bad=key", Some(b"value".to_vec()))],
            TxtLimits::default(),
        )
        .unwrap_err();
        assert!(matches!(invalid_key, DiscoveryError::InvalidTxtKey(_)));

        let duplicate = parse_txt_properties(
            vec![
                ("deviceid", Some(b"001122334455".to_vec())),
                ("DeviceID", Some(b"AABBCCDDEEFF".to_vec())),
            ],
            TxtLimits::default(),
        )
        .unwrap_err();
        assert!(matches!(duplicate, DiscoveryError::DuplicateTxtKey(_)));

        let invalid_utf8 =
            parse_txt_properties(vec![("pk", Some(vec![0xff, 0xfe]))], TxtLimits::default())
                .unwrap_err();
        assert!(matches!(invalid_utf8, DiscoveryError::InvalidTxtUtf8(_)));
    }

    #[test]
    fn oversized_txt_is_rejected_before_allocation_growth() {
        let limits = TxtLimits {
            max_records: 2,
            max_total_bytes: 20,
            max_value_bytes: 10,
        };
        let too_large =
            parse_txt_properties(vec![("fn", Some(vec![b'x'; 11]))], limits).unwrap_err();
        assert!(matches!(too_large, DiscoveryError::TxtValueTooLarge { .. }));

        let too_many = parse_txt_properties(
            vec![
                ("a", Some(b"1".to_vec())),
                ("b", Some(b"2".to_vec())),
                ("c", Some(b"3".to_vec())),
            ],
            limits,
        )
        .unwrap_err();
        assert_eq!(too_many, DiscoveryError::TxtTooManyRecords);
    }

    #[test]
    fn missing_stable_identifier_is_rejected() {
        let error = DiscoveryObservation::from_parts(
            ServiceKind::AirPlay,
            "Living Room._airplay._tcp.local.",
            "receiver.local.",
            7_000,
            interface(4, "Ethernet"),
            [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            Vec::<(String, Option<Vec<u8>>)>::new(),
            TxtLimits::default(),
        )
        .unwrap_err();
        assert!(matches!(error, DiscoveryError::Identity(_)));
    }

    #[test]
    fn duplicate_service_snapshot_is_idempotent() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));

        let first = registry
            .replace_service_snapshot(service.clone(), [observation.clone()], 100)
            .unwrap();
        let duplicate = registry
            .replace_service_snapshot(service, [observation], 100)
            .unwrap();

        assert!(matches!(first.as_slice(), [RegistryEvent::Added { .. }]));
        assert!(duplicate.is_empty());
        assert_eq!(registry.len(), 1);
    }

    #[test]
    fn addresses_and_interfaces_merge_without_duplicate_receiver() {
        let first = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
                IpAddr::V6(Ipv6Addr::LOCALHOST),
            ],
            &supported_properties(),
        );
        let second = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V4(Ipv4Addr::new(198, 51, 100, 20))],
            &supported_properties(),
        );
        let service = first.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service, [first, second], 100)
            .unwrap();

        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.observations.len(), 2);
        let addresses = snapshot
            .observations
            .iter()
            .flat_map(|observation| observation.addresses.iter())
            .copied()
            .collect::<BTreeSet<_>>();
        assert_eq!(addresses.len(), 3);
    }

    #[test]
    fn hostname_and_ip_update_preserve_identity() {
        let first = raop(
            "001122334455",
            "Living Room",
            "old.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let mut updated = first.clone();
        updated.hostname = "new.local.".to_owned();
        updated.addresses = BTreeSet::from([IpAddr::V4(Ipv4Addr::new(192, 0, 2, 99))]);
        let identity = first.identity.clone();
        let service = first.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [first], 100)
            .unwrap();
        registry
            .replace_service_snapshot(service, [updated], 200)
            .unwrap();

        assert_eq!(registry.len(), 1);
        let snapshot = registry.get(&identity).unwrap();
        assert_eq!(snapshot.observations[0].hostname, "new.local.");
        assert!(
            snapshot.observations[0]
                .addresses
                .contains(&IpAddr::V4(Ipv4Addr::new(192, 0, 2, 99)))
        );
    }

    #[test]
    fn partial_interface_removal_keeps_receiver_online() {
        let ethernet = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let wifi = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V4(Ipv4Addr::new(198, 51, 100, 20))],
            &supported_properties(),
        );
        let wifi_key = wifi.key.clone();
        let service = ethernet.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service, [ethernet, wifi], 100)
            .unwrap();
        registry.remove_observation(&wifi_key, 200).unwrap();

        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.state, ReceiverState::OnlineSupported);
        assert_eq!(snapshot.observations.len(), 1);
        assert_eq!(snapshot.observations[0].key.interface.index, 4);
    }

    #[test]
    fn rapid_remove_and_readd_cancels_grace_without_new_receiver() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let identity = observation.identity.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [observation.clone()], 100)
            .unwrap();
        let removed = registry.remove_service(&service, 200).unwrap();
        assert!(matches!(
            removed.as_slice(),
            [RegistryEvent::GraceStarted { .. }]
        ));
        assert_eq!(
            registry.get(&identity).unwrap().state,
            ReceiverState::GraceOffline
        );

        let readded = registry
            .replace_service_snapshot(service, [observation], 500)
            .unwrap();
        assert!(matches!(
            readded.as_slice(),
            [RegistryEvent::GraceCancelled { .. }]
        ));
        assert_eq!(
            registry.get(&identity).unwrap().state,
            ReceiverState::OnlineSupported
        );
        assert!(registry.tick(8_199).unwrap().is_empty());
    }

    #[test]
    fn genuine_removal_expires_at_configured_grace() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_millis(500));
        registry
            .replace_service_snapshot(service.clone(), [observation], 1_000)
            .unwrap();
        registry.remove_service(&service, 1_100).unwrap();

        assert!(registry.tick(1_599).unwrap().is_empty());
        let expired = registry.tick(1_600).unwrap();
        assert!(matches!(
            expired.as_slice(),
            [
                RegistryEvent::Removing { .. },
                RegistryEvent::Removed { .. }
            ]
        ));
        assert!(registry.is_empty());
    }

    #[test]
    fn airplay_metadata_merges_with_raop_by_stable_identity() {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let raop = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let airplay = airplay(
            "00:11:22:33:44:55",
            "Living Room",
            interface(4, "Ethernet"),
            address,
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(raop.key.service.clone(), [raop], 100)
            .unwrap();
        registry
            .replace_service_snapshot(airplay.key.service.clone(), [airplay], 110)
            .unwrap();

        assert_eq!(registry.len(), 1);
        assert_eq!(registry.snapshots()[0].observations.len(), 2);
    }

    #[test]
    fn unsupported_capability_combinations_are_explicit() {
        let address = [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))];
        let unsupported_codec = raop(
            "001122334455",
            "Codec",
            "codec.local.",
            interface(4, "Ethernet"),
            &address,
            &[("cn", "2,3"), ("tp", "UDP"), ("et", "0")],
        );
        let unsupported_transport = raop(
            "001122334456",
            "Transport",
            "transport.local.",
            interface(4, "Ethernet"),
            &address,
            &[("cn", "0"), ("tp", "QUIC"), ("et", "0")],
        );
        let unsupported_encryption = raop(
            "001122334457",
            "Encryption",
            "encryption.local.",
            interface(4, "Ethernet"),
            &address,
            &[("cn", "0"), ("tp", "UDP"), ("et", "3,5")],
        );

        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        for observation in [
            unsupported_codec,
            unsupported_transport,
            unsupported_encryption,
        ] {
            registry
                .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
                .unwrap();
        }
        let reasons = registry
            .snapshots()
            .into_iter()
            .filter_map(|snapshot| match snapshot.capability {
                ReceiverCapability::Unsupported { reason } => Some(reason),
                ReceiverCapability::SupportedClassicRaop { .. } => None,
            })
            .collect::<BTreeSet<_>>();
        assert_eq!(
            reasons,
            BTreeSet::from([
                UnsupportedReason::UnsupportedCodec,
                UnsupportedReason::UnsupportedTransport,
                UnsupportedReason::FairPlayEncryptionRequired,
            ])
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn sender_profile_rejections_report_the_first_unsupported_operation() {
        let address = [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))];
        let cases = [
            (
                raop(
                    "001122334451",
                    "RSA",
                    "rsa.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "UDP"), ("et", "1")],
                ),
                UnsupportedReason::RsaAesEncryptionRequired,
            ),
            (
                raop(
                    "001122334452",
                    "MFi",
                    "mfi.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "UDP"), ("et", "4")],
                ),
                UnsupportedReason::MfiSapEncryptionRequired,
            ),
            (
                raop(
                    "001122334453",
                    "FairPlay",
                    "fairplay.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "UDP"), ("et", "3,5")],
                ),
                UnsupportedReason::FairPlayEncryptionRequired,
            ),
            (
                raop(
                    "001122334454",
                    "ALAC only",
                    "alac.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "1"), ("tp", "UDP"), ("et", "0")],
                ),
                UnsupportedReason::UnsupportedCodec,
            ),
            (
                raop(
                    "001122334455",
                    "TCP only",
                    "tcp.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "TCP"), ("et", "0")],
                ),
                UnsupportedReason::UnsupportedTransport,
            ),
            (
                raop(
                    "001122334456",
                    "Pairing",
                    "pairing.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "UDP"), ("et", "0"), ("pairing", "hap")],
                ),
                UnsupportedReason::PairingRequired,
            ),
            (
                raop(
                    "001122334457",
                    "AirPlay 2",
                    "airplay2.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "UDP"), ("et", "0"), ("ap2", "true")],
                ),
                UnsupportedReason::AirPlay2Unsupported,
            ),
            (
                raop(
                    "001122334458",
                    "No encryption profile",
                    "missing-et.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("tp", "UDP")],
                ),
                UnsupportedReason::MissingEncryptionAdvertisement,
            ),
            (
                raop(
                    "001122334459",
                    "No codec profile",
                    "missing-cn.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("tp", "UDP"), ("et", "0")],
                ),
                UnsupportedReason::MissingCodecAdvertisement,
            ),
            (
                raop(
                    "00112233445A",
                    "No transport profile",
                    "missing-tp.local.",
                    interface(4, "Ethernet"),
                    &address,
                    &[("cn", "0"), ("et", "0")],
                ),
                UnsupportedReason::MissingTransportAdvertisement,
            ),
        ];

        for (observation, expected_reason) in cases {
            let registry =
                ReceiverRegistry::reconstruct(Duration::from_secs(8), [observation], 100).unwrap();
            assert_eq!(
                registry.snapshots()[0].capability,
                ReceiverCapability::Unsupported {
                    reason: expected_reason,
                }
            );
            assert_eq!(
                registry.snapshots()[0].state,
                ReceiverState::OnlineUnsupported
            );
        }
    }

    #[test]
    fn textual_pcm_l16_profile_selects_udp_only() {
        let observation = raop(
            "001122334455",
            "PCM",
            "pcm.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &[("cn", "PCM,L16"), ("tp", "TCP,UDP"), ("et", "NONE")],
        );
        let registry =
            ReceiverRegistry::reconstruct(Duration::from_secs(8), [observation], 100).unwrap();
        assert_eq!(
            registry.snapshots()[0].capability,
            ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            }
        );
    }

    #[test]
    fn sf_one_time_pairing_bit_is_unsupported() {
        assert_eq!(
            capability_with_status_flag("sf", "0x244"),
            ReceiverCapability::Unsupported {
                reason: UnsupportedReason::PairingRequired,
            }
        );
    }

    #[test]
    fn flags_pin_required_bit_is_unsupported() {
        assert_eq!(
            capability_with_status_flag("flags", "0x8"),
            ReceiverCapability::Unsupported {
                reason: UnsupportedReason::PairingRequired,
            }
        );
    }

    #[test]
    fn flags_password_required_bit_marks_supported_profile() {
        assert_eq!(
            capability_with_status_flag("flags", "0x80"),
            ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: true,
            }
        );
    }

    #[test]
    fn malformed_status_flags_fail_closed() {
        for (key, value) in [
            ("sf", ""),
            ("sf", "0x"),
            ("flags", "not-hex"),
            ("flags", "0x10000000000000000"),
        ] {
            assert_eq!(
                capability_with_status_flag(key, value),
                ReceiverCapability::Unsupported {
                    reason: UnsupportedReason::PairingRequired,
                },
                "{key}={value:?} must not select a sender profile",
            );
        }
    }

    #[test]
    fn benign_status_flags_preserve_supported_profile() {
        assert_eq!(
            capability_with_status_flag("sf", "0x4"),
            ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            }
        );
    }

    #[test]
    fn companion_pairing_flags_prevent_raop_admission() {
        for (key, value) in [("sf", "0x244"), ("flags", "0x8"), ("sf", "not-hex")] {
            assert_eq!(
                capability_with_companion_status_flag(key, value),
                ReceiverCapability::Unsupported {
                    reason: UnsupportedReason::PairingRequired,
                },
                "companion {key}={value:?} must prevent sender admission",
            );
        }
    }

    #[test]
    fn companion_password_and_benign_flags_are_merged_into_raop_profile() {
        assert_eq!(
            capability_with_companion_status_flag("sf", "0x4"),
            ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            }
        );
        assert_eq!(
            capability_with_companion_status_flag("flags", "0x80"),
            ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: true,
            }
        );
    }

    #[test]
    fn key_only_security_fields_fail_closed() {
        for key in ["pw", "pairing", "pair", "requirespairing", "auth"] {
            let expected = ReceiverCapability::Unsupported {
                reason: UnsupportedReason::PairingRequired,
            };
            assert_eq!(
                capability_with_security_property(key, None),
                expected,
                "key-only RAOP {key} must prevent sender admission",
            );
            assert_eq!(
                capability_with_companion_security_property(key, None),
                expected,
                "key-only companion {key} must prevent sender admission",
            );
        }
    }

    #[test]
    fn malformed_security_values_fail_closed() {
        for (key, value) in [
            ("pw", ""),
            ("pw", "unknown"),
            ("pairing", ""),
            ("pair", ""),
            ("requirespairing", ""),
            ("auth", ""),
        ] {
            let expected = ReceiverCapability::Unsupported {
                reason: UnsupportedReason::PairingRequired,
            };
            assert_eq!(
                capability_with_security_property(key, Some(value)),
                expected,
                "malformed RAOP {key}={value:?} must prevent sender admission",
            );
            assert_eq!(
                capability_with_companion_security_property(key, Some(value)),
                expected,
                "malformed companion {key}={value:?} must prevent sender admission",
            );
        }
    }

    #[test]
    fn airplay2_marker_is_strict_and_fails_closed() {
        let unsupported = ReceiverCapability::Unsupported {
            reason: UnsupportedReason::AirPlay2Unsupported,
        };
        for value in [None, Some(""), Some("unknown")] {
            assert_eq!(
                capability_with_security_property("ap2", value),
                unsupported,
                "malformed RAOP ap2={value:?} must prevent classic sender admission",
            );
        }
        for value in ["true", "yes", "1"] {
            assert_eq!(
                capability_with_security_property("ap2", Some(value)),
                unsupported,
                "explicit RAOP ap2={value:?} must select the AirPlay 2 rejection",
            );
        }
        for value in ["false", "no", "0"] {
            assert_eq!(
                capability_with_security_property("ap2", Some(value)),
                ReceiverCapability::SupportedClassicRaop {
                    transports: BTreeSet::from([RaopTransport::Udp]),
                    password_required: false,
                },
                "explicit RAOP ap2={value:?} must preserve the classic profile",
            );
        }

        let mut airplay_only = airplay(
            "00:11:22:33:44:55",
            "Malformed AirPlay 2 Marker",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
        );
        airplay_only.txt.insert("ap2".to_owned(), None);
        assert_eq!(
            classify_observations([&airplay_only].into_iter()),
            unsupported,
            "key-only AirPlay companion ap2 must fail closed",
        );
    }

    #[test]
    fn explicit_benign_security_values_preserve_supported_profile() {
        for (key, value) in [
            ("pw", "false"),
            ("pw", "no"),
            ("pw", "0"),
            ("pairing", "false"),
            ("pairing", "none"),
            ("pairing", "0"),
            ("pair", "none"),
            ("requirespairing", "false"),
            ("auth", "none"),
            ("auth", "digest"),
        ] {
            let expected = ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: false,
            };
            assert_eq!(
                capability_with_security_property(key, Some(value)),
                expected,
                "benign RAOP {key}={value:?} must preserve sender admission",
            );
            assert_eq!(
                capability_with_companion_security_property(key, Some(value)),
                expected,
                "benign companion {key}={value:?} must preserve sender admission",
            );
        }
    }

    #[test]
    fn conflicting_advertised_pcm_format_is_unsupported() {
        let address = [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))];
        let cases = [
            (
                "001122334451",
                "sample-rate.local.",
                ("sr", "48000"),
                UnsupportedReason::UnsupportedSampleRate,
            ),
            (
                "001122334452",
                "sample-size.local.",
                ("ss", "24"),
                UnsupportedReason::UnsupportedSampleSize,
            ),
            (
                "001122334453",
                "channels.local.",
                ("ch", "1"),
                UnsupportedReason::UnsupportedChannelCount,
            ),
        ];

        for (id, hostname, conflicting_field, expected_reason) in cases {
            let properties = [("cn", "0"), ("tp", "UDP"), ("et", "0"), conflicting_field];
            let observation = raop(
                id,
                "Conflicting PCM format",
                hostname,
                interface(4, "Ethernet"),
                &address,
                &properties,
            );

            assert_eq!(
                classify_raop_observation(&observation),
                ReceiverCapability::Unsupported {
                    reason: expected_reason,
                },
                "field {}={} must not select the fixed L16 profile",
                conflicting_field.0,
                conflicting_field.1,
            );
        }
    }

    #[test]
    fn pcm_format_fields_are_optional_but_must_offer_the_fixed_choice() {
        let address = [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))];
        let absent = raop(
            "001122334454",
            "Implicit PCM format",
            "implicit-format.local.",
            interface(4, "Ethernet"),
            &address,
            &[("cn", "0"), ("tp", "UDP"), ("et", "0")],
        );
        let compatible_lists = raop(
            "001122334455",
            "Explicit PCM format",
            "explicit-format.local.",
            interface(4, "Ethernet"),
            &address,
            &[
                ("cn", "0"),
                ("tp", "UDP"),
                ("et", "0"),
                ("sr", "48000, 44100"),
                ("ss", "24, 16"),
                ("ch", "1, 2"),
            ],
        );

        for observation in [&absent, &compatible_lists] {
            assert_eq!(
                classify_raop_observation(observation),
                ReceiverCapability::SupportedClassicRaop {
                    transports: BTreeSet::from([RaopTransport::Udp]),
                    password_required: false,
                }
            );
        }
    }

    #[test]
    fn reconstruction_order_is_deterministic() {
        let first = raop(
            "001122334455",
            "First",
            "first.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let second = raop(
            "AABBCCDDEEFF",
            "Second",
            "second.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20))],
            &supported_properties(),
        );

        let forward = ReceiverRegistry::reconstruct(
            Duration::from_secs(8),
            [first.clone(), second.clone()],
            100,
        )
        .unwrap();
        let reverse =
            ReceiverRegistry::reconstruct(Duration::from_secs(8), [second, first], 100).unwrap();
        assert_eq!(forward.snapshots(), reverse.snapshots());
    }

    #[test]
    fn service_identity_change_is_rejected_without_stale_mutation() {
        let first = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = first.key.service.clone();
        let mut malicious = first.clone();
        malicious.identity = ReceiverIdentity::parse("AABBCCDDEEFF").unwrap();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [first], 100)
            .unwrap();
        let before = registry.snapshots();

        let error = registry
            .replace_service_snapshot(service, [malicious], 200)
            .unwrap_err();
        assert_eq!(error, super::RegistryError::ServiceIdentityChanged);
        assert_eq!(registry.snapshots(), before);
    }

    #[test]
    fn service_identity_takeover_is_rejected_during_offline_grace() {
        let first = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = first.key.service.clone();
        let mut takeover = first.clone();
        takeover.identity = ReceiverIdentity::parse("AABBCCDDEEFF").unwrap();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [first], 100)
            .unwrap();
        registry.remove_service(&service, 200).unwrap();

        let error = registry
            .replace_service_snapshot(service, [takeover], 300)
            .unwrap_err();
        assert_eq!(error, super::RegistryError::ServiceIdentityChanged);
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.snapshots()[0].state, ReceiverState::GraceOffline);
    }

    #[test]
    fn receiver_admission_limit_is_atomic() {
        let limits = registry_limits(2, 2, 4, 2, 4, 2);
        let mut registry = ReceiverRegistry::with_limits(Duration::from_secs(8), limits).unwrap();
        for (id, name, octet) in [
            ("001122334455", "First", 10),
            ("AABBCCDDEEFF", "Second", 20),
        ] {
            let observation = airplay(
                id,
                name,
                interface(4, "Ethernet"),
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, octet)),
            );
            registry
                .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
                .unwrap();
        }
        let before = registry.snapshots();
        let rejected = airplay(
            "102030405060",
            "Third",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 30)),
        );
        let error = registry
            .replace_service_snapshot(rejected.key.service.clone(), [rejected], 200)
            .unwrap_err();

        assert_eq!(error, RegistryError::ReceiverLimitExceeded { maximum: 2 });
        assert_eq!(registry.snapshots(), before);
        assert_eq!(registry.known_services.len(), 2);
    }

    #[test]
    fn supported_receiver_slot_is_reserved_through_offline_grace() {
        let limits = registry_limits(2, 1, 4, 2, 4, 2);
        let mut registry =
            ReceiverRegistry::with_limits(Duration::from_millis(100), limits).unwrap();
        let first = raop(
            "001122334455",
            "First",
            "first.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let first_service = first.key.service.clone();
        registry
            .replace_service_snapshot(first_service.clone(), [first], 0)
            .unwrap();
        registry.remove_service(&first_service, 10).unwrap();

        let second = raop(
            "AABBCCDDEEFF",
            "Second",
            "second.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20))],
            &supported_properties(),
        );
        let second_service = second.key.service.clone();
        let error = registry
            .replace_service_snapshot(second_service.clone(), [second.clone()], 109)
            .unwrap_err();
        assert_eq!(
            error,
            RegistryError::SupportedReceiverLimitExceeded { maximum: 1 }
        );
        assert_eq!(registry.len(), 1);
        assert_eq!(registry.snapshots()[0].state, ReceiverState::GraceOffline);

        registry.tick(110).unwrap();
        registry
            .replace_service_snapshot(second_service, [second], 110)
            .unwrap();
        assert_eq!(registry.len(), 1);
        assert_eq!(
            registry.snapshots()[0].state,
            ReceiverState::OnlineSupported
        );
    }

    #[test]
    fn unsupported_receiver_cannot_upgrade_past_supported_slot_cap() {
        let limits = registry_limits(3, 1, 6, 2, 6, 2);
        let mut registry = ReceiverRegistry::with_limits(Duration::from_secs(8), limits).unwrap();
        let supported = raop(
            "001122334455",
            "Supported",
            "supported.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        registry
            .replace_service_snapshot(supported.key.service.clone(), [supported], 100)
            .unwrap();
        let metadata = airplay(
            "AABBCCDDEEFF",
            "Metadata",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20)),
        );
        registry
            .replace_service_snapshot(metadata.key.service.clone(), [metadata], 100)
            .unwrap();
        let before = registry.snapshots();

        let upgrade = raop(
            "AABBCCDDEEFF",
            "Metadata",
            "metadata.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 20))],
            &supported_properties(),
        );
        let error = registry
            .replace_service_snapshot(upgrade.key.service.clone(), [upgrade], 200)
            .unwrap_err();
        assert_eq!(
            error,
            RegistryError::SupportedReceiverLimitExceeded { maximum: 1 }
        );
        assert_eq!(registry.snapshots(), before);
    }

    #[test]
    fn per_receiver_service_limit_rejects_churn_atomically() {
        let limits = registry_limits(2, 1, 4, 2, 4, 4);
        let mut registry = ReceiverRegistry::with_limits(Duration::from_secs(8), limits).unwrap();
        for name in ["One", "Two"] {
            let observation = airplay(
                "001122334455",
                name,
                interface(4, "Ethernet"),
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
            );
            registry
                .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
                .unwrap();
        }
        let before = registry.snapshots();
        let third = airplay(
            "001122334455",
            "Three",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
        );
        let error = registry
            .replace_service_snapshot(third.key.service.clone(), [third], 200)
            .unwrap_err();

        assert_eq!(
            error,
            RegistryError::ReceiverServiceLimitExceeded { maximum: 2 }
        );
        assert_eq!(registry.snapshots(), before);
        assert_eq!(registry.known_services.len(), 2);
    }

    #[test]
    fn global_and_per_receiver_observation_limits_are_atomic() {
        let global_limits = registry_limits(3, 1, 3, 2, 2, 2);
        let mut global =
            ReceiverRegistry::with_limits(Duration::from_secs(8), global_limits).unwrap();
        for (id, name, octet) in [("001122334455", "One", 10), ("AABBCCDDEEFF", "Two", 20)] {
            let observation = airplay(
                id,
                name,
                interface(4, "Ethernet"),
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, octet)),
            );
            global
                .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
                .unwrap();
        }
        let global_before = global.snapshots();
        let third = airplay(
            "102030405060",
            "Three",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 30)),
        );
        assert_eq!(
            global
                .replace_service_snapshot(third.key.service.clone(), [third], 200)
                .unwrap_err(),
            RegistryError::ObservationLimitExceeded { maximum: 2 }
        );
        assert_eq!(global.snapshots(), global_before);

        let per_receiver_limits = registry_limits(2, 1, 4, 2, 8, 2);
        let mut per_receiver =
            ReceiverRegistry::with_limits(Duration::from_secs(8), per_receiver_limits).unwrap();
        let first = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(1, "One"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let mut second = first.clone();
        second.key.interface = interface(2, "Two");
        let mut third = first.clone();
        third.key.interface = interface(3, "Three");
        let service = first.key.service.clone();
        per_receiver
            .replace_service_snapshot(service.clone(), [first.clone(), second.clone()], 100)
            .unwrap();
        let per_receiver_before = per_receiver.snapshots();
        assert_eq!(
            per_receiver
                .replace_service_snapshot(service, [first, second, third], 200)
                .unwrap_err(),
            RegistryError::ReceiverObservationLimitExceeded { maximum: 2 }
        );
        assert_eq!(per_receiver.snapshots(), per_receiver_before);
    }

    #[test]
    fn reconstruction_rejects_oversized_input_before_building_registry_state() {
        let limits = registry_limits(3, 1, 3, 2, 2, 2);
        let observations = ["001122334455", "AABBCCDDEEFF", "102030405060"]
            .into_iter()
            .enumerate()
            .map(|(index, id)| {
                airplay(
                    id,
                    &format!("Receiver {index}"),
                    interface(4, "Ethernet"),
                    IpAddr::V4(Ipv4Addr::new(192, 0, 2, u8::try_from(index + 1).unwrap())),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            ReceiverRegistry::reconstruct_with_limits(
                Duration::from_secs(8),
                limits,
                observations,
                100,
            )
            .unwrap_err(),
            RegistryError::ObservationLimitExceeded { maximum: 2 }
        );
    }

    #[test]
    fn known_service_quarantine_expires_while_companion_remains() {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let original = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let service = original.key.service.clone();
        let companion = airplay("001122334455", "Room", interface(4, "Ethernet"), address);
        let mut takeover = original.clone();
        takeover.identity = ReceiverIdentity::parse("AABBCCDDEEFF").unwrap();
        let mut registry = ReceiverRegistry::new(Duration::from_millis(100));
        registry
            .replace_service_snapshot(service.clone(), [original], 0)
            .unwrap();
        registry
            .replace_service_snapshot(companion.key.service.clone(), [companion], 0)
            .unwrap();
        registry.remove_service(&service, 10).unwrap();

        assert_eq!(
            registry
                .replace_service_snapshot(service.clone(), [takeover.clone()], 109)
                .unwrap_err(),
            RegistryError::ServiceIdentityChanged
        );
        registry.tick(110).unwrap();
        assert_eq!(registry.len(), 1);
        assert_eq!(
            registry.snapshots()[0].state,
            ReceiverState::OnlineUnsupported
        );

        registry
            .replace_service_snapshot(service, [takeover], 110)
            .unwrap();
        assert_eq!(registry.len(), 2);
    }

    #[test]
    fn quarantined_service_churn_is_bounded_and_pruned() {
        let limits = registry_limits(2, 1, 4, 2, 4, 2);
        let mut registry = ReceiverRegistry::with_limits(Duration::from_secs(1), limits).unwrap();
        let companion = airplay(
            "001122334455",
            "Room",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
        );
        registry
            .replace_service_snapshot(companion.key.service.clone(), [companion], 0)
            .unwrap();

        for (index, name) in ["One", "Two", "Three"].into_iter().enumerate() {
            let observation = raop(
                "001122334455",
                name,
                "receiver.local.",
                interface(4, "Ethernet"),
                &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                &supported_properties(),
            );
            let service = observation.key.service.clone();
            let now_ms = 10 + u64::try_from(index).unwrap() * 10;
            registry
                .replace_service_snapshot(service.clone(), [observation], now_ms)
                .unwrap();
            registry.remove_service(&service, now_ms + 1).unwrap();
        }
        assert_eq!(registry.known_services.len(), 4);

        let fourth = raop(
            "001122334455",
            "Four",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        assert_eq!(
            registry
                .replace_service_snapshot(fourth.key.service.clone(), [fourth.clone()], 40)
                .unwrap_err(),
            RegistryError::KnownServiceLimitExceeded { maximum: 4 }
        );
        assert_eq!(registry.known_services.len(), 4);

        registry.tick(1_031).unwrap();
        assert_eq!(registry.known_services.len(), 1);
        registry
            .replace_service_snapshot(fourth.key.service.clone(), [fourth], 1_031)
            .unwrap();
        assert_eq!(registry.known_services.len(), 2);
    }

    #[test]
    fn browser_identity_change_fails_closed_into_grace() {
        let original = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = original.key.service.clone();
        let identity = original.identity.clone();
        let mut takeover = original.clone();
        takeover.identity = ReceiverIdentity::parse("AABBCCDDEEFF").unwrap();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [original.clone()], 100)
            .unwrap();

        let outcome = apply_resolved_snapshot(&mut registry, &service, vec![takeover], 200);
        let SnapshotApplication::Rejected {
            lifecycle_events,
            error,
        } = outcome
        else {
            panic!("identity takeover unexpectedly applied");
        };
        assert_eq!(error, RegistryError::ServiceIdentityChanged);
        assert!(matches!(
            lifecycle_events.as_slice(),
            [RegistryEvent::GraceStarted { .. }]
        ));
        let snapshot = registry.get(&identity).unwrap();
        assert_eq!(snapshot.state, ReceiverState::GraceOffline);
        assert!(snapshot.observations.is_empty());

        let returned = apply_resolved_snapshot(&mut registry, &service, vec![original], 300);
        assert!(matches!(
            returned,
            SnapshotApplication::Applied(ref events)
                if matches!(events.as_slice(), [RegistryEvent::GraceCancelled { .. }])
        ));
    }

    #[test]
    fn registry_state_is_resynchronised_after_informational_queue_pressure() {
        let (sender, notifications) = mpsc::sync_channel(1);
        let dropped = Arc::new(AtomicU64::new(0));
        let coalesced = Arc::new(AtomicU64::new(0));
        let mut publisher =
            NotificationPublisher::new(sender, Arc::clone(&dropped), Arc::clone(&coalesced));
        let mut registry = ReceiverRegistry::new(Duration::ZERO);

        publisher.publish_informational(DiscoveryNotification::SearchStarted {
            service_type: RAOP_SERVICE_TYPE.to_owned(),
        });
        publisher.publish_informational(DiscoveryNotification::ServiceFound {
            service_type: RAOP_SERVICE_TYPE.to_owned(),
            fullname: "queued._raop._tcp.local.".to_owned(),
        });

        let observation = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let added = registry
            .replace_service_snapshot(service.clone(), [observation], 0)
            .unwrap();
        publisher.publish_registry_events(added);
        assert_eq!(dropped.load(Ordering::Relaxed), 0);
        assert!(publisher.registry_dirty);
        assert!(coalesced.load(Ordering::Relaxed) >= 2);

        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::SearchStarted { .. }
        ));
        publisher.reconcile_registry(&registry);
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::Added { .. }
            }
        ));
        assert!(!publisher.registry_dirty);

        publisher.publish_informational(DiscoveryNotification::ServiceFound {
            service_type: RAOP_SERVICE_TYPE.to_owned(),
            fullname: "pressure._raop._tcp.local.".to_owned(),
        });
        let grace = registry.remove_service(&service, 10).unwrap();
        publisher.publish_registry_events(grace);
        let removed = registry.tick(10).unwrap();
        publisher.publish_registry_events(removed);
        assert_eq!(dropped.load(Ordering::Relaxed), 0);

        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::ServiceFound { .. }
        ));
        publisher.reconcile_registry(&registry);
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::Removed { receiver }
            } if receiver.state == ReceiverState::Removed
        ));
        assert!(!publisher.registry_dirty);
        assert!(publisher.published.is_empty());
        assert_eq!(dropped.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn supported_profile_exposes_transports_and_password_requirement() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &[
                ("cn", "0,1"),
                ("tp", "UDP,TCP"),
                ("et", "0,1"),
                ("pw", "yes"),
            ],
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
            .unwrap();

        assert_eq!(
            registry.snapshots()[0].capability,
            ReceiverCapability::SupportedClassicRaop {
                transports: BTreeSet::from([RaopTransport::Udp]),
                password_required: true,
            }
        );
    }

    #[test]
    fn service_keys_are_dns_case_insensitive() {
        assert_eq!(
            ServiceKey::new(ServiceKind::Raop, "001122334455@Room._RAOP._TCP.LOCAL."),
            ServiceKey::new(ServiceKind::Raop, "001122334455@room._raop._tcp.local.")
        );
    }

    #[test]
    fn duplicate_addresses_are_deduplicated() {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[address, address],
            &supported_properties(),
        );
        assert_eq!(observation.addresses, BTreeSet::from([address]));
    }

    #[test]
    fn unicast_ipv4_and_ipv6_are_retained() {
        let addresses = [
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
            IpAddr::V6(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 1)),
        ];
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &addresses,
            &supported_properties(),
        );
        assert_eq!(observation.addresses, BTreeSet::from(addresses));
    }

    #[test]
    fn deterministic_registry_output_serializes_as_json() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        let events = registry
            .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
            .unwrap();
        let json = serde_json::to_string(&events).unwrap();
        assert!(json.contains("\"event\":\"added\""));
        assert!(json.contains("001122334455"));
    }

    #[test]
    fn invalid_snapshot_is_atomic() {
        let first = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let mut conflicting = first.clone();
        conflicting.identity = ReceiverIdentity::parse("AABBCCDDEEFF").unwrap();
        conflicting.key.interface = interface(8, "Wi-Fi");
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));

        let error = registry
            .replace_service_snapshot(first.key.service.clone(), [first, conflicting], 100)
            .unwrap_err();
        assert_eq!(error, super::RegistryError::InconsistentSnapshotIdentity);
        assert!(registry.is_empty());
    }

    #[test]
    fn airplay_only_receiver_is_explicitly_unsupported() {
        let observation = airplay(
            "00:11:22:33:44:55",
            "Living Room",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
            .unwrap();
        assert_eq!(
            registry.snapshots()[0].capability,
            ReceiverCapability::Unsupported {
                reason: UnsupportedReason::MissingRaopService,
            }
        );
    }

    #[test]
    fn raop_removal_is_graced_while_airplay_metadata_remains() {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let raop = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let airplay = airplay(
            "001122334455",
            "Living Room",
            interface(4, "Ethernet"),
            address,
        );
        let raop_key = raop.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(raop_key.clone(), [raop], 100)
            .unwrap();
        registry
            .replace_service_snapshot(airplay.key.service.clone(), [airplay], 100)
            .unwrap();

        registry
            .replace_service_snapshot(raop_key, Vec::new(), 200)
            .unwrap();
        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.observations.len(), 1);
        assert_eq!(snapshot.state, ReceiverState::GraceOffline);

        let expired = registry.tick(8_200).unwrap();
        assert!(matches!(
            expired.as_slice(),
            [
                RegistryEvent::Removing { .. },
                RegistryEvent::Updated { .. }
            ]
        ));
        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.state, ReceiverState::OnlineUnsupported);
        assert_eq!(snapshot.observations.len(), 1);
    }

    #[test]
    fn airplay_refresh_does_not_cancel_raop_loss_grace() {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let raop = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let airplay = airplay(
            "001122334455",
            "Living Room",
            interface(4, "Ethernet"),
            address,
        );
        let raop_key = raop.key.service.clone();
        let airplay_key = airplay.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(raop_key.clone(), [raop.clone()], 100)
            .unwrap();
        registry
            .replace_service_snapshot(airplay_key.clone(), [airplay.clone()], 100)
            .unwrap();
        registry.remove_service(&raop_key, 200).unwrap();
        registry
            .replace_service_snapshot(airplay_key, [airplay], 300)
            .unwrap();
        assert_eq!(registry.snapshots()[0].state, ReceiverState::GraceOffline);

        let returned = registry
            .replace_service_snapshot(raop_key, [raop], 400)
            .unwrap();
        assert!(matches!(
            returned.as_slice(),
            [RegistryEvent::GraceCancelled { .. }]
        ));
        assert_eq!(
            registry.snapshots()[0].state,
            ReceiverState::OnlineSupported
        );
    }

    #[test]
    fn snapshots_are_sorted_by_identity_and_observation_key() {
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        for id in ["AABBCCDDEEFF", "001122334455"] {
            let observation = raop(
                id,
                id,
                "receiver.local.",
                interface(4, "Ethernet"),
                &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                &supported_properties(),
            );
            registry
                .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
                .unwrap();
        }

        assert_eq!(
            registry
                .snapshots()
                .iter()
                .map(|snapshot| snapshot.identity.as_str())
                .collect::<Vec<_>>(),
            ["001122334455", "AABBCCDDEEFF"]
        );
    }

    #[test]
    fn registry_does_not_retain_removed_records() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::ZERO);
        registry
            .replace_service_snapshot(service.clone(), [observation], 100)
            .unwrap();
        registry.remove_service(&service, 100).unwrap();
        registry.tick(100).unwrap();
        assert!(registry.snapshots().is_empty());
    }

    #[test]
    fn service_restart_reconstruction_has_no_gracing_entries() {
        let observations = [
            raop(
                "001122334455",
                "Living Room",
                "receiver.local.",
                interface(4, "Ethernet"),
                &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                &supported_properties(),
            ),
            airplay(
                "001122334455",
                "Living Room",
                interface(4, "Ethernet"),
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)),
            ),
        ];
        let registry =
            ReceiverRegistry::reconstruct(Duration::from_secs(8), observations, 0).unwrap();
        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.state, ReceiverState::OnlineSupported);
        assert_eq!(snapshot.grace_deadline_ms, None);
    }

    #[test]
    fn missing_backend_addresses_are_rejected() {
        let error = DiscoveryObservation::from_parts(
            ServiceKind::Raop,
            "001122334455@Room._raop._tcp.local.",
            "receiver.local.",
            7_000,
            interface(4, "Ethernet"),
            [],
            properties(&supported_properties()),
            TxtLimits::default(),
        )
        .unwrap_err();
        assert_eq!(error, DiscoveryError::NoUsableAddresses);
    }

    #[test]
    fn grace_deadline_uses_saturating_arithmetic() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_millis(10));
        registry
            .replace_service_snapshot(service.clone(), [observation], u64::MAX)
            .unwrap();
        registry.remove_service(&service, u64::MAX).unwrap();
        assert_eq!(registry.snapshots()[0].grace_deadline_ms, Some(u64::MAX));
    }

    #[test]
    fn observation_key_keeps_interface_scope() {
        let first = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let second = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        assert_ne!(first.key, second.key);
        assert_eq!(first.identity, second.identity);
    }

    #[test]
    fn missing_capabilities_are_not_assumed_supported() {
        let observation = raop(
            "001122334455",
            "Legacy Receiver",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &[],
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
            .unwrap();
        assert_eq!(
            registry.snapshots()[0].capability,
            ReceiverCapability::Unsupported {
                reason: UnsupportedReason::MissingEncryptionAdvertisement,
            }
        );
    }

    #[test]
    fn display_name_control_characters_are_not_propagated() {
        let observation = DiscoveryObservation::from_parts(
            ServiceKind::Raop,
            "001122334455@Living Room._raop._tcp.local.",
            "receiver.local.",
            7_000,
            interface(4, "Ethernet"),
            [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            vec![
                ("fn", Some(b"Living\nRoom".to_vec())),
                ("cn", Some(b"1".to_vec())),
            ],
            TxtLimits::default(),
        );
        assert!(matches!(
            observation,
            Err(DiscoveryError::InvalidTxtControlCharacter(_))
        ));
    }

    #[test]
    fn registry_state_can_drive_endpoint_lifecycle() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let identity = observation.identity.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(observation.key.service.clone(), [observation], 100)
            .unwrap();
        registry
            .transition(
                &identity,
                crate::receiver::ReceiverSignal::BeginEndpointCreation,
            )
            .unwrap();
        registry
            .transition(&identity, crate::receiver::ReceiverSignal::EndpointCreated)
            .unwrap();
        assert_eq!(
            registry.get(&identity).unwrap().state,
            ReceiverState::EndpointReady
        );
    }

    #[test]
    fn unsupported_and_supported_interface_records_are_inconsistent() {
        let supported = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let unsupported = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 11))],
            &[("cn", "2"), ("tp", "UDP"), ("et", "0")],
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(supported.key.service.clone(), [supported, unsupported], 100)
            .unwrap();
        assert_eq!(
            registry.snapshots()[0].capability,
            ReceiverCapability::Unsupported {
                reason: UnsupportedReason::InconsistentAdvertisements,
            }
        );
    }

    #[test]
    fn empty_txt_limits_are_rejected() {
        let error = parse_txt_properties(
            Vec::<(String, Option<Vec<u8>>)>::new(),
            TxtLimits {
                max_records: 0,
                max_total_bytes: 1,
                max_value_bytes: 1,
            },
        )
        .unwrap_err();
        assert_eq!(error, DiscoveryError::InvalidTxtLimits);
    }

    #[test]
    fn fullname_case_changes_do_not_create_duplicate_service() {
        let lower = ServiceKey::new(ServiceKind::Raop, "001122334455@Room._raop._tcp.local.");
        let upper = ServiceKey::new(ServiceKind::Raop, "001122334455@ROOM._RAOP._TCP.LOCAL.");
        let keys = BTreeSet::from([lower, upper]);
        assert_eq!(keys.len(), 1);
    }

    #[test]
    fn bounded_registry_batch_is_permutation_invariant() {
        let a = raop(
            "001122334455",
            "A",
            "a.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &supported_properties(),
        );
        let b = raop(
            "AABBCCDDEEFF",
            "B",
            "b.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 2))],
            &supported_properties(),
        );
        let sequences = [
            vec![a.clone(), b.clone()],
            vec![b.clone(), a.clone()],
            vec![a.clone(), a, b],
        ];
        let snapshots = sequences
            .into_iter()
            .map(|observations| {
                ReceiverRegistry::reconstruct(Duration::from_secs(8), observations, 100)
                    .unwrap()
                    .snapshots()
            })
            .collect::<Vec<_>>();
        assert!(snapshots.windows(2).all(|pair| pair[0] == pair[1]));
    }

    #[test]
    fn service_type_conversion_is_strict() {
        assert_eq!(
            ServiceKind::from_service_type("_RAOP._TCP.LOCAL.").unwrap(),
            ServiceKind::Raop
        );
        assert!(ServiceKind::from_service_type("_http._tcp.local.").is_err());
    }

    #[test]
    fn receiver_identity_stays_canonical_in_snapshot() {
        let observation = raop(
            "aabbccddeeff",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        assert_eq!(
            observation.identity,
            ReceiverIdentity::parse("AA:BB:CC:DD:EE:FF").unwrap()
        );
    }

    #[test]
    fn remove_unknown_service_is_a_noop() {
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        let events = registry
            .remove_service(
                &ServiceKey::new(ServiceKind::Raop, "001122334455@Unknown._raop._tcp.local."),
                100,
            )
            .unwrap();
        assert!(events.is_empty());
    }

    #[test]
    fn browser_config_defaults_are_bounded() {
        let config = DiscoveryConfig::default();
        assert!(config.output_capacity > 0);
        assert!(config.max_events_per_poll > 0);
        assert!(config.offline_grace >= Duration::from_secs(5));
        assert!(config.offline_grace <= Duration::from_secs(10));
        assert_eq!(config.query_interval, DEFAULT_DISCOVERY_QUERY_INTERVAL);
        assert_eq!(config.mdns_port, DEFAULT_MDNS_PORT);
        assert!(QUERY_PULSE_DURATION >= Duration::from_millis(1_500));
        assert!(QUERY_PULSE_DURATION < config.query_interval);
        assert!(!QUERY_PULSE_STOP_ACK_TIMEOUT.is_zero());
        assert!(browser_config_is_valid(&config));
        assert!(config.registry_limits.is_valid());
        assert!(
            config.registry_limits.max_supported_receivers < config.registry_limits.max_receivers
        );
        assert!(config.registry_limits.max_known_services <= 256);
        assert!(config.registry_limits.max_observations <= 512);
    }

    #[test]
    fn browser_rejects_query_intervals_outside_central_bounds() {
        for query_interval in [
            MIN_DISCOVERY_QUERY_INTERVAL
                .checked_sub(Duration::from_millis(1))
                .expect("minimum query interval exceeds one millisecond"),
            MAX_DISCOVERY_QUERY_INTERVAL
                .checked_add(Duration::from_millis(1))
                .expect("maximum query interval can be incremented"),
        ] {
            let config = DiscoveryConfig {
                query_interval,
                ..DiscoveryConfig::default()
            };
            assert!(!browser_config_is_valid(&config));
        }
    }

    #[test]
    fn browser_rejects_zero_mdns_port() {
        let config = DiscoveryConfig {
            mdns_port: 0,
            ..DiscoveryConfig::default()
        };
        assert!(!browser_config_is_valid(&config));
    }

    #[test]
    fn query_pulse_schedule_does_not_emit_catch_up_bursts() {
        let started = Instant::now();
        let mut schedule = QueryPulseSchedule::new(started, Duration::from_secs(4));
        assert!(!schedule.is_due(started + Duration::from_millis(3_999)));
        assert!(schedule.is_due(started + Duration::from_secs(4)));

        let delayed_start = started + Duration::from_secs(10);
        schedule.mark_started(delayed_start);
        assert!(!schedule.is_due(delayed_start + Duration::from_millis(3_999)));
        assert!(schedule.is_due(delayed_start + Duration::from_secs(4)));
    }

    #[test]
    fn query_pulse_resolutions_and_real_removals_are_authoritative() {
        let properties = supported_properties();
        let resolved = ServiceInfo::new(
            RAOP_SERVICE_TYPE,
            "001122334455@Living Room",
            "receiver.local.",
            "192.0.2.10",
            7_000,
            &properties[..],
        )
        .unwrap()
        .as_resolved_service();
        let returned = resolved.clone();
        let fullname = resolved.fullname.clone();
        let (sender, notifications) = mpsc::sync_channel(8);
        let mut publisher = NotificationPublisher::new(
            sender,
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));

        assert!(
            process_service_event(
                ServiceEvent::ServiceResolved(Box::new(resolved)),
                &mut publisher,
                &mut registry,
                100,
                TxtLimits::default(),
                ServiceEventAuthority::QueryPulse,
            )
            .is_some()
        );
        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.state, ReceiverState::OnlineSupported);
        assert_eq!(snapshot.last_seen_ms, 100);
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::Added { .. }
            }
        ));

        assert!(
            process_service_event(
                ServiceEvent::ServiceRemoved(RAOP_SERVICE_TYPE.to_owned(), fullname.clone()),
                &mut publisher,
                &mut registry,
                200,
                TxtLimits::default(),
                ServiceEventAuthority::QueryPulse,
            )
            .is_none()
        );
        let snapshot = registry.snapshots().pop().unwrap();
        assert_eq!(snapshot.state, ReceiverState::GraceOffline);
        assert_eq!(snapshot.last_seen_ms, 100);
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::GraceStarted { .. }
            }
        ));

        assert!(
            process_service_event(
                ServiceEvent::ServiceResolved(Box::new(returned)),
                &mut publisher,
                &mut registry,
                300,
                TxtLimits::default(),
                ServiceEventAuthority::QueryPulse,
            )
            .is_some()
        );
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::GraceCancelled { .. }
            }
        ));

        assert!(
            process_service_event(
                ServiceEvent::ServiceRemoved(RAOP_SERVICE_TYPE.to_owned(), fullname),
                &mut publisher,
                &mut registry,
                400,
                TxtLimits::default(),
                ServiceEventAuthority::Primary,
            )
            .is_none()
        );
        assert_eq!(
            registry.snapshots().pop().unwrap().state,
            ReceiverState::GraceOffline
        );
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::GraceStarted { .. }
            }
        ));
    }

    #[test]
    fn successful_query_epochs_expire_missing_services_independently() {
        let address = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let raop = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[address],
            &supported_properties(),
        );
        let companion = airplay(
            "00:11:22:33:44:55",
            "Living Room",
            interface(4, "Ethernet"),
            address,
        );
        let raop_service = raop.key.service.clone();
        let companion_service = companion.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(raop_service.clone(), [raop], 0)
            .unwrap();
        registry
            .replace_service_snapshot(companion_service.clone(), [companion], 0)
            .unwrap();
        let (sender, notifications) = mpsc::sync_channel(8);
        let mut publisher = NotificationPublisher::new(
            sender,
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
        );
        let mut freshness = QueryPulseFreshness::default();

        freshness.note_resolved([raop_service.clone(), companion_service.clone()], &registry);
        freshness.complete_successful_epoch(&mut registry, &mut publisher, 100);

        for epoch in 1..MAX_MISSED_QUERY_EPOCHS {
            freshness.note_resolved([companion_service.clone()], &registry);
            freshness.complete_successful_epoch(
                &mut registry,
                &mut publisher,
                u64::from(epoch) * 1_000,
            );
            assert!(
                registry.active_service_keys().contains(&raop_service),
                "RAOP must survive transient miss {epoch}"
            );
        }

        freshness.note_resolved([companion_service.clone()], &registry);
        freshness.complete_successful_epoch(&mut registry, &mut publisher, 3_000);
        let active = registry.active_service_keys();
        assert!(!active.contains(&raop_service));
        assert!(active.contains(&companion_service));
        assert_eq!(
            registry.snapshots().pop().unwrap().state,
            ReceiverState::GraceOffline
        );
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::GraceStarted { receiver, .. }
            } if receiver.state == ReceiverState::GraceOffline
        ));
    }

    #[test]
    fn failed_query_epochs_do_not_age_service_freshness() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [observation], 0)
            .unwrap();
        let (sender, _notifications) = mpsc::sync_channel(8);
        let mut publisher = NotificationPublisher::new(
            sender,
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
        );
        let mut freshness = QueryPulseFreshness::default();

        // A failed pulse does not call complete_successful_epoch. Even many
        // failures therefore provide no negative evidence.
        for _ in 0..10 {
            freshness.note_resolved(std::iter::empty(), &registry);
        }
        assert!(freshness.missed_successful_epochs.is_empty());

        for epoch in 1..MAX_MISSED_QUERY_EPOCHS {
            freshness.complete_successful_epoch(
                &mut registry,
                &mut publisher,
                u64::from(epoch) * 1_000,
            );
            assert!(registry.active_service_keys().contains(&service));
        }
    }

    #[test]
    fn pulse_only_service_silent_loss_enters_normal_grace_and_removal() {
        let observation = raop(
            "001122334455",
            "Living Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        let service = observation.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [observation], 0)
            .unwrap();
        let (sender, notifications) = mpsc::sync_channel(8);
        let mut publisher = NotificationPublisher::new(
            sender,
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
        );
        let mut freshness = QueryPulseFreshness::default();
        freshness.note_resolved([service], &registry);
        freshness.complete_successful_epoch(&mut registry, &mut publisher, 100);

        for epoch in 1..=MAX_MISSED_QUERY_EPOCHS {
            freshness.complete_successful_epoch(
                &mut registry,
                &mut publisher,
                u64::from(epoch) * 1_000,
            );
        }
        assert_eq!(
            registry.snapshots().pop().unwrap().state,
            ReceiverState::GraceOffline
        );
        assert!(matches!(
            notifications.try_recv().unwrap(),
            DiscoveryNotification::Registry {
                change: RegistryEvent::GraceStarted {
                    deadline_ms: 11_000,
                    ..
                }
            }
        ));
        assert!(registry.tick(10_999).unwrap().is_empty());
        assert!(matches!(
            registry.tick(11_000).unwrap().as_slice(),
            [
                RegistryEvent::Removing { .. },
                RegistryEvent::Removed { .. }
            ]
        ));
        assert!(registry.is_empty());
    }

    #[test]
    fn invalid_registry_limits_are_rejected() {
        let invalid = RegistryLimits {
            max_supported_receivers: 2,
            max_receivers: 1,
            ..RegistryLimits::default()
        };
        assert_eq!(
            ReceiverRegistry::with_limits(Duration::from_secs(8), invalid).unwrap_err(),
            RegistryError::InvalidLimits
        );
    }

    #[test]
    fn txt_total_limit_uses_checked_accumulation() {
        let error = parse_txt_properties(
            vec![
                ("a", Some(b"12345".to_vec())),
                ("b", Some(b"12345".to_vec())),
            ],
            TxtLimits {
                max_records: 2,
                max_total_bytes: 10,
                max_value_bytes: 10,
            },
        )
        .unwrap_err();
        assert!(matches!(error, DiscoveryError::TxtTotalTooLarge { .. }));
    }

    #[test]
    fn observation_service_key_matches_service_type() {
        let observation = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
            &supported_properties(),
        );
        assert_eq!(
            observation.key.service,
            ServiceKey::new(ServiceKind::Raop, &observation.service_fullname)
        );
    }

    #[test]
    fn ip_address_never_participates_in_identity() {
        let first = raop(
            "001122334455",
            "Room",
            "one.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &supported_properties(),
        );
        let second = raop(
            "001122334455",
            "Room",
            "two.local.",
            interface(8, "Wi-Fi"),
            &[IpAddr::V6(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 2))],
            &supported_properties(),
        );
        assert_eq!(first.identity, second.identity);
    }

    #[test]
    fn registry_outputs_stable_service_order() {
        let observation = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &supported_properties(),
        );
        let companion = airplay(
            "001122334455",
            "Room",
            interface(4, "Ethernet"),
            IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)),
        );
        let registry =
            ReceiverRegistry::reconstruct(Duration::from_secs(8), [observation, companion], 100)
                .unwrap();
        let kinds = registry.snapshots()[0]
            .observations
            .iter()
            .map(|item| item.key.service.kind)
            .collect::<Vec<_>>();
        assert_eq!(kinds, [ServiceKind::Raop, ServiceKind::AirPlay]);
    }

    #[test]
    fn record_count_is_checked_before_insert() {
        let properties = (0..65)
            .map(|index| (format!("k{index}"), Some(Vec::new())))
            .collect::<Vec<_>>();
        assert_eq!(
            parse_txt_properties(properties, TxtLimits::default()).unwrap_err(),
            DiscoveryError::TxtTooManyRecords
        );
    }

    #[test]
    fn zero_port_is_rejected() {
        let error = DiscoveryObservation::from_parts(
            ServiceKind::Raop,
            "001122334455@Room._raop._tcp.local.",
            "receiver.local.",
            0,
            interface(4, "Ethernet"),
            [IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            properties(&supported_properties()),
            TxtLimits::default(),
        )
        .unwrap_err();
        assert_eq!(error, DiscoveryError::InvalidPort);
    }

    #[test]
    fn multicast_and_unspecified_addresses_are_rejected() {
        for address in [
            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            IpAddr::V4(Ipv4Addr::new(224, 0, 0, 1)),
            IpAddr::V6(Ipv6Addr::UNSPECIFIED),
            IpAddr::V6(Ipv6Addr::new(0xff02, 0, 0, 0, 0, 0, 0, 1)),
        ] {
            let error = DiscoveryObservation::from_parts(
                ServiceKind::Raop,
                "001122334455@Room._raop._tcp.local.",
                "receiver.local.",
                7_000,
                interface(4, "Ethernet"),
                [address],
                properties(&supported_properties()),
                TxtLimits::default(),
            )
            .unwrap_err();
            assert_eq!(error, DiscoveryError::NoUsableAddresses);
        }
    }

    #[test]
    fn registry_update_reports_changed_snapshot() {
        let first = raop(
            "001122334455",
            "Room",
            "one.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &supported_properties(),
        );
        let mut second = first.clone();
        second.hostname = "two.local.".to_owned();
        let service = first.key.service.clone();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        registry
            .replace_service_snapshot(service.clone(), [first], 100)
            .unwrap();
        let events = registry
            .replace_service_snapshot(service, [second], 200)
            .unwrap();
        assert!(matches!(events.as_slice(), [RegistryEvent::Updated { .. }]));
    }

    #[test]
    fn registry_rejects_observation_under_wrong_service_key() {
        let observation = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &supported_properties(),
        );
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        let error = registry
            .replace_service_snapshot(
                ServiceKey::new(ServiceKind::Raop, "AABBCCDDEEFF@Other._raop._tcp.local."),
                [observation],
                100,
            )
            .unwrap_err();
        assert_eq!(error, super::RegistryError::MismatchedServiceKey);
    }

    #[test]
    fn password_flag_defaults_false() {
        let observation = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &[("cn", "0"), ("tp", "UDP"), ("et", "0")],
        );
        let registry =
            ReceiverRegistry::reconstruct(Duration::from_secs(8), [observation], 100).unwrap();
        assert!(matches!(
            registry.snapshots()[0].capability,
            ReceiverCapability::SupportedClassicRaop {
                password_required: false,
                ..
            }
        ));
    }

    #[test]
    fn state_transition_errors_leave_registry_unchanged() {
        let observation = raop(
            "001122334455",
            "Room",
            "receiver.local.",
            interface(4, "Ethernet"),
            &[IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))],
            &supported_properties(),
        );
        let identity = observation.identity.clone();
        let mut registry =
            ReceiverRegistry::reconstruct(Duration::from_secs(8), [observation], 100).unwrap();
        let before = registry.get(&identity).unwrap();
        assert!(
            registry
                .transition(&identity, crate::receiver::ReceiverSignal::StreamStarted)
                .is_err()
        );
        assert_eq!(registry.get(&identity).unwrap(), before);
    }

    #[test]
    fn unknown_receiver_transition_is_explicit() {
        let identity = ReceiverIdentity::parse("001122334455").unwrap();
        let mut registry = ReceiverRegistry::new(Duration::from_secs(8));
        assert!(matches!(
            registry.transition(
                &identity,
                crate::receiver::ReceiverSignal::BeginEndpointCreation
            ),
            Err(super::RegistryError::ReceiverNotFound(_))
        ));
    }

    #[test]
    fn txt_keys_are_printable_ascii_only() {
        for key in ["", "line\nbreak", "nonascii\u{e9}"] {
            assert!(matches!(
                parse_txt_properties(vec![(key, Some(b"value".to_vec()))], TxtLimits::default()),
                Err(DiscoveryError::InvalidTxtKey(_))
            ));
        }
    }

    #[test]
    fn flag_txt_property_counts_only_key_bytes() {
        let parsed = parse_txt_properties(
            vec![("flag", None)],
            TxtLimits {
                max_records: 1,
                max_total_bytes: 4,
                max_value_bytes: 1,
            },
        )
        .unwrap();
        assert_eq!(parsed, BTreeMap::from([("flag".to_owned(), None)]));
    }
}
