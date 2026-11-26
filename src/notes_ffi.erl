-module(notes_ffi).
-export([strip/1, unremote/1]).

%% Removes what only the presenter may see from a deck before it goes to the
%% audience:
%%  - <aside class="... notes ...">...</aside>, counting nested asides;
%%  - Reveal markdown notes ("Note:" up to the next slide) inside
%%    <section data-markdown>, honouring its data-separator* attributes;
%%  - data-notes="..." and data-cast-key="..." attributes.
%%
%% One pass over the document, reading it the way a browser's tokenizer
%% does: tags are scanned by hand with the browser's states (so an
%% attribute value is never read as an attribute), comments and raw-text
%% elements (<script>, <style>, <textarea>...) are opaque, and a tag or raw
%% element that never closes drops the rest of the file.
%%
%% Inside a markdown section the template's text is markup to Reveal: its
%% notes are cut as Reveal splits them (same flags, line starts and \s), and
%% then it is stripped like a page, comments included ("<!-- .slide:
%% data-notes=... -->").
%%
%% Every regex is anchored or led by a literal, or bounded by a match
%% limit, and a limit cuts (fail closed): the audience may lose part of a
%% slide, but never sees a note.

-define(LIMIT, [{match_limit, 200000}, {match_limit_recursion, 20000}, report_errors]).
-define(RAW, [<<"script">>, <<"style">>, <<"textarea">>, <<"title">>, <<"xmp">>,
              <<"iframe">>, <<"noembed">>, <<"noframes">>, <<"noscript">>]).
-define(WS, [$\s, $\t, $\n, $\r, $\f]).

%% Patterns are compiled once per node and kept in persistent_term.
mp(Key, Pattern, Opts) ->
    case persistent_term:get({?MODULE, Key}, undefined) of
        undefined ->
            {ok, MP} = re:compile(Pattern, Opts),
            persistent_term:put({?MODULE, Key}, MP),
            MP;
        MP -> MP
    end.

strip(Html) when is_binary(Html) ->
    iolist_to_binary(walk(Html, 0, #{out => [], skip => 0, md => none, lenient => false})).

%% A markdown template's text: code samples ("a<b", "<title>") are common
%% there, so an unclosed tag is text and an unclosed raw element is plain
%% markup. Both only strip more than the browser would show, never less.
strip_lenient(Text) ->
    iolist_to_binary(walk(Text, 0, #{out => [], skip => 0, md => none, lenient => true})).

%% ------------------------------------------------------------ the walk

walk(Html, From, S) ->
    case binary:match(Html, <<"<">>, [{scope, {From, byte_size(Html) - From}}]) of
        nomatch ->
            finish(emit(S, part(Html, From, byte_size(Html))));
        {Lt, 1} ->
            S1 = emit(S, part(Html, From, Lt)),
            case token(Html, Lt) of
                eof when map_get(lenient, S1) -> walk(Html, Lt + 1, emit(S1, <<"<">>));
                eof -> finish(S1);
                {text, End} -> walk(Html, End, emit(S1, part(Html, Lt, End)));
                {comment, End} -> walk(Html, End, emit(S1, part(Html, Lt, End)));
                {open, Name, End, Attrs} -> open(Html, Name, Lt, End, Attrs, S1);
                {close, Name, End, _} -> close(Html, Name, Lt, End, S1)
            end
    end.

%% The end of the document (or a tag that never closes, which the browser
%% drops along with everything after it).
finish(#{md := {Sec, Outer, _}} = S) ->
    finish(S#{out := [md_body(body(S), Sec) | Outer], md := none});
finish(#{out := Out}) ->
    lists:reverse(Out).

emit(#{skip := 0, out := Out} = S, Bin) -> S#{out := [Bin | Out]};
emit(S, _) -> S.

body(#{out := Out}) -> iolist_to_binary(lists:reverse(Out)).

open(Html, Name, Lt, End, Attrs, #{skip := Skip} = S) ->
    Clean = clean(Html, Lt, End, Attrs),
    S1 = case {Name, Skip} of
             {<<"aside">>, 0} ->
                 case is_notes(Attrs) of
                     true -> S#{skip := 1};
                     false -> emit(S, Clean)
                 end;
             {<<"aside">>, _} -> S#{skip := Skip + 1};
             {<<"section">>, 0} -> section_open(Attrs, Clean, S);
             _ -> emit(S, Clean)
         end,
    case lists:member(Name, ?RAW) of
        false ->
            walk(Html, End, S1);
        true ->
            %% Raw text: everything up to its own end tag is opaque.
            case raw_end(Html, Name, End) of
                eof when map_get(lenient, S1) -> walk(Html, End, S1);
                eof -> finish(S1);
                Stop ->
                    Raw = part(Html, End, Stop),
                    Text = case S1 of
                               #{md := {Sec, _, _}} when Name =:= <<"textarea">>;
                                                         Name =:= <<"script">> ->
                                   template(Raw, Name, Sec);
                               _ -> Raw
                           end,
                    walk(Html, Stop, emit(S1, Text))
            end
    end.

close(Html, Name, Lt, End, #{skip := Skip} = S) ->
    Tag = part(Html, Lt, End),
    case {Name, Skip} of
        {<<"aside">>, 1} -> walk(Html, End, S#{skip := 0});
        {<<"aside">>, N} when N > 1 -> walk(Html, End, S#{skip := N - 1});
        {<<"section">>, 0} -> walk(Html, End, section_close(Tag, S));
        _ -> walk(Html, End, emit(S, Tag))
    end.

%% A markdown section collects its output apart, and its notes are cut when
%% it closes, with its own separators. Sections nested in it just count.
section_open(Attrs, Clean, #{md := none, out := Out} = S) ->
    case has(Attrs, <<"data-markdown">>) of
        true -> S#{md := {Attrs, [Clean | Out], 1}, out := []};
        false -> emit(S, Clean)
    end;
section_open(_, Clean, #{md := {A, O, D}} = S) ->
    emit(S#{md := {A, O, D + 1}}, Clean).

section_close(Close, #{md := {Sec, Outer, 1}} = S) ->
    S#{out := [Close, md_body(body(S), Sec) | Outer], md := none};
section_close(Close, #{md := {A, O, D}} = S) when D > 1 ->
    emit(S#{md := {A, O, D - 1}}, Close);
section_close(Close, S) ->
    emit(S, Close).

%% ------------------------------------------------------------ tokens

%% What starts at the "<" at Lt, and the offset just past it.
token(Html, Lt) ->
    Size = byte_size(Html),
    At = fun(N) -> case Lt + N < Size of
                       true -> binary:at(Html, Lt + N);
                       false -> none
                   end end,
    case {At(1), At(2), At(3)} of
        {$!, $-, $-} ->
            case binary:match(Html, <<"-->">>, [{scope, {Lt + 4, max(0, Size - Lt - 4)}}]) of
                {P, 3} -> {comment, P + 3};
                nomatch -> eof
            end;
        {C, _, _} when C =:= $!; C =:= $? -> bogus(Html, Lt);
        {$/, C, _} when is_integer(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)) ->
            tag(Html, Lt + 2, close);
        {$/, _, _} -> bogus(Html, Lt);
        {C, _, _} when is_integer(C), ((C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)) ->
            tag(Html, Lt + 1, open);
        _ -> {text, Lt + 1}
    end.

%% "<!x", "<?x", "</ x": a comment up to the next ">".
bogus(Html, Lt) ->
    case binary:match(Html, <<">">>, [{scope, {Lt, byte_size(Html) - Lt}}]) of
        {P, 1} -> {comment, P + 1};
        nomatch -> eof
    end.

%% A start or end tag, scanned with the browser's tokenizer states. Attrs
%% are {lowercase name, raw value, start, end} in order. A tag that runs
%% into the end of the file is eof (the browser drops it).
tag(Html, P, Kind) ->
    Size = byte_size(Html),
    NameEnd = upto(Html, P, Size, [$/, $> | ?WS]),
    case attrs(Html, NameEnd, Size, []) of
        eof -> eof;
        {End, Attrs} -> {Kind, lower(part(Html, P, NameEnd)), End, Attrs}
    end.

%% Before attribute name. "/" not followed by ">" is skipped, as there.
attrs(_, P, Size, _) when P >= Size -> eof;
attrs(H, P, Size, Acc) ->
    case binary:at(H, P) of
        $> -> {P + 1, lists:reverse(Acc)};
        C when C =:= $/; C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r; C =:= $\f ->
            attrs(H, P + 1, Size, Acc);
        _ ->
            %% The first character is part of the name even if it is "=".
            NE = upto(H, P + 1, Size, [$/, $>, $= | ?WS]),
            Name = lower(part(H, P, NE)),
            Q = upto_not(H, NE, Size, ?WS),
            case Q < Size andalso binary:at(H, Q) =:= $= of
                false -> attrs(H, Q, Size, [{Name, <<>>, P, NE} | Acc]);
                true -> value(H, upto_not(H, Q + 1, Size, ?WS), Size, Name, P, Acc)
            end
    end.

value(_, V, Size, _, _, _) when V >= Size -> eof;
value(H, V, Size, Name, Start, Acc) ->
    case binary:at(H, V) of
        Q when Q =:= $"; Q =:= $' ->
            case binary:match(H, <<Q>>, [{scope, {V + 1, Size - V - 1}}]) of
                nomatch -> eof;
                {E, 1} -> attrs(H, E + 1, Size, [{Name, part(H, V + 1, E), Start, E + 1} | Acc])
            end;
        $> -> attrs(H, V, Size, [{Name, <<>>, Start, V} | Acc]);
        _ ->
            E = upto(H, V, Size, [$> | ?WS]),
            attrs(H, E, Size, [{Name, part(H, V, E), Start, E} | Acc])
    end.

upto(H, P, Size, Stop) when P < Size ->
    case lists:member(binary:at(H, P), Stop) of
        true -> P;
        false -> upto(H, P + 1, Size, Stop)
    end;
upto(_, P, _, _) -> P.

upto_not(H, P, Size, Skip) when P < Size ->
    case lists:member(binary:at(H, P), Skip) of
        true -> upto_not(H, P + 1, Size, Skip);
        false -> P
    end;
upto_not(_, P, _, _) -> P.

%% Offset of the end tag that closes a raw-text element, or eof.
raw_end(Html, Name, From) ->
    Re = mp({raw, Name}, ["</", Name, "(?=[\\s/>])"], [caseless]),
    case re:run(Html, Re, [{offset, From}, {capture, first, index} | ?LIMIT]) of
        {match, [{P, _}]} -> P;
        _ -> eof
    end.

%% ------------------------------------------------------------ attributes

%% The first value of an attribute (the one the browser keeps), decoded.
first(Attrs, Name, Default) ->
    case [V || {N, V, _, _} <- Attrs, N =:= Name] of
        [V | _] -> decode(V);
        [] -> Default
    end.

has(Attrs, Name) -> lists:keymember(Name, 1, Attrs).

%% Any class attribute holds the token "notes" (any case: toward stripping).
%% A reference decode does not know (the browser knows them all) next to
%% "notes" counts as notes too.
is_notes(Attrs) ->
    lists:any(fun({<<"class">>, V, _, _}) ->
                      Class = lower(decode(V)),
                      lists:member(<<"notes">>,
                                   binary:split(Class, [<<" ">>, <<"\t">>, <<"\n">>, <<"\r">>, <<"\f">>],
                                                [global, trim_all]))
                          orelse (binary:match(Class, <<"notes">>) =/= nomatch
                                  andalso binary:match(Class, <<"&">>) =/= nomatch);
                 (_) -> false
              end, Attrs).

%% The tag without its data-notes and data-cast-key attributes.
clean(Html, Lt, End, Attrs) ->
    Drop = [{S, E} || {N, _, S, E} <- Attrs,
                      N =:= <<"data-notes">> orelse N =:= <<"data-cast-key">>],
    splice(Html, Lt, End, Drop).

splice(H, From, End, []) -> [part(H, From, End)];
splice(H, From, End, [{S, E} | R]) -> [part(H, From, S) | splice(H, E, End, R)].

%% Character references, as far as they can spell a tag, a class or a
%% notes marker: numeric ones and the named ones for <, >, &, quotes,
%% spaces, line breaks and ":" (";" optional).
decode(V) ->
    case binary:split(V, <<"&">>, [global]) of
        [V] -> V;
        [First | Rest] -> iolist_to_binary([First | [entity(R) || R <- Rest]])
    end.

entity(R) ->
    Re = mp(entity, "^(?:#[xX]0*+([0-9a-fA-F]{1,6})|#0*+([0-9]{1,7})|(lt|gt|amp|quot|apos|tab|newline|colon|nbsp|ensp|emsp|thinsp|hairsp|numsp|puncsp|mediumspace|sol|equals))(;?)",
            [caseless]),
    case re:run(R, Re, [{capture, all, index}]) of
        {match, [{0, L}, Hex, Dec, Named | _]} ->
            Char = case {Hex, Dec, Named} of
                       {{S, N}, _, _} when N > 0 -> code(binary_to_integer(part(R, S, S + N), 16));
                       {_, {S, N}, _} when N > 0 -> code(binary_to_integer(part(R, S, S + N)));
                       {_, _, {S, N}} ->
                           case lower(part(R, S, S + N)) of
                               <<"lt">> -> <<"<">>;
                               <<"gt">> -> <<">">>;
                               <<"amp">> -> <<"&">>;
                               <<"quot">> -> <<"\"">>;
                               <<"apos">> -> <<"'">>;
                               <<"tab">> -> <<"\t">>;
                               <<"newline">> -> <<"\n">>;
                               <<"colon">> -> <<":">>;
                               <<"nbsp">> -> <<16#A0/utf8>>;
                               <<"ensp">> -> <<16#2002/utf8>>;
                               <<"emsp">> -> <<16#2003/utf8>>;
                               <<"thinsp">> -> <<16#2009/utf8>>;
                               <<"hairsp">> -> <<16#200A/utf8>>;
                               <<"numsp">> -> <<16#2007/utf8>>;
                               <<"puncsp">> -> <<16#2008/utf8>>;
                               <<"mediumspace">> -> <<16#205F/utf8>>;
                               <<"sol">> -> <<"/">>;
                               <<"equals">> -> <<"=">>
                           end
                   end,
            [Char | part(R, L, byte_size(R))];
        _ -> [<<"&">>, R]
    end.

code(0) -> <<16#FFFD/utf8>>;
code(C) -> try <<C/utf8>> catch _:_ -> <<16#FFFD/utf8>> end.

escape(T) ->
    binary:replace(binary:replace(T, <<"&">>, <<"&amp;">>, [global]),
                   <<"<">>, <<"&lt;">>, [global]).

lower(B) -> << <<(if C >= $A, C =< $Z -> C + 32; true -> C end)>> || <<C>> <= B >>.

part(Html, From, To) -> binary:part(Html, From, To - From).

%% ------------------------------------------------------------ markdown notes

%% The text of a markdown template (a <textarea> or <script> in a
%% data-markdown section), as Reveal reads it (textContent), without notes:
%% cut its "Note:" parts, strip it as markup, drop data-notes anywhere (the
%% ".slide:" comments). Unchanged text goes out byte for byte.
template(Raw, Name, Sec) ->
    Text = case Name of
               <<"textarea">> -> decode(Raw);
               _ -> Raw
           end,
    Clean = case md_cut(utf8(Text), Sec, template) of
                drop -> <<>>;
                Cut -> scrub(strip_lenient(Cut))
            end,
    if
        Clean =:= Text -> Raw;
        Name =:= <<"textarea">> -> escape(Clean);
        true ->
            %% A script must not end early where something was removed.
            case binary:match(lower(Clean), <<"</script">>) of
                nomatch -> Clean;
                _ -> <<>>
            end
    end.

%% A markdown section's own text (when it has no template), cut the same way.
%% Reveal reads it as textContent, where tags and references vanish, so a
%% marker may sit anywhere: unless the section is plain text already, a
%% marker in its text drops the whole section.
md_body(Body0, Sec) ->
    Body = utf8(Body0),
    Plain = utf8(decode(re:replace(Body, mp(tags, "<[^>]*+>", []), "", [global, {return, binary}]))),
    case notes_re(first(Sec, <<"data-separator-notes">>, <<>>), anywhere) of
        drop -> <<>>;
        Any ->
            %% Counting markers can be fooled (a fake one in an attribute
            %% or comment hides a real one): any marker in text that tags
            %% or references change means the whole section goes.
            Hidden = count(Plain, Any) =/= 0 andalso Plain =/= Body,
            case Hidden of
                true -> <<>>;
                false ->
                    case md_cut(Body, Sec, body) of
                        drop -> <<>>;
                        Cut -> Cut
                    end
            end
    end.

%% How many markers; a matcher that gives up counts as more than any.
count(T, Re) ->
    case re:run(T, Re, [global, {capture, first, index} | ?LIMIT]) of
        nomatch -> 0;
        {match, Ms} -> length(Ms);
        _ -> infinity
    end.

scrub(T) ->
    Re = mp(scrub, "data-(?:notes|cast-key)(?:\\s*+=\\s*+(?:\"[^\"]*+\"|'[^']*+'|[^\\s>\"']\\S*+))?",
            [caseless]),
    case re:run(T, Re, [global, {capture, first, index} | ?LIMIT]) of
        nomatch -> T;
        {match, Ms} -> iolist_to_binary(splice(T, 0, byte_size(T), [{S, S + L} || [{S, L}] <- Ms]));
        _ -> <<>>
    end.

%% Cuts from each notes marker up to the next slide separator (or the end).
%% Reveal's flags: notes "mgi", separators "mg" (case matters). Notes see
%% every line start and Unicode \s (stripping more); separators only CR/LF
%% line starts and ASCII \s (ending a cut later, never sooner).
md_cut(Text, Sec, Mode) ->
    case notes_re(first(Sec, <<"data-separator-notes">>, <<>>), case Mode of body -> anywhere; template -> line end) of
        drop -> drop;
        Notes ->
            Slides = case first(Sec, <<"data-separator">>, <<>>) of
                         <<>> -> [<<"\\r?\\n---\\r?\\n">>];
                         P -> [js(P)]
                     end,
            Vertical = case first(Sec, <<"data-separator-vertical">>, <<>>) of
                           <<>> -> [];
                           V -> [js(V)]
                       end,
            Ends = case Mode of
                       body -> [<<"</textarea">>, <<"</script">>];
                       template -> []
                   end,
            Opts = [unicode, multiline, {newline, anycrlf}],
            %% A separator that does not compile (or matches nothing at all)
            %% is left out: the note then runs to the end.
            Good = [P || P <- Slides ++ Vertical ++ Ends,
                         case re:compile(P, Opts) of
                             {ok, MP} -> re:run(<<>>, MP) =:= nomatch;
                             _ -> false
                         end],
            Sep = case Good of
                      [] -> none;
                      _ ->
                          {ok, MP} = re:compile(lists:join("|", [["(?:", P, ")"] || P <- Good]), Opts),
                          MP
                  end,
            iolist_to_binary(cut(Text, 0, Notes, Sep, []))
    end.

%% The notes pattern, or drop (the whole template goes) if it is unusable.
notes_re(P0, Where) ->
    P1 = case P0 of
             <<>> -> <<"^\\s*notes?:">>;
             _ -> js(P0)
         end,
    %% Anywhere: without a leading "^" (and "\s*"), so markup before the
    %% marker on its line does not hide it.
    P = case Where of
            line -> P1;
            anywhere -> re:replace(P1, "^\\^(?:\\\\s\\*)?", "", [{return, binary}])
        end,
    case re:compile(P, [unicode, ucp, caseless, multiline, {newline, any}]) of
        {ok, MP} ->
            case re:run(<<>>, MP) of
                nomatch -> MP;
                _ -> drop
            end;
        _ -> drop
    end.

%% JavaScript's \uXXXX is PCRE's \x{XXXX}.
js(P) ->
    re:replace(P, "\\\\u([0-9a-fA-F]{4})", "\\\\x{\\1}", [global, {return, binary}]).

cut(Text, From, Notes, Sep, Acc) ->
    Size = byte_size(Text),
    case re:run(Text, Notes, [{offset, From}, {capture, first, index} | ?LIMIT]) of
        nomatch ->
            lists:reverse([part(Text, From, Size) | Acc]);
        {match, [{M, ML}]} when ML > 0 ->
            Kept = [part(Text, From, M) | Acc],
            Next = case Sep of
                       none -> nomatch;
                       _ -> re:run(Text, Sep, [{offset, M + ML}, {capture, first, index} | ?LIMIT])
                   end,
            case Next of
                {match, [{P, PL}]} when PL > 0 -> cut(Text, P, Notes, Sep, Kept);
                _ -> lists:reverse(Kept)        % no separator, or a limit: cut to the end
            end;
        _ ->
            %% An empty marker, or the matcher gave up: drop the rest.
            lists:reverse(Acc)
    end.

%% Invalid UTF-8 as the browser shows it (U+FFFD), so the Unicode-mode
%% patterns can run on it.
utf8(B) ->
    case unicode:characters_to_binary(B) of
        Ok when is_binary(Ok) -> Ok;
        {error, Good, Rest} -> utf8_fix([Good], Rest);
        {incomplete, Good, _} -> <<Good/binary, 16#FFFD/utf8>>
    end.

utf8_fix(Acc, <<_, Rest/binary>>) ->
    Bad = <<16#FFFD/utf8>>,
    case unicode:characters_to_binary(Rest) of
        Ok when is_binary(Ok) -> iolist_to_binary(lists:reverse([Ok, Bad | Acc]));
        {error, Good, R} -> utf8_fix([Good, Bad | Acc], R);
        {incomplete, Good, _} -> iolist_to_binary(lists:reverse([Bad, Good, Bad | Acc]))
    end.

%% ------------------------------------------------------------ re-uploads

%% Drops <script ... cast-remote.js ...></script> tags from an uploaded page
%% (a saved projector page carries its old code and key), using the same
%% tokenizer so quotes and comments are read as the browser reads them.
unremote(Html) when is_binary(Html) ->
    iolist_to_binary(lists:reverse(unremote(Html, 0, []))).

unremote(Html, From, Acc) ->
    Size = byte_size(Html),
    case binary:match(Html, <<"<">>, [{scope, {From, Size - From}}]) of
        nomatch -> [part(Html, From, Size) | Acc];
        {Lt, 1} ->
            Before = part(Html, From, Lt),
            case token(Html, Lt) of
                {open, <<"script">>, End, Attrs} ->
                    Close = case raw_end(Html, <<"script">>, End) of
                                eof -> Size;
                                Stop ->
                                    case tag(Html, Stop + 2, close) of
                                        {close, _, E, _} -> E;
                                        _ -> Size
                                    end
                            end,
                    case is_remote(Attrs) of
                        true -> unremote(Html, Close, [Before | Acc]);
                        false -> unremote(Html, Close, [part(Html, Lt, Close), Before | Acc])
                    end;
                {_, _, End, _} -> unremote(Html, End, [part(Html, Lt, End), Before | Acc]);
                {_, End} -> unremote(Html, End, [part(Html, Lt, End), Before | Acc]);
                eof -> [part(Html, Lt, Size), Before | Acc]
            end
    end.

is_remote(Attrs) ->
    binary:match(lower(first(Attrs, <<"src">>, <<>>)), <<"cast-remote.js">>) =/= nomatch
        orelse has(Attrs, <<"data-cast-code">>) orelse has(Attrs, <<"data-cast-key">>).
