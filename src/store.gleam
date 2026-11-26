//// Cast codes -> (username, filename).
////
//// Kept in an actor and mirrored to an append-only file, so a restart (deploy,
//// crash, systemd) does not turn every running presentation into
//// "Invalid or expired cast code". The file is replayed in order on start:
//// later lines win.

import deck
import envoy
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import types.{
  type Message, CodeInUse, DeckInUse, Get, Owner, Release, Reserve, Store,
}

pub fn codes_file() -> String {
  envoy.get("CODES_FILE") |> result.unwrap("./data/codes.tsv")
}

pub fn start() {
  let initial = load(codes_file())
  let assert Ok(store) =
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  store.data
}

/// Reads the codes file; missing or malformed lines are skipped.
pub fn load(path: String) -> types.CodeStore {
  case simplifile.read(path) {
    Error(_) -> dict.new()
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.fold(dict.new(), fn(acc, line) {
        case string.split(line, "\t") {
          [code, username, filename] if code != "" ->
            dict.insert(acc, code, #(username, filename))
          _ -> acc
        }
      })
  }
}

fn persist(code: String, username: String, filename: String) -> Nil {
  let path = codes_file()
  let clean = fn(s) {
    s |> string.replace("\t", " ") |> string.replace("\n", " ")
  }
  let dir = case string.split(path, "/") |> list.reverse {
    [_, ..rest] if rest != [] -> string.join(list.reverse(rest), "/")
    _ -> "."
  }
  let _ = simplifile.create_directory_all(dir)
  let _ =
    simplifile.append(
      path,
      clean(code) <> "\t" <> clean(username) <> "\t" <> clean(filename) <> "\n",
    )
  Nil
}

pub fn handle_message(state: types.CodeStore, msg: Message) {
  case msg {
    Store(username, filename, code) -> {
      persist(code, username, filename)
      actor.continue(dict.insert(state, code, #(username, filename)))
    }
    Get(code, reply) -> {
      actor.send(reply, option.from_result(dict.get(state, code)))
      actor.continue(state)
    }
    Owner(username, view_filename, reply) -> {
      actor.send(reply, owner(state, username, view_filename))
      actor.continue(state)
    }
    Reserve(code, username, filename, key_ok, reply) -> {
      let previous = dict.get(state, code)
      let view = deck.view_filename(filename)
      let check = case previous, key_ok {
        Ok(_), False -> Error(CodeInUse)
        _, _ ->
          case owner(state, username, view) {
            option.Some(c) if c == code -> Ok(Nil)
            option.Some(_) -> Error(DeckInUse)
            // A file nobody in the store owns (older uploads, or the same
            // name in other letter case on a case-insensitive disk).
            option.None ->
              case
                simplifile.is_file(deck.view_dir <> username <> "/" <> view)
              {
                Ok(True) -> Error(DeckInUse)
                _ -> Ok(Nil)
              }
          }
      }
      case check {
        Error(e) -> {
          actor.send(reply, Error(e))
          actor.continue(state)
        }
        Ok(_) -> {
          actor.send(reply, Ok(option.from_result(previous)))
          actor.continue(dict.insert(state, code, #(username, filename)))
        }
      }
    }
    Release(code, previous) ->
      actor.continue(case previous {
        option.Some(entry) -> dict.insert(state, code, entry)
        option.None -> dict.delete(state, code)
      })
  }
}

/// The code whose entry points at ./view/<username>/<view_filename>. Older
/// versions let several codes point at one file; then the file's own tag
/// picks among them, and nobody owns it if that does not settle it.
pub fn owner(
  state: types.CodeStore,
  username: String,
  view_filename: String,
) -> Option(String) {
  let codes =
    dict.fold(state, [], fn(acc, code, entry) {
      let #(u, f) = entry
      case u == username && deck.view_filename(f) == view_filename {
        True -> [code, ..acc]
        False -> acc
      }
    })
  case codes {
    [] -> option.None
    [code] -> option.Some(code)
    _ -> {
      let tagged =
        simplifile.read(deck.view_dir <> username <> "/" <> view_filename)
        |> result.replace_error(Nil)
        |> result.try(deck.code_in)
      case tagged {
        Ok(code) ->
          case list.contains(codes, code) {
            True -> option.Some(code)
            False -> option.None
          }
        Error(_) -> option.None
      }
    }
  }
}

pub fn owner_of(
  store: process.Subject(Message),
  username: String,
  view_filename: String,
) -> Option(String) {
  process.call(store, 1000, Owner(username, view_filename, _))
}

pub fn reserve(
  store: process.Subject(Message),
  code: String,
  username: String,
  filename: String,
  key_ok: Bool,
) -> Result(Option(#(String, String)), types.ReserveError) {
  process.call(store, 2000, Reserve(code, username, filename, key_ok, _))
}

pub fn release(
  store: process.Subject(Message),
  code: String,
  previous: Option(#(String, String)),
) -> Nil {
  actor.send(store, Release(code, previous))
}

pub fn get(
  store: process.Subject(Message),
  code: String,
) -> Option(#(String, String)) {
  process.call(store, 1000, Get(code, _))
}

pub fn set(
  store: process.Subject(Message),
  username: String,
  filename: String,
  code: String,
) -> Nil {
  actor.send(store, Store(username, filename, code))
}
