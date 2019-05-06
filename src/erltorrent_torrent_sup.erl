%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 00.37
%%%-------------------------------------------------------------------
-module(erltorrent_torrent_sup).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(TorrentName) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [TorrentName]).



%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([TorrentName]) ->
    Server = #{
        id          => erltorrent_leech_server,
        start       => {erltorrent_leech_server, start_link, [TorrentName]},
        restart     => permanent,
        shutdown    => 5000,
        type        => worker,
        modules     => [erltorrent_leech_server]
    },
    PeerSup = #{
        id          => peers_mgr_sup,
        start       => {erltorrent_peers_mgr_sup, start_link, []},
        restart     => permanent,
        shutdown    => infinity,
        type        => supervisor,
        modules     => [erltorrent_peers_mgr_sup]
    },
    {ok, {{one_for_one, 5, 10}, [Server, PeerSup]}}.


