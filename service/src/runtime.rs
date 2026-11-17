//! Service process lifetime and orderly shutdown.

use std::ffi::OsString;
use std::sync::mpsc::{self, SyncSender, TryRecvError, TrySendError};
use std::time::{Duration, Instant};

use thiserror::Error;
use windows_service::define_windows_service;
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus, ServiceType,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;

use crate::config::{ConfigError, ServiceConfig, default_config_path};
use crate::coordinator::{ServiceOrchestrator, ServiceOrchestratorError};

// Keep distinct from the kernel driver's `WinAirPlayAudio` service name.
pub const SERVICE_NAME: &str = "WinAirPlayAudioService";
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

define_windows_service!(ffi_service_main, service_main);

#[derive(Debug, Error)]
pub enum RuntimeError {
    #[error("unable to install Ctrl+C handler: {0}")]
    CtrlC(#[from] ctrlc::Error),
    #[error("Windows service operation failed: {0}")]
    Service(#[from] windows_service::Error),
    #[error("service shutdown channel disconnected unexpectedly")]
    ShutdownChannelDisconnected,
    #[error(transparent)]
    Config(#[from] ConfigError),
    #[error(transparent)]
    Orchestrator(#[from] ServiceOrchestratorError),
}

pub fn run_console(run_for: Option<Duration>) -> Result<(), RuntimeError> {
    let (stop_sender, stop_receiver) = mpsc::sync_channel(1);
    ctrlc::set_handler(move || {
        signal_stop(&stop_sender);
    })?;
    let mut orchestrator = start_orchestrator()?;
    let run_result = poll_until_stopped(
        &stop_receiver,
        run_for.map(|duration| Instant::now() + duration),
        &mut orchestrator,
    );
    finish_orchestrator(run_result, orchestrator)
}

pub fn run_service_dispatcher() -> Result<(), RuntimeError> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
    Ok(())
}

fn service_main(_arguments: Vec<OsString>) {
    if let Err(error) = run_service() {
        // SCM has no console; the bounded JSONL logging layer remains available.
        tracing::error!(component = "service", operation = "run", %error);
    }
}

fn run_service() -> Result<(), RuntimeError> {
    let (stop_sender, stop_receiver) = mpsc::sync_channel(1);
    let handler = move |control| match control {
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        ServiceControl::Stop | ServiceControl::Shutdown => {
            signal_stop(&stop_sender);
            ServiceControlHandlerResult::NoError
        }
        _ => ServiceControlHandlerResult::NotImplemented,
    };
    let status = service_control_handler::register(SERVICE_NAME, handler)?;
    status.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::StartPending,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 1,
        wait_hint: Duration::from_secs(15),
        process_id: None,
    })?;

    // Configuration, DPAPI store setup, mDNS startup, and endpoint-manager
    // construction all happen while SCM still sees StartPending.
    let mut orchestrator = match start_orchestrator() {
        Ok(orchestrator) => orchestrator,
        Err(error) => {
            status.set_service_status(stopped_status(ServiceExitCode::ServiceSpecific(1)))?;
            return Err(error);
        }
    };

    if let Err(error) = status.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::ZERO,
        process_id: None,
    }) {
        drop(orchestrator);
        return Err(error.into());
    }

    let poll_result = poll_until_stopped(&stop_receiver, None, &mut orchestrator);
    let pending_result = status.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::StopPending,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 1,
        wait_hint: Duration::from_mins(1),
        process_id: None,
    });

    // Cleanup begins only after StopPending has been reported. Drop remains a
    // second safety net if status reporting itself fails.
    let run_result = finish_orchestrator(poll_result, orchestrator);
    let combined_result = match pending_result {
        Ok(()) => run_result,
        Err(error) => run_result.and(Err(error.into())),
    };
    let exit_code = if combined_result.is_ok() {
        ServiceExitCode::Win32(0)
    } else {
        ServiceExitCode::ServiceSpecific(1)
    };
    status.set_service_status(stopped_status(exit_code))?;
    combined_result
}

fn stopped_status(exit_code: ServiceExitCode) -> ServiceStatus {
    ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code,
        checkpoint: 0,
        wait_hint: Duration::ZERO,
        process_id: None,
    }
}

fn signal_stop(sender: &SyncSender<()>) {
    match sender.try_send(()) {
        Ok(()) | Err(TrySendError::Full(()) | TrySendError::Disconnected(())) => {}
    }
}

fn start_orchestrator() -> Result<ServiceOrchestrator, RuntimeError> {
    let config_path = default_config_path()?;
    let config = ServiceConfig::load_optional(&config_path)?;
    let orchestrator = ServiceOrchestrator::start(&config)?;
    tracing::info!(
        component = "service",
        configuration = %config_path.display(),
        manage_endpoints = config.manage_endpoints,
        "service orchestration started"
    );
    Ok(orchestrator)
}

fn poll_until_stopped(
    receiver: &mpsc::Receiver<()>,
    deadline: Option<Instant>,
    orchestrator: &mut ServiceOrchestrator,
) -> Result<(), RuntimeError> {
    loop {
        if deadline.is_some_and(|value| Instant::now() >= value) {
            break;
        }
        match receiver.try_recv() {
            Ok(()) => break,
            Err(TryRecvError::Empty) => {}
            Err(TryRecvError::Disconnected) => {
                return Err(RuntimeError::ShutdownChannelDisconnected);
            }
        }
        orchestrator.poll(Duration::from_millis(250))?;
    }
    Ok(())
}

fn finish_orchestrator(
    run_result: Result<(), RuntimeError>,
    orchestrator: ServiceOrchestrator,
) -> Result<(), RuntimeError> {
    let shutdown_result = orchestrator.shutdown().map_err(RuntimeError::from);
    let result = run_result.and(shutdown_result);
    if result.is_ok() {
        tracing::info!(
            component = "service",
            "service orchestration stopped cleanly"
        );
    }
    result
}
