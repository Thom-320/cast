import envoy
import gleam/int
import gleam/result
import gleam/string

pub type Config {
  Config(
    server_host: String,
    server_port: Int,
    /// Where browsers open the relay. Empty means "same origin, /ws/", which
    /// works behind the bundled relay (it proxies HTTP to this server) or any
    /// reverse proxy that forwards /ws/ to the relay.
    websocket_url: String,
    /// Public base URL used in QR codes (e.g. https://cast.example.com).
    /// Empty means "derive it from the upload request".
    public_url: String,
  )
}

pub fn get_config() -> Config {
  Config(
    server_host: env("SERVER_HOST", "0.0.0.0"),
    server_port: env("SERVER_PORT", "6767")
      |> int.parse
      |> result.unwrap(6767),
    websocket_url: env("WEBSOCKET_URL", ""),
    public_url: env("PUBLIC_URL", "") |> trim_slash,
  )
}

fn env(name: String, default: String) -> String {
  case envoy.get(name) {
    Ok(value) ->
      case string.trim(value) {
        "" -> default
        v -> v
      }
    Error(_) -> default
  }
}

fn trim_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }
}
