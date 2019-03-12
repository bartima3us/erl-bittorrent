-module(erltorrent_peers_crawler_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_child/6]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


start_child(FileName, AnnounceLink, Hash, PeerId, FullSize, PieceSize) ->
    supervisor:start_child(?MODULE, [FileName, AnnounceLink, Hash, PeerId, FullSize, PieceSize]).


%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Crawler = #{
        id          => peers_crawler,
        start       => {erltorrent_peers_crawler, start_link, []},
        restart     => permanent,
        shutdown    => 5000,
        type        => worker,
        modules     => [erltorrent_peers_crawler]
    },
    {ok, {{simple_one_for_one, 5, 10}, [Crawler]}}.

