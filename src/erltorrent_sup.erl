%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 18. Feb 2018 14.04
%%%-------------------------------------------------------------------
-module(erltorrent_sup).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(supervisor).

%% API
-export([
    start_link/0,
    start_child/1,
    stop_child/1
]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


start_child(TorrentName) ->
    TorrentSupSpec = #{
        id          => {erltorrent_torrent_sup, TorrentName},
        start       => {erltorrent_torrent_sup, start_link, [TorrentName]},
        restart     => permanent,
        shutdown    => infinity,
        type        => supervisor,
        modules     => [erltorrent_torrent_sup]
    },
    supervisor:start_child(?MODULE, TorrentSupSpec).


stop_child(TorrentName) ->
    ok = supervisor:terminate_child(?MODULE, {erltorrent_torrent_sup, TorrentName}),
    ok = supervisor:delete_child(?MODULE, {erltorrent_torrent_sup, TorrentName}).



%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.


