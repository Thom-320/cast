import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option}

pub type CodeStore =
  dict.Dict(String, #(String, String))

/// The store's state: the live codes, and the uploads still converting.
/// A reservation does not touch the live codes, so the old deck keeps its
/// owner (and the projector its key) until the new one is written.
pub type StoreState {
  StoreState(codes: CodeStore, pending: dict.Dict(String, Pending))
}

/// An upload still converting, held by the process doing it: if that
/// process dies (a crash, a kill) the claim goes too. A client that hangs up
/// is only noticed once the conversion returns.
pub type Pending {
  Pending(
    username: String,
    filename: String,
    since: Int,
    holder: process.Pid,
    monitor: process.Monitor,
  )
}

pub type Context {
  Context(store: process.Subject(Message), secret: String)
}

pub type ReserveError {
  /// The code exists and the upload did not bring its control key, or
  /// another upload for that code is still converting.
  CodeInUse
  /// Another code's deck already sits at that username and file name.
  DeckInUse
}

pub type Message {
  /// Commits a reserved code. Only the process holding the reservation can;
  /// the reply says whether it did.
  Store(
    username: String,
    filename: String,
    code: String,
    holder: process.Pid,
    reply: process.Subject(Bool),
  )
  Get(code: String, reply: process.Subject(Option(#(String, String))))
  /// Checks and claims a code and its deck file in one step, so two uploads
  /// cannot both pass the checks while converting. The claim is pending
  /// until Store commits it or Release drops it.
  Reserve(
    code: String,
    username: String,
    filename: String,
    key_ok: Bool,
    holder: process.Pid,
    reply: process.Subject(Result(Nil, ReserveError)),
  )
  Release(code: String, holder: process.Pid)
  /// A process the store was watching ended.
  HolderDown(process.Down)
  /// The code that owns the deck ./view/<username>/<view_filename>.
  Owner(
    username: String,
    view_filename: String,
    reply: process.Subject(Option(String)),
  )
}
