import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option}

pub type CodeStore =
  dict.Dict(String, #(String, String))

pub type Context {
  Context(store: process.Subject(Message), secret: String)
}

pub type ReserveError {
  /// The code exists and the upload did not bring its control key.
  CodeInUse
  /// Another code's deck already sits at that username and file name.
  DeckInUse
}

pub type Message {
  Store(username: String, filename: String, code: String)
  Get(code: String, reply: process.Subject(Option(#(String, String))))
  /// Checks and claims a code and its deck file in one step, so two uploads
  /// cannot both pass the checks while converting. Replies with the code's
  /// previous entry, for Release if the conversion fails.
  Reserve(
    code: String,
    username: String,
    filename: String,
    key_ok: Bool,
    reply: process.Subject(Result(Option(#(String, String)), ReserveError)),
  )
  Release(code: String, previous: Option(#(String, String)))
  /// The code that owns the deck ./view/<username>/<view_filename>.
  Owner(
    username: String,
    view_filename: String,
    reply: process.Subject(Option(String)),
  )
}
