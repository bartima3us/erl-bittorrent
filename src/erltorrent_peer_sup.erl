-module(erltorrent_peer_sup).

-behaviour(supervisor).

%% API
-export([start_link/6]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Peer, PeerId, Hash, FileName, FullSize, PieceSize) ->
    supervisor:start_link(?MODULE, [Peer, PeerId, Hash, FileName, FullSize, PieceSize]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Peer, PeerId, Hash, FileName, FullSize, PieceSize]) ->
    Spec = #{
        id          => Peer,
        start       => {erltorrent_peer, start_link, [Peer, PeerId, Hash, FileName, FullSize, PieceSize]},
        restart     => transient,
        shutdown    => 5000,
        type        => worker,
        modules     => [erltorrent_peer]
    },
    {ok, {{one_for_one, 5, 10}, [Spec]}}.