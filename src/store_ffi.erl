-module(store_ffi).
-export([now/0, guard/2]).

%% Seconds on a clock that never goes back.
now() -> erlang:monotonic_time(second).

%% Runs Body; if it returns {error, _} or crashes, runs OnFail first. A
%% conversion that dies (a failed assert, a killed port) still gives its
%% reservation back.
guard(Body, OnFail) ->
    try Body() of
        {error, _} = E -> OnFail(), E;
        R -> R
    catch
        C:R:S -> OnFail(), erlang:raise(C, R, S)
    end.
