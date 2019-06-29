%%%-------------------------------------------------------------------
%%% @author bartimaeus
%%% @copyright (C) 2019, sarunas.bartusevicius@gmail.com
%%% @doc
%%%
%%% @end
%%% Created : 06. May 2019 19.35
%%%-------------------------------------------------------------------
-module(erltorrent_peer_sup).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(supervisor).

%% API
-export([start_link/4]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Peer, PeerId, Hash, FullSize) ->
    supervisor:start_link(?MODULE, [Peer, PeerId, Hash, FullSize]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Peer, PeerId, Hash, FullSize]) ->
    Spec = #{
        id          => Peer,
        start       => {erltorrent_peer, start_link, [Peer, PeerId, Hash, FullSize]},
        restart     => transient,
        shutdown    => 5000,
        type        => worker,
        modules     => [erltorrent_peer]
    },
    {ok, {{one_for_one, 5, 10}, [Spec]}}.