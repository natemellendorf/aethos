use std::env;
use std::error::Error;
use std::fs;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Deserialize)]
struct VectorFile {
    envelope: Envelope,
}

#[derive(Deserialize)]
struct Envelope {
    to_wayfarer_id: String,
    manifest_id: String,
    body_utf8: String,
    author_pubkey: String,
    author_sig: String,
}

#[derive(Serialize)]
struct Output {
    canonical_cbor_hex: String,
    item_id_hex: String,
    envelope_b64: String,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        return Err("usage: rust_runner encode-envelope <vector-file>".into());
    }
    if args[1] != "encode-envelope" {
        return Err(format!("unsupported command: {}", args[1]).into());
    }

    let raw = fs::read_to_string(&args[2])?;
    let vf: VectorFile = serde_json::from_str(&raw)?;
    validate_envelope(&vf.envelope)?;

    let canonical = encode_canonical_envelope(&vf.envelope)?;

    let mut hasher = Sha256::new();
    hasher.update(&canonical);
    let item_id_hex = format!("{:x}", hasher.finalize());

    let out = Output {
        canonical_cbor_hex: to_hex(&canonical),
        item_id_hex,
        envelope_b64: URL_SAFE_NO_PAD.encode(&canonical),
    };

    println!("{}", serde_json::to_string_pretty(&out)?);
    Ok(())
}

fn validate_envelope(env: &Envelope) -> Result<(), Box<dyn Error>> {
    if env.to_wayfarer_id.len() != 64 || !is_lower_hex(&env.to_wayfarer_id) {
        return Err("envelope.to_wayfarer_id must be 64 lowercase hex chars".into());
    }
    if env.manifest_id.len() != 64 || !is_lower_hex(&env.manifest_id) {
        return Err("envelope.manifest_id must be 64 lowercase hex chars".into());
    }
    if env.author_pubkey.len() != 64 || !is_lower_hex(&env.author_pubkey) {
        return Err("envelope.author_pubkey must be 64 lowercase hex chars".into());
    }
    if env.author_sig.len() != 128 || !is_lower_hex(&env.author_sig) {
        return Err("envelope.author_sig must be 128 lowercase hex chars".into());
    }
    Ok(())
}

fn is_lower_hex(s: &str) -> bool {
    s.chars()
        .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

fn encode_canonical_envelope(env: &Envelope) -> Result<Vec<u8>, Box<dyn Error>> {
    let body = env.body_utf8.as_bytes();
    let manifest_id = decode_hex(&env.manifest_id)?;
    let to_wayfarer_id = decode_hex(&env.to_wayfarer_id)?;
    let author_pubkey = decode_hex(&env.author_pubkey)?;
    let author_sig = decode_hex(&env.author_sig)?;

    let mut out = Vec::new();
    out.push(0xa5);
    append_bytes_pair(&mut out, "body", body)?;
    append_bytes_pair(&mut out, "author_sig", &author_sig)?;
    append_bytes_pair(&mut out, "manifest_id", &manifest_id)?;
    append_bytes_pair(&mut out, "author_pubkey", &author_pubkey)?;
    append_bytes_pair(&mut out, "to_wayfarer_id", &to_wayfarer_id)?;
    Ok(out)
}

fn append_bytes_pair(out: &mut Vec<u8>, key: &str, value: &[u8]) -> Result<(), Box<dyn Error>> {
    out.extend(encode_text(key)?);
    out.extend(encode_bytes(value)?);
    Ok(())
}

fn encode_text(s: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    let b = s.as_bytes();
    let n = b.len();
    let mut out = Vec::new();

    if n < 24 {
        out.push(0x60 | (n as u8));
    } else if n < 256 {
        out.push(0x78);
        out.push(n as u8);
    } else if n < 65536 {
        out.push(0x79);
        out.push(((n >> 8) & 0xff) as u8);
        out.push((n & 0xff) as u8);
    } else {
        return Err("string too long for compatibility runner".into());
    }

    out.extend(b);
    Ok(out)
}

fn encode_bytes(b: &[u8]) -> Result<Vec<u8>, Box<dyn Error>> {
    let n = b.len();
    let mut out = Vec::new();

    if n < 24 {
        out.push(0x40 | (n as u8));
    } else if n < 256 {
        out.push(0x58);
        out.push(n as u8);
    } else if n < 65536 {
        out.push(0x59);
        out.push(((n >> 8) & 0xff) as u8);
        out.push((n & 0xff) as u8);
    } else {
        return Err("byte string too long for compatibility runner".into());
    }

    out.extend(b);
    Ok(out)
}

fn decode_hex(value: &str) -> Result<Vec<u8>, Box<dyn Error>> {
    if value.len() % 2 != 0 {
        return Err("hex value must have even length".into());
    }
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut idx = 0;
    while idx < bytes.len() {
        let high = hex_value(bytes[idx])?;
        let low = hex_value(bytes[idx + 1])?;
        out.push((high << 4) | low);
        idx += 2;
    }
    Ok(out)
}

fn hex_value(b: u8) -> Result<u8, Box<dyn Error>> {
    match b {
        b'0'..=b'9' => Ok(b - b'0'),
        b'a'..=b'f' => Ok(b - b'a' + 10),
        _ => Err("hex value must use lowercase digits".into()),
    }
}

fn to_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(nibble((b >> 4) & 0x0f));
        s.push(nibble(b & 0x0f));
    }
    s
}

fn nibble(v: u8) -> char {
    match v {
        0..=9 => (b'0' + v) as char,
        10..=15 => (b'a' + (v - 10)) as char,
        _ => unreachable!(),
    }
}
