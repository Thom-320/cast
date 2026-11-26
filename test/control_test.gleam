import control
import deck
import document
import gleam/dict
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import notes
import store
import types

// Must match websocket_relay.js (and test/relay.test.js): same secret and
// code give the same key in Gleam and in Node.
pub fn key_matches_the_relay_test() {
  assert control.key("test-secret", "aB3xZ9") == "1rvJYI2_DVuDtn5GuBfmeO"
}

pub fn valid_accepts_only_the_right_key_test() {
  let k = control.key("test-secret", "aB3xZ9")
  assert control.valid("test-secret", "aB3xZ9", k)
  assert !control.valid("test-secret", "aB3xZ9", "")
  assert !control.valid("test-secret", "aB3xZ9", k <> "x")
  assert !control.valid("other-secret", "aB3xZ9", k)
  assert !control.valid("test-secret", "aB3xZ0", k)
}

pub fn notes_are_stripped_for_the_audience_test() {
  let deck =
    "<section><h2>Hi</h2><aside class=\"notes\">secret one</aside></section>"
    <> "<section data-notes='secret two'><aside class='x'>keep</aside></section>"
    <> "<section><ASIDE CLASS=\"notes big\">secret three</ASIDE></section>"
    <> "<section><aside class=notes>secret four</aside><p>after</p></section>"
    <> "<section><aside class=\"notes\">secret five, never closed"
  let out = notes.strip(deck)
  assert !string.contains(out, "secret")
  assert string.contains(out, "keep")
  assert string.contains(out, "<h2>Hi</h2>")
  assert string.contains(out, "<p>after</p>")
}

pub fn names_are_safe_path_segments_test() {
  assert !string.contains(document.safe_name("../public"), "/")
  assert !string.contains(document.safe_name("../public"), "..")
  assert document.safe_name("a/b\\c") == "a_b_c"
  assert document.safe_name("x');alert(1);('.html") == "x_)_alert(1)_(_.html"
  assert document.safe_name("Clase 3.pptx") == "Clase 3.pptx"
  assert !string.contains(document.safe_name("...."), "..")
}

pub fn qr_paths_differ_by_case_test() {
  assert document.control_qr_path("ab") != document.control_qr_path("AB")
}

pub fn deck_code_reads_the_remote_tag_test() {
  let assert Ok("aB3") =
    deck.code_in(
      "<script src='/assets/cast-remote.js' data-cast-code='aB3'></script>",
    )
  let assert Error(Nil) = deck.code_in("<html>no remote</html>")
}

pub fn extension_is_lowercased_test() {
  let assert "Talk.v2.pdf" = document.lower_extension("Talk.v2.PDF")
  let assert "noext" = document.lower_extension("noext")
}

pub fn tricky_notes_are_stripped_test() {
  let deck =
    "<section><aside title=\"a > b\" class=\"notes\">secret six<aside>inner</aside>secret seven</aside><p>after6</p></section>"
    <> "<section data-markdown><textarea data-template>\n## One\nNote: secret eight\nmore secret nine\n---\n## Two\nshown ten\n</textarea></section>"
    <> "<section data-markdown data-separator-notes=\"^Speaker:\" data-separator=\"^===$\"><textarea data-template>\n## Three\nSpeaker: secret eleven\n===\n## Four\n</textarea></section>"
    <> "<section data-markdown data-separator-notes=\"\"><textarea data-template>\n## Five\nNotes: secret twelve\n</textarea></section>"
    // Markup browsers accept: "/" before an attribute, no space after a quote.
    <> "<section><aside/class=notes>secret thirteen</aside><p x='a'data-notes='secret fourteen'>after7 ñandú</p></section>"
  let out = notes.strip(deck)
  let assert False = string.contains(out, "secret")
  let assert True = string.contains(out, "after6")
  let assert True = string.contains(out, "## Two")
  let assert True = string.contains(out, "shown ten")
  let assert True = string.contains(out, "## Four")
  let assert True = string.contains(out, "## Five")
  let assert True = string.contains(out, "after7 ñandú")
}

fn test_store() {
  let assert Ok(started) =
    actor.new(dict.new())
    |> actor.on_message(store.handle_message)
    |> actor.start
  started.data
}

pub fn reserve_claims_codes_and_decks_atomically_test() {
  // Reserve only touches memory; Store (Commit) is what writes CODES_FILE.
  let s = test_store()
  let user = "nobody-" <> int.to_string(int.random(1_000_000_000))
  let assert Ok(None) = store.reserve(s, "c1", user, "talk.pdf", False)
  // Same code again without its key: refused while the first converts.
  let assert Error(types.CodeInUse) =
    store.reserve(s, "c1", user, "talk.pdf", False)
  // Another code on the same deck file: refused even with its own key.
  let assert Error(types.DeckInUse) =
    store.reserve(s, "c2", user, "talk.pdf", True)
  // The owner with its key may replace it.
  let assert Ok(Some(_)) = store.reserve(s, "c1", user, "talk.pdf", True)
  let assert Some("c1") = store.owner_of(s, user, "talk.html")
  // A failed conversion gives the code back.
  store.release(s, "c1", None)
  let assert None = store.get(s, "c1")
  let assert Ok(None) = store.reserve(s, "c2", user, "talk.pdf", False)
}
