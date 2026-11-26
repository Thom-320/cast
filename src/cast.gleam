import config
import control
import document
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist
import notes
import simplifile
import store
import types
import wisp.{type Request, type Response}
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()

  let store = store.start()

  let secret_key_base = wisp.random_string(64)

  let ctx = types.Context(store:, secret: control.load_secret())
  let handler = fn(req) { routes(req, ctx) }
  let conf = config.get_config()

  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.bind(conf.server_host)
    |> mist.port(conf.server_port)
    |> mist.start

  process.sleep_forever()
}

fn routes(req: Request, ctx: types.Context) -> Response {
  use req <- web_middleware(req)

  // Decode %20 etc. so files with spaces in their names resolve.
  let segments =
    wisp.path_segments(req)
    |> list.map(fn(s) { uri.percent_decode(s) |> result.unwrap(s) })

  case segments {
    ["convert"] -> document.handle_convert(req, ctx)
    [] | ["upload"] -> serve_index()
    ["join"] -> serve_join_page(req, ctx)

    ["view", username, filename] ->
      serve_view_page(req, username, filename, ctx)
    ["view", code] -> serve_view_connection_page(req, code, ctx)
    ["cast", code] -> handle_cast_code(code, ctx)
    ["present", code] -> serve_present(req, code, ctx)
    ["code", code] -> handle_cast_code(code, ctx)
    ["controls", code] -> serve_controls_page(req, code, ctx)
    ["qr", code] -> serve_qr_code(req, code, ctx)
    ["slides", ..rest] -> serve_static_file("./slides/", rest)
    ["assets", ..rest] -> serve_asset(rest)
    _ -> wisp.not_found()
  }
}

fn handle_cast_code(code: String, ctx: types.Context) -> Response {
  case store.get(ctx.store, code) {
    Some(#(username, filename)) -> {
      let redirect_url =
        "/view/" <> username <> "/" <> document.view_filename(filename)
      wisp.redirect(redirect_url)
    }
    None -> wisp.html_response("Invalid or expired cast code", 404)
  }
}

// The deck. Everyone gets it, but the speaker notes and the control key only
// go to the window that brings the deck's key: in ?k= (the presenter's
// projector link) or in the HttpOnly cookie that link leaves for this deck's
// path, so a reload keeps working without the key in the address bar.
//
// Decks are uploaded HTML, so each one runs sandboxed in its own opaque
// origin: its scripts cannot read other decks' pages, storage or cookies.
fn serve_view_page(
  req: Request,
  username: String,
  filename: String,
  ctx: types.Context,
) -> Response {
  use <- wisp.rescue_crashes

  let safe_username = string.replace(username, "..", "")
  let safe_filename = string.replace(filename, "..", "")
  let html_path = "./view/" <> safe_username <> "/" <> safe_filename
  case simplifile.is_file(html_path) {
    Ok(True) -> {
      // The store says which code owns this deck; only its key counts.
      let code = store.owner_of(ctx.store, safe_username, safe_filename)
      let from_query = case code {
        Some(c) -> has_key(req, c, ctx)
        None -> False
      }
      let from_cookie = case code {
        Some(c) ->
          own_navigation(req)
          && control.valid(ctx.secret, c, cookie(req, deck_cookie))
        None -> False
      }
      let res = case code, from_query || from_cookie {
        Some(c), True ->
          case simplifile.read(html_path) {
            Ok(content) -> {
              let key = control.key(ctx.secret, c)
              let tag = "data-cast-code='" <> c <> "'"
              string.replace(
                content,
                tag,
                tag <> " data-cast-key='" <> key <> "'",
              )
              |> wisp.html_response(200)
              // The raw (still percent-encoded) path, as the browser compares it.
              |> set_deck_cookie(req, req.path, key)
            }
            Error(_) -> wisp.internal_server_error()
          }
        // The audience copy, notes already out (made at upload).
        _, _ ->
          case notes.audience_file(safe_username, safe_filename) {
            Ok(path) ->
              wisp.response(200)
              |> wisp.set_header("content-type", "text/html; charset=utf-8")
              |> wisp.set_body(wisp.File(path:, offset: 0, limit: None))
            Error(_) -> wisp.internal_server_error()
          }
      }
      res
      |> private_page
      |> wisp.set_header(
        "content-security-policy",
        "sandbox allow-scripts allow-popups allow-modals allow-presentation allow-downloads; frame-ancestors 'none'",
      )
      // No other page can frame the deck or keep a handle on its window.
      |> wisp.set_header("cross-origin-opener-policy", "same-origin")
    }
    _ -> wisp.html_response("Presentation not found", 404)
  }
}

const deck_cookie = "cast_k"

/// The cookie counts only for navigations the user or our own pages start
/// (typed, reloaded, same-origin). A missing header is an older browser or
/// a script, which cannot send the cookie cross-site anyway.
fn own_navigation(req: Request) -> Bool {
  case request.get_header(req, "sec-fetch-site") {
    Ok("same-origin") | Ok("none") | Error(_) -> True
    _ -> False
  }
}

fn cookie(req: Request, name: String) -> String {
  request.get_cookies(req) |> list.key_find(name) |> result.unwrap("")
}

// Scoped to this one deck's path, invisible to scripts, and Strict: another
// site (or another deck, which runs in an opaque origin) that opens this deck
// in a window does not get it, so it cannot become the room's projector.
fn set_deck_cookie(res: Response, req: Request, path: String, key: String) {
  let secure = case request.get_header(req, "x-forwarded-proto"), req.scheme {
    Ok("https"), _ -> "; Secure"
    _, http.Https -> "; Secure"
    _, _ -> ""
  }
  wisp.set_header(
    res,
    "set-cookie",
    deck_cookie
      <> "="
      <> key
      <> "; Path="
      <> path
      <> "; Max-Age=43200; HttpOnly; SameSite=Strict"
      <> secure,
  )
}

/// The presenter's "Go to Slides": checks the key, leaves it in the deck's
/// HttpOnly cookie and opens the deck as the projector, with no key in the
/// URL. (The deck runs sandboxed and cannot rewrite its own address.)
fn serve_present(req: Request, code: String, ctx: types.Context) -> Response {
  case store.get(ctx.store, code), has_key(req, code, ctx) {
    Some(#(username, filename)), True -> {
      let deck_path =
        "/view/"
        <> uri.percent_encode(username)
        <> "/"
        <> uri.percent_encode(document.view_filename(filename))
      // A same-origin hop instead of a 303: when the link was opened from
      // another site (chat, mail), a redirect stays cross-site and the Strict
      // cookie would not go along.
      let target = html_escape(deck_path <> "?proyector=1")
      wisp.html_response(
        "<!doctype html><meta http-equiv=\"refresh\" content=\"0;url="
          <> target
          <> "\"><a href=\""
          <> target
          <> "\">Open the slides</a>",
        200,
      )
      |> set_deck_cookie(req, deck_path, control.key(ctx.secret, code))
      |> private_page
    }
    Some(_), False -> wisp.redirect("/cast/" <> code)
    None, _ -> wisp.html_response("Invalid or expired cast code", 404)
  }
}

/// Pages that may carry the control key in their URL: never cached, and the
/// URL never leaks to other sites (or our own logs) through Referer.
fn private_page(res: Response) -> Response {
  res
  |> wisp.set_header("referrer-policy", "no-referrer")
  |> wisp.set_header("cache-control", "no-store")
}

/// The control key given in the query (?k=...), or "".
fn query_key(req: Request) -> String {
  list.key_find(wisp.get_query(req), "k") |> result.unwrap("")
}

fn has_key(req: Request, code: String, ctx: types.Context) -> Bool {
  control.valid(ctx.secret, code, query_key(req))
}

// The presenter's page (reached right after uploading): projector link,
// remote link and QR, all carrying the control key. Without the key the
// visitor is audience and just follows the slides.
fn serve_view_connection_page(
  req: Request,
  code: String,
  ctx: types.Context,
) -> Response {
  case store.get(ctx.store, code), has_key(req, code, ctx) {
    Some(_), False -> wisp.redirect("/cast/" <> code)
    Some(#(username, _filename)), True -> {
      use <- wisp.rescue_crashes

      let k = control.key(ctx.secret, code)

      // Construct URLs
      let qr_url = "/qr/" <> code <> "?k=" <> k
      // The window opened from here is the projector: the one the remotes
      // drive and every other screen follows.
      // Through /present: the key never shows in the projector's address bar.
      let presentation_url = "/present/" <> code <> "?k=" <> k
      let controls_url = "/controls/" <> code <> "?k=" <> k
      let replace_url = "/upload?code=" <> code <> "&k=" <> k

      case simplifile.read("./public/view.html") {
        Ok(content) -> {
          let html =
            content
            |> string.replace("{{CAST_CODE}}", code)
            |> string.replace("{{QR_URL}}", qr_url)
            |> string.replace(
              "{{PRESENTATION_URL}}",
              html_escape(presentation_url),
            )
            |> string.replace("{{CONTROLS_URL}}", html_escape(controls_url))
            |> string.replace("{{REPLACE_URL}}", html_escape(replace_url))
            |> string.replace("{{USERNAME}}", html_escape(username))
          wisp.html_response(html, 200) |> private_page
        }
        Error(_) -> wisp.html_response("Connection page not found", 500)
      }
    }
    None, _ -> wisp.redirect("/")
    // Invalid/expired code → redirect to index
  }
}

fn serve_controls_page(
  req: Request,
  code: String,
  ctx: types.Context,
) -> Response {
  case store.get(ctx.store, code), has_key(req, code, ctx) {
    Some(_), False ->
      render_join(
        code,
        "This link cannot steer the slides. The presenter's remote opens from the QR on their own presenter page. With the code you can follow along.",
      )
    Some(#(username, _filename)), True -> {
      use <- wisp.rescue_crashes
      case simplifile.read("./public/controls.html") {
        Ok(content) -> {
          let content_with_code =
            string.replace(content, "{{CAST_CODE}}", code)
            |> string.replace("{{CONTROL_KEY}}", control.key(ctx.secret, code))
            |> string.replace("{{USERNAME}}", html_escape(username))
            |> string.replace("{{WS_URL}}", config.get_config().websocket_url)
          wisp.html_response(content_with_code, 200) |> private_page
        }
        Error(_) -> wisp.html_response("Controls page not found", 404)
      }
    }
    None, _ -> wisp.redirect("/join?code=" <> uri.percent_encode(code))
  }
}

// GET /join shows the code form; GET /join?code=X opens a known code's slides
// on this device (following the projector) and re-shows the form otherwise.
// The code never gives control: that comes with the presenter's QR.
fn serve_join_page(req: Request, ctx: types.Context) -> Response {
  use <- wisp.rescue_crashes

  let code = case list.key_find(wisp.get_query(req), "code") {
    Ok(code) -> string.trim(code)
    Error(_) -> ""
  }
  let known =
    document.is_valid_cast_code(code) && store.get(ctx.store, code) != None

  case known, code {
    True, _ -> wisp.redirect("/cast/" <> code)
    False, "" -> render_join(code, "")
    False, _ -> render_join(code, "No cast is running with that code.")
  }
}

fn render_join(code: String, error: String) -> Response {
  case simplifile.read("./public/join.html") {
    Ok(content) ->
      content
      |> string.replace("{{ERROR}}", html_escape(error))
      |> string.replace("{{CODE}}", html_escape(code))
      |> wisp.html_response(200)
    Error(_) -> wisp.html_response("Join page not found", 500)
  }
}

fn html_escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&#39;")
}

// The QR opens the remote, so it carries the control key and needs it too.
// Made on demand, so codes from before the key get a working QR.
fn serve_qr_code(req: Request, code: String, ctx: types.Context) -> Response {
  use <- wisp.rescue_crashes

  let qr_path = document.control_qr_path(code)
  let ready = case
    document.is_valid_cast_code(code) && has_key(req, code, ctx),
    simplifile.is_file(qr_path)
  {
    False, _ -> False
    True, Ok(True) -> True
    True, _ ->
      document.generate_qr_code(
        document.public_base_url(req),
        code,
        control.key(ctx.secret, code),
      )
      |> result.is_ok
  }
  case ready {
    False -> wisp.html_response("QR code not found", 404)
    True -> serve_qr_file(qr_path) |> private_page
  }
}

fn serve_qr_file(qr_path: String) -> Response {
  case simplifile.read_bits(qr_path) {
    Ok(content) ->
      wisp.response(200)
      |> wisp.set_header("content-type", "image/png")
      |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(content)))
    Error(_) -> wisp.html_response("QR code not found", 404)
  }
}

fn serve_static_file(base_path: String, segments: List(String)) -> Response {
  use <- wisp.rescue_crashes

  let safe_segments = list.map(segments, fn(s) { string.replace(s, "..", "") })
  let file_path = base_path <> string.join(safe_segments, "/")
  case simplifile.read_bits(file_path) {
    Ok(content) -> {
      let content_type = case string.ends_with(file_path, ".png") {
        True -> "image/png"
        False -> "image/jpeg"
      }

      wisp.response(200)
      |> wisp.set_header("content-type", content_type)
      |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(content)))
    }
    Error(_) -> wisp.html_response("File not found", 404)
  }
}

fn serve_asset(segments: List(String)) -> Response {
  use <- wisp.rescue_crashes

  let safe_segments = list.map(segments, fn(s) { string.replace(s, "..", "") })
  let file_path = "./public/assets/" <> string.join(safe_segments, "/")

  case simplifile.read_bits(file_path) {
    Ok(content) -> {
      let content_type = case string.ends_with(file_path, ".css") {
        True -> "text/css"
        False ->
          case string.ends_with(file_path, ".js") {
            True -> "application/javascript"
            False ->
              case string.ends_with(file_path, ".png") {
                True -> "image/png"
                False ->
                  case string.ends_with(file_path, ".jpg") {
                    True -> "image/jpeg"
                    False ->
                      case string.ends_with(file_path, ".woff") {
                        True -> "font/woff"
                        False -> "application/octet-stream"
                      }
                  }
              }
          }
      }

      wisp.response(200)
      |> wisp.set_header("content-type", content_type)
      |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(content)))
    }
    Error(_) -> wisp.html_response("Asset not found", 404)
  }
}

fn serve_index() -> Response {
  use <- wisp.rescue_crashes

  case simplifile.read("./public/index.html") {
    // Opened from "Replace slides" it carries the control key in the URL.
    // Not no-referrer: then the form's POST goes out with Origin: null and
    // the CSRF check refuses the upload. same-origin still keeps the URL
    // from other sites.
    Ok(content) ->
      wisp.html_response(content, 200)
      |> wisp.set_header("referrer-policy", "same-origin")
      |> wisp.set_header("cache-control", "no-store")
    Error(_) -> wisp.html_response("Error loading page", 500)
  }
}

pub fn web_middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)

  handle_request(req)
}
