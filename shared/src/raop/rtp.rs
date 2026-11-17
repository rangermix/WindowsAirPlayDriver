use std::collections::VecDeque;

use super::RaopError;

const RTP_HEADER_BYTES: usize = 12;
const RETRANSMISSION_REQUEST_BYTES: usize = 8;

/// A newly packetized RTP datagram and the state used to construct it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PacketizedRtp {
    /// RTP sequence number.
    pub sequence: u16,
    /// RTP timestamp of the first frame.
    pub timestamp: u32,
    /// Number of audio frames in the payload.
    pub frames: usize,
    /// Complete RTP datagram.
    pub bytes: Vec<u8>,
}

/// Parsed view of a linear-PCM RTP datagram.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RtpPacketView<'a> {
    /// RTP marker bit.
    pub marker: bool,
    /// Seven-bit RTP payload type.
    pub payload_type: u8,
    /// RTP sequence number.
    pub sequence: u16,
    /// RTP timestamp.
    pub timestamp: u32,
    /// RTP synchronization source.
    pub ssrc: u32,
    /// Raw payload bytes.
    pub payload: &'a [u8],
}

/// Deterministic RTP sequence, timestamp, and L16 payload packetizer.
#[derive(Clone, Debug)]
pub struct RtpPacketizer {
    next_sequence: u16,
    next_timestamp: u32,
    ssrc: u32,
    first_packet: bool,
}

impl RtpPacketizer {
    /// Creates a packetizer with explicit initial counters.
    #[must_use]
    pub const fn new(initial_sequence: u16, initial_timestamp: u32, ssrc: u32) -> Self {
        Self {
            next_sequence: initial_sequence,
            next_timestamp: initial_timestamp,
            ssrc,
            first_packet: true,
        }
    }

    /// Packetizes interleaved stereo signed 16-bit PCM as network-order L16.
    pub fn packetize_stereo_i16(&mut self, samples: &[i16]) -> Result<PacketizedRtp, RaopError> {
        if !samples.len().is_multiple_of(2) {
            return Err(RaopError::IncompleteAudioFrame {
                sample_count: samples.len(),
            });
        }
        let frames = samples.len() / 2;
        let sequence = self.next_sequence;
        let timestamp = self.next_timestamp;
        let mut bytes = Vec::with_capacity(RTP_HEADER_BYTES + samples.len() * 2);
        bytes.push(0x80);
        bytes.push(if self.first_packet { 0xE0 } else { 0x60 });
        bytes.extend_from_slice(&sequence.to_be_bytes());
        bytes.extend_from_slice(&timestamp.to_be_bytes());
        bytes.extend_from_slice(&self.ssrc.to_be_bytes());
        for sample in samples {
            bytes.extend_from_slice(&sample.to_be_bytes());
        }

        self.next_sequence = self.next_sequence.wrapping_add(1);
        self.next_timestamp = self
            .next_timestamp
            .wrapping_add(u32::try_from(frames).map_err(|_| {
                RaopError::InvalidConfiguration("RTP packet frame count exceeds u32".to_owned())
            })?);
        self.first_packet = false;
        Ok(PacketizedRtp {
            sequence,
            timestamp,
            frames,
            bytes,
        })
    }

    /// Returns the sequence number assigned to the next packet.
    #[must_use]
    pub const fn next_sequence(&self) -> u16 {
        self.next_sequence
    }

    /// Returns the timestamp assigned to the next packet.
    #[must_use]
    pub const fn next_timestamp(&self) -> u32 {
        self.next_timestamp
    }

    /// Marks the next audio packet, for example after a remote flush.
    pub fn mark_next_packet(&mut self) {
        self.first_packet = true;
    }
}

/// Parses the fixed RTP header used by the MVP sender.
pub fn parse_rtp_packet(packet: &[u8]) -> Result<RtpPacketView<'_>, RaopError> {
    if packet.len() < RTP_HEADER_BYTES {
        return Err(RaopError::InvalidRtp(format!(
            "RTP datagram is {} bytes; expected at least {RTP_HEADER_BYTES}",
            packet.len()
        )));
    }
    if packet[0] >> 6 != 2 {
        return Err(RaopError::InvalidRtp(format!(
            "RTP version {} is unsupported",
            packet[0] >> 6
        )));
    }
    if packet[0] & 0x3F != 0 {
        return Err(RaopError::InvalidRtp(
            "RTP CSRC, extension, and padding fields are unsupported in the MVP".to_owned(),
        ));
    }
    Ok(RtpPacketView {
        marker: packet[1] & 0x80 != 0,
        payload_type: packet[1] & 0x7F,
        sequence: u16::from_be_bytes([packet[2], packet[3]]),
        timestamp: u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]),
        ssrc: u32::from_be_bytes([packet[8], packet[9], packet[10], packet[11]]),
        payload: &packet[RTP_HEADER_BYTES..],
    })
}

/// Receiver request for one or more missing RTP sequence numbers.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetransmissionRequest {
    /// Receiver's request sequence number.
    pub request_sequence: u16,
    /// First missing audio sequence number.
    pub first_missing_sequence: u16,
    /// Number of consecutive missing packets.
    pub packet_count: u16,
}

impl RetransmissionRequest {
    /// Parses the eight-byte RAOP retransmission request.
    pub fn parse(packet: &[u8]) -> Result<Self, RaopError> {
        if packet.len() != RETRANSMISSION_REQUEST_BYTES {
            return Err(RaopError::InvalidTransport(format!(
                "retransmission request is {} bytes; expected {RETRANSMISSION_REQUEST_BYTES}",
                packet.len()
            )));
        }
        if packet[0] >> 6 != 2 || packet[1] & 0x7F != 0x55 {
            return Err(RaopError::InvalidTransport(
                "control datagram is not an RAOP retransmission request".to_owned(),
            ));
        }
        let packet_count = u16::from_be_bytes([packet[6], packet[7]]);
        if packet_count == 0 {
            return Err(RaopError::InvalidTransport(
                "retransmission request packet count is zero".to_owned(),
            ));
        }
        Ok(Self {
            request_sequence: u16::from_be_bytes([packet[2], packet[3]]),
            first_missing_sequence: u16::from_be_bytes([packet[4], packet[5]]),
            packet_count,
        })
    }
}

/// Wraps an original RTP datagram in a RAOP retransmission response.
#[must_use]
pub fn build_retransmission_reply(original: &PacketizedRtp) -> Vec<u8> {
    let mut response = Vec::with_capacity(4 + original.bytes.len());
    response.extend_from_slice(&[0x80, 0xD6]);
    response.extend_from_slice(&original.sequence.to_be_bytes());
    response.extend_from_slice(&original.bytes);
    response
}

#[derive(Debug)]
pub(crate) struct PacketBacklog {
    capacity: usize,
    packets: VecDeque<PacketizedRtp>,
}

impl PacketBacklog {
    pub(crate) fn new(capacity: usize) -> Self {
        Self {
            capacity,
            packets: VecDeque::with_capacity(capacity),
        }
    }

    pub(crate) fn insert(&mut self, packet: PacketizedRtp) {
        if self.packets.len() == self.capacity {
            self.packets.pop_front();
        }
        self.packets.push_back(packet);
    }

    pub(crate) fn get(&self, sequence: u16) -> Option<&PacketizedRtp> {
        self.packets
            .iter()
            .rev()
            .find(|packet| packet.sequence == sequence)
    }

    pub(crate) fn clear(&mut self) {
        self.packets.clear();
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.packets.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequence_and_timestamp_wrap_without_panicking() {
        let mut packetizer = RtpPacketizer::new(u16::MAX, u32::MAX - 1, 0x0102_0304);
        let first = packetizer.packetize_stereo_i16(&[1, -1, 2, -2]).unwrap();
        let second = packetizer.packetize_stereo_i16(&[3, -3]).unwrap();
        assert_eq!(first.sequence, u16::MAX);
        assert_eq!(first.timestamp, u32::MAX - 1);
        assert_eq!(second.sequence, 0);
        assert_eq!(second.timestamp, 0);
        assert_eq!(packetizer.next_sequence(), 1);
        assert_eq!(packetizer.next_timestamp(), 1);
    }

    #[test]
    fn l16_payload_is_big_endian_and_parseable() {
        let mut packetizer = RtpPacketizer::new(9, 100, 7);
        let packet = packetizer.packetize_stereo_i16(&[0x1234, -0x1234]).unwrap();
        let parsed = parse_rtp_packet(&packet.bytes).unwrap();
        assert!(parsed.marker);
        assert_eq!(parsed.payload_type, 96);
        assert_eq!(parsed.sequence, 9);
        assert_eq!(parsed.timestamp, 100);
        assert_eq!(parsed.ssrc, 7);
        assert_eq!(parsed.payload, &[0x12, 0x34, 0xED, 0xCC]);

        packetizer.mark_next_packet();
        let after_flush = packetizer.packetize_stereo_i16(&[0, 0]).unwrap();
        assert!(parse_rtp_packet(&after_flush.bytes).unwrap().marker);
    }

    #[test]
    fn retransmission_request_and_reply_round_trip() {
        let request = RetransmissionRequest::parse(&[0x80, 0x55, 0, 7, 0xFF, 0xFE, 0, 2]).unwrap();
        assert_eq!(request.request_sequence, 7);
        assert_eq!(request.first_missing_sequence, 0xFFFE);
        assert_eq!(request.packet_count, 2);

        let mut packetizer = RtpPacketizer::new(0xFFFE, 0, 1);
        let packet = packetizer.packetize_stereo_i16(&[0, 0]).unwrap();
        let reply = build_retransmission_reply(&packet);
        assert_eq!(&reply[..4], &[0x80, 0xD6, 0xFF, 0xFE]);
        assert_eq!(&reply[4..], packet.bytes);
    }

    #[test]
    fn packet_backlog_is_bounded() {
        let mut backlog = PacketBacklog::new(2);
        let mut packetizer = RtpPacketizer::new(1, 1, 1);
        for _ in 0..3 {
            backlog.insert(packetizer.packetize_stereo_i16(&[0, 0]).unwrap());
        }
        assert_eq!(backlog.len(), 2);
        assert!(backlog.get(1).is_none());
        assert!(backlog.get(2).is_some());
        assert!(backlog.get(3).is_some());
    }
}
