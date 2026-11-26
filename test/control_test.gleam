import control
import deck
import document
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import notes
import simplifile
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
    // A "</section>" written inside the markdown is not the section's end.
    <> "<section data-markdown><textarea data-template>\n## Six\nuse `</section>` here\nNote: secret fifteen\n</textarea></section>"
    // A stray quote outside a value does not swallow the rest of the deck.
    <> "<section><aside data-x=it's>shown eleven</aside><aside class=notes>secret sixteen</aside><p>shown twelve</p></section>"
  let out = notes.strip(deck)
  let assert False = string.contains(out, "secret")
  let assert True = string.contains(out, "after6")
  let assert True = string.contains(out, "## Two")
  let assert True = string.contains(out, "shown ten")
  let assert True = string.contains(out, "## Four")
  let assert True = string.contains(out, "## Five")
  let assert True = string.contains(out, "after7 ñandú")
  let assert True = string.contains(out, "## Six")
  let assert True = string.contains(out, "shown eleven")
  let assert True = string.contains(out, "shown twelve")
}

fn test_store() {
  store.start_with(store.new_state(dict.new()))
}

pub fn reserve_claims_codes_and_decks_atomically_test() {
  // Reserve only touches memory; Store (set) is what writes CODES_FILE.
  let s = test_store()
  let user = "nobody-" <> int.to_string(int.random(1_000_000_000))
  let assert Ok(Nil) = store.reserve(s, "c1", user, "talk.pdf", False)
  // While c1 converts: the code is busy, even with its key, and so is the
  // deck file for any other code. Nothing is live yet.
  let assert Error(types.CodeInUse) =
    store.reserve(s, "c1", user, "talk.pdf", True)
  let assert Error(types.DeckInUse) =
    store.reserve(s, "c2", user, "talk.pdf", True)
  let assert None = store.get(s, "c1")
  // A failed conversion gives the code and the file back.
  store.release(s, "c1")
  let assert Ok(Nil) = store.reserve(s, "c2", user, "talk.pdf", False)
  store.release(s, "c2")
}

@external(erlang, "test_ffi", "rescue")
fn rescue(f: fn() -> a) -> Result(a, Nil)

pub fn a_replacement_goes_live_only_when_committed_test() {
  let user = "nobody-" <> int.to_string(int.random(1_000_000_000))
  let state = store.new_state(dict.from_list([#("c1", #(user, "old.pdf"))]))
  let s2 = store.start_with(state)
  // Without the key the code is not replaced.
  let assert Error(types.CodeInUse) =
    store.reserve(s2, "c1", user, "new.pdf", False)
  // With it, the old deck stays live (and owned) while the new one converts.
  let assert Ok(Nil) = store.reserve(s2, "c1", user, "new.pdf", True)
  let assert Some(#(_, "old.pdf")) = store.get(s2, "c1")
  let assert Some("c1") = store.owner_of(s2, user, "old.html")
  // A conversion that crashes still releases its claim.
  let assert Error(_) =
    rescue(fn() {
      store.while_reserved(s2, "c1", fn() -> Result(Nil, Nil) {
        panic as "conversion died"
      })
    })
  let assert Ok(Nil) = store.reserve(s2, "c1", user, "new.pdf", True)
  // A failed one too, and the code stays the old deck's.
  let assert Error(Nil) =
    store.while_reserved(s2, "c1", fn() -> Result(Nil, Nil) { Error(Nil) })
  let assert Some(#(_, "old.pdf")) = store.get(s2, "c1")
  let assert Ok(Nil) = store.reserve(s2, "c1", user, "new.pdf", True)
  store.release(s2, "c1")
}

pub fn a_saved_projector_page_loses_its_old_remote_test() {
  let page =
    "<p>deck</p><script src=\"/assets/cast-remote.js\" data-cast-code='old' data-cast-key='oldkey'></script>"
    <> "<script>var keep = 1;</script>"
    <> "<script data-cast-code=x src=other.js>gone()</script><p>end</p>"
  let out = notes.unremote(page)
  let assert False = string.contains(out, "old")
  let assert False = string.contains(out, "gone")
  let assert True = string.contains(out, "var keep = 1;")
  let assert True = string.contains(out, "<p>deck</p>")
  let assert True = string.contains(out, "<p>end</p>")
}

pub fn a_reservation_ends_with_its_process_test() {
  let s = test_store()
  let user = "nobody-" <> int.to_string(int.random(1_000_000_000))
  // An upload process that reserves and dies before committing.
  let done = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(done, store.reserve(s, "c9", user, "talk.pdf", False))
  })
  let assert Ok(Ok(Nil)) = process.receive(done, 1000)
  process.sleep(50)
  let assert Ok(Nil) = store.reserve(s, "c9", user, "talk.pdf", False)
  // Another process cannot release or commit this one's claim.
  let other = process.new_subject()
  process.spawn_unlinked(fn() {
    store.release(s, "c9")
    process.send(other, store.set(s, user, "talk.pdf", "c9"))
  })
  // The stranger's commit is refused, and says so.
  let assert Ok(Error(Nil)) = process.receive(other, 1000)
  let assert None = store.get(s, "c9")
  let assert Error(types.CodeInUse) =
    store.reserve(s, "c9", user, "talk.pdf", True)
  store.release(s, "c9")
}

pub fn a_replaced_deck_file_is_removed_test() {
  let user = "nobody-" <> int.to_string(int.random(1_000_000_000))
  let dir = deck.view_dir <> user <> "/"
  let assert Ok(_) = simplifile.create_directory_all(dir)
  let assert Ok(_) = simplifile.write(dir <> "old.html", "<p>old</p>")
  let assert Ok(_) = simplifile.write(dir <> "kept.html", "<p>kept</p>")
  let s =
    store.start_with(
      store.new_state(
        dict.from_list([
          #("c1", #(user, "old.pdf")),
          #("c2", #(user, "kept.pdf")),
          #("c3", #(user, "kept.pdf")),
        ]),
      ),
    )
  let assert Ok(Nil) = store.reserve(s, "c1", user, "new.pdf", True)
  let assert Ok(Nil) = store.set(s, user, "new.pdf", "c1")
  // c3 still shows kept.html, so moving c2 away leaves it.
  let assert Ok(Nil) = store.reserve(s, "c2", user, "new2.pdf", True)
  let assert Ok(Nil) = store.set(s, user, "new2.pdf", "c2")
  let assert Some(#(_, "new2.pdf")) = store.get(s, "c2")
  let assert Ok(False) = simplifile.is_file(dir <> "old.html")
  let assert Ok(True) = simplifile.is_file(dir <> "kept.html")
  let _ = simplifile.delete(dir)
  Nil
}

pub fn notes_inside_markdown_templates_are_stripped_test() {
  let deck =
    // HTML notes in the markdown are real markup to Reveal.
    "<section data-markdown><textarea data-template>\n# A\n<aside class=\"notes\">secret one</aside>\nshown one\n</textarea></section>"
    // Escaped in the textarea, the browser decodes it first.
    <> "<section data-markdown><textarea data-template>\n# B\n&lt;aside class=&quot;notes&quot;&gt;secret two&lt;/aside&gt;\nshown two\n</textarea></section>"
    <> "<section data-markdown><script type=\"text/template\">\n# C\n<!-- .slide: data-notes=\"secret three\" -->\nshown three\n</script></section>"
    // A note at the very start of the template, after a no-break space.
    <> "<section data-markdown><textarea data-template>Note: secret four\n---\nshown four\n\u{00A0}Note: secret five\n</textarea></section>"
    // Reveal's separators are case-sensitive: "slide" does not end the note.
    <> "<section data-markdown data-separator=\"^SLIDE$\"><textarea data-template>\n# D\nNote: x\nslide\nsecret six\nSLIDE\nshown six\n</textarea></section>"
    // A JavaScript \u escape in a custom notes marker.
    <> "<section data-markdown data-separator-notes=\"^\\u0053peaker:\"><textarea data-template>\n# E\nSpeaker: secret seven\n</textarea></section>"
    // A value that looks like an attribute is not one.
    <> "<aside title=\" class='x'\" class=\"notes\">secret eight</aside>"
    <> "<aside class=\"&#110;otes\">secret nine</aside><p>shown nine</p>"
  let out = notes.strip(deck)
  let assert False = string.contains(out, "secret")
  let assert True = string.contains(out, "shown one")
  let assert True = string.contains(out, "shown two")
  let assert True = string.contains(out, "shown three")
  let assert True = string.contains(out, "shown four")
  let assert True = string.contains(out, "shown six")
  let assert True = string.contains(out, "shown nine")
  // An untouched template goes out byte for byte.
  let plain =
    "<section data-markdown><textarea data-template>\n# T &amp; U\n</textarea></section>"
  let assert True = notes.strip(plain) == plain
}

pub fn an_unclosed_raw_element_drops_the_rest_test() {
  let out = notes.strip("<p>a</p><script>x()<aside class=notes>secret</aside>")
  let assert False = string.contains(out, "secret")
  let assert True = string.contains(out, "<p>a</p>")
}

pub fn a_room_loading_at_once_gets_the_audience_copy_test() {
  let user = "nobody-" <> int.to_string(int.random(1_000_000_000))
  let dir = deck.view_dir <> user <> "/"
  let assert Ok(_) = simplifile.create_directory_all(dir)
  let assert Ok(_) =
    simplifile.write(
      dir <> "talk.html",
      "<section>hi<aside class=notes>secret</aside></section>",
    )
  let done = process.new_subject()
  list.each(list.repeat(Nil, 30), fn(_) {
    process.spawn_unlinked(fn() {
      process.send(done, notes.audience_file(user, "talk.html"))
    })
  })
  list.each(list.repeat(Nil, 30), fn(_) {
    let assert Ok(Ok(path)) = process.receive(done, 5000)
    let assert Ok(copy) = simplifile.read(path)
    let assert False = string.contains(copy, "secret")
  })
  let _ = simplifile.delete(dir)
  let _ = simplifile.delete(notes.audience_path(user, ""))
  Nil
}

pub fn markdown_code_samples_survive_and_hidden_markers_do_not_test() {
  let deck =
    // Code in a template: an unclosed "<" or a "<title>" is just text.
    "<section data-markdown><textarea data-template>\n# Code\nif (a&lt;b) x\n`&lt;title&gt;`\nshown one\n---\nshown two\nNote: secret one\n</textarea></section>"
    // References the browser decodes before Reveal reads the text.
    <> "<section data-markdown><textarea data-template>\n# A&NewLine;Note: secret two\n</textarea></section>"
    <> "<section data-markdown><textarea data-template>\n# B\nNote&colon; secret three\n</textarea></section>"
    <> "<aside class=\"x&Tab;notes\">secret four</aside><p>shown three</p>"
    // A section without a template: its text, tags and references gone.
    <> "<section data-markdown><div data-template>Note: secret five</div></section>"
    <> "<section data-markdown>\n# C\nN&#111;te: secret six\n</section><p>shown four</p>"
    // A fake marker the raw HTML shows does not hide the real one.
    <> "<section data-markdown>N&#111;te: secret seven\n---\n# B <p title=\"Note:\">x</p></section>"
    <> "<section data-markdown>N&#111;te: secret eight\n---\n# B <!-- Note: --></section>"
  let out = notes.strip(deck)
  let assert False = string.contains(out, "secret")
  let assert True = string.contains(out, "shown one")
  let assert True = string.contains(out, "shown two")
  let assert True = string.contains(out, "shown three")
  let assert True = string.contains(out, "shown four")
}
