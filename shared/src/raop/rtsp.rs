use std::collections::BTreeMap;
use std::io::{self, Read, Write};

use super::RaopError;

const HEADER_TERMINATOR: &[u8] = b"\r\n\r\n";

/// Hard bounds applied to every inbound RTSP message.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RtspMessageLimits {
    /// Maximum bytes through the final CRLF of the header block.
    pub max_header_bytes: usize,
    /// Maximum body bytes accepted from `Content-Length`.
    pub max_body_bytes: usize,
}

impl RtspMessageLimits {
    pub(crate) fn validate(self) -> Result<(), RaopError> {
        if self.max_header_bytes < 64 {
            return Err(RaopError::InvalidConfiguration(
                "RTSP max_header_bytes must be at least 64".to_owned(),
            ));
        }
        if self.max_body_bytes > 16 * 1024 * 1024 {
            return Err(RaopError::InvalidConfiguration(
                "RTSP max_body_bytes must not exceed 16 MiB".to_owned(),
            ));
        }
        Ok(())
    }
}

impl Default for RtspMessageLimits {
    fn default() -> Self {
        Self {
            max_header_bytes: 32 * 1024,
            max_body_bytes: 1024 * 1024,
        }
    }
}

/// A bounded RTSP request, primarily used by the mock receiver.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RtspRequest {
    /// RTSP method.
    pub method: String,
    /// Request URI.
    pub uri: String,
    /// Lowercase header-name map.
    pub headers: BTreeMap<String, String>,
    /// Exact request body.
    pub body: Vec<u8>,
}

impl RtspRequest {
    /// Retrieves a header case-insensitively.
    #[must_use]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

/// A bounded RTSP response.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RtspResponse {
    /// Numeric status code.
    pub status: u16,
    /// Reason phrase.
    pub reason: String,
    /// Lowercase header-name map.
    pub headers: BTreeMap<String, String>,
    /// Exact response body.
    pub body: Vec<u8>,
}

impl RtspResponse {
    /// Constructs a response for a mock receiver.
    #[must_use]
    pub fn new(status: u16, reason: impl Into<String>) -> Self {
        Self {
            status,
            reason: reason.into(),
            headers: BTreeMap::new(),
            body: Vec::new(),
        }
    }

    /// Adds or replaces a response header.
    #[must_use]
    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers
            .insert(name.into().to_ascii_lowercase(), value.into());
        self
    }

    /// Retrieves a header case-insensitively.
    #[must_use]
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

/// Reads one bounded RTSP request without consuming bytes from the next message.
pub fn read_rtsp_request<R: Read>(
    reader: &mut R,
    limits: RtspMessageLimits,
) -> io::Result<RtspRequest> {
    let (start_line, headers, body) = read_message(reader, limits)?;
    let mut fields = start_line.split_whitespace();
    let method = fields
        .next()
        .ok_or_else(|| invalid_data("RTSP request method is missing"))?;
    let uri = fields
        .next()
        .ok_or_else(|| invalid_data("RTSP request URI is missing"))?;
    let version = fields
        .next()
        .ok_or_else(|| invalid_data("RTSP request version is missing"))?;
    if fields.next().is_some() || version != "RTSP/1.0" {
        return Err(invalid_data(format!(
            "invalid RTSP request line {start_line:?}"
        )));
    }
    validate_token(method, "request method")?;
    Ok(RtspRequest {
        method: method.to_owned(),
        uri: uri.to_owned(),
        headers,
        body,
    })
}

/// Reads one bounded RTSP response without consuming bytes from the next message.
pub fn read_rtsp_response<R: Read>(
    reader: &mut R,
    limits: RtspMessageLimits,
) -> io::Result<RtspResponse> {
    let (start_line, headers, body) = read_message(reader, limits)?;
    let mut fields = start_line.splitn(3, ' ');
    let version = fields
        .next()
        .ok_or_else(|| invalid_data("RTSP response version is missing"))?;
    let status = fields
        .next()
        .ok_or_else(|| invalid_data("RTSP response status is missing"))?
        .parse::<u16>()
        .map_err(|_| invalid_data("RTSP response status is not numeric"))?;
    let reason = fields.next().unwrap_or("").trim().to_owned();
    if version != "RTSP/1.0" || !(100..=999).contains(&status) {
        return Err(invalid_data(format!(
            "invalid RTSP response line {start_line:?}"
        )));
    }
    Ok(RtspResponse {
        status,
        reason,
        headers,
        body,
    })
}

/// Writes one complete RTSP response for a mock receiver.
pub fn write_rtsp_response<W: Write>(writer: &mut W, response: &RtspResponse) -> io::Result<()> {
    validate_single_line(&response.reason, "response reason")?;
    write!(
        writer,
        "RTSP/1.0 {} {}\r\n",
        response.status, response.reason
    )?;
    for (name, value) in &response.headers {
        validate_header(name, value)?;
        if !name.eq_ignore_ascii_case("content-length") {
            write!(writer, "{name}: {value}\r\n")?;
        }
    }
    write!(writer, "Content-Length: {}\r\n\r\n", response.body.len())?;
    writer.write_all(&response.body)?;
    writer.flush()
}

pub(crate) fn write_rtsp_request<W: Write>(
    writer: &mut W,
    method: &str,
    uri: &str,
    headers: &[(String, String)],
    body: &[u8],
) -> io::Result<()> {
    validate_token(method, "request method")?;
    validate_single_line(uri, "request URI")?;
    write!(writer, "{method} {uri} RTSP/1.0\r\n")?;
    for (name, value) in headers {
        validate_header(name, value)?;
        if !name.eq_ignore_ascii_case("content-length") {
            write!(writer, "{name}: {value}\r\n")?;
        }
    }
    write!(writer, "Content-Length: {}\r\n\r\n", body.len())?;
    writer.write_all(body)?;
    writer.flush()
}

fn read_message<R: Read>(
    reader: &mut R,
    limits: RtspMessageLimits,
) -> io::Result<(String, BTreeMap<String, String>, Vec<u8>)> {
    let header_bytes = read_header_block(reader, limits.max_header_bytes)?;
    let header_text = std::str::from_utf8(&header_bytes[..header_bytes.len() - 4])
        .map_err(|_| invalid_data("RTSP headers are not valid UTF-8"))?;
    let mut lines = header_text.split("\r\n");
    let start_line = lines
        .next()
        .filter(|line| !line.is_empty())
        .ok_or_else(|| invalid_data("RTSP start line is missing"))?
        .to_owned();
    let mut headers = BTreeMap::<String, String>::new();
    for line in lines {
        if line.starts_with([' ', '\t']) {
            return Err(invalid_data("folded RTSP headers are not accepted"));
        }
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| invalid_data(format!("malformed RTSP header {line:?}")))?;
        validate_token(name, "header name")?;
        validate_single_line(value, "header value")?;
        let name = name.to_ascii_lowercase();
        let value = value.trim().to_owned();
        headers
            .entry(name)
            .and_modify(|existing| {
                existing.push_str(", ");
                existing.push_str(&value);
            })
            .or_insert(value);
    }

    let content_length = headers
        .get("content-length")
        .map(|value| {
            value
                .parse::<usize>()
                .map_err(|_| invalid_data("RTSP Content-Length is not a non-negative integer"))
        })
        .transpose()?
        .unwrap_or(0);
    if content_length > limits.max_body_bytes {
        return Err(invalid_data(format!(
            "RTSP body length {content_length} exceeds limit {}",
            limits.max_body_bytes
        )));
    }
    let mut body = vec![0_u8; content_length];
    reader.read_exact(&mut body)?;
    Ok((start_line, headers, body))
}

fn read_header_block<R: Read>(reader: &mut R, max_bytes: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(max_bytes.min(4096));
    let mut next = [0_u8; 1];
    while bytes.len() < max_bytes {
        match reader.read_exact(&mut next) {
            Ok(()) => bytes.push(next[0]),
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof && bytes.is_empty() => {
                return Err(error);
            }
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                return Err(invalid_data("RTSP connection closed inside a header block"));
            }
            Err(error) => return Err(error),
        }
        if bytes.ends_with(HEADER_TERMINATOR) {
            return Ok(bytes);
        }
    }
    Err(invalid_data(format!(
        "RTSP header block exceeds {max_bytes} bytes"
    )))
}

fn validate_header(name: &str, value: &str) -> io::Result<()> {
    validate_token(name, "header name")?;
    validate_single_line(value, "header value")
}

fn validate_token(value: &str, field: &str) -> io::Result<()> {
    if value.is_empty()
        || !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(
                    byte,
                    b'!' | b'#'
                        | b'$'
                        | b'%'
                        | b'&'
                        | b'\''
                        | b'*'
                        | b'+'
                        | b'-'
                        | b'.'
                        | b'^'
                        | b'_'
                        | b'`'
                        | b'|'
                        | b'~'
                )
        })
    {
        return Err(invalid_data(format!("invalid RTSP {field} {value:?}")));
    }
    Ok(())
}

fn validate_single_line(value: &str, field: &str) -> io::Result<()> {
    if value.contains(['\r', '\n']) {
        Err(invalid_data(format!("RTSP {field} contains a newline")))
    } else {
        Ok(())
    }
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn response_parser_is_bounded_and_preserves_following_message() {
        let first = b"RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 3\r\n\r\none";
        let second = b"RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 0\r\n\r\n";
        let mut bytes = Vec::from(*first);
        bytes.extend_from_slice(second);
        let mut cursor = Cursor::new(bytes);
        let response = read_rtsp_response(&mut cursor, RtspMessageLimits::default()).unwrap();
        assert_eq!(response.header("cseq"), Some("1"));
        assert_eq!(response.body, b"one");
        let response = read_rtsp_response(&mut cursor, RtspMessageLimits::default()).unwrap();
        assert_eq!(response.header("CSeq"), Some("2"));
    }

    #[test]
    fn oversized_header_and_body_are_rejected() {
        let mut oversized_header = Cursor::new(vec![b'a'; 64]);
        assert!(
            read_rtsp_response(
                &mut oversized_header,
                RtspMessageLimits {
                    max_header_bytes: 64,
                    max_body_bytes: 10,
                }
            )
            .is_err()
        );

        let mut oversized_body =
            Cursor::new(b"RTSP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n".to_vec());
        assert!(
            read_rtsp_response(
                &mut oversized_body,
                RtspMessageLimits {
                    max_header_bytes: 128,
                    max_body_bytes: 10,
                }
            )
            .is_err()
        );
    }

    #[test]
    fn malformed_or_injected_headers_are_rejected() {
        let mut malformed =
            Cursor::new(b"RTSP/1.0 200 OK\r\n folded: no\r\nContent-Length: 0\r\n\r\n".to_vec());
        assert!(read_rtsp_response(&mut malformed, RtspMessageLimits::default()).is_err());

        let response = RtspResponse::new(200, "OK").with_header("CSeq", "1\r\nInjected: yes");
        assert!(write_rtsp_response(&mut Vec::new(), &response).is_err());
    }

    #[test]
    fn request_parser_reads_body_and_normalizes_headers() {
        let mut request = Cursor::new(
            b"ANNOUNCE rtsp://127.0.0.1/1 RTSP/1.0\r\nCSeq: 4\r\nContent-Length: 3\r\n\r\nsdp"
                .to_vec(),
        );
        let parsed = read_rtsp_request(&mut request, RtspMessageLimits::default()).unwrap();
        assert_eq!(parsed.method, "ANNOUNCE");
        assert_eq!(parsed.header("CSEQ"), Some("4"));
        assert_eq!(parsed.body, b"sdp");
    }
}
