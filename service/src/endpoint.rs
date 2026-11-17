//! Software-device and Windows audio endpoint lifecycle.

use std::collections::HashMap;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

use thiserror::Error;
use uuid::Uuid;
use winairplay_shared::identity::ReceiverIdentity;
use windows::Win32::Devices::Enumeration::Pnp::{
    HSWDEVICE, SW_DEVICE_CREATE_INFO, SWDeviceCapabilitiesDriverRequired,
    SWDeviceCapabilitiesSilentInstall, SwDeviceClose, SwDeviceCreate,
};
use windows::Win32::Devices::Properties::{
    DEVPKEY_Device_FriendlyName, DEVPROP_STORE_SYSTEM, DEVPROP_TYPE_STRING, DEVPROPCOMPKEY,
    DEVPROPERTY,
};
use windows::Win32::Foundation::DEVPROPKEY;
use windows::core::{GUID, HRESULT, PCWSTR};

const INSTANCE_NAMESPACE: Uuid = Uuid::from_u128(0x1437a67a_53fd_5d59_a642_609b19e85e10);
const RECEIVER_ID_PROPERTY: DEVPROPKEY = DEVPROPKEY {
    fmtid: GUID::from_u128(0x54b65a8e_7cd3_4f7b_953b_59a21c2e5cdd),
    pid: 2,
};
const RECEIVER_DISPLAY_NAME_PROPERTY: DEVPROPKEY = DEVPROPKEY {
    fmtid: GUID::from_u128(0x54b65a8e_7cd3_4f7b_953b_59a21c2e5cdd),
    pid: 3,
};
const MAX_DEVICE_NAME_UTF16: usize = 120;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EndpointSpec {
    pub receiver_id: String,
    pub display_name: String,
    pub instance_token: String,
    pub container_id: Uuid,
}

impl EndpointSpec {
    pub fn new(receiver_id: &str, display_name: &str) -> Result<Self, EndpointError> {
        let identity = ReceiverIdentity::parse(receiver_id.trim())
            .map_err(|_| EndpointError::InvalidReceiverId)?;
        let receiver_id = identity.to_string();

        let instance_uuid = Uuid::new_v5(&INSTANCE_NAMESPACE, receiver_id.as_bytes());
        let container_id = identity.stable_uuid();
        Ok(Self {
            receiver_id: receiver_id.clone(),
            display_name: endpoint_display_name(display_name),
            instance_token: format!("WAPA_{}", instance_uuid.simple()).to_ascii_uppercase(),
            container_id,
        })
    }
}

#[must_use]
pub fn endpoint_display_name(receiver_name: &str) -> String {
    let mut cleaned = String::with_capacity(receiver_name.len().min(MAX_DEVICE_NAME_UTF16));
    let mut previous_space = false;
    let mut utf16_units = 0_usize;
    let base_limit = MAX_DEVICE_NAME_UTF16.saturating_sub(10);
    for character in receiver_name.chars() {
        let unsafe_directional = matches!(
            character,
            '\u{202A}'
                ..='\u{202E}'
                    | '\u{2066}'..='\u{2069}'
                    | '\u{200E}'
                    | '\u{200F}'
                    | '\u{061C}'
        );
        let value = if character.is_control() || unsafe_directional {
            ' '
        } else {
            character
        };
        if value.is_whitespace() {
            if previous_space {
                continue;
            }
            if utf16_units >= base_limit {
                break;
            }
            previous_space = true;
            cleaned.push(' ');
            utf16_units += 1;
        } else {
            let character_units = value.len_utf16();
            if utf16_units.saturating_add(character_units) > base_limit {
                break;
            }
            previous_space = false;
            cleaned.push(value);
            utf16_units += character_units;
        }
    }

    let base = cleaned.trim();
    if base.is_empty() {
        "AirPlay Receiver (AirPlay)".to_owned()
    } else {
        format!("{base} (AirPlay)")
    }
}

#[derive(Debug, Error, Clone, Eq, PartialEq)]
pub enum EndpointError {
    #[error("receiver identity must be a canonical six-byte hexadecimal ID")]
    InvalidReceiverId,
    #[error("endpoint backend failed while {operation} receiver {receiver_id}: {detail}")]
    Backend {
        operation: &'static str,
        receiver_id: String,
        detail: String,
    },
    #[error(
        "software-device creation for receiver {receiver_id} did not complete within {timeout:?}"
    )]
    CreateTimedOut {
        receiver_id: String,
        timeout: Duration,
    },
    #[error(
        "software-device creation failed for receiver {receiver_id} with HRESULT {result:#010x}"
    )]
    CreateRejected { receiver_id: String, result: i32 },
}

pub trait EndpointBackend {
    type Handle;

    fn create(&mut self, spec: &EndpointSpec) -> Result<Self::Handle, EndpointError>;
    fn close(&mut self, receiver_id: &str, handle: Self::Handle) -> Result<(), EndpointError>;
}

pub struct EndpointManager<B: EndpointBackend> {
    backend: B,
    active: HashMap<String, ActiveEndpoint<B::Handle>>,
}

struct ActiveEndpoint<H> {
    spec: EndpointSpec,
    handle: H,
}

impl<B: EndpointBackend> EndpointManager<B> {
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            active: HashMap::new(),
        }
    }

    pub fn active_receiver_ids(&self) -> impl Iterator<Item = &str> {
        self.active.keys().map(String::as_str)
    }

    pub fn ensure(&mut self, spec: &EndpointSpec) -> Result<bool, EndpointError> {
        if let Some(active) = self.active.get(&spec.receiver_id) {
            if &active.spec == spec {
                return Ok(false);
            }
            // SwDevice creation properties are creation-time inputs. Recreate
            // the same stable instance/container to propagate a live rename.
            self.remove(&spec.receiver_id)?;
        }
        let handle = self.backend.create(spec)?;
        self.active.insert(
            spec.receiver_id.clone(),
            ActiveEndpoint {
                spec: spec.clone(),
                handle,
            },
        );
        Ok(true)
    }

    pub fn remove(&mut self, receiver_id: &str) -> Result<bool, EndpointError> {
        let Some(active) = self.active.remove(receiver_id) else {
            return Ok(false);
        };
        self.backend.close(receiver_id, active.handle)?;
        Ok(true)
    }

    pub fn shutdown(&mut self) -> Vec<EndpointError> {
        let handles = self.active.drain().collect::<Vec<_>>();
        let mut failures = Vec::new();
        for (receiver_id, active) in handles {
            if let Err(error) = self.backend.close(&receiver_id, active.handle) {
                failures.push(error);
            }
        }
        failures
    }

    #[cfg(test)]
    pub fn backend(&self) -> &B {
        &self.backend
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SoftwareDeviceCompletion {
    pub result: i32,
    pub device_instance_id: String,
}

#[derive(Default)]
struct CallbackState {
    completion: Mutex<Option<SoftwareDeviceCompletion>>,
    ready: Condvar,
}

unsafe extern "system" fn software_device_created(
    _device: HSWDEVICE,
    create_result: HRESULT,
    context: *const core::ffi::c_void,
    device_instance_id: PCWSTR,
) {
    if context.is_null() {
        return;
    }
    // SAFETY: `PendingSoftwareDevice` owns the boxed callback state for at least as
    // long as the HSWDEVICE. SwDeviceClose is called before that state is dropped.
    let state = unsafe { &*context.cast::<CallbackState>() };
    let instance_id = if device_instance_id.is_null() {
        String::new()
    } else {
        // SAFETY: Windows owns this NUL-terminated string for the callback duration.
        unsafe { device_instance_id.to_string() }.unwrap_or_else(|_| "<invalid UTF-16>".to_owned())
    };
    let mut completion = state
        .completion
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if completion.is_none() {
        *completion = Some(SoftwareDeviceCompletion {
            result: create_result.0,
            device_instance_id: instance_id,
        });
        state.ready.notify_all();
    }
}

pub struct PendingSoftwareDevice {
    handle: HSWDEVICE,
    callback: Box<CallbackState>,
    receiver_id: String,
}

impl PendingSoftwareDevice {
    pub fn wait_ready(&self, timeout: Duration) -> Result<SoftwareDeviceCompletion, EndpointError> {
        let completion = self
            .callback
            .completion
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (completion, wait_result) = self
            .callback
            .ready
            .wait_timeout_while(completion, timeout, |result| result.is_none())
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if wait_result.timed_out() && completion.is_none() {
            return Err(EndpointError::CreateTimedOut {
                receiver_id: self.receiver_id.clone(),
                timeout,
            });
        }
        let result = completion
            .clone()
            .expect("completion is present after non-timeout wait");
        if result.result < 0 {
            return Err(EndpointError::CreateRejected {
                receiver_id: self.receiver_id.clone(),
                result: result.result,
            });
        }
        Ok(result)
    }
}

impl Drop for PendingSoftwareDevice {
    fn drop(&mut self) {
        // SAFETY: the handle came from SwDeviceCreate and is closed exactly once.
        unsafe { SwDeviceClose(self.handle) };
    }
}

pub fn create_software_device(
    specification: &EndpointSpec,
) -> Result<PendingSoftwareDevice, EndpointError> {
    let instance_id = wide_null(&specification.instance_token);
    let hardware_ids = wide_multi_string(&["ROOT\\WinAirPlayAudio"]);
    let compatible_ids = [0_u16, 0];
    let display_name = wide_null(&specification.display_name);
    let receiver_id = wide_null(&specification.receiver_id);
    let enumerator = wide_null("WinAirPlayAudio");
    let parent = wide_null("HTREE\\ROOT\\0");
    let container_id = GUID::from_u128(specification.container_id.as_u128());

    let receiver_property = DEVPROPERTY {
        CompKey: DEVPROPCOMPKEY {
            Key: RECEIVER_ID_PROPERTY,
            Store: DEVPROP_STORE_SYSTEM,
            LocaleName: PCWSTR::null(),
        },
        Type: DEVPROP_TYPE_STRING,
        BufferSize: u32::try_from(receiver_id.len() * size_of::<u16>()).map_err(|error| {
            EndpointError::Backend {
                operation: "encoding receiver property",
                receiver_id: specification.receiver_id.clone(),
                detail: error.to_string(),
            }
        })?,
        Buffer: receiver_id.as_ptr().cast_mut().cast(),
    };
    let display_property = DEVPROPERTY {
        CompKey: DEVPROPCOMPKEY {
            Key: RECEIVER_DISPLAY_NAME_PROPERTY,
            Store: DEVPROP_STORE_SYSTEM,
            LocaleName: PCWSTR::null(),
        },
        Type: DEVPROP_TYPE_STRING,
        BufferSize: u32::try_from(display_name.len() * size_of::<u16>()).map_err(|error| {
            EndpointError::Backend {
                operation: "encoding receiver display-name property",
                receiver_id: specification.receiver_id.clone(),
                detail: error.to_string(),
            }
        })?,
        Buffer: display_name.as_ptr().cast_mut().cast(),
    };
    // AudioEndpointBuilder composes the endpoint display name from its form
    // factor and the parent device instance's friendly name. The INF
    // DeviceDesc is package-wide, so seed the standard per-instance property
    // alongside the private metadata supplied during SwDeviceCreate.
    let friendly_name_property = DEVPROPERTY {
        CompKey: DEVPROPCOMPKEY {
            Key: DEVPKEY_Device_FriendlyName,
            Store: DEVPROP_STORE_SYSTEM,
            LocaleName: PCWSTR::null(),
        },
        Type: DEVPROP_TYPE_STRING,
        BufferSize: u32::try_from(display_name.len() * size_of::<u16>()).map_err(|error| {
            EndpointError::Backend {
                operation: "encoding device friendly-name property",
                receiver_id: specification.receiver_id.clone(),
                detail: error.to_string(),
            }
        })?,
        Buffer: display_name.as_ptr().cast_mut().cast(),
    };
    let properties = [receiver_property, display_property, friendly_name_property];

    let create_info = SW_DEVICE_CREATE_INFO {
        cbSize: u32::try_from(size_of::<SW_DEVICE_CREATE_INFO>()).expect("structure size fits u32"),
        pszInstanceId: PCWSTR(instance_id.as_ptr()),
        pszzHardwareIds: PCWSTR(hardware_ids.as_ptr()),
        pszzCompatibleIds: PCWSTR(compatible_ids.as_ptr()),
        pContainerId: &raw const container_id,
        CapabilityFlags: u32::try_from(
            SWDeviceCapabilitiesDriverRequired.0 | SWDeviceCapabilitiesSilentInstall.0,
        )
        .expect("capability flags are non-negative"),
        pszDeviceDescription: PCWSTR(display_name.as_ptr()),
        pszDeviceLocation: PCWSTR::null(),
        pSecurityDescriptor: std::ptr::null(),
    };

    let callback = Box::<CallbackState>::default();
    let callback_pointer = (&raw const *callback).cast();
    // SAFETY: all pointers remain valid for the call, the multi-strings are
    // double-NUL terminated, and callback state lives through the returned handle.
    let handle = unsafe {
        SwDeviceCreate(
            PCWSTR(enumerator.as_ptr()),
            PCWSTR(parent.as_ptr()),
            &raw const create_info,
            Some(&properties),
            Some(software_device_created),
            Some(callback_pointer),
        )
    }
    .map_err(|error| EndpointError::Backend {
        operation: "initiating SwDeviceCreate",
        receiver_id: specification.receiver_id.clone(),
        detail: error.to_string(),
    })?;

    Ok(PendingSoftwareDevice {
        handle,
        callback,
        receiver_id: specification.receiver_id.clone(),
    })
}

#[derive(Clone, Copy, Debug)]
pub struct WindowsEndpointBackend {
    create_timeout: Duration,
}

impl WindowsEndpointBackend {
    #[must_use]
    pub const fn new(create_timeout: Duration) -> Self {
        Self { create_timeout }
    }
}

impl Default for WindowsEndpointBackend {
    fn default() -> Self {
        Self::new(Duration::from_secs(15))
    }
}

impl EndpointBackend for WindowsEndpointBackend {
    type Handle = PendingSoftwareDevice;

    fn create(&mut self, spec: &EndpointSpec) -> Result<Self::Handle, EndpointError> {
        let device = create_software_device(spec)?;
        device.wait_ready(self.create_timeout)?;
        Ok(device)
    }

    fn close(&mut self, _receiver_id: &str, handle: Self::Handle) -> Result<(), EndpointError> {
        drop(handle);
        Ok(())
    }
}

fn wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn wide_multi_string(values: &[&str]) -> Vec<u16> {
    let mut encoded = Vec::new();
    for value in values {
        encoded.extend(value.encode_utf16());
        encoded.push(0);
    }
    encoded.push(0);
    encoded
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[derive(Default)]
    struct FakeBackend {
        created: Vec<String>,
        created_names: Vec<String>,
        closed: Vec<String>,
        fail_create: Option<String>,
    }

    impl EndpointBackend for FakeBackend {
        type Handle = String;

        fn create(&mut self, spec: &EndpointSpec) -> Result<Self::Handle, EndpointError> {
            if self.fail_create.as_deref() == Some(&spec.receiver_id) {
                return Err(EndpointError::Backend {
                    operation: "creating fake endpoint",
                    receiver_id: spec.receiver_id.clone(),
                    detail: "injected failure".to_owned(),
                });
            }
            self.created.push(spec.receiver_id.clone());
            self.created_names.push(spec.display_name.clone());
            Ok(spec.receiver_id.clone())
        }

        fn close(&mut self, receiver_id: &str, _handle: Self::Handle) -> Result<(), EndpointError> {
            self.closed.push(receiver_id.to_owned());
            Ok(())
        }
    }

    fn spec(receiver_id: &str) -> EndpointSpec {
        EndpointSpec::new(receiver_id, "Living Room").expect("valid endpoint specification")
    }

    #[test]
    fn stable_tokens_do_not_depend_on_display_name_or_address() {
        let first = EndpointSpec::new("001122AABBCC", "Living Room").unwrap();
        let renamed = EndpointSpec::new("001122AABBCC", "Renamed").unwrap();
        assert_eq!(first.instance_token, renamed.instance_token);
        assert_eq!(first.container_id, renamed.container_id);
        assert_eq!(
            first.container_id,
            ReceiverIdentity::parse("001122AABBCC")
                .unwrap()
                .stable_uuid()
        );
        assert_ne!(
            first.container_id,
            EndpointSpec::new("FFEEDDCCBBAA", "Living Room")
                .unwrap()
                .container_id
        );
    }

    #[test]
    fn network_name_is_sanitized_and_bounded() {
        let hostile = format!("Living\u{202E}\r\nRoom {}", "x".repeat(300));
        let name = endpoint_display_name(&hostile);
        assert!(!name.contains('\u{202E}'));
        assert!(!name.contains('\r'));
        assert!(!name.contains('\n'));
        assert!(name.encode_utf16().count() <= MAX_DEVICE_NAME_UTF16);
        assert!(name.ends_with(" (AirPlay)"));
    }

    #[test]
    fn network_name_never_splits_or_overruns_a_supplementary_character() {
        let boundary = format!("{}😀tail", "x".repeat(109));
        let name = endpoint_display_name(&boundary);

        assert_eq!(name.encode_utf16().count(), 119);
        assert_eq!(name, format!("{} (AirPlay)", "x".repeat(109)));
    }

    #[test]
    fn duplicate_ensure_does_not_duplicate_endpoint() {
        let mut manager = EndpointManager::new(FakeBackend::default());
        assert!(manager.ensure(&spec("001122334455")).unwrap());
        assert!(!manager.ensure(&spec("001122334455")).unwrap());
        assert_eq!(manager.backend().created, ["001122334455"]);
    }

    #[test]
    fn rename_recreates_the_same_stable_endpoint_with_the_new_name() {
        let mut manager = EndpointManager::new(FakeBackend::default());
        let first = EndpointSpec::new("001122334455", "Living Room").unwrap();
        let renamed = EndpointSpec::new("001122334455", "Family Room").unwrap();
        assert!(manager.ensure(&first).unwrap());
        assert!(manager.ensure(&renamed).unwrap());
        assert_eq!(manager.backend().created, ["001122334455", "001122334455"]);
        assert_eq!(manager.backend().closed, ["001122334455"]);
        assert_eq!(
            manager.backend().created_names,
            ["Living Room (AirPlay)", "Family Room (AirPlay)"]
        );
    }

    #[test]
    fn removing_one_receiver_preserves_other_endpoints() {
        let mut manager = EndpointManager::new(FakeBackend::default());
        manager.ensure(&spec("001122334455")).unwrap();
        manager.ensure(&spec("001122334456")).unwrap();
        assert!(manager.remove("001122334455").unwrap());
        manager.ensure(&spec("001122334457")).unwrap();
        let active: HashSet<&str> = manager.active_receiver_ids().collect();
        assert_eq!(active, HashSet::from(["001122334456", "001122334457"]));
        assert_eq!(manager.backend().closed, ["001122334455"]);
    }

    #[test]
    fn creation_failure_does_not_leave_stale_entry() {
        let backend = FakeBackend {
            fail_create: Some("001122334455".to_owned()),
            ..FakeBackend::default()
        };
        let mut manager = EndpointManager::new(backend);
        assert!(manager.ensure(&spec("001122334455")).is_err());
        assert_eq!(manager.active_receiver_ids().count(), 0);
    }

    #[test]
    fn shutdown_closes_every_endpoint() {
        let mut manager = EndpointManager::new(FakeBackend::default());
        manager.ensure(&spec("001122334455")).unwrap();
        manager.ensure(&spec("001122334456")).unwrap();
        assert!(manager.shutdown().is_empty());
        assert_eq!(manager.active_receiver_ids().count(), 0);
        assert_eq!(manager.backend().closed.len(), 2);
    }

    #[test]
    fn multi_string_is_double_nul_terminated() {
        let encoded = wide_multi_string(&["ROOT\\WinAirPlayAudio"]);
        assert_eq!(&encoded[encoded.len() - 2..], &[0, 0]);
    }
}
