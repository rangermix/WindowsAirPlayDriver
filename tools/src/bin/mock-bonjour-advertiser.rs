//! Advertises deterministic matching `_raop` and `_airplay` mock services.

use std::collections::BTreeSet;
use std::error::Error;
use std::net::{IpAddr, Ipv4Addr, SocketAddrV4, UdpSocket};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use clap::Parser;
use mdns_sd::{DaemonEvent, ServiceDaemon, ServiceInfo};
use winairplay_shared::discovery::{AIRPLAY_SERVICE_TYPE, DEFAULT_MDNS_PORT, RAOP_SERVICE_TYPE};
use winairplay_shared::identity::ReceiverIdentity;

#[derive(Debug, Parser)]
#[command(
    name = "mock-bonjour-advertiser",
    about = "Advertise deterministic local RAOP fixtures"
)]
struct Arguments {
    /// Base display name. A numeric suffix is added when count is greater than one.
    #[arg(long, default_value = "WinAirPlayAudio Mock")]
    name: String,

    /// First six-byte hexadecimal RAOP device identifier.
    #[arg(long, default_value = "020000000001")]
    device_id: String,

    /// Hostname used for the first receiver.
    #[arg(long, default_value = "winairplay-mock.local.")]
    hostname: String,

    /// First mock RTSP port.
    #[arg(long, default_value_t = 7_000)]
    port: u16,

    /// Number of matching receiver pairs to advertise.
    #[arg(long, default_value_t = 1, value_parser = clap::value_parser!(u16).range(1..=32))]
    count: u16,

    /// Explicit address; omit to advertise all eligible active interface addresses.
    #[arg(long)]
    address: Option<IpAddr>,

    /// Stop after this many seconds; zero runs until Ctrl+C.
    #[arg(long, default_value_t = 0)]
    duration_seconds: u64,

    /// Mark the RAOP fixture as password protected.
    #[arg(long)]
    password_required: bool,

    #[arg(
        long,
        default_value_t = DEFAULT_MDNS_PORT,
        value_parser = clap::value_parser!(u16).range(1..),
        hide = true
    )]
    mdns_port: u16,

    #[arg(long, hide = true)]
    unicast_loopback: bool,
}

const DNS_FLAG_RESPONSE_AUTHORITATIVE: u16 = 0x8400;
const DNS_CLASS_IN: u16 = 1;
const DNS_CLASS_IN_CACHE_FLUSH: u16 = 0x8001;
const DNS_TYPE_A: u16 = 1;
const DNS_TYPE_PTR: u16 = 12;
const DNS_TYPE_TXT: u16 = 16;
const DNS_TYPE_SRV: u16 = 33;
const FIXTURE_TTL_SECONDS: u32 = 120;
const MAX_FIXTURE_PACKET_BYTES: usize = 9_000;

fn main() -> Result<(), Box<dyn Error>> {
    let arguments = Arguments::parse();
    let base_identity = ReceiverIdentity::parse(&arguments.device_id)?;
    let base_value = u64::from_str_radix(base_identity.as_str(), 16)?;
    let last_offset = u64::from(arguments.count - 1);
    if base_value > 0xFFFF_FFFF_FFFF - last_offset {
        return Err("device-id range exceeds 48 bits".into());
    }
    let last_port_offset = arguments.count - 1;
    if arguments.port.checked_add(last_port_offset).is_none() {
        return Err("port range exceeds 65535".into());
    }
    if arguments.unicast_loopback {
        if arguments.count != 1 {
            return Err("unicast loopback mode supports exactly one receiver".into());
        }
        return run_unicast_loopback(&arguments, base_value);
    }

    let daemon = ServiceDaemon::new_with_port(arguments.mdns_port)?;
    let monitor = daemon.monitor()?;
    let mut fullnames = Vec::with_capacity(usize::from(arguments.count) * 2);
    let mut advertised_receivers = Vec::with_capacity(usize::from(arguments.count));
    for offset in 0..arguments.count {
        let identity = format!("{:012X}", base_value + u64::from(offset));
        let display_name = if arguments.count == 1 {
            arguments.name.clone()
        } else {
            format!("{} {}", arguments.name, offset + 1)
        };
        let hostname = indexed_hostname(&arguments.hostname, offset, arguments.count)?;
        let port = arguments.port + offset;
        let device_id_txt = colon_device_id(&identity);

        let raop_properties = raop_properties(arguments.password_required);
        let airplay_properties = airplay_properties(&device_id_txt);

        let raop = service_info(
            RAOP_SERVICE_TYPE,
            &format!("{identity}@{display_name}"),
            &hostname,
            arguments.address,
            port,
            &raop_properties,
        )?;
        let airplay = service_info(
            AIRPLAY_SERVICE_TYPE,
            &display_name,
            &hostname,
            arguments.address,
            port,
            &airplay_properties,
        )?;
        fullnames.push(raop.get_fullname().to_owned());
        fullnames.push(airplay.get_fullname().to_owned());
        daemon.register(raop)?;
        daemon.register(airplay)?;
        advertised_receivers.push((identity, display_name, hostname, port));
    }
    wait_for_announcements(&monitor, &fullnames, Duration::from_secs(10))?;
    for (identity, display_name, hostname, port) in advertised_receivers {
        println!(
            "advertised {identity} \"{display_name}\" at {hostname}:{port} as {RAOP_SERVICE_TYPE} and {AIRPLAY_SERVICE_TYPE}"
        );
    }

    wait_for_lifetime(arguments.duration_seconds)?;

    for fullname in fullnames {
        let status = daemon.unregister(&fullname)?;
        let _ = status.recv_timeout(Duration::from_secs(2));
    }
    let shutdown = daemon.shutdown()?;
    let _ = shutdown.recv_timeout(Duration::from_secs(2));
    Ok(())
}

fn run_unicast_loopback(arguments: &Arguments, base_value: u64) -> Result<(), Box<dyn Error>> {
    if arguments.name.contains('.') {
        return Err("unicast loopback fixture name cannot contain a dot".into());
    }
    let identity = format!("{base_value:012X}");
    let display_name = arguments.name.clone();
    let hostname = indexed_hostname(&arguments.hostname, 0, 1)?;
    let advertised_address = match arguments.address {
        Some(IpAddr::V4(address)) => address,
        Some(IpAddr::V6(_)) => {
            return Err("unicast loopback mode requires an IPv4 fixture address".into());
        }
        None => Ipv4Addr::LOCALHOST,
    };
    let raop_properties = raop_properties(arguments.password_required);
    let airplay_properties = airplay_properties(&colon_device_id(&identity));
    let announcement = fixture_announcement(
        &identity,
        &display_name,
        &hostname,
        advertised_address,
        arguments.port,
        &raop_properties,
        &airplay_properties,
    )?;
    let goodbye = fixture_goodbye(&identity, &display_name)?;

    let socket = UdpSocket::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0))?;
    let target = SocketAddrV4::new(Ipv4Addr::LOCALHOST, arguments.mdns_port);
    send_complete_datagram(&socket, &announcement, target)?;
    println!(
        "advertised {identity} \"{display_name}\" at {hostname}:{} as {RAOP_SERVICE_TYPE} and {AIRPLAY_SERVICE_TYPE}",
        arguments.port
    );

    wait_for_lifetime(arguments.duration_seconds)?;
    send_complete_datagram(&socket, &goodbye, target)?;
    Ok(())
}

fn send_complete_datagram(
    socket: &UdpSocket,
    packet: &[u8],
    target: SocketAddrV4,
) -> Result<(), Box<dyn Error>> {
    let sent = socket.send_to(packet, target)?;
    if sent != packet.len() {
        return Err(format!(
            "short mDNS fixture datagram write: sent {sent} of {} bytes",
            packet.len()
        )
        .into());
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn fixture_announcement(
    identity: &str,
    display_name: &str,
    hostname: &str,
    address: Ipv4Addr,
    port: u16,
    raop_properties: &[(String, String)],
    airplay_properties: &[(String, String)],
) -> Result<Vec<u8>, Box<dyn Error>> {
    let raop_fullname = format!("{identity}@{display_name}.{RAOP_SERVICE_TYPE}");
    let airplay_fullname = format!("{display_name}.{AIRPLAY_SERVICE_TYPE}");
    let mut packet = dns_response_header(2, 5);

    append_dns_record(
        &mut packet,
        RAOP_SERVICE_TYPE,
        DNS_TYPE_PTR,
        DNS_CLASS_IN,
        FIXTURE_TTL_SECONDS,
        &encode_dns_name(&raop_fullname)?,
    )?;
    append_dns_record(
        &mut packet,
        AIRPLAY_SERVICE_TYPE,
        DNS_TYPE_PTR,
        DNS_CLASS_IN,
        FIXTURE_TTL_SECONDS,
        &encode_dns_name(&airplay_fullname)?,
    )?;
    append_dns_record(
        &mut packet,
        &raop_fullname,
        DNS_TYPE_SRV,
        DNS_CLASS_IN_CACHE_FLUSH,
        FIXTURE_TTL_SECONDS,
        &encode_srv_record(port, hostname)?,
    )?;
    append_dns_record(
        &mut packet,
        &raop_fullname,
        DNS_TYPE_TXT,
        DNS_CLASS_IN_CACHE_FLUSH,
        FIXTURE_TTL_SECONDS,
        &encode_txt_record(raop_properties)?,
    )?;
    append_dns_record(
        &mut packet,
        &airplay_fullname,
        DNS_TYPE_SRV,
        DNS_CLASS_IN_CACHE_FLUSH,
        FIXTURE_TTL_SECONDS,
        &encode_srv_record(port, hostname)?,
    )?;
    append_dns_record(
        &mut packet,
        &airplay_fullname,
        DNS_TYPE_TXT,
        DNS_CLASS_IN_CACHE_FLUSH,
        FIXTURE_TTL_SECONDS,
        &encode_txt_record(airplay_properties)?,
    )?;
    append_dns_record(
        &mut packet,
        hostname,
        DNS_TYPE_A,
        DNS_CLASS_IN_CACHE_FLUSH,
        FIXTURE_TTL_SECONDS,
        &address.octets(),
    )?;
    validate_fixture_packet_size(&packet)?;
    Ok(packet)
}

fn fixture_goodbye(identity: &str, display_name: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let raop_fullname = format!("{identity}@{display_name}.{RAOP_SERVICE_TYPE}");
    let airplay_fullname = format!("{display_name}.{AIRPLAY_SERVICE_TYPE}");
    let mut packet = dns_response_header(2, 0);
    append_dns_record(
        &mut packet,
        RAOP_SERVICE_TYPE,
        DNS_TYPE_PTR,
        DNS_CLASS_IN,
        0,
        &encode_dns_name(&raop_fullname)?,
    )?;
    append_dns_record(
        &mut packet,
        AIRPLAY_SERVICE_TYPE,
        DNS_TYPE_PTR,
        DNS_CLASS_IN,
        0,
        &encode_dns_name(&airplay_fullname)?,
    )?;
    validate_fixture_packet_size(&packet)?;
    Ok(packet)
}

fn dns_response_header(answer_count: u16, additional_count: u16) -> Vec<u8> {
    let mut packet = Vec::with_capacity(512);
    push_u16(&mut packet, 0);
    push_u16(&mut packet, DNS_FLAG_RESPONSE_AUTHORITATIVE);
    push_u16(&mut packet, 0);
    push_u16(&mut packet, answer_count);
    push_u16(&mut packet, 0);
    push_u16(&mut packet, additional_count);
    packet
}

fn append_dns_record(
    packet: &mut Vec<u8>,
    name: &str,
    record_type: u16,
    class: u16,
    ttl: u32,
    data: &[u8],
) -> Result<(), Box<dyn Error>> {
    packet.extend_from_slice(&encode_dns_name(name)?);
    push_u16(packet, record_type);
    push_u16(packet, class);
    packet.extend_from_slice(&ttl.to_be_bytes());
    push_u16(packet, u16::try_from(data.len())?);
    packet.extend_from_slice(data);
    Ok(())
}

fn encode_dns_name(name: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let Some(without_root) = name.strip_suffix('.') else {
        return Err(format!("DNS name must be absolute: {name}").into());
    };
    if without_root.is_empty() {
        return Err("DNS name must contain at least one label".into());
    }
    let mut encoded = Vec::with_capacity(name.len() + 1);
    for label in without_root.split('.') {
        let bytes = label.as_bytes();
        if bytes.is_empty() || bytes.len() > 63 {
            return Err(format!("DNS label length is outside 1..=63 bytes: {label}").into());
        }
        encoded.push(u8::try_from(bytes.len())?);
        encoded.extend_from_slice(bytes);
    }
    encoded.push(0);
    if encoded.len() > 255 {
        return Err(format!("encoded DNS name exceeds 255 bytes: {name}").into());
    }
    Ok(encoded)
}

fn encode_srv_record(port: u16, hostname: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let mut data = Vec::new();
    push_u16(&mut data, 0);
    push_u16(&mut data, 0);
    push_u16(&mut data, port);
    data.extend_from_slice(&encode_dns_name(hostname)?);
    Ok(data)
}

fn encode_txt_record(properties: &[(String, String)]) -> Result<Vec<u8>, Box<dyn Error>> {
    let mut data = Vec::new();
    for (key, value) in properties {
        let property = format!("{key}={value}");
        if property.len() > usize::from(u8::MAX) {
            return Err(format!("TXT property exceeds 255 bytes: {key}").into());
        }
        data.push(u8::try_from(property.len())?);
        data.extend_from_slice(property.as_bytes());
    }
    if data.len() > usize::from(u16::MAX) {
        return Err("encoded TXT record exceeds 65535 bytes".into());
    }
    Ok(data)
}

fn push_u16(buffer: &mut Vec<u8>, value: u16) {
    buffer.extend_from_slice(&value.to_be_bytes());
}

fn validate_fixture_packet_size(packet: &[u8]) -> Result<(), Box<dyn Error>> {
    if packet.len() > MAX_FIXTURE_PACKET_BYTES {
        return Err(format!(
            "mDNS fixture packet exceeds {MAX_FIXTURE_PACKET_BYTES} bytes: {}",
            packet.len()
        )
        .into());
    }
    Ok(())
}

fn raop_properties(password_required: bool) -> Vec<(String, String)> {
    vec![
        ("ch".to_owned(), "2".to_owned()),
        ("cn".to_owned(), "0,1".to_owned()),
        ("et".to_owned(), "0,1".to_owned()),
        ("md".to_owned(), "0,1,2".to_owned()),
        ("pw".to_owned(), password_required.to_string()),
        ("sr".to_owned(), "44100".to_owned()),
        ("ss".to_owned(), "16".to_owned()),
        ("tp".to_owned(), "UDP,TCP".to_owned()),
        ("txtvers".to_owned(), "1".to_owned()),
        ("vn".to_owned(), "3".to_owned()),
    ]
}

fn airplay_properties(device_id: &str) -> Vec<(String, String)> {
    vec![
        ("deviceid".to_owned(), device_id.to_owned()),
        ("features".to_owned(), "0x0".to_owned()),
        ("flags".to_owned(), "0x4".to_owned()),
        ("model".to_owned(), "WinAirPlayAudioMock1,1".to_owned()),
        ("srcvers".to_owned(), "220.68".to_owned()),
    ]
}

fn wait_for_lifetime(duration_seconds: u64) -> Result<(), ctrlc::Error> {
    let interrupted = Arc::new(AtomicBool::new(false));
    let handler_flag = Arc::clone(&interrupted);
    ctrlc::set_handler(move || handler_flag.store(true, Ordering::Release))?;
    let deadline =
        (duration_seconds != 0).then(|| Instant::now() + Duration::from_secs(duration_seconds));
    while !interrupted.load(Ordering::Acquire)
        && deadline.is_none_or(|limit| Instant::now() < limit)
    {
        thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

fn wait_for_announcements(
    monitor: &mdns_sd::Receiver<DaemonEvent>,
    fullnames: &[String],
    timeout: Duration,
) -> Result<(), Box<dyn Error>> {
    let mut pending = fullnames
        .iter()
        .map(|fullname| fullname.to_ascii_lowercase())
        .collect::<BTreeSet<_>>();
    let deadline = Instant::now() + timeout;
    while !pending.is_empty() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!(
                "mDNS announcement timed out for: {}",
                pending.into_iter().collect::<Vec<_>>().join(", ")
            )
            .into());
        }
        match monitor.recv_timeout(remaining) {
            Ok(DaemonEvent::Announce(fullname, _)) => {
                pending.remove(&fullname.to_ascii_lowercase());
            }
            Ok(DaemonEvent::Error(error)) => {
                return Err(format!("mDNS advertiser daemon failed: {error}").into());
            }
            Ok(_) => {}
            Err(error) => {
                return Err(format!(
                    "mDNS announcement channel closed or timed out while waiting for {} service(s): {error}",
                    pending.len()
                )
                .into());
            }
        }
    }
    Ok(())
}

fn service_info(
    service_type: &str,
    instance: &str,
    hostname: &str,
    address: Option<IpAddr>,
    port: u16,
    properties: &[(String, String)],
) -> Result<ServiceInfo, mdns_sd::Error> {
    match address {
        Some(address) => {
            ServiceInfo::new(service_type, instance, hostname, address, port, properties)
        }
        None => ServiceInfo::new(service_type, instance, hostname, (), port, properties)
            .map(ServiceInfo::enable_addr_auto),
    }
}

fn indexed_hostname(base: &str, offset: u16, count: u16) -> Result<String, Box<dyn Error>> {
    if !base.to_ascii_lowercase().ends_with(".local.") || base.len() <= ".local.".len() {
        return Err("hostname must end with .local.".into());
    }
    if count == 1 {
        return Ok(base.to_owned());
    }
    let stem = &base[..base.len() - ".local.".len()];
    Ok(format!("{stem}-{}.local.", offset + 1))
}

fn colon_device_id(canonical: &str) -> String {
    canonical
        .as_bytes()
        .chunks_exact(2)
        .map(|chunk| std::str::from_utf8(chunk).expect("canonical identity is ASCII"))
        .collect::<Vec<_>>()
        .join(":")
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use clap::Parser;
    use winairplay_shared::discovery::DEFAULT_MDNS_PORT;

    use super::{
        Arguments, DNS_FLAG_RESPONSE_AUTHORITATIVE, airplay_properties, colon_device_id,
        fixture_announcement, fixture_goodbye, raop_properties,
    };

    #[test]
    fn mdns_port_defaults_to_the_standard_port() {
        let arguments = Arguments::try_parse_from(["mock-bonjour-advertiser"])
            .expect("default arguments parse");
        assert_eq!(arguments.mdns_port, DEFAULT_MDNS_PORT);
    }

    #[test]
    fn mdns_port_rejects_zero() {
        assert!(
            Arguments::try_parse_from(["mock-bonjour-advertiser", "--mdns-port", "0"]).is_err()
        );
    }

    #[test]
    fn unicast_fixture_encodes_complete_announcement_and_goodbye_responses() {
        const IDENTITY: &str = "02ABCDEF7654";
        let announcement = fixture_announcement(
            IDENTITY,
            "WinAirPlayAudio Integration",
            "winairplay-integration.local.",
            Ipv4Addr::LOCALHOST,
            17_954,
            &raop_properties(false),
            &airplay_properties(&colon_device_id(IDENTITY)),
        )
        .expect("fixture announcement encodes");
        let goodbye = fixture_goodbye(IDENTITY, "WinAirPlayAudio Integration")
            .expect("fixture goodbye encodes");

        assert_eq!(read_u16(&announcement, 2), DNS_FLAG_RESPONSE_AUTHORITATIVE);
        assert_eq!(read_u16(&announcement, 6), 2);
        assert_eq!(read_u16(&announcement, 10), 5);
        assert_eq!(read_u16(&goodbye, 2), DNS_FLAG_RESPONSE_AUTHORITATIVE);
        assert_eq!(read_u16(&goodbye, 6), 2);
        assert_eq!(read_u16(&goodbye, 10), 0);
        assert!(announcement.len() > goodbye.len());
    }

    fn read_u16(packet: &[u8], offset: usize) -> u16 {
        u16::from_be_bytes([packet[offset], packet[offset + 1]])
    }
}
