//! Bounded service configuration loading.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use winairplay_shared::discovery::{
    DEFAULT_DISCOVERY_QUERY_INTERVAL, DiscoveryConfig, MAX_DISCOVERY_QUERY_INTERVAL,
    MIN_DISCOVERY_QUERY_INTERVAL, TxtLimits,
};
use winairplay_shared::raop::{MVP_SAMPLE_RATE, RtspMessageLimits};

const MAX_CONFIG_BYTES: u64 = 64 * 1024;
pub const DEFAULT_RAOP_SYNC_LATENCY_MS: u64 = 500;
pub const MIN_RAOP_SYNC_LATENCY_MS: u64 = 250;
pub const MAX_RAOP_SYNC_LATENCY_MS: u64 = 3_000;
const MILLISECONDS_PER_SECOND: u64 = 1_000;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct ServiceConfig {
    pub manage_endpoints: bool,
    pub discovery_query_interval_ms: u64,
    pub offline_grace_ms: u64,
    pub idle_disconnect_ms: u64,
    pub retry_initial_ms: u64,
    pub retry_max_ms: u64,
    pub endpoint_create_timeout_ms: u64,
    pub capture_queue_packets: usize,
    pub raop_sync_latency_ms: u64,
    pub txt_max_records: usize,
    pub txt_max_total_bytes: usize,
    pub txt_max_value_bytes: usize,
    pub rtsp_max_header_bytes: usize,
}

impl Default for ServiceConfig {
    fn default() -> Self {
        let discovery = DiscoveryConfig::default();
        let txt = TxtLimits::default();
        Self {
            manage_endpoints: true,
            discovery_query_interval_ms: duration_millis(DEFAULT_DISCOVERY_QUERY_INTERVAL),
            offline_grace_ms: duration_millis(discovery.offline_grace),
            idle_disconnect_ms: 5_000,
            retry_initial_ms: 250,
            retry_max_ms: 30_000,
            endpoint_create_timeout_ms: 15_000,
            capture_queue_packets: 512,
            raop_sync_latency_ms: DEFAULT_RAOP_SYNC_LATENCY_MS,
            txt_max_records: txt.max_records,
            txt_max_total_bytes: txt.max_total_bytes,
            txt_max_value_bytes: txt.max_value_bytes,
            rtsp_max_header_bytes: RtspMessageLimits::default().max_header_bytes,
        }
    }
}

impl ServiceConfig {
    pub fn load_optional(path: &Path) -> Result<Self, ConfigError> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let metadata = std::fs::metadata(path).map_err(|source| ConfigError::Read {
            path: path.to_path_buf(),
            source,
        })?;
        if metadata.len() > MAX_CONFIG_BYTES {
            return Err(ConfigError::TooLarge {
                actual: metadata.len(),
                maximum: MAX_CONFIG_BYTES,
            });
        }
        let bytes = std::fs::read(path).map_err(|source| ConfigError::Read {
            path: path.to_path_buf(),
            source,
        })?;
        Self::parse(&bytes)
    }

    pub fn parse(bytes: &[u8]) -> Result<Self, ConfigError> {
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAX_CONFIG_BYTES {
            return Err(ConfigError::TooLarge {
                actual: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
                maximum: MAX_CONFIG_BYTES,
            });
        }
        let config: Self = serde_json::from_slice(bytes).map_err(ConfigError::Json)?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        bounded(
            "discovery_query_interval_ms",
            self.discovery_query_interval_ms,
            duration_millis(MIN_DISCOVERY_QUERY_INTERVAL),
            duration_millis(MAX_DISCOVERY_QUERY_INTERVAL),
        )?;
        bounded("offline_grace_ms", self.offline_grace_ms, 1_000, 60_000)?;
        bounded("idle_disconnect_ms", self.idle_disconnect_ms, 500, 600_000)?;
        bounded("retry_initial_ms", self.retry_initial_ms, 10, 60_000)?;
        bounded("retry_max_ms", self.retry_max_ms, 100, 300_000)?;
        if self.retry_initial_ms > self.retry_max_ms {
            return Err(ConfigError::Invalid(
                "retry_initial_ms must not exceed retry_max_ms".to_owned(),
            ));
        }
        bounded(
            "endpoint_create_timeout_ms",
            self.endpoint_create_timeout_ms,
            1_000,
            60_000,
        )?;
        bounded_usize(
            "capture_queue_packets",
            self.capture_queue_packets,
            8,
            4_096,
        )?;
        bounded(
            "raop_sync_latency_ms",
            self.raop_sync_latency_ms,
            MIN_RAOP_SYNC_LATENCY_MS,
            MAX_RAOP_SYNC_LATENCY_MS,
        )?;
        let _ = self.raop_sync_latency_frames()?;
        bounded_usize("txt_max_records", self.txt_max_records, 1, 128)?;
        bounded_usize("txt_max_total_bytes", self.txt_max_total_bytes, 256, 16_384)?;
        bounded_usize("txt_max_value_bytes", self.txt_max_value_bytes, 1, 4_096)?;
        if self.txt_max_value_bytes > self.txt_max_total_bytes {
            return Err(ConfigError::Invalid(
                "txt_max_value_bytes must not exceed txt_max_total_bytes".to_owned(),
            ));
        }
        bounded_usize(
            "rtsp_max_header_bytes",
            self.rtsp_max_header_bytes,
            4_096,
            131_072,
        )?;
        Ok(())
    }

    #[must_use]
    pub const fn txt_limits(&self) -> TxtLimits {
        TxtLimits {
            max_records: self.txt_max_records,
            max_total_bytes: self.txt_max_total_bytes,
            max_value_bytes: self.txt_max_value_bytes,
        }
    }

    #[must_use]
    pub fn endpoint_create_timeout(&self) -> Duration {
        Duration::from_millis(self.endpoint_create_timeout_ms)
    }

    #[must_use]
    pub fn discovery_query_interval(&self) -> Duration {
        Duration::from_millis(self.discovery_query_interval_ms)
    }

    pub fn raop_sync_latency_frames(&self) -> Result<u32, ConfigError> {
        let scaled_frames = self
            .raop_sync_latency_ms
            .checked_mul(u64::from(MVP_SAMPLE_RATE))
            .ok_or_else(|| {
                ConfigError::Invalid(format!(
                    "raop_sync_latency_ms {} cannot be converted to 44.1 kHz frames",
                    self.raop_sync_latency_ms
                ))
            })?;
        let frames = scaled_frames / MILLISECONDS_PER_SECOND;
        u32::try_from(frames).map_err(|_| {
            ConfigError::Invalid(format!(
                "raop_sync_latency_ms {} cannot be represented as a frame count",
                self.raop_sync_latency_ms
            ))
        })
    }
}

pub fn default_config_path() -> Result<PathBuf, ConfigError> {
    let program_data =
        std::env::var_os("ProgramData").ok_or(ConfigError::ProgramDataUnavailable)?;
    Ok(PathBuf::from(program_data)
        .join("WinAirPlayAudio")
        .join("config.json"))
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("ProgramData is unavailable; pass an explicit configuration path")]
    ProgramDataUnavailable,
    #[error("could not read configuration {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("configuration is {actual} bytes; maximum is {maximum}")]
    TooLarge { actual: u64, maximum: u64 },
    #[error("configuration JSON is invalid: {0}")]
    Json(serde_json::Error),
    #[error("configuration value is invalid: {0}")]
    Invalid(String),
}

fn duration_millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

fn bounded(name: &str, value: u64, minimum: u64, maximum: u64) -> Result<(), ConfigError> {
    if (minimum..=maximum).contains(&value) {
        Ok(())
    } else {
        Err(ConfigError::Invalid(format!(
            "{name} must be between {minimum} and {maximum}; got {value}"
        )))
    }
}

fn bounded_usize(
    name: &str,
    value: usize,
    minimum: usize,
    maximum: usize,
) -> Result<(), ConfigError> {
    if (minimum..=maximum).contains(&value) {
        Ok(())
    } else {
        Err(ConfigError::Invalid(format!(
            "{name} must be between {minimum} and {maximum}; got {value}"
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_validate() {
        ServiceConfig::default().validate().unwrap();
    }

    #[test]
    fn partial_configuration_uses_central_defaults() {
        let config = ServiceConfig::parse(br#"{"offline_grace_ms":5000}"#).unwrap();
        assert_eq!(config.offline_grace_ms, 5_000);
        assert_eq!(
            config.discovery_query_interval_ms,
            duration_millis(DEFAULT_DISCOVERY_QUERY_INTERVAL)
        );
        assert_eq!(
            config.capture_queue_packets,
            ServiceConfig::default().capture_queue_packets
        );
        assert_eq!(config.raop_sync_latency_ms, DEFAULT_RAOP_SYNC_LATENCY_MS);
        assert_eq!(config.raop_sync_latency_frames().unwrap(), 22_050);
    }

    #[test]
    fn discovery_query_interval_is_bounded() {
        for value in [999, 60_001] {
            let input = format!(r#"{{"discovery_query_interval_ms":{value}}}"#);
            let error = ServiceConfig::parse(input.as_bytes()).unwrap_err();
            assert!(
                error
                    .to_string()
                    .contains("discovery_query_interval_ms must be between 1000 and 60000")
            );
        }
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let error = ServiceConfig::parse(br#"{"offline_grace_ms":5000,"typo":1}"#).unwrap_err();
        assert!(matches!(error, ConfigError::Json(_)));
    }

    #[test]
    fn retry_bounds_are_consistent() {
        let error =
            ServiceConfig::parse(br#"{"retry_initial_ms":1000,"retry_max_ms":500}"#).unwrap_err();
        assert!(error.to_string().contains("must not exceed"));
    }

    #[test]
    fn raop_sync_latency_is_bounded_and_converts_to_frames() {
        for (milliseconds, expected_frames) in [(250, 11_025), (500, 22_050), (3_000, 132_300)] {
            let input = format!(r#"{{"raop_sync_latency_ms":{milliseconds}}}"#);
            let config = ServiceConfig::parse(input.as_bytes()).unwrap();
            assert_eq!(config.raop_sync_latency_frames().unwrap(), expected_frames);
        }

        for milliseconds in [249, 3_001] {
            let input = format!(r#"{{"raop_sync_latency_ms":{milliseconds}}}"#);
            let error = ServiceConfig::parse(input.as_bytes()).unwrap_err();
            assert!(
                error
                    .to_string()
                    .contains("raop_sync_latency_ms must be between 250 and 3000")
            );
        }
    }

    #[test]
    fn oversized_configuration_is_rejected_before_parse() {
        let input = vec![b' '; usize::try_from(MAX_CONFIG_BYTES).unwrap() + 1];
        assert!(matches!(
            ServiceConfig::parse(&input),
            Err(ConfigError::TooLarge { .. })
        ));
    }
}
