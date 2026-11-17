//! Continuously prints bounded, resolved RAOP/AirPlay discovery events.

use std::error::Error;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use clap::Parser;
use winairplay_shared::discovery::{
    DEFAULT_MDNS_PORT, DiscoveryBrowser, DiscoveryConfig, DiscoveryNotification, ReceiverSnapshot,
    RegistryEvent,
};

#[derive(Debug, Parser)]
#[command(
    name = "airplay-discover",
    about = "Browse and resolve local RAOP receivers"
)]
struct Arguments {
    /// Emit one stable JSON object per notification.
    #[arg(long)]
    json: bool,

    /// Stop after this many seconds; zero runs until Ctrl+C.
    #[arg(long, default_value_t = 0)]
    duration_seconds: u64,

    /// Delay endpoint-affecting removal after the final advertisement disappears.
    #[arg(long, default_value_t = 8)]
    offline_grace_seconds: u64,

    #[arg(
        long,
        default_value_t = DEFAULT_MDNS_PORT,
        value_parser = clap::value_parser!(u16).range(1..),
        hide = true
    )]
    mdns_port: u16,
}

fn main() -> Result<(), Box<dyn Error>> {
    let arguments = Arguments::parse();
    let config = DiscoveryConfig {
        offline_grace: Duration::from_secs(arguments.offline_grace_seconds),
        mdns_port: arguments.mdns_port,
        ..DiscoveryConfig::default()
    };
    let (browser, notifications) = DiscoveryBrowser::start(config)?;

    let interrupted = Arc::new(AtomicBool::new(false));
    let handler_flag = Arc::clone(&interrupted);
    ctrlc::set_handler(move || handler_flag.store(true, Ordering::Release))?;
    let deadline = (arguments.duration_seconds != 0)
        .then(|| Instant::now() + Duration::from_secs(arguments.duration_seconds));

    while !interrupted.load(Ordering::Acquire)
        && deadline.is_none_or(|limit| Instant::now() < limit)
    {
        match notifications.recv_timeout(Duration::from_millis(250)) {
            Ok(notification) => print_notification(notification, arguments.json)?,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                return Err("discovery worker stopped unexpectedly".into());
            }
        }
    }

    let dropped = browser.dropped_notifications();
    browser.stop()?;
    if dropped != 0 {
        eprintln!(
            "airplay-discover: {dropped} notifications were dropped because the output queue was full"
        );
    }
    Ok(())
}

fn print_notification(
    notification: DiscoveryNotification,
    json: bool,
) -> Result<(), serde_json::Error> {
    if json {
        println!("{}", serde_json::to_string(&notification)?);
        return Ok(());
    }

    match notification {
        DiscoveryNotification::Registry { change } => match change {
            RegistryEvent::Added { receiver } => print_receiver("added", &receiver),
            RegistryEvent::Updated { receiver } => print_receiver("updated", &receiver),
            RegistryEvent::GraceStarted {
                receiver,
                deadline_ms,
            } => {
                print_receiver("grace", &receiver);
                println!("  removal deadline: +{deadline_ms} ms from browser start");
            }
            RegistryEvent::GraceCancelled { receiver } => {
                print_receiver("returned", &receiver);
            }
            RegistryEvent::Removing { receiver } => print_receiver("removing", &receiver),
            RegistryEvent::Removed { receiver } => print_receiver("removed", &receiver),
        },
        DiscoveryNotification::SearchStarted { service_type } => {
            println!("searching {service_type}");
        }
        DiscoveryNotification::SearchStopped { service_type } => {
            println!("stopped {service_type}");
        }
        DiscoveryNotification::ServiceFound {
            service_type,
            fullname,
        } => {
            println!("found     {service_type} {fullname} (resolving)");
        }
        DiscoveryNotification::Rejected {
            service_type,
            fullname,
            reason,
        } => {
            eprintln!("rejected  {service_type} {fullname}: {reason}");
        }
        DiscoveryNotification::BackendError { operation, reason } => {
            eprintln!("backend   {operation}: {reason}");
        }
        DiscoveryNotification::InterfaceChanged { added, address } => {
            let action = if added { "interface+" } else { "interface-" };
            println!("{action:<10} {address}");
        }
    }
    Ok(())
}

fn print_receiver(action: &str, receiver: &ReceiverSnapshot) {
    let destinations = receiver
        .observations
        .iter()
        .flat_map(|observation| {
            observation.addresses.iter().map(move |address| {
                format!(
                    "{}%{}:{}",
                    address, observation.key.interface.index, observation.port
                )
            })
        })
        .collect::<Vec<_>>()
        .join(",");
    println!(
        "{action:<10} {}  {}  {:?}  {:?}  {destinations}",
        receiver.identity, receiver.display_name, receiver.state, receiver.capability
    );
}

#[cfg(test)]
mod tests {
    use clap::Parser;
    use winairplay_shared::discovery::DEFAULT_MDNS_PORT;

    use super::Arguments;

    #[test]
    fn mdns_port_defaults_to_the_standard_port() {
        let arguments =
            Arguments::try_parse_from(["airplay-discover"]).expect("default arguments parse");
        assert_eq!(arguments.mdns_port, DEFAULT_MDNS_PORT);
    }

    #[test]
    fn mdns_port_rejects_zero() {
        assert!(Arguments::try_parse_from(["airplay-discover", "--mdns-port", "0"]).is_err());
    }
}
