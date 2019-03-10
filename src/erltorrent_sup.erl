-module(erltorrent_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Server = #{
        id          => server,
        start       => {erltorrent_server, start_link, []},
        restart     => permanent,
        shutdown    => 5000,
        type        => worker,
        modules     => [erltorrent_server]
    },
    PeerSup = #{
        id          => peers_sup,
        start       => {erltorrent_peers_sup, start_link, []},
        restart     => permanent,
        shutdown    => infinity,
        type        => supervisor,
        modules     => [erltorrent_peers_sup]
    },
    {ok, {{one_for_one, 5, 10}, [Server, PeerSup]}}.


