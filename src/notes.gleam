//// Removes speaker notes from a deck's HTML for the audience copy.
//// The presenter's keyed windows get the untouched deck.

@external(erlang, "notes_ffi", "strip")
pub fn strip(html: String) -> String
