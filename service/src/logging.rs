//! Bounded structured service logging.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use thiserror::Error;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::prelude::*;

const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;
const MAX_RECORD_BYTES: usize = 64 * 1024;

#[derive(Debug, Error)]
pub enum LoggingError {
    #[error("ProgramData is unavailable for service logging")]
    ProgramDataUnavailable,
    #[error("cannot initialize structured log {path}: {source}")]
    Open {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("cannot install tracing subscriber: {0}")]
    Subscriber(String),
}

pub fn initialize(console: bool) -> Result<(), LoggingError> {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("winairplay_service=info,winairplay_shared=info"));
    if console {
        tracing_subscriber::registry()
            .with(filter)
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .with_ansi(false)
                    .with_writer(io::stderr),
            )
            .try_init()
            .map_err(|error| LoggingError::Subscriber(error.to_string()))
    } else {
        let writer = BoundedLogWriter::open(&default_log_path()?)?;
        tracing_subscriber::registry()
            .with(filter)
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .with_ansi(false)
                    .with_writer(writer),
            )
            .try_init()
            .map_err(|error| LoggingError::Subscriber(error.to_string()))
    }
}

pub fn default_log_path() -> Result<PathBuf, LoggingError> {
    let program_data =
        std::env::var_os("ProgramData").ok_or(LoggingError::ProgramDataUnavailable)?;
    Ok(PathBuf::from(program_data)
        .join("WinAirPlayAudio")
        .join("logs")
        .join("service.jsonl"))
}

#[derive(Clone)]
struct BoundedLogWriter {
    state: Arc<Mutex<LogState>>,
}

struct LogState {
    path: PathBuf,
    rotated_path: PathBuf,
    file: Option<File>,
    length: u64,
    maximum: u64,
}

impl BoundedLogWriter {
    fn open(path: &Path) -> Result<Self, LoggingError> {
        Self::open_with_limit(path, MAX_LOG_BYTES)
    }

    fn open_with_limit(path: &Path, maximum: u64) -> Result<Self, LoggingError> {
        let parent = path.parent().ok_or_else(|| LoggingError::Open {
            path: path.to_path_buf(),
            source: io::Error::new(io::ErrorKind::InvalidInput, "log path has no parent"),
        })?;
        fs::create_dir_all(parent).map_err(|source| LoggingError::Open {
            path: path.to_path_buf(),
            source,
        })?;
        let file = open_append(path).map_err(|source| LoggingError::Open {
            path: path.to_path_buf(),
            source,
        })?;
        let length = file.metadata().map_or(0, |value| value.len());
        Ok(Self {
            state: Arc::new(Mutex::new(LogState {
                path: path.to_path_buf(),
                rotated_path: path.with_extension("jsonl.1"),
                file: Some(file),
                length,
                maximum,
            })),
        })
    }
}

struct LogWriterGuard<'a>(MutexGuard<'a, LogState>);

impl<'a> MakeWriter<'a> for BoundedLogWriter {
    type Writer = LogWriterGuard<'a>;

    fn make_writer(&'a self) -> Self::Writer {
        LogWriterGuard(
            self.state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
    }
}

impl Write for LogWriterGuard<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_RECORD_BYTES {
            static OVERSIZED: &[u8] =
                b"{\"level\":\"ERROR\",\"message\":\"oversized structured log record dropped\"}\n";
            self.0.write_record(OVERSIZED)?;
            return Ok(bytes.len());
        }
        self.0.write_record(bytes)?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0
            .file
            .as_mut()
            .ok_or_else(|| io::Error::other("structured log file is unavailable"))?
            .flush()
    }
}

impl LogState {
    fn write_record(&mut self, bytes: &[u8]) -> io::Result<()> {
        let byte_count = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if self.length.saturating_add(byte_count) > self.maximum {
            self.rotate()?;
        }
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| io::Error::other("structured log file is unavailable"))?;
        file.write_all(bytes)?;
        self.length = self.length.saturating_add(byte_count);
        Ok(())
    }

    fn rotate(&mut self) -> io::Result<()> {
        if let Some(mut file) = self.file.take() {
            file.flush()?;
        }
        match fs::remove_file(&self.rotated_path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        match fs::rename(&self.path, &self.rotated_path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        self.file = Some(open_append(&self.path)?);
        self.length = 0;
        Ok(())
    }
}

fn open_append(path: &Path) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_writer_rotates_instead_of_growing_forever() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "winairplay-log-test-{}-{unique}",
            std::process::id()
        ));
        let path = directory.join("service.jsonl");
        let writer = BoundedLogWriter::open_with_limit(&path, 8).unwrap();
        {
            let mut output = writer.make_writer();
            output.write_all(b"12345678").unwrap();
            output.write_all(b"next").unwrap();
            output.flush().unwrap();
        }
        assert_eq!(fs::read_to_string(&path).unwrap(), "next");
        assert_eq!(
            fs::read_to_string(path.with_extension("jsonl.1")).unwrap(),
            "12345678"
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
