//// Control key: who may steer a cast.
////
//// The cast code is public (it is in every audience page and on the screen),
//// so it only lets a screen follow along. Steering the room, reading the
//// speaker notes or acting as the projector needs the control key, which only
//// goes into the presenter's links and QR code.
////
//// key = first 22 chars of base64url(HMAC-SHA256(secret, "cast-control:" <> code))
////
//// The relay (websocket_relay.js) derives the same key from the same secret,
//// so nothing else has to be stored or shared per code.

import envoy
import gleam/bit_array
import gleam/crypto
import gleam/result
import gleam/string
import simplifile

pub fn secret_file() -> String {
  envoy.get("CAST_SECRET_FILE") |> result.unwrap("./data/cast-secret")
}

/// CAST_SECRET if set; else the secret file, created (mode 600) on first start.
pub fn load_secret() -> String {
  case envoy.get("CAST_SECRET") |> result.map(string.trim) {
    Ok(secret) if secret != "" -> secret
    _ -> load_or_create(secret_file())
  }
}

// Created only when missing. An existing file that cannot be read, or is
// empty, stops the server: silently replacing it would invalidate every
// presenter's key and split Gleam from the relay.
fn load_or_create(path: String) -> String {
  case simplifile.is_file(path) {
    Ok(True) -> {
      let assert Ok(secret) = simplifile.read(path) |> result.map(string.trim)
        as "cannot read the cast secret file"
      let assert True = secret != "" as "the cast secret file is empty"
      let _ = simplifile.set_permissions_octal(path, 0o600)
      secret
    }
    _ -> {
      let secret =
        crypto.strong_random_bytes(32) |> bit_array.base64_url_encode(False)
      let _ = simplifile.create_directory_all(parent(path))
      let _ = simplifile.create_file(path)
      let _ = simplifile.set_permissions_octal(path, 0o600)
      let assert Ok(_) = simplifile.write(path, secret <> "\n")
      secret
    }
  }
}

fn parent(path: String) -> String {
  case string.split(path, "/") {
    [_] -> "."
    parts ->
      parts
      |> drop_last
      |> string.join("/")
  }
}

fn drop_last(parts: List(String)) -> List(String) {
  case parts {
    [] | [_] -> []
    [first, ..rest] -> [first, ..drop_last(rest)]
  }
}

pub fn key(secret: String, code: String) -> String {
  crypto.hmac(
    bit_array.from_string("cast-control:" <> code),
    crypto.Sha256,
    bit_array.from_string(secret),
  )
  |> bit_array.base64_url_encode(False)
  |> string.slice(0, 22)
}

pub fn valid(secret: String, code: String, given: String) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(key(secret, code)),
    bit_array.from_string(given),
  )
}
