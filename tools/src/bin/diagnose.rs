use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::mem::size_of;
use std::os::windows::io::AsRawHandle;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use clap::Parser;
use serde_json::{Value, json};
use winairplay_service::logging::default_log_path;
use winairplay_service::wasapi::list_render_endpoints;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Security::{GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TokenElevation};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::core::PCWSTR;

const MAX_COMMAND_OUTPUT_BYTES: usize = 256 * 1024;
const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Parser)]
#[command(about = "Collect bounded WinAirPlayAudio diagnostics without raw audio or secrets")]
struct Arguments {
    /// Write JSON to this file instead of standard output.
    #[arg(long)]
    output: Option<PathBuf>,

    /// Run a bounded live discovery probe for this many seconds; zero disables it.
    #[arg(long, default_value_t = 3, value_parser = clap::value_parser!(u64).range(0..=30))]
    discovery_seconds: u64,
}

struct KillOnCloseJob(HANDLE);

impl KillOnCloseJob {
    fn create() -> Result<Self, windows::core::Error> {
        // SAFETY: no security attributes or job name are supplied.
        let handle = unsafe { CreateJobObjectW(None, PCWSTR::null()) }?;
        let job = Self(handle);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: `limits` has the exact structure and length for the selected class.
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
                    .expect("job information structure fits u32"),
            )
        }?;
        Ok(job)
    }

    fn assign(&self, child: &Child) -> Result<(), windows::core::Error> {
        // SAFETY: the Child owns a live process handle and the job handle is live.
        unsafe { AssignProcessToJobObject(self.0, HANDLE(child.as_raw_handle())) }
    }

    fn terminate(&self) -> Result<(), windows::core::Error> {
        // SAFETY: the handle is a live job object owned by self.
        unsafe { TerminateJobObject(self.0, 1) }
    }
}

impl Drop for KillOnCloseJob {
    fn drop(&mut self) {
        // SAFETY: this type exclusively owns the job handle.
        let _ = unsafe { CloseHandle(self.0) };
    }
}

fn command_capture(program: &str, arguments: &[&str]) -> Value {
    command_capture_with_timeout(program, arguments, DEFAULT_COMMAND_TIMEOUT)
}

fn command_capture_with_timeout(program: &str, arguments: &[&str], timeout: Duration) -> Value {
    let job = match KillOnCloseJob::create() {
        Ok(job) => job,
        Err(error) => {
            return json!({
                "program": program,
                "arguments": arguments,
                "job_error": error.to_string(),
            });
        }
    };
    match Command::new(program)
        .args(arguments)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(mut child) => {
            let stdout = child
                .stdout
                .take()
                .map(|pipe| thread::spawn(move || drain_bounded(pipe)));
            let stderr = child
                .stderr
                .take()
                .map(|pipe| thread::spawn(move || drain_bounded(pipe)));
            if let Err(error) = job.assign(&child) {
                let _ = child.kill();
                let _ = child.wait();
                let (stdout, stdout_truncated) = join_capture(stdout);
                let (stderr, stderr_truncated) = join_capture(stderr);
                return json!({
                    "program": program,
                    "arguments": arguments,
                    "job_error": error.to_string(),
                    "stdout": stdout,
                    "stderr": stderr,
                    "truncated": stdout_truncated || stderr_truncated,
                });
            }
            let (status, timed_out, wait_error) = wait_bounded(&mut child, &job, timeout);
            let (stdout, stdout_truncated) = join_capture(stdout);
            let (stderr, stderr_truncated) = join_capture(stderr);
            json!({
                "program": program,
                "arguments": arguments,
                "exit_code": status.and_then(|value| value.code()),
                "timed_out": timed_out,
                "timeout_ms": timeout.as_millis(),
                "wait_error": wait_error,
                "stdout": stdout,
                "stderr": stderr,
                "truncated": stdout_truncated || stderr_truncated,
            })
        }
        Err(error) => json!({
            "program": program,
            "arguments": arguments,
            "spawn_error": error.to_string(),
        }),
    }
}

fn wait_bounded(
    child: &mut Child,
    job: &KillOnCloseJob,
    timeout: Duration,
) -> (Option<ExitStatus>, bool, Option<String>) {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return (Some(status), false, None),
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(20));
            }
            Ok(None) => {
                let terminate_error = job.terminate().err().map(|error| error.to_string());
                let _ = child.kill();
                return match child.wait() {
                    Ok(status) => (Some(status), true, terminate_error),
                    Err(error) => (
                        None,
                        true,
                        Some(match terminate_error {
                            Some(job_error) => {
                                format!("terminating job: {job_error}; waiting for child: {error}")
                            }
                            None => format!("waiting for terminated child: {error}"),
                        }),
                    ),
                };
            }
            Err(error) => return (None, false, Some(error.to_string())),
        }
    }
}

fn drain_bounded(mut input: impl Read) -> (String, bool) {
    let mut captured = Vec::with_capacity(MAX_COMMAND_OUTPUT_BYTES);
    let mut buffer = [0_u8; 8 * 1024];
    let mut truncated = false;
    loop {
        let length = match input.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(length) => length,
        };
        let remaining = MAX_COMMAND_OUTPUT_BYTES.saturating_sub(captured.len());
        let retained = length.min(remaining);
        captured.extend_from_slice(&buffer[..retained]);
        truncated |= retained < length;
    }
    (String::from_utf8_lossy(&captured).into_owned(), truncated)
}

fn join_capture(capture: Option<thread::JoinHandle<(String, bool)>>) -> (String, bool) {
    capture
        .and_then(|thread| thread.join().ok())
        .unwrap_or_else(|| ("<capture failed>".to_owned(), true))
}

fn recent_log() -> Value {
    let path = match default_log_path() {
        Ok(path) => path,
        Err(error) => return json!({ "error": error.to_string() }),
    };
    let result = (|| {
        let mut file = File::open(&path)?;
        let length = file.metadata()?.len();
        let wanted = length.min(u64::try_from(MAX_COMMAND_OUTPUT_BYTES).unwrap_or(u64::MAX));
        let offset = i64::try_from(wanted).unwrap_or(i64::MAX);
        file.seek(SeekFrom::End(-offset))?;
        let mut bytes = Vec::with_capacity(usize::try_from(wanted).unwrap_or_default());
        file.take(wanted).read_to_end(&mut bytes)?;
        Ok::<_, std::io::Error>((bytes, length > wanted))
    })();
    match result {
        Ok((bytes, truncated)) => json!({
            "path": path.display().to_string(),
            "tail": String::from_utf8_lossy(&bytes),
            "truncated": truncated,
        }),
        Err(error) => json!({
            "path": path.display().to_string(),
            "read_error": error.to_string(),
        }),
    }
}

fn discovery_probe(seconds: u64) -> Value {
    if seconds == 0 {
        return json!({ "skipped": true });
    }
    let executable = std::env::current_exe().ok().and_then(|path| {
        path.parent()
            .map(|parent| parent.join("airplay-discover.exe"))
    });
    let Some(executable) = executable else {
        return json!({ "error": "cannot resolve diagnostic executable directory" });
    };
    let executable_text = executable.to_string_lossy();
    let duration = seconds.to_string();
    command_capture_with_timeout(
        &executable_text,
        &["--json", "--duration-seconds", &duration],
        Duration::from_secs(seconds.saturating_add(5)),
    )
}

fn collect(arguments: &Arguments) -> Value {
    let endpoints = match list_render_endpoints() {
        Ok(values) => json!(
            values
                .into_iter()
                .map(|endpoint| json!({
                    "endpoint_id": endpoint.endpoint_id,
                    "friendly_name": endpoint.friendly_name,
                    "container_id": endpoint.container_id.map(|value| value.to_string()),
                    "receiver_id": endpoint.receiver_id,
                }))
                .collect::<Vec<_>>()
        ),
        Err(error) => json!({ "error": error.to_string() }),
    };
    let system_root = std::env::var_os("SystemRoot").map(PathBuf::from);
    let bonjour_dll = system_root
        .as_ref()
        .map(|root| root.join("System32").join("dnssd.dll"));

    json!({
        "schema": "WinAirPlayAudio.diagnostics.v1",
        "version": env!("CARGO_PKG_VERSION"),
        "raw_audio_included": false,
        "authorization_headers_included": false,
        "process": {
            "arch": std::env::consts::ARCH,
            "os": std::env::consts::OS,
            "elevated": is_elevated(),
        },
        "installed_bonjour": {
            "system32_dnssd_path": bonjour_dll.as_ref().map(|path| path.display().to_string()),
            "system32_dnssd_exists": bonjour_dll.is_some_and(|path| path.is_file()),
        },
        "service": command_capture("sc.exe", &["query", "WinAirPlayAudioService"]),
        "driver_service": command_capture("sc.exe", &["query", "WinAirPlayAudio"]),
        "recent_structured_log": recent_log(),
        "discovery_probe": discovery_probe(arguments.discovery_seconds),
        "ip_configuration": command_capture("ipconfig.exe", &["/all"]),
        "os_version": command_capture("cmd.exe", &["/d", "/c", "ver"]),
        "endpoints": endpoints,
    })
}

fn is_elevated() -> bool {
    let mut token = HANDLE::default();
    // SAFETY: token receives a new handle for the current pseudo-process handle.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw mut token) }.is_err() {
        return false;
    }
    let mut elevation = TOKEN_ELEVATION::default();
    let mut returned = 0_u32;
    // SAFETY: `elevation` is writable for the exact size supplied and token is live.
    let result = unsafe {
        GetTokenInformation(
            token,
            TokenElevation,
            Some((&raw mut elevation).cast()),
            u32::try_from(size_of::<TOKEN_ELEVATION>())
                .expect("token elevation structure fits u32"),
            &raw mut returned,
        )
    };
    // SAFETY: OpenProcessToken created this handle.
    let _ = unsafe { CloseHandle(token) };
    result.is_ok() && elevation.TokenIsElevated != 0
}

fn run(arguments: &Arguments) -> Result<(), String> {
    let content = serde_json::to_string_pretty(&collect(arguments))
        .map_err(|error| format!("serializing diagnostic report: {error}"))?;
    if let Some(path) = &arguments.output {
        std::fs::write(path, format!("{content}\n"))
            .map_err(|error| format!("writing {}: {error}", path.display()))?;
        println!("Diagnostic report written to {}", path.display());
    } else {
        println!("{content}");
    }
    Ok(())
}

fn main() {
    let arguments = Arguments::parse();
    if let Err(error) = run(&arguments) {
        eprintln!("diagnose: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_capture_terminates_a_timed_out_process_tree() {
        let result = command_capture_with_timeout(
            "cmd.exe",
            &["/d", "/c", "ping -n 6 127.0.0.1 >nul"],
            Duration::from_millis(100),
        );
        assert_eq!(result["timed_out"], true);
    }
}
