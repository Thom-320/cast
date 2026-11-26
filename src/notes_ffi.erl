-module(notes_ffi).
-export([strip/1]).

%% Removes speaker notes: <aside class="... notes ...">...</aside> (any case,
%% any quoting; an unclosed one is cut to the end rather than leaked) and
%% data-notes attributes.
strip(Html) ->
    Opts = [global, caseless, dotall, unicode, {return, binary}],
    Open = "<aside\\b[^>]*\\bclass\\s*=\\s*(?:\"[^\"]*\\bnotes\\b[^\"]*\"|'[^']*\\bnotes\\b[^']*'|notes\\b)[^>]*>",
    A = re:replace(Html, Open ++ ".*?</aside\\s*>", "", Opts),
    B = re:replace(A, Open ++ ".*$", "", Opts),
    re:replace(B, "\\sdata-notes\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", "", Opts).
