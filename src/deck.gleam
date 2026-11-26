//// Where a deck lives on disk and which code it was built for. Shared by the
//// upload code and the code store (which cannot import document).

import gleam/string

pub const view_dir: String = "./view/"

/// The name the generated presentation is saved under in ./view/<username>/.
pub fn view_filename(filename: String) -> String {
  let lower = string.lowercase(filename)
  case string.ends_with(lower, ".pdf"), string.ends_with(lower, ".pptx") {
    True, _ -> string.replace(filename, ".pdf", ".html")
    _, True -> string.replace(filename, ".pptx", ".html")
    _, _ -> filename
  }
}

/// The cast code in a generated deck's remote script tag. Only a tiebreak:
/// the code store is what says who owns a deck.
pub fn code_in(html: String) -> Result(String, Nil) {
  case string.split_once(html, "data-cast-code='") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "'") {
        Ok(#(code, _)) -> Ok(code)
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}
