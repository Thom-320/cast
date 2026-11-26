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
import notes
import simplifile
import types.{
  type Message, type StoreState, CodeInUse, DeckInUse, Get, HolderDown, Owner,
  Pending, Release, Reserve, Store, StoreState,
}

/// A reservation ends with its process (monitored). This is a backstop for
/// a conversion that hangs while its process lives (a stuck LibreOffice).
const pending_seconds = 900

@external(erlang, "store_ffi", "now")
fn now() -> Int

@external(erlang, "store_ffi", "guard")
fn guard(body: fn() -> Result(a, e), on_fail: fn() -> Nil) -> Result(a, e)

pub fn new_state(codes: types.CodeStore) -> StoreState {
  StoreState(codes: codes, pending: dict.new())
}

pub fn codes_file() -> String {
  envoy.get("CODES_FILE") |> result.unwrap("./data/codes.tsv")
}

pub fn start() {
  start_with(new_state(load(codes_file())))
}

/// The actor also hears when a process holding a reservation ends.
pub fn start_with(initial: StoreState) -> process.Subject(Message) {
  let assert Ok(store) =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(HolderDown)
      actor.initialised(initial)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start
  store.data
}

/// Drops code's reservation if holder holds it.
fn drop_held(
  state: StoreState,
  code: String,
  holder: process.Pid,
) -> StoreState {
  case dict.get(state.pending, code) {
    Ok(p) if p.holder == holder -> {
      process.demonitor_process(p.monitor)
      StoreState(..state, pending: dict.delete(state.pending, code))
    }
    _ -> state
  }
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

pub fn handle_message(state: StoreState, msg: Message) {
  case msg {
    Store(username, filename, code, holder, reply) ->
      case dict.get(state.pending, code) {
        // Only the upload that reserved the code (and still holds it).
        Ok(p) if p.holder == holder -> {
          actor.send(reply, True)
          persist(code, username, filename)
          let state = drop_held(state, code, holder)
          remove_replaced(state.codes, code, username, filename)
          actor.continue(
            StoreState(
              ..state,
              codes: dict.insert(state.codes, code, #(username, filename)),
            ),
          )
        }
        _ -> {
          actor.send(reply, False)
          actor.continue(state)
        }
      }
    Get(code, reply) -> {
      actor.send(reply, option.from_result(dict.get(state.codes, code)))
      actor.continue(state)
    }
    Owner(username, view_filename, reply) -> {
      actor.send(reply, owner(state.codes, username, view_filename))
      actor.continue(state)
    }
    Reserve(code, username, filename, key_ok, holder, reply) -> {
      let t = now()
      let #(pending, stale) =
        dict.to_list(state.pending)
        |> list.partition(fn(entry) { t - { entry.1 }.since < pending_seconds })
      list.each(stale, fn(entry) {
        process.demonitor_process({ entry.1 }.monitor)
      })
      let pending = dict.from_list(pending)
      let view = deck.view_filename(filename)
      let deck_pending =
        dict.to_list(pending)
        |> list.any(fn(entry) {
          let #(_, p) = entry
          p.username == username && deck.view_filename(p.filename) == view
        })
      let check = case dict.has_key(pending, code), deck_pending {
        True, _ -> Error(CodeInUse)
        _, True -> Error(DeckInUse)
        _, _ ->
          case dict.has_key(state.codes, code), key_ok {
            True, False -> Error(CodeInUse)
            _, _ ->
              case owner(state.codes, username, view) {
                option.Some(c) if c == code -> Ok(Nil)
                option.Some(_) -> Error(DeckInUse)
                // A file nobody in the store owns (older uploads, or the
                // same name in other letter case on a case-insensitive disk).
                option.None ->
                  case
                    simplifile.is_file(deck.view_dir <> username <> "/" <> view)
                  {
                    Ok(True) -> Error(DeckInUse)
                    _ -> Ok(Nil)
                  }
              }
          }
      }
      actor.send(reply, check)
      actor.continue(case check {
        Ok(_) ->
          StoreState(
            ..state,
            pending: dict.insert(
              pending,
              code,
              Pending(username, filename, t, holder, process.monitor(holder)),
            ),
          )
        Error(_) -> StoreState(..state, pending: pending)
      })
    }
    Release(code, holder) -> actor.continue(drop_held(state, code, holder))
    HolderDown(process.ProcessDown(pid:, ..)) ->
      actor.continue(
        StoreState(
          ..state,
          pending: dict.filter(state.pending, fn(_, p) { p.holder != pid }),
        ),
      )
    HolderDown(_) -> actor.continue(state)
  }
}

/// A code moved to another deck file: the old file (and its audience copy)
/// goes unless another code still points at it. Slide images stay.
fn remove_replaced(
  codes: types.CodeStore,
  code: String,
  username: String,
  filename: String,
) -> Nil {
  case dict.get(codes, code) {
    Ok(#(old_user, old_file)) -> {
      let old_view = deck.view_filename(old_file)
      let moved =
        old_user != username || old_view != deck.view_filename(filename)
      let shared =
        dict.to_list(codes)
        |> list.any(fn(entry) {
          let #(c, #(u, f)) = entry
          c != code && u == old_user && deck.view_filename(f) == old_view
        })
      case moved && !shared {
        True -> {
          let _ =
            simplifile.delete(deck.view_dir <> old_user <> "/" <> old_view)
          notes.delete_audience(old_user, old_view)
        }
        False -> Nil
      }
    }
    Error(_) -> Nil
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
) -> Result(Nil, types.ReserveError) {
  let holder = process.self()
  process.call(store, 2000, Reserve(code, username, filename, key_ok, holder, _))
}

pub fn release(store: process.Subject(Message), code: String) -> Nil {
  actor.send(store, Release(code, process.self()))
}

/// Runs a conversion for a reserved code. If it fails or crashes, the
/// reservation is dropped; if it succeeds, the caller commits with set
/// (from the same process: a reservation belongs to the process that made it).
pub fn while_reserved(
  store: process.Subject(Message),
  code: String,
  body: fn() -> Result(a, e),
) -> Result(a, e) {
  guard(body, fn() { release(store, code) })
}

pub fn get(
  store: process.Subject(Message),
  code: String,
) -> Option(#(String, String)) {
  process.call(store, 1000, Get(code, _))
}

/// Commits this process's reservation. Error if it no longer holds it (the
/// backstop expired and another upload took the code).
pub fn set(
  store: process.Subject(Message),
  username: String,
  filename: String,
  code: String,
) -> Result(Nil, Nil) {
  let holder = process.self()
  case process.call(store, 5000, Store(username, filename, code, holder, _)) {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}
