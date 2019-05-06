%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 18. Feb 2018 14.04
%%%-------------------------------------------------------------------
-module(erltorrent_app).
-author("bartimaeus").

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    ok = erltorrent_store:wait_for_tables(20000),
    erltorrent_sup:start_link().

stop(_State) ->
    ok.
