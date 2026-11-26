import control
import document
import gleam/string
import notes

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
    document.deck_code(
      "<script src='/assets/cast-remote.js' data-cast-code='aB3'></script>",
    )
  let assert Error(Nil) = document.deck_code("<html>no remote</html>")
}

pub fn extension_is_lowercased_test() {
  let assert "Talk.v2.pdf" = document.lower_extension("Talk.v2.PDF")
  let assert "noext" = document.lower_extension("noext")
}
