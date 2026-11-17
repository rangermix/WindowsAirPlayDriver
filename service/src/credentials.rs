//! Receiver-specific Windows DPAPI credential storage.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{Ordering, compiler_fence};

use thiserror::Error;
use winairplay_shared::identity::ReceiverIdentity;
use windows::Win32::Foundation::{HLOCAL, LocalFree};
use windows::Win32::Security::Cryptography::{
    CRYPT_INTEGER_BLOB, CRYPTPROTECT_LOCAL_MACHINE, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData,
    CryptUnprotectData,
};
use windows::Win32::Storage::FileSystem::{REPLACEFILE_WRITE_THROUGH, ReplaceFileW};
use windows::core::PCWSTR;
use zeroize::Zeroizing;

const MAX_PASSWORD_BYTES: usize = 1_024;
const MAX_PROTECTED_BYTES: u64 = 64 * 1024;

#[derive(Clone, Debug)]
pub struct CredentialStore {
    directory: PathBuf,
}

impl CredentialStore {
    pub fn default_store() -> Result<Self, CredentialError> {
        let program_data =
            std::env::var_os("ProgramData").ok_or(CredentialError::ProgramDataUnavailable)?;
        Ok(Self {
            directory: PathBuf::from(program_data)
                .join("WinAirPlayAudio")
                .join("credentials"),
        })
    }

    #[cfg(test)]
    #[must_use]
    pub fn at(directory: PathBuf) -> Self {
        Self { directory }
    }

    pub fn read(&self, receiver_id: &str) -> Result<Option<String>, CredentialError> {
        let receiver = canonical_identity(receiver_id)?;
        let path = self.path_for(&receiver);
        let metadata = match fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(source) => {
                return Err(CredentialError::Read {
                    path: path.clone(),
                    source,
                });
            }
        };
        if metadata.len() > MAX_PROTECTED_BYTES {
            return Err(CredentialError::ProtectedValueTooLarge {
                path,
                actual: metadata.len(),
                maximum: MAX_PROTECTED_BYTES,
            });
        }
        let protected = fs::read(&path).map_err(|source| CredentialError::Read {
            path: path.clone(),
            source,
        })?;
        let entropy = entropy_for(&receiver);
        let plaintext = Zeroizing::new(unprotect(&protected, &entropy)?);
        let password = std::str::from_utf8(&plaintext)
            .map(str::to_owned)
            .map_err(|_| CredentialError::InvalidPlaintext(receiver.to_string()))?;
        validate_password(&password)?;
        Ok(Some(password))
    }

    pub fn write(&self, receiver_id: &str, password: &str) -> Result<(), CredentialError> {
        let receiver = canonical_identity(receiver_id)?;
        validate_password(password)?;
        if !self.directory.is_dir() {
            return Err(CredentialError::DirectoryUnavailable(
                self.directory.clone(),
            ));
        }
        let entropy = entropy_for(&receiver);
        let protected = protect(password.as_bytes(), &entropy)?;
        if u64::try_from(protected.len()).unwrap_or(u64::MAX) > MAX_PROTECTED_BYTES {
            return Err(CredentialError::ProtectedValueTooLarge {
                path: self.path_for(&receiver),
                actual: u64::try_from(protected.len()).unwrap_or(u64::MAX),
                maximum: MAX_PROTECTED_BYTES,
            });
        }

        let path = self.path_for(&receiver);
        let temporary = self
            .directory
            .join(format!(".{receiver}.tmp-{}", std::process::id()));
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|source| CredentialError::Write {
                path: temporary.clone(),
                source,
            })?;
        let result = (|| {
            output.write_all(&protected)?;
            output.sync_all()?;
            drop(output);
            replace_file(&path, &temporary)
        })();
        if let Err(source) = result {
            let _ = fs::remove_file(&temporary);
            return Err(CredentialError::Write { path, source });
        }
        Ok(())
    }

    pub fn remove(&self, receiver_id: &str) -> Result<bool, CredentialError> {
        let receiver = canonical_identity(receiver_id)?;
        let path = self.path_for(&receiver);
        match fs::remove_file(&path) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(source) => Err(CredentialError::Write { path, source }),
        }
    }

    fn path_for(&self, receiver: &ReceiverIdentity) -> PathBuf {
        self.directory.join(format!("{receiver}.dpapi"))
    }
}

fn canonical_identity(value: &str) -> Result<ReceiverIdentity, CredentialError> {
    ReceiverIdentity::parse(value)
        .map_err(|_| CredentialError::InvalidReceiverIdentity(value.to_owned()))
}

fn validate_password(password: &str) -> Result<(), CredentialError> {
    if password.is_empty() || password.len() > MAX_PASSWORD_BYTES || password.contains('\0') {
        return Err(CredentialError::InvalidPassword);
    }
    Ok(())
}

fn entropy_for(receiver: &ReceiverIdentity) -> Vec<u8> {
    format!("WinAirPlayAudio/RAOP/{receiver}").into_bytes()
}

fn blob(bytes: &[u8]) -> Result<CRYPT_INTEGER_BLOB, CredentialError> {
    Ok(CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(bytes.len()).map_err(|_| CredentialError::InvalidPassword)?,
        pbData: bytes.as_ptr().cast_mut(),
    })
}

fn protect(plaintext: &[u8], entropy: &[u8]) -> Result<Vec<u8>, CredentialError> {
    let input = blob(plaintext)?;
    let entropy = blob(entropy)?;
    let mut output = CRYPT_INTEGER_BLOB::default();
    // SAFETY: input and entropy point to live slices, output is initialized by
    // DPAPI, UI is forbidden, and the returned LocalAlloc buffer is copied/freed.
    unsafe {
        CryptProtectData(
            &raw const input,
            PCWSTR::null(),
            Some(&raw const entropy),
            None,
            None,
            CRYPTPROTECT_LOCAL_MACHINE | CRYPTPROTECT_UI_FORBIDDEN,
            &raw mut output,
        )
    }
    .map_err(|source| CredentialError::Dpapi {
        operation: "CryptProtectData",
        source,
    })?;
    take_local_blob(output)
}

fn unprotect(protected: &[u8], entropy: &[u8]) -> Result<Vec<u8>, CredentialError> {
    let input = blob(protected)?;
    let entropy = blob(entropy)?;
    let mut output = CRYPT_INTEGER_BLOB::default();
    // SAFETY: input and entropy point to live slices, no UI is allowed, and
    // the returned LocalAlloc buffer is copied/freed below.
    unsafe {
        CryptUnprotectData(
            &raw const input,
            None,
            Some(&raw const entropy),
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &raw mut output,
        )
    }
    .map_err(|source| CredentialError::Dpapi {
        operation: "CryptUnprotectData",
        source,
    })?;
    take_local_blob(output)
}

fn take_local_blob(output: CRYPT_INTEGER_BLOB) -> Result<Vec<u8>, CredentialError> {
    let length = usize::try_from(output.cbData).unwrap_or(usize::MAX);
    if output.pbData.is_null()
        || length == 0
        || length > usize::try_from(MAX_PROTECTED_BYTES).unwrap_or(usize::MAX)
    {
        if !output.pbData.is_null() {
            if length > 0 && length <= usize::try_from(MAX_PROTECTED_BYTES).unwrap_or(usize::MAX) {
                secure_zero(output.pbData, length);
            }
            // SAFETY: DPAPI returned this pointer from LocalAlloc.
            let _ = unsafe { LocalFree(Some(HLOCAL(output.pbData.cast()))) };
        }
        return Err(CredentialError::InvalidDpapiOutput);
    }
    // SAFETY: DPAPI reports a readable allocation of cbData bytes.
    let value = unsafe { std::slice::from_raw_parts(output.pbData, length) }.to_vec();
    secure_zero(output.pbData, length);
    // SAFETY: DPAPI documents LocalFree for the returned allocation.
    let _ = unsafe { LocalFree(Some(HLOCAL(output.pbData.cast()))) };
    Ok(value)
}

fn secure_zero(pointer: *mut u8, length: usize) {
    // SAFETY: callers pass a live DPAPI allocation spanning `length` bytes.
    unsafe {
        for offset in 0..length {
            std::ptr::write_volatile(pointer.add(offset), 0);
        }
    }
    compiler_fence(Ordering::SeqCst);
}

fn replace_file(destination: &Path, replacement: &Path) -> std::io::Result<()> {
    if !destination.exists() {
        return fs::rename(replacement, destination);
    }
    let destination_wide = wide_null(destination);
    let replacement_wide = wide_null(replacement);
    // SAFETY: both path buffers are NUL-terminated and live for the call.
    unsafe {
        ReplaceFileW(
            PCWSTR(destination_wide.as_ptr()),
            PCWSTR(replacement_wide.as_ptr()),
            PCWSTR::null(),
            REPLACEFILE_WRITE_THROUGH,
            None,
            None,
        )
    }
    .map_err(std::io::Error::other)
}

fn wide_null(path: &Path) -> Vec<u16> {
    path.as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[derive(Debug, Error)]
pub enum CredentialError {
    #[error("ProgramData is unavailable for receiver credentials")]
    ProgramDataUnavailable,
    #[error("receiver identity is not a canonical six-byte ID: {0}")]
    InvalidReceiverIdentity(String),
    #[error("password must be non-empty, NUL-free, and at most {MAX_PASSWORD_BYTES} UTF-8 bytes")]
    InvalidPassword,
    #[error("protected credential directory is unavailable: {0}")]
    DirectoryUnavailable(PathBuf),
    #[error("cannot read protected credential {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("cannot write protected credential {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("protected credential {path} is {actual} bytes; maximum is {maximum}")]
    ProtectedValueTooLarge {
        path: PathBuf,
        actual: u64,
        maximum: u64,
    },
    #[error("DPAPI {operation} failed: {source}")]
    Dpapi {
        operation: &'static str,
        #[source]
        source: windows::core::Error,
    },
    #[error("DPAPI returned an empty or oversized allocation")]
    InvalidDpapiOutput,
    #[error("protected receiver credential for {0} is not valid UTF-8")]
    InvalidPlaintext(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_dpapi_round_trip_is_receiver_scoped() {
        let first = ReceiverIdentity::parse("001122334455").unwrap();
        let second = ReceiverIdentity::parse("001122334456").unwrap();
        let protected = protect(b"test-password", &entropy_for(&first)).unwrap();
        assert_ne!(protected, b"test-password");
        assert_eq!(
            unprotect(&protected, &entropy_for(&first)).unwrap(),
            b"test-password"
        );
        assert!(unprotect(&protected, &entropy_for(&second)).is_err());
    }

    #[test]
    fn credential_validation_rejects_ambiguous_inputs() {
        assert!(canonical_identity("001122334455").is_ok());
        assert!(canonical_identity("../credential").is_err());
        assert!(validate_password("").is_err());
        assert!(validate_password("contains\0nul").is_err());
    }

    #[test]
    fn store_writes_updates_reads_and_removes_atomically() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "winairplay-credential-test-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        let store = CredentialStore::at(directory.clone());
        store.write("001122334455", "first").unwrap();
        assert_eq!(
            store.read("001122334455").unwrap().as_deref(),
            Some("first")
        );
        store.write("001122334455", "second").unwrap();
        assert_eq!(
            store.read("001122334455").unwrap().as_deref(),
            Some("second")
        );
        assert!(store.remove("001122334455").unwrap());
        assert!(!store.remove("001122334455").unwrap());
        fs::remove_dir(directory).unwrap();
    }
}
