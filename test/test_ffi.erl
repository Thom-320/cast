-module(test_ffi).
-export([rescue/1]).

rescue(F) ->
    try {ok, F()} catch _:_ -> {error, nil} end.
