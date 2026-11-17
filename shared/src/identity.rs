//! Stable receiver identity derivation.
//!
//! Receiver identity must not depend on a hostname or IP address: both can
//! change while Windows is retaining the same software-device instance.  RAOP
//! instances conventionally start with a 48-bit device identifier, while the
//! companion `AirPlay` service exposes the same identifier in its `deviceid`
//! TXT property.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

const RAOP_SUFFIX: &str = "._raop._tcp.local.";
const AIRPLAY_SUFFIX: &str = "._airplay._tcp.local.";

/// Canonical, address-independent identity of one physical receiver.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(transparent)]
pub struct ReceiverIdentity(String);

impl ReceiverIdentity {
    /// Parses a six-byte hexadecimal receiver identifier.
    pub fn parse(value: &str) -> Result<Self, IdentityError> {
        canonical_device_id(value).map(Self)
    }

    /// Returns the canonical twelve-character uppercase hexadecimal identifier.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Returns the deterministic UUID used for Windows container/device metadata.
    #[must_use]
    pub fn stable_uuid(&self) -> Uuid {
        let scoped_name = format!("WinAirPlayAudio/receiver/{}", self.0);
        Uuid::new_v5(&Uuid::NAMESPACE_URL, scoped_name.as_bytes())
    }
}

impl fmt::Display for ReceiverIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// Identity derivation failures are rejected instead of falling back to an IP.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum IdentityError {
    /// No stable identifier was present in either the service instance or TXT.
    #[error("service has no stable RAOP device identifier")]
    MissingStableIdentifier,

    /// A candidate identifier was present but was not a six-byte hexadecimal ID.
    #[error("invalid RAOP device identifier: {0}")]
    InvalidStableIdentifier(String),

    /// The service instance and TXT data claimed different physical devices.
    #[error("RAOP instance identifier {instance} conflicts with TXT deviceid {txt}")]
    InconsistentStableIdentifier { instance: String, txt: String },

    /// The full service name was not of the expected DNS-SD type.
    #[error("service fullname does not match {expected}: {fullname}")]
    WrongServiceType {
        expected: &'static str,
        fullname: String,
    },
}

/// Extracts the stable identity from a resolved RAOP service.
///
/// If `deviceid` is also advertised, it must agree with the identifier before
/// `@` in the RAOP instance name.
pub fn identity_from_raop(
    fullname: &str,
    txt: &BTreeMap<String, Option<String>>,
) -> Result<ReceiverIdentity, IdentityError> {
    let instance = service_instance(fullname, RAOP_SUFFIX)?;
    let instance_id = instance
        .split_once('@')
        .map(|(id, _)| id)
        .filter(|id| !id.is_empty())
        .ok_or(IdentityError::MissingStableIdentifier)?;
    let instance_id = ReceiverIdentity::parse(instance_id)?;

    if let Some(txt_id) = txt_device_id(txt)?
        && txt_id != instance_id
    {
        return Err(IdentityError::InconsistentStableIdentifier {
            instance: instance_id.to_string(),
            txt: txt_id.to_string(),
        });
    }

    Ok(instance_id)
}

/// Extracts the stable identity from the companion `_airplay._tcp` TXT data.
pub fn identity_from_airplay(
    fullname: &str,
    txt: &BTreeMap<String, Option<String>>,
) -> Result<ReceiverIdentity, IdentityError> {
    let _ = service_instance(fullname, AIRPLAY_SUFFIX)?;
    txt_device_id(txt)?.ok_or(IdentityError::MissingStableIdentifier)
}

/// Returns the unescaped DNS-SD instance label for a supported service type.
pub fn service_instance<'a>(
    fullname: &'a str,
    expected_suffix: &'static str,
) -> Result<&'a str, IdentityError> {
    let leading_dot = usize::from(!expected_suffix.starts_with('.'));
    let suffix_length = expected_suffix.len().saturating_add(leading_dot);
    if fullname.len() <= suffix_length {
        return Err(IdentityError::WrongServiceType {
            expected: expected_suffix,
            fullname: fullname.to_owned(),
        });
    }

    let suffix_start = fullname.len() - suffix_length;
    let (instance, suffix) = fullname.split_at(suffix_start);
    let suffix_matches = if leading_dot == 0 {
        suffix.eq_ignore_ascii_case(expected_suffix)
    } else {
        suffix
            .strip_prefix('.')
            .is_some_and(|value| value.eq_ignore_ascii_case(expected_suffix))
    };
    if !suffix_matches || instance.is_empty() {
        return Err(IdentityError::WrongServiceType {
            expected: expected_suffix,
            fullname: fullname.to_owned(),
        });
    }
    Ok(instance)
}

fn txt_device_id(
    txt: &BTreeMap<String, Option<String>>,
) -> Result<Option<ReceiverIdentity>, IdentityError> {
    let Some(value) = txt
        .get("deviceid")
        .or_else(|| txt.get("device-id"))
        .and_then(Option::as_deref)
    else {
        return Ok(None);
    };

    ReceiverIdentity::parse(value).map(Some)
}

fn canonical_device_id(value: &str) -> Result<String, IdentityError> {
    let mut canonical = String::with_capacity(12);
    for character in value.chars() {
        if character == ':' || character == '-' {
            continue;
        }
        if !character.is_ascii_hexdigit() {
            return Err(IdentityError::InvalidStableIdentifier(value.to_owned()));
        }
        canonical.push(character.to_ascii_uppercase());
    }

    if canonical.len() != 12 {
        return Err(IdentityError::InvalidStableIdentifier(value.to_owned()));
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::{
        IdentityError, ReceiverIdentity, identity_from_airplay, identity_from_raop,
        service_instance,
    };
    use std::collections::BTreeMap;

    fn txt(entries: &[(&str, &str)]) -> BTreeMap<String, Option<String>> {
        entries
            .iter()
            .map(|(key, value)| ((*key).to_owned(), Some((*value).to_owned())))
            .collect()
    }

    #[test]
    fn canonical_identity_ignores_common_separators_and_case() {
        let identity = ReceiverIdentity::parse("aa:bb-CC:dd-ee:ff").unwrap();
        assert_eq!(identity.as_str(), "AABBCCDDEEFF");
    }

    #[test]
    fn uuid_is_stable_and_scoped() {
        let first = ReceiverIdentity::parse("001122334455").unwrap();
        let equivalent = ReceiverIdentity::parse("00:11:22:33:44:55").unwrap();
        let other = ReceiverIdentity::parse("001122334456").unwrap();

        assert_eq!(first.stable_uuid(), equivalent.stable_uuid());
        assert_ne!(first.stable_uuid(), other.stable_uuid());
    }

    #[test]
    fn raop_identity_is_independent_of_network_location() {
        let first = identity_from_raop(
            "001122334455@Living Room._raop._tcp.local.",
            &BTreeMap::new(),
        )
        .unwrap();
        let renamed = identity_from_raop(
            "001122334455@Renamed Receiver._RAOP._TCP.LOCAL.",
            &BTreeMap::new(),
        )
        .unwrap();

        assert_eq!(first, renamed);
    }

    #[test]
    fn matching_txt_identity_is_accepted() {
        let identity = identity_from_raop(
            "001122334455@Living Room._raop._tcp.local.",
            &txt(&[("deviceid", "00:11:22:33:44:55")]),
        )
        .unwrap();
        assert_eq!(identity.as_str(), "001122334455");
    }

    #[test]
    fn conflicting_instance_and_txt_identity_is_rejected() {
        let error = identity_from_raop(
            "001122334455@Living Room._raop._tcp.local.",
            &txt(&[("deviceid", "AABBCCDDEEFF")]),
        )
        .unwrap_err();
        assert!(matches!(
            error,
            IdentityError::InconsistentStableIdentifier { .. }
        ));
    }

    #[test]
    fn airplay_requires_deviceid_txt() {
        let error = identity_from_airplay("Living Room._airplay._tcp.local.", &BTreeMap::new())
            .unwrap_err();
        assert_eq!(error, IdentityError::MissingStableIdentifier);
    }

    #[test]
    fn airplay_deviceid_is_canonicalized() {
        let identity = identity_from_airplay(
            "Living Room._airplay._tcp.local.",
            &txt(&[("deviceid", "aa:bb:cc:dd:ee:ff")]),
        )
        .unwrap();
        assert_eq!(identity.as_str(), "AABBCCDDEEFF");
    }

    #[test]
    fn malformed_identity_is_rejected() {
        let error = ReceiverIdentity::parse("not-a-device").unwrap_err();
        assert!(matches!(error, IdentityError::InvalidStableIdentifier(_)));
    }

    #[test]
    fn service_type_must_match_exact_suffix() {
        let error = service_instance("Name._http._tcp.local.", "._raop._tcp.local.").unwrap_err();
        assert!(matches!(error, IdentityError::WrongServiceType { .. }));
    }

    #[test]
    fn service_instance_accepts_type_with_or_without_separator() {
        let fullname = "Room._raop._tcp.local.";
        assert_eq!(
            service_instance(fullname, "._raop._tcp.local.").unwrap(),
            "Room"
        );
        assert_eq!(
            service_instance(fullname, "_raop._tcp.local.").unwrap(),
            "Room"
        );
    }
}
