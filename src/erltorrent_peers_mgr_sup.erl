-module(erltorrent_peers_mgr_sup).

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
    PeersSup = #{
        id          => peers_sup,
        start       => {erltorrent_peers_sup, start_link, []},
        restart     => permanent,
        shutdown    => infinity,
        type        => supervisor,
        modules     => [erltorrent_peers_sup]
    },
    CrawlerSup = #{
        id          => peers_crawler_sup,
        start       => {erltorrent_peers_crawler_sup, start_link, []},
        restart     => permanent,
        shutdown    => infinity,
        type        => supervisor,
        modules     => [erltorrent_peers_crawler_sup]
    },
    % Because Crawler uses Peers Sup
    {ok, {{rest_for_one, 5, 10}, [PeersSup, CrawlerSup]}}.


