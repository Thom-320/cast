//// The audience copy of a deck: its HTML without the speaker notes, made
//// once (at upload, or on the first visit for older decks) and kept on disk
//// apart from the deck, so a page load only streams a file. The
//// presenter's keyed windows get the untouched deck.

import deck
import gleam/int
import gleam/result
import simplifile

@external(erlang, "notes_ffi", "strip")
pub fn strip(html: String) -> String

/// Drops cast-remote script tags (and keys) already in an uploaded page: a
/// saved projector page must not bring an old code or its key along.
@external(erlang, "notes_ffi", "unremote")
pub fn unremote(html: String) -> String

pub const audience_dir: String = "./audience/"

/// Bumped whenever strip changes, so copies made by an older (possibly
/// leakier) stripper are never served: they sit in another folder.
const stripper_version = "v2"

fn user_dir(username: String) -> String {
  audience_dir <> stripper_version <> "/" <> username
}

pub fn audience_path(username: String, view_filename: String) -> String {
  user_dir(username) <> "/" <> view_filename
}

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

/// Writes the audience copy of ./view/<username>/<view_filename>.
pub fn write_audience(
  username: String,
  view_filename: String,
) -> Result(Nil, Nil) {
  use html <- result.try(
    simplifile.read(deck.view_dir <> username <> "/" <> view_filename)
    |> result.replace_error(Nil),
  )
  use _ <- result.try(
    simplifile.create_directory_all(user_dir(username))
    |> result.replace_error(Nil),
  )
  let path = audience_path(username, view_filename)
  // Written beside and renamed: a reader never sees half a file. Each
  // writer has its own temporary name (a room loading at once).
  let tmp = path <> ".tmp" <> int.to_string(unique())
  let written =
    simplifile.write(tmp, strip(html))
    |> result.try(fn(_) { simplifile.rename(tmp, path) })
  case written {
    Ok(_) -> Ok(Nil)
    Error(_) -> {
      let _ = simplifile.delete(tmp)
      Error(Nil)
    }
  }
}

/// The audience copy's path, made now if missing or older than the deck.
pub fn audience_file(
  username: String,
  view_filename: String,
) -> Result(String, Nil) {
  let path = audience_path(username, view_filename)
  let deck_file = deck.view_dir <> username <> "/" <> view_filename
  let fresh = case simplifile.file_info(path), simplifile.file_info(deck_file) {
    Ok(a), Ok(d) -> a.mtime_seconds >= d.mtime_seconds
    _, _ -> False
  }
  case fresh {
    True -> Ok(path)
    False ->
      case write_audience(username, view_filename) {
        Ok(_) -> Ok(path)
        // Another visitor's copy may have landed first.
        Error(_) ->
          case simplifile.is_file(path) {
            Ok(True) -> Ok(path)
            _ -> Error(Nil)
          }
      }
  }
}

/// Removes the audience copy (the deck was replaced under another name).
pub fn delete_audience(username: String, view_filename: String) -> Nil {
  let _ = simplifile.delete(audience_path(username, view_filename))
  Nil
}
