//// Cast codes -> (username, filename).
////
//// Kept in an actor and mirrored to an append-only file, so a restart (deploy,
//// crash, systemd) does not turn every running presentation into
//// "Invalid or expired cast code". The file is replayed in order on start:
//// later lines win.

import envoy
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import types.{type Message, Get, Store}

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
  }
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
