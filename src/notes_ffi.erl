-module(notes_ffi).
-export([strip/1]).

%% Removes speaker notes from a deck before it goes to the audience:
%%  - <aside class="... notes ...">...</aside>, any case and quoting, counting
%%    nested <aside>s; one that never closes is cut to the end, not leaked;
%%  - Reveal markdown notes ("Note:" up to the next slide) inside
%%    <section data-markdown>, honouring data-separator* attributes;
%%  - data-notes="..." attributes.
%% Tags are read with quoted attribute values, so a ">" inside one does not
%% end the tag early.
%% Matching is on bytes, without the unicode flag: with it, every re:run
%% re-validates the whole document, and a deck with many tags costs
%% (tags x size). All the patterns are ASCII and the offsets are bytes.

-define(OPTS, [caseless]).

strip(Html) ->
    A = strip_asides(Html),
    B = strip_markdown(A),
    re:replace(B, "(?<=[\\s\"'/])data-notes\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", "",
               [global, caseless, {return, binary}]).

tag(Name) -> "<" ++ Name ++ "\\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>".

rest(Html, From) -> binary:part(Html, From, byte_size(Html) - From).

%% ------------------------------------------------------------ <aside class=notes>

strip_asides(Html) -> iolist_to_binary(asides(Html, 0, [])).

asides(Html, From, Acc) ->
    case re:run(Html, tag("aside"), [{offset, From}, {capture, first, index} | ?OPTS]) of
        nomatch ->
            lists:reverse([rest(Html, From) | Acc]);
        {match, [{S, L}]} ->
            Before = binary:part(Html, From, S - From),
            case is_notes(binary:part(Html, S, L)) of
                false ->
                    asides(Html, S + L, [binary:part(Html, S, L), Before | Acc]);
                true ->
                    case close_of(Html, S + L, 1) of
                        none -> lists:reverse([Before | Acc]);
                        End -> asides(Html, End, [Before | Acc])
                    end
            end
    end.

is_notes(Tag) ->
    re:run(Tag, "[\\s/\"']class\\s*=\\s*(?:\"[^\"]*\\bnotes\\b[^\"]*\"|'[^']*\\bnotes\\b[^']*'|notes\\b)",
           ?OPTS) =/= nomatch.

%% Offset just past the </aside> that closes the one opened before From.
close_of(Html, From, Depth) ->
    case re:run(Html, "(" ++ tag("aside") ++ ")|</aside\\s*>",
                [{offset, From}, {capture, all, index} | ?OPTS]) of
        nomatch ->
            none;
        {match, [{S, L} | Groups]} ->
            case Groups of
                [{G, _}] when G >= 0 -> close_of(Html, S + L, Depth + 1);
                _ when Depth =:= 1 -> S + L;
                _ -> close_of(Html, S + L, Depth - 1)
            end
    end.

%% ------------------------------------------------------------ markdown notes

strip_markdown(Html) -> iolist_to_binary(md(Html, 0, [])).

md(Html, From, Acc) ->
    case re:run(Html, tag("section"), [{offset, From}, {capture, first, index} | ?OPTS]) of
        nomatch ->
            lists:reverse([rest(Html, From) | Acc]);
        {match, [{S, L}]} ->
            Tag = binary:part(Html, S, L),
            Head = binary:part(Html, From, S + L - From),
            case re:run(Tag, "\\sdata-markdown\\b", ?OPTS) of
                nomatch ->
                    md(Html, S + L, [Head | Acc]);
                _ ->
                    Start = S + L,
                    End = case re:run(Html, "</section\\s*>",
                                      [{offset, Start}, {capture, first, index} | ?OPTS]) of
                              {match, [{E, _}]} -> E;
                              nomatch -> byte_size(Html)
                          end,
                    Body = binary:part(Html, Start, End - Start),
                    md(Html, End, [md_notes(Body, Tag), Head | Acc])
            end
    end.

%% Cuts from each notes marker up to the next slide separator or the end of
%% the template. Reveal's defaults: notes "^\s*notes?:", slides "\r?\n---\r?\n".
md_notes(Body, Tag) ->
    Notes = attr(Tag, "data-separator-notes", "^\\s*notes?:"),
    Seps = [S || S <- [attr(Tag, "data-separator", "\\r?\\n---\\r?\\n"),
                       attr(Tag, "data-separator-vertical", "")], S =/= ""],
    Ahead = lists:join("|", [["(?:", S, ")"] || S <- Seps]
                            ++ ["</textarea", "</script", "\\z"]),
    Pattern = iolist_to_binary(["(?:", Notes, ")[\\s\\S]*?(?=", Ahead, ")"]),
    try re:replace(Body, Pattern, "", [global, caseless, multiline, {return, binary}])
    catch
        _:_ ->
            %% A separator we cannot compile: fall back to the defaults.
            re:replace(Body, "^\\s*notes?:[\\s\\S]*?(?=\\r?\\n---\\r?\\n|</textarea|</script|\\z)",
                       "", [global, caseless, multiline, {return, binary}])
    end.

attr(Tag, Name, Default) ->
    case re:run(Tag, "\\s" ++ Name ++ "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
                [{capture, all_but_first, binary} | ?OPTS]) of
        {match, Groups} ->
            %% An empty value would match everywhere: use the default.
            case [V || V <- Groups, V =/= <<>>] of
                [V | _] -> unescape(V);
                [] -> Default
            end;
        nomatch -> Default
    end.

unescape(V) ->
    lists:foldl(fun({F, T}, Acc) -> binary:replace(Acc, F, T, [global]) end, V,
                [{<<"&lt;">>, <<"<">>}, {<<"&gt;">>, <<">">>}, {<<"&quot;">>, <<"\"">>},
                 {<<"&#39;">>, <<"'">>}, {<<"&amp;">>, <<"&">>}]).
