-module(erltorrent_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
%%    ok = erltorrent_store:wait_for_tables(60000),
    erltorrent_sup:start_link().

stop(_State) ->
    ok.
