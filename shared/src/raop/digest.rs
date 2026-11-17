use std::fmt;

use getrandom::getrandom;
use md5::{Digest, Md5};
use zeroize::Zeroize;

use super::RaopError;

/// Parsed HTTP Digest authentication challenge.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DigestChallenge {
    /// Authentication realm.
    pub realm: String,
    /// Server nonce.
    pub nonce: String,
    /// Optional opaque value.
    pub opaque: Option<String>,
    /// Selected quality-of-protection token.
    pub qop: Option<String>,
}

impl DigestChallenge {
    pub(crate) fn parse(header: &str) -> Result<Self, RaopError> {
        let Some((scheme, parameters)) = header.trim().split_once(char::is_whitespace) else {
            return Err(RaopError::UnsupportedAuthentication(header.to_owned()));
        };
        if !scheme.eq_ignore_ascii_case("digest") {
            return Err(RaopError::UnsupportedAuthentication(scheme.to_owned()));
        }

        let mut realm = None;
        let mut nonce = None;
        let mut opaque = None;
        let mut qop = None;
        let mut algorithm = None;
        for parameter in split_parameters(parameters)? {
            let Some((name, raw_value)) = parameter.split_once('=') else {
                return Err(RaopError::UnsupportedAuthentication(format!(
                    "malformed Digest parameter {parameter:?}"
                )));
            };
            let value = unquote(raw_value.trim())?;
            match name.trim().to_ascii_lowercase().as_str() {
                "realm" => realm = Some(value),
                "nonce" => nonce = Some(value),
                "opaque" => opaque = Some(value),
                "algorithm" => algorithm = Some(value),
                "qop" => {
                    let supports_auth = value
                        .split(',')
                        .any(|candidate| candidate.trim().eq_ignore_ascii_case("auth"));
                    if supports_auth {
                        qop = Some("auth".to_owned());
                    } else {
                        return Err(RaopError::UnsupportedAuthentication(format!(
                            "Digest qop {value:?}; only auth or omitted qop is supported"
                        )));
                    }
                }
                _ => {}
            }
        }
        if algorithm
            .as_deref()
            .is_some_and(|value| !value.eq_ignore_ascii_case("md5"))
        {
            return Err(RaopError::UnsupportedAuthentication(format!(
                "Digest algorithm {}",
                algorithm.expect("checked")
            )));
        }
        Ok(Self {
            realm: realm.ok_or_else(|| {
                RaopError::UnsupportedAuthentication("Digest realm is missing".to_owned())
            })?,
            nonce: nonce.ok_or_else(|| {
                RaopError::UnsupportedAuthentication("Digest nonce is missing".to_owned())
            })?,
            opaque,
            qop,
        })
    }
}

pub(crate) struct DigestAuthenticator {
    challenge: DigestChallenge,
    username: String,
    password: String,
    nonce_count: u32,
    cnonce: String,
}

impl fmt::Debug for DigestAuthenticator {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DigestAuthenticator")
            .field("challenge", &self.challenge)
            .field("username", &self.username)
            .field("password", &"<redacted>")
            .field("nonce_count", &self.nonce_count)
            .field("cnonce", &"<redacted>")
            .finish()
    }
}

impl Drop for DigestAuthenticator {
    fn drop(&mut self) {
        self.password.zeroize();
        self.cnonce.zeroize();
    }
}

impl DigestAuthenticator {
    pub(crate) fn new(
        challenge: DigestChallenge,
        username: String,
        password: String,
    ) -> Result<Self, RaopError> {
        let mut random = [0_u8; 16];
        getrandom(&mut random).map_err(|error| RaopError::Entropy(error.to_string()))?;
        Ok(Self {
            challenge,
            username,
            password,
            nonce_count: 0,
            cnonce: hex::encode(random),
        })
    }

    pub(crate) fn authorization(&mut self, method: &str, uri: &str) -> String {
        self.nonce_count = self.nonce_count.wrapping_add(1).max(1);
        build_authorization(
            &self.challenge,
            &self.username,
            &self.password,
            method,
            uri,
            self.nonce_count,
            &self.cnonce,
        )
    }
}

/// Verifies a Digest Authorization header for a mock receiver.
///
/// This parser accepts only fields emitted by this sender and is intentionally
/// separate from the bounded RTSP message parser.
pub fn verify_digest_authorization(
    authorization: &str,
    challenge: &DigestChallenge,
    password: &str,
    method: &str,
    uri: &str,
) -> bool {
    let Some((scheme, parameters)) = authorization.trim().split_once(char::is_whitespace) else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("digest") {
        return false;
    }
    let Ok(parameters) = split_parameters(parameters) else {
        return false;
    };
    let mut username = None;
    let mut response = None;
    let mut nonce_count = None;
    let mut cnonce = None;
    let mut supplied_uri = None;
    for parameter in parameters {
        let Some((name, value)) = parameter.split_once('=') else {
            return false;
        };
        let Ok(value) = unquote(value.trim()) else {
            return false;
        };
        match name.trim().to_ascii_lowercase().as_str() {
            "username" => username = Some(value),
            "response" => response = Some(value),
            "nc" => nonce_count = u32::from_str_radix(&value, 16).ok(),
            "cnonce" => cnonce = Some(value),
            "uri" => supplied_uri = Some(value),
            _ => {}
        }
    }
    let (Some(username), Some(response), Some(supplied_uri)) = (username, response, supplied_uri)
    else {
        return false;
    };
    if supplied_uri != uri {
        return false;
    }
    let expected = build_authorization(
        challenge,
        &username,
        password,
        method,
        uri,
        nonce_count.unwrap_or(1),
        cnonce.as_deref().unwrap_or(""),
    );
    extract_digest_field(&expected, "response").is_some_and(|value| value == response)
}

fn build_authorization(
    challenge: &DigestChallenge,
    username: &str,
    password: &str,
    method: &str,
    uri: &str,
    nonce_count: u32,
    cnonce: &str,
) -> String {
    let ha1 = md5_hex(format!("{username}:{}:{password}", challenge.realm).as_bytes());
    let ha2 = md5_hex(format!("{method}:{uri}").as_bytes());
    let response = if let Some(qop) = challenge.qop.as_deref() {
        md5_hex(
            format!(
                "{ha1}:{}:{nonce_count:08x}:{cnonce}:{qop}:{ha2}",
                challenge.nonce
            )
            .as_bytes(),
        )
    } else {
        md5_hex(format!("{ha1}:{}:{ha2}", challenge.nonce).as_bytes())
    };

    let mut fields = vec![
        format!("username=\"{}\"", escape_quoted(username)),
        format!("realm=\"{}\"", escape_quoted(&challenge.realm)),
        format!("nonce=\"{}\"", escape_quoted(&challenge.nonce)),
        format!("uri=\"{}\"", escape_quoted(uri)),
        "algorithm=MD5".to_owned(),
        format!("response=\"{response}\""),
    ];
    if let Some(opaque) = challenge.opaque.as_deref() {
        fields.push(format!("opaque=\"{}\"", escape_quoted(opaque)));
    }
    if let Some(qop) = challenge.qop.as_deref() {
        fields.push(format!("qop={qop}"));
        fields.push(format!("nc={nonce_count:08x}"));
        fields.push(format!("cnonce=\"{}\"", escape_quoted(cnonce)));
    }
    format!("Digest {}", fields.join(", "))
}

fn md5_hex(bytes: &[u8]) -> String {
    let mut hasher = Md5::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn split_parameters(input: &str) -> Result<Vec<String>, RaopError> {
    let mut parameters = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut escaped = false;
    for character in input.chars() {
        if escaped {
            current.push(character);
            escaped = false;
            continue;
        }
        match character {
            '\\' if quoted => {
                current.push(character);
                escaped = true;
            }
            '"' => {
                quoted = !quoted;
                current.push(character);
            }
            ',' if !quoted => {
                if !current.trim().is_empty() {
                    parameters.push(current.trim().to_owned());
                }
                current.clear();
            }
            _ => current.push(character),
        }
    }
    if quoted || escaped {
        return Err(RaopError::UnsupportedAuthentication(
            "unterminated quoted Digest parameter".to_owned(),
        ));
    }
    if !current.trim().is_empty() {
        parameters.push(current.trim().to_owned());
    }
    Ok(parameters)
}

fn unquote(value: &str) -> Result<String, RaopError> {
    if !value.starts_with('"') {
        return Ok(value.to_owned());
    }
    if !value.ends_with('"') || value.len() < 2 {
        return Err(RaopError::UnsupportedAuthentication(
            "unterminated quoted Digest value".to_owned(),
        ));
    }
    let mut output = String::new();
    let mut escaped = false;
    for character in value[1..value.len() - 1].chars() {
        if escaped {
            output.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else {
            output.push(character);
        }
    }
    if escaped {
        return Err(RaopError::UnsupportedAuthentication(
            "unterminated Digest escape".to_owned(),
        ));
    }
    Ok(output)
}

fn escape_quoted(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn extract_digest_field(header: &str, field: &str) -> Option<String> {
    let (_, parameters) = header.split_once(char::is_whitespace)?;
    split_parameters(parameters)
        .ok()?
        .into_iter()
        .find_map(|parameter| {
            let (name, value) = parameter.split_once('=')?;
            name.trim()
                .eq_ignore_ascii_case(field)
                .then(|| unquote(value.trim()).ok())
                .flatten()
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digest_matches_rfc_2617_example() {
        let challenge = DigestChallenge {
            realm: "testrealm@host.com".to_owned(),
            nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093".to_owned(),
            opaque: Some("5ccc069c403ebaf9f0171e9517f40e41".to_owned()),
            qop: Some("auth".to_owned()),
        };
        let header = build_authorization(
            &challenge,
            "Mufasa",
            "Circle Of Life",
            "GET",
            "/dir/index.html",
            1,
            "0a4f113b",
        );
        assert_eq!(
            extract_digest_field(&header, "response").as_deref(),
            Some("6629fae49393a05397450978507c4ef1")
        );
        assert!(verify_digest_authorization(
            &header,
            &challenge,
            "Circle Of Life",
            "GET",
            "/dir/index.html"
        ));
    }

    #[test]
    fn challenge_parser_handles_quoted_comma_and_rejects_auth_int() {
        let parsed = DigestChallenge::parse(
            "Digest realm=\"room, speaker\", nonce=\"abc\", qop=\"auth,auth-int\"",
        )
        .unwrap();
        assert_eq!(parsed.realm, "room, speaker");
        assert_eq!(parsed.qop.as_deref(), Some("auth"));

        assert!(matches!(
            DigestChallenge::parse("Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\""),
            Err(RaopError::UnsupportedAuthentication(_))
        ));
    }
}
