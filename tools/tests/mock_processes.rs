use std::io::{BufRead, BufReader};
use std::net::{SocketAddr, UdpSocket};
use std::process::{Child, ChildStdout, Command, Output, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use winairplay_shared::discovery::{
    AIRPLAY_SERVICE_TYPE, DiscoveryNotification, RAOP_SERVICE_TYPE, RegistryEvent,
};

struct ChildGuard(Option<Child>);

impl ChildGuard {
    fn spawn(command: &mut Command) -> Self {
        Self(Some(command.spawn().expect("child process starts")))
    }

    fn wait_with_output(mut self) -> Output {
        self.0
            .take()
            .expect("child is present")
            .wait_with_output()
            .expect("child process can be joined")
    }

    fn take_stdout(&mut self) -> ChildStdout {
        self.0
            .as_mut()
            .expect("child is present")
            .stdout
            .take()
            .expect("child stdout is piped")
    }

    fn wait_with_output_timeout(mut self, timeout: Duration) -> (Output, bool) {
        let deadline = Instant::now() + timeout;
        loop {
            let child = self.0.as_mut().expect("child is present");
            if child
                .try_wait()
                .expect("child status can be read")
                .is_some()
            {
                return (self.wait_with_output(), false);
            }
            if Instant::now() >= deadline {
                child.kill().expect("timed-out child can be terminated");
                return (self.wait_with_output(), true);
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[test]
fn digest_raop_sender_and_mock_receiver_interoperate_across_processes() {
    let mut receiver_command = Command::new(env!("CARGO_BIN_EXE_mock-raop-receiver"));
    receiver_command
        .args([
            "--bind",
            "127.0.0.1:0",
            "--password",
            "mock-secret",
            "--expected-duration",
            "0.1",
            "--timeout-ms",
            "3000",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut receiver = ChildGuard::spawn(&mut receiver_command);
    let (notifications, receiver_stdout_reader) = capture_stdout(&mut receiver);
    let address = match wait_for_mock_listener(&notifications, Duration::from_secs(3)) {
        Ok(address) => address,
        Err(reason) => {
            let (receiver, timed_out) = receiver.wait_with_output_timeout(Duration::from_secs(1));
            let stdout = join_stdout(receiver_stdout_reader);
            panic!(
                "mock did not become ready: {reason}\nstatus: {}; timed_out: {timed_out}\nstdout: {stdout}\nstderr: {}",
                receiver.status,
                String::from_utf8_lossy(&receiver.stderr)
            );
        }
    };

    // Keep the unpaced burst below the mock's UDP receive buffer. The default
    // one-second tone can lose packets when an optimized sender outruns it.
    let mut sender_command = Command::new(env!("CARGO_BIN_EXE_airplay-send"));
    sender_command
        .args([
            "--receiver",
            &address.to_string(),
            "--password",
            "mock-secret",
            "--duration",
            "0.1",
            "--no-pace",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let sender = ChildGuard::spawn(&mut sender_command);
    let (sender, sender_timed_out) = sender.wait_with_output_timeout(Duration::from_secs(5));
    // Collect both children before asserting so a receiver validation failure
    // remains visible instead of being hidden behind the sender's socket error.
    let (receiver, receiver_timed_out) = receiver.wait_with_output_timeout(Duration::from_secs(5));
    let report = join_stdout(receiver_stdout_reader);
    assert!(
        sender.status.success()
            && receiver.status.success()
            && !sender_timed_out
            && !receiver_timed_out,
        "sender status: {}; timed_out: {sender_timed_out}\nstdout: {}\nstderr: {}\nreceiver status: {}; timed_out: {receiver_timed_out}\nstdout: {report}\nstderr: {}",
        sender.status,
        String::from_utf8_lossy(&sender.stdout),
        String::from_utf8_lossy(&sender.stderr),
        receiver.status,
        String::from_utf8_lossy(&receiver.stderr)
    );
    let validation = report
        .lines()
        .find(|line| line.starts_with("validated: "))
        .expect("mock emits a validation report");
    let fields = validation.split(", ").collect::<Vec<_>>();
    assert!(fields.contains(&"frames=4410"), "{validation}");
    assert!(fields.contains(&"retransmission=true"), "{validation}");
    assert!(fields.contains(&"timing=true"), "{validation}");
}

fn wait_for_mock_listener(
    notifications: &Receiver<String>,
    timeout: Duration,
) -> Result<SocketAddr, String> {
    let line = notifications
        .recv_timeout(timeout)
        .map_err(|error| format!("mock listener readiness failed: {error}"))?;
    let address: SocketAddr = line
        .strip_prefix("mock RAOP receiver listening on ")
        .ok_or_else(|| format!("unexpected mock readiness line: {line}"))?
        .parse()
        .map_err(|error| format!("invalid mock listener address: {error}"))?;
    if !address.ip().is_loopback() || address.port() == 0 {
        return Err(format!(
            "mock did not report a bound loopback address: {address}"
        ));
    }
    Ok(address)
}

#[test]
fn timed_out_mock_receiver_is_terminated_and_reaped() {
    let mut command = Command::new(env!("CARGO_BIN_EXE_mock-raop-receiver"));
    command
        .args(["--bind", "127.0.0.1:0", "--timeout-ms", "10000"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut receiver = ChildGuard::spawn(&mut command);
    let (notifications, stdout_reader) = capture_stdout(&mut receiver);
    let readiness = wait_for_mock_listener(&notifications, Duration::from_secs(3));
    let started = Instant::now();
    // No client is started: the owned receiver must still be waiting when the
    // harness deadline forces termination, process reaping, and pipe closure.
    let (output, timed_out) = receiver.wait_with_output_timeout(Duration::from_millis(100));
    let stdout = join_stdout(stdout_reader);
    assert!(readiness.is_ok(), "mock readiness failed: {readiness:?}");
    assert!(timed_out, "idle mock exited before the harness deadline");
    assert!(!output.status.success(), "terminated mock reported success");
    assert!(stdout.starts_with("mock RAOP receiver listening on "));
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "timeout cleanup failed to finish promptly"
    );
}

#[test]
fn mock_discovery_exercises_remove_and_same_identity_reappearance_across_processes() {
    const IDENTITY: &str = "02ABCDEF7654";
    let port_reservation = UdpSocket::bind("127.0.0.1:0").expect("ephemeral UDP port is available");
    let mdns_port = port_reservation
        .local_addr()
        .expect("ephemeral UDP socket has an address")
        .port()
        .to_string();

    let mut discover_command = Command::new(env!("CARGO_BIN_EXE_airplay-discover"));
    discover_command
        .args([
            "--json",
            "--duration-seconds",
            "7",
            "--offline-grace-seconds",
            "1",
            "--mdns-port",
            &mdns_port,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    drop(port_reservation);
    let mut discover = ChildGuard::spawn(&mut discover_command);
    let (notifications, discover_stdout_reader) = capture_stdout(&mut discover);
    if let Err(reason) = wait_for_searches(&notifications, Duration::from_secs(3)) {
        let discover_output = discover.wait_with_output();
        let discover_stdout = join_stdout(discover_stdout_reader);
        panic!(
            "discovery did not become ready: {reason}\nstatus: {}\nstdout: {discover_stdout}\nstderr: {}",
            discover_output.status,
            String::from_utf8_lossy(&discover_output.stderr)
        );
    }

    run_unicast_advertiser(&mdns_port, IDENTITY);
    wait_for_receiver_event(&notifications, IDENTITY, "removed", Duration::from_secs(3))
        .unwrap_or_else(|reason| panic!("first discovery lifecycle did not finish: {reason}"));

    run_unicast_advertiser(&mdns_port, IDENTITY);
    wait_for_receiver_event(&notifications, IDENTITY, "removed", Duration::from_secs(3))
        .unwrap_or_else(|reason| panic!("reappeared discovery lifecycle did not finish: {reason}"));

    let discover = discover.wait_with_output();
    let output = join_stdout(discover_stdout_reader);
    assert!(
        discover.status.success(),
        "discovery failed\nstdout: {}\nstderr: {}",
        output,
        String::from_utf8_lossy(&discover.stderr)
    );
    let matching = output
        .lines()
        .filter(|line| line.contains(IDENTITY))
        .collect::<Vec<_>>()
        .join("\n");
    assert_eq!(
        matching
            .lines()
            .filter(|line| line.contains("\"change\":{\"event\":\"added\""))
            .count(),
        2,
        "expected initial discovery and same-identity reappearance:\n{matching}\nall discovery output:\n{output}"
    );
    assert_eq!(
        matching
            .lines()
            .filter(|line| line.contains("\"change\":{\"event\":\"grace_started\""))
            .count(),
        2,
        "each fixture lifetime must enter bounded offline grace:\n{matching}"
    );
    assert_eq!(
        matching
            .lines()
            .filter(|line| line.contains("\"change\":{\"event\":\"removed\""))
            .count(),
        2,
        "the reappeared identity must receive final cleanup:\n{matching}"
    );
}

fn run_unicast_advertiser(mdns_port: &str, identity: &str) {
    let advertiser = Command::new(env!("CARGO_BIN_EXE_mock-bonjour-advertiser"))
        .args([
            "--name",
            "WinAirPlayAudio Integration",
            "--device-id",
            identity,
            "--hostname",
            "winairplay-integration.local.",
            "--port",
            "17954",
            "--duration-seconds",
            "1",
            "--mdns-port",
            mdns_port,
            "--unicast-loopback",
        ])
        .output()
        .expect("advertiser process starts");
    assert!(
        advertiser.status.success(),
        "advertiser failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&advertiser.stdout),
        String::from_utf8_lossy(&advertiser.stderr)
    );
}

fn capture_stdout(
    child: &mut ChildGuard,
) -> (
    Receiver<String>,
    JoinHandle<Result<Vec<String>, std::io::Error>>,
) {
    let stdout = child.take_stdout();
    let (sender, receiver) = mpsc::channel();
    let reader = thread::spawn(move || {
        let mut lines = Vec::new();
        for line in BufReader::new(stdout).lines() {
            let line = line?;
            let _ = sender.send(line.clone());
            lines.push(line);
        }
        Ok(lines)
    });
    (receiver, reader)
}

fn wait_for_searches(notifications: &Receiver<String>, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    let mut raop_started = false;
    let mut airplay_started = false;
    while !raop_started || !airplay_started {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("timed out waiting for both mDNS browse operations".to_owned());
        }
        let line = match notifications.recv_timeout(remaining) {
            Ok(line) => line,
            Err(RecvTimeoutError::Timeout) => {
                return Err("timed out waiting for both mDNS browse operations".to_owned());
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err(
                    "discovery stdout closed before both browse operations started".to_owned(),
                );
            }
        };
        let notification: DiscoveryNotification = serde_json::from_str(&line)
            .map_err(|error| format!("invalid discovery JSON `{line}`: {error}"))?;
        if let DiscoveryNotification::SearchStarted { service_type } = notification {
            raop_started |= service_type.starts_with(RAOP_SERVICE_TYPE);
            airplay_started |= service_type.starts_with(AIRPLAY_SERVICE_TYPE);
        }
    }
    Ok(())
}

fn wait_for_receiver_event(
    notifications: &Receiver<String>,
    identity: &str,
    expected_event: &str,
    timeout: Duration,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "timed out waiting for receiver {identity} event {expected_event}"
            ));
        }
        let line = match notifications.recv_timeout(remaining) {
            Ok(line) => line,
            Err(RecvTimeoutError::Timeout) => {
                return Err(format!(
                    "timed out waiting for receiver {identity} event {expected_event}"
                ));
            }
            Err(RecvTimeoutError::Disconnected) => {
                return Err(format!(
                    "discovery stdout closed before receiver {identity} event {expected_event}"
                ));
            }
        };
        let notification: DiscoveryNotification = serde_json::from_str(&line)
            .map_err(|error| format!("invalid discovery JSON `{line}`: {error}"))?;
        let DiscoveryNotification::Registry { change } = notification else {
            continue;
        };
        let (event, receiver) = match change {
            RegistryEvent::Added { receiver } => ("added", receiver),
            RegistryEvent::Updated { receiver } => ("updated", receiver),
            RegistryEvent::GraceStarted { receiver, .. } => ("grace_started", receiver),
            RegistryEvent::GraceCancelled { receiver } => ("grace_cancelled", receiver),
            RegistryEvent::Removing { receiver } => ("removing", receiver),
            RegistryEvent::Removed { receiver } => ("removed", receiver),
        };
        if receiver.identity.as_str() == identity && event == expected_event {
            return Ok(());
        }
    }
}

fn join_stdout(reader: JoinHandle<Result<Vec<String>, std::io::Error>>) -> String {
    reader
        .join()
        .expect("discovery stdout reader does not panic")
        .expect("discovery stdout can be read")
        .join("\n")
}
